package sh.sandboxed.dashboard.orb

import android.content.Context
import android.content.SharedPreferences
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
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Reply
import androidx.compose.material.icons.filled.ArrowForward
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.CheckCircleOutline
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.time.Instant

object OrbMissionUnreadStore {
    private const val PREFS_KEY = "orb.missionSeenAt.v2"
    private var prefs: SharedPreferences? = null
    private val seenMap = mutableStateMapOf<String, String>()
    var revision by mutableIntStateOf(0)
        private set

    private val unreadResponseStates = setOf(
        "awaiting_user", "waiting_user", "completed", "succeeded",
        "failed", "blocked", "not_feasible", "paused", "interrupted"
    )

    fun init(context: Context) {
        if (prefs == null) {
            val p = context.applicationContext.getSharedPreferences(PREFS_KEY, Context.MODE_PRIVATE)
            prefs = p
            for ((k, v) in p.all) {
                if (v is String) {
                    seenMap[k] = v
                }
            }
        }
    }

    fun isUnread(mission: OrbRow, hasInteraction: Boolean = false): Boolean {
        val _rev = revision
        val state = (mission.str("status", "state") ?: "").lowercase()
        if (!hasInteraction && state !in unreadResponseStates) return false
        val updated = mission.str("updated_at", "completed_at", "started_at", "created_at") ?: ""
        val firstViewed = mission.str("first_viewed_at") ?: ""
        if (firstViewed.isNotEmpty()) {
            if (updated.isEmpty() || firstViewed >= updated) return false
        }
        val seen = seenMap[mission.id]
        if (seen != null) {
            if (updated.isEmpty() || seen >= updated) return false
        }
        return true
    }

    fun markSeen(mission: OrbRow) {
        val updated = mission.str("updated_at", "completed_at", "started_at", "created_at") ?: ""
        val nowIso = Instant.now().toString()
        val stamp = maxOf(updated, nowIso)
        if (seenMap[mission.id] != stamp) {
            seenMap[mission.id] = stamp
            revision += 1
            prefs?.edit()?.putString(mission.id, stamp)?.apply()
        }
    }

    fun markSeen(missionId: String, missions: List<OrbRow>) {
        val row = missions.firstOrNull { it.id == missionId } ?: return
        markSeen(row)
    }

    fun markAllSeen(missions: List<OrbRow>) {
        val editor = prefs?.edit()
        val nowIso = Instant.now().toString()
        var changed = false
        for (m in missions) {
            val updated = m.str("updated_at", "completed_at", "started_at", "created_at") ?: ""
            val stamp = maxOf(updated, nowIso)
            if (seenMap[m.id] != stamp) {
                seenMap[m.id] = stamp
                editor?.putString(m.id, stamp)
                changed = true
            }
        }
        if (changed) {
            revision += 1
            editor?.apply()
        }
    }
}

enum class OrbInboxKind {
    NeedsInput,
    Finished
}

enum class OrbInboxTone {
    Amber,
    Red,
    Blue,
    Green,
    Muted;

    val foreground: Color
        get() = when (this) {
            Amber -> OrbStyle.warning
            Red -> OrbStyle.error
            Blue -> OrbStyle.inboxBlue
            Green -> OrbStyle.success
            Muted -> OrbStyle.textSecondary
        }

    val background: Color
        get() = when (this) {
            Amber -> OrbStyle.warning.copy(alpha = 0.14f)
            Red -> OrbStyle.error.copy(alpha = 0.14f)
            Blue -> OrbStyle.inboxBlue.copy(alpha = 0.14f)
            Green -> OrbStyle.success.copy(alpha = 0.14f)
            Muted -> Color.White.copy(alpha = 0.06f)
        }
}

data class OrbInboxChildFailure(
    val id: String,
    val title: String,
    val row: OrbRow
)

data class OrbInboxItem(
    val id: String,
    val mission: OrbRow,
    val project: OrbRow,
    val kind: OrbInboxKind,
    val tone: OrbInboxTone,
    val badge: String,
    val headline: String,
    val summary: String,
    val commandPreview: String?,
    val quickOptions: List<String>,
    val updatedAt: String?,
    val isUnread: Boolean,
    val isAttention: Boolean,
    val canRetry: Boolean,
    val isGoal: Boolean,
    val childCount: Int,
    val completedChildCount: Int,
    val runningChildCount: Int,
    val failedChildCount: Int,
    val failedChildren: List<OrbInboxChildFailure>
)

object OrbInboxModel {
    private const val PREFS_KEY = "orb.inbox.dismissed"
    private var prefs: SharedPreferences? = null
    private val dismissedMap = mutableStateMapOf<String, String>()
    var revision by mutableIntStateOf(0)
        private set

    private val workingStatuses = setOf(
        "active", "running", "starting", "pending", "queued", "resuming", "waiting_background"
    )
    private val hiddenStatuses = setOf(
        "acknowledged", "archived", "deleted", "cancelled"
    )

    fun init(context: Context) {
        if (prefs == null) {
            val p = context.applicationContext.getSharedPreferences(PREFS_KEY, Context.MODE_PRIVATE)
            prefs = p
            for ((k, v) in p.all) {
                if (v is String) {
                    dismissedMap[k] = v
                }
            }
        }
    }

    fun dismiss(item: OrbInboxItem) {
        val sig = signature(item.mission)
        dismissedMap[item.id] = sig
        revision += 1
        prefs?.edit()?.putString(item.id, sig)?.apply()
        OrbMissionUnreadStore.markSeen(item.mission)
    }

    fun dismissAll(items: List<OrbInboxItem>) {
        val editor = prefs?.edit()
        for (item in items) {
            val sig = signature(item.mission)
            dismissedMap[item.id] = sig
            editor?.putString(item.id, sig)
        }
        revision += 1
        editor?.apply()
        OrbMissionUnreadStore.markAllSeen(items.map { it.mission })
    }

    fun restore(item: OrbInboxItem) {
        dismissedMap.remove(item.id)
        revision += 1
        prefs?.edit()?.remove(item.id)?.apply()
    }

    private fun isDismissed(mission: OrbRow): Boolean {
        val _rev = revision
        val seen = dismissedMap[mission.id] ?: return false
        return seen == signature(mission)
    }

    private fun signature(mission: OrbRow): String {
        val updated = mission.str("updated_at", "completed_at", "started_at", "created_at") ?: ""
        val status = (mission.str("status", "state") ?: "").lowercase()
        val reason = (mission.str("terminal_reason", "reason", "error") ?: "").lowercase()
        return "$status|$reason|$updated"
    }

    private fun isSubagent(mission: OrbRow): Boolean {
        if (!mission.str("parent_mission_id", "callback_parent_mission_id").isNullOrEmpty()) return true
        val tags = OrbJSON.strList(mission.raw, "tags")
        if (tags.any { it.startsWith("worker-dispatch:") || it == "superseded" || it.startsWith("superseded-by:") }) {
            return true
        }
        val title = (mission.str("title", "name") ?: "").trim()
        if (Regex("^you are a sub-?agent\\b", RegexOption.IGNORE_CASE).containsMatchIn(title)) {
            return true
        }
        return false
    }

    private fun isMobile(mission: OrbRow): Boolean {
        val tags = OrbJSON.strList(mission.raw, "tags")
        return tags.none { it.startsWith("btw-parent:") }
    }

