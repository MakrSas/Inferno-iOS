package com.makr.inferno.vm

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.net.InetSocketAddress
import java.net.Socket

/**
 * Talks to the emulator's QMP socket — just enough to ask it to quit.
 *
 * This is the only safe way to stop the machine. `quit` unwinds QEMU's main
 * loop, which flushes the block layer to the files; killing the process
 * instead leaves qcow2 metadata half-written, and the guest's disk then
 * disagrees with the Secure Enclave's replay counters — a mismatch the
 * guest answers with a SEP panic on the next boot. Same reasoning as
 * QMPClient.swift, minus the inspection commands, which need a Terminal
 * pane to show their output in and aren't wired up yet on this platform.
 */
object QMPClient {
    suspend fun quit(port: Int): String = withContext(Dispatchers.IO) {
        try {
            Socket().use { socket ->
                socket.connect(InetSocketAddress("127.0.0.1", port), 2000)
                socket.soTimeout = 3000
                val out = socket.getOutputStream()
                val reader = socket.getInputStream().bufferedReader()

                if (reader.readLine() == null) return@withContext "Выключение: приветствия от QMP нет"
                out.write("{\"execute\":\"qmp_capabilities\"}\n".toByteArray())
                out.flush()
                if (reader.readLine() == null) return@withContext "Выключение: команда не ушла"
                out.write("{\"execute\":\"quit\"}\n".toByteArray())
                out.flush()
                // The reply may never arrive: QEMU acts on quit and exits.
                runCatching { reader.readLine() }
                "Выключение: команда отправлена, машина сбрасывает диски на файлы"
            }
        } catch (e: Exception) {
            "Выключение: ${e.message ?: e::class.simpleName}"
        }
    }
}
