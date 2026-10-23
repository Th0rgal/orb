package sh.sandboxed.dashboard.orb

/** The ordered stream a turn is made of, reduced to what narration folding needs
 * (mirrors desktop `StreamItem` kinds in orb/src/transcriptModel.ts). */
sealed class OrbStreamItem(open val key: String) {
    data class User(override val key: String) : OrbStreamItem(key)
    data class Think(override val key: String) : OrbStreamItem(key)
    /** [cumulative]: the producer's one bubble for a whole response
     * (text_delta_latest), across tool boundaries: it holds the answer, never only narration. */
    data class Text(override val key: String, val text: String, val cumulative: Boolean = false) : OrbStreamItem(key)
    data class Tool(override val key: String, val name: String) : OrbStreamItem(key)
    data class Other(override val key: String) : OrbStreamItem(key)
}

object OrbNarration {
    /** Orchestration tools (start_mission, spawn_managed_machine…) stand alone and do not
     * count as work (desktop `isOrchestrationTool`). */
    fun isOrchestrationTool(name: String): Boolean {
        var n = name.trim().lowercase()
        if (n.startsWith("mcp__") && n.lastIndexOf("__") > 3) n = n.substring(n.lastIndexOf("__") + 2)
        n = n.substring(n.lastIndexOf('.') + 1)
        n = n.substring(n.lastIndexOf(':') + 1)
        n = n.replace(Regex("^(?:mcp_)?(?:sandboxed|orchestrator|paloma)(?:[_-](?:sh|assistant|orchestrator))*[_-]"), "")
        return n in setOf("start_mission", "create_mission", "spawn_worker", "spawn_managed_machine", "destroy_managed_machine")
    }

    /** Narration: assistant text written between tool calls of one turn. Returns the keys of
     * texts that have a later work tool in the same turn and either join a fold that already
     * holds a tool or are followed (through thoughts and more text) by one. Same rule as
     * desktop `narrationKeys` in orb/src/workModel.ts. */
    fun narrationKeys(items: List<OrbStreamItem>, standalone: (String) -> Boolean = ::isOrchestrationTool): Set<String> {
        val keys = mutableSetOf<String>()
        fun isWorkTool(item: OrbStreamItem) = item is OrbStreamItem.Tool && !standalone(item.name)
        val toolAhead = BooleanArray(items.size)
        val nextIsTool = BooleanArray(items.size)
        var ahead = false
        var next = false
        for (i in items.indices.reversed()) {
            toolAhead[i] = ahead; nextIsTool[i] = next
            val item = items[i]
            when {
                item is OrbStreamItem.User -> { ahead = false; next = false }
                isWorkTool(item) -> { ahead = true; next = true }
                item !is OrbStreamItem.Text && item !is OrbStreamItem.Think -> next = false
            }
        }
        var foldHasTool = false
        for (i in items.indices) {
            val item = items[i]
            val itemKind = when {
                item is OrbStreamItem.User -> 0
                item is OrbStreamItem.Think -> 1
                item is OrbStreamItem.Text -> 2
                isWorkTool(item) -> 3
                item is OrbStreamItem.Tool -> 4
                else -> 5
            }
            val isCumulative = item is OrbStreamItem.Text && item.cumulative
            val isNonEmpty = item is OrbStreamItem.Text && item.text.isNotBlank()
            val verdict = OrbKernel.workfoldStep(
                itemKind = itemKind,
                isCumulative = isCumulative,
                isNonEmpty = isNonEmpty,
                toolAhead = toolAhead[i],
                nextIsTool = nextIsTool[i],
                foldHasTool = foldHasTool
            )
            if (item is OrbStreamItem.Text && verdict.foldItem) {
                keys.add(item.key)
            }
            foldHasTool = verdict.foldHasToolNext
        }
        return keys
    }

    /** One line of narration for a fold header: Markdown markers stripped, whitespace collapsed. */
    fun narrationLine(text: String): String =
        text.replace(Regex("```[\\s\\S]*?(```|$)"), " ")
            .replace(Regex("[*_`#>]+"), "")
            .replace(Regex("\\s+"), " ")
            .trim()
}
