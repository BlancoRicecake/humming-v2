import AVFoundation
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    AppDelegate.configurePlaybackSession()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// flutter_midi_pro sets NO AVAudioSession category, so iOS defaults to
  /// soloAmbient — which respects the hardware silent switch. The result:
  /// synth output (instrument preview, loop playback) is silent whenever the
  /// ringer switch is set to silent, while Android (no such switch) always
  /// plays. Force .playback so music audio plays regardless of the switch —
  /// the standard category for a music-creation app. The record + autotune
  /// monitor flows switch to .playAndRecord while active and this resting
  /// category applies the rest of the time.
  static func configurePlaybackSession() {
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playback, options: [])
      try session.setActive(true)
    } catch {
      NSLog("[audio] playback session setup failed: \(error)")
    }
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // humming/audio — output-route queries (mirrors Android MainActivity.kt).
    // "wired" enables live autotune monitoring; "bluetooth" only allows the
    // backing loop during recording; "none" mutes the backing (speaker bleed).
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "humming.audio") {
      let channel = FlutterMethodChannel(name: "humming/audio", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in
        switch call.method {
        case "hasHeadset":
          result(AppDelegate.headsetRoute() != "none")
        case "headsetRoute":
          result(AppDelegate.headsetRoute())
        case "outputSampleRate":
          // Current shared-session hardware rate. Recording at exactly this rate
          // keeps record_ios from dragging the hardware to a lower rate and
          // leaving it there (which crackles the synth output AFTER recording).
          result(AVAudioSession.sharedInstance().sampleRate)
        case "resetToPlaybackSession":
          // Recording leaves the shared session configured for duplex IO. Just
          // flipping the category back to .playback on a STILL-ACTIVE session does
          // not renegotiate the hardware IO, so the synth output keeps crackling
          // after recording. A full deactivate → .playback → reactivate forces a
          // clean IO renegotiation (call with the output unit already released).
          do {
            let s = AVAudioSession.sharedInstance()
            try s.setActive(false, options: .notifyOthersOnDeactivation)
            try s.setCategory(.playback, options: [])
            try s.setActive(true)
            result(true)
          } catch {
            NSLog("[audio] resetToPlaybackSession failed: \(error)")
            result(false)
          }
        case "overrideOutputToSpeaker":
          // After the synth output is rebuilt under .playAndRecord (recording
          // window), flutter_pcm_sound's setCategory carries no .defaultToSpeaker
          // option, so output would fall back to the receiver. Force it to the
          // built-in speaker. Only valid while the category is .playAndRecord.
          do {
            try AVAudioSession.sharedInstance().overrideOutputAudioPort(.speaker)
            result(true)
          } catch {
            NSLog("[audio] overrideOutputToSpeaker failed: \(error)")
            result(false)
          }
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }

    // humming/autotune_monitor — live pitch-corrected monitoring while
    // recording (wired headphones only; see AutotuneMonitor.swift).
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "humming.autotune_monitor") {
      let channel = FlutterMethodChannel(name: "humming/autotune_monitor", binaryMessenger: registrar.messenger())
      // the monitor pushes "monitorStopped" back over this channel when it
      // shuts itself down (wired headphones unplugged mid-recording)
      AutotuneMonitor.shared.channel = channel
      channel.setMethodCallHandler { call, result in
        switch call.method {
        case "start":
          let args = call.arguments as? [String: Any] ?? [:]
          let ok = AutotuneMonitor.shared.start(
            key: args["key"] as? String ?? "A",
            scale: args["scale"] as? String ?? "minor",
            strength: args["strength"] as? Double ?? 1.0
          )
          result(ok)
        case "stop":
          AutotuneMonitor.shared.stop()
          result(true)
        case "releaseSession":
          AutotuneMonitor.shared.releaseSession()
          result(true)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }
  }

  private static func headsetRoute() -> String {
    let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
    for o in outputs {
      switch o.portType {
      case .headphones, .usbAudio:
        return "wired"
      case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP:
        return "bluetooth"
      default:
        continue
      }
    }
    return "none"
  }
}
