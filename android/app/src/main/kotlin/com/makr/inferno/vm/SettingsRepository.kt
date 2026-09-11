package com.makr.inferno.vm

import android.content.Context
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn

private val Context.dataStore by preferencesDataStore(name = "settings")

/** Everything the user can change without a rebuild — the same knobs
 *  Settings.swift exposes, other than the ones that only exist because of
 *  iOS's platform restrictions (builtInDisplay is not a choice here: it's
 *  the only display path; there is no JIT toggle to diagnose). */
data class SettingsState(
    val cores: Int = 4,
    val memory: String = "3G",
    val tcgThreads: String = "multi",
    val tbSize: Int = 128,
    val headless: Boolean = false,
    val smoothUpscale: Boolean = true,
    val roundedScreen: Boolean = true,
    val showFPS: Boolean = false,
    val hideKernel: Boolean = true,
    val terminalFollow: Boolean = true,
    val network: Boolean = true,
    val netAutoFix: Boolean = true,
) {
    fun toVMConfig() = VMConfig(
        cores = cores,
        memory = memory,
        tcgThreads = tcgThreads,
        tbSize = tbSize,
        network = network,
        headless = headless,
    )
}

class SettingsRepository(private val context: Context) {
    private object Keys {
        val CORES = intPreferencesKey("cores")
        val MEMORY = stringPreferencesKey("memory")
        val TCG_THREADS = stringPreferencesKey("tcgThreads")
        val TB_SIZE = intPreferencesKey("tbSize")
        val HEADLESS = booleanPreferencesKey("headless")
        val SMOOTH_UPSCALE = booleanPreferencesKey("smoothUpscale")
        val ROUNDED_SCREEN = booleanPreferencesKey("roundedScreen")
        val SHOW_FPS = booleanPreferencesKey("showFPS")
        val HIDE_KERNEL = booleanPreferencesKey("hideKernel")
        val TERMINAL_FOLLOW = booleanPreferencesKey("terminalFollow")
        val NETWORK = booleanPreferencesKey("network")
        val NET_AUTO_FIX = booleanPreferencesKey("netAutoFix")
    }

    private val defaults = SettingsState()

    /** A hot, always-current snapshot for callers that just want to read
     *  (building the argv at start time, say) without collecting a Flow. */
    fun state(scope: CoroutineScope): StateFlow<SettingsState> =
        context.dataStore.data
            .map { prefs ->
                SettingsState(
                    cores = prefs[Keys.CORES] ?: defaults.cores,
                    memory = prefs[Keys.MEMORY] ?: defaults.memory,
                    tcgThreads = prefs[Keys.TCG_THREADS] ?: defaults.tcgThreads,
                    tbSize = prefs[Keys.TB_SIZE] ?: defaults.tbSize,
                    headless = prefs[Keys.HEADLESS] ?: defaults.headless,
                    smoothUpscale = prefs[Keys.SMOOTH_UPSCALE] ?: defaults.smoothUpscale,
                    roundedScreen = prefs[Keys.ROUNDED_SCREEN] ?: defaults.roundedScreen,
                    showFPS = prefs[Keys.SHOW_FPS] ?: defaults.showFPS,
                    hideKernel = prefs[Keys.HIDE_KERNEL] ?: defaults.hideKernel,
                    terminalFollow = prefs[Keys.TERMINAL_FOLLOW] ?: defaults.terminalFollow,
                    network = prefs[Keys.NETWORK] ?: defaults.network,
                    netAutoFix = prefs[Keys.NET_AUTO_FIX] ?: defaults.netAutoFix,
                )
            }
            .stateIn(scope, SharingStarted.Eagerly, defaults)

    suspend fun setCores(value: Int) = context.dataStore.edit { it[Keys.CORES] = value }
    suspend fun setMemory(value: String) = context.dataStore.edit { it[Keys.MEMORY] = value }
    suspend fun setTcgThreads(value: String) = context.dataStore.edit { it[Keys.TCG_THREADS] = value }
    suspend fun setTbSize(value: Int) = context.dataStore.edit { it[Keys.TB_SIZE] = value }
    suspend fun setHeadless(value: Boolean) = context.dataStore.edit { it[Keys.HEADLESS] = value }
    suspend fun setSmoothUpscale(value: Boolean) = context.dataStore.edit { it[Keys.SMOOTH_UPSCALE] = value }
    suspend fun setRoundedScreen(value: Boolean) = context.dataStore.edit { it[Keys.ROUNDED_SCREEN] = value }
    suspend fun setShowFPS(value: Boolean) = context.dataStore.edit { it[Keys.SHOW_FPS] = value }
    suspend fun setHideKernel(value: Boolean) = context.dataStore.edit { it[Keys.HIDE_KERNEL] = value }
    suspend fun setTerminalFollow(value: Boolean) = context.dataStore.edit { it[Keys.TERMINAL_FOLLOW] = value }
    suspend fun setNetwork(value: Boolean) = context.dataStore.edit { it[Keys.NETWORK] = value }
    suspend fun setNetAutoFix(value: Boolean) = context.dataStore.edit { it[Keys.NET_AUTO_FIX] = value }
}
