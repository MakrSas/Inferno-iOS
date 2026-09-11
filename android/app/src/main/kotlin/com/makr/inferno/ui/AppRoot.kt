package com.makr.inferno.ui

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import com.makr.inferno.ui.theme.InfernoTheme
import com.makr.inferno.vm.VMModel

/**
 * Setup → Home → (optionally) Settings, as a small manual stack rather than
 * pulling in Navigation-Compose for three destinations. `Settings` sits
 * beside `Home` rather than inside it so opening it fully replaces the
 * screen — closer to how SettingsView is presented as a sheet on iOS than
 * to a cramped in-place panel.
 */
@Composable
fun InfernoAppRoot(model: VMModel, libraryPath: String) {
    InfernoTheme {
        Surface(modifier = Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
            var showSettings by remember { mutableStateOf(false) }
            when {
                model.missing.isNotEmpty() -> SetupScreen(model)
                showSettings -> SettingsScreen(model, onDone = { showSettings = false })
                else -> HomeScreen(model, libraryPath, onOpenSettings = { showSettings = true })
            }
        }
    }
}
