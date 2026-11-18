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
