package sh.sandboxed.dashboard.orb

/** Conversation messages reconcile together; raw tails never own older history. */
object OrbConversationHistory {
    val eventTypes = setOf("user_message", "assistant_message", "assistant_message_canonical")
    fun forMission(rows: List<OrbRow>, missionId: String): List<OrbRow> =
        rows.filter { it.str("mission_id") == missionId }

    fun merge(history: List<OrbRow>, events: List<OrbRow>): List<OrbRow> {
        val missions = (history + events).mapNotNull { it.str("mission_id") }.distinct()
        if (missions.size > 1 && history.any { it.str("mission_id") == null }) return history
        if (missions.size > 1) return missions.flatMap { mission ->
            merge(history.filter { it.str("mission_id") == mission }, events.filter { it.str("mission_id") == mission })
        }
        val incoming = events.sortedBy { it.int("sequence", "seq") ?: 0 }.mapNotNull { event ->
            val type = event.str("event_type", "type")
            val content = event.str("content") ?: ""
            val metadata = event.dict("metadata") ?: emptyMap()
            if (type !in eventTypes || content.isEmpty() || metadata["queued"] == true || metadata["success"] == false) null
            else OrbRow(event.id, event.raw + mapOf("role" to if (type == "user_message") "user" else "assistant", "content" to content) +
                (event.int("sequence", "seq")?.let { mapOf("sequence" to it) } ?: emptyMap()))
        }
        if (history.isEmpty()) return incoming
        if (history.all { it.int("sequence") != null } && incoming.all { it.int("sequence") != null }) {
            val first = history.minOf { it.int("sequence")!! }
            return (history + incoming.filter { it.int("sequence")!! >= first }).associateBy { it.int("sequence") }.values.sortedBy { it.int("sequence") }
        }
        fun key(row: OrbRow) = (row.str("role") ?: "") + "\u0000" + (row.str("content") ?: "").trim()
        val known = history.map(::key).toSet()
        val anchor = incoming.indexOfLast { key(it) in known }
        return if (anchor < 0) history else history + incoming.drop(anchor + 1)
    }
}
