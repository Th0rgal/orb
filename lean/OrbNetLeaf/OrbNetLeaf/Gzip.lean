/-
  OrbNetLeaf.Gzip: Verified pure-Lean 4 RFC 1952 `gzip` & RFC 1951 `DEFLATE` decompressor
  with strict `maxOutBytes` zip-bomb ceiling, bounds-checked canonical Huffman decoding,
  LZ77 32 KiB sliding-window back-reference validation, and IEEE 802.3 CRC-32 + `ISIZE`
  integrity verification. Zero external `libz` / C LOC dependencies.
-/
import LeanSys.Spec

namespace OrbNetLeaf.Gzip

open LeanSys.Spec

/-- Precomputed 256-entry IEEE 802.3 CRC-32 lookup table (`0xEDB88320` reflected polynomial). -/
private def crc32Table : Array UInt32 := Id.run do
  let mut tbl : Array UInt32 := Array.mkEmpty 256
  for i in [0:256] do
    let mut c : UInt32 := i.toUInt32
    for _ in [0:8] do
      if (c &&& 1) != 0 then
        c := (c >>> 1) ^^^ 0xEDB88320
      else
        c := c >>> 1
    tbl := tbl.push c
  return tbl

/-- Compute IEEE 802.3 CRC-32 checksum over `buf`. -/
def crc32 (buf : ByteArray) : UInt32 := Id.run do
  let cap := buf.size.toUInt64
  let mut c : UInt32 := 0xFFFFFFFF
  let mut i : Nat := 0
  while verifySliceBounds i.toUInt64 1 cap == 1 do
    let b := buf.get! i
    let idx := ((c ^^^ b.toUInt32) &&& 0xFF).toNat
    c := (c >>> 8) ^^^ crc32Table[idx]!
    i := i + 1
  return c ^^^ 0xFFFFFFFF

/-- Bit-level LSB-first reader state over an immutable `ByteArray`. -/
private structure BitReader where
  raw    : ByteArray
  pos    : Nat := 0
  bitBuf : UInt64 := 0
  bitCnt : Nat := 0

private def BitReader.ensureBits (br : BitReader) (need : Nat) : BitReader := Id.run do
  let mut st := br
  let cap := st.raw.size.toUInt64
  while st.bitCnt < need && verifySliceBounds st.pos.toUInt64 1 cap == 1 do
    let b := (st.raw.get! st.pos).toUInt64
    st := { st with
      pos := st.pos + 1
      bitBuf := st.bitBuf ||| (b <<< st.bitCnt.toUInt64)
      bitCnt := st.bitCnt + 8
    }
  return st

private def BitReader.readBits? (br : BitReader) (n : Nat) : Option (Nat × BitReader) :=
  if n == 0 then
    some (0, br)
  else
    let st := br.ensureBits n
    if st.bitCnt < n then
      none
    else
      let mask : UInt64 := (1 <<< n.toUInt64) - 1
      let v := (st.bitBuf &&& mask).toNat
      some (v, { st with
        bitBuf := st.bitBuf >>> n.toUInt64
        bitCnt := st.bitCnt - n
      })

private def BitReader.alignToByte (br : BitReader) : BitReader :=
  let dropBits := br.bitCnt % 8
  if dropBits == 0 then br
  else { br with
    bitBuf := br.bitBuf >>> dropBits.toUInt64
    bitCnt := br.bitCnt - dropBits
  }

private def BitReader.readAlignedByte? (br : BitReader) : Option (UInt8 × BitReader) :=
  if br.bitCnt >= 8 then
    let b := (br.bitBuf &&& 0xFF).toUInt8
    some (b, { br with bitBuf := br.bitBuf >>> 8, bitCnt := br.bitCnt - 8 })
  else if verifySliceBounds br.pos.toUInt64 1 br.raw.size.toUInt64 == 1 then
    let b := br.raw.get! br.pos
    some (b, { br with pos := br.pos + 1 })
  else
    none

