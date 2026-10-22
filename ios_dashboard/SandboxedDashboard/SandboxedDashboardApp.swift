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
            try? FileManager.default.removeItem(at: OrbFileService.cacheRoot)
            if UserDefaults.standard.bool(forKey: "orb_test_reset_auth") { OrbCore.shared.logout() }
        }
        #endif
        // Drop the legacy Control-tab mission caches (UserDefaults blobs and
        // Caches/missions files); Orb keeps its own account-scoped store.
        OrbLegacyCleanup.purgeLegacyMissionCacheIfNeeded()
        OrbMemory.observeWarnings()
    }

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .modifier(OrbTestTypeSize())
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { OrbBackgroundRefresh.schedule(); OrbMemory.trim() }
        }
        .backgroundTask(.appRefresh(OrbBackgroundRefresh.identifier)) {
            await OrbBackgroundRefresh.run()
        }
    }
}

/// DEBUG: `-orb_dynamic_type accessibility3` renders the app at that Dynamic Type size,
/// so UI tests can check large-text layouts without changing simulator settings.
private struct OrbTestTypeSize: ViewModifier {
    func body(content: Content) -> some View {
        #if DEBUG
        if let raw = UserDefaults.standard.string(forKey: "orb_dynamic_type"),
           let size = DynamicTypeSize.allCases.first(where: { "\($0)" == raw }) {
            content.dynamicTypeSize(size)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// Releases rebuildable caches. A 4 GB phone (iPhone 13 mini) reclaims the largest
/// suspended app first; Orb measured 353 MB resident while suspended.
@MainActor enum OrbMemory {
    static func trim() {
        OrbReadCache.trimMemory()
        OrbNativeMarkdownView.trimCaches()
        OrbRemoteLog.trimCache()
        OrbImageLoader.trimCache()
        OrbWebViewPool.shared.drain()
    }
    static func observeWarnings() {
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { trim() }
        }
    }
}
