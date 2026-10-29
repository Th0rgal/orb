package sh.sandboxed.dashboard.orb

import java.security.MessageDigest

/**
 * Every request a mission or external session raises for the user's approval, of any kind
 * (`secret`, `privilege`, `mission_access`), as Core lists it
 * (`GET /api/approvals/queue`, src/api/approval_queue.rs). Approving signs
 * `{kind, id, digest}` for each item with one BiometricPrompt; Core admits
 * the batch only when every item is still pending, unchanged and, if
 * critical, confirmed (the Lean `orb_verify_approval` gate). Same names as
 * desktop `approvalQueue.ts` and iOS `OrbApprovalQueue.swift`, checked
 * against `shared/orb-spec/fixtures/approvals.json`.
 */
object OrbApprovalQueue {
    private val secretVerb = mapOf("read" to "Read", "write" to "Store", "delete" to "Delete", "move" to "Move")
    private val riskOrder = listOf("critical", "elevated", "routine")

    @Suppress("UNCHECKED_CAST")
    private fun request(i: Map<String, Any?>): Map<String, Any?> = (i["request"] as? Map<String, Any?>).orEmpty()
    private fun str(m: Map<String, Any?>, k: String): String = (m[k] as? String).orEmpty()

    private fun mission(title: String, id: String) = title.ifBlank { "Mission ${id.take(8)}" }

    private fun stripControls(s: String): String {
        val sb = StringBuilder()
        var i = 0
        while (i < s.length) {
            val cp = s.codePointAt(i)
            if (!(cp <= 0x1F || cp in 0x7F..0x9F)) sb.appendCodePoint(cp)
            i += Character.charCount(cp)
        }
        return sb.toString().trim()
    }

    private fun takeCodePoints(s: String, max: Int): String {
        val sb = StringBuilder()
        var i = 0
        var count = 0
        while (i < s.length && count < max) {
            val cp = s.codePointAt(i)
            sb.appendCodePoint(cp)
            i += Character.charCount(cp)
            count++
        }
        return sb.toString()
    }

    fun externalLabel(subject: Map<String, Any?>?): String? {
        if (subject == null || subject["kind"] != "external_session") return null
        val fallback = str(subject, "client_kind").ifEmpty { "local_mcp" }
        val label = takeCodePoints(stripControls(str(subject, "client_label")), 80).ifEmpty { fallback }
        val host = takeCodePoints(stripControls(str(subject, "host_hint")), 80)
        return if (host.isEmpty()) "External · $label" else "External · $host ($label)"
    }

    @Suppress("UNCHECKED_CAST")
    fun subjectOf(r: Map<String, Any?>): Map<String, Any?>? {
        (r["requester_subject"] as? Map<String, Any?>)?.let { return it }
        (r["requester"] as? Map<String, Any?>)?.let { return it }
        val req = request(r)
        return (req["requester_subject"] as? Map<String, Any?>) ?: (req["requester"] as? Map<String, Any?>)
    }

    fun subjectKey(r: Map<String, Any?>): String {
        val subject = subjectOf(r)
        if (subject?.get("kind") == "external_session") return "session:${str(subject, "session_id")}"
        if (subject?.get("kind") == "mission") return "mission:${str(subject, "mission_id")}"
        val missionId = str(r, "requester_mission_id").ifEmpty { str(r, "mission_id") }
        if (missionId.isNotEmpty()) return "mission:$missionId"
        val label = actorLabel(r)
        return if (label.isEmpty()) "mission:" else "external:$label"
    }

    private fun sha256Hex(input: String): String =
        MessageDigest.getInstance("SHA-256").digest(input.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }

    fun canonicalSubjectId(subject: Map<String, Any?>): String {
        if (subject["kind"] == "mission") return "mission:${str(subject, "mission_id")}"
        val kind = str(subject, "client_kind").ifEmpty { "local_mcp" }
        val label = str(subject, "client_label").trim()
        val host = str(subject, "host_hint").trim()
        val hash = sha256Hex("$label\n$host").take(16)
        return "session:${str(subject, "session_id")}:$kind:$hash"
    }

    fun approvalDigest(kind: String, id: String, subject: Map<String, Any?>, fields: List<String>): String {
        val head = if (subject["kind"] == "mission") {
            "orb-approval-v1\n$kind\n$id\n${str(subject, "mission_id")}"
        } else {
            "orb-approval-v2\n$kind\n$id\n${canonicalSubjectId(subject)}"
        }
        return sha256Hex((listOf(head) + fields).joinToString("\n"))
    }

