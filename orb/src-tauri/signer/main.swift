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
    // Show the summary Core wrote into the signed payload (its last line), not
    // text from the caller: what Touch ID describes is exactly what gets signed.
    guard let text = String(data: payload, encoding: .utf8), text.hasPrefix("paloma-approval-v1\n"),
          let summary = text.split(separator: "\n", omittingEmptySubsequences: false).last, !summary.isEmpty
    else { fail("Not a Paloma approval payload") }
    let reason = String(summary)
    let context = LAContext()
    context.localizedCancelTitle = "Cancel"
    let semaphore = DispatchSemaphore(value: 0)
    var authError: Error?
    context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { ok, error in
        if !ok { authError = error ?? NSError(domain: "orb-signer", code: 1) }
        semaphore.signal()
    }
    semaphore.wait()
    if let authError {
        let cancelled = (authError as? LAError)?.code == .userCancel || (authError as? LAError)?.code == .appCancel
        fail("Touch ID: \(authError.localizedDescription)", code: cancelled ? 2 : 1)
    }
    do {
        let signature = try loadKey(context: context).signature(for: payload)
        emit(["signature": signature.derRepresentation.base64EncodedString()])
    } catch {
        fail("Signing failed: \(error)")
    }
default:
    fail("unknown command \(command)")
}