private def BitReader.readAlignedU16LE? (br : BitReader) : Option (UInt16 × BitReader) := do
  let (b0, br1) ← br.readAlignedByte?
  let (b1, br2) ← br1.readAlignedByte?
  return (b0.toUInt16 ||| (b1.toUInt16 <<< 8), br2)

private def BitReader.readAlignedU32LE? (br : BitReader) : Option (UInt32 × BitReader) := do
  let (lo, br1) ← br.readAlignedU16LE?
  let (hi, br2) ← br1.readAlignedU16LE?
  return (lo.toUInt32 ||| (hi.toUInt32 <<< 16), br2)

/-- Reverse the low `len` bits of `code` (`1 ≤ len ≤ 15`) for LSB-first DEFLATE lookup. -/
private def reverseBits (code : Nat) (len : Nat) : Nat := Id.run do
  let mut c := code
  let mut r : Nat := 0
  for _ in [0:len] do
    r := (r <<< 1) ||| (c &&& 1)
    c := c >>> 1
  return r

/-- Fast flat lookup table (`2^maxBits` entries, `maxBits ≤ 15`).
    Entry `0` = invalid/unassigned code; non-zero packs `(bitLen <<< 16) ||| (sym + 1)`. -/
private structure HuffTable where
  maxBits : Nat
  entries : Array UInt32

private def buildHuffTable? (lengths : Array Nat) (maxBitsCap : Nat := 15) : Except String HuffTable := do
  let mut blCount : Array Nat := Array.replicate (maxBitsCap + 1) 0
  let mut maxLen : Nat := 0
  for l in lengths do
    if l > maxBitsCap then
      throw "DEFLATE Huffman code length exceeds 15 bits"
    if l > 0 then
      blCount := blCount.set! l (blCount[l]! + 1)
      if l > maxLen then
        maxLen := l
  if maxLen == 0 then
    -- Empty distance tree allowed by RFC 1951 when only literals appear in block
    return { maxBits := 1, entries := #[0, 0] }
  let mut nextCode : Array Nat := Array.replicate (maxLen + 1) 0
  let mut code : Nat := 0
  for bits in [1:maxLen + 1] do
    code := (code + blCount[bits - 1]!) <<< 1
    if code + blCount[bits]! > (1 <<< bits) then
      throw "oversubscribed DEFLATE Huffman tree"
    nextCode := nextCode.set! bits code
  let tableSize : Nat := 1 <<< maxLen
  let mut tbl : Array UInt32 := Array.replicate tableSize 0
  for sym in [0:lengths.size] do
    let len := lengths[sym]!
    if len > 0 then
      let c := nextCode[len]!
      nextCode := nextCode.set! len (c + 1)
      let rev := reverseBits c len
      let packed : UInt32 := ((len.toUInt32) <<< 16) ||| (sym + 1).toUInt32
      let step : Nat := 1 <<< len
      let mut idx := rev
      while idx < tableSize do
        tbl := tbl.set! idx packed
        idx := idx + step
  return { maxBits := maxLen, entries := tbl }

private def decodeHuffSym? (ht : HuffTable) (br : BitReader) : Option (Nat × BitReader) :=
  let st := br.ensureBits ht.maxBits
  let mask : UInt64 := (1 <<< ht.maxBits.toUInt64) - 1
  let idx := (st.bitBuf &&& mask).toNat
  let entry := ht.entries[idx]!
  if entry == 0 then
    none
  else
    let len := (entry >>> 16).toNat
    if st.bitCnt < len then
      none
    else
      let sym := (entry &&& 0xFFFF).toNat - 1
      some (sym, { st with
        bitBuf := st.bitBuf >>> len.toUInt64
        bitCnt := st.bitCnt - len
      })

private def fixedLitLenTable : HuffTable := Id.run do
  let mut lens : Array Nat := Array.mkEmpty 288
  for i in [0:288] do
    if i <= 143 then lens := lens.push 8
    else if i <= 255 then lens := lens.push 9
    else if i <= 279 then lens := lens.push 7
    else lens := lens.push 8
  match buildHuffTable? lens 9 with
  | .ok t => return t
  | .error _ => return { maxBits := 1, entries := #[0, 0] }

private def fixedDistTable : HuffTable := Id.run do
  let lens : Array Nat := Array.replicate 32 5
  match buildHuffTable? lens 5 with
  | .ok t => return t
  | .error _ => return { maxBits := 1, entries := #[0, 0] }

private def codeLenOrder : Array Nat :=
  #[16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

private def lenBaseTable : Array Nat :=
  #[3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
    35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]

private def lenExtraTable : Array Nat :=
  #[0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
    3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]

private def distBaseTable : Array Nat :=
  #[1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
    257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]

