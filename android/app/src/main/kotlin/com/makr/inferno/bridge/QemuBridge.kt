package com.makr.inferno.bridge

import android.os.Handler
import android.os.Looper
import java.nio.ByteBuffer

/**
 * Loads the Inferno emulator library and drives its lifecycle.
 *
 * Android has no equivalent of iOS's ban on writable+executable memory, so
 * there is no split-wx, no `brk #0x69` handshake with a debugger, and no
 * libucontext workaround — this bridge is the whole story. The library is
 * `dlopen`'d (mirroring `QemuBridge.swift`'s own approach almost exactly)
 * rather than linked at build time, because the .so this app actually needs
 * — `libqemu-aarch64-softmmu.so`, cross-compiled per ANDROID-PORT.md — does
 * not exist yet; the JNI glue below (`inferno_jni.cpp`) is real today and
 * will pick it up unchanged once it does.
 *
 * `qemu_init` returns with QEMU's big lock held and `qemu_main_loop` expects
 * to be entered that way, so both run on one native thread spawned inside
 * `nativeStart`, never on a Kotlin-managed thread.
 */
object QemuBridge {
    init { System.loadLibrary("inferno_jni") }

    enum class State { IDLE, RUNNING, STOPPED, FAILED }

    data class Status(val state: State, val exitCode: Int = 0, val message: String? = null)

    @Volatile var status: Status = Status(State.IDLE)
        private set

    /** Delivered on the main thread, like `QemuBridge.swift`'s `onStateChange`. */
    var onStateChange: ((Status) -> Unit)? = null

    private val mainHandler = Handler(Looper.getMainLooper())

    /** Loads `libqemu-aarch64-softmmu.so` from an absolute path and resolves
     *  `qemu_init`/`qemu_main_loop`/`qemu_cleanup`. False means the library
     *  is missing or doesn't export them — the setup screen's job to say so. */
    external fun nativeLoad(libraryPath: String): Boolean

    /** True once [nativeLoad] has resolved every symbol this bridge needs. */
    external fun nativeIsLoaded(): Boolean

    /** Starts the emulator on its own native thread. Returns immediately;
     *  the outcome arrives through [onStateChange]. */
    external fun nativeStart(argv: Array<String>): Boolean

    /** Looks up one of the emulator's other exported entry points
     *  (`inferno_net_link_up` and friends) — mirrors `QemuBridge.symbol()`. */
    external fun nativeHasSymbol(name: String): Boolean

    external fun nativeDisplayAttach()
    external fun nativeDisplayDetach()
    external fun nativeDisplayInvalidate()

    /**
     * Copies whatever the guest redrew into `dst` (a direct [ByteBuffer]
     * holding one whole frame, a8r8g8b8). `info` receives, in order:
     * width, height, stride, x, y, w, h, generation — the same eight
     * `uint32` fields `InfernoFrameInfo` packs on the C side.
     * Returns 0 (none), 1 (ok) or 2 (resize), matching `InfernoFrameResult`.
     */
    external fun nativeDisplayRead(dst: ByteBuffer?, info: IntArray): Int

    external fun nativeInputTouch(x: Int, y: Int, pressed: Boolean)
    external fun nativeInputFunctionKey(number: Int, pressed: Boolean)
    external fun nativeNetLinkUp(): Boolean

    /**
     * Called from the emulator's native thread via a cached `JNIEnv` method
     * ID; hops to the main thread before anyone sees it, same as the Swift
     * bridge's `set(_:)`. Left with default (public) visibility rather than
     * `private` or `internal` on purpose — `internal` gets a mangled JVM
     * name and `private` an access check, and either would break the plain
     * `GetMethodID(env, class, "onNativeStateChange", ...)` lookup in
     * inferno_jni.cpp. Not part of the bridge's real API; don't call it from
     * Kotlin.
     */
    @Suppress("unused") // invoked by inferno_jni.cpp via JNI
    fun onNativeStateChange(stateOrdinal: Int, exitCode: Int, message: String?) {
        val newStatus = Status(State.entries[stateOrdinal], exitCode, message)
        status = newStatus
        mainHandler.post { onStateChange?.invoke(newStatus) }
    }
}
