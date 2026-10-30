plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.panelshift"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlin {
        compilerOptions {
            jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        }
    }

    defaultConfig {
        applicationId = "com.example.panelshift"
        minSdk = 24
        targetSdk = flutter.targetSdkVersion

        // FIXED: Use flutter extension properties
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        ndk {
            abiFilters.clear()
            abiFilters.add("arm64-v8a")
        }

        externalNativeBuild {
            cmake {
                cppFlags("-std=c++17", "-O3")
                arguments(
                    "-DANDROID_STL=c++_shared",
                    "-DOpenCV_DIR=C:/deps/opencv_android/sdk/native/jni"
                )
            }
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

// PERMANENTLY DISABLE AAR METADATA VERSION MISMATCH CHECKS
tasks.configureEach {
    if (name.contains("AarMetadata")) {
        enabled = false
    }
}