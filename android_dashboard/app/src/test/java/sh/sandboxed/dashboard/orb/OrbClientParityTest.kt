package sh.sandboxed.dashboard.orb

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.security.MessageDigest

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
        assertEquals(1, OrbBackupArchive.effectiveCleanupDays(null))
        assertEquals(1, OrbBackupArchive.effectiveCleanupDays(0))
        assertEquals(14, OrbBackupArchive.effectiveCleanupDays(14))
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
    fun projectBoardSharedFixture() {
        val cases = OrbJSON.dictList(OrbSpec.dict("fixtures/project-board.json")["cases"])
        assertEquals(listOf("no board", "board", "missing fields"), cases.map { it["name"] })
        for (item in cases) {
            val project = OrbProjectBoard.decode(OrbJSON.dict(item["project"]))
            val board = OrbProjectBoard.decode(OrbJSON.dict(item["board"]))
            assertEquals(project.controllerMissionID, board.controllerMissionID)
            assertEquals(project.boardUpdatedAt, board.updatedAt)
            assertEquals(project.controllerMissionID, OrbJSON.dict(item["controller_update"])?.get("mission_id"))
            when (item["name"]) {
                "no board" -> {
                    assertEquals("", board.text)
                    assertNull(board.updatedByMissionID)
                    assertNull(board.controllerMissionID)
                }
                "board" -> {
                    assertEquals("# Project board\nShip iOS and Android together.\n", board.text)
                    assertEquals("2026-11-15T10:00:00Z", board.updatedAt)
                    assertEquals("writer-2", board.updatedByMissionID)
                    assertEquals("controller-1", board.controllerMissionID)
                }
                "missing fields" -> {
                    assertNull(board.text)
                    assertNull(board.updatedAt)
                    assertNull(board.updatedByMissionID)
                    assertNull(project.controllerMissionID)
                }
                else -> error("Unknown fixture case")
            }
        }
    }

    @Test
    fun missionBoardSharedFixtureAndProjectionRules() {
        val raw = OrbSpec.dict("fixtures/mission-board.json")
        val project = OrbJSON.dict(raw["project"])!!
        val mission = OrbJSON.dict(raw["mission"])!!
        val board = OrbMissionBoardSummary.decode(OrbJSON.dictList(project["boards"])[0])
        assertEquals("m1", board.id)
        assertEquals(listOf("m1"), OrbMissionBoardProjection.summaries(project).map { it.id })
        assertFalse(OrbMissionBoardProjection.shouldShowEntry(OrbProjectBoard.decode(mapOf("text" to " \n"))))
        assertTrue(OrbMissionBoardProjection.accepts(mission, "m1", "notes", 1, "notes", 1))
        assertFalse(OrbMissionBoardProjection.accepts(mission, "m1", "old", 1, "notes", 1))
        val equal = mapOf("boards" to listOf(mapOf("mission_id" to "b", "updated_at" to "same"), mapOf("mission_id" to "a", "updated_at" to "same")))
        assertEquals(listOf("a", "b"), OrbMissionBoardProjection.summaries(equal).map { it.id })
    }

    @Test
    fun projectLimitNormalization() {
        assertEquals(0, OrbProjectGrant.parseProjectLimit("").getOrNull())
        assertEquals(4, OrbProjectGrant.parseProjectLimit(" 4 ").getOrNull())
        assertTrue(OrbProjectGrant.parseProjectLimit("-1").isFailure)
        assertNull(OrbProjectGrant.projectLimitOf(mapOf("parallel_missions" to 0)))
        assertEquals(3, OrbProjectGrant.projectLimitOf(mapOf("parallel_missions" to 3)))
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
        assertTrue(OrbAdminFormatting.sameLibraryRemote("git@github.com:Org/Skills.git/", "git@github.com:org/skills"))
        assertFalse(OrbAdminFormatting.needsLibraryRemoteInit(null, "git@github.com:org/skills.git", null))
        assertFalse(OrbAdminFormatting.needsLibraryRemoteInit("git@github.com:org/skills.git", "git@github.com:org/skills", null))
        assertTrue(OrbAdminFormatting.needsLibraryRemoteInit("git@github.com:org/new.git", "git@github.com:org/old.git", null))
        assertTrue(OrbAdminFormatting.needsLibraryRemoteInit("git@github.com:org/new.git", "git@github.com:org/new.git", "git@github.com:org/new.git"))
    }

    @Test
    fun customProviderPacingSubtitleAndCapValidation() {
        val provider = OrbRow(
            mapOf(
                "id" to "eth-1",
                "provider_type" to "custom",
                "name" to "Ethereum Foundation",
                "enabled" to true,
                "status" to mapOf("type" to "connected"),
                "rpm_limit" to 300,
                "max_concurrency" to 8
            )
        )
        assertEquals(
            "custom · connected · 300 RPM · 8 concurrent",
            providerStatusSubtitle(provider, null)
        )
        assertEquals(true to null, parseOptionalProviderCap("  ", 1, 100_000))
        assertEquals(true to 300, parseOptionalProviderCap("300", 1, 100_000))
        assertEquals(false to null, parseOptionalProviderCap("0", 1, 100_000))
        assertEquals(false to null, parseOptionalProviderCap("100001", 1, 100_000))
        assertTrue(isValidHttpUrl("https://inference.ethereum.foundation/v1"))
        assertFalse(isValidHttpUrl("ftp://inference.ethereum.foundation/v1"))
    }
}
