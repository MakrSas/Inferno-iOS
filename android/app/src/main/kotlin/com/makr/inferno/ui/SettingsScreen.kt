@file:OptIn(ExperimentalMaterial3Api::class)

package com.makr.inferno.ui

import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.makr.inferno.BuildConfig
import com.makr.inferno.R
import com.makr.inferno.vm.SettingsState
import com.makr.inferno.vm.VMModel

@Composable
fun SettingsScreen(model: VMModel, onDone: () -> Unit) {
    val settings by model.settings.collectAsStateWithLifecycle()

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.settings_title)) },
                actions = { TextButton(onClick = onDone) { Text(stringResource(R.string.action_done)) } },
            )
        },
    ) { padding ->
        Column(
            Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState()),
        ) {
            SectionHeader(stringResource(R.string.settings_screen))
            SwitchRow(stringResource(R.string.settings_rounded_screen), settings.roundedScreen, model::setRoundedScreen)
            SwitchRow(stringResource(R.string.settings_show_fps), settings.showFPS, model::setShowFPS)
            SwitchRow(stringResource(R.string.settings_smooth_upscale), settings.smoothUpscale, model::setSmoothUpscale)

            SectionHeader(stringResource(R.string.settings_terminal))
            SwitchRow(stringResource(R.string.settings_terminal_follow), settings.terminalFollow, model::setTerminalFollow)

            SectionHeader(stringResource(R.string.settings_network))
            SwitchRow(stringResource(R.string.settings_network_toggle), settings.network, model::setNetwork)
            SwitchRow(
                stringResource(R.string.settings_network_autofix),
                settings.netAutoFix,
                model::setNetAutoFix,
                enabled = settings.network,
            )

            SectionHeader(stringResource(R.string.settings_machine))
            ChoiceRow(
                label = stringResource(R.string.settings_cores),
                options = listOf(2, 3, 4, 5, 7),
                selected = settings.cores,
                optionLabel = { it.toString() },
                onSelect = model::setCores,
            )
            ChoiceRow(
                label = stringResource(R.string.settings_memory),
                options = listOf("1G", "2G", "3G", "4G"),
                selected = settings.memory,
                optionLabel = { it },
                onSelect = model::setMemory,
            )
            ChoiceRow(
                label = stringResource(R.string.settings_tcg_threads),
                options = listOf("multi", "single"),
                selected = settings.tcgThreads,
                optionLabel = { it },
                onSelect = model::setTcgThreads,
            )
            ChoiceRow(
                label = stringResource(R.string.settings_tb_size),
                options = listOf(32, 64, 128, 256),
                selected = settings.tbSize,
                optionLabel = { "$it МБ" },
                onSelect = model::setTbSize,
            )

            SectionHeader(stringResource(R.string.settings_diagnostics))
            ListItem(
                headlineContent = { Text(stringResource(R.string.settings_build)) },
                supportingContent = { Text("${BuildConfig.VERSION_NAME} (${BuildConfig.BUILD_TYPE})") },
            )
        }
    }
}

@Composable
private fun SectionHeader(title: String) {
    Text(
        text = title,
        style = MaterialTheme.typography.labelLarge,
        color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(start = 16.dp, top = 20.dp, bottom = 4.dp),
    )
    HorizontalDivider()
}

@Composable
private fun SwitchRow(title: String, checked: Boolean, onCheckedChange: (Boolean) -> Unit, enabled: Boolean = true) {
    ListItem(
        headlineContent = { Text(title) },
        trailingContent = { Switch(checked = checked, onCheckedChange = onCheckedChange, enabled = enabled) },
    )
}

@Composable
private fun <T> ChoiceRow(
    label: String,
    options: List<T>,
    selected: T,
    optionLabel: (T) -> String,
    onSelect: (T) -> Unit,
) {
    ListItem(
        headlineContent = { Text(label) },
        supportingContent = {
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(top = 6.dp)) {
                options.forEachIndexed { index, option ->
                    SegmentedButton(
                        selected = option == selected,
                        onClick = { onSelect(option) },
                        shape = SegmentedButtonDefaults.itemShape(index, options.size),
                    ) { Text(optionLabel(option)) }
                }
            }
        },
    )
}

/** Kept so preview tooling and future callers have a stable default to
 *  build against without wiring the whole ViewModel graph. */
internal val previewSettings = SettingsState()
