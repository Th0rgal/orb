import Foundation

/// What the home screen shows when Orb cannot reach its server, and which way
/// out it offers. Pure logic, unit tested (mirrors Android OrbConnectionIssue.kt).
struct OrbConnectionIssue: Equatable {
    var title: String
    var message: String
    /// The failing server URL, shown verbatim so a stale address is obvious.
    var serverURL: String
    /// Offer "Use default" (the saved URL is not already the default).
    var offerUseDefault: Bool
    /// Saved URL is a private/LAN address while the default server answers.
    var recommendDefault: Bool
    var technicalDetail: String
    /// System HTTP proxy ("host:port") the failed connection went through.
    var proxy: String? = nil
}

enum OrbConnection {
    static let defaultBaseURL = "https://agent-backend.thomas.md"
    static let orbcoreBaseURL = "https://orbcore.thomas.md"
    static let knownDirectBaseURL = "https://agent-backend.nico-best-pc-ever.ovh"

    static func normalize(_ url: String) -> String {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// Ordered candidate origins for 3-way Edge-diverse multi-path failover (mirrors Desktop/Tauri/Android).
    /// Prefers Cloudflare Edge BBR (`defaultBaseURL`) before direct OVH (`knownDirectBaseURL`) so lossy/high-RTT
    /// Wi-Fi or cellular links avoid transatlantic CUBIC collapse when `orbcore` degrades.
    static func candidateEndpoints(for primary: String) -> [String] {
        let clean = normalize(primary)
        guard !clean.isEmpty else { return [] }
        let lower = clean.lowercased()
        if lower == orbcoreBaseURL {
            return [clean, defaultBaseURL, knownDirectBaseURL]
        }
        if lower == knownDirectBaseURL {
            return [clean, defaultBaseURL, orbcoreBaseURL]
        }
        if lower == defaultBaseURL {
            return [clean, orbcoreBaseURL, knownDirectBaseURL]
        }
        // Dev and custom instances never share credentials or writes with prod.
        return [clean]
    }

    /// Whether a mutating `/api/...` JSON request should automatically carry an `Idempotency-Key`
    /// so retries and multi-path failovers cannot duplicate side effects.
    static func shouldAttachIdempotencyKey(method: String, path: String) -> Bool {
        let upper = method.uppercased()
        guard ["POST", "PUT", "PATCH", "DELETE"].contains(upper) else { return false }
        guard path.hasPrefix("/api/") else { return false }
        let excludedPrefixes = ["/api/auth/login", "/api/voice/", "/api/uploads", "/api/fs/upload"]
        return !excludedPrefixes.contains { path.hasPrefix($0) }
    }

    static func isFastRetryableGetError(_ error: Error) -> Bool {
        if let http = error as? OrbHTTPError {
            return [502, 503, 504, 522, 524].contains(http.status)
        }
        if let u = error as? URLError {
            switch u.code {
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
                 .dnsLookupFailed, .secureConnectionFailed, .cannotLoadFromNetwork:
                return true
            default:
                return false
            }
        }
        return false
    }

    static func isDefault(_ url: String) -> Bool { normalize(url).caseInsensitiveCompare(defaultBaseURL) == .orderedSame }

    static func host(_ url: String) -> String? {
        let raw = url.contains("://") ? url : "http://\(url)"
        return URLComponents(string: raw.trimmingCharacters(in: .whitespaces))?.host?
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
    }

    /// RFC 1918, loopback, link-local, CGNAT/Tailscale, IPv6 ULA, `.local`/`.lan`, single-label names.
    static func isPrivateAddress(_ url: String) -> Bool {
        guard let h = host(url), !h.isEmpty else { return false }
        if h == "localhost" || [".local", ".lan", ".home.arpa", ".internal"].contains(where: { h.hasSuffix($0) }) { return true }
        let parts = h.split(separator: ".").map(String.init)
        if parts.count == 4, parts.allSatisfy({ Int($0).map { (0...255).contains($0) } ?? false }) {
            let a = Int(parts[0])!, b = Int(parts[1])!
            return a == 10 || a == 127 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168)
                || (a == 169 && b == 254) || (a == 100 && (64...127).contains(b))
        }
        if h.contains(":") { return h == "::1" || h.hasPrefix("fc") || h.hasPrefix("fd") || h.hasPrefix("fe80") }
        return !h.contains(".")
    }

