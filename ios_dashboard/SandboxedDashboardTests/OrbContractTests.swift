import XCTest
@testable import sandboxed_sh

final class OrbContractTests: XCTestCase {
    @MainActor func testReadCacheCoalescesAndInvalidates() async throws {
        let key = "test-cache:" + UUID().uuidString
        defer { OrbDisk.remove(key) }
        var requests = 0
        let fetch: @MainActor () async throws -> OrbJSON = {
            requests += 1
            try await Task.sleep(for: .milliseconds(30))
            return .string("loaded")
        }
        async let first = OrbReadCache.load(key, fetch: fetch)
        async let second = OrbReadCache.load(key, fetch: fetch)
        let results = try await [first, second]
        XCTAssertEqual(results, [.string("loaded"), .string("loaded")])
        XCTAssertEqual(requests, 1)
        _ = try await OrbReadCache.load(key, fetch: fetch)
        XCTAssertEqual(requests, 1)
        OrbReadCache.invalidate(key)
        XCTAssertEqual(OrbReadCache.read(key), .string("loaded"))
        _ = try await OrbReadCache.load(key, fetch: fetch)
        XCTAssertEqual(requests, 2)
    }
    func testLocalAndSideMissionsAreExcluded() throws {
        let local = OrbRow(.object(["id": .string("local"), "tags": .array([.string("placement:client")])]))
        XCTAssertFalse(local.mobile)
        let cloud = OrbRow(.object(["id": .string("cloud"), "backend": .string("cloud_chatgpt")]))
        XCTAssertTrue(cloud.mobile)
        XCTAssertTrue(cloud.cloud)
    }
    func testRemoteFollowupOmitsLocalIdentityAcrossPlacementFormats() {
        let local: [String: OrbJSON] = ["project": .string("default"), "track": .string("mission-123"), "github_pr": .null]
        XCTAssertEqual(OrbContinuation.identity(for: .object(local)), .object(local))
        for placement: [String: OrbJSON] in [
            ["remote_node_id": .string("babylon")],
            ["remote_job": .object(["node_id": .string("babylon")])],
            ["execution": .object(["scope_unit": .string("remote-node:babylon")])]
        ] {
            XCTAssertNil(OrbContinuation.identity(for: .object(local.merging(placement) { _, new in new })))
        }
        XCTAssertNil(OrbContinuation.identity(for: .object([:])))
    }

    func testFolderTagKeepsNestedPath() {
        let row = OrbRow(.object(["id": .string("a"), "tags": .array([.string("orb-folder:Design/Images")])]))
        XCTAssertEqual(row.folder, "Design/Images")
    }
    func testWireRoundTripPreservesProviderParameters() throws {
        let value = OrbJSON.object(["params": .array([.object(["id": .string("effort"), "value": .string("high")])]), "available": .bool(true)])
        XCTAssertEqual(try JSONDecoder().decode(OrbJSON.self, from: JSONEncoder().encode(value)), value)
    }
    func testCreationRequiresDestinationAccountAndRepository() {
        var selection = OrbSelection()
        XCTAssertThrowsError(try selection.validate())
        selection.provider = "cursor_cloud"; selection.account = "test"
        XCTAssertThrowsError(try selection.validate())
        selection.repository = "https://github.com/example/test"
        XCTAssertThrowsError(try selection.validate())
        selection.gitRef = "main"
        XCTAssertNoThrow(try selection.validate())
    }
}
