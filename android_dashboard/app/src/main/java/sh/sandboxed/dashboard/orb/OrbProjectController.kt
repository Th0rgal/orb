package sh.sandboxed.dashboard.orb

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import java.util.UUID
import kotlin.math.roundToInt

/**
 * Pure model mirroring `orb/src/cronSchema.ts`, `orb/src/Controller.tsx`,
 * `orb/src/ProjectSettings.tsx`, and iOS `OrbControllerModel` in `OrbProjectController.swift`.
 */
object OrbControllerModel {
    enum class CronState(val label: String) {
        Running("Running"),
        Paused("Paused"),
        Attention("Attention"),
        Scheduled("Scheduled")
    }

    sealed class TimelineEntry {
        abstract val key: String

        data class Day(override val key: String, val label: String) : TimelineEntry()
        data class Run(override val key: String, val run: OrbDict) : TimelineEntry()
        data class Steer(override val key: String, val steer: OrbDict) : TimelineEntry()
        data class Silent(override val key: String, val runs: List<OrbDict>) : TimelineEntry()
        data class Failed(override val key: String, val runs: List<OrbDict>, val error: String) : TimelineEntry()
    }

    const val NO_PROJECT_LIMIT = 0

    fun scheduleExpression(raw: Any?): String {
        if (raw is String) return raw.trim()
        val obj = OrbJSON.dict(raw) ?: return ""
        val kind = OrbJSON.str(obj, "kind").orEmpty()
        if (kind == "interval") {
            val mins = OrbJSON.int(obj, "minutes") ?: 0
            if (mins > 0) {
                if (mins % 1440 == 0) return "every ${mins / 1440}d"
                if (mins % 60 == 0) return "every ${mins / 60}h"
                return "every ${mins}m"
            }
        }
        if (kind == "cron") return OrbJSON.str(obj, "expr").orEmpty()
        if (kind == "once") return OrbJSON.str(obj, "run_at").orEmpty()
        return OrbJSON.str(obj, "display").orEmpty()
    }

    fun continuityEnabled(settings: OrbDict?, job: OrbDict?): Boolean {
        (settings?.get("continuity") as? Boolean)?.let { return it }
        (job?.get("continuity") as? Boolean)?.let { return it }
        val ctx = job?.get("context_from")
        if (ctx is String) return ctx.trim().equals("self", ignoreCase = true)
        if (ctx is List<*>) {
            return ctx.any { (it as? String)?.trim()?.equals("self", ignoreCase = true) == true }
        }
        return false
    }

    /** Normalizes `skills` array or legacy singular `skill` string from `settings` then `job` (`orb/src/cronSchema.ts`). */
    fun skillsOf(settings: OrbDict?, job: OrbDict?): List<String> {
        for (source in listOfNotNull(settings, job)) {
            val rawSkills = source["skills"]
            if (rawSkills is List<*>) {
                return rawSkills.mapNotNull { (it as? String)?.trim()?.takeIf { s -> s.isNotEmpty() } }
            }
            val single = OrbJSON.str(source, "skill")
            if (!single.isNullOrEmpty()) return listOf(single)
        }
        return emptyList()
    }

    /**
     * Builds either a full cron creation payload or a changed-fields edit patch (`orb/src/ControllerSettings.tsx`).
     * Omitting unchanged fields prevents script-only controllers (`prompt == ""`) from failing Core's `prompt cannot be empty` check.
     */
    fun buildCronPatch(
        existingView: OrbDict?,
        defaultDeliver: String,
        name: String,
        schedule: String,
        prompt: String,
        skills: List<String>,
        deliver: String,
        model: String,
        reasoningEffort: String,
        continuity: Boolean
    ): Map<String, Any?> {
        val trimmedName = name.trim()
        val trimmedSchedule = schedule.trim()
        val trimmedDeliver = deliver.trim()
        val trimmedModel = model.trim()
        val trimmedEffort = reasoningEffort.trim()

        val existingJob = OrbJSON.dict(existingView?.get("job"))
        if (existingJob == null) {
            return LinkedHashMap<String, Any?>().apply {
                put("name", trimmedName)
                put("schedule", trimmedSchedule)
                put("prompt", prompt)
                put("skills", skills)
                put("deliver", trimmedDeliver.ifEmpty { defaultDeliver })
                if (trimmedModel.isNotEmpty()) put("model", trimmedModel)
                if (trimmedEffort.isNotEmpty()) put("reasoning_effort", trimmedEffort)
                if (continuity) put("continuity", true)
            }
        }

        val existingSettings = OrbJSON.dict(existingView?.get("settings")) ?: existingJob
        val baseName = OrbJSON.str(existingJob, "name").orEmpty()
        val rawSchedule = scheduleExpression(existingJob["schedule"]).trim()
        val baseSchedule = rawSchedule.ifEmpty { "every 30m" }
        val basePrompt = OrbJSON.rawStr(existingSettings, "prompt").orEmpty()
        val baseSkills = skillsOf(existingSettings, existingJob)
        val baseDeliver = (OrbJSON.str(existingSettings, "deliver") ?: OrbJSON.str(existingJob, "deliver")).orEmpty()
        val baseModel = OrbJSON.str(existingSettings, "model").orEmpty()
        val baseEffort = OrbJSON.str(existingSettings, "reasoning_effort").orEmpty()
        val baseContinuity = continuityEnabled(existingSettings, existingJob)

        return LinkedHashMap<String, Any?>().apply {
            if (trimmedName != baseName) put("name", trimmedName)
            if (trimmedSchedule != baseSchedule) put("schedule", trimmedSchedule)
            if (prompt != basePrompt) put("prompt", prompt)
            if (skills != baseSkills) put("skills", skills)
            if (trimmedDeliver != baseDeliver) put("deliver", trimmedDeliver)
            if (trimmedModel != baseModel) put("model", trimmedModel)
            if (trimmedEffort != baseEffort) put("reasoning_effort", trimmedEffort)
            if (continuity != baseContinuity) put("continuity", continuity)
        }
    }

    /** Translates `continuity` into Hermes `context_from` without dropping sibling context refs. */
    fun hermesPatch(patch: Map<String, Any?>, existingJob: OrbDict? = null): Map<String, Any?> {
        val out = LinkedHashMap<String, Any?>(patch)
        val cont = out.remove("continuity") as? Boolean ?: return out
        val refs = mutableListOf<String>()
        val rawCtx = existingJob?.get("context_from")
        when (rawCtx) {
            is String -> if (rawCtx.isNotBlank()) refs += rawCtx.trim()
            is List<*> -> rawCtx.mapNotNull { (it as? String)?.trim()?.takeIf { s -> s.isNotEmpty() } }.forEach { refs += it }
        }
        refs.removeAll { it.equals("self", ignoreCase = true) }
        if (cont) refs += "self"
        out["context_from"] = refs
        return out
    }

