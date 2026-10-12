package sh.sandboxed.dashboard.orb

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathFillType
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.PathParser
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

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

private val providerVectorPaths: Map<String, List<String>> = mapOf(
    "anthropic" to listOf(
        "M13.827 3.52h3.603L24 20h-3.603l-6.57-16.48zm-7.258 0h3.767L16.906 20h-3.674l-1.343-3.461H5.017l-1.344 3.46H0L6.57 3.522zm4.132 9.959L8.453 7.687 6.205 13.48H10.7z"
    ),
    "cursor" to listOf(
        "M22.106 5.68L12.5.135a.998.998 0 00-.998 0L1.893 5.68a.84.84 0 00-.419.726v11.186c0 .3.16.577.42.727l9.607 5.547a.999.999 0 00.998 0l9.608-5.547a.84.84 0 00.42-.727V6.407a.84.84 0 00-.42-.726zm-.603 1.176L12.228 22.92c-.063.108-.228.064-.228-.061V12.34a.59.59 0 00-.295-.51l-9.11-5.26c-.107-.062-.063-.228.062-.228h18.55c.264 0 .428.286.296.514z"
    ),
    "google" to listOf(
        "M12.24 10.285V14.4h6.806c-.275 1.765-2.056 5.174-6.806 5.174-4.095 0-7.439-3.389-7.439-7.574s3.345-7.574 7.439-7.574c2.33 0 3.891.989 4.785 1.849l3.254-3.138C18.189 1.186 15.479 0 12.24 0c-6.635 0-12 5.365-12 12s5.365 12 12 12c6.926 0 11.52-4.869 11.52-11.726 0-.788-.085-1.39-.189-1.989H12.24z"
    ),
    "grok" to listOf(
        "M9.27 15.29l7.978-5.897c.391-.29.95-.177 1.137.272.98 2.369.542 5.215-1.41 7.169-1.951 1.954-4.667 2.382-7.149 1.406l-2.711 1.257c3.889 2.661 8.611 2.003 11.562-.953 2.341-2.344 3.066-5.539 2.388-8.42l.006.007c-.983-4.232.242-5.924 2.75-9.383.06-.082.12-.164.179-.248l-3.301 3.305v-.01L9.267 15.292M7.623 16.723c-2.792-2.67-2.31-6.801.071-9.184 1.761-1.763 4.647-2.483 7.166-1.425l2.705-1.25a7.808 7.808 0 00-1.829-1A8.975 8.975 0 005.984 5.83c-2.533 2.536-3.33 6.436-1.962 9.764 1.022 2.487-.653 4.246-2.34 6.022-.599.63-1.199 1.259-1.682 1.925l7.62-6.815"
    ),
    "kimi" to listOf(
        "M21.846 0a1.923 1.923 0 110 3.846H20.15a.226.226 0 01-.227-.226V1.923C19.923.861 20.784 0 21.846 0z",
        "M11.065 11.199l7.257-7.2c.137-.136.06-.41-.116-.41H14.3a.164.164 0 00-.117.051l-7.82 7.756c-.122.12-.302.013-.302-.179V3.82c0-.127-.083-.23-.185-.23H3.186c-.103 0-.186.103-.186.23V19.77c0 .128.083.23.186.23h2.69c.103 0 .186-.102.186-.23v-3.25c0-.069.025-.135.069-.178l2.424-2.406a.158.158 0 01.205-.023l6.484 4.772a7.677 7.677 0 003.453 1.283c.108.012.2-.095.2-.23v-3.06c0-.117-.07-.212-.164-.227a5.028 5.028 0 01-2.027-.807l-5.613-4.064c-.117-.078-.132-.279-.028-.381z"
    ),
    "meta" to listOf(
        "M6.897 4c1.915 0 3.516.932 5.43 3.376l.282-.373c.19-.246.383-.484.58-.71l.313-.35C14.588 4.788 15.792 4 17.225 4c1.273 0 2.469.557 3.491 1.516l.218.213c1.73 1.765 2.917 4.71 3.053 8.026l.011.392.002.25c0 1.501-.28 2.759-.818 3.7l-.14.23-.108.153c-.301.42-.664.758-1.086 1.009l-.265.142-.087.04a3.493 3.493 0 01-.302.118 4.117 4.117 0 01-1.33.208c-.524 0-.996-.067-1.438-.215-.614-.204-1.163-.56-1.726-1.116l-.227-.235c-.753-.812-1.534-1.976-2.493-3.586l-1.43-2.41-.544-.895-1.766 3.13-.343.592C7.597 19.156 6.227 20 4.356 20c-1.21 0-2.205-.42-2.936-1.182l-.168-.184c-.484-.573-.837-1.311-1.043-2.189l-.067-.32a8.69 8.69 0 01-.136-1.288L0 14.468c.002-.745.06-1.49.174-2.23l.1-.573c.298-1.53.828-2.958 1.536-4.157l.209-.34c1.177-1.83 2.789-3.053 4.615-3.16L6.897 4zm-.033 2.615l-.201.01c-.83.083-1.606.673-2.252 1.577l-.138.199-.01.018c-.67 1.017-1.185 2.378-1.456 3.845l-.004.022a12.591 12.591 0 00-.207 2.254l.002.188c.004.18.017.36.04.54l.043.291c.092.503.257.908.486 1.208l.117.137c.303.323.698.492 1.17.492 1.1 0 1.796-.676 3.696-3.641l2.175-3.4.454-.701-.139-.198C9.11 7.3 8.084 6.616 6.864 6.616zm10.196-.552l-.176.007c-.635.048-1.223.359-1.82.933l-.196.198c-.439.462-.887 1.064-1.367 1.807l.266.398c.18.274.362.56.55.858l.293.475 1.396 2.335.695 1.114c.583.926 1.03 1.6 1.408 2.082l.213.262c.282.326.529.54.777.673l.102.05c.227.1.457.138.718.138.176.002.35-.023.518-.073.338-.104.61-.32.813-.637l.095-.163.077-.162c.194-.459.29-1.06.29-1.785l-.006-.449c-.08-2.871-.938-5.372-2.2-6.798l-.176-.189c-.67-.683-1.444-1.074-2.27-1.074z"
    ),
    "minimax" to listOf(
        "M16.278 2c1.156 0 2.093.927 2.093 2.07v12.501a.74.74 0 00.744.709.74.74 0 00.743-.709V9.099a2.06 2.06 0 012.071-2.049A2.06 2.06 0 0124 9.1v6.561a.649.649 0 01-.652.645.649.649 0 01-.653-.645V9.1a.762.762 0 00-.766-.758.762.762 0 00-.766.758v7.472a2.037 2.037 0 01-2.048 2.026 2.037 2.037 0 01-2.048-2.026v-12.5a.785.785 0 00-.788-.753.785.785 0 00-.789.752l-.001 15.904A2.037 2.037 0 0113.441 22a2.037 2.037 0 01-2.048-2.026V18.04c0-.356.292-.645.652-.645.36 0 .652.289.652.645v1.934c0 .263.142.506.372.638.23.131.514.131.744 0a.734.734 0 00.372-.638V4.07c0-1.143.937-2.07 2.093-2.07zm-5.674 0c1.156 0 2.093.927 2.093 2.07v11.523a.648.648 0 01-.652.645.648.648 0 01-.652-.645V4.07a.785.785 0 00-.789-.78.785.785 0 00-.789.78v14.013a2.06 2.06 0 01-2.07 2.048 2.06 2.06 0 01-2.071-2.048V9.1a.762.762 0 00-.766-.758.762.762 0 00-.766.758v3.8a2.06 2.06 0 01-2.071 2.049A2.06 2.06 0 010 12.9v-1.378c0-.357.292-.646.652-.646.36 0 .653.29.653.646V12.9c0 .418.343.757.766.757s.766-.339.766-.757V9.099a2.06 2.06 0 012.07-2.048 2.06 2.06 0 012.071 2.048v8.984c0 .419.343.758.767.758.423 0 .766-.339.766-.758V4.07c0-1.143.937-2.07 2.093-2.07z"
    ),
    "mistral" to listOf(
        "M3.428 3.4h3.429v3.4h3.429v3.4h3.428V6.8h3.429V3.4h3.429v13.6h3.428v3.4h-6.857v-3.4h3.428v-3.4h-3.428v3.4h-3.429v-3.4H6.857v3.4h3.429v3.4H3.428v-3.4h3.429V3.4H3.428zM0 17h3.428v3.4H0V17z"
    ),
    "nvidia" to listOf(
        "M10.212 8.976V7.62c.127-.01.256-.017.388-.021 3.596-.117 5.957 3.184 5.957 3.184s-2.548 3.647-5.282 3.647a3.227 3.227 0 01-1.063-.175v-4.109c1.4.174 1.681.812 2.523 2.258l1.873-1.627a4.905 4.905 0 00-3.67-1.846 6.594 6.594 0 00-.729.044m0-4.476v2.025c.13-.01.259-.019.388-.024 5.002-.174 8.261 4.226 8.261 4.226s-3.743 4.69-7.643 4.69c-.338 0-.675-.031-1.007-.092v1.25c.278.038.558.057.838.057 3.629 0 6.253-1.91 8.794-4.169.421.347 2.146 1.193 2.501 1.564-2.416 2.083-8.048 3.763-11.24 3.763-.308 0-.603-.02-.894-.048V19.5H24v-15H10.21zm0 9.756v1.068c-3.356-.616-4.287-4.21-4.287-4.21a7.173 7.173 0 014.287-2.138v1.172h-.005a3.182 3.182 0 00-2.502 1.178s.615 2.276 2.507 2.931m-5.961-3.3c1.436-1.935 3.604-3.148 5.961-3.336V6.523C5.81 6.887 2 10.723 2 10.723s2.158 6.427 8.21 7.015v-1.166C5.77 16 4.25 10.958 4.25 10.958h-.002z"
    ),
    "openai" to listOf(
        "M9.205 8.658v-2.26c0-.19.072-.333.238-.428l4.543-2.616c.619-.357 1.356-.523 2.117-.523 2.854 0 4.662 2.212 4.662 4.566 0 .167 0 .357-.024.547l-4.71-2.759a.797.797 0 00-.856 0l-5.97 3.473zm10.609 8.8V12.06c0-.333-.143-.57-.429-.737l-5.97-3.473 1.95-1.118a.433.433 0 01.476 0l4.543 2.617c1.309.76 2.189 2.378 2.189 3.948 0 1.808-1.07 3.473-2.76 4.163zM7.802 12.703l-1.95-1.142c-.167-.095-.239-.238-.239-.428V5.899c0-2.545 1.95-4.472 4.591-4.472 1 0 1.927.333 2.712.928L8.23 5.067c-.285.166-.428.404-.428.737v6.898zM12 15.128l-2.795-1.57v-3.33L12 8.658l2.795 1.57v3.33L12 15.128zm1.796 7.23c-1 0-1.927-.332-2.712-.927l4.686-2.712c.285-.166.428-.404.428-.737v-6.898l1.974 1.142c.167.095.238.238.238.428v5.233c0 2.545-1.974 4.472-4.614 4.472zm-5.637-5.303l-4.544-2.617c-1.308-.761-2.188-2.378-2.188-3.948A4.482 4.482 0 014.21 6.327v5.423c0 .333.143.571.428.738l5.947 3.449-1.95 1.118a.432.432 0 01-.476 0zm-.262 3.9c-2.688 0-4.662-2.021-4.662-4.519 0-.19.024-.38.047-.57l4.686 2.71c.286.167.571.167.856 0l5.97-3.448v2.26c0 .19-.07.333-.237.428l-4.543 2.616c-.619.357-1.356.523-2.117.523zm5.899 2.83a5.947 5.947 0 005.827-4.756C22.287 18.339 24 15.84 24 13.296c0-1.665-.713-3.282-1.998-4.448.119-.5.19-.999.19-1.498 0-3.401-2.759-5.947-5.946-5.947-.642 0-1.26.095-1.88.31A5.962 5.962 0 0010.205 0a5.947 5.947 0 00-5.827 4.757C1.713 5.447 0 7.945 0 10.49c0 1.666.713 3.283 1.998 4.448-.119.5-.19 1-.19 1.499 0 3.401 2.759 5.946 5.946 5.946.642 0 1.26-.095 1.88-.309a5.96 5.96 0 004.162 1.713z"
    ),
    "xai" to listOf(
        "M6.469 8.776L16.512 23h-4.464L2.005 8.776H6.47zm-.004 7.9l2.233 3.164L6.467 23H2l4.465-6.324zM22 2.582V23h-3.659V7.764L22 2.582zM22 1l-9.952 14.095-2.233-3.163L17.533 1H22z"
    ),
    "zai" to listOf(
        "M12.105 2L9.927 4.953H.653L2.83 2h9.276zM23.254 19.048L21.078 22h-9.242l2.174-2.952h9.244zM24 2L9.264 22H0L14.736 2H24z"
    )
)

