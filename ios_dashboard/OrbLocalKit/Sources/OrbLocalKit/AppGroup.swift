import Foundation

/// Shared container layout used by Orb, the Orb keyboard and the screen
/// broadcast extension. All three targets carry the same App Group.
public enum OrbAppGroup {
    public static let identifier = "group.md.thomas.openagent.dashboard"
    public static let frameNotification = "md.thomas.orb.screen.frame"
    public static let broadcastStateNotification = "md.thomas.orb.screen.state"

    public static func container() -> URL? {
        #if canImport(Darwin)
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
        #else
        nil // App Groups exist only on Apple platforms; Linux CI tests use temp dirs.
        #endif
    }

    public static var keyboard: URL? { container()?.appendingPathComponent("keyboard", isDirectory: true) }
    public static var screen: URL? { container()?.appendingPathComponent("screen", isDirectory: true) }
    public static var missions: URL? { container()?.appendingPathComponent("missions", isDirectory: true) }
}

/// Metadata the broadcast extension writes next to `latest.jpg`.
public struct BroadcastFrameInfo: Codable, Equatable, Sendable {
    public var sequence: UInt64
    public var capturedAt: Date
    public var width: Int
    public var height: Int
    public var sourceWidth: Int
    public var sourceHeight: Int
    public var orientation: Int
    public init(sequence: UInt64, capturedAt: Date, width: Int, height: Int, sourceWidth: Int, sourceHeight: Int, orientation: Int) {
        self.sequence = sequence; self.capturedAt = capturedAt; self.width = width; self.height = height
        self.sourceWidth = sourceWidth; self.sourceHeight = sourceHeight; self.orientation = orientation
    }
}

public struct BroadcastState: Codable, Equatable, Sendable {
    public var active: Bool
    public var startedAt: Date?
    public var heartbeat: Date
    public var maxDimension: Int
    public init(active: Bool, startedAt: Date?, heartbeat: Date = Date(), maxDimension: Int) {
        self.active = active; self.startedAt = startedAt; self.heartbeat = heartbeat; self.maxDimension = maxDimension
    }
    /// The extension refreshes its heartbeat at least every 2 seconds.
    public func isLive(now: Date = Date()) -> Bool { active && now.timeIntervalSince(heartbeat) < 6 }
}

/// Settings the app writes for the extension (resolution, frame rate).
public struct BroadcastSettings: Codable, Equatable, Sendable {
    public var maxDimension: Int
    public var maxFramesPerSecond: Double
    public var jpegQuality: Double
    public init(maxDimension: Int = 1024, maxFramesPerSecond: Double = 4, jpegQuality: Double = 0.6) {
        self.maxDimension = maxDimension; self.maxFramesPerSecond = maxFramesPerSecond; self.jpegQuality = jpegQuality
    }
}
