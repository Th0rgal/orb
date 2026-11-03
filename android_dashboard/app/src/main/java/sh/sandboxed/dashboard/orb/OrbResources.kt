package sh.sandboxed.dashboard.orb

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import java.util.Locale
import kotlin.coroutines.cancellation.CancellationException
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Agents › Resources (desktop: Resources.tsx & resourcesModel.ts; iOS: OrbResources.swift).
 * Conserved Fleet Sankey (Machines / Quota Pools -> Missions) + 1-tap Mission Fast-DAG drilldown,
 * synchronized consumption curve, bottom Timeline bar, and [vCPU / B tok/h | $] unit toggle.
 */
object OrbResourcesModel {
    enum class Lens(val id: String) {
        Compute("compute"),
        Inference("inference");
        companion object {
            fun parse(raw: String): Lens = if (raw == "inference") Inference else Compute
        }
    }

    enum class Metric(val id: String) {
        Raw("raw"),
        Usd("usd");
        companion object {
            fun parse(raw: String): Metric = if (raw == "usd") Usd else Raw
        }
    }

    data class SankeyInputNode(
        val id: String,
        val column: Int,
        val label: String,
        val sub: String,
        val colorHex: String,
        val missionId: String? = null,
        val fallbackValue: Double = 0.0,
        val fallbackUsd: Double = 0.0,
    )

    data class SankeyInputLink(
        val id: String,
        val source: String,
        val target: String,
        val value: Double,
        val estUsdPerH: Double,
        val degraded: Boolean = false,
    )

    data class SankeyLayoutNode(
        val id: String,
        val column: Int,
        val label: String,
        val sub: String,
        val colorHex: String,
        val missionId: String?,
        val value: Double,
        val rawValue: Double,
        val usdValue: Double,
        val x0: Double,
        val x1: Double,
        var y0: Double,
        var y1: Double,
    )

    data class SankeyLayoutLink(
        val id: String,
        val source: String,
        val target: String,
        val rawValue: Double,
        val usdValue: Double,
        val degraded: Boolean,
        val colorHex: String,
        val sourceX: Double,
        val targetX: Double,
        val y0: Double,
        val y1: Double,
        val sourceWidth: Double,
        val width: Double,
    )

    data class SankeyLayoutResult(
        val nodes: List<SankeyLayoutNode>,
        val links: List<SankeyLayoutLink>,
        val totalRaw: Double,
        val totalUsd: Double,
        val columns: Int,
    )

    data class DagBarInput(
        val id: String,
        val missionId: String? = null,
        val label: String,
        val section: String,
        val startOffsetSecs: Double,
        val durationSecs: Double,
        val etaRemainingSecs: Double? = null,
        val state: String,
        val afterIds: List<String> = emptyList(),
    )

    data class DagRowLayout(
        val bar: DagBarInput,
        val sectionHeader: String?,
        val startFrac: Double,
        val endFrac: Double,
        val etaEndFrac: Double?,
    )

    fun formatResourceRate(
        value: Double,
        lens: Lens,
        metric: Metric,
        withUnit: Boolean = true,
    ): String {
        val safe = if (value.isFinite()) max(0.0, value) else 0.0
        if (metric == Metric.Usd) {
            if (!withUnit) {
                return when {
                    safe >= 100.0 -> "$${safe.roundToInt()}"
                    safe >= 10.0 -> String.format(Locale.US, "$%.1f", safe)
                    else -> String.format(Locale.US, "$%.2f", safe)
                }
            }
            return when {
                safe >= 100.0 -> "$${safe.roundToInt()}/h"
                safe >= 10.0 -> String.format(Locale.US, "$%.1f/h", safe)
                safe >= 0.01 -> String.format(Locale.US, "$%.2f/h", safe)
                safe > 0.0 -> "<$0.01/h"
                else -> "$0.00/h"
            }
        }

        if (lens == Lens.Compute) {
            val rounded1 = (safe * 10.0).roundToInt() / 10.0
            val num = if (safe >= 10.0 || abs(rounded1 - safe.roundToInt()) < 0.05) {
                "${safe.roundToInt()}"
            } else {
                String.format(Locale.US, "%.1f", safe)
            }
            return if (withUnit) "$num vCPU" else num
        }

        val num = when {
            safe >= 10.0 -> String.format(Locale.US, "%.1f", safe)
            safe >= 0.1 -> String.format(Locale.US, "%.2f", safe)
            safe > 0.0 -> String.format(Locale.US, "%.3f", safe)
            else -> "0.00"
        }
        return if (withUnit) "$num B tok/h" else num
    }

    fun formatDurationCompact(secs: Double): String {
        if (!secs.isFinite() || secs <= 0.0) return "0m"
        val s = secs.roundToInt()
        if (s < 60) return "${s}s"
        val mins = s / 60
        if (mins < 60) return "${mins}m"
        val hours = mins / 60
        val remM = mins % 60
        if (hours < 24) return if (remM > 0) "${hours}h ${remM}m" else "${hours}h"
        val days = hours / 24
        val remH = hours % 24
        return if (remH > 0) "${days}d ${remH}h" else "${days}d"
    }

