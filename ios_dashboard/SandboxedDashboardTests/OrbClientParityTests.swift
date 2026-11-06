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

    func testControllerModelScheduleTimelineAndGrantNormalization() {
        XCTAssertEqual(OrbControllerModel.scheduleExpression(.string("0 9 * * *")), "0 9 * * *")
        XCTAssertEqual(
            OrbControllerModel.scheduleExpression(.object(["kind": .string("interval"), "minutes": .number(120)])),
            "every 2h"
        )
        XCTAssertEqual(
            OrbControllerModel.scheduleExpression(.object(["kind": .string("cron"), "expr": .string("*/15 * * * *")])),
            "*/15 * * * *"
        )

        let patched = OrbControllerModel.hermesPatch(
            ["name": .string("nightly"), "continuity": .bool(true)],
            existingJob: .object(["context_from": .array([.string("other-job"), .string("self")])])
        )
        XCTAssertEqual(patched["context_from"].items.map(\.text), ["other-job", "self"])

        let now = Date(timeIntervalSince1970: 1_762_000_000)
        let iso = ISO8601DateFormatter()
        let runs: [OrbJSON] = [
            .object(["id": .string("r4"), "at": .string(iso.string(from: now.addingTimeInterval(-60))), "silent": .bool(true)]),
            .object(["id": .string("r3"), "at": .string(iso.string(from: now.addingTimeInterval(-120))), "silent": .bool(true)]),
            .object(["id": .string("r2"), "at": .string(iso.string(from: now.addingTimeInterval(-180))), "status": .string("failed"), "error": .string("boom")]),
            .object(["id": .string("r1"), "at": .string(iso.string(from: now.addingTimeInterval(-240))), "status": .string("failed"), "error": .string("boom")])
        ]
        let entries = OrbControllerModel.buildEntries(runs: runs, now: now)
        XCTAssertEqual(entries.count, 3) // Today header + 2 folded silent + 2 folded failed
        if case .silent(_, let silentRuns) = entries[1] {
            XCTAssertEqual(silentRuns.count, 2)
        } else {
            XCTFail("Expected folded silent entry")
        }
        if case .failed(_, let failedRuns, let err) = entries[2] {
            XCTAssertEqual(failedRuns.count, 2)
            XCTAssertEqual(err, "boom")
        } else {
            XCTFail("Expected folded failed entry")
        }

        XCTAssertEqual(OrbControllerModel.parseProjectLimit(""), .success(0))
        XCTAssertEqual(OrbControllerModel.parseProjectLimit("4"), .success(4))
        XCTAssertNil(OrbControllerModel.projectLimitOf(.object(["parallel_missions": .number(0)])))
        XCTAssertEqual(OrbControllerModel.projectLimitOf(.object(["parallel_missions": .number(3)])), 3)

        // Legacy singular `skill` fallback vs explicit `skills` array.
        XCTAssertEqual(
            OrbControllerModel.skillsOf(
                settings: .object(["skill": .string("project-notes")]),
                job: .null
            ),
            ["project-notes"]
        )
        XCTAssertEqual(
            OrbControllerModel.skillsOf(
                settings: .object(["skills": .array([]), "skill": .string("stale-skill")]),
                job: .null
            ),
            []
        )

        // Script-only controller edits omit unchanged empty `prompt` so Core's `edit_args` does not reject `prompt: ""`.
        let scriptView: OrbJSON = .object([
            "job": .object([
                "id": .string("job-1"),
                "name": .string("script controller"),
                "schedule": .string("every 30m")
            ]),
            "settings": .object([
                "script": .string("scripts/check.py"),
                "prompt": .string(""),
                "skills": .array([.string("ops")]),
                "deliver": .string("project:demo"),
                "model": .string(""),
                "reasoning_effort": .string(""),
                "continuity": .bool(false)
            ])
        ])
        let scheduleOnlyPatch = OrbControllerModel.buildCronPatch(
            existingView: scriptView,
            defaultDeliver: "project:demo",
            name: "script controller",
            schedule: "every 15m",
            prompt: "",
            skills: ["ops"],
            deliver: "project:demo",
            model: "",
            reasoningEffort: "",
            continuity: false
        )
        XCTAssertEqual(scheduleOnlyPatch, ["schedule": .string("every 15m")])
        XCTAssertNil(scheduleOnlyPatch["prompt"])

        let unchangedPatch = OrbControllerModel.buildCronPatch(
            existingView: scriptView,
            defaultDeliver: "project:demo",
            name: "script controller",
            schedule: "every 30m",
            prompt: "",
            skills: ["ops"],
            deliver: "project:demo",
            model: "",
            reasoningEffort: "",
            continuity: false
        )
        XCTAssertTrue(unchangedPatch.isEmpty)
        XCTAssertEqual(
            OrbControllerModel.steerRunFailureMessage("scheduler offline"),
            "Steer saved, but the controller could not start: scheduler offline. Use Run now to retry."
        )
    }
}
