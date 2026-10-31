import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
}

android {
    namespace = "sh.sandboxed.dashboard"
    compileSdk = 36

    defaultConfig {
        applicationId = "sh.sandboxed.dashboard"
        minSdk = 33
        targetSdk = 36
        // Single source: android_dashboard/gradle.properties. CI may override
        // the code with -PorbVersionCode=<n> or ORB_VERSION_CODE=<n>.
        versionCode = (providers.gradleProperty("orbVersionCode").orNull
            ?: System.getenv("ORB_VERSION_CODE")?.takeIf { it.isNotBlank() }
            ?: error("orbVersionCode missing from gradle.properties")).toInt()
        versionName = providers.gradleProperty("orbVersionName").get()
        manifestPlaceholders["orbAppLabel"] = "@string/app_name"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        vectorDrawables { useSupportLibrary = true }
    }

    signingConfigs {
        create("release") {
            val ksPath = System.getenv("RELEASE_KEYSTORE")
            if (ksPath != null) {
                storeFile = file(ksPath)
                storePassword = System.getenv("RELEASE_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("RELEASE_KEY_ALIAS")
                keyPassword = System.getenv("RELEASE_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            if (System.getenv("RELEASE_KEYSTORE") != null) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
        debug {
            // Debug builds always install side by side with the release app
            // (sh.sandboxed.dashboard) so a dev APK never overwrites the
            // user's real install or its data.
            applicationIdSuffix = ".preview"
            versionNameSuffix = "-dev"
            manifestPlaceholders["orbAppLabel"] = "Orb (dev)"
            isMinifyEnabled = false
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
        resources.excludes += "/META-INF/{AL2.0,LGPL2.1}"
    }
    testOptions {
        // Robolectric-backed Compose tests (OrbSafeDrawingRootTest) need resources.
        unitTests.isIncludeAndroidResources = true
        unitTests.all {
            // Tests read the cross-platform tables in shared/orb-spec straight from the repo.
            it.systemProperty("orb.spec.dir", rootProject.file("../shared/orb-spec").absolutePath)
            it.systemProperty("java.library.path", rootProject.file("app/src/test/resources/jni").absolutePath)
            // A JVM loads liborb_kernel into one classloader only: a plain JUnit test
            // (OrbKernelTest) loading it first left Robolectric tests (OrbStreamCostTest,
            // own sandbox classloader) with "liborb_kernel JNI not loaded", depending on
            // test order. One JVM per test class keeps each load in its own classloader.
            it.forkEvery = 1
        }
    }
    lint {
        // Orb code is lint-error free; keep it that way (warnings stay warnings).
        abortOnError = true
        checkReleaseBuilds = false
        textReport = true
    }
}

kotlin {
    compilerOptions { jvmTarget.set(JvmTarget.JVM_17) }
}

dependencies {
    val composeBom = platform(libs.compose.bom)
    implementation(composeBom)
    androidTestImplementation(composeBom)

    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.biometric)
    implementation(libs.androidx.fragment.ktx)
    implementation(libs.androidx.browser)

    implementation(libs.compose.ui)
    implementation(libs.compose.ui.graphics)
    implementation(libs.compose.ui.tooling.preview)
    implementation(libs.compose.material3)
    implementation(libs.compose.material.icons.extended)

    implementation(libs.okhttp)
    implementation(libs.okhttp.sse)

    implementation(libs.kotlinx.serialization.json)
    implementation(libs.kotlinx.coroutines.android)

    debugImplementation(libs.compose.ui.tooling)
    debugImplementation(libs.compose.ui.test.manifest)

    testImplementation(libs.junit)
    testImplementation(composeBom)
    testImplementation(libs.robolectric)
    testImplementation(libs.compose.ui.test.junit4)
    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.test.ext.junit)
    androidTestImplementation(libs.androidx.test.uiautomator)
}
