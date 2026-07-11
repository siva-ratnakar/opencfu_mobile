import Flutter
import UIKit

/// Adds Home Screen quick-action handling ("New Count", see Info.plist's
/// `UIApplicationShortcutItems`) on top of Flutter's default scene delegate.
/// Scene-based apps receive shortcut taps here rather than in the app
/// delegate's `application(_:performActionFor:completionHandler:)`.
class SceneDelegate: FlutterSceneDelegate {
  private static let basicCaptureShortcutType = "com.example.opencfuMobile.basicCapture"

  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    if connectionOptions.shortcutItem?.type == Self.basicCaptureShortcutType {
      AppDelegate.shared?.recordPendingBasicCapture()
    }
  }

  override func windowScene(
    _ windowScene: UIWindowScene,
    performActionFor shortcutItem: UIApplicationShortcutItem,
    completionHandler: @escaping (Bool) -> Void
  ) {
    guard shortcutItem.type == Self.basicCaptureShortcutType else {
      super.windowScene(windowScene, performActionFor: shortcutItem, completionHandler: completionHandler)
      return
    }
    AppDelegate.shared?.triggerBasicCapture()
    completionHandler(true)
  }
}
