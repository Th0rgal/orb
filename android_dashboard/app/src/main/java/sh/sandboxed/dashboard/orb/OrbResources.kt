package sh.sandboxed.dashboard.orb

import android.graphics.Paint
import android.graphics.Typeface
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowLeft
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
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
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.layout.SubcomposeLayout
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import java.util.Locale
import kotlin.coroutines.cancellation.CancellationException
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.roundToLong
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

    enum class HeaderTier {
        FullSingleRow,
        CompactSingleRow,
        TwoClusterWrap,
        IndividualWrap,
    }

    fun chooseHeaderTier(
        availableWidthPx: Int,
        minGapPx: Int,
        leftWidthPx: Int,
        rightFullWidthPx: Int,
        rightCompactWidthPx: Int,
    ): HeaderTier = when {
        leftWidthPx + minGapPx + rightFullWidthPx <= availableWidthPx -> HeaderTier.FullSingleRow
        leftWidthPx + minGapPx + rightCompactWidthPx <= availableWidthPx -> HeaderTier.CompactSingleRow
        max(leftWidthPx, rightCompactWidthPx) <= availableWidthPx -> HeaderTier.TwoClusterWrap
        else -> HeaderTier.IndividualWrap
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
        var showLabel: Boolean = true,
        var showSublabel: Boolean = false,
        var labelY: Double = 0.0,
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
        val role: String = "worker",
        val nodeId: String? = null,
        val startOffsetSecs: Double,
        val durationSecs: Double,
        val etaRemainingSecs: Double? = null,
        val state: String,
        val afterIds: List<String> = emptyList(),
    )

    data class DagSpanLayout(
        val bar: DagBarInput,
        val startFrac: Double,
        val endFrac: Double,
        val etaEndFrac: Double?,
    )

    data class DagRowLayout(
        val id: String,
        val bar: DagBarInput,
        val spans: List<DagSpanLayout>,
        val totalDurationSecs: Double,
        val sectionHeader: String?,
        val startFrac: Double,
        val endFrac: Double,
        val etaEndFrac: Double?,
    )

    fun formatIntThousands(value: Double): String {
        val n = max(0L, if (value.isFinite()) value.roundToLong() else 0L)
        val s = n.toString()
        if (s.length <= 3) return s
        val sb = StringBuilder(s.length + (s.length - 1) / 3)
        for (i in s.indices) {
            if (i > 0 && (s.length - i) % 3 == 0) {
                sb.append(',')
            }
            sb.append(s[i])
        }
        return sb.toString()
    }

    fun formatLargeNumber(value: Double): String {
        val safe = if (value.isFinite()) max(0.0, value) else 0.0
        val rounded = safe.roundToLong()
        if (rounded >= 1_000_000L) {
            val m100 = ((safe / 1_000_000.0) * 100.0).roundToLong()
            if (m100 >= 10_000L) {
                return "${formatIntThousands(safe / 1_000_000.0)}M"
            }
            if (m100 >= 1_000L) {
                val m10 = ((safe / 1_000_000.0) * 10.0).roundToLong()
                return if (m10 % 10L == 0L) {
                    "${m10 / 10L}M"
                } else {
                    String.format(Locale.US, "%.1fM", m10.toDouble() / 10.0)
                }
            }
            if (m100 % 100L == 0L) return "${m100 / 100L}M"
            if (m100 % 10L == 0L) return String.format(Locale.US, "%.1fM", m100.toDouble() / 100.0)
            return String.format(Locale.US, "%.2fM", m100.toDouble() / 100.0)
        }
        if (rounded >= 10_000L) {
            val k10 = ((safe / 1_000.0) * 10.0).roundToLong()
            if (k10 >= 10_000L) return "1M"
            if (k10 >= 1_000L) {
                val kInt = (safe / 1_000.0).roundToLong()
                return if (kInt >= 1_000L) "1M" else "${kInt}k"
            }
            return if (k10 % 10L == 0L) {
                "${k10 / 10L}k"
            } else {
                String.format(Locale.US, "%.1fk", k10.toDouble() / 10.0)
            }
        }
        if (rounded >= 1_000L) {
            return formatIntThousands(rounded.toDouble())
        }
        return "$rounded"
    }

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
                    safe >= 100.0 -> "$${formatLargeNumber(safe)}"
                    safe >= 10.0 -> String.format(Locale.US, "$%.1f", safe)
                    else -> String.format(Locale.US, "$%.2f", safe)
                }
            }
            return when {
                safe >= 100.0 -> "$${formatLargeNumber(safe)}/h"
                safe >= 10.0 -> String.format(Locale.US, "$%.1f/h", safe)
                safe >= 0.01 -> String.format(Locale.US, "$%.2f/h", safe)
                safe > 0.0 -> "<$0.01/h"
                else -> "$0.00/h"
            }
        }

        if (lens == Lens.Compute) {
            val rounded1 = (safe * 10.0).roundToLong() / 10.0
            val num = if (safe >= 10.0 || abs(rounded1 - safe.roundToLong()) < 0.05) {
                formatLargeNumber(safe)
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
        marginX: Double? = null,
        marginY: Double? = null,
        density: Double = 1.0,
    ): SankeyLayoutResult {
        val scale = max(0.5, density)
        val effMarginX = marginX ?: (6.0 * scale)
        val effMarginY = marginY ?: (8.0 * scale)
        val nodeWidth = 8.0 * scale
        val nodePadding = 10.0 * scale
        val minNodeH = 6.0 * scale
        val minDrawnNodeH = 4.0 * scale
        val singleLabelHalfH = 9.0 * scale
        val twoLineLabelHalfH = 15.0 * scale
        val labelGap = 3.0 * scale
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

        val innerW = max(60.0 * scale, width - effMarginX * 2.0 - nodeWidth)
        val innerH = max(60.0 * scale, height - effMarginY * 2.0)

        val cols = Array(columns) { mutableListOf<SankeyLayoutNode>() }
        val nodeMap = mutableMapOf<String, SankeyLayoutNode>()

        for (n in inputNodes) {
            if (n.column !in 0 until columns) continue
            val rVal = max(max(rawIn[n.id] ?: 0.0, rawOut[n.id] ?: 0.0), n.fallbackValue)
            val uVal = max(max(usdIn[n.id] ?: 0.0, usdOut[n.id] ?: 0.0), n.fallbackUsd)
            val active = if (metric == Metric.Usd) uVal else rVal
            val x0 = effMarginX + (n.column.toDouble() / max(1, columns - 1).toDouble()) * innerW
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
            col.sortWith { a, b ->
                val aTail = a.id.contains("__other")
                val bTail = b.id.contains("__other")
                if (aTail != bTail) {
                    if (aTail) 1 else -1
                } else {
                    b.value.compareTo(a.value)
                }
            }
            val sumVal = col.sumOf { max(0.0, it.value) }
            val padTotal = max(0, col.size - 1) * nodePadding
            val availH = max(32.0 * scale, innerH - padTotal)
            if (sumVal > 0.0) sharedScale = min(sharedScale, availH / sumVal)
        }
        if (!sharedScale.isFinite() || sharedScale <= 0.0) sharedScale = 1.0

        for (c in 0 until columns) {
            val col = cols[c]
            if (col.isEmpty()) continue
            val heights = col.map { max(minNodeH, it.value * sharedScale) }
            val rawColH = heights.sum() + max(0, col.size - 1) * nodePadding
            val compress = if (rawColH > innerH) innerH / rawColH else 1.0
            val effPad = nodePadding * compress
            val finalH = heights.sumOf { it * compress } + max(0, col.size - 1) * effPad
            var cursorY = effMarginY + max(0.0, (innerH - finalH) / 2.0)
            var lastLabelBottom = Double.NEGATIVE_INFINITY
            for (i in col.indices) {
                val h = max(minDrawnNodeH, heights[i] * compress)
                val rawMidY = cursorY + h / 2.0
                val hasSub = (c == 0 || c == columns - 1) && h >= 32.0 * scale
                val labelHalfH = if (hasSub) twoLineLabelHalfH else singleLabelHalfH
                val minCenterY = effMarginY + labelHalfH
                val maxCenterY = max(minCenterY, height - effMarginY - labelHalfH)
                val clampedY = min(maxCenterY, max(minCenterY, rawMidY))
                if (clampedY - labelHalfH >= lastLabelBottom + labelGap) {
                    col[i].showLabel = true
                    col[i].showSublabel = hasSub
                    col[i].labelY = clampedY
                    lastLabelBottom = clampedY + labelHalfH
                } else {
                    col[i].showLabel = false
                    col[i].showSublabel = false
                    col[i].labelY = clampedY
                }
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
            val nodeH = max(minDrawnNodeH, src.y1 - src.y0)
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
            val nodeH = max(minDrawnNodeH, dst.y1 - dst.y0)
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
                    sourceWidth = max(1.5 * scale, sw),
                    width = max(1.5 * scale, w),
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

    private fun stripVmSectionAffix(section: String): String {
        val trimmed = section.trim()
        if (trimmed.endsWith(" VMs")) {
            val cut = trimmed.dropLast(4).trim()
            return cut.ifEmpty { section }
        }
        return trimmed.ifEmpty { section }
    }

    private fun normalizeDagBarsForLanes(bars: List<DagBarInput>): List<DagBarInput> {
        val vmClassByNode = mutableMapOf<String, String>()
        val nodesWithWorkers = mutableSetOf<String>()

        for (b in bars) {
            val nid = b.nodeId?.trim().orEmpty()
            if (nid.isEmpty()) continue
            if (b.role == "vm") {
                vmClassByNode[nid] = stripVmSectionAffix(b.section)
            } else {
                nodesWithWorkers.add(nid)
            }
        }

        val out = mutableListOf<DagBarInput>()
        for (b in bars) {
            val nid = b.nodeId?.trim().orEmpty()
            if (b.role == "vm") {
                if (nid.isNotEmpty() && nodesWithWorkers.contains(nid)) {
                    continue
                }
                out.add(if (nid.isNotEmpty()) b.copy(section = stripVmSectionAffix(b.section)) else b)
                continue
            }

            val roleLc = b.role.lowercase(Locale.US)
            val sec = when {
                roleLc == "coordinator" || roleLc == "boss" || roleLc == "orchestrator" ->
                    b.section.ifEmpty { "Orchestrator" }
                nid.isNotEmpty() && vmClassByNode.containsKey(nid) ->
                    vmClassByNode.getValue(nid)
                nid.isNotEmpty() && nid != "core" && nid != "local" -> when {
                    nid.startsWith("managed-") -> if (b.section.contains("·")) stripVmSectionAffix(b.section) else "Cloud VMs"
                    nid.startsWith("spark") -> "DGX Spark"
                    else -> "Static fleet"
                }
                else -> b.section
            }
            out.add(b.copy(section = sec))
        }
        return out
    }

    fun layoutDagRows(bars: List<DagBarInput>, horizonSecs: Double): List<DagRowLayout> {
        val safeH = max(60.0, horizonSecs)
        val normalized = normalizeDagBarsForLanes(bars)
        val sectionOrder = mutableListOf<String>()
        val bySection = mutableMapOf<String, MutableList<DagBarInput>>()
        for (b in normalized) {
            if (!bySection.containsKey(b.section)) {
                sectionOrder.add(b.section)
                bySection[b.section] = mutableListOf()
            }
            bySection.getValue(b.section).add(b)
        }
        val orchIdx = sectionOrder.indexOf("Orchestrator")
        if (orchIdx > 0) {
            sectionOrder.removeAt(orchIdx)
            sectionOrder.add(0, "Orchestrator")
        }

        class Lane(
            var lastEndSecs: Double,
            var lastOccFrac: Double,
            var lastNodeId: String?,
            val spans: MutableList<DagSpanLayout>,
        )

        val rows = mutableListOf<DagRowLayout>()
        for (sec in sectionOrder) {
            val secBars = (bySection[sec] ?: emptyList()).sortedWith(
                compareBy<DagBarInput> { it.startOffsetSecs }
                    .thenByDescending { it.durationSecs }
                    .thenBy { it.id },
            )
            val lanes = mutableListOf<Lane>()
            for (b in secBars) {
                val dur = max(30.0, b.durationSecs)
                val sFrac = min(1.0, max(0.0, b.startOffsetSecs / safeH))
                val eFrac = min(1.0, max(sFrac + 0.008, (b.startOffsetSecs + dur) / safeH))
                val etaFrac = if (b.etaRemainingSecs != null && b.etaRemainingSecs > 0.0 && b.state == "active") {
                    min(1.0, max(eFrac, (b.startOffsetSecs + b.durationSecs + b.etaRemainingSecs) / safeH))
                } else {
                    null
                }
                val occEndSecs = b.startOffsetSecs + dur + (if (b.state == "active" && (b.etaRemainingSecs ?: 0.0) > 0.0) (b.etaRemainingSecs ?: 0.0) else 0.0)
                val occEndFrac = etaFrac ?: eFrac
                val nid = b.nodeId?.trim()?.takeIf { it.isNotEmpty() }

                var chosen = -1
                if (nid != null) {
                    for (i in lanes.indices) {
                        val ln = lanes[i]
                        if (ln.lastNodeId == nid && ln.lastEndSecs <= b.startOffsetSecs + 5.0 && ln.lastOccFrac <= sFrac + 0.002) {
                            chosen = i
                            break
                        }
                    }
                }
                if (chosen < 0) {
                    for (i in lanes.indices) {
                        val ln = lanes[i]
                        if (ln.lastEndSecs <= b.startOffsetSecs + 5.0 && ln.lastOccFrac <= sFrac + 0.002) {
                            chosen = i
                            break
                        }
                    }
                }

                val span = DagSpanLayout(bar = b, startFrac = sFrac, endFrac = eFrac, etaEndFrac = etaFrac)
                if (chosen < 0) {
                    lanes.add(Lane(occEndSecs, occEndFrac, nid, mutableListOf(span)))
                } else {
                    val ln = lanes[chosen]
                    ln.lastEndSecs = max(ln.lastEndSecs, occEndSecs)
                    ln.lastOccFrac = max(ln.lastOccFrac, occEndFrac)
                    if (nid != null) ln.lastNodeId = nid
                    ln.spans.add(span)
                }
            }

            lanes.forEachIndexed { li, ln ->
                val hdr = if (li == 0) sec else null
                val primarySpan = ln.spans.lastOrNull { it.bar.state == "active" } ?: ln.spans.last()
                val totalDur = ln.spans.sumOf { max(0.0, it.bar.durationSecs) }
                val rowId = if (ln.spans.size == 1) primarySpan.bar.id else "lane:$sec:$li:${ln.spans.first().bar.id}"
                rows.add(
                    DagRowLayout(
                        id = rowId,
                        bar = primarySpan.bar,
                        spans = ln.spans,
                        totalDurationSecs = totalDur,
                        sectionHeader = hdr,
                        startFrac = primarySpan.startFrac,
                        endFrac = primarySpan.endFrac,
                        etaEndFrac = primarySpan.etaEndFrac,
                    ),
                )
            }
        }
        return rows
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

    fun normalizePoolLabel(id: String, label: String): String {
        var cleanId = id.trim().lowercase(Locale.US)
        if (cleanId.startsWith("in:inf:")) cleanId = cleanId.removePrefix("in:inf:")
        if (cleanId.endsWith(":pool")) cleanId = cleanId.removeSuffix(":pool")
        val head = cleanId.substringBefore(':')
        val cleanLabel = label.trim().lowercase(Locale.US)

        if (
            head == "ethereumfoundation" ||
            head == "ethereum_foundation" ||
            head == "ethereum" ||
            head == "ef" ||
            cleanLabel == "ethereumfoundation" ||
            cleanLabel == "ethereum foundation" ||
            cleanLabel == "ethereum_foundation"
        ) {
            return "EF"
        }

        if (
            (head == "particle" || head == "particleai" || head == "particle_ai" || head == "particle.ai") &&
            (cleanLabel == "particleai" || cleanLabel == "particle_ai")
        ) {
            return "Particle"
        }

        return label
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
    var submode by remember { mutableStateOf("flow") }

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

    val config = LocalConfiguration.current
    val isCompactHeight = config.screenHeightDp < 480
    val sankeyHeightDp = if (isCompactHeight) {
        max(220, min(320, config.screenHeightDp - 82)).dp
    } else {
        val ratio = if (selectedMissionId != null) 0.54f else 0.48f
        max(330, min(460, (config.screenHeightDp * ratio).roundToInt())).dp
    }
    var timelineMenuOpen by remember { mutableStateOf(false) }

    val activeTimelineShort = if (selectedMissionId != null) {
        val horizons = OrbJSON.dictList(detail?.get("available_horizons"))
        val match = horizons.firstOrNull { OrbJSON.str(it, "id") == horizon }
        OrbJSON.str(match, "id")?.ifEmpty { horizon } ?: horizon
    } else {
        range
    }

    val backButton: @Composable () -> Unit = {
        Row(
            modifier = Modifier
                .heightIn(min = 28.dp)
                .clip(RoundedCornerShape(8.dp))
                .orbPressClickable {
                    if (selectedMissionId != null) {
                        selectedMissionId = null
                        detail = null
                    } else {
                        onBack()
                    }
                }
                .padding(horizontal = 4.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            Icon(
                imageVector = Icons.AutoMirrored.Filled.KeyboardArrowLeft,
                contentDescription = "Back",
                tint = OrbStyle.textSecondary,
                modifier = Modifier.size(18.dp),
            )
            Text(
                text = if (selectedMissionId != null) "Fleet" else "Resources",
                color = Color.White,
                fontSize = if (selectedMissionId != null) 14.sp else 15.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
            )
        }
    }

    val submodeGroup: @Composable () -> Unit = {
        CompactPillGroup(
            options = listOf("flow" to "Flow", "dag" to "DAG"),
            selected = submode,
            onSelect = { submode = it },
        )
    }

    val lensGroup: @Composable (Boolean) -> Unit = { fullLabels ->
        CompactPillGroup(
            options = listOf(
                OrbResourcesModel.Lens.Inference to if (fullLabels) "Inference" else "Inf",
                OrbResourcesModel.Lens.Compute to if (fullLabels) "Compute" else "CPU",
            ),
            selected = lens,
            onSelect = { lens = it },
        )
    }

    val metricGroup: @Composable () -> Unit = {
        CompactPillGroup(
            options = listOf(
                OrbResourcesModel.Metric.Raw to if (lens == OrbResourcesModel.Lens.Compute) "vCPU" else "tok",
                OrbResourcesModel.Metric.Usd to "$",
            ),
            selected = metric,
            onSelect = { metric = it },
        )
    }

    val timelinePill: @Composable () -> Unit = {
        Row(
            modifier = Modifier
                .heightIn(min = 28.dp)
                .clip(RoundedCornerShape(8.dp))
                .background(OrbStyle.surface)
                .border(1.dp, OrbStyle.border, RoundedCornerShape(8.dp))
                .orbPressClickable { timelineMenuOpen = true }
                .padding(horizontal = 8.dp, vertical = 3.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            Text(
                text = activeTimelineShort,
                color = Color.White,
                fontSize = 11.5.sp,
                fontFamily = FontFamily.Monospace,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
            )
            Icon(
                imageVector = Icons.Default.KeyboardArrowDown,
                contentDescription = "Timeline window",
                tint = OrbStyle.textSecondary,
                modifier = Modifier.size(13.dp),
            )
        }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(OrbStyle.background),
    ) {
        // Measured adaptive header: single row (full or compact lens labels) when controls fit,
        // wrapping cleanly via FlowRow at large font scales or narrow widths so controls never clip.
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 6.dp, vertical = 6.dp),
        ) {
            AdaptiveResourcesHeader(
                leftCluster = {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(5.dp),
                    ) {
                        backButton()
                        if (selectedMissionId != null) {
                            submodeGroup()
                        }
                    }
                },
                rightFullCluster = {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(5.dp),
                    ) {
                        lensGroup(true)
                        metricGroup()
                        timelinePill()
                    }
                },
                rightCompactCluster = {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(5.dp),
                    ) {
                        lensGroup(false)
                        metricGroup()
                        timelinePill()
                    }
                },
                wrappedContent = {
                    @OptIn(ExperimentalLayoutApi::class)
                    FlowRow(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(5.dp),
                        ) {
                            backButton()
                            if (selectedMissionId != null) {
                                submodeGroup()
                            }
                        }
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(5.dp),
                        ) {
                            lensGroup(false)
                            metricGroup()
                            timelinePill()
                        }
                    }
                },
                ultraNarrowWrappedContent = {
                    @OptIn(ExperimentalLayoutApi::class)
                    FlowRow(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(5.dp),
                        verticalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        backButton()
                        if (selectedMissionId != null) {
                            submodeGroup()
                        }
                        lensGroup(false)
                        metricGroup()
                        timelinePill()
                    }
                },
            )

            Box(modifier = Modifier.align(Alignment.BottomEnd)) {
                DropdownMenu(
                    expanded = timelineMenuOpen,
                    onDismissRequest = { timelineMenuOpen = false },
                    containerColor = OrbStyle.elevated,
                ) {
                    if (selectedMissionId != null) {
                        val horizons = OrbJSON.dictList(detail?.get("available_horizons"))
                            .map { (OrbJSON.str(it, "id") ?: "6h") to (OrbJSON.str(it, "label") ?: "Fast-DAG (6h)") }
                            .ifEmpty { listOf("6h" to "Fast-DAG (6h)") }
                        horizons.forEach { (hid, lbl) ->
                            DropdownMenuItem(
                                text = { Text(lbl, color = Color.White, fontSize = 13.sp) },
                                trailingIcon = if (horizon == hid) {
                                    {
                                        Icon(
                                            imageVector = Icons.Default.Check,
                                            contentDescription = null,
                                            tint = Color.White,
                                            modifier = Modifier.size(15.dp),
                                        )
                                    }
                                } else {
                                    null
                                },
                                onClick = {
                                    horizon = hid
                                    timelineMenuOpen = false
                                },
                            )
                        }
                    } else {
                        FLEET_RANGES.forEach { r ->
                            DropdownMenuItem(
                                text = { Text("Last $r", color = Color.White, fontSize = 13.sp) },
                                trailingIcon = if (range == r) {
                                    {
                                        Icon(
                                            imageVector = Icons.Default.Check,
                                            contentDescription = null,
                                            tint = Color.White,
                                            modifier = Modifier.size(15.dp),
                                        )
                                    }
                                } else {
                                    null
                                },
                                onClick = {
                                    range = r
                                    timelineMenuOpen = false
                                },
                            )
                        }
                    }
                }
            }
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
                    .padding(horizontal = 6.dp, vertical = 2.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                error?.let {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(10.dp))
                            .background(OrbStyle.surface)
                            .border(1.dp, OrbStyle.warning.copy(alpha = 0.35f), RoundedCornerShape(10.dp))
                            .padding(horizontal = 10.dp, vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(it, color = OrbStyle.warning, fontSize = 12.sp, modifier = Modifier.weight(1f))
                    }
                }

                if (selectedMissionId != null) {
                    if (submode == "flow") {
                        MissionFlowCard(
                            detail = detail,
                            lens = lens,
                            metric = metric,
                            canvasHeight = sankeyHeightDp,
                        )
                    } else {
                        MissionFastDagCard(detail = detail)
                    }
                } else {
                    FleetSankeyCard(
                        overview = overview,
                        lens = lens,
                        metric = metric,
                        range = range,
                        canvasHeight = sankeyHeightDp,
                        onSelectMission = {
                            submode = "flow"
                            selectedMissionId = it
                        },
                    )
                }

                ConsumptionCurveCard(
                    overview = overview,
                    detail = detail,
                    isMission = selectedMissionId != null,
                    isCompactHeight = isCompactHeight,
                    lens = lens,
                    metric = metric,
                )
                Spacer(modifier = Modifier.height(10.dp))
            }
        }
    }
}

