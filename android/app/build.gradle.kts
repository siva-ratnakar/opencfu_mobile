plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Path to the OpenCV Android SDK's CMake package (<sdk>/sdk/native/jni).
// Set it in android/gradle.properties or on the command line:
//   flutter build apk -POpenCV_DIR=/abs/path/to/OpenCV-android-sdk/sdk/native/jni
// When it is absent the native OpenCFU library is NOT built and the Dart layer
// falls back to reporting that the engine is unavailable, so the app still runs.
val openCvDir: String? = (project.findProperty("OpenCV_DIR") as String?)?.takeIf { it.isNotBlank() }

android {
    namespace = "com.example.opencfu_mobile"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.opencfu_mobile"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // OpenCV requires a modern API level; FFI and the camera plugin are fine here.
        minSdk = maxOf(flutter.minSdkVersion, 24)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        if (openCvDir != null) {
            externalNativeBuild {
                cmake {
                    cppFlags += "-std=c++14"
                    arguments += "-DOpenCV_DIR=$openCvDir"
                    arguments += "-DANDROID_STL=c++_shared"
                }
            }
            ndk {
                abiFilters += listOf("arm64-v8a", "armeabi-v7a", "x86_64")
            }
        }
    }

    if (openCvDir != null) {
        externalNativeBuild {
            cmake {
                path = file("../../native/opencfu_core/CMakeLists.txt")
                version = "3.22.1"
            }
        }
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
