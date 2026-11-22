package sh.sandboxed.dashboard.orb

/** Lossless transport envelope, not a capability declaration or completion verdict. */
object OrbRemoteGoal {
    fun event(value: Map<String, Any?>): Map<String, Any?>? {
        val type = value["type"] as? String ?: return null
        if (type != "goal_status" && type != "goal_iteration") return null
        val data = value["data"] as? Map<*, *> ?: return null
        if (data.keys.any { it !is String }) return null
        return mapOf("type" to type, "data" to data.toMap())
    }

    data class Projection(val phase: String, val objective: String, val iteration: Int, val detail: String? = null)

    const val UNSUPPORTED = "Goal mode is unavailable for this remote harness because it cannot continue the objective safely. Choose OpenCode or send a standard turn."

    fun phase(status: String?, reason: String?): String = when {
        reason == "remote_goal_complete" -> "complete"
        reason == "remote_goal_stopped" || status == "cancelled" -> "stopped"
        status == "active" || status == "pending" || reason == "remote_goal_continuation" || reason == "awaiting_wakeup" -> "active"
        status == "paused" -> "paused"
        else -> "blocked"
    }

    fun label(phase: String, iteration: Int): String = when {
        phase != "active" -> "Goal $phase"
        iteration > 0 -> "Goal in progress · iteration $iteration"
        else -> "Goal in progress"
    }

    fun supports(fleet: Map<String, Any?>, backend: String): Boolean =
        ((fleet["remote_launch"] as? Map<*, *>)?.get("goal_harnesses") as? List<*>)?.contains(backend) == true
    fun apply(previous: Projection, value: Map<String, Any?>): Projection {
        val envelope = event(value) ?: return previous
        val data = envelope["data"] as? Map<*, *> ?: return previous
        val status = data["status"] as? String
        val phase = when {
            previous.phase == "complete" && status == "active" -> previous.phase
            previous.phase == "stopped" && status == "active" -> previous.phase
            status in setOf("active", "complete", "stopped", "paused", "blocked") -> status!!
            else -> previous.phase
        }
        return Projection(phase, data["objective"] as? String ?: previous.objective, (data["iteration"] as? Number)?.toInt() ?: previous.iteration, data["summary"] as? String ?: previous.detail)
    }
}

/** Core supplies this owner-scoped reason on the selected fleet row. */
object OrbNativeLaunch {
    fun warning(fleet: OrbDict, nodeID: String): String? {
        val rows = fleet["nodes"] as? List<*> ?: return null
        val node = rows.filterIsInstance<Map<*, *>>().firstOrNull { it["id"] == nodeID }
        return when (node?.get("launch_block")) {
            "native_owner_executor_unavailable" ->
                "The isolated workspace executor for this enrolled Antigravity account is unavailable. Choose another machine to start a mission."
            "native_owner_enrollment_required" ->
                "This node needs an enabled Antigravity account. Check its enrollment in provider settings or choose another machine."
            else -> null
        }
    }

    suspend fun require(nodeID: String, goalBackend: String?, loadFleet: suspend () -> OrbDict) {
        if (nodeID.isEmpty() || nodeID == "core" || (goalBackend == null && OrbManagedMachines.isAutoManagedTarget(nodeID))) return
        val fleet = loadFleet()
        warning(fleet, nodeID)?.let { throw OrbError(it) }
        if (goalBackend != null && !OrbRemoteGoal.supports(fleet, goalBackend)) throw OrbError(OrbRemoteGoal.UNSUPPORTED)
    }
}
