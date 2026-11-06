package sh.sandboxed.dashboard.orb

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.security.MessageDigest
import java.time.Instant
import java.time.ZoneOffset

class OrbClientParityTest {
    @Test
    fun backupMultipartSha256MatchesExactBodyBytesAndCleanupBounds() {
        val zip = byteArrayOf(0x50, 0x4B, 0x03, 0x04, 0x11, 0x22)
        val payload = OrbBackupArchive.buildRestoreMultipart(
            zipBytes = zip,
            filename = "backup.zip",
            boundary = "OrbTestBoundary"
        )
        assertEquals("multipart/form-data; boundary=OrbTestBoundary", payload.contentType)
        val expectedSha = MessageDigest.getInstance("SHA-256")
            .digest(payload.body)
            .joinToString("") { "%02x".format(it) }
        assertEquals(expectedSha, payload.sha256Hex)
        val text = payload.body.decodeToString()
        assertTrue(text.contains("name=\"backup\"; filename=\"backup.zip\""))

        assertEquals(14, OrbBackupArchive.parseCleanupDays("14").getOrNull())
        assertTrue(OrbBackupArchive.parseCleanupDays("0").isFailure)
        assertTrue(OrbBackupArchive.parseCleanupDays("366").isFailure)
        assertTrue(OrbBackupArchive.parseCleanupDays("abc").isFailure)

        val emptyArchive = OrbBackupArchive.interpretRestoreResponse(
            mapOf(
                "success" to false,
                "message" to "No recognized files in backup archive",
                "restored_files" to emptyList<String>(),
                "errors" to emptyList<String>()
            )
        )
        assertFalse(emptyArchive.first)
        assertEquals("No recognized files in backup archive", emptyArchive.second)

        val okArchive = OrbBackupArchive.interpretRestoreResponse(
            mapOf(
                "success" to true,
                "message" to "",
                "restored_files" to listOf("settings.json", "providers.json"),
                "errors" to emptyList<String>()
            )
        )
        assertTrue(okArchive.first)
        assertEquals("Restored 2 files (settings.json, providers.json).", okArchive.second)
    }