@Composable
private fun AdaptiveResourcesHeader(
    leftCluster: @Composable () -> Unit,
    rightFullCluster: @Composable () -> Unit,
    rightCompactCluster: @Composable () -> Unit,
    wrappedContent: @Composable () -> Unit,
    ultraNarrowWrappedContent: @Composable () -> Unit,
) {
    SubcomposeLayout(modifier = Modifier.fillMaxWidth()) { constraints ->
        val unbounded = Constraints()
        val leftPlaceable = subcompose("left", leftCluster).first().measure(unbounded)
        val rightFullPlaceable = subcompose("rightFull", rightFullCluster).first().measure(unbounded)
        val rightCompactPlaceable = subcompose("rightCompact", rightCompactCluster).first().measure(unbounded)
        val minGapPx = 6.dp.roundToPx()

        val tier = OrbResourcesModel.chooseHeaderTier(
            availableWidthPx = constraints.maxWidth,
            minGapPx = minGapPx,
            leftWidthPx = leftPlaceable.width,
            rightFullWidthPx = rightFullPlaceable.width,
            rightCompactWidthPx = rightCompactPlaceable.width,
        )

        when (tier) {
            OrbResourcesModel.HeaderTier.FullSingleRow -> {
                val h = max(leftPlaceable.height, rightFullPlaceable.height)
                layout(constraints.maxWidth, h) {
                    leftPlaceable.placeRelative(0, (h - leftPlaceable.height) / 2)
                    rightFullPlaceable.placeRelative(
                        constraints.maxWidth - rightFullPlaceable.width,
                        (h - rightFullPlaceable.height) / 2,
                    )
                }
            }
            OrbResourcesModel.HeaderTier.CompactSingleRow -> {
                val h = max(leftPlaceable.height, rightCompactPlaceable.height)
                layout(constraints.maxWidth, h) {
                    leftPlaceable.placeRelative(0, (h - leftPlaceable.height) / 2)
                    rightCompactPlaceable.placeRelative(
                        constraints.maxWidth - rightCompactPlaceable.width,
                        (h - rightCompactPlaceable.height) / 2,
                    )
                }
            }
            OrbResourcesModel.HeaderTier.TwoClusterWrap -> {
                val wrapped = subcompose("wrapped", wrappedContent).first().measure(
                    constraints.copy(minWidth = constraints.maxWidth, minHeight = 0),
                )
                layout(constraints.maxWidth, wrapped.height) {
                    wrapped.placeRelative(0, 0)
                }
            }
            OrbResourcesModel.HeaderTier.IndividualWrap -> {
                val ultra = subcompose("ultra", ultraNarrowWrappedContent).first().measure(
                    constraints.copy(minWidth = constraints.maxWidth, minHeight = 0),
                )
                layout(constraints.maxWidth, ultra.height) {
                    ultra.placeRelative(0, 0)
                }
            }
        }
    }
}

