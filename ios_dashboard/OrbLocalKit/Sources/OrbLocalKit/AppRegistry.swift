import Foundation

/// Deep-link registry. Each action is a URL template taken from the vendor's
/// own documentation; whether the app is installed and whether opening
/// actually worked are *observed* on device and recorded, never assumed.
public struct AppActionTemplate: Codable, Equatable, Sendable {
    public var name: String
    public var summary: String
    /// `{param}` placeholders are percent-encoded on substitution.
    public var template: String
    public var parameters: [String]
    public var source: String
    public init(name: String, summary: String, template: String, parameters: [String], source: String) {
        self.name = name; self.summary = summary; self.template = template; self.parameters = parameters; self.source = source
    }
}

public struct AppEntry: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    /// URL that opens the app with no other effect, if one exists.
    public var launchURL: String?
    /// Scheme used for the installed probe (declared in LSApplicationQueriesSchemes).
    public var probeScheme: String?
    public var actions: [AppActionTemplate]
    public init(id: String, name: String, launchURL: String?, probeScheme: String?, actions: [AppActionTemplate]) {
        self.id = id; self.name = name; self.launchURL = launchURL; self.probeScheme = probeScheme; self.actions = actions
    }
}

/// What this device has actually shown for an app. Persisted so later
/// missions start from evidence.
public struct AppObservation: Codable, Equatable, Sendable {
    public var installed: Bool?
    public var lastOpenSucceeded: Bool?
    public var lastOpenedAt: Date?
    public var verifiedActions: [String: Bool]
    public init(installed: Bool? = nil, lastOpenSucceeded: Bool? = nil, lastOpenedAt: Date? = nil, verifiedActions: [String: Bool] = [:]) {
        self.installed = installed; self.lastOpenSucceeded = lastOpenSucceeded; self.lastOpenedAt = lastOpenedAt; self.verifiedActions = verifiedActions
    }
}

public enum AppRegistryError: Error, Equatable, LocalizedError {
    case unknownApp(String), unknownAction(String), missingParameter(String), invalidURL
    public var errorDescription: String? {
        switch self {
        case .unknownApp(let a): "Unknown app \(a). Call list_apps."
        case .unknownAction(let a): "Unknown action \(a). Call list_apps."
        case .missingParameter(let p): "Missing parameter \(p)"
        case .invalidURL: "The resulting URL is invalid"
        }
    }
}

public final class AppRegistry: @unchecked Sendable {
    public let entries: [AppEntry]
    private let lock = NSLock()
    private var observations: [String: AppObservation]
    private let store: URL?

    public init(entries: [AppEntry] = AppRegistry.builtin, store: URL? = nil) {
        self.entries = entries
        self.store = store
        if let store, let data = try? Data(contentsOf: store),
           let saved = try? JSONDecoder().decode([String: AppObservation].self, from: data) { observations = saved }
        else { observations = [:] }
    }

    public func entry(_ id: String) -> AppEntry? {
        let key = id.lowercased().replacingOccurrences(of: " ", with: "")
        return entries.first { $0.id == key || $0.name.lowercased().replacingOccurrences(of: " ", with: "") == key }
    }

    public func url(app: String, action: String, parameters: [String: String]) throws -> URL {
        guard let entry = entry(app) else { throw AppRegistryError.unknownApp(app) }
        guard let template = entry.actions.first(where: { $0.name == action }) else { throw AppRegistryError.unknownAction(action) }
        var url = template.template
        for p in template.parameters {
            guard let value = parameters[p] else { throw AppRegistryError.missingParameter(p) }
            // A template that is only a URL parameter takes the URL verbatim.
            url = url.replacingOccurrences(of: "{\(p)}", with: template.template == "{\(p)}" ? value : Self.encode(value))
        }
        guard let result = URL(string: url) else { throw AppRegistryError.invalidURL }
        return result
    }

