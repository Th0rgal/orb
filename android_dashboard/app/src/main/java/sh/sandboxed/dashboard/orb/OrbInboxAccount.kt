package sh.sandboxed.dashboard.orb

import java.security.MessageDigest
import java.util.Base64

// Cache identity only. Authentication remains entirely server-owned.
fun inboxAccountScope(endpoint: String, token: String?): String {
    val bearer = token.orEmpty()
    val subject = tokenSubject(bearer)
    val identity = if (subject != null) "subject:$subject" else if (bearer.isEmpty()) "anonymous" else "opaque:" + MessageDigest.getInstance("SHA-256").digest(bearer.toByteArray()).joinToString("") { "%02x".format(it) }
    return endpoint.trimEnd('/') + ":" + identity
}

/** `sub` / `user_id` claim of a JWT bearer, or null for opaque tokens. Never verifies anything. */
fun tokenSubject(token: String?): String? {
    val parts = token.orEmpty().split('.')
    if (parts.size != 3) return null
    val claims = try {
        OrbJSON.dict(OrbJSON.parse(Base64.getUrlDecoder().decode(parts[1])))
    } catch (_: IllegalArgumentException) {
        null // not base64url: treat as an opaque token
    }
    return (claims?.get("sub") ?: claims?.get("user_id"))?.toString()?.takeIf { it.isNotBlank() }
}
