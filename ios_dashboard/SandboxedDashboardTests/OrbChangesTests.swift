import XCTest
@testable import sandboxed_sh

final class OrbChangesTests: XCTestCase {
    func testClaudePermissionModeParsingAndLabels() {
        XCTAssertEqual(OrbClaudePermissionMode.parse(nil), .supervised)
        XCTAssertEqual(OrbClaudePermissionMode.parse("supervised"), .supervised)
        XCTAssertEqual(OrbClaudePermissionMode.parse("acceptEdits"), .acceptEdits)
        XCTAssertEqual(OrbClaudePermissionMode.parse("accept_edits"), .acceptEdits)
        XCTAssertEqual(OrbClaudePermissionMode.parse("auto"), .auto)
        XCTAssertEqual(OrbClaudePermissionMode.parse("bypassPermissions"), .bypassPermissions)
        XCTAssertEqual(OrbClaudePermissionMode.parse("bypass_permissions"), .bypassPermissions)
        XCTAssertEqual(OrbClaudePermissionMode.acceptEdits.label, "Auto-edit")
        XCTAssertEqual(OrbClaudePermissionMode.bypassPermissions.label, "Full access")
    }

    func testWorktreeLaunchModeParsing() {
        XCTAssertEqual(OrbWorktreeLaunchMode.parse(nil), .auto)
        XCTAssertEqual(OrbWorktreeLaunchMode.parse("worktree"), .worktree)
        XCTAssertEqual(OrbWorktreeLaunchMode.parse("local"), .local)
        XCTAssertEqual(OrbWorktreeLaunchMode.worktree.label, "Isolated worktree")
    }

    func testUnifiedDiffParserMultiFileAndStatus() {
        let sample = """
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
        """

        let files = OrbUnifiedDiffParser.parse(sample)
        XCTAssertEqual(files.count, 2)

        XCTAssertEqual(files[0].path, "src/hello.ts")
        XCTAssertEqual(files[0].status, "M")
        XCTAssertEqual(files[0].additions, 2)
        XCTAssertEqual(files[0].deletions, 1)
        XCTAssertEqual(files[0].hunks.count, 1)
        XCTAssertEqual(files[0].hunks[0].lines.count, 5)
        XCTAssertEqual(files[0].hunks[0].lines[0].kind, .context)
        XCTAssertEqual(files[0].hunks[0].lines[1].kind, .del)
        XCTAssertEqual(files[0].hunks[0].lines[1].oldLine, 2)
        XCTAssertEqual(files[0].hunks[0].lines[2].kind, .add)
        XCTAssertEqual(files[0].hunks[0].lines[2].newLine, 2)

        XCTAssertEqual(files[1].path, "src/added.ts")
        XCTAssertEqual(files[1].status, "A")
        XCTAssertEqual(files[1].additions, 2)
        XCTAssertEqual(files[1].deletions, 0)
    }

    func testCheckpointMetaDecodesCanonicalAndAliasFields() throws {
        let data = try XCTUnwrap(
            """
            {"ref":"refs/orb/checkpoints/m1/0001-post-1","commit_sha":"abcdef123456","turn_index":1}
            """.data(using: .utf8)
        )
        let json = try JSONDecoder().decode(OrbJSON.self, from: data)
        let meta = OrbCheckpointMeta(json)
        XCTAssertEqual(meta.ref, "refs/orb/checkpoints/m1/0001-post-1")
        XCTAssertEqual(meta.oid, "abcdef123456")
        XCTAssertEqual(meta.turn, 1)
    }
}