    fun build(projects: List<OrbRow>, missions: List<OrbRow>): List<OrbInboxItem> {
        val _rev1 = revision
        val _rev2 = OrbMissionUnreadStore.revision

        val activeProjects = projects.filterNot { p ->
            val st = (p.str("status", "state") ?: "").lowercase()
            st == "archived" || st == "deleted" || p.bool("archived") == true
        }
        val projectsBySlug = mutableMapOf<String, OrbRow>()
        val defaultProj = activeProjects.firstOrNull { (it.str("slug", "id") ?: "").lowercase() == "default" }
            ?: OrbRow("default", mapOf("id" to "default", "slug" to "default", "title" to "Default"))
        projectsBySlug["default"] = defaultProj
        for (p in activeProjects) {
            val s = (p.str("slug", "id") ?: p.id).trim().lowercase()
            if (s.isNotEmpty()) projectsBySlug[s] = p
        }

        val mobileMissions = missions.filter { isMobile(it) }

        val childrenByParent = mutableMapOf<String, MutableList<OrbRow>>()
        val seenChildren = mutableSetOf<String>()
        for (child in mobileMissions) {
            if (!seenChildren.add(child.id)) continue
            val parentId = child.str("parent_mission_id", "callback_parent_mission_id") ?: ""
            val state = (child.str("status", "state") ?: "").lowercase()
            if (parentId.isNotEmpty() && state !in hiddenStatuses) {
                childrenByParent.getOrPut(parentId) { mutableListOf() }.add(child)
            }
        }

        val items = mutableListOf<OrbInboxItem>()
        val seen = mutableSetOf<String>()

        for (mission in mobileMissions) {
            if (!seen.add(mission.id)) continue
            val state = (mission.str("status", "state") ?: "").lowercase()
            if (state in hiddenStatuses || OrbMissionTree.isArchived(mission)) continue
            if (isDismissed(mission)) continue
            if (isSubagent(mission)) continue
            if (state in workingStatuses) continue

            val rawSlug = (mission.str("project", "project_slug") ?: "").trim().lowercase()
            val tags = OrbJSON.strList(mission.raw, "tags")
            val isClient = tags.contains("placement:client")
            if (activeProjects.isNotEmpty()) {
                if (rawSlug.isEmpty() && !isClient) continue
                val slug = if (rawSlug.isEmpty()) "default" else rawSlug
                if (!projectsBySlug.containsKey(slug)) continue
            }

            val classified = classify(mission) ?: continue
            val resolvedSlug = if (rawSlug.isEmpty()) "default" else rawSlug
            val project = projectsBySlug[resolvedSlug] ?: resolveProject(mission, activeProjects)

            val children = childrenByParent[mission.id] ?: emptyList()
            var completedKids = 0
            var runningKids = 0
            var failedKids = 0
            val failedList = mutableListOf<OrbInboxChildFailure>()
            var hasUnreadFailure = false

            for (child in children) {
                val cst = (child.str("status", "state") ?: "").lowercase()
                when {
                    cst in setOf("completed", "succeeded") -> completedKids += 1
                    cst in workingStatuses -> runningKids += 1
                    cst in setOf("failed", "not_feasible", "blocked") -> {
                        failedKids += 1
                        val cTitle = missionHeadline(child)
                        failedList.add(
                            OrbInboxChildFailure(
                                id = child.id,
                                title = cTitle.ifEmpty { "Worker track" },
                                row = child
                            )
                        )
                        if (OrbMissionUnreadStore.isUnread(child)) {
                            hasUnreadFailure = true
                        }
                    }
                }
            }

            val unread = OrbMissionUnreadStore.isUnread(mission) || hasUnreadFailure
            val attention = classified.quickOptions.isNotEmpty() ||
                state in setOf("blocked", "failed", "not_feasible") ||
                hasUnreadFailure
            val canRetry = state in setOf("failed", "not_feasible", "interrupted", "blocked")

            items.add(
                OrbInboxItem(
                    id = mission.id,
                    mission = mission,
                    project = project,
                    kind = classified.kind,
                    tone = classified.tone,
                    badge = classified.badge,
                    headline = missionHeadline(mission),
                    summary = classified.summary,
                    commandPreview = classified.commandPreview,
                    quickOptions = classified.quickOptions,
                    updatedAt = mission.str("updated_at", "completed_at", "started_at", "created_at"),
                    isUnread = unread,
                    isAttention = attention,
                    canRetry = canRetry,
                    isGoal = OrbMissionTree.isGoal(mission) || mission.bool("goal_mode") == true ||
                        (mission.str("title", "name") ?: "").trim().startsWith("/goal"),
                    childCount = children.size,
                    completedChildCount = completedKids,
                    runningChildCount = runningKids,
                    failedChildCount = failedKids,
                    failedChildren = failedList
                )
            )
        }

        return items.sortedWith { a, b ->
            if (a.kind != b.kind) {
                return@sortedWith if (a.kind == OrbInboxKind.NeedsInput) -1 else 1
            }
            if (a.kind == OrbInboxKind.NeedsInput) {
                val ua = urgencyRank(a)
                val ub = urgencyRank(b)
                if (ua != ub) return@sortedWith ua.compareTo(ub)
            }
            val ua = a.updatedAt ?: ""
            val ub = b.updatedAt ?: ""
            ub.compareTo(ua)
        }
    }

    fun workingMissions(projects: List<OrbRow>, missions: List<OrbRow>): List<OrbRow> {
        val activeProjects = projects.filterNot { p ->
            val st = (p.str("status", "state") ?: "").lowercase()
            st == "archived" || st == "deleted" || p.bool("archived") == true
        }
        val validSlugs = mutableSetOf("default")
        for (p in activeProjects) {
            val s = (p.str("slug", "id") ?: p.id).trim().lowercase()
            if (s.isNotEmpty()) validSlugs.add(s)
        }
        val seen = mutableSetOf<String>()
        return missions.filter { m ->
            if (!seen.add(m.id)) return@filter false
            if (!isMobile(m)) return@filter false
            val st = (m.str("status", "state") ?: "").lowercase()
            if (st !in workingStatuses || isSubagent(m) || OrbMissionTree.isArchived(m)) return@filter false
            val rawSlug = (m.str("project", "project_slug") ?: "").trim().lowercase()
            val tags = OrbJSON.strList(m.raw, "tags")
            val isClient = tags.contains("placement:client")
            if (activeProjects.isNotEmpty()) {
                if (rawSlug.isEmpty() && !isClient) return@filter false
                val slug = if (rawSlug.isEmpty()) "default" else rawSlug
                if (slug !in validSlugs) return@filter false
            }
            true
        }
    }

    fun actionableCount(projects: List<OrbRow>, missions: List<OrbRow>): Int {
        val all = build(projects, missions)
        return all.count { it.isUnread }
    }

    private fun urgencyRank(item: OrbInboxItem): Int {
        if (item.quickOptions.isNotEmpty()) return 0
        return when ((item.mission.str("status", "state") ?: "").lowercase()) {
            "blocked" -> 1
            "awaiting_user", "waiting_user" -> 2
            "failed", "not_feasible" -> 3
            else -> 4
        }
    }

    private data class Classification(
        val kind: OrbInboxKind,
        val tone: OrbInboxTone,
        val badge: String,
        val summary: String,
        val commandPreview: String?,
        val quickOptions: List<String>
    )

