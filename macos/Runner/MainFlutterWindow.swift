import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    self.backgroundColor = .white
    self.isOpaque = true
    self.alphaValue = 0.0

    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    // 默认打开尺寸：内容区 400×600，居中显示
    self.setContentSize(NSSize(width: 400, height: 600))
    self.center()

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
    NearShareInbox.shared.attach(messenger: flutterViewController.engine.binaryMessenger)

    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
      guard let self = self else { return }
      if self.alphaValue < 1.0 {
        self.alphaValue = 1.0
      }
    }

    super.awakeFromNib()
  }
}

/// Finder「打开方式 → Near」/ 拖到 Dock 图标的文件经此转给 Dart 的 near/share。
class NearShareInbox: NSObject, FlutterAppLifecycleDelegate {
  static let shared = NearShareInbox()
  private var channel: FlutterMethodChannel?
  private var pending: [String] = []
  private var dartReady = false

  func attach(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "near/share", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self, call.method == "getInitial" else {
        result(FlutterMethodNotImplemented)
        return
      }
      self.dartReady = true
      result(self.pending)
      self.pending.removeAll()
    }
    self.channel = channel
    (NSApp.delegate as? FlutterAppDelegate)?.addApplicationLifecycleDelegate(self)
  }

  @objc(handleOpenURLs:)
  func handleOpen(_ urls: [URL]) -> Bool {
    let paths = urls.filter(\.isFileURL).map(\.path)
    guard !paths.isEmpty else { return false }
    if dartReady, let channel = channel {
      channel.invokeMethod("shared", arguments: paths)
    } else {
      pending.append(contentsOf: paths)
    }
    return true
  }
}
