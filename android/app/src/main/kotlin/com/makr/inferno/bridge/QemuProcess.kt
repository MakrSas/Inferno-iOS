package com.makr.inferno.bridge

import android.graphics.Bitmap
import android.net.LocalServerSocket
import android.net.LocalSocket
import android.os.ParcelFileDescriptor
import android.os.SharedMemory
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Runs the emulator as this app's own child process and talks to it over a
 * small shared-memory + socket protocol — see ANDROID-PORT.md for why it's
 * a separate process at all (dlopen()'d into this one, the exact same
 * library corrupts a mutex within milliseconds of qemu_init(), almost
 * certainly ART's own signal-handler chaining fighting the emulator's
 * signal-based coroutine switch; proven fine as a plain child process) and
 * include/ui/inferno-ipc.h in inferno-src for the wire protocol itself.
 *
 * There is still no VNC anywhere in this path: the shared memory is the
 * guest's own framebuffer, memcpy'd into by the emulator's process and
 * read directly out of by this one, the same "no encode, no decode, only
 * the changed rectangle" shape the in-process design had — just crossing a
 * process boundary instead of a language one.
 */
class QemuProcess {
    enum class State { IDLE, RUNNING, STOPPED, FAILED }
    data class Status(val state: State, val message: String? = null)

    var onStateChange: ((Status) -> Unit)? = null
    var onFrame: ((Bitmap) -> Unit)? = null
    var onDisplayStatus: ((GuestDisplayStatus) -> Unit)? = null

    @Volatile var status: Status = Status(State.IDLE)
        private set
    @Volatile var displayStatus: GuestDisplayStatus = GuestDisplayStatus.Disconnected
        private set

    private val mainHandler = Handler(Looper.getMainLooper())
    private var pid: Int = -1
    private var serverSocket: LocalServerSocket? = null
    private var clientSocket: LocalSocket? = null
    private var sharedMemory: SharedMemory? = null
    private var sharedBuffer: ByteBuffer? = null
    private var width = 0
    private var height = 0
    @Volatile private var running = false
    private var pumpThread: Thread? = null
    private var watchdogThread: Thread? = null
    private var logFile: File? = null

    val isRunning: Boolean get() = status.state == State.RUNNING

    /**
     * Starts the emulator. [execPath] is the real on-disk path to the
     * built executable (packaged as libqemu_helper.so — see
     * scripts/build-android-qemu.sh); [argv] is exactly what
     * VMConfig.arguments() builds, argv[0] included. [keepOpenFds] are file
     * descriptors (the guest's root disk, opened through SAF, in both
     * access modes — see VMConfig.resolveRootImage) that must survive into
     * the child at the same fd numbers — see ProcessLauncher for why plain
     * android.os.ProcessBuilder can't do this and VMConfig.arguments for
     * why the numbers have to match what's already baked into argv as
     * `-add-fd fd=N,...`.
     * [logFile], when given, gets the child's stdout and stderr combined —
     * logcat only captures this process's own output, not a forked
     * child's, so without this a crash before the IPC handshake leaves no
     * trace at all (see the comment on ProcessLauncher.nativeForkExec).
     */
    fun start(execPath: String, argv: List<String>, env: Map<String, String>, keepOpenFds: List<Int>, logFile: File? = null) {
        val socketName = "inferno_ipc_${System.nanoTime()}"
        val server = try {
            LocalServerSocket(socketName)
        } catch (e: Exception) {
            report(Status(State.FAILED, "Не удалось открыть IPC-сокет: ${e.message}"))
            return
        }
        serverSocket = server
        this.logFile = logFile

        val fullEnv = (env + mapOf("INFERNO_IPC_SOCKET" to socketName)).map { (k, v) -> "$k=$v" }
        val keepFds = keepOpenFds.toIntArray()

        val logPfd = logFile?.let {
            try {
                ParcelFileDescriptor.open(
                    it,
                    ParcelFileDescriptor.MODE_CREATE or ParcelFileDescriptor.MODE_TRUNCATE or ParcelFileDescriptor.MODE_READ_WRITE,
                )
            } catch (e: Exception) {
                Log.w("QemuProcess", "could not open log file $it: ${e.message}")
                null
            }
        }
        val logFd = logPfd?.fd ?: -1

        val newPid = ProcessLauncher.nativeForkExec(
            execPath, argv.toTypedArray(), fullEnv.toTypedArray(), keepFds, logFd, logFd,
        )
        // The child inherited its own copy of logFd at fork() — this
        // process's copy isn't needed past that point (dup2 in the child
        // already happened by the time nativeForkExec returns, since
        // fork() itself is what's concurrent, not the dup2/execve after it
        // racing this call's return... in practice the close below simply
        // drops our handle; the child keeps writing through fds 1/2 either
        // way).
        try { logPfd?.close() } catch (_: Exception) {}
        if (newPid <= 0) {
            report(Status(State.FAILED, "fork/exec не удался"))
            closeServer()
            return
        }
        pid = newPid
        running = true
        report(Status(State.RUNNING))

        Thread({ acceptAndPump(server) }, "inferno-ipc-accept").start()
        watchdogThread = Thread({ watchProcess() }, "inferno-ipc-watchdog").also { it.start() }
    }

