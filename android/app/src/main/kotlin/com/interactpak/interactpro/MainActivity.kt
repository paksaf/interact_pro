package com.interactpak.interactpro

import android.app.UiModeManager
import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Adds an `interact_pro/device_info` platform channel that exposes a
 * reliable "is this an Android TV" signal to Dart.
 *
 * Why this matters: WindowManager.shortestSide heuristics can fail on
 * Sony Bravia firmware that launches sideloaded apps in compact
 * portrait windows (~300dp wide) regardless of the actual screen
 * size. Asking UiModeManager directly avoids that whole class of
 * false-negative.
 *
 * Dart side: see `lib/core/device/device_info.dart` for the consumer.
 */
class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "interact_pro/device_info",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                // True iff the OS reports this device as a TELEVISION
                // form factor. Reliable across Android TV, Google TV,
                // Fire TV (Amazon's UiModeManager extends AOSP's).
                "isAndroidTv" -> {
                    val ui = getSystemService(UI_MODE_SERVICE) as UiModeManager
                    val isTv =
                        ui.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION
                    result.success(isTv)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Belt-and-braces: if the system reports we're on a TV,
        // explicitly request landscape orientation so the activity
        // settles into the right aspect from the start instead of
        // flickering portrait → landscape after Flutter's runtime
        // SystemChrome call fires a few frames later.
        val ui = getSystemService(UI_MODE_SERVICE) as UiModeManager
        if (ui.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION) {
            requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
        }
    }
}
