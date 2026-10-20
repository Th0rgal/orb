package sh.sandboxed.dashboard.orb

import java.net.URI

/**
 * What the home screen shows when Orb cannot reach its server, and which way
 * out it offers. Pure logic (no Android types) so it is unit tested.
 */
data class OrbConnectionIssue(
    /** Plain-language headline, e.g. "Can't reach your Orb server". */
    val title: String,
    /** One or two sentences explaining what to do. */
    val message: String,
    /** The server URL that failed, shown verbatim so the user can spot a stale address. */
    val serverURL: String,
    /** Offer "Use default" (the saved URL is not already the default). */
    val offerUseDefault: Boolean,
    /** The saved URL is a private/LAN address while the default server answers: recommend switching. */
    val recommendDefault: Boolean,
    /** Raw error, kept for the copy button and log tail. */
    val technicalDetail: String,
    /** A device HTTP proxy ("host:port") that the failed connection went through, if any. */
    val proxy: String? = null
)

object OrbConnection {
    const val DEFAULT_BASE_URL = "https://agent-backend.thomas.md"

    fun normalize(url: String): String = url.trim().trimEnd('/')

    fun isDefault(url: String): Boolean = normalize(url).equals(DEFAULT_BASE_URL, ignoreCase = true)

    /** Host of [url] or null when it does not parse. */
    fun host(url: String): String? = try {
        val withScheme = if ("://" in url) url.trim() else "http://${url.trim()}"
        URI(withScheme).host?.trim('[', ']')?.lowercase()
    } catch (_: Exception) {
        null
    }

    /**
     * True for addresses only reachable on a local network: RFC 1918 IPv4,
     * loopback, link-local, CGNAT/Tailscale (100.64/10), IPv6 ULA/link-local,
     * and `.local` / `.lan` / `.home.arpa` / single-label names.
     */
    fun isPrivateAddress(url: String): Boolean {
        val h = host(url) ?: return false
        if (h == "localhost" || h.endsWith(".local") || h.endsWith(".lan") ||
            h.endsWith(".home.arpa") || h.endsWith(".internal")) return true
        val parts = h.split('.')
        if (parts.size == 4 && parts.all { p -> p.toIntOrNull()?.let { it in 0..255 } == true }) {
            val (a, b) = parts[0].toInt() to parts[1].toInt()
            return a == 10 || a == 127 || (a == 172 && b in 16..31) || (a == 192 && b == 168) ||
                (a == 169 && b == 254) || (a == 100 && b in 64..127)
        }
        if (':' in h) {
            return h == "::1" || h.startsWith("fc") || h.startsWith("fd") || h.startsWith("fe80")
        }
        return !h.contains('.')
    }

    /**
     * True when [error] means the server could not be reached at all (as
     * opposed to an HTTP error from a server that answered).
     */
    fun isUnreachable(error: String?): Boolean {
        val e = error?.lowercase() ?: return false
        return listOf(
            "failed to connect", "unable to resolve host", "connection refused", "timeout",
            "timed out", "no route to host", "network is unreachable", "unknownhost",
            "connect exception", "connection reset", "host unreachable", "could not connect",
            "cannot connect", "offline", "not connected to the internet", "software caused connection abort",
            "ssl handshake", "cleartext"
        ).any { it in e }
    }

    /**
     * Builds the card for a failed refresh, or null when [error] is not a
     * connection problem (those keep the generic notice).
     * [defaultReachable] is the result of probing [DEFAULT_BASE_URL]: null while unknown.
     */
    fun issue(
        serverURL: String,
        error: String?,
        defaultReachable: Boolean?,
        proxy: String? = null
    ): OrbConnectionIssue? {
        if (!isUnreachable(error)) return null
        val url = normalize(serverURL)
        // A system proxy that is down makes every server fail with the proxy's
        // address in the error; switching servers would not help.
        val proxyHost = proxy?.substringBeforeLast(':')?.trim()?.takeIf { it.isNotEmpty() }
        if (proxyHost != null && error.orEmpty().contains(proxyHost) && host(url) != proxyHost) {
            return OrbConnectionIssue(
                title = "Can't reach your Orb server",
                message = "Your phone sends web traffic through a proxy at $proxy, and that proxy isn't answering. Remove the proxy in your Wi-Fi or network settings, then try again.",
                serverURL = url,
                offerUseDefault = !isDefault(url),
                recommendDefault = false,
                technicalDetail = error.orEmpty(),
                proxy = proxy
            )
        }
        val usingDefault = isDefault(url)
        val private = isPrivateAddress(url)
        val recommend = !usingDefault && private && defaultReachable == true
        val message = when {
            recommend ->
                "This looks like a local network address and it isn't answering, but the default Orb server is online. Switch to the default server, or change the address."
            private ->
                "This is a local network address. Make sure your phone is on the same network and the server is running, or change the address."
            usingDefault ->
                "Check your internet connection and try again."
            else ->
                "Check the address and your connection, or switch to the default server."
        }
        return OrbConnectionIssue(
            title = "Can't reach your Orb server",
            message = message,
            serverURL = url,
            offerUseDefault = !usingDefault,
            recommendDefault = recommend,
            technicalDetail = error.orEmpty()
        )
    }

    /** Probe the default server only when it could change the advice. */
    fun shouldProbeDefault(serverURL: String, error: String?): Boolean =
        isUnreachable(error) && !isDefault(serverURL) && isPrivateAddress(serverURL)
}
