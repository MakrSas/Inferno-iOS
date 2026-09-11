package com.makr.inferno.vm

import android.app.Application
import android.graphics.Bitmap
import android.os.ParcelFileDescriptor
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.makr.inferno.bridge.EmbeddedDisplay
import com.makr.inferno.bridge.GuestDisplayStatus
import com.makr.inferno.bridge.QemuBridge
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
    var qemuState by mutableStateOf(QemuBridge.State.IDLE)
        private set
    var displayStatus by mutableStateOf<GuestDisplayStatus>(GuestDisplayStatus.Disconnected)
        private set
    var frame by mutableStateOf<Bitmap?>(null)
        private set
    var fps by mutableStateOf(0.0)
        private set
    var networkUp by mutableStateOf(false)
        private set
    /** QEMU is not re-entrant and lives inside this process; once a machine
     *  has run, a second one in the same process would take it down with
     *  it, so starting again means relaunching — same rule as iOS. */
    var hasRun by mutableStateOf(false)
        private set
    var lastError by mutableStateOf<String?>(null)
        private set

    val isRunning: Boolean get() = qemuState == QemuBridge.State.RUNNING
    val framebufferSize: Pair<Int, Int>? get() = displayStatus.size

    private val display = EmbeddedDisplay().apply {
        onFrame = { bitmap ->
            frame = bitmap
            countFrame()
        }
        onStatus = { status -> displayStatus = status }
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

    /** Held for as long as the machine might still be opening the root
     *  disk — see VMConfig.ResolvedRoot. Closed once QEMU has its own
     *  handle (in practice, for the whole run, to not race that moment). */
    private var rootDescriptor: ParcelFileDescriptor? = null

    fun refreshFiles() {
        missing = VMConfig.missingFiles(getApplication())
    }

    /**
     * `libraryPath` is the absolute path to `libqemu-aarch64-softmmu.so`.
     * There is nowhere to default it to yet — see ANDROID-PORT.md — so the
     * setup screen is where a build eventually offers to fetch or import
     * it, the same way it already does for the guest image files.
     */
    fun start(libraryPath: String) {
        refreshFiles()
        if (missing.isNotEmpty()) return
        lastError = null

        if (!QemuBridge.nativeIsLoaded() && !QemuBridge.nativeLoad(libraryPath)) {
            lastError = "Библиотека эмулятора не загрузилась: $libraryPath"
            qemuState = QemuBridge.State.FAILED
            return
        }

        // Resolved here rather than inside VMConfig.arguments() because a
        // SAF-backed disk comes with a live ParcelFileDescriptor this model
        // has to keep open for the run — VMConfig only knows the path
        // string (/proc/self/fd/N) that descriptor makes valid.
        val resolvedRoot = VMConfig.resolveRootImage(getApplication())
        if (resolvedRoot == null) {
            lastError = "Диск устройства недоступен — выберите папку InfernoData заново"
            qemuState = QemuBridge.State.FAILED
            return
        }
        rootDescriptor?.close()
        rootDescriptor = resolvedRoot.descriptor

        QemuBridge.onStateChange = { status ->
            qemuState = status.state
            if (status.state == QemuBridge.State.RUNNING) {
                onMachineRunning(libraryPath)
            }
            if (status.state == QemuBridge.State.FAILED) {
                lastError = status.message
            }
        }

        hasRun = true
        val config = settings.value.toVMConfig()
        val args = config.arguments(getApplication(), libraryPath, resolvedRoot.image)
        if (!QemuBridge.nativeStart(args.toTypedArray())) {
            lastError = "Не удалось запустить поток эмулятора"
            qemuState = QemuBridge.State.FAILED
        }
    }

    private fun onMachineRunning(libraryPath: String) {
        val headless = settings.value.headless
        viewModelScope.launch {
            // Give qemu_init time to open its sockets, same margin as
            // QemuBridge.swift waits before connecting the display.
            delay(1500)
            if (!headless) {
                display.connect()
            }
            if (settings.value.network) watchNetwork()
        }
    }

    /** Stops the machine the only safe way there is — see QMPClient. */
    fun shutdown() {
        if (!isRunning) return
        val config = settings.value.toVMConfig()
        viewModelScope.launch {
            QMPClient.quit(config.qmpPort)
            display.disconnect()
            networkWatch?.cancel()
            rootDescriptor?.close()
            rootDescriptor = null
        }
    }

    override fun onCleared() {
        super.onCleared()
        // Belt and braces: shutdown() is the normal path, but the process
        // can go away without it running at all.
        rootDescriptor?.close()
        rootDescriptor = null
    }

    // MARK: Network

    /**
     * Polls the emulator's own answer to "did the guest ever configure its
     * end of the link". `netAutoFix`'s active half — sending
     * `ipconfig set en0 DHCP` down the guest's console the way
     * `fixNetwork()` does on iOS — needs a working serial console, which
     * isn't ported yet; this only reports status until it is.
     */
    private fun watchNetwork() {
        networkWatch?.cancel()
        networkWatch = viewModelScope.launch {
            delay(90_000) // long enough for an unhurried boot to have got there
            while (isRunning) {
                networkUp = QemuBridge.nativeNetLinkUp()
                delay(20_000)
            }
        }
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
        display.sendTouch(gx, gy, pressed = true)
    }

    fun release(localX: Float, localY: Float, boxWidthPx: Float, boxHeightPx: Float) {
        val (gx, gy) = guestPoint(localX, localY, boxWidthPx, boxHeightPx) ?: return
        display.sendTouch(gx, gy, pressed = false)
    }

    fun press(button: HardwareButton) {
        display.sendFunctionKey(button.functionKey, pressed = true)
        viewModelScope.launch {
            delay(button.holdMillis)
            display.sendFunctionKey(button.functionKey, pressed = false)
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
        /** Where a build would drop the cross-compiled library — see
         *  ANDROID-PORT.md. Nothing places a file here yet. */
        fun defaultLibraryPath(application: Application): String =
            File(application.applicationInfo.nativeLibraryDir, "libqemu-aarch64-softmmu.so").path
    }
}
