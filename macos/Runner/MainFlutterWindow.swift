import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    self.backgroundColor = .white
    self.isOpaque = true
    self.alphaValue = 0.0

    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    flutterViewController.view.wantsLayer = true
    flutterViewController.view.layer?.backgroundColor = NSColor.white.cgColor
    if let contentView = self.contentView {
      contentView.wantsLayer = true
      contentView.layer?.backgroundColor = NSColor.white.cgColor
    }

    let channel = FlutterMethodChannel(
      name: "near.window/ready",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(nil); return }
      if call.method == "ready" {
        DispatchQueue.main.async {
          NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            self.animator().alphaValue = 1.0
          })
        }
      }
      result(nil)
    }

    RegisterGeneratedPlugins(registry: flutterViewController)

    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
      guard let self = self else { return }
      if self.alphaValue < 1.0 {
        self.alphaValue = 1.0
      }
    }

    super.awakeFromNib()
  }
}
