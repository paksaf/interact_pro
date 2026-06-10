import AVKit
import Flutter
import UIKit

/// Native bridge for "tap the AirPlay device picker" from Dart.
///
/// `SystemCastService` calls `interact_pro/airplay#presentRoutePicker`
/// when the user picks the AirPlay row in the cast sheet. We respond by
/// inserting an off-screen `AVRoutePickerView` into the key window and
/// programmatically pressing its hidden button — this is the supported
/// way to surface the AirPlay route picker without our own custom UI.
///
/// If iOS rejects the press (e.g. running in a context where audio /
/// video session isn't active), we return a Flutter error and the Dart
/// side falls back to the OS share sheet (which still includes AirPlay).
public class AirPlayPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "interact_pro/airplay",
      binaryMessenger: registrar.messenger()
    )
    let instance = AirPlayPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  /// Held strongly so the route-picker view doesn't get torn down before
  /// the user actually picks a route. Cleared the next time the channel
  /// is invoked.
  private var picker: AVRoutePickerView?

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "presentRoutePicker":
      presentRoutePicker(result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func presentRoutePicker(result: @escaping FlutterResult) {
    DispatchQueue.main.async {
      guard let window = self.keyWindow() else {
        result(FlutterError(
          code: "NO_WINDOW",
          message: "No key window to attach AVRoutePickerView to.",
          details: nil
        ))
        return
      }

      // Reuse an existing picker if one's already attached — avoids
      // accumulating subviews if the user taps repeatedly.
      let picker = self.picker ?? AVRoutePickerView(frame: .zero)
      // Off-screen position; the view need only exist in the hierarchy
      // for its embedded button to fire.
      picker.frame = CGRect(x: -100, y: -100, width: 0, height: 0)
      picker.activeTintColor = .clear
      picker.tintColor = .clear
      // Prefer audio-and-video targets over audio-only — most users
      // who tap "Cast a PDF" want the TV, not their HomePod.
      picker.prioritizesVideoDevices = true

      if picker.superview == nil {
        window.addSubview(picker)
      }
      self.picker = picker

      // Press the embedded button. AVRoutePickerView always has exactly
      // one UIButton child — `sendActions(.touchUpInside)` opens the
      // route picker sheet.
      let button = picker.subviews.compactMap { $0 as? UIButton }.first
      if let button = button {
        button.sendActions(for: .touchUpInside)
        result(nil)
      } else {
        // Safety net — should never hit. iOS doesn't document the
        // internal subview structure, so we degrade gracefully.
        result(FlutterError(
          code: "NO_PICKER_BUTTON",
          message: "Could not locate AVRoutePickerView's embedded button.",
          details: nil
        ))
      }
    }
  }

  /// `UIApplication.shared.windows` is deprecated since iOS 15 — the
  /// modern path goes via the connected scenes. We try both because the
  /// app supports older iOS versions too.
  private func keyWindow() -> UIWindow? {
    if #available(iOS 15.0, *) {
      let scenes = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
      for scene in scenes {
        if let key = scene.windows.first(where: { $0.isKeyWindow }) {
          return key
        }
      }
      return scenes.first?.windows.first
    } else {
      return UIApplication.shared.windows.first(where: { $0.isKeyWindow })
        ?? UIApplication.shared.windows.first
    }
  }
}