private def distExtraTable : Array Nat :=
  #[0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
    7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]

private def parseDynamicTables (br0 : BitReader) : Except String (HuffTable × HuffTable × BitReader) := do
  let some (hlitRaw, br1) := br0.readBits? 5 | throw "truncated DEFLATE HLIT"
  let some (hdistRaw, br2) := br1.readBits? 5 | throw "truncated DEFLATE HDIST"
  let some (hclenRaw, br3) := br2.readBits? 4 | throw "truncated DEFLATE HCLEN"
  let hlit := hlitRaw + 257
  let hdist := hdistRaw + 1
  let hclen := hclenRaw + 4
  if hlit > 286 || hdist > 32 then
    throw "invalid DEFLATE HLIT/HDIST count"
  let mut clLens : Array Nat := Array.replicate 19 0
  let mut br := br3
  for i in [0:hclen] do
    let some (v, br') := br.readBits? 3 | throw "truncated DEFLATE code-length alphabet"
    br := br'
    clLens := clLens.set! codeLenOrder[i]! v
  let clTable ← buildHuffTable? clLens 7
  let totalCodes := hlit + hdist
  let mut lengths : Array Nat := Array.mkEmpty totalCodes
  while lengths.size < totalCodes do
    let some (sym, br') := decodeHuffSym? clTable br
      | throw "invalid or truncated DEFLATE code-length symbol"
    br := br'
    if sym <= 15 then
      lengths := lengths.push sym
    else if sym == 16 then
      if lengths.isEmpty then
        throw "DEFLATE repeat code 16 with no previous length"
      let some (extra, br2) := br.readBits? 2 | throw "truncated DEFLATE code 16 extra bits"
      br := br2
      let rep := extra + 3
      if lengths.size + rep > totalCodes then
        throw "DEFLATE code 16 repeat overflows HLIT+HDIST"
      let prev := lengths[lengths.size - 1]!
      for _ in [0:rep] do
        lengths := lengths.push prev
    else if sym == 17 then
      let some (extra, br2) := br.readBits? 3 | throw "truncated DEFLATE code 17 extra bits"
      br := br2
      let rep := extra + 3
      if lengths.size + rep > totalCodes then
        throw "DEFLATE code 17 repeat overflows HLIT+HDIST"
      for _ in [0:rep] do
        lengths := lengths.push 0
    else if sym == 18 then
      let some (extra, br2) := br.readBits? 7 | throw "truncated DEFLATE code 18 extra bits"
      br := br2
      let rep := extra + 11
      if lengths.size + rep > totalCodes then
        throw "DEFLATE code 18 repeat overflows HLIT+HDIST"
      for _ in [0:rep] do
        lengths := lengths.push 0
    else
      throw "unexpected DEFLATE code-length symbol"
  let litLens := lengths.extract 0 hlit
  let distLens := lengths.extract hlit totalCodes
  if litLens.size <= 256 || litLens[256]! == 0 then
    throw "DEFLATE dynamic block missing end-of-block symbol 256"
  let litTable ← buildHuffTable? litLens 15
  let distTable ← buildHuffTable? distLens 15
  return (litTable, distTable, br)

private def inflateHuffmanBlock
    (litTable distTable : HuffTable)
    (br0 : BitReader) (out0 : ByteArray) (maxOutBytes : Nat) : Except String (ByteArray × BitReader) := do
  let mut br := br0
  let mut out := out0
  let mut done := false
  while !done do
    let some (sym, br1) := decodeHuffSym? litTable br
      | throw "invalid or truncated DEFLATE literal/length code"
    br := br1
    if sym < 256 then
      if out.size + 1 > maxOutBytes then
        throw s!"gzip output exceeds maxOutBytes ({maxOutBytes})"
      out := out.push sym.toUInt8
    else if sym == 256 then
      done := true
    else if sym <= 285 then
      let lIdx := sym - 257
      let baseLen := lenBaseTable[lIdx]!
      let extraBits := lenExtraTable[lIdx]!
      let some (extraVal, br2) := br.readBits? extraBits
        | throw "truncated DEFLATE length extra bits"
      br := br2
      let copyLen := baseLen + extraVal
      if out.size + copyLen > maxOutBytes then
        throw s!"gzip output exceeds maxOutBytes ({maxOutBytes})"
      let some (distSym, br3) := decodeHuffSym? distTable br
        | throw "invalid or truncated DEFLATE distance code"
      br := br3
      if distSym >= 30 then
        throw "reserved DEFLATE distance symbol >= 30"
      let baseDist := distBaseTable[distSym]!
      let distExtra := distExtraTable[distSym]!
      let some (distExtraVal, br4) := br.readBits? distExtra
        | throw "truncated DEFLATE distance extra bits"
      br := br4
      let dist := baseDist + distExtraVal
      if dist == 0 || dist > out.size then
        throw "DEFLATE LZ77 distance exceeds output window"
      let srcStart := out.size - dist
      if dist >= copyLen then
        out := out ++ out.extract srcStart (srcStart + copyLen)
      else
        for i in [0:copyLen] do
          let b := out.get! (srcStart + (i % dist))
          out := out.push b
    else
      throw "reserved DEFLATE literal/length symbol >= 286"
  return (out, br)

/-- Inflate a raw RFC 1951 `DEFLATE` stream starting at `br0`, appending onto `out0` up to `maxOutBytes`. -/
private def inflateMember (br0 : BitReader) (out0 : ByteArray) (maxOutBytes : Nat) : Except String (ByteArray × BitReader) := do
  let mut br := br0
  let mut out := out0
  let mut isFinal := false
  while !isFinal do
    let some (bfinal, br1) := br.readBits? 1 | throw "truncated DEFLATE BFINAL bit"
    let some (btype, br2) := br1.readBits? 2 | throw "truncated DEFLATE BTYPE bits"
    br := br2
    isFinal := (bfinal == 1)
    if btype == 0 then
      br := br.alignToByte
      let some (len16, br3) := br.readAlignedU16LE? | throw "truncated DEFLATE stored LEN"
      let some (nlen16, br4) := br3.readAlignedU16LE? | throw "truncated DEFLATE stored NLEN"
      br := br4
      if (len16 ^^^ 0xFFFF) != nlen16 then
        throw "DEFLATE stored block LEN/NLEN complement mismatch"
      let blkLen := len16.toNat
      if out.size + blkLen > maxOutBytes then
        throw s!"gzip output exceeds maxOutBytes ({maxOutBytes})"
      -- Drain any byte-aligned buffered bits first, then bulk-slice remaining bytes
      let mut rem := blkLen
      while rem > 0 && br.bitCnt > 0 do
        let some (b, brNext) := br.readAlignedByte? | throw "truncated DEFLATE stored block payload"
        br := brNext
        out := out.push b
        rem := rem - 1
      if rem > 0 then
        if verifySliceBounds br.pos.toUInt64 rem.toUInt64 br.raw.size.toUInt64 != 1 then
          throw "truncated DEFLATE stored block payload"
        out := out ++ br.raw.extract br.pos (br.pos + rem)
        br := { br with pos := br.pos + rem }
    else if btype == 1 then
      let (out', br') ← inflateHuffmanBlock fixedLitLenTable fixedDistTable br out maxOutBytes
      out := out'
      br := br'
    else if btype == 2 then
      let (litTbl, distTbl, brDyn) ← parseDynamicTables br
      let (out', br') ← inflateHuffmanBlock litTbl distTbl brDyn out maxOutBytes
      out := out'
      br := br'
    else
      throw "reserved DEFLATE block type BTYPE=11"
  return (out, br.alignToByte)

private def skipZeroTerminatedField (br0 : BitReader) : Except String BitReader := do
  let mut br := br0
  while true do
    let some (b, brNext) := br.readAlignedByte?
      | throw "unterminated NUL string in gzip header"
    br := brNext
    if b == 0 then
      return br
  return br

/-- Decompress an RFC 1952 `gzip` payload (supporting single or concatenated gzip members)
    with a hard `maxOutBytes` zip-bomb ceiling (`16 MiB` default) and strict CRC-32 + `ISIZE` verification. -/
def gunzipBounded (raw : ByteArray) (maxOutBytes : Nat := 16777216) : Except String ByteArray := do
  if verifySliceBounds 0 18 raw.size.toUInt64 != 1 then
    throw "gzip payload shorter than 18-byte RFC 1952 minimum"
  let mut br : BitReader := { raw := raw }
  let mut totalOut := ByteArray.empty
  let mut memberCount : Nat := 0
  while br.pos < raw.size || br.bitCnt > 0 do
    memberCount := memberCount + 1
    let hdrStartPos := br.pos - (br.bitCnt / 8)
    let some (id1, br1) := br.readAlignedByte? | throw "truncated gzip magic ID1"
    let some (id2, br2) := br1.readAlignedByte? | throw "truncated gzip magic ID2"
    let some (cm, br3) := br2.readAlignedByte? | throw "truncated gzip CM"
    let some (flg, br4) := br3.readAlignedByte? | throw "truncated gzip FLG"
    if id1 != 0x1F || id2 != 0x8B then
      throw "invalid gzip magic header (expected 0x1F 0x8B)"
    if cm != 8 then
      throw s!"unsupported gzip compression method CM={cm} (expected 8 = DEFLATE)"
    if (flg &&& 0xE0) != 0 then
      throw "reserved gzip FLG bits non-zero"
    -- Skip 4-byte MTIME + XFL + OS (6 bytes)
    let some (_, br5) := br4.readAlignedU32LE? | throw "truncated gzip MTIME"
    let some (_, br6) := br5.readAlignedU16LE? | throw "truncated gzip XFL/OS"
    br := br6
    if (flg &&& 0x04) != 0 then
      let some (xlen16, brX) := br.readAlignedU16LE? | throw "truncated gzip FEXTRA XLEN"
      let xlen := xlen16.toNat
      let mut brSkip := brX
      for _ in [0:xlen] do
        let some (_, bn) := brSkip.readAlignedByte? | throw "truncated gzip FEXTRA payload"
        brSkip := bn
      br := brSkip
    if (flg &&& 0x08) != 0 then
      br ← skipZeroTerminatedField br
    if (flg &&& 0x10) != 0 then
      br ← skipZeroTerminatedField br
    if (flg &&& 0x02) != 0 then
      let hdrEndPos := br.pos - (br.bitCnt / 8)
      let wantCrc16 : UInt16 := (crc32 (raw.extract hdrStartPos hdrEndPos) &&& 0xFFFF).toUInt16
      let some (gotCrc16, brH) := br.readAlignedU16LE? | throw "truncated gzip FHCRC"
      if gotCrc16 != wantCrc16 then
        throw "gzip header FHCRC mismatch"
      br := brH
    let memberStartOut := totalOut.size
    let (nextOut, brAfter) ← inflateMember br totalOut maxOutBytes
    totalOut := nextOut
    br := brAfter
    let some (expectedCrc, brC) := br.readAlignedU32LE? | throw "truncated gzip trailer CRC32"
    let some (expectedIsize, brI) := brC.readAlignedU32LE? | throw "truncated gzip trailer ISIZE"
    br := brI
    let memberSlice := totalOut.extract memberStartOut totalOut.size
    let actualCrc := crc32 memberSlice
    if actualCrc != expectedCrc then
      throw "gzip CRC32 checksum mismatch"
    let actualIsize : UInt32 := (memberSlice.size % 4294967296).toUInt32
    if actualIsize != expectedIsize then
      throw "gzip ISIZE length mismatch"
  if memberCount == 0 then
    throw "empty gzip stream"
  return totalOut

/-- Bit-level LSB-first writer state for RFC 1951 DEFLATE encoding. -/
private structure BitWriter where
  out    : ByteArray := ByteArray.empty
  bitBuf : UInt64 := 0
  bitCnt : Nat := 0

private def BitWriter.writeBits (bw : BitWriter) (val : Nat) (n : Nat) : BitWriter := Id.run do
  let mask : UInt64 := if n >= 64 then 0xFFFFFFFFFFFFFFFF else (1 <<< n.toUInt64) - 1
  let mut buf := bw.bitBuf ||| ((val.toUInt64 &&& mask) <<< bw.bitCnt.toUInt64)
  let mut cnt := bw.bitCnt + n
  let mut o := bw.out
  while cnt >= 8 do
    o := o.push (buf &&& 0xFF).toUInt8
    buf := buf >>> 8
    cnt := cnt - 8
  return { out := o, bitBuf := buf, bitCnt := cnt }

private def BitWriter.flushAligned (bw : BitWriter) : ByteArray :=
  if bw.bitCnt == 0 then bw.out
  else bw.out.push (bw.bitBuf &&& 0xFF).toUInt8

private def writeFixedLitSym (bw : BitWriter) (sym : Nat) : BitWriter :=
  if sym <= 143 then
    bw.writeBits (reverseBits (0x30 + sym) 8) 8
  else if sym <= 255 then
    bw.writeBits (reverseBits (0x190 + (sym - 144)) 9) 9
  else if sym <= 279 then
    bw.writeBits (reverseBits (sym - 256) 7) 7
  else
    bw.writeBits (reverseBits (0xC0 + (sym - 280)) 8) 8

private def findLenIdx (len : Nat) : Nat := Id.run do
  if len == 258 then return 28
  let mut idx : Nat := 0
  for i in [0:28] do
    if len >= lenBaseTable[i]! then idx := i
  return idx

private def findDistIdx (dist : Nat) : Nat := Id.run do
  let mut lo : Nat := 0
  let mut hi : Nat := 29
  while lo < hi do
    let mid := (lo + hi + 1) / 2
    if dist >= distBaseTable[mid]! then lo := mid else hi := mid - 1
  return lo

/-- Compress `raw` into a valid RFC 1952 `gzip` member using RFC 1951 fixed-Huffman
    LZ77 (`32 KiB` sliding window, 4-byte hash table) + IEEE 802.3 CRC-32 + `ISIZE`. -/
def gzipCompress (raw : ByteArray) : ByteArray := Id.run do
  let hdr := ByteArray.mk #[0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03]
  let mut bw : BitWriter := { out := hdr }
  -- BFINAL=1 (1 bit), BTYPE=01 fixed Huffman (2 bits) => 0b011 = 3 in 3 LSB bits
  bw := bw.writeBits 3 3
  let n := raw.size
  let hashBits : Nat := 12
  let hashSize : Nat := 1 <<< hashBits
  let hashMask : UInt32 := (hashSize - 1).toUInt32
  -- Store `pos + 1` so `0` represents empty slot
  let mut head : Array UInt32 := Array.replicate hashSize 0
  let mut i : Nat := 0
  while i < n do
    let mut bestLen : Nat := 0
    let mut bestDist : Nat := 0
    if i + 4 <= n then
      let b0 := (raw.get! i).toUInt32
      let b1 := (raw.get! (i + 1)).toUInt32
      let b2 := (raw.get! (i + 2)).toUInt32
      let b3 := (raw.get! (i + 3)).toUInt32
      let w4 := b0 ||| (b1 <<< 8) ||| (b2 <<< 16) ||| (b3 <<< 24)
      let hIdx := (((w4 * 0x9E3779B1) >>> 20) &&& hashMask).toNat
      let prev1 := head[hIdx]!
      head := head.set! hIdx (i + 1).toUInt32
      if prev1 > 0 then
        let cand := prev1.toNat - 1
        let dist := i - cand
        if dist >= 1 && dist <= 32768 then
          let maxL := Nat.min 258 (n - i)
          if raw.get! cand == raw.get! i &&
             raw.get! (cand + 1) == raw.get! (i + 1) &&
             raw.get! (cand + 2) == raw.get! (i + 2) then
            let mut l : Nat := 3
            while l < maxL && raw.get! (cand + l) == raw.get! (i + l) do
              l := l + 1
            bestLen := l
            bestDist := dist
    if bestLen >= 4 then
      let lIdx := findLenIdx bestLen
      bw := writeFixedLitSym bw (257 + lIdx)
      let lEx := lenExtraTable[lIdx]!
      if lEx > 0 then
        bw := bw.writeBits (bestLen - lenBaseTable[lIdx]!) lEx
      let dIdx := findDistIdx bestDist
      bw := bw.writeBits (reverseBits dIdx 5) 5
      let dEx := distExtraTable[dIdx]!
      if dEx > 0 then
        bw := bw.writeBits (bestDist - distBaseTable[dIdx]!) dEx
      -- Update intermediate 4-byte hashes so overlapping JSON keys still chain cleanly
      let mut step : Nat := 1
      let stepCap := Nat.min bestLen 16
      while step < stepCap && i + step + 4 <= n do
        let p := i + step
        let w := (raw.get! p).toUInt32 ||| ((raw.get! (p + 1)).toUInt32 <<< 8) |||
                 ((raw.get! (p + 2)).toUInt32 <<< 16) ||| ((raw.get! (p + 3)).toUInt32 <<< 24)
        let idx2 := (((w * 0x9E3779B1) >>> 20) &&& hashMask).toNat
        head := head.set! idx2 (p + 1).toUInt32
        step := step + 1
      i := i + bestLen
    else
      bw := writeFixedLitSym bw (raw.get! i).toNat
      i := i + 1
  -- End-of-block symbol 256
  bw := writeFixedLitSym bw 256
  let mut out := bw.flushAligned
  let crc := crc32 raw
  let isize : UInt32 := (n % 4294967296).toUInt32
  out := out.push (crc &&& 0xFF).toUInt8
  out := out.push ((crc >>> 8) &&& 0xFF).toUInt8
  out := out.push ((crc >>> 16) &&& 0xFF).toUInt8
  out := out.push ((crc >>> 24) &&& 0xFF).toUInt8
  out := out.push (isize &&& 0xFF).toUInt8
  out := out.push ((isize >>> 8) &&& 0xFF).toUInt8
  out := out.push ((isize >>> 16) &&& 0xFF).toUInt8
  out := out.push ((isize >>> 24) &&& 0xFF).toUInt8
  return out

end OrbNetLeaf.Gzip
