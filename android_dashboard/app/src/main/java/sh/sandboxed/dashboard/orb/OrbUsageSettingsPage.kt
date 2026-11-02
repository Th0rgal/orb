package sh.sandboxed.dashboard.orb

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

/** Models › Usage (desktop: UsageSettings.tsx; iOS: OrbUsageSettings): spend over time and top missions. */
internal data class UsageDay(val day: String, val label: String, val usd: Double)
internal data class UsageSpender(val key: String, val name: String, val usd: Double, val requests: Int)

internal val USAGE_WINDOWS: List<Pair<String, String>> = listOf(
    "24h" to "24 hours",
    "7d" to "7 days",
    "30d" to "30 days",
)

internal fun usageDays(summary: OrbDict): List<UsageDay> = OrbJSON.dictList(summary["by_day"]).map { d ->
    val day = d["day"] as? String ?: ""
    UsageDay(day, day.takeLast(5), ((d["cost_cents"] as? Number)?.toDouble() ?: 0.0) / 100)
}

internal fun usageTotalUsd(summary: OrbDict): Double {
    val totalsCents = (OrbJSON.dict(summary["totals"])?.get("cost_cents") as? Number)?.toDouble()
    if (totalsCents != null) return totalsCents / 100.0
    return usageDays(summary).sumOf { it.usd }
}

