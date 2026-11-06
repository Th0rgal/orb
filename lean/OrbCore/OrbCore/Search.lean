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

/-- Indexed conversation document handle backed by `LeanSys.Store` + cached `SstTable` trigram index,
    serialized across concurrent `IO.asTask` HTTP handlers via `mu : Std.Mutex Unit`. -/
structure SearchIndex where
  dir      : String
  mu       : Std.Mutex Unit
  storeRef : IO.Ref Handle
  sstRef   : IO.Ref (Option SstTable)

def openSearchIndex (dir : String) : IO (Except String SearchIndex) := do
  IO.FS.createDirAll dir
  match ← openStore dir with
  | .error e => return .error s!"search_store_open_failed:{repr e}"
  | .ok h =>
    let mu ← Std.Mutex.new ()
    let storeRef ← IO.mkRef h
    let sstPath := s!"{dir}/trigrams.sst"
    let sst0? ← match ← SstTable.openSst sstPath with
      | .ok t => pure (some t)
      | .error _ => pure none
    let sstRef ← IO.mkRef sst0?
    return .ok { dir := dir, mu := mu, storeRef := storeRef, sstRef := sstRef }

/-- Index `text` for `missionId` and flush the updated trigram SST on write (never on `GET` queries). -/
def indexConversation (idx : SearchIndex) (missionId text : String) : IO (Except String SearchIndex) :=
  idx.mu.atomically do
    let cur ← idx.storeRef.get
    match ← indexDoc cur missionId text false with
    | .error e => return .error s!"search_index_doc_failed:{repr e}"
    | .ok h' =>
      idx.storeRef.set h'
      let sstPath := s!"{idx.dir}/trigrams.sst"
      match ← SstTable.flushFromStore h' sstPath with
      | .ok sst => idx.sstRef.set (some sst)
      | .error _ => pure ()
      return .ok idx

/-- Query indexed conversations without performing disk writes on `GET`. -/
def queryConversations (idx : SearchIndex) (needle : String) (maxResults : Nat := 32) : IO (Array String) :=
  idx.mu.atomically do
    let h ← idx.storeRef.get
    if needle.length < 3 then
      return (searchStoreSubstring h needle maxResults).map (·.1)
    match ← idx.sstRef.get with
    | some sst =>
      return (searchTrigramSst sst needle maxResults).map (·.1)
    | none =>
      return (searchStoreSubstring h needle maxResults).map (·.1)

end OrbCore.Search
