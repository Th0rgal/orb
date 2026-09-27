//
//  SandboxedDashboardApp.swift
//  SandboxedDashboard
//
//  iOS Dashboard for sandboxed.sh with liquid glass design
//

import SwiftUI

@main
struct SandboxedDashboardApp: App {
    init() {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "orb_test_reset"),
           UserDefaults.standard.string(forKey: "api_base_url")?.hasPrefix("http://127.0.0.1:") == true {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Orb")
            try? FileManager.default.removeItem(at: root)
        }
        #endif
        // Drain legacy in-UserDefaults mission cache blobs into the on-disk
        // Caches store. Each blob was a multi-KB-to-multi-MB JSON payload
        // held resident by cfprefsd; the migration runs at most once.
        ControlView.migrateMissionCacheIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    NavigationState.shared.handle(url: url)
                }
        }
    }
}
