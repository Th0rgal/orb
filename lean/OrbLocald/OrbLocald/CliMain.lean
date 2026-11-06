import LeanSys
import OrbBin.Json
import OrbLocald.Rpc

/-
  OrbLocald.CliMain — `orb-locald` loopback RPC & transport bridge daemon.
-/

open LeanSys.Posix
open OrbBin.Json
open OrbLocald.Rpc

private def handleOneRpcClient (stRef : IO.Ref LocaldState) (clientFd : Fd) : IO Unit := do
  match ← pollReadable clientFd 5000 with
  | .error _ => pure ()
  | .ok () =>
    let raw ← readStreamChunk clientFd 65536
    if raw.size > 0 then
      let reqText := String.fromUTF8? raw |>.getD ""
      let headerEnd := (reqText.splitOn "\r\n\r\n")
      let head := headerEnd.head?.getD ""
      let body := String.intercalate "\r\n\r\n" (headerEnd.drop 1)
      let firstLine := (head.splitOn "\r\n").head?.getD ""
      if firstLine.startsWith "OPTIONS " then
        let resp :=
          "HTTP/1.1 204 No Content\r\n" ++
          "Access-Control-Allow-Origin: *\r\n" ++
          "Access-Control-Allow-Methods: GET, POST, PUT, PATCH, DELETE, OPTIONS\r\n" ++
          "Access-Control-Allow-Headers: *\r\n" ++
          "Access-Control-Max-Age: 86400\r\n" ++
          "Content-Length: 0\r\n\r\n"
        discard <| writeAll clientFd resp.toUTF8 false
      else
        let st ← stRef.get
        let tokenLine := (head.splitOn "\r\n").find? fun l =>
          l.toLower.startsWith "x-orb-token:"
        let provided := match tokenLine with
          | some l => ((l.drop 12).trimAscii).toString
          | none => ""
        if !checkRpcAuth "127.0.0.1" provided st.launchToken then
          let errJson := "{\"error\":\"unauthorized\"}"
          let resp :=
            s!"HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nContent-Length: {errJson.toUTF8.size}\r\n\r\n{errJson}"
          discard <| writeAll clientFd resp.toUTF8 false
        else
          match OrbBin.Json.parse body with
          | .error e =>
            let errJson := renderCompact (.obj #[("error", .str e)])
            let resp :=
              s!"HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: {errJson.toUTF8.size}\r\n\r\n{errJson}"
            discard <| writeAll clientFd resp.toUTF8 false
          | .ok jv =>
            let cmd := (jv.fieldStr? "command").getD ""
            let cargs := (jv.field? "args").getD (.obj #[])
            let out ← dispatchRpcCommand stRef cmd cargs
            let (statusLine, payload) := match out with
              | .ok res => ("200 OK", renderCompact (.obj #[("result", res)]))
              | .error msg => ("400 Bad Request", renderCompact (.obj #[("error", .str msg)]))
            let resp :=
              s!"HTTP/1.1 {statusLine}\r\n" ++
              "Access-Control-Allow-Origin: *\r\n" ++
              "Content-Type: application/json\r\n" ++
              s!"Content-Length: {payload.toUTF8.size}\r\n\r\n{payload}"
            discard <| writeAll clientFd resp.toUTF8 false
  discard <| closeFd clientFd

partial def acceptLoop (stRef : IO.Ref LocaldState) (listenFd : Fd) : IO UInt32 := do
  match ← tcpAcceptPoll listenFd 500 with
  | .ok cfd => handleOneRpcClient stRef cfd
  | .error _ => pure ()
  acceptLoop stRef listenFd

def main (args : List String) : IO UInt32 := do
  if args.contains "--version" then
    IO.println "orb-locald 0.13.0 (Lean 4)"
    return 0
  if args.contains "--print-init-script" then
    IO.print (renderWebviewInitScript 19479 "dev-token")
    return 0
  let portStr := (← IO.getEnv "ORB_LOCALD_PORT").getD "19479"
  let port : UInt16 := UInt16.ofNat (portStr.toNat?.getD 19479)
  let tok := (← IO.getEnv "ORB_LOCALD_TOKEN").getD "orb-locald-default-token"
  let stRef ← IO.mkRef ({ launchToken := tok } : LocaldState)
  match ← tcpListen "127.0.0.1" port 64 with
  | .error _ =>
    IO.eprintln s!"orb-locald: failed to bind 127.0.0.1:{port}"
    return 1
  | .ok (listenFd, _) =>
    acceptLoop stRef listenFd
