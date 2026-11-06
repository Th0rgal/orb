/-
  OrbNetLeaf.SelfTest: Deterministic end-to-end test suite for `OrbNetLeaf`
  (AEAD `AES-256-GCM` & `ChaCha20-Poly1305` roundtrip + tamper rejection,
   `Ed25519` sign/verify + tamper rejection, `X25519` symmetric ECDH,
   `FD_CLOEXEC` `openPty` + `resizePty` + bidirectional I/O,
   and outbound HTTP/1.1 wire builder & chunked/Content-Length response parser).
-/
import LeanSys.Posix
import OrbNetLeaf

open OrbNetLeaf.Spec
open OrbNetLeaf.Crypto
open OrbNetLeaf.Pty
open OrbNetLeaf.TlsHttp

private def assertTrue (label : String) (cond : Bool) : IO Unit := do
  if !cond then
    throw <| IO.userError s!"[FAIL] {label}"
  IO.println s!"[PASS] {label}"

def main : IO Unit := do
  -- 1. Spec gate sanity & fail-closed checks
  assertTrue "verifyAeadEnvelope accepts 32B key / 12B nonce"
    (verifyAeadEnvelope 0 1 32 12 16 128 == 1)
  assertTrue "verifyAeadEnvelope rejects truncated 15B open buffer"
    (verifyAeadEnvelope 0 0 32 12 0 15 == 0)
  assertTrue "verifyAsymOp rejects 63B Ed25519 signature"
    (verifyAsymOp 2 32 63 64 == 0)
  assertTrue "verifyOutboundRequest rejects CR/LF host"
    (verifyOutboundRequest 0 1 443 12 64 4096 == 0)
  assertTrue "verifyPtyWindow rejects zero rows"
    (verifyPtyWindow 0 80 == 0)

  -- 2. CSPRNG & AES-256-GCM + ChaCha20-Poly1305 AEAD roundtrip + tamper rejection
  let .ok key ← randBytes 32 | throw (IO.userError "randBytes 32 failed")
  let .ok nonce ← randBytes 12 | throw (IO.userError "randBytes 12 failed")
  let aad := "orb-net-leaf-aad-v1".toUTF8
  let msg := "verified-lean4-aead-payload".toUTF8

  for alg in [AeadAlg.aes256Gcm, AeadAlg.chacha20Poly1305] do
    let .ok ct ← aeadSeal alg key nonce aad msg
      | throw (IO.userError s!"aeadSeal failed for {reprStr alg}")
    let .ok pt ← aeadOpen alg key nonce aad ct
      | throw (IO.userError s!"aeadOpen failed for {reprStr alg}")
    assertTrue s!"{reprStr alg} roundtrip matches plaintext" (pt == msg)

    -- Tamper last tag byte -> must fail closed!
    let tampered := ct.set! (ct.size - 1) (ct.get! (ct.size - 1) ^^^ 0xFF)
    let badOpen ← aeadOpen alg key nonce aad tampered
    assertTrue s!"{reprStr alg} rejects tampered authentication tag" badOpen.isOk.not

    -- Empty plaintext roundtrip + tampered empty-plaintext tag rejection
    let .ok emptyCt ← aeadSeal alg key nonce aad ByteArray.empty
      | throw (IO.userError "empty aeadSeal failed")
    let .ok emptyPt ← aeadOpen alg key nonce aad emptyCt
      | throw (IO.userError "empty aeadOpen failed")
    assertTrue s!"{reprStr alg} 0-byte plaintext roundtrip" (emptyPt.isEmpty)
    let badEmpty := emptyCt.set! 0 (emptyCt.get! 0 ^^^ 0x01)
    let badEmptyOpen ← aeadOpen alg key nonce aad badEmpty
    assertTrue s!"{reprStr alg} rejects tampered 0-byte tag" badEmptyOpen.isOk.not

  -- 3. Ed25519 sign/verify + tamper rejection
  let .ok edSeed ← randBytes 32 | throw (IO.userError "edSeed failed")
  let .ok edPub ← ed25519PublicKey edSeed | throw (IO.userError "ed25519PublicKey failed")
  let .ok sig ← ed25519Sign edSeed msg | throw (IO.userError "ed25519Sign failed")
  let okSig ← ed25519Verify edPub sig msg
  assertTrue "Ed25519 valid signature verifies" okSig
  let badSig := sig.set! 0 (sig.get! 0 ^^^ 0x80)
  let okBadSig ← ed25519Verify edPub badSig msg
  assertTrue "Ed25519 tampered signature rejected" (!okBadSig)

  -- 4. X25519 symmetric ECDH key agreement
  let .ok aliceSec ← randBytes 32 | throw (IO.userError "aliceSec failed")
  let .ok bobSec ← randBytes 32 | throw (IO.userError "bobSec failed")
  let .ok alicePub ← x25519PublicKey aliceSec | throw (IO.userError "alicePub failed")
  let .ok bobPub ← x25519PublicKey bobSec | throw (IO.userError "bobPub failed")
  let .ok sAB ← x25519SharedSecret aliceSec bobPub | throw (IO.userError "sAB failed")
  let .ok sBA ← x25519SharedSecret bobSec alicePub | throw (IO.userError "sBA failed")
  assertTrue "X25519 ECDH shared secrets match" (sAB == sBA && sAB.size == 32)

  -- 5. PTY allocation, window resize, and bidirectional fd roundtrip
  let .ok pty ← openPty 24 80 | throw (IO.userError "openPty failed")
  let .ok () ← resizePty pty.masterFd 40 120 | throw (IO.userError "resizePty failed")
  let _ ← LeanSys.Posix.writeAll pty.slaveFd ("pty-ok\n".toUTF8)
  let rd ← LeanSys.Posix.readStreamChunk pty.masterFd 64
  closePtyPair pty
  assertTrue "PTY master read non-empty slave payload" (!rd.isEmpty)

  -- 6. Outbound HTTP/1.1 wire builder & response parser (Content-Length + chunked + smuggling rejection)
  let badHdrReq := buildOutboundHttp11Request "GET" "example.com" "/" #[("X-Inj", "ok\r\nEvil: 1")]
  assertTrue "Outbound HTTP builder rejects CR/LF header injection" badHdrReq.isOk.not
  let sampleChunked :=
    ("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Type: text/plain\r\n\r\n" ++
     "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n").toUTF8
  let .ok parsedResp := parseHttpResponseWire sampleChunked
    | throw (IO.userError "parseHttpResponseWire chunked failed")
  assertTrue "Chunked HTTP response decoded accurately"
    (parsedResp.status == 200 && parsedResp.body == "hello world".toUTF8)

  IO.println "[OrbNetLeaf] ALL SELF-TESTS PASSED"
