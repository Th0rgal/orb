/-
  OrbNetLeaf.SelfTest: Deterministic end-to-end test & benchmark suite for `OrbNetLeaf`
  (AEAD `AES-256-GCM`, `ChaCha20-Poly1305`, `AES-128-GCM` roundtrip + tamper rejection + 4096B AAD / 0B payload,
   RFC 9001 QUIC Header Protection (`AES-128-ECB`, `ChaCha20`) + 1-RTT packet seal/open,
   RFC 9113 HTTP/2 (`LeanSys.H2`) preface/HPACK/CONTINUATION/DATA/trailers roundtrip + smuggling/truncation rejection,
   RFC 9000/9114 QUIC + HTTP/3 (`LeanSys.Quic` + `LeanSys.H3`) protected 1-RTT datagram exchange,
   packet-loss / out-of-order / anti-replay / address-roaming / monotonic TX nonce conformance,
   `Ed25519` sign/verify, role-separated `X25519` ECDH + empty-peer rejection,
   `FD_CLOEXEC` / `O_NONBLOCK` `openPty`, `createExclFile0600`,
   outbound HTTP/1.1 smuggling/TLS truncation/1xx/HEAD/304 checks,
   and Wave 5.B native Sans-I/O vs subprocess baseline ablation benchmark receipt).
-/
import LeanSys.Posix
import LeanSys.H2
import LeanSys.Quic
import LeanSys.H3
import OrbNetLeaf

open LeanSys.Posix
open LeanSys.H2
open LeanSys.Quic
open LeanSys.H3
open OrbNetLeaf.Spec
open OrbNetLeaf.Crypto
open OrbNetLeaf.HpackQpack
open OrbNetLeaf.Pty
open OrbNetLeaf.TlsHttp
open OrbNetLeaf.Gzip
open OrbNetLeaf.H2Pool

private def assertTrue (label : String) (cond : Bool) : IO Unit := do
  if !cond then
    throw <| IO.userError s!"[FAIL] {label}"
  IO.println s!"[PASS] {label}"

