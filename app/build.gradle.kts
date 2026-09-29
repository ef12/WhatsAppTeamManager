plugins { id("com.android.application"); id("org.jetbrains.kotlin.android") }
android { namespace = "nl.rkavic.manager"; compileSdk = 35
    defaultConfig { applicationId = "nl.rkavic.manager"; minSdk = 26; targetSdk = 35; versionCode = 2; versionName = "0.2" }
    signingConfigs { getByName("debug") { storeFile = file("debug.keystore") } }
    buildTypes { release { isMinifyEnabled = false } }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    kotlinOptions { jvmTarget = "17" }
}

val debugKeystore = layout.projectDirectory.file("debug.keystore").asFile
val generateDebugKeystore by tasks.registering(Exec::class) {
    outputs.file(debugKeystore)
    onlyIf { !debugKeystore.exists() }
    val keytool = File(System.getProperty("java.home"), "bin/keytool${if (System.getProperty("os.name").startsWith("Windows")) ".exe" else ""}")
    commandLine(
        keytool.absolutePath, "-genkeypair", "-keystore", debugKeystore.absolutePath,
        "-storepass", "android", "-alias", "androiddebugkey", "-keypass", "android",
        "-keyalg", "RSA", "-keysize", "2048", "-validity", "10000",
        "-dname", "CN=Android Debug,O=Android,C=US"
    )
}
tasks.matching { it.name == "validateSigningDebug" }.configureEach { dependsOn(generateDebugKeystore) }
