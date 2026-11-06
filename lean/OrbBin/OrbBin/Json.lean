/-
  OrbBin.Json: Pure, Total RFC 8259 JSON Value AST, Parser, Compact & Pretty Serializer (`0 import Lean`).
-/
namespace OrbBin.Json

inductive JVal where
  | null
  | bool (b : Bool)
  | num  (raw : String)
  | str  (s : String)
  | arr  (items : Array JVal)
  | obj  (fields : Array (String × JVal))
  deriving Repr, Inhabited, BEq

namespace JVal

def int (n : Int) : JVal := .num (toString n)
def nat (n : Nat) : JVal := .num (toString n)
def uint64 (n : UInt64) : JVal := .num (toString n)

def isNull : JVal → Bool
  | .null => true
  | _ => false

def asStr? : JVal → Option String
  | .str s => some s
  | _ => none

def asBool? : JVal → Option Bool
  | .bool b => some b
  | _ => none

def asNat? : JVal → Option Nat
  | .num raw => raw.trimAscii.toString.toNat?
  | _ => none

def asUInt64? : JVal → Option UInt64
  | .num raw => (raw.trimAscii.toString.toNat?).map (·.toUInt64)
  | _ => none

def asInt? : JVal → Option Int
  | .num raw => raw.trimAscii.toString.toInt?
  | _ => none

def asArr? : JVal → Option (Array JVal)
  | .arr xs => some xs
  | _ => none

def asObj? : JVal → Option (Array (String × JVal))
  | .obj kvs => some kvs
  | _ => none

def field? (v : JVal) (k : String) : Option JVal :=
  match v with
  | .obj kvs => (kvs.find? (fun (fk, _) => fk == k)).map Prod.snd
  | _ => none

def fieldOrNull (v : JVal) (k : String) : JVal :=
  (v.field? k).getD .null

def fieldStr? (v : JVal) (k : String) : Option String :=
  (v.field? k) >>= asStr?

def fieldBool? (v : JVal) (k : String) : Option Bool :=
  (v.field? k) >>= asBool?

def fieldNat? (v : JVal) (k : String) : Option Nat :=
  (v.field? k) >>= asNat?

def fieldUInt64? (v : JVal) (k : String) : Option UInt64 :=
  (v.field? k) >>= asUInt64?

def fieldInt? (v : JVal) (k : String) : Option Int :=
  (v.field? k) >>= asInt?

def fieldArr? (v : JVal) (k : String) : Option (Array JVal) :=
  (v.field? k) >>= asArr?

def setField (v : JVal) (k : String) (nv : JVal) : JVal :=
  match v with
  | .obj kvs =>
    if kvs.any (fun (fk, _) => fk == k) then
      .obj (kvs.map (fun (fk, fv) => if fk == k then (k, nv) else (fk, fv)))
    else
      .obj (kvs.push (k, nv))
  | other => other

def removeField (v : JVal) (k : String) : JVal :=
  match v with
  | .obj kvs => .obj (kvs.filter (fun (fk, _) => fk != k))
  | other => other

end JVal

/-! ### String Escaping & Compact / Pretty Rendering -/

private def hexDigitLower (n : Nat) : Char :=
  let d := n % 16
  if d < 10 then Char.ofNat ('0'.toNat + d) else Char.ofNat ('a'.toNat + (d - 10))

def escapeJsonString (s : String) : String := Id.run do
  let mut out : Array Char := Array.mkEmpty (s.length + 4)
  out := out.push '"'
  for c in s.toList do
    let code := c.toNat
    if c == '"' then
      out := out.push '\\'; out := out.push '"'
    else if c == '\\' then
      out := out.push '\\'; out := out.push '\\'
    else if c == '\n' then
      out := out.push '\\'; out := out.push 'n'
    else if c == '\r' then
      out := out.push '\\'; out := out.push 'r'
    else if c == '\t' then
      out := out.push '\\'; out := out.push 't'
    else if code == 0x08 then
      out := out.push '\\'; out := out.push 'b'
    else if code == 0x0C then
      out := out.push '\\'; out := out.push 'f'
    else if code < 0x20 then
      out := out.push '\\'; out := out.push 'u'
      out := out.push '0'; out := out.push '0'
      out := out.push (hexDigitLower (code / 16))
      out := out.push (hexDigitLower (code % 16))
    else
      out := out.push c
  out := out.push '"'
  return String.ofList out.toList

