package sh.sandboxed.dashboard.orb

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class OrbFidoTrustTest {
    private var now = 1_000_000L
    private val trust = OrbFidoTrust { now }
    private fun req(fp: String = "SHA256:k", host: String? = "github.com", origin: String = "ssh:") =
        OrbFidoRequest("r", "ed25519-sk", fp, origin, host, null, "")

    @Test
    fun offByDefaultEveryRequestAsks() {
        trust.recordBiometricApproval(req())
        assertFalse(trust.isTrusted(req()))
    }

    @Test
    fun trustsSameKeyAndHostOnlyWithinWindow() {
        trust.minutes = 5
        assertFalse(trust.isTrusted(req()))
        trust.recordBiometricApproval(req())
        assertTrue(trust.isTrusted(req(host = "GitHub.com")))
        assertFalse(trust.isTrusted(req(host = "gitlab.com")))
        assertFalse(trust.isTrusted(req(fp = "SHA256:other")))
        now += 5 * 60_000L - 1
        assertTrue(trust.isTrusted(req()))
        now += 1
        assertFalse(trust.isTrusted(req()))
    }

    @Test
    fun changingSettingOrClearingDropsTrust() {
        trust.minutes = 15
        trust.recordBiometricApproval(req())
        trust.minutes = 30
        assertFalse(trust.isTrusted(req()))
        trust.recordBiometricApproval(req())
        trust.clear()
        assertFalse(trust.isTrusted(req()))
    }

    @Test
    fun requestsWithoutKeyOrHostAreNeverTrusted() {
        trust.minutes = 5
        trust.recordBiometricApproval(req(fp = ""))
        assertFalse(trust.isTrusted(req(fp = "")))
        trust.recordBiometricApproval(req(host = null, origin = ""))
        assertFalse(trust.isTrusted(req(host = null, origin = "")))
    }
}
