/-
  OrbNetLeaf.SelfTest: Deterministic end-to-end test suite for `OrbNetLeaf`
  (AEAD `AES-256-GCM` & `ChaCha20-Poly1305` roundtrip + tamper rejection + 4096B AAD / 0B payload,
   `Ed25519` sign/verify + tamper rejection, role-separated `X25519` ECDH + empty-peer rejection,
   `FD_CLOEXEC` / `O_NONBLOCK` `openPty` + `resizePty` + bidirectional I/O,
   and outbound HTTP/1.1 wire builder, Content-Length validation, TLS truncation/EOF status framing,
   and curl HTTP/1.1 chunked fallback decoding).
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
  assertTrue "verifyAsymOp rejects empty peer key on X25519 ECDH (op = 4)"
    (verifyAsymOp 4 32 0 0 == 0)
  assertTrue "verifyOutboundRequest rejects CR/LF host"
    (verifyOutboundRequest 0 1 443 12 64 4096 == 0)
  assertTrue "verifyPtyWindow rejects zero rows and zero cols"
    (verifyPtyWindow 0 80 == 0 && verifyPtyWindow 24 0 == 0)

  -- 2. CSPRNG & AES-256-GCM + ChaCha20-Poly1305 AEAD roundtrip + tamper rejection + large-AAD 0-byte payload
  let .ok key ← randBytes 32 | throw (IO.userError "randBytes 32 failed")
  let .ok nonce ← randBytes 12 | throw (IO.userError "randBytes 12 failed")
  let aad := "orb-net-leaf-aad-v1".toUTF8
  let largeAad ← match (← randBytes 4096) with
    | .ok b => pure b
    | .error e => throw (IO.userError e)
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

    -- Empty plaintext with 4096-byte AAD roundtrip + tampered tag rejection (regression for AAD pointer offset)
    let .ok emptyCt ← aeadSeal alg key nonce largeAad ByteArray.empty
      | throw (IO.userError "empty aeadSeal with 4096B AAD failed")
    let .ok emptyPt ← aeadOpen alg key nonce largeAad emptyCt
      | throw (IO.userError "empty aeadOpen with 4096B AAD failed")
    assertTrue s!"{reprStr alg} 0-byte plaintext + 4096B AAD roundtrip" (emptyPt.isEmpty)
    let badEmpty := emptyCt.set! 0 (emptyCt.get! 0 ^^^ 0x01)
    let badEmptyOpen ← aeadOpen alg key nonce largeAad badEmpty
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

  -- 4. Role-separated X25519 symmetric ECDH key agreement + empty-peer rejection
  let .ok aliceSec ← randBytes 32 | throw (IO.userError "aliceSec failed")
  let .ok bobSec ← randBytes 32 | throw (IO.userError "bobSec failed")
  let .ok alicePub ← x25519PublicKey aliceSec | throw (IO.userError "alicePub failed")
  let .ok bobPub ← x25519PublicKey bobSec | throw (IO.userError "bobPub failed")
  let emptyPeerRes ← x25519SharedSecret aliceSec ByteArray.empty
  assertTrue "X25519 shared secret rejects empty peer key" emptyPeerRes.isOk.not
  let .ok sAB ← x25519SharedSecret aliceSec bobPub | throw (IO.userError "sAB failed")
  let .ok sBA ← x25519SharedSecret bobSec alicePub | throw (IO.userError "sBA failed")
  assertTrue "X25519 ECDH shared secrets match" (sAB == sBA && sAB.size == 32 && sAB != alicePub)

  -- 5. PTY allocation, window resize, and bidirectional fd roundtrip
  let .ok pty ← openPty 24 80 | throw (IO.userError "openPty failed")
  let .ok () ← resizePty pty.masterFd 40 120 | throw (IO.userError "resizePty failed")
  let _ ← LeanSys.Posix.writeAll pty.slaveFd ("pty-ok\n".toUTF8)
  let rd ← LeanSys.Posix.readStreamChunk pty.masterFd 64
  closePtyPair pty
  assertTrue "PTY master read non-empty slave payload" (!rd.isEmpty)

  -- 6. Outbound HTTP/1.1 smuggling, Content-Length mismatch, whitespace path, TLS truncation, and curl fallback checks
  let badHdrReq := buildOutboundHttp11Request "GET" "example.com" "/" #[("X-Inj", "ok\r\nEvil: 1")]
  assertTrue "Outbound HTTP builder rejects CR/LF header injection" badHdrReq.isOk.not
  let badSpacePath := buildOutboundHttp11Request "GET" "example.com" "/bad path HTTP/1.1"
  assertTrue "Outbound HTTP builder rejects whitespace in request target" badSpacePath.isOk.not
  let badClMismatch := buildOutboundHttp11Request "POST" "example.com" "/v1/chat" #[("Content-Length", "0")] ("hello".toUTF8)
  assertTrue "Outbound HTTP builder rejects mismatched Content-Length" badClMismatch.isOk.not
  let badClDup := buildOutboundHttp11Request "POST" "example.com" "/v1/chat"
    #[("Content-Length", "5"), ("Content-Length", "5")] ("hello".toUTF8)
  assertTrue "Outbound HTTP builder rejects duplicate Content-Length" badClDup.isOk.not
  let goodCl := buildOutboundHttp11Request "POST" "example.com" "/v1/chat" #[("Content-Length", "5")] ("hello".toUTF8)
  assertTrue "Outbound HTTP builder accepts matching Content-Length" goodCl.isOk

  let sampleChunked :=
    ("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Type: text/plain\r\n\r\n" ++
     "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n").toUTF8
  let .ok parsedResp := parseHttpResponseWire sampleChunked
    | throw (IO.userError "parseHttpResponseWire chunked failed")
  assertTrue "Chunked HTTP response decoded accurately"
    (parsedResp.status == 200 && parsedResp.body == "hello world".toUTF8)

  -- TLS status framing: cap exhaustion (`status = 2`) and unauthenticated close-delimited EOF (`status = 4`) fail closed
  let rawCloseDelim := ("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\npartial").toUTF8
  assertTrue "TLS cap exhaustion status (2) fails closed"
    (decodeTlsRoundtripWire (ByteArray.mk #[2] ++ rawCloseDelim) 4096).isOk.not
  assertTrue "TLS unauthenticated EOF (4) on close-delimited response fails closed"
    (decodeTlsRoundtripWire (ByteArray.mk #[4] ++ rawCloseDelim) 4096).isOk.not
  assertTrue "TLS authenticated close_notify (1) on close-delimited response succeeds"
    (decodeTlsRoundtripWire (ByteArray.mk #[1] ++ rawCloseDelim) 4096).isOk

  -- Curl HTTP/1.1 chunked fallback + trailer dump + 1xx informational + HEAD/304 bodyless checks
  let wire1xx :=
    ("HTTP/1.1 100 Continue\r\n\r\n" ++
     "HTTP/1.1 103 Early Hints\r\nLink: </app.js>; rel=preload\r\n\r\n" ++
     "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\ndone").toUTF8
  let .ok parsed1xx := parseHttpResponseWire wire1xx
    | throw (IO.userError "parseHttpResponseWire 1xx skip failed")
  assertTrue "HTTP wire parser skips 100/103 informational blocks"
    (parsed1xx.status == 200 && parsed1xx.body == "done".toUTF8)

  let wireHead := ("HTTP/1.1 200 OK\r\nContent-Length: 99999\r\n\r\n").toUTF8
  let .ok parsedHead := parseHttpResponseWire wireHead 4096 false "HEAD"
    | throw (IO.userError "parseHttpResponseWire HEAD failed")
  assertTrue "HEAD response with nonzero Content-Length succeeds with empty body"
    (parsedHead.status == 200 && parsedHead.body.isEmpty)

  let wire304 := ("HTTP/1.1 304 Not Modified\r\nContent-Length: 4096\r\n\r\n").toUTF8
  let .ok parsed304 := parseHttpResponseWire wire304 4096 false "GET"
    | throw (IO.userError "parseHttpResponseWire 304 failed")
  assertTrue "304 Not Modified response with nonzero Content-Length succeeds with empty body"
    (parsed304.status == 304 && parsed304.body.isEmpty)

  let wireTeSmuggle := ("HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip\r\nContent-Length: 5\r\n\r\nhello").toUTF8
  assertTrue "Transfer-Encoding: gzip with Content-Length rejected fail-closed"
    (parseHttpResponseWire wireTeSmuggle 4096 false "GET").isOk.not

  let curlHdrDump :=
    ("HTTP/1.1 100 Continue\r\n\r\n" ++
     "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nTrailer: X-Checksum\r\nContent-Type: application/json\r\n\r\n" ++
     "X-Checksum: abc123\r\n\r\n").toUTF8
  let curlDecodedBody := "{\"ok\":true}".toUTF8
  let .ok curlResp := parseCurlDumpHeadersAndBody curlHdrDump curlDecodedBody 4096 "GET"
    | throw (IO.userError "parseCurlDumpHeadersAndBody chunked+trailer fallback failed")
  assertTrue "Curl HTTP/1.1 chunked fallback with trailers preserves decoded body"
    (curlResp.status == 200 && curlResp.body == curlDecodedBody)

  let .ok curlHeadResp := parseCurlDumpHeadersAndBody wireHead ByteArray.empty 4096 "HEAD"
    | throw (IO.userError "parseCurlDumpHeadersAndBody HEAD failed")
  assertTrue "Curl HEAD response with nonzero Content-Length succeeds"
    (curlHeadResp.status == 200 && curlHeadResp.body.isEmpty)

  let wireHeadTe := ("HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip\r\nContent-Length: 99999\r\n\r\n").toUTF8
  let .ok parsedHeadTe := parseHttpResponseWire wireHeadTe 4096 false "HEAD"
    | throw (IO.userError "parseHttpResponseWire HEAD with Transfer-Encoding: gzip failed")
  assertTrue "HEAD response with Transfer-Encoding: gzip metadata succeeds with empty body"
    (parsedHeadTe.status == 200 && parsedHeadTe.body.isEmpty)

  let .ok curlHeadSmallCap := parseCurlDumpHeadersAndBody wireHead ("HTTP/1.1 200 OK\r\n".toUTF8) 4 "HEAD"
    | throw (IO.userError "parseCurlDumpHeadersAndBody HEAD small maxBodyBytes failed")
  assertTrue "Curl HEAD response ignores non-body stdout bytes before maxBodyBytes check"
    (curlHeadSmallCap.status == 200 && curlHeadSmallCap.body.isEmpty)

  IO.println "[OrbNetLeaf] ALL SELF-TESTS PASSED"
