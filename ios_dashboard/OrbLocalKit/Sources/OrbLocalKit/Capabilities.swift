import Foundation

/// What this iPhone can actually do for an agent, reported to Core on client
/// registration and to the agent through the `capabilities` tool, so computer
/// use plans around the platform instead of hallucinating taps.
public struct DeviceCapabilities: Codable, Equatable, Sendable {
    public var localAgents: Bool
    public var unixShell: Bool
    public var screenObservation: Bool
    public var keyboardInjection: Bool
    public var appIntents: Bool
    public var computerUse: Bool
    /// Never true on stock iOS: there is no public or requestable API that
    /// synthesizes touches in another app. Kept explicit for agents.
    public var arbitraryUIInjection: Bool
    public var crossAppOpen: Bool
    /// Empirical: whether `UIApplication.open` succeeded while Orb was in the
    /// background. `nil` until the on-device probe has run.
    public var backgroundAppOpen: Bool?
    public var screenRead: Bool { screenObservation }

    public init(localAgents: Bool = false, unixShell: Bool = false, screenObservation: Bool = false,
                keyboardInjection: Bool = false, appIntents: Bool = true, computerUse: Bool = true,
                crossAppOpen: Bool = true, backgroundAppOpen: Bool? = nil) {
        self.localAgents = localAgents; self.unixShell = unixShell; self.screenObservation = screenObservation
        self.keyboardInjection = keyboardInjection; self.appIntents = appIntents; self.computerUse = computerUse
        self.arbitraryUIInjection = false; self.crossAppOpen = crossAppOpen; self.backgroundAppOpen = backgroundAppOpen
    }

    /// Core registry form (`/api/control/clients`).
    public var registry: [String: Bool] {
        ["local_agents": localAgents, "unix_shell": unixShell, "screen_observation": screenObservation,
         "keyboard_injection": keyboardInjection, "app_intents": appIntents, "computer_use": computerUse,
         "arbitrary_ui_injection": false]
    }

    /// Agent-facing form: what is possible plus the exact missing primitives.
    public var agentReport: JSONValue {
        [
            "screen_read": .bool(screenObservation),
            "cross_app_open": .bool(crossAppOpen),
            "background_app_open": backgroundAppOpen.map(JSONValue.bool) ?? .string("unknown"),
            "text_injection": .bool(keyboardInjection),
            "shortcuts": true,
            "unix_shell": .bool(unixShell),
            "arbitrary_cross_app_tap": false,
            "arbitrary_cross_app_swipe": false,
            "activate_accessibility_element_in_other_app": false,
            "read_accessibility_tree_of_other_app": false,
            "constraints": [
                "iOS has no public API to tap, swipe, scroll or focus elements in another app. Do not request coordinates; use deep links, Shortcuts and the Orb keyboard instead.",
                "Text can be typed only while the Orb keyboard is the active keyboard and a text field is already focused. Prefer URLs that prefill text (sms:, mailto:?body=, maps://?q=).",
                "Secure and phone-pad fields always use the system keyboard; they cannot be typed into or read.",
                "Screen frames come from a ReplayKit broadcast the user started; if it is off, screenshot returns Orb's own last frame or an error.",
                "Opening an app while Orb is in the background may be refused by iOS; the result says so, and Orb can ask the user with a notification.",
            ],
        ]
    }
}
