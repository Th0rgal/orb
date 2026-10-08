package sh.sandboxed.dashboard.orb

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.SharedPreferences
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.WarningAmber
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlin.math.PI
import kotlin.math.cos

object OrbStyle {
    // Exact RGB equivalents of iOS OrbStyle:
    // Color(white: 0.073) -> 19, 19, 19 (#131313)
    val background = Color(0xFF131313)
    // Color(white: 0.105) -> 27, 27, 27 (#1B1B1B)
    val surface = Color(0xFF1B1B1B)
    // Color(white: 0.125) -> 32, 32, 32 (#202020)
    val card = Color(0xFF202020)
    // Color(white: 0.155) -> 40, 40, 40 (#272727)
    val elevated = Color(0xFF272727)
    // Color(red: 0.54, green: 0.54, blue: 0.54) -> 138, 138, 138 (#8A8A8A)
    val icon = Color(0xFF8A8A8A)
    val textPrimary = Color.White
    // Color(red: 0.61, green: 0.61, blue: 0.61) -> 155, 155, 155 (#9B9B9B)
    val textSecondary = Color(0xFF9B9B9B)
    // Color(red: 0.42, green: 0.42, blue: 0.42) -> 108, 108, 108 (#6C6C6C)
    val textMuted = Color(0xFF6C6C6C)
    val border = Color.White.copy(alpha = 0.08f)
    val borderStrong = Color.White.copy(alpha = 0.14f)
    // Color(red: 0.45, green: 0.79, blue: 0.57) -> 115, 201, 145 (#73C991)
    val success = Color(0xFF73C991)
    // Color(red: 0.84, green: 0.63, blue: 0.42) -> 214, 161, 106 (#D6A16A)
    val warning = Color(0xFFD6A16A)
    // Color(red: 0.92, green: 0.44, blue: 0.44) -> 235, 111, 111 (#EB6F6F)
    val error = Color(0xFFEB6F6F)
    // Color(red: 0.44, green: 0.69, blue: 0.96) -> 112, 175, 245 (#70AFF5)
    val inboxBlue = Color(0xFF70AFF5)

    fun copyToClipboard(context: Context, text: String) {
        val cb = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
        cb?.setPrimaryClip(ClipData.newPlainText("Orb", text))
    }
}

fun Modifier.orbPressClickable(
    enabled: Boolean = true,
    onClick: () -> Unit
): Modifier = composed {
    val interactionSource = remember { MutableInteractionSource() }
    val isPressed by interactionSource.collectIsPressedAsState()
    val scale by animateFloatAsState(
        targetValue = if (isPressed) 0.985f else 1f,
        animationSpec = spring(dampingRatio = 0.82f, stiffness = 900f),
        label = "orbPressScale"
    )
    val alpha by animateFloatAsState(
        targetValue = if (isPressed) 0.88f else 1f,
        animationSpec = tween(durationMillis = 90),
        label = "orbPressAlpha"
    )
    this
        .graphicsLayer {
            scaleX = scale
            scaleY = scale
            this.alpha = alpha
        }
        .clickable(
            interactionSource = interactionSource,
            indication = null,
            enabled = enabled,
            onClick = onClick
        )
}

fun Modifier.orbShimmer(active: Boolean = true): Modifier = composed {
    if (!active) return@composed this
    val transition = rememberInfiniteTransition(label = "orbShimmer")
    val phase by transition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 1900, easing = LinearEasing),
            repeatMode = RepeatMode.Restart
        ),
        label = "orbShimmerPhase"
    )
    this
        .graphicsLayer(compositingStrategy = CompositingStrategy.Offscreen)
        .drawWithContent {
            drawContent()
            val w = maxOf(size.width, 60f)
            val band = maxOf(50f, w * 0.55f)
            val startX = -band + phase * (w + band * 2f)
            drawRect(
                brush = Brush.linearGradient(
                    colors = listOf(
                        Color.Transparent,
                        Color.White.copy(alpha = 0.26f),
                        Color.Transparent
                    ),
                    start = Offset(startX, 0f),
                    end = Offset(startX + band, 0f)
                ),
                blendMode = BlendMode.SrcAtop
            )
        }
}

