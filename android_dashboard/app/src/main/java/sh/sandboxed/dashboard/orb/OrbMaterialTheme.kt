package sh.sandboxed.dashboard.orb

import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Shapes
import androidx.compose.ui.unit.dp
import androidx.compose.ui.graphics.Color
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

private val DarkColors = darkColorScheme(
    primary = OrbStyle.textPrimary,
    onPrimary = OrbStyle.background,
    primaryContainer = OrbStyle.elevated,
    onPrimaryContainer = OrbStyle.textPrimary,
    secondary = OrbStyle.textSecondary,
    onSecondary = OrbStyle.background,
    secondaryContainer = OrbStyle.card,
    onSecondaryContainer = OrbStyle.textPrimary,
    tertiary = OrbStyle.textSecondary,
    onTertiary = OrbStyle.background,
    tertiaryContainer = OrbStyle.elevated,
    onTertiaryContainer = OrbStyle.textPrimary,
    background = OrbStyle.background,
    onBackground = Color(0xFFEDEDED),
    surface = OrbStyle.surface,
    onSurface = Color(0xFFEDEDED),
    surfaceVariant = OrbStyle.card,
    onSurfaceVariant = Color(0xCCFFFFFF),
    surfaceTint = OrbStyle.textPrimary,
    surfaceDim = OrbStyle.background,
    surfaceBright = OrbStyle.elevated,
    surfaceContainerLowest = OrbStyle.background,
    surfaceContainerLow = OrbStyle.surface,
    surfaceContainer = OrbStyle.card,
    surfaceContainerHigh = OrbStyle.elevated,
    surfaceContainerHighest = OrbStyle.elevated,
    error = Color(0xFFEF4444),
    outline = OrbStyle.borderStrong,
)

private val AppTypography = Typography(
    headlineSmall = TextStyle(fontFamily = FontFamily.SansSerif, fontWeight = FontWeight.SemiBold, fontSize = 22.sp),
    titleLarge = TextStyle(fontFamily = FontFamily.SansSerif, fontWeight = FontWeight.SemiBold, fontSize = 20.sp),
    titleMedium = TextStyle(fontFamily = FontFamily.SansSerif, fontWeight = FontWeight.Medium, fontSize = 16.sp),
    titleSmall = TextStyle(fontFamily = FontFamily.SansSerif, fontWeight = FontWeight.Medium, fontSize = 14.sp),
    bodyLarge = TextStyle(fontFamily = FontFamily.SansSerif, fontSize = 16.sp, lineHeight = 22.sp),
    bodyMedium = TextStyle(fontFamily = FontFamily.SansSerif, fontSize = 14.sp, lineHeight = 20.sp),
    bodySmall = TextStyle(fontFamily = FontFamily.SansSerif, fontSize = 12.sp, lineHeight = 16.sp),
    labelLarge = TextStyle(fontFamily = FontFamily.SansSerif, fontWeight = FontWeight.Medium, fontSize = 14.sp),
    labelMedium = TextStyle(fontFamily = FontFamily.SansSerif, fontWeight = FontWeight.Medium, fontSize = 12.sp),
)

@Composable
fun OrbMaterialTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = DarkColors,
        typography = AppTypography,
        shapes = Shapes(
            extraSmall = RoundedCornerShape(OrbStyle.controlRadius),
            small = RoundedCornerShape(OrbStyle.controlRadius),
            medium = RoundedCornerShape(OrbStyle.panelRadius),
            large = RoundedCornerShape(OrbStyle.panelRadius),
            extraLarge = RoundedCornerShape(16.dp),
        ),
        content = content,
    )
}
