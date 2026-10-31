package sh.sandboxed.dashboard.orb

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class OrbAgentSoftwareTest {
    private fun sampleComponent(
        id: String = "vibe",
        installed: Boolean = true,
        version: String? = "2.19.1",
        path: String? = "/usr/local/bin/vibe-acp",
        updateSupported: Boolean = true,
        latest: String? = "2.19.1",
        ready: Boolean? = true,
        readyDetail: String? = "Authenticated via Core Mistral proxy."
    ) = OrbSoftwareComponent(
        id = id,
        name = id,
        version = version,
        path = path,
        installed = installed,
        owner = "Fleet installer",
        updateSupported = updateSupported,
        latest = latest,
        releaseError = null,
        instructions = "",
        ready = ready,
        readyDetail = readyDetail
    )

    @Test
    fun freshFleetInstallableAndSummaryParityWithDesktopAndIos() {
        val missing = sampleComponent(
            installed = false,
            version = null,
            path = null,
            updateSupported = true,
            latest = "2.19.1",
            ready = false
        )
        assertTrue(OrbAgentSoftware.canInstallSoftware(missing))
        assertFalse(OrbAgentSoftware.canUpdateSoftware(missing))

        val job = OrbSoftwareJob(
            id = "j1",
            component = "vibe",
            version = "2.19.1",
            path = "/usr/local/bin/vibe-acp",
            state = "queued",
            error = null
        )
        assertTrue(OrbAgentSoftware.matchesSoftwareJob(job, missing))

        val machines = listOf(
            OrbSoftwareMachine(
                id = "dgx-spark-admin",
                name = "dgx-spark-admin",
                online = true,
                inventory = OrbSoftwareInventory(
                    checkedAt = 1.0,
                    components = listOf(
                        sampleComponent(id = "codex", version = "codex-cli 1.9.0", latest = "1.10.0"),
                        sampleComponent(id = "grok", ready = false, readyDetail = "Missing Grok profile")
                    ),
                    runtime = OrbSoftwareRuntime(
                        name = "Node runner",
                        version = "0.13.0",
                        build = "test",
                        path = "/usr/local/bin/sandboxed-node",
                        restartRequired = true
                    ),
                    jobs = emptyList()
                )
            ),
            OrbSoftwareMachine(
                id = "nimrud",
                name = "nimrud",
                online = true,
                inventory = OrbSoftwareInventory(
                    checkedAt = 1.0,
                    components = listOf(missing),
                    runtime = OrbSoftwareRuntime(
                        name = "Node runner",
                        version = "0.13.0",
                        build = "test",
                        path = "/usr/local/bin/sandboxed-node",
                        restartRequired = false
                    ),
                    jobs = emptyList()
                )
            )
        )

        assertEquals(
            "1 restart needed · 1 missing · 1 setup needed · 1 update",
            OrbAgentSoftware.softwareAttentionSummary(machines)
        )
        assertEquals(2, OrbAgentSoftware.availableSoftwareUpdates(machines).size)
    }
}