    fun actorLabel(r: Map<String, Any?>): String {
        val explicit = str(r, "requester_label").ifEmpty { str(request(r), "requester_label") }
        if (explicit.isNotBlank()) return explicit
        val subject = subjectOf(r)
        externalLabel(subject)?.let { return it }
        val title = str(r, "requester_title").ifEmpty { str(r, "mission_title") }
        if (title.isNotBlank()) return title
        val missionId = listOf(
            str(r, "requester_mission_id"),
            str(r, "mission_id"),
            if (subject?.get("kind") == "mission") str(subject, "mission_id") else ""
        ).firstOrNull { it.isNotEmpty() }.orEmpty()
        return mission("", missionId)
    }

    /** What approving does, in a few words ("Root on its own node", "Store DEPLOY_TOKEN"). */
    fun title(i: Map<String, Any?>): String {
        val r = request(i)
        return when (i["kind"]) {
            "privilege" -> OrbPrivilegeAccess.title(r)
            "mission_access" -> "Read ${mission(str(r, "target_title"), str(r, "target_mission_id"))}"
            else -> {
                val verb = secretVerb[i["tier"]] ?: "Read"
                when {
                    str(r, "key").isNotEmpty() -> "$verb ${str(r, "key")}"
                    r["all_projects"] == true -> "$verb every secret project"
                    else -> "$verb a whole secret project"
                }
            }
        }
    }

    fun requester(i: Map<String, Any?>): String = actorLabel(i)

    /**
     * The fine print: what it unlocks and for how long, and for secrets the
     * project a write lands in, a delete removes from, or a move goes between.
     */
    fun detail(i: Map<String, Any?>, projectName: (String) -> String = { it.take(8) }): String {
        val r = request(i)
        fun project(k: String) = str(r, k).let { if (it.isEmpty()) "" else projectName(it) }
        return when (i["kind"]) {
            "privilege" -> "Allows ${OrbPrivilegeAccess.unlocks(r)} · ${OrbPrivilegeAccess.lifetime(r)}"
            "mission_access" -> "Read only · ${(r["ttl_hours"] as? Number)?.toInt() ?: 0} h · no messages, cancel or resume"
            else -> {
                val from = project("project_id").ifEmpty { "unknown project" }
                when (i["tier"]) {
                    "move" -> "From $from to ${project("target_project_id").ifEmpty { "unknown project" }}"
                    "delete" -> "From $from"
                    "write" -> project("project_id").let { if (it.isEmpty()) "" else "Into $it" }
                    else -> ""
                }
            }
        }
    }

    fun isCritical(i: Map<String, Any?>): Boolean = i["risk"] == "critical"

    /** The "Approve all" line: risks most severe first, then who asks. */
    data class Summary(val risks: String, val missions: String, val critical: Int)

    fun summary(items: List<Map<String, Any?>>): Summary = Summary(
        risks = riskOrder.mapNotNull { k -> items.count { it["risk"] == k }.takeIf { it > 0 }?.let { "$it $k" } }.joinToString(" · "),
        missions = items.map { requester(it) }.toSortedSet().joinToString(", "),
        critical = items.count { isCritical(it) },
    )

    /** What "Approve all" covers: critical items only when ticked. */
    /** Core's per-signature limit (`MAX_BATCH` in src/api/approval_queue.rs). */
    const val MAX_BATCH = 20

    /** What "Approve N" under the normal rows covers: the non-critical items only, at most [MAX_BATCH]. */
    fun normalBatch(items: List<Map<String, Any?>>): List<Map<String, Any?>> =
        items.filter { !isCritical(it) }.take(MAX_BATCH)

    /** What "Approve all" covers: every item, critical first so the prompt names them before anything else; at most [MAX_BATCH]. */
    fun allBatch(items: List<Map<String, Any?>>): List<Map<String, Any?>> =
        items.sortedBy { riskOrder.indexOf(it["risk"]).let { n -> if (n < 0) 3 else n } }.take(MAX_BATCH)

    /** The bottom button: plain "Approve all", or red with the critical count. */
    fun approveAllLabel(items: List<Map<String, Any?>>): String {
        val all = allBatch(items)
        val critical = all.count { isCritical(it) }
        return if (critical == 0) "Approve all" else "Approve all (${all.size}, incl. $critical critical)"
    }

