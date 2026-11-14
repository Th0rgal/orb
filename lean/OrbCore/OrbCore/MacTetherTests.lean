import OrbCore.Control

namespace OrbCore.MacTetherTests

open OrbCore.Control OrbCore.Store OrbCore.Managed OrbCore.MacTether OrbCore.MemoryAndCloud
open OrbBin.Json OrbBin.PosixExt LeanSys.Http

private def check (condition : Bool) (label : String) : IO Unit := do
  unless condition do throw (IO.userError s!"mac tether: {label}")

private def hex (b : ByteArray) : String := LeanSys.Auth.bytesToHexLower b

private def pushU32LE (b : ByteArray) (v : UInt32) : ByteArray :=
  b.push (v &&& 0xFF).toUInt8 |>.push ((v >>> 8) &&& 0xFF).toUInt8
    |>.push ((v >>> 16) &&& 0xFF).toUInt8 |>.push ((v >>> 24) &&& 0xFF).toUInt8

private def padTo (b : ByteArray) (size : Nat) (fill : UInt8) : ByteArray :=
  b ++ ByteArray.mk (Array.replicate (size - b.size) fill)

/-- WireGuard handshake initiation (type 1, 148 bytes) addressed to the peer with `responderPub32`. -/
private def wgInitPacket (responderPub32 : ByteArray) (senderIdx : UInt32) : IO ByteArray := do
  let head := padTo (pushU32LE (ByteArray.mk #[1, 0, 0, 0]) senderIdx) 116 0x42
  return padTo (head ++ (← wgMac1 responderPub32 head)) 148 0

/-- WireGuard handshake response (type 2, 92 bytes) addressed to the initiator with `initiatorPub32`. -/
private def wgRespPacket (initiatorPub32 : ByteArray) (senderIdx receiverIdx : UInt32) : IO ByteArray := do
  let head := padTo (pushU32LE (pushU32LE (ByteArray.mk #[2, 0, 0, 0]) senderIdx) receiverIdx) 60 0x24
  return padTo (head ++ (← wgMac1 initiatorPub32 head)) 92 0

/-- WireGuard transport data (type 4) for `receiverIdx`. -/
private def wgDataPacket (receiverIdx : UInt32) : ByteArray :=
  padTo (pushU32LE (ByteArray.mk #[4, 0, 0, 0]) receiverIdx) 64 0xAA

/-- The UDP and BLAKE2s shim against RFC 7693 / `hashlib.blake2s` vectors. -/
private def shimChecks : IO Unit := do
  let key32 := ByteArray.mk ((Array.range 32).map (·.toUInt8))
  check (hex (← blake2s ByteArray.empty "abc".toUTF8 32) ==
    "508c5e8c327c14e2e1a72ba34eeb452f37458b209ed63a294d999b4c86675982") "BLAKE2s-256 of abc"
  check (hex (← blake2s ByteArray.empty (ByteArray.mk (Array.replicate 64 0)) 32) ==
    "ae09db7cd54f42b490ef09b6bc541af688e4959bb8c53f359a6f56e38ab454a3") "BLAKE2s-256 of one full block"
  check (hex (← blake2s key32 ByteArray.empty 32) ==
    "48a8997da407876b3d79c0d92325ad3b89cbb754d86ab71aee047ad345fd2c49") "keyed BLAKE2s-256 of the empty message"
  check (hex (← blake2s key32 (ByteArray.mk ((Array.range 200).map (·.toUInt8))) 16) ==
    "42a6f8ff590af21b512e9e088257aa34") "keyed BLAKE2s-128 over several blocks"
  check (hex (← wgMac1 key32 (ByteArray.mk (Array.replicate 116 0x42))) ==
    "fe7603c3fa9d38645bc6b67fd06b6f78") "WireGuard mac1"
  check ((← wgMac1 (ByteArray.mk #[1, 2, 3]) ByteArray.empty).isEmpty) "mac1 needs a 32-byte key"
  let .ok (fdA, portA) ← udpBind "127.0.0.1" 0 | throw (IO.userError "mac tether: udp bind A")
  let .ok (fdB, portB) ← udpBind "127.0.0.1" 0 | throw (IO.userError "mac tether: udp bind B")
  let second ← udpBind "127.0.0.1" portA
  let sent ← udpSendTo fdA 0x7F000001 portB "ping".toUTF8
  let got ← udpRecvFromPoll fdB 1000 256
  closeFdRaw fdA
  closeFdRaw fdB
  if let .ok (fdC, _) := second then closeFdRaw fdC
  check (!second.isOk) "a bound relay port cannot be bound a second time"
  check (sent == 0 && (got.map (·.payload)) == some "ping".toUTF8 && (got.map (·.srcPort)) == some portA) "UDP loopback"
  check (parseIpv4U32? "10.88.200.10" == some 0x0A58C80A && formatIpv4U32 0x0A58C80A == "10.88.200.10") "IPv4 round trip"

set_option maxHeartbeats 800000
set_option maxRecDepth 200000

/-- The broker through the real HTTP and MCP boundary: who may ask, what the laptop daemon reads,
    who receives the lease token, and that revocation closes the relay. No host effects. -/
def run (root : String) : IO Unit := do
  shimChecks
  let path := root ++ "/mac-tether"
  let .ok store ← openCoreStore path | throw (IO.userError "mac tether: store")
  setenvVar "ORB_WG_RELAY_PUBLIC_ENDPOINT" "127.0.0.1:51890"
  setenvVar "ORB_WG_RELAY_BIND" "127.0.0.1"
  setenvVar "ORB_WG_RELAY_PORT" "0"
  let rt ← startMacTetherRuntime store
  for name in #["ORB_WG_RELAY_PUBLIC_ENDPOINT", "ORB_WG_RELAY_BIND", "ORB_WG_RELAY_PORT"] do unsetenvVar name
  try
    let now ← coreEpochSec
    let sql (query : String) (params : Array String := #[]) : IO (Array (Array String)) := do
      let .ok rows ← execParamQuery store.missionsDb query params | throw (IO.userError s!"mac tether: SQL {query}")
      return rows
    for (uid, role) in #[("admin", "admin"), ("member", "member")] do
      discard <| sql "INSERT INTO users(id,username,password_hash,role,unix_username) VALUES(?1,?1,'synthetic-hash',?2,?3);"
        #[uid, role, "orb-" ++ uid]
    for (mid, owner) in #[("admin-mission", "admin"), ("admin-other", "admin"), ("member-mission", "member")] do
      let .ok () ← upsertMission store {
        id := mid, ownerUserId := owner, title := mid ++ " title", status := "awaiting_user", backend := "codex",
        modelOverride := "", workingDirectory := path, project := "tether", updatedAt := "2026-11-14T10:00:00Z" }
        | throw (IO.userError "mac tether: mission fixture")
    let bunkerRef ← IO.mkRef (0 : UInt8)
    let st : CoreAppState := {
      cfg := { instanceName := "dev", jwtSecret := "synthetic-mac-tether-jwt-not-a-live-secret", workingDir := path },
      store := store, bootstrapAdminId := "admin", searchIdx? := none,
      managedRef := ← IO.mkRef ({ enabled := true } : ManagedFleetState), chainsRef := ← IO.mkRef #[],
      proxyCooldownsRef := ← IO.mkRef #[], seqRef := ← IO.mkRef 1,
      bunkerStateRef? := some bunkerRef, macTether? := some rt }
    let admin := mintSessionTokenV2 st.cfg.jwtSecret "admin" "admin" 1 (now + 3600)
    let member := mintSessionTokenV2 st.cfg.jwtSecret "member" "member" 1 (now + 3600)
    let missionToken (mid session : String) : String := mintScopedMcpToken st.cfg.jwtSecret
      { sessionId := session, missionId := mid, role := "executor", project := "tether", expiresAt := now + 3600 }
    let adminMission := missionToken "admin-mission" "11111111-1111-4111-8111-111111111111"
    let otherMission := missionToken "admin-other" "22222222-2222-4222-8222-222222222222"
    let memberMission := missionToken "member-mission" "33333333-3333-4333-8333-333333333333"
    let send (method target bearer : String) (body : JVal := .obj #[]) : IO (Nat × JVal) := do
      let payload := renderCompact body
      let wire := s!"{method} {target} HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer {bearer}\r\nContent-Type: application/json\r\nContent-Length: {payload.utf8ByteSize}\r\n\r\n{payload}"
      let .ok request := parseRequest wire.toUTF8 none | throw (IO.userError "mac tether: request")
      let .ok response ← dispatchCoreRequest st request now | throw (IO.userError "mac tether: dispatch")
      return (response.status, (parseBytes response.body).toOption.getD .null)
    let call (bearer tool : String) (args : JVal := .obj #[]) : IO JVal := do
      let (status, doc) ← send "POST" "/api/mcp/call" bearer (.obj #[("name", .str tool), ("arguments", args)])
      check (status == 200) s!"MCP transport {tool}"
      return doc
    let errorCode (doc : JVal) : Option String := (doc.fieldOrNull "error").fieldStr? "code"
    let has (doc : JVal) (needle : String) : Bool := ((renderCompact doc).splitOn needle).length > 1

    -- Every mission receives the three tools in its catalogue.
    let (capStatus, caps) ← send "GET" "/api/mcp/capabilities" adminMission
    let toolNames := ((caps.fieldArr? "tools").getD #[]).filterMap (·.fieldStr? "name")
    check (capStatus == 200 && #["request_macbook_tether", "list_macbook_tethers", "revoke_macbook_tether"].all toolNames.contains)
      "the mission catalogue lists the tether tools"

    let .ok (_, agentWgPub, agentWgPub32) ← generateWireguardKeypair | throw (IO.userError "mac tether: keygen")
    let .ok (agentKemPriv, agentKemPub, _) ← generateWireguardKeypair | throw (IO.userError "mac tether: keygen")
    let .ok (_, macWgPub, macWgPub32) ← generateWireguardKeypair | throw (IO.userError "mac tether: keygen")
    let .ok (macKemPriv, macKemPub, _) ← generateWireguardKeypair | throw (IO.userError "mac tether: keygen")
    let .ok (_, pskB64, _) ← generateWireguardKeypair | throw (IO.userError "mac tether: keygen")
    let .ok (_, agentSshPub) ← generateOpenSshEd25519Keypair "orb-tether-test" | throw (IO.userError "mac tether: ssh keygen")
    let requestArgs : JVal := .obj #[
      ("scope", .str "sandbox_ssh"), ("agent_ports", .arr #[.nat 3000]), ("ttl_minutes", .nat 30),
      ("session_scoped", .bool true), ("wait_secs", .nat 0), ("reason", .str "Run the preview build"),
      ("agent_wg_pubkey", .str agentWgPub), ("agent_kem_pubkey", .str agentKemPub), ("agent_ssh_pubkey", .str agentSshPub)]

    -- A mission owned by a `member` is refused server-side, on every path, and nothing is stored.
    let refused ← call memberMission "request_macbook_tether" requestArgs
    check (refused.fieldBool? "ok" == some false && errorCode refused == some "mac_tether_denied")
      "a member-owned mission cannot request a tether"
    check (errorCode (← call memberMission "list_macbook_tethers") == some "mac_tether_denied")
      "a member-owned mission cannot list tethers"
    check (!(← createMacTetherRequest store (some rt) 0 "member-mission" "label" "host" false requestArgs now).isOk)
      "the broker itself refuses a member-owned mission"
    check (!(← createMacTetherRequest store (some rt) 0 "no-such-mission" "label" "host" false requestArgs now).isOk)
      "the broker refuses an unknown mission"
    let (onBehalf, _) ← send "POST" "/api/mac-tether/requests" admin (requestArgs.setField "mission_id" (.str "member-mission"))
    check (onBehalf == 400) "an administrator cannot file a tether for a member-owned mission"
    check ((← sql "SELECT COUNT(*) FROM mac_tether_requests;")[1]? == some #["0"]) "refused requests leave no row"

    -- The owner's mission may ask; the request is pending and carries no lease token.
    let pending ← call adminMission "request_macbook_tether" requestArgs
    let pendingResult := pending.fieldOrNull "result"
    let some reqId := pendingResult.fieldStr? "request_id" | throw (IO.userError s!"mac tether: no request id: {renderCompact pending}")
    check (pending.fieldBool? "ok" == some true && pendingResult.fieldStr? "status" == some "pending" && !has pending "lease_token")
      "the owner's mission gets a pending request"
    check ((← call adminMission "request_macbook_tether" (requestArgs.setField "reason" (.str ""))).fieldBool? "ok" == some false)
      "a request needs a reason"

    -- The daemon routes need the admin bearer.
    let approvePath := s!"/api/mac-tether/requests/{reqId}/approve"
    for (method, target) in #[("GET", "/api/mac-tether/events?since_gen=0&wait_secs=0"), ("GET", "/api/mac-tether/requests"),
        ("POST", approvePath), ("POST", s!"/api/mac-tether/requests/{reqId}/deny"),
        ("POST", s!"/api/mac-tether/requests/{reqId}/revoke")] do
      check ((← send method target member).1 == 403) s!"member bearer is refused on {method} {target}"
      check ((← send method target adminMission).1 == 401) s!"a mission token is not a bearer for {method} {target}"
      check ((← send method target "not-a-token").1 == 401) s!"no bearer is refused on {method} {target}"

    -- What the laptop daemon reads from the long-poll.
    let (eventsStatus, events) ← send "GET" "/api/mac-tether/events?since_gen=0&wait_secs=25" admin
    let listed := ((events.fieldArr? "requests").getD #[])
    let row := listed[0]?.getD .null
    check (eventsStatus == 200 && (events.fieldNat? "generation").isSome && (events.fieldNat? "server_epoch").isSome &&
      events.fieldNat? "bunker_state" == some 0 && events.fieldStr? "relay_endpoint" == some "127.0.0.1:51890" && listed.size == 1)
      s!"events envelope: {renderCompact events}"
    check (row.fieldStr? "id" == some reqId && row.fieldStr? "state" == some "pending" &&
      row.fieldStr? "mission_id" == some "admin-mission" && row.fieldStr? "requester_label" == some "[tether] admin-mission title" &&
      row.fieldStr? "requested_scope" == some "sandbox_ssh" && row.fieldStr? "reason" == some "Run the preview build" &&
      (row.fieldStr? "host_id").isSome && row.fieldBool? "is_managed_vm" == some false &&
      (row.fieldArr? "agent_ports").map (·.filterMap JVal.asNat?) == some #[3000] &&
      (row.fieldArr? "mac_ports").map (·.size) == some 0 &&
      row.fieldNat? "ttl_minutes" == some 30 && row.fieldStr? "agent_kem_pubkey" == some agentKemPub &&
      row.fieldStr? "agent_wg_pubkey" == some agentWgPub && row.fieldStr? "agent_ssh_pubkey" == some agentSshPub &&
      row.field? "expires_at" == some .null && !has events "lease_token")
      s!"pending request as the daemon reads it: {renderCompact row}"
    let gen := (events.fieldNat? "generation").getD 0
    let (_, idle) ← send "GET" s!"/api/mac-tether/events?since_gen={gen}&wait_secs=0" admin
    check (idle.fieldNat? "generation" == some gen) "the generation only moves when a request changes"

    -- Approval needs the biometric assertion, then allocates an overlay address and a lease.
    let .ok sealed ← sealTetherPsk macKemPriv agentKemPub reqId pskB64 | throw (IO.userError "mac tether: seal")
    let approval : JVal := .obj #[
      ("biometric_verified", .bool true), ("effective_scope", .str "host_ssh"), ("effective_target", .str "thomas"),
      ("ttl_minutes", .nat 15), ("session_scoped", .bool true), ("mac_wg_pubkey", .str macWgPub),
      ("mac_kem_pubkey", .str macKemPub), ("sealed_psk_b64", .str sealed), ("mac_direct_endpoint", .str "192.168.1.165:51889")]
    check ((← send "POST" approvePath admin (approval.setField "biometric_verified" (.bool false))).1 == 403)
      "approval without the biometric assertion is refused"
    let (approveStatus, approved) ← send "POST" approvePath admin approval
    let tether := approved.fieldOrNull "tether"
    check (approveStatus == 200 && tether.fieldStr? "state" == some "approved" && tether.fieldStr? "overlay_ip" == some "10.88.200.10" &&
      tether.fieldNat? "expires_at" == some (now + 900).toNat && tether.fieldStr? "relay_endpoint" == some "127.0.0.1:51890" &&
      tether.fieldStr? "effective_scope" == some "host_ssh" && tether.fieldStr? "effective_target" == some "thomas" &&
      tether.fieldStr? "agent_direct_endpoint" == none && tether.fieldBool? "is_managed_vm" == some false &&
      tether.fieldStr? "agent_wg_pubkey" == some agentWgPub && tether.fieldStr? "agent_ssh_pubkey" == some agentSshPub &&
      (tether.fieldArr? "agent_ports").isSome && (tether.fieldArr? "mac_ports").isSome && !has approved "lease_token")
      s!"approval reply as the daemon reads it: {approveStatus} {renderCompact approved}"
    check ((← send "POST" approvePath admin approval).1 == 409) "a request is approved once"
    let (_, afterApprove) ← send "GET" s!"/api/mac-tether/events?since_gen={gen}&wait_secs=25" admin
    check ((afterApprove.fieldNat? "generation").getD 0 > gen) "approval wakes the long-poll"

    -- Only the owning mission receives the lease token and the sealed PSK; another mission sees nothing.
    let mine ← call adminMission "list_macbook_tethers"
    let myTether := (((mine.fieldOrNull "result").fieldArr? "tethers").getD #[])[0]?.getD .null
    let leaseToken := (myTether.fieldStr? "lease_token").getD ""
    check (leaseToken.startsWith "tether1." &&
      (← openTetherPsk agentKemPriv macKemPub reqId ((myTether.fieldStr? "sealed_psk_b64").getD "")).toOption == some pskB64)
      "the owning mission receives its lease and can open the PSK"
    check (!(← openTetherPsk agentKemPriv macKemPub "another-request" sealed).isOk) "the sealed PSK is bound to its request"
    let polled ← call adminMission "request_macbook_tether" (.obj #[("request_id", .str reqId), ("wait_secs", .nat 0)])
    check ((polled.fieldOrNull "result").fieldStr? "status" == some "approved" && has polled leaseToken) "polling returns the approved lease"
    check (!(← executeMacTetherMcpTool store (some rt) none 0 false "" "list_macbook_tethers" (.obj #[]) now).isOk)
      "an executor session without a mission is refused"
    let direct ← call admin "list_macbook_tethers"
    check (direct.fieldBool? "ok" == some true && has direct reqId) "the administrator acting directly lists every request"
    let theirs ← call otherMission "list_macbook_tethers"
    check (theirs.fieldBool? "ok" == some true && !has theirs reqId) "another mission does not list the request"
    for (tool, args) in #[("request_macbook_tether", JVal.obj #[("request_id", .str reqId), ("wait_secs", .nat 0)]),
        ("revoke_macbook_tether", JVal.obj #[("request_id", .str reqId)])] do
      let foreign ← call otherMission tool args
      check (foreign.fieldBool? "ok" == some false && !has foreign leaseToken) s!"another mission cannot use {tool} on the request"

    -- `orb-privd` verifies the lease; bunker mode and a wrong mission fail closed.
    let verifyBody (mission : String) : JVal :=
      .obj #[("request_id", .str reqId), ("lease_token", .str leaseToken), ("mission_id", .str mission)]
    let (verifyStatus, verified) ← send "POST" "/api/mac-tether/verify-lease" admin (verifyBody "admin-mission")
    check (verifyStatus == 200 && verified.fieldBool? "allowed" == some true && verified.fieldNat? "bunker_state" == some 0 &&
      (verified.fieldOrNull "tether").fieldStr? "overlay_ip" == some "10.88.200.10" && !has verified leaseToken) "a live lease verifies"
    check ((← send "POST" "/api/mac-tether/verify-lease" admin (verifyBody "admin-other")).1 == 403) "a lease is bound to its mission"
    -- `orb-privd` holds no admin bearer: the lease token and its mission are the proof.
    let (nodeStatus, nodeVerified) ← send "POST" "/api/mac-tether/verify-lease" "not-a-token" (verifyBody "admin-mission")
    check (nodeStatus == 200 && nodeVerified.fieldBool? "allowed" == some true) "a node without a bearer verifies a live lease"
    check ((← send "POST" "/api/mac-tether/verify-lease" "not-a-token" (verifyBody "")).1 == 403) "verify-lease needs the mission id"
    check ((← send "POST" "/api/mac-tether/verify-lease" "not-a-token"
      (.obj #[("request_id", .str reqId), ("lease_token", .str "tether1.00"), ("mission_id", .str "admin-mission")])).1 == 403)
      "a wrong lease token is refused without a bearer"
    check ((← send "POST" "/api/mac-tether/verify-lease" member (verifyBody "admin-other")).1 == 403) "a member cannot verify another mission's lease"
    bunkerRef.set 1
    let bunkered ← send "POST" "/api/mac-tether/verify-lease" admin (verifyBody "admin-mission")
    let bunkerRequest ← call adminMission "request_macbook_tether" requestArgs
    bunkerRef.set 0
    check (bunkered.1 == 403 && bunkerRequest.fieldBool? "ok" == some false) "bunker mode closes verification and new requests"

    -- Blind relay: forwards only between the two approved peers, and a spoofed initiation does not move a route.
    let slots ← rt.slotsMu.atomically get
    let epMac : UdpEndpoint := { ipHostOrder := 0xC633640A, port := 51889 }
    let epVm : UdpEndpoint := { ipHostOrder := 0xCB007114, port := 41900 }
    let epEvil : UdpEndpoint := { ipHostOrder := 0xC0000299, port := 6666 }
    let step (slotsNow : Array RelayPairSlot) (src : UdpEndpoint) (payload : ByteArray) (at_ : UInt64) : IO (Array UdpEndpoint) :=
      stepBlindRelayDatagram slotsNow rt.fwdMu { srcIpHostOrder := src.ipHostOrder, srcPort := src.port, payload := payload } at_
    let d1 ← step slots epMac (← wgInitPacket agentWgPub32 0x1001) now
    let d2 ← step slots epVm (← wgInitPacket macWgPub32 0x2002) now
    let d3 ← step slots epMac (← wgRespPacket agentWgPub32 0x1005 0x2002) now
    discard <| step slots epEvil (← wgInitPacket macWgPub32 0x9999) (now + 1)
    let toVm ← step slots epMac (wgDataPacket 0x2002) (now + 2)
    let toMac ← step slots epVm (wgDataPacket 0x1005) (now + 2)
    let stranger ← step slots epEvil (← wgInitPacket (ByteArray.mk (Array.replicate 32 7)) 0x7777) (now + 2)
    check (slots.size == 1 && d1.isEmpty && d2 == #[epMac] && d3 == #[epVm] && toVm == #[epVm] && toMac == #[epMac] && stranger.isEmpty)
      s!"relay routing: d1={repr d1} d2={repr d2} d3={repr d3} toVm={repr toVm} toMac={repr toMac} stranger={repr stranger}"

    -- Stopping the mission revokes its session-scoped lease and closes the relay at once.
    discard <| send "POST" "/api/control/missions/admin-mission/cancel" admin
    let afterStop ← rt.slotsMu.atomically get
    check (afterStop.isEmpty && (← step afterStop epMac (wgDataPacket 0x2002) (now + 3)).isEmpty) "stopping the mission closes the relay"
    check ((← send "POST" "/api/mac-tether/verify-lease" admin (verifyBody "admin-mission")).1 == 403) "a revoked lease no longer verifies"
    check ((← sql "SELECT state, lease_token FROM mac_tether_requests WHERE id=?1;" #[reqId])[1]? == some #["revoked", ""])
      "revocation erases the stored lease token"

    -- Deny and revoke as the daemon calls them.
    let second ← call adminMission "request_macbook_tether" requestArgs
    let some secondId := (second.fieldOrNull "result").fieldStr? "request_id" | throw (IO.userError "mac tether: second request")
    let (denyStatus, denied) ← send "POST" s!"/api/mac-tether/requests/{secondId}/deny" admin (.obj #[("reason", .str "Denied on MacBook")])
    check (denyStatus == 200 && denied.fieldBool? "ok" == some true && (denied.fieldOrNull "tether").fieldStr? "state" == some "denied" &&
      (denied.fieldOrNull "tether").fieldStr? "deny_reason" == some "Denied on MacBook") "deny"
    check ((← send "POST" s!"/api/mac-tether/requests/{secondId}/approve" admin approval).1 == 409) "a denied request cannot be approved"
    let third ← call adminMission "request_macbook_tether" requestArgs
    let some thirdId := (third.fieldOrNull "result").fieldStr? "request_id" | throw (IO.userError "mac tether: third request")
    let (revokeStatus, revoked) ← send "POST" s!"/api/mac-tether/requests/{thirdId}/revoke" admin (.obj #[("reason", .str "Revoked from MacBook")])
    check (revokeStatus == 200 && (revoked.fieldOrNull "tether").fieldStr? "state" == some "revoked" &&
      ((revoked.fieldOrNull "tether").fieldNat? "revoked_at").isSome) "revoke"
    let (listStatus, all) ← send "GET" "/api/mac-tether/requests" admin
    check (listStatus == 200 && ((all.fieldArr? "requests").getD #[]).size == 3 && !has all "tether1.") "the daemon's list has every request and no token"
    check ((← send "POST" "/api/mac-tether/requests/00000000-0000-4000-8000-000000000000/approve" admin approval).1 == 404)
      "an unknown request is not found"
  finally
    stopMacTetherRuntime rt
    closeCoreStore store

end OrbCore.MacTetherTests
