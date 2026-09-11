package com.makr.inferno.bridge

/** Mirrors `GuestDisplayStatus` on the iOS side. */
sealed interface GuestDisplayStatus {
    data object Disconnected : GuestDisplayStatus
    data object Connecting : GuestDisplayStatus
    data class Connected(val width: Int, val height: Int) : GuestDisplayStatus
    data class Failed(val reason: String) : GuestDisplayStatus

    val size: Pair<Int, Int>?
        get() = (this as? Connected)?.let { it.width to it.height }
}
