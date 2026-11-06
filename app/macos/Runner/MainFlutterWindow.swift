import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // M2 target side: the Dart layer drives the local cursor and keyboard
    // through this channel. Registered here rather than in AppDelegate because
    // this is where the engine's binary messenger first exists.
    MacInputInjector.register(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()

    // The Flutter template opens at 800x600, which is shorter than this page:
    // the control panel then overflows and hides the input-injection status.
    setContentSize(NSSize(width: 1180, height: 840))
    center()
  }
}
