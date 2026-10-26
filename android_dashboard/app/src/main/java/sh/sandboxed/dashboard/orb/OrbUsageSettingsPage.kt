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
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** Models › Usage (desktop: UsageSettings.tsx; iOS: OrbUsageSettings): spend over time and top missions. */
internal data class UsageDay(val day: String, val label: String, val usd: Double)
internal data class UsageSpender(val key: String, val name: String, val usd: Double, val requests: Int)

internal fun usageDays(summary: OrbDict): List<UsageDay> = OrbJSON.dictList(summary["by_day"]).map { d ->
    val day = d["day"] as? String ?: ""
    UsageDay(day, day.takeLast(5), ((d["cost_cents"] as? Number)?.toDouble() ?: 0.0) / 100)
}

internal fun usageTopMissions(summary: OrbDict, limit: Int = 5): List<UsageSpender> = OrbJSON.dictList(summary["by_mission"]).map { g ->
    val key = g["key"] as? String ?: ""
    val label = g["label"] as? String ?: ""
    UsageSpender(key.ifEmpty { "none" }, label.ifEmpty { key.ifEmpty { "No mission" } }, ((g["cost_cents"] as? Number)?.toDouble() ?: 0.0) / 100, (g["requests"] as? Number)?.toInt() ?: 0)
}.sortedByDescending { it.usd }.take(limit)

@Composable
fun OrbUsageSettingsPage(core: OrbCore, onBack: () -> Unit) {
    var summary by remember { mutableStateOf<OrbDict?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(Unit) {
        runCatching { core.fetchDict("/api/ai/usage/summary?window=7d") }
            .onSuccess { summary = it; error = null }
            .onFailure { error = "Couldn’t load usage." }
    }
    Column(
        modifier = Modifier.fillMaxSize().background(OrbStyle.background).verticalScroll(rememberScrollState()).padding(horizontal = 20.dp, vertical = 16.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp)
    ) {
        Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Box(
                modifier = Modifier.size(38.dp).clip(CircleShape).background(OrbStyle.surface).border(1.dp, OrbStyle.border, CircleShape).orbPressClickable { onBack() },
                contentAlignment = Alignment.Center
            ) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back", tint = Color.White, modifier = Modifier.size(17.dp)) }
            Text("Usage", color = Color.White, fontSize = 17.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f), textAlign = androidx.compose.ui.text.style.TextAlign.Center)
            Spacer(modifier = Modifier.width(38.dp))
        }
        error?.let { Text(it, color = OrbStyle.warning, fontSize = 12.sp) }
        Text("Spend over the last 7 days", color = OrbStyle.textSecondary, fontSize = 12.sp)
        val days = summary?.let(::usageDays) ?: List(7) { UsageDay("$it", "", 0.0) }
        val max = days.maxOfOrNull { it.usd }?.takeIf { it > 0 } ?: 1.0
        // Fixed height so nothing jumps when the data arrives.
        Row(
            modifier = Modifier.fillMaxWidth().height(140.dp).clip(RoundedCornerShape(12.dp)).background(OrbStyle.surface).padding(12.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            verticalAlignment = Alignment.Bottom
        ) {
            days.forEach { d ->
                Column(modifier = Modifier.weight(1f).fillMaxHeight(), verticalArrangement = Arrangement.Bottom, horizontalAlignment = Alignment.CenterHorizontally) {
                    Box(
                        modifier = Modifier.fillMaxWidth().fillMaxHeight((d.usd / max).toFloat().coerceIn(0.02f, 0.85f))
                            .clip(RoundedCornerShape(3.dp)).background(if (summary == null) OrbStyle.card else OrbStyle.inboxBlue)
                            .semantics { contentDescription = "${d.label}: $${"%.2f".format(d.usd)}" }
                    )
                    Text(d.label, color = OrbStyle.textMuted, fontSize = 9.sp, maxLines = 1)
                }
            }
        }
        Text("Top missions", color = OrbStyle.textSecondary, fontSize = 12.sp)
        val top = summary?.let { usageTopMissions(it) }.orEmpty()
        if (summary != null && top.isEmpty()) Text("No usage in this window.", color = OrbStyle.textMuted, fontSize = 13.sp)
        Column(modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(OrbStyle.surface)) {
            top.forEach { m ->
                Row(modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(m.name, color = Color.White, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text("${m.requests} requests", color = OrbStyle.textMuted, fontSize = 11.sp)
                    }
                    Text("$${"%.2f".format(m.usd)}", color = Color.White, fontSize = 14.sp)
                }
            }
        }
    }
}
