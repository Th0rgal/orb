import XCTest
@testable import sandboxed_sh

final class OrbAgentSoftwareTests: XCTestCase {
    private func sampleComponent(
        id: String = "vibe",
        installed: Bool = true,
        version: String? = "2.19.1",
        path: String? = "/usr/local/bin/vibe-acp",
        updateSupported: Bool = true,
        latest: String? = "2.19.1",
        ready: Bool? = true,
        readyDetail: String? = "Authenticated via Core Mistral proxy."
    ) -> OrbSoftwareComponent {
        OrbSoftwareComponent(
            id: id,
            name: id,
            version: version,
            path: path,
            installed: installed,
            owner: "Fleet installer",
            update_supported: updateSupported,
            latest: latest,
            release_error: nil,
            running: [],
            instructions: "",
            ready: ready,
            ready_detail: readyDetail
        )
    }

    func testFreshFleetInstallableAndSummaryParityWithDesktop() {
        let missing = sampleComponent(
            installed: false,
            version: nil,
            path: nil,
            updateSupported: true,
            latest: "2.19.1",
            ready: false
        )
        XCTAssertTrue(OrbAgentSoftware.canInstallSoftware(missing))
        XCTAssertFalse(OrbAgentSoftware.canUpdateSoftware(missing))

        let job = OrbSoftwareJob(
            id: "j1",
            component: "vibe",
            version: "2.19.1",
            path: "/usr/local/bin/vibe-acp",
            state: "queued",
            error: nil,
            created_at: 1,
            updated_at: 1
        )
        XCTAssertTrue(OrbAgentSoftware.matchesSoftwareJob(job, missing))

        let machines = [
            OrbSoftwareMachine(
                id: "dgx-spark-admin",
                name: "dgx-spark-admin",
                online: true,
                inventory: OrbSoftwareInventory(
                    checked_at: 1,
                    components: [
                        sampleComponent(id: "codex", version: "codex-cli 1.9.0", latest: "1.10.0"),
                        sampleComponent(id: "grok", ready: false, readyDetail: "Missing Grok profile")
                    ],
                    runtime: OrbSoftwareRuntime(
                        name: "Node runner",
                        version: "0.13.0",
                        build: "test",
                        path: "/usr/local/bin/sandboxed-node",
                        restart_required: true,
                        running: []
                    ),
                    jobs: []
                ),
                error: nil
            ),
            OrbSoftwareMachine(
                id: "nimrud",
                name: "nimrud",
                online: true,
                inventory: OrbSoftwareInventory(
                    checked_at: 1,
                    components: [missing],
                    runtime: OrbSoftwareRuntime(
                        name: "Node runner",
                        version: "0.13.0",
                        build: "test",
                        path: "/usr/local/bin/sandboxed-node",
                        restart_required: false,
                        running: []
                    ),
                    jobs: []
                ),
                error: nil
            )
        ]

        XCTAssertEqual(
            OrbAgentSoftware.softwareAttentionSummary(machines),
            "1 restart needed · 1 missing · 1 setup needed · 1 update"
        )
        XCTAssertEqual(OrbAgentSoftware.availableSoftwareUpdates(machines).count, 2)
    }
}