    /** Tail of whatever the emulator printed to stdout/stderr before dying
     *  — see [start]'s logFile parameter. Empty if none was captured. */
    fun readLogTail(maxBytes: Int = 8192): String {
        val f = logFile ?: return ""
        return try {
            val bytes = f.readBytes()
            val start = (bytes.size - maxBytes).coerceAtLeast(0)
            String(bytes, start, bytes.size - start, Charsets.UTF_8)
        } catch (e: Exception) {
            ""
        }
    }

    private fun watchProcess() {
        // No portable, reliable waitpid() from this side (see
        // ProcessLauncher's notes on Android's own child-reaping) — but a
        // process that's exited stops having a /proc entry, which needs no
        // special privilege to check.
        while (running) {
            if (!File("/proc/$pid").exists()) {
                if (running) {
                    running = false
                    val tail = readLogTail()
                    if (tail.isNotBlank()) Log.e("QemuProcess", "child $pid exited; stdout/stderr tail:\n$tail")
                    report(Status(State.STOPPED, tail.takeIf { it.isNotBlank() }))
                    onDisplayStatus?.let { mainHandler.post { it(GuestDisplayStatus.Disconnected) } }
                }
                return
            }
            Thread.sleep(1000)
        }
    }

    private fun closeServer() {
        try { serverSocket?.close() } catch (_: Exception) {}
        serverSocket = null
    }

    private fun acceptAndPump(server: LocalServerSocket) {
        val client = try {
            server.accept()
        } catch (e: Exception) {
            if (running) reportDisplay(GuestDisplayStatus.Failed("IPC: не удалось принять соединение — ${e.message}"))
            return
        } finally {
            closeServer()
        }
        clientSocket = client
        reportDisplay(GuestDisplayStatus.Connecting)

        val handshake = ByteArray(1)
        val n = try {
            client.inputStream.read(handshake)
        } catch (e: Exception) {
            reportDisplay(GuestDisplayStatus.Failed("IPC: рукопожатие не удалось — ${e.message}"))
            return
        }
        val fds = client.ancillaryFileDescriptors
        if (n <= 0 || fds.isNullOrEmpty()) {
            reportDisplay(GuestDisplayStatus.Failed("IPC: гость не передал дескриптор общей памяти"))
            return
        }

        try {
            val pfd = ParcelFileDescriptor.dup(fds[0])
            val shm = SharedMemory.fromFileDescriptor(pfd)
            val buffer = shm.mapReadOnly().order(ByteOrder.nativeOrder())
            sharedMemory = shm
            sharedBuffer = buffer
            width = buffer.getInt(OFFSET_WIDTH)
            height = buffer.getInt(OFFSET_HEIGHT)
        } catch (e: Exception) {
            reportDisplay(GuestDisplayStatus.Failed("IPC: не удалось отобразить общую память — ${e.message}"))
            return
        }

        if (width <= 0 || height <= 0) {
            reportDisplay(GuestDisplayStatus.Failed("IPC: гость сообщил нулевой размер экрана"))
            return
        }
        reportDisplay(GuestDisplayStatus.Connected(width, height))

        pumpThread = Thread({ pumpFrames() }, "inferno-ipc-frames").also { it.start() }
    }

