namespace OrbNode.Posix

@[extern "orb_node_install_signals"]
opaque installSignals : IO Unit

@[extern "orb_node_poll_signals"]
opaque pollSignals : IO UInt32

@[extern "orb_node_geteuid"]
opaque geteuid : IO UInt32

@[extern "orb_node_now_epoch"]
opaque nowEpoch : IO UInt64

@[extern "orb_node_host_stats"]
opaque hostStatsRaw (workDir : @& String) : IO ByteArray

@[extern "orb_node_tcp_listen"]
opaque tcpListen (host : @& String) (port : UInt16) : IO UInt32

@[extern "orb_node_tcp_accept"]
opaque tcpAccept (listenFd : UInt32) (timeoutMs : UInt32) : IO UInt32

@[extern "orb_node_fd_read"]
opaque fdRead (fd : UInt32) (maxBytes : USize) : IO ByteArray

@[extern "orb_node_fd_write_all"]
opaque fdWriteAll (fd : UInt32) (bytes : @& ByteArray) : IO UInt32

@[extern "orb_node_fd_close"]
opaque fdClose (fd : UInt32) : IO Unit

@[extern "orb_node_spawn_job_pgrp"]
opaque spawnJobPgrp
    (prog : @& String) (args : @& Array String) (envKv : @& Array String)
    (cwd : @& String) (logPath : @& String) : IO UInt64

@[extern "orb_node_poll_pid"]
opaque pollPid (pid : UInt64) : IO UInt64

@[extern "orb_node_kill_pgrp"]
opaque killPgrp (pid : UInt64) (sig : UInt32) : IO Unit

structure HostStats where
  cpuTotal       : UInt32
  memTotalBytes  : UInt64
  memAvailBytes  : UInt64
  diskTotalBytes : UInt64
  diskAvailBytes : UInt64
  deriving Repr, Inhabited

private def readU32LE (b : ByteArray) (off : Nat) : UInt32 :=
  if off + 4 ≤ b.size then
    (b.get! off).toUInt32 |||
    ((b.get! (off + 1)).toUInt32 <<< 8) |||
    ((b.get! (off + 2)).toUInt32 <<< 16) |||
    ((b.get! (off + 3)).toUInt32 <<< 24)
  else 0

private def readU64LE (b : ByteArray) (off : Nat) : UInt64 :=
  if off + 8 ≤ b.size then
    (readU32LE b off).toUInt64 ||| ((readU32LE b (off + 4)).toUInt64 <<< 32)
  else 0

def hostStats (workDir : String) : IO HostStats := do
  let raw ← hostStatsRaw workDir
  return {
    cpuTotal := max 1 (readU32LE raw 0)
    memTotalBytes := readU64LE raw 8
    memAvailBytes := readU64LE raw 16
    diskTotalBytes := readU64LE raw 24
    diskAvailBytes := readU64LE raw 32
  }

end OrbNode.Posix
