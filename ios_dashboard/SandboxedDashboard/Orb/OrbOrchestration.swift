import SwiftUI

/// Subagents and machines a mission started through the orchestration API
/// (`sandboxed_start_mission`, `mcp__sandboxed__start_mission`,
/// `spawn_managed_machine`…). Same rules as the desktop `orchestrationModel.ts`:
/// one reference model whatever the harness prefix or the node the child runs on.
enum OrbOrchestration {
    enum Kind: Equatable { case subagent, machineSpawn, machineDestroy }

    struct Subagent: Identifiable, Equatable {
        let id: String
        var title: String
        var backend: String
        var model: String
        var nodeID: String
        var missionID: String?
        var status: String // starting, queued, running, done, failed, cancelled
        var error: String
        var summary: String
    }

    struct Machine: Identifiable, Equatable {
        let id: String
        let destroy: Bool
        var machineID: String
        var nodeID: String
        var size: String
        var state: String // requested, provisioning, online, destroyed, failed
        var costUSD: Double?
        var error: String
    }

    enum Ref: Identifiable, Equatable {
        case subagent(Subagent), machine(Machine)
        var id: String { switch self { case .subagent(let s): return s.id; case .machine(let m): return m.id } }
    }

    static func operation(_ name: String) -> String {
        var n = name.lowercased()
        if n.hasPrefix("functions.") { n.removeFirst("functions.".count) }
        if n.hasPrefix("mcp__"), let r = n.range(of: "__", options: .backwards), r.lowerBound > n.index(n.startIndex, offsetBy: 3) { n = String(n[r.upperBound...]) }
        if let dot = n.lastIndex(of: ".") { n = String(n[n.index(after: dot)...]) }
        if let colon = n.lastIndex(of: ":") { n = String(n[n.index(after: colon)...]) }
        if let match = n.range(of: #"^(?:mcp_)?(?:sandboxed|orchestrator|paloma)(?:[_-](?:sh|assistant|orchestrator))*[_-]"#, options: .regularExpression) {
            n.removeSubrange(match)
        }
        return n
    }

    static func kind(_ name: String) -> Kind? {
        switch operation(name) {
        case "start_mission", "create_mission", "spawn_worker": return .subagent
        case "spawn_managed_machine": return .machineSpawn
        case "destroy_managed_machine": return .machineDestroy
        default: return nil
        }
    }

    /// The JSON the tool returned, through the OpenCode `{output:"<json>"}` and MCP `{content:[{text}]}` envelopes.
    static func payload(_ raw: String) -> (value: OrbJSON, error: String?) {
        var value = parse(raw)
        for _ in 0..<4 {
            if value["structuredContent"] != .null { value = value["structuredContent"]; continue }
            let content = value["content"].items
            if !content.isEmpty {
                let text = content.map { $0["text"].text }.joined()
                if !text.isEmpty { value = parse(text); continue }
            }
            if !value["error"].text.isEmpty && value["output"] == .null {
                let inner = parse(value["error"].text)
                return (inner, errorText(inner, fallback: value["error"].text))
            }
            if !value["output"].text.isEmpty && (value["name"] != .null || value["rawInput"] != .null) { value = parse(value["output"].text); continue }
            break
        }
        return (value, nil)
    }

    private static func parse(_ text: String) -> OrbJSON {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("{") || t.hasPrefix("["), let v = try? JSONDecoder().decode(OrbJSON.self, from: Data(t.utf8)) else { return .string(text) }
        return v
    }

    private static func errorText(_ v: OrbJSON, fallback: String = "Failed") -> String {
        let e = v["error"]
        if !e["message"].text.isEmpty { return e["message"].text }
        if !v["message"].text.isEmpty { return v["message"].text }
        if !e.text.isEmpty { return e.text }
        return fallback
    }

    private static func status(_ m: OrbJSON) -> String? {
        let raw = (m["status"].text.isEmpty ? m["execution"]["state"].text : m["status"].text).lowercased()
        if raw.isEmpty { return nil }
        if ["completed", "complete", "done", "succeeded", "finished"].contains(raw) { return "done" }
        if raw.contains("cancel") { return "cancelled" }
        if ["fail", "error", "blocked", "not_feasible", "interrupted"].contains(where: raw.contains) { return "failed" }
        if ["queued", "pending", "admission", "dispatching"].contains(where: raw.contains) { return "queued" }
        return "running"
    }