    @Test
    fun controllerModelScheduleTimelineAndGrantNormalization() {
        assertEquals("0 9 * * *", OrbControllerModel.scheduleExpression("0 9 * * *"))
        assertEquals(
            "every 2h",
            OrbControllerModel.scheduleExpression(mapOf("kind" to "interval", "minutes" to 120))
        )
        assertEquals(
            "*/15 * * * *",
            OrbControllerModel.scheduleExpression(mapOf("kind" to "cron", "expr" to "*/15 * * * *"))
        )

        val patched = OrbControllerModel.hermesPatch(
            patch = mapOf("name" to "nightly", "continuity" to true),
            existingJob = mapOf("context_from" to listOf("other-job", "self"))
        )
        assertEquals(listOf("other-job", "self"), patched["context_from"])

        val disabledPatch = OrbControllerModel.hermesPatch(
            patch = mapOf("name" to "nightly", "continuity" to false),
            existingJob = mapOf("context_from" to listOf("other-job", "self"))
        )
        assertEquals(listOf("other-job"), disabledPatch["context_from"])

        val nowMs = 1_762_000_000_000L
        fun isoAt(offsetSecs: Long) = Instant.ofEpochMilli(nowMs + offsetSecs * 1_000L).toString()
        val runs = listOf(
            mapOf("id" to "r4", "at" to isoAt(-60), "silent" to true),
            mapOf("id" to "r3", "at" to isoAt(-120), "silent" to true),
            mapOf("id" to "r2", "at" to isoAt(-180), "status" to "failed", "error" to "boom"),
            mapOf("id" to "r1", "at" to isoAt(-240), "status" to "failed", "error" to "boom")
        )
        val entries = OrbControllerModel.buildEntries(runs = runs, nowMs = nowMs, zone = ZoneOffset.UTC)
        assertEquals(3, entries.size)
        assertTrue(entries[0] is OrbControllerModel.TimelineEntry.Day)
        val silent = entries[1] as OrbControllerModel.TimelineEntry.Silent
        assertEquals(2, silent.runs.size)
        val failed = entries[2] as OrbControllerModel.TimelineEntry.Failed
        assertEquals(2, failed.runs.size)
        assertEquals("boom", failed.error)

        assertEquals(0, OrbControllerModel.parseProjectLimit("").getOrNull())
        assertEquals(4, OrbControllerModel.parseProjectLimit(" 4 ").getOrNull())
        assertTrue(OrbControllerModel.parseProjectLimit("-1").isFailure)
        assertNull(OrbControllerModel.projectLimitOf(mapOf("parallel_missions" to 0)))
        assertEquals(3, OrbControllerModel.projectLimitOf(mapOf("parallel_missions" to 3)))

        assertEquals(
            listOf("project-notes"),
            OrbControllerModel.skillsOf(mapOf("skill" to "project-notes"), null)
        )
        assertEquals(
            emptyList<String>(),
            OrbControllerModel.skillsOf(mapOf("skills" to emptyList<String>(), "skill" to "stale-skill"), null)
        )

        val scriptView: OrbDict = mapOf(
            "job" to mapOf(
                "id" to "job-1",
                "name" to "script controller",
                "schedule" to "every 30m"
            ),
            "settings" to mapOf(
                "script" to "scripts/check.py",
                "prompt" to "",
                "skills" to listOf("ops"),
                "deliver" to "project:demo",
                "model" to "",
                "reasoning_effort" to "",
                "continuity" to false
            )
        )
        val scheduleOnlyPatch = OrbControllerModel.buildCronPatch(
            existingView = scriptView,
            defaultDeliver = "project:demo",
            name = "script controller",
            schedule = "every 15m",
            prompt = "",
            skills = listOf("ops"),
            deliver = "project:demo",
            model = "",
            reasoningEffort = "",
            continuity = false
        )
        assertEquals(mapOf<String, Any?>("schedule" to "every 15m"), scheduleOnlyPatch)
        assertFalse(scheduleOnlyPatch.containsKey("prompt"))

        val unchangedPatch = OrbControllerModel.buildCronPatch(
            existingView = scriptView,
            defaultDeliver = "project:demo",
            name = "script controller",
            schedule = "every 30m",
            prompt = "",
            skills = listOf("ops"),
            deliver = "project:demo",
            model = "",
            reasoningEffort = "",
            continuity = false
        )
        assertTrue(unchangedPatch.isEmpty())
        assertEquals(
            "Steer saved, but the controller could not start: scheduler offline. Use Run now to retry.",
            OrbControllerModel.steerRunFailureMessage("scheduler offline")
        )
    }

    @Test
    fun libraryErrorClassificationMatchesCoreStatusCodes() {
        assertTrue(OrbAdminFormatting.isUnconfiguredError(OrbError("Library not configured", status = 503)))
        assertFalse(OrbAdminFormatting.isUnconfiguredError(OrbError("Boom", status = 500)))
        assertTrue(
            OrbAdminFormatting.isDivergedError(
                OrbError("Conflict", status = 409, body = """{"error":"DIVERGED_HISTORY"}""")
            )
        )
        assertFalse(OrbAdminFormatting.isDivergedError(OrbError("Conflict", status = 409, body = """{"error":"OTHER"}""")))
        assertNull(OrbAdminFormatting.libraryRemoteUpdateError(mapOf("library_reinitialized" to true)))
        assertEquals(
            "Failed to clone git@github.com:org/private.git",
            OrbAdminFormatting.libraryRemoteUpdateError(
                mapOf(
                    "library_reinitialized" to false,
                    "library_error" to "Failed to clone git@github.com:org/private.git"
                )
            )
        )
    }
}
