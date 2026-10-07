//
//  SandboxedDashboardApp.swift
//  SandboxedDashboard
//
//  iOS Dashboard for sandboxed.sh with liquid glass design
//

import SwiftUI
import UserNotifications

/// Notification taps from the on-iPhone agent: reopen Orb to resume a paused
/// mission, or open the app an agent could not open from the background.
final class OrbAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if let raw = response.notification.request.content.userInfo["orb_open_url"] as? String, let url = URL(string: raw) {
            _ = await UIApplication.shared.open(url)
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}

@main
struct SandboxedDashboardApp: App {
    @UIApplicationDelegateAdaptor(OrbAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    init() {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "orb_test_reset"),
           UserDefaults.standard.string(forKey: "api_base_url")?.hasPrefix("http://127.0.0.1:") == true {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Orb")
            try? FileManager.default.removeItem(at: root)
            if UserDefaults.standard.bool(forKey: "orb_test_reset_auth") { APIService.shared.logout() }
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
                .task {
                    if LocalAgentNode.shared.enabled {
                        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                        LocalAgentNode.shared.start()
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    LocalAgentNode.shared.start()
                    LocalAgentNode.shared.scenePhaseChanged(phase == .active ? .active : phase == .background ? .background : .inactive)
                }
        }
    }
}