    private static func oneLine(_ text: String, max: Int = 280) -> String {
        var t = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        t = t.replacingOccurrences(of: #"(?m)^\s*[-*]\s+"#, with: "", options: .regularExpression)
        t = t.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return t.count > max ? String(t.prefix(max)) + "…" : t
    }

    static func build(from events: [StoredEvent], liveStatus: (String) -> String? = { _ in nil }) -> [Ref] {
        // Facts revealed by later calls: get_action results, mission reads, machine states.
        var actions: [String: (value: OrbJSON, error: String?)] = [:]
        var missions: [String: OrbJSON] = [:]
        var machines: [String: OrbJSON] = [:]
        var argsByCall: [String: OrbJSON] = [:]
        func note(machine m: OrbJSON) {
            for key in [m["id"].text, m["node_id"].text] where !key.isEmpty { machines[key] = m }
        }
        for event in events where event.eventType == "tool_call" {
            argsByCall[event.toolCallId ?? "seq-\(event.sequence)"] = parse(event.content)
        }
        for event in events where event.eventType == "tool_result" {
            let op = operation(event.toolName ?? "")
            let (value, error) = payload(event.content)
            let args = argsByCall[event.toolCallId ?? ""] ?? .null
            if op == "get_action" {
                let id = args["action_id"].text.isEmpty ? value["action_id"].text : args["action_id"].text
                guard !id.isEmpty else { continue }
                let actionError = error ?? (value["error"] != .null ? errorText(value) : nil)
                actions[id] = (value["result"], actionError)
                let mission = value["result"]["mission"]
                if !mission["id"].text.isEmpty { missions[mission["id"].text] = mission }
                if value["result"]["machine"] != .null { note(machine: value["result"]["machine"]) }
                else if !value["result"]["node_id"].text.isEmpty && !value["result"]["state"].text.isEmpty { note(machine: value["result"]) }
            } else if ["get_mission", "get_mission_health", "get_mission_status"].contains(op) {
                let id = [value["mission_id"].text, value["id"].text, args["mission_id"].text].first { !$0.isEmpty } ?? ""
                if !id.isEmpty { missions[id] = value }
            }
        }

        var refs: [Ref] = []
        var results: [String: String] = [:]
        for event in events where event.eventType == "tool_result" { if let id = event.toolCallId { results[id] = event.content } }
        for event in events where event.eventType == "tool_call" {
            guard let kind = kind(event.toolName ?? "") else { continue }
            let callID = event.toolCallId ?? "seq-\(event.sequence)"
            let a = parse(event.content)
            let result = results[callID]
            if kind == .subagent {
                var s = Subagent(id: callID, title: [a["title"].text, a["description"].text].first { !$0.isEmpty } ?? oneLine(a["prompt"].text, max: 90),
                                 backend: a["backend"].text, model: a["model_override"].text, nodeID: a["remote_node_id"].text,
                                 missionID: nil, status: result == nil ? "starting" : "queued", error: "", summary: "")
                if let result {
                    let (value, error) = payload(result)
                    if error != nil || value["accepted"].text == "no" {
                        s.status = "failed"; s.error = error ?? errorText(value)
                    } else {
                        var mission: OrbJSON = value["mission"] != .null ? value["mission"] : (value["mission_id"].text.isEmpty ? .null : value)
                        if let act = actions[value["action_id"].text] {
                            if let e = act.error { s.status = "failed"; s.error = e.replacingOccurrences(of: "Outcome unconfirmed; inspect before retrying. ", with: "") }
                            if act.value["mission"] != .null { mission = act.value["mission"] }
                        }
                        let id = mission["mission_id"].text.isEmpty ? mission["id"].text : mission["mission_id"].text
                        if !id.isEmpty {
                            s.missionID = id
                            var facts = mission
                            if case .object(var base) = mission, case .object(let later) = missions[id] ?? .null {
                                base.merge(later) { _, new in new }; facts = .object(base)
                            }
                            if !facts["title"].text.isEmpty { s.title = facts["title"].text }
                            if !facts["backend"].text.isEmpty { s.backend = facts["backend"].text }
                            if !facts["model_override"].text.isEmpty { s.model = facts["model_override"].text }
                            let scope = facts["execution"]["scope_unit"].text
                            if s.nodeID.isEmpty && scope.hasPrefix("remote-node:") { s.nodeID = String(scope.dropFirst("remote-node:".count)) }
                            if s.status != "failed" { s.status = status(facts) ?? "running" }
                            if let live = liveStatus(id), let mapped = status(.object(["status": .string(live)])) { s.status = mapped }
                            if s.status == "done" || s.status == "running" { s.summary = oneLine(facts["last_assistant_message"].text) }
                        }
                    }
                }
                refs.append(.subagent(s))
            } else {
                var m = Machine(id: callID, destroy: kind == .machineDestroy, machineID: a["machine_id"].text, nodeID: "", size: a["size"].text,
                                state: result == nil ? "requested" : (kind == .machineDestroy ? "requested" : "provisioning"), costUSD: nil, error: "")
                if let result {
                    let (value, error) = payload(result)
                    if error != nil || value["accepted"].text == "no" {
                        m.state = "failed"; m.error = error ?? errorText(value)
                    } else {
                        var machine: OrbJSON = value["machine"]
                        if let act = actions[value["action_id"].text] {
                            if let e = act.error { m.state = "failed"; m.error = e }
                            if act.value["machine"] != .null { machine = act.value["machine"] }
                            else if !act.value["node_id"].text.isEmpty { machine = act.value }
                        }
                        if machine == .null, !m.machineID.isEmpty { machine = machines[m.machineID] ?? .null }
                        if case .object(var base) = machine, case .object(let later) = machines[machine["id"].text] ?? .null {
                            base.merge(later) { _, new in new }; machine = .object(base)
                        }
                        if machine != .null && m.state != "failed" {
                            m.machineID = machine["id"].text.isEmpty ? m.machineID : machine["id"].text
                            m.nodeID = machine["node_id"].text
                            if !machine["size"].text.isEmpty { m.size = machine["size"].text }
                            m.costUSD = machine["cost_usd"].doubleValue
                            let st = machine["state"].text.lowercased()
                            m.state = st == "destroyed" || !machine["destroyed_at"].text.isEmpty ? "destroyed" : st == "online" ? "online" : st == "failed" ? "failed" : "provisioning"
                        }
                    }
                }
                refs.append(.machine(m))
            }
        }
        return refs
    }

    static func nodeLabel(_ nodeID: String, refs: [Ref]) -> String {
        guard !nodeID.isEmpty else { return "" }
        let short = nodeID.hasPrefix("managed-") ? String(nodeID.dropFirst("managed-".count)) : nodeID
        for case .machine(let m) in refs where m.nodeID == nodeID && !m.size.isEmpty { return "\(m.size) · \(short)" }
        return short
    }

    static func statusLabel(_ s: String) -> String {
        ["starting": "Starting", "queued": "Queued", "running": "Running", "done": "Done", "failed": "Failed", "cancelled": "Cancelled",
         "requested": "Requested", "provisioning": "Provisioning", "online": "Online", "destroyed": "Destroyed"][s] ?? s.capitalized
    }

    static func usd(_ v: Double) -> String { v < 1 ? String(format: "$%.4f", v) : String(format: "$%.2f", v) }
}

/// Subagent and machine cards, shown on their own instead of inside the work fold.
struct OrbOrchestrationCards: View {
    let refs: [OrbOrchestration.Ref]
    let project: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(refs) { ref in
                switch ref {
                case .subagent(let s): subagentCard(s)
                case .machine(let m): machineCard(m)
                }
            }
        }
    }

    private func color(_ status: String) -> Color {
        switch status {
        case "done", "online": return OrbStyle.success
        case "failed": return OrbStyle.error
        default: return OrbStyle.textSecondary
        }
    }

    @ViewBuilder
    private func subagentCard(_ s: OrbOrchestration.Subagent) -> some View {
        let content = VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 11, weight: .semibold)).foregroundStyle(.purple)
                Text("Subagent").font(.caption.weight(.medium)).foregroundStyle(OrbStyle.textSecondary)
                Text(s.title).font(.caption).foregroundStyle(.primary).lineLimit(1)
                Spacer(minLength: 4)
                Text(OrbOrchestration.statusLabel(s.status)).font(.caption2.weight(.medium)).foregroundStyle(color(s.status))
                if s.missionID != nil { Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(OrbStyle.textMuted) }
            }
            let meta = [[s.backend, s.model].filter { !$0.isEmpty }.joined(separator: " · "), OrbOrchestration.nodeLabel(s.nodeID, refs: refs)].filter { !$0.isEmpty }
            if !meta.isEmpty { Text(meta.joined(separator: "  ·  ")).font(.caption2).foregroundStyle(OrbStyle.textMuted).lineLimit(1) }
            if !s.error.isEmpty { Text(s.error).font(.caption2).foregroundStyle(OrbStyle.error).lineLimit(3) }
            else if !s.summary.isEmpty { Text(s.summary).font(.caption2).foregroundStyle(OrbStyle.textSecondary).lineLimit(3) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OrbStyle.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(OrbStyle.border, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("orchestration.subagent.\(s.id)")
        if let id = s.missionID {
            NavigationLink { OrbConversation(missionID: id, project: project, folder: "") } label: { content }.buttonStyle(.plain)
        } else {
            content
        }
    }

    private func machineCard(_ m: OrbOrchestration.Machine) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "server.rack").font(.system(size: 11, weight: .semibold)).foregroundStyle(OrbStyle.textSecondary)
            Text(m.destroy ? "Destroy machine" : "Machine").font(.caption.weight(.medium)).foregroundStyle(OrbStyle.textSecondary)
            Text(OrbOrchestration.nodeLabel(m.nodeID.isEmpty ? (m.machineID.isEmpty ? "" : "managed-\(m.machineID)") : m.nodeID, refs: refs)).font(.caption).lineLimit(1)
            Spacer(minLength: 4)
            Text(!m.destroy && m.state == "destroyed" ? "Online → Destroyed" : OrbOrchestration.statusLabel(m.state)).font(.caption2.weight(.medium)).foregroundStyle(color(m.state))
            if let cost = m.costUSD { Text(OrbOrchestration.usd(cost)).font(.caption2.monospacedDigit()).foregroundStyle(OrbStyle.textMuted) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OrbStyle.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(OrbStyle.border, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("orchestration.machine.\(m.id)")
    }
}
