import CryptoKit
import XCTest
@testable import sandboxed_sh

@MainActor
final class OrbClientParityTests: XCTestCase {
    func testGitHubSignInAcceptsMatchingCallbackOnceAndEnforcesState() {
        var now: Int64 = 1_000_000
        let store = OrbGitHubSignIn.MemoryStore()
        let signIn = OrbGitHubSignIn(store: store, clock: { now })

        let state = signIn.begin(endpoint: "https://Core.example/")
        XCTAssertTrue((16...128).contains(state.count))
        XCTAssertTrue(signIn.isPending(endpoint: "https://core.example"))

        now += 30_000
        XCTAssertEqual(
            signIn.onCallback(
                currentEndpoint: "https://core.example",
                token: " jwt-123 ",
                error: nil,
                state: state,
                serverEchoesState: true
            ),
            .accept(endpoint: "https://core.example", token: "jwt-123")
        )
        // Single-use: replay is rejected.
        if case .accept = signIn.onCallback(currentEndpoint: "https://core.example", token: "jwt-123", error: nil, state: state, serverEchoesState: true) {
            XCTFail("Expected second callback to be rejected")
        }

        // Forged state is rejected even when serverEchoesState is false.
        _ = signIn.begin(endpoint: "https://core.example")
        if case .accept = signIn.onCallback(currentEndpoint: "https://core.example", token: "jwt", error: nil, state: "forged-state-value", serverEchoesState: false) {
            XCTFail("Expected forged state to be rejected")
        }

        // Expired attempt is rejected.
        _ = signIn.begin(endpoint: "https://core.example")
        now += OrbGitHubSignIn.maxAgeMs + 1
        if case .accept = signIn.onCallback(currentEndpoint: "https://core.example", token: "jwt", error: nil) {
            XCTFail("Expected expired attempt to be rejected")
        }
    }

    func testGitHubCallbackURLParsingAndAuthorizeURL() throws {
        let cb = try XCTUnwrap(URL(string: "sandboxed://auth/callback?token=tok_abc&state=st_1"))
        XCTAssertTrue(OrbGitHubSignIn.isCallbackURL(cb))
        XCTAssertEqual(OrbGitHubSignIn.parseCallback(cb), .init(token: "tok_abc", error: nil, state: "st_1"))

        let inboxURL = try XCTUnwrap(URL(string: "sandboxed://inbox"))
        XCTAssertFalse(OrbGitHubSignIn.isCallbackURL(inboxURL))

        let authURL = try XCTUnwrap(OrbGitHubSignIn.authorizeURL(baseURL: "https://core.example/", state: "st_1234567890123456"))
        XCTAssertTrue(authURL.absoluteString.hasPrefix("https://core.example/api/auth/github/start?"))
        XCTAssertTrue(authURL.absoluteString.contains("state=st_1234567890123456"))
    }

    func testBackupMultipartSha256MatchesExactBodyBytes() {
        let zip = Data([0x50, 0x4B, 0x03, 0x04, 0xAA, 0xBB])
        let payload = OrbBackupArchive.buildRestoreMultipart(zipData: zip, filename: "backup.zip", boundary: "OrbTestBoundary")
        XCTAssertEqual(payload.contentType, "multipart/form-data; boundary=OrbTestBoundary")
        let expectedSha = SHA256.hash(data: payload.body).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(payload.sha256Hex, expectedSha)
        let text = String(decoding: payload.body, as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"backup\"; filename=\"backup.zip\""))

        XCTAssertEqual(OrbBackupArchive.parseCleanupDays("14"), .success(14))
        XCTAssertEqual(OrbBackupArchive.effectiveCleanupDays(nil), 1)
        XCTAssertEqual(OrbBackupArchive.effectiveCleanupDays(0), 1)
        XCTAssertEqual(OrbBackupArchive.effectiveCleanupDays(14), 14)
        if case .success = OrbBackupArchive.parseCleanupDays("0") {
            XCTFail("Expected 0 days to fail validation")
        }
        if case .success = OrbBackupArchive.parseCleanupDays("366") {
            XCTFail("Expected 366 days to fail validation")
        }

