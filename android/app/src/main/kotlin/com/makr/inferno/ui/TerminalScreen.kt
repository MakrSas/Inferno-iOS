package com.makr.inferno.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import com.makr.inferno.vm.VMConfig
import com.makr.inferno.vm.VMModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.RandomAccessFile

/**
 * The guest's boot log — the one thing this platform can show today without
 * a ported shell channel or VT100 emulator (Terminal.swift and
 * ShellChannel.swift are the two biggest pieces of the iOS app that haven't
 * crossed over yet). QEMU writes the console to a plain file
 * (`-chardev socket,...,logfile=...`, see VMConfig.arguments), so this tails
 * that file the same way SerialConsole.swift's `poll()` does, just without
 * the escape-code-aware terminal grid on top of it or a way to type back.
 */
@Composable
fun TerminalScreen(model: VMModel) {
    val context = LocalContext.current
    var text by remember { mutableStateOf("") }
    val scroll = rememberScrollState()
    val scope = rememberCoroutineScope()

    LaunchedEffect(Unit) {
        val file = VMConfig.guestConsoleLog(context)
        var position = 0L
        val limit = 256 * 1024
        while (isActive) {
            if (file.exists() && file.length() > position) {
                val chunk = withContext(Dispatchers.IO) {
                    RandomAccessFile(file, "r").use { raf ->
                        raf.seek(position)
                        val bytes = ByteArray((raf.length() - position).toInt())
                        raf.readFully(bytes)
                        position = raf.length()
                        String(bytes, Charsets.UTF_8)
                    }
                }
                text = (text + chunk).let { if (it.length > limit) it.takeLast(limit) else it }
                scope.launch { scroll.animateScrollTo(scroll.maxValue) }
            }
            delay(500)
        }
    }

    Box(Modifier.fillMaxSize().safeDrawingPadding().padding(12.dp)) {
        if (text.isEmpty()) {
            Text(
                text = "Ожидание вывода консоли…",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.align(Alignment.TopStart),
            )
        } else {
            SelectionContainer {
                Text(
                    text = text,
                    fontFamily = FontFamily.Monospace,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onBackground,
                    modifier = Modifier.verticalScroll(scroll),
                )
            }
        }
    }
}
