package com.makr.inferno.ui.theme

import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext

/**
 * The seed is the same blue as the app icon's gradient (see
 * app/Resources/Inferno.icon/Assets/SVG Image 5.svg on the iOS side) — the
 * one piece of brand identity shared between the two platforms.
 */
private val Seed = Color(0xFF508CC8)

private val LightColors = lightColorScheme(
    primary = Seed,
    secondary = Color(0xFF6EA9E6),
)

private val DarkColors = darkColorScheme(
    primary = Color(0xFF9FCBFF),
    secondary = Color(0xFF6EA9E6),
)

/**
 * Material You dynamic color on 12+, the fixed blue scheme everywhere else.
 * Unlike the iOS app — which locks itself to dark because the guest's own
 * picture is the only thing worth looking at — this follows the system's
 * light/dark choice like any other Material 3 app.
 */
@Composable
fun InfernoTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    dynamicColor: Boolean = true,
    content: @Composable () -> Unit,
) {
    val context = LocalContext.current
    val colorScheme = when {
        dynamicColor && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S ->
            if (darkTheme) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        darkTheme -> DarkColors
        else -> LightColors
    }

    MaterialTheme(
        colorScheme = colorScheme,
        typography = InfernoTypography,
        content = content,
    )
}