@Composable
private fun <T> CompactPillGroup(
    options: List<Pair<T, String>>,
    selected: T,
    onSelect: (T) -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier
            .heightIn(min = 28.dp)
            .clip(RoundedCornerShape(8.dp))
            .background(OrbStyle.surface)
            .border(1.dp, OrbStyle.border, RoundedCornerShape(8.dp))
            .padding(2.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        options.forEach { (value, label) ->
            val active = value == selected
            Box(
                modifier = Modifier
                    .heightIn(min = 24.dp)
                    .clip(RoundedCornerShape(6.dp))
                    .background(if (active) Color.White.copy(alpha = 0.12f) else Color.Transparent)
                    .orbPressClickable { onSelect(value) }
                    .padding(horizontal = 8.dp, vertical = 2.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    text = label,
                    color = if (active) Color.White else OrbStyle.textSecondary,
                    fontSize = 11.5.sp,
                    fontWeight = if (active) FontWeight.SemiBold else FontWeight.Medium,
                    maxLines = 1,
                )
            }
        }
    }
}

private fun fitPaintText(raw: String, paint: Paint, maxWidth: Float): Pair<String, Float> {
    val fullW = paint.measureText(raw)
    if (fullW <= maxWidth || raw.length <= 4) return raw to min(fullW, maxWidth)
    val ellipsis = "…"
    val ellW = paint.measureText(ellipsis)
    val count = paint.breakText(raw, true, (maxWidth - ellW).coerceAtLeast(4f), null)
    val prefix = raw.take(count.coerceAtLeast(1)).trimEnd()
    val fitted = "$prefix$ellipsis"
    return fitted to min(maxWidth, paint.measureText(fitted))
}

