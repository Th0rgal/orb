package sh.sandboxed.dashboard.orb

import java.net.URI
import java.net.URLDecoder

/** What an `orb://` / `sandboxed://` link asks for. Pure: parsed with java.net.URI so it is JVM-testable. */
sealed class OrbDeepLink {
    data class Inbox(val missionId: String?, val expandPeek: Boolean, val openReply: Boolean) : OrbDeepLink()
    data object Settings : OrbDeepLink()
    data class Project(val slug: String) : OrbDeepLink()
    data class Mission(val id: String) : OrbDeepLink()
    data class Documents(val slug: String) : OrbDeepLink()
    data class GitHubCallback(val token: String?, val error: String?, val state: String? = null) : OrbDeepLink()

    companion object {
        fun parse(raw: String?): OrbDeepLink? {
            val uri = try {
                URI(raw?.trim() ?: return null)
            } catch (_: java.net.URISyntaxException) {
                return null
            }
            val scheme = uri.scheme?.lowercase() ?: return null
            if (scheme != "orb" && scheme != "sandboxed") return null
            val host = uri.host?.lowercase() ?: uri.authority?.lowercase() ?: ""
            val segments = (uri.rawPath ?: "").split('/').map { decode(it).trim() }.filter { it.isNotEmpty() }
            val query = parseQuery(uri.rawQuery)
            if (scheme == "sandboxed" && host == "auth" && uri.path == "/callback") {
                return GitHubCallback(query["token"]?.takeIf { it.isNotEmpty() }, query["error"], query["state"]?.takeIf { it.isNotEmpty() })
            }
            return when (host) {
                "inbox" -> {
                    val missionId = (segments.firstOrNull() ?: query["mission"]?.trim() ?: query["id"]?.trim())
                        ?.takeIf { it.isNotEmpty() }
                    Inbox(
                        missionId = missionId,
                        expandPeek = query["peek"]?.lowercase() !in setOf("0", "false"),
                        openReply = query["reply"]?.lowercase() in setOf("1", "true"),
                    )
                }
                "settings" -> Settings
                "project", "projects" -> segments.firstOrNull()?.let { Project(it) }
                "mission", "missions" -> segments.firstOrNull()?.let { Mission(it) }
                "documents", "context" -> segments.firstOrNull()?.let { Documents(it) }
                else -> null
            }
        }

        private fun decode(s: String): String = URLDecoder.decode(s.replace("+", "%2B"), Charsets.UTF_8)

        private fun parseQuery(raw: String?): Map<String, String> {
            if (raw.isNullOrEmpty()) return emptyMap()
            val out = LinkedHashMap<String, String>()
            for (pair in raw.split('&')) {
                if (pair.isEmpty()) continue
                val i = pair.indexOf('=')
                val k = decode(if (i < 0) pair else pair.substring(0, i))
                val v = if (i < 0) "" else URLDecoder.decode(pair.substring(i + 1), Charsets.UTF_8)
                out.putIfAbsent(k, v)
            }
            return out
        }
    }
}