    private fun classify(mission: OrbRow): Classification? {
        val status = (mission.str("status", "state") ?: "").lowercase()
        val summaryText = extractSummary(mission)
        val cachedEvents = OrbReadCache.loadRows("mission_events_${mission.id}")
        val cachedMessages = OrbReadCache.loadRows("mission_msgs_${mission.id}")

        val q = OrbQuestionExtractor.extract(cachedEvents, cachedMessages, status)
        if (q != null && status !in setOf("completed", "succeeded", "failed", "not_feasible")) {
            val badge = when (q.kind) {
                OrbQuestion.Kind.Permission -> "Approval"
                OrbQuestion.Kind.Plan -> "Plan review"
                OrbQuestion.Kind.Question -> "Question"
            }
            return Classification(
                kind = OrbInboxKind.NeedsInput,
                tone = OrbInboxTone.Amber,
                badge = badge,
                summary = clipToSentence(q.prompt),
                commandPreview = null,
                quickOptions = q.options.take(3)
            )
        }

        return when (status) {
            "blocked" -> Classification(
                kind = OrbInboxKind.NeedsInput,
                tone = OrbInboxTone.Amber,
                badge = "Blocked",
                summary = summaryText,
                commandPreview = null,
                quickOptions = emptyList()
            )
            "failed" -> Classification(
                kind = OrbInboxKind.NeedsInput,
                tone = OrbInboxTone.Red,
                badge = "Failed",
                summary = summaryText,
                commandPreview = null,
                quickOptions = emptyList()
            )
            "not_feasible" -> Classification(
                kind = OrbInboxKind.NeedsInput,
                tone = OrbInboxTone.Red,
                badge = "Not feasible",
                summary = summaryText,
                commandPreview = null,
                quickOptions = emptyList()
            )
            "awaiting_user", "waiting_user" -> Classification(
                kind = OrbInboxKind.NeedsInput,
                tone = OrbInboxTone.Blue,
                badge = if (summaryText.trim().endsWith("?")) "Question" else "Waiting",
                summary = summaryText,
                commandPreview = null,
                quickOptions = emptyList()
            )
            "completed", "succeeded" -> Classification(
                kind = OrbInboxKind.Finished,
                tone = OrbInboxTone.Green,
                badge = "Completed",
                summary = summaryText,
                commandPreview = null,
                quickOptions = emptyList()
            )
            "paused", "interrupted" -> Classification(
                kind = OrbInboxKind.Finished,
                tone = OrbInboxTone.Muted,
                badge = "Paused",
                summary = summaryText,
                commandPreview = null,
                quickOptions = emptyList()
            )
            else -> null
        }
    }

    fun missionHeadline(mission: OrbRow): String {
        val rawTitle = displayTitle(mission.str("title", "name") ?: "")
        if (rawTitle.isNotEmpty()) return rawTitle
        val history = OrbJSON.dictList(mission.raw["history"])
        val firstUser = history.firstOrNull { OrbJSON.str(it, "role") == "user" }
            ?.let { OrbJSON.str(it, "content") } ?: ""
        if (firstUser.isNotEmpty()) return clipToSentence(firstUser, 54)
        return "Untitled conversation"
    }

    private fun displayTitle(raw: String): String {
        val trimmed = raw.trim()
        if (trimmed.startsWith("/goal")) {
            val rest = trimmed.drop(5).trim()
            if (rest.isNotEmpty()) return rest.lineSequence().first().trim()
        }
        if (trimmed.startsWith("/plan")) {
            val rest = trimmed.drop(5).trim()
            if (rest.isNotEmpty()) return rest.lineSequence().first().trim()
        }
        return trimmed.lineSequence().firstOrNull()?.trim() ?: ""
    }

    private fun extractSummary(mission: OrbRow): String {
        val cachedEvents = OrbReadCache.loadRows("mission_events_${mission.id}")
        for (ev in cachedEvents.asReversed()) {
            val evType = (ev.str("event_type", "type") ?: "").lowercase()
            if (evType == "error") {
                val clean = humanizeStatusText(ev.str("content", "message", "error") ?: "")
                if (clean.isNotEmpty()) return clipToSentence(clean)
            }
            if (evType == "assistant_message" || evType == "assistant_message_canonical") {
                val clean = humanizeStatusText(ev.str("content", "text", "message") ?: "")
                if (clean.isNotEmpty()) return clipToSentence(clean)
            }
        }
        val history = OrbJSON.dictList(mission.raw["history"])
        for (entry in history.asReversed()) {
            if (OrbJSON.str(entry, "role") == "assistant") {
                val clean = humanizeStatusText(OrbJSON.str(entry, "content") ?: "")
                if (clean.isNotEmpty()) return clipToSentence(clean)
            }
        }
        val remoteJob = mission.dict("remote_job")
        val remoteErr = humanizeStatusText(OrbJSON.str(remoteJob, "error") ?: "")
        if (remoteErr.isNotEmpty()) return clipToSentence(remoteErr)

        val statusMsg = humanizeStatusText(mission.str("status_message", "last_assistant_message", "summary") ?: "")
        if (statusMsg.isNotEmpty()) return clipToSentence(statusMsg)

        val termReason = humanizeStatusText(mission.str("terminal_reason") ?: "")
        if (termReason.isNotEmpty()) return clipToSentence(termReason)

        return when ((mission.str("status", "state") ?: "").lowercase()) {
            "completed", "succeeded" -> "Finished the task and is ready for your review."
            "awaiting_user", "waiting_user" -> "Finished the turn and is waiting for your follow-up."
            "blocked" -> "Blocked and needs your input to continue."
            "failed", "not_feasible" -> "Stopped with an error — open to inspect or resume."
            else -> "Ready for your review."
        }
    }

    fun humanizeStatusText(raw: String): String {
        var trimmed = raw.trim()
        if (trimmed.isEmpty()) return ""
        if (Regex("^[a-z0-9_]+$").matches(trimmed)) return ""
        trimmed = trimmed.replace(Regex("(?i);\\s*error:\\s*command exited with (?:Some\\()?(-?\\d+)\\)?"), "")
        trimmed = trimmed.replace(Regex("\\(exit Some\\((-?\\d+)\\)\\)"), "(exit $1)")
        trimmed = trimmed.replace(Regex("\\bSome\\((-?\\d+)\\)"), "$1")
        trimmed = trimmed.replace(Regex("(?i)finished with state 'failed'\\s*"), "failed ")
        trimmed = trimmed.replace(Regex("(?i)^Remote\\s+(\\S+)\\s+job\\s+[0-9a-f-]{36}\\s+on\\s+node\\s+'([^']+)'\\s+"), "Remote $1 run on $2 ")
        trimmed = trimmed.replace(Regex("(?i)^Job\\s+[0-9a-f-]{36}\\s+on\\s+node\\s+'([^']+)'\\s+"), "Remote run on $1 ")
        return trimmed
    }

    fun cleanMarkdownPreview(raw: String): String = clipToSentence(raw)

    private fun stripMarkdownToProse(raw: String): String {
        if (raw.isEmpty()) return ""
        var s = raw
        s = s.replace(Regex("```[\\s\\S]*?```"), " ")
        s = s.replace(Regex("(?m)^\\s{0,3}#{1,6}\\s+[^\\n]*$"), " ")
        s = s.replace(Regex("(?m)^\\s{0,3}>\\s*"), "")
        s = s.replace(Regex("(?m)^\\s*(?:[-*+]|\\d+\\.)\\s+"), "")
        s = s.replace(Regex("\\[([^\\]]+)\\]\\([^)]+\\)"), "$1")
        s = s.replace(Regex("`([^`]+)`"), "$1")
        s = s.replace(Regex("\\*\\*(.*?)\\*\\*"), "$1")
        s = s.replace(Regex("\\s+"), " ")
        return s.trim()
    }

