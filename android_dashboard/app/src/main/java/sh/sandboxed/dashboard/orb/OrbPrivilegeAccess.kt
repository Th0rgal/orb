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

    fun requester(r: Map<String, Any?>): String = OrbApprovalQueue.actorLabel(r)

    /** Approved, not revoked and not yet expired (Core still decides every command). */
    fun isLive(r: Map<String, Any?>, now: Instant = Instant.now()): Boolean =
        r["state"] == "approved" && (r["revoked_at"] as? String).isNullOrEmpty() &&
            runCatching { Instant.parse(r["expires_at"] as String).isAfter(now) }.getOrDefault(false)

    /** Body Core expects on approve: keep the lifetime the mission asked for. */
    fun approveBody(r: Map<String, Any?>): Map<String, Any?> =
        mapOf("ttl_minutes" to (r["ttl_minutes"] as? Number)?.toInt(), "session_scoped" to (r["session_scoped"] == true))

    fun bunkerLabel(state: Int): String = when (state) {
        0 -> "Normal"
        1 -> "Soft Quarantine"
        2 -> "Hard Lockdown"
        3 -> "Sovereign Dead-Man Tripped"
        else -> "Locked ($state)"
    }

    fun bunkerBody(
        level: Int = 2,
        reason: String = "Operator manual Fleet Bunker lockdown from Orb Android"
    ): Map<String, Any?> = mapOf(
        "level" to level,
        "reason" to reason,
        "canary_tripped" to (level >= 2),
        "auth_failure_burst" to (level == 1)
    )

    /** Home card while bunkered; a dismissal hides it until the level changes (desktop `BunkerModeCard`). */
    fun showsBunkerCard(state: Int, dismissedLevel: Int): Boolean = state > 0 && dismissedLevel != state

    /** Core lists incidents newest first; canary dry runs do not change the posture. */
    fun latestIncidentReason(incidents: List<Map<String, Any?>>): String? =
        incidents.firstOrNull { it["dry_run"] != true && !(it["reason"] as? String).isNullOrEmpty() }?.get("reason") as? String

    /** Run on the Core host; Core deletes the file when a device uses it. */
    const val ENROLLMENT_CODE_COMMAND =
        "ssh agent-core 'umask 077; head -c 12 /dev/urandom | base64 | tr -dc A-Za-z0-9 | tee /root/.sandboxed-sh/approval_enrollment_code; echo'"

    /** Prompt only where Core asks for signatures and this key is not enrolled (iOS `OrbApprovalEnrollmentMonitor`). */
    fun shouldPromptEnrollment(mode: String, enrolled: Boolean, dismissedMode: String?): Boolean =
        (mode == "warn" || mode == "enforce") && !enrolled && dismissedMode != mode

    fun isEnrolled(publicKey: String?, devices: List<Map<String, Any?>>): Boolean =
        !publicKey.isNullOrEmpty() && devices.any { it["public_key"] == publicKey }
}
