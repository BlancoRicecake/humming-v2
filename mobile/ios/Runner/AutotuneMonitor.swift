import AVFoundation
import Flutter

/// Live autotune monitoring: mic → YIN pitch detection → AVAudioUnitTimePitch
/// correction toward the nearest in-scale note → headphone output.
///
/// Wired-headphones-only by design (Bluetooth round-trip is 150-300 ms — too
/// late to sing against). The RECORDED take stays dry (the `record` plugin
/// captures the mic in parallel); this graph only colors what the singer
/// hears, and the final take is processed server-side with the same key/scale
/// so the monitored sound ≈ the end result.
///
/// Known risk (plan spike): sharing the mic with AVAudioRecorder. Both attach
/// to the shared AVAudioSession; if engine start fails we report `false` and
/// the modal silently falls back to plain (un-monitored) recording.
final class AutotuneMonitor {
  static let shared = AutotuneMonitor()

  /// `humming/autotune_monitor` channel (set by AppDelegate) — used to tell
  /// Dart when the native side stops on its own (wired route disappeared).
  var channel: FlutterMethodChannel?

  private var engine: AVAudioEngine?
  private var timePitch: AVAudioUnitTimePitch?
  private var routeObserver: NSObjectProtocol?
  private var sessionActivated = false
  private var scalePcs: [Int] = []
  private var strength: Double = 1.0
  private var heldTarget: Double?
  private var smoothedCents: Double = 0

  /// Wired (zero-feedback, low-latency) output present? Mic→speaker
  /// monitoring would feed straight back into the take.
  private static func hasWiredOutput() -> Bool {
    AVAudioSession.sharedInstance().currentRoute.outputs.contains {
      $0.portType == .headphones || $0.portType == .usbAudio
    }
  }

  private static let noteToPc: [String: Int] = [
    "C": 0, "C#": 1, "DB": 1, "D": 2, "D#": 3, "EB": 3, "E": 4,
    "F": 5, "F#": 6, "GB": 6, "G": 7, "G#": 8, "AB": 8, "A": 9,
    "A#": 10, "BB": 10, "B": 11,
  ]
  private static let scaleIntervals: [String: [Int]] = [
    "major": [0, 2, 4, 5, 7, 9, 11],
    "minor": [0, 2, 3, 5, 7, 8, 10],
    "dorian": [0, 2, 3, 5, 7, 9, 10],
    "major_pentatonic": [0, 2, 4, 7, 9],
    "minor_pentatonic": [0, 3, 5, 7, 10],
  ]

