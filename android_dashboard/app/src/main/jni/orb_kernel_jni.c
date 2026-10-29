#include <jni.h>
#include <stdint.h>
#include "../../../shared/orb-spec/cabi/orb_kernel.h"

static uint8_t sat_u8(jint v) {
    return v < 0 ? 0 : (v > 255 ? 255 : (uint8_t)v);
}

JNIEXPORT jlong JNICALL
Java_sh_sandboxed_dashboard_orb_OrbKernel_orbWorkfoldStep(JNIEnv *env, jclass clazz, jint itemKind, jint isCumulative, jint isNonEmpty, jint toolAhead, jint nextIsTool, jint foldHasTool) {
    return (jlong)orb_workfold_step((uint8_t)itemKind, (uint8_t)isCumulative, (uint8_t)isNonEmpty, (uint8_t)toolAhead, (uint8_t)nextIsTool, (uint8_t)foldHasTool);
}

JNIEXPORT jlong JNICALL
Java_sh_sandboxed_dashboard_orb_OrbKernel_orbTaskcardStep(JNIEnv *env, jclass clazz, jint turnEnded, jint allClosed, jint turnOutcomeFinished) {
    return (jlong)orb_taskcard_step((uint8_t)turnEnded, (uint8_t)allClosed, (uint8_t)turnOutcomeFinished);
}

JNIEXPORT jlong JNICALL
Java_sh_sandboxed_dashboard_orb_OrbKernel_orbTurnSummaryStep(JNIEnv *env, jclass clazz, jint rawStatus, jint turnEnded, jint allClosed, jint turnOutcomeFinished) {
    return (jlong)orb_turn_summary_step((uint8_t)rawStatus, (uint8_t)turnEnded, (uint8_t)allClosed, (uint8_t)turnOutcomeFinished);
}

JNIEXPORT jlong JNICALL
Java_sh_sandboxed_dashboard_orb_OrbKernel_orbUsageLimitStatus(JNIEnv *env, jclass clazz, jint statusKind, jint claimKind, jint hasUtilization, jint utilizationPct, jint hasReset, jlong resetRemSecs) {
    return (jlong)orb_usage_limit_status((uint8_t)statusKind, (uint8_t)claimKind, (uint8_t)hasUtilization, sat_u8(utilizationPct), (uint8_t)hasReset, (uint64_t)resetRemSecs);
}

JNIEXPORT jlong JNICALL
Java_sh_sandboxed_dashboard_orb_OrbKernel_orbRelativeTimeBucket(JNIEnv *env, jclass clazz, jlong elapsedSecs) {
    return (jlong)orb_relative_time_bucket((uint64_t)elapsedSecs);
}

JNIEXPORT jlong JNICALL
Java_sh_sandboxed_dashboard_orb_OrbKernel_orbTranscriptPatchStep(JNIEnv *env, jclass clazz, jint stateLen, jint stateSeq, jint eventKind, jint deltaLen) {
    return (jlong)orb_transcript_patch_step((uint32_t)stateLen, (uint32_t)stateSeq, (uint8_t)eventKind, (uint32_t)deltaLen);
}

JNIEXPORT jlong JNICALL
Java_sh_sandboxed_dashboard_orb_OrbKernel_orbScrollMaxTop(JNIEnv *env, jclass clazz, jlong content, jlong viewport) {
    return (jlong)orb_scroll_max_top((uint64_t)content, (uint64_t)viewport);
}

JNIEXPORT jlong JNICALL
Java_sh_sandboxed_dashboard_orb_OrbKernel_orbScrollClampTop(JNIEnv *env, jclass clazz, jlong content, jlong viewport, jlong top) {
    return (jlong)orb_scroll_clamp_top((uint64_t)content, (uint64_t)viewport, (uint64_t)top);
}

JNIEXPORT jlong JNICALL
Java_sh_sandboxed_dashboard_orb_OrbKernel_orbScrollGap(JNIEnv *env, jclass clazz, jlong content, jlong viewport, jlong top) {
    return (jlong)orb_scroll_gap((uint64_t)content, (uint64_t)viewport, (uint64_t)top);
}

JNIEXPORT jlong JNICALL
Java_sh_sandboxed_dashboard_orb_OrbKernel_orbScrollLayoutStep(JNIEnv *env, jclass clazz, jint pinned, jlong content, jlong viewport, jlong top) {
    return (jlong)orb_scroll_layout_step((uint8_t)pinned, (uint64_t)content, (uint64_t)viewport, (uint64_t)top);
}

