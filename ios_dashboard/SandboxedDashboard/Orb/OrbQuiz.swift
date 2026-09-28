import SwiftUI

/// Mirrors the desktop `parseQuiz`: only explicit numbered QCMs become interactive;
/// options and correct answers are never inferred.
struct OrbQuizData: Equatable {
    struct Question: Equatable { let number: String; let text: String; let choices: [(letter: String, text: String)]
        static func == (a: Self, b: Self) -> Bool { a.number == b.number && a.text == b.text && a.choices.map(\.letter) == b.choices.map(\.letter) && a.choices.map(\.text) == b.choices.map(\.text) }
    }
    let before: String
    let after: String
    let questions: [Question]

    static func parse(_ source: String) -> OrbQuizData? {
        guard source.range(of: #"\b(quiz|qcm)\b"#, options: [.regularExpression, .caseInsensitive]) != nil,
              !source.contains("```"), !source.contains("~~~") else { return nil }
        let text = source.replacingOccurrences(of: "\r\n", with: "\n") as NSString
        let all = NSRange(location: 0, length: text.length)
        let starts = try! NSRegularExpression(pattern: #"^\s*(?:\*\*)?(\d+)[.)]\s+"#, options: .anchorsMatchLines).matches(in: text as String, range: all)
        guard !starts.isEmpty, starts.count <= 30 else { return nil }
        let optionStart = try! NSRegularExpression(pattern: #"(?:^|\s)(?:\*\*)?A\)\s+"#)
        let paragraphEnd = try! NSRegularExpression(pattern: #"\n\s*\n(?=\s*(?!(?:\*\*)?[A-H]\)\s)\S)"#)
        let optionMarks = try! NSRegularExpression(pattern: #"(?:^|\s)(?:\*\*)?([A-H])\)\s+"#)
        var questions: [Question] = []
        var end = 0
        for (i, start) in starts.enumerated() {
            guard Int(text.substring(with: start.range(at: 1))) == i + 1 else { return nil }
            let from = start.range.location + start.range.length
            let to = i + 1 < starts.count ? starts[i + 1].range.location : text.length
            let block = text.substring(with: NSRange(location: from, length: to - from)) as NSString
            guard let first = optionStart.firstMatch(in: block as String, range: NSRange(location: 0, length: block.length)) else { return nil }
            let tail = block.substring(from: first.range.location) as NSString
            let paragraph = paragraphEnd.firstMatch(in: tail as String, range: NSRange(location: 0, length: tail.length))
            let optionsEnd = first.range.location + (paragraph?.range.location ?? tail.length)
            let options = block.substring(with: NSRange(location: first.range.location, length: optionsEnd - first.range.location)) as NSString
            let marks = optionMarks.matches(in: options as String, range: NSRange(location: 0, length: options.length))
            guard (2...8).contains(marks.count) else { return nil }
            var choices: [(letter: String, text: String)] = []
            for (j, mark) in marks.enumerated() {
                let begin = mark.range.location + mark.range.length
                let stop = j + 1 < marks.count ? marks[j + 1].range.location : options.length
                let letter = options.substring(with: mark.range(at: 1))
                let body = clean(options.substring(with: NSRange(location: begin, length: stop - begin)))
                guard letter == String(UnicodeScalar(65 + j)!), !body.isEmpty else { return nil }
                choices.append((letter, body))
            }
            let question = clean(block.substring(to: first.range.location))
            guard !question.isEmpty else { return nil }
            // Preserve prose between questions by declining the transformation.
            if i < starts.count - 1, !block.substring(from: optionsEnd).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
            questions.append(Question(number: text.substring(with: start.range(at: 1)), text: question, choices: choices))
            end = from + optionsEnd
        }
        return OrbQuizData(before: text.substring(to: starts[0].range.location).trimmingCharacters(in: .whitespacesAndNewlines),
                           after: text.substring(from: end).trimmingCharacters(in: .whitespacesAndNewlines), questions: questions)
    }
    private static func clean(_ value: String) -> String {
        var s = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("**") { s.removeFirst(2) }
        if s.hasSuffix("**") { s.removeLast(2) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// The same reply the desktop sends, so either client can continue the quiz.
    func reply(_ answers: [String: String]) -> String {
        "Mes réponses au quiz :\n" + questions.map { q in
            let letter = answers[q.number] ?? ""
            return "\(q.number). \(letter)) \(q.choices.first { $0.letter == letter }?.text ?? "")"
        }.joined(separator: "\n")
    }
}

struct OrbQuiz: View {
    let quiz: OrbQuizData
    let disabled: Bool
    let onSubmit: (String) async -> Bool
    @State private var index = 0
    @State private var answers: [String: String] = [:]
    @State private var sending = false
    @State private var sent = false
    @State private var error = ""
    private var question: OrbQuizData.Question { quiz.questions[index] }
    private var locked: Bool { disabled || sending || sent }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Question \(index + 1) / \(quiz.questions.count)").font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Button { index -= 1 } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }.disabled(index == 0 || sending).accessibilityLabel("Question précédente")
                Button { index += 1 } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }.disabled(index == quiz.questions.count - 1 || sending).accessibilityLabel("Question suivante")
            }
            OrbRichText(source: question.text)
            VStack(spacing: 6) {
                ForEach(question.choices, id: \.letter) { choice in
                    let selected = answers[question.number] == choice.letter
                    Button { answers[question.number] = choice.letter } label: {
                        HStack(spacing: 14) {
                            Text(choice.letter).frame(width: 34, height: 34).overlay(Circle().stroke(selected ? Color.primary : Color.secondary, lineWidth: 1))
                            Text(choice.text).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(.vertical, 10).padding(.horizontal, 12).contentShape(Rectangle())
                            .background(selected ? Color(white: 0.2) : .clear, in: RoundedRectangle(cornerRadius: 24))
                    }.buttonStyle(.plain).disabled(locked)
                        .accessibilityLabel("\(choice.letter). \(choice.text)").accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            HStack {
                Text(sent ? "Réponses envoyées" : "\(answers.count) / \(quiz.questions.count) réponses").font(.footnote).foregroundStyle(.secondary)
                Spacer()
                if index < quiz.questions.count - 1 {
                    Button("Suivant") { index += 1 }.disabled(answers[question.number] == nil || sending)
                } else {
                    Button(sending ? "Envoi…" : "Envoyer mes réponses") { Task { await submit() } }
                        .disabled(locked || answers.count != quiz.questions.count)
                }
            }.buttonStyle(.bordered)
            if !error.isEmpty { Text(error).font(.footnote).foregroundStyle(.orange) }
        }
        .tint(.primary)
        .padding(20)
        .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 26))
        .overlay(RoundedRectangle(cornerRadius: 26).stroke(Color(white: 0.2)))
        .accessibilityElement(children: .contain).accessibilityLabel("Quiz interactif")
        .onChange(of: quiz) { _, _ in index = 0; answers = [:]; sent = false; error = "" }
    }
    private func submit() async {
        guard !locked, answers.count == quiz.questions.count else { return }
        sending = true; error = ""
        if await onSubmit(quiz.reply(answers)) { sent = true } else { error = "Envoi non confirmé. Tes réponses sont conservées." }
        sending = false
    }
}
