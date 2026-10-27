package sh.sandboxed.dashboard.orb

/**
 * Every request a mission raises for the user's approval, of any kind
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

    fun requester(i: Map<String, Any?>): String =
        mission(str(i, "requester_title"), str(i, "requester_mission_id"))

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

    /** At most [MAX_BATCH]; the rest stay for the next signature. */
    fun batchApprovable(items: List<Map<String, Any?>>, includeCritical: Boolean): List<Map<String, Any?>> =
        items.filter { includeCritical || !isCritical(it) }.take(MAX_BATCH)

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
}