    fun computeSankeyLayout(
        inputNodes: List<SankeyInputNode>,
        inputLinks: List<SankeyInputLink>,
        width: Double,
        height: Double,
        metric: Metric,
        marginX: Double = 80.0,
        marginY: Double = 10.0,
    ): SankeyLayoutResult {
        val nodeWidth = 10.0
        val nodePadding = 10.0
        val maxCol = inputNodes.maxOfOrNull { it.column } ?: 1
        val columns = max(2, maxCol + 1)

        val rawIn = mutableMapOf<String, Double>()
        val rawOut = mutableMapOf<String, Double>()
        val usdIn = mutableMapOf<String, Double>()
        val usdOut = mutableMapOf<String, Double>()

        for (l in inputLinks) {
            val r = max(0.0, l.value)
            val u = max(0.0, l.estUsdPerH)
            rawOut[l.source] = (rawOut[l.source] ?: 0.0) + r
            rawIn[l.target] = (rawIn[l.target] ?: 0.0) + r
            usdOut[l.source] = (usdOut[l.source] ?: 0.0) + u
            usdIn[l.target] = (usdIn[l.target] ?: 0.0) + u
        }

        val col0Ids = inputNodes.filter { it.column == 0 }.map { it.id }.toSet()
        var totalRaw = 0.0
        var totalUsd = 0.0
        for (l in inputLinks) {
            if (col0Ids.contains(l.source)) {
                totalRaw += max(0.0, l.value)
                totalUsd += max(0.0, l.estUsdPerH)
            }
        }
        if (totalRaw == 0.0 && inputLinks.isEmpty()) {
            for (n in inputNodes) {
                if (n.column == 0) {
                    totalRaw += max(0.0, n.fallbackValue)
                    totalUsd += max(0.0, n.fallbackUsd)
                }
            }
        }

        val innerW = max(60.0, width - marginX * 2.0 - nodeWidth)
        val innerH = max(60.0, height - marginY * 2.0)

        val cols = Array(columns) { mutableListOf<SankeyLayoutNode>() }
        val nodeMap = mutableMapOf<String, SankeyLayoutNode>()

        for (n in inputNodes) {
            if (n.column !in 0 until columns) continue
            val rVal = max(max(rawIn[n.id] ?: 0.0, rawOut[n.id] ?: 0.0), n.fallbackValue)
            val uVal = max(max(usdIn[n.id] ?: 0.0, usdOut[n.id] ?: 0.0), n.fallbackUsd)
            val active = if (metric == Metric.Usd) uVal else rVal
            val x0 = marginX + (n.column.toDouble() / max(1, columns - 1).toDouble()) * innerW
            cols[n.column].add(
                SankeyLayoutNode(
                    id = n.id,
                    column = n.column,
                    label = n.label,
                    sub = n.sub,
                    colorHex = n.colorHex,
                    missionId = n.missionId,
                    value = active,
                    rawValue = rVal,
                    usdValue = uVal,
                    x0 = x0,
                    x1 = x0 + nodeWidth,
                    y0 = 0.0,
                    y1 = 0.0,
                ),
            )
        }

        var sharedScale = Double.POSITIVE_INFINITY
        for (c in 0 until columns) {
            val col = cols[c]
            if (col.isEmpty()) continue
            col.sortByDescending { it.value }
            val sumVal = col.sumOf { max(0.0, it.value) }
            val padTotal = max(0, col.size - 1) * nodePadding
            val availH = max(32.0, innerH - padTotal)
            if (sumVal > 0.0) sharedScale = min(sharedScale, availH / sumVal)
        }
        if (!sharedScale.isFinite() || sharedScale <= 0.0) sharedScale = 1.0

        for (c in 0 until columns) {
            val col = cols[c]
            if (col.isEmpty()) continue
            val heights = col.map { max(6.0, it.value * sharedScale) }
            val rawColH = heights.sum() + max(0, col.size - 1) * nodePadding
            val compress = if (rawColH > innerH) innerH / rawColH else 1.0
            val effPad = nodePadding * compress
            val finalH = heights.sumOf { it * compress } + max(0, col.size - 1) * effPad
            var cursorY = marginY + max(0.0, (innerH - finalH) / 2.0)
            for (i in col.indices) {
                val h = max(4.0, heights[i] * compress)
                col[i].y0 = cursorY
                col[i].y1 = cursorY + h
                nodeMap[col[i].id] = col[i]
                cursorY += h + effPad
            }
        }

        val outBySource = mutableMapOf<String, MutableList<SankeyInputLink>>()
        val inByTarget = mutableMapOf<String, MutableList<SankeyInputLink>>()
        for (l in inputLinks) {
            if (!nodeMap.containsKey(l.source) || !nodeMap.containsKey(l.target)) continue
            val mv = if (metric == Metric.Usd) l.estUsdPerH else l.value
            if (mv <= 0.0 && l.value <= 0.0) continue
            outBySource.getOrPut(l.source) { mutableListOf() }.add(l)
            inByTarget.getOrPut(l.target) { mutableListOf() }.add(l)
        }

        val sourceYW = mutableMapOf<String, Pair<Double, Double>>()
        for ((srcId, list) in outBySource) {
            val src = nodeMap[srcId] ?: continue
            list.sortBy { nodeMap[it.target]?.y0 ?: 0.0 }
            val nodeH = max(4.0, src.y1 - src.y0)
            val sumM = list.sumOf { max(1e-6, if (metric == Metric.Usd) it.estUsdPerH else it.value) }
            var off = src.y0
            for (l in list) {
                val mv = max(1e-6, if (metric == Metric.Usd) l.estUsdPerH else l.value)
                val w = (mv / sumM) * nodeH
                sourceYW[l.id] = (off + w / 2.0) to w
                off += w
            }
        }

        val targetYW = mutableMapOf<String, Pair<Double, Double>>()
        for ((dstId, list) in inByTarget) {
            val dst = nodeMap[dstId] ?: continue
            list.sortBy { nodeMap[it.source]?.y0 ?: 0.0 }
            val nodeH = max(4.0, dst.y1 - dst.y0)
            val sumM = list.sumOf { max(1e-6, if (metric == Metric.Usd) it.estUsdPerH else it.value) }
            var off = dst.y0
            for (l in list) {
                val mv = max(1e-6, if (metric == Metric.Usd) l.estUsdPerH else l.value)
                val w = (mv / sumM) * nodeH
                targetYW[l.id] = (off + w / 2.0) to w
                off += w
            }
        }

        val outLinks = mutableListOf<SankeyLayoutLink>()
        for (l in inputLinks) {
            val src = nodeMap[l.source] ?: continue
            val dst = nodeMap[l.target] ?: continue
            val (y0, sw) = sourceYW[l.id] ?: continue
            val (y1, w) = targetYW[l.id] ?: continue
            outLinks.add(
                SankeyLayoutLink(
                    id = l.id,
                    source = l.source,
                    target = l.target,
                    rawValue = max(0.0, l.value),
                    usdValue = max(0.0, l.estUsdPerH),
                    degraded = l.degraded,
                    colorHex = src.colorHex,
                    sourceX = src.x1,
                    targetX = dst.x0,
                    y0 = y0,
                    y1 = y1,
                    sourceWidth = max(1.5, sw),
                    width = max(1.5, w),
                ),
            )
        }

        return SankeyLayoutResult(
            nodes = cols.flatMap { it },
            links = outLinks,
            totalRaw = totalRaw,
            totalUsd = totalUsd,
            columns = columns,
        )
    }