partial def renderCompact : JVal → String
  | .null => "null"
  | .bool true => "true"
  | .bool false => "false"
  | .num raw => raw
  | .str s => escapeJsonString s
  | .arr xs =>
    "[" ++ String.intercalate "," (xs.toList.map renderCompact) ++ "]"
  | .obj kvs =>
    "{" ++ String.intercalate "," (kvs.toList.map fun (k, v) =>
      escapeJsonString k ++ ":" ++ renderCompact v) ++ "}"

private def indentSpaces (n : Nat) : String :=
  String.ofList (List.replicate n ' ')

partial def renderPrettyAux (indent : Nat) : JVal → String
  | .null => "null"
  | .bool true => "true"
  | .bool false => "false"
  | .num raw => raw
  | .str s => escapeJsonString s
  | .arr xs =>
    if xs.isEmpty then "[]"
    else
      let inner := indent + 2
      let pad := indentSpaces inner
      let endPad := indentSpaces indent
      let rendered := xs.toList.map (fun x => pad ++ renderPrettyAux inner x)
      "[\n" ++ String.intercalate ",\n" rendered ++ "\n" ++ endPad ++ "]"
  | .obj kvs =>
    if kvs.isEmpty then "{}"
    else
      let inner := indent + 2
      let pad := indentSpaces inner
      let endPad := indentSpaces indent
      let rendered := kvs.toList.map (fun (k, v) =>
        pad ++ escapeJsonString k ++ ": " ++ renderPrettyAux inner v)
      "{\n" ++ String.intercalate ",\n" rendered ++ "\n" ++ endPad ++ "}"

def renderPretty (v : JVal) : String :=
  renderPrettyAux 0 v

/-! ### Total Fuel-Bounded Recursive-Descent RFC 8259 Parser -/

private def isWsByte (b : UInt8) : Bool :=
  b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D

private def skipWs (bs : ByteArray) (pos : Nat) : Nat := Id.run do
  let mut i := pos
  while i < bs.size && isWsByte (bs.get! i) do
    i := i + 1
  return i

private def hexByteVal? (b : UInt8) : Option UInt32 :=
  if 0x30 ≤ b && b ≤ 0x39 then some (b - 0x30).toUInt32
  else if 0x61 ≤ b && b ≤ 0x66 then some (10 + (b - 0x61)).toUInt32
  else if 0x41 ≤ b && b ≤ 0x46 then some (10 + (b - 0x41)).toUInt32
  else none

private def parseHex4? (bs : ByteArray) (pos : Nat) : Option UInt32 :=
  if pos + 4 > bs.size then none
  else do
    let d0 ← hexByteVal? (bs.get! pos)
    let d1 ← hexByteVal? (bs.get! (pos + 1))
    let d2 ← hexByteVal? (bs.get! (pos + 2))
    let d3 ← hexByteVal? (bs.get! (pos + 3))
    return (d0 <<< 12) ||| (d1 <<< 8) ||| (d2 <<< 4) ||| d3

private def pushCodepointUtf8 (buf : ByteArray) (cp : UInt32) : ByteArray :=
  if cp ≤ 0x7F then
    buf.push cp.toUInt8
  else if cp ≤ 0x7FF then
    let b0 := ((0xC0 : UInt32) ||| ((cp >>> 6) &&& (0x1F : UInt32))).toUInt8
    let b1 := ((0x80 : UInt32) ||| (cp &&& (0x3F : UInt32))).toUInt8
    (buf.push b0).push b1
  else if cp ≤ 0xFFFF then
    let b0 := ((0xE0 : UInt32) ||| ((cp >>> 12) &&& (0x0F : UInt32))).toUInt8
    let b1 := ((0x80 : UInt32) ||| ((cp >>> 6) &&& (0x3F : UInt32))).toUInt8
    let b2 := ((0x80 : UInt32) ||| (cp &&& (0x3F : UInt32))).toUInt8
    ((buf.push b0).push b1).push b2
  else
    let b0 := ((0xF0 : UInt32) ||| ((cp >>> 18) &&& (0x07 : UInt32))).toUInt8
    let b1 := ((0x80 : UInt32) ||| ((cp >>> 12) &&& (0x3F : UInt32))).toUInt8
    let b2 := ((0x80 : UInt32) ||| ((cp >>> 6) &&& (0x3F : UInt32))).toUInt8
    let b3 := ((0x80 : UInt32) ||| (cp &&& (0x3F : UInt32))).toUInt8
    (((buf.push b0).push b1).push b2).push b3

