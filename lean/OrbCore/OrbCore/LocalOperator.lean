import OrbBin.PosixExt

namespace OrbCore.LocalOperator

def isMission : IO Bool := do
  for name in #["SANDBOXED_MISSION_ID", "SANDBOXED_SH_MISSION_ID", "SANDBOXED_JOB_ID"] do
    if ((← IO.getEnv name).getD "").trimAscii.toString != "" then return true
  return false

def ownsRoot (root : String) : IO Bool := do
  let st ← OrbBin.PosixExt.statPath root
  return st.exists_ && st.isDir && !st.isSymlink && st.ownedByEuid && (st.mode &&& 0o022) == 0

def authorize (root : String) : IO (Except String Unit) := do
  if (← isMission) || !(← ownsRoot root) then return .error "operator_required"
  return .ok ()

end OrbCore.LocalOperator
