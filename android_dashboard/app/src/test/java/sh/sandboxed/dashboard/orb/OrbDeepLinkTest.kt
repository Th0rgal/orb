package sh.sandboxed.dashboard.orb

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class OrbDeepLinkTest {
    @Test
    fun inboxVariants() {
        assertEquals(OrbDeepLink.Inbox(null, true, false), OrbDeepLink.parse("orb://inbox"))
        assertEquals(OrbDeepLink.Inbox("m1", true, false), OrbDeepLink.parse("orb://inbox/m1"))
        assertEquals(OrbDeepLink.Inbox("m2", false, true), OrbDeepLink.parse("sandboxed://inbox?mission=m2&peek=0&reply=true"))
        assertEquals(OrbDeepLink.Inbox("m3", true, false), OrbDeepLink.parse("orb://INBOX?id=m3"))
    }

    @Test
    fun targets() {
        assertEquals(OrbDeepLink.Settings, OrbDeepLink.parse("orb://settings"))
        assertEquals(OrbDeepLink.Project("orb"), OrbDeepLink.parse("orb://projects/orb"))
        assertEquals(OrbDeepLink.Mission("abc"), OrbDeepLink.parse("orb://mission/abc"))
        assertEquals(OrbDeepLink.Documents("my proj"), OrbDeepLink.parse("orb://context/my%20proj"))
    }

    @Test
    fun rejectsUnknownOrIncomplete() {
        assertNull(OrbDeepLink.parse(null))
        assertNull(OrbDeepLink.parse("https://example.com/inbox"))
        assertNull(OrbDeepLink.parse("orb://project"))
        assertNull(OrbDeepLink.parse("orb://nope/x"))
        assertNull(OrbDeepLink.parse("orb://bad uri"))
    }

    @Test
    fun githubCallback() {
        assertEquals(OrbDeepLink.GitHubCallback("jwt.a.b", null), OrbDeepLink.parse("sandboxed://auth/callback?token=jwt.a.b&exp=1"))
        assertEquals(OrbDeepLink.GitHubCallback(null, "denied"), OrbDeepLink.parse("sandboxed://auth/callback?error=denied"))
        assertEquals(OrbDeepLink.GitHubCallback("jwt", null, "s_t-1"), OrbDeepLink.parse("sandboxed://auth/callback?token=jwt&exp=1&state=s_t-1"))
        assertNull(OrbDeepLink.parse("orb://auth/callback?token=x"))
    }
}