    fun cronState(job: OrbDict?, running: Boolean = false): CronState {
        if (job == null) return CronState.Scheduled
        val enabled = if (job.containsKey("enabled") && job["enabled"] != null) {
            OrbJSON.bool(job, "enabled") != false
        } else {
            true
        }
        val state = OrbJSON.str(job, "state").orEmpty()
        if (!enabled || state == "paused") return CronState.Paused
        if (running || state == "running") return CronState.Running
        val streak = OrbJSON.int(job, "failure_streak") ?: 0
        val lastStatus = OrbJSON.str(job, "last_status").orEmpty()
        if (streak > 0 || (lastStatus.isNotEmpty() && lastStatus != "ok")) return CronState.Attention
        return CronState.Scheduled
    }

    fun untilLabel(iso: String?, nowMs: Long = System.currentTimeMillis()): String {
        val targetMs = OrbJSON.dateEpochMs(iso) ?: return ""
        val deltaSecs = (targetMs - nowMs) / 1000.0
        if (deltaSecs <= 0.0) return "due"
        val mins = (deltaSecs / 60.0).roundToInt()
        if (mins < 1) return "in <1m"
        if (mins < 60) return "in ${mins}m"
        return "in ${mins / 60}h ${mins % 60}m"
    }

    fun durationLabel(secs: Double?): String {
        if (secs == null) return ""
        val total = maxOf(0, secs.roundToInt())
        if (total < 60) return "${total}s"
        return "%dm %02ds".format(Locale.US, total / 60, total % 60)
    }

    fun dayLabel(epochMs: Long, nowMs: Long = System.currentTimeMillis(), zone: ZoneId = ZoneId.systemDefault()): String {
        val date = Instant.ofEpochMilli(epochMs).atZone(zone).toLocalDate()
        val today = Instant.ofEpochMilli(nowMs).atZone(zone).toLocalDate()
        if (date == today) return "Today"
        if (date == today.minusDays(1)) return "Yesterday"
        return DateTimeFormatter.ofPattern("EEEE, MMM d", Locale.US).format(date)
    }

    /** Builds newest-first controller timeline entries, folding consecutive silent or identical failed ticks. */
    fun buildEntries(
        runs: List<OrbDict>,
        steers: List<OrbDict> = emptyList(),
        nowMs: Long = System.currentTimeMillis(),
        zone: ZoneId = ZoneId.systemDefault()
    ): List<TimelineEntry> {
        data class RawItem(
            val at: String,
            val epochMs: Long,
            val run: OrbDict?,
            val steer: OrbDict?
        )

        val items = mutableListOf<RawItem>()
        for (run in runs) {
            val at = OrbJSON.str(run, "at").orEmpty()
            val epoch = OrbJSON.dateEpochMs(at) ?: 0L
            items += RawItem(at = at, epochMs = epoch, run = run, steer = null)
        }
        for (steer in steers) {
            val consumed = OrbJSON.str(steer, "consumed_at").orEmpty()
            if (consumed.isEmpty()) continue
            val epoch = OrbJSON.dateEpochMs(consumed) ?: 0L
            items += RawItem(at = consumed, epochMs = epoch, run = null, steer = steer)
        }
        items.sortByDescending { it.epochMs }

        val out = mutableListOf<TimelineEntry>()
        var currentDay = ""
        for (item in items) {
            val parsedMs = OrbJSON.dateEpochMs(item.at)
            if (parsedMs != null) {
                val label = dayLabel(parsedMs, nowMs = nowMs, zone = zone)
                if (label.isNotEmpty() && label != currentDay) {
                    currentDay = label
                    out += TimelineEntry.Day(key = "day:$label", label = label)
                }
            }
            val steer = item.steer
            if (steer != null) {
                val sid = OrbJSON.str(steer, "id") ?: item.at
                out += TimelineEntry.Steer(key = "steer:$sid", steer = steer)
                continue
            }
            val run = item.run ?: continue
            val rid = OrbJSON.str(run, "id") ?: item.at
            val status = OrbJSON.str(run, "status").orEmpty()
            val running = status == "running" || status == "claimed"
            val errText = OrbJSON.str(run, "error").orEmpty()
            val isFailed = status == "failed" || errText.isNotEmpty()
            val report = OrbJSON.str(run, "report").orEmpty()
            if (isFailed && !running && report.isEmpty()) {
                val err = errText.ifEmpty { "failed" }
                val prev = out.lastOrNull()
                if (prev is TimelineEntry.Failed && prev.error == err) {
                    out[out.lastIndex] = prev.copy(runs = prev.runs + run)
                } else {
                    out += TimelineEntry.Failed(key = "f:$rid", runs = listOf(run), error = err)
                }
            } else if (OrbJSON.bool(run, "silent") == true && !running && errText.isEmpty()) {
                val prev = out.lastOrNull()
                if (prev is TimelineEntry.Silent) {
                    out[out.lastIndex] = prev.copy(runs = prev.runs + run)
                } else {
                    out += TimelineEntry.Silent(key = "s:$rid", runs = listOf(run))
                }
            } else {
                out += TimelineEntry.Run(key = rid, run = run)
            }
        }
        return out
    }

    fun projectLimitOf(grant: OrbDict?): Int? {
        val n = OrbJSON.int(grant, "parallel_missions") ?: return null
        return if (n > 0) n else null
    }

    fun parseProjectLimit(raw: String): Result<Int> {
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) return Result.success(NO_PROJECT_LIMIT)
        val n = if (trimmed.all { it.isDigit() }) trimmed.toIntOrNull() else null
        if (n == null || n < 1) {
            return Result.failure(IllegalArgumentException("Enter 1 or more, or leave empty for no limit."))
        }
        return Result.success(n)
    }
}

enum class OrbAutomationTab(val label: String) {
    Controller("Controller"),
    Crons("Crons"),
    Grant("Grant")
}

private fun cronStateColor(state: OrbControllerModel.CronState): Color = when (state) {
    OrbControllerModel.CronState.Running -> OrbStyle.success
    OrbControllerModel.CronState.Paused -> OrbStyle.textMuted
    OrbControllerModel.CronState.Attention -> OrbStyle.warning
    OrbControllerModel.CronState.Scheduled -> Color(0xFF4DA3FF)
}

