import Foundation

/// The legacy Control tab cached mission events as UserDefaults blobs and later as
/// files under Caches/missions. Orb never reads either, so purge them once at launch
/// instead of migrating data that nothing consumes.
enum OrbLegacyCleanup {
    static let didPurgeKey = "did_purge_legacy_mission_cache_v2"

    static func purgeLegacyMissionCacheIfNeeded(defaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        guard !defaults.bool(forKey: didPurgeKey) else { return }
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("cached_mission_") {
            defaults.removeObject(forKey: key)
        }
        defaults.removeObject(forKey: "did_migrate_mission_cache_v1")
        if let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            try? fileManager.removeItem(at: caches.appendingPathComponent("missions", isDirectory: true))
        }
        defaults.set(true, forKey: didPurgeKey)
    }
}