    fun clipToSentence(raw: String, maxChars: Int = 112): String {
        val prose = stripMarkdownToProse(raw)
        if (prose.isEmpty()) return ""
        var cutIdx = -1
        for (i in prose.indices) {
            val ch = prose[i]
            if (ch == '.' || ch == '?' || ch == '!') {
                val nextIdx = i + 1
                val isEnd = nextIdx == prose.length || prose[nextIdx].isWhitespace()
                if (isEnd && nextIdx >= 12) {
                    cutIdx = nextIdx
                    break
                }
            }
        }
        val candidate = if (cutIdx > 0) prose.substring(0, cutIdx).trim() else prose
        if (candidate.length <= maxChars) return candidate
        val prefix = candidate.take(maxOf(1, maxChars - 1))
        val lastSpace = prefix.lastIndexOf(' ')
        if (lastSpace >= maxChars / 2) {
            return prefix.substring(0, lastSpace).trim() + "…"
        }
        return prefix.trim() + "…"
    }

    fun resolveProject(mission: OrbRow, projects: List<OrbRow>): OrbRow {
        val pName = (mission.str("project", "project_slug", "project_id", "project_name") ?: "").lowercase()
        val mSession = mission.str("origin_session_id", "session_id", "bound_session_id")
        val tags = OrbJSON.strList(mission.raw, "tags").map { it.lowercase() }

        for (project in projects) {
            val slug = (project.str("slug", "id") ?: "").lowercase()
            val name = (project.str("title", "name") ?: "").lowercase()
            val bound = project.str("bound_session_id", "conversation_id", "session_id")
            if (slug.isNotEmpty() && (pName == slug || tags.contains("project:$slug") || tags.contains(slug))) {
                return project
            }
            if (name.isNotEmpty() && pName == name) {
                return project
            }
            if (!bound.isNullOrEmpty() && mSession == bound) {
                return project
            }
        }
        val workspaceId = mission.str("workspace_id", "workspaceId")
        val fallbackSlug = if (pName.isEmpty()) "default" else pName
        val fallbackName = if (pName.isEmpty() || pName == "default") {
            "Default"
        } else {
            pName.replace("-", " ").replace("_", " ").split(" ")
                .joinToString(" ") { it.replaceFirstChar { c -> c.uppercase() } }
        }
        return OrbRow(
            fallbackSlug,
            mapOf(
                "id" to fallbackSlug,
                "slug" to fallbackSlug,
                "title" to fallbackName,
                "name" to fallbackName,
                "workspace_id" to (workspaceId ?: "")
            )
        )
    }
}

