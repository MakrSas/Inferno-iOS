package com.makr.inferno.bridge

import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * The guest's framebuffer, read where it already is.
 *
 * This is the answer to "can the display be native instead of VNC": on iOS,
 * `EmbeddedDisplay.swift` exists specifically to avoid a VNC round trip
 * through the emulator's own server on the loopback — six passes over a
 * multi-megabyte frame (compare, encode, write, read, decode, blit) just to
 * move pixels a short distance in the same address space. Android has no
 * platform reason to prefer VNC at all, so there is no VNC client here —
 * this is the only display path, not a fallback.
 *
 * The one thing the direct copy does need is a channel swap: the emulator
 * hands back little-endian a8r8g8b8 (memory order B,G,R,A — see
 * `InfernoFrameInfo` in inferno-embed.h), and Android's `ARGB_8888` bitmaps
 * are R,G,B,A in memory. `inferno_jni.cpp` does that swap in native code,
 * over the dirty rectangle only, right after the copy out of the guest's
 * surface — the one adjustment `EmbeddedDisplay.swift` doesn't need.
 */
class EmbeddedDisplay {
    private companion object {
        const val FRAME_NONE = 0
        const val FRAME_OK = 1
        const val FRAME_RESIZE = 2
        const val POLL_INTERVAL_MS = 16L // ~60 Hz, same cadence as the iOS pump
    }

    var onFrame: ((Bitmap) -> Unit)? = null
    var onStatus: ((GuestDisplayStatus) -> Unit)? = null

    @Volatile var status: GuestDisplayStatus = GuestDisplayStatus.Disconnected
        private set

    private val mainHandler = Handler(Looper.getMainLooper())
    private val info = IntArray(8) // width,height,stride,x,y,w,h,generation
    private var scratch: ByteBuffer? = null
    private var width = 0
    private var height = 0

    @Volatile private var running = false
    private var thread: Thread? = null

    fun connect() {
        if (thread != null) return
        report(GuestDisplayStatus.Connecting)
        running = true
        QemuBridge.nativeDisplayAttach()
        thread = Thread(::pump, "inferno.display").also {
            it.priority = Thread.MAX_PRIORITY
            it.start()
        }
    }

    fun disconnect() {
        running = false
        thread = null
        QemuBridge.nativeDisplayDetach()
        report(GuestDisplayStatus.Disconnected)
    }

    private fun report(new: GuestDisplayStatus) {
        status = new
        mainHandler.post { onStatus?.invoke(new) }
    }

    /** Reads at the poll rate; a pass with nothing to show costs one lock and
     *  a comparison on the native side, so polling is cheaper than arranging
     *  to be woken — same reasoning as `EmbeddedDisplay.swift`. */
    private fun pump() {
        while (running) {
            when (QemuBridge.nativeDisplayRead(scratch, info)) {
                FRAME_RESIZE -> resize(info[0], info[1])
                FRAME_OK -> publish()
                FRAME_NONE -> {}
            }
            try {
                Thread.sleep(POLL_INTERVAL_MS)
            } catch (_: InterruptedException) {
                return
            }
        }
    }

    private fun resize(w: Int, h: Int) {
        if (w <= 0 || h <= 0) return
        scratch = ByteBuffer.allocateDirect(w * h * 4).order(ByteOrder.nativeOrder())
        width = w
        height = h
        report(GuestDisplayStatus.Connected(w, h))
    }

    private fun publish() {
        val buffer = scratch ?: return
        if (width <= 0 || height <= 0) return
        buffer.rewind()
        // One copy, same as the Swift side's CGImage construction — just
        // into a mutable Bitmap instead of wrapping the buffer in place,
        // since a Bitmap's backing store isn't ours to hand out raw.
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        bitmap.copyPixelsFromBuffer(buffer)
        mainHandler.post { onFrame?.invoke(bitmap) }
    }

    // MARK: - Input

    fun sendTouch(x: Int, y: Int, pressed: Boolean) {
        if (width <= 0) return
        QemuBridge.nativeInputTouch(x, y, pressed)
    }

    fun sendFunctionKey(number: Int, pressed: Boolean) {
        QemuBridge.nativeInputFunctionKey(number, pressed)
    }
}