@Composable
fun OrbRunningDots(
    color: Color = OrbStyle.icon,
    dotSize: Dp = 2.6.dp,
    spacing: Dp = 2.4.dp,
    modifier: Modifier = Modifier
) {
    // 3x3 animated dot matrix matching iOS OrbRunningDots
    val delays = remember {
        floatArrayOf(0.0f, 0.15f, 0.30f, 0.20f, 0.35f, 0.50f, 0.40f, 0.55f, 0.70f)
    }
    var timeMs by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) {
        while (isActive) {
            timeMs = System.currentTimeMillis()
            delay(80L)
        }
    }
    val totalSide = dotSize * 3 + spacing * 2
    val tSec = (timeMs % 120000L) / 1000.0
    Canvas(modifier = modifier.size(totalSide)) {
        val dotPx = dotSize.toPx()
        val gapPx = spacing.toPx()
        val step = dotPx + gapPx
        val r = dotPx / 2f
        for (row in 0..2) {
            for (col in 0..2) {
                val idx = row * 3 + col
                val phase = ((tSec / 1.2 + delays[idx]) % 1.0)
                val wave = (0.5 - 0.5 * cos(phase * 2.0 * PI)).toFloat()
                val alpha = (0.18f + 0.72f * wave).coerceIn(0f, 1f)
                drawCircle(
                    color = color.copy(alpha = alpha),
                    radius = r,
                    center = Offset(col * step + r, row * step + r)
                )
            }
        }
    }
}

@Composable
fun OrbCircle(
    icon: ImageVector,
    size: Dp = 44.dp,
    iconSize: Dp = 17.dp,
    tint: Color = Color.White,
    background: Color = OrbStyle.surface,
    modifier: Modifier = Modifier
) {
    Box(
        modifier = modifier
            .size(size)
            .clip(CircleShape)
            .background(background)
            .border(1.dp, OrbStyle.border, CircleShape),
        contentAlignment = Alignment.Center
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = tint,
            modifier = Modifier.size(iconSize)
        )
    }
}

@Composable
fun OrbNotice(
    title: String,
    log: String?,
    modifier: Modifier = Modifier
) {
    val context = LocalContext.current
    var showLog by remember { mutableStateOf(false) }
    var copied by remember { mutableStateOf(false) }
    val payload = remember(title, log) {
        listOfNotNull(title, log?.takeIf { it.isNotEmpty() }).joinToString("\n\n")
    }

    LaunchedEffect(copied) {
        if (copied) {
            delay(1500L)
            copied = false
        }
    }

    Column(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(OrbStyle.surface)
            .border(1.dp, OrbStyle.border, RoundedCornerShape(14.dp))
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        Row(
            verticalAlignment = Alignment.Top,
            horizontalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            Icon(
                imageVector = Icons.Default.WarningAmber,
                contentDescription = null,
                tint = OrbStyle.warning,
                modifier = Modifier
                    .padding(top = 2.dp)
                    .size(15.dp)
            )
            Text(
                text = title,
                color = Color.White,
                fontSize = 13.sp,
                fontWeight = FontWeight.Medium,
                modifier = Modifier.weight(1f)
            )
            Box(
                modifier = Modifier
                    .size(28.dp)
                    .clip(CircleShape)
                    .background(OrbStyle.card)
                    .orbPressClickable {
                        OrbStyle.copyToClipboard(context, payload)
                        copied = true
                    },
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    imageVector = if (copied) Icons.Default.Check else Icons.Default.ContentCopy,
                    contentDescription = "Copy",
                    tint = if (copied) OrbStyle.success else OrbStyle.textSecondary,
                    modifier = Modifier.size(13.dp)
                )
            }
        }

        if (!log.isNullOrEmpty()) {
            Row(
                modifier = Modifier.orbPressClickable { showLog = !showLog },
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(5.dp)
            ) {
                Icon(
                    imageVector = if (showLog) Icons.Default.ExpandMore else Icons.Default.ChevronRight,
                    contentDescription = null,
                    tint = OrbStyle.textMuted,
                    modifier = Modifier.size(12.dp)
                )
                Text(
                    text = "Log tail",
                    color = OrbStyle.textMuted,
                    fontSize = 11.sp,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    softWrap = false
                )
            }
            if (showLog) {
                Text(
                    text = log,
                    color = OrbStyle.textSecondary,
                    fontSize = 11.sp,
                    fontFamily = FontFamily.Monospace,
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(10.dp))
                        .background(Color.Black.copy(alpha = 0.35f))
                        .padding(10.dp)
                )
            }
        }
    }
}

data class OrbColorPreset(
    val name: String,
    val hex: String
)

object OrbProjectAppearance {
    val presets: List<OrbColorPreset> = listOf(
        OrbColorPreset("Default", ""),
        OrbColorPreset("Blue", "#8AAED4"),
        OrbColorPreset("Green", "#94B89A"),
        OrbColorPreset("Amber", "#C5AA70"),
        OrbColorPreset("Rose", "#CB929F"),
        OrbColorPreset("Purple", "#AD9ACB")
    )

    private const val PREFS_KEY = "orb.project.colors"
    private var prefs: SharedPreferences? = null
    val customColors = mutableStateMapOf<String, String>(
        "verity-core" to "#8AAED4",
        "verity" to "#8AAED4",
        "sandboxed" to "#AD9ACB",
        "health-manager" to "#CB929F",
        "minecraft" to "#94B89A"
    )