JNIEXPORT jint JNICALL
Java_sh_sandboxed_dashboard_orb_OrbKernel_orbScrollUserStep(JNIEnv *env, jclass clazz, jlong content, jlong viewport, jlong top, jlong threshold) {
    return (jint)orb_scroll_user_step((uint64_t)content, (uint64_t)viewport, (uint64_t)top, (uint64_t)threshold);
}

JNIEXPORT jlong JNICALL
Java_sh_sandboxed_dashboard_orb_OrbKernel_orbScrollJumpStep(JNIEnv *env, jclass clazz, jlong content, jlong viewport) {
    return (jlong)orb_scroll_jump_step((uint64_t)content, (uint64_t)viewport);
}

JNIEXPORT jlong JNICALL
Java_sh_sandboxed_dashboard_orb_OrbKernel_orbScrollCorrect(JNIEnv *env, jclass clazz, jint pinned, jlong content, jlong viewport, jlong top) {
    return (jlong)orb_scroll_correct((uint8_t)pinned, (uint64_t)content, (uint64_t)viewport, (uint64_t)top);
}

JNIEXPORT jint JNICALL
Java_sh_sandboxed_dashboard_orb_OrbKernel_orbScrollShowsJump(JNIEnv *env, jclass clazz, jint pinned, jlong content, jlong viewport, jlong top, jlong pillThreshold) {
    return (jint)orb_scroll_shows_jump((uint8_t)pinned, (uint64_t)content, (uint64_t)viewport, (uint64_t)top, (uint64_t)pillThreshold);
}

JNIEXPORT jlong JNICALL
Java_sh_sandboxed_dashboard_orb_OrbKernel_orbStreamCoalescerStep(JNIEnv *env, jclass clazz, jint op, jint shownLen, jint pendingLen, jint deltaLen) {
    return (jlong)orb_stream_coalescer_step((uint8_t)op, (uint32_t)shownLen, (uint32_t)pendingLen, (uint32_t)deltaLen);
}

JNIEXPORT jlong JNICALL
Java_sh_sandboxed_dashboard_orb_OrbKernel_orbStreamFenceStep(JNIEnv *env, jclass clazz, jint openKind, jint openCount, jint markerKind, jint markerCount) {
    return (jlong)orb_stream_fence_step((uint8_t)openKind, (uint32_t)openCount, (uint8_t)markerKind, (uint32_t)markerCount);
}

JNIEXPORT jlong JNICALL
Java_sh_sandboxed_dashboard_orb_OrbKernel_orbStreamCommitStep(JNIEnv *env, jclass clazz, jint tick, jint openKind, jint openCount, jint lineBlank, jint lineTick, jint markerKind, jint markerCount, jint pos, jint commit) {
    return (jlong)orb_stream_commit_step((uint8_t)tick, (uint8_t)openKind, (uint32_t)openCount, (uint8_t)lineBlank, (uint8_t)lineTick, (uint8_t)markerKind, (uint32_t)markerCount, (uint32_t)pos, (uint32_t)commit);
}

JNIEXPORT jlong JNICALL
Java_sh_sandboxed_dashboard_orb_OrbKernel_orbStreamTokenCostStep(JNIEnv *env, jclass clazz, jlong prevCost, jlong newAdvance, jlong tailBytes) {
    return (jlong)orb_stream_token_cost_step((uint64_t)prevCost, (uint64_t)newAdvance, (uint64_t)tailBytes);
}

JNIEXPORT jint JNICALL
Java_sh_sandboxed_dashboard_orb_OrbKernel_orbMissionStateClassify(JNIEnv *env, jclass clazz, jint stateId) {
    return (jint)orb_mission_state_classify((uint8_t)stateId);
}

JNIEXPORT jint JNICALL
Java_sh_sandboxed_dashboard_orb_OrbKernel_orbMissionSortRank(JNIEnv *env, jclass clazz, jint stateId) {
    return (jint)orb_mission_sort_rank((uint8_t)stateId);
}

JNIEXPORT jint JNICALL
Java_sh_sandboxed_dashboard_orb_OrbKernel_orbMissionFlags(JNIEnv *env, jclass clazz, jint stateId) {
    return (jint)orb_mission_flags((uint8_t)stateId);
}

