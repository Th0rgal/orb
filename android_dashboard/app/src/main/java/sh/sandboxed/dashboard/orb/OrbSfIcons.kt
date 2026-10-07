package sh.sandboxed.dashboard.orb

import androidx.compose.foundation.Canvas
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.layout.size

/**
 * Custom vector icons matching SF Symbols used in iOS Orb (`person.crop.circle`,
 * `folder.badge.plus`, `tray.full`, `folder`, `cpu`, `cloud`, `chevron.right`, `plus`, `ellipsis`).
 */
object OrbSfIcons {

    @Composable
    fun PersonCropCircle(
        color: Color = Color.White,
        size: Dp = 20.dp,
        modifier: Modifier = Modifier
    ) {
        Canvas(modifier = modifier.size(size)) {
            val w = this.size.width
            val h = this.size.height
            val stroke = Stroke(width = w * 0.085f, cap = StrokeCap.Round, join = StrokeJoin.Round)
            // Outer circle
            drawCircle(
                color = color,
                radius = w * 0.43f,
                center = Offset(w * 0.5f, h * 0.5f),
                style = stroke
            )
            // Head
            drawCircle(
                color = color,
                radius = w * 0.15f,
                center = Offset(w * 0.5f, h * 0.39f)
            )
            // Shoulders arc
            val p = Path().apply {
                moveTo(w * 0.24f, h * 0.78f)
                cubicTo(
                    w * 0.30f, h * 0.60f,
                    w * 0.70f, h * 0.60f,
                    w * 0.76f, h * 0.78f
                )
            }
            drawPath(p, color = color, style = stroke)
        }
    }

    @Composable
    fun FolderBadgePlus(
        color: Color = Color.White,
        size: Dp = 21.dp,
        modifier: Modifier = Modifier
    ) {
        Canvas(modifier = modifier.size(size)) {
            val w = this.size.width
            val h = this.size.height
            val sw = w * 0.075f
            val stroke = Stroke(width = sw, cap = StrokeCap.Round, join = StrokeJoin.Round)

            // Folder outline
            val p = Path().apply {
                moveTo(w * 0.10f, h * 0.30f)
                lineTo(w * 0.10f, h * 0.76f)
                quadraticTo(w * 0.10f, h * 0.84f, w * 0.18f, h * 0.84f)
                lineTo(w * 0.76f, h * 0.84f)
                quadraticTo(w * 0.84f, h * 0.84f, w * 0.84f, h * 0.76f)
                lineTo(w * 0.84f, h * 0.52f)
                moveTo(w * 0.60f, h * 0.34f)
                lineTo(w * 0.44f, h * 0.34f)
                lineTo(w * 0.36f, h * 0.23f)
                lineTo(w * 0.18f, h * 0.23f)
                quadraticTo(w * 0.10f, h * 0.23f, w * 0.10f, h * 0.31f)
            }
            drawPath(p, color = color, style = stroke)

            // Badge circle at top-right
            val cx = w * 0.77f
            val cy = h * 0.31f
            val r = w * 0.17f
            drawCircle(color = Color.White, radius = r, center = Offset(cx, cy))
            // Plus cutout inside badge
            val plusStroke = Stroke(width = w * 0.065f, cap = StrokeCap.Round)
            drawLine(
                color = OrbStyle.surface,
                start = Offset(cx - r * 0.48f, cy),
                end = Offset(cx + r * 0.48f, cy),
                strokeWidth = plusStroke.width,
                cap = StrokeCap.Round
            )
            drawLine(
                color = OrbStyle.surface,
                start = Offset(cx, cy - r * 0.48f),
                end = Offset(cx, cy + r * 0.48f),
                strokeWidth = plusStroke.width,
                cap = StrokeCap.Round
            )
        }
    }

    @Composable
    fun FolderOutline(
        color: Color = OrbStyle.icon,
        size: Dp = 20.dp,
        modifier: Modifier = Modifier
    ) {
        Canvas(modifier = modifier.size(size)) {
            val w = this.size.width
            val h = this.size.height
            val sw = w * 0.082f
            val stroke = Stroke(width = sw, cap = StrokeCap.Round, join = StrokeJoin.Round)
            val path = Path().apply {
                moveTo(w * 0.09f, h * 0.29f)
                quadraticTo(w * 0.09f, h * 0.21f, w * 0.17f, h * 0.21f)
                lineTo(w * 0.37f, h * 0.21f)
                lineTo(w * 0.46f, h * 0.32f)
                lineTo(w * 0.83f, h * 0.32f)
                quadraticTo(w * 0.91f, h * 0.32f, w * 0.91f, h * 0.40f)
                lineTo(w * 0.91f, h * 0.74f)
                quadraticTo(w * 0.91f, h * 0.82f, w * 0.83f, h * 0.82f)
                lineTo(w * 0.17f, h * 0.82f)
                quadraticTo(w * 0.09f, h * 0.82f, w * 0.09f, h * 0.74f)
                close()
            }
            drawPath(path, color = color, style = stroke)
            // Subtle inner top lip line like SF Symbol "folder"
            drawLine(
                color = color,
                start = Offset(w * 0.10f, h * 0.35f),
                end = Offset(w * 0.46f, h * 0.35f),
                strokeWidth = sw * 0.85f
            )
        }
    }

