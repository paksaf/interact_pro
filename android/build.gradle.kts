allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// Force every subproject (every Flutter plugin's Android module) to use
// JVM 17 for both Java and Kotlin compilation. Some plugins —
// receive_sharing_intent 1.8.x and bonsoir_android in particular — ship
// with mismatched targets (Java 1.8, Kotlin 17/21), which Gradle 8+ hard-
// fails as "Inconsistent JVM-target compatibility". This block normalises
// both to JVM 17.
//
// IMPORTANT: setting JavaCompile task properties directly does NOT work
// because AGP overrides them from `android.compileOptions`. We have to
// reach into the AGP extension via pluginManager.withPlugin (which is
// lazy and fires whenever the Android library plugin is applied to a
// subproject — that's every Flutter plugin's Android module). The Kotlin
// side uses the lazy `tasks.withType().configureEach` pattern.
//
// `pluginManager.withPlugin("com.android.library")` is the right hook
// because Flutter plugins all use the library variant of AGP. We avoid
// `afterEvaluate` because it'd race with the existing evaluationDependsOn
// at the top of this file.
// Both Java and Kotlin sides need to be set INSIDE afterEvaluate so they
// run AFTER each plugin's own android { compileOptions { ... } } and
// kotlin { compilerOptions { ... } } blocks have executed. Otherwise the
// plugin's own setting wins. Examples seen in this project:
//   • bonsoir_android — Java compileOptions defaults to 1.8
//   • workmanager     — Kotlin compilerOptions explicitly set to 1.8
// Without overriding both sides post-evaluate, you ping-pong between the
// two errors as you fix one and unmask the other.
//
// Skip `:app` because the existing `evaluationDependsOn(":app")` above
// forces :app to evaluate eagerly; afterEvaluate then errors. :app's own
// compileOptions are already JVM 17 via app/build.gradle.kts.
subprojects {
    if (name != "app") {
        afterEvaluate {
            // Java side — reach into AGP's library extension.
            extensions.findByType(com.android.build.gradle.LibraryExtension::class.java)?.apply {
                compileOptions.sourceCompatibility = JavaVersion.VERSION_17
                compileOptions.targetCompatibility = JavaVersion.VERSION_17

                // AGP 8+ requires every Android module to declare a
                // `namespace`. Plugins published before that requirement —
                // ar_flutter_plugin 0.7.3 is the live example — leave it
                // unset, which makes the configure-project step hard-fail
                // with "Namespace not specified". They DO still ship a
                // `package="..."` attribute in their AndroidManifest.xml
                // (the legacy place namespaces lived), so we lift the
                // value over and set namespace from there.
                //
                // This block is a no-op for plugins that already declare
                // their own namespace, so it's safe to keep installed
                // forever; future plugin updates that move to declaring
                // their own namespace silently take precedence.
                if (namespace.isNullOrEmpty()) {
                    val manifestFile = file("src/main/AndroidManifest.xml")
                    if (manifestFile.exists()) {
                        val pkgRegex = Regex("""package\s*=\s*"([^"]+)"""")
                        val match = pkgRegex.find(manifestFile.readText())
                        val pkg = match?.groupValues?.getOrNull(1)
                        if (!pkg.isNullOrEmpty()) {
                            namespace = pkg
                        }
                    }
                }

                // Force every plugin to compile against modern Android.
                //
                // Why: older plugins like `ar_flutter_plugin 0.7.3` pin
                // compileSdk = 30, but their transitive androidx.core
                // dependency now requires API 31+ resource attributes
                // (android:attr/lStar — the OkLab perceptual luminance
                // attribute introduced in Android 12). Without this
                // bump, AAPT fails resource linking with:
                //   "error: resource android:attr/lStar not found"
                //
                // Pinning to 35 matches what `flutter.compileSdkVersion`
                // resolves to in current Flutter SDK channels and what
                // our :app module already uses. Future-proof: if a
                // plugin already declares a HIGHER compileSdk, leave it
                // alone (don't downgrade).
                if (compileSdk == null || (compileSdk ?: 0) < 35) {
                    compileSdk = 35
                }
            }
            // Kotlin side — modern compilerOptions DSL on every Kotlin
            // compile task. Inside afterEvaluate so it runs after any
            // plugin-level kotlin { compilerOptions { jvmTarget = JVM_1_8 } }.
            tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
                compilerOptions {
                    jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
                }
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
