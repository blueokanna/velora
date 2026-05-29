allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

fun Project.ensureAndroidNamespaceFallback() {
    if (path == ":rust_lib_velora") {
        return
    }
    val configureNamespace: () -> Unit = configureNamespace@{
        val androidExtension = extensions.findByName("android") ?: return@configureNamespace
        val getNamespace = androidExtension.javaClass.methods.firstOrNull {
            it.name == "getNamespace" && it.parameterCount == 0
        } ?: return@configureNamespace
        val currentNamespace = getNamespace.invoke(androidExtension) as? String
        if (!currentNamespace.isNullOrBlank()) {
            return@configureNamespace
        }
        val manifestFile = file("src/main/AndroidManifest.xml")
        if (!manifestFile.exists()) {
            return@configureNamespace
        }
        val manifestText = manifestFile.readText()
        val manifestPackage = Regex("""package\s*=\s*\"([^\"]+)\"""")
            .find(manifestText)
            ?.groupValues
            ?.getOrNull(1)
            ?.trim()
        if (manifestPackage.isNullOrBlank()) {
            return@configureNamespace
        }
        androidExtension.javaClass.methods.firstOrNull {
            it.name == "setNamespace" &&
                it.parameterCount == 1 &&
                it.parameterTypes[0] == String::class.java
        }?.invoke(androidExtension, manifestPackage)
    }
    if (state.executed) {
        configureNamespace()
    } else {
        afterEvaluate {
            configureNamespace()
        }
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
    ensureAndroidNamespaceFallback()
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
