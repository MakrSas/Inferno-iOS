import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
}

android {
    namespace = "com.makr.inferno"
    compileSdk = 36
    // Matches the toolchain already on this machine; the emulator's own
    // cross-compile (see ../../ANDROID-PORT.md) can pick a newer NDK for
    // itself independently — this project only builds the thin JNI bridge.
    ndkVersion = "26.3.11579264"

    defaultConfig {
        applicationId = "com.makr.inferno"
        // 28 (Pie): modern foreground-service behaviour, and every device
        // worth running a 2-4 GiB guest on is well past this anyway.
        minSdk = 28
        targetSdk = 36
        versionCode = 1
        versionName = "0.1"

        vectorDrawables.useSupportLibrary = true

        ndk {
            // arm64 only: translating arm64 guest code on x86_64 (Chromebooks,
            // emulators) would be too slow to be worth shipping. See
            // ANDROID-PORT.md ("Только arm64").
            abiFilters += "arm64-v8a"
        }

        externalNativeBuild {
            cmake {
                cppFlags += "-std=c++17"
                arguments += "-DANDROID_STL=c++_shared"
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
            isMinifyEnabled = false
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    packaging {
        // true (the old behaviour) on purpose, against AGP's own default:
        // with libs stored uncompressed and mmap'd straight out of the APK
        // (useLegacyPackaging = false, AGP's default past API 23),
        // applicationInfo.nativeLibraryDir names a directory nothing is
        // ever actually extracted into — the linker maps the library via a
        // "base.apk!/lib/..." path instead, which only System.loadLibrary()
        // (through the ClassLoader) knows how to build. QemuBridge dlopens
        // by a plain path it constructs itself (see VMModel.defaultLibraryPath),
        // so it needs a real extracted file at that path, not a virtual one.
        jniLibs.useLegacyPackaging = true
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.core.splashscreen)
    // Only for the XML window theme (Theme.Material3.DayNight.NoActionBar)
    // the Activity needs before Compose takes over — Compose's own
    // material3 artifact ships no XML resources at all.
    implementation(libs.google.material)
    implementation(libs.androidx.documentfile)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.datastore.preferences)

    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.graphics)
    implementation(libs.androidx.compose.material3)
    // Most of the icons this app uses (NetworkCheck, Tune, PowerSettingsNew,
    // FolderOpen...) live only in -extended, not the small curated -core
    // set — pulling in every Material icon there is (many thousands of
    // classes) as the price. With minification off, that dominates a debug
    // build's dex size; a real release build (minifyEnabled = true) lets
    // R8 tree-shake it down to just the icons actually referenced.
    implementation(libs.androidx.compose.material.icons.extended)
    implementation(libs.androidx.compose.foundation)
    debugImplementation(libs.androidx.compose.ui.tooling)
    implementation(libs.androidx.compose.ui.tooling.preview)
}