internal fun usageTopMissions(summary: OrbDict, limit: Int = 5): List<UsageSpender> = OrbJSON.dictList(summary["by_mission"]).map { g ->
    val key = g["key"] as? String ?: ""
    val label = g["label"] as? String ?: ""
    UsageSpender(key.ifEmpty { "none" }, label.ifEmpty { key.ifEmpty { "No mission" } }, ((g["cost_cents"] as? Number)?.toDouble() ?: 0.0) / 100, (g["requests"] as? Number)?.toInt() ?: 0)
}.sortedByDescending { it.usd }.take(limit)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun OrbUsageSettingsPage(core: OrbCore, onBack: () -> Unit) {
    val scope = rememberCoroutineScope()
    var window by remember { mutableStateOf("7d") }
    val cacheKey = remember(window) { "usage_summary_$window" }
    var summary by remember(cacheKey) { mutableStateOf(OrbReadCache.readMemoryDict(cacheKey)) }
    var error by remember(cacheKey) { mutableStateOf<String?>(null) }
    var isRefreshing by remember { mutableStateOf(false) }

    suspend fun load(forWindow: String) {
        val key = "usage_summary_$forWindow"
        if (summary == null) {
            val diskCached = OrbReadCache.loadDictAsync(key)
            if (diskCached != null && forWindow == window) {
                summary = diskCached
            }
        }
        try {
            val fresh = core.fetchDict("/api/ai/usage/summary?window=$forWindow&compact=true&top_limit=5")
            OrbReadCache.saveDict(key, fresh)
            if (forWindow == window) {
                summary = fresh
                error = null
            }
        } catch (c: CancellationException) {
            throw c
        } catch (_: Throwable) {
            if (forWindow == window) {
                error = "Couldn’t load usage. Pull to retry."
            }
        }
    }

    LaunchedEffect(window) {
        load(window)
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(OrbStyle.background)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp, vertical = 14.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            OrbCircle(
                icon = Icons.AutoMirrored.Filled.ArrowBack,
                size = 38.dp,
                iconSize = 17.dp,
                contentDescription = "Back",
                modifier = Modifier.orbPressClickable { onBack() }
            )
            Text(
                text = "Usage",
                color = Color.White,
                fontSize = 17.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.weight(1f),
                textAlign = TextAlign.Center
            )
            Spacer(modifier = Modifier.width(38.dp))
        }

        PullToRefreshBox(
            isRefreshing = isRefreshing,
            onRefresh = {
                scope.launch {
                    isRefreshing = true
                    try {
                        load(window)
                    } finally {
                        isRefreshing = false
                    }
                }
            },
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth()
        ) {
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 20.dp, vertical = 4.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp)
            ) {
                error?.let { Text(it, color = OrbStyle.warning, fontSize = 12.sp) }

                Text("Spend over time", color = OrbStyle.textSecondary, fontSize = 12.sp)

                // Segmented window selector matching iOS OrbUsageSettings (24h / 7d / 30d)
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(10.dp))
                        .background(OrbStyle.surface)
                        .border(1.dp, OrbStyle.border, RoundedCornerShape(10.dp))
                        .padding(3.dp),
                    horizontalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    USAGE_WINDOWS.forEach { (tag, label) ->
                        val active = window == tag
                        Box(
                            modifier = Modifier
                                .weight(1f)
                                .clip(RoundedCornerShape(8.dp))
                                .background(if (active) OrbStyle.elevated else Color.Transparent)
                                .orbPressClickable { window = tag }
                                .padding(vertical = 7.dp),
                            contentAlignment = Alignment.Center
                        ) {
                            Text(
                                text = label,
                                color = if (active) Color.White else OrbStyle.textSecondary,
                                fontSize = 12.sp,
                                fontWeight = FontWeight.SemiBold,
                                maxLines = 1,
                                softWrap = false
                            )
                        }
                    }
                }

                val currentSummary = summary
                val days = currentSummary?.let(::usageDays) ?: List(7) { UsageDay("$it", "", 0.0) }
                val totalUsd = currentSummary?.let(::usageTotalUsd) ?: 0.0
                val hasSpend = days.any { it.usd > 0.0 } || totalUsd > 0.0
                val max = days.maxOfOrNull { it.usd }?.takeIf { it > 0 } ?: 1.0

                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(14.dp))
                        .background(OrbStyle.surface)
                        .border(1.dp, OrbStyle.border, RoundedCornerShape(14.dp))
                ) {
                    if (currentSummary != null && !hasSpend) {
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(92.dp)
                                .padding(16.dp),
                            contentAlignment = Alignment.CenterStart
                        ) {
                            Text("No spend recorded in this window.", color = OrbStyle.textMuted, fontSize = 13.sp)
                        }
                    } else {
                        val skeletonHeights = listOf(0.32f, 0.55f, 0.24f, 0.72f, 0.44f, 0.62f, 0.38f)
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(148.dp)
                                .padding(horizontal = 12.dp, vertical = 12.dp)
                                .orbShimmer(active = currentSummary == null),
                            horizontalArrangement = Arrangement.spacedBy(6.dp),
                            verticalAlignment = Alignment.Bottom
                        ) {
                            days.forEachIndexed { idx, d ->
                                val frac = if (currentSummary == null) {
                                    skeletonHeights[idx % skeletonHeights.size]
                                } else {
                                    (d.usd / max).toFloat().coerceIn(0.03f, 0.88f)
                                }
                                Column(
                                    modifier = Modifier
                                        .weight(1f)
                                        .fillMaxHeight(),
                                    verticalArrangement = Arrangement.Bottom,
                                    horizontalAlignment = Alignment.CenterHorizontally
                                ) {
                                    Box(
                                        modifier = Modifier
                                            .fillMaxWidth()
                                            .fillMaxHeight(frac)
                                            .clip(RoundedCornerShape(3.dp))
                                            .background(if (currentSummary == null) OrbStyle.card else OrbStyle.inboxBlue)
                                            .semantics {
                                                contentDescription = if (currentSummary == null) {
                                                    "Loading spend per day"
                                                } else {
                                                    "${d.label}: $${"%.2f".format(d.usd)}"
                                                }
                                            }
                                    )
                                    if (d.label.isNotEmpty() && days.size <= 10) {
                                        Text(d.label, color = OrbStyle.textMuted, fontSize = 9.sp, maxLines = 1)
                                    }
                                }
                            }
                        }
                    }

                    if (currentSummary != null) {
                        HorizontalDivider(color = OrbStyle.border)
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 14.dp, vertical = 11.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Text("Total", color = OrbStyle.textSecondary, fontSize = 14.sp, modifier = Modifier.weight(1f))
                            Text(
                                text = "$${"%.2f".format(totalUsd)}",
                                color = Color.White,
                                fontSize = 14.sp,
                                fontWeight = FontWeight.SemiBold,
                                fontFamily = FontFamily.Monospace
                            )
                        }
                    }
                }

                val top = currentSummary?.let { usageTopMissions(it) }.orEmpty()
                if (top.isNotEmpty()) {
                    Text("Top missions", color = OrbStyle.textSecondary, fontSize = 12.sp)
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(14.dp))
                            .background(OrbStyle.surface)
                            .border(1.dp, OrbStyle.border, RoundedCornerShape(14.dp))
                    ) {
                        top.forEachIndexed { idx, m ->
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(horizontal = 14.dp, vertical = 10.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Column(modifier = Modifier.weight(1f)) {
                                    Text(m.name, color = Color.White, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                    Text("${m.requests} requests", color = OrbStyle.textMuted, fontSize = 11.sp)
                                }
                                Text(
                                    text = "$${"%.2f".format(m.usd)}",
                                    color = Color.White,
                                    fontSize = 14.sp,
                                    fontFamily = FontFamily.Monospace
                                )
                            }
                            if (idx < top.size - 1) {
                                HorizontalDivider(color = OrbStyle.border)
                            }
                        }
                    }
                }
                Spacer(modifier = Modifier.height(16.dp))
            }
        }
    }
}
