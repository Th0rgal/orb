package sh.sandboxed.dashboard.orb

/**
 * Shared mobile UI compaction & sanitization rules (`shared/orb-spec/fixtures/mobile-debloat.json`),
 * mirrored in iOS `OrbActivityCompaction.swift`.
 */
object OrbActivityCompaction {
    data class CoalescedCommand(
        val id: String,
        val status: String,
        val exitCode: Int?,
        val host: String,
        val command: String,
        val missionId: String,
        val timestamp: String,
        val detail: String,
    )

    data class ErrorInput(
        val category: String,
        val summary: String,
        val detail: String,
        val at: Long,
    )

    data class CoalescedError(
        val category: String,
        val summary: String,
        val detail: String,
        val count: Int,
        val at: Long,
    ) {
        val id: String get() = "$category|$summary|$detail|$at"
    }

    private const val PRE_EXEC_PREFIX = "[pre-exec] "

    private fun str(value: Any?): String = when (value) {
        is String -> value
        is Number -> value.toString()
        else -> ""
    }

    /**
     * Coalesces newest-first privilege command audit entries by pairing each `EXIT <code>`
     * row with its nearest older matching `[pre-exec]` row on the same host. Unmatched
     * `[pre-exec]` rows remain visible as in-flight `RUN` rows with the prefix stripped.
     */
    fun coalescePrivilegeCommands(commands: List<Map<String, Any?>>): List<CoalescedCommand> {
        val consumed = HashSet<Int>()
        val result = ArrayList<CoalescedCommand>(commands.size)
        for (idx in commands.indices) {
            if (consumed.contains(idx)) continue
            val entry = commands[idx]
            val host = str(entry["target_host"]).ifBlank { str(entry["host"]) }
            val rawCmd = str(entry["command"]).trim()
            val exitCode = (entry["exit_code"] as? Number)?.toInt()
            val id = str(entry["id"]).ifBlank { "cmd-$idx" }
            val missionId = str(entry["mission_id"])
            val grantId = str(entry["grant_id"])
            val cwd = str(entry["cwd"])
            val ts = str(entry["at"])
                .ifBlank { str(entry["recorded_at"]) }
                .ifBlank { str(entry["created_at"]) }
                .ifBlank { str(entry["timestamp"]) }
            val detail = listOf(str(entry["stderr"]), str(entry["stdout"]))
                .filter { it.isNotBlank() }
                .joinToString("\n")

            if (exitCode != null) {
                val expectedPre = PRE_EXEC_PREFIX + rawCmd
                for (olderIdx in (idx + 1) until commands.size) {
                    if (consumed.contains(olderIdx)) continue
                    val older = commands[olderIdx]
                    val olderHost = str(older["target_host"]).ifBlank { str(older["host"]) }
                    if ((older["exit_code"] as? Number) == null &&
                        olderHost == host &&
                        str(older["mission_id"]) == missionId &&
                        str(older["grant_id"]) == grantId &&
                        str(older["cwd"]) == cwd &&
                        str(older["command"]).trim() == expectedPre
                    ) {
                        consumed.add(olderIdx)
                        break
                    }
                }
                result.add(
                    CoalescedCommand(
                        id = id,
                        status = "EXIT $exitCode",
                        exitCode = exitCode,
                        host = host,
                        command = rawCmd,
                        missionId = missionId,
                        timestamp = ts,
                        detail = detail,
                    )
                )
            } else {
                val cleanCmd = if (rawCmd.startsWith(PRE_EXEC_PREFIX)) {
                    rawCmd.removePrefix(PRE_EXEC_PREFIX).trim()
                } else {
                    rawCmd
                }
                result.add(
                    CoalescedCommand(
                        id = id,
                        status = "RUN",
                        exitCode = null,
                        host = host,
                        command = cleanCmd,
                        missionId = missionId,
                        timestamp = ts,
                        detail = detail,
                    )
                )
            }
        }
        return result
    }

    /**
     * Collapses consecutive identical `(category, summary, detail)` error entries,
     * keeping the newest timestamp and recording `count`.
     */
    fun coalesceErrors(entries: List<ErrorInput>): List<CoalescedError> {
        val out = ArrayList<CoalescedError>(entries.size)
        for (entry in entries) {
            val last = out.lastOrNull()
            if (last != null &&
                last.category == entry.category &&
                last.summary == entry.summary &&
                last.detail == entry.detail
            ) {
                out[out.lastIndex] = last.copy(count = last.count + 1)
            } else {
                out.add(
                    CoalescedError(
                        category = entry.category,
                        summary = entry.summary,
                        detail = entry.detail,
                        count = 1,
                        at = entry.at,
                    )
                )
            }
        }
        return out
    }

