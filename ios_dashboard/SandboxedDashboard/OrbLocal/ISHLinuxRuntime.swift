import CryptoKit
import Foundation
import OrbLocalKit

/// `UnixRuntime` backed by the in-process iSH ARM64 interpreter
/// (see OrbLinuxBridge.h). Persistent state lives in Application Support:
///   OrbLinux/root      — fakefs Alpine aarch64 root (meta.db + data/)
///   OrbLinux/work      — workspaces, bind-mounted at /root/work
/// Both survive app termination; the guest kernel itself does not, which is
/// why the runner checkpoints native harness sessions between turns.
final class ISHLinuxRuntime: UnixRuntime, @unchecked Sendable {
    static let shared = ISHLinuxRuntime()
    static let rootfsVersion = "alpine-3.21-aarch64"
    /// Pinned Alpine minirootfs; Orb downloads it on first use and verifies the
    /// SHA-256 before import. Downloading a base OS image is data, not code
    /// that changes Orb's features (App Review 2.5.2 is about the app binary).
    static let rootfsURL = URL(string: "https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/aarch64/alpine-minirootfs-3.21.0-aarch64.tar.gz")!
    static let rootfsSHA256 = "f31202c4070c4ef7de9e157e1bd01cb4da3a2150035d74ea5372c5e86f1efac1"

    private let lock = NSLock()
    private var bootError: String?
    private var booted = false
    private var processes: [Int32: ISHProcess] = [:]

    let base: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("OrbLinux", isDirectory: true)
    var root: URL { base.appendingPathComponent("root", isDirectory: true) }
    var work: URL { base.appendingPathComponent("work", isDirectory: true) }
    var linked: Bool { orb_linux_linked() == 1 }
    var installed: Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent("meta.db").path) }

    private init() {}

    func status() async -> RuntimeStatus {
        guard linked else {
            return RuntimeStatus(available: false, engine: "none", detail: "This Orb build does not include the on-device Linux runtime (ORB_WITH_ISH).")
        }
        guard installed else {
            return RuntimeStatus(available: false, engine: "ish-arm64", detail: "Linux userland not installed yet. Install it from Settings → This iPhone.")
        }
        if let bootError = lock.withLock({ bootError }) {
            return RuntimeStatus(available: false, engine: "ish-arm64", detail: "Linux runtime failed to boot: \(bootError)")
        }
        return RuntimeStatus(available: true, engine: "ish-arm64", detail: "Alpine aarch64 on iSH ARM64 threaded-code interpreter (no JIT)",
                             shell: true, pty: true, processes: true, sockets: true)
    }

    /// Download + verify + import the root filesystem. Idempotent.
    func install(progress: @escaping @MainActor (String) -> Void) async throws {
        guard linked else { throw HarnessError.runtimeUnavailable("Linux runtime is not linked into this build") }
        if installed { return }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        await progress("Downloading Alpine Linux…")
        let (file, _) = try await URLSession.shared.download(from: Self.rootfsURL)
        let digest = SHA256.hash(data: try Data(contentsOf: file, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
        guard digest == Self.rootfsSHA256 else {
            try? FileManager.default.removeItem(at: file)
            throw HarnessError.runtimeUnavailable("Downloaded root filesystem failed verification")
        }
        let archive = base.appendingPathComponent("rootfs.tar.gz")
        try? FileManager.default.removeItem(at: archive)
        try FileManager.default.moveItem(at: file, to: archive)
        defer { try? FileManager.default.removeItem(at: archive) }
        await progress("Importing root filesystem…")
        try? FileManager.default.removeItem(at: root)
        var error: UnsafeMutablePointer<CChar>?
        let code = orb_linux_import_rootfs(archive.path, root.path, &error)
        if code != 0 {
            let message = error.map { String(cString: $0) } ?? "error \(code)"
            free(error)
            throw HarnessError.runtimeUnavailable(message)
        }
        try await bootIfNeeded()
        await progress("Installing git, Node.js and certificates…")
        let setup = try await run("apk update && apk add --no-progress git nodejs npm ca-certificates openssh-client curl", cwd: "/root", timeout: 1800)
        if setup.code != 0 { throw HarnessError.runtimeUnavailable("apk failed: \(setup.output.suffix(400))") }
        await progress("Linux runtime ready")
    }

    func bootIfNeeded() async throws {
        if lock.withLock({ booted }) { return }
        guard linked, installed else { throw HarnessError.runtimeUnavailable("Linux runtime not installed") }
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let code = orb_linux_boot(root.path, work.path)
        if code != 0 {
            lock.withLock { bootError = "boot error \(code)" }
            throw HarnessError.runtimeUnavailable("Linux runtime failed to boot (\(code))")
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        orb_linux_set_exit_callback({ pid, status, context in
            guard let context else { return }
            Unmanaged<ISHLinuxRuntime>.fromOpaque(context).takeUnretainedValue().exited(pid: pid, status: status)
        }, context)
        lock.withLock { booted = true }
    }

    private func exited(pid: Int32, status: Int32) {
        let process = lock.withLock { processes.removeValue(forKey: pid) }
        // Wait status: exit code in bits 8–15, terminating signal in bits 0–6.
        process?.finish(code: status & 0x7f != 0 ? 128 + (status & 0x7f) : (status >> 8) & 0xff)
    }

    func launch(_ spec: LaunchSpec) async throws -> RuntimeProcess {
        try await bootIfNeeded()
        for (path, contents) in spec.files {
            let host = guestToHost(path)
            try FileManager.default.createDirectory(at: host.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: host, atomically: true, encoding: .utf8)
        }
        let argv = [spec.executable] + spec.arguments
        let env = spec.environment.map { "\($0.key)=\($0.value)" }
        var stdinFD: Int32 = -1, stdoutFD: Int32 = -1, stderrFD: Int32 = -1
        let pid: Int32 = withCStrings(argv) { a in
            withCStrings(env) { e in orb_linux_spawn(spec.workingDirectory, a, e, &stdinFD, &stdoutFD, &stderrFD) }
        }
        if pid < 0 { throw HarnessError.runtimeUnavailable("spawn \(spec.executable) failed (\(pid))") }
        let process = ISHProcess(pid: pid, stdin: stdinFD, stdout: stdoutFD, stderr: stderrFD)
        lock.withLock { processes[pid] = process }
        return process
    }

    func run(_ command: String, cwd: String?, timeout: TimeInterval) async throws -> (code: Int32, output: String) {
        let process = try await launch(LaunchSpec(executable: "/bin/sh", arguments: ["-lc", command], workingDirectory: cwd ?? "/root"))
        let collector = Task { () -> String in
            var out = ""
            for await line in process.lines { out += line + "\n" }
            return out
        }
        let errors = Task { () -> String in
            var out = ""
            for await line in process.stderrLines { out += line + "\n" }
            return out
        }
        let watchdog = Task { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)); await process.signal(9) }
        let code = await process.waitForExit()
        watchdog.cancel()
        return (code, await collector.value + (await errors.value))
    }

    /// Workspaces live on the host side of the `/root/work` bind mount.
    func guestToHost(_ path: String) -> URL {
        if path.hasPrefix("/root/work/") { return work.appendingPathComponent(String(path.dropFirst("/root/work/".count))) }
        return root.appendingPathComponent("data").appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path)
    }
}

