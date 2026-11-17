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
}
