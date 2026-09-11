package com.makr.inferno

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import com.makr.inferno.ui.InfernoAppRoot
import com.makr.inferno.vm.VMModel

class MainActivity : ComponentActivity() {
    private val model: VMModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        installSplashScreen()
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()

        val libraryPath = VMModel.defaultLibraryPath(application)
        setContent {
            InfernoAppRoot(model = model, libraryPath = libraryPath)
        }
    }

    override fun onResume() {
        super.onResume()
        // Coming back to the foreground is exactly when the answer to "is
        // everything still there" can have changed — a file added through
        // another app, say. Mirrors RootView's onChange(of: scenePhase) on
        // iOS (which also refreshes JIT there; nothing here needs that).
        model.refreshFiles()
    }
}
