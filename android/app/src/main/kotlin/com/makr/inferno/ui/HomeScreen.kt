@file:OptIn(ExperimentalMaterial3Api::class)

package com.makr.inferno.ui

import android.content.Context
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.IntOffset
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.NetworkCheck
import androidx.compose.material.icons.filled.OpenInFull
import androidx.compose.material.icons.filled.Power
import androidx.compose.material.icons.filled.PowerSettingsNew
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.input.pointer.PointerInputScope
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.makr.inferno.R
import com.makr.inferno.bridge.GuestDisplayStatus
import com.makr.inferno.bridge.QemuProcess
import com.makr.inferno.vm.HardwareButton
import com.makr.inferno.vm.VMModel
import kotlin.math.min
import kotlin.math.roundToInt

private enum class Pane { SCREEN, TERMINAL }

@Composable
fun HomeScreen(model: VMModel, libraryPath: String, onOpenSettings: () -> Unit) {
    var pane by remember { mutableStateOf(Pane.SCREEN) }
    var sheetOpen by remember { mutableStateOf(false) }
    var fullScreen by remember { mutableStateOf(false) }
    var confirmShutdown by remember { mutableStateOf(false) }

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        when (pane) {
            Pane.SCREEN -> GuestScreenView(model, fullScreen)
            Pane.TERMINAL -> TerminalScreen(model)
        }

        if (fullScreen) {
            FilledIconButton(
                onClick = { fullScreen = false },
                modifier = Modifier.align(Alignment.TopEnd).padding(12.dp),
            ) {
                Icon(Icons.Filled.OpenInFull, contentDescription = "Exit full screen")
            }
        } else {
            DraggableMenuButton(onClick = { sheetOpen = true })
        }
    }

    if (sheetOpen) {
        ModalBottomSheet(
            onDismissRequest = { sheetOpen = false },
            sheetState = rememberModalBottomSheetState(),
            // Explicit rather than relying on the theme default — this is
            // the one surface in the app that's supposed to read as a
            // rounded sheet sitting over the guest's picture.
            shape = RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp),
        ) {
            ControlSheetContent(
                model = model,
                pane = pane,
                onPaneChange = { pane = it },
                libraryPath = libraryPath,
                onOpenSettings = { sheetOpen = false; onOpenSettings() },
                onFullScreen = { sheetOpen = false; fullScreen = true },
                onShutdownRequest = { sheetOpen = false; confirmShutdown = true },
            )
        }
    }

    if (confirmShutdown) {
        AlertDialog(
            onDismissRequest = { confirmShutdown = false },
            title = { Text(stringResource(R.string.menu_shutdown_confirm_title)) },
            text = { Text(stringResource(R.string.menu_shutdown_confirm_body)) },
            confirmButton = {
                TextButton(onClick = { confirmShutdown = false; model.shutdown() }) {
                    Text(stringResource(R.string.action_shutdown))
                }
            },
            dismissButton = {
                TextButton(onClick = { confirmShutdown = false }) { Text(stringResource(R.string.action_cancel)) }
            },
        )
    }
}

private const val MENU_BUTTON_PREFS = "inferno_ui"

/**
 * The one control on screen while the guest is showing — draggable and
 * sticky, same as ControlMenu on iOS (`@AppStorage("menuX")`/`"menuY"`
 * there; a plain SharedPreferences pair here, for the same reason: it only
 * needs to survive a relaunch, not sync or query). Position is kept as a
 * fraction of the screen so it stays put across rotation and across
 * devices, and a negative value means "never moved" — rest in the default
 * bottom-trailing corner.
 */
