/-
  OrbNetLeaf.Pty: Verified CLOEXEC pseudo-terminal allocation and window resize
  over `orb_net_leaf.c` + `LeanSys.Posix`, strictly gated by `verifyPtyWindow`.
-/
import LeanSys.Posix
import OrbNetLeaf.Spec

namespace OrbNetLeaf.Pty

open LeanSys.Posix
open OrbNetLeaf.Spec

@[extern "orb_net_leaf_openpty"]
private opaque rawOpenPty (rows cols : UInt16) : IO UInt64

@[extern "orb_net_leaf_pty_resize"]
private opaque rawPtyResize (mfd : UInt32) (rows cols : UInt16) : IO UInt64

structure PtyPair where
  masterFd : Fd
  slaveFd  : Fd
  deriving Repr, DecidableEq

/-- Allocate a `FD_CLOEXEC` PTY pair with validated `(rows, cols)` geometry (`1 ≤ rows, cols ≤ 1024`). -/
def openPty (rows : UInt16 := 24) (cols : UInt16 := 80) : IO (SysResult PtyPair) := do
  if verifyPtyWindow rows.toUInt32 cols.toUInt32 != 1 then
    return .error .einval
  let packed ← rawOpenPty rows cols
  match decodePackedWord packed with
  | .error e => return .error e
  | .ok v =>
    let mfd : UInt32 := v.toUInt32
    let sfd : UInt32 := (v >>> 32).toUInt32
    return .ok { masterFd := ⟨mfd⟩, slaveFd := ⟨sfd⟩ }

/-- Resize an open PTY master descriptor (`TIOCSWINSZ`) with `verifyPtyWindow` validation. -/
def resizePty (masterFd : Fd) (rows cols : UInt16) : IO (SysResult Unit) := do
  if verifyPtyWindow rows.toUInt32 cols.toUInt32 != 1 then
    return .error .einval
  let packed ← rawPtyResize masterFd.raw rows cols
  match decodePackedWord packed with
  | .error e => return .error e
  | .ok _ => return .ok ()

/-- Close both master and slave descriptors of a `PtyPair`. -/
def closePtyPair (pair : PtyPair) : IO Unit := do
  discard <| closeFd pair.slaveFd
  discard <| closeFd pair.masterFd

end OrbNetLeaf.Pty
