package sh.sandboxed.dashboard.orb

/**
 * Mirrors iOS `OrbMessageImages` and Orb `messageImages.ts`: `[Image #n] [Uploaded: /path.png]`
 * transport markers become thumbnails; the visible text keeps only the `[Image #n]` reference.
 */
data class OrbMessageImages(
    val text: String,
    val paths: List<String>,
    val references: List<Int>
) {
    companion object {
        private val pattern = Regex("""(?:\[Image #(\d+)\][ \t]*)?\[Uploaded: ([^\]\r\n]+)\]""", RegexOption.IGNORE_CASE)
        private val inlinePattern = Regex("""^data:image/(?:png|jpeg|webp|gif);base64,[A-Za-z0-9+/]+=*$""", RegexOption.IGNORE_CASE)
        private val pathPrefix = Regex("""^(?:/|~/|\.\.?/)""")
        private val imageExt = Regex("""\.(?:png|jpe?g|webp|gif)$""", RegexOption.IGNORE_CASE)

        fun isInline(path: String): Boolean = inlinePattern.matches(path)

        fun parse(source: String): OrbMessageImages {
            val paths = mutableListOf<String>()
            val references = mutableListOf<Int>()
            val out = StringBuilder()
            var last = 0
            for (match in pattern.findAll(source)) {
                val marker = match.value
                val path = match.groupValues[2]
                val label = match.groups[1]?.value?.toIntOrNull()
                val start = match.range.first
                out.append(source, last, start)
                last = match.range.last + 1
                val accepted = isInline(path) || (pathPrefix.containsMatchIn(path) && imageExt.containsMatchIn(path))
                if (!accepted) {
                    out.append(marker)
                    continue
                }
                var index = paths.indexOf(path)
                if (index < 0) {
                    index = paths.size
                    paths.add(path)
                    references.add(label ?: paths.size)
                }
                val lineStart = source.lastIndexOf('\n', start - 1).let { if (it < 0) 0 else it + 1 }
                val before = if (start > lineStart) source.substring(lineStart, start) else ""
                val lineEnd = source.indexOf('\n', last).let { if (it < 0) source.length else it }
                val after = source.substring(last, lineEnd)
                val ownLine = before.isBlank() && after.isBlank()
                if (!ownLine) {
                    out.append(if (label != null) "[Image #${references[index]}]" else "#${references[index]}")
                }
            }
            out.append(source.substring(last))
            if (paths.isEmpty()) return OrbMessageImages(source, emptyList(), emptyList())
            val collapsed = out.toString().replace(Regex("\n{3,}"), "\n\n").trim()
            return OrbMessageImages(collapsed, paths, references)
        }
    }

    /** Image refs for [OrbImageStrip]; mission-scoped download first, plain path as fallback. */
    fun refs(core: OrbCore, missionId: String?): List<OrbImageAttachmentRef> = paths.mapIndexed { idx, path ->
        val url = when {
            isInline(path) -> path
            missionId != null ->
                "/api/fs/download?path=${core.encodeComponent(path)}&mission_id=${core.encodeComponent(missionId)}"
            else -> null
        }
        OrbImageAttachmentRef(
            id = "msg-img-$idx-${path.hashCode()}",
            filename = "#${references[idx]}",
            path = path,
            url = url
        )
    }
}