    /** The signed body: each item by Core's digest. A single item is its own confirmation. */
    fun batchBody(items: List<Map<String, Any?>>): Map<String, Any?> = mapOf(
        "items" to items.map { mapOf("kind" to it["kind"], "id" to it["id"], "digest" to it["digest"]) },
        "confirm_critical" to items.any { isCritical(it) },
    )

    /** What the BiometricPrompt says: every item, critical first. */
    fun signingReason(items: List<Map<String, Any?>>): String =
        if (items.size == 1) "${title(items[0])} for ${requester(items[0])}"
        else "Approve ${items.size} requests (${summary(items).risks}): " +
            items.sortedBy { riskOrder.indexOf(it["risk"]).let { n -> if (n < 0) 3 else n } }.joinToString("; ") { title(it) }

    fun denyPath(i: Map<String, Any?>, encode: (String) -> String): String {
        val id = encode(str(i, "id"))
        return when (i["kind"]) {
            "privilege" -> "/api/privilege-access/$id/deny"
            "mission_access" -> "/api/mission-access/$id/deny"
            else -> "/api/bitwarden/requests/$id/reject"
        }
    }

    /** Risk of a kind's tier, as Core assigns it (approvals.json `risk`). */
    fun riskOf(kind: String, tier: String, request: Map<String, Any?> = emptyMap()): String = when (kind) {
        "privilege" -> when (tier) { "root_exec" -> "critical"; "service_deploy" -> "elevated"; else -> "routine" }
        "mission_access" -> "elevated"
        else -> when {
            tier == "delete" || tier == "move" -> "critical"
            tier == "write" || request["all_projects"] == true -> "elevated"
            else -> "routine"
        }
    }

    /** A per-kind request as a queue item, for a Core without the queue. No digest: approved through the kind's own signed route. */
    fun legacyItem(kind: String, r: Map<String, Any?>): Map<String, Any?> {
        val tier = when (kind) { "privilege" -> str(r, "scope"); "secret" -> str(r, "kind"); else -> "read_mission" }
        val target = when (kind) {
            "privilege" -> str(r, "target_host")
            "mission_access" -> str(r, "target_mission_id")
            else -> str(r, "key").ifEmpty { str(r, "project_id").ifEmpty { "*" } }
        }
        val missionId = str(r, "requester_mission_id").ifEmpty { str(r, "mission_id") }.ifEmpty { null }
        return mapOf(
            "kind" to kind, "id" to r["id"],
            "requester_mission_id" to missionId,
            "requester_title" to (r["requester_title"] ?: r["mission_title"]),
            "requester_subject" to (r["requester_subject"] ?: r["requester"]),
            "requester_label" to r["requester_label"],
            "tier" to tier, "target" to target, "risk" to riskOf(kind, tier, r),
            "reason" to r["reason"], "created_at" to r["created_at"], "digest" to "",
            "request" to r, "legacy" to true,
        )
    }

    /** Pending items from the per-kind lists the earlier clients used; an empty list hides nothing else. */
    fun legacyItems(
        privilege: List<Map<String, Any?>>,
        secrets: List<Map<String, Any?>>,
        missions: List<Map<String, Any?>>,
    ): List<Map<String, Any?>> = (
        privilege.filter { it["state"] == "pending" }.map { legacyItem("privilege", it) } +
            secrets.filter { it["status"] == "pending" }.map { legacyItem("secret", it) } +
            missions.filter { it["state"] == "pending" }.map { legacyItem("mission_access", it) }
        ).sortedByDescending { str(it, "created_at") }

    /** The kind's own approve route and body, for a Core without the queue. */
    fun legacyApprove(i: Map<String, Any?>, encode: (String) -> String): Pair<String, Map<String, Any?>> {
        val id = encode(str(i, "id"))
        val r = request(i)
        return when (i["kind"]) {
            "privilege" -> "/api/privilege-access/$id/approve" to OrbPrivilegeAccess.approveBody(r)
            "mission_access" -> "/api/mission-access/$id/approve" to mapOf("ttl_hours" to (r["ttl_hours"] as? Number)?.toInt())
            else -> "/api/bitwarden/requests/$id/approve" to emptyMap()
        }
    }
}