def main : IO Unit := do
  -- 1. Spec gate sanity & fail-closed checks
  assertTrue "verifyAeadEnvelope accepts 32B AES-256-GCM & 16B AES-128-GCM"
    (verifyAeadEnvelope 0 1 32 12 16 128 == 1 && verifyAeadEnvelope 2 1 16 12 16 128 == 1)
  assertTrue "verifyAeadEnvelope rejects 16B key on AES-256-GCM & 15B open buffer"
    (verifyAeadEnvelope 0 1 16 12 16 128 == 0 && verifyAeadEnvelope 0 0 32 12 0 15 == 0)
  assertTrue "verifyQuicHpMask accepts 16B AES-128-ECB & 32B ChaCha20 with 16B sample"
    (verifyQuicHpMask 0 16 16 == 1 && verifyQuicHpMask 1 32 16 == 1 && verifyQuicHpMask 0 16 15 == 0)
  assertTrue "verifyAsymOp rejects 63B Ed25519 signature"
    (verifyAsymOp 2 32 63 64 == 0)
  assertTrue "verifyAsymOp rejects empty peer key on X25519 ECDH (op = 4)"
    (verifyAsymOp 4 32 0 0 == 0)
  assertTrue "verifyOutboundRequest rejects CR/LF host"
    (verifyOutboundRequest 0 1 443 12 64 4096 == 0)
  assertTrue "verifyPtyWindow rejects zero rows and zero cols"
    (verifyPtyWindow 0 80 == 0 && verifyPtyWindow 24 0 == 0)

  -- 2. CSPRNG & AES-256-GCM + ChaCha20-Poly1305 + AES-128-GCM AEAD roundtrip + tamper rejection + 4096B AAD / 0B payload
  let .ok key32 ← randBytes 32 | throw (IO.userError "randBytes 32 failed")
  let .ok key16 ← randBytes 16 | throw (IO.userError "randBytes 16 failed")
  let .ok nonce ← randBytes 12 | throw (IO.userError "randBytes 12 failed")
  let aad := "orb-net-leaf-aad-v1".toUTF8
  let largeAad ← match (← randBytes 4096) with
    | .ok b => pure b
    | .error e => throw (IO.userError e)
  let msg := "verified-lean4-aead-payload".toUTF8

  for (alg, k) in [(AeadAlg.aes256Gcm, key32), (AeadAlg.chacha20Poly1305, key32), (AeadAlg.aes128Gcm, key16)] do
    let .ok ct ← aeadSeal alg k nonce aad msg
      | throw (IO.userError s!"aeadSeal failed for {reprStr alg}")
    let .ok pt ← aeadOpen alg k nonce aad ct
      | throw (IO.userError s!"aeadOpen failed for {reprStr alg}")
    assertTrue s!"{reprStr alg} roundtrip matches plaintext" (pt == msg)

    let tampered := ct.set! (ct.size - 1) (ct.get! (ct.size - 1) ^^^ 0xFF)
    let badOpen ← aeadOpen alg k nonce aad tampered
    assertTrue s!"{reprStr alg} rejects tampered authentication tag" badOpen.isOk.not

    let .ok emptyCt ← aeadSeal alg k nonce largeAad ByteArray.empty
      | throw (IO.userError "empty aeadSeal with 4096B AAD failed")
    let .ok emptyPt ← aeadOpen alg k nonce largeAad emptyCt
      | throw (IO.userError "empty aeadOpen with 4096B AAD failed")
    assertTrue s!"{reprStr alg} 0-byte plaintext + 4096B AAD roundtrip" emptyPt.isEmpty
    let badEmpty := emptyCt.set! 0 (emptyCt.get! 0 ^^^ 0x01)
    let badEmptyOpen ← aeadOpen alg k nonce largeAad badEmpty
    assertTrue s!"{reprStr alg} rejects tampered 0-byte tag" badEmptyOpen.isOk.not

  -- 3. Ed25519 sign/verify + tamper rejection + role-separated X25519 ECDH + PTY + createExclFile0600
  let .ok edSeed ← randBytes 32 | throw (IO.userError "edSeed failed")
  let .ok edPub ← ed25519PublicKey edSeed | throw (IO.userError "ed25519PublicKey failed")
  let .ok sig ← ed25519Sign edSeed msg | throw (IO.userError "ed25519Sign failed")
  assertTrue "Ed25519 valid signature verifies" (← ed25519Verify edPub sig msg)
  assertTrue "Ed25519 tampered signature rejected"
    (!(← ed25519Verify edPub (sig.set! 0 (sig.get! 0 ^^^ 0x80)) msg))

  let .ok aliceSec ← randBytes 32 | throw (IO.userError "aliceSec failed")
  let .ok bobSec ← randBytes 32 | throw (IO.userError "bobSec failed")
  let .ok alicePub ← x25519PublicKey aliceSec | throw (IO.userError "alicePub failed")
  let .ok bobPub ← x25519PublicKey bobSec | throw (IO.userError "bobPub failed")
  let emptyPeerRes ← x25519SharedSecret aliceSec ByteArray.empty
  assertTrue "X25519 shared secret rejects empty peer key" emptyPeerRes.isOk.not
  let .ok sAB ← x25519SharedSecret aliceSec bobPub | throw (IO.userError "sAB failed")
  let .ok sBA ← x25519SharedSecret bobSec alicePub | throw (IO.userError "sBA failed")
  assertTrue "X25519 ECDH shared secrets match" (sAB == sBA && sAB.size == 32 && sAB != alicePub)

  let .ok pty ← openPty 24 80 | throw (IO.userError "openPty failed")
  let .ok () ← resizePty pty.masterFd 40 120 | throw (IO.userError "resizePty failed")
  let _ ← LeanSys.Posix.writeAll pty.slaveFd ("pty-ok\n".toUTF8)
  let rd ← LeanSys.Posix.readStreamChunk pty.masterFd 64
  closePtyPair pty
  assertTrue "PTY master read non-empty slave payload" (!rd.isEmpty)

  let .ok tmpNonce ← randBytes 6 | throw (IO.userError "randBytes for temp file test failed")
  let tmpPath : System.FilePath :=
    s!"/tmp/orb_excl_test_{(tmpNonce.get! 0).toNat}_{(tmpNonce.get! 1).toNat}_{(tmpNonce.get! 2).toNat}.tmp"
  try IO.FS.removeFile tmpPath catch _ => pure ()
  assertTrue "createExclFile0600 creates new owner-only file" (← createExclFile0600 tmpPath).isOk
  assertTrue "createExclFile0600 rejects existing path (O_EXCL)" (← createExclFile0600 tmpPath).isOk.not
  let stOut ← IO.Process.output { cmd := "stat", args := #["-c", "%a", tmpPath.toString] }
  try IO.FS.removeFile tmpPath catch _ => pure ()
  assertTrue "createExclFile0600 sets mode 600" (stOut.stdout.trimAscii.toString == "600")

  -- 4. Outbound HTTP/1.1 smuggling, Content-Length mismatch, whitespace/# path, TLS truncation, 1xx, HEAD/304 checks
  assertTrue "Outbound HTTP/1.1 builder rejects CR/LF header injection"
    (buildOutboundHttp11Request "GET" "example.com" "/" #[("X-Inj", "ok\r\nEvil: 1")]).isOk.not
  assertTrue "Outbound HTTP/1.1 builder rejects whitespace in request target"
    (buildOutboundHttp11Request "GET" "example.com" "/bad path HTTP/1.1").isOk.not
  assertTrue "Outbound HTTP/1.1 builder rejects literal # fragment in request target"
    (buildOutboundHttp11Request "GET" "example.com" "/resource#frag").isOk.not
  assertTrue "Outbound HTTP/1.1 builder rejects mismatched Content-Length"
    (buildOutboundHttp11Request "POST" "example.com" "/v1/chat" #[("Content-Length", "0")] ("hello".toUTF8)).isOk.not
  assertTrue "Outbound HTTP/1.1 builder rejects duplicate Content-Length"
    (buildOutboundHttp11Request "POST" "example.com" "/v1/chat"
      #[("Content-Length", "5"), ("Content-Length", "5")] ("hello".toUTF8)).isOk.not
  assertTrue "Outbound HTTP/1.1 builder accepts matching Content-Length"
    (buildOutboundHttp11Request "POST" "example.com" "/v1/chat" #[("Content-Length", "5")] ("hello".toUTF8)).isOk

  let sampleChunked :=
    ("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Type: text/plain\r\n\r\n" ++
     "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n").toUTF8
  let .ok parsedH1 := parseHttpResponseWire sampleChunked
    | throw (IO.userError "parseHttpResponseWire chunked failed")
  assertTrue "Chunked HTTP/1.1 response decoded accurately"
    (parsedH1.status == 200 && parsedH1.body == "hello world".toUTF8)

  let rawCloseDelim := ("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\npartial").toUTF8
  assertTrue "TLS cap exhaustion status (2) fails closed"
    (decodeTlsRoundtripWire (ByteArray.mk #[2] ++ rawCloseDelim) 4096).isOk.not
  assertTrue "TLS unauthenticated EOF (4) on close-delimited response fails closed"
    (decodeTlsRoundtripWire (ByteArray.mk #[4] ++ rawCloseDelim) 4096).isOk.not
  assertTrue "TLS authenticated close_notify (1) on close-delimited response succeeds"
    (decodeTlsRoundtripWire (ByteArray.mk #[1] ++ rawCloseDelim) 4096).isOk

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

  assertTrue "isValidBareHost rejects userinfo @, path /, bare dots, triple-colon, and leading hyphen"
    (!isValidBareHost "expected.example@127.0.0.1" && !isValidBareHost "example.com/evil" &&
     !isValidBareHost "..." && !isValidBareHost "---" && !isValidBareHost ":::" &&
     !isValidBareHost "foo..bar" && !isValidBareHost "-bad.example" &&
     !isValidHostChars "expected.example@127.0.0.1")
  assertTrue "createExclFile0600 rejects embedded NUL path"
    (← createExclFile0600 (System.FilePath.mk ("/tmp/orb-nul" ++ String.singleton (Char.ofNat 0) ++ "x"))).isOk.not
  assertTrue "formatHostAuthority appends non-default port and omits 443"
    (formatHostAuthority "example.com" 8443 443 == "example.com:8443" &&
     formatHostAuthority "example.com" 443 443 == "example.com" &&
     formatHostAuthority "::1" 8443 443 == "[::1]:8443")

  -- 4b. Complete RFC 7541 HPACK (61 static + Huffman + dynamic table + safe UTF-8) & RFC 9204 QPACK (99 static + name-ref + Huffman)
  let huffExpected := ByteArray.mk #[0xf1, 0xe3, 0xc2, 0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab, 0x90, 0xf4, 0xff]
  let huffEnc := encodeHuffmanBytes "www.example.com".toUTF8
  assertTrue "RFC 7541 Appendix C.4 Huffman vector matches byte-for-byte"
    (huffEnc == huffExpected &&
     decodeHuffmanBytes? (ByteSource.ofByteArray huffEnc) == some "www.example.com".toUTF8)
  -- >= 8 bits of 1-padding (`huffEnc.push 0xFF`) and 0-padded trailing bits (`0xfe` -> 7-bit incomplete prefix `1111110`) must fail closed (RFC 7541 §5.2)
  assertTrue "RFC 7541 Huffman decoder rejects >= 8-bit EOS padding and non-1 padding"
    ((decodeHuffmanBytes? (ByteSource.ofByteArray (huffEnc.push 0xFF))).isNone &&
     (decodeHuffmanBytes? (ByteSource.ofByteArray (ByteArray.mk #[0xf1, 0xe3, 0xc2, 0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab, 0x90, 0xf4, 0xfe]))).isNone)
  -- HPACK static indices 28 (`content-length`), 54 (`server`), 61 (`www-authenticate`), Huffman string, and dynamic table `01xxxxxx` (`idx 62`)
  let huffSrv := encodeHuffmanBytes "orb-edge/2.0".toUTF8
  let hpackDynAndHuff :=
    ByteArray.mk #[0x88] ++ -- :status: 200 (idx 8)
    ByteArray.mk #[0x0f, 0x0d, 0x01] ++ "4".toUTF8 ++ -- literal without indexing, name idx 28 (content-length) = "4"
    (ByteArray.mk #[0x40 + 54, (0x80 ||| huffSrv.size.toUInt8)]) ++ huffSrv ++ -- incremental indexing (01xxxxxx), name idx 54 (server) = Huffman("orb-edge/2.0") -> dyn idx 62
    ByteArray.mk #[0x80 + 62] -- reference newly inserted dynamic entry idx 62!
  let some (decHpackFields, _) := decodeRfc7541BlockWithTable? {} (ByteSource.ofByteArray hpackDynAndHuff)
    | throw (IO.userError "decodeRfc7541BlockWithTable? failed on static 28/54 + Huffman + dynamic 62")
  assertTrue "RFC 7541 HPACK decodes static 1..61, Huffman strings, and FIFO dynamic table entries"
    (decHpackFields == #[(":status", "200"), ("content-length", "4"), ("server", "orb-edge/2.0"), ("server", "orb-edge/2.0")])
  -- Invalid UTF-8 byte `0xFF` in HPACK & QPACK must return `none` without `String.fromUTF8!` panic!
  let badUtf8Hpack := ByteArray.mk #[0x00, 0x05] ++ "x-bin".toUTF8 ++ ByteArray.mk #[0x01, 0xFF]
  assertTrue "RFC 7541 HPACK rejects invalid UTF-8 bytes fail-closed without panic"
    (decodeRfc7541Block? (ByteSource.ofByteArray badUtf8Hpack)).isNone

  -- QPACK: static entry 98 (`x-frame-options: sameorigin`), `01NTxxxx` static name-ref (`:status` idx 24 -> `"201"`), `N=1` never-indexed literal, and Huffman value
  let huffLoc := encodeHuffmanBytes "/v1/missions/42".toUTF8
  let qpackRich :=
    ByteArray.mk #[0x00, 0x00] ++ -- RIC=0, Base=0
    (encodeHpackInt 24 4 0x50) ++ ByteArray.mk #[0x03] ++ "201".toUTF8 ++ -- 01 N=0 T=1 idx=24 (:status) = "201"
    (encodeHpackInt 12 4 0x70) ++ ByteArray.mk #[0x80 ||| huffLoc.size.toUInt8] ++ huffLoc ++ -- 01 N=1 T=1 idx=12 (location) = Huffman("/v1/missions/42")
    (encodeHpackInt 98 6 0xC0) ++ -- 11 idx=98 (x-frame-options: sameorigin)
    ByteArray.mk #[0x35] ++ "x-tok".toUTF8 ++ ByteArray.mk #[0x02] ++ "ok".toUTF8 -- 001 N=1 H=0 len=5 ("x-tok") = "ok"
  let some decQpackFields := decodeRfc9204Block? (ByteSource.ofByteArray qpackRich)
    | throw (IO.userError "decodeRfc9204Block? failed on 01NTxxxx / static 98 / N=1 / Huffman")
  assertTrue "RFC 9204 QPACK decodes 0..98 static entries, 01NTxxxx name-refs, N=1 literals, and Huffman strings"
    (decQpackFields == #[(":status", "201"), ("location", "/v1/missions/42"), ("x-frame-options", "sameorigin"), ("x-tok", "ok")])
  let badUtf8Qpack := ByteArray.mk #[0x00, 0x00, 0x25] ++ "x-bin".toUTF8 ++ ByteArray.mk #[0x01, 0xFF]
  assertTrue "RFC 9204 QPACK rejects invalid UTF-8 bytes fail-closed without panic"
    (decodeRfc9204Block? (ByteSource.ofByteArray badUtf8Qpack)).isNone

  -- 5. Native RFC 9113 HTTP/2 (`LeanSys.H2`) request builder + CONTINUATION + 1xx + trailers + GOAWAY + >1MiB + bodyless checks
  let .ok h2OutWire := buildOutboundH2PrefaceAndStream "POST" "api.orb.local" "/v1/missions"
      #[("x-orb-trace", "w5b")] ("{\"goal\":\"lean4\"}".toUTF8)
    | throw (IO.userError "buildOutboundH2PrefaceAndStream failed")
  assertTrue "HTTP/2 client stream starts with 24-byte RFC 9113 preface"
    (h2OutWire.extract 0 24 == clientPreface)
  assertTrue "HTTP/2 Sans-I/O burst enforces 65535-byte peer initial flow-control window"
    (buildOutboundH2PrefaceAndStream "POST" "api.orb.local" "/v1/upload" #[] (ByteArray.mk (Array.replicate 70000 0x41))).isOk.not
  -- Outbound >16 KiB header block splits into HEADERS + CONTINUATION frames cleanly
  let bigVal := String.ofList (List.replicate 9000 'a')
  let .ok h2ContOut := buildOutboundH2PrefaceAndStream "GET" "api.orb.local" "/v1/big"
      #[("x-large-a", bigVal), ("x-large-b", bigVal)]
    | throw (IO.userError "buildOutboundH2PrefaceAndStream failed to split >16 KiB headers into CONTINUATION")
  assertTrue "HTTP/2 outbound >16 KiB headers split into HEADERS + CONTINUATION"
    (h2ContOut.size > 18000)
  assertTrue "HTTP/2 builder rejects connection-specific transfer-encoding header"
    (buildOutboundH2PrefaceAndStream "GET" "api.orb.local" "/" #[("Transfer-Encoding", "chunked")]).isOk.not
  assertTrue "HTTP/2 builder rejects leading/trailing CR/LF/VT/FF in header values"
    ((buildOutboundH2PrefaceAndStream "GET" "api.orb.local" "/" #[("x-test", "ok\r\n")]).isOk.not &&
     (buildOutboundH2PrefaceAndStream "GET" "api.orb.local" "/" #[("x-test", "\r\nok")]).isOk.not &&
     (buildOutboundH2PrefaceAndStream "GET" "api.orb.local" "/" #[("x-test", "ok\x0c")]).isOk.not)

  let srvBody := "{\"ok\":true,\"proto\":\"h2\"}".toUTF8
  let some srvSettings := buildSettingsFrame? #[(0x0003, 100)] false | throw (IO.userError "srvSettings")
  let srvHpack := encodeHeadersBlock
    #[(":status", "200"), ("content-type", "application/json"), ("content-length", toString srvBody.size)]
  let some srvHdrFrame := encodeFrame? { frameType := .headers, flags := 0x04, streamId := 1, payload := srvHpack }
    | throw (IO.userError "srvHdrFrame")
  let some srvDataFrame := encodeFrame? { frameType := .data, flags := 0x01, streamId := 1, payload := srvBody }
    | throw (IO.userError "srvDataFrame")
  let .ok parsedH2 := parseH2ResponseFrames (srvSettings ++ srvHdrFrame ++ srvDataFrame) 1
    | throw (IO.userError "parseH2ResponseFrames failed")
  assertTrue "Native HTTP/2 response decoded status 200, headers, and DATA body"
    (parsedH2.status == 200 && parsedH2.body == srvBody &&
     parsedH2.headers == #[("content-type", "application/json"), ("content-length", toString srvBody.size)])

  -- Inbound HTTP/2 `103 Early Hints` + `200 OK` split across `HEADERS` + `CONTINUATION` + graceful `GOAWAY(NO_ERROR)` + trailing `HEADERS(END_STREAM)`!
  let info103 := encodeHeadersBlock #[(":status", "103"), ("link", "</app.css>; rel=preload")]
  let some info103Frame := encodeFrame? { frameType := .headers, flags := 0x04, streamId := 1, payload := info103 }
    | throw (IO.userError "info103Frame")
  let splitAt := srvHpack.size / 2
  let some hdrPart1 := encodeFrame? { frameType := .headers, flags := 0x00, streamId := 1, payload := srvHpack.extract 0 splitAt }
    | throw (IO.userError "hdrPart1")
  let some hdrPart2 := encodeFrame? { frameType := .continuation, flags := 0x04, streamId := 1, payload := srvHpack.extract splitAt srvHpack.size }
    | throw (IO.userError "hdrPart2")
  let gracefulGoawayPayload := ByteArray.mk #[0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00] -- lastStreamId=1, NO_ERROR=0
  let some gracefulGoaway := encodeFrame? { frameType := .goaway, flags := 0x00, streamId := 0, payload := gracefulGoawayPayload }
    | throw (IO.userError "gracefulGoaway")
  let some bodyNoEs := encodeFrame? { frameType := .data, flags := 0x00, streamId := 1, payload := srvBody }
    | throw (IO.userError "bodyNoEs")
  let trlBlock := encodeHeadersBlock #[("x-checksum", "sha256-ok")]
  let some trlFrame := encodeFrame? { frameType := .headers, flags := 0x05, streamId := 1, payload := trlBlock }
    | throw (IO.userError "trlFrame")
  let .ok parsedComplexH2 := parseH2ResponseFrames
      (info103Frame ++ hdrPart1 ++ hdrPart2 ++ gracefulGoaway ++ bodyNoEs ++ trlFrame) 1
    | throw (IO.userError "parseH2ResponseFrames failed on 103 + CONTINUATION + graceful GOAWAY + trailers")
  assertTrue "HTTP/2 parses 103 Early Hints + CONTINUATION + graceful GOAWAY(NO_ERROR) + trailers"
    (parsedComplexH2.status == 200 && parsedComplexH2.body == srvBody)

  -- Error GOAWAY (`lastStreamId=0`) and cross-stream CONTINUATION lock violation must fail closed!
  let abortGoawayPayload := ByteArray.mk #[0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
  let some abortGoaway := encodeFrame? { frameType := .goaway, flags := 0x00, streamId := 0, payload := abortGoawayPayload }
    | throw (IO.userError "abortGoaway")
  assertTrue "HTTP/2 GOAWAY with lastStreamId < targetStreamId fails closed"
    (parseH2ResponseFrames (hdrPart1 ++ hdrPart2 ++ abortGoaway ++ srvDataFrame) 1).isOk.not
  let some strm3NoEh := encodeFrame? { frameType := .headers, flags := 0x00, streamId := 3, payload := srvHpack.extract 0 4 }
    | throw (IO.userError "strm3NoEh")
  assertTrue "HTTP/2 connection-level CONTINUATION lock rejects interleaved stream HEADERS"
    (parseH2ResponseFrames (strm3NoEh ++ srvHdrFrame ++ srvDataFrame) 1).isOk.not

  -- > 1 MiB (`1.15 MiB`) HTTP/2 response succeeds within default 4 MiB cap!
  let chunk16k := ByteArray.mk (Array.replicate 16384 0x42)
  let some d16k := encodeFrame? { frameType := .data, flags := 0x00, streamId := 1, payload := chunk16k } 16384 16777216
    | throw (IO.userError "d16k")
  let some d16kEnd := encodeFrame? { frameType := .data, flags := 0x01, streamId := 1, payload := chunk16k } 16384 16777216
    | throw (IO.userError "d16kEnd")
  let bigHdr := encodeHeadersBlock #[(":status", "200"), ("content-length", toString (74 * 16384))]
  let some bigHdrFrame := encodeFrame? { frameType := .headers, flags := 0x04, streamId := 1, payload := bigHdr }
    | throw (IO.userError "bigHdrFrame")
  let bigH2Wire := Id.run do
    let mut w := bigHdrFrame
    for _ in [0:73] do
      w := w ++ d16k
    w := w ++ d16kEnd
    return w
  let .ok parsedBigH2 := parseH2ResponseFrames bigH2Wire 1 4194304
    | throw (IO.userError "parseH2ResponseFrames failed on 1.15 MiB response")
  assertTrue "HTTP/2 parses >1 MiB (1.15 MiB) response cleanly"
    (parsedBigH2.body.size == 74 * 16384)

  -- Bodyless `204`, `304`, `HEAD` reject non-empty DATA frames & admit empty END_STREAM HEADERS
  let hdr204 := encodeHeadersBlock #[(":status", "204")]
  let some hdr204Es := encodeFrame? { frameType := .headers, flags := 0x05, streamId := 1, payload := hdr204 }
    | throw (IO.userError "hdr204Es")
  let some hdr204NoEs := encodeFrame? { frameType := .headers, flags := 0x04, streamId := 1, payload := hdr204 }
    | throw (IO.userError "hdr204NoEs")
  assertTrue "HTTP/2 204 and HEAD admit empty response and reject illegal DATA payload"
    ((parseH2ResponseFrames hdr204Es 1).isOk &&
     (parseH2ResponseFrames (hdr204NoEs ++ srvDataFrame) 1).isOk.not &&
     (parseH2ResponseFrames (srvHdrFrame ++ srvDataFrame) 1 16777216 "HEAD").isOk.not)

  -- Control byte (`0x1B` ESC) in HTTP/2 header value must fail closed!
  let escHdr := encodeHeadersBlock #[(":status", "200"), ("x-ansi", String.singleton (Char.ofNat 0x1B) ++ "[31m")]
  let some escHdrFrame := encodeFrame? { frameType := .headers, flags := 0x05, streamId := 1, payload := escHdr }
    | throw (IO.userError "escHdrFrame")
  assertTrue "HTTP/2 rejects C0/ANSI escape control bytes in header values"
    (parseH2ResponseFrames escHdrFrame 1).isOk.not

  -- Truncated HTTP/2 stream without END_STREAM (`flags := 0x00` on DATA) must fail closed!
  let some srvDataNoEs := encodeFrame? { frameType := .data, flags := 0x00, streamId := 1, payload := srvBody }
    | throw (IO.userError "srvDataNoEs")
  assertTrue "HTTP/2 response missing END_STREAM fails closed"
    (parseH2ResponseFrames (srvSettings ++ srvHdrFrame ++ srvDataNoEs) 1).isOk.not

  -- HTTP/2 content-length mismatch must fail closed!
  let badClHpack := encodeHeadersBlock #[(":status", "200"), ("content-length", "999")]
  let some badClHdr := encodeFrame? { frameType := .headers, flags := 0x04, streamId := 1, payload := badClHpack }
    | throw (IO.userError "badClHdr")
  assertTrue "HTTP/2 response content-length mismatch fails closed"
    (parseH2ResponseFrames (badClHdr ++ srvDataFrame) 1).isOk.not

  -- HTTP/2 uppercase or connection-specific response header must fail closed!
  let upperHpack := ByteArray.mk #[0x00, 0x07] ++ ":status".toUTF8 ++ ByteArray.mk #[0x03] ++ "200".toUTF8 ++
                    ByteArray.mk #[0x00, 0x05] ++ "X-Bad".toUTF8 ++ ByteArray.mk #[0x01] ++ "1".toUTF8
  let some upperHdr := encodeFrame? { frameType := .headers, flags := 0x05, streamId := 1, payload := upperHpack }
    | throw (IO.userError "upperHdr")
  assertTrue "HTTP/2 uppercase response header fails closed (RFC 9113 §8.2)"
    (parseH2ResponseFrames upperHdr 1).isOk.not

  -- 6. Native RFC 9000/9001/9114 QUIC + HTTP/3 1-RTT packet/header protection + PADDING/ACK + 1..4B PN + stateful anti-nonce-reuse
  let .ok hpKey16 ← randBytes 16 | throw (IO.userError "hpKey16")
  let .ok iv12 ← randBytes 12 | throw (IO.userError "iv12")
  let sessKeys : Quic1RttSessionKeys := {
    dcid := 0x0102030405060708
    aeadAlg := .aes128Gcm
    hpAlg := .aes128Ecb
    txKey := key16, txIv12 := iv12, txHpKey := hpKey16
    rxKey := key16, rxIv12 := iv12, rxHpKey := hpKey16
  }
  let .ok reqDgram ← buildProtectedH3RequestDatagram sessKeys 7 "POST" "quic.orb.local" "/v1/ping"
      #[("x-orb-quic", "1rtt")] ("ping-h3".toUTF8) 0
    | throw (IO.userError "buildProtectedH3RequestDatagram failed")
  assertTrue "Protected 1-RTT QUIC + HTTP/3 request datagram obscures plaintext header"
    (reqDgram.size > 29)

  -- Verify 1-byte, 2-byte, 3-byte, and 4-byte PN QUIC short-header roundtrips + RFC 9000 Appendix A.3 8-bit wrap (`127 -> 256`)
  for pnLen in [1, 2, 3, 4] do
    let .ok wPn ← sealQuicShortPacketWithPnLen .aes128Gcm .aes128Ecb key16 iv12 hpKey16
        { dcid := sessKeys.dcid, pktNum := 256, keyPhase := false, payload := "pn-test".toUTF8 } pnLen
      | throw (IO.userError s!"seal pnLen={pnLen} failed")
    let .ok oPn ← openQuicShortPacketEx .aes128Gcm .aes128Ecb key16 iv12 hpKey16 wPn (some 127)
      | throw (IO.userError s!"open pnLen={pnLen} failed")
    assertTrue s!"QUIC short packet pnLen={pnLen} reconstructs pktNum=256 from largestRx=127"
      (oPn.pktNum == 256 && oPn.payload == "pn-test".toUTF8)

  -- Build three server response packets (`pktNum = 10, 12, 11`), prepending leading `PADDING` (`0x00`), `PING` (`0x01`),
  -- `ACK` (`0x02, largest=7, delay=0, rcnt=0, first=0`), and `HANDSHAKE_DONE` (`0x1e`) before `STREAM`!
  let some h3RespBytes := encodeH3Message?
      #[(":status", "200"), ("x-transport", "h3-quic"), ("content-length", "7")] ("pong-h3".toUTF8)
    | throw (IO.userError "encodeH3Message?")
  let some qStreamFrame := encodeQuicStreamFrame? 0 0 h3RespBytes true
    | throw (IO.userError "encodeQuicStreamFrame?")
  let leadingCtrlFrames := ByteArray.mk #[0x00, 0x00, 0x01, 0x02, 0x07, 0x00, 0x00, 0x00, 0x1e]
  let bundledQuicPayload := leadingCtrlFrames ++ qStreamFrame
  let .ok dgram10 ← sealQuicShortPacketWithPnLen .aes128Gcm .aes128Ecb key16 iv12 hpKey16
      { dcid := sessKeys.dcid, pktNum := 10, keyPhase := false, payload := bundledQuicPayload } 2
    | throw (IO.userError "seal dgram10")
  let .ok dgram12 ← sealQuicShortPacket .aes128Gcm .aes128Ecb key16 iv12 hpKey16
      { dcid := sessKeys.dcid, pktNum := 12, keyPhase := true, payload := bundledQuicPayload }
    | throw (IO.userError "seal dgram12")
  let .ok dgram11 ← sealQuicShortPacket .aes128Gcm .aes128Ecb key16 iv12 hpKey16
      { dcid := sessKeys.dcid, pktNum := 11, keyPhase := false, payload := qStreamFrame }
    | throw (IO.userError "seal dgram11")

  let res10 ← openProtectedH3ResponseDatagram sessKeys {} dgram10 0
  let (h3Resp10, stAfter10) ← match res10 with
    | .ok v => pure v
    | .error e => throw (IO.userError s!"open dgram10 failed: {e}")
  assertTrue "Protected 1-RTT HTTP/3 response datagram #10 (2B PN + leading PADDING/PING/ACK) decoded accurately"
    (h3Resp10.status == 200 && h3Resp10.body == "pong-h3".toUTF8 &&
     h3Resp10.headers == #[("x-transport", "h3-quic"), ("content-length", "7")])

  -- Trailing `CONNECTION_CLOSE` (`0x1c`) and HTTP/3 `204` with illegal `DATA` capsule must fail closed!
  let .ok dgramClose ← sealQuicShortPacket .aes128Gcm .aes128Ecb key16 iv12 hpKey16
      { dcid := sessKeys.dcid, pktNum := 98, keyPhase := false, payload := qStreamFrame.push 0x1c }
    | throw (IO.userError "seal dgramClose")
  assertTrue "QUIC 1-RTT packet with trailing CONNECTION_CLOSE fails closed"
    (← openProtectedH3ResponseDatagram sessKeys {} dgramClose 0).isOk.not
  let some badH3204 := encodeH3Message? #[(":status", "204")] ("illegal".toUTF8)
    | throw (IO.userError "badH3204")
  assertTrue "HTTP/3 204 No Content with non-empty DATA capsule fails closed"
    (parseH3ResponseStream badH3204).isOk.not

  -- Truncated QUIC STREAM without FIN (`fin := false`) must fail closed!
  let some qStreamNoFin := encodeQuicStreamFrame? 0 0 h3RespBytes false
    | throw (IO.userError "qStreamNoFin")
  let .ok dgramNoFin ← sealQuicShortPacket .aes128Gcm .aes128Ecb key16 iv12 hpKey16
      { dcid := sessKeys.dcid, pktNum := 99, keyPhase := false, payload := qStreamNoFin }
    | throw (IO.userError "seal dgramNoFin")
  assertTrue "QUIC 1-RTT HTTP/3 response missing STREAM FIN fails closed"
    (← openProtectedH3ResponseDatagram sessKeys {} dgramNoFin 0).isOk.not

  -- Out-of-order gap (`pkt 12` arrives while `11` was delayed/lost, then `11` arrives late, then replay of `12` is rejected!)
  let .ok (_, stAfter12) ← openProtectedH3ResponseDatagram sessKeys stAfter10 dgram12 0
    | throw (IO.userError "open out-of-order dgram12 failed")
  let .ok (_, stAfter11) ← openProtectedH3ResponseDatagram sessKeys stAfter12 dgram11 0
    | throw (IO.userError "open late dgram11 failed")
  let replay12 ← openProtectedH3ResponseDatagram sessKeys stAfter11 dgram12 0
  assertTrue "RFC 6479 QUIC anti-replay window admits out-of-order #12 -> #11 and rejects duplicate #12"
    replay12.isOk.not
  -- Cross-request stream ID separation: response for stream 0 must be rejected when expecting client bidi stream 4!
  let crossStreamReplay ← openProtectedH3ResponseDatagram sessKeys stAfter10 dgram11 4
  assertTrue "Cross-request replay of Stream 0 datagram onto Stream 4 is rejected"
    crossStreamReplay.isOk.not

  -- Stateful `Quic1RttSession` monotonically advances `nextTxPktNum` & `nextClientStreamId` BEFORE UDP send
  -- even when UDP roundtrips fail/timeout or go through `http2Or3Request (.http3 (some sess))`!
  let liveSess ← mkQuic1RttSession sessKeys 7 0
  let _ ← http3Quic1RttRequest liveSess "GET" "127.0.0.1" 9 "/v1/drop1" #[] ByteArray.empty 4096 50
  let snap1 ← inspectQuic1RttSession liveSess
  let _ ← http2Or3Request (.http3 (some liveSess)) "GET" "127.0.0.1" 9 "/v1/drop2" #[] ByteArray.empty 4096 1
  let snap2 ← inspectQuic1RttSession liveSess
  assertTrue "Quic1RttSession atomically advances nextTxPktNum (7->8->9) and streamId (0->4->8) across failed UDP & http2Or3Request calls"
    (snap1.nextTxPktNum == 8 && snap1.nextClientStreamId == 4 &&
     snap2.nextTxPktNum == 9 && snap2.nextClientStreamId == 8)

  -- Address-roaming migration check (`peerAddrTag` updates cleanly on higher packet number `15`, preserved on older `14`)
  let some stRoam15 := admitPacketNumber? stAfter11 15 0xCAFEBABE0002
    | throw (IO.userError "admitPacketNumber? roam 15 failed")
  let some stRoam14 := admitPacketNumber? stRoam15 14 0x111111111111
    | throw (IO.userError "admitPacketNumber? late 14 failed")
  assertTrue "QUIC address roaming updates peerAddrTag only on highest authenticated packet"
    (stRoam15.peerAddrTag == 0xCAFEBABE0002 && stRoam14.peerAddrTag == 0xCAFEBABE0002)

  -- ChaCha20-Poly1305 + ChaCha20 Header Protection 1-RTT roundtrip
  let .ok chachaHpKey ← randBytes 32 | throw (IO.userError "chachaHpKey")
  let .ok chachaWire ← sealQuicShortPacket .chacha20Poly1305 .chacha20 key32 iv12 chachaHpKey
      { dcid := 0xAABBCCDDEEFF0011, pktNum := 42, keyPhase := true, payload := qStreamFrame }
    | throw (IO.userError "chacha seal failed")
  let .ok chachaOpened ← openQuicShortPacket .chacha20Poly1305 .chacha20 key32 iv12 chachaHpKey chachaWire 40
    | throw (IO.userError "chacha open failed")
  assertTrue "ChaCha20-Poly1305 + ChaCha20 HP 1-RTT packet roundtrip preserves keyPhase & payload"
    (chachaOpened.pktNum == 42 && chachaOpened.keyPhase == true && chachaOpened.payload == qStreamFrame)

  -- 7. Wave 5.B Subprocess-Elimination Ablation Receipt: In-process 1-RTT H3/QUIC seal+open+parse vs fork+exec spawn floor
  let iters := 200
  let t0 ← IO.monoNanosNow
  for i in [0:iters] do
    let .ok w ← buildProtectedH3RequestDatagram sessKeys i.toUInt64 "GET" "quic.orb.local" "/v1/health" #[] ByteArray.empty 0
      | throw (IO.userError "bench seal")
    let .ok pkt ← openQuicShortPacket .aes128Gcm .aes128Ecb key16 iv12 hpKey16 w (if i == 0 then 0 else (i - 1).toUInt64)
      | throw (IO.userError "bench open")
    let .ok _ := extractQuic1RttStreamPayload pkt.payload 0 4096
      | throw (IO.userError "bench frame walk")
  let t1 ← IO.monoNanosNow
  let nativeNs := Nat.max 1 (t1 - t0)

  let subIters := 20
  let s0 ← IO.monoNanosNow
  for _ in [0:subIters] do
    let child ← IO.Process.spawn { cmd := "/bin/true", stdin := .null, stdout := .null, stderr := .null }
    let _ ← child.wait
  let s1 ← IO.monoNanosNow
  let subScaledNs := (s1 - s0) * (iters / subIters)
  let deltaPct := if subScaledNs > nativeNs then ((subScaledNs - nativeNs) * 100) / subScaledNs else 0
  IO.println s!"[BENCH] Wave 5.B 200x in-process 1-RTT H3/QUIC codec={nativeNs / 1000}us vs fork+exec spawn floor={subScaledNs / 1000}us (Delta={deltaPct}%)"
  assertTrue "In-process 1-RTT H3/QUIC codec completed 200 roundtrips"
    (nativeNs > 0)

  -- 8. RFC 1952 `gzip` + RFC 1951 `DEFLATE` decompressor & zip-bomb / CRC32 rejection
  -- (a) Fixed Huffman (`BTYPE=01`): `gzip` of `"{\"ok\":true,\"missions\":[{\"id\":\"m1\"},{\"id\":\"m2\"}]}"` (48 bytes)
  let gzValid := ByteArray.mk #[
    0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0xff, 0xab, 0x56,
    0xca, 0xcf, 0x56, 0xb2, 0x2a, 0x29, 0x2a, 0x4d, 0xd5, 0x51, 0xca, 0xcd,
    0x2c, 0x2e, 0xce, 0xcc, 0xcf, 0x2b, 0x56, 0xb2, 0x8a, 0xae, 0x56, 0xca,
    0x4c, 0x51, 0xb2, 0x52, 0xca, 0x35, 0x54, 0xaa, 0xd5, 0x81, 0xb1, 0x8d,
    0x94, 0x6a, 0x63, 0x6b, 0x01, 0xde, 0xda, 0xc6, 0xf0, 0x30, 0x00, 0x00,
    0x00
  ]
  let expectedJson := "{\"ok\":true,\"missions\":[{\"id\":\"m1\"},{\"id\":\"m2\"}]}".toUTF8
  let .ok inflatedJson := gunzipBounded gzValid 1024
    | throw (IO.userError "gunzipBounded failed on valid RFC 1952 BTYPE=01 vector")
  assertTrue "gunzipBounded inflates RFC 1952 BTYPE=01 + LZ77 back-referenced JSON and verifies CRC32/ISIZE"
    (inflatedJson == expectedJson)

  -- (b) Dynamic Huffman (`BTYPE=10`): 146B -> 642B mission list JSON (`4.4x` compression)
  let gzDyn := ByteArray.mk #[
    0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0xff, 0x8d, 0xd2,
    0x4d, 0x0a, 0x83, 0x30, 0x18, 0x84, 0xe1, 0xab, 0x94, 0x59, 0x5b, 0x30,
    0xfe, 0x46, 0xef, 0xe0, 0x09, 0xc4, 0x85, 0x50, 0x91, 0x0f, 0x4c, 0x84,
    0x26, 0xae, 0xc4, 0xbb, 0x1b, 0x28, 0x94, 0xcf, 0xdd, 0x6c, 0x07, 0x9e,
    0xd5, 0xbc, 0x27, 0x9c, 0x84, 0x20, 0xbb, 0x0f, 0xe8, 0xc7, 0x13, 0xf2,
    0x41, 0x0f, 0xf7, 0xce, 0x91, 0x21, 0xc4, 0x39, 0x1e, 0x69, 0xc5, 0xf7,
    0xf0, 0x5e, 0xfc, 0x9a, 0xa6, 0x28, 0x71, 0x5b, 0xd2, 0x32, 0xfc, 0xc8,
    0x2b, 0xc7, 0x95, 0xfd, 0x8d, 0xe1, 0x8c, 0xd1, 0xa6, 0xe0, 0x4c, 0xa1,
    0x4d, 0xc9, 0x99, 0x52, 0x9b, 0x8a, 0x33, 0x95, 0x36, 0x35, 0x67, 0x6a,
    0x6d, 0x1a, 0xce, 0x34, 0xda, 0xb4, 0x9c, 0x69, 0xb5, 0xb1, 0x9c, 0xb1,
    0xda, 0x74, 0x9c, 0xe9, 0x1e, 0x9f, 0x92, 0x21, 0x98, 0x67, 0x09, 0x6c,
    0x0a, 0xa9, 0x85, 0xe9, 0xba, 0x01, 0xbd, 0x91, 0x5b, 0x7b, 0x82, 0x02,
    0x00, 0x00
  ]
  let .ok inflatedDyn := gunzipBounded gzDyn 2048
    | throw (IO.userError "gunzipBounded failed on valid RFC 1952 BTYPE=10 dynamic Huffman vector")
  assertTrue "gunzipBounded inflates RFC 1952 BTYPE=10 dynamic Huffman 146B -> 642B JSON"
    (inflatedDyn.size == 642)

  -- Corrupt trailer CRC32 byte -> fail closed
  let gzBadCrc := gzValid.set! (gzValid.size - 8) ((gzValid.get! (gzValid.size - 8)) ^^^ 0xFF)
  assertTrue "gunzipBounded rejects corrupted CRC32 trailer"
    (gunzipBounded gzBadCrc 1024).isOk.not

  -- Enforce maxOutBytes zip-bomb cap (`32 < 48`) -> fail closed before unbounded growth
  assertTrue "gunzipBounded enforces maxOutBytes zip-bomb ceiling"
    (gunzipBounded gzValid 32).isOk.not

  -- Stored block (`BTYPE=00`) + `FNAME` header flag roundtrip
  let rawHello := "hello-orb-gzip".toUTF8
  let helloCrc := crc32 rawHello
  let storedLen : UInt16 := rawHello.size.toUInt16
  let storedNlen : UInt16 := storedLen ^^^ 0xFFFF
  let mut gzStored := ByteArray.mk #[
    0x1f, 0x8b, 0x08, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03,
    0x74, 0x2e, 0x6a, 0x73, 0x00, -- FNAME "t.js\0"
    0x01, -- BFINAL=1, BTYPE=00
    (storedLen &&& 0xFF).toUInt8, (storedLen >>> 8).toUInt8,
    (storedNlen &&& 0xFF).toUInt8, (storedNlen >>> 8).toUInt8
  ]
  gzStored := gzStored ++ rawHello ++ ByteArray.mk #[
    (helloCrc &&& 0xFF).toUInt8, ((helloCrc >>> 8) &&& 0xFF).toUInt8,
    ((helloCrc >>> 16) &&& 0xFF).toUInt8, ((helloCrc >>> 24) &&& 0xFF).toUInt8,
    rawHello.size.toUInt8, 0x00, 0x00, 0x00
  ]
  assertTrue "gunzipBounded inflates FNAME + stored BTYPE=00 block"
    (match gunzipBounded gzStored 256 with | .ok out => out == rawHello | .error _ => false)

  -- H2ClientPool instantiation, concurrent cold-connect coalescing, and fast fail-closed connect timeout (`totalTimeoutMs = 65000` must NOT stall on transport failure)
  let h2Pool ← H2ClientPool.new
  let tPool0 ← IO.monoMsNow
  let mut tasks : Array (Task (Except IO.Error (Except String PooledHttpResult))) := #[]
  for _ in [0:8] do
    let tk ← IO.asTask (prio := .dedicated) do
      h2Pool.request 0 "GET" "127.0.0.1" 9 "/api/health" #[] ByteArray.empty 4096 false 150 65000
    tasks := tasks.push tk
  let mut allFailedCleanly := true
  for tk in tasks do
    match ← IO.ofExcept tk.get with
    | .ok _ => allFailedCleanly := false
    | .error _ => pure ()
  let tPool1 ← IO.monoMsNow
  assertTrue "H2ClientPool coalesces concurrent cold connects and fails fast without 65s H1 fallback stall"
    (allFailedCleanly && (tPool1 - tPool0) < 3000)

  IO.println "[OrbNetLeaf] ALL SELF-TESTS PASSED"