private fun DrawScope.drawSankeyDiagram(
    layout: OrbResourcesModel.SankeyLayoutResult,
    lens: OrbResourcesModel.Lens,
    metric: OrbResourcesModel.Metric,
) {
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
                    width = 1.dp.toPx(),
                    pathEffect = PathEffect.dashPathEffect(floatArrayOf(4.dp.toPx(), 3.dp.toPx())),
                ),
            )
        }
    }

    val labelPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = android.graphics.Color.WHITE
        textSize = 11.dp.toPx()
        typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
    }
    val subPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = android.graphics.Color.rgb(162, 162, 170)
        textSize = 9.5f.dp.toPx()
        typeface = Typeface.MONOSPACE
    }

    val columns = max(2, layout.columns)
    val lastCol = columns - 1
    val nodeW = layout.nodes.firstOrNull()?.let { max(6.dp.toPx().toDouble(), it.x1 - it.x0) } ?: 8.dp.toPx().toDouble()
    val leftEdge = layout.nodes.filter { it.column == 0 }.maxOfOrNull { it.x1 } ?: (6.dp.toPx().toDouble() + nodeW)
    val rightEdge = layout.nodes.filter { it.column == lastCol }.minOfOrNull { it.x0 }
        ?: max(leftEdge + 80.dp.toPx().toDouble(), size.width.toDouble() - 6.dp.toPx().toDouble() - nodeW)
    val totalSpan = max(80.dp.toPx().toDouble(), rightEdge - leftEdge)
    val segGap = if (columns <= 2) {
        totalSpan
    } else {
        max(60.dp.toPx().toDouble(), (totalSpan / (columns - 1).toDouble()) - nodeW)
    }
    val midMaxPillW = max(48.dp.toPx().toDouble(), segGap * 0.48).toFloat()
    val outerMaxPillW = (if (columns <= 2) {
        max(64.dp.toPx().toDouble(), totalSpan * 0.46)
    } else {
        max(56.dp.toPx().toDouble(), segGap - midMaxPillW / 2.0 - 14.dp.toPx().toDouble())
    }).toFloat()

    val padFromBar = 5.dp.toPx()
    val pillPadX = 6.dp.toPx()
    val pillBg = Color(0xFF111115).copy(alpha = 0.84f)
    val pillBorder = Color.White.copy(alpha = 0.10f)

    // Draw node bars first, then draw inward frosted-dark label badges above bars & ribbons
    for (node in layout.nodes) {
        val nodeH = max(4.dp.toPx(), (node.y1 - node.y0).toFloat())
        drawRoundRect(
            color = OrbResourcesModel.parseColor(node.colorHex),
            topLeft = Offset(node.x0.toFloat(), node.y0.toFloat()),
            size = Size((node.x1 - node.x0).toFloat(), nodeH),
            cornerRadius = CornerRadius(3.dp.toPx(), 3.dp.toPx()),
        )
    }

    for (node in layout.nodes) {
        if (!node.showLabel) continue
        val isLeft = node.column == 0
        val isRight = node.column == lastCol
        val maxPillW = if (isLeft || isRight) outerMaxPillW else midMaxPillW
        val maxTextW = max(28.dp.toPx(), maxPillW - pillPadX * 2f)

        val (fittedTitle, titleW) = fitPaintText(node.label, labelPaint, maxTextW)
        val showSub = (isLeft || isRight) && node.showSublabel
        var fittedSub = ""
        var subW = 0f
        if (showSub) {
            val rateStr = OrbResourcesModel.formatResourceRate(
                if (metric == OrbResourcesModel.Metric.Usd) node.usdValue else node.rawValue,
                lens,
                metric,
            )
            val (fs, sw) = fitPaintText(rateStr, subPaint, maxTextW)
            fittedSub = fs
            subW = sw
        }

        val pillW = min(maxPillW, max(titleW, subW) + pillPadX * 2f)
        val pillH = if (showSub) 30.dp.toPx() else 18.dp.toPx()
        val nodeH = max(4.dp.toPx(), (node.y1 - node.y0).toFloat())
        val centerY = if (node.labelY > 0.0) node.labelY.toFloat() else (node.y0.toFloat() + nodeH / 2f)

        val pillX: Float
        val textX: Float
        when {
            isLeft -> {
                pillX = node.x1.toFloat() + padFromBar
                textX = pillX + pillPadX
                labelPaint.textAlign = Paint.Align.LEFT
            }
            isRight -> {
                pillX = node.x0.toFloat() - padFromBar - pillW
                textX = node.x0.toFloat() - padFromBar - pillPadX
                labelPaint.textAlign = Paint.Align.RIGHT
            }
            else -> {
                val midX = ((node.x0 + node.x1) / 2.0).toFloat()
                pillX = midX - pillW / 2f
                textX = midX
                labelPaint.textAlign = Paint.Align.CENTER
            }
        }
        subPaint.textAlign = labelPaint.textAlign

        drawRoundRect(
            color = pillBg,
            topLeft = Offset(pillX, centerY - pillH / 2f),
            size = Size(pillW, pillH),
            cornerRadius = CornerRadius(5.dp.toPx(), 5.dp.toPx()),
        )
        drawRoundRect(
            color = pillBorder,
            topLeft = Offset(pillX, centerY - pillH / 2f),
            size = Size(pillW, pillH),
            cornerRadius = CornerRadius(5.dp.toPx(), 5.dp.toPx()),
            style = Stroke(width = 0.75f.dp.toPx()),
        )

        if (showSub) {
            drawContext.canvas.nativeCanvas.drawText(fittedTitle, textX, centerY - 2.dp.toPx(), labelPaint)
            drawContext.canvas.nativeCanvas.drawText(fittedSub, textX, centerY + 9.5f.dp.toPx(), subPaint)
        } else {
            drawContext.canvas.nativeCanvas.drawText(fittedTitle, textX, centerY + 3.8f.dp.toPx(), labelPaint)
        }
    }
}

