package sh.sandboxed.dashboard.orb

import java.security.MessageDigest
import java.util.Base64

// Cache identity only. Authentication remains entirely server-owned.
fun inboxAccountScope(endpoint: String, token: String?): String {
    val bearer = token.orEmpty()
    val parts = bearer.split('.')
    val claims = if (parts.size == 3) runCatching { OrbJSON.dict(OrbJSON.parse(Base64.getUrlDecoder().decode(parts[1]))) }.getOrNull() else null
    val subject = (claims?.get("sub") ?: claims?.get("user_id"))?.toString()?.takeIf { it.isNotBlank() }
    val identity = if (subject != null) "subject:$subject" else if (bearer.isEmpty()) "anonymous" else "opaque:" + MessageDigest.getInstance("SHA-256").digest(bearer.toByteArray()).joinToString("") { "%02x".format(it) }
    return endpoint.trimEnd('/') + ":" + identity
}