JNIEXPORT jint JNICALL
Java_sh_sandboxed_dashboard_orb_OrbKernel_orbMissionInboxSection(JNIEnv *env, jclass clazz, jint stateId) {
    return (jint)orb_mission_inbox_section((uint8_t)stateId);
}

JNIEXPORT jint JNICALL
Java_sh_sandboxed_dashboard_orb_OrbKernel_orbConnectionIssueClassify(JNIEnv *env, jclass clazz, jint isUnreachable, jint isUsingDefault, jint isPrivateAddr, jint defaultReachable, jint hasExternalProxy) {
    return (jint)orb_connection_issue_classify((uint8_t)isUnreachable, (uint8_t)isUsingDefault, (uint8_t)isPrivateAddr, (uint8_t)defaultReachable, (uint8_t)hasExternalProxy);
}

JNIEXPORT jlong JNICALL
Java_sh_sandboxed_dashboard_orb_OrbKernel_orbWorkedDurationBucket(JNIEnv *env, jclass clazz, jlong seconds) {
    return (jlong)orb_worked_duration_bucket((uint64_t)seconds);
}

JNIEXPORT jint JNICALL
Java_sh_sandboxed_dashboard_orb_OrbKernel_orbTurnOutcomeStep(JNIEnv *env, jclass clazz, jint prevOutcome, jint prevFailed, jint eventKind, jint isNarration, jint isSuccessFalse, jint isTextNonEmpty) {
    return (jint)orb_turn_outcome_step((uint8_t)prevOutcome, (uint8_t)prevFailed, (uint8_t)eventKind, (uint8_t)isNarration, (uint8_t)isSuccessFalse, (uint8_t)isTextNonEmpty);
}

JNIEXPORT jint JNICALL
Java_sh_sandboxed_dashboard_orb_OrbKernel_orbNumericCellScan(JNIEnv *env, jclass clazz, jint nonEmpty, jint hasLeadingDigitOrSign, jint hasDigit, jint allAllowedChars) {
    return (jint)orb_numeric_cell_scan((uint8_t)nonEmpty, (uint8_t)hasLeadingDigitOrSign, (uint8_t)hasDigit, (uint8_t)allAllowedChars);
}

JNIEXPORT jlong JNICALL
Java_sh_sandboxed_dashboard_orb_OrbKernel_orbFileRefLineSpan(JNIEnv *env, jclass clazz, jint startLine, jint endLine, jint totalLines) {
    return (jlong)orb_file_ref_line_span((uint32_t)startLine, (uint32_t)endLine, (uint32_t)totalLines);
}

JNIEXPORT jint JNICALL
Java_sh_sandboxed_dashboard_orb_OrbKernel_orbMachineActionAdmitted(JNIEnv *env, jclass clazz, jint stateKind, jint isBusy, jint isMuted) {
    return (jint)orb_machine_action_admitted((uint8_t)stateKind, (uint8_t)isBusy, (uint8_t)isMuted);
}

JNIEXPORT jint JNICALL
Java_sh_sandboxed_dashboard_orb_OrbKernel_orbSendFlowStep(JNIEnv *env, jclass clazz, jint isBusy, jint hasNonEmptyText, jint canQueue, jint awaitingAck, jint isDraining, jint pendingCount, jint httpStatus) {
    return (jint)orb_send_flow_step((uint8_t)isBusy, (uint8_t)hasNonEmptyText, (uint8_t)canQueue, (uint8_t)awaitingAck, (uint8_t)isDraining, (uint8_t)pendingCount, (uint32_t)httpStatus);
}

JNIEXPORT jint JNICALL
Java_sh_sandboxed_dashboard_orb_OrbKernel_orbWireValidateFrame(JNIEnv *env, jclass clazz, jint magic, jint abiVersion, jint schemaId, jint expectedSchemaId, jint totalLen, jint payloadLen, jint arenaOff, jint arenaLen, jint maxBudgetBytes, jint outCap, jint requiredOutBytes) {
    return (jint)orb_wire_validate_frame((uint32_t)magic, (uint32_t)abiVersion, (uint32_t)schemaId, (uint32_t)expectedSchemaId, (uint32_t)totalLen, (uint32_t)payloadLen, (uint32_t)arenaOff, (uint32_t)arenaLen, (uint32_t)maxBudgetBytes, (uint32_t)outCap, (uint32_t)requiredOutBytes);
}