@Composable
private fun DraggableMenuButton(onClick: () -> Unit) {
    val context = LocalContext.current
    val prefs = remember { context.getSharedPreferences(MENU_BUTTON_PREFS, Context.MODE_PRIVATE) }
    var fx by remember { mutableStateOf(prefs.getFloat("menuX", -1f)) }
    var fy by remember { mutableStateOf(prefs.getFloat("menuY", -1f)) }
    var drag by remember { mutableStateOf(Offset.Zero) }

    BoxWithConstraints(Modifier.fillMaxSize()) {
        val density = LocalDensity.current
        val widthPx = with(density) { maxWidth.toPx() }
        val heightPx = with(density) { maxHeight.toPx() }
        // Only far enough from the edge not to hang off it, same margin
        // iOS's menuPoint(in:) uses.
        val half = with(density) { (28.dp).toPx() } + with(density) { 6.dp.toPx() }
        val edge = with(density) { 10.dp.toPx() }

        val restingX = if (fx < 0f) widthPx - half - edge else fx * widthPx
        val restingY = if (fy < 0f) heightPx - half - edge else fy * heightPx

        val posX = (restingX + drag.x).coerceIn(half, widthPx - half)
        val posY = (restingY + drag.y).coerceIn(half, heightPx - half)

        FloatingActionButton(
            onClick = onClick,
            modifier = Modifier
                .offset { IntOffset((posX - half).roundToInt(), (posY - half).roundToInt()) }
                .pointerInput(widthPx, heightPx) {
                    detectDragGestures(
                        onDrag = { change, amount -> change.consume(); drag += amount },
                        onDragEnd = {
                            val landedX = (restingX + drag.x).coerceIn(half, widthPx - half)
                            val landedY = (restingY + drag.y).coerceIn(half, heightPx - half)
                            drag = Offset.Zero
                            if (widthPx > 0f && heightPx > 0f) {
                                fx = landedX / widthPx
                                fy = landedY / heightPx
                                prefs.edit().putFloat("menuX", fx).putFloat("menuY", fy).apply()
                            }
                        },
                        onDragCancel = { drag = Offset.Zero },
                    )
                },
        ) {
            Icon(Icons.Filled.Tune, contentDescription = stringResource(R.string.menu_machine))
        }
    }
}

@Composable
private fun ControlSheetContent(
    model: VMModel,
    pane: Pane,
    onPaneChange: (Pane) -> Unit,
    libraryPath: String,
    onOpenSettings: () -> Unit,
    onFullScreen: () -> Unit,
    onShutdownRequest: () -> Unit,
) {
    Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
        Text(stringResource(R.string.menu_view), style = MaterialTheme.typography.labelLarge)
        SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(vertical = 8.dp)) {
            SegmentedButton(
                selected = pane == Pane.SCREEN,
                onClick = { onPaneChange(Pane.SCREEN) },
                shape = SegmentedButtonDefaults.itemShape(0, 2),
            ) { Text(stringResource(R.string.menu_view_screen)) }
            SegmentedButton(
                selected = pane == Pane.TERMINAL,
                onClick = { onPaneChange(Pane.TERMINAL) },
                shape = SegmentedButtonDefaults.itemShape(1, 2),
            ) { Text(stringResource(R.string.menu_view_terminal)) }
        }

        HorizontalDivider(Modifier.padding(vertical = 8.dp))
        Text(stringResource(R.string.menu_machine), style = MaterialTheme.typography.labelLarge)
        Spacer(Modifier.height(8.dp))

        Button(
            onClick = { model.start(libraryPath) },
            enabled = !model.isRunning && !model.hasRun && model.missing.isEmpty(),
            modifier = Modifier.fillMaxWidth(),
        ) { Text(startLabel(model)) }

        Spacer(Modifier.height(4.dp))
        ListItem(
            headlineContent = { Text(stringResource(R.string.menu_settings)) },
            leadingContent = { Icon(Icons.Filled.Settings, contentDescription = null) },
            modifier = Modifier.clickableRow(onClick = onOpenSettings),
        )
        ListItem(
            headlineContent = { Text(stringResource(R.string.menu_fullscreen)) },
            leadingContent = { Icon(Icons.Filled.OpenInFull, contentDescription = null) },
            modifier = Modifier.clickableRow(onClick = onFullScreen),
        )
        ListItem(
            headlineContent = { Text(stringResource(R.string.menu_network_fix)) },
            leadingContent = { Icon(Icons.Filled.NetworkCheck, contentDescription = null) },
            modifier = Modifier.clickableRow(enabled = model.isRunning) { model.refreshNetworkStatus() },
        )
        ListItem(
            headlineContent = {
                Text(stringResource(R.string.menu_shutdown), color = MaterialTheme.colorScheme.error)
            },
            leadingContent = {
                Icon(Icons.Filled.Power, contentDescription = null, tint = MaterialTheme.colorScheme.error)
            },
            modifier = Modifier.clickableRow(enabled = model.isRunning, onClick = onShutdownRequest),
        )

        if (model.isRunning) {
            HorizontalDivider(Modifier.padding(vertical = 8.dp))
            Text("Кнопки устройства", style = MaterialTheme.typography.labelLarge)
            Row(
                Modifier.fillMaxWidth().padding(vertical = 8.dp),
                horizontalArrangement = Arrangement.SpaceEvenly,
            ) {
                HardwareButton.entries.forEach { button ->
                    IconButton(onClick = { model.press(button) }) {
                        Icon(Icons.Filled.PowerSettingsNew, contentDescription = button.name)
                    }
                }
            }
        }
        Spacer(Modifier.height(24.dp)) // breathing room over the gesture nav bar
    }
}