    static func encode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    public func observe(_ app: String, update: (inout AppObservation) -> Void) {
        let snapshot: [String: AppObservation] = lock.withLock {
            var o = observations[app] ?? AppObservation()
            update(&o)
            observations[app] = o
            return observations
        }
        if let store, let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: store, options: .atomic) }
    }

    public func observation(_ app: String) -> AppObservation? { lock.withLock { observations[app] } }

    public var listing: JSONValue {
        .array(entries.map { e in
            let o = observation(e.id)
            return [
                "id": .string(e.id), "name": .string(e.name),
                "installed": o?.installed.map(JSONValue.bool) ?? .string("unknown"),
                "last_open_succeeded": o?.lastOpenSucceeded.map(JSONValue.bool) ?? .null,
                "actions": .array(e.actions.map { a in
                    ["name": .string(a.name), "summary": .string(a.summary), "parameters": .array(a.parameters.map(JSONValue.string)),
                     "verified_on_device": o?.verifiedActions[a.name].map(JSONValue.bool) ?? .null]
                }),
            ]
        })
    }

    /// Schemes for Info.plist `LSApplicationQueriesSchemes` (25 max on iOS 27+).
    public var querySchemes: [String] { entries.compactMap(\.probeScheme) }

    public static let builtin: [AppEntry] = [
        AppEntry(id: "safari", name: "Safari", launchURL: nil, probeScheme: nil, actions: [
            .init(name: "open", summary: "Open a web page in the default browser", template: "{url}", parameters: ["url"], source: "UIApplication.open https"),
        ]),
        AppEntry(id: "maps", name: "Maps", launchURL: "maps://", probeScheme: nil, actions: [
            .init(name: "search", summary: "Search places", template: "maps://?q={query}", parameters: ["query"], source: "developer.apple.com/documentation/mapkit/unified-map-urls"),
            .init(name: "directions", summary: "Directions to a destination", template: "maps://?daddr={destination}", parameters: ["destination"], source: "Apple Map Links"),
        ]),
        AppEntry(id: "phone", name: "Phone", launchURL: nil, probeScheme: nil, actions: [
            .init(name: "call", summary: "Start a call (iOS always asks the user to confirm)", template: "tel:{number}", parameters: ["number"], source: "Apple URL Scheme Reference"),
        ]),
        AppEntry(id: "messages", name: "Messages", launchURL: "sms:", probeScheme: nil, actions: [
            .init(name: "compose", summary: "Open a conversation with a recipient", template: "sms:{recipient}", parameters: ["recipient"], source: "Apple URL Scheme Reference"),
            .init(name: "compose_body", summary: "Recipient plus prefilled body (undocumented &body=, observed to work)", template: "sms:{recipient}&body={body}", parameters: ["recipient", "body"], source: "observed"),
        ]),
        AppEntry(id: "mail", name: "Mail", launchURL: "message://", probeScheme: nil, actions: [
            .init(name: "compose", summary: "Compose an email", template: "mailto:{to}?subject={subject}&body={body}", parameters: ["to", "subject", "body"], source: "RFC 6068"),
        ]),
        AppEntry(id: "facetime", name: "FaceTime", launchURL: nil, probeScheme: nil, actions: [
            .init(name: "call", summary: "FaceTime video call", template: "facetime:{handle}", parameters: ["handle"], source: "Apple URL Scheme Reference"),
        ]),
        AppEntry(id: "shortcuts", name: "Shortcuts", launchURL: "shortcuts://", probeScheme: "shortcuts", actions: [
            .init(name: "run", summary: "Run a shortcut with text input", template: "shortcuts://run-shortcut?name={name}&input=text&text={text}", parameters: ["name", "text"], source: "support.apple.com/guide/shortcuts/apd624386f42"),
        ]),
        AppEntry(id: "settings", name: "Settings", launchURL: "app-settings:", probeScheme: nil, actions: []),
        AppEntry(id: "telegram", name: "Telegram", launchURL: "tg://", probeScheme: "tg", actions: [
            .init(name: "open_chat", summary: "Open a chat with a public username", template: "tg://resolve?domain={username}", parameters: ["username"], source: "core.telegram.org/api/links"),
            .init(name: "share", summary: "Share text to a chat picker", template: "tg://msg?text={text}", parameters: ["text"], source: "core.telegram.org/api/links"),
        ]),
        AppEntry(id: "whatsapp", name: "WhatsApp", launchURL: "whatsapp://", probeScheme: "whatsapp", actions: [
            .init(name: "send", summary: "Open a chat with prefilled text (user taps send)", template: "https://wa.me/{phone}?text={text}", parameters: ["phone", "text"], source: "faq.whatsapp.com click-to-chat"),
        ]),
        AppEntry(id: "uber", name: "Uber", launchURL: "uber://", probeScheme: "uber", actions: [
            .init(name: "ride_to", summary: "Request a ride to coordinates (user confirms in Uber)", template: "uber://?action=setPickup&pickup=my_location&dropoff[latitude]={lat}&dropoff[longitude]={lng}&dropoff[nickname]={name}", parameters: ["lat", "lng", "name"], source: "developer.uber.com deep links"),
        ]),
        AppEntry(id: "googlemaps", name: "Google Maps", launchURL: "comgooglemaps://", probeScheme: "comgooglemaps", actions: [
            .init(name: "search", summary: "Search places", template: "comgooglemaps://?q={query}", parameters: ["query"], source: "developers.google.com/maps/documentation/urls/ios-urlscheme"),
        ]),
        AppEntry(id: "spotify", name: "Spotify", launchURL: "spotify://", probeScheme: "spotify", actions: [
            .init(name: "search", summary: "Search music", template: "spotify:search:{query}", parameters: ["query"], source: "Spotify URI scheme"),
        ]),
        AppEntry(id: "youtube", name: "YouTube", launchURL: "youtube://", probeScheme: "youtube", actions: [
            .init(name: "search", summary: "Search videos", template: "https://www.youtube.com/results?search_query={query}", parameters: ["query"], source: "universal link"),
        ]),
        AppEntry(id: "slack", name: "Slack", launchURL: "slack://open", probeScheme: "slack", actions: [
            .init(name: "open_channel", summary: "Open a channel", template: "slack://channel?team={team}&id={channel}", parameters: ["team", "channel"], source: "api.slack.com/reference/deep-linking"),
        ]),
        AppEntry(id: "orb", name: "Orb", launchURL: "orb://", probeScheme: nil, actions: []),
    ]
}
