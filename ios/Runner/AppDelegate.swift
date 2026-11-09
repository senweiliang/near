import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "NearShareInbox") {
      NearShareInbox.register(with: registrar)
    }
  }
}

/// 其他 app「分享 / 用 Near 打开」的文件（CFBundleDocumentTypes）经此转给 Dart 的 near/share。
class NearShareInbox: NSObject, FlutterPlugin, FlutterSceneLifeCycleDelegate {
  private let channel: FlutterMethodChannel
  private var pending: [String] = []
  private var dartReady = false

  init(channel: FlutterMethodChannel) {
    self.channel = channel
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "near/share", binaryMessenger: registrar.messenger())
    let instance = NearShareInbox(channel: channel)
    registrar.addMethodCallDelegate(instance, channel: channel)
    registrar.addSceneDelegate(instance)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "getInitial" else {
      result(FlutterMethodNotImplemented)
      return
    }
    dartReady = true
    result(pending)
    pending.removeAll()
  }

  func scene(
    _ scene: UIScene, willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions?
  ) -> Bool {
    guard let contexts = connectionOptions?.urlContexts, !contexts.isEmpty else { return false }
    deliver(contexts)
    return true
  }

  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) -> Bool {
    deliver(URLContexts)
    return true
  }

  private func deliver(_ contexts: Set<UIOpenURLContext>) {
    let paths = contexts.map(\.url).filter(\.isFileURL).compactMap(copyToTemp)
    guard !paths.isEmpty else { return }
    if dartReady {
      channel.invokeMethod("shared", arguments: paths)
    } else {
      pending.append(contentsOf: paths)
    }
  }

  // 系统给的 URL 可能是安全作用域 / Inbox 下的临时文件，复制一份到 app 自己的临时目录再交给 Dart
  private func copyToTemp(_ url: URL) -> String? {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("shared-\(UUID().uuidString)", isDirectory: true)
    let target = dir.appendingPathComponent(url.lastPathComponent)
    do {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      try FileManager.default.copyItem(at: url, to: target)
      return target.path
    } catch {
      NSLog("[share] copy \(url) failed: \(error)")
      return nil
    }
  }
}