JNIEXPORT jlong JNICALL
Java_sh_sandboxed_dashboard_orb_OrbKernel_orbWirePackRecord(JNIEnv *env, jclass clazz, jint tag, jint flags, jint len16, jint payload32) {
    return (jlong)orb_wire_pack_record((uint8_t)tag, (uint8_t)flags, (uint32_t)len16, (uint32_t)payload32);
}

JNIEXPORT jint JNICALL
Java_sh_sandboxed_dashboard_orb_OrbKernel_orbWireSchemaMigrateStep(JNIEnv *env, jclass clazz, jint fromSchema, jint toSchema, jint currentSchema, jlong payloadBytes, jlong maxBytes) {
    return (jint)orb_wire_schema_migrate_step((uint32_t)fromSchema, (uint32_t)toSchema, (uint32_t)currentSchema, (uint64_t)payloadBytes, (uint64_t)maxBytes);
}

JNIEXPORT jint JNICALL
Java_sh_sandboxed_dashboard_orb_OrbKernel_orbEffectAdmissible(JNIEnv *env, jclass clazz, jint effectKind, jint hasValidLease, jint sessionCreated, jint lineageVerified, jint isArchived, jint idempotencyFresh, jint accountBound, jint accountRejected, jint firstByteLocked, jint grammarAllowed, jint envScrubbed, jint budgetOk) {
    return (jint)orb_effect_admissible((uint8_t)effectKind, (uint8_t)hasValidLease, (uint8_t)sessionCreated, (uint8_t)lineageVerified, (uint8_t)isArchived, (uint8_t)idempotencyFresh, (uint8_t)accountBound, (uint8_t)accountRejected, (uint8_t)firstByteLocked, (uint8_t)grammarAllowed, (uint8_t)envScrubbed, (uint8_t)budgetOk);
}

JNIEXPORT jlong JNICALL
Java_sh_sandboxed_dashboard_orb_OrbKernel_orbProviderPoolStep(JNIEnv *env, jclass clazz, jint hasBoundAccount, jint boundAccountId, jint candidateAccountId, jint isRejected, jint firstByteSent, jint isFailoverAttempt, jint attempts, jint maxAttempts, jlong nowEpoch, jlong resetEpoch) {
    return (jlong)orb_provider_pool_step((uint8_t)hasBoundAccount, (uint32_t)boundAccountId, (uint32_t)candidateAccountId, (uint8_t)isRejected, (uint8_t)firstByteSent, (uint8_t)isFailoverAttempt, (uint32_t)attempts, (uint32_t)maxAttempts, (uint64_t)nowEpoch, (uint64_t)resetEpoch);
}

JNIEXPORT jlong JNICALL
Java_sh_sandboxed_dashboard_orb_OrbKernel_orbRouteArgminStep(JNIEnv *env, jclass clazz, jint hasBest, jint bestId, jlong bestScore, jint candId, jlong candScore, jint candAdmissible) {
    return (jlong)orb_route_argmin_step((uint8_t)hasBest, (uint32_t)bestId, (uint64_t)bestScore, (uint32_t)candId, (uint64_t)candScore, (uint8_t)candAdmissible);
}

JNIEXPORT jlong JNICALL
Java_sh_sandboxed_dashboard_orb_OrbKernel_orbMissionControlStep(JNIEnv *env, jclass clazz, jint isArchived, jint activeTrackWriters, jint hasLease, jint msgAlreadyDelivered, jint isResume, jint sessionCreated, jint lineageVerified, jint rolloutExists, jint hasFallbackPrompt) {
    return (jlong)orb_mission_control_step((uint8_t)isArchived, (uint32_t)activeTrackWriters, (uint8_t)hasLease, (uint8_t)msgAlreadyDelivered, (uint8_t)isResume, (uint8_t)sessionCreated, (uint8_t)lineageVerified, (uint8_t)rolloutExists, (uint8_t)hasFallbackPrompt);
}

JNIEXPORT jlong JNICALL
Java_sh_sandboxed_dashboard_orb_OrbKernel_orbForkHomeStep(JNIEnv *env, jclass clazz, jint isForkOrSide, jint sourceExists, jint sourceIsSymlink, jint sameWorkspace, jint sameNode, jint hasCommittedTransfer, jint requestedOverrideHome) {
    return (jlong)orb_fork_home_step((uint8_t)isForkOrSide, (uint8_t)sourceExists, (uint8_t)sourceIsSymlink, (uint8_t)sameWorkspace, (uint8_t)sameNode, (uint8_t)hasCommittedTransfer, (uint8_t)requestedOverrideHome);
}

