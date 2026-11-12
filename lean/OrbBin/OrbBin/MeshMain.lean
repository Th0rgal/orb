/-
  OrbBin.MeshMain: Native Lean `lean-mesh` CLI Entrypoint (`0 import Lean`),
  supporting all 11 subcommands (`init-fleet`, `verify-manifest`, `eval-route`, `render-wg`,
  `sign-manifest`, `node-keygen`, `sign-canary`, `render-nft`, `reconcile-wg`, `bunker-step`, `audit-abi`).
-/
import LeanMesh.Kernel
import OrbBin.PosixExt
import OrbBin.Json
import OrbBin.MeshCli

namespace OrbBin.MeshMainImpl

open LeanMesh.Kernel
open OrbBin.PosixExt
open OrbBin.Json
open OrbBin.MeshCli

def findOptVal? (args : List String) (flag : String) : Option String :=
  match args with
  | [] => none
  | a :: b :: rest =>
    if a == flag then some b
    else if a.startsWith (flag ++ "=") then some ((a.drop (flag.length + 1)).toString)
    else findOptVal? (b :: rest) flag
  | [a] =>
    if a.startsWith (flag ++ "=") then some ((a.drop (flag.length + 1)).toString)
    else none

def hasFlag (args : List String) (flag : String) : Bool :=
  args.contains flag

def firstPositional? (args : List String) (boolFlags : List String := []) : Option String :=
  match args with
  | [] => none
  | a :: rest =>
    if a.startsWith "--" then
      if a.contains '=' || boolFlags.contains a then firstPositional? rest boolFlags
      else match rest with
        | [] => none
        | _ :: tail => firstPositional? tail boolFlags
    else some a

def loadManifestFile (path : String) : IO (Except String MeshManifest) := do
  let raw ← try IO.FS.readFile path catch e => return .error s!"failed reading `{path}`: {e}"
  return (Json.parse raw) >>= MeshManifest.ofJVal

def loadSeedHexFile (path : String) : IO (Except String ByteArray) := do
  let raw ← try IO.FS.readFile path catch e => return .error s!"failed reading `{path}`: {e}"
  match hexDecode? raw.trimAscii.toString with
  | some b =>
    if b.size == 32 then return .ok b
    else return .error s!"`{path}` must contain 32-byte hex seed"
  | none => return .error s!"invalid hex in `{path}`"

def withReplacedExt (p : String) (newExt : String) : String :=
  let fp := System.FilePath.mk p
  let stem := fp.fileStem.getD p
  match fp.parent with
  | some dir =>
    let ds := dir.toString
    if ds.isEmpty || ds == "." then s!"{stem}.{newExt}" else s!"{ds}/{stem}.{newExt}"
  | none => s!"{stem}.{newExt}"

def parseRenderConfig (args : List String) : Except String MeshRenderConfig := do
  let iface := (findOptVal? args "--interface").getD "wg-leanmesh0"
  let nftTbl := (findOptVal? args "--nft-table").getD "lean_mesh"
  let portNat ← match findOptVal? args "--listen-port" with
    | none => pure 51888
    | some s =>
      match s.toNat? with
      | some p =>
        if 1 ≤ p && p ≤ 65535 then pure p
        else throw s!"--listen-port `{s}` must be in 1..65535"
      | none => throw s!"invalid --listen-port `{s}`"
  let denyGid? ← match findOptVal? args "--deny-skgid" with
    | none => pure none
    | some s =>
      match s.toNat? with
      | some g =>
        if g ≤ 0xFFFFFFFF then pure (some g.toUInt32)
        else throw s!"--deny-skgid `{s}` out of UInt32 range"
      | none => throw s!"invalid --deny-skgid `{s}`"
  validateRenderConfig {
    interfaceName := iface
    nftTableName  := nftTbl
    defaultPort   := portNat.toUInt16
    pskDir?       := findOptVal? args "--psk-dir"
    denySkGid?    := denyGid?
    jitBiometric  := hasFlag args "--jit-biometric"
  }

