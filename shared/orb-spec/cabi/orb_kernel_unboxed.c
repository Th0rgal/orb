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
#define lean_uint32_shift_left(a, b) ((uint32_t)((a) << (b)))
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

LEAN_EXPORT uint8_t orb_verify_board_retry(uint32_t v_attempts_158_, uint32_t v_maxAttempts_159_, uint8_t v_requiresExternalRecovery_160_, uint8_t v_preflightMerged_161_, uint8_t v_chatgptUiBlocked_162_){
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
v___x_171_ = lean_uint8_dec_eq(v_chatgptUiBlocked_162_, v___x_168_);
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

LEAN_EXPORT uint64_t orb_transcript_patch_step(uint32_t v_stateLen_1338_, uint32_t v_stateSeq_1339_, uint8_t v_eventKind_1340_, uint32_t v_deltaLen_1341_){
_start:
{
uint32_t v___y_1343_; uint8_t v___x_1351_; uint8_t v___x_1352_; 
v___x_1351_ = 2;
v___x_1352_ = lean_uint8_dec_eq(v_eventKind_1340_, v___x_1351_);
if (v___x_1352_ == 0)
{
uint8_t v___x_1353_; uint8_t v___x_1354_; 
v___x_1353_ = 1;
v___x_1354_ = lean_uint8_dec_eq(v_eventKind_1340_, v___x_1353_);
if (v___x_1354_ == 0)
{
uint32_t v___x_1355_; 
v___x_1355_ = lean_uint32_add(v_stateLen_1338_, v_deltaLen_1341_);
v___y_1343_ = v___x_1355_;
goto v___jp_1342_;
}
else
{
uint32_t v___x_1356_; uint8_t v___x_1357_; 
v___x_1356_ = 0;
v___x_1357_ = lean_uint32_dec_lt(v___x_1356_, v_deltaLen_1341_);
if (v___x_1357_ == 0)
{
v___y_1343_ = v_stateLen_1338_;
goto v___jp_1342_;
}
else
{
v___y_1343_ = v_deltaLen_1341_;
goto v___jp_1342_;
}
}
}
else
{
uint32_t v___x_1358_; 
v___x_1358_ = 0;
v___y_1343_ = v___x_1358_;
goto v___jp_1342_;
}
v___jp_1342_:
{
uint32_t v___x_1344_; uint32_t v_nextSeq_1345_; uint64_t v___x_1346_; uint64_t v___x_1347_; uint64_t v___x_1348_; uint64_t v___x_1349_; uint64_t v___x_1350_; 
v___x_1344_ = 1;
v_nextSeq_1345_ = lean_uint32_add(v_stateSeq_1339_, v___x_1344_);
v___x_1346_ = lean_uint32_to_uint64(v___y_1343_);
v___x_1347_ = lean_uint32_to_uint64(v_nextSeq_1345_);
v___x_1348_ = 32ULL;
v___x_1349_ = lean_uint64_shift_left(v___x_1347_, v___x_1348_);
v___x_1350_ = lean_uint64_lor(v___x_1346_, v___x_1349_);
return v___x_1350_;
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

LEAN_EXPORT uint8_t leansys_sse_frame_scan(uint64_t v_frameOff_3962_, uint64_t v_frameLen_3963_, uint64_t v_chunkLen_3964_, uint8_t v_fieldKind_3965_, uint8_t v_nextByte_3966_){
_start:
{
uint64_t v___x_3967_; uint8_t v___x_3968_; 
v___x_3967_ = 0ULL;
v___x_3968_ = lean_uint64_dec_lt(v___x_3967_, v_frameLen_3963_);
if (v___x_3968_ == 0)
{
uint8_t v___x_3969_; 
v___x_3969_ = 0;
return v___x_3969_;
}
else
{
uint64_t v___x_3970_; uint8_t v___x_3971_; 
v___x_3970_ = lean_uint64_add(v_frameOff_3962_, v_frameLen_3963_);
v___x_3971_ = lean_uint64_dec_le(v___x_3970_, v_chunkLen_3964_);
if (v___x_3971_ == 0)
{
uint8_t v___x_3972_; 
v___x_3972_ = 0;
return v___x_3972_;
}
else
{
uint8_t v___x_3973_; uint8_t v___x_3974_; 
v___x_3973_ = 1;
v___x_3974_ = lean_uint8_dec_le(v___x_3973_, v_fieldKind_3965_);
if (v___x_3974_ == 0)
{
uint8_t v___x_3975_; 
v___x_3975_ = 0;
return v___x_3975_;
}
else
{
uint8_t v___x_3976_; uint8_t v___x_3977_; 
v___x_3976_ = 4;
v___x_3977_ = lean_uint8_dec_le(v_fieldKind_3965_, v___x_3976_);
if (v___x_3977_ == 0)
{
uint8_t v___x_3978_; 
v___x_3978_ = 0;
return v___x_3978_;
}
else
{
uint8_t v___x_3979_; uint8_t v___x_3980_; 
v___x_3979_ = 128;
v___x_3980_ = lean_uint8_dec_lt(v_nextByte_3966_, v___x_3979_);
if (v___x_3980_ == 0)
{
uint8_t v___x_3981_; uint8_t v___x_3982_; 
v___x_3981_ = 191;
v___x_3982_ = lean_uint8_dec_lt(v___x_3981_, v_nextByte_3966_);
if (v___x_3982_ == 0)
{
uint8_t v___x_3983_; 
v___x_3983_ = 0;
return v___x_3983_;
}
else
{
return v___x_3973_;
}
}
else
{
return v___x_3973_;
}
}
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_gfm_pipe_scan(uint64_t v_rowOff_4166_, uint64_t v_rowLen_4167_, uint64_t v_bufLen_4168_, uint32_t v_colCount_4169_, uint32_t v_sepCols_4170_, uint8_t v_unterminatedEscape_4171_){
_start:
{
uint64_t v___x_4172_; uint8_t v___x_4173_; 
v___x_4172_ = 0ULL;
v___x_4173_ = lean_uint64_dec_lt(v___x_4172_, v_rowLen_4167_);
if (v___x_4173_ == 0)
{
uint8_t v___x_4174_; 
v___x_4174_ = 0;
return v___x_4174_;
}
else
{
uint64_t v___x_4175_; uint8_t v___x_4176_; 
v___x_4175_ = lean_uint64_add(v_rowOff_4166_, v_rowLen_4167_);
v___x_4176_ = lean_uint64_dec_le(v___x_4175_, v_bufLen_4168_);
if (v___x_4176_ == 0)
{
uint8_t v___x_4177_; 
v___x_4177_ = 0;
return v___x_4177_;
}
else
{
uint32_t v___x_4178_; uint8_t v___x_4179_; 
v___x_4178_ = 0;
v___x_4179_ = lean_uint32_dec_lt(v___x_4178_, v_colCount_4169_);
if (v___x_4179_ == 0)
{
uint8_t v___x_4180_; 
v___x_4180_ = 0;
return v___x_4180_;
}
else
{
uint32_t v___x_4181_; uint8_t v___x_4182_; 
v___x_4181_ = 64;
v___x_4182_ = lean_uint32_dec_le(v_colCount_4169_, v___x_4181_);
if (v___x_4182_ == 0)
{
uint8_t v___x_4183_; 
v___x_4183_ = 0;
return v___x_4183_;
}
else
{
uint8_t v___x_4184_; 
v___x_4184_ = lean_uint32_dec_eq(v_colCount_4169_, v_sepCols_4170_);
if (v___x_4184_ == 0)
{
uint8_t v___x_4185_; 
v___x_4185_ = 0;
return v___x_4185_;
}
else
{
uint8_t v___x_4186_; uint8_t v___x_4187_; 
v___x_4186_ = 0;
v___x_4187_ = lean_uint8_dec_eq(v_unterminatedEscape_4171_, v___x_4186_);
if (v___x_4187_ == 0)
{
return v___x_4186_;
}
else
{
uint8_t v___x_4188_; 
v___x_4188_ = 1;
return v___x_4188_;
}
}
}
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_tag_scan(uint64_t v_tagOff_4416_, uint64_t v_tagLen_4417_, uint64_t v_attrOff_4418_, uint64_t v_attrLen_4419_, uint64_t v_bufLen_4420_, uint8_t v_tagKind_4421_){
_start:
{
uint64_t v___x_4422_; uint8_t v___x_4423_; 
v___x_4422_ = 0ULL;
v___x_4423_ = lean_uint64_dec_lt(v___x_4422_, v_tagLen_4417_);
if (v___x_4423_ == 0)
{
uint8_t v___x_4424_; 
v___x_4424_ = 0;
return v___x_4424_;
}
else
{
uint64_t v___x_4425_; uint8_t v___x_4426_; 
v___x_4425_ = lean_uint64_add(v_tagOff_4416_, v_tagLen_4417_);
v___x_4426_ = lean_uint64_dec_le(v___x_4425_, v_bufLen_4420_);
if (v___x_4426_ == 0)
{
uint8_t v___x_4427_; 
v___x_4427_ = 0;
return v___x_4427_;
}
else
{
uint8_t v___x_4428_; 
v___x_4428_ = lean_uint64_dec_le(v_tagOff_4416_, v_attrOff_4418_);
if (v___x_4428_ == 0)
{
uint8_t v___x_4429_; 
v___x_4429_ = 0;
return v___x_4429_;
}
else
{
uint64_t v___x_4430_; uint8_t v___x_4431_; 
v___x_4430_ = lean_uint64_add(v_attrOff_4418_, v_attrLen_4419_);
v___x_4431_ = lean_uint64_dec_le(v___x_4430_, v___x_4425_);
if (v___x_4431_ == 0)
{
uint8_t v___x_4432_; 
v___x_4432_ = 0;
return v___x_4432_;
}
else
{
uint8_t v___x_4433_; uint8_t v___x_4434_; 
v___x_4433_ = 1;
v___x_4434_ = lean_uint8_dec_le(v___x_4433_, v_tagKind_4421_);
if (v___x_4434_ == 0)
{
uint8_t v___x_4435_; 
v___x_4435_ = 0;
return v___x_4435_;
}
else
{
uint8_t v___x_4436_; uint8_t v___x_4437_; 
v___x_4436_ = 3;
v___x_4437_ = lean_uint8_dec_le(v_tagKind_4421_, v___x_4436_);
if (v___x_4437_ == 0)
{
uint8_t v___x_4438_; 
v___x_4438_ = 0;
return v___x_4438_;
}
else
{
return v___x_4433_;
}
}
}
}
}
}
}
}

LEAN_EXPORT uint64_t leansys_transcript_index(uint64_t v_turnOff_4635_, uint64_t v_turnLen_4636_, uint64_t v_bufLen_4637_, uint64_t v_prevDigest_4638_, uint64_t v_blockHash_4639_){
_start:
{
uint64_t v___x_4640_; uint8_t v___x_4641_; 
v___x_4640_ = 0ULL;
v___x_4641_ = lean_uint64_dec_lt(v___x_4640_, v_turnLen_4636_);
if (v___x_4641_ == 0)
{
return v___x_4640_;
}
else
{
uint64_t v___x_4642_; uint8_t v___x_4643_; 
v___x_4642_ = lean_uint64_add(v_turnOff_4635_, v_turnLen_4636_);
v___x_4643_ = lean_uint64_dec_le(v___x_4642_, v_bufLen_4637_);
if (v___x_4643_ == 0)
{
return v___x_4640_;
}
else
{
uint64_t v___x_4644_; uint64_t v___x_4645_; uint64_t v___x_4646_; uint64_t v___x_4647_; uint64_t v___x_4648_; uint64_t v_z_4649_; uint64_t v___x_4650_; uint64_t v___x_4651_; uint64_t v___x_4652_; uint64_t v___x_4653_; uint64_t v_z1_4654_; uint64_t v___x_4655_; uint64_t v___x_4656_; uint64_t v_mixed_4657_; uint8_t v___x_4658_; 
v___x_4644_ = lean_uint64_xor(v_prevDigest_4638_, v_turnLen_4636_);
v___x_4645_ = 11400714819323198485ULL;
v___x_4646_ = lean_uint64_mul(v_blockHash_4639_, v___x_4645_);
v___x_4647_ = lean_uint64_xor(v___x_4644_, v___x_4646_);
v___x_4648_ = 13787848793156543929ULL;
v_z_4649_ = lean_uint64_mul(v___x_4647_, v___x_4648_);
v___x_4650_ = 30ULL;
v___x_4651_ = lean_uint64_shift_right(v_z_4649_, v___x_4650_);
v___x_4652_ = lean_uint64_xor(v_z_4649_, v___x_4651_);
v___x_4653_ = 10723151780598845931ULL;
v_z1_4654_ = lean_uint64_mul(v___x_4652_, v___x_4653_);
v___x_4655_ = 31ULL;
v___x_4656_ = lean_uint64_shift_right(v_z1_4654_, v___x_4655_);
v_mixed_4657_ = lean_uint64_xor(v_z1_4654_, v___x_4656_);
v___x_4658_ = lean_uint64_dec_eq(v_mixed_4657_, v___x_4640_);
if (v___x_4658_ == 0)
{
return v_mixed_4657_;
}
else
{
uint64_t v___x_4659_; 
v___x_4659_ = 1ULL;
return v___x_4659_;
}
}
}
}
}
