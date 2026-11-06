/-
  OrbCore.Search: Pure-Lean Conversation & Workspace Substring/Trigram Search Engine
  (`0 import Lean`, `0 sorryAx`) backed by `LeanSys.Search` & `LeanSys.Store`.
-/
import LeanSys

namespace OrbCore.Search

open LeanSys.Posix
open LeanSys.Store
open LeanSys.Lsm
open LeanSys.Search

/-- Indexed conversation document handle backed by `LeanSys.Store` + `SstTable` trigram index. -/
structure SearchIndex where
  dir   : String
  store : Handle

def openSearchIndex (dir : String) : IO (Except String SearchIndex) := do
  IO.FS.createDirAll dir
  match ← openStore dir with
  | .error e => return .error s!"search_store_open_failed:{repr e}"
  | .ok h => return .ok { dir := dir, store := h }

def indexConversation (idx : SearchIndex) (missionId text : String) : IO (Except String SearchIndex) := do
  match ← indexDoc idx.store missionId text false with
  | .error e => return .error s!"search_index_doc_failed:{repr e}"
  | .ok h' => return .ok { idx with store := h' }

def queryConversations (idx : SearchIndex) (needle : String) (maxResults : Nat := 32) : IO (Array String) := do
  if needle.length < 3 then
    let hits := searchStoreSubstring idx.store needle maxResults
    return hits.map (·.1)
  let sstPath := s!"{idx.dir}/trigrams.sst"
  match ← SstTable.flushFromStore idx.store sstPath with
  | Except.error _ =>
    return (searchStoreSubstring idx.store needle maxResults).map (·.1)
  | Except.ok sst =>
    return (searchTrigramSst sst needle maxResults).map (·.1)

end OrbCore.Search
