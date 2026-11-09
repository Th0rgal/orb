package sh.sandboxed.dashboard.orb

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class OrbChangesTest {
    @Test
    fun claudePermissionModesParseAndLabel() {
        assertEquals(OrbClaudePermissionMode.Supervised, OrbClaudePermissionMode.parse(null))
        assertEquals(OrbClaudePermissionMode.Supervised, OrbClaudePermissionMode.parse("supervised"))
        assertEquals(OrbClaudePermissionMode.AcceptEdits, OrbClaudePermissionMode.parse("acceptEdits"))
        assertEquals(OrbClaudePermissionMode.AcceptEdits, OrbClaudePermissionMode.parse("accept_edits"))
        assertEquals(OrbClaudePermissionMode.Auto, OrbClaudePermissionMode.parse("auto"))
        assertEquals(OrbClaudePermissionMode.BypassPermissions, OrbClaudePermissionMode.parse("bypassPermissions"))
        assertEquals(OrbClaudePermissionMode.BypassPermissions, OrbClaudePermissionMode.parse("bypass_permissions"))
        assertEquals("Auto-edit", OrbClaudePermissionMode.AcceptEdits.label)
        assertEquals("Full access", OrbClaudePermissionMode.BypassPermissions.label)
    }

    @Test
    fun worktreeModesParse() {
        assertEquals(OrbWorktreeLaunchMode.Auto, OrbWorktreeLaunchMode.parse(null))
        assertEquals(OrbWorktreeLaunchMode.Worktree, OrbWorktreeLaunchMode.parse("worktree"))
        assertEquals(OrbWorktreeLaunchMode.Local, OrbWorktreeLaunchMode.parse("local"))
    }

    @Test
    fun unifiedDiffParserExtractsMultiFileHunksAndLineNumbers() {
        val sample = """
            diff --git a/src/hello.ts b/src/hello.ts
            index 1111111..2222222 100644
            --- a/src/hello.ts
            +++ b/src/hello.ts
            @@ -1,3 +1,4 @@
             export function greet() {
            -  return "hi";
            +  const msg = "hello world";
            +  return msg;
             }
            diff --git a/src/added.ts b/src/added.ts
            new file mode 100644
            index 0000000..3333333
            --- /dev/null
            +++ b/src/added.ts
            @@ -0,0 +1,2 @@
            +export const VERSION = 2;
            +export const READY = true;
        """.trimIndent()

        val files = OrbUnifiedDiffParser.parse(sample)
        assertEquals(2, files.size)

        assertEquals("src/hello.ts", files[0].path)
        assertEquals("M", files[0].status)
        assertEquals(2, files[0].additions)
        assertEquals(1, files[0].deletions)
        assertEquals(1, files[0].hunks.size)
        assertEquals(5, files[0].hunks[0].lines.size)
        assertEquals(OrbDiffLineKind.Context, files[0].hunks[0].lines[0].kind)
        assertEquals(OrbDiffLineKind.Del, files[0].hunks[0].lines[1].kind)
        assertEquals(2, files[0].hunks[0].lines[1].oldLine)
        assertNull(files[0].hunks[0].lines[1].newLine)
        assertEquals(OrbDiffLineKind.Add, files[0].hunks[0].lines[2].kind)
        assertEquals(2, files[0].hunks[0].lines[2].newLine)

        assertEquals("src/added.ts", files[1].path)
        assertEquals("A", files[1].status)
        assertEquals(2, files[1].additions)
        assertEquals(0, files[1].deletions)
    }

    @Test
    fun nativePermissionRequestExposesAllowForSession() {
        val ev = OrbRow(
            "ev-1",
            mapOf(
                "type" to "tool_call",
                "tool_name" to "ui_native_request",
                "tool_call_id" to "call-42",
                "content" to """{"id":"req-1","method":"permission","params":{"tool":"Bash","input":{"command":"git status","description":"Check git status"}}}"""
            )
        )
        val q = OrbQuestionExtractor.nativeReviewRequest(ev, "tool_call")
        assertEquals(listOf("Allow once", "Allow for session", "Decline"), q?.options)
        assertEquals("git status", q?.command)
    }

    @Test
    fun checkpointMetaParsesCanonicalAndAliasFields() {
        val cp = OrbCheckpointMeta.fromDict(
            mapOf(
                "ref" to "refs/orb/checkpoints/m1/0001-post-1",
                "commit_sha" to "abcdef123456",
                "turn_index" to 1
            )
        )
        assertEquals("refs/orb/checkpoints/m1/0001-post-1", cp?.ref)
        assertEquals("abcdef123456", cp?.oid)
        assertEquals(1, cp?.turn)
    }
}