private def parseJsonStringAt (bs : ByteArray) (pos : Nat) : Except String (String × Nat) := Id.run do
  if pos ≥ bs.size || bs.get! pos != 0x22 then
    return .error "expected '\"'"
  let mut i := pos + 1
  let mut out := ByteArray.emptyWithCapacity 32
  while i < bs.size do
    let b := bs.get! i
    if b == 0x22 then
      match String.fromUTF8? out with
      | some s => return .ok (s, i + 1)
      | none => return .error "invalid UTF-8 in JSON string"
    else if b == 0x5C then
      if i + 1 ≥ bs.size then return .error "unterminated escape in JSON string"
      let esc := bs.get! (i + 1)
      if esc == 0x22 || esc == 0x5C || esc == 0x2F then
        out := out.push esc; i := i + 2
      else if esc == 0x62 then out := out.push 0x08; i := i + 2
      else if esc == 0x66 then out := out.push 0x0C; i := i + 2
      else if esc == 0x6E then out := out.push 0x0A; i := i + 2
      else if esc == 0x72 then out := out.push 0x0D; i := i + 2
      else if esc == 0x74 then out := out.push 0x09; i := i + 2
      else if esc == 0x75 then
        match parseHex4? bs (i + 2) with
        | none => return .error "invalid \\uXXXX escape"
        | some u1 =>
          if 0xD800 ≤ u1 && u1 ≤ 0xDBFF then
            if i + 12 ≤ bs.size && bs.get! (i + 6) == 0x5C && bs.get! (i + 7) == 0x75 then
              match parseHex4? bs (i + 8) with
              | some u2 =>
                if 0xDC00 ≤ u2 && u2 ≤ 0xDFFF then
                  let cp : UInt32 := (0x10000 : UInt32) + (((u1 - 0xD800) <<< 10) ||| (u2 - 0xDC00))
                  out := pushCodepointUtf8 out cp
                  i := i + 12
                else
                  return .error "invalid UTF-16 low surrogate"
              | none => return .error "invalid UTF-16 surrogate pair"
            else
              return .error "unpaired UTF-16 high surrogate"
          else if 0xDC00 ≤ u1 && u1 ≤ 0xDFFF then
            return .error "unpaired UTF-16 low surrogate"
          else
            out := pushCodepointUtf8 out u1
            i := i + 6
      else
        return .error "unknown JSON string escape"
    else if b < 0x20 then
      return .error "unescaped control character in JSON string"
    else
      out := out.push b
      i := i + 1
  return .error "unterminated JSON string"

private def isNumCharByte (b : UInt8) : Bool :=
  (0x30 ≤ b && b ≤ 0x39) || b == 0x2D || b == 0x2B || b == 0x2E || b == 0x65 || b == 0x45

private def parseJsonNumberAt (bs : ByteArray) (pos : Nat) : Except String (JVal × Nat) := Id.run do
  let mut i := pos
  if i < bs.size && bs.get! i == 0x2D then i := i + 1
  if i ≥ bs.size then return .error "empty JSON number"
  let d0 := bs.get! i
  if d0 == 0x30 then
    i := i + 1
    if i < bs.size && 0x30 ≤ bs.get! i && bs.get! i ≤ 0x39 then
      return .error "leading zero in JSON number"
  else if 0x31 ≤ d0 && d0 ≤ 0x39 then
    while i < bs.size && 0x30 ≤ bs.get! i && bs.get! i ≤ 0x39 do
      i := i + 1
  else
    return .error "invalid JSON number start"
  if i < bs.size && bs.get! i == 0x2E then
    i := i + 1
    if i ≥ bs.size || !(0x30 ≤ bs.get! i && bs.get! i ≤ 0x39) then
      return .error "missing fraction digits in JSON number"
    while i < bs.size && 0x30 ≤ bs.get! i && bs.get! i ≤ 0x39 do
      i := i + 1
  if i < bs.size && (bs.get! i == 0x65 || bs.get! i == 0x45) then
    i := i + 1
    if i < bs.size && (bs.get! i == 0x2B || bs.get! i == 0x2D) then
      i := i + 1
    if i ≥ bs.size || !(0x30 ≤ bs.get! i && bs.get! i ≤ 0x39) then
      return .error "missing exponent digits in JSON number"
    while i < bs.size && 0x30 ≤ bs.get! i && bs.get! i ≤ 0x39 do
      i := i + 1
  if i < bs.size && isNumCharByte (bs.get! i) then
    return .error "trailing garbage in JSON number"
  match String.fromUTF8? (bs.extract pos i) with
  | some s => return .ok (.num s, i)
  | none => return .error "invalid UTF-8 in JSON number"

