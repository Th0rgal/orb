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
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: permission ? "hand.raised.fill" : "questionmark.bubble.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(OrbStyle.warning)
                Text(permission ? "Review request" : "Your response is needed")
                    .font(.subheadline.weight(.semibold))
            }
            if !error.isEmpty { OrbNotice(message: error) }
            if permission {
                let detail = params["plan"].text.isEmpty ? params["input"]["description"].text : params["plan"].text
                if !detail.isEmpty {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.primary.opacity(0.9))
                }
                if !params["input"]["command"].text.isEmpty {
                    Text(params["input"]["command"].text)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(OrbStyle.textSecondary)
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(OrbStyle.border))
                }
                HStack(spacing: 10) {
                    Button {
                        OrbHaptics.light()
                        Task { await reply(.object(["action": .string("revise")])) }
                    } label: {
                        Text("Decline")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(OrbStyle.textSecondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.05), in: Capsule())
                            .overlay(Capsule().stroke(OrbStyle.border))
                    }
                    .buttonStyle(.plain)

                    Button {
                        OrbHaptics.success()
                        Task { await reply(.object(["action": .string("accept")])) }
                    } label: {
                        Text("Approve")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(OrbStyle.background)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.white, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            } else {
                ForEach(params["questions"].items.indices, id: \.self) { index in
                    let question = params["questions"].items[index]
                    VStack(alignment: .leading, spacing: 8) {
                        Text(question["question"].text)
                            .font(.subheadline.weight(.medium))
                        ForEach(question["options"].items.indices, id: \.self) { choice in
                            let label = question["options"].items[choice]["label"].text
                            let selected = answers[String(index)] == label
                            Button {
                                OrbHaptics.selection()
                                answers[String(index)] = label
                            } label: {
                                HStack(spacing: 10) {
                                    Text(label)
                                        .font(.footnote)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if selected {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(.primary)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .background(selected ? OrbStyle.elevated : Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(selected ? OrbStyle.borderStrong : OrbStyle.border))
                            }
                            .buttonStyle(.plain)
                        }
                        TextField("Your answer", text: Binding(get: { answers[String(index)] ?? "" }, set: { answers[String(index)] = $0 }))
                            .font(.footnote)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(OrbStyle.border))
                    }
                }
                let invalid = params["questions"].items.indices.contains { (answers[String($0)] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
                Button {
                    OrbHaptics.light()
                    Task {
                        var mapped: [String: OrbJSON] = [:]
                        for (index, question) in params["questions"].items.enumerated() {
                            let answer = answers[String(index)] ?? ""
                            if request["method"].text == "claude_questions" || event.toolName == "AskUserQuestion" { mapped[question["question"].text] = .string(answer) }
                            else { mapped[question["id"].text.isEmpty ? String(index) : question["id"].text] = .object(["answers": .array([.string(answer)])]) }
                        }
                        await reply(.object(["answers": .object(mapped)]))
                    }
                } label: {
                    Text("Continue")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(invalid ? OrbStyle.textMuted : OrbStyle.background)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(invalid ? Color.white.opacity(0.08) : Color.white, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(invalid)
            }
        }
        .disabled(busy)
        .padding(14)
        .background(OrbStyle.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(OrbStyle.borderStrong))
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
