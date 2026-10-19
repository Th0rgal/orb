//
//  SandboxedDashboardApp.swift
//  SandboxedDashboard
//
//  iOS Dashboard for sandboxed.sh with liquid glass design
//

import BackgroundTasks
import SwiftUI

@main
struct SandboxedDashboardApp: App {
    init() {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "orb_test_reset"),
           UserDefaults.standard.string(forKey: "api_base_url")?.hasPrefix("http://127.0.0.1:") == true {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Orb")
            try? FileManager.default.removeItem(at: root)
            if UserDefaults.standard.bool(forKey: "orb_test_reset_auth") { APIService.shared.logout() }
        }
        #endif
        // Drop the legacy Control-tab mission caches (UserDefaults blobs and
        // Caches/missions files); Orb keeps its own account-scoped store.
        OrbLegacyCleanup.purgeLegacyMissionCacheIfNeeded()
    }

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { OrbBackgroundRefresh.schedule() }
        }
        .backgroundTask(.appRefresh(OrbBackgroundRefresh.identifier)) {
            await OrbBackgroundRefresh.run()
        }
    }
}
