package com.makr.inferno.vm

import android.app.Application
import android.graphics.Bitmap
import android.os.ParcelFileDescriptor
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.makr.inferno.bridge.GuestDisplayStatus
import com.makr.inferno.bridge.QemuProcess
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.io.File

/** Device buttons the machine wires to F1..F10 — identical mapping to
 *  HardwareButton in InfernoApp.swift. */
enum class HardwareButton(val functionKey: Int, val holdMillis: Long) {
    POWER(5, 2500),     // long enough for the power-off slider
    VOLUME_UP(4, 200),
    VOLUME_DOWN(3, 200),
    HOME(6, 200),
}

class VMModel(application: Application) : AndroidViewModel(application) {
    private val settingsRepo = SettingsRepository(application)
    val settings = settingsRepo.state(viewModelScope)

    var missing by mutableStateOf(VMConfig.missingFiles(application))
        private set
    var qemuState by mutableStateOf(QemuProcess.State.IDLE)
        private set
    var displayStatus by mutableStateOf<GuestDisplayStatus>(GuestDisplayStatus.Disconnected)
        private set
    var frame by mutableStateOf<Bitmap?>(null)
        private set
    var fps by mutableStateOf(0.0)
        private set
    var networkUp by mutableStateOf(false)
        private set
    /** A machine that stopped can't be started again in this process — the
     *  emulator's own globals (QOM types registered via constructors, and
     *  worse now) are not meant to survive a second qemu_init in the same
     *  one, and here "the same process" is the emulator's own child, not
     *  this app, so this is really just "don't double-launch while a
     *  previous run's process might still be exiting." */
    var hasRun by mutableStateOf(false)
        private set
    var lastError by mutableStateOf<String?>(null)
        private set

    val isRunning: Boolean get() = qemuState == QemuProcess.State.RUNNING
    val framebufferSize: Pair<Int, Int>? get() = displayStatus.size

    private val process = QemuProcess().apply {
        onStateChange = { status ->
            qemuState = status.state
            // STOPPED carries the tail of the child's stdout/stderr when it
            // exited on its own (crash, bad argv, …) rather than via a
            // clean QMP quit — see QemuProcess.readLogTail.
            if (status.state == QemuProcess.State.FAILED || status.state == QemuProcess.State.STOPPED) {
                lastError = status.message
            }
            if (status.state == QemuProcess.State.RUNNING && settings.value.network) watchNetwork()
        }
        onDisplayStatus = { status -> this@VMModel.displayStatus = status }
        onFrame = { bitmap ->
            frame = bitmap
            countFrame()
        }
    }

    private var framesThisSecond = 0
    private var fpsWindowStart = System.currentTimeMillis()
    private fun countFrame() {
        framesThisSecond++
        val now = System.currentTimeMillis()
        val elapsed = now - fpsWindowStart
        if (elapsed >= 1000) {
            fps = framesThisSecond * 1000.0 / elapsed
            framesThisSecond = 0
            fpsWindowStart = now
        }
    }

    private var networkWatch: Job? = null

    /** Held for as long as the emulator's own process might still be
     *  opening the root disk — see VMConfig.ResolvedRoot. Closed once the
     *  machine stops (in practice, for the whole run, to not race that
     *  moment: the fds only have to survive fork()+execve(), but there is no
     *  cheap, precise "execve happened" signal to close them on instead). */
    private var rootDescriptors: List<ParcelFileDescriptor> = emptyList()

    fun refreshFiles() {
        missing = VMConfig.missingFiles(getApplication())
    }

    /**
     * `execPath` is the absolute path to the emulator executable, packaged
     * as libqemu_helper.so — see ANDROID-PORT.md and
     * scripts/build-android-qemu.sh for why it's a real child process
     * rather than a library loaded into this one.
     */
    fun start(execPath: String) {
        refreshFiles()
        if (missing.isNotEmpty()) return
        lastError = null

        // Resolved here rather than inside VMConfig.arguments() because a
        // SAF-backed disk comes with a live ParcelFileDescriptor this model
        // has to keep open for the run, and — new with the separate-process
        // design — whose fd number has to be handed to ProcessLauncher so
        // it survives into the child. VMConfig only knows the path string
        // (/proc/self/fd/N) that descriptor makes valid.
        val resolvedRoot = VMConfig.resolveRootImage(getApplication())
        if (resolvedRoot == null) {
            lastError = "Диск устройства недоступен — выберите папку InfernoData заново"
            qemuState = QemuProcess.State.FAILED
            return
        }
        rootDescriptors.forEach { it.close() }
        rootDescriptors = resolvedRoot.descriptors

        hasRun = true
        val application = getApplication<Application>()
        val config = settings.value.toVMConfig()
        val args = config.arguments(application, execPath, resolvedRoot.image)
        val env = mapOf(
            "TMPDIR" to application.cacheDir.absolutePath,
            "HOME" to application.filesDir.absolutePath,
        )
        val logFile = File(application.cacheDir, "qemu-stdio.log")
        process.start(execPath, args, env, resolvedRoot.descriptors.map { it.fd }, logFile)
    }