private fun statusDotColor(status: String?): Color = when (status) {
    "active", "running", "waiting_background" -> Color(0xFF3B82F6)
    "completed", "acknowledged", "done" -> OrbStyle.success
    "blocked", "failed" -> OrbStyle.warning
    else -> OrbStyle.textMuted
}

@Composable
private fun FleetSankeyCard(
    overview: OrbDict?,
    lens: OrbResourcesModel.Lens,
    metric: OrbResourcesModel.Metric,
    range: String,
    canvasHeight: Dp,
    onSelectMission: (String) -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(OrbStyle.surface)
            .border(1.dp, OrbStyle.border, RoundedCornerShape(10.dp)),
    ) {
        if (overview == null) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(12.dp)
                    .height(canvasHeight)
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
        val secondaryStamp = if (lens == OrbResourcesModel.Lens.Compute) {
            "${missions.size} missions"
        } else if (metric == OrbResourcesModel.Metric.Usd) {
            "${OrbResourcesModel.formatResourceRate(OrbJSON.double(inference, "window_est_usd") ?: 0.0, lens, metric, false)} ($range)"
        } else {
            range
        }

        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 12.dp, vertical = 9.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = if (lens == OrbResourcesModel.Lens.Compute) "MACHINES → MISSIONS" else "QUOTA POOLS → MISSIONS",
                color = OrbStyle.textSecondary,
                fontSize = 10.5.sp,
                fontWeight = FontWeight.SemiBold,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = primaryStamp,
                    color = Color.White,
                    fontSize = 11.5.sp,
                    fontFamily = FontFamily.Monospace,
                    fontWeight = FontWeight.SemiBold,
                )
                Text(
                    text = "· $secondaryStamp",
                    color = OrbStyle.textSecondary,
                    fontSize = 11.sp,
                    fontFamily = FontFamily.Monospace,
                )
            }
        }

        HorizontalDivider(color = OrbStyle.border, thickness = 1.dp)

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
                val pid = OrbJSON.str(p, "id") ?: "pool-$i"
                val rawLbl = OrbJSON.str(p, "label") ?: "Pool"
                inputNodes.add(
                    OrbResourcesModel.SankeyInputNode(
                        id = pid,
                        column = 0,
                        label = OrbResourcesModel.normalizePoolLabel(pid, rawLbl),
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

        if (inputNodes.isEmpty()) {
            Text(
                text = "No ${lens.id} flow recorded in this window",
                color = OrbStyle.textSecondary,
                fontSize = 12.sp,
                textAlign = TextAlign.Center,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(vertical = 32.dp, horizontal = 16.dp),
            )
        } else {
            Canvas(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(vertical = 2.dp)
                    .height(canvasHeight),
            ) {
                val layout = OrbResourcesModel.computeSankeyLayout(
                    inputNodes = inputNodes,
                    inputLinks = inputLinks,
                    width = size.width.toDouble(),
                    height = size.height.toDouble(),
                    metric = metric,
                    marginX = 6.dp.toPx().toDouble(),
                    marginY = 8.dp.toPx().toDouble(),
                    density = density.toDouble(),
                )
                drawSankeyDiagram(
                    layout = layout,
                    lens = lens,
                    metric = metric,
                )
            }
        }

        if (missions.isNotEmpty()) {
            HorizontalDivider(color = OrbStyle.border, thickness = 1.dp)
            missions.forEachIndexed { idx, m ->
                if (idx > 0) {
                    HorizontalDivider(
                        color = OrbStyle.border,
                        thickness = 1.dp,
                        modifier = Modifier.padding(start = 12.dp),
                    )
                }
                val mid = OrbJSON.str(m, "id") ?: return@forEachIndexed
                val title = OrbJSON.str(m, "title")?.ifEmpty { mid.take(8) } ?: mid.take(8)
                val status = OrbJSON.str(m, "status")
                val rateVal = if (lens == OrbResourcesModel.Lens.Compute) {
                    if (metric == OrbResourcesModel.Metric.Usd) OrbJSON.double(m, "compute_usd_per_h") ?: 0.0 else OrbJSON.double(m, "vcpu") ?: 0.0
                } else {
                    if (metric == OrbResourcesModel.Metric.Usd) OrbJSON.double(m, "inference_usd_per_h") ?: 0.0 else OrbJSON.double(m, "b_tok_per_h") ?: 0.0
                }
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .orbPressClickable { onSelectMission(mid) }
                        .padding(horizontal = 12.dp, vertical = 9.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Box(
                        modifier = Modifier
                            .size(6.dp)
                            .clip(CircleShape)
                            .background(statusDotColor(status)),
                    )
                    Text(
                        text = title,
                        color = Color.White,
                        fontSize = 13.sp,
                        fontWeight = FontWeight.Medium,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false),
                    )
                    Text(
                        text = "· ${OrbResourcesModel.formatLargeNumber((OrbJSON.int(m, "subagent_total") ?: 1).toDouble())} spans",
                        color = OrbStyle.textMuted,
                        fontSize = 11.sp,
                        maxLines = 1,
                    )
                    Spacer(modifier = Modifier.weight(1f))
                    Text(
                        text = OrbResourcesModel.formatResourceRate(rateVal, lens, metric),
                        color = OrbStyle.textSecondary,
                        fontSize = 11.5.sp,
                        fontFamily = FontFamily.Monospace,
                    )
                    Icon(
                        imageVector = Icons.AutoMirrored.Filled.KeyboardArrowRight,
                        contentDescription = null,
                        tint = OrbStyle.textMuted,
                        modifier = Modifier.size(14.dp),
                    )
                }
            }
        }
    }
}

