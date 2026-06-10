import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Load the release keystore properties from android/key.properties
// (gitignored). The file is optional — when absent, release builds
// fall back to the debug keystore so `flutter run --release` and CI
// without secrets still work.
val keystoreProperties = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) FileInputStream(f).use { load(it) }
}
val hasReleaseSigning =
    keystoreProperties.getProperty("storeFile")?.isNotBlank() == true

android {
    namespace = "com.interactpak.interactpro"
    compileSdk = flutter.compileSdkVersion
    // Pinning NDK to 28.2.13676358 — the version `jni` + `speech_to_text`
    // were built against. NDK 27 left strip-debug-symbols failing during
    // AAB build because the native libs from those two plugins (compiled
    // with NDK 28) are not strip-compatible with NDK 27's llvm-strip.
    // Flutter's rule: use the HIGHEST NDK any plugin needs (they're
    // backward compatible). Pinning explicitly so we get reproducible
    // builds across machines AND a controlled upgrade path the next time
    // a plugin bumps its NDK requirement.
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // Java 8+ desugaring — required by flutter_local_notifications
        // (it uses java.time APIs that need backporting on minSdk < 26).
        // The desugar_jdk_libs dep below is what makes those APIs work
        // on Android 21-25. No-op on Android 26+.
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // Reverse-domain applicationId — MUST stay stable once published.
        // Google Play binds the listing to this string permanently.
        applicationId = "com.interactpak.interactpro"
        // Bumped to 26 (Android 8.0 Oreo) on 2026-05-16 because the
        // newly-added media_cast_dlna plugin requires API 26+ for its
        // DLNA/UPnP discovery code. Android 7.x share in PK is ~3% in
        // 2026 and DLNA is a public-tier LAN feature we want every
        // user to have. Older Android 7 devices still get Bonsoir
        // discovery + manual IP entry; only DLNA target discovery
        // is gated by this floor.
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        getByName("release") {
            // Use the release keystore when key.properties is present;
            // otherwise fall back to debug so engineers without the
            // keystore can still produce a smoke-testable build.
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            // R8 / shrinking off for now — proguard rules tend to break
            // the reflection-heavy ML Kit + Syncfusion classes. Turn on
            // later with custom rules once we have a stable build.
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Google Cast Application Framework. flutter_chrome_cast bundles its
    // own version, but adding this explicitly pins the version we test
    // against and surfaces compile errors immediately if the SDK ever
    // breaks in a way the plugin doesn't shield us from.
    //
    // 22.x is the current AndroidX-aligned line as of May 2026. If the
    // pub plugin pulls a different major, prefer the plugin's version
    // (remove this line) — Cast SDK doesn't tolerate two majors on the
    // classpath.
    implementation("com.google.android.gms:play-services-cast-framework:22.0.0")

    // Java 8+ desugaring runtime — referenced by isCoreLibraryDesugaringEnabled
    // above. Required by flutter_local_notifications (uses java.time on
    // minSdk < 26). 2.1.4 is the current line that pairs with AGP 8.x.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