enum class OrbInboxFilterMode(val title: String) {
    Unread("Unread"),
    Attention("Attention"),
    All("All")
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun OrbInboxView(
    core: OrbCore,
    onSelectMission: (mission: OrbRow, project: OrbRow) -> Unit,
    onSelectProject: (OrbRow) -> Unit,
    modifier: Modifier = Modifier
) {
    val projects by core.projects.collectAsState()
    val missions by core.missions.collectAsState()
    val scope = rememberCoroutineScope()

    var filterMode by remember { mutableStateOf(OrbInboxFilterMode.Unread) }
    var selectedProjectSlug by remember { mutableStateOf<String?>(null) }
    var replyingItemId by remember { mutableStateOf<String?>(null) }
    var replyDraft by remember { mutableStateOf("") }
    var sendingItemId by remember { mutableStateOf<String?>(null) }
    var showRunningSection by remember { mutableStateOf(false) }
    var lastDismissedItem by remember { mutableStateOf<OrbInboxItem?>(null) }
    var peekedItemId by remember { mutableStateOf<String?>(null) }
    val peekMessagesByItem = remember { mutableStateMapOf<String, List<OrbRow>>() }
    var loadingPeekId by remember { mutableStateOf<String?>(null) }
    var isRefreshing by remember { mutableStateOf(false) }

    var eventsVersion by remember { mutableIntStateOf(0) }
    androidx.compose.runtime.LaunchedEffect(missions) {
        val candidates = missions.filter { m ->
            val st = (m.str("status", "state") ?: "").lowercase()
            st in setOf("active", "running", "starting", "awaiting_user", "waiting_user", "blocked")
        }.take(8)
        var anyLoaded = false
        for (row in candidates) {
            if (OrbReadCache.loadRows("mission_events_${row.id}").isNotEmpty()) continue
            val evs = runCatching {
                core.fetchRows("/api/control/missions/${row.id}/events?limit=120", "events")
            }.getOrDefault(emptyList())
            if (evs.isNotEmpty()) {
                OrbReadCache.saveRows("mission_events_${row.id}", evs)
                anyLoaded = true
            }
        }
        if (anyLoaded) {
            eventsVersion += 1
        }
    }

    val allItems = remember(projects, missions, OrbInboxModel.revision, OrbMissionUnreadStore.revision, eventsVersion) {
        OrbInboxModel.build(projects, missions)
    }

    val workingMissions = remember(projects, missions) {
        OrbInboxModel.workingMissions(projects, missions)
    }

    val unreadCount = remember(allItems) { allItems.count { it.isUnread } }
    val attentionCount = remember(allItems) { allItems.count { it.isAttention } }
    val totalActionableCount = allItems.size

    val modeFilteredItems = remember(allItems, filterMode) {
        when (filterMode) {
            OrbInboxFilterMode.Unread -> allItems.filter { it.isUnread }
            OrbInboxFilterMode.Attention -> allItems.filter { it.isAttention }
            OrbInboxFilterMode.All -> allItems
        }
    }

    val visibleItems = remember(modeFilteredItems, selectedProjectSlug) {
        val slug = selectedProjectSlug ?: return@remember modeFilteredItems
        modeFilteredItems.filter { OrbProjectAppearance.slug(it.project) == slug }
    }

    val needsInputItems = remember(visibleItems) { visibleItems.filter { it.kind == OrbInboxKind.NeedsInput } }
    val finishedItems = remember(visibleItems) { visibleItems.filter { it.kind == OrbInboxKind.Finished } }

    data class ProjectFilterEntry(val slug: String, val name: String, val project: OrbRow, val count: Int)
    val projectFilterChips = remember(modeFilteredItems) {
        val counts = mutableMapOf<String, Int>()
        val rowsBySlug = mutableMapOf<String, OrbRow>()
        for (item in modeFilteredItems) {
            val slug = OrbProjectAppearance.slug(item.project)
            counts[slug] = (counts[slug] ?: 0) + 1
            rowsBySlug[slug] = item.project
        }
        counts.mapNotNull { (slug, count) ->
            val p = rowsBySlug[slug] ?: return@mapNotNull null
            val name = p.str("title", "name", "slug") ?: "Project"
            ProjectFilterEntry(slug, name, p, count)
        }.sortedWith { a, b ->
            if (a.count != b.count) b.count.compareTo(a.count)
            else a.name.compareTo(b.name, ignoreCase = true)
        }
    }

    fun markItemAndChildrenRead(item: OrbInboxItem) {
        OrbMissionUnreadStore.markSeen(item.mission)
        item.failedChildren.forEach { OrbMissionUnreadStore.markSeen(it.row) }
    }

    fun togglePeek(item: OrbInboxItem) {
        if (peekedItemId == item.id) {
            peekedItemId = null
            return
        }
        peekedItemId = item.id
        val cached = OrbReadCache.loadRows("mission_msgs_${item.id}")
        if (cached.isNotEmpty()) {
            peekMessagesByItem[item.id] = cached.takeLast(3)
        }
        loadingPeekId = item.id
        scope.launch {
            val rows = runCatching {
                core.fetchRows("/api/control/missions/${item.id}/messages", "messages")
            }.getOrDefault(emptyList())
            if (rows.isNotEmpty()) {
                OrbReadCache.saveRows("mission_msgs_${item.id}", rows)
                peekMessagesByItem[item.id] = rows.takeLast(3)
            }
            if (loadingPeekId == item.id) {
                loadingPeekId = null
            }
        }
    }

    fun dismissWithUndo(item: OrbInboxItem) {
        markItemAndChildrenRead(item)
        OrbInboxModel.dismiss(item)
        lastDismissedItem = item
        val dismissedId = item.id
        scope.launch {
            delay(4500L)
            if (lastDismissedItem?.id == dismissedId) {
                lastDismissedItem = null
            }
        }
    }

    fun sendQuickReply(text: String, item: OrbInboxItem) {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return
        sendingItemId = item.id
        scope.launch {
            try {
                core.request(
                    path = "/api/control/missions/${item.id}/message",
                    method = "POST",
                    body = mapOf("content" to trimmed)
                )
                markItemAndChildrenRead(item)
                replyingItemId = null
                replyDraft = ""
                core.refreshMissionsQuietly()
            } catch (e: Throwable) {
                core.setError(e.message)
            } finally {
                sendingItemId = null
            }
        }
    }

    Box(modifier = modifier.fillMaxSize()) {
        PullToRefreshBox(
            isRefreshing = isRefreshing,
            onRefresh = {
                scope.launch {
                    isRefreshing = true
                    core.refreshAll()
                    isRefreshing = false
                }
            },
            modifier = Modifier.fillMaxSize()
        ) {
            LazyColumn(
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(
                    start = 16.dp,
                    end = 16.dp,
                    top = 8.dp,
                    bottom = if (lastDismissedItem != null) 76.dp else 28.dp
                ),
                verticalArrangement = Arrangement.spacedBy(14.dp)
            ) {
                item(key = "header") {
                    Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                        // headerSummary matching iOS line 1059
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(10.dp)
                        ) {
                            Text(
                                text = "New agent responses and questions waiting on you.",
                                color = OrbStyle.textSecondary,
                                fontSize = 13.sp,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                                modifier = Modifier.weight(1f)
                            )

                            if (workingMissions.isNotEmpty()) {
                                Row(
                                    modifier = Modifier
                                        .clip(CircleShape)
                                        .background(if (showRunningSection) OrbStyle.elevated else OrbStyle.surface)
                                        .border(
                                            1.dp,
                                            if (showRunningSection) OrbStyle.borderStrong else OrbStyle.border,
                                            CircleShape
                                        )
                                        .orbPressClickable { showRunningSection = !showRunningSection }
                                        .padding(horizontal = 10.dp, vertical = 5.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(6.dp)
                                ) {
                                    OrbRunningDots(color = Color.White, dotSize = 2.1.dp, spacing = 1.9.dp)
                                    Text(
                                        text = "${workingMissions.size} working",
                                        color = Color.White,
                                        fontSize = 12.sp,
                                        fontWeight = FontWeight.Medium,
                                        fontFamily = FontFamily.Monospace
                                    )
                                }
                            }
                        }

                        // modeFilterBar matching iOS line 988
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            Row(
                                modifier = Modifier
                                    .clip(CircleShape)
                                    .background(OrbStyle.surface)
                                    .border(1.dp, OrbStyle.border, CircleShape)
                                    .padding(3.dp),
                                horizontalArrangement = Arrangement.spacedBy(4.dp)
                            ) {
                                OrbInboxFilterMode.entries.forEach { mode ->
                                    val active = filterMode == mode
                                    val count = when (mode) {
                                        OrbInboxFilterMode.Unread -> unreadCount
                                        OrbInboxFilterMode.Attention -> attentionCount
                                        OrbInboxFilterMode.All -> totalActionableCount
                                    }
                                    Row(
                                        modifier = Modifier
                                            .clip(CircleShape)
                                            .background(if (active) OrbStyle.elevated else Color.Transparent)
                                            .orbPressClickable { filterMode = mode }
                                            .padding(horizontal = 10.dp, vertical = 6.dp),
                                        verticalAlignment = Alignment.CenterVertically,
                                        horizontalArrangement = Arrangement.spacedBy(5.dp)
                                    ) {
                                        if (mode == OrbInboxFilterMode.Unread) {
                                            Box(
                                                modifier = Modifier
                                                    .size(6.dp)
                                                    .clip(CircleShape)
                                                    .background(Color(0xFF0A84FF))
                                            )
                                        }
                                        Text(
                                            text = mode.title,
                                            color = if (active) Color.White else OrbStyle.textSecondary,
                                            fontSize = 12.sp,
                                            fontWeight = FontWeight.Medium
                                        )
                                        Text(
                                            text = "$count",
                                            color = OrbStyle.textMuted,
                                            fontSize = 11.sp,
                                            fontFamily = FontFamily.Monospace
                                        )
                                    }
                                }
                            }

                            Spacer(modifier = Modifier.weight(1f))

                            if (unreadCount > 0) {
                                Row(
                                    modifier = Modifier
                                        .clip(CircleShape)
                                        .background(OrbStyle.surface)
                                        .border(1.dp, OrbStyle.border, CircleShape)
                                        .orbPressClickable {
                                            allItems.filter { it.isUnread }.forEach { markItemAndChildrenRead(it) }
                                        }
                                        .padding(horizontal = 10.dp, vertical = 6.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(4.dp)
                                ) {
                                    Icon(
                                        imageVector = Icons.Default.Check,
                                        contentDescription = null,
                                        tint = OrbStyle.textSecondary,
                                        modifier = Modifier.size(11.dp)
                                    )
                                    Text(
                                        text = "Read all",
                                        color = OrbStyle.textSecondary,
                                        fontSize = 12.sp,
                                        fontWeight = FontWeight.Medium
                                    )
                                }
                            }
                        }

                        // Project filter chips
                        if (projectFilterChips.size > 1) {
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .horizontalScroll(rememberScrollState()),
                                horizontalArrangement = Arrangement.spacedBy(6.dp)
                            ) {
                                Row(
                                    modifier = Modifier
                                        .clip(CircleShape)
                                        .background(if (selectedProjectSlug == null) OrbStyle.elevated else OrbStyle.surface)
                                        .border(
                                            1.dp,
                                            if (selectedProjectSlug == null) OrbStyle.borderStrong else OrbStyle.border,
                                            CircleShape
                                        )
                                        .orbPressClickable { selectedProjectSlug = null }
                                        .padding(horizontal = 11.dp, vertical = 6.dp),
                                    verticalAlignment = Alignment.CenterVertically
                                ) {
                                    Text(
                                        text = "All projects",
                                        color = if (selectedProjectSlug == null) Color.White else OrbStyle.textSecondary,
                                        fontSize = 12.sp,
                                        fontWeight = FontWeight.Medium
                                    )
                                }

                                projectFilterChips.forEach { chip ->
                                    val selected = selectedProjectSlug == chip.slug
                                    Row(
                                        modifier = Modifier
                                            .clip(CircleShape)
                                            .background(if (selected) OrbStyle.elevated else OrbStyle.surface)
                                            .border(
                                                1.dp,
                                                if (selected) OrbStyle.borderStrong else OrbStyle.border,
                                                CircleShape
                                            )
                                            .orbPressClickable {
                                                selectedProjectSlug = if (selected) null else chip.slug
                                            }
                                            .padding(horizontal = 10.dp, vertical = 6.dp),
                                        verticalAlignment = Alignment.CenterVertically,
                                        horizontalArrangement = Arrangement.spacedBy(6.dp)
                                    ) {
                                        Box(
                                            modifier = Modifier
                                                .size(6.dp)
                                                .clip(CircleShape)
                                                .background(OrbProjectAppearance.color(chip.project))
                                        )
                                        Text(
                                            text = chip.name,
                                            color = if (selected) Color.White else OrbStyle.textSecondary,
                                            fontSize = 12.sp,
                                            fontWeight = FontWeight.Medium,
                                            maxLines = 1
                                        )
                                        Text(
                                            text = "${chip.count}",
                                            color = OrbStyle.textMuted,
                                            fontSize = 11.sp,
                                            fontFamily = FontFamily.Monospace
                                        )
                                    }
                                }
                            }
                        }
                    }
                }

                if (showRunningSection && workingMissions.isNotEmpty()) {
                    item(key = "working_section") {
                        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            OrbInboxSectionHeader(
                                title = "WORKING IN BACKGROUND",
                                count = workingMissions.size
                            )
                            workingMissions.forEach { mission ->
                                val project = OrbInboxModel.resolveProject(mission, projects)
                                val pName = project.str("title", "name", "slug") ?: "Project"
                                val updated = mission.str("updated_at", "started_at", "created_at")
                                Row(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .clip(RoundedCornerShape(12.dp))
                                        .background(OrbStyle.surface)
                                        .border(1.dp, OrbStyle.border, RoundedCornerShape(12.dp))
                                        .orbPressClickable { onSelectMission(mission, project) }
                                        .padding(horizontal = 12.dp, vertical = 10.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(10.dp)
                                ) {
                                    OrbRunningDots(color = Color.White, dotSize = 2.1.dp, spacing = 1.9.dp)
                                    Box(
                                        modifier = Modifier
                                            .size(6.dp)
                                            .clip(CircleShape)
                                            .background(OrbProjectAppearance.color(project))
                                    )
                                    Text(
                                        text = pName,
                                        color = OrbStyle.textSecondary,
                                        fontSize = 12.sp,
                                        fontWeight = FontWeight.Medium
                                    )
                                    Text(
                                        text = "·",
                                        color = OrbStyle.textMuted,
                                        fontSize = 12.sp
                                    )
                                    Text(
                                        text = OrbInboxModel.missionHeadline(mission),
                                        color = Color.White,
                                        fontSize = 13.sp,
                                        fontWeight = FontWeight.Medium,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis,
                                        modifier = Modifier.weight(1f)
                                    )
                                    Text(
                                        text = OrbJSON.relative(updated),
                                        color = OrbStyle.textMuted,
                                        fontSize = 11.sp,
                                        fontFamily = FontFamily.Monospace
                                    )
                                }
                            }
                        }
                    }
                }

                if (visibleItems.isEmpty()) {
                    item(key = "empty") {
                        Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 24.dp, vertical = 56.dp),
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.spacedBy(12.dp)
                        ) {
                            Box(
                                modifier = Modifier
                                    .size(56.dp)
                                    .clip(CircleShape)
                                    .background(OrbStyle.surface)
                                    .border(1.dp, OrbStyle.border, CircleShape),
                                contentAlignment = Alignment.Center
                            ) {
                                Icon(
                                    imageVector = Icons.Default.CheckCircleOutline,
                                    contentDescription = null,
                                    tint = OrbStyle.textSecondary,
                                    modifier = Modifier.size(22.dp)
                                )
                            }
                            Text(
                                text = when (filterMode) {
                                    OrbInboxFilterMode.Unread -> "No unread updates"
                                    OrbInboxFilterMode.Attention -> "Nothing waiting on you"
                                    OrbInboxFilterMode.All -> "Inbox is clear"
                                },
                                color = Color.White,
                                fontSize = 17.sp,
                                fontWeight = FontWeight.SemiBold
                            )
                            Text(
                                text = if (workingMissions.isEmpty()) {
                                    "Finished runs, approvals, and blocked missions across all projects will appear here."
                                } else {
                                    "${workingMissions.size} ${if (workingMissions.size == 1) "agent is" else "agents are"} currently working in the background."
                                },
                                color = OrbStyle.textSecondary,
                                fontSize = 13.sp
                            )
                            if (filterMode != OrbInboxFilterMode.All && allItems.isNotEmpty()) {
                                Box(
                                    modifier = Modifier
                                        .padding(top = 4.dp)
                                        .clip(CircleShape)
                                        .background(OrbStyle.surface)
                                        .border(1.dp, OrbStyle.border, CircleShape)
                                        .orbPressClickable { filterMode = OrbInboxFilterMode.All }
                                        .padding(horizontal = 14.dp, vertical = 8.dp)
                                ) {
                                    Text(
                                        text = "Show all ${allItems.size} items",
                                        color = Color.White,
                                        fontSize = 13.sp,
                                        fontWeight = FontWeight.SemiBold
                                    )
                                }
                            }
                        }
                    }
                } else {
                    if (needsInputItems.isNotEmpty()) {
                        item(key = "needs_you_header") {
                            OrbInboxSectionHeader(
                                title = "NEEDS YOU",
                                count = needsInputItems.size
                            )
                        }

                        items(needsInputItems, key = { "needs-${it.id}" }) { item ->
                            OrbInboxCard(
                                item = item,
                                isReplying = replyingItemId == item.id,
                                replyDraft = if (replyingItemId == item.id) replyDraft else "",
                                onReplyDraftChange = { replyDraft = it },
                                isSending = sendingItemId == item.id,
                                isPeeked = peekedItemId == item.id,
                                peekMessages = peekMessagesByItem[item.id] ?: emptyList(),
                                isLoadingPeek = loadingPeekId == item.id,
                                onSelectMission = {
                                    markItemAndChildrenRead(item)
                                    onSelectMission(item.mission, item.project)
                                },
                                onSelectFailedChild = { failedChild ->
                                    markItemAndChildrenRead(item)
                                    onSelectMission(failedChild, item.project)
                                },
                                onTogglePeek = { togglePeek(item) },
                                onMarkRead = { markItemAndChildrenRead(item) },
                                onToggleReply = {
                                    if (replyingItemId == item.id) {
                                        replyingItemId = null
                                        replyDraft = ""
                                    } else {
                                        replyingItemId = item.id
                                        replyDraft = ""
                                    }
                                },
                                onSendQuickReply = { sendQuickReply(it, item) },
                                onDismiss = { dismissWithUndo(item) }
                            )
                        }
                    }

                    if (finishedItems.isNotEmpty()) {
                        item(key = "finished_header") {
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                OrbInboxSectionHeader(
                                    title = "READY FOR REVIEW",
                                    count = finishedItems.size
                                )
                                Spacer(modifier = Modifier.weight(1f))
                                Text(
                                    text = "Mark all done",
                                    color = OrbStyle.textSecondary,
                                    fontSize = 12.sp,
                                    fontWeight = FontWeight.Medium,
                                    modifier = Modifier.orbPressClickable {
                                        OrbInboxModel.dismissAll(finishedItems)
                                    }
                                )
                            }
                        }

                        items(finishedItems, key = { "done-${it.id}" }) { item ->
                            OrbInboxCard(
                                item = item,
                                isReplying = replyingItemId == item.id,
                                replyDraft = if (replyingItemId == item.id) replyDraft else "",
                                onReplyDraftChange = { replyDraft = it },
                                isSending = sendingItemId == item.id,
                                isPeeked = peekedItemId == item.id,
                                peekMessages = peekMessagesByItem[item.id] ?: emptyList(),
                                isLoadingPeek = loadingPeekId == item.id,
                                onSelectMission = {
                                    markItemAndChildrenRead(item)
                                    onSelectMission(item.mission, item.project)
                                },
                                onSelectFailedChild = { failedChild ->
                                    markItemAndChildrenRead(item)
                                    onSelectMission(failedChild, item.project)
                                },
                                onTogglePeek = { togglePeek(item) },
                                onMarkRead = { markItemAndChildrenRead(item) },
                                onToggleReply = {
                                    if (replyingItemId == item.id) {
                                        replyingItemId = null
                                        replyDraft = ""
                                    } else {
                                        replyingItemId = item.id
                                        replyDraft = ""
                                    }
                                },
                                onSendQuickReply = { sendQuickReply(it, item) },
                                onDismiss = { dismissWithUndo(item) }
                            )
                        }
                    }
                }
            }
        }

        val dismissed = lastDismissedItem
        if (dismissed != null) {
            Row(
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .padding(horizontal = 18.dp, vertical = 14.dp)
                    .clip(CircleShape)
                    .background(OrbStyle.elevated)
                    .border(1.dp, OrbStyle.borderStrong, CircleShape)
                    .padding(horizontal = 15.dp, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                Icon(
                    imageVector = Icons.Default.CheckCircle,
                    contentDescription = null,
                    tint = OrbStyle.success,
                    modifier = Modifier.size(14.dp)
                )
                Text(
                    text = "Marked done",
                    color = Color.White,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Medium
                )
                Spacer(modifier = Modifier.width(6.dp))
                Text(
                    text = "Undo",
                    color = OrbStyle.inboxBlue,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Bold,
                    modifier = Modifier.orbPressClickable {
                        OrbInboxModel.restore(dismissed)
                        lastDismissedItem = null
                    }
                )
            }
        }
    }
}