    /** Stops the machine the only safe way there is — see QMPClient. */
    fun shutdown() {
        if (!isRunning) return
        val config = settings.value.toVMConfig()
        viewModelScope.launch {
            QMPClient.quit(config.qmpPort)
            networkWatch?.cancel()
            process.cleanup()
            rootDescriptors.forEach { it.close() }
            rootDescriptors = emptyList()
        }
    }

    override fun onCleared() {
        super.onCleared()
        // Belt and braces: shutdown() is the normal path, but the process
        // can go away without it running at all.
        process.cleanup()
        rootDescriptors.forEach { it.close() }
        rootDescriptors = emptyList()
    }

    // MARK: Network

    /**
     * Polls the emulator's own answer to "did the guest ever configure its
     * end of the link" (refreshed into the shared header by the emulator's
     * process every couple of seconds — see QemuProcess.isNetworkUp).
     * `netAutoFix`'s active half — sending `ipconfig set en0 DHCP` down the
     * guest's console the way `fixNetwork()` does on iOS — needs a working
     * serial console, which isn't ported yet; this only reports status
     * until it is.
     */
    private fun watchNetwork() {
        networkWatch?.cancel()
        networkWatch = viewModelScope.launch {
            delay(90_000) // long enough for an unhurried boot to have got there
            while (isRunning) {
                networkUp = process.isNetworkUp()
                delay(20_000)
            }
        }
    }

    /** An immediate re-check for the "Поднять сеть в госте" menu item —
     *  the periodic one in watchNetwork() only runs every 20s. */
    fun refreshNetworkStatus() {
        if (isRunning) networkUp = process.isNetworkUp()
    }

    // MARK: Input

    /**
     * Undoes the letterboxing of the aspect-fit picture: where in the
     * guest's own pixels a touch landed. Unlike `guestPoint(from:in:)` on
     * iOS, this takes coordinates already local to the drawn picture rather
     * than the whole screen minus an origin — the pointer input handler in
     * HomeScreen is attached directly to the sized `Image`, so Compose has
     * already done that subtraction by the time this is called.
     */
    private fun guestPoint(localX: Float, localY: Float, boxWidthPx: Float, boxHeightPx: Float): Pair<Int, Int>? {
        val (fbW, fbH) = framebufferSize ?: return null
        if (boxWidthPx <= 0f || boxHeightPx <= 0f) return null
        val scale = fbW / boxWidthPx
        val gx = (localX * scale).toInt().coerceIn(0, fbW - 1)
        val gy = (localY * scale).toInt().coerceIn(0, fbH - 1)
        return gx to gy
    }

    fun tap(localX: Float, localY: Float, boxWidthPx: Float, boxHeightPx: Float) {
        val (gx, gy) = guestPoint(localX, localY, boxWidthPx, boxHeightPx) ?: return
        process.sendTouch(gx, gy, pressed = true)
    }

    fun release(localX: Float, localY: Float, boxWidthPx: Float, boxHeightPx: Float) {
        val (gx, gy) = guestPoint(localX, localY, boxWidthPx, boxHeightPx) ?: return
        process.sendTouch(gx, gy, pressed = false)
    }

    fun press(button: HardwareButton) {
        process.sendFunctionKey(button.functionKey, pressed = true)
        viewModelScope.launch {
            delay(button.holdMillis)
            process.sendFunctionKey(button.functionKey, pressed = false)
        }
    }

    // MARK: Settings passthrough (persisted; see SettingsRepository)

    fun setCores(v: Int) = viewModelScope.launch { settingsRepo.setCores(v) }
    fun setMemory(v: String) = viewModelScope.launch { settingsRepo.setMemory(v) }
    fun setTcgThreads(v: String) = viewModelScope.launch { settingsRepo.setTcgThreads(v) }
    fun setTbSize(v: Int) = viewModelScope.launch { settingsRepo.setTbSize(v) }
    fun setHeadless(v: Boolean) = viewModelScope.launch { settingsRepo.setHeadless(v) }
    fun setSmoothUpscale(v: Boolean) = viewModelScope.launch { settingsRepo.setSmoothUpscale(v) }
    fun setRoundedScreen(v: Boolean) = viewModelScope.launch { settingsRepo.setRoundedScreen(v) }
    fun setShowFPS(v: Boolean) = viewModelScope.launch { settingsRepo.setShowFPS(v) }
    fun setHideKernel(v: Boolean) = viewModelScope.launch { settingsRepo.setHideKernel(v) }
    fun setTerminalFollow(v: Boolean) = viewModelScope.launch { settingsRepo.setTerminalFollow(v) }
    fun setNetwork(v: Boolean) = viewModelScope.launch { settingsRepo.setNetwork(v) }
    fun setNetAutoFix(v: Boolean) = viewModelScope.launch { settingsRepo.setNetAutoFix(v) }

    companion object {
        /** Where build-android-qemu.sh drops the cross-compiled emulator,
         *  packaged as a "library" only so the installer extracts it with
         *  the execute bit set — see ANDROID-PORT.md. */
        fun defaultLibraryPath(application: Application): String =
            File(application.applicationInfo.nativeLibraryDir, "libqemu_helper.so").path
    }
}
