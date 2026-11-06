/-
  OrbNetLeaf.HpackQpack: Complete, zero-panic (`0` `String.fromUTF8!`), slice-gated
  RFC 7541 HPACK (all 61 static entries + canonical Huffman + bounded FIFO dynamic table)
  and RFC 9204 QPACK (all 99 static entries + indexed / static-name-ref / literal-name +
  never-indexed + canonical Huffman) header block codecs, plus RFC 9110 §5.5 / RFC 9113 §8.2.1
  field-value control-byte & whitespace hygiene.
-/
import LeanSys.Spec
import LeanSys.Posix
import LeanSys.H2

namespace OrbNetLeaf.HpackQpack

open LeanSys.Spec
open LeanSys.Posix
open LeanSys.H2

/-- RFC 9110 §5.5 + RFC 9113 §8.2.1 / RFC 9114 §4.2 field-value hygiene:
    - Zero C0 control bytes (`0x00..0x1F` except HTAB `0x09`) and zero DEL (`0x7F`).
    - Zero leading or trailing SP (`0x20`) or HTAB (`0x09`) whitespace. -/
def isValidModernHeaderValue (v : String) : Bool := Id.run do
  let b := v.toUTF8
  let cap := b.size.toUInt64
  if cap == 0 then
    return true
  if verifySliceBounds 0 1 cap != 1 || verifySliceBounds (b.size - 1).toUInt64 1 cap != 1 then
    return false
  let first := b.get! 0
  let last := b.get! (b.size - 1)
  if first == 0x20 || first == 0x09 || last == 0x20 || last == 0x09 then
    return false
  let mut i : Nat := 0
  while verifySliceBounds i.toUInt64 1 cap == 1 do
    let c := b.get! i
    if (c < 0x20 && c != 0x09) || c == 0x7F then
      return false
    i := i + 1
  return true

/-! ## RFC 7541 Appendix B Canonical Huffman Table (Symbols `0..255`, Shared by HPACK & QPACK) -/