  /// Start monitoring. Returns false when the graph can't start (caller falls
  /// back to un-monitored recording).
  func start(key: String, scale: String, strength: Double) -> Bool {
    stop()
    guard let rootPc = Self.noteToPc[key.uppercased()],
          let intervals = Self.scaleIntervals[scale] ?? Self.scaleIntervals["minor"]
    else { return false }
    scalePcs = Set(intervals.map { ($0 + rootPc) % 12 }).sorted()
    self.strength = strength
    heldTarget = nil
    smoothedCents = 0

    // Wired-output check BEFORE wiring the engine — without headphones the
    // mic would monitor through the speaker and feed back into itself.
    guard Self.hasWiredOutput() else { return false }

    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playAndRecord, mode: .measurement,
                              options: [.mixWithOthers, .allowBluetoothA2DP])
      try session.setPreferredIOBufferDuration(0.005) // ~256 frames @48k
      try session.setActive(true)
      sessionActivated = true
    } catch {
      return false
    }

    let engine = AVAudioEngine()
    let timePitch = AVAudioUnitTimePitch()
    timePitch.overlap = 8 // denser grains — fewer artifacts on voice
    engine.attach(timePitch)
    let input = engine.inputNode
    let fmt = input.outputFormat(forBus: 0)
    guard fmt.sampleRate > 0 else { return false }
    engine.connect(input, to: timePitch, format: fmt)
    engine.connect(timePitch, to: engine.mainMixerNode, format: fmt)

    // pitch tracking tap — 1024 frames ≈ 21 ms @48k; correction updated per tap
    input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buffer, _ in
      guard let self, let ch = buffer.floatChannelData?[0] else { return }
      let n = Int(buffer.frameLength)
      if let hz = Self.yinPitch(ch, n, Float(fmt.sampleRate)) {
        self.updateCorrection(hz: Double(hz))
      }
    }

    do {
      try engine.start()
    } catch {
      input.removeTap(onBus: 0)
      return false
    }
    self.engine = engine
    self.timePitch = timePitch

    // Stop the moment the wired route disappears (unplugged mid-recording):
    // the engine would fall back to the speaker and feed back into the mic.
    routeObserver = NotificationCenter.default.addObserver(
      forName: AVAudioSession.routeChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self, self.engine != nil, !Self.hasWiredOutput() else { return }
      self.stop()
      // tell Dart so the "LIVE AUTOTUNE" badge clears
      self.channel?.invokeMethod("monitorStopped", arguments: nil)
    }
    return true
  }

  func stop() {
    if let routeObserver {
      NotificationCenter.default.removeObserver(routeObserver)
      self.routeObserver = nil
    }
    if let engine {
      engine.inputNode.removeTap(onBus: 0)
      engine.stop()
    }
    engine = nil
    timePitch = nil
    // NOTE: the session is NOT deactivated here — every stop path in the
    // recording modal stops the monitor while AVAudioRecorder is still
    // writing, and setActive(false) then would cut the take short. Dart calls
    // releaseSession() after the recorder has fully stopped.
  }

  /// Deactivate the shared session we activated in start(). Safe to call
  /// unconditionally after recording ends; no-op when the monitor never
  /// activated the session or is still running.
  func releaseSession() {
    guard engine == nil, sessionActivated else { return }
    sessionActivated = false
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  // Nearest in-scale target with hysteresis (mirror of backend retune_f0),
  // then one-pole smoothing of the correction in cents.
  private func updateCorrection(hz: Double) {
    guard hz > 60, hz < 1200 else { return }
    let midi = 69 + 12 * log2(hz / 440)
    let base = (midi).rounded()
    var best = base
    var bestDist = Double.greatestFiniteMagnitude
    for octave in [-1.0, 0.0, 1.0] {
      for pc in scalePcs {
        let cand = base - base.truncatingRemainder(dividingBy: 12) + Double(pc) + 12 * octave
        let d = abs(cand - midi)
        if d < bestDist { bestDist = d; best = cand }
      }
    }
    if let held = heldTarget, best != held, (abs(midi - held) - abs(midi - best)) <= 0.6 {
      best = held // hysteresis: keep the held note unless the new one clearly wins
    }
    heldTarget = best
    let corrCents = (best - midi) * 100 * strength
    smoothedCents += 0.35 * (corrCents - smoothedCents) // ~60 ms settle at 21 ms taps
    let clamped = max(-700, min(700, smoothedCents))
    DispatchQueue.main.async { [weak self] in
      self?.timePitch?.pitch = Float(clamped)
    }
  }

  /// Compact YIN (difference function + CMNDF, threshold 0.15) over one tap
  /// buffer. Returns nil for unvoiced/quiet frames.
  private static func yinPitch(_ x: UnsafeMutablePointer<Float>, _ n: Int, _ sr: Float) -> Float? {
    guard n >= 512 else { return nil }
    var energy: Float = 0
    for i in 0..<n { energy += x[i] * x[i] }
    if energy / Float(n) < 1e-6 { return nil } // gate

    let tauMin = max(2, Int(sr / 800)) // ≤800 Hz
    let tauMax = min(n / 2, Int(sr / 70)) // ≥70 Hz
    guard tauMax > tauMin else { return nil }
    var d = [Float](repeating: 0, count: tauMax + 1)
    for tau in tauMin...tauMax {
      var sum: Float = 0
      for i in 0..<(n - tau) {
        let diff = x[i] - x[i + tau]
        sum += diff * diff
      }
      d[tau] = sum
    }
    // cumulative-mean-normalized difference
    var runningSum: Float = 0
    var cmndf = [Float](repeating: 1, count: tauMax + 1)
    for tau in tauMin...tauMax {
      runningSum += d[tau]
      cmndf[tau] = runningSum > 0 ? d[tau] * Float(tau - tauMin + 1) / runningSum : 1
    }
    var tauEst = -1
    for tau in tauMin..<tauMax {
      if cmndf[tau] < 0.15 {
        var t = tau
        while t + 1 <= tauMax, cmndf[t + 1] < cmndf[t] { t += 1 }
        tauEst = t
        break
      }
    }
    guard tauEst > 0 else { return nil }
    // parabolic interpolation around the minimum
    var betterTau = Float(tauEst)
    if tauEst > tauMin && tauEst < tauMax {
      let s0 = cmndf[tauEst - 1], s1 = cmndf[tauEst], s2 = cmndf[tauEst + 1]
      let denom = 2 * (2 * s1 - s2 - s0)
      if abs(denom) > 1e-9 { betterTau += (s2 - s0) / denom }
    }
    return sr / betterTau
  }
}