JNIEXPORT jlong JNICALL
Java_sh_sandboxed_dashboard_orb_OrbKernel_orbPrivdCommandStep(JNIEnv *env, jclass clazz, jint leaseValid, jint grantScope, jint commandClass, jint unitMatchesAllowed, jint hasShellMetacharOrFlagBypass, jint hasPathTraversalOrSymlink, jint hasUnsafeEnvVar, jint requireForceCmd) {
    return (jlong)orb_privd_command_step((uint8_t)leaseValid, (uint8_t)grantScope, (uint8_t)commandClass, (uint8_t)unitMatchesAllowed, (uint8_t)hasShellMetacharOrFlagBypass, (uint8_t)hasPathTraversalOrSymlink, (uint8_t)hasUnsafeEnvVar, (uint8_t)requireForceCmd);
}

JNIEXPORT jlong JNICALL
Java_sh_sandboxed_dashboard_orb_OrbKernel_orbSshIdentityStep(JNIEnv *env, jclass clazz, jint isWorkerOrContainerTarget, jint bundleHasControlPlaneKey, jint parentDirIsSymlink, jint pubKeyIsEd25519WithoutPrivate, jint proxyJumpValid, jint codexCyberProgramValid, jint codexGoalBudgetExhausted) {
    return (jlong)orb_ssh_identity_step((uint8_t)isWorkerOrContainerTarget, (uint8_t)bundleHasControlPlaneKey, (uint8_t)parentDirIsSymlink, (uint8_t)pubKeyIsEd25519WithoutPrivate, (uint8_t)proxyJumpValid, (uint8_t)codexCyberProgramValid, (uint8_t)codexGoalBudgetExhausted);
}

JNIEXPORT jlong JNICALL
Java_sh_sandboxed_dashboard_orb_OrbKernel_orbAgentEventNormalizeStep(JNIEnv *env, jclass clazz, jint harnessKind, jint rawEventKind, jint isCompleted, jint hasNonEmptyText, jint sessionMatchesExpected, jint isDuplicateTurnOrTool, jint payloadBytes, jint maxPayloadBytes) {
    return (jlong)orb_agent_event_normalize_step((uint8_t)harnessKind, (uint8_t)rawEventKind, (uint8_t)isCompleted, (uint8_t)hasNonEmptyText, (uint32_t)sessionMatchesExpected, (uint32_t)isDuplicateTurnOrTool, (uint32_t)payloadBytes, (uint32_t)maxPayloadBytes);
}

JNIEXPORT jlong JNICALL
Java_sh_sandboxed_dashboard_orb_OrbKernel_orbTranscriptReduceStep(JNIEnv *env, jclass clazz, jlong lastAppliedSeq, jlong incomingSeq, jint thinkingOpen, jint normalizedAction, jint isReplayFromLog) {
    return (jlong)orb_transcript_reduce_step((uint64_t)lastAppliedSeq, (uint64_t)incomingSeq, (uint8_t)thinkingOpen, (uint8_t)normalizedAction, (uint8_t)isReplayFromLog);
}

JNIEXPORT jlong JNICALL
Java_sh_sandboxed_dashboard_orb_OrbKernel_orbCursorPageStep(JNIEnv *env, jclass clazz, jlong sinceSeq, jlong beforeSeq, jlong itemSeq, jint hasSinceCursor, jint hasBeforeCursor, jint isPartialResponse, jint existingCount) {
    return (jlong)orb_cursor_page_step((uint64_t)sinceSeq, (uint64_t)beforeSeq, (uint64_t)itemSeq, (uint32_t)hasSinceCursor, (uint32_t)hasBeforeCursor, (uint32_t)isPartialResponse, (uint32_t)existingCount);
}