private def huffmanCodes : Array UInt32 := #[
  0x1ff8, 0x7fffd8, 0xfffffe2, 0xfffffe3, 0xfffffe4, 0xfffffe5, 0xfffffe6, 0xfffffe7,
  0xfffffe8, 0xffffea, 0x3ffffffc, 0xfffffe9, 0xfffffea, 0x3ffffffd, 0xfffffeb, 0xfffffec,
  0xfffffed, 0xfffffee, 0xfffffef, 0xffffff0, 0xffffff1, 0xffffff2, 0x3ffffffe, 0xffffff3,
  0xffffff4, 0xffffff5, 0xffffff6, 0xffffff7, 0xffffff8, 0xffffff9, 0xffffffa, 0xffffffb,
  0x14, 0x3f8, 0x3f9, 0xffa, 0x1ff9, 0x15, 0xf8, 0x7fa,
  0x3fa, 0x3fb, 0xf9, 0x7fb, 0xfa, 0x16, 0x17, 0x18,
  0x0, 0x1, 0x2, 0x19, 0x1a, 0x1b, 0x1c, 0x1d,
  0x1e, 0x1f, 0x5c, 0xfb, 0x7ffc, 0x20, 0xffb, 0x3fc,
  0x1ffa, 0x21, 0x5d, 0x5e, 0x5f, 0x60, 0x61, 0x62,
  0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6a,
  0x6b, 0x6c, 0x6d, 0x6e, 0x6f, 0x70, 0x71, 0x72,
  0xfc, 0x73, 0xfd, 0x1ffb, 0x7fff0, 0x1ffc, 0x3ffc, 0x22,
  0x7ffd, 0x3, 0x23, 0x4, 0x24, 0x5, 0x25, 0x26,
  0x27, 0x6, 0x74, 0x75, 0x28, 0x29, 0x2a, 0x7,
  0x2b, 0x76, 0x2c, 0x8, 0x9, 0x2d, 0x77, 0x78,
  0x79, 0x7a, 0x7b, 0x7ffe, 0x7fc, 0x3ffd, 0x1ffd, 0xffffffc,
  0xfffe6, 0x3fffd2, 0xfffe7, 0xfffe8, 0x3fffd3, 0x3fffd4, 0x3fffd5, 0x7fffd9,
  0x3fffd6, 0x7fffda, 0x7fffdb, 0x7fffdc, 0x7fffdd, 0x7fffde, 0xffffeb, 0x7fffdf,
  0xffffec, 0xffffed, 0x3fffd7, 0x7fffe0, 0xffffee, 0x7fffe1, 0x7fffe2, 0x7fffe3,
  0x7fffe4, 0x1fffdc, 0x3fffd8, 0x7fffe5, 0x3fffd9, 0x7fffe6, 0x7fffe7, 0xffffef,
  0x3fffda, 0x1fffdd, 0xfffe9, 0x3fffdb, 0x3fffdc, 0x7fffe8, 0x7fffe9, 0x1fffde,
  0x7fffea, 0x3fffdd, 0x3fffde, 0xfffff0, 0x1fffdf, 0x3fffdf, 0x7fffeb, 0x7fffec,
  0x1fffe0, 0x1fffe1, 0x3fffe0, 0x1fffe2, 0x7fffed, 0x3fffe1, 0x7fffee, 0x7fffef,
  0xfffea, 0x3fffe2, 0x3fffe3, 0x3fffe4, 0x7ffff0, 0x3fffe5, 0x3fffe6, 0x7ffff1,
  0x3ffffe0, 0x3ffffe1, 0xfffeb, 0x7fff1, 0x3fffe7, 0x7ffff2, 0x3fffe8, 0x1ffffec,
  0x3ffffe2, 0x3ffffe3, 0x3ffffe4, 0x7ffffde, 0x7ffffdf, 0x3ffffe5, 0xfffff1, 0x1ffffed,
  0x7fff2, 0x1fffe3, 0x3ffffe6, 0x7ffffe0, 0x7ffffe1, 0x3ffffe7, 0x7ffffe2, 0xfffff2,
  0x1fffe4, 0x1fffe5, 0x3ffffe8, 0x3ffffe9, 0xffffffd, 0x7ffffe3, 0x7ffffe4, 0x7ffffe5,
  0xfffec, 0xfffff3, 0xfffed, 0x1fffe6, 0x3fffe9, 0x1fffe7, 0x1fffe8, 0x7ffff3,
  0x3fffea, 0x3fffeb, 0x1ffffee, 0x1ffffef, 0xfffff4, 0xfffff5, 0x3ffffea, 0x7ffff4,
  0x3ffffeb, 0x7ffffe6, 0x3ffffec, 0x3ffffed, 0x7ffffe7, 0x7ffffe8, 0x7ffffe9, 0x7ffffea,
  0x7ffffeb, 0xffffffe, 0x7ffffec, 0x7ffffed, 0x7ffffee, 0x7ffffef, 0x7fffff0, 0x3ffffee
]

private def huffmanCodeLens : Array UInt8 := #[
  13, 23, 28, 28, 28, 28, 28, 28, 28, 24, 30, 28, 28, 30, 28, 28,
  28, 28, 28, 28, 28, 28, 30, 28, 28, 28, 28, 28, 28, 28, 28, 28,
   6, 10, 10, 12, 13,  6,  8, 11, 10, 10,  8, 11,  8,  6,  6,  6,
   5,  5,  5,  6,  6,  6,  6,  6,  6,  6,  7,  8, 15,  6, 12, 10,
  13,  6,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,
   7,  7,  7,  7,  7,  7,  7,  7,  8,  7,  8, 13, 19, 13, 14,  6,
  15,  5,  6,  5,  6,  5,  6,  6,  6,  5,  7,  7,  6,  6,  6,  5,
   6,  7,  6,  5,  5,  6,  7,  7,  7,  7,  7, 15, 11, 14, 13, 28,
  20, 22, 20, 20, 22, 22, 22, 23, 22, 23, 23, 23, 23, 23, 24, 23,
  24, 24, 22, 23, 24, 23, 23, 23, 23, 21, 22, 23, 22, 23, 23, 24,
  22, 21, 20, 22, 22, 23, 23, 21, 23, 22, 22, 24, 21, 22, 23, 23,
  21, 21, 22, 21, 23, 22, 23, 23, 20, 22, 22, 22, 23, 22, 22, 23,
  26, 26, 20, 19, 22, 23, 22, 25, 26, 26, 26, 27, 27, 26, 24, 25,
  19, 21, 26, 27, 27, 26, 27, 24, 21, 21, 26, 26, 28, 27, 27, 27,
  20, 24, 20, 21, 22, 21, 21, 23, 22, 22, 25, 25, 24, 24, 26, 23,
  26, 27, 26, 26, 27, 27, 27, 27, 27, 28, 27, 27, 27, 27, 27, 26
]

