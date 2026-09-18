import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    appearance = NSAppearance(named: .darkAqua)
    titlebarAppearsTransparent = true
    backgroundColor = NSColor(calibratedWhite: 14.0 / 255.0, alpha: 1)
    minSize = NSSize(width: 960, height: 600)
    title = "HumTrack"
    super.awakeFromNib()
  }
}
