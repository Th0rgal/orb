package sh.sandboxed.dashboard.orb

import kotlinx.coroutines.delay

object OrbHarnessTransfer {
    fun sourceStopped(mission: Map<String, Any?>): Boolean =
        mission["status"] in setOf("awaiting_user", "blocked", "paused", "interrupted", "failed", "completed", "cancelled", "acknowledged") &&
            OrbJSON.dict(mission["execution"])?.get("state") != "running" &&
            OrbJSON.dict(mission["remote_job"])?.get("node_state") !in setOf("queued", "running")

    suspend fun stopSource(core: OrbCore, base: String) {
        fun stopped(value: Any?) = OrbJSON.dict(value)?.let(::sourceStopped) == true
        if (stopped(core.request(base))) return
        core.request("$base/cancel", method = "POST")
        repeat(20) {
            if (stopped(core.request(base))) return
            delay(500)
        }
        throw OrbError("The original agent has not stopped yet. Wait and retry the transfer.")
    }
}

/** Structured historical context, matching desktop forkContext.ts and iOS OrbForkContext. */
object OrbForkContext {
    data class Entry(val role: String, val content: String)
    data class Context(val messages: List<Entry>, val request: String?)
    fun parse(text: String): Context? {
        val preambles = listOf("Continue the work from this conversation in a fresh native session.", "The user edited a message in this conversation and sent it again.", "This conversation's native session could not be resumed, so it continues in a fresh session.")
        if (preambles.none { text.startsWith(it) }) return null
        val open = "\n<fork_context>\n"
        val close = "\n</fork_context>"
        val start = text.indexOf(open).takeIf { it >= 0 }?.plus(open.length) ?: return null
        val end = text.indexOf(close, start).takeIf { it >= 0 } ?: return null
        val rest = text.substring(end + close.length)
        val marker = "\n\nCurrent request:\n"
        if (rest.isNotEmpty() && !rest.startsWith(marker)) return null
        val value = OrbJSON.dict(OrbJSON.parse(text.substring(start, end))) ?: return null
        if (value["source_mission_id"] !is String) return null
        val raw = value["messages"] as? List<*> ?: return null
        val messages = raw.map {
            val message = OrbJSON.dict(it) ?: return null
            val role = message["role"] as? String ?: return null
            val content = message["content"] as? String ?: return null
            if (role !in setOf("user", "assistant", "context")) return null
            Entry(if (role == "context") "assistant" else role, content)
        }
        return Context(messages, if (rest.isEmpty()) null else rest.removePrefix(marker))
    }

    fun expand(row: OrbRow, depth: Int = 0): List<OrbRow> {
        if (depth > 50 || row.str("role", "sender", "author") !in setOf("user", "operator", "human")) return listOf(row)
        val context = parse(row.str("content", "text", "message") ?: "") ?: return listOf(row)
        val entries = context.messages + listOfNotNull(context.request?.let { Entry("user", it) })
        return entries.flatMapIndexed { index, entry ->
            expand(OrbRow("${row.id}:context:$index", mapOf("role" to entry.role, "content" to entry.content)), depth + 1)
        }
    }
}
