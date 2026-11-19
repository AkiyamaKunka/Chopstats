import java.util.Base64
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing (docs/RELEASING.md § Google Play).
//
// android/key.properties (git-ignored; written by .github/workflows/release.yml
// on CI, by hand on the owner's Mac) carries the upload-key settings:
//
//     storeFile=upload-keystore.jks      # relative to android/, or absolute
//     storePassword=...
//     keyPassword=...
//     keyAlias=upload
//
// Without it the release build is signed with the DEBUG key, as it always
// was, so friends and contributors can still `flutter build apk --release`
// without any keystore. Such a build installs fine but Play rejects it, and
// Android refuses to upgrade between the two signatures.
val keystorePropertiesFile = rootProject.file("key.properties")
val hasUploadKeystore = keystorePropertiesFile.exists()
val keystoreProperties = Properties().apply {
    if (hasUploadKeystore) {
        keystorePropertiesFile.inputStream().use { load(it) }
    }
}
// Only a release build is affected, so only a release build gets the notice:
// `flutter build apk --debug` / `flutter run` request assembleDebug and
// would otherwise print it on every developer build.
val releaseRequested =
    gradle.startParameter.taskNames.any { it.contains("Release", ignoreCase = true) }
if (!hasUploadKeystore && releaseRequested) {
    // logger.quiet, not warn: `flutter build` runs Gradle with -q, which
    // hides WARN-level output; QUIET is the one level that still reaches
    // the terminal.
    logger.quiet(
        "BiteWise: android/key.properties not found - the release build is signed with the " +
            "DEBUG key (installable, NOT uploadable to Google Play). See docs/RELEASING.md.",
    )
}

// The sideload APK (GitHub release, scripts/build_share_apk.sh) is ONE arm64
// APK built with `flutter build apk --target-platform android-arm64`, not
// --split-per-abi: Flutter gives a split APK the versionCode 1000 x ABI + the
// build number (2102 for arm64 build 102), so it could never upgrade to or
// from the Play bundle's plain 102. A plain build would still pack the
// plugins' libraries for every ABI (libdartjni, libdatastore_shared_counter)
// without libflutter.so for them, so a 32-bit phone would install it and
// crash at launch; the filter below keeps only arm64-v8a. Bundles (Flutter
// passes all three platforms) and --split-per-abi builds are untouched.
val arm64OnlyApk =
    project.findProperty("target-platform")?.toString() == "android-arm64" &&
        project.findProperty("split-per-abi")?.toString()?.toBoolean() != true

// The Google Play build (owner decision 1, 2026-11-13; docs/RELEASING.md
// § 6): `flutter build appbundle --dart-define=CHOPSTATS_CHANNEL=play`.
// The ONE switch: the Dart side reads it as lib/core/app_channel.dart, and
// here it merges src/playChannel/AndroidManifest.xml into every variant,
// which strips the three photo permissions (the GitHub APK keeps them).
// Flutter hands its dart-defines to Gradle as the `dart-defines` project
// property: comma-separated, each entry base64(utf8("KEY=VALUE"))
// (flutter_tools build_info.dart encodeDartDefines, read by FlutterPlugin.kt).
// An entry that does not decode is skipped; Flutter itself would fail on it.
val dartDefines: Map<String, String> =
    project.findProperty("dart-defines")?.toString().orEmpty()
        .split(',')
        .mapNotNull { entry ->
            runCatching {
                String(Base64.getDecoder().decode(entry.trim()), Charsets.UTF_8)
            }.getOrNull()
        }
        .mapNotNull { define ->
            val eq = define.indexOf('=')
            if (eq > 0) define.substring(0, eq) to define.substring(eq + 1) else null
        }
        .toMap()
val playChannel = dartDefines["CHOPSTATS_CHANNEL"] == "play"

android {
    namespace = "dev.calorietracker.calorie_tracker"
    // receive_sharing_intent's AAR metadata requires compileSdk >= 37.
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications uses java.time — needs desugaring.
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // Permanent (owner, 2026-11-13): never change applicationId. A new id
        // is a new app on Play and orphans every installed copy, whose meal
        // log lives only on the phone. Play's app-signing key is the upload
        // key the GitHub APKs are signed with, so both builds share it.
        applicationId = "dev.calorietracker.calorie_tracker"
        // Flutter's defaults: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        if (arm64OnlyApk) {
            ndk {
                abiFilters.clear()
                abiFilters.add("arm64-v8a")
            }
        }
    }

    signingConfigs {
        if (hasUploadKeystore) {
            create("release") {
                // The path and the alias are trimmed (a stray space after
                // them is never intended); the passwords are used verbatim,
                // since trailing whitespace can be part of a password and
                // trimming it would make the keystore silently un-openable.
                fun required(name: String, trim: Boolean): String =
                    keystoreProperties.getProperty(name)
                        ?.let { if (trim) it.trim() else it }
                        ?.takeIf { it.isNotEmpty() }
                        ?: throw GradleException(
                            "android/key.properties exists but has no '$name' (see docs/RELEASING.md § Google Play)",
                        )
                val store = rootProject.file(required("storeFile", trim = true))
                if (!store.exists()) {
                    throw GradleException(
                        "android/key.properties: storeFile '${store.path}' does not exist " +
                            "(the path is relative to android/)",
                    )
                }
                storeFile = store
                storePassword = required("storePassword", trim = false)
                keyAlias = required("keyAlias", trim = true)
                keyPassword = required("keyPassword", trim = false)
            }
        }
    }

    buildTypes {
        release {
            // Upload key when android/key.properties is present, otherwise the
            // debug key so `flutter run --release` keeps working for everyone.
            signingConfig =
                if (hasUploadKeystore) {
                    signingConfigs.getByName("release")
                } else {
                    signingConfigs.getByName("debug")
                }
            // R8 needs explicit keeps for WorkManager's reflective Room setup
            // (release-only startup crash without them — see proguard-rules.pro).
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

// The Play build's manifest: added to EVERY variant (debug, profile and
// release alike) as one more manifest above the main one, so its
// tools:node="remove" entries strip the photo permissions from the main
// manifest and from every library's (photo_manager declares
// READ_EXTERNAL_STORAGE). The debug and profile source-set manifests, which
// carry INTERNET for the Flutter tool, stay as they are.
androidComponents {
    onVariants { variant ->
        if (playChannel) {
            variant.sources.manifests.addStaticManifestFile(
                "src/playChannel/AndroidManifest.xml",
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    // The system Photo Picker contracts (MainActivity.pickImages) need
    // 1.7.0 or later; 1.9.0 is what the plugins already resolve.
    implementation("androidx.activity:activity-ktx:1.9.0")
    // IntakeRulesTest (src/test): MainActivity's decisions on the JVM,
    // `./gradlew :app:testDebugUnitTest` (mobile-build.yml).
    testImplementation("junit:junit:4.13.2")
}
