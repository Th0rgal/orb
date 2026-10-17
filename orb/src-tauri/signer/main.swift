// orb-signer: Secure Enclave approval key for Orb.
//
// The private key never leaves the Secure Enclave. Its encrypted handle
// (`dataRepresentation`) is stored in a 0600 file and is useless on any
// other Mac. Every signature requires Touch ID with the currently enrolled
// fingers (`.biometryCurrentSet`): adding a finger invalidates the key.
//
//   orb-signer create --key PATH          -> {"public_key": "<base64 SPKI DER>"}
//   orb-signer public --key PATH          -> {"public_key": ...}
//   orb-signer sign --key PATH --reason R -> stdin payload, {"signature": "<base64 DER>"}
//   orb-signer serve --key PATH           -> one base64 payload per stdin line,
//                                            one JSON reply per line
//
// `serve` keeps a Touch ID-authenticated context for GRACE seconds, so
// approvals in quick succession need one fingerprint. The context is
// invalidated when the grace ends; the key still never leaves the enclave.
import CryptoKit
import Foundation
import LocalAuthentication

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func emit(_ object: [String: String]) {
    let data = try! JSONSerialization.data(withJSONObject: object)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

let args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
guard let command = args.first else { fail("usage: orb-signer create|public|sign --key PATH") }
guard let keyPath = option("--key") else { fail("--key is required") }
let keyURL = URL(fileURLWithPath: keyPath)
guard SecureEnclave.isAvailable else { fail("Secure Enclave is not available on this Mac", code: 3) }

func loadKey(context: LAContext? = nil) -> SecureEnclave.P256.Signing.PrivateKey {
    guard let blob = try? Data(contentsOf: keyURL) else { fail("No approval key at \(keyPath)", code: 4) }
    do {
        return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob, authenticationContext: context)
    } catch {
        fail("Approval key is unusable (Touch ID fingers changed?): \(error)", code: 5)
    }
}

struct SignError: Error { let message: String; let code: Int32 }

/// Sign one Paloma approval payload. A held, already-authenticated context
/// signs without prompting; otherwise Touch ID shows the payload's summary.
func sign(_ payload: Data, context held: LAContext?) -> Result<(String, LAContext), SignError> {
    // Show the summary Core wrote into the signed payload (its last line), not
    // text from the caller: what Touch ID describes is exactly what gets signed.
    guard let text = String(data: payload, encoding: .utf8), text.hasPrefix("paloma-approval-v1\n"),
          let summary = text.split(separator: "\n", omittingEmptySubsequences: false).last, !summary.isEmpty
    else { return .failure(SignError(message: "Not a Paloma approval payload", code: 1)) }
    let context = held ?? LAContext()
    if held == nil {
        context.localizedCancelTitle = "Cancel"
        let semaphore = DispatchSemaphore(value: 0)
        var authError: Error?
        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: String(summary)) { ok, error in
            if !ok { authError = error ?? NSError(domain: "orb-signer", code: 1) }
            semaphore.signal()
        }
        semaphore.wait()
        if let authError {
            let code = (authError as? LAError)?.code
            return .failure(SignError(message: "Touch ID: \(authError.localizedDescription)", code: code == .userCancel || code == .appCancel ? 2 : 1))
        }
    }
    guard let blob = try? Data(contentsOf: keyURL),
          let key = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob, authenticationContext: context)
    else { return .failure(SignError(message: "Approval key is unusable (Touch ID fingers changed?)", code: 5)) }
    do {
        return .success((try key.signature(for: payload).derRepresentation.base64EncodedString(), context))
    } catch {
        return .failure(SignError(message: "Signing failed: \(error)", code: 1))
    }
}

switch command {
case "create":
    var cfError: Unmanaged<CFError>?
    guard let access = SecAccessControlCreateWithFlags(
        nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .biometryCurrentSet], &cfError
    ) else { fail("Access control: \(String(describing: cfError))") }
    do {
        let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
        try FileManager.default.createDirectory(at: keyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: keyPath, contents: key.dataRepresentation, attributes: [.posixPermissions: 0o600])
        emit(["public_key": key.publicKey.derRepresentation.base64EncodedString()])
    } catch {
        fail("Could not create the Secure Enclave key: \(error)")
    }
case "public":
    emit(["public_key": loadKey().publicKey.derRepresentation.base64EncodedString()])
case "sign":
    let payload = FileHandle.standardInput.readDataToEndOfFile()
    switch sign(payload, context: nil) {
    case .success(let (signature, _)): emit(["signature": signature])
    case .failure(let error): fail(error.message, code: error.code)
    }
case "serve":
    let grace: TimeInterval = 300
    var held: (context: LAContext, at: Date)?
    while let line = readLine() {
        if let current = held, Date().timeIntervalSince(current.at) > grace {
            current.context.invalidate()
            held = nil
        }
        guard let payload = Data(base64Encoded: line.trimmingCharacters(in: .whitespaces)) else {
            emit(["error": "Invalid request", "code": "1"]); continue
        }
        switch sign(payload, context: held?.context) {
        case .success(let (signature, context)):
            if held == nil { held = (context, Date()) }
            emit(["signature": signature])
        case .failure(let error):
            held?.context.invalidate(); held = nil
            emit(["error": error.message, "code": String(error.code)])
        }
    }
default:
    fail("unknown command \(command)")
}
