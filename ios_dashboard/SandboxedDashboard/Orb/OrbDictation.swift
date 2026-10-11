import AVFoundation
import SwiftUI
import Observation
import Combine

/// One short recording at a time. Cancellation fences permission and network callbacks.
@Observable
@MainActor
final class OrbDictation {
    enum Phase: Equatable { case idle, permission, recording, transcribing, failed }
    static let languages: [(String, String)] = [("en", "English"), ("fr", "Français"), ("de", "Deutsch"), ("es", "Español"), ("it", "Italiano"), ("pt", "Português"), ("nl", "Nederlands"), ("pl", "Polski"), ("el", "Ελληνικά"), ("ar", "العربية"), ("ja", "日本語"), ("zh", "中文"), ("vi", "Tiếng Việt"), ("ko", "한국어")]
    private(set) var phase: Phase = .idle
    private(set) var levels = Array(repeating: CGFloat(0.05), count: 36)
    private(set) var elapsed: TimeInterval = 0
    private(set) var error = ""
    private(set) var microphoneDenied = false
    var active: Bool { phase != .idle }
    nonisolated static func audioNotifications(_ name: Notification.Name) -> AnyPublisher<Notification, Never> {
        // Audio route changes arrive on a system thread. SwiftUI callbacks are
        // MainActor-isolated, so hop before invoking them (including their guards).
        NotificationCenter.default.publisher(for: name)
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }
    private let requestPermission: @MainActor () async -> Bool
    private var ownsAudioSession = false
    init(requestPermission: @escaping @MainActor () async -> Bool = { await AVAudioApplication.requestRecordPermission() }) {
        self.requestPermission = requestPermission
    }
    private var recorder: AVAudioRecorder?
    private var file: URL?
    private var meterTask: Task<Void, Never>?
    private var requestTask: Task<Void, Never>?
    private var generation = 0
    private var endpoint = ""
    private var language = "en"
    private var accept: ((String) -> Void)?

    func start(language: String, accept: @escaping (String) -> Void) {
        cancel()
        phase = .permission
        self.language = language
        self.accept = accept
        endpoint = OrbCore.shared.endpoint
        #if DEBUG
        // Deterministic recorder fixture, available only in debug builds against loopback.
        if UserDefaults.standard.bool(forKey: "orb_dictation_fixture"),
           URL(string: endpoint)?.host == "127.0.0.1" {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("orb-dictation-\(UUID()).wav")
            var wav = Data("RIFF".utf8)
            func integer<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; withUnsafeBytes(of: &little) { wav.append(contentsOf: $0) } }
            integer(UInt32(3236)); wav.append(Data("WAVEfmt ".utf8)); integer(UInt32(16))
            integer(UInt16(1)); integer(UInt16(1)); integer(UInt32(16000)); integer(UInt32(32000)); integer(UInt16(2)); integer(UInt16(16))
            wav.append(Data("data".utf8)); integer(UInt32(3200)); wav.append(Data(repeating: 0, count: 3200))
            do { try wav.write(to: url); file = url; phase = .recording; elapsed = 6; levels = (0..<36).map { CGFloat(0.08 + abs(sin(Double($0) * 0.55)) * 0.8) } }
            catch { fail("Could not create fixture recording.") }
            return
        }
        #endif
        let current = generation
        requestTask = Task { [weak self] in
            guard let permission = self?.requestPermission else { return }
            let granted = await permission()
            guard let self, self.generation == current, !Task.isCancelled else { return }
            guard granted else {
                self.microphoneDenied = true
                self.fail("Allow microphone access in Settings to dictate.")
                return
            }
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
                try session.setActive(true)
                self.ownsAudioSession = true
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("orb-dictation-\(UUID()).wav")
                self.file = url
                let recorder = try AVAudioRecorder(url: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000.0, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
                recorder.isMeteringEnabled = true
                guard recorder.prepareToRecord(), recorder.record(forDuration: 120) else { throw URLError(.cannotCreateFile) }
                self.recorder = recorder
                self.phase = .recording
                OrbHaptics.selection()
                self.meterTask = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(80))
                        guard let self, self.generation == current, self.phase == .recording, let recorder = self.recorder else { return }
                        guard recorder.isRecording else {
                            if self.elapsed >= 119 { self.finish() }
                            else { self.fail("Recording was interrupted. Please try again."); self.releaseRecorder() }
                            return
                        }
                        recorder.updateMeters()
                        self.elapsed = recorder.currentTime
                        self.levels.removeFirst()
                        self.levels.append(CGFloat(max(0.05, min(1, pow(10, recorder.averagePower(forChannel: 0) / 35)))))
                        if self.elapsed >= 120 { self.finish(); return }
                    }
                }
            } catch {
                self.releaseRecorder()
                self.removeFile()
                self.fail("Could not start the microphone. Please try again.")
            }
        }
    }

    func finish() {
        guard phase == .recording else { return }
        elapsed = max(elapsed, recorder?.currentTime ?? 0)
        releaseRecorder()
        guard elapsed >= 0.2 else {
            removeFile()
            fail("Recording was too short. Cancel and record a longer message.")
            return
        }
        transcribe()
    }
    func retry() { guard phase == .failed, file != nil else { return }; transcribe() }
    private func transcribe() {
        guard let file else { return }
        phase = .transcribing
        error = ""
        let current = generation
        requestTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard self.endpoint == OrbCore.shared.endpoint else { throw CancellationError() }
                let audio = try Data(contentsOf: file)
                let result = try await OrbCore.shared.transcribe(audio, language: self.language)
                guard !Task.isCancelled, self.generation == current, self.endpoint == OrbCore.shared.endpoint else { return }
                guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { self.fail("No speech detected. Cancel and try a new recording."); return }
                let accept = self.accept
                self.cancel()
                accept?(result)
                OrbHaptics.selection()
            } catch {
                guard !Task.isCancelled, self.generation == current else { return }
                if error is CancellationError { self.cancel(); return }
                self.fail(error is OrbHTTPError ? error.localizedDescription : "Transcription failed. Your recording is retained while this screen stays open; retry or cancel.")
            }
        }
    }
    private func fail(_ message: String) { error = message; phase = .failed }
    private func releaseRecorder() {
        meterTask?.cancel(); meterTask = nil
        recorder?.stop(); recorder = nil
        if ownsAudioSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            ownsAudioSession = false
        }
    }
    private func removeFile() { if let file { try? FileManager.default.removeItem(at: file) }; file = nil }
    func cancel() {
        generation += 1
        requestTask?.cancel(); requestTask = nil
        releaseRecorder(); removeFile()
        phase = .idle; elapsed = 0; error = ""; microphoneDenied = false
        levels = Array(repeating: 0.05, count: 36)
        accept = nil
    }
    var canRetry: Bool { phase == .failed && file != nil }
}

