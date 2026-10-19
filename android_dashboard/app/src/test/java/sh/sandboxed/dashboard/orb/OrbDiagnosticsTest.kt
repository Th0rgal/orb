package sh.sandboxed.dashboard.orb

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class OrbDiagnosticsTest {
    @Test
    fun readsCoreVersionFromHealth() {
        assertEquals("0.42.1", OrbDiagnostics.backendVersion(OrbJSON.parse("""{"status":"ok","version":"0.42.1"}""")))
        assertNull(OrbDiagnostics.backendVersion(OrbJSON.parse("""{"status":"ok"}""")))
        assertNull(OrbDiagnostics.backendVersion(OrbJSON.parse("""{"version":"  "}""")))
        assertNull(OrbDiagnostics.backendVersion(null))
    }
}