JNIEXPORT jlong JNICALL
Java_sh_sandboxed_dashboard_orb_OrbKernel_orbSidebarMergeStep(JNIEnv *env, jclass clazz, jint existingIdOrd, jint incomingIdOrd, jlong existingUpdatedAtMs, jlong incomingUpdatedAtMs, jint incomingSupersededOrArchived, jint isPartialPage) {
    return (jlong)orb_sidebar_merge_step((uint32_t)existingIdOrd, (uint32_t)incomingIdOrd, (uint64_t)existingUpdatedAtMs, (uint64_t)incomingUpdatedAtMs, (uint8_t)incomingSupersededOrArchived, (uint8_t)isPartialPage);
}

JNIEXPORT jlong JNICALL
Java_sh_sandboxed_dashboard_orb_OrbKernel_orbScrollEpochStep(JNIEnv *env, jclass clazz, jint layoutEpoch, jint lastCorrectedEpoch, jint correctionsInEpoch, jint isPinnedToBottom, jint userIsDragging, jint targetScrollTopPx, jint currentScrollTopPx) {
    return (jlong)orb_scroll_epoch_step((uint32_t)layoutEpoch, (uint32_t)lastCorrectedEpoch, (uint8_t)correctionsInEpoch, (uint8_t)isPinnedToBottom, (uint8_t)userIsDragging, (uint32_t)targetScrollTopPx, (uint32_t)currentScrollTopPx);
}

JNIEXPORT jlong JNICALL
Java_sh_sandboxed_dashboard_orb_OrbKernel_orbClientParityStep(JNIEnv *env, jclass clazz, jint clientTarget, jint wireSchemaId, jint transcriptSeq, jint markdownBlocksCount, jint sendQueueDepth, jint scrollCorrectedInEpoch) {
    return (jlong)orb_client_parity_step((uint8_t)clientTarget, (uint32_t)wireSchemaId, (uint32_t)transcriptSeq, (uint32_t)markdownBlocksCount, (uint32_t)sendQueueDepth, (uint8_t)scrollCorrectedInEpoch);
}

JNIEXPORT jlong JNICALL
Java_sh_sandboxed_dashboard_orb_OrbKernel_orbWireApplyPatchStep(JNIEnv *env, jclass clazz, jlong currentRev, jlong incomingRev, jint currentHasVal, jint currentVal, jint presence, jint incomingVal) {
    return (jlong)orb_wire_apply_patch_step((uint64_t)currentRev, (uint64_t)incomingRev, (uint8_t)currentHasVal, (uint32_t)currentVal, (uint8_t)presence, (uint32_t)incomingVal);
}

JNIEXPORT jlong JNICALL
Java_sh_sandboxed_dashboard_orb_OrbKernel_orbWireMachineStep(JNIEnv *env, jclass clazz, jint schemaId, jlong stateRev, jlong eventSeq, jint effectKind, jint effectAdmitted, jint outCap, jint requiredOutBytes) {
    return (jlong)orb_wire_machine_step((uint32_t)schemaId, (uint64_t)stateRev, (uint64_t)eventSeq, (uint8_t)effectKind, (uint8_t)effectAdmitted, (uint32_t)outCap, (uint32_t)requiredOutBytes);
}

JNIEXPORT jlong JNICALL
Java_sh_sandboxed_dashboard_orb_OrbKernel_orbHierarchyMergeStep(JNIEnv *env, jclass clazz, jlong currentEpoch, jlong incomingEpoch, jlong archiveEpoch, jint curArchived, jint curSuperseded, jint isPartialPatch, jint parentPresence, jint curParentOrd, jint incParentOrd, jint incArchive, jint incUnarchive, jint incSupersede) {
    return (jlong)orb_hierarchy_merge_step((uint64_t)currentEpoch, (uint64_t)incomingEpoch, (uint64_t)archiveEpoch, (uint8_t)curArchived, (uint8_t)curSuperseded, (uint8_t)isPartialPatch, (uint8_t)parentPresence, (uint32_t)curParentOrd, (uint32_t)incParentOrd, (uint8_t)incArchive, (uint8_t)incUnarchive, (uint8_t)incSupersede);
}

JNIEXPORT jlong JNICALL
Java_sh_sandboxed_dashboard_orb_OrbKernel_orbTranscriptFoldStep(JNIEnv *env, jclass clazz, jlong lastAppliedSeq, jlong incomingSeq, jint entryCount, jint thinkingOpen, jint normalizedAction, jint isReplayFromLog) {
    return (jlong)orb_transcript_fold_step((uint64_t)lastAppliedSeq, (uint64_t)incomingSeq, (uint32_t)entryCount, (uint8_t)thinkingOpen, (uint8_t)normalizedAction, (uint8_t)isReplayFromLog);
}