    fun layoutDagRows(bars: List<DagBarInput>, horizonSecs: Double): List<DagRowLayout> {
        val safeH = max(60.0, horizonSecs)
        var prevSection: String? = null
        return bars.map { b ->
            val hdr = if (b.section != prevSection) b.section else null
            prevSection = b.section
            val sFrac = min(1.0, max(0.0, b.startOffsetSecs / safeH))
            val eFrac = min(1.0, max(sFrac + 0.01, (b.startOffsetSecs + max(30.0, b.durationSecs)) / safeH))
            val etaFrac = if (b.etaRemainingSecs != null && b.etaRemainingSecs > 0.0 && b.state == "active") {
                min(1.0, max(eFrac, (b.startOffsetSecs + b.durationSecs + b.etaRemainingSecs) / safeH))
            } else {
                null
            }
            DagRowLayout(bar = b, sectionHeader = hdr, startFrac = sFrac, endFrac = eFrac, etaEndFrac = etaFrac)
        }
    }

    fun parseColor(hex: String): Color {
        val clean = hex.removePrefix("#")
        return runCatching {
            val rgb = clean.toLong(16)
            Color(
                red = ((rgb shr 16) and 0xFF) / 255f,
                green = ((rgb shr 8) and 0xFF) / 255f,
                blue = (rgb and 0xFF) / 255f,
            )
        }.getOrDefault(Color(0xFF2F83BF))
    }
}

