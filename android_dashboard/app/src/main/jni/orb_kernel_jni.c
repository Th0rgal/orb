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
