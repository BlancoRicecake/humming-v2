import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

apply(from = rootProject.file("auth-config.gradle"))

// Analytics는 google_app_id Android 리소스가 있어야 동작한다. 공식 설정
// 파일이 주입된 빌드에만 플러그인을 적용해 설정 없는 개발/CI 빌드는 유지한다.
if (file("google-services.json").exists()) {
    apply(plugin = "com.google.gms.google-services")
}

// Load signing config from key.properties if present (release builds).
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.humtrack.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "28.2.13676358" // Required by jni; supports the other native plugins.

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.humtrack.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24 // flutter_midi_pro requires API 24+
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // Never fall back to the debug keystore: without key.properties the
            // release variant stays unsigned and verifyReleaseSigningConfiguration
            // (below) fails the build before anything is packaged. Debug/profile
            // builds are unaffected.
            if (keystorePropertiesFile.exists()) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }
}

// Mirrors verifyReleaseAuthConfiguration (auth-config.gradle): runs for every
// Flutter release compilation (APK, AAB, flavored release variants). Never
// print keystore values.
val releaseKeystoreFile = keystorePropertiesFile
val verifyReleaseSigning = tasks.register("verifyReleaseSigningConfiguration") {
    group = "verification"
    description = "Reject release builds without android/key.properties (no debug-key fallback)."
    doLast {
        if (!releaseKeystoreFile.exists()) {
            throw GradleException(
                "android/key.properties is missing; release build blocked " +
                    "(it would otherwise be signed with the debug key). " +
                    "Provide the upload keystore configuration or build debug/profile instead."
            )
        }
        val props = Properties()
        FileInputStream(releaseKeystoreFile).use { props.load(it) }
        val required = listOf("keyAlias", "keyPassword", "storeFile", "storePassword")
        val missing = required.filter { props.getProperty(it).isNullOrBlank() }
        if (missing.isNotEmpty()) {
            throw GradleException(
                "android/key.properties is incomplete (missing: " + missing.joinToString(", ") +
                    "); release build blocked."
            )
        }
        logger.lifecycle("Release signing configuration verified (key.properties present).")
    }
}

tasks.configureEach {
    if (name.startsWith("compileFlutterBuild") && name.endsWith("Release")) {
        dependsOn(verifyReleaseSigning)
    }
}

flutter {
    source = "../.."
}
