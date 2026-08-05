package com.interactpak.interactpro

import android.app.UiModeManager
import android.content.Context
import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.net.wifi.WifiManager
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

    /**
     * Wi-Fi multicast lock for mDNS / SSDP discovery (2026-07-02).
     *
     * The AndroidManifest has declared CHANGE_WIFI_MULTICAST_STATE since
     * the LAN feature shipped, and its comment claimed the lock was
     * "acquired in code" — but no code ever did. Many consumer routers +
     * Android's Wi-Fi power-save silently drop multicast (mDNS 224.0.0.251,
     * SSDP 239.255.255.250) unless the app holds a MulticastLock, which is
     * one reason peers appeared minutes late on Sony Bravia + Samsung
     * (2026-05-13 report) and why the 15 s re-browse kicker exists.
     * Dart acquires this via the `interact_pro/multicast` channel at
     * LanDiscoveryService.startBrowsing() and releases at stopBrowsing().
     */
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "interact_pro/multicast",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "acquire" -> {
                    try {
                        if (multicastLock?.isHeld != true) {
                            val wifi = applicationContext
                                .getSystemService(Context.WIFI_SERVICE) as WifiManager
                            multicastLock = wifi.createMulticastLock("interact_pro_lan").apply {
                                setReferenceCounted(false)
                                acquire()
                            }
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        // Non-fatal — discovery still works on networks that
                        // deliver multicast without the lock.
                        result.success(false)
                    }
                }
                "release" -> {
                    try {
                        if (multicastLock?.isHeld == true) multicastLock?.release()
                        multicastLock = null
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }

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

    override fun onDestroy() {
        // Belt-and-braces: never leak the multicast lock past the activity.
        try {
            if (multicastLock?.isHeld == true) multicastLock?.release()
        } catch (_: Exception) {
        }
        multicastLock = null
        super.onDestroy()
    }
}