private fun shortTimeLabel(iso: String?): String {
    val ms = OrbJSON.dateEpochMs(iso) ?: return ""
    val fmt = DateTimeFormatter.ofPattern("HH:mm", Locale.US)
    return fmt.format(Instant.ofEpochMilli(ms).atZone(ZoneId.systemDefault()))
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun OrbProjectAutomationPage(
    core: OrbCore,
    project: OrbRow,
    onBack: () -> Unit
) {
    val scope = rememberCoroutineScope()
    val slug = remember(project) { OrbProjectAppearance.slug(project).ifEmpty { project.id } }
    val projectName = remember(project) { project.str("title", "name", "slug") ?: project.id }

    var tab by remember { mutableStateOf(OrbAutomationTab.Controller) }
    var controllerView by remember { mutableStateOf<OrbDict?>(null) }
    var steers by remember { mutableStateOf<OrbDict?>(null) }
    var crons by remember { mutableStateOf<List<OrbDict>>(emptyList()) }
    var cronDefaults by remember { mutableStateOf<OrbDict?>(null) }
    var grant by remember { mutableStateOf<OrbDict?>(null) }

    var limitDraft by remember { mutableStateOf("") }
    var limitDirty by remember { mutableStateOf(false) }
    var limitSaving by remember { mutableStateOf(false) }
    var limitSaved by remember { mutableStateOf(false) }

    var steerText by remember { mutableStateOf("") }
    var steerRunNow by remember { mutableStateOf(true) }
    var steerSending by remember { mutableStateOf(false) }
    var actionBusy by remember { mutableStateOf<String?>(null) }

    var isRefreshing by remember { mutableStateOf(false) }
    var editingController by remember { mutableStateOf(false) }
    var creatingCron by remember { mutableStateOf(false) }
    var selectedCron by remember { mutableStateOf<OrbDict?>(null) }
    var expandedSilentKeys by remember { mutableStateOf<Set<String>>(emptySet()) }
    var error by remember { mutableStateOf<String?>(null) }

    suspend fun loadController() {
        try {
            controllerView = core.fetchDict("/api/projects/${core.encodeComponent(slug)}/controller?limit=40")
            steers = runCatching { core.fetchDict("/api/projects/${core.encodeComponent(slug)}/steers") }.getOrNull()
            error = null
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            error = e.message
        }
    }

    suspend fun loadCrons() {
        runCatching { core.fetchDict("/api/projects/${core.encodeComponent(slug)}/crons") }.onSuccess { raw ->
            crons = OrbJSON.dictList(raw["jobs"])
        }
        cronDefaults = runCatching { core.fetchDict("/api/projects/${core.encodeComponent(slug)}/crons/defaults") }.getOrNull()
    }

    suspend fun loadGrant() {
        val raw = runCatching { core.fetchDict("/api/projects/${core.encodeComponent(slug)}/grant") }.getOrNull() ?: return
        val g = OrbJSON.dict(raw["grant"])
        grant = g
        if (!limitDirty) {
            limitDraft = OrbControllerModel.projectLimitOf(g)?.toString().orEmpty()
        }
    }

    suspend fun loadAll() = coroutineScope {
        val a = async { loadController() }
        val b = async { loadCrons() }
        val c = async { loadGrant() }
        a.await(); b.await(); c.await()
    }

    LaunchedEffect(slug) {
        isRefreshing = true
        try { loadAll() } finally { isRefreshing = false }
    }

    val openCron = selectedCron
    if (openCron != null) {
        val cronId = OrbJSON.str(openCron, "id").orEmpty()
        OrbProjectCronDetailSubpage(
            core = core,
            slug = slug,
            cronId = cronId,
            initialJob = openCron,
            onBack = {
                selectedCron = null
                scope.launch { loadCrons() }
            },
            onChanged = {
                scope.launch { loadCrons() }
            }
        )
        return
    }

    val controllerJob = OrbJSON.dict(controllerView?.get("job"))
    val controllerRuns = OrbJSON.dictList(controllerView?.get("runs"))
    val controllerRunning = controllerRuns.any {
        val st = OrbJSON.str(it, "status")
        st == "running" || st == "claimed"
    }

    suspend fun runControllerAction(action: String) {
        if (actionBusy != null) return
        actionBusy = action
        try {
            val next = OrbJSON.dict(
                core.request(
                    "/api/projects/${core.encodeComponent(slug)}/controller/action",
                    "POST",
                    body = mapOf("action" to action)
                )
            )
            if (next != null) controllerView = next
            error = null
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            error = e.message
        } finally {
            actionBusy = null
        }
    }

    suspend fun sendSteer() {
        val body = steerText.trim()
        if (body.isEmpty() || steerSending) return
        steerSending = true
        try {
            val next = OrbJSON.dict(
                core.request(
                    "/api/projects/${core.encodeComponent(slug)}/steers",
                    "POST",
                    headers = mapOf("Idempotency-Key" to UUID.randomUUID().toString()),
                    body = mapOf("body" to body, "origin" to "orb")
                )
            )
            if (next != null) steers = next
            steerText = ""
            if (steerRunNow && !controllerRunning && controllerJob != null) {
                runCatching {
                    core.request(
                        "/api/projects/${core.encodeComponent(slug)}/controller/action",
                        "POST",
                        body = mapOf("action" to "run")
                    )
                }
                loadController()
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            error = e.message
        } finally {
            steerSending = false
        }
    }

    suspend fun saveProjectLimit() {
        val value = OrbControllerModel.parseProjectLimit(limitDraft).getOrElse { err ->
            error = err.message
            return
        }
        limitSaving = true
        try {
            val res = OrbJSON.dict(
                core.request(
                    "/api/projects/${core.encodeComponent(slug)}/grant",
                    "POST",
                    body = mapOf("parallel_missions" to value)
                )
            )
            grant = OrbJSON.dict(res?.get("grant"))
            limitDraft = OrbControllerModel.projectLimitOf(grant)?.toString().orEmpty()
            limitDirty = false
            limitSaved = true
            error = null
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            error = e.message
        } finally {
            limitSaving = false
        }
    }

    Column(modifier = Modifier.fillMaxSize().background(OrbStyle.background)) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                modifier = Modifier
                    .size(38.dp)
                    .clip(CircleShape)
                    .background(OrbStyle.surface)
                    .border(1.dp, OrbStyle.border, CircleShape)
                    .orbPressClickable { onBack() },
                contentAlignment = Alignment.Center
            ) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back", tint = Color.White, modifier = Modifier.size(17.dp))
            }
            Text(
                text = "Controller & crons",
                color = Color.White,
                fontSize = 17.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.weight(1f),
                textAlign = TextAlign.Center
            )
            when (tab) {
                OrbAutomationTab.Controller -> {
                    if (controllerJob != null) {
                        Box(
                            modifier = Modifier
                                .size(38.dp)
                                .clip(CircleShape)
                                .background(OrbStyle.surface)
                                .border(1.dp, OrbStyle.border, CircleShape)
                                .orbPressClickable { editingController = true },
                            contentAlignment = Alignment.Center
                        ) {
                            Icon(
                                imageVector = Icons.Default.Tune,
                                contentDescription = "Controller settings",
                                tint = Color.White,
                                modifier = Modifier.size(17.dp)
                            )
                        }
                    } else {
                        Spacer(modifier = Modifier.width(38.dp))
                    }
                }
                OrbAutomationTab.Crons -> {
                    Box(
                        modifier = Modifier
                            .size(38.dp)
                            .clip(CircleShape)
                            .background(OrbStyle.surface)
                            .border(1.dp, OrbStyle.border, CircleShape)
                            .orbPressClickable { creatingCron = true },
                        contentAlignment = Alignment.Center
                    ) {
                        Icon(Icons.Default.Add, contentDescription = "New scheduled cron", tint = Color.White, modifier = Modifier.size(18.dp))
                    }
                }
                OrbAutomationTab.Grant -> Spacer(modifier = Modifier.width(38.dp))
            }
        }

        // Segmented tabs
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp, vertical = 4.dp)
                .clip(RoundedCornerShape(10.dp))
                .background(OrbStyle.surface)
                .border(1.dp, OrbStyle.border, RoundedCornerShape(10.dp))
                .padding(3.dp),
            horizontalArrangement = Arrangement.spacedBy(4.dp)
        ) {
            OrbAutomationTab.entries.forEach { option ->
                val selected = tab == option
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .clip(RoundedCornerShape(8.dp))
                        .background(if (selected) OrbStyle.card else Color.Transparent)
                        .orbPressClickable { tab = option }
                        .padding(vertical = 8.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        text = option.label,
                        color = if (selected) Color.White else OrbStyle.textMuted,
                        fontSize = 13.sp,
                        fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Medium
                    )
                }
            }
        }

        PullToRefreshBox(
            isRefreshing = isRefreshing,
            onRefresh = {
                scope.launch {
                    isRefreshing = true
                    try { loadAll() } finally { isRefreshing = false }
                }
            },
            modifier = Modifier.fillMaxSize()
        ) {
            LazyColumn(
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(horizontal = 20.dp, vertical = 12.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                error?.let { err ->
                    item { Text(err, color = OrbStyle.error, fontSize = 13.sp) }
                }

                when (tab) {
                    OrbAutomationTab.Controller -> {
                        if (controllerView == null) {
                            item {
                                Text("Loading controller…", color = OrbStyle.textMuted, fontSize = 13.sp)
                            }
                        } else if (controllerJob != null) {
                            val state = OrbControllerModel.cronState(controllerJob, running = controllerRunning)
                            item {
                                Column(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .clip(RoundedCornerShape(16.dp))
                                        .background(OrbStyle.surface)
                                        .border(1.dp, OrbStyle.border, RoundedCornerShape(16.dp))
                                        .padding(16.dp),
                                    verticalArrangement = Arrangement.spacedBy(8.dp)
                                ) {
                                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                        Box(
                                            modifier = Modifier
                                                .size(8.dp)
                                                .clip(CircleShape)
                                                .background(cronStateColor(state))
                                        )
                                        Text(
                                            text = OrbJSON.str(controllerJob, "name") ?: "Project controller",
                                            color = Color.White,
                                            fontSize = 15.sp,
                                            fontWeight = FontWeight.SemiBold,
                                            modifier = Modifier.weight(1f)
                                        )
                                        Text(
                                            text = state.label,
                                            color = cronStateColor(state),
                                            fontSize = 12.sp,
                                            fontWeight = FontWeight.SemiBold
                                        )
                                    }
                                    val sched = OrbControllerModel.scheduleExpression(controllerJob["schedule"])
                                    val next = OrbControllerModel.untilLabel(OrbJSON.str(controllerJob, "next_run_at"))
                                    val sub = listOfNotNull(
                                        sched.ifEmpty { "scheduled" },
                                        next.takeIf { it.isNotEmpty() }?.let { "next $it" }
                                    ).joinToString(" · ")
                                    Text(sub, color = OrbStyle.textMuted, fontSize = 12.sp)
                                    val streak = OrbJSON.int(controllerJob, "failure_streak") ?: 0
                                    if (streak > 0) {
                                        Text("$streak failed in a row", color = OrbStyle.warning, fontSize = 12.sp)
                                    }
                                    val archived = OrbJSON.bool(controllerJob, "archived") == true
                                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                                        if (state == OrbControllerModel.CronState.Paused) {
                                            TextButton(
                                                enabled = actionBusy == null && !archived,
                                                onClick = { scope.launch { runControllerAction("resume") } }
                                            ) { Text(if (actionBusy == "resume") "Resuming…" else "Resume") }
                                        } else {
                                            TextButton(
                                                enabled = actionBusy == null,
                                                onClick = { scope.launch { runControllerAction("pause") } }
                                            ) { Text(if (actionBusy == "pause") "Pausing…" else "Pause") }
                                        }
                                        TextButton(
                                            enabled = actionBusy == null && !controllerRunning && !archived,
                                            onClick = { scope.launch { runControllerAction("run") } }
                                        ) { Text(if (actionBusy == "run") "Starting…" else "Run now") }
                                        Spacer(modifier = Modifier.weight(1f))
                                        TextButton(onClick = { editingController = true }) { Text("Configure") }
                                    }
                                }
                            }
                        } else {
                            item {
                                Column(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .clip(RoundedCornerShape(16.dp))
                                        .background(OrbStyle.surface)
                                        .border(1.dp, OrbStyle.border, RoundedCornerShape(16.dp))
                                        .padding(16.dp),
                                    verticalArrangement = Arrangement.spacedBy(8.dp)
                                ) {
                                    Text("This project has no controller cron in Hermes.", color = OrbStyle.textMuted, fontSize = 13.sp)
                                    TextButton(onClick = { creatingCron = true }) {
                                        Text("New scheduled cron…")
                                    }
                                }
                            }
                        }

                        // Steer composer
                        item {
                            val pending = OrbJSON.dictList(steers?.get("pending"))
                            Column(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clip(RoundedCornerShape(16.dp))
                                    .background(OrbStyle.surface)
                                    .border(1.dp, OrbStyle.border, RoundedCornerShape(16.dp))
                                    .padding(16.dp),
                                verticalArrangement = Arrangement.spacedBy(10.dp)
                            ) {
                                Text("Steer", color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                                pending.forEach { st ->
                                    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                        Text(
                                            text = if (controllerRunning) "Awaiting pickup" else "Next tick",
                                            color = OrbStyle.warning,
                                            fontSize = 11.sp,
                                            fontWeight = FontWeight.SemiBold
                                        )
                                        Text(OrbJSON.str(st, "body").orEmpty(), color = OrbStyle.textPrimary, fontSize = 13.sp)
                                    }
                                }
                                OutlinedTextField(
                                    value = steerText,
                                    onValueChange = { steerText = it },
                                    placeholder = { Text("Steer the next tick…") },
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .semantics { contentDescription = "Steer the next tick" }
                                )
                                Row(
                                    modifier = Modifier.fillMaxWidth(),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.SpaceBetween
                                ) {
                                    Text("Run controller immediately", color = OrbStyle.textSecondary, fontSize = 13.sp)
                                    Switch(checked = steerRunNow, onCheckedChange = { steerRunNow = it })
                                }
                                TextButton(
                                    enabled = !steerSending && steerText.trim().isNotEmpty(),
                                    onClick = { scope.launch { sendSteer() } }
                                ) {
                                    Text(if (steerSending) "Sending…" else "Send steer")
                                }
                            }
                        }

                        // Timeline
                        if (controllerJob != null) {
                            val entries = OrbControllerModel.buildEntries(
                                runs = controllerRuns,
                                steers = OrbJSON.dictList(steers?.get("recent"))
                            )
                            item {
                                Text("Recent ticks", color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                            }
                            if (entries.isEmpty()) {
                                item {
                                    Text("No controller ticks recorded yet.", color = OrbStyle.textMuted, fontSize = 13.sp)
                                }
                            }
                            items(entries, key = { it.key }) { entry ->
                                when (entry) {
                                    is OrbControllerModel.TimelineEntry.Day -> {
                                        Text(entry.label, color = OrbStyle.textMuted, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                                    }
                                    is OrbControllerModel.TimelineEntry.Steer -> {
                                        Column(
                                            modifier = Modifier
                                                .fillMaxWidth()
                                                .clip(RoundedCornerShape(12.dp))
                                                .background(OrbStyle.surface)
                                                .border(1.dp, OrbStyle.border, RoundedCornerShape(12.dp))
                                                .padding(12.dp),
                                            verticalArrangement = Arrangement.spacedBy(4.dp)
                                        ) {
                                            Text("Steer consumed", color = OrbStyle.textMuted, fontSize = 11.sp, fontWeight = FontWeight.SemiBold)
                                            Text(OrbJSON.str(entry.steer, "body").orEmpty(), color = OrbStyle.textPrimary, fontSize = 13.sp)
                                        }
                                    }
                                    is OrbControllerModel.TimelineEntry.Silent -> {
                                        val expanded = expandedSilentKeys.contains(entry.key)
                                        Column(
                                            modifier = Modifier
                                                .fillMaxWidth()
                                                .clip(RoundedCornerShape(12.dp))
                                                .background(OrbStyle.surface)
                                                .border(1.dp, OrbStyle.border, RoundedCornerShape(12.dp))
                                                .orbPressClickable {
                                                    expandedSilentKeys = if (expanded) expandedSilentKeys - entry.key else expandedSilentKeys + entry.key
                                                }
                                                .padding(12.dp),
                                            verticalArrangement = Arrangement.spacedBy(6.dp)
                                        ) {
                                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                                Text(
                                                    text = "${entry.runs.size} silent tick${if (entry.runs.size == 1) "" else "s"}",
                                                    color = OrbStyle.textMuted,
                                                    fontSize = 13.sp,
                                                    modifier = Modifier.weight(1f)
                                                )
                                                Icon(
                                                    imageVector = if (expanded) Icons.Default.ExpandMore else Icons.Default.ChevronRight,
                                                    contentDescription = null,
                                                    tint = OrbStyle.textMuted,
                                                    modifier = Modifier.size(16.dp)
                                                )
                                            }
                                            if (expanded) {
                                                entry.runs.forEach { r ->
                                                    Text(
                                                        text = listOfNotNull(
                                                            shortTimeLabel(OrbJSON.str(r, "at")).takeIf { it.isNotEmpty() },
                                                            OrbControllerModel.durationLabel(OrbJSON.double(r, "duration_secs")).takeIf { it.isNotEmpty() },
                                                            OrbJSON.str(r, "ctrl") ?: "nothing new"
                                                        ).joinToString(" · "),
                                                        color = OrbStyle.textMuted,
                                                        fontSize = 12.sp,
                                                        fontFamily = FontFamily.Monospace
                                                    )
                                                }
                                            }
                                        }
                                    }
                                    is OrbControllerModel.TimelineEntry.Failed -> {
                                        Column(
                                            modifier = Modifier
                                                .fillMaxWidth()
                                                .clip(RoundedCornerShape(12.dp))
                                                .background(OrbStyle.surface)
                                                .border(1.dp, OrbStyle.border, RoundedCornerShape(12.dp))
                                                .padding(12.dp),
                                            verticalArrangement = Arrangement.spacedBy(4.dp)
                                        ) {
                                            Row(verticalAlignment = Alignment.CenterVertically) {
                                                Text(
                                                    text = if (entry.runs.size == 1) "Tick failed" else "${entry.runs.size} ticks failed",
                                                    color = OrbStyle.error,
                                                    fontSize = 13.sp,
                                                    fontWeight = FontWeight.SemiBold,
                                                    modifier = Modifier.weight(1f)
                                                )
                                                Text(
                                                    text = shortTimeLabel(OrbJSON.str(entry.runs.firstOrNull(), "at")),
                                                    color = OrbStyle.textMuted,
                                                    fontSize = 12.sp,
                                                    fontFamily = FontFamily.Monospace
                                                )
                                            }
                                            Text(entry.error, color = OrbStyle.error, fontSize = 12.sp)
                                        }
                                    }
                                    is OrbControllerModel.TimelineEntry.Run -> {
                                        val r = entry.run
                                        val st = OrbJSON.str(r, "status").orEmpty()
                                        Column(
                                            modifier = Modifier
                                                .fillMaxWidth()
                                                .clip(RoundedCornerShape(12.dp))
                                                .background(OrbStyle.surface)
                                                .border(1.dp, OrbStyle.border, RoundedCornerShape(12.dp))
                                                .padding(12.dp),
                                            verticalArrangement = Arrangement.spacedBy(6.dp)
                                        ) {
                                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                                Text(
                                                    text = shortTimeLabel(OrbJSON.str(r, "at")),
                                                    color = OrbStyle.textMuted,
                                                    fontSize = 12.sp,
                                                    fontFamily = FontFamily.Monospace
                                                )
                                                val dur = OrbControllerModel.durationLabel(OrbJSON.double(r, "duration_secs"))
                                                if (dur.isNotEmpty()) {
                                                    Text("· $dur", color = OrbStyle.textMuted, fontSize = 12.sp, fontFamily = FontFamily.Monospace)
                                                }
                                                if (st == "running" || st == "claimed") {
                                                    Text("Ticking…", color = OrbStyle.success, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                                                }
                                            }
                                            OrbJSON.str(r, "report")?.takeIf { it.isNotEmpty() }?.let { rep ->
                                                Text(rep, color = OrbStyle.textPrimary, fontSize = 13.sp, lineHeight = 19.sp)
                                            }
                                            OrbJSON.str(r, "error")?.takeIf { it.isNotEmpty() }?.let { errTxt ->
                                                Text(errTxt, color = OrbStyle.error, fontSize = 12.sp)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    OrbAutomationTab.Crons -> {
                        item {
                            Column(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clip(RoundedCornerShape(16.dp))
                                    .background(OrbStyle.surface)
                                    .border(1.dp, OrbStyle.border, RoundedCornerShape(16.dp))
                            ) {
                                if (crons.isEmpty()) {
                                    Text(
                                        "No additional scheduled crons bound to $projectName.",
                                        color = OrbStyle.textMuted,
                                        fontSize = 13.sp,
                                        modifier = Modifier.padding(16.dp)
                                    )
                                }
                                crons.forEachIndexed { idx, job ->
                                    val state = OrbControllerModel.cronState(job)
                                    val sched = OrbControllerModel.scheduleExpression(job["schedule"])
                                    val next = OrbControllerModel.untilLabel(OrbJSON.str(job, "next_run_at"))
                                    val subtitle = listOfNotNull(
                                        sched.ifEmpty { "scheduled" },
                                        if (state == OrbControllerModel.CronState.Paused) "paused" else next.takeIf { it.isNotEmpty() }?.let { "next $it" }
                                    ).joinToString(" · ")
                                    Row(
                                        modifier = Modifier
                                            .fillMaxWidth()
                                            .orbPressClickable { selectedCron = job }
                                            .padding(horizontal = 16.dp, vertical = 12.dp),
                                        verticalAlignment = Alignment.CenterVertically,
                                        horizontalArrangement = Arrangement.spacedBy(10.dp)
                                    ) {
                                        Box(
                                            modifier = Modifier
                                                .size(8.dp)
                                                .clip(CircleShape)
                                                .background(cronStateColor(state))
                                        )
                                        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                            Text(
                                                text = OrbJSON.str(job, "name") ?: OrbJSON.str(job, "id").orEmpty(),
                                                color = Color.White,
                                                fontSize = 15.sp,
                                                fontWeight = FontWeight.Medium,
                                                maxLines = 1,
                                                overflow = TextOverflow.Ellipsis
                                            )
                                            Text(subtitle, color = OrbStyle.textMuted, fontSize = 12.sp)
                                        }
                                        Icon(Icons.Default.ChevronRight, contentDescription = null, tint = OrbStyle.textMuted, modifier = Modifier.size(16.dp))
                                    }
                                    if (idx < crons.lastIndex) {
                                        HorizontalDivider(color = OrbStyle.border, modifier = Modifier.padding(start = 16.dp))
                                    }
                                }
                            }
                        }
                        item {
                            TextButton(onClick = { creatingCron = true }) {
                                Text("New scheduled cron…")
                            }
                        }
                    }

                    OrbAutomationTab.Grant -> {
                        item {
                            Column(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clip(RoundedCornerShape(16.dp))
                                    .background(OrbStyle.surface)
                                    .border(1.dp, OrbStyle.border, RoundedCornerShape(16.dp))
                                    .padding(16.dp),
                                verticalArrangement = Arrangement.spacedBy(10.dp)
                            ) {
                                Text("Project concurrency", color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                                Text(
                                    "Maximum unfinished missions in $projectName. Leave empty for no limit.",
                                    color = OrbStyle.textMuted,
                                    fontSize = 12.sp
                                )
                                OutlinedTextField(
                                    value = limitDraft,
                                    onValueChange = {
                                        limitDraft = it
                                        limitDirty = true
                                        limitSaved = false
                                    },
                                    singleLine = true,
                                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                                    placeholder = { Text("No limit") },
                                    label = { Text("Agent limit") },
                                    modifier = Modifier.fillMaxWidth()
                                )
                                TextButton(
                                    enabled = !limitSaving && limitDirty,
                                    onClick = { scope.launch { saveProjectLimit() } }
                                ) {
                                    Text(if (limitSaving) "Saving…" else "Save agent limit")
                                }
                                if (limitSaved) {
                                    Text("Saved.", color = OrbStyle.success, fontSize = 12.sp)
                                }
                            }
                        }

                        val readOnlyPairs = listOf(
                            "Autonomy level" to OrbJSON.str(grant, "autonomy_level").orEmpty(),
                            "Merge authority" to OrbJSON.str(grant, "merge_authority").orEmpty(),
                            "Budget per run" to OrbJSON.str(grant, "budget_per_tick").orEmpty(),
                            "Material bar" to OrbJSON.str(grant, "material_bar").orEmpty(),
                            "Pause reason" to OrbJSON.str(grant, "pause_reason").orEmpty(),
                            "Resume condition" to OrbJSON.str(grant, "resume_condition").orEmpty()
                        ).filter { it.second.isNotEmpty() }

                        if (readOnlyPairs.isNotEmpty()) {
                            item {
                                Column(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .clip(RoundedCornerShape(16.dp))
                                        .background(OrbStyle.surface)
                                        .border(1.dp, OrbStyle.border, RoundedCornerShape(16.dp))
                                        .padding(16.dp),
                                    verticalArrangement = Arrangement.spacedBy(8.dp)
                                ) {
                                    Text("Standing authority", color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                                    readOnlyPairs.forEach { (k, v) ->
                                        Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                                            Text(k, color = OrbStyle.textMuted, fontSize = 13.sp, modifier = Modifier.weight(0.45f))
                                            Text(v, color = Color.White, fontSize = 13.sp, modifier = Modifier.weight(0.55f))
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    if (editingController) {
        OrbCronEditorDialog(
            title = if (controllerJob == null) "Set up controller" else "Controller settings",
            slug = slug,
            existingView = controllerView,
            defaultDeliver = "project:$slug",
            allowDelete = controllerJob != null,
            onDismiss = { editingController = false },
            onSave = { patch ->
                val next = OrbJSON.dict(
                    core.request(
                        "/api/projects/${core.encodeComponent(slug)}/controller",
                        "PUT",
                        body = patch
                    )
                )
                if (next != null) controllerView = next
            },
            onDelete = {
                val next = OrbJSON.dict(
                    core.request(
                        "/api/projects/${core.encodeComponent(slug)}/controller",
                        "DELETE"
                    )
                )
                if (next != null) controllerView = next
            }
        )
    }

    if (creatingCron) {
        val defaultDeliver = OrbJSON.str(cronDefaults, "deliver") ?: "local"
        OrbCronEditorDialog(
            title = "New scheduled cron",
            slug = slug,
            existingView = null,
            defaultDeliver = defaultDeliver,
            allowDelete = false,
            onDismiss = { creatingCron = false },
            onSave = { patch ->
                val body = OrbControllerModel.hermesPatch(patch)
                core.request(
                    "/api/projects/${core.encodeComponent(slug)}/crons",
                    "POST",
                    body = body
                )
                loadCrons()
            },
            onDelete = null
        )
    }
}

@Composable
private fun OrbProjectCronDetailSubpage(
    core: OrbCore,
    slug: String,
    cronId: String,
    initialJob: OrbDict,
    onBack: () -> Unit,
    onChanged: () -> Unit
) {
    val scope = rememberCoroutineScope()
    var job by remember(cronId) { mutableStateOf(initialJob) }
    var runs by remember(cronId) { mutableStateOf<List<OrbDict>>(emptyList()) }
    var busy by remember { mutableStateOf<String?>(null) }
    var editing by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    suspend fun load() {
        try {
            val data = core.fetchDict("/api/projects/${core.encodeComponent(slug)}/crons/${core.encodeComponent(cronId)}")
            OrbJSON.dict(data["job"])?.let { job = it }
            runs = OrbJSON.dictList(data["runs"])
            error = null
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            error = e.message
        }
    }

    LaunchedEffect(cronId) {
        load()
    }

    val state = OrbControllerModel.cronState(job)

    Column(modifier = Modifier.fillMaxSize().background(OrbStyle.background)) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                modifier = Modifier
                    .size(38.dp)
                    .clip(CircleShape)
                    .background(OrbStyle.surface)
                    .border(1.dp, OrbStyle.border, CircleShape)
                    .orbPressClickable { onBack() },
                contentAlignment = Alignment.Center
            ) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back", tint = Color.White, modifier = Modifier.size(17.dp))
            }
            Text(
                text = OrbJSON.str(job, "name") ?: cronId,
                color = Color.White,
                fontSize = 17.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.weight(1f),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                textAlign = TextAlign.Center
            )
            TextButton(onClick = { editing = true }) {
                Text("Edit")
            }
        }

        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            error?.let { Text(it, color = OrbStyle.error, fontSize = 13.sp) }

            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(16.dp))
                    .background(OrbStyle.surface)
                    .border(1.dp, OrbStyle.border, RoundedCornerShape(16.dp))
                    .padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                val sched = OrbControllerModel.scheduleExpression(job["schedule"]).ifEmpty { "scheduled" }
                Text("Schedule: $sched", color = Color.White, fontSize = 14.sp)
                Text("State: ${state.label}", color = cronStateColor(state), fontSize = 13.sp)
                OrbJSON.str(job, "deliver")?.takeIf { it.isNotEmpty() }?.let { deliv ->
                    Text("Deliver to: $deliv", color = OrbStyle.textMuted, fontSize = 13.sp)
                }
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    val toggleAction = if (state == OrbControllerModel.CronState.Paused) "resume" else "pause"
                    TextButton(
                        enabled = busy == null,
                        onClick = {
                            busy = toggleAction
                            scope.launch {
                                try {
                                    core.request(
                                        "/api/projects/${core.encodeComponent(slug)}/crons/${core.encodeComponent(cronId)}/action",
                                        "POST",
                                        body = mapOf("action" to toggleAction)
                                    )
                                    load()
                                    onChanged()
                                } catch (e: Throwable) {
                                    error = e.message
                                } finally {
                                    busy = null
                                }
                            }
                        }
                    ) { Text(if (state == OrbControllerModel.CronState.Paused) "Resume" else "Pause") }

                    TextButton(
                        enabled = busy == null,
                        onClick = {
                            busy = "run"
                            scope.launch {
                                try {
                                    core.request(
                                        "/api/projects/${core.encodeComponent(slug)}/crons/${core.encodeComponent(cronId)}/action",
                                        "POST",
                                        body = mapOf("action" to "run")
                                    )
                                    load()
                                    onChanged()
                                } catch (e: Throwable) {
                                    error = e.message
                                } finally {
                                    busy = null
                                }
                            }
                        }
                    ) { Text("Run now") }
                }
            }

            OrbJSON.str(job, "prompt")?.takeIf { it.isNotEmpty() }?.let { prompt ->
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(16.dp))
                        .background(OrbStyle.surface)
                        .border(1.dp, OrbStyle.border, RoundedCornerShape(16.dp))
                        .padding(16.dp),
                    verticalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    Text("Instruction", color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                    Text(prompt, color = OrbStyle.textPrimary, fontSize = 12.sp, fontFamily = FontFamily.Monospace)
                }
            }

            Text("Recent runs", color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
            if (runs.isEmpty()) {
                Text("No runs recorded yet.", color = OrbStyle.textMuted, fontSize = 13.sp)
            }
            runs.forEach { r ->
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(12.dp))
                        .background(OrbStyle.surface)
                        .border(1.dp, OrbStyle.border, RoundedCornerShape(12.dp))
                        .padding(12.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    Text(
                        text = "${OrbJSON.str(r, "at").orEmpty()} · ${OrbJSON.str(r, "status") ?: "ok"}",
                        color = OrbStyle.textMuted,
                        fontSize = 12.sp,
                        fontFamily = FontFamily.Monospace
                    )
                    OrbJSON.str(r, "report")?.takeIf { it.isNotEmpty() }?.let { rep ->
                        Text(rep, color = OrbStyle.textPrimary, fontSize = 13.sp)
                    }
                    OrbJSON.str(r, "error")?.takeIf { it.isNotEmpty() }?.let { errTxt ->
                        Text(errTxt, color = OrbStyle.error, fontSize = 12.sp)
                    }
                }
            }
        }
    }

    if (editing) {
        OrbCronEditorDialog(
            title = "Edit cron",
            slug = slug,
            existingView = mapOf("job" to job, "settings" to job, "runs" to runs),
            defaultDeliver = OrbJSON.str(job, "deliver") ?: "local",
            allowDelete = true,
            onDismiss = { editing = false },
            onSave = { patch ->
                val body = OrbControllerModel.hermesPatch(patch, existingJob = job)
                val updated = OrbJSON.dict(
                    core.request(
                        "/api/projects/${core.encodeComponent(slug)}/crons/${core.encodeComponent(cronId)}",
                        "PATCH",
                        body = body
                    )
                )
                OrbJSON.dict(updated?.get("job"))?.let { job = it }
                val updatedRuns = OrbJSON.dictList(updated?.get("runs"))
                if (updatedRuns.isNotEmpty()) runs = updatedRuns
                onChanged()
            },
            onDelete = {
                core.request(
                    "/api/projects/${core.encodeComponent(slug)}/crons/${core.encodeComponent(cronId)}",
                    "DELETE"
                )
                onChanged()
                onBack()
            }
        )
    }
}

private val CRON_PRESETS = listOf("every 15m", "every 30m", "every 1h", "every 6h", "every 1d", "0 9 * * *")
private val REASONING_LEVELS = listOf("", "minimal", "low", "medium", "high", "xhigh")

@Composable
private fun OrbCronEditorDialog(
    title: String,
    slug: String,
    existingView: OrbDict?,
    defaultDeliver: String,
    allowDelete: Boolean,
    onDismiss: () -> Unit,
    onSave: suspend (Map<String, Any?>) -> Unit,
    onDelete: (suspend () -> Unit)?
) {
    val scope = rememberCoroutineScope()
    val existingJob = OrbJSON.dict(existingView?.get("job"))
    val existingSettings = OrbJSON.dict(existingView?.get("settings")) ?: existingJob

    var name by remember {
        mutableStateOf(OrbJSON.str(existingJob, "name") ?: "$slug controller")
    }
    var schedule by remember {
        val s = existingJob?.let { OrbControllerModel.scheduleExpression(it["schedule"]) }.orEmpty()
        mutableStateOf(s.ifEmpty { "every 30m" })
    }
    var prompt by remember {
        mutableStateOf(OrbJSON.rawStr(existingSettings, "prompt").orEmpty())
    }
    var deliver by remember {
        mutableStateOf(
            if (existingJob != null) {
                (OrbJSON.str(existingSettings, "deliver") ?: OrbJSON.str(existingJob, "deliver")).orEmpty()
            } else {
                defaultDeliver
            }
        )
    }
    var skillsText by remember {
        mutableStateOf(OrbControllerModel.skillsOf(existingSettings, existingJob).joinToString(", "))
    }
    var model by remember {
        mutableStateOf(OrbJSON.str(existingSettings, "model").orEmpty())
    }
    var reasoningEffort by remember {
        mutableStateOf(OrbJSON.str(existingSettings, "reasoning_effort").orEmpty())
    }
    var continuity by remember {
        mutableStateOf(
            if (existingJob != null) OrbControllerModel.continuityEnabled(existingSettings, existingJob) else false
        )
    }
    var reasoningMenu by remember { mutableStateOf(false) }
    var saving by remember { mutableStateOf(false) }
    var confirmDelete by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    AlertDialog(
        onDismissRequest = { if (!saving) onDismiss() },
        containerColor = OrbStyle.elevated,
        title = { Text(title, color = Color.White, fontWeight = FontWeight.SemiBold) },
        text = {
            Column(
                modifier = Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                error?.let { Text(it, color = OrbStyle.error, fontSize = 12.sp) }
                OutlinedTextField(
                    value = name,
                    onValueChange = { name = it; error = null },
                    enabled = !saving,
                    singleLine = true,
                    label = { Text("Name") },
                    modifier = Modifier.fillMaxWidth()
                )
                OutlinedTextField(
                    value = schedule,
                    onValueChange = { schedule = it; error = null },
                    enabled = !saving,
                    singleLine = true,
                    label = { Text("Schedule (e.g. every 30m or 0 9 * * *)") },
                    modifier = Modifier.fillMaxWidth()
                )
                Row(
                    modifier = Modifier.horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    CRON_PRESETS.forEach { preset ->
                        TextButton(enabled = !saving, onClick = { schedule = preset }) {
                            Text(preset, fontSize = 11.sp)
                        }
                    }
                }
                OutlinedTextField(
                    value = deliver,
                    onValueChange = { deliver = it },
                    enabled = !saving,
                    singleLine = true,
                    label = { Text("Deliver to (local or project:$slug)") },
                    modifier = Modifier.fillMaxWidth()
                )
                OutlinedTextField(
                    value = prompt,
                    onValueChange = { prompt = it; error = null },
                    enabled = !saving,
                    label = { Text("Instruction") },
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = 120.dp)
                )
                OutlinedTextField(
                    value = skillsText,
                    onValueChange = { skillsText = it },
                    enabled = !saving,
                    singleLine = true,
                    label = { Text("Skills (comma-separated)") },
                    modifier = Modifier.fillMaxWidth()
                )
                OutlinedTextField(
                    value = model,
                    onValueChange = { model = it },
                    enabled = !saving,
                    singleLine = true,
                    label = { Text("Model override (optional)") },
                    modifier = Modifier.fillMaxWidth()
                )
                Box {
                    TextButton(enabled = !saving, onClick = { reasoningMenu = true }) {
                        Text("Reasoning: ${reasoningEffort.ifEmpty { "Hermes default" }}")
                    }
                    DropdownMenu(
                        expanded = reasoningMenu,
                        onDismissRequest = { reasoningMenu = false },
                        containerColor = OrbStyle.elevated
                    ) {
                        REASONING_LEVELS.forEach { level ->
                            DropdownMenuItem(
                                text = { Text(level.ifEmpty { "Hermes default" }, color = Color.White) },
                                onClick = {
                                    reasoningEffort = level
                                    reasoningMenu = false
                                }
                            )
                        }
                    }
                }
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween
                ) {
                    Text("Keep context across runs", color = Color.White, fontSize = 13.sp)
                    Switch(checked = continuity, onCheckedChange = { continuity = it }, enabled = !saving)
                }
                if (allowDelete && onDelete != null) {
                    TextButton(enabled = !saving, onClick = { confirmDelete = true }) {
                        Text("Delete cron…", color = OrbStyle.error)
                    }
                }
            }
        },
        confirmButton = {
            TextButton(
                enabled = !saving,
                onClick = {
                    val trimmedName = name.trim()
                    val trimmedSchedule = schedule.trim()
                    val hasScript = !OrbJSON.str(existingSettings, "script").isNullOrEmpty()
                    val basePrompt = OrbJSON.rawStr(existingSettings, "prompt").orEmpty()
                    if (
                        trimmedName.isEmpty()
                        || trimmedSchedule.isEmpty()
                        || (prompt.trim().isEmpty() && (!hasScript || prompt != basePrompt))
                    ) {
                        error = "Name, schedule, and instruction are required."
                        return@TextButton
                    }
                    val skills = skillsText.split(",").map { it.trim() }.filter { it.isNotEmpty() }
                    val patch = OrbControllerModel.buildCronPatch(
                        existingView = existingView,
                        defaultDeliver = defaultDeliver,
                        name = trimmedName,
                        schedule = trimmedSchedule,
                        prompt = prompt,
                        skills = skills,
                        deliver = deliver,
                        model = model,
                        reasoningEffort = reasoningEffort,
                        continuity = continuity
                    )
                    if (existingJob != null && patch.isEmpty()) {
                        onDismiss()
                        return@TextButton
                    }
                    saving = true
                    error = null
                    scope.launch {
                        try {
                            onSave(patch)
                            onDismiss()
                        } catch (e: CancellationException) {
                            throw e
                        } catch (e: Throwable) {
                            error = e.message ?: "Could not save cron"
                        } finally {
                            saving = false
                        }
                    }
                }
            ) { Text(if (saving) "Saving…" else "Save") }
        },
        dismissButton = {
            TextButton(enabled = !saving, onClick = onDismiss) { Text("Cancel") }
        }
    )

    if (confirmDelete && onDelete != null) {
        AlertDialog(
            onDismissRequest = { if (!saving) confirmDelete = false },
            containerColor = OrbStyle.elevated,
            title = { Text("Delete this cron?", color = Color.White) },
            text = { Text("Removes the job from Hermes immediately.", color = OrbStyle.textSecondary) },
            confirmButton = {
                TextButton(
                    enabled = !saving,
                    onClick = {
                        saving = true
                        scope.launch {
                            try {
                                onDelete()
                                confirmDelete = false
                                onDismiss()
                            } catch (e: Throwable) {
                                error = e.message
                                confirmDelete = false
                            } finally {
                                saving = false
                            }
                        }
                    }
                ) { Text("Delete", color = OrbStyle.error) }
            },
            dismissButton = {
                TextButton(enabled = !saving, onClick = { confirmDelete = false }) { Text("Cancel") }
            }
        )
    }
}