@Composable
private fun OrbInboxSectionHeader(title: String, count: Int) {
    Row(
        modifier = Modifier.padding(top = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp)
    ) {
        Text(
            text = title,
            color = OrbStyle.textMuted,
            fontSize = 11.sp,
            fontWeight = FontWeight.SemiBold,
            letterSpacing = 0.5.sp
        )
        Text(
            text = "$count",
            color = OrbStyle.textMuted,
            fontSize = 11.sp,
            fontWeight = FontWeight.Medium,
            fontFamily = FontFamily.Monospace
        )
    }
}

@Composable
private fun OrbInboxCard(
    item: OrbInboxItem,
    isReplying: Boolean,
    replyDraft: String,
    onReplyDraftChange: (String) -> Unit,
    isSending: Boolean,
    isPeeked: Boolean,
    peekMessages: List<OrbRow>,
    isLoadingPeek: Boolean,
    onSelectMission: () -> Unit,
    onSelectFailedChild: (OrbRow) -> Unit,
    onTogglePeek: () -> Unit,
    onMarkRead: () -> Unit,
    onToggleReply: () -> Unit,
    onSendQuickReply: (String) -> Unit,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier
) {
    val pName = item.project.str("title", "name", "slug") ?: "Project"
    val pColor = OrbProjectAppearance.color(item.project)

    Column(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(OrbStyle.surface)
            .border(
                1.dp,
                if (isReplying) OrbStyle.borderStrong else OrbStyle.border,
                RoundedCornerShape(14.dp)
            )
            .padding(horizontal = 13.dp, vertical = 11.dp),
        verticalArrangement = Arrangement.spacedBy(9.dp)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .orbPressClickable { onSelectMission() },
            verticalArrangement = Arrangement.spacedBy(6.dp)
        ) {
            // Line 1: Unread dot + Project dot + Project name + · + Goal tag + Headline + Badge + Time
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                if (item.isUnread) {
                    Box(
                        modifier = Modifier
                            .size(7.dp)
                            .clip(CircleShape)
                            .background(Color(0xFF0A84FF))
                    )
                }
                Box(
                    modifier = Modifier
                        .size(7.dp)
                        .clip(CircleShape)
                        .background(pColor)
                )
                Text(
                    text = pName,
                    color = OrbStyle.textSecondary,
                    fontSize = 12.sp,
                    fontWeight = FontWeight.Medium,
                    maxLines = 1
                )
                Text(
                    text = "·",
                    color = OrbStyle.textMuted,
                    fontSize = 12.sp
                )
                if (item.isGoal) {
                    Text(
                        text = "Goal",
                        color = OrbStyle.inboxBlue,
                        fontSize = 10.sp,
                        fontWeight = FontWeight.SemiBold,
                        modifier = Modifier
                            .clip(CircleShape)
                            .background(OrbStyle.inboxBlue.copy(alpha = 0.14f))
                            .padding(horizontal = 6.dp, vertical = 2.dp)
                    )
                }
                Text(
                    text = item.headline,
                    color = Color.White,
                    fontSize = 14.5.sp,
                    fontWeight = if (item.isUnread) FontWeight.SemiBold else FontWeight.Medium,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f)
                )
                Text(
                    text = item.badge,
                    color = item.tone.foreground,
                    fontSize = 10.5.sp,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier
                        .clip(CircleShape)
                        .background(item.tone.background)
                        .padding(horizontal = 7.dp, vertical = 2.5.dp)
                )
                val rel = OrbJSON.relative(item.updatedAt)
                if (rel.isNotEmpty()) {
                    Text(
                        text = rel,
                        color = OrbStyle.textMuted,
                        fontSize = 11.sp,
                        fontFamily = FontFamily.Monospace
                    )
                }
            }

            // Line 2: 1-sentence prose summary
            if (item.summary.isNotEmpty()) {
                Text(
                    text = item.summary,
                    color = OrbStyle.textSecondary,
                    fontSize = 13.sp,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis
                )
            }

            if (!item.commandPreview.isNullOrEmpty()) {
                Text(
                    text = item.commandPreview,
                    color = OrbStyle.textSecondary,
                    fontSize = 11.sp,
                    fontFamily = FontFamily.Monospace,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(7.dp))
                        .background(Color.Black.copy(alpha = 0.28f))
                        .padding(horizontal = 8.dp, vertical = 5.dp)
                )
            }
        }

        // Subagent track summary pill
        if (item.childCount > 0) {
            val firstFailed = item.failedChildren.firstOrNull()
            if (firstFailed != null) {
                Row(
                    modifier = Modifier
                        .clip(RoundedCornerShape(6.dp))
                        .background(OrbStyle.error.copy(alpha = 0.12f))
                        .border(1.dp, OrbStyle.error.copy(alpha = 0.28f), RoundedCornerShape(6.dp))
                        .orbPressClickable { onSelectFailedChild(firstFailed.row) }
                        .padding(horizontal = 8.dp, vertical = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    Box(
                        modifier = Modifier
                            .size(6.dp)
                            .clip(CircleShape)
                            .background(OrbStyle.error)
                    )
                    Text(
                        text = "${item.failedChildCount} ${if (item.failedChildCount == 1) "track" else "tracks"} failed: ${firstFailed.title}",
                        color = OrbStyle.error,
                        fontSize = 11.sp,
                        fontWeight = FontWeight.Medium,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false)
                    )
                    Icon(
                        imageVector = Icons.Default.ArrowForward,
                        contentDescription = null,
                        tint = OrbStyle.error,
                        modifier = Modifier.size(11.dp)
                    )
                }
            } else {
                Text(
                    text = "${item.childCount} ${if (item.childCount == 1) "track" else "tracks"} · ${item.completedChildCount} completed${if (item.runningChildCount > 0) " · ${item.runningChildCount} running" else ""}",
                    color = OrbStyle.textMuted,
                    fontSize = 11.sp,
                    modifier = Modifier
                        .clip(RoundedCornerShape(6.dp))
                        .background(Color.White.copy(alpha = 0.04f))
                        .padding(horizontal = 8.dp, vertical = 3.5.dp)
                )
            }
        }

        // Quick action bar matching iOS line 1340
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp)
        ) {
            if (item.quickOptions.isNotEmpty()) {
                item.quickOptions.take(2).forEachIndexed { idx, opt ->
                    val primary = idx == 0
                    Box(
                        modifier = Modifier
                            .clip(CircleShape)
                            .background(if (primary) Color.White else Color.White.copy(alpha = 0.06f))
                            .border(1.dp, if (primary) Color.Transparent else OrbStyle.border, CircleShape)
                            .orbPressClickable(enabled = !isSending) { onSendQuickReply(opt) }
                            .padding(horizontal = 11.dp, vertical = 5.5.dp)
                    ) {
                        Text(
                            text = opt,
                            color = if (primary) OrbStyle.background else Color.White,
                            fontSize = 12.sp,
                            fontWeight = if (primary) FontWeight.SemiBold else FontWeight.Medium,
                            maxLines = 1
                        )
                    }
                }
            }

            if (item.canRetry) {
                Row(
                    modifier = Modifier
                        .clip(CircleShape)
                        .background(OrbStyle.warning.copy(alpha = 0.12f))
                        .border(1.dp, OrbStyle.warning.copy(alpha = 0.32f), CircleShape)
                        .orbPressClickable(enabled = !isSending) {
                            onSendQuickReply("Continue and resolve the blocker/error.")
                        }
                        .padding(horizontal = 9.dp, vertical = 5.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    Icon(
                        imageVector = Icons.Default.Refresh,
                        contentDescription = null,
                        tint = OrbStyle.warning,
                        modifier = Modifier.size(11.dp)
                    )
                    Text(
                        text = "Retry",
                        color = OrbStyle.warning,
                        fontSize = 12.sp,
                        fontWeight = FontWeight.Medium
                    )
                }
            }

            Box(
                modifier = Modifier
                    .clip(CircleShape)
                    .background(if (isPeeked) OrbStyle.elevated else Color.White.copy(alpha = 0.04f))
                    .border(1.dp, OrbStyle.border, CircleShape)
                    .orbPressClickable { onTogglePeek() }
                    .padding(horizontal = 9.dp, vertical = 5.dp)
            ) {
                Text(
                    text = "Peek",
                    color = if (isPeeked) Color.White else OrbStyle.textSecondary,
                    fontSize = 12.sp,
                    fontWeight = FontWeight.Medium
                )
            }

            Spacer(modifier = Modifier.weight(1f))

            if (item.isUnread) {
                Row(
                    modifier = Modifier
                        .clip(CircleShape)
                        .background(Color.White.copy(alpha = 0.04f))
                        .border(1.dp, OrbStyle.border, CircleShape)
                        .orbPressClickable { onMarkRead() }
                        .padding(horizontal = 9.dp, vertical = 5.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    Box(
                        modifier = Modifier
                            .size(6.dp)
                            .clip(CircleShape)
                            .background(Color(0xFF0A84FF))
                    )
                    Text(
                        text = "Read",
                        color = OrbStyle.textSecondary,
                        fontSize = 12.sp,
                        fontWeight = FontWeight.Medium
                    )
                }
            }

            Row(
                modifier = Modifier
                    .clip(CircleShape)
                    .background(if (isReplying) OrbStyle.elevated else Color.White.copy(alpha = 0.04f))
                    .border(1.dp, OrbStyle.border, CircleShape)
                    .orbPressClickable { onToggleReply() }
                    .padding(horizontal = 10.dp, vertical = 5.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp)
            ) {
                Icon(
                    imageVector = Icons.AutoMirrored.Filled.Reply,
                    contentDescription = null,
                    tint = if (isReplying) Color.White else OrbStyle.textSecondary,
                    modifier = Modifier.size(11.dp)
                )
                Text(
                    text = "Reply",
                    color = if (isReplying) Color.White else OrbStyle.textSecondary,
                    fontSize = 12.sp,
                    fontWeight = FontWeight.Medium
                )
            }

            Row(
                modifier = Modifier
                    .clip(CircleShape)
                    .background(Color.White.copy(alpha = 0.04f))
                    .border(1.dp, OrbStyle.border, CircleShape)
                    .orbPressClickable { onDismiss() }
                    .padding(horizontal = 10.dp, vertical = 5.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp)
            ) {
                Icon(
                    imageVector = Icons.Default.Check,
                    contentDescription = null,
                    tint = OrbStyle.textSecondary,
                    modifier = Modifier.size(11.dp)
                )
                Text(
                    text = "Done",
                    color = OrbStyle.textSecondary,
                    fontSize = 12.sp,
                    fontWeight = FontWeight.Medium
                )
            }
        }

        if (isPeeked) {
            Column(
                modifier = Modifier.padding(top = 2.dp),
                verticalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                if (isLoadingPeek && peekMessages.isEmpty()) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        CircularProgressIndicator(
                            color = OrbStyle.textSecondary,
                            strokeWidth = 2.dp,
                            modifier = Modifier.size(14.dp)
                        )
                        Text(
                            text = "Loading recent turns…",
                            color = OrbStyle.textSecondary,
                            fontSize = 12.sp
                        )
                    }
                } else {
                    val rowsToShow = if (peekMessages.isNotEmpty()) {
                        peekMessages
                    } else {
                        listOf(
                            OrbRow(
                                "fallback",
                                mapOf("role" to "assistant", "content" to item.summary)
                            )
                        )
                    }
                    rowsToShow.forEach { msg ->
                        val role = (msg.str("role", "sender", "author") ?: "assistant").lowercase()
                        val isUser = role == "user" || role == "operator" || role == "human"
                        val text = OrbInboxModel.cleanMarkdownPreview(msg.str("content", "text", "message") ?: "")
                        if (text.isNotEmpty()) {
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clip(RoundedCornerShape(8.dp))
                                    .background(Color.Black.copy(alpha = 0.24f))
                                    .padding(horizontal = 9.dp, vertical = 6.dp),
                                verticalAlignment = Alignment.Top,
                                horizontalArrangement = Arrangement.spacedBy(8.dp)
                            ) {
                                Text(
                                    text = if (isUser) "YOU" else "AGENT",
                                    color = if (isUser) OrbStyle.textSecondary else OrbStyle.inboxBlue,
                                    fontSize = 10.sp,
                                    fontWeight = FontWeight.SemiBold,
                                    modifier = Modifier.width(40.dp)
                                )
                                Text(
                                    text = text,
                                    color = OrbStyle.textSecondary,
                                    fontSize = 12.sp,
                                    modifier = Modifier.weight(1f)
                                )
                            }
                        }
                    }
                }
            }
        }

        if (isReplying) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .clip(RoundedCornerShape(10.dp))
                        .background(Color.Black.copy(alpha = 0.28f))
                        .border(1.dp, OrbStyle.borderStrong, RoundedCornerShape(10.dp))
                        .padding(horizontal = 11.dp, vertical = 8.dp)
                ) {
                    if (replyDraft.isEmpty()) {
                        Text(
                            text = "Send follow-up…",
                            color = OrbStyle.textMuted,
                            fontSize = 13.sp,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                    BasicTextField(
                        value = replyDraft,
                        onValueChange = onReplyDraftChange,
                        textStyle = TextStyle(color = Color.White, fontSize = 13.sp),
                        cursorBrush = SolidColor(Color.White),
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth()
                    )
                }
                val canSend = replyDraft.trim().isNotEmpty() && !isSending
                Box(
                    modifier = Modifier
                        .clip(CircleShape)
                        .background(if (canSend) Color.White else Color.White.copy(alpha = 0.08f))
                        .orbPressClickable(enabled = canSend) { onSendQuickReply(replyDraft) }
                        .padding(horizontal = 12.dp, vertical = 8.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        text = if (isSending) "…" else "Send",
                        color = if (canSend) OrbStyle.background else OrbStyle.textMuted,
                        fontSize = 12.sp,
                        fontWeight = FontWeight.SemiBold
                    )
                }
            }
        }
    }
}