@Composable
private fun MissionFlowCard(
    detail: OrbDict?,
    lens: OrbResourcesModel.Lens,
    metric: OrbResourcesModel.Metric,
    canvasHeight: Dp,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(OrbStyle.surface)
            .border(1.dp, OrbStyle.border, RoundedCornerShape(10.dp)),
    ) {
        if (detail == null) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(12.dp)
                    .height(canvasHeight)
                    .clip(RoundedCornerShape(8.dp))
                    .background(Color.White.copy(alpha = 0.04f)),
            )
            return@Column
        }

        val mission = OrbJSON.dict(detail["mission"]) ?: emptyMap()
        val missionTitle = OrbJSON.str(mission, "title").orEmpty()
        val flow = OrbJSON.dict(detail["flow"]) ?: emptyMap()
        val etaSecs = OrbJSON.double(mission, "eta_remaining_secs")
        val elapsedSecs = OrbJSON.double(mission, "elapsed_secs")

        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 10.dp, vertical = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (missionTitle.isNotEmpty()) {
                Text(
                    text = missionTitle,
                    color = Color.White,
                    fontSize = 12.5.sp,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false),
                )
                Text(
                    text = "·",
                    color = OrbStyle.textMuted,
                    fontSize = 11.sp,
                )
            }
            Text(
                text = if (lens == OrbResourcesModel.Lens.Compute) {
                    "MACHINES → TRACKS → SUBAGENTS"
                } else {
                    "POOLS → TRACKS → SUBAGENTS"
                },
                color = OrbStyle.textSecondary,
                fontSize = 10.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            val stamp = if (etaSecs != null && etaSecs > 0.0) {
                "ETA ~${OrbResourcesModel.formatDurationCompact(etaSecs)}"
            } else if (elapsedSecs != null) {
                OrbResourcesModel.formatDurationCompact(elapsedSecs)
            } else {
                ""
            }
            if (stamp.isNotEmpty()) {
                Text(
                    text = stamp,
                    color = OrbStyle.textSecondary,
                    fontSize = 11.sp,
                    fontFamily = FontFamily.Monospace,
                    maxLines = 1,
                )
            }
        }

        HorizontalDivider(color = OrbStyle.border, thickness = 1.dp)

        val inputNodes = mutableListOf<OrbResourcesModel.SankeyInputNode>()
        val inputLinks = mutableListOf<OrbResourcesModel.SankeyInputLink>()

        val inputs = OrbJSON.dictList(flow["inputs"]).filter { OrbJSON.str(it, "kind") == lens.id }
        inputs.forEachIndexed { idx, inp ->
            val iid = OrbJSON.str(inp, "id") ?: "inp-$idx"
            val rawLbl = OrbJSON.str(inp, "label") ?: "Source"
            inputNodes.add(
                OrbResourcesModel.SankeyInputNode(
                    id = iid,
                    column = 0,
                    label = if (lens == OrbResourcesModel.Lens.Inference) {
                        OrbResourcesModel.normalizePoolLabel(iid, rawLbl)
                    } else {
                        rawLbl
                    },
                    sub = OrbJSON.str(inp, "sub") ?: "",
                    colorHex = RESOURCES_PALETTE[idx % RESOURCES_PALETTE.size],
                    fallbackValue = OrbJSON.double(inp, "weight") ?: 0.0,
                    fallbackUsd = OrbJSON.double(inp, "est_usd_per_h") ?: 0.0,
                ),
            )
        }

        val allTracks = OrbJSON.dictList(flow["tracks"])
        val tracks = allTracks.take(8)
        val visibleTrackIds = tracks.mapNotNull { OrbJSON.str(it, "id") }.toSet()
        tracks.forEachIndexed { idx, trk ->
            inputNodes.add(
                OrbResourcesModel.SankeyInputNode(
                    id = OrbJSON.str(trk, "id") ?: "trk-$idx",
                    column = 1,
                    label = OrbJSON.str(trk, "label") ?: "Track",
                    sub = OrbJSON.str(trk, "sub") ?: "",
                    colorHex = RESOURCES_PALETTE[(idx + 1) % RESOURCES_PALETTE.size],
                ),
            )
        }
        val overflowTrackCount = (allTracks.size - tracks.size).coerceAtLeast(0)
        val tailTrackId = "track:__other__"
        if (overflowTrackCount > 0) {
            inputNodes.add(
                OrbResourcesModel.SankeyInputNode(
                    id = tailTrackId,
                    column = 1,
                    label = "+$overflowTrackCount tracks",
                    sub = "grouped",
                    colorHex = "#6b7280",
                ),
            )
        }

        val allSubs = OrbJSON.dictList(flow["subagents"])
        val subs = allSubs.take(9)
        val visibleSubIds = subs.mapNotNull { OrbJSON.str(it, "id") }.toSet()
        subs.forEachIndexed { idx, sub ->
            inputNodes.add(
                OrbResourcesModel.SankeyInputNode(
                    id = OrbJSON.str(sub, "id") ?: "sub-$idx",
                    column = 2,
                    label = OrbJSON.str(sub, "label") ?: "Subagent",
                    sub = OrbJSON.str(sub, "role") ?: "",
                    colorHex = RESOURCES_PALETTE[(idx + 2) % RESOURCES_PALETTE.size],
                    missionId = OrbJSON.str(sub, "mission_id")?.ifEmpty { null },
                    fallbackValue = if (lens == OrbResourcesModel.Lens.Compute) {
                        OrbJSON.double(sub, "vcpu") ?: 0.0
                    } else {
                        OrbJSON.double(sub, "b_tok_per_h") ?: 0.0
                    },
                    fallbackUsd = if (lens == OrbResourcesModel.Lens.Compute) {
                        OrbJSON.double(sub, "compute_usd_per_h") ?: 0.0
                    } else {
                        OrbJSON.double(sub, "inference_usd_per_h") ?: 0.0
                    },
                ),
            )
        }
        val overflowSubCount = (allSubs.size - subs.size).coerceAtLeast(0)
        val tailSubId = "sub:__other__"
        if (overflowSubCount > 0) {
            inputNodes.add(
                OrbResourcesModel.SankeyInputNode(
                    id = tailSubId,
                    column = 2,
                    label = "+$overflowSubCount spans",
                    sub = "grouped",
                    colorHex = "#6b7280",
                ),
            )
        }

        OrbJSON.dictList(flow["input_to_track"])
            .filter { OrbJSON.str(it, "kind") == lens.id }
            .forEachIndexed { idx, e ->
                val rawTgt = OrbJSON.str(e, "target_id") ?: ""
                val tgt = if (visibleTrackIds.contains(rawTgt)) rawTgt else tailTrackId
                inputLinks.add(
                    OrbResourcesModel.SankeyInputLink(
                        id = "i2t-$idx",
                        source = OrbJSON.str(e, "source_id") ?: "",
                        target = tgt,
                        value = OrbJSON.double(e, "weight") ?: 0.0,
                        estUsdPerH = OrbJSON.double(e, "est_usd_per_h") ?: 0.0,
                        degraded = e["degraded"] == true,
                    ),
                )
            }
        OrbJSON.dictList(flow["track_to_subagent"])
            .filter { OrbJSON.str(it, "kind") == lens.id }
            .forEachIndexed { idx, e ->
                val rawSrc = OrbJSON.str(e, "source_id") ?: ""
                val rawTgt = OrbJSON.str(e, "target_id") ?: ""
                val src = if (visibleTrackIds.contains(rawSrc)) rawSrc else tailTrackId
                val tgt = if (visibleSubIds.contains(rawTgt)) rawTgt else tailSubId
                inputLinks.add(
                    OrbResourcesModel.SankeyInputLink(
                        id = "t2s-$idx",
                        source = src,
                        target = tgt,
                        value = OrbJSON.double(e, "weight") ?: 0.0,
                        estUsdPerH = OrbJSON.double(e, "est_usd_per_h") ?: 0.0,
                        degraded = e["degraded"] == true,
                    ),
                )
            }

        if (inputNodes.isEmpty()) {
            Text(
                text = "No ${lens.id} flow recorded in this window.",
                color = OrbStyle.textSecondary,
                fontSize = 12.sp,
                textAlign = TextAlign.Center,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(vertical = 28.dp),
            )
        } else {
            Canvas(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(vertical = 2.dp)
                    .height(canvasHeight),
            ) {
                val layout = OrbResourcesModel.computeSankeyLayout(
                    inputNodes = inputNodes,
                    inputLinks = inputLinks,
                    width = size.width.toDouble(),
                    height = size.height.toDouble(),
                    metric = metric,
                    marginX = 6.dp.toPx().toDouble(),
                    marginY = 8.dp.toPx().toDouble(),
                    density = density.toDouble(),
                )
                drawSankeyDiagram(
                    layout = layout,
                    lens = lens,
                    metric = metric,
                )
            }
        }
    }
}