JNIEXPORT jlong JNICALL
Java_sh_sandboxed_dashboard_orb_OrbKernel_orbOutboxCrashReconcileStep(JNIEnv *env, jclass clazz, jint durableQueued, jint durableAcked, jint volatileInFlight, jlong leaseBootEpoch, jlong nodeBootEpoch, jint volatileLeaseOwner, jint reqOwner) {
    return (jlong)orb_outbox_crash_reconcile_step((uint32_t)durableQueued, (uint32_t)durableAcked, (uint32_t)volatileInFlight, (uint64_t)leaseBootEpoch, (uint64_t)nodeBootEpoch, (uint32_t)volatileLeaseOwner, (uint32_t)reqOwner);
}

JNIEXPORT jlong JNICALL
Java_sh_sandboxed_dashboard_orb_OrbKernel_orbProviderAttemptStep(JNIEnv *env, jclass clazz, jint pinnedAccountId, jint candidateAccountId, jint attemptsUsed, jint retryBudget, jint firstByteCommitted, jint failureKind, jlong upstreamNowEpoch, jlong cooldownUntilEpoch, jlong upstreamDeadline, jint authValid) {
    return (jlong)orb_provider_attempt_step((uint32_t)pinnedAccountId, (uint32_t)candidateAccountId, (uint32_t)attemptsUsed, (uint32_t)retryBudget, (uint8_t)firstByteCommitted, (uint8_t)failureKind, (uint64_t)upstreamNowEpoch, (uint64_t)cooldownUntilEpoch, (uint64_t)upstreamDeadline, (uint8_t)authValid);
}

JNIEXPORT jint JNICALL
Java_sh_sandboxed_dashboard_orb_OrbKernel_orbAuthToctouExecuteStep(JNIEnv *env, jclass clazz, jint principalKind, jint bunkerState, jint observedTargetId, jint execTargetId, jlong observedLeaseEpoch, jlong liveLeaseEpoch, jlong nowTick, jlong expiryTick, jlong observedDigest, jlong execDigest) {
    return (jint)orb_auth_toctou_execute_step((uint8_t)principalKind, (uint8_t)bunkerState, (uint32_t)observedTargetId, (uint32_t)execTargetId, (uint64_t)observedLeaseEpoch, (uint64_t)liveLeaseEpoch, (uint64_t)nowTick, (uint64_t)expiryTick, (uint64_t)observedDigest, (uint64_t)execDigest);
}

JNIEXPORT jlong JNICALL
Java_sh_sandboxed_dashboard_orb_OrbKernel_orbResourceLedgerStep(JNIEnv *env, jclass clazz, jint opKind, jint reservedSlots, jint activeSlots, jint maxSlots, jlong spentCents, jlong costDeltaCents, jlong budgetCents, jlong nowTick, jlong ttlExpiryTick) {
    return (jlong)orb_resource_ledger_step((uint8_t)opKind, (uint32_t)reservedSlots, (uint32_t)activeSlots, (uint32_t)maxSlots, (uint64_t)spentCents, (uint64_t)costDeltaCents, (uint64_t)budgetCents, (uint64_t)nowTick, (uint64_t)ttlExpiryTick);
}

JNIEXPORT jlong JNICALL
Java_sh_sandboxed_dashboard_orb_OrbKernel_orbStreamBoundedCommitStep(JNIEnv *env, jclass clazz, jint prevLen, jint prevCommit, jint prevCheckpoint, jint newLen, jint rawCommit, jint maxOpenTailBytes) {
    return (jlong)orb_stream_bounded_commit_step((uint32_t)prevLen, (uint32_t)prevCommit, (uint32_t)prevCheckpoint, (uint32_t)newLen, (uint32_t)rawCommit, (uint32_t)maxOpenTailBytes);
}

JNIEXPORT jbyte JNICALL
Java_sh_sandboxed_dashboard_orb_OrbKernel_leansysSseFrameScan(JNIEnv *env, jclass clazz, jlong frameOff, jlong frameLen, jlong chunkLen, jint fieldKind, jint nextByte, jint lastByte) {
    return (jbyte)leansys_sse_frame_scan((uint64_t)frameOff, (uint64_t)frameLen, (uint64_t)chunkLen, (uint8_t)fieldKind, (uint8_t)nextByte, (uint8_t)lastByte);
}

