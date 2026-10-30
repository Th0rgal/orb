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
#define lean_uint32_xor(a, b) ((uint32_t)((a) ^ (b)))
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
#define lean_uint64_to_uint32(a) ((uint32_t)(a))
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

LEAN_EXPORT uint32_t orb_attribution_step(uint8_t v_principalKind_1507_, uint8_t v_claimedKind_1508_, uint8_t v_sameMission_1509_, uint8_t v_isDescendant_1510_){
_start:
{
uint8_t v___y_1512_; uint8_t v___y_1517_; uint8_t v___y_1521_; uint8_t v___y_1522_; uint8_t v___y_1525_; uint8_t v___x_1560_; uint8_t v___x_1561_;
v___x_1560_ = 6;
v___x_1561_ = lean_uint8_dec_le(v_principalKind_1507_, v___x_1560_);
if (v___x_1561_ == 0)
{
uint8_t v___x_1562_;
v___x_1562_ = 0;
v___y_1525_ = v___x_1562_;
goto v___jp_1524_;
}
else
{
v___y_1525_ = v_principalKind_1507_;
goto v___jp_1524_;
}
v___jp_1511_:
{
uint32_t v___x_1513_; uint32_t v___x_1514_; uint32_t v___x_1515_;
v___x_1513_ = lean_uint8_to_uint32(v___y_1512_);
v___x_1514_ = 256;
v___x_1515_ = lean_uint32_lor(v___x_1513_, v___x_1514_);
return v___x_1515_;
}
v___jp_1516_:
{
uint8_t v___x_1518_; uint8_t v___x_1519_;
v___x_1518_ = 0;
v___x_1519_ = lean_uint8_dec_eq(v_claimedKind_1508_, v___x_1518_);
if (v___x_1519_ == 0)
{
v___y_1512_ = v_claimedKind_1508_;
goto v___jp_1511_;
}
else
{
v___y_1512_ = v___y_1517_;
goto v___jp_1511_;
}
}
v___jp_1520_:
{
if (v___y_1522_ == 0)
{
uint32_t v___x_1523_;
v___x_1523_ = lean_uint8_to_uint32(v___y_1521_);
return v___x_1523_;
}
else
{
v___y_1517_ = v___y_1521_;
goto v___jp_1516_;
}
}
v___jp_1524_:
{
uint8_t v___x_1526_; uint8_t v___x_1527_;
v___x_1526_ = 0;
v___x_1527_ = lean_uint8_dec_eq(v_claimedKind_1508_, v___x_1526_);
if (v___x_1527_ == 0)
{
uint8_t v___x_1528_; uint8_t v___x_1529_;
v___x_1528_ = 5;
v___x_1529_ = lean_uint8_dec_eq(v___y_1525_, v___x_1528_);
if (v___x_1529_ == 0)
{
uint8_t v___x_1530_; uint8_t v___x_1531_;
v___x_1530_ = 1;
v___x_1531_ = lean_uint8_dec_eq(v___y_1525_, v___x_1530_);
if (v___x_1531_ == 0)
{
uint8_t v___x_1532_; uint8_t v___x_1533_;
v___x_1532_ = 2;
v___x_1533_ = lean_uint8_dec_eq(v___y_1525_, v___x_1532_);
if (v___x_1533_ == 0)
{
uint8_t v___x_1534_; uint8_t v___x_1535_;
v___x_1534_ = 3;
v___x_1535_ = lean_uint8_dec_eq(v___y_1525_, v___x_1534_);
if (v___x_1535_ == 0)
{
uint8_t v___x_1536_; uint8_t v___x_1537_;
v___x_1536_ = 4;
v___x_1537_ = lean_uint8_dec_eq(v___y_1525_, v___x_1536_);
if (v___x_1537_ == 0)
{
uint8_t v___x_1538_; uint8_t v___x_1539_;
v___x_1538_ = 6;
v___x_1539_ = lean_uint8_dec_eq(v___y_1525_, v___x_1538_);
if (v___x_1539_ == 0)
{
uint32_t v___x_1540_;
v___x_1540_ = lean_uint8_to_uint32(v___y_1525_);
return v___x_1540_;
}
else
{
uint8_t v___x_1541_;
v___x_1541_ = lean_uint8_dec_eq(v_claimedKind_1508_, v___x_1538_);
v___y_1521_ = v___y_1525_;
v___y_1522_ = v___x_1541_;
goto v___jp_1520_;
}
}
else
{
uint8_t v___x_1542_;
v___x_1542_ = lean_uint8_dec_eq(v_claimedKind_1508_, v___x_1536_);
v___y_1521_ = v___y_1525_;
v___y_1522_ = v___x_1542_;
goto v___jp_1520_;
}
}
else
{
uint8_t v___x_1543_;
v___x_1543_ = lean_uint8_dec_eq(v_claimedKind_1508_, v___x_1534_);
v___y_1521_ = v___y_1525_;
v___y_1522_ = v___x_1543_;
goto v___jp_1520_;
}
}
else
{
uint8_t v___x_1544_;
v___x_1544_ = lean_uint8_dec_eq(v_claimedKind_1508_, v___x_1530_);
if (v___x_1544_ == 0)
{
uint8_t v___x_1545_;
v___x_1545_ = lean_uint8_dec_eq(v_claimedKind_1508_, v___x_1532_);
if (v___x_1545_ == 0)
{
uint32_t v___x_1546_;
v___x_1546_ = lean_uint8_to_uint32(v___y_1525_);
return v___x_1546_;
}
else
{
uint8_t v___x_1547_;
v___x_1547_ = lean_uint8_dec_eq(v_isDescendant_1510_, v___x_1530_);
v___y_1521_ = v___y_1525_;
v___y_1522_ = v___x_1547_;
goto v___jp_1520_;
}
}
else
{
uint8_t v___x_1548_;
v___x_1548_ = lean_uint8_dec_eq(v_sameMission_1509_, v___x_1530_);
v___y_1521_ = v___y_1525_;
v___y_1522_ = v___x_1548_;
goto v___jp_1520_;
}
}
}
else
{
uint8_t v___x_1549_;
v___x_1549_ = lean_uint8_dec_eq(v_claimedKind_1508_, v___x_1530_);
if (v___x_1549_ == 0)
{
uint8_t v___x_1550_; uint8_t v___x_1551_;
v___x_1550_ = 2;
v___x_1551_ = lean_uint8_dec_eq(v_claimedKind_1508_, v___x_1550_);
if (v___x_1551_ == 0)
{
uint32_t v___x_1552_;
v___x_1552_ = lean_uint8_to_uint32(v___y_1525_);
return v___x_1552_;
}
else
{
uint8_t v___x_1553_;
v___x_1553_ = lean_uint8_dec_eq(v_isDescendant_1510_, v___x_1530_);
v___y_1521_ = v___y_1525_;
v___y_1522_ = v___x_1553_;
goto v___jp_1520_;
}
}
else
{
uint8_t v___x_1554_;
v___x_1554_ = lean_uint8_dec_eq(v_sameMission_1509_, v___x_1530_);
v___y_1521_ = v___y_1525_;
v___y_1522_ = v___x_1554_;
goto v___jp_1520_;
}
}
}
else
{
uint8_t v___x_1555_; uint8_t v___x_1556_;
v___x_1555_ = 1;
v___x_1556_ = lean_uint8_dec_eq(v_claimedKind_1508_, v___x_1555_);
if (v___x_1556_ == 0)
{
uint8_t v___x_1557_; uint8_t v___x_1558_;
v___x_1557_ = 2;
v___x_1558_ = lean_uint8_dec_eq(v_claimedKind_1508_, v___x_1557_);
if (v___x_1558_ == 0)
{
uint8_t v___x_1559_;
v___x_1559_ = lean_uint8_dec_eq(v_claimedKind_1508_, v___x_1528_);
v___y_1521_ = v___y_1525_;
v___y_1522_ = v___x_1559_;
goto v___jp_1520_;
}
else
{
v___y_1517_ = v___y_1525_;
goto v___jp_1516_;
}
}
else
{
v___y_1517_ = v___y_1525_;
goto v___jp_1516_;
}
}
}
else
{
v___y_1517_ = v___y_1525_;
goto v___jp_1516_;
}
}
}
}

LEAN_EXPORT uint8_t orb_schedule_step(uint8_t v_op_1632_, uint8_t v_known_1633_, uint8_t v_cancelled_1634_, uint8_t v_ownerTerminal_1635_, uint8_t v_authorized_1636_, uint8_t v_busy_1637_, uint64_t v_lastFired_1638_, uint64_t v_nextDue_1639_, uint64_t v_now_1640_){
_start:
{
uint8_t v___x_1641_; uint8_t v___x_1642_;
v___x_1641_ = 1;
v___x_1642_ = lean_uint8_dec_eq(v_authorized_1636_, v___x_1641_);
if (v___x_1642_ == 0)
{
uint8_t v___x_1643_;
v___x_1643_ = 0;
return v___x_1643_;
}
else
{
uint8_t v___x_1644_; uint8_t v___x_1645_;
v___x_1644_ = 0;
v___x_1645_ = lean_uint8_dec_eq(v_op_1632_, v___x_1644_);
if (v___x_1645_ == 0)
{
uint8_t v___x_1646_;
v___x_1646_ = lean_uint8_dec_eq(v_cancelled_1634_, v___x_1641_);
if (v___x_1646_ == 0)
{
uint8_t v___x_1647_;
v___x_1647_ = lean_uint8_dec_eq(v_ownerTerminal_1635_, v___x_1641_);
if (v___x_1647_ == 0)
{
uint8_t v___x_1648_;
v___x_1648_ = lean_uint64_dec_lt(v_lastFired_1638_, v_nextDue_1639_);
if (v___x_1648_ == 0)
{
uint8_t v___x_1649_;
v___x_1649_ = 4;
return v___x_1649_;
}
else
{
uint8_t v___x_1650_;
v___x_1650_ = lean_uint64_dec_le(v_nextDue_1639_, v_now_1640_);
if (v___x_1650_ == 0)
{
uint8_t v___x_1651_;
v___x_1651_ = 4;
return v___x_1651_;
}
else
{
uint8_t v___x_1652_;
v___x_1652_ = lean_uint8_dec_eq(v_busy_1637_, v___x_1641_);
if (v___x_1652_ == 0)
{
uint8_t v___x_1653_;
v___x_1653_ = 3;
return v___x_1653_;
}
else
{
uint8_t v___x_1654_;
v___x_1654_ = 4;
return v___x_1654_;
}
}
}
}
else
{
return v___x_1644_;
}
}
else
{
return v___x_1644_;
}
}
else
{
uint8_t v___x_1655_;
v___x_1655_ = lean_uint8_dec_eq(v_known_1633_, v___x_1641_);
if (v___x_1655_ == 0)
{
uint8_t v___x_1656_;
v___x_1656_ = lean_uint8_dec_eq(v_ownerTerminal_1635_, v___x_1641_);
if (v___x_1656_ == 0)
{
return v___x_1641_;
}
else
{
return v___x_1644_;
}
}
else
{
uint8_t v___x_1657_;
v___x_1657_ = 2;
return v___x_1657_;
}
}
}
}
}

LEAN_EXPORT uint64_t orb_stats_settle_step(uint64_t v_acc_1695_, uint64_t v_cost_1696_, uint8_t v_seen_1697_){
_start:
{
uint8_t v___x_1698_; uint8_t v___x_1699_;
v___x_1698_ = 1;
v___x_1699_ = lean_uint8_dec_eq(v_seen_1697_, v___x_1698_);
if (v___x_1699_ == 0)
{
uint64_t v___x_1700_; uint64_t v___x_1701_; uint8_t v___x_1702_;
v___x_1700_ = 18446744073709551615ULL;
v___x_1701_ = lean_uint64_sub(v___x_1700_, v_cost_1696_);
v___x_1702_ = lean_uint64_dec_le(v_acc_1695_, v___x_1701_);
if (v___x_1702_ == 0)
{
return v___x_1700_;
}
else
{
uint64_t v___x_1703_;
v___x_1703_ = lean_uint64_add(v_acc_1695_, v_cost_1696_);
return v___x_1703_;
}
}
else
{
return v_acc_1695_;
}
}
}

LEAN_EXPORT uint32_t orb_privilege_step(uint8_t v_sameOwner_1712_, uint8_t v_missionActive_1713_, uint8_t v_biometricSigned_1714_, uint8_t v_scopeRank_1715_, uint8_t v_maxGrantedScope_1716_, uint8_t v_bunkerState_1717_, uint8_t v_revoked_1718_, uint64_t v_nowEpoch_1719_, uint64_t v_grantExpiresAt_1720_, uint64_t v_sessionExpiresAt_1721_){
_start:
{
uint8_t v___x_1722_; uint8_t v___x_1723_;
v___x_1722_ = 0;
v___x_1723_ = lean_uint8_dec_eq(v_missionActive_1713_, v___x_1722_);
if (v___x_1723_ == 0)
{
uint8_t v___x_1724_; uint8_t v___x_1725_;
v___x_1724_ = 1;
v___x_1725_ = lean_uint8_dec_eq(v_revoked_1718_, v___x_1724_);
if (v___x_1725_ == 0)
{
uint8_t v___x_1726_;
v___x_1726_ = lean_uint8_dec_eq(v_bunkerState_1717_, v___x_1722_);
if (v___x_1726_ == 0)
{
uint32_t v___x_1727_;
v___x_1727_ = 65536;
return v___x_1727_;
}
else
{
uint8_t v___x_1728_;
v___x_1728_ = lean_uint64_dec_le(v_grantExpiresAt_1720_, v_nowEpoch_1719_);
if (v___x_1728_ == 0)
{
uint8_t v___x_1729_;
v___x_1729_ = lean_uint64_dec_le(v_sessionExpiresAt_1721_, v_nowEpoch_1719_);
if (v___x_1729_ == 0)
{
uint8_t v___x_1730_;
v___x_1730_ = lean_uint8_dec_eq(v_sameOwner_1712_, v___x_1724_);
if (v___x_1730_ == 0)
{
uint32_t v___x_1731_;
v___x_1731_ = 0;
return v___x_1731_;
}
else
{
uint8_t v___x_1732_;
v___x_1732_ = lean_uint8_dec_eq(v_biometricSigned_1714_, v___x_1724_);
if (v___x_1732_ == 0)
{
uint32_t v___x_1733_;
v___x_1733_ = 0;
return v___x_1733_;
}
else
{
uint8_t v___x_1734_;
v___x_1734_ = lean_uint8_dec_le(v_scopeRank_1715_, v_maxGrantedScope_1716_);
if (v___x_1734_ == 0)
{
uint32_t v___x_1735_;
v___x_1735_ = 0;
return v___x_1735_;
}
else
{
uint8_t v___x_1736_; uint8_t v___x_1737_;
v___x_1736_ = 2;
v___x_1737_ = lean_uint8_dec_lt(v_scopeRank_1715_, v___x_1736_);
if (v___x_1737_ == 0)
{
uint32_t v___x_1738_;
v___x_1738_ = 1;
return v___x_1738_;
}
else
{
uint32_t v___x_1739_;
v___x_1739_ = 257;
return v___x_1739_;
}
}
}
}
}
else
{
uint32_t v___x_1740_;
v___x_1740_ = 65536;
return v___x_1740_;
}
}
else
{
uint32_t v___x_1741_;
v___x_1741_ = 65536;
return v___x_1741_;
}
}
}
else
{
uint32_t v___x_1742_;
v___x_1742_ = 65536;
return v___x_1742_;
}
}
else
{
uint32_t v___x_1743_;
v___x_1743_ = 65536;
return v___x_1743_;
}
}
}

LEAN_EXPORT uint32_t orb_bunker_step(uint8_t v_currentState_1766_, uint8_t v_canaryTripped_1767_, uint8_t v_authFailureBurst_1768_, uint8_t v_manualTrigger_1769_, uint8_t v_biometricUnbunker_1770_){
_start:
{
uint8_t v___x_1771_; uint8_t v___y_1773_; uint32_t v___y_1774_; uint32_t v___y_1775_; uint8_t v___y_1781_; uint8_t v___y_1782_; uint8_t v___y_1788_; uint8_t v___x_1801_;
v___x_1771_ = 2;
v___x_1801_ = lean_uint8_dec_le(v_currentState_1766_, v___x_1771_);
if (v___x_1801_ == 0)
{
v___y_1788_ = v___x_1771_;
goto v___jp_1787_;
}
else
{
v___y_1788_ = v_currentState_1766_;
goto v___jp_1787_;
}
v___jp_1772_:
{
uint32_t v___x_1776_; uint8_t v___x_1777_;
v___x_1776_ = lean_uint32_lor(v___y_1774_, v___y_1775_);
v___x_1777_ = lean_uint8_dec_eq(v___y_1773_, v___x_1771_);
if (v___x_1777_ == 0)
{
return v___x_1776_;
}
else
{
uint32_t v___x_1778_; uint32_t v___x_1779_;
v___x_1778_ = 65536;
v___x_1779_ = lean_uint32_lor(v___x_1776_, v___x_1778_);
return v___x_1779_;
}
}
v___jp_1780_:
{
uint32_t v___x_1783_; uint8_t v___x_1784_;
v___x_1783_ = lean_uint8_to_uint32(v___y_1782_);
v___x_1784_ = lean_uint8_dec_le(v___y_1781_, v___y_1782_);
if (v___x_1784_ == 0)
{
uint32_t v___x_1785_;
v___x_1785_ = 0;
v___y_1773_ = v___y_1782_;
v___y_1774_ = v___x_1783_;
v___y_1775_ = v___x_1785_;
goto v___jp_1772_;
}
else
{
uint32_t v___x_1786_;
v___x_1786_ = 256;
v___y_1773_ = v___y_1782_;
v___y_1774_ = v___x_1783_;
v___y_1775_ = v___x_1786_;
goto v___jp_1772_;
}
}
v___jp_1787_:
{
uint8_t v___x_1789_; uint8_t v___x_1790_;
v___x_1789_ = 1;
v___x_1790_ = lean_uint8_dec_eq(v_canaryTripped_1767_, v___x_1789_);
if (v___x_1790_ == 0)
{
uint8_t v___x_1791_;
v___x_1791_ = lean_uint8_dec_eq(v_manualTrigger_1769_, v___x_1771_);
if (v___x_1791_ == 0)
{
uint8_t v___x_1792_;
v___x_1792_ = lean_uint8_dec_eq(v___y_1788_, v___x_1771_);
if (v___x_1792_ == 0)
{
uint8_t v___x_1793_;
v___x_1793_ = lean_uint8_dec_eq(v_authFailureBurst_1768_, v___x_1789_);
if (v___x_1793_ == 0)
{
uint8_t v___x_1794_;
v___x_1794_ = lean_uint8_dec_eq(v_manualTrigger_1769_, v___x_1789_);
if (v___x_1794_ == 0)
{
uint8_t v___x_1795_;
v___x_1795_ = lean_uint8_dec_eq(v___y_1788_, v___x_1789_);
if (v___x_1795_ == 0)
{
uint8_t v___x_1796_;
v___x_1796_ = 0;
v___y_1781_ = v___x_1789_;
v___y_1782_ = v___x_1796_;
goto v___jp_1780_;
}
else
{
uint8_t v___x_1797_;
v___x_1797_ = lean_uint8_dec_eq(v_biometricUnbunker_1770_, v___x_1789_);
if (v___x_1797_ == 0)
{
v___y_1781_ = v___x_1789_;
v___y_1782_ = v___x_1789_;
goto v___jp_1780_;
}
else
{
uint8_t v___x_1798_;
v___x_1798_ = 0;
v___y_1781_ = v___x_1789_;
v___y_1782_ = v___x_1798_;
goto v___jp_1780_;
}
}
}
else
{
v___y_1781_ = v___x_1789_;
v___y_1782_ = v___x_1789_;
goto v___jp_1780_;
}
}
else
{
v___y_1781_ = v___x_1789_;
v___y_1782_ = v___x_1789_;
goto v___jp_1780_;
}
}
else
{
uint8_t v___x_1799_;
v___x_1799_ = lean_uint8_dec_eq(v_biometricUnbunker_1770_, v___x_1789_);
if (v___x_1799_ == 0)
{
v___y_1781_ = v___x_1789_;
v___y_1782_ = v___x_1771_;
goto v___jp_1780_;
}
else
{
uint8_t v___x_1800_;
v___x_1800_ = 0;
v___y_1781_ = v___x_1789_;
v___y_1782_ = v___x_1800_;
goto v___jp_1780_;
}
}
}
else
{
v___y_1781_ = v___x_1789_;
v___y_1782_ = v___x_1771_;
goto v___jp_1780_;
}
}
else
{
v___y_1781_ = v___x_1789_;
v___y_1782_ = v___x_1771_;
goto v___jp_1780_;
}
}
}
}

LEAN_EXPORT uint8_t orb_deploy_gate_step(uint8_t v_isProdService_1814_, uint8_t v_serviceMatches_1815_, uint8_t v_callingOnSelf_1816_, uint8_t v_debounceOk_1817_, uint8_t v_forceFlag_1818_, uint8_t v_biometricApproved_1819_, uint8_t v_bunkerState_1820_, uint32_t v_liveWriters_1821_){
_start:
{
uint8_t v___x_1822_; uint8_t v___y_1824_; uint8_t v___x_1833_;
v___x_1822_ = 1;
v___x_1833_ = lean_uint8_dec_eq(v_serviceMatches_1815_, v___x_1822_);
if (v___x_1833_ == 0)
{
v___y_1824_ = v___x_1833_;
goto v___jp_1823_;
}
else
{
uint8_t v___x_1834_; uint8_t v___x_1835_;
v___x_1834_ = 0;
v___x_1835_ = lean_uint8_dec_eq(v_callingOnSelf_1816_, v___x_1834_);
if (v___x_1835_ == 0)
{
v___y_1824_ = v___x_1835_;
goto v___jp_1823_;
}
else
{
uint8_t v___x_1836_;
v___x_1836_ = lean_uint8_dec_eq(v_debounceOk_1817_, v___x_1822_);
if (v___x_1836_ == 0)
{
v___y_1824_ = v___x_1836_;
goto v___jp_1823_;
}
else
{
uint32_t v___x_1837_; uint8_t v___x_1838_;
v___x_1837_ = 0;
v___x_1838_ = lean_uint32_dec_eq(v_liveWriters_1821_, v___x_1837_);
if (v___x_1838_ == 0)
{
uint8_t v___x_1839_;
v___x_1839_ = lean_uint8_dec_eq(v_forceFlag_1818_, v___x_1822_);
if (v___x_1839_ == 0)
{
v___y_1824_ = v___x_1839_;
goto v___jp_1823_;
}
else
{
goto v___jp_1830_;
}
}
else
{
goto v___jp_1830_;
}
}
}
}
v___jp_1823_:
{
uint8_t v___x_1825_;
v___x_1825_ = lean_uint8_dec_eq(v_isProdService_1814_, v___x_1822_);
if (v___x_1825_ == 0)
{
if (v___y_1824_ == 0)
{
uint8_t v___x_1826_;
v___x_1826_ = 0;
return v___x_1826_;
}
else
{
return v___x_1822_;
}
}
else
{
if (v___y_1824_ == 0)
{
uint8_t v___x_1827_;
v___x_1827_ = 0;
return v___x_1827_;
}
else
{
uint8_t v___x_1828_;
v___x_1828_ = lean_uint8_dec_eq(v_biometricApproved_1819_, v___x_1822_);
if (v___x_1828_ == 0)
{
uint8_t v___x_1829_;
v___x_1829_ = 0;
return v___x_1829_;
}
else
{
return v___x_1822_;
}
}
}
}
v___jp_1830_:
{
uint8_t v___x_1831_; uint8_t v___x_1832_;
v___x_1831_ = 0;
v___x_1832_ = lean_uint8_dec_eq(v_bunkerState_1820_, v___x_1831_);
v___y_1824_ = v___x_1832_;
goto v___jp_1823_;
}
}
}

LEAN_EXPORT uint64_t orb_scroll_max_top(uint64_t v_content_1858_, uint64_t v_viewport_1859_){
_start:
{
uint8_t v___x_1860_;
v___x_1860_ = lean_uint64_dec_le(v_viewport_1859_, v_content_1858_);
if (v___x_1860_ == 0)
{
uint64_t v___x_1861_;
v___x_1861_ = 0ULL;
return v___x_1861_;
}
else
{
uint64_t v___x_1862_;
v___x_1862_ = lean_uint64_sub(v_content_1858_, v_viewport_1859_);
return v___x_1862_;
}
}
}

LEAN_EXPORT uint64_t orb_scroll_clamp_top(uint64_t v_content_1869_, uint64_t v_viewport_1870_, uint64_t v_top_1871_){
_start:
{
uint64_t v___y_1873_; uint8_t v___x_1875_;
v___x_1875_ = lean_uint64_dec_le(v_viewport_1870_, v_content_1869_);
if (v___x_1875_ == 0)
{
uint64_t v___x_1876_;
v___x_1876_ = 0ULL;
v___y_1873_ = v___x_1876_;
goto v___jp_1872_;
}
else
{
uint64_t v___x_1877_;
v___x_1877_ = lean_uint64_sub(v_content_1869_, v_viewport_1870_);
v___y_1873_ = v___x_1877_;
goto v___jp_1872_;
}
v___jp_1872_:
{
uint8_t v___x_1874_;
v___x_1874_ = lean_uint64_dec_le(v_top_1871_, v___y_1873_);
if (v___x_1874_ == 0)
{
return v___y_1873_;
}
else
{
return v_top_1871_;
}
}
}
}

LEAN_EXPORT uint64_t orb_scroll_gap(uint64_t v_content_1886_, uint64_t v_viewport_1887_, uint64_t v_top_1888_){
_start:
{
uint64_t v___y_1890_; uint64_t v___y_1891_; uint64_t v___y_1896_; uint64_t v___y_1897_; uint64_t v___y_1900_; uint8_t v___x_1904_;
v___x_1904_ = lean_uint64_dec_le(v_viewport_1887_, v_content_1886_);
if (v___x_1904_ == 0)
{
uint64_t v___x_1905_;
v___x_1905_ = 0ULL;
v___y_1900_ = v___x_1905_;
goto v___jp_1899_;
}
else
{
uint64_t v___x_1906_;
v___x_1906_ = lean_uint64_sub(v_content_1886_, v_viewport_1887_);
v___y_1900_ = v___x_1906_;
goto v___jp_1899_;
}
v___jp_1889_:
{
uint8_t v___x_1892_;
v___x_1892_ = lean_uint64_dec_le(v___y_1891_, v___y_1890_);
if (v___x_1892_ == 0)
{
uint64_t v___x_1893_;
v___x_1893_ = 0ULL;
return v___x_1893_;
}
else
{
uint64_t v___x_1894_;
v___x_1894_ = lean_uint64_sub(v___y_1890_, v___y_1891_);
return v___x_1894_;
}
}
v___jp_1895_:
{
uint8_t v___x_1898_;
v___x_1898_ = lean_uint64_dec_le(v_top_1888_, v___y_1897_);
if (v___x_1898_ == 0)
{
v___y_1890_ = v___y_1896_;
v___y_1891_ = v___y_1897_;
goto v___jp_1889_;
}
else
{
v___y_1890_ = v___y_1896_;
v___y_1891_ = v_top_1888_;
goto v___jp_1889_;
}
}
v___jp_1899_:
{
uint8_t v___x_1901_;
v___x_1901_ = lean_uint64_dec_le(v_viewport_1887_, v_content_1886_);
if (v___x_1901_ == 0)
{
uint64_t v___x_1902_;
v___x_1902_ = 0ULL;
v___y_1896_ = v___y_1900_;
v___y_1897_ = v___x_1902_;
goto v___jp_1895_;
}
else
{
uint64_t v___x_1903_;
v___x_1903_ = lean_uint64_sub(v_content_1886_, v_viewport_1887_);
v___y_1896_ = v___y_1900_;
v___y_1897_ = v___x_1903_;
goto v___jp_1895_;
}
}
}
}

LEAN_EXPORT uint64_t orb_scroll_layout_step(uint8_t v_pinned_1915_, uint64_t v_content_1916_, uint64_t v_viewport_1917_, uint64_t v_top_1918_){
_start:
{
uint64_t v___y_1920_; uint8_t v___x_1922_; uint8_t v___x_1923_;
v___x_1922_ = 1;
v___x_1923_ = lean_uint8_dec_eq(v_pinned_1915_, v___x_1922_);
if (v___x_1923_ == 0)
{
uint8_t v___x_1924_;
v___x_1924_ = lean_uint64_dec_le(v_viewport_1917_, v_content_1916_);
if (v___x_1924_ == 0)
{
uint64_t v___x_1925_;
v___x_1925_ = 0ULL;
v___y_1920_ = v___x_1925_;
goto v___jp_1919_;
}
else
{
uint64_t v___x_1926_;
v___x_1926_ = lean_uint64_sub(v_content_1916_, v_viewport_1917_);
v___y_1920_ = v___x_1926_;
goto v___jp_1919_;
}
}
else
{
uint8_t v___x_1927_;
v___x_1927_ = lean_uint64_dec_le(v_viewport_1917_, v_content_1916_);
if (v___x_1927_ == 0)
{
uint64_t v___x_1928_;
v___x_1928_ = 0ULL;
return v___x_1928_;
}
else
{
uint64_t v___x_1929_;
v___x_1929_ = lean_uint64_sub(v_content_1916_, v_viewport_1917_);
return v___x_1929_;
}
}
v___jp_1919_:
{
uint8_t v___x_1921_;
v___x_1921_ = lean_uint64_dec_le(v_top_1918_, v___y_1920_);
if (v___x_1921_ == 0)
{
return v___y_1920_;
}
else
{
return v_top_1918_;
}
}
}
}

LEAN_EXPORT uint8_t orb_scroll_user_step(uint64_t v_content_1940_, uint64_t v_viewport_1941_, uint64_t v_top_1942_, uint64_t v_threshold_1943_){
_start:
{
uint64_t v___y_1945_; uint64_t v___y_1950_; uint64_t v___y_1951_; uint64_t v___y_1956_; uint64_t v___y_1957_; uint64_t v___y_1960_; uint8_t v___x_1964_;
v___x_1964_ = lean_uint64_dec_le(v_viewport_1941_, v_content_1940_);
if (v___x_1964_ == 0)
{
uint64_t v___x_1965_;
v___x_1965_ = 0ULL;
v___y_1960_ = v___x_1965_;
goto v___jp_1959_;
}
else
{
uint64_t v___x_1966_;
v___x_1966_ = lean_uint64_sub(v_content_1940_, v_viewport_1941_);
v___y_1960_ = v___x_1966_;
goto v___jp_1959_;
}
v___jp_1944_:
{
uint8_t v___x_1946_;
v___x_1946_ = lean_uint64_dec_le(v___y_1945_, v_threshold_1943_);
if (v___x_1946_ == 0)
{
uint8_t v___x_1947_;
v___x_1947_ = 0;
return v___x_1947_;
}
else
{
uint8_t v___x_1948_;
v___x_1948_ = 1;
return v___x_1948_;
}
}
v___jp_1949_:
{
uint8_t v___x_1952_;
v___x_1952_ = lean_uint64_dec_le(v___y_1951_, v___y_1950_);
if (v___x_1952_ == 0)
{
uint64_t v___x_1953_;
v___x_1953_ = 0ULL;
v___y_1945_ = v___x_1953_;
goto v___jp_1944_;
}
else
{
uint64_t v___x_1954_;
v___x_1954_ = lean_uint64_sub(v___y_1950_, v___y_1951_);
v___y_1945_ = v___x_1954_;
goto v___jp_1944_;
}
}
v___jp_1955_:
{
uint8_t v___x_1958_;
v___x_1958_ = lean_uint64_dec_le(v_top_1942_, v___y_1957_);
if (v___x_1958_ == 0)
{
v___y_1950_ = v___y_1956_;
v___y_1951_ = v___y_1957_;
goto v___jp_1949_;
}
else
{
v___y_1950_ = v___y_1956_;
v___y_1951_ = v_top_1942_;
goto v___jp_1949_;
}
}
v___jp_1959_:
{
uint8_t v___x_1961_;
v___x_1961_ = lean_uint64_dec_le(v_viewport_1941_, v_content_1940_);
if (v___x_1961_ == 0)
{
uint64_t v___x_1962_;
v___x_1962_ = 0ULL;
v___y_1956_ = v___y_1960_;
v___y_1957_ = v___x_1962_;
goto v___jp_1955_;
}
else
{
uint64_t v___x_1963_;
v___x_1963_ = lean_uint64_sub(v_content_1940_, v_viewport_1941_);
v___y_1956_ = v___y_1960_;
v___y_1957_ = v___x_1963_;
goto v___jp_1955_;
}
}
}
}

LEAN_EXPORT uint64_t orb_scroll_jump_step(uint64_t v_content_1977_, uint64_t v_viewport_1978_){
_start:
{
uint8_t v___x_1979_;
v___x_1979_ = lean_uint64_dec_le(v_viewport_1978_, v_content_1977_);
if (v___x_1979_ == 0)
{
uint64_t v___x_1980_;
v___x_1980_ = 0ULL;
return v___x_1980_;
}
else
{
uint64_t v___x_1981_;
v___x_1981_ = lean_uint64_sub(v_content_1977_, v_viewport_1978_);
return v___x_1981_;
}
}
}

LEAN_EXPORT uint64_t orb_scroll_correct(uint8_t v_pinned_1988_, uint64_t v_content_1989_, uint64_t v_viewport_1990_, uint64_t v_top_1991_){
_start:
{
uint64_t v___y_1993_; uint8_t v___x_1995_; uint8_t v___x_1996_;
v___x_1995_ = 1;
v___x_1996_ = lean_uint8_dec_eq(v_pinned_1988_, v___x_1995_);
if (v___x_1996_ == 0)
{
uint8_t v___x_1997_;
v___x_1997_ = lean_uint64_dec_le(v_viewport_1990_, v_content_1989_);
if (v___x_1997_ == 0)
{
uint64_t v___x_1998_;
v___x_1998_ = 0ULL;
v___y_1993_ = v___x_1998_;
goto v___jp_1992_;
}
else
{
uint64_t v___x_1999_;
v___x_1999_ = lean_uint64_sub(v_content_1989_, v_viewport_1990_);
v___y_1993_ = v___x_1999_;
goto v___jp_1992_;
}
}
else
{
uint8_t v___x_2000_;
v___x_2000_ = lean_uint64_dec_le(v_viewport_1990_, v_content_1989_);
if (v___x_2000_ == 0)
{
uint64_t v___x_2001_;
v___x_2001_ = 0ULL;
return v___x_2001_;
}
else
{
uint64_t v___x_2002_;
v___x_2002_ = lean_uint64_sub(v_content_1989_, v_viewport_1990_);
return v___x_2002_;
}
}
v___jp_1992_:
{
uint8_t v___x_1994_;
v___x_1994_ = lean_uint64_dec_le(v_top_1991_, v___y_1993_);
if (v___x_1994_ == 0)
{
return v___y_1993_;
}
else
{
return v_top_1991_;
}
}
}
}

LEAN_EXPORT uint8_t orb_scroll_shows_jump(uint8_t v_pinned_2013_, uint64_t v_content_2014_, uint64_t v_viewport_2015_, uint64_t v_top_2016_, uint64_t v_pillThreshold_2017_){
_start:
{
uint8_t v___x_2018_; uint64_t v___y_2020_; uint64_t v___y_2024_; uint64_t v___y_2025_; uint64_t v___y_2030_; uint64_t v___y_2031_; uint64_t v___y_2034_; uint8_t v___x_2038_;
v___x_2018_ = 0;
v___x_2038_ = lean_uint8_dec_eq(v_pinned_2013_, v___x_2018_);
if (v___x_2038_ == 0)
{
return v___x_2018_;
}
else
{
uint64_t v___x_2039_; uint8_t v___x_2040_;
v___x_2039_ = 18446744073709551591ULL;
v___x_2040_ = lean_uint64_dec_le(v_viewport_2015_, v___x_2039_);
if (v___x_2040_ == 0)
{
return v___x_2018_;
}
else
{
uint64_t v___x_2041_; uint64_t v___x_2042_; uint8_t v___x_2043_;
v___x_2041_ = 24ULL;
v___x_2042_ = lean_uint64_add(v_viewport_2015_, v___x_2041_);
v___x_2043_ = lean_uint64_dec_lt(v___x_2042_, v_content_2014_);
if (v___x_2043_ == 0)
{
return v___x_2018_;
}
else
{
uint8_t v___x_2044_;
v___x_2044_ = lean_uint64_dec_le(v_viewport_2015_, v_content_2014_);
if (v___x_2044_ == 0)
{
uint64_t v___x_2045_;
v___x_2045_ = 0ULL;
v___y_2034_ = v___x_2045_;
goto v___jp_2033_;
}
else
{
uint64_t v___x_2046_;
v___x_2046_ = lean_uint64_sub(v_content_2014_, v_viewport_2015_);
v___y_2034_ = v___x_2046_;
goto v___jp_2033_;
}
}
}
}
v___jp_2019_:
{
uint8_t v___x_2021_;
v___x_2021_ = lean_uint64_dec_lt(v_pillThreshold_2017_, v___y_2020_);
if (v___x_2021_ == 0)
{
return v___x_2018_;
}
else
{
uint8_t v___x_2022_;
v___x_2022_ = 1;
return v___x_2022_;
}
}
v___jp_2023_:
{
uint8_t v___x_2026_;
v___x_2026_ = lean_uint64_dec_le(v___y_2025_, v___y_2024_);
if (v___x_2026_ == 0)
{
uint64_t v___x_2027_;
v___x_2027_ = 0ULL;
v___y_2020_ = v___x_2027_;
goto v___jp_2019_;
}
else
{
uint64_t v___x_2028_;
v___x_2028_ = lean_uint64_sub(v___y_2024_, v___y_2025_);
v___y_2020_ = v___x_2028_;
goto v___jp_2019_;
}
}
v___jp_2029_:
{
uint8_t v___x_2032_;
v___x_2032_ = lean_uint64_dec_le(v_top_2016_, v___y_2031_);
if (v___x_2032_ == 0)
{
v___y_2024_ = v___y_2030_;
v___y_2025_ = v___y_2031_;
goto v___jp_2023_;
}
else
{
v___y_2024_ = v___y_2030_;
v___y_2025_ = v_top_2016_;
goto v___jp_2023_;
}
}
v___jp_2033_:
{
uint8_t v___x_2035_;
v___x_2035_ = lean_uint64_dec_le(v_viewport_2015_, v_content_2014_);
if (v___x_2035_ == 0)
{
uint64_t v___x_2036_;
v___x_2036_ = 0ULL;
v___y_2030_ = v___y_2034_;
v___y_2031_ = v___x_2036_;
goto v___jp_2029_;
}
else
{
uint64_t v___x_2037_;
v___x_2037_ = lean_uint64_sub(v_content_2014_, v_viewport_2015_);
v___y_2030_ = v___y_2034_;
v___y_2031_ = v___x_2037_;
goto v___jp_2029_;
}
}
}
}

LEAN_EXPORT uint64_t orb_stream_coalescer_step(uint8_t v_op_2059_, uint32_t v_shownLen_2060_, uint32_t v_pendingLen_2061_, uint32_t v_deltaLen_2062_){
_start:
{
uint32_t v___y_2064_; uint32_t v___y_2069_; uint8_t v___x_2077_; uint8_t v___x_2078_;
v___x_2077_ = 0;
v___x_2078_ = lean_uint8_dec_eq(v_op_2059_, v___x_2077_);
if (v___x_2078_ == 0)
{
uint8_t v___x_2079_; uint8_t v___x_2080_;
v___x_2079_ = 1;
v___x_2080_ = lean_uint8_dec_eq(v_op_2059_, v___x_2079_);
if (v___x_2080_ == 0)
{
uint64_t v___x_2081_;
v___x_2081_ = 0ULL;
return v___x_2081_;
}
else
{
uint32_t v___x_2082_; uint8_t v___x_2083_;
v___x_2082_ = 0;
v___x_2083_ = lean_uint32_dec_eq(v_pendingLen_2061_, v___x_2082_);
if (v___x_2083_ == 0)
{
uint32_t v___x_2084_; uint32_t v___x_2085_; uint8_t v___x_2086_;
v___x_2084_ = 4294967295;
v___x_2085_ = lean_uint32_sub(v___x_2084_, v_pendingLen_2061_);
v___x_2086_ = lean_uint32_dec_le(v_shownLen_2060_, v___x_2085_);
if (v___x_2086_ == 0)
{
v___y_2064_ = v___x_2084_;
goto v___jp_2063_;
}
else
{
uint32_t v___x_2087_;
v___x_2087_ = lean_uint32_add(v_shownLen_2060_, v_pendingLen_2061_);
v___y_2064_ = v___x_2087_;
goto v___jp_2063_;
}
}
else
{
uint64_t v___x_2088_;
v___x_2088_ = lean_uint32_to_uint64(v_shownLen_2060_);
return v___x_2088_;
}
}
}
else
{
uint32_t v___x_2089_; uint32_t v___x_2090_; uint8_t v___x_2091_;
v___x_2089_ = 4294967295;
v___x_2090_ = lean_uint32_sub(v___x_2089_, v_deltaLen_2062_);
v___x_2091_ = lean_uint32_dec_le(v_pendingLen_2061_, v___x_2090_);
if (v___x_2091_ == 0)
{
v___y_2069_ = v___x_2089_;
goto v___jp_2068_;
}
else
{
uint32_t v___x_2092_;
v___x_2092_ = lean_uint32_add(v_pendingLen_2061_, v_deltaLen_2062_);
v___y_2069_ = v___x_2092_;
goto v___jp_2068_;
}
}
v___jp_2063_:
{
uint64_t v___x_2065_; uint64_t v___x_2066_; uint64_t v___x_2067_;
v___x_2065_ = lean_uint32_to_uint64(v___y_2064_);
v___x_2066_ = 9223372036854775808ULL;
v___x_2067_ = lean_uint64_lor(v___x_2065_, v___x_2066_);
return v___x_2067_;
}
v___jp_2068_:
{
uint64_t v___x_2070_; uint64_t v___x_2071_; uint64_t v___x_2072_; uint64_t v___x_2073_; uint64_t v___x_2074_; uint64_t v___x_2075_; uint64_t v___x_2076_;
v___x_2070_ = lean_uint32_to_uint64(v_shownLen_2060_);
v___x_2071_ = lean_uint32_to_uint64(v___y_2069_);
v___x_2072_ = 2147483647ULL;
v___x_2073_ = lean_uint64_land(v___x_2071_, v___x_2072_);
v___x_2074_ = 32ULL;
v___x_2075_ = lean_uint64_shift_left(v___x_2073_, v___x_2074_);
v___x_2076_ = lean_uint64_lor(v___x_2070_, v___x_2075_);
return v___x_2076_;
}
}
}

LEAN_EXPORT uint64_t orb_stream_fence_step(uint8_t v_openKind_2160_, uint32_t v_openCount_2161_, uint8_t v_markerKind_2162_, uint32_t v_markerCount_2163_){
_start:
{
uint8_t v___y_2165_; uint32_t v___y_2166_; uint8_t v___y_2173_; uint8_t v___y_2178_; uint8_t v___x_2191_; uint8_t v___x_2195_;
v___x_2191_ = 0;
v___x_2195_ = lean_uint8_dec_eq(v_openKind_2160_, v___x_2191_);
if (v___x_2195_ == 0)
{
uint8_t v___x_2196_;
v___x_2196_ = lean_uint8_dec_eq(v_markerKind_2162_, v_openKind_2160_);
if (v___x_2196_ == 0)
{
v___y_2178_ = v_openKind_2160_;
goto v___jp_2177_;
}
else
{
uint8_t v___x_2197_;
v___x_2197_ = lean_uint32_dec_le(v_openCount_2161_, v_markerCount_2163_);
if (v___x_2197_ == 0)
{
v___y_2178_ = v_openKind_2160_;
goto v___jp_2177_;
}
else
{
uint32_t v___x_2198_; uint8_t v___x_2199_;
v___x_2198_ = 3;
v___x_2199_ = lean_uint32_dec_le(v___x_2198_, v_markerCount_2163_);
if (v___x_2199_ == 0)
{
v___y_2178_ = v_openKind_2160_;
goto v___jp_2177_;
}
else
{
v___y_2178_ = v___x_2191_;
goto v___jp_2177_;
}
}
}
}
else
{
uint8_t v___x_2200_; uint8_t v___x_2201_;
v___x_2200_ = 1;
v___x_2201_ = lean_uint8_dec_eq(v_markerKind_2162_, v___x_2200_);
if (v___x_2201_ == 0)
{
uint8_t v___x_2202_; uint8_t v___x_2203_;
v___x_2202_ = 2;
v___x_2203_ = lean_uint8_dec_eq(v_markerKind_2162_, v___x_2202_);
if (v___x_2203_ == 0)
{
v___y_2178_ = v___x_2191_;
goto v___jp_2177_;
}
else
{
goto v___jp_2192_;
}
}
else
{
goto v___jp_2192_;
}
}
v___jp_2164_:
{
uint64_t v___x_2167_; uint64_t v___x_2168_; uint64_t v___x_2169_; uint64_t v___x_2170_; uint64_t v___x_2171_;
v___x_2167_ = lean_uint8_to_uint64(v___y_2165_);
v___x_2168_ = lean_uint32_to_uint64(v___y_2166_);
v___x_2169_ = 32ULL;
v___x_2170_ = lean_uint64_shift_left(v___x_2168_, v___x_2169_);
v___x_2171_ = lean_uint64_lor(v___x_2167_, v___x_2170_);
return v___x_2171_;
}
v___jp_2172_:
{
uint32_t v___x_2174_; uint8_t v___x_2175_;
v___x_2174_ = 3;
v___x_2175_ = lean_uint32_dec_le(v___x_2174_, v_markerCount_2163_);
if (v___x_2175_ == 0)
{
uint32_t v___x_2176_;
v___x_2176_ = 0;
v___y_2165_ = v___y_2173_;
v___y_2166_ = v___x_2176_;
goto v___jp_2164_;
}
else
{
v___y_2165_ = v___y_2173_;
v___y_2166_ = v_markerCount_2163_;
goto v___jp_2164_;
}
}
v___jp_2177_:
{
uint8_t v___x_2179_; uint8_t v___x_2180_;
v___x_2179_ = 0;
v___x_2180_ = lean_uint8_dec_eq(v_openKind_2160_, v___x_2179_);
if (v___x_2180_ == 0)
{
uint8_t v___x_2181_;
v___x_2181_ = lean_uint8_dec_eq(v_markerKind_2162_, v_openKind_2160_);
if (v___x_2181_ == 0)
{
v___y_2165_ = v___y_2178_;
v___y_2166_ = v_openCount_2161_;
goto v___jp_2164_;
}
else
{
uint8_t v___x_2182_;
v___x_2182_ = lean_uint32_dec_le(v_openCount_2161_, v_markerCount_2163_);
if (v___x_2182_ == 0)
{
v___y_2165_ = v___y_2178_;
v___y_2166_ = v_openCount_2161_;
goto v___jp_2164_;
}
else
{
uint32_t v___x_2183_; uint8_t v___x_2184_;
v___x_2183_ = 3;
v___x_2184_ = lean_uint32_dec_le(v___x_2183_, v_markerCount_2163_);
if (v___x_2184_ == 0)
{
v___y_2165_ = v___y_2178_;
v___y_2166_ = v_openCount_2161_;
goto v___jp_2164_;
}
else
{
uint32_t v___x_2185_;
v___x_2185_ = 0;
v___y_2165_ = v___y_2178_;
v___y_2166_ = v___x_2185_;
goto v___jp_2164_;
}
}
}
}
else
{
uint8_t v___x_2186_; uint8_t v___x_2187_;
v___x_2186_ = 1;
v___x_2187_ = lean_uint8_dec_eq(v_markerKind_2162_, v___x_2186_);
if (v___x_2187_ == 0)
{
uint8_t v___x_2188_; uint8_t v___x_2189_;
v___x_2188_ = 2;
v___x_2189_ = lean_uint8_dec_eq(v_markerKind_2162_, v___x_2188_);
if (v___x_2189_ == 0)
{
uint32_t v___x_2190_;
v___x_2190_ = 0;
v___y_2165_ = v___y_2178_;
v___y_2166_ = v___x_2190_;
goto v___jp_2164_;
}
else
{
v___y_2173_ = v___y_2178_;
goto v___jp_2172_;
}
}
else
{
v___y_2173_ = v___y_2178_;
goto v___jp_2172_;
}
}
}
v___jp_2192_:
{
uint32_t v___x_2193_; uint8_t v___x_2194_;
v___x_2193_ = 3;
v___x_2194_ = lean_uint32_dec_le(v___x_2193_, v_markerCount_2163_);
if (v___x_2194_ == 0)
{
v___y_2178_ = v___x_2191_;
goto v___jp_2177_;
}
else
{
v___y_2178_ = v_markerKind_2162_;
goto v___jp_2177_;
}
}
}
}

LEAN_EXPORT uint64_t orb_stream_commit_step(uint8_t v_tick_2214_, uint8_t v_openKind_2215_, uint32_t v_openCount_2216_, uint8_t v_lineBlank_2217_, uint8_t v_lineTick_2218_, uint8_t v_markerKind_2219_, uint32_t v_markerCount_2220_, uint32_t v_pos_2221_, uint32_t v_commit_2222_){
_start:
{
uint32_t v___y_2224_; uint8_t v___y_2225_; uint32_t v___y_2226_; uint32_t v___y_2227_; uint8_t v___y_2237_; uint32_t v___y_2238_; uint8_t v___y_2239_; uint32_t v___y_2240_; uint8_t v___x_2243_; uint8_t v___y_2245_; uint8_t v___y_2246_; uint8_t v___y_2247_; uint32_t v___y_2248_; uint8_t v___y_2256_; uint32_t v___y_2257_; uint8_t v___y_2258_; uint8_t v___y_2259_; uint8_t v___y_2262_; uint8_t v___y_2263_; uint32_t v___y_2264_; uint8_t v___y_2267_; uint8_t v___y_2268_; uint32_t v___y_2269_; uint8_t v___y_2275_; uint8_t v___y_2276_; uint8_t v___y_2283_; uint8_t v___y_2284_; uint8_t v___y_2288_; uint8_t v___x_2298_;
v___x_2243_ = 1;
v___x_2298_ = lean_uint8_dec_eq(v_lineTick_2218_, v___x_2243_);
if (v___x_2298_ == 0)
{
uint8_t v___x_2299_;
v___x_2299_ = lean_uint8_dec_eq(v_tick_2214_, v___x_2243_);
if (v___x_2299_ == 0)
{
uint8_t v___x_2300_;
v___x_2300_ = 0;
v___y_2288_ = v___x_2300_;
goto v___jp_2287_;
}
else
{
v___y_2288_ = v___x_2243_;
goto v___jp_2287_;
}
}
else
{
uint8_t v___x_2301_;
v___x_2301_ = lean_uint8_dec_eq(v_tick_2214_, v___x_2243_);
if (v___x_2301_ == 0)
{
v___y_2288_ = v___x_2243_;
goto v___jp_2287_;
}
else
{
uint8_t v___x_2302_;
v___x_2302_ = 0;
v___y_2288_ = v___x_2302_;
goto v___jp_2287_;
}
}
v___jp_2223_:
{
uint32_t v___x_2228_; uint32_t v___x_2229_; uint32_t v_lo32_2230_; uint64_t v___x_2231_; uint64_t v___x_2232_; uint64_t v___x_2233_; uint64_t v___x_2234_; uint64_t v___x_2235_;
v___x_2228_ = lean_uint8_to_uint32(v___y_2225_);
v___x_2229_ = lean_uint32_lor(v___x_2228_, v___y_2226_);
v_lo32_2230_ = lean_uint32_lor(v___x_2229_, v___y_2227_);
v___x_2231_ = lean_uint32_to_uint64(v_lo32_2230_);
v___x_2232_ = lean_uint32_to_uint64(v___y_2224_);
v___x_2233_ = 32ULL;
v___x_2234_ = lean_uint64_shift_left(v___x_2232_, v___x_2233_);
v___x_2235_ = lean_uint64_lor(v___x_2231_, v___x_2234_);
return v___x_2235_;
}
v___jp_2236_:
{
if (v___y_2239_ == 0)
{
uint32_t v___x_2241_;
v___x_2241_ = 0;
v___y_2224_ = v___y_2238_;
v___y_2225_ = v___y_2237_;
v___y_2226_ = v___y_2240_;
v___y_2227_ = v___x_2241_;
goto v___jp_2223_;
}
else
{
uint32_t v___x_2242_;
v___x_2242_ = 65536;
v___y_2224_ = v___y_2238_;
v___y_2225_ = v___y_2237_;
v___y_2226_ = v___y_2240_;
v___y_2227_ = v___x_2242_;
goto v___jp_2223_;
}
}
v___jp_2244_:
{
uint8_t v___x_2249_;
v___x_2249_ = lean_uint8_dec_eq(v___y_2247_, v___x_2243_);
if (v___x_2249_ == 0)
{
uint8_t v___x_2250_; uint8_t v___x_2251_;
v___x_2250_ = 2;
v___x_2251_ = lean_uint8_dec_eq(v___y_2247_, v___x_2250_);
if (v___x_2251_ == 0)
{
uint32_t v___x_2252_;
v___x_2252_ = 0;
v___y_2237_ = v___y_2245_;
v___y_2238_ = v___y_2248_;
v___y_2239_ = v___y_2246_;
v___y_2240_ = v___x_2252_;
goto v___jp_2236_;
}
else
{
uint32_t v___x_2253_;
v___x_2253_ = 512;
v___y_2237_ = v___y_2245_;
v___y_2238_ = v___y_2248_;
v___y_2239_ = v___y_2246_;
v___y_2240_ = v___x_2253_;
goto v___jp_2236_;
}
}
else
{
uint32_t v___x_2254_;
v___x_2254_ = 256;
v___y_2237_ = v___y_2245_;
v___y_2238_ = v___y_2248_;
v___y_2239_ = v___y_2246_;
v___y_2240_ = v___x_2254_;
goto v___jp_2236_;
}
}
v___jp_2255_:
{
uint8_t v___x_2260_;
v___x_2260_ = lean_uint8_dec_eq(v___y_2259_, v___x_2243_);
if (v___x_2260_ == 0)
{
v___y_2245_ = v___y_2256_;
v___y_2246_ = v___x_2260_;
v___y_2247_ = v___y_2258_;
v___y_2248_ = v_commit_2222_;
goto v___jp_2244_;
}
else
{
v___y_2245_ = v___y_2256_;
v___y_2246_ = v___x_2260_;
v___y_2247_ = v___y_2258_;
v___y_2248_ = v___y_2257_;
goto v___jp_2244_;
}
}
v___jp_2261_:
{
uint8_t v___x_2265_;
v___x_2265_ = 0;
v___y_2256_ = v___y_2262_;
v___y_2257_ = v___y_2264_;
v___y_2258_ = v___y_2263_;
v___y_2259_ = v___x_2265_;
goto v___jp_2255_;
}
v___jp_2266_:
{
uint8_t v___x_2270_;
v___x_2270_ = lean_uint8_dec_eq(v_lineBlank_2217_, v___x_2243_);
if (v___x_2270_ == 0)
{
v___y_2262_ = v___y_2267_;
v___y_2263_ = v___y_2268_;
v___y_2264_ = v___y_2269_;
goto v___jp_2261_;
}
else
{
uint8_t v___x_2271_; uint8_t v___x_2272_;
v___x_2271_ = 0;
v___x_2272_ = lean_uint8_dec_eq(v___y_2267_, v___x_2271_);
if (v___x_2272_ == 0)
{
v___y_2262_ = v___y_2267_;
v___y_2263_ = v___y_2268_;
v___y_2264_ = v___y_2269_;
goto v___jp_2261_;
}
else
{
uint8_t v___x_2273_;
v___x_2273_ = lean_uint8_dec_eq(v___y_2268_, v___x_2271_);
if (v___x_2273_ == 0)
{
v___y_2262_ = v___y_2267_;
v___y_2263_ = v___y_2268_;
v___y_2264_ = v___y_2269_;
goto v___jp_2261_;
}
else
{
v___y_2256_ = v___y_2267_;
v___y_2257_ = v___y_2269_;
v___y_2258_ = v___y_2268_;
v___y_2259_ = v___x_2243_;
goto v___jp_2255_;
}
}
}
}
v___jp_2274_:
{
uint32_t v___x_2277_; uint8_t v___x_2278_;
v___x_2277_ = 4294967294;
v___x_2278_ = lean_uint32_dec_le(v_pos_2221_, v___x_2277_);
if (v___x_2278_ == 0)
{
uint32_t v___x_2279_;
v___x_2279_ = 4294967295;
v___y_2267_ = v___y_2275_;
v___y_2268_ = v___y_2276_;
v___y_2269_ = v___x_2279_;
goto v___jp_2266_;
}
else
{
uint32_t v___x_2280_; uint32_t v___x_2281_;
v___x_2280_ = 1;
v___x_2281_ = lean_uint32_add(v_pos_2221_, v___x_2280_);
v___y_2267_ = v___y_2275_;
v___y_2268_ = v___y_2276_;
v___y_2269_ = v___x_2281_;
goto v___jp_2266_;
}
}
v___jp_2282_:
{
uint32_t v___x_2285_; uint8_t v___x_2286_;
v___x_2285_ = 3;
v___x_2286_ = lean_uint32_dec_le(v___x_2285_, v_markerCount_2220_);
if (v___x_2286_ == 0)
{
v___y_2275_ = v___y_2283_;
v___y_2276_ = v___y_2284_;
goto v___jp_2274_;
}
else
{
v___y_2275_ = v___y_2283_;
v___y_2276_ = v_markerKind_2219_;
goto v___jp_2274_;
}
}
v___jp_2287_:
{
uint8_t v___x_2289_; uint8_t v___x_2290_;
v___x_2289_ = 0;
v___x_2290_ = lean_uint8_dec_eq(v_openKind_2215_, v___x_2289_);
if (v___x_2290_ == 0)
{
uint8_t v___x_2291_;
v___x_2291_ = lean_uint8_dec_eq(v_markerKind_2219_, v_openKind_2215_);
if (v___x_2291_ == 0)
{
v___y_2275_ = v___y_2288_;
v___y_2276_ = v_openKind_2215_;
goto v___jp_2274_;
}
else
{
uint8_t v___x_2292_;
v___x_2292_ = lean_uint32_dec_le(v_openCount_2216_, v_markerCount_2220_);
if (v___x_2292_ == 0)
{
v___y_2275_ = v___y_2288_;
v___y_2276_ = v_openKind_2215_;
goto v___jp_2274_;
}
else
{
uint32_t v___x_2293_; uint8_t v___x_2294_;
v___x_2293_ = 3;
v___x_2294_ = lean_uint32_dec_le(v___x_2293_, v_markerCount_2220_);
if (v___x_2294_ == 0)
{
v___y_2275_ = v___y_2288_;
v___y_2276_ = v_openKind_2215_;
goto v___jp_2274_;
}
else
{
v___y_2275_ = v___y_2288_;
v___y_2276_ = v___x_2289_;
goto v___jp_2274_;
}
}
}
}
else
{
uint8_t v___x_2295_;
v___x_2295_ = lean_uint8_dec_eq(v_markerKind_2219_, v___x_2243_);
if (v___x_2295_ == 0)
{
uint8_t v___x_2296_; uint8_t v___x_2297_;
v___x_2296_ = 2;
v___x_2297_ = lean_uint8_dec_eq(v_markerKind_2219_, v___x_2296_);
if (v___x_2297_ == 0)
{
v___y_2275_ = v___y_2288_;
v___y_2276_ = v___x_2289_;
goto v___jp_2274_;
}
else
{
v___y_2283_ = v___y_2288_;
v___y_2284_ = v___x_2289_;
goto v___jp_2282_;
}
}
else
{
v___y_2283_ = v___y_2288_;
v___y_2284_ = v___x_2289_;
goto v___jp_2282_;
}
}
}
}
}

LEAN_EXPORT uint64_t orb_stream_token_cost_step(uint64_t v_prevCost_2323_, uint64_t v_newAdvance_2324_, uint64_t v_tailBytes_2325_){
_start:
{
uint64_t v___y_2327_; uint64_t v___x_2332_; uint64_t v___x_2333_; uint8_t v___x_2334_;
v___x_2332_ = 18446744073709551615ULL;
v___x_2333_ = lean_uint64_sub(v___x_2332_, v_tailBytes_2325_);
v___x_2334_ = lean_uint64_dec_le(v_newAdvance_2324_, v___x_2333_);
if (v___x_2334_ == 0)
{
v___y_2327_ = v___x_2332_;
goto v___jp_2326_;
}
else
{
uint64_t v___x_2335_;
v___x_2335_ = lean_uint64_add(v_newAdvance_2324_, v_tailBytes_2325_);
v___y_2327_ = v___x_2335_;
goto v___jp_2326_;
}
v___jp_2326_:
{
uint64_t v___x_2328_; uint64_t v___x_2329_; uint8_t v___x_2330_;
v___x_2328_ = 18446744073709551615ULL;
v___x_2329_ = lean_uint64_sub(v___x_2328_, v___y_2327_);
v___x_2330_ = lean_uint64_dec_le(v_prevCost_2323_, v___x_2329_);
if (v___x_2330_ == 0)
{
return v___x_2328_;
}
else
{
uint64_t v___x_2331_;
v___x_2331_ = lean_uint64_add(v_prevCost_2323_, v___y_2327_);
return v___x_2331_;
}
}
}
}

LEAN_EXPORT uint8_t orb_mission_state_classify(uint8_t v_stateId_2344_){
_start:
{
uint8_t v___x_2345_; uint8_t v___x_2346_;
v___x_2345_ = 8;
v___x_2346_ = lean_uint8_dec_le(v_stateId_2344_, v___x_2345_);
if (v___x_2346_ == 0)
{
uint8_t v___x_2347_; uint8_t v___x_2348_;
v___x_2347_ = 10;
v___x_2348_ = lean_uint8_dec_le(v_stateId_2344_, v___x_2347_);
if (v___x_2348_ == 0)
{
uint8_t v___x_2349_; uint8_t v___x_2350_;
v___x_2349_ = 15;
v___x_2350_ = lean_uint8_dec_le(v_stateId_2344_, v___x_2349_);
if (v___x_2350_ == 0)
{
uint8_t v___x_2351_; uint8_t v___x_2352_;
v___x_2351_ = 16;
v___x_2352_ = lean_uint8_dec_eq(v_stateId_2344_, v___x_2351_);
if (v___x_2352_ == 0)
{
uint8_t v___x_2353_; uint8_t v___x_2354_;
v___x_2353_ = 21;
v___x_2354_ = lean_uint8_dec_le(v_stateId_2344_, v___x_2353_);
if (v___x_2354_ == 0)
{
uint8_t v___x_2355_; uint8_t v___x_2356_;
v___x_2355_ = 23;
v___x_2356_ = lean_uint8_dec_le(v_stateId_2344_, v___x_2355_);
if (v___x_2356_ == 0)
{
uint8_t v___x_2357_; uint8_t v___x_2358_;
v___x_2357_ = 24;
v___x_2358_ = lean_uint8_dec_eq(v_stateId_2344_, v___x_2357_);
if (v___x_2358_ == 0)
{
uint8_t v___x_2359_; uint8_t v___x_2360_;
v___x_2359_ = 26;
v___x_2360_ = lean_uint8_dec_le(v_stateId_2344_, v___x_2359_);
if (v___x_2360_ == 0)
{
uint8_t v___x_2361_; uint8_t v___x_2362_;
v___x_2361_ = 28;
v___x_2362_ = lean_uint8_dec_le(v_stateId_2344_, v___x_2361_);
if (v___x_2362_ == 0)
{
uint8_t v___x_2363_;
v___x_2363_ = 9;
return v___x_2363_;
}
else
{
return v___x_2345_;
}
}
else
{
uint8_t v___x_2364_;
v___x_2364_ = 7;
return v___x_2364_;
}
}
else
{
uint8_t v___x_2365_;
v___x_2365_ = 5;
return v___x_2365_;
}
}
else
{
uint8_t v___x_2366_;
v___x_2366_ = 6;
return v___x_2366_;
}
}
else
{
uint8_t v___x_2367_;
v___x_2367_ = 2;
return v___x_2367_;
}
}
else
{
uint8_t v___x_2368_;
v___x_2368_ = 1;
return v___x_2368_;
}
}
else
{
uint8_t v___x_2369_;
v___x_2369_ = 0;
return v___x_2369_;
}
}
else
{
uint8_t v___x_2370_;
v___x_2370_ = 4;
return v___x_2370_;
}
}
else
{
uint8_t v___x_2371_;
v___x_2371_ = 3;
return v___x_2371_;
}
}
}

LEAN_EXPORT uint8_t orb_mission_sort_rank(uint8_t v_stateId_2376_){
_start:
{
uint8_t v___x_2377_; uint8_t v___x_2378_;
v___x_2377_ = 8;
v___x_2378_ = lean_uint8_dec_le(v_stateId_2376_, v___x_2377_);
if (v___x_2378_ == 0)
{
uint8_t v___x_2379_; uint8_t v___x_2380_;
v___x_2379_ = 10;
v___x_2380_ = lean_uint8_dec_le(v_stateId_2376_, v___x_2379_);
if (v___x_2380_ == 0)
{
uint8_t v___x_2381_; uint8_t v___x_2382_;
v___x_2381_ = 15;
v___x_2382_ = lean_uint8_dec_le(v_stateId_2376_, v___x_2381_);
if (v___x_2382_ == 0)
{
uint8_t v___x_2383_; uint8_t v___x_2384_;
v___x_2383_ = 16;
v___x_2384_ = lean_uint8_dec_eq(v_stateId_2376_, v___x_2383_);
if (v___x_2384_ == 0)
{
uint8_t v___x_2385_; uint8_t v___x_2386_;
v___x_2385_ = 21;
v___x_2386_ = lean_uint8_dec_le(v_stateId_2376_, v___x_2385_);
if (v___x_2386_ == 0)
{
uint8_t v___x_2387_; uint8_t v___x_2388_;
v___x_2387_ = 23;
v___x_2388_ = lean_uint8_dec_le(v_stateId_2376_, v___x_2387_);
if (v___x_2388_ == 0)
{
uint8_t v___x_2389_; uint8_t v___x_2390_;
v___x_2389_ = 24;
v___x_2390_ = lean_uint8_dec_eq(v_stateId_2376_, v___x_2389_);
if (v___x_2390_ == 0)
{
uint8_t v___x_2391_; uint8_t v___x_2392_;
v___x_2391_ = 26;
v___x_2392_ = lean_uint8_dec_le(v_stateId_2376_, v___x_2391_);
if (v___x_2392_ == 0)
{
uint8_t v___x_2393_; uint8_t v___x_2394_;
v___x_2393_ = 28;
v___x_2394_ = lean_uint8_dec_le(v_stateId_2376_, v___x_2393_);
if (v___x_2394_ == 0)
{
uint8_t v___x_2395_;
v___x_2395_ = 9;
return v___x_2395_;
}
else
{
return v___x_2377_;
}
}
else
{
uint8_t v___x_2396_;
v___x_2396_ = 7;
return v___x_2396_;
}
}
else
{
uint8_t v___x_2397_;
v___x_2397_ = 5;
return v___x_2397_;
}
}
else
{
uint8_t v___x_2398_;
v___x_2398_ = 6;
return v___x_2398_;
}
}
else
{
uint8_t v___x_2399_;
v___x_2399_ = 2;
return v___x_2399_;
}
}
else
{
uint8_t v___x_2400_;
v___x_2400_ = 1;
return v___x_2400_;
}
}
else
{
uint8_t v___x_2401_;
v___x_2401_ = 0;
return v___x_2401_;
}
}
else
{
uint8_t v___x_2402_;
v___x_2402_ = 4;
return v___x_2402_;
}
}
else
{
uint8_t v___x_2403_;
v___x_2403_ = 3;
return v___x_2403_;
}
}
}

LEAN_EXPORT uint32_t orb_mission_flags(uint8_t v_stateId_2494_){
_start:
{
uint32_t v___y_2496_; uint8_t v___y_2534_; uint8_t v___x_2560_; uint8_t v___x_2561_;
v___x_2560_ = 8;
v___x_2561_ = lean_uint8_dec_le(v_stateId_2494_, v___x_2560_);
if (v___x_2561_ == 0)
{
uint8_t v___x_2562_; uint8_t v___x_2563_;
v___x_2562_ = 10;
v___x_2563_ = lean_uint8_dec_le(v_stateId_2494_, v___x_2562_);
if (v___x_2563_ == 0)
{
uint8_t v___x_2564_; uint8_t v___x_2565_;
v___x_2564_ = 15;
v___x_2565_ = lean_uint8_dec_le(v_stateId_2494_, v___x_2564_);
if (v___x_2565_ == 0)
{
uint8_t v___x_2566_; uint8_t v___x_2567_;
v___x_2566_ = 16;
v___x_2567_ = lean_uint8_dec_eq(v_stateId_2494_, v___x_2566_);
if (v___x_2567_ == 0)
{
uint8_t v___x_2568_; uint8_t v___x_2569_;
v___x_2568_ = 21;
v___x_2569_ = lean_uint8_dec_le(v_stateId_2494_, v___x_2568_);
if (v___x_2569_ == 0)
{
uint8_t v___x_2570_; uint8_t v___x_2571_;
v___x_2570_ = 23;
v___x_2571_ = lean_uint8_dec_le(v_stateId_2494_, v___x_2570_);
if (v___x_2571_ == 0)
{
uint8_t v___x_2572_; uint8_t v___x_2573_;
v___x_2572_ = 24;
v___x_2573_ = lean_uint8_dec_eq(v_stateId_2494_, v___x_2572_);
if (v___x_2573_ == 0)
{
uint8_t v___x_2574_; uint8_t v___x_2575_;
v___x_2574_ = 26;
v___x_2575_ = lean_uint8_dec_le(v_stateId_2494_, v___x_2574_);
if (v___x_2575_ == 0)
{
uint8_t v___x_2576_; uint8_t v___x_2577_;
v___x_2576_ = 28;
v___x_2577_ = lean_uint8_dec_le(v_stateId_2494_, v___x_2576_);
if (v___x_2577_ == 0)
{
uint8_t v___x_2578_;
v___x_2578_ = 9;
v___y_2534_ = v___x_2578_;
goto v___jp_2533_;
}
else
{
v___y_2534_ = v___x_2560_;
goto v___jp_2533_;
}
}
else
{
uint8_t v___x_2579_;
v___x_2579_ = 7;
v___y_2534_ = v___x_2579_;
goto v___jp_2533_;
}
}
else
{
uint8_t v___x_2580_;
v___x_2580_ = 5;
v___y_2534_ = v___x_2580_;
goto v___jp_2533_;
}
}
else
{
uint8_t v___x_2581_;
v___x_2581_ = 6;
v___y_2534_ = v___x_2581_;
goto v___jp_2533_;
}
}
else
{
uint8_t v___x_2582_;
v___x_2582_ = 2;
v___y_2534_ = v___x_2582_;
goto v___jp_2533_;
}
}
else
{
uint8_t v___x_2583_;
v___x_2583_ = 1;
v___y_2534_ = v___x_2583_;
goto v___jp_2533_;
}
}
else
{
uint8_t v___x_2584_;
v___x_2584_ = 0;
v___y_2534_ = v___x_2584_;
goto v___jp_2533_;
}
}
else
{
uint8_t v___x_2585_;
v___x_2585_ = 4;
v___y_2534_ = v___x_2585_;
goto v___jp_2533_;
}
}
else
{
uint8_t v___x_2586_;
v___x_2586_ = 3;
v___y_2534_ = v___x_2586_;
goto v___jp_2533_;
}
v___jp_2495_:
{
uint8_t v___x_2497_; uint8_t v___x_2498_;
v___x_2497_ = 11;
v___x_2498_ = lean_uint8_dec_eq(v_stateId_2494_, v___x_2497_);
if (v___x_2498_ == 0)
{
uint8_t v___x_2499_; uint8_t v___x_2500_;
v___x_2499_ = 12;
v___x_2500_ = lean_uint8_dec_eq(v_stateId_2494_, v___x_2499_);
if (v___x_2500_ == 0)
{
uint8_t v___x_2501_; uint8_t v___x_2502_;
v___x_2501_ = 24;
v___x_2502_ = lean_uint8_dec_eq(v_stateId_2494_, v___x_2501_);
if (v___x_2502_ == 0)
{
uint8_t v___x_2503_; uint8_t v___x_2504_;
v___x_2503_ = 25;
v___x_2504_ = lean_uint8_dec_eq(v_stateId_2494_, v___x_2503_);
if (v___x_2504_ == 0)
{
uint8_t v___x_2505_; uint8_t v___x_2506_;
v___x_2505_ = 26;
v___x_2506_ = lean_uint8_dec_eq(v_stateId_2494_, v___x_2505_);
if (v___x_2506_ == 0)
{
uint8_t v___x_2507_; uint8_t v___x_2508_;
v___x_2507_ = 16;
v___x_2508_ = lean_uint8_dec_eq(v_stateId_2494_, v___x_2507_);
if (v___x_2508_ == 0)
{
uint8_t v___x_2509_; uint8_t v___x_2510_;
v___x_2509_ = 17;
v___x_2510_ = lean_uint8_dec_eq(v_stateId_2494_, v___x_2509_);
if (v___x_2510_ == 0)
{
uint8_t v___x_2511_; uint8_t v___x_2512_;
v___x_2511_ = 20;
v___x_2512_ = lean_uint8_dec_eq(v_stateId_2494_, v___x_2511_);
if (v___x_2512_ == 0)
{
uint8_t v___x_2513_; uint8_t v___x_2514_;
v___x_2513_ = 22;
v___x_2514_ = lean_uint8_dec_eq(v_stateId_2494_, v___x_2513_);
if (v___x_2514_ == 0)
{
return v___y_2496_;
}
else
{
uint32_t v___x_2515_; uint32_t v___x_2516_;
v___x_2515_ = 24;
v___x_2516_ = lean_uint32_lor(v___y_2496_, v___x_2515_);
return v___x_2516_;
}
}
else
{
uint32_t v___x_2517_; uint32_t v___x_2518_;
v___x_2517_ = 24;
v___x_2518_ = lean_uint32_lor(v___y_2496_, v___x_2517_);
return v___x_2518_;
}
}
else
{
uint32_t v___x_2519_; uint32_t v___x_2520_;
v___x_2519_ = 24;
v___x_2520_ = lean_uint32_lor(v___y_2496_, v___x_2519_);
return v___x_2520_;
}
}
else
{
uint32_t v___x_2521_; uint32_t v___x_2522_;
v___x_2521_ = 24;
v___x_2522_ = lean_uint32_lor(v___y_2496_, v___x_2521_);
return v___x_2522_;
}
}
else
{
uint32_t v___x_2523_; uint32_t v___x_2524_;
v___x_2523_ = 8;
v___x_2524_ = lean_uint32_lor(v___y_2496_, v___x_2523_);
return v___x_2524_;
}
}
else
{
uint32_t v___x_2525_; uint32_t v___x_2526_;
v___x_2525_ = 8;
v___x_2526_ = lean_uint32_lor(v___y_2496_, v___x_2525_);
return v___x_2526_;
}
}
else
{
uint32_t v___x_2527_; uint32_t v___x_2528_;
v___x_2527_ = 8;
v___x_2528_ = lean_uint32_lor(v___y_2496_, v___x_2527_);
return v___x_2528_;
}
}
else
{
uint32_t v___x_2529_; uint32_t v___x_2530_;
v___x_2529_ = 8;
v___x_2530_ = lean_uint32_lor(v___y_2496_, v___x_2529_);
return v___x_2530_;
}
}
else
{
uint32_t v___x_2531_; uint32_t v___x_2532_;
v___x_2531_ = 8;
v___x_2532_ = lean_uint32_lor(v___y_2496_, v___x_2531_);
return v___x_2532_;
}
}
v___jp_2533_:
{
uint8_t v___x_2535_; uint8_t v___x_2536_;
v___x_2535_ = 0;
v___x_2536_ = lean_uint8_dec_eq(v___y_2534_, v___x_2535_);
if (v___x_2536_ == 0)
{
uint8_t v___x_2537_; uint8_t v___x_2538_;
v___x_2537_ = 1;
v___x_2538_ = lean_uint8_dec_eq(v___y_2534_, v___x_2537_);
if (v___x_2538_ == 0)
{
uint8_t v___x_2539_; uint8_t v___x_2540_;
v___x_2539_ = 2;
v___x_2540_ = lean_uint8_dec_eq(v___y_2534_, v___x_2539_);
if (v___x_2540_ == 0)
{
uint8_t v___x_2541_; uint8_t v___x_2542_;
v___x_2541_ = 3;
v___x_2542_ = lean_uint8_dec_eq(v___y_2534_, v___x_2541_);
if (v___x_2542_ == 0)
{
uint8_t v___x_2543_; uint8_t v___x_2544_;
v___x_2543_ = 4;
v___x_2544_ = lean_uint8_dec_eq(v___y_2534_, v___x_2543_);
if (v___x_2544_ == 0)
{
uint8_t v___x_2545_; uint8_t v___x_2546_;
v___x_2545_ = 7;
v___x_2546_ = lean_uint8_dec_eq(v___y_2534_, v___x_2545_);
if (v___x_2546_ == 0)
{
uint8_t v___x_2547_; uint8_t v___x_2548_;
v___x_2547_ = 6;
v___x_2548_ = lean_uint8_dec_eq(v___y_2534_, v___x_2547_);
if (v___x_2548_ == 0)
{
uint8_t v___x_2549_; uint8_t v___x_2550_;
v___x_2549_ = 8;
v___x_2550_ = lean_uint8_dec_eq(v___y_2534_, v___x_2549_);
if (v___x_2550_ == 0)
{
uint32_t v___x_2551_;
v___x_2551_ = 0;
v___y_2496_ = v___x_2551_;
goto v___jp_2495_;
}
else
{
uint32_t v___x_2552_;
v___x_2552_ = 128;
v___y_2496_ = v___x_2552_;
goto v___jp_2495_;
}
}
else
{
uint32_t v___x_2553_;
v___x_2553_ = 128;
v___y_2496_ = v___x_2553_;
goto v___jp_2495_;
}
}
else
{
uint32_t v___x_2554_;
v___x_2554_ = 194;
v___y_2496_ = v___x_2554_;
goto v___jp_2495_;
}
}
else
{
uint32_t v___x_2555_;
v___x_2555_ = 1;
v___y_2496_ = v___x_2555_;
goto v___jp_2495_;
}
}
else
{
uint32_t v___x_2556_;
v___x_2556_ = 1;
v___y_2496_ = v___x_2556_;
goto v___jp_2495_;
}
}
else
{
uint32_t v___x_2557_;
v___x_2557_ = 166;
v___y_2496_ = v___x_2557_;
goto v___jp_2495_;
}
}
else
{
uint32_t v___x_2558_;
v___x_2558_ = 36;
v___y_2496_ = v___x_2558_;
goto v___jp_2495_;
}
}
else
{
uint32_t v___x_2559_;
v___x_2559_ = 4;
v___y_2496_ = v___x_2559_;
goto v___jp_2495_;
}
}
}
}

LEAN_EXPORT uint8_t orb_mission_inbox_section(uint8_t v_stateId_2591_){
_start:
{
uint8_t v___y_2593_; uint8_t v___x_2627_; uint8_t v___x_2628_;
v___x_2627_ = 8;
v___x_2628_ = lean_uint8_dec_le(v_stateId_2591_, v___x_2627_);
if (v___x_2628_ == 0)
{
uint8_t v___x_2629_; uint8_t v___x_2630_;
v___x_2629_ = 10;
v___x_2630_ = lean_uint8_dec_le(v_stateId_2591_, v___x_2629_);
if (v___x_2630_ == 0)
{
uint8_t v___x_2631_; uint8_t v___x_2632_;
v___x_2631_ = 15;
v___x_2632_ = lean_uint8_dec_le(v_stateId_2591_, v___x_2631_);
if (v___x_2632_ == 0)
{
uint8_t v___x_2633_; uint8_t v___x_2634_;
v___x_2633_ = 16;
v___x_2634_ = lean_uint8_dec_eq(v_stateId_2591_, v___x_2633_);
if (v___x_2634_ == 0)
{
uint8_t v___x_2635_; uint8_t v___x_2636_;
v___x_2635_ = 21;
v___x_2636_ = lean_uint8_dec_le(v_stateId_2591_, v___x_2635_);
if (v___x_2636_ == 0)
{
uint8_t v___x_2637_; uint8_t v___x_2638_;
v___x_2637_ = 23;
v___x_2638_ = lean_uint8_dec_le(v_stateId_2591_, v___x_2637_);
if (v___x_2638_ == 0)
{
uint8_t v___x_2639_; uint8_t v___x_2640_;
v___x_2639_ = 24;
v___x_2640_ = lean_uint8_dec_eq(v_stateId_2591_, v___x_2639_);
if (v___x_2640_ == 0)
{
uint8_t v___x_2641_; uint8_t v___x_2642_;
v___x_2641_ = 26;
v___x_2642_ = lean_uint8_dec_le(v_stateId_2591_, v___x_2641_);
if (v___x_2642_ == 0)
{
uint8_t v___x_2643_; uint8_t v___x_2644_;
v___x_2643_ = 28;
v___x_2644_ = lean_uint8_dec_le(v_stateId_2591_, v___x_2643_);
if (v___x_2644_ == 0)
{
uint8_t v___x_2645_;
v___x_2645_ = 9;
v___y_2593_ = v___x_2645_;
goto v___jp_2592_;
}
else
{
v___y_2593_ = v___x_2627_;
goto v___jp_2592_;
}
}
else
{
uint8_t v___x_2646_;
v___x_2646_ = 7;
v___y_2593_ = v___x_2646_;
goto v___jp_2592_;
}
}
else
{
uint8_t v___x_2647_;
v___x_2647_ = 5;
v___y_2593_ = v___x_2647_;
goto v___jp_2592_;
}
}
else
{
uint8_t v___x_2648_;
v___x_2648_ = 6;
v___y_2593_ = v___x_2648_;
goto v___jp_2592_;
}
}
else
{
uint8_t v___x_2649_;
v___x_2649_ = 2;
v___y_2593_ = v___x_2649_;
goto v___jp_2592_;
}
}
else
{
uint8_t v___x_2650_;
v___x_2650_ = 1;
v___y_2593_ = v___x_2650_;
goto v___jp_2592_;
}
}
else
{
uint8_t v___x_2651_;
v___x_2651_ = 0;
v___y_2593_ = v___x_2651_;
goto v___jp_2592_;
}
}
else
{
uint8_t v___x_2652_;
v___x_2652_ = 4;
v___y_2593_ = v___x_2652_;
goto v___jp_2592_;
}
}
else
{
uint8_t v___x_2653_;
v___x_2653_ = 3;
v___y_2593_ = v___x_2653_;
goto v___jp_2592_;
}
v___jp_2592_:
{
uint8_t v___x_2594_; uint8_t v___x_2595_;
v___x_2594_ = 3;
v___x_2595_ = lean_uint8_dec_eq(v___y_2593_, v___x_2594_);
if (v___x_2595_ == 0)
{
uint8_t v___x_2596_; uint8_t v___x_2597_;
v___x_2596_ = 4;
v___x_2597_ = lean_uint8_dec_eq(v___y_2593_, v___x_2596_);
if (v___x_2597_ == 0)
{
uint8_t v___x_2598_; uint8_t v___x_2599_;
v___x_2598_ = 2;
v___x_2599_ = lean_uint8_dec_le(v___y_2593_, v___x_2598_);
if (v___x_2599_ == 0)
{
uint8_t v___x_2600_; uint8_t v___x_2601_;
v___x_2600_ = 7;
v___x_2601_ = lean_uint8_dec_eq(v___y_2593_, v___x_2600_);
if (v___x_2601_ == 0)
{
uint8_t v___x_2602_; uint8_t v___x_2603_;
v___x_2602_ = 5;
v___x_2603_ = lean_uint8_dec_eq(v___y_2593_, v___x_2602_);
if (v___x_2603_ == 0)
{
uint8_t v___x_2604_; uint8_t v___x_2605_;
v___x_2604_ = 6;
v___x_2605_ = lean_uint8_dec_eq(v___y_2593_, v___x_2604_);
if (v___x_2605_ == 0)
{
return v___x_2594_;
}
else
{
uint8_t v___x_2606_; uint8_t v___x_2607_;
v___x_2606_ = 11;
v___x_2607_ = lean_uint8_dec_eq(v_stateId_2591_, v___x_2606_);
if (v___x_2607_ == 0)
{
uint8_t v___x_2608_; uint8_t v___x_2609_;
v___x_2608_ = 12;
v___x_2609_ = lean_uint8_dec_eq(v_stateId_2591_, v___x_2608_);
if (v___x_2609_ == 0)
{
uint8_t v___x_2610_; uint8_t v___x_2611_;
v___x_2610_ = 16;
v___x_2611_ = lean_uint8_dec_eq(v_stateId_2591_, v___x_2610_);
if (v___x_2611_ == 0)
{
uint8_t v___x_2612_; uint8_t v___x_2613_;
v___x_2612_ = 17;
v___x_2613_ = lean_uint8_dec_eq(v_stateId_2591_, v___x_2612_);
if (v___x_2613_ == 0)
{
uint8_t v___x_2614_; uint8_t v___x_2615_;
v___x_2614_ = 20;
v___x_2615_ = lean_uint8_dec_eq(v_stateId_2591_, v___x_2614_);
if (v___x_2615_ == 0)
{
uint8_t v___x_2616_; uint8_t v___x_2617_;
v___x_2616_ = 22;
v___x_2617_ = lean_uint8_dec_eq(v_stateId_2591_, v___x_2616_);
if (v___x_2617_ == 0)
{
uint8_t v___x_2618_; uint8_t v___x_2619_;
v___x_2618_ = 24;
v___x_2619_ = lean_uint8_dec_eq(v_stateId_2591_, v___x_2618_);
if (v___x_2619_ == 0)
{
uint8_t v___x_2620_; uint8_t v___x_2621_;
v___x_2620_ = 25;
v___x_2621_ = lean_uint8_dec_eq(v_stateId_2591_, v___x_2620_);
if (v___x_2621_ == 0)
{
uint8_t v___x_2622_; uint8_t v___x_2623_;
v___x_2622_ = 26;
v___x_2623_ = lean_uint8_dec_eq(v_stateId_2591_, v___x_2622_);
if (v___x_2623_ == 0)
{
return v___x_2594_;
}
else
{
return v___x_2598_;
}
}
else
{
return v___x_2598_;
}
}
else
{
return v___x_2598_;
}
}
else
{
return v___x_2598_;
}
}
else
{
return v___x_2598_;
}
}
else
{
return v___x_2598_;
}
}
else
{
return v___x_2598_;
}
}
else
{
return v___x_2598_;
}
}
else
{
return v___x_2598_;
}
}
}
else
{
return v___x_2598_;
}
}
else
{
return v___x_2598_;
}
}
else
{
uint8_t v___x_2624_;
v___x_2624_ = 1;
return v___x_2624_;
}
}
else
{
uint8_t v___x_2625_;
v___x_2625_ = 0;
return v___x_2625_;
}
}
else
{
uint8_t v___x_2626_;
v___x_2626_ = 0;
return v___x_2626_;
}
}
}
}

LEAN_EXPORT uint32_t orb_connection_issue_classify(uint8_t v_isUnreachable_2658_, uint8_t v_isUsingDefault_2659_, uint8_t v_isPrivateAddr_2660_, uint8_t v_defaultReachable_2661_, uint8_t v_hasExternalProxy_2662_){
_start:
{
uint32_t v___y_2664_; uint32_t v___y_2665_; uint32_t v___y_2666_; uint32_t v___y_2667_; uint8_t v___x_2675_; uint32_t v___y_2677_; uint32_t v___y_2678_; uint8_t v___y_2686_; uint32_t v___y_2687_; uint32_t v___y_2688_; uint32_t v___y_2699_; uint8_t v___y_2700_; uint8_t v___x_2702_;
v___x_2675_ = 1;
v___x_2702_ = lean_uint8_dec_eq(v_isUnreachable_2658_, v___x_2675_);
if (v___x_2702_ == 0)
{
uint32_t v___x_2703_;
v___x_2703_ = 0;
return v___x_2703_;
}
else
{
uint8_t v___x_2704_; uint8_t v___x_2705_; uint8_t v___x_2706_; uint32_t v___y_2708_;
v___x_2704_ = 0;
v___x_2705_ = 0;
v___x_2706_ = lean_uint8_dec_eq(v_isUsingDefault_2659_, v___x_2705_);
if (v___x_2706_ == 0)
{
uint32_t v___x_2711_;
v___x_2711_ = 0;
v___y_2708_ = v___x_2711_;
goto v___jp_2707_;
}
else
{
uint32_t v___x_2712_;
v___x_2712_ = 256;
v___y_2708_ = v___x_2712_;
goto v___jp_2707_;
}
v___jp_2707_:
{
if (v___x_2706_ == 0)
{
v___y_2699_ = v___y_2708_;
v___y_2700_ = v___x_2704_;
goto v___jp_2698_;
}
else
{
uint8_t v___x_2709_;
v___x_2709_ = lean_uint8_dec_eq(v_isPrivateAddr_2660_, v___x_2675_);
if (v___x_2709_ == 0)
{
v___y_2699_ = v___y_2708_;
v___y_2700_ = v___x_2709_;
goto v___jp_2698_;
}
else
{
uint32_t v___x_2710_;
v___x_2710_ = 16777216;
v___y_2686_ = v___x_2709_;
v___y_2687_ = v___y_2708_;
v___y_2688_ = v___x_2710_;
goto v___jp_2685_;
}
}
}
}
v___jp_2663_:
{
uint32_t v___x_2668_; uint32_t v___x_2669_; uint32_t v___x_2670_; uint32_t v___x_2671_; uint32_t v___x_2672_; uint32_t v___x_2673_; uint32_t v___x_2674_;
v___x_2668_ = 1;
v___x_2669_ = lean_uint32_lor(v___x_2668_, v___y_2666_);
v___x_2670_ = lean_uint32_lor(v___x_2669_, v___y_2665_);
v___x_2671_ = lean_uint32_lor(v___x_2670_, v___y_2664_);
v___x_2672_ = 28;
v___x_2673_ = lean_uint32_shift_left(v___y_2667_, v___x_2672_);
v___x_2674_ = lean_uint32_lor(v___x_2671_, v___x_2673_);
return v___x_2674_;
}
v___jp_2676_:
{
uint32_t v___x_2679_; uint8_t v___x_2680_;
v___x_2679_ = 0;
v___x_2680_ = lean_uint8_dec_eq(v_isPrivateAddr_2660_, v___x_2675_);
if (v___x_2680_ == 0)
{
uint8_t v___x_2681_;
v___x_2681_ = lean_uint8_dec_eq(v_isUsingDefault_2659_, v___x_2675_);
if (v___x_2681_ == 0)
{
uint32_t v___x_2682_;
v___x_2682_ = 5;
v___y_2664_ = v___y_2677_;
v___y_2665_ = v___x_2679_;
v___y_2666_ = v___y_2678_;
v___y_2667_ = v___x_2682_;
goto v___jp_2663_;
}
else
{
uint32_t v___x_2683_;
v___x_2683_ = 4;
v___y_2664_ = v___y_2677_;
v___y_2665_ = v___x_2679_;
v___y_2666_ = v___y_2678_;
v___y_2667_ = v___x_2683_;
goto v___jp_2663_;
}
}
else
{
uint32_t v___x_2684_;
v___x_2684_ = 3;
v___y_2664_ = v___y_2677_;
v___y_2665_ = v___x_2679_;
v___y_2666_ = v___y_2678_;
v___y_2667_ = v___x_2684_;
goto v___jp_2663_;
}
}
v___jp_2685_:
{
uint8_t v___x_2689_;
v___x_2689_ = lean_uint8_dec_eq(v_hasExternalProxy_2662_, v___x_2675_);
if (v___x_2689_ == 0)
{
if (v___y_2686_ == 0)
{
v___y_2677_ = v___y_2688_;
v___y_2678_ = v___y_2687_;
goto v___jp_2676_;
}
else
{
uint8_t v___x_2690_;
v___x_2690_ = lean_uint8_dec_eq(v_defaultReachable_2661_, v___x_2675_);
if (v___x_2690_ == 0)
{
v___y_2677_ = v___y_2688_;
v___y_2678_ = v___y_2687_;
goto v___jp_2676_;
}
else
{
uint32_t v___x_2691_; uint32_t v___x_2692_;
v___x_2691_ = 65536;
v___x_2692_ = 2;
v___y_2664_ = v___y_2688_;
v___y_2665_ = v___x_2691_;
v___y_2666_ = v___y_2687_;
v___y_2667_ = v___x_2692_;
goto v___jp_2663_;
}
}
}
else
{
uint32_t v___x_2693_; uint32_t v___x_2694_; uint32_t v___x_2695_; uint32_t v___x_2696_; uint32_t v___x_2697_;
v___x_2693_ = 1;
v___x_2694_ = lean_uint32_lor(v___x_2693_, v___y_2687_);
v___x_2695_ = lean_uint32_lor(v___x_2694_, v___y_2688_);
v___x_2696_ = 268435456;
v___x_2697_ = lean_uint32_lor(v___x_2695_, v___x_2696_);
return v___x_2697_;
}
}
v___jp_2698_:
{
uint32_t v___x_2701_;
v___x_2701_ = 0;
v___y_2686_ = v___y_2700_;
v___y_2687_ = v___y_2699_;
v___y_2688_ = v___x_2701_;
goto v___jp_2685_;
}
}
}

LEAN_EXPORT uint64_t orb_worked_duration_bucket(uint64_t v_seconds_2725_){
_start:
{
uint64_t v___x_2726_; uint8_t v___x_2727_;
v___x_2726_ = 60ULL;
v___x_2727_ = lean_uint64_dec_lt(v_seconds_2725_, v___x_2726_);
if (v___x_2727_ == 0)
{
uint64_t v___x_2728_; uint8_t v___x_2729_;
v___x_2728_ = 3600ULL;
v___x_2729_ = lean_uint64_dec_lt(v_seconds_2725_, v___x_2728_);
if (v___x_2729_ == 0)
{
uint64_t v___x_2730_; uint8_t v___x_2731_;
v___x_2730_ = 86400ULL;
v___x_2731_ = lean_uint64_dec_lt(v_seconds_2725_, v___x_2730_);
if (v___x_2731_ == 0)
{
uint64_t v_totalH_2732_; uint64_t v___x_2733_; uint64_t v___y_2735_; uint64_t v___x_2744_; uint64_t v___x_2745_; uint8_t v___x_2746_;
v_totalH_2732_ = lean_uint64_div(v_seconds_2725_, v___x_2728_);
v___x_2733_ = 24ULL;
v___x_2744_ = lean_uint64_div(v_totalH_2732_, v___x_2733_);
v___x_2745_ = 4294967295ULL;
v___x_2746_ = lean_uint64_dec_le(v___x_2744_, v___x_2745_);
if (v___x_2746_ == 0)
{
v___y_2735_ = v___x_2745_;
goto v___jp_2734_;
}
else
{
v___y_2735_ = v___x_2744_;
goto v___jp_2734_;
}
v___jp_2734_:
{
uint64_t v_remH_2736_; uint64_t v___x_2737_; uint64_t v___x_2738_; uint64_t v___x_2739_; uint64_t v___x_2740_; uint64_t v___x_2741_; uint64_t v___x_2742_; uint64_t v___x_2743_;
v_remH_2736_ = lean_uint64_mod(v_totalH_2732_, v___x_2733_);
v___x_2737_ = 3ULL;
v___x_2738_ = 8ULL;
v___x_2739_ = lean_uint64_shift_left(v_remH_2736_, v___x_2738_);
v___x_2740_ = lean_uint64_lor(v___x_2737_, v___x_2739_);
v___x_2741_ = 32ULL;
v___x_2742_ = lean_uint64_shift_left(v___y_2735_, v___x_2741_);
v___x_2743_ = lean_uint64_lor(v___x_2740_, v___x_2742_);
return v___x_2743_;
}
}
else
{
uint64_t v_totalM_2747_; uint64_t v_h_2748_; uint64_t v_remM_2749_; uint64_t v___x_2750_; uint64_t v___x_2751_; uint64_t v___x_2752_; uint64_t v___x_2753_; uint64_t v___x_2754_; uint64_t v___x_2755_; uint64_t v___x_2756_;
v_totalM_2747_ = lean_uint64_div(v_seconds_2725_, v___x_2726_);
v_h_2748_ = lean_uint64_div(v_totalM_2747_, v___x_2726_);
v_remM_2749_ = lean_uint64_mod(v_totalM_2747_, v___x_2726_);
v___x_2750_ = 2ULL;
v___x_2751_ = 8ULL;
v___x_2752_ = lean_uint64_shift_left(v_remM_2749_, v___x_2751_);
v___x_2753_ = lean_uint64_lor(v___x_2750_, v___x_2752_);
v___x_2754_ = 32ULL;
v___x_2755_ = lean_uint64_shift_left(v_h_2748_, v___x_2754_);
v___x_2756_ = lean_uint64_lor(v___x_2753_, v___x_2755_);
return v___x_2756_;
}
}
else
{
uint64_t v_m_2757_; uint64_t v_rem_2758_; uint64_t v___x_2759_; uint64_t v___x_2760_; uint64_t v___x_2761_; uint64_t v___x_2762_; uint64_t v___x_2763_; uint64_t v___x_2764_; uint64_t v___x_2765_;
v_m_2757_ = lean_uint64_div(v_seconds_2725_, v___x_2726_);
v_rem_2758_ = lean_uint64_mod(v_seconds_2725_, v___x_2726_);
v___x_2759_ = 1ULL;
v___x_2760_ = 8ULL;
v___x_2761_ = lean_uint64_shift_left(v_rem_2758_, v___x_2760_);
v___x_2762_ = lean_uint64_lor(v___x_2759_, v___x_2761_);
v___x_2763_ = 32ULL;
v___x_2764_ = lean_uint64_shift_left(v_m_2757_, v___x_2763_);
v___x_2765_ = lean_uint64_lor(v___x_2762_, v___x_2764_);
return v___x_2765_;
}
}
else
{
uint64_t v___x_2766_; uint64_t v___x_2767_;
v___x_2766_ = 32ULL;
v___x_2767_ = lean_uint64_shift_left(v_seconds_2725_, v___x_2766_);
return v___x_2767_;
}
}
}

LEAN_EXPORT uint32_t orb_turn_outcome_step(uint8_t v_prevOutcome_2772_, uint8_t v_prevFailed_2773_, uint8_t v_eventKind_2774_, uint8_t v_isNarration_2775_, uint8_t v_isSuccessFalse_2776_, uint8_t v_isTextNonEmpty_2777_){
_start:
{
uint8_t v___x_2778_; uint8_t v___x_2779_;
v___x_2778_ = 0;
v___x_2779_ = lean_uint8_dec_eq(v_eventKind_2774_, v___x_2778_);
if (v___x_2779_ == 0)
{
uint8_t v___x_2780_; uint32_t v___y_2782_; uint32_t v___y_2787_; uint32_t v___y_2796_; uint8_t v___x_2800_;
v___x_2780_ = 1;
v___x_2800_ = lean_uint8_dec_eq(v_eventKind_2774_, v___x_2780_);
if (v___x_2800_ == 0)
{
uint8_t v___x_2801_; uint8_t v___x_2802_;
v___x_2801_ = 2;
v___x_2802_ = lean_uint8_dec_eq(v_eventKind_2774_, v___x_2801_);
if (v___x_2802_ == 0)
{
uint8_t v___x_2803_;
v___x_2803_ = lean_uint8_dec_eq(v_prevOutcome_2772_, v___x_2780_);
if (v___x_2803_ == 0)
{
uint32_t v___x_2804_;
v___x_2804_ = 0;
v___y_2796_ = v___x_2804_;
goto v___jp_2795_;
}
else
{
uint32_t v___x_2805_;
v___x_2805_ = 1;
v___y_2796_ = v___x_2805_;
goto v___jp_2795_;
}
}
else
{
uint8_t v___x_2806_;
v___x_2806_ = lean_uint8_dec_eq(v_isNarration_2775_, v___x_2780_);
if (v___x_2806_ == 0)
{
uint8_t v___x_2807_;
v___x_2807_ = lean_uint8_dec_eq(v_isSuccessFalse_2776_, v___x_2780_);
if (v___x_2807_ == 0)
{
uint8_t v___x_2808_;
v___x_2808_ = lean_uint8_dec_eq(v_prevFailed_2773_, v___x_2778_);
if (v___x_2808_ == 0)
{
goto v___jp_2791_;
}
else
{
uint8_t v___x_2809_;
v___x_2809_ = lean_uint8_dec_eq(v_isTextNonEmpty_2777_, v___x_2780_);
if (v___x_2809_ == 0)
{
goto v___jp_2791_;
}
else
{
uint32_t v___x_2810_;
v___x_2810_ = 1;
return v___x_2810_;
}
}
}
else
{
uint32_t v___x_2811_;
v___x_2811_ = 256;
return v___x_2811_;
}
}
else
{
uint8_t v___x_2812_;
v___x_2812_ = lean_uint8_dec_eq(v_prevOutcome_2772_, v___x_2780_);
if (v___x_2812_ == 0)
{
uint32_t v___x_2813_;
v___x_2813_ = 0;
v___y_2782_ = v___x_2813_;
goto v___jp_2781_;
}
else
{
uint32_t v___x_2814_;
v___x_2814_ = 1;
v___y_2782_ = v___x_2814_;
goto v___jp_2781_;
}
}
}
}
else
{
uint32_t v___x_2815_;
v___x_2815_ = 0;
return v___x_2815_;
}
v___jp_2781_:
{
uint8_t v___x_2783_;
v___x_2783_ = lean_uint8_dec_eq(v_prevFailed_2773_, v___x_2780_);
if (v___x_2783_ == 0)
{
return v___y_2782_;
}
else
{
uint32_t v___x_2784_; uint32_t v___x_2785_;
v___x_2784_ = 256;
v___x_2785_ = lean_uint32_lor(v___y_2782_, v___x_2784_);
return v___x_2785_;
}
}
v___jp_2786_:
{
uint8_t v___x_2788_;
v___x_2788_ = lean_uint8_dec_eq(v_prevFailed_2773_, v___x_2780_);
if (v___x_2788_ == 0)
{
return v___y_2787_;
}
else
{
uint32_t v___x_2789_; uint32_t v___x_2790_;
v___x_2789_ = 256;
v___x_2790_ = lean_uint32_lor(v___y_2787_, v___x_2789_);
return v___x_2790_;
}
}
v___jp_2791_:
{
uint8_t v___x_2792_;
v___x_2792_ = lean_uint8_dec_eq(v_prevOutcome_2772_, v___x_2780_);
if (v___x_2792_ == 0)
{
uint32_t v___x_2793_;
v___x_2793_ = 0;
v___y_2787_ = v___x_2793_;
goto v___jp_2786_;
}
else
{
uint32_t v___x_2794_;
v___x_2794_ = 1;
v___y_2787_ = v___x_2794_;
goto v___jp_2786_;
}
}
v___jp_2795_:
{
uint8_t v___x_2797_;
v___x_2797_ = lean_uint8_dec_eq(v_prevFailed_2773_, v___x_2780_);
if (v___x_2797_ == 0)
{
return v___y_2796_;
}
else
{
uint32_t v___x_2798_; uint32_t v___x_2799_;
v___x_2798_ = 256;
v___x_2799_ = lean_uint32_lor(v___y_2796_, v___x_2798_);
return v___x_2799_;
}
}
}
else
{
uint32_t v___x_2816_;
v___x_2816_ = 0;
return v___x_2816_;
}
}
}

LEAN_EXPORT uint8_t orb_numeric_cell_scan(uint8_t v_nonEmpty_2831_, uint8_t v_hasLeadingDigitOrSign_2832_, uint8_t v_hasDigit_2833_, uint8_t v_allAllowedChars_2834_){
_start:
{
uint8_t v___x_2835_; uint8_t v___x_2836_;
v___x_2835_ = 1;
v___x_2836_ = lean_uint8_dec_eq(v_nonEmpty_2831_, v___x_2835_);
if (v___x_2836_ == 0)
{
uint8_t v___x_2837_;
v___x_2837_ = 0;
return v___x_2837_;
}
else
{
uint8_t v___x_2838_;
v___x_2838_ = lean_uint8_dec_eq(v_hasLeadingDigitOrSign_2832_, v___x_2835_);
if (v___x_2838_ == 0)
{
uint8_t v___x_2839_;
v___x_2839_ = 0;
return v___x_2839_;
}
else
{
uint8_t v___x_2840_;
v___x_2840_ = lean_uint8_dec_eq(v_hasDigit_2833_, v___x_2835_);
if (v___x_2840_ == 0)
{
uint8_t v___x_2841_;
v___x_2841_ = 0;
return v___x_2841_;
}
else
{
uint8_t v___x_2842_;
v___x_2842_ = lean_uint8_dec_eq(v_allAllowedChars_2834_, v___x_2835_);
if (v___x_2842_ == 0)
{
uint8_t v___x_2843_;
v___x_2843_ = 0;
return v___x_2843_;
}
else
{
return v___x_2835_;
}
}
}
}
}
}

LEAN_EXPORT uint64_t orb_file_ref_line_span(uint32_t v_startLine_2854_, uint32_t v_endLine_2855_, uint32_t v_totalLines_2856_){
_start:
{
uint32_t v___x_2857_; uint8_t v___x_2866_;
v___x_2857_ = 1;
v___x_2866_ = lean_uint32_dec_le(v___x_2857_, v_startLine_2854_);
if (v___x_2866_ == 0)
{
uint64_t v___x_2867_;
v___x_2867_ = 0ULL;
return v___x_2867_;
}
else
{
uint8_t v___x_2868_;
v___x_2868_ = lean_uint32_dec_le(v_startLine_2854_, v_endLine_2855_);
if (v___x_2868_ == 0)
{
uint64_t v___x_2869_;
v___x_2869_ = 0ULL;
return v___x_2869_;
}
else
{
uint32_t v___x_2870_; uint8_t v___x_2871_;
v___x_2870_ = 0;
v___x_2871_ = lean_uint32_dec_eq(v_totalLines_2856_, v___x_2870_);
if (v___x_2871_ == 0)
{
uint8_t v___x_2872_;
v___x_2872_ = lean_uint32_dec_le(v_endLine_2855_, v_totalLines_2856_);
if (v___x_2872_ == 0)
{
uint64_t v___x_2873_;
v___x_2873_ = 0ULL;
return v___x_2873_;
}
else
{
goto v___jp_2858_;
}
}
else
{
goto v___jp_2858_;
}
}
}
v___jp_2858_:
{
uint32_t v___x_2859_; uint32_t v_count_2860_; uint64_t v___x_2861_; uint64_t v___x_2862_; uint64_t v___x_2863_; uint64_t v___x_2864_; uint64_t v___x_2865_;
v___x_2859_ = lean_uint32_sub(v_endLine_2855_, v_startLine_2854_);
v_count_2860_ = lean_uint32_add(v___x_2859_, v___x_2857_);
v___x_2861_ = 1ULL;
v___x_2862_ = lean_uint32_to_uint64(v_count_2860_);
v___x_2863_ = 32ULL;
v___x_2864_ = lean_uint64_shift_left(v___x_2862_, v___x_2863_);
v___x_2865_ = lean_uint64_lor(v___x_2861_, v___x_2864_);
return v___x_2865_;
}
}
}

LEAN_EXPORT uint32_t orb_machine_action_admitted(uint8_t v_stateKind_2882_, uint8_t v_isBusy_2883_, uint8_t v_isMuted_2884_){
_start:
{
uint32_t v___y_2886_; uint32_t v___y_2887_; uint32_t v___y_2888_; uint32_t v___y_2889_; uint32_t v___y_2890_; uint32_t v___y_2896_; uint32_t v___y_2897_; uint32_t v___y_2898_; uint32_t v___y_2899_; uint32_t v___y_2902_; uint32_t v___y_2903_; uint32_t v___y_2904_; uint8_t v___y_2905_; uint8_t v___y_2906_; uint32_t v___y_2907_; uint32_t v___y_2910_; uint32_t v___y_2911_; uint8_t v___y_2912_; uint32_t v___y_2913_; uint32_t v___y_2919_; uint8_t v___y_2920_; uint8_t v___y_2921_; uint32_t v___y_2922_; uint32_t v___y_2926_; uint8_t v___y_2927_; uint8_t v___y_2928_; uint8_t v___y_2931_; uint32_t v___y_2932_; uint8_t v___y_2937_; uint8_t v___x_2942_; uint8_t v___x_2943_;
v___x_2942_ = 0;
v___x_2943_ = lean_uint8_dec_eq(v_isBusy_2883_, v___x_2942_);
if (v___x_2943_ == 0)
{
v___y_2937_ = v___x_2943_;
goto v___jp_2936_;
}
else
{
uint8_t v___x_2944_;
v___x_2944_ = lean_uint8_dec_eq(v_isMuted_2884_, v___x_2942_);
v___y_2937_ = v___x_2944_;
goto v___jp_2936_;
}
v___jp_2885_:
{
uint32_t v___x_2891_; uint32_t v___x_2892_; uint32_t v___x_2893_; uint32_t v___x_2894_;
v___x_2891_ = lean_uint32_lor(v___y_2889_, v___y_2888_);
v___x_2892_ = lean_uint32_lor(v___x_2891_, v___y_2886_);
v___x_2893_ = lean_uint32_lor(v___x_2892_, v___y_2887_);
v___x_2894_ = lean_uint32_lor(v___x_2893_, v___y_2890_);
return v___x_2894_;
}
v___jp_2895_:
{
uint32_t v___x_2900_;
v___x_2900_ = 0;
v___y_2886_ = v___y_2896_;
v___y_2887_ = v___y_2897_;
v___y_2888_ = v___y_2898_;
v___y_2889_ = v___y_2899_;
v___y_2890_ = v___x_2900_;
goto v___jp_2885_;
}
v___jp_2901_:
{
if (v___y_2905_ == 0)
{
v___y_2896_ = v___y_2902_;
v___y_2897_ = v___y_2907_;
v___y_2898_ = v___y_2903_;
v___y_2899_ = v___y_2904_;
goto v___jp_2895_;
}
else
{
if (v___y_2906_ == 0)
{
v___y_2896_ = v___y_2902_;
v___y_2897_ = v___y_2907_;
v___y_2898_ = v___y_2903_;
v___y_2899_ = v___y_2904_;
goto v___jp_2895_;
}
else
{
uint32_t v___x_2908_;
v___x_2908_ = 33554432;
v___y_2886_ = v___y_2902_;
v___y_2887_ = v___y_2907_;
v___y_2888_ = v___y_2903_;
v___y_2889_ = v___y_2904_;
v___y_2890_ = v___x_2908_;
goto v___jp_2885_;
}
}
}
v___jp_2909_:
{
uint8_t v___x_2914_; uint8_t v___x_2915_;
v___x_2914_ = 6;
v___x_2915_ = lean_uint8_dec_eq(v_stateKind_2882_, v___x_2914_);
if (v___x_2915_ == 0)
{
uint32_t v___x_2916_;
v___x_2916_ = 0;
v___y_2902_ = v___y_2913_;
v___y_2903_ = v___y_2910_;
v___y_2904_ = v___y_2911_;
v___y_2905_ = v___x_2915_;
v___y_2906_ = v___y_2912_;
v___y_2907_ = v___x_2916_;
goto v___jp_2901_;
}
else
{
uint32_t v___x_2917_;
v___x_2917_ = 16777216;
v___y_2902_ = v___y_2913_;
v___y_2903_ = v___y_2910_;
v___y_2904_ = v___y_2911_;
v___y_2905_ = v___x_2915_;
v___y_2906_ = v___y_2912_;
v___y_2907_ = v___x_2917_;
goto v___jp_2901_;
}
}
v___jp_2918_:
{
if (v___y_2920_ == 0)
{
uint32_t v___x_2923_;
v___x_2923_ = 0;
v___y_2910_ = v___y_2922_;
v___y_2911_ = v___y_2919_;
v___y_2912_ = v___y_2921_;
v___y_2913_ = v___x_2923_;
goto v___jp_2909_;
}
else
{
uint32_t v___x_2924_;
v___x_2924_ = 65536;
v___y_2910_ = v___y_2922_;
v___y_2911_ = v___y_2919_;
v___y_2912_ = v___y_2921_;
v___y_2913_ = v___x_2924_;
goto v___jp_2909_;
}
}
v___jp_2925_:
{
uint32_t v___x_2929_;
v___x_2929_ = 0;
v___y_2919_ = v___y_2926_;
v___y_2920_ = v___y_2927_;
v___y_2921_ = v___y_2928_;
v___y_2922_ = v___x_2929_;
goto v___jp_2918_;
}
v___jp_2930_:
{
uint8_t v___x_2933_; uint8_t v___x_2934_;
v___x_2933_ = 2;
v___x_2934_ = lean_uint8_dec_le(v_stateKind_2882_, v___x_2933_);
if (v___x_2934_ == 0)
{
v___y_2926_ = v___y_2932_;
v___y_2927_ = v___x_2934_;
v___y_2928_ = v___y_2931_;
goto v___jp_2925_;
}
else
{
if (v___y_2931_ == 0)
{
v___y_2926_ = v___y_2932_;
v___y_2927_ = v___x_2934_;
v___y_2928_ = v___y_2931_;
goto v___jp_2925_;
}
else
{
uint32_t v___x_2935_;
v___x_2935_ = 256;
v___y_2919_ = v___y_2932_;
v___y_2920_ = v___x_2934_;
v___y_2921_ = v___y_2931_;
v___y_2922_ = v___x_2935_;
goto v___jp_2918_;
}
}
}
v___jp_2936_:
{
uint8_t v___x_2938_; uint8_t v___x_2939_;
v___x_2938_ = 3;
v___x_2939_ = lean_uint8_dec_le(v_stateKind_2882_, v___x_2938_);
if (v___x_2939_ == 0)
{
uint32_t v___x_2940_;
v___x_2940_ = 0;
v___y_2931_ = v___y_2937_;
v___y_2932_ = v___x_2940_;
goto v___jp_2930_;
}
else
{
uint32_t v___x_2941_;
v___x_2941_ = 1;
v___y_2931_ = v___y_2937_;
v___y_2932_ = v___x_2941_;
goto v___jp_2930_;
}
}
}
}

LEAN_EXPORT uint32_t orb_send_flow_step(uint8_t v_isBusy_2953_, uint8_t v_hasNonEmptyText_2954_, uint8_t v_canQueue_2955_, uint8_t v_awaitingAck_2956_, uint8_t v_isDraining_2957_, uint8_t v_pendingCount_2958_, uint32_t v_httpStatus_2959_){
_start:
{
uint32_t v___y_2961_; uint32_t v___y_2962_; uint32_t v___y_2963_; uint32_t v___y_2969_; uint32_t v___y_2970_; uint32_t v___y_2973_; uint32_t v___y_2974_; uint32_t v___y_2984_; uint32_t v___y_2985_; uint32_t v___y_2992_; uint8_t v___x_2994_; uint32_t v___y_2996_; uint8_t v___x_3001_;
v___x_2994_ = 0;
v___x_3001_ = lean_uint8_dec_eq(v_hasNonEmptyText_2954_, v___x_2994_);
if (v___x_3001_ == 0)
{
uint8_t v___x_3002_;
v___x_3002_ = lean_uint8_dec_eq(v_isBusy_2953_, v___x_2994_);
if (v___x_3002_ == 0)
{
uint8_t v___x_3003_; uint8_t v___x_3004_;
v___x_3003_ = 1;
v___x_3004_ = lean_uint8_dec_eq(v_canQueue_2955_, v___x_3003_);
if (v___x_3004_ == 0)
{
uint32_t v___x_3005_;
v___x_3005_ = 0;
v___y_2996_ = v___x_3005_;
goto v___jp_2995_;
}
else
{
uint32_t v___x_3006_;
v___x_3006_ = 2;
v___y_2996_ = v___x_3006_;
goto v___jp_2995_;
}
}
else
{
uint32_t v___x_3007_;
v___x_3007_ = 1;
v___y_2996_ = v___x_3007_;
goto v___jp_2995_;
}
}
else
{
uint32_t v___x_3008_;
v___x_3008_ = 0;
v___y_2996_ = v___x_3008_;
goto v___jp_2995_;
}
v___jp_2960_:
{
uint32_t v___x_2964_; uint32_t v___x_2965_; uint32_t v___x_2966_; uint32_t v___x_2967_;
v___x_2964_ = lean_uint32_lor(v___y_2962_, v___y_2961_);
v___x_2965_ = 16;
v___x_2966_ = lean_uint32_shift_left(v___y_2963_, v___x_2965_);
v___x_2967_ = lean_uint32_lor(v___x_2964_, v___x_2966_);
return v___x_2967_;
}
v___jp_2968_:
{
uint32_t v___x_2971_;
v___x_2971_ = 2;
v___y_2961_ = v___y_2969_;
v___y_2962_ = v___y_2970_;
v___y_2963_ = v___x_2971_;
goto v___jp_2960_;
}
v___jp_2972_:
{
uint32_t v___x_2975_; uint8_t v___x_2976_;
v___x_2975_ = 404;
v___x_2976_ = lean_uint32_dec_eq(v_httpStatus_2959_, v___x_2975_);
if (v___x_2976_ == 0)
{
uint32_t v___x_2977_; uint8_t v___x_2978_;
v___x_2977_ = 405;
v___x_2978_ = lean_uint32_dec_eq(v_httpStatus_2959_, v___x_2977_);
if (v___x_2978_ == 0)
{
uint32_t v___x_2979_; uint8_t v___x_2980_;
v___x_2979_ = 409;
v___x_2980_ = lean_uint32_dec_eq(v_httpStatus_2959_, v___x_2979_);
if (v___x_2980_ == 0)
{
uint32_t v___x_2981_;
v___x_2981_ = 0;
v___y_2961_ = v___y_2973_;
v___y_2962_ = v___y_2974_;
v___y_2963_ = v___x_2981_;
goto v___jp_2960_;
}
else
{
uint32_t v___x_2982_;
v___x_2982_ = 3;
v___y_2961_ = v___y_2973_;
v___y_2962_ = v___y_2974_;
v___y_2963_ = v___x_2982_;
goto v___jp_2960_;
}
}
else
{
v___y_2969_ = v___y_2973_;
v___y_2970_ = v___y_2974_;
goto v___jp_2968_;
}
}
else
{
v___y_2969_ = v___y_2973_;
v___y_2970_ = v___y_2974_;
goto v___jp_2968_;
}
}
v___jp_2983_:
{
uint32_t v___x_2986_; uint8_t v___x_2987_;
v___x_2986_ = 200;
v___x_2987_ = lean_uint32_dec_le(v___x_2986_, v_httpStatus_2959_);
if (v___x_2987_ == 0)
{
v___y_2973_ = v___y_2985_;
v___y_2974_ = v___y_2984_;
goto v___jp_2972_;
}
else
{
uint32_t v___x_2988_; uint8_t v___x_2989_;
v___x_2988_ = 300;
v___x_2989_ = lean_uint32_dec_lt(v_httpStatus_2959_, v___x_2988_);
if (v___x_2989_ == 0)
{
v___y_2973_ = v___y_2985_;
v___y_2974_ = v___y_2984_;
goto v___jp_2972_;
}
else
{
uint32_t v___x_2990_;
v___x_2990_ = 1;
v___y_2961_ = v___y_2985_;
v___y_2962_ = v___y_2984_;
v___y_2963_ = v___x_2990_;
goto v___jp_2960_;
}
}
}
v___jp_2991_:
{
uint32_t v___x_2993_;
v___x_2993_ = 0;
v___y_2984_ = v___y_2992_;
v___y_2985_ = v___x_2993_;
goto v___jp_2983_;
}
v___jp_2995_:
{
uint8_t v___x_2997_;
v___x_2997_ = lean_uint8_dec_lt(v___x_2994_, v_pendingCount_2958_);
if (v___x_2997_ == 0)
{
v___y_2992_ = v___y_2996_;
goto v___jp_2991_;
}
else
{
uint8_t v___x_2998_;
v___x_2998_ = lean_uint8_dec_eq(v_awaitingAck_2956_, v___x_2994_);
if (v___x_2998_ == 0)
{
v___y_2992_ = v___y_2996_;
goto v___jp_2991_;
}
else
{
uint8_t v___x_2999_;
v___x_2999_ = lean_uint8_dec_eq(v_isDraining_2957_, v___x_2994_);
if (v___x_2999_ == 0)
{
v___y_2992_ = v___y_2996_;
goto v___jp_2991_;
}
else
{
uint32_t v___x_3000_;
v___x_3000_ = 256;
v___y_2984_ = v___y_2996_;
v___y_2985_ = v___x_3000_;
goto v___jp_2983_;
}
}
}
}
}
}

LEAN_EXPORT uint8_t orb_wire_validate_frame(uint32_t v_magic_3025_, uint32_t v_abiVersion_3026_, uint32_t v_schemaId_3027_, uint32_t v_expectedSchemaId_3028_, uint32_t v_totalLen_3029_, uint32_t v_payloadLen_3030_, uint32_t v_arenaOff_3031_, uint32_t v_arenaLen_3032_, uint32_t v_maxBudgetBytes_3033_, uint32_t v_outCap_3034_, uint32_t v_requiredOutBytes_3035_){
_start:
{
uint32_t v___x_3036_; uint8_t v___x_3037_;
v___x_3036_ = 1330790999;
v___x_3037_ = lean_uint32_dec_eq(v_magic_3025_, v___x_3036_);
if (v___x_3037_ == 0)
{
uint8_t v___x_3038_;
v___x_3038_ = 1;
return v___x_3038_;
}
else
{
uint32_t v___x_3039_; uint8_t v___x_3040_;
v___x_3039_ = 1;
v___x_3040_ = lean_uint32_dec_eq(v_abiVersion_3026_, v___x_3039_);
if (v___x_3040_ == 0)
{
uint8_t v___x_3041_;
v___x_3041_ = 1;
return v___x_3041_;
}
else
{
uint8_t v___x_3042_;
v___x_3042_ = lean_uint32_dec_eq(v_schemaId_3027_, v_expectedSchemaId_3028_);
if (v___x_3042_ == 0)
{
uint8_t v___x_3043_;
v___x_3043_ = 2;
return v___x_3043_;
}
else
{
uint32_t v___x_3044_; uint8_t v___x_3045_;
v___x_3044_ = 24;
v___x_3045_ = lean_uint32_dec_le(v___x_3044_, v_totalLen_3029_);
if (v___x_3045_ == 0)
{
uint8_t v___x_3046_;
v___x_3046_ = 3;
return v___x_3046_;
}
else
{
uint8_t v___x_3047_;
v___x_3047_ = lean_uint32_dec_le(v_totalLen_3029_, v_maxBudgetBytes_3033_);
if (v___x_3047_ == 0)
{
uint8_t v___x_3048_;
v___x_3048_ = 4;
return v___x_3048_;
}
else
{
uint32_t v___x_3049_; uint8_t v___x_3050_;
v___x_3049_ = lean_uint32_sub(v_totalLen_3029_, v___x_3044_);
v___x_3050_ = lean_uint32_dec_le(v_payloadLen_3030_, v___x_3049_);
if (v___x_3050_ == 0)
{
uint8_t v___x_3051_;
v___x_3051_ = 3;
return v___x_3051_;
}
else
{
uint8_t v___x_3052_;
v___x_3052_ = lean_uint32_dec_le(v_arenaOff_3031_, v_payloadLen_3030_);
if (v___x_3052_ == 0)
{
uint8_t v___x_3053_;
v___x_3053_ = 3;
return v___x_3053_;
}
else
{
uint32_t v___x_3054_; uint8_t v___x_3055_;
v___x_3054_ = lean_uint32_sub(v_payloadLen_3030_, v_arenaOff_3031_);
v___x_3055_ = lean_uint32_dec_le(v_arenaLen_3032_, v___x_3054_);
if (v___x_3055_ == 0)
{
uint8_t v___x_3056_;
v___x_3056_ = 3;
return v___x_3056_;
}
else
{
uint8_t v___x_3057_;
v___x_3057_ = lean_uint32_dec_le(v_requiredOutBytes_3035_, v_outCap_3034_);
if (v___x_3057_ == 0)
{
uint8_t v___x_3058_;
v___x_3058_ = 5;
return v___x_3058_;
}
else
{
uint8_t v___x_3059_;
v___x_3059_ = 0;
return v___x_3059_;
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

LEAN_EXPORT uint64_t orb_wire_pack_record(uint8_t v_tag_3084_, uint8_t v_flags_3085_, uint32_t v_len16_3086_, uint32_t v_payload32_3087_){
_start:
{
uint32_t v___x_3088_; uint32_t v___x_3089_; uint32_t v___x_3090_; uint32_t v___x_3091_; uint32_t v___x_3092_; uint32_t v___x_3093_; uint32_t v___x_3094_; uint32_t v___x_3095_; uint32_t v___x_3096_; uint32_t v_lo32_3097_; uint64_t v___x_3098_; uint64_t v___x_3099_; uint64_t v___x_3100_; uint64_t v___x_3101_; uint64_t v___x_3102_;
v___x_3088_ = lean_uint8_to_uint32(v_tag_3084_);
v___x_3089_ = lean_uint8_to_uint32(v_flags_3085_);
v___x_3090_ = 8;
v___x_3091_ = lean_uint32_shift_left(v___x_3089_, v___x_3090_);
v___x_3092_ = lean_uint32_lor(v___x_3088_, v___x_3091_);
v___x_3093_ = 65535;
v___x_3094_ = lean_uint32_land(v_len16_3086_, v___x_3093_);
v___x_3095_ = 16;
v___x_3096_ = lean_uint32_shift_left(v___x_3094_, v___x_3095_);
v_lo32_3097_ = lean_uint32_lor(v___x_3092_, v___x_3096_);
v___x_3098_ = lean_uint32_to_uint64(v_lo32_3097_);
v___x_3099_ = lean_uint32_to_uint64(v_payload32_3087_);
v___x_3100_ = 32ULL;
v___x_3101_ = lean_uint64_shift_left(v___x_3099_, v___x_3100_);
v___x_3102_ = lean_uint64_lor(v___x_3098_, v___x_3101_);
return v___x_3102_;
}
}

LEAN_EXPORT uint8_t orb_wire_schema_migrate_step(uint32_t v_fromSchema_3149_, uint32_t v_toSchema_3150_, uint32_t v_currentSchema_3151_, uint64_t v_payloadBytes_3152_, uint64_t v_maxBytes_3153_){
_start:
{
uint8_t v___x_3154_;
v___x_3154_ = lean_uint32_dec_eq(v_fromSchema_3149_, v_currentSchema_3151_);
if (v___x_3154_ == 0)
{
uint8_t v___x_3155_;
v___x_3155_ = 0;
return v___x_3155_;
}
else
{
uint8_t v___x_3156_;
v___x_3156_ = lean_uint32_dec_lt(v_fromSchema_3149_, v_toSchema_3150_);
if (v___x_3156_ == 0)
{
uint8_t v___x_3157_;
v___x_3157_ = 0;
return v___x_3157_;
}
else
{
uint32_t v___x_3158_; uint32_t v___x_3159_; uint8_t v___x_3160_;
v___x_3158_ = lean_uint32_sub(v_toSchema_3150_, v_fromSchema_3149_);
v___x_3159_ = 1;
v___x_3160_ = lean_uint32_dec_eq(v___x_3158_, v___x_3159_);
if (v___x_3160_ == 0)
{
uint8_t v___x_3161_;
v___x_3161_ = 0;
return v___x_3161_;
}
else
{
uint64_t v___x_3162_; uint8_t v___x_3163_;
v___x_3162_ = 0ULL;
v___x_3163_ = lean_uint64_dec_lt(v___x_3162_, v_payloadBytes_3152_);
if (v___x_3163_ == 0)
{
uint8_t v___x_3164_;
v___x_3164_ = 0;
return v___x_3164_;
}
else
{
uint8_t v___x_3165_;
v___x_3165_ = lean_uint64_dec_le(v_payloadBytes_3152_, v_maxBytes_3153_);
if (v___x_3165_ == 0)
{
uint8_t v___x_3166_;
v___x_3166_ = 0;
return v___x_3166_;
}
else
{
uint8_t v___x_3167_;
v___x_3167_ = 1;
return v___x_3167_;
}
}
}
}
}
}
}

LEAN_EXPORT uint8_t orb_effect_admissible(uint8_t v_effectKind_3180_, uint8_t v_hasValidLease_3181_, uint8_t v_sessionCreated_3182_, uint8_t v_lineageVerified_3183_, uint8_t v_isArchived_3184_, uint8_t v_idempotencyFresh_3185_, uint8_t v_accountBound_3186_, uint8_t v_accountRejected_3187_, uint8_t v_firstByteLocked_3188_, uint8_t v_grammarAllowed_3189_, uint8_t v_envScrubbed_3190_, uint8_t v_budgetOk_3191_){
_start:
{
uint8_t v___x_3192_; uint8_t v___x_3193_;
v___x_3192_ = 1;
v___x_3193_ = lean_uint8_dec_eq(v_budgetOk_3191_, v___x_3192_);
if (v___x_3193_ == 0)
{
uint8_t v___x_3194_;
v___x_3194_ = 0;
return v___x_3194_;
}
else
{
uint8_t v___x_3195_; uint8_t v___x_3196_;
v___x_3195_ = 0;
v___x_3196_ = lean_uint8_dec_eq(v_effectKind_3180_, v___x_3195_);
if (v___x_3196_ == 0)
{
uint8_t v___x_3197_;
v___x_3197_ = lean_uint8_dec_eq(v_effectKind_3180_, v___x_3192_);
if (v___x_3197_ == 0)
{
uint8_t v___x_3198_; uint8_t v___x_3199_;
v___x_3198_ = 2;
v___x_3199_ = lean_uint8_dec_eq(v_effectKind_3180_, v___x_3198_);
if (v___x_3199_ == 0)
{
uint8_t v___x_3200_; uint8_t v___x_3201_;
v___x_3200_ = 3;
v___x_3201_ = lean_uint8_dec_eq(v_effectKind_3180_, v___x_3200_);
if (v___x_3201_ == 0)
{
uint8_t v___x_3202_; uint8_t v___x_3203_;
v___x_3202_ = 4;
v___x_3203_ = lean_uint8_dec_eq(v_effectKind_3180_, v___x_3202_);
if (v___x_3203_ == 0)
{
uint8_t v___x_3204_; uint8_t v___x_3205_;
v___x_3204_ = 5;
v___x_3205_ = lean_uint8_dec_eq(v_effectKind_3180_, v___x_3204_);
if (v___x_3205_ == 0)
{
return v___x_3195_;
}
else
{
uint8_t v___x_3206_;
v___x_3206_ = lean_uint8_dec_eq(v_hasValidLease_3181_, v___x_3192_);
if (v___x_3206_ == 0)
{
return v___x_3195_;
}
else
{
uint8_t v___x_3207_;
v___x_3207_ = lean_uint8_dec_eq(v_idempotencyFresh_3185_, v___x_3192_);
if (v___x_3207_ == 0)
{
return v___x_3195_;
}
else
{
return v___x_3192_;
}
}
}
}
else
{
uint8_t v___x_3208_;
v___x_3208_ = lean_uint8_dec_eq(v_grammarAllowed_3189_, v___x_3192_);
if (v___x_3208_ == 0)
{
return v___x_3195_;
}
else
{
uint8_t v___x_3209_;
v___x_3209_ = lean_uint8_dec_eq(v_envScrubbed_3190_, v___x_3192_);
if (v___x_3209_ == 0)
{
return v___x_3195_;
}
else
{
uint8_t v___x_3210_;
v___x_3210_ = lean_uint8_dec_eq(v_hasValidLease_3181_, v___x_3192_);
if (v___x_3210_ == 0)
{
return v___x_3195_;
}
else
{
uint8_t v___x_3211_;
v___x_3211_ = lean_uint8_dec_eq(v_isArchived_3184_, v___x_3195_);
if (v___x_3211_ == 0)
{
return v___x_3195_;
}
else
{
return v___x_3192_;
}
}
}
}
}
}
else
{
uint8_t v___x_3212_;
v___x_3212_ = lean_uint8_dec_eq(v_accountBound_3186_, v___x_3192_);
if (v___x_3212_ == 0)
{
return v___x_3195_;
}
else
{
uint8_t v___x_3213_;
v___x_3213_ = lean_uint8_dec_eq(v_accountRejected_3187_, v___x_3195_);
if (v___x_3213_ == 0)
{
return v___x_3195_;
}
else
{
uint8_t v___x_3214_;
v___x_3214_ = lean_uint8_dec_eq(v_firstByteLocked_3188_, v___x_3195_);
if (v___x_3214_ == 0)
{
return v___x_3195_;
}
else
{
return v___x_3192_;
}
}
}
}
}
else
{
uint8_t v___x_3215_;
v___x_3215_ = lean_uint8_dec_eq(v_hasValidLease_3181_, v___x_3192_);
if (v___x_3215_ == 0)
{
return v___x_3195_;
}
else
{
uint8_t v___x_3216_;
v___x_3216_ = lean_uint8_dec_eq(v_sessionCreated_3182_, v___x_3192_);
if (v___x_3216_ == 0)
{
return v___x_3195_;
}
else
{
uint8_t v___x_3217_;
v___x_3217_ = lean_uint8_dec_eq(v_lineageVerified_3183_, v___x_3192_);
if (v___x_3217_ == 0)
{
return v___x_3195_;
}
else
{
uint8_t v___x_3218_;
v___x_3218_ = lean_uint8_dec_eq(v_isArchived_3184_, v___x_3195_);
if (v___x_3218_ == 0)
{
return v___x_3195_;
}
else
{
return v___x_3192_;
}
}
}
}
}
}
else
{
uint8_t v___x_3219_;
v___x_3219_ = lean_uint8_dec_eq(v_hasValidLease_3181_, v___x_3192_);
if (v___x_3219_ == 0)
{
return v___x_3195_;
}
else
{
uint8_t v___x_3220_;
v___x_3220_ = lean_uint8_dec_eq(v_isArchived_3184_, v___x_3195_);
if (v___x_3220_ == 0)
{
return v___x_3195_;
}
else
{
uint8_t v___x_3221_;
v___x_3221_ = lean_uint8_dec_eq(v_idempotencyFresh_3185_, v___x_3192_);
if (v___x_3221_ == 0)
{
return v___x_3195_;
}
else
{
return v___x_3192_;
}
}
}
}
}
else
{
return v___x_3192_;
}
}
}
}

LEAN_EXPORT uint64_t orb_provider_pool_step(uint8_t v_hasBoundAccount_3248_, uint32_t v_boundAccountId_3249_, uint32_t v_candidateAccountId_3250_, uint8_t v_isRejected_3251_, uint8_t v_firstByteSent_3252_, uint8_t v_isFailoverAttempt_3253_, uint32_t v_attempts_3254_, uint32_t v_maxAttempts_3255_, uint64_t v_nowEpoch_3256_, uint64_t v_resetEpoch_3257_){
_start:
{
uint32_t v___y_3259_; uint32_t v___y_3260_; uint32_t v___y_3267_; uint32_t v___y_3270_; uint32_t v___y_3274_; uint32_t v___y_3277_; uint8_t v___x_3279_; uint32_t v___y_3281_; uint32_t v___y_3286_; uint8_t v___y_3287_; uint8_t v___y_3291_; uint32_t v___y_3292_; uint8_t v___y_3298_; uint32_t v___y_3299_; uint32_t v___y_3300_; uint8_t v___y_3305_; uint8_t v___y_3306_; uint32_t v___y_3307_; uint8_t v___y_3313_; uint32_t v___y_3314_; uint8_t v___y_3318_; uint8_t v___y_3319_; uint32_t v___y_3320_; uint8_t v___y_3324_; uint32_t v___y_3325_; uint8_t v___y_3326_; uint32_t v___y_3330_; uint8_t v___y_3331_; uint8_t v___x_3338_; uint32_t v___y_3340_;
v___x_3279_ = 1;
v___x_3338_ = lean_uint8_dec_eq(v_firstByteSent_3252_, v___x_3279_);
if (v___x_3338_ == 0)
{
uint32_t v___x_3342_;
v___x_3342_ = 0;
v___y_3340_ = v___x_3342_;
goto v___jp_3339_;
}
else
{
uint32_t v___x_3343_;
v___x_3343_ = 65536;
v___y_3340_ = v___x_3343_;
goto v___jp_3339_;
}
v___jp_3258_:
{
uint64_t v___x_3261_; uint64_t v___x_3262_; uint64_t v___x_3263_; uint64_t v___x_3264_; uint64_t v___x_3265_;
v___x_3261_ = lean_uint32_to_uint64(v___y_3259_);
v___x_3262_ = lean_uint32_to_uint64(v___y_3260_);
v___x_3263_ = 32ULL;
v___x_3264_ = lean_uint64_shift_left(v___x_3262_, v___x_3263_);
v___x_3265_ = lean_uint64_lor(v___x_3261_, v___x_3264_);
return v___x_3265_;
}
v___jp_3266_:
{
uint32_t v___x_3268_;
v___x_3268_ = 0;
v___y_3259_ = v___y_3267_;
v___y_3260_ = v___x_3268_;
goto v___jp_3258_;
}
v___jp_3269_:
{
uint32_t v___x_3271_; uint8_t v___x_3272_;
v___x_3271_ = 0;
v___x_3272_ = lean_uint32_dec_eq(v_candidateAccountId_3250_, v___x_3271_);
if (v___x_3272_ == 0)
{
v___y_3259_ = v___y_3270_;
v___y_3260_ = v_candidateAccountId_3250_;
goto v___jp_3258_;
}
else
{
v___y_3259_ = v___y_3270_;
v___y_3260_ = v___x_3271_;
goto v___jp_3258_;
}
}
v___jp_3273_:
{
uint32_t v___x_3275_;
v___x_3275_ = 0;
v___y_3259_ = v___y_3274_;
v___y_3260_ = v___x_3275_;
goto v___jp_3258_;
}
v___jp_3276_:
{
uint32_t v___x_3278_;
v___x_3278_ = 0;
v___y_3259_ = v___y_3277_;
v___y_3260_ = v___x_3278_;
goto v___jp_3258_;
}
v___jp_3280_:
{
uint8_t v___x_3282_;
v___x_3282_ = lean_uint8_dec_eq(v_isRejected_3251_, v___x_3279_);
if (v___x_3282_ == 0)
{
v___y_3270_ = v___y_3281_;
goto v___jp_3269_;
}
else
{
uint8_t v___x_3283_;
v___x_3283_ = lean_uint64_dec_lt(v_nowEpoch_3256_, v_resetEpoch_3257_);
if (v___x_3283_ == 0)
{
v___y_3270_ = v___y_3281_;
goto v___jp_3269_;
}
else
{
uint32_t v___x_3284_;
v___x_3284_ = 0;
v___y_3259_ = v___y_3281_;
v___y_3260_ = v___x_3284_;
goto v___jp_3258_;
}
}
}
v___jp_3285_:
{
uint8_t v___x_3288_;
v___x_3288_ = lean_uint8_dec_eq(v_hasBoundAccount_3248_, v___x_3279_);
if (v___x_3288_ == 0)
{
v___y_3281_ = v___y_3286_;
goto v___jp_3280_;
}
else
{
uint8_t v___x_3289_;
v___x_3289_ = lean_uint32_dec_eq(v_candidateAccountId_3250_, v_boundAccountId_3249_);
if (v___x_3289_ == 0)
{
v___y_3274_ = v___y_3286_;
goto v___jp_3273_;
}
else
{
if (v___y_3287_ == 0)
{
v___y_3281_ = v___y_3286_;
goto v___jp_3280_;
}
else
{
v___y_3274_ = v___y_3286_;
goto v___jp_3273_;
}
}
}
}
v___jp_3290_:
{
if (v___y_3291_ == 0)
{
uint8_t v___x_3293_;
v___x_3293_ = lean_uint8_dec_eq(v_isFailoverAttempt_3253_, v___x_3279_);
if (v___x_3293_ == 0)
{
v___y_3286_ = v___y_3292_;
v___y_3287_ = v___x_3293_;
goto v___jp_3285_;
}
else
{
uint32_t v___x_3294_; uint8_t v___x_3295_;
v___x_3294_ = 1;
v___x_3295_ = lean_uint32_dec_le(v___x_3294_, v_maxAttempts_3255_);
if (v___x_3295_ == 0)
{
v___y_3277_ = v___y_3292_;
goto v___jp_3276_;
}
else
{
uint8_t v___x_3296_;
v___x_3296_ = lean_uint32_dec_lt(v_attempts_3254_, v_maxAttempts_3255_);
if (v___x_3296_ == 0)
{
v___y_3277_ = v___y_3292_;
goto v___jp_3276_;
}
else
{
v___y_3286_ = v___y_3292_;
v___y_3287_ = v___y_3291_;
goto v___jp_3285_;
}
}
}
}
else
{
v___y_3267_ = v___y_3292_;
goto v___jp_3266_;
}
}
v___jp_3297_:
{
uint32_t v___x_3301_; uint32_t v___x_3302_; uint32_t v___x_3303_;
v___x_3301_ = 256;
v___x_3302_ = lean_uint32_add(v___y_3300_, v___x_3301_);
v___x_3303_ = lean_uint32_add(v___x_3302_, v___y_3299_);
v___y_3291_ = v___y_3298_;
v___y_3292_ = v___x_3303_;
goto v___jp_3290_;
}
v___jp_3304_:
{
uint32_t v___x_3308_; uint8_t v___x_3309_;
v___x_3308_ = 0;
v___x_3309_ = lean_uint32_dec_eq(v_candidateAccountId_3250_, v___x_3308_);
if (v___x_3309_ == 0)
{
if (v___y_3306_ == 0)
{
uint32_t v___x_3310_;
v___x_3310_ = 2;
v___y_3298_ = v___y_3305_;
v___y_3299_ = v___y_3307_;
v___y_3300_ = v___x_3310_;
goto v___jp_3297_;
}
else
{
uint32_t v___x_3311_;
v___x_3311_ = 1;
v___y_3298_ = v___y_3305_;
v___y_3299_ = v___y_3307_;
v___y_3300_ = v___x_3311_;
goto v___jp_3297_;
}
}
else
{
v___y_3291_ = v___y_3305_;
v___y_3292_ = v___y_3307_;
goto v___jp_3290_;
}
}
v___jp_3312_:
{
uint32_t v___x_3315_; uint32_t v___x_3316_;
v___x_3315_ = 4;
v___x_3316_ = lean_uint32_add(v___x_3315_, v___y_3314_);
v___y_3291_ = v___y_3313_;
v___y_3292_ = v___x_3316_;
goto v___jp_3290_;
}
v___jp_3317_:
{
uint8_t v___x_3321_;
v___x_3321_ = lean_uint8_dec_eq(v_isRejected_3251_, v___x_3279_);
if (v___x_3321_ == 0)
{
v___y_3305_ = v___y_3318_;
v___y_3306_ = v___y_3319_;
v___y_3307_ = v___y_3320_;
goto v___jp_3304_;
}
else
{
uint8_t v___x_3322_;
v___x_3322_ = lean_uint64_dec_lt(v_nowEpoch_3256_, v_resetEpoch_3257_);
if (v___x_3322_ == 0)
{
v___y_3305_ = v___y_3318_;
v___y_3306_ = v___y_3319_;
v___y_3307_ = v___y_3320_;
goto v___jp_3304_;
}
else
{
v___y_3291_ = v___y_3318_;
v___y_3292_ = v___y_3320_;
goto v___jp_3290_;
}
}
}
v___jp_3323_:
{
uint8_t v___x_3327_;
v___x_3327_ = lean_uint8_dec_eq(v_hasBoundAccount_3248_, v___x_3279_);
if (v___x_3327_ == 0)
{
v___y_3318_ = v___y_3324_;
v___y_3319_ = v___x_3327_;
v___y_3320_ = v___y_3325_;
goto v___jp_3317_;
}
else
{
uint8_t v___x_3328_;
v___x_3328_ = lean_uint32_dec_eq(v_candidateAccountId_3250_, v_boundAccountId_3249_);
if (v___x_3328_ == 0)
{
v___y_3291_ = v___y_3324_;
v___y_3292_ = v___y_3325_;
goto v___jp_3290_;
}
else
{
if (v___y_3326_ == 0)
{
v___y_3318_ = v___y_3324_;
v___y_3319_ = v___x_3327_;
v___y_3320_ = v___y_3325_;
goto v___jp_3317_;
}
else
{
v___y_3291_ = v___y_3324_;
v___y_3292_ = v___y_3325_;
goto v___jp_3290_;
}
}
}
}
v___jp_3329_:
{
if (v___y_3331_ == 0)
{
uint8_t v___x_3332_;
v___x_3332_ = lean_uint8_dec_eq(v_isFailoverAttempt_3253_, v___x_3279_);
if (v___x_3332_ == 0)
{
v___y_3324_ = v___y_3331_;
v___y_3325_ = v___y_3330_;
v___y_3326_ = v___x_3332_;
goto v___jp_3323_;
}
else
{
uint32_t v___x_3333_; uint8_t v___x_3334_;
v___x_3333_ = 1;
v___x_3334_ = lean_uint32_dec_le(v___x_3333_, v_maxAttempts_3255_);
if (v___x_3334_ == 0)
{
v___y_3313_ = v___y_3331_;
v___y_3314_ = v___y_3330_;
goto v___jp_3312_;
}
else
{
uint8_t v___x_3335_;
v___x_3335_ = lean_uint32_dec_lt(v_attempts_3254_, v_maxAttempts_3255_);
if (v___x_3335_ == 0)
{
v___y_3313_ = v___y_3331_;
v___y_3314_ = v___y_3330_;
goto v___jp_3312_;
}
else
{
v___y_3324_ = v___y_3331_;
v___y_3325_ = v___y_3330_;
v___y_3326_ = v___y_3331_;
goto v___jp_3323_;
}
}
}
}
else
{
uint32_t v___x_3336_; uint32_t v___x_3337_;
v___x_3336_ = 3;
v___x_3337_ = lean_uint32_add(v___x_3336_, v___y_3330_);
v___y_3267_ = v___x_3337_;
goto v___jp_3266_;
}
}
v___jp_3339_:
{
if (v___x_3338_ == 0)
{
v___y_3330_ = v___y_3340_;
v___y_3331_ = v___x_3338_;
goto v___jp_3329_;
}
else
{
uint8_t v___x_3341_;
v___x_3341_ = lean_uint8_dec_eq(v_isFailoverAttempt_3253_, v___x_3279_);
v___y_3330_ = v___y_3340_;
v___y_3331_ = v___x_3341_;
goto v___jp_3329_;
}
}
}
}

LEAN_EXPORT uint64_t orb_route_argmin_step(uint8_t v_hasBest_3366_, uint32_t v_bestId_3367_, uint64_t v_bestScore_3368_, uint32_t v_candId_3369_, uint64_t v_candScore_3370_, uint8_t v_candAdmissible_3371_){
_start:
{
uint32_t v___y_3373_; uint32_t v___y_3374_; uint8_t v___x_3380_; uint32_t v___y_3382_; uint8_t v___y_3386_; uint8_t v___x_3391_;
v___x_3380_ = 1;
v___x_3391_ = lean_uint8_dec_eq(v_candAdmissible_3371_, v___x_3380_);
if (v___x_3391_ == 0)
{
v___y_3386_ = v___x_3391_;
goto v___jp_3385_;
}
else
{
uint8_t v___x_3392_; uint8_t v___x_3393_;
v___x_3392_ = 0;
v___x_3393_ = lean_uint8_dec_eq(v_hasBest_3366_, v___x_3392_);
if (v___x_3393_ == 0)
{
uint8_t v___x_3394_;
v___x_3394_ = lean_uint64_dec_lt(v_candScore_3370_, v_bestScore_3368_);
v___y_3386_ = v___x_3394_;
goto v___jp_3385_;
}
else
{
v___y_3386_ = v___x_3393_;
goto v___jp_3385_;
}
}
v___jp_3372_:
{
uint64_t v___x_3375_; uint64_t v___x_3376_; uint64_t v___x_3377_; uint64_t v___x_3378_; uint64_t v___x_3379_;
v___x_3375_ = lean_uint32_to_uint64(v___y_3373_);
v___x_3376_ = lean_uint32_to_uint64(v___y_3374_);
v___x_3377_ = 32ULL;
v___x_3378_ = lean_uint64_shift_left(v___x_3376_, v___x_3377_);
v___x_3379_ = lean_uint64_lor(v___x_3375_, v___x_3378_);
return v___x_3379_;
}
v___jp_3381_:
{
uint8_t v___x_3383_;
v___x_3383_ = lean_uint8_dec_eq(v_hasBest_3366_, v___x_3380_);
if (v___x_3383_ == 0)
{
uint32_t v___x_3384_;
v___x_3384_ = 0;
v___y_3373_ = v___y_3382_;
v___y_3374_ = v___x_3384_;
goto v___jp_3372_;
}
else
{
v___y_3373_ = v___y_3382_;
v___y_3374_ = v_bestId_3367_;
goto v___jp_3372_;
}
}
v___jp_3385_:
{
if (v___y_3386_ == 0)
{
uint8_t v___x_3387_;
v___x_3387_ = lean_uint8_dec_eq(v_hasBest_3366_, v___x_3380_);
if (v___x_3387_ == 0)
{
uint32_t v___x_3388_;
v___x_3388_ = 0;
v___y_3382_ = v___x_3388_;
goto v___jp_3381_;
}
else
{
uint32_t v___x_3389_;
v___x_3389_ = 1;
v___y_3382_ = v___x_3389_;
goto v___jp_3381_;
}
}
else
{
uint32_t v___x_3390_;
v___x_3390_ = 257;
v___y_3373_ = v___x_3390_;
v___y_3374_ = v_candId_3369_;
goto v___jp_3372_;
}
}
}
}

LEAN_EXPORT uint64_t orb_mission_control_step(uint8_t v_isArchived_3409_, uint32_t v_activeTrackWriters_3410_, uint8_t v_hasLease_3411_, uint8_t v_msgAlreadyDelivered_3412_, uint8_t v_isResume_3413_, uint8_t v_sessionCreated_3414_, uint8_t v_lineageVerified_3415_, uint8_t v_rolloutExists_3416_, uint8_t v_hasFallbackPrompt_3417_){
_start:
{
uint32_t v___y_3419_; uint32_t v___y_3420_; uint32_t v___y_3427_; uint8_t v___x_3429_; uint32_t v___y_3431_; uint8_t v___x_3435_; uint32_t v___y_3437_;
v___x_3429_ = 1;
v___x_3435_ = lean_uint8_dec_eq(v_isArchived_3409_, v___x_3429_);
if (v___x_3435_ == 0)
{
uint8_t v___x_3456_;
v___x_3456_ = lean_uint8_dec_eq(v_msgAlreadyDelivered_3412_, v___x_3429_);
if (v___x_3456_ == 0)
{
uint8_t v___x_3457_;
v___x_3457_ = lean_uint8_dec_eq(v_hasLease_3411_, v___x_3429_);
if (v___x_3457_ == 0)
{
goto v___jp_3450_;
}
else
{
uint32_t v___x_3458_; uint8_t v___x_3459_;
v___x_3458_ = 0;
v___x_3459_ = lean_uint32_dec_eq(v_activeTrackWriters_3410_, v___x_3458_);
if (v___x_3459_ == 0)
{
goto v___jp_3450_;
}
else
{
uint8_t v___x_3460_;
v___x_3460_ = lean_uint8_dec_eq(v_isResume_3413_, v___x_3429_);
if (v___x_3460_ == 0)
{
uint32_t v___x_3461_;
v___x_3461_ = 257;
v___y_3437_ = v___x_3461_;
goto v___jp_3436_;
}
else
{
uint8_t v___x_3462_;
v___x_3462_ = lean_uint8_dec_eq(v_sessionCreated_3414_, v___x_3429_);
if (v___x_3462_ == 0)
{
goto v___jp_3452_;
}
else
{
uint8_t v___x_3463_;
v___x_3463_ = lean_uint8_dec_eq(v_lineageVerified_3415_, v___x_3429_);
if (v___x_3463_ == 0)
{
goto v___jp_3452_;
}
else
{
uint8_t v___x_3464_;
v___x_3464_ = lean_uint8_dec_eq(v_rolloutExists_3416_, v___x_3429_);
if (v___x_3464_ == 0)
{
goto v___jp_3452_;
}
else
{
uint32_t v___x_3465_;
v___x_3465_ = 258;
v___y_3437_ = v___x_3465_;
goto v___jp_3436_;
}
}
}
}
}
}
}
else
{
uint32_t v___x_3466_;
v___x_3466_ = 4;
v___y_3437_ = v___x_3466_;
goto v___jp_3436_;
}
}
else
{
uint32_t v___x_3467_;
v___x_3467_ = 65536;
v___y_3437_ = v___x_3467_;
goto v___jp_3436_;
}
v___jp_3418_:
{
uint64_t v___x_3421_; uint64_t v___x_3422_; uint64_t v___x_3423_; uint64_t v___x_3424_; uint64_t v___x_3425_;
v___x_3421_ = lean_uint32_to_uint64(v___y_3419_);
v___x_3422_ = lean_uint32_to_uint64(v___y_3420_);
v___x_3423_ = 32ULL;
v___x_3424_ = lean_uint64_shift_left(v___x_3422_, v___x_3423_);
v___x_3425_ = lean_uint64_lor(v___x_3421_, v___x_3424_);
return v___x_3425_;
}
v___jp_3426_:
{
uint32_t v___x_3428_;
v___x_3428_ = 0;
v___y_3419_ = v___y_3427_;
v___y_3420_ = v___x_3428_;
goto v___jp_3418_;
}
v___jp_3430_:
{
uint8_t v___x_3432_;
v___x_3432_ = lean_uint8_dec_eq(v_hasFallbackPrompt_3417_, v___x_3429_);
if (v___x_3432_ == 0)
{
uint32_t v___x_3433_;
v___x_3433_ = 0;
v___y_3419_ = v___y_3431_;
v___y_3420_ = v___x_3433_;
goto v___jp_3418_;
}
else
{
uint32_t v___x_3434_;
v___x_3434_ = 1;
v___y_3419_ = v___y_3431_;
v___y_3420_ = v___x_3434_;
goto v___jp_3418_;
}
}
v___jp_3436_:
{
if (v___x_3435_ == 0)
{
uint8_t v___x_3438_;
v___x_3438_ = lean_uint8_dec_eq(v_msgAlreadyDelivered_3412_, v___x_3429_);
if (v___x_3438_ == 0)
{
uint8_t v___x_3439_;
v___x_3439_ = lean_uint8_dec_eq(v_hasLease_3411_, v___x_3429_);
if (v___x_3439_ == 0)
{
v___y_3427_ = v___y_3437_;
goto v___jp_3426_;
}
else
{
uint32_t v___x_3440_; uint8_t v___x_3441_;
v___x_3440_ = 0;
v___x_3441_ = lean_uint32_dec_eq(v_activeTrackWriters_3410_, v___x_3440_);
if (v___x_3441_ == 0)
{
v___y_3427_ = v___y_3437_;
goto v___jp_3426_;
}
else
{
uint8_t v___x_3442_;
v___x_3442_ = lean_uint8_dec_eq(v_isResume_3413_, v___x_3429_);
if (v___x_3442_ == 0)
{
uint32_t v___x_3443_;
v___x_3443_ = 1;
v___y_3419_ = v___y_3437_;
v___y_3420_ = v___x_3443_;
goto v___jp_3418_;
}
else
{
uint8_t v___x_3444_;
v___x_3444_ = lean_uint8_dec_eq(v_sessionCreated_3414_, v___x_3429_);
if (v___x_3444_ == 0)
{
v___y_3431_ = v___y_3437_;
goto v___jp_3430_;
}
else
{
uint8_t v___x_3445_;
v___x_3445_ = lean_uint8_dec_eq(v_lineageVerified_3415_, v___x_3429_);
if (v___x_3445_ == 0)
{
v___y_3431_ = v___y_3437_;
goto v___jp_3430_;
}
else
{
uint8_t v___x_3446_;
v___x_3446_ = lean_uint8_dec_eq(v_rolloutExists_3416_, v___x_3429_);
if (v___x_3446_ == 0)
{
v___y_3431_ = v___y_3437_;
goto v___jp_3430_;
}
else
{
uint32_t v___x_3447_;
v___x_3447_ = 1;
v___y_3419_ = v___y_3437_;
v___y_3420_ = v___x_3447_;
goto v___jp_3418_;
}
}
}
}
}
}
}
else
{
uint32_t v___x_3448_;
v___x_3448_ = 0;
v___y_3419_ = v___y_3437_;
v___y_3420_ = v___x_3448_;
goto v___jp_3418_;
}
}
else
{
uint32_t v___x_3449_;
v___x_3449_ = 0;
v___y_3419_ = v___y_3437_;
v___y_3420_ = v___x_3449_;
goto v___jp_3418_;
}
}
v___jp_3450_:
{
uint32_t v___x_3451_;
v___x_3451_ = 5;
v___y_3437_ = v___x_3451_;
goto v___jp_3436_;
}
v___jp_3452_:
{
uint8_t v___x_3453_;
v___x_3453_ = lean_uint8_dec_eq(v_hasFallbackPrompt_3417_, v___x_3429_);
if (v___x_3453_ == 0)
{
uint32_t v___x_3454_;
v___x_3454_ = 6;
v___y_3437_ = v___x_3454_;
goto v___jp_3436_;
}
else
{
uint32_t v___x_3455_;
v___x_3455_ = 771;
v___y_3437_ = v___x_3455_;
goto v___jp_3436_;
}
}
}
}

LEAN_EXPORT uint64_t orb_fork_home_step(uint8_t v_isForkOrSide_3538_, uint8_t v_sourceExists_3539_, uint8_t v_sourceIsSymlink_3540_, uint8_t v_sameWorkspace_3541_, uint8_t v_sameNode_3542_, uint8_t v_hasCommittedTransfer_3543_, uint8_t v_requestedOverrideHome_3544_){
_start:
{
uint32_t v___y_3546_; uint32_t v___y_3547_; uint8_t v___y_3554_; uint8_t v___y_3555_; uint32_t v___y_3556_; uint8_t v___x_3560_; uint8_t v___y_3562_; uint8_t v___x_3570_;
v___x_3560_ = 1;
v___x_3570_ = lean_uint8_dec_eq(v_sourceExists_3539_, v___x_3560_);
if (v___x_3570_ == 0)
{
v___y_3562_ = v___x_3570_;
goto v___jp_3561_;
}
else
{
uint8_t v___x_3571_; uint8_t v___x_3572_;
v___x_3571_ = 0;
v___x_3572_ = lean_uint8_dec_eq(v_sourceIsSymlink_3540_, v___x_3571_);
if (v___x_3572_ == 0)
{
v___y_3562_ = v___x_3572_;
goto v___jp_3561_;
}
else
{
uint8_t v___x_3573_;
v___x_3573_ = lean_uint8_dec_eq(v_sameWorkspace_3541_, v___x_3560_);
if (v___x_3573_ == 0)
{
v___y_3562_ = v___x_3573_;
goto v___jp_3561_;
}
else
{
uint8_t v___x_3574_;
v___x_3574_ = lean_uint8_dec_eq(v_sameNode_3542_, v___x_3560_);
v___y_3562_ = v___x_3574_;
goto v___jp_3561_;
}
}
}
v___jp_3545_:
{
uint64_t v___x_3548_; uint64_t v___x_3549_; uint64_t v___x_3550_; uint64_t v___x_3551_; uint64_t v___x_3552_;
v___x_3548_ = lean_uint32_to_uint64(v___y_3546_);
v___x_3549_ = lean_uint32_to_uint64(v___y_3547_);
v___x_3550_ = 32ULL;
v___x_3551_ = lean_uint64_shift_left(v___x_3549_, v___x_3550_);
v___x_3552_ = lean_uint64_lor(v___x_3548_, v___x_3551_);
return v___x_3552_;
}
v___jp_3553_:
{
if (v___y_3555_ == 0)
{
if (v___y_3554_ == 0)
{
uint32_t v___x_3557_;
v___x_3557_ = 78;
v___y_3546_ = v___y_3556_;
v___y_3547_ = v___x_3557_;
goto v___jp_3545_;
}
else
{
uint32_t v___x_3558_;
v___x_3558_ = 0;
v___y_3546_ = v___y_3556_;
v___y_3547_ = v___x_3558_;
goto v___jp_3545_;
}
}
else
{
uint32_t v___x_3559_;
v___x_3559_ = 0;
v___y_3546_ = v___y_3556_;
v___y_3547_ = v___x_3559_;
goto v___jp_3545_;
}
}
v___jp_3561_:
{
uint8_t v___x_3563_; uint8_t v___x_3564_;
v___x_3563_ = 0;
v___x_3564_ = lean_uint8_dec_eq(v_isForkOrSide_3538_, v___x_3563_);
if (v___x_3564_ == 0)
{
if (v___y_3562_ == 0)
{
uint32_t v___x_3565_;
v___x_3565_ = 131072;
v___y_3554_ = v___y_3562_;
v___y_3555_ = v___x_3564_;
v___y_3556_ = v___x_3565_;
goto v___jp_3553_;
}
else
{
uint8_t v___x_3566_;
v___x_3566_ = lean_uint8_dec_eq(v_hasCommittedTransfer_3543_, v___x_3560_);
if (v___x_3566_ == 0)
{
uint32_t v___x_3567_;
v___x_3567_ = 131842;
v___y_3554_ = v___y_3562_;
v___y_3555_ = v___x_3564_;
v___y_3556_ = v___x_3567_;
goto v___jp_3553_;
}
else
{
uint32_t v___x_3568_;
v___x_3568_ = 131843;
v___y_3554_ = v___y_3562_;
v___y_3555_ = v___x_3564_;
v___y_3556_ = v___x_3568_;
goto v___jp_3553_;
}
}
}
else
{
uint32_t v___x_3569_;
v___x_3569_ = 131329;
v___y_3554_ = v___y_3562_;
v___y_3555_ = v___x_3564_;
v___y_3556_ = v___x_3569_;
goto v___jp_3553_;
}
}
}
}

LEAN_EXPORT uint64_t orb_privd_command_step(uint8_t v_leaseValid_3591_, uint8_t v_grantScope_3592_, uint8_t v_commandClass_3593_, uint8_t v_unitMatchesAllowed_3594_, uint8_t v_hasShellMetacharOrFlagBypass_3595_, uint8_t v_hasPathTraversalOrSymlink_3596_, uint8_t v_hasUnsafeEnvVar_3597_, uint8_t v_requireForceCmd_3598_){
_start:
{
uint32_t v___y_3600_; uint32_t v___y_3601_; uint32_t v___y_3608_; uint8_t v___x_3617_; uint8_t v___x_3618_;
v___x_3617_ = 1;
v___x_3618_ = lean_uint8_dec_eq(v_leaseValid_3591_, v___x_3617_);
if (v___x_3618_ == 0)
{
goto v___jp_3613_;
}
else
{
uint8_t v___x_3619_; uint8_t v___x_3620_;
v___x_3619_ = 0;
v___x_3620_ = lean_uint8_dec_eq(v_hasShellMetacharOrFlagBypass_3595_, v___x_3619_);
if (v___x_3620_ == 0)
{
goto v___jp_3613_;
}
else
{
uint8_t v___x_3621_;
v___x_3621_ = lean_uint8_dec_eq(v_hasPathTraversalOrSymlink_3596_, v___x_3619_);
if (v___x_3621_ == 0)
{
goto v___jp_3613_;
}
else
{
uint8_t v___x_3622_;
v___x_3622_ = lean_uint8_dec_eq(v_hasUnsafeEnvVar_3597_, v___x_3619_);
if (v___x_3622_ == 0)
{
goto v___jp_3613_;
}
else
{
uint8_t v___x_3623_; uint8_t v___x_3635_;
v___x_3623_ = 2;
v___x_3635_ = lean_uint8_dec_le(v_grantScope_3592_, v___x_3623_);
if (v___x_3635_ == 0)
{
uint32_t v___x_3636_;
v___x_3636_ = 1536;
v___y_3608_ = v___x_3636_;
goto v___jp_3607_;
}
else
{
uint8_t v___x_3637_;
v___x_3637_ = lean_uint8_dec_eq(v_commandClass_3593_, v___x_3617_);
if (v___x_3637_ == 0)
{
uint8_t v___x_3638_;
v___x_3638_ = lean_uint8_dec_eq(v_commandClass_3593_, v___x_3623_);
if (v___x_3638_ == 0)
{
goto v___jp_3630_;
}
else
{
uint8_t v___x_3639_;
v___x_3639_ = lean_uint8_dec_le(v___x_3617_, v_grantScope_3592_);
if (v___x_3639_ == 0)
{
goto v___jp_3630_;
}
else
{
uint8_t v___x_3640_;
v___x_3640_ = lean_uint8_dec_eq(v_unitMatchesAllowed_3594_, v___x_3617_);
if (v___x_3640_ == 0)
{
goto v___jp_3630_;
}
else
{
uint32_t v___x_3641_;
v___x_3641_ = 1794;
v___y_3608_ = v___x_3641_;
goto v___jp_3607_;
}
}
}
}
else
{
uint32_t v___x_3642_;
v___x_3642_ = 1793;
v___y_3608_ = v___x_3642_;
goto v___jp_3607_;
}
}
v___jp_3624_:
{
uint8_t v___x_3625_; uint8_t v___x_3626_;
v___x_3625_ = 4;
v___x_3626_ = lean_uint8_dec_eq(v_commandClass_3593_, v___x_3625_);
if (v___x_3626_ == 0)
{
goto v___jp_3615_;
}
else
{
uint8_t v___x_3627_;
v___x_3627_ = lean_uint8_dec_eq(v_grantScope_3592_, v___x_3623_);
if (v___x_3627_ == 0)
{
goto v___jp_3615_;
}
else
{
uint8_t v___x_3628_;
v___x_3628_ = lean_uint8_dec_eq(v_requireForceCmd_3598_, v___x_3619_);
if (v___x_3628_ == 0)
{
goto v___jp_3615_;
}
else
{
uint32_t v___x_3629_;
v___x_3629_ = 1795;
v___y_3608_ = v___x_3629_;
goto v___jp_3607_;
}
}
}
}
v___jp_3630_:
{
uint8_t v___x_3631_; uint8_t v___x_3632_;
v___x_3631_ = 3;
v___x_3632_ = lean_uint8_dec_eq(v_commandClass_3593_, v___x_3631_);
if (v___x_3632_ == 0)
{
goto v___jp_3624_;
}
else
{
uint8_t v___x_3633_;
v___x_3633_ = lean_uint8_dec_le(v___x_3617_, v_grantScope_3592_);
if (v___x_3633_ == 0)
{
goto v___jp_3624_;
}
else
{
uint32_t v___x_3634_;
v___x_3634_ = 1794;
v___y_3608_ = v___x_3634_;
goto v___jp_3607_;
}
}
}
}
}
}
}
v___jp_3599_:
{
uint64_t v___x_3602_; uint64_t v___x_3603_; uint64_t v___x_3604_; uint64_t v___x_3605_; uint64_t v___x_3606_;
v___x_3602_ = lean_uint32_to_uint64(v___y_3600_);
v___x_3603_ = lean_uint32_to_uint64(v___y_3601_);
v___x_3604_ = 32ULL;
v___x_3605_ = lean_uint64_shift_left(v___x_3603_, v___x_3604_);
v___x_3606_ = lean_uint64_lor(v___x_3602_, v___x_3605_);
return v___x_3606_;
}
v___jp_3607_:
{
uint32_t v___x_3609_; uint8_t v___x_3610_;
v___x_3609_ = 1536;
v___x_3610_ = lean_uint32_dec_eq(v___y_3608_, v___x_3609_);
if (v___x_3610_ == 0)
{
uint32_t v___x_3611_;
v___x_3611_ = 0;
v___y_3600_ = v___y_3608_;
v___y_3601_ = v___x_3611_;
goto v___jp_3599_;
}
else
{
uint32_t v___x_3612_;
v___x_3612_ = 126;
v___y_3600_ = v___y_3608_;
v___y_3601_ = v___x_3612_;
goto v___jp_3599_;
}
}
v___jp_3613_:
{
uint32_t v___x_3614_;
v___x_3614_ = 1536;
v___y_3608_ = v___x_3614_;
goto v___jp_3607_;
}
v___jp_3615_:
{
uint32_t v___x_3616_;
v___x_3616_ = 1536;
v___y_3608_ = v___x_3616_;
goto v___jp_3607_;
}
}
}

LEAN_EXPORT uint64_t orb_ssh_identity_step(uint8_t v_isWorkerOrContainerTarget_3661_, uint8_t v_bundleHasControlPlaneKey_3662_, uint8_t v_parentDirIsSymlink_3663_, uint8_t v_pubKeyIsEd25519WithoutPrivate_3664_, uint8_t v_proxyJumpValid_3665_, uint8_t v_codexCyberProgramValid_3666_, uint8_t v_codexGoalBudgetExhausted_3667_){
_start:
{
uint32_t v___y_3669_; uint32_t v___y_3670_; uint32_t v___y_3677_; uint32_t v___y_3680_; uint8_t v___y_3688_; uint8_t v___x_3693_; uint8_t v___x_3694_;
v___x_3693_ = 0;
v___x_3694_ = lean_uint8_dec_eq(v_parentDirIsSymlink_3663_, v___x_3693_);
if (v___x_3694_ == 0)
{
v___y_3688_ = v___x_3694_;
goto v___jp_3687_;
}
else
{
uint8_t v___x_3695_; uint8_t v___x_3696_;
v___x_3695_ = 1;
v___x_3696_ = lean_uint8_dec_eq(v_pubKeyIsEd25519WithoutPrivate_3664_, v___x_3695_);
if (v___x_3696_ == 0)
{
v___y_3688_ = v___x_3696_;
goto v___jp_3687_;
}
else
{
uint8_t v___x_3697_;
v___x_3697_ = lean_uint8_dec_eq(v_proxyJumpValid_3665_, v___x_3695_);
if (v___x_3697_ == 0)
{
v___y_3688_ = v___x_3697_;
goto v___jp_3687_;
}
else
{
uint8_t v___x_3698_;
v___x_3698_ = lean_uint8_dec_eq(v_codexCyberProgramValid_3666_, v___x_3695_);
if (v___x_3698_ == 0)
{
v___y_3688_ = v___x_3698_;
goto v___jp_3687_;
}
else
{
uint8_t v___x_3699_;
v___x_3699_ = lean_uint8_dec_eq(v_codexGoalBudgetExhausted_3667_, v___x_3693_);
if (v___x_3699_ == 0)
{
v___y_3688_ = v___x_3699_;
goto v___jp_3687_;
}
else
{
uint8_t v___x_3700_;
v___x_3700_ = lean_uint8_dec_eq(v_isWorkerOrContainerTarget_3661_, v___x_3695_);
if (v___x_3700_ == 0)
{
v___y_3688_ = v___x_3699_;
goto v___jp_3687_;
}
else
{
uint8_t v___x_3701_;
v___x_3701_ = lean_uint8_dec_eq(v_bundleHasControlPlaneKey_3662_, v___x_3695_);
if (v___x_3701_ == 0)
{
v___y_3688_ = v___x_3699_;
goto v___jp_3687_;
}
else
{
goto v___jp_3682_;
}
}
}
}
}
}
}
v___jp_3668_:
{
uint64_t v___x_3671_; uint64_t v___x_3672_; uint64_t v___x_3673_; uint64_t v___x_3674_; uint64_t v___x_3675_;
v___x_3671_ = lean_uint32_to_uint64(v___y_3669_);
v___x_3672_ = lean_uint32_to_uint64(v___y_3670_);
v___x_3673_ = 32ULL;
v___x_3674_ = lean_uint64_shift_left(v___x_3672_, v___x_3673_);
v___x_3675_ = lean_uint64_lor(v___x_3671_, v___x_3674_);
return v___x_3675_;
}
v___jp_3676_:
{
uint32_t v___x_3678_;
v___x_3678_ = 78;
v___y_3669_ = v___y_3677_;
v___y_3670_ = v___x_3678_;
goto v___jp_3668_;
}
v___jp_3679_:
{
uint32_t v___x_3681_;
v___x_3681_ = 0;
v___y_3669_ = v___y_3680_;
v___y_3670_ = v___x_3681_;
goto v___jp_3668_;
}
v___jp_3682_:
{
uint8_t v___x_3683_; uint8_t v___x_3684_;
v___x_3683_ = 1;
v___x_3684_ = lean_uint8_dec_eq(v_isWorkerOrContainerTarget_3661_, v___x_3683_);
if (v___x_3684_ == 0)
{
uint32_t v___x_3685_;
v___x_3685_ = 1024;
v___y_3677_ = v___x_3685_;
goto v___jp_3676_;
}
else
{
uint32_t v___x_3686_;
v___x_3686_ = 1536;
v___y_3677_ = v___x_3686_;
goto v___jp_3676_;
}
}
v___jp_3687_:
{
if (v___y_3688_ == 0)
{
goto v___jp_3682_;
}
else
{
uint8_t v___x_3689_; uint8_t v___x_3690_;
v___x_3689_ = 1;
v___x_3690_ = lean_uint8_dec_eq(v_isWorkerOrContainerTarget_3661_, v___x_3689_);
if (v___x_3690_ == 0)
{
uint32_t v___x_3691_;
v___x_3691_ = 1282;
v___y_3680_ = v___x_3691_;
goto v___jp_3679_;
}
else
{
uint32_t v___x_3692_;
v___x_3692_ = 1793;
v___y_3680_ = v___x_3692_;
goto v___jp_3679_;
}
}
}
}
}

LEAN_EXPORT uint64_t orb_agent_event_normalize_step(uint8_t v_harnessKind_3718_, uint8_t v_rawEventKind_3719_, uint8_t v_isCompleted_3720_, uint8_t v_hasNonEmptyText_3721_, uint32_t v_sessionMatchesExpected_3722_, uint32_t v_isDuplicateTurnOrTool_3723_, uint32_t v_payloadBytes_3724_, uint32_t v_maxPayloadBytes_3725_){
_start:
{
uint32_t v___y_3727_; uint32_t v___y_3728_; uint8_t v_bounded_3734_; uint32_t v___y_3736_; uint8_t v___x_3739_; uint8_t v_harnessValid_3740_; uint8_t v___y_3742_; uint32_t v___x_3776_; uint8_t v___x_3777_;
v_bounded_3734_ = lean_uint32_dec_le(v_payloadBytes_3724_, v_maxPayloadBytes_3725_);
v___x_3739_ = 5;
v_harnessValid_3740_ = lean_uint8_dec_le(v_harnessKind_3718_, v___x_3739_);
v___x_3776_ = 1;
v___x_3777_ = lean_uint32_dec_eq(v_sessionMatchesExpected_3722_, v___x_3776_);
if (v___x_3777_ == 0)
{
uint8_t v___x_3778_; uint8_t v___x_3779_;
v___x_3778_ = 0;
v___x_3779_ = lean_uint8_dec_eq(v_rawEventKind_3719_, v___x_3778_);
if (v___x_3779_ == 0)
{
uint8_t v___x_3780_; uint8_t v___x_3781_;
v___x_3780_ = 1;
v___x_3781_ = lean_uint8_dec_eq(v_rawEventKind_3719_, v___x_3780_);
if (v___x_3781_ == 0)
{
uint8_t v___x_3782_; uint8_t v___x_3783_;
v___x_3782_ = 7;
v___x_3783_ = lean_uint8_dec_eq(v_rawEventKind_3719_, v___x_3782_);
v___y_3742_ = v___x_3783_;
goto v___jp_3741_;
}
else
{
v___y_3742_ = v___x_3781_;
goto v___jp_3741_;
}
}
else
{
v___y_3742_ = v___x_3779_;
goto v___jp_3741_;
}
}
else
{
v___y_3742_ = v___x_3777_;
goto v___jp_3741_;
}
v___jp_3726_:
{
uint64_t v___x_3729_; uint64_t v___x_3730_; uint64_t v___x_3731_; uint64_t v___x_3732_; uint64_t v___x_3733_;
v___x_3729_ = lean_uint32_to_uint64(v___y_3727_);
v___x_3730_ = lean_uint32_to_uint64(v___y_3728_);
v___x_3731_ = 32ULL;
v___x_3732_ = lean_uint64_shift_left(v___x_3730_, v___x_3731_);
v___x_3733_ = lean_uint64_lor(v___x_3729_, v___x_3732_);
return v___x_3733_;
}
v___jp_3735_:
{
if (v_bounded_3734_ == 0)
{
v___y_3727_ = v___y_3736_;
v___y_3728_ = v_maxPayloadBytes_3725_;
goto v___jp_3726_;
}
else
{
v___y_3727_ = v___y_3736_;
v___y_3728_ = v_payloadBytes_3724_;
goto v___jp_3726_;
}
}
v___jp_3737_:
{
uint32_t v___x_3738_;
v___x_3738_ = 2049;
v___y_3736_ = v___x_3738_;
goto v___jp_3735_;
}
v___jp_3741_:
{
if (v_bounded_3734_ == 0)
{
uint32_t v___x_3743_;
v___x_3743_ = 2048;
v___y_3736_ = v___x_3743_;
goto v___jp_3735_;
}
else
{
if (v_harnessValid_3740_ == 0)
{
goto v___jp_3737_;
}
else
{
if (v___y_3742_ == 0)
{
goto v___jp_3737_;
}
else
{
uint32_t v___x_3744_; uint8_t v_notDup_3745_;
v___x_3744_ = 0;
v_notDup_3745_ = lean_uint32_dec_eq(v_isDuplicateTurnOrTool_3723_, v___x_3744_);
if (v_notDup_3745_ == 0)
{
goto v___jp_3737_;
}
else
{
uint8_t v___x_3746_; uint8_t v___x_3747_;
v___x_3746_ = 0;
v___x_3747_ = lean_uint8_dec_eq(v_rawEventKind_3719_, v___x_3746_);
if (v___x_3747_ == 0)
{
uint8_t v___x_3748_; uint8_t v___x_3749_;
v___x_3748_ = 1;
v___x_3749_ = lean_uint8_dec_eq(v_rawEventKind_3719_, v___x_3748_);
if (v___x_3749_ == 0)
{
uint8_t v___x_3750_; uint8_t v___x_3751_;
v___x_3750_ = 2;
v___x_3751_ = lean_uint8_dec_eq(v_rawEventKind_3719_, v___x_3750_);
if (v___x_3751_ == 0)
{
uint8_t v___x_3752_; uint8_t v___x_3753_;
v___x_3752_ = 3;
v___x_3753_ = lean_uint8_dec_eq(v_rawEventKind_3719_, v___x_3752_);
if (v___x_3753_ == 0)
{
uint8_t v___x_3754_; uint8_t v___x_3755_;
v___x_3754_ = 4;
v___x_3755_ = lean_uint8_dec_eq(v_rawEventKind_3719_, v___x_3754_);
if (v___x_3755_ == 0)
{
uint8_t v___x_3756_;
v___x_3756_ = lean_uint8_dec_eq(v_rawEventKind_3719_, v___x_3739_);
if (v___x_3756_ == 0)
{
uint8_t v___x_3757_; uint8_t v___x_3758_;
v___x_3757_ = 6;
v___x_3758_ = lean_uint8_dec_eq(v_rawEventKind_3719_, v___x_3757_);
if (v___x_3758_ == 0)
{
uint8_t v___x_3759_; uint8_t v___x_3760_;
v___x_3759_ = 7;
v___x_3760_ = lean_uint8_dec_eq(v_rawEventKind_3719_, v___x_3759_);
if (v___x_3760_ == 0)
{
uint32_t v___x_3761_;
v___x_3761_ = 2049;
v___y_3736_ = v___x_3761_;
goto v___jp_3735_;
}
else
{
uint32_t v___x_3762_;
v___x_3762_ = 3338;
v___y_3736_ = v___x_3762_;
goto v___jp_3735_;
}
}
else
{
uint32_t v___x_3763_;
v___x_3763_ = 3337;
v___y_3736_ = v___x_3763_;
goto v___jp_3735_;
}
}
else
{
uint32_t v___x_3764_;
v___x_3764_ = 2312;
v___y_3736_ = v___x_3764_;
goto v___jp_3735_;
}
}
else
{
uint8_t v___x_3765_;
v___x_3765_ = lean_uint8_dec_eq(v_isCompleted_3720_, v___x_3748_);
if (v___x_3765_ == 0)
{
uint32_t v___x_3766_;
v___x_3766_ = 3335;
v___y_3736_ = v___x_3766_;
goto v___jp_3735_;
}
else
{
uint32_t v___x_3767_;
v___x_3767_ = 3334;
v___y_3736_ = v___x_3767_;
goto v___jp_3735_;
}
}
}
else
{
uint8_t v___x_3768_;
v___x_3768_ = lean_uint8_dec_eq(v_hasNonEmptyText_3721_, v___x_3748_);
if (v___x_3768_ == 0)
{
uint32_t v___x_3769_;
v___x_3769_ = 2049;
v___y_3736_ = v___x_3769_;
goto v___jp_3735_;
}
else
{
uint32_t v___x_3770_;
v___x_3770_ = 3333;
v___y_3736_ = v___x_3770_;
goto v___jp_3735_;
}
}
}
else
{
uint8_t v___x_3771_;
v___x_3771_ = lean_uint8_dec_eq(v_hasNonEmptyText_3721_, v___x_3748_);
if (v___x_3771_ == 0)
{
uint32_t v___x_3772_;
v___x_3772_ = 2049;
v___y_3736_ = v___x_3772_;
goto v___jp_3735_;
}
else
{
uint32_t v___x_3773_;
v___x_3773_ = 2820;
v___y_3736_ = v___x_3773_;
goto v___jp_3735_;
}
}
}
else
{
uint32_t v___x_3774_;
v___x_3774_ = 2307;
v___y_3736_ = v___x_3774_;
goto v___jp_3735_;
}
}
else
{
uint32_t v___x_3775_;
v___x_3775_ = 2306;
v___y_3736_ = v___x_3775_;
goto v___jp_3735_;
}
}
}
}
}
}
}
}

LEAN_EXPORT uint64_t orb_transcript_reduce_step(uint64_t v_lastAppliedSeq_3867_, uint64_t v_incomingSeq_3868_, uint8_t v_thinkingOpen_3869_, uint8_t v_normalizedAction_3870_, uint8_t v_isReplayFromLog_3871_){
_start:
{
uint32_t v___y_3873_; uint32_t v___y_3874_; uint32_t v___y_3881_; uint32_t v___y_3887_; uint8_t v_seqAdvances_3892_; uint64_t v___y_3894_;
v_seqAdvances_3892_ = lean_uint64_dec_lt(v_lastAppliedSeq_3867_, v_incomingSeq_3868_);
if (v_seqAdvances_3892_ == 0)
{
v___y_3894_ = v_lastAppliedSeq_3867_;
goto v___jp_3893_;
}
else
{
v___y_3894_ = v_incomingSeq_3868_;
goto v___jp_3893_;
}
v___jp_3872_:
{
uint64_t v___x_3875_; uint64_t v___x_3876_; uint64_t v___x_3877_; uint64_t v___x_3878_; uint64_t v___x_3879_;
v___x_3875_ = lean_uint32_to_uint64(v___y_3874_);
v___x_3876_ = lean_uint32_to_uint64(v___y_3873_);
v___x_3877_ = 32ULL;
v___x_3878_ = lean_uint64_shift_left(v___x_3876_, v___x_3877_);
v___x_3879_ = lean_uint64_lor(v___x_3875_, v___x_3878_);
return v___x_3879_;
}
v___jp_3880_:
{
uint8_t v___x_3882_; uint8_t v___x_3883_;
v___x_3882_ = 1;
v___x_3883_ = lean_uint8_dec_eq(v_thinkingOpen_3869_, v___x_3882_);
if (v___x_3883_ == 0)
{
uint32_t v___x_3884_;
v___x_3884_ = 258;
v___y_3873_ = v___y_3881_;
v___y_3874_ = v___x_3884_;
goto v___jp_3872_;
}
else
{
uint32_t v___x_3885_;
v___x_3885_ = 1282;
v___y_3873_ = v___y_3881_;
v___y_3874_ = v___x_3885_;
goto v___jp_3872_;
}
}
v___jp_3886_:
{
uint8_t v___x_3888_; uint8_t v___x_3889_;
v___x_3888_ = 1;
v___x_3889_ = lean_uint8_dec_eq(v_thinkingOpen_3869_, v___x_3888_);
if (v___x_3889_ == 0)
{
uint32_t v___x_3890_;
v___x_3890_ = 259;
v___y_3873_ = v___y_3887_;
v___y_3874_ = v___x_3890_;
goto v___jp_3872_;
}
else
{
uint32_t v___x_3891_;
v___x_3891_ = 771;
v___y_3873_ = v___y_3887_;
v___y_3874_ = v___x_3891_;
goto v___jp_3872_;
}
}
v___jp_3893_:
{
uint32_t v_nextSeq32_3895_;
v_nextSeq32_3895_ = lean_uint64_to_uint32(v___y_3894_);
if (v_seqAdvances_3892_ == 0)
{
uint8_t v___x_3896_; uint8_t v___x_3897_;
v___x_3896_ = 1;
v___x_3897_ = lean_uint8_dec_eq(v_thinkingOpen_3869_, v___x_3896_);
if (v___x_3897_ == 0)
{
uint32_t v___x_3898_;
v___x_3898_ = 0;
v___y_3873_ = v_nextSeq32_3895_;
v___y_3874_ = v___x_3898_;
goto v___jp_3872_;
}
else
{
uint32_t v___x_3899_;
v___x_3899_ = 512;
v___y_3873_ = v_nextSeq32_3895_;
v___y_3874_ = v___x_3899_;
goto v___jp_3872_;
}
}
else
{
uint8_t v___x_3900_; uint8_t v___x_3901_;
v___x_3900_ = 4;
v___x_3901_ = lean_uint8_dec_eq(v_normalizedAction_3870_, v___x_3900_);
if (v___x_3901_ == 0)
{
uint8_t v___x_3902_; uint8_t v___x_3903_;
v___x_3902_ = 5;
v___x_3903_ = lean_uint8_dec_eq(v_normalizedAction_3870_, v___x_3902_);
if (v___x_3903_ == 0)
{
uint8_t v___x_3904_; uint8_t v___x_3905_;
v___x_3904_ = 6;
v___x_3905_ = lean_uint8_dec_eq(v_normalizedAction_3870_, v___x_3904_);
if (v___x_3905_ == 0)
{
uint8_t v___x_3906_; uint8_t v___x_3907_;
v___x_3906_ = 7;
v___x_3907_ = lean_uint8_dec_eq(v_normalizedAction_3870_, v___x_3906_);
if (v___x_3907_ == 0)
{
uint8_t v___x_3908_; uint8_t v___x_3909_;
v___x_3908_ = 9;
v___x_3909_ = lean_uint8_dec_eq(v_normalizedAction_3870_, v___x_3908_);
if (v___x_3909_ == 0)
{
uint8_t v___x_3910_; uint8_t v___x_3911_;
v___x_3910_ = 10;
v___x_3911_ = lean_uint8_dec_eq(v_normalizedAction_3870_, v___x_3910_);
if (v___x_3911_ == 0)
{
uint8_t v___x_3912_; uint8_t v___x_3913_;
v___x_3912_ = 2;
v___x_3913_ = lean_uint8_dec_eq(v_normalizedAction_3870_, v___x_3912_);
if (v___x_3913_ == 0)
{
uint8_t v___x_3914_; uint8_t v___x_3915_;
v___x_3914_ = 3;
v___x_3915_ = lean_uint8_dec_eq(v_normalizedAction_3870_, v___x_3914_);
if (v___x_3915_ == 0)
{
uint8_t v___x_3916_; uint8_t v___x_3917_;
v___x_3916_ = 8;
v___x_3917_ = lean_uint8_dec_eq(v_normalizedAction_3870_, v___x_3916_);
if (v___x_3917_ == 0)
{
uint8_t v___x_3918_; uint8_t v___x_3919_;
v___x_3918_ = 1;
v___x_3919_ = lean_uint8_dec_eq(v_thinkingOpen_3869_, v___x_3918_);
if (v___x_3919_ == 0)
{
uint32_t v___x_3920_;
v___x_3920_ = 0;
v___y_3873_ = v_nextSeq32_3895_;
v___y_3874_ = v___x_3920_;
goto v___jp_3872_;
}
else
{
uint32_t v___x_3921_;
v___x_3921_ = 512;
v___y_3873_ = v_nextSeq32_3895_;
v___y_3874_ = v___x_3921_;
goto v___jp_3872_;
}
}
else
{
v___y_3887_ = v_nextSeq32_3895_;
goto v___jp_3886_;
}
}
else
{
v___y_3887_ = v_nextSeq32_3895_;
goto v___jp_3886_;
}
}
else
{
v___y_3887_ = v_nextSeq32_3895_;
goto v___jp_3886_;
}
}
else
{
v___y_3881_ = v_nextSeq32_3895_;
goto v___jp_3880_;
}
}
else
{
v___y_3881_ = v_nextSeq32_3895_;
goto v___jp_3880_;
}
}
else
{
v___y_3881_ = v_nextSeq32_3895_;
goto v___jp_3880_;
}
}
else
{
v___y_3881_ = v_nextSeq32_3895_;
goto v___jp_3880_;
}
}
else
{
v___y_3881_ = v_nextSeq32_3895_;
goto v___jp_3880_;
}
}
else
{
uint32_t v___x_3922_;
v___x_3922_ = 769;
v___y_3873_ = v_nextSeq32_3895_;
v___y_3874_ = v___x_3922_;
goto v___jp_3872_;
}
}
}
}
}

LEAN_EXPORT uint64_t orb_cursor_page_step(uint64_t v_sinceSeq_3935_, uint64_t v_beforeSeq_3936_, uint64_t v_itemSeq_3937_, uint32_t v_hasSinceCursor_3938_, uint32_t v_hasBeforeCursor_3939_, uint32_t v_isPartialResponse_3940_, uint32_t v_existingCount_3941_){
_start:
{
uint32_t v___y_3943_; uint32_t v___y_3944_; uint32_t v___x_3950_; uint32_t v___y_3952_; uint8_t v___y_3955_; uint8_t v___y_3956_; uint32_t v___y_3957_; uint8_t v___y_3965_; uint32_t v___y_3966_; uint8_t v___y_3967_; uint8_t v___y_3971_; uint8_t v___y_3972_; uint32_t v___y_3973_; uint8_t v___y_3974_; uint8_t v___y_3976_; uint32_t v___y_3977_; uint8_t v___y_3978_; uint8_t v___y_3982_; uint8_t v___x_3988_;
v___x_3950_ = 1;
v___x_3988_ = lean_uint32_dec_eq(v_hasSinceCursor_3938_, v___x_3950_);
if (v___x_3988_ == 0)
{
goto v___jp_3986_;
}
else
{
uint8_t v___x_3989_;
v___x_3989_ = lean_uint32_dec_eq(v_hasBeforeCursor_3939_, v___x_3950_);
if (v___x_3989_ == 0)
{
goto v___jp_3986_;
}
else
{
uint8_t v___x_3990_;
v___x_3990_ = lean_uint64_dec_le(v_beforeSeq_3936_, v_sinceSeq_3935_);
if (v___x_3990_ == 0)
{
goto v___jp_3986_;
}
else
{
uint8_t v___x_3991_;
v___x_3991_ = 0;
v___y_3982_ = v___x_3991_;
goto v___jp_3981_;
}
}
}
v___jp_3942_:
{
uint64_t v___x_3945_; uint64_t v___x_3946_; uint64_t v___x_3947_; uint64_t v___x_3948_; uint64_t v___x_3949_;
v___x_3945_ = lean_uint32_to_uint64(v___y_3943_);
v___x_3946_ = lean_uint32_to_uint64(v___y_3944_);
v___x_3947_ = 32ULL;
v___x_3948_ = lean_uint64_shift_left(v___x_3946_, v___x_3947_);
v___x_3949_ = lean_uint64_lor(v___x_3945_, v___x_3948_);
return v___x_3949_;
}
v___jp_3951_:
{
uint32_t v___x_3953_;
v___x_3953_ = lean_uint32_add(v_existingCount_3941_, v___x_3950_);
v___y_3943_ = v___y_3952_;
v___y_3944_ = v___x_3953_;
goto v___jp_3942_;
}
v___jp_3954_:
{
if (v___y_3955_ == 0)
{
uint32_t v___x_3958_; uint32_t v___x_3959_;
v___x_3958_ = 512;
v___x_3959_ = lean_uint32_lor(v___x_3958_, v___y_3957_);
if (v___y_3956_ == 0)
{
v___y_3943_ = v___x_3959_;
v___y_3944_ = v_existingCount_3941_;
goto v___jp_3942_;
}
else
{
v___y_3952_ = v___x_3959_;
goto v___jp_3951_;
}
}
else
{
if (v___y_3956_ == 0)
{
uint32_t v___x_3960_; uint32_t v___x_3961_;
v___x_3960_ = 514;
v___x_3961_ = lean_uint32_lor(v___x_3960_, v___y_3957_);
v___y_3943_ = v___x_3961_;
v___y_3944_ = v_existingCount_3941_;
goto v___jp_3942_;
}
else
{
uint32_t v___x_3962_; uint32_t v___x_3963_;
v___x_3962_ = 769;
v___x_3963_ = lean_uint32_lor(v___x_3962_, v___y_3957_);
v___y_3952_ = v___x_3963_;
goto v___jp_3951_;
}
}
}
v___jp_3964_:
{
uint8_t v___x_3968_;
v___x_3968_ = lean_uint32_dec_eq(v_isPartialResponse_3940_, v___x_3950_);
if (v___x_3968_ == 0)
{
v___y_3955_ = v___y_3965_;
v___y_3956_ = v___y_3967_;
v___y_3957_ = v___y_3966_;
goto v___jp_3954_;
}
else
{
uint32_t v___x_3969_;
v___x_3969_ = 1024;
v___y_3955_ = v___y_3965_;
v___y_3956_ = v___y_3967_;
v___y_3957_ = v___x_3969_;
goto v___jp_3954_;
}
}
v___jp_3970_:
{
if (v___y_3971_ == 0)
{
v___y_3965_ = v___y_3971_;
v___y_3966_ = v___y_3973_;
v___y_3967_ = v___y_3971_;
goto v___jp_3964_;
}
else
{
if (v___y_3972_ == 0)
{
v___y_3965_ = v___y_3971_;
v___y_3966_ = v___y_3973_;
v___y_3967_ = v___y_3972_;
goto v___jp_3964_;
}
else
{
v___y_3965_ = v___y_3971_;
v___y_3966_ = v___y_3973_;
v___y_3967_ = v___y_3974_;
goto v___jp_3964_;
}
}
}
v___jp_3975_:
{
uint8_t v___x_3979_;
v___x_3979_ = lean_uint32_dec_eq(v_hasBeforeCursor_3939_, v___y_3977_);
if (v___x_3979_ == 0)
{
uint8_t v___x_3980_;
v___x_3980_ = lean_uint64_dec_lt(v_itemSeq_3937_, v_beforeSeq_3936_);
v___y_3971_ = v___y_3976_;
v___y_3972_ = v___y_3978_;
v___y_3973_ = v___y_3977_;
v___y_3974_ = v___x_3980_;
goto v___jp_3970_;
}
else
{
v___y_3971_ = v___y_3976_;
v___y_3972_ = v___y_3978_;
v___y_3973_ = v___y_3977_;
v___y_3974_ = v___x_3979_;
goto v___jp_3970_;
}
}
v___jp_3981_:
{
uint32_t v___x_3983_; uint8_t v___x_3984_;
v___x_3983_ = 0;
v___x_3984_ = lean_uint32_dec_eq(v_hasSinceCursor_3938_, v___x_3983_);
if (v___x_3984_ == 0)
{
uint8_t v___x_3985_;
v___x_3985_ = lean_uint64_dec_lt(v_sinceSeq_3935_, v_itemSeq_3937_);
v___y_3976_ = v___y_3982_;
v___y_3977_ = v___x_3983_;
v___y_3978_ = v___x_3985_;
goto v___jp_3975_;
}
else
{
v___y_3976_ = v___y_3982_;
v___y_3977_ = v___x_3983_;
v___y_3978_ = v___x_3984_;
goto v___jp_3975_;
}
}
v___jp_3986_:
{
uint8_t v___x_3987_;
v___x_3987_ = 1;
v___y_3982_ = v___x_3987_;
goto v___jp_3981_;
}
}
}

LEAN_EXPORT uint64_t orb_sidebar_merge_step(uint32_t v_existingIdOrd_4008_, uint32_t v_incomingIdOrd_4009_, uint64_t v_existingUpdatedAtMs_4010_, uint64_t v_incomingUpdatedAtMs_4011_, uint8_t v_incomingSupersededOrArchived_4012_, uint8_t v_isPartialPage_4013_){
_start:
{
uint32_t v___y_4015_; uint32_t v___y_4016_; uint32_t v___x_4022_; uint8_t v___y_4024_; uint8_t v___y_4025_; uint32_t v___y_4026_; uint32_t v___y_4029_; uint8_t v___y_4030_; uint8_t v___y_4031_; uint32_t v___y_4032_; uint32_t v___y_4035_; uint8_t v___y_4036_; uint8_t v___y_4037_; uint32_t v___y_4038_; uint8_t v___y_4041_; uint8_t v___y_4042_; uint8_t v___y_4043_; uint32_t v___y_4044_; uint8_t v___y_4053_; uint8_t v___x_4058_;
v___x_4022_ = 0;
v___x_4058_ = lean_uint32_dec_eq(v_existingIdOrd_4008_, v___x_4022_);
if (v___x_4058_ == 0)
{
uint8_t v___x_4059_;
v___x_4059_ = lean_uint32_dec_eq(v_existingIdOrd_4008_, v_incomingIdOrd_4009_);
v___y_4053_ = v___x_4059_;
goto v___jp_4052_;
}
else
{
uint8_t v___x_4060_;
v___x_4060_ = 0;
v___y_4053_ = v___x_4060_;
goto v___jp_4052_;
}
v___jp_4014_:
{
uint64_t v___x_4017_; uint64_t v___x_4018_; uint64_t v___x_4019_; uint64_t v___x_4020_; uint64_t v___x_4021_;
v___x_4017_ = lean_uint32_to_uint64(v___y_4015_);
v___x_4018_ = lean_uint32_to_uint64(v___y_4016_);
v___x_4019_ = 32ULL;
v___x_4020_ = lean_uint64_shift_left(v___x_4018_, v___x_4019_);
v___x_4021_ = lean_uint64_lor(v___x_4017_, v___x_4020_);
return v___x_4021_;
}
v___jp_4023_:
{
if (v___y_4024_ == 0)
{
if (v___y_4025_ == 0)
{
uint32_t v___x_4027_;
v___x_4027_ = 1;
v___y_4015_ = v___y_4026_;
v___y_4016_ = v___x_4027_;
goto v___jp_4014_;
}
else
{
v___y_4015_ = v___y_4026_;
v___y_4016_ = v___x_4022_;
goto v___jp_4014_;
}
}
else
{
v___y_4015_ = v___y_4026_;
v___y_4016_ = v___x_4022_;
goto v___jp_4014_;
}
}
v___jp_4028_:
{
uint32_t v___x_4033_;
v___x_4033_ = lean_uint32_lor(v___y_4032_, v___y_4029_);
v___y_4024_ = v___y_4030_;
v___y_4025_ = v___y_4031_;
v___y_4026_ = v___x_4033_;
goto v___jp_4023_;
}
v___jp_4034_:
{
uint32_t v___x_4039_;
v___x_4039_ = lean_uint32_lor(v___y_4038_, v___y_4035_);
v___y_4024_ = v___y_4036_;
v___y_4025_ = v___y_4037_;
v___y_4026_ = v___x_4039_;
goto v___jp_4023_;
}
v___jp_4040_:
{
uint8_t v___x_4045_;
v___x_4045_ = lean_uint8_dec_eq(v_incomingSupersededOrArchived_4012_, v___y_4041_);
if (v___x_4045_ == 0)
{
if (v___y_4043_ == 0)
{
uint32_t v___x_4046_; uint32_t v___x_4047_;
v___x_4046_ = 1795;
v___x_4047_ = lean_uint32_lor(v___x_4046_, v___y_4044_);
v___y_4024_ = v___x_4045_;
v___y_4025_ = v___y_4043_;
v___y_4026_ = v___x_4047_;
goto v___jp_4023_;
}
else
{
if (v___y_4042_ == 0)
{
uint32_t v___x_4048_;
v___x_4048_ = 1282;
v___y_4029_ = v___y_4044_;
v___y_4030_ = v___x_4045_;
v___y_4031_ = v___y_4043_;
v___y_4032_ = v___x_4048_;
goto v___jp_4028_;
}
else
{
uint32_t v___x_4049_;
v___x_4049_ = 1281;
v___y_4029_ = v___y_4044_;
v___y_4030_ = v___x_4045_;
v___y_4031_ = v___y_4043_;
v___y_4032_ = v___x_4049_;
goto v___jp_4028_;
}
}
}
else
{
if (v___y_4043_ == 0)
{
uint32_t v___x_4050_;
v___x_4050_ = 1024;
v___y_4035_ = v___y_4044_;
v___y_4036_ = v___x_4045_;
v___y_4037_ = v___y_4043_;
v___y_4038_ = v___x_4050_;
goto v___jp_4034_;
}
else
{
uint32_t v___x_4051_;
v___x_4051_ = 1028;
v___y_4035_ = v___y_4044_;
v___y_4036_ = v___x_4045_;
v___y_4037_ = v___y_4043_;
v___y_4038_ = v___x_4051_;
goto v___jp_4034_;
}
}
}
v___jp_4052_:
{
uint8_t v_incomingNewer_4054_; uint8_t v___x_4055_; uint8_t v___x_4056_;
v_incomingNewer_4054_ = lean_uint64_dec_le(v_existingUpdatedAtMs_4010_, v_incomingUpdatedAtMs_4011_);
v___x_4055_ = 1;
v___x_4056_ = lean_uint8_dec_eq(v_isPartialPage_4013_, v___x_4055_);
if (v___x_4056_ == 0)
{
v___y_4041_ = v___x_4055_;
v___y_4042_ = v_incomingNewer_4054_;
v___y_4043_ = v___y_4053_;
v___y_4044_ = v___x_4022_;
goto v___jp_4040_;
}
else
{
uint32_t v___x_4057_;
v___x_4057_ = 2048;
v___y_4041_ = v___x_4055_;
v___y_4042_ = v_incomingNewer_4054_;
v___y_4043_ = v___y_4053_;
v___y_4044_ = v___x_4057_;
goto v___jp_4040_;
}
}
}
}

LEAN_EXPORT uint64_t orb_scroll_epoch_step(uint32_t v_layoutEpoch_4075_, uint32_t v_lastCorrectedEpoch_4076_, uint8_t v_correctionsInEpoch_4077_, uint8_t v_isPinnedToBottom_4078_, uint8_t v_userIsDragging_4079_, uint32_t v_targetScrollTopPx_4080_, uint32_t v_currentScrollTopPx_4081_){
_start:
{
uint32_t v___y_4083_; uint32_t v___y_4084_; uint8_t v___y_4093_; uint8_t v___y_4094_; uint8_t v___y_4098_; uint8_t v___y_4099_; uint8_t v___y_4105_; uint8_t v_newEpoch_4109_;
v_newEpoch_4109_ = lean_uint32_dec_lt(v_lastCorrectedEpoch_4076_, v_layoutEpoch_4075_);
if (v_newEpoch_4109_ == 0)
{
uint8_t v___x_4110_; uint8_t v___x_4111_;
v___x_4110_ = 0;
v___x_4111_ = lean_uint8_dec_lt(v___x_4110_, v_correctionsInEpoch_4077_);
v___y_4105_ = v___x_4111_;
goto v___jp_4104_;
}
else
{
uint8_t v___x_4112_;
v___x_4112_ = 0;
v___y_4105_ = v___x_4112_;
goto v___jp_4104_;
}
v___jp_4082_:
{
uint64_t v___x_4085_; uint64_t v___x_4086_; uint64_t v___x_4087_; uint64_t v___x_4088_; uint64_t v___x_4089_;
v___x_4085_ = lean_uint32_to_uint64(v___y_4083_);
v___x_4086_ = lean_uint32_to_uint64(v___y_4084_);
v___x_4087_ = 32ULL;
v___x_4088_ = lean_uint64_shift_left(v___x_4086_, v___x_4087_);
v___x_4089_ = lean_uint64_lor(v___x_4085_, v___x_4088_);
return v___x_4089_;
}
v___jp_4090_:
{
uint32_t v___x_4091_;
v___x_4091_ = 1026;
v___y_4083_ = v___x_4091_;
v___y_4084_ = v_currentScrollTopPx_4081_;
goto v___jp_4082_;
}
v___jp_4092_:
{
if (v___y_4094_ == 0)
{
if (v___y_4093_ == 0)
{
uint32_t v___x_4095_;
v___x_4095_ = 0;
v___y_4083_ = v___x_4095_;
v___y_4084_ = v_currentScrollTopPx_4081_;
goto v___jp_4082_;
}
else
{
goto v___jp_4090_;
}
}
else
{
uint32_t v___x_4096_;
v___x_4096_ = 1281;
v___y_4083_ = v___x_4096_;
v___y_4084_ = v_targetScrollTopPx_4080_;
goto v___jp_4082_;
}
}
v___jp_4097_:
{
uint8_t v___x_4100_; uint8_t v___x_4101_;
v___x_4100_ = 1;
v___x_4101_ = lean_uint8_dec_eq(v_isPinnedToBottom_4078_, v___x_4100_);
if (v___x_4101_ == 0)
{
v___y_4093_ = v___y_4098_;
v___y_4094_ = v___x_4101_;
goto v___jp_4092_;
}
else
{
uint8_t v___x_4102_; uint8_t v___x_4103_;
v___x_4102_ = 0;
v___x_4103_ = lean_uint8_dec_eq(v_userIsDragging_4079_, v___x_4102_);
if (v___x_4103_ == 0)
{
v___y_4093_ = v___y_4098_;
v___y_4094_ = v___x_4103_;
goto v___jp_4092_;
}
else
{
if (v___y_4098_ == 0)
{
v___y_4093_ = v___y_4098_;
v___y_4094_ = v___y_4099_;
goto v___jp_4092_;
}
else
{
goto v___jp_4090_;
}
}
}
}
v___jp_4104_:
{
uint8_t v___x_4106_;
v___x_4106_ = lean_uint32_dec_eq(v_targetScrollTopPx_4080_, v_currentScrollTopPx_4081_);
if (v___x_4106_ == 0)
{
uint8_t v___x_4107_;
v___x_4107_ = 1;
v___y_4098_ = v___y_4105_;
v___y_4099_ = v___x_4107_;
goto v___jp_4097_;
}
else
{
uint8_t v___x_4108_;
v___x_4108_ = 0;
v___y_4098_ = v___y_4105_;
v___y_4099_ = v___x_4108_;
goto v___jp_4097_;
}
}
}
}

LEAN_EXPORT uint64_t orb_client_parity_step(uint8_t v_clientTarget_4129_, uint32_t v_wireSchemaId_4130_, uint32_t v_transcriptSeq_4131_, uint32_t v_markdownBlocksCount_4132_, uint32_t v_sendQueueDepth_4133_, uint8_t v_scrollCorrectedInEpoch_4134_){
_start:
{
uint32_t v___y_4136_; uint32_t v___y_4137_; uint32_t v___y_4146_; uint8_t v___x_4153_; uint8_t v_validTarget_4154_; uint8_t v___y_4156_; uint32_t v___x_4161_; uint8_t v___x_4162_;
v___x_4153_ = 3;
v_validTarget_4154_ = lean_uint8_dec_le(v_clientTarget_4129_, v___x_4153_);
v___x_4161_ = 1;
v___x_4162_ = lean_uint32_dec_le(v___x_4161_, v_wireSchemaId_4130_);
if (v___x_4162_ == 0)
{
v___y_4156_ = v___x_4162_;
goto v___jp_4155_;
}
else
{
uint32_t v___x_4163_; uint8_t v___x_4164_;
v___x_4163_ = 2;
v___x_4164_ = lean_uint32_dec_le(v_wireSchemaId_4130_, v___x_4163_);
v___y_4156_ = v___x_4164_;
goto v___jp_4155_;
}
v___jp_4135_:
{
uint64_t v___x_4138_; uint64_t v___x_4139_; uint64_t v___x_4140_; uint64_t v___x_4141_; uint64_t v___x_4142_;
v___x_4138_ = lean_uint32_to_uint64(v___y_4136_);
v___x_4139_ = lean_uint32_to_uint64(v___y_4137_);
v___x_4140_ = 32ULL;
v___x_4141_ = lean_uint64_shift_left(v___x_4139_, v___x_4140_);
v___x_4142_ = lean_uint64_lor(v___x_4138_, v___x_4141_);
return v___x_4142_;
}
v___jp_4143_:
{
uint32_t v___x_4144_;
v___x_4144_ = 0;
v___y_4136_ = v___x_4144_;
v___y_4137_ = v___x_4144_;
goto v___jp_4135_;
}
v___jp_4145_:
{
uint32_t v___x_4147_; uint32_t v___x_4148_; uint32_t v___x_4149_; uint32_t v___x_4150_; uint32_t v___x_4151_; uint32_t v___x_4152_;
v___x_4147_ = 16;
v___x_4148_ = lean_uint32_shift_left(v_markdownBlocksCount_4132_, v___x_4147_);
v___x_4149_ = lean_uint32_xor(v_transcriptSeq_4131_, v___x_4148_);
v___x_4150_ = 24;
v___x_4151_ = lean_uint32_shift_left(v_sendQueueDepth_4133_, v___x_4150_);
v___x_4152_ = lean_uint32_xor(v___x_4149_, v___x_4151_);
v___y_4136_ = v___y_4146_;
v___y_4137_ = v___x_4152_;
goto v___jp_4135_;
}
v___jp_4155_:
{
if (v_validTarget_4154_ == 0)
{
goto v___jp_4143_;
}
else
{
if (v___y_4156_ == 0)
{
goto v___jp_4143_;
}
else
{
uint8_t v___x_4157_; uint8_t v___x_4158_;
v___x_4157_ = 1;
v___x_4158_ = lean_uint8_dec_eq(v_scrollCorrectedInEpoch_4134_, v___x_4157_);
if (v___x_4158_ == 0)
{
uint32_t v___x_4159_;
v___x_4159_ = 257;
v___y_4146_ = v___x_4159_;
goto v___jp_4145_;
}
else
{
uint32_t v___x_4160_;
v___x_4160_ = 769;
v___y_4146_ = v___x_4160_;
goto v___jp_4145_;
}
}
}
}
}
}

LEAN_EXPORT uint8_t orb_verify_approval(uint8_t v_signed_4443_, uint8_t v_owned_4444_, uint8_t v_pending_4445_, uint8_t v_unexpired_4446_, uint8_t v_unchanged_4447_, uint8_t v_risk_4448_, uint8_t v_confirmed_4449_){
_start:
{
uint8_t v___x_4450_; uint8_t v___x_4451_;
v___x_4450_ = 1;
v___x_4451_ = lean_uint8_dec_eq(v_signed_4443_, v___x_4450_);
if (v___x_4451_ == 0)
{
uint8_t v___x_4452_;
v___x_4452_ = 0;
return v___x_4452_;
}
else
{
uint8_t v___x_4453_;
v___x_4453_ = lean_uint8_dec_eq(v_owned_4444_, v___x_4450_);
if (v___x_4453_ == 0)
{
uint8_t v___x_4454_;
v___x_4454_ = 0;
return v___x_4454_;
}
else
{
uint8_t v___x_4455_;
v___x_4455_ = lean_uint8_dec_eq(v_pending_4445_, v___x_4450_);
if (v___x_4455_ == 0)
{
uint8_t v___x_4456_;
v___x_4456_ = 0;
return v___x_4456_;
}
else
{
uint8_t v___x_4457_;
v___x_4457_ = lean_uint8_dec_eq(v_unexpired_4446_, v___x_4450_);
if (v___x_4457_ == 0)
{
uint8_t v___x_4458_;
v___x_4458_ = 0;
return v___x_4458_;
}
else
{
uint8_t v___x_4459_;
v___x_4459_ = lean_uint8_dec_eq(v_unchanged_4447_, v___x_4450_);
if (v___x_4459_ == 0)
{
uint8_t v___x_4460_;
v___x_4460_ = 0;
return v___x_4460_;
}
else
{
uint8_t v___x_4461_; uint8_t v___x_4462_;
v___x_4461_ = 2;
v___x_4462_ = lean_uint8_dec_lt(v_risk_4448_, v___x_4461_);
if (v___x_4462_ == 0)
{
uint8_t v___x_4463_;
v___x_4463_ = lean_uint8_dec_eq(v_confirmed_4449_, v___x_4450_);
if (v___x_4463_ == 0)
{
uint8_t v___x_4464_;
v___x_4464_ = 0;
return v___x_4464_;
}
else
{
return v___x_4450_;
}
}
else
{
return v___x_4450_;
}
}
}
}
}
}
}
}

LEAN_EXPORT uint64_t orb_node_gc_step(uint64_t v_freeBytes_4481_, uint64_t v_floorBytes_4482_, uint64_t v_emergencyFloorBytes_4483_, uint64_t v_agedScratchBytes_4484_, uint64_t v_freshScratchBytes_4485_, uint64_t v_coldCacheBytes_4486_, uint64_t v_hotCacheBytes_4487_){
_start:
{
uint32_t v___y_4489_; uint32_t v___y_4490_; uint8_t v___y_4497_; uint32_t v___y_4498_; uint32_t v___y_4499_; uint8_t v___y_4504_; uint8_t v___y_4505_; uint32_t v___y_4506_; uint32_t v___y_4507_; uint32_t v___y_4512_; uint8_t v___y_4513_; uint8_t v___y_4514_; uint8_t v___y_4515_; uint32_t v___y_4516_; uint32_t v___y_4521_; uint8_t v___y_4522_; uint8_t v___y_4523_; uint8_t v___y_4524_; uint32_t v___y_4525_; uint8_t v___y_4530_; uint8_t v___y_4531_; uint8_t v___y_4532_; uint8_t v___y_4533_; uint32_t v___y_4534_; uint8_t v___y_4540_; uint8_t v___y_4541_; uint8_t v___y_4542_; uint8_t v___y_4543_; uint8_t v___y_4546_; uint8_t v___y_4547_; uint8_t v___y_4548_; uint8_t v___y_4549_; uint8_t v___y_4554_; uint8_t v___y_4555_; uint8_t v___y_4556_; uint8_t v___y_4557_; uint8_t v___y_4560_; uint8_t v___y_4561_; uint8_t v___y_4562_; uint8_t v___y_4563_; uint8_t v_underFloor_4564_;
v_underFloor_4564_ = lean_uint64_dec_lt(v_freeBytes_4481_, v_floorBytes_4482_);
if (v_underFloor_4564_ == 0)
{
uint64_t v___x_4565_;
v___x_4565_ = 309237645312ULL;
return v___x_4565_;
}
else
{
uint8_t v___x_4566_; uint8_t v_emerg_4567_; uint8_t v___y_4569_; uint8_t v___y_4570_; uint64_t v___y_4571_; uint8_t v___y_4572_; uint8_t v___y_4573_; uint64_t v___y_4576_; uint64_t v___y_4577_; uint64_t v___y_4578_; uint64_t v___y_4585_; uint64_t v___y_4586_; uint64_t v___y_4591_; uint64_t v_deficit_4595_; uint8_t v___x_4596_;
v___x_4566_ = 0;
v_emerg_4567_ = lean_uint64_dec_lt(v_freeBytes_4481_, v_emergencyFloorBytes_4483_);
v_deficit_4595_ = lean_uint64_sub(v_floorBytes_4482_, v_freeBytes_4481_);
v___x_4596_ = lean_uint64_dec_le(v_deficit_4595_, v_agedScratchBytes_4484_);
if (v___x_4596_ == 0)
{
uint64_t v___x_4597_;
v___x_4597_ = lean_uint64_sub(v_deficit_4595_, v_agedScratchBytes_4484_);
v___y_4591_ = v___x_4597_;
goto v___jp_4590_;
}
else
{
uint64_t v___x_4598_;
v___x_4598_ = 0ULL;
v___y_4591_ = v___x_4598_;
goto v___jp_4590_;
}
v___jp_4568_:
{
if (v___y_4572_ == 0)
{
if (v___y_4569_ == 0)
{
v___y_4546_ = v___y_4573_;
v___y_4547_ = v___y_4569_;
v___y_4548_ = v___y_4570_;
v___y_4549_ = v___x_4566_;
goto v___jp_4545_;
}
else
{
v___y_4540_ = v___y_4573_;
v___y_4541_ = v___y_4569_;
v___y_4542_ = v___y_4570_;
v___y_4543_ = v___x_4566_;
goto v___jp_4539_;
}
}
else
{
if (v___y_4569_ == 0)
{
if (v_underFloor_4564_ == 0)
{
v___y_4546_ = v___y_4573_;
v___y_4547_ = v___y_4569_;
v___y_4548_ = v___y_4570_;
v___y_4549_ = v_underFloor_4564_;
goto v___jp_4545_;
}
else
{
v___y_4554_ = v___y_4573_;
v___y_4555_ = v___y_4569_;
v___y_4556_ = v___y_4570_;
v___y_4557_ = v_underFloor_4564_;
goto v___jp_4553_;
}
}
else
{
if (v_emerg_4567_ == 0)
{
v___y_4560_ = v___y_4573_;
v___y_4561_ = v___y_4569_;
v___y_4562_ = v___y_4570_;
v___y_4563_ = v_emerg_4567_;
goto v___jp_4559_;
}
else
{
uint8_t v___x_4574_;
v___x_4574_ = lean_uint64_dec_lt(v___y_4571_, v_hotCacheBytes_4487_);
v___y_4560_ = v___y_4573_;
v___y_4561_ = v___y_4569_;
v___y_4562_ = v___y_4570_;
v___y_4563_ = v___x_4574_;
goto v___jp_4559_;
}
}
}
}
v___jp_4575_:
{
uint8_t v_unrecoverable_4579_; uint64_t v___x_4580_; uint8_t v_evictCold_4581_; uint8_t v_hasRem2_4582_; uint8_t v_hasRem3_4583_;
v_unrecoverable_4579_ = lean_uint64_dec_lt(v_hotCacheBytes_4487_, v___y_4578_);
v___x_4580_ = 0ULL;
v_evictCold_4581_ = lean_uint64_dec_lt(v___x_4580_, v___y_4577_);
v_hasRem2_4582_ = lean_uint64_dec_lt(v___x_4580_, v___y_4576_);
v_hasRem3_4583_ = lean_uint64_dec_lt(v___x_4580_, v___y_4578_);
if (v_hasRem2_4582_ == 0)
{
v___y_4569_ = v_unrecoverable_4579_;
v___y_4570_ = v_evictCold_4581_;
v___y_4571_ = v___x_4580_;
v___y_4572_ = v_hasRem3_4583_;
v___y_4573_ = v_emerg_4567_;
goto v___jp_4568_;
}
else
{
v___y_4569_ = v_unrecoverable_4579_;
v___y_4570_ = v_evictCold_4581_;
v___y_4571_ = v___x_4580_;
v___y_4572_ = v_hasRem3_4583_;
v___y_4573_ = v_underFloor_4564_;
goto v___jp_4568_;
}
}
v___jp_4584_:
{
uint8_t v___x_4587_;
v___x_4587_ = lean_uint64_dec_le(v___y_4586_, v_freshScratchBytes_4485_);
if (v___x_4587_ == 0)
{
uint64_t v___x_4588_;
v___x_4588_ = lean_uint64_sub(v___y_4586_, v_freshScratchBytes_4485_);
v___y_4576_ = v___y_4586_;
v___y_4577_ = v___y_4585_;
v___y_4578_ = v___x_4588_;
goto v___jp_4575_;
}
else
{
uint64_t v___x_4589_;
v___x_4589_ = 0ULL;
v___y_4576_ = v___y_4586_;
v___y_4577_ = v___y_4585_;
v___y_4578_ = v___x_4589_;
goto v___jp_4575_;
}
}
v___jp_4590_:
{
uint8_t v___x_4592_;
v___x_4592_ = lean_uint64_dec_le(v___y_4591_, v_coldCacheBytes_4486_);
if (v___x_4592_ == 0)
{
uint64_t v___x_4593_;
v___x_4593_ = lean_uint64_sub(v___y_4591_, v_coldCacheBytes_4486_);
v___y_4585_ = v___y_4591_;
v___y_4586_ = v___x_4593_;
goto v___jp_4584_;
}
else
{
uint64_t v___x_4594_;
v___x_4594_ = 0ULL;
v___y_4585_ = v___y_4591_;
v___y_4586_ = v___x_4594_;
goto v___jp_4584_;
}
}
}
v___jp_4488_:
{
uint64_t v___x_4491_; uint64_t v___x_4492_; uint64_t v___x_4493_; uint64_t v___x_4494_; uint64_t v___x_4495_;
v___x_4491_ = lean_uint32_to_uint64(v___y_4489_);
v___x_4492_ = lean_uint32_to_uint64(v___y_4490_);
v___x_4493_ = 32ULL;
v___x_4494_ = lean_uint64_shift_left(v___x_4492_, v___x_4493_);
v___x_4495_ = lean_uint64_lor(v___x_4491_, v___x_4494_);
return v___x_4495_;
}
v___jp_4496_:
{
uint32_t v_lo32_4500_;
v_lo32_4500_ = lean_uint32_lor(v___y_4498_, v___y_4499_);
if (v___y_4497_ == 0)
{
uint32_t v___x_4501_;
v___x_4501_ = 6;
v___y_4489_ = v_lo32_4500_;
v___y_4490_ = v___x_4501_;
goto v___jp_4488_;
}
else
{
uint32_t v___x_4502_;
v___x_4502_ = 0;
v___y_4489_ = v_lo32_4500_;
v___y_4490_ = v___x_4502_;
goto v___jp_4488_;
}
}
v___jp_4503_:
{
uint32_t v___x_4508_;
v___x_4508_ = lean_uint32_lor(v___y_4506_, v___y_4507_);
if (v___y_4505_ == 0)
{
uint32_t v___x_4509_;
v___x_4509_ = 0;
v___y_4497_ = v___y_4504_;
v___y_4498_ = v___x_4508_;
v___y_4499_ = v___x_4509_;
goto v___jp_4496_;
}
else
{
uint32_t v___x_4510_;
v___x_4510_ = 4096;
v___y_4497_ = v___y_4504_;
v___y_4498_ = v___x_4508_;
v___y_4499_ = v___x_4510_;
goto v___jp_4496_;
}
}
v___jp_4511_:
{
uint32_t v___x_4517_;
v___x_4517_ = lean_uint32_lor(v___y_4512_, v___y_4516_);
if (v___y_4515_ == 0)
{
uint32_t v___x_4518_;
v___x_4518_ = 0;
v___y_4504_ = v___y_4513_;
v___y_4505_ = v___y_4514_;
v___y_4506_ = v___x_4517_;
v___y_4507_ = v___x_4518_;
goto v___jp_4503_;
}
else
{
uint32_t v___x_4519_;
v___x_4519_ = 2048;
v___y_4504_ = v___y_4513_;
v___y_4505_ = v___y_4514_;
v___y_4506_ = v___x_4517_;
v___y_4507_ = v___x_4519_;
goto v___jp_4503_;
}
}
v___jp_4520_:
{
uint32_t v___x_4526_;
v___x_4526_ = lean_uint32_lor(v___y_4521_, v___y_4525_);
if (v___y_4522_ == 0)
{
uint32_t v___x_4527_;
v___x_4527_ = 0;
v___y_4512_ = v___x_4526_;
v___y_4513_ = v___y_4522_;
v___y_4514_ = v___y_4523_;
v___y_4515_ = v___y_4524_;
v___y_4516_ = v___x_4527_;
goto v___jp_4511_;
}
else
{
uint32_t v___x_4528_;
v___x_4528_ = 1024;
v___y_4512_ = v___x_4526_;
v___y_4513_ = v___y_4522_;
v___y_4514_ = v___y_4523_;
v___y_4515_ = v___y_4524_;
v___y_4516_ = v___x_4528_;
goto v___jp_4511_;
}
}
v___jp_4529_:
{
uint32_t v___x_4535_; uint32_t v___x_4536_;
v___x_4535_ = 256;
v___x_4536_ = lean_uint32_lor(v___y_4534_, v___x_4535_);
if (v___y_4532_ == 0)
{
uint32_t v___x_4537_;
v___x_4537_ = 0;
v___y_4521_ = v___x_4536_;
v___y_4522_ = v___y_4530_;
v___y_4523_ = v___y_4531_;
v___y_4524_ = v___y_4533_;
v___y_4525_ = v___x_4537_;
goto v___jp_4520_;
}
else
{
uint32_t v___x_4538_;
v___x_4538_ = 512;
v___y_4521_ = v___x_4536_;
v___y_4522_ = v___y_4530_;
v___y_4523_ = v___y_4531_;
v___y_4524_ = v___y_4533_;
v___y_4525_ = v___x_4538_;
goto v___jp_4520_;
}
}
v___jp_4539_:
{
uint32_t v___x_4544_;
v___x_4544_ = 5;
v___y_4530_ = v___y_4540_;
v___y_4531_ = v___y_4541_;
v___y_4532_ = v___y_4542_;
v___y_4533_ = v___y_4543_;
v___y_4534_ = v___x_4544_;
goto v___jp_4529_;
}
v___jp_4545_:
{
if (v___y_4546_ == 0)
{
if (v___y_4548_ == 0)
{
uint32_t v___x_4550_;
v___x_4550_ = 1;
v___y_4530_ = v___y_4546_;
v___y_4531_ = v___y_4547_;
v___y_4532_ = v___y_4548_;
v___y_4533_ = v___y_4549_;
v___y_4534_ = v___x_4550_;
goto v___jp_4529_;
}
else
{
uint32_t v___x_4551_;
v___x_4551_ = 2;
v___y_4530_ = v___y_4546_;
v___y_4531_ = v___y_4547_;
v___y_4532_ = v___y_4548_;
v___y_4533_ = v___y_4549_;
v___y_4534_ = v___x_4551_;
goto v___jp_4529_;
}
}
else
{
uint32_t v___x_4552_;
v___x_4552_ = 3;
v___y_4530_ = v___y_4546_;
v___y_4531_ = v___y_4547_;
v___y_4532_ = v___y_4548_;
v___y_4533_ = v___y_4549_;
v___y_4534_ = v___x_4552_;
goto v___jp_4529_;
}
}
v___jp_4553_:
{
uint32_t v___x_4558_;
v___x_4558_ = 4;
v___y_4530_ = v___y_4554_;
v___y_4531_ = v___y_4555_;
v___y_4532_ = v___y_4556_;
v___y_4533_ = v___y_4557_;
v___y_4534_ = v___x_4558_;
goto v___jp_4529_;
}
v___jp_4559_:
{
if (v___y_4563_ == 0)
{
v___y_4540_ = v___y_4560_;
v___y_4541_ = v___y_4561_;
v___y_4542_ = v___y_4562_;
v___y_4543_ = v___y_4563_;
goto v___jp_4539_;
}
else
{
v___y_4554_ = v___y_4560_;
v___y_4555_ = v___y_4561_;
v___y_4556_ = v___y_4562_;
v___y_4557_ = v___y_4563_;
goto v___jp_4553_;
}
}
}
}

LEAN_EXPORT uint64_t orb_node_disk_admission_step(uint64_t v_freeBytes_4615_, uint64_t v_reservedBytes_4616_, uint64_t v_nodeFloorBytes_4617_, uint64_t v_coreFloorBytes_4618_, uint64_t v_hysteresisBytes_4619_, uint8_t v_nodePinnedPressure_4620_){
_start:
{
uint32_t v___y_4622_; uint32_t v___y_4623_; uint8_t v___y_4630_; uint8_t v___y_4631_; uint8_t v___y_4632_; uint32_t v___y_4633_; uint64_t v___y_4639_; uint8_t v___y_4640_; uint8_t v___y_4641_; uint8_t v___y_4642_; uint8_t v___y_4650_; uint8_t v___y_4651_; uint8_t v___y_4652_; uint64_t v___y_4655_; uint64_t v___y_4656_; uint64_t v___y_4666_; uint8_t v___x_4670_;
v___x_4670_ = lean_uint64_dec_le(v_coreFloorBytes_4618_, v_nodeFloorBytes_4617_);
if (v___x_4670_ == 0)
{
v___y_4666_ = v_coreFloorBytes_4618_;
goto v___jp_4665_;
}
else
{
v___y_4666_ = v_nodeFloorBytes_4617_;
goto v___jp_4665_;
}
v___jp_4621_:
{
uint64_t v___x_4624_; uint64_t v___x_4625_; uint64_t v___x_4626_; uint64_t v___x_4627_; uint64_t v___x_4628_;
v___x_4624_ = lean_uint32_to_uint64(v___y_4623_);
v___x_4625_ = lean_uint32_to_uint64(v___y_4622_);
v___x_4626_ = 32ULL;
v___x_4627_ = lean_uint64_shift_left(v___x_4625_, v___x_4626_);
v___x_4628_ = lean_uint64_lor(v___x_4624_, v___x_4627_);
return v___x_4628_;
}
v___jp_4629_:
{
if (v___y_4632_ == 0)
{
if (v___y_4631_ == 0)
{
uint32_t v___x_4634_;
v___x_4634_ = 0;
v___y_4622_ = v___y_4633_;
v___y_4623_ = v___x_4634_;
goto v___jp_4621_;
}
else
{
if (v___y_4630_ == 0)
{
uint32_t v___x_4635_;
v___x_4635_ = 257;
v___y_4622_ = v___y_4633_;
v___y_4623_ = v___x_4635_;
goto v___jp_4621_;
}
else
{
uint32_t v___x_4636_;
v___x_4636_ = 769;
v___y_4622_ = v___y_4633_;
v___y_4623_ = v___x_4636_;
goto v___jp_4621_;
}
}
}
else
{
uint32_t v___x_4637_;
v___x_4637_ = 2;
v___y_4622_ = v___y_4633_;
v___y_4623_ = v___x_4637_;
goto v___jp_4621_;
}
}
v___jp_4638_:
{
uint64_t v___x_4643_; uint64_t v_rawHeadroomGiB_4644_; uint64_t v___x_4645_; uint8_t v___x_4646_;
v___x_4643_ = 30ULL;
v_rawHeadroomGiB_4644_ = lean_uint64_shift_right(v___y_4639_, v___x_4643_);
v___x_4645_ = 4294967295ULL;
v___x_4646_ = lean_uint64_dec_lt(v___x_4645_, v_rawHeadroomGiB_4644_);
if (v___x_4646_ == 0)
{
uint32_t v___x_4647_;
v___x_4647_ = lean_uint64_to_uint32(v_rawHeadroomGiB_4644_);
v___y_4630_ = v___y_4642_;
v___y_4631_ = v___y_4640_;
v___y_4632_ = v___y_4641_;
v___y_4633_ = v___x_4647_;
goto v___jp_4629_;
}
else
{
uint32_t v___x_4648_;
v___x_4648_ = 4294967295;
v___y_4630_ = v___y_4642_;
v___y_4631_ = v___y_4640_;
v___y_4632_ = v___y_4641_;
v___y_4633_ = v___x_4648_;
goto v___jp_4629_;
}
}
v___jp_4649_:
{
uint64_t v___x_4653_;
v___x_4653_ = 0ULL;
v___y_4639_ = v___x_4653_;
v___y_4640_ = v___y_4650_;
v___y_4641_ = v___y_4651_;
v___y_4642_ = v___y_4652_;
goto v___jp_4638_;
}
v___jp_4654_:
{
uint8_t v___x_4657_; uint8_t v___x_4658_;
v___x_4657_ = 0;
v___x_4658_ = lean_uint8_dec_eq(v_nodePinnedPressure_4620_, v___x_4657_);
if (v___x_4658_ == 0)
{
uint8_t v___x_4659_; uint8_t v_aboveFloor_4660_;
v___x_4659_ = 1;
v_aboveFloor_4660_ = lean_uint64_dec_le(v___y_4655_, v___y_4656_);
v___y_4650_ = v_aboveFloor_4660_;
v___y_4651_ = v___x_4659_;
v___y_4652_ = v___x_4658_;
goto v___jp_4649_;
}
else
{
uint8_t v___x_4661_; uint8_t v_aboveFloor_4662_;
v___x_4661_ = 0;
v_aboveFloor_4662_ = lean_uint64_dec_le(v___y_4655_, v___y_4656_);
if (v_aboveFloor_4662_ == 0)
{
v___y_4650_ = v_aboveFloor_4662_;
v___y_4651_ = v___x_4661_;
v___y_4652_ = v_aboveFloor_4662_;
goto v___jp_4649_;
}
else
{
uint64_t v___x_4663_; uint8_t v___x_4664_;
v___x_4663_ = lean_uint64_sub(v___y_4656_, v___y_4655_);
v___x_4664_ = lean_uint64_dec_lt(v___x_4663_, v_hysteresisBytes_4619_);
v___y_4639_ = v___x_4663_;
v___y_4640_ = v_aboveFloor_4662_;
v___y_4641_ = v___x_4661_;
v___y_4642_ = v___x_4664_;
goto v___jp_4638_;
}
}
}
v___jp_4665_:
{
uint8_t v___x_4667_;
v___x_4667_ = lean_uint64_dec_le(v_reservedBytes_4616_, v_freeBytes_4615_);
if (v___x_4667_ == 0)
{
uint64_t v___x_4668_;
v___x_4668_ = 0ULL;
v___y_4655_ = v___y_4666_;
v___y_4656_ = v___x_4668_;
goto v___jp_4654_;
}
else
{
uint64_t v___x_4669_;
v___x_4669_ = lean_uint64_sub(v_freeBytes_4615_, v_reservedBytes_4616_);
v___y_4655_ = v___y_4666_;
v___y_4656_ = v___x_4669_;
goto v___jp_4654_;
}
}
}
}

LEAN_EXPORT uint32_t orb_vm_lifecycle_step(uint8_t v_ownerClass_4685_, uint8_t v_busy_4686_, uint8_t v_ttlExpired_4687_, uint8_t v_graceOrIdleElapsed_4688_, uint8_t v_workingIdleEnabled_4689_, uint8_t v_supportsFreeStop_4690_, uint8_t v_minDeletePending_4691_){
_start:
{
uint8_t v___x_4692_; uint8_t v___x_4693_;
v___x_4692_ = 1;
v___x_4693_ = lean_uint8_dec_eq(v_ttlExpired_4687_, v___x_4692_);
if (v___x_4693_ == 0)
{
uint8_t v___x_4694_;
v___x_4694_ = lean_uint8_dec_eq(v_busy_4686_, v___x_4692_);
if (v___x_4694_ == 0)
{
uint8_t v___x_4695_; uint8_t v___x_4696_;
v___x_4695_ = 0;
v___x_4696_ = lean_uint8_dec_eq(v_ownerClass_4685_, v___x_4695_);
if (v___x_4696_ == 0)
{
uint8_t v___x_4697_;
v___x_4697_ = lean_uint8_dec_eq(v_ownerClass_4685_, v___x_4692_);
if (v___x_4697_ == 0)
{
uint8_t v___x_4698_; uint8_t v___x_4699_;
v___x_4698_ = 2;
v___x_4699_ = lean_uint8_dec_eq(v_ownerClass_4685_, v___x_4698_);
if (v___x_4699_ == 0)
{
uint8_t v___x_4700_;
v___x_4700_ = lean_uint8_dec_eq(v_graceOrIdleElapsed_4688_, v___x_4695_);
if (v___x_4700_ == 0)
{
uint8_t v___x_4701_;
v___x_4701_ = lean_uint8_dec_eq(v_minDeletePending_4691_, v___x_4692_);
if (v___x_4701_ == 0)
{
uint32_t v___x_4702_;
v___x_4702_ = 259;
return v___x_4702_;
}
else
{
uint32_t v___x_4703_;
v___x_4703_ = 65537;
return v___x_4703_;
}
}
else
{
uint32_t v___x_4704_;
v___x_4704_ = 1;
return v___x_4704_;
}
}
else
{
uint8_t v___x_4705_;
v___x_4705_ = lean_uint8_dec_eq(v_graceOrIdleElapsed_4688_, v___x_4695_);
if (v___x_4705_ == 0)
{
uint8_t v___x_4706_;
v___x_4706_ = lean_uint8_dec_eq(v_supportsFreeStop_4690_, v___x_4692_);
if (v___x_4706_ == 0)
{
uint8_t v___x_4707_;
v___x_4707_ = lean_uint8_dec_eq(v_minDeletePending_4691_, v___x_4692_);
if (v___x_4707_ == 0)
{
uint32_t v___x_4708_;
v___x_4708_ = 259;
return v___x_4708_;
}
else
{
uint32_t v___x_4709_;
v___x_4709_ = 65537;
return v___x_4709_;
}
}
else
{
uint32_t v___x_4710_;
v___x_4710_ = 258;
return v___x_4710_;
}
}
else
{
uint32_t v___x_4711_;
v___x_4711_ = 1;
return v___x_4711_;
}
}
}
else
{
uint8_t v___x_4712_;
v___x_4712_ = lean_uint8_dec_eq(v_workingIdleEnabled_4689_, v___x_4695_);
if (v___x_4712_ == 0)
{
uint8_t v___x_4713_;
v___x_4713_ = lean_uint8_dec_eq(v_graceOrIdleElapsed_4688_, v___x_4695_);
if (v___x_4713_ == 0)
{
uint8_t v___x_4714_;
v___x_4714_ = lean_uint8_dec_eq(v_minDeletePending_4691_, v___x_4692_);
if (v___x_4714_ == 0)
{
uint32_t v___x_4715_;
v___x_4715_ = 259;
return v___x_4715_;
}
else
{
uint32_t v___x_4716_;
v___x_4716_ = 65537;
return v___x_4716_;
}
}
else
{
uint32_t v___x_4717_;
v___x_4717_ = 1;
return v___x_4717_;
}
}
else
{
uint32_t v___x_4718_;
v___x_4718_ = 0;
return v___x_4718_;
}
}
}
else
{
uint32_t v___x_4719_;
v___x_4719_ = 0;
return v___x_4719_;
}
}
else
{
uint32_t v___x_4720_;
v___x_4720_ = 0;
return v___x_4720_;
}
}
else
{
uint8_t v___x_4721_;
v___x_4721_ = lean_uint8_dec_eq(v_minDeletePending_4691_, v___x_4692_);
if (v___x_4721_ == 0)
{
uint32_t v___x_4722_;
v___x_4722_ = 259;
return v___x_4722_;
}
else
{
uint32_t v___x_4723_;
v___x_4723_ = 65537;
return v___x_4723_;
}
}
}
}

LEAN_EXPORT uint32_t orb_vm_claim_step(uint8_t v_isLive_4740_, uint8_t v_sameTenant_4741_, uint8_t v_ownerNone_4742_, uint8_t v_ownerInLineage_4743_){
_start:
{
uint8_t v___x_4744_; uint8_t v___x_4745_;
v___x_4744_ = 1;
v___x_4745_ = lean_uint8_dec_eq(v_isLive_4740_, v___x_4744_);
if (v___x_4745_ == 0)
{
uint32_t v___x_4746_;
v___x_4746_ = 512;
return v___x_4746_;
}
else
{
uint8_t v___x_4747_;
v___x_4747_ = lean_uint8_dec_eq(v_sameTenant_4741_, v___x_4744_);
if (v___x_4747_ == 0)
{
uint32_t v___x_4748_;
v___x_4748_ = 512;
return v___x_4748_;
}
else
{
uint8_t v___x_4749_;
v___x_4749_ = lean_uint8_dec_eq(v_ownerNone_4742_, v___x_4744_);
if (v___x_4749_ == 0)
{
uint8_t v___x_4750_;
v___x_4750_ = lean_uint8_dec_eq(v_ownerInLineage_4743_, v___x_4744_);
if (v___x_4750_ == 0)
{
uint32_t v___x_4751_;
v___x_4751_ = 512;
return v___x_4751_;
}
else
{
uint32_t v___x_4752_;
v___x_4752_ = 257;
return v___x_4752_;
}
}
else
{
uint32_t v___x_4753_;
v___x_4753_ = 257;
return v___x_4753_;
}
}
}
}
}

LEAN_EXPORT uint32_t orb_compute_secret_gate(uint8_t v_isCoreReservedComputeKey_4764_, uint8_t v_callerOnManagedNode_4765_, uint8_t v_isAllowlistedManagedSecret_4766_, uint8_t v_operatorBreakGlass_4767_){
_start:
{
uint8_t v___x_4768_; uint8_t v___x_4776_;
v___x_4768_ = 1;
v___x_4776_ = lean_uint8_dec_eq(v_isCoreReservedComputeKey_4764_, v___x_4768_);
if (v___x_4776_ == 0)
{
goto v___jp_4769_;
}
else
{
uint8_t v___x_4777_; uint8_t v___x_4778_;
v___x_4777_ = 0;
v___x_4778_ = lean_uint8_dec_eq(v_operatorBreakGlass_4767_, v___x_4777_);
if (v___x_4778_ == 0)
{
goto v___jp_4769_;
}
else
{
uint32_t v___x_4779_;
v___x_4779_ = 512;
return v___x_4779_;
}
}
v___jp_4769_:
{
uint8_t v___x_4770_;
v___x_4770_ = lean_uint8_dec_eq(v_callerOnManagedNode_4765_, v___x_4768_);
if (v___x_4770_ == 0)
{
uint32_t v___x_4771_;
v___x_4771_ = 257;
return v___x_4771_;
}
else
{
uint8_t v___x_4772_; uint8_t v___x_4773_;
v___x_4772_ = 0;
v___x_4773_ = lean_uint8_dec_eq(v_isAllowlistedManagedSecret_4766_, v___x_4772_);
if (v___x_4773_ == 0)
{
uint32_t v___x_4774_;
v___x_4774_ = 257;
return v___x_4774_;
}
else
{
uint32_t v___x_4775_;
v___x_4775_ = 512;
return v___x_4775_;
}
}
}
}
}

LEAN_EXPORT uint64_t orb_wire_apply_patch_step(uint64_t v_currentRev_4790_, uint64_t v_incomingRev_4791_, uint8_t v_currentHasVal_4792_, uint32_t v_currentVal_4793_, uint8_t v_presence_4794_, uint32_t v_incomingVal_4795_){
_start:
{
uint32_t v___y_4797_; uint32_t v___y_4798_; uint8_t v___x_4804_; uint32_t v___y_4806_; uint8_t v___y_4807_; uint8_t v___y_4808_; uint32_t v___y_4809_; uint32_t v___y_4815_; uint32_t v___y_4816_; uint8_t v___x_4830_; uint32_t v___y_4832_;
v___x_4804_ = 1;
v___x_4830_ = lean_uint8_dec_eq(v_currentHasVal_4792_, v___x_4804_);
if (v___x_4830_ == 0)
{
uint32_t v___x_4834_;
v___x_4834_ = 0;
v___y_4832_ = v___x_4834_;
goto v___jp_4831_;
}
else
{
uint32_t v___x_4835_;
v___x_4835_ = 512;
v___y_4832_ = v___x_4835_;
goto v___jp_4831_;
}
v___jp_4796_:
{
uint64_t v___x_4799_; uint64_t v___x_4800_; uint64_t v___x_4801_; uint64_t v___x_4802_; uint64_t v___x_4803_;
v___x_4799_ = lean_uint32_to_uint64(v___y_4797_);
v___x_4800_ = lean_uint32_to_uint64(v___y_4798_);
v___x_4801_ = 32ULL;
v___x_4802_ = lean_uint64_shift_left(v___x_4800_, v___x_4801_);
v___x_4803_ = lean_uint64_lor(v___x_4799_, v___x_4802_);
return v___x_4803_;
}
v___jp_4805_:
{
if (v___y_4807_ == 0)
{
v___y_4797_ = v___y_4809_;
v___y_4798_ = v___y_4806_;
goto v___jp_4796_;
}
else
{
if (v___y_4808_ == 0)
{
v___y_4797_ = v___y_4809_;
v___y_4798_ = v___y_4806_;
goto v___jp_4796_;
}
else
{
uint8_t v___x_4810_; uint8_t v___x_4811_;
v___x_4810_ = 0;
v___x_4811_ = lean_uint8_dec_eq(v_presence_4794_, v___x_4810_);
if (v___x_4811_ == 0)
{
uint8_t v___x_4812_;
v___x_4812_ = lean_uint8_dec_eq(v_presence_4794_, v___x_4804_);
if (v___x_4812_ == 0)
{
uint32_t v___x_4813_;
v___x_4813_ = 0;
v___y_4797_ = v___y_4809_;
v___y_4798_ = v___x_4813_;
goto v___jp_4796_;
}
else
{
v___y_4797_ = v___y_4809_;
v___y_4798_ = v_incomingVal_4795_;
goto v___jp_4796_;
}
}
else
{
v___y_4797_ = v___y_4809_;
v___y_4798_ = v___y_4806_;
goto v___jp_4796_;
}
}
}
}
v___jp_4814_:
{
uint8_t v___x_4817_; uint8_t v_validPresence_4818_; uint8_t v_freshRev_4819_;
v___x_4817_ = 2;
v_validPresence_4818_ = lean_uint8_dec_le(v_presence_4794_, v___x_4817_);
v_freshRev_4819_ = lean_uint64_dec_lt(v_currentRev_4790_, v_incomingRev_4791_);
if (v_validPresence_4818_ == 0)
{
uint32_t v___x_4820_;
v___x_4820_ = 0;
v___y_4806_ = v___y_4816_;
v___y_4807_ = v_validPresence_4818_;
v___y_4808_ = v_freshRev_4819_;
v___y_4809_ = v___x_4820_;
goto v___jp_4805_;
}
else
{
if (v_freshRev_4819_ == 0)
{
uint32_t v___x_4821_; uint32_t v___x_4822_;
v___x_4821_ = 2;
v___x_4822_ = lean_uint32_lor(v___x_4821_, v___y_4815_);
v___y_4806_ = v___y_4816_;
v___y_4807_ = v_validPresence_4818_;
v___y_4808_ = v_freshRev_4819_;
v___y_4809_ = v___x_4822_;
goto v___jp_4805_;
}
else
{
uint8_t v___x_4823_; uint8_t v___x_4824_;
v___x_4823_ = 0;
v___x_4824_ = lean_uint8_dec_eq(v_presence_4794_, v___x_4823_);
if (v___x_4824_ == 0)
{
uint8_t v___x_4825_;
v___x_4825_ = lean_uint8_dec_eq(v_presence_4794_, v___x_4804_);
if (v___x_4825_ == 0)
{
uint32_t v___x_4826_;
v___x_4826_ = 260;
v___y_4806_ = v___y_4816_;
v___y_4807_ = v_validPresence_4818_;
v___y_4808_ = v_freshRev_4819_;
v___y_4809_ = v___x_4826_;
goto v___jp_4805_;
}
else
{
uint32_t v___x_4827_;
v___x_4827_ = 769;
v___y_4806_ = v___y_4816_;
v___y_4807_ = v_validPresence_4818_;
v___y_4808_ = v_freshRev_4819_;
v___y_4809_ = v___x_4827_;
goto v___jp_4805_;
}
}
else
{
uint32_t v___x_4828_; uint32_t v___x_4829_;
v___x_4828_ = 259;
v___x_4829_ = lean_uint32_lor(v___x_4828_, v___y_4815_);
v___y_4806_ = v___y_4816_;
v___y_4807_ = v_validPresence_4818_;
v___y_4808_ = v_freshRev_4819_;
v___y_4809_ = v___x_4829_;
goto v___jp_4805_;
}
}
}
}
v___jp_4831_:
{
if (v___x_4830_ == 0)
{
uint32_t v___x_4833_;
v___x_4833_ = 0;
v___y_4815_ = v___y_4832_;
v___y_4816_ = v___x_4833_;
goto v___jp_4814_;
}
else
{
v___y_4815_ = v___y_4832_;
v___y_4816_ = v_currentVal_4793_;
goto v___jp_4814_;
}
}
}
}

LEAN_EXPORT uint64_t orb_wire_machine_step(uint32_t v_schemaId_4850_, uint64_t v_stateRev_4851_, uint64_t v_eventSeq_4852_, uint8_t v_effectKind_4853_, uint8_t v_effectAdmitted_4854_, uint32_t v_outCap_4855_, uint32_t v_requiredOutBytes_4856_){
_start:
{
uint32_t v___y_4858_; uint32_t v___y_4859_; uint32_t v_curRev32_4865_; uint8_t v_capOk_4866_; uint8_t v___y_4868_; uint8_t v___y_4869_; uint8_t v___y_4870_; uint32_t v___y_4871_; uint8_t v___y_4874_; uint8_t v___y_4875_; uint8_t v___y_4876_; uint32_t v___y_4877_; uint8_t v___y_4885_; uint8_t v___y_4886_; uint8_t v___y_4887_; uint8_t v___y_4893_; uint32_t v___x_4899_; uint8_t v___x_4900_;
v_curRev32_4865_ = lean_uint64_to_uint32(v_stateRev_4851_);
v_capOk_4866_ = lean_uint32_dec_le(v_requiredOutBytes_4856_, v_outCap_4855_);
v___x_4899_ = 1;
v___x_4900_ = lean_uint32_dec_le(v___x_4899_, v_schemaId_4850_);
if (v___x_4900_ == 0)
{
v___y_4893_ = v___x_4900_;
goto v___jp_4892_;
}
else
{
uint32_t v___x_4901_; uint8_t v___x_4902_;
v___x_4901_ = 2;
v___x_4902_ = lean_uint32_dec_le(v_schemaId_4850_, v___x_4901_);
v___y_4893_ = v___x_4902_;
goto v___jp_4892_;
}
v___jp_4857_:
{
uint64_t v___x_4860_; uint64_t v___x_4861_; uint64_t v___x_4862_; uint64_t v___x_4863_; uint64_t v___x_4864_;
v___x_4860_ = lean_uint32_to_uint64(v___y_4858_);
v___x_4861_ = lean_uint32_to_uint64(v___y_4859_);
v___x_4862_ = 32ULL;
v___x_4863_ = lean_uint64_shift_left(v___x_4861_, v___x_4862_);
v___x_4864_ = lean_uint64_lor(v___x_4860_, v___x_4863_);
return v___x_4864_;
}
v___jp_4867_:
{
if (v_capOk_4866_ == 0)
{
v___y_4858_ = v___y_4871_;
v___y_4859_ = v_curRev32_4865_;
goto v___jp_4857_;
}
else
{
if (v___y_4868_ == 0)
{
v___y_4858_ = v___y_4871_;
v___y_4859_ = v_curRev32_4865_;
goto v___jp_4857_;
}
else
{
if (v___y_4869_ == 0)
{
v___y_4858_ = v___y_4871_;
v___y_4859_ = v_curRev32_4865_;
goto v___jp_4857_;
}
else
{
if (v___y_4870_ == 0)
{
v___y_4858_ = v___y_4871_;
v___y_4859_ = v_curRev32_4865_;
goto v___jp_4857_;
}
else
{
uint32_t v___x_4872_;
v___x_4872_ = lean_uint64_to_uint32(v_eventSeq_4852_);
v___y_4858_ = v___y_4871_;
v___y_4859_ = v___x_4872_;
goto v___jp_4857_;
}
}
}
}
}
v___jp_4873_:
{
if (v_capOk_4866_ == 0)
{
uint32_t v___x_4878_;
v___x_4878_ = 5;
v___y_4868_ = v___y_4874_;
v___y_4869_ = v___y_4875_;
v___y_4870_ = v___y_4876_;
v___y_4871_ = v___x_4878_;
goto v___jp_4867_;
}
else
{
if (v___y_4874_ == 0)
{
uint32_t v___x_4879_;
v___x_4879_ = 2;
v___y_4868_ = v___y_4874_;
v___y_4869_ = v___y_4875_;
v___y_4870_ = v___y_4876_;
v___y_4871_ = v___x_4879_;
goto v___jp_4867_;
}
else
{
if (v___y_4875_ == 0)
{
uint32_t v___x_4880_;
v___x_4880_ = 3;
v___y_4868_ = v___y_4874_;
v___y_4869_ = v___y_4875_;
v___y_4870_ = v___y_4876_;
v___y_4871_ = v___x_4880_;
goto v___jp_4867_;
}
else
{
if (v___y_4876_ == 0)
{
uint32_t v___x_4881_;
v___x_4881_ = 4;
v___y_4868_ = v___y_4874_;
v___y_4869_ = v___y_4875_;
v___y_4870_ = v___y_4876_;
v___y_4871_ = v___x_4881_;
goto v___jp_4867_;
}
else
{
uint32_t v___x_4882_; uint32_t v___x_4883_;
v___x_4882_ = 257;
v___x_4883_ = lean_uint32_lor(v___x_4882_, v___y_4877_);
v___y_4868_ = v___y_4874_;
v___y_4869_ = v___y_4875_;
v___y_4870_ = v___y_4876_;
v___y_4871_ = v___x_4883_;
goto v___jp_4867_;
}
}
}
}
}
v___jp_4884_:
{
uint8_t v___x_4888_; uint8_t v___x_4889_;
v___x_4888_ = 0;
v___x_4889_ = lean_uint8_dec_eq(v_effectKind_4853_, v___x_4888_);
if (v___x_4889_ == 0)
{
uint32_t v___x_4890_;
v___x_4890_ = 512;
v___y_4874_ = v___y_4885_;
v___y_4875_ = v___y_4886_;
v___y_4876_ = v___y_4887_;
v___y_4877_ = v___x_4890_;
goto v___jp_4873_;
}
else
{
uint32_t v___x_4891_;
v___x_4891_ = 0;
v___y_4874_ = v___y_4885_;
v___y_4875_ = v___y_4886_;
v___y_4876_ = v___y_4887_;
v___y_4877_ = v___x_4891_;
goto v___jp_4873_;
}
}
v___jp_4892_:
{
uint8_t v_seqFresh_4894_; uint8_t v___x_4895_; uint8_t v___x_4896_;
v_seqFresh_4894_ = lean_uint64_dec_lt(v_stateRev_4851_, v_eventSeq_4852_);
v___x_4895_ = 1;
v___x_4896_ = lean_uint8_dec_eq(v_effectAdmitted_4854_, v___x_4895_);
if (v___x_4896_ == 0)
{
v___y_4885_ = v___y_4893_;
v___y_4886_ = v_seqFresh_4894_;
v___y_4887_ = v___x_4896_;
goto v___jp_4884_;
}
else
{
uint8_t v___x_4897_; uint8_t v___x_4898_;
v___x_4897_ = 5;
v___x_4898_ = lean_uint8_dec_le(v_effectKind_4853_, v___x_4897_);
v___y_4885_ = v___y_4893_;
v___y_4886_ = v_seqFresh_4894_;
v___y_4887_ = v___x_4898_;
goto v___jp_4884_;
}
}
}
}

LEAN_EXPORT uint64_t orb_hierarchy_merge_step(uint64_t v_currentEpoch_4919_, uint64_t v_incomingEpoch_4920_, uint64_t v_archiveEpoch_4921_, uint8_t v_curArchived_4922_, uint8_t v_curSuperseded_4923_, uint8_t v_isPartialPatch_4924_, uint8_t v_parentPresence_4925_, uint32_t v_curParentOrd_4926_, uint32_t v_incParentOrd_4927_, uint8_t v_incArchive_4928_, uint8_t v_incUnarchive_4929_, uint8_t v_incSupersede_4930_){
_start:
{
uint32_t v___y_4932_; uint32_t v___y_4933_; uint32_t v___y_4934_; uint32_t v___y_4935_; uint32_t v___y_4936_; uint32_t v___y_4946_; uint32_t v___y_4947_; uint32_t v___y_4948_; uint32_t v___y_4949_; uint32_t v___y_4952_; uint32_t v___y_4953_; uint32_t v___y_4954_; uint8_t v___y_4957_; uint32_t v___y_4958_; uint8_t v___y_4959_; uint32_t v___y_4960_; uint8_t v___y_4961_; uint32_t v___y_4962_; uint8_t v___y_4967_; uint8_t v___y_4968_; uint8_t v___y_4969_; uint32_t v___y_4970_; uint8_t v___y_4971_; uint32_t v___y_4972_; uint8_t v___y_4976_; uint8_t v___y_4977_; uint8_t v___y_4978_; uint8_t v___y_4979_; uint8_t v___y_4980_; uint32_t v___y_4981_; uint8_t v___x_4984_; uint8_t v___y_4986_; uint8_t v___y_4987_; uint8_t v___y_4988_; uint8_t v___y_4989_; uint8_t v___y_4990_; uint8_t v___y_4991_; uint8_t v___y_4992_; uint8_t v___y_4993_; uint8_t v___y_4994_; uint8_t v___y_5003_; uint8_t v___y_5004_; uint8_t v___y_5005_; uint8_t v___y_5006_; uint8_t v___y_5007_; uint8_t v___y_5008_; uint8_t v___y_5009_; uint8_t v___y_5010_; uint8_t v___y_5011_; uint8_t v___x_5013_; uint8_t v___y_5015_; uint8_t v___y_5016_; uint8_t v___y_5017_; uint8_t v___y_5018_; uint8_t v___y_5019_; uint8_t v___y_5020_; uint8_t v___y_5021_; uint8_t v___y_5022_; uint8_t v___y_5023_; uint8_t v___y_5026_; uint8_t v___y_5027_; uint8_t v___y_5028_; uint8_t v___y_5029_; uint8_t v___y_5030_; uint8_t v___y_5031_; uint8_t v___y_5032_; uint8_t v___y_5033_; uint8_t v___y_5034_; uint8_t v___y_5036_; uint8_t v___y_5037_; uint8_t v___y_5038_; uint8_t v___y_5039_; uint8_t v___y_5040_; uint8_t v___y_5041_; uint8_t v___y_5042_; uint8_t v___y_5043_; uint8_t v___y_5044_; uint8_t v___y_5048_;
v___x_4984_ = 1;
v___x_5013_ = lean_uint8_dec_eq(v_curSuperseded_4923_, v___x_4984_);
if (v___x_5013_ == 0)
{
uint8_t v___x_5059_;
v___x_5059_ = lean_uint8_dec_eq(v_incSupersede_4930_, v___x_4984_);
v___y_5048_ = v___x_5059_;
goto v___jp_5047_;
}
else
{
v___y_5048_ = v___x_5013_;
goto v___jp_5047_;
}
v___jp_4931_:
{
uint32_t v___x_4937_; uint32_t v___x_4938_; uint32_t v_lo32_4939_; uint64_t v___x_4940_; uint64_t v___x_4941_; uint64_t v___x_4942_; uint64_t v___x_4943_; uint64_t v___x_4944_;
v___x_4937_ = lean_uint32_lor(v___y_4936_, v___y_4932_);
v___x_4938_ = lean_uint32_lor(v___x_4937_, v___y_4934_);
v_lo32_4939_ = lean_uint32_lor(v___x_4938_, v___y_4933_);
v___x_4940_ = lean_uint32_to_uint64(v_lo32_4939_);
v___x_4941_ = lean_uint32_to_uint64(v___y_4935_);
v___x_4942_ = 32ULL;
v___x_4943_ = lean_uint64_shift_left(v___x_4941_, v___x_4942_);
v___x_4944_ = lean_uint64_lor(v___x_4940_, v___x_4943_);
return v___x_4944_;
}
v___jp_4945_:
{
uint32_t v___x_4950_;
v___x_4950_ = 257;
v___y_4932_ = v___y_4946_;
v___y_4933_ = v___y_4949_;
v___y_4934_ = v___y_4947_;
v___y_4935_ = v___y_4948_;
v___y_4936_ = v___x_4950_;
goto v___jp_4931_;
}
v___jp_4951_:
{
uint32_t v___x_4955_;
v___x_4955_ = 0;
v___y_4946_ = v___y_4952_;
v___y_4947_ = v___y_4953_;
v___y_4948_ = v___y_4954_;
v___y_4949_ = v___x_4955_;
goto v___jp_4945_;
}
v___jp_4956_:
{
if (v___y_4957_ == 0)
{
uint32_t v___x_4963_; uint32_t v___x_4964_;
v___x_4963_ = 0;
v___x_4964_ = 2;
v___y_4932_ = v___y_4958_;
v___y_4933_ = v___x_4963_;
v___y_4934_ = v___y_4962_;
v___y_4935_ = v___y_4960_;
v___y_4936_ = v___x_4964_;
goto v___jp_4931_;
}
else
{
if (v___y_4961_ == 0)
{
v___y_4952_ = v___y_4958_;
v___y_4953_ = v___y_4962_;
v___y_4954_ = v___y_4960_;
goto v___jp_4951_;
}
else
{
if (v___y_4959_ == 0)
{
v___y_4952_ = v___y_4958_;
v___y_4953_ = v___y_4962_;
v___y_4954_ = v___y_4960_;
goto v___jp_4951_;
}
else
{
uint32_t v___x_4965_;
v___x_4965_ = 2048;
v___y_4946_ = v___y_4958_;
v___y_4947_ = v___y_4962_;
v___y_4948_ = v___y_4960_;
v___y_4949_ = v___x_4965_;
goto v___jp_4945_;
}
}
}
}
v___jp_4966_:
{
if (v___y_4969_ == 0)
{
uint32_t v___x_4973_;
v___x_4973_ = 0;
v___y_4957_ = v___y_4967_;
v___y_4958_ = v___y_4972_;
v___y_4959_ = v___y_4968_;
v___y_4960_ = v___y_4970_;
v___y_4961_ = v___y_4971_;
v___y_4962_ = v___x_4973_;
goto v___jp_4956_;
}
else
{
uint32_t v___x_4974_;
v___x_4974_ = 1024;
v___y_4957_ = v___y_4967_;
v___y_4958_ = v___y_4972_;
v___y_4959_ = v___y_4968_;
v___y_4960_ = v___y_4970_;
v___y_4961_ = v___y_4971_;
v___y_4962_ = v___x_4974_;
goto v___jp_4956_;
}
}
v___jp_4975_:
{
if (v___y_4977_ == 0)
{
uint32_t v___x_4982_;
v___x_4982_ = 0;
v___y_4967_ = v___y_4976_;
v___y_4968_ = v___y_4978_;
v___y_4969_ = v___y_4979_;
v___y_4970_ = v___y_4981_;
v___y_4971_ = v___y_4980_;
v___y_4972_ = v___x_4982_;
goto v___jp_4966_;
}
else
{
uint32_t v___x_4983_;
v___x_4983_ = 512;
v___y_4967_ = v___y_4976_;
v___y_4968_ = v___y_4978_;
v___y_4969_ = v___y_4979_;
v___y_4970_ = v___y_4981_;
v___y_4971_ = v___y_4980_;
v___y_4972_ = v___x_4983_;
goto v___jp_4966_;
}
}
v___jp_4985_:
{
if (v___y_4992_ == 0)
{
v___y_4976_ = v___y_4992_;
v___y_4977_ = v___y_4987_;
v___y_4978_ = v___y_4990_;
v___y_4979_ = v___y_4991_;
v___y_4980_ = v___y_4993_;
v___y_4981_ = v_curParentOrd_4926_;
goto v___jp_4975_;
}
else
{
if (v___y_4986_ == 0)
{
v___y_4976_ = v___y_4986_;
v___y_4977_ = v___y_4987_;
v___y_4978_ = v___y_4990_;
v___y_4979_ = v___y_4991_;
v___y_4980_ = v___y_4993_;
v___y_4981_ = v_curParentOrd_4926_;
goto v___jp_4975_;
}
else
{
if (v___y_4989_ == 0)
{
if (v___y_4994_ == 0)
{
if (v___y_4988_ == 0)
{
uint8_t v___x_4995_;
v___x_4995_ = lean_uint8_dec_eq(v_parentPresence_4925_, v___x_4984_);
if (v___x_4995_ == 0)
{
uint32_t v___x_4996_;
v___x_4996_ = 0;
v___y_4976_ = v___y_4986_;
v___y_4977_ = v___y_4987_;
v___y_4978_ = v___y_4990_;
v___y_4979_ = v___y_4991_;
v___y_4980_ = v___y_4993_;
v___y_4981_ = v___x_4996_;
goto v___jp_4975_;
}
else
{
v___y_4976_ = v___y_4986_;
v___y_4977_ = v___y_4987_;
v___y_4978_ = v___y_4990_;
v___y_4979_ = v___y_4991_;
v___y_4980_ = v___y_4993_;
v___y_4981_ = v_incParentOrd_4927_;
goto v___jp_4975_;
}
}
else
{
uint8_t v___x_4997_; uint8_t v___x_4998_;
v___x_4997_ = 0;
v___x_4998_ = lean_uint8_dec_eq(v_parentPresence_4925_, v___x_4997_);
if (v___x_4998_ == 0)
{
uint8_t v___x_4999_;
v___x_4999_ = lean_uint8_dec_eq(v_parentPresence_4925_, v___x_4984_);
if (v___x_4999_ == 0)
{
uint32_t v___x_5000_;
v___x_5000_ = 0;
v___y_4976_ = v___y_4986_;
v___y_4977_ = v___y_4987_;
v___y_4978_ = v___y_4990_;
v___y_4979_ = v___y_4991_;
v___y_4980_ = v___y_4993_;
v___y_4981_ = v___x_5000_;
goto v___jp_4975_;
}
else
{
v___y_4976_ = v___y_4986_;
v___y_4977_ = v___y_4987_;
v___y_4978_ = v___y_4990_;
v___y_4979_ = v___y_4991_;
v___y_4980_ = v___y_4993_;
v___y_4981_ = v_incParentOrd_4927_;
goto v___jp_4975_;
}
}
else
{
v___y_4976_ = v___y_4986_;
v___y_4977_ = v___y_4987_;
v___y_4978_ = v___y_4990_;
v___y_4979_ = v___y_4991_;
v___y_4980_ = v___y_4993_;
v___y_4981_ = v_curParentOrd_4926_;
goto v___jp_4975_;
}
}
}
else
{
v___y_4976_ = v___y_4989_;
v___y_4977_ = v___y_4987_;
v___y_4978_ = v___y_4990_;
v___y_4979_ = v___y_4991_;
v___y_4980_ = v___y_4993_;
v___y_4981_ = v_curParentOrd_4926_;
goto v___jp_4975_;
}
}
else
{
uint8_t v___x_5001_;
v___x_5001_ = 0;
v___y_4976_ = v___x_5001_;
v___y_4977_ = v___y_4987_;
v___y_4978_ = v___y_4990_;
v___y_4979_ = v___y_4991_;
v___y_4980_ = v___y_4993_;
v___y_4981_ = v_curParentOrd_4926_;
goto v___jp_4975_;
}
}
}
}
v___jp_5002_:
{
if (v___y_5006_ == 0)
{
v___y_4986_ = v___y_5003_;
v___y_4987_ = v___y_5005_;
v___y_4988_ = v___y_5004_;
v___y_4989_ = v___y_5011_;
v___y_4990_ = v___y_5006_;
v___y_4991_ = v___y_5009_;
v___y_4992_ = v___y_5008_;
v___y_4993_ = v___y_5010_;
v___y_4994_ = v___y_5006_;
goto v___jp_4985_;
}
else
{
if (v___y_5009_ == 0)
{
if (v___y_5007_ == 0)
{
if (v___y_5010_ == 0)
{
v___y_4986_ = v___y_5003_;
v___y_4987_ = v___y_5005_;
v___y_4988_ = v___y_5004_;
v___y_4989_ = v___y_5011_;
v___y_4990_ = v___y_5006_;
v___y_4991_ = v___y_5009_;
v___y_4992_ = v___y_5008_;
v___y_4993_ = v___y_5010_;
v___y_4994_ = v___y_5006_;
goto v___jp_4985_;
}
else
{
v___y_4986_ = v___y_5003_;
v___y_4987_ = v___y_5005_;
v___y_4988_ = v___y_5004_;
v___y_4989_ = v___y_5011_;
v___y_4990_ = v___y_5006_;
v___y_4991_ = v___y_5009_;
v___y_4992_ = v___y_5008_;
v___y_4993_ = v___y_5010_;
v___y_4994_ = v___y_5007_;
goto v___jp_4985_;
}
}
else
{
v___y_4986_ = v___y_5003_;
v___y_4987_ = v___y_5005_;
v___y_4988_ = v___y_5004_;
v___y_4989_ = v___y_5011_;
v___y_4990_ = v___y_5006_;
v___y_4991_ = v___y_5009_;
v___y_4992_ = v___y_5008_;
v___y_4993_ = v___y_5010_;
v___y_4994_ = v___y_5009_;
goto v___jp_4985_;
}
}
else
{
uint8_t v___x_5012_;
v___x_5012_ = 0;
v___y_4986_ = v___y_5003_;
v___y_4987_ = v___y_5005_;
v___y_4988_ = v___y_5004_;
v___y_4989_ = v___y_5011_;
v___y_4990_ = v___y_5006_;
v___y_4991_ = v___y_5009_;
v___y_4992_ = v___y_5008_;
v___y_4993_ = v___y_5010_;
v___y_4994_ = v___x_5012_;
goto v___jp_4985_;
}
}
}
v___jp_5014_:
{
if (v___x_5013_ == 0)
{
v___y_5003_ = v___y_5015_;
v___y_5004_ = v___y_5016_;
v___y_5005_ = v___y_5023_;
v___y_5006_ = v___y_5017_;
v___y_5007_ = v___y_5019_;
v___y_5008_ = v___y_5018_;
v___y_5009_ = v___y_5020_;
v___y_5010_ = v___y_5022_;
v___y_5011_ = v___x_5013_;
goto v___jp_5002_;
}
else
{
if (v___y_5021_ == 0)
{
v___y_5003_ = v___y_5015_;
v___y_5004_ = v___y_5016_;
v___y_5005_ = v___y_5023_;
v___y_5006_ = v___y_5017_;
v___y_5007_ = v___y_5019_;
v___y_5008_ = v___y_5018_;
v___y_5009_ = v___y_5020_;
v___y_5010_ = v___y_5022_;
v___y_5011_ = v___x_5013_;
goto v___jp_5002_;
}
else
{
uint8_t v___x_5024_;
v___x_5024_ = 0;
v___y_5003_ = v___y_5015_;
v___y_5004_ = v___y_5016_;
v___y_5005_ = v___y_5023_;
v___y_5006_ = v___y_5017_;
v___y_5007_ = v___y_5019_;
v___y_5008_ = v___y_5018_;
v___y_5009_ = v___y_5020_;
v___y_5010_ = v___y_5022_;
v___y_5011_ = v___x_5024_;
goto v___jp_5002_;
}
}
}
v___jp_5025_:
{
if (v___y_5032_ == 0)
{
v___y_5015_ = v___y_5026_;
v___y_5016_ = v___y_5027_;
v___y_5017_ = v___y_5028_;
v___y_5018_ = v___y_5032_;
v___y_5019_ = v___y_5031_;
v___y_5020_ = v___y_5030_;
v___y_5021_ = v___y_5033_;
v___y_5022_ = v___y_5034_;
v___y_5023_ = v___y_5028_;
goto v___jp_5014_;
}
else
{
if (v___y_5026_ == 0)
{
v___y_5015_ = v___y_5026_;
v___y_5016_ = v___y_5027_;
v___y_5017_ = v___y_5028_;
v___y_5018_ = v___y_5032_;
v___y_5019_ = v___y_5031_;
v___y_5020_ = v___y_5030_;
v___y_5021_ = v___y_5033_;
v___y_5022_ = v___y_5034_;
v___y_5023_ = v___y_5028_;
goto v___jp_5014_;
}
else
{
if (v___y_5031_ == 0)
{
if (v___y_5034_ == 0)
{
v___y_5015_ = v___y_5026_;
v___y_5016_ = v___y_5027_;
v___y_5017_ = v___y_5028_;
v___y_5018_ = v___y_5032_;
v___y_5019_ = v___y_5031_;
v___y_5020_ = v___y_5030_;
v___y_5021_ = v___y_5033_;
v___y_5022_ = v___y_5034_;
v___y_5023_ = v___y_5028_;
goto v___jp_5014_;
}
else
{
v___y_5015_ = v___y_5026_;
v___y_5016_ = v___y_5027_;
v___y_5017_ = v___y_5028_;
v___y_5018_ = v___y_5032_;
v___y_5019_ = v___y_5031_;
v___y_5020_ = v___y_5030_;
v___y_5021_ = v___y_5033_;
v___y_5022_ = v___y_5034_;
v___y_5023_ = v___y_5031_;
goto v___jp_5014_;
}
}
else
{
v___y_5015_ = v___y_5026_;
v___y_5016_ = v___y_5027_;
v___y_5017_ = v___y_5028_;
v___y_5018_ = v___y_5032_;
v___y_5019_ = v___y_5031_;
v___y_5020_ = v___y_5030_;
v___y_5021_ = v___y_5033_;
v___y_5022_ = v___y_5034_;
v___y_5023_ = v___y_5029_;
goto v___jp_5014_;
}
}
}
}
v___jp_5035_:
{
if (v___y_5041_ == 0)
{
if (v___y_5036_ == 0)
{
v___y_5026_ = v___y_5044_;
v___y_5027_ = v___y_5037_;
v___y_5028_ = v___y_5038_;
v___y_5029_ = v___y_5042_;
v___y_5030_ = v___y_5041_;
v___y_5031_ = v___y_5040_;
v___y_5032_ = v___y_5039_;
v___y_5033_ = v___y_5043_;
v___y_5034_ = v___y_5036_;
goto v___jp_5025_;
}
else
{
if (v___y_5040_ == 0)
{
uint8_t v_unarchEpochOk_5045_;
v_unarchEpochOk_5045_ = lean_uint64_dec_lt(v_archiveEpoch_4921_, v_incomingEpoch_4920_);
v___y_5026_ = v___y_5044_;
v___y_5027_ = v___y_5037_;
v___y_5028_ = v___y_5038_;
v___y_5029_ = v___y_5042_;
v___y_5030_ = v___y_5041_;
v___y_5031_ = v___y_5040_;
v___y_5032_ = v___y_5039_;
v___y_5033_ = v___y_5043_;
v___y_5034_ = v_unarchEpochOk_5045_;
goto v___jp_5025_;
}
else
{
v___y_5026_ = v___y_5044_;
v___y_5027_ = v___y_5037_;
v___y_5028_ = v___y_5038_;
v___y_5029_ = v___y_5042_;
v___y_5030_ = v___y_5041_;
v___y_5031_ = v___y_5040_;
v___y_5032_ = v___y_5039_;
v___y_5033_ = v___y_5043_;
v___y_5034_ = v___y_5041_;
goto v___jp_5025_;
}
}
}
else
{
uint8_t v___x_5046_;
v___x_5046_ = 0;
v___y_5015_ = v___y_5044_;
v___y_5016_ = v___y_5037_;
v___y_5017_ = v___y_5038_;
v___y_5018_ = v___y_5039_;
v___y_5019_ = v___y_5040_;
v___y_5020_ = v___y_5041_;
v___y_5021_ = v___y_5043_;
v___y_5022_ = v___x_5046_;
v___y_5023_ = v___y_5042_;
goto v___jp_5014_;
}
}
v___jp_5047_:
{
uint8_t v_curArchBool_5049_; uint8_t v_incArchBool_5050_; uint8_t v_incUnarchBool_5051_; uint8_t v_incSupBool_5052_; uint8_t v___x_5053_; uint8_t v_validPresence_5054_; uint8_t v___x_5055_; uint8_t v___x_5056_;
v_curArchBool_5049_ = lean_uint8_dec_eq(v_curArchived_4922_, v___x_4984_);
v_incArchBool_5050_ = lean_uint8_dec_eq(v_incArchive_4928_, v___x_4984_);
v_incUnarchBool_5051_ = lean_uint8_dec_eq(v_incUnarchive_4929_, v___x_4984_);
v_incSupBool_5052_ = lean_uint8_dec_eq(v_incSupersede_4930_, v___x_4984_);
v___x_5053_ = 2;
v_validPresence_5054_ = lean_uint8_dec_le(v_parentPresence_4925_, v___x_5053_);
v___x_5055_ = lean_uint8_dec_eq(v_isPartialPatch_4924_, v___x_4984_);
v___x_5056_ = 1;
if (v___x_5055_ == 0)
{
uint8_t v___x_5057_;
v___x_5057_ = lean_uint64_dec_le(v_currentEpoch_4919_, v_incomingEpoch_4920_);
v___y_5036_ = v_incUnarchBool_5051_;
v___y_5037_ = v___x_5055_;
v___y_5038_ = v_curArchBool_5049_;
v___y_5039_ = v_validPresence_5054_;
v___y_5040_ = v_incArchBool_5050_;
v___y_5041_ = v___y_5048_;
v___y_5042_ = v___x_5056_;
v___y_5043_ = v_incSupBool_5052_;
v___y_5044_ = v___x_5057_;
goto v___jp_5035_;
}
else
{
uint8_t v___x_5058_;
v___x_5058_ = lean_uint64_dec_lt(v_currentEpoch_4919_, v_incomingEpoch_4920_);
v___y_5036_ = v_incUnarchBool_5051_;
v___y_5037_ = v___x_5055_;
v___y_5038_ = v_curArchBool_5049_;
v___y_5039_ = v_validPresence_5054_;
v___y_5040_ = v_incArchBool_5050_;
v___y_5041_ = v___y_5048_;
v___y_5042_ = v___x_5056_;
v___y_5043_ = v_incSupBool_5052_;
v___y_5044_ = v___x_5058_;
goto v___jp_5035_;
}
}
}
}

LEAN_EXPORT uint64_t orb_transcript_fold_step(uint64_t v_lastAppliedSeq_5179_, uint64_t v_incomingSeq_5180_, uint32_t v_entryCount_5181_, uint8_t v_thinkingOpen_5182_, uint8_t v_normalizedAction_5183_, uint8_t v_isReplayFromLog_5184_){
_start:
{
uint32_t v___y_5186_; uint32_t v___y_5187_; uint32_t v___y_5194_; uint8_t v___y_5201_; uint32_t v___y_5202_; uint8_t v___x_5203_; uint8_t v___x_5204_; uint8_t v___y_5206_; uint8_t v___y_5207_; uint8_t v___y_5208_; uint8_t v___y_5209_; uint32_t v___y_5210_; uint8_t v___y_5211_; uint8_t v___x_5223_; uint8_t v___y_5225_; uint8_t v___y_5226_; uint8_t v___y_5227_; uint32_t v___y_5228_; uint8_t v___y_5229_; uint8_t v___y_5237_; uint32_t v___y_5238_; uint8_t v___y_5239_; uint32_t v___y_5253_;
v___x_5203_ = 1;
v___x_5204_ = lean_uint8_dec_eq(v_thinkingOpen_5182_, v___x_5203_);
v___x_5223_ = 1;
if (v___x_5204_ == 0)
{
uint32_t v___x_5259_;
v___x_5259_ = 0;
v___y_5253_ = v___x_5259_;
goto v___jp_5252_;
}
else
{
uint32_t v___x_5260_;
v___x_5260_ = 512;
v___y_5253_ = v___x_5260_;
goto v___jp_5252_;
}
v___jp_5185_:
{
uint64_t v___x_5188_; uint64_t v___x_5189_; uint64_t v___x_5190_; uint64_t v___x_5191_; uint64_t v___x_5192_;
v___x_5188_ = lean_uint32_to_uint64(v___y_5186_);
v___x_5189_ = lean_uint32_to_uint64(v___y_5187_);
v___x_5190_ = 32ULL;
v___x_5191_ = lean_uint64_shift_left(v___x_5189_, v___x_5190_);
v___x_5192_ = lean_uint64_lor(v___x_5188_, v___x_5191_);
return v___x_5192_;
}
v___jp_5193_:
{
uint32_t v___x_5195_; uint8_t v___x_5196_;
v___x_5195_ = 4294967294;
v___x_5196_ = lean_uint32_dec_le(v_entryCount_5181_, v___x_5195_);
if (v___x_5196_ == 0)
{
uint32_t v___x_5197_;
v___x_5197_ = 4294967295;
v___y_5186_ = v___y_5194_;
v___y_5187_ = v___x_5197_;
goto v___jp_5185_;
}
else
{
uint32_t v___x_5198_; uint32_t v___x_5199_;
v___x_5198_ = 1;
v___x_5199_ = lean_uint32_add(v_entryCount_5181_, v___x_5198_);
v___y_5186_ = v___y_5194_;
v___y_5187_ = v___x_5199_;
goto v___jp_5185_;
}
}
v___jp_5200_:
{
if (v___y_5201_ == 0)
{
v___y_5186_ = v___y_5202_;
v___y_5187_ = v_entryCount_5181_;
goto v___jp_5185_;
}
else
{
v___y_5194_ = v___y_5202_;
goto v___jp_5193_;
}
}
v___jp_5205_:
{
if (v___y_5209_ == 0)
{
if (v___y_5207_ == 0)
{
uint32_t v___x_5212_; uint32_t v___x_5213_;
v___x_5212_ = 2051;
v___x_5213_ = lean_uint32_lor(v___x_5212_, v___y_5210_);
v___y_5186_ = v___x_5213_;
v___y_5187_ = v_entryCount_5181_;
goto v___jp_5185_;
}
else
{
if (v___y_5208_ == 0)
{
if (v___y_5206_ == 0)
{
if (v___y_5211_ == 0)
{
uint32_t v___x_5214_; uint32_t v___x_5215_;
v___x_5214_ = 5;
v___x_5215_ = lean_uint32_lor(v___x_5214_, v___y_5210_);
v___y_5186_ = v___x_5215_;
v___y_5187_ = v_entryCount_5181_;
goto v___jp_5185_;
}
else
{
uint32_t v___x_5216_; uint32_t v___x_5217_;
v___x_5216_ = 260;
v___x_5217_ = lean_uint32_lor(v___x_5216_, v___y_5210_);
v___y_5186_ = v___x_5217_;
v___y_5187_ = v_entryCount_5181_;
goto v___jp_5185_;
}
}
else
{
if (v___x_5204_ == 0)
{
uint32_t v___x_5218_;
v___x_5218_ = 257;
v___y_5194_ = v___x_5218_;
goto v___jp_5193_;
}
else
{
uint32_t v___x_5219_;
v___x_5219_ = 1281;
v___y_5194_ = v___x_5219_;
goto v___jp_5193_;
}
}
}
else
{
uint32_t v___x_5220_;
v___x_5220_ = 769;
v___y_5201_ = v___y_5206_;
v___y_5202_ = v___x_5220_;
goto v___jp_5200_;
}
}
}
else
{
uint32_t v___x_5221_; uint32_t v___x_5222_;
v___x_5221_ = 2;
v___x_5222_ = lean_uint32_lor(v___x_5221_, v___y_5210_);
if (v___y_5207_ == 0)
{
v___y_5186_ = v___x_5222_;
v___y_5187_ = v_entryCount_5181_;
goto v___jp_5185_;
}
else
{
v___y_5201_ = v___y_5206_;
v___y_5202_ = v___x_5222_;
goto v___jp_5200_;
}
}
}
v___jp_5224_:
{
uint8_t v___x_5230_; uint8_t v___x_5231_;
v___x_5230_ = 2;
v___x_5231_ = lean_uint8_dec_eq(v_normalizedAction_5183_, v___x_5230_);
if (v___x_5231_ == 0)
{
uint8_t v___x_5232_; uint8_t v___x_5233_;
v___x_5232_ = 3;
v___x_5233_ = lean_uint8_dec_eq(v_normalizedAction_5183_, v___x_5232_);
if (v___x_5233_ == 0)
{
uint8_t v___x_5234_; uint8_t v___x_5235_;
v___x_5234_ = 8;
v___x_5235_ = lean_uint8_dec_eq(v_normalizedAction_5183_, v___x_5234_);
v___y_5206_ = v___y_5229_;
v___y_5207_ = v___y_5225_;
v___y_5208_ = v___y_5226_;
v___y_5209_ = v___y_5227_;
v___y_5210_ = v___y_5228_;
v___y_5211_ = v___x_5235_;
goto v___jp_5205_;
}
else
{
v___y_5206_ = v___y_5229_;
v___y_5207_ = v___y_5225_;
v___y_5208_ = v___y_5226_;
v___y_5209_ = v___y_5227_;
v___y_5210_ = v___y_5228_;
v___y_5211_ = v___x_5223_;
goto v___jp_5205_;
}
}
else
{
v___y_5206_ = v___y_5229_;
v___y_5207_ = v___y_5225_;
v___y_5208_ = v___y_5226_;
v___y_5209_ = v___y_5227_;
v___y_5210_ = v___y_5228_;
v___y_5211_ = v___x_5223_;
goto v___jp_5205_;
}
}
v___jp_5236_:
{
uint8_t v___x_5240_; uint8_t v_isOpenThink_5241_; uint8_t v___x_5242_; uint8_t v___x_5243_;
v___x_5240_ = 4;
v_isOpenThink_5241_ = lean_uint8_dec_eq(v_normalizedAction_5183_, v___x_5240_);
v___x_5242_ = 5;
v___x_5243_ = lean_uint8_dec_eq(v_normalizedAction_5183_, v___x_5242_);
if (v___x_5243_ == 0)
{
uint8_t v___x_5244_; uint8_t v___x_5245_;
v___x_5244_ = 6;
v___x_5245_ = lean_uint8_dec_eq(v_normalizedAction_5183_, v___x_5244_);
if (v___x_5245_ == 0)
{
uint8_t v___x_5246_; uint8_t v___x_5247_;
v___x_5246_ = 7;
v___x_5247_ = lean_uint8_dec_eq(v_normalizedAction_5183_, v___x_5246_);
if (v___x_5247_ == 0)
{
uint8_t v___x_5248_; uint8_t v___x_5249_;
v___x_5248_ = 9;
v___x_5249_ = lean_uint8_dec_eq(v_normalizedAction_5183_, v___x_5248_);
if (v___x_5249_ == 0)
{
uint8_t v___x_5250_; uint8_t v___x_5251_;
v___x_5250_ = 10;
v___x_5251_ = lean_uint8_dec_eq(v_normalizedAction_5183_, v___x_5250_);
v___y_5225_ = v___y_5239_;
v___y_5226_ = v_isOpenThink_5241_;
v___y_5227_ = v___y_5237_;
v___y_5228_ = v___y_5238_;
v___y_5229_ = v___x_5251_;
goto v___jp_5224_;
}
else
{
v___y_5225_ = v___y_5239_;
v___y_5226_ = v_isOpenThink_5241_;
v___y_5227_ = v___y_5237_;
v___y_5228_ = v___y_5238_;
v___y_5229_ = v___x_5223_;
goto v___jp_5224_;
}
}
else
{
v___y_5225_ = v___y_5239_;
v___y_5226_ = v_isOpenThink_5241_;
v___y_5227_ = v___y_5237_;
v___y_5228_ = v___y_5238_;
v___y_5229_ = v___x_5223_;
goto v___jp_5224_;
}
}
else
{
v___y_5225_ = v___y_5239_;
v___y_5226_ = v_isOpenThink_5241_;
v___y_5227_ = v___y_5237_;
v___y_5228_ = v___y_5238_;
v___y_5229_ = v___x_5223_;
goto v___jp_5224_;
}
}
else
{
v___y_5225_ = v___y_5239_;
v___y_5226_ = v_isOpenThink_5241_;
v___y_5227_ = v___y_5237_;
v___y_5228_ = v___y_5238_;
v___y_5229_ = v___x_5223_;
goto v___jp_5224_;
}
}
v___jp_5252_:
{
uint8_t v_isDuplicate_5254_;
v_isDuplicate_5254_ = lean_uint64_dec_le(v_incomingSeq_5180_, v_lastAppliedSeq_5179_);
if (v_isDuplicate_5254_ == 0)
{
uint64_t v___x_5255_; uint64_t v___x_5256_; uint8_t v___x_5257_;
v___x_5255_ = lean_uint64_sub(v_incomingSeq_5180_, v_lastAppliedSeq_5179_);
v___x_5256_ = 1ULL;
v___x_5257_ = lean_uint64_dec_eq(v___x_5255_, v___x_5256_);
v___y_5237_ = v_isDuplicate_5254_;
v___y_5238_ = v___y_5253_;
v___y_5239_ = v___x_5257_;
goto v___jp_5236_;
}
else
{
uint8_t v___x_5258_;
v___x_5258_ = 0;
v___y_5237_ = v_isDuplicate_5254_;
v___y_5238_ = v___y_5253_;
v___y_5239_ = v___x_5258_;
goto v___jp_5236_;
}
}
}
}

LEAN_EXPORT uint64_t orb_outbox_crash_reconcile_step(uint32_t v_durableQueued_5275_, uint32_t v_durableAcked_5276_, uint32_t v_volatileInFlight_5277_, uint64_t v_leaseBootEpoch_5278_, uint64_t v_nodeBootEpoch_5279_, uint32_t v_volatileLeaseOwner_5280_, uint32_t v_reqOwner_5281_){
_start:
{
uint32_t v___y_5283_; uint32_t v___y_5284_; uint32_t v___y_5291_; uint32_t v___y_5292_; uint32_t v___y_5293_; uint32_t v___y_5294_; uint8_t v_validWal_5297_; uint8_t v___y_5299_; uint32_t v___y_5300_; uint32_t v___y_5301_; uint32_t v___y_5302_; uint32_t v___y_5303_; uint8_t v___y_5311_; uint8_t v___y_5312_; uint32_t v___y_5313_; uint32_t v___y_5314_; uint32_t v___y_5315_; uint8_t v___y_5318_; uint8_t v___y_5319_; uint32_t v___y_5320_; uint32_t v___y_5321_; uint8_t v___y_5326_; uint32_t v___y_5327_; uint32_t v___y_5328_; uint8_t v___y_5329_; uint8_t v___y_5331_; uint32_t v___y_5332_; uint32_t v___y_5333_; uint32_t v___y_5334_; uint8_t v___y_5337_; uint32_t v___y_5338_; uint32_t v___y_5339_; uint32_t v___y_5340_; uint32_t v___y_5348_;
v_validWal_5297_ = lean_uint32_dec_le(v_durableAcked_5276_, v_durableQueued_5275_);
if (v_validWal_5297_ == 0)
{
uint32_t v___x_5353_;
v___x_5353_ = 0;
v___y_5348_ = v___x_5353_;
goto v___jp_5347_;
}
else
{
uint32_t v___x_5354_;
v___x_5354_ = lean_uint32_sub(v_durableQueued_5275_, v_durableAcked_5276_);
v___y_5348_ = v___x_5354_;
goto v___jp_5347_;
}
v___jp_5282_:
{
uint64_t v___x_5285_; uint64_t v___x_5286_; uint64_t v___x_5287_; uint64_t v___x_5288_; uint64_t v___x_5289_;
v___x_5285_ = lean_uint32_to_uint64(v___y_5284_);
v___x_5286_ = lean_uint32_to_uint64(v___y_5283_);
v___x_5287_ = 32ULL;
v___x_5288_ = lean_uint64_shift_left(v___x_5286_, v___x_5287_);
v___x_5289_ = lean_uint64_lor(v___x_5285_, v___x_5288_);
return v___x_5289_;
}
v___jp_5290_:
{
uint32_t v___x_5295_; uint32_t v___x_5296_;
v___x_5295_ = lean_uint32_lor(v___y_5294_, v___y_5291_);
v___x_5296_ = lean_uint32_lor(v___x_5295_, v___y_5293_);
v___y_5283_ = v___y_5292_;
v___y_5284_ = v___x_5296_;
goto v___jp_5282_;
}
v___jp_5298_:
{
if (v_validWal_5297_ == 0)
{
v___y_5283_ = v___y_5301_;
v___y_5284_ = v___y_5300_;
goto v___jp_5282_;
}
else
{
if (v___y_5299_ == 0)
{
uint8_t v___x_5304_;
v___x_5304_ = lean_uint32_dec_eq(v___y_5301_, v___y_5300_);
if (v___x_5304_ == 0)
{
uint32_t v___x_5305_;
v___x_5305_ = 3;
v___y_5291_ = v___y_5303_;
v___y_5292_ = v___y_5301_;
v___y_5293_ = v___y_5302_;
v___y_5294_ = v___x_5305_;
goto v___jp_5290_;
}
else
{
uint32_t v___x_5306_;
v___x_5306_ = 2;
v___y_5291_ = v___y_5303_;
v___y_5292_ = v___y_5301_;
v___y_5293_ = v___y_5302_;
v___y_5294_ = v___x_5306_;
goto v___jp_5290_;
}
}
else
{
uint32_t v___x_5307_; uint32_t v___x_5308_; uint32_t v___x_5309_;
v___x_5307_ = 257;
v___x_5308_ = lean_uint32_lor(v___x_5307_, v___y_5303_);
v___x_5309_ = lean_uint32_lor(v___x_5308_, v___y_5302_);
v___y_5283_ = v___y_5301_;
v___y_5284_ = v___x_5309_;
goto v___jp_5282_;
}
}
}
v___jp_5310_:
{
if (v___y_5311_ == 0)
{
v___y_5299_ = v___y_5312_;
v___y_5300_ = v___y_5313_;
v___y_5301_ = v___y_5314_;
v___y_5302_ = v___y_5315_;
v___y_5303_ = v___y_5313_;
goto v___jp_5298_;
}
else
{
uint32_t v___x_5316_;
v___x_5316_ = 512;
v___y_5299_ = v___y_5312_;
v___y_5300_ = v___y_5313_;
v___y_5301_ = v___y_5314_;
v___y_5302_ = v___y_5315_;
v___y_5303_ = v___x_5316_;
goto v___jp_5298_;
}
}
v___jp_5317_:
{
uint32_t v___x_5322_; uint8_t v___x_5323_;
v___x_5322_ = 0;
v___x_5323_ = lean_uint32_dec_eq(v___y_5321_, v___x_5322_);
if (v___x_5323_ == 0)
{
uint32_t v___x_5324_;
v___x_5324_ = 1024;
v___y_5311_ = v___y_5318_;
v___y_5312_ = v___y_5319_;
v___y_5313_ = v___x_5322_;
v___y_5314_ = v___y_5320_;
v___y_5315_ = v___x_5324_;
goto v___jp_5310_;
}
else
{
v___y_5311_ = v___y_5318_;
v___y_5312_ = v___y_5319_;
v___y_5313_ = v___x_5322_;
v___y_5314_ = v___y_5320_;
v___y_5315_ = v___x_5322_;
goto v___jp_5310_;
}
}
v___jp_5325_:
{
if (v___y_5329_ == 0)
{
v___y_5318_ = v___y_5326_;
v___y_5319_ = v___y_5329_;
v___y_5320_ = v___y_5328_;
v___y_5321_ = v___y_5327_;
goto v___jp_5317_;
}
else
{
v___y_5318_ = v___y_5326_;
v___y_5319_ = v___y_5329_;
v___y_5320_ = v___y_5328_;
v___y_5321_ = v_reqOwner_5281_;
goto v___jp_5317_;
}
}
v___jp_5330_:
{
uint8_t v___x_5335_;
v___x_5335_ = lean_uint32_dec_lt(v___y_5334_, v___y_5333_);
v___y_5326_ = v___y_5331_;
v___y_5327_ = v___y_5332_;
v___y_5328_ = v___y_5333_;
v___y_5329_ = v___x_5335_;
goto v___jp_5325_;
}
v___jp_5336_:
{
if (v_validWal_5297_ == 0)
{
v___y_5326_ = v___y_5337_;
v___y_5327_ = v___y_5339_;
v___y_5328_ = v___y_5338_;
v___y_5329_ = v_validWal_5297_;
goto v___jp_5325_;
}
else
{
uint32_t v___x_5341_; uint8_t v___x_5342_;
v___x_5341_ = 0;
v___x_5342_ = lean_uint32_dec_lt(v___x_5341_, v___y_5338_);
if (v___x_5342_ == 0)
{
v___y_5326_ = v___y_5337_;
v___y_5327_ = v___y_5339_;
v___y_5328_ = v___y_5338_;
v___y_5329_ = v___x_5342_;
goto v___jp_5325_;
}
else
{
uint8_t v___x_5343_;
v___x_5343_ = lean_uint32_dec_eq(v_reqOwner_5281_, v___x_5341_);
if (v___x_5343_ == 0)
{
uint8_t v___x_5344_;
v___x_5344_ = lean_uint32_dec_eq(v___y_5339_, v___x_5341_);
if (v___x_5344_ == 0)
{
uint8_t v___x_5345_;
v___x_5345_ = lean_uint32_dec_eq(v___y_5339_, v_reqOwner_5281_);
if (v___x_5345_ == 0)
{
v___y_5326_ = v___y_5337_;
v___y_5327_ = v___y_5339_;
v___y_5328_ = v___y_5338_;
v___y_5329_ = v___x_5345_;
goto v___jp_5325_;
}
else
{
v___y_5331_ = v___y_5337_;
v___y_5332_ = v___y_5339_;
v___y_5333_ = v___y_5338_;
v___y_5334_ = v___y_5340_;
goto v___jp_5330_;
}
}
else
{
v___y_5331_ = v___y_5337_;
v___y_5332_ = v___y_5339_;
v___y_5333_ = v___y_5338_;
v___y_5334_ = v___y_5340_;
goto v___jp_5330_;
}
}
else
{
uint8_t v___x_5346_;
v___x_5346_ = 0;
v___y_5318_ = v___y_5337_;
v___y_5319_ = v___x_5346_;
v___y_5320_ = v___y_5338_;
v___y_5321_ = v___y_5339_;
goto v___jp_5317_;
}
}
}
}
v___jp_5347_:
{
uint8_t v___x_5349_;
v___x_5349_ = lean_uint64_dec_eq(v_leaseBootEpoch_5278_, v_nodeBootEpoch_5279_);
if (v___x_5349_ == 0)
{
uint8_t v___x_5350_; uint32_t v___x_5351_;
v___x_5350_ = 1;
v___x_5351_ = 0;
v___y_5337_ = v___x_5350_;
v___y_5338_ = v___y_5348_;
v___y_5339_ = v___x_5351_;
v___y_5340_ = v___x_5351_;
goto v___jp_5336_;
}
else
{
uint8_t v___x_5352_;
v___x_5352_ = 0;
v___y_5337_ = v___x_5352_;
v___y_5338_ = v___y_5348_;
v___y_5339_ = v_volatileLeaseOwner_5280_;
v___y_5340_ = v_volatileInFlight_5277_;
goto v___jp_5336_;
}
}
}
}

LEAN_EXPORT uint64_t orb_provider_attempt_step(uint32_t v_pinnedAccountId_5371_, uint32_t v_candidateAccountId_5372_, uint32_t v_attemptsUsed_5373_, uint32_t v_retryBudget_5374_, uint8_t v_firstByteCommitted_5375_, uint8_t v_failureKind_5376_, uint64_t v_upstreamNowEpoch_5377_, uint64_t v_cooldownUntilEpoch_5378_, uint64_t v_upstreamDeadline_5379_, uint8_t v_authValid_5380_){
_start:
{
uint32_t v___y_5382_; uint32_t v___y_5383_; uint32_t v___y_5390_; uint32_t v___y_5391_; uint8_t v___y_5395_; uint8_t v___y_5396_; uint32_t v___y_5397_; uint8_t v___y_5398_; uint8_t v___y_5399_; uint8_t v___y_5400_; uint8_t v___y_5401_; uint8_t v___x_5417_; uint8_t v___x_5418_; uint8_t v___y_5420_; uint8_t v___y_5421_; uint32_t v___y_5422_; uint8_t v___y_5423_; uint8_t v___y_5424_; uint8_t v___y_5425_; uint8_t v___y_5427_; uint32_t v___y_5428_; uint8_t v___y_5429_; uint8_t v___y_5430_; uint8_t v___y_5431_; uint8_t v___y_5435_; uint8_t v___y_5436_; uint32_t v___y_5437_; uint8_t v___y_5438_; uint8_t v___y_5439_; uint8_t v___y_5443_; uint32_t v___y_5444_; uint8_t v___y_5445_; uint8_t v___y_5446_; uint32_t v___y_5450_; uint8_t v___y_5451_; uint32_t v___y_5457_;
v___x_5417_ = 1;
v___x_5418_ = lean_uint8_dec_eq(v_firstByteCommitted_5375_, v___x_5417_);
if (v___x_5418_ == 0)
{
uint8_t v___x_5465_; uint8_t v___x_5466_;
v___x_5465_ = 3;
v___x_5466_ = lean_uint8_dec_eq(v_failureKind_5376_, v___x_5465_);
if (v___x_5466_ == 0)
{
uint32_t v___x_5467_;
v___x_5467_ = 0;
v___y_5457_ = v___x_5467_;
goto v___jp_5456_;
}
else
{
goto v___jp_5463_;
}
}
else
{
goto v___jp_5463_;
}
v___jp_5381_:
{
uint64_t v___x_5384_; uint64_t v___x_5385_; uint64_t v___x_5386_; uint64_t v___x_5387_; uint64_t v___x_5388_;
v___x_5384_ = lean_uint32_to_uint64(v___y_5383_);
v___x_5385_ = lean_uint32_to_uint64(v___y_5382_);
v___x_5386_ = 32ULL;
v___x_5387_ = lean_uint64_shift_left(v___x_5385_, v___x_5386_);
v___x_5388_ = lean_uint64_lor(v___x_5384_, v___x_5387_);
return v___x_5388_;
}
v___jp_5389_:
{
uint32_t v___x_5392_; uint32_t v___x_5393_;
v___x_5392_ = 257;
v___x_5393_ = lean_uint32_lor(v___x_5392_, v___y_5390_);
v___y_5382_ = v___y_5391_;
v___y_5383_ = v___x_5393_;
goto v___jp_5381_;
}
v___jp_5394_:
{
if (v___y_5401_ == 0)
{
if (v___y_5400_ == 0)
{
uint32_t v___x_5402_; uint32_t v___x_5403_;
v___x_5402_ = 4;
v___x_5403_ = lean_uint32_lor(v___x_5402_, v___y_5397_);
v___y_5382_ = v_attemptsUsed_5373_;
v___y_5383_ = v___x_5403_;
goto v___jp_5381_;
}
else
{
if (v___y_5398_ == 0)
{
uint32_t v___x_5404_; uint32_t v___x_5405_;
v___x_5404_ = 5;
v___x_5405_ = lean_uint32_lor(v___x_5404_, v___y_5397_);
v___y_5382_ = v_attemptsUsed_5373_;
v___y_5383_ = v___x_5405_;
goto v___jp_5381_;
}
else
{
if (v___y_5395_ == 0)
{
uint32_t v___x_5406_; uint32_t v___x_5407_;
v___x_5406_ = 6;
v___x_5407_ = lean_uint32_lor(v___x_5406_, v___y_5397_);
v___y_5382_ = v_attemptsUsed_5373_;
v___y_5383_ = v___x_5407_;
goto v___jp_5381_;
}
else
{
if (v___y_5396_ == 0)
{
uint32_t v___x_5408_; uint32_t v___x_5409_;
v___x_5408_ = 7;
v___x_5409_ = lean_uint32_lor(v___x_5408_, v___y_5397_);
v___y_5382_ = v_attemptsUsed_5373_;
v___y_5383_ = v___x_5409_;
goto v___jp_5381_;
}
else
{
if (v___y_5399_ == 0)
{
v___y_5390_ = v___y_5397_;
v___y_5391_ = v_attemptsUsed_5373_;
goto v___jp_5389_;
}
else
{
uint32_t v___x_5410_; uint8_t v___x_5411_;
v___x_5410_ = 4294967294;
v___x_5411_ = lean_uint32_dec_le(v_attemptsUsed_5373_, v___x_5410_);
if (v___x_5411_ == 0)
{
uint32_t v___x_5412_;
v___x_5412_ = 4294967295;
v___y_5390_ = v___y_5397_;
v___y_5391_ = v___x_5412_;
goto v___jp_5389_;
}
else
{
uint32_t v___x_5413_; uint32_t v___x_5414_;
v___x_5413_ = 1;
v___x_5414_ = lean_uint32_add(v_attemptsUsed_5373_, v___x_5413_);
v___y_5390_ = v___y_5397_;
v___y_5391_ = v___x_5414_;
goto v___jp_5389_;
}
}
}
}
}
}
}
else
{
uint32_t v___x_5415_; uint32_t v___x_5416_;
v___x_5415_ = 3;
v___x_5416_ = lean_uint32_lor(v___x_5415_, v___y_5397_);
v___y_5382_ = v_attemptsUsed_5373_;
v___y_5383_ = v___x_5416_;
goto v___jp_5381_;
}
}
v___jp_5419_:
{
if (v___x_5418_ == 0)
{
v___y_5395_ = v___y_5420_;
v___y_5396_ = v___y_5425_;
v___y_5397_ = v___y_5422_;
v___y_5398_ = v___y_5421_;
v___y_5399_ = v___y_5424_;
v___y_5400_ = v___y_5423_;
v___y_5401_ = v___x_5418_;
goto v___jp_5394_;
}
else
{
v___y_5395_ = v___y_5420_;
v___y_5396_ = v___y_5425_;
v___y_5397_ = v___y_5422_;
v___y_5398_ = v___y_5421_;
v___y_5399_ = v___y_5424_;
v___y_5400_ = v___y_5423_;
v___y_5401_ = v___y_5424_;
goto v___jp_5394_;
}
}
v___jp_5426_:
{
if (v___y_5431_ == 0)
{
uint8_t v___x_5432_;
v___x_5432_ = lean_uint32_dec_le(v_attemptsUsed_5373_, v_retryBudget_5374_);
v___y_5420_ = v___y_5427_;
v___y_5421_ = v___y_5429_;
v___y_5422_ = v___y_5428_;
v___y_5423_ = v___y_5430_;
v___y_5424_ = v___y_5431_;
v___y_5425_ = v___x_5432_;
goto v___jp_5419_;
}
else
{
uint8_t v___x_5433_;
v___x_5433_ = lean_uint32_dec_lt(v_attemptsUsed_5373_, v_retryBudget_5374_);
v___y_5420_ = v___y_5427_;
v___y_5421_ = v___y_5429_;
v___y_5422_ = v___y_5428_;
v___y_5423_ = v___y_5430_;
v___y_5424_ = v___y_5431_;
v___y_5425_ = v___x_5433_;
goto v___jp_5419_;
}
}
v___jp_5434_:
{
uint8_t v___x_5440_;
v___x_5440_ = lean_uint8_dec_eq(v_failureKind_5376_, v___x_5417_);
if (v___x_5440_ == 0)
{
uint8_t v___x_5441_;
v___x_5441_ = lean_uint8_dec_eq(v_failureKind_5376_, v___y_5435_);
v___y_5427_ = v___y_5439_;
v___y_5428_ = v___y_5437_;
v___y_5429_ = v___y_5436_;
v___y_5430_ = v___y_5438_;
v___y_5431_ = v___x_5441_;
goto v___jp_5426_;
}
else
{
v___y_5427_ = v___y_5439_;
v___y_5428_ = v___y_5437_;
v___y_5429_ = v___y_5436_;
v___y_5430_ = v___y_5438_;
v___y_5431_ = v___x_5440_;
goto v___jp_5426_;
}
}
v___jp_5442_:
{
uint8_t v___x_5447_;
v___x_5447_ = lean_uint64_dec_lt(v_upstreamNowEpoch_5377_, v_upstreamDeadline_5379_);
if (v___x_5447_ == 0)
{
v___y_5435_ = v___y_5443_;
v___y_5436_ = v___y_5446_;
v___y_5437_ = v___y_5444_;
v___y_5438_ = v___y_5445_;
v___y_5439_ = v___x_5447_;
goto v___jp_5434_;
}
else
{
uint8_t v___x_5448_;
v___x_5448_ = lean_uint8_dec_eq(v_authValid_5380_, v___x_5417_);
v___y_5435_ = v___y_5443_;
v___y_5436_ = v___y_5446_;
v___y_5437_ = v___y_5444_;
v___y_5438_ = v___y_5445_;
v___y_5439_ = v___x_5448_;
goto v___jp_5434_;
}
}
v___jp_5449_:
{
uint8_t v___x_5452_; uint8_t v___x_5453_;
v___x_5452_ = 2;
v___x_5453_ = lean_uint8_dec_eq(v_failureKind_5376_, v___x_5452_);
if (v___x_5453_ == 0)
{
uint8_t v___x_5454_;
v___x_5454_ = lean_uint64_dec_le(v_cooldownUntilEpoch_5378_, v_upstreamNowEpoch_5377_);
v___y_5443_ = v___x_5452_;
v___y_5444_ = v___y_5450_;
v___y_5445_ = v___y_5451_;
v___y_5446_ = v___x_5454_;
goto v___jp_5442_;
}
else
{
uint8_t v___x_5455_;
v___x_5455_ = 0;
v___y_5443_ = v___x_5452_;
v___y_5444_ = v___y_5450_;
v___y_5445_ = v___y_5451_;
v___y_5446_ = v___x_5455_;
goto v___jp_5442_;
}
}
v___jp_5456_:
{
uint32_t v___x_5458_; uint8_t v___x_5459_;
v___x_5458_ = 0;
v___x_5459_ = lean_uint32_dec_eq(v_candidateAccountId_5372_, v___x_5458_);
if (v___x_5459_ == 0)
{
uint8_t v___x_5460_;
v___x_5460_ = lean_uint32_dec_eq(v_pinnedAccountId_5371_, v___x_5458_);
if (v___x_5460_ == 0)
{
uint8_t v___x_5461_;
v___x_5461_ = lean_uint32_dec_eq(v_candidateAccountId_5372_, v_pinnedAccountId_5371_);
v___y_5450_ = v___y_5457_;
v___y_5451_ = v___x_5461_;
goto v___jp_5449_;
}
else
{
v___y_5450_ = v___y_5457_;
v___y_5451_ = v___x_5460_;
goto v___jp_5449_;
}
}
else
{
uint8_t v___x_5462_;
v___x_5462_ = 0;
v___y_5450_ = v___y_5457_;
v___y_5451_ = v___x_5462_;
goto v___jp_5449_;
}
}
v___jp_5463_:
{
uint32_t v___x_5464_;
v___x_5464_ = 512;
v___y_5457_ = v___x_5464_;
goto v___jp_5456_;
}
}
}

LEAN_EXPORT uint32_t orb_auth_toctou_execute_step(uint8_t v_principalKind_5490_, uint8_t v_bunkerState_5491_, uint32_t v_observedTargetId_5492_, uint32_t v_execTargetId_5493_, uint64_t v_observedLeaseEpoch_5494_, uint64_t v_liveLeaseEpoch_5495_, uint64_t v_nowTick_5496_, uint64_t v_expiryTick_5497_, uint64_t v_observedDigest_5498_, uint64_t v_execDigest_5499_){
_start:
{
uint8_t v___x_5500_; uint8_t v___x_5501_;
v___x_5500_ = 0;
v___x_5501_ = lean_uint8_dec_eq(v_bunkerState_5491_, v___x_5500_);
if (v___x_5501_ == 0)
{
uint32_t v___x_5502_;
v___x_5502_ = 513;
return v___x_5502_;
}
else
{
uint8_t v___x_5503_; uint8_t v___x_5504_;
v___x_5503_ = 1;
v___x_5504_ = lean_uint8_dec_le(v___x_5503_, v_principalKind_5490_);
if (v___x_5504_ == 0)
{
uint32_t v___x_5505_;
v___x_5505_ = 514;
return v___x_5505_;
}
else
{
uint8_t v___x_5506_; uint8_t v___x_5507_;
v___x_5506_ = 3;
v___x_5507_ = lean_uint8_dec_le(v_principalKind_5490_, v___x_5506_);
if (v___x_5507_ == 0)
{
uint32_t v___x_5508_;
v___x_5508_ = 514;
return v___x_5508_;
}
else
{
uint8_t v___x_5509_;
v___x_5509_ = lean_uint64_dec_lt(v_nowTick_5496_, v_expiryTick_5497_);
if (v___x_5509_ == 0)
{
uint32_t v___x_5510_;
v___x_5510_ = 515;
return v___x_5510_;
}
else
{
uint64_t v___x_5511_; uint8_t v___x_5512_;
v___x_5511_ = 0ULL;
v___x_5512_ = lean_uint64_dec_eq(v_observedLeaseEpoch_5494_, v___x_5511_);
if (v___x_5512_ == 0)
{
uint8_t v___x_5513_;
v___x_5513_ = lean_uint64_dec_eq(v_observedLeaseEpoch_5494_, v_liveLeaseEpoch_5495_);
if (v___x_5513_ == 0)
{
uint32_t v___x_5514_;
v___x_5514_ = 516;
return v___x_5514_;
}
else
{
uint32_t v___x_5515_; uint8_t v___x_5516_;
v___x_5515_ = 0;
v___x_5516_ = lean_uint32_dec_eq(v_observedTargetId_5492_, v___x_5515_);
if (v___x_5516_ == 0)
{
uint8_t v___x_5517_;
v___x_5517_ = lean_uint32_dec_eq(v_observedTargetId_5492_, v_execTargetId_5493_);
if (v___x_5517_ == 0)
{
uint32_t v___x_5518_;
v___x_5518_ = 517;
return v___x_5518_;
}
else
{
uint8_t v___x_5519_;
v___x_5519_ = lean_uint64_dec_eq(v_observedDigest_5498_, v___x_5511_);
if (v___x_5519_ == 0)
{
uint8_t v___x_5520_;
v___x_5520_ = lean_uint64_dec_eq(v_observedDigest_5498_, v_execDigest_5499_);
if (v___x_5520_ == 0)
{
uint32_t v___x_5521_;
v___x_5521_ = 518;
return v___x_5521_;
}
else
{
uint32_t v___x_5522_;
v___x_5522_ = 257;
return v___x_5522_;
}
}
else
{
uint32_t v___x_5523_;
v___x_5523_ = 518;
return v___x_5523_;
}
}
}
else
{
uint32_t v___x_5524_;
v___x_5524_ = 517;
return v___x_5524_;
}
}
}
else
{
uint32_t v___x_5525_;
v___x_5525_ = 516;
return v___x_5525_;
}
}
}
}
}
}
}

LEAN_EXPORT uint64_t orb_resource_ledger_step(uint8_t v_opKind_5548_, uint32_t v_reservedSlots_5549_, uint32_t v_activeSlots_5550_, uint32_t v_maxSlots_5551_, uint64_t v_spentCents_5552_, uint64_t v_costDeltaCents_5553_, uint64_t v_budgetCents_5554_, uint64_t v_nowTick_5555_, uint64_t v_ttlExpiryTick_5556_){
_start:
{
uint32_t v___y_5558_; uint32_t v___y_5559_; uint32_t v___y_5560_; uint32_t v___y_5573_; uint32_t v___y_5574_; uint8_t v___y_5575_; uint32_t v___y_5576_; uint8_t v___y_5577_; uint8_t v_activeFits_5586_; uint8_t v___x_5587_; uint32_t v___y_5589_; uint8_t v___y_5590_; uint32_t v___y_5591_; uint8_t v___y_5592_; uint8_t v___y_5593_; uint8_t v___y_5594_; uint8_t v___y_5595_; uint32_t v___y_5596_; uint32_t v___y_5598_; uint8_t v___y_5599_; uint8_t v___y_5600_; uint8_t v___y_5601_; uint8_t v___y_5602_; uint8_t v___y_5603_; uint32_t v___y_5604_; uint32_t v___y_5608_; uint8_t v___y_5609_; uint8_t v___y_5610_; uint8_t v___y_5611_; uint8_t v___y_5612_; uint8_t v___y_5613_; uint32_t v___y_5614_; uint32_t v___y_5618_; uint8_t v___y_5619_; uint8_t v___y_5620_; uint8_t v___y_5621_; uint8_t v___y_5622_; uint8_t v___y_5623_; uint32_t v___y_5627_; uint8_t v___y_5628_; uint8_t v___y_5629_; uint8_t v___y_5630_; uint8_t v___y_5631_; uint8_t v___y_5632_; uint8_t v___y_5636_; uint8_t v___y_5637_; uint32_t v___y_5638_; uint8_t v___y_5639_; uint8_t v___y_5640_; uint8_t v___y_5641_; uint8_t v___y_5642_; uint8_t v___y_5646_; uint8_t v___y_5647_; uint32_t v___y_5648_; uint8_t v___y_5649_; uint8_t v___y_5650_; uint8_t v___y_5651_; uint8_t v___y_5652_; uint8_t v___y_5656_; uint8_t v___y_5657_; uint32_t v___y_5658_; uint8_t v___y_5659_; uint8_t v___y_5660_; uint8_t v___y_5661_; uint8_t v___y_5662_; uint8_t v___y_5666_; uint32_t v___y_5667_; uint8_t v___y_5668_; uint8_t v___y_5678_; uint32_t v___y_5679_; uint64_t v___y_5680_; uint8_t v___y_5683_; uint32_t v___y_5684_; uint8_t v___y_5685_; uint32_t v___y_5689_;
v_activeFits_5586_ = lean_uint32_dec_le(v_activeSlots_5550_, v_maxSlots_5551_);
v___x_5587_ = 1;
if (v_activeFits_5586_ == 0)
{
uint32_t v___x_5692_;
v___x_5692_ = 0;
v___y_5689_ = v___x_5692_;
goto v___jp_5688_;
}
else
{
uint32_t v___x_5693_;
v___x_5693_ = lean_uint32_sub(v_maxSlots_5551_, v_activeSlots_5550_);
v___y_5689_ = v___x_5693_;
goto v___jp_5688_;
}
v___jp_5557_:
{
uint32_t v___x_5561_; uint32_t v___x_5562_; uint32_t v___x_5563_; uint32_t v___x_5564_; uint32_t v___x_5565_; uint32_t v_hi32_5566_; uint64_t v___x_5567_; uint64_t v___x_5568_; uint64_t v___x_5569_; uint64_t v___x_5570_; uint64_t v___x_5571_;
v___x_5561_ = 65535;
v___x_5562_ = lean_uint32_land(v___y_5559_, v___x_5561_);
v___x_5563_ = lean_uint32_land(v___y_5558_, v___x_5561_);
v___x_5564_ = 16;
v___x_5565_ = lean_uint32_shift_left(v___x_5563_, v___x_5564_);
v_hi32_5566_ = lean_uint32_lor(v___x_5562_, v___x_5565_);
v___x_5567_ = lean_uint32_to_uint64(v___y_5560_);
v___x_5568_ = lean_uint32_to_uint64(v_hi32_5566_);
v___x_5569_ = 32ULL;
v___x_5570_ = lean_uint64_shift_left(v___x_5568_, v___x_5569_);
v___x_5571_ = lean_uint64_lor(v___x_5567_, v___x_5570_);
return v___x_5571_;
}
v___jp_5572_:
{
if (v___y_5575_ == 0)
{
v___y_5558_ = v___y_5573_;
v___y_5559_ = v___y_5576_;
v___y_5560_ = v___y_5574_;
goto v___jp_5557_;
}
else
{
if (v___y_5577_ == 0)
{
uint32_t v___x_5578_;
v___x_5578_ = 2;
v___y_5558_ = v___y_5573_;
v___y_5559_ = v___y_5576_;
v___y_5560_ = v___x_5578_;
goto v___jp_5557_;
}
else
{
uint32_t v___x_5579_; uint32_t v___x_5580_; uint32_t v___x_5581_; uint32_t v___x_5582_; uint32_t v___x_5583_; uint32_t v___x_5584_; uint32_t v___x_5585_;
v___x_5579_ = 257;
v___x_5580_ = lean_uint8_to_uint32(v_opKind_5548_);
v___x_5581_ = 255;
v___x_5582_ = lean_uint32_land(v___x_5580_, v___x_5581_);
v___x_5583_ = 1;
v___x_5584_ = lean_uint32_shift_left(v___x_5582_, v___x_5583_);
v___x_5585_ = lean_uint32_lor(v___x_5579_, v___x_5584_);
v___y_5558_ = v___y_5573_;
v___y_5559_ = v___y_5576_;
v___y_5560_ = v___x_5585_;
goto v___jp_5557_;
}
}
}
v___jp_5588_:
{
if (v___y_5593_ == 0)
{
if (v___y_5594_ == 0)
{
if (v___y_5595_ == 0)
{
v___y_5573_ = v___y_5596_;
v___y_5574_ = v___y_5589_;
v___y_5575_ = v___y_5590_;
v___y_5576_ = v___y_5591_;
v___y_5577_ = v___y_5592_;
goto v___jp_5572_;
}
else
{
v___y_5573_ = v___y_5596_;
v___y_5574_ = v___y_5589_;
v___y_5575_ = v___y_5590_;
v___y_5576_ = v___y_5591_;
v___y_5577_ = v___x_5587_;
goto v___jp_5572_;
}
}
else
{
v___y_5573_ = v___y_5596_;
v___y_5574_ = v___y_5589_;
v___y_5575_ = v___y_5590_;
v___y_5576_ = v___y_5591_;
v___y_5577_ = v___x_5587_;
goto v___jp_5572_;
}
}
else
{
v___y_5573_ = v___y_5596_;
v___y_5574_ = v___y_5589_;
v___y_5575_ = v___y_5590_;
v___y_5576_ = v___y_5591_;
v___y_5577_ = v___x_5587_;
goto v___jp_5572_;
}
}
v___jp_5597_:
{
if (v___y_5603_ == 0)
{
v___y_5589_ = v___y_5598_;
v___y_5590_ = v___y_5599_;
v___y_5591_ = v___y_5604_;
v___y_5592_ = v___y_5600_;
v___y_5593_ = v___y_5601_;
v___y_5594_ = v___y_5602_;
v___y_5595_ = v___y_5603_;
v___y_5596_ = v_activeSlots_5550_;
goto v___jp_5588_;
}
else
{
uint32_t v___x_5605_; uint32_t v___x_5606_;
v___x_5605_ = 1;
v___x_5606_ = lean_uint32_sub(v_activeSlots_5550_, v___x_5605_);
v___y_5589_ = v___y_5598_;
v___y_5590_ = v___y_5599_;
v___y_5591_ = v___y_5604_;
v___y_5592_ = v___y_5600_;
v___y_5593_ = v___y_5601_;
v___y_5594_ = v___y_5602_;
v___y_5595_ = v___y_5603_;
v___y_5596_ = v___x_5606_;
goto v___jp_5588_;
}
}
v___jp_5607_:
{
if (v___y_5612_ == 0)
{
v___y_5598_ = v___y_5608_;
v___y_5599_ = v___y_5609_;
v___y_5600_ = v___y_5610_;
v___y_5601_ = v___y_5611_;
v___y_5602_ = v___y_5612_;
v___y_5603_ = v___y_5613_;
v___y_5604_ = v___y_5614_;
goto v___jp_5597_;
}
else
{
uint32_t v___x_5615_; uint32_t v___x_5616_;
v___x_5615_ = 1;
v___x_5616_ = lean_uint32_add(v_activeSlots_5550_, v___x_5615_);
v___y_5589_ = v___y_5608_;
v___y_5590_ = v___y_5609_;
v___y_5591_ = v___y_5614_;
v___y_5592_ = v___y_5610_;
v___y_5593_ = v___y_5611_;
v___y_5594_ = v___y_5612_;
v___y_5595_ = v___y_5613_;
v___y_5596_ = v___x_5616_;
goto v___jp_5588_;
}
}
v___jp_5617_:
{
uint32_t v___x_5624_; uint32_t v___x_5625_;
v___x_5624_ = 1;
v___x_5625_ = lean_uint32_sub(v_reservedSlots_5549_, v___x_5624_);
v___y_5608_ = v___y_5618_;
v___y_5609_ = v___y_5619_;
v___y_5610_ = v___y_5620_;
v___y_5611_ = v___y_5621_;
v___y_5612_ = v___y_5622_;
v___y_5613_ = v___y_5623_;
v___y_5614_ = v___x_5625_;
goto v___jp_5607_;
}
v___jp_5626_:
{
if (v___y_5629_ == 0)
{
if (v___y_5630_ == 0)
{
if (v___y_5632_ == 0)
{
v___y_5598_ = v___y_5627_;
v___y_5599_ = v___y_5628_;
v___y_5600_ = v___y_5632_;
v___y_5601_ = v___y_5629_;
v___y_5602_ = v___y_5630_;
v___y_5603_ = v___y_5631_;
v___y_5604_ = v_reservedSlots_5549_;
goto v___jp_5597_;
}
else
{
v___y_5618_ = v___y_5627_;
v___y_5619_ = v___y_5628_;
v___y_5620_ = v___y_5632_;
v___y_5621_ = v___y_5629_;
v___y_5622_ = v___y_5630_;
v___y_5623_ = v___y_5631_;
goto v___jp_5617_;
}
}
else
{
v___y_5618_ = v___y_5627_;
v___y_5619_ = v___y_5628_;
v___y_5620_ = v___y_5632_;
v___y_5621_ = v___y_5629_;
v___y_5622_ = v___y_5630_;
v___y_5623_ = v___y_5631_;
goto v___jp_5617_;
}
}
else
{
uint32_t v___x_5633_; uint32_t v___x_5634_;
v___x_5633_ = 1;
v___x_5634_ = lean_uint32_add(v_reservedSlots_5549_, v___x_5633_);
v___y_5608_ = v___y_5627_;
v___y_5609_ = v___y_5628_;
v___y_5610_ = v___y_5632_;
v___y_5611_ = v___y_5629_;
v___y_5612_ = v___y_5630_;
v___y_5613_ = v___y_5631_;
v___y_5614_ = v___x_5634_;
goto v___jp_5607_;
}
}
v___jp_5635_:
{
uint8_t v___x_5643_; uint8_t v___x_5644_;
v___x_5643_ = 3;
v___x_5644_ = lean_uint8_dec_eq(v_opKind_5548_, v___x_5643_);
if (v___x_5644_ == 0)
{
v___y_5627_ = v___y_5638_;
v___y_5628_ = v___y_5639_;
v___y_5629_ = v___y_5640_;
v___y_5630_ = v___y_5641_;
v___y_5631_ = v___y_5642_;
v___y_5632_ = v___x_5644_;
goto v___jp_5626_;
}
else
{
if (v___y_5639_ == 0)
{
v___y_5627_ = v___y_5638_;
v___y_5628_ = v___y_5639_;
v___y_5629_ = v___y_5640_;
v___y_5630_ = v___y_5641_;
v___y_5631_ = v___y_5642_;
v___y_5632_ = v___y_5639_;
goto v___jp_5626_;
}
else
{
if (v___y_5637_ == 0)
{
v___y_5627_ = v___y_5638_;
v___y_5628_ = v___y_5639_;
v___y_5629_ = v___y_5640_;
v___y_5630_ = v___y_5641_;
v___y_5631_ = v___y_5642_;
v___y_5632_ = v___y_5637_;
goto v___jp_5626_;
}
else
{
v___y_5627_ = v___y_5638_;
v___y_5628_ = v___y_5639_;
v___y_5629_ = v___y_5640_;
v___y_5630_ = v___y_5641_;
v___y_5631_ = v___y_5642_;
v___y_5632_ = v___y_5636_;
goto v___jp_5626_;
}
}
}
}
v___jp_5645_:
{
uint8_t v___x_5653_; uint8_t v___x_5654_;
v___x_5653_ = 2;
v___x_5654_ = lean_uint8_dec_eq(v_opKind_5548_, v___x_5653_);
if (v___x_5654_ == 0)
{
v___y_5636_ = v___y_5646_;
v___y_5637_ = v___y_5647_;
v___y_5638_ = v___y_5648_;
v___y_5639_ = v___y_5649_;
v___y_5640_ = v___y_5651_;
v___y_5641_ = v___y_5652_;
v___y_5642_ = v___x_5654_;
goto v___jp_5635_;
}
else
{
if (v___y_5649_ == 0)
{
v___y_5636_ = v___y_5646_;
v___y_5637_ = v___y_5647_;
v___y_5638_ = v___y_5648_;
v___y_5639_ = v___y_5649_;
v___y_5640_ = v___y_5651_;
v___y_5641_ = v___y_5652_;
v___y_5642_ = v___y_5649_;
goto v___jp_5635_;
}
else
{
v___y_5636_ = v___y_5646_;
v___y_5637_ = v___y_5647_;
v___y_5638_ = v___y_5648_;
v___y_5639_ = v___y_5649_;
v___y_5640_ = v___y_5651_;
v___y_5641_ = v___y_5652_;
v___y_5642_ = v___y_5650_;
goto v___jp_5635_;
}
}
}
v___jp_5655_:
{
uint8_t v___x_5663_; uint8_t v___x_5664_;
v___x_5663_ = 1;
v___x_5664_ = lean_uint8_dec_eq(v_opKind_5548_, v___x_5663_);
if (v___x_5664_ == 0)
{
v___y_5646_ = v___y_5656_;
v___y_5647_ = v___y_5657_;
v___y_5648_ = v___y_5658_;
v___y_5649_ = v___y_5659_;
v___y_5650_ = v___y_5661_;
v___y_5651_ = v___y_5662_;
v___y_5652_ = v___x_5664_;
goto v___jp_5645_;
}
else
{
if (v___y_5659_ == 0)
{
v___y_5646_ = v___y_5656_;
v___y_5647_ = v___y_5657_;
v___y_5648_ = v___y_5658_;
v___y_5649_ = v___y_5659_;
v___y_5650_ = v___y_5661_;
v___y_5651_ = v___y_5662_;
v___y_5652_ = v___y_5659_;
goto v___jp_5645_;
}
else
{
if (v___y_5657_ == 0)
{
v___y_5646_ = v___y_5656_;
v___y_5647_ = v___y_5657_;
v___y_5648_ = v___y_5658_;
v___y_5649_ = v___y_5659_;
v___y_5650_ = v___y_5661_;
v___y_5651_ = v___y_5662_;
v___y_5652_ = v___y_5657_;
goto v___jp_5645_;
}
else
{
v___y_5646_ = v___y_5656_;
v___y_5647_ = v___y_5657_;
v___y_5648_ = v___y_5658_;
v___y_5649_ = v___y_5659_;
v___y_5650_ = v___y_5661_;
v___y_5651_ = v___y_5662_;
v___y_5652_ = v___y_5660_;
goto v___jp_5645_;
}
}
}
}
v___jp_5665_:
{
uint8_t v_hasFreeSlot_5669_; uint32_t v___x_5670_; uint8_t v_hasReserved_5671_; uint8_t v_hasActive_5672_; uint8_t v_ttlLive_5673_; uint8_t v_ttlExpired_5674_; uint8_t v___x_5675_; uint8_t v___x_5676_;
v_hasFreeSlot_5669_ = lean_uint32_dec_lt(v_reservedSlots_5549_, v___y_5667_);
v___x_5670_ = 0;
v_hasReserved_5671_ = lean_uint32_dec_lt(v___x_5670_, v_reservedSlots_5549_);
v_hasActive_5672_ = lean_uint32_dec_lt(v___x_5670_, v_activeSlots_5550_);
v_ttlLive_5673_ = lean_uint64_dec_lt(v_nowTick_5555_, v_ttlExpiryTick_5556_);
v_ttlExpired_5674_ = lean_uint64_dec_le(v_ttlExpiryTick_5556_, v_nowTick_5555_);
v___x_5675_ = 0;
v___x_5676_ = lean_uint8_dec_eq(v_opKind_5548_, v___x_5675_);
if (v___x_5676_ == 0)
{
v___y_5656_ = v_ttlExpired_5674_;
v___y_5657_ = v_hasReserved_5671_;
v___y_5658_ = v___x_5670_;
v___y_5659_ = v___y_5666_;
v___y_5660_ = v_ttlLive_5673_;
v___y_5661_ = v_hasActive_5672_;
v___y_5662_ = v___x_5676_;
goto v___jp_5655_;
}
else
{
if (v___y_5668_ == 0)
{
v___y_5656_ = v_ttlExpired_5674_;
v___y_5657_ = v_hasReserved_5671_;
v___y_5658_ = v___x_5670_;
v___y_5659_ = v___y_5666_;
v___y_5660_ = v_ttlLive_5673_;
v___y_5661_ = v_hasActive_5672_;
v___y_5662_ = v___y_5668_;
goto v___jp_5655_;
}
else
{
if (v_hasFreeSlot_5669_ == 0)
{
v___y_5656_ = v_ttlExpired_5674_;
v___y_5657_ = v_hasReserved_5671_;
v___y_5658_ = v___x_5670_;
v___y_5659_ = v___y_5666_;
v___y_5660_ = v_ttlLive_5673_;
v___y_5661_ = v_hasActive_5672_;
v___y_5662_ = v_hasFreeSlot_5669_;
goto v___jp_5655_;
}
else
{
v___y_5656_ = v_ttlExpired_5674_;
v___y_5657_ = v_hasReserved_5671_;
v___y_5658_ = v___x_5670_;
v___y_5659_ = v___y_5666_;
v___y_5660_ = v_ttlLive_5673_;
v___y_5661_ = v_hasActive_5672_;
v___y_5662_ = v_ttlLive_5673_;
goto v___jp_5655_;
}
}
}
}
v___jp_5677_:
{
if (v___y_5678_ == 0)
{
v___y_5666_ = v___y_5678_;
v___y_5667_ = v___y_5679_;
v___y_5668_ = v___y_5678_;
goto v___jp_5665_;
}
else
{
uint8_t v___x_5681_;
v___x_5681_ = lean_uint64_dec_le(v_costDeltaCents_5553_, v___y_5680_);
v___y_5666_ = v___y_5678_;
v___y_5667_ = v___y_5679_;
v___y_5668_ = v___x_5681_;
goto v___jp_5665_;
}
}
v___jp_5682_:
{
if (v___y_5683_ == 0)
{
uint64_t v___x_5686_;
v___x_5686_ = 0ULL;
v___y_5678_ = v___y_5685_;
v___y_5679_ = v___y_5684_;
v___y_5680_ = v___x_5686_;
goto v___jp_5677_;
}
else
{
uint64_t v___x_5687_;
v___x_5687_ = lean_uint64_sub(v_budgetCents_5554_, v_spentCents_5552_);
v___y_5678_ = v___y_5685_;
v___y_5679_ = v___y_5684_;
v___y_5680_ = v___x_5687_;
goto v___jp_5677_;
}
}
v___jp_5688_:
{
uint8_t v_budgetValid_5690_;
v_budgetValid_5690_ = lean_uint64_dec_le(v_spentCents_5552_, v_budgetCents_5554_);
if (v_activeFits_5586_ == 0)
{
v___y_5683_ = v_budgetValid_5690_;
v___y_5684_ = v___y_5689_;
v___y_5685_ = v_activeFits_5586_;
goto v___jp_5682_;
}
else
{
uint8_t v_reservedFits_5691_;
v_reservedFits_5691_ = lean_uint32_dec_le(v_reservedSlots_5549_, v___y_5689_);
if (v_reservedFits_5691_ == 0)
{
v___y_5683_ = v_budgetValid_5690_;
v___y_5684_ = v___y_5689_;
v___y_5685_ = v_reservedFits_5691_;
goto v___jp_5682_;
}
else
{
v___y_5683_ = v_budgetValid_5690_;
v___y_5684_ = v___y_5689_;
v___y_5685_ = v_budgetValid_5690_;
goto v___jp_5682_;
}
}
}
}
}

LEAN_EXPORT uint64_t orb_stream_bounded_commit_step(uint32_t v_prevLen_5714_, uint32_t v_prevCommit_5715_, uint32_t v_prevCheckpoint_5716_, uint32_t v_newLen_5717_, uint32_t v_rawCommit_5718_, uint32_t v_maxOpenTailBytes_5719_){
_start:
{
uint32_t v___y_5721_; uint32_t v___y_5722_; uint32_t v___x_5728_; uint8_t v_validCap_5729_; uint32_t v___y_5731_; uint8_t v___y_5732_; uint32_t v___y_5733_; uint32_t v___y_5737_; uint8_t v___y_5738_; uint32_t v___y_5739_; uint32_t v___y_5743_; uint8_t v___y_5744_; uint32_t v___y_5745_; uint32_t v___y_5746_; uint32_t v___y_5749_; uint8_t v___y_5750_; uint32_t v___y_5751_; uint8_t v___y_5755_; uint32_t v___y_5756_; uint8_t v___y_5759_; uint32_t v___y_5760_; uint8_t v___y_5763_; uint8_t v___x_5765_;
v___x_5728_ = 0;
v_validCap_5729_ = lean_uint32_dec_lt(v___x_5728_, v_maxOpenTailBytes_5719_);
v___x_5765_ = lean_uint32_dec_le(v_prevCommit_5715_, v_prevCheckpoint_5716_);
if (v___x_5765_ == 0)
{
v___y_5763_ = v___x_5765_;
goto v___jp_5762_;
}
else
{
uint8_t v___x_5766_;
v___x_5766_ = lean_uint32_dec_le(v_prevCheckpoint_5716_, v_prevLen_5714_);
if (v___x_5766_ == 0)
{
v___y_5763_ = v___x_5766_;
goto v___jp_5762_;
}
else
{
uint8_t v___x_5767_;
v___x_5767_ = lean_uint32_dec_le(v_prevLen_5714_, v_newLen_5717_);
v___y_5763_ = v___x_5767_;
goto v___jp_5762_;
}
}
v___jp_5720_:
{
uint64_t v___x_5723_; uint64_t v___x_5724_; uint64_t v___x_5725_; uint64_t v___x_5726_; uint64_t v___x_5727_;
v___x_5723_ = lean_uint32_to_uint64(v___y_5721_);
v___x_5724_ = lean_uint32_to_uint64(v___y_5722_);
v___x_5725_ = 32ULL;
v___x_5726_ = lean_uint64_shift_left(v___x_5724_, v___x_5725_);
v___x_5727_ = lean_uint64_lor(v___x_5723_, v___x_5726_);
return v___x_5727_;
}
v___jp_5730_:
{
if (v_validCap_5729_ == 0)
{
v___y_5721_ = v___x_5728_;
v___y_5722_ = v_prevCheckpoint_5716_;
goto v___jp_5720_;
}
else
{
if (v___y_5732_ == 0)
{
v___y_5721_ = v___x_5728_;
v___y_5722_ = v_prevCheckpoint_5716_;
goto v___jp_5720_;
}
else
{
uint32_t v___x_5734_; uint32_t v___x_5735_;
v___x_5734_ = 257;
v___x_5735_ = lean_uint32_lor(v___x_5734_, v___y_5733_);
v___y_5721_ = v___x_5735_;
v___y_5722_ = v___y_5731_;
goto v___jp_5720_;
}
}
}
v___jp_5736_:
{
uint8_t v___x_5740_;
v___x_5740_ = lean_uint32_dec_lt(v___y_5737_, v___y_5739_);
if (v___x_5740_ == 0)
{
v___y_5731_ = v___y_5739_;
v___y_5732_ = v___y_5738_;
v___y_5733_ = v___x_5728_;
goto v___jp_5730_;
}
else
{
uint32_t v___x_5741_;
v___x_5741_ = 512;
v___y_5731_ = v___y_5739_;
v___y_5732_ = v___y_5738_;
v___y_5733_ = v___x_5741_;
goto v___jp_5730_;
}
}
v___jp_5742_:
{
uint8_t v___x_5747_;
v___x_5747_ = lean_uint32_dec_le(v___y_5745_, v___y_5746_);
if (v___x_5747_ == 0)
{
v___y_5737_ = v___y_5743_;
v___y_5738_ = v___y_5744_;
v___y_5739_ = v___y_5745_;
goto v___jp_5736_;
}
else
{
v___y_5737_ = v___y_5743_;
v___y_5738_ = v___y_5744_;
v___y_5739_ = v___y_5746_;
goto v___jp_5736_;
}
}
v___jp_5748_:
{
uint8_t v___x_5752_;
v___x_5752_ = lean_uint32_dec_le(v_maxOpenTailBytes_5719_, v_newLen_5717_);
if (v___x_5752_ == 0)
{
v___y_5743_ = v___y_5749_;
v___y_5744_ = v___y_5750_;
v___y_5745_ = v___y_5751_;
v___y_5746_ = v___x_5728_;
goto v___jp_5742_;
}
else
{
uint32_t v___x_5753_;
v___x_5753_ = lean_uint32_sub(v_newLen_5717_, v_maxOpenTailBytes_5719_);
v___y_5743_ = v___y_5749_;
v___y_5744_ = v___y_5750_;
v___y_5745_ = v___y_5751_;
v___y_5746_ = v___x_5753_;
goto v___jp_5742_;
}
}
v___jp_5754_:
{
uint8_t v___x_5757_;
v___x_5757_ = lean_uint32_dec_le(v_prevCheckpoint_5716_, v___y_5756_);
if (v___x_5757_ == 0)
{
v___y_5749_ = v___y_5756_;
v___y_5750_ = v___y_5755_;
v___y_5751_ = v_prevCheckpoint_5716_;
goto v___jp_5748_;
}
else
{
v___y_5749_ = v___y_5756_;
v___y_5750_ = v___y_5755_;
v___y_5751_ = v___y_5756_;
goto v___jp_5748_;
}
}
v___jp_5758_:
{
uint8_t v___x_5761_;
v___x_5761_ = lean_uint32_dec_le(v_prevCommit_5715_, v___y_5760_);
if (v___x_5761_ == 0)
{
v___y_5755_ = v___y_5759_;
v___y_5756_ = v_prevCommit_5715_;
goto v___jp_5754_;
}
else
{
v___y_5755_ = v___y_5759_;
v___y_5756_ = v___y_5760_;
goto v___jp_5754_;
}
}
v___jp_5762_:
{
uint8_t v___x_5764_;
v___x_5764_ = lean_uint32_dec_le(v_rawCommit_5718_, v_newLen_5717_);
if (v___x_5764_ == 0)
{
v___y_5759_ = v___y_5763_;
v___y_5760_ = v_newLen_5717_;
goto v___jp_5758_;
}
else
{
v___y_5759_ = v___y_5763_;
v___y_5760_ = v_rawCommit_5718_;
goto v___jp_5758_;
}
}
}
}

LEAN_EXPORT uint32_t orb_vm_cap_admit(uint8_t v_hasPoolOverride_5782_, uint8_t v_hasPoolMax_5783_, uint8_t v_hasProviderMax_5784_, uint8_t v_hasGlobalMax_5785_, uint8_t v_ancestorBlocked_5786_, uint32_t v_sharedActive_5787_, uint32_t v_globalMax_5788_, uint32_t v_poolActive_5789_, uint32_t v_poolMax_5790_, uint32_t v_providerActive_5791_, uint32_t v_providerMax_5792_){
_start:
{
uint8_t v___x_5805_; uint8_t v___x_5806_;
v___x_5805_ = 1;
v___x_5806_ = lean_uint8_dec_eq(v_ancestorBlocked_5786_, v___x_5805_);
if (v___x_5806_ == 0)
{
uint8_t v___x_5807_;
v___x_5807_ = lean_uint8_dec_eq(v_hasPoolOverride_5782_, v___x_5805_);
if (v___x_5807_ == 0)
{
uint8_t v___x_5808_; uint8_t v___x_5809_;
v___x_5808_ = 0;
v___x_5809_ = lean_uint8_dec_eq(v_hasGlobalMax_5785_, v___x_5808_);
if (v___x_5809_ == 0)
{
uint8_t v___x_5810_;
v___x_5810_ = lean_uint32_dec_lt(v_sharedActive_5787_, v_globalMax_5788_);
if (v___x_5810_ == 0)
{
uint32_t v___x_5811_;
v___x_5811_ = 512;
return v___x_5811_;
}
else
{
uint32_t v___x_5812_;
v___x_5812_ = 257;
return v___x_5812_;
}
}
else
{
uint32_t v___x_5813_;
v___x_5813_ = 257;
return v___x_5813_;
}
}
else
{
uint8_t v___x_5814_;
v___x_5814_ = lean_uint8_dec_eq(v_hasPoolMax_5783_, v___x_5805_);
if (v___x_5814_ == 0)
{
uint8_t v___x_5815_;
v___x_5815_ = lean_uint8_dec_eq(v_hasProviderMax_5784_, v___x_5805_);
if (v___x_5815_ == 0)
{
uint32_t v___x_5816_;
v___x_5816_ = 512;
return v___x_5816_;
}
else
{
goto v___jp_5800_;
}
}
else
{
goto v___jp_5800_;
}
}
}
else
{
uint32_t v___x_5817_;
v___x_5817_ = 512;
return v___x_5817_;
}
v___jp_5793_:
{
uint8_t v___x_5794_; uint8_t v___x_5795_;
v___x_5794_ = 0;
v___x_5795_ = lean_uint8_dec_eq(v_hasPoolMax_5783_, v___x_5794_);
if (v___x_5795_ == 0)
{
uint8_t v___x_5796_;
v___x_5796_ = lean_uint32_dec_lt(v_poolActive_5789_, v_poolMax_5790_);
if (v___x_5796_ == 0)
{
uint32_t v___x_5797_;
v___x_5797_ = 512;
return v___x_5797_;
}
else
{
uint32_t v___x_5798_;
v___x_5798_ = 257;
return v___x_5798_;
}
}
else
{
uint32_t v___x_5799_;
v___x_5799_ = 257;
return v___x_5799_;
}
}
v___jp_5800_:
{
uint8_t v___x_5801_; uint8_t v___x_5802_;
v___x_5801_ = 0;
v___x_5802_ = lean_uint8_dec_eq(v_hasProviderMax_5784_, v___x_5801_);
if (v___x_5802_ == 0)
{
uint8_t v___x_5803_;
v___x_5803_ = lean_uint32_dec_lt(v_providerActive_5791_, v_providerMax_5792_);
if (v___x_5803_ == 0)
{
uint32_t v___x_5804_;
v___x_5804_ = 512;
return v___x_5804_;
}
else
{
goto v___jp_5793_;
}
}
else
{
goto v___jp_5793_;
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

LEAN_EXPORT uint8_t leansys_verify_jsonl_tape(uint64_t v_keyOff_1173_, uint64_t v_keyLen_1174_, uint64_t v_valOff_1175_, uint64_t v_valLen_1176_, uint64_t v_bufCap_1177_, uint32_t v_depth_1178_){
_start:
{
uint8_t v___x_1179_;
v___x_1179_ = lean_uint64_dec_le(v_keyOff_1173_, v_bufCap_1177_);
if (v___x_1179_ == 0)
{
uint8_t v___x_1180_;
v___x_1180_ = 0;
return v___x_1180_;
}
else
{
uint64_t v___x_1181_; uint8_t v___x_1182_;
v___x_1181_ = lean_uint64_sub(v_bufCap_1177_, v_keyOff_1173_);
v___x_1182_ = lean_uint64_dec_le(v_keyLen_1174_, v___x_1181_);
if (v___x_1182_ == 0)
{
uint8_t v___x_1183_;
v___x_1183_ = 0;
return v___x_1183_;
}
else
{
uint8_t v___x_1184_;
v___x_1184_ = lean_uint64_dec_le(v_valOff_1175_, v_bufCap_1177_);
if (v___x_1184_ == 0)
{
uint8_t v___x_1185_;
v___x_1185_ = 0;
return v___x_1185_;
}
else
{
uint64_t v___x_1186_; uint8_t v___x_1187_;
v___x_1186_ = lean_uint64_sub(v_bufCap_1177_, v_valOff_1175_);
v___x_1187_ = lean_uint64_dec_le(v_valLen_1176_, v___x_1186_);
if (v___x_1187_ == 0)
{
uint8_t v___x_1188_;
v___x_1188_ = 0;
return v___x_1188_;
}
else
{
uint64_t v___x_1189_; uint8_t v___x_1190_;
v___x_1189_ = lean_uint64_add(v_keyOff_1173_, v_keyLen_1174_);
v___x_1190_ = lean_uint64_dec_le(v___x_1189_, v_valOff_1175_);
if (v___x_1190_ == 0)
{
uint8_t v___x_1191_;
v___x_1191_ = 0;
return v___x_1191_;
}
else
{
uint32_t v___x_1192_; uint8_t v___x_1193_;
v___x_1192_ = 64;
v___x_1193_ = lean_uint32_dec_le(v_depth_1178_, v___x_1192_);
if (v___x_1193_ == 0)
{
uint8_t v___x_1194_;
v___x_1194_ = 0;
return v___x_1194_;
}
else
{
uint8_t v___x_1195_;
v___x_1195_ = 1;
return v___x_1195_;
}
}
}
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_verify_ring_cursor(uint64_t v_head_1426_, uint64_t v_tail_1427_, uint64_t v_cap_1428_, uint64_t v_msgLen_1429_){
_start:
{
uint64_t v___x_1430_; uint8_t v___x_1431_;
v___x_1430_ = 0ULL;
v___x_1431_ = lean_uint64_dec_lt(v___x_1430_, v_cap_1428_);
if (v___x_1431_ == 0)
{
uint8_t v___x_1432_;
v___x_1432_ = 0;
return v___x_1432_;
}
else
{
uint8_t v___x_1433_;
v___x_1433_ = lean_uint64_dec_le(v_tail_1427_, v_head_1426_);
if (v___x_1433_ == 0)
{
uint8_t v___x_1434_;
v___x_1434_ = 0;
return v___x_1434_;
}
else
{
uint64_t v___x_1435_; uint8_t v___x_1436_;
v___x_1435_ = lean_uint64_sub(v_head_1426_, v_tail_1427_);
v___x_1436_ = lean_uint64_dec_le(v___x_1435_, v_cap_1428_);
if (v___x_1436_ == 0)
{
uint8_t v___x_1437_;
v___x_1437_ = 0;
return v___x_1437_;
}
else
{
uint64_t v___x_1438_; uint8_t v___x_1439_;
v___x_1438_ = lean_uint64_sub(v_cap_1428_, v___x_1435_);
v___x_1439_ = lean_uint64_dec_le(v_msgLen_1429_, v___x_1438_);
if (v___x_1439_ == 0)
{
uint8_t v___x_1440_;
v___x_1440_ = 0;
return v___x_1440_;
}
else
{
uint8_t v___x_1441_;
v___x_1441_ = 1;
return v___x_1441_;
}
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_verify_sst_block(uint32_t v_magic_1621_, uint32_t v_numEntries_1622_, uint64_t v_indexOff_1623_, uint64_t v_footerOff_1624_, uint64_t v_fileSize_1625_, uint64_t v_bloomMask_1626_){
_start:
{
uint32_t v___x_1627_; uint8_t v___x_1628_;
v___x_1627_ = 1280529236;
v___x_1628_ = lean_uint32_dec_eq(v_magic_1621_, v___x_1627_);
if (v___x_1628_ == 0)
{
uint8_t v___x_1629_;
v___x_1629_ = 0;
return v___x_1629_;
}
else
{
uint8_t v___x_1630_;
v___x_1630_ = lean_uint64_dec_le(v_indexOff_1623_, v_footerOff_1624_);
if (v___x_1630_ == 0)
{
uint8_t v___x_1631_;
v___x_1631_ = 0;
return v___x_1631_;
}
else
{
uint8_t v___x_1632_;
v___x_1632_ = lean_uint64_dec_le(v_footerOff_1624_, v_fileSize_1625_);
if (v___x_1632_ == 0)
{
uint8_t v___x_1633_;
v___x_1633_ = 0;
return v___x_1633_;
}
else
{
uint32_t v___x_1634_; uint8_t v___x_1635_;
v___x_1634_ = 0;
v___x_1635_ = lean_uint32_dec_eq(v_numEntries_1622_, v___x_1634_);
if (v___x_1635_ == 0)
{
uint64_t v___x_1636_; uint8_t v___x_1637_;
v___x_1636_ = 0ULL;
v___x_1637_ = lean_uint64_dec_eq(v_bloomMask_1626_, v___x_1636_);
if (v___x_1637_ == 0)
{
uint8_t v___x_1638_;
v___x_1638_ = 1;
return v___x_1638_;
}
else
{
uint8_t v___x_1639_;
v___x_1639_ = 0;
return v___x_1639_;
}
}
else
{
uint8_t v___x_1640_;
v___x_1640_ = 1;
return v___x_1640_;
}
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_verify_poll_interest(uint32_t v_activeConns_1863_, uint32_t v_maxConns_1864_, uint32_t v_keepAliveReqs_1865_, uint32_t v_maxKeepAlive_1866_, uint32_t v_idleMs_1867_, uint32_t v_maxIdleMs_1868_){
_start:
{
uint8_t v___x_1869_;
v___x_1869_ = lean_uint32_dec_le(v_activeConns_1863_, v_maxConns_1864_);
if (v___x_1869_ == 0)
{
uint8_t v___x_1870_;
v___x_1870_ = 0;
return v___x_1870_;
}
else
{
uint32_t v___x_1871_; uint8_t v___x_1872_;
v___x_1871_ = 1024;
v___x_1872_ = lean_uint32_dec_le(v_maxConns_1864_, v___x_1871_);
if (v___x_1872_ == 0)
{
uint8_t v___x_1873_;
v___x_1873_ = 0;
return v___x_1873_;
}
else
{
uint8_t v___x_1874_;
v___x_1874_ = lean_uint32_dec_lt(v_keepAliveReqs_1865_, v_maxKeepAlive_1866_);
if (v___x_1874_ == 0)
{
uint8_t v___x_1875_;
v___x_1875_ = 0;
return v___x_1875_;
}
else
{
uint8_t v___x_1876_;
v___x_1876_ = lean_uint32_dec_le(v_idleMs_1867_, v_maxIdleMs_1868_);
if (v___x_1876_ == 0)
{
uint8_t v___x_1877_;
v___x_1877_ = 0;
return v___x_1877_;
}
else
{
uint8_t v___x_1878_;
v___x_1878_ = 1;
return v___x_1878_;
}
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_verify_rlimit_budget(uint64_t v_rssBytes_2101_, uint64_t v_maxRssBytes_2102_, uint64_t v_elapsedMs_2103_, uint64_t v_timeoutMs_2104_, uint64_t v_pipeBytes_2105_, uint64_t v_maxPipeBytes_2106_){
_start:
{
uint8_t v___x_2107_;
v___x_2107_ = lean_uint64_dec_le(v_rssBytes_2101_, v_maxRssBytes_2102_);
if (v___x_2107_ == 0)
{
uint8_t v___x_2108_;
v___x_2108_ = 0;
return v___x_2108_;
}
else
{
uint8_t v___x_2109_;
v___x_2109_ = lean_uint64_dec_le(v_elapsedMs_2103_, v_timeoutMs_2104_);
if (v___x_2109_ == 0)
{
uint8_t v___x_2110_;
v___x_2110_ = 0;
return v___x_2110_;
}
else
{
uint8_t v___x_2111_;
v___x_2111_ = lean_uint64_dec_le(v_pipeBytes_2105_, v_maxPipeBytes_2106_);
if (v___x_2111_ == 0)
{
uint8_t v___x_2112_;
v___x_2112_ = 0;
return v___x_2112_;
}
else
{
uint8_t v___x_2113_;
v___x_2113_ = 1;
return v___x_2113_;
}
}
}
}
}

LEAN_EXPORT uint64_t leansys_mix64_word(uint64_t v_acc_2329_, uint64_t v_word_2330_){
_start:
{
uint64_t v___x_2331_; uint64_t v___x_2332_; uint64_t v___x_2333_; uint64_t v___x_2334_; uint64_t v_z_2335_; uint64_t v___x_2336_; uint64_t v___x_2337_; uint64_t v___x_2338_; uint64_t v___x_2339_; uint64_t v_z1_2340_; uint64_t v___x_2341_; uint64_t v___x_2342_; uint64_t v___x_2343_;
v___x_2331_ = 11400714819323198485ULL;
v___x_2332_ = lean_uint64_mul(v_word_2330_, v___x_2331_);
v___x_2333_ = lean_uint64_xor(v_acc_2329_, v___x_2332_);
v___x_2334_ = 13787848793156543929ULL;
v_z_2335_ = lean_uint64_mul(v___x_2333_, v___x_2334_);
v___x_2336_ = 30ULL;
v___x_2337_ = lean_uint64_shift_right(v_z_2335_, v___x_2336_);
v___x_2338_ = lean_uint64_xor(v_z_2335_, v___x_2337_);
v___x_2339_ = 10723151780598845931ULL;
v_z1_2340_ = lean_uint64_mul(v___x_2338_, v___x_2339_);
v___x_2341_ = 31ULL;
v___x_2342_ = lean_uint64_shift_right(v_z1_2340_, v___x_2341_);
v___x_2343_ = lean_uint64_xor(v_z1_2340_, v___x_2342_);
return v___x_2343_;
}
}

LEAN_EXPORT uint8_t leansys_verify_composite_key_order(uint64_t v_hiA_2350_, uint64_t v_loA_2351_, uint64_t v_seqA_2352_, uint64_t v_hiB_2353_, uint64_t v_loB_2354_, uint64_t v_seqB_2355_){
_start:
{
uint8_t v___x_2356_;
v___x_2356_ = lean_uint64_dec_lt(v_hiA_2350_, v_hiB_2353_);
if (v___x_2356_ == 0)
{
uint8_t v___x_2357_;
v___x_2357_ = lean_uint64_dec_eq(v_hiA_2350_, v_hiB_2353_);
if (v___x_2357_ == 0)
{
uint8_t v___x_2358_;
v___x_2358_ = 0;
return v___x_2358_;
}
else
{
uint8_t v___x_2359_;
v___x_2359_ = lean_uint64_dec_lt(v_loA_2351_, v_loB_2354_);
if (v___x_2359_ == 0)
{
uint8_t v___x_2360_;
v___x_2360_ = lean_uint64_dec_eq(v_loA_2351_, v_loB_2354_);
if (v___x_2360_ == 0)
{
uint8_t v___x_2361_;
v___x_2361_ = 0;
return v___x_2361_;
}
else
{
uint8_t v___x_2362_;
v___x_2362_ = lean_uint64_dec_le(v_seqA_2352_, v_seqB_2355_);
if (v___x_2362_ == 0)
{
uint8_t v___x_2363_;
v___x_2363_ = 0;
return v___x_2363_;
}
else
{
uint8_t v___x_2364_;
v___x_2364_ = 1;
return v___x_2364_;
}
}
}
else
{
uint8_t v___x_2365_;
v___x_2365_ = 1;
return v___x_2365_;
}
}
}
else
{
uint8_t v___x_2366_;
v___x_2366_ = 1;
return v___x_2366_;
}
}
}

LEAN_EXPORT uint8_t leansys_verify_token_auth(uint8_t v_matchCurrent_2586_, uint8_t v_hasPrev_2587_, uint8_t v_matchPrev_2588_, uint8_t v_scopeOk_2589_, uint64_t v_nowEpoch_2590_, uint64_t v_expiresAt_2591_){
_start:
{
uint8_t v___x_2592_; uint8_t v___x_2598_;
v___x_2592_ = 1;
v___x_2598_ = lean_uint8_dec_eq(v_matchCurrent_2586_, v___x_2592_);
if (v___x_2598_ == 0)
{
uint8_t v___x_2599_;
v___x_2599_ = lean_uint8_dec_eq(v_hasPrev_2587_, v___x_2592_);
if (v___x_2599_ == 0)
{
uint8_t v___x_2600_;
v___x_2600_ = 0;
return v___x_2600_;
}
else
{
uint8_t v___x_2601_;
v___x_2601_ = lean_uint8_dec_eq(v_matchPrev_2588_, v___x_2592_);
if (v___x_2601_ == 0)
{
uint8_t v___x_2602_;
v___x_2602_ = 0;
return v___x_2602_;
}
else
{
goto v___jp_2593_;
}
}
}
else
{
goto v___jp_2593_;
}
v___jp_2593_:
{
uint8_t v___x_2594_;
v___x_2594_ = lean_uint8_dec_eq(v_scopeOk_2589_, v___x_2592_);
if (v___x_2594_ == 0)
{
uint8_t v___x_2595_;
v___x_2595_ = 0;
return v___x_2595_;
}
else
{
uint8_t v___x_2596_;
v___x_2596_ = lean_uint64_dec_lt(v_nowEpoch_2590_, v_expiresAt_2591_);
if (v___x_2596_ == 0)
{
uint8_t v___x_2597_;
v___x_2597_ = 0;
return v___x_2597_;
}
else
{
return v___x_2592_;
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_verify_log_window(uint64_t v_startOff_2829_, uint64_t v_nextOff_2830_, uint64_t v_fileLen_2831_, uint64_t v_maxBytes_2832_){
_start:
{
uint8_t v___x_2833_;
v___x_2833_ = lean_uint64_dec_le(v_startOff_2829_, v_nextOff_2830_);
if (v___x_2833_ == 0)
{
uint8_t v___x_2834_;
v___x_2834_ = 0;
return v___x_2834_;
}
else
{
uint8_t v___x_2835_;
v___x_2835_ = lean_uint64_dec_le(v_nextOff_2830_, v_fileLen_2831_);
if (v___x_2835_ == 0)
{
uint8_t v___x_2836_;
v___x_2836_ = 0;
return v___x_2836_;
}
else
{
uint64_t v___x_2837_; uint8_t v___x_2838_;
v___x_2837_ = lean_uint64_sub(v_nextOff_2830_, v_startOff_2829_);
v___x_2838_ = lean_uint64_dec_le(v___x_2837_, v_maxBytes_2832_);
if (v___x_2838_ == 0)
{
uint8_t v___x_2839_;
v___x_2839_ = 0;
return v___x_2839_;
}
else
{
uint64_t v___x_2840_; uint8_t v___x_2841_;
v___x_2840_ = 262144ULL;
v___x_2841_ = lean_uint64_dec_le(v_maxBytes_2832_, v___x_2840_);
if (v___x_2841_ == 0)
{
uint8_t v___x_2842_;
v___x_2842_ = 0;
return v___x_2842_;
}
else
{
uint8_t v___x_2843_;
v___x_2843_ = 1;
return v___x_2843_;
}
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_verify_jsonrpc_frame(uint8_t v_hasV2_3020_, uint8_t v_hasId_3021_, uint32_t v_methodLen_3022_, uint64_t v_payloadLen_3023_){
_start:
{
uint8_t v___x_3024_; uint8_t v___x_3025_;
v___x_3024_ = 1;
v___x_3025_ = lean_uint8_dec_eq(v_hasV2_3020_, v___x_3024_);
if (v___x_3025_ == 0)
{
uint8_t v___x_3026_;
v___x_3026_ = 0;
return v___x_3026_;
}
else
{
uint8_t v___x_3027_;
v___x_3027_ = lean_uint8_dec_le(v_hasId_3021_, v___x_3024_);
if (v___x_3027_ == 0)
{
uint8_t v___x_3028_;
v___x_3028_ = 0;
return v___x_3028_;
}
else
{
uint32_t v___x_3029_; uint8_t v___x_3030_;
v___x_3029_ = 0;
v___x_3030_ = lean_uint32_dec_lt(v___x_3029_, v_methodLen_3022_);
if (v___x_3030_ == 0)
{
uint8_t v___x_3031_;
v___x_3031_ = 0;
return v___x_3031_;
}
else
{
uint32_t v___x_3032_; uint8_t v___x_3033_;
v___x_3032_ = 128;
v___x_3033_ = lean_uint32_dec_le(v_methodLen_3022_, v___x_3032_);
if (v___x_3033_ == 0)
{
uint8_t v___x_3034_;
v___x_3034_ = 0;
return v___x_3034_;
}
else
{
uint64_t v___x_3035_; uint8_t v___x_3036_;
v___x_3035_ = 4194304ULL;
v___x_3036_ = lean_uint64_dec_le(v_payloadLen_3023_, v___x_3035_);
if (v___x_3036_ == 0)
{
uint8_t v___x_3037_;
v___x_3037_ = 0;
return v___x_3037_;
}
else
{
return v___x_3024_;
}
}
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_gate_admit(uint8_t v_noSorryAx_3218_, uint8_t v_statementPinned_3219_, uint8_t v_certVerified_3220_){
_start:
{
uint8_t v___x_3221_; uint8_t v___x_3222_;
v___x_3221_ = 1;
v___x_3222_ = lean_uint8_dec_eq(v_noSorryAx_3218_, v___x_3221_);
if (v___x_3222_ == 0)
{
uint8_t v___x_3223_;
v___x_3223_ = 0;
return v___x_3223_;
}
else
{
uint8_t v___x_3224_;
v___x_3224_ = lean_uint8_dec_eq(v_statementPinned_3219_, v___x_3221_);
if (v___x_3224_ == 0)
{
uint8_t v___x_3225_;
v___x_3225_ = 0;
return v___x_3225_;
}
else
{
uint8_t v___x_3226_;
v___x_3226_ = lean_uint8_dec_eq(v_certVerified_3220_, v___x_3221_);
if (v___x_3226_ == 0)
{
uint8_t v___x_3227_;
v___x_3227_ = 0;
return v___x_3227_;
}
else
{
return v___x_3221_;
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_verify_mmap_seqlock(uint32_t v_magic_3380_, uint32_t v_schemaVersion_3381_, uint32_t v_expectedVersion_3382_, uint64_t v_seqBefore_3383_, uint64_t v_seqAfter_3384_, uint64_t v_writerEpoch_3385_, uint64_t v_minEpoch_3386_, uint64_t v_payloadLen_3387_, uint64_t v_ringCap_3388_){
_start:
{
uint32_t v___x_3389_; uint8_t v___x_3390_;
v___x_3389_ = 1280527693;
v___x_3390_ = lean_uint32_dec_eq(v_magic_3380_, v___x_3389_);
if (v___x_3390_ == 0)
{
uint8_t v___x_3391_;
v___x_3391_ = 0;
return v___x_3391_;
}
else
{
uint8_t v___x_3392_;
v___x_3392_ = lean_uint32_dec_eq(v_schemaVersion_3381_, v_expectedVersion_3382_);
if (v___x_3392_ == 0)
{
uint8_t v___x_3393_;
v___x_3393_ = 0;
return v___x_3393_;
}
else
{
uint8_t v___x_3394_;
v___x_3394_ = lean_uint64_dec_eq(v_seqBefore_3383_, v_seqAfter_3384_);
if (v___x_3394_ == 0)
{
uint8_t v___x_3395_;
v___x_3395_ = 0;
return v___x_3395_;
}
else
{
uint64_t v___x_3396_; uint64_t v___x_3397_; uint64_t v___x_3398_; uint8_t v___x_3399_;
v___x_3396_ = 2ULL;
v___x_3397_ = lean_uint64_mod(v_seqBefore_3383_, v___x_3396_);
v___x_3398_ = 0ULL;
v___x_3399_ = lean_uint64_dec_eq(v___x_3397_, v___x_3398_);
if (v___x_3399_ == 0)
{
uint8_t v___x_3400_;
v___x_3400_ = 0;
return v___x_3400_;
}
else
{
uint8_t v___x_3401_;
v___x_3401_ = lean_uint64_dec_le(v_minEpoch_3386_, v_writerEpoch_3385_);
if (v___x_3401_ == 0)
{
uint8_t v___x_3402_;
v___x_3402_ = 0;
return v___x_3402_;
}
else
{
uint8_t v___x_3403_;
v___x_3403_ = lean_uint64_dec_le(v_payloadLen_3387_, v_ringCap_3388_);
if (v___x_3403_ == 0)
{
uint8_t v___x_3404_;
v___x_3404_ = 0;
return v___x_3404_;
}
else
{
uint8_t v___x_3405_;
v___x_3405_ = 1;
return v___x_3405_;
}
}
}
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_verify_proc_stat_fields(uint64_t v_commOpenIdx_3831_, uint64_t v_commCloseIdx_3832_, uint64_t v_totalLen_3833_, uint64_t v_minFieldsAfterComm_3834_, uint64_t v_actualFields_3835_){
_start:
{
uint8_t v___x_3836_;
v___x_3836_ = lean_uint64_dec_lt(v_commOpenIdx_3831_, v_commCloseIdx_3832_);
if (v___x_3836_ == 0)
{
uint8_t v___x_3837_;
v___x_3837_ = 0;
return v___x_3837_;
}
else
{
uint64_t v___x_3838_; uint64_t v___x_3839_; uint8_t v___x_3840_;
v___x_3838_ = 2ULL;
v___x_3839_ = lean_uint64_add(v_commCloseIdx_3832_, v___x_3838_);
v___x_3840_ = lean_uint64_dec_le(v___x_3839_, v_totalLen_3833_);
if (v___x_3840_ == 0)
{
uint8_t v___x_3841_;
v___x_3841_ = 0;
return v___x_3841_;
}
else
{
uint8_t v___x_3842_;
v___x_3842_ = lean_uint64_dec_le(v_minFieldsAfterComm_3834_, v_actualFields_3835_);
if (v___x_3842_ == 0)
{
uint8_t v___x_3843_;
v___x_3843_ = 0;
return v___x_3843_;
}
else
{
uint8_t v___x_3844_;
v___x_3844_ = 1;
return v___x_3844_;
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_sse_frame_scan(uint64_t v_frameOff_4100_, uint64_t v_frameLen_4101_, uint64_t v_chunkLen_4102_, uint8_t v_fieldKind_4103_, uint8_t v_nextByte_4104_, uint8_t v_lastByte_4105_){
_start:
{
uint64_t v___x_4111_; uint8_t v___x_4112_;
v___x_4111_ = 0ULL;
v___x_4112_ = lean_uint64_dec_lt(v___x_4111_, v_frameLen_4101_);
if (v___x_4112_ == 0)
{
uint8_t v___x_4113_;
v___x_4113_ = 0;
return v___x_4113_;
}
else
{
uint8_t v___x_4114_;
v___x_4114_ = lean_uint64_dec_le(v_frameOff_4100_, v_chunkLen_4102_);
if (v___x_4114_ == 0)
{
uint8_t v___x_4115_;
v___x_4115_ = 0;
return v___x_4115_;
}
else
{
uint64_t v___x_4116_; uint8_t v___x_4117_;
v___x_4116_ = lean_uint64_sub(v_chunkLen_4102_, v_frameOff_4100_);
v___x_4117_ = lean_uint64_dec_le(v_frameLen_4101_, v___x_4116_);
if (v___x_4117_ == 0)
{
uint8_t v___x_4118_;
v___x_4118_ = 0;
return v___x_4118_;
}
else
{
uint8_t v___x_4119_; uint8_t v___x_4120_;
v___x_4119_ = 1;
v___x_4120_ = lean_uint8_dec_le(v___x_4119_, v_fieldKind_4103_);
if (v___x_4120_ == 0)
{
uint8_t v___x_4121_;
v___x_4121_ = 0;
return v___x_4121_;
}
else
{
uint8_t v___x_4122_; uint8_t v___x_4123_;
v___x_4122_ = 4;
v___x_4123_ = lean_uint8_dec_le(v_fieldKind_4103_, v___x_4122_);
if (v___x_4123_ == 0)
{
uint8_t v___x_4124_;
v___x_4124_ = 0;
return v___x_4124_;
}
else
{
uint8_t v___x_4125_; uint8_t v___x_4126_;
v___x_4125_ = 128;
v___x_4126_ = lean_uint8_dec_lt(v_nextByte_4104_, v___x_4125_);
if (v___x_4126_ == 0)
{
uint8_t v___x_4127_; uint8_t v___x_4128_;
v___x_4127_ = 191;
v___x_4128_ = lean_uint8_dec_lt(v___x_4127_, v_nextByte_4104_);
if (v___x_4128_ == 0)
{
uint8_t v___x_4129_;
v___x_4129_ = 0;
return v___x_4129_;
}
else
{
goto v___jp_4106_;
}
}
else
{
goto v___jp_4106_;
}
}
}
}
}
}
v___jp_4106_:
{
uint8_t v___x_4107_; uint8_t v___x_4108_;
v___x_4107_ = 192;
v___x_4108_ = lean_uint8_dec_lt(v_lastByte_4105_, v___x_4107_);
if (v___x_4108_ == 0)
{
uint8_t v___x_4109_;
v___x_4109_ = 0;
return v___x_4109_;
}
else
{
uint8_t v___x_4110_;
v___x_4110_ = 1;
return v___x_4110_;
}
}
}
}

LEAN_EXPORT uint8_t leansys_gfm_pipe_scan(uint64_t v_rowOff_4373_, uint64_t v_rowLen_4374_, uint64_t v_bufLen_4375_, uint32_t v_colCount_4376_, uint32_t v_sepCols_4377_, uint8_t v_unterminatedEscape_4378_){
_start:
{
uint64_t v___x_4379_; uint8_t v___x_4380_;
v___x_4379_ = 0ULL;
v___x_4380_ = lean_uint64_dec_lt(v___x_4379_, v_rowLen_4374_);
if (v___x_4380_ == 0)
{
uint8_t v___x_4381_;
v___x_4381_ = 0;
return v___x_4381_;
}
else
{
uint8_t v___x_4382_;
v___x_4382_ = lean_uint64_dec_le(v_rowOff_4373_, v_bufLen_4375_);
if (v___x_4382_ == 0)
{
uint8_t v___x_4383_;
v___x_4383_ = 0;
return v___x_4383_;
}
else
{
uint64_t v___x_4384_; uint8_t v___x_4385_;
v___x_4384_ = lean_uint64_sub(v_bufLen_4375_, v_rowOff_4373_);
v___x_4385_ = lean_uint64_dec_le(v_rowLen_4374_, v___x_4384_);
if (v___x_4385_ == 0)
{
uint8_t v___x_4386_;
v___x_4386_ = 0;
return v___x_4386_;
}
else
{
uint32_t v___x_4387_; uint8_t v___x_4388_;
v___x_4387_ = 0;
v___x_4388_ = lean_uint32_dec_lt(v___x_4387_, v_colCount_4376_);
if (v___x_4388_ == 0)
{
uint8_t v___x_4389_;
v___x_4389_ = 0;
return v___x_4389_;
}
else
{
uint32_t v___x_4390_; uint8_t v___x_4391_;
v___x_4390_ = 64;
v___x_4391_ = lean_uint32_dec_le(v_colCount_4376_, v___x_4390_);
if (v___x_4391_ == 0)
{
uint8_t v___x_4392_;
v___x_4392_ = 0;
return v___x_4392_;
}
else
{
uint8_t v___x_4393_;
v___x_4393_ = lean_uint32_dec_eq(v_colCount_4376_, v_sepCols_4377_);
if (v___x_4393_ == 0)
{
uint8_t v___x_4394_;
v___x_4394_ = 0;
return v___x_4394_;
}
else
{
uint8_t v___x_4395_; uint8_t v___x_4396_;
v___x_4395_ = 0;
v___x_4396_ = lean_uint8_dec_eq(v_unterminatedEscape_4378_, v___x_4395_);
if (v___x_4396_ == 0)
{
return v___x_4395_;
}
else
{
uint8_t v___x_4397_;
v___x_4397_ = 1;
return v___x_4397_;
}
}
}
}
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_tag_scan(uint64_t v_tagOff_4631_, uint64_t v_tagLen_4632_, uint64_t v_attrOff_4633_, uint64_t v_attrLen_4634_, uint64_t v_bufLen_4635_, uint8_t v_tagKind_4636_){
_start:
{
uint64_t v___x_4637_; uint8_t v___x_4638_;
v___x_4637_ = 0ULL;
v___x_4638_ = lean_uint64_dec_lt(v___x_4637_, v_tagLen_4632_);
if (v___x_4638_ == 0)
{
uint8_t v___x_4639_;
v___x_4639_ = 0;
return v___x_4639_;
}
else
{
uint8_t v___x_4640_;
v___x_4640_ = lean_uint64_dec_le(v_tagOff_4631_, v_bufLen_4635_);
if (v___x_4640_ == 0)
{
uint8_t v___x_4641_;
v___x_4641_ = 0;
return v___x_4641_;
}
else
{
uint64_t v___x_4642_; uint8_t v___x_4643_;
v___x_4642_ = lean_uint64_sub(v_bufLen_4635_, v_tagOff_4631_);
v___x_4643_ = lean_uint64_dec_le(v_tagLen_4632_, v___x_4642_);
if (v___x_4643_ == 0)
{
uint8_t v___x_4644_;
v___x_4644_ = 0;
return v___x_4644_;
}
else
{
uint8_t v___x_4645_;
v___x_4645_ = lean_uint64_dec_le(v_tagOff_4631_, v_attrOff_4633_);
if (v___x_4645_ == 0)
{
uint8_t v___x_4646_;
v___x_4646_ = 0;
return v___x_4646_;
}
else
{
uint64_t v___x_4647_; uint8_t v___x_4648_;
v___x_4647_ = lean_uint64_sub(v_attrOff_4633_, v_tagOff_4631_);
v___x_4648_ = lean_uint64_dec_le(v___x_4647_, v_tagLen_4632_);
if (v___x_4648_ == 0)
{
uint8_t v___x_4649_;
v___x_4649_ = 0;
return v___x_4649_;
}
else
{
uint64_t v___x_4650_; uint8_t v___x_4651_;
v___x_4650_ = lean_uint64_sub(v_tagLen_4632_, v___x_4647_);
v___x_4651_ = lean_uint64_dec_le(v_attrLen_4634_, v___x_4650_);
if (v___x_4651_ == 0)
{
uint8_t v___x_4652_;
v___x_4652_ = 0;
return v___x_4652_;
}
else
{
uint8_t v___x_4653_; uint8_t v___x_4654_;
v___x_4653_ = 1;
v___x_4654_ = lean_uint8_dec_le(v___x_4653_, v_tagKind_4636_);
if (v___x_4654_ == 0)
{
uint8_t v___x_4655_;
v___x_4655_ = 0;
return v___x_4655_;
}
else
{
uint8_t v___x_4656_; uint8_t v___x_4657_;
v___x_4656_ = 3;
v___x_4657_ = lean_uint8_dec_le(v_tagKind_4636_, v___x_4656_);
if (v___x_4657_ == 0)
{
uint8_t v___x_4658_;
v___x_4658_ = 0;
return v___x_4658_;
}
else
{
return v___x_4653_;
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

LEAN_EXPORT uint64_t leansys_transcript_index(uint64_t v_turnOff_4867_, uint64_t v_turnLen_4868_, uint64_t v_bufLen_4869_, uint64_t v_prevDigest_4870_, uint64_t v_blockHash_4871_){
_start:
{
uint64_t v___x_4872_; uint8_t v___x_4873_;
v___x_4872_ = 0ULL;
v___x_4873_ = lean_uint64_dec_lt(v___x_4872_, v_turnLen_4868_);
if (v___x_4873_ == 0)
{
return v___x_4872_;
}
else
{
uint8_t v___x_4874_;
v___x_4874_ = lean_uint64_dec_le(v_turnOff_4867_, v_bufLen_4869_);
if (v___x_4874_ == 0)
{
return v___x_4872_;
}
else
{
uint64_t v___x_4875_; uint8_t v___x_4876_;
v___x_4875_ = lean_uint64_sub(v_bufLen_4869_, v_turnOff_4867_);
v___x_4876_ = lean_uint64_dec_le(v_turnLen_4868_, v___x_4875_);
if (v___x_4876_ == 0)
{
return v___x_4872_;
}
else
{
uint64_t v___x_4877_; uint64_t v___x_4878_; uint64_t v___x_4879_; uint64_t v___x_4880_; uint64_t v___x_4881_; uint64_t v_z_4882_; uint64_t v___x_4883_; uint64_t v___x_4884_; uint64_t v___x_4885_; uint64_t v___x_4886_; uint64_t v_z1_4887_; uint64_t v___x_4888_; uint64_t v___x_4889_; uint64_t v_mixed_4890_; uint8_t v___x_4891_;
v___x_4877_ = lean_uint64_xor(v_prevDigest_4870_, v_turnLen_4868_);
v___x_4878_ = 11400714819323198485ULL;
v___x_4879_ = lean_uint64_mul(v_blockHash_4871_, v___x_4878_);
v___x_4880_ = lean_uint64_xor(v___x_4877_, v___x_4879_);
v___x_4881_ = 13787848793156543929ULL;
v_z_4882_ = lean_uint64_mul(v___x_4880_, v___x_4881_);
v___x_4883_ = 30ULL;
v___x_4884_ = lean_uint64_shift_right(v_z_4882_, v___x_4883_);
v___x_4885_ = lean_uint64_xor(v_z_4882_, v___x_4884_);
v___x_4886_ = 10723151780598845931ULL;
v_z1_4887_ = lean_uint64_mul(v___x_4885_, v___x_4886_);
v___x_4888_ = 31ULL;
v___x_4889_ = lean_uint64_shift_right(v_z1_4887_, v___x_4888_);
v_mixed_4890_ = lean_uint64_xor(v_z1_4887_, v___x_4889_);
v___x_4891_ = lean_uint64_dec_eq(v_mixed_4890_, v___x_4872_);
if (v___x_4891_ == 0)
{
return v_mixed_4890_;
}
else
{
uint64_t v___x_4892_;
v___x_4892_ = 1ULL;
return v___x_4892_;
}
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_verify_par_chunk(uint64_t v_chunkStart_5070_, uint64_t v_chunkEnd_5071_, uint64_t v_totalLen_5072_, uint64_t v_minGrain_5073_){
_start:
{
uint8_t v___x_5074_;
v___x_5074_ = lean_uint64_dec_lt(v_chunkStart_5070_, v_chunkEnd_5071_);
if (v___x_5074_ == 0)
{
uint8_t v___x_5075_;
v___x_5075_ = 0;
return v___x_5075_;
}
else
{
uint8_t v___x_5076_;
v___x_5076_ = lean_uint64_dec_le(v_chunkEnd_5071_, v_totalLen_5072_);
if (v___x_5076_ == 0)
{
uint8_t v___x_5077_;
v___x_5077_ = 0;
return v___x_5077_;
}
else
{
uint64_t v___x_5078_; uint8_t v___x_5079_;
v___x_5078_ = lean_uint64_sub(v_chunkEnd_5071_, v_chunkStart_5070_);
v___x_5079_ = lean_uint64_dec_le(v_minGrain_5073_, v___x_5078_);
if (v___x_5079_ == 0)
{
uint8_t v___x_5080_;
v___x_5080_ = lean_uint64_dec_eq(v_chunkEnd_5071_, v_totalLen_5072_);
if (v___x_5080_ == 0)
{
uint8_t v___x_5081_;
v___x_5081_ = 0;
return v___x_5081_;
}
else
{
uint8_t v___x_5082_;
v___x_5082_ = 1;
return v___x_5082_;
}
}
else
{
uint8_t v___x_5083_;
v___x_5083_ = 1;
return v___x_5083_;
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_verify_arena_disjoint(uint64_t v_offA_5251_, uint64_t v_lenA_5252_, uint64_t v_offB_5253_, uint64_t v_lenB_5254_, uint64_t v_arenaCap_5255_){
_start:
{
uint8_t v___x_5256_;
v___x_5256_ = lean_uint64_dec_le(v_offA_5251_, v_arenaCap_5255_);
if (v___x_5256_ == 0)
{
uint8_t v___x_5257_;
v___x_5257_ = 0;
return v___x_5257_;
}
else
{
uint64_t v___x_5258_; uint8_t v___x_5259_;
v___x_5258_ = lean_uint64_sub(v_arenaCap_5255_, v_offA_5251_);
v___x_5259_ = lean_uint64_dec_le(v_lenA_5252_, v___x_5258_);
if (v___x_5259_ == 0)
{
uint8_t v___x_5260_;
v___x_5260_ = 0;
return v___x_5260_;
}
else
{
uint8_t v___x_5261_;
v___x_5261_ = lean_uint64_dec_le(v_offB_5253_, v_arenaCap_5255_);
if (v___x_5261_ == 0)
{
uint8_t v___x_5262_;
v___x_5262_ = 0;
return v___x_5262_;
}
else
{
uint64_t v___x_5263_; uint8_t v___x_5264_;
v___x_5263_ = lean_uint64_sub(v_arenaCap_5255_, v_offB_5253_);
v___x_5264_ = lean_uint64_dec_le(v_lenB_5254_, v___x_5263_);
if (v___x_5264_ == 0)
{
uint8_t v___x_5265_;
v___x_5265_ = 0;
return v___x_5265_;
}
else
{
uint64_t v___x_5266_; uint8_t v___x_5267_;
v___x_5266_ = lean_uint64_add(v_offA_5251_, v_lenA_5252_);
v___x_5267_ = lean_uint64_dec_le(v___x_5266_, v_offB_5253_);
if (v___x_5267_ == 0)
{
uint64_t v___x_5268_; uint8_t v___x_5269_;
v___x_5268_ = lean_uint64_add(v_offB_5253_, v_lenB_5254_);
v___x_5269_ = lean_uint64_dec_le(v___x_5268_, v_offA_5251_);
if (v___x_5269_ == 0)
{
uint8_t v___x_5270_;
v___x_5270_ = 0;
return v___x_5270_;
}
else
{
uint8_t v___x_5271_;
v___x_5271_ = 1;
return v___x_5271_;
}
}
else
{
uint8_t v___x_5272_;
v___x_5272_ = 1;
return v___x_5272_;
}
}
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_verify_snapshot_visibility(uint64_t v_entrySeq_5468_, uint64_t v_maxSnapshotSeq_5469_, uint8_t v_isTombstone_5470_){
_start:
{
uint8_t v___x_5471_;
v___x_5471_ = lean_uint64_dec_le(v_entrySeq_5468_, v_maxSnapshotSeq_5469_);
if (v___x_5471_ == 0)
{
uint8_t v___x_5472_;
v___x_5472_ = 0;
return v___x_5472_;
}
else
{
uint8_t v___x_5473_; uint8_t v___x_5474_;
v___x_5473_ = 0;
v___x_5474_ = lean_uint8_dec_eq(v_isTombstone_5470_, v___x_5473_);
if (v___x_5474_ == 0)
{
return v___x_5473_;
}
else
{
uint8_t v___x_5475_;
v___x_5475_ = 1;
return v___x_5475_;
}
}
}
}

LEAN_EXPORT uint8_t leansys_verify_http_route_match(uint8_t v_methodMatch_5622_, uint8_t v_pathMatch_5623_, uint32_t v_routeIdx_5624_, uint32_t v_routeCount_5625_){
_start:
{
uint8_t v___x_5626_; uint8_t v___x_5627_;
v___x_5626_ = 1;
v___x_5627_ = lean_uint8_dec_eq(v_methodMatch_5622_, v___x_5626_);
if (v___x_5627_ == 0)
{
uint8_t v___x_5628_;
v___x_5628_ = 0;
return v___x_5628_;
}
else
{
uint8_t v___x_5629_;
v___x_5629_ = lean_uint8_dec_eq(v_pathMatch_5623_, v___x_5626_);
if (v___x_5629_ == 0)
{
uint8_t v___x_5630_;
v___x_5630_ = 0;
return v___x_5630_;
}
else
{
uint8_t v___x_5631_;
v___x_5631_ = lean_uint32_dec_lt(v_routeIdx_5624_, v_routeCount_5625_);
if (v___x_5631_ == 0)
{
uint8_t v___x_5632_;
v___x_5632_ = 0;
return v___x_5632_;
}
else
{
uint32_t v___x_5633_; uint8_t v___x_5634_;
v___x_5633_ = 64;
v___x_5634_ = lean_uint32_dec_le(v_routeCount_5625_, v___x_5633_);
if (v___x_5634_ == 0)
{
uint8_t v___x_5635_;
v___x_5635_ = 0;
return v___x_5635_;
}
else
{
return v___x_5626_;
}
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_verify_counterexample_triage(uint8_t v_hasViolation_5797_, uint8_t v_hasMissingHypHint_5798_, uint8_t v_refDisagreesWithCandidate_5799_, uint8_t v_triageClass_5800_){
_start:
{
uint8_t v___x_5801_; uint8_t v___x_5814_;
v___x_5801_ = 1;
v___x_5814_ = lean_uint8_dec_eq(v_hasViolation_5797_, v___x_5801_);
if (v___x_5814_ == 0)
{
uint8_t v___x_5815_;
v___x_5815_ = 0;
return v___x_5815_;
}
else
{
uint8_t v___x_5816_;
v___x_5816_ = lean_uint8_dec_eq(v_hasMissingHypHint_5798_, v___x_5801_);
if (v___x_5816_ == 0)
{
goto v___jp_5808_;
}
else
{
uint8_t v___x_5817_;
v___x_5817_ = lean_uint8_dec_eq(v_triageClass_5800_, v___x_5801_);
if (v___x_5817_ == 0)
{
goto v___jp_5808_;
}
else
{
return v___x_5801_;
}
}
}
v___jp_5802_:
{
uint8_t v___x_5803_; uint8_t v___x_5804_;
v___x_5803_ = 0;
v___x_5804_ = lean_uint8_dec_eq(v_hasMissingHypHint_5798_, v___x_5803_);
if (v___x_5804_ == 0)
{
return v___x_5803_;
}
else
{
uint8_t v___x_5805_;
v___x_5805_ = lean_uint8_dec_eq(v_refDisagreesWithCandidate_5799_, v___x_5803_);
if (v___x_5805_ == 0)
{
return v___x_5803_;
}
else
{
uint8_t v___x_5806_; uint8_t v___x_5807_;
v___x_5806_ = 3;
v___x_5807_ = lean_uint8_dec_eq(v_triageClass_5800_, v___x_5806_);
if (v___x_5807_ == 0)
{
return v___x_5803_;
}
else
{
return v___x_5801_;
}
}
}
}
v___jp_5808_:
{
uint8_t v___x_5809_; uint8_t v___x_5810_;
v___x_5809_ = 0;
v___x_5810_ = lean_uint8_dec_eq(v_hasMissingHypHint_5798_, v___x_5809_);
if (v___x_5810_ == 0)
{
goto v___jp_5802_;
}
else
{
uint8_t v___x_5811_;
v___x_5811_ = lean_uint8_dec_eq(v_refDisagreesWithCandidate_5799_, v___x_5801_);
if (v___x_5811_ == 0)
{
goto v___jp_5802_;
}
else
{
uint8_t v___x_5812_; uint8_t v___x_5813_;
v___x_5812_ = 2;
v___x_5813_ = lean_uint8_dec_eq(v_triageClass_5800_, v___x_5812_);
if (v___x_5813_ == 0)
{
goto v___jp_5802_;
}
else
{
return v___x_5801_;
}
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_verify_dag_wave_step(uint64_t v_inDegreeSum_5994_, uint64_t v_waveSize_5995_, uint64_t v_completedTasks_5996_, uint64_t v_totalTasks_5997_, uint64_t v_activeWorkers_5998_, uint64_t v_maxWorkers_5999_){
_start:
{
uint64_t v___x_6000_; uint8_t v___x_6001_;
v___x_6000_ = 0ULL;
v___x_6001_ = lean_uint64_dec_eq(v_inDegreeSum_5994_, v___x_6000_);
if (v___x_6001_ == 0)
{
uint8_t v___x_6002_;
v___x_6002_ = 0;
return v___x_6002_;
}
else
{
uint8_t v___x_6003_;
v___x_6003_ = lean_uint64_dec_lt(v___x_6000_, v_waveSize_5995_);
if (v___x_6003_ == 0)
{
uint8_t v___x_6004_;
v___x_6004_ = 0;
return v___x_6004_;
}
else
{
uint8_t v___x_6005_;
v___x_6005_ = lean_uint64_dec_le(v_completedTasks_5996_, v_totalTasks_5997_);
if (v___x_6005_ == 0)
{
uint8_t v___x_6006_;
v___x_6006_ = 0;
return v___x_6006_;
}
else
{
uint64_t v___x_6007_; uint8_t v___x_6008_;
v___x_6007_ = lean_uint64_sub(v_totalTasks_5997_, v_completedTasks_5996_);
v___x_6008_ = lean_uint64_dec_le(v_waveSize_5995_, v___x_6007_);
if (v___x_6008_ == 0)
{
uint8_t v___x_6009_;
v___x_6009_ = 0;
return v___x_6009_;
}
else
{
uint8_t v___x_6010_;
v___x_6010_ = lean_uint64_dec_lt(v___x_6000_, v_activeWorkers_5998_);
if (v___x_6010_ == 0)
{
uint8_t v___x_6011_;
v___x_6011_ = 0;
return v___x_6011_;
}
else
{
uint8_t v___x_6012_;
v___x_6012_ = lean_uint64_dec_le(v_activeWorkers_5998_, v_maxWorkers_5999_);
if (v___x_6012_ == 0)
{
uint8_t v___x_6013_;
v___x_6013_ = 0;
return v___x_6013_;
}
else
{
uint8_t v___x_6014_;
v___x_6014_ = 1;
return v___x_6014_;
}
}
}
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_verify_ios_jetsam_budget(uint64_t v_dirtyRssBytes_6207_, uint64_t v_allocBytes_6208_, uint64_t v_maxJetsamBytes_6209_, uint64_t v_pageAlignMask_6210_, uint8_t v_isAppExtension_6211_){
_start:
{
uint64_t v___x_6212_; uint8_t v___x_6213_;
v___x_6212_ = 0ULL;
v___x_6213_ = lean_uint64_dec_lt(v___x_6212_, v_allocBytes_6208_);
if (v___x_6213_ == 0)
{
uint8_t v___x_6214_;
v___x_6214_ = 0;
return v___x_6214_;
}
else
{
uint64_t v___x_6215_; uint8_t v___x_6216_;
v___x_6215_ = 16383ULL;
v___x_6216_ = lean_uint64_dec_eq(v_pageAlignMask_6210_, v___x_6215_);
if (v___x_6216_ == 0)
{
uint8_t v___x_6217_;
v___x_6217_ = 0;
return v___x_6217_;
}
else
{
uint8_t v___x_6218_;
v___x_6218_ = lean_uint64_dec_le(v_dirtyRssBytes_6207_, v_maxJetsamBytes_6209_);
if (v___x_6218_ == 0)
{
uint8_t v___x_6219_;
v___x_6219_ = 0;
return v___x_6219_;
}
else
{
uint64_t v___x_6220_; uint8_t v___x_6221_;
v___x_6220_ = lean_uint64_sub(v_maxJetsamBytes_6209_, v_dirtyRssBytes_6207_);
v___x_6221_ = lean_uint64_dec_le(v_allocBytes_6208_, v___x_6220_);
if (v___x_6221_ == 0)
{
uint8_t v___x_6222_;
v___x_6222_ = 0;
return v___x_6222_;
}
else
{
uint8_t v___x_6223_; uint8_t v___x_6224_;
v___x_6223_ = 1;
v___x_6224_ = lean_uint8_dec_le(v_isAppExtension_6211_, v___x_6223_);
if (v___x_6224_ == 0)
{
uint8_t v___x_6225_;
v___x_6225_ = 0;
return v___x_6225_;
}
else
{
uint8_t v___x_6226_; uint8_t v___x_6227_;
v___x_6226_ = 0;
v___x_6227_ = lean_uint8_dec_eq(v_isAppExtension_6211_, v___x_6226_);
if (v___x_6227_ == 0)
{
uint64_t v___x_6228_; uint8_t v___x_6229_;
v___x_6228_ = 25165824ULL;
v___x_6229_ = lean_uint64_dec_le(v_maxJetsamBytes_6209_, v___x_6228_);
if (v___x_6229_ == 0)
{
return v___x_6226_;
}
else
{
return v___x_6223_;
}
}
else
{
return v___x_6223_;
}
}
}
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_verify_worker_budget(uint64_t v_activeWorkers_6422_, uint64_t v_maxWorkers_6423_, uint64_t v_microChunks_6424_, uint64_t v_totalLen_6425_, uint8_t v_topologyKind_6426_){
_start:
{
uint64_t v___x_6435_; uint8_t v___x_6436_;
v___x_6435_ = 0ULL;
v___x_6436_ = lean_uint64_dec_lt(v___x_6435_, v_activeWorkers_6422_);
if (v___x_6436_ == 0)
{
uint8_t v___x_6437_;
v___x_6437_ = 0;
return v___x_6437_;
}
else
{
uint8_t v___x_6438_;
v___x_6438_ = lean_uint64_dec_le(v_activeWorkers_6422_, v_maxWorkers_6423_);
if (v___x_6438_ == 0)
{
uint8_t v___x_6439_;
v___x_6439_ = 0;
return v___x_6439_;
}
else
{
uint64_t v___x_6440_; uint8_t v___x_6441_;
v___x_6440_ = 64ULL;
v___x_6441_ = lean_uint64_dec_le(v_maxWorkers_6423_, v___x_6440_);
if (v___x_6441_ == 0)
{
uint8_t v___x_6442_;
v___x_6442_ = 0;
return v___x_6442_;
}
else
{
uint8_t v___x_6443_;
v___x_6443_ = lean_uint64_dec_lt(v___x_6435_, v_totalLen_6425_);
if (v___x_6443_ == 0)
{
uint8_t v___x_6444_;
v___x_6444_ = 0;
return v___x_6444_;
}
else
{
uint8_t v___x_6445_;
v___x_6445_ = lean_uint64_dec_le(v_activeWorkers_6422_, v_microChunks_6424_);
if (v___x_6445_ == 0)
{
uint8_t v___x_6446_;
v___x_6446_ = 0;
return v___x_6446_;
}
else
{
uint64_t v___x_6447_; uint64_t v___x_6448_; uint8_t v___x_6449_;
v___x_6447_ = 3ULL;
v___x_6448_ = lean_uint64_shift_left(v_maxWorkers_6423_, v___x_6447_);
v___x_6449_ = lean_uint64_dec_le(v_microChunks_6424_, v___x_6448_);
if (v___x_6449_ == 0)
{
uint8_t v___x_6450_;
v___x_6450_ = 0;
return v___x_6450_;
}
else
{
uint8_t v___x_6451_; uint8_t v___x_6452_;
v___x_6451_ = 2;
v___x_6452_ = lean_uint8_dec_le(v_topologyKind_6426_, v___x_6451_);
if (v___x_6452_ == 0)
{
uint8_t v___x_6453_;
v___x_6453_ = 0;
return v___x_6453_;
}
else
{
uint8_t v___x_6454_; uint8_t v___x_6455_;
v___x_6454_ = 1;
v___x_6455_ = lean_uint8_dec_eq(v_topologyKind_6426_, v___x_6454_);
if (v___x_6455_ == 0)
{
goto v___jp_6427_;
}
else
{
uint64_t v___x_6456_; uint8_t v___x_6457_;
v___x_6456_ = 6ULL;
v___x_6457_ = lean_uint64_dec_le(v_maxWorkers_6423_, v___x_6456_);
if (v___x_6457_ == 0)
{
uint8_t v___x_6458_;
v___x_6458_ = 0;
return v___x_6458_;
}
else
{
goto v___jp_6427_;
}
}
}
}
}
}
}
}
}
v___jp_6427_:
{
uint8_t v___x_6428_; uint8_t v___x_6429_;
v___x_6428_ = 2;
v___x_6429_ = lean_uint8_dec_eq(v_topologyKind_6426_, v___x_6428_);
if (v___x_6429_ == 0)
{
uint8_t v___x_6430_;
v___x_6430_ = 1;
return v___x_6430_;
}
else
{
uint64_t v___x_6431_; uint8_t v___x_6432_;
v___x_6431_ = 9ULL;
v___x_6432_ = lean_uint64_dec_le(v_maxWorkers_6423_, v___x_6431_);
if (v___x_6432_ == 0)
{
uint8_t v___x_6433_;
v___x_6433_ = 0;
return v___x_6433_;
}
else
{
uint8_t v___x_6434_;
v___x_6434_ = 1;
return v___x_6434_;
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_verify_page_aligned_buffer(uint64_t v_addr_6675_, uint64_t v_allocBytes_6676_, uint64_t v_capacityBytes_6677_, uint64_t v_dirtyRssBytes_6678_, uint64_t v_maxBudgetBytes_6679_, uint64_t v_pageAlignMask_6680_){
_start:
{
uint64_t v___x_6693_; uint8_t v___x_6694_;
v___x_6693_ = 0ULL;
v___x_6694_ = lean_uint64_dec_lt(v___x_6693_, v_addr_6675_);
if (v___x_6694_ == 0)
{
uint8_t v___x_6695_;
v___x_6695_ = 0;
return v___x_6695_;
}
else
{
uint8_t v___x_6696_;
v___x_6696_ = lean_uint64_dec_lt(v___x_6693_, v_allocBytes_6676_);
if (v___x_6696_ == 0)
{
uint8_t v___x_6697_;
v___x_6697_ = 0;
return v___x_6697_;
}
else
{
uint8_t v___x_6698_;
v___x_6698_ = lean_uint64_dec_le(v_allocBytes_6676_, v_capacityBytes_6677_);
if (v___x_6698_ == 0)
{
uint8_t v___x_6699_;
v___x_6699_ = 0;
return v___x_6699_;
}
else
{
uint64_t v___x_6700_; uint8_t v___x_6701_;
v___x_6700_ = 4095ULL;
v___x_6701_ = lean_uint64_dec_eq(v_pageAlignMask_6680_, v___x_6700_);
if (v___x_6701_ == 0)
{
uint64_t v___x_6702_; uint8_t v___x_6703_;
v___x_6702_ = 16383ULL;
v___x_6703_ = lean_uint64_dec_eq(v_pageAlignMask_6680_, v___x_6702_);
if (v___x_6703_ == 0)
{
uint8_t v___x_6704_;
v___x_6704_ = 0;
return v___x_6704_;
}
else
{
goto v___jp_6681_;
}
}
else
{
goto v___jp_6681_;
}
}
}
}
v___jp_6681_:
{
uint64_t v___x_6682_; uint64_t v___x_6683_; uint64_t v___x_6684_; uint8_t v___x_6685_;
v___x_6682_ = lean_uint64_lor(v_addr_6675_, v_capacityBytes_6677_);
v___x_6683_ = lean_uint64_land(v___x_6682_, v_pageAlignMask_6680_);
v___x_6684_ = 0ULL;
v___x_6685_ = lean_uint64_dec_eq(v___x_6683_, v___x_6684_);
if (v___x_6685_ == 0)
{
uint8_t v___x_6686_;
v___x_6686_ = 0;
return v___x_6686_;
}
else
{
uint8_t v___x_6687_;
v___x_6687_ = lean_uint64_dec_le(v_dirtyRssBytes_6678_, v_maxBudgetBytes_6679_);
if (v___x_6687_ == 0)
{
uint8_t v___x_6688_;
v___x_6688_ = 0;
return v___x_6688_;
}
else
{
uint64_t v___x_6689_; uint8_t v___x_6690_;
v___x_6689_ = lean_uint64_sub(v_maxBudgetBytes_6679_, v_dirtyRssBytes_6678_);
v___x_6690_ = lean_uint64_dec_le(v_capacityBytes_6677_, v___x_6689_);
if (v___x_6690_ == 0)
{
uint8_t v___x_6691_;
v___x_6691_ = 0;
return v___x_6691_;
}
else
{
uint8_t v___x_6692_;
v___x_6692_ = 1;
return v___x_6692_;
}
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_select_isa(uint64_t v_detectedHwCaps_6941_, uint64_t v_requiredMask_6942_, uint8_t v_requestedVariantId_6943_, uint8_t v_maxVariantId_6944_){
_start:
{
uint8_t v___x_6945_; uint64_t v___y_6947_; uint8_t v___x_6951_;
v___x_6945_ = 0;
v___x_6951_ = lean_uint8_dec_lt(v___x_6945_, v_requestedVariantId_6943_);
if (v___x_6951_ == 0)
{
return v___x_6945_;
}
else
{
uint8_t v___x_6952_;
v___x_6952_ = lean_uint8_dec_le(v_requestedVariantId_6943_, v_maxVariantId_6944_);
if (v___x_6952_ == 0)
{
return v___x_6945_;
}
else
{
uint8_t v___x_6953_; uint8_t v___x_6954_;
v___x_6953_ = 4;
v___x_6954_ = lean_uint8_dec_le(v_maxVariantId_6944_, v___x_6953_);
if (v___x_6954_ == 0)
{
return v___x_6945_;
}
else
{
uint8_t v___x_6955_;
v___x_6955_ = lean_uint8_dec_eq(v_requestedVariantId_6943_, v___x_6945_);
if (v___x_6955_ == 0)
{
uint8_t v___x_6956_; uint8_t v___x_6957_;
v___x_6956_ = 1;
v___x_6957_ = lean_uint8_dec_eq(v_requestedVariantId_6943_, v___x_6956_);
if (v___x_6957_ == 0)
{
uint8_t v___x_6958_; uint8_t v___x_6959_;
v___x_6958_ = 2;
v___x_6959_ = lean_uint8_dec_eq(v_requestedVariantId_6943_, v___x_6958_);
if (v___x_6959_ == 0)
{
uint8_t v___x_6960_; uint8_t v___x_6961_;
v___x_6960_ = 3;
v___x_6961_ = lean_uint8_dec_eq(v_requestedVariantId_6943_, v___x_6960_);
if (v___x_6961_ == 0)
{
uint8_t v___x_6962_;
v___x_6962_ = lean_uint8_dec_eq(v_requestedVariantId_6943_, v___x_6953_);
if (v___x_6962_ == 0)
{
uint64_t v___x_6963_;
v___x_6963_ = 18446744073709551615ULL;
v___y_6947_ = v___x_6963_;
goto v___jp_6946_;
}
else
{
uint64_t v___x_6964_;
v___x_6964_ = 927ULL;
v___y_6947_ = v___x_6964_;
goto v___jp_6946_;
}
}
else
{
uint64_t v___x_6965_;
v___x_6965_ = 895ULL;
v___y_6947_ = v___x_6965_;
goto v___jp_6946_;
}
}
else
{
uint64_t v___x_6966_;
v___x_6966_ = 799ULL;
v___y_6947_ = v___x_6966_;
goto v___jp_6946_;
}
}
else
{
uint64_t v___x_6967_;
v___x_6967_ = 775ULL;
v___y_6947_ = v___x_6967_;
goto v___jp_6946_;
}
}
else
{
uint64_t v___x_6968_;
v___x_6968_ = 263ULL;
v___y_6947_ = v___x_6968_;
goto v___jp_6946_;
}
}
}
}
v___jp_6946_:
{
uint8_t v___x_6948_;
v___x_6948_ = lean_uint64_dec_eq(v_requiredMask_6942_, v___y_6947_);
if (v___x_6948_ == 0)
{
return v___x_6945_;
}
else
{
uint64_t v___x_6949_; uint8_t v___x_6950_;
v___x_6949_ = lean_uint64_land(v_detectedHwCaps_6941_, v_requiredMask_6942_);
v___x_6950_ = lean_uint64_dec_eq(v___x_6949_, v_requiredMask_6942_);
if (v___x_6950_ == 0)
{
return v___x_6945_;
}
else
{
return v_requestedVariantId_6943_;
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_verify_isa_selection(uint64_t v_detectedHwCaps_6979_, uint64_t v_requiredMask_6980_, uint8_t v_selectedVariantId_6981_, uint8_t v_maxVariantId_6982_){
_start:
{
uint64_t v___y_6984_; uint8_t v___x_6993_;
v___x_6993_ = lean_uint8_dec_le(v_selectedVariantId_6981_, v_maxVariantId_6982_);
if (v___x_6993_ == 0)
{
uint8_t v___x_6994_;
v___x_6994_ = 0;
return v___x_6994_;
}
else
{
uint8_t v___x_6995_; uint8_t v___x_6996_;
v___x_6995_ = 4;
v___x_6996_ = lean_uint8_dec_le(v_maxVariantId_6982_, v___x_6995_);
if (v___x_6996_ == 0)
{
uint8_t v___x_6997_;
v___x_6997_ = 0;
return v___x_6997_;
}
else
{
uint8_t v___x_6998_; uint8_t v___x_6999_;
v___x_6998_ = 0;
v___x_6999_ = lean_uint8_dec_eq(v_selectedVariantId_6981_, v___x_6998_);
if (v___x_6999_ == 0)
{
uint8_t v___x_7000_; uint8_t v___x_7001_;
v___x_7000_ = 1;
v___x_7001_ = lean_uint8_dec_eq(v_selectedVariantId_6981_, v___x_7000_);
if (v___x_7001_ == 0)
{
uint8_t v___x_7002_; uint8_t v___x_7003_;
v___x_7002_ = 2;
v___x_7003_ = lean_uint8_dec_eq(v_selectedVariantId_6981_, v___x_7002_);
if (v___x_7003_ == 0)
{
uint8_t v___x_7004_; uint8_t v___x_7005_;
v___x_7004_ = 3;
v___x_7005_ = lean_uint8_dec_eq(v_selectedVariantId_6981_, v___x_7004_);
if (v___x_7005_ == 0)
{
uint8_t v___x_7006_;
v___x_7006_ = lean_uint8_dec_eq(v_selectedVariantId_6981_, v___x_6995_);
if (v___x_7006_ == 0)
{
uint64_t v___x_7007_;
v___x_7007_ = 18446744073709551615ULL;
v___y_6984_ = v___x_7007_;
goto v___jp_6983_;
}
else
{
uint64_t v___x_7008_;
v___x_7008_ = 927ULL;
v___y_6984_ = v___x_7008_;
goto v___jp_6983_;
}
}
else
{
uint64_t v___x_7009_;
v___x_7009_ = 895ULL;
v___y_6984_ = v___x_7009_;
goto v___jp_6983_;
}
}
else
{
uint64_t v___x_7010_;
v___x_7010_ = 799ULL;
v___y_6984_ = v___x_7010_;
goto v___jp_6983_;
}
}
else
{
uint64_t v___x_7011_;
v___x_7011_ = 775ULL;
v___y_6984_ = v___x_7011_;
goto v___jp_6983_;
}
}
else
{
uint64_t v___x_7012_;
v___x_7012_ = 263ULL;
v___y_6984_ = v___x_7012_;
goto v___jp_6983_;
}
}
}
v___jp_6983_:
{
uint8_t v___x_6985_;
v___x_6985_ = lean_uint64_dec_eq(v_requiredMask_6980_, v___y_6984_);
if (v___x_6985_ == 0)
{
uint8_t v___x_6986_;
v___x_6986_ = 0;
return v___x_6986_;
}
else
{
uint8_t v___x_6987_; uint8_t v___x_6988_;
v___x_6987_ = 0;
v___x_6988_ = lean_uint8_dec_eq(v_selectedVariantId_6981_, v___x_6987_);
if (v___x_6988_ == 0)
{
uint64_t v___x_6989_; uint8_t v___x_6990_;
v___x_6989_ = lean_uint64_land(v_detectedHwCaps_6979_, v_requiredMask_6980_);
v___x_6990_ = lean_uint64_dec_eq(v___x_6989_, v_requiredMask_6980_);
if (v___x_6990_ == 0)
{
return v___x_6987_;
}
else
{
uint8_t v___x_6991_;
v___x_6991_ = 1;
return v___x_6991_;
}
}
else
{
uint8_t v___x_6992_;
v___x_6992_ = 1;
return v___x_6992_;
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_verify_fd_bounds(uint64_t v_rawWord_7271_, uint32_t v_fdOut_7272_){
_start:
{
uint64_t v___x_7273_; uint8_t v___x_7274_;
v___x_7273_ = 2147483647ULL;
v___x_7274_ = lean_uint64_dec_le(v_rawWord_7271_, v___x_7273_);
if (v___x_7274_ == 0)
{
uint8_t v___x_7275_;
v___x_7275_ = 0;
return v___x_7275_;
}
else
{
uint64_t v___x_7276_; uint8_t v___x_7277_;
v___x_7276_ = lean_uint32_to_uint64(v_fdOut_7272_);
v___x_7277_ = lean_uint64_dec_eq(v_rawWord_7271_, v___x_7276_);
if (v___x_7277_ == 0)
{
uint8_t v___x_7278_;
v___x_7278_ = 0;
return v___x_7278_;
}
else
{
uint8_t v___x_7279_;
v___x_7279_ = 1;
return v___x_7279_;
}
}
}
}