@Composable
private fun MissionFastDagCard(
    detail: OrbDict?,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(OrbStyle.surface)
            .border(1.dp, OrbStyle.border, RoundedCornerShape(10.dp)),
    ) {
        if (detail == null) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(12.dp)
                    .height(180.dp)
                    .clip(RoundedCornerShape(8.dp))
                    .background(Color.White.copy(alpha = 0.04f)),
            )
            return@Column
        }

        val mission = OrbJSON.dict(detail["mission"]) ?: emptyMap()
        val etaSecs = OrbJSON.double(mission, "eta_remaining_secs")
        val dag = OrbJSON.dict(detail["dag"]) ?: emptyMap()
        val horizonSecs = OrbJSON.double(dag, "horizon_secs") ?: 21600.0
        val bars = OrbJSON.dictList(dag["bars"]).map { b ->
            OrbResourcesModel.DagBarInput(
                id = OrbJSON.str(b, "id") ?: "",
                missionId = OrbJSON.str(b, "mission_id"),
                label = OrbJSON.str(b, "label") ?: "Subagent",
                section = OrbJSON.str(b, "section") ?: "Workers",
                role = OrbJSON.str(b, "role") ?: "worker",
                nodeId = OrbJSON.str(b, "node_id"),
                startOffsetSecs = OrbJSON.double(b, "start_offset_secs") ?: 0.0,
                durationSecs = OrbJSON.double(b, "duration_secs") ?: 60.0,
                etaRemainingSecs = OrbJSON.double(b, "eta_remaining_secs"),
                state = OrbJSON.str(b, "state") ?: "pending",
            )
        }
        val rows = OrbResourcesModel.layoutDagRows(bars, horizonSecs)
        val laneCount = rows.size
        val spanCount = rows.sumOf { it.spans.size }

        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 10.dp, vertical = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            val missionTitle = OrbJSON.str(mission, "title").orEmpty()
            if (missionTitle.isNotEmpty()) {
                Text(
                    text = missionTitle,
                    color = Color.White,
                    fontSize = 12.5.sp,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false),
                )
                Text(
                    text = "·",
                    color = OrbStyle.textMuted,
                    fontSize = 11.sp,
                )
            }
            Text(
                text = if (laneCount > 0 && spanCount > laneCount) {
                    "${OrbResourcesModel.formatLargeNumber(laneCount.toDouble())} LANES · ${OrbResourcesModel.formatLargeNumber(spanCount.toDouble())} SPANS"
                } else {
                    "${OrbResourcesModel.formatLargeNumber(spanCount.toDouble())} SPANS"
                },
                color = OrbStyle.textSecondary,
                fontSize = 10.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                modifier = Modifier.weight(1f),
            )
            if (etaSecs != null && etaSecs > 0.0) {
                Text(
                    text = "~${OrbResourcesModel.formatDurationCompact(etaSecs)}",
                    color = OrbStyle.textSecondary,
                    fontSize = 11.sp,
                    fontFamily = FontFamily.Monospace,
                )
            }
        }

        HorizontalDivider(color = OrbStyle.border, thickness = 1.dp)

        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            rows.forEach { row ->
                row.sectionHeader?.let { sec ->
                    Text(
                        text = sec.uppercase(Locale.US),
                        color = OrbStyle.textMuted,
                        fontSize = 10.sp,
                        fontWeight = FontWeight.SemiBold,
                        modifier = Modifier.padding(top = 2.dp),
                    )
                }
                Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                    ) {
                        Text(row.bar.label, color = Color.White, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                        val durText = if (row.spans.size > 1) {
                            "${row.spans.size}× ${OrbResourcesModel.formatDurationCompact(row.totalDurationSecs)}"
                        } else {
                            OrbResourcesModel.formatDurationCompact(row.bar.durationSecs)
                        }
                        Text(
                            durText,
                            color = OrbStyle.textSecondary,
                            fontSize = 10.5.sp,
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
                            cornerRadius = CornerRadius(4.dp.toPx(), 4.dp.toPx()),
                        )
                        row.spans.forEachIndexed { spIdx, sp ->
                            val barColor = if (sp.bar.role == "vm") {
                                when (sp.bar.state) {
                                    "active" -> Color(0xFF22959D)
                                    "done" -> Color(0xFF1D9A78)
                                    "capped" -> Color(0xFFD9B23A)
                                    else -> Color(0xFF6A6A6A)
                                }
                            } else {
                                when (sp.bar.state) {
                                    "done" -> Color(0xFF80B28D)
                                    "active" -> Color(0xFF86AEE4)
                                    "capped" -> Color(0xFFD9B23A)
                                    "cancelled" -> Color(0xFF7D8590).copy(alpha = 0.55f)
                                    else -> Color(0xFF6A6A6A)
                                }
                            }
                            val x0 = (sp.startFrac * w).toFloat()
                            val rawBw = max(5.dp.toPx(), ((sp.endFrac - sp.startFrac) * w).toFloat())
                            val bw = if (spIdx + 1 < row.spans.size) {
                                val nextX = (row.spans[spIdx + 1].startFrac * w).toFloat() - 2.dp.toPx()
                                max(4.dp.toPx(), min(rawBw, nextX - x0))
                            } else {
                                rawBw
                            }
                            drawRoundRect(
                                color = barColor,
                                topLeft = Offset(x0, 0f),
                                size = Size(bw, size.height),
                                cornerRadius = CornerRadius(4.dp.toPx(), 4.dp.toPx()),
                            )
                            sp.etaEndFrac?.let { etaEnd ->
                                val ew = max(0f, ((etaEnd - sp.endFrac) * w).toFloat())
                                if (ew > 2f) {
                                    drawRoundRect(
                                        color = barColor.copy(alpha = 0.25f),
                                        topLeft = Offset(x0 + bw, 0f),
                                        size = Size(ew, size.height),
                                        cornerRadius = CornerRadius(4.dp.toPx(), 4.dp.toPx()),
                                    )
                                }
                            }
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
    isCompactHeight: Boolean = false,
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
            val hasActiveFleet = OrbJSON.dictList(ov["missions"]).any { m ->
                val st = OrbJSON.str(m, "status")
                st == "active" || st == "waiting_background" || (OrbJSON.int(m, "subagent_running") ?: 0) > 0
            } || (OrbJSON.double(OrbJSON.dict(ov["compute"]), "active_vcpu") ?: 0.0) > 0.0
            if (hasActiveFleet && sums.size >= 2 && sums[sums.size - 2] > 0.0) {
                val prevVal = sums[sums.size - 2]
                val lastVal = sums[sums.size - 1]
                if (lastVal <= 0.0) {
                    sums[sums.size - 1] = prevVal
                } else if (lastVal < prevVal * 0.45) {
                    val lastStartMs = (ts.lastOrNull() as? Number)?.toDouble()
                    val bucketSecs = OrbJSON.double(ov, "bucket_seconds") ?: 0.0
                    val asOfMs = runCatching { java.time.Instant.parse(OrbJSON.str(ov, "as_of") ?: "").toEpochMilli().toDouble() }.getOrNull()
                    if (lastStartMs != null && asOfMs != null && bucketSecs > 0.0) {
                        val rawFrac = (asOfMs - lastStartMs) / (bucketSecs * 1000.0)
                        if (rawFrac < 0.7) {
                            val frac = min(0.7, max(0.08, rawFrac))
                            val rescaled = min(prevVal * 1.15, lastVal / max(0.25, frac))
                            val w = min(1.0, frac / 0.7)
                            sums[sums.size - 1] = prevVal * (1.0 - w) + max(lastVal, rescaled) * w
                        }
                    }
                }
            }
            sums.toList()
        }
    }

    val peak = values.maxOrNull() ?: 0.0
    val unitLabel = if (metric == OrbResourcesModel.Metric.Usd) "$/H" else if (lens == OrbResourcesModel.Lens.Compute) "VCPU" else "B TOK/H"

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(OrbStyle.surface)
            .border(1.dp, OrbStyle.border, RoundedCornerShape(10.dp)),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 10.dp, vertical = 8.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = "CONSUMPTION · $unitLabel",
                color = OrbStyle.textSecondary,
                fontSize = 10.5.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
            )
            Text(
                text = "Peak ${OrbResourcesModel.formatResourceRate(peak, lens, metric)}",
                color = OrbStyle.textSecondary,
                fontSize = 11.sp,
                fontFamily = FontFamily.Monospace,
            )
        }

        HorizontalDivider(color = OrbStyle.border, thickness = 1.dp)

        if (values.size < 2) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(76.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    text = "Waiting for timeline samples…",
                    color = OrbStyle.textMuted,
                    fontSize = 12.sp,
                )
            }
        } else {
            val accent = if (lens == OrbResourcesModel.Lens.Compute) Color(0xFF5C9EED) else Color(0xFF9E85E6)
            Canvas(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 12.dp, vertical = 6.dp)
                    .height(if (isCompactHeight) 72.dp else 90.dp),
            ) {
                val denom = if (peak > 0.0) peak * 1.12 else 1.0
                val linePath = Path()
                val areaPath = Path()
                val n = max(1, values.size - 1)
                val baseY = size.height - 4.dp.toPx()
                values.forEachIndexed { i, v ->
                    val x = (i.toFloat() / n.toFloat()) * size.width
                    val y = baseY - ((v / denom).toFloat() * (baseY - 6.dp.toPx()))
                    if (i == 0) {
                        linePath.moveTo(x, y)
                        areaPath.moveTo(x, baseY)
                        areaPath.lineTo(x, y)
                    } else {
                        linePath.lineTo(x, y)
                        areaPath.lineTo(x, y)
                    }
                }
                areaPath.lineTo(size.width, baseY)
                areaPath.close()
                drawPath(
                    path = areaPath,
                    brush = Brush.verticalGradient(
                        colors = listOf(accent.copy(alpha = 0.24f), accent.copy(alpha = 0.01f)),
                        startY = 0f,
                        endY = baseY,
                    ),
                )
                drawPath(
                    path = linePath,
                    color = accent,
                    style = Stroke(width = 1.8.dp.toPx()),
                )
            }
        }
    }
}