struct OrbDictationCapsule: View {
    @Bindable var dictation: OrbDictation
    var body: some View {
        let levels = dictation.levels
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button { dictation.cancel() } label: { Image(systemName: "xmark").font(.system(size: 19, weight: .medium)).frame(width: 44, height: 44).background(.white.opacity(0.09), in: Circle()) }
                    .accessibilityLabel("Cancel dictation").accessibilityIdentifier("dictation.cancel")
                if dictation.phase == .recording {
                    Canvas { context, size in
                        let pitch = size.width / CGFloat(levels.count)
                        for (i, level) in levels.enumerated() {
                            let height = max(3, level * 28)
                            let rect = CGRect(x: CGFloat(i) * pitch, y: (size.height - height) / 2, width: max(1, pitch * 0.55), height: height)
                            context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(.white.opacity(0.3 + Double(level) * 0.6)))
                        }
                    }.frame(height: 32).accessibilityHidden(true)
                    Button { dictation.finish() } label: { Image(systemName: "stop.fill").font(.system(size: 16)).frame(width: 44, height: 44).background(.white.opacity(0.09), in: Circle()) }
                        .accessibilityLabel("Stop recording and transcribe").accessibilityIdentifier("dictation.stop")
                    Button { dictation.finish() } label: { Image(systemName: "arrow.up").font(.system(size: 22, weight: .medium)).foregroundStyle(.black).frame(width: 44, height: 44).background(.white, in: Circle()) }
                        .accessibilityLabel("Use recording in draft").accessibilityIdentifier("dictation.use")
                } else {
                    HStack(spacing: 7) {
                        if dictation.phase != .failed { ProgressView().tint(.white) }
                        Text(dictation.phase == .permission ? "Microphone…" : dictation.phase == .failed ? "Try again" : "Transcribing…").font(.subheadline).lineLimit(1)
                    }.frame(maxWidth: .infinity)
                    if dictation.canRetry {
                        Button { dictation.retry() } label: { Image(systemName: "arrow.clockwise").frame(width: 44, height: 44).background(.white.opacity(0.09), in: Circle()) }.accessibilityLabel("Retry transcription")
                    } else {
                        Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
                    }
                }
            }
            .buttonStyle(.plain).foregroundStyle(.white)
            .padding(8).background(OrbStyle.surface, in: Capsule())
            .overlay(Capsule().stroke(OrbStyle.borderStrong))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("dictation.capsule")
            if dictation.phase == .recording {
                Text("\(Int(dictation.elapsed) / 60):\(String(format: "%02d", Int(dictation.elapsed) % 60)) · Tap to transcribe")
                    .font(.caption2).foregroundStyle(OrbStyle.textSecondary).monospacedDigit()
            }
            if !dictation.error.isEmpty {
                Text(dictation.error).font(.caption).foregroundStyle(OrbStyle.textSecondary)
                if dictation.microphoneDenied {
                    Button("Open microphone settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }.font(.caption)
                }
            }
        }
    }
}

struct OrbDictationButton: View {
    @Bindable var dictation: OrbDictation
    @Binding var text: String
    var onStart: () -> Void
    var onComplete: () -> Void
    @AppStorage("orb.dictationLanguage") private var language = Locale.current.language.languageCode?.identifier ?? "en"
    var body: some View {
        Button {
            onStart()
            let code = OrbDictation.languages.contains(where: { $0.0 == language }) ? language : "en"
            dictation.start(language: code) { transcript in
                text += (text.isEmpty || text.last?.isWhitespace == true ? "" : " ") + transcript
                onComplete()
            }
        } label: {
            Image(systemName: "mic").font(.system(size: 18)).foregroundStyle(OrbStyle.textSecondary).frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dictate message")
        .accessibilityHint("Touch and hold to choose the language. Current language: \(language)")
        .accessibilityIdentifier("dictation.microphone")
        .contextMenu {
            ForEach(OrbDictation.languages, id: \.0) { code, label in
                Button { language = code } label: {
                    if language == code { Label(label, systemImage: "checkmark") } else { Text(label) }
                }
            }
        }
    }
}
