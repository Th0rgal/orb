import XCTest
@testable import sandboxed_sh

final class OrbDictationTests: XCTestCase {
    @MainActor func testDeniedPermissionPreservesDraftAndShowsRecovery() async {
        let model = OrbDictation(requestPermission: { false })
        var draft = "Existing text"
        model.start(language: "fr") { draft += $0 }
        for _ in 0..<100 { if model.phase == .failed { break }; await Task.yield() }
        XCTAssertEqual(model.phase, .failed)
        XCTAssertTrue(model.microphoneDenied)
        XCTAssertFalse(model.canRetry)
        XCTAssertEqual(draft, "Existing text")
        model.cancel()
        XCTAssertEqual(model.phase, .idle)
    }
    @MainActor func testPermissionReplyAfterCancelCannotReopenRecorder() async {
        var continuation: CheckedContinuation<Bool, Never>?
        let model = OrbDictation(requestPermission: { await withCheckedContinuation { continuation = $0 } })
        model.start(language: "en") { _ in XCTFail("Cancelled dictation changed the draft") }
        for _ in 0..<100 { if continuation != nil { break }; await Task.yield() }
        XCTAssertNotNil(continuation)
        model.cancel()
        continuation?.resume(returning: true)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(model.phase, .idle)
        XCTAssertFalse(model.active)
    }
    @MainActor func testOldPermissionFailureCannotOverwriteNewRequest() async {
        var replies: [CheckedContinuation<Bool, Never>] = []
        let model = OrbDictation(requestPermission: { await withCheckedContinuation { replies.append($0) } })
        model.start(language: "en") { _ in }
        for _ in 0..<100 { if replies.count == 1 { break }; await Task.yield() }
        model.start(language: "fr") { _ in }
        for _ in 0..<100 { if replies.count == 2 { break }; await Task.yield() }
        XCTAssertEqual(replies.count, 2)
        guard replies.count == 2 else { model.cancel(); replies.forEach { $0.resume(returning: false) }; return }
        replies[0].resume(returning: false)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(model.phase, .permission)
        XCTAssertFalse(model.microphoneDenied)
        replies[1].resume(returning: false)
        for _ in 0..<100 { if model.phase == .failed { break }; await Task.yield() }
        XCTAssertEqual(model.phase, .failed)
        XCTAssertTrue(model.microphoneDenied)
    }
}