fun resolveProviderBrandKey(type: String, name: String = ""): String? {
    val key = type.lowercase()
    val combined = "$key ${name.lowercase()}"
    if (combined.contains("spark") || combined.contains("nvidia") || combined.contains("local")) return "nvidia"
    if (key.contains("anthropic") || key.contains("claude")) return "anthropic"
    if (key.contains("openai") || key.contains("codex") || key.contains("chatgpt")) return "openai"
    if (key.contains("kimi") || key.contains("moonshot")) return "kimi"
    if (key.contains("grok")) return "grok"
    if (key.contains("cursor")) return "cursor"
    if (key.contains("xai")) return "xai"
    if (key.contains("meta") || key.contains("muse") || key.contains("llama")) return "meta"
    if (key.contains("minimax")) return "minimax"
    if (key.contains("mistral") || key.contains("vibe")) return "mistral"
    if (key.contains("google") || key.contains("antigravity") || key.contains("gemini")) return "google"
    if (key.contains("zai") || key.contains("z.ai") || key.contains("z-ai") || key.contains("z_ai") || key.contains("zhipu") || key.contains("glm")) return "zai"
    return null
}

@Composable
fun OrbProviderLogo(
    type: String,
    name: String = "",
    size: Dp = 18.dp,
    modifier: Modifier = Modifier
) {
    val brand = remember(type, name) { resolveProviderBrandKey(type, name) }
    val pathList = brand?.let { providerVectorPaths[it] }
    Box(
        modifier = modifier
            .size(size + 12.dp)
            .clip(RoundedCornerShape(8.dp))
            .background(Color.White.copy(alpha = 0.06f))
            .border(1.dp, OrbStyle.border, RoundedCornerShape(8.dp)),
        contentAlignment = Alignment.Center
    ) {
        if (pathList != null) {
            val parsedPaths = remember(brand) {
                pathList.mapNotNull { pathStr ->
                    runCatching {
                        PathParser().parsePathString(pathStr).toPath().apply {
                            fillType = PathFillType.EvenOdd
                        }
                    }.getOrNull()
                }
            }
            Canvas(modifier = Modifier.size(size)) {
                val scaleX = this.size.width / 24f
                val scaleY = this.size.height / 24f
                drawContext.canvas.save()
                drawContext.canvas.scale(scaleX, scaleY)
                for (p in parsedPaths) {
                    drawPath(path = p, color = Color.White)
                }
                drawContext.canvas.restore()
            }
        } else {
            OrbSfIcons.CpuIcon(color = OrbStyle.textSecondary, size = size * 0.85f)
        }
    }
}