    /** Polls at the same ~60 Hz cadence the in-process design used — a pass
     *  that finds nothing new costs one int read. */
    private fun pumpFrames() {
        val buffer = sharedBuffer ?: return
        var lastGeneration = -1
        while (running) {
            val generation = buffer.getInt(OFFSET_GENERATION)
            // A publish() that returns false raced a write and copied a
            // torn frame's worth of nothing usable — leave lastGeneration
            // alone so the next tick retries against the same generation
            // instead of silently accepting the skip.
            if (generation != lastGeneration && publish(buffer)) {
                lastGeneration = generation
            }
            try {
                Thread.sleep(16)
            } catch (_: InterruptedException) {
                return
            }
        }
    }

    /** Returns false, without invoking [onFrame], if the emulator's own
     *  writer thread was touching these pixels during the copy — see
     *  write_seq's comment in inferno-ipc.h. Before this check existed,
     *  a copy caught mid-write showed up as flickering red/blue patches:
     *  part of the frame already channel-swapped, the rest still in the
     *  emulator's native (unswapped) byte order. */
    private fun publish(buffer: ByteBuffer): Boolean {
        val seqBefore = buffer.getInt(OFFSET_WRITE_SEQ)
        if (seqBefore and 1 != 0) return false

        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val pixels = buffer.duplicate().order(ByteOrder.nativeOrder())
        pixels.position(HEADER_SIZE)
        bitmap.copyPixelsFromBuffer(pixels)

        if (buffer.getInt(OFFSET_WRITE_SEQ) != seqBefore) return false

        mainHandler.post { onFrame?.invoke(bitmap) }
        return true
    }

    private fun report(new: Status) {
        status = new
        mainHandler.post { onStateChange?.invoke(new) }
    }

    private fun reportDisplay(new: GuestDisplayStatus) {
        displayStatus = new
        mainHandler.post { onDisplayStatus?.invoke(new) }
    }

    // MARK: Input — fixed 12-byte messages over the same connected socket
    // the shared-memory handshake used; see InfernoInputMsg in
    // include/ui/inferno-ipc.h.

    private fun sendInput(type: Int, pressed: Boolean, a: Int, b: Int) {
        val out = clientSocket?.outputStream ?: return
        val msg = ByteBuffer.allocate(12).order(ByteOrder.nativeOrder())
        msg.put(type.toByte())
        msg.put(if (pressed) 1.toByte() else 0.toByte())
        msg.put(0)
        msg.put(0)
        msg.putInt(a)
        msg.putInt(b)
        try {
            out.write(msg.array())
        } catch (_: Exception) {
            // The process is on its way down; the watchdog will notice.
        }
    }

    fun sendTouch(x: Int, y: Int, pressed: Boolean) = sendInput(INPUT_TOUCH, pressed, x, y)
    fun sendFunctionKey(number: Int, pressed: Boolean) = sendInput(INPUT_FUNCTION_KEY, pressed, number, 0)

    /** Mirrors inferno_net_link_up(), refreshed by the emulator's own
     *  process every couple of seconds into the shared header — there's no
     *  other way to ask now that this app isn't the one that can call that
     *  function itself. */
    fun isNetworkUp(): Boolean = sharedBuffer?.getInt(OFFSET_NETWORK_UP) != 0

    /** Tears down the IPC side once the process itself is known to be
     *  gone (after a clean QMP quit — see QMPClient — or the watchdog
     *  noticing it died some other way). Does not itself send any signal:
     *  killing this process's own child is exactly what QMP quit is for,
     *  see VMModel.shutdown. */
    fun cleanup() {
        running = false
        try { clientSocket?.close() } catch (_: Exception) {}
        closeServer()
        sharedMemory?.close()
        sharedMemory = null
        sharedBuffer = null
    }

    private companion object {
        const val OFFSET_WIDTH = 8
        const val OFFSET_HEIGHT = 12
        const val OFFSET_GENERATION = 20
        const val OFFSET_NETWORK_UP = 40
        const val OFFSET_WRITE_SEQ = 44
        const val HEADER_SIZE = 64
        const val INPUT_TOUCH = 1
        const val INPUT_FUNCTION_KEY = 2
    }
}