    fun wireNameToHex(raw: String): String {
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) return ""
        if (trimmed.startsWith("#") && trimmed.length == 7) return trimmed.uppercase()
        val lower = trimmed.lowercase()
        return presets.firstOrNull { it.hex.isNotEmpty() && it.name.lowercase() == lower }?.hex ?: ""
    }

    fun hexToWireName(raw: String): String? {
        val clean = raw.trim().uppercase()
        if (clean.isEmpty()) return null
        return presets.firstOrNull { it.hex.equals(clean, ignoreCase = true) }?.name?.lowercase()
    }

    fun init(context: Context) {
        if (prefs == null) {
            val p = context.applicationContext.getSharedPreferences(PREFS_KEY, Context.MODE_PRIVATE)
            prefs = p
            val defaults = mapOf(
                "verity-core" to "#8AAED4",
                "verity" to "#8AAED4",
                "sandboxed" to "#AD9ACB",
                "health-manager" to "#CB929F",
                "minecraft" to "#94B89A"
            )
            val ed = p.edit()
            var wroteDefaults = false
            for ((k, v) in p.all) {
                if (v is String && v.isNotEmpty()) {
                    val resolved = wireNameToHex(v)
                    if (resolved.isNotEmpty()) {
                        customColors[k] = resolved
                    }
                }
            }
            for ((k, v) in defaults) {
                if (customColors[k].isNullOrEmpty()) {
                    customColors[k] = v
                    ed.putString(k, v)
                    wroteDefaults = true
                }
            }
            if (wroteDefaults) ed.apply()
        }
    }

    fun slug(project: OrbRow): String =
        (project.str("slug", "id", "name") ?: project.id).trim().lowercase()

    fun hex(project: OrbRow): String {
        val key = slug(project)
        val rawServer = (project.str("color", "folder_color", "icon_color") ?: "").trim()
        val serverHex = wireNameToHex(rawServer)
        if (serverHex.isNotEmpty()) {
            if (customColors[key] != serverHex) {
                customColors[key] = serverHex
                save()
            }
            return serverHex
        }
        return customColors[key] ?: ""
    }

    fun color(project: OrbRow): Color =
        colorFromHex(hex(project)) ?: OrbStyle.icon

    fun colorForSlug(slug: String): Color =
        colorFromHex(customColors[slug.trim().lowercase()] ?: "") ?: OrbStyle.icon

    fun setColor(hex: String, project: OrbRow, core: OrbCore) {
        val key = slug(project)
        val normalized = wireNameToHex(hex)
        val serverSlug = (project.str("slug", "id") ?: key).trim()
        if (normalized.isEmpty()) {
            customColors.remove(key)
        } else {
            customColors[key] = normalized
        }
        save()
        core.scope.launch(Dispatchers.IO) {
            val encoded = core.encodeComponent(serverSlug)
            val wireName = hexToWireName(normalized)
            val body: Map<String, Any?> = mapOf("color" to wireName)
            try {
                core.request("/api/projects/$encoded/appearance", method = "POST", body = body)
                core.refreshMissionsQuietly()
            } catch (_: Throwable) {
            }
        }
    }

    private fun save() {
        val p = prefs ?: return
        val editor = p.edit().clear()
        for ((k, v) in customColors) {
            editor.putString(k, v)
        }
        editor.apply()
    }

    fun colorFromHex(raw: String): Color? {
        val resolved = wireNameToHex(raw)
        val clean = resolved.trim().removePrefix("#")
        if (clean.length != 6) return null
        val rgb = clean.toLongOrNull(16) ?: return null
        val r = ((rgb shr 16) and 0xFF).toInt()
        val g = ((rgb shr 8) and 0xFF).toInt()
        val b = (rgb and 0xFF).toInt()
        return Color(r, g, b)
    }
}

@Composable
fun OrbSkeletonRow() {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 20.dp, vertical = 13.dp)
            .orbShimmer(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        Box(
            modifier = Modifier
                .size(22.dp)
                .clip(RoundedCornerShape(6.dp))
                .background(OrbStyle.card)
        )
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(6.dp)
        ) {
            Box(
                modifier = Modifier
                    .width(150.dp)
                    .height(14.dp)
                    .clip(RoundedCornerShape(4.dp))
                    .background(OrbStyle.card)
            )
            Box(
                modifier = Modifier
                    .width(95.dp)
                    .height(10.dp)
                    .clip(RoundedCornerShape(4.dp))
                    .background(OrbStyle.surface)
            )
        }
        Spacer(modifier = Modifier.width(8.dp))
        Box(
            modifier = Modifier
                .width(28.dp)
                .height(11.dp)
                .clip(RoundedCornerShape(4.dp))
                .background(OrbStyle.surface)
        )
    }
}