private val RESOURCES_PALETTE = listOf("#2f83bf", "#1d9a78", "#7b63cf", "#cf6a2d", "#be4f78", "#22959d")
private val FLEET_RANGES = listOf("30m", "1h", "6h", "24h", "7d")

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun OrbResourcesSettingsPage(
    core: OrbCore,
    onBack: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    var lens by remember { mutableStateOf(OrbResourcesModel.Lens.Inference) }
    var metric by remember { mutableStateOf(OrbResourcesModel.Metric.Raw) }
    var range by remember { mutableStateOf("6h") }
    var horizon by remember { mutableStateOf("6h") }
    var selectedMissionId by remember { mutableStateOf<String?>(null) }

    var overview by remember { mutableStateOf<OrbDict?>(null) }
    var detail by remember { mutableStateOf<OrbDict?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var isRefreshing by remember { mutableStateOf(false) }

    suspend fun load() {
        try {
            if (selectedMissionId != null) {
                val mid = selectedMissionId!!
                detail = core.fetchDict("/api/resources/missions/${core.encodeComponent(mid)}?horizon=${core.encodeComponent(horizon)}")
            } else {
                overview = core.fetchDict("/api/resources/overview?range=${core.encodeComponent(range)}")
            }
            error = null
        } catch (c: CancellationException) {
            throw c
        } catch (_: Throwable) {
            error = "Couldn’t load resources. Pull to retry."
        }
    }

    LaunchedEffect(selectedMissionId, range, horizon) {
        load()
        while (true) {
            delay(12_000L)
            load()
        }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(OrbStyle.background),
    ) {
        // Header bar
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp, vertical = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            OrbCircle(
                icon = Icons.AutoMirrored.Filled.ArrowBack,
                size = 38.dp,
                iconSize = 17.dp,
                contentDescription = "Back",
                modifier = Modifier.orbPressClickable {
                    if (selectedMissionId != null) {
                        selectedMissionId = null
                        detail = null
                    } else {
                        onBack()
                    }
                },
            )
            Text(
                text = if (selectedMissionId == null) {
                    "Resources"
                } else {
                    OrbJSON.str(OrbJSON.dict(detail?.get("mission")), "title")?.ifEmpty { null } ?: "Mission Fast-DAG"
                },
                color = Color.White,
                fontSize = 17.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier
                    .weight(1f)
                    .padding(horizontal = 8.dp),
                textAlign = TextAlign.Center,
            )
            Spacer(modifier = Modifier.width(38.dp))
        }

        PullToRefreshBox(
            isRefreshing = isRefreshing,
            onRefresh = {
                scope.launch {
                    isRefreshing = true
                    try {
                        load()
                    } finally {
                        isRefreshing = false
                    }
                }
            },
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth(),
        ) {
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 20.dp, vertical = 6.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                error?.let { Text(it, color = OrbStyle.warning, fontSize = 12.sp) }

                // Top Lens + Unit [vCPU / B tok/h | $] Toggle Row
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    SegmentedPillRow(
                        options = listOf(
                            OrbResourcesModel.Lens.Inference to "Inference",
                            OrbResourcesModel.Lens.Compute to "Compute",
                        ),
                        selected = lens,
                        onSelect = { lens = it },
                        modifier = Modifier.weight(1f),
                    )
                    SegmentedPillRow(
                        options = listOf(
                            OrbResourcesModel.Metric.Raw to if (lens == OrbResourcesModel.Lens.Compute) "vCPU" else "B tok/h",
                            OrbResourcesModel.Metric.Usd to "$",
                        ),
                        selected = metric,
                        onSelect = { metric = it },
                        modifier = Modifier.width(116.dp),
                    )
                }

                if (selectedMissionId != null) {
                    MissionFastDagCard(detail = detail, lens = lens, metric = metric)
                } else {
                    FleetSankeyCard(
                        overview = overview,
                        lens = lens,
                        metric = metric,
                        range = range,
                        onSelectMission = { selectedMissionId = it },
                    )
                }

                ConsumptionCurveCard(
                    overview = overview,
                    detail = detail,
                    isMission = selectedMissionId != null,
                    lens = lens,
                    metric = metric,
                )
            }
        }

        // Bottom-anchored Timeline Bar
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .background(OrbStyle.surface)
                .border(1.dp, OrbStyle.border)
                .padding(horizontal = 16.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text(
                text = "TIMELINE",
                color = OrbStyle.textSecondary,
                fontSize = 11.sp,
                fontWeight = FontWeight.SemiBold,
            )
            Spacer(modifier = Modifier.weight(1f))
            if (selectedMissionId != null) {
                val horizons = OrbJSON.dictList(detail?.get("available_horizons"))
                    .map { (OrbJSON.str(it, "id") ?: "6h") to (OrbJSON.str(it, "label") ?: "Fast-DAG (6h)") }
                    .ifEmpty { listOf("6h" to "Fast-DAG (6h)") }
                SegmentedPillRow(
                    options = horizons,
                    selected = horizon,
                    onSelect = { horizon = it },
                    modifier = Modifier.width(220.dp),
                )
            } else {
                SegmentedPillRow(
                    options = FLEET_RANGES.map { it to it },
                    selected = range,
                    onSelect = { range = it },
                    modifier = Modifier.width(240.dp),
                )
            }
        }
    }
}

@Composable
private fun <T> SegmentedPillRow(
    options: List<Pair<T, String>>,
    selected: T,
    onSelect: (T) -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier
            .clip(RoundedCornerShape(9.dp))
            .background(OrbStyle.surface)
            .border(1.dp, OrbStyle.border, RoundedCornerShape(9.dp))
            .padding(2.dp),
        horizontalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        options.forEach { (value, label) ->
            val active = value == selected
            Box(
                modifier = Modifier
                    .weight(1f)
                    .clip(RoundedCornerShape(7.dp))
                    .background(if (active) Color.White.copy(alpha = 0.11f) else Color.Transparent)
                    .orbPressClickable { onSelect(value) }
                    .padding(vertical = 6.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    text = label,
                    color = if (active) Color.White else OrbStyle.textSecondary,
                    fontSize = 11.5.sp,
                    fontWeight = if (active) FontWeight.SemiBold else FontWeight.Normal,
                    maxLines = 1,
                )
            }
        }
    }
}