def runMeshCli (args : List String) : IO (Except String Unit) := do
  match args with
  | [] | ["-h"] | ["--help"] | ["help"] =>
    IO.println "lean-mesh 0.2.0 (Lean 4)\nSubcommands: init-fleet, verify-manifest, eval-route, render-wg, sign-manifest, node-keygen, sign-canary, render-nft, reconcile-wg, roam-select, bunker-step, audit-abi"
    return .ok ()
  | ["-V"] | ["--version"] =>
    IO.println "lean-mesh 0.2.0"
    return .ok ()
  | sub :: rest =>
    if rest.contains "--help" || rest.contains "-h" then
      IO.println s!"Usage: lean-mesh {sub} [options]"
      return .ok ()
    let sysNow ← nowEpoch
    match sub with
    | "init-fleet" =>
      let outPath := (findOptVal? rest "--out").getD "paloma-fleet-manifest.json"
      let nowVal := ((findOptVal? rest "--now") >>= String.toNat?).map (·.toUInt64) |>.getD sysNow
      let seed ← match findOptVal? rest "--seed-hex" with
        | some hx =>
          match hexDecode? hx with
          | some b =>
            if b.size == 32 then pure b
            else return .error "--seed-hex must decode to exactly 32 bytes"
          | none => return .error "invalid --seed-hex encoding"
        | none => generateCsprngSeed32
      if let some seedOut := findOptVal? rest "--seed-out" then
        if let .error e ← writeAtomicPrivate0600 (System.FilePath.mk seedOut) ((LeanSys.Auth.bytesToHexLower seed) ++ "\n").toUTF8 then
          return .error e
      let (manifest, peerSeedsJson) ← match (← initPalomaFleet nowVal seed) with
        | .ok res => pure res
        | .error e => return .error e
      let peerKeysPath := (findOptVal? rest "--peer-seeds-out").getD (withReplacedExt outPath "peer-keys.json")
      if let .error e ← writeAtomicPrivate0600 (System.FilePath.mk peerKeysPath) (renderPretty peerSeedsJson).toUTF8 then
        return .error e
      if let .error e ← writeAtomicPrivate0600 (System.FilePath.mk outPath) (renderPretty manifest.toJVal).toUTF8 then
        return .error e
      IO.println s!"Generated signed Paloma fleet manifest at {outPath} and 0600 peer keystore at {peerKeysPath} (epoch={manifest.epoch}, coordinator_pubkey={manifest.coordinatorPubkeyHex}, peers={manifest.peers.size}, rules={manifest.rules.size})"
      return .ok ()
    | "verify-manifest" =>
      let some mPath := (findOptVal? rest "--manifest").orElse (fun _ => firstPositional? rest)
        | return .error "verify-manifest requires <MANIFEST>"
      let curEpoch := ((findOptVal? rest "--current-epoch") >>= String.toNat?).map (·.toUInt64) |>.getD 0
      let curPanic := ((findOptVal? rest "--current-panic-seq") >>= String.toNat?).map (·.toUInt64) |>.getD 0
      let nowVal := ((findOptVal? rest "--now") >>= String.toNat?).map (·.toUInt64) |>.getD sysNow
      let m ← match (← loadManifestFile mPath) with
        | .ok x => pure x
        | .error e => return .error e
      match (← m.verifyFormal curEpoch curPanic nowVal) with
      | .ok decision =>
        IO.println (renderPretty decision)
        return .ok ()
      | .error e => return .error e
    | "eval-route" =>
      let some mPath := findOptVal? rest "--manifest" | return .error "eval-route requires --manifest"
      let some src := findOptVal? rest "--src" | return .error "eval-route requires --src"
      let some dst := findOptVal? rest "--dst" | return .error "eval-route requires --dst"
      let protoStr := (findOptVal? rest "--proto").getD "tcp"
      let some proto := MeshProto.ofStr? protoStr | return .error s!"invalid --proto `{protoStr}`"
      let port := ((findOptVal? rest "--port") >>= String.toNat?).getD 0 |>.toUInt32
      let bunkerStr := (findOptVal? rest "--bunker").getD "normal"
      let some bunker := BunkerState.ofCliArg? bunkerStr | return .error s!"invalid --bunker `{bunkerStr}`"
      let jit := hasFlag rest "--jit-biometric"
      let nowVal := ((findOptVal? rest "--now") >>= String.toNat?).map (·.toUInt64) |>.getD sysNow
      let m ← match (← loadManifestFile mPath) with
        | .ok x => pure x
        | .error e => return .error e
      if let .error e ← m.verifyFormal 0 0 nowVal then return .error e
      let jitExp := if jit then nowVal + 600 else 0
      match m.evaluateRoute src dst proto port jit jitExp bunker nowVal with
      | .error e => return .error e
      | .ok (allowed, decJson) =>
        IO.println (renderPretty decJson)
        if !allowed then return .error "Route DENIED by LeanMesh.Kernel"
        return .ok ()
    | "render-wg" =>
      let some mPath := findOptVal? rest "--manifest" | return .error "render-wg requires --manifest"
      let some node := findOptVal? rest "--node" | return .error "render-wg requires --node"
      let bunkerStr := (findOptVal? rest "--bunker").getD "normal"
      let some bunker := BunkerState.ofCliArg? bunkerStr | return .error s!"invalid --bunker `{bunkerStr}`"
      let nowVal := ((findOptVal? rest "--now") >>= String.toNat?).map (·.toUInt64) |>.getD sysNow
      let privKey ← match findOptVal? rest "--private-key-file" with
        | some pkf =>
          try pure (← IO.FS.readFile pkf).trimAscii.toString
          catch e => return .error s!"failed reading `{pkf}`: {e}"
        | none => pure "<NODE_WG_PRIVATE_KEY>"
      let rcfg ← match parseRenderConfig rest with
        | .ok c => pure c
        | .error e => return .error e
      let m ← match (← loadManifestFile mPath) with
        | .ok x => pure x
        | .error e => return .error e
      match (← m.renderWireguardConfig node privKey bunker nowVal rcfg) with
      | .ok cfg =>
        IO.print cfg
        return .ok ()
      | .error e => return .error e
    | "sign-manifest" =>
      let some mPath := findOptVal? rest "--manifest" | return .error "sign-manifest requires --manifest"
      let some skPath := findOptVal? rest "--signing-key-file" | return .error "sign-manifest requires --signing-key-file"
      let outPath := (findOptVal? rest "--output").getD mPath
      let m ← match (← loadManifestFile mPath) with
        | .ok x => pure x
        | .error e => return .error e
      let seed ← match (← loadSeedHexFile skPath) with
        | .ok s => pure s
        | .error e => return .error e
      let signed ← match (← m.signWithSeed seed) with
        | .ok sm => pure sm
        | .error e => return .error e
      if let .error e ← signed.verifyFormal 0 0 sysNow then return .error e
      if let .error e ← writeAtomicPrivate0600 (System.FilePath.mk outPath) (renderPretty signed.toJVal).toUTF8 then
        return .error e
      IO.println s!"Signed and verified manifest at {outPath} (epoch={signed.epoch}, coordinator_pubkey={signed.coordinatorPubkeyHex})"
      return .ok ()
    | "node-keygen" =>
      let some outSeed := findOptVal? rest "--out-seed" | return .error "node-keygen requires --out-seed"
      let seed ← generateCsprngSeed32
      if let .error e ← writeAtomicPrivate0600 (System.FilePath.mk outSeed) ((LeanSys.Auth.bytesToHexLower seed) ++ "\n").toUTF8 then
        return .error e
      match (← OrbNetLeaf.Crypto.ed25519PublicKey seed) with
      | .ok pk =>
        IO.println (LeanSys.Auth.bytesToHexLower pk)
        return .ok ()
      | .error e => return .error e
    | "sign-canary" =>
      let some node := findOptVal? rest "--node" | return .error "sign-canary requires --node"
      let some skPath := findOptVal? rest "--signing-key-file" | return .error "sign-canary requires --signing-key-file"
      let some kind := findOptVal? rest "--canary-kind" | return .error "sign-canary requires --canary-kind"
      let some seqNat := (findOptVal? rest "--seq") >>= String.toNat? | return .error "sign-canary requires --seq"
      if seqNat == 0 then return .error "--seq must be > 0 for ReplayWindow64 admission"
      let ts := ((findOptVal? rest "--timestamp") >>= String.toNat?).map (·.toUInt64) |>.getD sysNow
      let reason := (findOptVal? rest "--reason").getD "Canary tripwire triggered"
      let pid := ((findOptVal? rest "--pid") >>= String.toNat?).map (·.toUInt32)
      let uid := ((findOptVal? rest "--uid") >>= String.toNat?).map (·.toUInt32)
      let cgroup := findOptVal? rest "--cgroup"
      let cmdline := findOptVal? rest "--cmdline"
      let dryRun := hasFlag rest "--dry-run"
      let seed ← match (← loadSeedHexFile skPath) with
        | .ok s => pure s
        | .error e => return .error e
      let detailHex := canonicalCanaryEvidenceSha256Hex reason pid uid cgroup cmdline
      let sigHex ← match (← signCanaryTrip seed node kind seqNat.toUInt64 ts dryRun detailHex) with
        | .ok s => pure s
        | .error e => return .error e
      let outJson := JVal.obj #[
        ("peer_name", .str node),
        ("canary_kind", .str kind),
        ("event_seq", .uint64 seqNat.toUInt64),
        ("timestamp", .uint64 ts),
        ("dry_run", .bool dryRun),
        ("reason", .str reason),
        ("pid", match pid with | some p => .nat p.toNat | none => .null),
        ("uid", match uid with | some u => .nat u.toNat | none => .null),
        ("cgroup", match cgroup with | some c => .str c | none => .null),
        ("cmdline", match cmdline with | some c => .str c | none => .null),
        ("detail_sha256_hex", .str detailHex),
        ("signature_hex", .str sigHex)
      ]
      IO.println (renderCompact outJson)
      return .ok ()
    | "render-nft" =>
      let some mPath := findOptVal? rest "--manifest" | return .error "render-nft requires --manifest"
      let some node := findOptVal? rest "--node" | return .error "render-nft requires --node"
      let bunkerStr := (findOptVal? rest "--bunker").getD "normal"
      let some bunker := BunkerState.ofCliArg? bunkerStr | return .error s!"invalid --bunker `{bunkerStr}`"
      let nowVal := ((findOptVal? rest "--now") >>= String.toNat?).map (·.toUInt64) |>.getD sysNow
      let rcfg ← match parseRenderConfig rest with
        | .ok c => pure c
        | .error e => return .error e
      let m ← match (← loadManifestFile mPath) with
        | .ok x => pure x
        | .error e => return .error e
      match (← m.renderNftablesPolicy node bunker nowVal rcfg) with
      | .ok nft =>
        IO.print nft
        return .ok ()
      | .error e => return .error e
    | "reconcile-wg" =>
      let some mPath := findOptVal? rest "--manifest" | return .error "reconcile-wg requires --manifest"
      let some node := findOptVal? rest "--node" | return .error "reconcile-wg requires --node"
      let some dumpPath := findOptVal? rest "--wg-dump" | return .error "reconcile-wg requires --wg-dump"
      let bunkerStr := (findOptVal? rest "--bunker").getD "normal"
      let some bunker := BunkerState.ofCliArg? bunkerStr | return .error s!"invalid --bunker `{bunkerStr}`"
      let nowVal := ((findOptVal? rest "--now") >>= String.toNat?).map (·.toUInt64) |>.getD sysNow
      let rcfg ← match parseRenderConfig rest with
        | .ok c => pure c
        | .error e => return .error e
      let m ← match (← loadManifestFile mPath) with
        | .ok x => pure x
        | .error e => return .error e
      let dumpRaw ← try IO.FS.readFile dumpPath catch e => return .error s!"failed reading `{dumpPath}`: {e}"
      match (← m.reconcileWireguardDump node dumpRaw bunker nowVal rcfg) with
      | .ok plans =>
        IO.println (renderPretty plans)
        return .ok ()
      | .error e => return .error e
    | "roam-select" =>
      let srcId := (((findOptVal? rest "--src-id") >>= String.toNat?).getD 10).toUInt32
      let dstId := (((findOptVal? rest "--dst-id") >>= String.toNat?).getD 20).toUInt32
      let relayId := (((findOptVal? rest "--relay-id") >>= String.toNat?).getD 1).toUInt32
      let activeRelays := (((findOptVal? rest "--active-relays") >>= String.toNat?).getD 0).toUInt32
      let maxRelays := (((findOptVal? rest "--max-relays") >>= String.toNat?).getD 64).toUInt32
      let nowVal := ((findOptVal? rest "--now") >>= String.toNat?).map (·.toUInt64) |>.getD sysNow
      let hsAt := (((findOptVal? rest "--direct-handshake-at") >>= String.toNat?).map (·.toUInt64)).getD nowVal
      let maxStale := (((findOptVal? rest "--max-stale-secs") >>= String.toNat?).getD 120).toUInt64
      let lanEp? := findOptVal? rest "--lan-endpoint"
      let wanEp? := findOptVal? rest "--wan-endpoint"
      let relayEp? := findOptVal? rest "--relay-endpoint"
      let routeOk := !(hasFlag rest "--route-denied")
      let lanOk := hasFlag rest "--lan-ok"
      let wanOk := hasFlag rest "--wan-ok"
      let relayOk := hasFlag rest "--relay-ok"
      let j := selectTransportPathJson routeOk lanOk wanOk relayOk
        srcId dstId relayId activeRelays maxRelays nowVal hsAt maxStale lanEp? wanEp? relayEp?
      IO.println (renderCompact j)
      return .ok ()
    | "bunker-step" =>
      let curStr := (findOptVal? rest "--current").getD "normal"
      let some cur := BunkerState.ofCliArg? curStr | return .error s!"invalid --current `{curStr}`"
      let sov := hasFlag rest "--sovereign"
      let can := hasFlag rest "--canary"
      let burst := hasFlag rest "--burst"
      let manual := ((findOptVal? rest "--manual") >>= String.toNat?).getD 0 |>.toUInt8
      let unbunker := hasFlag rest "--unbunker"
      let hbAge := ((findOptVal? rest "--heartbeat-age-secs") >>= String.toNat?).getD 10 |>.toUInt64
      let dmTimeout := ((findOptVal? rest "--deadman-timeout-secs") >>= String.toNat?).getD 180 |>.toUInt64
      let nowRef : UInt64 := 10000
      let lastHb := if hbAge ≤ nowRef then nowRef - hbAge else 0
      let raw := bunkerIsolateStep cur.toUInt8
        (if sov then 1 else 0) (if can then 1 else 0) (if burst then 1 else 0)
        manual (if unbunker then 1 else 0) 1 nowRef lastHb dmTimeout
      let nextState := BunkerState.ofUInt8 (raw &&& 0xFF).toUInt8
      let j := JVal.obj #[
        ("next_state", .str nextState.toSnakeJson),
        ("revoke_jit_grants", .bool ((raw &&& 256) != 0)),
        ("prune_non_admin_wg_peers", .bool ((raw &&& 65536) != 0)),
        ("lock_sovereign_vault", .bool ((raw &&& 16777216) != 0))
      ]
      IO.println (renderPretty j)
      return .ok ()
    | "audit-abi" =>
      match runAuditAbi with
      | .ok j =>
        IO.println (renderCompact j)
        return .ok ()
      | .error e => return .error e
    | other =>
      return .error s!"unknown lean-mesh subcommand `{other}`"

def runMain (args : List String) : IO UInt32 := do
  match (← runMeshCli args) with
  | .ok () => return 0
  | .error err =>
    IO.eprintln s!"Error: {err}"
    return 1

end OrbBin.MeshMainImpl
