/-
  OrbNode.MutantSuite: 3-Mutant Kill Matrix (`0 import Lean`, `0 sorryAx`)
  proving every Wave 2 `OrbNode.Spec` gate strictly distinguishes semantic security faults.
-/
import OrbNode.Spec

namespace OrbNode.MutantSuite

open OrbNode.Spec

/-- Mutant 1: Accepts `prevMatches == 1` even when `hasPrevConfigured == 0`
    (empty previous token rotation bug). -/
def m1_node_acceptUnconfiguredPrev
    (hasBearerPrefix : UInt8)
    (curMatches : UInt8)
    (hasPrevConfigured : UInt8)
    (prevMatches : UInt8)
    (candidateLen : UInt32) : UInt8 :=
  if hasBearerPrefix == 1 &&
     1 ≤ candidateLen && candidateLen ≤ 4096 &&
     (curMatches == 1 || (hasPrevConfigured ≤ 1 && prevMatches == 1)) then 1 else 0

/-- Mutant 2: Allows `job:force` (`scopeCode == 3`) without requiring `jobIdMatches == 1`
    (cross-job force-bypass privilege escalation bug). -/
def m2_node_forceWithoutJobMatch
    (hmacValid : UInt8)
    (nodeMatches : UInt8)
    (scopeCode : UInt8)
    (expectedScope : UInt8)
    (jobIdMatches : UInt8)
    (nowSecs : UInt64)
    (expiresAt : UInt64) : UInt8 :=
  if hmacValid == 1 &&
     nodeMatches == 1 &&
     1 ≤ scopeCode && scopeCode ≤ 4 &&
     scopeCode == expectedScope &&
     nowSecs < expiresAt &&
     (scopeCode != 3 || jobIdMatches ≤ 1) then 1 else 0

/-- Mutant 3: Admits unforced non-resize job submissions even when `freeBytes < floorBytes`
    (disk-pressure pin bypass bug). -/
def m3_node_ignoreDiskFloor
    (capacity : UInt32)
    (coordCapacity : UInt32)
    (freeBytes : UInt64)
    (floorBytes : UInt64)
    (isResize : UInt8)
    (isForced : UInt8) : UInt8 :=
  if 1 ≤ capacity && capacity ≤ 256 &&
     1 ≤ coordCapacity && coordCapacity ≤ 16 &&
     (isResize ≤ 1 || isForced == 1 || floorBytes ≤ freeBytes) then 1 else 0

theorem kill_m1_node_acceptUnconfiguredPrev :
    m1_node_acceptUnconfiguredPrev 1 0 0 1 64 ≠
      verifyNodeBearerAuth 1 0 0 1 64 := by
  decide

theorem kill_m2_node_forceWithoutJobMatch :
    m2_node_forceWithoutJobMatch 1 1 3 3 0 1000 1600 ≠
      verifyNodeLeaseClaims 1 1 3 3 0 1000 1600 := by
  decide

theorem kill_m3_node_ignoreDiskFloor :
    m3_node_ignoreDiskFloor 8 2 5000000000 10000000000 0 0 ≠
      verifyNodeCapacityDisk 8 2 5000000000 10000000000 0 0 := by
  decide

end OrbNode.MutantSuite