/-- Binary Huffman trie over `0..255` (excluding EOS `256` so explicit 30-bit EOS fails closed).
    Edge encoding: `0` = unassigned, `(0x80000000 ||| sym)` = leaf byte, else internal node index. -/
private def huffmanTrie : Array (UInt32 × UInt32) := Id.run do
  let mut nodes : Array (UInt32 × UInt32) := #[(0, 0)]
  for sym in [0:256] do
    let code := huffmanCodes[sym]!
    let bLen := huffmanCodeLens[sym]!.toNat
    let mut cur : Nat := 0
    for step in [0:bLen] do
      let shift := (bLen - 1 - step).toUInt32
      let bit := (code >>> shift) &&& 1
      let (lc, rc) := nodes[cur]!
      if step + 1 == bLen then
        let leaf : UInt32 := 0x80000000 ||| sym.toUInt32
        nodes := nodes.set! cur (if bit == 0 then (leaf, rc) else (lc, leaf))
      else
        let child := if bit == 0 then lc else rc
        if child == 0 then
          let nextIdx := nodes.size
          nodes := nodes.push (0, 0)
          nodes := nodes.set! cur (if bit == 0 then (nextIdx.toUInt32, rc) else (lc, nextIdx.toUInt32))
          cur := nextIdx
        else
          cur := child.toNat
  return nodes

/-- Encode raw bytes with RFC 7541 Appendix B canonical Huffman coding (1-padded to octet boundary). -/
def encodeHuffmanBytes (plain : ByteArray) : ByteArray := Id.run do
  let mut out := ByteArray.emptyWithCapacity plain.size
  let mut acc : UInt64 := 0
  let mut nbits : Nat := 0
  for i in [0:plain.size] do
    let ch := (plain.get! i).toNat
    let code := huffmanCodes[ch]!.toUInt64
    let bl := huffmanCodeLens[ch]!.toNat
    acc := (acc <<< bl.toUInt64) ||| code
    nbits := nbits + bl
    while nbits >= 8 do
      nbits := nbits - 8
      out := out.push ((acc >>> nbits.toUInt64) &&& 0xFF).toUInt8
  if nbits > 0 then
    let pad := 8 - nbits
    let mask : UInt64 := (1 <<< pad.toUInt64) - 1
    out := out.push (((acc <<< pad.toUInt64) ||| mask) &&& 0xFF).toUInt8
  return out

/-- Decode RFC 7541 §5.2 / RFC 9204 §4.1.2 Huffman-encoded string bytes strictly:
    - Enforces `maxDecodedBytes` cap against compression bombs.
    - Rejects explicit EOS symbol (`30` ones), `>= 8` bits of trailing padding, or any `0` bit in padding. -/
def decodeHuffmanBytes? (src : ByteSource) (maxDecodedBytes : Nat := 65536) : Option ByteArray := Id.run do
  let trie := huffmanTrie
  let mut out := ByteArray.emptyWithCapacity (Nat.min (src.size * 2) maxDecodedBytes)
  let mut cur : Nat := 0
  let mut padBits : Nat := 0
  let mut padAllOnes := true
  for i in [0:src.size] do
    let b := src.getByteD i
    for bitIdx in [0:8] do
      let shift := (7 - bitIdx).toUInt8
      let bit := (b >>> shift) &&& 1
      if cur >= trie.size then
        return none
      let (lc, rc) := trie[cur]!
      let edge := if bit == 0 then lc else rc
      if edge == 0 then
        return none
      if (edge &&& 0x80000000) != 0 then
        if out.size >= maxDecodedBytes then
          return none
        out := out.push (edge &&& 0xFF).toUInt8
        cur := 0
        padBits := 0
        padAllOnes := true
      else
        cur := edge.toNat
        padBits := padBits + 1
        if bit == 0 then
          padAllOnes := false
  if cur == 0 || (padBits <= 7 && padAllOnes) then
    return some out
  else
    return none