@Composable
private fun startLabel(model: VMModel): String = when {
    model.isRunning -> stringResource(R.string.menu_running)
    model.hasRun -> stringResource(R.string.menu_stopped_relaunch)
    else -> stringResource(R.string.menu_start)
}

private fun Modifier.clickableRow(enabled: Boolean = true, onClick: () -> Unit): Modifier =
    if (enabled) this.clickable(onClick = onClick) else this

/** The guest display. Touches become absolute pointer events at the
 *  emulated panel's own resolution, landing exactly where the finger is —
 *  no cursor, same contract as ScreenView on iOS. */
@Composable
private fun GuestScreenView(model: VMModel, fullScreen: Boolean) {
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val density = LocalDensity.current
        val settingsState by model.settings.collectAsStateWithLifecycle()
        val fb = model.framebufferSize
        val marginH: Dp = if (fullScreen) 0.dp else 16.dp
        val marginV: Dp = if (fullScreen) 0.dp else 24.dp

        val freeWidth = (maxWidth - marginH * 2).coerceAtLeast(1.dp)
        val freeHeight = (maxHeight - marginV * 2).coerceAtLeast(1.dp)

        val boxSize = if (fb != null && fb.first > 0 && fb.second > 0) {
            val scale = min(freeWidth.value / fb.first, freeHeight.value / fb.second)
            Dp(fb.first * scale) to Dp(fb.second * scale)
        } else {
            null
        }

        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            val bitmap = model.frame
            if (bitmap != null && boxSize != null) {
                val (boxW, boxH) = boxSize
                val cornerRadius = if (settingsState.roundedScreen) boxW * (41.5f / 414f) else 0.dp
                val boxWidthPx = with(density) { boxW.toPx() }
                val boxHeightPx = with(density) { boxH.toPx() }
                Image(
                    bitmap = bitmap.asImageBitmap(),
                    contentDescription = null,
                    modifier = Modifier
                        .size(boxW, boxH)
                        .clip(RoundedCornerShape(cornerRadius))
                        .pointerInput(fb) {
                            trackTouches(
                                onDown = { x, y -> model.tap(x, y, boxWidthPx, boxHeightPx) },
                                onMove = { x, y -> model.tap(x, y, boxWidthPx, boxHeightPx) },
                                onUp = { x, y -> model.release(x, y, boxWidthPx, boxHeightPx) },
                            )
                        },
                )
            } else {
                PlaceholderContent(model)
            }
        }
    }
}

/**
 * A raw touch tracker with no minimum distance — Compose's own
 * `detectDragGestures` waits for the pointer to clear a touch-slop before
 * calling back at all, which would silently drop every plain tap (press
 * with no movement) on the guest's panel. This mirrors
 * `DragGesture(minimumDistance: 0)` on iOS instead: every down, every move
 * while pressed, and the final up are all reported.
 */
private suspend fun PointerInputScope.trackTouches(
    onDown: (Float, Float) -> Unit,
    onMove: (Float, Float) -> Unit,
    onUp: (Float, Float) -> Unit,
) {
    awaitEachGesture {
        val down = awaitFirstDown(requireUnconsumed = false)
        down.consume()
        onDown(down.position.x, down.position.y)
        val pointerId = down.id
        while (true) {
            val event = awaitPointerEvent()
            val change = event.changes.firstOrNull { it.id == pointerId } ?: break
            change.consume()
            if (change.pressed) {
                onMove(change.position.x, change.position.y)
            } else {
                onUp(change.position.x, change.position.y)
                break
            }
        }
    }
}

@Composable
private fun PlaceholderContent(model: VMModel) {
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
        if (model.qemuState == QemuProcess.State.RUNNING) {
            CircularProgressIndicator()
        }
        Text(
            text = placeholderText(model),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.8f),
        )
    }
}

@Composable
private fun placeholderText(model: VMModel): String = when (model.qemuState) {
    QemuProcess.State.IDLE -> stringResource(R.string.placeholder_open_menu)
    QemuProcess.State.RUNNING -> when (val status = model.displayStatus) {
        is GuestDisplayStatus.Connected ->
            stringResource(R.string.placeholder_boot_wait, status.width, status.height)
        is GuestDisplayStatus.Failed -> stringResource(R.string.placeholder_failed, status.reason)
        GuestDisplayStatus.Connecting, GuestDisplayStatus.Disconnected ->
            stringResource(R.string.placeholder_connecting)
    }
    QemuProcess.State.STOPPED -> stringResource(R.string.placeholder_stopped)
    QemuProcess.State.FAILED -> model.lastError ?: stringResource(R.string.placeholder_stopped)
}
