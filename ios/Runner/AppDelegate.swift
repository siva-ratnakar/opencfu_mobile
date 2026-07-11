import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// Lets `SceneDelegate` reach the app delegate to report a Home Screen quick
  /// action tap (see Info.plist's `UIApplicationShortcutItems`).
  static weak var shared: AppDelegate?

  private let shortcutChannelName = "opencfu_mobile/shortcut"
  private var shortcutChannel: FlutterMethodChannel?
  private var pendingLaunchAction: String?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    AppDelegate.shared = self
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let channel = FlutterMethodChannel(
      name: shortcutChannelName,
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(nil)
        return
      }
      switch call.method {
      case "getLaunchAction":
        result(self.pendingLaunchAction)
        self.pendingLaunchAction = nil
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    shortcutChannel = channel
  }

  /// Cold start: the app is launching because of the quick action. Dart pulls
  /// this once (`getLaunchAction`) after it is actually ready to navigate, so
  /// there is no race with the Dart isolate not having registered its channel
  /// handler yet.
  func recordPendingBasicCapture() {
    pendingLaunchAction = "basicCapture"
  }

  /// Warm start: the app (and its Flutter engine) is already running, so the
  /// Dart-side handler is guaranteed to be registered; push the event directly.
  func triggerBasicCapture() {
    shortcutChannel?.invokeMethod("launchBasicCapture", arguments: nil)
  }
}