private def matchAsciiLit (bs : ByteArray) (pos : Nat) (lit : ByteArray) : Bool := Id.run do
  if pos + lit.size > bs.size then return false
  for k in [0:lit.size] do
    if bs.get! (pos + k) != lit.get! k then return false
  return true

partial def parseValueAt (bs : ByteArray) (pos : Nat) (depth : Nat) : Except String (JVal × Nat) := do
  if depth > 256 then throw "JSON nesting depth exceeded 256"
  let i := skipWs bs pos
  if i ≥ bs.size then throw "unexpected EOF in JSON"
  let b := bs.get! i
  if b == 0x6E then
    if matchAsciiLit bs i "null".toUTF8 then return (.null, i + 4)
    else throw "invalid JSON literal starting with 'n'"
  else if b == 0x74 then
    if matchAsciiLit bs i "true".toUTF8 then return (.bool true, i + 4)
    else throw "invalid JSON literal starting with 't'"
  else if b == 0x66 then
    if matchAsciiLit bs i "false".toUTF8 then return (.bool false, i + 5)
    else throw "invalid JSON literal starting with 'f'"
  else if b == 0x22 then
    let (s, next) ← parseJsonStringAt bs i
    return (.str s, next)
  else if b == 0x5B then
    let mut cur := skipWs bs (i + 1)
    if cur ≥ bs.size then throw "unterminated JSON array"
    if bs.get! cur == 0x5D then return (.arr #[], cur + 1)
    let mut items : Array JVal := #[]
    while true do
      let (elem, afterElem) ← parseValueAt bs cur (depth + 1)
      items := items.push elem
      cur := skipWs bs afterElem
      if cur ≥ bs.size then throw "unterminated JSON array"
      let sep := bs.get! cur
      if sep == 0x5D then
        return (.arr items, cur + 1)
      else if sep == 0x2C then
        cur := skipWs bs (cur + 1)
      else
        throw "expected ',' or ']' in JSON array"
    throw "unreachable"
  else if b == 0x7B then
    let mut cur := skipWs bs (i + 1)
    if cur ≥ bs.size then throw "unterminated JSON object"
    if bs.get! cur == 0x7D then return (.obj #[], cur + 1)
    let mut fields : Array (String × JVal) := #[]
    while true do
      if cur ≥ bs.size || bs.get! cur != 0x22 then
        throw "expected string key in JSON object"
      let (k, afterKey) ← parseJsonStringAt bs cur
      let colonPos := skipWs bs afterKey
      if colonPos ≥ bs.size || bs.get! colonPos != 0x3A then
        throw "expected ':' after JSON object key"
      let (v, afterVal) ← parseValueAt bs (colonPos + 1) (depth + 1)
      fields := fields.push (k, v)
      cur := skipWs bs afterVal
      if cur ≥ bs.size then throw "unterminated JSON object"
      let sep := bs.get! cur
      if sep == 0x7D then
        return (.obj fields, cur + 1)
      else if sep == 0x2C then
        cur := skipWs bs (cur + 1)
      else
        throw "expected ',' or '}' in JSON object"
    throw "unreachable"
  else if b == 0x2D || (0x30 ≤ b && b ≤ 0x39) then
    parseJsonNumberAt bs i
  else
    throw s!"unexpected byte {b} at offset {i} in JSON"

def parseBytes (bs : ByteArray) : Except String JVal := do
  let (v, afterPos) ← parseValueAt bs 0 0
  let endPos := skipWs bs afterPos
  if endPos != bs.size then
    throw s!"trailing characters in JSON at byte {endPos}"
  return v

def parse (s : String) : Except String JVal :=
  parseBytes s.toUTF8

end OrbBin.Json
