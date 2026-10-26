#ifndef LEAN_MESH_KERNEL_H
#define LEAN_MESH_KERNEL_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
uint32_t leanmesh_ratchet_epoch_step(uint8_t sigValid, uint8_t isEmergencyPanic, uint64_t currentEpoch, uint64_t candidateEpoch, uint64_t currentPanicSeq, uint64_t candidatePanicSeq, uint64_t nowEpoch, uint64_t issuedAt, uint64_t expiresAt, uint64_t maxTtlSecs);
uint32_t leanmesh_eval_route_step(uint32_t srcId, uint32_t dstId, uint8_t srcClass, uint8_t dstClass, uint8_t srcRevoked, uint8_t dstRevoked, uint8_t ruleMatched, uint8_t proto, uint32_t dstPort, uint32_t rulePortMin, uint32_t rulePortMax, uint8_t jitBiometricGrant, uint8_t bunkerState, uint64_t nowEpoch, uint64_t srcExpiresAt, uint64_t dstExpiresAt, uint64_t jitExpiresAt);
uint8_t leanmesh_replay_window_step(uint64_t lastMaxSeq, uint64_t bitmap, uint64_t pktSeq);
uint64_t leanmesh_replay_window_next_max(uint64_t lastMaxSeq, uint64_t bitmap, uint64_t pktSeq);
uint64_t leanmesh_replay_window_next_bitmap(uint64_t lastMaxSeq, uint64_t bitmap, uint64_t pktSeq);
uint8_t leanmesh_endpoint_roam_step(uint8_t aeadAuthOk, uint8_t peerPinnedStatic, uint8_t candidateIpClass, uint8_t allowPrivateRoam, uint8_t bunkerState, uint32_t candidatePort, uint64_t lastRoamSeq, uint64_t pktSeq, uint64_t lastRoamEpoch, uint64_t nowEpoch, uint64_t minRoamIntervalSecs);
uint8_t leanmesh_relay_select_step(uint8_t routeAllowed, uint8_t lanReachable, uint8_t wanReachable, uint8_t relayHealthy, uint32_t srcId, uint32_t dstId, uint32_t relayId, uint32_t activeRelaySessions, uint32_t maxRelaySessions, uint64_t nowEpoch, uint64_t directHandshakeAt, uint64_t maxDirectStaleSecs);
uint32_t leanmesh_bunker_isolate_step(uint8_t currentState, uint8_t isSovereignNode, uint8_t canaryTripped, uint8_t authFailureBurst, uint8_t manualTrigger, uint8_t biometricUnbunker, uint8_t heartbeatValid, uint64_t nowEpoch, uint64_t lastHeartbeatAt, uint64_t deadManTimeoutSecs);
uint8_t leanmesh_frame_bounds_step(uint32_t magic, uint8_t version, uint8_t frameKind, uint8_t tagVerified, uint64_t headerLen, uint64_t payloadLen, uint64_t maxFrameBytes, uint64_t bufCap);
uint8_t leanmesh_overlay_ip_step(uint32_t peerIdA, uint32_t peerIdB, uint32_t ipA, uint32_t ipB, uint8_t prefixLenA, uint8_t prefixLenB);
uint8_t leanmesh_reconcile_wg_step(uint8_t manifestValid, uint8_t peerPresentInKernel, uint8_t peerRevoked, uint8_t pubkeyMatches, uint8_t allowedIpMatches, uint8_t endpointChanged, uint8_t bunkerPruneNonAdmin, uint8_t peerIsAdmin, uint64_t nowEpoch, uint64_t peerExpiresAt);
uint32_t leanmesh_jit_lease_step(uint8_t biometricSigValid, uint8_t operatorSameOwner, uint8_t missionActive, uint8_t grantRevoked, uint8_t bunkerState, uint8_t srcClass, uint8_t dstClass, uint64_t nowEpoch, uint64_t grantIssuedAt, uint64_t grantExpiresAt, uint64_t maxJitTtlSecs);
#ifdef __cplusplus
}
#endif
#endif