/-- Decode a prefixed string literal (`huffBitMask` for `H` bit, `lenPrefixBits` for integer length)
    strictly via `String.fromUTF8?` (zero `String.fromUTF8!` panics). -/
def decodeWireString?
    (src : ByteSource) (off : Nat)
    (huffBitMask : UInt8 := 0x80) (lenPrefixBits : Nat := 7)
    (maxDecodedBytes : Nat := 65536) : Option (String × Nat) := do
  let head ← src.subSource? off 1
  let isHuff := ((head.getByteD 0) &&& huffBitMask) != 0
  let (rawLen, afterLen) ← decodeHpackInt? src off lenPrefixBits
  if rawLen > maxDecodedBytes then
    none
  else
    let rawSub ← src.subSource? afterLen rawLen
    let utf8Bytes ←
      if isHuff then
        decodeHuffmanBytes? rawSub maxDecodedBytes
      else
        some rawSub.toByteArray
    let str ← String.fromUTF8? utf8Bytes
    some (str, afterLen + rawLen)

/-! ## Complete RFC 7541 Appendix A Static Table (`1..61`) + FIFO Dynamic Table -/

private def hpackStaticTable : Array (String × String) := #[
  (":authority", ""),
  (":method", "GET"),
  (":method", "POST"),
  (":path", "/"),
  (":path", "/index.html"),
  (":scheme", "http"),
  (":scheme", "https"),
  (":status", "200"),
  (":status", "204"),
  (":status", "206"),
  (":status", "304"),
  (":status", "400"),
  (":status", "404"),
  (":status", "500"),
  ("accept-charset", ""),
  ("accept-encoding", "gzip, deflate"),
  ("accept-language", ""),
  ("accept-ranges", ""),
  ("accept", ""),
  ("access-control-allow-origin", ""),
  ("age", ""),
  ("allow", ""),
  ("authorization", ""),
  ("cache-control", ""),
  ("content-disposition", ""),
  ("content-encoding", ""),
  ("content-language", ""),
  ("content-length", ""),
  ("content-location", ""),
  ("content-range", ""),
  ("content-type", ""),
  ("cookie", ""),
  ("date", ""),
  ("etag", ""),
  ("expect", ""),
  ("expires", ""),
  ("from", ""),
  ("host", ""),
  ("if-match", ""),
  ("if-modified-since", ""),
  ("if-none-match", ""),
  ("if-range", ""),
  ("if-unmodified-since", ""),
  ("last-modified", ""),
  ("link", ""),
  ("location", ""),
  ("max-forwards", ""),
  ("proxy-authenticate", ""),
  ("proxy-authorization", ""),
  ("range", ""),
  ("referer", ""),
  ("refresh", ""),
  ("retry-after", ""),
  ("server", ""),
  ("set-cookie", ""),
  ("strict-transport-security", ""),
  ("transfer-encoding", ""),
  ("user-agent", ""),
  ("vary", ""),
  ("via", ""),
  ("www-authenticate", "")
]

/-- Look up 1-based RFC 7541 Appendix A static entry (`1..61`). -/
def hpackFullStaticEntry? (idx : Nat) : Option (String × String) :=
  if 1 ≤ idx && idx ≤ hpackStaticTable.size then
    some hpackStaticTable[idx - 1]!
  else
    none

/-- Stateful RFC 7541 §4 FIFO dynamic table (`entries[0]` = oldest, `entries.back` = newest = index `62`). -/
structure HpackDecoderTable where
  entries      : Array (String × String) := #[]
  usedBytes    : Nat := 0
  maxBytes     : Nat := 4096
  hardCapBytes : Nat := 4096
  deriving Inhabited