    /// The server could not be reached at all (vs. an HTTP error from a server that answered).
    static func isUnreachable(_ error: String?) -> Bool {
        guard let e = error?.lowercased() else { return false }
        return ["failed to connect", "could not connect", "cannot connect", "unable to resolve host",
                "hostname could not be found", "connection refused", "timed out", "timeout",
                "network connection was lost", "not connected to the internet", "offline",
                "no route to host", "network is unreachable", "secure connection failed",
                "connection reset", "cannot find host"].contains { e.contains($0) }
    }

    static func isUnreachable(_ error: Error) -> Bool {
        if let u = error as? URLError {
            switch u.code {
            case .cannotConnectToHost, .cannotFindHost, .timedOut, .notConnectedToInternet,
                 .networkConnectionLost, .dnsLookupFailed, .secureConnectionFailed, .cannotLoadFromNetwork:
                return true
            default: break
            }
        }
        return isUnreachable(error.localizedDescription)
    }

    static func issue(serverURL: String, error: String?, unreachable: Bool? = nil,
                      defaultReachable: Bool?, proxy: String? = nil) -> OrbConnectionIssue? {
        let isUnreach = unreachable ?? isUnreachable(error)
        let url = normalize(serverURL)
        let usingDefault = isDefault(url)
        let isPrivate = isPrivateAddress(url)
        let hasExternalProxy: Bool
        if let proxy, let proxyHost = proxy.split(separator: ":").first.map(String.init), !proxyHost.isEmpty,
           host(url) != proxyHost {
            hasExternalProxy = true
        } else {
            hasExternalProxy = false
        }
        let verdict = OrbKernel.connectionIssueClassify(
            isUnreachable: isUnreach,
            isUsingDefault: usingDefault,
            isPrivateAddr: isPrivate,
            defaultReachable: defaultReachable == true,
            hasExternalProxy: hasExternalProxy
        )
        guard verdict.showIssue else { return nil }
        if verdict.messageKind == 1, let proxy {
            return OrbConnectionIssue(
                title: "Can’t reach your Orb server",
                message: "Your device sends web traffic through a proxy at \(proxy), and the connection failed. Check or remove the proxy in your Wi-Fi settings, then try again.",
                serverURL: url, offerUseDefault: verdict.offerUseDefault, recommendDefault: verdict.recommendDefault,
                technicalDetail: error ?? "", proxy: proxy)
        }
        let message: String
        switch verdict.messageKind {
        case 2:
            message = "This looks like a local network address and it isn’t answering, but the default Orb server is online. Switch to the default server, or change the address."
        case 3:
            message = "This is a local network address. Make sure you’re on the same network and the server is running, or change the address."
        case 4:
            message = "Check your internet connection and try again."
        default:
            message = "Check the address and your connection, or switch to the default server."
        }
        return OrbConnectionIssue(title: "Can’t reach your Orb server", message: message, serverURL: url,
                                  offerUseDefault: verdict.offerUseDefault, recommendDefault: verdict.recommendDefault,
                                  technicalDetail: error ?? "")
    }

    static func shouldProbeDefault(serverURL: String, unreachable: Bool) -> Bool {
        OrbKernel.connectionIssueClassify(
            isUnreachable: unreachable,
            isUsingDefault: isDefault(serverURL),
            isPrivateAddr: isPrivateAddress(serverURL),
            defaultReachable: false,
            hasExternalProxy: false
        ).shouldProbeDefault
    }

    /// GET /api/health on the default server without credentials.
    static func probeDefault() async -> Bool {
        guard let url = URL(string: "\(defaultBaseURL)/api/health") else { return false }
        var req = URLRequest(url: url); req.timeoutInterval = 6
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return false }
        return (200..<500).contains(http.statusCode)
    }

    /// "host:port" of the system HTTPS proxy, if one is configured.
    static func systemProxy() -> String? {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else { return nil }
        // Keys are the CFNetwork HTTPS proxy keys (kCFNetworkProxiesHTTPSProxy is unavailable on iOS headers).
        for (hostKey, portKey, enableKey) in [("HTTPSProxy", "HTTPSPort", "HTTPSEnable"), ("HTTPProxy", "HTTPPort", "HTTPEnable")] {
            if (settings[enableKey] as? Int) == 1, let host = settings[hostKey] as? String, !host.isEmpty {
                let port = settings[portKey] as? Int
                return port.map { "\(host):\($0)" } ?? host
            }
        }
        return nil
    }
}