    /**
     * Deduplicates active mission-access grants by `(requester_mission_id, target_mission_id, scope)`,
     * keeping the grant with the latest `expires_at` while preserving first-seen order.
     */
    fun dedupeMissionGrants(grants: List<Map<String, Any?>>): List<Map<String, Any?>> {
        val indexByKey = HashMap<String, Int>()
        val out = ArrayList<Map<String, Any?>>(grants.size)
        for (grant in grants) {
            val req = str(grant["requester_mission_id"])
            val tgt = str(grant["target_mission_id"])
            val scope = str(grant["scope"])
            val key = if (req.isEmpty() && tgt.isEmpty()) "id:${str(grant["id"])}" else "$req|$tgt|$scope"
            val existingIdx = indexByKey[key]
            if (existingIdx != null) {
                if (str(grant["expires_at"]) > str(out[existingIdx]["expires_at"])) {
                    out[existingIdx] = grant
                }
            } else {
                indexByKey[key] = out.size
                out.add(grant)
            }
        }
        return out
    }

    /** Formats cooldown seconds into concise human units (`45s`, `4m 21s`, `1h`, `3d 17h`). */
    fun formatCooldown(seconds: Int): String {
        if (seconds <= 0) return "0s"
        if (seconds >= 86_400) {
            val d = seconds / 86_400
            val h = (seconds % 86_400) / 3_600
            return if (h > 0) "${d}d ${h}h" else "${d}d"
        }
        if (seconds >= 3_600) {
            val h = seconds / 3_600
            val m = (seconds % 3_600) / 60
            return if (m > 0) "${h}h ${m}m" else "${h}h"
        }
        if (seconds >= 60) {
            val m = seconds / 60
            val s = seconds % 60
            return if (s > 0) "${m}m ${s}s" else "${m}m"
        }
        return "${seconds}s"
    }

    /**
     * Strips Markdown pipe-table alignment separators (`|---|---|`) and joins cells with ` · `
     * so collapsed 2–3 line Inbox previews stay scannable.
     */
    fun cleanInboxPreview(raw: String): String {
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) return ""
        if (trimmed.count { it == '|' } < 2) return trimmed

        val startsWithPipe = trimmed.startsWith("|")
        val rawParts = trimmed.split("|")
        val cells = ArrayList<Pair<String, Boolean>>()
        for ((idx, part) in rawParts.withIndex()) {
            val collapsed = part.trim().split(Regex("\\s+")).filter { it.isNotEmpty() }.joinToString(" ")
            if (collapsed.isEmpty()) continue
            if (collapsed.contains('-') && collapsed.all { it == '-' || it == ':' || it == ' ' }) {
                continue
            }
            cells.add(collapsed to (idx == 0 && !startsWithPipe))
        }
        if (cells.isEmpty()) return trimmed
        val sb = StringBuilder(cells[0].first)
        val firstIsIntro = cells[0].second
        for (i in 1 until cells.size) {
            val cell = cells[i].first
            if (i == 1 && firstIsIntro && (sb.endsWith(":") || sb.endsWith(".") || sb.endsWith("!") || sb.endsWith("?"))) {
                sb.append(' ').append(cell)
            } else {
                sb.append(" · ").append(cell)
            }
        }
        return sb.toString()
    }

    /** True when an assistant message contains only whitespace or placeholder dots (`.`, `...`, `…`). */
    fun isPlaceholderTurn(text: String): Boolean {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return true
        return trimmed.all { it == '.' || it == '…' }
    }

    /**
     * True only for canonical 36-character `8-4-4-4-12` hex UUIDs accepted by Core's
     * `/api/control/inbox-state/seen/:mission_id` endpoint.
     */
    fun isCanonicalUUID(id: String): Boolean {
        if (id.length != 36) return false
        for (i in 0 until 36) {
            val c = id[i]
            if (i == 8 || i == 13 || i == 18 || i == 23) {
                if (c != '-') return false
            } else {
                val isHex = (c in '0'..'9') || (c in 'a'..'f') || (c in 'A'..'F')
                if (!isHex) return false
            }
        }
        return true
    }
}