private def hpackEntryWeight (name val : String) : Nat :=
  32 + name.utf8ByteSize + val.utf8ByteSize

private def evictHpackToLimit (tbl : HpackDecoderTable) (limit : Nat) : HpackDecoderTable := Id.run do
  let mut used := tbl.usedBytes
  let mut dropCount := 0
  while dropCount < tbl.entries.size && used > limit do
    let (k, v) := tbl.entries[dropCount]!
    let w := hpackEntryWeight k v
    used := used - w
    dropCount := dropCount + 1
  if dropCount == 0 then
    return tbl
  else
    return { tbl with entries := tbl.entries.extract dropCount tbl.entries.size, usedBytes := used }

private def insertHpackDynamic (tbl : HpackDecoderTable) (name val : String) : HpackDecoderTable :=
  let w := hpackEntryWeight name val
  if w > tbl.maxBytes then
    { tbl with entries := #[], usedBytes := 0 }
  else
    let tbl' := evictHpackToLimit tbl (tbl.maxBytes - w)
    { tbl' with entries := tbl'.entries.push (name, val), usedBytes := tbl'.usedBytes + w }

private def lookupHpackIndex? (tbl : HpackDecoderTable) (idx : Nat) : Option (String × String) :=
  if idx == 0 then none
  else if idx <= hpackStaticTable.size then
    some hpackStaticTable[idx - 1]!
  else
    let dynOffset := idx - (hpackStaticTable.size + 1)
    if dynOffset < tbl.entries.size then
      some tbl.entries[tbl.entries.size - 1 - dynOffset]!
    else
      none

/-- Decode a complete RFC 7541 HPACK header block (`1..61` static + dynamic table + Huffman + `String.fromUTF8?`). -/
def decodeRfc7541BlockWithTable?
    (tbl0 : HpackDecoderTable) (src : ByteSource) (maxHeaders : Nat := 128) :
    Option (Array (String × String) × HpackDecoderTable) := Id.run do
  let mut tbl := tbl0
  let mut out : Array (String × String) := #[]
  let mut off := 0
  let mut sawField := false
  while off < src.size do
    let b ← match src.subSource? off 1 with
      | some head => pure (head.getByteD 0)
      | none => return none
    if (b &&& 0x80) != 0 then
      -- §6.1 Indexed Header Field (`1xxxxxxx`)
      if out.size >= maxHeaders then return none
      let (idx, nextOff) ← match decodeHpackInt? src off 7 with
        | some r => pure r
        | none => return none
      let kv ← match lookupHpackIndex? tbl idx with
        | some r => pure r
        | none => return none
      out := out.push kv
      sawField := true
      off := nextOff
    else if (b &&& 0x40) != 0 then
      -- §6.2.1 Literal Header Field with Incremental Indexing (`01xxxxxx`)
      if out.size >= maxHeaders then return none
      let (nameIdx, afterIdx) ← match decodeHpackInt? src off 6 with
        | some r => pure r
        | none => return none
      let (name, valOff) ←
        if nameIdx == 0 then
          match decodeWireString? src afterIdx 0x80 7 with
          | some r => pure r
          | none => return none
        else
          match lookupHpackIndex? tbl nameIdx with
          | some (n, _) => pure (n, afterIdx)
          | none => return none
      let (val, nextOff) ← match decodeWireString? src valOff 0x80 7 with
        | some r => pure r
        | none => return none
      tbl := insertHpackDynamic tbl name val
      out := out.push (name, val)
      sawField := true
      off := nextOff
    else if (b &&& 0xE0) == 0x20 then
      -- §6.3 Dynamic Table Size Update (`001xxxxx`): allowed only before fields in block (§4.2)
      if sawField then return none
      let (newSz, nextOff) ← match decodeHpackInt? src off 5 with
        | some r => pure r
        | none => return none
      if newSz > tbl.hardCapBytes then return none
      tbl := evictHpackToLimit { tbl with maxBytes := newSz } newSz
      off := nextOff
    else
      -- §6.2.2 Without Indexing (`0000xxxx`) or §6.2.3 Never Indexed (`0001xxxx`)
      if out.size >= maxHeaders then return none
      let (nameIdx, afterIdx) ← match decodeHpackInt? src off 4 with
        | some r => pure r
        | none => return none
      let (name, valOff) ←
        if nameIdx == 0 then
          match decodeWireString? src afterIdx 0x80 7 with
          | some r => pure r
          | none => return none
        else
          match lookupHpackIndex? tbl nameIdx with
          | some (n, _) => pure (n, afterIdx)
          | none => return none
      let (val, nextOff) ← match decodeWireString? src valOff 0x80 7 with
        | some r => pure r
        | none => return none
      out := out.push (name, val)
      sawField := true
      off := nextOff
  return some (out, tbl)

/-- Stateless wrapper over `decodeRfc7541BlockWithTable?` with RFC 9113 default 4096-byte dynamic table. -/
def decodeRfc7541Block? (src : ByteSource) (maxHeaders : Nat := 128) : Option (Array (String × String)) :=
  (decodeRfc7541BlockWithTable? {} src maxHeaders).map Prod.fst

/-! ## Complete RFC 9204 Appendix A QPACK Static Table (`0..98`) + Field Section Decoder -/

private def qpackStaticTable : Array (String × String) := #[
  (":authority", ""),
  (":path", "/"),
  ("age", "0"),
  ("content-disposition", ""),
  ("content-length", "0"),
  ("cookie", ""),
  ("date", ""),
  ("etag", ""),
  ("if-modified-since", ""),
  ("if-none-match", ""),
  ("last-modified", ""),
  ("link", ""),
  ("location", ""),
  ("referer", ""),
  ("set-cookie", ""),
  (":method", "CONNECT"),
  (":method", "DELETE"),
  (":method", "GET"),
  (":method", "HEAD"),
  (":method", "OPTIONS"),
  (":method", "POST"),
  (":method", "PUT"),
  (":scheme", "http"),
  (":scheme", "https"),
  (":status", "103"),
  (":status", "200"),
  (":status", "304"),
  (":status", "404"),
  (":status", "503"),
  ("accept", "*/*"),
  ("accept", "application/dns-message"),
  ("accept-encoding", "gzip, deflate, br"),
  ("accept-ranges", "bytes"),
  ("access-control-allow-headers", "cache-control"),
  ("access-control-allow-headers", "content-type"),
  ("access-control-allow-origin", "*"),
  ("cache-control", "max-age=0"),
  ("cache-control", "max-age=2592000"),
  ("cache-control", "max-age=604800"),
  ("cache-control", "no-cache"),
  ("cache-control", "no-store"),
  ("cache-control", "public, max-age=31536000"),
  ("content-encoding", "br"),
  ("content-encoding", "gzip"),
  ("content-type", "application/dns-message"),
  ("content-type", "application/javascript"),
  ("content-type", "application/json"),
  ("content-type", "application/x-www-form-urlencoded"),
  ("content-type", "image/gif"),
  ("content-type", "image/jpeg"),
  ("content-type", "image/png"),
  ("content-type", "text/css"),
  ("content-type", "text/html; charset=utf-8"),
  ("content-type", "text/plain"),
  ("content-type", "text/plain;charset=utf-8"),
  ("range", "bytes=0-"),
  ("strict-transport-security", "max-age=31536000"),
  ("strict-transport-security", "max-age=31536000; includesubdomains"),
  ("strict-transport-security", "max-age=31536000; includesubdomains; preload"),
  ("vary", "accept-encoding"),
  ("vary", "origin"),
  ("x-content-type-options", "nosniff"),
  ("x-xss-protection", "1; mode=block"),
  (":status", "100"),
  (":status", "204"),
  (":status", "206"),
  (":status", "302"),
  (":status", "400"),
  (":status", "403"),
  (":status", "421"),
  (":status", "425"),
  (":status", "500"),
  ("accept-language", ""),
  ("access-control-allow-credentials", "FALSE"),
  ("access-control-allow-credentials", "TRUE"),
  ("access-control-allow-headers", "*"),
  ("access-control-allow-methods", "get"),
  ("access-control-allow-methods", "get, post, options"),
  ("access-control-allow-methods", "options"),
  ("access-control-expose-headers", "content-length"),
  ("access-control-request-headers", "content-type"),
  ("access-control-request-method", "get"),
  ("access-control-request-method", "post"),
  ("alt-svc", "clear"),
  ("authorization", ""),
  ("content-security-policy", "script-src 'none'; object-src 'none'; base-uri 'none'"),
  ("early-data", "1"),
  ("expect-ct", ""),
  ("forwarded", ""),
  ("if-range", ""),
  ("origin", ""),
  ("purpose", "prefetch"),
  ("server", ""),
  ("timing-allow-origin", "*"),
  ("upgrade-insecure-requests", "1"),
  ("user-agent", ""),
  ("x-forwarded-for", ""),
  ("x-frame-options", "deny"),
  ("x-frame-options", "sameorigin")
]

/-- Look up 0-based RFC 9204 Appendix A static entry (`0..98`). -/
def qpackFullStaticEntry? (idx : Nat) : Option (String × String) :=
  if idx < qpackStaticTable.size then
    some qpackStaticTable[idx]!
  else
    none

/-- Decode a complete RFC 9204 §4.5 static QPACK field section (`Required Insert Count == 0, Base == 0`),
    supporting `11xxxxxx` Indexed Static, `01NTxxxx` (`T=1`) Literal With Static Name Ref (`N=0/1`),
    `001NHxxx` Literal With Literal Name (`N=0/1`, `H=0/1`), Huffman values, and `String.fromUTF8?`. -/
def decodeRfc9204Block? (src : ByteSource) (maxHeaders : Nat := 128) : Option (Array (String × String)) := Id.run do
  let pfx ← match src.subSource? 0 2 with
    | some p => pure p
    | none => return none
  if pfx.getByteD 0 != 0 || pfx.getByteD 1 != 0 then
    return none
  let mut out : Array (String × String) := #[]
  let mut off := 2
  while off < src.size do
    if out.size >= maxHeaders then
      return none
    let b ← match src.subSource? off 1 with
      | some head => pure (head.getByteD 0)
      | none => return none
    if (b &&& 0x80) != 0 then
      -- §4.5.2 Indexed Field Line (`1Txxxxxx`), require static table `T=1` (`0x40`)
      if (b &&& 0x40) == 0 then return none
      let (idx, nextOff) ← match decodeHpackInt? src off 6 with
        | some r => pure r
        | none => return none
      let kv ← match qpackFullStaticEntry? idx with
        | some r => pure r
        | none => return none
      out := out.push kv
      off := nextOff
    else if (b &&& 0xC0) == 0x40 then
      -- §4.5.4 Literal Field Line With Name Reference (`01NTxxxx`), require static `T=1` (`0x10`)
      if (b &&& 0x10) == 0 then return none
      let (nameIdx, afterIdx) ← match decodeHpackInt? src off 4 with
        | some r => pure r
        | none => return none
      let (name, _) ← match qpackFullStaticEntry? nameIdx with
        | some r => pure r
        | none => return none
      let (val, nextOff) ← match decodeWireString? src afterIdx 0x80 7 with
        | some r => pure r
        | none => return none
      out := out.push (name, val)
      off := nextOff
    else if (b &&& 0xE0) == 0x20 then
      -- §4.5.6 Literal Field Line With Literal Name (`001NHxxx`)
      let (name, afterName) ← match decodeWireString? src off 0x08 3 with
        | some r => pure r
        | none => return none
      let (val, nextOff) ← match decodeWireString? src afterName 0x80 7 with
        | some r => pure r
        | none => return none
      out := out.push (name, val)
      off := nextOff
    else
      -- Dynamic post-base representations forbidden when QPACK_MAX_TABLE_CAPACITY == 0
      return none
  return some out

end OrbNetLeaf.HpackQpack