@Composable
private fun FleetSankeyCard(
    overview: OrbDict?,
    lens: OrbResourcesModel.Lens,
    metric: OrbResourcesModel.Metric,
    range: String,
    onSelectMission: (String) -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(OrbStyle.surface)
            .border(1.dp, OrbStyle.border, RoundedCornerShape(12.dp))
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        if (overview == null) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(190.dp)
                    .clip(RoundedCornerShape(8.dp))
                    .background(Color.White.copy(alpha = 0.04f)),
            )
            return@Column
        }

        val compute = OrbJSON.dict(overview["compute"]) ?: emptyMap()
        val inference = OrbJSON.dict(overview["inference"]) ?: emptyMap()
        val missions = OrbJSON.dictList(overview["missions"])
        val links = OrbJSON.dictList(overview["links"])

        val primaryStamp = if (lens == OrbResourcesModel.Lens.Compute) {
            if (metric == OrbResourcesModel.Metric.Usd) {
                OrbResourcesModel.formatResourceRate(OrbJSON.double(compute, "hourly_burn_usd") ?: 0.0, lens, metric)
            } else {
                val act = OrbResourcesModel.formatResourceRate(OrbJSON.double(compute, "active_vcpu") ?: 0.0, lens, OrbResourcesModel.Metric.Raw, false)
                val tot = OrbResourcesModel.formatResourceRate(OrbJSON.double(compute, "total_vcpu") ?: 0.0, lens, OrbResourcesModel.Metric.Raw, true)
                "$act/$tot"
            }
        } else {
            val v = if (metric == OrbResourcesModel.Metric.Usd) {
                OrbJSON.double(inference, "est_usd_per_h") ?: 0.0
            } else {
                OrbJSON.double(inference, "current_b_tok_per_h") ?: 0.0
            }
            OrbResourcesModel.formatResourceRate(v, lens, metric)
        }

        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = if (lens == OrbResourcesModel.Lens.Compute) "Machines → Missions" else "Quota Pools → Missions",
                color = OrbStyle.textSecondary,
                fontSize = 11.sp,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                text = "$primaryStamp ($range)",
                color = Color.White,
                fontSize = 12.sp,
                fontFamily = FontFamily.Monospace,
                fontWeight = FontWeight.SemiBold,
            )
        }

        val inputNodes = mutableListOf<OrbResourcesModel.SankeyInputNode>()
        if (lens == OrbResourcesModel.Lens.Compute) {
            OrbJSON.dictList(compute["sources"]).forEachIndexed { i, s ->
                inputNodes.add(
                    OrbResourcesModel.SankeyInputNode(
                        id = OrbJSON.str(s, "id") ?: "src-$i",
                        column = 0,
                        label = OrbJSON.str(s, "label") ?: "Machine",
                        sub = OrbJSON.str(s, "sublabel") ?: "",
                        colorHex = RESOURCES_PALETTE[i % RESOURCES_PALETTE.size],
                        fallbackValue = OrbJSON.double(s, "total_vcpu") ?: 0.0,
                        fallbackUsd = OrbJSON.double(s, "est_usd_per_h") ?: 0.0,
                    ),
                )
            }
        } else {
            val activeIds = links
                .filter { OrbJSON.str(it, "kind") == "inference" && (OrbJSON.double(it, "value") ?: 0.0) > 0.0 }
                .mapNotNull { OrbJSON.str(it, "source_id") }
                .toSet()
            val allPools = OrbJSON.dictList(inference["pools"])
            val filtered = allPools.filter {
                activeIds.contains(OrbJSON.str(it, "id") ?: "") ||
                    (OrbJSON.double(it, "current_b_tok_per_h") ?: 0.0) > 0.0 ||
                    (OrbJSON.double(it, "est_usd_per_h") ?: 0.0) > 0.0
            }
            val pools = if (filtered.isNotEmpty()) filtered else allPools.take(5)
            pools.forEachIndexed { i, p ->
                val rawSub = OrbJSON.str(p, "sublabel") ?: ""
                val remPct = OrbJSON.double(p, "remaining_pct")
                val hasLeft = rawSub.contains("% left", ignoreCase = true)
                val sub = if (remPct != null && !hasLeft) {
                    if (rawSub.isEmpty()) "${remPct.roundToInt()}% left" else "${remPct.roundToInt()}% left · $rawSub"
                } else {
                    rawSub
                }
                inputNodes.add(
                    OrbResourcesModel.SankeyInputNode(
                        id = OrbJSON.str(p, "id") ?: "pool-$i",
                        column = 0,
                        label = OrbJSON.str(p, "label") ?: "Pool",
                        sub = sub,
                        colorHex = RESOURCES_PALETTE[i % RESOURCES_PALETTE.size],
                        fallbackValue = OrbJSON.double(p, "current_b_tok_per_h") ?: 0.0,
                        fallbackUsd = OrbJSON.double(p, "est_usd_per_h") ?: 0.0,
                    ),
                )
            }
        }
        val maxCol1 = 7
        val sortedMissions = missions.sortedByDescending { m ->
            if (lens == OrbResourcesModel.Lens.Compute) {
                if (metric == OrbResourcesModel.Metric.Usd) OrbJSON.double(m, "compute_usd_per_h") ?: 0.0 else OrbJSON.double(m, "vcpu") ?: 0.0
            } else {
                if (metric == OrbResourcesModel.Metric.Usd) OrbJSON.double(m, "inference_usd_per_h") ?: 0.0 else OrbJSON.double(m, "b_tok_per_h") ?: 0.0
            }
        }
        val capMissions = sortedMissions.size > maxCol1 + 1
        val visibleMissions = if (capMissions) sortedMissions.take(maxCol1) else sortedMissions
        val overflowMissions = if (capMissions) sortedMissions.drop(maxCol1) else emptyList()
        val overflowIds = overflowMissions.mapNotNull { OrbJSON.str(it, "id") }.toSet()
        val tailId = "__other_missions__"

        visibleMissions.forEachIndexed { i, m ->
            val mid = OrbJSON.str(m, "id") ?: "m-$i"
            inputNodes.add(
                OrbResourcesModel.SankeyInputNode(
                    id = mid,
                    column = 1,
                    label = OrbJSON.str(m, "title") ?: mid.take(8),
                    sub = OrbJSON.str(m, "status") ?: "",
                    colorHex = RESOURCES_PALETTE[(i + 2) % RESOURCES_PALETTE.size],
                    missionId = mid,
                    fallbackValue = if (lens == OrbResourcesModel.Lens.Compute) (OrbJSON.double(m, "vcpu") ?: 0.0) else (OrbJSON.double(m, "b_tok_per_h") ?: 0.0),
                    fallbackUsd = if (lens == OrbResourcesModel.Lens.Compute) (OrbJSON.double(m, "compute_usd_per_h") ?: 0.0) else (OrbJSON.double(m, "inference_usd_per_h") ?: 0.0),
                ),
            )
        }
        if (overflowMissions.isNotEmpty()) {
            val sumRaw = overflowMissions.sumOf {
                if (lens == OrbResourcesModel.Lens.Compute) (OrbJSON.double(it, "vcpu") ?: 0.0) else (OrbJSON.double(it, "b_tok_per_h") ?: 0.0)
            }
            val sumUsd = overflowMissions.sumOf {
                if (lens == OrbResourcesModel.Lens.Compute) (OrbJSON.double(it, "compute_usd_per_h") ?: 0.0) else (OrbJSON.double(it, "inference_usd_per_h") ?: 0.0)
            }
            inputNodes.add(
                OrbResourcesModel.SankeyInputNode(
                    id = tailId,
                    column = 1,
                    label = "+${overflowMissions.size} missions",
                    sub = "grouped",
                    colorHex = "#6b7280",
                    missionId = null,
                    fallbackValue = sumRaw,
                    fallbackUsd = sumUsd,
                ),
            )
        }

        val inputLinks = mutableListOf<OrbResourcesModel.SankeyInputLink>()
        val tailAgg = mutableMapOf<String, Triple<Double, Double, Boolean>>()
        links.filter { OrbJSON.str(it, "kind") == lens.id }.forEachIndexed { i, l ->
            val src = OrbJSON.str(l, "source_id") ?: ""
            val tgt = OrbJSON.str(l, "mission_id") ?: ""
            val v = OrbJSON.double(l, "value") ?: 0.0
            val u = OrbJSON.double(l, "est_usd_per_h") ?: 0.0
            val deg = l["degraded"] == true
            if (overflowIds.contains(tgt)) {
                val prev = tailAgg[src] ?: Triple(0.0, 0.0, false)
                tailAgg[src] = Triple(prev.first + v, prev.second + u, prev.third || deg)
            } else {
                inputLinks.add(
                    OrbResourcesModel.SankeyInputLink(
                        id = "l-$i",
                        source = src,
                        target = tgt,
                        value = v,
                        estUsdPerH = u,
                        degraded = deg,
                    ),
                )
            }
        }
        for ((src, agg) in tailAgg) {
            inputLinks.add(
                OrbResourcesModel.SankeyInputLink(
                    id = "l-tail-$src",
                    source = src,
                    target = tailId,
                    value = agg.first,
                    estUsdPerH = agg.second,
                    degraded = agg.third,
                ),
            )
        }

        if (inputNodes.isNotEmpty()) {
            Canvas(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(180.dp),
            ) {
                val layout = OrbResourcesModel.computeSankeyLayout(
                    inputNodes = inputNodes,
                    inputLinks = inputLinks,
                    width = size.width.toDouble(),
                    height = size.height.toDouble(),
                    metric = metric,
                    marginX = 24.0,
                    marginY = 8.0,
                )
                for (link in layout.links) {
                    val mx = ((link.sourceX + link.targetX) / 2.0).toFloat()
                    val syTop = (link.y0 - link.sourceWidth / 2.0).toFloat()
                    val syBot = (link.y0 + link.sourceWidth / 2.0).toFloat()
                    val tyTop = (link.y1 - link.width / 2.0).toFloat()
                    val tyBot = (link.y1 + link.width / 2.0).toFloat()
                    val path = Path().apply {
                        moveTo(link.sourceX.toFloat(), syTop)
                        cubicTo(mx, syTop, mx, tyTop, link.targetX.toFloat(), tyTop)
                        lineTo(link.targetX.toFloat(), tyBot)
                        cubicTo(mx, tyBot, mx, syBot, link.sourceX.toFloat(), syBot)
                        close()
                    }
                    val col = OrbResourcesModel.parseColor(link.colorHex)
                    drawPath(
                        path = path,
                        color = col.copy(alpha = 0.36f),
                    )
                    if (link.degraded) {
                        drawPath(
                            path = path,
                            color = col.copy(alpha = 0.68f),
                            style = Stroke(
                                width = 2f,
                                pathEffect = PathEffect.dashPathEffect(floatArrayOf(10f, 6f)),
                            ),
                        )
                    }
                }
                for (node in layout.nodes) {
                    drawRoundRect(
                        color = OrbResourcesModel.parseColor(node.colorHex),
                        topLeft = Offset(node.x0.toFloat(), node.y0.toFloat()),
                        size = Size((node.x1 - node.x0).toFloat(), max(4.0, node.y1 - node.y0).toFloat()),
                        cornerRadius = CornerRadius(4f, 4f),
                    )
                }
            }
        }

        // Tappable mission rows for 1-tap drilldown into Fast-DAG
        missions.forEach { m ->
            val mid = OrbJSON.str(m, "id") ?: return@forEach
            val title = OrbJSON.str(m, "title")?.ifEmpty { mid.take(8) } ?: mid.take(8)
            val rateVal = if (lens == OrbResourcesModel.Lens.Compute) {
                if (metric == OrbResourcesModel.Metric.Usd) OrbJSON.double(m, "compute_usd_per_h") ?: 0.0 else OrbJSON.double(m, "vcpu") ?: 0.0
            } else {
                if (metric == OrbResourcesModel.Metric.Usd) OrbJSON.double(m, "inference_usd_per_h") ?: 0.0 else OrbJSON.double(m, "b_tok_per_h") ?: 0.0
            }
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(8.dp))
                    .background(Color.White.copy(alpha = 0.03f))
                    .orbPressClickable { onSelectMission(mid) }
                    .padding(horizontal = 10.dp, vertical = 8.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(title, color = Color.White, fontSize = 13.sp, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(
                        "${OrbJSON.int(m, "subagent_total") ?: 1} spans · tap for Fast-DAG",
                        color = OrbStyle.textSecondary,
                        fontSize = 11.sp,
                    )
                }
                Text(
                    OrbResourcesModel.formatResourceRate(rateVal, lens, metric),
                    color = OrbStyle.textSecondary,
                    fontSize = 11.5.sp,
                    fontFamily = FontFamily.Monospace,
                )
            }
        }
    }
}