JNIEXPORT jbyte JNICALL
Java_sh_sandboxed_dashboard_orb_OrbKernel_leansysGfmPipeScan(JNIEnv *env, jclass clazz, jlong rowOff, jlong rowLen, jlong bufLen, jint colCount, jint sepCols, jint unterminatedEscape) {
    return (jbyte)leansys_gfm_pipe_scan((uint64_t)rowOff, (uint64_t)rowLen, (uint64_t)bufLen, (uint32_t)colCount, (uint32_t)sepCols, (uint8_t)unterminatedEscape);
}

JNIEXPORT jbyte JNICALL
Java_sh_sandboxed_dashboard_orb_OrbKernel_leansysTagScan(JNIEnv *env, jclass clazz, jlong tagOff, jlong tagLen, jlong attrOff, jlong attrLen, jlong bufLen, jint tagKind) {
    return (jbyte)leansys_tag_scan((uint64_t)tagOff, (uint64_t)tagLen, (uint64_t)attrOff, (uint64_t)attrLen, (uint64_t)bufLen, (uint8_t)tagKind);
}

JNIEXPORT jlong JNICALL
Java_sh_sandboxed_dashboard_orb_OrbKernel_leansysTranscriptIndex(JNIEnv *env, jclass clazz, jlong turnOff, jlong turnLen, jlong bufLen, jlong prevDigest, jlong blockHash) {
    return (jlong)leansys_transcript_index((uint64_t)turnOff, (uint64_t)turnLen, (uint64_t)bufLen, (uint64_t)prevDigest, (uint64_t)blockHash);
}

JNIEXPORT jint JNICALL
Java_sh_sandboxed_dashboard_orb_OrbKernel_leansysVerifyIosJetsamBudget(JNIEnv *env, jclass clazz, jlong dirtyRssBytes, jlong allocBytes, jlong maxJetsamBytes, jlong pageAlignMask, jint isAppExtension) {
    return (jint)leansys_verify_ios_jetsam_budget((uint64_t)dirtyRssBytes, (uint64_t)allocBytes, (uint64_t)maxJetsamBytes, (uint64_t)pageAlignMask, (uint8_t)isAppExtension);
}

JNIEXPORT jint JNICALL
Java_sh_sandboxed_dashboard_orb_OrbKernel_leansysVerifyWorkerBudget(JNIEnv *env, jclass clazz, jlong activeWorkers, jlong maxWorkers, jlong microChunks, jlong totalLen, jint topologyKind) {
    return (jint)leansys_verify_worker_budget((uint64_t)activeWorkers, (uint64_t)maxWorkers, (uint64_t)microChunks, (uint64_t)totalLen, (uint8_t)topologyKind);
}

JNIEXPORT jint JNICALL
Java_sh_sandboxed_dashboard_orb_OrbKernel_leansysVerifyPageAlignedBuffer(JNIEnv *env, jclass clazz, jlong addr, jlong allocBytes, jlong capacityBytes, jlong dirtyRssBytes, jlong maxBudgetBytes, jlong pageAlignMask) {
    return (jint)leansys_verify_page_aligned_buffer((uint64_t)addr, (uint64_t)allocBytes, (uint64_t)capacityBytes, (uint64_t)dirtyRssBytes, (uint64_t)maxBudgetBytes, (uint64_t)pageAlignMask);
}

JNIEXPORT jint JNICALL
Java_sh_sandboxed_dashboard_orb_OrbKernel_leansysSelectIsa(JNIEnv *env, jclass clazz, jlong detectedHwCaps, jlong requiredMask, jint requestedVariantId, jint maxVariantId) {
    return (jint)leansys_select_isa((uint64_t)detectedHwCaps, (uint64_t)requiredMask, (uint8_t)requestedVariantId, (uint8_t)maxVariantId);
}

JNIEXPORT jint JNICALL
Java_sh_sandboxed_dashboard_orb_OrbKernel_leansysVerifyIsaSelection(JNIEnv *env, jclass clazz, jlong detectedHwCaps, jlong requiredMask, jint selectedVariantId, jint maxVariantId) {
    return (jint)leansys_verify_isa_selection((uint64_t)detectedHwCaps, (uint64_t)requiredMask, (uint8_t)selectedVariantId, (uint8_t)maxVariantId);
}
