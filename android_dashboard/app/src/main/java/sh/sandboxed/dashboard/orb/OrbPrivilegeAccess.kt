package sh.sandboxed.dashboard.orb

import java.time.Instant

/**
 * Privileged access requests (`/api/privilege-access`): a mission asks for
 * root, a service deploy or read-only ops on a host, usually for the rest of
 * its session. Approving needs a device signature (BiometricPrompt via
 * [OrbApprovalKey.signedRequest]); Core checks the grant on every command.
 * Labels match desktop `privilegeAccessApi.ts`, iOS `OrbPrivilegeAccess.swift`
 * and `shared/orb-spec/fixtures/privilege-access.json`.
 */
object OrbPrivilegeAccess {
    fun scopeLabel(scope: String?): String = when (scope) {
        "ops_read" -> "Read-only ops"
        "service_deploy" -> "Service deploy"
        "root_exec" -> "Root"
        else -> scope ?: ""
    }

    fun host(h: String?): String = if (h == "self") "its own node" else h ?: ""

    fun title(r: Map<String, Any?>): String = "${scopeLabel(r["scope"] as? String)} on ${host(r["target_host"] as? String)}"

    fun unlocks(r: Map<String, Any?>): String {
        val unit = (r["allowed_unit"] as? String).orEmpty()
        return when (r["scope"]) {
            "service_deploy" -> if (unit.isNotEmpty()) "restart and deploy $unit only" else "restart and deploy services, including production"
            "ops_read" -> "logs, status and disk checks as root; no changes"
            "root_exec" -> "any command as root"
            else -> ""
        }
    }

    fun lifetime(r: Map<String, Any?>): String {
        val m = (r["ttl_minutes"] as? Number)?.toInt() ?: 0
        val span = if (m >= 60 && m % 60 == 0) "${m / 60} h" else "$m min"
        return if (r["session_scoped"] == true) "for this session (max $span)" else "for $span"
    }

    fun requester(r: Map<String, Any?>): String =
        (r["requester_title"] as? String)?.takeIf { it.isNotBlank() }
            ?: "Mission ${(r["requester_mission_id"] as? String)?.take(8) ?: ""}"

    /** Approved, not revoked and not yet expired (Core still decides every command). */
    fun isLive(r: Map<String, Any?>, now: Instant = Instant.now()): Boolean =
        r["state"] == "approved" && (r["revoked_at"] as? String).isNullOrEmpty() &&
            runCatching { Instant.parse(r["expires_at"] as String).isAfter(now) }.getOrDefault(false)

    /** Body Core expects on approve: keep the lifetime the mission asked for. */
    fun approveBody(r: Map<String, Any?>): Map<String, Any?> =
        mapOf("ttl_minutes" to (r["ttl_minutes"] as? Number)?.toInt(), "session_scoped" to (r["session_scoped"] == true))

    /** What one "Approve all" grants: count per tier (root first), hosts and missions. Same strings as desktop `batchSummary`. */
    data class Batch(val tiers: String, val hosts: String, val missions: String, val root: Int)

    fun batchSummary(rs: List<Map<String, Any?>>): Batch = Batch(
        tiers = listOf("root_exec", "service_deploy", "ops_read")
            .mapNotNull { s -> rs.count { it["scope"] == s }.takeIf { it > 0 }?.let { "$it ${scopeLabel(s)}" } }
            .joinToString(" · "),
        hosts = rs.map { (it["target_host"] as? String).orEmpty() }.toSortedSet().joinToString(", ") { host(it) },
        missions = rs.map { requester(it) }.toSortedSet().joinToString(", "),
        root = rs.count { it["scope"] == "root_exec" },
    )

    /** Root stays out of "Approve all" unless ticked; Core enforces it too (`confirm_root`). */
    fun batchApprovable(rs: List<Map<String, Any?>>, includeRoot: Boolean): List<Map<String, Any?>> =
        rs.filter { includeRoot || it["scope"] != "root_exec" }

    /** The signed body for `/api/approvals/approve-all`: each request by Core's digest of what it grants. Core refuses the whole batch if one changed. */
    fun batchBody(rs: List<Map<String, Any?>>): Map<String, Any?> = mapOf(
        "items" to rs.map { r -> mapOf("kind" to "privilege", "id" to r["id"], "digest" to ((r["digest"] as? String) ?: "")) },
        "confirm_critical" to (batchSummary(rs).root > 0),
    )
}