private func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafePointer<CChar>?>) -> R) -> R {
    let duplicated = strings.map { strdup($0) }
    defer { duplicated.forEach { free($0) } }
    var pointers: [UnsafePointer<CChar>?] = duplicated.map { UnsafePointer($0) }
    pointers.append(nil)
    return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
}

/// Host-side view of one guest process: pipe fds + exit status.
final class ISHProcess: RuntimeProcess, @unchecked Sendable {
    let pid: Int32
    private let stdinHandle: FileHandle
    let lines: AsyncStream<String>
    let stderrLines: AsyncStream<String>
    private let lock = NSLock()
    private var exitCode: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []

    init(pid: Int32, stdin: Int32, stdout: Int32, stderr: Int32) {
        self.pid = pid
        stdinHandle = FileHandle(fileDescriptor: stdin, closeOnDealloc: true)
        lines = Self.lineStream(fd: stdout)
        stderrLines = Self.lineStream(fd: stderr)
    }

    private static func lineStream(fd: Int32) -> AsyncStream<String> {
        AsyncStream { continuation in
            Thread.detachNewThread {
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                var buffer = Data()
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        continuation.yield(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
                        buffer.removeSubrange(buffer.startIndex...newline)
                    }
                    // Bound memory if a process never prints a newline.
                    if buffer.count > 4 << 20 { continuation.yield(String(decoding: buffer, as: UTF8.self)); buffer.removeAll() }
                }
                if !buffer.isEmpty { continuation.yield(String(decoding: buffer, as: UTF8.self)) }
                continuation.finish()
            }
        }
    }

    func write(_ data: Data) async throws { try stdinHandle.write(contentsOf: data) }
    func closeInput() async { try? stdinHandle.close() }
    func signal(_ signal: Int32) async { _ = orb_linux_kill(pid, signal) }

    func finish(code: Int32) {
        let pending: [CheckedContinuation<Int32, Never>] = lock.withLock {
            exitCode = code
            defer { waiters.removeAll() }
            return waiters
        }
        pending.forEach { $0.resume(returning: code) }
    }

    func waitForExit() async -> Int32 {
        await withCheckedContinuation { continuation in
            let code: Int32? = lock.withLock {
                if let exitCode { return exitCode }
                waiters.append(continuation)
                return nil
            }
            if let code { continuation.resume(returning: code) }
        }
    }
}
