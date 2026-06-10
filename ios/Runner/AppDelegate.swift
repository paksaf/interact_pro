import Flutter
import UIKit

// NOTE: GoogleCast SDK init was removed when `flutter_chrome_cast` was
// disabled in pubspec. AirPlay native plugin registration was removed
// because `AirPlayPlugin.swift` exists on disk but isn't added to the
// Runner Xcode target — Swift can't see the symbol at compile time.
//
// Both Cast and AirPlay still work for end users via the OS share
// sheet, so neither needs native code in v1.
//
// To re-enable the native AirPlay route picker:
//   1. Open ios/Runner.xcworkspace in Xcode.
//   2. Right-click the Runner group → Add Files to "Runner"…
//   3. Select ios/Runner/AirPlayPlugin.swift, ensure "Runner" target
//      is ticked, click Add.
//   4. Restore the `if let registrar = ...` block below from git
//      history.

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
  }
}