    @Composable
    fun TrayFull(
        color: Color = OrbStyle.icon,
        size: Dp = 20.dp,
        modifier: Modifier = Modifier
    ) {
        Canvas(modifier = modifier.size(size)) {
            val w = this.size.width
            val h = this.size.height
            val sw = w * 0.082f
            val stroke = Stroke(width = sw, cap = StrokeCap.Round, join = StrokeJoin.Round)
            val outer = Path().apply {
                moveTo(w * 0.21f, h * 0.24f)
                lineTo(w * 0.79f, h * 0.24f)
                lineTo(w * 0.91f, h * 0.54f)
                lineTo(w * 0.91f, h * 0.75f)
                quadraticTo(w * 0.91f, h * 0.82f, w * 0.83f, h * 0.82f)
                lineTo(w * 0.17f, h * 0.82f)
                quadraticTo(w * 0.09f, h * 0.82f, w * 0.09f, h * 0.75f)
                lineTo(w * 0.09f, h * 0.54f)
                close()
            }
            drawPath(outer, color = color, style = stroke)

            val shelf = Path().apply {
                moveTo(w * 0.10f, h * 0.55f)
                lineTo(w * 0.34f, h * 0.55f)
                quadraticTo(w * 0.38f, h * 0.65f, w * 0.50f, h * 0.65f)
                quadraticTo(w * 0.62f, h * 0.65f, w * 0.66f, h * 0.55f)
                lineTo(w * 0.90f, h * 0.55f)
            }
            drawPath(shelf, color = color, style = stroke)

            drawLine(
                color = color,
                start = Offset(w * 0.28f, h * 0.39f),
                end = Offset(w * 0.72f, h * 0.39f),
                strokeWidth = sw * 0.85f,
                cap = StrokeCap.Round
            )
        }
    }

    @Composable
    fun CpuIcon(
        color: Color = OrbStyle.icon,
        size: Dp = 18.dp,
        modifier: Modifier = Modifier
    ) {
        Canvas(modifier = modifier.size(size)) {
            val w = this.size.width
            val h = this.size.height
            val sw = w * 0.08f
            val stroke = Stroke(width = sw, cap = StrokeCap.Round, join = StrokeJoin.Round)
            drawRoundRect(
                color = color,
                topLeft = Offset(w * 0.22f, h * 0.22f),
                size = Size(w * 0.56f, h * 0.56f),
                cornerRadius = CornerRadius(w * 0.10f, w * 0.10f),
                style = stroke
            )
            drawRoundRect(
                color = color,
                topLeft = Offset(w * 0.36f, h * 0.36f),
                size = Size(w * 0.28f, h * 0.28f),
                cornerRadius = CornerRadius(w * 0.05f, w * 0.05f),
                style = stroke
            )
            for (pos in listOf(0.36f, 0.64f)) {
                // Top pins
                drawLine(color, Offset(w * pos, h * 0.08f), Offset(w * pos, h * 0.22f), sw, StrokeCap.Round)
                // Bottom pins
                drawLine(color, Offset(w * pos, h * 0.78f), Offset(w * pos, h * 0.92f), sw, StrokeCap.Round)
                // Left pins
                drawLine(color, Offset(w * 0.08f, h * pos), Offset(w * 0.22f, h * pos), sw, StrokeCap.Round)
                // Right pins
                drawLine(color, Offset(w * 0.78f, h * pos), Offset(w * 0.92f, h * pos), sw, StrokeCap.Round)
            }
        }
    }

    @Composable
    fun ChevronRightSmall(
        color: Color = OrbStyle.textMuted,
        size: Dp = 11.dp,
        modifier: Modifier = Modifier
    ) {
        Canvas(modifier = modifier.size(size)) {
            val w = this.size.width
            val h = this.size.height
            val sw = w * 0.16f
            val path = Path().apply {
                moveTo(w * 0.32f, h * 0.16f)
                lineTo(w * 0.68f, h * 0.50f)
                lineTo(w * 0.32f, h * 0.84f)
            }
            drawPath(
                path = path,
                color = color,
                style = Stroke(width = sw, cap = StrokeCap.Round, join = StrokeJoin.Round)
            )
        }
    }

    @Composable
    fun TargetIcon(
        color: Color = OrbStyle.textSecondary,
        size: Dp = 10.dp,
        modifier: Modifier = Modifier
    ) {
        Canvas(modifier = modifier.size(size)) {
            val w = this.size.width
            val h = this.size.height
            val cx = w * 0.5f
            val cy = h * 0.5f
            val stroke = w * 0.11f
            drawCircle(
                color = color,
                radius = w * 0.42f,
                center = Offset(cx, cy),
                style = Stroke(width = stroke)
            )
            drawCircle(
                color = color,
                radius = w * 0.24f,
                center = Offset(cx, cy),
                style = Stroke(width = stroke)
            )
            drawCircle(
                color = color,
                radius = w * 0.09f,
                center = Offset(cx, cy)
            )
        }
    }
}