        let emptyArchive = OrbBackupArchive.interpretRestoreResponse(.object([
            "success": .bool(false),
            "message": .string("No recognized files in backup archive"),
            "restored_files": .array([]),
            "errors": .array([])
        ]))
        XCTAssertFalse(emptyArchive.ok)
        XCTAssertEqual(emptyArchive.message, "No recognized files in backup archive")

        let okArchive = OrbBackupArchive.interpretRestoreResponse(.object([
            "success": .bool(true),
            "message": .string(""),
            "restored_files": .array([.string("settings.json"), .string("providers.json")]),
            "errors": .array([])
        ]))
        XCTAssertTrue(okArchive.ok)
        XCTAssertEqual(okArchive.message, "Restored 2 files (settings.json, providers.json).")

        XCTAssertNil(OrbSkillsSettings.libraryRemoteUpdateError(.object(["library_reinitialized": .bool(true)])))
        XCTAssertEqual(
            OrbSkillsSettings.libraryRemoteUpdateError(.object([
                "library_reinitialized": .bool(false),
                "library_error": .string("Failed to clone git@github.com:org/private.git")
            ])),
            "Failed to clone git@github.com:org/private.git"
        )
        XCTAssertTrue(OrbSkillsSettings.sameLibraryRemote("git@github.com:Org/Skills.git/", "git@github.com:org/skills"))
        XCTAssertFalse(OrbSkillsSettings.needsLibraryRemoteInit(nextRemote: nil, activeRepoRemote: "git@github.com:org/skills.git", failedInitRemote: nil))
        XCTAssertFalse(OrbSkillsSettings.needsLibraryRemoteInit(nextRemote: "git@github.com:org/skills.git", activeRepoRemote: "git@github.com:org/skills", failedInitRemote: nil))
        XCTAssertTrue(OrbSkillsSettings.needsLibraryRemoteInit(nextRemote: "git@github.com:org/new.git", activeRepoRemote: "git@github.com:org/old.git", failedInitRemote: nil))
        XCTAssertTrue(OrbSkillsSettings.needsLibraryRemoteInit(nextRemote: "git@github.com:org/new.git", activeRepoRemote: "git@github.com:org/new.git", failedInitRemote: "git@github.com:org/new.git"))
    }

    func testProjectBoardSharedFixture() throws {
        let raw = try JSONDecoder().decode(OrbJSON.self, from: Data(contentsOf: OrbSpec.url("fixtures/project-board.json")))
        let cases = raw["cases"].items
        XCTAssertEqual(cases.map { $0["name"].text }, ["no board", "board", "missing fields"])
        for item in cases {
            let project = OrbProjectBoard(item["project"])
            let board = OrbProjectBoard(item["board"])
            XCTAssertEqual(project.controllerMissionID, board.controllerMissionID)
            XCTAssertEqual(project.boardUpdatedAt, board.updatedAt)
            XCTAssertEqual(project.controllerMissionID.map(OrbJSON.string) ?? .null, item["controller_update"]["mission_id"])
            switch item["name"].text {
            case "no board":
                XCTAssertEqual(board.text, "")
                XCTAssertNil(board.updatedByMissionID)
                XCTAssertNil(board.controllerMissionID)
            case "board":
                XCTAssertEqual(board.text, "# Project board\nShip iOS and Android together.\n")
                XCTAssertEqual(board.updatedAt, "2026-11-15T10:00:00Z")
                XCTAssertEqual(board.updatedByMissionID, "writer-2")
                XCTAssertEqual(board.controllerMissionID, "controller-1")
            case "missing fields":
                XCTAssertNil(board.text)
                XCTAssertNil(board.updatedAt)
                XCTAssertNil(board.updatedByMissionID)
                XCTAssertNil(project.controllerMissionID)
            default: XCTFail("Unknown fixture case")
            }
        }
    }

    func testProjectLimitNormalization() {
        XCTAssertEqual(OrbProjectGrant.parseProjectLimit(""), .success(0))
        XCTAssertEqual(OrbProjectGrant.parseProjectLimit("4"), .success(4))
        XCTAssertNil(OrbProjectGrant.projectLimitOf(.object(["parallel_missions": .number(0)])))
        XCTAssertEqual(OrbProjectGrant.projectLimitOf(.object(["parallel_missions": .number(3)])), 3)
    }
}