enum class OrbAndroidDictationPhase {
    Idle,
    Listening,
    Transcribing,
    Failed
}

@Composable
fun OrbAndroidDictationCapsule(
    phase: OrbAndroidDictationPhase,
    elapsedSeconds: Int,
    onCancel: () -> Unit,
    onFinish: () -> Unit,
    onRetry: () -> Unit,
    modifier: Modifier = Modifier
) {
    val isListening = phase == OrbAndroidDictationPhase.Listening
    val statusText = when (phase) {
        OrbAndroidDictationPhase.Listening -> "Microphone"
        OrbAndroidDictationPhase.Transcribing -> "Transcribing"
        OrbAndroidDictationPhase.Failed -> "Try again"
        OrbAndroidDictationPhase.Idle -> "Microphone"
    }
    Row(
        modifier = modifier
            .fillMaxWidth()
            .clip(CircleShape)
            .background(OrbStyle.surface)
            .border(1.dp, OrbStyle.borderStrong, CircleShape)
            .padding(horizontal = 8.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        // Left cancel circle
        Box(
            modifier = Modifier
                .size(38.dp)
                .clip(CircleShape)
                .background(Color.White.copy(alpha = 0.09f))
                .orbPressClickable { onCancel() },
            contentAlignment = Alignment.Center
        ) {
            Icon(
                imageVector = Icons.Default.Close,
                contentDescription = "Cancel dictation",
                tint = Color.White,
                modifier = Modifier.size(16.dp)
            )
        }

        // Center status / timer
        Box(
            modifier = Modifier.weight(1f),
            contentAlignment = Alignment.Center
        ) {
            Text(
                text = if (isListening && elapsedSeconds > 0) {
                    "Listening · ${elapsedSeconds / 60}:${"%02d".format(elapsedSeconds % 60)}"
                } else {
                    statusText
                },
                color = OrbStyle.textSecondary,
                fontSize = 15.sp,
                fontWeight = FontWeight.Medium,
                maxLines = 1
            )
        }

        // Right controls: dark circle (spinner / stop / retry) + solid white arrow.up circle
        Row(
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                modifier = Modifier
                    .size(38.dp)
                    .clip(CircleShape)
                    .background(Color.White.copy(alpha = 0.09f))
                    .orbPressClickable {
                        if (phase == OrbAndroidDictationPhase.Failed) onRetry()
                        else onFinish()
                    },
                contentAlignment = Alignment.Center
            ) {
                when (phase) {
                    OrbAndroidDictationPhase.Listening -> {
                        Icon(
                            imageVector = Icons.Default.Stop,
                            contentDescription = "Stop",
                            tint = Color.White,
                            modifier = Modifier.size(15.dp)
                        )
                    }
                    OrbAndroidDictationPhase.Failed -> {
                        Icon(
                            imageVector = Icons.Default.Refresh,
                            contentDescription = "Retry",
                            tint = Color.White,
                            modifier = Modifier.size(15.dp)
                        )
                    }
                    else -> {
                        CircularProgressIndicator(
                            color = Color.White,
                            strokeWidth = 2.dp,
                            modifier = Modifier.size(15.dp)
                        )
                    }
                }
            }

            Box(
                modifier = Modifier
                    .size(38.dp)
                    .clip(CircleShape)
                    .background(Color.White)
                    .orbPressClickable {
                        if (phase == OrbAndroidDictationPhase.Failed) onRetry()
                        else onFinish()
                    },
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    imageVector = Icons.Default.ArrowUpward,
                    contentDescription = "Use dictation",
                    tint = Color.Black,
                    modifier = Modifier.size(18.dp)
                )
            }
        }
    }
}

