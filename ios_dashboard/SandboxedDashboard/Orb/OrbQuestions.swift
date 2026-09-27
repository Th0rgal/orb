import SwiftUI

struct OrbQuestion: View {
    let event: StoredEvent
    let request: OrbJSON
    let onAnswered: () -> Void
    @State private var answers: [String: String] = [:]
    @State private var error = ""
    @State private var busy = false
    private var params: OrbJSON { request["params"] == .null ? request : request["params"] }
    private var permission: Bool { ["permission", "plan"].contains(request["method"].text) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(permission ? "Review request" : "Your response is needed").font(.headline)
            if !error.isEmpty { OrbNotice(message: error) }
            if permission {
                Text(params["plan"].text.isEmpty ? params["input"]["description"].text : params["plan"].text)
                if !params["input"]["command"].text.isEmpty { Text(params["input"]["command"].text).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                HStack { Button("Decline") { Task { await reply(.object(["action": .string("revise")])) } }; Button("Approve") { Task { await reply(.object(["action": .string("accept")])) } } }
            } else {
                ForEach(params["questions"].items.indices, id: \.self) { index in
                    let question = params["questions"].items[index]
                    Text(question["question"].text)
                    ForEach(question["options"].items.indices, id: \.self) { choice in
                        let label = question["options"].items[choice]["label"].text
                        Button { answers[String(index)] = label } label: { HStack { Text(label); Spacer(); if answers[String(index)] == label { Image(systemName: "checkmark") } } }
                    }
                    TextField("Your answer", text: Binding(get: { answers[String(index)] ?? "" }, set: { answers[String(index)] = $0 }))
                }
                Button("Continue") { Task {
                    var mapped: [String: OrbJSON] = [:]
                    for (index, question) in params["questions"].items.enumerated() {
                        let answer = answers[String(index)] ?? ""
                        if request["method"].text == "claude_questions" || event.toolName == "AskUserQuestion" { mapped[question["question"].text] = .string(answer) }
                        else { mapped[question["id"].text.isEmpty ? String(index) : question["id"].text] = .object(["answers": .array([.string(answer)])]) }
                    }
                    await reply(.object(["answers": .object(mapped)]))
                } }.disabled(params["questions"].items.indices.contains { (answers[String($0)] ?? "").trimmingCharacters(in: .whitespaces).isEmpty })
            }
        }.disabled(busy).padding(18).background(OrbStyle.surface, in: RoundedRectangle(cornerRadius: 22))
    }
    private func reply(_ answer: OrbJSON) async {
        guard let call = event.toolCallId, !busy else { return }; busy = true; defer { busy = false }
        do {
            let result = try await OrbCore.shared.call("/api/control/tool_result", method: "POST", body: .object(["tool_call_id": .string(call), "name": .string(event.toolName ?? "ui_native_request"), "result": answer]))
            guard result["delivered"].flag else { throw OrbHTTPError(status: 409, detail: "This request has expired. Refresh the conversation.") }
            onAnswered()
        } catch { self.error = error.localizedDescription }
    }
}
