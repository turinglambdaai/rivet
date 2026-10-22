import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.gradle.api.tasks.testing.Test

plugins {
    kotlin("jvm")
}

kotlin {
    compilerOptions { jvmTarget.set(JvmTarget.JVM_17) }
}

val sdkRoot = System.getenv("ANDROID_HOME") ?: System.getenv("ANDROID_SDK_ROOT") ?: ""
val platformJar = file("$sdkRoot/platforms/android-35/android.jar")
dependencies {
    implementation(project(":"))
    compileOnly(files(platformJar))
}

// JVM-only developers can run the root tests without installing Android.
tasks.named<Test>("test") { enabled = false }
tasks.named("compileKotlin") {
    doFirst { check(platformJar.isFile) { "Android SDK API 35 is required: $platformJar" } }
}