@Composable
private fun MissionFastDagCard(
    detail: OrbDict?,
    lens: OrbResourcesModel.Lens,
    metric: OrbResourcesModel.Metric,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(OrbStyle.surface)
            .border(1.dp, OrbStyle.border, RoundedCornerShape(12.dp))
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        if (detail == null) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(160.dp)
                    .clip(RoundedCornerShape(8.dp))
                    .background(Color.White.copy(alpha = 0.04f)),
            )
            return@Column
        }

        val dag = OrbJSON.dict(detail["dag"]) ?: emptyMap()
        val horizonSecs = OrbJSON.double(dag, "horizon_secs") ?: 21600.0
        val bars = OrbJSON.dictList(dag["bars"]).map { b ->
            OrbResourcesModel.DagBarInput(
                id = OrbJSON.str(b, "id") ?: "",
                missionId = OrbJSON.str(b, "mission_id"),
                label = OrbJSON.str(b, "label") ?: "Subagent",
                section = OrbJSON.str(b, "section") ?: "Workers",
                startOffsetSecs = OrbJSON.double(b, "start_offset_secs") ?: 0.0,
                durationSecs = OrbJSON.double(b, "duration_secs") ?: 60.0,
                etaRemainingSecs = OrbJSON.double(b, "eta_remaining_secs"),
                state = OrbJSON.str(b, "state") ?: "pending",
            )
        }
        val rows = OrbResourcesModel.layoutDagRows(bars, horizonSecs)

        Text(
            text = "Subagent Execution Fast-DAG · ${bars.size} spans (${if (metric == OrbResourcesModel.Metric.Usd) "$/h" else if (lens == OrbResourcesModel.Lens.Compute) "vCPU" else "B tok/h"})",
            color = OrbStyle.textSecondary,
            fontSize = 11.sp,
            fontWeight = FontWeight.SemiBold,
        )

        rows.forEach { row ->
            row.sectionHeader?.let { sec ->
                Text(
                    text = sec.uppercase(Locale.US),
                    color = OrbStyle.textSecondary,
                    fontSize = 10.sp,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.padding(top = 4.dp),
                )
            }
            Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                ) {
                    Text(row.bar.label, color = Color.White, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                    Text(
                        OrbResourcesModel.formatDurationCompact(row.bar.durationSecs),
                        color = OrbStyle.textSecondary,
                        fontSize = 11.sp,
                        fontFamily = FontFamily.Monospace,
                    )
                }
                Canvas(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(8.dp),
                ) {
                    val w = size.width
                    drawRoundRect(
                        color = Color.White.copy(alpha = 0.08f),
                        size = size,
                        cornerRadius = CornerRadius(4f, 4f),
                    )
                    val barColor = when (row.bar.state) {
                        "done" -> Color(0xFF80B28D)
                        "active" -> Color(0xFF86AEE4)
                        "capped" -> Color(0xFFD9B23A)
                        else -> Color(0xFF6A6A6A)
                    }
                    val x0 = (row.startFrac * w).toFloat()
                    val bw = max(8f, ((row.endFrac - row.startFrac) * w).toFloat())
                    drawRoundRect(
                        color = barColor,
                        topLeft = Offset(x0, 0f),
                        size = Size(bw, size.height),
                        cornerRadius = CornerRadius(4f, 4f),
                    )
                    row.etaEndFrac?.let { etaEnd ->
                        val ew = max(0f, ((etaEnd - row.endFrac) * w).toFloat())
                        if (ew > 2f) {
                            drawRoundRect(
                                color = barColor.copy(alpha = 0.25f),
                                topLeft = Offset(x0 + bw, 0f),
                                size = Size(ew, size.height),
                                cornerRadius = CornerRadius(4f, 4f),
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun ConsumptionCurveCard(
    overview: OrbDict?,
    detail: OrbDict?,
    isMission: Boolean,
    lens: OrbResourcesModel.Lens,
    metric: OrbResourcesModel.Metric,
) {
    val values: List<Double> = remember(overview, detail, isMission, lens, metric) {
        if (isMission) {
            val tl = OrbJSON.dict(detail?.get("timeline")) ?: return@remember emptyList()
            val obsKey = when {
                lens == OrbResourcesModel.Lens.Compute && metric == OrbResourcesModel.Metric.Raw -> "observed_vcpu"
                lens == OrbResourcesModel.Lens.Compute -> "observed_compute_usd_per_h"
                metric == OrbResourcesModel.Metric.Raw -> "observed_b_tok_per_h"
                else -> "observed_inference_usd_per_h"
            }
            val projKey = obsKey.replace("observed_", "projected_")
            val obs = (tl[obsKey] as? List<*>) ?: emptyList<Any?>()
            val proj = (tl[projKey] as? List<*>) ?: emptyList<Any?>()
            val len = max(obs.size, proj.size)
            (0 until len).map { i ->
                ((obs.getOrNull(i) as? Number)?.toDouble())
                    ?: ((proj.getOrNull(i) as? Number)?.toDouble())
                    ?: 0.0
            }
        } else {
            val ov = overview ?: return@remember emptyList()
            val ts = (ov["timestamps_ms"] as? List<*>) ?: return@remember emptyList()
            if (ts.isEmpty()) return@remember emptyList()
            val sums = DoubleArray(ts.size)
            if (lens == OrbResourcesModel.Lens.Compute) {
                val key = if (metric == OrbResourcesModel.Metric.Usd) "series_usd_per_h" else "series_vcpu"
                for (s in OrbJSON.dictList(OrbJSON.dict(ov["compute"])?.get("sources"))) {
                    val arr = (s[key] as? List<*>) ?: continue
                    for (i in sums.indices) sums[i] += (arr.getOrNull(i) as? Number)?.toDouble() ?: 0.0
                }
            } else {
                val key = if (metric == OrbResourcesModel.Metric.Usd) "series_usd_per_h" else "series_b_tok_per_h"
                for (p in OrbJSON.dictList(OrbJSON.dict(ov["inference"])?.get("pools"))) {
                    val arr = (p[key] as? List<*>) ?: continue
                    for (i in sums.indices) sums[i] += (arr.getOrNull(i) as? Number)?.toDouble() ?: 0.0
                }
            }
            sums.toList()
        }
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(OrbStyle.surface)
            .border(1.dp, OrbStyle.border, RoundedCornerShape(12.dp))
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        val peak = values.maxOrNull() ?: 0.0
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Text(
                text = "Consumption",
                color = OrbStyle.textSecondary,
                fontSize = 11.sp,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                text = "Peak ${OrbResourcesModel.formatResourceRate(peak, lens, metric)}",
                color = OrbStyle.textSecondary,
                fontSize = 11.sp,
                fontFamily = FontFamily.Monospace,
            )
        }
        Canvas(
            modifier = Modifier
                .fillMaxWidth()
                .height(74.dp),
        ) {
            if (values.size < 2) return@Canvas
            val denom = if (peak > 0.0) peak * 1.12 else 1.0
            val path = Path()
            val n = max(1, values.size - 1)
            values.forEachIndexed { i, v ->
                val x = (i.toFloat() / n.toFloat()) * size.width
                val y = size.height - ((v / denom).toFloat() * (size.height - 8f))
                if (i == 0) path.moveTo(x, y) else path.lineTo(x, y)
            }
            drawPath(
                path = path,
                color = if (lens == OrbResourcesModel.Lens.Compute) Color(0xFF86AEE4) else Color(0xFFA08CE0),
                style = Stroke(width = 3.5f),
            )
        }
    }
}
