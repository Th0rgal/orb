import XCTest
@testable import sandboxed_sh

/// Same inputs as the desktop `quiz.test.tsx` and `message-images.test.tsx`, so both clients agree.
final class OrbDesktopParityTests: XCTestCase {
    private let quiz = "Oui.\n\n## Quiz de test\n\n**1. Combien font 7 × 8 ?** A) 48   B) 56   C) 64\n\n**2. Quel mot est un verbe ?** A) Rapidement B) Maison C) Apprendre\n\n**3. Tous les chats sont des mammifères. Félix est un chat. Que peut-on conclure ?** A) Félix est un mammifère. B) Tous les mammifères sont des chats. C) Félix n’est pas un mammifère.\n\nRéponds avec le numéro et la lettre pour chaque question, et je te donnerai ton score."

    func testQuizKeepsQuestionsChoicesIntroAndOutro() throws {
        let q = try XCTUnwrap(OrbQuizData.parse(quiz))
        XCTAssertEqual(q.questions.count, 3)
        XCTAssertEqual(q.questions[0].text, "Combien font 7 × 8 ?")
        XCTAssertEqual(q.questions[0].choices.map(\.letter), ["A", "B", "C"])
        XCTAssertEqual(q.questions[2].choices[2].text, "Félix n’est pas un mammifère.")
        XCTAssertTrue(q.before.contains("Oui."))
        XCTAssertTrue(q.after.contains("Réponds"))
    }

    func testQuizRefusesAnythingItWouldHaveToGuess() {
        XCTAssertNil(OrbQuizData.parse("Quiz\n1. Question A) one C) three"))
        XCTAssertNil(OrbQuizData.parse("Ordinary list\n1. Question A) one B) two"))
        XCTAssertNil(OrbQuizData.parse("Quiz\n```\n1. Question A) one B) two\n```"))
        XCTAssertNil(OrbQuizData.parse("Quiz\n1. Question A) One B) Two\n\nUnrelated prose\n\n2. Other A) X B) Y"))
        XCTAssertEqual(OrbQuizData.parse("Quiz\n1. Question ?\nA) One\nB) Two\n\n2. Another ?\nA) Three\nB) Four")?.questions.count, 2)
    }

    func testQuizReplyMatchesTheDesktopMessage() throws {
        let q = try XCTUnwrap(OrbQuizData.parse(quiz))
        XCTAssertEqual(q.reply(["1": "B", "2": "C", "3": "A"]),
                       "Mes réponses au quiz :\n1. B) 56\n2. C) Apprendre\n3. A) Félix est un mammifère.")
    }

    func testUploadedImagesBecomeThumbnailsAndOtherFilesStay() {
        let text = "Compare #1 and #2.\n\n[Uploaded: /workspace/first.png]\n\n[Uploaded: /workspace/second.jpg]\n\n[Uploaded: /workspace/report.pdf]"
        let parsed = OrbMessageImages.parse(text)
        XCTAssertEqual(parsed.text, "Compare #1 and #2.\n\n[Uploaded: /workspace/report.pdf]")
        XCTAssertEqual(parsed.paths, ["/workspace/first.png", "/workspace/second.jpg"])
        XCTAssertEqual(parsed.references, [1, 2])
    }

    func testImageReferencesKeepTheirNumbers() {
        XCTAssertEqual(OrbMessageImages.parse("Before\n[Image #3]\nAfter\n\n[Image #3] [Uploaded: /tmp/a.png]"),
                       OrbMessageImages(text: "Before\n[Image #3]\nAfter", paths: ["/tmp/a.png"], references: [3]))
        XCTAssertEqual(OrbMessageImages.parse("See [Image #3] [Uploaded: /tmp/a.png] here.").text, "See [Image #3] here.")
        XCTAssertEqual(OrbMessageImages.parse("See [Uploaded: /tmp/a.png] here.").text, "See #1 here.")
        XCTAssertEqual(OrbMessageImages.parse("  ordinary\n\n\ntext  ").text, "  ordinary\n\n\ntext  ")
        for value in ["[Uploaded: https://example.com/a.png]", "[Uploaded: /tmp/a.pdf]"] { XCTAssertEqual(OrbMessageImages.parse(value).text, value) }
    }

    func testLegacyInlineImageMarkersBecomeThumbnails() {
        let data = "data:image/png;base64,aGVsbG8="
        XCTAssertEqual(OrbMessageImages.parse("Look [Image #1]\n\n[Image #1] [Uploaded: \(data)]"),
                       OrbMessageImages(text: "Look [Image #1]", paths: [data], references: [1]))
        XCTAssertEqual(OrbMessageImages.parse("[Uploaded: data:text/html;base64,aGVsbG8=]").text, "[Uploaded: data:text/html;base64,aGVsbG8=]")
    }
}
