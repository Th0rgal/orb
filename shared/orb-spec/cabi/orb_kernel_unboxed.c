#include "orb_kernel.h"
#define LEAN_EXPORT
#define lean_uint8_dec_eq(a, b) ((uint8_t)((a) == (b)))
#define lean_uint8_dec_lt(a, b) ((uint8_t)((a) < (b)))
#define lean_uint8_dec_le(a, b) ((uint8_t)((a) <= (b)))
#define lean_uint8_to_uint32(a) ((uint32_t)(a))
#define lean_uint8_to_uint64(a) ((uint64_t)(a))
#define lean_uint32_dec_eq(a, b) ((uint8_t)((a) == (b)))
#define lean_uint32_dec_lt(a, b) ((uint8_t)((a) < (b)))
#define lean_uint32_dec_le(a, b) ((uint8_t)((a) <= (b)))
#define lean_uint32_add(a, b) ((uint32_t)((a) + (b)))
#define lean_uint32_sub(a, b) ((uint32_t)((a) - (b)))
#define lean_uint32_mul(a, b) ((uint32_t)((a) * (b)))
#define lean_uint32_lor(a, b) ((uint32_t)((a) | (b)))
#define lean_uint32_land(a, b) ((uint32_t)((a) & (b)))
#define lean_uint32_shift_left(a, b) ((uint32_t)((a) << (b)))
#define lean_uint32_shift_right(a, b) ((uint32_t)((a) >> (b)))
#define lean_uint32_to_uint64(a) ((uint64_t)(a))
#define lean_uint64_dec_eq(a, b) ((uint8_t)((a) == (b)))
#define lean_uint64_dec_lt(a, b) ((uint8_t)((a) < (b)))
#define lean_uint64_dec_le(a, b) ((uint8_t)((a) <= (b)))
#define lean_uint64_add(a, b) ((uint64_t)((a) + (b)))
#define lean_uint64_sub(a, b) ((uint64_t)((a) - (b)))
#define lean_uint64_mul(a, b) ((uint64_t)((a) * (b)))
#define lean_uint64_div(a, b) ((uint64_t)((a) / (b)))
#define lean_uint64_mod(a, b) ((uint64_t)((a) % (b)))
#define lean_uint64_lor(a, b) ((uint64_t)((a) | (b)))
#define lean_uint64_land(a, b) ((uint64_t)((a) & (b)))
#define lean_uint64_xor(a, b) ((uint64_t)((a) ^ (b)))
#define lean_uint64_shift_left(a, b) ((uint64_t)((a) << (b)))
#define lean_uint64_shift_right(a, b) ((uint64_t)((a) >> (b)))
LEAN_EXPORT uint8_t orb_verify_writer_reuse(uint8_t v_hasContinue_1_, uint8_t v_contTrackNonempty_2_, uint8_t v_contMatchesStored_3_, uint8_t v_hasAnyEdit_4_, uint8_t v_workChanged_5_, uint8_t v_identityUpdated_6_){
_start:
{
uint8_t v___x_7_; uint8_t v___x_8_;
v___x_7_ = 1;
v___x_8_ = lean_uint8_dec_eq(v_hasContinue_1_, v___x_7_);
if (v___x_8_ == 0)
{
uint8_t v___x_9_; uint8_t v___x_10_;
v___x_9_ = 0;
v___x_10_ = lean_uint8_dec_eq(v_workChanged_5_, v___x_9_);
if (v___x_10_ == 0)
{
uint8_t v___x_11_;
v___x_11_ = lean_uint8_dec_eq(v_identityUpdated_6_, v___x_7_);
if (v___x_11_ == 0)
{
return v___x_9_;
}
else
{
return v___x_7_;
}
}
else
{
return v___x_7_;
}
}
else
{
uint8_t v___x_12_;
v___x_12_ = lean_uint8_dec_eq(v_contTrackNonempty_2_, v___x_7_);
if (v___x_12_ == 0)
{
uint8_t v___x_13_;
v___x_13_ = 0;
return v___x_13_;
}
else
{
uint8_t v___x_14_;
v___x_14_ = lean_uint8_dec_eq(v_contMatchesStored_3_, v___x_7_);
if (v___x_14_ == 0)
{
uint8_t v___x_15_;
v___x_15_ = 0;
return v___x_15_;
}
else
{
uint8_t v___x_16_; uint8_t v___x_17_;
v___x_16_ = 0;
v___x_17_ = lean_uint8_dec_eq(v_hasAnyEdit_4_, v___x_16_);
if (v___x_17_ == 0)
{
return v___x_16_;
}
else
{
return v___x_7_;
}
}
}
}
}
}

LEAN_EXPORT uint8_t orb_verify_lease_mode(uint8_t v_writerFlag_32_, uint8_t v_hasReadonlyTag_33_, uint8_t v_hasWriterTag_34_, uint8_t v_isReadonlyIntent_35_){
_start:
{
uint8_t v___x_36_; uint8_t v___x_37_;
v___x_36_ = 0;
v___x_37_ = lean_uint8_dec_eq(v_writerFlag_32_, v___x_36_);
if (v___x_37_ == 0)
{
uint8_t v___x_38_; uint8_t v___x_39_;
v___x_38_ = 1;
v___x_39_ = lean_uint8_dec_eq(v_hasReadonlyTag_33_, v___x_38_);
if (v___x_39_ == 0)
{
uint8_t v___x_40_;
v___x_40_ = lean_uint8_dec_eq(v_writerFlag_32_, v___x_38_);
if (v___x_40_ == 0)
{
uint8_t v___x_41_;
v___x_41_ = lean_uint8_dec_eq(v_hasWriterTag_34_, v___x_38_);
if (v___x_41_ == 0)
{
uint8_t v___x_42_;
v___x_42_ = lean_uint8_dec_eq(v_isReadonlyIntent_35_, v___x_38_);
if (v___x_42_ == 0)
{
return v___x_38_;
}
else
{
return v___x_36_;
}
}
else
{
return v___x_38_;
}
}
else
{
return v___x_38_;
}
}
else
{
return v___x_36_;
}
}
else
{
return v___x_36_;
}
}
}

LEAN_EXPORT uint8_t orb_verify_track_hold(uint8_t v_inUnresolved_53_, uint8_t v_inQueued_54_, uint8_t v_hasLiveOwner_55_, uint8_t v_nativeGoalHolds_56_){
_start:
{
uint8_t v___x_57_; uint8_t v___x_58_;
v___x_57_ = 1;
v___x_58_ = lean_uint8_dec_eq(v_inUnresolved_53_, v___x_57_);
if (v___x_58_ == 0)
{
uint8_t v___x_59_;
v___x_59_ = lean_uint8_dec_eq(v_inQueued_54_, v___x_57_);
if (v___x_59_ == 0)
{
uint8_t v___x_60_;
v___x_60_ = lean_uint8_dec_eq(v_hasLiveOwner_55_, v___x_57_);
if (v___x_60_ == 0)
{
uint8_t v___x_61_;
v___x_61_ = lean_uint8_dec_eq(v_nativeGoalHolds_56_, v___x_57_);
if (v___x_61_ == 0)
{
uint8_t v___x_62_;
v___x_62_ = 0;
return v___x_62_;
}
else
{
return v___x_57_;
}
}
else
{
return v___x_57_;
}
}
else
{
return v___x_57_;
}
}
else
{
return v___x_57_;
}
}
}

LEAN_EXPORT uint8_t orb_verify_repo_disjoint(uint8_t v_handleRepoKnown_73_, uint8_t v_targetRepoKnown_74_, uint8_t v_sameRepo_75_){
_start:
{
uint8_t v___x_76_; uint8_t v___x_77_;
v___x_76_ = 1;
v___x_77_ = lean_uint8_dec_eq(v_handleRepoKnown_73_, v___x_76_);
if (v___x_77_ == 0)
{
uint8_t v___x_78_;
v___x_78_ = 0;
return v___x_78_;
}
else
{
uint8_t v___x_79_;
v___x_79_ = lean_uint8_dec_eq(v_targetRepoKnown_74_, v___x_76_);
if (v___x_79_ == 0)
{
uint8_t v___x_80_;
v___x_80_ = 0;
return v___x_80_;
}
else
{
uint8_t v___x_81_; uint8_t v___x_82_;
v___x_81_ = 0;
v___x_82_ = lean_uint8_dec_eq(v_sameRepo_75_, v___x_81_);
if (v___x_82_ == 0)
{
return v___x_81_;
}
else
{
return v___x_76_;
}
}
}
}
}

LEAN_EXPORT uint8_t orb_verify_remote_outbox(uint8_t v_opKind_91_, uint8_t v_alreadyExists_92_, uint8_t v_sameMission_93_, uint8_t v_isCancelled_94_, uint8_t v_isSuperseded_95_, uint8_t v_sessionReady_96_, uint8_t v_prUnsupported_97_, uint8_t v_hasJobId_98_, uint8_t v_deliveryAbandonable_99_){
_start:
{
uint8_t v___x_100_; uint8_t v___x_113_;
v___x_100_ = 0;
v___x_113_ = lean_uint8_dec_eq(v_opKind_91_, v___x_100_);
if (v___x_113_ == 0)
{
goto v___jp_101_;
}
else
{
uint8_t v___x_114_; uint8_t v___x_115_;
v___x_114_ = 1;
v___x_115_ = lean_uint8_dec_eq(v_alreadyExists_92_, v___x_114_);
if (v___x_115_ == 0)
{
goto v___jp_107_;
}
else
{
uint8_t v___x_116_;
v___x_116_ = lean_uint8_dec_eq(v_sameMission_93_, v___x_114_);
if (v___x_116_ == 0)
{
goto v___jp_107_;
}
else
{
uint8_t v___x_117_;
v___x_117_ = lean_uint8_dec_eq(v_isCancelled_94_, v___x_100_);
if (v___x_117_ == 0)
{
goto v___jp_107_;
}
else
{
return v___x_114_;
}
}
}
}
v___jp_101_:
{
uint8_t v___x_102_;
v___x_102_ = lean_uint8_dec_eq(v_opKind_91_, v___x_100_);
if (v___x_102_ == 0)
{
uint8_t v___x_103_;
v___x_103_ = lean_uint8_dec_eq(v_hasJobId_98_, v___x_100_);
if (v___x_103_ == 0)
{
uint8_t v___x_104_; uint8_t v___x_105_;
v___x_104_ = 1;
v___x_105_ = lean_uint8_dec_eq(v_deliveryAbandonable_99_, v___x_104_);
if (v___x_105_ == 0)
{
return v___x_100_;
}
else
{
return v___x_104_;
}
}
else
{
uint8_t v___x_106_;
v___x_106_ = 1;
return v___x_106_;
}
}
else
{
return v___x_100_;
}
}
v___jp_107_:
{
uint8_t v___x_108_;
v___x_108_ = lean_uint8_dec_eq(v_alreadyExists_92_, v___x_100_);
if (v___x_108_ == 0)
{
goto v___jp_101_;
}
else
{
uint8_t v___x_109_;
v___x_109_ = lean_uint8_dec_eq(v_isSuperseded_95_, v___x_100_);
if (v___x_109_ == 0)
{
goto v___jp_101_;
}
else
{
uint8_t v___x_110_; uint8_t v___x_111_;
v___x_110_ = 1;
v___x_111_ = lean_uint8_dec_eq(v_sessionReady_96_, v___x_110_);
if (v___x_111_ == 0)
{
goto v___jp_101_;
}
else
{
uint8_t v___x_112_;
v___x_112_ = lean_uint8_dec_eq(v_prUnsupported_97_, v___x_100_);
if (v___x_112_ == 0)
{
goto v___jp_101_;
}
else
{
return v___x_110_;
}
}
}
}
}
}
}

LEAN_EXPORT uint8_t orb_verify_board_slots(uint32_t v_maxParallel_138_, uint32_t v_reservedBossSlots_139_, uint32_t v_totalRunning_140_){
_start:
{
uint32_t v___x_141_; uint8_t v___x_142_;
v___x_141_ = 1;
v___x_142_ = lean_uint32_dec_le(v___x_141_, v_reservedBossSlots_139_);
if (v___x_142_ == 0)
{
uint8_t v___x_143_;
v___x_143_ = 0;
return v___x_143_;
}
else
{
uint8_t v___x_144_;
v___x_144_ = lean_uint32_dec_lt(v_reservedBossSlots_139_, v_maxParallel_138_);
if (v___x_144_ == 0)
{
uint8_t v___x_145_;
v___x_145_ = 0;
return v___x_145_;
}
else
{
uint32_t v___x_146_; uint8_t v___x_147_;
v___x_146_ = lean_uint32_sub(v_maxParallel_138_, v_reservedBossSlots_139_);
v___x_147_ = lean_uint32_dec_lt(v_totalRunning_140_, v___x_146_);
if (v___x_147_ == 0)
{
uint8_t v___x_148_;
v___x_148_ = 0;
return v___x_148_;
}
else
{
uint8_t v___x_149_;
v___x_149_ = 1;
return v___x_149_;
}
}
}
}
}

LEAN_EXPORT uint8_t orb_verify_board_retry(uint32_t v_attempts_158_, uint32_t v_maxAttempts_159_, uint8_t v_requiresExternalRecovery_160_, uint8_t v_preflightMerged_161_, uint8_t v_retrySuppressed_162_){
_start:
{
uint32_t v___x_163_; uint8_t v___x_164_;
v___x_163_ = 1;
v___x_164_ = lean_uint32_dec_le(v___x_163_, v_maxAttempts_159_);
if (v___x_164_ == 0)
{
uint8_t v___x_165_;
v___x_165_ = 0;
return v___x_165_;
}
else
{
uint8_t v___x_166_;
v___x_166_ = lean_uint32_dec_lt(v_attempts_158_, v_maxAttempts_159_);
if (v___x_166_ == 0)
{
uint8_t v___x_167_;
v___x_167_ = 0;
return v___x_167_;
}
else
{
uint8_t v___x_168_; uint8_t v___x_169_;
v___x_168_ = 0;
v___x_169_ = lean_uint8_dec_eq(v_requiresExternalRecovery_160_, v___x_168_);
if (v___x_169_ == 0)
{
return v___x_168_;
}
else
{
uint8_t v___x_170_;
v___x_170_ = lean_uint8_dec_eq(v_preflightMerged_161_, v___x_168_);
if (v___x_170_ == 0)
{
return v___x_168_;
}
else
{
uint8_t v___x_171_;
v___x_171_ = lean_uint8_dec_eq(v_retrySuppressed_162_, v___x_168_);
if (v___x_171_ == 0)
{
return v___x_168_;
}
else
{
uint8_t v___x_172_;
v___x_172_ = 1;
return v___x_172_;
}
}
}
}
}
}
}

LEAN_EXPORT uint8_t orb_verify_job_transition(uint8_t v_fromState_185_, uint8_t v_toState_186_){
_start:
{
uint8_t v___x_187_; uint8_t v___x_201_;
v___x_187_ = 0;
v___x_201_ = lean_uint8_dec_eq(v_fromState_185_, v___x_187_);
if (v___x_201_ == 0)
{
goto v___jp_194_;
}
else
{
uint8_t v___x_202_; uint8_t v___x_203_;
v___x_202_ = 1;
v___x_203_ = lean_uint8_dec_le(v___x_202_, v_toState_186_);
if (v___x_203_ == 0)
{
goto v___jp_194_;
}
else
{
uint8_t v___x_204_; uint8_t v___x_205_;
v___x_204_ = 5;
v___x_205_ = lean_uint8_dec_le(v_toState_186_, v___x_204_);
if (v___x_205_ == 0)
{
goto v___jp_194_;
}
else
{
return v___x_202_;
}
}
}
v___jp_188_:
{
uint8_t v___x_189_; uint8_t v___x_190_;
v___x_189_ = 5;
v___x_190_ = lean_uint8_dec_eq(v_fromState_185_, v___x_189_);
if (v___x_190_ == 0)
{
return v___x_187_;
}
else
{
uint8_t v___x_191_; uint8_t v___x_192_;
v___x_191_ = 4;
v___x_192_ = lean_uint8_dec_eq(v_toState_186_, v___x_191_);
if (v___x_192_ == 0)
{
return v___x_187_;
}
else
{
uint8_t v___x_193_;
v___x_193_ = 1;
return v___x_193_;
}
}
}
v___jp_194_:
{
uint8_t v___x_195_; uint8_t v___x_196_;
v___x_195_ = 1;
v___x_196_ = lean_uint8_dec_eq(v_fromState_185_, v___x_195_);
if (v___x_196_ == 0)
{
goto v___jp_188_;
}
else
{
uint8_t v___x_197_; uint8_t v___x_198_;
v___x_197_ = 2;
v___x_198_ = lean_uint8_dec_le(v___x_197_, v_toState_186_);
if (v___x_198_ == 0)
{
goto v___jp_188_;
}
else
{
uint8_t v___x_199_; uint8_t v___x_200_;
v___x_199_ = 5;
v___x_200_ = lean_uint8_dec_le(v_toState_186_, v___x_199_);
if (v___x_200_ == 0)
{
goto v___jp_188_;
}
else
{
return v___x_195_;
}
}
}
}
}
}

LEAN_EXPORT uint8_t orb_verify_bundle_budget(uint8_t v_isComplete_212_, uint64_t v_decodedBytes_213_, uint64_t v_overlayCap_214_, uint64_t v_completeCap_215_, uint64_t v_maxBytes_216_){
_start:
{
uint8_t v___x_217_; uint64_t v___y_219_; uint8_t v___x_224_;
v___x_217_ = 1;
v___x_224_ = lean_uint8_dec_eq(v_isComplete_212_, v___x_217_);
if (v___x_224_ == 0)
{
v___y_219_ = v_overlayCap_214_;
goto v___jp_218_;
}
else
{
v___y_219_ = v_completeCap_215_;
goto v___jp_218_;
}
v___jp_218_:
{
uint8_t v___x_220_;
v___x_220_ = lean_uint64_dec_le(v_decodedBytes_213_, v___y_219_);
if (v___x_220_ == 0)
{
uint8_t v___x_221_;
v___x_221_ = 0;
return v___x_221_;
}
else
{
uint8_t v___x_222_;
v___x_222_ = lean_uint64_dec_le(v_decodedBytes_213_, v_maxBytes_216_);
if (v___x_222_ == 0)
{
uint8_t v___x_223_;
v___x_223_ = 0;
return v___x_223_;
}
else
{
return v___x_217_;
}
}
}
}
}

LEAN_EXPORT uint8_t orb_verify_token_rotation(uint8_t v_presentedNonEmpty_237_, uint8_t v_matchCurrent_238_, uint8_t v_prevNonEmpty_239_, uint8_t v_matchPrev_240_, uint8_t v_scopeAndExpiryOk_241_){
_start:
{
uint8_t v___x_242_; uint8_t v___x_246_;
v___x_242_ = 1;
v___x_246_ = lean_uint8_dec_eq(v_presentedNonEmpty_237_, v___x_242_);
if (v___x_246_ == 0)
{
uint8_t v___x_247_;
v___x_247_ = 0;
return v___x_247_;
}
else
{
uint8_t v___x_248_;
v___x_248_ = lean_uint8_dec_eq(v_matchCurrent_238_, v___x_242_);
if (v___x_248_ == 0)
{
uint8_t v___x_249_;
v___x_249_ = lean_uint8_dec_eq(v_prevNonEmpty_239_, v___x_242_);
if (v___x_249_ == 0)
{
uint8_t v___x_250_;
v___x_250_ = 0;
return v___x_250_;
}
else
{
uint8_t v___x_251_;
v___x_251_ = lean_uint8_dec_eq(v_matchPrev_240_, v___x_242_);
if (v___x_251_ == 0)
{
uint8_t v___x_252_;
v___x_252_ = 0;
return v___x_252_;
}
else
{
goto v___jp_243_;
}
}
}
else
{
goto v___jp_243_;
}
}
v___jp_243_:
{
uint8_t v___x_244_;
v___x_244_ = lean_uint8_dec_eq(v_scopeAndExpiryOk_241_, v___x_242_);
if (v___x_244_ == 0)
{
uint8_t v___x_245_;
v___x_245_ = 0;
return v___x_245_;
}
else
{
return v___x_242_;
}
}
}
}

LEAN_EXPORT uint8_t orb_verify_log_window(uint64_t v_offset_265_, uint64_t v_reqLen_266_, uint64_t v_maxChunk_267_, uint64_t v_hardCap_268_, uint64_t v_fileSize_269_, uint64_t v_actualLen_270_){
_start:
{
uint8_t v___x_271_;
v___x_271_ = lean_uint64_dec_le(v_offset_265_, v_fileSize_269_);
if (v___x_271_ == 0)
{
uint8_t v___x_272_;
v___x_272_ = 0;
return v___x_272_;
}
else
{
uint8_t v___x_273_;
v___x_273_ = lean_uint64_dec_le(v_reqLen_266_, v_maxChunk_267_);
if (v___x_273_ == 0)
{
uint8_t v___x_274_;
v___x_274_ = 0;
return v___x_274_;
}
else
{
uint8_t v___x_275_;
v___x_275_ = lean_uint64_dec_le(v_maxChunk_267_, v_hardCap_268_);
if (v___x_275_ == 0)
{
uint8_t v___x_276_;
v___x_276_ = 0;
return v___x_276_;
}
else
{
uint8_t v___x_277_;
v___x_277_ = lean_uint64_dec_le(v_actualLen_270_, v_reqLen_266_);
if (v___x_277_ == 0)
{
uint8_t v___x_278_;
v___x_278_ = 0;
return v___x_278_;
}
else
{
uint64_t v___x_279_; uint8_t v___x_280_;
v___x_279_ = lean_uint64_sub(v_fileSize_269_, v_offset_265_);
v___x_280_ = lean_uint64_dec_le(v_actualLen_270_, v___x_279_);
if (v___x_280_ == 0)
{
uint8_t v___x_281_;
v___x_281_ = 0;
return v___x_281_;
}
else
{
uint8_t v___x_282_;
v___x_282_ = 1;
return v___x_282_;
}
}
}
}
}
}
}

LEAN_EXPORT uint64_t orb_mix64_word(uint64_t v_acc_297_, uint64_t v_word_298_){
_start:
{
uint64_t v___x_299_; uint64_t v___x_300_; uint64_t v_v1_301_; uint64_t v___x_302_; uint64_t v___x_303_; uint64_t v___x_304_; uint64_t v___x_305_; uint64_t v_v2_306_; uint64_t v___x_307_; uint64_t v_v3_308_; uint64_t v___x_309_; uint64_t v___x_310_; uint64_t v___x_311_;
v___x_299_ = 13787848793156543929ULL;
v___x_300_ = lean_uint64_mul(v_word_298_, v___x_299_);
v_v1_301_ = lean_uint64_add(v_acc_297_, v___x_300_);
v___x_302_ = 31ULL;
v___x_303_ = lean_uint64_shift_left(v_v1_301_, v___x_302_);
v___x_304_ = 33ULL;
v___x_305_ = lean_uint64_shift_right(v_v1_301_, v___x_304_);
v_v2_306_ = lean_uint64_lor(v___x_303_, v___x_305_);
v___x_307_ = 11400714819323198485ULL;
v_v3_308_ = lean_uint64_mul(v_v2_306_, v___x_307_);
v___x_309_ = 27ULL;
v___x_310_ = lean_uint64_shift_right(v_v3_308_, v___x_309_);
v___x_311_ = lean_uint64_xor(v_v3_308_, v___x_310_);
return v___x_311_;
}
}

LEAN_EXPORT uint32_t orb_proxy_step(uint8_t v_committed_318_, uint8_t v_chunkCommits_319_, uint8_t v_stalled_320_, uint32_t v_retries_321_, uint32_t v_maxRetries_322_){
_start:
{
uint32_t v___y_324_; uint8_t v___x_327_; uint32_t v___y_329_; uint8_t v___x_344_;
v___x_327_ = 1;
v___x_344_ = lean_uint8_dec_eq(v_committed_318_, v___x_327_);
if (v___x_344_ == 0)
{
uint8_t v___x_345_;
v___x_345_ = lean_uint8_dec_eq(v_chunkCommits_319_, v___x_327_);
if (v___x_345_ == 0)
{
uint32_t v___x_346_;
v___x_346_ = 0;
v___y_329_ = v___x_346_;
goto v___jp_328_;
}
else
{
goto v___jp_342_;
}
}
else
{
goto v___jp_342_;
}
v___jp_323_:
{
uint32_t v___x_325_; uint32_t v___x_326_;
v___x_325_ = 768;
v___x_326_ = lean_uint32_lor(v___y_324_, v___x_325_);
return v___x_326_;
}
v___jp_328_:
{
uint8_t v___x_330_;
v___x_330_ = lean_uint8_dec_eq(v_stalled_320_, v___x_327_);
if (v___x_330_ == 0)
{
return v___y_329_;
}
else
{
uint8_t v___x_331_; uint8_t v___x_332_;
v___x_331_ = 0;
v___x_332_ = lean_uint8_dec_eq(v_committed_318_, v___x_331_);
if (v___x_332_ == 0)
{
v___y_324_ = v___y_329_;
goto v___jp_323_;
}
else
{
uint8_t v___x_333_;
v___x_333_ = lean_uint32_dec_lt(v_retries_321_, v_maxRetries_322_);
if (v___x_333_ == 0)
{
v___y_324_ = v___y_329_;
goto v___jp_323_;
}
else
{
uint32_t v___x_334_; uint32_t v___x_335_; uint32_t v___x_336_; uint8_t v___x_337_;
v___x_334_ = 2;
v___x_335_ = 1;
v___x_336_ = lean_uint32_add(v_retries_321_, v___x_335_);
v___x_337_ = lean_uint32_dec_le(v___x_334_, v___x_336_);
if (v___x_337_ == 0)
{
uint32_t v___x_338_; uint32_t v___x_339_;
v___x_338_ = 256;
v___x_339_ = lean_uint32_lor(v___y_329_, v___x_338_);
return v___x_339_;
}
else
{
uint32_t v___x_340_; uint32_t v___x_341_;
v___x_340_ = 66048;
v___x_341_ = lean_uint32_lor(v___y_329_, v___x_340_);
return v___x_341_;
}
}
}
}
}
v___jp_342_:
{
uint32_t v___x_343_;
v___x_343_ = 1;
v___y_329_ = v___x_343_;
goto v___jp_328_;
}
}
}

LEAN_EXPORT uint32_t orb_stream_deadlines(uint64_t v_clientElapsedMs_359_, uint64_t v_keepaliveMs_360_, uint64_t v_upstreamElapsedMs_361_, uint64_t v_baseIdleMs_362_, uint64_t v_providerFloorMs_363_, uint8_t v_atEventBoundary_364_, uint8_t v_hasMissionHeader_365_, uint8_t v_authVerified_366_){
_start:
{
uint32_t v___y_368_; uint32_t v___y_369_; uint32_t v___y_370_; uint32_t v___y_374_; uint32_t v___y_375_; uint32_t v___y_378_; uint32_t v___y_379_; uint64_t v___y_385_; uint32_t v___y_386_; uint64_t v___y_391_; uint64_t v___y_394_; uint8_t v___x_399_;
v___x_399_ = lean_uint64_dec_lt(v_baseIdleMs_362_, v_providerFloorMs_363_);
if (v___x_399_ == 0)
{
v___y_394_ = v_baseIdleMs_362_;
goto v___jp_393_;
}
else
{
v___y_394_ = v_providerFloorMs_363_;
goto v___jp_393_;
}
v___jp_367_:
{
uint32_t v___x_371_; uint32_t v___x_372_;
v___x_371_ = lean_uint32_lor(v___y_368_, v___y_369_);
v___x_372_ = lean_uint32_lor(v___x_371_, v___y_370_);
return v___x_372_;
}
v___jp_373_:
{
uint32_t v___x_376_;
v___x_376_ = 0;
v___y_368_ = v___y_374_;
v___y_369_ = v___y_375_;
v___y_370_ = v___x_376_;
goto v___jp_367_;
}
v___jp_377_:
{
uint8_t v___x_380_; uint8_t v___x_381_;
v___x_380_ = 1;
v___x_381_ = lean_uint8_dec_eq(v_hasMissionHeader_365_, v___x_380_);
if (v___x_381_ == 0)
{
v___y_374_ = v___y_378_;
v___y_375_ = v___y_379_;
goto v___jp_373_;
}
else
{
uint8_t v___x_382_;
v___x_382_ = lean_uint8_dec_eq(v_authVerified_366_, v___x_380_);
if (v___x_382_ == 0)
{
v___y_374_ = v___y_378_;
v___y_375_ = v___y_379_;
goto v___jp_373_;
}
else
{
uint32_t v___x_383_;
v___x_383_ = 65536;
v___y_368_ = v___y_378_;
v___y_369_ = v___y_379_;
v___y_370_ = v___x_383_;
goto v___jp_367_;
}
}
}
v___jp_384_:
{
uint8_t v___x_387_;
v___x_387_ = lean_uint64_dec_le(v___y_385_, v_upstreamElapsedMs_361_);
if (v___x_387_ == 0)
{
uint32_t v___x_388_;
v___x_388_ = 0;
v___y_378_ = v___y_386_;
v___y_379_ = v___x_388_;
goto v___jp_377_;
}
else
{
uint32_t v___x_389_;
v___x_389_ = 256;
v___y_378_ = v___y_386_;
v___y_379_ = v___x_389_;
goto v___jp_377_;
}
}
v___jp_390_:
{
uint32_t v___x_392_;
v___x_392_ = 0;
v___y_385_ = v___y_391_;
v___y_386_ = v___x_392_;
goto v___jp_384_;
}
v___jp_393_:
{
uint8_t v___x_395_;
v___x_395_ = lean_uint64_dec_le(v_keepaliveMs_360_, v_clientElapsedMs_359_);
if (v___x_395_ == 0)
{
v___y_391_ = v___y_394_;
goto v___jp_390_;
}
else
{
uint8_t v___x_396_; uint8_t v___x_397_;
v___x_396_ = 1;
v___x_397_ = lean_uint8_dec_eq(v_atEventBoundary_364_, v___x_396_);
if (v___x_397_ == 0)
{
v___y_391_ = v___y_394_;
goto v___jp_390_;
}
else
{
uint32_t v___x_398_;
v___x_398_ = 1;
v___y_385_ = v___y_394_;
v___y_386_ = v___x_398_;
goto v___jp_384_;
}
}
}
}
}

LEAN_EXPORT uint32_t orb_breaker_step(uint8_t v_reason_418_, uint32_t v_transientStreak_419_, uint32_t v_transientThreshold_420_){
_start:
{
uint32_t v___y_422_; uint8_t v___x_427_; uint8_t v___x_428_;
v___x_427_ = 0;
v___x_428_ = lean_uint8_dec_eq(v_reason_418_, v___x_427_);
if (v___x_428_ == 0)
{
uint8_t v___x_429_; uint8_t v___x_430_;
v___x_429_ = 4;
v___x_430_ = lean_uint8_dec_eq(v_reason_418_, v___x_429_);
if (v___x_430_ == 0)
{
uint8_t v___x_431_; uint8_t v___x_432_;
v___x_431_ = 2;
v___x_432_ = lean_uint8_dec_eq(v_reason_418_, v___x_431_);
if (v___x_432_ == 0)
{
uint8_t v___x_436_; uint8_t v___x_437_;
v___x_436_ = 3;
v___x_437_ = lean_uint8_dec_eq(v_reason_418_, v___x_436_);
if (v___x_437_ == 0)
{
uint8_t v___x_438_; uint8_t v___x_439_;
v___x_438_ = 1;
v___x_439_ = lean_uint8_dec_eq(v_reason_418_, v___x_438_);
if (v___x_439_ == 0)
{
uint32_t v___x_440_;
v___x_440_ = 65536;
return v___x_440_;
}
else
{
uint32_t v___x_441_;
v___x_441_ = 65792;
return v___x_441_;
}
}
else
{
goto v___jp_433_;
}
}
else
{
goto v___jp_433_;
}
v___jp_433_:
{
if (v___x_432_ == 0)
{
uint32_t v___x_434_;
v___x_434_ = 0;
v___y_422_ = v___x_434_;
goto v___jp_421_;
}
else
{
uint32_t v___x_435_;
v___x_435_ = 256;
v___y_422_ = v___x_435_;
goto v___jp_421_;
}
}
}
else
{
uint8_t v___x_442_;
v___x_442_ = lean_uint32_dec_le(v_transientThreshold_420_, v_transientStreak_419_);
if (v___x_442_ == 0)
{
uint32_t v___x_443_;
v___x_443_ = 0;
return v___x_443_;
}
else
{
uint32_t v___x_444_; uint8_t v___x_445_;
v___x_444_ = 1;
v___x_445_ = lean_uint32_dec_le(v___x_444_, v_transientThreshold_420_);
if (v___x_445_ == 0)
{
uint32_t v___x_446_;
v___x_446_ = 0;
return v___x_446_;
}
else
{
uint32_t v___x_447_;
v___x_447_ = 65536;
return v___x_447_;
}
}
}
}
else
{
uint32_t v___x_448_;
v___x_448_ = 0;
return v___x_448_;
}
v___jp_421_:
{
uint32_t v___x_423_; uint32_t v___x_424_; uint32_t v___x_425_; uint32_t v___x_426_;
v___x_423_ = 1;
v___x_424_ = lean_uint32_lor(v___x_423_, v___y_422_);
v___x_425_ = 65536;
v___x_426_ = lean_uint32_lor(v___x_424_, v___x_425_);
return v___x_426_;
}
}
}

LEAN_EXPORT uint8_t orb_mission_step(uint8_t v_armed_457_, uint8_t v_signal_458_, uint8_t v_continuationPending_459_, uint8_t v_wakeupArmed_460_, uint8_t v_madeProgress_461_, uint32_t v_priorNoProgress_462_, uint32_t v_maxNoProgress_463_, uint32_t v_priorContinuations_464_, uint32_t v_maxContinuations_465_, uint32_t v_hasMaxCont_466_){
_start:
{
uint8_t v___x_467_; uint8_t v___x_468_;
v___x_467_ = 0;
v___x_468_ = lean_uint8_dec_eq(v_armed_457_, v___x_467_);
if (v___x_468_ == 0)
{
uint8_t v___x_469_; uint8_t v___x_470_;
v___x_469_ = 1;
v___x_470_ = lean_uint8_dec_eq(v_signal_458_, v___x_469_);
if (v___x_470_ == 0)
{
uint8_t v___x_471_; uint8_t v___x_472_;
v___x_471_ = 2;
v___x_472_ = lean_uint8_dec_eq(v_signal_458_, v___x_471_);
if (v___x_472_ == 0)
{
uint8_t v___x_473_;
v___x_473_ = lean_uint8_dec_eq(v_continuationPending_459_, v___x_469_);
if (v___x_473_ == 0)
{
uint8_t v___x_474_;
v___x_474_ = lean_uint8_dec_eq(v_wakeupArmed_460_, v___x_469_);
if (v___x_474_ == 0)
{
uint32_t v___x_475_; uint32_t v___y_477_; uint32_t v___y_478_; uint32_t v___y_488_; uint8_t v___x_492_;
v___x_475_ = 1;
v___x_492_ = lean_uint32_dec_le(v___x_475_, v_maxNoProgress_463_);
if (v___x_492_ == 0)
{
v___y_488_ = v___x_475_;
goto v___jp_487_;
}
else
{
v___y_488_ = v_maxNoProgress_463_;
goto v___jp_487_;
}
v___jp_476_:
{
uint8_t v___x_479_;
v___x_479_ = lean_uint32_dec_le(v___y_477_, v___y_478_);
if (v___x_479_ == 0)
{
uint8_t v___x_480_;
v___x_480_ = lean_uint32_dec_eq(v_hasMaxCont_466_, v___x_475_);
if (v___x_480_ == 0)
{
uint8_t v___x_481_;
v___x_481_ = 7;
return v___x_481_;
}
else
{
uint32_t v___x_482_; uint8_t v___x_483_;
v___x_482_ = lean_uint32_add(v_priorContinuations_464_, v___x_475_);
v___x_483_ = lean_uint32_dec_lt(v_maxContinuations_465_, v___x_482_);
if (v___x_483_ == 0)
{
uint8_t v___x_484_;
v___x_484_ = 7;
return v___x_484_;
}
else
{
uint8_t v___x_485_;
v___x_485_ = 6;
return v___x_485_;
}
}
}
else
{
uint8_t v___x_486_;
v___x_486_ = 5;
return v___x_486_;
}
}
v___jp_487_:
{
uint8_t v___x_489_;
v___x_489_ = lean_uint8_dec_eq(v_madeProgress_461_, v___x_469_);
if (v___x_489_ == 0)
{
uint32_t v___x_490_;
v___x_490_ = lean_uint32_add(v_priorNoProgress_462_, v___x_475_);
v___y_477_ = v___y_488_;
v___y_478_ = v___x_490_;
goto v___jp_476_;
}
else
{
uint32_t v___x_491_;
v___x_491_ = 0;
v___y_477_ = v___y_488_;
v___y_478_ = v___x_491_;
goto v___jp_476_;
}
}
}
else
{
uint8_t v___x_493_;
v___x_493_ = 4;
return v___x_493_;
}
}
else
{
uint8_t v___x_494_;
v___x_494_ = 3;
return v___x_494_;
}
}
else
{
return v___x_471_;
}
}
else
{
return v___x_469_;
}
}
else
{
return v___x_467_;
}
}
}

LEAN_EXPORT uint8_t orb_reconcile_step(uint8_t v_status_517_, uint8_t v_isClientPlaced_518_, uint8_t v_sameBootId_519_, uint8_t v_isAssistantMode_520_, uint8_t v_runningInActor_521_, uint8_t v_hasLiveScope_522_, uint8_t v_hasDurableRun_523_, uint8_t v_recentlyUpdated_524_, uint8_t v_hasEvents_525_, uint8_t v_alreadyOrphaned_526_, uint8_t v_isServiceRestart_527_, uint8_t v_withinHorizon_528_, uint8_t v_liveRetryExists_529_){
_start:
{
uint8_t v___x_530_; uint8_t v___x_531_;
v___x_530_ = 1;
v___x_531_ = lean_uint8_dec_eq(v_isClientPlaced_518_, v___x_530_);
if (v___x_531_ == 0)
{
uint8_t v___x_532_;
v___x_532_ = lean_uint8_dec_eq(v_sameBootId_519_, v___x_530_);
if (v___x_532_ == 0)
{
uint8_t v___x_533_;
v___x_533_ = lean_uint8_dec_eq(v_runningInActor_521_, v___x_530_);
if (v___x_533_ == 0)
{
uint8_t v___x_534_;
v___x_534_ = lean_uint8_dec_eq(v_hasLiveScope_522_, v___x_530_);
if (v___x_534_ == 0)
{
uint8_t v___x_535_;
v___x_535_ = lean_uint8_dec_eq(v_hasDurableRun_523_, v___x_530_);
if (v___x_535_ == 0)
{
uint8_t v___x_536_; uint8_t v___x_537_;
v___x_536_ = 0;
v___x_537_ = lean_uint8_dec_eq(v_status_517_, v___x_536_);
if (v___x_537_ == 0)
{
uint8_t v___x_538_;
v___x_538_ = lean_uint8_dec_eq(v_status_517_, v___x_530_);
if (v___x_538_ == 0)
{
uint8_t v___x_539_; uint8_t v___x_540_;
v___x_539_ = 2;
v___x_540_ = lean_uint8_dec_eq(v_status_517_, v___x_539_);
if (v___x_540_ == 0)
{
return v___x_536_;
}
else
{
uint8_t v___x_541_;
v___x_541_ = lean_uint8_dec_eq(v_isServiceRestart_527_, v___x_530_);
if (v___x_541_ == 0)
{
return v___x_536_;
}
else
{
uint8_t v___x_542_;
v___x_542_ = lean_uint8_dec_eq(v_withinHorizon_528_, v___x_530_);
if (v___x_542_ == 0)
{
return v___x_536_;
}
else
{
uint8_t v___x_543_;
v___x_543_ = lean_uint8_dec_eq(v_liveRetryExists_529_, v___x_536_);
if (v___x_543_ == 0)
{
return v___x_536_;
}
else
{
uint8_t v___x_544_;
v___x_544_ = 3;
return v___x_544_;
}
}
}
}
}
else
{
uint8_t v___x_545_;
v___x_545_ = lean_uint8_dec_eq(v_hasEvents_525_, v___x_536_);
if (v___x_545_ == 0)
{
return v___x_536_;
}
else
{
uint8_t v___x_546_;
v___x_546_ = lean_uint8_dec_eq(v_alreadyOrphaned_526_, v___x_536_);
if (v___x_546_ == 0)
{
return v___x_536_;
}
else
{
uint8_t v___x_547_;
v___x_547_ = 2;
return v___x_547_;
}
}
}
}
else
{
uint8_t v___x_548_;
v___x_548_ = lean_uint8_dec_eq(v_isAssistantMode_520_, v___x_536_);
if (v___x_548_ == 0)
{
return v___x_536_;
}
else
{
uint8_t v___x_549_;
v___x_549_ = lean_uint8_dec_eq(v_recentlyUpdated_524_, v___x_536_);
if (v___x_549_ == 0)
{
return v___x_536_;
}
else
{
return v___x_530_;
}
}
}
}
else
{
uint8_t v___x_550_;
v___x_550_ = 0;
return v___x_550_;
}
}
else
{
uint8_t v___x_551_;
v___x_551_ = 0;
return v___x_551_;
}
}
else
{
uint8_t v___x_552_;
v___x_552_ = 0;
return v___x_552_;
}
}
else
{
uint8_t v___x_553_;
v___x_553_ = 0;
return v___x_553_;
}
}
else
{
uint8_t v___x_554_;
v___x_554_ = 0;
return v___x_554_;
}
}
}

LEAN_EXPORT uint32_t orb_queue_step(uint8_t v_deliveryOutcome_583_, uint8_t v_durablyStarted_584_){
_start:
{
uint8_t v___x_590_; uint8_t v___x_591_;
v___x_590_ = 0;
v___x_591_ = lean_uint8_dec_eq(v_deliveryOutcome_583_, v___x_590_);
if (v___x_591_ == 0)
{
goto v___jp_585_;
}
else
{
uint8_t v___x_592_; uint8_t v___x_593_;
v___x_592_ = 1;
v___x_593_ = lean_uint8_dec_eq(v_durablyStarted_584_, v___x_592_);
if (v___x_593_ == 0)
{
goto v___jp_585_;
}
else
{
uint32_t v___x_594_;
v___x_594_ = 256;
return v___x_594_;
}
}
v___jp_585_:
{
uint8_t v___x_586_; uint8_t v___x_587_;
v___x_586_ = 2;
v___x_587_ = lean_uint8_dec_eq(v_deliveryOutcome_583_, v___x_586_);
if (v___x_587_ == 0)
{
uint32_t v___x_588_;
v___x_588_ = 1;
return v___x_588_;
}
else
{
uint32_t v___x_589_;
v___x_589_ = 65537;
return v___x_589_;
}
}
}
}

LEAN_EXPORT uint8_t orb_vm_step(uint8_t v_op_601_, uint8_t v_sizeRank_602_, uint8_t v_maxSizeRank_603_, uint8_t v_secretProjected_604_, uint8_t v_ttlExpired_605_, uint8_t v_busy_606_, uint8_t v_ownerEnded_607_, uint8_t v_idleExpired_608_, uint32_t v_activeCount_609_, uint32_t v_maxConcurrent_610_, uint32_t v_ttlMinutes_611_, uint32_t v_maxTtlMinutes_612_, uint32_t v_jobMemPct_613_, uint64_t v_spentPlusNewCents_614_, uint64_t v_dailyCapCents_615_){
_start:
{
uint8_t v___x_616_; uint8_t v___x_617_;
v___x_616_ = 0;
v___x_617_ = lean_uint8_dec_eq(v_op_601_, v___x_616_);
if (v___x_617_ == 0)
{
uint8_t v___x_618_; uint8_t v___x_619_;
v___x_618_ = 1;
v___x_619_ = lean_uint8_dec_eq(v_ttlExpired_605_, v___x_618_);
if (v___x_619_ == 0)
{
uint8_t v___x_620_;
v___x_620_ = lean_uint8_dec_eq(v_busy_606_, v___x_616_);
if (v___x_620_ == 0)
{
return v___x_616_;
}
else
{
uint8_t v___x_621_;
v___x_621_ = lean_uint8_dec_eq(v_ownerEnded_607_, v___x_618_);
if (v___x_621_ == 0)
{
uint8_t v___x_622_;
v___x_622_ = lean_uint8_dec_eq(v_idleExpired_608_, v___x_618_);
if (v___x_622_ == 0)
{
return v___x_616_;
}
else
{
return v___x_618_;
}
}
else
{
return v___x_618_;
}
}
}
else
{
return v___x_618_;
}
}
else
{
uint8_t v___x_623_;
v___x_623_ = lean_uint8_dec_le(v_sizeRank_602_, v_maxSizeRank_603_);
if (v___x_623_ == 0)
{
return v___x_616_;
}
else
{
uint8_t v___x_624_;
v___x_624_ = lean_uint32_dec_lt(v_activeCount_609_, v_maxConcurrent_610_);
if (v___x_624_ == 0)
{
return v___x_616_;
}
else
{
uint8_t v___x_625_;
v___x_625_ = lean_uint64_dec_le(v_spentPlusNewCents_614_, v_dailyCapCents_615_);
if (v___x_625_ == 0)
{
return v___x_616_;
}
else
{
uint32_t v___x_626_; uint8_t v___x_627_;
v___x_626_ = 5;
v___x_627_ = lean_uint32_dec_le(v___x_626_, v_ttlMinutes_611_);
if (v___x_627_ == 0)
{
return v___x_616_;
}
else
{
uint8_t v___x_628_;
v___x_628_ = lean_uint32_dec_le(v_ttlMinutes_611_, v_maxTtlMinutes_612_);
if (v___x_628_ == 0)
{
return v___x_616_;
}
else
{
uint32_t v___x_629_; uint8_t v___x_630_;
v___x_629_ = 90;
v___x_630_ = lean_uint32_dec_le(v_jobMemPct_613_, v___x_629_);
if (v___x_630_ == 0)
{
return v___x_616_;
}
else
{
uint8_t v___x_631_;
v___x_631_ = lean_uint8_dec_eq(v_secretProjected_604_, v___x_616_);
if (v___x_631_ == 0)
{
return v___x_616_;
}
else
{
uint8_t v___x_632_;
v___x_632_ = 1;
return v___x_632_;
}
}
}
}
}
}
}
}
}
}

LEAN_EXPORT uint32_t lp_orb_x2dspec_Orb_Kernel_accessStep___redArg(uint8_t v_sameOwner_665_, uint8_t v_isSelfOrChild_666_, uint8_t v_isReadTool_667_, uint8_t v_grantApproved_668_, uint8_t v_grantUnexpired_669_){
_start:
{
uint32_t v___y_671_; uint8_t v___x_674_; uint8_t v___x_675_;
v___x_674_ = 1;
v___x_675_ = lean_uint8_dec_eq(v_sameOwner_665_, v___x_674_);
if (v___x_675_ == 0)
{
goto v___jp_676_;
}
else
{
uint8_t v___x_685_;
v___x_685_ = lean_uint8_dec_eq(v_isSelfOrChild_666_, v___x_674_);
if (v___x_685_ == 0)
{
goto v___jp_676_;
}
else
{
uint32_t v___x_686_;
v___x_686_ = 65793;
return v___x_686_;
}
}
v___jp_670_:
{
uint32_t v___x_672_; uint32_t v___x_673_;
v___x_672_ = 256;
v___x_673_ = lean_uint32_lor(v___y_671_, v___x_672_);
return v___x_673_;
}
v___jp_676_:
{
if (v___x_675_ == 0)
{
uint32_t v___x_677_;
v___x_677_ = 0;
return v___x_677_;
}
else
{
uint8_t v___x_678_;
v___x_678_ = lean_uint8_dec_eq(v_grantApproved_668_, v___x_674_);
if (v___x_678_ == 0)
{
uint32_t v___x_679_;
v___x_679_ = 0;
return v___x_679_;
}
else
{
uint8_t v___x_680_;
v___x_680_ = lean_uint8_dec_eq(v_grantUnexpired_669_, v___x_674_);
if (v___x_680_ == 0)
{
uint32_t v___x_681_;
v___x_681_ = 0;
return v___x_681_;
}
else
{
uint8_t v___x_682_;
v___x_682_ = lean_uint8_dec_eq(v_isReadTool_667_, v___x_674_);
if (v___x_682_ == 0)
{
uint32_t v___x_683_;
v___x_683_ = 0;
v___y_671_ = v___x_683_;
goto v___jp_670_;
}
else
{
uint32_t v___x_684_;
v___x_684_ = 1;
v___y_671_ = v___x_684_;
goto v___jp_670_;
}
}
}
}
}
}
}

LEAN_EXPORT uint32_t orb_access_step(uint8_t v_sameOwner_699_, uint8_t v_isSelfOrChild_700_, uint8_t v_isReadTool_701_, uint8_t v_grantApproved_702_, uint8_t v_grantUnexpired_703_, uint8_t v___targetExists_704_){
_start:
{
uint32_t v___y_706_; uint8_t v___x_709_; uint8_t v___x_710_;
v___x_709_ = 1;
v___x_710_ = lean_uint8_dec_eq(v_sameOwner_699_, v___x_709_);
if (v___x_710_ == 0)
{
goto v___jp_711_;
}
else
{
uint8_t v___x_720_;
v___x_720_ = lean_uint8_dec_eq(v_isSelfOrChild_700_, v___x_709_);
if (v___x_720_ == 0)
{
goto v___jp_711_;
}
else
{
uint32_t v___x_721_;
v___x_721_ = 65793;
return v___x_721_;
}
}
v___jp_705_:
{
uint32_t v___x_707_; uint32_t v___x_708_;
v___x_707_ = 256;
v___x_708_ = lean_uint32_lor(v___y_706_, v___x_707_);
return v___x_708_;
}
v___jp_711_:
{
if (v___x_710_ == 0)
{
uint32_t v___x_712_;
v___x_712_ = 0;
return v___x_712_;
}
else
{
uint8_t v___x_713_;
v___x_713_ = lean_uint8_dec_eq(v_grantApproved_702_, v___x_709_);
if (v___x_713_ == 0)
{
uint32_t v___x_714_;
v___x_714_ = 0;
return v___x_714_;
}
else
{
uint8_t v___x_715_;
v___x_715_ = lean_uint8_dec_eq(v_grantUnexpired_703_, v___x_709_);
if (v___x_715_ == 0)
{
uint32_t v___x_716_;
v___x_716_ = 0;
return v___x_716_;
}
else
{
uint8_t v___x_717_;
v___x_717_ = lean_uint8_dec_eq(v_isReadTool_701_, v___x_709_);
if (v___x_717_ == 0)
{
uint32_t v___x_718_;
v___x_718_ = 0;
v___y_706_ = v___x_718_;
goto v___jp_705_;
}
else
{
uint32_t v___x_719_;
v___x_719_ = 1;
v___y_706_ = v___x_719_;
goto v___jp_705_;
}
}
}
}
}
}
}

LEAN_EXPORT uint32_t orb_workfold_step(uint8_t v_itemKind_736_, uint8_t v_isCumulative_737_, uint8_t v_isNonEmpty_738_, uint8_t v_toolAhead_739_, uint8_t v_nextIsTool_740_, uint8_t v_foldHasTool_741_){
_start:
{
uint8_t v___x_742_; uint8_t v___x_743_;
v___x_742_ = 3;
v___x_743_ = lean_uint8_dec_eq(v_itemKind_736_, v___x_742_);
if (v___x_743_ == 0)
{
uint8_t v___x_744_; uint8_t v___x_749_;
v___x_744_ = 1;
v___x_749_ = lean_uint8_dec_eq(v_itemKind_736_, v___x_744_);
if (v___x_749_ == 0)
{
uint8_t v___x_750_; uint8_t v___x_751_;
v___x_750_ = 2;
v___x_751_ = lean_uint8_dec_eq(v_itemKind_736_, v___x_750_);
if (v___x_751_ == 0)
{
uint32_t v___x_752_;
v___x_752_ = 0;
return v___x_752_;
}
else
{
uint8_t v___x_753_; uint8_t v___x_754_;
v___x_753_ = 0;
v___x_754_ = lean_uint8_dec_eq(v_isCumulative_737_, v___x_753_);
if (v___x_754_ == 0)
{
uint32_t v___x_755_;
v___x_755_ = 0;
return v___x_755_;
}
else
{
uint8_t v___x_756_;
v___x_756_ = lean_uint8_dec_eq(v_isNonEmpty_738_, v___x_744_);
if (v___x_756_ == 0)
{
uint32_t v___x_757_;
v___x_757_ = 0;
return v___x_757_;
}
else
{
uint8_t v___x_758_;
v___x_758_ = lean_uint8_dec_eq(v_toolAhead_739_, v___x_744_);
if (v___x_758_ == 0)
{
uint32_t v___x_759_;
v___x_759_ = 0;
return v___x_759_;
}
else
{
uint8_t v___x_760_;
v___x_760_ = lean_uint8_dec_eq(v_foldHasTool_741_, v___x_744_);
if (v___x_760_ == 0)
{
uint8_t v___x_761_;
v___x_761_ = lean_uint8_dec_eq(v_nextIsTool_740_, v___x_744_);
if (v___x_761_ == 0)
{
uint32_t v___x_762_;
v___x_762_ = 0;
return v___x_762_;
}
else
{
goto v___jp_745_;
}
}
else
{
goto v___jp_745_;
}
}
}
}
}
}
else
{
uint8_t v___x_763_;
v___x_763_ = lean_uint8_dec_eq(v_foldHasTool_741_, v___x_744_);
if (v___x_763_ == 0)
{
uint32_t v___x_764_;
v___x_764_ = 1;
return v___x_764_;
}
else
{
uint32_t v___x_765_;
v___x_765_ = 257;
return v___x_765_;
}
}
v___jp_745_:
{
uint8_t v___x_746_;
v___x_746_ = lean_uint8_dec_eq(v_foldHasTool_741_, v___x_744_);
if (v___x_746_ == 0)
{
uint32_t v___x_747_;
v___x_747_ = 1;
return v___x_747_;
}
else
{
uint32_t v___x_748_;
v___x_748_ = 257;
return v___x_748_;
}
}
}
else
{
uint32_t v___x_766_;
v___x_766_ = 257;
return v___x_766_;
}
}
}

LEAN_EXPORT uint8_t orb_taskcard_step(uint8_t v_turnEnded_781_, uint8_t v_allClosed_782_, uint8_t v_turnOutcomeFinished_783_){
_start:
{
uint8_t v___x_784_; uint8_t v___x_785_;
v___x_784_ = 0;
v___x_785_ = lean_uint8_dec_eq(v_turnEnded_781_, v___x_784_);
if (v___x_785_ == 0)
{
uint8_t v___x_786_; uint8_t v___x_787_;
v___x_786_ = 1;
v___x_787_ = lean_uint8_dec_eq(v_allClosed_782_, v___x_786_);
if (v___x_787_ == 0)
{
uint8_t v___x_788_;
v___x_788_ = lean_uint8_dec_eq(v_turnOutcomeFinished_783_, v___x_786_);
if (v___x_788_ == 0)
{
uint8_t v___x_789_;
v___x_789_ = 3;
return v___x_789_;
}
else
{
uint8_t v___x_790_;
v___x_790_ = 2;
return v___x_790_;
}
}
else
{
return v___x_786_;
}
}
else
{
return v___x_784_;
}
}
}

LEAN_EXPORT uint32_t orb_sidebar_visibility(uint8_t v_matchesFilter_799_, uint8_t v_hasVisibleDescendant_800_, uint8_t v_isAcknowledged_801_, uint8_t v_hasParent_802_, uint8_t v_isFork_803_, uint8_t v_parentReachesSelf_804_){
_start:
{
uint32_t v___y_806_; uint32_t v___y_807_; uint32_t v___y_808_; uint32_t v___y_812_; uint32_t v___y_813_; uint8_t v___x_815_; uint32_t v___y_817_; uint32_t v___y_818_; uint32_t v___y_825_; uint32_t v___y_828_; uint8_t v___x_835_;
v___x_815_ = 1;
v___x_835_ = lean_uint8_dec_eq(v_matchesFilter_799_, v___x_815_);
if (v___x_835_ == 0)
{
uint8_t v___x_836_;
v___x_836_ = lean_uint8_dec_eq(v_hasVisibleDescendant_800_, v___x_815_);
if (v___x_836_ == 0)
{
uint32_t v___x_837_;
v___x_837_ = 0;
v___y_828_ = v___x_837_;
goto v___jp_827_;
}
else
{
goto v___jp_833_;
}
}
else
{
goto v___jp_833_;
}
v___jp_805_:
{
uint32_t v___x_809_; uint32_t v___x_810_;
v___x_809_ = lean_uint32_lor(v___y_806_, v___y_807_);
v___x_810_ = lean_uint32_lor(v___x_809_, v___y_808_);
return v___x_810_;
}
v___jp_811_:
{
uint32_t v___x_814_;
v___x_814_ = 0;
v___y_806_ = v___y_812_;
v___y_807_ = v___y_813_;
v___y_808_ = v___x_814_;
goto v___jp_805_;
}
v___jp_816_:
{
uint8_t v___x_819_;
v___x_819_ = lean_uint8_dec_eq(v_hasParent_802_, v___x_815_);
if (v___x_819_ == 0)
{
v___y_812_ = v___y_817_;
v___y_813_ = v___y_818_;
goto v___jp_811_;
}
else
{
uint8_t v___x_820_; uint8_t v___x_821_;
v___x_820_ = 0;
v___x_821_ = lean_uint8_dec_eq(v_isFork_803_, v___x_820_);
if (v___x_821_ == 0)
{
v___y_812_ = v___y_817_;
v___y_813_ = v___y_818_;
goto v___jp_811_;
}
else
{
uint8_t v___x_822_;
v___x_822_ = lean_uint8_dec_eq(v_parentReachesSelf_804_, v___x_820_);
if (v___x_822_ == 0)
{
v___y_812_ = v___y_817_;
v___y_813_ = v___y_818_;
goto v___jp_811_;
}
else
{
uint32_t v___x_823_;
v___x_823_ = 65536;
v___y_806_ = v___y_817_;
v___y_807_ = v___y_818_;
v___y_808_ = v___x_823_;
goto v___jp_805_;
}
}
}
}
v___jp_824_:
{
uint32_t v___x_826_;
v___x_826_ = 0;
v___y_817_ = v___y_825_;
v___y_818_ = v___x_826_;
goto v___jp_816_;
}
v___jp_827_:
{
uint8_t v___x_829_;
v___x_829_ = lean_uint8_dec_eq(v_isAcknowledged_801_, v___x_815_);
if (v___x_829_ == 0)
{
v___y_825_ = v___y_828_;
goto v___jp_824_;
}
else
{
uint32_t v___x_830_; uint8_t v___x_831_;
v___x_830_ = 0;
v___x_831_ = lean_uint32_dec_eq(v___y_828_, v___x_830_);
if (v___x_831_ == 0)
{
v___y_825_ = v___y_828_;
goto v___jp_824_;
}
else
{
uint32_t v___x_832_;
v___x_832_ = 256;
v___y_817_ = v___y_828_;
v___y_818_ = v___x_832_;
goto v___jp_816_;
}
}
}
v___jp_833_:
{
uint32_t v___x_834_;
v___x_834_ = 1;
v___y_828_ = v___x_834_;
goto v___jp_827_;
}
}
}

LEAN_EXPORT uint32_t orb_admission_step(uint8_t v_recoveryPhase_852_, uint8_t v_isQuiescent_853_, uint8_t v_reservedTagForged_854_, uint64_t v_emergencyPlusCandBytes_855_, uint64_t v_freeDiskBytes_856_){
_start:
{
uint8_t v___x_857_; uint8_t v___x_858_;
v___x_857_ = 1;
v___x_858_ = lean_uint8_dec_eq(v_recoveryPhase_852_, v___x_857_);
if (v___x_858_ == 0)
{
uint8_t v___x_859_; uint8_t v___x_860_;
v___x_859_ = 2;
v___x_860_ = lean_uint8_dec_eq(v_recoveryPhase_852_, v___x_859_);
if (v___x_860_ == 0)
{
uint8_t v___x_861_;
v___x_861_ = lean_uint8_dec_eq(v_isQuiescent_853_, v___x_857_);
if (v___x_861_ == 0)
{
uint32_t v___x_862_;
v___x_862_ = 0;
return v___x_862_;
}
else
{
uint8_t v___x_863_; uint8_t v___x_864_;
v___x_863_ = 0;
v___x_864_ = lean_uint8_dec_eq(v_reservedTagForged_854_, v___x_863_);
if (v___x_864_ == 0)
{
uint32_t v___x_865_;
v___x_865_ = 0;
return v___x_865_;
}
else
{
uint8_t v___x_866_;
v___x_866_ = lean_uint64_dec_le(v_emergencyPlusCandBytes_855_, v_freeDiskBytes_856_);
if (v___x_866_ == 0)
{
uint32_t v___x_867_;
v___x_867_ = 0;
return v___x_867_;
}
else
{
uint32_t v___x_868_;
v___x_868_ = 1;
return v___x_868_;
}
}
}
}
else
{
uint32_t v___x_869_;
v___x_869_ = 65536;
return v___x_869_;
}
}
else
{
uint32_t v___x_870_;
v___x_870_ = 256;
return v___x_870_;
}
}
}

LEAN_EXPORT uint64_t orb_account_cooldown_secs(uint64_t v_baseSecs_883_, uint64_t v_maxSecs_884_, uint32_t v_consecutive_885_){
_start:
{
uint64_t v___x_886_; uint64_t v___y_888_; uint64_t v___y_889_; uint32_t v___y_890_; uint64_t v___y_897_; uint64_t v___y_898_; uint32_t v___y_899_; uint64_t v___y_903_; uint64_t v___y_904_; uint64_t v___y_910_; uint8_t v___x_912_;
v___x_886_ = 1ULL;
v___x_912_ = lean_uint64_dec_le(v___x_886_, v_baseSecs_883_);
if (v___x_912_ == 0)
{
uint64_t v___x_913_;
v___x_913_ = 600ULL;
v___y_910_ = v___x_913_;
goto v___jp_909_;
}
else
{
v___y_910_ = v_baseSecs_883_;
goto v___jp_909_;
}
v___jp_887_:
{
uint64_t v_exp_891_; uint64_t v_factor_892_; uint64_t v___x_893_; uint8_t v___x_894_;
v_exp_891_ = lean_uint32_to_uint64(v___y_890_);
v_factor_892_ = lean_uint64_shift_left(v___x_886_, v_exp_891_);
v___x_893_ = lean_uint64_div(v___y_889_, v_factor_892_);
v___x_894_ = lean_uint64_dec_lt(v___x_893_, v___y_888_);
if (v___x_894_ == 0)
{
uint64_t v___x_895_;
v___x_895_ = lean_uint64_mul(v___y_888_, v_factor_892_);
return v___x_895_;
}
else
{
return v___y_889_;
}
}
v___jp_896_:
{
uint32_t v___x_900_; uint8_t v___x_901_;
v___x_900_ = 20;
v___x_901_ = lean_uint32_dec_lt(v___x_900_, v___y_899_);
if (v___x_901_ == 0)
{
v___y_888_ = v___y_897_;
v___y_889_ = v___y_898_;
v___y_890_ = v___y_899_;
goto v___jp_887_;
}
else
{
v___y_888_ = v___y_897_;
v___y_889_ = v___y_898_;
v___y_890_ = v___x_900_;
goto v___jp_887_;
}
}
v___jp_902_:
{
uint32_t v___x_905_; uint8_t v___x_906_;
v___x_905_ = 1;
v___x_906_ = lean_uint32_dec_lt(v___x_905_, v_consecutive_885_);
if (v___x_906_ == 0)
{
uint32_t v___x_907_;
v___x_907_ = 0;
v___y_897_ = v___y_903_;
v___y_898_ = v___y_904_;
v___y_899_ = v___x_907_;
goto v___jp_896_;
}
else
{
uint32_t v___x_908_;
v___x_908_ = lean_uint32_sub(v_consecutive_885_, v___x_905_);
v___y_897_ = v___y_903_;
v___y_898_ = v___y_904_;
v___y_899_ = v___x_908_;
goto v___jp_896_;
}
}
v___jp_909_:
{
uint8_t v___x_911_;
v___x_911_ = lean_uint64_dec_lt(v___y_910_, v_maxSecs_884_);
if (v___x_911_ == 0)
{
v___y_903_ = v___y_910_;
v___y_904_ = v___y_910_;
goto v___jp_902_;
}
else
{
v___y_903_ = v___y_910_;
v___y_904_ = v_maxSecs_884_;
goto v___jp_902_;
}
}
}
}

LEAN_EXPORT uint64_t orb_cost_cents_step(uint64_t v_inputTokens_922_, uint64_t v_outputTokens_923_, uint64_t v_cacheCreateTokens_924_, uint64_t v_cacheReadTokens_925_, uint64_t v_inputNano_926_, uint64_t v_outputNano_927_, uint64_t v_cacheCreateNano_928_, uint64_t v_cacheReadNano_929_){
_start:
{
uint64_t v___y_931_; uint8_t v___x_943_;
v___x_943_ = lean_uint64_dec_le(v_cacheCreateTokens_924_, v_inputTokens_922_);
if (v___x_943_ == 0)
{
uint64_t v___x_944_;
v___x_944_ = 0ULL;
v___y_931_ = v___x_944_;
goto v___jp_930_;
}
else
{
uint64_t v___x_945_;
v___x_945_ = lean_uint64_sub(v_inputTokens_922_, v_cacheCreateTokens_924_);
v___y_931_ = v___x_945_;
goto v___jp_930_;
}
v___jp_930_:
{
uint64_t v___x_932_; uint64_t v___x_933_; uint64_t v___x_934_; uint64_t v___x_935_; uint64_t v___x_936_; uint64_t v___x_937_; uint64_t v_totalNano_938_; uint64_t v___x_939_; uint64_t v___x_940_; uint64_t v___x_941_; uint64_t v___x_942_;
v___x_932_ = lean_uint64_mul(v___y_931_, v_inputNano_926_);
v___x_933_ = lean_uint64_mul(v_outputTokens_923_, v_outputNano_927_);
v___x_934_ = lean_uint64_add(v___x_932_, v___x_933_);
v___x_935_ = lean_uint64_mul(v_cacheCreateTokens_924_, v_cacheCreateNano_928_);
v___x_936_ = lean_uint64_add(v___x_934_, v___x_935_);
v___x_937_ = lean_uint64_mul(v_cacheReadTokens_925_, v_cacheReadNano_929_);
v_totalNano_938_ = lean_uint64_add(v___x_936_, v___x_937_);
v___x_939_ = 5000000ULL;
v___x_940_ = lean_uint64_add(v_totalNano_938_, v___x_939_);
v___x_941_ = 10000000ULL;
v___x_942_ = lean_uint64_div(v___x_940_, v___x_941_);
return v___x_942_;
}
}
}

LEAN_EXPORT uint8_t orb_stream_loop_step(uint8_t v_cancelledOrTimedOut_964_, uint8_t v_hashCollision_965_, uint32_t v_windowLen_966_, uint32_t v_minLen_967_, uint32_t v_repeats_968_, uint32_t v_nonOverlappingCount_969_, uint32_t v_distinctWords4Plus_970_, uint64_t v_comparisons_971_, uint64_t v_comparisonBudget_972_){
_start:
{
uint8_t v___x_973_; uint8_t v___x_974_;
v___x_973_ = 1;
v___x_974_ = lean_uint8_dec_eq(v_cancelledOrTimedOut_964_, v___x_973_);
if (v___x_974_ == 0)
{
uint32_t v___x_975_; uint8_t v___x_976_;
v___x_975_ = 256;
v___x_976_ = lean_uint32_dec_lt(v___x_975_, v_minLen_967_);
if (v___x_976_ == 0)
{
uint8_t v___x_977_;
v___x_977_ = lean_uint64_dec_lt(v_comparisonBudget_972_, v_comparisons_971_);
if (v___x_977_ == 0)
{
uint32_t v___x_978_; uint8_t v___x_979_;
v___x_978_ = 0;
v___x_979_ = lean_uint32_dec_eq(v_minLen_967_, v___x_978_);
if (v___x_979_ == 0)
{
uint32_t v___x_980_; uint8_t v___x_981_;
v___x_980_ = 2;
v___x_981_ = lean_uint32_dec_lt(v_repeats_968_, v___x_980_);
if (v___x_981_ == 0)
{
uint32_t v___x_982_; uint8_t v___x_983_;
v___x_982_ = lean_uint32_mul(v_minLen_967_, v_repeats_968_);
v___x_983_ = lean_uint32_dec_lt(v_windowLen_966_, v___x_982_);
if (v___x_983_ == 0)
{
uint8_t v___x_984_;
v___x_984_ = lean_uint8_dec_eq(v_hashCollision_965_, v___x_973_);
if (v___x_984_ == 0)
{
uint8_t v___x_985_;
v___x_985_ = lean_uint32_dec_le(v_repeats_968_, v_nonOverlappingCount_969_);
if (v___x_985_ == 0)
{
uint8_t v___x_986_;
v___x_986_ = 0;
return v___x_986_;
}
else
{
uint8_t v___x_987_;
v___x_987_ = lean_uint32_dec_le(v___x_980_, v_distinctWords4Plus_970_);
if (v___x_987_ == 0)
{
uint8_t v___x_988_;
v___x_988_ = 0;
return v___x_988_;
}
else
{
return v___x_973_;
}
}
}
else
{
uint8_t v___x_989_;
v___x_989_ = 2;
return v___x_989_;
}
}
else
{
uint8_t v___x_990_;
v___x_990_ = 0;
return v___x_990_;
}
}
else
{
uint8_t v___x_991_;
v___x_991_ = 0;
return v___x_991_;
}
}
else
{
uint8_t v___x_992_;
v___x_992_ = 0;
return v___x_992_;
}
}
else
{
uint8_t v___x_993_;
v___x_993_ = 2;
return v___x_993_;
}
}
else
{
uint8_t v___x_994_;
v___x_994_ = 2;
return v___x_994_;
}
}
else
{
uint8_t v___x_995_;
v___x_995_ = 2;
return v___x_995_;
}
}
}

LEAN_EXPORT uint32_t orb_job_ledger_step(uint8_t v_isAcceptedRemoteBuild_1016_, uint8_t v_expectsContinuation_1017_, uint8_t v_newerTerminalExists_1018_, uint8_t v_newerAmbiguousTentative_1019_){
_start:
{
uint8_t v___x_1020_; uint32_t v___y_1022_; uint8_t v___x_1029_;
v___x_1020_ = 1;
v___x_1029_ = lean_uint8_dec_eq(v_newerTerminalExists_1018_, v___x_1020_);
if (v___x_1029_ == 0)
{
uint8_t v___x_1030_;
v___x_1030_ = lean_uint8_dec_eq(v_newerAmbiguousTentative_1019_, v___x_1020_);
if (v___x_1030_ == 0)
{
uint32_t v___x_1031_;
v___x_1031_ = 0;
v___y_1022_ = v___x_1031_;
goto v___jp_1021_;
}
else
{
uint32_t v___x_1032_;
v___x_1032_ = 256;
v___y_1022_ = v___x_1032_;
goto v___jp_1021_;
}
}
else
{
uint32_t v___x_1033_;
v___x_1033_ = 512;
v___y_1022_ = v___x_1033_;
goto v___jp_1021_;
}
v___jp_1021_:
{
uint8_t v___x_1023_;
v___x_1023_ = lean_uint8_dec_eq(v_isAcceptedRemoteBuild_1016_, v___x_1020_);
if (v___x_1023_ == 0)
{
return v___y_1022_;
}
else
{
uint8_t v___x_1024_;
v___x_1024_ = lean_uint8_dec_eq(v_expectsContinuation_1017_, v___x_1020_);
if (v___x_1024_ == 0)
{
return v___y_1022_;
}
else
{
uint32_t v___x_1025_; uint8_t v___x_1026_;
v___x_1025_ = 0;
v___x_1026_ = lean_uint32_dec_eq(v___y_1022_, v___x_1025_);
if (v___x_1026_ == 0)
{
return v___y_1022_;
}
else
{
uint32_t v___x_1027_; uint32_t v___x_1028_;
v___x_1027_ = 1;
v___x_1028_ = lean_uint32_lor(v___x_1027_, v___y_1022_);
return v___x_1028_;
}
}
}
}
}
}

LEAN_EXPORT uint8_t orb_proc_liveness_step(uint8_t v_procMissing_1044_, uint8_t v_procReadError_1045_, uint8_t v_isZombieOrDeadState_1046_, uint8_t v_hasExpectedTicks_1047_, uint32_t v_fieldsAfterComm_1048_, uint64_t v_expectedStartTicks_1049_, uint64_t v_actualStartTicks_1050_){
_start:
{
uint8_t v___x_1051_; uint8_t v___x_1052_;
v___x_1051_ = 1;
v___x_1052_ = lean_uint8_dec_eq(v_procMissing_1044_, v___x_1051_);
if (v___x_1052_ == 0)
{
uint8_t v___x_1053_;
v___x_1053_ = lean_uint8_dec_eq(v_procReadError_1045_, v___x_1051_);
if (v___x_1053_ == 0)
{
uint8_t v___x_1054_;
v___x_1054_ = lean_uint8_dec_eq(v_isZombieOrDeadState_1046_, v___x_1051_);
if (v___x_1054_ == 0)
{
uint32_t v___x_1055_; uint8_t v___x_1056_;
v___x_1055_ = 20;
v___x_1056_ = lean_uint32_dec_lt(v_fieldsAfterComm_1048_, v___x_1055_);
if (v___x_1056_ == 0)
{
uint8_t v___x_1057_;
v___x_1057_ = lean_uint8_dec_eq(v_hasExpectedTicks_1047_, v___x_1051_);
if (v___x_1057_ == 0)
{
return v___x_1051_;
}
else
{
uint8_t v___x_1058_;
v___x_1058_ = lean_uint64_dec_eq(v_actualStartTicks_1050_, v_expectedStartTicks_1049_);
if (v___x_1058_ == 0)
{
uint8_t v___x_1059_;
v___x_1059_ = 0;
return v___x_1059_;
}
else
{
return v___x_1051_;
}
}
}
else
{
uint8_t v___x_1060_;
v___x_1060_ = 0;
return v___x_1060_;
}
}
else
{
uint8_t v___x_1061_;
v___x_1061_ = 0;
return v___x_1061_;
}
}
else
{
uint8_t v___x_1062_;
v___x_1062_ = 2;
return v___x_1062_;
}
}
else
{
uint8_t v___x_1063_;
v___x_1063_ = 0;
return v___x_1063_;
}
}
}

LEAN_EXPORT uint8_t orb_pr_gate_step(uint8_t v_merged_1080_, uint8_t v_draft_1081_, uint8_t v_closed_1082_, uint8_t v_exactHead_1083_, uint8_t v_actionRequired_1084_, uint8_t v_blocked_1085_, uint8_t v_behind_1086_, uint8_t v_conflicting_1087_, uint8_t v_checksGreen_1088_, uint8_t v_workflowsGreen_1089_){
_start:
{
uint8_t v___x_1090_; uint8_t v___x_1091_;
v___x_1090_ = 1;
v___x_1091_ = lean_uint8_dec_eq(v_merged_1080_, v___x_1090_);
if (v___x_1091_ == 0)
{
uint8_t v___x_1092_;
v___x_1092_ = lean_uint8_dec_eq(v_draft_1081_, v___x_1090_);
if (v___x_1092_ == 0)
{
uint8_t v___x_1093_;
v___x_1093_ = lean_uint8_dec_eq(v_closed_1082_, v___x_1090_);
if (v___x_1093_ == 0)
{
uint8_t v___x_1094_; uint8_t v___x_1095_;
v___x_1094_ = 0;
v___x_1095_ = lean_uint8_dec_eq(v_exactHead_1083_, v___x_1094_);
if (v___x_1095_ == 0)
{
uint8_t v___x_1096_;
v___x_1096_ = lean_uint8_dec_eq(v_actionRequired_1084_, v___x_1090_);
if (v___x_1096_ == 0)
{
uint8_t v___x_1097_;
v___x_1097_ = lean_uint8_dec_eq(v_blocked_1085_, v___x_1090_);
if (v___x_1097_ == 0)
{
uint8_t v___x_1098_;
v___x_1098_ = lean_uint8_dec_eq(v_behind_1086_, v___x_1090_);
if (v___x_1098_ == 0)
{
uint8_t v___x_1099_;
v___x_1099_ = lean_uint8_dec_eq(v_conflicting_1087_, v___x_1090_);
if (v___x_1099_ == 0)
{
uint8_t v___x_1100_;
v___x_1100_ = lean_uint8_dec_eq(v_checksGreen_1088_, v___x_1090_);
if (v___x_1100_ == 0)
{
uint8_t v___x_1101_;
v___x_1101_ = 9;
return v___x_1101_;
}
else
{
uint8_t v___x_1102_;
v___x_1102_ = lean_uint8_dec_eq(v_workflowsGreen_1089_, v___x_1090_);
if (v___x_1102_ == 0)
{
uint8_t v___x_1103_;
v___x_1103_ = 9;
return v___x_1103_;
}
else
{
uint8_t v___x_1104_;
v___x_1104_ = 8;
return v___x_1104_;
}
}
}
else
{
uint8_t v___x_1105_;
v___x_1105_ = 7;
return v___x_1105_;
}
}
else
{
uint8_t v___x_1106_;
v___x_1106_ = 6;
return v___x_1106_;
}
}
else
{
uint8_t v___x_1107_;
v___x_1107_ = 5;
return v___x_1107_;
}
}
else
{
uint8_t v___x_1108_;
v___x_1108_ = 4;
return v___x_1108_;
}
}
else
{
uint8_t v___x_1109_;
v___x_1109_ = 3;
return v___x_1109_;
}
}
else
{
uint8_t v___x_1110_;
v___x_1110_ = 2;
return v___x_1110_;
}
}
else
{
return v___x_1090_;
}
}
else
{
uint8_t v___x_1111_;
v___x_1111_ = 0;
return v___x_1111_;
}
}
}

LEAN_EXPORT uint32_t orb_turn_summary_step(uint8_t v_rawStatus_1134_, uint8_t v_turnEnded_1135_, uint8_t v_allClosed_1136_, uint8_t v_turnOutcomeFinished_1137_){
_start:
{
uint32_t v___y_1139_; uint8_t v___y_1140_; uint32_t v___y_1141_; uint8_t v___y_1142_; uint8_t v___x_1150_; uint8_t v___y_1152_; uint32_t v___y_1153_; uint32_t v___y_1154_; uint8_t v___y_1162_; uint32_t v___y_1163_; uint8_t v___y_1169_; uint8_t v___x_1175_;
v___x_1150_ = 2;
v___x_1175_ = lean_uint8_dec_eq(v_rawStatus_1134_, v___x_1150_);
if (v___x_1175_ == 0)
{
uint8_t v___x_1176_; uint8_t v___x_1177_;
v___x_1176_ = 3;
v___x_1177_ = lean_uint8_dec_eq(v_rawStatus_1134_, v___x_1176_);
if (v___x_1177_ == 0)
{
uint8_t v___x_1178_; uint8_t v___x_1179_;
v___x_1178_ = 1;
v___x_1179_ = lean_uint8_dec_eq(v_rawStatus_1134_, v___x_1178_);
if (v___x_1179_ == 0)
{
goto v___jp_1173_;
}
else
{
uint8_t v___x_1180_; uint8_t v___x_1181_;
v___x_1180_ = 0;
v___x_1181_ = lean_uint8_dec_eq(v_turnEnded_1135_, v___x_1180_);
if (v___x_1181_ == 0)
{
goto v___jp_1173_;
}
else
{
v___y_1169_ = v___x_1178_;
goto v___jp_1168_;
}
}
}
else
{
v___y_1169_ = v___x_1176_;
goto v___jp_1168_;
}
}
else
{
v___y_1169_ = v___x_1150_;
goto v___jp_1168_;
}
v___jp_1138_:
{
uint32_t v___x_1143_; uint32_t v___x_1144_; uint32_t v_card_1145_; uint32_t v___x_1146_; uint32_t v___x_1147_; uint32_t v___x_1148_; uint32_t v___x_1149_;
v___x_1143_ = lean_uint8_to_uint32(v___y_1142_);
v___x_1144_ = 24;
v_card_1145_ = lean_uint32_shift_left(v___x_1143_, v___x_1144_);
v___x_1146_ = lean_uint8_to_uint32(v___y_1140_);
v___x_1147_ = lean_uint32_lor(v___x_1146_, v___y_1141_);
v___x_1148_ = lean_uint32_lor(v___x_1147_, v___y_1139_);
v___x_1149_ = lean_uint32_lor(v___x_1148_, v_card_1145_);
return v___x_1149_;
}
v___jp_1151_:
{
uint8_t v___x_1155_; uint8_t v___x_1156_;
v___x_1155_ = 0;
v___x_1156_ = lean_uint8_dec_eq(v_turnEnded_1135_, v___x_1155_);
if (v___x_1156_ == 0)
{
uint8_t v___x_1157_; uint8_t v___x_1158_;
v___x_1157_ = 1;
v___x_1158_ = lean_uint8_dec_eq(v_allClosed_1136_, v___x_1157_);
if (v___x_1158_ == 0)
{
uint8_t v___x_1159_;
v___x_1159_ = lean_uint8_dec_eq(v_turnOutcomeFinished_1137_, v___x_1157_);
if (v___x_1159_ == 0)
{
uint8_t v___x_1160_;
v___x_1160_ = 3;
v___y_1139_ = v___y_1154_;
v___y_1140_ = v___y_1152_;
v___y_1141_ = v___y_1153_;
v___y_1142_ = v___x_1160_;
goto v___jp_1138_;
}
else
{
v___y_1139_ = v___y_1154_;
v___y_1140_ = v___y_1152_;
v___y_1141_ = v___y_1153_;
v___y_1142_ = v___x_1150_;
goto v___jp_1138_;
}
}
else
{
v___y_1139_ = v___y_1154_;
v___y_1140_ = v___y_1152_;
v___y_1141_ = v___y_1153_;
v___y_1142_ = v___x_1157_;
goto v___jp_1138_;
}
}
else
{
v___y_1139_ = v___y_1154_;
v___y_1140_ = v___y_1152_;
v___y_1141_ = v___y_1153_;
v___y_1142_ = v___x_1155_;
goto v___jp_1138_;
}
}
v___jp_1161_:
{
uint8_t v___x_1164_; uint8_t v___x_1165_;
v___x_1164_ = 1;
v___x_1165_ = lean_uint8_dec_eq(v___y_1162_, v___x_1164_);
if (v___x_1165_ == 0)
{
uint32_t v___x_1166_;
v___x_1166_ = 0;
v___y_1152_ = v___y_1162_;
v___y_1153_ = v___y_1163_;
v___y_1154_ = v___x_1166_;
goto v___jp_1151_;
}
else
{
uint32_t v___x_1167_;
v___x_1167_ = 65536;
v___y_1152_ = v___y_1162_;
v___y_1153_ = v___y_1163_;
v___y_1154_ = v___x_1167_;
goto v___jp_1151_;
}
}
v___jp_1168_:
{
uint8_t v___x_1170_;
v___x_1170_ = lean_uint8_dec_eq(v___y_1169_, v___x_1150_);
if (v___x_1170_ == 0)
{
uint32_t v___x_1171_;
v___x_1171_ = 0;
v___y_1162_ = v___y_1169_;
v___y_1163_ = v___x_1171_;
goto v___jp_1161_;
}
else
{
uint32_t v___x_1172_;
v___x_1172_ = 256;
v___y_1162_ = v___y_1169_;
v___y_1163_ = v___x_1172_;
goto v___jp_1161_;
}
}
v___jp_1173_:
{
uint8_t v___x_1174_;
v___x_1174_ = 0;
v___y_1169_ = v___x_1174_;
goto v___jp_1168_;
}
}
}

LEAN_EXPORT uint64_t orb_usage_limit_status(uint8_t v_statusKind_1192_, uint8_t v_claimKind_1193_, uint8_t v_hasUtilization_1194_, uint8_t v_utilizationPct_1195_, uint8_t v_hasReset_1196_, uint64_t v_resetRemSecs_1197_){
_start:
{
uint64_t v___y_1199_; uint64_t v___y_1200_; uint64_t v___y_1209_; uint64_t v___y_1210_; uint64_t v___y_1214_; uint64_t v___y_1215_; uint64_t v___y_1216_; uint64_t v___y_1222_; uint64_t v___y_1223_; uint64_t v___y_1230_; uint8_t v___x_1232_; uint8_t v___x_1233_;
v___x_1232_ = 0;
v___x_1233_ = lean_uint8_dec_eq(v_statusKind_1192_, v___x_1232_);
if (v___x_1233_ == 0)
{
uint8_t v___x_1234_; uint64_t v___y_1236_; uint64_t v___y_1242_; uint8_t v___x_1248_;
v___x_1234_ = 1;
v___x_1248_ = lean_uint8_dec_eq(v_statusKind_1192_, v___x_1234_);
if (v___x_1248_ == 0)
{
uint8_t v___x_1249_; uint8_t v___x_1250_;
v___x_1249_ = 2;
v___x_1250_ = lean_uint8_dec_eq(v_statusKind_1192_, v___x_1249_);
if (v___x_1250_ == 0)
{
uint64_t v___x_1251_;
v___x_1251_ = 3ULL;
return v___x_1251_;
}
else
{
uint8_t v___x_1252_;
v___x_1252_ = lean_uint8_dec_eq(v_hasReset_1196_, v___x_1234_);
if (v___x_1252_ == 0)
{
uint64_t v___x_1253_;
v___x_1253_ = 2ULL;
return v___x_1253_;
}
else
{
uint64_t v___x_1254_; uint8_t v___x_1255_;
v___x_1254_ = 0ULL;
v___x_1255_ = lean_uint64_dec_lt(v___x_1254_, v_resetRemSecs_1197_);
if (v___x_1255_ == 0)
{
uint64_t v___x_1256_;
v___x_1256_ = 2ULL;
return v___x_1256_;
}
else
{
uint64_t v___x_1257_; uint64_t v_mins_1258_; uint64_t v___x_1259_; uint64_t v_hrs_1260_; uint64_t v___x_1261_; uint64_t v_days_1262_; uint8_t v___x_1263_; uint64_t v___y_1265_;
v___x_1257_ = 60ULL;
v_mins_1258_ = lean_uint64_div(v_resetRemSecs_1197_, v___x_1257_);
v___x_1259_ = 3600ULL;
v_hrs_1260_ = lean_uint64_div(v_resetRemSecs_1197_, v___x_1259_);
v___x_1261_ = 86400ULL;
v_days_1262_ = lean_uint64_div(v_resetRemSecs_1197_, v___x_1261_);
v___x_1263_ = lean_uint64_dec_lt(v_mins_1258_, v___x_1257_);
if (v___x_1263_ == 0)
{
uint64_t v___x_1270_; uint8_t v___x_1271_;
v___x_1270_ = 48ULL;
v___x_1271_ = lean_uint64_dec_lt(v_hrs_1260_, v___x_1270_);
if (v___x_1271_ == 0)
{
uint64_t v___x_1272_;
v___x_1272_ = 3ULL;
v___y_1265_ = v___x_1272_;
goto v___jp_1264_;
}
else
{
uint64_t v___x_1273_;
v___x_1273_ = 2ULL;
v___y_1265_ = v___x_1273_;
goto v___jp_1264_;
}
}
else
{
uint64_t v___x_1274_;
v___x_1274_ = 1ULL;
v___y_1265_ = v___x_1274_;
goto v___jp_1264_;
}
v___jp_1264_:
{
if (v___x_1263_ == 0)
{
uint64_t v___x_1266_; uint8_t v___x_1267_;
v___x_1266_ = 48ULL;
v___x_1267_ = lean_uint64_dec_lt(v_hrs_1260_, v___x_1266_);
if (v___x_1267_ == 0)
{
v___y_1209_ = v___y_1265_;
v___y_1210_ = v_days_1262_;
goto v___jp_1208_;
}
else
{
v___y_1209_ = v___y_1265_;
v___y_1210_ = v_hrs_1260_;
goto v___jp_1208_;
}
}
else
{
uint64_t v___x_1268_; uint8_t v___x_1269_;
v___x_1268_ = 1ULL;
v___x_1269_ = lean_uint64_dec_le(v___x_1268_, v_mins_1258_);
if (v___x_1269_ == 0)
{
v___y_1209_ = v___y_1265_;
v___y_1210_ = v___x_1268_;
goto v___jp_1208_;
}
else
{
v___y_1209_ = v___y_1265_;
v___y_1210_ = v_mins_1258_;
goto v___jp_1208_;
}
}
}
}
}
}
}
else
{
uint8_t v___x_1275_;
v___x_1275_ = lean_uint8_dec_le(v___x_1234_, v_claimKind_1193_);
if (v___x_1275_ == 0)
{
goto v___jp_1246_;
}
else
{
uint8_t v___x_1276_; uint8_t v___x_1277_;
v___x_1276_ = 4;
v___x_1277_ = lean_uint8_dec_le(v_claimKind_1193_, v___x_1276_);
if (v___x_1277_ == 0)
{
goto v___jp_1246_;
}
else
{
uint64_t v___x_1278_; uint64_t v___x_1279_; uint64_t v___x_1280_;
v___x_1278_ = lean_uint8_to_uint64(v_claimKind_1193_);
v___x_1279_ = 8ULL;
v___x_1280_ = lean_uint64_shift_left(v___x_1278_, v___x_1279_);
v___y_1242_ = v___x_1280_;
goto v___jp_1241_;
}
}
}
v___jp_1235_:
{
uint8_t v___x_1237_;
v___x_1237_ = lean_uint8_dec_eq(v_hasUtilization_1194_, v___x_1234_);
if (v___x_1237_ == 0)
{
v___y_1230_ = v___y_1236_;
goto v___jp_1229_;
}
else
{
uint8_t v___x_1238_; uint8_t v___x_1239_;
v___x_1238_ = 100;
v___x_1239_ = lean_uint8_dec_le(v_utilizationPct_1195_, v___x_1238_);
if (v___x_1239_ == 0)
{
v___y_1230_ = v___y_1236_;
goto v___jp_1229_;
}
else
{
uint64_t v___x_1240_;
v___x_1240_ = 65536ULL;
v___y_1222_ = v___y_1236_;
v___y_1223_ = v___x_1240_;
goto v___jp_1221_;
}
}
}
v___jp_1241_:
{
uint8_t v___x_1243_;
v___x_1243_ = lean_uint8_dec_eq(v_claimKind_1193_, v___x_1234_);
if (v___x_1243_ == 0)
{
uint8_t v___x_1244_; uint8_t v___x_1245_;
v___x_1244_ = 2;
v___x_1245_ = lean_uint8_dec_eq(v_claimKind_1193_, v___x_1244_);
if (v___x_1245_ == 0)
{
v___y_1230_ = v___y_1242_;
goto v___jp_1229_;
}
else
{
v___y_1236_ = v___y_1242_;
goto v___jp_1235_;
}
}
else
{
v___y_1236_ = v___y_1242_;
goto v___jp_1235_;
}
}
v___jp_1246_:
{
uint64_t v___x_1247_;
v___x_1247_ = 0ULL;
v___y_1242_ = v___x_1247_;
goto v___jp_1241_;
}
}
else
{
uint64_t v___x_1281_;
v___x_1281_ = 0ULL;
return v___x_1281_;
}
v___jp_1198_:
{
uint64_t v___x_1201_; uint64_t v___x_1202_; uint64_t v___x_1203_; uint64_t v___x_1204_; uint64_t v___x_1205_; uint64_t v___x_1206_; uint64_t v___x_1207_;
v___x_1201_ = 2ULL;
v___x_1202_ = 32ULL;
v___x_1203_ = lean_uint64_shift_left(v___y_1199_, v___x_1202_);
v___x_1204_ = lean_uint64_lor(v___x_1201_, v___x_1203_);
v___x_1205_ = 40ULL;
v___x_1206_ = lean_uint64_shift_left(v___y_1200_, v___x_1205_);
v___x_1207_ = lean_uint64_lor(v___x_1204_, v___x_1206_);
return v___x_1207_;
}
v___jp_1208_:
{
uint64_t v___x_1211_; uint8_t v___x_1212_;
v___x_1211_ = 16777215ULL;
v___x_1212_ = lean_uint64_dec_lt(v___x_1211_, v___y_1210_);
if (v___x_1212_ == 0)
{
v___y_1199_ = v___y_1209_;
v___y_1200_ = v___y_1210_;
goto v___jp_1198_;
}
else
{
v___y_1199_ = v___y_1209_;
v___y_1200_ = v___x_1211_;
goto v___jp_1198_;
}
}
v___jp_1213_:
{
uint64_t v___x_1217_; uint64_t v___x_1218_; uint64_t v___x_1219_; uint64_t v___x_1220_;
v___x_1217_ = 1ULL;
v___x_1218_ = lean_uint64_lor(v___x_1217_, v___y_1214_);
v___x_1219_ = lean_uint64_lor(v___x_1218_, v___y_1215_);
v___x_1220_ = lean_uint64_lor(v___x_1219_, v___y_1216_);
return v___x_1220_;
}
v___jp_1221_:
{
uint64_t v___x_1224_; uint8_t v___x_1225_;
v___x_1224_ = 0ULL;
v___x_1225_ = lean_uint64_dec_eq(v___y_1223_, v___x_1224_);
if (v___x_1225_ == 0)
{
uint64_t v___x_1226_; uint64_t v___x_1227_; uint64_t v___x_1228_;
v___x_1226_ = lean_uint8_to_uint64(v_utilizationPct_1195_);
v___x_1227_ = 24ULL;
v___x_1228_ = lean_uint64_shift_left(v___x_1226_, v___x_1227_);
v___y_1214_ = v___y_1222_;
v___y_1215_ = v___y_1223_;
v___y_1216_ = v___x_1228_;
goto v___jp_1213_;
}
else
{
v___y_1214_ = v___y_1222_;
v___y_1215_ = v___y_1223_;
v___y_1216_ = v___x_1224_;
goto v___jp_1213_;
}
}
v___jp_1229_:
{
uint64_t v___x_1231_;
v___x_1231_ = 0ULL;
v___y_1222_ = v___y_1230_;
v___y_1223_ = v___x_1231_;
goto v___jp_1221_;
}
}
}

LEAN_EXPORT uint64_t orb_relative_time_bucket(uint64_t v_elapsedSecs_1296_){
_start:
{
uint64_t v___y_1298_; uint64_t v___x_1303_; uint8_t v___x_1304_;
v___x_1303_ = 45ULL;
v___x_1304_ = lean_uint64_dec_lt(v_elapsedSecs_1296_, v___x_1303_);
if (v___x_1304_ == 0)
{
uint64_t v___x_1305_; uint8_t v___x_1306_;
v___x_1305_ = 3600ULL;
v___x_1306_ = lean_uint64_dec_lt(v_elapsedSecs_1296_, v___x_1305_);
if (v___x_1306_ == 0)
{
uint64_t v___x_1307_; uint8_t v___x_1308_;
v___x_1307_ = 86400ULL;
v___x_1308_ = lean_uint64_dec_lt(v_elapsedSecs_1296_, v___x_1307_);
if (v___x_1308_ == 0)
{
uint64_t v___x_1309_; uint8_t v___x_1310_;
v___x_1309_ = 604800ULL;
v___x_1310_ = lean_uint64_dec_lt(v_elapsedSecs_1296_, v___x_1309_);
if (v___x_1310_ == 0)
{
uint64_t v_wks_1311_; uint64_t v___x_1312_; uint8_t v___x_1313_;
v_wks_1311_ = lean_uint64_div(v_elapsedSecs_1296_, v___x_1309_);
v___x_1312_ = 4294967295ULL;
v___x_1313_ = lean_uint64_dec_lt(v___x_1312_, v_wks_1311_);
if (v___x_1313_ == 0)
{
v___y_1298_ = v_wks_1311_;
goto v___jp_1297_;
}
else
{
v___y_1298_ = v___x_1312_;
goto v___jp_1297_;
}
}
else
{
uint64_t v___x_1314_; uint64_t v___x_1315_; uint64_t v___x_1316_; uint64_t v___x_1317_; uint64_t v___x_1318_;
v___x_1314_ = 3ULL;
v___x_1315_ = lean_uint64_div(v_elapsedSecs_1296_, v___x_1307_);
v___x_1316_ = 8ULL;
v___x_1317_ = lean_uint64_shift_left(v___x_1315_, v___x_1316_);
v___x_1318_ = lean_uint64_lor(v___x_1314_, v___x_1317_);
return v___x_1318_;
}
}
else
{
uint64_t v___x_1319_; uint64_t v___x_1320_; uint64_t v___x_1321_; uint64_t v___x_1322_; uint64_t v___x_1323_;
v___x_1319_ = 2ULL;
v___x_1320_ = lean_uint64_div(v_elapsedSecs_1296_, v___x_1305_);
v___x_1321_ = 8ULL;
v___x_1322_ = lean_uint64_shift_left(v___x_1320_, v___x_1321_);
v___x_1323_ = lean_uint64_lor(v___x_1319_, v___x_1322_);
return v___x_1323_;
}
}
else
{
uint64_t v___x_1324_; uint64_t v_mins_1325_; uint64_t v___x_1326_; uint64_t v___y_1328_; uint8_t v___x_1332_;
v___x_1324_ = 60ULL;
v_mins_1325_ = lean_uint64_div(v_elapsedSecs_1296_, v___x_1324_);
v___x_1326_ = 1ULL;
v___x_1332_ = lean_uint64_dec_le(v___x_1326_, v_mins_1325_);
if (v___x_1332_ == 0)
{
v___y_1328_ = v___x_1326_;
goto v___jp_1327_;
}
else
{
v___y_1328_ = v_mins_1325_;
goto v___jp_1327_;
}
v___jp_1327_:
{
uint64_t v___x_1329_; uint64_t v___x_1330_; uint64_t v___x_1331_;
v___x_1329_ = 8ULL;
v___x_1330_ = lean_uint64_shift_left(v___y_1328_, v___x_1329_);
v___x_1331_ = lean_uint64_lor(v___x_1326_, v___x_1330_);
return v___x_1331_;
}
}
}
else
{
uint64_t v___x_1333_;
v___x_1333_ = 0ULL;
return v___x_1333_;
}
v___jp_1297_:
{
uint64_t v___x_1299_; uint64_t v___x_1300_; uint64_t v___x_1301_; uint64_t v___x_1302_;
v___x_1299_ = 4ULL;
v___x_1300_ = 8ULL;
v___x_1301_ = lean_uint64_shift_left(v___y_1298_, v___x_1300_);
v___x_1302_ = lean_uint64_lor(v___x_1299_, v___x_1301_);
return v___x_1302_;
}
}
}

LEAN_EXPORT uint64_t orb_transcript_patch_step(uint32_t v_stateLen_1350_, uint32_t v_stateSeq_1351_, uint8_t v_eventKind_1352_, uint32_t v_deltaLen_1353_){
_start:
{
uint64_t v___y_1355_; uint32_t v___y_1356_; uint32_t v___y_1362_; uint8_t v___x_1369_; uint8_t v___x_1370_;
v___x_1369_ = 2;
v___x_1370_ = lean_uint8_dec_le(v_eventKind_1352_, v___x_1369_);
if (v___x_1370_ == 0)
{
uint64_t v___x_1371_; uint64_t v___x_1372_; uint64_t v___x_1373_; uint64_t v___x_1374_; uint64_t v___x_1375_;
v___x_1371_ = lean_uint32_to_uint64(v_stateLen_1350_);
v___x_1372_ = lean_uint32_to_uint64(v_stateSeq_1351_);
v___x_1373_ = 32ULL;
v___x_1374_ = lean_uint64_shift_left(v___x_1372_, v___x_1373_);
v___x_1375_ = lean_uint64_lor(v___x_1371_, v___x_1374_);
return v___x_1375_;
}
else
{
uint8_t v___x_1376_;
v___x_1376_ = lean_uint8_dec_eq(v_eventKind_1352_, v___x_1369_);
if (v___x_1376_ == 0)
{
uint8_t v___x_1377_; uint8_t v___x_1378_;
v___x_1377_ = 1;
v___x_1378_ = lean_uint8_dec_eq(v_eventKind_1352_, v___x_1377_);
if (v___x_1378_ == 0)
{
uint32_t v___x_1379_; uint32_t v___x_1380_; uint8_t v___x_1381_;
v___x_1379_ = 4294967295;
v___x_1380_ = lean_uint32_sub(v___x_1379_, v_deltaLen_1353_);
v___x_1381_ = lean_uint32_dec_le(v_stateLen_1350_, v___x_1380_);
if (v___x_1381_ == 0)
{
v___y_1362_ = v___x_1379_;
goto v___jp_1361_;
}
else
{
uint32_t v___x_1382_;
v___x_1382_ = lean_uint32_add(v_stateLen_1350_, v_deltaLen_1353_);
v___y_1362_ = v___x_1382_;
goto v___jp_1361_;
}
}
else
{
uint32_t v___x_1383_; uint8_t v___x_1384_;
v___x_1383_ = 0;
v___x_1384_ = lean_uint32_dec_lt(v___x_1383_, v_deltaLen_1353_);
if (v___x_1384_ == 0)
{
v___y_1362_ = v_stateLen_1350_;
goto v___jp_1361_;
}
else
{
v___y_1362_ = v_deltaLen_1353_;
goto v___jp_1361_;
}
}
}
else
{
uint32_t v___x_1385_;
v___x_1385_ = 0;
v___y_1362_ = v___x_1385_;
goto v___jp_1361_;
}
}
v___jp_1354_:
{
uint64_t v___x_1357_; uint64_t v___x_1358_; uint64_t v___x_1359_; uint64_t v___x_1360_;
v___x_1357_ = lean_uint32_to_uint64(v___y_1356_);
v___x_1358_ = 32ULL;
v___x_1359_ = lean_uint64_shift_left(v___x_1357_, v___x_1358_);
v___x_1360_ = lean_uint64_lor(v___y_1355_, v___x_1359_);
return v___x_1360_;
}
v___jp_1361_:
{
uint64_t v___x_1363_; uint32_t v___x_1364_; uint8_t v___x_1365_;
v___x_1363_ = lean_uint32_to_uint64(v___y_1362_);
v___x_1364_ = 4294967294;
v___x_1365_ = lean_uint32_dec_le(v_stateSeq_1351_, v___x_1364_);
if (v___x_1365_ == 0)
{
uint32_t v___x_1366_;
v___x_1366_ = 4294967295;
v___y_1355_ = v___x_1363_;
v___y_1356_ = v___x_1366_;
goto v___jp_1354_;
}
else
{
uint32_t v___x_1367_; uint32_t v___x_1368_;
v___x_1367_ = 1;
v___x_1368_ = lean_uint32_add(v_stateSeq_1351_, v___x_1367_);
v___y_1355_ = v___x_1363_;
v___y_1356_ = v___x_1368_;
goto v___jp_1354_;
}
}
}
}

LEAN_EXPORT uint32_t orb_attribution_step(uint8_t v_principalKind_1511_, uint8_t v_claimedKind_1512_, uint8_t v_sameMission_1513_, uint8_t v_isDescendant_1514_){
_start:
{
uint32_t v___y_1516_; uint8_t v___y_1520_; uint32_t v___y_1521_; uint8_t v___y_1524_; uint32_t v___y_1525_; uint8_t v___y_1533_; uint32_t v___y_1534_; uint8_t v___y_1540_; uint32_t v___y_1541_; uint8_t v___y_1546_; uint32_t v___y_1547_; uint32_t v___y_1553_; uint8_t v___y_1554_; uint8_t v___y_1565_; uint8_t v___y_1571_; uint8_t v___y_1575_; uint8_t v___y_1578_; uint8_t v___y_1586_; uint8_t v___y_1592_; uint8_t v___y_1597_; uint8_t v___y_1603_; uint8_t v___x_1613_; uint8_t v___x_1614_;
v___x_1613_ = 6;
v___x_1614_ = lean_uint8_dec_le(v_principalKind_1511_, v___x_1613_);
if (v___x_1614_ == 0)
{
uint8_t v___x_1615_;
v___x_1615_ = 0;
v___y_1603_ = v___x_1615_;
goto v___jp_1602_;
}
else
{
v___y_1603_ = v_principalKind_1511_;
goto v___jp_1602_;
}
v___jp_1515_:
{
uint32_t v___x_1517_; uint32_t v___x_1518_;
v___x_1517_ = 256;
v___x_1518_ = lean_uint32_lor(v___y_1516_, v___x_1517_);
return v___x_1518_;
}
v___jp_1519_:
{
uint8_t v___x_1522_;
v___x_1522_ = lean_uint8_dec_eq(v_claimedKind_1512_, v___y_1520_);
if (v___x_1522_ == 0)
{
return v___y_1521_;
}
else
{
v___y_1516_ = v___y_1521_;
goto v___jp_1515_;
}
}
v___jp_1523_:
{
uint8_t v___x_1526_; uint8_t v___x_1527_;
v___x_1526_ = 3;
v___x_1527_ = lean_uint8_dec_eq(v___y_1524_, v___x_1526_);
if (v___x_1527_ == 0)
{
uint8_t v___x_1528_; uint8_t v___x_1529_;
v___x_1528_ = 4;
v___x_1529_ = lean_uint8_dec_eq(v___y_1524_, v___x_1528_);
if (v___x_1529_ == 0)
{
uint8_t v___x_1530_; uint8_t v___x_1531_;
v___x_1530_ = 6;
v___x_1531_ = lean_uint8_dec_eq(v___y_1524_, v___x_1530_);
if (v___x_1531_ == 0)
{
return v___y_1525_;
}
else
{
v___y_1520_ = v___y_1524_;
v___y_1521_ = v___y_1525_;
goto v___jp_1519_;
}
}
else
{
v___y_1520_ = v___y_1524_;
v___y_1521_ = v___y_1525_;
goto v___jp_1519_;
}
}
else
{
v___y_1520_ = v___y_1524_;
v___y_1521_ = v___y_1525_;
goto v___jp_1519_;
}
}
v___jp_1532_:
{
uint8_t v___x_1535_; uint8_t v___x_1536_;
v___x_1535_ = 2;
v___x_1536_ = lean_uint8_dec_eq(v_claimedKind_1512_, v___x_1535_);
if (v___x_1536_ == 0)
{
v___y_1524_ = v___y_1533_;
v___y_1525_ = v___y_1534_;
goto v___jp_1523_;
}
else
{
uint8_t v___x_1537_; uint8_t v___x_1538_;
v___x_1537_ = 1;
v___x_1538_ = lean_uint8_dec_eq(v_isDescendant_1514_, v___x_1537_);
if (v___x_1538_ == 0)
{
v___y_1524_ = v___y_1533_;
v___y_1525_ = v___y_1534_;
goto v___jp_1523_;
}
else
{
v___y_1516_ = v___y_1534_;
goto v___jp_1515_;
}
}
}
v___jp_1539_:
{
uint8_t v___x_1542_; uint8_t v___x_1543_;
v___x_1542_ = 1;
v___x_1543_ = lean_uint8_dec_eq(v_claimedKind_1512_, v___x_1542_);
if (v___x_1543_ == 0)
{
v___y_1533_ = v___y_1540_;
v___y_1534_ = v___y_1541_;
goto v___jp_1532_;
}
else
{
uint8_t v___x_1544_;
v___x_1544_ = lean_uint8_dec_eq(v_sameMission_1513_, v___x_1542_);
if (v___x_1544_ == 0)
{
v___y_1533_ = v___y_1540_;
v___y_1534_ = v___y_1541_;
goto v___jp_1532_;
}
else
{
v___y_1516_ = v___y_1541_;
goto v___jp_1515_;
}
}
}
v___jp_1545_:
{
uint8_t v___x_1548_; uint8_t v___x_1549_;
v___x_1548_ = 1;
v___x_1549_ = lean_uint8_dec_eq(v___y_1546_, v___x_1548_);
if (v___x_1549_ == 0)
{
uint8_t v___x_1550_; uint8_t v___x_1551_;
v___x_1550_ = 2;
v___x_1551_ = lean_uint8_dec_eq(v___y_1546_, v___x_1550_);
if (v___x_1551_ == 0)
{
v___y_1524_ = v___y_1546_;
v___y_1525_ = v___y_1547_;
goto v___jp_1523_;
}
else
{
v___y_1540_ = v___y_1546_;
v___y_1541_ = v___y_1547_;
goto v___jp_1539_;
}
}
else
{
v___y_1540_ = v___y_1546_;
v___y_1541_ = v___y_1547_;
goto v___jp_1539_;
}
}
v___jp_1552_:
{
uint8_t v___x_1555_; uint8_t v___x_1556_;
v___x_1555_ = 0;
v___x_1556_ = lean_uint8_dec_eq(v_claimedKind_1512_, v___x_1555_);
if (v___x_1556_ == 0)
{
uint8_t v___x_1557_; uint8_t v___x_1558_;
v___x_1557_ = 5;
v___x_1558_ = lean_uint8_dec_eq(v___y_1554_, v___x_1557_);
if (v___x_1558_ == 0)
{
v___y_1546_ = v___y_1554_;
v___y_1547_ = v___y_1553_;
goto v___jp_1545_;
}
else
{
uint8_t v___x_1559_; uint8_t v___x_1560_;
v___x_1559_ = 1;
v___x_1560_ = lean_uint8_dec_eq(v_claimedKind_1512_, v___x_1559_);
if (v___x_1560_ == 0)
{
uint8_t v___x_1561_; uint8_t v___x_1562_;
v___x_1561_ = 2;
v___x_1562_ = lean_uint8_dec_eq(v_claimedKind_1512_, v___x_1561_);
if (v___x_1562_ == 0)
{
uint8_t v___x_1563_;
v___x_1563_ = lean_uint8_dec_eq(v_claimedKind_1512_, v___x_1557_);
if (v___x_1563_ == 0)
{
v___y_1546_ = v___y_1554_;
v___y_1547_ = v___y_1553_;
goto v___jp_1545_;
}
else
{
v___y_1516_ = v___y_1553_;
goto v___jp_1515_;
}
}
else
{
v___y_1516_ = v___y_1553_;
goto v___jp_1515_;
}
}
else
{
v___y_1516_ = v___y_1553_;
goto v___jp_1515_;
}
}
}
else
{
v___y_1516_ = v___y_1553_;
goto v___jp_1515_;
}
}
v___jp_1564_:
{
uint32_t v___x_1566_; uint8_t v___x_1567_; uint8_t v___x_1568_;
v___x_1566_ = lean_uint8_to_uint32(v___y_1565_);
v___x_1567_ = 6;
v___x_1568_ = lean_uint8_dec_le(v_principalKind_1511_, v___x_1567_);
if (v___x_1568_ == 0)
{
uint8_t v___x_1569_;
v___x_1569_ = 0;
v___y_1553_ = v___x_1566_;
v___y_1554_ = v___x_1569_;
goto v___jp_1552_;
}
else
{
v___y_1553_ = v___x_1566_;
v___y_1554_ = v_principalKind_1511_;
goto v___jp_1552_;
}
}
v___jp_1570_:
{
uint8_t v___x_1572_; uint8_t v___x_1573_;
v___x_1572_ = 0;
v___x_1573_ = lean_uint8_dec_eq(v_claimedKind_1512_, v___x_1572_);
if (v___x_1573_ == 0)
{
v___y_1565_ = v_claimedKind_1512_;
goto v___jp_1564_;
}
else
{
v___y_1565_ = v___y_1571_;
goto v___jp_1564_;
}
}
v___jp_1574_:
{
uint8_t v___x_1576_;
v___x_1576_ = lean_uint8_dec_eq(v_claimedKind_1512_, v___y_1575_);
if (v___x_1576_ == 0)
{
v___y_1565_ = v___y_1575_;
goto v___jp_1564_;
}
else
{
v___y_1571_ = v___y_1575_;
goto v___jp_1570_;
}
}
v___jp_1577_:
{
uint8_t v___x_1579_; uint8_t v___x_1580_;
v___x_1579_ = 3;
v___x_1580_ = lean_uint8_dec_eq(v___y_1578_, v___x_1579_);
if (v___x_1580_ == 0)
{
uint8_t v___x_1581_; uint8_t v___x_1582_;
v___x_1581_ = 4;
v___x_1582_ = lean_uint8_dec_eq(v___y_1578_, v___x_1581_);
if (v___x_1582_ == 0)
{
uint8_t v___x_1583_; uint8_t v___x_1584_;
v___x_1583_ = 6;
v___x_1584_ = lean_uint8_dec_eq(v___y_1578_, v___x_1583_);
if (v___x_1584_ == 0)
{
v___y_1565_ = v___y_1578_;
goto v___jp_1564_;
}
else
{
v___y_1575_ = v___y_1578_;
goto v___jp_1574_;
}
}
else
{
v___y_1575_ = v___y_1578_;
goto v___jp_1574_;
}
}
else
{
v___y_1575_ = v___y_1578_;
goto v___jp_1574_;
}
}
v___jp_1585_:
{
uint8_t v___x_1587_; uint8_t v___x_1588_;
v___x_1587_ = 2;
v___x_1588_ = lean_uint8_dec_eq(v_claimedKind_1512_, v___x_1587_);
if (v___x_1588_ == 0)
{
v___y_1578_ = v___y_1586_;
goto v___jp_1577_;
}
else
{
uint8_t v___x_1589_; uint8_t v___x_1590_;
v___x_1589_ = 1;
v___x_1590_ = lean_uint8_dec_eq(v_isDescendant_1514_, v___x_1589_);
if (v___x_1590_ == 0)
{
v___y_1578_ = v___y_1586_;
goto v___jp_1577_;
}
else
{
v___y_1571_ = v___y_1586_;
goto v___jp_1570_;
}
}
}
v___jp_1591_:
{
uint8_t v___x_1593_; uint8_t v___x_1594_;
v___x_1593_ = 1;
v___x_1594_ = lean_uint8_dec_eq(v_claimedKind_1512_, v___x_1593_);
if (v___x_1594_ == 0)
{
v___y_1586_ = v___y_1592_;
goto v___jp_1585_;
}
else
{
uint8_t v___x_1595_;
v___x_1595_ = lean_uint8_dec_eq(v_sameMission_1513_, v___x_1593_);
if (v___x_1595_ == 0)
{
v___y_1586_ = v___y_1592_;
goto v___jp_1585_;
}
else
{
v___y_1571_ = v___y_1592_;
goto v___jp_1570_;
}
}
}
v___jp_1596_:
{
uint8_t v___x_1598_; uint8_t v___x_1599_;
v___x_1598_ = 1;
v___x_1599_ = lean_uint8_dec_eq(v___y_1597_, v___x_1598_);
if (v___x_1599_ == 0)
{
uint8_t v___x_1600_; uint8_t v___x_1601_;
v___x_1600_ = 2;
v___x_1601_ = lean_uint8_dec_eq(v___y_1597_, v___x_1600_);
if (v___x_1601_ == 0)
{
v___y_1578_ = v___y_1597_;
goto v___jp_1577_;
}
else
{
v___y_1592_ = v___y_1597_;
goto v___jp_1591_;
}
}
else
{
v___y_1592_ = v___y_1597_;
goto v___jp_1591_;
}
}
v___jp_1602_:
{
uint8_t v___x_1604_; uint8_t v___x_1605_;
v___x_1604_ = 0;
v___x_1605_ = lean_uint8_dec_eq(v_claimedKind_1512_, v___x_1604_);
if (v___x_1605_ == 0)
{
uint8_t v___x_1606_; uint8_t v___x_1607_;
v___x_1606_ = 5;
v___x_1607_ = lean_uint8_dec_eq(v___y_1603_, v___x_1606_);
if (v___x_1607_ == 0)
{
v___y_1597_ = v___y_1603_;
goto v___jp_1596_;
}
else
{
uint8_t v___x_1608_; uint8_t v___x_1609_;
v___x_1608_ = 1;
v___x_1609_ = lean_uint8_dec_eq(v_claimedKind_1512_, v___x_1608_);
if (v___x_1609_ == 0)
{
uint8_t v___x_1610_; uint8_t v___x_1611_;
v___x_1610_ = 2;
v___x_1611_ = lean_uint8_dec_eq(v_claimedKind_1512_, v___x_1610_);
if (v___x_1611_ == 0)
{
uint8_t v___x_1612_;
v___x_1612_ = lean_uint8_dec_eq(v_claimedKind_1512_, v___x_1606_);
if (v___x_1612_ == 0)
{
v___y_1597_ = v___y_1603_;
goto v___jp_1596_;
}
else
{
v___y_1571_ = v___y_1603_;
goto v___jp_1570_;
}
}
else
{
v___y_1571_ = v___y_1603_;
goto v___jp_1570_;
}
}
else
{
v___y_1571_ = v___y_1603_;
goto v___jp_1570_;
}
}
}
else
{
v___y_1571_ = v___y_1603_;
goto v___jp_1570_;
}
}
}
}

LEAN_EXPORT uint8_t orb_schedule_step(uint8_t v_op_1685_, uint8_t v_known_1686_, uint8_t v_cancelled_1687_, uint8_t v_ownerTerminal_1688_, uint8_t v_authorized_1689_, uint8_t v_busy_1690_, uint64_t v_lastFired_1691_, uint64_t v_nextDue_1692_, uint64_t v_now_1693_){
_start:
{
uint8_t v___x_1694_; uint8_t v___x_1695_;
v___x_1694_ = 1;
v___x_1695_ = lean_uint8_dec_eq(v_authorized_1689_, v___x_1694_);
if (v___x_1695_ == 0)
{
uint8_t v___x_1696_;
v___x_1696_ = 0;
return v___x_1696_;
}
else
{
uint8_t v___x_1697_; uint8_t v___x_1698_;
v___x_1697_ = 0;
v___x_1698_ = lean_uint8_dec_eq(v_op_1685_, v___x_1697_);
if (v___x_1698_ == 0)
{
uint8_t v___x_1699_;
v___x_1699_ = lean_uint8_dec_eq(v_cancelled_1687_, v___x_1694_);
if (v___x_1699_ == 0)
{
uint8_t v___x_1700_;
v___x_1700_ = lean_uint8_dec_eq(v_ownerTerminal_1688_, v___x_1694_);
if (v___x_1700_ == 0)
{
uint8_t v___x_1701_;
v___x_1701_ = lean_uint64_dec_lt(v_lastFired_1691_, v_nextDue_1692_);
if (v___x_1701_ == 0)
{
uint8_t v___x_1702_;
v___x_1702_ = 4;
return v___x_1702_;
}
else
{
uint8_t v___x_1703_;
v___x_1703_ = lean_uint64_dec_le(v_nextDue_1692_, v_now_1693_);
if (v___x_1703_ == 0)
{
uint8_t v___x_1704_;
v___x_1704_ = 4;
return v___x_1704_;
}
else
{
uint8_t v___x_1705_;
v___x_1705_ = lean_uint8_dec_eq(v_busy_1690_, v___x_1694_);
if (v___x_1705_ == 0)
{
uint8_t v___x_1706_;
v___x_1706_ = 3;
return v___x_1706_;
}
else
{
uint8_t v___x_1707_;
v___x_1707_ = 4;
return v___x_1707_;
}
}
}
}
else
{
return v___x_1697_;
}
}
else
{
return v___x_1697_;
}
}
else
{
uint8_t v___x_1708_;
v___x_1708_ = lean_uint8_dec_eq(v_known_1686_, v___x_1694_);
if (v___x_1708_ == 0)
{
uint8_t v___x_1709_;
v___x_1709_ = lean_uint8_dec_eq(v_ownerTerminal_1688_, v___x_1694_);
if (v___x_1709_ == 0)
{
return v___x_1694_;
}
else
{
return v___x_1697_;
}
}
else
{
uint8_t v___x_1710_;
v___x_1710_ = 2;
return v___x_1710_;
}
}
}
}
}

LEAN_EXPORT uint64_t orb_stats_settle_step(uint64_t v_acc_1748_, uint64_t v_cost_1749_, uint8_t v_seen_1750_){
_start:
{
uint8_t v___x_1751_; uint8_t v___x_1752_;
v___x_1751_ = 1;
v___x_1752_ = lean_uint8_dec_eq(v_seen_1750_, v___x_1751_);
if (v___x_1752_ == 0)
{
uint64_t v___x_1753_; uint64_t v___x_1754_; uint8_t v___x_1755_;
v___x_1753_ = 18446744073709551615ULL;
v___x_1754_ = lean_uint64_sub(v___x_1753_, v_cost_1749_);
v___x_1755_ = lean_uint64_dec_le(v_acc_1748_, v___x_1754_);
if (v___x_1755_ == 0)
{
return v___x_1753_;
}
else
{
uint64_t v___x_1756_;
v___x_1756_ = lean_uint64_add(v_acc_1748_, v_cost_1749_);
return v___x_1756_;
}
}
else
{
return v_acc_1748_;
}
}
}

LEAN_EXPORT uint32_t orb_privilege_step(uint8_t v_sameOwner_1765_, uint8_t v_missionActive_1766_, uint8_t v_biometricSigned_1767_, uint8_t v_scopeRank_1768_, uint8_t v_maxGrantedScope_1769_, uint8_t v_bunkerState_1770_, uint8_t v_revoked_1771_, uint64_t v_nowEpoch_1772_, uint64_t v_grantExpiresAt_1773_, uint64_t v_sessionExpiresAt_1774_){
_start:
{
uint8_t v___x_1775_; uint8_t v___x_1776_;
v___x_1775_ = 0;
v___x_1776_ = lean_uint8_dec_eq(v_missionActive_1766_, v___x_1775_);
if (v___x_1776_ == 0)
{
uint8_t v___x_1777_; uint8_t v___x_1778_;
v___x_1777_ = 1;
v___x_1778_ = lean_uint8_dec_eq(v_revoked_1771_, v___x_1777_);
if (v___x_1778_ == 0)
{
uint8_t v___x_1779_;
v___x_1779_ = lean_uint8_dec_eq(v_bunkerState_1770_, v___x_1775_);
if (v___x_1779_ == 0)
{
uint32_t v___x_1780_;
v___x_1780_ = 65536;
return v___x_1780_;
}
else
{
uint8_t v___x_1781_;
v___x_1781_ = lean_uint64_dec_le(v_grantExpiresAt_1773_, v_nowEpoch_1772_);
if (v___x_1781_ == 0)
{
uint8_t v___x_1782_;
v___x_1782_ = lean_uint64_dec_le(v_sessionExpiresAt_1774_, v_nowEpoch_1772_);
if (v___x_1782_ == 0)
{
uint8_t v___x_1783_;
v___x_1783_ = lean_uint8_dec_eq(v_sameOwner_1765_, v___x_1777_);
if (v___x_1783_ == 0)
{
uint32_t v___x_1784_;
v___x_1784_ = 0;
return v___x_1784_;
}
else
{
uint8_t v___x_1785_;
v___x_1785_ = lean_uint8_dec_eq(v_biometricSigned_1767_, v___x_1777_);
if (v___x_1785_ == 0)
{
uint32_t v___x_1786_;
v___x_1786_ = 0;
return v___x_1786_;
}
else
{
uint8_t v___x_1787_;
v___x_1787_ = lean_uint8_dec_le(v_scopeRank_1768_, v_maxGrantedScope_1769_);
if (v___x_1787_ == 0)
{
uint32_t v___x_1788_;
v___x_1788_ = 0;
return v___x_1788_;
}
else
{
uint8_t v___x_1789_; uint8_t v___x_1790_;
v___x_1789_ = 2;
v___x_1790_ = lean_uint8_dec_lt(v_scopeRank_1768_, v___x_1789_);
if (v___x_1790_ == 0)
{
uint32_t v___x_1791_;
v___x_1791_ = 1;
return v___x_1791_;
}
else
{
uint32_t v___x_1792_;
v___x_1792_ = 257;
return v___x_1792_;
}
}
}
}
}
else
{
uint32_t v___x_1793_;
v___x_1793_ = 65536;
return v___x_1793_;
}
}
else
{
uint32_t v___x_1794_;
v___x_1794_ = 65536;
return v___x_1794_;
}
}
}
else
{
uint32_t v___x_1795_;
v___x_1795_ = 65536;
return v___x_1795_;
}
}
else
{
uint32_t v___x_1796_;
v___x_1796_ = 65536;
return v___x_1796_;
}
}
}

LEAN_EXPORT uint32_t orb_bunker_step(uint8_t v_currentState_1819_, uint8_t v_canaryTripped_1820_, uint8_t v_authFailureBurst_1821_, uint8_t v_manualTrigger_1822_, uint8_t v_biometricUnbunker_1823_){
_start:
{
uint8_t v___x_1824_; uint8_t v___y_1826_; uint32_t v___y_1827_; uint32_t v___y_1828_; uint8_t v___y_1834_; uint8_t v___y_1835_; uint8_t v___y_1841_; uint8_t v___x_1854_;
v___x_1824_ = 2;
v___x_1854_ = lean_uint8_dec_le(v_currentState_1819_, v___x_1824_);
if (v___x_1854_ == 0)
{
v___y_1841_ = v___x_1824_;
goto v___jp_1840_;
}
else
{
v___y_1841_ = v_currentState_1819_;
goto v___jp_1840_;
}
v___jp_1825_:
{
uint32_t v___x_1829_; uint8_t v___x_1830_;
v___x_1829_ = lean_uint32_lor(v___y_1827_, v___y_1828_);
v___x_1830_ = lean_uint8_dec_eq(v___y_1826_, v___x_1824_);
if (v___x_1830_ == 0)
{
return v___x_1829_;
}
else
{
uint32_t v___x_1831_; uint32_t v___x_1832_;
v___x_1831_ = 65536;
v___x_1832_ = lean_uint32_lor(v___x_1829_, v___x_1831_);
return v___x_1832_;
}
}
v___jp_1833_:
{
uint32_t v___x_1836_; uint8_t v___x_1837_;
v___x_1836_ = lean_uint8_to_uint32(v___y_1835_);
v___x_1837_ = lean_uint8_dec_le(v___y_1834_, v___y_1835_);
if (v___x_1837_ == 0)
{
uint32_t v___x_1838_;
v___x_1838_ = 0;
v___y_1826_ = v___y_1835_;
v___y_1827_ = v___x_1836_;
v___y_1828_ = v___x_1838_;
goto v___jp_1825_;
}
else
{
uint32_t v___x_1839_;
v___x_1839_ = 256;
v___y_1826_ = v___y_1835_;
v___y_1827_ = v___x_1836_;
v___y_1828_ = v___x_1839_;
goto v___jp_1825_;
}
}
v___jp_1840_:
{
uint8_t v___x_1842_; uint8_t v___x_1843_;
v___x_1842_ = 1;
v___x_1843_ = lean_uint8_dec_eq(v_canaryTripped_1820_, v___x_1842_);
if (v___x_1843_ == 0)
{
uint8_t v___x_1844_;
v___x_1844_ = lean_uint8_dec_eq(v_manualTrigger_1822_, v___x_1824_);
if (v___x_1844_ == 0)
{
uint8_t v___x_1845_;
v___x_1845_ = lean_uint8_dec_eq(v___y_1841_, v___x_1824_);
if (v___x_1845_ == 0)
{
uint8_t v___x_1846_;
v___x_1846_ = lean_uint8_dec_eq(v_authFailureBurst_1821_, v___x_1842_);
if (v___x_1846_ == 0)
{
uint8_t v___x_1847_;
v___x_1847_ = lean_uint8_dec_eq(v_manualTrigger_1822_, v___x_1842_);
if (v___x_1847_ == 0)
{
uint8_t v___x_1848_;
v___x_1848_ = lean_uint8_dec_eq(v___y_1841_, v___x_1842_);
if (v___x_1848_ == 0)
{
uint8_t v___x_1849_;
v___x_1849_ = 0;
v___y_1834_ = v___x_1842_;
v___y_1835_ = v___x_1849_;
goto v___jp_1833_;
}
else
{
uint8_t v___x_1850_;
v___x_1850_ = lean_uint8_dec_eq(v_biometricUnbunker_1823_, v___x_1842_);
if (v___x_1850_ == 0)
{
v___y_1834_ = v___x_1842_;
v___y_1835_ = v___x_1842_;
goto v___jp_1833_;
}
else
{
uint8_t v___x_1851_;
v___x_1851_ = 0;
v___y_1834_ = v___x_1842_;
v___y_1835_ = v___x_1851_;
goto v___jp_1833_;
}
}
}
else
{
v___y_1834_ = v___x_1842_;
v___y_1835_ = v___x_1842_;
goto v___jp_1833_;
}
}
else
{
v___y_1834_ = v___x_1842_;
v___y_1835_ = v___x_1842_;
goto v___jp_1833_;
}
}
else
{
uint8_t v___x_1852_;
v___x_1852_ = lean_uint8_dec_eq(v_biometricUnbunker_1823_, v___x_1842_);
if (v___x_1852_ == 0)
{
v___y_1834_ = v___x_1842_;
v___y_1835_ = v___x_1824_;
goto v___jp_1833_;
}
else
{
uint8_t v___x_1853_;
v___x_1853_ = 0;
v___y_1834_ = v___x_1842_;
v___y_1835_ = v___x_1853_;
goto v___jp_1833_;
}
}
}
else
{
v___y_1834_ = v___x_1842_;
v___y_1835_ = v___x_1824_;
goto v___jp_1833_;
}
}
else
{
v___y_1834_ = v___x_1842_;
v___y_1835_ = v___x_1824_;
goto v___jp_1833_;
}
}
}
}

LEAN_EXPORT uint8_t orb_deploy_gate_step(uint8_t v_isProdService_1867_, uint8_t v_serviceMatches_1868_, uint8_t v_callingOnSelf_1869_, uint8_t v_debounceOk_1870_, uint8_t v_forceFlag_1871_, uint8_t v_biometricApproved_1872_, uint8_t v_bunkerState_1873_, uint32_t v_liveWriters_1874_){
_start:
{
uint8_t v___x_1875_; uint8_t v___y_1877_; uint8_t v___x_1886_;
v___x_1875_ = 1;
v___x_1886_ = lean_uint8_dec_eq(v_serviceMatches_1868_, v___x_1875_);
if (v___x_1886_ == 0)
{
v___y_1877_ = v___x_1886_;
goto v___jp_1876_;
}
else
{
uint8_t v___x_1887_; uint8_t v___x_1888_;
v___x_1887_ = 0;
v___x_1888_ = lean_uint8_dec_eq(v_callingOnSelf_1869_, v___x_1887_);
if (v___x_1888_ == 0)
{
v___y_1877_ = v___x_1888_;
goto v___jp_1876_;
}
else
{
uint8_t v___x_1889_;
v___x_1889_ = lean_uint8_dec_eq(v_debounceOk_1870_, v___x_1875_);
if (v___x_1889_ == 0)
{
v___y_1877_ = v___x_1889_;
goto v___jp_1876_;
}
else
{
uint32_t v___x_1890_; uint8_t v___x_1891_;
v___x_1890_ = 0;
v___x_1891_ = lean_uint32_dec_eq(v_liveWriters_1874_, v___x_1890_);
if (v___x_1891_ == 0)
{
uint8_t v___x_1892_;
v___x_1892_ = lean_uint8_dec_eq(v_forceFlag_1871_, v___x_1875_);
if (v___x_1892_ == 0)
{
v___y_1877_ = v___x_1892_;
goto v___jp_1876_;
}
else
{
goto v___jp_1883_;
}
}
else
{
goto v___jp_1883_;
}
}
}
}
v___jp_1876_:
{
uint8_t v___x_1878_;
v___x_1878_ = lean_uint8_dec_eq(v_isProdService_1867_, v___x_1875_);
if (v___x_1878_ == 0)
{
if (v___y_1877_ == 0)
{
uint8_t v___x_1879_;
v___x_1879_ = 0;
return v___x_1879_;
}
else
{
return v___x_1875_;
}
}
else
{
if (v___y_1877_ == 0)
{
uint8_t v___x_1880_;
v___x_1880_ = 0;
return v___x_1880_;
}
else
{
uint8_t v___x_1881_;
v___x_1881_ = lean_uint8_dec_eq(v_biometricApproved_1872_, v___x_1875_);
if (v___x_1881_ == 0)
{
uint8_t v___x_1882_;
v___x_1882_ = 0;
return v___x_1882_;
}
else
{
return v___x_1875_;
}
}
}
}
v___jp_1883_:
{
uint8_t v___x_1884_; uint8_t v___x_1885_;
v___x_1884_ = 0;
v___x_1885_ = lean_uint8_dec_eq(v_bunkerState_1873_, v___x_1884_);
v___y_1877_ = v___x_1885_;
goto v___jp_1876_;
}
}
}

LEAN_EXPORT uint64_t orb_scroll_max_top(uint64_t v_content_1911_, uint64_t v_viewport_1912_){
_start:
{
uint8_t v___x_1913_;
v___x_1913_ = lean_uint64_dec_le(v_viewport_1912_, v_content_1911_);
if (v___x_1913_ == 0)
{
uint64_t v___x_1914_;
v___x_1914_ = 0ULL;
return v___x_1914_;
}
else
{
uint64_t v___x_1915_;
v___x_1915_ = lean_uint64_sub(v_content_1911_, v_viewport_1912_);
return v___x_1915_;
}
}
}

LEAN_EXPORT uint64_t orb_scroll_clamp_top(uint64_t v_content_1922_, uint64_t v_viewport_1923_, uint64_t v_top_1924_){
_start:
{
uint64_t v___y_1926_; uint8_t v___x_1928_;
v___x_1928_ = lean_uint64_dec_le(v_viewport_1923_, v_content_1922_);
if (v___x_1928_ == 0)
{
uint64_t v___x_1929_;
v___x_1929_ = 0ULL;
v___y_1926_ = v___x_1929_;
goto v___jp_1925_;
}
else
{
uint64_t v___x_1930_;
v___x_1930_ = lean_uint64_sub(v_content_1922_, v_viewport_1923_);
v___y_1926_ = v___x_1930_;
goto v___jp_1925_;
}
v___jp_1925_:
{
uint8_t v___x_1927_;
v___x_1927_ = lean_uint64_dec_le(v_top_1924_, v___y_1926_);
if (v___x_1927_ == 0)
{
return v___y_1926_;
}
else
{
return v_top_1924_;
}
}
}
}

LEAN_EXPORT uint64_t orb_scroll_gap(uint64_t v_content_1939_, uint64_t v_viewport_1940_, uint64_t v_top_1941_){
_start:
{
uint64_t v___y_1943_; uint64_t v___y_1944_; uint64_t v___y_1949_; uint64_t v___y_1950_; uint64_t v___y_1953_; uint8_t v___x_1957_;
v___x_1957_ = lean_uint64_dec_le(v_viewport_1940_, v_content_1939_);
if (v___x_1957_ == 0)
{
uint64_t v___x_1958_;
v___x_1958_ = 0ULL;
v___y_1953_ = v___x_1958_;
goto v___jp_1952_;
}
else
{
uint64_t v___x_1959_;
v___x_1959_ = lean_uint64_sub(v_content_1939_, v_viewport_1940_);
v___y_1953_ = v___x_1959_;
goto v___jp_1952_;
}
v___jp_1942_:
{
uint8_t v___x_1945_;
v___x_1945_ = lean_uint64_dec_le(v___y_1944_, v___y_1943_);
if (v___x_1945_ == 0)
{
uint64_t v___x_1946_;
v___x_1946_ = 0ULL;
return v___x_1946_;
}
else
{
uint64_t v___x_1947_;
v___x_1947_ = lean_uint64_sub(v___y_1943_, v___y_1944_);
return v___x_1947_;
}
}
v___jp_1948_:
{
uint8_t v___x_1951_;
v___x_1951_ = lean_uint64_dec_le(v_top_1941_, v___y_1950_);
if (v___x_1951_ == 0)
{
v___y_1943_ = v___y_1949_;
v___y_1944_ = v___y_1950_;
goto v___jp_1942_;
}
else
{
v___y_1943_ = v___y_1949_;
v___y_1944_ = v_top_1941_;
goto v___jp_1942_;
}
}
v___jp_1952_:
{
uint8_t v___x_1954_;
v___x_1954_ = lean_uint64_dec_le(v_viewport_1940_, v_content_1939_);
if (v___x_1954_ == 0)
{
uint64_t v___x_1955_;
v___x_1955_ = 0ULL;
v___y_1949_ = v___y_1953_;
v___y_1950_ = v___x_1955_;
goto v___jp_1948_;
}
else
{
uint64_t v___x_1956_;
v___x_1956_ = lean_uint64_sub(v_content_1939_, v_viewport_1940_);
v___y_1949_ = v___y_1953_;
v___y_1950_ = v___x_1956_;
goto v___jp_1948_;
}
}
}
}

LEAN_EXPORT uint64_t orb_scroll_layout_step(uint8_t v_pinned_1968_, uint64_t v_content_1969_, uint64_t v_viewport_1970_, uint64_t v_top_1971_){
_start:
{
uint64_t v___y_1973_; uint8_t v___x_1975_; uint8_t v___x_1976_;
v___x_1975_ = 1;
v___x_1976_ = lean_uint8_dec_eq(v_pinned_1968_, v___x_1975_);
if (v___x_1976_ == 0)
{
uint8_t v___x_1977_;
v___x_1977_ = lean_uint64_dec_le(v_viewport_1970_, v_content_1969_);
if (v___x_1977_ == 0)
{
uint64_t v___x_1978_;
v___x_1978_ = 0ULL;
v___y_1973_ = v___x_1978_;
goto v___jp_1972_;
}
else
{
uint64_t v___x_1979_;
v___x_1979_ = lean_uint64_sub(v_content_1969_, v_viewport_1970_);
v___y_1973_ = v___x_1979_;
goto v___jp_1972_;
}
}
else
{
uint8_t v___x_1980_;
v___x_1980_ = lean_uint64_dec_le(v_viewport_1970_, v_content_1969_);
if (v___x_1980_ == 0)
{
uint64_t v___x_1981_;
v___x_1981_ = 0ULL;
return v___x_1981_;
}
else
{
uint64_t v___x_1982_;
v___x_1982_ = lean_uint64_sub(v_content_1969_, v_viewport_1970_);
return v___x_1982_;
}
}
v___jp_1972_:
{
uint8_t v___x_1974_;
v___x_1974_ = lean_uint64_dec_le(v_top_1971_, v___y_1973_);
if (v___x_1974_ == 0)
{
return v___y_1973_;
}
else
{
return v_top_1971_;
}
}
}
}

LEAN_EXPORT uint8_t orb_scroll_user_step(uint64_t v_content_1993_, uint64_t v_viewport_1994_, uint64_t v_top_1995_, uint64_t v_threshold_1996_){
_start:
{
uint64_t v___y_1998_; uint64_t v___y_2003_; uint64_t v___y_2004_; uint64_t v___y_2009_; uint64_t v___y_2010_; uint64_t v___y_2013_; uint8_t v___x_2017_;
v___x_2017_ = lean_uint64_dec_le(v_viewport_1994_, v_content_1993_);
if (v___x_2017_ == 0)
{
uint64_t v___x_2018_;
v___x_2018_ = 0ULL;
v___y_2013_ = v___x_2018_;
goto v___jp_2012_;
}
else
{
uint64_t v___x_2019_;
v___x_2019_ = lean_uint64_sub(v_content_1993_, v_viewport_1994_);
v___y_2013_ = v___x_2019_;
goto v___jp_2012_;
}
v___jp_1997_:
{
uint8_t v___x_1999_;
v___x_1999_ = lean_uint64_dec_le(v___y_1998_, v_threshold_1996_);
if (v___x_1999_ == 0)
{
uint8_t v___x_2000_;
v___x_2000_ = 0;
return v___x_2000_;
}
else
{
uint8_t v___x_2001_;
v___x_2001_ = 1;
return v___x_2001_;
}
}
v___jp_2002_:
{
uint8_t v___x_2005_;
v___x_2005_ = lean_uint64_dec_le(v___y_2004_, v___y_2003_);
if (v___x_2005_ == 0)
{
uint64_t v___x_2006_;
v___x_2006_ = 0ULL;
v___y_1998_ = v___x_2006_;
goto v___jp_1997_;
}
else
{
uint64_t v___x_2007_;
v___x_2007_ = lean_uint64_sub(v___y_2003_, v___y_2004_);
v___y_1998_ = v___x_2007_;
goto v___jp_1997_;
}
}
v___jp_2008_:
{
uint8_t v___x_2011_;
v___x_2011_ = lean_uint64_dec_le(v_top_1995_, v___y_2010_);
if (v___x_2011_ == 0)
{
v___y_2003_ = v___y_2009_;
v___y_2004_ = v___y_2010_;
goto v___jp_2002_;
}
else
{
v___y_2003_ = v___y_2009_;
v___y_2004_ = v_top_1995_;
goto v___jp_2002_;
}
}
v___jp_2012_:
{
uint8_t v___x_2014_;
v___x_2014_ = lean_uint64_dec_le(v_viewport_1994_, v_content_1993_);
if (v___x_2014_ == 0)
{
uint64_t v___x_2015_;
v___x_2015_ = 0ULL;
v___y_2009_ = v___y_2013_;
v___y_2010_ = v___x_2015_;
goto v___jp_2008_;
}
else
{
uint64_t v___x_2016_;
v___x_2016_ = lean_uint64_sub(v_content_1993_, v_viewport_1994_);
v___y_2009_ = v___y_2013_;
v___y_2010_ = v___x_2016_;
goto v___jp_2008_;
}
}
}
}

LEAN_EXPORT uint64_t orb_scroll_jump_step(uint64_t v_content_2030_, uint64_t v_viewport_2031_){
_start:
{
uint8_t v___x_2032_;
v___x_2032_ = lean_uint64_dec_le(v_viewport_2031_, v_content_2030_);
if (v___x_2032_ == 0)
{
uint64_t v___x_2033_;
v___x_2033_ = 0ULL;
return v___x_2033_;
}
else
{
uint64_t v___x_2034_;
v___x_2034_ = lean_uint64_sub(v_content_2030_, v_viewport_2031_);
return v___x_2034_;
}
}
}

LEAN_EXPORT uint64_t orb_scroll_correct(uint8_t v_pinned_2041_, uint64_t v_content_2042_, uint64_t v_viewport_2043_, uint64_t v_top_2044_){
_start:
{
uint64_t v___y_2046_; uint8_t v___x_2048_; uint8_t v___x_2049_;
v___x_2048_ = 1;
v___x_2049_ = lean_uint8_dec_eq(v_pinned_2041_, v___x_2048_);
if (v___x_2049_ == 0)
{
uint8_t v___x_2050_;
v___x_2050_ = lean_uint64_dec_le(v_viewport_2043_, v_content_2042_);
if (v___x_2050_ == 0)
{
uint64_t v___x_2051_;
v___x_2051_ = 0ULL;
v___y_2046_ = v___x_2051_;
goto v___jp_2045_;
}
else
{
uint64_t v___x_2052_;
v___x_2052_ = lean_uint64_sub(v_content_2042_, v_viewport_2043_);
v___y_2046_ = v___x_2052_;
goto v___jp_2045_;
}
}
else
{
uint8_t v___x_2053_;
v___x_2053_ = lean_uint64_dec_le(v_viewport_2043_, v_content_2042_);
if (v___x_2053_ == 0)
{
uint64_t v___x_2054_;
v___x_2054_ = 0ULL;
return v___x_2054_;
}
else
{
uint64_t v___x_2055_;
v___x_2055_ = lean_uint64_sub(v_content_2042_, v_viewport_2043_);
return v___x_2055_;
}
}
v___jp_2045_:
{
uint8_t v___x_2047_;
v___x_2047_ = lean_uint64_dec_le(v_top_2044_, v___y_2046_);
if (v___x_2047_ == 0)
{
return v___y_2046_;
}
else
{
return v_top_2044_;
}
}
}
}

LEAN_EXPORT uint8_t orb_scroll_shows_jump(uint8_t v_pinned_2066_, uint64_t v_content_2067_, uint64_t v_viewport_2068_, uint64_t v_top_2069_, uint64_t v_pillThreshold_2070_){
_start:
{
uint8_t v___x_2071_; uint64_t v___y_2073_; uint64_t v___y_2077_; uint64_t v___y_2078_; uint64_t v___y_2083_; uint64_t v___y_2084_; uint64_t v___y_2087_; uint8_t v___x_2091_;
v___x_2071_ = 0;
v___x_2091_ = lean_uint8_dec_eq(v_pinned_2066_, v___x_2071_);
if (v___x_2091_ == 0)
{
return v___x_2071_;
}
else
{
uint64_t v___x_2092_; uint8_t v___x_2093_;
v___x_2092_ = 18446744073709551591ULL;
v___x_2093_ = lean_uint64_dec_le(v_viewport_2068_, v___x_2092_);
if (v___x_2093_ == 0)
{
return v___x_2071_;
}
else
{
uint64_t v___x_2094_; uint64_t v___x_2095_; uint8_t v___x_2096_;
v___x_2094_ = 24ULL;
v___x_2095_ = lean_uint64_add(v_viewport_2068_, v___x_2094_);
v___x_2096_ = lean_uint64_dec_lt(v___x_2095_, v_content_2067_);
if (v___x_2096_ == 0)
{
return v___x_2071_;
}
else
{
uint8_t v___x_2097_;
v___x_2097_ = lean_uint64_dec_le(v_viewport_2068_, v_content_2067_);
if (v___x_2097_ == 0)
{
uint64_t v___x_2098_;
v___x_2098_ = 0ULL;
v___y_2087_ = v___x_2098_;
goto v___jp_2086_;
}
else
{
uint64_t v___x_2099_;
v___x_2099_ = lean_uint64_sub(v_content_2067_, v_viewport_2068_);
v___y_2087_ = v___x_2099_;
goto v___jp_2086_;
}
}
}
}
v___jp_2072_:
{
uint8_t v___x_2074_;
v___x_2074_ = lean_uint64_dec_lt(v_pillThreshold_2070_, v___y_2073_);
if (v___x_2074_ == 0)
{
return v___x_2071_;
}
else
{
uint8_t v___x_2075_;
v___x_2075_ = 1;
return v___x_2075_;
}
}
v___jp_2076_:
{
uint8_t v___x_2079_;
v___x_2079_ = lean_uint64_dec_le(v___y_2078_, v___y_2077_);
if (v___x_2079_ == 0)
{
uint64_t v___x_2080_;
v___x_2080_ = 0ULL;
v___y_2073_ = v___x_2080_;
goto v___jp_2072_;
}
else
{
uint64_t v___x_2081_;
v___x_2081_ = lean_uint64_sub(v___y_2077_, v___y_2078_);
v___y_2073_ = v___x_2081_;
goto v___jp_2072_;
}
}
v___jp_2082_:
{
uint8_t v___x_2085_;
v___x_2085_ = lean_uint64_dec_le(v_top_2069_, v___y_2084_);
if (v___x_2085_ == 0)
{
v___y_2077_ = v___y_2083_;
v___y_2078_ = v___y_2084_;
goto v___jp_2076_;
}
else
{
v___y_2077_ = v___y_2083_;
v___y_2078_ = v_top_2069_;
goto v___jp_2076_;
}
}
v___jp_2086_:
{
uint8_t v___x_2088_;
v___x_2088_ = lean_uint64_dec_le(v_viewport_2068_, v_content_2067_);
if (v___x_2088_ == 0)
{
uint64_t v___x_2089_;
v___x_2089_ = 0ULL;
v___y_2083_ = v___y_2087_;
v___y_2084_ = v___x_2089_;
goto v___jp_2082_;
}
else
{
uint64_t v___x_2090_;
v___x_2090_ = lean_uint64_sub(v_content_2067_, v_viewport_2068_);
v___y_2083_ = v___y_2087_;
v___y_2084_ = v___x_2090_;
goto v___jp_2082_;
}
}
}
}

LEAN_EXPORT uint64_t orb_stream_coalescer_step(uint8_t v_op_2112_, uint32_t v_shownLen_2113_, uint32_t v_pendingLen_2114_, uint32_t v_deltaLen_2115_){
_start:
{
uint32_t v___y_2117_; uint32_t v___y_2122_; uint8_t v___x_2130_; uint8_t v___x_2131_;
v___x_2130_ = 0;
v___x_2131_ = lean_uint8_dec_eq(v_op_2112_, v___x_2130_);
if (v___x_2131_ == 0)
{
uint8_t v___x_2132_; uint8_t v___x_2133_;
v___x_2132_ = 1;
v___x_2133_ = lean_uint8_dec_eq(v_op_2112_, v___x_2132_);
if (v___x_2133_ == 0)
{
uint64_t v___x_2134_;
v___x_2134_ = 0ULL;
return v___x_2134_;
}
else
{
uint32_t v___x_2135_; uint8_t v___x_2136_;
v___x_2135_ = 0;
v___x_2136_ = lean_uint32_dec_eq(v_pendingLen_2114_, v___x_2135_);
if (v___x_2136_ == 0)
{
uint32_t v___x_2137_; uint32_t v___x_2138_; uint8_t v___x_2139_;
v___x_2137_ = 4294967295;
v___x_2138_ = lean_uint32_sub(v___x_2137_, v_pendingLen_2114_);
v___x_2139_ = lean_uint32_dec_le(v_shownLen_2113_, v___x_2138_);
if (v___x_2139_ == 0)
{
v___y_2117_ = v___x_2137_;
goto v___jp_2116_;
}
else
{
uint32_t v___x_2140_;
v___x_2140_ = lean_uint32_add(v_shownLen_2113_, v_pendingLen_2114_);
v___y_2117_ = v___x_2140_;
goto v___jp_2116_;
}
}
else
{
uint64_t v___x_2141_;
v___x_2141_ = lean_uint32_to_uint64(v_shownLen_2113_);
return v___x_2141_;
}
}
}
else
{
uint32_t v___x_2142_; uint32_t v___x_2143_; uint8_t v___x_2144_;
v___x_2142_ = 4294967295;
v___x_2143_ = lean_uint32_sub(v___x_2142_, v_deltaLen_2115_);
v___x_2144_ = lean_uint32_dec_le(v_pendingLen_2114_, v___x_2143_);
if (v___x_2144_ == 0)
{
v___y_2122_ = v___x_2142_;
goto v___jp_2121_;
}
else
{
uint32_t v___x_2145_;
v___x_2145_ = lean_uint32_add(v_pendingLen_2114_, v_deltaLen_2115_);
v___y_2122_ = v___x_2145_;
goto v___jp_2121_;
}
}
v___jp_2116_:
{
uint64_t v___x_2118_; uint64_t v___x_2119_; uint64_t v___x_2120_;
v___x_2118_ = lean_uint32_to_uint64(v___y_2117_);
v___x_2119_ = 9223372036854775808ULL;
v___x_2120_ = lean_uint64_lor(v___x_2118_, v___x_2119_);
return v___x_2120_;
}
v___jp_2121_:
{
uint64_t v___x_2123_; uint64_t v___x_2124_; uint64_t v___x_2125_; uint64_t v___x_2126_; uint64_t v___x_2127_; uint64_t v___x_2128_; uint64_t v___x_2129_;
v___x_2123_ = lean_uint32_to_uint64(v_shownLen_2113_);
v___x_2124_ = lean_uint32_to_uint64(v___y_2122_);
v___x_2125_ = 2147483647ULL;
v___x_2126_ = lean_uint64_land(v___x_2124_, v___x_2125_);
v___x_2127_ = 32ULL;
v___x_2128_ = lean_uint64_shift_left(v___x_2126_, v___x_2127_);
v___x_2129_ = lean_uint64_lor(v___x_2123_, v___x_2128_);
return v___x_2129_;
}
}
}

LEAN_EXPORT uint64_t orb_stream_fence_step(uint8_t v_openKind_2213_, uint32_t v_openCount_2214_, uint8_t v_markerKind_2215_, uint32_t v_markerCount_2216_){
_start:
{
uint8_t v___y_2218_; uint32_t v___y_2219_; uint8_t v___y_2226_; uint8_t v___y_2231_; uint8_t v___x_2244_; uint8_t v___x_2248_;
v___x_2244_ = 0;
v___x_2248_ = lean_uint8_dec_eq(v_openKind_2213_, v___x_2244_);
if (v___x_2248_ == 0)
{
uint8_t v___x_2249_;
v___x_2249_ = lean_uint8_dec_eq(v_markerKind_2215_, v_openKind_2213_);
if (v___x_2249_ == 0)
{
v___y_2231_ = v_openKind_2213_;
goto v___jp_2230_;
}
else
{
uint8_t v___x_2250_;
v___x_2250_ = lean_uint32_dec_le(v_openCount_2214_, v_markerCount_2216_);
if (v___x_2250_ == 0)
{
v___y_2231_ = v_openKind_2213_;
goto v___jp_2230_;
}
else
{
uint32_t v___x_2251_; uint8_t v___x_2252_;
v___x_2251_ = 3;
v___x_2252_ = lean_uint32_dec_le(v___x_2251_, v_markerCount_2216_);
if (v___x_2252_ == 0)
{
v___y_2231_ = v_openKind_2213_;
goto v___jp_2230_;
}
else
{
v___y_2231_ = v___x_2244_;
goto v___jp_2230_;
}
}
}
}
else
{
uint8_t v___x_2253_; uint8_t v___x_2254_;
v___x_2253_ = 1;
v___x_2254_ = lean_uint8_dec_eq(v_markerKind_2215_, v___x_2253_);
if (v___x_2254_ == 0)
{
uint8_t v___x_2255_; uint8_t v___x_2256_;
v___x_2255_ = 2;
v___x_2256_ = lean_uint8_dec_eq(v_markerKind_2215_, v___x_2255_);
if (v___x_2256_ == 0)
{
v___y_2231_ = v___x_2244_;
goto v___jp_2230_;
}
else
{
goto v___jp_2245_;
}
}
else
{
goto v___jp_2245_;
}
}
v___jp_2217_:
{
uint64_t v___x_2220_; uint64_t v___x_2221_; uint64_t v___x_2222_; uint64_t v___x_2223_; uint64_t v___x_2224_;
v___x_2220_ = lean_uint8_to_uint64(v___y_2218_);
v___x_2221_ = lean_uint32_to_uint64(v___y_2219_);
v___x_2222_ = 32ULL;
v___x_2223_ = lean_uint64_shift_left(v___x_2221_, v___x_2222_);
v___x_2224_ = lean_uint64_lor(v___x_2220_, v___x_2223_);
return v___x_2224_;
}
v___jp_2225_:
{
uint32_t v___x_2227_; uint8_t v___x_2228_;
v___x_2227_ = 3;
v___x_2228_ = lean_uint32_dec_le(v___x_2227_, v_markerCount_2216_);
if (v___x_2228_ == 0)
{
uint32_t v___x_2229_;
v___x_2229_ = 0;
v___y_2218_ = v___y_2226_;
v___y_2219_ = v___x_2229_;
goto v___jp_2217_;
}
else
{
v___y_2218_ = v___y_2226_;
v___y_2219_ = v_markerCount_2216_;
goto v___jp_2217_;
}
}
v___jp_2230_:
{
uint8_t v___x_2232_; uint8_t v___x_2233_;
v___x_2232_ = 0;
v___x_2233_ = lean_uint8_dec_eq(v_openKind_2213_, v___x_2232_);
if (v___x_2233_ == 0)
{
uint8_t v___x_2234_;
v___x_2234_ = lean_uint8_dec_eq(v_markerKind_2215_, v_openKind_2213_);
if (v___x_2234_ == 0)
{
v___y_2218_ = v___y_2231_;
v___y_2219_ = v_openCount_2214_;
goto v___jp_2217_;
}
else
{
uint8_t v___x_2235_;
v___x_2235_ = lean_uint32_dec_le(v_openCount_2214_, v_markerCount_2216_);
if (v___x_2235_ == 0)
{
v___y_2218_ = v___y_2231_;
v___y_2219_ = v_openCount_2214_;
goto v___jp_2217_;
}
else
{
uint32_t v___x_2236_; uint8_t v___x_2237_;
v___x_2236_ = 3;
v___x_2237_ = lean_uint32_dec_le(v___x_2236_, v_markerCount_2216_);
if (v___x_2237_ == 0)
{
v___y_2218_ = v___y_2231_;
v___y_2219_ = v_openCount_2214_;
goto v___jp_2217_;
}
else
{
uint32_t v___x_2238_;
v___x_2238_ = 0;
v___y_2218_ = v___y_2231_;
v___y_2219_ = v___x_2238_;
goto v___jp_2217_;
}
}
}
}
else
{
uint8_t v___x_2239_; uint8_t v___x_2240_;
v___x_2239_ = 1;
v___x_2240_ = lean_uint8_dec_eq(v_markerKind_2215_, v___x_2239_);
if (v___x_2240_ == 0)
{
uint8_t v___x_2241_; uint8_t v___x_2242_;
v___x_2241_ = 2;
v___x_2242_ = lean_uint8_dec_eq(v_markerKind_2215_, v___x_2241_);
if (v___x_2242_ == 0)
{
uint32_t v___x_2243_;
v___x_2243_ = 0;
v___y_2218_ = v___y_2231_;
v___y_2219_ = v___x_2243_;
goto v___jp_2217_;
}
else
{
v___y_2226_ = v___y_2231_;
goto v___jp_2225_;
}
}
else
{
v___y_2226_ = v___y_2231_;
goto v___jp_2225_;
}
}
}
v___jp_2245_:
{
uint32_t v___x_2246_; uint8_t v___x_2247_;
v___x_2246_ = 3;
v___x_2247_ = lean_uint32_dec_le(v___x_2246_, v_markerCount_2216_);
if (v___x_2247_ == 0)
{
v___y_2231_ = v___x_2244_;
goto v___jp_2230_;
}
else
{
v___y_2231_ = v_markerKind_2215_;
goto v___jp_2230_;
}
}
}
}

LEAN_EXPORT uint64_t orb_stream_commit_step(uint8_t v_tick_2267_, uint8_t v_openKind_2268_, uint32_t v_openCount_2269_, uint8_t v_lineBlank_2270_, uint8_t v_lineTick_2271_, uint8_t v_markerKind_2272_, uint32_t v_markerCount_2273_, uint32_t v_pos_2274_, uint32_t v_commit_2275_){
_start:
{
uint32_t v___y_2277_; uint32_t v___y_2278_; uint8_t v___y_2279_; uint32_t v___y_2280_; uint32_t v___y_2290_; uint8_t v___y_2291_; uint8_t v___y_2292_; uint32_t v___y_2293_; uint8_t v___x_2296_; uint8_t v___y_2298_; uint8_t v___y_2299_; uint8_t v___y_2300_; uint32_t v___y_2301_; uint32_t v___y_2309_; uint8_t v___y_2310_; uint8_t v___y_2311_; uint8_t v___y_2312_; uint32_t v___y_2315_; uint8_t v___y_2316_; uint8_t v___y_2317_; uint8_t v___y_2320_; uint8_t v___y_2321_; uint32_t v___y_2322_; uint8_t v___y_2328_; uint8_t v___y_2329_; uint8_t v___y_2336_; uint8_t v___y_2337_; uint8_t v___y_2341_; uint8_t v___x_2351_;
v___x_2296_ = 1;
v___x_2351_ = lean_uint8_dec_eq(v_lineTick_2271_, v___x_2296_);
if (v___x_2351_ == 0)
{
uint8_t v___x_2352_;
v___x_2352_ = lean_uint8_dec_eq(v_tick_2267_, v___x_2296_);
if (v___x_2352_ == 0)
{
uint8_t v___x_2353_;
v___x_2353_ = 0;
v___y_2341_ = v___x_2353_;
goto v___jp_2340_;
}
else
{
v___y_2341_ = v___x_2296_;
goto v___jp_2340_;
}
}
else
{
uint8_t v___x_2354_;
v___x_2354_ = lean_uint8_dec_eq(v_tick_2267_, v___x_2296_);
if (v___x_2354_ == 0)
{
v___y_2341_ = v___x_2296_;
goto v___jp_2340_;
}
else
{
uint8_t v___x_2355_;
v___x_2355_ = 0;
v___y_2341_ = v___x_2355_;
goto v___jp_2340_;
}
}
v___jp_2276_:
{
uint32_t v___x_2281_; uint32_t v___x_2282_; uint32_t v_lo32_2283_; uint64_t v___x_2284_; uint64_t v___x_2285_; uint64_t v___x_2286_; uint64_t v___x_2287_; uint64_t v___x_2288_;
v___x_2281_ = lean_uint8_to_uint32(v___y_2279_);
v___x_2282_ = lean_uint32_lor(v___x_2281_, v___y_2277_);
v_lo32_2283_ = lean_uint32_lor(v___x_2282_, v___y_2280_);
v___x_2284_ = lean_uint32_to_uint64(v_lo32_2283_);
v___x_2285_ = lean_uint32_to_uint64(v___y_2278_);
v___x_2286_ = 32ULL;
v___x_2287_ = lean_uint64_shift_left(v___x_2285_, v___x_2286_);
v___x_2288_ = lean_uint64_lor(v___x_2284_, v___x_2287_);
return v___x_2288_;
}
v___jp_2289_:
{
if (v___y_2291_ == 0)
{
uint32_t v___x_2294_;
v___x_2294_ = 0;
v___y_2277_ = v___y_2293_;
v___y_2278_ = v___y_2290_;
v___y_2279_ = v___y_2292_;
v___y_2280_ = v___x_2294_;
goto v___jp_2276_;
}
else
{
uint32_t v___x_2295_;
v___x_2295_ = 65536;
v___y_2277_ = v___y_2293_;
v___y_2278_ = v___y_2290_;
v___y_2279_ = v___y_2292_;
v___y_2280_ = v___x_2295_;
goto v___jp_2276_;
}
}
v___jp_2297_:
{
uint8_t v___x_2302_;
v___x_2302_ = lean_uint8_dec_eq(v___y_2298_, v___x_2296_);
if (v___x_2302_ == 0)
{
uint8_t v___x_2303_; uint8_t v___x_2304_;
v___x_2303_ = 2;
v___x_2304_ = lean_uint8_dec_eq(v___y_2298_, v___x_2303_);
if (v___x_2304_ == 0)
{
uint32_t v___x_2305_;
v___x_2305_ = 0;
v___y_2290_ = v___y_2301_;
v___y_2291_ = v___y_2299_;
v___y_2292_ = v___y_2300_;
v___y_2293_ = v___x_2305_;
goto v___jp_2289_;
}
else
{
uint32_t v___x_2306_;
v___x_2306_ = 512;
v___y_2290_ = v___y_2301_;
v___y_2291_ = v___y_2299_;
v___y_2292_ = v___y_2300_;
v___y_2293_ = v___x_2306_;
goto v___jp_2289_;
}
}
else
{
uint32_t v___x_2307_;
v___x_2307_ = 256;
v___y_2290_ = v___y_2301_;
v___y_2291_ = v___y_2299_;
v___y_2292_ = v___y_2300_;
v___y_2293_ = v___x_2307_;
goto v___jp_2289_;
}
}
v___jp_2308_:
{
uint8_t v___x_2313_;
v___x_2313_ = lean_uint8_dec_eq(v___y_2312_, v___x_2296_);
if (v___x_2313_ == 0)
{
v___y_2298_ = v___y_2310_;
v___y_2299_ = v___x_2313_;
v___y_2300_ = v___y_2311_;
v___y_2301_ = v_commit_2275_;
goto v___jp_2297_;
}
else
{
v___y_2298_ = v___y_2310_;
v___y_2299_ = v___x_2313_;
v___y_2300_ = v___y_2311_;
v___y_2301_ = v___y_2309_;
goto v___jp_2297_;
}
}
v___jp_2314_:
{
uint8_t v___x_2318_;
v___x_2318_ = 0;
v___y_2309_ = v___y_2315_;
v___y_2310_ = v___y_2316_;
v___y_2311_ = v___y_2317_;
v___y_2312_ = v___x_2318_;
goto v___jp_2308_;
}
v___jp_2319_:
{
uint8_t v___x_2323_;
v___x_2323_ = lean_uint8_dec_eq(v_lineBlank_2270_, v___x_2296_);
if (v___x_2323_ == 0)
{
v___y_2315_ = v___y_2322_;
v___y_2316_ = v___y_2320_;
v___y_2317_ = v___y_2321_;
goto v___jp_2314_;
}
else
{
uint8_t v___x_2324_; uint8_t v___x_2325_;
v___x_2324_ = 0;
v___x_2325_ = lean_uint8_dec_eq(v___y_2321_, v___x_2324_);
if (v___x_2325_ == 0)
{
v___y_2315_ = v___y_2322_;
v___y_2316_ = v___y_2320_;
v___y_2317_ = v___y_2321_;
goto v___jp_2314_;
}
else
{
uint8_t v___x_2326_;
v___x_2326_ = lean_uint8_dec_eq(v___y_2320_, v___x_2324_);
if (v___x_2326_ == 0)
{
v___y_2315_ = v___y_2322_;
v___y_2316_ = v___y_2320_;
v___y_2317_ = v___y_2321_;
goto v___jp_2314_;
}
else
{
v___y_2309_ = v___y_2322_;
v___y_2310_ = v___y_2320_;
v___y_2311_ = v___y_2321_;
v___y_2312_ = v___x_2296_;
goto v___jp_2308_;
}
}
}
}
v___jp_2327_:
{
uint32_t v___x_2330_; uint8_t v___x_2331_;
v___x_2330_ = 4294967294;
v___x_2331_ = lean_uint32_dec_le(v_pos_2274_, v___x_2330_);
if (v___x_2331_ == 0)
{
uint32_t v___x_2332_;
v___x_2332_ = 4294967295;
v___y_2320_ = v___y_2329_;
v___y_2321_ = v___y_2328_;
v___y_2322_ = v___x_2332_;
goto v___jp_2319_;
}
else
{
uint32_t v___x_2333_; uint32_t v___x_2334_;
v___x_2333_ = 1;
v___x_2334_ = lean_uint32_add(v_pos_2274_, v___x_2333_);
v___y_2320_ = v___y_2329_;
v___y_2321_ = v___y_2328_;
v___y_2322_ = v___x_2334_;
goto v___jp_2319_;
}
}
v___jp_2335_:
{
uint32_t v___x_2338_; uint8_t v___x_2339_;
v___x_2338_ = 3;
v___x_2339_ = lean_uint32_dec_le(v___x_2338_, v_markerCount_2273_);
if (v___x_2339_ == 0)
{
v___y_2328_ = v___y_2337_;
v___y_2329_ = v___y_2336_;
goto v___jp_2327_;
}
else
{
v___y_2328_ = v___y_2337_;
v___y_2329_ = v_markerKind_2272_;
goto v___jp_2327_;
}
}
v___jp_2340_:
{
uint8_t v___x_2342_; uint8_t v___x_2343_;
v___x_2342_ = 0;
v___x_2343_ = lean_uint8_dec_eq(v_openKind_2268_, v___x_2342_);
if (v___x_2343_ == 0)
{
uint8_t v___x_2344_;
v___x_2344_ = lean_uint8_dec_eq(v_markerKind_2272_, v_openKind_2268_);
if (v___x_2344_ == 0)
{
v___y_2328_ = v___y_2341_;
v___y_2329_ = v_openKind_2268_;
goto v___jp_2327_;
}
else
{
uint8_t v___x_2345_;
v___x_2345_ = lean_uint32_dec_le(v_openCount_2269_, v_markerCount_2273_);
if (v___x_2345_ == 0)
{
v___y_2328_ = v___y_2341_;
v___y_2329_ = v_openKind_2268_;
goto v___jp_2327_;
}
else
{
uint32_t v___x_2346_; uint8_t v___x_2347_;
v___x_2346_ = 3;
v___x_2347_ = lean_uint32_dec_le(v___x_2346_, v_markerCount_2273_);
if (v___x_2347_ == 0)
{
v___y_2328_ = v___y_2341_;
v___y_2329_ = v_openKind_2268_;
goto v___jp_2327_;
}
else
{
v___y_2328_ = v___y_2341_;
v___y_2329_ = v___x_2342_;
goto v___jp_2327_;
}
}
}
}
else
{
uint8_t v___x_2348_;
v___x_2348_ = lean_uint8_dec_eq(v_markerKind_2272_, v___x_2296_);
if (v___x_2348_ == 0)
{
uint8_t v___x_2349_; uint8_t v___x_2350_;
v___x_2349_ = 2;
v___x_2350_ = lean_uint8_dec_eq(v_markerKind_2272_, v___x_2349_);
if (v___x_2350_ == 0)
{
v___y_2328_ = v___y_2341_;
v___y_2329_ = v___x_2342_;
goto v___jp_2327_;
}
else
{
v___y_2336_ = v___x_2342_;
v___y_2337_ = v___y_2341_;
goto v___jp_2335_;
}
}
else
{
v___y_2336_ = v___x_2342_;
v___y_2337_ = v___y_2341_;
goto v___jp_2335_;
}
}
}
}
}

LEAN_EXPORT uint64_t orb_stream_token_cost_step(uint64_t v_prevCost_2376_, uint64_t v_newAdvance_2377_, uint64_t v_tailBytes_2378_){
_start:
{
uint64_t v___y_2380_; uint64_t v___x_2385_; uint64_t v___x_2386_; uint8_t v___x_2387_;
v___x_2385_ = 18446744073709551615ULL;
v___x_2386_ = lean_uint64_sub(v___x_2385_, v_tailBytes_2378_);
v___x_2387_ = lean_uint64_dec_le(v_newAdvance_2377_, v___x_2386_);
if (v___x_2387_ == 0)
{
v___y_2380_ = v___x_2385_;
goto v___jp_2379_;
}
else
{
uint64_t v___x_2388_;
v___x_2388_ = lean_uint64_add(v_newAdvance_2377_, v_tailBytes_2378_);
v___y_2380_ = v___x_2388_;
goto v___jp_2379_;
}
v___jp_2379_:
{
uint64_t v___x_2381_; uint64_t v___x_2382_; uint8_t v___x_2383_;
v___x_2381_ = 18446744073709551615ULL;
v___x_2382_ = lean_uint64_sub(v___x_2381_, v___y_2380_);
v___x_2383_ = lean_uint64_dec_le(v_prevCost_2376_, v___x_2382_);
if (v___x_2383_ == 0)
{
return v___x_2381_;
}
else
{
uint64_t v___x_2384_;
v___x_2384_ = lean_uint64_add(v_prevCost_2376_, v___y_2380_);
return v___x_2384_;
}
}
}
}

LEAN_EXPORT uint8_t orb_mission_state_classify(uint8_t v_stateId_2397_){
_start:
{
uint8_t v___x_2398_; uint8_t v___x_2399_;
v___x_2398_ = 8;
v___x_2399_ = lean_uint8_dec_le(v_stateId_2397_, v___x_2398_);
if (v___x_2399_ == 0)
{
uint8_t v___x_2400_; uint8_t v___x_2401_;
v___x_2400_ = 10;
v___x_2401_ = lean_uint8_dec_le(v_stateId_2397_, v___x_2400_);
if (v___x_2401_ == 0)
{
uint8_t v___x_2402_; uint8_t v___x_2403_;
v___x_2402_ = 15;
v___x_2403_ = lean_uint8_dec_le(v_stateId_2397_, v___x_2402_);
if (v___x_2403_ == 0)
{
uint8_t v___x_2404_; uint8_t v___x_2405_;
v___x_2404_ = 16;
v___x_2405_ = lean_uint8_dec_eq(v_stateId_2397_, v___x_2404_);
if (v___x_2405_ == 0)
{
uint8_t v___x_2406_; uint8_t v___x_2407_;
v___x_2406_ = 21;
v___x_2407_ = lean_uint8_dec_le(v_stateId_2397_, v___x_2406_);
if (v___x_2407_ == 0)
{
uint8_t v___x_2408_; uint8_t v___x_2409_;
v___x_2408_ = 23;
v___x_2409_ = lean_uint8_dec_le(v_stateId_2397_, v___x_2408_);
if (v___x_2409_ == 0)
{
uint8_t v___x_2410_; uint8_t v___x_2411_;
v___x_2410_ = 24;
v___x_2411_ = lean_uint8_dec_eq(v_stateId_2397_, v___x_2410_);
if (v___x_2411_ == 0)
{
uint8_t v___x_2412_; uint8_t v___x_2413_;
v___x_2412_ = 26;
v___x_2413_ = lean_uint8_dec_le(v_stateId_2397_, v___x_2412_);
if (v___x_2413_ == 0)
{
uint8_t v___x_2414_; uint8_t v___x_2415_;
v___x_2414_ = 28;
v___x_2415_ = lean_uint8_dec_le(v_stateId_2397_, v___x_2414_);
if (v___x_2415_ == 0)
{
uint8_t v___x_2416_;
v___x_2416_ = 9;
return v___x_2416_;
}
else
{
return v___x_2398_;
}
}
else
{
uint8_t v___x_2417_;
v___x_2417_ = 7;
return v___x_2417_;
}
}
else
{
uint8_t v___x_2418_;
v___x_2418_ = 5;
return v___x_2418_;
}
}
else
{
uint8_t v___x_2419_;
v___x_2419_ = 6;
return v___x_2419_;
}
}
else
{
uint8_t v___x_2420_;
v___x_2420_ = 2;
return v___x_2420_;
}
}
else
{
uint8_t v___x_2421_;
v___x_2421_ = 1;
return v___x_2421_;
}
}
else
{
uint8_t v___x_2422_;
v___x_2422_ = 0;
return v___x_2422_;
}
}
else
{
uint8_t v___x_2423_;
v___x_2423_ = 4;
return v___x_2423_;
}
}
else
{
uint8_t v___x_2424_;
v___x_2424_ = 3;
return v___x_2424_;
}
}
}

LEAN_EXPORT uint8_t orb_mission_sort_rank(uint8_t v_stateId_2429_){
_start:
{
uint8_t v___x_2430_; uint8_t v___x_2431_;
v___x_2430_ = 8;
v___x_2431_ = lean_uint8_dec_le(v_stateId_2429_, v___x_2430_);
if (v___x_2431_ == 0)
{
uint8_t v___x_2432_; uint8_t v___x_2433_;
v___x_2432_ = 10;
v___x_2433_ = lean_uint8_dec_le(v_stateId_2429_, v___x_2432_);
if (v___x_2433_ == 0)
{
uint8_t v___x_2434_; uint8_t v___x_2435_;
v___x_2434_ = 15;
v___x_2435_ = lean_uint8_dec_le(v_stateId_2429_, v___x_2434_);
if (v___x_2435_ == 0)
{
uint8_t v___x_2436_; uint8_t v___x_2437_;
v___x_2436_ = 16;
v___x_2437_ = lean_uint8_dec_eq(v_stateId_2429_, v___x_2436_);
if (v___x_2437_ == 0)
{
uint8_t v___x_2438_; uint8_t v___x_2439_;
v___x_2438_ = 21;
v___x_2439_ = lean_uint8_dec_le(v_stateId_2429_, v___x_2438_);
if (v___x_2439_ == 0)
{
uint8_t v___x_2440_; uint8_t v___x_2441_;
v___x_2440_ = 23;
v___x_2441_ = lean_uint8_dec_le(v_stateId_2429_, v___x_2440_);
if (v___x_2441_ == 0)
{
uint8_t v___x_2442_; uint8_t v___x_2443_;
v___x_2442_ = 24;
v___x_2443_ = lean_uint8_dec_eq(v_stateId_2429_, v___x_2442_);
if (v___x_2443_ == 0)
{
uint8_t v___x_2444_; uint8_t v___x_2445_;
v___x_2444_ = 26;
v___x_2445_ = lean_uint8_dec_le(v_stateId_2429_, v___x_2444_);
if (v___x_2445_ == 0)
{
uint8_t v___x_2446_; uint8_t v___x_2447_;
v___x_2446_ = 28;
v___x_2447_ = lean_uint8_dec_le(v_stateId_2429_, v___x_2446_);
if (v___x_2447_ == 0)
{
uint8_t v___x_2448_;
v___x_2448_ = 9;
return v___x_2448_;
}
else
{
return v___x_2430_;
}
}
else
{
uint8_t v___x_2449_;
v___x_2449_ = 7;
return v___x_2449_;
}
}
else
{
uint8_t v___x_2450_;
v___x_2450_ = 5;
return v___x_2450_;
}
}
else
{
uint8_t v___x_2451_;
v___x_2451_ = 6;
return v___x_2451_;
}
}
else
{
uint8_t v___x_2452_;
v___x_2452_ = 2;
return v___x_2452_;
}
}
else
{
uint8_t v___x_2453_;
v___x_2453_ = 1;
return v___x_2453_;
}
}
else
{
uint8_t v___x_2454_;
v___x_2454_ = 0;
return v___x_2454_;
}
}
else
{
uint8_t v___x_2455_;
v___x_2455_ = 4;
return v___x_2455_;
}
}
else
{
uint8_t v___x_2456_;
v___x_2456_ = 3;
return v___x_2456_;
}
}
}

LEAN_EXPORT uint32_t orb_mission_flags(uint8_t v_stateId_2547_){
_start:
{
uint32_t v___y_2549_; uint8_t v___y_2587_; uint8_t v___x_2613_; uint8_t v___x_2614_;
v___x_2613_ = 8;
v___x_2614_ = lean_uint8_dec_le(v_stateId_2547_, v___x_2613_);
if (v___x_2614_ == 0)
{
uint8_t v___x_2615_; uint8_t v___x_2616_;
v___x_2615_ = 10;
v___x_2616_ = lean_uint8_dec_le(v_stateId_2547_, v___x_2615_);
if (v___x_2616_ == 0)
{
uint8_t v___x_2617_; uint8_t v___x_2618_;
v___x_2617_ = 15;
v___x_2618_ = lean_uint8_dec_le(v_stateId_2547_, v___x_2617_);
if (v___x_2618_ == 0)
{
uint8_t v___x_2619_; uint8_t v___x_2620_;
v___x_2619_ = 16;
v___x_2620_ = lean_uint8_dec_eq(v_stateId_2547_, v___x_2619_);
if (v___x_2620_ == 0)
{
uint8_t v___x_2621_; uint8_t v___x_2622_;
v___x_2621_ = 21;
v___x_2622_ = lean_uint8_dec_le(v_stateId_2547_, v___x_2621_);
if (v___x_2622_ == 0)
{
uint8_t v___x_2623_; uint8_t v___x_2624_;
v___x_2623_ = 23;
v___x_2624_ = lean_uint8_dec_le(v_stateId_2547_, v___x_2623_);
if (v___x_2624_ == 0)
{
uint8_t v___x_2625_; uint8_t v___x_2626_;
v___x_2625_ = 24;
v___x_2626_ = lean_uint8_dec_eq(v_stateId_2547_, v___x_2625_);
if (v___x_2626_ == 0)
{
uint8_t v___x_2627_; uint8_t v___x_2628_;
v___x_2627_ = 26;
v___x_2628_ = lean_uint8_dec_le(v_stateId_2547_, v___x_2627_);
if (v___x_2628_ == 0)
{
uint8_t v___x_2629_; uint8_t v___x_2630_;
v___x_2629_ = 28;
v___x_2630_ = lean_uint8_dec_le(v_stateId_2547_, v___x_2629_);
if (v___x_2630_ == 0)
{
uint8_t v___x_2631_;
v___x_2631_ = 9;
v___y_2587_ = v___x_2631_;
goto v___jp_2586_;
}
else
{
v___y_2587_ = v___x_2613_;
goto v___jp_2586_;
}
}
else
{
uint8_t v___x_2632_;
v___x_2632_ = 7;
v___y_2587_ = v___x_2632_;
goto v___jp_2586_;
}
}
else
{
uint8_t v___x_2633_;
v___x_2633_ = 5;
v___y_2587_ = v___x_2633_;
goto v___jp_2586_;
}
}
else
{
uint8_t v___x_2634_;
v___x_2634_ = 6;
v___y_2587_ = v___x_2634_;
goto v___jp_2586_;
}
}
else
{
uint8_t v___x_2635_;
v___x_2635_ = 2;
v___y_2587_ = v___x_2635_;
goto v___jp_2586_;
}
}
else
{
uint8_t v___x_2636_;
v___x_2636_ = 1;
v___y_2587_ = v___x_2636_;
goto v___jp_2586_;
}
}
else
{
uint8_t v___x_2637_;
v___x_2637_ = 0;
v___y_2587_ = v___x_2637_;
goto v___jp_2586_;
}
}
else
{
uint8_t v___x_2638_;
v___x_2638_ = 4;
v___y_2587_ = v___x_2638_;
goto v___jp_2586_;
}
}
else
{
uint8_t v___x_2639_;
v___x_2639_ = 3;
v___y_2587_ = v___x_2639_;
goto v___jp_2586_;
}
v___jp_2548_:
{
uint8_t v___x_2550_; uint8_t v___x_2551_;
v___x_2550_ = 11;
v___x_2551_ = lean_uint8_dec_eq(v_stateId_2547_, v___x_2550_);
if (v___x_2551_ == 0)
{
uint8_t v___x_2552_; uint8_t v___x_2553_;
v___x_2552_ = 12;
v___x_2553_ = lean_uint8_dec_eq(v_stateId_2547_, v___x_2552_);
if (v___x_2553_ == 0)
{
uint8_t v___x_2554_; uint8_t v___x_2555_;
v___x_2554_ = 24;
v___x_2555_ = lean_uint8_dec_eq(v_stateId_2547_, v___x_2554_);
if (v___x_2555_ == 0)
{
uint8_t v___x_2556_; uint8_t v___x_2557_;
v___x_2556_ = 25;
v___x_2557_ = lean_uint8_dec_eq(v_stateId_2547_, v___x_2556_);
if (v___x_2557_ == 0)
{
uint8_t v___x_2558_; uint8_t v___x_2559_;
v___x_2558_ = 26;
v___x_2559_ = lean_uint8_dec_eq(v_stateId_2547_, v___x_2558_);
if (v___x_2559_ == 0)
{
uint8_t v___x_2560_; uint8_t v___x_2561_;
v___x_2560_ = 16;
v___x_2561_ = lean_uint8_dec_eq(v_stateId_2547_, v___x_2560_);
if (v___x_2561_ == 0)
{
uint8_t v___x_2562_; uint8_t v___x_2563_;
v___x_2562_ = 17;
v___x_2563_ = lean_uint8_dec_eq(v_stateId_2547_, v___x_2562_);
if (v___x_2563_ == 0)
{
uint8_t v___x_2564_; uint8_t v___x_2565_;
v___x_2564_ = 20;
v___x_2565_ = lean_uint8_dec_eq(v_stateId_2547_, v___x_2564_);
if (v___x_2565_ == 0)
{
uint8_t v___x_2566_; uint8_t v___x_2567_;
v___x_2566_ = 22;
v___x_2567_ = lean_uint8_dec_eq(v_stateId_2547_, v___x_2566_);
if (v___x_2567_ == 0)
{
return v___y_2549_;
}
else
{
uint32_t v___x_2568_; uint32_t v___x_2569_;
v___x_2568_ = 24;
v___x_2569_ = lean_uint32_lor(v___y_2549_, v___x_2568_);
return v___x_2569_;
}
}
else
{
uint32_t v___x_2570_; uint32_t v___x_2571_;
v___x_2570_ = 24;
v___x_2571_ = lean_uint32_lor(v___y_2549_, v___x_2570_);
return v___x_2571_;
}
}
else
{
uint32_t v___x_2572_; uint32_t v___x_2573_;
v___x_2572_ = 24;
v___x_2573_ = lean_uint32_lor(v___y_2549_, v___x_2572_);
return v___x_2573_;
}
}
else
{
uint32_t v___x_2574_; uint32_t v___x_2575_;
v___x_2574_ = 24;
v___x_2575_ = lean_uint32_lor(v___y_2549_, v___x_2574_);
return v___x_2575_;
}
}
else
{
uint32_t v___x_2576_; uint32_t v___x_2577_;
v___x_2576_ = 8;
v___x_2577_ = lean_uint32_lor(v___y_2549_, v___x_2576_);
return v___x_2577_;
}
}
else
{
uint32_t v___x_2578_; uint32_t v___x_2579_;
v___x_2578_ = 8;
v___x_2579_ = lean_uint32_lor(v___y_2549_, v___x_2578_);
return v___x_2579_;
}
}
else
{
uint32_t v___x_2580_; uint32_t v___x_2581_;
v___x_2580_ = 8;
v___x_2581_ = lean_uint32_lor(v___y_2549_, v___x_2580_);
return v___x_2581_;
}
}
else
{
uint32_t v___x_2582_; uint32_t v___x_2583_;
v___x_2582_ = 8;
v___x_2583_ = lean_uint32_lor(v___y_2549_, v___x_2582_);
return v___x_2583_;
}
}
else
{
uint32_t v___x_2584_; uint32_t v___x_2585_;
v___x_2584_ = 8;
v___x_2585_ = lean_uint32_lor(v___y_2549_, v___x_2584_);
return v___x_2585_;
}
}
v___jp_2586_:
{
uint8_t v___x_2588_; uint8_t v___x_2589_;
v___x_2588_ = 0;
v___x_2589_ = lean_uint8_dec_eq(v___y_2587_, v___x_2588_);
if (v___x_2589_ == 0)
{
uint8_t v___x_2590_; uint8_t v___x_2591_;
v___x_2590_ = 1;
v___x_2591_ = lean_uint8_dec_eq(v___y_2587_, v___x_2590_);
if (v___x_2591_ == 0)
{
uint8_t v___x_2592_; uint8_t v___x_2593_;
v___x_2592_ = 2;
v___x_2593_ = lean_uint8_dec_eq(v___y_2587_, v___x_2592_);
if (v___x_2593_ == 0)
{
uint8_t v___x_2594_; uint8_t v___x_2595_;
v___x_2594_ = 3;
v___x_2595_ = lean_uint8_dec_eq(v___y_2587_, v___x_2594_);
if (v___x_2595_ == 0)
{
uint8_t v___x_2596_; uint8_t v___x_2597_;
v___x_2596_ = 4;
v___x_2597_ = lean_uint8_dec_eq(v___y_2587_, v___x_2596_);
if (v___x_2597_ == 0)
{
uint8_t v___x_2598_; uint8_t v___x_2599_;
v___x_2598_ = 7;
v___x_2599_ = lean_uint8_dec_eq(v___y_2587_, v___x_2598_);
if (v___x_2599_ == 0)
{
uint8_t v___x_2600_; uint8_t v___x_2601_;
v___x_2600_ = 6;
v___x_2601_ = lean_uint8_dec_eq(v___y_2587_, v___x_2600_);
if (v___x_2601_ == 0)
{
uint8_t v___x_2602_; uint8_t v___x_2603_;
v___x_2602_ = 8;
v___x_2603_ = lean_uint8_dec_eq(v___y_2587_, v___x_2602_);
if (v___x_2603_ == 0)
{
uint32_t v___x_2604_;
v___x_2604_ = 0;
v___y_2549_ = v___x_2604_;
goto v___jp_2548_;
}
else
{
uint32_t v___x_2605_;
v___x_2605_ = 128;
v___y_2549_ = v___x_2605_;
goto v___jp_2548_;
}
}
else
{
uint32_t v___x_2606_;
v___x_2606_ = 128;
v___y_2549_ = v___x_2606_;
goto v___jp_2548_;
}
}
else
{
uint32_t v___x_2607_;
v___x_2607_ = 194;
v___y_2549_ = v___x_2607_;
goto v___jp_2548_;
}
}
else
{
uint32_t v___x_2608_;
v___x_2608_ = 1;
v___y_2549_ = v___x_2608_;
goto v___jp_2548_;
}
}
else
{
uint32_t v___x_2609_;
v___x_2609_ = 1;
v___y_2549_ = v___x_2609_;
goto v___jp_2548_;
}
}
else
{
uint32_t v___x_2610_;
v___x_2610_ = 166;
v___y_2549_ = v___x_2610_;
goto v___jp_2548_;
}
}
else
{
uint32_t v___x_2611_;
v___x_2611_ = 36;
v___y_2549_ = v___x_2611_;
goto v___jp_2548_;
}
}
else
{
uint32_t v___x_2612_;
v___x_2612_ = 4;
v___y_2549_ = v___x_2612_;
goto v___jp_2548_;
}
}
}
}

LEAN_EXPORT uint8_t orb_mission_inbox_section(uint8_t v_stateId_2644_){
_start:
{
uint8_t v___y_2646_; uint8_t v___x_2680_; uint8_t v___x_2681_;
v___x_2680_ = 8;
v___x_2681_ = lean_uint8_dec_le(v_stateId_2644_, v___x_2680_);
if (v___x_2681_ == 0)
{
uint8_t v___x_2682_; uint8_t v___x_2683_;
v___x_2682_ = 10;
v___x_2683_ = lean_uint8_dec_le(v_stateId_2644_, v___x_2682_);
if (v___x_2683_ == 0)
{
uint8_t v___x_2684_; uint8_t v___x_2685_;
v___x_2684_ = 15;
v___x_2685_ = lean_uint8_dec_le(v_stateId_2644_, v___x_2684_);
if (v___x_2685_ == 0)
{
uint8_t v___x_2686_; uint8_t v___x_2687_;
v___x_2686_ = 16;
v___x_2687_ = lean_uint8_dec_eq(v_stateId_2644_, v___x_2686_);
if (v___x_2687_ == 0)
{
uint8_t v___x_2688_; uint8_t v___x_2689_;
v___x_2688_ = 21;
v___x_2689_ = lean_uint8_dec_le(v_stateId_2644_, v___x_2688_);
if (v___x_2689_ == 0)
{
uint8_t v___x_2690_; uint8_t v___x_2691_;
v___x_2690_ = 23;
v___x_2691_ = lean_uint8_dec_le(v_stateId_2644_, v___x_2690_);
if (v___x_2691_ == 0)
{
uint8_t v___x_2692_; uint8_t v___x_2693_;
v___x_2692_ = 24;
v___x_2693_ = lean_uint8_dec_eq(v_stateId_2644_, v___x_2692_);
if (v___x_2693_ == 0)
{
uint8_t v___x_2694_; uint8_t v___x_2695_;
v___x_2694_ = 26;
v___x_2695_ = lean_uint8_dec_le(v_stateId_2644_, v___x_2694_);
if (v___x_2695_ == 0)
{
uint8_t v___x_2696_; uint8_t v___x_2697_;
v___x_2696_ = 28;
v___x_2697_ = lean_uint8_dec_le(v_stateId_2644_, v___x_2696_);
if (v___x_2697_ == 0)
{
uint8_t v___x_2698_;
v___x_2698_ = 9;
v___y_2646_ = v___x_2698_;
goto v___jp_2645_;
}
else
{
v___y_2646_ = v___x_2680_;
goto v___jp_2645_;
}
}
else
{
uint8_t v___x_2699_;
v___x_2699_ = 7;
v___y_2646_ = v___x_2699_;
goto v___jp_2645_;
}
}
else
{
uint8_t v___x_2700_;
v___x_2700_ = 5;
v___y_2646_ = v___x_2700_;
goto v___jp_2645_;
}
}
else
{
uint8_t v___x_2701_;
v___x_2701_ = 6;
v___y_2646_ = v___x_2701_;
goto v___jp_2645_;
}
}
else
{
uint8_t v___x_2702_;
v___x_2702_ = 2;
v___y_2646_ = v___x_2702_;
goto v___jp_2645_;
}
}
else
{
uint8_t v___x_2703_;
v___x_2703_ = 1;
v___y_2646_ = v___x_2703_;
goto v___jp_2645_;
}
}
else
{
uint8_t v___x_2704_;
v___x_2704_ = 0;
v___y_2646_ = v___x_2704_;
goto v___jp_2645_;
}
}
else
{
uint8_t v___x_2705_;
v___x_2705_ = 4;
v___y_2646_ = v___x_2705_;
goto v___jp_2645_;
}
}
else
{
uint8_t v___x_2706_;
v___x_2706_ = 3;
v___y_2646_ = v___x_2706_;
goto v___jp_2645_;
}
v___jp_2645_:
{
uint8_t v___x_2647_; uint8_t v___x_2648_;
v___x_2647_ = 3;
v___x_2648_ = lean_uint8_dec_eq(v___y_2646_, v___x_2647_);
if (v___x_2648_ == 0)
{
uint8_t v___x_2649_; uint8_t v___x_2650_;
v___x_2649_ = 4;
v___x_2650_ = lean_uint8_dec_eq(v___y_2646_, v___x_2649_);
if (v___x_2650_ == 0)
{
uint8_t v___x_2651_; uint8_t v___x_2652_;
v___x_2651_ = 2;
v___x_2652_ = lean_uint8_dec_le(v___y_2646_, v___x_2651_);
if (v___x_2652_ == 0)
{
uint8_t v___x_2653_; uint8_t v___x_2654_;
v___x_2653_ = 7;
v___x_2654_ = lean_uint8_dec_eq(v___y_2646_, v___x_2653_);
if (v___x_2654_ == 0)
{
uint8_t v___x_2655_; uint8_t v___x_2656_;
v___x_2655_ = 5;
v___x_2656_ = lean_uint8_dec_eq(v___y_2646_, v___x_2655_);
if (v___x_2656_ == 0)
{
uint8_t v___x_2657_; uint8_t v___x_2658_;
v___x_2657_ = 6;
v___x_2658_ = lean_uint8_dec_eq(v___y_2646_, v___x_2657_);
if (v___x_2658_ == 0)
{
return v___x_2647_;
}
else
{
uint8_t v___x_2659_; uint8_t v___x_2660_;
v___x_2659_ = 11;
v___x_2660_ = lean_uint8_dec_eq(v_stateId_2644_, v___x_2659_);
if (v___x_2660_ == 0)
{
uint8_t v___x_2661_; uint8_t v___x_2662_;
v___x_2661_ = 12;
v___x_2662_ = lean_uint8_dec_eq(v_stateId_2644_, v___x_2661_);
if (v___x_2662_ == 0)
{
uint8_t v___x_2663_; uint8_t v___x_2664_;
v___x_2663_ = 16;
v___x_2664_ = lean_uint8_dec_eq(v_stateId_2644_, v___x_2663_);
if (v___x_2664_ == 0)
{
uint8_t v___x_2665_; uint8_t v___x_2666_;
v___x_2665_ = 17;
v___x_2666_ = lean_uint8_dec_eq(v_stateId_2644_, v___x_2665_);
if (v___x_2666_ == 0)
{
uint8_t v___x_2667_; uint8_t v___x_2668_;
v___x_2667_ = 20;
v___x_2668_ = lean_uint8_dec_eq(v_stateId_2644_, v___x_2667_);
if (v___x_2668_ == 0)
{
uint8_t v___x_2669_; uint8_t v___x_2670_;
v___x_2669_ = 22;
v___x_2670_ = lean_uint8_dec_eq(v_stateId_2644_, v___x_2669_);
if (v___x_2670_ == 0)
{
uint8_t v___x_2671_; uint8_t v___x_2672_;
v___x_2671_ = 24;
v___x_2672_ = lean_uint8_dec_eq(v_stateId_2644_, v___x_2671_);
if (v___x_2672_ == 0)
{
uint8_t v___x_2673_; uint8_t v___x_2674_;
v___x_2673_ = 25;
v___x_2674_ = lean_uint8_dec_eq(v_stateId_2644_, v___x_2673_);
if (v___x_2674_ == 0)
{
uint8_t v___x_2675_; uint8_t v___x_2676_;
v___x_2675_ = 26;
v___x_2676_ = lean_uint8_dec_eq(v_stateId_2644_, v___x_2675_);
if (v___x_2676_ == 0)
{
return v___x_2647_;
}
else
{
return v___x_2651_;
}
}
else
{
return v___x_2651_;
}
}
else
{
return v___x_2651_;
}
}
else
{
return v___x_2651_;
}
}
else
{
return v___x_2651_;
}
}
else
{
return v___x_2651_;
}
}
else
{
return v___x_2651_;
}
}
else
{
return v___x_2651_;
}
}
else
{
return v___x_2651_;
}
}
}
else
{
return v___x_2651_;
}
}
else
{
return v___x_2651_;
}
}
else
{
uint8_t v___x_2677_;
v___x_2677_ = 1;
return v___x_2677_;
}
}
else
{
uint8_t v___x_2678_;
v___x_2678_ = 0;
return v___x_2678_;
}
}
else
{
uint8_t v___x_2679_;
v___x_2679_ = 0;
return v___x_2679_;
}
}
}
}

LEAN_EXPORT uint32_t orb_connection_issue_classify(uint8_t v_isUnreachable_2711_, uint8_t v_isUsingDefault_2712_, uint8_t v_isPrivateAddr_2713_, uint8_t v_defaultReachable_2714_, uint8_t v_hasExternalProxy_2715_){
_start:
{
uint32_t v___y_2717_; uint32_t v___y_2718_; uint32_t v___y_2719_; uint32_t v___y_2720_; uint8_t v___x_2728_; uint32_t v___y_2730_; uint32_t v___y_2731_; uint8_t v___y_2739_; uint32_t v___y_2740_; uint32_t v___y_2741_; uint32_t v___y_2752_; uint8_t v___y_2753_; uint8_t v___x_2755_;
v___x_2728_ = 1;
v___x_2755_ = lean_uint8_dec_eq(v_isUnreachable_2711_, v___x_2728_);
if (v___x_2755_ == 0)
{
uint32_t v___x_2756_;
v___x_2756_ = 0;
return v___x_2756_;
}
else
{
uint8_t v___x_2757_; uint8_t v___x_2758_; uint8_t v___x_2759_; uint32_t v___y_2761_;
v___x_2757_ = 0;
v___x_2758_ = 0;
v___x_2759_ = lean_uint8_dec_eq(v_isUsingDefault_2712_, v___x_2758_);
if (v___x_2759_ == 0)
{
uint32_t v___x_2764_;
v___x_2764_ = 0;
v___y_2761_ = v___x_2764_;
goto v___jp_2760_;
}
else
{
uint32_t v___x_2765_;
v___x_2765_ = 256;
v___y_2761_ = v___x_2765_;
goto v___jp_2760_;
}
v___jp_2760_:
{
if (v___x_2759_ == 0)
{
v___y_2752_ = v___y_2761_;
v___y_2753_ = v___x_2757_;
goto v___jp_2751_;
}
else
{
uint8_t v___x_2762_;
v___x_2762_ = lean_uint8_dec_eq(v_isPrivateAddr_2713_, v___x_2728_);
if (v___x_2762_ == 0)
{
v___y_2752_ = v___y_2761_;
v___y_2753_ = v___x_2762_;
goto v___jp_2751_;
}
else
{
uint32_t v___x_2763_;
v___x_2763_ = 16777216;
v___y_2739_ = v___x_2762_;
v___y_2740_ = v___y_2761_;
v___y_2741_ = v___x_2763_;
goto v___jp_2738_;
}
}
}
}
v___jp_2716_:
{
uint32_t v___x_2721_; uint32_t v___x_2722_; uint32_t v___x_2723_; uint32_t v___x_2724_; uint32_t v___x_2725_; uint32_t v___x_2726_; uint32_t v___x_2727_;
v___x_2721_ = 1;
v___x_2722_ = lean_uint32_lor(v___x_2721_, v___y_2719_);
v___x_2723_ = lean_uint32_lor(v___x_2722_, v___y_2718_);
v___x_2724_ = lean_uint32_lor(v___x_2723_, v___y_2717_);
v___x_2725_ = 28;
v___x_2726_ = lean_uint32_shift_left(v___y_2720_, v___x_2725_);
v___x_2727_ = lean_uint32_lor(v___x_2724_, v___x_2726_);
return v___x_2727_;
}
v___jp_2729_:
{
uint32_t v___x_2732_; uint8_t v___x_2733_;
v___x_2732_ = 0;
v___x_2733_ = lean_uint8_dec_eq(v_isPrivateAddr_2713_, v___x_2728_);
if (v___x_2733_ == 0)
{
uint8_t v___x_2734_;
v___x_2734_ = lean_uint8_dec_eq(v_isUsingDefault_2712_, v___x_2728_);
if (v___x_2734_ == 0)
{
uint32_t v___x_2735_;
v___x_2735_ = 5;
v___y_2717_ = v___y_2730_;
v___y_2718_ = v___x_2732_;
v___y_2719_ = v___y_2731_;
v___y_2720_ = v___x_2735_;
goto v___jp_2716_;
}
else
{
uint32_t v___x_2736_;
v___x_2736_ = 4;
v___y_2717_ = v___y_2730_;
v___y_2718_ = v___x_2732_;
v___y_2719_ = v___y_2731_;
v___y_2720_ = v___x_2736_;
goto v___jp_2716_;
}
}
else
{
uint32_t v___x_2737_;
v___x_2737_ = 3;
v___y_2717_ = v___y_2730_;
v___y_2718_ = v___x_2732_;
v___y_2719_ = v___y_2731_;
v___y_2720_ = v___x_2737_;
goto v___jp_2716_;
}
}
v___jp_2738_:
{
uint8_t v___x_2742_;
v___x_2742_ = lean_uint8_dec_eq(v_hasExternalProxy_2715_, v___x_2728_);
if (v___x_2742_ == 0)
{
if (v___y_2739_ == 0)
{
v___y_2730_ = v___y_2741_;
v___y_2731_ = v___y_2740_;
goto v___jp_2729_;
}
else
{
uint8_t v___x_2743_;
v___x_2743_ = lean_uint8_dec_eq(v_defaultReachable_2714_, v___x_2728_);
if (v___x_2743_ == 0)
{
v___y_2730_ = v___y_2741_;
v___y_2731_ = v___y_2740_;
goto v___jp_2729_;
}
else
{
uint32_t v___x_2744_; uint32_t v___x_2745_;
v___x_2744_ = 65536;
v___x_2745_ = 2;
v___y_2717_ = v___y_2741_;
v___y_2718_ = v___x_2744_;
v___y_2719_ = v___y_2740_;
v___y_2720_ = v___x_2745_;
goto v___jp_2716_;
}
}
}
else
{
uint32_t v___x_2746_; uint32_t v___x_2747_; uint32_t v___x_2748_; uint32_t v___x_2749_; uint32_t v___x_2750_;
v___x_2746_ = 1;
v___x_2747_ = lean_uint32_lor(v___x_2746_, v___y_2740_);
v___x_2748_ = lean_uint32_lor(v___x_2747_, v___y_2741_);
v___x_2749_ = 268435456;
v___x_2750_ = lean_uint32_lor(v___x_2748_, v___x_2749_);
return v___x_2750_;
}
}
v___jp_2751_:
{
uint32_t v___x_2754_;
v___x_2754_ = 0;
v___y_2739_ = v___y_2753_;
v___y_2740_ = v___y_2752_;
v___y_2741_ = v___x_2754_;
goto v___jp_2738_;
}
}
}

LEAN_EXPORT uint64_t orb_worked_duration_bucket(uint64_t v_seconds_2778_){
_start:
{
uint64_t v___x_2779_; uint8_t v___x_2780_;
v___x_2779_ = 60ULL;
v___x_2780_ = lean_uint64_dec_lt(v_seconds_2778_, v___x_2779_);
if (v___x_2780_ == 0)
{
uint64_t v___x_2781_; uint8_t v___x_2782_;
v___x_2781_ = 3600ULL;
v___x_2782_ = lean_uint64_dec_lt(v_seconds_2778_, v___x_2781_);
if (v___x_2782_ == 0)
{
uint64_t v___x_2783_; uint8_t v___x_2784_;
v___x_2783_ = 86400ULL;
v___x_2784_ = lean_uint64_dec_lt(v_seconds_2778_, v___x_2783_);
if (v___x_2784_ == 0)
{
uint64_t v_totalH_2785_; uint64_t v___x_2786_; uint64_t v___y_2788_; uint64_t v___x_2797_; uint64_t v___x_2798_; uint8_t v___x_2799_;
v_totalH_2785_ = lean_uint64_div(v_seconds_2778_, v___x_2781_);
v___x_2786_ = 24ULL;
v___x_2797_ = lean_uint64_div(v_totalH_2785_, v___x_2786_);
v___x_2798_ = 4294967295ULL;
v___x_2799_ = lean_uint64_dec_le(v___x_2797_, v___x_2798_);
if (v___x_2799_ == 0)
{
v___y_2788_ = v___x_2798_;
goto v___jp_2787_;
}
else
{
v___y_2788_ = v___x_2797_;
goto v___jp_2787_;
}
v___jp_2787_:
{
uint64_t v_remH_2789_; uint64_t v___x_2790_; uint64_t v___x_2791_; uint64_t v___x_2792_; uint64_t v___x_2793_; uint64_t v___x_2794_; uint64_t v___x_2795_; uint64_t v___x_2796_;
v_remH_2789_ = lean_uint64_mod(v_totalH_2785_, v___x_2786_);
v___x_2790_ = 3ULL;
v___x_2791_ = 8ULL;
v___x_2792_ = lean_uint64_shift_left(v_remH_2789_, v___x_2791_);
v___x_2793_ = lean_uint64_lor(v___x_2790_, v___x_2792_);
v___x_2794_ = 32ULL;
v___x_2795_ = lean_uint64_shift_left(v___y_2788_, v___x_2794_);
v___x_2796_ = lean_uint64_lor(v___x_2793_, v___x_2795_);
return v___x_2796_;
}
}
else
{
uint64_t v_totalM_2800_; uint64_t v_h_2801_; uint64_t v_remM_2802_; uint64_t v___x_2803_; uint64_t v___x_2804_; uint64_t v___x_2805_; uint64_t v___x_2806_; uint64_t v___x_2807_; uint64_t v___x_2808_; uint64_t v___x_2809_;
v_totalM_2800_ = lean_uint64_div(v_seconds_2778_, v___x_2779_);
v_h_2801_ = lean_uint64_div(v_totalM_2800_, v___x_2779_);
v_remM_2802_ = lean_uint64_mod(v_totalM_2800_, v___x_2779_);
v___x_2803_ = 2ULL;
v___x_2804_ = 8ULL;
v___x_2805_ = lean_uint64_shift_left(v_remM_2802_, v___x_2804_);
v___x_2806_ = lean_uint64_lor(v___x_2803_, v___x_2805_);
v___x_2807_ = 32ULL;
v___x_2808_ = lean_uint64_shift_left(v_h_2801_, v___x_2807_);
v___x_2809_ = lean_uint64_lor(v___x_2806_, v___x_2808_);
return v___x_2809_;
}
}
else
{
uint64_t v_m_2810_; uint64_t v_rem_2811_; uint64_t v___x_2812_; uint64_t v___x_2813_; uint64_t v___x_2814_; uint64_t v___x_2815_; uint64_t v___x_2816_; uint64_t v___x_2817_; uint64_t v___x_2818_;
v_m_2810_ = lean_uint64_div(v_seconds_2778_, v___x_2779_);
v_rem_2811_ = lean_uint64_mod(v_seconds_2778_, v___x_2779_);
v___x_2812_ = 1ULL;
v___x_2813_ = 8ULL;
v___x_2814_ = lean_uint64_shift_left(v_rem_2811_, v___x_2813_);
v___x_2815_ = lean_uint64_lor(v___x_2812_, v___x_2814_);
v___x_2816_ = 32ULL;
v___x_2817_ = lean_uint64_shift_left(v_m_2810_, v___x_2816_);
v___x_2818_ = lean_uint64_lor(v___x_2815_, v___x_2817_);
return v___x_2818_;
}
}
else
{
uint64_t v___x_2819_; uint64_t v___x_2820_;
v___x_2819_ = 32ULL;
v___x_2820_ = lean_uint64_shift_left(v_seconds_2778_, v___x_2819_);
return v___x_2820_;
}
}
}

LEAN_EXPORT uint32_t orb_turn_outcome_step(uint8_t v_prevOutcome_2825_, uint8_t v_prevFailed_2826_, uint8_t v_eventKind_2827_, uint8_t v_isNarration_2828_, uint8_t v_isSuccessFalse_2829_, uint8_t v_isTextNonEmpty_2830_){
_start:
{
uint8_t v___x_2831_; uint8_t v___x_2832_;
v___x_2831_ = 0;
v___x_2832_ = lean_uint8_dec_eq(v_eventKind_2827_, v___x_2831_);
if (v___x_2832_ == 0)
{
uint8_t v___x_2833_; uint32_t v___y_2835_; uint32_t v___y_2840_; uint32_t v___y_2849_; uint8_t v___x_2853_;
v___x_2833_ = 1;
v___x_2853_ = lean_uint8_dec_eq(v_eventKind_2827_, v___x_2833_);
if (v___x_2853_ == 0)
{
uint8_t v___x_2854_; uint8_t v___x_2855_;
v___x_2854_ = 2;
v___x_2855_ = lean_uint8_dec_eq(v_eventKind_2827_, v___x_2854_);
if (v___x_2855_ == 0)
{
uint8_t v___x_2856_;
v___x_2856_ = lean_uint8_dec_eq(v_prevOutcome_2825_, v___x_2833_);
if (v___x_2856_ == 0)
{
uint32_t v___x_2857_;
v___x_2857_ = 0;
v___y_2849_ = v___x_2857_;
goto v___jp_2848_;
}
else
{
uint32_t v___x_2858_;
v___x_2858_ = 1;
v___y_2849_ = v___x_2858_;
goto v___jp_2848_;
}
}
else
{
uint8_t v___x_2859_;
v___x_2859_ = lean_uint8_dec_eq(v_isNarration_2828_, v___x_2833_);
if (v___x_2859_ == 0)
{
uint8_t v___x_2860_;
v___x_2860_ = lean_uint8_dec_eq(v_isSuccessFalse_2829_, v___x_2833_);
if (v___x_2860_ == 0)
{
uint8_t v___x_2861_;
v___x_2861_ = lean_uint8_dec_eq(v_prevFailed_2826_, v___x_2831_);
if (v___x_2861_ == 0)
{
goto v___jp_2844_;
}
else
{
uint8_t v___x_2862_;
v___x_2862_ = lean_uint8_dec_eq(v_isTextNonEmpty_2830_, v___x_2833_);
if (v___x_2862_ == 0)
{
goto v___jp_2844_;
}
else
{
uint32_t v___x_2863_;
v___x_2863_ = 1;
return v___x_2863_;
}
}
}
else
{
uint32_t v___x_2864_;
v___x_2864_ = 256;
return v___x_2864_;
}
}
else
{
uint8_t v___x_2865_;
v___x_2865_ = lean_uint8_dec_eq(v_prevOutcome_2825_, v___x_2833_);
if (v___x_2865_ == 0)
{
uint32_t v___x_2866_;
v___x_2866_ = 0;
v___y_2835_ = v___x_2866_;
goto v___jp_2834_;
}
else
{
uint32_t v___x_2867_;
v___x_2867_ = 1;
v___y_2835_ = v___x_2867_;
goto v___jp_2834_;
}
}
}
}
else
{
uint32_t v___x_2868_;
v___x_2868_ = 0;
return v___x_2868_;
}
v___jp_2834_:
{
uint8_t v___x_2836_;
v___x_2836_ = lean_uint8_dec_eq(v_prevFailed_2826_, v___x_2833_);
if (v___x_2836_ == 0)
{
return v___y_2835_;
}
else
{
uint32_t v___x_2837_; uint32_t v___x_2838_;
v___x_2837_ = 256;
v___x_2838_ = lean_uint32_lor(v___y_2835_, v___x_2837_);
return v___x_2838_;
}
}
v___jp_2839_:
{
uint8_t v___x_2841_;
v___x_2841_ = lean_uint8_dec_eq(v_prevFailed_2826_, v___x_2833_);
if (v___x_2841_ == 0)
{
return v___y_2840_;
}
else
{
uint32_t v___x_2842_; uint32_t v___x_2843_;
v___x_2842_ = 256;
v___x_2843_ = lean_uint32_lor(v___y_2840_, v___x_2842_);
return v___x_2843_;
}
}
v___jp_2844_:
{
uint8_t v___x_2845_;
v___x_2845_ = lean_uint8_dec_eq(v_prevOutcome_2825_, v___x_2833_);
if (v___x_2845_ == 0)
{
uint32_t v___x_2846_;
v___x_2846_ = 0;
v___y_2840_ = v___x_2846_;
goto v___jp_2839_;
}
else
{
uint32_t v___x_2847_;
v___x_2847_ = 1;
v___y_2840_ = v___x_2847_;
goto v___jp_2839_;
}
}
v___jp_2848_:
{
uint8_t v___x_2850_;
v___x_2850_ = lean_uint8_dec_eq(v_prevFailed_2826_, v___x_2833_);
if (v___x_2850_ == 0)
{
return v___y_2849_;
}
else
{
uint32_t v___x_2851_; uint32_t v___x_2852_;
v___x_2851_ = 256;
v___x_2852_ = lean_uint32_lor(v___y_2849_, v___x_2851_);
return v___x_2852_;
}
}
}
else
{
uint32_t v___x_2869_;
v___x_2869_ = 0;
return v___x_2869_;
}
}
}

LEAN_EXPORT uint8_t orb_numeric_cell_scan(uint8_t v_nonEmpty_2884_, uint8_t v_hasLeadingDigitOrSign_2885_, uint8_t v_hasDigit_2886_, uint8_t v_allAllowedChars_2887_){
_start:
{
uint8_t v___x_2888_; uint8_t v___x_2889_;
v___x_2888_ = 1;
v___x_2889_ = lean_uint8_dec_eq(v_nonEmpty_2884_, v___x_2888_);
if (v___x_2889_ == 0)
{
uint8_t v___x_2890_;
v___x_2890_ = 0;
return v___x_2890_;
}
else
{
uint8_t v___x_2891_;
v___x_2891_ = lean_uint8_dec_eq(v_hasLeadingDigitOrSign_2885_, v___x_2888_);
if (v___x_2891_ == 0)
{
uint8_t v___x_2892_;
v___x_2892_ = 0;
return v___x_2892_;
}
else
{
uint8_t v___x_2893_;
v___x_2893_ = lean_uint8_dec_eq(v_hasDigit_2886_, v___x_2888_);
if (v___x_2893_ == 0)
{
uint8_t v___x_2894_;
v___x_2894_ = 0;
return v___x_2894_;
}
else
{
uint8_t v___x_2895_;
v___x_2895_ = lean_uint8_dec_eq(v_allAllowedChars_2887_, v___x_2888_);
if (v___x_2895_ == 0)
{
uint8_t v___x_2896_;
v___x_2896_ = 0;
return v___x_2896_;
}
else
{
return v___x_2888_;
}
}
}
}
}
}

LEAN_EXPORT uint64_t orb_file_ref_line_span(uint32_t v_startLine_2907_, uint32_t v_endLine_2908_, uint32_t v_totalLines_2909_){
_start:
{
uint32_t v___x_2910_; uint8_t v___x_2919_;
v___x_2910_ = 1;
v___x_2919_ = lean_uint32_dec_le(v___x_2910_, v_startLine_2907_);
if (v___x_2919_ == 0)
{
uint64_t v___x_2920_;
v___x_2920_ = 0ULL;
return v___x_2920_;
}
else
{
uint8_t v___x_2921_;
v___x_2921_ = lean_uint32_dec_le(v_startLine_2907_, v_endLine_2908_);
if (v___x_2921_ == 0)
{
uint64_t v___x_2922_;
v___x_2922_ = 0ULL;
return v___x_2922_;
}
else
{
uint32_t v___x_2923_; uint8_t v___x_2924_;
v___x_2923_ = 0;
v___x_2924_ = lean_uint32_dec_eq(v_totalLines_2909_, v___x_2923_);
if (v___x_2924_ == 0)
{
uint8_t v___x_2925_;
v___x_2925_ = lean_uint32_dec_le(v_endLine_2908_, v_totalLines_2909_);
if (v___x_2925_ == 0)
{
uint64_t v___x_2926_;
v___x_2926_ = 0ULL;
return v___x_2926_;
}
else
{
goto v___jp_2911_;
}
}
else
{
goto v___jp_2911_;
}
}
}
v___jp_2911_:
{
uint32_t v___x_2912_; uint32_t v_count_2913_; uint64_t v___x_2914_; uint64_t v___x_2915_; uint64_t v___x_2916_; uint64_t v___x_2917_; uint64_t v___x_2918_;
v___x_2912_ = lean_uint32_sub(v_endLine_2908_, v_startLine_2907_);
v_count_2913_ = lean_uint32_add(v___x_2912_, v___x_2910_);
v___x_2914_ = 1ULL;
v___x_2915_ = lean_uint32_to_uint64(v_count_2913_);
v___x_2916_ = 32ULL;
v___x_2917_ = lean_uint64_shift_left(v___x_2915_, v___x_2916_);
v___x_2918_ = lean_uint64_lor(v___x_2914_, v___x_2917_);
return v___x_2918_;
}
}
}

LEAN_EXPORT uint32_t orb_machine_action_admitted(uint8_t v_stateKind_2935_, uint8_t v_isBusy_2936_, uint8_t v_isMuted_2937_){
_start:
{
uint32_t v___y_2939_; uint32_t v___y_2940_; uint32_t v___y_2941_; uint8_t v___y_2945_; uint32_t v___y_2946_; uint32_t v___y_2947_; uint8_t v___y_2951_; uint32_t v___y_2952_; uint32_t v___y_2955_; uint8_t v___x_2962_; uint8_t v___x_2963_;
v___x_2962_ = 3;
v___x_2963_ = lean_uint8_dec_le(v_stateKind_2935_, v___x_2962_);
if (v___x_2963_ == 0)
{
uint32_t v___x_2964_;
v___x_2964_ = 0;
v___y_2955_ = v___x_2964_;
goto v___jp_2954_;
}
else
{
uint32_t v___x_2965_;
v___x_2965_ = 1;
v___y_2955_ = v___x_2965_;
goto v___jp_2954_;
}
v___jp_2938_:
{
uint32_t v___x_2942_; uint32_t v___x_2943_;
v___x_2942_ = lean_uint32_lor(v___y_2940_, v___y_2939_);
v___x_2943_ = lean_uint32_lor(v___x_2942_, v___y_2941_);
return v___x_2943_;
}
v___jp_2944_:
{
if (v___y_2945_ == 0)
{
uint32_t v___x_2948_;
v___x_2948_ = 0;
v___y_2939_ = v___y_2947_;
v___y_2940_ = v___y_2946_;
v___y_2941_ = v___x_2948_;
goto v___jp_2938_;
}
else
{
uint32_t v___x_2949_;
v___x_2949_ = 65536;
v___y_2939_ = v___y_2947_;
v___y_2940_ = v___y_2946_;
v___y_2941_ = v___x_2949_;
goto v___jp_2938_;
}
}
v___jp_2950_:
{
uint32_t v___x_2953_;
v___x_2953_ = 0;
v___y_2945_ = v___y_2951_;
v___y_2946_ = v___y_2952_;
v___y_2947_ = v___x_2953_;
goto v___jp_2944_;
}
v___jp_2954_:
{
uint8_t v___x_2956_; uint8_t v___x_2957_;
v___x_2956_ = 2;
v___x_2957_ = lean_uint8_dec_le(v_stateKind_2935_, v___x_2956_);
if (v___x_2957_ == 0)
{
v___y_2951_ = v___x_2957_;
v___y_2952_ = v___y_2955_;
goto v___jp_2950_;
}
else
{
uint8_t v___x_2958_; uint8_t v___x_2959_;
v___x_2958_ = 0;
v___x_2959_ = lean_uint8_dec_eq(v_isBusy_2936_, v___x_2958_);
if (v___x_2959_ == 0)
{
v___y_2951_ = v___x_2957_;
v___y_2952_ = v___y_2955_;
goto v___jp_2950_;
}
else
{
uint8_t v___x_2960_;
v___x_2960_ = lean_uint8_dec_eq(v_isMuted_2937_, v___x_2958_);
if (v___x_2960_ == 0)
{
v___y_2951_ = v___x_2957_;
v___y_2952_ = v___y_2955_;
goto v___jp_2950_;
}
else
{
uint32_t v___x_2961_;
v___x_2961_ = 256;
v___y_2945_ = v___x_2957_;
v___y_2946_ = v___y_2955_;
v___y_2947_ = v___x_2961_;
goto v___jp_2944_;
}
}
}
}
}
}

LEAN_EXPORT uint32_t orb_send_flow_step(uint8_t v_isBusy_2974_, uint8_t v_hasNonEmptyText_2975_, uint8_t v_canQueue_2976_, uint8_t v_awaitingAck_2977_, uint8_t v_isDraining_2978_, uint8_t v_pendingCount_2979_, uint32_t v_httpStatus_2980_){
_start:
{
uint32_t v___y_2982_; uint32_t v___y_2983_; uint32_t v___y_2984_; uint32_t v___y_2990_; uint32_t v___y_2991_; uint32_t v___y_2994_; uint32_t v___y_2995_; uint32_t v___y_3005_; uint32_t v___y_3006_; uint32_t v___y_3013_; uint8_t v___x_3015_; uint32_t v___y_3017_; uint8_t v___x_3022_;
v___x_3015_ = 0;
v___x_3022_ = lean_uint8_dec_eq(v_hasNonEmptyText_2975_, v___x_3015_);
if (v___x_3022_ == 0)
{
uint8_t v___x_3023_;
v___x_3023_ = lean_uint8_dec_eq(v_isBusy_2974_, v___x_3015_);
if (v___x_3023_ == 0)
{
uint8_t v___x_3024_; uint8_t v___x_3025_;
v___x_3024_ = 1;
v___x_3025_ = lean_uint8_dec_eq(v_canQueue_2976_, v___x_3024_);
if (v___x_3025_ == 0)
{
uint32_t v___x_3026_;
v___x_3026_ = 0;
v___y_3017_ = v___x_3026_;
goto v___jp_3016_;
}
else
{
uint32_t v___x_3027_;
v___x_3027_ = 2;
v___y_3017_ = v___x_3027_;
goto v___jp_3016_;
}
}
else
{
uint32_t v___x_3028_;
v___x_3028_ = 1;
v___y_3017_ = v___x_3028_;
goto v___jp_3016_;
}
}
else
{
uint32_t v___x_3029_;
v___x_3029_ = 0;
v___y_3017_ = v___x_3029_;
goto v___jp_3016_;
}
v___jp_2981_:
{
uint32_t v___x_2985_; uint32_t v___x_2986_; uint32_t v___x_2987_; uint32_t v___x_2988_;
v___x_2985_ = lean_uint32_lor(v___y_2983_, v___y_2982_);
v___x_2986_ = 16;
v___x_2987_ = lean_uint32_shift_left(v___y_2984_, v___x_2986_);
v___x_2988_ = lean_uint32_lor(v___x_2985_, v___x_2987_);
return v___x_2988_;
}
v___jp_2989_:
{
uint32_t v___x_2992_;
v___x_2992_ = 2;
v___y_2982_ = v___y_2990_;
v___y_2983_ = v___y_2991_;
v___y_2984_ = v___x_2992_;
goto v___jp_2981_;
}
v___jp_2993_:
{
uint32_t v___x_2996_; uint8_t v___x_2997_;
v___x_2996_ = 404;
v___x_2997_ = lean_uint32_dec_eq(v_httpStatus_2980_, v___x_2996_);
if (v___x_2997_ == 0)
{
uint32_t v___x_2998_; uint8_t v___x_2999_;
v___x_2998_ = 405;
v___x_2999_ = lean_uint32_dec_eq(v_httpStatus_2980_, v___x_2998_);
if (v___x_2999_ == 0)
{
uint32_t v___x_3000_; uint8_t v___x_3001_;
v___x_3000_ = 409;
v___x_3001_ = lean_uint32_dec_eq(v_httpStatus_2980_, v___x_3000_);
if (v___x_3001_ == 0)
{
uint32_t v___x_3002_;
v___x_3002_ = 0;
v___y_2982_ = v___y_2994_;
v___y_2983_ = v___y_2995_;
v___y_2984_ = v___x_3002_;
goto v___jp_2981_;
}
else
{
uint32_t v___x_3003_;
v___x_3003_ = 3;
v___y_2982_ = v___y_2994_;
v___y_2983_ = v___y_2995_;
v___y_2984_ = v___x_3003_;
goto v___jp_2981_;
}
}
else
{
v___y_2990_ = v___y_2994_;
v___y_2991_ = v___y_2995_;
goto v___jp_2989_;
}
}
else
{
v___y_2990_ = v___y_2994_;
v___y_2991_ = v___y_2995_;
goto v___jp_2989_;
}
}
v___jp_3004_:
{
uint32_t v___x_3007_; uint8_t v___x_3008_;
v___x_3007_ = 200;
v___x_3008_ = lean_uint32_dec_le(v___x_3007_, v_httpStatus_2980_);
if (v___x_3008_ == 0)
{
v___y_2994_ = v___y_3006_;
v___y_2995_ = v___y_3005_;
goto v___jp_2993_;
}
else
{
uint32_t v___x_3009_; uint8_t v___x_3010_;
v___x_3009_ = 300;
v___x_3010_ = lean_uint32_dec_lt(v_httpStatus_2980_, v___x_3009_);
if (v___x_3010_ == 0)
{
v___y_2994_ = v___y_3006_;
v___y_2995_ = v___y_3005_;
goto v___jp_2993_;
}
else
{
uint32_t v___x_3011_;
v___x_3011_ = 1;
v___y_2982_ = v___y_3006_;
v___y_2983_ = v___y_3005_;
v___y_2984_ = v___x_3011_;
goto v___jp_2981_;
}
}
}
v___jp_3012_:
{
uint32_t v___x_3014_;
v___x_3014_ = 0;
v___y_3005_ = v___y_3013_;
v___y_3006_ = v___x_3014_;
goto v___jp_3004_;
}
v___jp_3016_:
{
uint8_t v___x_3018_;
v___x_3018_ = lean_uint8_dec_lt(v___x_3015_, v_pendingCount_2979_);
if (v___x_3018_ == 0)
{
v___y_3013_ = v___y_3017_;
goto v___jp_3012_;
}
else
{
uint8_t v___x_3019_;
v___x_3019_ = lean_uint8_dec_eq(v_awaitingAck_2977_, v___x_3015_);
if (v___x_3019_ == 0)
{
v___y_3013_ = v___y_3017_;
goto v___jp_3012_;
}
else
{
uint8_t v___x_3020_;
v___x_3020_ = lean_uint8_dec_eq(v_isDraining_2978_, v___x_3015_);
if (v___x_3020_ == 0)
{
v___y_3013_ = v___y_3017_;
goto v___jp_3012_;
}
else
{
uint32_t v___x_3021_;
v___x_3021_ = 256;
v___y_3005_ = v___y_3017_;
v___y_3006_ = v___x_3021_;
goto v___jp_3004_;
}
}
}
}
}
}

LEAN_EXPORT uint8_t orb_wire_validate_frame(uint32_t v_magic_3046_, uint32_t v_abiVersion_3047_, uint32_t v_schemaId_3048_, uint32_t v_expectedSchemaId_3049_, uint32_t v_totalLen_3050_, uint32_t v_payloadLen_3051_, uint32_t v_arenaOff_3052_, uint32_t v_arenaLen_3053_, uint32_t v_maxBudgetBytes_3054_, uint32_t v_outCap_3055_, uint32_t v_requiredOutBytes_3056_){
_start:
{
uint32_t v___x_3057_; uint8_t v___x_3058_;
v___x_3057_ = 1330790999;
v___x_3058_ = lean_uint32_dec_eq(v_magic_3046_, v___x_3057_);
if (v___x_3058_ == 0)
{
uint8_t v___x_3059_;
v___x_3059_ = 1;
return v___x_3059_;
}
else
{
uint32_t v___x_3060_; uint8_t v___x_3061_;
v___x_3060_ = 1;
v___x_3061_ = lean_uint32_dec_eq(v_abiVersion_3047_, v___x_3060_);
if (v___x_3061_ == 0)
{
uint8_t v___x_3062_;
v___x_3062_ = 1;
return v___x_3062_;
}
else
{
uint8_t v___x_3063_;
v___x_3063_ = lean_uint32_dec_eq(v_schemaId_3048_, v_expectedSchemaId_3049_);
if (v___x_3063_ == 0)
{
uint8_t v___x_3064_;
v___x_3064_ = 2;
return v___x_3064_;
}
else
{
uint32_t v___x_3065_; uint8_t v___x_3066_;
v___x_3065_ = 24;
v___x_3066_ = lean_uint32_dec_le(v___x_3065_, v_totalLen_3050_);
if (v___x_3066_ == 0)
{
uint8_t v___x_3067_;
v___x_3067_ = 3;
return v___x_3067_;
}
else
{
uint8_t v___x_3068_;
v___x_3068_ = lean_uint32_dec_le(v_totalLen_3050_, v_maxBudgetBytes_3054_);
if (v___x_3068_ == 0)
{
uint8_t v___x_3069_;
v___x_3069_ = 4;
return v___x_3069_;
}
else
{
uint32_t v___x_3070_; uint8_t v___x_3071_;
v___x_3070_ = lean_uint32_sub(v_totalLen_3050_, v___x_3065_);
v___x_3071_ = lean_uint32_dec_le(v_payloadLen_3051_, v___x_3070_);
if (v___x_3071_ == 0)
{
uint8_t v___x_3072_;
v___x_3072_ = 3;
return v___x_3072_;
}
else
{
uint8_t v___x_3073_;
v___x_3073_ = lean_uint32_dec_le(v_arenaOff_3052_, v_payloadLen_3051_);
if (v___x_3073_ == 0)
{
uint8_t v___x_3074_;
v___x_3074_ = 3;
return v___x_3074_;
}
else
{
uint32_t v___x_3075_; uint8_t v___x_3076_;
v___x_3075_ = lean_uint32_sub(v_payloadLen_3051_, v_arenaOff_3052_);
v___x_3076_ = lean_uint32_dec_le(v_arenaLen_3053_, v___x_3075_);
if (v___x_3076_ == 0)
{
uint8_t v___x_3077_;
v___x_3077_ = 3;
return v___x_3077_;
}
else
{
uint8_t v___x_3078_;
v___x_3078_ = lean_uint32_dec_le(v_requiredOutBytes_3056_, v_outCap_3055_);
if (v___x_3078_ == 0)
{
uint8_t v___x_3079_;
v___x_3079_ = 5;
return v___x_3079_;
}
else
{
uint8_t v___x_3080_;
v___x_3080_ = 0;
return v___x_3080_;
}
}
}
}
}
}
}
}
}
}
}

LEAN_EXPORT uint64_t orb_wire_pack_record(uint8_t v_tag_3105_, uint8_t v_flags_3106_, uint32_t v_len16_3107_, uint32_t v_payload32_3108_){
_start:
{
uint32_t v___x_3109_; uint32_t v___x_3110_; uint32_t v___x_3111_; uint32_t v___x_3112_; uint32_t v___x_3113_; uint32_t v___x_3114_; uint32_t v___x_3115_; uint32_t v___x_3116_; uint32_t v___x_3117_; uint32_t v_lo32_3118_; uint64_t v___x_3119_; uint64_t v___x_3120_; uint64_t v___x_3121_; uint64_t v___x_3122_; uint64_t v___x_3123_;
v___x_3109_ = lean_uint8_to_uint32(v_tag_3105_);
v___x_3110_ = lean_uint8_to_uint32(v_flags_3106_);
v___x_3111_ = 8;
v___x_3112_ = lean_uint32_shift_left(v___x_3110_, v___x_3111_);
v___x_3113_ = lean_uint32_lor(v___x_3109_, v___x_3112_);
v___x_3114_ = 65535;
v___x_3115_ = lean_uint32_land(v_len16_3107_, v___x_3114_);
v___x_3116_ = 16;
v___x_3117_ = lean_uint32_shift_left(v___x_3115_, v___x_3116_);
v_lo32_3118_ = lean_uint32_lor(v___x_3113_, v___x_3117_);
v___x_3119_ = lean_uint32_to_uint64(v_lo32_3118_);
v___x_3120_ = lean_uint32_to_uint64(v_payload32_3108_);
v___x_3121_ = 32ULL;
v___x_3122_ = lean_uint64_shift_left(v___x_3120_, v___x_3121_);
v___x_3123_ = lean_uint64_lor(v___x_3119_, v___x_3122_);
return v___x_3123_;
}
}

LEAN_EXPORT uint8_t orb_wire_schema_migrate_step(uint32_t v_fromSchema_3170_, uint32_t v_toSchema_3171_, uint32_t v_currentSchema_3172_, uint64_t v_payloadBytes_3173_, uint64_t v_maxBytes_3174_){
_start:
{
uint8_t v___x_3175_;
v___x_3175_ = lean_uint32_dec_eq(v_fromSchema_3170_, v_currentSchema_3172_);
if (v___x_3175_ == 0)
{
uint8_t v___x_3176_;
v___x_3176_ = 0;
return v___x_3176_;
}
else
{
uint8_t v___x_3177_;
v___x_3177_ = lean_uint32_dec_lt(v_fromSchema_3170_, v_toSchema_3171_);
if (v___x_3177_ == 0)
{
uint8_t v___x_3178_;
v___x_3178_ = 0;
return v___x_3178_;
}
else
{
uint32_t v___x_3179_; uint32_t v___x_3180_; uint8_t v___x_3181_;
v___x_3179_ = lean_uint32_sub(v_toSchema_3171_, v_fromSchema_3170_);
v___x_3180_ = 1;
v___x_3181_ = lean_uint32_dec_eq(v___x_3179_, v___x_3180_);
if (v___x_3181_ == 0)
{
uint8_t v___x_3182_;
v___x_3182_ = 0;
return v___x_3182_;
}
else
{
uint64_t v___x_3183_; uint8_t v___x_3184_;
v___x_3183_ = 0ULL;
v___x_3184_ = lean_uint64_dec_lt(v___x_3183_, v_payloadBytes_3173_);
if (v___x_3184_ == 0)
{
uint8_t v___x_3185_;
v___x_3185_ = 0;
return v___x_3185_;
}
else
{
uint8_t v___x_3186_;
v___x_3186_ = lean_uint64_dec_le(v_payloadBytes_3173_, v_maxBytes_3174_);
if (v___x_3186_ == 0)
{
uint8_t v___x_3187_;
v___x_3187_ = 0;
return v___x_3187_;
}
else
{
uint8_t v___x_3188_;
v___x_3188_ = 1;
return v___x_3188_;
}
}
}
}
}
}
}

LEAN_EXPORT uint8_t orb_effect_admissible(uint8_t v_effectKind_3201_, uint8_t v_hasValidLease_3202_, uint8_t v_sessionCreated_3203_, uint8_t v_lineageVerified_3204_, uint8_t v_isArchived_3205_, uint8_t v_idempotencyFresh_3206_, uint8_t v_accountBound_3207_, uint8_t v_accountRejected_3208_, uint8_t v_firstByteLocked_3209_, uint8_t v_grammarAllowed_3210_, uint8_t v_envScrubbed_3211_, uint8_t v_budgetOk_3212_){
_start:
{
uint8_t v___x_3213_; uint8_t v___x_3214_;
v___x_3213_ = 1;
v___x_3214_ = lean_uint8_dec_eq(v_budgetOk_3212_, v___x_3213_);
if (v___x_3214_ == 0)
{
uint8_t v___x_3215_;
v___x_3215_ = 0;
return v___x_3215_;
}
else
{
uint8_t v___x_3216_; uint8_t v___x_3217_;
v___x_3216_ = 0;
v___x_3217_ = lean_uint8_dec_eq(v_effectKind_3201_, v___x_3216_);
if (v___x_3217_ == 0)
{
uint8_t v___x_3218_;
v___x_3218_ = lean_uint8_dec_eq(v_effectKind_3201_, v___x_3213_);
if (v___x_3218_ == 0)
{
uint8_t v___x_3219_; uint8_t v___x_3220_;
v___x_3219_ = 2;
v___x_3220_ = lean_uint8_dec_eq(v_effectKind_3201_, v___x_3219_);
if (v___x_3220_ == 0)
{
uint8_t v___x_3221_; uint8_t v___x_3222_;
v___x_3221_ = 3;
v___x_3222_ = lean_uint8_dec_eq(v_effectKind_3201_, v___x_3221_);
if (v___x_3222_ == 0)
{
uint8_t v___x_3223_; uint8_t v___x_3224_;
v___x_3223_ = 4;
v___x_3224_ = lean_uint8_dec_eq(v_effectKind_3201_, v___x_3223_);
if (v___x_3224_ == 0)
{
uint8_t v___x_3225_; uint8_t v___x_3226_;
v___x_3225_ = 5;
v___x_3226_ = lean_uint8_dec_eq(v_effectKind_3201_, v___x_3225_);
if (v___x_3226_ == 0)
{
return v___x_3216_;
}
else
{
uint8_t v___x_3227_;
v___x_3227_ = lean_uint8_dec_eq(v_hasValidLease_3202_, v___x_3213_);
if (v___x_3227_ == 0)
{
return v___x_3216_;
}
else
{
uint8_t v___x_3228_;
v___x_3228_ = lean_uint8_dec_eq(v_idempotencyFresh_3206_, v___x_3213_);
if (v___x_3228_ == 0)
{
return v___x_3216_;
}
else
{
return v___x_3213_;
}
}
}
}
else
{
uint8_t v___x_3229_;
v___x_3229_ = lean_uint8_dec_eq(v_grammarAllowed_3210_, v___x_3213_);
if (v___x_3229_ == 0)
{
return v___x_3216_;
}
else
{
uint8_t v___x_3230_;
v___x_3230_ = lean_uint8_dec_eq(v_envScrubbed_3211_, v___x_3213_);
if (v___x_3230_ == 0)
{
return v___x_3216_;
}
else
{
uint8_t v___x_3231_;
v___x_3231_ = lean_uint8_dec_eq(v_hasValidLease_3202_, v___x_3213_);
if (v___x_3231_ == 0)
{
return v___x_3216_;
}
else
{
uint8_t v___x_3232_;
v___x_3232_ = lean_uint8_dec_eq(v_isArchived_3205_, v___x_3216_);
if (v___x_3232_ == 0)
{
return v___x_3216_;
}
else
{
return v___x_3213_;
}
}
}
}
}
}
else
{
uint8_t v___x_3233_;
v___x_3233_ = lean_uint8_dec_eq(v_accountBound_3207_, v___x_3213_);
if (v___x_3233_ == 0)
{
return v___x_3216_;
}
else
{
uint8_t v___x_3234_;
v___x_3234_ = lean_uint8_dec_eq(v_accountRejected_3208_, v___x_3216_);
if (v___x_3234_ == 0)
{
return v___x_3216_;
}
else
{
uint8_t v___x_3235_;
v___x_3235_ = lean_uint8_dec_eq(v_firstByteLocked_3209_, v___x_3216_);
if (v___x_3235_ == 0)
{
return v___x_3216_;
}
else
{
return v___x_3213_;
}
}
}
}
}
else
{
uint8_t v___x_3236_;
v___x_3236_ = lean_uint8_dec_eq(v_hasValidLease_3202_, v___x_3213_);
if (v___x_3236_ == 0)
{
return v___x_3216_;
}
else
{
uint8_t v___x_3237_;
v___x_3237_ = lean_uint8_dec_eq(v_sessionCreated_3203_, v___x_3213_);
if (v___x_3237_ == 0)
{
return v___x_3216_;
}
else
{
uint8_t v___x_3238_;
v___x_3238_ = lean_uint8_dec_eq(v_lineageVerified_3204_, v___x_3213_);
if (v___x_3238_ == 0)
{
return v___x_3216_;
}
else
{
uint8_t v___x_3239_;
v___x_3239_ = lean_uint8_dec_eq(v_isArchived_3205_, v___x_3216_);
if (v___x_3239_ == 0)
{
return v___x_3216_;
}
else
{
return v___x_3213_;
}
}
}
}
}
}
else
{
uint8_t v___x_3240_;
v___x_3240_ = lean_uint8_dec_eq(v_hasValidLease_3202_, v___x_3213_);
if (v___x_3240_ == 0)
{
return v___x_3216_;
}
else
{
uint8_t v___x_3241_;
v___x_3241_ = lean_uint8_dec_eq(v_isArchived_3205_, v___x_3216_);
if (v___x_3241_ == 0)
{
return v___x_3216_;
}
else
{
uint8_t v___x_3242_;
v___x_3242_ = lean_uint8_dec_eq(v_idempotencyFresh_3206_, v___x_3213_);
if (v___x_3242_ == 0)
{
return v___x_3216_;
}
else
{
return v___x_3213_;
}
}
}
}
}
else
{
return v___x_3213_;
}
}
}
}

LEAN_EXPORT uint64_t orb_provider_pool_step(uint8_t v_hasBoundAccount_3269_, uint32_t v_boundAccountId_3270_, uint32_t v_candidateAccountId_3271_, uint8_t v_isRejected_3272_, uint8_t v_firstByteSent_3273_, uint8_t v_isFailoverAttempt_3274_, uint32_t v_attempts_3275_, uint32_t v_maxAttempts_3276_, uint64_t v_nowEpoch_3277_, uint64_t v_resetEpoch_3278_){
_start:
{
uint32_t v___y_3280_; uint32_t v___y_3281_; uint32_t v___y_3288_; uint32_t v___y_3291_; uint32_t v___y_3295_; uint32_t v___y_3298_; uint8_t v___x_3300_; uint32_t v___y_3302_; uint32_t v___y_3307_; uint8_t v___y_3308_; uint8_t v___y_3312_; uint32_t v___y_3313_; uint8_t v___y_3319_; uint32_t v___y_3320_; uint32_t v___y_3321_; uint8_t v___y_3326_; uint8_t v___y_3327_; uint32_t v___y_3328_; uint8_t v___y_3334_; uint32_t v___y_3335_; uint8_t v___y_3339_; uint8_t v___y_3340_; uint32_t v___y_3341_; uint8_t v___y_3345_; uint32_t v___y_3346_; uint8_t v___y_3347_; uint32_t v___y_3351_; uint8_t v___y_3352_; uint8_t v___x_3359_; uint32_t v___y_3361_;
v___x_3300_ = 1;
v___x_3359_ = lean_uint8_dec_eq(v_firstByteSent_3273_, v___x_3300_);
if (v___x_3359_ == 0)
{
uint32_t v___x_3363_;
v___x_3363_ = 0;
v___y_3361_ = v___x_3363_;
goto v___jp_3360_;
}
else
{
uint32_t v___x_3364_;
v___x_3364_ = 65536;
v___y_3361_ = v___x_3364_;
goto v___jp_3360_;
}
v___jp_3279_:
{
uint64_t v___x_3282_; uint64_t v___x_3283_; uint64_t v___x_3284_; uint64_t v___x_3285_; uint64_t v___x_3286_;
v___x_3282_ = lean_uint32_to_uint64(v___y_3280_);
v___x_3283_ = lean_uint32_to_uint64(v___y_3281_);
v___x_3284_ = 32ULL;
v___x_3285_ = lean_uint64_shift_left(v___x_3283_, v___x_3284_);
v___x_3286_ = lean_uint64_lor(v___x_3282_, v___x_3285_);
return v___x_3286_;
}
v___jp_3287_:
{
uint32_t v___x_3289_;
v___x_3289_ = 0;
v___y_3280_ = v___y_3288_;
v___y_3281_ = v___x_3289_;
goto v___jp_3279_;
}
v___jp_3290_:
{
uint32_t v___x_3292_; uint8_t v___x_3293_;
v___x_3292_ = 0;
v___x_3293_ = lean_uint32_dec_eq(v_candidateAccountId_3271_, v___x_3292_);
if (v___x_3293_ == 0)
{
v___y_3280_ = v___y_3291_;
v___y_3281_ = v_candidateAccountId_3271_;
goto v___jp_3279_;
}
else
{
v___y_3280_ = v___y_3291_;
v___y_3281_ = v___x_3292_;
goto v___jp_3279_;
}
}
v___jp_3294_:
{
uint32_t v___x_3296_;
v___x_3296_ = 0;
v___y_3280_ = v___y_3295_;
v___y_3281_ = v___x_3296_;
goto v___jp_3279_;
}
v___jp_3297_:
{
uint32_t v___x_3299_;
v___x_3299_ = 0;
v___y_3280_ = v___y_3298_;
v___y_3281_ = v___x_3299_;
goto v___jp_3279_;
}
v___jp_3301_:
{
uint8_t v___x_3303_;
v___x_3303_ = lean_uint8_dec_eq(v_isRejected_3272_, v___x_3300_);
if (v___x_3303_ == 0)
{
v___y_3291_ = v___y_3302_;
goto v___jp_3290_;
}
else
{
uint8_t v___x_3304_;
v___x_3304_ = lean_uint64_dec_lt(v_nowEpoch_3277_, v_resetEpoch_3278_);
if (v___x_3304_ == 0)
{
v___y_3291_ = v___y_3302_;
goto v___jp_3290_;
}
else
{
uint32_t v___x_3305_;
v___x_3305_ = 0;
v___y_3280_ = v___y_3302_;
v___y_3281_ = v___x_3305_;
goto v___jp_3279_;
}
}
}
v___jp_3306_:
{
uint8_t v___x_3309_;
v___x_3309_ = lean_uint8_dec_eq(v_hasBoundAccount_3269_, v___x_3300_);
if (v___x_3309_ == 0)
{
v___y_3302_ = v___y_3307_;
goto v___jp_3301_;
}
else
{
uint8_t v___x_3310_;
v___x_3310_ = lean_uint32_dec_eq(v_candidateAccountId_3271_, v_boundAccountId_3270_);
if (v___x_3310_ == 0)
{
v___y_3295_ = v___y_3307_;
goto v___jp_3294_;
}
else
{
if (v___y_3308_ == 0)
{
v___y_3302_ = v___y_3307_;
goto v___jp_3301_;
}
else
{
v___y_3295_ = v___y_3307_;
goto v___jp_3294_;
}
}
}
}
v___jp_3311_:
{
if (v___y_3312_ == 0)
{
uint8_t v___x_3314_;
v___x_3314_ = lean_uint8_dec_eq(v_isFailoverAttempt_3274_, v___x_3300_);
if (v___x_3314_ == 0)
{
v___y_3307_ = v___y_3313_;
v___y_3308_ = v___x_3314_;
goto v___jp_3306_;
}
else
{
uint32_t v___x_3315_; uint8_t v___x_3316_;
v___x_3315_ = 1;
v___x_3316_ = lean_uint32_dec_le(v___x_3315_, v_maxAttempts_3276_);
if (v___x_3316_ == 0)
{
v___y_3298_ = v___y_3313_;
goto v___jp_3297_;
}
else
{
uint8_t v___x_3317_;
v___x_3317_ = lean_uint32_dec_lt(v_attempts_3275_, v_maxAttempts_3276_);
if (v___x_3317_ == 0)
{
v___y_3298_ = v___y_3313_;
goto v___jp_3297_;
}
else
{
v___y_3307_ = v___y_3313_;
v___y_3308_ = v___y_3312_;
goto v___jp_3306_;
}
}
}
}
else
{
v___y_3288_ = v___y_3313_;
goto v___jp_3287_;
}
}
v___jp_3318_:
{
uint32_t v___x_3322_; uint32_t v___x_3323_; uint32_t v___x_3324_;
v___x_3322_ = 256;
v___x_3323_ = lean_uint32_add(v___y_3321_, v___x_3322_);
v___x_3324_ = lean_uint32_add(v___x_3323_, v___y_3320_);
v___y_3312_ = v___y_3319_;
v___y_3313_ = v___x_3324_;
goto v___jp_3311_;
}
v___jp_3325_:
{
uint32_t v___x_3329_; uint8_t v___x_3330_;
v___x_3329_ = 0;
v___x_3330_ = lean_uint32_dec_eq(v_candidateAccountId_3271_, v___x_3329_);
if (v___x_3330_ == 0)
{
if (v___y_3327_ == 0)
{
uint32_t v___x_3331_;
v___x_3331_ = 2;
v___y_3319_ = v___y_3326_;
v___y_3320_ = v___y_3328_;
v___y_3321_ = v___x_3331_;
goto v___jp_3318_;
}
else
{
uint32_t v___x_3332_;
v___x_3332_ = 1;
v___y_3319_ = v___y_3326_;
v___y_3320_ = v___y_3328_;
v___y_3321_ = v___x_3332_;
goto v___jp_3318_;
}
}
else
{
v___y_3312_ = v___y_3326_;
v___y_3313_ = v___y_3328_;
goto v___jp_3311_;
}
}
v___jp_3333_:
{
uint32_t v___x_3336_; uint32_t v___x_3337_;
v___x_3336_ = 4;
v___x_3337_ = lean_uint32_add(v___x_3336_, v___y_3335_);
v___y_3312_ = v___y_3334_;
v___y_3313_ = v___x_3337_;
goto v___jp_3311_;
}
v___jp_3338_:
{
uint8_t v___x_3342_;
v___x_3342_ = lean_uint8_dec_eq(v_isRejected_3272_, v___x_3300_);
if (v___x_3342_ == 0)
{
v___y_3326_ = v___y_3339_;
v___y_3327_ = v___y_3340_;
v___y_3328_ = v___y_3341_;
goto v___jp_3325_;
}
else
{
uint8_t v___x_3343_;
v___x_3343_ = lean_uint64_dec_lt(v_nowEpoch_3277_, v_resetEpoch_3278_);
if (v___x_3343_ == 0)
{
v___y_3326_ = v___y_3339_;
v___y_3327_ = v___y_3340_;
v___y_3328_ = v___y_3341_;
goto v___jp_3325_;
}
else
{
v___y_3312_ = v___y_3339_;
v___y_3313_ = v___y_3341_;
goto v___jp_3311_;
}
}
}
v___jp_3344_:
{
uint8_t v___x_3348_;
v___x_3348_ = lean_uint8_dec_eq(v_hasBoundAccount_3269_, v___x_3300_);
if (v___x_3348_ == 0)
{
v___y_3339_ = v___y_3345_;
v___y_3340_ = v___x_3348_;
v___y_3341_ = v___y_3346_;
goto v___jp_3338_;
}
else
{
uint8_t v___x_3349_;
v___x_3349_ = lean_uint32_dec_eq(v_candidateAccountId_3271_, v_boundAccountId_3270_);
if (v___x_3349_ == 0)
{
v___y_3312_ = v___y_3345_;
v___y_3313_ = v___y_3346_;
goto v___jp_3311_;
}
else
{
if (v___y_3347_ == 0)
{
v___y_3339_ = v___y_3345_;
v___y_3340_ = v___x_3348_;
v___y_3341_ = v___y_3346_;
goto v___jp_3338_;
}
else
{
v___y_3312_ = v___y_3345_;
v___y_3313_ = v___y_3346_;
goto v___jp_3311_;
}
}
}
}
v___jp_3350_:
{
if (v___y_3352_ == 0)
{
uint8_t v___x_3353_;
v___x_3353_ = lean_uint8_dec_eq(v_isFailoverAttempt_3274_, v___x_3300_);
if (v___x_3353_ == 0)
{
v___y_3345_ = v___y_3352_;
v___y_3346_ = v___y_3351_;
v___y_3347_ = v___x_3353_;
goto v___jp_3344_;
}
else
{
uint32_t v___x_3354_; uint8_t v___x_3355_;
v___x_3354_ = 1;
v___x_3355_ = lean_uint32_dec_le(v___x_3354_, v_maxAttempts_3276_);
if (v___x_3355_ == 0)
{
v___y_3334_ = v___y_3352_;
v___y_3335_ = v___y_3351_;
goto v___jp_3333_;
}
else
{
uint8_t v___x_3356_;
v___x_3356_ = lean_uint32_dec_lt(v_attempts_3275_, v_maxAttempts_3276_);
if (v___x_3356_ == 0)
{
v___y_3334_ = v___y_3352_;
v___y_3335_ = v___y_3351_;
goto v___jp_3333_;
}
else
{
v___y_3345_ = v___y_3352_;
v___y_3346_ = v___y_3351_;
v___y_3347_ = v___y_3352_;
goto v___jp_3344_;
}
}
}
}
else
{
uint32_t v___x_3357_; uint32_t v___x_3358_;
v___x_3357_ = 3;
v___x_3358_ = lean_uint32_add(v___x_3357_, v___y_3351_);
v___y_3288_ = v___x_3358_;
goto v___jp_3287_;
}
}
v___jp_3360_:
{
if (v___x_3359_ == 0)
{
v___y_3351_ = v___y_3361_;
v___y_3352_ = v___x_3359_;
goto v___jp_3350_;
}
else
{
uint8_t v___x_3362_;
v___x_3362_ = lean_uint8_dec_eq(v_isFailoverAttempt_3274_, v___x_3300_);
v___y_3351_ = v___y_3361_;
v___y_3352_ = v___x_3362_;
goto v___jp_3350_;
}
}
}
}

LEAN_EXPORT uint64_t orb_route_argmin_step(uint8_t v_hasBest_3387_, uint32_t v_bestId_3388_, uint64_t v_bestScore_3389_, uint32_t v_candId_3390_, uint64_t v_candScore_3391_, uint8_t v_candAdmissible_3392_){
_start:
{
uint32_t v___y_3394_; uint32_t v___y_3395_; uint8_t v___x_3401_; uint32_t v___y_3403_; uint8_t v___y_3407_; uint8_t v___x_3412_;
v___x_3401_ = 1;
v___x_3412_ = lean_uint8_dec_eq(v_candAdmissible_3392_, v___x_3401_);
if (v___x_3412_ == 0)
{
v___y_3407_ = v___x_3412_;
goto v___jp_3406_;
}
else
{
uint8_t v___x_3413_; uint8_t v___x_3414_;
v___x_3413_ = 0;
v___x_3414_ = lean_uint8_dec_eq(v_hasBest_3387_, v___x_3413_);
if (v___x_3414_ == 0)
{
uint8_t v___x_3415_;
v___x_3415_ = lean_uint64_dec_lt(v_candScore_3391_, v_bestScore_3389_);
v___y_3407_ = v___x_3415_;
goto v___jp_3406_;
}
else
{
v___y_3407_ = v___x_3414_;
goto v___jp_3406_;
}
}
v___jp_3393_:
{
uint64_t v___x_3396_; uint64_t v___x_3397_; uint64_t v___x_3398_; uint64_t v___x_3399_; uint64_t v___x_3400_;
v___x_3396_ = lean_uint32_to_uint64(v___y_3394_);
v___x_3397_ = lean_uint32_to_uint64(v___y_3395_);
v___x_3398_ = 32ULL;
v___x_3399_ = lean_uint64_shift_left(v___x_3397_, v___x_3398_);
v___x_3400_ = lean_uint64_lor(v___x_3396_, v___x_3399_);
return v___x_3400_;
}
v___jp_3402_:
{
uint8_t v___x_3404_;
v___x_3404_ = lean_uint8_dec_eq(v_hasBest_3387_, v___x_3401_);
if (v___x_3404_ == 0)
{
uint32_t v___x_3405_;
v___x_3405_ = 0;
v___y_3394_ = v___y_3403_;
v___y_3395_ = v___x_3405_;
goto v___jp_3393_;
}
else
{
v___y_3394_ = v___y_3403_;
v___y_3395_ = v_bestId_3388_;
goto v___jp_3393_;
}
}
v___jp_3406_:
{
if (v___y_3407_ == 0)
{
uint8_t v___x_3408_;
v___x_3408_ = lean_uint8_dec_eq(v_hasBest_3387_, v___x_3401_);
if (v___x_3408_ == 0)
{
uint32_t v___x_3409_;
v___x_3409_ = 0;
v___y_3403_ = v___x_3409_;
goto v___jp_3402_;
}
else
{
uint32_t v___x_3410_;
v___x_3410_ = 1;
v___y_3403_ = v___x_3410_;
goto v___jp_3402_;
}
}
else
{
uint32_t v___x_3411_;
v___x_3411_ = 257;
v___y_3394_ = v___x_3411_;
v___y_3395_ = v_candId_3390_;
goto v___jp_3393_;
}
}
}
}

LEAN_EXPORT uint8_t leansys_verify_slice_bounds(uint64_t v_off_143_, uint64_t v_len_144_, uint64_t v_cap_145_){
_start:
{
uint8_t v___x_146_;
v___x_146_ = lean_uint64_dec_le(v_off_143_, v_cap_145_);
if (v___x_146_ == 0)
{
uint8_t v___x_147_;
v___x_147_ = 0;
return v___x_147_;
}
else
{
uint64_t v___x_148_; uint8_t v___x_149_;
v___x_148_ = lean_uint64_sub(v_cap_145_, v_off_143_);
v___x_149_ = lean_uint64_dec_le(v_len_144_, v___x_148_);
if (v___x_149_ == 0)
{
uint8_t v___x_150_;
v___x_150_ = 0;
return v___x_150_;
}
else
{
uint8_t v___x_151_;
v___x_151_ = 1;
return v___x_151_;
}
}
}
}

LEAN_EXPORT uint8_t leansys_verify_wal_frame(uint32_t v_magic_333_, uint32_t v_payloadLen_334_, uint64_t v_actualBytes_335_, uint64_t v_expectedHash_336_, uint64_t v_computedHash_337_){
_start:
{
uint32_t v___x_338_; uint8_t v___x_339_;
v___x_338_ = 1280530771;
v___x_339_ = lean_uint32_dec_eq(v_magic_333_, v___x_338_);
if (v___x_339_ == 0)
{
uint8_t v___x_340_;
v___x_340_ = 0;
return v___x_340_;
}
else
{
uint32_t v___x_341_; uint8_t v___x_342_;
v___x_341_ = 0;
v___x_342_ = lean_uint32_dec_lt(v___x_341_, v_payloadLen_334_);
if (v___x_342_ == 0)
{
uint8_t v___x_343_;
v___x_343_ = 0;
return v___x_343_;
}
else
{
uint32_t v___x_344_; uint8_t v___x_345_;
v___x_344_ = 16777216;
v___x_345_ = lean_uint32_dec_le(v_payloadLen_334_, v___x_344_);
if (v___x_345_ == 0)
{
uint8_t v___x_346_;
v___x_346_ = 0;
return v___x_346_;
}
else
{
uint64_t v___x_347_; uint8_t v___x_348_;
v___x_347_ = lean_uint32_to_uint64(v_payloadLen_334_);
v___x_348_ = lean_uint64_dec_eq(v_actualBytes_335_, v___x_347_);
if (v___x_348_ == 0)
{
uint8_t v___x_349_;
v___x_349_ = 0;
return v___x_349_;
}
else
{
uint8_t v___x_350_;
v___x_350_ = lean_uint64_dec_eq(v_expectedHash_336_, v_computedHash_337_);
if (v___x_350_ == 0)
{
uint8_t v___x_351_;
v___x_351_ = 0;
return v___x_351_;
}
else
{
uint8_t v___x_352_;
v___x_352_ = 1;
return v___x_352_;
}
}
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_verify_cas_digest(uint64_t v_expectedDigest_428_, uint64_t v_computedDigest_429_, uint8_t v_hasPathSep_430_){
_start:
{
uint64_t v___x_431_; uint8_t v___x_432_;
v___x_431_ = 0ULL;
v___x_432_ = lean_uint64_dec_eq(v_expectedDigest_428_, v___x_431_);
if (v___x_432_ == 0)
{
uint8_t v___x_433_;
v___x_433_ = lean_uint64_dec_eq(v_expectedDigest_428_, v_computedDigest_429_);
if (v___x_433_ == 0)
{
uint8_t v___x_434_;
v___x_434_ = 0;
return v___x_434_;
}
else
{
uint8_t v___x_435_; uint8_t v___x_436_;
v___x_435_ = 0;
v___x_436_ = lean_uint8_dec_eq(v_hasPathSep_430_, v___x_435_);
if (v___x_436_ == 0)
{
return v___x_435_;
}
else
{
uint8_t v___x_437_;
v___x_437_ = 1;
return v___x_437_;
}
}
}
else
{
uint8_t v___x_438_;
v___x_438_ = 0;
return v___x_438_;
}
}
}

LEAN_EXPORT uint8_t leansys_check_http_bounds(uint32_t v_numHeaders_447_, uint64_t v_contentLen_448_, uint64_t v_actualBodyLen_449_, uint8_t v_authOk_450_){
_start:
{
uint32_t v___x_451_; uint8_t v___x_452_;
v___x_451_ = 32;
v___x_452_ = lean_uint32_dec_le(v_numHeaders_447_, v___x_451_);
if (v___x_452_ == 0)
{
uint8_t v___x_453_;
v___x_453_ = 0;
return v___x_453_;
}
else
{
uint64_t v___x_454_; uint8_t v___x_455_;
v___x_454_ = 4194304ULL;
v___x_455_ = lean_uint64_dec_le(v_contentLen_448_, v___x_454_);
if (v___x_455_ == 0)
{
uint8_t v___x_456_;
v___x_456_ = 0;
return v___x_456_;
}
else
{
uint8_t v___x_457_;
v___x_457_ = lean_uint64_dec_eq(v_actualBodyLen_449_, v_contentLen_448_);
if (v___x_457_ == 0)
{
uint8_t v___x_458_;
v___x_458_ = 0;
return v___x_458_;
}
else
{
uint8_t v___x_459_; uint8_t v___x_460_;
v___x_459_ = 1;
v___x_460_ = lean_uint8_dec_eq(v_authOk_450_, v___x_459_);
if (v___x_460_ == 0)
{
uint8_t v___x_461_;
v___x_461_ = 0;
return v___x_461_;
}
else
{
return v___x_459_;
}
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_verify_jsonl_tape(uint64_t v_keyOff_1049_, uint64_t v_keyLen_1050_, uint64_t v_valOff_1051_, uint64_t v_valLen_1052_, uint64_t v_bufCap_1053_, uint32_t v_depth_1054_){
_start:
{
uint8_t v___x_1055_;
v___x_1055_ = lean_uint64_dec_le(v_keyOff_1049_, v_bufCap_1053_);
if (v___x_1055_ == 0)
{
uint8_t v___x_1056_;
v___x_1056_ = 0;
return v___x_1056_;
}
else
{
uint64_t v___x_1057_; uint8_t v___x_1058_;
v___x_1057_ = lean_uint64_sub(v_bufCap_1053_, v_keyOff_1049_);
v___x_1058_ = lean_uint64_dec_le(v_keyLen_1050_, v___x_1057_);
if (v___x_1058_ == 0)
{
uint8_t v___x_1059_;
v___x_1059_ = 0;
return v___x_1059_;
}
else
{
uint8_t v___x_1060_;
v___x_1060_ = lean_uint64_dec_le(v_valOff_1051_, v_bufCap_1053_);
if (v___x_1060_ == 0)
{
uint8_t v___x_1061_;
v___x_1061_ = 0;
return v___x_1061_;
}
else
{
uint64_t v___x_1062_; uint8_t v___x_1063_;
v___x_1062_ = lean_uint64_sub(v_bufCap_1053_, v_valOff_1051_);
v___x_1063_ = lean_uint64_dec_le(v_valLen_1052_, v___x_1062_);
if (v___x_1063_ == 0)
{
uint8_t v___x_1064_;
v___x_1064_ = 0;
return v___x_1064_;
}
else
{
uint64_t v___x_1065_; uint8_t v___x_1066_;
v___x_1065_ = lean_uint64_add(v_keyOff_1049_, v_keyLen_1050_);
v___x_1066_ = lean_uint64_dec_le(v___x_1065_, v_valOff_1051_);
if (v___x_1066_ == 0)
{
uint8_t v___x_1067_;
v___x_1067_ = 0;
return v___x_1067_;
}
else
{
uint32_t v___x_1068_; uint8_t v___x_1069_;
v___x_1068_ = 64;
v___x_1069_ = lean_uint32_dec_le(v_depth_1054_, v___x_1068_);
if (v___x_1069_ == 0)
{
uint8_t v___x_1070_;
v___x_1070_ = 0;
return v___x_1070_;
}
else
{
uint8_t v___x_1071_;
v___x_1071_ = 1;
return v___x_1071_;
}
}
}
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_verify_ring_cursor(uint64_t v_head_1302_, uint64_t v_tail_1303_, uint64_t v_cap_1304_, uint64_t v_msgLen_1305_){
_start:
{
uint64_t v___x_1306_; uint8_t v___x_1307_;
v___x_1306_ = 0ULL;
v___x_1307_ = lean_uint64_dec_lt(v___x_1306_, v_cap_1304_);
if (v___x_1307_ == 0)
{
uint8_t v___x_1308_;
v___x_1308_ = 0;
return v___x_1308_;
}
else
{
uint8_t v___x_1309_;
v___x_1309_ = lean_uint64_dec_le(v_tail_1303_, v_head_1302_);
if (v___x_1309_ == 0)
{
uint8_t v___x_1310_;
v___x_1310_ = 0;
return v___x_1310_;
}
else
{
uint64_t v___x_1311_; uint8_t v___x_1312_;
v___x_1311_ = lean_uint64_sub(v_head_1302_, v_tail_1303_);
v___x_1312_ = lean_uint64_dec_le(v___x_1311_, v_cap_1304_);
if (v___x_1312_ == 0)
{
uint8_t v___x_1313_;
v___x_1313_ = 0;
return v___x_1313_;
}
else
{
uint64_t v___x_1314_; uint8_t v___x_1315_;
v___x_1314_ = lean_uint64_sub(v_cap_1304_, v___x_1311_);
v___x_1315_ = lean_uint64_dec_le(v_msgLen_1305_, v___x_1314_);
if (v___x_1315_ == 0)
{
uint8_t v___x_1316_;
v___x_1316_ = 0;
return v___x_1316_;
}
else
{
uint8_t v___x_1317_;
v___x_1317_ = 1;
return v___x_1317_;
}
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_verify_sst_block(uint32_t v_magic_1497_, uint32_t v_numEntries_1498_, uint64_t v_indexOff_1499_, uint64_t v_footerOff_1500_, uint64_t v_fileSize_1501_, uint64_t v_bloomMask_1502_){
_start:
{
uint32_t v___x_1503_; uint8_t v___x_1504_;
v___x_1503_ = 1280529236;
v___x_1504_ = lean_uint32_dec_eq(v_magic_1497_, v___x_1503_);
if (v___x_1504_ == 0)
{
uint8_t v___x_1505_;
v___x_1505_ = 0;
return v___x_1505_;
}
else
{
uint8_t v___x_1506_;
v___x_1506_ = lean_uint64_dec_le(v_indexOff_1499_, v_footerOff_1500_);
if (v___x_1506_ == 0)
{
uint8_t v___x_1507_;
v___x_1507_ = 0;
return v___x_1507_;
}
else
{
uint8_t v___x_1508_;
v___x_1508_ = lean_uint64_dec_le(v_footerOff_1500_, v_fileSize_1501_);
if (v___x_1508_ == 0)
{
uint8_t v___x_1509_;
v___x_1509_ = 0;
return v___x_1509_;
}
else
{
uint32_t v___x_1510_; uint8_t v___x_1511_;
v___x_1510_ = 0;
v___x_1511_ = lean_uint32_dec_eq(v_numEntries_1498_, v___x_1510_);
if (v___x_1511_ == 0)
{
uint64_t v___x_1512_; uint8_t v___x_1513_;
v___x_1512_ = 0ULL;
v___x_1513_ = lean_uint64_dec_eq(v_bloomMask_1502_, v___x_1512_);
if (v___x_1513_ == 0)
{
uint8_t v___x_1514_;
v___x_1514_ = 1;
return v___x_1514_;
}
else
{
uint8_t v___x_1515_;
v___x_1515_ = 0;
return v___x_1515_;
}
}
else
{
uint8_t v___x_1516_;
v___x_1516_ = 1;
return v___x_1516_;
}
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_verify_poll_interest(uint32_t v_activeConns_1739_, uint32_t v_maxConns_1740_, uint32_t v_keepAliveReqs_1741_, uint32_t v_maxKeepAlive_1742_, uint32_t v_idleMs_1743_, uint32_t v_maxIdleMs_1744_){
_start:
{
uint8_t v___x_1745_;
v___x_1745_ = lean_uint32_dec_le(v_activeConns_1739_, v_maxConns_1740_);
if (v___x_1745_ == 0)
{
uint8_t v___x_1746_;
v___x_1746_ = 0;
return v___x_1746_;
}
else
{
uint32_t v___x_1747_; uint8_t v___x_1748_;
v___x_1747_ = 1024;
v___x_1748_ = lean_uint32_dec_le(v_maxConns_1740_, v___x_1747_);
if (v___x_1748_ == 0)
{
uint8_t v___x_1749_;
v___x_1749_ = 0;
return v___x_1749_;
}
else
{
uint8_t v___x_1750_;
v___x_1750_ = lean_uint32_dec_lt(v_keepAliveReqs_1741_, v_maxKeepAlive_1742_);
if (v___x_1750_ == 0)
{
uint8_t v___x_1751_;
v___x_1751_ = 0;
return v___x_1751_;
}
else
{
uint8_t v___x_1752_;
v___x_1752_ = lean_uint32_dec_le(v_idleMs_1743_, v_maxIdleMs_1744_);
if (v___x_1752_ == 0)
{
uint8_t v___x_1753_;
v___x_1753_ = 0;
return v___x_1753_;
}
else
{
uint8_t v___x_1754_;
v___x_1754_ = 1;
return v___x_1754_;
}
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_verify_rlimit_budget(uint64_t v_rssBytes_1977_, uint64_t v_maxRssBytes_1978_, uint64_t v_elapsedMs_1979_, uint64_t v_timeoutMs_1980_, uint64_t v_pipeBytes_1981_, uint64_t v_maxPipeBytes_1982_){
_start:
{
uint8_t v___x_1983_;
v___x_1983_ = lean_uint64_dec_le(v_rssBytes_1977_, v_maxRssBytes_1978_);
if (v___x_1983_ == 0)
{
uint8_t v___x_1984_;
v___x_1984_ = 0;
return v___x_1984_;
}
else
{
uint8_t v___x_1985_;
v___x_1985_ = lean_uint64_dec_le(v_elapsedMs_1979_, v_timeoutMs_1980_);
if (v___x_1985_ == 0)
{
uint8_t v___x_1986_;
v___x_1986_ = 0;
return v___x_1986_;
}
else
{
uint8_t v___x_1987_;
v___x_1987_ = lean_uint64_dec_le(v_pipeBytes_1981_, v_maxPipeBytes_1982_);
if (v___x_1987_ == 0)
{
uint8_t v___x_1988_;
v___x_1988_ = 0;
return v___x_1988_;
}
else
{
uint8_t v___x_1989_;
v___x_1989_ = 1;
return v___x_1989_;
}
}
}
}
}

LEAN_EXPORT uint64_t leansys_mix64_word(uint64_t v_acc_2205_, uint64_t v_word_2206_){
_start:
{
uint64_t v___x_2207_; uint64_t v___x_2208_; uint64_t v___x_2209_; uint64_t v___x_2210_; uint64_t v_z_2211_; uint64_t v___x_2212_; uint64_t v___x_2213_; uint64_t v___x_2214_; uint64_t v___x_2215_; uint64_t v_z1_2216_; uint64_t v___x_2217_; uint64_t v___x_2218_; uint64_t v___x_2219_;
v___x_2207_ = 11400714819323198485ULL;
v___x_2208_ = lean_uint64_mul(v_word_2206_, v___x_2207_);
v___x_2209_ = lean_uint64_xor(v_acc_2205_, v___x_2208_);
v___x_2210_ = 13787848793156543929ULL;
v_z_2211_ = lean_uint64_mul(v___x_2209_, v___x_2210_);
v___x_2212_ = 30ULL;
v___x_2213_ = lean_uint64_shift_right(v_z_2211_, v___x_2212_);
v___x_2214_ = lean_uint64_xor(v_z_2211_, v___x_2213_);
v___x_2215_ = 10723151780598845931ULL;
v_z1_2216_ = lean_uint64_mul(v___x_2214_, v___x_2215_);
v___x_2217_ = 31ULL;
v___x_2218_ = lean_uint64_shift_right(v_z1_2216_, v___x_2217_);
v___x_2219_ = lean_uint64_xor(v_z1_2216_, v___x_2218_);
return v___x_2219_;
}
}

LEAN_EXPORT uint8_t leansys_verify_composite_key_order(uint64_t v_hiA_2226_, uint64_t v_loA_2227_, uint64_t v_seqA_2228_, uint64_t v_hiB_2229_, uint64_t v_loB_2230_, uint64_t v_seqB_2231_){
_start:
{
uint8_t v___x_2232_;
v___x_2232_ = lean_uint64_dec_lt(v_hiA_2226_, v_hiB_2229_);
if (v___x_2232_ == 0)
{
uint8_t v___x_2233_;
v___x_2233_ = lean_uint64_dec_eq(v_hiA_2226_, v_hiB_2229_);
if (v___x_2233_ == 0)
{
uint8_t v___x_2234_;
v___x_2234_ = 0;
return v___x_2234_;
}
else
{
uint8_t v___x_2235_;
v___x_2235_ = lean_uint64_dec_lt(v_loA_2227_, v_loB_2230_);
if (v___x_2235_ == 0)
{
uint8_t v___x_2236_;
v___x_2236_ = lean_uint64_dec_eq(v_loA_2227_, v_loB_2230_);
if (v___x_2236_ == 0)
{
uint8_t v___x_2237_;
v___x_2237_ = 0;
return v___x_2237_;
}
else
{
uint8_t v___x_2238_;
v___x_2238_ = lean_uint64_dec_le(v_seqA_2228_, v_seqB_2231_);
if (v___x_2238_ == 0)
{
uint8_t v___x_2239_;
v___x_2239_ = 0;
return v___x_2239_;
}
else
{
uint8_t v___x_2240_;
v___x_2240_ = 1;
return v___x_2240_;
}
}
}
else
{
uint8_t v___x_2241_;
v___x_2241_ = 1;
return v___x_2241_;
}
}
}
else
{
uint8_t v___x_2242_;
v___x_2242_ = 1;
return v___x_2242_;
}
}
}

LEAN_EXPORT uint8_t leansys_verify_token_auth(uint8_t v_matchCurrent_2462_, uint8_t v_hasPrev_2463_, uint8_t v_matchPrev_2464_, uint8_t v_scopeOk_2465_, uint64_t v_nowEpoch_2466_, uint64_t v_expiresAt_2467_){
_start:
{
uint8_t v___x_2468_; uint8_t v___x_2474_;
v___x_2468_ = 1;
v___x_2474_ = lean_uint8_dec_eq(v_matchCurrent_2462_, v___x_2468_);
if (v___x_2474_ == 0)
{
uint8_t v___x_2475_;
v___x_2475_ = lean_uint8_dec_eq(v_hasPrev_2463_, v___x_2468_);
if (v___x_2475_ == 0)
{
uint8_t v___x_2476_;
v___x_2476_ = 0;
return v___x_2476_;
}
else
{
uint8_t v___x_2477_;
v___x_2477_ = lean_uint8_dec_eq(v_matchPrev_2464_, v___x_2468_);
if (v___x_2477_ == 0)
{
uint8_t v___x_2478_;
v___x_2478_ = 0;
return v___x_2478_;
}
else
{
goto v___jp_2469_;
}
}
}
else
{
goto v___jp_2469_;
}
v___jp_2469_:
{
uint8_t v___x_2470_;
v___x_2470_ = lean_uint8_dec_eq(v_scopeOk_2465_, v___x_2468_);
if (v___x_2470_ == 0)
{
uint8_t v___x_2471_;
v___x_2471_ = 0;
return v___x_2471_;
}
else
{
uint8_t v___x_2472_;
v___x_2472_ = lean_uint64_dec_lt(v_nowEpoch_2466_, v_expiresAt_2467_);
if (v___x_2472_ == 0)
{
uint8_t v___x_2473_;
v___x_2473_ = 0;
return v___x_2473_;
}
else
{
return v___x_2468_;
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_verify_log_window(uint64_t v_startOff_2705_, uint64_t v_nextOff_2706_, uint64_t v_fileLen_2707_, uint64_t v_maxBytes_2708_){
_start:
{
uint8_t v___x_2709_;
v___x_2709_ = lean_uint64_dec_le(v_startOff_2705_, v_nextOff_2706_);
if (v___x_2709_ == 0)
{
uint8_t v___x_2710_;
v___x_2710_ = 0;
return v___x_2710_;
}
else
{
uint8_t v___x_2711_;
v___x_2711_ = lean_uint64_dec_le(v_nextOff_2706_, v_fileLen_2707_);
if (v___x_2711_ == 0)
{
uint8_t v___x_2712_;
v___x_2712_ = 0;
return v___x_2712_;
}
else
{
uint64_t v___x_2713_; uint8_t v___x_2714_;
v___x_2713_ = lean_uint64_sub(v_nextOff_2706_, v_startOff_2705_);
v___x_2714_ = lean_uint64_dec_le(v___x_2713_, v_maxBytes_2708_);
if (v___x_2714_ == 0)
{
uint8_t v___x_2715_;
v___x_2715_ = 0;
return v___x_2715_;
}
else
{
uint64_t v___x_2716_; uint8_t v___x_2717_;
v___x_2716_ = 262144ULL;
v___x_2717_ = lean_uint64_dec_le(v_maxBytes_2708_, v___x_2716_);
if (v___x_2717_ == 0)
{
uint8_t v___x_2718_;
v___x_2718_ = 0;
return v___x_2718_;
}
else
{
uint8_t v___x_2719_;
v___x_2719_ = 1;
return v___x_2719_;
}
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_verify_jsonrpc_frame(uint8_t v_hasV2_2896_, uint8_t v_hasId_2897_, uint32_t v_methodLen_2898_, uint64_t v_payloadLen_2899_){
_start:
{
uint8_t v___x_2900_; uint8_t v___x_2901_;
v___x_2900_ = 1;
v___x_2901_ = lean_uint8_dec_eq(v_hasV2_2896_, v___x_2900_);
if (v___x_2901_ == 0)
{
uint8_t v___x_2902_;
v___x_2902_ = 0;
return v___x_2902_;
}
else
{
uint8_t v___x_2903_;
v___x_2903_ = lean_uint8_dec_le(v_hasId_2897_, v___x_2900_);
if (v___x_2903_ == 0)
{
uint8_t v___x_2904_;
v___x_2904_ = 0;
return v___x_2904_;
}
else
{
uint32_t v___x_2905_; uint8_t v___x_2906_;
v___x_2905_ = 0;
v___x_2906_ = lean_uint32_dec_lt(v___x_2905_, v_methodLen_2898_);
if (v___x_2906_ == 0)
{
uint8_t v___x_2907_;
v___x_2907_ = 0;
return v___x_2907_;
}
else
{
uint32_t v___x_2908_; uint8_t v___x_2909_;
v___x_2908_ = 128;
v___x_2909_ = lean_uint32_dec_le(v_methodLen_2898_, v___x_2908_);
if (v___x_2909_ == 0)
{
uint8_t v___x_2910_;
v___x_2910_ = 0;
return v___x_2910_;
}
else
{
uint64_t v___x_2911_; uint8_t v___x_2912_;
v___x_2911_ = 4194304ULL;
v___x_2912_ = lean_uint64_dec_le(v_payloadLen_2899_, v___x_2911_);
if (v___x_2912_ == 0)
{
uint8_t v___x_2913_;
v___x_2913_ = 0;
return v___x_2913_;
}
else
{
return v___x_2900_;
}
}
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_gate_admit(uint8_t v_noSorryAx_3094_, uint8_t v_statementPinned_3095_, uint8_t v_certVerified_3096_){
_start:
{
uint8_t v___x_3097_; uint8_t v___x_3098_;
v___x_3097_ = 1;
v___x_3098_ = lean_uint8_dec_eq(v_noSorryAx_3094_, v___x_3097_);
if (v___x_3098_ == 0)
{
uint8_t v___x_3099_;
v___x_3099_ = 0;
return v___x_3099_;
}
else
{
uint8_t v___x_3100_;
v___x_3100_ = lean_uint8_dec_eq(v_statementPinned_3095_, v___x_3097_);
if (v___x_3100_ == 0)
{
uint8_t v___x_3101_;
v___x_3101_ = 0;
return v___x_3101_;
}
else
{
uint8_t v___x_3102_;
v___x_3102_ = lean_uint8_dec_eq(v_certVerified_3096_, v___x_3097_);
if (v___x_3102_ == 0)
{
uint8_t v___x_3103_;
v___x_3103_ = 0;
return v___x_3103_;
}
else
{
return v___x_3097_;
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_verify_mmap_seqlock(uint32_t v_magic_3256_, uint32_t v_schemaVersion_3257_, uint32_t v_expectedVersion_3258_, uint64_t v_seqBefore_3259_, uint64_t v_seqAfter_3260_, uint64_t v_writerEpoch_3261_, uint64_t v_minEpoch_3262_, uint64_t v_payloadLen_3263_, uint64_t v_ringCap_3264_){
_start:
{
uint32_t v___x_3265_; uint8_t v___x_3266_;
v___x_3265_ = 1280527693;
v___x_3266_ = lean_uint32_dec_eq(v_magic_3256_, v___x_3265_);
if (v___x_3266_ == 0)
{
uint8_t v___x_3267_;
v___x_3267_ = 0;
return v___x_3267_;
}
else
{
uint8_t v___x_3268_;
v___x_3268_ = lean_uint32_dec_eq(v_schemaVersion_3257_, v_expectedVersion_3258_);
if (v___x_3268_ == 0)
{
uint8_t v___x_3269_;
v___x_3269_ = 0;
return v___x_3269_;
}
else
{
uint8_t v___x_3270_;
v___x_3270_ = lean_uint64_dec_eq(v_seqBefore_3259_, v_seqAfter_3260_);
if (v___x_3270_ == 0)
{
uint8_t v___x_3271_;
v___x_3271_ = 0;
return v___x_3271_;
}
else
{
uint64_t v___x_3272_; uint64_t v___x_3273_; uint64_t v___x_3274_; uint8_t v___x_3275_;
v___x_3272_ = 2ULL;
v___x_3273_ = lean_uint64_mod(v_seqBefore_3259_, v___x_3272_);
v___x_3274_ = 0ULL;
v___x_3275_ = lean_uint64_dec_eq(v___x_3273_, v___x_3274_);
if (v___x_3275_ == 0)
{
uint8_t v___x_3276_;
v___x_3276_ = 0;
return v___x_3276_;
}
else
{
uint8_t v___x_3277_;
v___x_3277_ = lean_uint64_dec_le(v_minEpoch_3262_, v_writerEpoch_3261_);
if (v___x_3277_ == 0)
{
uint8_t v___x_3278_;
v___x_3278_ = 0;
return v___x_3278_;
}
else
{
uint8_t v___x_3279_;
v___x_3279_ = lean_uint64_dec_le(v_payloadLen_3263_, v_ringCap_3264_);
if (v___x_3279_ == 0)
{
uint8_t v___x_3280_;
v___x_3280_ = 0;
return v___x_3280_;
}
else
{
uint8_t v___x_3281_;
v___x_3281_ = 1;
return v___x_3281_;
}
}
}
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_verify_proc_stat_fields(uint64_t v_commOpenIdx_3707_, uint64_t v_commCloseIdx_3708_, uint64_t v_totalLen_3709_, uint64_t v_minFieldsAfterComm_3710_, uint64_t v_actualFields_3711_){
_start:
{
uint8_t v___x_3712_;
v___x_3712_ = lean_uint64_dec_lt(v_commOpenIdx_3707_, v_commCloseIdx_3708_);
if (v___x_3712_ == 0)
{
uint8_t v___x_3713_;
v___x_3713_ = 0;
return v___x_3713_;
}
else
{
uint64_t v___x_3714_; uint64_t v___x_3715_; uint8_t v___x_3716_;
v___x_3714_ = 2ULL;
v___x_3715_ = lean_uint64_add(v_commCloseIdx_3708_, v___x_3714_);
v___x_3716_ = lean_uint64_dec_le(v___x_3715_, v_totalLen_3709_);
if (v___x_3716_ == 0)
{
uint8_t v___x_3717_;
v___x_3717_ = 0;
return v___x_3717_;
}
else
{
uint8_t v___x_3718_;
v___x_3718_ = lean_uint64_dec_le(v_minFieldsAfterComm_3710_, v_actualFields_3711_);
if (v___x_3718_ == 0)
{
uint8_t v___x_3719_;
v___x_3719_ = 0;
return v___x_3719_;
}
else
{
uint8_t v___x_3720_;
v___x_3720_ = 1;
return v___x_3720_;
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_sse_frame_scan(uint64_t v_frameOff_3976_, uint64_t v_frameLen_3977_, uint64_t v_chunkLen_3978_, uint8_t v_fieldKind_3979_, uint8_t v_nextByte_3980_, uint8_t v_lastByte_3981_){
_start:
{
uint64_t v___x_3987_; uint8_t v___x_3988_;
v___x_3987_ = 0ULL;
v___x_3988_ = lean_uint64_dec_lt(v___x_3987_, v_frameLen_3977_);
if (v___x_3988_ == 0)
{
uint8_t v___x_3989_;
v___x_3989_ = 0;
return v___x_3989_;
}
else
{
uint8_t v___x_3990_;
v___x_3990_ = lean_uint64_dec_le(v_frameOff_3976_, v_chunkLen_3978_);
if (v___x_3990_ == 0)
{
uint8_t v___x_3991_;
v___x_3991_ = 0;
return v___x_3991_;
}
else
{
uint64_t v___x_3992_; uint8_t v___x_3993_;
v___x_3992_ = lean_uint64_sub(v_chunkLen_3978_, v_frameOff_3976_);
v___x_3993_ = lean_uint64_dec_le(v_frameLen_3977_, v___x_3992_);
if (v___x_3993_ == 0)
{
uint8_t v___x_3994_;
v___x_3994_ = 0;
return v___x_3994_;
}
else
{
uint8_t v___x_3995_; uint8_t v___x_3996_;
v___x_3995_ = 1;
v___x_3996_ = lean_uint8_dec_le(v___x_3995_, v_fieldKind_3979_);
if (v___x_3996_ == 0)
{
uint8_t v___x_3997_;
v___x_3997_ = 0;
return v___x_3997_;
}
else
{
uint8_t v___x_3998_; uint8_t v___x_3999_;
v___x_3998_ = 4;
v___x_3999_ = lean_uint8_dec_le(v_fieldKind_3979_, v___x_3998_);
if (v___x_3999_ == 0)
{
uint8_t v___x_4000_;
v___x_4000_ = 0;
return v___x_4000_;
}
else
{
uint8_t v___x_4001_; uint8_t v___x_4002_;
v___x_4001_ = 128;
v___x_4002_ = lean_uint8_dec_lt(v_nextByte_3980_, v___x_4001_);
if (v___x_4002_ == 0)
{
uint8_t v___x_4003_; uint8_t v___x_4004_;
v___x_4003_ = 191;
v___x_4004_ = lean_uint8_dec_lt(v___x_4003_, v_nextByte_3980_);
if (v___x_4004_ == 0)
{
uint8_t v___x_4005_;
v___x_4005_ = 0;
return v___x_4005_;
}
else
{
goto v___jp_3982_;
}
}
else
{
goto v___jp_3982_;
}
}
}
}
}
}
v___jp_3982_:
{
uint8_t v___x_3983_; uint8_t v___x_3984_;
v___x_3983_ = 192;
v___x_3984_ = lean_uint8_dec_lt(v_lastByte_3981_, v___x_3983_);
if (v___x_3984_ == 0)
{
uint8_t v___x_3985_;
v___x_3985_ = 0;
return v___x_3985_;
}
else
{
uint8_t v___x_3986_;
v___x_3986_ = 1;
return v___x_3986_;
}
}
}
}

LEAN_EXPORT uint8_t leansys_gfm_pipe_scan(uint64_t v_rowOff_4249_, uint64_t v_rowLen_4250_, uint64_t v_bufLen_4251_, uint32_t v_colCount_4252_, uint32_t v_sepCols_4253_, uint8_t v_unterminatedEscape_4254_){
_start:
{
uint64_t v___x_4255_; uint8_t v___x_4256_;
v___x_4255_ = 0ULL;
v___x_4256_ = lean_uint64_dec_lt(v___x_4255_, v_rowLen_4250_);
if (v___x_4256_ == 0)
{
uint8_t v___x_4257_;
v___x_4257_ = 0;
return v___x_4257_;
}
else
{
uint8_t v___x_4258_;
v___x_4258_ = lean_uint64_dec_le(v_rowOff_4249_, v_bufLen_4251_);
if (v___x_4258_ == 0)
{
uint8_t v___x_4259_;
v___x_4259_ = 0;
return v___x_4259_;
}
else
{
uint64_t v___x_4260_; uint8_t v___x_4261_;
v___x_4260_ = lean_uint64_sub(v_bufLen_4251_, v_rowOff_4249_);
v___x_4261_ = lean_uint64_dec_le(v_rowLen_4250_, v___x_4260_);
if (v___x_4261_ == 0)
{
uint8_t v___x_4262_;
v___x_4262_ = 0;
return v___x_4262_;
}
else
{
uint32_t v___x_4263_; uint8_t v___x_4264_;
v___x_4263_ = 0;
v___x_4264_ = lean_uint32_dec_lt(v___x_4263_, v_colCount_4252_);
if (v___x_4264_ == 0)
{
uint8_t v___x_4265_;
v___x_4265_ = 0;
return v___x_4265_;
}
else
{
uint32_t v___x_4266_; uint8_t v___x_4267_;
v___x_4266_ = 64;
v___x_4267_ = lean_uint32_dec_le(v_colCount_4252_, v___x_4266_);
if (v___x_4267_ == 0)
{
uint8_t v___x_4268_;
v___x_4268_ = 0;
return v___x_4268_;
}
else
{
uint8_t v___x_4269_;
v___x_4269_ = lean_uint32_dec_eq(v_colCount_4252_, v_sepCols_4253_);
if (v___x_4269_ == 0)
{
uint8_t v___x_4270_;
v___x_4270_ = 0;
return v___x_4270_;
}
else
{
uint8_t v___x_4271_; uint8_t v___x_4272_;
v___x_4271_ = 0;
v___x_4272_ = lean_uint8_dec_eq(v_unterminatedEscape_4254_, v___x_4271_);
if (v___x_4272_ == 0)
{
return v___x_4271_;
}
else
{
uint8_t v___x_4273_;
v___x_4273_ = 1;
return v___x_4273_;
}
}
}
}
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_tag_scan(uint64_t v_tagOff_4507_, uint64_t v_tagLen_4508_, uint64_t v_attrOff_4509_, uint64_t v_attrLen_4510_, uint64_t v_bufLen_4511_, uint8_t v_tagKind_4512_){
_start:
{
uint64_t v___x_4513_; uint8_t v___x_4514_;
v___x_4513_ = 0ULL;
v___x_4514_ = lean_uint64_dec_lt(v___x_4513_, v_tagLen_4508_);
if (v___x_4514_ == 0)
{
uint8_t v___x_4515_;
v___x_4515_ = 0;
return v___x_4515_;
}
else
{
uint8_t v___x_4516_;
v___x_4516_ = lean_uint64_dec_le(v_tagOff_4507_, v_bufLen_4511_);
if (v___x_4516_ == 0)
{
uint8_t v___x_4517_;
v___x_4517_ = 0;
return v___x_4517_;
}
else
{
uint64_t v___x_4518_; uint8_t v___x_4519_;
v___x_4518_ = lean_uint64_sub(v_bufLen_4511_, v_tagOff_4507_);
v___x_4519_ = lean_uint64_dec_le(v_tagLen_4508_, v___x_4518_);
if (v___x_4519_ == 0)
{
uint8_t v___x_4520_;
v___x_4520_ = 0;
return v___x_4520_;
}
else
{
uint8_t v___x_4521_;
v___x_4521_ = lean_uint64_dec_le(v_tagOff_4507_, v_attrOff_4509_);
if (v___x_4521_ == 0)
{
uint8_t v___x_4522_;
v___x_4522_ = 0;
return v___x_4522_;
}
else
{
uint64_t v___x_4523_; uint8_t v___x_4524_;
v___x_4523_ = lean_uint64_sub(v_attrOff_4509_, v_tagOff_4507_);
v___x_4524_ = lean_uint64_dec_le(v___x_4523_, v_tagLen_4508_);
if (v___x_4524_ == 0)
{
uint8_t v___x_4525_;
v___x_4525_ = 0;
return v___x_4525_;
}
else
{
uint64_t v___x_4526_; uint8_t v___x_4527_;
v___x_4526_ = lean_uint64_sub(v_tagLen_4508_, v___x_4523_);
v___x_4527_ = lean_uint64_dec_le(v_attrLen_4510_, v___x_4526_);
if (v___x_4527_ == 0)
{
uint8_t v___x_4528_;
v___x_4528_ = 0;
return v___x_4528_;
}
else
{
uint8_t v___x_4529_; uint8_t v___x_4530_;
v___x_4529_ = 1;
v___x_4530_ = lean_uint8_dec_le(v___x_4529_, v_tagKind_4512_);
if (v___x_4530_ == 0)
{
uint8_t v___x_4531_;
v___x_4531_ = 0;
return v___x_4531_;
}
else
{
uint8_t v___x_4532_; uint8_t v___x_4533_;
v___x_4532_ = 3;
v___x_4533_ = lean_uint8_dec_le(v_tagKind_4512_, v___x_4532_);
if (v___x_4533_ == 0)
{
uint8_t v___x_4534_;
v___x_4534_ = 0;
return v___x_4534_;
}
else
{
return v___x_4529_;
}
}
}
}
}
}
}
}
}
}

LEAN_EXPORT uint64_t leansys_transcript_index(uint64_t v_turnOff_4743_, uint64_t v_turnLen_4744_, uint64_t v_bufLen_4745_, uint64_t v_prevDigest_4746_, uint64_t v_blockHash_4747_){
_start:
{
uint64_t v___x_4748_; uint8_t v___x_4749_;
v___x_4748_ = 0ULL;
v___x_4749_ = lean_uint64_dec_lt(v___x_4748_, v_turnLen_4744_);
if (v___x_4749_ == 0)
{
return v___x_4748_;
}
else
{
uint8_t v___x_4750_;
v___x_4750_ = lean_uint64_dec_le(v_turnOff_4743_, v_bufLen_4745_);
if (v___x_4750_ == 0)
{
return v___x_4748_;
}
else
{
uint64_t v___x_4751_; uint8_t v___x_4752_;
v___x_4751_ = lean_uint64_sub(v_bufLen_4745_, v_turnOff_4743_);
v___x_4752_ = lean_uint64_dec_le(v_turnLen_4744_, v___x_4751_);
if (v___x_4752_ == 0)
{
return v___x_4748_;
}
else
{
uint64_t v___x_4753_; uint64_t v___x_4754_; uint64_t v___x_4755_; uint64_t v___x_4756_; uint64_t v___x_4757_; uint64_t v_z_4758_; uint64_t v___x_4759_; uint64_t v___x_4760_; uint64_t v___x_4761_; uint64_t v___x_4762_; uint64_t v_z1_4763_; uint64_t v___x_4764_; uint64_t v___x_4765_; uint64_t v_mixed_4766_; uint8_t v___x_4767_;
v___x_4753_ = lean_uint64_xor(v_prevDigest_4746_, v_turnLen_4744_);
v___x_4754_ = 11400714819323198485ULL;
v___x_4755_ = lean_uint64_mul(v_blockHash_4747_, v___x_4754_);
v___x_4756_ = lean_uint64_xor(v___x_4753_, v___x_4755_);
v___x_4757_ = 13787848793156543929ULL;
v_z_4758_ = lean_uint64_mul(v___x_4756_, v___x_4757_);
v___x_4759_ = 30ULL;
v___x_4760_ = lean_uint64_shift_right(v_z_4758_, v___x_4759_);
v___x_4761_ = lean_uint64_xor(v_z_4758_, v___x_4760_);
v___x_4762_ = 10723151780598845931ULL;
v_z1_4763_ = lean_uint64_mul(v___x_4761_, v___x_4762_);
v___x_4764_ = 31ULL;
v___x_4765_ = lean_uint64_shift_right(v_z1_4763_, v___x_4764_);
v_mixed_4766_ = lean_uint64_xor(v_z1_4763_, v___x_4765_);
v___x_4767_ = lean_uint64_dec_eq(v_mixed_4766_, v___x_4748_);
if (v___x_4767_ == 0)
{
return v_mixed_4766_;
}
else
{
uint64_t v___x_4768_;
v___x_4768_ = 1ULL;
return v___x_4768_;
}
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_verify_par_chunk(uint64_t v_chunkStart_4946_, uint64_t v_chunkEnd_4947_, uint64_t v_totalLen_4948_, uint64_t v_minGrain_4949_){
_start:
{
uint8_t v___x_4950_;
v___x_4950_ = lean_uint64_dec_lt(v_chunkStart_4946_, v_chunkEnd_4947_);
if (v___x_4950_ == 0)
{
uint8_t v___x_4951_;
v___x_4951_ = 0;
return v___x_4951_;
}
else
{
uint8_t v___x_4952_;
v___x_4952_ = lean_uint64_dec_le(v_chunkEnd_4947_, v_totalLen_4948_);
if (v___x_4952_ == 0)
{
uint8_t v___x_4953_;
v___x_4953_ = 0;
return v___x_4953_;
}
else
{
uint64_t v___x_4954_; uint8_t v___x_4955_;
v___x_4954_ = lean_uint64_sub(v_chunkEnd_4947_, v_chunkStart_4946_);
v___x_4955_ = lean_uint64_dec_le(v_minGrain_4949_, v___x_4954_);
if (v___x_4955_ == 0)
{
uint8_t v___x_4956_;
v___x_4956_ = lean_uint64_dec_eq(v_chunkEnd_4947_, v_totalLen_4948_);
if (v___x_4956_ == 0)
{
uint8_t v___x_4957_;
v___x_4957_ = 0;
return v___x_4957_;
}
else
{
uint8_t v___x_4958_;
v___x_4958_ = 1;
return v___x_4958_;
}
}
else
{
uint8_t v___x_4959_;
v___x_4959_ = 1;
return v___x_4959_;
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_verify_arena_disjoint(uint64_t v_offA_5127_, uint64_t v_lenA_5128_, uint64_t v_offB_5129_, uint64_t v_lenB_5130_, uint64_t v_arenaCap_5131_){
_start:
{
uint8_t v___x_5132_;
v___x_5132_ = lean_uint64_dec_le(v_offA_5127_, v_arenaCap_5131_);
if (v___x_5132_ == 0)
{
uint8_t v___x_5133_;
v___x_5133_ = 0;
return v___x_5133_;
}
else
{
uint64_t v___x_5134_; uint8_t v___x_5135_;
v___x_5134_ = lean_uint64_sub(v_arenaCap_5131_, v_offA_5127_);
v___x_5135_ = lean_uint64_dec_le(v_lenA_5128_, v___x_5134_);
if (v___x_5135_ == 0)
{
uint8_t v___x_5136_;
v___x_5136_ = 0;
return v___x_5136_;
}
else
{
uint8_t v___x_5137_;
v___x_5137_ = lean_uint64_dec_le(v_offB_5129_, v_arenaCap_5131_);
if (v___x_5137_ == 0)
{
uint8_t v___x_5138_;
v___x_5138_ = 0;
return v___x_5138_;
}
else
{
uint64_t v___x_5139_; uint8_t v___x_5140_;
v___x_5139_ = lean_uint64_sub(v_arenaCap_5131_, v_offB_5129_);
v___x_5140_ = lean_uint64_dec_le(v_lenB_5130_, v___x_5139_);
if (v___x_5140_ == 0)
{
uint8_t v___x_5141_;
v___x_5141_ = 0;
return v___x_5141_;
}
else
{
uint64_t v___x_5142_; uint8_t v___x_5143_;
v___x_5142_ = lean_uint64_add(v_offA_5127_, v_lenA_5128_);
v___x_5143_ = lean_uint64_dec_le(v___x_5142_, v_offB_5129_);
if (v___x_5143_ == 0)
{
uint64_t v___x_5144_; uint8_t v___x_5145_;
v___x_5144_ = lean_uint64_add(v_offB_5129_, v_lenB_5130_);
v___x_5145_ = lean_uint64_dec_le(v___x_5144_, v_offA_5127_);
if (v___x_5145_ == 0)
{
uint8_t v___x_5146_;
v___x_5146_ = 0;
return v___x_5146_;
}
else
{
uint8_t v___x_5147_;
v___x_5147_ = 1;
return v___x_5147_;
}
}
else
{
uint8_t v___x_5148_;
v___x_5148_ = 1;
return v___x_5148_;
}
}
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_verify_snapshot_visibility(uint64_t v_entrySeq_5344_, uint64_t v_maxSnapshotSeq_5345_, uint8_t v_isTombstone_5346_){
_start:
{
uint8_t v___x_5347_;
v___x_5347_ = lean_uint64_dec_le(v_entrySeq_5344_, v_maxSnapshotSeq_5345_);
if (v___x_5347_ == 0)
{
uint8_t v___x_5348_;
v___x_5348_ = 0;
return v___x_5348_;
}
else
{
uint8_t v___x_5349_; uint8_t v___x_5350_;
v___x_5349_ = 0;
v___x_5350_ = lean_uint8_dec_eq(v_isTombstone_5346_, v___x_5349_);
if (v___x_5350_ == 0)
{
return v___x_5349_;
}
else
{
uint8_t v___x_5351_;
v___x_5351_ = 1;
return v___x_5351_;
}
}
}
}

LEAN_EXPORT uint8_t leansys_verify_http_route_match(uint8_t v_methodMatch_5498_, uint8_t v_pathMatch_5499_, uint32_t v_routeIdx_5500_, uint32_t v_routeCount_5501_){
_start:
{
uint8_t v___x_5502_; uint8_t v___x_5503_;
v___x_5502_ = 1;
v___x_5503_ = lean_uint8_dec_eq(v_methodMatch_5498_, v___x_5502_);
if (v___x_5503_ == 0)
{
uint8_t v___x_5504_;
v___x_5504_ = 0;
return v___x_5504_;
}
else
{
uint8_t v___x_5505_;
v___x_5505_ = lean_uint8_dec_eq(v_pathMatch_5499_, v___x_5502_);
if (v___x_5505_ == 0)
{
uint8_t v___x_5506_;
v___x_5506_ = 0;
return v___x_5506_;
}
else
{
uint8_t v___x_5507_;
v___x_5507_ = lean_uint32_dec_lt(v_routeIdx_5500_, v_routeCount_5501_);
if (v___x_5507_ == 0)
{
uint8_t v___x_5508_;
v___x_5508_ = 0;
return v___x_5508_;
}
else
{
uint32_t v___x_5509_; uint8_t v___x_5510_;
v___x_5509_ = 64;
v___x_5510_ = lean_uint32_dec_le(v_routeCount_5501_, v___x_5509_);
if (v___x_5510_ == 0)
{
uint8_t v___x_5511_;
v___x_5511_ = 0;
return v___x_5511_;
}
else
{
return v___x_5502_;
}
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_verify_counterexample_triage(uint8_t v_hasViolation_5673_, uint8_t v_hasMissingHypHint_5674_, uint8_t v_refDisagreesWithCandidate_5675_, uint8_t v_triageClass_5676_){
_start:
{
uint8_t v___x_5677_; uint8_t v___x_5690_;
v___x_5677_ = 1;
v___x_5690_ = lean_uint8_dec_eq(v_hasViolation_5673_, v___x_5677_);
if (v___x_5690_ == 0)
{
uint8_t v___x_5691_;
v___x_5691_ = 0;
return v___x_5691_;
}
else
{
uint8_t v___x_5692_;
v___x_5692_ = lean_uint8_dec_eq(v_hasMissingHypHint_5674_, v___x_5677_);
if (v___x_5692_ == 0)
{
goto v___jp_5684_;
}
else
{
uint8_t v___x_5693_;
v___x_5693_ = lean_uint8_dec_eq(v_triageClass_5676_, v___x_5677_);
if (v___x_5693_ == 0)
{
goto v___jp_5684_;
}
else
{
return v___x_5677_;
}
}
}
v___jp_5678_:
{
uint8_t v___x_5679_; uint8_t v___x_5680_;
v___x_5679_ = 0;
v___x_5680_ = lean_uint8_dec_eq(v_hasMissingHypHint_5674_, v___x_5679_);
if (v___x_5680_ == 0)
{
return v___x_5679_;
}
else
{
uint8_t v___x_5681_;
v___x_5681_ = lean_uint8_dec_eq(v_refDisagreesWithCandidate_5675_, v___x_5679_);
if (v___x_5681_ == 0)
{
return v___x_5679_;
}
else
{
uint8_t v___x_5682_; uint8_t v___x_5683_;
v___x_5682_ = 3;
v___x_5683_ = lean_uint8_dec_eq(v_triageClass_5676_, v___x_5682_);
if (v___x_5683_ == 0)
{
return v___x_5679_;
}
else
{
return v___x_5677_;
}
}
}
}
v___jp_5684_:
{
uint8_t v___x_5685_; uint8_t v___x_5686_;
v___x_5685_ = 0;
v___x_5686_ = lean_uint8_dec_eq(v_hasMissingHypHint_5674_, v___x_5685_);
if (v___x_5686_ == 0)
{
goto v___jp_5678_;
}
else
{
uint8_t v___x_5687_;
v___x_5687_ = lean_uint8_dec_eq(v_refDisagreesWithCandidate_5675_, v___x_5677_);
if (v___x_5687_ == 0)
{
goto v___jp_5678_;
}
else
{
uint8_t v___x_5688_; uint8_t v___x_5689_;
v___x_5688_ = 2;
v___x_5689_ = lean_uint8_dec_eq(v_triageClass_5676_, v___x_5688_);
if (v___x_5689_ == 0)
{
goto v___jp_5678_;
}
else
{
return v___x_5677_;
}
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_verify_dag_wave_step(uint64_t v_inDegreeSum_5870_, uint64_t v_waveSize_5871_, uint64_t v_completedTasks_5872_, uint64_t v_totalTasks_5873_, uint64_t v_activeWorkers_5874_, uint64_t v_maxWorkers_5875_){
_start:
{
uint64_t v___x_5876_; uint8_t v___x_5877_;
v___x_5876_ = 0ULL;
v___x_5877_ = lean_uint64_dec_eq(v_inDegreeSum_5870_, v___x_5876_);
if (v___x_5877_ == 0)
{
uint8_t v___x_5878_;
v___x_5878_ = 0;
return v___x_5878_;
}
else
{
uint8_t v___x_5879_;
v___x_5879_ = lean_uint64_dec_lt(v___x_5876_, v_waveSize_5871_);
if (v___x_5879_ == 0)
{
uint8_t v___x_5880_;
v___x_5880_ = 0;
return v___x_5880_;
}
else
{
uint8_t v___x_5881_;
v___x_5881_ = lean_uint64_dec_le(v_completedTasks_5872_, v_totalTasks_5873_);
if (v___x_5881_ == 0)
{
uint8_t v___x_5882_;
v___x_5882_ = 0;
return v___x_5882_;
}
else
{
uint64_t v___x_5883_; uint8_t v___x_5884_;
v___x_5883_ = lean_uint64_sub(v_totalTasks_5873_, v_completedTasks_5872_);
v___x_5884_ = lean_uint64_dec_le(v_waveSize_5871_, v___x_5883_);
if (v___x_5884_ == 0)
{
uint8_t v___x_5885_;
v___x_5885_ = 0;
return v___x_5885_;
}
else
{
uint8_t v___x_5886_;
v___x_5886_ = lean_uint64_dec_lt(v___x_5876_, v_activeWorkers_5874_);
if (v___x_5886_ == 0)
{
uint8_t v___x_5887_;
v___x_5887_ = 0;
return v___x_5887_;
}
else
{
uint8_t v___x_5888_;
v___x_5888_ = lean_uint64_dec_le(v_activeWorkers_5874_, v_maxWorkers_5875_);
if (v___x_5888_ == 0)
{
uint8_t v___x_5889_;
v___x_5889_ = 0;
return v___x_5889_;
}
else
{
uint8_t v___x_5890_;
v___x_5890_ = 1;
return v___x_5890_;
}
}
}
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_verify_ios_jetsam_budget(uint64_t v_dirtyRssBytes_6083_, uint64_t v_allocBytes_6084_, uint64_t v_maxJetsamBytes_6085_, uint64_t v_pageAlignMask_6086_, uint8_t v_isAppExtension_6087_){
_start:
{
uint64_t v___x_6088_; uint8_t v___x_6089_;
v___x_6088_ = 0ULL;
v___x_6089_ = lean_uint64_dec_lt(v___x_6088_, v_allocBytes_6084_);
if (v___x_6089_ == 0)
{
uint8_t v___x_6090_;
v___x_6090_ = 0;
return v___x_6090_;
}
else
{
uint64_t v___x_6091_; uint8_t v___x_6092_;
v___x_6091_ = 16383ULL;
v___x_6092_ = lean_uint64_dec_eq(v_pageAlignMask_6086_, v___x_6091_);
if (v___x_6092_ == 0)
{
uint8_t v___x_6093_;
v___x_6093_ = 0;
return v___x_6093_;
}
else
{
uint8_t v___x_6094_;
v___x_6094_ = lean_uint64_dec_le(v_dirtyRssBytes_6083_, v_maxJetsamBytes_6085_);
if (v___x_6094_ == 0)
{
uint8_t v___x_6095_;
v___x_6095_ = 0;
return v___x_6095_;
}
else
{
uint64_t v___x_6096_; uint8_t v___x_6097_;
v___x_6096_ = lean_uint64_sub(v_maxJetsamBytes_6085_, v_dirtyRssBytes_6083_);
v___x_6097_ = lean_uint64_dec_le(v_allocBytes_6084_, v___x_6096_);
if (v___x_6097_ == 0)
{
uint8_t v___x_6098_;
v___x_6098_ = 0;
return v___x_6098_;
}
else
{
uint8_t v___x_6099_; uint8_t v___x_6100_;
v___x_6099_ = 1;
v___x_6100_ = lean_uint8_dec_le(v_isAppExtension_6087_, v___x_6099_);
if (v___x_6100_ == 0)
{
uint8_t v___x_6101_;
v___x_6101_ = 0;
return v___x_6101_;
}
else
{
uint8_t v___x_6102_; uint8_t v___x_6103_;
v___x_6102_ = 0;
v___x_6103_ = lean_uint8_dec_eq(v_isAppExtension_6087_, v___x_6102_);
if (v___x_6103_ == 0)
{
uint64_t v___x_6104_; uint8_t v___x_6105_;
v___x_6104_ = 25165824ULL;
v___x_6105_ = lean_uint64_dec_le(v_maxJetsamBytes_6085_, v___x_6104_);
if (v___x_6105_ == 0)
{
return v___x_6102_;
}
else
{
return v___x_6099_;
}
}
else
{
return v___x_6099_;
}
}
}
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_verify_worker_budget(uint64_t v_activeWorkers_6298_, uint64_t v_maxWorkers_6299_, uint64_t v_microChunks_6300_, uint64_t v_totalLen_6301_, uint8_t v_topologyKind_6302_){
_start:
{
uint64_t v___x_6311_; uint8_t v___x_6312_;
v___x_6311_ = 0ULL;
v___x_6312_ = lean_uint64_dec_lt(v___x_6311_, v_activeWorkers_6298_);
if (v___x_6312_ == 0)
{
uint8_t v___x_6313_;
v___x_6313_ = 0;
return v___x_6313_;
}
else
{
uint8_t v___x_6314_;
v___x_6314_ = lean_uint64_dec_le(v_activeWorkers_6298_, v_maxWorkers_6299_);
if (v___x_6314_ == 0)
{
uint8_t v___x_6315_;
v___x_6315_ = 0;
return v___x_6315_;
}
else
{
uint64_t v___x_6316_; uint8_t v___x_6317_;
v___x_6316_ = 64ULL;
v___x_6317_ = lean_uint64_dec_le(v_maxWorkers_6299_, v___x_6316_);
if (v___x_6317_ == 0)
{
uint8_t v___x_6318_;
v___x_6318_ = 0;
return v___x_6318_;
}
else
{
uint8_t v___x_6319_;
v___x_6319_ = lean_uint64_dec_lt(v___x_6311_, v_totalLen_6301_);
if (v___x_6319_ == 0)
{
uint8_t v___x_6320_;
v___x_6320_ = 0;
return v___x_6320_;
}
else
{
uint8_t v___x_6321_;
v___x_6321_ = lean_uint64_dec_le(v_activeWorkers_6298_, v_microChunks_6300_);
if (v___x_6321_ == 0)
{
uint8_t v___x_6322_;
v___x_6322_ = 0;
return v___x_6322_;
}
else
{
uint64_t v___x_6323_; uint64_t v___x_6324_; uint8_t v___x_6325_;
v___x_6323_ = 3ULL;
v___x_6324_ = lean_uint64_shift_left(v_maxWorkers_6299_, v___x_6323_);
v___x_6325_ = lean_uint64_dec_le(v_microChunks_6300_, v___x_6324_);
if (v___x_6325_ == 0)
{
uint8_t v___x_6326_;
v___x_6326_ = 0;
return v___x_6326_;
}
else
{
uint8_t v___x_6327_; uint8_t v___x_6328_;
v___x_6327_ = 2;
v___x_6328_ = lean_uint8_dec_le(v_topologyKind_6302_, v___x_6327_);
if (v___x_6328_ == 0)
{
uint8_t v___x_6329_;
v___x_6329_ = 0;
return v___x_6329_;
}
else
{
uint8_t v___x_6330_; uint8_t v___x_6331_;
v___x_6330_ = 1;
v___x_6331_ = lean_uint8_dec_eq(v_topologyKind_6302_, v___x_6330_);
if (v___x_6331_ == 0)
{
goto v___jp_6303_;
}
else
{
uint64_t v___x_6332_; uint8_t v___x_6333_;
v___x_6332_ = 6ULL;
v___x_6333_ = lean_uint64_dec_le(v_maxWorkers_6299_, v___x_6332_);
if (v___x_6333_ == 0)
{
uint8_t v___x_6334_;
v___x_6334_ = 0;
return v___x_6334_;
}
else
{
goto v___jp_6303_;
}
}
}
}
}
}
}
}
}
v___jp_6303_:
{
uint8_t v___x_6304_; uint8_t v___x_6305_;
v___x_6304_ = 2;
v___x_6305_ = lean_uint8_dec_eq(v_topologyKind_6302_, v___x_6304_);
if (v___x_6305_ == 0)
{
uint8_t v___x_6306_;
v___x_6306_ = 1;
return v___x_6306_;
}
else
{
uint64_t v___x_6307_; uint8_t v___x_6308_;
v___x_6307_ = 9ULL;
v___x_6308_ = lean_uint64_dec_le(v_maxWorkers_6299_, v___x_6307_);
if (v___x_6308_ == 0)
{
uint8_t v___x_6309_;
v___x_6309_ = 0;
return v___x_6309_;
}
else
{
uint8_t v___x_6310_;
v___x_6310_ = 1;
return v___x_6310_;
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_verify_page_aligned_buffer(uint64_t v_addr_6551_, uint64_t v_allocBytes_6552_, uint64_t v_capacityBytes_6553_, uint64_t v_dirtyRssBytes_6554_, uint64_t v_maxBudgetBytes_6555_, uint64_t v_pageAlignMask_6556_){
_start:
{
uint64_t v___x_6569_; uint8_t v___x_6570_;
v___x_6569_ = 0ULL;
v___x_6570_ = lean_uint64_dec_lt(v___x_6569_, v_addr_6551_);
if (v___x_6570_ == 0)
{
uint8_t v___x_6571_;
v___x_6571_ = 0;
return v___x_6571_;
}
else
{
uint8_t v___x_6572_;
v___x_6572_ = lean_uint64_dec_lt(v___x_6569_, v_allocBytes_6552_);
if (v___x_6572_ == 0)
{
uint8_t v___x_6573_;
v___x_6573_ = 0;
return v___x_6573_;
}
else
{
uint8_t v___x_6574_;
v___x_6574_ = lean_uint64_dec_le(v_allocBytes_6552_, v_capacityBytes_6553_);
if (v___x_6574_ == 0)
{
uint8_t v___x_6575_;
v___x_6575_ = 0;
return v___x_6575_;
}
else
{
uint64_t v___x_6576_; uint8_t v___x_6577_;
v___x_6576_ = 4095ULL;
v___x_6577_ = lean_uint64_dec_eq(v_pageAlignMask_6556_, v___x_6576_);
if (v___x_6577_ == 0)
{
uint64_t v___x_6578_; uint8_t v___x_6579_;
v___x_6578_ = 16383ULL;
v___x_6579_ = lean_uint64_dec_eq(v_pageAlignMask_6556_, v___x_6578_);
if (v___x_6579_ == 0)
{
uint8_t v___x_6580_;
v___x_6580_ = 0;
return v___x_6580_;
}
else
{
goto v___jp_6557_;
}
}
else
{
goto v___jp_6557_;
}
}
}
}
v___jp_6557_:
{
uint64_t v___x_6558_; uint64_t v___x_6559_; uint64_t v___x_6560_; uint8_t v___x_6561_;
v___x_6558_ = lean_uint64_lor(v_addr_6551_, v_capacityBytes_6553_);
v___x_6559_ = lean_uint64_land(v___x_6558_, v_pageAlignMask_6556_);
v___x_6560_ = 0ULL;
v___x_6561_ = lean_uint64_dec_eq(v___x_6559_, v___x_6560_);
if (v___x_6561_ == 0)
{
uint8_t v___x_6562_;
v___x_6562_ = 0;
return v___x_6562_;
}
else
{
uint8_t v___x_6563_;
v___x_6563_ = lean_uint64_dec_le(v_dirtyRssBytes_6554_, v_maxBudgetBytes_6555_);
if (v___x_6563_ == 0)
{
uint8_t v___x_6564_;
v___x_6564_ = 0;
return v___x_6564_;
}
else
{
uint64_t v___x_6565_; uint8_t v___x_6566_;
v___x_6565_ = lean_uint64_sub(v_maxBudgetBytes_6555_, v_dirtyRssBytes_6554_);
v___x_6566_ = lean_uint64_dec_le(v_capacityBytes_6553_, v___x_6565_);
if (v___x_6566_ == 0)
{
uint8_t v___x_6567_;
v___x_6567_ = 0;
return v___x_6567_;
}
else
{
uint8_t v___x_6568_;
v___x_6568_ = 1;
return v___x_6568_;
}
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_select_isa(uint64_t v_detectedHwCaps_6817_, uint64_t v_requiredMask_6818_, uint8_t v_requestedVariantId_6819_, uint8_t v_maxVariantId_6820_){
_start:
{
uint8_t v___x_6821_; uint64_t v___y_6823_; uint8_t v___x_6827_;
v___x_6821_ = 0;
v___x_6827_ = lean_uint8_dec_lt(v___x_6821_, v_requestedVariantId_6819_);
if (v___x_6827_ == 0)
{
return v___x_6821_;
}
else
{
uint8_t v___x_6828_;
v___x_6828_ = lean_uint8_dec_le(v_requestedVariantId_6819_, v_maxVariantId_6820_);
if (v___x_6828_ == 0)
{
return v___x_6821_;
}
else
{
uint8_t v___x_6829_; uint8_t v___x_6830_;
v___x_6829_ = 4;
v___x_6830_ = lean_uint8_dec_le(v_maxVariantId_6820_, v___x_6829_);
if (v___x_6830_ == 0)
{
return v___x_6821_;
}
else
{
uint8_t v___x_6831_;
v___x_6831_ = lean_uint8_dec_eq(v_requestedVariantId_6819_, v___x_6821_);
if (v___x_6831_ == 0)
{
uint8_t v___x_6832_; uint8_t v___x_6833_;
v___x_6832_ = 1;
v___x_6833_ = lean_uint8_dec_eq(v_requestedVariantId_6819_, v___x_6832_);
if (v___x_6833_ == 0)
{
uint8_t v___x_6834_; uint8_t v___x_6835_;
v___x_6834_ = 2;
v___x_6835_ = lean_uint8_dec_eq(v_requestedVariantId_6819_, v___x_6834_);
if (v___x_6835_ == 0)
{
uint8_t v___x_6836_; uint8_t v___x_6837_;
v___x_6836_ = 3;
v___x_6837_ = lean_uint8_dec_eq(v_requestedVariantId_6819_, v___x_6836_);
if (v___x_6837_ == 0)
{
uint8_t v___x_6838_;
v___x_6838_ = lean_uint8_dec_eq(v_requestedVariantId_6819_, v___x_6829_);
if (v___x_6838_ == 0)
{
uint64_t v___x_6839_;
v___x_6839_ = 18446744073709551615ULL;
v___y_6823_ = v___x_6839_;
goto v___jp_6822_;
}
else
{
uint64_t v___x_6840_;
v___x_6840_ = 927ULL;
v___y_6823_ = v___x_6840_;
goto v___jp_6822_;
}
}
else
{
uint64_t v___x_6841_;
v___x_6841_ = 895ULL;
v___y_6823_ = v___x_6841_;
goto v___jp_6822_;
}
}
else
{
uint64_t v___x_6842_;
v___x_6842_ = 799ULL;
v___y_6823_ = v___x_6842_;
goto v___jp_6822_;
}
}
else
{
uint64_t v___x_6843_;
v___x_6843_ = 775ULL;
v___y_6823_ = v___x_6843_;
goto v___jp_6822_;
}
}
else
{
uint64_t v___x_6844_;
v___x_6844_ = 263ULL;
v___y_6823_ = v___x_6844_;
goto v___jp_6822_;
}
}
}
}
v___jp_6822_:
{
uint8_t v___x_6824_;
v___x_6824_ = lean_uint64_dec_eq(v_requiredMask_6818_, v___y_6823_);
if (v___x_6824_ == 0)
{
return v___x_6821_;
}
else
{
uint64_t v___x_6825_; uint8_t v___x_6826_;
v___x_6825_ = lean_uint64_land(v_detectedHwCaps_6817_, v_requiredMask_6818_);
v___x_6826_ = lean_uint64_dec_eq(v___x_6825_, v_requiredMask_6818_);
if (v___x_6826_ == 0)
{
return v___x_6821_;
}
else
{
return v_requestedVariantId_6819_;
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_verify_isa_selection(uint64_t v_detectedHwCaps_6855_, uint64_t v_requiredMask_6856_, uint8_t v_selectedVariantId_6857_, uint8_t v_maxVariantId_6858_){
_start:
{
uint64_t v___y_6860_; uint8_t v___x_6869_;
v___x_6869_ = lean_uint8_dec_le(v_selectedVariantId_6857_, v_maxVariantId_6858_);
if (v___x_6869_ == 0)
{
uint8_t v___x_6870_;
v___x_6870_ = 0;
return v___x_6870_;
}
else
{
uint8_t v___x_6871_; uint8_t v___x_6872_;
v___x_6871_ = 4;
v___x_6872_ = lean_uint8_dec_le(v_maxVariantId_6858_, v___x_6871_);
if (v___x_6872_ == 0)
{
uint8_t v___x_6873_;
v___x_6873_ = 0;
return v___x_6873_;
}
else
{
uint8_t v___x_6874_; uint8_t v___x_6875_;
v___x_6874_ = 0;
v___x_6875_ = lean_uint8_dec_eq(v_selectedVariantId_6857_, v___x_6874_);
if (v___x_6875_ == 0)
{
uint8_t v___x_6876_; uint8_t v___x_6877_;
v___x_6876_ = 1;
v___x_6877_ = lean_uint8_dec_eq(v_selectedVariantId_6857_, v___x_6876_);
if (v___x_6877_ == 0)
{
uint8_t v___x_6878_; uint8_t v___x_6879_;
v___x_6878_ = 2;
v___x_6879_ = lean_uint8_dec_eq(v_selectedVariantId_6857_, v___x_6878_);
if (v___x_6879_ == 0)
{
uint8_t v___x_6880_; uint8_t v___x_6881_;
v___x_6880_ = 3;
v___x_6881_ = lean_uint8_dec_eq(v_selectedVariantId_6857_, v___x_6880_);
if (v___x_6881_ == 0)
{
uint8_t v___x_6882_;
v___x_6882_ = lean_uint8_dec_eq(v_selectedVariantId_6857_, v___x_6871_);
if (v___x_6882_ == 0)
{
uint64_t v___x_6883_;
v___x_6883_ = 18446744073709551615ULL;
v___y_6860_ = v___x_6883_;
goto v___jp_6859_;
}
else
{
uint64_t v___x_6884_;
v___x_6884_ = 927ULL;
v___y_6860_ = v___x_6884_;
goto v___jp_6859_;
}
}
else
{
uint64_t v___x_6885_;
v___x_6885_ = 895ULL;
v___y_6860_ = v___x_6885_;
goto v___jp_6859_;
}
}
else
{
uint64_t v___x_6886_;
v___x_6886_ = 799ULL;
v___y_6860_ = v___x_6886_;
goto v___jp_6859_;
}
}
else
{
uint64_t v___x_6887_;
v___x_6887_ = 775ULL;
v___y_6860_ = v___x_6887_;
goto v___jp_6859_;
}
}
else
{
uint64_t v___x_6888_;
v___x_6888_ = 263ULL;
v___y_6860_ = v___x_6888_;
goto v___jp_6859_;
}
}
}
v___jp_6859_:
{
uint8_t v___x_6861_;
v___x_6861_ = lean_uint64_dec_eq(v_requiredMask_6856_, v___y_6860_);
if (v___x_6861_ == 0)
{
uint8_t v___x_6862_;
v___x_6862_ = 0;
return v___x_6862_;
}
else
{
uint8_t v___x_6863_; uint8_t v___x_6864_;
v___x_6863_ = 0;
v___x_6864_ = lean_uint8_dec_eq(v_selectedVariantId_6857_, v___x_6863_);
if (v___x_6864_ == 0)
{
uint64_t v___x_6865_; uint8_t v___x_6866_;
v___x_6865_ = lean_uint64_land(v_detectedHwCaps_6855_, v_requiredMask_6856_);
v___x_6866_ = lean_uint64_dec_eq(v___x_6865_, v_requiredMask_6856_);
if (v___x_6866_ == 0)
{
return v___x_6863_;
}
else
{
uint8_t v___x_6867_;
v___x_6867_ = 1;
return v___x_6867_;
}
}
else
{
uint8_t v___x_6868_;
v___x_6868_ = 1;
return v___x_6868_;
}
}
}
}
}
