plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.chatbot"
    compileSdk = flutter.compileSdkVersion
    // Pinned rather than using flutter.ndkVersion (28.2.13676358), because
    // llamadart ships prebuilt .so files and links fine against the NDK that
    // is already installed here.
    ndkVersion = "30.0.15729638"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.chatbot"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // llamadart's llama.cpp runtime requires API 29+.
        minSdk = 29
        targetSdk = flutter.targetSdkVersion
        // Only ship the ABIs the native runtime supports on real devices.
        ndk {
            abiFilters += listOf("arm64-v8a", "x86_64")
        }
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
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
