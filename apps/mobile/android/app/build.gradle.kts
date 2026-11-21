import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Test APKs must deliberately opt into the existing Android debug certificate.
// Store builds never silently fall back to it.
val testSigning = providers.gradleProperty("partyboxTestSigning").orNull == "true"
val testTargetAbi = providers.gradleProperty("partyboxTargetAbi").orNull
if (testTargetAbi != null) {
    check(testSigning && testTargetAbi in setOf("armeabi-v7a", "arm64-v8a", "x86_64")) {
        "partyboxTargetAbi is only supported for explicitly signed test APKs."
    }
}
val keyPropertiesFile = rootProject.file("key.properties")
val keyProperties = Properties().apply {
    if (keyPropertiesFile.isFile) keyPropertiesFile.inputStream().use { load(it) }
}
val signingKeys = listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
val completeStoreSigning = signingKeys.all { !keyProperties.getProperty(it).isNullOrBlank() } &&
    rootProject.file(keyProperties.getProperty("storeFile", "missing-keystore")).isFile
// Check actual app artifacts in the resolved graph: `assemble`/`build` can
// include a release, but release unit tests alone never need a signing key.
val appProjectPath = project.path
val releaseArtifactTasks = setOf(
    "assembleRelease", "bundleRelease", "packageRelease",
    "packageReleaseBundle", "signReleaseBundle",
)
gradle.taskGraph.whenReady {
    if (!testSigning && allTasks.any {
            it.project.path == appProjectPath && it.name in releaseArtifactTasks
        }) {
        check(completeStoreSigning) {
            "Store release requires android/key.properties and an existing keystore. " +
                "For a test APK only, explicitly set -PpartyboxTestSigning=true."
        }
    }
}

android {
    namespace = "dev.partybox.prototype.partybox"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "dev.partybox.prototype.partybox"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (completeStoreSigning) {
            create("storeRelease") {
                storeFile = rootProject.file(keyProperties.getProperty("storeFile"))
                storePassword = keyProperties.getProperty("storePassword")
                keyAlias = keyProperties.getProperty("keyAlias")
                keyPassword = keyProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            if (testTargetAbi != null) {
                // Flutter 3.38 defaults plugin JNI libraries to all supported
                // ABIs even for a single --target-platform. Filter them too.
                ndk.abiFilters.clear()
                ndk.abiFilters.add(testTargetAbi)
            }
            signingConfig = when {
                testSigning -> signingConfigs.getByName("debug")
                completeStoreSigning -> signingConfigs.getByName("storeRelease")
                else -> null
            }
        }
    }
}

flutter {
    source = "../.."
}
