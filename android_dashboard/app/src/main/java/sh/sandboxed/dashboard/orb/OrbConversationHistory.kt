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
            else OrbRow(event.id, event.raw + mapOf("role" to if (type == "user_message") "user" else "assistant", "content" to content,
                "canonical" to (type == "assistant_message_canonical"),
                "bubble_id" to (metadata["bubble_id"] ?: "text_delta_latest"), "revision" to (metadata["revision"] ?: 0)) +
                (event.int("sequence", "seq")?.let { mapOf("sequence" to it) } ?: emptyMap()))
        }
        if (history.isEmpty()) return incoming
        if (history.all { it.int("sequence") != null } && incoming.all { it.int("sequence") != null }) {
            val first = history.minOf { it.int("sequence")!! }
            return (history + incoming.filter { it.int("sequence")!! >= first }).associateBy { it.int("sequence") }.values.sortedBy { it.int("sequence") }
        }
        fun key(row: OrbRow) = (row.str("role") ?: "") + "\u0000" + (row.str("content") ?: "").trim()
        val anchor = incoming.indexOfLast { key(it) == key(history.last()) }
        return if (anchor < 0) history else history + incoming.drop(anchor + 1)
    }
    /** Mirrors desktop canonical bubble revisions and terminal receipts; storage keeps every sequence. */
    fun visible(rows: List<OrbRow>): List<OrbRow> {
        val missions = rows.mapNotNull { it.str("mission_id") }.distinct()
        if (missions.size > 1) return missions.flatMap { mission -> visible(rows.filter { it.str("mission_id") == mission }) }
        val result = mutableListOf<OrbRow>()
        val bubbles = mutableMapOf<String, Int>()
        val native = mutableListOf<Int>()
        for (row in rows) {
            if (row.str("role") == "user") {
                bubbles.clear(); native.clear(); result.add(row); continue
            }
            val bubble = row.str("bubble_id") ?: "text_delta_latest"
            if (row.raw["canonical"] == true) {
                val index = bubbles[bubble]
                if (index != null) {
                    if ((row.int("revision") ?: 0) >= (result[index].int("revision") ?: 0)) result[index] = row
                } else {
                    bubbles[bubble] = result.size
                    if (bubble.startsWith("antigravity:") || bubble.startsWith("opencode:")) native.add(result.size)
                    result.add(row)
                }
                continue
            }
            val text = row.str("content")?.trim() ?: ""
            val receipt = native.isNotEmpty() && (text == native.joinToString("") { result[it].str("content") ?: "" }.trim() || text == result[native.last()].str("content")?.trim())
            if (!receipt) {
                val index = bubbles[bubble]
                if (index != null) result[index] = row else result.add(row)
            }
            bubbles.clear(); native.clear()
        }
        return result
    }

}
