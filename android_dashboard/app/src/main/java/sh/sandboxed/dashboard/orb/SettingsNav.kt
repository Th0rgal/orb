package sh.sandboxed.dashboard.orb

/**
 * Settings navigation shared with Orb desktop (orb/src/settingsNav.ts) and iOS
 * (OrbSettingsNav.swift): five sections with the same ids, names and
 * subtitles, checked against shared/orb-spec/fixtures/settings-nav.json.
 * Pages a phone cannot show are left out; phone-only pages sit in the section
 * they belong to.
 */
enum class OrbSettingsSection(val id: String, val label: String, val subtitle: String) {
    Account("account", "Account", "Your server connection, connected accounts, how Orb looks and usage telemetry."),
    Models("models", "Models", "Fallback order, provider health, usage over time and API keys."),
    Agents("agents", "Agents", "What agents know and can do, the Assistant, and the agents on this computer."),
    Security("security", "Security", "Who can approve risky actions, Fleet Bunker Mode, privileged access and secrets."),
    Notifications("notifications", "Notifications", "What reaches your Inbox and when Orb tells you.");

    /** Concise 1-line summary shown on root mobile Settings rows (never truncates mid-sentence). */
    val mobileSummary: String
        get() = when (this) {
            Account -> "Server, sign-in & diagnostics"
            Models -> "Providers, routing, usage & keys"
            Agents -> "Skills, Assistant & machines"
            Security -> "Approvals, Bunker Mode & secrets"
            Notifications -> "Inbox & alert preferences"
        }

    /** Page id, label and route; ids shared with desktop keep desktop's label. */
    val pages: List<Triple<String, String, OrbSettingsRoute>>
        get() = when (this) {
            Account -> listOf(
                Triple("settings", "Account", OrbSettingsRoute.Backend),
                Triple("usage-telemetry", "Usage telemetry", OrbSettingsRoute.UsageTelemetry),
                Triple("dictation", "Dictation", OrbSettingsRoute.Dictation),
                Triple("debug", "Advanced", OrbSettingsRoute.DebugInfo),
            )
            Models -> listOf(
                Triple("routing", "Fallback Chains", OrbSettingsRoute.FallbackChains),
                Triple("routing-providers", "Providers", OrbSettingsRoute.Providers),
                Triple("usage-settings", "Usage", OrbSettingsRoute.Usage),
                Triple("routing-keys", "API Keys", OrbSettingsRoute.ProxyKeys),
            )
            Agents -> listOf(
                Triple("skills-settings", "Skills", OrbSettingsRoute.Skills),
                Triple("hermes-settings", "Assistant", OrbSettingsRoute.Assistant),
                Triple("btw-settings", "Quick questions (/btw)", OrbSettingsRoute.SideQuestions),
                Triple("machines", "Machines", OrbSettingsRoute.Machines),
            )
            Security -> listOf(
                Triple("security-settings", "Access", OrbSettingsRoute.Secrets),
                Triple("bitwarden-settings", "Secrets vault", OrbSettingsRoute.Bitwarden),
                Triple("ssh-signing", "SSH signing", OrbSettingsRoute.Fido),
            )
            Notifications -> listOf(Triple("inbox-settings", "Notifications", OrbSettingsRoute.Inbox))
        }

    companion object {
        fun of(route: OrbSettingsRoute): OrbSettingsSection? = entries.firstOrNull { s -> s.pages.any { it.third == route } }

        /** Sections that need the user (attention dot). */
        fun attention(bunkerActive: Boolean, deviceEnrolled: Boolean, quotaExhausted: Boolean): Set<OrbSettingsSection> = buildSet {
            if (bunkerActive || !deviceEnrolled) add(Security)
            if (quotaExhausted) add(Models)
        }
    }
}
