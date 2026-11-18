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

LEAN_EXPORT uint8_t orb_verify_job_transition(uint8_t v_fromState_138_, uint8_t v_toState_139_){
_start:
{
uint8_t v___x_140_; uint8_t v___x_154_;
v___x_140_ = 0;
v___x_154_ = lean_uint8_dec_eq(v_fromState_138_, v___x_140_);
if (v___x_154_ == 0)
{
goto v___jp_147_;
}
else
{
uint8_t v___x_155_; uint8_t v___x_156_;
v___x_155_ = 1;
v___x_156_ = lean_uint8_dec_le(v___x_155_, v_toState_139_);
if (v___x_156_ == 0)
{
goto v___jp_147_;
}
else
{
uint8_t v___x_157_; uint8_t v___x_158_;
v___x_157_ = 5;
v___x_158_ = lean_uint8_dec_le(v_toState_139_, v___x_157_);
if (v___x_158_ == 0)
{
goto v___jp_147_;
}
else
{
return v___x_155_;
}
}
}
v___jp_141_:
{
uint8_t v___x_142_; uint8_t v___x_143_;
v___x_142_ = 5;
v___x_143_ = lean_uint8_dec_eq(v_fromState_138_, v___x_142_);
if (v___x_143_ == 0)
{
return v___x_140_;
}
else
{
uint8_t v___x_144_; uint8_t v___x_145_;
v___x_144_ = 4;
v___x_145_ = lean_uint8_dec_eq(v_toState_139_, v___x_144_);
if (v___x_145_ == 0)
{
return v___x_140_;
}
else
{
uint8_t v___x_146_;
v___x_146_ = 1;
return v___x_146_;
}
}
}
v___jp_147_:
{
uint8_t v___x_148_; uint8_t v___x_149_;
v___x_148_ = 1;
v___x_149_ = lean_uint8_dec_eq(v_fromState_138_, v___x_148_);
if (v___x_149_ == 0)
{
goto v___jp_141_;
}
else
{
uint8_t v___x_150_; uint8_t v___x_151_;
v___x_150_ = 2;
v___x_151_ = lean_uint8_dec_le(v___x_150_, v_toState_139_);
if (v___x_151_ == 0)
{
goto v___jp_141_;
}
else
{
uint8_t v___x_152_; uint8_t v___x_153_;
v___x_152_ = 5;
v___x_153_ = lean_uint8_dec_le(v_toState_139_, v___x_152_);
if (v___x_153_ == 0)
{
goto v___jp_141_;
}
else
{
return v___x_148_;
}
}
}
}
}
}

LEAN_EXPORT uint8_t orb_verify_bundle_budget(uint8_t v_isComplete_165_, uint64_t v_decodedBytes_166_, uint64_t v_overlayCap_167_, uint64_t v_completeCap_168_, uint64_t v_maxBytes_169_){
_start:
{
uint8_t v___x_170_; uint64_t v___y_172_; uint8_t v___x_177_;
v___x_170_ = 1;
v___x_177_ = lean_uint8_dec_eq(v_isComplete_165_, v___x_170_);
if (v___x_177_ == 0)
{
v___y_172_ = v_overlayCap_167_;
goto v___jp_171_;
}
else
{
v___y_172_ = v_completeCap_168_;
goto v___jp_171_;
}
v___jp_171_:
{
uint8_t v___x_173_;
v___x_173_ = lean_uint64_dec_le(v_decodedBytes_166_, v___y_172_);
if (v___x_173_ == 0)
{
uint8_t v___x_174_;
v___x_174_ = 0;
return v___x_174_;
}
else
{
uint8_t v___x_175_;
v___x_175_ = lean_uint64_dec_le(v_decodedBytes_166_, v_maxBytes_169_);
if (v___x_175_ == 0)
{
uint8_t v___x_176_;
v___x_176_ = 0;
return v___x_176_;
}
else
{
return v___x_170_;
}
}
}
}
}

LEAN_EXPORT uint8_t orb_verify_token_rotation(uint8_t v_presentedNonEmpty_190_, uint8_t v_matchCurrent_191_, uint8_t v_prevNonEmpty_192_, uint8_t v_matchPrev_193_, uint8_t v_scopeAndExpiryOk_194_){
_start:
{
uint8_t v___x_195_; uint8_t v___x_199_;
v___x_195_ = 1;
v___x_199_ = lean_uint8_dec_eq(v_presentedNonEmpty_190_, v___x_195_);
if (v___x_199_ == 0)
{
uint8_t v___x_200_;
v___x_200_ = 0;
return v___x_200_;
}
else
{
uint8_t v___x_201_;
v___x_201_ = lean_uint8_dec_eq(v_matchCurrent_191_, v___x_195_);
if (v___x_201_ == 0)
{
uint8_t v___x_202_;
v___x_202_ = lean_uint8_dec_eq(v_prevNonEmpty_192_, v___x_195_);
if (v___x_202_ == 0)
{
uint8_t v___x_203_;
v___x_203_ = 0;
return v___x_203_;
}
else
{
uint8_t v___x_204_;
v___x_204_ = lean_uint8_dec_eq(v_matchPrev_193_, v___x_195_);
if (v___x_204_ == 0)
{
uint8_t v___x_205_;
v___x_205_ = 0;
return v___x_205_;
}
else
{
goto v___jp_196_;
}
}
}
else
{
goto v___jp_196_;
}
}
v___jp_196_:
{
uint8_t v___x_197_;
v___x_197_ = lean_uint8_dec_eq(v_scopeAndExpiryOk_194_, v___x_195_);
if (v___x_197_ == 0)
{
uint8_t v___x_198_;
v___x_198_ = 0;
return v___x_198_;
}
else
{
return v___x_195_;
}
}
}
}

LEAN_EXPORT uint8_t orb_verify_log_window(uint64_t v_offset_218_, uint64_t v_reqLen_219_, uint64_t v_maxChunk_220_, uint64_t v_hardCap_221_, uint64_t v_fileSize_222_, uint64_t v_actualLen_223_){
_start:
{
uint8_t v___x_224_;
v___x_224_ = lean_uint64_dec_le(v_offset_218_, v_fileSize_222_);
if (v___x_224_ == 0)
{
uint8_t v___x_225_;
v___x_225_ = 0;
return v___x_225_;
}
else
{
uint8_t v___x_226_;
v___x_226_ = lean_uint64_dec_le(v_reqLen_219_, v_maxChunk_220_);
if (v___x_226_ == 0)
{
uint8_t v___x_227_;
v___x_227_ = 0;
return v___x_227_;
}
else
{
uint8_t v___x_228_;
v___x_228_ = lean_uint64_dec_le(v_maxChunk_220_, v_hardCap_221_);
if (v___x_228_ == 0)
{
uint8_t v___x_229_;
v___x_229_ = 0;
return v___x_229_;
}
else
{
uint8_t v___x_230_;
v___x_230_ = lean_uint64_dec_le(v_actualLen_223_, v_reqLen_219_);
if (v___x_230_ == 0)
{
uint8_t v___x_231_;
v___x_231_ = 0;
return v___x_231_;
}
else
{
uint64_t v___x_232_; uint8_t v___x_233_;
v___x_232_ = lean_uint64_sub(v_fileSize_222_, v_offset_218_);
v___x_233_ = lean_uint64_dec_le(v_actualLen_223_, v___x_232_);
if (v___x_233_ == 0)
{
uint8_t v___x_234_;
v___x_234_ = 0;
return v___x_234_;
}
else
{
uint8_t v___x_235_;
v___x_235_ = 1;
return v___x_235_;
}
}
}
}
}
}
}

LEAN_EXPORT uint64_t orb_mix64_word(uint64_t v_acc_250_, uint64_t v_word_251_){
_start:
{
uint64_t v___x_252_; uint64_t v___x_253_; uint64_t v_v1_254_; uint64_t v___x_255_; uint64_t v___x_256_; uint64_t v___x_257_; uint64_t v___x_258_; uint64_t v_v2_259_; uint64_t v___x_260_; uint64_t v_v3_261_; uint64_t v___x_262_; uint64_t v___x_263_; uint64_t v___x_264_;
v___x_252_ = 13787848793156543929ULL;
v___x_253_ = lean_uint64_mul(v_word_251_, v___x_252_);
v_v1_254_ = lean_uint64_add(v_acc_250_, v___x_253_);
v___x_255_ = 31ULL;
v___x_256_ = lean_uint64_shift_left(v_v1_254_, v___x_255_);
v___x_257_ = 33ULL;
v___x_258_ = lean_uint64_shift_right(v_v1_254_, v___x_257_);
v_v2_259_ = lean_uint64_lor(v___x_256_, v___x_258_);
v___x_260_ = 11400714819323198485ULL;
v_v3_261_ = lean_uint64_mul(v_v2_259_, v___x_260_);
v___x_262_ = 27ULL;
v___x_263_ = lean_uint64_shift_right(v_v3_261_, v___x_262_);
v___x_264_ = lean_uint64_xor(v_v3_261_, v___x_263_);
return v___x_264_;
}
}

LEAN_EXPORT uint32_t orb_proxy_step(uint8_t v_committed_271_, uint8_t v_chunkCommits_272_, uint8_t v_stalled_273_, uint32_t v_retries_274_, uint32_t v_maxRetries_275_){
_start:
{
uint32_t v___y_277_; uint8_t v___x_280_; uint32_t v___y_282_; uint8_t v___x_297_;
v___x_280_ = 1;
v___x_297_ = lean_uint8_dec_eq(v_committed_271_, v___x_280_);
if (v___x_297_ == 0)
{
uint8_t v___x_298_;
v___x_298_ = lean_uint8_dec_eq(v_chunkCommits_272_, v___x_280_);
if (v___x_298_ == 0)
{
uint32_t v___x_299_;
v___x_299_ = 0;
v___y_282_ = v___x_299_;
goto v___jp_281_;
}
else
{
goto v___jp_295_;
}
}
else
{
goto v___jp_295_;
}
v___jp_276_:
{
uint32_t v___x_278_; uint32_t v___x_279_;
v___x_278_ = 768;
v___x_279_ = lean_uint32_lor(v___y_277_, v___x_278_);
return v___x_279_;
}
v___jp_281_:
{
uint8_t v___x_283_;
v___x_283_ = lean_uint8_dec_eq(v_stalled_273_, v___x_280_);
if (v___x_283_ == 0)
{
return v___y_282_;
}
else
{
uint8_t v___x_284_; uint8_t v___x_285_;
v___x_284_ = 0;
v___x_285_ = lean_uint8_dec_eq(v_committed_271_, v___x_284_);
if (v___x_285_ == 0)
{
v___y_277_ = v___y_282_;
goto v___jp_276_;
}
else
{
uint8_t v___x_286_;
v___x_286_ = lean_uint32_dec_lt(v_retries_274_, v_maxRetries_275_);
if (v___x_286_ == 0)
{
v___y_277_ = v___y_282_;
goto v___jp_276_;
}
else
{
uint32_t v___x_287_; uint32_t v___x_288_; uint32_t v___x_289_; uint8_t v___x_290_;
v___x_287_ = 2;
v___x_288_ = 1;
v___x_289_ = lean_uint32_add(v_retries_274_, v___x_288_);
v___x_290_ = lean_uint32_dec_le(v___x_287_, v___x_289_);
if (v___x_290_ == 0)
{
uint32_t v___x_291_; uint32_t v___x_292_;
v___x_291_ = 256;
v___x_292_ = lean_uint32_lor(v___y_282_, v___x_291_);
return v___x_292_;
}
else
{
uint32_t v___x_293_; uint32_t v___x_294_;
v___x_293_ = 66048;
v___x_294_ = lean_uint32_lor(v___y_282_, v___x_293_);
return v___x_294_;
}
}
}
}
}
v___jp_295_:
{
uint32_t v___x_296_;
v___x_296_ = 1;
v___y_282_ = v___x_296_;
goto v___jp_281_;
}
}
}

LEAN_EXPORT uint32_t orb_stream_deadlines(uint64_t v_clientElapsedMs_312_, uint64_t v_keepaliveMs_313_, uint64_t v_upstreamElapsedMs_314_, uint64_t v_baseIdleMs_315_, uint64_t v_providerFloorMs_316_, uint8_t v_atEventBoundary_317_, uint8_t v_hasMissionHeader_318_, uint8_t v_authVerified_319_){
_start:
{
uint32_t v___y_321_; uint32_t v___y_322_; uint32_t v___y_323_; uint32_t v___y_327_; uint32_t v___y_328_; uint32_t v___y_331_; uint32_t v___y_332_; uint64_t v___y_338_; uint32_t v___y_339_; uint64_t v___y_344_; uint64_t v___y_347_; uint8_t v___x_352_;
v___x_352_ = lean_uint64_dec_lt(v_baseIdleMs_315_, v_providerFloorMs_316_);
if (v___x_352_ == 0)
{
v___y_347_ = v_baseIdleMs_315_;
goto v___jp_346_;
}
else
{
v___y_347_ = v_providerFloorMs_316_;
goto v___jp_346_;
}
v___jp_320_:
{
uint32_t v___x_324_; uint32_t v___x_325_;
v___x_324_ = lean_uint32_lor(v___y_322_, v___y_321_);
v___x_325_ = lean_uint32_lor(v___x_324_, v___y_323_);
return v___x_325_;
}
v___jp_326_:
{
uint32_t v___x_329_;
v___x_329_ = 0;
v___y_321_ = v___y_327_;
v___y_322_ = v___y_328_;
v___y_323_ = v___x_329_;
goto v___jp_320_;
}
v___jp_330_:
{
uint8_t v___x_333_; uint8_t v___x_334_;
v___x_333_ = 1;
v___x_334_ = lean_uint8_dec_eq(v_hasMissionHeader_318_, v___x_333_);
if (v___x_334_ == 0)
{
v___y_327_ = v___y_332_;
v___y_328_ = v___y_331_;
goto v___jp_326_;
}
else
{
uint8_t v___x_335_;
v___x_335_ = lean_uint8_dec_eq(v_authVerified_319_, v___x_333_);
if (v___x_335_ == 0)
{
v___y_327_ = v___y_332_;
v___y_328_ = v___y_331_;
goto v___jp_326_;
}
else
{
uint32_t v___x_336_;
v___x_336_ = 65536;
v___y_321_ = v___y_332_;
v___y_322_ = v___y_331_;
v___y_323_ = v___x_336_;
goto v___jp_320_;
}
}
}
v___jp_337_:
{
uint8_t v___x_340_;
v___x_340_ = lean_uint64_dec_le(v___y_338_, v_upstreamElapsedMs_314_);
if (v___x_340_ == 0)
{
uint32_t v___x_341_;
v___x_341_ = 0;
v___y_331_ = v___y_339_;
v___y_332_ = v___x_341_;
goto v___jp_330_;
}
else
{
uint32_t v___x_342_;
v___x_342_ = 256;
v___y_331_ = v___y_339_;
v___y_332_ = v___x_342_;
goto v___jp_330_;
}
}
v___jp_343_:
{
uint32_t v___x_345_;
v___x_345_ = 0;
v___y_338_ = v___y_344_;
v___y_339_ = v___x_345_;
goto v___jp_337_;
}
v___jp_346_:
{
uint8_t v___x_348_;
v___x_348_ = lean_uint64_dec_le(v_keepaliveMs_313_, v_clientElapsedMs_312_);
if (v___x_348_ == 0)
{
v___y_344_ = v___y_347_;
goto v___jp_343_;
}
else
{
uint8_t v___x_349_; uint8_t v___x_350_;
v___x_349_ = 1;
v___x_350_ = lean_uint8_dec_eq(v_atEventBoundary_317_, v___x_349_);
if (v___x_350_ == 0)
{
v___y_344_ = v___y_347_;
goto v___jp_343_;
}
else
{
uint32_t v___x_351_;
v___x_351_ = 1;
v___y_338_ = v___y_347_;
v___y_339_ = v___x_351_;
goto v___jp_337_;
}
}
}
}
}

LEAN_EXPORT uint32_t orb_breaker_step(uint8_t v_reason_371_, uint32_t v_transientStreak_372_, uint32_t v_transientThreshold_373_){
_start:
{
uint32_t v___y_375_; uint8_t v___x_380_; uint8_t v___x_381_;
v___x_380_ = 0;
v___x_381_ = lean_uint8_dec_eq(v_reason_371_, v___x_380_);
if (v___x_381_ == 0)
{
uint8_t v___x_382_; uint8_t v___x_383_;
v___x_382_ = 4;
v___x_383_ = lean_uint8_dec_eq(v_reason_371_, v___x_382_);
if (v___x_383_ == 0)
{
uint8_t v___x_384_; uint8_t v___x_385_;
v___x_384_ = 2;
v___x_385_ = lean_uint8_dec_eq(v_reason_371_, v___x_384_);
if (v___x_385_ == 0)
{
uint8_t v___x_389_; uint8_t v___x_390_;
v___x_389_ = 3;
v___x_390_ = lean_uint8_dec_eq(v_reason_371_, v___x_389_);
if (v___x_390_ == 0)
{
uint8_t v___x_391_; uint8_t v___x_392_;
v___x_391_ = 1;
v___x_392_ = lean_uint8_dec_eq(v_reason_371_, v___x_391_);
if (v___x_392_ == 0)
{
uint8_t v___x_393_; uint8_t v___x_394_;
v___x_393_ = 6;
v___x_394_ = lean_uint8_dec_eq(v_reason_371_, v___x_393_);
if (v___x_394_ == 0)
{
uint32_t v___x_395_;
v___x_395_ = 65536;
return v___x_395_;
}
else
{
uint32_t v___x_396_;
v___x_396_ = 1;
return v___x_396_;
}
}
else
{
uint32_t v___x_397_;
v___x_397_ = 65792;
return v___x_397_;
}
}
else
{
goto v___jp_386_;
}
}
else
{
goto v___jp_386_;
}
v___jp_386_:
{
if (v___x_385_ == 0)
{
uint32_t v___x_387_;
v___x_387_ = 0;
v___y_375_ = v___x_387_;
goto v___jp_374_;
}
else
{
uint32_t v___x_388_;
v___x_388_ = 256;
v___y_375_ = v___x_388_;
goto v___jp_374_;
}
}
}
else
{
uint8_t v___x_398_;
v___x_398_ = lean_uint32_dec_le(v_transientThreshold_373_, v_transientStreak_372_);
if (v___x_398_ == 0)
{
uint32_t v___x_399_;
v___x_399_ = 0;
return v___x_399_;
}
else
{
uint32_t v___x_400_; uint8_t v___x_401_;
v___x_400_ = 1;
v___x_401_ = lean_uint32_dec_le(v___x_400_, v_transientThreshold_373_);
if (v___x_401_ == 0)
{
uint32_t v___x_402_;
v___x_402_ = 0;
return v___x_402_;
}
else
{
uint32_t v___x_403_;
v___x_403_ = 65536;
return v___x_403_;
}
}
}
}
else
{
uint32_t v___x_404_;
v___x_404_ = 0;
return v___x_404_;
}
v___jp_374_:
{
uint32_t v___x_376_; uint32_t v___x_377_; uint32_t v___x_378_; uint32_t v___x_379_;
v___x_376_ = 1;
v___x_377_ = lean_uint32_lor(v___x_376_, v___y_375_);
v___x_378_ = 65536;
v___x_379_ = lean_uint32_lor(v___x_377_, v___x_378_);
return v___x_379_;
}
}
}

LEAN_EXPORT uint8_t orb_mission_step(uint8_t v_armed_413_, uint8_t v_signal_414_, uint8_t v_continuationPending_415_, uint8_t v_wakeupArmed_416_, uint8_t v_madeProgress_417_, uint32_t v_priorNoProgress_418_, uint32_t v_maxNoProgress_419_, uint32_t v_priorContinuations_420_, uint32_t v_maxContinuations_421_, uint32_t v_hasMaxCont_422_){
_start:
{
uint8_t v___x_423_; uint8_t v___x_424_;
v___x_423_ = 0;
v___x_424_ = lean_uint8_dec_eq(v_armed_413_, v___x_423_);
if (v___x_424_ == 0)
{
uint8_t v___x_425_; uint8_t v___x_426_;
v___x_425_ = 1;
v___x_426_ = lean_uint8_dec_eq(v_signal_414_, v___x_425_);
if (v___x_426_ == 0)
{
uint8_t v___x_427_; uint8_t v___x_428_;
v___x_427_ = 2;
v___x_428_ = lean_uint8_dec_eq(v_signal_414_, v___x_427_);
if (v___x_428_ == 0)
{
uint8_t v___x_429_;
v___x_429_ = lean_uint8_dec_eq(v_continuationPending_415_, v___x_425_);
if (v___x_429_ == 0)
{
uint8_t v___x_430_;
v___x_430_ = lean_uint8_dec_eq(v_wakeupArmed_416_, v___x_425_);
if (v___x_430_ == 0)
{
uint32_t v___x_431_; uint32_t v___y_433_; uint32_t v___y_434_; uint32_t v___y_444_; uint8_t v___x_448_;
v___x_431_ = 1;
v___x_448_ = lean_uint32_dec_le(v___x_431_, v_maxNoProgress_419_);
if (v___x_448_ == 0)
{
v___y_444_ = v___x_431_;
goto v___jp_443_;
}
else
{
v___y_444_ = v_maxNoProgress_419_;
goto v___jp_443_;
}
v___jp_432_:
{
uint8_t v___x_435_;
v___x_435_ = lean_uint32_dec_le(v___y_433_, v___y_434_);
if (v___x_435_ == 0)
{
uint8_t v___x_436_;
v___x_436_ = lean_uint32_dec_eq(v_hasMaxCont_422_, v___x_431_);
if (v___x_436_ == 0)
{
uint8_t v___x_437_;
v___x_437_ = 7;
return v___x_437_;
}
else
{
uint32_t v___x_438_; uint8_t v___x_439_;
v___x_438_ = lean_uint32_add(v_priorContinuations_420_, v___x_431_);
v___x_439_ = lean_uint32_dec_lt(v_maxContinuations_421_, v___x_438_);
if (v___x_439_ == 0)
{
uint8_t v___x_440_;
v___x_440_ = 7;
return v___x_440_;
}
else
{
uint8_t v___x_441_;
v___x_441_ = 6;
return v___x_441_;
}
}
}
else
{
uint8_t v___x_442_;
v___x_442_ = 5;
return v___x_442_;
}
}
v___jp_443_:
{
uint8_t v___x_445_;
v___x_445_ = lean_uint8_dec_eq(v_madeProgress_417_, v___x_425_);
if (v___x_445_ == 0)
{
uint32_t v___x_446_;
v___x_446_ = lean_uint32_add(v_priorNoProgress_418_, v___x_431_);
v___y_433_ = v___y_444_;
v___y_434_ = v___x_446_;
goto v___jp_432_;
}
else
{
uint32_t v___x_447_;
v___x_447_ = 0;
v___y_433_ = v___y_444_;
v___y_434_ = v___x_447_;
goto v___jp_432_;
}
}
}
else
{
uint8_t v___x_449_;
v___x_449_ = 4;
return v___x_449_;
}
}
else
{
uint8_t v___x_450_;
v___x_450_ = 3;
return v___x_450_;
}
}
else
{
return v___x_427_;
}
}
else
{
return v___x_425_;
}
}
else
{
return v___x_423_;
}
}
}

LEAN_EXPORT uint8_t orb_reconcile_step(uint8_t v_status_473_, uint8_t v_isClientPlaced_474_, uint8_t v_sameBootId_475_, uint8_t v_isAssistantMode_476_, uint8_t v_runningInActor_477_, uint8_t v_hasLiveScope_478_, uint8_t v_hasDurableRun_479_, uint8_t v_recentlyUpdated_480_, uint8_t v_hasEvents_481_, uint8_t v_alreadyOrphaned_482_, uint8_t v_isServiceRestart_483_, uint8_t v_withinHorizon_484_, uint8_t v_liveRetryExists_485_){
_start:
{
uint8_t v___x_486_; uint8_t v___x_487_;
v___x_486_ = 1;
v___x_487_ = lean_uint8_dec_eq(v_isClientPlaced_474_, v___x_486_);
if (v___x_487_ == 0)
{
uint8_t v___x_488_;
v___x_488_ = lean_uint8_dec_eq(v_sameBootId_475_, v___x_486_);
if (v___x_488_ == 0)
{
uint8_t v___x_489_;
v___x_489_ = lean_uint8_dec_eq(v_runningInActor_477_, v___x_486_);
if (v___x_489_ == 0)
{
uint8_t v___x_490_;
v___x_490_ = lean_uint8_dec_eq(v_hasLiveScope_478_, v___x_486_);
if (v___x_490_ == 0)
{
uint8_t v___x_491_;
v___x_491_ = lean_uint8_dec_eq(v_hasDurableRun_479_, v___x_486_);
if (v___x_491_ == 0)
{
uint8_t v___x_492_; uint8_t v___x_493_;
v___x_492_ = 0;
v___x_493_ = lean_uint8_dec_eq(v_status_473_, v___x_492_);
if (v___x_493_ == 0)
{
uint8_t v___x_494_;
v___x_494_ = lean_uint8_dec_eq(v_status_473_, v___x_486_);
if (v___x_494_ == 0)
{
uint8_t v___x_495_; uint8_t v___x_496_;
v___x_495_ = 2;
v___x_496_ = lean_uint8_dec_eq(v_status_473_, v___x_495_);
if (v___x_496_ == 0)
{
return v___x_492_;
}
else
{
uint8_t v___x_497_;
v___x_497_ = lean_uint8_dec_eq(v_isServiceRestart_483_, v___x_486_);
if (v___x_497_ == 0)
{
return v___x_492_;
}
else
{
uint8_t v___x_498_;
v___x_498_ = lean_uint8_dec_eq(v_withinHorizon_484_, v___x_486_);
if (v___x_498_ == 0)
{
return v___x_492_;
}
else
{
uint8_t v___x_499_;
v___x_499_ = lean_uint8_dec_eq(v_liveRetryExists_485_, v___x_492_);
if (v___x_499_ == 0)
{
return v___x_492_;
}
else
{
uint8_t v___x_500_;
v___x_500_ = 3;
return v___x_500_;
}
}
}
}
}
else
{
uint8_t v___x_501_;
v___x_501_ = lean_uint8_dec_eq(v_hasEvents_481_, v___x_492_);
if (v___x_501_ == 0)
{
return v___x_492_;
}
else
{
uint8_t v___x_502_;
v___x_502_ = lean_uint8_dec_eq(v_alreadyOrphaned_482_, v___x_492_);
if (v___x_502_ == 0)
{
return v___x_492_;
}
else
{
uint8_t v___x_503_;
v___x_503_ = 2;
return v___x_503_;
}
}
}
}
else
{
uint8_t v___x_504_;
v___x_504_ = lean_uint8_dec_eq(v_isAssistantMode_476_, v___x_492_);
if (v___x_504_ == 0)
{
return v___x_492_;
}
else
{
uint8_t v___x_505_;
v___x_505_ = lean_uint8_dec_eq(v_recentlyUpdated_480_, v___x_492_);
if (v___x_505_ == 0)
{
return v___x_492_;
}
else
{
return v___x_486_;
}
}
}
}
else
{
uint8_t v___x_506_;
v___x_506_ = 0;
return v___x_506_;
}
}
else
{
uint8_t v___x_507_;
v___x_507_ = 0;
return v___x_507_;
}
}
else
{
uint8_t v___x_508_;
v___x_508_ = 0;
return v___x_508_;
}
}
else
{
uint8_t v___x_509_;
v___x_509_ = 0;
return v___x_509_;
}
}
else
{
uint8_t v___x_510_;
v___x_510_ = 0;
return v___x_510_;
}
}
}

LEAN_EXPORT uint32_t orb_queue_step(uint8_t v_deliveryOutcome_539_, uint8_t v_durablyStarted_540_){
_start:
{
uint8_t v___x_546_; uint8_t v___x_547_;
v___x_546_ = 0;
v___x_547_ = lean_uint8_dec_eq(v_deliveryOutcome_539_, v___x_546_);
if (v___x_547_ == 0)
{
goto v___jp_541_;
}
else
{
uint8_t v___x_548_; uint8_t v___x_549_;
v___x_548_ = 1;
v___x_549_ = lean_uint8_dec_eq(v_durablyStarted_540_, v___x_548_);
if (v___x_549_ == 0)
{
goto v___jp_541_;
}
else
{
uint32_t v___x_550_;
v___x_550_ = 256;
return v___x_550_;
}
}
v___jp_541_:
{
uint8_t v___x_542_; uint8_t v___x_543_;
v___x_542_ = 2;
v___x_543_ = lean_uint8_dec_eq(v_deliveryOutcome_539_, v___x_542_);
if (v___x_543_ == 0)
{
uint32_t v___x_544_;
v___x_544_ = 1;
return v___x_544_;
}
else
{
uint32_t v___x_545_;
v___x_545_ = 65537;
return v___x_545_;
}
}
}
}

LEAN_EXPORT uint8_t orb_vm_step(uint8_t v_op_557_, uint8_t v_sizeRank_558_, uint8_t v_maxSizeRank_559_, uint8_t v_secretProjected_560_, uint8_t v_ttlExpired_561_, uint8_t v_busy_562_, uint8_t v_ownerEnded_563_, uint8_t v_idleExpired_564_, uint32_t v_activeCount_565_, uint32_t v_maxConcurrent_566_, uint32_t v_ttlMinutes_567_, uint32_t v_maxTtlMinutes_568_, uint32_t v_jobMemPct_569_, uint64_t v_spentPlusNewCents_570_, uint64_t v_dailyCapCents_571_){
_start:
{
uint8_t v___x_572_; uint8_t v___x_573_;
v___x_572_ = 0;
v___x_573_ = lean_uint8_dec_eq(v_op_557_, v___x_572_);
if (v___x_573_ == 0)
{
uint8_t v___x_574_; uint8_t v___x_575_;
v___x_574_ = 1;
v___x_575_ = lean_uint8_dec_eq(v_ttlExpired_561_, v___x_574_);
if (v___x_575_ == 0)
{
uint8_t v___x_576_;
v___x_576_ = lean_uint8_dec_eq(v_busy_562_, v___x_572_);
if (v___x_576_ == 0)
{
return v___x_572_;
}
else
{
uint8_t v___x_577_;
v___x_577_ = lean_uint8_dec_eq(v_ownerEnded_563_, v___x_574_);
if (v___x_577_ == 0)
{
uint8_t v___x_578_;
v___x_578_ = lean_uint8_dec_eq(v_idleExpired_564_, v___x_574_);
if (v___x_578_ == 0)
{
return v___x_572_;
}
else
{
return v___x_574_;
}
}
else
{
return v___x_574_;
}
}
}
else
{
return v___x_574_;
}
}
else
{
uint8_t v___x_579_;
v___x_579_ = lean_uint8_dec_le(v_sizeRank_558_, v_maxSizeRank_559_);
if (v___x_579_ == 0)
{
return v___x_572_;
}
else
{
uint8_t v___x_580_;
v___x_580_ = lean_uint32_dec_lt(v_activeCount_565_, v_maxConcurrent_566_);
if (v___x_580_ == 0)
{
return v___x_572_;
}
else
{
uint8_t v___x_581_;
v___x_581_ = lean_uint64_dec_le(v_spentPlusNewCents_570_, v_dailyCapCents_571_);
if (v___x_581_ == 0)
{
return v___x_572_;
}
else
{
uint32_t v___x_582_; uint8_t v___x_583_;
v___x_582_ = 5;
v___x_583_ = lean_uint32_dec_le(v___x_582_, v_ttlMinutes_567_);
if (v___x_583_ == 0)
{
return v___x_572_;
}
else
{
uint8_t v___x_584_;
v___x_584_ = lean_uint32_dec_le(v_ttlMinutes_567_, v_maxTtlMinutes_568_);
if (v___x_584_ == 0)
{
return v___x_572_;
}
else
{
uint32_t v___x_585_; uint8_t v___x_586_;
v___x_585_ = 90;
v___x_586_ = lean_uint32_dec_le(v_jobMemPct_569_, v___x_585_);
if (v___x_586_ == 0)
{
return v___x_572_;
}
else
{
uint8_t v___x_587_;
v___x_587_ = lean_uint8_dec_eq(v_secretProjected_560_, v___x_572_);
if (v___x_587_ == 0)
{
return v___x_572_;
}
else
{
uint8_t v___x_588_;
v___x_588_ = 1;
return v___x_588_;
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

LEAN_EXPORT uint32_t lp_orb_x2dspec_Orb_Kernel_accessStep___redArg(uint8_t v_sameOwner_621_, uint8_t v_isSelfOrChild_622_, uint8_t v_isReadTool_623_, uint8_t v_grantApproved_624_, uint8_t v_grantUnexpired_625_){
_start:
{
uint32_t v___y_627_; uint8_t v___x_630_; uint8_t v___x_631_;
v___x_630_ = 1;
v___x_631_ = lean_uint8_dec_eq(v_sameOwner_621_, v___x_630_);
if (v___x_631_ == 0)
{
goto v___jp_632_;
}
else
{
uint8_t v___x_641_;
v___x_641_ = lean_uint8_dec_eq(v_isSelfOrChild_622_, v___x_630_);
if (v___x_641_ == 0)
{
goto v___jp_632_;
}
else
{
uint32_t v___x_642_;
v___x_642_ = 65793;
return v___x_642_;
}
}
v___jp_626_:
{
uint32_t v___x_628_; uint32_t v___x_629_;
v___x_628_ = 256;
v___x_629_ = lean_uint32_lor(v___y_627_, v___x_628_);
return v___x_629_;
}
v___jp_632_:
{
if (v___x_631_ == 0)
{
uint32_t v___x_633_;
v___x_633_ = 0;
return v___x_633_;
}
else
{
uint8_t v___x_634_;
v___x_634_ = lean_uint8_dec_eq(v_grantApproved_624_, v___x_630_);
if (v___x_634_ == 0)
{
uint32_t v___x_635_;
v___x_635_ = 0;
return v___x_635_;
}
else
{
uint8_t v___x_636_;
v___x_636_ = lean_uint8_dec_eq(v_grantUnexpired_625_, v___x_630_);
if (v___x_636_ == 0)
{
uint32_t v___x_637_;
v___x_637_ = 0;
return v___x_637_;
}
else
{
uint8_t v___x_638_;
v___x_638_ = lean_uint8_dec_eq(v_isReadTool_623_, v___x_630_);
if (v___x_638_ == 0)
{
uint32_t v___x_639_;
v___x_639_ = 0;
v___y_627_ = v___x_639_;
goto v___jp_626_;
}
else
{
uint32_t v___x_640_;
v___x_640_ = 1;
v___y_627_ = v___x_640_;
goto v___jp_626_;
}
}
}
}
}
}
}

LEAN_EXPORT uint32_t orb_access_step(uint8_t v_sameOwner_655_, uint8_t v_isSelfOrChild_656_, uint8_t v_isReadTool_657_, uint8_t v_grantApproved_658_, uint8_t v_grantUnexpired_659_, uint8_t v___targetExists_660_){
_start:
{
uint32_t v___y_662_; uint8_t v___x_665_; uint8_t v___x_666_;
v___x_665_ = 1;
v___x_666_ = lean_uint8_dec_eq(v_sameOwner_655_, v___x_665_);
if (v___x_666_ == 0)
{
goto v___jp_667_;
}
else
{
uint8_t v___x_676_;
v___x_676_ = lean_uint8_dec_eq(v_isSelfOrChild_656_, v___x_665_);
if (v___x_676_ == 0)
{
goto v___jp_667_;
}
else
{
uint32_t v___x_677_;
v___x_677_ = 65793;
return v___x_677_;
}
}
v___jp_661_:
{
uint32_t v___x_663_; uint32_t v___x_664_;
v___x_663_ = 256;
v___x_664_ = lean_uint32_lor(v___y_662_, v___x_663_);
return v___x_664_;
}
v___jp_667_:
{
if (v___x_666_ == 0)
{
uint32_t v___x_668_;
v___x_668_ = 0;
return v___x_668_;
}
else
{
uint8_t v___x_669_;
v___x_669_ = lean_uint8_dec_eq(v_grantApproved_658_, v___x_665_);
if (v___x_669_ == 0)
{
uint32_t v___x_670_;
v___x_670_ = 0;
return v___x_670_;
}
else
{
uint8_t v___x_671_;
v___x_671_ = lean_uint8_dec_eq(v_grantUnexpired_659_, v___x_665_);
if (v___x_671_ == 0)
{
uint32_t v___x_672_;
v___x_672_ = 0;
return v___x_672_;
}
else
{
uint8_t v___x_673_;
v___x_673_ = lean_uint8_dec_eq(v_isReadTool_657_, v___x_665_);
if (v___x_673_ == 0)
{
uint32_t v___x_674_;
v___x_674_ = 0;
v___y_662_ = v___x_674_;
goto v___jp_661_;
}
else
{
uint32_t v___x_675_;
v___x_675_ = 1;
v___y_662_ = v___x_675_;
goto v___jp_661_;
}
}
}
}
}
}
}

LEAN_EXPORT uint32_t orb_workfold_step(uint8_t v_itemKind_692_, uint8_t v_isCumulative_693_, uint8_t v_isNonEmpty_694_, uint8_t v_toolAhead_695_, uint8_t v_nextIsTool_696_, uint8_t v_foldHasTool_697_){
_start:
{
uint8_t v___x_698_; uint8_t v___x_699_;
v___x_698_ = 3;
v___x_699_ = lean_uint8_dec_eq(v_itemKind_692_, v___x_698_);
if (v___x_699_ == 0)
{
uint8_t v___x_700_; uint8_t v___x_705_;
v___x_700_ = 1;
v___x_705_ = lean_uint8_dec_eq(v_itemKind_692_, v___x_700_);
if (v___x_705_ == 0)
{
uint8_t v___x_706_; uint8_t v___x_707_;
v___x_706_ = 2;
v___x_707_ = lean_uint8_dec_eq(v_itemKind_692_, v___x_706_);
if (v___x_707_ == 0)
{
uint32_t v___x_708_;
v___x_708_ = 0;
return v___x_708_;
}
else
{
uint8_t v___x_709_; uint8_t v___x_710_;
v___x_709_ = 0;
v___x_710_ = lean_uint8_dec_eq(v_isCumulative_693_, v___x_709_);
if (v___x_710_ == 0)
{
uint32_t v___x_711_;
v___x_711_ = 0;
return v___x_711_;
}
else
{
uint8_t v___x_712_;
v___x_712_ = lean_uint8_dec_eq(v_isNonEmpty_694_, v___x_700_);
if (v___x_712_ == 0)
{
uint32_t v___x_713_;
v___x_713_ = 0;
return v___x_713_;
}
else
{
uint8_t v___x_714_;
v___x_714_ = lean_uint8_dec_eq(v_toolAhead_695_, v___x_700_);
if (v___x_714_ == 0)
{
uint32_t v___x_715_;
v___x_715_ = 0;
return v___x_715_;
}
else
{
uint8_t v___x_716_;
v___x_716_ = lean_uint8_dec_eq(v_foldHasTool_697_, v___x_700_);
if (v___x_716_ == 0)
{
uint8_t v___x_717_;
v___x_717_ = lean_uint8_dec_eq(v_nextIsTool_696_, v___x_700_);
if (v___x_717_ == 0)
{
uint32_t v___x_718_;
v___x_718_ = 0;
return v___x_718_;
}
else
{
goto v___jp_701_;
}
}
else
{
goto v___jp_701_;
}
}
}
}
}
}
else
{
uint8_t v___x_719_;
v___x_719_ = lean_uint8_dec_eq(v_foldHasTool_697_, v___x_700_);
if (v___x_719_ == 0)
{
uint32_t v___x_720_;
v___x_720_ = 1;
return v___x_720_;
}
else
{
uint32_t v___x_721_;
v___x_721_ = 257;
return v___x_721_;
}
}
v___jp_701_:
{
uint8_t v___x_702_;
v___x_702_ = lean_uint8_dec_eq(v_foldHasTool_697_, v___x_700_);
if (v___x_702_ == 0)
{
uint32_t v___x_703_;
v___x_703_ = 1;
return v___x_703_;
}
else
{
uint32_t v___x_704_;
v___x_704_ = 257;
return v___x_704_;
}
}
}
else
{
uint32_t v___x_722_;
v___x_722_ = 257;
return v___x_722_;
}
}
}

LEAN_EXPORT uint8_t orb_taskcard_step(uint8_t v_turnEnded_737_, uint8_t v_allClosed_738_, uint8_t v_turnOutcomeFinished_739_){
_start:
{
uint8_t v___x_740_; uint8_t v___x_741_;
v___x_740_ = 0;
v___x_741_ = lean_uint8_dec_eq(v_turnEnded_737_, v___x_740_);
if (v___x_741_ == 0)
{
uint8_t v___x_742_; uint8_t v___x_743_;
v___x_742_ = 1;
v___x_743_ = lean_uint8_dec_eq(v_allClosed_738_, v___x_742_);
if (v___x_743_ == 0)
{
uint8_t v___x_744_;
v___x_744_ = lean_uint8_dec_eq(v_turnOutcomeFinished_739_, v___x_742_);
if (v___x_744_ == 0)
{
uint8_t v___x_745_;
v___x_745_ = 3;
return v___x_745_;
}
else
{
uint8_t v___x_746_;
v___x_746_ = 2;
return v___x_746_;
}
}
else
{
return v___x_742_;
}
}
else
{
return v___x_740_;
}
}
}

LEAN_EXPORT uint32_t orb_sidebar_visibility(uint8_t v_matchesFilter_755_, uint8_t v_hasVisibleDescendant_756_, uint8_t v_isAcknowledged_757_, uint8_t v_hasParent_758_, uint8_t v_isFork_759_, uint8_t v_parentReachesSelf_760_){
_start:
{
uint32_t v___y_762_; uint32_t v___y_763_; uint32_t v___y_764_; uint32_t v___y_768_; uint32_t v___y_769_; uint8_t v___x_771_; uint32_t v___y_773_; uint32_t v___y_774_; uint32_t v___y_781_; uint32_t v___y_784_; uint8_t v___x_791_;
v___x_771_ = 1;
v___x_791_ = lean_uint8_dec_eq(v_matchesFilter_755_, v___x_771_);
if (v___x_791_ == 0)
{
uint8_t v___x_792_;
v___x_792_ = lean_uint8_dec_eq(v_hasVisibleDescendant_756_, v___x_771_);
if (v___x_792_ == 0)
{
uint32_t v___x_793_;
v___x_793_ = 0;
v___y_784_ = v___x_793_;
goto v___jp_783_;
}
else
{
goto v___jp_789_;
}
}
else
{
goto v___jp_789_;
}
v___jp_761_:
{
uint32_t v___x_765_; uint32_t v___x_766_;
v___x_765_ = lean_uint32_lor(v___y_762_, v___y_763_);
v___x_766_ = lean_uint32_lor(v___x_765_, v___y_764_);
return v___x_766_;
}
v___jp_767_:
{
uint32_t v___x_770_;
v___x_770_ = 0;
v___y_762_ = v___y_768_;
v___y_763_ = v___y_769_;
v___y_764_ = v___x_770_;
goto v___jp_761_;
}
v___jp_772_:
{
uint8_t v___x_775_;
v___x_775_ = lean_uint8_dec_eq(v_hasParent_758_, v___x_771_);
if (v___x_775_ == 0)
{
v___y_768_ = v___y_773_;
v___y_769_ = v___y_774_;
goto v___jp_767_;
}
else
{
uint8_t v___x_776_; uint8_t v___x_777_;
v___x_776_ = 0;
v___x_777_ = lean_uint8_dec_eq(v_isFork_759_, v___x_776_);
if (v___x_777_ == 0)
{
v___y_768_ = v___y_773_;
v___y_769_ = v___y_774_;
goto v___jp_767_;
}
else
{
uint8_t v___x_778_;
v___x_778_ = lean_uint8_dec_eq(v_parentReachesSelf_760_, v___x_776_);
if (v___x_778_ == 0)
{
v___y_768_ = v___y_773_;
v___y_769_ = v___y_774_;
goto v___jp_767_;
}
else
{
uint32_t v___x_779_;
v___x_779_ = 65536;
v___y_762_ = v___y_773_;
v___y_763_ = v___y_774_;
v___y_764_ = v___x_779_;
goto v___jp_761_;
}
}
}
}
v___jp_780_:
{
uint32_t v___x_782_;
v___x_782_ = 0;
v___y_773_ = v___y_781_;
v___y_774_ = v___x_782_;
goto v___jp_772_;
}
v___jp_783_:
{
uint8_t v___x_785_;
v___x_785_ = lean_uint8_dec_eq(v_isAcknowledged_757_, v___x_771_);
if (v___x_785_ == 0)
{
v___y_781_ = v___y_784_;
goto v___jp_780_;
}
else
{
uint32_t v___x_786_; uint8_t v___x_787_;
v___x_786_ = 0;
v___x_787_ = lean_uint32_dec_eq(v___y_784_, v___x_786_);
if (v___x_787_ == 0)
{
v___y_781_ = v___y_784_;
goto v___jp_780_;
}
else
{
uint32_t v___x_788_;
v___x_788_ = 256;
v___y_773_ = v___y_784_;
v___y_774_ = v___x_788_;
goto v___jp_772_;
}
}
}
v___jp_789_:
{
uint32_t v___x_790_;
v___x_790_ = 1;
v___y_784_ = v___x_790_;
goto v___jp_783_;
}
}
}

LEAN_EXPORT uint32_t orb_admission_step(uint8_t v_recoveryPhase_808_, uint8_t v_isQuiescent_809_, uint8_t v_reservedTagForged_810_, uint64_t v_emergencyPlusCandBytes_811_, uint64_t v_freeDiskBytes_812_){
_start:
{
uint8_t v___x_813_; uint8_t v___x_814_;
v___x_813_ = 1;
v___x_814_ = lean_uint8_dec_eq(v_recoveryPhase_808_, v___x_813_);
if (v___x_814_ == 0)
{
uint8_t v___x_815_; uint8_t v___x_816_;
v___x_815_ = 2;
v___x_816_ = lean_uint8_dec_eq(v_recoveryPhase_808_, v___x_815_);
if (v___x_816_ == 0)
{
uint8_t v___x_817_;
v___x_817_ = lean_uint8_dec_eq(v_isQuiescent_809_, v___x_813_);
if (v___x_817_ == 0)
{
uint32_t v___x_818_;
v___x_818_ = 0;
return v___x_818_;
}
else
{
uint8_t v___x_819_; uint8_t v___x_820_;
v___x_819_ = 0;
v___x_820_ = lean_uint8_dec_eq(v_reservedTagForged_810_, v___x_819_);
if (v___x_820_ == 0)
{
uint32_t v___x_821_;
v___x_821_ = 0;
return v___x_821_;
}
else
{
uint8_t v___x_822_;
v___x_822_ = lean_uint64_dec_le(v_emergencyPlusCandBytes_811_, v_freeDiskBytes_812_);
if (v___x_822_ == 0)
{
uint32_t v___x_823_;
v___x_823_ = 0;
return v___x_823_;
}
else
{
uint32_t v___x_824_;
v___x_824_ = 1;
return v___x_824_;
}
}
}
}
else
{
uint32_t v___x_825_;
v___x_825_ = 65536;
return v___x_825_;
}
}
else
{
uint32_t v___x_826_;
v___x_826_ = 256;
return v___x_826_;
}
}
}

LEAN_EXPORT uint64_t orb_account_cooldown_secs(uint64_t v_baseSecs_839_, uint64_t v_maxSecs_840_, uint32_t v_consecutive_841_){
_start:
{
uint64_t v___x_842_; uint64_t v___y_844_; uint64_t v___y_845_; uint32_t v___y_846_; uint64_t v___y_853_; uint64_t v___y_854_; uint32_t v___y_855_; uint64_t v___y_859_; uint64_t v___y_860_; uint64_t v___y_866_; uint8_t v___x_868_;
v___x_842_ = 1ULL;
v___x_868_ = lean_uint64_dec_le(v___x_842_, v_baseSecs_839_);
if (v___x_868_ == 0)
{
uint64_t v___x_869_;
v___x_869_ = 600ULL;
v___y_866_ = v___x_869_;
goto v___jp_865_;
}
else
{
v___y_866_ = v_baseSecs_839_;
goto v___jp_865_;
}
v___jp_843_:
{
uint64_t v_exp_847_; uint64_t v_factor_848_; uint64_t v___x_849_; uint8_t v___x_850_;
v_exp_847_ = lean_uint32_to_uint64(v___y_846_);
v_factor_848_ = lean_uint64_shift_left(v___x_842_, v_exp_847_);
v___x_849_ = lean_uint64_div(v___y_844_, v_factor_848_);
v___x_850_ = lean_uint64_dec_lt(v___x_849_, v___y_845_);
if (v___x_850_ == 0)
{
uint64_t v___x_851_;
v___x_851_ = lean_uint64_mul(v___y_845_, v_factor_848_);
return v___x_851_;
}
else
{
return v___y_844_;
}
}
v___jp_852_:
{
uint32_t v___x_856_; uint8_t v___x_857_;
v___x_856_ = 20;
v___x_857_ = lean_uint32_dec_lt(v___x_856_, v___y_855_);
if (v___x_857_ == 0)
{
v___y_844_ = v___y_853_;
v___y_845_ = v___y_854_;
v___y_846_ = v___y_855_;
goto v___jp_843_;
}
else
{
v___y_844_ = v___y_853_;
v___y_845_ = v___y_854_;
v___y_846_ = v___x_856_;
goto v___jp_843_;
}
}
v___jp_858_:
{
uint32_t v___x_861_; uint8_t v___x_862_;
v___x_861_ = 1;
v___x_862_ = lean_uint32_dec_lt(v___x_861_, v_consecutive_841_);
if (v___x_862_ == 0)
{
uint32_t v___x_863_;
v___x_863_ = 0;
v___y_853_ = v___y_860_;
v___y_854_ = v___y_859_;
v___y_855_ = v___x_863_;
goto v___jp_852_;
}
else
{
uint32_t v___x_864_;
v___x_864_ = lean_uint32_sub(v_consecutive_841_, v___x_861_);
v___y_853_ = v___y_860_;
v___y_854_ = v___y_859_;
v___y_855_ = v___x_864_;
goto v___jp_852_;
}
}
v___jp_865_:
{
uint8_t v___x_867_;
v___x_867_ = lean_uint64_dec_lt(v___y_866_, v_maxSecs_840_);
if (v___x_867_ == 0)
{
v___y_859_ = v___y_866_;
v___y_860_ = v___y_866_;
goto v___jp_858_;
}
else
{
v___y_859_ = v___y_866_;
v___y_860_ = v_maxSecs_840_;
goto v___jp_858_;
}
}
}
}

LEAN_EXPORT uint64_t orb_cost_cents_step(uint64_t v_inputTokens_878_, uint64_t v_outputTokens_879_, uint64_t v_cacheCreateTokens_880_, uint64_t v_cacheReadTokens_881_, uint64_t v_inputNano_882_, uint64_t v_outputNano_883_, uint64_t v_cacheCreateNano_884_, uint64_t v_cacheReadNano_885_){
_start:
{
uint64_t v___y_887_; uint8_t v___x_899_;
v___x_899_ = lean_uint64_dec_le(v_cacheCreateTokens_880_, v_inputTokens_878_);
if (v___x_899_ == 0)
{
uint64_t v___x_900_;
v___x_900_ = 0ULL;
v___y_887_ = v___x_900_;
goto v___jp_886_;
}
else
{
uint64_t v___x_901_;
v___x_901_ = lean_uint64_sub(v_inputTokens_878_, v_cacheCreateTokens_880_);
v___y_887_ = v___x_901_;
goto v___jp_886_;
}
v___jp_886_:
{
uint64_t v___x_888_; uint64_t v___x_889_; uint64_t v___x_890_; uint64_t v___x_891_; uint64_t v___x_892_; uint64_t v___x_893_; uint64_t v_totalNano_894_; uint64_t v___x_895_; uint64_t v___x_896_; uint64_t v___x_897_; uint64_t v___x_898_;
v___x_888_ = lean_uint64_mul(v___y_887_, v_inputNano_882_);
v___x_889_ = lean_uint64_mul(v_outputTokens_879_, v_outputNano_883_);
v___x_890_ = lean_uint64_add(v___x_888_, v___x_889_);
v___x_891_ = lean_uint64_mul(v_cacheCreateTokens_880_, v_cacheCreateNano_884_);
v___x_892_ = lean_uint64_add(v___x_890_, v___x_891_);
v___x_893_ = lean_uint64_mul(v_cacheReadTokens_881_, v_cacheReadNano_885_);
v_totalNano_894_ = lean_uint64_add(v___x_892_, v___x_893_);
v___x_895_ = 5000000ULL;
v___x_896_ = lean_uint64_add(v_totalNano_894_, v___x_895_);
v___x_897_ = 10000000ULL;
v___x_898_ = lean_uint64_div(v___x_896_, v___x_897_);
return v___x_898_;
}
}
}

LEAN_EXPORT uint8_t orb_stream_loop_step(uint8_t v_cancelledOrTimedOut_920_, uint8_t v_hashCollision_921_, uint32_t v_windowLen_922_, uint32_t v_minLen_923_, uint32_t v_repeats_924_, uint32_t v_nonOverlappingCount_925_, uint32_t v_distinctWords4Plus_926_, uint64_t v_comparisons_927_, uint64_t v_comparisonBudget_928_){
_start:
{
uint8_t v___x_929_; uint8_t v___x_930_;
v___x_929_ = 1;
v___x_930_ = lean_uint8_dec_eq(v_cancelledOrTimedOut_920_, v___x_929_);
if (v___x_930_ == 0)
{
uint32_t v___x_931_; uint8_t v___x_932_;
v___x_931_ = 256;
v___x_932_ = lean_uint32_dec_lt(v___x_931_, v_minLen_923_);
if (v___x_932_ == 0)
{
uint8_t v___x_933_;
v___x_933_ = lean_uint64_dec_lt(v_comparisonBudget_928_, v_comparisons_927_);
if (v___x_933_ == 0)
{
uint32_t v___x_934_; uint8_t v___x_935_;
v___x_934_ = 0;
v___x_935_ = lean_uint32_dec_eq(v_minLen_923_, v___x_934_);
if (v___x_935_ == 0)
{
uint32_t v___x_936_; uint8_t v___x_937_;
v___x_936_ = 2;
v___x_937_ = lean_uint32_dec_lt(v_repeats_924_, v___x_936_);
if (v___x_937_ == 0)
{
uint32_t v___x_938_; uint8_t v___x_939_;
v___x_938_ = lean_uint32_mul(v_minLen_923_, v_repeats_924_);
v___x_939_ = lean_uint32_dec_lt(v_windowLen_922_, v___x_938_);
if (v___x_939_ == 0)
{
uint8_t v___x_940_;
v___x_940_ = lean_uint8_dec_eq(v_hashCollision_921_, v___x_929_);
if (v___x_940_ == 0)
{
uint8_t v___x_941_;
v___x_941_ = lean_uint32_dec_le(v_repeats_924_, v_nonOverlappingCount_925_);
if (v___x_941_ == 0)
{
uint8_t v___x_942_;
v___x_942_ = 0;
return v___x_942_;
}
else
{
uint8_t v___x_943_;
v___x_943_ = lean_uint32_dec_le(v___x_936_, v_distinctWords4Plus_926_);
if (v___x_943_ == 0)
{
uint8_t v___x_944_;
v___x_944_ = 0;
return v___x_944_;
}
else
{
return v___x_929_;
}
}
}
else
{
uint8_t v___x_945_;
v___x_945_ = 2;
return v___x_945_;
}
}
else
{
uint8_t v___x_946_;
v___x_946_ = 0;
return v___x_946_;
}
}
else
{
uint8_t v___x_947_;
v___x_947_ = 0;
return v___x_947_;
}
}
else
{
uint8_t v___x_948_;
v___x_948_ = 0;
return v___x_948_;
}
}
else
{
uint8_t v___x_949_;
v___x_949_ = 2;
return v___x_949_;
}
}
else
{
uint8_t v___x_950_;
v___x_950_ = 2;
return v___x_950_;
}
}
else
{
uint8_t v___x_951_;
v___x_951_ = 2;
return v___x_951_;
}
}
}

LEAN_EXPORT uint32_t orb_job_ledger_step(uint8_t v_isAcceptedRemoteBuild_972_, uint8_t v_expectsContinuation_973_, uint8_t v_newerTerminalExists_974_, uint8_t v_newerAmbiguousTentative_975_){
_start:
{
uint8_t v___x_976_; uint32_t v___y_978_; uint8_t v___x_985_;
v___x_976_ = 1;
v___x_985_ = lean_uint8_dec_eq(v_newerTerminalExists_974_, v___x_976_);
if (v___x_985_ == 0)
{
uint8_t v___x_986_;
v___x_986_ = lean_uint8_dec_eq(v_newerAmbiguousTentative_975_, v___x_976_);
if (v___x_986_ == 0)
{
uint32_t v___x_987_;
v___x_987_ = 0;
v___y_978_ = v___x_987_;
goto v___jp_977_;
}
else
{
uint32_t v___x_988_;
v___x_988_ = 256;
v___y_978_ = v___x_988_;
goto v___jp_977_;
}
}
else
{
uint32_t v___x_989_;
v___x_989_ = 512;
v___y_978_ = v___x_989_;
goto v___jp_977_;
}
v___jp_977_:
{
uint8_t v___x_979_;
v___x_979_ = lean_uint8_dec_eq(v_isAcceptedRemoteBuild_972_, v___x_976_);
if (v___x_979_ == 0)
{
return v___y_978_;
}
else
{
uint8_t v___x_980_;
v___x_980_ = lean_uint8_dec_eq(v_expectsContinuation_973_, v___x_976_);
if (v___x_980_ == 0)
{
return v___y_978_;
}
else
{
uint32_t v___x_981_; uint8_t v___x_982_;
v___x_981_ = 0;
v___x_982_ = lean_uint32_dec_eq(v___y_978_, v___x_981_);
if (v___x_982_ == 0)
{
return v___y_978_;
}
else
{
uint32_t v___x_983_; uint32_t v___x_984_;
v___x_983_ = 1;
v___x_984_ = lean_uint32_lor(v___x_983_, v___y_978_);
return v___x_984_;
}
}
}
}
}
}

LEAN_EXPORT uint8_t orb_proc_liveness_step(uint8_t v_procMissing_1000_, uint8_t v_procReadError_1001_, uint8_t v_isZombieOrDeadState_1002_, uint8_t v_hasExpectedTicks_1003_, uint32_t v_fieldsAfterComm_1004_, uint64_t v_expectedStartTicks_1005_, uint64_t v_actualStartTicks_1006_){
_start:
{
uint8_t v___x_1007_; uint8_t v___x_1008_;
v___x_1007_ = 1;
v___x_1008_ = lean_uint8_dec_eq(v_procMissing_1000_, v___x_1007_);
if (v___x_1008_ == 0)
{
uint8_t v___x_1009_;
v___x_1009_ = lean_uint8_dec_eq(v_procReadError_1001_, v___x_1007_);
if (v___x_1009_ == 0)
{
uint8_t v___x_1010_;
v___x_1010_ = lean_uint8_dec_eq(v_isZombieOrDeadState_1002_, v___x_1007_);
if (v___x_1010_ == 0)
{
uint32_t v___x_1011_; uint8_t v___x_1012_;
v___x_1011_ = 20;
v___x_1012_ = lean_uint32_dec_lt(v_fieldsAfterComm_1004_, v___x_1011_);
if (v___x_1012_ == 0)
{
uint8_t v___x_1013_;
v___x_1013_ = lean_uint8_dec_eq(v_hasExpectedTicks_1003_, v___x_1007_);
if (v___x_1013_ == 0)
{
return v___x_1007_;
}
else
{
uint8_t v___x_1014_;
v___x_1014_ = lean_uint64_dec_eq(v_actualStartTicks_1006_, v_expectedStartTicks_1005_);
if (v___x_1014_ == 0)
{
uint8_t v___x_1015_;
v___x_1015_ = 0;
return v___x_1015_;
}
else
{
return v___x_1007_;
}
}
}
else
{
uint8_t v___x_1016_;
v___x_1016_ = 0;
return v___x_1016_;
}
}
else
{
uint8_t v___x_1017_;
v___x_1017_ = 0;
return v___x_1017_;
}
}
else
{
uint8_t v___x_1018_;
v___x_1018_ = 2;
return v___x_1018_;
}
}
else
{
uint8_t v___x_1019_;
v___x_1019_ = 0;
return v___x_1019_;
}
}
}

LEAN_EXPORT uint8_t orb_pr_gate_step(uint8_t v_merged_1036_, uint8_t v_draft_1037_, uint8_t v_closed_1038_, uint8_t v_exactHead_1039_, uint8_t v_actionRequired_1040_, uint8_t v_blocked_1041_, uint8_t v_behind_1042_, uint8_t v_conflicting_1043_, uint8_t v_checksGreen_1044_, uint8_t v_workflowsGreen_1045_){
_start:
{
uint8_t v___x_1046_; uint8_t v___x_1047_;
v___x_1046_ = 1;
v___x_1047_ = lean_uint8_dec_eq(v_merged_1036_, v___x_1046_);
if (v___x_1047_ == 0)
{
uint8_t v___x_1048_;
v___x_1048_ = lean_uint8_dec_eq(v_draft_1037_, v___x_1046_);
if (v___x_1048_ == 0)
{
uint8_t v___x_1049_;
v___x_1049_ = lean_uint8_dec_eq(v_closed_1038_, v___x_1046_);
if (v___x_1049_ == 0)
{
uint8_t v___x_1050_; uint8_t v___x_1051_;
v___x_1050_ = 0;
v___x_1051_ = lean_uint8_dec_eq(v_exactHead_1039_, v___x_1050_);
if (v___x_1051_ == 0)
{
uint8_t v___x_1052_;
v___x_1052_ = lean_uint8_dec_eq(v_actionRequired_1040_, v___x_1046_);
if (v___x_1052_ == 0)
{
uint8_t v___x_1053_;
v___x_1053_ = lean_uint8_dec_eq(v_blocked_1041_, v___x_1046_);
if (v___x_1053_ == 0)
{
uint8_t v___x_1054_;
v___x_1054_ = lean_uint8_dec_eq(v_behind_1042_, v___x_1046_);
if (v___x_1054_ == 0)
{
uint8_t v___x_1055_;
v___x_1055_ = lean_uint8_dec_eq(v_conflicting_1043_, v___x_1046_);
if (v___x_1055_ == 0)
{
uint8_t v___x_1056_;
v___x_1056_ = lean_uint8_dec_eq(v_checksGreen_1044_, v___x_1046_);
if (v___x_1056_ == 0)
{
uint8_t v___x_1057_;
v___x_1057_ = 9;
return v___x_1057_;
}
else
{
uint8_t v___x_1058_;
v___x_1058_ = lean_uint8_dec_eq(v_workflowsGreen_1045_, v___x_1046_);
if (v___x_1058_ == 0)
{
uint8_t v___x_1059_;
v___x_1059_ = 9;
return v___x_1059_;
}
else
{
uint8_t v___x_1060_;
v___x_1060_ = 8;
return v___x_1060_;
}
}
}
else
{
uint8_t v___x_1061_;
v___x_1061_ = 7;
return v___x_1061_;
}
}
else
{
uint8_t v___x_1062_;
v___x_1062_ = 6;
return v___x_1062_;
}
}
else
{
uint8_t v___x_1063_;
v___x_1063_ = 5;
return v___x_1063_;
}
}
else
{
uint8_t v___x_1064_;
v___x_1064_ = 4;
return v___x_1064_;
}
}
else
{
uint8_t v___x_1065_;
v___x_1065_ = 3;
return v___x_1065_;
}
}
else
{
uint8_t v___x_1066_;
v___x_1066_ = 2;
return v___x_1066_;
}
}
else
{
return v___x_1046_;
}
}
else
{
uint8_t v___x_1067_;
v___x_1067_ = 0;
return v___x_1067_;
}
}
}

LEAN_EXPORT uint32_t orb_turn_summary_step(uint8_t v_rawStatus_1090_, uint8_t v_turnEnded_1091_, uint8_t v_allClosed_1092_, uint8_t v_turnOutcomeFinished_1093_){
_start:
{
uint32_t v___y_1095_; uint8_t v___y_1096_; uint32_t v___y_1097_; uint8_t v___y_1098_; uint8_t v___x_1106_; uint32_t v___y_1108_; uint8_t v___y_1109_; uint32_t v___y_1110_; uint8_t v___y_1118_; uint32_t v___y_1119_; uint8_t v___y_1125_; uint8_t v___x_1131_;
v___x_1106_ = 2;
v___x_1131_ = lean_uint8_dec_eq(v_rawStatus_1090_, v___x_1106_);
if (v___x_1131_ == 0)
{
uint8_t v___x_1132_; uint8_t v___x_1133_;
v___x_1132_ = 3;
v___x_1133_ = lean_uint8_dec_eq(v_rawStatus_1090_, v___x_1132_);
if (v___x_1133_ == 0)
{
uint8_t v___x_1134_; uint8_t v___x_1135_;
v___x_1134_ = 1;
v___x_1135_ = lean_uint8_dec_eq(v_rawStatus_1090_, v___x_1134_);
if (v___x_1135_ == 0)
{
goto v___jp_1129_;
}
else
{
uint8_t v___x_1136_; uint8_t v___x_1137_;
v___x_1136_ = 0;
v___x_1137_ = lean_uint8_dec_eq(v_turnEnded_1091_, v___x_1136_);
if (v___x_1137_ == 0)
{
goto v___jp_1129_;
}
else
{
v___y_1125_ = v___x_1134_;
goto v___jp_1124_;
}
}
}
else
{
v___y_1125_ = v___x_1132_;
goto v___jp_1124_;
}
}
else
{
v___y_1125_ = v___x_1106_;
goto v___jp_1124_;
}
v___jp_1094_:
{
uint32_t v___x_1099_; uint32_t v___x_1100_; uint32_t v_card_1101_; uint32_t v___x_1102_; uint32_t v___x_1103_; uint32_t v___x_1104_; uint32_t v___x_1105_;
v___x_1099_ = lean_uint8_to_uint32(v___y_1098_);
v___x_1100_ = 24;
v_card_1101_ = lean_uint32_shift_left(v___x_1099_, v___x_1100_);
v___x_1102_ = lean_uint8_to_uint32(v___y_1096_);
v___x_1103_ = lean_uint32_lor(v___x_1102_, v___y_1095_);
v___x_1104_ = lean_uint32_lor(v___x_1103_, v___y_1097_);
v___x_1105_ = lean_uint32_lor(v___x_1104_, v_card_1101_);
return v___x_1105_;
}
v___jp_1107_:
{
uint8_t v___x_1111_; uint8_t v___x_1112_;
v___x_1111_ = 0;
v___x_1112_ = lean_uint8_dec_eq(v_turnEnded_1091_, v___x_1111_);
if (v___x_1112_ == 0)
{
uint8_t v___x_1113_; uint8_t v___x_1114_;
v___x_1113_ = 1;
v___x_1114_ = lean_uint8_dec_eq(v_allClosed_1092_, v___x_1113_);
if (v___x_1114_ == 0)
{
uint8_t v___x_1115_;
v___x_1115_ = lean_uint8_dec_eq(v_turnOutcomeFinished_1093_, v___x_1113_);
if (v___x_1115_ == 0)
{
uint8_t v___x_1116_;
v___x_1116_ = 3;
v___y_1095_ = v___y_1108_;
v___y_1096_ = v___y_1109_;
v___y_1097_ = v___y_1110_;
v___y_1098_ = v___x_1116_;
goto v___jp_1094_;
}
else
{
v___y_1095_ = v___y_1108_;
v___y_1096_ = v___y_1109_;
v___y_1097_ = v___y_1110_;
v___y_1098_ = v___x_1106_;
goto v___jp_1094_;
}
}
else
{
v___y_1095_ = v___y_1108_;
v___y_1096_ = v___y_1109_;
v___y_1097_ = v___y_1110_;
v___y_1098_ = v___x_1113_;
goto v___jp_1094_;
}
}
else
{
v___y_1095_ = v___y_1108_;
v___y_1096_ = v___y_1109_;
v___y_1097_ = v___y_1110_;
v___y_1098_ = v___x_1111_;
goto v___jp_1094_;
}
}
v___jp_1117_:
{
uint8_t v___x_1120_; uint8_t v___x_1121_;
v___x_1120_ = 1;
v___x_1121_ = lean_uint8_dec_eq(v___y_1118_, v___x_1120_);
if (v___x_1121_ == 0)
{
uint32_t v___x_1122_;
v___x_1122_ = 0;
v___y_1108_ = v___y_1119_;
v___y_1109_ = v___y_1118_;
v___y_1110_ = v___x_1122_;
goto v___jp_1107_;
}
else
{
uint32_t v___x_1123_;
v___x_1123_ = 65536;
v___y_1108_ = v___y_1119_;
v___y_1109_ = v___y_1118_;
v___y_1110_ = v___x_1123_;
goto v___jp_1107_;
}
}
v___jp_1124_:
{
uint8_t v___x_1126_;
v___x_1126_ = lean_uint8_dec_eq(v___y_1125_, v___x_1106_);
if (v___x_1126_ == 0)
{
uint32_t v___x_1127_;
v___x_1127_ = 0;
v___y_1118_ = v___y_1125_;
v___y_1119_ = v___x_1127_;
goto v___jp_1117_;
}
else
{
uint32_t v___x_1128_;
v___x_1128_ = 256;
v___y_1118_ = v___y_1125_;
v___y_1119_ = v___x_1128_;
goto v___jp_1117_;
}
}
v___jp_1129_:
{
uint8_t v___x_1130_;
v___x_1130_ = 0;
v___y_1125_ = v___x_1130_;
goto v___jp_1124_;
}
}
}

LEAN_EXPORT uint64_t orb_usage_limit_status(uint8_t v_statusKind_1148_, uint8_t v_claimKind_1149_, uint8_t v_hasUtilization_1150_, uint8_t v_utilizationPct_1151_, uint8_t v_hasReset_1152_, uint64_t v_resetRemSecs_1153_){
_start:
{
uint64_t v___y_1155_; uint64_t v___y_1156_; uint64_t v___y_1165_; uint64_t v___y_1166_; uint64_t v___y_1170_; uint64_t v___y_1171_; uint64_t v___y_1172_; uint64_t v___y_1178_; uint64_t v___y_1179_; uint64_t v___y_1186_; uint8_t v___x_1188_; uint8_t v___x_1189_;
v___x_1188_ = 0;
v___x_1189_ = lean_uint8_dec_eq(v_statusKind_1148_, v___x_1188_);
if (v___x_1189_ == 0)
{
uint8_t v___x_1190_; uint64_t v___y_1192_; uint64_t v___y_1198_; uint8_t v___x_1204_;
v___x_1190_ = 1;
v___x_1204_ = lean_uint8_dec_eq(v_statusKind_1148_, v___x_1190_);
if (v___x_1204_ == 0)
{
uint8_t v___x_1205_; uint8_t v___x_1206_;
v___x_1205_ = 2;
v___x_1206_ = lean_uint8_dec_eq(v_statusKind_1148_, v___x_1205_);
if (v___x_1206_ == 0)
{
uint64_t v___x_1207_;
v___x_1207_ = 3ULL;
return v___x_1207_;
}
else
{
uint8_t v___x_1208_;
v___x_1208_ = lean_uint8_dec_eq(v_hasReset_1152_, v___x_1190_);
if (v___x_1208_ == 0)
{
uint64_t v___x_1209_;
v___x_1209_ = 2ULL;
return v___x_1209_;
}
else
{
uint64_t v___x_1210_; uint8_t v___x_1211_;
v___x_1210_ = 0ULL;
v___x_1211_ = lean_uint64_dec_lt(v___x_1210_, v_resetRemSecs_1153_);
if (v___x_1211_ == 0)
{
uint64_t v___x_1212_;
v___x_1212_ = 2ULL;
return v___x_1212_;
}
else
{
uint64_t v___x_1213_; uint64_t v_mins_1214_; uint64_t v___x_1215_; uint64_t v_hrs_1216_; uint64_t v___x_1217_; uint64_t v_days_1218_; uint8_t v___x_1219_; uint64_t v___y_1221_;
v___x_1213_ = 60ULL;
v_mins_1214_ = lean_uint64_div(v_resetRemSecs_1153_, v___x_1213_);
v___x_1215_ = 3600ULL;
v_hrs_1216_ = lean_uint64_div(v_resetRemSecs_1153_, v___x_1215_);
v___x_1217_ = 86400ULL;
v_days_1218_ = lean_uint64_div(v_resetRemSecs_1153_, v___x_1217_);
v___x_1219_ = lean_uint64_dec_lt(v_mins_1214_, v___x_1213_);
if (v___x_1219_ == 0)
{
uint64_t v___x_1226_; uint8_t v___x_1227_;
v___x_1226_ = 48ULL;
v___x_1227_ = lean_uint64_dec_lt(v_hrs_1216_, v___x_1226_);
if (v___x_1227_ == 0)
{
uint64_t v___x_1228_;
v___x_1228_ = 3ULL;
v___y_1221_ = v___x_1228_;
goto v___jp_1220_;
}
else
{
uint64_t v___x_1229_;
v___x_1229_ = 2ULL;
v___y_1221_ = v___x_1229_;
goto v___jp_1220_;
}
}
else
{
uint64_t v___x_1230_;
v___x_1230_ = 1ULL;
v___y_1221_ = v___x_1230_;
goto v___jp_1220_;
}
v___jp_1220_:
{
if (v___x_1219_ == 0)
{
uint64_t v___x_1222_; uint8_t v___x_1223_;
v___x_1222_ = 48ULL;
v___x_1223_ = lean_uint64_dec_lt(v_hrs_1216_, v___x_1222_);
if (v___x_1223_ == 0)
{
v___y_1165_ = v___y_1221_;
v___y_1166_ = v_days_1218_;
goto v___jp_1164_;
}
else
{
v___y_1165_ = v___y_1221_;
v___y_1166_ = v_hrs_1216_;
goto v___jp_1164_;
}
}
else
{
uint64_t v___x_1224_; uint8_t v___x_1225_;
v___x_1224_ = 1ULL;
v___x_1225_ = lean_uint64_dec_le(v___x_1224_, v_mins_1214_);
if (v___x_1225_ == 0)
{
v___y_1165_ = v___y_1221_;
v___y_1166_ = v___x_1224_;
goto v___jp_1164_;
}
else
{
v___y_1165_ = v___y_1221_;
v___y_1166_ = v_mins_1214_;
goto v___jp_1164_;
}
}
}
}
}
}
}
else
{
uint8_t v___x_1231_;
v___x_1231_ = lean_uint8_dec_le(v___x_1190_, v_claimKind_1149_);
if (v___x_1231_ == 0)
{
goto v___jp_1202_;
}
else
{
uint8_t v___x_1232_; uint8_t v___x_1233_;
v___x_1232_ = 4;
v___x_1233_ = lean_uint8_dec_le(v_claimKind_1149_, v___x_1232_);
if (v___x_1233_ == 0)
{
goto v___jp_1202_;
}
else
{
uint64_t v___x_1234_; uint64_t v___x_1235_; uint64_t v___x_1236_;
v___x_1234_ = lean_uint8_to_uint64(v_claimKind_1149_);
v___x_1235_ = 8ULL;
v___x_1236_ = lean_uint64_shift_left(v___x_1234_, v___x_1235_);
v___y_1198_ = v___x_1236_;
goto v___jp_1197_;
}
}
}
v___jp_1191_:
{
uint8_t v___x_1193_;
v___x_1193_ = lean_uint8_dec_eq(v_hasUtilization_1150_, v___x_1190_);
if (v___x_1193_ == 0)
{
v___y_1186_ = v___y_1192_;
goto v___jp_1185_;
}
else
{
uint8_t v___x_1194_; uint8_t v___x_1195_;
v___x_1194_ = 100;
v___x_1195_ = lean_uint8_dec_le(v_utilizationPct_1151_, v___x_1194_);
if (v___x_1195_ == 0)
{
v___y_1186_ = v___y_1192_;
goto v___jp_1185_;
}
else
{
uint64_t v___x_1196_;
v___x_1196_ = 65536ULL;
v___y_1178_ = v___y_1192_;
v___y_1179_ = v___x_1196_;
goto v___jp_1177_;
}
}
}
v___jp_1197_:
{
uint8_t v___x_1199_;
v___x_1199_ = lean_uint8_dec_eq(v_claimKind_1149_, v___x_1190_);
if (v___x_1199_ == 0)
{
uint8_t v___x_1200_; uint8_t v___x_1201_;
v___x_1200_ = 2;
v___x_1201_ = lean_uint8_dec_eq(v_claimKind_1149_, v___x_1200_);
if (v___x_1201_ == 0)
{
v___y_1186_ = v___y_1198_;
goto v___jp_1185_;
}
else
{
v___y_1192_ = v___y_1198_;
goto v___jp_1191_;
}
}
else
{
v___y_1192_ = v___y_1198_;
goto v___jp_1191_;
}
}
v___jp_1202_:
{
uint64_t v___x_1203_;
v___x_1203_ = 0ULL;
v___y_1198_ = v___x_1203_;
goto v___jp_1197_;
}
}
else
{
uint64_t v___x_1237_;
v___x_1237_ = 0ULL;
return v___x_1237_;
}
v___jp_1154_:
{
uint64_t v___x_1157_; uint64_t v___x_1158_; uint64_t v___x_1159_; uint64_t v___x_1160_; uint64_t v___x_1161_; uint64_t v___x_1162_; uint64_t v___x_1163_;
v___x_1157_ = 2ULL;
v___x_1158_ = 32ULL;
v___x_1159_ = lean_uint64_shift_left(v___y_1155_, v___x_1158_);
v___x_1160_ = lean_uint64_lor(v___x_1157_, v___x_1159_);
v___x_1161_ = 40ULL;
v___x_1162_ = lean_uint64_shift_left(v___y_1156_, v___x_1161_);
v___x_1163_ = lean_uint64_lor(v___x_1160_, v___x_1162_);
return v___x_1163_;
}
v___jp_1164_:
{
uint64_t v___x_1167_; uint8_t v___x_1168_;
v___x_1167_ = 16777215ULL;
v___x_1168_ = lean_uint64_dec_lt(v___x_1167_, v___y_1166_);
if (v___x_1168_ == 0)
{
v___y_1155_ = v___y_1165_;
v___y_1156_ = v___y_1166_;
goto v___jp_1154_;
}
else
{
v___y_1155_ = v___y_1165_;
v___y_1156_ = v___x_1167_;
goto v___jp_1154_;
}
}
v___jp_1169_:
{
uint64_t v___x_1173_; uint64_t v___x_1174_; uint64_t v___x_1175_; uint64_t v___x_1176_;
v___x_1173_ = 1ULL;
v___x_1174_ = lean_uint64_lor(v___x_1173_, v___y_1171_);
v___x_1175_ = lean_uint64_lor(v___x_1174_, v___y_1170_);
v___x_1176_ = lean_uint64_lor(v___x_1175_, v___y_1172_);
return v___x_1176_;
}
v___jp_1177_:
{
uint64_t v___x_1180_; uint8_t v___x_1181_;
v___x_1180_ = 0ULL;
v___x_1181_ = lean_uint64_dec_eq(v___y_1179_, v___x_1180_);
if (v___x_1181_ == 0)
{
uint64_t v___x_1182_; uint64_t v___x_1183_; uint64_t v___x_1184_;
v___x_1182_ = lean_uint8_to_uint64(v_utilizationPct_1151_);
v___x_1183_ = 24ULL;
v___x_1184_ = lean_uint64_shift_left(v___x_1182_, v___x_1183_);
v___y_1170_ = v___y_1179_;
v___y_1171_ = v___y_1178_;
v___y_1172_ = v___x_1184_;
goto v___jp_1169_;
}
else
{
v___y_1170_ = v___y_1179_;
v___y_1171_ = v___y_1178_;
v___y_1172_ = v___x_1180_;
goto v___jp_1169_;
}
}
v___jp_1185_:
{
uint64_t v___x_1187_;
v___x_1187_ = 0ULL;
v___y_1178_ = v___y_1186_;
v___y_1179_ = v___x_1187_;
goto v___jp_1177_;
}
}
}

LEAN_EXPORT uint64_t orb_relative_time_bucket(uint64_t v_elapsedSecs_1252_){
_start:
{
uint64_t v___y_1254_; uint64_t v___x_1259_; uint8_t v___x_1260_;
v___x_1259_ = 45ULL;
v___x_1260_ = lean_uint64_dec_lt(v_elapsedSecs_1252_, v___x_1259_);
if (v___x_1260_ == 0)
{
uint64_t v___x_1261_; uint8_t v___x_1262_;
v___x_1261_ = 3600ULL;
v___x_1262_ = lean_uint64_dec_lt(v_elapsedSecs_1252_, v___x_1261_);
if (v___x_1262_ == 0)
{
uint64_t v___x_1263_; uint8_t v___x_1264_;
v___x_1263_ = 86400ULL;
v___x_1264_ = lean_uint64_dec_lt(v_elapsedSecs_1252_, v___x_1263_);
if (v___x_1264_ == 0)
{
uint64_t v___x_1265_; uint8_t v___x_1266_;
v___x_1265_ = 604800ULL;
v___x_1266_ = lean_uint64_dec_lt(v_elapsedSecs_1252_, v___x_1265_);
if (v___x_1266_ == 0)
{
uint64_t v_wks_1267_; uint64_t v___x_1268_; uint8_t v___x_1269_;
v_wks_1267_ = lean_uint64_div(v_elapsedSecs_1252_, v___x_1265_);
v___x_1268_ = 4294967295ULL;
v___x_1269_ = lean_uint64_dec_lt(v___x_1268_, v_wks_1267_);
if (v___x_1269_ == 0)
{
v___y_1254_ = v_wks_1267_;
goto v___jp_1253_;
}
else
{
v___y_1254_ = v___x_1268_;
goto v___jp_1253_;
}
}
else
{
uint64_t v___x_1270_; uint64_t v___x_1271_; uint64_t v___x_1272_; uint64_t v___x_1273_; uint64_t v___x_1274_;
v___x_1270_ = 3ULL;
v___x_1271_ = lean_uint64_div(v_elapsedSecs_1252_, v___x_1263_);
v___x_1272_ = 8ULL;
v___x_1273_ = lean_uint64_shift_left(v___x_1271_, v___x_1272_);
v___x_1274_ = lean_uint64_lor(v___x_1270_, v___x_1273_);
return v___x_1274_;
}
}
else
{
uint64_t v___x_1275_; uint64_t v___x_1276_; uint64_t v___x_1277_; uint64_t v___x_1278_; uint64_t v___x_1279_;
v___x_1275_ = 2ULL;
v___x_1276_ = lean_uint64_div(v_elapsedSecs_1252_, v___x_1261_);
v___x_1277_ = 8ULL;
v___x_1278_ = lean_uint64_shift_left(v___x_1276_, v___x_1277_);
v___x_1279_ = lean_uint64_lor(v___x_1275_, v___x_1278_);
return v___x_1279_;
}
}
else
{
uint64_t v___x_1280_; uint64_t v_mins_1281_; uint64_t v___x_1282_; uint64_t v___y_1284_; uint8_t v___x_1288_;
v___x_1280_ = 60ULL;
v_mins_1281_ = lean_uint64_div(v_elapsedSecs_1252_, v___x_1280_);
v___x_1282_ = 1ULL;
v___x_1288_ = lean_uint64_dec_le(v___x_1282_, v_mins_1281_);
if (v___x_1288_ == 0)
{
v___y_1284_ = v___x_1282_;
goto v___jp_1283_;
}
else
{
v___y_1284_ = v_mins_1281_;
goto v___jp_1283_;
}
v___jp_1283_:
{
uint64_t v___x_1285_; uint64_t v___x_1286_; uint64_t v___x_1287_;
v___x_1285_ = 8ULL;
v___x_1286_ = lean_uint64_shift_left(v___y_1284_, v___x_1285_);
v___x_1287_ = lean_uint64_lor(v___x_1282_, v___x_1286_);
return v___x_1287_;
}
}
}
else
{
uint64_t v___x_1289_;
v___x_1289_ = 0ULL;
return v___x_1289_;
}
v___jp_1253_:
{
uint64_t v___x_1255_; uint64_t v___x_1256_; uint64_t v___x_1257_; uint64_t v___x_1258_;
v___x_1255_ = 4ULL;
v___x_1256_ = 8ULL;
v___x_1257_ = lean_uint64_shift_left(v___y_1254_, v___x_1256_);
v___x_1258_ = lean_uint64_lor(v___x_1255_, v___x_1257_);
return v___x_1258_;
}
}
}

LEAN_EXPORT uint64_t orb_transcript_patch_step(uint32_t v_stateLen_1306_, uint32_t v_stateSeq_1307_, uint8_t v_eventKind_1308_, uint32_t v_deltaLen_1309_){
_start:
{
uint64_t v___y_1311_; uint32_t v___y_1312_; uint32_t v___y_1318_; uint8_t v___x_1325_; uint8_t v___x_1326_;
v___x_1325_ = 2;
v___x_1326_ = lean_uint8_dec_le(v_eventKind_1308_, v___x_1325_);
if (v___x_1326_ == 0)
{
uint64_t v___x_1327_; uint64_t v___x_1328_; uint64_t v___x_1329_; uint64_t v___x_1330_; uint64_t v___x_1331_;
v___x_1327_ = lean_uint32_to_uint64(v_stateLen_1306_);
v___x_1328_ = lean_uint32_to_uint64(v_stateSeq_1307_);
v___x_1329_ = 32ULL;
v___x_1330_ = lean_uint64_shift_left(v___x_1328_, v___x_1329_);
v___x_1331_ = lean_uint64_lor(v___x_1327_, v___x_1330_);
return v___x_1331_;
}
else
{
uint8_t v___x_1332_;
v___x_1332_ = lean_uint8_dec_eq(v_eventKind_1308_, v___x_1325_);
if (v___x_1332_ == 0)
{
uint8_t v___x_1333_; uint8_t v___x_1334_;
v___x_1333_ = 1;
v___x_1334_ = lean_uint8_dec_eq(v_eventKind_1308_, v___x_1333_);
if (v___x_1334_ == 0)
{
uint32_t v___x_1335_; uint32_t v___x_1336_; uint8_t v___x_1337_;
v___x_1335_ = 4294967295;
v___x_1336_ = lean_uint32_sub(v___x_1335_, v_deltaLen_1309_);
v___x_1337_ = lean_uint32_dec_le(v_stateLen_1306_, v___x_1336_);
if (v___x_1337_ == 0)
{
v___y_1318_ = v___x_1335_;
goto v___jp_1317_;
}
else
{
uint32_t v___x_1338_;
v___x_1338_ = lean_uint32_add(v_stateLen_1306_, v_deltaLen_1309_);
v___y_1318_ = v___x_1338_;
goto v___jp_1317_;
}
}
else
{
uint32_t v___x_1339_; uint8_t v___x_1340_;
v___x_1339_ = 0;
v___x_1340_ = lean_uint32_dec_lt(v___x_1339_, v_deltaLen_1309_);
if (v___x_1340_ == 0)
{
v___y_1318_ = v_stateLen_1306_;
goto v___jp_1317_;
}
else
{
v___y_1318_ = v_deltaLen_1309_;
goto v___jp_1317_;
}
}
}
else
{
uint32_t v___x_1341_;
v___x_1341_ = 0;
v___y_1318_ = v___x_1341_;
goto v___jp_1317_;
}
}
v___jp_1310_:
{
uint64_t v___x_1313_; uint64_t v___x_1314_; uint64_t v___x_1315_; uint64_t v___x_1316_;
v___x_1313_ = lean_uint32_to_uint64(v___y_1312_);
v___x_1314_ = 32ULL;
v___x_1315_ = lean_uint64_shift_left(v___x_1313_, v___x_1314_);
v___x_1316_ = lean_uint64_lor(v___y_1311_, v___x_1315_);
return v___x_1316_;
}
v___jp_1317_:
{
uint64_t v___x_1319_; uint32_t v___x_1320_; uint8_t v___x_1321_;
v___x_1319_ = lean_uint32_to_uint64(v___y_1318_);
v___x_1320_ = 4294967294;
v___x_1321_ = lean_uint32_dec_le(v_stateSeq_1307_, v___x_1320_);
if (v___x_1321_ == 0)
{
uint32_t v___x_1322_;
v___x_1322_ = 4294967295;
v___y_1311_ = v___x_1319_;
v___y_1312_ = v___x_1322_;
goto v___jp_1310_;
}
else
{
uint32_t v___x_1323_; uint32_t v___x_1324_;
v___x_1323_ = 1;
v___x_1324_ = lean_uint32_add(v_stateSeq_1307_, v___x_1323_);
v___y_1311_ = v___x_1319_;
v___y_1312_ = v___x_1324_;
goto v___jp_1310_;
}
}
}
}

LEAN_EXPORT uint32_t orb_attribution_step(uint8_t v_principalKind_1463_, uint8_t v_claimedKind_1464_, uint8_t v_sameMission_1465_, uint8_t v_isDescendant_1466_){
_start:
{
uint8_t v___y_1468_; uint8_t v___y_1473_; uint8_t v___y_1477_; uint8_t v___y_1478_; uint8_t v___y_1481_; uint8_t v___x_1516_; uint8_t v___x_1517_;
v___x_1516_ = 6;
v___x_1517_ = lean_uint8_dec_le(v_principalKind_1463_, v___x_1516_);
if (v___x_1517_ == 0)
{
uint8_t v___x_1518_;
v___x_1518_ = 0;
v___y_1481_ = v___x_1518_;
goto v___jp_1480_;
}
else
{
v___y_1481_ = v_principalKind_1463_;
goto v___jp_1480_;
}
v___jp_1467_:
{
uint32_t v___x_1469_; uint32_t v___x_1470_; uint32_t v___x_1471_;
v___x_1469_ = lean_uint8_to_uint32(v___y_1468_);
v___x_1470_ = 256;
v___x_1471_ = lean_uint32_lor(v___x_1469_, v___x_1470_);
return v___x_1471_;
}
v___jp_1472_:
{
uint8_t v___x_1474_; uint8_t v___x_1475_;
v___x_1474_ = 0;
v___x_1475_ = lean_uint8_dec_eq(v_claimedKind_1464_, v___x_1474_);
if (v___x_1475_ == 0)
{
v___y_1468_ = v_claimedKind_1464_;
goto v___jp_1467_;
}
else
{
v___y_1468_ = v___y_1473_;
goto v___jp_1467_;
}
}
v___jp_1476_:
{
if (v___y_1478_ == 0)
{
uint32_t v___x_1479_;
v___x_1479_ = lean_uint8_to_uint32(v___y_1477_);
return v___x_1479_;
}
else
{
v___y_1473_ = v___y_1477_;
goto v___jp_1472_;
}
}
v___jp_1480_:
{
uint8_t v___x_1482_; uint8_t v___x_1483_;
v___x_1482_ = 0;
v___x_1483_ = lean_uint8_dec_eq(v_claimedKind_1464_, v___x_1482_);
if (v___x_1483_ == 0)
{
uint8_t v___x_1484_; uint8_t v___x_1485_;
v___x_1484_ = 5;
v___x_1485_ = lean_uint8_dec_eq(v___y_1481_, v___x_1484_);
if (v___x_1485_ == 0)
{
uint8_t v___x_1486_; uint8_t v___x_1487_;
v___x_1486_ = 1;
v___x_1487_ = lean_uint8_dec_eq(v___y_1481_, v___x_1486_);
if (v___x_1487_ == 0)
{
uint8_t v___x_1488_; uint8_t v___x_1489_;
v___x_1488_ = 2;
v___x_1489_ = lean_uint8_dec_eq(v___y_1481_, v___x_1488_);
if (v___x_1489_ == 0)
{
uint8_t v___x_1490_; uint8_t v___x_1491_;
v___x_1490_ = 3;
v___x_1491_ = lean_uint8_dec_eq(v___y_1481_, v___x_1490_);
if (v___x_1491_ == 0)
{
uint8_t v___x_1492_; uint8_t v___x_1493_;
v___x_1492_ = 4;
v___x_1493_ = lean_uint8_dec_eq(v___y_1481_, v___x_1492_);
if (v___x_1493_ == 0)
{
uint8_t v___x_1494_; uint8_t v___x_1495_;
v___x_1494_ = 6;
v___x_1495_ = lean_uint8_dec_eq(v___y_1481_, v___x_1494_);
if (v___x_1495_ == 0)
{
uint32_t v___x_1496_;
v___x_1496_ = lean_uint8_to_uint32(v___y_1481_);
return v___x_1496_;
}
else
{
uint8_t v___x_1497_;
v___x_1497_ = lean_uint8_dec_eq(v_claimedKind_1464_, v___x_1494_);
v___y_1477_ = v___y_1481_;
v___y_1478_ = v___x_1497_;
goto v___jp_1476_;
}
}
else
{
uint8_t v___x_1498_;
v___x_1498_ = lean_uint8_dec_eq(v_claimedKind_1464_, v___x_1492_);
v___y_1477_ = v___y_1481_;
v___y_1478_ = v___x_1498_;
goto v___jp_1476_;
}
}
else
{
uint8_t v___x_1499_;
v___x_1499_ = lean_uint8_dec_eq(v_claimedKind_1464_, v___x_1490_);
v___y_1477_ = v___y_1481_;
v___y_1478_ = v___x_1499_;
goto v___jp_1476_;
}
}
else
{
uint8_t v___x_1500_;
v___x_1500_ = lean_uint8_dec_eq(v_claimedKind_1464_, v___x_1486_);
if (v___x_1500_ == 0)
{
uint8_t v___x_1501_;
v___x_1501_ = lean_uint8_dec_eq(v_claimedKind_1464_, v___x_1488_);
if (v___x_1501_ == 0)
{
uint32_t v___x_1502_;
v___x_1502_ = lean_uint8_to_uint32(v___y_1481_);
return v___x_1502_;
}
else
{
uint8_t v___x_1503_;
v___x_1503_ = lean_uint8_dec_eq(v_isDescendant_1466_, v___x_1486_);
v___y_1477_ = v___y_1481_;
v___y_1478_ = v___x_1503_;
goto v___jp_1476_;
}
}
else
{
uint8_t v___x_1504_;
v___x_1504_ = lean_uint8_dec_eq(v_sameMission_1465_, v___x_1486_);
v___y_1477_ = v___y_1481_;
v___y_1478_ = v___x_1504_;
goto v___jp_1476_;
}
}
}
else
{
uint8_t v___x_1505_;
v___x_1505_ = lean_uint8_dec_eq(v_claimedKind_1464_, v___x_1486_);
if (v___x_1505_ == 0)
{
uint8_t v___x_1506_; uint8_t v___x_1507_;
v___x_1506_ = 2;
v___x_1507_ = lean_uint8_dec_eq(v_claimedKind_1464_, v___x_1506_);
if (v___x_1507_ == 0)
{
uint32_t v___x_1508_;
v___x_1508_ = lean_uint8_to_uint32(v___y_1481_);
return v___x_1508_;
}
else
{
uint8_t v___x_1509_;
v___x_1509_ = lean_uint8_dec_eq(v_isDescendant_1466_, v___x_1486_);
v___y_1477_ = v___y_1481_;
v___y_1478_ = v___x_1509_;
goto v___jp_1476_;
}
}
else
{
uint8_t v___x_1510_;
v___x_1510_ = lean_uint8_dec_eq(v_sameMission_1465_, v___x_1486_);
v___y_1477_ = v___y_1481_;
v___y_1478_ = v___x_1510_;
goto v___jp_1476_;
}
}
}
else
{
uint8_t v___x_1511_; uint8_t v___x_1512_;
v___x_1511_ = 1;
v___x_1512_ = lean_uint8_dec_eq(v_claimedKind_1464_, v___x_1511_);
if (v___x_1512_ == 0)
{
uint8_t v___x_1513_; uint8_t v___x_1514_;
v___x_1513_ = 2;
v___x_1514_ = lean_uint8_dec_eq(v_claimedKind_1464_, v___x_1513_);
if (v___x_1514_ == 0)
{
uint8_t v___x_1515_;
v___x_1515_ = lean_uint8_dec_eq(v_claimedKind_1464_, v___x_1484_);
v___y_1477_ = v___y_1481_;
v___y_1478_ = v___x_1515_;
goto v___jp_1476_;
}
else
{
v___y_1473_ = v___y_1481_;
goto v___jp_1472_;
}
}
else
{
v___y_1473_ = v___y_1481_;
goto v___jp_1472_;
}
}
}
else
{
v___y_1473_ = v___y_1481_;
goto v___jp_1472_;
}
}
}
}

LEAN_EXPORT uint8_t orb_schedule_step(uint8_t v_op_1588_, uint8_t v_known_1589_, uint8_t v_cancelled_1590_, uint8_t v_ownerTerminal_1591_, uint8_t v_authorized_1592_, uint8_t v_busy_1593_, uint64_t v_lastFired_1594_, uint64_t v_nextDue_1595_, uint64_t v_now_1596_){
_start:
{
uint8_t v___x_1597_; uint8_t v___x_1598_;
v___x_1597_ = 1;
v___x_1598_ = lean_uint8_dec_eq(v_authorized_1592_, v___x_1597_);
if (v___x_1598_ == 0)
{
uint8_t v___x_1599_;
v___x_1599_ = 0;
return v___x_1599_;
}
else
{
uint8_t v___x_1600_; uint8_t v___x_1601_;
v___x_1600_ = 0;
v___x_1601_ = lean_uint8_dec_eq(v_op_1588_, v___x_1600_);
if (v___x_1601_ == 0)
{
uint8_t v___x_1602_;
v___x_1602_ = lean_uint8_dec_eq(v_cancelled_1590_, v___x_1597_);
if (v___x_1602_ == 0)
{
uint8_t v___x_1603_;
v___x_1603_ = lean_uint8_dec_eq(v_ownerTerminal_1591_, v___x_1597_);
if (v___x_1603_ == 0)
{
uint8_t v___x_1604_;
v___x_1604_ = lean_uint64_dec_lt(v_lastFired_1594_, v_nextDue_1595_);
if (v___x_1604_ == 0)
{
uint8_t v___x_1605_;
v___x_1605_ = 4;
return v___x_1605_;
}
else
{
uint8_t v___x_1606_;
v___x_1606_ = lean_uint64_dec_le(v_nextDue_1595_, v_now_1596_);
if (v___x_1606_ == 0)
{
uint8_t v___x_1607_;
v___x_1607_ = 4;
return v___x_1607_;
}
else
{
uint8_t v___x_1608_;
v___x_1608_ = lean_uint8_dec_eq(v_busy_1593_, v___x_1597_);
if (v___x_1608_ == 0)
{
uint8_t v___x_1609_;
v___x_1609_ = 3;
return v___x_1609_;
}
else
{
uint8_t v___x_1610_;
v___x_1610_ = 4;
return v___x_1610_;
}
}
}
}
else
{
return v___x_1600_;
}
}
else
{
return v___x_1600_;
}
}
else
{
uint8_t v___x_1611_;
v___x_1611_ = lean_uint8_dec_eq(v_known_1589_, v___x_1597_);
if (v___x_1611_ == 0)
{
uint8_t v___x_1612_;
v___x_1612_ = lean_uint8_dec_eq(v_ownerTerminal_1591_, v___x_1597_);
if (v___x_1612_ == 0)
{
return v___x_1597_;
}
else
{
return v___x_1600_;
}
}
else
{
uint8_t v___x_1613_;
v___x_1613_ = 2;
return v___x_1613_;
}
}
}
}
}

LEAN_EXPORT uint64_t orb_stats_settle_step(uint64_t v_acc_1651_, uint64_t v_cost_1652_, uint8_t v_seen_1653_){
_start:
{
uint8_t v___x_1654_; uint8_t v___x_1655_;
v___x_1654_ = 1;
v___x_1655_ = lean_uint8_dec_eq(v_seen_1653_, v___x_1654_);
if (v___x_1655_ == 0)
{
uint64_t v___x_1656_; uint64_t v___x_1657_; uint8_t v___x_1658_;
v___x_1656_ = 18446744073709551615ULL;
v___x_1657_ = lean_uint64_sub(v___x_1656_, v_cost_1652_);
v___x_1658_ = lean_uint64_dec_le(v_acc_1651_, v___x_1657_);
if (v___x_1658_ == 0)
{
return v___x_1656_;
}
else
{
uint64_t v___x_1659_;
v___x_1659_ = lean_uint64_add(v_acc_1651_, v_cost_1652_);
return v___x_1659_;
}
}
else
{
return v_acc_1651_;
}
}
}

LEAN_EXPORT uint32_t orb_privilege_step(uint8_t v_sameOwner_1668_, uint8_t v_missionActive_1669_, uint8_t v_biometricSigned_1670_, uint8_t v_scopeRank_1671_, uint8_t v_maxGrantedScope_1672_, uint8_t v_bunkerState_1673_, uint8_t v_revoked_1674_, uint64_t v_nowEpoch_1675_, uint64_t v_grantExpiresAt_1676_, uint64_t v_sessionExpiresAt_1677_){
_start:
{
uint8_t v___x_1678_; uint8_t v___x_1679_;
v___x_1678_ = 0;
v___x_1679_ = lean_uint8_dec_eq(v_missionActive_1669_, v___x_1678_);
if (v___x_1679_ == 0)
{
uint8_t v___x_1680_; uint8_t v___x_1681_;
v___x_1680_ = 1;
v___x_1681_ = lean_uint8_dec_eq(v_revoked_1674_, v___x_1680_);
if (v___x_1681_ == 0)
{
uint8_t v___x_1682_;
v___x_1682_ = lean_uint8_dec_eq(v_bunkerState_1673_, v___x_1678_);
if (v___x_1682_ == 0)
{
uint32_t v___x_1683_;
v___x_1683_ = 65536;
return v___x_1683_;
}
else
{
uint8_t v___x_1684_;
v___x_1684_ = lean_uint64_dec_le(v_grantExpiresAt_1676_, v_nowEpoch_1675_);
if (v___x_1684_ == 0)
{
uint8_t v___x_1685_;
v___x_1685_ = lean_uint64_dec_le(v_sessionExpiresAt_1677_, v_nowEpoch_1675_);
if (v___x_1685_ == 0)
{
uint8_t v___x_1686_;
v___x_1686_ = lean_uint8_dec_eq(v_sameOwner_1668_, v___x_1680_);
if (v___x_1686_ == 0)
{
uint32_t v___x_1687_;
v___x_1687_ = 0;
return v___x_1687_;
}
else
{
uint8_t v___x_1688_;
v___x_1688_ = lean_uint8_dec_eq(v_biometricSigned_1670_, v___x_1680_);
if (v___x_1688_ == 0)
{
uint32_t v___x_1689_;
v___x_1689_ = 0;
return v___x_1689_;
}
else
{
uint8_t v___x_1690_;
v___x_1690_ = lean_uint8_dec_le(v_scopeRank_1671_, v_maxGrantedScope_1672_);
if (v___x_1690_ == 0)
{
uint32_t v___x_1691_;
v___x_1691_ = 0;
return v___x_1691_;
}
else
{
uint8_t v___x_1692_; uint8_t v___x_1693_;
v___x_1692_ = 2;
v___x_1693_ = lean_uint8_dec_lt(v_scopeRank_1671_, v___x_1692_);
if (v___x_1693_ == 0)
{
uint32_t v___x_1694_;
v___x_1694_ = 1;
return v___x_1694_;
}
else
{
uint32_t v___x_1695_;
v___x_1695_ = 257;
return v___x_1695_;
}
}
}
}
}
else
{
uint32_t v___x_1696_;
v___x_1696_ = 65536;
return v___x_1696_;
}
}
else
{
uint32_t v___x_1697_;
v___x_1697_ = 65536;
return v___x_1697_;
}
}
}
else
{
uint32_t v___x_1698_;
v___x_1698_ = 65536;
return v___x_1698_;
}
}
else
{
uint32_t v___x_1699_;
v___x_1699_ = 65536;
return v___x_1699_;
}
}
}

LEAN_EXPORT uint32_t orb_bunker_step(uint8_t v_currentState_1722_, uint8_t v_canaryTripped_1723_, uint8_t v_authFailureBurst_1724_, uint8_t v_manualTrigger_1725_, uint8_t v_biometricUnbunker_1726_){
_start:
{
uint8_t v___x_1727_; uint32_t v___y_1729_; uint8_t v___y_1730_; uint32_t v___y_1731_; uint8_t v___y_1737_; uint8_t v___y_1738_; uint8_t v___y_1744_; uint8_t v___x_1757_;
v___x_1727_ = 2;
v___x_1757_ = lean_uint8_dec_le(v_currentState_1722_, v___x_1727_);
if (v___x_1757_ == 0)
{
v___y_1744_ = v___x_1727_;
goto v___jp_1743_;
}
else
{
v___y_1744_ = v_currentState_1722_;
goto v___jp_1743_;
}
v___jp_1728_:
{
uint32_t v___x_1732_; uint8_t v___x_1733_;
v___x_1732_ = lean_uint32_lor(v___y_1729_, v___y_1731_);
v___x_1733_ = lean_uint8_dec_eq(v___y_1730_, v___x_1727_);
if (v___x_1733_ == 0)
{
return v___x_1732_;
}
else
{
uint32_t v___x_1734_; uint32_t v___x_1735_;
v___x_1734_ = 65536;
v___x_1735_ = lean_uint32_lor(v___x_1732_, v___x_1734_);
return v___x_1735_;
}
}
v___jp_1736_:
{
uint32_t v___x_1739_; uint8_t v___x_1740_;
v___x_1739_ = lean_uint8_to_uint32(v___y_1738_);
v___x_1740_ = lean_uint8_dec_le(v___y_1737_, v___y_1738_);
if (v___x_1740_ == 0)
{
uint32_t v___x_1741_;
v___x_1741_ = 0;
v___y_1729_ = v___x_1739_;
v___y_1730_ = v___y_1738_;
v___y_1731_ = v___x_1741_;
goto v___jp_1728_;
}
else
{
uint32_t v___x_1742_;
v___x_1742_ = 256;
v___y_1729_ = v___x_1739_;
v___y_1730_ = v___y_1738_;
v___y_1731_ = v___x_1742_;
goto v___jp_1728_;
}
}
v___jp_1743_:
{
uint8_t v___x_1745_; uint8_t v___x_1746_;
v___x_1745_ = 1;
v___x_1746_ = lean_uint8_dec_eq(v_canaryTripped_1723_, v___x_1745_);
if (v___x_1746_ == 0)
{
uint8_t v___x_1747_;
v___x_1747_ = lean_uint8_dec_eq(v_manualTrigger_1725_, v___x_1727_);
if (v___x_1747_ == 0)
{
uint8_t v___x_1748_;
v___x_1748_ = lean_uint8_dec_eq(v___y_1744_, v___x_1727_);
if (v___x_1748_ == 0)
{
uint8_t v___x_1749_;
v___x_1749_ = lean_uint8_dec_eq(v_authFailureBurst_1724_, v___x_1745_);
if (v___x_1749_ == 0)
{
uint8_t v___x_1750_;
v___x_1750_ = lean_uint8_dec_eq(v_manualTrigger_1725_, v___x_1745_);
if (v___x_1750_ == 0)
{
uint8_t v___x_1751_;
v___x_1751_ = lean_uint8_dec_eq(v___y_1744_, v___x_1745_);
if (v___x_1751_ == 0)
{
uint8_t v___x_1752_;
v___x_1752_ = 0;
v___y_1737_ = v___x_1745_;
v___y_1738_ = v___x_1752_;
goto v___jp_1736_;
}
else
{
uint8_t v___x_1753_;
v___x_1753_ = lean_uint8_dec_eq(v_biometricUnbunker_1726_, v___x_1745_);
if (v___x_1753_ == 0)
{
v___y_1737_ = v___x_1745_;
v___y_1738_ = v___x_1745_;
goto v___jp_1736_;
}
else
{
uint8_t v___x_1754_;
v___x_1754_ = 0;
v___y_1737_ = v___x_1745_;
v___y_1738_ = v___x_1754_;
goto v___jp_1736_;
}
}
}
else
{
v___y_1737_ = v___x_1745_;
v___y_1738_ = v___x_1745_;
goto v___jp_1736_;
}
}
else
{
v___y_1737_ = v___x_1745_;
v___y_1738_ = v___x_1745_;
goto v___jp_1736_;
}
}
else
{
uint8_t v___x_1755_;
v___x_1755_ = lean_uint8_dec_eq(v_biometricUnbunker_1726_, v___x_1745_);
if (v___x_1755_ == 0)
{
v___y_1737_ = v___x_1745_;
v___y_1738_ = v___x_1727_;
goto v___jp_1736_;
}
else
{
uint8_t v___x_1756_;
v___x_1756_ = 0;
v___y_1737_ = v___x_1745_;
v___y_1738_ = v___x_1756_;
goto v___jp_1736_;
}
}
}
else
{
v___y_1737_ = v___x_1745_;
v___y_1738_ = v___x_1727_;
goto v___jp_1736_;
}
}
else
{
v___y_1737_ = v___x_1745_;
v___y_1738_ = v___x_1727_;
goto v___jp_1736_;
}
}
}
}

LEAN_EXPORT uint8_t orb_deploy_gate_step(uint8_t v_isProdService_1770_, uint8_t v_serviceMatches_1771_, uint8_t v_callingOnSelf_1772_, uint8_t v_debounceOk_1773_, uint8_t v_forceFlag_1774_, uint8_t v_biometricApproved_1775_, uint8_t v_bunkerState_1776_, uint32_t v_liveWriters_1777_){
_start:
{
uint8_t v___x_1778_; uint8_t v___y_1780_; uint8_t v___x_1789_;
v___x_1778_ = 1;
v___x_1789_ = lean_uint8_dec_eq(v_serviceMatches_1771_, v___x_1778_);
if (v___x_1789_ == 0)
{
v___y_1780_ = v___x_1789_;
goto v___jp_1779_;
}
else
{
uint8_t v___x_1790_; uint8_t v___x_1791_;
v___x_1790_ = 0;
v___x_1791_ = lean_uint8_dec_eq(v_callingOnSelf_1772_, v___x_1790_);
if (v___x_1791_ == 0)
{
v___y_1780_ = v___x_1791_;
goto v___jp_1779_;
}
else
{
uint8_t v___x_1792_;
v___x_1792_ = lean_uint8_dec_eq(v_debounceOk_1773_, v___x_1778_);
if (v___x_1792_ == 0)
{
v___y_1780_ = v___x_1792_;
goto v___jp_1779_;
}
else
{
uint32_t v___x_1793_; uint8_t v___x_1794_;
v___x_1793_ = 0;
v___x_1794_ = lean_uint32_dec_eq(v_liveWriters_1777_, v___x_1793_);
if (v___x_1794_ == 0)
{
uint8_t v___x_1795_;
v___x_1795_ = lean_uint8_dec_eq(v_forceFlag_1774_, v___x_1778_);
if (v___x_1795_ == 0)
{
v___y_1780_ = v___x_1795_;
goto v___jp_1779_;
}
else
{
goto v___jp_1786_;
}
}
else
{
goto v___jp_1786_;
}
}
}
}
v___jp_1779_:
{
uint8_t v___x_1781_;
v___x_1781_ = lean_uint8_dec_eq(v_isProdService_1770_, v___x_1778_);
if (v___x_1781_ == 0)
{
if (v___y_1780_ == 0)
{
uint8_t v___x_1782_;
v___x_1782_ = 0;
return v___x_1782_;
}
else
{
return v___x_1778_;
}
}
else
{
if (v___y_1780_ == 0)
{
uint8_t v___x_1783_;
v___x_1783_ = 0;
return v___x_1783_;
}
else
{
uint8_t v___x_1784_;
v___x_1784_ = lean_uint8_dec_eq(v_biometricApproved_1775_, v___x_1778_);
if (v___x_1784_ == 0)
{
uint8_t v___x_1785_;
v___x_1785_ = 0;
return v___x_1785_;
}
else
{
return v___x_1778_;
}
}
}
}
v___jp_1786_:
{
uint8_t v___x_1787_; uint8_t v___x_1788_;
v___x_1787_ = 0;
v___x_1788_ = lean_uint8_dec_eq(v_bunkerState_1776_, v___x_1787_);
v___y_1780_ = v___x_1788_;
goto v___jp_1779_;
}
}
}

LEAN_EXPORT uint64_t orb_scroll_max_top(uint64_t v_content_1814_, uint64_t v_viewport_1815_){
_start:
{
uint8_t v___x_1816_;
v___x_1816_ = lean_uint64_dec_le(v_viewport_1815_, v_content_1814_);
if (v___x_1816_ == 0)
{
uint64_t v___x_1817_;
v___x_1817_ = 0ULL;
return v___x_1817_;
}
else
{
uint64_t v___x_1818_;
v___x_1818_ = lean_uint64_sub(v_content_1814_, v_viewport_1815_);
return v___x_1818_;
}
}
}

LEAN_EXPORT uint64_t orb_scroll_clamp_top(uint64_t v_content_1825_, uint64_t v_viewport_1826_, uint64_t v_top_1827_){
_start:
{
uint64_t v___y_1829_; uint8_t v___x_1831_;
v___x_1831_ = lean_uint64_dec_le(v_viewport_1826_, v_content_1825_);
if (v___x_1831_ == 0)
{
uint64_t v___x_1832_;
v___x_1832_ = 0ULL;
v___y_1829_ = v___x_1832_;
goto v___jp_1828_;
}
else
{
uint64_t v___x_1833_;
v___x_1833_ = lean_uint64_sub(v_content_1825_, v_viewport_1826_);
v___y_1829_ = v___x_1833_;
goto v___jp_1828_;
}
v___jp_1828_:
{
uint8_t v___x_1830_;
v___x_1830_ = lean_uint64_dec_le(v_top_1827_, v___y_1829_);
if (v___x_1830_ == 0)
{
return v___y_1829_;
}
else
{
return v_top_1827_;
}
}
}
}

LEAN_EXPORT uint64_t orb_scroll_gap(uint64_t v_content_1842_, uint64_t v_viewport_1843_, uint64_t v_top_1844_){
_start:
{
uint64_t v___y_1846_; uint64_t v___y_1847_; uint64_t v___y_1852_; uint64_t v___y_1853_; uint64_t v___y_1856_; uint8_t v___x_1860_;
v___x_1860_ = lean_uint64_dec_le(v_viewport_1843_, v_content_1842_);
if (v___x_1860_ == 0)
{
uint64_t v___x_1861_;
v___x_1861_ = 0ULL;
v___y_1856_ = v___x_1861_;
goto v___jp_1855_;
}
else
{
uint64_t v___x_1862_;
v___x_1862_ = lean_uint64_sub(v_content_1842_, v_viewport_1843_);
v___y_1856_ = v___x_1862_;
goto v___jp_1855_;
}
v___jp_1845_:
{
uint8_t v___x_1848_;
v___x_1848_ = lean_uint64_dec_le(v___y_1847_, v___y_1846_);
if (v___x_1848_ == 0)
{
uint64_t v___x_1849_;
v___x_1849_ = 0ULL;
return v___x_1849_;
}
else
{
uint64_t v___x_1850_;
v___x_1850_ = lean_uint64_sub(v___y_1846_, v___y_1847_);
return v___x_1850_;
}
}
v___jp_1851_:
{
uint8_t v___x_1854_;
v___x_1854_ = lean_uint64_dec_le(v_top_1844_, v___y_1853_);
if (v___x_1854_ == 0)
{
v___y_1846_ = v___y_1852_;
v___y_1847_ = v___y_1853_;
goto v___jp_1845_;
}
else
{
v___y_1846_ = v___y_1852_;
v___y_1847_ = v_top_1844_;
goto v___jp_1845_;
}
}
v___jp_1855_:
{
uint8_t v___x_1857_;
v___x_1857_ = lean_uint64_dec_le(v_viewport_1843_, v_content_1842_);
if (v___x_1857_ == 0)
{
uint64_t v___x_1858_;
v___x_1858_ = 0ULL;
v___y_1852_ = v___y_1856_;
v___y_1853_ = v___x_1858_;
goto v___jp_1851_;
}
else
{
uint64_t v___x_1859_;
v___x_1859_ = lean_uint64_sub(v_content_1842_, v_viewport_1843_);
v___y_1852_ = v___y_1856_;
v___y_1853_ = v___x_1859_;
goto v___jp_1851_;
}
}
}
}

LEAN_EXPORT uint64_t orb_scroll_layout_step(uint8_t v_pinned_1871_, uint64_t v_content_1872_, uint64_t v_viewport_1873_, uint64_t v_top_1874_){
_start:
{
uint64_t v___y_1876_; uint8_t v___x_1878_; uint8_t v___x_1879_;
v___x_1878_ = 1;
v___x_1879_ = lean_uint8_dec_eq(v_pinned_1871_, v___x_1878_);
if (v___x_1879_ == 0)
{
uint8_t v___x_1880_;
v___x_1880_ = lean_uint64_dec_le(v_viewport_1873_, v_content_1872_);
if (v___x_1880_ == 0)
{
uint64_t v___x_1881_;
v___x_1881_ = 0ULL;
v___y_1876_ = v___x_1881_;
goto v___jp_1875_;
}
else
{
uint64_t v___x_1882_;
v___x_1882_ = lean_uint64_sub(v_content_1872_, v_viewport_1873_);
v___y_1876_ = v___x_1882_;
goto v___jp_1875_;
}
}
else
{
uint8_t v___x_1883_;
v___x_1883_ = lean_uint64_dec_le(v_viewport_1873_, v_content_1872_);
if (v___x_1883_ == 0)
{
uint64_t v___x_1884_;
v___x_1884_ = 0ULL;
return v___x_1884_;
}
else
{
uint64_t v___x_1885_;
v___x_1885_ = lean_uint64_sub(v_content_1872_, v_viewport_1873_);
return v___x_1885_;
}
}
v___jp_1875_:
{
uint8_t v___x_1877_;
v___x_1877_ = lean_uint64_dec_le(v_top_1874_, v___y_1876_);
if (v___x_1877_ == 0)
{
return v___y_1876_;
}
else
{
return v_top_1874_;
}
}
}
}

LEAN_EXPORT uint8_t orb_scroll_user_step(uint64_t v_content_1896_, uint64_t v_viewport_1897_, uint64_t v_top_1898_, uint64_t v_threshold_1899_){
_start:
{
uint64_t v___y_1901_; uint64_t v___y_1906_; uint64_t v___y_1907_; uint64_t v___y_1912_; uint64_t v___y_1913_; uint64_t v___y_1916_; uint8_t v___x_1920_;
v___x_1920_ = lean_uint64_dec_le(v_viewport_1897_, v_content_1896_);
if (v___x_1920_ == 0)
{
uint64_t v___x_1921_;
v___x_1921_ = 0ULL;
v___y_1916_ = v___x_1921_;
goto v___jp_1915_;
}
else
{
uint64_t v___x_1922_;
v___x_1922_ = lean_uint64_sub(v_content_1896_, v_viewport_1897_);
v___y_1916_ = v___x_1922_;
goto v___jp_1915_;
}
v___jp_1900_:
{
uint8_t v___x_1902_;
v___x_1902_ = lean_uint64_dec_le(v___y_1901_, v_threshold_1899_);
if (v___x_1902_ == 0)
{
uint8_t v___x_1903_;
v___x_1903_ = 0;
return v___x_1903_;
}
else
{
uint8_t v___x_1904_;
v___x_1904_ = 1;
return v___x_1904_;
}
}
v___jp_1905_:
{
uint8_t v___x_1908_;
v___x_1908_ = lean_uint64_dec_le(v___y_1907_, v___y_1906_);
if (v___x_1908_ == 0)
{
uint64_t v___x_1909_;
v___x_1909_ = 0ULL;
v___y_1901_ = v___x_1909_;
goto v___jp_1900_;
}
else
{
uint64_t v___x_1910_;
v___x_1910_ = lean_uint64_sub(v___y_1906_, v___y_1907_);
v___y_1901_ = v___x_1910_;
goto v___jp_1900_;
}
}
v___jp_1911_:
{
uint8_t v___x_1914_;
v___x_1914_ = lean_uint64_dec_le(v_top_1898_, v___y_1913_);
if (v___x_1914_ == 0)
{
v___y_1906_ = v___y_1912_;
v___y_1907_ = v___y_1913_;
goto v___jp_1905_;
}
else
{
v___y_1906_ = v___y_1912_;
v___y_1907_ = v_top_1898_;
goto v___jp_1905_;
}
}
v___jp_1915_:
{
uint8_t v___x_1917_;
v___x_1917_ = lean_uint64_dec_le(v_viewport_1897_, v_content_1896_);
if (v___x_1917_ == 0)
{
uint64_t v___x_1918_;
v___x_1918_ = 0ULL;
v___y_1912_ = v___y_1916_;
v___y_1913_ = v___x_1918_;
goto v___jp_1911_;
}
else
{
uint64_t v___x_1919_;
v___x_1919_ = lean_uint64_sub(v_content_1896_, v_viewport_1897_);
v___y_1912_ = v___y_1916_;
v___y_1913_ = v___x_1919_;
goto v___jp_1911_;
}
}
}
}

LEAN_EXPORT uint64_t orb_scroll_jump_step(uint64_t v_content_1933_, uint64_t v_viewport_1934_){
_start:
{
uint8_t v___x_1935_;
v___x_1935_ = lean_uint64_dec_le(v_viewport_1934_, v_content_1933_);
if (v___x_1935_ == 0)
{
uint64_t v___x_1936_;
v___x_1936_ = 0ULL;
return v___x_1936_;
}
else
{
uint64_t v___x_1937_;
v___x_1937_ = lean_uint64_sub(v_content_1933_, v_viewport_1934_);
return v___x_1937_;
}
}
}

LEAN_EXPORT uint64_t orb_scroll_correct(uint8_t v_pinned_1944_, uint64_t v_content_1945_, uint64_t v_viewport_1946_, uint64_t v_top_1947_){
_start:
{
uint64_t v___y_1949_; uint8_t v___x_1951_; uint8_t v___x_1952_;
v___x_1951_ = 1;
v___x_1952_ = lean_uint8_dec_eq(v_pinned_1944_, v___x_1951_);
if (v___x_1952_ == 0)
{
uint8_t v___x_1953_;
v___x_1953_ = lean_uint64_dec_le(v_viewport_1946_, v_content_1945_);
if (v___x_1953_ == 0)
{
uint64_t v___x_1954_;
v___x_1954_ = 0ULL;
v___y_1949_ = v___x_1954_;
goto v___jp_1948_;
}
else
{
uint64_t v___x_1955_;
v___x_1955_ = lean_uint64_sub(v_content_1945_, v_viewport_1946_);
v___y_1949_ = v___x_1955_;
goto v___jp_1948_;
}
}
else
{
uint8_t v___x_1956_;
v___x_1956_ = lean_uint64_dec_le(v_viewport_1946_, v_content_1945_);
if (v___x_1956_ == 0)
{
uint64_t v___x_1957_;
v___x_1957_ = 0ULL;
return v___x_1957_;
}
else
{
uint64_t v___x_1958_;
v___x_1958_ = lean_uint64_sub(v_content_1945_, v_viewport_1946_);
return v___x_1958_;
}
}
v___jp_1948_:
{
uint8_t v___x_1950_;
v___x_1950_ = lean_uint64_dec_le(v_top_1947_, v___y_1949_);
if (v___x_1950_ == 0)
{
return v___y_1949_;
}
else
{
return v_top_1947_;
}
}
}
}

LEAN_EXPORT uint8_t orb_scroll_shows_jump(uint8_t v_pinned_1969_, uint64_t v_content_1970_, uint64_t v_viewport_1971_, uint64_t v_top_1972_, uint64_t v_pillThreshold_1973_){
_start:
{
uint8_t v___x_1974_; uint64_t v___y_1976_; uint64_t v___y_1980_; uint64_t v___y_1981_; uint64_t v___y_1986_; uint64_t v___y_1987_; uint64_t v___y_1990_; uint8_t v___x_1994_;
v___x_1974_ = 0;
v___x_1994_ = lean_uint8_dec_eq(v_pinned_1969_, v___x_1974_);
if (v___x_1994_ == 0)
{
return v___x_1974_;
}
else
{
uint64_t v___x_1995_; uint8_t v___x_1996_;
v___x_1995_ = 18446744073709551591ULL;
v___x_1996_ = lean_uint64_dec_le(v_viewport_1971_, v___x_1995_);
if (v___x_1996_ == 0)
{
return v___x_1974_;
}
else
{
uint64_t v___x_1997_; uint64_t v___x_1998_; uint8_t v___x_1999_;
v___x_1997_ = 24ULL;
v___x_1998_ = lean_uint64_add(v_viewport_1971_, v___x_1997_);
v___x_1999_ = lean_uint64_dec_lt(v___x_1998_, v_content_1970_);
if (v___x_1999_ == 0)
{
return v___x_1974_;
}
else
{
uint8_t v___x_2000_;
v___x_2000_ = lean_uint64_dec_le(v_viewport_1971_, v_content_1970_);
if (v___x_2000_ == 0)
{
uint64_t v___x_2001_;
v___x_2001_ = 0ULL;
v___y_1990_ = v___x_2001_;
goto v___jp_1989_;
}
else
{
uint64_t v___x_2002_;
v___x_2002_ = lean_uint64_sub(v_content_1970_, v_viewport_1971_);
v___y_1990_ = v___x_2002_;
goto v___jp_1989_;
}
}
}
}
v___jp_1975_:
{
uint8_t v___x_1977_;
v___x_1977_ = lean_uint64_dec_lt(v_pillThreshold_1973_, v___y_1976_);
if (v___x_1977_ == 0)
{
return v___x_1974_;
}
else
{
uint8_t v___x_1978_;
v___x_1978_ = 1;
return v___x_1978_;
}
}
v___jp_1979_:
{
uint8_t v___x_1982_;
v___x_1982_ = lean_uint64_dec_le(v___y_1981_, v___y_1980_);
if (v___x_1982_ == 0)
{
uint64_t v___x_1983_;
v___x_1983_ = 0ULL;
v___y_1976_ = v___x_1983_;
goto v___jp_1975_;
}
else
{
uint64_t v___x_1984_;
v___x_1984_ = lean_uint64_sub(v___y_1980_, v___y_1981_);
v___y_1976_ = v___x_1984_;
goto v___jp_1975_;
}
}
v___jp_1985_:
{
uint8_t v___x_1988_;
v___x_1988_ = lean_uint64_dec_le(v_top_1972_, v___y_1987_);
if (v___x_1988_ == 0)
{
v___y_1980_ = v___y_1986_;
v___y_1981_ = v___y_1987_;
goto v___jp_1979_;
}
else
{
v___y_1980_ = v___y_1986_;
v___y_1981_ = v_top_1972_;
goto v___jp_1979_;
}
}
v___jp_1989_:
{
uint8_t v___x_1991_;
v___x_1991_ = lean_uint64_dec_le(v_viewport_1971_, v_content_1970_);
if (v___x_1991_ == 0)
{
uint64_t v___x_1992_;
v___x_1992_ = 0ULL;
v___y_1986_ = v___y_1990_;
v___y_1987_ = v___x_1992_;
goto v___jp_1985_;
}
else
{
uint64_t v___x_1993_;
v___x_1993_ = lean_uint64_sub(v_content_1970_, v_viewport_1971_);
v___y_1986_ = v___y_1990_;
v___y_1987_ = v___x_1993_;
goto v___jp_1985_;
}
}
}
}

LEAN_EXPORT uint64_t orb_stream_coalescer_step(uint8_t v_op_2015_, uint32_t v_shownLen_2016_, uint32_t v_pendingLen_2017_, uint32_t v_deltaLen_2018_){
_start:
{
uint32_t v___y_2020_; uint32_t v___y_2025_; uint8_t v___x_2033_; uint8_t v___x_2034_;
v___x_2033_ = 0;
v___x_2034_ = lean_uint8_dec_eq(v_op_2015_, v___x_2033_);
if (v___x_2034_ == 0)
{
uint8_t v___x_2035_; uint8_t v___x_2036_;
v___x_2035_ = 1;
v___x_2036_ = lean_uint8_dec_eq(v_op_2015_, v___x_2035_);
if (v___x_2036_ == 0)
{
uint64_t v___x_2037_;
v___x_2037_ = 0ULL;
return v___x_2037_;
}
else
{
uint32_t v___x_2038_; uint8_t v___x_2039_;
v___x_2038_ = 0;
v___x_2039_ = lean_uint32_dec_eq(v_pendingLen_2017_, v___x_2038_);
if (v___x_2039_ == 0)
{
uint32_t v___x_2040_; uint32_t v___x_2041_; uint8_t v___x_2042_;
v___x_2040_ = 4294967295;
v___x_2041_ = lean_uint32_sub(v___x_2040_, v_pendingLen_2017_);
v___x_2042_ = lean_uint32_dec_le(v_shownLen_2016_, v___x_2041_);
if (v___x_2042_ == 0)
{
v___y_2020_ = v___x_2040_;
goto v___jp_2019_;
}
else
{
uint32_t v___x_2043_;
v___x_2043_ = lean_uint32_add(v_shownLen_2016_, v_pendingLen_2017_);
v___y_2020_ = v___x_2043_;
goto v___jp_2019_;
}
}
else
{
uint64_t v___x_2044_;
v___x_2044_ = lean_uint32_to_uint64(v_shownLen_2016_);
return v___x_2044_;
}
}
}
else
{
uint32_t v___x_2045_; uint32_t v___x_2046_; uint8_t v___x_2047_;
v___x_2045_ = 4294967295;
v___x_2046_ = lean_uint32_sub(v___x_2045_, v_deltaLen_2018_);
v___x_2047_ = lean_uint32_dec_le(v_pendingLen_2017_, v___x_2046_);
if (v___x_2047_ == 0)
{
v___y_2025_ = v___x_2045_;
goto v___jp_2024_;
}
else
{
uint32_t v___x_2048_;
v___x_2048_ = lean_uint32_add(v_pendingLen_2017_, v_deltaLen_2018_);
v___y_2025_ = v___x_2048_;
goto v___jp_2024_;
}
}
v___jp_2019_:
{
uint64_t v___x_2021_; uint64_t v___x_2022_; uint64_t v___x_2023_;
v___x_2021_ = lean_uint32_to_uint64(v___y_2020_);
v___x_2022_ = 9223372036854775808ULL;
v___x_2023_ = lean_uint64_lor(v___x_2021_, v___x_2022_);
return v___x_2023_;
}
v___jp_2024_:
{
uint64_t v___x_2026_; uint64_t v___x_2027_; uint64_t v___x_2028_; uint64_t v___x_2029_; uint64_t v___x_2030_; uint64_t v___x_2031_; uint64_t v___x_2032_;
v___x_2026_ = lean_uint32_to_uint64(v_shownLen_2016_);
v___x_2027_ = lean_uint32_to_uint64(v___y_2025_);
v___x_2028_ = 2147483647ULL;
v___x_2029_ = lean_uint64_land(v___x_2027_, v___x_2028_);
v___x_2030_ = 32ULL;
v___x_2031_ = lean_uint64_shift_left(v___x_2029_, v___x_2030_);
v___x_2032_ = lean_uint64_lor(v___x_2026_, v___x_2031_);
return v___x_2032_;
}
}
}

LEAN_EXPORT uint64_t orb_stream_fence_step(uint8_t v_openKind_2116_, uint32_t v_openCount_2117_, uint8_t v_markerKind_2118_, uint32_t v_markerCount_2119_){
_start:
{
uint8_t v___y_2121_; uint32_t v___y_2122_; uint8_t v___y_2129_; uint8_t v___y_2134_; uint8_t v___x_2147_; uint8_t v___x_2151_;
v___x_2147_ = 0;
v___x_2151_ = lean_uint8_dec_eq(v_openKind_2116_, v___x_2147_);
if (v___x_2151_ == 0)
{
uint8_t v___x_2152_;
v___x_2152_ = lean_uint8_dec_eq(v_markerKind_2118_, v_openKind_2116_);
if (v___x_2152_ == 0)
{
v___y_2134_ = v_openKind_2116_;
goto v___jp_2133_;
}
else
{
uint8_t v___x_2153_;
v___x_2153_ = lean_uint32_dec_le(v_openCount_2117_, v_markerCount_2119_);
if (v___x_2153_ == 0)
{
v___y_2134_ = v_openKind_2116_;
goto v___jp_2133_;
}
else
{
uint32_t v___x_2154_; uint8_t v___x_2155_;
v___x_2154_ = 3;
v___x_2155_ = lean_uint32_dec_le(v___x_2154_, v_markerCount_2119_);
if (v___x_2155_ == 0)
{
v___y_2134_ = v_openKind_2116_;
goto v___jp_2133_;
}
else
{
v___y_2134_ = v___x_2147_;
goto v___jp_2133_;
}
}
}
}
else
{
uint8_t v___x_2156_; uint8_t v___x_2157_;
v___x_2156_ = 1;
v___x_2157_ = lean_uint8_dec_eq(v_markerKind_2118_, v___x_2156_);
if (v___x_2157_ == 0)
{
uint8_t v___x_2158_; uint8_t v___x_2159_;
v___x_2158_ = 2;
v___x_2159_ = lean_uint8_dec_eq(v_markerKind_2118_, v___x_2158_);
if (v___x_2159_ == 0)
{
v___y_2134_ = v___x_2147_;
goto v___jp_2133_;
}
else
{
goto v___jp_2148_;
}
}
else
{
goto v___jp_2148_;
}
}
v___jp_2120_:
{
uint64_t v___x_2123_; uint64_t v___x_2124_; uint64_t v___x_2125_; uint64_t v___x_2126_; uint64_t v___x_2127_;
v___x_2123_ = lean_uint8_to_uint64(v___y_2121_);
v___x_2124_ = lean_uint32_to_uint64(v___y_2122_);
v___x_2125_ = 32ULL;
v___x_2126_ = lean_uint64_shift_left(v___x_2124_, v___x_2125_);
v___x_2127_ = lean_uint64_lor(v___x_2123_, v___x_2126_);
return v___x_2127_;
}
v___jp_2128_:
{
uint32_t v___x_2130_; uint8_t v___x_2131_;
v___x_2130_ = 3;
v___x_2131_ = lean_uint32_dec_le(v___x_2130_, v_markerCount_2119_);
if (v___x_2131_ == 0)
{
uint32_t v___x_2132_;
v___x_2132_ = 0;
v___y_2121_ = v___y_2129_;
v___y_2122_ = v___x_2132_;
goto v___jp_2120_;
}
else
{
v___y_2121_ = v___y_2129_;
v___y_2122_ = v_markerCount_2119_;
goto v___jp_2120_;
}
}
v___jp_2133_:
{
uint8_t v___x_2135_; uint8_t v___x_2136_;
v___x_2135_ = 0;
v___x_2136_ = lean_uint8_dec_eq(v_openKind_2116_, v___x_2135_);
if (v___x_2136_ == 0)
{
uint8_t v___x_2137_;
v___x_2137_ = lean_uint8_dec_eq(v_markerKind_2118_, v_openKind_2116_);
if (v___x_2137_ == 0)
{
v___y_2121_ = v___y_2134_;
v___y_2122_ = v_openCount_2117_;
goto v___jp_2120_;
}
else
{
uint8_t v___x_2138_;
v___x_2138_ = lean_uint32_dec_le(v_openCount_2117_, v_markerCount_2119_);
if (v___x_2138_ == 0)
{
v___y_2121_ = v___y_2134_;
v___y_2122_ = v_openCount_2117_;
goto v___jp_2120_;
}
else
{
uint32_t v___x_2139_; uint8_t v___x_2140_;
v___x_2139_ = 3;
v___x_2140_ = lean_uint32_dec_le(v___x_2139_, v_markerCount_2119_);
if (v___x_2140_ == 0)
{
v___y_2121_ = v___y_2134_;
v___y_2122_ = v_openCount_2117_;
goto v___jp_2120_;
}
else
{
uint32_t v___x_2141_;
v___x_2141_ = 0;
v___y_2121_ = v___y_2134_;
v___y_2122_ = v___x_2141_;
goto v___jp_2120_;
}
}
}
}
else
{
uint8_t v___x_2142_; uint8_t v___x_2143_;
v___x_2142_ = 1;
v___x_2143_ = lean_uint8_dec_eq(v_markerKind_2118_, v___x_2142_);
if (v___x_2143_ == 0)
{
uint8_t v___x_2144_; uint8_t v___x_2145_;
v___x_2144_ = 2;
v___x_2145_ = lean_uint8_dec_eq(v_markerKind_2118_, v___x_2144_);
if (v___x_2145_ == 0)
{
uint32_t v___x_2146_;
v___x_2146_ = 0;
v___y_2121_ = v___y_2134_;
v___y_2122_ = v___x_2146_;
goto v___jp_2120_;
}
else
{
v___y_2129_ = v___y_2134_;
goto v___jp_2128_;
}
}
else
{
v___y_2129_ = v___y_2134_;
goto v___jp_2128_;
}
}
}
v___jp_2148_:
{
uint32_t v___x_2149_; uint8_t v___x_2150_;
v___x_2149_ = 3;
v___x_2150_ = lean_uint32_dec_le(v___x_2149_, v_markerCount_2119_);
if (v___x_2150_ == 0)
{
v___y_2134_ = v___x_2147_;
goto v___jp_2133_;
}
else
{
v___y_2134_ = v_markerKind_2118_;
goto v___jp_2133_;
}
}
}
}

LEAN_EXPORT uint64_t orb_stream_commit_step(uint8_t v_tick_2170_, uint8_t v_openKind_2171_, uint32_t v_openCount_2172_, uint8_t v_lineBlank_2173_, uint8_t v_lineTick_2174_, uint8_t v_markerKind_2175_, uint32_t v_markerCount_2176_, uint32_t v_pos_2177_, uint32_t v_commit_2178_){
_start:
{
uint8_t v___y_2180_; uint32_t v___y_2181_; uint32_t v___y_2182_; uint32_t v___y_2183_; uint8_t v___y_2193_; uint8_t v___y_2194_; uint32_t v___y_2195_; uint32_t v___y_2196_; uint8_t v___x_2199_; uint8_t v___y_2201_; uint8_t v___y_2202_; uint8_t v___y_2203_; uint32_t v___y_2204_; uint8_t v___y_2212_; uint32_t v___y_2213_; uint8_t v___y_2214_; uint8_t v___y_2215_; uint8_t v___y_2218_; uint32_t v___y_2219_; uint8_t v___y_2220_; uint8_t v___y_2223_; uint8_t v___y_2224_; uint32_t v___y_2225_; uint8_t v___y_2231_; uint8_t v___y_2232_; uint8_t v___y_2239_; uint8_t v___y_2240_; uint8_t v___y_2244_; uint8_t v___x_2254_;
v___x_2199_ = 1;
v___x_2254_ = lean_uint8_dec_eq(v_lineTick_2174_, v___x_2199_);
if (v___x_2254_ == 0)
{
uint8_t v___x_2255_;
v___x_2255_ = lean_uint8_dec_eq(v_tick_2170_, v___x_2199_);
if (v___x_2255_ == 0)
{
uint8_t v___x_2256_;
v___x_2256_ = 0;
v___y_2244_ = v___x_2256_;
goto v___jp_2243_;
}
else
{
v___y_2244_ = v___x_2199_;
goto v___jp_2243_;
}
}
else
{
uint8_t v___x_2257_;
v___x_2257_ = lean_uint8_dec_eq(v_tick_2170_, v___x_2199_);
if (v___x_2257_ == 0)
{
v___y_2244_ = v___x_2199_;
goto v___jp_2243_;
}
else
{
uint8_t v___x_2258_;
v___x_2258_ = 0;
v___y_2244_ = v___x_2258_;
goto v___jp_2243_;
}
}
v___jp_2179_:
{
uint32_t v___x_2184_; uint32_t v___x_2185_; uint32_t v_lo32_2186_; uint64_t v___x_2187_; uint64_t v___x_2188_; uint64_t v___x_2189_; uint64_t v___x_2190_; uint64_t v___x_2191_;
v___x_2184_ = lean_uint8_to_uint32(v___y_2180_);
v___x_2185_ = lean_uint32_lor(v___x_2184_, v___y_2181_);
v_lo32_2186_ = lean_uint32_lor(v___x_2185_, v___y_2183_);
v___x_2187_ = lean_uint32_to_uint64(v_lo32_2186_);
v___x_2188_ = lean_uint32_to_uint64(v___y_2182_);
v___x_2189_ = 32ULL;
v___x_2190_ = lean_uint64_shift_left(v___x_2188_, v___x_2189_);
v___x_2191_ = lean_uint64_lor(v___x_2187_, v___x_2190_);
return v___x_2191_;
}
v___jp_2192_:
{
if (v___y_2193_ == 0)
{
uint32_t v___x_2197_;
v___x_2197_ = 0;
v___y_2180_ = v___y_2194_;
v___y_2181_ = v___y_2196_;
v___y_2182_ = v___y_2195_;
v___y_2183_ = v___x_2197_;
goto v___jp_2179_;
}
else
{
uint32_t v___x_2198_;
v___x_2198_ = 65536;
v___y_2180_ = v___y_2194_;
v___y_2181_ = v___y_2196_;
v___y_2182_ = v___y_2195_;
v___y_2183_ = v___x_2198_;
goto v___jp_2179_;
}
}
v___jp_2200_:
{
uint8_t v___x_2205_;
v___x_2205_ = lean_uint8_dec_eq(v___y_2203_, v___x_2199_);
if (v___x_2205_ == 0)
{
uint8_t v___x_2206_; uint8_t v___x_2207_;
v___x_2206_ = 2;
v___x_2207_ = lean_uint8_dec_eq(v___y_2203_, v___x_2206_);
if (v___x_2207_ == 0)
{
uint32_t v___x_2208_;
v___x_2208_ = 0;
v___y_2193_ = v___y_2202_;
v___y_2194_ = v___y_2201_;
v___y_2195_ = v___y_2204_;
v___y_2196_ = v___x_2208_;
goto v___jp_2192_;
}
else
{
uint32_t v___x_2209_;
v___x_2209_ = 512;
v___y_2193_ = v___y_2202_;
v___y_2194_ = v___y_2201_;
v___y_2195_ = v___y_2204_;
v___y_2196_ = v___x_2209_;
goto v___jp_2192_;
}
}
else
{
uint32_t v___x_2210_;
v___x_2210_ = 256;
v___y_2193_ = v___y_2202_;
v___y_2194_ = v___y_2201_;
v___y_2195_ = v___y_2204_;
v___y_2196_ = v___x_2210_;
goto v___jp_2192_;
}
}
v___jp_2211_:
{
uint8_t v___x_2216_;
v___x_2216_ = lean_uint8_dec_eq(v___y_2215_, v___x_2199_);
if (v___x_2216_ == 0)
{
v___y_2201_ = v___y_2212_;
v___y_2202_ = v___x_2216_;
v___y_2203_ = v___y_2214_;
v___y_2204_ = v_commit_2178_;
goto v___jp_2200_;
}
else
{
v___y_2201_ = v___y_2212_;
v___y_2202_ = v___x_2216_;
v___y_2203_ = v___y_2214_;
v___y_2204_ = v___y_2213_;
goto v___jp_2200_;
}
}
v___jp_2217_:
{
uint8_t v___x_2221_;
v___x_2221_ = 0;
v___y_2212_ = v___y_2218_;
v___y_2213_ = v___y_2219_;
v___y_2214_ = v___y_2220_;
v___y_2215_ = v___x_2221_;
goto v___jp_2211_;
}
v___jp_2222_:
{
uint8_t v___x_2226_;
v___x_2226_ = lean_uint8_dec_eq(v_lineBlank_2173_, v___x_2199_);
if (v___x_2226_ == 0)
{
v___y_2218_ = v___y_2223_;
v___y_2219_ = v___y_2225_;
v___y_2220_ = v___y_2224_;
goto v___jp_2217_;
}
else
{
uint8_t v___x_2227_; uint8_t v___x_2228_;
v___x_2227_ = 0;
v___x_2228_ = lean_uint8_dec_eq(v___y_2223_, v___x_2227_);
if (v___x_2228_ == 0)
{
v___y_2218_ = v___y_2223_;
v___y_2219_ = v___y_2225_;
v___y_2220_ = v___y_2224_;
goto v___jp_2217_;
}
else
{
uint8_t v___x_2229_;
v___x_2229_ = lean_uint8_dec_eq(v___y_2224_, v___x_2227_);
if (v___x_2229_ == 0)
{
v___y_2218_ = v___y_2223_;
v___y_2219_ = v___y_2225_;
v___y_2220_ = v___y_2224_;
goto v___jp_2217_;
}
else
{
v___y_2212_ = v___y_2223_;
v___y_2213_ = v___y_2225_;
v___y_2214_ = v___y_2224_;
v___y_2215_ = v___x_2199_;
goto v___jp_2211_;
}
}
}
}
v___jp_2230_:
{
uint32_t v___x_2233_; uint8_t v___x_2234_;
v___x_2233_ = 4294967294;
v___x_2234_ = lean_uint32_dec_le(v_pos_2177_, v___x_2233_);
if (v___x_2234_ == 0)
{
uint32_t v___x_2235_;
v___x_2235_ = 4294967295;
v___y_2223_ = v___y_2231_;
v___y_2224_ = v___y_2232_;
v___y_2225_ = v___x_2235_;
goto v___jp_2222_;
}
else
{
uint32_t v___x_2236_; uint32_t v___x_2237_;
v___x_2236_ = 1;
v___x_2237_ = lean_uint32_add(v_pos_2177_, v___x_2236_);
v___y_2223_ = v___y_2231_;
v___y_2224_ = v___y_2232_;
v___y_2225_ = v___x_2237_;
goto v___jp_2222_;
}
}
v___jp_2238_:
{
uint32_t v___x_2241_; uint8_t v___x_2242_;
v___x_2241_ = 3;
v___x_2242_ = lean_uint32_dec_le(v___x_2241_, v_markerCount_2176_);
if (v___x_2242_ == 0)
{
v___y_2231_ = v___y_2239_;
v___y_2232_ = v___y_2240_;
goto v___jp_2230_;
}
else
{
v___y_2231_ = v___y_2239_;
v___y_2232_ = v_markerKind_2175_;
goto v___jp_2230_;
}
}
v___jp_2243_:
{
uint8_t v___x_2245_; uint8_t v___x_2246_;
v___x_2245_ = 0;
v___x_2246_ = lean_uint8_dec_eq(v_openKind_2171_, v___x_2245_);
if (v___x_2246_ == 0)
{
uint8_t v___x_2247_;
v___x_2247_ = lean_uint8_dec_eq(v_markerKind_2175_, v_openKind_2171_);
if (v___x_2247_ == 0)
{
v___y_2231_ = v___y_2244_;
v___y_2232_ = v_openKind_2171_;
goto v___jp_2230_;
}
else
{
uint8_t v___x_2248_;
v___x_2248_ = lean_uint32_dec_le(v_openCount_2172_, v_markerCount_2176_);
if (v___x_2248_ == 0)
{
v___y_2231_ = v___y_2244_;
v___y_2232_ = v_openKind_2171_;
goto v___jp_2230_;
}
else
{
uint32_t v___x_2249_; uint8_t v___x_2250_;
v___x_2249_ = 3;
v___x_2250_ = lean_uint32_dec_le(v___x_2249_, v_markerCount_2176_);
if (v___x_2250_ == 0)
{
v___y_2231_ = v___y_2244_;
v___y_2232_ = v_openKind_2171_;
goto v___jp_2230_;
}
else
{
v___y_2231_ = v___y_2244_;
v___y_2232_ = v___x_2245_;
goto v___jp_2230_;
}
}
}
}
else
{
uint8_t v___x_2251_;
v___x_2251_ = lean_uint8_dec_eq(v_markerKind_2175_, v___x_2199_);
if (v___x_2251_ == 0)
{
uint8_t v___x_2252_; uint8_t v___x_2253_;
v___x_2252_ = 2;
v___x_2253_ = lean_uint8_dec_eq(v_markerKind_2175_, v___x_2252_);
if (v___x_2253_ == 0)
{
v___y_2231_ = v___y_2244_;
v___y_2232_ = v___x_2245_;
goto v___jp_2230_;
}
else
{
v___y_2239_ = v___y_2244_;
v___y_2240_ = v___x_2245_;
goto v___jp_2238_;
}
}
else
{
v___y_2239_ = v___y_2244_;
v___y_2240_ = v___x_2245_;
goto v___jp_2238_;
}
}
}
}
}

LEAN_EXPORT uint64_t orb_stream_token_cost_step(uint64_t v_prevCost_2279_, uint64_t v_newAdvance_2280_, uint64_t v_tailBytes_2281_){
_start:
{
uint64_t v___y_2283_; uint64_t v___x_2288_; uint64_t v___x_2289_; uint8_t v___x_2290_;
v___x_2288_ = 18446744073709551615ULL;
v___x_2289_ = lean_uint64_sub(v___x_2288_, v_tailBytes_2281_);
v___x_2290_ = lean_uint64_dec_le(v_newAdvance_2280_, v___x_2289_);
if (v___x_2290_ == 0)
{
v___y_2283_ = v___x_2288_;
goto v___jp_2282_;
}
else
{
uint64_t v___x_2291_;
v___x_2291_ = lean_uint64_add(v_newAdvance_2280_, v_tailBytes_2281_);
v___y_2283_ = v___x_2291_;
goto v___jp_2282_;
}
v___jp_2282_:
{
uint64_t v___x_2284_; uint64_t v___x_2285_; uint8_t v___x_2286_;
v___x_2284_ = 18446744073709551615ULL;
v___x_2285_ = lean_uint64_sub(v___x_2284_, v___y_2283_);
v___x_2286_ = lean_uint64_dec_le(v_prevCost_2279_, v___x_2285_);
if (v___x_2286_ == 0)
{
return v___x_2284_;
}
else
{
uint64_t v___x_2287_;
v___x_2287_ = lean_uint64_add(v_prevCost_2279_, v___y_2283_);
return v___x_2287_;
}
}
}
}

LEAN_EXPORT uint8_t orb_mission_state_classify(uint8_t v_stateId_2300_){
_start:
{
uint8_t v___x_2301_; uint8_t v___x_2302_;
v___x_2301_ = 8;
v___x_2302_ = lean_uint8_dec_le(v_stateId_2300_, v___x_2301_);
if (v___x_2302_ == 0)
{
uint8_t v___x_2303_; uint8_t v___x_2304_;
v___x_2303_ = 10;
v___x_2304_ = lean_uint8_dec_le(v_stateId_2300_, v___x_2303_);
if (v___x_2304_ == 0)
{
uint8_t v___x_2305_; uint8_t v___x_2306_;
v___x_2305_ = 15;
v___x_2306_ = lean_uint8_dec_le(v_stateId_2300_, v___x_2305_);
if (v___x_2306_ == 0)
{
uint8_t v___x_2307_; uint8_t v___x_2308_;
v___x_2307_ = 16;
v___x_2308_ = lean_uint8_dec_eq(v_stateId_2300_, v___x_2307_);
if (v___x_2308_ == 0)
{
uint8_t v___x_2309_; uint8_t v___x_2310_;
v___x_2309_ = 21;
v___x_2310_ = lean_uint8_dec_le(v_stateId_2300_, v___x_2309_);
if (v___x_2310_ == 0)
{
uint8_t v___x_2311_; uint8_t v___x_2312_;
v___x_2311_ = 23;
v___x_2312_ = lean_uint8_dec_le(v_stateId_2300_, v___x_2311_);
if (v___x_2312_ == 0)
{
uint8_t v___x_2313_; uint8_t v___x_2314_;
v___x_2313_ = 24;
v___x_2314_ = lean_uint8_dec_eq(v_stateId_2300_, v___x_2313_);
if (v___x_2314_ == 0)
{
uint8_t v___x_2315_; uint8_t v___x_2316_;
v___x_2315_ = 26;
v___x_2316_ = lean_uint8_dec_le(v_stateId_2300_, v___x_2315_);
if (v___x_2316_ == 0)
{
uint8_t v___x_2317_; uint8_t v___x_2318_;
v___x_2317_ = 28;
v___x_2318_ = lean_uint8_dec_le(v_stateId_2300_, v___x_2317_);
if (v___x_2318_ == 0)
{
uint8_t v___x_2319_;
v___x_2319_ = 9;
return v___x_2319_;
}
else
{
return v___x_2301_;
}
}
else
{
uint8_t v___x_2320_;
v___x_2320_ = 7;
return v___x_2320_;
}
}
else
{
uint8_t v___x_2321_;
v___x_2321_ = 5;
return v___x_2321_;
}
}
else
{
uint8_t v___x_2322_;
v___x_2322_ = 6;
return v___x_2322_;
}
}
else
{
uint8_t v___x_2323_;
v___x_2323_ = 2;
return v___x_2323_;
}
}
else
{
uint8_t v___x_2324_;
v___x_2324_ = 1;
return v___x_2324_;
}
}
else
{
uint8_t v___x_2325_;
v___x_2325_ = 0;
return v___x_2325_;
}
}
else
{
uint8_t v___x_2326_;
v___x_2326_ = 4;
return v___x_2326_;
}
}
else
{
uint8_t v___x_2327_;
v___x_2327_ = 3;
return v___x_2327_;
}
}
}

LEAN_EXPORT uint8_t orb_mission_sort_rank(uint8_t v_stateId_2332_){
_start:
{
uint8_t v___x_2333_; uint8_t v___x_2334_;
v___x_2333_ = 8;
v___x_2334_ = lean_uint8_dec_le(v_stateId_2332_, v___x_2333_);
if (v___x_2334_ == 0)
{
uint8_t v___x_2335_; uint8_t v___x_2336_;
v___x_2335_ = 10;
v___x_2336_ = lean_uint8_dec_le(v_stateId_2332_, v___x_2335_);
if (v___x_2336_ == 0)
{
uint8_t v___x_2337_; uint8_t v___x_2338_;
v___x_2337_ = 15;
v___x_2338_ = lean_uint8_dec_le(v_stateId_2332_, v___x_2337_);
if (v___x_2338_ == 0)
{
uint8_t v___x_2339_; uint8_t v___x_2340_;
v___x_2339_ = 16;
v___x_2340_ = lean_uint8_dec_eq(v_stateId_2332_, v___x_2339_);
if (v___x_2340_ == 0)
{
uint8_t v___x_2341_; uint8_t v___x_2342_;
v___x_2341_ = 21;
v___x_2342_ = lean_uint8_dec_le(v_stateId_2332_, v___x_2341_);
if (v___x_2342_ == 0)
{
uint8_t v___x_2343_; uint8_t v___x_2344_;
v___x_2343_ = 23;
v___x_2344_ = lean_uint8_dec_le(v_stateId_2332_, v___x_2343_);
if (v___x_2344_ == 0)
{
uint8_t v___x_2345_; uint8_t v___x_2346_;
v___x_2345_ = 24;
v___x_2346_ = lean_uint8_dec_eq(v_stateId_2332_, v___x_2345_);
if (v___x_2346_ == 0)
{
uint8_t v___x_2347_; uint8_t v___x_2348_;
v___x_2347_ = 26;
v___x_2348_ = lean_uint8_dec_le(v_stateId_2332_, v___x_2347_);
if (v___x_2348_ == 0)
{
uint8_t v___x_2349_; uint8_t v___x_2350_;
v___x_2349_ = 28;
v___x_2350_ = lean_uint8_dec_le(v_stateId_2332_, v___x_2349_);
if (v___x_2350_ == 0)
{
uint8_t v___x_2351_;
v___x_2351_ = 9;
return v___x_2351_;
}
else
{
return v___x_2333_;
}
}
else
{
uint8_t v___x_2352_;
v___x_2352_ = 7;
return v___x_2352_;
}
}
else
{
uint8_t v___x_2353_;
v___x_2353_ = 5;
return v___x_2353_;
}
}
else
{
uint8_t v___x_2354_;
v___x_2354_ = 6;
return v___x_2354_;
}
}
else
{
uint8_t v___x_2355_;
v___x_2355_ = 2;
return v___x_2355_;
}
}
else
{
uint8_t v___x_2356_;
v___x_2356_ = 1;
return v___x_2356_;
}
}
else
{
uint8_t v___x_2357_;
v___x_2357_ = 0;
return v___x_2357_;
}
}
else
{
uint8_t v___x_2358_;
v___x_2358_ = 4;
return v___x_2358_;
}
}
else
{
uint8_t v___x_2359_;
v___x_2359_ = 3;
return v___x_2359_;
}
}
}

LEAN_EXPORT uint32_t orb_mission_flags(uint8_t v_stateId_2450_){
_start:
{
uint32_t v___y_2452_; uint8_t v___y_2490_; uint8_t v___x_2516_; uint8_t v___x_2517_;
v___x_2516_ = 8;
v___x_2517_ = lean_uint8_dec_le(v_stateId_2450_, v___x_2516_);
if (v___x_2517_ == 0)
{
uint8_t v___x_2518_; uint8_t v___x_2519_;
v___x_2518_ = 10;
v___x_2519_ = lean_uint8_dec_le(v_stateId_2450_, v___x_2518_);
if (v___x_2519_ == 0)
{
uint8_t v___x_2520_; uint8_t v___x_2521_;
v___x_2520_ = 15;
v___x_2521_ = lean_uint8_dec_le(v_stateId_2450_, v___x_2520_);
if (v___x_2521_ == 0)
{
uint8_t v___x_2522_; uint8_t v___x_2523_;
v___x_2522_ = 16;
v___x_2523_ = lean_uint8_dec_eq(v_stateId_2450_, v___x_2522_);
if (v___x_2523_ == 0)
{
uint8_t v___x_2524_; uint8_t v___x_2525_;
v___x_2524_ = 21;
v___x_2525_ = lean_uint8_dec_le(v_stateId_2450_, v___x_2524_);
if (v___x_2525_ == 0)
{
uint8_t v___x_2526_; uint8_t v___x_2527_;
v___x_2526_ = 23;
v___x_2527_ = lean_uint8_dec_le(v_stateId_2450_, v___x_2526_);
if (v___x_2527_ == 0)
{
uint8_t v___x_2528_; uint8_t v___x_2529_;
v___x_2528_ = 24;
v___x_2529_ = lean_uint8_dec_eq(v_stateId_2450_, v___x_2528_);
if (v___x_2529_ == 0)
{
uint8_t v___x_2530_; uint8_t v___x_2531_;
v___x_2530_ = 26;
v___x_2531_ = lean_uint8_dec_le(v_stateId_2450_, v___x_2530_);
if (v___x_2531_ == 0)
{
uint8_t v___x_2532_; uint8_t v___x_2533_;
v___x_2532_ = 28;
v___x_2533_ = lean_uint8_dec_le(v_stateId_2450_, v___x_2532_);
if (v___x_2533_ == 0)
{
uint8_t v___x_2534_;
v___x_2534_ = 9;
v___y_2490_ = v___x_2534_;
goto v___jp_2489_;
}
else
{
v___y_2490_ = v___x_2516_;
goto v___jp_2489_;
}
}
else
{
uint8_t v___x_2535_;
v___x_2535_ = 7;
v___y_2490_ = v___x_2535_;
goto v___jp_2489_;
}
}
else
{
uint8_t v___x_2536_;
v___x_2536_ = 5;
v___y_2490_ = v___x_2536_;
goto v___jp_2489_;
}
}
else
{
uint8_t v___x_2537_;
v___x_2537_ = 6;
v___y_2490_ = v___x_2537_;
goto v___jp_2489_;
}
}
else
{
uint8_t v___x_2538_;
v___x_2538_ = 2;
v___y_2490_ = v___x_2538_;
goto v___jp_2489_;
}
}
else
{
uint8_t v___x_2539_;
v___x_2539_ = 1;
v___y_2490_ = v___x_2539_;
goto v___jp_2489_;
}
}
else
{
uint8_t v___x_2540_;
v___x_2540_ = 0;
v___y_2490_ = v___x_2540_;
goto v___jp_2489_;
}
}
else
{
uint8_t v___x_2541_;
v___x_2541_ = 4;
v___y_2490_ = v___x_2541_;
goto v___jp_2489_;
}
}
else
{
uint8_t v___x_2542_;
v___x_2542_ = 3;
v___y_2490_ = v___x_2542_;
goto v___jp_2489_;
}
v___jp_2451_:
{
uint8_t v___x_2453_; uint8_t v___x_2454_;
v___x_2453_ = 11;
v___x_2454_ = lean_uint8_dec_eq(v_stateId_2450_, v___x_2453_);
if (v___x_2454_ == 0)
{
uint8_t v___x_2455_; uint8_t v___x_2456_;
v___x_2455_ = 12;
v___x_2456_ = lean_uint8_dec_eq(v_stateId_2450_, v___x_2455_);
if (v___x_2456_ == 0)
{
uint8_t v___x_2457_; uint8_t v___x_2458_;
v___x_2457_ = 24;
v___x_2458_ = lean_uint8_dec_eq(v_stateId_2450_, v___x_2457_);
if (v___x_2458_ == 0)
{
uint8_t v___x_2459_; uint8_t v___x_2460_;
v___x_2459_ = 25;
v___x_2460_ = lean_uint8_dec_eq(v_stateId_2450_, v___x_2459_);
if (v___x_2460_ == 0)
{
uint8_t v___x_2461_; uint8_t v___x_2462_;
v___x_2461_ = 26;
v___x_2462_ = lean_uint8_dec_eq(v_stateId_2450_, v___x_2461_);
if (v___x_2462_ == 0)
{
uint8_t v___x_2463_; uint8_t v___x_2464_;
v___x_2463_ = 16;
v___x_2464_ = lean_uint8_dec_eq(v_stateId_2450_, v___x_2463_);
if (v___x_2464_ == 0)
{
uint8_t v___x_2465_; uint8_t v___x_2466_;
v___x_2465_ = 17;
v___x_2466_ = lean_uint8_dec_eq(v_stateId_2450_, v___x_2465_);
if (v___x_2466_ == 0)
{
uint8_t v___x_2467_; uint8_t v___x_2468_;
v___x_2467_ = 20;
v___x_2468_ = lean_uint8_dec_eq(v_stateId_2450_, v___x_2467_);
if (v___x_2468_ == 0)
{
uint8_t v___x_2469_; uint8_t v___x_2470_;
v___x_2469_ = 22;
v___x_2470_ = lean_uint8_dec_eq(v_stateId_2450_, v___x_2469_);
if (v___x_2470_ == 0)
{
return v___y_2452_;
}
else
{
uint32_t v___x_2471_; uint32_t v___x_2472_;
v___x_2471_ = 24;
v___x_2472_ = lean_uint32_lor(v___y_2452_, v___x_2471_);
return v___x_2472_;
}
}
else
{
uint32_t v___x_2473_; uint32_t v___x_2474_;
v___x_2473_ = 24;
v___x_2474_ = lean_uint32_lor(v___y_2452_, v___x_2473_);
return v___x_2474_;
}
}
else
{
uint32_t v___x_2475_; uint32_t v___x_2476_;
v___x_2475_ = 24;
v___x_2476_ = lean_uint32_lor(v___y_2452_, v___x_2475_);
return v___x_2476_;
}
}
else
{
uint32_t v___x_2477_; uint32_t v___x_2478_;
v___x_2477_ = 24;
v___x_2478_ = lean_uint32_lor(v___y_2452_, v___x_2477_);
return v___x_2478_;
}
}
else
{
uint32_t v___x_2479_; uint32_t v___x_2480_;
v___x_2479_ = 8;
v___x_2480_ = lean_uint32_lor(v___y_2452_, v___x_2479_);
return v___x_2480_;
}
}
else
{
uint32_t v___x_2481_; uint32_t v___x_2482_;
v___x_2481_ = 8;
v___x_2482_ = lean_uint32_lor(v___y_2452_, v___x_2481_);
return v___x_2482_;
}
}
else
{
uint32_t v___x_2483_; uint32_t v___x_2484_;
v___x_2483_ = 8;
v___x_2484_ = lean_uint32_lor(v___y_2452_, v___x_2483_);
return v___x_2484_;
}
}
else
{
uint32_t v___x_2485_; uint32_t v___x_2486_;
v___x_2485_ = 8;
v___x_2486_ = lean_uint32_lor(v___y_2452_, v___x_2485_);
return v___x_2486_;
}
}
else
{
uint32_t v___x_2487_; uint32_t v___x_2488_;
v___x_2487_ = 8;
v___x_2488_ = lean_uint32_lor(v___y_2452_, v___x_2487_);
return v___x_2488_;
}
}
v___jp_2489_:
{
uint8_t v___x_2491_; uint8_t v___x_2492_;
v___x_2491_ = 0;
v___x_2492_ = lean_uint8_dec_eq(v___y_2490_, v___x_2491_);
if (v___x_2492_ == 0)
{
uint8_t v___x_2493_; uint8_t v___x_2494_;
v___x_2493_ = 1;
v___x_2494_ = lean_uint8_dec_eq(v___y_2490_, v___x_2493_);
if (v___x_2494_ == 0)
{
uint8_t v___x_2495_; uint8_t v___x_2496_;
v___x_2495_ = 2;
v___x_2496_ = lean_uint8_dec_eq(v___y_2490_, v___x_2495_);
if (v___x_2496_ == 0)
{
uint8_t v___x_2497_; uint8_t v___x_2498_;
v___x_2497_ = 3;
v___x_2498_ = lean_uint8_dec_eq(v___y_2490_, v___x_2497_);
if (v___x_2498_ == 0)
{
uint8_t v___x_2499_; uint8_t v___x_2500_;
v___x_2499_ = 4;
v___x_2500_ = lean_uint8_dec_eq(v___y_2490_, v___x_2499_);
if (v___x_2500_ == 0)
{
uint8_t v___x_2501_; uint8_t v___x_2502_;
v___x_2501_ = 7;
v___x_2502_ = lean_uint8_dec_eq(v___y_2490_, v___x_2501_);
if (v___x_2502_ == 0)
{
uint8_t v___x_2503_; uint8_t v___x_2504_;
v___x_2503_ = 6;
v___x_2504_ = lean_uint8_dec_eq(v___y_2490_, v___x_2503_);
if (v___x_2504_ == 0)
{
uint8_t v___x_2505_; uint8_t v___x_2506_;
v___x_2505_ = 8;
v___x_2506_ = lean_uint8_dec_eq(v___y_2490_, v___x_2505_);
if (v___x_2506_ == 0)
{
uint32_t v___x_2507_;
v___x_2507_ = 0;
v___y_2452_ = v___x_2507_;
goto v___jp_2451_;
}
else
{
uint32_t v___x_2508_;
v___x_2508_ = 128;
v___y_2452_ = v___x_2508_;
goto v___jp_2451_;
}
}
else
{
uint32_t v___x_2509_;
v___x_2509_ = 128;
v___y_2452_ = v___x_2509_;
goto v___jp_2451_;
}
}
else
{
uint32_t v___x_2510_;
v___x_2510_ = 194;
v___y_2452_ = v___x_2510_;
goto v___jp_2451_;
}
}
else
{
uint32_t v___x_2511_;
v___x_2511_ = 1;
v___y_2452_ = v___x_2511_;
goto v___jp_2451_;
}
}
else
{
uint32_t v___x_2512_;
v___x_2512_ = 1;
v___y_2452_ = v___x_2512_;
goto v___jp_2451_;
}
}
else
{
uint32_t v___x_2513_;
v___x_2513_ = 166;
v___y_2452_ = v___x_2513_;
goto v___jp_2451_;
}
}
else
{
uint32_t v___x_2514_;
v___x_2514_ = 36;
v___y_2452_ = v___x_2514_;
goto v___jp_2451_;
}
}
else
{
uint32_t v___x_2515_;
v___x_2515_ = 4;
v___y_2452_ = v___x_2515_;
goto v___jp_2451_;
}
}
}
}

LEAN_EXPORT uint8_t orb_mission_inbox_section(uint8_t v_stateId_2547_){
_start:
{
uint8_t v___y_2549_; uint8_t v___x_2583_; uint8_t v___x_2584_;
v___x_2583_ = 8;
v___x_2584_ = lean_uint8_dec_le(v_stateId_2547_, v___x_2583_);
if (v___x_2584_ == 0)
{
uint8_t v___x_2585_; uint8_t v___x_2586_;
v___x_2585_ = 10;
v___x_2586_ = lean_uint8_dec_le(v_stateId_2547_, v___x_2585_);
if (v___x_2586_ == 0)
{
uint8_t v___x_2587_; uint8_t v___x_2588_;
v___x_2587_ = 15;
v___x_2588_ = lean_uint8_dec_le(v_stateId_2547_, v___x_2587_);
if (v___x_2588_ == 0)
{
uint8_t v___x_2589_; uint8_t v___x_2590_;
v___x_2589_ = 16;
v___x_2590_ = lean_uint8_dec_eq(v_stateId_2547_, v___x_2589_);
if (v___x_2590_ == 0)
{
uint8_t v___x_2591_; uint8_t v___x_2592_;
v___x_2591_ = 21;
v___x_2592_ = lean_uint8_dec_le(v_stateId_2547_, v___x_2591_);
if (v___x_2592_ == 0)
{
uint8_t v___x_2593_; uint8_t v___x_2594_;
v___x_2593_ = 23;
v___x_2594_ = lean_uint8_dec_le(v_stateId_2547_, v___x_2593_);
if (v___x_2594_ == 0)
{
uint8_t v___x_2595_; uint8_t v___x_2596_;
v___x_2595_ = 24;
v___x_2596_ = lean_uint8_dec_eq(v_stateId_2547_, v___x_2595_);
if (v___x_2596_ == 0)
{
uint8_t v___x_2597_; uint8_t v___x_2598_;
v___x_2597_ = 26;
v___x_2598_ = lean_uint8_dec_le(v_stateId_2547_, v___x_2597_);
if (v___x_2598_ == 0)
{
uint8_t v___x_2599_; uint8_t v___x_2600_;
v___x_2599_ = 28;
v___x_2600_ = lean_uint8_dec_le(v_stateId_2547_, v___x_2599_);
if (v___x_2600_ == 0)
{
uint8_t v___x_2601_;
v___x_2601_ = 9;
v___y_2549_ = v___x_2601_;
goto v___jp_2548_;
}
else
{
v___y_2549_ = v___x_2583_;
goto v___jp_2548_;
}
}
else
{
uint8_t v___x_2602_;
v___x_2602_ = 7;
v___y_2549_ = v___x_2602_;
goto v___jp_2548_;
}
}
else
{
uint8_t v___x_2603_;
v___x_2603_ = 5;
v___y_2549_ = v___x_2603_;
goto v___jp_2548_;
}
}
else
{
uint8_t v___x_2604_;
v___x_2604_ = 6;
v___y_2549_ = v___x_2604_;
goto v___jp_2548_;
}
}
else
{
uint8_t v___x_2605_;
v___x_2605_ = 2;
v___y_2549_ = v___x_2605_;
goto v___jp_2548_;
}
}
else
{
uint8_t v___x_2606_;
v___x_2606_ = 1;
v___y_2549_ = v___x_2606_;
goto v___jp_2548_;
}
}
else
{
uint8_t v___x_2607_;
v___x_2607_ = 0;
v___y_2549_ = v___x_2607_;
goto v___jp_2548_;
}
}
else
{
uint8_t v___x_2608_;
v___x_2608_ = 4;
v___y_2549_ = v___x_2608_;
goto v___jp_2548_;
}
}
else
{
uint8_t v___x_2609_;
v___x_2609_ = 3;
v___y_2549_ = v___x_2609_;
goto v___jp_2548_;
}
v___jp_2548_:
{
uint8_t v___x_2550_; uint8_t v___x_2551_;
v___x_2550_ = 3;
v___x_2551_ = lean_uint8_dec_eq(v___y_2549_, v___x_2550_);
if (v___x_2551_ == 0)
{
uint8_t v___x_2552_; uint8_t v___x_2553_;
v___x_2552_ = 4;
v___x_2553_ = lean_uint8_dec_eq(v___y_2549_, v___x_2552_);
if (v___x_2553_ == 0)
{
uint8_t v___x_2554_; uint8_t v___x_2555_;
v___x_2554_ = 2;
v___x_2555_ = lean_uint8_dec_le(v___y_2549_, v___x_2554_);
if (v___x_2555_ == 0)
{
uint8_t v___x_2556_; uint8_t v___x_2557_;
v___x_2556_ = 7;
v___x_2557_ = lean_uint8_dec_eq(v___y_2549_, v___x_2556_);
if (v___x_2557_ == 0)
{
uint8_t v___x_2558_; uint8_t v___x_2559_;
v___x_2558_ = 5;
v___x_2559_ = lean_uint8_dec_eq(v___y_2549_, v___x_2558_);
if (v___x_2559_ == 0)
{
uint8_t v___x_2560_; uint8_t v___x_2561_;
v___x_2560_ = 6;
v___x_2561_ = lean_uint8_dec_eq(v___y_2549_, v___x_2560_);
if (v___x_2561_ == 0)
{
return v___x_2550_;
}
else
{
uint8_t v___x_2562_; uint8_t v___x_2563_;
v___x_2562_ = 11;
v___x_2563_ = lean_uint8_dec_eq(v_stateId_2547_, v___x_2562_);
if (v___x_2563_ == 0)
{
uint8_t v___x_2564_; uint8_t v___x_2565_;
v___x_2564_ = 12;
v___x_2565_ = lean_uint8_dec_eq(v_stateId_2547_, v___x_2564_);
if (v___x_2565_ == 0)
{
uint8_t v___x_2566_; uint8_t v___x_2567_;
v___x_2566_ = 16;
v___x_2567_ = lean_uint8_dec_eq(v_stateId_2547_, v___x_2566_);
if (v___x_2567_ == 0)
{
uint8_t v___x_2568_; uint8_t v___x_2569_;
v___x_2568_ = 17;
v___x_2569_ = lean_uint8_dec_eq(v_stateId_2547_, v___x_2568_);
if (v___x_2569_ == 0)
{
uint8_t v___x_2570_; uint8_t v___x_2571_;
v___x_2570_ = 20;
v___x_2571_ = lean_uint8_dec_eq(v_stateId_2547_, v___x_2570_);
if (v___x_2571_ == 0)
{
uint8_t v___x_2572_; uint8_t v___x_2573_;
v___x_2572_ = 22;
v___x_2573_ = lean_uint8_dec_eq(v_stateId_2547_, v___x_2572_);
if (v___x_2573_ == 0)
{
uint8_t v___x_2574_; uint8_t v___x_2575_;
v___x_2574_ = 24;
v___x_2575_ = lean_uint8_dec_eq(v_stateId_2547_, v___x_2574_);
if (v___x_2575_ == 0)
{
uint8_t v___x_2576_; uint8_t v___x_2577_;
v___x_2576_ = 25;
v___x_2577_ = lean_uint8_dec_eq(v_stateId_2547_, v___x_2576_);
if (v___x_2577_ == 0)
{
uint8_t v___x_2578_; uint8_t v___x_2579_;
v___x_2578_ = 26;
v___x_2579_ = lean_uint8_dec_eq(v_stateId_2547_, v___x_2578_);
if (v___x_2579_ == 0)
{
return v___x_2550_;
}
else
{
return v___x_2554_;
}
}
else
{
return v___x_2554_;
}
}
else
{
return v___x_2554_;
}
}
else
{
return v___x_2554_;
}
}
else
{
return v___x_2554_;
}
}
else
{
return v___x_2554_;
}
}
else
{
return v___x_2554_;
}
}
else
{
return v___x_2554_;
}
}
else
{
return v___x_2554_;
}
}
}
else
{
return v___x_2554_;
}
}
else
{
return v___x_2554_;
}
}
else
{
uint8_t v___x_2580_;
v___x_2580_ = 1;
return v___x_2580_;
}
}
else
{
uint8_t v___x_2581_;
v___x_2581_ = 0;
return v___x_2581_;
}
}
else
{
uint8_t v___x_2582_;
v___x_2582_ = 0;
return v___x_2582_;
}
}
}
}

LEAN_EXPORT uint32_t orb_connection_issue_classify(uint8_t v_isUnreachable_2614_, uint8_t v_isUsingDefault_2615_, uint8_t v_isPrivateAddr_2616_, uint8_t v_defaultReachable_2617_, uint8_t v_hasExternalProxy_2618_){
_start:
{
uint32_t v___y_2620_; uint32_t v___y_2621_; uint32_t v___y_2622_; uint32_t v___y_2623_; uint8_t v___x_2631_; uint32_t v___y_2633_; uint32_t v___y_2634_; uint8_t v___y_2642_; uint32_t v___y_2643_; uint32_t v___y_2644_; uint32_t v___y_2655_; uint8_t v___y_2656_; uint8_t v___x_2658_;
v___x_2631_ = 1;
v___x_2658_ = lean_uint8_dec_eq(v_isUnreachable_2614_, v___x_2631_);
if (v___x_2658_ == 0)
{
uint32_t v___x_2659_;
v___x_2659_ = 0;
return v___x_2659_;
}
else
{
uint8_t v___x_2660_; uint8_t v___x_2661_; uint8_t v___x_2662_; uint32_t v___y_2664_;
v___x_2660_ = 0;
v___x_2661_ = 0;
v___x_2662_ = lean_uint8_dec_eq(v_isUsingDefault_2615_, v___x_2661_);
if (v___x_2662_ == 0)
{
uint32_t v___x_2667_;
v___x_2667_ = 0;
v___y_2664_ = v___x_2667_;
goto v___jp_2663_;
}
else
{
uint32_t v___x_2668_;
v___x_2668_ = 256;
v___y_2664_ = v___x_2668_;
goto v___jp_2663_;
}
v___jp_2663_:
{
if (v___x_2662_ == 0)
{
v___y_2655_ = v___y_2664_;
v___y_2656_ = v___x_2660_;
goto v___jp_2654_;
}
else
{
uint8_t v___x_2665_;
v___x_2665_ = lean_uint8_dec_eq(v_isPrivateAddr_2616_, v___x_2631_);
if (v___x_2665_ == 0)
{
v___y_2655_ = v___y_2664_;
v___y_2656_ = v___x_2665_;
goto v___jp_2654_;
}
else
{
uint32_t v___x_2666_;
v___x_2666_ = 16777216;
v___y_2642_ = v___x_2665_;
v___y_2643_ = v___y_2664_;
v___y_2644_ = v___x_2666_;
goto v___jp_2641_;
}
}
}
}
v___jp_2619_:
{
uint32_t v___x_2624_; uint32_t v___x_2625_; uint32_t v___x_2626_; uint32_t v___x_2627_; uint32_t v___x_2628_; uint32_t v___x_2629_; uint32_t v___x_2630_;
v___x_2624_ = 1;
v___x_2625_ = lean_uint32_lor(v___x_2624_, v___y_2622_);
v___x_2626_ = lean_uint32_lor(v___x_2625_, v___y_2620_);
v___x_2627_ = lean_uint32_lor(v___x_2626_, v___y_2621_);
v___x_2628_ = 28;
v___x_2629_ = lean_uint32_shift_left(v___y_2623_, v___x_2628_);
v___x_2630_ = lean_uint32_lor(v___x_2627_, v___x_2629_);
return v___x_2630_;
}
v___jp_2632_:
{
uint32_t v___x_2635_; uint8_t v___x_2636_;
v___x_2635_ = 0;
v___x_2636_ = lean_uint8_dec_eq(v_isPrivateAddr_2616_, v___x_2631_);
if (v___x_2636_ == 0)
{
uint8_t v___x_2637_;
v___x_2637_ = lean_uint8_dec_eq(v_isUsingDefault_2615_, v___x_2631_);
if (v___x_2637_ == 0)
{
uint32_t v___x_2638_;
v___x_2638_ = 5;
v___y_2620_ = v___x_2635_;
v___y_2621_ = v___y_2633_;
v___y_2622_ = v___y_2634_;
v___y_2623_ = v___x_2638_;
goto v___jp_2619_;
}
else
{
uint32_t v___x_2639_;
v___x_2639_ = 4;
v___y_2620_ = v___x_2635_;
v___y_2621_ = v___y_2633_;
v___y_2622_ = v___y_2634_;
v___y_2623_ = v___x_2639_;
goto v___jp_2619_;
}
}
else
{
uint32_t v___x_2640_;
v___x_2640_ = 3;
v___y_2620_ = v___x_2635_;
v___y_2621_ = v___y_2633_;
v___y_2622_ = v___y_2634_;
v___y_2623_ = v___x_2640_;
goto v___jp_2619_;
}
}
v___jp_2641_:
{
uint8_t v___x_2645_;
v___x_2645_ = lean_uint8_dec_eq(v_hasExternalProxy_2618_, v___x_2631_);
if (v___x_2645_ == 0)
{
if (v___y_2642_ == 0)
{
v___y_2633_ = v___y_2644_;
v___y_2634_ = v___y_2643_;
goto v___jp_2632_;
}
else
{
uint8_t v___x_2646_;
v___x_2646_ = lean_uint8_dec_eq(v_defaultReachable_2617_, v___x_2631_);
if (v___x_2646_ == 0)
{
v___y_2633_ = v___y_2644_;
v___y_2634_ = v___y_2643_;
goto v___jp_2632_;
}
else
{
uint32_t v___x_2647_; uint32_t v___x_2648_;
v___x_2647_ = 65536;
v___x_2648_ = 2;
v___y_2620_ = v___x_2647_;
v___y_2621_ = v___y_2644_;
v___y_2622_ = v___y_2643_;
v___y_2623_ = v___x_2648_;
goto v___jp_2619_;
}
}
}
else
{
uint32_t v___x_2649_; uint32_t v___x_2650_; uint32_t v___x_2651_; uint32_t v___x_2652_; uint32_t v___x_2653_;
v___x_2649_ = 1;
v___x_2650_ = lean_uint32_lor(v___x_2649_, v___y_2643_);
v___x_2651_ = lean_uint32_lor(v___x_2650_, v___y_2644_);
v___x_2652_ = 268435456;
v___x_2653_ = lean_uint32_lor(v___x_2651_, v___x_2652_);
return v___x_2653_;
}
}
v___jp_2654_:
{
uint32_t v___x_2657_;
v___x_2657_ = 0;
v___y_2642_ = v___y_2656_;
v___y_2643_ = v___y_2655_;
v___y_2644_ = v___x_2657_;
goto v___jp_2641_;
}
}
}

LEAN_EXPORT uint64_t orb_worked_duration_bucket(uint64_t v_seconds_2681_){
_start:
{
uint64_t v___x_2682_; uint8_t v___x_2683_;
v___x_2682_ = 60ULL;
v___x_2683_ = lean_uint64_dec_lt(v_seconds_2681_, v___x_2682_);
if (v___x_2683_ == 0)
{
uint64_t v___x_2684_; uint8_t v___x_2685_;
v___x_2684_ = 3600ULL;
v___x_2685_ = lean_uint64_dec_lt(v_seconds_2681_, v___x_2684_);
if (v___x_2685_ == 0)
{
uint64_t v___x_2686_; uint8_t v___x_2687_;
v___x_2686_ = 86400ULL;
v___x_2687_ = lean_uint64_dec_lt(v_seconds_2681_, v___x_2686_);
if (v___x_2687_ == 0)
{
uint64_t v_totalH_2688_; uint64_t v___x_2689_; uint64_t v___y_2691_; uint64_t v___x_2700_; uint64_t v___x_2701_; uint8_t v___x_2702_;
v_totalH_2688_ = lean_uint64_div(v_seconds_2681_, v___x_2684_);
v___x_2689_ = 24ULL;
v___x_2700_ = lean_uint64_div(v_totalH_2688_, v___x_2689_);
v___x_2701_ = 4294967295ULL;
v___x_2702_ = lean_uint64_dec_le(v___x_2700_, v___x_2701_);
if (v___x_2702_ == 0)
{
v___y_2691_ = v___x_2701_;
goto v___jp_2690_;
}
else
{
v___y_2691_ = v___x_2700_;
goto v___jp_2690_;
}
v___jp_2690_:
{
uint64_t v_remH_2692_; uint64_t v___x_2693_; uint64_t v___x_2694_; uint64_t v___x_2695_; uint64_t v___x_2696_; uint64_t v___x_2697_; uint64_t v___x_2698_; uint64_t v___x_2699_;
v_remH_2692_ = lean_uint64_mod(v_totalH_2688_, v___x_2689_);
v___x_2693_ = 3ULL;
v___x_2694_ = 8ULL;
v___x_2695_ = lean_uint64_shift_left(v_remH_2692_, v___x_2694_);
v___x_2696_ = lean_uint64_lor(v___x_2693_, v___x_2695_);
v___x_2697_ = 32ULL;
v___x_2698_ = lean_uint64_shift_left(v___y_2691_, v___x_2697_);
v___x_2699_ = lean_uint64_lor(v___x_2696_, v___x_2698_);
return v___x_2699_;
}
}
else
{
uint64_t v_totalM_2703_; uint64_t v_h_2704_; uint64_t v_remM_2705_; uint64_t v___x_2706_; uint64_t v___x_2707_; uint64_t v___x_2708_; uint64_t v___x_2709_; uint64_t v___x_2710_; uint64_t v___x_2711_; uint64_t v___x_2712_;
v_totalM_2703_ = lean_uint64_div(v_seconds_2681_, v___x_2682_);
v_h_2704_ = lean_uint64_div(v_totalM_2703_, v___x_2682_);
v_remM_2705_ = lean_uint64_mod(v_totalM_2703_, v___x_2682_);
v___x_2706_ = 2ULL;
v___x_2707_ = 8ULL;
v___x_2708_ = lean_uint64_shift_left(v_remM_2705_, v___x_2707_);
v___x_2709_ = lean_uint64_lor(v___x_2706_, v___x_2708_);
v___x_2710_ = 32ULL;
v___x_2711_ = lean_uint64_shift_left(v_h_2704_, v___x_2710_);
v___x_2712_ = lean_uint64_lor(v___x_2709_, v___x_2711_);
return v___x_2712_;
}
}
else
{
uint64_t v_m_2713_; uint64_t v_rem_2714_; uint64_t v___x_2715_; uint64_t v___x_2716_; uint64_t v___x_2717_; uint64_t v___x_2718_; uint64_t v___x_2719_; uint64_t v___x_2720_; uint64_t v___x_2721_;
v_m_2713_ = lean_uint64_div(v_seconds_2681_, v___x_2682_);
v_rem_2714_ = lean_uint64_mod(v_seconds_2681_, v___x_2682_);
v___x_2715_ = 1ULL;
v___x_2716_ = 8ULL;
v___x_2717_ = lean_uint64_shift_left(v_rem_2714_, v___x_2716_);
v___x_2718_ = lean_uint64_lor(v___x_2715_, v___x_2717_);
v___x_2719_ = 32ULL;
v___x_2720_ = lean_uint64_shift_left(v_m_2713_, v___x_2719_);
v___x_2721_ = lean_uint64_lor(v___x_2718_, v___x_2720_);
return v___x_2721_;
}
}
else
{
uint64_t v___x_2722_; uint64_t v___x_2723_;
v___x_2722_ = 32ULL;
v___x_2723_ = lean_uint64_shift_left(v_seconds_2681_, v___x_2722_);
return v___x_2723_;
}
}
}

LEAN_EXPORT uint32_t orb_turn_outcome_step(uint8_t v_prevOutcome_2728_, uint8_t v_prevFailed_2729_, uint8_t v_eventKind_2730_, uint8_t v_isNarration_2731_, uint8_t v_isSuccessFalse_2732_, uint8_t v_isTextNonEmpty_2733_){
_start:
{
uint8_t v___x_2734_; uint8_t v___x_2735_;
v___x_2734_ = 0;
v___x_2735_ = lean_uint8_dec_eq(v_eventKind_2730_, v___x_2734_);
if (v___x_2735_ == 0)
{
uint8_t v___x_2736_; uint32_t v___y_2738_; uint32_t v___y_2743_; uint32_t v___y_2752_; uint8_t v___x_2756_;
v___x_2736_ = 1;
v___x_2756_ = lean_uint8_dec_eq(v_eventKind_2730_, v___x_2736_);
if (v___x_2756_ == 0)
{
uint8_t v___x_2757_; uint8_t v___x_2758_;
v___x_2757_ = 2;
v___x_2758_ = lean_uint8_dec_eq(v_eventKind_2730_, v___x_2757_);
if (v___x_2758_ == 0)
{
uint8_t v___x_2759_;
v___x_2759_ = lean_uint8_dec_eq(v_prevOutcome_2728_, v___x_2736_);
if (v___x_2759_ == 0)
{
uint32_t v___x_2760_;
v___x_2760_ = 0;
v___y_2752_ = v___x_2760_;
goto v___jp_2751_;
}
else
{
uint32_t v___x_2761_;
v___x_2761_ = 1;
v___y_2752_ = v___x_2761_;
goto v___jp_2751_;
}
}
else
{
uint8_t v___x_2762_;
v___x_2762_ = lean_uint8_dec_eq(v_isNarration_2731_, v___x_2736_);
if (v___x_2762_ == 0)
{
uint8_t v___x_2763_;
v___x_2763_ = lean_uint8_dec_eq(v_isSuccessFalse_2732_, v___x_2736_);
if (v___x_2763_ == 0)
{
uint8_t v___x_2764_;
v___x_2764_ = lean_uint8_dec_eq(v_prevFailed_2729_, v___x_2734_);
if (v___x_2764_ == 0)
{
goto v___jp_2747_;
}
else
{
uint8_t v___x_2765_;
v___x_2765_ = lean_uint8_dec_eq(v_isTextNonEmpty_2733_, v___x_2736_);
if (v___x_2765_ == 0)
{
goto v___jp_2747_;
}
else
{
uint32_t v___x_2766_;
v___x_2766_ = 1;
return v___x_2766_;
}
}
}
else
{
uint32_t v___x_2767_;
v___x_2767_ = 256;
return v___x_2767_;
}
}
else
{
uint8_t v___x_2768_;
v___x_2768_ = lean_uint8_dec_eq(v_prevOutcome_2728_, v___x_2736_);
if (v___x_2768_ == 0)
{
uint32_t v___x_2769_;
v___x_2769_ = 0;
v___y_2738_ = v___x_2769_;
goto v___jp_2737_;
}
else
{
uint32_t v___x_2770_;
v___x_2770_ = 1;
v___y_2738_ = v___x_2770_;
goto v___jp_2737_;
}
}
}
}
else
{
uint32_t v___x_2771_;
v___x_2771_ = 0;
return v___x_2771_;
}
v___jp_2737_:
{
uint8_t v___x_2739_;
v___x_2739_ = lean_uint8_dec_eq(v_prevFailed_2729_, v___x_2736_);
if (v___x_2739_ == 0)
{
return v___y_2738_;
}
else
{
uint32_t v___x_2740_; uint32_t v___x_2741_;
v___x_2740_ = 256;
v___x_2741_ = lean_uint32_lor(v___y_2738_, v___x_2740_);
return v___x_2741_;
}
}
v___jp_2742_:
{
uint8_t v___x_2744_;
v___x_2744_ = lean_uint8_dec_eq(v_prevFailed_2729_, v___x_2736_);
if (v___x_2744_ == 0)
{
return v___y_2743_;
}
else
{
uint32_t v___x_2745_; uint32_t v___x_2746_;
v___x_2745_ = 256;
v___x_2746_ = lean_uint32_lor(v___y_2743_, v___x_2745_);
return v___x_2746_;
}
}
v___jp_2747_:
{
uint8_t v___x_2748_;
v___x_2748_ = lean_uint8_dec_eq(v_prevOutcome_2728_, v___x_2736_);
if (v___x_2748_ == 0)
{
uint32_t v___x_2749_;
v___x_2749_ = 0;
v___y_2743_ = v___x_2749_;
goto v___jp_2742_;
}
else
{
uint32_t v___x_2750_;
v___x_2750_ = 1;
v___y_2743_ = v___x_2750_;
goto v___jp_2742_;
}
}
v___jp_2751_:
{
uint8_t v___x_2753_;
v___x_2753_ = lean_uint8_dec_eq(v_prevFailed_2729_, v___x_2736_);
if (v___x_2753_ == 0)
{
return v___y_2752_;
}
else
{
uint32_t v___x_2754_; uint32_t v___x_2755_;
v___x_2754_ = 256;
v___x_2755_ = lean_uint32_lor(v___y_2752_, v___x_2754_);
return v___x_2755_;
}
}
}
else
{
uint32_t v___x_2772_;
v___x_2772_ = 0;
return v___x_2772_;
}
}
}

LEAN_EXPORT uint8_t orb_numeric_cell_scan(uint8_t v_nonEmpty_2787_, uint8_t v_hasLeadingDigitOrSign_2788_, uint8_t v_hasDigit_2789_, uint8_t v_allAllowedChars_2790_){
_start:
{
uint8_t v___x_2791_; uint8_t v___x_2792_;
v___x_2791_ = 1;
v___x_2792_ = lean_uint8_dec_eq(v_nonEmpty_2787_, v___x_2791_);
if (v___x_2792_ == 0)
{
uint8_t v___x_2793_;
v___x_2793_ = 0;
return v___x_2793_;
}
else
{
uint8_t v___x_2794_;
v___x_2794_ = lean_uint8_dec_eq(v_hasLeadingDigitOrSign_2788_, v___x_2791_);
if (v___x_2794_ == 0)
{
uint8_t v___x_2795_;
v___x_2795_ = 0;
return v___x_2795_;
}
else
{
uint8_t v___x_2796_;
v___x_2796_ = lean_uint8_dec_eq(v_hasDigit_2789_, v___x_2791_);
if (v___x_2796_ == 0)
{
uint8_t v___x_2797_;
v___x_2797_ = 0;
return v___x_2797_;
}
else
{
uint8_t v___x_2798_;
v___x_2798_ = lean_uint8_dec_eq(v_allAllowedChars_2790_, v___x_2791_);
if (v___x_2798_ == 0)
{
uint8_t v___x_2799_;
v___x_2799_ = 0;
return v___x_2799_;
}
else
{
return v___x_2791_;
}
}
}
}
}
}

LEAN_EXPORT uint64_t orb_file_ref_line_span(uint32_t v_startLine_2810_, uint32_t v_endLine_2811_, uint32_t v_totalLines_2812_){
_start:
{
uint32_t v___x_2813_; uint8_t v___x_2822_;
v___x_2813_ = 1;
v___x_2822_ = lean_uint32_dec_le(v___x_2813_, v_startLine_2810_);
if (v___x_2822_ == 0)
{
uint64_t v___x_2823_;
v___x_2823_ = 0ULL;
return v___x_2823_;
}
else
{
uint8_t v___x_2824_;
v___x_2824_ = lean_uint32_dec_le(v_startLine_2810_, v_endLine_2811_);
if (v___x_2824_ == 0)
{
uint64_t v___x_2825_;
v___x_2825_ = 0ULL;
return v___x_2825_;
}
else
{
uint32_t v___x_2826_; uint8_t v___x_2827_;
v___x_2826_ = 0;
v___x_2827_ = lean_uint32_dec_eq(v_totalLines_2812_, v___x_2826_);
if (v___x_2827_ == 0)
{
uint8_t v___x_2828_;
v___x_2828_ = lean_uint32_dec_le(v_endLine_2811_, v_totalLines_2812_);
if (v___x_2828_ == 0)
{
uint64_t v___x_2829_;
v___x_2829_ = 0ULL;
return v___x_2829_;
}
else
{
goto v___jp_2814_;
}
}
else
{
goto v___jp_2814_;
}
}
}
v___jp_2814_:
{
uint32_t v___x_2815_; uint32_t v_count_2816_; uint64_t v___x_2817_; uint64_t v___x_2818_; uint64_t v___x_2819_; uint64_t v___x_2820_; uint64_t v___x_2821_;
v___x_2815_ = lean_uint32_sub(v_endLine_2811_, v_startLine_2810_);
v_count_2816_ = lean_uint32_add(v___x_2815_, v___x_2813_);
v___x_2817_ = 1ULL;
v___x_2818_ = lean_uint32_to_uint64(v_count_2816_);
v___x_2819_ = 32ULL;
v___x_2820_ = lean_uint64_shift_left(v___x_2818_, v___x_2819_);
v___x_2821_ = lean_uint64_lor(v___x_2817_, v___x_2820_);
return v___x_2821_;
}
}
}

LEAN_EXPORT uint32_t orb_machine_action_admitted(uint8_t v_stateKind_2838_, uint8_t v_isBusy_2839_, uint8_t v_isMuted_2840_){
_start:
{
uint32_t v___y_2842_; uint32_t v___y_2843_; uint32_t v___y_2844_; uint32_t v___y_2845_; uint32_t v___y_2846_; uint32_t v___y_2852_; uint32_t v___y_2853_; uint32_t v___y_2854_; uint32_t v___y_2855_; uint32_t v___y_2858_; uint32_t v___y_2859_; uint8_t v___y_2860_; uint32_t v___y_2861_; uint8_t v___y_2862_; uint32_t v___y_2863_; uint32_t v___y_2866_; uint32_t v___y_2867_; uint8_t v___y_2868_; uint32_t v___y_2869_; uint32_t v___y_2875_; uint8_t v___y_2876_; uint8_t v___y_2877_; uint32_t v___y_2878_; uint32_t v___y_2882_; uint8_t v___y_2883_; uint8_t v___y_2884_; uint8_t v___y_2887_; uint32_t v___y_2888_; uint8_t v___y_2893_; uint8_t v___x_2898_; uint8_t v___x_2899_;
v___x_2898_ = 0;
v___x_2899_ = lean_uint8_dec_eq(v_isBusy_2839_, v___x_2898_);
if (v___x_2899_ == 0)
{
v___y_2893_ = v___x_2899_;
goto v___jp_2892_;
}
else
{
uint8_t v___x_2900_;
v___x_2900_ = lean_uint8_dec_eq(v_isMuted_2840_, v___x_2898_);
v___y_2893_ = v___x_2900_;
goto v___jp_2892_;
}
v___jp_2841_:
{
uint32_t v___x_2847_; uint32_t v___x_2848_; uint32_t v___x_2849_; uint32_t v___x_2850_;
v___x_2847_ = lean_uint32_lor(v___y_2842_, v___y_2844_);
v___x_2848_ = lean_uint32_lor(v___x_2847_, v___y_2845_);
v___x_2849_ = lean_uint32_lor(v___x_2848_, v___y_2843_);
v___x_2850_ = lean_uint32_lor(v___x_2849_, v___y_2846_);
return v___x_2850_;
}
v___jp_2851_:
{
uint32_t v___x_2856_;
v___x_2856_ = 0;
v___y_2842_ = v___y_2852_;
v___y_2843_ = v___y_2853_;
v___y_2844_ = v___y_2854_;
v___y_2845_ = v___y_2855_;
v___y_2846_ = v___x_2856_;
goto v___jp_2841_;
}
v___jp_2857_:
{
if (v___y_2860_ == 0)
{
v___y_2852_ = v___y_2858_;
v___y_2853_ = v___y_2863_;
v___y_2854_ = v___y_2859_;
v___y_2855_ = v___y_2861_;
goto v___jp_2851_;
}
else
{
if (v___y_2862_ == 0)
{
v___y_2852_ = v___y_2858_;
v___y_2853_ = v___y_2863_;
v___y_2854_ = v___y_2859_;
v___y_2855_ = v___y_2861_;
goto v___jp_2851_;
}
else
{
uint32_t v___x_2864_;
v___x_2864_ = 33554432;
v___y_2842_ = v___y_2858_;
v___y_2843_ = v___y_2863_;
v___y_2844_ = v___y_2859_;
v___y_2845_ = v___y_2861_;
v___y_2846_ = v___x_2864_;
goto v___jp_2841_;
}
}
}
v___jp_2865_:
{
uint8_t v___x_2870_; uint8_t v___x_2871_;
v___x_2870_ = 6;
v___x_2871_ = lean_uint8_dec_eq(v_stateKind_2838_, v___x_2870_);
if (v___x_2871_ == 0)
{
uint32_t v___x_2872_;
v___x_2872_ = 0;
v___y_2858_ = v___y_2866_;
v___y_2859_ = v___y_2867_;
v___y_2860_ = v___x_2871_;
v___y_2861_ = v___y_2869_;
v___y_2862_ = v___y_2868_;
v___y_2863_ = v___x_2872_;
goto v___jp_2857_;
}
else
{
uint32_t v___x_2873_;
v___x_2873_ = 16777216;
v___y_2858_ = v___y_2866_;
v___y_2859_ = v___y_2867_;
v___y_2860_ = v___x_2871_;
v___y_2861_ = v___y_2869_;
v___y_2862_ = v___y_2868_;
v___y_2863_ = v___x_2873_;
goto v___jp_2857_;
}
}
v___jp_2874_:
{
if (v___y_2876_ == 0)
{
uint32_t v___x_2879_;
v___x_2879_ = 0;
v___y_2866_ = v___y_2875_;
v___y_2867_ = v___y_2878_;
v___y_2868_ = v___y_2877_;
v___y_2869_ = v___x_2879_;
goto v___jp_2865_;
}
else
{
uint32_t v___x_2880_;
v___x_2880_ = 65536;
v___y_2866_ = v___y_2875_;
v___y_2867_ = v___y_2878_;
v___y_2868_ = v___y_2877_;
v___y_2869_ = v___x_2880_;
goto v___jp_2865_;
}
}
v___jp_2881_:
{
uint32_t v___x_2885_;
v___x_2885_ = 0;
v___y_2875_ = v___y_2882_;
v___y_2876_ = v___y_2883_;
v___y_2877_ = v___y_2884_;
v___y_2878_ = v___x_2885_;
goto v___jp_2874_;
}
v___jp_2886_:
{
uint8_t v___x_2889_; uint8_t v___x_2890_;
v___x_2889_ = 2;
v___x_2890_ = lean_uint8_dec_le(v_stateKind_2838_, v___x_2889_);
if (v___x_2890_ == 0)
{
v___y_2882_ = v___y_2888_;
v___y_2883_ = v___x_2890_;
v___y_2884_ = v___y_2887_;
goto v___jp_2881_;
}
else
{
if (v___y_2887_ == 0)
{
v___y_2882_ = v___y_2888_;
v___y_2883_ = v___x_2890_;
v___y_2884_ = v___y_2887_;
goto v___jp_2881_;
}
else
{
uint32_t v___x_2891_;
v___x_2891_ = 256;
v___y_2875_ = v___y_2888_;
v___y_2876_ = v___x_2890_;
v___y_2877_ = v___y_2887_;
v___y_2878_ = v___x_2891_;
goto v___jp_2874_;
}
}
}
v___jp_2892_:
{
uint8_t v___x_2894_; uint8_t v___x_2895_;
v___x_2894_ = 3;
v___x_2895_ = lean_uint8_dec_le(v_stateKind_2838_, v___x_2894_);
if (v___x_2895_ == 0)
{
uint32_t v___x_2896_;
v___x_2896_ = 0;
v___y_2887_ = v___y_2893_;
v___y_2888_ = v___x_2896_;
goto v___jp_2886_;
}
else
{
uint32_t v___x_2897_;
v___x_2897_ = 1;
v___y_2887_ = v___y_2893_;
v___y_2888_ = v___x_2897_;
goto v___jp_2886_;
}
}
}
}

LEAN_EXPORT uint32_t orb_send_flow_step(uint8_t v_isBusy_2909_, uint8_t v_hasNonEmptyText_2910_, uint8_t v_canQueue_2911_, uint8_t v_awaitingAck_2912_, uint8_t v_isDraining_2913_, uint8_t v_pendingCount_2914_, uint32_t v_httpStatus_2915_){
_start:
{
uint32_t v___y_2917_; uint32_t v___y_2918_; uint32_t v___y_2919_; uint32_t v___y_2925_; uint32_t v___y_2926_; uint32_t v___y_2929_; uint32_t v___y_2930_; uint32_t v___y_2940_; uint32_t v___y_2941_; uint32_t v___y_2948_; uint8_t v___x_2950_; uint32_t v___y_2952_; uint8_t v___x_2957_;
v___x_2950_ = 0;
v___x_2957_ = lean_uint8_dec_eq(v_hasNonEmptyText_2910_, v___x_2950_);
if (v___x_2957_ == 0)
{
uint8_t v___x_2958_;
v___x_2958_ = lean_uint8_dec_eq(v_isBusy_2909_, v___x_2950_);
if (v___x_2958_ == 0)
{
uint8_t v___x_2959_; uint8_t v___x_2960_;
v___x_2959_ = 1;
v___x_2960_ = lean_uint8_dec_eq(v_canQueue_2911_, v___x_2959_);
if (v___x_2960_ == 0)
{
uint32_t v___x_2961_;
v___x_2961_ = 0;
v___y_2952_ = v___x_2961_;
goto v___jp_2951_;
}
else
{
uint32_t v___x_2962_;
v___x_2962_ = 2;
v___y_2952_ = v___x_2962_;
goto v___jp_2951_;
}
}
else
{
uint32_t v___x_2963_;
v___x_2963_ = 1;
v___y_2952_ = v___x_2963_;
goto v___jp_2951_;
}
}
else
{
uint32_t v___x_2964_;
v___x_2964_ = 0;
v___y_2952_ = v___x_2964_;
goto v___jp_2951_;
}
v___jp_2916_:
{
uint32_t v___x_2920_; uint32_t v___x_2921_; uint32_t v___x_2922_; uint32_t v___x_2923_;
v___x_2920_ = lean_uint32_lor(v___y_2918_, v___y_2917_);
v___x_2921_ = 16;
v___x_2922_ = lean_uint32_shift_left(v___y_2919_, v___x_2921_);
v___x_2923_ = lean_uint32_lor(v___x_2920_, v___x_2922_);
return v___x_2923_;
}
v___jp_2924_:
{
uint32_t v___x_2927_;
v___x_2927_ = 2;
v___y_2917_ = v___y_2926_;
v___y_2918_ = v___y_2925_;
v___y_2919_ = v___x_2927_;
goto v___jp_2916_;
}
v___jp_2928_:
{
uint32_t v___x_2931_; uint8_t v___x_2932_;
v___x_2931_ = 404;
v___x_2932_ = lean_uint32_dec_eq(v_httpStatus_2915_, v___x_2931_);
if (v___x_2932_ == 0)
{
uint32_t v___x_2933_; uint8_t v___x_2934_;
v___x_2933_ = 405;
v___x_2934_ = lean_uint32_dec_eq(v_httpStatus_2915_, v___x_2933_);
if (v___x_2934_ == 0)
{
uint32_t v___x_2935_; uint8_t v___x_2936_;
v___x_2935_ = 409;
v___x_2936_ = lean_uint32_dec_eq(v_httpStatus_2915_, v___x_2935_);
if (v___x_2936_ == 0)
{
uint32_t v___x_2937_;
v___x_2937_ = 0;
v___y_2917_ = v___y_2930_;
v___y_2918_ = v___y_2929_;
v___y_2919_ = v___x_2937_;
goto v___jp_2916_;
}
else
{
uint32_t v___x_2938_;
v___x_2938_ = 3;
v___y_2917_ = v___y_2930_;
v___y_2918_ = v___y_2929_;
v___y_2919_ = v___x_2938_;
goto v___jp_2916_;
}
}
else
{
v___y_2925_ = v___y_2929_;
v___y_2926_ = v___y_2930_;
goto v___jp_2924_;
}
}
else
{
v___y_2925_ = v___y_2929_;
v___y_2926_ = v___y_2930_;
goto v___jp_2924_;
}
}
v___jp_2939_:
{
uint32_t v___x_2942_; uint8_t v___x_2943_;
v___x_2942_ = 200;
v___x_2943_ = lean_uint32_dec_le(v___x_2942_, v_httpStatus_2915_);
if (v___x_2943_ == 0)
{
v___y_2929_ = v___y_2940_;
v___y_2930_ = v___y_2941_;
goto v___jp_2928_;
}
else
{
uint32_t v___x_2944_; uint8_t v___x_2945_;
v___x_2944_ = 300;
v___x_2945_ = lean_uint32_dec_lt(v_httpStatus_2915_, v___x_2944_);
if (v___x_2945_ == 0)
{
v___y_2929_ = v___y_2940_;
v___y_2930_ = v___y_2941_;
goto v___jp_2928_;
}
else
{
uint32_t v___x_2946_;
v___x_2946_ = 1;
v___y_2917_ = v___y_2941_;
v___y_2918_ = v___y_2940_;
v___y_2919_ = v___x_2946_;
goto v___jp_2916_;
}
}
}
v___jp_2947_:
{
uint32_t v___x_2949_;
v___x_2949_ = 0;
v___y_2940_ = v___y_2948_;
v___y_2941_ = v___x_2949_;
goto v___jp_2939_;
}
v___jp_2951_:
{
uint8_t v___x_2953_;
v___x_2953_ = lean_uint8_dec_lt(v___x_2950_, v_pendingCount_2914_);
if (v___x_2953_ == 0)
{
v___y_2948_ = v___y_2952_;
goto v___jp_2947_;
}
else
{
uint8_t v___x_2954_;
v___x_2954_ = lean_uint8_dec_eq(v_awaitingAck_2912_, v___x_2950_);
if (v___x_2954_ == 0)
{
v___y_2948_ = v___y_2952_;
goto v___jp_2947_;
}
else
{
uint8_t v___x_2955_;
v___x_2955_ = lean_uint8_dec_eq(v_isDraining_2913_, v___x_2950_);
if (v___x_2955_ == 0)
{
v___y_2948_ = v___y_2952_;
goto v___jp_2947_;
}
else
{
uint32_t v___x_2956_;
v___x_2956_ = 256;
v___y_2940_ = v___y_2952_;
v___y_2941_ = v___x_2956_;
goto v___jp_2939_;
}
}
}
}
}
}

LEAN_EXPORT uint8_t orb_wire_validate_frame(uint32_t v_magic_2981_, uint32_t v_abiVersion_2982_, uint32_t v_schemaId_2983_, uint32_t v_expectedSchemaId_2984_, uint32_t v_totalLen_2985_, uint32_t v_payloadLen_2986_, uint32_t v_arenaOff_2987_, uint32_t v_arenaLen_2988_, uint32_t v_maxBudgetBytes_2989_, uint32_t v_outCap_2990_, uint32_t v_requiredOutBytes_2991_){
_start:
{
uint32_t v___x_2992_; uint8_t v___x_2993_;
v___x_2992_ = 1330790999;
v___x_2993_ = lean_uint32_dec_eq(v_magic_2981_, v___x_2992_);
if (v___x_2993_ == 0)
{
uint8_t v___x_2994_;
v___x_2994_ = 1;
return v___x_2994_;
}
else
{
uint32_t v___x_2995_; uint8_t v___x_2996_;
v___x_2995_ = 1;
v___x_2996_ = lean_uint32_dec_eq(v_abiVersion_2982_, v___x_2995_);
if (v___x_2996_ == 0)
{
uint8_t v___x_2997_;
v___x_2997_ = 1;
return v___x_2997_;
}
else
{
uint8_t v___x_2998_;
v___x_2998_ = lean_uint32_dec_eq(v_schemaId_2983_, v_expectedSchemaId_2984_);
if (v___x_2998_ == 0)
{
uint8_t v___x_2999_;
v___x_2999_ = 2;
return v___x_2999_;
}
else
{
uint32_t v___x_3000_; uint8_t v___x_3001_;
v___x_3000_ = 24;
v___x_3001_ = lean_uint32_dec_le(v___x_3000_, v_totalLen_2985_);
if (v___x_3001_ == 0)
{
uint8_t v___x_3002_;
v___x_3002_ = 3;
return v___x_3002_;
}
else
{
uint8_t v___x_3003_;
v___x_3003_ = lean_uint32_dec_le(v_totalLen_2985_, v_maxBudgetBytes_2989_);
if (v___x_3003_ == 0)
{
uint8_t v___x_3004_;
v___x_3004_ = 4;
return v___x_3004_;
}
else
{
uint32_t v___x_3005_; uint8_t v___x_3006_;
v___x_3005_ = lean_uint32_sub(v_totalLen_2985_, v___x_3000_);
v___x_3006_ = lean_uint32_dec_le(v_payloadLen_2986_, v___x_3005_);
if (v___x_3006_ == 0)
{
uint8_t v___x_3007_;
v___x_3007_ = 3;
return v___x_3007_;
}
else
{
uint8_t v___x_3008_;
v___x_3008_ = lean_uint32_dec_le(v_arenaOff_2987_, v_payloadLen_2986_);
if (v___x_3008_ == 0)
{
uint8_t v___x_3009_;
v___x_3009_ = 3;
return v___x_3009_;
}
else
{
uint32_t v___x_3010_; uint8_t v___x_3011_;
v___x_3010_ = lean_uint32_sub(v_payloadLen_2986_, v_arenaOff_2987_);
v___x_3011_ = lean_uint32_dec_le(v_arenaLen_2988_, v___x_3010_);
if (v___x_3011_ == 0)
{
uint8_t v___x_3012_;
v___x_3012_ = 3;
return v___x_3012_;
}
else
{
uint8_t v___x_3013_;
v___x_3013_ = lean_uint32_dec_le(v_requiredOutBytes_2991_, v_outCap_2990_);
if (v___x_3013_ == 0)
{
uint8_t v___x_3014_;
v___x_3014_ = 5;
return v___x_3014_;
}
else
{
uint8_t v___x_3015_;
v___x_3015_ = 0;
return v___x_3015_;
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

LEAN_EXPORT uint64_t orb_wire_pack_record(uint8_t v_tag_3040_, uint8_t v_flags_3041_, uint32_t v_len16_3042_, uint32_t v_payload32_3043_){
_start:
{
uint32_t v___x_3044_; uint32_t v___x_3045_; uint32_t v___x_3046_; uint32_t v___x_3047_; uint32_t v___x_3048_; uint32_t v___x_3049_; uint32_t v___x_3050_; uint32_t v___x_3051_; uint32_t v___x_3052_; uint32_t v_lo32_3053_; uint64_t v___x_3054_; uint64_t v___x_3055_; uint64_t v___x_3056_; uint64_t v___x_3057_; uint64_t v___x_3058_;
v___x_3044_ = lean_uint8_to_uint32(v_tag_3040_);
v___x_3045_ = lean_uint8_to_uint32(v_flags_3041_);
v___x_3046_ = 8;
v___x_3047_ = lean_uint32_shift_left(v___x_3045_, v___x_3046_);
v___x_3048_ = lean_uint32_lor(v___x_3044_, v___x_3047_);
v___x_3049_ = 65535;
v___x_3050_ = lean_uint32_land(v_len16_3042_, v___x_3049_);
v___x_3051_ = 16;
v___x_3052_ = lean_uint32_shift_left(v___x_3050_, v___x_3051_);
v_lo32_3053_ = lean_uint32_lor(v___x_3048_, v___x_3052_);
v___x_3054_ = lean_uint32_to_uint64(v_lo32_3053_);
v___x_3055_ = lean_uint32_to_uint64(v_payload32_3043_);
v___x_3056_ = 32ULL;
v___x_3057_ = lean_uint64_shift_left(v___x_3055_, v___x_3056_);
v___x_3058_ = lean_uint64_lor(v___x_3054_, v___x_3057_);
return v___x_3058_;
}
}

LEAN_EXPORT uint8_t orb_wire_schema_migrate_step(uint32_t v_fromSchema_3105_, uint32_t v_toSchema_3106_, uint32_t v_currentSchema_3107_, uint64_t v_payloadBytes_3108_, uint64_t v_maxBytes_3109_){
_start:
{
uint8_t v___x_3110_;
v___x_3110_ = lean_uint32_dec_eq(v_fromSchema_3105_, v_currentSchema_3107_);
if (v___x_3110_ == 0)
{
uint8_t v___x_3111_;
v___x_3111_ = 0;
return v___x_3111_;
}
else
{
uint8_t v___x_3112_;
v___x_3112_ = lean_uint32_dec_lt(v_fromSchema_3105_, v_toSchema_3106_);
if (v___x_3112_ == 0)
{
uint8_t v___x_3113_;
v___x_3113_ = 0;
return v___x_3113_;
}
else
{
uint32_t v___x_3114_; uint32_t v___x_3115_; uint8_t v___x_3116_;
v___x_3114_ = lean_uint32_sub(v_toSchema_3106_, v_fromSchema_3105_);
v___x_3115_ = 1;
v___x_3116_ = lean_uint32_dec_eq(v___x_3114_, v___x_3115_);
if (v___x_3116_ == 0)
{
uint8_t v___x_3117_;
v___x_3117_ = 0;
return v___x_3117_;
}
else
{
uint64_t v___x_3118_; uint8_t v___x_3119_;
v___x_3118_ = 0ULL;
v___x_3119_ = lean_uint64_dec_lt(v___x_3118_, v_payloadBytes_3108_);
if (v___x_3119_ == 0)
{
uint8_t v___x_3120_;
v___x_3120_ = 0;
return v___x_3120_;
}
else
{
uint8_t v___x_3121_;
v___x_3121_ = lean_uint64_dec_le(v_payloadBytes_3108_, v_maxBytes_3109_);
if (v___x_3121_ == 0)
{
uint8_t v___x_3122_;
v___x_3122_ = 0;
return v___x_3122_;
}
else
{
uint8_t v___x_3123_;
v___x_3123_ = 1;
return v___x_3123_;
}
}
}
}
}
}
}

LEAN_EXPORT uint8_t orb_effect_admissible(uint8_t v_effectKind_3136_, uint8_t v_hasValidLease_3137_, uint8_t v_sessionCreated_3138_, uint8_t v_lineageVerified_3139_, uint8_t v_isArchived_3140_, uint8_t v_idempotencyFresh_3141_, uint8_t v_accountBound_3142_, uint8_t v_accountRejected_3143_, uint8_t v_firstByteLocked_3144_, uint8_t v_grammarAllowed_3145_, uint8_t v_envScrubbed_3146_, uint8_t v_budgetOk_3147_){
_start:
{
uint8_t v___x_3148_; uint8_t v___x_3149_;
v___x_3148_ = 1;
v___x_3149_ = lean_uint8_dec_eq(v_budgetOk_3147_, v___x_3148_);
if (v___x_3149_ == 0)
{
uint8_t v___x_3150_;
v___x_3150_ = 0;
return v___x_3150_;
}
else
{
uint8_t v___x_3151_; uint8_t v___x_3152_;
v___x_3151_ = 0;
v___x_3152_ = lean_uint8_dec_eq(v_effectKind_3136_, v___x_3151_);
if (v___x_3152_ == 0)
{
uint8_t v___x_3153_;
v___x_3153_ = lean_uint8_dec_eq(v_effectKind_3136_, v___x_3148_);
if (v___x_3153_ == 0)
{
uint8_t v___x_3154_; uint8_t v___x_3155_;
v___x_3154_ = 2;
v___x_3155_ = lean_uint8_dec_eq(v_effectKind_3136_, v___x_3154_);
if (v___x_3155_ == 0)
{
uint8_t v___x_3156_; uint8_t v___x_3157_;
v___x_3156_ = 3;
v___x_3157_ = lean_uint8_dec_eq(v_effectKind_3136_, v___x_3156_);
if (v___x_3157_ == 0)
{
uint8_t v___x_3158_; uint8_t v___x_3159_;
v___x_3158_ = 4;
v___x_3159_ = lean_uint8_dec_eq(v_effectKind_3136_, v___x_3158_);
if (v___x_3159_ == 0)
{
uint8_t v___x_3160_; uint8_t v___x_3161_;
v___x_3160_ = 5;
v___x_3161_ = lean_uint8_dec_eq(v_effectKind_3136_, v___x_3160_);
if (v___x_3161_ == 0)
{
return v___x_3151_;
}
else
{
uint8_t v___x_3162_;
v___x_3162_ = lean_uint8_dec_eq(v_hasValidLease_3137_, v___x_3148_);
if (v___x_3162_ == 0)
{
return v___x_3151_;
}
else
{
uint8_t v___x_3163_;
v___x_3163_ = lean_uint8_dec_eq(v_idempotencyFresh_3141_, v___x_3148_);
if (v___x_3163_ == 0)
{
return v___x_3151_;
}
else
{
return v___x_3148_;
}
}
}
}
else
{
uint8_t v___x_3164_;
v___x_3164_ = lean_uint8_dec_eq(v_grammarAllowed_3145_, v___x_3148_);
if (v___x_3164_ == 0)
{
return v___x_3151_;
}
else
{
uint8_t v___x_3165_;
v___x_3165_ = lean_uint8_dec_eq(v_envScrubbed_3146_, v___x_3148_);
if (v___x_3165_ == 0)
{
return v___x_3151_;
}
else
{
uint8_t v___x_3166_;
v___x_3166_ = lean_uint8_dec_eq(v_hasValidLease_3137_, v___x_3148_);
if (v___x_3166_ == 0)
{
return v___x_3151_;
}
else
{
uint8_t v___x_3167_;
v___x_3167_ = lean_uint8_dec_eq(v_isArchived_3140_, v___x_3151_);
if (v___x_3167_ == 0)
{
return v___x_3151_;
}
else
{
return v___x_3148_;
}
}
}
}
}
}
else
{
uint8_t v___x_3168_;
v___x_3168_ = lean_uint8_dec_eq(v_accountBound_3142_, v___x_3148_);
if (v___x_3168_ == 0)
{
return v___x_3151_;
}
else
{
uint8_t v___x_3169_;
v___x_3169_ = lean_uint8_dec_eq(v_accountRejected_3143_, v___x_3151_);
if (v___x_3169_ == 0)
{
return v___x_3151_;
}
else
{
uint8_t v___x_3170_;
v___x_3170_ = lean_uint8_dec_eq(v_firstByteLocked_3144_, v___x_3151_);
if (v___x_3170_ == 0)
{
return v___x_3151_;
}
else
{
return v___x_3148_;
}
}
}
}
}
else
{
uint8_t v___x_3171_;
v___x_3171_ = lean_uint8_dec_eq(v_hasValidLease_3137_, v___x_3148_);
if (v___x_3171_ == 0)
{
return v___x_3151_;
}
else
{
uint8_t v___x_3172_;
v___x_3172_ = lean_uint8_dec_eq(v_sessionCreated_3138_, v___x_3148_);
if (v___x_3172_ == 0)
{
return v___x_3151_;
}
else
{
uint8_t v___x_3173_;
v___x_3173_ = lean_uint8_dec_eq(v_lineageVerified_3139_, v___x_3148_);
if (v___x_3173_ == 0)
{
return v___x_3151_;
}
else
{
uint8_t v___x_3174_;
v___x_3174_ = lean_uint8_dec_eq(v_isArchived_3140_, v___x_3151_);
if (v___x_3174_ == 0)
{
return v___x_3151_;
}
else
{
return v___x_3148_;
}
}
}
}
}
}
else
{
uint8_t v___x_3175_;
v___x_3175_ = lean_uint8_dec_eq(v_hasValidLease_3137_, v___x_3148_);
if (v___x_3175_ == 0)
{
return v___x_3151_;
}
else
{
uint8_t v___x_3176_;
v___x_3176_ = lean_uint8_dec_eq(v_isArchived_3140_, v___x_3151_);
if (v___x_3176_ == 0)
{
return v___x_3151_;
}
else
{
uint8_t v___x_3177_;
v___x_3177_ = lean_uint8_dec_eq(v_idempotencyFresh_3141_, v___x_3148_);
if (v___x_3177_ == 0)
{
return v___x_3151_;
}
else
{
return v___x_3148_;
}
}
}
}
}
else
{
return v___x_3148_;
}
}
}
}

LEAN_EXPORT uint64_t orb_provider_pool_step(uint8_t v_hasBoundAccount_3204_, uint32_t v_boundAccountId_3205_, uint32_t v_candidateAccountId_3206_, uint8_t v_isRejected_3207_, uint8_t v_firstByteSent_3208_, uint8_t v_isFailoverAttempt_3209_, uint32_t v_attempts_3210_, uint32_t v_maxAttempts_3211_, uint64_t v_nowEpoch_3212_, uint64_t v_resetEpoch_3213_){
_start:
{
uint32_t v___y_3215_; uint32_t v___y_3216_; uint32_t v___y_3223_; uint32_t v___y_3226_; uint32_t v___y_3230_; uint32_t v___y_3233_; uint8_t v___x_3235_; uint32_t v___y_3237_; uint32_t v___y_3242_; uint8_t v___y_3243_; uint8_t v___y_3247_; uint32_t v___y_3248_; uint32_t v___y_3254_; uint8_t v___y_3255_; uint32_t v___y_3256_; uint32_t v___y_3261_; uint8_t v___y_3262_; uint8_t v___y_3263_; uint32_t v___y_3269_; uint8_t v___y_3270_; uint32_t v___y_3274_; uint8_t v___y_3275_; uint8_t v___y_3276_; uint32_t v___y_3280_; uint8_t v___y_3281_; uint8_t v___y_3282_; uint32_t v___y_3286_; uint8_t v___y_3287_; uint8_t v___x_3294_; uint32_t v___y_3296_;
v___x_3235_ = 1;
v___x_3294_ = lean_uint8_dec_eq(v_firstByteSent_3208_, v___x_3235_);
if (v___x_3294_ == 0)
{
uint32_t v___x_3298_;
v___x_3298_ = 0;
v___y_3296_ = v___x_3298_;
goto v___jp_3295_;
}
else
{
uint32_t v___x_3299_;
v___x_3299_ = 65536;
v___y_3296_ = v___x_3299_;
goto v___jp_3295_;
}
v___jp_3214_:
{
uint64_t v___x_3217_; uint64_t v___x_3218_; uint64_t v___x_3219_; uint64_t v___x_3220_; uint64_t v___x_3221_;
v___x_3217_ = lean_uint32_to_uint64(v___y_3215_);
v___x_3218_ = lean_uint32_to_uint64(v___y_3216_);
v___x_3219_ = 32ULL;
v___x_3220_ = lean_uint64_shift_left(v___x_3218_, v___x_3219_);
v___x_3221_ = lean_uint64_lor(v___x_3217_, v___x_3220_);
return v___x_3221_;
}
v___jp_3222_:
{
uint32_t v___x_3224_;
v___x_3224_ = 0;
v___y_3215_ = v___y_3223_;
v___y_3216_ = v___x_3224_;
goto v___jp_3214_;
}
v___jp_3225_:
{
uint32_t v___x_3227_; uint8_t v___x_3228_;
v___x_3227_ = 0;
v___x_3228_ = lean_uint32_dec_eq(v_candidateAccountId_3206_, v___x_3227_);
if (v___x_3228_ == 0)
{
v___y_3215_ = v___y_3226_;
v___y_3216_ = v_candidateAccountId_3206_;
goto v___jp_3214_;
}
else
{
v___y_3215_ = v___y_3226_;
v___y_3216_ = v___x_3227_;
goto v___jp_3214_;
}
}
v___jp_3229_:
{
uint32_t v___x_3231_;
v___x_3231_ = 0;
v___y_3215_ = v___y_3230_;
v___y_3216_ = v___x_3231_;
goto v___jp_3214_;
}
v___jp_3232_:
{
uint32_t v___x_3234_;
v___x_3234_ = 0;
v___y_3215_ = v___y_3233_;
v___y_3216_ = v___x_3234_;
goto v___jp_3214_;
}
v___jp_3236_:
{
uint8_t v___x_3238_;
v___x_3238_ = lean_uint8_dec_eq(v_isRejected_3207_, v___x_3235_);
if (v___x_3238_ == 0)
{
v___y_3226_ = v___y_3237_;
goto v___jp_3225_;
}
else
{
uint8_t v___x_3239_;
v___x_3239_ = lean_uint64_dec_lt(v_nowEpoch_3212_, v_resetEpoch_3213_);
if (v___x_3239_ == 0)
{
v___y_3226_ = v___y_3237_;
goto v___jp_3225_;
}
else
{
uint32_t v___x_3240_;
v___x_3240_ = 0;
v___y_3215_ = v___y_3237_;
v___y_3216_ = v___x_3240_;
goto v___jp_3214_;
}
}
}
v___jp_3241_:
{
uint8_t v___x_3244_;
v___x_3244_ = lean_uint8_dec_eq(v_hasBoundAccount_3204_, v___x_3235_);
if (v___x_3244_ == 0)
{
v___y_3237_ = v___y_3242_;
goto v___jp_3236_;
}
else
{
uint8_t v___x_3245_;
v___x_3245_ = lean_uint32_dec_eq(v_candidateAccountId_3206_, v_boundAccountId_3205_);
if (v___x_3245_ == 0)
{
v___y_3230_ = v___y_3242_;
goto v___jp_3229_;
}
else
{
if (v___y_3243_ == 0)
{
v___y_3237_ = v___y_3242_;
goto v___jp_3236_;
}
else
{
v___y_3230_ = v___y_3242_;
goto v___jp_3229_;
}
}
}
}
v___jp_3246_:
{
if (v___y_3247_ == 0)
{
uint8_t v___x_3249_;
v___x_3249_ = lean_uint8_dec_eq(v_isFailoverAttempt_3209_, v___x_3235_);
if (v___x_3249_ == 0)
{
v___y_3242_ = v___y_3248_;
v___y_3243_ = v___x_3249_;
goto v___jp_3241_;
}
else
{
uint32_t v___x_3250_; uint8_t v___x_3251_;
v___x_3250_ = 1;
v___x_3251_ = lean_uint32_dec_le(v___x_3250_, v_maxAttempts_3211_);
if (v___x_3251_ == 0)
{
v___y_3233_ = v___y_3248_;
goto v___jp_3232_;
}
else
{
uint8_t v___x_3252_;
v___x_3252_ = lean_uint32_dec_lt(v_attempts_3210_, v_maxAttempts_3211_);
if (v___x_3252_ == 0)
{
v___y_3233_ = v___y_3248_;
goto v___jp_3232_;
}
else
{
v___y_3242_ = v___y_3248_;
v___y_3243_ = v___y_3247_;
goto v___jp_3241_;
}
}
}
}
else
{
v___y_3223_ = v___y_3248_;
goto v___jp_3222_;
}
}
v___jp_3253_:
{
uint32_t v___x_3257_; uint32_t v___x_3258_; uint32_t v___x_3259_;
v___x_3257_ = 256;
v___x_3258_ = lean_uint32_add(v___y_3256_, v___x_3257_);
v___x_3259_ = lean_uint32_add(v___x_3258_, v___y_3254_);
v___y_3247_ = v___y_3255_;
v___y_3248_ = v___x_3259_;
goto v___jp_3246_;
}
v___jp_3260_:
{
uint32_t v___x_3264_; uint8_t v___x_3265_;
v___x_3264_ = 0;
v___x_3265_ = lean_uint32_dec_eq(v_candidateAccountId_3206_, v___x_3264_);
if (v___x_3265_ == 0)
{
if (v___y_3263_ == 0)
{
uint32_t v___x_3266_;
v___x_3266_ = 2;
v___y_3254_ = v___y_3261_;
v___y_3255_ = v___y_3262_;
v___y_3256_ = v___x_3266_;
goto v___jp_3253_;
}
else
{
uint32_t v___x_3267_;
v___x_3267_ = 1;
v___y_3254_ = v___y_3261_;
v___y_3255_ = v___y_3262_;
v___y_3256_ = v___x_3267_;
goto v___jp_3253_;
}
}
else
{
v___y_3247_ = v___y_3262_;
v___y_3248_ = v___y_3261_;
goto v___jp_3246_;
}
}
v___jp_3268_:
{
uint32_t v___x_3271_; uint32_t v___x_3272_;
v___x_3271_ = 4;
v___x_3272_ = lean_uint32_add(v___x_3271_, v___y_3269_);
v___y_3247_ = v___y_3270_;
v___y_3248_ = v___x_3272_;
goto v___jp_3246_;
}
v___jp_3273_:
{
uint8_t v___x_3277_;
v___x_3277_ = lean_uint8_dec_eq(v_isRejected_3207_, v___x_3235_);
if (v___x_3277_ == 0)
{
v___y_3261_ = v___y_3274_;
v___y_3262_ = v___y_3275_;
v___y_3263_ = v___y_3276_;
goto v___jp_3260_;
}
else
{
uint8_t v___x_3278_;
v___x_3278_ = lean_uint64_dec_lt(v_nowEpoch_3212_, v_resetEpoch_3213_);
if (v___x_3278_ == 0)
{
v___y_3261_ = v___y_3274_;
v___y_3262_ = v___y_3275_;
v___y_3263_ = v___y_3276_;
goto v___jp_3260_;
}
else
{
v___y_3247_ = v___y_3275_;
v___y_3248_ = v___y_3274_;
goto v___jp_3246_;
}
}
}
v___jp_3279_:
{
uint8_t v___x_3283_;
v___x_3283_ = lean_uint8_dec_eq(v_hasBoundAccount_3204_, v___x_3235_);
if (v___x_3283_ == 0)
{
v___y_3274_ = v___y_3280_;
v___y_3275_ = v___y_3281_;
v___y_3276_ = v___x_3283_;
goto v___jp_3273_;
}
else
{
uint8_t v___x_3284_;
v___x_3284_ = lean_uint32_dec_eq(v_candidateAccountId_3206_, v_boundAccountId_3205_);
if (v___x_3284_ == 0)
{
v___y_3247_ = v___y_3281_;
v___y_3248_ = v___y_3280_;
goto v___jp_3246_;
}
else
{
if (v___y_3282_ == 0)
{
v___y_3274_ = v___y_3280_;
v___y_3275_ = v___y_3281_;
v___y_3276_ = v___x_3283_;
goto v___jp_3273_;
}
else
{
v___y_3247_ = v___y_3281_;
v___y_3248_ = v___y_3280_;
goto v___jp_3246_;
}
}
}
}
v___jp_3285_:
{
if (v___y_3287_ == 0)
{
uint8_t v___x_3288_;
v___x_3288_ = lean_uint8_dec_eq(v_isFailoverAttempt_3209_, v___x_3235_);
if (v___x_3288_ == 0)
{
v___y_3280_ = v___y_3286_;
v___y_3281_ = v___y_3287_;
v___y_3282_ = v___x_3288_;
goto v___jp_3279_;
}
else
{
uint32_t v___x_3289_; uint8_t v___x_3290_;
v___x_3289_ = 1;
v___x_3290_ = lean_uint32_dec_le(v___x_3289_, v_maxAttempts_3211_);
if (v___x_3290_ == 0)
{
v___y_3269_ = v___y_3286_;
v___y_3270_ = v___y_3287_;
goto v___jp_3268_;
}
else
{
uint8_t v___x_3291_;
v___x_3291_ = lean_uint32_dec_lt(v_attempts_3210_, v_maxAttempts_3211_);
if (v___x_3291_ == 0)
{
v___y_3269_ = v___y_3286_;
v___y_3270_ = v___y_3287_;
goto v___jp_3268_;
}
else
{
v___y_3280_ = v___y_3286_;
v___y_3281_ = v___y_3287_;
v___y_3282_ = v___y_3287_;
goto v___jp_3279_;
}
}
}
}
else
{
uint32_t v___x_3292_; uint32_t v___x_3293_;
v___x_3292_ = 3;
v___x_3293_ = lean_uint32_add(v___x_3292_, v___y_3286_);
v___y_3223_ = v___x_3293_;
goto v___jp_3222_;
}
}
v___jp_3295_:
{
if (v___x_3294_ == 0)
{
v___y_3286_ = v___y_3296_;
v___y_3287_ = v___x_3294_;
goto v___jp_3285_;
}
else
{
uint8_t v___x_3297_;
v___x_3297_ = lean_uint8_dec_eq(v_isFailoverAttempt_3209_, v___x_3235_);
v___y_3286_ = v___y_3296_;
v___y_3287_ = v___x_3297_;
goto v___jp_3285_;
}
}
}
}

LEAN_EXPORT uint64_t orb_route_argmin_step(uint8_t v_hasBest_3322_, uint32_t v_bestId_3323_, uint64_t v_bestScore_3324_, uint32_t v_candId_3325_, uint64_t v_candScore_3326_, uint8_t v_candAdmissible_3327_){
_start:
{
uint32_t v___y_3329_; uint32_t v___y_3330_; uint8_t v___x_3336_; uint32_t v___y_3338_; uint8_t v___y_3342_; uint8_t v___x_3347_;
v___x_3336_ = 1;
v___x_3347_ = lean_uint8_dec_eq(v_candAdmissible_3327_, v___x_3336_);
if (v___x_3347_ == 0)
{
v___y_3342_ = v___x_3347_;
goto v___jp_3341_;
}
else
{
uint8_t v___x_3348_; uint8_t v___x_3349_;
v___x_3348_ = 0;
v___x_3349_ = lean_uint8_dec_eq(v_hasBest_3322_, v___x_3348_);
if (v___x_3349_ == 0)
{
uint8_t v___x_3350_;
v___x_3350_ = lean_uint64_dec_lt(v_candScore_3326_, v_bestScore_3324_);
v___y_3342_ = v___x_3350_;
goto v___jp_3341_;
}
else
{
v___y_3342_ = v___x_3349_;
goto v___jp_3341_;
}
}
v___jp_3328_:
{
uint64_t v___x_3331_; uint64_t v___x_3332_; uint64_t v___x_3333_; uint64_t v___x_3334_; uint64_t v___x_3335_;
v___x_3331_ = lean_uint32_to_uint64(v___y_3329_);
v___x_3332_ = lean_uint32_to_uint64(v___y_3330_);
v___x_3333_ = 32ULL;
v___x_3334_ = lean_uint64_shift_left(v___x_3332_, v___x_3333_);
v___x_3335_ = lean_uint64_lor(v___x_3331_, v___x_3334_);
return v___x_3335_;
}
v___jp_3337_:
{
uint8_t v___x_3339_;
v___x_3339_ = lean_uint8_dec_eq(v_hasBest_3322_, v___x_3336_);
if (v___x_3339_ == 0)
{
uint32_t v___x_3340_;
v___x_3340_ = 0;
v___y_3329_ = v___y_3338_;
v___y_3330_ = v___x_3340_;
goto v___jp_3328_;
}
else
{
v___y_3329_ = v___y_3338_;
v___y_3330_ = v_bestId_3323_;
goto v___jp_3328_;
}
}
v___jp_3341_:
{
if (v___y_3342_ == 0)
{
uint8_t v___x_3343_;
v___x_3343_ = lean_uint8_dec_eq(v_hasBest_3322_, v___x_3336_);
if (v___x_3343_ == 0)
{
uint32_t v___x_3344_;
v___x_3344_ = 0;
v___y_3338_ = v___x_3344_;
goto v___jp_3337_;
}
else
{
uint32_t v___x_3345_;
v___x_3345_ = 1;
v___y_3338_ = v___x_3345_;
goto v___jp_3337_;
}
}
else
{
uint32_t v___x_3346_;
v___x_3346_ = 257;
v___y_3329_ = v___x_3346_;
v___y_3330_ = v_candId_3325_;
goto v___jp_3328_;
}
}
}
}

LEAN_EXPORT uint64_t orb_mission_control_step(uint8_t v_isArchived_3365_, uint32_t v_activeTrackWriters_3366_, uint8_t v_hasLease_3367_, uint8_t v_msgAlreadyDelivered_3368_, uint8_t v_isResume_3369_, uint8_t v_sessionCreated_3370_, uint8_t v_lineageVerified_3371_, uint8_t v_rolloutExists_3372_, uint8_t v_hasFallbackPrompt_3373_){
_start:
{
uint32_t v___y_3375_; uint32_t v___y_3376_; uint32_t v___y_3383_; uint8_t v___x_3385_; uint32_t v___y_3387_; uint8_t v___x_3391_; uint32_t v___y_3393_;
v___x_3385_ = 1;
v___x_3391_ = lean_uint8_dec_eq(v_isArchived_3365_, v___x_3385_);
if (v___x_3391_ == 0)
{
uint8_t v___x_3412_;
v___x_3412_ = lean_uint8_dec_eq(v_msgAlreadyDelivered_3368_, v___x_3385_);
if (v___x_3412_ == 0)
{
uint8_t v___x_3413_;
v___x_3413_ = lean_uint8_dec_eq(v_hasLease_3367_, v___x_3385_);
if (v___x_3413_ == 0)
{
goto v___jp_3406_;
}
else
{
uint32_t v___x_3414_; uint8_t v___x_3415_;
v___x_3414_ = 0;
v___x_3415_ = lean_uint32_dec_eq(v_activeTrackWriters_3366_, v___x_3414_);
if (v___x_3415_ == 0)
{
goto v___jp_3406_;
}
else
{
uint8_t v___x_3416_;
v___x_3416_ = lean_uint8_dec_eq(v_isResume_3369_, v___x_3385_);
if (v___x_3416_ == 0)
{
uint32_t v___x_3417_;
v___x_3417_ = 257;
v___y_3393_ = v___x_3417_;
goto v___jp_3392_;
}
else
{
uint8_t v___x_3418_;
v___x_3418_ = lean_uint8_dec_eq(v_sessionCreated_3370_, v___x_3385_);
if (v___x_3418_ == 0)
{
goto v___jp_3408_;
}
else
{
uint8_t v___x_3419_;
v___x_3419_ = lean_uint8_dec_eq(v_lineageVerified_3371_, v___x_3385_);
if (v___x_3419_ == 0)
{
goto v___jp_3408_;
}
else
{
uint8_t v___x_3420_;
v___x_3420_ = lean_uint8_dec_eq(v_rolloutExists_3372_, v___x_3385_);
if (v___x_3420_ == 0)
{
goto v___jp_3408_;
}
else
{
uint32_t v___x_3421_;
v___x_3421_ = 258;
v___y_3393_ = v___x_3421_;
goto v___jp_3392_;
}
}
}
}
}
}
}
else
{
uint32_t v___x_3422_;
v___x_3422_ = 4;
v___y_3393_ = v___x_3422_;
goto v___jp_3392_;
}
}
else
{
uint32_t v___x_3423_;
v___x_3423_ = 65536;
v___y_3393_ = v___x_3423_;
goto v___jp_3392_;
}
v___jp_3374_:
{
uint64_t v___x_3377_; uint64_t v___x_3378_; uint64_t v___x_3379_; uint64_t v___x_3380_; uint64_t v___x_3381_;
v___x_3377_ = lean_uint32_to_uint64(v___y_3375_);
v___x_3378_ = lean_uint32_to_uint64(v___y_3376_);
v___x_3379_ = 32ULL;
v___x_3380_ = lean_uint64_shift_left(v___x_3378_, v___x_3379_);
v___x_3381_ = lean_uint64_lor(v___x_3377_, v___x_3380_);
return v___x_3381_;
}
v___jp_3382_:
{
uint32_t v___x_3384_;
v___x_3384_ = 0;
v___y_3375_ = v___y_3383_;
v___y_3376_ = v___x_3384_;
goto v___jp_3374_;
}
v___jp_3386_:
{
uint8_t v___x_3388_;
v___x_3388_ = lean_uint8_dec_eq(v_hasFallbackPrompt_3373_, v___x_3385_);
if (v___x_3388_ == 0)
{
uint32_t v___x_3389_;
v___x_3389_ = 0;
v___y_3375_ = v___y_3387_;
v___y_3376_ = v___x_3389_;
goto v___jp_3374_;
}
else
{
uint32_t v___x_3390_;
v___x_3390_ = 1;
v___y_3375_ = v___y_3387_;
v___y_3376_ = v___x_3390_;
goto v___jp_3374_;
}
}
v___jp_3392_:
{
if (v___x_3391_ == 0)
{
uint8_t v___x_3394_;
v___x_3394_ = lean_uint8_dec_eq(v_msgAlreadyDelivered_3368_, v___x_3385_);
if (v___x_3394_ == 0)
{
uint8_t v___x_3395_;
v___x_3395_ = lean_uint8_dec_eq(v_hasLease_3367_, v___x_3385_);
if (v___x_3395_ == 0)
{
v___y_3383_ = v___y_3393_;
goto v___jp_3382_;
}
else
{
uint32_t v___x_3396_; uint8_t v___x_3397_;
v___x_3396_ = 0;
v___x_3397_ = lean_uint32_dec_eq(v_activeTrackWriters_3366_, v___x_3396_);
if (v___x_3397_ == 0)
{
v___y_3383_ = v___y_3393_;
goto v___jp_3382_;
}
else
{
uint8_t v___x_3398_;
v___x_3398_ = lean_uint8_dec_eq(v_isResume_3369_, v___x_3385_);
if (v___x_3398_ == 0)
{
uint32_t v___x_3399_;
v___x_3399_ = 1;
v___y_3375_ = v___y_3393_;
v___y_3376_ = v___x_3399_;
goto v___jp_3374_;
}
else
{
uint8_t v___x_3400_;
v___x_3400_ = lean_uint8_dec_eq(v_sessionCreated_3370_, v___x_3385_);
if (v___x_3400_ == 0)
{
v___y_3387_ = v___y_3393_;
goto v___jp_3386_;
}
else
{
uint8_t v___x_3401_;
v___x_3401_ = lean_uint8_dec_eq(v_lineageVerified_3371_, v___x_3385_);
if (v___x_3401_ == 0)
{
v___y_3387_ = v___y_3393_;
goto v___jp_3386_;
}
else
{
uint8_t v___x_3402_;
v___x_3402_ = lean_uint8_dec_eq(v_rolloutExists_3372_, v___x_3385_);
if (v___x_3402_ == 0)
{
v___y_3387_ = v___y_3393_;
goto v___jp_3386_;
}
else
{
uint32_t v___x_3403_;
v___x_3403_ = 1;
v___y_3375_ = v___y_3393_;
v___y_3376_ = v___x_3403_;
goto v___jp_3374_;
}
}
}
}
}
}
}
else
{
uint32_t v___x_3404_;
v___x_3404_ = 0;
v___y_3375_ = v___y_3393_;
v___y_3376_ = v___x_3404_;
goto v___jp_3374_;
}
}
else
{
uint32_t v___x_3405_;
v___x_3405_ = 0;
v___y_3375_ = v___y_3393_;
v___y_3376_ = v___x_3405_;
goto v___jp_3374_;
}
}
v___jp_3406_:
{
uint32_t v___x_3407_;
v___x_3407_ = 5;
v___y_3393_ = v___x_3407_;
goto v___jp_3392_;
}
v___jp_3408_:
{
uint8_t v___x_3409_;
v___x_3409_ = lean_uint8_dec_eq(v_hasFallbackPrompt_3373_, v___x_3385_);
if (v___x_3409_ == 0)
{
uint32_t v___x_3410_;
v___x_3410_ = 6;
v___y_3393_ = v___x_3410_;
goto v___jp_3392_;
}
else
{
uint32_t v___x_3411_;
v___x_3411_ = 771;
v___y_3393_ = v___x_3411_;
goto v___jp_3392_;
}
}
}
}

LEAN_EXPORT uint64_t orb_fork_home_step(uint8_t v_isForkOrSide_3494_, uint8_t v_sourceExists_3495_, uint8_t v_sourceIsSymlink_3496_, uint8_t v_sameWorkspace_3497_, uint8_t v_sameNode_3498_, uint8_t v_hasCommittedTransfer_3499_, uint8_t v_requestedOverrideHome_3500_){
_start:
{
uint32_t v___y_3502_; uint32_t v___y_3503_; uint8_t v___y_3510_; uint8_t v___y_3511_; uint32_t v___y_3512_; uint8_t v___x_3516_; uint8_t v___y_3518_; uint8_t v___x_3526_;
v___x_3516_ = 1;
v___x_3526_ = lean_uint8_dec_eq(v_sourceExists_3495_, v___x_3516_);
if (v___x_3526_ == 0)
{
v___y_3518_ = v___x_3526_;
goto v___jp_3517_;
}
else
{
uint8_t v___x_3527_; uint8_t v___x_3528_;
v___x_3527_ = 0;
v___x_3528_ = lean_uint8_dec_eq(v_sourceIsSymlink_3496_, v___x_3527_);
if (v___x_3528_ == 0)
{
v___y_3518_ = v___x_3528_;
goto v___jp_3517_;
}
else
{
uint8_t v___x_3529_;
v___x_3529_ = lean_uint8_dec_eq(v_sameWorkspace_3497_, v___x_3516_);
if (v___x_3529_ == 0)
{
v___y_3518_ = v___x_3529_;
goto v___jp_3517_;
}
else
{
uint8_t v___x_3530_;
v___x_3530_ = lean_uint8_dec_eq(v_sameNode_3498_, v___x_3516_);
v___y_3518_ = v___x_3530_;
goto v___jp_3517_;
}
}
}
v___jp_3501_:
{
uint64_t v___x_3504_; uint64_t v___x_3505_; uint64_t v___x_3506_; uint64_t v___x_3507_; uint64_t v___x_3508_;
v___x_3504_ = lean_uint32_to_uint64(v___y_3502_);
v___x_3505_ = lean_uint32_to_uint64(v___y_3503_);
v___x_3506_ = 32ULL;
v___x_3507_ = lean_uint64_shift_left(v___x_3505_, v___x_3506_);
v___x_3508_ = lean_uint64_lor(v___x_3504_, v___x_3507_);
return v___x_3508_;
}
v___jp_3509_:
{
if (v___y_3510_ == 0)
{
if (v___y_3511_ == 0)
{
uint32_t v___x_3513_;
v___x_3513_ = 78;
v___y_3502_ = v___y_3512_;
v___y_3503_ = v___x_3513_;
goto v___jp_3501_;
}
else
{
uint32_t v___x_3514_;
v___x_3514_ = 0;
v___y_3502_ = v___y_3512_;
v___y_3503_ = v___x_3514_;
goto v___jp_3501_;
}
}
else
{
uint32_t v___x_3515_;
v___x_3515_ = 0;
v___y_3502_ = v___y_3512_;
v___y_3503_ = v___x_3515_;
goto v___jp_3501_;
}
}
v___jp_3517_:
{
uint8_t v___x_3519_; uint8_t v___x_3520_;
v___x_3519_ = 0;
v___x_3520_ = lean_uint8_dec_eq(v_isForkOrSide_3494_, v___x_3519_);
if (v___x_3520_ == 0)
{
if (v___y_3518_ == 0)
{
uint32_t v___x_3521_;
v___x_3521_ = 131072;
v___y_3510_ = v___x_3520_;
v___y_3511_ = v___y_3518_;
v___y_3512_ = v___x_3521_;
goto v___jp_3509_;
}
else
{
uint8_t v___x_3522_;
v___x_3522_ = lean_uint8_dec_eq(v_hasCommittedTransfer_3499_, v___x_3516_);
if (v___x_3522_ == 0)
{
uint32_t v___x_3523_;
v___x_3523_ = 131842;
v___y_3510_ = v___x_3520_;
v___y_3511_ = v___y_3518_;
v___y_3512_ = v___x_3523_;
goto v___jp_3509_;
}
else
{
uint32_t v___x_3524_;
v___x_3524_ = 131843;
v___y_3510_ = v___x_3520_;
v___y_3511_ = v___y_3518_;
v___y_3512_ = v___x_3524_;
goto v___jp_3509_;
}
}
}
else
{
uint32_t v___x_3525_;
v___x_3525_ = 131329;
v___y_3510_ = v___x_3520_;
v___y_3511_ = v___y_3518_;
v___y_3512_ = v___x_3525_;
goto v___jp_3509_;
}
}
}
}

LEAN_EXPORT uint64_t orb_privd_command_step(uint8_t v_leaseValid_3547_, uint8_t v_grantScope_3548_, uint8_t v_commandClass_3549_, uint8_t v_unitMatchesAllowed_3550_, uint8_t v_hasShellMetacharOrFlagBypass_3551_, uint8_t v_hasPathTraversalOrSymlink_3552_, uint8_t v_hasUnsafeEnvVar_3553_, uint8_t v_requireForceCmd_3554_){
_start:
{
uint32_t v___y_3556_; uint32_t v___y_3557_; uint32_t v___y_3564_; uint8_t v___x_3573_; uint8_t v___x_3574_;
v___x_3573_ = 1;
v___x_3574_ = lean_uint8_dec_eq(v_leaseValid_3547_, v___x_3573_);
if (v___x_3574_ == 0)
{
goto v___jp_3569_;
}
else
{
uint8_t v___x_3575_; uint8_t v___x_3576_;
v___x_3575_ = 0;
v___x_3576_ = lean_uint8_dec_eq(v_hasShellMetacharOrFlagBypass_3551_, v___x_3575_);
if (v___x_3576_ == 0)
{
goto v___jp_3569_;
}
else
{
uint8_t v___x_3577_;
v___x_3577_ = lean_uint8_dec_eq(v_hasPathTraversalOrSymlink_3552_, v___x_3575_);
if (v___x_3577_ == 0)
{
goto v___jp_3569_;
}
else
{
uint8_t v___x_3578_;
v___x_3578_ = lean_uint8_dec_eq(v_hasUnsafeEnvVar_3553_, v___x_3575_);
if (v___x_3578_ == 0)
{
goto v___jp_3569_;
}
else
{
uint8_t v___x_3579_; uint8_t v___x_3591_;
v___x_3579_ = 2;
v___x_3591_ = lean_uint8_dec_le(v_grantScope_3548_, v___x_3579_);
if (v___x_3591_ == 0)
{
uint32_t v___x_3592_;
v___x_3592_ = 1536;
v___y_3564_ = v___x_3592_;
goto v___jp_3563_;
}
else
{
uint8_t v___x_3593_;
v___x_3593_ = lean_uint8_dec_eq(v_commandClass_3549_, v___x_3573_);
if (v___x_3593_ == 0)
{
uint8_t v___x_3594_;
v___x_3594_ = lean_uint8_dec_eq(v_commandClass_3549_, v___x_3579_);
if (v___x_3594_ == 0)
{
goto v___jp_3586_;
}
else
{
uint8_t v___x_3595_;
v___x_3595_ = lean_uint8_dec_le(v___x_3573_, v_grantScope_3548_);
if (v___x_3595_ == 0)
{
goto v___jp_3586_;
}
else
{
uint8_t v___x_3596_;
v___x_3596_ = lean_uint8_dec_eq(v_unitMatchesAllowed_3550_, v___x_3573_);
if (v___x_3596_ == 0)
{
goto v___jp_3586_;
}
else
{
uint32_t v___x_3597_;
v___x_3597_ = 1794;
v___y_3564_ = v___x_3597_;
goto v___jp_3563_;
}
}
}
}
else
{
uint32_t v___x_3598_;
v___x_3598_ = 1793;
v___y_3564_ = v___x_3598_;
goto v___jp_3563_;
}
}
v___jp_3580_:
{
uint8_t v___x_3581_; uint8_t v___x_3582_;
v___x_3581_ = 4;
v___x_3582_ = lean_uint8_dec_eq(v_commandClass_3549_, v___x_3581_);
if (v___x_3582_ == 0)
{
goto v___jp_3571_;
}
else
{
uint8_t v___x_3583_;
v___x_3583_ = lean_uint8_dec_eq(v_grantScope_3548_, v___x_3579_);
if (v___x_3583_ == 0)
{
goto v___jp_3571_;
}
else
{
uint8_t v___x_3584_;
v___x_3584_ = lean_uint8_dec_eq(v_requireForceCmd_3554_, v___x_3575_);
if (v___x_3584_ == 0)
{
goto v___jp_3571_;
}
else
{
uint32_t v___x_3585_;
v___x_3585_ = 1795;
v___y_3564_ = v___x_3585_;
goto v___jp_3563_;
}
}
}
}
v___jp_3586_:
{
uint8_t v___x_3587_; uint8_t v___x_3588_;
v___x_3587_ = 3;
v___x_3588_ = lean_uint8_dec_eq(v_commandClass_3549_, v___x_3587_);
if (v___x_3588_ == 0)
{
goto v___jp_3580_;
}
else
{
uint8_t v___x_3589_;
v___x_3589_ = lean_uint8_dec_le(v___x_3573_, v_grantScope_3548_);
if (v___x_3589_ == 0)
{
goto v___jp_3580_;
}
else
{
uint32_t v___x_3590_;
v___x_3590_ = 1794;
v___y_3564_ = v___x_3590_;
goto v___jp_3563_;
}
}
}
}
}
}
}
v___jp_3555_:
{
uint64_t v___x_3558_; uint64_t v___x_3559_; uint64_t v___x_3560_; uint64_t v___x_3561_; uint64_t v___x_3562_;
v___x_3558_ = lean_uint32_to_uint64(v___y_3556_);
v___x_3559_ = lean_uint32_to_uint64(v___y_3557_);
v___x_3560_ = 32ULL;
v___x_3561_ = lean_uint64_shift_left(v___x_3559_, v___x_3560_);
v___x_3562_ = lean_uint64_lor(v___x_3558_, v___x_3561_);
return v___x_3562_;
}
v___jp_3563_:
{
uint32_t v___x_3565_; uint8_t v___x_3566_;
v___x_3565_ = 1536;
v___x_3566_ = lean_uint32_dec_eq(v___y_3564_, v___x_3565_);
if (v___x_3566_ == 0)
{
uint32_t v___x_3567_;
v___x_3567_ = 0;
v___y_3556_ = v___y_3564_;
v___y_3557_ = v___x_3567_;
goto v___jp_3555_;
}
else
{
uint32_t v___x_3568_;
v___x_3568_ = 126;
v___y_3556_ = v___y_3564_;
v___y_3557_ = v___x_3568_;
goto v___jp_3555_;
}
}
v___jp_3569_:
{
uint32_t v___x_3570_;
v___x_3570_ = 1536;
v___y_3564_ = v___x_3570_;
goto v___jp_3563_;
}
v___jp_3571_:
{
uint32_t v___x_3572_;
v___x_3572_ = 1536;
v___y_3564_ = v___x_3572_;
goto v___jp_3563_;
}
}
}

LEAN_EXPORT uint64_t orb_ssh_identity_step(uint8_t v_isWorkerOrContainerTarget_3617_, uint8_t v_bundleHasControlPlaneKey_3618_, uint8_t v_parentDirIsSymlink_3619_, uint8_t v_pubKeyIsEd25519WithoutPrivate_3620_, uint8_t v_proxyJumpValid_3621_, uint8_t v_codexCyberProgramValid_3622_, uint8_t v_codexGoalBudgetExhausted_3623_){
_start:
{
uint32_t v___y_3625_; uint32_t v___y_3626_; uint32_t v___y_3633_; uint32_t v___y_3636_; uint8_t v___y_3644_; uint8_t v___x_3649_; uint8_t v___x_3650_;
v___x_3649_ = 0;
v___x_3650_ = lean_uint8_dec_eq(v_parentDirIsSymlink_3619_, v___x_3649_);
if (v___x_3650_ == 0)
{
v___y_3644_ = v___x_3650_;
goto v___jp_3643_;
}
else
{
uint8_t v___x_3651_; uint8_t v___x_3652_;
v___x_3651_ = 1;
v___x_3652_ = lean_uint8_dec_eq(v_pubKeyIsEd25519WithoutPrivate_3620_, v___x_3651_);
if (v___x_3652_ == 0)
{
v___y_3644_ = v___x_3652_;
goto v___jp_3643_;
}
else
{
uint8_t v___x_3653_;
v___x_3653_ = lean_uint8_dec_eq(v_proxyJumpValid_3621_, v___x_3651_);
if (v___x_3653_ == 0)
{
v___y_3644_ = v___x_3653_;
goto v___jp_3643_;
}
else
{
uint8_t v___x_3654_;
v___x_3654_ = lean_uint8_dec_eq(v_codexCyberProgramValid_3622_, v___x_3651_);
if (v___x_3654_ == 0)
{
v___y_3644_ = v___x_3654_;
goto v___jp_3643_;
}
else
{
uint8_t v___x_3655_;
v___x_3655_ = lean_uint8_dec_eq(v_codexGoalBudgetExhausted_3623_, v___x_3649_);
if (v___x_3655_ == 0)
{
v___y_3644_ = v___x_3655_;
goto v___jp_3643_;
}
else
{
uint8_t v___x_3656_;
v___x_3656_ = lean_uint8_dec_eq(v_isWorkerOrContainerTarget_3617_, v___x_3651_);
if (v___x_3656_ == 0)
{
v___y_3644_ = v___x_3655_;
goto v___jp_3643_;
}
else
{
uint8_t v___x_3657_;
v___x_3657_ = lean_uint8_dec_eq(v_bundleHasControlPlaneKey_3618_, v___x_3651_);
if (v___x_3657_ == 0)
{
v___y_3644_ = v___x_3655_;
goto v___jp_3643_;
}
else
{
goto v___jp_3638_;
}
}
}
}
}
}
}
v___jp_3624_:
{
uint64_t v___x_3627_; uint64_t v___x_3628_; uint64_t v___x_3629_; uint64_t v___x_3630_; uint64_t v___x_3631_;
v___x_3627_ = lean_uint32_to_uint64(v___y_3625_);
v___x_3628_ = lean_uint32_to_uint64(v___y_3626_);
v___x_3629_ = 32ULL;
v___x_3630_ = lean_uint64_shift_left(v___x_3628_, v___x_3629_);
v___x_3631_ = lean_uint64_lor(v___x_3627_, v___x_3630_);
return v___x_3631_;
}
v___jp_3632_:
{
uint32_t v___x_3634_;
v___x_3634_ = 78;
v___y_3625_ = v___y_3633_;
v___y_3626_ = v___x_3634_;
goto v___jp_3624_;
}
v___jp_3635_:
{
uint32_t v___x_3637_;
v___x_3637_ = 0;
v___y_3625_ = v___y_3636_;
v___y_3626_ = v___x_3637_;
goto v___jp_3624_;
}
v___jp_3638_:
{
uint8_t v___x_3639_; uint8_t v___x_3640_;
v___x_3639_ = 1;
v___x_3640_ = lean_uint8_dec_eq(v_isWorkerOrContainerTarget_3617_, v___x_3639_);
if (v___x_3640_ == 0)
{
uint32_t v___x_3641_;
v___x_3641_ = 1024;
v___y_3633_ = v___x_3641_;
goto v___jp_3632_;
}
else
{
uint32_t v___x_3642_;
v___x_3642_ = 1536;
v___y_3633_ = v___x_3642_;
goto v___jp_3632_;
}
}
v___jp_3643_:
{
if (v___y_3644_ == 0)
{
goto v___jp_3638_;
}
else
{
uint8_t v___x_3645_; uint8_t v___x_3646_;
v___x_3645_ = 1;
v___x_3646_ = lean_uint8_dec_eq(v_isWorkerOrContainerTarget_3617_, v___x_3645_);
if (v___x_3646_ == 0)
{
uint32_t v___x_3647_;
v___x_3647_ = 1282;
v___y_3636_ = v___x_3647_;
goto v___jp_3635_;
}
else
{
uint32_t v___x_3648_;
v___x_3648_ = 1793;
v___y_3636_ = v___x_3648_;
goto v___jp_3635_;
}
}
}
}
}

LEAN_EXPORT uint64_t orb_agent_event_normalize_step(uint8_t v_harnessKind_3674_, uint8_t v_rawEventKind_3675_, uint8_t v_isCompleted_3676_, uint8_t v_hasNonEmptyText_3677_, uint32_t v_sessionMatchesExpected_3678_, uint32_t v_isDuplicateTurnOrTool_3679_, uint32_t v_payloadBytes_3680_, uint32_t v_maxPayloadBytes_3681_){
_start:
{
uint32_t v___y_3683_; uint32_t v___y_3684_; uint8_t v_bounded_3690_; uint32_t v___y_3692_; uint8_t v___x_3695_; uint8_t v_harnessValid_3696_; uint8_t v___y_3698_; uint32_t v___x_3732_; uint8_t v___x_3733_;
v_bounded_3690_ = lean_uint32_dec_le(v_payloadBytes_3680_, v_maxPayloadBytes_3681_);
v___x_3695_ = 5;
v_harnessValid_3696_ = lean_uint8_dec_le(v_harnessKind_3674_, v___x_3695_);
v___x_3732_ = 1;
v___x_3733_ = lean_uint32_dec_eq(v_sessionMatchesExpected_3678_, v___x_3732_);
if (v___x_3733_ == 0)
{
uint8_t v___x_3734_; uint8_t v___x_3735_;
v___x_3734_ = 0;
v___x_3735_ = lean_uint8_dec_eq(v_rawEventKind_3675_, v___x_3734_);
if (v___x_3735_ == 0)
{
uint8_t v___x_3736_; uint8_t v___x_3737_;
v___x_3736_ = 1;
v___x_3737_ = lean_uint8_dec_eq(v_rawEventKind_3675_, v___x_3736_);
if (v___x_3737_ == 0)
{
uint8_t v___x_3738_; uint8_t v___x_3739_;
v___x_3738_ = 7;
v___x_3739_ = lean_uint8_dec_eq(v_rawEventKind_3675_, v___x_3738_);
v___y_3698_ = v___x_3739_;
goto v___jp_3697_;
}
else
{
v___y_3698_ = v___x_3737_;
goto v___jp_3697_;
}
}
else
{
v___y_3698_ = v___x_3735_;
goto v___jp_3697_;
}
}
else
{
v___y_3698_ = v___x_3733_;
goto v___jp_3697_;
}
v___jp_3682_:
{
uint64_t v___x_3685_; uint64_t v___x_3686_; uint64_t v___x_3687_; uint64_t v___x_3688_; uint64_t v___x_3689_;
v___x_3685_ = lean_uint32_to_uint64(v___y_3683_);
v___x_3686_ = lean_uint32_to_uint64(v___y_3684_);
v___x_3687_ = 32ULL;
v___x_3688_ = lean_uint64_shift_left(v___x_3686_, v___x_3687_);
v___x_3689_ = lean_uint64_lor(v___x_3685_, v___x_3688_);
return v___x_3689_;
}
v___jp_3691_:
{
if (v_bounded_3690_ == 0)
{
v___y_3683_ = v___y_3692_;
v___y_3684_ = v_maxPayloadBytes_3681_;
goto v___jp_3682_;
}
else
{
v___y_3683_ = v___y_3692_;
v___y_3684_ = v_payloadBytes_3680_;
goto v___jp_3682_;
}
}
v___jp_3693_:
{
uint32_t v___x_3694_;
v___x_3694_ = 2049;
v___y_3692_ = v___x_3694_;
goto v___jp_3691_;
}
v___jp_3697_:
{
if (v_bounded_3690_ == 0)
{
uint32_t v___x_3699_;
v___x_3699_ = 2048;
v___y_3692_ = v___x_3699_;
goto v___jp_3691_;
}
else
{
if (v_harnessValid_3696_ == 0)
{
goto v___jp_3693_;
}
else
{
if (v___y_3698_ == 0)
{
goto v___jp_3693_;
}
else
{
uint32_t v___x_3700_; uint8_t v_notDup_3701_;
v___x_3700_ = 0;
v_notDup_3701_ = lean_uint32_dec_eq(v_isDuplicateTurnOrTool_3679_, v___x_3700_);
if (v_notDup_3701_ == 0)
{
goto v___jp_3693_;
}
else
{
uint8_t v___x_3702_; uint8_t v___x_3703_;
v___x_3702_ = 0;
v___x_3703_ = lean_uint8_dec_eq(v_rawEventKind_3675_, v___x_3702_);
if (v___x_3703_ == 0)
{
uint8_t v___x_3704_; uint8_t v___x_3705_;
v___x_3704_ = 1;
v___x_3705_ = lean_uint8_dec_eq(v_rawEventKind_3675_, v___x_3704_);
if (v___x_3705_ == 0)
{
uint8_t v___x_3706_; uint8_t v___x_3707_;
v___x_3706_ = 2;
v___x_3707_ = lean_uint8_dec_eq(v_rawEventKind_3675_, v___x_3706_);
if (v___x_3707_ == 0)
{
uint8_t v___x_3708_; uint8_t v___x_3709_;
v___x_3708_ = 3;
v___x_3709_ = lean_uint8_dec_eq(v_rawEventKind_3675_, v___x_3708_);
if (v___x_3709_ == 0)
{
uint8_t v___x_3710_; uint8_t v___x_3711_;
v___x_3710_ = 4;
v___x_3711_ = lean_uint8_dec_eq(v_rawEventKind_3675_, v___x_3710_);
if (v___x_3711_ == 0)
{
uint8_t v___x_3712_;
v___x_3712_ = lean_uint8_dec_eq(v_rawEventKind_3675_, v___x_3695_);
if (v___x_3712_ == 0)
{
uint8_t v___x_3713_; uint8_t v___x_3714_;
v___x_3713_ = 6;
v___x_3714_ = lean_uint8_dec_eq(v_rawEventKind_3675_, v___x_3713_);
if (v___x_3714_ == 0)
{
uint8_t v___x_3715_; uint8_t v___x_3716_;
v___x_3715_ = 7;
v___x_3716_ = lean_uint8_dec_eq(v_rawEventKind_3675_, v___x_3715_);
if (v___x_3716_ == 0)
{
uint32_t v___x_3717_;
v___x_3717_ = 2049;
v___y_3692_ = v___x_3717_;
goto v___jp_3691_;
}
else
{
uint32_t v___x_3718_;
v___x_3718_ = 3338;
v___y_3692_ = v___x_3718_;
goto v___jp_3691_;
}
}
else
{
uint32_t v___x_3719_;
v___x_3719_ = 3337;
v___y_3692_ = v___x_3719_;
goto v___jp_3691_;
}
}
else
{
uint32_t v___x_3720_;
v___x_3720_ = 2312;
v___y_3692_ = v___x_3720_;
goto v___jp_3691_;
}
}
else
{
uint8_t v___x_3721_;
v___x_3721_ = lean_uint8_dec_eq(v_isCompleted_3676_, v___x_3704_);
if (v___x_3721_ == 0)
{
uint32_t v___x_3722_;
v___x_3722_ = 3335;
v___y_3692_ = v___x_3722_;
goto v___jp_3691_;
}
else
{
uint32_t v___x_3723_;
v___x_3723_ = 3334;
v___y_3692_ = v___x_3723_;
goto v___jp_3691_;
}
}
}
else
{
uint8_t v___x_3724_;
v___x_3724_ = lean_uint8_dec_eq(v_hasNonEmptyText_3677_, v___x_3704_);
if (v___x_3724_ == 0)
{
uint32_t v___x_3725_;
v___x_3725_ = 2049;
v___y_3692_ = v___x_3725_;
goto v___jp_3691_;
}
else
{
uint32_t v___x_3726_;
v___x_3726_ = 3333;
v___y_3692_ = v___x_3726_;
goto v___jp_3691_;
}
}
}
else
{
uint8_t v___x_3727_;
v___x_3727_ = lean_uint8_dec_eq(v_hasNonEmptyText_3677_, v___x_3704_);
if (v___x_3727_ == 0)
{
uint32_t v___x_3728_;
v___x_3728_ = 2049;
v___y_3692_ = v___x_3728_;
goto v___jp_3691_;
}
else
{
uint32_t v___x_3729_;
v___x_3729_ = 2820;
v___y_3692_ = v___x_3729_;
goto v___jp_3691_;
}
}
}
else
{
uint32_t v___x_3730_;
v___x_3730_ = 2307;
v___y_3692_ = v___x_3730_;
goto v___jp_3691_;
}
}
else
{
uint32_t v___x_3731_;
v___x_3731_ = 2306;
v___y_3692_ = v___x_3731_;
goto v___jp_3691_;
}
}
}
}
}
}
}
}

LEAN_EXPORT uint64_t orb_transcript_reduce_step(uint64_t v_lastAppliedSeq_3823_, uint64_t v_incomingSeq_3824_, uint8_t v_thinkingOpen_3825_, uint8_t v_normalizedAction_3826_, uint8_t v_isReplayFromLog_3827_){
_start:
{
uint32_t v___y_3829_; uint32_t v___y_3830_; uint32_t v___y_3837_; uint32_t v___y_3843_; uint8_t v_seqAdvances_3848_; uint64_t v___y_3850_;
v_seqAdvances_3848_ = lean_uint64_dec_lt(v_lastAppliedSeq_3823_, v_incomingSeq_3824_);
if (v_seqAdvances_3848_ == 0)
{
v___y_3850_ = v_lastAppliedSeq_3823_;
goto v___jp_3849_;
}
else
{
v___y_3850_ = v_incomingSeq_3824_;
goto v___jp_3849_;
}
v___jp_3828_:
{
uint64_t v___x_3831_; uint64_t v___x_3832_; uint64_t v___x_3833_; uint64_t v___x_3834_; uint64_t v___x_3835_;
v___x_3831_ = lean_uint32_to_uint64(v___y_3830_);
v___x_3832_ = lean_uint32_to_uint64(v___y_3829_);
v___x_3833_ = 32ULL;
v___x_3834_ = lean_uint64_shift_left(v___x_3832_, v___x_3833_);
v___x_3835_ = lean_uint64_lor(v___x_3831_, v___x_3834_);
return v___x_3835_;
}
v___jp_3836_:
{
uint8_t v___x_3838_; uint8_t v___x_3839_;
v___x_3838_ = 1;
v___x_3839_ = lean_uint8_dec_eq(v_thinkingOpen_3825_, v___x_3838_);
if (v___x_3839_ == 0)
{
uint32_t v___x_3840_;
v___x_3840_ = 258;
v___y_3829_ = v___y_3837_;
v___y_3830_ = v___x_3840_;
goto v___jp_3828_;
}
else
{
uint32_t v___x_3841_;
v___x_3841_ = 1282;
v___y_3829_ = v___y_3837_;
v___y_3830_ = v___x_3841_;
goto v___jp_3828_;
}
}
v___jp_3842_:
{
uint8_t v___x_3844_; uint8_t v___x_3845_;
v___x_3844_ = 1;
v___x_3845_ = lean_uint8_dec_eq(v_thinkingOpen_3825_, v___x_3844_);
if (v___x_3845_ == 0)
{
uint32_t v___x_3846_;
v___x_3846_ = 259;
v___y_3829_ = v___y_3843_;
v___y_3830_ = v___x_3846_;
goto v___jp_3828_;
}
else
{
uint32_t v___x_3847_;
v___x_3847_ = 771;
v___y_3829_ = v___y_3843_;
v___y_3830_ = v___x_3847_;
goto v___jp_3828_;
}
}
v___jp_3849_:
{
uint32_t v_nextSeq32_3851_;
v_nextSeq32_3851_ = lean_uint64_to_uint32(v___y_3850_);
if (v_seqAdvances_3848_ == 0)
{
uint8_t v___x_3852_; uint8_t v___x_3853_;
v___x_3852_ = 1;
v___x_3853_ = lean_uint8_dec_eq(v_thinkingOpen_3825_, v___x_3852_);
if (v___x_3853_ == 0)
{
uint32_t v___x_3854_;
v___x_3854_ = 0;
v___y_3829_ = v_nextSeq32_3851_;
v___y_3830_ = v___x_3854_;
goto v___jp_3828_;
}
else
{
uint32_t v___x_3855_;
v___x_3855_ = 512;
v___y_3829_ = v_nextSeq32_3851_;
v___y_3830_ = v___x_3855_;
goto v___jp_3828_;
}
}
else
{
uint8_t v___x_3856_; uint8_t v___x_3857_;
v___x_3856_ = 4;
v___x_3857_ = lean_uint8_dec_eq(v_normalizedAction_3826_, v___x_3856_);
if (v___x_3857_ == 0)
{
uint8_t v___x_3858_; uint8_t v___x_3859_;
v___x_3858_ = 5;
v___x_3859_ = lean_uint8_dec_eq(v_normalizedAction_3826_, v___x_3858_);
if (v___x_3859_ == 0)
{
uint8_t v___x_3860_; uint8_t v___x_3861_;
v___x_3860_ = 6;
v___x_3861_ = lean_uint8_dec_eq(v_normalizedAction_3826_, v___x_3860_);
if (v___x_3861_ == 0)
{
uint8_t v___x_3862_; uint8_t v___x_3863_;
v___x_3862_ = 7;
v___x_3863_ = lean_uint8_dec_eq(v_normalizedAction_3826_, v___x_3862_);
if (v___x_3863_ == 0)
{
uint8_t v___x_3864_; uint8_t v___x_3865_;
v___x_3864_ = 9;
v___x_3865_ = lean_uint8_dec_eq(v_normalizedAction_3826_, v___x_3864_);
if (v___x_3865_ == 0)
{
uint8_t v___x_3866_; uint8_t v___x_3867_;
v___x_3866_ = 10;
v___x_3867_ = lean_uint8_dec_eq(v_normalizedAction_3826_, v___x_3866_);
if (v___x_3867_ == 0)
{
uint8_t v___x_3868_; uint8_t v___x_3869_;
v___x_3868_ = 2;
v___x_3869_ = lean_uint8_dec_eq(v_normalizedAction_3826_, v___x_3868_);
if (v___x_3869_ == 0)
{
uint8_t v___x_3870_; uint8_t v___x_3871_;
v___x_3870_ = 3;
v___x_3871_ = lean_uint8_dec_eq(v_normalizedAction_3826_, v___x_3870_);
if (v___x_3871_ == 0)
{
uint8_t v___x_3872_; uint8_t v___x_3873_;
v___x_3872_ = 8;
v___x_3873_ = lean_uint8_dec_eq(v_normalizedAction_3826_, v___x_3872_);
if (v___x_3873_ == 0)
{
uint8_t v___x_3874_; uint8_t v___x_3875_;
v___x_3874_ = 1;
v___x_3875_ = lean_uint8_dec_eq(v_thinkingOpen_3825_, v___x_3874_);
if (v___x_3875_ == 0)
{
uint32_t v___x_3876_;
v___x_3876_ = 0;
v___y_3829_ = v_nextSeq32_3851_;
v___y_3830_ = v___x_3876_;
goto v___jp_3828_;
}
else
{
uint32_t v___x_3877_;
v___x_3877_ = 512;
v___y_3829_ = v_nextSeq32_3851_;
v___y_3830_ = v___x_3877_;
goto v___jp_3828_;
}
}
else
{
v___y_3843_ = v_nextSeq32_3851_;
goto v___jp_3842_;
}
}
else
{
v___y_3843_ = v_nextSeq32_3851_;
goto v___jp_3842_;
}
}
else
{
v___y_3843_ = v_nextSeq32_3851_;
goto v___jp_3842_;
}
}
else
{
v___y_3837_ = v_nextSeq32_3851_;
goto v___jp_3836_;
}
}
else
{
v___y_3837_ = v_nextSeq32_3851_;
goto v___jp_3836_;
}
}
else
{
v___y_3837_ = v_nextSeq32_3851_;
goto v___jp_3836_;
}
}
else
{
v___y_3837_ = v_nextSeq32_3851_;
goto v___jp_3836_;
}
}
else
{
v___y_3837_ = v_nextSeq32_3851_;
goto v___jp_3836_;
}
}
else
{
uint32_t v___x_3878_;
v___x_3878_ = 769;
v___y_3829_ = v_nextSeq32_3851_;
v___y_3830_ = v___x_3878_;
goto v___jp_3828_;
}
}
}
}
}

LEAN_EXPORT uint64_t orb_cursor_page_step(uint64_t v_sinceSeq_3891_, uint64_t v_beforeSeq_3892_, uint64_t v_itemSeq_3893_, uint32_t v_hasSinceCursor_3894_, uint32_t v_hasBeforeCursor_3895_, uint32_t v_isPartialResponse_3896_, uint32_t v_existingCount_3897_){
_start:
{
uint32_t v___y_3899_; uint32_t v___y_3900_; uint32_t v___x_3906_; uint32_t v___y_3908_; uint8_t v___y_3911_; uint8_t v___y_3912_; uint32_t v___y_3913_; uint32_t v___y_3921_; uint8_t v___y_3922_; uint8_t v___y_3923_; uint8_t v___y_3927_; uint32_t v___y_3928_; uint8_t v___y_3929_; uint8_t v___y_3930_; uint32_t v___y_3932_; uint8_t v___y_3933_; uint8_t v___y_3934_; uint8_t v___y_3938_; uint8_t v___x_3944_;
v___x_3906_ = 1;
v___x_3944_ = lean_uint32_dec_eq(v_hasSinceCursor_3894_, v___x_3906_);
if (v___x_3944_ == 0)
{
goto v___jp_3942_;
}
else
{
uint8_t v___x_3945_;
v___x_3945_ = lean_uint32_dec_eq(v_hasBeforeCursor_3895_, v___x_3906_);
if (v___x_3945_ == 0)
{
goto v___jp_3942_;
}
else
{
uint8_t v___x_3946_;
v___x_3946_ = lean_uint64_dec_le(v_beforeSeq_3892_, v_sinceSeq_3891_);
if (v___x_3946_ == 0)
{
goto v___jp_3942_;
}
else
{
uint8_t v___x_3947_;
v___x_3947_ = 0;
v___y_3938_ = v___x_3947_;
goto v___jp_3937_;
}
}
}
v___jp_3898_:
{
uint64_t v___x_3901_; uint64_t v___x_3902_; uint64_t v___x_3903_; uint64_t v___x_3904_; uint64_t v___x_3905_;
v___x_3901_ = lean_uint32_to_uint64(v___y_3899_);
v___x_3902_ = lean_uint32_to_uint64(v___y_3900_);
v___x_3903_ = 32ULL;
v___x_3904_ = lean_uint64_shift_left(v___x_3902_, v___x_3903_);
v___x_3905_ = lean_uint64_lor(v___x_3901_, v___x_3904_);
return v___x_3905_;
}
v___jp_3907_:
{
uint32_t v___x_3909_;
v___x_3909_ = lean_uint32_add(v_existingCount_3897_, v___x_3906_);
v___y_3899_ = v___y_3908_;
v___y_3900_ = v___x_3909_;
goto v___jp_3898_;
}
v___jp_3910_:
{
if (v___y_3912_ == 0)
{
uint32_t v___x_3914_; uint32_t v___x_3915_;
v___x_3914_ = 512;
v___x_3915_ = lean_uint32_lor(v___x_3914_, v___y_3913_);
if (v___y_3911_ == 0)
{
v___y_3899_ = v___x_3915_;
v___y_3900_ = v_existingCount_3897_;
goto v___jp_3898_;
}
else
{
v___y_3908_ = v___x_3915_;
goto v___jp_3907_;
}
}
else
{
if (v___y_3911_ == 0)
{
uint32_t v___x_3916_; uint32_t v___x_3917_;
v___x_3916_ = 514;
v___x_3917_ = lean_uint32_lor(v___x_3916_, v___y_3913_);
v___y_3899_ = v___x_3917_;
v___y_3900_ = v_existingCount_3897_;
goto v___jp_3898_;
}
else
{
uint32_t v___x_3918_; uint32_t v___x_3919_;
v___x_3918_ = 769;
v___x_3919_ = lean_uint32_lor(v___x_3918_, v___y_3913_);
v___y_3908_ = v___x_3919_;
goto v___jp_3907_;
}
}
}
v___jp_3920_:
{
uint8_t v___x_3924_;
v___x_3924_ = lean_uint32_dec_eq(v_isPartialResponse_3896_, v___x_3906_);
if (v___x_3924_ == 0)
{
v___y_3911_ = v___y_3923_;
v___y_3912_ = v___y_3922_;
v___y_3913_ = v___y_3921_;
goto v___jp_3910_;
}
else
{
uint32_t v___x_3925_;
v___x_3925_ = 1024;
v___y_3911_ = v___y_3923_;
v___y_3912_ = v___y_3922_;
v___y_3913_ = v___x_3925_;
goto v___jp_3910_;
}
}
v___jp_3926_:
{
if (v___y_3929_ == 0)
{
v___y_3921_ = v___y_3928_;
v___y_3922_ = v___y_3929_;
v___y_3923_ = v___y_3929_;
goto v___jp_3920_;
}
else
{
if (v___y_3927_ == 0)
{
v___y_3921_ = v___y_3928_;
v___y_3922_ = v___y_3929_;
v___y_3923_ = v___y_3927_;
goto v___jp_3920_;
}
else
{
v___y_3921_ = v___y_3928_;
v___y_3922_ = v___y_3929_;
v___y_3923_ = v___y_3930_;
goto v___jp_3920_;
}
}
}
v___jp_3931_:
{
uint8_t v___x_3935_;
v___x_3935_ = lean_uint32_dec_eq(v_hasBeforeCursor_3895_, v___y_3932_);
if (v___x_3935_ == 0)
{
uint8_t v___x_3936_;
v___x_3936_ = lean_uint64_dec_lt(v_itemSeq_3893_, v_beforeSeq_3892_);
v___y_3927_ = v___y_3934_;
v___y_3928_ = v___y_3932_;
v___y_3929_ = v___y_3933_;
v___y_3930_ = v___x_3936_;
goto v___jp_3926_;
}
else
{
v___y_3927_ = v___y_3934_;
v___y_3928_ = v___y_3932_;
v___y_3929_ = v___y_3933_;
v___y_3930_ = v___x_3935_;
goto v___jp_3926_;
}
}
v___jp_3937_:
{
uint32_t v___x_3939_; uint8_t v___x_3940_;
v___x_3939_ = 0;
v___x_3940_ = lean_uint32_dec_eq(v_hasSinceCursor_3894_, v___x_3939_);
if (v___x_3940_ == 0)
{
uint8_t v___x_3941_;
v___x_3941_ = lean_uint64_dec_lt(v_sinceSeq_3891_, v_itemSeq_3893_);
v___y_3932_ = v___x_3939_;
v___y_3933_ = v___y_3938_;
v___y_3934_ = v___x_3941_;
goto v___jp_3931_;
}
else
{
v___y_3932_ = v___x_3939_;
v___y_3933_ = v___y_3938_;
v___y_3934_ = v___x_3940_;
goto v___jp_3931_;
}
}
v___jp_3942_:
{
uint8_t v___x_3943_;
v___x_3943_ = 1;
v___y_3938_ = v___x_3943_;
goto v___jp_3937_;
}
}
}

LEAN_EXPORT uint64_t orb_sidebar_merge_step(uint32_t v_existingIdOrd_3964_, uint32_t v_incomingIdOrd_3965_, uint64_t v_existingUpdatedAtMs_3966_, uint64_t v_incomingUpdatedAtMs_3967_, uint8_t v_incomingSupersededOrArchived_3968_, uint8_t v_isPartialPage_3969_){
_start:
{
uint32_t v___y_3971_; uint32_t v___y_3972_; uint32_t v___x_3978_; uint8_t v___y_3980_; uint8_t v___y_3981_; uint32_t v___y_3982_; uint8_t v___y_3985_; uint32_t v___y_3986_; uint8_t v___y_3987_; uint32_t v___y_3988_; uint8_t v___y_3991_; uint32_t v___y_3992_; uint8_t v___y_3993_; uint32_t v___y_3994_; uint8_t v___y_3997_; uint8_t v___y_3998_; uint8_t v___y_3999_; uint32_t v___y_4000_; uint8_t v___y_4009_; uint8_t v___x_4014_;
v___x_3978_ = 0;
v___x_4014_ = lean_uint32_dec_eq(v_existingIdOrd_3964_, v___x_3978_);
if (v___x_4014_ == 0)
{
uint8_t v___x_4015_;
v___x_4015_ = lean_uint32_dec_eq(v_existingIdOrd_3964_, v_incomingIdOrd_3965_);
v___y_4009_ = v___x_4015_;
goto v___jp_4008_;
}
else
{
uint8_t v___x_4016_;
v___x_4016_ = 0;
v___y_4009_ = v___x_4016_;
goto v___jp_4008_;
}
v___jp_3970_:
{
uint64_t v___x_3973_; uint64_t v___x_3974_; uint64_t v___x_3975_; uint64_t v___x_3976_; uint64_t v___x_3977_;
v___x_3973_ = lean_uint32_to_uint64(v___y_3971_);
v___x_3974_ = lean_uint32_to_uint64(v___y_3972_);
v___x_3975_ = 32ULL;
v___x_3976_ = lean_uint64_shift_left(v___x_3974_, v___x_3975_);
v___x_3977_ = lean_uint64_lor(v___x_3973_, v___x_3976_);
return v___x_3977_;
}
v___jp_3979_:
{
if (v___y_3981_ == 0)
{
if (v___y_3980_ == 0)
{
uint32_t v___x_3983_;
v___x_3983_ = 1;
v___y_3971_ = v___y_3982_;
v___y_3972_ = v___x_3983_;
goto v___jp_3970_;
}
else
{
v___y_3971_ = v___y_3982_;
v___y_3972_ = v___x_3978_;
goto v___jp_3970_;
}
}
else
{
v___y_3971_ = v___y_3982_;
v___y_3972_ = v___x_3978_;
goto v___jp_3970_;
}
}
v___jp_3984_:
{
uint32_t v___x_3989_;
v___x_3989_ = lean_uint32_lor(v___y_3988_, v___y_3986_);
v___y_3980_ = v___y_3985_;
v___y_3981_ = v___y_3987_;
v___y_3982_ = v___x_3989_;
goto v___jp_3979_;
}
v___jp_3990_:
{
uint32_t v___x_3995_;
v___x_3995_ = lean_uint32_lor(v___y_3994_, v___y_3992_);
v___y_3980_ = v___y_3991_;
v___y_3981_ = v___y_3993_;
v___y_3982_ = v___x_3995_;
goto v___jp_3979_;
}
v___jp_3996_:
{
uint8_t v___x_4001_;
v___x_4001_ = lean_uint8_dec_eq(v_incomingSupersededOrArchived_3968_, v___y_3997_);
if (v___x_4001_ == 0)
{
if (v___y_3999_ == 0)
{
uint32_t v___x_4002_; uint32_t v___x_4003_;
v___x_4002_ = 1795;
v___x_4003_ = lean_uint32_lor(v___x_4002_, v___y_4000_);
v___y_3980_ = v___y_3999_;
v___y_3981_ = v___x_4001_;
v___y_3982_ = v___x_4003_;
goto v___jp_3979_;
}
else
{
if (v___y_3998_ == 0)
{
uint32_t v___x_4004_;
v___x_4004_ = 1282;
v___y_3985_ = v___y_3999_;
v___y_3986_ = v___y_4000_;
v___y_3987_ = v___x_4001_;
v___y_3988_ = v___x_4004_;
goto v___jp_3984_;
}
else
{
uint32_t v___x_4005_;
v___x_4005_ = 1281;
v___y_3985_ = v___y_3999_;
v___y_3986_ = v___y_4000_;
v___y_3987_ = v___x_4001_;
v___y_3988_ = v___x_4005_;
goto v___jp_3984_;
}
}
}
else
{
if (v___y_3999_ == 0)
{
uint32_t v___x_4006_;
v___x_4006_ = 1024;
v___y_3991_ = v___y_3999_;
v___y_3992_ = v___y_4000_;
v___y_3993_ = v___x_4001_;
v___y_3994_ = v___x_4006_;
goto v___jp_3990_;
}
else
{
uint32_t v___x_4007_;
v___x_4007_ = 1028;
v___y_3991_ = v___y_3999_;
v___y_3992_ = v___y_4000_;
v___y_3993_ = v___x_4001_;
v___y_3994_ = v___x_4007_;
goto v___jp_3990_;
}
}
}
v___jp_4008_:
{
uint8_t v_incomingNewer_4010_; uint8_t v___x_4011_; uint8_t v___x_4012_;
v_incomingNewer_4010_ = lean_uint64_dec_le(v_existingUpdatedAtMs_3966_, v_incomingUpdatedAtMs_3967_);
v___x_4011_ = 1;
v___x_4012_ = lean_uint8_dec_eq(v_isPartialPage_3969_, v___x_4011_);
if (v___x_4012_ == 0)
{
v___y_3997_ = v___x_4011_;
v___y_3998_ = v_incomingNewer_4010_;
v___y_3999_ = v___y_4009_;
v___y_4000_ = v___x_3978_;
goto v___jp_3996_;
}
else
{
uint32_t v___x_4013_;
v___x_4013_ = 2048;
v___y_3997_ = v___x_4011_;
v___y_3998_ = v_incomingNewer_4010_;
v___y_3999_ = v___y_4009_;
v___y_4000_ = v___x_4013_;
goto v___jp_3996_;
}
}
}
}

LEAN_EXPORT uint64_t orb_scroll_epoch_step(uint32_t v_layoutEpoch_4031_, uint32_t v_lastCorrectedEpoch_4032_, uint8_t v_correctionsInEpoch_4033_, uint8_t v_isPinnedToBottom_4034_, uint8_t v_userIsDragging_4035_, uint32_t v_targetScrollTopPx_4036_, uint32_t v_currentScrollTopPx_4037_){
_start:
{
uint32_t v___y_4039_; uint32_t v___y_4040_; uint8_t v___y_4049_; uint8_t v___y_4050_; uint8_t v___y_4054_; uint8_t v___y_4055_; uint8_t v___y_4061_; uint8_t v_newEpoch_4065_;
v_newEpoch_4065_ = lean_uint32_dec_lt(v_lastCorrectedEpoch_4032_, v_layoutEpoch_4031_);
if (v_newEpoch_4065_ == 0)
{
uint8_t v___x_4066_; uint8_t v___x_4067_;
v___x_4066_ = 0;
v___x_4067_ = lean_uint8_dec_lt(v___x_4066_, v_correctionsInEpoch_4033_);
v___y_4061_ = v___x_4067_;
goto v___jp_4060_;
}
else
{
uint8_t v___x_4068_;
v___x_4068_ = 0;
v___y_4061_ = v___x_4068_;
goto v___jp_4060_;
}
v___jp_4038_:
{
uint64_t v___x_4041_; uint64_t v___x_4042_; uint64_t v___x_4043_; uint64_t v___x_4044_; uint64_t v___x_4045_;
v___x_4041_ = lean_uint32_to_uint64(v___y_4039_);
v___x_4042_ = lean_uint32_to_uint64(v___y_4040_);
v___x_4043_ = 32ULL;
v___x_4044_ = lean_uint64_shift_left(v___x_4042_, v___x_4043_);
v___x_4045_ = lean_uint64_lor(v___x_4041_, v___x_4044_);
return v___x_4045_;
}
v___jp_4046_:
{
uint32_t v___x_4047_;
v___x_4047_ = 1026;
v___y_4039_ = v___x_4047_;
v___y_4040_ = v_currentScrollTopPx_4037_;
goto v___jp_4038_;
}
v___jp_4048_:
{
if (v___y_4050_ == 0)
{
if (v___y_4049_ == 0)
{
uint32_t v___x_4051_;
v___x_4051_ = 0;
v___y_4039_ = v___x_4051_;
v___y_4040_ = v_currentScrollTopPx_4037_;
goto v___jp_4038_;
}
else
{
goto v___jp_4046_;
}
}
else
{
uint32_t v___x_4052_;
v___x_4052_ = 1281;
v___y_4039_ = v___x_4052_;
v___y_4040_ = v_targetScrollTopPx_4036_;
goto v___jp_4038_;
}
}
v___jp_4053_:
{
uint8_t v___x_4056_; uint8_t v___x_4057_;
v___x_4056_ = 1;
v___x_4057_ = lean_uint8_dec_eq(v_isPinnedToBottom_4034_, v___x_4056_);
if (v___x_4057_ == 0)
{
v___y_4049_ = v___y_4054_;
v___y_4050_ = v___x_4057_;
goto v___jp_4048_;
}
else
{
uint8_t v___x_4058_; uint8_t v___x_4059_;
v___x_4058_ = 0;
v___x_4059_ = lean_uint8_dec_eq(v_userIsDragging_4035_, v___x_4058_);
if (v___x_4059_ == 0)
{
v___y_4049_ = v___y_4054_;
v___y_4050_ = v___x_4059_;
goto v___jp_4048_;
}
else
{
if (v___y_4054_ == 0)
{
v___y_4049_ = v___y_4054_;
v___y_4050_ = v___y_4055_;
goto v___jp_4048_;
}
else
{
goto v___jp_4046_;
}
}
}
}
v___jp_4060_:
{
uint8_t v___x_4062_;
v___x_4062_ = lean_uint32_dec_eq(v_targetScrollTopPx_4036_, v_currentScrollTopPx_4037_);
if (v___x_4062_ == 0)
{
uint8_t v___x_4063_;
v___x_4063_ = 1;
v___y_4054_ = v___y_4061_;
v___y_4055_ = v___x_4063_;
goto v___jp_4053_;
}
else
{
uint8_t v___x_4064_;
v___x_4064_ = 0;
v___y_4054_ = v___y_4061_;
v___y_4055_ = v___x_4064_;
goto v___jp_4053_;
}
}
}
}

LEAN_EXPORT uint64_t orb_client_parity_step(uint8_t v_clientTarget_4085_, uint32_t v_wireSchemaId_4086_, uint32_t v_transcriptSeq_4087_, uint32_t v_markdownBlocksCount_4088_, uint32_t v_sendQueueDepth_4089_, uint8_t v_scrollCorrectedInEpoch_4090_){
_start:
{
uint32_t v___y_4092_; uint32_t v___y_4093_; uint32_t v___y_4102_; uint8_t v___x_4109_; uint8_t v_validTarget_4110_; uint8_t v___y_4112_; uint32_t v___x_4117_; uint8_t v___x_4118_;
v___x_4109_ = 3;
v_validTarget_4110_ = lean_uint8_dec_le(v_clientTarget_4085_, v___x_4109_);
v___x_4117_ = 1;
v___x_4118_ = lean_uint32_dec_le(v___x_4117_, v_wireSchemaId_4086_);
if (v___x_4118_ == 0)
{
v___y_4112_ = v___x_4118_;
goto v___jp_4111_;
}
else
{
uint32_t v___x_4119_; uint8_t v___x_4120_;
v___x_4119_ = 2;
v___x_4120_ = lean_uint32_dec_le(v_wireSchemaId_4086_, v___x_4119_);
v___y_4112_ = v___x_4120_;
goto v___jp_4111_;
}
v___jp_4091_:
{
uint64_t v___x_4094_; uint64_t v___x_4095_; uint64_t v___x_4096_; uint64_t v___x_4097_; uint64_t v___x_4098_;
v___x_4094_ = lean_uint32_to_uint64(v___y_4092_);
v___x_4095_ = lean_uint32_to_uint64(v___y_4093_);
v___x_4096_ = 32ULL;
v___x_4097_ = lean_uint64_shift_left(v___x_4095_, v___x_4096_);
v___x_4098_ = lean_uint64_lor(v___x_4094_, v___x_4097_);
return v___x_4098_;
}
v___jp_4099_:
{
uint32_t v___x_4100_;
v___x_4100_ = 0;
v___y_4092_ = v___x_4100_;
v___y_4093_ = v___x_4100_;
goto v___jp_4091_;
}
v___jp_4101_:
{
uint32_t v___x_4103_; uint32_t v___x_4104_; uint32_t v___x_4105_; uint32_t v___x_4106_; uint32_t v___x_4107_; uint32_t v___x_4108_;
v___x_4103_ = 16;
v___x_4104_ = lean_uint32_shift_left(v_markdownBlocksCount_4088_, v___x_4103_);
v___x_4105_ = lean_uint32_xor(v_transcriptSeq_4087_, v___x_4104_);
v___x_4106_ = 24;
v___x_4107_ = lean_uint32_shift_left(v_sendQueueDepth_4089_, v___x_4106_);
v___x_4108_ = lean_uint32_xor(v___x_4105_, v___x_4107_);
v___y_4092_ = v___y_4102_;
v___y_4093_ = v___x_4108_;
goto v___jp_4091_;
}
v___jp_4111_:
{
if (v_validTarget_4110_ == 0)
{
goto v___jp_4099_;
}
else
{
if (v___y_4112_ == 0)
{
goto v___jp_4099_;
}
else
{
uint8_t v___x_4113_; uint8_t v___x_4114_;
v___x_4113_ = 1;
v___x_4114_ = lean_uint8_dec_eq(v_scrollCorrectedInEpoch_4090_, v___x_4113_);
if (v___x_4114_ == 0)
{
uint32_t v___x_4115_;
v___x_4115_ = 257;
v___y_4102_ = v___x_4115_;
goto v___jp_4101_;
}
else
{
uint32_t v___x_4116_;
v___x_4116_ = 769;
v___y_4102_ = v___x_4116_;
goto v___jp_4101_;
}
}
}
}
}
}

LEAN_EXPORT uint8_t orb_verify_approval(uint8_t v_signed_4399_, uint8_t v_owned_4400_, uint8_t v_pending_4401_, uint8_t v_unexpired_4402_, uint8_t v_unchanged_4403_, uint8_t v_risk_4404_, uint8_t v_confirmed_4405_){
_start:
{
uint8_t v___x_4406_; uint8_t v___x_4407_;
v___x_4406_ = 1;
v___x_4407_ = lean_uint8_dec_eq(v_signed_4399_, v___x_4406_);
if (v___x_4407_ == 0)
{
uint8_t v___x_4408_;
v___x_4408_ = 0;
return v___x_4408_;
}
else
{
uint8_t v___x_4409_;
v___x_4409_ = lean_uint8_dec_eq(v_owned_4400_, v___x_4406_);
if (v___x_4409_ == 0)
{
uint8_t v___x_4410_;
v___x_4410_ = 0;
return v___x_4410_;
}
else
{
uint8_t v___x_4411_;
v___x_4411_ = lean_uint8_dec_eq(v_pending_4401_, v___x_4406_);
if (v___x_4411_ == 0)
{
uint8_t v___x_4412_;
v___x_4412_ = 0;
return v___x_4412_;
}
else
{
uint8_t v___x_4413_;
v___x_4413_ = lean_uint8_dec_eq(v_unexpired_4402_, v___x_4406_);
if (v___x_4413_ == 0)
{
uint8_t v___x_4414_;
v___x_4414_ = 0;
return v___x_4414_;
}
else
{
uint8_t v___x_4415_;
v___x_4415_ = lean_uint8_dec_eq(v_unchanged_4403_, v___x_4406_);
if (v___x_4415_ == 0)
{
uint8_t v___x_4416_;
v___x_4416_ = 0;
return v___x_4416_;
}
else
{
uint8_t v___x_4417_; uint8_t v___x_4418_;
v___x_4417_ = 2;
v___x_4418_ = lean_uint8_dec_lt(v_risk_4404_, v___x_4417_);
if (v___x_4418_ == 0)
{
uint8_t v___x_4419_;
v___x_4419_ = lean_uint8_dec_eq(v_confirmed_4405_, v___x_4406_);
if (v___x_4419_ == 0)
{
uint8_t v___x_4420_;
v___x_4420_ = 0;
return v___x_4420_;
}
else
{
return v___x_4406_;
}
}
else
{
return v___x_4406_;
}
}
}
}
}
}
}
}

LEAN_EXPORT uint64_t orb_node_gc_step(uint64_t v_freeBytes_4437_, uint64_t v_floorBytes_4438_, uint64_t v_emergencyFloorBytes_4439_, uint64_t v_agedScratchBytes_4440_, uint64_t v_freshScratchBytes_4441_, uint64_t v_coldCacheBytes_4442_, uint64_t v_hotCacheBytes_4443_){
_start:
{
uint32_t v___y_4445_; uint32_t v___y_4446_; uint32_t v___y_4453_; uint8_t v___y_4454_; uint32_t v___y_4455_; uint8_t v___y_4460_; uint8_t v___y_4461_; uint32_t v___y_4462_; uint32_t v___y_4463_; uint8_t v___y_4468_; uint8_t v___y_4469_; uint32_t v___y_4470_; uint8_t v___y_4471_; uint32_t v___y_4472_; uint8_t v___y_4477_; uint8_t v___y_4478_; uint8_t v___y_4479_; uint32_t v___y_4480_; uint32_t v___y_4481_; uint8_t v___y_4486_; uint8_t v___y_4487_; uint8_t v___y_4488_; uint8_t v___y_4489_; uint32_t v___y_4490_; uint8_t v___y_4496_; uint8_t v___y_4497_; uint8_t v___y_4498_; uint8_t v___y_4499_; uint8_t v___y_4502_; uint8_t v___y_4503_; uint8_t v___y_4504_; uint8_t v___y_4505_; uint8_t v___y_4510_; uint8_t v___y_4511_; uint8_t v___y_4512_; uint8_t v___y_4513_; uint8_t v___y_4516_; uint8_t v___y_4517_; uint8_t v___y_4518_; uint8_t v___y_4519_; uint8_t v_underFloor_4520_;
v_underFloor_4520_ = lean_uint64_dec_lt(v_freeBytes_4437_, v_floorBytes_4438_);
if (v_underFloor_4520_ == 0)
{
uint64_t v___x_4521_;
v___x_4521_ = 309237645312ULL;
return v___x_4521_;
}
else
{
uint8_t v___x_4522_; uint8_t v_emerg_4523_; uint8_t v___y_4525_; uint8_t v___y_4526_; uint8_t v___y_4527_; uint64_t v___y_4528_; uint8_t v___y_4529_; uint64_t v___y_4532_; uint64_t v___y_4533_; uint64_t v___y_4534_; uint64_t v___y_4541_; uint64_t v___y_4542_; uint64_t v___y_4547_; uint64_t v_deficit_4551_; uint8_t v___x_4552_;
v___x_4522_ = 0;
v_emerg_4523_ = lean_uint64_dec_lt(v_freeBytes_4437_, v_emergencyFloorBytes_4439_);
v_deficit_4551_ = lean_uint64_sub(v_floorBytes_4438_, v_freeBytes_4437_);
v___x_4552_ = lean_uint64_dec_le(v_deficit_4551_, v_agedScratchBytes_4440_);
if (v___x_4552_ == 0)
{
uint64_t v___x_4553_;
v___x_4553_ = lean_uint64_sub(v_deficit_4551_, v_agedScratchBytes_4440_);
v___y_4547_ = v___x_4553_;
goto v___jp_4546_;
}
else
{
uint64_t v___x_4554_;
v___x_4554_ = 0ULL;
v___y_4547_ = v___x_4554_;
goto v___jp_4546_;
}
v___jp_4524_:
{
if (v___y_4525_ == 0)
{
if (v___y_4526_ == 0)
{
v___y_4502_ = v___y_4526_;
v___y_4503_ = v___y_4529_;
v___y_4504_ = v___y_4527_;
v___y_4505_ = v___x_4522_;
goto v___jp_4501_;
}
else
{
v___y_4496_ = v___y_4526_;
v___y_4497_ = v___y_4529_;
v___y_4498_ = v___y_4527_;
v___y_4499_ = v___x_4522_;
goto v___jp_4495_;
}
}
else
{
if (v___y_4526_ == 0)
{
if (v_underFloor_4520_ == 0)
{
v___y_4502_ = v___y_4526_;
v___y_4503_ = v___y_4529_;
v___y_4504_ = v___y_4527_;
v___y_4505_ = v_underFloor_4520_;
goto v___jp_4501_;
}
else
{
v___y_4510_ = v___y_4526_;
v___y_4511_ = v___y_4529_;
v___y_4512_ = v_underFloor_4520_;
v___y_4513_ = v___y_4527_;
goto v___jp_4509_;
}
}
else
{
if (v_emerg_4523_ == 0)
{
v___y_4516_ = v___y_4526_;
v___y_4517_ = v___y_4529_;
v___y_4518_ = v___y_4527_;
v___y_4519_ = v_emerg_4523_;
goto v___jp_4515_;
}
else
{
uint8_t v___x_4530_;
v___x_4530_ = lean_uint64_dec_lt(v___y_4528_, v_hotCacheBytes_4443_);
v___y_4516_ = v___y_4526_;
v___y_4517_ = v___y_4529_;
v___y_4518_ = v___y_4527_;
v___y_4519_ = v___x_4530_;
goto v___jp_4515_;
}
}
}
}
v___jp_4531_:
{
uint8_t v_unrecoverable_4535_; uint64_t v___x_4536_; uint8_t v_evictCold_4537_; uint8_t v_hasRem2_4538_; uint8_t v_hasRem3_4539_;
v_unrecoverable_4535_ = lean_uint64_dec_lt(v_hotCacheBytes_4443_, v___y_4534_);
v___x_4536_ = 0ULL;
v_evictCold_4537_ = lean_uint64_dec_lt(v___x_4536_, v___y_4533_);
v_hasRem2_4538_ = lean_uint64_dec_lt(v___x_4536_, v___y_4532_);
v_hasRem3_4539_ = lean_uint64_dec_lt(v___x_4536_, v___y_4534_);
if (v_hasRem2_4538_ == 0)
{
v___y_4525_ = v_hasRem3_4539_;
v___y_4526_ = v_unrecoverable_4535_;
v___y_4527_ = v_evictCold_4537_;
v___y_4528_ = v___x_4536_;
v___y_4529_ = v_emerg_4523_;
goto v___jp_4524_;
}
else
{
v___y_4525_ = v_hasRem3_4539_;
v___y_4526_ = v_unrecoverable_4535_;
v___y_4527_ = v_evictCold_4537_;
v___y_4528_ = v___x_4536_;
v___y_4529_ = v_underFloor_4520_;
goto v___jp_4524_;
}
}
v___jp_4540_:
{
uint8_t v___x_4543_;
v___x_4543_ = lean_uint64_dec_le(v___y_4542_, v_freshScratchBytes_4441_);
if (v___x_4543_ == 0)
{
uint64_t v___x_4544_;
v___x_4544_ = lean_uint64_sub(v___y_4542_, v_freshScratchBytes_4441_);
v___y_4532_ = v___y_4542_;
v___y_4533_ = v___y_4541_;
v___y_4534_ = v___x_4544_;
goto v___jp_4531_;
}
else
{
uint64_t v___x_4545_;
v___x_4545_ = 0ULL;
v___y_4532_ = v___y_4542_;
v___y_4533_ = v___y_4541_;
v___y_4534_ = v___x_4545_;
goto v___jp_4531_;
}
}
v___jp_4546_:
{
uint8_t v___x_4548_;
v___x_4548_ = lean_uint64_dec_le(v___y_4547_, v_coldCacheBytes_4442_);
if (v___x_4548_ == 0)
{
uint64_t v___x_4549_;
v___x_4549_ = lean_uint64_sub(v___y_4547_, v_coldCacheBytes_4442_);
v___y_4541_ = v___y_4547_;
v___y_4542_ = v___x_4549_;
goto v___jp_4540_;
}
else
{
uint64_t v___x_4550_;
v___x_4550_ = 0ULL;
v___y_4541_ = v___y_4547_;
v___y_4542_ = v___x_4550_;
goto v___jp_4540_;
}
}
}
v___jp_4444_:
{
uint64_t v___x_4447_; uint64_t v___x_4448_; uint64_t v___x_4449_; uint64_t v___x_4450_; uint64_t v___x_4451_;
v___x_4447_ = lean_uint32_to_uint64(v___y_4445_);
v___x_4448_ = lean_uint32_to_uint64(v___y_4446_);
v___x_4449_ = 32ULL;
v___x_4450_ = lean_uint64_shift_left(v___x_4448_, v___x_4449_);
v___x_4451_ = lean_uint64_lor(v___x_4447_, v___x_4450_);
return v___x_4451_;
}
v___jp_4452_:
{
uint32_t v_lo32_4456_;
v_lo32_4456_ = lean_uint32_lor(v___y_4453_, v___y_4455_);
if (v___y_4454_ == 0)
{
uint32_t v___x_4457_;
v___x_4457_ = 6;
v___y_4445_ = v_lo32_4456_;
v___y_4446_ = v___x_4457_;
goto v___jp_4444_;
}
else
{
uint32_t v___x_4458_;
v___x_4458_ = 0;
v___y_4445_ = v_lo32_4456_;
v___y_4446_ = v___x_4458_;
goto v___jp_4444_;
}
}
v___jp_4459_:
{
uint32_t v___x_4464_;
v___x_4464_ = lean_uint32_lor(v___y_4462_, v___y_4463_);
if (v___y_4460_ == 0)
{
uint32_t v___x_4465_;
v___x_4465_ = 0;
v___y_4453_ = v___x_4464_;
v___y_4454_ = v___y_4461_;
v___y_4455_ = v___x_4465_;
goto v___jp_4452_;
}
else
{
uint32_t v___x_4466_;
v___x_4466_ = 4096;
v___y_4453_ = v___x_4464_;
v___y_4454_ = v___y_4461_;
v___y_4455_ = v___x_4466_;
goto v___jp_4452_;
}
}
v___jp_4467_:
{
uint32_t v___x_4473_;
v___x_4473_ = lean_uint32_lor(v___y_4470_, v___y_4472_);
if (v___y_4471_ == 0)
{
uint32_t v___x_4474_;
v___x_4474_ = 0;
v___y_4460_ = v___y_4468_;
v___y_4461_ = v___y_4469_;
v___y_4462_ = v___x_4473_;
v___y_4463_ = v___x_4474_;
goto v___jp_4459_;
}
else
{
uint32_t v___x_4475_;
v___x_4475_ = 2048;
v___y_4460_ = v___y_4468_;
v___y_4461_ = v___y_4469_;
v___y_4462_ = v___x_4473_;
v___y_4463_ = v___x_4475_;
goto v___jp_4459_;
}
}
v___jp_4476_:
{
uint32_t v___x_4482_;
v___x_4482_ = lean_uint32_lor(v___y_4480_, v___y_4481_);
if (v___y_4478_ == 0)
{
uint32_t v___x_4483_;
v___x_4483_ = 0;
v___y_4468_ = v___y_4477_;
v___y_4469_ = v___y_4478_;
v___y_4470_ = v___x_4482_;
v___y_4471_ = v___y_4479_;
v___y_4472_ = v___x_4483_;
goto v___jp_4467_;
}
else
{
uint32_t v___x_4484_;
v___x_4484_ = 1024;
v___y_4468_ = v___y_4477_;
v___y_4469_ = v___y_4478_;
v___y_4470_ = v___x_4482_;
v___y_4471_ = v___y_4479_;
v___y_4472_ = v___x_4484_;
goto v___jp_4467_;
}
}
v___jp_4485_:
{
uint32_t v___x_4491_; uint32_t v___x_4492_;
v___x_4491_ = 256;
v___x_4492_ = lean_uint32_lor(v___y_4490_, v___x_4491_);
if (v___y_4489_ == 0)
{
uint32_t v___x_4493_;
v___x_4493_ = 0;
v___y_4477_ = v___y_4486_;
v___y_4478_ = v___y_4487_;
v___y_4479_ = v___y_4488_;
v___y_4480_ = v___x_4492_;
v___y_4481_ = v___x_4493_;
goto v___jp_4476_;
}
else
{
uint32_t v___x_4494_;
v___x_4494_ = 512;
v___y_4477_ = v___y_4486_;
v___y_4478_ = v___y_4487_;
v___y_4479_ = v___y_4488_;
v___y_4480_ = v___x_4492_;
v___y_4481_ = v___x_4494_;
goto v___jp_4476_;
}
}
v___jp_4495_:
{
uint32_t v___x_4500_;
v___x_4500_ = 5;
v___y_4486_ = v___y_4496_;
v___y_4487_ = v___y_4497_;
v___y_4488_ = v___y_4499_;
v___y_4489_ = v___y_4498_;
v___y_4490_ = v___x_4500_;
goto v___jp_4485_;
}
v___jp_4501_:
{
if (v___y_4503_ == 0)
{
if (v___y_4504_ == 0)
{
uint32_t v___x_4506_;
v___x_4506_ = 1;
v___y_4486_ = v___y_4502_;
v___y_4487_ = v___y_4503_;
v___y_4488_ = v___y_4505_;
v___y_4489_ = v___y_4504_;
v___y_4490_ = v___x_4506_;
goto v___jp_4485_;
}
else
{
uint32_t v___x_4507_;
v___x_4507_ = 2;
v___y_4486_ = v___y_4502_;
v___y_4487_ = v___y_4503_;
v___y_4488_ = v___y_4505_;
v___y_4489_ = v___y_4504_;
v___y_4490_ = v___x_4507_;
goto v___jp_4485_;
}
}
else
{
uint32_t v___x_4508_;
v___x_4508_ = 3;
v___y_4486_ = v___y_4502_;
v___y_4487_ = v___y_4503_;
v___y_4488_ = v___y_4505_;
v___y_4489_ = v___y_4504_;
v___y_4490_ = v___x_4508_;
goto v___jp_4485_;
}
}
v___jp_4509_:
{
uint32_t v___x_4514_;
v___x_4514_ = 4;
v___y_4486_ = v___y_4510_;
v___y_4487_ = v___y_4511_;
v___y_4488_ = v___y_4512_;
v___y_4489_ = v___y_4513_;
v___y_4490_ = v___x_4514_;
goto v___jp_4485_;
}
v___jp_4515_:
{
if (v___y_4519_ == 0)
{
v___y_4496_ = v___y_4516_;
v___y_4497_ = v___y_4517_;
v___y_4498_ = v___y_4518_;
v___y_4499_ = v___y_4519_;
goto v___jp_4495_;
}
else
{
v___y_4510_ = v___y_4516_;
v___y_4511_ = v___y_4517_;
v___y_4512_ = v___y_4519_;
v___y_4513_ = v___y_4518_;
goto v___jp_4509_;
}
}
}
}

LEAN_EXPORT uint64_t orb_node_disk_admission_step(uint64_t v_freeBytes_4571_, uint64_t v_reservedBytes_4572_, uint64_t v_nodeFloorBytes_4573_, uint64_t v_coreFloorBytes_4574_, uint64_t v_hysteresisBytes_4575_, uint8_t v_nodePinnedPressure_4576_){
_start:
{
uint32_t v___y_4578_; uint32_t v___y_4579_; uint8_t v___y_4586_; uint8_t v___y_4587_; uint8_t v___y_4588_; uint32_t v___y_4589_; uint64_t v___y_4595_; uint8_t v___y_4596_; uint8_t v___y_4597_; uint8_t v___y_4598_; uint8_t v___y_4606_; uint8_t v___y_4607_; uint8_t v___y_4608_; uint64_t v___y_4611_; uint64_t v___y_4612_; uint64_t v___y_4622_; uint8_t v___x_4626_;
v___x_4626_ = lean_uint64_dec_le(v_coreFloorBytes_4574_, v_nodeFloorBytes_4573_);
if (v___x_4626_ == 0)
{
v___y_4622_ = v_coreFloorBytes_4574_;
goto v___jp_4621_;
}
else
{
v___y_4622_ = v_nodeFloorBytes_4573_;
goto v___jp_4621_;
}
v___jp_4577_:
{
uint64_t v___x_4580_; uint64_t v___x_4581_; uint64_t v___x_4582_; uint64_t v___x_4583_; uint64_t v___x_4584_;
v___x_4580_ = lean_uint32_to_uint64(v___y_4579_);
v___x_4581_ = lean_uint32_to_uint64(v___y_4578_);
v___x_4582_ = 32ULL;
v___x_4583_ = lean_uint64_shift_left(v___x_4581_, v___x_4582_);
v___x_4584_ = lean_uint64_lor(v___x_4580_, v___x_4583_);
return v___x_4584_;
}
v___jp_4585_:
{
if (v___y_4588_ == 0)
{
if (v___y_4587_ == 0)
{
uint32_t v___x_4590_;
v___x_4590_ = 0;
v___y_4578_ = v___y_4589_;
v___y_4579_ = v___x_4590_;
goto v___jp_4577_;
}
else
{
if (v___y_4586_ == 0)
{
uint32_t v___x_4591_;
v___x_4591_ = 257;
v___y_4578_ = v___y_4589_;
v___y_4579_ = v___x_4591_;
goto v___jp_4577_;
}
else
{
uint32_t v___x_4592_;
v___x_4592_ = 769;
v___y_4578_ = v___y_4589_;
v___y_4579_ = v___x_4592_;
goto v___jp_4577_;
}
}
}
else
{
uint32_t v___x_4593_;
v___x_4593_ = 2;
v___y_4578_ = v___y_4589_;
v___y_4579_ = v___x_4593_;
goto v___jp_4577_;
}
}
v___jp_4594_:
{
uint64_t v___x_4599_; uint64_t v_rawHeadroomGiB_4600_; uint64_t v___x_4601_; uint8_t v___x_4602_;
v___x_4599_ = 30ULL;
v_rawHeadroomGiB_4600_ = lean_uint64_shift_right(v___y_4595_, v___x_4599_);
v___x_4601_ = 4294967295ULL;
v___x_4602_ = lean_uint64_dec_lt(v___x_4601_, v_rawHeadroomGiB_4600_);
if (v___x_4602_ == 0)
{
uint32_t v___x_4603_;
v___x_4603_ = lean_uint64_to_uint32(v_rawHeadroomGiB_4600_);
v___y_4586_ = v___y_4598_;
v___y_4587_ = v___y_4596_;
v___y_4588_ = v___y_4597_;
v___y_4589_ = v___x_4603_;
goto v___jp_4585_;
}
else
{
uint32_t v___x_4604_;
v___x_4604_ = 4294967295;
v___y_4586_ = v___y_4598_;
v___y_4587_ = v___y_4596_;
v___y_4588_ = v___y_4597_;
v___y_4589_ = v___x_4604_;
goto v___jp_4585_;
}
}
v___jp_4605_:
{
uint64_t v___x_4609_;
v___x_4609_ = 0ULL;
v___y_4595_ = v___x_4609_;
v___y_4596_ = v___y_4606_;
v___y_4597_ = v___y_4607_;
v___y_4598_ = v___y_4608_;
goto v___jp_4594_;
}
v___jp_4610_:
{
uint8_t v___x_4613_; uint8_t v___x_4614_;
v___x_4613_ = 0;
v___x_4614_ = lean_uint8_dec_eq(v_nodePinnedPressure_4576_, v___x_4613_);
if (v___x_4614_ == 0)
{
uint8_t v___x_4615_; uint8_t v_aboveFloor_4616_;
v___x_4615_ = 1;
v_aboveFloor_4616_ = lean_uint64_dec_le(v___y_4611_, v___y_4612_);
v___y_4606_ = v_aboveFloor_4616_;
v___y_4607_ = v___x_4615_;
v___y_4608_ = v___x_4614_;
goto v___jp_4605_;
}
else
{
uint8_t v___x_4617_; uint8_t v_aboveFloor_4618_;
v___x_4617_ = 0;
v_aboveFloor_4618_ = lean_uint64_dec_le(v___y_4611_, v___y_4612_);
if (v_aboveFloor_4618_ == 0)
{
v___y_4606_ = v_aboveFloor_4618_;
v___y_4607_ = v___x_4617_;
v___y_4608_ = v_aboveFloor_4618_;
goto v___jp_4605_;
}
else
{
uint64_t v___x_4619_; uint8_t v___x_4620_;
v___x_4619_ = lean_uint64_sub(v___y_4612_, v___y_4611_);
v___x_4620_ = lean_uint64_dec_lt(v___x_4619_, v_hysteresisBytes_4575_);
v___y_4595_ = v___x_4619_;
v___y_4596_ = v_aboveFloor_4618_;
v___y_4597_ = v___x_4617_;
v___y_4598_ = v___x_4620_;
goto v___jp_4594_;
}
}
}
v___jp_4621_:
{
uint8_t v___x_4623_;
v___x_4623_ = lean_uint64_dec_le(v_reservedBytes_4572_, v_freeBytes_4571_);
if (v___x_4623_ == 0)
{
uint64_t v___x_4624_;
v___x_4624_ = 0ULL;
v___y_4611_ = v___y_4622_;
v___y_4612_ = v___x_4624_;
goto v___jp_4610_;
}
else
{
uint64_t v___x_4625_;
v___x_4625_ = lean_uint64_sub(v_freeBytes_4571_, v_reservedBytes_4572_);
v___y_4611_ = v___y_4622_;
v___y_4612_ = v___x_4625_;
goto v___jp_4610_;
}
}
}
}

LEAN_EXPORT uint32_t orb_vm_lifecycle_step(uint8_t v_ownerClass_4641_, uint8_t v_busy_4642_, uint8_t v_ttlExpired_4643_, uint8_t v_graceOrIdleElapsed_4644_, uint8_t v_workingIdleEnabled_4645_, uint8_t v_supportsFreeStop_4646_, uint8_t v_minDeletePending_4647_){
_start:
{
uint8_t v___x_4648_; uint8_t v___x_4649_;
v___x_4648_ = 1;
v___x_4649_ = lean_uint8_dec_eq(v_ttlExpired_4643_, v___x_4648_);
if (v___x_4649_ == 0)
{
uint8_t v___x_4650_;
v___x_4650_ = lean_uint8_dec_eq(v_busy_4642_, v___x_4648_);
if (v___x_4650_ == 0)
{
uint8_t v___x_4651_; uint8_t v___x_4652_;
v___x_4651_ = 0;
v___x_4652_ = lean_uint8_dec_eq(v_ownerClass_4641_, v___x_4651_);
if (v___x_4652_ == 0)
{
uint8_t v___x_4653_;
v___x_4653_ = lean_uint8_dec_eq(v_ownerClass_4641_, v___x_4648_);
if (v___x_4653_ == 0)
{
uint8_t v___x_4654_; uint8_t v___x_4655_;
v___x_4654_ = 2;
v___x_4655_ = lean_uint8_dec_eq(v_ownerClass_4641_, v___x_4654_);
if (v___x_4655_ == 0)
{
uint8_t v___x_4656_;
v___x_4656_ = lean_uint8_dec_eq(v_graceOrIdleElapsed_4644_, v___x_4651_);
if (v___x_4656_ == 0)
{
uint8_t v___x_4657_;
v___x_4657_ = lean_uint8_dec_eq(v_minDeletePending_4647_, v___x_4648_);
if (v___x_4657_ == 0)
{
uint32_t v___x_4658_;
v___x_4658_ = 259;
return v___x_4658_;
}
else
{
uint32_t v___x_4659_;
v___x_4659_ = 65537;
return v___x_4659_;
}
}
else
{
uint32_t v___x_4660_;
v___x_4660_ = 1;
return v___x_4660_;
}
}
else
{
uint8_t v___x_4661_;
v___x_4661_ = lean_uint8_dec_eq(v_graceOrIdleElapsed_4644_, v___x_4651_);
if (v___x_4661_ == 0)
{
uint8_t v___x_4662_;
v___x_4662_ = lean_uint8_dec_eq(v_supportsFreeStop_4646_, v___x_4648_);
if (v___x_4662_ == 0)
{
uint8_t v___x_4663_;
v___x_4663_ = lean_uint8_dec_eq(v_minDeletePending_4647_, v___x_4648_);
if (v___x_4663_ == 0)
{
uint32_t v___x_4664_;
v___x_4664_ = 259;
return v___x_4664_;
}
else
{
uint32_t v___x_4665_;
v___x_4665_ = 65537;
return v___x_4665_;
}
}
else
{
uint32_t v___x_4666_;
v___x_4666_ = 258;
return v___x_4666_;
}
}
else
{
uint32_t v___x_4667_;
v___x_4667_ = 1;
return v___x_4667_;
}
}
}
else
{
uint8_t v___x_4668_;
v___x_4668_ = lean_uint8_dec_eq(v_workingIdleEnabled_4645_, v___x_4651_);
if (v___x_4668_ == 0)
{
uint8_t v___x_4669_;
v___x_4669_ = lean_uint8_dec_eq(v_graceOrIdleElapsed_4644_, v___x_4651_);
if (v___x_4669_ == 0)
{
uint8_t v___x_4670_;
v___x_4670_ = lean_uint8_dec_eq(v_minDeletePending_4647_, v___x_4648_);
if (v___x_4670_ == 0)
{
uint32_t v___x_4671_;
v___x_4671_ = 259;
return v___x_4671_;
}
else
{
uint32_t v___x_4672_;
v___x_4672_ = 65537;
return v___x_4672_;
}
}
else
{
uint32_t v___x_4673_;
v___x_4673_ = 1;
return v___x_4673_;
}
}
else
{
uint32_t v___x_4674_;
v___x_4674_ = 0;
return v___x_4674_;
}
}
}
else
{
uint32_t v___x_4675_;
v___x_4675_ = 0;
return v___x_4675_;
}
}
else
{
uint32_t v___x_4676_;
v___x_4676_ = 0;
return v___x_4676_;
}
}
else
{
uint8_t v___x_4677_;
v___x_4677_ = lean_uint8_dec_eq(v_minDeletePending_4647_, v___x_4648_);
if (v___x_4677_ == 0)
{
uint32_t v___x_4678_;
v___x_4678_ = 259;
return v___x_4678_;
}
else
{
uint32_t v___x_4679_;
v___x_4679_ = 65537;
return v___x_4679_;
}
}
}
}

LEAN_EXPORT uint32_t orb_vm_claim_step(uint8_t v_isLive_4696_, uint8_t v_sameTenant_4697_, uint8_t v_ownerNone_4698_, uint8_t v_ownerInLineage_4699_){
_start:
{
uint8_t v___x_4700_; uint8_t v___x_4701_;
v___x_4700_ = 1;
v___x_4701_ = lean_uint8_dec_eq(v_isLive_4696_, v___x_4700_);
if (v___x_4701_ == 0)
{
uint32_t v___x_4702_;
v___x_4702_ = 512;
return v___x_4702_;
}
else
{
uint8_t v___x_4703_;
v___x_4703_ = lean_uint8_dec_eq(v_sameTenant_4697_, v___x_4700_);
if (v___x_4703_ == 0)
{
uint32_t v___x_4704_;
v___x_4704_ = 512;
return v___x_4704_;
}
else
{
uint8_t v___x_4705_;
v___x_4705_ = lean_uint8_dec_eq(v_ownerNone_4698_, v___x_4700_);
if (v___x_4705_ == 0)
{
uint8_t v___x_4706_;
v___x_4706_ = lean_uint8_dec_eq(v_ownerInLineage_4699_, v___x_4700_);
if (v___x_4706_ == 0)
{
uint32_t v___x_4707_;
v___x_4707_ = 512;
return v___x_4707_;
}
else
{
uint32_t v___x_4708_;
v___x_4708_ = 257;
return v___x_4708_;
}
}
else
{
uint32_t v___x_4709_;
v___x_4709_ = 257;
return v___x_4709_;
}
}
}
}
}

LEAN_EXPORT uint32_t orb_compute_secret_gate(uint8_t v_isCoreReservedComputeKey_4720_, uint8_t v_callerOnManagedNode_4721_, uint8_t v_isAllowlistedManagedSecret_4722_, uint8_t v_operatorBreakGlass_4723_){
_start:
{
uint8_t v___x_4724_; uint8_t v___x_4732_;
v___x_4724_ = 1;
v___x_4732_ = lean_uint8_dec_eq(v_isCoreReservedComputeKey_4720_, v___x_4724_);
if (v___x_4732_ == 0)
{
goto v___jp_4725_;
}
else
{
uint8_t v___x_4733_; uint8_t v___x_4734_;
v___x_4733_ = 0;
v___x_4734_ = lean_uint8_dec_eq(v_operatorBreakGlass_4723_, v___x_4733_);
if (v___x_4734_ == 0)
{
goto v___jp_4725_;
}
else
{
uint32_t v___x_4735_;
v___x_4735_ = 512;
return v___x_4735_;
}
}
v___jp_4725_:
{
uint8_t v___x_4726_;
v___x_4726_ = lean_uint8_dec_eq(v_callerOnManagedNode_4721_, v___x_4724_);
if (v___x_4726_ == 0)
{
uint32_t v___x_4727_;
v___x_4727_ = 257;
return v___x_4727_;
}
else
{
uint8_t v___x_4728_; uint8_t v___x_4729_;
v___x_4728_ = 0;
v___x_4729_ = lean_uint8_dec_eq(v_isAllowlistedManagedSecret_4722_, v___x_4728_);
if (v___x_4729_ == 0)
{
uint32_t v___x_4730_;
v___x_4730_ = 257;
return v___x_4730_;
}
else
{
uint32_t v___x_4731_;
v___x_4731_ = 512;
return v___x_4731_;
}
}
}
}
}

LEAN_EXPORT uint64_t orb_wire_apply_patch_step(uint64_t v_currentRev_4746_, uint64_t v_incomingRev_4747_, uint8_t v_currentHasVal_4748_, uint32_t v_currentVal_4749_, uint8_t v_presence_4750_, uint32_t v_incomingVal_4751_){
_start:
{
uint32_t v___y_4753_; uint32_t v___y_4754_; uint8_t v___x_4760_; uint8_t v___y_4762_; uint32_t v___y_4763_; uint8_t v___y_4764_; uint32_t v___y_4765_; uint32_t v___y_4771_; uint32_t v___y_4772_; uint8_t v___x_4786_; uint32_t v___y_4788_;
v___x_4760_ = 1;
v___x_4786_ = lean_uint8_dec_eq(v_currentHasVal_4748_, v___x_4760_);
if (v___x_4786_ == 0)
{
uint32_t v___x_4790_;
v___x_4790_ = 0;
v___y_4788_ = v___x_4790_;
goto v___jp_4787_;
}
else
{
uint32_t v___x_4791_;
v___x_4791_ = 512;
v___y_4788_ = v___x_4791_;
goto v___jp_4787_;
}
v___jp_4752_:
{
uint64_t v___x_4755_; uint64_t v___x_4756_; uint64_t v___x_4757_; uint64_t v___x_4758_; uint64_t v___x_4759_;
v___x_4755_ = lean_uint32_to_uint64(v___y_4753_);
v___x_4756_ = lean_uint32_to_uint64(v___y_4754_);
v___x_4757_ = 32ULL;
v___x_4758_ = lean_uint64_shift_left(v___x_4756_, v___x_4757_);
v___x_4759_ = lean_uint64_lor(v___x_4755_, v___x_4758_);
return v___x_4759_;
}
v___jp_4761_:
{
if (v___y_4764_ == 0)
{
v___y_4753_ = v___y_4765_;
v___y_4754_ = v___y_4763_;
goto v___jp_4752_;
}
else
{
if (v___y_4762_ == 0)
{
v___y_4753_ = v___y_4765_;
v___y_4754_ = v___y_4763_;
goto v___jp_4752_;
}
else
{
uint8_t v___x_4766_; uint8_t v___x_4767_;
v___x_4766_ = 0;
v___x_4767_ = lean_uint8_dec_eq(v_presence_4750_, v___x_4766_);
if (v___x_4767_ == 0)
{
uint8_t v___x_4768_;
v___x_4768_ = lean_uint8_dec_eq(v_presence_4750_, v___x_4760_);
if (v___x_4768_ == 0)
{
uint32_t v___x_4769_;
v___x_4769_ = 0;
v___y_4753_ = v___y_4765_;
v___y_4754_ = v___x_4769_;
goto v___jp_4752_;
}
else
{
v___y_4753_ = v___y_4765_;
v___y_4754_ = v_incomingVal_4751_;
goto v___jp_4752_;
}
}
else
{
v___y_4753_ = v___y_4765_;
v___y_4754_ = v___y_4763_;
goto v___jp_4752_;
}
}
}
}
v___jp_4770_:
{
uint8_t v___x_4773_; uint8_t v_validPresence_4774_; uint8_t v_freshRev_4775_;
v___x_4773_ = 2;
v_validPresence_4774_ = lean_uint8_dec_le(v_presence_4750_, v___x_4773_);
v_freshRev_4775_ = lean_uint64_dec_lt(v_currentRev_4746_, v_incomingRev_4747_);
if (v_validPresence_4774_ == 0)
{
uint32_t v___x_4776_;
v___x_4776_ = 0;
v___y_4762_ = v_freshRev_4775_;
v___y_4763_ = v___y_4772_;
v___y_4764_ = v_validPresence_4774_;
v___y_4765_ = v___x_4776_;
goto v___jp_4761_;
}
else
{
if (v_freshRev_4775_ == 0)
{
uint32_t v___x_4777_; uint32_t v___x_4778_;
v___x_4777_ = 2;
v___x_4778_ = lean_uint32_lor(v___x_4777_, v___y_4771_);
v___y_4762_ = v_freshRev_4775_;
v___y_4763_ = v___y_4772_;
v___y_4764_ = v_validPresence_4774_;
v___y_4765_ = v___x_4778_;
goto v___jp_4761_;
}
else
{
uint8_t v___x_4779_; uint8_t v___x_4780_;
v___x_4779_ = 0;
v___x_4780_ = lean_uint8_dec_eq(v_presence_4750_, v___x_4779_);
if (v___x_4780_ == 0)
{
uint8_t v___x_4781_;
v___x_4781_ = lean_uint8_dec_eq(v_presence_4750_, v___x_4760_);
if (v___x_4781_ == 0)
{
uint32_t v___x_4782_;
v___x_4782_ = 260;
v___y_4762_ = v_freshRev_4775_;
v___y_4763_ = v___y_4772_;
v___y_4764_ = v_validPresence_4774_;
v___y_4765_ = v___x_4782_;
goto v___jp_4761_;
}
else
{
uint32_t v___x_4783_;
v___x_4783_ = 769;
v___y_4762_ = v_freshRev_4775_;
v___y_4763_ = v___y_4772_;
v___y_4764_ = v_validPresence_4774_;
v___y_4765_ = v___x_4783_;
goto v___jp_4761_;
}
}
else
{
uint32_t v___x_4784_; uint32_t v___x_4785_;
v___x_4784_ = 259;
v___x_4785_ = lean_uint32_lor(v___x_4784_, v___y_4771_);
v___y_4762_ = v_freshRev_4775_;
v___y_4763_ = v___y_4772_;
v___y_4764_ = v_validPresence_4774_;
v___y_4765_ = v___x_4785_;
goto v___jp_4761_;
}
}
}
}
v___jp_4787_:
{
if (v___x_4786_ == 0)
{
uint32_t v___x_4789_;
v___x_4789_ = 0;
v___y_4771_ = v___y_4788_;
v___y_4772_ = v___x_4789_;
goto v___jp_4770_;
}
else
{
v___y_4771_ = v___y_4788_;
v___y_4772_ = v_currentVal_4749_;
goto v___jp_4770_;
}
}
}
}

LEAN_EXPORT uint64_t orb_wire_machine_step(uint32_t v_schemaId_4806_, uint64_t v_stateRev_4807_, uint64_t v_eventSeq_4808_, uint8_t v_effectKind_4809_, uint8_t v_effectAdmitted_4810_, uint32_t v_outCap_4811_, uint32_t v_requiredOutBytes_4812_){
_start:
{
uint32_t v___y_4814_; uint32_t v___y_4815_; uint32_t v_curRev32_4821_; uint8_t v_capOk_4822_; uint8_t v___y_4824_; uint8_t v___y_4825_; uint8_t v___y_4826_; uint32_t v___y_4827_; uint8_t v___y_4830_; uint8_t v___y_4831_; uint8_t v___y_4832_; uint32_t v___y_4833_; uint8_t v___y_4841_; uint8_t v___y_4842_; uint8_t v___y_4843_; uint8_t v___y_4849_; uint32_t v___x_4855_; uint8_t v___x_4856_;
v_curRev32_4821_ = lean_uint64_to_uint32(v_stateRev_4807_);
v_capOk_4822_ = lean_uint32_dec_le(v_requiredOutBytes_4812_, v_outCap_4811_);
v___x_4855_ = 1;
v___x_4856_ = lean_uint32_dec_le(v___x_4855_, v_schemaId_4806_);
if (v___x_4856_ == 0)
{
v___y_4849_ = v___x_4856_;
goto v___jp_4848_;
}
else
{
uint32_t v___x_4857_; uint8_t v___x_4858_;
v___x_4857_ = 2;
v___x_4858_ = lean_uint32_dec_le(v_schemaId_4806_, v___x_4857_);
v___y_4849_ = v___x_4858_;
goto v___jp_4848_;
}
v___jp_4813_:
{
uint64_t v___x_4816_; uint64_t v___x_4817_; uint64_t v___x_4818_; uint64_t v___x_4819_; uint64_t v___x_4820_;
v___x_4816_ = lean_uint32_to_uint64(v___y_4814_);
v___x_4817_ = lean_uint32_to_uint64(v___y_4815_);
v___x_4818_ = 32ULL;
v___x_4819_ = lean_uint64_shift_left(v___x_4817_, v___x_4818_);
v___x_4820_ = lean_uint64_lor(v___x_4816_, v___x_4819_);
return v___x_4820_;
}
v___jp_4823_:
{
if (v_capOk_4822_ == 0)
{
v___y_4814_ = v___y_4827_;
v___y_4815_ = v_curRev32_4821_;
goto v___jp_4813_;
}
else
{
if (v___y_4824_ == 0)
{
v___y_4814_ = v___y_4827_;
v___y_4815_ = v_curRev32_4821_;
goto v___jp_4813_;
}
else
{
if (v___y_4826_ == 0)
{
v___y_4814_ = v___y_4827_;
v___y_4815_ = v_curRev32_4821_;
goto v___jp_4813_;
}
else
{
if (v___y_4825_ == 0)
{
v___y_4814_ = v___y_4827_;
v___y_4815_ = v_curRev32_4821_;
goto v___jp_4813_;
}
else
{
uint32_t v___x_4828_;
v___x_4828_ = lean_uint64_to_uint32(v_eventSeq_4808_);
v___y_4814_ = v___y_4827_;
v___y_4815_ = v___x_4828_;
goto v___jp_4813_;
}
}
}
}
}
v___jp_4829_:
{
if (v_capOk_4822_ == 0)
{
uint32_t v___x_4834_;
v___x_4834_ = 5;
v___y_4824_ = v___y_4830_;
v___y_4825_ = v___y_4832_;
v___y_4826_ = v___y_4831_;
v___y_4827_ = v___x_4834_;
goto v___jp_4823_;
}
else
{
if (v___y_4830_ == 0)
{
uint32_t v___x_4835_;
v___x_4835_ = 2;
v___y_4824_ = v___y_4830_;
v___y_4825_ = v___y_4832_;
v___y_4826_ = v___y_4831_;
v___y_4827_ = v___x_4835_;
goto v___jp_4823_;
}
else
{
if (v___y_4831_ == 0)
{
uint32_t v___x_4836_;
v___x_4836_ = 3;
v___y_4824_ = v___y_4830_;
v___y_4825_ = v___y_4832_;
v___y_4826_ = v___y_4831_;
v___y_4827_ = v___x_4836_;
goto v___jp_4823_;
}
else
{
if (v___y_4832_ == 0)
{
uint32_t v___x_4837_;
v___x_4837_ = 4;
v___y_4824_ = v___y_4830_;
v___y_4825_ = v___y_4832_;
v___y_4826_ = v___y_4831_;
v___y_4827_ = v___x_4837_;
goto v___jp_4823_;
}
else
{
uint32_t v___x_4838_; uint32_t v___x_4839_;
v___x_4838_ = 257;
v___x_4839_ = lean_uint32_lor(v___x_4838_, v___y_4833_);
v___y_4824_ = v___y_4830_;
v___y_4825_ = v___y_4832_;
v___y_4826_ = v___y_4831_;
v___y_4827_ = v___x_4839_;
goto v___jp_4823_;
}
}
}
}
}
v___jp_4840_:
{
uint8_t v___x_4844_; uint8_t v___x_4845_;
v___x_4844_ = 0;
v___x_4845_ = lean_uint8_dec_eq(v_effectKind_4809_, v___x_4844_);
if (v___x_4845_ == 0)
{
uint32_t v___x_4846_;
v___x_4846_ = 512;
v___y_4830_ = v___y_4841_;
v___y_4831_ = v___y_4842_;
v___y_4832_ = v___y_4843_;
v___y_4833_ = v___x_4846_;
goto v___jp_4829_;
}
else
{
uint32_t v___x_4847_;
v___x_4847_ = 0;
v___y_4830_ = v___y_4841_;
v___y_4831_ = v___y_4842_;
v___y_4832_ = v___y_4843_;
v___y_4833_ = v___x_4847_;
goto v___jp_4829_;
}
}
v___jp_4848_:
{
uint8_t v_seqFresh_4850_; uint8_t v___x_4851_; uint8_t v___x_4852_;
v_seqFresh_4850_ = lean_uint64_dec_lt(v_stateRev_4807_, v_eventSeq_4808_);
v___x_4851_ = 1;
v___x_4852_ = lean_uint8_dec_eq(v_effectAdmitted_4810_, v___x_4851_);
if (v___x_4852_ == 0)
{
v___y_4841_ = v___y_4849_;
v___y_4842_ = v_seqFresh_4850_;
v___y_4843_ = v___x_4852_;
goto v___jp_4840_;
}
else
{
uint8_t v___x_4853_; uint8_t v___x_4854_;
v___x_4853_ = 5;
v___x_4854_ = lean_uint8_dec_le(v_effectKind_4809_, v___x_4853_);
v___y_4841_ = v___y_4849_;
v___y_4842_ = v_seqFresh_4850_;
v___y_4843_ = v___x_4854_;
goto v___jp_4840_;
}
}
}
}

LEAN_EXPORT uint64_t orb_hierarchy_merge_step(uint64_t v_currentEpoch_4875_, uint64_t v_incomingEpoch_4876_, uint64_t v_archiveEpoch_4877_, uint8_t v_curArchived_4878_, uint8_t v_curSuperseded_4879_, uint8_t v_isPartialPatch_4880_, uint8_t v_parentPresence_4881_, uint32_t v_curParentOrd_4882_, uint32_t v_incParentOrd_4883_, uint8_t v_incArchive_4884_, uint8_t v_incUnarchive_4885_, uint8_t v_incSupersede_4886_){
_start:
{
uint32_t v___y_4888_; uint32_t v___y_4889_; uint32_t v___y_4890_; uint32_t v___y_4891_; uint32_t v___y_4892_; uint32_t v___y_4902_; uint32_t v___y_4903_; uint32_t v___y_4904_; uint32_t v___y_4905_; uint32_t v___y_4908_; uint32_t v___y_4909_; uint32_t v___y_4910_; uint8_t v___y_4913_; uint8_t v___y_4914_; uint32_t v___y_4915_; uint8_t v___y_4916_; uint32_t v___y_4917_; uint32_t v___y_4918_; uint8_t v___y_4923_; uint8_t v___y_4924_; uint8_t v___y_4925_; uint32_t v___y_4926_; uint8_t v___y_4927_; uint32_t v___y_4928_; uint8_t v___y_4932_; uint8_t v___y_4933_; uint8_t v___y_4934_; uint8_t v___y_4935_; uint8_t v___y_4936_; uint32_t v___y_4937_; uint8_t v___x_4940_; uint8_t v___y_4942_; uint8_t v___y_4943_; uint8_t v___y_4944_; uint8_t v___y_4945_; uint8_t v___y_4946_; uint8_t v___y_4947_; uint8_t v___y_4948_; uint8_t v___y_4949_; uint8_t v___y_4950_; uint8_t v___y_4959_; uint8_t v___y_4960_; uint8_t v___y_4961_; uint8_t v___y_4962_; uint8_t v___y_4963_; uint8_t v___y_4964_; uint8_t v___y_4965_; uint8_t v___y_4966_; uint8_t v___y_4967_; uint8_t v___x_4969_; uint8_t v___y_4971_; uint8_t v___y_4972_; uint8_t v___y_4973_; uint8_t v___y_4974_; uint8_t v___y_4975_; uint8_t v___y_4976_; uint8_t v___y_4977_; uint8_t v___y_4978_; uint8_t v___y_4979_; uint8_t v___y_4982_; uint8_t v___y_4983_; uint8_t v___y_4984_; uint8_t v___y_4985_; uint8_t v___y_4986_; uint8_t v___y_4987_; uint8_t v___y_4988_; uint8_t v___y_4989_; uint8_t v___y_4990_; uint8_t v___y_4992_; uint8_t v___y_4993_; uint8_t v___y_4994_; uint8_t v___y_4995_; uint8_t v___y_4996_; uint8_t v___y_4997_; uint8_t v___y_4998_; uint8_t v___y_4999_; uint8_t v___y_5000_; uint8_t v___y_5004_;
v___x_4940_ = 1;
v___x_4969_ = lean_uint8_dec_eq(v_curSuperseded_4879_, v___x_4940_);
if (v___x_4969_ == 0)
{
uint8_t v___x_5015_;
v___x_5015_ = lean_uint8_dec_eq(v_incSupersede_4886_, v___x_4940_);
v___y_5004_ = v___x_5015_;
goto v___jp_5003_;
}
else
{
v___y_5004_ = v___x_4969_;
goto v___jp_5003_;
}
v___jp_4887_:
{
uint32_t v___x_4893_; uint32_t v___x_4894_; uint32_t v_lo32_4895_; uint64_t v___x_4896_; uint64_t v___x_4897_; uint64_t v___x_4898_; uint64_t v___x_4899_; uint64_t v___x_4900_;
v___x_4893_ = lean_uint32_lor(v___y_4892_, v___y_4890_);
v___x_4894_ = lean_uint32_lor(v___x_4893_, v___y_4891_);
v_lo32_4895_ = lean_uint32_lor(v___x_4894_, v___y_4888_);
v___x_4896_ = lean_uint32_to_uint64(v_lo32_4895_);
v___x_4897_ = lean_uint32_to_uint64(v___y_4889_);
v___x_4898_ = 32ULL;
v___x_4899_ = lean_uint64_shift_left(v___x_4897_, v___x_4898_);
v___x_4900_ = lean_uint64_lor(v___x_4896_, v___x_4899_);
return v___x_4900_;
}
v___jp_4901_:
{
uint32_t v___x_4906_;
v___x_4906_ = 257;
v___y_4888_ = v___y_4905_;
v___y_4889_ = v___y_4902_;
v___y_4890_ = v___y_4903_;
v___y_4891_ = v___y_4904_;
v___y_4892_ = v___x_4906_;
goto v___jp_4887_;
}
v___jp_4907_:
{
uint32_t v___x_4911_;
v___x_4911_ = 0;
v___y_4902_ = v___y_4908_;
v___y_4903_ = v___y_4909_;
v___y_4904_ = v___y_4910_;
v___y_4905_ = v___x_4911_;
goto v___jp_4901_;
}
v___jp_4912_:
{
if (v___y_4913_ == 0)
{
uint32_t v___x_4919_; uint32_t v___x_4920_;
v___x_4919_ = 0;
v___x_4920_ = 2;
v___y_4888_ = v___x_4919_;
v___y_4889_ = v___y_4915_;
v___y_4890_ = v___y_4917_;
v___y_4891_ = v___y_4918_;
v___y_4892_ = v___x_4920_;
goto v___jp_4887_;
}
else
{
if (v___y_4916_ == 0)
{
v___y_4908_ = v___y_4915_;
v___y_4909_ = v___y_4917_;
v___y_4910_ = v___y_4918_;
goto v___jp_4907_;
}
else
{
if (v___y_4914_ == 0)
{
v___y_4908_ = v___y_4915_;
v___y_4909_ = v___y_4917_;
v___y_4910_ = v___y_4918_;
goto v___jp_4907_;
}
else
{
uint32_t v___x_4921_;
v___x_4921_ = 2048;
v___y_4902_ = v___y_4915_;
v___y_4903_ = v___y_4917_;
v___y_4904_ = v___y_4918_;
v___y_4905_ = v___x_4921_;
goto v___jp_4901_;
}
}
}
}
v___jp_4922_:
{
if (v___y_4923_ == 0)
{
uint32_t v___x_4929_;
v___x_4929_ = 0;
v___y_4913_ = v___y_4924_;
v___y_4914_ = v___y_4925_;
v___y_4915_ = v___y_4926_;
v___y_4916_ = v___y_4927_;
v___y_4917_ = v___y_4928_;
v___y_4918_ = v___x_4929_;
goto v___jp_4912_;
}
else
{
uint32_t v___x_4930_;
v___x_4930_ = 1024;
v___y_4913_ = v___y_4924_;
v___y_4914_ = v___y_4925_;
v___y_4915_ = v___y_4926_;
v___y_4916_ = v___y_4927_;
v___y_4917_ = v___y_4928_;
v___y_4918_ = v___x_4930_;
goto v___jp_4912_;
}
}
v___jp_4931_:
{
if (v___y_4935_ == 0)
{
uint32_t v___x_4938_;
v___x_4938_ = 0;
v___y_4923_ = v___y_4932_;
v___y_4924_ = v___y_4933_;
v___y_4925_ = v___y_4934_;
v___y_4926_ = v___y_4937_;
v___y_4927_ = v___y_4936_;
v___y_4928_ = v___x_4938_;
goto v___jp_4922_;
}
else
{
uint32_t v___x_4939_;
v___x_4939_ = 512;
v___y_4923_ = v___y_4932_;
v___y_4924_ = v___y_4933_;
v___y_4925_ = v___y_4934_;
v___y_4926_ = v___y_4937_;
v___y_4927_ = v___y_4936_;
v___y_4928_ = v___x_4939_;
goto v___jp_4922_;
}
}
v___jp_4941_:
{
if (v___y_4945_ == 0)
{
v___y_4932_ = v___y_4942_;
v___y_4933_ = v___y_4945_;
v___y_4934_ = v___y_4944_;
v___y_4935_ = v___y_4946_;
v___y_4936_ = v___y_4948_;
v___y_4937_ = v_curParentOrd_4882_;
goto v___jp_4931_;
}
else
{
if (v___y_4949_ == 0)
{
v___y_4932_ = v___y_4942_;
v___y_4933_ = v___y_4949_;
v___y_4934_ = v___y_4944_;
v___y_4935_ = v___y_4946_;
v___y_4936_ = v___y_4948_;
v___y_4937_ = v_curParentOrd_4882_;
goto v___jp_4931_;
}
else
{
if (v___y_4947_ == 0)
{
if (v___y_4950_ == 0)
{
if (v___y_4943_ == 0)
{
uint8_t v___x_4951_;
v___x_4951_ = lean_uint8_dec_eq(v_parentPresence_4881_, v___x_4940_);
if (v___x_4951_ == 0)
{
uint32_t v___x_4952_;
v___x_4952_ = 0;
v___y_4932_ = v___y_4942_;
v___y_4933_ = v___y_4949_;
v___y_4934_ = v___y_4944_;
v___y_4935_ = v___y_4946_;
v___y_4936_ = v___y_4948_;
v___y_4937_ = v___x_4952_;
goto v___jp_4931_;
}
else
{
v___y_4932_ = v___y_4942_;
v___y_4933_ = v___y_4949_;
v___y_4934_ = v___y_4944_;
v___y_4935_ = v___y_4946_;
v___y_4936_ = v___y_4948_;
v___y_4937_ = v_incParentOrd_4883_;
goto v___jp_4931_;
}
}
else
{
uint8_t v___x_4953_; uint8_t v___x_4954_;
v___x_4953_ = 0;
v___x_4954_ = lean_uint8_dec_eq(v_parentPresence_4881_, v___x_4953_);
if (v___x_4954_ == 0)
{
uint8_t v___x_4955_;
v___x_4955_ = lean_uint8_dec_eq(v_parentPresence_4881_, v___x_4940_);
if (v___x_4955_ == 0)
{
uint32_t v___x_4956_;
v___x_4956_ = 0;
v___y_4932_ = v___y_4942_;
v___y_4933_ = v___y_4949_;
v___y_4934_ = v___y_4944_;
v___y_4935_ = v___y_4946_;
v___y_4936_ = v___y_4948_;
v___y_4937_ = v___x_4956_;
goto v___jp_4931_;
}
else
{
v___y_4932_ = v___y_4942_;
v___y_4933_ = v___y_4949_;
v___y_4934_ = v___y_4944_;
v___y_4935_ = v___y_4946_;
v___y_4936_ = v___y_4948_;
v___y_4937_ = v_incParentOrd_4883_;
goto v___jp_4931_;
}
}
else
{
v___y_4932_ = v___y_4942_;
v___y_4933_ = v___y_4949_;
v___y_4934_ = v___y_4944_;
v___y_4935_ = v___y_4946_;
v___y_4936_ = v___y_4948_;
v___y_4937_ = v_curParentOrd_4882_;
goto v___jp_4931_;
}
}
}
else
{
v___y_4932_ = v___y_4942_;
v___y_4933_ = v___y_4947_;
v___y_4934_ = v___y_4944_;
v___y_4935_ = v___y_4946_;
v___y_4936_ = v___y_4948_;
v___y_4937_ = v_curParentOrd_4882_;
goto v___jp_4931_;
}
}
else
{
uint8_t v___x_4957_;
v___x_4957_ = 0;
v___y_4932_ = v___y_4942_;
v___y_4933_ = v___x_4957_;
v___y_4934_ = v___y_4944_;
v___y_4935_ = v___y_4946_;
v___y_4936_ = v___y_4948_;
v___y_4937_ = v_curParentOrd_4882_;
goto v___jp_4931_;
}
}
}
}
v___jp_4958_:
{
if (v___y_4962_ == 0)
{
v___y_4942_ = v___y_4959_;
v___y_4943_ = v___y_4960_;
v___y_4944_ = v___y_4962_;
v___y_4945_ = v___y_4961_;
v___y_4946_ = v___y_4964_;
v___y_4947_ = v___y_4967_;
v___y_4948_ = v___y_4965_;
v___y_4949_ = v___y_4966_;
v___y_4950_ = v___y_4962_;
goto v___jp_4941_;
}
else
{
if (v___y_4959_ == 0)
{
if (v___y_4963_ == 0)
{
if (v___y_4965_ == 0)
{
v___y_4942_ = v___y_4959_;
v___y_4943_ = v___y_4960_;
v___y_4944_ = v___y_4962_;
v___y_4945_ = v___y_4961_;
v___y_4946_ = v___y_4964_;
v___y_4947_ = v___y_4967_;
v___y_4948_ = v___y_4965_;
v___y_4949_ = v___y_4966_;
v___y_4950_ = v___y_4962_;
goto v___jp_4941_;
}
else
{
v___y_4942_ = v___y_4959_;
v___y_4943_ = v___y_4960_;
v___y_4944_ = v___y_4962_;
v___y_4945_ = v___y_4961_;
v___y_4946_ = v___y_4964_;
v___y_4947_ = v___y_4967_;
v___y_4948_ = v___y_4965_;
v___y_4949_ = v___y_4966_;
v___y_4950_ = v___y_4963_;
goto v___jp_4941_;
}
}
else
{
v___y_4942_ = v___y_4959_;
v___y_4943_ = v___y_4960_;
v___y_4944_ = v___y_4962_;
v___y_4945_ = v___y_4961_;
v___y_4946_ = v___y_4964_;
v___y_4947_ = v___y_4967_;
v___y_4948_ = v___y_4965_;
v___y_4949_ = v___y_4966_;
v___y_4950_ = v___y_4959_;
goto v___jp_4941_;
}
}
else
{
uint8_t v___x_4968_;
v___x_4968_ = 0;
v___y_4942_ = v___y_4959_;
v___y_4943_ = v___y_4960_;
v___y_4944_ = v___y_4962_;
v___y_4945_ = v___y_4961_;
v___y_4946_ = v___y_4964_;
v___y_4947_ = v___y_4967_;
v___y_4948_ = v___y_4965_;
v___y_4949_ = v___y_4966_;
v___y_4950_ = v___x_4968_;
goto v___jp_4941_;
}
}
}
v___jp_4970_:
{
if (v___x_4969_ == 0)
{
v___y_4959_ = v___y_4971_;
v___y_4960_ = v___y_4972_;
v___y_4961_ = v___y_4974_;
v___y_4962_ = v___y_4975_;
v___y_4963_ = v___y_4976_;
v___y_4964_ = v___y_4979_;
v___y_4965_ = v___y_4977_;
v___y_4966_ = v___y_4978_;
v___y_4967_ = v___x_4969_;
goto v___jp_4958_;
}
else
{
if (v___y_4973_ == 0)
{
v___y_4959_ = v___y_4971_;
v___y_4960_ = v___y_4972_;
v___y_4961_ = v___y_4974_;
v___y_4962_ = v___y_4975_;
v___y_4963_ = v___y_4976_;
v___y_4964_ = v___y_4979_;
v___y_4965_ = v___y_4977_;
v___y_4966_ = v___y_4978_;
v___y_4967_ = v___x_4969_;
goto v___jp_4958_;
}
else
{
uint8_t v___x_4980_;
v___x_4980_ = 0;
v___y_4959_ = v___y_4971_;
v___y_4960_ = v___y_4972_;
v___y_4961_ = v___y_4974_;
v___y_4962_ = v___y_4975_;
v___y_4963_ = v___y_4976_;
v___y_4964_ = v___y_4979_;
v___y_4965_ = v___y_4977_;
v___y_4966_ = v___y_4978_;
v___y_4967_ = v___x_4980_;
goto v___jp_4958_;
}
}
}
v___jp_4981_:
{
if (v___y_4987_ == 0)
{
v___y_4971_ = v___y_4982_;
v___y_4972_ = v___y_4984_;
v___y_4973_ = v___y_4985_;
v___y_4974_ = v___y_4987_;
v___y_4975_ = v___y_4986_;
v___y_4976_ = v___y_4988_;
v___y_4977_ = v___y_4990_;
v___y_4978_ = v___y_4989_;
v___y_4979_ = v___y_4986_;
goto v___jp_4970_;
}
else
{
if (v___y_4989_ == 0)
{
v___y_4971_ = v___y_4982_;
v___y_4972_ = v___y_4984_;
v___y_4973_ = v___y_4985_;
v___y_4974_ = v___y_4987_;
v___y_4975_ = v___y_4986_;
v___y_4976_ = v___y_4988_;
v___y_4977_ = v___y_4990_;
v___y_4978_ = v___y_4989_;
v___y_4979_ = v___y_4986_;
goto v___jp_4970_;
}
else
{
if (v___y_4988_ == 0)
{
if (v___y_4990_ == 0)
{
v___y_4971_ = v___y_4982_;
v___y_4972_ = v___y_4984_;
v___y_4973_ = v___y_4985_;
v___y_4974_ = v___y_4987_;
v___y_4975_ = v___y_4986_;
v___y_4976_ = v___y_4988_;
v___y_4977_ = v___y_4990_;
v___y_4978_ = v___y_4989_;
v___y_4979_ = v___y_4986_;
goto v___jp_4970_;
}
else
{
v___y_4971_ = v___y_4982_;
v___y_4972_ = v___y_4984_;
v___y_4973_ = v___y_4985_;
v___y_4974_ = v___y_4987_;
v___y_4975_ = v___y_4986_;
v___y_4976_ = v___y_4988_;
v___y_4977_ = v___y_4990_;
v___y_4978_ = v___y_4989_;
v___y_4979_ = v___y_4988_;
goto v___jp_4970_;
}
}
else
{
v___y_4971_ = v___y_4982_;
v___y_4972_ = v___y_4984_;
v___y_4973_ = v___y_4985_;
v___y_4974_ = v___y_4987_;
v___y_4975_ = v___y_4986_;
v___y_4976_ = v___y_4988_;
v___y_4977_ = v___y_4990_;
v___y_4978_ = v___y_4989_;
v___y_4979_ = v___y_4983_;
goto v___jp_4970_;
}
}
}
}
v___jp_4991_:
{
if (v___y_4992_ == 0)
{
if (v___y_4999_ == 0)
{
v___y_4982_ = v___y_4992_;
v___y_4983_ = v___y_4993_;
v___y_4984_ = v___y_4994_;
v___y_4985_ = v___y_4995_;
v___y_4986_ = v___y_4997_;
v___y_4987_ = v___y_4996_;
v___y_4988_ = v___y_4998_;
v___y_4989_ = v___y_5000_;
v___y_4990_ = v___y_4999_;
goto v___jp_4981_;
}
else
{
if (v___y_4998_ == 0)
{
uint8_t v_unarchEpochOk_5001_;
v_unarchEpochOk_5001_ = lean_uint64_dec_lt(v_archiveEpoch_4877_, v_incomingEpoch_4876_);
v___y_4982_ = v___y_4992_;
v___y_4983_ = v___y_4993_;
v___y_4984_ = v___y_4994_;
v___y_4985_ = v___y_4995_;
v___y_4986_ = v___y_4997_;
v___y_4987_ = v___y_4996_;
v___y_4988_ = v___y_4998_;
v___y_4989_ = v___y_5000_;
v___y_4990_ = v_unarchEpochOk_5001_;
goto v___jp_4981_;
}
else
{
v___y_4982_ = v___y_4992_;
v___y_4983_ = v___y_4993_;
v___y_4984_ = v___y_4994_;
v___y_4985_ = v___y_4995_;
v___y_4986_ = v___y_4997_;
v___y_4987_ = v___y_4996_;
v___y_4988_ = v___y_4998_;
v___y_4989_ = v___y_5000_;
v___y_4990_ = v___y_4992_;
goto v___jp_4981_;
}
}
}
else
{
uint8_t v___x_5002_;
v___x_5002_ = 0;
v___y_4971_ = v___y_4992_;
v___y_4972_ = v___y_4994_;
v___y_4973_ = v___y_4995_;
v___y_4974_ = v___y_4996_;
v___y_4975_ = v___y_4997_;
v___y_4976_ = v___y_4998_;
v___y_4977_ = v___x_5002_;
v___y_4978_ = v___y_5000_;
v___y_4979_ = v___y_4993_;
goto v___jp_4970_;
}
}
v___jp_5003_:
{
uint8_t v_curArchBool_5005_; uint8_t v_incArchBool_5006_; uint8_t v_incUnarchBool_5007_; uint8_t v_incSupBool_5008_; uint8_t v___x_5009_; uint8_t v_validPresence_5010_; uint8_t v___x_5011_; uint8_t v___x_5012_;
v_curArchBool_5005_ = lean_uint8_dec_eq(v_curArchived_4878_, v___x_4940_);
v_incArchBool_5006_ = lean_uint8_dec_eq(v_incArchive_4884_, v___x_4940_);
v_incUnarchBool_5007_ = lean_uint8_dec_eq(v_incUnarchive_4885_, v___x_4940_);
v_incSupBool_5008_ = lean_uint8_dec_eq(v_incSupersede_4886_, v___x_4940_);
v___x_5009_ = 2;
v_validPresence_5010_ = lean_uint8_dec_le(v_parentPresence_4881_, v___x_5009_);
v___x_5011_ = lean_uint8_dec_eq(v_isPartialPatch_4880_, v___x_4940_);
v___x_5012_ = 1;
if (v___x_5011_ == 0)
{
uint8_t v___x_5013_;
v___x_5013_ = lean_uint64_dec_le(v_currentEpoch_4875_, v_incomingEpoch_4876_);
v___y_4992_ = v___y_5004_;
v___y_4993_ = v___x_5012_;
v___y_4994_ = v___x_5011_;
v___y_4995_ = v_incSupBool_5008_;
v___y_4996_ = v_validPresence_5010_;
v___y_4997_ = v_curArchBool_5005_;
v___y_4998_ = v_incArchBool_5006_;
v___y_4999_ = v_incUnarchBool_5007_;
v___y_5000_ = v___x_5013_;
goto v___jp_4991_;
}
else
{
uint8_t v___x_5014_;
v___x_5014_ = lean_uint64_dec_lt(v_currentEpoch_4875_, v_incomingEpoch_4876_);
v___y_4992_ = v___y_5004_;
v___y_4993_ = v___x_5012_;
v___y_4994_ = v___x_5011_;
v___y_4995_ = v_incSupBool_5008_;
v___y_4996_ = v_validPresence_5010_;
v___y_4997_ = v_curArchBool_5005_;
v___y_4998_ = v_incArchBool_5006_;
v___y_4999_ = v_incUnarchBool_5007_;
v___y_5000_ = v___x_5014_;
goto v___jp_4991_;
}
}
}
}

LEAN_EXPORT uint64_t orb_transcript_fold_step(uint64_t v_lastAppliedSeq_5135_, uint64_t v_incomingSeq_5136_, uint32_t v_entryCount_5137_, uint8_t v_thinkingOpen_5138_, uint8_t v_normalizedAction_5139_, uint8_t v_isReplayFromLog_5140_){
_start:
{
uint32_t v___y_5142_; uint32_t v___y_5143_; uint32_t v___y_5150_; uint8_t v___y_5157_; uint32_t v___y_5158_; uint8_t v___x_5159_; uint8_t v___x_5160_; uint8_t v___y_5162_; uint32_t v___y_5163_; uint8_t v___y_5164_; uint8_t v___y_5165_; uint8_t v___y_5166_; uint8_t v___y_5167_; uint8_t v___x_5179_; uint32_t v___y_5181_; uint8_t v___y_5182_; uint8_t v___y_5183_; uint8_t v___y_5184_; uint8_t v___y_5185_; uint32_t v___y_5193_; uint8_t v___y_5194_; uint8_t v___y_5195_; uint32_t v___y_5209_;
v___x_5159_ = 1;
v___x_5160_ = lean_uint8_dec_eq(v_thinkingOpen_5138_, v___x_5159_);
v___x_5179_ = 1;
if (v___x_5160_ == 0)
{
uint32_t v___x_5215_;
v___x_5215_ = 0;
v___y_5209_ = v___x_5215_;
goto v___jp_5208_;
}
else
{
uint32_t v___x_5216_;
v___x_5216_ = 512;
v___y_5209_ = v___x_5216_;
goto v___jp_5208_;
}
v___jp_5141_:
{
uint64_t v___x_5144_; uint64_t v___x_5145_; uint64_t v___x_5146_; uint64_t v___x_5147_; uint64_t v___x_5148_;
v___x_5144_ = lean_uint32_to_uint64(v___y_5142_);
v___x_5145_ = lean_uint32_to_uint64(v___y_5143_);
v___x_5146_ = 32ULL;
v___x_5147_ = lean_uint64_shift_left(v___x_5145_, v___x_5146_);
v___x_5148_ = lean_uint64_lor(v___x_5144_, v___x_5147_);
return v___x_5148_;
}
v___jp_5149_:
{
uint32_t v___x_5151_; uint8_t v___x_5152_;
v___x_5151_ = 4294967294;
v___x_5152_ = lean_uint32_dec_le(v_entryCount_5137_, v___x_5151_);
if (v___x_5152_ == 0)
{
uint32_t v___x_5153_;
v___x_5153_ = 4294967295;
v___y_5142_ = v___y_5150_;
v___y_5143_ = v___x_5153_;
goto v___jp_5141_;
}
else
{
uint32_t v___x_5154_; uint32_t v___x_5155_;
v___x_5154_ = 1;
v___x_5155_ = lean_uint32_add(v_entryCount_5137_, v___x_5154_);
v___y_5142_ = v___y_5150_;
v___y_5143_ = v___x_5155_;
goto v___jp_5141_;
}
}
v___jp_5156_:
{
if (v___y_5157_ == 0)
{
v___y_5142_ = v___y_5158_;
v___y_5143_ = v_entryCount_5137_;
goto v___jp_5141_;
}
else
{
v___y_5150_ = v___y_5158_;
goto v___jp_5149_;
}
}
v___jp_5161_:
{
if (v___y_5166_ == 0)
{
if (v___y_5165_ == 0)
{
uint32_t v___x_5168_; uint32_t v___x_5169_;
v___x_5168_ = 2051;
v___x_5169_ = lean_uint32_lor(v___x_5168_, v___y_5163_);
v___y_5142_ = v___x_5169_;
v___y_5143_ = v_entryCount_5137_;
goto v___jp_5141_;
}
else
{
if (v___y_5164_ == 0)
{
if (v___y_5162_ == 0)
{
if (v___y_5167_ == 0)
{
uint32_t v___x_5170_; uint32_t v___x_5171_;
v___x_5170_ = 4;
v___x_5171_ = lean_uint32_lor(v___x_5170_, v___y_5163_);
v___y_5142_ = v___x_5171_;
v___y_5143_ = v_entryCount_5137_;
goto v___jp_5141_;
}
else
{
uint32_t v___x_5172_; uint32_t v___x_5173_;
v___x_5172_ = 260;
v___x_5173_ = lean_uint32_lor(v___x_5172_, v___y_5163_);
v___y_5142_ = v___x_5173_;
v___y_5143_ = v_entryCount_5137_;
goto v___jp_5141_;
}
}
else
{
if (v___x_5160_ == 0)
{
uint32_t v___x_5174_;
v___x_5174_ = 257;
v___y_5150_ = v___x_5174_;
goto v___jp_5149_;
}
else
{
uint32_t v___x_5175_;
v___x_5175_ = 1281;
v___y_5150_ = v___x_5175_;
goto v___jp_5149_;
}
}
}
else
{
uint32_t v___x_5176_;
v___x_5176_ = 769;
v___y_5157_ = v___y_5162_;
v___y_5158_ = v___x_5176_;
goto v___jp_5156_;
}
}
}
else
{
uint32_t v___x_5177_; uint32_t v___x_5178_;
v___x_5177_ = 2;
v___x_5178_ = lean_uint32_lor(v___x_5177_, v___y_5163_);
if (v___y_5165_ == 0)
{
v___y_5142_ = v___x_5178_;
v___y_5143_ = v_entryCount_5137_;
goto v___jp_5141_;
}
else
{
v___y_5157_ = v___y_5162_;
v___y_5158_ = v___x_5178_;
goto v___jp_5156_;
}
}
}
v___jp_5180_:
{
uint8_t v___x_5186_; uint8_t v___x_5187_;
v___x_5186_ = 2;
v___x_5187_ = lean_uint8_dec_eq(v_normalizedAction_5139_, v___x_5186_);
if (v___x_5187_ == 0)
{
uint8_t v___x_5188_; uint8_t v___x_5189_;
v___x_5188_ = 3;
v___x_5189_ = lean_uint8_dec_eq(v_normalizedAction_5139_, v___x_5188_);
if (v___x_5189_ == 0)
{
uint8_t v___x_5190_; uint8_t v___x_5191_;
v___x_5190_ = 8;
v___x_5191_ = lean_uint8_dec_eq(v_normalizedAction_5139_, v___x_5190_);
v___y_5162_ = v___y_5185_;
v___y_5163_ = v___y_5181_;
v___y_5164_ = v___y_5182_;
v___y_5165_ = v___y_5183_;
v___y_5166_ = v___y_5184_;
v___y_5167_ = v___x_5191_;
goto v___jp_5161_;
}
else
{
v___y_5162_ = v___y_5185_;
v___y_5163_ = v___y_5181_;
v___y_5164_ = v___y_5182_;
v___y_5165_ = v___y_5183_;
v___y_5166_ = v___y_5184_;
v___y_5167_ = v___x_5179_;
goto v___jp_5161_;
}
}
else
{
v___y_5162_ = v___y_5185_;
v___y_5163_ = v___y_5181_;
v___y_5164_ = v___y_5182_;
v___y_5165_ = v___y_5183_;
v___y_5166_ = v___y_5184_;
v___y_5167_ = v___x_5179_;
goto v___jp_5161_;
}
}
v___jp_5192_:
{
uint8_t v___x_5196_; uint8_t v_isOpenThink_5197_; uint8_t v___x_5198_; uint8_t v___x_5199_;
v___x_5196_ = 4;
v_isOpenThink_5197_ = lean_uint8_dec_eq(v_normalizedAction_5139_, v___x_5196_);
v___x_5198_ = 5;
v___x_5199_ = lean_uint8_dec_eq(v_normalizedAction_5139_, v___x_5198_);
if (v___x_5199_ == 0)
{
uint8_t v___x_5200_; uint8_t v___x_5201_;
v___x_5200_ = 6;
v___x_5201_ = lean_uint8_dec_eq(v_normalizedAction_5139_, v___x_5200_);
if (v___x_5201_ == 0)
{
uint8_t v___x_5202_; uint8_t v___x_5203_;
v___x_5202_ = 7;
v___x_5203_ = lean_uint8_dec_eq(v_normalizedAction_5139_, v___x_5202_);
if (v___x_5203_ == 0)
{
uint8_t v___x_5204_; uint8_t v___x_5205_;
v___x_5204_ = 9;
v___x_5205_ = lean_uint8_dec_eq(v_normalizedAction_5139_, v___x_5204_);
if (v___x_5205_ == 0)
{
uint8_t v___x_5206_; uint8_t v___x_5207_;
v___x_5206_ = 10;
v___x_5207_ = lean_uint8_dec_eq(v_normalizedAction_5139_, v___x_5206_);
v___y_5181_ = v___y_5193_;
v___y_5182_ = v_isOpenThink_5197_;
v___y_5183_ = v___y_5195_;
v___y_5184_ = v___y_5194_;
v___y_5185_ = v___x_5207_;
goto v___jp_5180_;
}
else
{
v___y_5181_ = v___y_5193_;
v___y_5182_ = v_isOpenThink_5197_;
v___y_5183_ = v___y_5195_;
v___y_5184_ = v___y_5194_;
v___y_5185_ = v___x_5179_;
goto v___jp_5180_;
}
}
else
{
v___y_5181_ = v___y_5193_;
v___y_5182_ = v_isOpenThink_5197_;
v___y_5183_ = v___y_5195_;
v___y_5184_ = v___y_5194_;
v___y_5185_ = v___x_5179_;
goto v___jp_5180_;
}
}
else
{
v___y_5181_ = v___y_5193_;
v___y_5182_ = v_isOpenThink_5197_;
v___y_5183_ = v___y_5195_;
v___y_5184_ = v___y_5194_;
v___y_5185_ = v___x_5179_;
goto v___jp_5180_;
}
}
else
{
v___y_5181_ = v___y_5193_;
v___y_5182_ = v_isOpenThink_5197_;
v___y_5183_ = v___y_5195_;
v___y_5184_ = v___y_5194_;
v___y_5185_ = v___x_5179_;
goto v___jp_5180_;
}
}
v___jp_5208_:
{
uint8_t v_isDuplicate_5210_;
v_isDuplicate_5210_ = lean_uint64_dec_le(v_incomingSeq_5136_, v_lastAppliedSeq_5135_);
if (v_isDuplicate_5210_ == 0)
{
uint64_t v___x_5211_; uint64_t v___x_5212_; uint8_t v___x_5213_;
v___x_5211_ = lean_uint64_sub(v_incomingSeq_5136_, v_lastAppliedSeq_5135_);
v___x_5212_ = 1ULL;
v___x_5213_ = lean_uint64_dec_eq(v___x_5211_, v___x_5212_);
v___y_5193_ = v___y_5209_;
v___y_5194_ = v_isDuplicate_5210_;
v___y_5195_ = v___x_5213_;
goto v___jp_5192_;
}
else
{
uint8_t v___x_5214_;
v___x_5214_ = 0;
v___y_5193_ = v___y_5209_;
v___y_5194_ = v_isDuplicate_5210_;
v___y_5195_ = v___x_5214_;
goto v___jp_5192_;
}
}
}
}

LEAN_EXPORT uint64_t orb_outbox_crash_reconcile_step(uint32_t v_durableQueued_5231_, uint32_t v_durableAcked_5232_, uint32_t v_volatileInFlight_5233_, uint64_t v_leaseBootEpoch_5234_, uint64_t v_nodeBootEpoch_5235_, uint32_t v_volatileLeaseOwner_5236_, uint32_t v_reqOwner_5237_){
_start:
{
uint32_t v___y_5239_; uint32_t v___y_5240_; uint32_t v___y_5247_; uint32_t v___y_5248_; uint32_t v___y_5249_; uint32_t v___y_5250_; uint8_t v_validWal_5253_; uint8_t v___y_5255_; uint32_t v___y_5256_; uint32_t v___y_5257_; uint32_t v___y_5258_; uint32_t v___y_5259_; uint8_t v___y_5267_; uint32_t v___y_5268_; uint8_t v___y_5269_; uint32_t v___y_5270_; uint32_t v___y_5271_; uint8_t v___y_5274_; uint32_t v___y_5275_; uint8_t v___y_5276_; uint32_t v___y_5277_; uint32_t v___y_5282_; uint8_t v___y_5283_; uint32_t v___y_5284_; uint8_t v___y_5285_; uint32_t v___y_5287_; uint8_t v___y_5288_; uint32_t v___y_5289_; uint32_t v___y_5290_; uint32_t v___y_5293_; uint32_t v___y_5294_; uint8_t v___y_5295_; uint32_t v___y_5296_; uint32_t v___y_5304_;
v_validWal_5253_ = lean_uint32_dec_le(v_durableAcked_5232_, v_durableQueued_5231_);
if (v_validWal_5253_ == 0)
{
uint32_t v___x_5309_;
v___x_5309_ = 0;
v___y_5304_ = v___x_5309_;
goto v___jp_5303_;
}
else
{
uint32_t v___x_5310_;
v___x_5310_ = lean_uint32_sub(v_durableQueued_5231_, v_durableAcked_5232_);
v___y_5304_ = v___x_5310_;
goto v___jp_5303_;
}
v___jp_5238_:
{
uint64_t v___x_5241_; uint64_t v___x_5242_; uint64_t v___x_5243_; uint64_t v___x_5244_; uint64_t v___x_5245_;
v___x_5241_ = lean_uint32_to_uint64(v___y_5240_);
v___x_5242_ = lean_uint32_to_uint64(v___y_5239_);
v___x_5243_ = 32ULL;
v___x_5244_ = lean_uint64_shift_left(v___x_5242_, v___x_5243_);
v___x_5245_ = lean_uint64_lor(v___x_5241_, v___x_5244_);
return v___x_5245_;
}
v___jp_5246_:
{
uint32_t v___x_5251_; uint32_t v___x_5252_;
v___x_5251_ = lean_uint32_lor(v___y_5250_, v___y_5248_);
v___x_5252_ = lean_uint32_lor(v___x_5251_, v___y_5247_);
v___y_5239_ = v___y_5249_;
v___y_5240_ = v___x_5252_;
goto v___jp_5238_;
}
v___jp_5254_:
{
if (v_validWal_5253_ == 0)
{
v___y_5239_ = v___y_5258_;
v___y_5240_ = v___y_5257_;
goto v___jp_5238_;
}
else
{
if (v___y_5255_ == 0)
{
uint8_t v___x_5260_;
v___x_5260_ = lean_uint32_dec_eq(v___y_5258_, v___y_5257_);
if (v___x_5260_ == 0)
{
uint32_t v___x_5261_;
v___x_5261_ = 3;
v___y_5247_ = v___y_5256_;
v___y_5248_ = v___y_5259_;
v___y_5249_ = v___y_5258_;
v___y_5250_ = v___x_5261_;
goto v___jp_5246_;
}
else
{
uint32_t v___x_5262_;
v___x_5262_ = 2;
v___y_5247_ = v___y_5256_;
v___y_5248_ = v___y_5259_;
v___y_5249_ = v___y_5258_;
v___y_5250_ = v___x_5262_;
goto v___jp_5246_;
}
}
else
{
uint32_t v___x_5263_; uint32_t v___x_5264_; uint32_t v___x_5265_;
v___x_5263_ = 257;
v___x_5264_ = lean_uint32_lor(v___x_5263_, v___y_5259_);
v___x_5265_ = lean_uint32_lor(v___x_5264_, v___y_5256_);
v___y_5239_ = v___y_5258_;
v___y_5240_ = v___x_5265_;
goto v___jp_5238_;
}
}
}
v___jp_5266_:
{
if (v___y_5269_ == 0)
{
v___y_5255_ = v___y_5267_;
v___y_5256_ = v___y_5271_;
v___y_5257_ = v___y_5268_;
v___y_5258_ = v___y_5270_;
v___y_5259_ = v___y_5268_;
goto v___jp_5254_;
}
else
{
uint32_t v___x_5272_;
v___x_5272_ = 512;
v___y_5255_ = v___y_5267_;
v___y_5256_ = v___y_5271_;
v___y_5257_ = v___y_5268_;
v___y_5258_ = v___y_5270_;
v___y_5259_ = v___x_5272_;
goto v___jp_5254_;
}
}
v___jp_5273_:
{
uint32_t v___x_5278_; uint8_t v___x_5279_;
v___x_5278_ = 0;
v___x_5279_ = lean_uint32_dec_eq(v___y_5277_, v___x_5278_);
if (v___x_5279_ == 0)
{
uint32_t v___x_5280_;
v___x_5280_ = 1024;
v___y_5267_ = v___y_5274_;
v___y_5268_ = v___x_5278_;
v___y_5269_ = v___y_5276_;
v___y_5270_ = v___y_5275_;
v___y_5271_ = v___x_5280_;
goto v___jp_5266_;
}
else
{
v___y_5267_ = v___y_5274_;
v___y_5268_ = v___x_5278_;
v___y_5269_ = v___y_5276_;
v___y_5270_ = v___y_5275_;
v___y_5271_ = v___x_5278_;
goto v___jp_5266_;
}
}
v___jp_5281_:
{
if (v___y_5285_ == 0)
{
v___y_5274_ = v___y_5285_;
v___y_5275_ = v___y_5284_;
v___y_5276_ = v___y_5283_;
v___y_5277_ = v___y_5282_;
goto v___jp_5273_;
}
else
{
v___y_5274_ = v___y_5285_;
v___y_5275_ = v___y_5284_;
v___y_5276_ = v___y_5283_;
v___y_5277_ = v_reqOwner_5237_;
goto v___jp_5273_;
}
}
v___jp_5286_:
{
uint8_t v___x_5291_;
v___x_5291_ = lean_uint32_dec_lt(v___y_5287_, v___y_5290_);
v___y_5282_ = v___y_5289_;
v___y_5283_ = v___y_5288_;
v___y_5284_ = v___y_5290_;
v___y_5285_ = v___x_5291_;
goto v___jp_5281_;
}
v___jp_5292_:
{
if (v_validWal_5253_ == 0)
{
v___y_5282_ = v___y_5294_;
v___y_5283_ = v___y_5295_;
v___y_5284_ = v___y_5293_;
v___y_5285_ = v_validWal_5253_;
goto v___jp_5281_;
}
else
{
uint32_t v___x_5297_; uint8_t v___x_5298_;
v___x_5297_ = 0;
v___x_5298_ = lean_uint32_dec_lt(v___x_5297_, v___y_5293_);
if (v___x_5298_ == 0)
{
v___y_5282_ = v___y_5294_;
v___y_5283_ = v___y_5295_;
v___y_5284_ = v___y_5293_;
v___y_5285_ = v___x_5298_;
goto v___jp_5281_;
}
else
{
uint8_t v___x_5299_;
v___x_5299_ = lean_uint32_dec_eq(v_reqOwner_5237_, v___x_5297_);
if (v___x_5299_ == 0)
{
uint8_t v___x_5300_;
v___x_5300_ = lean_uint32_dec_eq(v___y_5294_, v___x_5297_);
if (v___x_5300_ == 0)
{
uint8_t v___x_5301_;
v___x_5301_ = lean_uint32_dec_eq(v___y_5294_, v_reqOwner_5237_);
if (v___x_5301_ == 0)
{
v___y_5282_ = v___y_5294_;
v___y_5283_ = v___y_5295_;
v___y_5284_ = v___y_5293_;
v___y_5285_ = v___x_5301_;
goto v___jp_5281_;
}
else
{
v___y_5287_ = v___y_5296_;
v___y_5288_ = v___y_5295_;
v___y_5289_ = v___y_5294_;
v___y_5290_ = v___y_5293_;
goto v___jp_5286_;
}
}
else
{
v___y_5287_ = v___y_5296_;
v___y_5288_ = v___y_5295_;
v___y_5289_ = v___y_5294_;
v___y_5290_ = v___y_5293_;
goto v___jp_5286_;
}
}
else
{
uint8_t v___x_5302_;
v___x_5302_ = 0;
v___y_5274_ = v___x_5302_;
v___y_5275_ = v___y_5293_;
v___y_5276_ = v___y_5295_;
v___y_5277_ = v___y_5294_;
goto v___jp_5273_;
}
}
}
}
v___jp_5303_:
{
uint8_t v___x_5305_;
v___x_5305_ = lean_uint64_dec_eq(v_leaseBootEpoch_5234_, v_nodeBootEpoch_5235_);
if (v___x_5305_ == 0)
{
uint8_t v___x_5306_; uint32_t v___x_5307_;
v___x_5306_ = 1;
v___x_5307_ = 0;
v___y_5293_ = v___y_5304_;
v___y_5294_ = v___x_5307_;
v___y_5295_ = v___x_5306_;
v___y_5296_ = v___x_5307_;
goto v___jp_5292_;
}
else
{
uint8_t v___x_5308_;
v___x_5308_ = 0;
v___y_5293_ = v___y_5304_;
v___y_5294_ = v_volatileLeaseOwner_5236_;
v___y_5295_ = v___x_5308_;
v___y_5296_ = v_volatileInFlight_5233_;
goto v___jp_5292_;
}
}
}
}

LEAN_EXPORT uint64_t orb_provider_attempt_step(uint32_t v_pinnedAccountId_5327_, uint32_t v_candidateAccountId_5328_, uint32_t v_attemptsUsed_5329_, uint32_t v_retryBudget_5330_, uint8_t v_firstByteCommitted_5331_, uint8_t v_failureKind_5332_, uint64_t v_upstreamNowEpoch_5333_, uint64_t v_cooldownUntilEpoch_5334_, uint64_t v_upstreamDeadline_5335_, uint8_t v_authValid_5336_){
_start:
{
uint32_t v___y_5338_; uint32_t v___y_5339_; uint32_t v___y_5346_; uint32_t v___y_5347_; uint8_t v___y_5351_; uint8_t v___y_5352_; uint8_t v___y_5353_; uint8_t v___y_5354_; uint8_t v___y_5355_; uint32_t v___y_5356_; uint8_t v___y_5357_; uint8_t v___x_5373_; uint8_t v___x_5374_; uint8_t v___y_5376_; uint8_t v___y_5377_; uint8_t v___y_5378_; uint8_t v___y_5379_; uint32_t v___y_5380_; uint8_t v___y_5381_; uint8_t v___y_5383_; uint8_t v___y_5384_; uint8_t v___y_5385_; uint32_t v___y_5386_; uint8_t v___y_5387_; uint8_t v___y_5391_; uint8_t v___y_5392_; uint8_t v___y_5393_; uint32_t v___y_5394_; uint8_t v___y_5395_; uint8_t v___y_5399_; uint8_t v___y_5400_; uint32_t v___y_5401_; uint8_t v___y_5402_; uint32_t v___y_5406_; uint8_t v___y_5407_; uint32_t v___y_5413_;
v___x_5373_ = 1;
v___x_5374_ = lean_uint8_dec_eq(v_firstByteCommitted_5331_, v___x_5373_);
if (v___x_5374_ == 0)
{
uint8_t v___x_5421_; uint8_t v___x_5422_;
v___x_5421_ = 3;
v___x_5422_ = lean_uint8_dec_eq(v_failureKind_5332_, v___x_5421_);
if (v___x_5422_ == 0)
{
uint32_t v___x_5423_;
v___x_5423_ = 0;
v___y_5413_ = v___x_5423_;
goto v___jp_5412_;
}
else
{
goto v___jp_5419_;
}
}
else
{
goto v___jp_5419_;
}
v___jp_5337_:
{
uint64_t v___x_5340_; uint64_t v___x_5341_; uint64_t v___x_5342_; uint64_t v___x_5343_; uint64_t v___x_5344_;
v___x_5340_ = lean_uint32_to_uint64(v___y_5339_);
v___x_5341_ = lean_uint32_to_uint64(v___y_5338_);
v___x_5342_ = 32ULL;
v___x_5343_ = lean_uint64_shift_left(v___x_5341_, v___x_5342_);
v___x_5344_ = lean_uint64_lor(v___x_5340_, v___x_5343_);
return v___x_5344_;
}
v___jp_5345_:
{
uint32_t v___x_5348_; uint32_t v___x_5349_;
v___x_5348_ = 257;
v___x_5349_ = lean_uint32_lor(v___x_5348_, v___y_5346_);
v___y_5338_ = v___y_5347_;
v___y_5339_ = v___x_5349_;
goto v___jp_5337_;
}
v___jp_5350_:
{
if (v___y_5357_ == 0)
{
if (v___y_5353_ == 0)
{
uint32_t v___x_5358_; uint32_t v___x_5359_;
v___x_5358_ = 4;
v___x_5359_ = lean_uint32_lor(v___x_5358_, v___y_5356_);
v___y_5338_ = v_attemptsUsed_5329_;
v___y_5339_ = v___x_5359_;
goto v___jp_5337_;
}
else
{
if (v___y_5352_ == 0)
{
uint32_t v___x_5360_; uint32_t v___x_5361_;
v___x_5360_ = 5;
v___x_5361_ = lean_uint32_lor(v___x_5360_, v___y_5356_);
v___y_5338_ = v_attemptsUsed_5329_;
v___y_5339_ = v___x_5361_;
goto v___jp_5337_;
}
else
{
if (v___y_5355_ == 0)
{
uint32_t v___x_5362_; uint32_t v___x_5363_;
v___x_5362_ = 6;
v___x_5363_ = lean_uint32_lor(v___x_5362_, v___y_5356_);
v___y_5338_ = v_attemptsUsed_5329_;
v___y_5339_ = v___x_5363_;
goto v___jp_5337_;
}
else
{
if (v___y_5351_ == 0)
{
uint32_t v___x_5364_; uint32_t v___x_5365_;
v___x_5364_ = 7;
v___x_5365_ = lean_uint32_lor(v___x_5364_, v___y_5356_);
v___y_5338_ = v_attemptsUsed_5329_;
v___y_5339_ = v___x_5365_;
goto v___jp_5337_;
}
else
{
if (v___y_5354_ == 0)
{
v___y_5346_ = v___y_5356_;
v___y_5347_ = v_attemptsUsed_5329_;
goto v___jp_5345_;
}
else
{
uint32_t v___x_5366_; uint8_t v___x_5367_;
v___x_5366_ = 4294967294;
v___x_5367_ = lean_uint32_dec_le(v_attemptsUsed_5329_, v___x_5366_);
if (v___x_5367_ == 0)
{
uint32_t v___x_5368_;
v___x_5368_ = 4294967295;
v___y_5346_ = v___y_5356_;
v___y_5347_ = v___x_5368_;
goto v___jp_5345_;
}
else
{
uint32_t v___x_5369_; uint32_t v___x_5370_;
v___x_5369_ = 1;
v___x_5370_ = lean_uint32_add(v_attemptsUsed_5329_, v___x_5369_);
v___y_5346_ = v___y_5356_;
v___y_5347_ = v___x_5370_;
goto v___jp_5345_;
}
}
}
}
}
}
}
else
{
uint32_t v___x_5371_; uint32_t v___x_5372_;
v___x_5371_ = 3;
v___x_5372_ = lean_uint32_lor(v___x_5371_, v___y_5356_);
v___y_5338_ = v_attemptsUsed_5329_;
v___y_5339_ = v___x_5372_;
goto v___jp_5337_;
}
}
v___jp_5375_:
{
if (v___x_5374_ == 0)
{
v___y_5351_ = v___y_5381_;
v___y_5352_ = v___y_5376_;
v___y_5353_ = v___y_5377_;
v___y_5354_ = v___y_5379_;
v___y_5355_ = v___y_5378_;
v___y_5356_ = v___y_5380_;
v___y_5357_ = v___x_5374_;
goto v___jp_5350_;
}
else
{
v___y_5351_ = v___y_5381_;
v___y_5352_ = v___y_5376_;
v___y_5353_ = v___y_5377_;
v___y_5354_ = v___y_5379_;
v___y_5355_ = v___y_5378_;
v___y_5356_ = v___y_5380_;
v___y_5357_ = v___y_5379_;
goto v___jp_5350_;
}
}
v___jp_5382_:
{
if (v___y_5387_ == 0)
{
uint8_t v___x_5388_;
v___x_5388_ = lean_uint32_dec_le(v_attemptsUsed_5329_, v_retryBudget_5330_);
v___y_5376_ = v___y_5383_;
v___y_5377_ = v___y_5384_;
v___y_5378_ = v___y_5385_;
v___y_5379_ = v___y_5387_;
v___y_5380_ = v___y_5386_;
v___y_5381_ = v___x_5388_;
goto v___jp_5375_;
}
else
{
uint8_t v___x_5389_;
v___x_5389_ = lean_uint32_dec_lt(v_attemptsUsed_5329_, v_retryBudget_5330_);
v___y_5376_ = v___y_5383_;
v___y_5377_ = v___y_5384_;
v___y_5378_ = v___y_5385_;
v___y_5379_ = v___y_5387_;
v___y_5380_ = v___y_5386_;
v___y_5381_ = v___x_5389_;
goto v___jp_5375_;
}
}
v___jp_5390_:
{
uint8_t v___x_5396_;
v___x_5396_ = lean_uint8_dec_eq(v_failureKind_5332_, v___x_5373_);
if (v___x_5396_ == 0)
{
uint8_t v___x_5397_;
v___x_5397_ = lean_uint8_dec_eq(v_failureKind_5332_, v___y_5391_);
v___y_5383_ = v___y_5392_;
v___y_5384_ = v___y_5393_;
v___y_5385_ = v___y_5395_;
v___y_5386_ = v___y_5394_;
v___y_5387_ = v___x_5397_;
goto v___jp_5382_;
}
else
{
v___y_5383_ = v___y_5392_;
v___y_5384_ = v___y_5393_;
v___y_5385_ = v___y_5395_;
v___y_5386_ = v___y_5394_;
v___y_5387_ = v___x_5396_;
goto v___jp_5382_;
}
}
v___jp_5398_:
{
uint8_t v___x_5403_;
v___x_5403_ = lean_uint64_dec_lt(v_upstreamNowEpoch_5333_, v_upstreamDeadline_5335_);
if (v___x_5403_ == 0)
{
v___y_5391_ = v___y_5399_;
v___y_5392_ = v___y_5402_;
v___y_5393_ = v___y_5400_;
v___y_5394_ = v___y_5401_;
v___y_5395_ = v___x_5403_;
goto v___jp_5390_;
}
else
{
uint8_t v___x_5404_;
v___x_5404_ = lean_uint8_dec_eq(v_authValid_5336_, v___x_5373_);
v___y_5391_ = v___y_5399_;
v___y_5392_ = v___y_5402_;
v___y_5393_ = v___y_5400_;
v___y_5394_ = v___y_5401_;
v___y_5395_ = v___x_5404_;
goto v___jp_5390_;
}
}
v___jp_5405_:
{
uint8_t v___x_5408_; uint8_t v___x_5409_;
v___x_5408_ = 2;
v___x_5409_ = lean_uint8_dec_eq(v_failureKind_5332_, v___x_5408_);
if (v___x_5409_ == 0)
{
uint8_t v___x_5410_;
v___x_5410_ = lean_uint64_dec_le(v_cooldownUntilEpoch_5334_, v_upstreamNowEpoch_5333_);
v___y_5399_ = v___x_5408_;
v___y_5400_ = v___y_5407_;
v___y_5401_ = v___y_5406_;
v___y_5402_ = v___x_5410_;
goto v___jp_5398_;
}
else
{
uint8_t v___x_5411_;
v___x_5411_ = 0;
v___y_5399_ = v___x_5408_;
v___y_5400_ = v___y_5407_;
v___y_5401_ = v___y_5406_;
v___y_5402_ = v___x_5411_;
goto v___jp_5398_;
}
}
v___jp_5412_:
{
uint32_t v___x_5414_; uint8_t v___x_5415_;
v___x_5414_ = 0;
v___x_5415_ = lean_uint32_dec_eq(v_candidateAccountId_5328_, v___x_5414_);
if (v___x_5415_ == 0)
{
uint8_t v___x_5416_;
v___x_5416_ = lean_uint32_dec_eq(v_pinnedAccountId_5327_, v___x_5414_);
if (v___x_5416_ == 0)
{
uint8_t v___x_5417_;
v___x_5417_ = lean_uint32_dec_eq(v_candidateAccountId_5328_, v_pinnedAccountId_5327_);
v___y_5406_ = v___y_5413_;
v___y_5407_ = v___x_5417_;
goto v___jp_5405_;
}
else
{
v___y_5406_ = v___y_5413_;
v___y_5407_ = v___x_5416_;
goto v___jp_5405_;
}
}
else
{
uint8_t v___x_5418_;
v___x_5418_ = 0;
v___y_5406_ = v___y_5413_;
v___y_5407_ = v___x_5418_;
goto v___jp_5405_;
}
}
v___jp_5419_:
{
uint32_t v___x_5420_;
v___x_5420_ = 512;
v___y_5413_ = v___x_5420_;
goto v___jp_5412_;
}
}
}

LEAN_EXPORT uint32_t orb_auth_toctou_execute_step(uint8_t v_principalKind_5446_, uint8_t v_bunkerState_5447_, uint32_t v_observedTargetId_5448_, uint32_t v_execTargetId_5449_, uint64_t v_observedLeaseEpoch_5450_, uint64_t v_liveLeaseEpoch_5451_, uint64_t v_nowTick_5452_, uint64_t v_expiryTick_5453_, uint64_t v_observedDigest_5454_, uint64_t v_execDigest_5455_){
_start:
{
uint8_t v___x_5456_; uint8_t v___x_5457_;
v___x_5456_ = 0;
v___x_5457_ = lean_uint8_dec_eq(v_bunkerState_5447_, v___x_5456_);
if (v___x_5457_ == 0)
{
uint32_t v___x_5458_;
v___x_5458_ = 513;
return v___x_5458_;
}
else
{
uint8_t v___x_5459_; uint8_t v___x_5460_;
v___x_5459_ = 1;
v___x_5460_ = lean_uint8_dec_le(v___x_5459_, v_principalKind_5446_);
if (v___x_5460_ == 0)
{
uint32_t v___x_5461_;
v___x_5461_ = 514;
return v___x_5461_;
}
else
{
uint8_t v___x_5462_; uint8_t v___x_5463_;
v___x_5462_ = 3;
v___x_5463_ = lean_uint8_dec_le(v_principalKind_5446_, v___x_5462_);
if (v___x_5463_ == 0)
{
uint32_t v___x_5464_;
v___x_5464_ = 514;
return v___x_5464_;
}
else
{
uint8_t v___x_5465_;
v___x_5465_ = lean_uint64_dec_lt(v_nowTick_5452_, v_expiryTick_5453_);
if (v___x_5465_ == 0)
{
uint32_t v___x_5466_;
v___x_5466_ = 515;
return v___x_5466_;
}
else
{
uint64_t v___x_5467_; uint8_t v___x_5468_;
v___x_5467_ = 0ULL;
v___x_5468_ = lean_uint64_dec_eq(v_observedLeaseEpoch_5450_, v___x_5467_);
if (v___x_5468_ == 0)
{
uint8_t v___x_5469_;
v___x_5469_ = lean_uint64_dec_eq(v_observedLeaseEpoch_5450_, v_liveLeaseEpoch_5451_);
if (v___x_5469_ == 0)
{
uint32_t v___x_5470_;
v___x_5470_ = 516;
return v___x_5470_;
}
else
{
uint32_t v___x_5471_; uint8_t v___x_5472_;
v___x_5471_ = 0;
v___x_5472_ = lean_uint32_dec_eq(v_observedTargetId_5448_, v___x_5471_);
if (v___x_5472_ == 0)
{
uint8_t v___x_5473_;
v___x_5473_ = lean_uint32_dec_eq(v_observedTargetId_5448_, v_execTargetId_5449_);
if (v___x_5473_ == 0)
{
uint32_t v___x_5474_;
v___x_5474_ = 517;
return v___x_5474_;
}
else
{
uint8_t v___x_5475_;
v___x_5475_ = lean_uint64_dec_eq(v_observedDigest_5454_, v___x_5467_);
if (v___x_5475_ == 0)
{
uint8_t v___x_5476_;
v___x_5476_ = lean_uint64_dec_eq(v_observedDigest_5454_, v_execDigest_5455_);
if (v___x_5476_ == 0)
{
uint32_t v___x_5477_;
v___x_5477_ = 518;
return v___x_5477_;
}
else
{
uint32_t v___x_5478_;
v___x_5478_ = 257;
return v___x_5478_;
}
}
else
{
uint32_t v___x_5479_;
v___x_5479_ = 518;
return v___x_5479_;
}
}
}
else
{
uint32_t v___x_5480_;
v___x_5480_ = 517;
return v___x_5480_;
}
}
}
else
{
uint32_t v___x_5481_;
v___x_5481_ = 516;
return v___x_5481_;
}
}
}
}
}
}
}

LEAN_EXPORT uint64_t orb_resource_ledger_step(uint8_t v_opKind_5504_, uint32_t v_reservedSlots_5505_, uint32_t v_activeSlots_5506_, uint32_t v_maxSlots_5507_, uint64_t v_spentCents_5508_, uint64_t v_costDeltaCents_5509_, uint64_t v_budgetCents_5510_, uint64_t v_nowTick_5511_, uint64_t v_ttlExpiryTick_5512_){
_start:
{
uint32_t v___y_5514_; uint32_t v___y_5515_; uint32_t v___y_5516_; uint32_t v___y_5529_; uint32_t v___y_5530_; uint32_t v___y_5531_; uint8_t v___y_5532_; uint8_t v___y_5533_; uint8_t v_activeFits_5542_; uint8_t v___x_5543_; uint8_t v___y_5545_; uint32_t v___y_5546_; uint32_t v___y_5547_; uint8_t v___y_5548_; uint8_t v___y_5549_; uint8_t v___y_5550_; uint8_t v___y_5551_; uint32_t v___y_5552_; uint8_t v___y_5554_; uint32_t v___y_5555_; uint8_t v___y_5556_; uint8_t v___y_5557_; uint8_t v___y_5558_; uint8_t v___y_5559_; uint32_t v___y_5560_; uint8_t v___y_5564_; uint32_t v___y_5565_; uint8_t v___y_5566_; uint8_t v___y_5567_; uint8_t v___y_5568_; uint8_t v___y_5569_; uint32_t v___y_5570_; uint8_t v___y_5574_; uint32_t v___y_5575_; uint8_t v___y_5576_; uint8_t v___y_5577_; uint8_t v___y_5578_; uint8_t v___y_5579_; uint8_t v___y_5583_; uint32_t v___y_5584_; uint8_t v___y_5585_; uint8_t v___y_5586_; uint8_t v___y_5587_; uint8_t v___y_5588_; uint8_t v___y_5592_; uint32_t v___y_5593_; uint8_t v___y_5594_; uint8_t v___y_5595_; uint8_t v___y_5596_; uint8_t v___y_5597_; uint8_t v___y_5598_; uint32_t v___y_5602_; uint8_t v___y_5603_; uint8_t v___y_5604_; uint8_t v___y_5605_; uint8_t v___y_5606_; uint8_t v___y_5607_; uint8_t v___y_5608_; uint8_t v___y_5612_; uint8_t v___y_5613_; uint32_t v___y_5614_; uint8_t v___y_5615_; uint8_t v___y_5616_; uint8_t v___y_5617_; uint8_t v___y_5618_; uint32_t v___y_5622_; uint8_t v___y_5623_; uint8_t v___y_5624_; uint32_t v___y_5634_; uint8_t v___y_5635_; uint64_t v___y_5636_; uint8_t v___y_5639_; uint32_t v___y_5640_; uint8_t v___y_5641_; uint32_t v___y_5645_;
v_activeFits_5542_ = lean_uint32_dec_le(v_activeSlots_5506_, v_maxSlots_5507_);
v___x_5543_ = 1;
if (v_activeFits_5542_ == 0)
{
uint32_t v___x_5648_;
v___x_5648_ = 0;
v___y_5645_ = v___x_5648_;
goto v___jp_5644_;
}
else
{
uint32_t v___x_5649_;
v___x_5649_ = lean_uint32_sub(v_maxSlots_5507_, v_activeSlots_5506_);
v___y_5645_ = v___x_5649_;
goto v___jp_5644_;
}
v___jp_5513_:
{
uint32_t v___x_5517_; uint32_t v___x_5518_; uint32_t v___x_5519_; uint32_t v___x_5520_; uint32_t v___x_5521_; uint32_t v_hi32_5522_; uint64_t v___x_5523_; uint64_t v___x_5524_; uint64_t v___x_5525_; uint64_t v___x_5526_; uint64_t v___x_5527_;
v___x_5517_ = 65535;
v___x_5518_ = lean_uint32_land(v___y_5514_, v___x_5517_);
v___x_5519_ = lean_uint32_land(v___y_5515_, v___x_5517_);
v___x_5520_ = 16;
v___x_5521_ = lean_uint32_shift_left(v___x_5519_, v___x_5520_);
v_hi32_5522_ = lean_uint32_lor(v___x_5518_, v___x_5521_);
v___x_5523_ = lean_uint32_to_uint64(v___y_5516_);
v___x_5524_ = lean_uint32_to_uint64(v_hi32_5522_);
v___x_5525_ = 32ULL;
v___x_5526_ = lean_uint64_shift_left(v___x_5524_, v___x_5525_);
v___x_5527_ = lean_uint64_lor(v___x_5523_, v___x_5526_);
return v___x_5527_;
}
v___jp_5528_:
{
if (v___y_5532_ == 0)
{
v___y_5514_ = v___y_5529_;
v___y_5515_ = v___y_5531_;
v___y_5516_ = v___y_5530_;
goto v___jp_5513_;
}
else
{
if (v___y_5533_ == 0)
{
uint32_t v___x_5534_;
v___x_5534_ = 2;
v___y_5514_ = v___y_5529_;
v___y_5515_ = v___y_5531_;
v___y_5516_ = v___x_5534_;
goto v___jp_5513_;
}
else
{
uint32_t v___x_5535_; uint32_t v___x_5536_; uint32_t v___x_5537_; uint32_t v___x_5538_; uint32_t v___x_5539_; uint32_t v___x_5540_; uint32_t v___x_5541_;
v___x_5535_ = 257;
v___x_5536_ = lean_uint8_to_uint32(v_opKind_5504_);
v___x_5537_ = 255;
v___x_5538_ = lean_uint32_land(v___x_5536_, v___x_5537_);
v___x_5539_ = 1;
v___x_5540_ = lean_uint32_shift_left(v___x_5538_, v___x_5539_);
v___x_5541_ = lean_uint32_lor(v___x_5535_, v___x_5540_);
v___y_5514_ = v___y_5529_;
v___y_5515_ = v___y_5531_;
v___y_5516_ = v___x_5541_;
goto v___jp_5513_;
}
}
}
v___jp_5544_:
{
if (v___y_5550_ == 0)
{
if (v___y_5551_ == 0)
{
if (v___y_5545_ == 0)
{
v___y_5529_ = v___y_5546_;
v___y_5530_ = v___y_5547_;
v___y_5531_ = v___y_5552_;
v___y_5532_ = v___y_5548_;
v___y_5533_ = v___y_5549_;
goto v___jp_5528_;
}
else
{
v___y_5529_ = v___y_5546_;
v___y_5530_ = v___y_5547_;
v___y_5531_ = v___y_5552_;
v___y_5532_ = v___y_5548_;
v___y_5533_ = v___x_5543_;
goto v___jp_5528_;
}
}
else
{
v___y_5529_ = v___y_5546_;
v___y_5530_ = v___y_5547_;
v___y_5531_ = v___y_5552_;
v___y_5532_ = v___y_5548_;
v___y_5533_ = v___x_5543_;
goto v___jp_5528_;
}
}
else
{
v___y_5529_ = v___y_5546_;
v___y_5530_ = v___y_5547_;
v___y_5531_ = v___y_5552_;
v___y_5532_ = v___y_5548_;
v___y_5533_ = v___x_5543_;
goto v___jp_5528_;
}
}
v___jp_5553_:
{
if (v___y_5554_ == 0)
{
v___y_5545_ = v___y_5554_;
v___y_5546_ = v___y_5560_;
v___y_5547_ = v___y_5555_;
v___y_5548_ = v___y_5556_;
v___y_5549_ = v___y_5557_;
v___y_5550_ = v___y_5558_;
v___y_5551_ = v___y_5559_;
v___y_5552_ = v_activeSlots_5506_;
goto v___jp_5544_;
}
else
{
uint32_t v___x_5561_; uint32_t v___x_5562_;
v___x_5561_ = 1;
v___x_5562_ = lean_uint32_sub(v_activeSlots_5506_, v___x_5561_);
v___y_5545_ = v___y_5554_;
v___y_5546_ = v___y_5560_;
v___y_5547_ = v___y_5555_;
v___y_5548_ = v___y_5556_;
v___y_5549_ = v___y_5557_;
v___y_5550_ = v___y_5558_;
v___y_5551_ = v___y_5559_;
v___y_5552_ = v___x_5562_;
goto v___jp_5544_;
}
}
v___jp_5563_:
{
if (v___y_5569_ == 0)
{
v___y_5554_ = v___y_5564_;
v___y_5555_ = v___y_5565_;
v___y_5556_ = v___y_5566_;
v___y_5557_ = v___y_5567_;
v___y_5558_ = v___y_5568_;
v___y_5559_ = v___y_5569_;
v___y_5560_ = v___y_5570_;
goto v___jp_5553_;
}
else
{
uint32_t v___x_5571_; uint32_t v___x_5572_;
v___x_5571_ = 1;
v___x_5572_ = lean_uint32_add(v_activeSlots_5506_, v___x_5571_);
v___y_5545_ = v___y_5564_;
v___y_5546_ = v___y_5570_;
v___y_5547_ = v___y_5565_;
v___y_5548_ = v___y_5566_;
v___y_5549_ = v___y_5567_;
v___y_5550_ = v___y_5568_;
v___y_5551_ = v___y_5569_;
v___y_5552_ = v___x_5572_;
goto v___jp_5544_;
}
}
v___jp_5573_:
{
uint32_t v___x_5580_; uint32_t v___x_5581_;
v___x_5580_ = 1;
v___x_5581_ = lean_uint32_sub(v_reservedSlots_5505_, v___x_5580_);
v___y_5564_ = v___y_5574_;
v___y_5565_ = v___y_5575_;
v___y_5566_ = v___y_5576_;
v___y_5567_ = v___y_5577_;
v___y_5568_ = v___y_5578_;
v___y_5569_ = v___y_5579_;
v___y_5570_ = v___x_5581_;
goto v___jp_5563_;
}
v___jp_5582_:
{
if (v___y_5586_ == 0)
{
if (v___y_5587_ == 0)
{
if (v___y_5588_ == 0)
{
v___y_5554_ = v___y_5583_;
v___y_5555_ = v___y_5584_;
v___y_5556_ = v___y_5585_;
v___y_5557_ = v___y_5588_;
v___y_5558_ = v___y_5586_;
v___y_5559_ = v___y_5587_;
v___y_5560_ = v_reservedSlots_5505_;
goto v___jp_5553_;
}
else
{
v___y_5574_ = v___y_5583_;
v___y_5575_ = v___y_5584_;
v___y_5576_ = v___y_5585_;
v___y_5577_ = v___y_5588_;
v___y_5578_ = v___y_5586_;
v___y_5579_ = v___y_5587_;
goto v___jp_5573_;
}
}
else
{
v___y_5574_ = v___y_5583_;
v___y_5575_ = v___y_5584_;
v___y_5576_ = v___y_5585_;
v___y_5577_ = v___y_5588_;
v___y_5578_ = v___y_5586_;
v___y_5579_ = v___y_5587_;
goto v___jp_5573_;
}
}
else
{
uint32_t v___x_5589_; uint32_t v___x_5590_;
v___x_5589_ = 1;
v___x_5590_ = lean_uint32_add(v_reservedSlots_5505_, v___x_5589_);
v___y_5564_ = v___y_5583_;
v___y_5565_ = v___y_5584_;
v___y_5566_ = v___y_5585_;
v___y_5567_ = v___y_5588_;
v___y_5568_ = v___y_5586_;
v___y_5569_ = v___y_5587_;
v___y_5570_ = v___x_5590_;
goto v___jp_5563_;
}
}
v___jp_5591_:
{
uint8_t v___x_5599_; uint8_t v___x_5600_;
v___x_5599_ = 3;
v___x_5600_ = lean_uint8_dec_eq(v_opKind_5504_, v___x_5599_);
if (v___x_5600_ == 0)
{
v___y_5583_ = v___y_5598_;
v___y_5584_ = v___y_5593_;
v___y_5585_ = v___y_5595_;
v___y_5586_ = v___y_5596_;
v___y_5587_ = v___y_5597_;
v___y_5588_ = v___x_5600_;
goto v___jp_5582_;
}
else
{
if (v___y_5595_ == 0)
{
v___y_5583_ = v___y_5598_;
v___y_5584_ = v___y_5593_;
v___y_5585_ = v___y_5595_;
v___y_5586_ = v___y_5596_;
v___y_5587_ = v___y_5597_;
v___y_5588_ = v___y_5595_;
goto v___jp_5582_;
}
else
{
if (v___y_5592_ == 0)
{
v___y_5583_ = v___y_5598_;
v___y_5584_ = v___y_5593_;
v___y_5585_ = v___y_5595_;
v___y_5586_ = v___y_5596_;
v___y_5587_ = v___y_5597_;
v___y_5588_ = v___y_5592_;
goto v___jp_5582_;
}
else
{
v___y_5583_ = v___y_5598_;
v___y_5584_ = v___y_5593_;
v___y_5585_ = v___y_5595_;
v___y_5586_ = v___y_5596_;
v___y_5587_ = v___y_5597_;
v___y_5588_ = v___y_5594_;
goto v___jp_5582_;
}
}
}
}
v___jp_5601_:
{
uint8_t v___x_5609_; uint8_t v___x_5610_;
v___x_5609_ = 2;
v___x_5610_ = lean_uint8_dec_eq(v_opKind_5504_, v___x_5609_);
if (v___x_5610_ == 0)
{
v___y_5592_ = v___y_5603_;
v___y_5593_ = v___y_5602_;
v___y_5594_ = v___y_5605_;
v___y_5595_ = v___y_5604_;
v___y_5596_ = v___y_5607_;
v___y_5597_ = v___y_5608_;
v___y_5598_ = v___x_5610_;
goto v___jp_5591_;
}
else
{
if (v___y_5604_ == 0)
{
v___y_5592_ = v___y_5603_;
v___y_5593_ = v___y_5602_;
v___y_5594_ = v___y_5605_;
v___y_5595_ = v___y_5604_;
v___y_5596_ = v___y_5607_;
v___y_5597_ = v___y_5608_;
v___y_5598_ = v___y_5604_;
goto v___jp_5591_;
}
else
{
v___y_5592_ = v___y_5603_;
v___y_5593_ = v___y_5602_;
v___y_5594_ = v___y_5605_;
v___y_5595_ = v___y_5604_;
v___y_5596_ = v___y_5607_;
v___y_5597_ = v___y_5608_;
v___y_5598_ = v___y_5606_;
goto v___jp_5591_;
}
}
}
v___jp_5611_:
{
uint8_t v___x_5619_; uint8_t v___x_5620_;
v___x_5619_ = 1;
v___x_5620_ = lean_uint8_dec_eq(v_opKind_5504_, v___x_5619_);
if (v___x_5620_ == 0)
{
v___y_5602_ = v___y_5614_;
v___y_5603_ = v___y_5613_;
v___y_5604_ = v___y_5616_;
v___y_5605_ = v___y_5615_;
v___y_5606_ = v___y_5617_;
v___y_5607_ = v___y_5618_;
v___y_5608_ = v___x_5620_;
goto v___jp_5601_;
}
else
{
if (v___y_5616_ == 0)
{
v___y_5602_ = v___y_5614_;
v___y_5603_ = v___y_5613_;
v___y_5604_ = v___y_5616_;
v___y_5605_ = v___y_5615_;
v___y_5606_ = v___y_5617_;
v___y_5607_ = v___y_5618_;
v___y_5608_ = v___y_5616_;
goto v___jp_5601_;
}
else
{
if (v___y_5613_ == 0)
{
v___y_5602_ = v___y_5614_;
v___y_5603_ = v___y_5613_;
v___y_5604_ = v___y_5616_;
v___y_5605_ = v___y_5615_;
v___y_5606_ = v___y_5617_;
v___y_5607_ = v___y_5618_;
v___y_5608_ = v___y_5613_;
goto v___jp_5601_;
}
else
{
v___y_5602_ = v___y_5614_;
v___y_5603_ = v___y_5613_;
v___y_5604_ = v___y_5616_;
v___y_5605_ = v___y_5615_;
v___y_5606_ = v___y_5617_;
v___y_5607_ = v___y_5618_;
v___y_5608_ = v___y_5612_;
goto v___jp_5601_;
}
}
}
}
v___jp_5621_:
{
uint8_t v_hasFreeSlot_5625_; uint32_t v___x_5626_; uint8_t v_hasReserved_5627_; uint8_t v_hasActive_5628_; uint8_t v_ttlLive_5629_; uint8_t v_ttlExpired_5630_; uint8_t v___x_5631_; uint8_t v___x_5632_;
v_hasFreeSlot_5625_ = lean_uint32_dec_lt(v_reservedSlots_5505_, v___y_5622_);
v___x_5626_ = 0;
v_hasReserved_5627_ = lean_uint32_dec_lt(v___x_5626_, v_reservedSlots_5505_);
v_hasActive_5628_ = lean_uint32_dec_lt(v___x_5626_, v_activeSlots_5506_);
v_ttlLive_5629_ = lean_uint64_dec_lt(v_nowTick_5511_, v_ttlExpiryTick_5512_);
v_ttlExpired_5630_ = lean_uint64_dec_le(v_ttlExpiryTick_5512_, v_nowTick_5511_);
v___x_5631_ = 0;
v___x_5632_ = lean_uint8_dec_eq(v_opKind_5504_, v___x_5631_);
if (v___x_5632_ == 0)
{
v___y_5612_ = v_ttlLive_5629_;
v___y_5613_ = v_hasReserved_5627_;
v___y_5614_ = v___x_5626_;
v___y_5615_ = v_ttlExpired_5630_;
v___y_5616_ = v___y_5623_;
v___y_5617_ = v_hasActive_5628_;
v___y_5618_ = v___x_5632_;
goto v___jp_5611_;
}
else
{
if (v___y_5624_ == 0)
{
v___y_5612_ = v_ttlLive_5629_;
v___y_5613_ = v_hasReserved_5627_;
v___y_5614_ = v___x_5626_;
v___y_5615_ = v_ttlExpired_5630_;
v___y_5616_ = v___y_5623_;
v___y_5617_ = v_hasActive_5628_;
v___y_5618_ = v___y_5624_;
goto v___jp_5611_;
}
else
{
if (v_hasFreeSlot_5625_ == 0)
{
v___y_5612_ = v_ttlLive_5629_;
v___y_5613_ = v_hasReserved_5627_;
v___y_5614_ = v___x_5626_;
v___y_5615_ = v_ttlExpired_5630_;
v___y_5616_ = v___y_5623_;
v___y_5617_ = v_hasActive_5628_;
v___y_5618_ = v_hasFreeSlot_5625_;
goto v___jp_5611_;
}
else
{
v___y_5612_ = v_ttlLive_5629_;
v___y_5613_ = v_hasReserved_5627_;
v___y_5614_ = v___x_5626_;
v___y_5615_ = v_ttlExpired_5630_;
v___y_5616_ = v___y_5623_;
v___y_5617_ = v_hasActive_5628_;
v___y_5618_ = v_ttlLive_5629_;
goto v___jp_5611_;
}
}
}
}
v___jp_5633_:
{
if (v___y_5635_ == 0)
{
v___y_5622_ = v___y_5634_;
v___y_5623_ = v___y_5635_;
v___y_5624_ = v___y_5635_;
goto v___jp_5621_;
}
else
{
uint8_t v___x_5637_;
v___x_5637_ = lean_uint64_dec_le(v_costDeltaCents_5509_, v___y_5636_);
v___y_5622_ = v___y_5634_;
v___y_5623_ = v___y_5635_;
v___y_5624_ = v___x_5637_;
goto v___jp_5621_;
}
}
v___jp_5638_:
{
if (v___y_5639_ == 0)
{
uint64_t v___x_5642_;
v___x_5642_ = 0ULL;
v___y_5634_ = v___y_5640_;
v___y_5635_ = v___y_5641_;
v___y_5636_ = v___x_5642_;
goto v___jp_5633_;
}
else
{
uint64_t v___x_5643_;
v___x_5643_ = lean_uint64_sub(v_budgetCents_5510_, v_spentCents_5508_);
v___y_5634_ = v___y_5640_;
v___y_5635_ = v___y_5641_;
v___y_5636_ = v___x_5643_;
goto v___jp_5633_;
}
}
v___jp_5644_:
{
uint8_t v_budgetValid_5646_;
v_budgetValid_5646_ = lean_uint64_dec_le(v_spentCents_5508_, v_budgetCents_5510_);
if (v_activeFits_5542_ == 0)
{
v___y_5639_ = v_budgetValid_5646_;
v___y_5640_ = v___y_5645_;
v___y_5641_ = v_activeFits_5542_;
goto v___jp_5638_;
}
else
{
uint8_t v_reservedFits_5647_;
v_reservedFits_5647_ = lean_uint32_dec_le(v_reservedSlots_5505_, v___y_5645_);
if (v_reservedFits_5647_ == 0)
{
v___y_5639_ = v_budgetValid_5646_;
v___y_5640_ = v___y_5645_;
v___y_5641_ = v_reservedFits_5647_;
goto v___jp_5638_;
}
else
{
v___y_5639_ = v_budgetValid_5646_;
v___y_5640_ = v___y_5645_;
v___y_5641_ = v_budgetValid_5646_;
goto v___jp_5638_;
}
}
}
}
}

LEAN_EXPORT uint64_t orb_stream_bounded_commit_step(uint32_t v_prevLen_5670_, uint32_t v_prevCommit_5671_, uint32_t v_prevCheckpoint_5672_, uint32_t v_newLen_5673_, uint32_t v_rawCommit_5674_, uint32_t v_maxOpenTailBytes_5675_){
_start:
{
uint32_t v___y_5677_; uint32_t v___y_5678_; uint32_t v___x_5684_; uint8_t v_validCap_5685_; uint32_t v___y_5687_; uint8_t v___y_5688_; uint32_t v___y_5689_; uint8_t v___y_5693_; uint32_t v___y_5694_; uint32_t v___y_5695_; uint8_t v___y_5699_; uint32_t v___y_5700_; uint32_t v___y_5701_; uint32_t v___y_5702_; uint8_t v___y_5705_; uint32_t v___y_5706_; uint32_t v___y_5707_; uint8_t v___y_5711_; uint32_t v___y_5712_; uint8_t v___y_5715_; uint32_t v___y_5716_; uint8_t v___y_5719_; uint8_t v___x_5721_;
v___x_5684_ = 0;
v_validCap_5685_ = lean_uint32_dec_lt(v___x_5684_, v_maxOpenTailBytes_5675_);
v___x_5721_ = lean_uint32_dec_le(v_prevCommit_5671_, v_prevCheckpoint_5672_);
if (v___x_5721_ == 0)
{
v___y_5719_ = v___x_5721_;
goto v___jp_5718_;
}
else
{
uint8_t v___x_5722_;
v___x_5722_ = lean_uint32_dec_le(v_prevCheckpoint_5672_, v_prevLen_5670_);
if (v___x_5722_ == 0)
{
v___y_5719_ = v___x_5722_;
goto v___jp_5718_;
}
else
{
uint8_t v___x_5723_;
v___x_5723_ = lean_uint32_dec_le(v_prevLen_5670_, v_newLen_5673_);
v___y_5719_ = v___x_5723_;
goto v___jp_5718_;
}
}
v___jp_5676_:
{
uint64_t v___x_5679_; uint64_t v___x_5680_; uint64_t v___x_5681_; uint64_t v___x_5682_; uint64_t v___x_5683_;
v___x_5679_ = lean_uint32_to_uint64(v___y_5677_);
v___x_5680_ = lean_uint32_to_uint64(v___y_5678_);
v___x_5681_ = 32ULL;
v___x_5682_ = lean_uint64_shift_left(v___x_5680_, v___x_5681_);
v___x_5683_ = lean_uint64_lor(v___x_5679_, v___x_5682_);
return v___x_5683_;
}
v___jp_5686_:
{
if (v_validCap_5685_ == 0)
{
v___y_5677_ = v___x_5684_;
v___y_5678_ = v_prevCheckpoint_5672_;
goto v___jp_5676_;
}
else
{
if (v___y_5688_ == 0)
{
v___y_5677_ = v___x_5684_;
v___y_5678_ = v_prevCheckpoint_5672_;
goto v___jp_5676_;
}
else
{
uint32_t v___x_5690_; uint32_t v___x_5691_;
v___x_5690_ = 257;
v___x_5691_ = lean_uint32_lor(v___x_5690_, v___y_5689_);
v___y_5677_ = v___x_5691_;
v___y_5678_ = v___y_5687_;
goto v___jp_5676_;
}
}
}
v___jp_5692_:
{
uint8_t v___x_5696_;
v___x_5696_ = lean_uint32_dec_lt(v___y_5694_, v___y_5695_);
if (v___x_5696_ == 0)
{
v___y_5687_ = v___y_5695_;
v___y_5688_ = v___y_5693_;
v___y_5689_ = v___x_5684_;
goto v___jp_5686_;
}
else
{
uint32_t v___x_5697_;
v___x_5697_ = 512;
v___y_5687_ = v___y_5695_;
v___y_5688_ = v___y_5693_;
v___y_5689_ = v___x_5697_;
goto v___jp_5686_;
}
}
v___jp_5698_:
{
uint8_t v___x_5703_;
v___x_5703_ = lean_uint32_dec_le(v___y_5701_, v___y_5702_);
if (v___x_5703_ == 0)
{
v___y_5693_ = v___y_5699_;
v___y_5694_ = v___y_5700_;
v___y_5695_ = v___y_5701_;
goto v___jp_5692_;
}
else
{
v___y_5693_ = v___y_5699_;
v___y_5694_ = v___y_5700_;
v___y_5695_ = v___y_5702_;
goto v___jp_5692_;
}
}
v___jp_5704_:
{
uint8_t v___x_5708_;
v___x_5708_ = lean_uint32_dec_le(v_maxOpenTailBytes_5675_, v_newLen_5673_);
if (v___x_5708_ == 0)
{
v___y_5699_ = v___y_5705_;
v___y_5700_ = v___y_5706_;
v___y_5701_ = v___y_5707_;
v___y_5702_ = v___x_5684_;
goto v___jp_5698_;
}
else
{
uint32_t v___x_5709_;
v___x_5709_ = lean_uint32_sub(v_newLen_5673_, v_maxOpenTailBytes_5675_);
v___y_5699_ = v___y_5705_;
v___y_5700_ = v___y_5706_;
v___y_5701_ = v___y_5707_;
v___y_5702_ = v___x_5709_;
goto v___jp_5698_;
}
}
v___jp_5710_:
{
uint8_t v___x_5713_;
v___x_5713_ = lean_uint32_dec_le(v_prevCheckpoint_5672_, v___y_5712_);
if (v___x_5713_ == 0)
{
v___y_5705_ = v___y_5711_;
v___y_5706_ = v___y_5712_;
v___y_5707_ = v_prevCheckpoint_5672_;
goto v___jp_5704_;
}
else
{
v___y_5705_ = v___y_5711_;
v___y_5706_ = v___y_5712_;
v___y_5707_ = v___y_5712_;
goto v___jp_5704_;
}
}
v___jp_5714_:
{
uint8_t v___x_5717_;
v___x_5717_ = lean_uint32_dec_le(v_prevCommit_5671_, v___y_5716_);
if (v___x_5717_ == 0)
{
v___y_5711_ = v___y_5715_;
v___y_5712_ = v_prevCommit_5671_;
goto v___jp_5710_;
}
else
{
v___y_5711_ = v___y_5715_;
v___y_5712_ = v___y_5716_;
goto v___jp_5710_;
}
}
v___jp_5718_:
{
uint8_t v___x_5720_;
v___x_5720_ = lean_uint32_dec_le(v_rawCommit_5674_, v_newLen_5673_);
if (v___x_5720_ == 0)
{
v___y_5715_ = v___y_5719_;
v___y_5716_ = v_newLen_5673_;
goto v___jp_5714_;
}
else
{
v___y_5715_ = v___y_5719_;
v___y_5716_ = v_rawCommit_5674_;
goto v___jp_5714_;
}
}
}
}

LEAN_EXPORT uint32_t orb_vm_cap_admit(uint8_t v_hasPoolOverride_5738_, uint8_t v_hasPoolMax_5739_, uint8_t v_hasProviderMax_5740_, uint8_t v_hasGlobalMax_5741_, uint8_t v_ancestorBlocked_5742_, uint32_t v_sharedActive_5743_, uint32_t v_globalMax_5744_, uint32_t v_poolActive_5745_, uint32_t v_poolMax_5746_, uint32_t v_providerActive_5747_, uint32_t v_providerMax_5748_){
_start:
{
uint8_t v___x_5761_; uint8_t v___x_5762_;
v___x_5761_ = 1;
v___x_5762_ = lean_uint8_dec_eq(v_ancestorBlocked_5742_, v___x_5761_);
if (v___x_5762_ == 0)
{
uint8_t v___x_5763_;
v___x_5763_ = lean_uint8_dec_eq(v_hasPoolOverride_5738_, v___x_5761_);
if (v___x_5763_ == 0)
{
uint8_t v___x_5764_; uint8_t v___x_5765_;
v___x_5764_ = 0;
v___x_5765_ = lean_uint8_dec_eq(v_hasGlobalMax_5741_, v___x_5764_);
if (v___x_5765_ == 0)
{
uint8_t v___x_5766_;
v___x_5766_ = lean_uint32_dec_lt(v_sharedActive_5743_, v_globalMax_5744_);
if (v___x_5766_ == 0)
{
uint32_t v___x_5767_;
v___x_5767_ = 512;
return v___x_5767_;
}
else
{
uint32_t v___x_5768_;
v___x_5768_ = 257;
return v___x_5768_;
}
}
else
{
uint32_t v___x_5769_;
v___x_5769_ = 257;
return v___x_5769_;
}
}
else
{
uint8_t v___x_5770_;
v___x_5770_ = lean_uint8_dec_eq(v_hasPoolMax_5739_, v___x_5761_);
if (v___x_5770_ == 0)
{
uint8_t v___x_5771_;
v___x_5771_ = lean_uint8_dec_eq(v_hasProviderMax_5740_, v___x_5761_);
if (v___x_5771_ == 0)
{
uint32_t v___x_5772_;
v___x_5772_ = 512;
return v___x_5772_;
}
else
{
goto v___jp_5756_;
}
}
else
{
goto v___jp_5756_;
}
}
}
else
{
uint32_t v___x_5773_;
v___x_5773_ = 512;
return v___x_5773_;
}
v___jp_5749_:
{
uint8_t v___x_5750_; uint8_t v___x_5751_;
v___x_5750_ = 0;
v___x_5751_ = lean_uint8_dec_eq(v_hasPoolMax_5739_, v___x_5750_);
if (v___x_5751_ == 0)
{
uint8_t v___x_5752_;
v___x_5752_ = lean_uint32_dec_lt(v_poolActive_5745_, v_poolMax_5746_);
if (v___x_5752_ == 0)
{
uint32_t v___x_5753_;
v___x_5753_ = 512;
return v___x_5753_;
}
else
{
uint32_t v___x_5754_;
v___x_5754_ = 257;
return v___x_5754_;
}
}
else
{
uint32_t v___x_5755_;
v___x_5755_ = 257;
return v___x_5755_;
}
}
v___jp_5756_:
{
uint8_t v___x_5757_; uint8_t v___x_5758_;
v___x_5757_ = 0;
v___x_5758_ = lean_uint8_dec_eq(v_hasProviderMax_5740_, v___x_5757_);
if (v___x_5758_ == 0)
{
uint8_t v___x_5759_;
v___x_5759_ = lean_uint32_dec_lt(v_providerActive_5747_, v_providerMax_5748_);
if (v___x_5759_ == 0)
{
uint32_t v___x_5760_;
v___x_5760_ = 512;
return v___x_5760_;
}
else
{
goto v___jp_5749_;
}
}
else
{
goto v___jp_5749_;
}
}
}
}

LEAN_EXPORT uint32_t orb_slot_bypass_step(uint8_t v_isOperatorForce_5798_, uint8_t v_isAgentCaller_5799_, uint8_t v_isWaitingSlot_5800_, uint32_t v_regularRunning_5801_, uint32_t v_regularMax_5802_, uint32_t v_forcedRunning_5803_, uint32_t v_forcedMax_5804_){
_start:
{
uint8_t v___x_5805_; uint8_t v___x_5806_;
v___x_5805_ = 1;
v___x_5806_ = lean_uint8_dec_eq(v_isOperatorForce_5798_, v___x_5805_);
if (v___x_5806_ == 0)
{
uint8_t v___x_5807_;
v___x_5807_ = lean_uint32_dec_lt(v_regularRunning_5801_, v_regularMax_5802_);
if (v___x_5807_ == 0)
{
uint32_t v___x_5808_;
v___x_5808_ = 512;
return v___x_5808_;
}
else
{
uint32_t v___x_5809_;
v___x_5809_ = 257;
return v___x_5809_;
}
}
else
{
uint8_t v___x_5810_;
v___x_5810_ = lean_uint8_dec_eq(v_isAgentCaller_5799_, v___x_5805_);
if (v___x_5810_ == 0)
{
uint8_t v___x_5811_;
v___x_5811_ = lean_uint8_dec_eq(v_isWaitingSlot_5800_, v___x_5805_);
if (v___x_5811_ == 0)
{
uint32_t v___x_5812_;
v___x_5812_ = 514;
return v___x_5812_;
}
else
{
uint8_t v___x_5813_;
v___x_5813_ = lean_uint32_dec_lt(v_forcedRunning_5803_, v_forcedMax_5804_);
if (v___x_5813_ == 0)
{
uint32_t v___x_5814_;
v___x_5814_ = 512;
return v___x_5814_;
}
else
{
uint32_t v___x_5815_;
v___x_5815_ = 258;
return v___x_5815_;
}
}
}
else
{
uint32_t v___x_5816_;
v___x_5816_ = 513;
return v___x_5816_;
}
}
}
}

LEAN_EXPORT uint64_t orb_node_resize_step(uint8_t v_isOperatorCaller_5833_, uint8_t v_isAgentCaller_5834_, uint8_t v_isStaticNode_5835_, uint32_t v_curCap_5836_, uint32_t v_curDebt_5837_, uint32_t v_idlePermits_5838_, uint32_t v_targetCap_5839_, uint32_t v_maxCap_5840_){
_start:
{
uint32_t v___y_5842_; uint32_t v___y_5843_; uint32_t v___y_5850_; uint32_t v___y_5851_; uint32_t v___y_5852_; uint32_t v___y_5859_; uint8_t v___y_5869_; uint8_t v___y_5870_; uint8_t v___y_5871_; uint8_t v___x_5880_; uint8_t v___y_5882_; uint8_t v___x_5887_;
v___x_5880_ = 1;
v___x_5887_ = lean_uint8_dec_eq(v_isOperatorCaller_5833_, v___x_5880_);
if (v___x_5887_ == 0)
{
v___y_5882_ = v___x_5887_;
goto v___jp_5881_;
}
else
{
uint8_t v___x_5888_;
v___x_5888_ = lean_uint8_dec_eq(v_isAgentCaller_5834_, v___x_5880_);
if (v___x_5888_ == 0)
{
v___y_5882_ = v___x_5887_;
goto v___jp_5881_;
}
else
{
uint8_t v___x_5889_;
v___x_5889_ = 0;
v___y_5882_ = v___x_5889_;
goto v___jp_5881_;
}
}
v___jp_5841_:
{
uint64_t v___x_5844_; uint64_t v___x_5845_; uint64_t v___x_5846_; uint64_t v___x_5847_; uint64_t v___x_5848_;
v___x_5844_ = lean_uint32_to_uint64(v___y_5842_);
v___x_5845_ = lean_uint32_to_uint64(v___y_5843_);
v___x_5846_ = 32ULL;
v___x_5847_ = lean_uint64_shift_left(v___x_5845_, v___x_5846_);
v___x_5848_ = lean_uint64_lor(v___x_5844_, v___x_5847_);
return v___x_5848_;
}
v___jp_5849_:
{
uint32_t v___x_5853_; uint32_t v___x_5854_; uint32_t v___x_5855_; uint8_t v___x_5856_;
v___x_5853_ = lean_uint32_sub(v___y_5850_, v___y_5852_);
v___x_5854_ = 4294967295;
v___x_5855_ = lean_uint32_sub(v___x_5854_, v___x_5853_);
v___x_5856_ = lean_uint32_dec_le(v_curDebt_5837_, v___x_5855_);
if (v___x_5856_ == 0)
{
v___y_5842_ = v___y_5851_;
v___y_5843_ = v___x_5854_;
goto v___jp_5841_;
}
else
{
uint32_t v___x_5857_;
v___x_5857_ = lean_uint32_add(v_curDebt_5837_, v___x_5853_);
v___y_5842_ = v___y_5851_;
v___y_5843_ = v___x_5857_;
goto v___jp_5841_;
}
}
v___jp_5858_:
{
uint8_t v___x_5860_;
v___x_5860_ = lean_uint32_dec_lt(v_curCap_5836_, v_targetCap_5839_);
if (v___x_5860_ == 0)
{
uint8_t v___x_5861_;
v___x_5861_ = lean_uint32_dec_lt(v_targetCap_5839_, v_curCap_5836_);
if (v___x_5861_ == 0)
{
v___y_5842_ = v___y_5859_;
v___y_5843_ = v_curDebt_5837_;
goto v___jp_5841_;
}
else
{
uint32_t v_shrink_5862_; uint8_t v___x_5863_;
v_shrink_5862_ = lean_uint32_sub(v_curCap_5836_, v_targetCap_5839_);
v___x_5863_ = lean_uint32_dec_le(v_shrink_5862_, v_idlePermits_5838_);
if (v___x_5863_ == 0)
{
v___y_5850_ = v_shrink_5862_;
v___y_5851_ = v___y_5859_;
v___y_5852_ = v_idlePermits_5838_;
goto v___jp_5849_;
}
else
{
v___y_5850_ = v_shrink_5862_;
v___y_5851_ = v___y_5859_;
v___y_5852_ = v_shrink_5862_;
goto v___jp_5849_;
}
}
}
else
{
uint32_t v_grow_5864_; uint8_t v___x_5865_;
v_grow_5864_ = lean_uint32_sub(v_targetCap_5839_, v_curCap_5836_);
v___x_5865_ = lean_uint32_dec_le(v_curDebt_5837_, v_grow_5864_);
if (v___x_5865_ == 0)
{
uint32_t v___x_5866_;
v___x_5866_ = lean_uint32_sub(v_curDebt_5837_, v_grow_5864_);
v___y_5842_ = v___y_5859_;
v___y_5843_ = v___x_5866_;
goto v___jp_5841_;
}
else
{
uint32_t v___x_5867_;
v___x_5867_ = 0;
v___y_5842_ = v___y_5859_;
v___y_5843_ = v___x_5867_;
goto v___jp_5841_;
}
}
}
v___jp_5868_:
{
if (v___y_5869_ == 0)
{
uint32_t v___x_5872_;
v___x_5872_ = 513;
v___y_5842_ = v___x_5872_;
v___y_5843_ = v_curDebt_5837_;
goto v___jp_5841_;
}
else
{
if (v___y_5870_ == 0)
{
uint32_t v___x_5873_;
v___x_5873_ = 514;
v___y_5842_ = v___x_5873_;
v___y_5843_ = v_curDebt_5837_;
goto v___jp_5841_;
}
else
{
if (v___y_5871_ == 0)
{
uint32_t v___x_5874_;
v___x_5874_ = 515;
v___y_5842_ = v___x_5874_;
v___y_5843_ = v_curDebt_5837_;
goto v___jp_5841_;
}
else
{
uint8_t v___x_5875_;
v___x_5875_ = lean_uint32_dec_lt(v_curCap_5836_, v_targetCap_5839_);
if (v___x_5875_ == 0)
{
uint8_t v___x_5876_;
v___x_5876_ = lean_uint32_dec_lt(v_targetCap_5839_, v_curCap_5836_);
if (v___x_5876_ == 0)
{
uint32_t v___x_5877_;
v___x_5877_ = 259;
v___y_5859_ = v___x_5877_;
goto v___jp_5858_;
}
else
{
uint32_t v___x_5878_;
v___x_5878_ = 1282;
v___y_5859_ = v___x_5878_;
goto v___jp_5858_;
}
}
else
{
uint32_t v___x_5879_;
v___x_5879_ = 1281;
v___y_5859_ = v___x_5879_;
goto v___jp_5858_;
}
}
}
}
}
v___jp_5881_:
{
uint8_t v_staticOk_5883_; uint32_t v___x_5884_; uint8_t v___x_5885_;
v_staticOk_5883_ = lean_uint8_dec_eq(v_isStaticNode_5835_, v___x_5880_);
v___x_5884_ = 1;
v___x_5885_ = lean_uint32_dec_le(v___x_5884_, v_targetCap_5839_);
if (v___x_5885_ == 0)
{
v___y_5869_ = v___y_5882_;
v___y_5870_ = v_staticOk_5883_;
v___y_5871_ = v___x_5885_;
goto v___jp_5868_;
}
else
{
uint8_t v___x_5886_;
v___x_5886_ = lean_uint32_dec_le(v_targetCap_5839_, v_maxCap_5840_);
v___y_5869_ = v___y_5882_;
v___y_5870_ = v_staticOk_5883_;
v___y_5871_ = v___x_5886_;
goto v___jp_5868_;
}
}
}
}

LEAN_EXPORT uint32_t orb_node_lane_step(uint8_t v_isSideQuestion_5908_, uint8_t v_isCoordinatorPriority_5909_, uint8_t v_hasWorkspaceBg_5910_, uint8_t v_isChildWorker_5911_, uint8_t v_isLongRunning_5912_, uint32_t v_mainRunning_5913_, uint32_t v_mainMax_5914_, uint32_t v_sideRunning_5915_, uint32_t v_sideMax_5916_, uint32_t v_coordRunning_5917_, uint32_t v_coordMax_5918_){
_start:
{
uint8_t v___x_5923_; uint8_t v___x_5924_;
v___x_5923_ = 1;
v___x_5924_ = lean_uint8_dec_eq(v_isSideQuestion_5908_, v___x_5923_);
if (v___x_5924_ == 0)
{
uint8_t v___x_5925_;
v___x_5925_ = lean_uint8_dec_eq(v_hasWorkspaceBg_5910_, v___x_5923_);
if (v___x_5925_ == 0)
{
uint8_t v___x_5926_;
v___x_5926_ = lean_uint8_dec_eq(v_isCoordinatorPriority_5909_, v___x_5923_);
if (v___x_5926_ == 0)
{
goto v___jp_5919_;
}
else
{
uint8_t v___x_5927_;
v___x_5927_ = lean_uint8_dec_eq(v_isChildWorker_5911_, v___x_5923_);
if (v___x_5927_ == 0)
{
uint8_t v___x_5928_;
v___x_5928_ = lean_uint8_dec_eq(v_isLongRunning_5912_, v___x_5923_);
if (v___x_5928_ == 0)
{
uint8_t v___x_5929_;
v___x_5929_ = lean_uint32_dec_lt(v_mainRunning_5913_, v_mainMax_5914_);
if (v___x_5929_ == 0)
{
uint8_t v___x_5930_;
v___x_5930_ = lean_uint32_dec_lt(v_coordRunning_5917_, v_coordMax_5918_);
if (v___x_5930_ == 0)
{
uint32_t v___x_5931_;
v___x_5931_ = 515;
return v___x_5931_;
}
else
{
uint32_t v___x_5932_;
v___x_5932_ = 259;
return v___x_5932_;
}
}
else
{
uint32_t v___x_5933_;
v___x_5933_ = 257;
return v___x_5933_;
}
}
else
{
goto v___jp_5919_;
}
}
else
{
goto v___jp_5919_;
}
}
}
else
{
uint8_t v___x_5934_;
v___x_5934_ = lean_uint32_dec_lt(v_coordRunning_5917_, v_coordMax_5918_);
if (v___x_5934_ == 0)
{
uint8_t v___x_5935_;
v___x_5935_ = lean_uint32_dec_lt(v_mainRunning_5913_, v_mainMax_5914_);
if (v___x_5935_ == 0)
{
uint32_t v___x_5936_;
v___x_5936_ = 515;
return v___x_5936_;
}
else
{
uint32_t v___x_5937_;
v___x_5937_ = 257;
return v___x_5937_;
}
}
else
{
uint32_t v___x_5938_;
v___x_5938_ = 260;
return v___x_5938_;
}
}
}
else
{
uint8_t v___x_5939_;
v___x_5939_ = lean_uint32_dec_lt(v_sideRunning_5915_, v_sideMax_5916_);
if (v___x_5939_ == 0)
{
uint32_t v___x_5940_;
v___x_5940_ = 514;
return v___x_5940_;
}
else
{
uint32_t v___x_5941_;
v___x_5941_ = 258;
return v___x_5941_;
}
}
v___jp_5919_:
{
uint8_t v___x_5920_;
v___x_5920_ = lean_uint32_dec_lt(v_mainRunning_5913_, v_mainMax_5914_);
if (v___x_5920_ == 0)
{
uint32_t v___x_5921_;
v___x_5921_ = 513;
return v___x_5921_;
}
else
{
uint32_t v___x_5922_;
v___x_5922_ = 257;
return v___x_5922_;
}
}
}
}

LEAN_EXPORT uint8_t orb_wire_verify_slice_io(uint64_t v_inPtr_5994_, uint64_t v_inLen_5995_, uint64_t v_outPtr_5996_, uint64_t v_outCap_5997_, uint64_t v_writtenLen_5998_, uint8_t v_is32Bit_5999_){
_start:
{
uint8_t v___x_6010_; uint8_t v___x_6011_;
v___x_6010_ = 1;
v___x_6011_ = lean_uint8_dec_le(v_is32Bit_5999_, v___x_6010_);
if (v___x_6011_ == 0)
{
uint8_t v___x_6012_;
v___x_6012_ = 6;
return v___x_6012_;
}
else
{
uint64_t v___x_6013_; uint8_t v___x_6014_; uint8_t v___y_6021_; uint8_t v___y_6024_; uint8_t v___y_6043_; uint8_t v___y_6060_;
v___x_6013_ = 0ULL;
v___x_6014_ = lean_uint64_dec_eq(v_inLen_5995_, v___x_6013_);
if (v___x_6014_ == 0)
{
uint8_t v___x_6064_;
v___x_6064_ = lean_uint64_dec_eq(v_inPtr_5994_, v___x_6013_);
if (v___x_6064_ == 0)
{
v___y_6060_ = v___x_6011_;
goto v___jp_6059_;
}
else
{
uint8_t v___x_6065_;
v___x_6065_ = 7;
return v___x_6065_;
}
}
else
{
v___y_6060_ = v___x_6011_;
goto v___jp_6059_;
}
v___jp_6015_:
{
if (v___x_6014_ == 0)
{
uint8_t v___x_6016_;
v___x_6016_ = lean_uint64_dec_eq(v_outCap_5997_, v___x_6013_);
if (v___x_6016_ == 0)
{
uint8_t v___x_6017_;
v___x_6017_ = lean_uint64_dec_le(v_inLen_5995_, v_outPtr_5996_);
if (v___x_6017_ == 0)
{
goto v___jp_6004_;
}
else
{
uint64_t v___x_6018_; uint8_t v___x_6019_;
v___x_6018_ = lean_uint64_sub(v_outPtr_5996_, v_inLen_5995_);
v___x_6019_ = lean_uint64_dec_le(v_inPtr_5994_, v___x_6018_);
if (v___x_6019_ == 0)
{
goto v___jp_6004_;
}
else
{
goto v___jp_6000_;
}
}
}
else
{
goto v___jp_6000_;
}
}
else
{
goto v___jp_6000_;
}
}
v___jp_6020_:
{
if (v___y_6021_ == 0)
{
uint8_t v___x_6022_;
v___x_6022_ = 8;
return v___x_6022_;
}
else
{
goto v___jp_6015_;
}
}
v___jp_6023_:
{
if (v___y_6024_ == 0)
{
uint8_t v___x_6025_;
v___x_6025_ = 8;
return v___x_6025_;
}
else
{
uint8_t v___x_6026_;
v___x_6026_ = lean_uint8_dec_eq(v_is32Bit_5999_, v___x_6010_);
if (v___x_6026_ == 0)
{
uint8_t v___x_6027_;
v___x_6027_ = lean_uint64_dec_eq(v_outPtr_5996_, v___x_6013_);
if (v___x_6027_ == 0)
{
uint8_t v___x_6028_;
v___x_6028_ = lean_uint64_dec_eq(v_outCap_5997_, v___x_6013_);
if (v___x_6028_ == 0)
{
uint64_t v___x_6029_; uint64_t v___x_6030_; uint64_t v___x_6031_; uint64_t v___x_6032_; uint8_t v___x_6033_;
v___x_6029_ = 1ULL;
v___x_6030_ = lean_uint64_sub(v_outPtr_5996_, v___x_6029_);
v___x_6031_ = 18446744073709551615ULL;
v___x_6032_ = lean_uint64_sub(v___x_6031_, v_outCap_5997_);
v___x_6033_ = lean_uint64_dec_le(v___x_6030_, v___x_6032_);
v___y_6021_ = v___x_6033_;
goto v___jp_6020_;
}
else
{
goto v___jp_6015_;
}
}
else
{
goto v___jp_6015_;
}
}
else
{
uint64_t v___x_6034_; uint8_t v___x_6035_;
v___x_6034_ = 4294967295ULL;
v___x_6035_ = lean_uint64_dec_le(v_outPtr_5996_, v___x_6034_);
if (v___x_6035_ == 0)
{
uint8_t v___x_6036_;
v___x_6036_ = 8;
return v___x_6036_;
}
else
{
uint8_t v___x_6037_;
v___x_6037_ = lean_uint64_dec_le(v_outCap_5997_, v___x_6034_);
if (v___x_6037_ == 0)
{
uint8_t v___x_6038_;
v___x_6038_ = 8;
return v___x_6038_;
}
else
{
uint64_t v___x_6039_; uint64_t v___x_6040_; uint8_t v___x_6041_;
v___x_6039_ = lean_uint64_add(v_outPtr_5996_, v_outCap_5997_);
v___x_6040_ = 4294967296ULL;
v___x_6041_ = lean_uint64_dec_le(v___x_6039_, v___x_6040_);
v___y_6021_ = v___x_6041_;
goto v___jp_6020_;
}
}
}
}
}
v___jp_6042_:
{
uint8_t v___x_6044_;
v___x_6044_ = lean_uint8_dec_eq(v_is32Bit_5999_, v___x_6010_);
if (v___x_6044_ == 0)
{
uint8_t v___x_6045_;
v___x_6045_ = lean_uint64_dec_eq(v_inPtr_5994_, v___x_6013_);
if (v___x_6045_ == 0)
{
if (v___x_6014_ == 0)
{
uint64_t v___x_6046_; uint64_t v___x_6047_; uint64_t v___x_6048_; uint64_t v___x_6049_; uint8_t v___x_6050_;
v___x_6046_ = 1ULL;
v___x_6047_ = lean_uint64_sub(v_inPtr_5994_, v___x_6046_);
v___x_6048_ = 18446744073709551615ULL;
v___x_6049_ = lean_uint64_sub(v___x_6048_, v_inLen_5995_);
v___x_6050_ = lean_uint64_dec_le(v___x_6047_, v___x_6049_);
v___y_6024_ = v___x_6050_;
goto v___jp_6023_;
}
else
{
v___y_6024_ = v___y_6043_;
goto v___jp_6023_;
}
}
else
{
v___y_6024_ = v___y_6043_;
goto v___jp_6023_;
}
}
else
{
uint64_t v___x_6051_; uint8_t v___x_6052_;
v___x_6051_ = 4294967295ULL;
v___x_6052_ = lean_uint64_dec_le(v_inPtr_5994_, v___x_6051_);
if (v___x_6052_ == 0)
{
uint8_t v___x_6053_;
v___x_6053_ = 8;
return v___x_6053_;
}
else
{
uint8_t v___x_6054_;
v___x_6054_ = lean_uint64_dec_le(v_inLen_5995_, v___x_6051_);
if (v___x_6054_ == 0)
{
uint8_t v___x_6055_;
v___x_6055_ = 8;
return v___x_6055_;
}
else
{
uint64_t v___x_6056_; uint64_t v___x_6057_; uint8_t v___x_6058_;
v___x_6056_ = lean_uint64_add(v_inPtr_5994_, v_inLen_5995_);
v___x_6057_ = 4294967296ULL;
v___x_6058_ = lean_uint64_dec_le(v___x_6056_, v___x_6057_);
v___y_6024_ = v___x_6058_;
goto v___jp_6023_;
}
}
}
}
v___jp_6059_:
{
uint8_t v___x_6061_;
v___x_6061_ = lean_uint64_dec_eq(v_outCap_5997_, v___x_6013_);
if (v___x_6061_ == 0)
{
uint8_t v___x_6062_;
v___x_6062_ = lean_uint64_dec_eq(v_outPtr_5996_, v___x_6013_);
if (v___x_6062_ == 0)
{
v___y_6043_ = v___y_6060_;
goto v___jp_6042_;
}
else
{
uint8_t v___x_6063_;
v___x_6063_ = 7;
return v___x_6063_;
}
}
else
{
v___y_6043_ = v___x_6011_;
goto v___jp_6042_;
}
}
}
v___jp_6000_:
{
uint8_t v___x_6001_;
v___x_6001_ = lean_uint64_dec_le(v_writtenLen_5998_, v_outCap_5997_);
if (v___x_6001_ == 0)
{
uint8_t v___x_6002_;
v___x_6002_ = 5;
return v___x_6002_;
}
else
{
uint8_t v___x_6003_;
v___x_6003_ = 0;
return v___x_6003_;
}
}
v___jp_6004_:
{
uint8_t v___x_6005_;
v___x_6005_ = lean_uint64_dec_le(v_outCap_5997_, v_inPtr_5994_);
if (v___x_6005_ == 0)
{
uint8_t v___x_6006_;
v___x_6006_ = 9;
return v___x_6006_;
}
else
{
uint64_t v___x_6007_; uint8_t v___x_6008_;
v___x_6007_ = lean_uint64_sub(v_inPtr_5994_, v_outCap_5997_);
v___x_6008_ = lean_uint64_dec_le(v_outPtr_5996_, v___x_6007_);
if (v___x_6008_ == 0)
{
uint8_t v___x_6009_;
v___x_6009_ = 9;
return v___x_6009_;
}
else
{
goto v___jp_6000_;
}
}
}
}
}

LEAN_EXPORT uint8_t orb_wire_encode_slice_step(uint64_t v_inArenaPtr_6080_, uint64_t v_outPtr_6081_, uint64_t v_outCap_6082_, uint32_t v_schemaId_6083_, uint32_t v_recordsCount_6084_, uint32_t v_arenaLen_6085_, uint32_t v_maxBudgetBytes_6086_, uint8_t v_is32Bit_6087_){
_start:
{
uint32_t v___x_6088_; uint8_t v___x_6089_;
v___x_6088_ = 1;
v___x_6089_ = lean_uint32_dec_le(v___x_6088_, v_schemaId_6083_);
if (v___x_6089_ == 0)
{
uint8_t v___x_6090_;
v___x_6090_ = 2;
return v___x_6090_;
}
else
{
uint32_t v___x_6091_; uint8_t v___x_6092_;
v___x_6091_ = 65535;
v___x_6092_ = lean_uint32_dec_le(v_schemaId_6083_, v___x_6091_);
if (v___x_6092_ == 0)
{
uint8_t v___x_6093_;
v___x_6093_ = 2;
return v___x_6093_;
}
else
{
uint32_t v___x_6094_; uint8_t v___x_6095_;
v___x_6094_ = 8191;
v___x_6095_ = lean_uint32_dec_le(v_recordsCount_6084_, v___x_6094_);
if (v___x_6095_ == 0)
{
uint8_t v___x_6096_;
v___x_6096_ = 3;
return v___x_6096_;
}
else
{
uint8_t v___x_6097_;
v___x_6097_ = lean_uint32_dec_le(v_arenaLen_6085_, v___x_6091_);
if (v___x_6097_ == 0)
{
uint8_t v___x_6098_;
v___x_6098_ = 3;
return v___x_6098_;
}
else
{
uint32_t v___x_6099_; uint32_t v_recordsBytes_6100_; uint32_t v_payloadLen_6101_; uint32_t v___x_6102_; uint32_t v_totalLen_6103_; uint8_t v___x_6104_;
v___x_6099_ = 3;
v_recordsBytes_6100_ = lean_uint32_shift_left(v_recordsCount_6084_, v___x_6099_);
v_payloadLen_6101_ = lean_uint32_add(v_recordsBytes_6100_, v_arenaLen_6085_);
v___x_6102_ = 24;
v_totalLen_6103_ = lean_uint32_add(v___x_6102_, v_payloadLen_6101_);
v___x_6104_ = lean_uint32_dec_le(v_totalLen_6103_, v_maxBudgetBytes_6086_);
if (v___x_6104_ == 0)
{
uint8_t v___x_6105_;
v___x_6105_ = 4;
return v___x_6105_;
}
else
{
uint8_t v___x_6106_; uint8_t v___x_6107_;
v___x_6106_ = 1;
v___x_6107_ = lean_uint8_dec_le(v_is32Bit_6087_, v___x_6106_);
if (v___x_6107_ == 0)
{
uint8_t v___x_6108_;
v___x_6108_ = 6;
return v___x_6108_;
}
else
{
uint64_t v___x_6109_; uint64_t v___x_6110_; uint64_t v___x_6121_; uint8_t v___x_6122_; uint8_t v___y_6129_; uint8_t v___y_6132_; uint8_t v___y_6151_; uint8_t v___y_6168_;
v___x_6109_ = lean_uint32_to_uint64(v_arenaLen_6085_);
v___x_6110_ = lean_uint32_to_uint64(v_totalLen_6103_);
v___x_6121_ = 0ULL;
v___x_6122_ = lean_uint64_dec_eq(v___x_6109_, v___x_6121_);
if (v___x_6122_ == 0)
{
uint8_t v___x_6172_;
v___x_6172_ = lean_uint64_dec_eq(v_inArenaPtr_6080_, v___x_6121_);
if (v___x_6172_ == 0)
{
v___y_6168_ = v___x_6107_;
goto v___jp_6167_;
}
else
{
uint8_t v___x_6173_;
v___x_6173_ = 7;
return v___x_6173_;
}
}
else
{
v___y_6168_ = v___x_6107_;
goto v___jp_6167_;
}
v___jp_6111_:
{
uint8_t v___x_6112_;
v___x_6112_ = lean_uint64_dec_le(v___x_6110_, v_outCap_6082_);
if (v___x_6112_ == 0)
{
uint8_t v___x_6113_;
v___x_6113_ = 5;
return v___x_6113_;
}
else
{
uint8_t v___x_6114_;
v___x_6114_ = 0;
return v___x_6114_;
}
}
v___jp_6115_:
{
uint8_t v___x_6116_;
v___x_6116_ = lean_uint64_dec_le(v_outCap_6082_, v_inArenaPtr_6080_);
if (v___x_6116_ == 0)
{
uint8_t v___x_6117_;
v___x_6117_ = 9;
return v___x_6117_;
}
else
{
uint64_t v___x_6118_; uint8_t v___x_6119_;
v___x_6118_ = lean_uint64_sub(v_inArenaPtr_6080_, v_outCap_6082_);
v___x_6119_ = lean_uint64_dec_le(v_outPtr_6081_, v___x_6118_);
if (v___x_6119_ == 0)
{
uint8_t v___x_6120_;
v___x_6120_ = 9;
return v___x_6120_;
}
else
{
goto v___jp_6111_;
}
}
}
v___jp_6123_:
{
if (v___x_6122_ == 0)
{
uint8_t v___x_6124_;
v___x_6124_ = lean_uint64_dec_eq(v_outCap_6082_, v___x_6121_);
if (v___x_6124_ == 0)
{
uint8_t v___x_6125_;
v___x_6125_ = lean_uint64_dec_le(v___x_6109_, v_outPtr_6081_);
if (v___x_6125_ == 0)
{
goto v___jp_6115_;
}
else
{
uint64_t v___x_6126_; uint8_t v___x_6127_;
v___x_6126_ = lean_uint64_sub(v_outPtr_6081_, v___x_6109_);
v___x_6127_ = lean_uint64_dec_le(v_inArenaPtr_6080_, v___x_6126_);
if (v___x_6127_ == 0)
{
goto v___jp_6115_;
}
else
{
goto v___jp_6111_;
}
}
}
else
{
goto v___jp_6111_;
}
}
else
{
goto v___jp_6111_;
}
}
v___jp_6128_:
{
if (v___y_6129_ == 0)
{
uint8_t v___x_6130_;
v___x_6130_ = 8;
return v___x_6130_;
}
else
{
goto v___jp_6123_;
}
}
v___jp_6131_:
{
if (v___y_6132_ == 0)
{
uint8_t v___x_6133_;
v___x_6133_ = 8;
return v___x_6133_;
}
else
{
uint8_t v___x_6134_;
v___x_6134_ = lean_uint8_dec_eq(v_is32Bit_6087_, v___x_6106_);
if (v___x_6134_ == 0)
{
uint8_t v___x_6135_;
v___x_6135_ = lean_uint64_dec_eq(v_outPtr_6081_, v___x_6121_);
if (v___x_6135_ == 0)
{
uint8_t v___x_6136_;
v___x_6136_ = lean_uint64_dec_eq(v_outCap_6082_, v___x_6121_);
if (v___x_6136_ == 0)
{
uint64_t v___x_6137_; uint64_t v___x_6138_; uint64_t v___x_6139_; uint64_t v___x_6140_; uint8_t v___x_6141_;
v___x_6137_ = 1ULL;
v___x_6138_ = lean_uint64_sub(v_outPtr_6081_, v___x_6137_);
v___x_6139_ = 18446744073709551615ULL;
v___x_6140_ = lean_uint64_sub(v___x_6139_, v_outCap_6082_);
v___x_6141_ = lean_uint64_dec_le(v___x_6138_, v___x_6140_);
v___y_6129_ = v___x_6141_;
goto v___jp_6128_;
}
else
{
goto v___jp_6123_;
}
}
else
{
goto v___jp_6123_;
}
}
else
{
uint64_t v___x_6142_; uint8_t v___x_6143_;
v___x_6142_ = 4294967295ULL;
v___x_6143_ = lean_uint64_dec_le(v_outPtr_6081_, v___x_6142_);
if (v___x_6143_ == 0)
{
uint8_t v___x_6144_;
v___x_6144_ = 8;
return v___x_6144_;
}
else
{
uint8_t v___x_6145_;
v___x_6145_ = lean_uint64_dec_le(v_outCap_6082_, v___x_6142_);
if (v___x_6145_ == 0)
{
uint8_t v___x_6146_;
v___x_6146_ = 8;
return v___x_6146_;
}
else
{
uint64_t v___x_6147_; uint64_t v___x_6148_; uint8_t v___x_6149_;
v___x_6147_ = lean_uint64_add(v_outPtr_6081_, v_outCap_6082_);
v___x_6148_ = 4294967296ULL;
v___x_6149_ = lean_uint64_dec_le(v___x_6147_, v___x_6148_);
v___y_6129_ = v___x_6149_;
goto v___jp_6128_;
}
}
}
}
}
v___jp_6150_:
{
uint8_t v___x_6152_;
v___x_6152_ = lean_uint8_dec_eq(v_is32Bit_6087_, v___x_6106_);
if (v___x_6152_ == 0)
{
uint8_t v___x_6153_;
v___x_6153_ = lean_uint64_dec_eq(v_inArenaPtr_6080_, v___x_6121_);
if (v___x_6153_ == 0)
{
if (v___x_6122_ == 0)
{
uint64_t v___x_6154_; uint64_t v___x_6155_; uint64_t v___x_6156_; uint64_t v___x_6157_; uint8_t v___x_6158_;
v___x_6154_ = 1ULL;
v___x_6155_ = lean_uint64_sub(v_inArenaPtr_6080_, v___x_6154_);
v___x_6156_ = 18446744073709551615ULL;
v___x_6157_ = lean_uint64_sub(v___x_6156_, v___x_6109_);
v___x_6158_ = lean_uint64_dec_le(v___x_6155_, v___x_6157_);
v___y_6132_ = v___x_6158_;
goto v___jp_6131_;
}
else
{
v___y_6132_ = v___y_6151_;
goto v___jp_6131_;
}
}
else
{
v___y_6132_ = v___y_6151_;
goto v___jp_6131_;
}
}
else
{
uint64_t v___x_6159_; uint8_t v___x_6160_;
v___x_6159_ = 4294967295ULL;
v___x_6160_ = lean_uint64_dec_le(v_inArenaPtr_6080_, v___x_6159_);
if (v___x_6160_ == 0)
{
uint8_t v___x_6161_;
v___x_6161_ = 8;
return v___x_6161_;
}
else
{
uint8_t v___x_6162_;
v___x_6162_ = lean_uint64_dec_le(v___x_6109_, v___x_6159_);
if (v___x_6162_ == 0)
{
uint8_t v___x_6163_;
v___x_6163_ = 8;
return v___x_6163_;
}
else
{
uint64_t v___x_6164_; uint64_t v___x_6165_; uint8_t v___x_6166_;
v___x_6164_ = lean_uint64_add(v_inArenaPtr_6080_, v___x_6109_);
v___x_6165_ = 4294967296ULL;
v___x_6166_ = lean_uint64_dec_le(v___x_6164_, v___x_6165_);
v___y_6132_ = v___x_6166_;
goto v___jp_6131_;
}
}
}
}
v___jp_6167_:
{
uint8_t v___x_6169_;
v___x_6169_ = lean_uint64_dec_eq(v_outCap_6082_, v___x_6121_);
if (v___x_6169_ == 0)
{
uint8_t v___x_6170_;
v___x_6170_ = lean_uint64_dec_eq(v_outPtr_6081_, v___x_6121_);
if (v___x_6170_ == 0)
{
v___y_6151_ = v___y_6168_;
goto v___jp_6150_;
}
else
{
uint8_t v___x_6171_;
v___x_6171_ = 7;
return v___x_6171_;
}
}
else
{
v___y_6151_ = v___x_6107_;
goto v___jp_6150_;
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

LEAN_EXPORT uint8_t orb_wire_decode_slice_step(uint64_t v_inPtr_6192_, uint64_t v_inLen_6193_, uint8_t v_is32Bit_6194_, uint32_t v_magic_6195_, uint32_t v_abiVersion_6196_, uint32_t v_schemaId_6197_, uint32_t v_expectedSchemaId_6198_, uint32_t v_totalLen_6199_, uint32_t v_payloadLen_6200_, uint32_t v_arenaOff_6201_, uint32_t v_arenaLen_6202_, uint32_t v_maxBudgetBytes_6203_){
_start:
{
uint32_t v___y_6205_; uint8_t v___y_6206_; uint8_t v___y_6207_; uint8_t v___y_6229_; uint8_t v___y_6255_; uint8_t v___x_6258_; uint8_t v___x_6259_;
v___x_6258_ = 1;
v___x_6259_ = lean_uint8_dec_le(v_is32Bit_6194_, v___x_6258_);
if (v___x_6259_ == 0)
{
uint8_t v___x_6260_;
v___x_6260_ = 6;
v___y_6229_ = v___x_6260_;
goto v___jp_6228_;
}
else
{
uint64_t v___x_6261_; uint8_t v___x_6262_;
v___x_6261_ = 0ULL;
v___x_6262_ = lean_uint64_dec_eq(v_inLen_6193_, v___x_6261_);
if (v___x_6262_ == 0)
{
uint8_t v___x_6279_;
v___x_6279_ = lean_uint64_dec_eq(v_inPtr_6192_, v___x_6261_);
if (v___x_6279_ == 0)
{
goto v___jp_6263_;
}
else
{
uint8_t v___x_6280_;
v___x_6280_ = 7;
v___y_6229_ = v___x_6280_;
goto v___jp_6228_;
}
}
else
{
goto v___jp_6263_;
}
v___jp_6263_:
{
uint8_t v___x_6264_;
v___x_6264_ = lean_uint8_dec_eq(v_is32Bit_6194_, v___x_6258_);
if (v___x_6264_ == 0)
{
uint8_t v___x_6265_;
v___x_6265_ = lean_uint64_dec_eq(v_inPtr_6192_, v___x_6261_);
if (v___x_6265_ == 0)
{
if (v___x_6262_ == 0)
{
uint64_t v___x_6266_; uint64_t v___x_6267_; uint64_t v___x_6268_; uint64_t v___x_6269_; uint8_t v___x_6270_;
v___x_6266_ = 1ULL;
v___x_6267_ = lean_uint64_sub(v_inPtr_6192_, v___x_6266_);
v___x_6268_ = 18446744073709551615ULL;
v___x_6269_ = lean_uint64_sub(v___x_6268_, v_inLen_6193_);
v___x_6270_ = lean_uint64_dec_le(v___x_6267_, v___x_6269_);
v___y_6255_ = v___x_6270_;
goto v___jp_6254_;
}
else
{
v___y_6255_ = v___x_6259_;
goto v___jp_6254_;
}
}
else
{
v___y_6255_ = v___x_6259_;
goto v___jp_6254_;
}
}
else
{
uint64_t v___x_6271_; uint8_t v___x_6272_;
v___x_6271_ = 4294967295ULL;
v___x_6272_ = lean_uint64_dec_le(v_inPtr_6192_, v___x_6271_);
if (v___x_6272_ == 0)
{
uint8_t v___x_6273_;
v___x_6273_ = 8;
v___y_6229_ = v___x_6273_;
goto v___jp_6228_;
}
else
{
uint8_t v___x_6274_;
v___x_6274_ = lean_uint64_dec_le(v_inLen_6193_, v___x_6271_);
if (v___x_6274_ == 0)
{
uint8_t v___x_6275_;
v___x_6275_ = 8;
v___y_6229_ = v___x_6275_;
goto v___jp_6228_;
}
else
{
uint64_t v___x_6276_; uint64_t v___x_6277_; uint8_t v___x_6278_;
v___x_6276_ = lean_uint64_add(v_inPtr_6192_, v_inLen_6193_);
v___x_6277_ = 4294967296ULL;
v___x_6278_ = lean_uint64_dec_le(v___x_6276_, v___x_6277_);
v___y_6255_ = v___x_6278_;
goto v___jp_6254_;
}
}
}
}
}
v___jp_6204_:
{
uint8_t v___x_6208_;
v___x_6208_ = lean_uint8_dec_eq(v___y_6207_, v___y_6206_);
if (v___x_6208_ == 0)
{
return v___y_6207_;
}
else
{
uint64_t v___x_6209_; uint8_t v___x_6210_;
v___x_6209_ = lean_uint32_to_uint64(v_totalLen_6199_);
v___x_6210_ = lean_uint64_dec_eq(v_inLen_6193_, v___x_6209_);
if (v___x_6210_ == 0)
{
uint8_t v___x_6211_;
v___x_6211_ = 3;
return v___x_6211_;
}
else
{
uint32_t v___x_6212_; uint32_t v___x_6213_; uint8_t v___x_6214_;
v___x_6212_ = 7;
v___x_6213_ = lean_uint32_land(v_arenaOff_6201_, v___x_6212_);
v___x_6214_ = lean_uint32_dec_eq(v___x_6213_, v___y_6205_);
if (v___x_6214_ == 0)
{
uint8_t v___x_6215_;
v___x_6215_ = 3;
return v___x_6215_;
}
else
{
uint32_t v___x_6216_; uint8_t v___x_6217_;
v___x_6216_ = 65535;
v___x_6217_ = lean_uint32_dec_le(v_arenaOff_6201_, v___x_6216_);
if (v___x_6217_ == 0)
{
uint8_t v___x_6218_;
v___x_6218_ = 3;
return v___x_6218_;
}
else
{
uint8_t v___x_6219_;
v___x_6219_ = lean_uint32_dec_le(v_arenaLen_6202_, v___x_6216_);
if (v___x_6219_ == 0)
{
uint8_t v___x_6220_;
v___x_6220_ = 3;
return v___x_6220_;
}
else
{
uint32_t v___x_6221_; uint8_t v___x_6222_;
v___x_6221_ = lean_uint32_add(v_arenaOff_6201_, v_arenaLen_6202_);
v___x_6222_ = lean_uint32_dec_eq(v___x_6221_, v_payloadLen_6200_);
if (v___x_6222_ == 0)
{
uint8_t v___x_6223_;
v___x_6223_ = 3;
return v___x_6223_;
}
else
{
uint32_t v___x_6224_; uint32_t v___x_6225_; uint8_t v___x_6226_;
v___x_6224_ = 24;
v___x_6225_ = lean_uint32_add(v___x_6224_, v_payloadLen_6200_);
v___x_6226_ = lean_uint32_dec_eq(v___x_6225_, v_totalLen_6199_);
if (v___x_6226_ == 0)
{
uint8_t v___x_6227_;
v___x_6227_ = 3;
return v___x_6227_;
}
else
{
return v___y_6206_;
}
}
}
}
}
}
}
}
v___jp_6228_:
{
uint8_t v___x_6230_; uint8_t v___x_6231_;
v___x_6230_ = 0;
v___x_6231_ = lean_uint8_dec_eq(v___y_6229_, v___x_6230_);
if (v___x_6231_ == 0)
{
return v___y_6229_;
}
else
{
uint32_t v___x_6232_; uint32_t v___x_6233_; uint8_t v___x_6234_;
v___x_6232_ = 0;
v___x_6233_ = 1330790999;
v___x_6234_ = lean_uint32_dec_eq(v_magic_6195_, v___x_6233_);
if (v___x_6234_ == 0)
{
uint8_t v___x_6235_;
v___x_6235_ = 1;
v___y_6205_ = v___x_6232_;
v___y_6206_ = v___x_6230_;
v___y_6207_ = v___x_6235_;
goto v___jp_6204_;
}
else
{
uint32_t v___x_6236_; uint8_t v___x_6237_;
v___x_6236_ = 1;
v___x_6237_ = lean_uint32_dec_eq(v_abiVersion_6196_, v___x_6236_);
if (v___x_6237_ == 0)
{
uint8_t v___x_6238_;
v___x_6238_ = 1;
v___y_6205_ = v___x_6232_;
v___y_6206_ = v___x_6230_;
v___y_6207_ = v___x_6238_;
goto v___jp_6204_;
}
else
{
uint8_t v___x_6239_;
v___x_6239_ = lean_uint32_dec_eq(v_schemaId_6197_, v_expectedSchemaId_6198_);
if (v___x_6239_ == 0)
{
uint8_t v___x_6240_;
v___x_6240_ = 2;
v___y_6205_ = v___x_6232_;
v___y_6206_ = v___x_6230_;
v___y_6207_ = v___x_6240_;
goto v___jp_6204_;
}
else
{
uint32_t v___x_6241_; uint8_t v___x_6242_;
v___x_6241_ = 24;
v___x_6242_ = lean_uint32_dec_le(v___x_6241_, v_totalLen_6199_);
if (v___x_6242_ == 0)
{
uint8_t v___x_6243_;
v___x_6243_ = 3;
v___y_6205_ = v___x_6232_;
v___y_6206_ = v___x_6230_;
v___y_6207_ = v___x_6243_;
goto v___jp_6204_;
}
else
{
uint8_t v___x_6244_;
v___x_6244_ = lean_uint32_dec_le(v_totalLen_6199_, v_maxBudgetBytes_6203_);
if (v___x_6244_ == 0)
{
uint8_t v___x_6245_;
v___x_6245_ = 4;
v___y_6205_ = v___x_6232_;
v___y_6206_ = v___x_6230_;
v___y_6207_ = v___x_6245_;
goto v___jp_6204_;
}
else
{
uint32_t v___x_6246_; uint8_t v___x_6247_;
v___x_6246_ = lean_uint32_sub(v_totalLen_6199_, v___x_6241_);
v___x_6247_ = lean_uint32_dec_le(v_payloadLen_6200_, v___x_6246_);
if (v___x_6247_ == 0)
{
uint8_t v___x_6248_;
v___x_6248_ = 3;
v___y_6205_ = v___x_6232_;
v___y_6206_ = v___x_6230_;
v___y_6207_ = v___x_6248_;
goto v___jp_6204_;
}
else
{
uint8_t v___x_6249_;
v___x_6249_ = lean_uint32_dec_le(v_arenaOff_6201_, v_payloadLen_6200_);
if (v___x_6249_ == 0)
{
uint8_t v___x_6250_;
v___x_6250_ = 3;
v___y_6205_ = v___x_6232_;
v___y_6206_ = v___x_6230_;
v___y_6207_ = v___x_6250_;
goto v___jp_6204_;
}
else
{
uint32_t v___x_6251_; uint8_t v___x_6252_;
v___x_6251_ = lean_uint32_sub(v_payloadLen_6200_, v_arenaOff_6201_);
v___x_6252_ = lean_uint32_dec_le(v_arenaLen_6202_, v___x_6251_);
if (v___x_6252_ == 0)
{
uint8_t v___x_6253_;
v___x_6253_ = 3;
v___y_6205_ = v___x_6232_;
v___y_6206_ = v___x_6230_;
v___y_6207_ = v___x_6253_;
goto v___jp_6204_;
}
else
{
v___y_6205_ = v___x_6232_;
v___y_6206_ = v___x_6230_;
v___y_6207_ = v___x_6230_;
goto v___jp_6204_;
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
v___jp_6254_:
{
if (v___y_6255_ == 0)
{
uint8_t v___x_6256_;
v___x_6256_ = 8;
v___y_6229_ = v___x_6256_;
goto v___jp_6228_;
}
else
{
uint8_t v___x_6257_;
v___x_6257_ = 0;
v___y_6229_ = v___x_6257_;
goto v___jp_6228_;
}
}
}
}

LEAN_EXPORT uint8_t orb_fleet_endpoint_gate(uint8_t v_meshReachable_6307_, uint8_t v_routerReady_6308_, uint8_t v_modelLoaded_6309_, uint8_t v_breakerOpen_6310_){
_start:
{
uint8_t v___x_6311_; uint8_t v___x_6312_;
v___x_6311_ = 1;
v___x_6312_ = lean_uint8_dec_eq(v_meshReachable_6307_, v___x_6311_);
if (v___x_6312_ == 0)
{
uint8_t v___x_6313_;
v___x_6313_ = 0;
return v___x_6313_;
}
else
{
uint8_t v___x_6314_;
v___x_6314_ = lean_uint8_dec_eq(v_routerReady_6308_, v___x_6311_);
if (v___x_6314_ == 0)
{
uint8_t v___x_6315_;
v___x_6315_ = 0;
return v___x_6315_;
}
else
{
uint8_t v___x_6316_;
v___x_6316_ = lean_uint8_dec_eq(v_modelLoaded_6309_, v___x_6311_);
if (v___x_6316_ == 0)
{
uint8_t v___x_6317_;
v___x_6317_ = 0;
return v___x_6317_;
}
else
{
uint8_t v___x_6318_; uint8_t v___x_6319_;
v___x_6318_ = 0;
v___x_6319_ = lean_uint8_dec_eq(v_breakerOpen_6310_, v___x_6318_);
if (v___x_6319_ == 0)
{
return v___x_6318_;
}
else
{
return v___x_6311_;
}
}
}
}
}
}

LEAN_EXPORT uint64_t orb_prefill_deadline_ms(uint64_t v_promptTokens_6330_, uint64_t v_baseMs_6331_, uint64_t v_perKTokensMs_6332_, uint64_t v_maxPrefillMs_6333_){
_start:
{
uint8_t v___x_6334_;
v___x_6334_ = lean_uint64_dec_le(v_maxPrefillMs_6333_, v_baseMs_6331_);
if (v___x_6334_ == 0)
{
uint64_t v___x_6335_; uint8_t v___x_6336_;
v___x_6335_ = 0ULL;
v___x_6336_ = lean_uint64_dec_eq(v_perKTokensMs_6332_, v___x_6335_);
if (v___x_6336_ == 0)
{
uint64_t v___x_6337_; uint64_t v___x_6338_; uint8_t v___x_6339_;
v___x_6337_ = 10ULL;
v___x_6338_ = lean_uint64_shift_right(v_promptTokens_6330_, v___x_6337_);
v___x_6339_ = lean_uint64_dec_eq(v___x_6338_, v___x_6335_);
if (v___x_6339_ == 0)
{
uint64_t v___x_6340_; uint64_t v___x_6341_; uint8_t v___x_6342_;
v___x_6340_ = lean_uint64_sub(v_maxPrefillMs_6333_, v_baseMs_6331_);
v___x_6341_ = lean_uint64_div(v___x_6340_, v_perKTokensMs_6332_);
v___x_6342_ = lean_uint64_dec_lt(v___x_6341_, v___x_6338_);
if (v___x_6342_ == 0)
{
uint64_t v___x_6343_; uint64_t v___x_6344_;
v___x_6343_ = lean_uint64_mul(v___x_6338_, v_perKTokensMs_6332_);
v___x_6344_ = lean_uint64_add(v_baseMs_6331_, v___x_6343_);
return v___x_6344_;
}
else
{
return v_maxPrefillMs_6333_;
}
}
else
{
return v_baseMs_6331_;
}
}
else
{
return v_baseMs_6331_;
}
}
else
{
return v_baseMs_6331_;
}
}
}

LEAN_EXPORT uint64_t orb_scroll_policy_gap(uint64_t v_height_6519_, uint64_t v_client_6520_, uint64_t v_top_6521_){
_start:
{
uint64_t v___y_6523_; uint64_t v___y_6524_; uint8_t v___y_6525_; uint8_t v___y_6526_; uint64_t v___y_6528_; uint64_t v___y_6529_; uint8_t v___y_6530_; uint8_t v___y_6531_; uint8_t v___y_6532_; uint8_t v___y_6533_; uint64_t v___y_6535_; uint64_t v_diff_6543_; uint64_t v___x_6544_; uint8_t v_aNeg_6545_; uint8_t v_bNeg_6546_; uint8_t v_dNeg_6547_; uint8_t v___y_6549_; uint8_t v___y_6551_;
v_diff_6543_ = lean_uint64_sub(v_height_6519_, v_top_6521_);
v___x_6544_ = 9223372036854775808ULL;
v_aNeg_6545_ = lean_uint64_dec_le(v___x_6544_, v_height_6519_);
v_bNeg_6546_ = lean_uint64_dec_le(v___x_6544_, v_top_6521_);
v_dNeg_6547_ = lean_uint64_dec_le(v___x_6544_, v_diff_6543_);
if (v_aNeg_6545_ == 0)
{
if (v_bNeg_6546_ == 0)
{
v___y_6551_ = v_bNeg_6546_;
goto v___jp_6550_;
}
else
{
if (v_dNeg_6547_ == 0)
{
v___y_6551_ = v_dNeg_6547_;
goto v___jp_6550_;
}
else
{
uint64_t v___x_6552_;
v___x_6552_ = 9223372036854775807ULL;
v___y_6535_ = v___x_6552_;
goto v___jp_6534_;
}
}
}
else
{
uint8_t v___x_6553_;
v___x_6553_ = 0;
v___y_6551_ = v___x_6553_;
goto v___jp_6550_;
}
v___jp_6522_:
{
if (v___y_6525_ == 0)
{
return v___y_6524_;
}
else
{
if (v___y_6526_ == 0)
{
return v___y_6523_;
}
else
{
return v___y_6524_;
}
}
}
v___jp_6527_:
{
if (v___y_6530_ == 0)
{
return v___y_6528_;
}
else
{
if (v___y_6531_ == 0)
{
v___y_6523_ = v___y_6528_;
v___y_6524_ = v___y_6529_;
v___y_6525_ = v___y_6532_;
v___y_6526_ = v___y_6533_;
goto v___jp_6522_;
}
else
{
if (v___y_6533_ == 0)
{
return v___y_6528_;
}
else
{
v___y_6523_ = v___y_6528_;
v___y_6524_ = v___y_6529_;
v___y_6525_ = v___y_6532_;
v___y_6526_ = v___y_6533_;
goto v___jp_6522_;
}
}
}
}
v___jp_6534_:
{
uint64_t v_diff_6536_; uint64_t v___x_6537_; uint8_t v_aNeg_6538_; uint8_t v_bNeg_6539_; uint8_t v_dNeg_6540_;
v_diff_6536_ = lean_uint64_sub(v___y_6535_, v_client_6520_);
v___x_6537_ = 9223372036854775808ULL;
v_aNeg_6538_ = lean_uint64_dec_le(v___x_6537_, v___y_6535_);
v_bNeg_6539_ = lean_uint64_dec_le(v___x_6537_, v_client_6520_);
v_dNeg_6540_ = lean_uint64_dec_le(v___x_6537_, v_diff_6536_);
if (v_aNeg_6538_ == 0)
{
if (v_bNeg_6539_ == 0)
{
v___y_6528_ = v_diff_6536_;
v___y_6529_ = v___x_6537_;
v___y_6530_ = v_aNeg_6538_;
v___y_6531_ = v_bNeg_6539_;
v___y_6532_ = v_dNeg_6540_;
v___y_6533_ = v_bNeg_6539_;
goto v___jp_6527_;
}
else
{
if (v_dNeg_6540_ == 0)
{
v___y_6528_ = v_diff_6536_;
v___y_6529_ = v___x_6537_;
v___y_6530_ = v_aNeg_6538_;
v___y_6531_ = v_bNeg_6539_;
v___y_6532_ = v_dNeg_6540_;
v___y_6533_ = v_dNeg_6540_;
goto v___jp_6527_;
}
else
{
uint64_t v___x_6541_;
v___x_6541_ = 9223372036854775807ULL;
return v___x_6541_;
}
}
}
else
{
uint8_t v___x_6542_;
v___x_6542_ = 0;
v___y_6528_ = v_diff_6536_;
v___y_6529_ = v___x_6537_;
v___y_6530_ = v_aNeg_6538_;
v___y_6531_ = v_bNeg_6539_;
v___y_6532_ = v_dNeg_6540_;
v___y_6533_ = v___x_6542_;
goto v___jp_6527_;
}
}
v___jp_6548_:
{
if (v_dNeg_6547_ == 0)
{
v___y_6535_ = v___x_6544_;
goto v___jp_6534_;
}
else
{
if (v___y_6549_ == 0)
{
v___y_6535_ = v_diff_6543_;
goto v___jp_6534_;
}
else
{
v___y_6535_ = v___x_6544_;
goto v___jp_6534_;
}
}
}
v___jp_6550_:
{
if (v_aNeg_6545_ == 0)
{
v___y_6535_ = v_diff_6543_;
goto v___jp_6534_;
}
else
{
if (v_bNeg_6546_ == 0)
{
v___y_6549_ = v___y_6551_;
goto v___jp_6548_;
}
else
{
if (v___y_6551_ == 0)
{
v___y_6535_ = v_diff_6543_;
goto v___jp_6534_;
}
else
{
v___y_6549_ = v___y_6551_;
goto v___jp_6548_;
}
}
}
}
}
}

LEAN_EXPORT uint64_t orb_scroll_policy_correct(uint64_t v_height_6562_, uint64_t v_client_6563_, uint64_t v_top_6564_, uint64_t v_anchorDoc_6565_, uint64_t v_y0_6566_){
_start:
{
uint64_t v___y_6568_; uint64_t v___y_6569_; uint64_t v___y_6574_; uint64_t v___y_6575_; uint64_t v___y_6576_; uint64_t v___y_6582_; uint64_t v___y_6583_; uint64_t v___y_6584_; uint64_t v___y_6589_; uint64_t v___y_6590_; uint64_t v___y_6591_; uint8_t v___y_6592_; uint8_t v___y_6593_; uint64_t v___y_6594_; uint64_t v___y_6596_; uint64_t v___y_6597_; uint64_t v___y_6598_; uint8_t v___y_6599_; uint8_t v___y_6600_; uint8_t v___y_6601_; uint64_t v___y_6602_; uint8_t v___y_6603_; uint64_t v___y_6605_; uint8_t v___y_6615_; uint8_t v___y_6616_; uint8_t v___y_6617_; uint64_t v___y_6618_; uint64_t v___y_6619_; uint8_t v___y_6620_; uint64_t v___y_6622_; uint64_t v___y_6631_; uint64_t v___y_6632_; uint8_t v___y_6633_; uint8_t v___y_6634_; uint64_t v___y_6636_; uint8_t v___y_6637_; uint64_t v___y_6638_; uint8_t v___y_6639_; uint8_t v___y_6640_; uint8_t v___y_6641_; uint64_t v___y_6643_; uint64_t v_diff_6651_; uint64_t v___x_6652_; uint8_t v_aNeg_6653_; uint8_t v_bNeg_6654_; uint8_t v_dNeg_6655_; uint8_t v___y_6657_; uint8_t v___y_6659_;
v_diff_6651_ = lean_uint64_sub(v_anchorDoc_6565_, v_top_6564_);
v___x_6652_ = 9223372036854775808ULL;
v_aNeg_6653_ = lean_uint64_dec_le(v___x_6652_, v_anchorDoc_6565_);
v_bNeg_6654_ = lean_uint64_dec_le(v___x_6652_, v_top_6564_);
v_dNeg_6655_ = lean_uint64_dec_le(v___x_6652_, v_diff_6651_);
if (v_aNeg_6653_ == 0)
{
if (v_bNeg_6654_ == 0)
{
v___y_6659_ = v_bNeg_6654_;
goto v___jp_6658_;
}
else
{
if (v_dNeg_6655_ == 0)
{
v___y_6659_ = v_dNeg_6655_;
goto v___jp_6658_;
}
else
{
uint64_t v___x_6660_;
v___x_6660_ = 9223372036854775807ULL;
v___y_6643_ = v___x_6660_;
goto v___jp_6642_;
}
}
}
else
{
uint8_t v___x_6661_;
v___x_6661_ = 0;
v___y_6659_ = v___x_6661_;
goto v___jp_6658_;
}
v___jp_6567_:
{
uint64_t v___x_6570_; uint64_t v___x_6571_; uint8_t v___x_6572_;
v___x_6570_ = 9223372036854775808ULL;
v___x_6571_ = lean_uint64_add(v___y_6569_, v___x_6570_);
v___x_6572_ = lean_uint64_dec_lt(v___x_6570_, v___x_6571_);
if (v___x_6572_ == 0)
{
return v___y_6568_;
}
else
{
return v___y_6569_;
}
}
v___jp_6573_:
{
uint64_t v___x_6577_; uint64_t v___x_6578_; uint64_t v___x_6579_; uint8_t v___x_6580_;
v___x_6577_ = 9223372036854775808ULL;
v___x_6578_ = lean_uint64_add(v___y_6574_, v___x_6577_);
v___x_6579_ = lean_uint64_add(v___y_6576_, v___x_6577_);
v___x_6580_ = lean_uint64_dec_le(v___x_6578_, v___x_6579_);
if (v___x_6580_ == 0)
{
v___y_6568_ = v___y_6575_;
v___y_6569_ = v___y_6576_;
goto v___jp_6567_;
}
else
{
v___y_6568_ = v___y_6575_;
v___y_6569_ = v___y_6574_;
goto v___jp_6567_;
}
}
v___jp_6581_:
{
uint64_t v___x_6585_; uint64_t v___x_6586_; uint8_t v___x_6587_;
v___x_6585_ = 9223372036854775808ULL;
v___x_6586_ = lean_uint64_add(v___y_6584_, v___x_6585_);
v___x_6587_ = lean_uint64_dec_lt(v___x_6585_, v___x_6586_);
if (v___x_6587_ == 0)
{
v___y_6574_ = v___y_6582_;
v___y_6575_ = v___y_6583_;
v___y_6576_ = v___y_6583_;
goto v___jp_6573_;
}
else
{
v___y_6574_ = v___y_6582_;
v___y_6575_ = v___y_6583_;
v___y_6576_ = v___y_6584_;
goto v___jp_6573_;
}
}
v___jp_6588_:
{
if (v___y_6593_ == 0)
{
v___y_6582_ = v___y_6589_;
v___y_6583_ = v___y_6594_;
v___y_6584_ = v___y_6590_;
goto v___jp_6581_;
}
else
{
if (v___y_6592_ == 0)
{
v___y_6582_ = v___y_6589_;
v___y_6583_ = v___y_6594_;
v___y_6584_ = v___y_6591_;
goto v___jp_6581_;
}
else
{
v___y_6582_ = v___y_6589_;
v___y_6583_ = v___y_6594_;
v___y_6584_ = v___y_6590_;
goto v___jp_6581_;
}
}
}
v___jp_6595_:
{
if (v___y_6599_ == 0)
{
v___y_6582_ = v___y_6596_;
v___y_6583_ = v___y_6602_;
v___y_6584_ = v___y_6598_;
goto v___jp_6581_;
}
else
{
if (v___y_6601_ == 0)
{
v___y_6589_ = v___y_6596_;
v___y_6590_ = v___y_6597_;
v___y_6591_ = v___y_6598_;
v___y_6592_ = v___y_6603_;
v___y_6593_ = v___y_6600_;
v___y_6594_ = v___y_6602_;
goto v___jp_6588_;
}
else
{
if (v___y_6603_ == 0)
{
v___y_6582_ = v___y_6596_;
v___y_6583_ = v___y_6602_;
v___y_6584_ = v___y_6598_;
goto v___jp_6581_;
}
else
{
v___y_6589_ = v___y_6596_;
v___y_6590_ = v___y_6597_;
v___y_6591_ = v___y_6598_;
v___y_6592_ = v___y_6603_;
v___y_6593_ = v___y_6600_;
v___y_6594_ = v___y_6602_;
goto v___jp_6588_;
}
}
}
}
v___jp_6604_:
{
uint64_t v___x_6606_; uint64_t v_diff_6607_; uint64_t v___x_6608_; uint8_t v_aNeg_6609_; uint8_t v_bNeg_6610_; uint8_t v_dNeg_6611_;
v___x_6606_ = 0ULL;
v_diff_6607_ = lean_uint64_sub(v_height_6562_, v_client_6563_);
v___x_6608_ = 9223372036854775808ULL;
v_aNeg_6609_ = lean_uint64_dec_le(v___x_6608_, v_height_6562_);
v_bNeg_6610_ = lean_uint64_dec_le(v___x_6608_, v_client_6563_);
v_dNeg_6611_ = lean_uint64_dec_le(v___x_6608_, v_diff_6607_);
if (v_aNeg_6609_ == 0)
{
if (v_bNeg_6610_ == 0)
{
v___y_6596_ = v___y_6605_;
v___y_6597_ = v___x_6608_;
v___y_6598_ = v_diff_6607_;
v___y_6599_ = v_aNeg_6609_;
v___y_6600_ = v_dNeg_6611_;
v___y_6601_ = v_bNeg_6610_;
v___y_6602_ = v___x_6606_;
v___y_6603_ = v_bNeg_6610_;
goto v___jp_6595_;
}
else
{
if (v_dNeg_6611_ == 0)
{
v___y_6596_ = v___y_6605_;
v___y_6597_ = v___x_6608_;
v___y_6598_ = v_diff_6607_;
v___y_6599_ = v_aNeg_6609_;
v___y_6600_ = v_dNeg_6611_;
v___y_6601_ = v_bNeg_6610_;
v___y_6602_ = v___x_6606_;
v___y_6603_ = v_dNeg_6611_;
goto v___jp_6595_;
}
else
{
uint64_t v___x_6612_;
v___x_6612_ = 9223372036854775807ULL;
v___y_6582_ = v___y_6605_;
v___y_6583_ = v___x_6606_;
v___y_6584_ = v___x_6612_;
goto v___jp_6581_;
}
}
}
else
{
uint8_t v___x_6613_;
v___x_6613_ = 0;
v___y_6596_ = v___y_6605_;
v___y_6597_ = v___x_6608_;
v___y_6598_ = v_diff_6607_;
v___y_6599_ = v_aNeg_6609_;
v___y_6600_ = v_dNeg_6611_;
v___y_6601_ = v_bNeg_6610_;
v___y_6602_ = v___x_6606_;
v___y_6603_ = v___x_6613_;
goto v___jp_6595_;
}
}
v___jp_6614_:
{
if (v___y_6615_ == 0)
{
v___y_6605_ = v___y_6619_;
goto v___jp_6604_;
}
else
{
if (v___y_6616_ == 0)
{
v___y_6605_ = v___y_6619_;
goto v___jp_6604_;
}
else
{
if (v___y_6617_ == 0)
{
v___y_6605_ = v___y_6618_;
goto v___jp_6604_;
}
else
{
if (v___y_6620_ == 0)
{
v___y_6605_ = v___y_6619_;
goto v___jp_6604_;
}
else
{
v___y_6605_ = v___y_6618_;
goto v___jp_6604_;
}
}
}
}
}
v___jp_6621_:
{
uint64_t v_sum_6623_; uint64_t v___x_6624_; uint8_t v_aNeg_6625_; uint8_t v_bNeg_6626_; uint8_t v_sNeg_6627_;
v_sum_6623_ = lean_uint64_add(v_top_6564_, v___y_6622_);
v___x_6624_ = 9223372036854775808ULL;
v_aNeg_6625_ = lean_uint64_dec_le(v___x_6624_, v_top_6564_);
v_bNeg_6626_ = lean_uint64_dec_le(v___x_6624_, v___y_6622_);
v_sNeg_6627_ = lean_uint64_dec_le(v___x_6624_, v_sum_6623_);
if (v_aNeg_6625_ == 0)
{
if (v_bNeg_6626_ == 0)
{
if (v_sNeg_6627_ == 0)
{
v___y_6615_ = v_aNeg_6625_;
v___y_6616_ = v_bNeg_6626_;
v___y_6617_ = v_sNeg_6627_;
v___y_6618_ = v___x_6624_;
v___y_6619_ = v_sum_6623_;
v___y_6620_ = v_sNeg_6627_;
goto v___jp_6614_;
}
else
{
uint64_t v___x_6628_;
v___x_6628_ = 9223372036854775807ULL;
v___y_6605_ = v___x_6628_;
goto v___jp_6604_;
}
}
else
{
v___y_6615_ = v_aNeg_6625_;
v___y_6616_ = v_bNeg_6626_;
v___y_6617_ = v_sNeg_6627_;
v___y_6618_ = v___x_6624_;
v___y_6619_ = v_sum_6623_;
v___y_6620_ = v_aNeg_6625_;
goto v___jp_6614_;
}
}
else
{
uint8_t v___x_6629_;
v___x_6629_ = 0;
v___y_6615_ = v_aNeg_6625_;
v___y_6616_ = v_bNeg_6626_;
v___y_6617_ = v_sNeg_6627_;
v___y_6618_ = v___x_6624_;
v___y_6619_ = v_sum_6623_;
v___y_6620_ = v___x_6629_;
goto v___jp_6614_;
}
}
v___jp_6630_:
{
if (v___y_6634_ == 0)
{
v___y_6622_ = v___y_6631_;
goto v___jp_6621_;
}
else
{
if (v___y_6633_ == 0)
{
v___y_6622_ = v___y_6632_;
goto v___jp_6621_;
}
else
{
v___y_6622_ = v___y_6631_;
goto v___jp_6621_;
}
}
}
v___jp_6635_:
{
if (v___y_6639_ == 0)
{
v___y_6622_ = v___y_6638_;
goto v___jp_6621_;
}
else
{
if (v___y_6637_ == 0)
{
v___y_6631_ = v___y_6636_;
v___y_6632_ = v___y_6638_;
v___y_6633_ = v___y_6641_;
v___y_6634_ = v___y_6640_;
goto v___jp_6630_;
}
else
{
if (v___y_6641_ == 0)
{
v___y_6622_ = v___y_6638_;
goto v___jp_6621_;
}
else
{
v___y_6631_ = v___y_6636_;
v___y_6632_ = v___y_6638_;
v___y_6633_ = v___y_6641_;
v___y_6634_ = v___y_6640_;
goto v___jp_6630_;
}
}
}
}
v___jp_6642_:
{
uint64_t v_diff_6644_; uint64_t v___x_6645_; uint8_t v_aNeg_6646_; uint8_t v_bNeg_6647_; uint8_t v_dNeg_6648_;
v_diff_6644_ = lean_uint64_sub(v___y_6643_, v_y0_6566_);
v___x_6645_ = 9223372036854775808ULL;
v_aNeg_6646_ = lean_uint64_dec_le(v___x_6645_, v___y_6643_);
v_bNeg_6647_ = lean_uint64_dec_le(v___x_6645_, v_y0_6566_);
v_dNeg_6648_ = lean_uint64_dec_le(v___x_6645_, v_diff_6644_);
if (v_aNeg_6646_ == 0)
{
if (v_bNeg_6647_ == 0)
{
v___y_6636_ = v___x_6645_;
v___y_6637_ = v_bNeg_6647_;
v___y_6638_ = v_diff_6644_;
v___y_6639_ = v_aNeg_6646_;
v___y_6640_ = v_dNeg_6648_;
v___y_6641_ = v_bNeg_6647_;
goto v___jp_6635_;
}
else
{
if (v_dNeg_6648_ == 0)
{
v___y_6636_ = v___x_6645_;
v___y_6637_ = v_bNeg_6647_;
v___y_6638_ = v_diff_6644_;
v___y_6639_ = v_aNeg_6646_;
v___y_6640_ = v_dNeg_6648_;
v___y_6641_ = v_dNeg_6648_;
goto v___jp_6635_;
}
else
{
uint64_t v___x_6649_;
v___x_6649_ = 9223372036854775807ULL;
v___y_6622_ = v___x_6649_;
goto v___jp_6621_;
}
}
}
else
{
uint8_t v___x_6650_;
v___x_6650_ = 0;
v___y_6636_ = v___x_6645_;
v___y_6637_ = v_bNeg_6647_;
v___y_6638_ = v_diff_6644_;
v___y_6639_ = v_aNeg_6646_;
v___y_6640_ = v_dNeg_6648_;
v___y_6641_ = v___x_6650_;
goto v___jp_6635_;
}
}
v___jp_6656_:
{
if (v_dNeg_6655_ == 0)
{
v___y_6643_ = v___x_6652_;
goto v___jp_6642_;
}
else
{
if (v___y_6657_ == 0)
{
v___y_6643_ = v_diff_6651_;
goto v___jp_6642_;
}
else
{
v___y_6643_ = v___x_6652_;
goto v___jp_6642_;
}
}
}
v___jp_6658_:
{
if (v_aNeg_6653_ == 0)
{
v___y_6643_ = v_diff_6651_;
goto v___jp_6642_;
}
else
{
if (v_bNeg_6654_ == 0)
{
v___y_6657_ = v___y_6659_;
goto v___jp_6656_;
}
else
{
if (v___y_6659_ == 0)
{
v___y_6643_ = v_diff_6651_;
goto v___jp_6642_;
}
else
{
v___y_6657_ = v___y_6659_;
goto v___jp_6656_;
}
}
}
}
}
}

LEAN_EXPORT uint64_t orb_scroll_policy_step(uint8_t v_opKind_7093_, uint8_t v_pinned_7094_, uint8_t v_intent_7095_, uint8_t v_resized_7096_, uint64_t v_curTop_7097_, uint64_t v_height_7098_, uint64_t v_client_7099_, uint64_t v_arg_7100_){
_start:
{
uint64_t v___y_7102_; uint32_t v___y_7103_; uint8_t v___y_7113_; uint64_t v___y_7114_; uint8_t v___y_7118_; uint64_t v___y_7119_; uint64_t v___y_7120_; uint8_t v___y_7125_; uint64_t v___y_7126_; uint64_t v___y_7127_; uint8_t v___y_7133_; uint64_t v___y_7134_; uint64_t v___y_7135_; uint8_t v___y_7140_; uint8_t v___y_7141_; uint8_t v___y_7142_; uint64_t v___y_7143_; uint64_t v___y_7144_; uint64_t v___y_7145_; uint8_t v___y_7147_; uint8_t v___y_7148_; uint8_t v___y_7149_; uint64_t v___y_7150_; uint64_t v___y_7151_; uint64_t v___y_7152_; uint8_t v___y_7153_; uint8_t v___y_7154_; uint8_t v___y_7156_; uint8_t v___y_7157_; uint8_t v___y_7166_; uint64_t v___y_7167_; uint64_t v___y_7168_; uint8_t v___y_7173_; uint8_t v___y_7174_; uint64_t v___y_7175_; uint64_t v___y_7176_; uint64_t v___y_7177_; uint8_t v___y_7178_; uint8_t v___y_7180_; uint8_t v___y_7181_; uint8_t v___y_7182_; uint64_t v___y_7183_; uint64_t v___y_7184_; uint64_t v___y_7185_; uint8_t v___y_7186_; uint8_t v___y_7187_; uint8_t v___y_7189_; uint64_t v___y_7190_; uint64_t v___y_7191_; uint8_t v___y_7196_; uint64_t v___y_7197_; uint64_t v___y_7198_; uint64_t v___y_7199_; uint8_t v___y_7205_; uint64_t v___y_7206_; uint64_t v___y_7207_; uint64_t v___y_7208_; uint8_t v___y_7213_; uint64_t v___y_7214_; uint64_t v___y_7215_; uint64_t v___y_7216_; uint8_t v___y_7217_; uint64_t v___y_7218_; uint8_t v___y_7219_; uint8_t v___y_7221_; uint8_t v___y_7222_; uint64_t v___y_7223_; uint64_t v___y_7224_; uint8_t v___y_7225_; uint64_t v___y_7226_; uint8_t v___y_7227_; uint64_t v___y_7228_; uint8_t v___y_7229_; uint8_t v___y_7231_; uint8_t v___y_7232_; uint64_t v___y_7233_; uint8_t v___y_7242_; uint64_t v___y_7243_; uint8_t v___y_7244_; uint8_t v___y_7245_; uint8_t v___y_7246_; uint8_t v___y_7247_; uint64_t v___y_7248_; uint8_t v___y_7249_; uint8_t v___y_7251_; uint64_t v___y_7252_; uint64_t v___y_7253_; uint64_t v___y_7258_; uint64_t v___y_7259_; uint8_t v___y_7260_; uint64_t v___y_7261_; uint8_t v___y_7262_; uint8_t v___y_7263_; uint64_t v___y_7265_; uint8_t v___y_7266_; uint8_t v___y_7267_; uint64_t v___y_7268_; uint64_t v___y_7269_; uint8_t v___y_7270_; uint8_t v___y_7271_; uint8_t v___y_7272_; uint8_t v___y_7274_; uint8_t v___y_7275_; uint8_t v___y_7305_; uint8_t v___y_7306_; uint8_t v___y_7307_; uint64_t v___y_7308_; uint8_t v___y_7314_; uint8_t v___y_7315_; uint8_t v___y_7316_; uint64_t v___y_7317_; uint8_t v___y_7323_; uint64_t v___y_7324_; uint64_t v___y_7325_; uint8_t v___y_7326_; uint8_t v___y_7327_; uint8_t v___y_7328_; uint8_t v___y_7329_; uint8_t v___y_7331_; uint64_t v___y_7332_; uint8_t v___y_7333_; uint64_t v___y_7334_; uint8_t v___y_7335_; uint8_t v___y_7336_; uint8_t v___y_7337_; uint8_t v___y_7338_; uint8_t v___y_7339_; uint8_t v___y_7341_; uint8_t v___y_7342_; uint8_t v___y_7343_; uint64_t v___y_7344_; uint8_t v___y_7352_; uint64_t v___y_7353_; uint64_t v___y_7354_; uint8_t v___y_7355_; uint8_t v___y_7356_; uint8_t v___y_7357_; uint8_t v___y_7358_; uint8_t v___y_7360_; uint64_t v___y_7361_; uint8_t v___y_7362_; uint8_t v___y_7363_; uint64_t v___y_7364_; uint8_t v___y_7365_; uint8_t v___y_7366_; uint8_t v___y_7367_; uint8_t v___y_7368_; uint64_t v___y_7370_; uint8_t v___y_7371_; uint8_t v___y_7372_; uint8_t v___y_7373_; uint8_t v___y_7374_; uint64_t v___y_7385_; uint8_t v___y_7386_; uint8_t v___y_7387_; uint8_t v___y_7388_; uint8_t v___y_7389_; uint8_t v___y_7391_; uint8_t v___y_7392_; uint8_t v___y_7393_; uint8_t v___y_7394_; uint8_t v___y_7395_; uint64_t v___y_7396_; uint64_t v___y_7399_; uint8_t v___y_7400_; uint8_t v___y_7401_; uint8_t v___y_7402_; uint8_t v___y_7403_; uint8_t v___y_7404_; uint64_t v___y_7405_; uint64_t v___y_7410_; uint8_t v___y_7411_; uint8_t v___y_7412_; uint8_t v___y_7413_; uint8_t v___y_7414_; uint8_t v___y_7415_; uint64_t v___y_7416_; uint64_t v___y_7422_; uint8_t v___y_7423_; uint8_t v___y_7424_; uint8_t v___y_7425_; uint8_t v___y_7426_; uint8_t v___y_7427_; uint64_t v___y_7428_; uint64_t v___y_7433_; uint8_t v___y_7434_; uint8_t v___y_7435_; uint8_t v___y_7436_; uint64_t v___y_7437_; uint8_t v___y_7438_; uint8_t v___y_7439_; uint8_t v___y_7440_; uint8_t v___y_7441_; uint64_t v___y_7442_; uint8_t v___y_7444_; uint64_t v___y_7445_; uint8_t v___y_7446_; uint8_t v___y_7447_; uint8_t v___y_7448_; uint64_t v___y_7449_; uint8_t v___y_7450_; uint8_t v___y_7451_; uint8_t v___y_7452_; uint64_t v___y_7453_; uint8_t v___y_7454_; uint8_t v___y_7455_; uint8_t v___y_7457_; uint8_t v___y_7458_; uint8_t v___y_7459_; uint8_t v___y_7460_; uint8_t v___y_7461_; uint8_t v___y_7472_; uint8_t v___y_7473_; uint64_t v___y_7474_; uint8_t v___y_7475_; uint64_t v___y_7476_; uint8_t v___y_7477_; uint8_t v___y_7478_; uint8_t v___y_7480_; uint64_t v___y_7481_; uint8_t v___y_7482_; uint8_t v___y_7483_; uint64_t v___y_7484_; uint8_t v___y_7485_; uint8_t v___y_7486_; uint8_t v___y_7487_; uint8_t v___y_7488_; uint8_t v___y_7490_; uint64_t v___y_7491_; uint8_t v___y_7492_; uint8_t v___y_7493_; uint8_t v___y_7494_; uint64_t v___y_7495_; uint64_t v___y_7502_; uint8_t v___y_7503_; uint8_t v___y_7504_; uint64_t v___y_7505_; uint8_t v___y_7506_; uint8_t v___y_7507_; uint8_t v___y_7508_; uint8_t v___y_7509_; uint64_t v___y_7511_; uint64_t v___y_7512_; uint8_t v___y_7513_; uint8_t v___y_7514_; uint8_t v___y_7515_; uint8_t v___y_7516_; uint8_t v___y_7517_; uint8_t v___y_7518_; uint8_t v___y_7519_; uint8_t v___y_7520_; uint8_t v___y_7522_; uint8_t v___y_7523_; uint8_t v___y_7524_; uint8_t v___y_7525_; uint64_t v___y_7526_; uint8_t v___y_7537_; uint64_t v___y_7538_; uint8_t v___y_7539_; uint8_t v___y_7540_; uint8_t v___y_7541_; uint64_t v___y_7542_; uint64_t v___y_7547_; uint8_t v___y_7548_; uint8_t v___y_7549_; uint8_t v___y_7550_; uint8_t v___y_7551_; uint64_t v___y_7552_; uint8_t v___y_7558_; uint64_t v___y_7559_; uint8_t v___y_7560_; uint8_t v___y_7561_; uint8_t v___y_7562_; uint64_t v___y_7563_; uint64_t v___y_7568_; uint64_t v___y_7569_; uint64_t v___y_7570_; uint8_t v___y_7571_; uint8_t v___y_7572_; uint8_t v___y_7573_; uint8_t v___y_7574_; uint8_t v___y_7575_; uint8_t v___y_7576_; uint8_t v___y_7578_; uint64_t v___y_7579_; uint8_t v___y_7580_; uint64_t v___y_7581_; uint64_t v___y_7582_; uint8_t v___y_7583_; uint8_t v___y_7584_; uint8_t v___y_7585_; uint8_t v___y_7586_; uint8_t v___y_7587_; uint8_t v___y_7588_; uint8_t v___y_7590_; uint8_t v___y_7591_; uint8_t v___y_7592_; uint8_t v___y_7593_; uint32_t v___y_7602_; uint32_t v___y_7603_; uint8_t v___y_7604_; uint32_t v___y_7631_; uint32_t v___y_7632_; uint32_t v___y_7638_; uint32_t v___y_7639_; uint32_t v___y_7645_; uint32_t v___y_7646_; uint32_t v___y_7652_; uint32_t v___y_7653_; uint32_t v___y_7659_; uint64_t v___y_7660_; uint32_t v___y_7666_; uint8_t v___x_7671_; uint8_t v___x_7672_;
v___x_7671_ = 1;
v___x_7672_ = lean_uint8_dec_eq(v_pinned_7094_, v___x_7671_);
if (v___x_7672_ == 0)
{
uint32_t v___x_7673_;
v___x_7673_ = 0;
v___y_7666_ = v___x_7673_;
goto v___jp_7665_;
}
else
{
uint32_t v___x_7674_;
v___x_7674_ = 512;
v___y_7666_ = v___x_7674_;
goto v___jp_7665_;
}
v___jp_7101_:
{
uint32_t v___x_7104_; uint32_t v_lo32_7105_; uint32_t v_hi32_7106_; uint64_t v___x_7107_; uint64_t v___x_7108_; uint64_t v___x_7109_; uint64_t v___x_7110_; uint64_t v___x_7111_;
v___x_7104_ = 257;
v_lo32_7105_ = lean_uint32_lor(v___x_7104_, v___y_7103_);
v_hi32_7106_ = lean_uint64_to_uint32(v___y_7102_);
v___x_7107_ = lean_uint32_to_uint64(v_lo32_7105_);
v___x_7108_ = lean_uint32_to_uint64(v_hi32_7106_);
v___x_7109_ = 32ULL;
v___x_7110_ = lean_uint64_shift_left(v___x_7108_, v___x_7109_);
v___x_7111_ = lean_uint64_lor(v___x_7107_, v___x_7110_);
return v___x_7111_;
}
v___jp_7112_:
{
if (v___y_7113_ == 0)
{
uint32_t v___x_7115_;
v___x_7115_ = 0;
v___y_7102_ = v___y_7114_;
v___y_7103_ = v___x_7115_;
goto v___jp_7101_;
}
else
{
uint32_t v___x_7116_;
v___x_7116_ = 512;
v___y_7102_ = v___y_7114_;
v___y_7103_ = v___x_7116_;
goto v___jp_7101_;
}
}
v___jp_7117_:
{
uint64_t v___x_7121_; uint64_t v___x_7122_; uint8_t v___x_7123_;
v___x_7121_ = 9223372036854775808ULL;
v___x_7122_ = lean_uint64_add(v___y_7120_, v___x_7121_);
v___x_7123_ = lean_uint64_dec_lt(v___x_7121_, v___x_7122_);
if (v___x_7123_ == 0)
{
v___y_7113_ = v___y_7118_;
v___y_7114_ = v___y_7119_;
goto v___jp_7112_;
}
else
{
v___y_7113_ = v___y_7118_;
v___y_7114_ = v___y_7120_;
goto v___jp_7112_;
}
}
v___jp_7124_:
{
uint64_t v___x_7128_; uint64_t v___x_7129_; uint64_t v___x_7130_; uint8_t v___x_7131_;
v___x_7128_ = 9223372036854775808ULL;
v___x_7129_ = lean_uint64_add(v_arg_7100_, v___x_7128_);
v___x_7130_ = lean_uint64_add(v___y_7127_, v___x_7128_);
v___x_7131_ = lean_uint64_dec_le(v___x_7129_, v___x_7130_);
if (v___x_7131_ == 0)
{
v___y_7118_ = v___y_7125_;
v___y_7119_ = v___y_7126_;
v___y_7120_ = v___y_7127_;
goto v___jp_7117_;
}
else
{
v___y_7118_ = v___y_7125_;
v___y_7119_ = v___y_7126_;
v___y_7120_ = v_arg_7100_;
goto v___jp_7117_;
}
}
v___jp_7132_:
{
uint64_t v___x_7136_; uint64_t v___x_7137_; uint8_t v___x_7138_;
v___x_7136_ = 9223372036854775808ULL;
v___x_7137_ = lean_uint64_add(v___y_7135_, v___x_7136_);
v___x_7138_ = lean_uint64_dec_lt(v___x_7136_, v___x_7137_);
if (v___x_7138_ == 0)
{
v___y_7125_ = v___y_7133_;
v___y_7126_ = v___y_7134_;
v___y_7127_ = v___y_7134_;
goto v___jp_7124_;
}
else
{
v___y_7125_ = v___y_7133_;
v___y_7126_ = v___y_7134_;
v___y_7127_ = v___y_7135_;
goto v___jp_7124_;
}
}
v___jp_7139_:
{
if (v___y_7142_ == 0)
{
v___y_7133_ = v___y_7141_;
v___y_7134_ = v___y_7145_;
v___y_7135_ = v___y_7143_;
goto v___jp_7132_;
}
else
{
if (v___y_7140_ == 0)
{
v___y_7133_ = v___y_7141_;
v___y_7134_ = v___y_7145_;
v___y_7135_ = v___y_7144_;
goto v___jp_7132_;
}
else
{
v___y_7133_ = v___y_7141_;
v___y_7134_ = v___y_7145_;
v___y_7135_ = v___y_7143_;
goto v___jp_7132_;
}
}
}
v___jp_7146_:
{
if (v___y_7147_ == 0)
{
v___y_7133_ = v___y_7148_;
v___y_7134_ = v___y_7151_;
v___y_7135_ = v___y_7152_;
goto v___jp_7132_;
}
else
{
if (v___y_7153_ == 0)
{
v___y_7140_ = v___y_7154_;
v___y_7141_ = v___y_7148_;
v___y_7142_ = v___y_7149_;
v___y_7143_ = v___y_7150_;
v___y_7144_ = v___y_7152_;
v___y_7145_ = v___y_7151_;
goto v___jp_7139_;
}
else
{
if (v___y_7154_ == 0)
{
v___y_7133_ = v___y_7148_;
v___y_7134_ = v___y_7151_;
v___y_7135_ = v___y_7152_;
goto v___jp_7132_;
}
else
{
v___y_7140_ = v___y_7154_;
v___y_7141_ = v___y_7148_;
v___y_7142_ = v___y_7149_;
v___y_7143_ = v___y_7150_;
v___y_7144_ = v___y_7152_;
v___y_7145_ = v___y_7151_;
goto v___jp_7139_;
}
}
}
}
v___jp_7155_:
{
uint64_t v___x_7158_; uint64_t v_diff_7159_; uint64_t v___x_7160_; uint8_t v_aNeg_7161_; uint8_t v_bNeg_7162_; uint8_t v_dNeg_7163_;
v___x_7158_ = 0ULL;
v_diff_7159_ = lean_uint64_sub(v_height_7098_, v_client_7099_);
v___x_7160_ = 9223372036854775808ULL;
v_aNeg_7161_ = lean_uint64_dec_le(v___x_7160_, v_height_7098_);
v_bNeg_7162_ = lean_uint64_dec_le(v___x_7160_, v_client_7099_);
v_dNeg_7163_ = lean_uint64_dec_le(v___x_7160_, v_diff_7159_);
if (v_aNeg_7161_ == 0)
{
if (v_bNeg_7162_ == 0)
{
v___y_7147_ = v_aNeg_7161_;
v___y_7148_ = v___y_7156_;
v___y_7149_ = v_dNeg_7163_;
v___y_7150_ = v___x_7160_;
v___y_7151_ = v___x_7158_;
v___y_7152_ = v_diff_7159_;
v___y_7153_ = v_bNeg_7162_;
v___y_7154_ = v_bNeg_7162_;
goto v___jp_7146_;
}
else
{
if (v_dNeg_7163_ == 0)
{
v___y_7147_ = v_aNeg_7161_;
v___y_7148_ = v___y_7156_;
v___y_7149_ = v_dNeg_7163_;
v___y_7150_ = v___x_7160_;
v___y_7151_ = v___x_7158_;
v___y_7152_ = v_diff_7159_;
v___y_7153_ = v_bNeg_7162_;
v___y_7154_ = v_dNeg_7163_;
goto v___jp_7146_;
}
else
{
uint64_t v___x_7164_;
v___x_7164_ = 9223372036854775807ULL;
v___y_7133_ = v___y_7156_;
v___y_7134_ = v___x_7158_;
v___y_7135_ = v___x_7164_;
goto v___jp_7132_;
}
}
}
else
{
v___y_7147_ = v_aNeg_7161_;
v___y_7148_ = v___y_7156_;
v___y_7149_ = v_dNeg_7163_;
v___y_7150_ = v___x_7160_;
v___y_7151_ = v___x_7158_;
v___y_7152_ = v_diff_7159_;
v___y_7153_ = v_bNeg_7162_;
v___y_7154_ = v___y_7157_;
goto v___jp_7146_;
}
}
v___jp_7165_:
{
uint64_t v___x_7169_; uint64_t v___x_7170_; uint8_t v___x_7171_;
v___x_7169_ = 9223372036854775808ULL;
v___x_7170_ = lean_uint64_add(v___y_7168_, v___x_7169_);
v___x_7171_ = lean_uint64_dec_lt(v___x_7169_, v___x_7170_);
if (v___x_7171_ == 0)
{
v___y_7113_ = v___y_7166_;
v___y_7114_ = v___y_7167_;
goto v___jp_7112_;
}
else
{
v___y_7113_ = v___y_7166_;
v___y_7114_ = v___y_7168_;
goto v___jp_7112_;
}
}
v___jp_7172_:
{
if (v___y_7178_ == 0)
{
v___y_7166_ = v___y_7174_;
v___y_7167_ = v___y_7175_;
v___y_7168_ = v___y_7176_;
goto v___jp_7165_;
}
else
{
if (v___y_7173_ == 0)
{
v___y_7166_ = v___y_7174_;
v___y_7167_ = v___y_7175_;
v___y_7168_ = v___y_7177_;
goto v___jp_7165_;
}
else
{
v___y_7166_ = v___y_7174_;
v___y_7167_ = v___y_7175_;
v___y_7168_ = v___y_7176_;
goto v___jp_7165_;
}
}
}
v___jp_7179_:
{
if (v___y_7180_ == 0)
{
v___y_7166_ = v___y_7182_;
v___y_7167_ = v___y_7183_;
v___y_7168_ = v___y_7185_;
goto v___jp_7165_;
}
else
{
if (v___y_7181_ == 0)
{
v___y_7173_ = v___y_7187_;
v___y_7174_ = v___y_7182_;
v___y_7175_ = v___y_7183_;
v___y_7176_ = v___y_7184_;
v___y_7177_ = v___y_7185_;
v___y_7178_ = v___y_7186_;
goto v___jp_7172_;
}
else
{
if (v___y_7187_ == 0)
{
v___y_7166_ = v___y_7182_;
v___y_7167_ = v___y_7183_;
v___y_7168_ = v___y_7185_;
goto v___jp_7165_;
}
else
{
v___y_7173_ = v___y_7187_;
v___y_7174_ = v___y_7182_;
v___y_7175_ = v___y_7183_;
v___y_7176_ = v___y_7184_;
v___y_7177_ = v___y_7185_;
v___y_7178_ = v___y_7186_;
goto v___jp_7172_;
}
}
}
}
v___jp_7188_:
{
uint64_t v___x_7192_; uint64_t v___x_7193_; uint8_t v___x_7194_;
v___x_7192_ = 9223372036854775808ULL;
v___x_7193_ = lean_uint64_add(v___y_7191_, v___x_7192_);
v___x_7194_ = lean_uint64_dec_lt(v___x_7192_, v___x_7193_);
if (v___x_7194_ == 0)
{
v___y_7113_ = v___y_7189_;
v___y_7114_ = v___y_7190_;
goto v___jp_7112_;
}
else
{
v___y_7113_ = v___y_7189_;
v___y_7114_ = v___y_7191_;
goto v___jp_7112_;
}
}
v___jp_7195_:
{
uint64_t v___x_7200_; uint64_t v___x_7201_; uint64_t v___x_7202_; uint8_t v___x_7203_;
v___x_7200_ = 9223372036854775808ULL;
v___x_7201_ = lean_uint64_add(v___y_7197_, v___x_7200_);
v___x_7202_ = lean_uint64_add(v___y_7199_, v___x_7200_);
v___x_7203_ = lean_uint64_dec_le(v___x_7201_, v___x_7202_);
if (v___x_7203_ == 0)
{
v___y_7189_ = v___y_7196_;
v___y_7190_ = v___y_7198_;
v___y_7191_ = v___y_7199_;
goto v___jp_7188_;
}
else
{
v___y_7189_ = v___y_7196_;
v___y_7190_ = v___y_7198_;
v___y_7191_ = v___y_7197_;
goto v___jp_7188_;
}
}
v___jp_7204_:
{
uint64_t v___x_7209_; uint64_t v___x_7210_; uint8_t v___x_7211_;
v___x_7209_ = 9223372036854775808ULL;
v___x_7210_ = lean_uint64_add(v___y_7208_, v___x_7209_);
v___x_7211_ = lean_uint64_dec_lt(v___x_7209_, v___x_7210_);
if (v___x_7211_ == 0)
{
v___y_7196_ = v___y_7205_;
v___y_7197_ = v___y_7206_;
v___y_7198_ = v___y_7207_;
v___y_7199_ = v___y_7207_;
goto v___jp_7195_;
}
else
{
v___y_7196_ = v___y_7205_;
v___y_7197_ = v___y_7206_;
v___y_7198_ = v___y_7207_;
v___y_7199_ = v___y_7208_;
goto v___jp_7195_;
}
}
v___jp_7212_:
{
if (v___y_7217_ == 0)
{
v___y_7205_ = v___y_7213_;
v___y_7206_ = v___y_7215_;
v___y_7207_ = v___y_7218_;
v___y_7208_ = v___y_7216_;
goto v___jp_7204_;
}
else
{
if (v___y_7219_ == 0)
{
v___y_7205_ = v___y_7213_;
v___y_7206_ = v___y_7215_;
v___y_7207_ = v___y_7218_;
v___y_7208_ = v___y_7214_;
goto v___jp_7204_;
}
else
{
v___y_7205_ = v___y_7213_;
v___y_7206_ = v___y_7215_;
v___y_7207_ = v___y_7218_;
v___y_7208_ = v___y_7216_;
goto v___jp_7204_;
}
}
}
v___jp_7220_:
{
if (v___y_7222_ == 0)
{
v___y_7205_ = v___y_7221_;
v___y_7206_ = v___y_7224_;
v___y_7207_ = v___y_7228_;
v___y_7208_ = v___y_7223_;
goto v___jp_7204_;
}
else
{
if (v___y_7225_ == 0)
{
v___y_7213_ = v___y_7221_;
v___y_7214_ = v___y_7223_;
v___y_7215_ = v___y_7224_;
v___y_7216_ = v___y_7226_;
v___y_7217_ = v___y_7227_;
v___y_7218_ = v___y_7228_;
v___y_7219_ = v___y_7229_;
goto v___jp_7212_;
}
else
{
if (v___y_7229_ == 0)
{
v___y_7205_ = v___y_7221_;
v___y_7206_ = v___y_7224_;
v___y_7207_ = v___y_7228_;
v___y_7208_ = v___y_7223_;
goto v___jp_7204_;
}
else
{
v___y_7213_ = v___y_7221_;
v___y_7214_ = v___y_7223_;
v___y_7215_ = v___y_7224_;
v___y_7216_ = v___y_7226_;
v___y_7217_ = v___y_7227_;
v___y_7218_ = v___y_7228_;
v___y_7219_ = v___y_7229_;
goto v___jp_7212_;
}
}
}
}
v___jp_7230_:
{
uint64_t v___x_7234_; uint64_t v_diff_7235_; uint64_t v___x_7236_; uint8_t v_aNeg_7237_; uint8_t v_bNeg_7238_; uint8_t v_dNeg_7239_;
v___x_7234_ = 0ULL;
v_diff_7235_ = lean_uint64_sub(v_height_7098_, v_client_7099_);
v___x_7236_ = 9223372036854775808ULL;
v_aNeg_7237_ = lean_uint64_dec_le(v___x_7236_, v_height_7098_);
v_bNeg_7238_ = lean_uint64_dec_le(v___x_7236_, v_client_7099_);
v_dNeg_7239_ = lean_uint64_dec_le(v___x_7236_, v_diff_7235_);
if (v_aNeg_7237_ == 0)
{
if (v_bNeg_7238_ == 0)
{
v___y_7221_ = v___y_7232_;
v___y_7222_ = v_aNeg_7237_;
v___y_7223_ = v_diff_7235_;
v___y_7224_ = v___y_7233_;
v___y_7225_ = v_bNeg_7238_;
v___y_7226_ = v___x_7236_;
v___y_7227_ = v_dNeg_7239_;
v___y_7228_ = v___x_7234_;
v___y_7229_ = v_bNeg_7238_;
goto v___jp_7220_;
}
else
{
if (v_dNeg_7239_ == 0)
{
v___y_7221_ = v___y_7232_;
v___y_7222_ = v_aNeg_7237_;
v___y_7223_ = v_diff_7235_;
v___y_7224_ = v___y_7233_;
v___y_7225_ = v_bNeg_7238_;
v___y_7226_ = v___x_7236_;
v___y_7227_ = v_dNeg_7239_;
v___y_7228_ = v___x_7234_;
v___y_7229_ = v_dNeg_7239_;
goto v___jp_7220_;
}
else
{
uint64_t v___x_7240_;
v___x_7240_ = 9223372036854775807ULL;
v___y_7205_ = v___y_7232_;
v___y_7206_ = v___y_7233_;
v___y_7207_ = v___x_7234_;
v___y_7208_ = v___x_7240_;
goto v___jp_7204_;
}
}
}
else
{
v___y_7221_ = v___y_7232_;
v___y_7222_ = v_aNeg_7237_;
v___y_7223_ = v_diff_7235_;
v___y_7224_ = v___y_7233_;
v___y_7225_ = v_bNeg_7238_;
v___y_7226_ = v___x_7236_;
v___y_7227_ = v_dNeg_7239_;
v___y_7228_ = v___x_7234_;
v___y_7229_ = v___y_7231_;
goto v___jp_7220_;
}
}
v___jp_7241_:
{
if (v___y_7247_ == 0)
{
v___y_7231_ = v___y_7242_;
v___y_7232_ = v___y_7246_;
v___y_7233_ = v___y_7248_;
goto v___jp_7230_;
}
else
{
if (v___y_7245_ == 0)
{
v___y_7231_ = v___y_7242_;
v___y_7232_ = v___y_7246_;
v___y_7233_ = v___y_7248_;
goto v___jp_7230_;
}
else
{
if (v___y_7244_ == 0)
{
v___y_7231_ = v___y_7242_;
v___y_7232_ = v___y_7246_;
v___y_7233_ = v___y_7243_;
goto v___jp_7230_;
}
else
{
if (v___y_7249_ == 0)
{
v___y_7231_ = v___y_7242_;
v___y_7232_ = v___y_7246_;
v___y_7233_ = v___y_7248_;
goto v___jp_7230_;
}
else
{
v___y_7231_ = v___y_7242_;
v___y_7232_ = v___y_7246_;
v___y_7233_ = v___y_7243_;
goto v___jp_7230_;
}
}
}
}
}
v___jp_7250_:
{
uint64_t v___x_7254_; uint64_t v___x_7255_; uint8_t v___x_7256_;
v___x_7254_ = 9223372036854775808ULL;
v___x_7255_ = lean_uint64_add(v___y_7253_, v___x_7254_);
v___x_7256_ = lean_uint64_dec_lt(v___x_7254_, v___x_7255_);
if (v___x_7256_ == 0)
{
v___y_7113_ = v___y_7251_;
v___y_7114_ = v___y_7252_;
goto v___jp_7112_;
}
else
{
v___y_7113_ = v___y_7251_;
v___y_7114_ = v___y_7253_;
goto v___jp_7112_;
}
}
v___jp_7257_:
{
if (v___y_7263_ == 0)
{
v___y_7251_ = v___y_7260_;
v___y_7252_ = v___y_7259_;
v___y_7253_ = v___y_7261_;
goto v___jp_7250_;
}
else
{
if (v___y_7262_ == 0)
{
v___y_7251_ = v___y_7260_;
v___y_7252_ = v___y_7259_;
v___y_7253_ = v___y_7258_;
goto v___jp_7250_;
}
else
{
v___y_7251_ = v___y_7260_;
v___y_7252_ = v___y_7259_;
v___y_7253_ = v___y_7261_;
goto v___jp_7250_;
}
}
}
v___jp_7264_:
{
if (v___y_7271_ == 0)
{
v___y_7251_ = v___y_7267_;
v___y_7252_ = v___y_7268_;
v___y_7253_ = v___y_7265_;
goto v___jp_7250_;
}
else
{
if (v___y_7266_ == 0)
{
v___y_7258_ = v___y_7265_;
v___y_7259_ = v___y_7268_;
v___y_7260_ = v___y_7267_;
v___y_7261_ = v___y_7269_;
v___y_7262_ = v___y_7272_;
v___y_7263_ = v___y_7270_;
goto v___jp_7257_;
}
else
{
if (v___y_7272_ == 0)
{
v___y_7251_ = v___y_7267_;
v___y_7252_ = v___y_7268_;
v___y_7253_ = v___y_7265_;
goto v___jp_7250_;
}
else
{
v___y_7258_ = v___y_7265_;
v___y_7259_ = v___y_7268_;
v___y_7260_ = v___y_7267_;
v___y_7261_ = v___y_7269_;
v___y_7262_ = v___y_7272_;
v___y_7263_ = v___y_7270_;
goto v___jp_7257_;
}
}
}
}
v___jp_7273_:
{
uint8_t v___x_7276_; uint8_t v___x_7277_;
v___x_7276_ = 0;
v___x_7277_ = lean_uint8_dec_eq(v_opKind_7093_, v___x_7276_);
if (v___x_7277_ == 0)
{
uint8_t v___x_7278_; uint8_t v___x_7279_;
v___x_7278_ = 1;
v___x_7279_ = lean_uint8_dec_eq(v_opKind_7093_, v___x_7278_);
if (v___x_7279_ == 0)
{
uint8_t v___x_7280_; uint8_t v___x_7281_;
v___x_7280_ = 2;
v___x_7281_ = lean_uint8_dec_eq(v_opKind_7093_, v___x_7280_);
if (v___x_7281_ == 0)
{
uint64_t v___x_7282_; uint64_t v_diff_7283_; uint64_t v___x_7284_; uint8_t v_aNeg_7285_; uint8_t v_bNeg_7286_; uint8_t v_dNeg_7287_;
v___x_7282_ = 0ULL;
v_diff_7283_ = lean_uint64_sub(v_height_7098_, v_client_7099_);
v___x_7284_ = 9223372036854775808ULL;
v_aNeg_7285_ = lean_uint64_dec_le(v___x_7284_, v_height_7098_);
v_bNeg_7286_ = lean_uint64_dec_le(v___x_7284_, v_client_7099_);
v_dNeg_7287_ = lean_uint64_dec_le(v___x_7284_, v_diff_7283_);
if (v_aNeg_7285_ == 0)
{
if (v_bNeg_7286_ == 0)
{
v___y_7180_ = v_aNeg_7285_;
v___y_7181_ = v_bNeg_7286_;
v___y_7182_ = v___y_7275_;
v___y_7183_ = v___x_7282_;
v___y_7184_ = v___x_7284_;
v___y_7185_ = v_diff_7283_;
v___y_7186_ = v_dNeg_7287_;
v___y_7187_ = v_bNeg_7286_;
goto v___jp_7179_;
}
else
{
if (v_dNeg_7287_ == 0)
{
v___y_7180_ = v_aNeg_7285_;
v___y_7181_ = v_bNeg_7286_;
v___y_7182_ = v___y_7275_;
v___y_7183_ = v___x_7282_;
v___y_7184_ = v___x_7284_;
v___y_7185_ = v_diff_7283_;
v___y_7186_ = v_dNeg_7287_;
v___y_7187_ = v_dNeg_7287_;
goto v___jp_7179_;
}
else
{
uint64_t v___x_7288_;
v___x_7288_ = 9223372036854775807ULL;
v___y_7166_ = v___y_7275_;
v___y_7167_ = v___x_7282_;
v___y_7168_ = v___x_7288_;
goto v___jp_7165_;
}
}
}
else
{
v___y_7180_ = v_aNeg_7285_;
v___y_7181_ = v_bNeg_7286_;
v___y_7182_ = v___y_7275_;
v___y_7183_ = v___x_7282_;
v___y_7184_ = v___x_7284_;
v___y_7185_ = v_diff_7283_;
v___y_7186_ = v_dNeg_7287_;
v___y_7187_ = v___x_7281_;
goto v___jp_7179_;
}
}
else
{
v___y_7156_ = v___y_7275_;
v___y_7157_ = v___x_7277_;
goto v___jp_7155_;
}
}
else
{
v___y_7156_ = v___y_7275_;
v___y_7157_ = v___x_7277_;
goto v___jp_7155_;
}
}
else
{
uint8_t v___x_7289_; uint8_t v___x_7290_;
v___x_7289_ = 1;
v___x_7290_ = lean_uint8_dec_eq(v_pinned_7094_, v___x_7289_);
if (v___x_7290_ == 0)
{
uint64_t v_sum_7291_; uint64_t v___x_7292_; uint8_t v_aNeg_7293_; uint8_t v_bNeg_7294_; uint8_t v_sNeg_7295_;
v_sum_7291_ = lean_uint64_add(v_curTop_7097_, v_arg_7100_);
v___x_7292_ = 9223372036854775808ULL;
v_aNeg_7293_ = lean_uint64_dec_le(v___x_7292_, v_curTop_7097_);
v_bNeg_7294_ = lean_uint64_dec_le(v___x_7292_, v_arg_7100_);
v_sNeg_7295_ = lean_uint64_dec_le(v___x_7292_, v_sum_7291_);
if (v_aNeg_7293_ == 0)
{
if (v_bNeg_7294_ == 0)
{
if (v_sNeg_7295_ == 0)
{
v___y_7242_ = v___x_7290_;
v___y_7243_ = v___x_7292_;
v___y_7244_ = v_sNeg_7295_;
v___y_7245_ = v_bNeg_7294_;
v___y_7246_ = v___y_7275_;
v___y_7247_ = v_aNeg_7293_;
v___y_7248_ = v_sum_7291_;
v___y_7249_ = v_sNeg_7295_;
goto v___jp_7241_;
}
else
{
uint64_t v___x_7296_;
v___x_7296_ = 9223372036854775807ULL;
v___y_7231_ = v___x_7290_;
v___y_7232_ = v___y_7275_;
v___y_7233_ = v___x_7296_;
goto v___jp_7230_;
}
}
else
{
v___y_7242_ = v___x_7290_;
v___y_7243_ = v___x_7292_;
v___y_7244_ = v_sNeg_7295_;
v___y_7245_ = v_bNeg_7294_;
v___y_7246_ = v___y_7275_;
v___y_7247_ = v_aNeg_7293_;
v___y_7248_ = v_sum_7291_;
v___y_7249_ = v_aNeg_7293_;
goto v___jp_7241_;
}
}
else
{
v___y_7242_ = v___x_7290_;
v___y_7243_ = v___x_7292_;
v___y_7244_ = v_sNeg_7295_;
v___y_7245_ = v_bNeg_7294_;
v___y_7246_ = v___y_7275_;
v___y_7247_ = v_aNeg_7293_;
v___y_7248_ = v_sum_7291_;
v___y_7249_ = v___x_7290_;
goto v___jp_7241_;
}
}
else
{
uint64_t v___x_7297_; uint64_t v_diff_7298_; uint64_t v___x_7299_; uint8_t v_aNeg_7300_; uint8_t v_bNeg_7301_; uint8_t v_dNeg_7302_;
v___x_7297_ = 0ULL;
v_diff_7298_ = lean_uint64_sub(v_height_7098_, v_client_7099_);
v___x_7299_ = 9223372036854775808ULL;
v_aNeg_7300_ = lean_uint64_dec_le(v___x_7299_, v_height_7098_);
v_bNeg_7301_ = lean_uint64_dec_le(v___x_7299_, v_client_7099_);
v_dNeg_7302_ = lean_uint64_dec_le(v___x_7299_, v_diff_7298_);
if (v_aNeg_7300_ == 0)
{
if (v_bNeg_7301_ == 0)
{
v___y_7265_ = v_diff_7298_;
v___y_7266_ = v_bNeg_7301_;
v___y_7267_ = v___y_7275_;
v___y_7268_ = v___x_7297_;
v___y_7269_ = v___x_7299_;
v___y_7270_ = v_dNeg_7302_;
v___y_7271_ = v_aNeg_7300_;
v___y_7272_ = v_bNeg_7301_;
goto v___jp_7264_;
}
else
{
if (v_dNeg_7302_ == 0)
{
v___y_7265_ = v_diff_7298_;
v___y_7266_ = v_bNeg_7301_;
v___y_7267_ = v___y_7275_;
v___y_7268_ = v___x_7297_;
v___y_7269_ = v___x_7299_;
v___y_7270_ = v_dNeg_7302_;
v___y_7271_ = v_aNeg_7300_;
v___y_7272_ = v_dNeg_7302_;
goto v___jp_7264_;
}
else
{
uint64_t v___x_7303_;
v___x_7303_ = 9223372036854775807ULL;
v___y_7251_ = v___y_7275_;
v___y_7252_ = v___x_7297_;
v___y_7253_ = v___x_7303_;
goto v___jp_7250_;
}
}
}
else
{
v___y_7265_ = v_diff_7298_;
v___y_7266_ = v_bNeg_7301_;
v___y_7267_ = v___y_7275_;
v___y_7268_ = v___x_7297_;
v___y_7269_ = v___x_7299_;
v___y_7270_ = v_dNeg_7302_;
v___y_7271_ = v_aNeg_7300_;
v___y_7272_ = v___y_7274_;
goto v___jp_7264_;
}
}
}
}
v___jp_7304_:
{
uint64_t v___x_7309_; uint64_t v___x_7310_; uint64_t v___x_7311_; uint8_t v___x_7312_;
v___x_7309_ = 9223372036854775808ULL;
v___x_7310_ = lean_uint64_add(v___y_7308_, v___x_7309_);
v___x_7311_ = 9223372036854775832ULL;
v___x_7312_ = lean_uint64_dec_lt(v___x_7310_, v___x_7311_);
if (v___x_7312_ == 0)
{
v___y_7274_ = v___y_7306_;
v___y_7275_ = v___y_7307_;
goto v___jp_7273_;
}
else
{
v___y_7274_ = v___y_7306_;
v___y_7275_ = v___y_7305_;
goto v___jp_7273_;
}
}
v___jp_7313_:
{
uint64_t v___x_7318_; uint64_t v___x_7319_; uint64_t v___x_7320_; uint8_t v___x_7321_;
v___x_7318_ = 9223372036854775808ULL;
v___x_7319_ = 9223372036854775832ULL;
v___x_7320_ = lean_uint64_add(v___y_7317_, v___x_7318_);
v___x_7321_ = lean_uint64_dec_le(v___x_7319_, v___x_7320_);
if (v___x_7321_ == 0)
{
v___y_7274_ = v___y_7314_;
v___y_7275_ = v___y_7316_;
goto v___jp_7273_;
}
else
{
v___y_7274_ = v___y_7314_;
v___y_7275_ = v___y_7315_;
goto v___jp_7273_;
}
}
v___jp_7322_:
{
if (v___y_7329_ == 0)
{
v___y_7314_ = v___y_7326_;
v___y_7315_ = v___y_7328_;
v___y_7316_ = v___y_7327_;
v___y_7317_ = v___y_7324_;
goto v___jp_7313_;
}
else
{
if (v___y_7323_ == 0)
{
v___y_7314_ = v___y_7326_;
v___y_7315_ = v___y_7328_;
v___y_7316_ = v___y_7327_;
v___y_7317_ = v___y_7325_;
goto v___jp_7313_;
}
else
{
v___y_7314_ = v___y_7326_;
v___y_7315_ = v___y_7328_;
v___y_7316_ = v___y_7327_;
v___y_7317_ = v___y_7324_;
goto v___jp_7313_;
}
}
}
v___jp_7330_:
{
if (v___y_7331_ == 0)
{
v___y_7314_ = v___y_7335_;
v___y_7315_ = v___y_7336_;
v___y_7316_ = v___y_7337_;
v___y_7317_ = v___y_7334_;
goto v___jp_7313_;
}
else
{
if (v___y_7333_ == 0)
{
v___y_7323_ = v___y_7339_;
v___y_7324_ = v___y_7332_;
v___y_7325_ = v___y_7334_;
v___y_7326_ = v___y_7335_;
v___y_7327_ = v___y_7337_;
v___y_7328_ = v___y_7336_;
v___y_7329_ = v___y_7338_;
goto v___jp_7322_;
}
else
{
if (v___y_7339_ == 0)
{
v___y_7314_ = v___y_7335_;
v___y_7315_ = v___y_7336_;
v___y_7316_ = v___y_7337_;
v___y_7317_ = v___y_7334_;
goto v___jp_7313_;
}
else
{
v___y_7323_ = v___y_7339_;
v___y_7324_ = v___y_7332_;
v___y_7325_ = v___y_7334_;
v___y_7326_ = v___y_7335_;
v___y_7327_ = v___y_7337_;
v___y_7328_ = v___y_7336_;
v___y_7329_ = v___y_7338_;
goto v___jp_7322_;
}
}
}
}
v___jp_7340_:
{
uint64_t v_diff_7345_; uint64_t v___x_7346_; uint8_t v_aNeg_7347_; uint8_t v_bNeg_7348_; uint8_t v_dNeg_7349_;
v_diff_7345_ = lean_uint64_sub(v___y_7344_, v_client_7099_);
v___x_7346_ = 9223372036854775808ULL;
v_aNeg_7347_ = lean_uint64_dec_le(v___x_7346_, v___y_7344_);
v_bNeg_7348_ = lean_uint64_dec_le(v___x_7346_, v_client_7099_);
v_dNeg_7349_ = lean_uint64_dec_le(v___x_7346_, v_diff_7345_);
if (v_aNeg_7347_ == 0)
{
if (v_bNeg_7348_ == 0)
{
v___y_7331_ = v_aNeg_7347_;
v___y_7332_ = v___x_7346_;
v___y_7333_ = v_bNeg_7348_;
v___y_7334_ = v_diff_7345_;
v___y_7335_ = v___y_7341_;
v___y_7336_ = v___y_7343_;
v___y_7337_ = v___y_7342_;
v___y_7338_ = v_dNeg_7349_;
v___y_7339_ = v_bNeg_7348_;
goto v___jp_7330_;
}
else
{
if (v_dNeg_7349_ == 0)
{
v___y_7331_ = v_aNeg_7347_;
v___y_7332_ = v___x_7346_;
v___y_7333_ = v_bNeg_7348_;
v___y_7334_ = v_diff_7345_;
v___y_7335_ = v___y_7341_;
v___y_7336_ = v___y_7343_;
v___y_7337_ = v___y_7342_;
v___y_7338_ = v_dNeg_7349_;
v___y_7339_ = v_dNeg_7349_;
goto v___jp_7330_;
}
else
{
uint64_t v___x_7350_;
v___x_7350_ = 9223372036854775807ULL;
v___y_7314_ = v___y_7341_;
v___y_7315_ = v___y_7343_;
v___y_7316_ = v___y_7342_;
v___y_7317_ = v___x_7350_;
goto v___jp_7313_;
}
}
}
else
{
v___y_7331_ = v_aNeg_7347_;
v___y_7332_ = v___x_7346_;
v___y_7333_ = v_bNeg_7348_;
v___y_7334_ = v_diff_7345_;
v___y_7335_ = v___y_7341_;
v___y_7336_ = v___y_7343_;
v___y_7337_ = v___y_7342_;
v___y_7338_ = v_dNeg_7349_;
v___y_7339_ = v___y_7343_;
goto v___jp_7330_;
}
}
v___jp_7351_:
{
if (v___y_7356_ == 0)
{
v___y_7341_ = v___y_7355_;
v___y_7342_ = v___y_7358_;
v___y_7343_ = v___y_7357_;
v___y_7344_ = v___y_7353_;
goto v___jp_7340_;
}
else
{
if (v___y_7352_ == 0)
{
v___y_7341_ = v___y_7355_;
v___y_7342_ = v___y_7358_;
v___y_7343_ = v___y_7357_;
v___y_7344_ = v___y_7354_;
goto v___jp_7340_;
}
else
{
v___y_7341_ = v___y_7355_;
v___y_7342_ = v___y_7358_;
v___y_7343_ = v___y_7357_;
v___y_7344_ = v___y_7353_;
goto v___jp_7340_;
}
}
}
v___jp_7359_:
{
if (v___y_7360_ == 0)
{
v___y_7341_ = v___y_7363_;
v___y_7342_ = v___y_7366_;
v___y_7343_ = v___y_7367_;
v___y_7344_ = v___y_7364_;
goto v___jp_7340_;
}
else
{
if (v___y_7365_ == 0)
{
v___y_7352_ = v___y_7368_;
v___y_7353_ = v___y_7361_;
v___y_7354_ = v___y_7364_;
v___y_7355_ = v___y_7363_;
v___y_7356_ = v___y_7362_;
v___y_7357_ = v___y_7367_;
v___y_7358_ = v___y_7366_;
goto v___jp_7351_;
}
else
{
if (v___y_7368_ == 0)
{
v___y_7341_ = v___y_7363_;
v___y_7342_ = v___y_7366_;
v___y_7343_ = v___y_7367_;
v___y_7344_ = v___y_7364_;
goto v___jp_7340_;
}
else
{
v___y_7352_ = v___y_7368_;
v___y_7353_ = v___y_7361_;
v___y_7354_ = v___y_7364_;
v___y_7355_ = v___y_7363_;
v___y_7356_ = v___y_7362_;
v___y_7357_ = v___y_7367_;
v___y_7358_ = v___y_7366_;
goto v___jp_7351_;
}
}
}
}
v___jp_7369_:
{
if (v___y_7374_ == 0)
{
v___y_7274_ = v___y_7371_;
v___y_7275_ = v___y_7373_;
goto v___jp_7273_;
}
else
{
uint64_t v___x_7375_; uint64_t v___x_7376_; uint64_t v___x_7377_; uint8_t v___x_7378_;
v___x_7375_ = 9223372036854775808ULL;
v___x_7376_ = lean_uint64_add(v___y_7370_, v___x_7375_);
v___x_7377_ = lean_uint64_add(v_curTop_7097_, v___x_7375_);
v___x_7378_ = lean_uint64_dec_lt(v___x_7376_, v___x_7377_);
if (v___x_7378_ == 0)
{
v___y_7274_ = v___y_7371_;
v___y_7275_ = v___y_7373_;
goto v___jp_7273_;
}
else
{
uint64_t v_diff_7379_; uint8_t v_aNeg_7380_; uint8_t v_bNeg_7381_; uint8_t v_dNeg_7382_;
v_diff_7379_ = lean_uint64_sub(v_height_7098_, v___y_7370_);
v_aNeg_7380_ = lean_uint64_dec_le(v___x_7375_, v_height_7098_);
v_bNeg_7381_ = lean_uint64_dec_le(v___x_7375_, v___y_7370_);
v_dNeg_7382_ = lean_uint64_dec_le(v___x_7375_, v_diff_7379_);
if (v_aNeg_7380_ == 0)
{
if (v_bNeg_7381_ == 0)
{
v___y_7360_ = v_aNeg_7380_;
v___y_7361_ = v___x_7375_;
v___y_7362_ = v_dNeg_7382_;
v___y_7363_ = v___y_7371_;
v___y_7364_ = v_diff_7379_;
v___y_7365_ = v_bNeg_7381_;
v___y_7366_ = v___y_7373_;
v___y_7367_ = v___y_7372_;
v___y_7368_ = v_bNeg_7381_;
goto v___jp_7359_;
}
else
{
if (v_dNeg_7382_ == 0)
{
v___y_7360_ = v_aNeg_7380_;
v___y_7361_ = v___x_7375_;
v___y_7362_ = v_dNeg_7382_;
v___y_7363_ = v___y_7371_;
v___y_7364_ = v_diff_7379_;
v___y_7365_ = v_bNeg_7381_;
v___y_7366_ = v___y_7373_;
v___y_7367_ = v___y_7372_;
v___y_7368_ = v_dNeg_7382_;
goto v___jp_7359_;
}
else
{
uint64_t v___x_7383_;
v___x_7383_ = 9223372036854775807ULL;
v___y_7341_ = v___y_7371_;
v___y_7342_ = v___y_7373_;
v___y_7343_ = v___y_7372_;
v___y_7344_ = v___x_7383_;
goto v___jp_7340_;
}
}
}
else
{
v___y_7360_ = v_aNeg_7380_;
v___y_7361_ = v___x_7375_;
v___y_7362_ = v_dNeg_7382_;
v___y_7363_ = v___y_7371_;
v___y_7364_ = v_diff_7379_;
v___y_7365_ = v_bNeg_7381_;
v___y_7366_ = v___y_7373_;
v___y_7367_ = v___y_7372_;
v___y_7368_ = v___y_7372_;
goto v___jp_7359_;
}
}
}
}
v___jp_7384_:
{
if (v___y_7389_ == 0)
{
v___y_7370_ = v___y_7385_;
v___y_7371_ = v___y_7386_;
v___y_7372_ = v___y_7388_;
v___y_7373_ = v___y_7387_;
v___y_7374_ = v___y_7388_;
goto v___jp_7369_;
}
else
{
v___y_7370_ = v___y_7385_;
v___y_7371_ = v___y_7386_;
v___y_7372_ = v___y_7388_;
v___y_7373_ = v___y_7387_;
v___y_7374_ = v___y_7387_;
goto v___jp_7369_;
}
}
v___jp_7390_:
{
uint8_t v___x_7397_;
v___x_7397_ = lean_uint8_dec_eq(v_resized_7096_, v___y_7395_);
if (v___x_7397_ == 0)
{
v___y_7385_ = v___y_7396_;
v___y_7386_ = v___y_7392_;
v___y_7387_ = v___y_7393_;
v___y_7388_ = v___y_7394_;
v___y_7389_ = v___y_7391_;
goto v___jp_7384_;
}
else
{
v___y_7385_ = v___y_7396_;
v___y_7386_ = v___y_7392_;
v___y_7387_ = v___y_7393_;
v___y_7388_ = v___y_7394_;
v___y_7389_ = v___y_7394_;
goto v___jp_7384_;
}
}
v___jp_7398_:
{
uint64_t v___x_7406_; uint64_t v___x_7407_; uint8_t v___x_7408_;
v___x_7406_ = 9223372036854775808ULL;
v___x_7407_ = lean_uint64_add(v___y_7405_, v___x_7406_);
v___x_7408_ = lean_uint64_dec_lt(v___x_7406_, v___x_7407_);
if (v___x_7408_ == 0)
{
v___y_7391_ = v___y_7400_;
v___y_7392_ = v___y_7401_;
v___y_7393_ = v___y_7403_;
v___y_7394_ = v___y_7402_;
v___y_7395_ = v___y_7404_;
v___y_7396_ = v___y_7399_;
goto v___jp_7390_;
}
else
{
v___y_7391_ = v___y_7400_;
v___y_7392_ = v___y_7401_;
v___y_7393_ = v___y_7403_;
v___y_7394_ = v___y_7402_;
v___y_7395_ = v___y_7404_;
v___y_7396_ = v___y_7405_;
goto v___jp_7390_;
}
}
v___jp_7409_:
{
uint64_t v___x_7417_; uint64_t v___x_7418_; uint64_t v___x_7419_; uint8_t v___x_7420_;
v___x_7417_ = 9223372036854775808ULL;
v___x_7418_ = lean_uint64_add(v_arg_7100_, v___x_7417_);
v___x_7419_ = lean_uint64_add(v___y_7416_, v___x_7417_);
v___x_7420_ = lean_uint64_dec_le(v___x_7418_, v___x_7419_);
if (v___x_7420_ == 0)
{
v___y_7399_ = v___y_7410_;
v___y_7400_ = v___y_7411_;
v___y_7401_ = v___y_7412_;
v___y_7402_ = v___y_7414_;
v___y_7403_ = v___y_7413_;
v___y_7404_ = v___y_7415_;
v___y_7405_ = v___y_7416_;
goto v___jp_7398_;
}
else
{
v___y_7399_ = v___y_7410_;
v___y_7400_ = v___y_7411_;
v___y_7401_ = v___y_7412_;
v___y_7402_ = v___y_7414_;
v___y_7403_ = v___y_7413_;
v___y_7404_ = v___y_7415_;
v___y_7405_ = v_arg_7100_;
goto v___jp_7398_;
}
}
v___jp_7421_:
{
uint64_t v___x_7429_; uint64_t v___x_7430_; uint8_t v___x_7431_;
v___x_7429_ = 9223372036854775808ULL;
v___x_7430_ = lean_uint64_add(v___y_7428_, v___x_7429_);
v___x_7431_ = lean_uint64_dec_lt(v___x_7429_, v___x_7430_);
if (v___x_7431_ == 0)
{
v___y_7410_ = v___y_7422_;
v___y_7411_ = v___y_7423_;
v___y_7412_ = v___y_7424_;
v___y_7413_ = v___y_7426_;
v___y_7414_ = v___y_7425_;
v___y_7415_ = v___y_7427_;
v___y_7416_ = v___y_7422_;
goto v___jp_7409_;
}
else
{
v___y_7410_ = v___y_7422_;
v___y_7411_ = v___y_7423_;
v___y_7412_ = v___y_7424_;
v___y_7413_ = v___y_7426_;
v___y_7414_ = v___y_7425_;
v___y_7415_ = v___y_7427_;
v___y_7416_ = v___y_7428_;
goto v___jp_7409_;
}
}
v___jp_7432_:
{
if (v___y_7438_ == 0)
{
v___y_7422_ = v___y_7433_;
v___y_7423_ = v___y_7435_;
v___y_7424_ = v___y_7436_;
v___y_7425_ = v___y_7440_;
v___y_7426_ = v___y_7439_;
v___y_7427_ = v___y_7441_;
v___y_7428_ = v___y_7442_;
goto v___jp_7421_;
}
else
{
if (v___y_7434_ == 0)
{
v___y_7422_ = v___y_7433_;
v___y_7423_ = v___y_7435_;
v___y_7424_ = v___y_7436_;
v___y_7425_ = v___y_7440_;
v___y_7426_ = v___y_7439_;
v___y_7427_ = v___y_7441_;
v___y_7428_ = v___y_7437_;
goto v___jp_7421_;
}
else
{
v___y_7422_ = v___y_7433_;
v___y_7423_ = v___y_7435_;
v___y_7424_ = v___y_7436_;
v___y_7425_ = v___y_7440_;
v___y_7426_ = v___y_7439_;
v___y_7427_ = v___y_7441_;
v___y_7428_ = v___y_7442_;
goto v___jp_7421_;
}
}
}
v___jp_7443_:
{
if (v___y_7444_ == 0)
{
v___y_7422_ = v___y_7445_;
v___y_7423_ = v___y_7446_;
v___y_7424_ = v___y_7447_;
v___y_7425_ = v___y_7450_;
v___y_7426_ = v___y_7451_;
v___y_7427_ = v___y_7454_;
v___y_7428_ = v___y_7449_;
goto v___jp_7421_;
}
else
{
if (v___y_7452_ == 0)
{
v___y_7433_ = v___y_7445_;
v___y_7434_ = v___y_7455_;
v___y_7435_ = v___y_7446_;
v___y_7436_ = v___y_7447_;
v___y_7437_ = v___y_7449_;
v___y_7438_ = v___y_7448_;
v___y_7439_ = v___y_7451_;
v___y_7440_ = v___y_7450_;
v___y_7441_ = v___y_7454_;
v___y_7442_ = v___y_7453_;
goto v___jp_7432_;
}
else
{
if (v___y_7455_ == 0)
{
v___y_7422_ = v___y_7445_;
v___y_7423_ = v___y_7446_;
v___y_7424_ = v___y_7447_;
v___y_7425_ = v___y_7450_;
v___y_7426_ = v___y_7451_;
v___y_7427_ = v___y_7454_;
v___y_7428_ = v___y_7449_;
goto v___jp_7421_;
}
else
{
v___y_7433_ = v___y_7445_;
v___y_7434_ = v___y_7455_;
v___y_7435_ = v___y_7446_;
v___y_7436_ = v___y_7447_;
v___y_7437_ = v___y_7449_;
v___y_7438_ = v___y_7448_;
v___y_7439_ = v___y_7451_;
v___y_7440_ = v___y_7450_;
v___y_7441_ = v___y_7454_;
v___y_7442_ = v___y_7453_;
goto v___jp_7432_;
}
}
}
}
v___jp_7456_:
{
uint8_t v___x_7462_; uint8_t v___x_7463_;
v___x_7462_ = 2;
v___x_7463_ = lean_uint8_dec_eq(v_opKind_7093_, v___x_7462_);
if (v___x_7463_ == 0)
{
v___y_7274_ = v___y_7458_;
v___y_7275_ = v___y_7457_;
goto v___jp_7273_;
}
else
{
uint64_t v___x_7464_; uint64_t v_diff_7465_; uint64_t v___x_7466_; uint8_t v_aNeg_7467_; uint8_t v_bNeg_7468_; uint8_t v_dNeg_7469_;
v___x_7464_ = 0ULL;
v_diff_7465_ = lean_uint64_sub(v_height_7098_, v_client_7099_);
v___x_7466_ = 9223372036854775808ULL;
v_aNeg_7467_ = lean_uint64_dec_le(v___x_7466_, v_height_7098_);
v_bNeg_7468_ = lean_uint64_dec_le(v___x_7466_, v_client_7099_);
v_dNeg_7469_ = lean_uint64_dec_le(v___x_7466_, v_diff_7465_);
if (v_aNeg_7467_ == 0)
{
if (v_bNeg_7468_ == 0)
{
v___y_7444_ = v_aNeg_7467_;
v___y_7445_ = v___x_7464_;
v___y_7446_ = v___x_7463_;
v___y_7447_ = v___y_7458_;
v___y_7448_ = v_dNeg_7469_;
v___y_7449_ = v_diff_7465_;
v___y_7450_ = v___y_7461_;
v___y_7451_ = v___y_7459_;
v___y_7452_ = v_bNeg_7468_;
v___y_7453_ = v___x_7466_;
v___y_7454_ = v___y_7460_;
v___y_7455_ = v_bNeg_7468_;
goto v___jp_7443_;
}
else
{
if (v_dNeg_7469_ == 0)
{
v___y_7444_ = v_aNeg_7467_;
v___y_7445_ = v___x_7464_;
v___y_7446_ = v___x_7463_;
v___y_7447_ = v___y_7458_;
v___y_7448_ = v_dNeg_7469_;
v___y_7449_ = v_diff_7465_;
v___y_7450_ = v___y_7461_;
v___y_7451_ = v___y_7459_;
v___y_7452_ = v_bNeg_7468_;
v___y_7453_ = v___x_7466_;
v___y_7454_ = v___y_7460_;
v___y_7455_ = v_dNeg_7469_;
goto v___jp_7443_;
}
else
{
uint64_t v___x_7470_;
v___x_7470_ = 9223372036854775807ULL;
v___y_7422_ = v___x_7464_;
v___y_7423_ = v___x_7463_;
v___y_7424_ = v___y_7458_;
v___y_7425_ = v___y_7461_;
v___y_7426_ = v___y_7459_;
v___y_7427_ = v___y_7460_;
v___y_7428_ = v___x_7470_;
goto v___jp_7421_;
}
}
}
else
{
v___y_7444_ = v_aNeg_7467_;
v___y_7445_ = v___x_7464_;
v___y_7446_ = v___x_7463_;
v___y_7447_ = v___y_7458_;
v___y_7448_ = v_dNeg_7469_;
v___y_7449_ = v_diff_7465_;
v___y_7450_ = v___y_7461_;
v___y_7451_ = v___y_7459_;
v___y_7452_ = v_bNeg_7468_;
v___y_7453_ = v___x_7466_;
v___y_7454_ = v___y_7460_;
v___y_7455_ = v___y_7461_;
goto v___jp_7443_;
}
}
}
v___jp_7471_:
{
if (v___y_7472_ == 0)
{
v___y_7305_ = v___y_7473_;
v___y_7306_ = v___y_7477_;
v___y_7307_ = v___y_7478_;
v___y_7308_ = v___y_7474_;
goto v___jp_7304_;
}
else
{
if (v___y_7475_ == 0)
{
v___y_7305_ = v___y_7473_;
v___y_7306_ = v___y_7477_;
v___y_7307_ = v___y_7478_;
v___y_7308_ = v___y_7476_;
goto v___jp_7304_;
}
else
{
v___y_7305_ = v___y_7473_;
v___y_7306_ = v___y_7477_;
v___y_7307_ = v___y_7478_;
v___y_7308_ = v___y_7474_;
goto v___jp_7304_;
}
}
}
v___jp_7479_:
{
if (v___y_7483_ == 0)
{
v___y_7305_ = v___y_7482_;
v___y_7306_ = v___y_7485_;
v___y_7307_ = v___y_7486_;
v___y_7308_ = v___y_7484_;
goto v___jp_7304_;
}
else
{
if (v___y_7487_ == 0)
{
v___y_7472_ = v___y_7480_;
v___y_7473_ = v___y_7482_;
v___y_7474_ = v___y_7481_;
v___y_7475_ = v___y_7488_;
v___y_7476_ = v___y_7484_;
v___y_7477_ = v___y_7485_;
v___y_7478_ = v___y_7486_;
goto v___jp_7471_;
}
else
{
if (v___y_7488_ == 0)
{
v___y_7305_ = v___y_7482_;
v___y_7306_ = v___y_7485_;
v___y_7307_ = v___y_7486_;
v___y_7308_ = v___y_7484_;
goto v___jp_7304_;
}
else
{
v___y_7472_ = v___y_7480_;
v___y_7473_ = v___y_7482_;
v___y_7474_ = v___y_7481_;
v___y_7475_ = v___y_7488_;
v___y_7476_ = v___y_7484_;
v___y_7477_ = v___y_7485_;
v___y_7478_ = v___y_7486_;
goto v___jp_7471_;
}
}
}
}
v___jp_7489_:
{
uint64_t v_diff_7496_; uint8_t v_aNeg_7497_; uint8_t v_bNeg_7498_; uint8_t v_dNeg_7499_;
v_diff_7496_ = lean_uint64_sub(v___y_7495_, v_client_7099_);
v_aNeg_7497_ = lean_uint64_dec_le(v___y_7491_, v___y_7495_);
v_bNeg_7498_ = lean_uint64_dec_le(v___y_7491_, v_client_7099_);
v_dNeg_7499_ = lean_uint64_dec_le(v___y_7491_, v_diff_7496_);
if (v_aNeg_7497_ == 0)
{
if (v_bNeg_7498_ == 0)
{
v___y_7480_ = v_dNeg_7499_;
v___y_7481_ = v___y_7491_;
v___y_7482_ = v___y_7490_;
v___y_7483_ = v_aNeg_7497_;
v___y_7484_ = v_diff_7496_;
v___y_7485_ = v___y_7493_;
v___y_7486_ = v___y_7494_;
v___y_7487_ = v_bNeg_7498_;
v___y_7488_ = v_bNeg_7498_;
goto v___jp_7479_;
}
else
{
if (v_dNeg_7499_ == 0)
{
v___y_7480_ = v_dNeg_7499_;
v___y_7481_ = v___y_7491_;
v___y_7482_ = v___y_7490_;
v___y_7483_ = v_aNeg_7497_;
v___y_7484_ = v_diff_7496_;
v___y_7485_ = v___y_7493_;
v___y_7486_ = v___y_7494_;
v___y_7487_ = v_bNeg_7498_;
v___y_7488_ = v_dNeg_7499_;
goto v___jp_7479_;
}
else
{
uint64_t v___x_7500_;
v___x_7500_ = 9223372036854775807ULL;
v___y_7305_ = v___y_7490_;
v___y_7306_ = v___y_7493_;
v___y_7307_ = v___y_7494_;
v___y_7308_ = v___x_7500_;
goto v___jp_7304_;
}
}
}
else
{
v___y_7480_ = v_dNeg_7499_;
v___y_7481_ = v___y_7491_;
v___y_7482_ = v___y_7490_;
v___y_7483_ = v_aNeg_7497_;
v___y_7484_ = v_diff_7496_;
v___y_7485_ = v___y_7493_;
v___y_7486_ = v___y_7494_;
v___y_7487_ = v_bNeg_7498_;
v___y_7488_ = v___y_7492_;
goto v___jp_7479_;
}
}
v___jp_7501_:
{
if (v___y_7509_ == 0)
{
v___y_7490_ = v___y_7504_;
v___y_7491_ = v___y_7505_;
v___y_7492_ = v___y_7506_;
v___y_7493_ = v___y_7507_;
v___y_7494_ = v___y_7508_;
v___y_7495_ = v___y_7505_;
goto v___jp_7489_;
}
else
{
if (v___y_7503_ == 0)
{
v___y_7490_ = v___y_7504_;
v___y_7491_ = v___y_7505_;
v___y_7492_ = v___y_7506_;
v___y_7493_ = v___y_7507_;
v___y_7494_ = v___y_7508_;
v___y_7495_ = v___y_7502_;
goto v___jp_7489_;
}
else
{
v___y_7490_ = v___y_7504_;
v___y_7491_ = v___y_7505_;
v___y_7492_ = v___y_7506_;
v___y_7493_ = v___y_7507_;
v___y_7494_ = v___y_7508_;
v___y_7495_ = v___y_7505_;
goto v___jp_7489_;
}
}
}
v___jp_7510_:
{
if (v___y_7518_ == 0)
{
v___y_7490_ = v___y_7513_;
v___y_7491_ = v___y_7512_;
v___y_7492_ = v___y_7514_;
v___y_7493_ = v___y_7515_;
v___y_7494_ = v___y_7516_;
v___y_7495_ = v___y_7511_;
goto v___jp_7489_;
}
else
{
if (v___y_7517_ == 0)
{
v___y_7502_ = v___y_7511_;
v___y_7503_ = v___y_7520_;
v___y_7504_ = v___y_7513_;
v___y_7505_ = v___y_7512_;
v___y_7506_ = v___y_7514_;
v___y_7507_ = v___y_7515_;
v___y_7508_ = v___y_7516_;
v___y_7509_ = v___y_7519_;
goto v___jp_7501_;
}
else
{
if (v___y_7520_ == 0)
{
v___y_7490_ = v___y_7513_;
v___y_7491_ = v___y_7512_;
v___y_7492_ = v___y_7514_;
v___y_7493_ = v___y_7515_;
v___y_7494_ = v___y_7516_;
v___y_7495_ = v___y_7511_;
goto v___jp_7489_;
}
else
{
v___y_7502_ = v___y_7511_;
v___y_7503_ = v___y_7520_;
v___y_7504_ = v___y_7513_;
v___y_7505_ = v___y_7512_;
v___y_7506_ = v___y_7514_;
v___y_7507_ = v___y_7515_;
v___y_7508_ = v___y_7516_;
v___y_7509_ = v___y_7519_;
goto v___jp_7501_;
}
}
}
}
v___jp_7521_:
{
uint64_t v___x_7527_; uint64_t v___x_7528_; uint64_t v___x_7529_; uint8_t v___x_7530_;
v___x_7527_ = 9223372036854775808ULL;
v___x_7528_ = lean_uint64_add(v___y_7526_, v___x_7527_);
v___x_7529_ = lean_uint64_add(v_curTop_7097_, v___x_7527_);
v___x_7530_ = lean_uint64_dec_lt(v___x_7528_, v___x_7529_);
if (v___x_7530_ == 0)
{
uint64_t v_diff_7531_; uint8_t v_aNeg_7532_; uint8_t v_bNeg_7533_; uint8_t v_dNeg_7534_;
v_diff_7531_ = lean_uint64_sub(v_height_7098_, v___y_7526_);
v_aNeg_7532_ = lean_uint64_dec_le(v___x_7527_, v_height_7098_);
v_bNeg_7533_ = lean_uint64_dec_le(v___x_7527_, v___y_7526_);
v_dNeg_7534_ = lean_uint64_dec_le(v___x_7527_, v_diff_7531_);
if (v_aNeg_7532_ == 0)
{
if (v_bNeg_7533_ == 0)
{
v___y_7511_ = v_diff_7531_;
v___y_7512_ = v___x_7527_;
v___y_7513_ = v___y_7522_;
v___y_7514_ = v___x_7530_;
v___y_7515_ = v___y_7524_;
v___y_7516_ = v___y_7525_;
v___y_7517_ = v_bNeg_7533_;
v___y_7518_ = v_aNeg_7532_;
v___y_7519_ = v_dNeg_7534_;
v___y_7520_ = v_bNeg_7533_;
goto v___jp_7510_;
}
else
{
if (v_dNeg_7534_ == 0)
{
v___y_7511_ = v_diff_7531_;
v___y_7512_ = v___x_7527_;
v___y_7513_ = v___y_7522_;
v___y_7514_ = v___x_7530_;
v___y_7515_ = v___y_7524_;
v___y_7516_ = v___y_7525_;
v___y_7517_ = v_bNeg_7533_;
v___y_7518_ = v_aNeg_7532_;
v___y_7519_ = v_dNeg_7534_;
v___y_7520_ = v_dNeg_7534_;
goto v___jp_7510_;
}
else
{
uint64_t v___x_7535_;
v___x_7535_ = 9223372036854775807ULL;
v___y_7490_ = v___y_7522_;
v___y_7491_ = v___x_7527_;
v___y_7492_ = v___x_7530_;
v___y_7493_ = v___y_7524_;
v___y_7494_ = v___y_7525_;
v___y_7495_ = v___x_7535_;
goto v___jp_7489_;
}
}
}
else
{
v___y_7511_ = v_diff_7531_;
v___y_7512_ = v___x_7527_;
v___y_7513_ = v___y_7522_;
v___y_7514_ = v___x_7530_;
v___y_7515_ = v___y_7524_;
v___y_7516_ = v___y_7525_;
v___y_7517_ = v_bNeg_7533_;
v___y_7518_ = v_aNeg_7532_;
v___y_7519_ = v_dNeg_7534_;
v___y_7520_ = v___x_7530_;
goto v___jp_7510_;
}
}
else
{
v___y_7274_ = v___y_7524_;
v___y_7275_ = v___y_7523_;
goto v___jp_7273_;
}
}
v___jp_7536_:
{
uint64_t v___x_7543_; uint64_t v___x_7544_; uint8_t v___x_7545_;
v___x_7543_ = 9223372036854775808ULL;
v___x_7544_ = lean_uint64_add(v___y_7542_, v___x_7543_);
v___x_7545_ = lean_uint64_dec_lt(v___x_7543_, v___x_7544_);
if (v___x_7545_ == 0)
{
v___y_7522_ = v___y_7537_;
v___y_7523_ = v___y_7539_;
v___y_7524_ = v___y_7540_;
v___y_7525_ = v___y_7541_;
v___y_7526_ = v___y_7538_;
goto v___jp_7521_;
}
else
{
v___y_7522_ = v___y_7537_;
v___y_7523_ = v___y_7539_;
v___y_7524_ = v___y_7540_;
v___y_7525_ = v___y_7541_;
v___y_7526_ = v___y_7542_;
goto v___jp_7521_;
}
}
v___jp_7546_:
{
uint64_t v___x_7553_; uint64_t v___x_7554_; uint64_t v___x_7555_; uint8_t v___x_7556_;
v___x_7553_ = 9223372036854775808ULL;
v___x_7554_ = lean_uint64_add(v_arg_7100_, v___x_7553_);
v___x_7555_ = lean_uint64_add(v___y_7552_, v___x_7553_);
v___x_7556_ = lean_uint64_dec_le(v___x_7554_, v___x_7555_);
if (v___x_7556_ == 0)
{
v___y_7537_ = v___y_7548_;
v___y_7538_ = v___y_7547_;
v___y_7539_ = v___y_7549_;
v___y_7540_ = v___y_7550_;
v___y_7541_ = v___y_7551_;
v___y_7542_ = v___y_7552_;
goto v___jp_7536_;
}
else
{
v___y_7537_ = v___y_7548_;
v___y_7538_ = v___y_7547_;
v___y_7539_ = v___y_7549_;
v___y_7540_ = v___y_7550_;
v___y_7541_ = v___y_7551_;
v___y_7542_ = v_arg_7100_;
goto v___jp_7536_;
}
}
v___jp_7557_:
{
uint64_t v___x_7564_; uint64_t v___x_7565_; uint8_t v___x_7566_;
v___x_7564_ = 9223372036854775808ULL;
v___x_7565_ = lean_uint64_add(v___y_7563_, v___x_7564_);
v___x_7566_ = lean_uint64_dec_lt(v___x_7564_, v___x_7565_);
if (v___x_7566_ == 0)
{
v___y_7547_ = v___y_7559_;
v___y_7548_ = v___y_7558_;
v___y_7549_ = v___y_7560_;
v___y_7550_ = v___y_7561_;
v___y_7551_ = v___y_7562_;
v___y_7552_ = v___y_7559_;
goto v___jp_7546_;
}
else
{
v___y_7547_ = v___y_7559_;
v___y_7548_ = v___y_7558_;
v___y_7549_ = v___y_7560_;
v___y_7550_ = v___y_7561_;
v___y_7551_ = v___y_7562_;
v___y_7552_ = v___y_7563_;
goto v___jp_7546_;
}
}
v___jp_7567_:
{
if (v___y_7576_ == 0)
{
v___y_7558_ = v___y_7571_;
v___y_7559_ = v___y_7570_;
v___y_7560_ = v___y_7572_;
v___y_7561_ = v___y_7574_;
v___y_7562_ = v___y_7575_;
v___y_7563_ = v___y_7568_;
goto v___jp_7557_;
}
else
{
if (v___y_7573_ == 0)
{
v___y_7558_ = v___y_7571_;
v___y_7559_ = v___y_7570_;
v___y_7560_ = v___y_7572_;
v___y_7561_ = v___y_7574_;
v___y_7562_ = v___y_7575_;
v___y_7563_ = v___y_7569_;
goto v___jp_7557_;
}
else
{
v___y_7558_ = v___y_7571_;
v___y_7559_ = v___y_7570_;
v___y_7560_ = v___y_7572_;
v___y_7561_ = v___y_7574_;
v___y_7562_ = v___y_7575_;
v___y_7563_ = v___y_7568_;
goto v___jp_7557_;
}
}
}
v___jp_7577_:
{
if (v___y_7578_ == 0)
{
v___y_7558_ = v___y_7580_;
v___y_7559_ = v___y_7581_;
v___y_7560_ = v___y_7583_;
v___y_7561_ = v___y_7585_;
v___y_7562_ = v___y_7587_;
v___y_7563_ = v___y_7582_;
goto v___jp_7557_;
}
else
{
if (v___y_7584_ == 0)
{
v___y_7568_ = v___y_7579_;
v___y_7569_ = v___y_7582_;
v___y_7570_ = v___y_7581_;
v___y_7571_ = v___y_7580_;
v___y_7572_ = v___y_7583_;
v___y_7573_ = v___y_7588_;
v___y_7574_ = v___y_7585_;
v___y_7575_ = v___y_7587_;
v___y_7576_ = v___y_7586_;
goto v___jp_7567_;
}
else
{
if (v___y_7588_ == 0)
{
v___y_7558_ = v___y_7580_;
v___y_7559_ = v___y_7581_;
v___y_7560_ = v___y_7583_;
v___y_7561_ = v___y_7585_;
v___y_7562_ = v___y_7587_;
v___y_7563_ = v___y_7582_;
goto v___jp_7557_;
}
else
{
v___y_7568_ = v___y_7579_;
v___y_7569_ = v___y_7582_;
v___y_7570_ = v___y_7581_;
v___y_7571_ = v___y_7580_;
v___y_7572_ = v___y_7583_;
v___y_7573_ = v___y_7588_;
v___y_7574_ = v___y_7585_;
v___y_7575_ = v___y_7587_;
v___y_7576_ = v___y_7586_;
goto v___jp_7567_;
}
}
}
}
v___jp_7589_:
{
uint64_t v___x_7594_; uint64_t v_diff_7595_; uint64_t v___x_7596_; uint8_t v_aNeg_7597_; uint8_t v_bNeg_7598_; uint8_t v_dNeg_7599_;
v___x_7594_ = 0ULL;
v_diff_7595_ = lean_uint64_sub(v_height_7098_, v_client_7099_);
v___x_7596_ = 9223372036854775808ULL;
v_aNeg_7597_ = lean_uint64_dec_le(v___x_7596_, v_height_7098_);
v_bNeg_7598_ = lean_uint64_dec_le(v___x_7596_, v_client_7099_);
v_dNeg_7599_ = lean_uint64_dec_le(v___x_7596_, v_diff_7595_);
if (v_aNeg_7597_ == 0)
{
if (v_bNeg_7598_ == 0)
{
v___y_7578_ = v_aNeg_7597_;
v___y_7579_ = v___x_7596_;
v___y_7580_ = v___y_7590_;
v___y_7581_ = v___x_7594_;
v___y_7582_ = v_diff_7595_;
v___y_7583_ = v___y_7591_;
v___y_7584_ = v_bNeg_7598_;
v___y_7585_ = v___y_7592_;
v___y_7586_ = v_dNeg_7599_;
v___y_7587_ = v___y_7593_;
v___y_7588_ = v_bNeg_7598_;
goto v___jp_7577_;
}
else
{
if (v_dNeg_7599_ == 0)
{
v___y_7578_ = v_aNeg_7597_;
v___y_7579_ = v___x_7596_;
v___y_7580_ = v___y_7590_;
v___y_7581_ = v___x_7594_;
v___y_7582_ = v_diff_7595_;
v___y_7583_ = v___y_7591_;
v___y_7584_ = v_bNeg_7598_;
v___y_7585_ = v___y_7592_;
v___y_7586_ = v_dNeg_7599_;
v___y_7587_ = v___y_7593_;
v___y_7588_ = v_dNeg_7599_;
goto v___jp_7577_;
}
else
{
uint64_t v___x_7600_;
v___x_7600_ = 9223372036854775807ULL;
v___y_7558_ = v___y_7590_;
v___y_7559_ = v___x_7594_;
v___y_7560_ = v___y_7591_;
v___y_7561_ = v___y_7592_;
v___y_7562_ = v___y_7593_;
v___y_7563_ = v___x_7600_;
goto v___jp_7557_;
}
}
}
else
{
v___y_7578_ = v_aNeg_7597_;
v___y_7579_ = v___x_7596_;
v___y_7580_ = v___y_7590_;
v___y_7581_ = v___x_7594_;
v___y_7582_ = v_diff_7595_;
v___y_7583_ = v___y_7591_;
v___y_7584_ = v_bNeg_7598_;
v___y_7585_ = v___y_7592_;
v___y_7586_ = v_dNeg_7599_;
v___y_7587_ = v___y_7593_;
v___y_7588_ = v___y_7591_;
goto v___jp_7577_;
}
}
v___jp_7601_:
{
uint8_t v___x_7605_; uint8_t v___x_7606_;
v___x_7605_ = 3;
v___x_7606_ = lean_uint8_dec_le(v_opKind_7093_, v___x_7605_);
if (v___x_7606_ == 0)
{
uint32_t v___x_7607_; uint32_t v_lo32Err_7608_; uint64_t v___x_7609_; uint64_t v___x_7610_; uint64_t v___x_7611_; uint64_t v___x_7612_; uint64_t v___x_7613_;
v___x_7607_ = 2;
v_lo32Err_7608_ = lean_uint32_lor(v___x_7607_, v___y_7603_);
v___x_7609_ = lean_uint32_to_uint64(v_lo32Err_7608_);
v___x_7610_ = lean_uint32_to_uint64(v___y_7602_);
v___x_7611_ = 32ULL;
v___x_7612_ = lean_uint64_shift_left(v___x_7610_, v___x_7611_);
v___x_7613_ = lean_uint64_lor(v___x_7609_, v___x_7612_);
return v___x_7613_;
}
else
{
if (v___y_7604_ == 0)
{
uint32_t v___x_7614_; uint32_t v_lo32Dom_7615_; uint64_t v___x_7616_; uint64_t v___x_7617_; uint64_t v___x_7618_; uint64_t v___x_7619_; uint64_t v___x_7620_;
v___x_7614_ = 3;
v_lo32Dom_7615_ = lean_uint32_lor(v___x_7614_, v___y_7603_);
v___x_7616_ = lean_uint32_to_uint64(v_lo32Dom_7615_);
v___x_7617_ = lean_uint32_to_uint64(v___y_7602_);
v___x_7618_ = 32ULL;
v___x_7619_ = lean_uint64_shift_left(v___x_7617_, v___x_7618_);
v___x_7620_ = lean_uint64_lor(v___x_7616_, v___x_7619_);
return v___x_7620_;
}
else
{
uint8_t v___x_7621_; uint8_t v___x_7622_; uint8_t v_pinBool_7623_; uint8_t v___x_7624_; uint8_t v___x_7625_;
v___x_7621_ = 0;
v___x_7622_ = 1;
v_pinBool_7623_ = lean_uint8_dec_eq(v_pinned_7094_, v___x_7622_);
v___x_7624_ = 0;
v___x_7625_ = lean_uint8_dec_eq(v_opKind_7093_, v___x_7624_);
if (v___x_7625_ == 0)
{
uint8_t v___x_7626_;
v___x_7626_ = lean_uint8_dec_eq(v_opKind_7093_, v___x_7622_);
if (v___x_7626_ == 0)
{
uint8_t v___x_7627_; uint8_t v___x_7628_;
v___x_7627_ = 2;
v___x_7628_ = lean_uint8_dec_eq(v_opKind_7093_, v___x_7627_);
if (v___x_7628_ == 0)
{
v___y_7457_ = v___y_7604_;
v___y_7458_ = v___x_7621_;
v___y_7459_ = v_pinBool_7623_;
v___y_7460_ = v___x_7622_;
v___y_7461_ = v___x_7625_;
goto v___jp_7456_;
}
else
{
uint8_t v___x_7629_;
v___x_7629_ = lean_uint8_dec_eq(v_intent_7095_, v___x_7622_);
if (v___x_7629_ == 0)
{
v___y_7457_ = v___y_7604_;
v___y_7458_ = v___x_7621_;
v___y_7459_ = v_pinBool_7623_;
v___y_7460_ = v___x_7622_;
v___y_7461_ = v___x_7629_;
goto v___jp_7456_;
}
else
{
v___y_7590_ = v___y_7604_;
v___y_7591_ = v___x_7625_;
v___y_7592_ = v___x_7621_;
v___y_7593_ = v_pinBool_7623_;
goto v___jp_7589_;
}
}
}
else
{
v___y_7590_ = v___y_7604_;
v___y_7591_ = v___x_7625_;
v___y_7592_ = v___x_7621_;
v___y_7593_ = v_pinBool_7623_;
goto v___jp_7589_;
}
}
else
{
v___y_7274_ = v___x_7621_;
v___y_7275_ = v_pinBool_7623_;
goto v___jp_7273_;
}
}
}
}
v___jp_7630_:
{
uint64_t v___x_7633_; uint8_t v___x_7634_;
v___x_7633_ = 1073741823ULL;
v___x_7634_ = lean_uint64_dec_le(v_arg_7100_, v___x_7633_);
if (v___x_7634_ == 0)
{
uint64_t v___x_7635_; uint8_t v___x_7636_;
v___x_7635_ = 18446744072635809792ULL;
v___x_7636_ = lean_uint64_dec_le(v___x_7635_, v_arg_7100_);
v___y_7602_ = v___y_7631_;
v___y_7603_ = v___y_7632_;
v___y_7604_ = v___x_7636_;
goto v___jp_7601_;
}
else
{
v___y_7602_ = v___y_7631_;
v___y_7603_ = v___y_7632_;
v___y_7604_ = v___x_7634_;
goto v___jp_7601_;
}
}
v___jp_7637_:
{
uint64_t v___x_7640_; uint8_t v___x_7641_;
v___x_7640_ = 1073741823ULL;
v___x_7641_ = lean_uint64_dec_le(v_client_7099_, v___x_7640_);
if (v___x_7641_ == 0)
{
uint64_t v___x_7642_; uint8_t v___x_7643_;
v___x_7642_ = 18446744072635809792ULL;
v___x_7643_ = lean_uint64_dec_le(v___x_7642_, v_client_7099_);
if (v___x_7643_ == 0)
{
v___y_7602_ = v___y_7638_;
v___y_7603_ = v___y_7639_;
v___y_7604_ = v___x_7643_;
goto v___jp_7601_;
}
else
{
v___y_7631_ = v___y_7638_;
v___y_7632_ = v___y_7639_;
goto v___jp_7630_;
}
}
else
{
v___y_7631_ = v___y_7638_;
v___y_7632_ = v___y_7639_;
goto v___jp_7630_;
}
}
v___jp_7644_:
{
uint64_t v___x_7647_; uint8_t v___x_7648_;
v___x_7647_ = 1073741823ULL;
v___x_7648_ = lean_uint64_dec_le(v_height_7098_, v___x_7647_);
if (v___x_7648_ == 0)
{
uint64_t v___x_7649_; uint8_t v___x_7650_;
v___x_7649_ = 18446744072635809792ULL;
v___x_7650_ = lean_uint64_dec_le(v___x_7649_, v_height_7098_);
if (v___x_7650_ == 0)
{
v___y_7602_ = v___y_7645_;
v___y_7603_ = v___y_7646_;
v___y_7604_ = v___x_7650_;
goto v___jp_7601_;
}
else
{
v___y_7638_ = v___y_7645_;
v___y_7639_ = v___y_7646_;
goto v___jp_7637_;
}
}
else
{
v___y_7638_ = v___y_7645_;
v___y_7639_ = v___y_7646_;
goto v___jp_7637_;
}
}
v___jp_7651_:
{
uint64_t v___x_7654_; uint8_t v___x_7655_;
v___x_7654_ = 1073741823ULL;
v___x_7655_ = lean_uint64_dec_le(v_curTop_7097_, v___x_7654_);
if (v___x_7655_ == 0)
{
uint64_t v___x_7656_; uint8_t v___x_7657_;
v___x_7656_ = 18446744072635809792ULL;
v___x_7657_ = lean_uint64_dec_le(v___x_7656_, v_curTop_7097_);
if (v___x_7657_ == 0)
{
v___y_7602_ = v___y_7653_;
v___y_7603_ = v___y_7652_;
v___y_7604_ = v___x_7657_;
goto v___jp_7601_;
}
else
{
v___y_7645_ = v___y_7653_;
v___y_7646_ = v___y_7652_;
goto v___jp_7644_;
}
}
else
{
v___y_7645_ = v___y_7653_;
v___y_7646_ = v___y_7652_;
goto v___jp_7644_;
}
}
v___jp_7658_:
{
uint64_t v___x_7661_; uint8_t v___x_7662_;
v___x_7661_ = 4294967295ULL;
v___x_7662_ = lean_uint64_dec_le(v___y_7660_, v___x_7661_);
if (v___x_7662_ == 0)
{
uint32_t v___x_7663_;
v___x_7663_ = 4294967295;
v___y_7652_ = v___y_7659_;
v___y_7653_ = v___x_7663_;
goto v___jp_7651_;
}
else
{
uint32_t v___x_7664_;
v___x_7664_ = lean_uint64_to_uint32(v___y_7660_);
v___y_7652_ = v___y_7659_;
v___y_7653_ = v___x_7664_;
goto v___jp_7651_;
}
}
v___jp_7665_:
{
uint64_t v___x_7667_; uint64_t v___x_7668_; uint8_t v___x_7669_;
v___x_7667_ = 9223372036854775808ULL;
v___x_7668_ = lean_uint64_add(v_curTop_7097_, v___x_7667_);
v___x_7669_ = lean_uint64_dec_lt(v___x_7667_, v___x_7668_);
if (v___x_7669_ == 0)
{
uint64_t v___x_7670_;
v___x_7670_ = 0ULL;
v___y_7659_ = v___y_7666_;
v___y_7660_ = v___x_7670_;
goto v___jp_7658_;
}
else
{
v___y_7659_ = v___y_7666_;
v___y_7660_ = v_curTop_7097_;
goto v___jp_7658_;
}
}
}
}

LEAN_EXPORT uint64_t orb_wire_scroll_slice_step(uint64_t v_inPtr_7693_, uint64_t v_inLen_7694_, uint64_t v_outPtr_7695_, uint64_t v_outCap_7696_, uint8_t v_is32Bit_7697_, uint8_t v_opKind_7698_, uint8_t v_pinned_7699_, uint8_t v_intent_7700_, uint8_t v_resized_7701_, uint64_t v_curTop_7702_, uint64_t v_height_7703_, uint64_t v_client_7704_, uint64_t v_arg_7705_){
_start:
{
uint64_t v___x_7706_; uint64_t v___y_7708_; uint32_t v___y_7709_; uint8_t v___y_7718_; uint64_t v___y_7719_; uint8_t v___y_7723_; uint64_t v___y_7724_; uint64_t v___y_7725_; uint8_t v___y_7730_; uint64_t v___y_7731_; uint64_t v___y_7732_; uint8_t v___y_7738_; uint64_t v___y_7739_; uint64_t v___y_7740_; uint64_t v___y_7745_; uint64_t v___y_7746_; uint8_t v___y_7747_; uint8_t v___y_7748_; uint64_t v___y_7749_; uint8_t v___y_7750_; uint64_t v___y_7752_; uint64_t v___y_7753_; uint8_t v___y_7754_; uint8_t v___y_7755_; uint8_t v___y_7756_; uint8_t v___y_7757_; uint64_t v___y_7758_; uint8_t v___y_7759_; uint8_t v___y_7761_; uint8_t v___y_7762_; uint64_t v___y_7771_; uint8_t v___y_7772_; uint64_t v___y_7773_; uint64_t v___y_7778_; uint64_t v___y_7779_; uint8_t v___y_7780_; uint8_t v___y_7781_; uint8_t v___y_7782_; uint64_t v___y_7783_; uint64_t v___y_7785_; uint64_t v___y_7786_; uint8_t v___y_7787_; uint8_t v___y_7788_; uint8_t v___y_7789_; uint8_t v___y_7790_; uint64_t v___y_7791_; uint8_t v___y_7792_; uint8_t v___y_7794_; uint64_t v___y_7795_; uint64_t v___y_7796_; uint64_t v___y_7801_; uint8_t v___y_7802_; uint64_t v___y_7803_; uint64_t v___y_7804_; uint64_t v___y_7810_; uint8_t v___y_7811_; uint64_t v___y_7812_; uint64_t v___y_7813_; uint64_t v___y_7818_; uint64_t v___y_7819_; uint8_t v___y_7820_; uint8_t v___y_7821_; uint8_t v___y_7822_; uint64_t v___y_7823_; uint64_t v___y_7824_; uint64_t v___y_7826_; uint64_t v___y_7827_; uint8_t v___y_7828_; uint8_t v___y_7829_; uint8_t v___y_7830_; uint8_t v___y_7831_; uint64_t v___y_7832_; uint64_t v___y_7833_; uint8_t v___y_7834_; uint8_t v___y_7836_; uint8_t v___y_7837_; uint64_t v___y_7838_; uint8_t v___y_7847_; uint8_t v___y_7848_; uint8_t v___y_7849_; uint64_t v___y_7850_; uint8_t v___y_7851_; uint8_t v___y_7852_; uint64_t v___y_7853_; uint8_t v___y_7854_; uint64_t v___y_7856_; uint8_t v___y_7857_; uint64_t v___y_7858_; uint64_t v___y_7863_; uint64_t v___y_7864_; uint8_t v___y_7865_; uint64_t v___y_7866_; uint8_t v___y_7867_; uint8_t v___y_7868_; uint64_t v___y_7870_; uint64_t v___y_7871_; uint8_t v___y_7872_; uint64_t v___y_7873_; uint8_t v___y_7874_; uint8_t v___y_7875_; uint8_t v___y_7876_; uint8_t v___y_7877_; uint8_t v___y_7879_; uint8_t v___y_7880_; uint8_t v___y_7881_; uint8_t v___y_7910_; uint8_t v___y_7911_; uint8_t v___y_7912_; uint8_t v___y_7913_; uint64_t v___y_7914_; uint8_t v___y_7920_; uint64_t v___y_7921_; uint8_t v___y_7922_; uint8_t v___y_7923_; uint8_t v___y_7924_; uint8_t v___y_7925_; uint64_t v___y_7926_; uint8_t v___y_7927_; uint64_t v___y_7929_; uint8_t v___y_7930_; uint8_t v___y_7931_; uint8_t v___y_7932_; uint8_t v___y_7933_; uint8_t v___y_7934_; uint8_t v___y_7935_; uint8_t v___y_7936_; uint64_t v___y_7937_; uint8_t v___y_7938_; uint8_t v___y_7940_; uint8_t v___y_7941_; uint8_t v___y_7942_; uint8_t v___y_7943_; uint64_t v___y_7944_; uint8_t v___y_7952_; uint8_t v___y_7953_; uint64_t v___y_7954_; uint8_t v___y_7955_; uint8_t v___y_7956_; uint8_t v___y_7957_; uint64_t v___y_7958_; uint8_t v___y_7959_; uint8_t v___y_7961_; uint8_t v___y_7962_; uint8_t v___y_7963_; uint64_t v___y_7964_; uint8_t v___y_7965_; uint8_t v___y_7966_; uint64_t v___y_7967_; uint8_t v___y_7968_; uint8_t v___y_7969_; uint8_t v___y_7970_; uint8_t v___y_7972_; uint8_t v___y_7973_; uint64_t v___y_7974_; uint8_t v___y_7975_; uint8_t v___y_7976_; uint8_t v___y_7977_; uint8_t v___y_7988_; uint8_t v___y_7989_; uint64_t v___y_7990_; uint8_t v___y_7991_; uint8_t v___y_7992_; uint8_t v___y_7993_; uint8_t v___y_7995_; uint8_t v___y_7996_; uint8_t v___y_7997_; uint8_t v___y_7998_; uint8_t v___y_7999_; uint8_t v___y_8000_; uint64_t v___y_8001_; uint8_t v___y_8004_; uint8_t v___y_8005_; uint8_t v___y_8006_; uint64_t v___y_8007_; uint8_t v___y_8008_; uint8_t v___y_8009_; uint8_t v___y_8010_; uint64_t v___y_8011_; uint8_t v___y_8016_; uint8_t v___y_8017_; uint8_t v___y_8018_; uint64_t v___y_8019_; uint8_t v___y_8020_; uint8_t v___y_8021_; uint8_t v___y_8022_; uint64_t v___y_8023_; uint8_t v___y_8029_; uint8_t v___y_8030_; uint8_t v___y_8031_; uint64_t v___y_8032_; uint8_t v___y_8033_; uint8_t v___y_8034_; uint8_t v___y_8035_; uint64_t v___y_8036_; uint8_t v___y_8041_; uint8_t v___y_8042_; uint8_t v___y_8043_; uint8_t v___y_8044_; uint64_t v___y_8045_; uint8_t v___y_8046_; uint8_t v___y_8047_; uint64_t v___y_8048_; uint64_t v___y_8049_; uint8_t v___y_8050_; uint8_t v___y_8051_; uint8_t v___y_8053_; uint8_t v___y_8054_; uint8_t v___y_8055_; uint8_t v___y_8056_; uint64_t v___y_8057_; uint8_t v___y_8058_; uint8_t v___y_8059_; uint8_t v___y_8060_; uint64_t v___y_8061_; uint64_t v___y_8062_; uint8_t v___y_8063_; uint8_t v___y_8064_; uint8_t v___y_8065_; uint8_t v___y_8067_; uint8_t v___y_8068_; uint8_t v___y_8069_; uint8_t v___y_8070_; uint8_t v___y_8071_; uint8_t v___y_8072_; uint8_t v___y_8083_; uint8_t v___y_8084_; uint8_t v___y_8085_; uint8_t v___y_8086_; uint64_t v___y_8087_; uint8_t v___y_8093_; uint8_t v___y_8094_; uint8_t v___y_8095_; uint8_t v___y_8096_; uint64_t v___y_8097_; uint64_t v___y_8098_; uint8_t v___y_8099_; uint8_t v___y_8100_; uint8_t v___y_8102_; uint8_t v___y_8103_; uint8_t v___y_8104_; uint64_t v___y_8105_; uint64_t v___y_8106_; uint8_t v___y_8107_; uint8_t v___y_8108_; uint8_t v___y_8109_; uint8_t v___y_8110_; uint8_t v___y_8111_; uint8_t v___y_8113_; uint8_t v___y_8114_; uint64_t v___y_8115_; uint8_t v___y_8116_; uint8_t v___y_8117_; uint8_t v___y_8118_; uint64_t v___y_8119_; uint8_t v___y_8126_; uint8_t v___y_8127_; uint8_t v___y_8128_; uint64_t v___y_8129_; uint64_t v___y_8130_; uint8_t v___y_8131_; uint8_t v___y_8132_; uint8_t v___y_8133_; uint8_t v___y_8134_; uint8_t v___y_8136_; uint8_t v___y_8137_; uint8_t v___y_8138_; uint8_t v___y_8139_; uint64_t v___y_8140_; uint64_t v___y_8141_; uint8_t v___y_8142_; uint8_t v___y_8143_; uint8_t v___y_8144_; uint8_t v___y_8145_; uint8_t v___y_8146_; uint8_t v___y_8148_; uint8_t v___y_8149_; uint8_t v___y_8150_; uint8_t v___y_8151_; uint8_t v___y_8152_; uint64_t v___y_8153_; uint8_t v___y_8164_; uint8_t v___y_8165_; uint8_t v___y_8166_; uint64_t v___y_8167_; uint8_t v___y_8168_; uint8_t v___y_8169_; uint64_t v___y_8170_; uint8_t v___y_8175_; uint8_t v___y_8176_; uint8_t v___y_8177_; uint64_t v___y_8178_; uint8_t v___y_8179_; uint8_t v___y_8180_; uint64_t v___y_8181_; uint8_t v___y_8187_; uint8_t v___y_8188_; uint8_t v___y_8189_; uint64_t v___y_8190_; uint8_t v___y_8191_; uint8_t v___y_8192_; uint64_t v___y_8193_; uint8_t v___y_8198_; uint8_t v___y_8199_; uint8_t v___y_8200_; uint8_t v___y_8201_; uint8_t v___y_8202_; uint64_t v___y_8203_; uint64_t v___y_8204_; uint64_t v___y_8205_; uint8_t v___y_8206_; uint8_t v___y_8207_; uint8_t v___y_8209_; uint8_t v___y_8210_; uint8_t v___y_8211_; uint8_t v___y_8212_; uint64_t v___y_8213_; uint64_t v___y_8214_; uint64_t v___y_8215_; uint8_t v___y_8216_; uint8_t v___y_8217_; uint8_t v___y_8218_; uint8_t v___y_8219_; uint8_t v___y_8220_; uint8_t v___y_8222_; uint8_t v___y_8223_; uint8_t v___y_8224_; uint8_t v___y_8225_; uint8_t v___y_8226_; uint32_t v___y_8235_; uint8_t v___y_8236_; uint8_t v___y_8237_; uint32_t v___y_8238_; uint8_t v___y_8239_; uint32_t v___y_8262_; uint8_t v___y_8263_; uint32_t v___y_8264_; uint8_t v___y_8265_; uint32_t v___y_8271_; uint8_t v___y_8272_; uint32_t v___y_8273_; uint8_t v___y_8274_; uint32_t v___y_8280_; uint8_t v___y_8281_; uint32_t v___y_8282_; uint8_t v___y_8283_; uint32_t v___y_8289_; uint8_t v___y_8290_; uint8_t v___y_8291_; uint32_t v___y_8292_; uint32_t v___y_8298_; uint8_t v___y_8299_; uint8_t v___y_8300_; uint64_t v___y_8301_; uint8_t v___y_8307_; uint8_t v___y_8308_; uint32_t v___y_8309_; uint32_t v___y_8315_; uint8_t v___y_8316_; uint32_t v___y_8317_; uint32_t v___y_8332_; uint8_t v___y_8333_; uint64_t v___y_8334_; uint8_t v___y_8340_; uint32_t v___y_8341_; uint8_t v___y_8347_; uint8_t v___x_8362_; uint8_t v___x_8363_;
v___x_7706_ = 32ULL;
v___x_8362_ = 1;
v___x_8363_ = lean_uint8_dec_le(v_is32Bit_7697_, v___x_8362_);
if (v___x_8363_ == 0)
{
uint8_t v___x_8364_;
v___x_8364_ = 6;
v___y_8347_ = v___x_8364_;
goto v___jp_8346_;
}
else
{
uint64_t v___x_8365_; uint8_t v___x_8366_; uint8_t v___y_8373_; uint8_t v___y_8376_; uint8_t v___y_8395_; uint8_t v___y_8412_;
v___x_8365_ = 0ULL;
v___x_8366_ = lean_uint64_dec_eq(v_inLen_7694_, v___x_8365_);
if (v___x_8366_ == 0)
{
uint8_t v___x_8416_;
v___x_8416_ = lean_uint64_dec_eq(v_inPtr_7693_, v___x_8365_);
if (v___x_8416_ == 0)
{
v___y_8412_ = v___x_8363_;
goto v___jp_8411_;
}
else
{
uint8_t v___x_8417_;
v___x_8417_ = 7;
v___y_8347_ = v___x_8417_;
goto v___jp_8346_;
}
}
else
{
v___y_8412_ = v___x_8363_;
goto v___jp_8411_;
}
v___jp_8367_:
{
if (v___x_8366_ == 0)
{
uint8_t v___x_8368_;
v___x_8368_ = lean_uint64_dec_eq(v_outCap_7696_, v___x_8365_);
if (v___x_8368_ == 0)
{
uint8_t v___x_8369_;
v___x_8369_ = lean_uint64_dec_le(v_inLen_7694_, v_outPtr_7695_);
if (v___x_8369_ == 0)
{
goto v___jp_8356_;
}
else
{
uint64_t v___x_8370_; uint8_t v___x_8371_;
v___x_8370_ = lean_uint64_sub(v_outPtr_7695_, v_inLen_7694_);
v___x_8371_ = lean_uint64_dec_le(v_inPtr_7693_, v___x_8370_);
if (v___x_8371_ == 0)
{
goto v___jp_8356_;
}
else
{
goto v___jp_8352_;
}
}
}
else
{
goto v___jp_8352_;
}
}
else
{
goto v___jp_8352_;
}
}
v___jp_8372_:
{
if (v___y_8373_ == 0)
{
uint8_t v___x_8374_;
v___x_8374_ = 8;
v___y_8347_ = v___x_8374_;
goto v___jp_8346_;
}
else
{
goto v___jp_8367_;
}
}
v___jp_8375_:
{
if (v___y_8376_ == 0)
{
uint8_t v___x_8377_;
v___x_8377_ = 8;
v___y_8347_ = v___x_8377_;
goto v___jp_8346_;
}
else
{
uint8_t v___x_8378_;
v___x_8378_ = lean_uint8_dec_eq(v_is32Bit_7697_, v___x_8362_);
if (v___x_8378_ == 0)
{
uint8_t v___x_8379_;
v___x_8379_ = lean_uint64_dec_eq(v_outPtr_7695_, v___x_8365_);
if (v___x_8379_ == 0)
{
uint8_t v___x_8380_;
v___x_8380_ = lean_uint64_dec_eq(v_outCap_7696_, v___x_8365_);
if (v___x_8380_ == 0)
{
uint64_t v___x_8381_; uint64_t v___x_8382_; uint64_t v___x_8383_; uint64_t v___x_8384_; uint8_t v___x_8385_;
v___x_8381_ = 1ULL;
v___x_8382_ = lean_uint64_sub(v_outPtr_7695_, v___x_8381_);
v___x_8383_ = 18446744073709551615ULL;
v___x_8384_ = lean_uint64_sub(v___x_8383_, v_outCap_7696_);
v___x_8385_ = lean_uint64_dec_le(v___x_8382_, v___x_8384_);
v___y_8373_ = v___x_8385_;
goto v___jp_8372_;
}
else
{
goto v___jp_8367_;
}
}
else
{
goto v___jp_8367_;
}
}
else
{
uint64_t v___x_8386_; uint8_t v___x_8387_;
v___x_8386_ = 4294967295ULL;
v___x_8387_ = lean_uint64_dec_le(v_outPtr_7695_, v___x_8386_);
if (v___x_8387_ == 0)
{
uint8_t v___x_8388_;
v___x_8388_ = 8;
v___y_8347_ = v___x_8388_;
goto v___jp_8346_;
}
else
{
uint8_t v___x_8389_;
v___x_8389_ = lean_uint64_dec_le(v_outCap_7696_, v___x_8386_);
if (v___x_8389_ == 0)
{
uint8_t v___x_8390_;
v___x_8390_ = 8;
v___y_8347_ = v___x_8390_;
goto v___jp_8346_;
}
else
{
uint64_t v___x_8391_; uint64_t v___x_8392_; uint8_t v___x_8393_;
v___x_8391_ = lean_uint64_add(v_outPtr_7695_, v_outCap_7696_);
v___x_8392_ = 4294967296ULL;
v___x_8393_ = lean_uint64_dec_le(v___x_8391_, v___x_8392_);
v___y_8373_ = v___x_8393_;
goto v___jp_8372_;
}
}
}
}
}
v___jp_8394_:
{
uint8_t v___x_8396_;
v___x_8396_ = lean_uint8_dec_eq(v_is32Bit_7697_, v___x_8362_);
if (v___x_8396_ == 0)
{
uint8_t v___x_8397_;
v___x_8397_ = lean_uint64_dec_eq(v_inPtr_7693_, v___x_8365_);
if (v___x_8397_ == 0)
{
if (v___x_8366_ == 0)
{
uint64_t v___x_8398_; uint64_t v___x_8399_; uint64_t v___x_8400_; uint64_t v___x_8401_; uint8_t v___x_8402_;
v___x_8398_ = 1ULL;
v___x_8399_ = lean_uint64_sub(v_inPtr_7693_, v___x_8398_);
v___x_8400_ = 18446744073709551615ULL;
v___x_8401_ = lean_uint64_sub(v___x_8400_, v_inLen_7694_);
v___x_8402_ = lean_uint64_dec_le(v___x_8399_, v___x_8401_);
v___y_8376_ = v___x_8402_;
goto v___jp_8375_;
}
else
{
v___y_8376_ = v___y_8395_;
goto v___jp_8375_;
}
}
else
{
v___y_8376_ = v___y_8395_;
goto v___jp_8375_;
}
}
else
{
uint64_t v___x_8403_; uint8_t v___x_8404_;
v___x_8403_ = 4294967295ULL;
v___x_8404_ = lean_uint64_dec_le(v_inPtr_7693_, v___x_8403_);
if (v___x_8404_ == 0)
{
uint8_t v___x_8405_;
v___x_8405_ = 8;
v___y_8347_ = v___x_8405_;
goto v___jp_8346_;
}
else
{
uint8_t v___x_8406_;
v___x_8406_ = lean_uint64_dec_le(v_inLen_7694_, v___x_8403_);
if (v___x_8406_ == 0)
{
uint8_t v___x_8407_;
v___x_8407_ = 8;
v___y_8347_ = v___x_8407_;
goto v___jp_8346_;
}
else
{
uint64_t v___x_8408_; uint64_t v___x_8409_; uint8_t v___x_8410_;
v___x_8408_ = lean_uint64_add(v_inPtr_7693_, v_inLen_7694_);
v___x_8409_ = 4294967296ULL;
v___x_8410_ = lean_uint64_dec_le(v___x_8408_, v___x_8409_);
v___y_8376_ = v___x_8410_;
goto v___jp_8375_;
}
}
}
}
v___jp_8411_:
{
uint8_t v___x_8413_;
v___x_8413_ = lean_uint64_dec_eq(v_outCap_7696_, v___x_8365_);
if (v___x_8413_ == 0)
{
uint8_t v___x_8414_;
v___x_8414_ = lean_uint64_dec_eq(v_outPtr_7695_, v___x_8365_);
if (v___x_8414_ == 0)
{
v___y_8395_ = v___y_8412_;
goto v___jp_8394_;
}
else
{
uint8_t v___x_8415_;
v___x_8415_ = 7;
v___y_8347_ = v___x_8415_;
goto v___jp_8346_;
}
}
else
{
v___y_8395_ = v___x_8363_;
goto v___jp_8394_;
}
}
}
v___jp_7707_:
{
uint32_t v___x_7710_; uint32_t v_lo32_7711_; uint32_t v_hi32_7712_; uint64_t v___x_7713_; uint64_t v___x_7714_; uint64_t v___x_7715_; uint64_t v___x_7716_;
v___x_7710_ = 257;
v_lo32_7711_ = lean_uint32_lor(v___x_7710_, v___y_7709_);
v_hi32_7712_ = lean_uint64_to_uint32(v___y_7708_);
v___x_7713_ = lean_uint32_to_uint64(v_lo32_7711_);
v___x_7714_ = lean_uint32_to_uint64(v_hi32_7712_);
v___x_7715_ = lean_uint64_shift_left(v___x_7714_, v___x_7706_);
v___x_7716_ = lean_uint64_lor(v___x_7713_, v___x_7715_);
return v___x_7716_;
}
v___jp_7717_:
{
if (v___y_7718_ == 0)
{
uint32_t v___x_7720_;
v___x_7720_ = 0;
v___y_7708_ = v___y_7719_;
v___y_7709_ = v___x_7720_;
goto v___jp_7707_;
}
else
{
uint32_t v___x_7721_;
v___x_7721_ = 512;
v___y_7708_ = v___y_7719_;
v___y_7709_ = v___x_7721_;
goto v___jp_7707_;
}
}
v___jp_7722_:
{
uint64_t v___x_7726_; uint64_t v___x_7727_; uint8_t v___x_7728_;
v___x_7726_ = 9223372036854775808ULL;
v___x_7727_ = lean_uint64_add(v___y_7725_, v___x_7726_);
v___x_7728_ = lean_uint64_dec_lt(v___x_7726_, v___x_7727_);
if (v___x_7728_ == 0)
{
v___y_7718_ = v___y_7723_;
v___y_7719_ = v___y_7724_;
goto v___jp_7717_;
}
else
{
v___y_7718_ = v___y_7723_;
v___y_7719_ = v___y_7725_;
goto v___jp_7717_;
}
}
v___jp_7729_:
{
uint64_t v___x_7733_; uint64_t v___x_7734_; uint64_t v___x_7735_; uint8_t v___x_7736_;
v___x_7733_ = 9223372036854775808ULL;
v___x_7734_ = lean_uint64_add(v_arg_7705_, v___x_7733_);
v___x_7735_ = lean_uint64_add(v___y_7732_, v___x_7733_);
v___x_7736_ = lean_uint64_dec_le(v___x_7734_, v___x_7735_);
if (v___x_7736_ == 0)
{
v___y_7723_ = v___y_7730_;
v___y_7724_ = v___y_7731_;
v___y_7725_ = v___y_7732_;
goto v___jp_7722_;
}
else
{
v___y_7723_ = v___y_7730_;
v___y_7724_ = v___y_7731_;
v___y_7725_ = v_arg_7705_;
goto v___jp_7722_;
}
}
v___jp_7737_:
{
uint64_t v___x_7741_; uint64_t v___x_7742_; uint8_t v___x_7743_;
v___x_7741_ = 9223372036854775808ULL;
v___x_7742_ = lean_uint64_add(v___y_7740_, v___x_7741_);
v___x_7743_ = lean_uint64_dec_lt(v___x_7741_, v___x_7742_);
if (v___x_7743_ == 0)
{
v___y_7730_ = v___y_7738_;
v___y_7731_ = v___y_7739_;
v___y_7732_ = v___y_7739_;
goto v___jp_7729_;
}
else
{
v___y_7730_ = v___y_7738_;
v___y_7731_ = v___y_7739_;
v___y_7732_ = v___y_7740_;
goto v___jp_7729_;
}
}
v___jp_7744_:
{
if (v___y_7748_ == 0)
{
v___y_7738_ = v___y_7747_;
v___y_7739_ = v___y_7749_;
v___y_7740_ = v___y_7746_;
goto v___jp_7737_;
}
else
{
if (v___y_7750_ == 0)
{
v___y_7738_ = v___y_7747_;
v___y_7739_ = v___y_7749_;
v___y_7740_ = v___y_7745_;
goto v___jp_7737_;
}
else
{
v___y_7738_ = v___y_7747_;
v___y_7739_ = v___y_7749_;
v___y_7740_ = v___y_7746_;
goto v___jp_7737_;
}
}
}
v___jp_7751_:
{
if (v___y_7754_ == 0)
{
v___y_7738_ = v___y_7755_;
v___y_7739_ = v___y_7758_;
v___y_7740_ = v___y_7752_;
goto v___jp_7737_;
}
else
{
if (v___y_7756_ == 0)
{
v___y_7745_ = v___y_7752_;
v___y_7746_ = v___y_7753_;
v___y_7747_ = v___y_7755_;
v___y_7748_ = v___y_7757_;
v___y_7749_ = v___y_7758_;
v___y_7750_ = v___y_7759_;
goto v___jp_7744_;
}
else
{
if (v___y_7759_ == 0)
{
v___y_7738_ = v___y_7755_;
v___y_7739_ = v___y_7758_;
v___y_7740_ = v___y_7752_;
goto v___jp_7737_;
}
else
{
v___y_7745_ = v___y_7752_;
v___y_7746_ = v___y_7753_;
v___y_7747_ = v___y_7755_;
v___y_7748_ = v___y_7757_;
v___y_7749_ = v___y_7758_;
v___y_7750_ = v___y_7759_;
goto v___jp_7744_;
}
}
}
}
v___jp_7760_:
{
uint64_t v___x_7763_; uint64_t v_diff_7764_; uint64_t v___x_7765_; uint8_t v_aNeg_7766_; uint8_t v_bNeg_7767_; uint8_t v_dNeg_7768_;
v___x_7763_ = 0ULL;
v_diff_7764_ = lean_uint64_sub(v_height_7703_, v_client_7704_);
v___x_7765_ = 9223372036854775808ULL;
v_aNeg_7766_ = lean_uint64_dec_le(v___x_7765_, v_height_7703_);
v_bNeg_7767_ = lean_uint64_dec_le(v___x_7765_, v_client_7704_);
v_dNeg_7768_ = lean_uint64_dec_le(v___x_7765_, v_diff_7764_);
if (v_aNeg_7766_ == 0)
{
if (v_bNeg_7767_ == 0)
{
v___y_7752_ = v_diff_7764_;
v___y_7753_ = v___x_7765_;
v___y_7754_ = v_aNeg_7766_;
v___y_7755_ = v___y_7761_;
v___y_7756_ = v_bNeg_7767_;
v___y_7757_ = v_dNeg_7768_;
v___y_7758_ = v___x_7763_;
v___y_7759_ = v_bNeg_7767_;
goto v___jp_7751_;
}
else
{
if (v_dNeg_7768_ == 0)
{
v___y_7752_ = v_diff_7764_;
v___y_7753_ = v___x_7765_;
v___y_7754_ = v_aNeg_7766_;
v___y_7755_ = v___y_7761_;
v___y_7756_ = v_bNeg_7767_;
v___y_7757_ = v_dNeg_7768_;
v___y_7758_ = v___x_7763_;
v___y_7759_ = v_dNeg_7768_;
goto v___jp_7751_;
}
else
{
uint64_t v___x_7769_;
v___x_7769_ = 9223372036854775807ULL;
v___y_7738_ = v___y_7761_;
v___y_7739_ = v___x_7763_;
v___y_7740_ = v___x_7769_;
goto v___jp_7737_;
}
}
}
else
{
v___y_7752_ = v_diff_7764_;
v___y_7753_ = v___x_7765_;
v___y_7754_ = v_aNeg_7766_;
v___y_7755_ = v___y_7761_;
v___y_7756_ = v_bNeg_7767_;
v___y_7757_ = v_dNeg_7768_;
v___y_7758_ = v___x_7763_;
v___y_7759_ = v___y_7762_;
goto v___jp_7751_;
}
}
v___jp_7770_:
{
uint64_t v___x_7774_; uint64_t v___x_7775_; uint8_t v___x_7776_;
v___x_7774_ = 9223372036854775808ULL;
v___x_7775_ = lean_uint64_add(v___y_7773_, v___x_7774_);
v___x_7776_ = lean_uint64_dec_lt(v___x_7774_, v___x_7775_);
if (v___x_7776_ == 0)
{
v___y_7718_ = v___y_7772_;
v___y_7719_ = v___y_7771_;
goto v___jp_7717_;
}
else
{
v___y_7718_ = v___y_7772_;
v___y_7719_ = v___y_7773_;
goto v___jp_7717_;
}
}
v___jp_7777_:
{
if (v___y_7781_ == 0)
{
v___y_7771_ = v___y_7778_;
v___y_7772_ = v___y_7782_;
v___y_7773_ = v___y_7783_;
goto v___jp_7770_;
}
else
{
if (v___y_7780_ == 0)
{
v___y_7771_ = v___y_7778_;
v___y_7772_ = v___y_7782_;
v___y_7773_ = v___y_7779_;
goto v___jp_7770_;
}
else
{
v___y_7771_ = v___y_7778_;
v___y_7772_ = v___y_7782_;
v___y_7773_ = v___y_7783_;
goto v___jp_7770_;
}
}
}
v___jp_7784_:
{
if (v___y_7787_ == 0)
{
v___y_7771_ = v___y_7785_;
v___y_7772_ = v___y_7789_;
v___y_7773_ = v___y_7786_;
goto v___jp_7770_;
}
else
{
if (v___y_7790_ == 0)
{
v___y_7778_ = v___y_7785_;
v___y_7779_ = v___y_7786_;
v___y_7780_ = v___y_7792_;
v___y_7781_ = v___y_7788_;
v___y_7782_ = v___y_7789_;
v___y_7783_ = v___y_7791_;
goto v___jp_7777_;
}
else
{
if (v___y_7792_ == 0)
{
v___y_7771_ = v___y_7785_;
v___y_7772_ = v___y_7789_;
v___y_7773_ = v___y_7786_;
goto v___jp_7770_;
}
else
{
v___y_7778_ = v___y_7785_;
v___y_7779_ = v___y_7786_;
v___y_7780_ = v___y_7792_;
v___y_7781_ = v___y_7788_;
v___y_7782_ = v___y_7789_;
v___y_7783_ = v___y_7791_;
goto v___jp_7777_;
}
}
}
}
v___jp_7793_:
{
uint64_t v___x_7797_; uint64_t v___x_7798_; uint8_t v___x_7799_;
v___x_7797_ = 9223372036854775808ULL;
v___x_7798_ = lean_uint64_add(v___y_7796_, v___x_7797_);
v___x_7799_ = lean_uint64_dec_lt(v___x_7797_, v___x_7798_);
if (v___x_7799_ == 0)
{
v___y_7718_ = v___y_7794_;
v___y_7719_ = v___y_7795_;
goto v___jp_7717_;
}
else
{
v___y_7718_ = v___y_7794_;
v___y_7719_ = v___y_7796_;
goto v___jp_7717_;
}
}
v___jp_7800_:
{
uint64_t v___x_7805_; uint64_t v___x_7806_; uint64_t v___x_7807_; uint8_t v___x_7808_;
v___x_7805_ = 9223372036854775808ULL;
v___x_7806_ = lean_uint64_add(v___y_7801_, v___x_7805_);
v___x_7807_ = lean_uint64_add(v___y_7804_, v___x_7805_);
v___x_7808_ = lean_uint64_dec_le(v___x_7806_, v___x_7807_);
if (v___x_7808_ == 0)
{
v___y_7794_ = v___y_7802_;
v___y_7795_ = v___y_7803_;
v___y_7796_ = v___y_7804_;
goto v___jp_7793_;
}
else
{
v___y_7794_ = v___y_7802_;
v___y_7795_ = v___y_7803_;
v___y_7796_ = v___y_7801_;
goto v___jp_7793_;
}
}
v___jp_7809_:
{
uint64_t v___x_7814_; uint64_t v___x_7815_; uint8_t v___x_7816_;
v___x_7814_ = 9223372036854775808ULL;
v___x_7815_ = lean_uint64_add(v___y_7813_, v___x_7814_);
v___x_7816_ = lean_uint64_dec_lt(v___x_7814_, v___x_7815_);
if (v___x_7816_ == 0)
{
v___y_7801_ = v___y_7810_;
v___y_7802_ = v___y_7811_;
v___y_7803_ = v___y_7812_;
v___y_7804_ = v___y_7812_;
goto v___jp_7800_;
}
else
{
v___y_7801_ = v___y_7810_;
v___y_7802_ = v___y_7811_;
v___y_7803_ = v___y_7812_;
v___y_7804_ = v___y_7813_;
goto v___jp_7800_;
}
}
v___jp_7817_:
{
if (v___y_7820_ == 0)
{
v___y_7810_ = v___y_7819_;
v___y_7811_ = v___y_7821_;
v___y_7812_ = v___y_7824_;
v___y_7813_ = v___y_7823_;
goto v___jp_7809_;
}
else
{
if (v___y_7822_ == 0)
{
v___y_7810_ = v___y_7819_;
v___y_7811_ = v___y_7821_;
v___y_7812_ = v___y_7824_;
v___y_7813_ = v___y_7818_;
goto v___jp_7809_;
}
else
{
v___y_7810_ = v___y_7819_;
v___y_7811_ = v___y_7821_;
v___y_7812_ = v___y_7824_;
v___y_7813_ = v___y_7823_;
goto v___jp_7809_;
}
}
}
v___jp_7825_:
{
if (v___y_7831_ == 0)
{
v___y_7810_ = v___y_7827_;
v___y_7811_ = v___y_7830_;
v___y_7812_ = v___y_7833_;
v___y_7813_ = v___y_7826_;
goto v___jp_7809_;
}
else
{
if (v___y_7828_ == 0)
{
v___y_7818_ = v___y_7826_;
v___y_7819_ = v___y_7827_;
v___y_7820_ = v___y_7829_;
v___y_7821_ = v___y_7830_;
v___y_7822_ = v___y_7834_;
v___y_7823_ = v___y_7832_;
v___y_7824_ = v___y_7833_;
goto v___jp_7817_;
}
else
{
if (v___y_7834_ == 0)
{
v___y_7810_ = v___y_7827_;
v___y_7811_ = v___y_7830_;
v___y_7812_ = v___y_7833_;
v___y_7813_ = v___y_7826_;
goto v___jp_7809_;
}
else
{
v___y_7818_ = v___y_7826_;
v___y_7819_ = v___y_7827_;
v___y_7820_ = v___y_7829_;
v___y_7821_ = v___y_7830_;
v___y_7822_ = v___y_7834_;
v___y_7823_ = v___y_7832_;
v___y_7824_ = v___y_7833_;
goto v___jp_7817_;
}
}
}
}
v___jp_7835_:
{
uint64_t v___x_7839_; uint64_t v_diff_7840_; uint64_t v___x_7841_; uint8_t v_aNeg_7842_; uint8_t v_bNeg_7843_; uint8_t v_dNeg_7844_;
v___x_7839_ = 0ULL;
v_diff_7840_ = lean_uint64_sub(v_height_7703_, v_client_7704_);
v___x_7841_ = 9223372036854775808ULL;
v_aNeg_7842_ = lean_uint64_dec_le(v___x_7841_, v_height_7703_);
v_bNeg_7843_ = lean_uint64_dec_le(v___x_7841_, v_client_7704_);
v_dNeg_7844_ = lean_uint64_dec_le(v___x_7841_, v_diff_7840_);
if (v_aNeg_7842_ == 0)
{
if (v_bNeg_7843_ == 0)
{
v___y_7826_ = v_diff_7840_;
v___y_7827_ = v___y_7838_;
v___y_7828_ = v_bNeg_7843_;
v___y_7829_ = v_dNeg_7844_;
v___y_7830_ = v___y_7837_;
v___y_7831_ = v_aNeg_7842_;
v___y_7832_ = v___x_7841_;
v___y_7833_ = v___x_7839_;
v___y_7834_ = v_bNeg_7843_;
goto v___jp_7825_;
}
else
{
if (v_dNeg_7844_ == 0)
{
v___y_7826_ = v_diff_7840_;
v___y_7827_ = v___y_7838_;
v___y_7828_ = v_bNeg_7843_;
v___y_7829_ = v_dNeg_7844_;
v___y_7830_ = v___y_7837_;
v___y_7831_ = v_aNeg_7842_;
v___y_7832_ = v___x_7841_;
v___y_7833_ = v___x_7839_;
v___y_7834_ = v_dNeg_7844_;
goto v___jp_7825_;
}
else
{
uint64_t v___x_7845_;
v___x_7845_ = 9223372036854775807ULL;
v___y_7810_ = v___y_7838_;
v___y_7811_ = v___y_7837_;
v___y_7812_ = v___x_7839_;
v___y_7813_ = v___x_7845_;
goto v___jp_7809_;
}
}
}
else
{
v___y_7826_ = v_diff_7840_;
v___y_7827_ = v___y_7838_;
v___y_7828_ = v_bNeg_7843_;
v___y_7829_ = v_dNeg_7844_;
v___y_7830_ = v___y_7837_;
v___y_7831_ = v_aNeg_7842_;
v___y_7832_ = v___x_7841_;
v___y_7833_ = v___x_7839_;
v___y_7834_ = v___y_7836_;
goto v___jp_7825_;
}
}
v___jp_7846_:
{
if (v___y_7848_ == 0)
{
v___y_7836_ = v___y_7849_;
v___y_7837_ = v___y_7852_;
v___y_7838_ = v___y_7850_;
goto v___jp_7835_;
}
else
{
if (v___y_7847_ == 0)
{
v___y_7836_ = v___y_7849_;
v___y_7837_ = v___y_7852_;
v___y_7838_ = v___y_7850_;
goto v___jp_7835_;
}
else
{
if (v___y_7851_ == 0)
{
v___y_7836_ = v___y_7849_;
v___y_7837_ = v___y_7852_;
v___y_7838_ = v___y_7853_;
goto v___jp_7835_;
}
else
{
if (v___y_7854_ == 0)
{
v___y_7836_ = v___y_7849_;
v___y_7837_ = v___y_7852_;
v___y_7838_ = v___y_7850_;
goto v___jp_7835_;
}
else
{
v___y_7836_ = v___y_7849_;
v___y_7837_ = v___y_7852_;
v___y_7838_ = v___y_7853_;
goto v___jp_7835_;
}
}
}
}
}
v___jp_7855_:
{
uint64_t v___x_7859_; uint64_t v___x_7860_; uint8_t v___x_7861_;
v___x_7859_ = 9223372036854775808ULL;
v___x_7860_ = lean_uint64_add(v___y_7858_, v___x_7859_);
v___x_7861_ = lean_uint64_dec_lt(v___x_7859_, v___x_7860_);
if (v___x_7861_ == 0)
{
v___y_7718_ = v___y_7857_;
v___y_7719_ = v___y_7856_;
goto v___jp_7717_;
}
else
{
v___y_7718_ = v___y_7857_;
v___y_7719_ = v___y_7858_;
goto v___jp_7717_;
}
}
v___jp_7862_:
{
if (v___y_7867_ == 0)
{
v___y_7856_ = v___y_7866_;
v___y_7857_ = v___y_7868_;
v___y_7858_ = v___y_7864_;
goto v___jp_7855_;
}
else
{
if (v___y_7865_ == 0)
{
v___y_7856_ = v___y_7866_;
v___y_7857_ = v___y_7868_;
v___y_7858_ = v___y_7863_;
goto v___jp_7855_;
}
else
{
v___y_7856_ = v___y_7866_;
v___y_7857_ = v___y_7868_;
v___y_7858_ = v___y_7864_;
goto v___jp_7855_;
}
}
}
v___jp_7869_:
{
if (v___y_7876_ == 0)
{
v___y_7856_ = v___y_7873_;
v___y_7857_ = v___y_7875_;
v___y_7858_ = v___y_7870_;
goto v___jp_7855_;
}
else
{
if (v___y_7874_ == 0)
{
v___y_7863_ = v___y_7870_;
v___y_7864_ = v___y_7871_;
v___y_7865_ = v___y_7877_;
v___y_7866_ = v___y_7873_;
v___y_7867_ = v___y_7872_;
v___y_7868_ = v___y_7875_;
goto v___jp_7862_;
}
else
{
if (v___y_7877_ == 0)
{
v___y_7856_ = v___y_7873_;
v___y_7857_ = v___y_7875_;
v___y_7858_ = v___y_7870_;
goto v___jp_7855_;
}
else
{
v___y_7863_ = v___y_7870_;
v___y_7864_ = v___y_7871_;
v___y_7865_ = v___y_7877_;
v___y_7866_ = v___y_7873_;
v___y_7867_ = v___y_7872_;
v___y_7868_ = v___y_7875_;
goto v___jp_7862_;
}
}
}
}
v___jp_7878_:
{
uint8_t v___x_7882_;
v___x_7882_ = lean_uint8_dec_eq(v_opKind_7698_, v___y_7879_);
if (v___x_7882_ == 0)
{
uint8_t v___x_7883_; uint8_t v___x_7884_;
v___x_7883_ = 1;
v___x_7884_ = lean_uint8_dec_eq(v_opKind_7698_, v___x_7883_);
if (v___x_7884_ == 0)
{
uint8_t v___x_7885_; uint8_t v___x_7886_;
v___x_7885_ = 2;
v___x_7886_ = lean_uint8_dec_eq(v_opKind_7698_, v___x_7885_);
if (v___x_7886_ == 0)
{
uint64_t v___x_7887_; uint64_t v_diff_7888_; uint64_t v___x_7889_; uint8_t v_aNeg_7890_; uint8_t v_bNeg_7891_; uint8_t v_dNeg_7892_;
v___x_7887_ = 0ULL;
v_diff_7888_ = lean_uint64_sub(v_height_7703_, v_client_7704_);
v___x_7889_ = 9223372036854775808ULL;
v_aNeg_7890_ = lean_uint64_dec_le(v___x_7889_, v_height_7703_);
v_bNeg_7891_ = lean_uint64_dec_le(v___x_7889_, v_client_7704_);
v_dNeg_7892_ = lean_uint64_dec_le(v___x_7889_, v_diff_7888_);
if (v_aNeg_7890_ == 0)
{
if (v_bNeg_7891_ == 0)
{
v___y_7785_ = v___x_7887_;
v___y_7786_ = v_diff_7888_;
v___y_7787_ = v_aNeg_7890_;
v___y_7788_ = v_dNeg_7892_;
v___y_7789_ = v___y_7881_;
v___y_7790_ = v_bNeg_7891_;
v___y_7791_ = v___x_7889_;
v___y_7792_ = v_bNeg_7891_;
goto v___jp_7784_;
}
else
{
if (v_dNeg_7892_ == 0)
{
v___y_7785_ = v___x_7887_;
v___y_7786_ = v_diff_7888_;
v___y_7787_ = v_aNeg_7890_;
v___y_7788_ = v_dNeg_7892_;
v___y_7789_ = v___y_7881_;
v___y_7790_ = v_bNeg_7891_;
v___y_7791_ = v___x_7889_;
v___y_7792_ = v_dNeg_7892_;
goto v___jp_7784_;
}
else
{
uint64_t v___x_7893_;
v___x_7893_ = 9223372036854775807ULL;
v___y_7771_ = v___x_7887_;
v___y_7772_ = v___y_7881_;
v___y_7773_ = v___x_7893_;
goto v___jp_7770_;
}
}
}
else
{
v___y_7785_ = v___x_7887_;
v___y_7786_ = v_diff_7888_;
v___y_7787_ = v_aNeg_7890_;
v___y_7788_ = v_dNeg_7892_;
v___y_7789_ = v___y_7881_;
v___y_7790_ = v_bNeg_7891_;
v___y_7791_ = v___x_7889_;
v___y_7792_ = v___x_7886_;
goto v___jp_7784_;
}
}
else
{
v___y_7761_ = v___y_7881_;
v___y_7762_ = v___x_7882_;
goto v___jp_7760_;
}
}
else
{
v___y_7761_ = v___y_7881_;
v___y_7762_ = v___x_7882_;
goto v___jp_7760_;
}
}
else
{
uint8_t v___x_7894_; uint8_t v___x_7895_;
v___x_7894_ = 1;
v___x_7895_ = lean_uint8_dec_eq(v_pinned_7699_, v___x_7894_);
if (v___x_7895_ == 0)
{
uint64_t v_sum_7896_; uint64_t v___x_7897_; uint8_t v_aNeg_7898_; uint8_t v_bNeg_7899_; uint8_t v_sNeg_7900_;
v_sum_7896_ = lean_uint64_add(v_curTop_7702_, v_arg_7705_);
v___x_7897_ = 9223372036854775808ULL;
v_aNeg_7898_ = lean_uint64_dec_le(v___x_7897_, v_curTop_7702_);
v_bNeg_7899_ = lean_uint64_dec_le(v___x_7897_, v_arg_7705_);
v_sNeg_7900_ = lean_uint64_dec_le(v___x_7897_, v_sum_7896_);
if (v_aNeg_7898_ == 0)
{
if (v_bNeg_7899_ == 0)
{
if (v_sNeg_7900_ == 0)
{
v___y_7847_ = v_bNeg_7899_;
v___y_7848_ = v_aNeg_7898_;
v___y_7849_ = v___x_7895_;
v___y_7850_ = v_sum_7896_;
v___y_7851_ = v_sNeg_7900_;
v___y_7852_ = v___y_7881_;
v___y_7853_ = v___x_7897_;
v___y_7854_ = v_sNeg_7900_;
goto v___jp_7846_;
}
else
{
uint64_t v___x_7901_;
v___x_7901_ = 9223372036854775807ULL;
v___y_7836_ = v___x_7895_;
v___y_7837_ = v___y_7881_;
v___y_7838_ = v___x_7901_;
goto v___jp_7835_;
}
}
else
{
v___y_7847_ = v_bNeg_7899_;
v___y_7848_ = v_aNeg_7898_;
v___y_7849_ = v___x_7895_;
v___y_7850_ = v_sum_7896_;
v___y_7851_ = v_sNeg_7900_;
v___y_7852_ = v___y_7881_;
v___y_7853_ = v___x_7897_;
v___y_7854_ = v_aNeg_7898_;
goto v___jp_7846_;
}
}
else
{
v___y_7847_ = v_bNeg_7899_;
v___y_7848_ = v_aNeg_7898_;
v___y_7849_ = v___x_7895_;
v___y_7850_ = v_sum_7896_;
v___y_7851_ = v_sNeg_7900_;
v___y_7852_ = v___y_7881_;
v___y_7853_ = v___x_7897_;
v___y_7854_ = v___x_7895_;
goto v___jp_7846_;
}
}
else
{
uint64_t v___x_7902_; uint64_t v_diff_7903_; uint64_t v___x_7904_; uint8_t v_aNeg_7905_; uint8_t v_bNeg_7906_; uint8_t v_dNeg_7907_;
v___x_7902_ = 0ULL;
v_diff_7903_ = lean_uint64_sub(v_height_7703_, v_client_7704_);
v___x_7904_ = 9223372036854775808ULL;
v_aNeg_7905_ = lean_uint64_dec_le(v___x_7904_, v_height_7703_);
v_bNeg_7906_ = lean_uint64_dec_le(v___x_7904_, v_client_7704_);
v_dNeg_7907_ = lean_uint64_dec_le(v___x_7904_, v_diff_7903_);
if (v_aNeg_7905_ == 0)
{
if (v_bNeg_7906_ == 0)
{
v___y_7870_ = v_diff_7903_;
v___y_7871_ = v___x_7904_;
v___y_7872_ = v_dNeg_7907_;
v___y_7873_ = v___x_7902_;
v___y_7874_ = v_bNeg_7906_;
v___y_7875_ = v___y_7881_;
v___y_7876_ = v_aNeg_7905_;
v___y_7877_ = v_bNeg_7906_;
goto v___jp_7869_;
}
else
{
if (v_dNeg_7907_ == 0)
{
v___y_7870_ = v_diff_7903_;
v___y_7871_ = v___x_7904_;
v___y_7872_ = v_dNeg_7907_;
v___y_7873_ = v___x_7902_;
v___y_7874_ = v_bNeg_7906_;
v___y_7875_ = v___y_7881_;
v___y_7876_ = v_aNeg_7905_;
v___y_7877_ = v_dNeg_7907_;
goto v___jp_7869_;
}
else
{
uint64_t v___x_7908_;
v___x_7908_ = 9223372036854775807ULL;
v___y_7856_ = v___x_7902_;
v___y_7857_ = v___y_7881_;
v___y_7858_ = v___x_7908_;
goto v___jp_7855_;
}
}
}
else
{
v___y_7870_ = v_diff_7903_;
v___y_7871_ = v___x_7904_;
v___y_7872_ = v_dNeg_7907_;
v___y_7873_ = v___x_7902_;
v___y_7874_ = v_bNeg_7906_;
v___y_7875_ = v___y_7881_;
v___y_7876_ = v_aNeg_7905_;
v___y_7877_ = v___y_7880_;
goto v___jp_7869_;
}
}
}
}
v___jp_7909_:
{
uint64_t v___x_7915_; uint64_t v___x_7916_; uint64_t v___x_7917_; uint8_t v___x_7918_;
v___x_7915_ = 9223372036854775808ULL;
v___x_7916_ = 9223372036854775832ULL;
v___x_7917_ = lean_uint64_add(v___y_7914_, v___x_7915_);
v___x_7918_ = lean_uint64_dec_le(v___x_7916_, v___x_7917_);
if (v___x_7918_ == 0)
{
v___y_7879_ = v___y_7912_;
v___y_7880_ = v___y_7913_;
v___y_7881_ = v___y_7911_;
goto v___jp_7878_;
}
else
{
v___y_7879_ = v___y_7912_;
v___y_7880_ = v___y_7913_;
v___y_7881_ = v___y_7910_;
goto v___jp_7878_;
}
}
v___jp_7919_:
{
if (v___y_7923_ == 0)
{
v___y_7910_ = v___y_7920_;
v___y_7911_ = v___y_7922_;
v___y_7912_ = v___y_7924_;
v___y_7913_ = v___y_7927_;
v___y_7914_ = v___y_7921_;
goto v___jp_7909_;
}
else
{
if (v___y_7925_ == 0)
{
v___y_7910_ = v___y_7920_;
v___y_7911_ = v___y_7922_;
v___y_7912_ = v___y_7924_;
v___y_7913_ = v___y_7927_;
v___y_7914_ = v___y_7926_;
goto v___jp_7909_;
}
else
{
v___y_7910_ = v___y_7920_;
v___y_7911_ = v___y_7922_;
v___y_7912_ = v___y_7924_;
v___y_7913_ = v___y_7927_;
v___y_7914_ = v___y_7921_;
goto v___jp_7909_;
}
}
}
v___jp_7928_:
{
if (v___y_7934_ == 0)
{
v___y_7910_ = v___y_7930_;
v___y_7911_ = v___y_7931_;
v___y_7912_ = v___y_7935_;
v___y_7913_ = v___y_7936_;
v___y_7914_ = v___y_7937_;
goto v___jp_7909_;
}
else
{
if (v___y_7932_ == 0)
{
v___y_7920_ = v___y_7930_;
v___y_7921_ = v___y_7929_;
v___y_7922_ = v___y_7931_;
v___y_7923_ = v___y_7933_;
v___y_7924_ = v___y_7935_;
v___y_7925_ = v___y_7938_;
v___y_7926_ = v___y_7937_;
v___y_7927_ = v___y_7936_;
goto v___jp_7919_;
}
else
{
if (v___y_7938_ == 0)
{
v___y_7910_ = v___y_7930_;
v___y_7911_ = v___y_7931_;
v___y_7912_ = v___y_7935_;
v___y_7913_ = v___y_7936_;
v___y_7914_ = v___y_7937_;
goto v___jp_7909_;
}
else
{
v___y_7920_ = v___y_7930_;
v___y_7921_ = v___y_7929_;
v___y_7922_ = v___y_7931_;
v___y_7923_ = v___y_7933_;
v___y_7924_ = v___y_7935_;
v___y_7925_ = v___y_7938_;
v___y_7926_ = v___y_7937_;
v___y_7927_ = v___y_7936_;
goto v___jp_7919_;
}
}
}
}
v___jp_7939_:
{
uint64_t v_diff_7945_; uint64_t v___x_7946_; uint8_t v_aNeg_7947_; uint8_t v_bNeg_7948_; uint8_t v_dNeg_7949_;
v_diff_7945_ = lean_uint64_sub(v___y_7944_, v_client_7704_);
v___x_7946_ = 9223372036854775808ULL;
v_aNeg_7947_ = lean_uint64_dec_le(v___x_7946_, v___y_7944_);
v_bNeg_7948_ = lean_uint64_dec_le(v___x_7946_, v_client_7704_);
v_dNeg_7949_ = lean_uint64_dec_le(v___x_7946_, v_diff_7945_);
if (v_aNeg_7947_ == 0)
{
if (v_bNeg_7948_ == 0)
{
v___y_7929_ = v___x_7946_;
v___y_7930_ = v___y_7940_;
v___y_7931_ = v___y_7941_;
v___y_7932_ = v_bNeg_7948_;
v___y_7933_ = v_dNeg_7949_;
v___y_7934_ = v_aNeg_7947_;
v___y_7935_ = v___y_7942_;
v___y_7936_ = v___y_7943_;
v___y_7937_ = v_diff_7945_;
v___y_7938_ = v_bNeg_7948_;
goto v___jp_7928_;
}
else
{
if (v_dNeg_7949_ == 0)
{
v___y_7929_ = v___x_7946_;
v___y_7930_ = v___y_7940_;
v___y_7931_ = v___y_7941_;
v___y_7932_ = v_bNeg_7948_;
v___y_7933_ = v_dNeg_7949_;
v___y_7934_ = v_aNeg_7947_;
v___y_7935_ = v___y_7942_;
v___y_7936_ = v___y_7943_;
v___y_7937_ = v_diff_7945_;
v___y_7938_ = v_dNeg_7949_;
goto v___jp_7928_;
}
else
{
uint64_t v___x_7950_;
v___x_7950_ = 9223372036854775807ULL;
v___y_7910_ = v___y_7940_;
v___y_7911_ = v___y_7941_;
v___y_7912_ = v___y_7942_;
v___y_7913_ = v___y_7943_;
v___y_7914_ = v___x_7950_;
goto v___jp_7909_;
}
}
}
else
{
v___y_7929_ = v___x_7946_;
v___y_7930_ = v___y_7940_;
v___y_7931_ = v___y_7941_;
v___y_7932_ = v_bNeg_7948_;
v___y_7933_ = v_dNeg_7949_;
v___y_7934_ = v_aNeg_7947_;
v___y_7935_ = v___y_7942_;
v___y_7936_ = v___y_7943_;
v___y_7937_ = v_diff_7945_;
v___y_7938_ = v___y_7940_;
goto v___jp_7928_;
}
}
v___jp_7951_:
{
if (v___y_7955_ == 0)
{
v___y_7940_ = v___y_7952_;
v___y_7941_ = v___y_7953_;
v___y_7942_ = v___y_7957_;
v___y_7943_ = v___y_7959_;
v___y_7944_ = v___y_7958_;
goto v___jp_7939_;
}
else
{
if (v___y_7956_ == 0)
{
v___y_7940_ = v___y_7952_;
v___y_7941_ = v___y_7953_;
v___y_7942_ = v___y_7957_;
v___y_7943_ = v___y_7959_;
v___y_7944_ = v___y_7954_;
goto v___jp_7939_;
}
else
{
v___y_7940_ = v___y_7952_;
v___y_7941_ = v___y_7953_;
v___y_7942_ = v___y_7957_;
v___y_7943_ = v___y_7959_;
v___y_7944_ = v___y_7958_;
goto v___jp_7939_;
}
}
}
v___jp_7960_:
{
if (v___y_7966_ == 0)
{
v___y_7940_ = v___y_7962_;
v___y_7941_ = v___y_7963_;
v___y_7942_ = v___y_7968_;
v___y_7943_ = v___y_7969_;
v___y_7944_ = v___y_7964_;
goto v___jp_7939_;
}
else
{
if (v___y_7961_ == 0)
{
v___y_7952_ = v___y_7962_;
v___y_7953_ = v___y_7963_;
v___y_7954_ = v___y_7964_;
v___y_7955_ = v___y_7965_;
v___y_7956_ = v___y_7970_;
v___y_7957_ = v___y_7968_;
v___y_7958_ = v___y_7967_;
v___y_7959_ = v___y_7969_;
goto v___jp_7951_;
}
else
{
if (v___y_7970_ == 0)
{
v___y_7940_ = v___y_7962_;
v___y_7941_ = v___y_7963_;
v___y_7942_ = v___y_7968_;
v___y_7943_ = v___y_7969_;
v___y_7944_ = v___y_7964_;
goto v___jp_7939_;
}
else
{
v___y_7952_ = v___y_7962_;
v___y_7953_ = v___y_7963_;
v___y_7954_ = v___y_7964_;
v___y_7955_ = v___y_7965_;
v___y_7956_ = v___y_7970_;
v___y_7957_ = v___y_7968_;
v___y_7958_ = v___y_7967_;
v___y_7959_ = v___y_7969_;
goto v___jp_7951_;
}
}
}
}
v___jp_7971_:
{
if (v___y_7977_ == 0)
{
v___y_7879_ = v___y_7975_;
v___y_7880_ = v___y_7976_;
v___y_7881_ = v___y_7973_;
goto v___jp_7878_;
}
else
{
uint64_t v___x_7978_; uint64_t v___x_7979_; uint64_t v___x_7980_; uint8_t v___x_7981_;
v___x_7978_ = 9223372036854775808ULL;
v___x_7979_ = lean_uint64_add(v___y_7974_, v___x_7978_);
v___x_7980_ = lean_uint64_add(v_curTop_7702_, v___x_7978_);
v___x_7981_ = lean_uint64_dec_lt(v___x_7979_, v___x_7980_);
if (v___x_7981_ == 0)
{
v___y_7879_ = v___y_7975_;
v___y_7880_ = v___y_7976_;
v___y_7881_ = v___y_7973_;
goto v___jp_7878_;
}
else
{
uint64_t v_diff_7982_; uint8_t v_aNeg_7983_; uint8_t v_bNeg_7984_; uint8_t v_dNeg_7985_;
v_diff_7982_ = lean_uint64_sub(v_height_7703_, v___y_7974_);
v_aNeg_7983_ = lean_uint64_dec_le(v___x_7978_, v_height_7703_);
v_bNeg_7984_ = lean_uint64_dec_le(v___x_7978_, v___y_7974_);
v_dNeg_7985_ = lean_uint64_dec_le(v___x_7978_, v_diff_7982_);
if (v_aNeg_7983_ == 0)
{
if (v_bNeg_7984_ == 0)
{
v___y_7961_ = v_bNeg_7984_;
v___y_7962_ = v___y_7972_;
v___y_7963_ = v___y_7973_;
v___y_7964_ = v_diff_7982_;
v___y_7965_ = v_dNeg_7985_;
v___y_7966_ = v_aNeg_7983_;
v___y_7967_ = v___x_7978_;
v___y_7968_ = v___y_7975_;
v___y_7969_ = v___y_7976_;
v___y_7970_ = v_bNeg_7984_;
goto v___jp_7960_;
}
else
{
if (v_dNeg_7985_ == 0)
{
v___y_7961_ = v_bNeg_7984_;
v___y_7962_ = v___y_7972_;
v___y_7963_ = v___y_7973_;
v___y_7964_ = v_diff_7982_;
v___y_7965_ = v_dNeg_7985_;
v___y_7966_ = v_aNeg_7983_;
v___y_7967_ = v___x_7978_;
v___y_7968_ = v___y_7975_;
v___y_7969_ = v___y_7976_;
v___y_7970_ = v_dNeg_7985_;
goto v___jp_7960_;
}
else
{
uint64_t v___x_7986_;
v___x_7986_ = 9223372036854775807ULL;
v___y_7940_ = v___y_7972_;
v___y_7941_ = v___y_7973_;
v___y_7942_ = v___y_7975_;
v___y_7943_ = v___y_7976_;
v___y_7944_ = v___x_7986_;
goto v___jp_7939_;
}
}
}
else
{
v___y_7961_ = v_bNeg_7984_;
v___y_7962_ = v___y_7972_;
v___y_7963_ = v___y_7973_;
v___y_7964_ = v_diff_7982_;
v___y_7965_ = v_dNeg_7985_;
v___y_7966_ = v_aNeg_7983_;
v___y_7967_ = v___x_7978_;
v___y_7968_ = v___y_7975_;
v___y_7969_ = v___y_7976_;
v___y_7970_ = v___y_7972_;
goto v___jp_7960_;
}
}
}
}
v___jp_7987_:
{
if (v___y_7993_ == 0)
{
v___y_7972_ = v___y_7988_;
v___y_7973_ = v___y_7989_;
v___y_7974_ = v___y_7990_;
v___y_7975_ = v___y_7991_;
v___y_7976_ = v___y_7992_;
v___y_7977_ = v___y_7988_;
goto v___jp_7971_;
}
else
{
v___y_7972_ = v___y_7988_;
v___y_7973_ = v___y_7989_;
v___y_7974_ = v___y_7990_;
v___y_7975_ = v___y_7991_;
v___y_7976_ = v___y_7992_;
v___y_7977_ = v___y_7989_;
goto v___jp_7971_;
}
}
v___jp_7994_:
{
uint8_t v___x_8002_;
v___x_8002_ = lean_uint8_dec_eq(v_resized_7701_, v___y_7998_);
if (v___x_8002_ == 0)
{
v___y_7988_ = v___y_7996_;
v___y_7989_ = v___y_7997_;
v___y_7990_ = v___y_8001_;
v___y_7991_ = v___y_7999_;
v___y_7992_ = v___y_8000_;
v___y_7993_ = v___y_7995_;
goto v___jp_7987_;
}
else
{
v___y_7988_ = v___y_7996_;
v___y_7989_ = v___y_7997_;
v___y_7990_ = v___y_8001_;
v___y_7991_ = v___y_7999_;
v___y_7992_ = v___y_8000_;
v___y_7993_ = v___y_7996_;
goto v___jp_7987_;
}
}
v___jp_8003_:
{
uint64_t v___x_8012_; uint64_t v___x_8013_; uint8_t v___x_8014_;
v___x_8012_ = 9223372036854775808ULL;
v___x_8013_ = lean_uint64_add(v___y_8011_, v___x_8012_);
v___x_8014_ = lean_uint64_dec_lt(v___x_8012_, v___x_8013_);
if (v___x_8014_ == 0)
{
v___y_7995_ = v___y_8005_;
v___y_7996_ = v___y_8004_;
v___y_7997_ = v___y_8006_;
v___y_7998_ = v___y_8008_;
v___y_7999_ = v___y_8009_;
v___y_8000_ = v___y_8010_;
v___y_8001_ = v___y_8007_;
goto v___jp_7994_;
}
else
{
v___y_7995_ = v___y_8005_;
v___y_7996_ = v___y_8004_;
v___y_7997_ = v___y_8006_;
v___y_7998_ = v___y_8008_;
v___y_7999_ = v___y_8009_;
v___y_8000_ = v___y_8010_;
v___y_8001_ = v___y_8011_;
goto v___jp_7994_;
}
}
v___jp_8015_:
{
uint64_t v___x_8024_; uint64_t v___x_8025_; uint64_t v___x_8026_; uint8_t v___x_8027_;
v___x_8024_ = 9223372036854775808ULL;
v___x_8025_ = lean_uint64_add(v_arg_7705_, v___x_8024_);
v___x_8026_ = lean_uint64_add(v___y_8023_, v___x_8024_);
v___x_8027_ = lean_uint64_dec_le(v___x_8025_, v___x_8026_);
if (v___x_8027_ == 0)
{
v___y_8004_ = v___y_8017_;
v___y_8005_ = v___y_8016_;
v___y_8006_ = v___y_8018_;
v___y_8007_ = v___y_8019_;
v___y_8008_ = v___y_8020_;
v___y_8009_ = v___y_8021_;
v___y_8010_ = v___y_8022_;
v___y_8011_ = v___y_8023_;
goto v___jp_8003_;
}
else
{
v___y_8004_ = v___y_8017_;
v___y_8005_ = v___y_8016_;
v___y_8006_ = v___y_8018_;
v___y_8007_ = v___y_8019_;
v___y_8008_ = v___y_8020_;
v___y_8009_ = v___y_8021_;
v___y_8010_ = v___y_8022_;
v___y_8011_ = v_arg_7705_;
goto v___jp_8003_;
}
}
v___jp_8028_:
{
uint64_t v___x_8037_; uint64_t v___x_8038_; uint8_t v___x_8039_;
v___x_8037_ = 9223372036854775808ULL;
v___x_8038_ = lean_uint64_add(v___y_8036_, v___x_8037_);
v___x_8039_ = lean_uint64_dec_lt(v___x_8037_, v___x_8038_);
if (v___x_8039_ == 0)
{
v___y_8016_ = v___y_8030_;
v___y_8017_ = v___y_8029_;
v___y_8018_ = v___y_8031_;
v___y_8019_ = v___y_8032_;
v___y_8020_ = v___y_8033_;
v___y_8021_ = v___y_8034_;
v___y_8022_ = v___y_8035_;
v___y_8023_ = v___y_8032_;
goto v___jp_8015_;
}
else
{
v___y_8016_ = v___y_8030_;
v___y_8017_ = v___y_8029_;
v___y_8018_ = v___y_8031_;
v___y_8019_ = v___y_8032_;
v___y_8020_ = v___y_8033_;
v___y_8021_ = v___y_8034_;
v___y_8022_ = v___y_8035_;
v___y_8023_ = v___y_8036_;
goto v___jp_8015_;
}
}
v___jp_8040_:
{
if (v___y_8046_ == 0)
{
v___y_8029_ = v___y_8042_;
v___y_8030_ = v___y_8041_;
v___y_8031_ = v___y_8043_;
v___y_8032_ = v___y_8045_;
v___y_8033_ = v___y_8047_;
v___y_8034_ = v___y_8050_;
v___y_8035_ = v___y_8051_;
v___y_8036_ = v___y_8048_;
goto v___jp_8028_;
}
else
{
if (v___y_8044_ == 0)
{
v___y_8029_ = v___y_8042_;
v___y_8030_ = v___y_8041_;
v___y_8031_ = v___y_8043_;
v___y_8032_ = v___y_8045_;
v___y_8033_ = v___y_8047_;
v___y_8034_ = v___y_8050_;
v___y_8035_ = v___y_8051_;
v___y_8036_ = v___y_8049_;
goto v___jp_8028_;
}
else
{
v___y_8029_ = v___y_8042_;
v___y_8030_ = v___y_8041_;
v___y_8031_ = v___y_8043_;
v___y_8032_ = v___y_8045_;
v___y_8033_ = v___y_8047_;
v___y_8034_ = v___y_8050_;
v___y_8035_ = v___y_8051_;
v___y_8036_ = v___y_8048_;
goto v___jp_8028_;
}
}
}
v___jp_8052_:
{
if (v___y_8056_ == 0)
{
v___y_8029_ = v___y_8053_;
v___y_8030_ = v___y_8054_;
v___y_8031_ = v___y_8055_;
v___y_8032_ = v___y_8057_;
v___y_8033_ = v___y_8060_;
v___y_8034_ = v___y_8063_;
v___y_8035_ = v___y_8064_;
v___y_8036_ = v___y_8062_;
goto v___jp_8028_;
}
else
{
if (v___y_8058_ == 0)
{
v___y_8041_ = v___y_8054_;
v___y_8042_ = v___y_8053_;
v___y_8043_ = v___y_8055_;
v___y_8044_ = v___y_8065_;
v___y_8045_ = v___y_8057_;
v___y_8046_ = v___y_8059_;
v___y_8047_ = v___y_8060_;
v___y_8048_ = v___y_8061_;
v___y_8049_ = v___y_8062_;
v___y_8050_ = v___y_8063_;
v___y_8051_ = v___y_8064_;
goto v___jp_8040_;
}
else
{
if (v___y_8065_ == 0)
{
v___y_8029_ = v___y_8053_;
v___y_8030_ = v___y_8054_;
v___y_8031_ = v___y_8055_;
v___y_8032_ = v___y_8057_;
v___y_8033_ = v___y_8060_;
v___y_8034_ = v___y_8063_;
v___y_8035_ = v___y_8064_;
v___y_8036_ = v___y_8062_;
goto v___jp_8028_;
}
else
{
v___y_8041_ = v___y_8054_;
v___y_8042_ = v___y_8053_;
v___y_8043_ = v___y_8055_;
v___y_8044_ = v___y_8065_;
v___y_8045_ = v___y_8057_;
v___y_8046_ = v___y_8059_;
v___y_8047_ = v___y_8060_;
v___y_8048_ = v___y_8061_;
v___y_8049_ = v___y_8062_;
v___y_8050_ = v___y_8063_;
v___y_8051_ = v___y_8064_;
goto v___jp_8040_;
}
}
}
}
v___jp_8066_:
{
uint8_t v___x_8073_; uint8_t v___x_8074_;
v___x_8073_ = 2;
v___x_8074_ = lean_uint8_dec_eq(v_opKind_7698_, v___x_8073_);
if (v___x_8074_ == 0)
{
v___y_7879_ = v___y_8070_;
v___y_7880_ = v___y_8071_;
v___y_7881_ = v___y_8067_;
goto v___jp_7878_;
}
else
{
uint64_t v___x_8075_; uint64_t v_diff_8076_; uint64_t v___x_8077_; uint8_t v_aNeg_8078_; uint8_t v_bNeg_8079_; uint8_t v_dNeg_8080_;
v___x_8075_ = 0ULL;
v_diff_8076_ = lean_uint64_sub(v_height_7703_, v_client_7704_);
v___x_8077_ = 9223372036854775808ULL;
v_aNeg_8078_ = lean_uint64_dec_le(v___x_8077_, v_height_7703_);
v_bNeg_8079_ = lean_uint64_dec_le(v___x_8077_, v_client_7704_);
v_dNeg_8080_ = lean_uint64_dec_le(v___x_8077_, v_diff_8076_);
if (v_aNeg_8078_ == 0)
{
if (v_bNeg_8079_ == 0)
{
v___y_8053_ = v___y_8072_;
v___y_8054_ = v___x_8074_;
v___y_8055_ = v___y_8068_;
v___y_8056_ = v_aNeg_8078_;
v___y_8057_ = v___x_8075_;
v___y_8058_ = v_bNeg_8079_;
v___y_8059_ = v_dNeg_8080_;
v___y_8060_ = v___y_8069_;
v___y_8061_ = v___x_8077_;
v___y_8062_ = v_diff_8076_;
v___y_8063_ = v___y_8070_;
v___y_8064_ = v___y_8071_;
v___y_8065_ = v_bNeg_8079_;
goto v___jp_8052_;
}
else
{
if (v_dNeg_8080_ == 0)
{
v___y_8053_ = v___y_8072_;
v___y_8054_ = v___x_8074_;
v___y_8055_ = v___y_8068_;
v___y_8056_ = v_aNeg_8078_;
v___y_8057_ = v___x_8075_;
v___y_8058_ = v_bNeg_8079_;
v___y_8059_ = v_dNeg_8080_;
v___y_8060_ = v___y_8069_;
v___y_8061_ = v___x_8077_;
v___y_8062_ = v_diff_8076_;
v___y_8063_ = v___y_8070_;
v___y_8064_ = v___y_8071_;
v___y_8065_ = v_dNeg_8080_;
goto v___jp_8052_;
}
else
{
uint64_t v___x_8081_;
v___x_8081_ = 9223372036854775807ULL;
v___y_8029_ = v___y_8072_;
v___y_8030_ = v___x_8074_;
v___y_8031_ = v___y_8068_;
v___y_8032_ = v___x_8075_;
v___y_8033_ = v___y_8069_;
v___y_8034_ = v___y_8070_;
v___y_8035_ = v___y_8071_;
v___y_8036_ = v___x_8081_;
goto v___jp_8028_;
}
}
}
else
{
v___y_8053_ = v___y_8072_;
v___y_8054_ = v___x_8074_;
v___y_8055_ = v___y_8068_;
v___y_8056_ = v_aNeg_8078_;
v___y_8057_ = v___x_8075_;
v___y_8058_ = v_bNeg_8079_;
v___y_8059_ = v_dNeg_8080_;
v___y_8060_ = v___y_8069_;
v___y_8061_ = v___x_8077_;
v___y_8062_ = v_diff_8076_;
v___y_8063_ = v___y_8070_;
v___y_8064_ = v___y_8071_;
v___y_8065_ = v___y_8072_;
goto v___jp_8052_;
}
}
}
v___jp_8082_:
{
uint64_t v___x_8088_; uint64_t v___x_8089_; uint64_t v___x_8090_; uint8_t v___x_8091_;
v___x_8088_ = 9223372036854775808ULL;
v___x_8089_ = lean_uint64_add(v___y_8087_, v___x_8088_);
v___x_8090_ = 9223372036854775832ULL;
v___x_8091_ = lean_uint64_dec_lt(v___x_8089_, v___x_8090_);
if (v___x_8091_ == 0)
{
v___y_7879_ = v___y_8085_;
v___y_7880_ = v___y_8086_;
v___y_7881_ = v___y_8084_;
goto v___jp_7878_;
}
else
{
v___y_7879_ = v___y_8085_;
v___y_7880_ = v___y_8086_;
v___y_7881_ = v___y_8083_;
goto v___jp_7878_;
}
}
v___jp_8092_:
{
if (v___y_8093_ == 0)
{
v___y_8083_ = v___y_8095_;
v___y_8084_ = v___y_8094_;
v___y_8085_ = v___y_8099_;
v___y_8086_ = v___y_8100_;
v___y_8087_ = v___y_8097_;
goto v___jp_8082_;
}
else
{
if (v___y_8096_ == 0)
{
v___y_8083_ = v___y_8095_;
v___y_8084_ = v___y_8094_;
v___y_8085_ = v___y_8099_;
v___y_8086_ = v___y_8100_;
v___y_8087_ = v___y_8098_;
goto v___jp_8082_;
}
else
{
v___y_8083_ = v___y_8095_;
v___y_8084_ = v___y_8094_;
v___y_8085_ = v___y_8099_;
v___y_8086_ = v___y_8100_;
v___y_8087_ = v___y_8097_;
goto v___jp_8082_;
}
}
}
v___jp_8101_:
{
if (v___y_8107_ == 0)
{
v___y_8083_ = v___y_8103_;
v___y_8084_ = v___y_8104_;
v___y_8085_ = v___y_8109_;
v___y_8086_ = v___y_8110_;
v___y_8087_ = v___y_8106_;
goto v___jp_8082_;
}
else
{
if (v___y_8108_ == 0)
{
v___y_8093_ = v___y_8102_;
v___y_8094_ = v___y_8104_;
v___y_8095_ = v___y_8103_;
v___y_8096_ = v___y_8111_;
v___y_8097_ = v___y_8105_;
v___y_8098_ = v___y_8106_;
v___y_8099_ = v___y_8109_;
v___y_8100_ = v___y_8110_;
goto v___jp_8092_;
}
else
{
if (v___y_8111_ == 0)
{
v___y_8083_ = v___y_8103_;
v___y_8084_ = v___y_8104_;
v___y_8085_ = v___y_8109_;
v___y_8086_ = v___y_8110_;
v___y_8087_ = v___y_8106_;
goto v___jp_8082_;
}
else
{
v___y_8093_ = v___y_8102_;
v___y_8094_ = v___y_8104_;
v___y_8095_ = v___y_8103_;
v___y_8096_ = v___y_8111_;
v___y_8097_ = v___y_8105_;
v___y_8098_ = v___y_8106_;
v___y_8099_ = v___y_8109_;
v___y_8100_ = v___y_8110_;
goto v___jp_8092_;
}
}
}
}
v___jp_8112_:
{
uint64_t v_diff_8120_; uint8_t v_aNeg_8121_; uint8_t v_bNeg_8122_; uint8_t v_dNeg_8123_;
v_diff_8120_ = lean_uint64_sub(v___y_8119_, v_client_7704_);
v_aNeg_8121_ = lean_uint64_dec_le(v___y_8115_, v___y_8119_);
v_bNeg_8122_ = lean_uint64_dec_le(v___y_8115_, v_client_7704_);
v_dNeg_8123_ = lean_uint64_dec_le(v___y_8115_, v_diff_8120_);
if (v_aNeg_8121_ == 0)
{
if (v_bNeg_8122_ == 0)
{
v___y_8102_ = v_dNeg_8123_;
v___y_8103_ = v___y_8114_;
v___y_8104_ = v___y_8113_;
v___y_8105_ = v___y_8115_;
v___y_8106_ = v_diff_8120_;
v___y_8107_ = v_aNeg_8121_;
v___y_8108_ = v_bNeg_8122_;
v___y_8109_ = v___y_8117_;
v___y_8110_ = v___y_8118_;
v___y_8111_ = v_bNeg_8122_;
goto v___jp_8101_;
}
else
{
if (v_dNeg_8123_ == 0)
{
v___y_8102_ = v_dNeg_8123_;
v___y_8103_ = v___y_8114_;
v___y_8104_ = v___y_8113_;
v___y_8105_ = v___y_8115_;
v___y_8106_ = v_diff_8120_;
v___y_8107_ = v_aNeg_8121_;
v___y_8108_ = v_bNeg_8122_;
v___y_8109_ = v___y_8117_;
v___y_8110_ = v___y_8118_;
v___y_8111_ = v_dNeg_8123_;
goto v___jp_8101_;
}
else
{
uint64_t v___x_8124_;
v___x_8124_ = 9223372036854775807ULL;
v___y_8083_ = v___y_8114_;
v___y_8084_ = v___y_8113_;
v___y_8085_ = v___y_8117_;
v___y_8086_ = v___y_8118_;
v___y_8087_ = v___x_8124_;
goto v___jp_8082_;
}
}
}
else
{
v___y_8102_ = v_dNeg_8123_;
v___y_8103_ = v___y_8114_;
v___y_8104_ = v___y_8113_;
v___y_8105_ = v___y_8115_;
v___y_8106_ = v_diff_8120_;
v___y_8107_ = v_aNeg_8121_;
v___y_8108_ = v_bNeg_8122_;
v___y_8109_ = v___y_8117_;
v___y_8110_ = v___y_8118_;
v___y_8111_ = v___y_8116_;
goto v___jp_8101_;
}
}
v___jp_8125_:
{
if (v___y_8128_ == 0)
{
v___y_8113_ = v___y_8127_;
v___y_8114_ = v___y_8126_;
v___y_8115_ = v___y_8130_;
v___y_8116_ = v___y_8131_;
v___y_8117_ = v___y_8133_;
v___y_8118_ = v___y_8134_;
v___y_8119_ = v___y_8130_;
goto v___jp_8112_;
}
else
{
if (v___y_8132_ == 0)
{
v___y_8113_ = v___y_8127_;
v___y_8114_ = v___y_8126_;
v___y_8115_ = v___y_8130_;
v___y_8116_ = v___y_8131_;
v___y_8117_ = v___y_8133_;
v___y_8118_ = v___y_8134_;
v___y_8119_ = v___y_8129_;
goto v___jp_8112_;
}
else
{
v___y_8113_ = v___y_8127_;
v___y_8114_ = v___y_8126_;
v___y_8115_ = v___y_8130_;
v___y_8116_ = v___y_8131_;
v___y_8117_ = v___y_8133_;
v___y_8118_ = v___y_8134_;
v___y_8119_ = v___y_8130_;
goto v___jp_8112_;
}
}
}
v___jp_8135_:
{
if (v___y_8138_ == 0)
{
v___y_8113_ = v___y_8136_;
v___y_8114_ = v___y_8137_;
v___y_8115_ = v___y_8140_;
v___y_8116_ = v___y_8142_;
v___y_8117_ = v___y_8144_;
v___y_8118_ = v___y_8145_;
v___y_8119_ = v___y_8141_;
goto v___jp_8112_;
}
else
{
if (v___y_8143_ == 0)
{
v___y_8126_ = v___y_8137_;
v___y_8127_ = v___y_8136_;
v___y_8128_ = v___y_8139_;
v___y_8129_ = v___y_8141_;
v___y_8130_ = v___y_8140_;
v___y_8131_ = v___y_8142_;
v___y_8132_ = v___y_8146_;
v___y_8133_ = v___y_8144_;
v___y_8134_ = v___y_8145_;
goto v___jp_8125_;
}
else
{
if (v___y_8146_ == 0)
{
v___y_8113_ = v___y_8136_;
v___y_8114_ = v___y_8137_;
v___y_8115_ = v___y_8140_;
v___y_8116_ = v___y_8142_;
v___y_8117_ = v___y_8144_;
v___y_8118_ = v___y_8145_;
v___y_8119_ = v___y_8141_;
goto v___jp_8112_;
}
else
{
v___y_8126_ = v___y_8137_;
v___y_8127_ = v___y_8136_;
v___y_8128_ = v___y_8139_;
v___y_8129_ = v___y_8141_;
v___y_8130_ = v___y_8140_;
v___y_8131_ = v___y_8142_;
v___y_8132_ = v___y_8146_;
v___y_8133_ = v___y_8144_;
v___y_8134_ = v___y_8145_;
goto v___jp_8125_;
}
}
}
}
v___jp_8147_:
{
uint64_t v___x_8154_; uint64_t v___x_8155_; uint64_t v___x_8156_; uint8_t v___x_8157_;
v___x_8154_ = 9223372036854775808ULL;
v___x_8155_ = lean_uint64_add(v___y_8153_, v___x_8154_);
v___x_8156_ = lean_uint64_add(v_curTop_7702_, v___x_8154_);
v___x_8157_ = lean_uint64_dec_lt(v___x_8155_, v___x_8156_);
if (v___x_8157_ == 0)
{
uint64_t v_diff_8158_; uint8_t v_aNeg_8159_; uint8_t v_bNeg_8160_; uint8_t v_dNeg_8161_;
v_diff_8158_ = lean_uint64_sub(v_height_7703_, v___y_8153_);
v_aNeg_8159_ = lean_uint64_dec_le(v___x_8154_, v_height_7703_);
v_bNeg_8160_ = lean_uint64_dec_le(v___x_8154_, v___y_8153_);
v_dNeg_8161_ = lean_uint64_dec_le(v___x_8154_, v_diff_8158_);
if (v_aNeg_8159_ == 0)
{
if (v_bNeg_8160_ == 0)
{
v___y_8136_ = v___y_8149_;
v___y_8137_ = v___y_8148_;
v___y_8138_ = v_aNeg_8159_;
v___y_8139_ = v_dNeg_8161_;
v___y_8140_ = v___x_8154_;
v___y_8141_ = v_diff_8158_;
v___y_8142_ = v___x_8157_;
v___y_8143_ = v_bNeg_8160_;
v___y_8144_ = v___y_8151_;
v___y_8145_ = v___y_8152_;
v___y_8146_ = v_bNeg_8160_;
goto v___jp_8135_;
}
else
{
if (v_dNeg_8161_ == 0)
{
v___y_8136_ = v___y_8149_;
v___y_8137_ = v___y_8148_;
v___y_8138_ = v_aNeg_8159_;
v___y_8139_ = v_dNeg_8161_;
v___y_8140_ = v___x_8154_;
v___y_8141_ = v_diff_8158_;
v___y_8142_ = v___x_8157_;
v___y_8143_ = v_bNeg_8160_;
v___y_8144_ = v___y_8151_;
v___y_8145_ = v___y_8152_;
v___y_8146_ = v_dNeg_8161_;
goto v___jp_8135_;
}
else
{
uint64_t v___x_8162_;
v___x_8162_ = 9223372036854775807ULL;
v___y_8113_ = v___y_8149_;
v___y_8114_ = v___y_8148_;
v___y_8115_ = v___x_8154_;
v___y_8116_ = v___x_8157_;
v___y_8117_ = v___y_8151_;
v___y_8118_ = v___y_8152_;
v___y_8119_ = v___x_8162_;
goto v___jp_8112_;
}
}
}
else
{
v___y_8136_ = v___y_8149_;
v___y_8137_ = v___y_8148_;
v___y_8138_ = v_aNeg_8159_;
v___y_8139_ = v_dNeg_8161_;
v___y_8140_ = v___x_8154_;
v___y_8141_ = v_diff_8158_;
v___y_8142_ = v___x_8157_;
v___y_8143_ = v_bNeg_8160_;
v___y_8144_ = v___y_8151_;
v___y_8145_ = v___y_8152_;
v___y_8146_ = v___x_8157_;
goto v___jp_8135_;
}
}
else
{
v___y_7879_ = v___y_8151_;
v___y_7880_ = v___y_8152_;
v___y_7881_ = v___y_8150_;
goto v___jp_7878_;
}
}
v___jp_8163_:
{
uint64_t v___x_8171_; uint64_t v___x_8172_; uint8_t v___x_8173_;
v___x_8171_ = 9223372036854775808ULL;
v___x_8172_ = lean_uint64_add(v___y_8170_, v___x_8171_);
v___x_8173_ = lean_uint64_dec_lt(v___x_8171_, v___x_8172_);
if (v___x_8173_ == 0)
{
v___y_8148_ = v___y_8165_;
v___y_8149_ = v___y_8164_;
v___y_8150_ = v___y_8166_;
v___y_8151_ = v___y_8168_;
v___y_8152_ = v___y_8169_;
v___y_8153_ = v___y_8167_;
goto v___jp_8147_;
}
else
{
v___y_8148_ = v___y_8165_;
v___y_8149_ = v___y_8164_;
v___y_8150_ = v___y_8166_;
v___y_8151_ = v___y_8168_;
v___y_8152_ = v___y_8169_;
v___y_8153_ = v___y_8170_;
goto v___jp_8147_;
}
}
v___jp_8174_:
{
uint64_t v___x_8182_; uint64_t v___x_8183_; uint64_t v___x_8184_; uint8_t v___x_8185_;
v___x_8182_ = 9223372036854775808ULL;
v___x_8183_ = lean_uint64_add(v_arg_7705_, v___x_8182_);
v___x_8184_ = lean_uint64_add(v___y_8181_, v___x_8182_);
v___x_8185_ = lean_uint64_dec_le(v___x_8183_, v___x_8184_);
if (v___x_8185_ == 0)
{
v___y_8164_ = v___y_8176_;
v___y_8165_ = v___y_8175_;
v___y_8166_ = v___y_8177_;
v___y_8167_ = v___y_8178_;
v___y_8168_ = v___y_8179_;
v___y_8169_ = v___y_8180_;
v___y_8170_ = v___y_8181_;
goto v___jp_8163_;
}
else
{
v___y_8164_ = v___y_8176_;
v___y_8165_ = v___y_8175_;
v___y_8166_ = v___y_8177_;
v___y_8167_ = v___y_8178_;
v___y_8168_ = v___y_8179_;
v___y_8169_ = v___y_8180_;
v___y_8170_ = v_arg_7705_;
goto v___jp_8163_;
}
}
v___jp_8186_:
{
uint64_t v___x_8194_; uint64_t v___x_8195_; uint8_t v___x_8196_;
v___x_8194_ = 9223372036854775808ULL;
v___x_8195_ = lean_uint64_add(v___y_8193_, v___x_8194_);
v___x_8196_ = lean_uint64_dec_lt(v___x_8194_, v___x_8195_);
if (v___x_8196_ == 0)
{
v___y_8175_ = v___y_8188_;
v___y_8176_ = v___y_8187_;
v___y_8177_ = v___y_8189_;
v___y_8178_ = v___y_8190_;
v___y_8179_ = v___y_8191_;
v___y_8180_ = v___y_8192_;
v___y_8181_ = v___y_8190_;
goto v___jp_8174_;
}
else
{
v___y_8175_ = v___y_8188_;
v___y_8176_ = v___y_8187_;
v___y_8177_ = v___y_8189_;
v___y_8178_ = v___y_8190_;
v___y_8179_ = v___y_8191_;
v___y_8180_ = v___y_8192_;
v___y_8181_ = v___y_8193_;
goto v___jp_8174_;
}
}
v___jp_8197_:
{
if (v___y_8202_ == 0)
{
v___y_8187_ = v___y_8200_;
v___y_8188_ = v___y_8199_;
v___y_8189_ = v___y_8201_;
v___y_8190_ = v___y_8203_;
v___y_8191_ = v___y_8206_;
v___y_8192_ = v___y_8207_;
v___y_8193_ = v___y_8204_;
goto v___jp_8186_;
}
else
{
if (v___y_8198_ == 0)
{
v___y_8187_ = v___y_8200_;
v___y_8188_ = v___y_8199_;
v___y_8189_ = v___y_8201_;
v___y_8190_ = v___y_8203_;
v___y_8191_ = v___y_8206_;
v___y_8192_ = v___y_8207_;
v___y_8193_ = v___y_8205_;
goto v___jp_8186_;
}
else
{
v___y_8187_ = v___y_8200_;
v___y_8188_ = v___y_8199_;
v___y_8189_ = v___y_8201_;
v___y_8190_ = v___y_8203_;
v___y_8191_ = v___y_8206_;
v___y_8192_ = v___y_8207_;
v___y_8193_ = v___y_8204_;
goto v___jp_8186_;
}
}
}
v___jp_8208_:
{
if (v___y_8218_ == 0)
{
v___y_8187_ = v___y_8209_;
v___y_8188_ = v___y_8210_;
v___y_8189_ = v___y_8211_;
v___y_8190_ = v___y_8213_;
v___y_8191_ = v___y_8216_;
v___y_8192_ = v___y_8219_;
v___y_8193_ = v___y_8215_;
goto v___jp_8186_;
}
else
{
if (v___y_8217_ == 0)
{
v___y_8198_ = v___y_8220_;
v___y_8199_ = v___y_8210_;
v___y_8200_ = v___y_8209_;
v___y_8201_ = v___y_8211_;
v___y_8202_ = v___y_8212_;
v___y_8203_ = v___y_8213_;
v___y_8204_ = v___y_8214_;
v___y_8205_ = v___y_8215_;
v___y_8206_ = v___y_8216_;
v___y_8207_ = v___y_8219_;
goto v___jp_8197_;
}
else
{
if (v___y_8220_ == 0)
{
v___y_8187_ = v___y_8209_;
v___y_8188_ = v___y_8210_;
v___y_8189_ = v___y_8211_;
v___y_8190_ = v___y_8213_;
v___y_8191_ = v___y_8216_;
v___y_8192_ = v___y_8219_;
v___y_8193_ = v___y_8215_;
goto v___jp_8186_;
}
else
{
v___y_8198_ = v___y_8220_;
v___y_8199_ = v___y_8210_;
v___y_8200_ = v___y_8209_;
v___y_8201_ = v___y_8211_;
v___y_8202_ = v___y_8212_;
v___y_8203_ = v___y_8213_;
v___y_8204_ = v___y_8214_;
v___y_8205_ = v___y_8215_;
v___y_8206_ = v___y_8216_;
v___y_8207_ = v___y_8219_;
goto v___jp_8197_;
}
}
}
}
v___jp_8221_:
{
uint64_t v___x_8227_; uint64_t v_diff_8228_; uint64_t v___x_8229_; uint8_t v_aNeg_8230_; uint8_t v_bNeg_8231_; uint8_t v_dNeg_8232_;
v___x_8227_ = 0ULL;
v_diff_8228_ = lean_uint64_sub(v_height_7703_, v_client_7704_);
v___x_8229_ = 9223372036854775808ULL;
v_aNeg_8230_ = lean_uint64_dec_le(v___x_8229_, v_height_7703_);
v_bNeg_8231_ = lean_uint64_dec_le(v___x_8229_, v_client_7704_);
v_dNeg_8232_ = lean_uint64_dec_le(v___x_8229_, v_diff_8228_);
if (v_aNeg_8230_ == 0)
{
if (v_bNeg_8231_ == 0)
{
v___y_8209_ = v___y_8223_;
v___y_8210_ = v___y_8222_;
v___y_8211_ = v___y_8224_;
v___y_8212_ = v_dNeg_8232_;
v___y_8213_ = v___x_8227_;
v___y_8214_ = v___x_8229_;
v___y_8215_ = v_diff_8228_;
v___y_8216_ = v___y_8225_;
v___y_8217_ = v_bNeg_8231_;
v___y_8218_ = v_aNeg_8230_;
v___y_8219_ = v___y_8226_;
v___y_8220_ = v_bNeg_8231_;
goto v___jp_8208_;
}
else
{
if (v_dNeg_8232_ == 0)
{
v___y_8209_ = v___y_8223_;
v___y_8210_ = v___y_8222_;
v___y_8211_ = v___y_8224_;
v___y_8212_ = v_dNeg_8232_;
v___y_8213_ = v___x_8227_;
v___y_8214_ = v___x_8229_;
v___y_8215_ = v_diff_8228_;
v___y_8216_ = v___y_8225_;
v___y_8217_ = v_bNeg_8231_;
v___y_8218_ = v_aNeg_8230_;
v___y_8219_ = v___y_8226_;
v___y_8220_ = v_dNeg_8232_;
goto v___jp_8208_;
}
else
{
uint64_t v___x_8233_;
v___x_8233_ = 9223372036854775807ULL;
v___y_8187_ = v___y_8223_;
v___y_8188_ = v___y_8222_;
v___y_8189_ = v___y_8224_;
v___y_8190_ = v___x_8227_;
v___y_8191_ = v___y_8225_;
v___y_8192_ = v___y_8226_;
v___y_8193_ = v___x_8233_;
goto v___jp_8186_;
}
}
}
else
{
v___y_8209_ = v___y_8223_;
v___y_8210_ = v___y_8222_;
v___y_8211_ = v___y_8224_;
v___y_8212_ = v_dNeg_8232_;
v___y_8213_ = v___x_8227_;
v___y_8214_ = v___x_8229_;
v___y_8215_ = v_diff_8228_;
v___y_8216_ = v___y_8225_;
v___y_8217_ = v_bNeg_8231_;
v___y_8218_ = v_aNeg_8230_;
v___y_8219_ = v___y_8226_;
v___y_8220_ = v___y_8224_;
goto v___jp_8208_;
}
}
v___jp_8234_:
{
uint8_t v___x_8240_; uint8_t v___x_8241_;
v___x_8240_ = 3;
v___x_8241_ = lean_uint8_dec_le(v_opKind_7698_, v___x_8240_);
if (v___x_8241_ == 0)
{
uint32_t v___x_8242_; uint32_t v_lo32Err_8243_; uint64_t v___x_8244_; uint64_t v___x_8245_; uint64_t v___x_8246_; uint64_t v___x_8247_;
v___x_8242_ = 2;
v_lo32Err_8243_ = lean_uint32_lor(v___x_8242_, v___y_8235_);
v___x_8244_ = lean_uint32_to_uint64(v_lo32Err_8243_);
v___x_8245_ = lean_uint32_to_uint64(v___y_8238_);
v___x_8246_ = lean_uint64_shift_left(v___x_8245_, v___x_7706_);
v___x_8247_ = lean_uint64_lor(v___x_8244_, v___x_8246_);
return v___x_8247_;
}
else
{
if (v___y_8239_ == 0)
{
uint32_t v___x_8248_; uint32_t v_lo32Dom_8249_; uint64_t v___x_8250_; uint64_t v___x_8251_; uint64_t v___x_8252_; uint64_t v___x_8253_;
v___x_8248_ = 3;
v_lo32Dom_8249_ = lean_uint32_lor(v___x_8248_, v___y_8235_);
v___x_8250_ = lean_uint32_to_uint64(v_lo32Dom_8249_);
v___x_8251_ = lean_uint32_to_uint64(v___y_8238_);
v___x_8252_ = lean_uint64_shift_left(v___x_8251_, v___x_7706_);
v___x_8253_ = lean_uint64_lor(v___x_8250_, v___x_8252_);
return v___x_8253_;
}
else
{
uint8_t v___x_8254_; uint8_t v_pinBool_8255_; uint8_t v___x_8256_;
v___x_8254_ = 1;
v_pinBool_8255_ = lean_uint8_dec_eq(v_pinned_7699_, v___x_8254_);
v___x_8256_ = lean_uint8_dec_eq(v_opKind_7698_, v___y_8236_);
if (v___x_8256_ == 0)
{
uint8_t v___x_8257_;
v___x_8257_ = lean_uint8_dec_eq(v_opKind_7698_, v___x_8254_);
if (v___x_8257_ == 0)
{
uint8_t v___x_8258_; uint8_t v___x_8259_;
v___x_8258_ = 2;
v___x_8259_ = lean_uint8_dec_eq(v_opKind_7698_, v___x_8258_);
if (v___x_8259_ == 0)
{
v___y_8067_ = v___y_8239_;
v___y_8068_ = v_pinBool_8255_;
v___y_8069_ = v___x_8254_;
v___y_8070_ = v___y_8236_;
v___y_8071_ = v___y_8237_;
v___y_8072_ = v___x_8256_;
goto v___jp_8066_;
}
else
{
uint8_t v___x_8260_;
v___x_8260_ = lean_uint8_dec_eq(v_intent_7700_, v___x_8254_);
if (v___x_8260_ == 0)
{
v___y_8067_ = v___y_8239_;
v___y_8068_ = v_pinBool_8255_;
v___y_8069_ = v___x_8254_;
v___y_8070_ = v___y_8236_;
v___y_8071_ = v___y_8237_;
v___y_8072_ = v___x_8260_;
goto v___jp_8066_;
}
else
{
v___y_8222_ = v___y_8239_;
v___y_8223_ = v_pinBool_8255_;
v___y_8224_ = v___x_8256_;
v___y_8225_ = v___y_8236_;
v___y_8226_ = v___y_8237_;
goto v___jp_8221_;
}
}
}
else
{
v___y_8222_ = v___y_8239_;
v___y_8223_ = v_pinBool_8255_;
v___y_8224_ = v___x_8256_;
v___y_8225_ = v___y_8236_;
v___y_8226_ = v___y_8237_;
goto v___jp_8221_;
}
}
else
{
v___y_7879_ = v___y_8236_;
v___y_7880_ = v___y_8237_;
v___y_7881_ = v_pinBool_8255_;
goto v___jp_7878_;
}
}
}
}
v___jp_8261_:
{
uint64_t v___x_8266_; uint8_t v___x_8267_;
v___x_8266_ = 1073741823ULL;
v___x_8267_ = lean_uint64_dec_le(v_arg_7705_, v___x_8266_);
if (v___x_8267_ == 0)
{
uint64_t v___x_8268_; uint8_t v___x_8269_;
v___x_8268_ = 18446744072635809792ULL;
v___x_8269_ = lean_uint64_dec_le(v___x_8268_, v_arg_7705_);
v___y_8235_ = v___y_8262_;
v___y_8236_ = v___y_8263_;
v___y_8237_ = v___y_8265_;
v___y_8238_ = v___y_8264_;
v___y_8239_ = v___x_8269_;
goto v___jp_8234_;
}
else
{
v___y_8235_ = v___y_8262_;
v___y_8236_ = v___y_8263_;
v___y_8237_ = v___y_8265_;
v___y_8238_ = v___y_8264_;
v___y_8239_ = v___x_8267_;
goto v___jp_8234_;
}
}
v___jp_8270_:
{
uint64_t v___x_8275_; uint8_t v___x_8276_;
v___x_8275_ = 1073741823ULL;
v___x_8276_ = lean_uint64_dec_le(v_client_7704_, v___x_8275_);
if (v___x_8276_ == 0)
{
uint64_t v___x_8277_; uint8_t v___x_8278_;
v___x_8277_ = 18446744072635809792ULL;
v___x_8278_ = lean_uint64_dec_le(v___x_8277_, v_client_7704_);
if (v___x_8278_ == 0)
{
v___y_8235_ = v___y_8271_;
v___y_8236_ = v___y_8272_;
v___y_8237_ = v___y_8274_;
v___y_8238_ = v___y_8273_;
v___y_8239_ = v___x_8278_;
goto v___jp_8234_;
}
else
{
v___y_8262_ = v___y_8271_;
v___y_8263_ = v___y_8272_;
v___y_8264_ = v___y_8273_;
v___y_8265_ = v___y_8274_;
goto v___jp_8261_;
}
}
else
{
v___y_8262_ = v___y_8271_;
v___y_8263_ = v___y_8272_;
v___y_8264_ = v___y_8273_;
v___y_8265_ = v___y_8274_;
goto v___jp_8261_;
}
}
v___jp_8279_:
{
uint64_t v___x_8284_; uint8_t v___x_8285_;
v___x_8284_ = 1073741823ULL;
v___x_8285_ = lean_uint64_dec_le(v_height_7703_, v___x_8284_);
if (v___x_8285_ == 0)
{
uint64_t v___x_8286_; uint8_t v___x_8287_;
v___x_8286_ = 18446744072635809792ULL;
v___x_8287_ = lean_uint64_dec_le(v___x_8286_, v_height_7703_);
if (v___x_8287_ == 0)
{
v___y_8235_ = v___y_8280_;
v___y_8236_ = v___y_8281_;
v___y_8237_ = v___y_8283_;
v___y_8238_ = v___y_8282_;
v___y_8239_ = v___x_8287_;
goto v___jp_8234_;
}
else
{
v___y_8271_ = v___y_8280_;
v___y_8272_ = v___y_8281_;
v___y_8273_ = v___y_8282_;
v___y_8274_ = v___y_8283_;
goto v___jp_8270_;
}
}
else
{
v___y_8271_ = v___y_8280_;
v___y_8272_ = v___y_8281_;
v___y_8273_ = v___y_8282_;
v___y_8274_ = v___y_8283_;
goto v___jp_8270_;
}
}
v___jp_8288_:
{
uint64_t v___x_8293_; uint8_t v___x_8294_;
v___x_8293_ = 1073741823ULL;
v___x_8294_ = lean_uint64_dec_le(v_curTop_7702_, v___x_8293_);
if (v___x_8294_ == 0)
{
uint64_t v___x_8295_; uint8_t v___x_8296_;
v___x_8295_ = 18446744072635809792ULL;
v___x_8296_ = lean_uint64_dec_le(v___x_8295_, v_curTop_7702_);
if (v___x_8296_ == 0)
{
v___y_8235_ = v___y_8289_;
v___y_8236_ = v___y_8290_;
v___y_8237_ = v___y_8291_;
v___y_8238_ = v___y_8292_;
v___y_8239_ = v___x_8296_;
goto v___jp_8234_;
}
else
{
v___y_8280_ = v___y_8289_;
v___y_8281_ = v___y_8290_;
v___y_8282_ = v___y_8292_;
v___y_8283_ = v___y_8291_;
goto v___jp_8279_;
}
}
else
{
v___y_8280_ = v___y_8289_;
v___y_8281_ = v___y_8290_;
v___y_8282_ = v___y_8292_;
v___y_8283_ = v___y_8291_;
goto v___jp_8279_;
}
}
v___jp_8297_:
{
uint64_t v___x_8302_; uint8_t v___x_8303_;
v___x_8302_ = 4294967295ULL;
v___x_8303_ = lean_uint64_dec_le(v___y_8301_, v___x_8302_);
if (v___x_8303_ == 0)
{
uint32_t v___x_8304_;
v___x_8304_ = 4294967295;
v___y_8289_ = v___y_8298_;
v___y_8290_ = v___y_8299_;
v___y_8291_ = v___y_8300_;
v___y_8292_ = v___x_8304_;
goto v___jp_8288_;
}
else
{
uint32_t v___x_8305_;
v___x_8305_ = lean_uint64_to_uint32(v___y_8301_);
v___y_8289_ = v___y_8298_;
v___y_8290_ = v___y_8299_;
v___y_8291_ = v___y_8300_;
v___y_8292_ = v___x_8305_;
goto v___jp_8288_;
}
}
v___jp_8306_:
{
uint64_t v___x_8310_; uint64_t v___x_8311_; uint8_t v___x_8312_;
v___x_8310_ = 9223372036854775808ULL;
v___x_8311_ = lean_uint64_add(v_curTop_7702_, v___x_8310_);
v___x_8312_ = lean_uint64_dec_lt(v___x_8310_, v___x_8311_);
if (v___x_8312_ == 0)
{
uint64_t v___x_8313_;
v___x_8313_ = 0ULL;
v___y_8298_ = v___y_8309_;
v___y_8299_ = v___y_8307_;
v___y_8300_ = v___y_8308_;
v___y_8301_ = v___x_8313_;
goto v___jp_8297_;
}
else
{
v___y_8298_ = v___y_8309_;
v___y_8299_ = v___y_8307_;
v___y_8300_ = v___y_8308_;
v___y_8301_ = v_curTop_7702_;
goto v___jp_8297_;
}
}
v___jp_8314_:
{
uint8_t v___x_8318_; uint8_t v___x_8319_;
v___x_8318_ = 0;
v___x_8319_ = lean_uint8_dec_eq(v___y_8316_, v___x_8318_);
if (v___x_8319_ == 0)
{
uint32_t v___x_8320_; uint32_t v___x_8321_; uint64_t v___x_8322_; uint64_t v___x_8323_; uint64_t v___x_8324_; uint64_t v___x_8325_;
v___x_8320_ = lean_uint8_to_uint32(v___y_8316_);
v___x_8321_ = lean_uint32_lor(v___x_8320_, v___y_8315_);
v___x_8322_ = lean_uint32_to_uint64(v___x_8321_);
v___x_8323_ = lean_uint32_to_uint64(v___y_8317_);
v___x_8324_ = lean_uint64_shift_left(v___x_8323_, v___x_7706_);
v___x_8325_ = lean_uint64_lor(v___x_8322_, v___x_8324_);
return v___x_8325_;
}
else
{
uint8_t v___x_8326_; uint8_t v___x_8327_; uint8_t v___x_8328_;
v___x_8326_ = 0;
v___x_8327_ = 1;
v___x_8328_ = lean_uint8_dec_eq(v_pinned_7699_, v___x_8327_);
if (v___x_8328_ == 0)
{
uint32_t v___x_8329_;
v___x_8329_ = 0;
v___y_8307_ = v___x_8318_;
v___y_8308_ = v___x_8326_;
v___y_8309_ = v___x_8329_;
goto v___jp_8306_;
}
else
{
uint32_t v___x_8330_;
v___x_8330_ = 512;
v___y_8307_ = v___x_8318_;
v___y_8308_ = v___x_8326_;
v___y_8309_ = v___x_8330_;
goto v___jp_8306_;
}
}
}
v___jp_8331_:
{
uint64_t v___x_8335_; uint8_t v___x_8336_;
v___x_8335_ = 4294967295ULL;
v___x_8336_ = lean_uint64_dec_le(v___y_8334_, v___x_8335_);
if (v___x_8336_ == 0)
{
uint32_t v___x_8337_;
v___x_8337_ = 4294967295;
v___y_8315_ = v___y_8332_;
v___y_8316_ = v___y_8333_;
v___y_8317_ = v___x_8337_;
goto v___jp_8314_;
}
else
{
uint32_t v___x_8338_;
v___x_8338_ = lean_uint64_to_uint32(v___y_8334_);
v___y_8315_ = v___y_8332_;
v___y_8316_ = v___y_8333_;
v___y_8317_ = v___x_8338_;
goto v___jp_8314_;
}
}
v___jp_8339_:
{
uint64_t v___x_8342_; uint64_t v___x_8343_; uint8_t v___x_8344_;
v___x_8342_ = 9223372036854775808ULL;
v___x_8343_ = lean_uint64_add(v_curTop_7702_, v___x_8342_);
v___x_8344_ = lean_uint64_dec_lt(v___x_8342_, v___x_8343_);
if (v___x_8344_ == 0)
{
uint64_t v___x_8345_;
v___x_8345_ = 0ULL;
v___y_8332_ = v___y_8341_;
v___y_8333_ = v___y_8340_;
v___y_8334_ = v___x_8345_;
goto v___jp_8331_;
}
else
{
v___y_8332_ = v___y_8341_;
v___y_8333_ = v___y_8340_;
v___y_8334_ = v_curTop_7702_;
goto v___jp_8331_;
}
}
v___jp_8346_:
{
uint8_t v___x_8348_; uint8_t v___x_8349_;
v___x_8348_ = 1;
v___x_8349_ = lean_uint8_dec_eq(v_pinned_7699_, v___x_8348_);
if (v___x_8349_ == 0)
{
uint32_t v___x_8350_;
v___x_8350_ = 0;
v___y_8340_ = v___y_8347_;
v___y_8341_ = v___x_8350_;
goto v___jp_8339_;
}
else
{
uint32_t v___x_8351_;
v___x_8351_ = 512;
v___y_8340_ = v___y_8347_;
v___y_8341_ = v___x_8351_;
goto v___jp_8339_;
}
}
v___jp_8352_:
{
uint8_t v___x_8353_;
v___x_8353_ = lean_uint64_dec_le(v___x_7706_, v_outCap_7696_);
if (v___x_8353_ == 0)
{
uint8_t v___x_8354_;
v___x_8354_ = 5;
v___y_8347_ = v___x_8354_;
goto v___jp_8346_;
}
else
{
uint8_t v___x_8355_;
v___x_8355_ = 0;
v___y_8347_ = v___x_8355_;
goto v___jp_8346_;
}
}
v___jp_8356_:
{
uint8_t v___x_8357_;
v___x_8357_ = lean_uint64_dec_le(v_outCap_7696_, v_inPtr_7693_);
if (v___x_8357_ == 0)
{
uint8_t v___x_8358_;
v___x_8358_ = 9;
v___y_8347_ = v___x_8358_;
goto v___jp_8346_;
}
else
{
uint64_t v___x_8359_; uint8_t v___x_8360_;
v___x_8359_ = lean_uint64_sub(v_inPtr_7693_, v_outCap_7696_);
v___x_8360_ = lean_uint64_dec_le(v_outPtr_7695_, v___x_8359_);
if (v___x_8360_ == 0)
{
uint8_t v___x_8361_;
v___x_8361_ = 9;
v___y_8347_ = v___x_8361_;
goto v___jp_8346_;
}
else
{
goto v___jp_8352_;
}
}
}
}
}

LEAN_EXPORT uint64_t orb_wire_stream_slice_step(uint64_t v_inPtr_8446_, uint64_t v_inLen_8447_, uint64_t v_outPtr_8448_, uint64_t v_outCap_8449_, uint8_t v_is32Bit_8450_, uint32_t v_prevLen_8451_, uint32_t v_prevCommit_8452_, uint32_t v_prevCheckpoint_8453_, uint32_t v_newLen_8454_, uint32_t v_rawCommit_8455_, uint32_t v_maxOpenTailBytes_8456_){
_start:
{
uint64_t v___x_8457_; uint32_t v___y_8459_; uint32_t v___y_8460_; uint32_t v___y_8461_; uint32_t v___y_8477_; uint32_t v___y_8478_; uint32_t v___y_8479_; uint8_t v___y_8480_; uint8_t v___y_8484_; uint8_t v___y_8485_; uint8_t v___y_8486_; uint32_t v___y_8487_; uint8_t v___y_8488_; uint32_t v___y_8489_; uint32_t v___y_8490_; uint8_t v___y_8492_; uint32_t v___y_8493_; uint8_t v___y_8494_; uint8_t v___y_8495_; uint8_t v___y_8496_; uint32_t v___y_8497_; uint32_t v___y_8498_; uint8_t v___y_8502_; uint8_t v___y_8503_; uint32_t v___y_8504_; uint8_t v___y_8505_; uint32_t v___y_8506_; uint8_t v___y_8507_; uint32_t v___y_8508_; uint32_t v___y_8509_; uint8_t v___y_8512_; uint32_t v___y_8513_; uint8_t v___y_8514_; uint8_t v___y_8515_; uint8_t v___y_8516_; uint32_t v___y_8517_; uint32_t v___y_8518_; uint8_t v___y_8522_; uint8_t v___y_8523_; uint8_t v___y_8524_; uint8_t v___y_8525_; uint32_t v___y_8526_; uint32_t v___y_8527_; uint8_t v___y_8530_; uint8_t v___y_8531_; uint8_t v___y_8532_; uint8_t v___y_8533_; uint32_t v___y_8534_; uint32_t v___y_8535_; uint8_t v___y_8538_; uint8_t v___y_8539_; uint8_t v___y_8540_; uint32_t v___y_8541_; uint8_t v___y_8542_; uint8_t v___y_8545_; uint8_t v___x_8569_; uint8_t v___x_8570_;
v___x_8457_ = 32ULL;
v___x_8569_ = 1;
v___x_8570_ = lean_uint8_dec_le(v_is32Bit_8450_, v___x_8569_);
if (v___x_8570_ == 0)
{
uint8_t v___x_8571_;
v___x_8571_ = 6;
v___y_8545_ = v___x_8571_;
goto v___jp_8544_;
}
else
{
uint64_t v___x_8572_; uint8_t v___x_8573_; uint8_t v___y_8580_; uint8_t v___y_8583_; uint8_t v___y_8602_; uint8_t v___y_8619_;
v___x_8572_ = 0ULL;
v___x_8573_ = lean_uint64_dec_eq(v_inLen_8447_, v___x_8572_);
if (v___x_8573_ == 0)
{
uint8_t v___x_8623_;
v___x_8623_ = lean_uint64_dec_eq(v_inPtr_8446_, v___x_8572_);
if (v___x_8623_ == 0)
{
v___y_8619_ = v___x_8570_;
goto v___jp_8618_;
}
else
{
uint8_t v___x_8624_;
v___x_8624_ = 7;
v___y_8545_ = v___x_8624_;
goto v___jp_8544_;
}
}
else
{
v___y_8619_ = v___x_8570_;
goto v___jp_8618_;
}
v___jp_8574_:
{
if (v___x_8573_ == 0)
{
uint8_t v___x_8575_;
v___x_8575_ = lean_uint64_dec_eq(v_outCap_8449_, v___x_8572_);
if (v___x_8575_ == 0)
{
uint8_t v___x_8576_;
v___x_8576_ = lean_uint64_dec_le(v_inLen_8447_, v_outPtr_8448_);
if (v___x_8576_ == 0)
{
goto v___jp_8563_;
}
else
{
uint64_t v___x_8577_; uint8_t v___x_8578_;
v___x_8577_ = lean_uint64_sub(v_outPtr_8448_, v_inLen_8447_);
v___x_8578_ = lean_uint64_dec_le(v_inPtr_8446_, v___x_8577_);
if (v___x_8578_ == 0)
{
goto v___jp_8563_;
}
else
{
goto v___jp_8559_;
}
}
}
else
{
goto v___jp_8559_;
}
}
else
{
goto v___jp_8559_;
}
}
v___jp_8579_:
{
if (v___y_8580_ == 0)
{
uint8_t v___x_8581_;
v___x_8581_ = 8;
v___y_8545_ = v___x_8581_;
goto v___jp_8544_;
}
else
{
goto v___jp_8574_;
}
}
v___jp_8582_:
{
if (v___y_8583_ == 0)
{
uint8_t v___x_8584_;
v___x_8584_ = 8;
v___y_8545_ = v___x_8584_;
goto v___jp_8544_;
}
else
{
uint8_t v___x_8585_;
v___x_8585_ = lean_uint8_dec_eq(v_is32Bit_8450_, v___x_8569_);
if (v___x_8585_ == 0)
{
uint8_t v___x_8586_;
v___x_8586_ = lean_uint64_dec_eq(v_outPtr_8448_, v___x_8572_);
if (v___x_8586_ == 0)
{
uint8_t v___x_8587_;
v___x_8587_ = lean_uint64_dec_eq(v_outCap_8449_, v___x_8572_);
if (v___x_8587_ == 0)
{
uint64_t v___x_8588_; uint64_t v___x_8589_; uint64_t v___x_8590_; uint64_t v___x_8591_; uint8_t v___x_8592_;
v___x_8588_ = 1ULL;
v___x_8589_ = lean_uint64_sub(v_outPtr_8448_, v___x_8588_);
v___x_8590_ = 18446744073709551615ULL;
v___x_8591_ = lean_uint64_sub(v___x_8590_, v_outCap_8449_);
v___x_8592_ = lean_uint64_dec_le(v___x_8589_, v___x_8591_);
v___y_8580_ = v___x_8592_;
goto v___jp_8579_;
}
else
{
goto v___jp_8574_;
}
}
else
{
goto v___jp_8574_;
}
}
else
{
uint64_t v___x_8593_; uint8_t v___x_8594_;
v___x_8593_ = 4294967295ULL;
v___x_8594_ = lean_uint64_dec_le(v_outPtr_8448_, v___x_8593_);
if (v___x_8594_ == 0)
{
uint8_t v___x_8595_;
v___x_8595_ = 8;
v___y_8545_ = v___x_8595_;
goto v___jp_8544_;
}
else
{
uint8_t v___x_8596_;
v___x_8596_ = lean_uint64_dec_le(v_outCap_8449_, v___x_8593_);
if (v___x_8596_ == 0)
{
uint8_t v___x_8597_;
v___x_8597_ = 8;
v___y_8545_ = v___x_8597_;
goto v___jp_8544_;
}
else
{
uint64_t v___x_8598_; uint64_t v___x_8599_; uint8_t v___x_8600_;
v___x_8598_ = lean_uint64_add(v_outPtr_8448_, v_outCap_8449_);
v___x_8599_ = 4294967296ULL;
v___x_8600_ = lean_uint64_dec_le(v___x_8598_, v___x_8599_);
v___y_8580_ = v___x_8600_;
goto v___jp_8579_;
}
}
}
}
}
v___jp_8601_:
{
uint8_t v___x_8603_;
v___x_8603_ = lean_uint8_dec_eq(v_is32Bit_8450_, v___x_8569_);
if (v___x_8603_ == 0)
{
uint8_t v___x_8604_;
v___x_8604_ = lean_uint64_dec_eq(v_inPtr_8446_, v___x_8572_);
if (v___x_8604_ == 0)
{
if (v___x_8573_ == 0)
{
uint64_t v___x_8605_; uint64_t v___x_8606_; uint64_t v___x_8607_; uint64_t v___x_8608_; uint8_t v___x_8609_;
v___x_8605_ = 1ULL;
v___x_8606_ = lean_uint64_sub(v_inPtr_8446_, v___x_8605_);
v___x_8607_ = 18446744073709551615ULL;
v___x_8608_ = lean_uint64_sub(v___x_8607_, v_inLen_8447_);
v___x_8609_ = lean_uint64_dec_le(v___x_8606_, v___x_8608_);
v___y_8583_ = v___x_8609_;
goto v___jp_8582_;
}
else
{
v___y_8583_ = v___y_8602_;
goto v___jp_8582_;
}
}
else
{
v___y_8583_ = v___y_8602_;
goto v___jp_8582_;
}
}
else
{
uint64_t v___x_8610_; uint8_t v___x_8611_;
v___x_8610_ = 4294967295ULL;
v___x_8611_ = lean_uint64_dec_le(v_inPtr_8446_, v___x_8610_);
if (v___x_8611_ == 0)
{
uint8_t v___x_8612_;
v___x_8612_ = 8;
v___y_8545_ = v___x_8612_;
goto v___jp_8544_;
}
else
{
uint8_t v___x_8613_;
v___x_8613_ = lean_uint64_dec_le(v_inLen_8447_, v___x_8610_);
if (v___x_8613_ == 0)
{
uint8_t v___x_8614_;
v___x_8614_ = 8;
v___y_8545_ = v___x_8614_;
goto v___jp_8544_;
}
else
{
uint64_t v___x_8615_; uint64_t v___x_8616_; uint8_t v___x_8617_;
v___x_8615_ = lean_uint64_add(v_inPtr_8446_, v_inLen_8447_);
v___x_8616_ = 4294967296ULL;
v___x_8617_ = lean_uint64_dec_le(v___x_8615_, v___x_8616_);
v___y_8583_ = v___x_8617_;
goto v___jp_8582_;
}
}
}
}
v___jp_8618_:
{
uint8_t v___x_8620_;
v___x_8620_ = lean_uint64_dec_eq(v_outCap_8449_, v___x_8572_);
if (v___x_8620_ == 0)
{
uint8_t v___x_8621_;
v___x_8621_ = lean_uint64_dec_eq(v_outPtr_8448_, v___x_8572_);
if (v___x_8621_ == 0)
{
v___y_8602_ = v___y_8619_;
goto v___jp_8601_;
}
else
{
uint8_t v___x_8622_;
v___x_8622_ = 7;
v___y_8545_ = v___x_8622_;
goto v___jp_8544_;
}
}
else
{
v___y_8602_ = v___x_8570_;
goto v___jp_8601_;
}
}
}
v___jp_8458_:
{
uint64_t v___x_8462_; uint64_t v___x_8463_; uint64_t v___x_8464_; uint64_t v___x_8465_; uint64_t v___x_8466_; uint64_t v___x_8467_; uint32_t v_stepLo_8468_; uint32_t v___x_8469_; uint32_t v___x_8470_; uint8_t v___x_8471_;
v___x_8462_ = lean_uint32_to_uint64(v___y_8459_);
v___x_8463_ = lean_uint32_to_uint64(v___y_8461_);
v___x_8464_ = lean_uint64_shift_left(v___x_8463_, v___x_8457_);
v___x_8465_ = lean_uint64_lor(v___x_8462_, v___x_8464_);
v___x_8466_ = 4294967295ULL;
v___x_8467_ = lean_uint64_land(v___x_8465_, v___x_8466_);
v_stepLo_8468_ = lean_uint64_to_uint32(v___x_8467_);
v___x_8469_ = 256;
v___x_8470_ = lean_uint32_land(v_stepLo_8468_, v___x_8469_);
v___x_8471_ = lean_uint32_dec_eq(v___x_8470_, v___y_8460_);
if (v___x_8471_ == 0)
{
return v___x_8465_;
}
else
{
uint64_t v___x_8472_; uint64_t v___x_8473_; uint64_t v___x_8474_; uint64_t v___x_8475_;
v___x_8472_ = 3ULL;
v___x_8473_ = lean_uint32_to_uint64(v_prevCheckpoint_8453_);
v___x_8474_ = lean_uint64_shift_left(v___x_8473_, v___x_8457_);
v___x_8475_ = lean_uint64_lor(v___x_8472_, v___x_8474_);
return v___x_8475_;
}
}
v___jp_8476_:
{
if (v___y_8480_ == 0)
{
uint32_t v___x_8481_; uint32_t v___x_8482_;
v___x_8481_ = 257;
v___x_8482_ = lean_uint32_lor(v___x_8481_, v___y_8477_);
v___y_8459_ = v___x_8482_;
v___y_8460_ = v___y_8479_;
v___y_8461_ = v___y_8478_;
goto v___jp_8458_;
}
else
{
v___y_8459_ = v___y_8479_;
v___y_8460_ = v___y_8479_;
v___y_8461_ = v_prevCheckpoint_8453_;
goto v___jp_8458_;
}
}
v___jp_8483_:
{
if (v___y_8488_ == 0)
{
v___y_8477_ = v___y_8490_;
v___y_8478_ = v___y_8487_;
v___y_8479_ = v___y_8489_;
v___y_8480_ = v___y_8486_;
goto v___jp_8476_;
}
else
{
if (v___y_8484_ == 0)
{
v___y_8477_ = v___y_8490_;
v___y_8478_ = v___y_8487_;
v___y_8479_ = v___y_8489_;
v___y_8480_ = v___y_8486_;
goto v___jp_8476_;
}
else
{
v___y_8477_ = v___y_8490_;
v___y_8478_ = v___y_8487_;
v___y_8479_ = v___y_8489_;
v___y_8480_ = v___y_8485_;
goto v___jp_8476_;
}
}
}
v___jp_8491_:
{
uint8_t v___x_8499_;
v___x_8499_ = lean_uint32_dec_lt(v___y_8493_, v___y_8498_);
if (v___x_8499_ == 0)
{
v___y_8484_ = v___y_8492_;
v___y_8485_ = v___y_8494_;
v___y_8486_ = v___y_8495_;
v___y_8487_ = v___y_8498_;
v___y_8488_ = v___y_8496_;
v___y_8489_ = v___y_8497_;
v___y_8490_ = v___y_8497_;
goto v___jp_8483_;
}
else
{
uint32_t v___x_8500_;
v___x_8500_ = 512;
v___y_8484_ = v___y_8492_;
v___y_8485_ = v___y_8494_;
v___y_8486_ = v___y_8495_;
v___y_8487_ = v___y_8498_;
v___y_8488_ = v___y_8496_;
v___y_8489_ = v___y_8497_;
v___y_8490_ = v___x_8500_;
goto v___jp_8483_;
}
}
v___jp_8501_:
{
uint8_t v___x_8510_;
v___x_8510_ = lean_uint32_dec_le(v___y_8506_, v___y_8509_);
if (v___x_8510_ == 0)
{
v___y_8492_ = v___y_8502_;
v___y_8493_ = v___y_8504_;
v___y_8494_ = v___y_8503_;
v___y_8495_ = v___y_8505_;
v___y_8496_ = v___y_8507_;
v___y_8497_ = v___y_8508_;
v___y_8498_ = v___y_8506_;
goto v___jp_8491_;
}
else
{
v___y_8492_ = v___y_8502_;
v___y_8493_ = v___y_8504_;
v___y_8494_ = v___y_8503_;
v___y_8495_ = v___y_8505_;
v___y_8496_ = v___y_8507_;
v___y_8497_ = v___y_8508_;
v___y_8498_ = v___y_8509_;
goto v___jp_8491_;
}
}
v___jp_8511_:
{
uint8_t v___x_8519_;
v___x_8519_ = lean_uint32_dec_le(v_maxOpenTailBytes_8456_, v_newLen_8454_);
if (v___x_8519_ == 0)
{
v___y_8502_ = v___y_8512_;
v___y_8503_ = v___y_8514_;
v___y_8504_ = v___y_8513_;
v___y_8505_ = v___y_8515_;
v___y_8506_ = v___y_8518_;
v___y_8507_ = v___y_8516_;
v___y_8508_ = v___y_8517_;
v___y_8509_ = v___y_8517_;
goto v___jp_8501_;
}
else
{
uint32_t v___x_8520_;
v___x_8520_ = lean_uint32_sub(v_newLen_8454_, v_maxOpenTailBytes_8456_);
v___y_8502_ = v___y_8512_;
v___y_8503_ = v___y_8514_;
v___y_8504_ = v___y_8513_;
v___y_8505_ = v___y_8515_;
v___y_8506_ = v___y_8518_;
v___y_8507_ = v___y_8516_;
v___y_8508_ = v___y_8517_;
v___y_8509_ = v___x_8520_;
goto v___jp_8501_;
}
}
v___jp_8521_:
{
uint8_t v___x_8528_;
v___x_8528_ = lean_uint32_dec_le(v_prevCheckpoint_8453_, v___y_8527_);
if (v___x_8528_ == 0)
{
v___y_8512_ = v___y_8522_;
v___y_8513_ = v___y_8527_;
v___y_8514_ = v___y_8523_;
v___y_8515_ = v___y_8524_;
v___y_8516_ = v___y_8525_;
v___y_8517_ = v___y_8526_;
v___y_8518_ = v_prevCheckpoint_8453_;
goto v___jp_8511_;
}
else
{
v___y_8512_ = v___y_8522_;
v___y_8513_ = v___y_8527_;
v___y_8514_ = v___y_8523_;
v___y_8515_ = v___y_8524_;
v___y_8516_ = v___y_8525_;
v___y_8517_ = v___y_8526_;
v___y_8518_ = v___y_8527_;
goto v___jp_8511_;
}
}
v___jp_8529_:
{
uint8_t v___x_8536_;
v___x_8536_ = lean_uint32_dec_le(v_prevCommit_8452_, v___y_8535_);
if (v___x_8536_ == 0)
{
v___y_8522_ = v___y_8530_;
v___y_8523_ = v___y_8531_;
v___y_8524_ = v___y_8532_;
v___y_8525_ = v___y_8533_;
v___y_8526_ = v___y_8534_;
v___y_8527_ = v_prevCommit_8452_;
goto v___jp_8521_;
}
else
{
v___y_8522_ = v___y_8530_;
v___y_8523_ = v___y_8531_;
v___y_8524_ = v___y_8532_;
v___y_8525_ = v___y_8533_;
v___y_8526_ = v___y_8534_;
v___y_8527_ = v___y_8535_;
goto v___jp_8521_;
}
}
v___jp_8537_:
{
uint8_t v___x_8543_;
v___x_8543_ = lean_uint32_dec_le(v_rawCommit_8455_, v_newLen_8454_);
if (v___x_8543_ == 0)
{
v___y_8530_ = v___y_8542_;
v___y_8531_ = v___y_8538_;
v___y_8532_ = v___y_8539_;
v___y_8533_ = v___y_8540_;
v___y_8534_ = v___y_8541_;
v___y_8535_ = v_newLen_8454_;
goto v___jp_8529_;
}
else
{
v___y_8530_ = v___y_8542_;
v___y_8531_ = v___y_8538_;
v___y_8532_ = v___y_8539_;
v___y_8533_ = v___y_8540_;
v___y_8534_ = v___y_8541_;
v___y_8535_ = v_rawCommit_8455_;
goto v___jp_8529_;
}
}
v___jp_8544_:
{
uint8_t v___x_8546_; uint8_t v___x_8547_;
v___x_8546_ = 0;
v___x_8547_ = lean_uint8_dec_eq(v___y_8545_, v___x_8546_);
if (v___x_8547_ == 0)
{
uint32_t v___x_8548_; uint64_t v___x_8549_; uint64_t v___x_8550_; uint64_t v___x_8551_; uint64_t v___x_8552_;
v___x_8548_ = lean_uint8_to_uint32(v___y_8545_);
v___x_8549_ = lean_uint32_to_uint64(v___x_8548_);
v___x_8550_ = lean_uint32_to_uint64(v_prevCheckpoint_8453_);
v___x_8551_ = lean_uint64_shift_left(v___x_8550_, v___x_8457_);
v___x_8552_ = lean_uint64_lor(v___x_8549_, v___x_8551_);
return v___x_8552_;
}
else
{
uint8_t v___x_8553_; uint32_t v___x_8554_; uint8_t v_validCap_8555_; uint8_t v___x_8556_;
v___x_8553_ = 0;
v___x_8554_ = 0;
v_validCap_8555_ = lean_uint32_dec_lt(v___x_8554_, v_maxOpenTailBytes_8456_);
v___x_8556_ = lean_uint32_dec_le(v_prevCommit_8452_, v_prevCheckpoint_8453_);
if (v___x_8556_ == 0)
{
v___y_8538_ = v___x_8553_;
v___y_8539_ = v___x_8547_;
v___y_8540_ = v_validCap_8555_;
v___y_8541_ = v___x_8554_;
v___y_8542_ = v___x_8556_;
goto v___jp_8537_;
}
else
{
uint8_t v___x_8557_;
v___x_8557_ = lean_uint32_dec_le(v_prevCheckpoint_8453_, v_prevLen_8451_);
if (v___x_8557_ == 0)
{
v___y_8538_ = v___x_8553_;
v___y_8539_ = v___x_8547_;
v___y_8540_ = v_validCap_8555_;
v___y_8541_ = v___x_8554_;
v___y_8542_ = v___x_8557_;
goto v___jp_8537_;
}
else
{
uint8_t v___x_8558_;
v___x_8558_ = lean_uint32_dec_le(v_prevLen_8451_, v_newLen_8454_);
v___y_8538_ = v___x_8553_;
v___y_8539_ = v___x_8547_;
v___y_8540_ = v_validCap_8555_;
v___y_8541_ = v___x_8554_;
v___y_8542_ = v___x_8558_;
goto v___jp_8537_;
}
}
}
}
v___jp_8559_:
{
uint8_t v___x_8560_;
v___x_8560_ = lean_uint64_dec_le(v___x_8457_, v_outCap_8449_);
if (v___x_8560_ == 0)
{
uint8_t v___x_8561_;
v___x_8561_ = 5;
v___y_8545_ = v___x_8561_;
goto v___jp_8544_;
}
else
{
uint8_t v___x_8562_;
v___x_8562_ = 0;
v___y_8545_ = v___x_8562_;
goto v___jp_8544_;
}
}
v___jp_8563_:
{
uint8_t v___x_8564_;
v___x_8564_ = lean_uint64_dec_le(v_outCap_8449_, v_inPtr_8446_);
if (v___x_8564_ == 0)
{
uint8_t v___x_8565_;
v___x_8565_ = 9;
v___y_8545_ = v___x_8565_;
goto v___jp_8544_;
}
else
{
uint64_t v___x_8566_; uint8_t v___x_8567_;
v___x_8566_ = lean_uint64_sub(v_inPtr_8446_, v_outCap_8449_);
v___x_8567_ = lean_uint64_dec_le(v_outPtr_8448_, v___x_8566_);
if (v___x_8567_ == 0)
{
uint8_t v___x_8568_;
v___x_8568_ = 9;
v___y_8545_ = v___x_8568_;
goto v___jp_8544_;
}
else
{
goto v___jp_8559_;
}
}
}
}
}

LEAN_EXPORT uint64_t orb_wire_transcript_slice_step(uint64_t v_inPtr_8847_, uint64_t v_inLen_8848_, uint64_t v_outPtr_8849_, uint64_t v_outCap_8850_, uint8_t v_is32Bit_8851_, uint64_t v_lastAppliedSeq_8852_, uint64_t v_incomingSeq_8853_, uint32_t v_entryCount_8854_, uint8_t v_thinkingOpen_8855_, uint8_t v_normalizedAction_8856_, uint8_t v_isReplayFromLog_8857_){
_start:
{
uint64_t v___x_8858_; uint32_t v___y_8860_; uint32_t v___y_8861_; uint32_t v___y_8867_; uint8_t v___y_8874_; uint32_t v___y_8875_; uint8_t v___y_8877_; uint8_t v___y_8878_; uint8_t v___y_8879_; uint8_t v___y_8880_; uint32_t v___y_8881_; uint8_t v___y_8882_; uint8_t v___y_8883_; uint8_t v___y_8896_; uint8_t v___y_8897_; uint8_t v___y_8898_; uint8_t v___y_8899_; uint8_t v___y_8900_; uint32_t v___y_8901_; uint8_t v___y_8902_; uint8_t v___y_8910_; uint8_t v___y_8911_; uint8_t v___y_8912_; uint32_t v___y_8913_; uint8_t v___y_8914_; uint8_t v___y_8928_; uint8_t v___y_8929_; uint8_t v___y_8930_; uint32_t v___y_8931_; uint8_t v___y_8937_; uint32_t v___y_8938_; uint8_t v___y_8953_; uint8_t v___x_8968_; uint8_t v___x_8969_;
v___x_8858_ = 32ULL;
v___x_8968_ = 1;
v___x_8969_ = lean_uint8_dec_le(v_is32Bit_8851_, v___x_8968_);
if (v___x_8969_ == 0)
{
uint8_t v___x_8970_;
v___x_8970_ = 6;
v___y_8953_ = v___x_8970_;
goto v___jp_8952_;
}
else
{
uint64_t v___x_8971_; uint8_t v___x_8972_; uint8_t v___y_8979_; uint8_t v___y_8982_; uint8_t v___y_9001_; uint8_t v___y_9018_;
v___x_8971_ = 0ULL;
v___x_8972_ = lean_uint64_dec_eq(v_inLen_8848_, v___x_8971_);
if (v___x_8972_ == 0)
{
uint8_t v___x_9022_;
v___x_9022_ = lean_uint64_dec_eq(v_inPtr_8847_, v___x_8971_);
if (v___x_9022_ == 0)
{
v___y_9018_ = v___x_8969_;
goto v___jp_9017_;
}
else
{
uint8_t v___x_9023_;
v___x_9023_ = 7;
v___y_8953_ = v___x_9023_;
goto v___jp_8952_;
}
}
else
{
v___y_9018_ = v___x_8969_;
goto v___jp_9017_;
}
v___jp_8973_:
{
if (v___x_8972_ == 0)
{
uint8_t v___x_8974_;
v___x_8974_ = lean_uint64_dec_eq(v_outCap_8850_, v___x_8971_);
if (v___x_8974_ == 0)
{
uint8_t v___x_8975_;
v___x_8975_ = lean_uint64_dec_le(v_inLen_8848_, v_outPtr_8849_);
if (v___x_8975_ == 0)
{
goto v___jp_8962_;
}
else
{
uint64_t v___x_8976_; uint8_t v___x_8977_;
v___x_8976_ = lean_uint64_sub(v_outPtr_8849_, v_inLen_8848_);
v___x_8977_ = lean_uint64_dec_le(v_inPtr_8847_, v___x_8976_);
if (v___x_8977_ == 0)
{
goto v___jp_8962_;
}
else
{
goto v___jp_8958_;
}
}
}
else
{
goto v___jp_8958_;
}
}
else
{
goto v___jp_8958_;
}
}
v___jp_8978_:
{
if (v___y_8979_ == 0)
{
uint8_t v___x_8980_;
v___x_8980_ = 8;
v___y_8953_ = v___x_8980_;
goto v___jp_8952_;
}
else
{
goto v___jp_8973_;
}
}
v___jp_8981_:
{
if (v___y_8982_ == 0)
{
uint8_t v___x_8983_;
v___x_8983_ = 8;
v___y_8953_ = v___x_8983_;
goto v___jp_8952_;
}
else
{
uint8_t v___x_8984_;
v___x_8984_ = lean_uint8_dec_eq(v_is32Bit_8851_, v___x_8968_);
if (v___x_8984_ == 0)
{
uint8_t v___x_8985_;
v___x_8985_ = lean_uint64_dec_eq(v_outPtr_8849_, v___x_8971_);
if (v___x_8985_ == 0)
{
uint8_t v___x_8986_;
v___x_8986_ = lean_uint64_dec_eq(v_outCap_8850_, v___x_8971_);
if (v___x_8986_ == 0)
{
uint64_t v___x_8987_; uint64_t v___x_8988_; uint64_t v___x_8989_; uint64_t v___x_8990_; uint8_t v___x_8991_;
v___x_8987_ = 1ULL;
v___x_8988_ = lean_uint64_sub(v_outPtr_8849_, v___x_8987_);
v___x_8989_ = 18446744073709551615ULL;
v___x_8990_ = lean_uint64_sub(v___x_8989_, v_outCap_8850_);
v___x_8991_ = lean_uint64_dec_le(v___x_8988_, v___x_8990_);
v___y_8979_ = v___x_8991_;
goto v___jp_8978_;
}
else
{
goto v___jp_8973_;
}
}
else
{
goto v___jp_8973_;
}
}
else
{
uint64_t v___x_8992_; uint8_t v___x_8993_;
v___x_8992_ = 4294967295ULL;
v___x_8993_ = lean_uint64_dec_le(v_outPtr_8849_, v___x_8992_);
if (v___x_8993_ == 0)
{
uint8_t v___x_8994_;
v___x_8994_ = 8;
v___y_8953_ = v___x_8994_;
goto v___jp_8952_;
}
else
{
uint8_t v___x_8995_;
v___x_8995_ = lean_uint64_dec_le(v_outCap_8850_, v___x_8992_);
if (v___x_8995_ == 0)
{
uint8_t v___x_8996_;
v___x_8996_ = 8;
v___y_8953_ = v___x_8996_;
goto v___jp_8952_;
}
else
{
uint64_t v___x_8997_; uint64_t v___x_8998_; uint8_t v___x_8999_;
v___x_8997_ = lean_uint64_add(v_outPtr_8849_, v_outCap_8850_);
v___x_8998_ = 4294967296ULL;
v___x_8999_ = lean_uint64_dec_le(v___x_8997_, v___x_8998_);
v___y_8979_ = v___x_8999_;
goto v___jp_8978_;
}
}
}
}
}
v___jp_9000_:
{
uint8_t v___x_9002_;
v___x_9002_ = lean_uint8_dec_eq(v_is32Bit_8851_, v___x_8968_);
if (v___x_9002_ == 0)
{
uint8_t v___x_9003_;
v___x_9003_ = lean_uint64_dec_eq(v_inPtr_8847_, v___x_8971_);
if (v___x_9003_ == 0)
{
if (v___x_8972_ == 0)
{
uint64_t v___x_9004_; uint64_t v___x_9005_; uint64_t v___x_9006_; uint64_t v___x_9007_; uint8_t v___x_9008_;
v___x_9004_ = 1ULL;
v___x_9005_ = lean_uint64_sub(v_inPtr_8847_, v___x_9004_);
v___x_9006_ = 18446744073709551615ULL;
v___x_9007_ = lean_uint64_sub(v___x_9006_, v_inLen_8848_);
v___x_9008_ = lean_uint64_dec_le(v___x_9005_, v___x_9007_);
v___y_8982_ = v___x_9008_;
goto v___jp_8981_;
}
else
{
v___y_8982_ = v___y_9001_;
goto v___jp_8981_;
}
}
else
{
v___y_8982_ = v___y_9001_;
goto v___jp_8981_;
}
}
else
{
uint64_t v___x_9009_; uint8_t v___x_9010_;
v___x_9009_ = 4294967295ULL;
v___x_9010_ = lean_uint64_dec_le(v_inPtr_8847_, v___x_9009_);
if (v___x_9010_ == 0)
{
uint8_t v___x_9011_;
v___x_9011_ = 8;
v___y_8953_ = v___x_9011_;
goto v___jp_8952_;
}
else
{
uint8_t v___x_9012_;
v___x_9012_ = lean_uint64_dec_le(v_inLen_8848_, v___x_9009_);
if (v___x_9012_ == 0)
{
uint8_t v___x_9013_;
v___x_9013_ = 8;
v___y_8953_ = v___x_9013_;
goto v___jp_8952_;
}
else
{
uint64_t v___x_9014_; uint64_t v___x_9015_; uint8_t v___x_9016_;
v___x_9014_ = lean_uint64_add(v_inPtr_8847_, v_inLen_8848_);
v___x_9015_ = 4294967296ULL;
v___x_9016_ = lean_uint64_dec_le(v___x_9014_, v___x_9015_);
v___y_8982_ = v___x_9016_;
goto v___jp_8981_;
}
}
}
}
v___jp_9017_:
{
uint8_t v___x_9019_;
v___x_9019_ = lean_uint64_dec_eq(v_outCap_8850_, v___x_8971_);
if (v___x_9019_ == 0)
{
uint8_t v___x_9020_;
v___x_9020_ = lean_uint64_dec_eq(v_outPtr_8849_, v___x_8971_);
if (v___x_9020_ == 0)
{
v___y_9001_ = v___y_9018_;
goto v___jp_9000_;
}
else
{
uint8_t v___x_9021_;
v___x_9021_ = 7;
v___y_8953_ = v___x_9021_;
goto v___jp_8952_;
}
}
else
{
v___y_9001_ = v___x_8969_;
goto v___jp_9000_;
}
}
}
v___jp_8859_:
{
uint64_t v___x_8862_; uint64_t v___x_8863_; uint64_t v___x_8864_; uint64_t v___x_8865_;
v___x_8862_ = lean_uint32_to_uint64(v___y_8860_);
v___x_8863_ = lean_uint32_to_uint64(v___y_8861_);
v___x_8864_ = lean_uint64_shift_left(v___x_8863_, v___x_8858_);
v___x_8865_ = lean_uint64_lor(v___x_8862_, v___x_8864_);
return v___x_8865_;
}
v___jp_8866_:
{
uint32_t v___x_8868_; uint8_t v___x_8869_;
v___x_8868_ = 4294967294;
v___x_8869_ = lean_uint32_dec_le(v_entryCount_8854_, v___x_8868_);
if (v___x_8869_ == 0)
{
uint32_t v___x_8870_;
v___x_8870_ = 4294967295;
v___y_8860_ = v___y_8867_;
v___y_8861_ = v___x_8870_;
goto v___jp_8859_;
}
else
{
uint32_t v___x_8871_; uint32_t v___x_8872_;
v___x_8871_ = 1;
v___x_8872_ = lean_uint32_add(v_entryCount_8854_, v___x_8871_);
v___y_8860_ = v___y_8867_;
v___y_8861_ = v___x_8872_;
goto v___jp_8859_;
}
}
v___jp_8873_:
{
if (v___y_8874_ == 0)
{
v___y_8860_ = v___y_8875_;
v___y_8861_ = v_entryCount_8854_;
goto v___jp_8859_;
}
else
{
v___y_8867_ = v___y_8875_;
goto v___jp_8866_;
}
}
v___jp_8876_:
{
if (v___y_8879_ == 0)
{
if (v___y_8880_ == 0)
{
uint32_t v___x_8884_; uint32_t v___x_8885_;
v___x_8884_ = 2051;
v___x_8885_ = lean_uint32_lor(v___x_8884_, v___y_8881_);
v___y_8860_ = v___x_8885_;
v___y_8861_ = v_entryCount_8854_;
goto v___jp_8859_;
}
else
{
if (v___y_8877_ == 0)
{
if (v___y_8882_ == 0)
{
if (v___y_8883_ == 0)
{
uint32_t v___x_8886_; uint32_t v___x_8887_;
v___x_8886_ = 4;
v___x_8887_ = lean_uint32_lor(v___x_8886_, v___y_8881_);
v___y_8860_ = v___x_8887_;
v___y_8861_ = v_entryCount_8854_;
goto v___jp_8859_;
}
else
{
uint32_t v___x_8888_; uint32_t v___x_8889_;
v___x_8888_ = 260;
v___x_8889_ = lean_uint32_lor(v___x_8888_, v___y_8881_);
v___y_8860_ = v___x_8889_;
v___y_8861_ = v_entryCount_8854_;
goto v___jp_8859_;
}
}
else
{
if (v___y_8878_ == 0)
{
uint32_t v___x_8890_;
v___x_8890_ = 257;
v___y_8867_ = v___x_8890_;
goto v___jp_8866_;
}
else
{
uint32_t v___x_8891_;
v___x_8891_ = 1281;
v___y_8867_ = v___x_8891_;
goto v___jp_8866_;
}
}
}
else
{
uint32_t v___x_8892_;
v___x_8892_ = 769;
v___y_8874_ = v___y_8882_;
v___y_8875_ = v___x_8892_;
goto v___jp_8873_;
}
}
}
else
{
uint32_t v___x_8893_; uint32_t v___x_8894_;
v___x_8893_ = 2;
v___x_8894_ = lean_uint32_lor(v___x_8893_, v___y_8881_);
if (v___y_8880_ == 0)
{
v___y_8860_ = v___x_8894_;
v___y_8861_ = v_entryCount_8854_;
goto v___jp_8859_;
}
else
{
v___y_8874_ = v___y_8882_;
v___y_8875_ = v___x_8894_;
goto v___jp_8873_;
}
}
}
v___jp_8895_:
{
uint8_t v___x_8903_; uint8_t v___x_8904_;
v___x_8903_ = 2;
v___x_8904_ = lean_uint8_dec_eq(v_normalizedAction_8856_, v___x_8903_);
if (v___x_8904_ == 0)
{
uint8_t v___x_8905_; uint8_t v___x_8906_;
v___x_8905_ = 3;
v___x_8906_ = lean_uint8_dec_eq(v_normalizedAction_8856_, v___x_8905_);
if (v___x_8906_ == 0)
{
uint8_t v___x_8907_; uint8_t v___x_8908_;
v___x_8907_ = 8;
v___x_8908_ = lean_uint8_dec_eq(v_normalizedAction_8856_, v___x_8907_);
v___y_8877_ = v___y_8896_;
v___y_8878_ = v___y_8897_;
v___y_8879_ = v___y_8899_;
v___y_8880_ = v___y_8900_;
v___y_8881_ = v___y_8901_;
v___y_8882_ = v___y_8902_;
v___y_8883_ = v___x_8908_;
goto v___jp_8876_;
}
else
{
v___y_8877_ = v___y_8896_;
v___y_8878_ = v___y_8897_;
v___y_8879_ = v___y_8899_;
v___y_8880_ = v___y_8900_;
v___y_8881_ = v___y_8901_;
v___y_8882_ = v___y_8902_;
v___y_8883_ = v___y_8898_;
goto v___jp_8876_;
}
}
else
{
v___y_8877_ = v___y_8896_;
v___y_8878_ = v___y_8897_;
v___y_8879_ = v___y_8899_;
v___y_8880_ = v___y_8900_;
v___y_8881_ = v___y_8901_;
v___y_8882_ = v___y_8902_;
v___y_8883_ = v___y_8898_;
goto v___jp_8876_;
}
}
v___jp_8909_:
{
uint8_t v___x_8915_; uint8_t v_isOpenThink_8916_; uint8_t v___x_8917_; uint8_t v___x_8918_;
v___x_8915_ = 4;
v_isOpenThink_8916_ = lean_uint8_dec_eq(v_normalizedAction_8856_, v___x_8915_);
v___x_8917_ = 5;
v___x_8918_ = lean_uint8_dec_eq(v_normalizedAction_8856_, v___x_8917_);
if (v___x_8918_ == 0)
{
uint8_t v___x_8919_; uint8_t v___x_8920_;
v___x_8919_ = 6;
v___x_8920_ = lean_uint8_dec_eq(v_normalizedAction_8856_, v___x_8919_);
if (v___x_8920_ == 0)
{
uint8_t v___x_8921_; uint8_t v___x_8922_;
v___x_8921_ = 7;
v___x_8922_ = lean_uint8_dec_eq(v_normalizedAction_8856_, v___x_8921_);
if (v___x_8922_ == 0)
{
uint8_t v___x_8923_; uint8_t v___x_8924_;
v___x_8923_ = 9;
v___x_8924_ = lean_uint8_dec_eq(v_normalizedAction_8856_, v___x_8923_);
if (v___x_8924_ == 0)
{
uint8_t v___x_8925_; uint8_t v___x_8926_;
v___x_8925_ = 10;
v___x_8926_ = lean_uint8_dec_eq(v_normalizedAction_8856_, v___x_8925_);
v___y_8896_ = v_isOpenThink_8916_;
v___y_8897_ = v___y_8910_;
v___y_8898_ = v___y_8912_;
v___y_8899_ = v___y_8911_;
v___y_8900_ = v___y_8914_;
v___y_8901_ = v___y_8913_;
v___y_8902_ = v___x_8926_;
goto v___jp_8895_;
}
else
{
v___y_8896_ = v_isOpenThink_8916_;
v___y_8897_ = v___y_8910_;
v___y_8898_ = v___y_8912_;
v___y_8899_ = v___y_8911_;
v___y_8900_ = v___y_8914_;
v___y_8901_ = v___y_8913_;
v___y_8902_ = v___y_8912_;
goto v___jp_8895_;
}
}
else
{
v___y_8896_ = v_isOpenThink_8916_;
v___y_8897_ = v___y_8910_;
v___y_8898_ = v___y_8912_;
v___y_8899_ = v___y_8911_;
v___y_8900_ = v___y_8914_;
v___y_8901_ = v___y_8913_;
v___y_8902_ = v___y_8912_;
goto v___jp_8895_;
}
}
else
{
v___y_8896_ = v_isOpenThink_8916_;
v___y_8897_ = v___y_8910_;
v___y_8898_ = v___y_8912_;
v___y_8899_ = v___y_8911_;
v___y_8900_ = v___y_8914_;
v___y_8901_ = v___y_8913_;
v___y_8902_ = v___y_8912_;
goto v___jp_8895_;
}
}
else
{
v___y_8896_ = v_isOpenThink_8916_;
v___y_8897_ = v___y_8910_;
v___y_8898_ = v___y_8912_;
v___y_8899_ = v___y_8911_;
v___y_8900_ = v___y_8914_;
v___y_8901_ = v___y_8913_;
v___y_8902_ = v___y_8912_;
goto v___jp_8895_;
}
}
v___jp_8927_:
{
uint8_t v_isDuplicate_8932_;
v_isDuplicate_8932_ = lean_uint64_dec_le(v_incomingSeq_8853_, v_lastAppliedSeq_8852_);
if (v_isDuplicate_8932_ == 0)
{
uint64_t v___x_8933_; uint64_t v___x_8934_; uint8_t v___x_8935_;
v___x_8933_ = lean_uint64_sub(v_incomingSeq_8853_, v_lastAppliedSeq_8852_);
v___x_8934_ = 1ULL;
v___x_8935_ = lean_uint64_dec_eq(v___x_8933_, v___x_8934_);
v___y_8910_ = v___y_8928_;
v___y_8911_ = v_isDuplicate_8932_;
v___y_8912_ = v___y_8929_;
v___y_8913_ = v___y_8931_;
v___y_8914_ = v___x_8935_;
goto v___jp_8909_;
}
else
{
v___y_8910_ = v___y_8928_;
v___y_8911_ = v_isDuplicate_8932_;
v___y_8912_ = v___y_8929_;
v___y_8913_ = v___y_8931_;
v___y_8914_ = v___y_8930_;
goto v___jp_8909_;
}
}
v___jp_8936_:
{
uint8_t v___x_8939_; uint8_t v___x_8940_;
v___x_8939_ = 0;
v___x_8940_ = lean_uint8_dec_eq(v___y_8937_, v___x_8939_);
if (v___x_8940_ == 0)
{
uint32_t v___x_8941_; uint32_t v___x_8942_; uint64_t v___x_8943_; uint64_t v___x_8944_; uint64_t v___x_8945_; uint64_t v___x_8946_;
v___x_8941_ = lean_uint8_to_uint32(v___y_8937_);
v___x_8942_ = lean_uint32_lor(v___x_8941_, v___y_8938_);
v___x_8943_ = lean_uint32_to_uint64(v___x_8942_);
v___x_8944_ = lean_uint32_to_uint64(v_entryCount_8854_);
v___x_8945_ = lean_uint64_shift_left(v___x_8944_, v___x_8858_);
v___x_8946_ = lean_uint64_lor(v___x_8943_, v___x_8945_);
return v___x_8946_;
}
else
{
uint8_t v___x_8947_; uint8_t v___x_8948_; uint8_t v___x_8949_;
v___x_8947_ = 0;
v___x_8948_ = 1;
v___x_8949_ = lean_uint8_dec_eq(v_thinkingOpen_8855_, v___x_8948_);
if (v___x_8949_ == 0)
{
uint32_t v___x_8950_;
v___x_8950_ = 0;
v___y_8928_ = v___x_8949_;
v___y_8929_ = v___x_8940_;
v___y_8930_ = v___x_8947_;
v___y_8931_ = v___x_8950_;
goto v___jp_8927_;
}
else
{
uint32_t v___x_8951_;
v___x_8951_ = 512;
v___y_8928_ = v___x_8949_;
v___y_8929_ = v___x_8940_;
v___y_8930_ = v___x_8947_;
v___y_8931_ = v___x_8951_;
goto v___jp_8927_;
}
}
}
v___jp_8952_:
{
uint8_t v___x_8954_; uint8_t v___x_8955_;
v___x_8954_ = 1;
v___x_8955_ = lean_uint8_dec_eq(v_thinkingOpen_8855_, v___x_8954_);
if (v___x_8955_ == 0)
{
uint32_t v___x_8956_;
v___x_8956_ = 0;
v___y_8937_ = v___y_8953_;
v___y_8938_ = v___x_8956_;
goto v___jp_8936_;
}
else
{
uint32_t v___x_8957_;
v___x_8957_ = 512;
v___y_8937_ = v___y_8953_;
v___y_8938_ = v___x_8957_;
goto v___jp_8936_;
}
}
v___jp_8958_:
{
uint8_t v___x_8959_;
v___x_8959_ = lean_uint64_dec_le(v___x_8858_, v_outCap_8850_);
if (v___x_8959_ == 0)
{
uint8_t v___x_8960_;
v___x_8960_ = 5;
v___y_8953_ = v___x_8960_;
goto v___jp_8952_;
}
else
{
uint8_t v___x_8961_;
v___x_8961_ = 0;
v___y_8953_ = v___x_8961_;
goto v___jp_8952_;
}
}
v___jp_8962_:
{
uint8_t v___x_8963_;
v___x_8963_ = lean_uint64_dec_le(v_outCap_8850_, v_inPtr_8847_);
if (v___x_8963_ == 0)
{
uint8_t v___x_8964_;
v___x_8964_ = 9;
v___y_8953_ = v___x_8964_;
goto v___jp_8952_;
}
else
{
uint64_t v___x_8965_; uint8_t v___x_8966_;
v___x_8965_ = lean_uint64_sub(v_inPtr_8847_, v_outCap_8850_);
v___x_8966_ = lean_uint64_dec_le(v_outPtr_8849_, v___x_8965_);
if (v___x_8966_ == 0)
{
uint8_t v___x_8967_;
v___x_8967_ = 9;
v___y_8953_ = v___x_8967_;
goto v___jp_8952_;
}
else
{
goto v___jp_8958_;
}
}
}
}
}

LEAN_EXPORT uint64_t orb_placement_merge_step(uint64_t v_curRev_9176_, uint64_t v_incRev_9177_, uint32_t v_pendingOpId_9178_, uint32_t v_ackOpId_9179_, uint8_t v_sourceKind_9180_, uint8_t v_hasPlacement_9181_){
_start:
{
uint32_t v___y_9183_; uint32_t v___y_9184_; uint32_t v___y_9191_; uint32_t v___y_9192_; uint32_t v___y_9193_; uint32_t v___y_9209_; uint32_t v___y_9210_; uint32_t v___y_9216_; uint32_t v___y_9222_; uint8_t v___x_9225_; uint8_t v___x_9226_;
v___x_9225_ = 3;
v___x_9226_ = lean_uint8_dec_le(v_sourceKind_9180_, v___x_9225_);
if (v___x_9226_ == 0)
{
uint32_t v___x_9227_;
v___x_9227_ = 2;
v___y_9216_ = v___x_9227_;
goto v___jp_9215_;
}
else
{
uint8_t v___x_9228_; uint8_t v___x_9229_;
v___x_9228_ = 2;
v___x_9229_ = lean_uint8_dec_eq(v_sourceKind_9180_, v___x_9228_);
if (v___x_9229_ == 0)
{
uint8_t v___x_9230_;
v___x_9230_ = lean_uint8_dec_eq(v_sourceKind_9180_, v___x_9225_);
if (v___x_9230_ == 0)
{
uint8_t v___x_9231_; uint8_t v___x_9232_;
v___x_9231_ = 1;
v___x_9232_ = lean_uint8_dec_eq(v_hasPlacement_9181_, v___x_9231_);
if (v___x_9232_ == 0)
{
uint32_t v___x_9233_;
v___x_9233_ = 3;
v___y_9216_ = v___x_9233_;
goto v___jp_9215_;
}
else
{
uint32_t v___x_9234_; uint8_t v___x_9235_;
v___x_9234_ = 0;
v___x_9235_ = lean_uint32_dec_eq(v_pendingOpId_9178_, v___x_9234_);
if (v___x_9235_ == 0)
{
uint8_t v___x_9236_;
v___x_9236_ = lean_uint64_dec_lt(v_curRev_9176_, v_incRev_9177_);
if (v___x_9236_ == 0)
{
uint8_t v___x_9237_;
v___x_9237_ = lean_uint8_dec_eq(v_sourceKind_9180_, v___x_9231_);
if (v___x_9237_ == 0)
{
uint32_t v___x_9238_;
v___x_9238_ = 5;
v___y_9216_ = v___x_9238_;
goto v___jp_9215_;
}
else
{
uint8_t v___x_9239_;
v___x_9239_ = lean_uint32_dec_eq(v_ackOpId_9179_, v_pendingOpId_9178_);
if (v___x_9239_ == 0)
{
uint32_t v___x_9240_;
v___x_9240_ = 5;
v___y_9216_ = v___x_9240_;
goto v___jp_9215_;
}
else
{
uint8_t v___x_9241_;
v___x_9241_ = lean_uint64_dec_le(v_curRev_9176_, v_incRev_9177_);
if (v___x_9241_ == 0)
{
uint32_t v___x_9242_;
v___x_9242_ = 5;
v___y_9216_ = v___x_9242_;
goto v___jp_9215_;
}
else
{
uint32_t v___x_9243_;
v___x_9243_ = 1793;
v___y_9216_ = v___x_9243_;
goto v___jp_9215_;
}
}
}
}
else
{
uint8_t v___x_9244_; uint8_t v___x_9245_;
v___x_9244_ = 0;
v___x_9245_ = lean_uint8_dec_eq(v_sourceKind_9180_, v___x_9244_);
if (v___x_9245_ == 0)
{
uint8_t v___x_9246_;
v___x_9246_ = lean_uint8_dec_eq(v_sourceKind_9180_, v___x_9231_);
if (v___x_9246_ == 0)
{
uint32_t v___x_9247_;
v___x_9247_ = 1793;
v___y_9216_ = v___x_9247_;
goto v___jp_9215_;
}
else
{
uint8_t v___x_9248_;
v___x_9248_ = lean_uint32_dec_lt(v_ackOpId_9179_, v_pendingOpId_9178_);
if (v___x_9248_ == 0)
{
uint32_t v___x_9249_;
v___x_9249_ = 1793;
v___y_9216_ = v___x_9249_;
goto v___jp_9215_;
}
else
{
uint32_t v___x_9250_;
v___x_9250_ = 1281;
v___y_9216_ = v___x_9250_;
goto v___jp_9215_;
}
}
}
else
{
uint32_t v___x_9251_;
v___x_9251_ = 1281;
v___y_9216_ = v___x_9251_;
goto v___jp_9215_;
}
}
}
else
{
uint8_t v___x_9252_;
v___x_9252_ = lean_uint8_dec_eq(v_sourceKind_9180_, v___x_9231_);
if (v___x_9252_ == 0)
{
uint8_t v___x_9253_;
v___x_9253_ = lean_uint64_dec_le(v_curRev_9176_, v_incRev_9177_);
if (v___x_9253_ == 0)
{
uint32_t v___x_9254_;
v___x_9254_ = 4;
v___y_9216_ = v___x_9254_;
goto v___jp_9215_;
}
else
{
uint8_t v___x_9255_;
v___x_9255_ = lean_uint64_dec_lt(v_curRev_9176_, v_incRev_9177_);
if (v___x_9255_ == 0)
{
v___y_9222_ = v___x_9234_;
goto v___jp_9221_;
}
else
{
uint32_t v___x_9256_;
v___x_9256_ = 1024;
v___y_9222_ = v___x_9256_;
goto v___jp_9221_;
}
}
}
else
{
uint8_t v___x_9257_;
v___x_9257_ = lean_uint64_dec_le(v_curRev_9176_, v_incRev_9177_);
if (v___x_9257_ == 0)
{
uint32_t v___x_9258_;
v___x_9258_ = 4;
v___y_9216_ = v___x_9258_;
goto v___jp_9215_;
}
else
{
uint32_t v___x_9259_;
v___x_9259_ = 1281;
v___y_9216_ = v___x_9259_;
goto v___jp_9215_;
}
}
}
}
}
else
{
uint32_t v___x_9260_; uint8_t v___x_9261_;
v___x_9260_ = 0;
v___x_9261_ = lean_uint32_dec_eq(v_pendingOpId_9178_, v___x_9260_);
if (v___x_9261_ == 0)
{
uint8_t v___x_9262_;
v___x_9262_ = lean_uint32_dec_eq(v_ackOpId_9179_, v_pendingOpId_9178_);
if (v___x_9262_ == 0)
{
uint32_t v___x_9263_;
v___x_9263_ = 6;
v___y_9216_ = v___x_9263_;
goto v___jp_9215_;
}
else
{
uint32_t v___x_9264_;
v___x_9264_ = 1793;
v___y_9216_ = v___x_9264_;
goto v___jp_9215_;
}
}
else
{
uint32_t v___x_9265_;
v___x_9265_ = 6;
v___y_9216_ = v___x_9265_;
goto v___jp_9215_;
}
}
}
else
{
uint8_t v___x_9266_; uint8_t v___x_9267_;
v___x_9266_ = 1;
v___x_9267_ = lean_uint8_dec_eq(v_hasPlacement_9181_, v___x_9266_);
if (v___x_9267_ == 0)
{
uint32_t v___x_9268_;
v___x_9268_ = 3;
v___y_9216_ = v___x_9268_;
goto v___jp_9215_;
}
else
{
uint32_t v___x_9269_; uint8_t v___x_9270_;
v___x_9269_ = 0;
v___x_9270_ = lean_uint32_dec_eq(v_ackOpId_9179_, v___x_9269_);
if (v___x_9270_ == 0)
{
uint32_t v___x_9271_;
v___x_9271_ = 1281;
v___y_9216_ = v___x_9271_;
goto v___jp_9215_;
}
else
{
uint32_t v___x_9272_;
v___x_9272_ = 3;
v___y_9216_ = v___x_9272_;
goto v___jp_9215_;
}
}
}
}
v___jp_9182_:
{
uint64_t v___x_9185_; uint64_t v___x_9186_; uint64_t v___x_9187_; uint64_t v___x_9188_; uint64_t v___x_9189_;
v___x_9185_ = lean_uint32_to_uint64(v___y_9183_);
v___x_9186_ = lean_uint32_to_uint64(v___y_9184_);
v___x_9187_ = 32ULL;
v___x_9188_ = lean_uint64_shift_left(v___x_9186_, v___x_9187_);
v___x_9189_ = lean_uint64_lor(v___x_9185_, v___x_9188_);
return v___x_9189_;
}
v___jp_9190_:
{
uint8_t v___x_9194_; uint8_t v___x_9195_;
v___x_9194_ = 3;
v___x_9195_ = lean_uint8_dec_le(v_sourceKind_9180_, v___x_9194_);
if (v___x_9195_ == 0)
{
v___y_9183_ = v___y_9191_;
v___y_9184_ = v___y_9192_;
goto v___jp_9182_;
}
else
{
uint8_t v___x_9196_; uint8_t v___x_9197_;
v___x_9196_ = 2;
v___x_9197_ = lean_uint8_dec_eq(v_sourceKind_9180_, v___x_9196_);
if (v___x_9197_ == 0)
{
uint8_t v___x_9198_;
v___x_9198_ = lean_uint8_dec_eq(v_sourceKind_9180_, v___x_9194_);
if (v___x_9198_ == 0)
{
uint8_t v___x_9199_; uint8_t v___x_9200_;
v___x_9199_ = 1;
v___x_9200_ = lean_uint8_dec_eq(v_hasPlacement_9181_, v___x_9199_);
if (v___x_9200_ == 0)
{
v___y_9183_ = v___y_9191_;
v___y_9184_ = v___y_9192_;
goto v___jp_9182_;
}
else
{
uint32_t v___x_9201_; uint8_t v___x_9202_;
v___x_9201_ = 0;
v___x_9202_ = lean_uint32_dec_eq(v_pendingOpId_9178_, v___x_9201_);
if (v___x_9202_ == 0)
{
uint8_t v___x_9203_;
v___x_9203_ = lean_uint64_dec_lt(v_curRev_9176_, v_incRev_9177_);
if (v___x_9203_ == 0)
{
uint8_t v___x_9204_;
v___x_9204_ = lean_uint8_dec_eq(v_sourceKind_9180_, v___x_9199_);
if (v___x_9204_ == 0)
{
v___y_9183_ = v___y_9191_;
v___y_9184_ = v___y_9192_;
goto v___jp_9182_;
}
else
{
uint8_t v___x_9205_;
v___x_9205_ = lean_uint32_dec_eq(v_ackOpId_9179_, v_pendingOpId_9178_);
if (v___x_9205_ == 0)
{
v___y_9183_ = v___y_9191_;
v___y_9184_ = v___y_9192_;
goto v___jp_9182_;
}
else
{
uint8_t v___x_9206_;
v___x_9206_ = lean_uint64_dec_le(v_curRev_9176_, v_incRev_9177_);
if (v___x_9206_ == 0)
{
v___y_9183_ = v___y_9191_;
v___y_9184_ = v___y_9192_;
goto v___jp_9182_;
}
else
{
v___y_9183_ = v___y_9191_;
v___y_9184_ = v___y_9193_;
goto v___jp_9182_;
}
}
}
}
else
{
v___y_9183_ = v___y_9191_;
v___y_9184_ = v___y_9193_;
goto v___jp_9182_;
}
}
else
{
uint8_t v___x_9207_;
v___x_9207_ = lean_uint64_dec_le(v_curRev_9176_, v_incRev_9177_);
if (v___x_9207_ == 0)
{
v___y_9183_ = v___y_9191_;
v___y_9184_ = v___y_9192_;
goto v___jp_9182_;
}
else
{
v___y_9183_ = v___y_9191_;
v___y_9184_ = v___y_9193_;
goto v___jp_9182_;
}
}
}
}
else
{
v___y_9183_ = v___y_9191_;
v___y_9184_ = v___y_9192_;
goto v___jp_9182_;
}
}
else
{
v___y_9183_ = v___y_9191_;
v___y_9184_ = v___y_9192_;
goto v___jp_9182_;
}
}
}
v___jp_9208_:
{
uint64_t v___x_9211_; uint8_t v___x_9212_;
v___x_9211_ = 4294967295ULL;
v___x_9212_ = lean_uint64_dec_le(v_incRev_9177_, v___x_9211_);
if (v___x_9212_ == 0)
{
uint32_t v___x_9213_;
v___x_9213_ = 4294967295;
v___y_9191_ = v___y_9209_;
v___y_9192_ = v___y_9210_;
v___y_9193_ = v___x_9213_;
goto v___jp_9190_;
}
else
{
uint32_t v___x_9214_;
v___x_9214_ = lean_uint64_to_uint32(v_incRev_9177_);
v___y_9191_ = v___y_9209_;
v___y_9192_ = v___y_9210_;
v___y_9193_ = v___x_9214_;
goto v___jp_9190_;
}
}
v___jp_9215_:
{
uint64_t v___x_9217_; uint8_t v___x_9218_;
v___x_9217_ = 4294967295ULL;
v___x_9218_ = lean_uint64_dec_le(v_curRev_9176_, v___x_9217_);
if (v___x_9218_ == 0)
{
uint32_t v___x_9219_;
v___x_9219_ = 4294967295;
v___y_9209_ = v___y_9216_;
v___y_9210_ = v___x_9219_;
goto v___jp_9208_;
}
else
{
uint32_t v___x_9220_;
v___x_9220_ = lean_uint64_to_uint32(v_curRev_9176_);
v___y_9209_ = v___y_9216_;
v___y_9210_ = v___x_9220_;
goto v___jp_9208_;
}
}
v___jp_9221_:
{
uint32_t v___x_9223_; uint32_t v___x_9224_;
v___x_9223_ = 257;
v___x_9224_ = lean_uint32_lor(v___x_9223_, v___y_9222_);
v___y_9216_ = v___x_9224_;
goto v___jp_9215_;
}
}
}

LEAN_EXPORT uint32_t orb_proxy_sse_scan_step(uint8_t v_lineKind_9287_, uint8_t v_hasDoneToken_9288_, uint8_t v_inThinkTag_9289_, uint8_t v_nextStartsThink_9290_, uint8_t v_nextEndsThink_9291_, uint8_t v_hasNonEmptyContent_9292_){
_start:
{
uint32_t v___y_9294_; uint32_t v___y_9295_; uint8_t v___x_9299_; uint32_t v___y_9301_; uint8_t v___x_9309_; uint32_t v___y_9311_;
v___x_9299_ = 1;
v___x_9309_ = lean_uint8_dec_eq(v_inThinkTag_9289_, v___x_9299_);
if (v___x_9309_ == 0)
{
uint32_t v___x_9323_;
v___x_9323_ = 0;
v___y_9311_ = v___x_9323_;
goto v___jp_9310_;
}
else
{
uint32_t v___x_9324_;
v___x_9324_ = 512;
v___y_9311_ = v___x_9324_;
goto v___jp_9310_;
}
v___jp_9293_:
{
uint32_t v___x_9296_; uint32_t v___x_9297_; uint32_t v___x_9298_;
v___x_9296_ = 2;
v___x_9297_ = lean_uint32_lor(v___x_9296_, v___y_9295_);
v___x_9298_ = lean_uint32_lor(v___x_9297_, v___y_9294_);
return v___x_9298_;
}
v___jp_9300_:
{
uint8_t v___x_9302_;
v___x_9302_ = lean_uint8_dec_eq(v_hasNonEmptyContent_9292_, v___x_9299_);
if (v___x_9302_ == 0)
{
uint32_t v___x_9303_;
v___x_9303_ = 0;
v___y_9294_ = v___y_9301_;
v___y_9295_ = v___x_9303_;
goto v___jp_9293_;
}
else
{
uint32_t v___x_9304_;
v___x_9304_ = 256;
v___y_9294_ = v___y_9301_;
v___y_9295_ = v___x_9304_;
goto v___jp_9293_;
}
}
v___jp_9305_:
{
uint32_t v___x_9306_;
v___x_9306_ = 0;
v___y_9301_ = v___x_9306_;
goto v___jp_9300_;
}
v___jp_9307_:
{
uint32_t v___x_9308_;
v___x_9308_ = 512;
v___y_9301_ = v___x_9308_;
goto v___jp_9300_;
}
v___jp_9310_:
{
uint8_t v___x_9312_; uint8_t v___x_9313_;
v___x_9312_ = 0;
v___x_9313_ = lean_uint8_dec_eq(v_lineKind_9287_, v___x_9312_);
if (v___x_9313_ == 0)
{
uint8_t v___x_9314_; uint8_t v___x_9315_;
v___x_9314_ = 2;
v___x_9315_ = lean_uint8_dec_eq(v_lineKind_9287_, v___x_9314_);
if (v___x_9315_ == 0)
{
uint32_t v___x_9316_; uint32_t v___x_9317_;
v___x_9316_ = 1;
v___x_9317_ = lean_uint32_lor(v___x_9316_, v___y_9311_);
return v___x_9317_;
}
else
{
uint8_t v___x_9318_;
v___x_9318_ = lean_uint8_dec_eq(v_hasDoneToken_9288_, v___x_9299_);
if (v___x_9318_ == 0)
{
uint8_t v___x_9319_;
v___x_9319_ = lean_uint8_dec_eq(v_nextEndsThink_9291_, v___x_9299_);
if (v___x_9319_ == 0)
{
uint8_t v___x_9320_;
v___x_9320_ = lean_uint8_dec_eq(v_nextStartsThink_9290_, v___x_9299_);
if (v___x_9320_ == 0)
{
if (v___x_9309_ == 0)
{
goto v___jp_9305_;
}
else
{
goto v___jp_9307_;
}
}
else
{
goto v___jp_9307_;
}
}
else
{
goto v___jp_9305_;
}
}
else
{
uint32_t v___x_9321_; uint32_t v___x_9322_;
v___x_9321_ = 3;
v___x_9322_ = lean_uint32_lor(v___x_9321_, v___y_9311_);
return v___x_9322_;
}
}
}
else
{
return v___y_9311_;
}
}
}
}

LEAN_EXPORT uint64_t orb_stream_repetition_step(uint8_t v_cancelledOrExpired_9378_, uint8_t v_collisionDetected_9379_, uint32_t v_startPos_9380_, uint32_t v_prevEnd_9381_, uint32_t v_candidateLen_9382_, uint32_t v_prevCount_9383_, uint32_t v_requiredRepeats_9384_, uint64_t v_comparisons_9385_, uint64_t v_comparisonBudget_9386_){
_start:
{
uint32_t v___y_9388_; uint32_t v___y_9389_; uint32_t v___y_9390_; uint32_t v___y_9398_; uint32_t v___y_9399_; uint8_t v___x_9409_; uint8_t v___x_9410_;
v___x_9409_ = 1;
v___x_9410_ = lean_uint8_dec_eq(v_cancelledOrExpired_9378_, v___x_9409_);
if (v___x_9410_ == 0)
{
uint8_t v___x_9411_;
v___x_9411_ = lean_uint8_dec_eq(v_collisionDetected_9379_, v___x_9409_);
if (v___x_9411_ == 0)
{
uint8_t v___x_9412_;
v___x_9412_ = lean_uint64_dec_lt(v_comparisonBudget_9386_, v_comparisons_9385_);
if (v___x_9412_ == 0)
{
uint32_t v___x_9413_; uint8_t v___x_9414_;
v___x_9413_ = 0;
v___x_9414_ = lean_uint32_dec_eq(v_candidateLen_9382_, v___x_9413_);
if (v___x_9414_ == 0)
{
uint32_t v___x_9415_; uint8_t v___x_9416_;
v___x_9415_ = 2;
v___x_9416_ = lean_uint32_dec_lt(v_requiredRepeats_9384_, v___x_9415_);
if (v___x_9416_ == 0)
{
uint8_t v___x_9417_;
v___x_9417_ = lean_uint32_dec_lt(v_startPos_9380_, v_prevEnd_9381_);
if (v___x_9417_ == 0)
{
uint64_t v___x_9418_; uint64_t v___x_9419_; uint64_t v___x_9420_; uint64_t v___x_9421_; uint8_t v_contiguous_9422_; uint32_t v___y_9424_;
v___x_9418_ = lean_uint32_to_uint64(v_startPos_9380_);
v___x_9419_ = lean_uint32_to_uint64(v_prevEnd_9381_);
v___x_9420_ = lean_uint32_to_uint64(v_candidateLen_9382_);
v___x_9421_ = lean_uint64_add(v___x_9419_, v___x_9420_);
v_contiguous_9422_ = lean_uint64_dec_le(v___x_9418_, v___x_9421_);
if (v_contiguous_9422_ == 0)
{
uint32_t v___x_9426_;
v___x_9426_ = 1;
v___y_9424_ = v___x_9426_;
goto v___jp_9423_;
}
else
{
uint32_t v___x_9427_; uint8_t v___x_9428_;
v___x_9427_ = 4294967295;
v___x_9428_ = lean_uint32_dec_lt(v_prevCount_9383_, v___x_9427_);
if (v___x_9428_ == 0)
{
v___y_9424_ = v___x_9427_;
goto v___jp_9423_;
}
else
{
uint32_t v___x_9429_; uint32_t v___x_9430_;
v___x_9429_ = 1;
v___x_9430_ = lean_uint32_add(v_prevCount_9383_, v___x_9429_);
v___y_9424_ = v___x_9430_;
goto v___jp_9423_;
}
}
v___jp_9423_:
{
if (v_contiguous_9422_ == 0)
{
uint32_t v___x_9425_;
v___x_9425_ = 512;
v___y_9398_ = v___y_9424_;
v___y_9399_ = v___x_9425_;
goto v___jp_9397_;
}
else
{
v___y_9398_ = v___y_9424_;
v___y_9399_ = v___x_9413_;
goto v___jp_9397_;
}
}
}
else
{
uint64_t v___x_9431_; uint64_t v___x_9432_; uint64_t v___x_9433_;
v___x_9431_ = lean_uint32_to_uint64(v_prevCount_9383_);
v___x_9432_ = 32ULL;
v___x_9433_ = lean_uint64_shift_left(v___x_9431_, v___x_9432_);
return v___x_9433_;
}
}
else
{
goto v___jp_9403_;
}
}
else
{
goto v___jp_9403_;
}
}
else
{
goto v___jp_9403_;
}
}
else
{
goto v___jp_9403_;
}
}
else
{
goto v___jp_9403_;
}
v___jp_9387_:
{
uint32_t v_lo32_9391_; uint64_t v___x_9392_; uint64_t v___x_9393_; uint64_t v___x_9394_; uint64_t v___x_9395_; uint64_t v___x_9396_;
v_lo32_9391_ = lean_uint32_lor(v___y_9390_, v___y_9389_);
v___x_9392_ = lean_uint32_to_uint64(v_lo32_9391_);
v___x_9393_ = lean_uint32_to_uint64(v___y_9388_);
v___x_9394_ = 32ULL;
v___x_9395_ = lean_uint64_shift_left(v___x_9393_, v___x_9394_);
v___x_9396_ = lean_uint64_lor(v___x_9392_, v___x_9395_);
return v___x_9396_;
}
v___jp_9397_:
{
uint8_t v_hit_9400_;
v_hit_9400_ = lean_uint32_dec_le(v_requiredRepeats_9384_, v___y_9398_);
if (v_hit_9400_ == 0)
{
uint32_t v___x_9401_;
v___x_9401_ = 1;
v___y_9388_ = v___y_9398_;
v___y_9389_ = v___y_9399_;
v___y_9390_ = v___x_9401_;
goto v___jp_9387_;
}
else
{
uint32_t v___x_9402_;
v___x_9402_ = 259;
v___y_9388_ = v___y_9398_;
v___y_9389_ = v___y_9399_;
v___y_9390_ = v___x_9402_;
goto v___jp_9387_;
}
}
v___jp_9403_:
{
uint64_t v___x_9404_; uint64_t v___x_9405_; uint64_t v___x_9406_; uint64_t v___x_9407_; uint64_t v___x_9408_;
v___x_9404_ = 2ULL;
v___x_9405_ = lean_uint32_to_uint64(v_prevCount_9383_);
v___x_9406_ = 32ULL;
v___x_9407_ = lean_uint64_shift_left(v___x_9405_, v___x_9406_);
v___x_9408_ = lean_uint64_lor(v___x_9404_, v___x_9407_);
return v___x_9408_;
}
}
}

LEAN_EXPORT uint64_t orb_http_rate_limit_classify_step(uint32_t v_httpStatus_9454_, uint8_t v_hasQuotaBodyHint_9455_, uint8_t v_hasAuthFailureHint_9456_, uint64_t v_retryAfterSecs_9457_, uint64_t v_maxCooldownSecs_9458_){
_start:
{
uint32_t v___y_9460_; uint32_t v___y_9461_; uint32_t v___y_9462_; uint32_t v___y_9472_; uint32_t v___y_9473_; uint32_t v___y_9476_; uint32_t v___y_9477_; uint32_t v___y_9478_; uint32_t v___y_9486_; uint32_t v___y_9487_; uint64_t v___y_9488_; uint32_t v___y_9494_; uint32_t v___y_9495_; uint64_t v___y_9496_; uint64_t v___y_9497_; uint32_t v___y_9500_; uint64_t v___y_9501_; uint32_t v___y_9502_; uint64_t v___y_9503_; uint64_t v___y_9504_; uint64_t v___y_9507_; uint32_t v___y_9508_; uint32_t v___y_9509_; uint64_t v___y_9510_; uint32_t v___y_9516_; uint32_t v___x_9539_; uint8_t v___x_9540_;
v___x_9539_ = 429;
v___x_9540_ = lean_uint32_dec_eq(v_httpStatus_9454_, v___x_9539_);
if (v___x_9540_ == 0)
{
uint32_t v___x_9541_; uint8_t v___x_9542_;
v___x_9541_ = 402;
v___x_9542_ = lean_uint32_dec_eq(v_httpStatus_9454_, v___x_9541_);
if (v___x_9542_ == 0)
{
uint32_t v___x_9543_; uint8_t v___x_9544_;
v___x_9543_ = 401;
v___x_9544_ = lean_uint32_dec_eq(v_httpStatus_9454_, v___x_9543_);
if (v___x_9544_ == 0)
{
uint32_t v___x_9545_; uint8_t v___x_9546_;
v___x_9545_ = 403;
v___x_9546_ = lean_uint32_dec_eq(v_httpStatus_9454_, v___x_9545_);
if (v___x_9546_ == 0)
{
goto v___jp_9529_;
}
else
{
uint8_t v___x_9547_; uint8_t v___x_9548_;
v___x_9547_ = 1;
v___x_9548_ = lean_uint8_dec_eq(v_hasAuthFailureHint_9456_, v___x_9547_);
if (v___x_9548_ == 0)
{
goto v___jp_9529_;
}
else
{
goto v___jp_9523_;
}
}
}
else
{
goto v___jp_9523_;
}
}
else
{
uint32_t v___x_9549_;
v___x_9549_ = 2;
v___y_9516_ = v___x_9549_;
goto v___jp_9515_;
}
}
else
{
uint8_t v___x_9550_; uint8_t v___x_9551_;
v___x_9550_ = 1;
v___x_9551_ = lean_uint8_dec_eq(v_hasQuotaBodyHint_9455_, v___x_9550_);
if (v___x_9551_ == 0)
{
uint32_t v___x_9552_;
v___x_9552_ = 1;
v___y_9516_ = v___x_9552_;
goto v___jp_9515_;
}
else
{
uint32_t v___x_9553_;
v___x_9553_ = 2;
v___y_9516_ = v___x_9553_;
goto v___jp_9515_;
}
}
v___jp_9459_:
{
uint32_t v___x_9463_; uint32_t v___x_9464_; uint32_t v_lo32_9465_; uint64_t v___x_9466_; uint64_t v___x_9467_; uint64_t v___x_9468_; uint64_t v___x_9469_; uint64_t v___x_9470_;
v___x_9463_ = 256;
v___x_9464_ = lean_uint32_lor(v___y_9460_, v___x_9463_);
v_lo32_9465_ = lean_uint32_lor(v___x_9464_, v___y_9462_);
v___x_9466_ = lean_uint32_to_uint64(v_lo32_9465_);
v___x_9467_ = lean_uint32_to_uint64(v___y_9461_);
v___x_9468_ = 32ULL;
v___x_9469_ = lean_uint64_shift_left(v___x_9467_, v___x_9468_);
v___x_9470_ = lean_uint64_lor(v___x_9466_, v___x_9469_);
return v___x_9470_;
}
v___jp_9471_:
{
uint32_t v___x_9474_;
v___x_9474_ = 512;
v___y_9460_ = v___y_9472_;
v___y_9461_ = v___y_9473_;
v___y_9462_ = v___x_9474_;
goto v___jp_9459_;
}
v___jp_9475_:
{
uint32_t v___x_9479_; uint8_t v___x_9480_;
v___x_9479_ = 1;
v___x_9480_ = lean_uint32_dec_eq(v___y_9476_, v___x_9479_);
if (v___x_9480_ == 0)
{
uint32_t v___x_9481_; uint8_t v___x_9482_;
v___x_9481_ = 4;
v___x_9482_ = lean_uint32_dec_eq(v___y_9476_, v___x_9481_);
if (v___x_9482_ == 0)
{
uint32_t v___x_9483_; uint8_t v___x_9484_;
v___x_9483_ = 5;
v___x_9484_ = lean_uint32_dec_eq(v___y_9476_, v___x_9483_);
if (v___x_9484_ == 0)
{
v___y_9460_ = v___y_9476_;
v___y_9461_ = v___y_9478_;
v___y_9462_ = v___y_9477_;
goto v___jp_9459_;
}
else
{
v___y_9472_ = v___y_9476_;
v___y_9473_ = v___y_9478_;
goto v___jp_9471_;
}
}
else
{
v___y_9472_ = v___y_9476_;
v___y_9473_ = v___y_9478_;
goto v___jp_9471_;
}
}
else
{
v___y_9472_ = v___y_9476_;
v___y_9473_ = v___y_9478_;
goto v___jp_9471_;
}
}
v___jp_9485_:
{
uint64_t v___x_9489_; uint8_t v___x_9490_;
v___x_9489_ = 4294967295ULL;
v___x_9490_ = lean_uint64_dec_le(v___y_9488_, v___x_9489_);
if (v___x_9490_ == 0)
{
uint32_t v___x_9491_;
v___x_9491_ = 4294967295;
v___y_9476_ = v___y_9486_;
v___y_9477_ = v___y_9487_;
v___y_9478_ = v___x_9491_;
goto v___jp_9475_;
}
else
{
uint32_t v___x_9492_;
v___x_9492_ = lean_uint64_to_uint32(v___y_9488_);
v___y_9476_ = v___y_9486_;
v___y_9477_ = v___y_9487_;
v___y_9478_ = v___x_9492_;
goto v___jp_9475_;
}
}
v___jp_9493_:
{
uint8_t v___x_9498_;
v___x_9498_ = lean_uint64_dec_le(v___y_9497_, v___y_9496_);
if (v___x_9498_ == 0)
{
v___y_9486_ = v___y_9494_;
v___y_9487_ = v___y_9495_;
v___y_9488_ = v___y_9496_;
goto v___jp_9485_;
}
else
{
v___y_9486_ = v___y_9494_;
v___y_9487_ = v___y_9495_;
v___y_9488_ = v___y_9497_;
goto v___jp_9485_;
}
}
v___jp_9499_:
{
uint8_t v___x_9505_;
v___x_9505_ = lean_uint64_dec_eq(v_retryAfterSecs_9457_, v___y_9501_);
if (v___x_9505_ == 0)
{
v___y_9494_ = v___y_9500_;
v___y_9495_ = v___y_9502_;
v___y_9496_ = v___y_9503_;
v___y_9497_ = v_retryAfterSecs_9457_;
goto v___jp_9493_;
}
else
{
v___y_9494_ = v___y_9500_;
v___y_9495_ = v___y_9502_;
v___y_9496_ = v___y_9503_;
v___y_9497_ = v___y_9504_;
goto v___jp_9493_;
}
}
v___jp_9506_:
{
uint32_t v___x_9511_; uint8_t v___x_9512_;
v___x_9511_ = 2;
v___x_9512_ = lean_uint32_dec_eq(v___y_9508_, v___x_9511_);
if (v___x_9512_ == 0)
{
uint64_t v___x_9513_;
v___x_9513_ = 15ULL;
v___y_9500_ = v___y_9508_;
v___y_9501_ = v___y_9507_;
v___y_9502_ = v___y_9509_;
v___y_9503_ = v___y_9510_;
v___y_9504_ = v___x_9513_;
goto v___jp_9499_;
}
else
{
uint64_t v___x_9514_;
v___x_9514_ = 300ULL;
v___y_9500_ = v___y_9508_;
v___y_9501_ = v___y_9507_;
v___y_9502_ = v___y_9509_;
v___y_9503_ = v___y_9510_;
v___y_9504_ = v___x_9514_;
goto v___jp_9499_;
}
}
v___jp_9515_:
{
uint32_t v___x_9517_; uint8_t v___x_9518_;
v___x_9517_ = 0;
v___x_9518_ = lean_uint32_dec_eq(v___y_9516_, v___x_9517_);
if (v___x_9518_ == 0)
{
uint64_t v___x_9519_; uint8_t v___x_9520_;
v___x_9519_ = 0ULL;
v___x_9520_ = lean_uint64_dec_eq(v_maxCooldownSecs_9458_, v___x_9519_);
if (v___x_9520_ == 0)
{
v___y_9507_ = v___x_9519_;
v___y_9508_ = v___y_9516_;
v___y_9509_ = v___x_9517_;
v___y_9510_ = v_maxCooldownSecs_9458_;
goto v___jp_9506_;
}
else
{
uint64_t v___x_9521_;
v___x_9521_ = 3600ULL;
v___y_9507_ = v___x_9519_;
v___y_9508_ = v___y_9516_;
v___y_9509_ = v___x_9517_;
v___y_9510_ = v___x_9521_;
goto v___jp_9506_;
}
}
else
{
uint64_t v___x_9522_;
v___x_9522_ = 0ULL;
return v___x_9522_;
}
}
v___jp_9523_:
{
uint32_t v___x_9524_;
v___x_9524_ = 3;
v___y_9516_ = v___x_9524_;
goto v___jp_9515_;
}
v___jp_9525_:
{
uint32_t v___x_9526_;
v___x_9526_ = 4;
v___y_9516_ = v___x_9526_;
goto v___jp_9515_;
}
v___jp_9527_:
{
uint32_t v___x_9528_;
v___x_9528_ = 0;
v___y_9516_ = v___x_9528_;
goto v___jp_9515_;
}
v___jp_9529_:
{
uint32_t v___x_9530_; uint8_t v___x_9531_;
v___x_9530_ = 529;
v___x_9531_ = lean_uint32_dec_eq(v_httpStatus_9454_, v___x_9530_);
if (v___x_9531_ == 0)
{
uint32_t v___x_9532_; uint8_t v___x_9533_;
v___x_9532_ = 503;
v___x_9533_ = lean_uint32_dec_eq(v_httpStatus_9454_, v___x_9532_);
if (v___x_9533_ == 0)
{
uint32_t v___x_9534_; uint8_t v___x_9535_;
v___x_9534_ = 500;
v___x_9535_ = lean_uint32_dec_le(v___x_9534_, v_httpStatus_9454_);
if (v___x_9535_ == 0)
{
goto v___jp_9527_;
}
else
{
uint32_t v___x_9536_; uint8_t v___x_9537_;
v___x_9536_ = 600;
v___x_9537_ = lean_uint32_dec_lt(v_httpStatus_9454_, v___x_9536_);
if (v___x_9537_ == 0)
{
goto v___jp_9527_;
}
else
{
uint32_t v___x_9538_;
v___x_9538_ = 5;
v___y_9516_ = v___x_9538_;
goto v___jp_9515_;
}
}
}
else
{
goto v___jp_9525_;
}
}
else
{
goto v___jp_9525_;
}
}
}
}

LEAN_EXPORT uint8_t orb_fleet_place_argmin_step(uint8_t v_aQueued_9566_, uint8_t v_aSpec_9567_, uint8_t v_aSoftDisk_9568_, uint8_t v_bQueued_9569_, uint8_t v_bSpec_9570_, uint8_t v_bSoftDisk_9571_, uint8_t v_idLexLt_9572_, uint32_t v_aLoad_9573_, uint32_t v_aCap_9574_, uint32_t v_aDiskGib_9575_, uint32_t v_bLoad_9576_, uint32_t v_bCap_9577_, uint32_t v_bDiskGib_9578_, uint64_t v_aMemAvail_9579_, uint64_t v_bMemAvail_9580_){
_start:
{
uint8_t v___x_9581_; uint8_t v___y_9583_; uint8_t v___y_9584_; uint8_t v___y_9597_; uint64_t v___y_9601_; uint64_t v___y_9602_; uint32_t v___y_9613_; uint64_t v___y_9614_; uint8_t v___y_9619_; uint8_t v___y_9620_; uint8_t v___y_9629_; uint8_t v___y_9633_; uint8_t v___y_9634_; uint8_t v___y_9641_; uint8_t v___x_9644_;
v___x_9581_ = 0;
v___x_9644_ = lean_uint8_dec_eq(v_aQueued_9566_, v___x_9581_);
if (v___x_9644_ == 0)
{
uint8_t v___x_9645_;
v___x_9645_ = 1;
v___y_9641_ = v___x_9645_;
goto v___jp_9640_;
}
else
{
v___y_9641_ = v___x_9581_;
goto v___jp_9640_;
}
v___jp_9582_:
{
uint8_t v___x_9585_;
v___x_9585_ = lean_uint8_dec_lt(v___y_9583_, v___y_9584_);
if (v___x_9585_ == 0)
{
uint8_t v___x_9586_;
v___x_9586_ = lean_uint8_dec_lt(v___y_9584_, v___y_9583_);
if (v___x_9586_ == 0)
{
uint8_t v___x_9587_;
v___x_9587_ = lean_uint64_dec_lt(v_bMemAvail_9580_, v_aMemAvail_9579_);
if (v___x_9587_ == 0)
{
uint8_t v___x_9588_;
v___x_9588_ = lean_uint64_dec_lt(v_aMemAvail_9579_, v_bMemAvail_9580_);
if (v___x_9588_ == 0)
{
uint8_t v___x_9589_;
v___x_9589_ = lean_uint32_dec_lt(v_bDiskGib_9578_, v_aDiskGib_9575_);
if (v___x_9589_ == 0)
{
uint8_t v___x_9590_;
v___x_9590_ = lean_uint32_dec_lt(v_aDiskGib_9575_, v_bDiskGib_9578_);
if (v___x_9590_ == 0)
{
uint8_t v___x_9591_; uint8_t v___x_9592_;
v___x_9591_ = 1;
v___x_9592_ = lean_uint8_dec_eq(v_idLexLt_9572_, v___x_9591_);
if (v___x_9592_ == 0)
{
return v___x_9581_;
}
else
{
return v___x_9591_;
}
}
else
{
return v___x_9581_;
}
}
else
{
uint8_t v___x_9593_;
v___x_9593_ = 1;
return v___x_9593_;
}
}
else
{
return v___x_9581_;
}
}
else
{
uint8_t v___x_9594_;
v___x_9594_ = 1;
return v___x_9594_;
}
}
else
{
return v___x_9581_;
}
}
else
{
uint8_t v___x_9595_;
v___x_9595_ = 1;
return v___x_9595_;
}
}
v___jp_9596_:
{
uint8_t v___x_9598_;
v___x_9598_ = lean_uint8_dec_eq(v_bSoftDisk_9571_, v___x_9581_);
if (v___x_9598_ == 0)
{
uint8_t v___x_9599_;
v___x_9599_ = 1;
v___y_9583_ = v___y_9597_;
v___y_9584_ = v___x_9599_;
goto v___jp_9582_;
}
else
{
v___y_9583_ = v___y_9597_;
v___y_9584_ = v___x_9581_;
goto v___jp_9582_;
}
}
v___jp_9600_:
{
uint64_t v___x_9603_; uint64_t v_lhs_9604_; uint64_t v___x_9605_; uint64_t v_rhs_9606_; uint8_t v___x_9607_;
v___x_9603_ = lean_uint32_to_uint64(v_aLoad_9573_);
v_lhs_9604_ = lean_uint64_mul(v___x_9603_, v___y_9602_);
v___x_9605_ = lean_uint32_to_uint64(v_bLoad_9576_);
v_rhs_9606_ = lean_uint64_mul(v___x_9605_, v___y_9601_);
v___x_9607_ = lean_uint64_dec_lt(v_lhs_9604_, v_rhs_9606_);
if (v___x_9607_ == 0)
{
uint8_t v___x_9608_;
v___x_9608_ = lean_uint64_dec_lt(v_rhs_9606_, v_lhs_9604_);
if (v___x_9608_ == 0)
{
uint8_t v___x_9609_;
v___x_9609_ = lean_uint8_dec_eq(v_aSoftDisk_9568_, v___x_9581_);
if (v___x_9609_ == 0)
{
uint8_t v___x_9610_;
v___x_9610_ = 1;
v___y_9597_ = v___x_9610_;
goto v___jp_9596_;
}
else
{
v___y_9597_ = v___x_9581_;
goto v___jp_9596_;
}
}
else
{
return v___x_9581_;
}
}
else
{
uint8_t v___x_9611_;
v___x_9611_ = 1;
return v___x_9611_;
}
}
v___jp_9612_:
{
uint8_t v___x_9615_;
v___x_9615_ = lean_uint32_dec_eq(v_bCap_9577_, v___y_9613_);
if (v___x_9615_ == 0)
{
uint64_t v___x_9616_;
v___x_9616_ = lean_uint32_to_uint64(v_bCap_9577_);
v___y_9601_ = v___y_9614_;
v___y_9602_ = v___x_9616_;
goto v___jp_9600_;
}
else
{
uint64_t v___x_9617_;
v___x_9617_ = 1ULL;
v___y_9601_ = v___y_9614_;
v___y_9602_ = v___x_9617_;
goto v___jp_9600_;
}
}
v___jp_9618_:
{
uint8_t v___x_9621_;
v___x_9621_ = lean_uint8_dec_lt(v___y_9619_, v___y_9620_);
if (v___x_9621_ == 0)
{
uint8_t v___x_9622_;
v___x_9622_ = lean_uint8_dec_lt(v___y_9620_, v___y_9619_);
if (v___x_9622_ == 0)
{
uint32_t v___x_9623_; uint8_t v___x_9624_;
v___x_9623_ = 0;
v___x_9624_ = lean_uint32_dec_eq(v_aCap_9574_, v___x_9623_);
if (v___x_9624_ == 0)
{
uint64_t v___x_9625_;
v___x_9625_ = lean_uint32_to_uint64(v_aCap_9574_);
v___y_9613_ = v___x_9623_;
v___y_9614_ = v___x_9625_;
goto v___jp_9612_;
}
else
{
uint64_t v___x_9626_;
v___x_9626_ = 1ULL;
v___y_9613_ = v___x_9623_;
v___y_9614_ = v___x_9626_;
goto v___jp_9612_;
}
}
else
{
return v___x_9581_;
}
}
else
{
uint8_t v___x_9627_;
v___x_9627_ = 1;
return v___x_9627_;
}
}
v___jp_9628_:
{
uint8_t v___x_9630_;
v___x_9630_ = lean_uint8_dec_eq(v_bSpec_9570_, v___x_9581_);
if (v___x_9630_ == 0)
{
uint8_t v___x_9631_;
v___x_9631_ = 1;
v___y_9619_ = v___y_9629_;
v___y_9620_ = v___x_9631_;
goto v___jp_9618_;
}
else
{
v___y_9619_ = v___y_9629_;
v___y_9620_ = v___x_9581_;
goto v___jp_9618_;
}
}
v___jp_9632_:
{
uint8_t v___x_9635_;
v___x_9635_ = lean_uint8_dec_lt(v___y_9633_, v___y_9634_);
if (v___x_9635_ == 0)
{
uint8_t v___x_9636_;
v___x_9636_ = lean_uint8_dec_lt(v___y_9634_, v___y_9633_);
if (v___x_9636_ == 0)
{
uint8_t v___x_9637_;
v___x_9637_ = lean_uint8_dec_eq(v_aSpec_9567_, v___x_9581_);
if (v___x_9637_ == 0)
{
uint8_t v___x_9638_;
v___x_9638_ = 1;
v___y_9629_ = v___x_9638_;
goto v___jp_9628_;
}
else
{
v___y_9629_ = v___x_9581_;
goto v___jp_9628_;
}
}
else
{
return v___x_9581_;
}
}
else
{
uint8_t v___x_9639_;
v___x_9639_ = 1;
return v___x_9639_;
}
}
v___jp_9640_:
{
uint8_t v___x_9642_;
v___x_9642_ = lean_uint8_dec_eq(v_bQueued_9569_, v___x_9581_);
if (v___x_9642_ == 0)
{
uint8_t v___x_9643_;
v___x_9643_ = 1;
v___y_9633_ = v___y_9641_;
v___y_9634_ = v___x_9643_;
goto v___jp_9632_;
}
else
{
v___y_9633_ = v___y_9641_;
v___y_9634_ = v___x_9581_;
goto v___jp_9632_;
}
}
}
}

LEAN_EXPORT uint64_t orb_pool_pacer_step(uint8_t v_mode_9678_, uint64_t v_prevDebtTokenMs_9679_, uint64_t v_elapsedMs_9680_, uint64_t v_rateTokensPerMin_9681_, uint64_t v_addedTokens_9682_, uint64_t v_maxDelayMs_9683_){
_start:
{
uint64_t v___x_9684_; uint64_t v___y_9686_; uint64_t v___y_9687_; uint64_t v___y_9697_; uint64_t v___y_9698_; uint64_t v___y_9699_; uint64_t v___y_9700_; uint64_t v___y_9707_; uint64_t v___y_9708_; uint64_t v___y_9709_; uint64_t v___y_9713_; uint64_t v___y_9714_; uint64_t v___y_9715_; uint64_t v___y_9716_; uint64_t v___y_9721_; uint64_t v___y_9722_; uint64_t v___y_9723_; uint64_t v___y_9724_; uint64_t v___y_9727_; uint8_t v___x_9731_;
v___x_9684_ = 0ULL;
v___x_9731_ = lean_uint64_dec_eq(v_rateTokensPerMin_9681_, v___x_9684_);
if (v___x_9731_ == 0)
{
uint64_t v___x_9732_; uint8_t v___x_9733_;
v___x_9732_ = 100000000000ULL;
v___x_9733_ = lean_uint64_dec_le(v_rateTokensPerMin_9681_, v___x_9732_);
if (v___x_9733_ == 0)
{
v___y_9727_ = v___x_9732_;
goto v___jp_9726_;
}
else
{
v___y_9727_ = v_rateTokensPerMin_9681_;
goto v___jp_9726_;
}
}
else
{
return v___x_9684_;
}
v___jp_9685_:
{
uint8_t v___x_9688_; uint8_t v___x_9689_;
v___x_9688_ = 0;
v___x_9689_ = lean_uint8_dec_eq(v_mode_9678_, v___x_9688_);
if (v___x_9689_ == 0)
{
uint8_t v___x_9690_;
v___x_9690_ = lean_uint64_dec_eq(v___y_9687_, v___x_9684_);
if (v___x_9690_ == 0)
{
uint64_t v___x_9691_; uint64_t v___x_9692_; uint64_t v___x_9693_; uint64_t v_rawDelayMs_9694_; uint8_t v___x_9695_;
v___x_9691_ = 1ULL;
v___x_9692_ = lean_uint64_sub(v___y_9686_, v___x_9691_);
v___x_9693_ = lean_uint64_add(v___y_9687_, v___x_9692_);
v_rawDelayMs_9694_ = lean_uint64_div(v___x_9693_, v___y_9686_);
v___x_9695_ = lean_uint64_dec_le(v_rawDelayMs_9694_, v_maxDelayMs_9683_);
if (v___x_9695_ == 0)
{
return v_maxDelayMs_9683_;
}
else
{
return v_rawDelayMs_9694_;
}
}
else
{
return v___x_9684_;
}
}
else
{
return v___y_9687_;
}
}
v___jp_9696_:
{
uint64_t v___x_9701_; uint64_t v_addUnits_9702_; uint64_t v_room_9703_; uint8_t v___x_9704_;
v___x_9701_ = 60000ULL;
v_addUnits_9702_ = lean_uint64_mul(v___y_9700_, v___x_9701_);
v_room_9703_ = lean_uint64_sub(v___y_9697_, v___y_9699_);
v___x_9704_ = lean_uint64_dec_le(v_addUnits_9702_, v_room_9703_);
if (v___x_9704_ == 0)
{
v___y_9686_ = v___y_9698_;
v___y_9687_ = v___y_9697_;
goto v___jp_9685_;
}
else
{
uint64_t v___x_9705_;
v___x_9705_ = lean_uint64_add(v___y_9699_, v_addUnits_9702_);
v___y_9686_ = v___y_9698_;
v___y_9687_ = v___x_9705_;
goto v___jp_9685_;
}
}
v___jp_9706_:
{
uint64_t v___x_9710_; uint8_t v___x_9711_;
v___x_9710_ = 200000000000ULL;
v___x_9711_ = lean_uint64_dec_le(v_addedTokens_9682_, v___x_9710_);
if (v___x_9711_ == 0)
{
v___y_9697_ = v___y_9707_;
v___y_9698_ = v___y_9708_;
v___y_9699_ = v___y_9709_;
v___y_9700_ = v___x_9710_;
goto v___jp_9696_;
}
else
{
v___y_9697_ = v___y_9707_;
v___y_9698_ = v___y_9708_;
v___y_9699_ = v___y_9709_;
v___y_9700_ = v_addedTokens_9682_;
goto v___jp_9696_;
}
}
v___jp_9712_:
{
uint64_t v_drained_9717_; uint8_t v___x_9718_;
v_drained_9717_ = lean_uint64_mul(v___y_9716_, v___y_9714_);
v___x_9718_ = lean_uint64_dec_le(v_drained_9717_, v___y_9715_);
if (v___x_9718_ == 0)
{
v___y_9707_ = v___y_9713_;
v___y_9708_ = v___y_9714_;
v___y_9709_ = v___x_9684_;
goto v___jp_9706_;
}
else
{
uint64_t v___x_9719_;
v___x_9719_ = lean_uint64_sub(v___y_9715_, v_drained_9717_);
v___y_9707_ = v___y_9713_;
v___y_9708_ = v___y_9714_;
v___y_9709_ = v___x_9719_;
goto v___jp_9706_;
}
}
v___jp_9720_:
{
uint8_t v___x_9725_;
v___x_9725_ = lean_uint64_dec_le(v_elapsedMs_9680_, v___y_9722_);
if (v___x_9725_ == 0)
{
v___y_9713_ = v___y_9721_;
v___y_9714_ = v___y_9723_;
v___y_9715_ = v___y_9724_;
v___y_9716_ = v___y_9722_;
goto v___jp_9712_;
}
else
{
v___y_9713_ = v___y_9721_;
v___y_9714_ = v___y_9723_;
v___y_9715_ = v___y_9724_;
v___y_9716_ = v_elapsedMs_9680_;
goto v___jp_9712_;
}
}
v___jp_9726_:
{
uint64_t v___x_9728_; uint64_t v_maxDebt_9729_; uint8_t v___x_9730_;
v___x_9728_ = 120000ULL;
v_maxDebt_9729_ = lean_uint64_mul(v___y_9727_, v___x_9728_);
v___x_9730_ = lean_uint64_dec_le(v_prevDebtTokenMs_9679_, v_maxDebt_9729_);
if (v___x_9730_ == 0)
{
v___y_9721_ = v_maxDebt_9729_;
v___y_9722_ = v___x_9728_;
v___y_9723_ = v___y_9727_;
v___y_9724_ = v_maxDebt_9729_;
goto v___jp_9720_;
}
else
{
v___y_9721_ = v_maxDebt_9729_;
v___y_9722_ = v___x_9728_;
v___y_9723_ = v___y_9727_;
v___y_9724_ = v_prevDebtTokenMs_9679_;
goto v___jp_9720_;
}
}
}
}

LEAN_EXPORT uint32_t orb_confinement_scan_step(uint8_t v_hasNullByte_9748_, uint8_t v_hasDotDotSegment_9749_, uint8_t v_escapesRoot_9750_, uint8_t v_hasUnsafeEnvKey_9751_, uint8_t v_touchesSensitivePath_9752_, uint8_t v_isSymlinkEscape_9753_, uint32_t v_pathLen_9754_, uint32_t v_maxPathLen_9755_){
_start:
{
uint32_t v___x_9756_; uint8_t v___x_9757_;
v___x_9756_ = 0;
v___x_9757_ = lean_uint32_dec_eq(v_maxPathLen_9755_, v___x_9756_);
if (v___x_9757_ == 0)
{
uint8_t v___x_9758_;
v___x_9758_ = lean_uint32_dec_eq(v_pathLen_9754_, v___x_9756_);
if (v___x_9758_ == 0)
{
uint8_t v___x_9759_;
v___x_9759_ = lean_uint32_dec_lt(v_maxPathLen_9755_, v_pathLen_9754_);
if (v___x_9759_ == 0)
{
uint8_t v___x_9760_; uint8_t v___x_9761_;
v___x_9760_ = 0;
v___x_9761_ = lean_uint8_dec_eq(v_hasNullByte_9748_, v___x_9760_);
if (v___x_9761_ == 0)
{
uint32_t v___x_9762_;
v___x_9762_ = 2;
return v___x_9762_;
}
else
{
uint8_t v___x_9763_;
v___x_9763_ = lean_uint8_dec_eq(v_hasDotDotSegment_9749_, v___x_9760_);
if (v___x_9763_ == 0)
{
uint32_t v___x_9764_;
v___x_9764_ = 3;
return v___x_9764_;
}
else
{
uint8_t v___x_9765_;
v___x_9765_ = lean_uint8_dec_eq(v_escapesRoot_9750_, v___x_9760_);
if (v___x_9765_ == 0)
{
uint32_t v___x_9766_;
v___x_9766_ = 4;
return v___x_9766_;
}
else
{
uint8_t v___x_9767_;
v___x_9767_ = lean_uint8_dec_eq(v_isSymlinkEscape_9753_, v___x_9760_);
if (v___x_9767_ == 0)
{
uint32_t v___x_9768_;
v___x_9768_ = 5;
return v___x_9768_;
}
else
{
uint8_t v___x_9769_;
v___x_9769_ = lean_uint8_dec_eq(v_hasUnsafeEnvKey_9751_, v___x_9760_);
if (v___x_9769_ == 0)
{
uint32_t v___x_9770_;
v___x_9770_ = 6;
return v___x_9770_;
}
else
{
uint8_t v___x_9771_;
v___x_9771_ = lean_uint8_dec_eq(v_touchesSensitivePath_9752_, v___x_9760_);
if (v___x_9771_ == 0)
{
uint32_t v___x_9772_;
v___x_9772_ = 7;
return v___x_9772_;
}
else
{
uint32_t v___x_9773_;
v___x_9773_ = 256;
return v___x_9773_;
}
}
}
}
}
}
}
else
{
uint32_t v___x_9774_;
v___x_9774_ = 1;
return v___x_9774_;
}
}
else
{
uint32_t v___x_9775_;
v___x_9775_ = 1;
return v___x_9775_;
}
}
else
{
uint32_t v___x_9776_;
v___x_9776_ = 1;
return v___x_9776_;
}
}
}

LEAN_EXPORT uint32_t orb_job_identity_eq256_step(uint64_t v_a0_9795_, uint64_t v_a1_9796_, uint64_t v_a2_9797_, uint64_t v_a3_9798_, uint64_t v_b0_9799_, uint64_t v_b1_9800_, uint64_t v_b2_9801_, uint64_t v_b3_9802_, uint8_t v_hasActiveMatch_9803_, uint8_t v_hasTerminalReceipt_9804_){
_start:
{
uint64_t v___x_9805_; uint64_t v___x_9806_; uint64_t v___x_9807_; uint64_t v___x_9808_; uint8_t v___x_9809_;
v___x_9805_ = lean_uint64_lor(v_a0_9795_, v_a1_9796_);
v___x_9806_ = lean_uint64_lor(v___x_9805_, v_a2_9797_);
v___x_9807_ = lean_uint64_lor(v___x_9806_, v_a3_9798_);
v___x_9808_ = 0ULL;
v___x_9809_ = lean_uint64_dec_eq(v___x_9807_, v___x_9808_);
if (v___x_9809_ == 0)
{
uint64_t v___x_9810_; uint64_t v___x_9811_; uint64_t v___x_9812_; uint64_t v___x_9813_; uint64_t v___x_9814_; uint64_t v___x_9815_; uint64_t v_diff_9816_; uint8_t v___x_9817_;
v___x_9810_ = lean_uint64_xor(v_a0_9795_, v_b0_9799_);
v___x_9811_ = lean_uint64_xor(v_a1_9796_, v_b1_9800_);
v___x_9812_ = lean_uint64_lor(v___x_9810_, v___x_9811_);
v___x_9813_ = lean_uint64_xor(v_a2_9797_, v_b2_9801_);
v___x_9814_ = lean_uint64_lor(v___x_9812_, v___x_9813_);
v___x_9815_ = lean_uint64_xor(v_a3_9798_, v_b3_9802_);
v_diff_9816_ = lean_uint64_lor(v___x_9814_, v___x_9815_);
v___x_9817_ = lean_uint64_dec_eq(v_diff_9816_, v___x_9808_);
if (v___x_9817_ == 0)
{
goto v___jp_9818_;
}
else
{
uint8_t v___x_9824_; uint8_t v___x_9825_;
v___x_9824_ = 1;
v___x_9825_ = lean_uint8_dec_eq(v_hasTerminalReceipt_9804_, v___x_9824_);
if (v___x_9825_ == 0)
{
goto v___jp_9818_;
}
else
{
uint32_t v___x_9826_;
v___x_9826_ = 2;
return v___x_9826_;
}
}
v___jp_9818_:
{
if (v___x_9817_ == 0)
{
uint32_t v___x_9819_;
v___x_9819_ = 256;
return v___x_9819_;
}
else
{
uint8_t v___x_9820_; uint8_t v___x_9821_;
v___x_9820_ = 1;
v___x_9821_ = lean_uint8_dec_eq(v_hasActiveMatch_9803_, v___x_9820_);
if (v___x_9821_ == 0)
{
uint32_t v___x_9822_;
v___x_9822_ = 256;
return v___x_9822_;
}
else
{
uint32_t v___x_9823_;
v___x_9823_ = 1;
return v___x_9823_;
}
}
}
}
else
{
uint32_t v___x_9827_;
v___x_9827_ = 3;
return v___x_9827_;
}
}
}

LEAN_EXPORT uint32_t orb_validation_dag_step(uint32_t v_totalDeps_9850_, uint32_t v_passedDeps_9851_, uint32_t v_failedDeps_9852_, uint8_t v_alreadyClaimed_9853_, uint8_t v_alreadyPassed_9854_, uint8_t v_candidateExactMatch_9855_){
_start:
{
uint64_t v___x_9856_; uint64_t v___x_9857_; uint64_t v___x_9858_; uint64_t v___x_9859_; uint8_t v___x_9860_;
v___x_9856_ = lean_uint32_to_uint64(v_totalDeps_9850_);
v___x_9857_ = lean_uint32_to_uint64(v_passedDeps_9851_);
v___x_9858_ = lean_uint32_to_uint64(v_failedDeps_9852_);
v___x_9859_ = lean_uint64_add(v___x_9857_, v___x_9858_);
v___x_9860_ = lean_uint64_dec_lt(v___x_9856_, v___x_9859_);
if (v___x_9860_ == 0)
{
uint8_t v___x_9861_; uint8_t v___x_9862_;
v___x_9861_ = 1;
v___x_9862_ = lean_uint8_dec_eq(v_candidateExactMatch_9855_, v___x_9861_);
if (v___x_9862_ == 0)
{
uint32_t v___x_9863_;
v___x_9863_ = 4;
return v___x_9863_;
}
else
{
uint8_t v___x_9864_; uint8_t v___x_9865_;
v___x_9864_ = 0;
v___x_9865_ = lean_uint8_dec_eq(v_alreadyPassed_9854_, v___x_9864_);
if (v___x_9865_ == 0)
{
uint32_t v___x_9866_;
v___x_9866_ = 3;
return v___x_9866_;
}
else
{
uint32_t v___x_9867_; uint8_t v___x_9868_;
v___x_9867_ = 0;
v___x_9868_ = lean_uint32_dec_lt(v___x_9867_, v_failedDeps_9852_);
if (v___x_9868_ == 0)
{
uint8_t v___x_9869_;
v___x_9869_ = lean_uint8_dec_eq(v_alreadyClaimed_9853_, v___x_9864_);
if (v___x_9869_ == 0)
{
uint32_t v___x_9870_;
v___x_9870_ = 1;
return v___x_9870_;
}
else
{
uint8_t v___x_9871_;
v___x_9871_ = lean_uint32_dec_lt(v_passedDeps_9851_, v_totalDeps_9850_);
if (v___x_9871_ == 0)
{
uint32_t v___x_9872_;
v___x_9872_ = 257;
return v___x_9872_;
}
else
{
uint32_t v___x_9873_;
v___x_9873_ = 1;
return v___x_9873_;
}
}
}
else
{
uint32_t v___x_9874_;
v___x_9874_ = 2;
return v___x_9874_;
}
}
}
}
else
{
uint32_t v___x_9875_;
v___x_9875_ = 0;
return v___x_9875_;
}
}
}

LEAN_EXPORT uint64_t orb_fts5_lexer_step(uint32_t v_state_9890_, uint32_t v_charClass_9891_, uint32_t v_tokenLen_9892_, uint32_t v_maxTokens_9893_, uint32_t v_emittedTokens_9894_){
_start:
{
uint32_t v___y_9896_; uint32_t v___y_9897_; uint32_t v___y_9920_; uint32_t v___y_9921_; uint32_t v___y_9922_; uint32_t v___x_9931_; uint8_t v___x_9932_;
v___x_9931_ = 0;
v___x_9932_ = lean_uint32_dec_eq(v_maxTokens_9893_, v___x_9931_);
if (v___x_9932_ == 0)
{
uint8_t v___x_9933_;
v___x_9933_ = lean_uint32_dec_le(v_maxTokens_9893_, v_emittedTokens_9894_);
if (v___x_9933_ == 0)
{
uint32_t v___x_9934_; uint32_t v___y_9936_; uint32_t v___y_9937_; uint32_t v___y_9942_; uint8_t v___y_9943_; uint8_t v___x_9944_;
v___x_9934_ = 2;
v___x_9944_ = lean_uint32_dec_lt(v___x_9934_, v_state_9890_);
if (v___x_9944_ == 0)
{
uint32_t v___x_9945_; uint8_t v___x_9946_;
v___x_9945_ = 3;
v___x_9946_ = lean_uint32_dec_lt(v___x_9945_, v_charClass_9891_);
if (v___x_9946_ == 0)
{
uint8_t v___x_9947_;
v___x_9947_ = lean_uint32_dec_eq(v_state_9890_, v___x_9931_);
if (v___x_9947_ == 0)
{
uint32_t v___x_9948_; uint8_t v___x_9949_;
v___x_9948_ = 1;
v___x_9949_ = lean_uint32_dec_eq(v_state_9890_, v___x_9948_);
if (v___x_9949_ == 0)
{
uint8_t v___x_9950_;
v___x_9950_ = lean_uint32_dec_eq(v_charClass_9891_, v___x_9934_);
if (v___x_9950_ == 0)
{
uint8_t v___x_9951_;
v___x_9951_ = lean_uint32_dec_eq(v_charClass_9891_, v___x_9948_);
if (v___x_9951_ == 0)
{
uint8_t v___x_9952_;
v___x_9952_ = lean_uint32_dec_lt(v___x_9931_, v_tokenLen_9892_);
if (v___x_9952_ == 0)
{
goto v___jp_9903_;
}
else
{
uint8_t v___x_9953_;
v___x_9953_ = lean_uint32_dec_eq(v_charClass_9891_, v___x_9931_);
if (v___x_9953_ == 0)
{
goto v___jp_9903_;
}
else
{
goto v___jp_9909_;
}
}
}
else
{
goto v___jp_9909_;
}
}
else
{
uint8_t v___x_9954_; uint32_t v___y_9956_;
v___x_9954_ = lean_uint32_dec_lt(v___x_9931_, v_tokenLen_9892_);
if (v___x_9954_ == 0)
{
v___y_9956_ = v_emittedTokens_9894_;
goto v___jp_9955_;
}
else
{
uint32_t v___x_9959_;
v___x_9959_ = lean_uint32_add(v_emittedTokens_9894_, v___x_9948_);
v___y_9956_ = v___x_9959_;
goto v___jp_9955_;
}
v___jp_9955_:
{
if (v___x_9954_ == 0)
{
uint32_t v___x_9957_;
v___x_9957_ = 256;
v___y_9896_ = v___y_9956_;
v___y_9897_ = v___x_9957_;
goto v___jp_9895_;
}
else
{
uint32_t v___x_9958_;
v___x_9958_ = 261;
v___y_9896_ = v___y_9956_;
v___y_9897_ = v___x_9958_;
goto v___jp_9895_;
}
}
}
}
else
{
uint8_t v___x_9960_;
v___x_9960_ = lean_uint32_dec_eq(v_charClass_9891_, v___x_9948_);
if (v___x_9960_ == 0)
{
uint8_t v___x_9965_;
v___x_9965_ = lean_uint32_dec_eq(v_charClass_9891_, v___x_9945_);
if (v___x_9965_ == 0)
{
goto v___jp_9961_;
}
else
{
uint8_t v___x_9966_;
v___x_9966_ = lean_uint32_dec_le(v___x_9934_, v_tokenLen_9892_);
if (v___x_9966_ == 0)
{
goto v___jp_9961_;
}
else
{
uint32_t v_nextEmit_9967_; uint64_t v___x_9968_; uint64_t v___x_9969_; uint64_t v___x_9970_; uint64_t v___x_9971_; uint64_t v___x_9972_;
v_nextEmit_9967_ = lean_uint32_add(v_emittedTokens_9894_, v___x_9948_);
v___x_9968_ = 259ULL;
v___x_9969_ = lean_uint32_to_uint64(v_nextEmit_9967_);
v___x_9970_ = 32ULL;
v___x_9971_ = lean_uint64_shift_left(v___x_9969_, v___x_9970_);
v___x_9972_ = lean_uint64_lor(v___x_9968_, v___x_9971_);
return v___x_9972_;
}
}
}
else
{
uint64_t v___x_9973_; uint64_t v___x_9974_; uint64_t v___x_9975_; uint64_t v___x_9976_; uint64_t v___x_9977_;
v___x_9973_ = 65793ULL;
v___x_9974_ = lean_uint32_to_uint64(v_emittedTokens_9894_);
v___x_9975_ = 32ULL;
v___x_9976_ = lean_uint64_shift_left(v___x_9974_, v___x_9975_);
v___x_9977_ = lean_uint64_lor(v___x_9973_, v___x_9976_);
return v___x_9977_;
}
v___jp_9961_:
{
uint32_t v_nextEmit_9962_; uint8_t v___x_9963_;
v_nextEmit_9962_ = lean_uint32_add(v_emittedTokens_9894_, v___x_9948_);
v___x_9963_ = lean_uint32_dec_eq(v_charClass_9891_, v___x_9934_);
if (v___x_9963_ == 0)
{
v___y_9942_ = v_nextEmit_9962_;
v___y_9943_ = v___x_9960_;
goto v___jp_9941_;
}
else
{
uint8_t v___x_9964_;
v___x_9964_ = lean_uint32_dec_lt(v_nextEmit_9962_, v_maxTokens_9893_);
v___y_9942_ = v_nextEmit_9962_;
v___y_9943_ = v___x_9964_;
goto v___jp_9941_;
}
}
}
}
else
{
uint32_t v___x_9978_; uint8_t v___x_9979_;
v___x_9978_ = 1;
v___x_9979_ = lean_uint32_dec_eq(v_charClass_9891_, v___x_9978_);
if (v___x_9979_ == 0)
{
uint8_t v___x_9980_;
v___x_9980_ = lean_uint32_dec_eq(v_charClass_9891_, v___x_9934_);
if (v___x_9980_ == 0)
{
uint64_t v___x_9981_; uint64_t v___x_9982_; uint64_t v___x_9983_; uint64_t v___x_9984_; uint64_t v___x_9985_;
v___x_9981_ = 256ULL;
v___x_9982_ = lean_uint32_to_uint64(v_emittedTokens_9894_);
v___x_9983_ = 32ULL;
v___x_9984_ = lean_uint64_shift_left(v___x_9982_, v___x_9983_);
v___x_9985_ = lean_uint64_lor(v___x_9981_, v___x_9984_);
return v___x_9985_;
}
else
{
uint64_t v___x_9986_; uint64_t v___x_9987_; uint64_t v___x_9988_; uint64_t v___x_9989_; uint64_t v___x_9990_;
v___x_9986_ = 131332ULL;
v___x_9987_ = lean_uint32_to_uint64(v_emittedTokens_9894_);
v___x_9988_ = 32ULL;
v___x_9989_ = lean_uint64_shift_left(v___x_9987_, v___x_9988_);
v___x_9990_ = lean_uint64_lor(v___x_9986_, v___x_9989_);
return v___x_9990_;
}
}
else
{
uint64_t v___x_9991_; uint64_t v___x_9992_; uint64_t v___x_9993_; uint64_t v___x_9994_; uint64_t v___x_9995_;
v___x_9991_ = 65793ULL;
v___x_9992_ = lean_uint32_to_uint64(v_emittedTokens_9894_);
v___x_9993_ = 32ULL;
v___x_9994_ = lean_uint64_shift_left(v___x_9992_, v___x_9993_);
v___x_9995_ = lean_uint64_lor(v___x_9991_, v___x_9994_);
return v___x_9995_;
}
}
}
else
{
goto v___jp_9915_;
}
}
else
{
goto v___jp_9915_;
}
v___jp_9935_:
{
uint8_t v___x_9938_;
v___x_9938_ = lean_uint32_dec_eq(v___y_9937_, v___x_9934_);
if (v___x_9938_ == 0)
{
uint32_t v___x_9939_;
v___x_9939_ = 258;
v___y_9920_ = v___y_9937_;
v___y_9921_ = v___y_9936_;
v___y_9922_ = v___x_9939_;
goto v___jp_9919_;
}
else
{
uint32_t v___x_9940_;
v___x_9940_ = 262;
v___y_9920_ = v___y_9937_;
v___y_9921_ = v___y_9936_;
v___y_9922_ = v___x_9940_;
goto v___jp_9919_;
}
}
v___jp_9941_:
{
if (v___y_9943_ == 0)
{
v___y_9936_ = v___y_9942_;
v___y_9937_ = v___x_9931_;
goto v___jp_9935_;
}
else
{
v___y_9936_ = v___y_9942_;
v___y_9937_ = v___x_9934_;
goto v___jp_9935_;
}
}
}
else
{
goto v___jp_9915_;
}
}
else
{
goto v___jp_9915_;
}
v___jp_9895_:
{
uint64_t v___x_9898_; uint64_t v___x_9899_; uint64_t v___x_9900_; uint64_t v___x_9901_; uint64_t v___x_9902_;
v___x_9898_ = lean_uint32_to_uint64(v___y_9897_);
v___x_9899_ = lean_uint32_to_uint64(v___y_9896_);
v___x_9900_ = 32ULL;
v___x_9901_ = lean_uint64_shift_left(v___x_9899_, v___x_9900_);
v___x_9902_ = lean_uint64_lor(v___x_9898_, v___x_9901_);
return v___x_9902_;
}
v___jp_9903_:
{
uint64_t v___x_9904_; uint64_t v___x_9905_; uint64_t v___x_9906_; uint64_t v___x_9907_; uint64_t v___x_9908_;
v___x_9904_ = 131328ULL;
v___x_9905_ = lean_uint32_to_uint64(v_emittedTokens_9894_);
v___x_9906_ = 32ULL;
v___x_9907_ = lean_uint64_shift_left(v___x_9905_, v___x_9906_);
v___x_9908_ = lean_uint64_lor(v___x_9904_, v___x_9907_);
return v___x_9908_;
}
v___jp_9909_:
{
uint64_t v___x_9910_; uint64_t v___x_9911_; uint64_t v___x_9912_; uint64_t v___x_9913_; uint64_t v___x_9914_;
v___x_9910_ = 131329ULL;
v___x_9911_ = lean_uint32_to_uint64(v_emittedTokens_9894_);
v___x_9912_ = 32ULL;
v___x_9913_ = lean_uint64_shift_left(v___x_9911_, v___x_9912_);
v___x_9914_ = lean_uint64_lor(v___x_9910_, v___x_9913_);
return v___x_9914_;
}
v___jp_9915_:
{
uint64_t v___x_9916_; uint64_t v___x_9917_; uint64_t v___x_9918_;
v___x_9916_ = lean_uint32_to_uint64(v_emittedTokens_9894_);
v___x_9917_ = 32ULL;
v___x_9918_ = lean_uint64_shift_left(v___x_9916_, v___x_9917_);
return v___x_9918_;
}
v___jp_9919_:
{
uint32_t v___x_9923_; uint32_t v___x_9924_; uint32_t v___x_9925_; uint64_t v___x_9926_; uint64_t v___x_9927_; uint64_t v___x_9928_; uint64_t v___x_9929_; uint64_t v___x_9930_;
v___x_9923_ = 16;
v___x_9924_ = lean_uint32_shift_left(v___y_9920_, v___x_9923_);
v___x_9925_ = lean_uint32_lor(v___y_9922_, v___x_9924_);
v___x_9926_ = lean_uint32_to_uint64(v___x_9925_);
v___x_9927_ = lean_uint32_to_uint64(v___y_9921_);
v___x_9928_ = 32ULL;
v___x_9929_ = lean_uint64_shift_left(v___x_9927_, v___x_9928_);
v___x_9930_ = lean_uint64_lor(v___x_9926_, v___x_9929_);
return v___x_9930_;
}
}
}

LEAN_EXPORT uint64_t orb_utf8_utf16_window_step(uint32_t v_byteIdx_10008_, uint32_t v_byteLen_10009_, uint32_t v_leadByte_10010_, uint32_t v_utf16Units_10011_, uint32_t v_maxUtf16Units_10012_){
_start:
{
uint32_t v___y_10018_; uint32_t v___y_10019_; uint32_t v___y_10044_; uint32_t v___x_10063_; uint8_t v___x_10064_;
v___x_10063_ = 127;
v___x_10064_ = lean_uint32_dec_le(v_leadByte_10010_, v___x_10063_);
if (v___x_10064_ == 0)
{
uint32_t v___x_10065_; uint8_t v___x_10066_;
v___x_10065_ = 194;
v___x_10066_ = lean_uint32_dec_le(v___x_10065_, v_leadByte_10010_);
if (v___x_10066_ == 0)
{
goto v___jp_10057_;
}
else
{
uint32_t v___x_10067_; uint8_t v___x_10068_;
v___x_10067_ = 223;
v___x_10068_ = lean_uint32_dec_le(v_leadByte_10010_, v___x_10067_);
if (v___x_10068_ == 0)
{
goto v___jp_10057_;
}
else
{
uint32_t v___x_10069_;
v___x_10069_ = 2;
v___y_10044_ = v___x_10069_;
goto v___jp_10043_;
}
}
}
else
{
uint32_t v___x_10070_;
v___x_10070_ = 1;
v___y_10044_ = v___x_10070_;
goto v___jp_10043_;
}
v___jp_10013_:
{
uint64_t v___x_10014_; uint64_t v___x_10015_; uint64_t v___x_10016_;
v___x_10014_ = lean_uint32_to_uint64(v_utf16Units_10011_);
v___x_10015_ = 32ULL;
v___x_10016_ = lean_uint64_shift_left(v___x_10014_, v___x_10015_);
return v___x_10016_;
}
v___jp_10017_:
{
uint32_t v___x_10020_; uint8_t v___x_10021_;
v___x_10020_ = 0;
v___x_10021_ = lean_uint32_dec_eq(v___y_10018_, v___x_10020_);
if (v___x_10021_ == 0)
{
uint64_t v___x_10022_; uint64_t v___x_10023_; uint64_t v___x_10024_; uint64_t v___x_10025_; uint8_t v___x_10026_;
v___x_10022_ = lean_uint32_to_uint64(v_byteLen_10009_);
v___x_10023_ = lean_uint32_to_uint64(v_byteIdx_10008_);
v___x_10024_ = lean_uint32_to_uint64(v___y_10018_);
v___x_10025_ = lean_uint64_add(v___x_10023_, v___x_10024_);
v___x_10026_ = lean_uint64_dec_lt(v___x_10022_, v___x_10025_);
if (v___x_10026_ == 0)
{
uint64_t v___x_10027_; uint64_t v___x_10028_; uint64_t v___x_10029_; uint64_t v___x_10030_; uint8_t v___x_10031_;
v___x_10027_ = lean_uint32_to_uint64(v_maxUtf16Units_10012_);
v___x_10028_ = lean_uint32_to_uint64(v_utf16Units_10011_);
v___x_10029_ = lean_uint32_to_uint64(v___y_10019_);
v___x_10030_ = lean_uint64_add(v___x_10028_, v___x_10029_);
v___x_10031_ = lean_uint64_dec_lt(v___x_10027_, v___x_10030_);
if (v___x_10031_ == 0)
{
uint32_t v_nextU16_10032_; uint32_t v___x_10033_; uint32_t v___x_10034_; uint32_t v___x_10035_; uint32_t v___x_10036_; uint32_t v_lo32_10037_; uint64_t v___x_10038_; uint64_t v___x_10039_; uint64_t v___x_10040_; uint64_t v___x_10041_; uint64_t v___x_10042_;
v_nextU16_10032_ = lean_uint32_add(v_utf16Units_10011_, v___y_10019_);
v___x_10033_ = 256;
v___x_10034_ = lean_uint32_lor(v___y_10018_, v___x_10033_);
v___x_10035_ = 16;
v___x_10036_ = lean_uint32_shift_left(v___y_10019_, v___x_10035_);
v_lo32_10037_ = lean_uint32_lor(v___x_10034_, v___x_10036_);
v___x_10038_ = lean_uint32_to_uint64(v_lo32_10037_);
v___x_10039_ = lean_uint32_to_uint64(v_nextU16_10032_);
v___x_10040_ = 32ULL;
v___x_10041_ = lean_uint64_shift_left(v___x_10039_, v___x_10040_);
v___x_10042_ = lean_uint64_lor(v___x_10038_, v___x_10041_);
return v___x_10042_;
}
else
{
goto v___jp_10013_;
}
}
else
{
goto v___jp_10013_;
}
}
else
{
goto v___jp_10013_;
}
}
v___jp_10043_:
{
uint32_t v___x_10045_; uint8_t v___x_10046_;
v___x_10045_ = 4;
v___x_10046_ = lean_uint32_dec_eq(v___y_10044_, v___x_10045_);
if (v___x_10046_ == 0)
{
uint32_t v___x_10047_;
v___x_10047_ = 1;
v___y_10018_ = v___y_10044_;
v___y_10019_ = v___x_10047_;
goto v___jp_10017_;
}
else
{
uint32_t v___x_10048_;
v___x_10048_ = 2;
v___y_10018_ = v___y_10044_;
v___y_10019_ = v___x_10048_;
goto v___jp_10017_;
}
}
v___jp_10049_:
{
uint32_t v___x_10050_;
v___x_10050_ = 0;
v___y_10044_ = v___x_10050_;
goto v___jp_10043_;
}
v___jp_10051_:
{
uint32_t v___x_10052_; uint8_t v___x_10053_;
v___x_10052_ = 240;
v___x_10053_ = lean_uint32_dec_le(v___x_10052_, v_leadByte_10010_);
if (v___x_10053_ == 0)
{
goto v___jp_10049_;
}
else
{
uint32_t v___x_10054_; uint8_t v___x_10055_;
v___x_10054_ = 244;
v___x_10055_ = lean_uint32_dec_le(v_leadByte_10010_, v___x_10054_);
if (v___x_10055_ == 0)
{
goto v___jp_10049_;
}
else
{
uint32_t v___x_10056_;
v___x_10056_ = 4;
v___y_10044_ = v___x_10056_;
goto v___jp_10043_;
}
}
}
v___jp_10057_:
{
uint32_t v___x_10058_; uint8_t v___x_10059_;
v___x_10058_ = 224;
v___x_10059_ = lean_uint32_dec_le(v___x_10058_, v_leadByte_10010_);
if (v___x_10059_ == 0)
{
goto v___jp_10051_;
}
else
{
uint32_t v___x_10060_; uint8_t v___x_10061_;
v___x_10060_ = 239;
v___x_10061_ = lean_uint32_dec_le(v_leadByte_10010_, v___x_10060_);
if (v___x_10061_ == 0)
{
goto v___jp_10051_;
}
else
{
uint32_t v___x_10062_;
v___x_10062_ = 3;
v___y_10044_ = v___x_10062_;
goto v___jp_10043_;
}
}
}
}
}

LEAN_EXPORT uint8_t orb_model_account_admit(uint32_t v_candId_10083_, uint8_t v_ineligible_10084_, uint8_t v_entitlement_10085_, uint8_t v_requireEntitled_10086_){
_start:
{
uint32_t v___x_10087_; uint8_t v___x_10088_;
v___x_10087_ = 0;
v___x_10088_ = lean_uint32_dec_eq(v_candId_10083_, v___x_10087_);
if (v___x_10088_ == 0)
{
uint8_t v___x_10089_; uint8_t v___x_10090_;
v___x_10089_ = 0;
v___x_10090_ = lean_uint8_dec_eq(v_ineligible_10084_, v___x_10089_);
if (v___x_10090_ == 0)
{
return v___x_10089_;
}
else
{
uint8_t v___x_10091_; uint8_t v___x_10092_;
v___x_10091_ = 2;
v___x_10092_ = lean_uint8_dec_eq(v_entitlement_10085_, v___x_10091_);
if (v___x_10092_ == 0)
{
uint8_t v___x_10093_; uint8_t v___x_10094_;
v___x_10093_ = 1;
v___x_10094_ = lean_uint8_dec_eq(v_entitlement_10085_, v___x_10093_);
if (v___x_10094_ == 0)
{
return v___x_10089_;
}
else
{
uint8_t v___x_10095_;
v___x_10095_ = lean_uint8_dec_eq(v_requireEntitled_10086_, v___x_10089_);
if (v___x_10095_ == 0)
{
return v___x_10089_;
}
else
{
return v___x_10093_;
}
}
}
else
{
uint8_t v___x_10096_;
v___x_10096_ = 1;
return v___x_10096_;
}
}
}
else
{
uint8_t v___x_10097_;
v___x_10097_ = 0;
return v___x_10097_;
}
}
}

LEAN_EXPORT uint64_t orb_model_account_score(uint32_t v_candId_10108_, uint8_t v_ineligible_10109_, uint8_t v_entitlement_10110_, uint8_t v_requireEntitled_10111_, uint8_t v_hasPoolQuota_10112_, uint32_t v_priorityRank_10113_, uint32_t v_usableInSecs_10114_){
_start:
{
uint64_t v___y_10116_; uint64_t v___y_10117_; uint64_t v___y_10118_; uint64_t v___y_10119_; uint64_t v___y_10124_; uint64_t v___y_10125_; uint64_t v___y_10126_; uint64_t v___y_10132_; uint8_t v___y_10133_; uint64_t v___y_10134_; uint64_t v___y_10140_; uint8_t v___y_10146_; uint32_t v___x_10154_; uint8_t v___x_10155_;
v___x_10154_ = 0;
v___x_10155_ = lean_uint32_dec_eq(v_candId_10108_, v___x_10154_);
if (v___x_10155_ == 0)
{
uint8_t v___x_10156_; uint8_t v___x_10157_;
v___x_10156_ = 0;
v___x_10157_ = lean_uint8_dec_eq(v_ineligible_10109_, v___x_10156_);
if (v___x_10157_ == 0)
{
v___y_10146_ = v___x_10156_;
goto v___jp_10145_;
}
else
{
uint8_t v___x_10158_; uint8_t v___x_10159_;
v___x_10158_ = 2;
v___x_10159_ = lean_uint8_dec_eq(v_entitlement_10110_, v___x_10158_);
if (v___x_10159_ == 0)
{
uint8_t v___x_10160_; uint8_t v___x_10161_;
v___x_10160_ = 1;
v___x_10161_ = lean_uint8_dec_eq(v_entitlement_10110_, v___x_10160_);
if (v___x_10161_ == 0)
{
v___y_10146_ = v___x_10156_;
goto v___jp_10145_;
}
else
{
uint8_t v___x_10162_;
v___x_10162_ = lean_uint8_dec_eq(v_requireEntitled_10111_, v___x_10156_);
if (v___x_10162_ == 0)
{
v___y_10146_ = v___x_10156_;
goto v___jp_10145_;
}
else
{
v___y_10146_ = v___x_10160_;
goto v___jp_10145_;
}
}
}
else
{
uint8_t v___x_10163_;
v___x_10163_ = 1;
v___y_10146_ = v___x_10163_;
goto v___jp_10145_;
}
}
}
else
{
uint8_t v___x_10164_;
v___x_10164_ = 0;
v___y_10146_ = v___x_10164_;
goto v___jp_10145_;
}
v___jp_10115_:
{
uint64_t v___x_10120_; uint64_t v___x_10121_; uint64_t v___x_10122_;
v___x_10120_ = lean_uint64_lor(v___y_10116_, v___y_10118_);
v___x_10121_ = lean_uint64_lor(v___x_10120_, v___y_10117_);
v___x_10122_ = lean_uint64_lor(v___x_10121_, v___y_10119_);
return v___x_10122_;
}
v___jp_10123_:
{
uint32_t v___x_10127_; uint8_t v___x_10128_;
v___x_10127_ = 65535;
v___x_10128_ = lean_uint32_dec_le(v_priorityRank_10113_, v___x_10127_);
if (v___x_10128_ == 0)
{
uint64_t v___x_10129_;
v___x_10129_ = 65535ULL;
v___y_10116_ = v___y_10124_;
v___y_10117_ = v___y_10126_;
v___y_10118_ = v___y_10125_;
v___y_10119_ = v___x_10129_;
goto v___jp_10115_;
}
else
{
uint64_t v___x_10130_;
v___x_10130_ = lean_uint32_to_uint64(v_priorityRank_10113_);
v___y_10116_ = v___y_10124_;
v___y_10117_ = v___y_10126_;
v___y_10118_ = v___y_10125_;
v___y_10119_ = v___x_10130_;
goto v___jp_10115_;
}
}
v___jp_10131_:
{
if (v___y_10133_ == 0)
{
uint64_t v___x_10135_; uint64_t v___x_10136_; uint64_t v___x_10137_;
v___x_10135_ = lean_uint32_to_uint64(v_usableInSecs_10114_);
v___x_10136_ = 16ULL;
v___x_10137_ = lean_uint64_shift_left(v___x_10135_, v___x_10136_);
v___y_10124_ = v___y_10132_;
v___y_10125_ = v___y_10134_;
v___y_10126_ = v___x_10137_;
goto v___jp_10123_;
}
else
{
uint64_t v___x_10138_;
v___x_10138_ = 0ULL;
v___y_10124_ = v___y_10132_;
v___y_10125_ = v___y_10134_;
v___y_10126_ = v___x_10138_;
goto v___jp_10123_;
}
}
v___jp_10139_:
{
uint8_t v___x_10141_; uint8_t v___x_10142_;
v___x_10141_ = 1;
v___x_10142_ = lean_uint8_dec_eq(v_hasPoolQuota_10112_, v___x_10141_);
if (v___x_10142_ == 0)
{
uint64_t v___x_10143_;
v___x_10143_ = 562949953421312ULL;
v___y_10132_ = v___y_10140_;
v___y_10133_ = v___x_10142_;
v___y_10134_ = v___x_10143_;
goto v___jp_10131_;
}
else
{
uint64_t v___x_10144_;
v___x_10144_ = 0ULL;
v___y_10132_ = v___y_10140_;
v___y_10133_ = v___x_10142_;
v___y_10134_ = v___x_10144_;
goto v___jp_10131_;
}
}
v___jp_10145_:
{
uint8_t v___x_10147_; uint8_t v___x_10148_;
v___x_10147_ = 0;
v___x_10148_ = lean_uint8_dec_eq(v___y_10146_, v___x_10147_);
if (v___x_10148_ == 0)
{
uint8_t v___x_10149_; uint8_t v___x_10150_;
v___x_10149_ = 2;
v___x_10150_ = lean_uint8_dec_eq(v_entitlement_10110_, v___x_10149_);
if (v___x_10150_ == 0)
{
uint64_t v___x_10151_;
v___x_10151_ = 1125899906842624ULL;
v___y_10140_ = v___x_10151_;
goto v___jp_10139_;
}
else
{
uint64_t v___x_10152_;
v___x_10152_ = 0ULL;
v___y_10140_ = v___x_10152_;
goto v___jp_10139_;
}
}
else
{
uint64_t v___x_10153_;
v___x_10153_ = 18446744073709551615ULL;
return v___x_10153_;
}
}
}
}

LEAN_EXPORT uint64_t orb_epoch_fence_step(uint64_t v_durableOwnerEpoch_10181_, uint64_t v_liveOwnerEpoch_10182_, uint64_t v_durableRunGeneration_10183_, uint64_t v_liveRunGeneration_10184_, uint64_t v_durableBootEpoch_10185_, uint64_t v_liveBootEpoch_10186_, uint32_t v_durableRevision_10187_, uint32_t v_liveRevision_10188_, uint64_t v_writerOwnerEpoch_10189_){
_start:
{
uint32_t v___y_10191_; uint32_t v___y_10192_; uint32_t v___y_10199_; uint8_t v___y_10207_; uint8_t v___x_10225_;
v___x_10225_ = lean_uint64_dec_eq(v_writerOwnerEpoch_10189_, v_durableOwnerEpoch_10181_);
if (v___x_10225_ == 0)
{
v___y_10207_ = v___x_10225_;
goto v___jp_10206_;
}
else
{
uint8_t v___x_10226_;
v___x_10226_ = lean_uint64_dec_eq(v_writerOwnerEpoch_10189_, v_liveOwnerEpoch_10182_);
v___y_10207_ = v___x_10226_;
goto v___jp_10206_;
}
v___jp_10190_:
{
uint64_t v___x_10193_; uint64_t v___x_10194_; uint64_t v___x_10195_; uint64_t v___x_10196_; uint64_t v___x_10197_;
v___x_10193_ = lean_uint32_to_uint64(v___y_10191_);
v___x_10194_ = lean_uint32_to_uint64(v___y_10192_);
v___x_10195_ = 32ULL;
v___x_10196_ = lean_uint64_shift_left(v___x_10194_, v___x_10195_);
v___x_10197_ = lean_uint64_lor(v___x_10193_, v___x_10196_);
return v___x_10197_;
}
v___jp_10198_:
{
uint32_t v___x_10200_; uint8_t v___x_10201_;
v___x_10200_ = 257;
v___x_10201_ = lean_uint32_dec_eq(v___y_10199_, v___x_10200_);
if (v___x_10201_ == 0)
{
v___y_10191_ = v___y_10199_;
v___y_10192_ = v_durableRevision_10187_;
goto v___jp_10190_;
}
else
{
uint32_t v___x_10202_; uint32_t v___x_10203_;
v___x_10202_ = 1;
v___x_10203_ = lean_uint32_add(v_durableRevision_10187_, v___x_10202_);
v___y_10191_ = v___y_10199_;
v___y_10192_ = v___x_10203_;
goto v___jp_10190_;
}
}
v___jp_10204_:
{
uint32_t v___x_10205_;
v___x_10205_ = 0;
v___y_10199_ = v___x_10205_;
goto v___jp_10198_;
}
v___jp_10206_:
{
uint64_t v___x_10208_; uint8_t v___x_10209_;
v___x_10208_ = 0ULL;
v___x_10209_ = lean_uint64_dec_eq(v_durableOwnerEpoch_10181_, v___x_10208_);
if (v___x_10209_ == 0)
{
uint8_t v_runOk_10210_; uint8_t v___x_10211_;
v_runOk_10210_ = lean_uint64_dec_eq(v_liveRunGeneration_10184_, v_durableRunGeneration_10183_);
v___x_10211_ = lean_uint64_dec_eq(v_durableRunGeneration_10183_, v___x_10208_);
if (v___x_10211_ == 0)
{
uint8_t v_bootOk_10212_; uint8_t v___x_10213_;
v_bootOk_10212_ = lean_uint64_dec_eq(v_liveBootEpoch_10186_, v_durableBootEpoch_10185_);
v___x_10213_ = lean_uint64_dec_eq(v_durableBootEpoch_10185_, v___x_10208_);
if (v___x_10213_ == 0)
{
uint8_t v_revMatch_10214_; uint32_t v___x_10215_; uint8_t v_revRoom_10216_; uint32_t v___x_10217_; uint8_t v___x_10218_;
v_revMatch_10214_ = lean_uint32_dec_eq(v_liveRevision_10188_, v_durableRevision_10187_);
v___x_10215_ = 4294967295;
v_revRoom_10216_ = lean_uint32_dec_lt(v_durableRevision_10187_, v___x_10215_);
v___x_10217_ = 0;
v___x_10218_ = lean_uint32_dec_eq(v_durableRevision_10187_, v___x_10217_);
if (v___x_10218_ == 0)
{
if (v___y_10207_ == 0)
{
uint32_t v___x_10219_;
v___x_10219_ = 5;
v___y_10199_ = v___x_10219_;
goto v___jp_10198_;
}
else
{
if (v_revMatch_10214_ == 0)
{
uint32_t v___x_10220_;
v___x_10220_ = 2;
v___y_10199_ = v___x_10220_;
goto v___jp_10198_;
}
else
{
if (v_runOk_10210_ == 0)
{
uint32_t v___x_10221_;
v___x_10221_ = 3;
v___y_10199_ = v___x_10221_;
goto v___jp_10198_;
}
else
{
if (v_bootOk_10212_ == 0)
{
uint32_t v___x_10222_;
v___x_10222_ = 4;
v___y_10199_ = v___x_10222_;
goto v___jp_10198_;
}
else
{
if (v_revRoom_10216_ == 0)
{
uint32_t v___x_10223_;
v___x_10223_ = 6;
v___y_10199_ = v___x_10223_;
goto v___jp_10198_;
}
else
{
uint32_t v___x_10224_;
v___x_10224_ = 257;
v___y_10199_ = v___x_10224_;
goto v___jp_10198_;
}
}
}
}
}
}
else
{
goto v___jp_10204_;
}
}
else
{
goto v___jp_10204_;
}
}
else
{
goto v___jp_10204_;
}
}
else
{
goto v___jp_10204_;
}
}
}
}

LEAN_EXPORT uint64_t orb_effect_outbox_step(uint8_t v_phase_10247_, uint8_t v_delivered_10248_, uint8_t v_op_10249_, uint8_t v_fenceMatches_10250_, uint64_t v_attemptEpoch_10251_, uint64_t v_nodeBootEpoch_10252_){
_start:
{
uint8_t v___y_10254_; uint32_t v___y_10255_; uint8_t v___y_10263_; uint8_t v___y_10266_; uint8_t v___y_10267_; uint8_t v___y_10268_; uint8_t v___y_10269_; uint8_t v___y_10270_; uint8_t v___y_10271_; uint8_t v___y_10272_; uint8_t v___y_10282_; uint8_t v___y_10283_; uint8_t v___y_10284_; uint8_t v___y_10285_; uint8_t v___y_10286_; uint8_t v___y_10287_; uint8_t v___x_10290_; uint8_t v___y_10292_; uint8_t v___y_10293_; uint8_t v___y_10294_; uint8_t v___y_10295_; uint8_t v___y_10296_; uint8_t v___y_10297_; uint8_t v___y_10302_; uint8_t v___y_10303_; uint8_t v___y_10304_; uint8_t v___y_10305_; uint8_t v___y_10316_; uint8_t v___x_10340_;
v___x_10290_ = 1;
v___x_10340_ = lean_uint8_dec_eq(v_fenceMatches_10250_, v___x_10290_);
if (v___x_10340_ == 0)
{
v___y_10316_ = v___x_10340_;
goto v___jp_10315_;
}
else
{
uint8_t v___x_10341_;
v___x_10341_ = lean_uint64_dec_eq(v_attemptEpoch_10251_, v_nodeBootEpoch_10252_);
if (v___x_10341_ == 0)
{
v___y_10316_ = v___x_10341_;
goto v___jp_10315_;
}
else
{
uint64_t v___x_10342_; uint8_t v___x_10343_;
v___x_10342_ = 0ULL;
v___x_10343_ = lean_uint64_dec_eq(v_attemptEpoch_10251_, v___x_10342_);
if (v___x_10343_ == 0)
{
v___y_10316_ = v___x_10341_;
goto v___jp_10315_;
}
else
{
uint8_t v___x_10344_;
v___x_10344_ = 0;
v___y_10316_ = v___x_10344_;
goto v___jp_10315_;
}
}
}
v___jp_10253_:
{
uint64_t v___x_10256_; uint32_t v___x_10257_; uint64_t v___x_10258_; uint64_t v___x_10259_; uint64_t v___x_10260_; uint64_t v___x_10261_;
v___x_10256_ = lean_uint32_to_uint64(v___y_10255_);
v___x_10257_ = lean_uint8_to_uint32(v___y_10254_);
v___x_10258_ = lean_uint32_to_uint64(v___x_10257_);
v___x_10259_ = 32ULL;
v___x_10260_ = lean_uint64_shift_left(v___x_10258_, v___x_10259_);
v___x_10261_ = lean_uint64_lor(v___x_10256_, v___x_10260_);
return v___x_10261_;
}
v___jp_10262_:
{
uint32_t v___x_10264_;
v___x_10264_ = 0;
v___y_10254_ = v___y_10263_;
v___y_10255_ = v___x_10264_;
goto v___jp_10253_;
}
v___jp_10265_:
{
if (v___y_10268_ == 0)
{
if (v___y_10267_ == 0)
{
v___y_10263_ = v___y_10270_;
goto v___jp_10262_;
}
else
{
if (v___y_10271_ == 0)
{
v___y_10263_ = v___y_10270_;
goto v___jp_10262_;
}
else
{
if (v___y_10272_ == 0)
{
if (v___y_10269_ == 0)
{
uint32_t v___x_10273_;
v___x_10273_ = 2;
v___y_10254_ = v___y_10270_;
v___y_10255_ = v___x_10273_;
goto v___jp_10253_;
}
else
{
uint32_t v___x_10274_; uint32_t v___x_10275_; uint32_t v___x_10276_; uint32_t v___x_10277_; uint32_t v___x_10278_;
v___x_10274_ = 257;
v___x_10275_ = lean_uint8_to_uint32(v___y_10266_);
v___x_10276_ = 16;
v___x_10277_ = lean_uint32_shift_left(v___x_10275_, v___x_10276_);
v___x_10278_ = lean_uint32_lor(v___x_10274_, v___x_10277_);
v___y_10254_ = v___y_10270_;
v___y_10255_ = v___x_10278_;
goto v___jp_10253_;
}
}
else
{
uint32_t v___x_10279_;
v___x_10279_ = 3;
v___y_10254_ = v___y_10270_;
v___y_10255_ = v___x_10279_;
goto v___jp_10253_;
}
}
}
}
else
{
uint32_t v___x_10280_;
v___x_10280_ = 4;
v___y_10254_ = v___y_10270_;
v___y_10255_ = v___x_10280_;
goto v___jp_10253_;
}
}
v___jp_10281_:
{
uint8_t v___x_10288_; uint8_t v___x_10289_;
v___x_10288_ = 4;
v___x_10289_ = lean_uint8_dec_eq(v_phase_10247_, v___x_10288_);
v___y_10266_ = v___y_10282_;
v___y_10267_ = v___y_10283_;
v___y_10268_ = v___y_10284_;
v___y_10269_ = v___y_10286_;
v___y_10270_ = v___y_10285_;
v___y_10271_ = v___y_10287_;
v___y_10272_ = v___x_10289_;
goto v___jp_10265_;
}
v___jp_10291_:
{
uint8_t v___x_10298_;
v___x_10298_ = lean_uint8_dec_eq(v_op_10249_, v___x_10290_);
if (v___x_10298_ == 0)
{
uint8_t v___x_10299_; uint8_t v___x_10300_;
v___x_10299_ = 2;
v___x_10300_ = lean_uint8_dec_eq(v_op_10249_, v___x_10299_);
if (v___x_10300_ == 0)
{
v___y_10266_ = v___y_10292_;
v___y_10267_ = v___y_10293_;
v___y_10268_ = v___y_10294_;
v___y_10269_ = v___y_10295_;
v___y_10270_ = v___y_10297_;
v___y_10271_ = v___y_10296_;
v___y_10272_ = v___x_10300_;
goto v___jp_10265_;
}
else
{
v___y_10282_ = v___y_10292_;
v___y_10283_ = v___y_10293_;
v___y_10284_ = v___y_10294_;
v___y_10285_ = v___y_10297_;
v___y_10286_ = v___y_10295_;
v___y_10287_ = v___y_10296_;
goto v___jp_10281_;
}
}
else
{
v___y_10282_ = v___y_10292_;
v___y_10283_ = v___y_10293_;
v___y_10284_ = v___y_10294_;
v___y_10285_ = v___y_10297_;
v___y_10286_ = v___y_10295_;
v___y_10287_ = v___y_10296_;
goto v___jp_10281_;
}
}
v___jp_10301_:
{
uint8_t v___x_10306_;
v___x_10306_ = lean_uint8_dec_eq(v___y_10305_, v_phase_10247_);
if (v___x_10306_ == 0)
{
uint8_t v___x_10307_; uint8_t v___x_10308_; uint8_t v___x_10309_;
v___x_10307_ = 1;
v___x_10308_ = 2;
v___x_10309_ = lean_uint8_dec_eq(v___y_10305_, v___x_10308_);
if (v___x_10309_ == 0)
{
uint8_t v___x_10310_; uint8_t v___x_10311_;
v___x_10310_ = 0;
v___x_10311_ = lean_uint8_dec_eq(v___y_10305_, v___x_10310_);
if (v___x_10311_ == 0)
{
uint8_t v___x_10312_; uint8_t v___x_10313_;
v___x_10312_ = 3;
v___x_10313_ = lean_uint8_dec_eq(v___y_10305_, v___x_10312_);
if (v___x_10313_ == 0)
{
v___y_10292_ = v___y_10305_;
v___y_10293_ = v___y_10302_;
v___y_10294_ = v___y_10303_;
v___y_10295_ = v___x_10307_;
v___y_10296_ = v___y_10304_;
v___y_10297_ = v_delivered_10248_;
goto v___jp_10291_;
}
else
{
v___y_10292_ = v___y_10305_;
v___y_10293_ = v___y_10302_;
v___y_10294_ = v___y_10303_;
v___y_10295_ = v___x_10307_;
v___y_10296_ = v___y_10304_;
v___y_10297_ = v___x_10310_;
goto v___jp_10291_;
}
}
else
{
v___y_10292_ = v___y_10305_;
v___y_10293_ = v___y_10302_;
v___y_10294_ = v___y_10303_;
v___y_10295_ = v___x_10307_;
v___y_10296_ = v___y_10304_;
v___y_10297_ = v___x_10310_;
goto v___jp_10291_;
}
}
else
{
v___y_10292_ = v___y_10305_;
v___y_10293_ = v___y_10302_;
v___y_10294_ = v___y_10303_;
v___y_10295_ = v___x_10307_;
v___y_10296_ = v___y_10304_;
v___y_10297_ = v___x_10290_;
goto v___jp_10291_;
}
}
else
{
uint8_t v___x_10314_;
v___x_10314_ = 0;
v___y_10292_ = v___y_10305_;
v___y_10293_ = v___y_10302_;
v___y_10294_ = v___y_10303_;
v___y_10295_ = v___x_10314_;
v___y_10296_ = v___y_10304_;
v___y_10297_ = v_delivered_10248_;
goto v___jp_10291_;
}
}
v___jp_10315_:
{
uint8_t v___x_10317_; uint8_t v_phaseOk_10318_; uint8_t v_opOk_10319_;
v___x_10317_ = 5;
v_phaseOk_10318_ = lean_uint8_dec_le(v_phase_10247_, v___x_10317_);
v_opOk_10319_ = lean_uint8_dec_le(v_op_10249_, v___x_10317_);
if (v___y_10316_ == 0)
{
uint8_t v___x_10320_;
v___x_10320_ = 1;
v___y_10302_ = v_phaseOk_10318_;
v___y_10303_ = v___x_10320_;
v___y_10304_ = v_opOk_10319_;
v___y_10305_ = v_phase_10247_;
goto v___jp_10301_;
}
else
{
uint8_t v___x_10321_;
v___x_10321_ = 0;
if (v_phaseOk_10318_ == 0)
{
v___y_10302_ = v_phaseOk_10318_;
v___y_10303_ = v___x_10321_;
v___y_10304_ = v_opOk_10319_;
v___y_10305_ = v_phase_10247_;
goto v___jp_10301_;
}
else
{
if (v_opOk_10319_ == 0)
{
v___y_10302_ = v_phaseOk_10318_;
v___y_10303_ = v___x_10321_;
v___y_10304_ = v_opOk_10319_;
v___y_10305_ = v_phase_10247_;
goto v___jp_10301_;
}
else
{
uint8_t v___x_10322_; uint8_t v___x_10323_;
v___x_10322_ = 0;
v___x_10323_ = lean_uint8_dec_eq(v_op_10249_, v___x_10322_);
if (v___x_10323_ == 0)
{
uint8_t v___x_10324_;
v___x_10324_ = lean_uint8_dec_eq(v_op_10249_, v___x_10290_);
if (v___x_10324_ == 0)
{
uint8_t v___x_10325_; uint8_t v___x_10326_;
v___x_10325_ = 2;
v___x_10326_ = lean_uint8_dec_eq(v_op_10249_, v___x_10325_);
if (v___x_10326_ == 0)
{
uint8_t v___x_10327_; uint8_t v___x_10328_;
v___x_10327_ = 3;
v___x_10328_ = lean_uint8_dec_eq(v_op_10249_, v___x_10327_);
if (v___x_10328_ == 0)
{
uint8_t v___x_10329_; uint8_t v___x_10330_;
v___x_10329_ = 4;
v___x_10330_ = lean_uint8_dec_eq(v_op_10249_, v___x_10329_);
if (v___x_10330_ == 0)
{
uint8_t v___x_10331_;
v___x_10331_ = lean_uint8_dec_eq(v_op_10249_, v___x_10317_);
if (v___x_10331_ == 0)
{
v___y_10302_ = v_phaseOk_10318_;
v___y_10303_ = v___x_10321_;
v___y_10304_ = v_opOk_10319_;
v___y_10305_ = v_phase_10247_;
goto v___jp_10301_;
}
else
{
uint8_t v___x_10332_;
v___x_10332_ = lean_uint8_dec_eq(v_phase_10247_, v___x_10329_);
if (v___x_10332_ == 0)
{
v___y_10302_ = v_phaseOk_10318_;
v___y_10303_ = v___x_10321_;
v___y_10304_ = v_opOk_10319_;
v___y_10305_ = v_phase_10247_;
goto v___jp_10301_;
}
else
{
v___y_10302_ = v_phaseOk_10318_;
v___y_10303_ = v___x_10321_;
v___y_10304_ = v_opOk_10319_;
v___y_10305_ = v___x_10317_;
goto v___jp_10301_;
}
}
}
else
{
uint8_t v___x_10333_;
v___x_10333_ = lean_uint8_dec_eq(v_phase_10247_, v___x_10290_);
if (v___x_10333_ == 0)
{
v___y_10302_ = v_phaseOk_10318_;
v___y_10303_ = v___x_10321_;
v___y_10304_ = v_opOk_10319_;
v___y_10305_ = v_phase_10247_;
goto v___jp_10301_;
}
else
{
v___y_10302_ = v_phaseOk_10318_;
v___y_10303_ = v___x_10321_;
v___y_10304_ = v_opOk_10319_;
v___y_10305_ = v___x_10329_;
goto v___jp_10301_;
}
}
}
else
{
uint8_t v___x_10334_;
v___x_10334_ = lean_uint8_dec_eq(v_phase_10247_, v___x_10290_);
if (v___x_10334_ == 0)
{
v___y_10302_ = v_phaseOk_10318_;
v___y_10303_ = v___x_10321_;
v___y_10304_ = v_opOk_10319_;
v___y_10305_ = v_phase_10247_;
goto v___jp_10301_;
}
else
{
v___y_10302_ = v_phaseOk_10318_;
v___y_10303_ = v___x_10321_;
v___y_10304_ = v_opOk_10319_;
v___y_10305_ = v___x_10327_;
goto v___jp_10301_;
}
}
}
else
{
uint8_t v___x_10335_;
v___x_10335_ = lean_uint8_dec_eq(v_phase_10247_, v___x_10290_);
if (v___x_10335_ == 0)
{
v___y_10302_ = v_phaseOk_10318_;
v___y_10303_ = v___x_10321_;
v___y_10304_ = v_opOk_10319_;
v___y_10305_ = v_phase_10247_;
goto v___jp_10301_;
}
else
{
v___y_10302_ = v_phaseOk_10318_;
v___y_10303_ = v___x_10321_;
v___y_10304_ = v_opOk_10319_;
v___y_10305_ = v___x_10325_;
goto v___jp_10301_;
}
}
}
else
{
uint8_t v___x_10336_;
v___x_10336_ = lean_uint8_dec_eq(v_phase_10247_, v___x_10322_);
if (v___x_10336_ == 0)
{
v___y_10302_ = v_phaseOk_10318_;
v___y_10303_ = v___x_10321_;
v___y_10304_ = v_opOk_10319_;
v___y_10305_ = v_phase_10247_;
goto v___jp_10301_;
}
else
{
v___y_10302_ = v_phaseOk_10318_;
v___y_10303_ = v___x_10321_;
v___y_10304_ = v_opOk_10319_;
v___y_10305_ = v___x_10290_;
goto v___jp_10301_;
}
}
}
else
{
uint8_t v___x_10337_; uint8_t v___x_10338_;
v___x_10337_ = 3;
v___x_10338_ = lean_uint8_dec_eq(v_phase_10247_, v___x_10337_);
if (v___x_10338_ == 0)
{
uint8_t v___x_10339_;
v___x_10339_ = lean_uint8_dec_eq(v_phase_10247_, v___x_10317_);
if (v___x_10339_ == 0)
{
v___y_10302_ = v_phaseOk_10318_;
v___y_10303_ = v___x_10321_;
v___y_10304_ = v_opOk_10319_;
v___y_10305_ = v_phase_10247_;
goto v___jp_10301_;
}
else
{
v___y_10302_ = v_phaseOk_10318_;
v___y_10303_ = v___x_10321_;
v___y_10304_ = v_opOk_10319_;
v___y_10305_ = v___x_10322_;
goto v___jp_10301_;
}
}
else
{
v___y_10302_ = v_phaseOk_10318_;
v___y_10303_ = v___x_10321_;
v___y_10304_ = v_opOk_10319_;
v___y_10305_ = v___x_10322_;
goto v___jp_10301_;
}
}
}
}
}
}
}
}

LEAN_EXPORT uint64_t orb_crash_boundary_step(uint32_t v_durableQueued_10359_, uint32_t v_durableAcked_10360_, uint64_t v_stateRevision_10361_, uint32_t v_volatileInFlight_10362_, uint64_t v_leaseBootEpoch_10363_, uint64_t v_nodeBootEpoch_10364_, uint32_t v_volatileLeaseOwner_10365_, uint32_t v_reqOwner_10366_){
_start:
{
uint32_t v___y_10368_; uint32_t v___y_10369_; uint32_t v___y_10376_; uint32_t v___y_10377_; uint32_t v___y_10378_; uint32_t v___y_10379_; uint32_t v___y_10383_; uint32_t v___y_10384_; uint32_t v___y_10385_; uint8_t v___y_10386_; uint8_t v___y_10387_; uint32_t v___y_10388_; uint8_t v___y_10396_; uint32_t v___y_10397_; uint32_t v___y_10398_; uint8_t v___y_10399_; uint8_t v___y_10400_; uint32_t v___y_10401_; uint32_t v___y_10404_; uint8_t v___y_10405_; uint8_t v___y_10406_; uint8_t v___y_10407_; uint32_t v___y_10408_; uint8_t v___y_10413_; uint32_t v___y_10414_; uint32_t v___y_10415_; uint8_t v___y_10416_; uint8_t v___y_10417_; uint8_t v___y_10419_; uint32_t v___y_10420_; uint32_t v___y_10421_; uint32_t v___y_10422_; uint8_t v___y_10423_; uint32_t v___y_10426_; uint8_t v___y_10427_; uint32_t v___y_10428_; uint8_t v___y_10429_; uint32_t v___y_10430_; uint8_t v___y_10438_; uint32_t v___y_10439_; uint8_t v___y_10445_; uint8_t v___y_10448_; uint8_t v___x_10450_;
v___x_10450_ = lean_uint32_dec_le(v_durableAcked_10360_, v_durableQueued_10359_);
if (v___x_10450_ == 0)
{
v___y_10448_ = v___x_10450_;
goto v___jp_10447_;
}
else
{
uint64_t v___x_10451_; uint8_t v___x_10452_;
v___x_10451_ = 0ULL;
v___x_10452_ = lean_uint64_dec_eq(v_stateRevision_10361_, v___x_10451_);
if (v___x_10452_ == 0)
{
v___y_10448_ = v___x_10450_;
goto v___jp_10447_;
}
else
{
uint8_t v___x_10453_;
v___x_10453_ = 0;
v___y_10445_ = v___x_10453_;
goto v___jp_10444_;
}
}
v___jp_10367_:
{
uint64_t v___x_10370_; uint64_t v___x_10371_; uint64_t v___x_10372_; uint64_t v___x_10373_; uint64_t v___x_10374_;
v___x_10370_ = lean_uint32_to_uint64(v___y_10369_);
v___x_10371_ = lean_uint32_to_uint64(v___y_10368_);
v___x_10372_ = 32ULL;
v___x_10373_ = lean_uint64_shift_left(v___x_10371_, v___x_10372_);
v___x_10374_ = lean_uint64_lor(v___x_10370_, v___x_10373_);
return v___x_10374_;
}
v___jp_10375_:
{
uint32_t v___x_10380_; uint32_t v___x_10381_;
v___x_10380_ = lean_uint32_lor(v___y_10379_, v___y_10378_);
v___x_10381_ = lean_uint32_lor(v___x_10380_, v___y_10377_);
v___y_10368_ = v___y_10376_;
v___y_10369_ = v___x_10381_;
goto v___jp_10367_;
}
v___jp_10382_:
{
if (v___y_10387_ == 0)
{
v___y_10368_ = v___y_10385_;
v___y_10369_ = v___y_10383_;
goto v___jp_10367_;
}
else
{
if (v___y_10386_ == 0)
{
uint8_t v___x_10389_;
v___x_10389_ = lean_uint32_dec_eq(v___y_10385_, v___y_10383_);
if (v___x_10389_ == 0)
{
uint32_t v___x_10390_;
v___x_10390_ = 3;
v___y_10376_ = v___y_10385_;
v___y_10377_ = v___y_10384_;
v___y_10378_ = v___y_10388_;
v___y_10379_ = v___x_10390_;
goto v___jp_10375_;
}
else
{
uint32_t v___x_10391_;
v___x_10391_ = 2;
v___y_10376_ = v___y_10385_;
v___y_10377_ = v___y_10384_;
v___y_10378_ = v___y_10388_;
v___y_10379_ = v___x_10391_;
goto v___jp_10375_;
}
}
else
{
uint32_t v___x_10392_; uint32_t v___x_10393_; uint32_t v___x_10394_;
v___x_10392_ = 257;
v___x_10393_ = lean_uint32_lor(v___x_10392_, v___y_10388_);
v___x_10394_ = lean_uint32_lor(v___x_10393_, v___y_10384_);
v___y_10368_ = v___y_10385_;
v___y_10369_ = v___x_10394_;
goto v___jp_10367_;
}
}
}
v___jp_10395_:
{
if (v___y_10396_ == 0)
{
v___y_10383_ = v___y_10398_;
v___y_10384_ = v___y_10401_;
v___y_10385_ = v___y_10397_;
v___y_10386_ = v___y_10399_;
v___y_10387_ = v___y_10400_;
v___y_10388_ = v___y_10398_;
goto v___jp_10382_;
}
else
{
uint32_t v___x_10402_;
v___x_10402_ = 512;
v___y_10383_ = v___y_10398_;
v___y_10384_ = v___y_10401_;
v___y_10385_ = v___y_10397_;
v___y_10386_ = v___y_10399_;
v___y_10387_ = v___y_10400_;
v___y_10388_ = v___x_10402_;
goto v___jp_10382_;
}
}
v___jp_10403_:
{
uint32_t v___x_10409_; uint8_t v___x_10410_;
v___x_10409_ = 0;
v___x_10410_ = lean_uint32_dec_eq(v___y_10408_, v___x_10409_);
if (v___x_10410_ == 0)
{
uint32_t v___x_10411_;
v___x_10411_ = 1024;
v___y_10396_ = v___y_10405_;
v___y_10397_ = v___y_10404_;
v___y_10398_ = v___x_10409_;
v___y_10399_ = v___y_10406_;
v___y_10400_ = v___y_10407_;
v___y_10401_ = v___x_10411_;
goto v___jp_10395_;
}
else
{
v___y_10396_ = v___y_10405_;
v___y_10397_ = v___y_10404_;
v___y_10398_ = v___x_10409_;
v___y_10399_ = v___y_10406_;
v___y_10400_ = v___y_10407_;
v___y_10401_ = v___x_10409_;
goto v___jp_10395_;
}
}
v___jp_10412_:
{
if (v___y_10417_ == 0)
{
v___y_10404_ = v___y_10414_;
v___y_10405_ = v___y_10413_;
v___y_10406_ = v___y_10417_;
v___y_10407_ = v___y_10416_;
v___y_10408_ = v___y_10415_;
goto v___jp_10403_;
}
else
{
v___y_10404_ = v___y_10414_;
v___y_10405_ = v___y_10413_;
v___y_10406_ = v___y_10417_;
v___y_10407_ = v___y_10416_;
v___y_10408_ = v_reqOwner_10366_;
goto v___jp_10403_;
}
}
v___jp_10418_:
{
uint8_t v___x_10424_;
v___x_10424_ = lean_uint32_dec_lt(v___y_10421_, v___y_10420_);
v___y_10413_ = v___y_10419_;
v___y_10414_ = v___y_10420_;
v___y_10415_ = v___y_10422_;
v___y_10416_ = v___y_10423_;
v___y_10417_ = v___x_10424_;
goto v___jp_10412_;
}
v___jp_10425_:
{
if (v___y_10429_ == 0)
{
v___y_10404_ = v___y_10426_;
v___y_10405_ = v___y_10427_;
v___y_10406_ = v___y_10429_;
v___y_10407_ = v___y_10429_;
v___y_10408_ = v___y_10428_;
goto v___jp_10403_;
}
else
{
uint32_t v___x_10431_; uint8_t v___x_10432_;
v___x_10431_ = 0;
v___x_10432_ = lean_uint32_dec_lt(v___x_10431_, v___y_10426_);
if (v___x_10432_ == 0)
{
v___y_10413_ = v___y_10427_;
v___y_10414_ = v___y_10426_;
v___y_10415_ = v___y_10428_;
v___y_10416_ = v___y_10429_;
v___y_10417_ = v___x_10432_;
goto v___jp_10412_;
}
else
{
uint8_t v___x_10433_;
v___x_10433_ = lean_uint32_dec_eq(v_reqOwner_10366_, v___x_10431_);
if (v___x_10433_ == 0)
{
uint8_t v___x_10434_;
v___x_10434_ = lean_uint32_dec_eq(v___y_10428_, v___x_10431_);
if (v___x_10434_ == 0)
{
uint8_t v___x_10435_;
v___x_10435_ = lean_uint32_dec_eq(v___y_10428_, v_reqOwner_10366_);
if (v___x_10435_ == 0)
{
v___y_10413_ = v___y_10427_;
v___y_10414_ = v___y_10426_;
v___y_10415_ = v___y_10428_;
v___y_10416_ = v___y_10429_;
v___y_10417_ = v___x_10435_;
goto v___jp_10412_;
}
else
{
v___y_10419_ = v___y_10427_;
v___y_10420_ = v___y_10426_;
v___y_10421_ = v___y_10430_;
v___y_10422_ = v___y_10428_;
v___y_10423_ = v___y_10429_;
goto v___jp_10418_;
}
}
else
{
v___y_10419_ = v___y_10427_;
v___y_10420_ = v___y_10426_;
v___y_10421_ = v___y_10430_;
v___y_10422_ = v___y_10428_;
v___y_10423_ = v___y_10429_;
goto v___jp_10418_;
}
}
else
{
uint8_t v___x_10436_;
v___x_10436_ = 0;
v___y_10404_ = v___y_10426_;
v___y_10405_ = v___y_10427_;
v___y_10406_ = v___x_10436_;
v___y_10407_ = v___y_10429_;
v___y_10408_ = v___y_10428_;
goto v___jp_10403_;
}
}
}
}
v___jp_10437_:
{
uint8_t v___x_10440_;
v___x_10440_ = lean_uint64_dec_eq(v_leaseBootEpoch_10363_, v_nodeBootEpoch_10364_);
if (v___x_10440_ == 0)
{
uint8_t v___x_10441_; uint32_t v___x_10442_;
v___x_10441_ = 1;
v___x_10442_ = 0;
v___y_10426_ = v___y_10439_;
v___y_10427_ = v___x_10441_;
v___y_10428_ = v___x_10442_;
v___y_10429_ = v___y_10438_;
v___y_10430_ = v___x_10442_;
goto v___jp_10425_;
}
else
{
uint8_t v___x_10443_;
v___x_10443_ = 0;
v___y_10426_ = v___y_10439_;
v___y_10427_ = v___x_10443_;
v___y_10428_ = v_volatileLeaseOwner_10365_;
v___y_10429_ = v___y_10438_;
v___y_10430_ = v_volatileInFlight_10362_;
goto v___jp_10425_;
}
}
v___jp_10444_:
{
uint32_t v___x_10446_;
v___x_10446_ = 0;
v___y_10438_ = v___y_10445_;
v___y_10439_ = v___x_10446_;
goto v___jp_10437_;
}
v___jp_10447_:
{
if (v___y_10448_ == 0)
{
v___y_10445_ = v___y_10448_;
goto v___jp_10444_;
}
else
{
uint32_t v___x_10449_;
v___x_10449_ = lean_uint32_sub(v_durableQueued_10359_, v_durableAcked_10360_);
v___y_10438_ = v___y_10448_;
v___y_10439_ = v___x_10449_;
goto v___jp_10437_;
}
}
}
}

LEAN_EXPORT uint8_t orb_activation_rollback_admit(uint8_t v_currentStatus_10472_, uint8_t v_snapshotStatus_10473_, uint8_t v_hasActiveRun_10474_){
_start:
{
uint8_t v___x_10475_; uint8_t v___x_10476_;
v___x_10475_ = 0;
v___x_10476_ = lean_uint8_dec_eq(v_hasActiveRun_10474_, v___x_10475_);
if (v___x_10476_ == 0)
{
return v___x_10475_;
}
else
{
uint8_t v___x_10477_; uint8_t v___x_10478_;
v___x_10477_ = 10;
v___x_10478_ = lean_uint8_dec_le(v_currentStatus_10472_, v___x_10477_);
if (v___x_10478_ == 0)
{
return v___x_10475_;
}
else
{
uint8_t v___x_10479_;
v___x_10479_ = lean_uint8_dec_le(v_snapshotStatus_10473_, v___x_10477_);
if (v___x_10479_ == 0)
{
return v___x_10475_;
}
else
{
uint8_t v___x_10480_; uint8_t v___x_10481_;
v___x_10480_ = 3;
v___x_10481_ = lean_uint8_dec_eq(v_currentStatus_10472_, v___x_10480_);
if (v___x_10481_ == 0)
{
uint8_t v___x_10482_;
v___x_10482_ = lean_uint8_dec_eq(v_currentStatus_10472_, v___x_10475_);
if (v___x_10482_ == 0)
{
uint8_t v___x_10483_; uint8_t v___x_10484_;
v___x_10483_ = 1;
v___x_10484_ = lean_uint8_dec_eq(v_currentStatus_10472_, v___x_10483_);
if (v___x_10484_ == 0)
{
uint8_t v___x_10485_;
v___x_10485_ = lean_uint8_dec_eq(v_currentStatus_10472_, v_snapshotStatus_10473_);
if (v___x_10485_ == 0)
{
return v___x_10475_;
}
else
{
return v___x_10483_;
}
}
else
{
return v___x_10483_;
}
}
else
{
uint8_t v___x_10486_;
v___x_10486_ = 1;
return v___x_10486_;
}
}
else
{
return v___x_10475_;
}
}
}
}
}
}

LEAN_EXPORT uint32_t orb_remote_replay_step(uint8_t v_op_10495_, uint8_t v_isWaitingRemote_10496_, uint8_t v_waitMatches_10497_, uint8_t v_pastDeadline_10498_, uint8_t v_dispatchOutcome_10499_, uint8_t v_hasRecoveryHandle_10500_, uint8_t v_retryFitsDeadline_10501_, uint32_t v_retries_10502_, uint32_t v_maxRetries_10503_){
_start:
{
uint32_t v___y_10505_; uint8_t v___x_10508_; uint32_t v___y_10510_; uint8_t v___y_10511_; uint8_t v___x_10515_;
v___x_10508_ = 1;
v___x_10515_ = lean_uint8_dec_eq(v_op_10495_, v___x_10508_);
if (v___x_10515_ == 0)
{
uint8_t v___x_10516_; uint8_t v___x_10517_;
v___x_10516_ = 0;
v___x_10517_ = lean_uint8_dec_eq(v_op_10495_, v___x_10516_);
if (v___x_10517_ == 0)
{
uint32_t v___x_10518_;
v___x_10518_ = 0;
return v___x_10518_;
}
else
{
uint8_t v___x_10519_;
v___x_10519_ = lean_uint8_dec_eq(v_waitMatches_10497_, v___x_10508_);
if (v___x_10519_ == 0)
{
uint32_t v___x_10520_;
v___x_10520_ = 0;
return v___x_10520_;
}
else
{
uint8_t v___x_10521_;
v___x_10521_ = lean_uint8_dec_eq(v_isWaitingRemote_10496_, v___x_10508_);
if (v___x_10521_ == 0)
{
uint32_t v___x_10522_;
v___x_10522_ = 257;
return v___x_10522_;
}
else
{
uint8_t v___x_10523_;
v___x_10523_ = lean_uint8_dec_eq(v_pastDeadline_10498_, v___x_10508_);
if (v___x_10523_ == 0)
{
uint8_t v___x_10524_; uint32_t v___y_10526_;
v___x_10524_ = lean_uint8_dec_eq(v_dispatchOutcome_10499_, v___x_10516_);
if (v___x_10524_ == 0)
{
uint8_t v___x_10529_;
v___x_10529_ = lean_uint8_dec_eq(v_hasRecoveryHandle_10500_, v___x_10516_);
if (v___x_10529_ == 0)
{
uint32_t v___x_10530_;
v___x_10530_ = 512;
v___y_10526_ = v___x_10530_;
goto v___jp_10525_;
}
else
{
uint32_t v___x_10531_;
v___x_10531_ = 1536;
v___y_10526_ = v___x_10531_;
goto v___jp_10525_;
}
}
else
{
uint32_t v___x_10532_;
v___x_10532_ = 259;
return v___x_10532_;
}
v___jp_10525_:
{
uint8_t v___x_10527_;
v___x_10527_ = lean_uint8_dec_eq(v_dispatchOutcome_10499_, v___x_10508_);
if (v___x_10527_ == 0)
{
v___y_10510_ = v___y_10526_;
v___y_10511_ = v___x_10524_;
goto v___jp_10509_;
}
else
{
uint8_t v___x_10528_;
v___x_10528_ = lean_uint32_dec_lt(v_retries_10502_, v_maxRetries_10503_);
v___y_10510_ = v___y_10526_;
v___y_10511_ = v___x_10528_;
goto v___jp_10509_;
}
}
}
else
{
uint32_t v___x_10533_;
v___x_10533_ = 258;
return v___x_10533_;
}
}
}
}
}
else
{
uint8_t v___x_10534_;
v___x_10534_ = lean_uint8_dec_eq(v_isWaitingRemote_10496_, v___x_10508_);
if (v___x_10534_ == 0)
{
uint32_t v___x_10535_;
v___x_10535_ = 0;
return v___x_10535_;
}
else
{
uint8_t v___x_10536_;
v___x_10536_ = lean_uint8_dec_eq(v_waitMatches_10497_, v___x_10508_);
if (v___x_10536_ == 0)
{
uint32_t v___x_10537_;
v___x_10537_ = 0;
return v___x_10537_;
}
else
{
uint8_t v___x_10538_; uint8_t v___x_10539_;
v___x_10538_ = 0;
v___x_10539_ = lean_uint8_dec_eq(v_hasRecoveryHandle_10500_, v___x_10538_);
if (v___x_10539_ == 0)
{
uint32_t v___x_10540_;
v___x_10540_ = 0;
return v___x_10540_;
}
else
{
uint8_t v___x_10541_;
v___x_10541_ = lean_uint8_dec_eq(v_pastDeadline_10498_, v___x_10508_);
if (v___x_10541_ == 0)
{
uint32_t v___x_10542_;
v___x_10542_ = 0;
return v___x_10542_;
}
else
{
uint8_t v___x_10543_;
v___x_10543_ = lean_uint8_dec_eq(v_dispatchOutcome_10499_, v___x_10508_);
if (v___x_10543_ == 0)
{
uint32_t v___x_10544_;
v___x_10544_ = 0;
return v___x_10544_;
}
else
{
uint32_t v___x_10545_;
v___x_10545_ = 262;
return v___x_10545_;
}
}
}
}
}
}
v___jp_10504_:
{
uint32_t v___x_10506_; uint32_t v___x_10507_;
v___x_10506_ = 261;
v___x_10507_ = lean_uint32_lor(v___x_10506_, v___y_10505_);
return v___x_10507_;
}
v___jp_10509_:
{
if (v___y_10511_ == 0)
{
v___y_10505_ = v___y_10510_;
goto v___jp_10504_;
}
else
{
uint8_t v___x_10512_;
v___x_10512_ = lean_uint8_dec_eq(v_retryFitsDeadline_10501_, v___x_10508_);
if (v___x_10512_ == 0)
{
v___y_10505_ = v___y_10510_;
goto v___jp_10504_;
}
else
{
uint32_t v___x_10513_; uint32_t v___x_10514_;
v___x_10513_ = 260;
v___x_10514_ = lean_uint32_lor(v___x_10513_, v___y_10510_);
return v___x_10514_;
}
}
}
}
}

LEAN_EXPORT uint8_t orb_memory_tool_gate(uint8_t v_opKind_10566_, uint8_t v_callerRole_10567_, uint8_t v_isExternalSession_10568_, uint8_t v_bunkerState_10569_, uint8_t v_onManagedNode_10570_, uint8_t v_hasProjectMemorySkill_10571_, uint8_t v_hasSecretAccess_10572_, uint8_t v_bankKind_10573_, uint32_t v_requestedLimit_10574_, uint32_t v_maxLimit_10575_, uint32_t v_requestedTokens_10576_, uint32_t v_maxTokens_10577_){
_start:
{
uint8_t v___x_10578_; uint8_t v___y_10580_; uint8_t v___y_10581_; uint8_t v___y_10582_; uint8_t v___y_10583_; uint8_t v___y_10589_; uint8_t v___y_10590_; uint8_t v___y_10591_; uint8_t v___y_10601_; uint8_t v___x_10607_;
v___x_10578_ = 1;
v___x_10607_ = lean_uint8_dec_eq(v_callerRole_10567_, v___x_10578_);
if (v___x_10607_ == 0)
{
uint8_t v___x_10608_; uint8_t v___x_10609_;
v___x_10608_ = 2;
v___x_10609_ = lean_uint8_dec_eq(v_callerRole_10567_, v___x_10608_);
if (v___x_10609_ == 0)
{
uint8_t v___x_10610_; uint8_t v___x_10611_;
v___x_10610_ = 0;
v___x_10611_ = lean_uint8_dec_eq(v_callerRole_10567_, v___x_10610_);
if (v___x_10611_ == 0)
{
v___y_10601_ = v___x_10611_;
goto v___jp_10600_;
}
else
{
uint8_t v___x_10612_;
v___x_10612_ = lean_uint8_dec_eq(v_isExternalSession_10568_, v___x_10610_);
if (v___x_10612_ == 0)
{
goto v___jp_10605_;
}
else
{
uint8_t v___x_10613_;
v___x_10613_ = lean_uint8_dec_eq(v_hasProjectMemorySkill_10571_, v___x_10578_);
if (v___x_10613_ == 0)
{
goto v___jp_10605_;
}
else
{
v___y_10601_ = v___x_10613_;
goto v___jp_10600_;
}
}
}
}
else
{
v___y_10601_ = v___x_10609_;
goto v___jp_10600_;
}
}
else
{
v___y_10601_ = v___x_10607_;
goto v___jp_10600_;
}
v___jp_10579_:
{
uint8_t v___x_10584_; uint8_t v___x_10585_;
v___x_10584_ = 3;
v___x_10585_ = lean_uint8_dec_le(v_opKind_10566_, v___x_10584_);
if (v___x_10585_ == 0)
{
return v___y_10582_;
}
else
{
uint8_t v___x_10586_;
v___x_10586_ = lean_uint8_dec_le(v_bankKind_10573_, v___x_10578_);
if (v___x_10586_ == 0)
{
return v___y_10582_;
}
else
{
uint8_t v___x_10587_;
v___x_10587_ = lean_uint8_dec_eq(v_onManagedNode_10570_, v___y_10582_);
if (v___x_10587_ == 0)
{
return v___y_10582_;
}
else
{
if (v___y_10581_ == 0)
{
return v___y_10582_;
}
else
{
if (v___y_10580_ == 0)
{
return v___y_10582_;
}
else
{
if (v___y_10583_ == 0)
{
return v___y_10582_;
}
else
{
return v___x_10578_;
}
}
}
}
}
}
}
v___jp_10588_:
{
uint32_t v___x_10592_; uint8_t v___x_10593_;
v___x_10592_ = 1;
v___x_10593_ = lean_uint32_dec_le(v___x_10592_, v_maxLimit_10575_);
if (v___x_10593_ == 0)
{
v___y_10580_ = v___y_10589_;
v___y_10581_ = v___y_10591_;
v___y_10582_ = v___y_10590_;
v___y_10583_ = v___x_10593_;
goto v___jp_10579_;
}
else
{
uint8_t v___x_10594_;
v___x_10594_ = lean_uint32_dec_le(v___x_10592_, v_requestedLimit_10574_);
if (v___x_10594_ == 0)
{
v___y_10580_ = v___y_10589_;
v___y_10581_ = v___y_10591_;
v___y_10582_ = v___y_10590_;
v___y_10583_ = v___x_10594_;
goto v___jp_10579_;
}
else
{
uint8_t v___x_10595_;
v___x_10595_ = lean_uint32_dec_le(v_requestedLimit_10574_, v_maxLimit_10575_);
if (v___x_10595_ == 0)
{
v___y_10580_ = v___y_10589_;
v___y_10581_ = v___y_10591_;
v___y_10582_ = v___y_10590_;
v___y_10583_ = v___x_10595_;
goto v___jp_10579_;
}
else
{
uint32_t v___x_10596_; uint8_t v___x_10597_;
v___x_10596_ = 256;
v___x_10597_ = lean_uint32_dec_le(v___x_10596_, v_maxTokens_10577_);
if (v___x_10597_ == 0)
{
v___y_10580_ = v___y_10589_;
v___y_10581_ = v___y_10591_;
v___y_10582_ = v___y_10590_;
v___y_10583_ = v___x_10597_;
goto v___jp_10579_;
}
else
{
uint8_t v___x_10598_;
v___x_10598_ = lean_uint32_dec_le(v___x_10592_, v_requestedTokens_10576_);
if (v___x_10598_ == 0)
{
v___y_10580_ = v___y_10589_;
v___y_10581_ = v___y_10591_;
v___y_10582_ = v___y_10590_;
v___y_10583_ = v___x_10598_;
goto v___jp_10579_;
}
else
{
uint8_t v___x_10599_;
v___x_10599_ = lean_uint32_dec_le(v_requestedTokens_10576_, v_maxTokens_10577_);
v___y_10580_ = v___y_10589_;
v___y_10581_ = v___y_10591_;
v___y_10582_ = v___y_10590_;
v___y_10583_ = v___x_10599_;
goto v___jp_10579_;
}
}
}
}
}
}
v___jp_10600_:
{
uint8_t v___x_10602_; uint8_t v___x_10603_;
v___x_10602_ = 0;
v___x_10603_ = lean_uint8_dec_eq(v_isExternalSession_10568_, v___x_10602_);
if (v___x_10603_ == 0)
{
uint8_t v___x_10604_;
v___x_10604_ = lean_uint8_dec_eq(v_bunkerState_10569_, v___x_10602_);
v___y_10589_ = v___y_10601_;
v___y_10590_ = v___x_10602_;
v___y_10591_ = v___x_10604_;
goto v___jp_10588_;
}
else
{
v___y_10589_ = v___y_10601_;
v___y_10590_ = v___x_10602_;
v___y_10591_ = v___x_10603_;
goto v___jp_10588_;
}
}
v___jp_10605_:
{
uint8_t v___x_10606_;
v___x_10606_ = lean_uint8_dec_eq(v_hasSecretAccess_10572_, v___x_10578_);
v___y_10601_ = v___x_10606_;
goto v___jp_10600_;
}
}
}

LEAN_EXPORT uint8_t orb_upload_cleanup_gate(uint8_t v_hasValidUuid_10640_, uint8_t v_isSharedLibraryArchive_10641_, uint8_t v_isExpiredForGc_10642_){
_start:
{
uint8_t v___x_10643_; uint8_t v___x_10644_;
v___x_10643_ = 1;
v___x_10644_ = lean_uint8_dec_eq(v_hasValidUuid_10640_, v___x_10643_);
if (v___x_10644_ == 0)
{
uint8_t v___x_10645_;
v___x_10645_ = 0;
return v___x_10645_;
}
else
{
uint8_t v___x_10646_; uint8_t v___x_10647_;
v___x_10646_ = 0;
v___x_10647_ = lean_uint8_dec_eq(v_isSharedLibraryArchive_10641_, v___x_10646_);
if (v___x_10647_ == 0)
{
uint8_t v___x_10648_;
v___x_10648_ = lean_uint8_dec_eq(v_isExpiredForGc_10642_, v___x_10643_);
if (v___x_10648_ == 0)
{
return v___x_10646_;
}
else
{
return v___x_10643_;
}
}
else
{
return v___x_10643_;
}
}
}
}

LEAN_EXPORT uint8_t orb_proxy_exhaustion_step(uint32_t v_rateLimitCount_10657_, uint32_t v_paymentRequiredCount_10658_, uint32_t v_clientAuthErrorCount_10659_, uint32_t v_serverErrorCount_10660_, uint32_t v_transportValidationCount_10661_, uint8_t v_hasContextOverflow_10662_){
_start:
{
uint32_t v___x_10663_; uint8_t v___y_10669_; uint8_t v___y_10673_; uint8_t v___y_10674_; uint8_t v___y_10678_; uint8_t v___y_10679_; uint8_t v___y_10682_; uint8_t v___y_10685_; uint8_t v___y_10686_; uint8_t v___y_10689_; uint8_t v___y_10690_; uint8_t v___y_10694_; uint8_t v___y_10697_; uint8_t v___y_10698_; uint8_t v___x_10716_;
v___x_10663_ = 0;
v___x_10716_ = lean_uint32_dec_eq(v_rateLimitCount_10657_, v___x_10663_);
if (v___x_10716_ == 0)
{
goto v___jp_10700_;
}
else
{
uint8_t v___x_10717_;
v___x_10717_ = lean_uint32_dec_eq(v_paymentRequiredCount_10658_, v___x_10663_);
if (v___x_10717_ == 0)
{
goto v___jp_10700_;
}
else
{
uint8_t v___x_10718_;
v___x_10718_ = lean_uint32_dec_eq(v_clientAuthErrorCount_10659_, v___x_10663_);
if (v___x_10718_ == 0)
{
goto v___jp_10700_;
}
else
{
uint8_t v___x_10719_;
v___x_10719_ = lean_uint32_dec_eq(v_serverErrorCount_10660_, v___x_10663_);
if (v___x_10719_ == 0)
{
goto v___jp_10700_;
}
else
{
uint8_t v___x_10720_;
v___x_10720_ = 1;
return v___x_10720_;
}
}
}
}
v___jp_10664_:
{
uint8_t v___x_10665_;
v___x_10665_ = lean_uint32_dec_eq(v_rateLimitCount_10657_, v___x_10663_);
if (v___x_10665_ == 0)
{
uint8_t v___x_10666_;
v___x_10666_ = 7;
return v___x_10666_;
}
else
{
uint8_t v___x_10667_;
v___x_10667_ = 6;
return v___x_10667_;
}
}
v___jp_10668_:
{
uint8_t v___x_10670_;
v___x_10670_ = lean_uint32_dec_eq(v_serverErrorCount_10660_, v___x_10663_);
if (v___x_10670_ == 0)
{
goto v___jp_10664_;
}
else
{
if (v___y_10669_ == 0)
{
uint8_t v___x_10671_;
v___x_10671_ = 7;
return v___x_10671_;
}
else
{
goto v___jp_10664_;
}
}
}
v___jp_10672_:
{
if (v___y_10674_ == 0)
{
v___y_10669_ = v___y_10673_;
goto v___jp_10668_;
}
else
{
uint8_t v___x_10675_;
v___x_10675_ = lean_uint32_dec_eq(v_serverErrorCount_10660_, v___x_10663_);
if (v___x_10675_ == 0)
{
v___y_10669_ = v___x_10675_;
goto v___jp_10668_;
}
else
{
uint8_t v___x_10676_;
v___x_10676_ = 5;
return v___x_10676_;
}
}
}
v___jp_10677_:
{
if (v___y_10679_ == 0)
{
v___y_10673_ = v___y_10678_;
v___y_10674_ = v___y_10678_;
goto v___jp_10672_;
}
else
{
uint8_t v___x_10680_;
v___x_10680_ = lean_uint32_dec_eq(v_rateLimitCount_10657_, v___x_10663_);
v___y_10673_ = v___y_10678_;
v___y_10674_ = v___x_10680_;
goto v___jp_10672_;
}
}
v___jp_10681_:
{
uint8_t v___x_10683_;
v___x_10683_ = lean_uint32_dec_eq(v_paymentRequiredCount_10658_, v___x_10663_);
v___y_10678_ = v___y_10682_;
v___y_10679_ = v___x_10683_;
goto v___jp_10677_;
}
v___jp_10684_:
{
uint8_t v___x_10687_;
v___x_10687_ = lean_uint32_dec_eq(v_clientAuthErrorCount_10659_, v___x_10663_);
if (v___x_10687_ == 0)
{
v___y_10682_ = v___y_10685_;
goto v___jp_10681_;
}
else
{
if (v___y_10686_ == 0)
{
v___y_10678_ = v___y_10685_;
v___y_10679_ = v___y_10685_;
goto v___jp_10677_;
}
else
{
v___y_10682_ = v___y_10685_;
goto v___jp_10681_;
}
}
}
v___jp_10688_:
{
if (v___y_10690_ == 0)
{
v___y_10685_ = v___y_10689_;
v___y_10686_ = v___y_10689_;
goto v___jp_10684_;
}
else
{
uint8_t v___x_10691_;
v___x_10691_ = lean_uint32_dec_eq(v_serverErrorCount_10660_, v___x_10663_);
if (v___x_10691_ == 0)
{
v___y_10685_ = v___y_10689_;
v___y_10686_ = v___x_10691_;
goto v___jp_10684_;
}
else
{
uint8_t v___x_10692_;
v___x_10692_ = 4;
return v___x_10692_;
}
}
}
v___jp_10693_:
{
uint8_t v___x_10695_;
v___x_10695_ = lean_uint32_dec_eq(v_rateLimitCount_10657_, v___x_10663_);
v___y_10689_ = v___y_10694_;
v___y_10690_ = v___x_10695_;
goto v___jp_10688_;
}
v___jp_10696_:
{
uint8_t v___x_10699_;
v___x_10699_ = lean_uint32_dec_eq(v_paymentRequiredCount_10658_, v___x_10663_);
if (v___x_10699_ == 0)
{
v___y_10694_ = v___y_10697_;
goto v___jp_10693_;
}
else
{
if (v___y_10698_ == 0)
{
v___y_10689_ = v___y_10697_;
v___y_10690_ = v___y_10697_;
goto v___jp_10688_;
}
else
{
v___y_10694_ = v___y_10697_;
goto v___jp_10693_;
}
}
}
v___jp_10700_:
{
uint64_t v___x_10701_; uint64_t v___x_10702_; uint64_t v___x_10703_; uint64_t v___x_10704_; uint64_t v___x_10705_; uint64_t v___x_10706_; uint64_t v_attempted_10707_; uint64_t v___x_10708_; uint8_t v___x_10709_;
v___x_10701_ = lean_uint32_to_uint64(v_rateLimitCount_10657_);
v___x_10702_ = lean_uint32_to_uint64(v_paymentRequiredCount_10658_);
v___x_10703_ = lean_uint64_add(v___x_10701_, v___x_10702_);
v___x_10704_ = lean_uint32_to_uint64(v_clientAuthErrorCount_10659_);
v___x_10705_ = lean_uint64_add(v___x_10703_, v___x_10704_);
v___x_10706_ = lean_uint32_to_uint64(v_serverErrorCount_10660_);
v_attempted_10707_ = lean_uint64_add(v___x_10705_, v___x_10706_);
v___x_10708_ = lean_uint32_to_uint64(v_transportValidationCount_10661_);
v___x_10709_ = lean_uint64_dec_eq(v___x_10708_, v_attempted_10707_);
if (v___x_10709_ == 0)
{
uint8_t v___x_10710_; uint8_t v___x_10711_;
v___x_10710_ = 1;
v___x_10711_ = lean_uint8_dec_eq(v_hasContextOverflow_10662_, v___x_10710_);
if (v___x_10711_ == 0)
{
v___y_10697_ = v___x_10709_;
v___y_10698_ = v___x_10709_;
goto v___jp_10696_;
}
else
{
uint8_t v___x_10712_;
v___x_10712_ = lean_uint32_dec_eq(v_rateLimitCount_10657_, v___x_10663_);
if (v___x_10712_ == 0)
{
v___y_10697_ = v___x_10709_;
v___y_10698_ = v___x_10709_;
goto v___jp_10696_;
}
else
{
uint8_t v___x_10713_;
v___x_10713_ = lean_uint32_dec_eq(v_paymentRequiredCount_10658_, v___x_10663_);
if (v___x_10713_ == 0)
{
v___y_10697_ = v___x_10709_;
v___y_10698_ = v___x_10713_;
goto v___jp_10696_;
}
else
{
uint8_t v___x_10714_;
v___x_10714_ = 3;
return v___x_10714_;
}
}
}
}
else
{
uint8_t v___x_10715_;
v___x_10715_ = 2;
return v___x_10715_;
}
}
}
}

LEAN_EXPORT uint8_t orb_composer_default_step(uint8_t v_hasExplicitChoice_10735_, uint8_t v_hasPinnedContext_10736_, uint8_t v_hermesAvailable_10737_, uint8_t v_hasNativeHarness_10738_){
_start:
{
uint8_t v___x_10739_; uint8_t v___x_10744_;
v___x_10739_ = 1;
v___x_10744_ = lean_uint8_dec_eq(v_hasExplicitChoice_10735_, v___x_10739_);
if (v___x_10744_ == 0)
{
uint8_t v___x_10745_; uint8_t v___x_10746_;
v___x_10745_ = 0;
v___x_10746_ = lean_uint8_dec_eq(v_hasPinnedContext_10736_, v___x_10745_);
if (v___x_10746_ == 0)
{
goto v___jp_10740_;
}
else
{
uint8_t v___x_10747_;
v___x_10747_ = lean_uint8_dec_eq(v_hermesAvailable_10737_, v___x_10739_);
if (v___x_10747_ == 0)
{
goto v___jp_10740_;
}
else
{
return v___x_10739_;
}
}
}
else
{
uint8_t v___x_10748_;
v___x_10748_ = 0;
return v___x_10748_;
}
v___jp_10740_:
{
uint8_t v___x_10741_;
v___x_10741_ = lean_uint8_dec_eq(v_hasNativeHarness_10738_, v___x_10739_);
if (v___x_10741_ == 0)
{
uint8_t v___x_10742_;
v___x_10742_ = 3;
return v___x_10742_;
}
else
{
uint8_t v___x_10743_;
v___x_10743_ = 2;
return v___x_10743_;
}
}
}
}

LEAN_EXPORT uint32_t orb_cloud_handoff_step(uint8_t v_sourceIsCloud_10759_, uint8_t v_isSideQuestion_10760_, uint8_t v_targetIsNative_10761_, uint8_t v_hasHistoryTurns_10762_, uint8_t v_targetPlacementValid_10763_){
_start:
{
uint8_t v___x_10764_; uint8_t v___x_10765_;
v___x_10764_ = 1;
v___x_10765_ = lean_uint8_dec_eq(v_targetIsNative_10761_, v___x_10764_);
if (v___x_10765_ == 0)
{
uint32_t v___x_10766_;
v___x_10766_ = 0;
return v___x_10766_;
}
else
{
uint8_t v___x_10767_;
v___x_10767_ = lean_uint8_dec_eq(v_targetPlacementValid_10763_, v___x_10764_);
if (v___x_10767_ == 0)
{
uint32_t v___x_10768_;
v___x_10768_ = 0;
return v___x_10768_;
}
else
{
uint8_t v___x_10769_;
v___x_10769_ = lean_uint8_dec_eq(v_sourceIsCloud_10759_, v___x_10764_);
if (v___x_10769_ == 0)
{
uint32_t v___x_10770_;
v___x_10770_ = 65537;
return v___x_10770_;
}
else
{
uint8_t v___x_10771_; uint8_t v___x_10772_;
v___x_10771_ = 0;
v___x_10772_ = lean_uint8_dec_eq(v_isSideQuestion_10760_, v___x_10771_);
if (v___x_10772_ == 0)
{
uint32_t v___x_10773_;
v___x_10773_ = 0;
return v___x_10773_;
}
else
{
uint8_t v___x_10774_;
v___x_10774_ = lean_uint8_dec_eq(v_hasHistoryTurns_10762_, v___x_10764_);
if (v___x_10774_ == 0)
{
uint32_t v___x_10775_;
v___x_10775_ = 0;
return v___x_10775_;
}
else
{
uint32_t v___x_10776_;
v___x_10776_ = 16777473;
return v___x_10776_;
}
}
}
}
}
}
}

LEAN_EXPORT uint64_t orb_fast_poll_delay_ms(uint8_t v_isStopping_10789_, uint64_t v_elapsedMs_10790_, uint32_t v_consecutiveFailures_10791_){
_start:
{
uint32_t v___x_10792_; uint8_t v___x_10793_;
v___x_10792_ = 4;
v___x_10793_ = lean_uint32_dec_le(v___x_10792_, v_consecutiveFailures_10791_);
if (v___x_10793_ == 0)
{
uint32_t v___x_10794_; uint8_t v___x_10795_;
v___x_10794_ = 3;
v___x_10795_ = lean_uint32_dec_eq(v_consecutiveFailures_10791_, v___x_10794_);
if (v___x_10795_ == 0)
{
uint32_t v___x_10796_; uint8_t v___x_10797_;
v___x_10796_ = 2;
v___x_10797_ = lean_uint32_dec_eq(v_consecutiveFailures_10791_, v___x_10796_);
if (v___x_10797_ == 0)
{
uint32_t v___x_10798_; uint8_t v___x_10799_;
v___x_10798_ = 1;
v___x_10799_ = lean_uint32_dec_eq(v_consecutiveFailures_10791_, v___x_10798_);
if (v___x_10799_ == 0)
{
uint8_t v___x_10800_; uint8_t v___x_10801_;
v___x_10800_ = 1;
v___x_10801_ = lean_uint8_dec_eq(v_isStopping_10789_, v___x_10800_);
if (v___x_10801_ == 0)
{
uint64_t v___x_10802_; uint8_t v___x_10803_;
v___x_10802_ = 4000ULL;
v___x_10803_ = lean_uint64_dec_lt(v_elapsedMs_10790_, v___x_10802_);
if (v___x_10803_ == 0)
{
uint64_t v___x_10804_; uint8_t v___x_10805_;
v___x_10804_ = 15000ULL;
v___x_10805_ = lean_uint64_dec_lt(v_elapsedMs_10790_, v___x_10804_);
if (v___x_10805_ == 0)
{
uint64_t v___x_10806_;
v___x_10806_ = 500ULL;
return v___x_10806_;
}
else
{
uint64_t v___x_10807_;
v___x_10807_ = 200ULL;
return v___x_10807_;
}
}
else
{
uint64_t v___x_10808_;
v___x_10808_ = 80ULL;
return v___x_10808_;
}
}
else
{
uint64_t v___x_10809_;
v___x_10809_ = 500ULL;
return v___x_10809_;
}
}
else
{
uint64_t v___x_10810_;
v___x_10810_ = 1000ULL;
return v___x_10810_;
}
}
else
{
uint64_t v___x_10811_;
v___x_10811_ = 2000ULL;
return v___x_10811_;
}
}
else
{
uint64_t v___x_10812_;
v___x_10812_ = 4000ULL;
return v___x_10812_;
}
}
else
{
uint64_t v___x_10813_;
v___x_10813_ = 5000ULL;
return v___x_10813_;
}
}
}

LEAN_EXPORT uint8_t orb_mcp_preflight_cache_gate(uint8_t v_hasCached_10822_, uint8_t v_identityMatches_10823_, uint8_t v_contractMatches_10824_, uint8_t v_sessionUnexpired_10825_, uint64_t v_ageSecs_10826_, uint64_t v_maxTtlSecs_10827_){
_start:
{
uint8_t v___x_10828_; uint8_t v___x_10829_;
v___x_10828_ = 1;
v___x_10829_ = lean_uint8_dec_eq(v_hasCached_10822_, v___x_10828_);
if (v___x_10829_ == 0)
{
uint8_t v___x_10830_;
v___x_10830_ = 0;
return v___x_10830_;
}
else
{
uint8_t v___x_10831_;
v___x_10831_ = lean_uint8_dec_eq(v_identityMatches_10823_, v___x_10828_);
if (v___x_10831_ == 0)
{
uint8_t v___x_10832_;
v___x_10832_ = 0;
return v___x_10832_;
}
else
{
uint8_t v___x_10833_;
v___x_10833_ = lean_uint8_dec_eq(v_contractMatches_10824_, v___x_10828_);
if (v___x_10833_ == 0)
{
uint8_t v___x_10834_;
v___x_10834_ = 0;
return v___x_10834_;
}
else
{
uint8_t v___x_10835_;
v___x_10835_ = lean_uint8_dec_eq(v_sessionUnexpired_10825_, v___x_10828_);
if (v___x_10835_ == 0)
{
uint8_t v___x_10836_;
v___x_10836_ = 0;
return v___x_10836_;
}
else
{
uint64_t v___x_10837_; uint8_t v___x_10838_;
v___x_10837_ = 1ULL;
v___x_10838_ = lean_uint64_dec_le(v___x_10837_, v_maxTtlSecs_10827_);
if (v___x_10838_ == 0)
{
uint8_t v___x_10839_;
v___x_10839_ = 0;
return v___x_10839_;
}
else
{
uint64_t v___x_10840_; uint8_t v___x_10841_;
v___x_10840_ = 300ULL;
v___x_10841_ = lean_uint64_dec_le(v_maxTtlSecs_10827_, v___x_10840_);
if (v___x_10841_ == 0)
{
uint8_t v___x_10842_;
v___x_10842_ = 0;
return v___x_10842_;
}
else
{
uint8_t v___x_10843_;
v___x_10843_ = lean_uint64_dec_le(v_ageSecs_10826_, v_maxTtlSecs_10827_);
if (v___x_10843_ == 0)
{
uint8_t v___x_10844_;
v___x_10844_ = 0;
return v___x_10844_;
}
else
{
return v___x_10828_;
}
}
}
}
}
}
}
}
}

LEAN_EXPORT uint32_t orb_codex_goal_launch_step(uint8_t v_isGoalRequest_10859_, uint8_t v_hasNonEmptyObjective_10860_, uint8_t v_hasImages_10861_, uint8_t v_hasExplicitCyber_10862_, uint8_t v_hasChatGptAuth_10863_, uint8_t v_modelCompatible_10864_, uint8_t v_accountSupportsProgram_10865_, uint8_t v_resumedGoalActive_10866_, uint8_t v_hasRetiredAlias_10867_){
_start:
{
uint32_t v___y_10869_; uint8_t v___x_10872_; uint32_t v___y_10874_; uint8_t v___y_10875_; uint32_t v___y_10882_; uint8_t v___y_10883_; uint8_t v___y_10884_; uint8_t v___y_10885_; uint8_t v___y_10892_; uint8_t v___y_10893_; uint32_t v___y_10894_; uint8_t v___y_10901_; uint8_t v___y_10902_; uint8_t v___x_10904_;
v___x_10872_ = 0;
v___x_10904_ = lean_uint8_dec_eq(v_isGoalRequest_10859_, v___x_10872_);
if (v___x_10904_ == 0)
{
uint8_t v___x_10905_;
v___x_10905_ = 1;
v___y_10901_ = v___x_10905_;
v___y_10902_ = v___x_10905_;
goto v___jp_10900_;
}
else
{
uint8_t v___x_10906_; uint8_t v___x_10907_;
v___x_10906_ = 0;
v___x_10907_ = lean_uint8_dec_eq(v_resumedGoalActive_10866_, v___x_10872_);
if (v___x_10907_ == 0)
{
v___y_10901_ = v___x_10906_;
v___y_10902_ = v___x_10904_;
goto v___jp_10900_;
}
else
{
uint32_t v___x_10908_;
v___x_10908_ = 0;
v___y_10892_ = v___x_10906_;
v___y_10893_ = v___x_10906_;
v___y_10894_ = v___x_10908_;
goto v___jp_10891_;
}
}
v___jp_10868_:
{
uint32_t v___x_10870_; uint32_t v___x_10871_;
v___x_10870_ = 256;
v___x_10871_ = lean_uint32_lor(v___x_10870_, v___y_10869_);
return v___x_10871_;
}
v___jp_10873_:
{
if (v___y_10875_ == 0)
{
v___y_10869_ = v___y_10874_;
goto v___jp_10868_;
}
else
{
uint8_t v___x_10876_;
v___x_10876_ = lean_uint8_dec_eq(v_hasNonEmptyObjective_10860_, v___x_10872_);
if (v___x_10876_ == 0)
{
uint8_t v___x_10877_;
v___x_10877_ = lean_uint8_dec_eq(v_hasImages_10861_, v___x_10872_);
if (v___x_10877_ == 0)
{
uint32_t v___x_10878_;
v___x_10878_ = 7;
return v___x_10878_;
}
else
{
if (v___x_10876_ == 0)
{
v___y_10869_ = v___y_10874_;
goto v___jp_10868_;
}
else
{
uint32_t v___x_10879_;
v___x_10879_ = 7;
return v___x_10879_;
}
}
}
else
{
uint32_t v___x_10880_;
v___x_10880_ = 6;
return v___x_10880_;
}
}
}
v___jp_10881_:
{
if (v___y_10885_ == 0)
{
v___y_10874_ = v___y_10882_;
v___y_10875_ = v___y_10883_;
goto v___jp_10873_;
}
else
{
uint8_t v___x_10886_;
v___x_10886_ = lean_uint8_dec_eq(v_hasChatGptAuth_10863_, v___x_10872_);
if (v___x_10886_ == 0)
{
uint8_t v___x_10887_;
v___x_10887_ = lean_uint8_dec_eq(v_accountSupportsProgram_10865_, v___x_10872_);
if (v___x_10887_ == 0)
{
if (v___y_10884_ == 0)
{
v___y_10874_ = v___y_10882_;
v___y_10875_ = v___y_10883_;
goto v___jp_10873_;
}
else
{
uint32_t v___x_10888_;
v___x_10888_ = 5;
return v___x_10888_;
}
}
else
{
uint32_t v___x_10889_;
v___x_10889_ = 4;
return v___x_10889_;
}
}
else
{
uint32_t v___x_10890_;
v___x_10890_ = 3;
return v___x_10890_;
}
}
}
v___jp_10891_:
{
uint8_t v___x_10895_;
v___x_10895_ = lean_uint8_dec_eq(v_hasRetiredAlias_10867_, v___x_10872_);
if (v___x_10895_ == 0)
{
uint32_t v___x_10896_;
v___x_10896_ = 1;
return v___x_10896_;
}
else
{
uint8_t v___x_10897_;
v___x_10897_ = lean_uint8_dec_eq(v_modelCompatible_10864_, v___x_10872_);
if (v___x_10897_ == 0)
{
uint8_t v___x_10898_;
v___x_10898_ = lean_uint8_dec_eq(v_hasExplicitCyber_10862_, v___x_10872_);
if (v___x_10898_ == 0)
{
v___y_10882_ = v___y_10894_;
v___y_10883_ = v___y_10892_;
v___y_10884_ = v___y_10893_;
v___y_10885_ = v___x_10895_;
goto v___jp_10881_;
}
else
{
v___y_10882_ = v___y_10894_;
v___y_10883_ = v___y_10892_;
v___y_10884_ = v___y_10893_;
v___y_10885_ = v___x_10897_;
goto v___jp_10881_;
}
}
else
{
uint32_t v___x_10899_;
v___x_10899_ = 2;
return v___x_10899_;
}
}
}
v___jp_10900_:
{
uint32_t v___x_10903_;
v___x_10903_ = 512;
v___y_10892_ = v___y_10901_;
v___y_10893_ = v___y_10902_;
v___y_10894_ = v___x_10903_;
goto v___jp_10891_;
}
}
}

LEAN_EXPORT uint8_t orb_codex_goal_preact_filter(uint8_t v_msgKind_10929_, uint8_t v_isRequest_10930_, uint8_t v_sameThread_10931_, uint8_t v_hasTurnId_10932_, uint8_t v_threadAlreadyActive_10933_, uint8_t v_goalGetWasNull_10934_, uint8_t v_snapshotMatchesGoalGet_10935_){
_start:
{
uint8_t v___x_10936_; uint8_t v___y_10938_; uint8_t v___x_10942_;
v___x_10936_ = 0;
v___x_10942_ = lean_uint8_dec_eq(v_isRequest_10930_, v___x_10936_);
if (v___x_10942_ == 0)
{
return v___x_10936_;
}
else
{
uint8_t v___x_10943_;
v___x_10943_ = lean_uint8_dec_eq(v_sameThread_10931_, v___x_10936_);
if (v___x_10943_ == 0)
{
uint8_t v___x_10944_;
v___x_10944_ = lean_uint8_dec_eq(v_hasTurnId_10932_, v___x_10936_);
if (v___x_10944_ == 0)
{
return v___x_10936_;
}
else
{
uint8_t v___x_10945_;
v___x_10945_ = lean_uint8_dec_eq(v_threadAlreadyActive_10933_, v___x_10936_);
if (v___x_10945_ == 0)
{
return v___x_10936_;
}
else
{
uint8_t v___x_10946_; uint8_t v___x_10947_;
v___x_10946_ = 2;
v___x_10947_ = lean_uint8_dec_eq(v_msgKind_10929_, v___x_10946_);
if (v___x_10947_ == 0)
{
v___y_10938_ = v___x_10943_;
goto v___jp_10937_;
}
else
{
uint8_t v___x_10948_;
v___x_10948_ = lean_uint8_dec_eq(v_goalGetWasNull_10934_, v___x_10936_);
if (v___x_10948_ == 0)
{
uint8_t v___x_10949_;
v___x_10949_ = 1;
return v___x_10949_;
}
else
{
v___y_10938_ = v___x_10943_;
goto v___jp_10937_;
}
}
}
}
}
else
{
return v___x_10936_;
}
}
v___jp_10937_:
{
uint8_t v___x_10939_; uint8_t v___x_10940_;
v___x_10939_ = 1;
v___x_10940_ = lean_uint8_dec_eq(v_msgKind_10929_, v___x_10939_);
if (v___x_10940_ == 0)
{
return v___x_10936_;
}
else
{
uint8_t v___x_10941_;
v___x_10941_ = lean_uint8_dec_eq(v_snapshotMatchesGoalGet_10935_, v___x_10936_);
if (v___x_10941_ == 0)
{
return v___x_10939_;
}
else
{
if (v___y_10938_ == 0)
{
return v___x_10936_;
}
else
{
return v___x_10939_;
}
}
}
}
}
}

LEAN_EXPORT uint64_t orb_skill_slash_step(uint8_t v_harnessKind_10966_, uint8_t v_isDelivered_10967_, uint8_t v_alreadySelected_10968_, uint8_t v_nameCharsValid_10969_, uint32_t v_nameLen_10970_, uint32_t v_maxNameLen_10971_, uint32_t v_selectedCount_10972_, uint32_t v_maxSelected_10973_){
_start:
{
uint32_t v___y_10987_; uint32_t v___x_11001_; uint8_t v___x_11002_;
v___x_11001_ = 0;
v___x_11002_ = lean_uint32_dec_eq(v_nameLen_10970_, v___x_11001_);
if (v___x_11002_ == 0)
{
uint8_t v___x_11003_;
v___x_11003_ = lean_uint32_dec_eq(v_maxNameLen_10971_, v___x_11001_);
if (v___x_11003_ == 0)
{
uint8_t v___x_11004_;
v___x_11004_ = lean_uint32_dec_lt(v_maxNameLen_10971_, v_nameLen_10970_);
if (v___x_11004_ == 0)
{
uint8_t v___x_11005_; uint8_t v___x_11006_;
v___x_11005_ = 0;
v___x_11006_ = lean_uint8_dec_eq(v_nameCharsValid_10969_, v___x_11005_);
if (v___x_11006_ == 0)
{
uint8_t v___x_11007_;
v___x_11007_ = lean_uint8_dec_eq(v_isDelivered_10967_, v___x_11005_);
if (v___x_11007_ == 0)
{
uint8_t v___x_11008_;
v___x_11008_ = lean_uint8_dec_eq(v_alreadySelected_10968_, v___x_11005_);
if (v___x_11008_ == 0)
{
uint64_t v___x_11009_; uint64_t v___x_11010_; uint64_t v___x_11011_; uint64_t v___x_11012_; uint64_t v___x_11013_;
v___x_11009_ = 4ULL;
v___x_11010_ = lean_uint32_to_uint64(v_selectedCount_10972_);
v___x_11011_ = 32ULL;
v___x_11012_ = lean_uint64_shift_left(v___x_11010_, v___x_11011_);
v___x_11013_ = lean_uint64_lor(v___x_11009_, v___x_11012_);
return v___x_11013_;
}
else
{
uint8_t v___x_11014_;
v___x_11014_ = lean_uint32_dec_eq(v_maxSelected_10973_, v___x_11001_);
if (v___x_11014_ == 0)
{
uint8_t v___x_11015_;
v___x_11015_ = lean_uint32_dec_le(v_maxSelected_10973_, v_selectedCount_10972_);
if (v___x_11015_ == 0)
{
uint8_t v___x_11016_; uint8_t v___x_11017_;
v___x_11016_ = 1;
v___x_11017_ = lean_uint8_dec_eq(v_harnessKind_10966_, v___x_11016_);
if (v___x_11017_ == 0)
{
uint8_t v___x_11018_; uint8_t v___x_11019_;
v___x_11018_ = 2;
v___x_11019_ = lean_uint8_dec_eq(v_harnessKind_10966_, v___x_11018_);
if (v___x_11019_ == 0)
{
uint32_t v___x_11020_;
v___x_11020_ = 2;
v___y_10987_ = v___x_11020_;
goto v___jp_10986_;
}
else
{
goto v___jp_10999_;
}
}
else
{
goto v___jp_10999_;
}
}
else
{
goto v___jp_10980_;
}
}
else
{
goto v___jp_10980_;
}
}
}
else
{
uint64_t v___x_11021_; uint64_t v___x_11022_; uint64_t v___x_11023_; uint64_t v___x_11024_; uint64_t v___x_11025_;
v___x_11021_ = 3ULL;
v___x_11022_ = lean_uint32_to_uint64(v_selectedCount_10972_);
v___x_11023_ = 32ULL;
v___x_11024_ = lean_uint64_shift_left(v___x_11022_, v___x_11023_);
v___x_11025_ = lean_uint64_lor(v___x_11021_, v___x_11024_);
return v___x_11025_;
}
}
else
{
uint64_t v___x_11026_; uint64_t v___x_11027_; uint64_t v___x_11028_; uint64_t v___x_11029_; uint64_t v___x_11030_;
v___x_11026_ = 2ULL;
v___x_11027_ = lean_uint32_to_uint64(v_selectedCount_10972_);
v___x_11028_ = 32ULL;
v___x_11029_ = lean_uint64_shift_left(v___x_11027_, v___x_11028_);
v___x_11030_ = lean_uint64_lor(v___x_11026_, v___x_11029_);
return v___x_11030_;
}
}
else
{
goto v___jp_10974_;
}
}
else
{
goto v___jp_10974_;
}
}
else
{
goto v___jp_10974_;
}
v___jp_10974_:
{
uint64_t v___x_10975_; uint64_t v___x_10976_; uint64_t v___x_10977_; uint64_t v___x_10978_; uint64_t v___x_10979_;
v___x_10975_ = 1ULL;
v___x_10976_ = lean_uint32_to_uint64(v_selectedCount_10972_);
v___x_10977_ = 32ULL;
v___x_10978_ = lean_uint64_shift_left(v___x_10976_, v___x_10977_);
v___x_10979_ = lean_uint64_lor(v___x_10975_, v___x_10978_);
return v___x_10979_;
}
v___jp_10980_:
{
uint64_t v___x_10981_; uint64_t v___x_10982_; uint64_t v___x_10983_; uint64_t v___x_10984_; uint64_t v___x_10985_;
v___x_10981_ = 5ULL;
v___x_10982_ = lean_uint32_to_uint64(v_selectedCount_10972_);
v___x_10983_ = 32ULL;
v___x_10984_ = lean_uint64_shift_left(v___x_10982_, v___x_10983_);
v___x_10985_ = lean_uint64_lor(v___x_10981_, v___x_10984_);
return v___x_10985_;
}
v___jp_10986_:
{
uint32_t v___x_10988_; uint32_t v_nextCount_10989_; uint32_t v___x_10990_; uint32_t v___x_10991_; uint32_t v___x_10992_; uint32_t v_lo32_10993_; uint64_t v___x_10994_; uint64_t v___x_10995_; uint64_t v___x_10996_; uint64_t v___x_10997_; uint64_t v___x_10998_;
v___x_10988_ = 1;
v_nextCount_10989_ = lean_uint32_add(v_selectedCount_10972_, v___x_10988_);
v___x_10990_ = 256;
v___x_10991_ = 16;
v___x_10992_ = lean_uint32_shift_left(v___y_10987_, v___x_10991_);
v_lo32_10993_ = lean_uint32_lor(v___x_10990_, v___x_10992_);
v___x_10994_ = lean_uint32_to_uint64(v_lo32_10993_);
v___x_10995_ = lean_uint32_to_uint64(v_nextCount_10989_);
v___x_10996_ = 32ULL;
v___x_10997_ = lean_uint64_shift_left(v___x_10995_, v___x_10996_);
v___x_10998_ = lean_uint64_lor(v___x_10994_, v___x_10997_);
return v___x_10998_;
}
v___jp_10999_:
{
uint32_t v___x_11000_;
v___x_11000_ = 1;
v___y_10987_ = v___x_11000_;
goto v___jp_10986_;
}
}
}

LEAN_EXPORT uint32_t orb_worktree_decision_step(uint8_t v_opKind_11049_, uint8_t v_isOccupied_11050_, uint8_t v_isGitRepo_11051_, uint8_t v_branchCharsValid_11052_, uint8_t v_targetPathExists_11053_, uint8_t v_parentDirValid_11054_, uint32_t v_slugLen_11055_, uint32_t v_maxSlugLen_11056_, uint32_t v_activeWorktrees_11057_, uint32_t v_maxWorktrees_11058_){
_start:
{
uint8_t v___x_11059_; uint8_t v___x_11060_;
v___x_11059_ = 0;
v___x_11060_ = lean_uint8_dec_eq(v_opKind_11049_, v___x_11059_);
if (v___x_11060_ == 0)
{
uint8_t v___x_11061_; uint8_t v___x_11062_;
v___x_11061_ = 1;
v___x_11062_ = lean_uint8_dec_eq(v_opKind_11049_, v___x_11061_);
if (v___x_11062_ == 0)
{
uint32_t v___x_11063_;
v___x_11063_ = 7;
return v___x_11063_;
}
else
{
uint8_t v___x_11064_;
v___x_11064_ = lean_uint8_dec_eq(v_isGitRepo_11051_, v___x_11059_);
if (v___x_11064_ == 0)
{
uint8_t v___x_11065_;
v___x_11065_ = lean_uint8_dec_eq(v_parentDirValid_11054_, v___x_11059_);
if (v___x_11065_ == 0)
{
uint8_t v___x_11066_;
v___x_11066_ = lean_uint8_dec_eq(v_branchCharsValid_11052_, v___x_11059_);
if (v___x_11066_ == 0)
{
uint32_t v___x_11067_; uint8_t v___x_11068_;
v___x_11067_ = 0;
v___x_11068_ = lean_uint32_dec_eq(v_slugLen_11055_, v___x_11067_);
if (v___x_11068_ == 0)
{
uint8_t v___x_11069_;
v___x_11069_ = lean_uint32_dec_eq(v_maxSlugLen_11056_, v___x_11067_);
if (v___x_11069_ == 0)
{
uint8_t v___x_11070_;
v___x_11070_ = lean_uint32_dec_lt(v_maxSlugLen_11056_, v_slugLen_11055_);
if (v___x_11070_ == 0)
{
uint8_t v___x_11071_;
v___x_11071_ = lean_uint8_dec_eq(v_targetPathExists_11053_, v___x_11059_);
if (v___x_11071_ == 0)
{
uint32_t v___x_11072_;
v___x_11072_ = 5;
return v___x_11072_;
}
else
{
uint8_t v___x_11073_;
v___x_11073_ = lean_uint32_dec_eq(v_maxWorktrees_11058_, v___x_11067_);
if (v___x_11073_ == 0)
{
uint8_t v___x_11074_;
v___x_11074_ = lean_uint32_dec_le(v_maxWorktrees_11058_, v_activeWorktrees_11057_);
if (v___x_11074_ == 0)
{
uint32_t v___x_11075_;
v___x_11075_ = 257;
return v___x_11075_;
}
else
{
uint32_t v___x_11076_;
v___x_11076_ = 6;
return v___x_11076_;
}
}
else
{
uint32_t v___x_11077_;
v___x_11077_ = 6;
return v___x_11077_;
}
}
}
else
{
uint32_t v___x_11078_;
v___x_11078_ = 4;
return v___x_11078_;
}
}
else
{
uint32_t v___x_11079_;
v___x_11079_ = 4;
return v___x_11079_;
}
}
else
{
uint32_t v___x_11080_;
v___x_11080_ = 4;
return v___x_11080_;
}
}
else
{
uint32_t v___x_11081_;
v___x_11081_ = 4;
return v___x_11081_;
}
}
else
{
uint32_t v___x_11082_;
v___x_11082_ = 3;
return v___x_11082_;
}
}
else
{
uint32_t v___x_11083_;
v___x_11083_ = 2;
return v___x_11083_;
}
}
}
else
{
uint8_t v___x_11084_;
v___x_11084_ = lean_uint8_dec_eq(v_isOccupied_11050_, v___x_11059_);
if (v___x_11084_ == 0)
{
uint8_t v___x_11085_;
v___x_11085_ = lean_uint8_dec_eq(v_isGitRepo_11051_, v___x_11059_);
if (v___x_11085_ == 0)
{
uint8_t v___x_11086_;
v___x_11086_ = lean_uint8_dec_eq(v_parentDirValid_11054_, v___x_11059_);
if (v___x_11086_ == 0)
{
uint32_t v___x_11087_;
v___x_11087_ = 513;
return v___x_11087_;
}
else
{
uint32_t v___x_11088_;
v___x_11088_ = 1;
return v___x_11088_;
}
}
else
{
uint32_t v___x_11089_;
v___x_11089_ = 1;
return v___x_11089_;
}
}
else
{
uint32_t v___x_11090_;
v___x_11090_ = 256;
return v___x_11090_;
}
}
}
}

LEAN_EXPORT uint64_t orb_repo_diff_budget_step(uint8_t v_isGitRepo_11113_, uint8_t v_pathSafe_11114_, uint8_t v_hasUntracked_11115_, uint32_t v_modifiedCount_11116_, uint32_t v_stagedCount_11117_, uint32_t v_aheadCount_11118_, uint32_t v_behindCount_11119_, uint32_t v_diffBytes_11120_, uint32_t v_maxFiles_11121_, uint32_t v_maxBytes_11122_){
_start:
{
uint32_t v___y_11124_; uint32_t v___y_11125_; uint32_t v___y_11126_; uint32_t v___y_11127_; uint32_t v___y_11128_; uint32_t v___y_11142_; uint32_t v___y_11143_; uint32_t v___y_11144_; uint32_t v___y_11145_; uint8_t v___x_11147_; uint8_t v___x_11148_;
v___x_11147_ = 0;
v___x_11148_ = lean_uint8_dec_eq(v_isGitRepo_11113_, v___x_11147_);
if (v___x_11148_ == 0)
{
uint8_t v___x_11149_;
v___x_11149_ = lean_uint8_dec_eq(v_pathSafe_11114_, v___x_11147_);
if (v___x_11149_ == 0)
{
uint32_t v___x_11150_; uint32_t v___y_11152_; uint8_t v___y_11153_; uint32_t v___y_11154_; uint32_t v___y_11155_; uint32_t v___y_11160_; uint32_t v___y_11161_; uint32_t v___y_11162_; uint32_t v___y_11167_; uint32_t v___y_11168_; uint64_t v___y_11172_; uint32_t v___y_11173_; uint8_t v___x_11177_;
v___x_11150_ = 0;
v___x_11177_ = lean_uint32_dec_eq(v_maxFiles_11121_, v___x_11150_);
if (v___x_11177_ == 0)
{
uint8_t v___x_11178_;
v___x_11178_ = lean_uint32_dec_eq(v_maxBytes_11122_, v___x_11150_);
if (v___x_11178_ == 0)
{
uint64_t v___x_11179_; uint64_t v___x_11180_; uint64_t v___x_11181_; uint64_t v___y_11183_; uint8_t v___x_11188_;
v___x_11179_ = lean_uint32_to_uint64(v_modifiedCount_11116_);
v___x_11180_ = lean_uint32_to_uint64(v_stagedCount_11117_);
v___x_11181_ = lean_uint64_add(v___x_11179_, v___x_11180_);
v___x_11188_ = lean_uint8_dec_eq(v_hasUntracked_11115_, v___x_11147_);
if (v___x_11188_ == 0)
{
uint64_t v___x_11189_;
v___x_11189_ = 1ULL;
v___y_11183_ = v___x_11189_;
goto v___jp_11182_;
}
else
{
uint64_t v___x_11190_;
v___x_11190_ = 0ULL;
v___y_11183_ = v___x_11190_;
goto v___jp_11182_;
}
v___jp_11182_:
{
uint64_t v_totalChanges64_11184_; uint64_t v___x_11185_; uint8_t v___x_11186_;
v_totalChanges64_11184_ = lean_uint64_add(v___x_11181_, v___y_11183_);
v___x_11185_ = 0ULL;
v___x_11186_ = lean_uint64_dec_lt(v___x_11185_, v_totalChanges64_11184_);
if (v___x_11186_ == 0)
{
v___y_11172_ = v_totalChanges64_11184_;
v___y_11173_ = v___x_11150_;
goto v___jp_11171_;
}
else
{
uint32_t v___x_11187_;
v___x_11187_ = 512;
v___y_11172_ = v_totalChanges64_11184_;
v___y_11173_ = v___x_11187_;
goto v___jp_11171_;
}
}
}
else
{
uint64_t v___x_11191_;
v___x_11191_ = 3ULL;
return v___x_11191_;
}
}
else
{
uint64_t v___x_11192_;
v___x_11192_ = 3ULL;
return v___x_11192_;
}
v___jp_11151_:
{
if (v___y_11153_ == 0)
{
uint8_t v___x_11156_;
v___x_11156_ = lean_uint32_dec_lt(v___x_11150_, v_behindCount_11119_);
if (v___x_11156_ == 0)
{
v___y_11142_ = v___y_11152_;
v___y_11143_ = v___y_11154_;
v___y_11144_ = v___y_11155_;
v___y_11145_ = v___x_11150_;
goto v___jp_11141_;
}
else
{
uint32_t v___x_11157_;
v___x_11157_ = 2;
v___y_11142_ = v___y_11152_;
v___y_11143_ = v___y_11154_;
v___y_11144_ = v___y_11155_;
v___y_11145_ = v___x_11157_;
goto v___jp_11141_;
}
}
else
{
uint32_t v___x_11158_;
v___x_11158_ = 1;
v___y_11142_ = v___y_11152_;
v___y_11143_ = v___y_11154_;
v___y_11144_ = v___y_11155_;
v___y_11145_ = v___x_11158_;
goto v___jp_11141_;
}
}
v___jp_11159_:
{
uint8_t v___x_11163_;
v___x_11163_ = lean_uint32_dec_lt(v___x_11150_, v_aheadCount_11118_);
if (v___x_11163_ == 0)
{
v___y_11152_ = v___y_11160_;
v___y_11153_ = v___x_11163_;
v___y_11154_ = v___y_11161_;
v___y_11155_ = v___y_11162_;
goto v___jp_11151_;
}
else
{
uint8_t v___x_11164_;
v___x_11164_ = lean_uint32_dec_lt(v___x_11150_, v_behindCount_11119_);
if (v___x_11164_ == 0)
{
v___y_11152_ = v___y_11160_;
v___y_11153_ = v___x_11163_;
v___y_11154_ = v___y_11161_;
v___y_11155_ = v___y_11162_;
goto v___jp_11151_;
}
else
{
uint32_t v___x_11165_;
v___x_11165_ = 3;
v___y_11142_ = v___y_11160_;
v___y_11143_ = v___y_11161_;
v___y_11144_ = v___y_11162_;
v___y_11145_ = v___x_11165_;
goto v___jp_11141_;
}
}
}
v___jp_11166_:
{
uint8_t v___x_11169_;
v___x_11169_ = lean_uint32_dec_lt(v_maxBytes_11122_, v_diffBytes_11120_);
if (v___x_11169_ == 0)
{
v___y_11160_ = v___y_11167_;
v___y_11161_ = v___y_11168_;
v___y_11162_ = v___x_11150_;
goto v___jp_11159_;
}
else
{
uint32_t v___x_11170_;
v___x_11170_ = 2048;
v___y_11160_ = v___y_11167_;
v___y_11161_ = v___y_11168_;
v___y_11162_ = v___x_11170_;
goto v___jp_11159_;
}
}
v___jp_11171_:
{
uint64_t v___x_11174_; uint8_t v___x_11175_;
v___x_11174_ = lean_uint32_to_uint64(v_maxFiles_11121_);
v___x_11175_ = lean_uint64_dec_lt(v___x_11174_, v___y_11172_);
if (v___x_11175_ == 0)
{
v___y_11167_ = v___y_11173_;
v___y_11168_ = v___x_11150_;
goto v___jp_11166_;
}
else
{
uint32_t v___x_11176_;
v___x_11176_ = 1024;
v___y_11167_ = v___y_11173_;
v___y_11168_ = v___x_11176_;
goto v___jp_11166_;
}
}
}
else
{
uint64_t v___x_11193_;
v___x_11193_ = 2ULL;
return v___x_11193_;
}
}
else
{
uint64_t v___x_11194_;
v___x_11194_ = 1ULL;
return v___x_11194_;
}
v___jp_11123_:
{
uint32_t v___x_11129_; uint32_t v___x_11130_; uint32_t v___x_11131_; uint32_t v___x_11132_; uint32_t v___x_11133_; uint32_t v___x_11134_; uint32_t v_lo32_11135_; uint64_t v___x_11136_; uint64_t v___x_11137_; uint64_t v___x_11138_; uint64_t v___x_11139_; uint64_t v___x_11140_;
v___x_11129_ = 256;
v___x_11130_ = lean_uint32_lor(v___x_11129_, v___y_11124_);
v___x_11131_ = lean_uint32_lor(v___x_11130_, v___y_11125_);
v___x_11132_ = lean_uint32_lor(v___x_11131_, v___y_11126_);
v___x_11133_ = 16;
v___x_11134_ = lean_uint32_shift_left(v___y_11127_, v___x_11133_);
v_lo32_11135_ = lean_uint32_lor(v___x_11132_, v___x_11134_);
v___x_11136_ = lean_uint32_to_uint64(v_lo32_11135_);
v___x_11137_ = lean_uint32_to_uint64(v___y_11128_);
v___x_11138_ = 32ULL;
v___x_11139_ = lean_uint64_shift_left(v___x_11137_, v___x_11138_);
v___x_11140_ = lean_uint64_lor(v___x_11136_, v___x_11139_);
return v___x_11140_;
}
v___jp_11141_:
{
uint8_t v___x_11146_;
v___x_11146_ = lean_uint32_dec_le(v_diffBytes_11120_, v_maxBytes_11122_);
if (v___x_11146_ == 0)
{
v___y_11124_ = v___y_11142_;
v___y_11125_ = v___y_11143_;
v___y_11126_ = v___y_11144_;
v___y_11127_ = v___y_11145_;
v___y_11128_ = v_maxBytes_11122_;
goto v___jp_11123_;
}
else
{
v___y_11124_ = v___y_11142_;
v___y_11125_ = v___y_11143_;
v___y_11126_ = v___y_11144_;
v___y_11127_ = v___y_11145_;
v___y_11128_ = v_diffBytes_11120_;
goto v___jp_11123_;
}
}
}
}

LEAN_EXPORT uint8_t orb_sidebar_move_target_admit(uint8_t v_itemKind_11217_, uint8_t v_dstIsSelfOrSubtree_11218_, uint32_t v_srcProjectOrd_11219_, uint32_t v_srcPathOrd_11220_, uint32_t v_srcParentOrd_11221_, uint32_t v_dstProjectOrd_11222_, uint32_t v_dstPathOrd_11223_){
_start:
{
uint8_t v___y_11225_; uint8_t v___y_11226_; uint8_t v___y_11227_; uint8_t v___y_11228_; uint8_t v___y_11233_; uint8_t v___y_11234_; uint8_t v___y_11235_; uint32_t v___y_11236_; uint8_t v___y_11240_; uint8_t v___y_11241_; uint8_t v___y_11242_; uint8_t v___y_11243_; uint8_t v___y_11247_; uint8_t v___x_11251_; uint8_t v___x_11252_;
v___x_11251_ = 3;
v___x_11252_ = lean_uint8_dec_le(v_itemKind_11217_, v___x_11251_);
if (v___x_11252_ == 0)
{
v___y_11247_ = v___x_11252_;
goto v___jp_11246_;
}
else
{
uint32_t v___x_11253_; uint8_t v___x_11254_;
v___x_11253_ = 0;
v___x_11254_ = lean_uint32_dec_eq(v_srcProjectOrd_11219_, v___x_11253_);
if (v___x_11254_ == 0)
{
uint8_t v___x_11255_;
v___x_11255_ = lean_uint32_dec_eq(v_dstProjectOrd_11222_, v___x_11253_);
if (v___x_11255_ == 0)
{
v___y_11247_ = v___x_11252_;
goto v___jp_11246_;
}
else
{
v___y_11247_ = v___x_11254_;
goto v___jp_11246_;
}
}
else
{
uint8_t v___x_11256_;
v___x_11256_ = 0;
v___y_11247_ = v___x_11256_;
goto v___jp_11246_;
}
}
v___jp_11224_:
{
if (v___y_11226_ == 0)
{
uint8_t v___x_11229_;
v___x_11229_ = 0;
return v___x_11229_;
}
else
{
if (v___y_11227_ == 0)
{
if (v___y_11228_ == 0)
{
return v___y_11225_;
}
else
{
uint8_t v___x_11230_;
v___x_11230_ = 0;
return v___x_11230_;
}
}
else
{
uint8_t v___x_11231_;
v___x_11231_ = 0;
return v___x_11231_;
}
}
}
v___jp_11232_:
{
uint8_t v___x_11237_;
v___x_11237_ = lean_uint32_dec_eq(v_srcProjectOrd_11219_, v_dstProjectOrd_11222_);
if (v___x_11237_ == 0)
{
v___y_11225_ = v___y_11233_;
v___y_11226_ = v___y_11234_;
v___y_11227_ = v___y_11235_;
v___y_11228_ = v___x_11237_;
goto v___jp_11224_;
}
else
{
uint8_t v___x_11238_;
v___x_11238_ = lean_uint32_dec_eq(v___y_11236_, v_dstPathOrd_11223_);
v___y_11225_ = v___y_11233_;
v___y_11226_ = v___y_11234_;
v___y_11227_ = v___y_11235_;
v___y_11228_ = v___x_11238_;
goto v___jp_11224_;
}
}
v___jp_11239_:
{
if (v___y_11242_ == 0)
{
uint8_t v___x_11244_; uint8_t v___x_11245_;
v___x_11244_ = 2;
v___x_11245_ = lean_uint8_dec_eq(v_itemKind_11217_, v___x_11244_);
if (v___x_11245_ == 0)
{
v___y_11233_ = v___y_11240_;
v___y_11234_ = v___y_11241_;
v___y_11235_ = v___y_11243_;
v___y_11236_ = v_srcPathOrd_11220_;
goto v___jp_11232_;
}
else
{
v___y_11233_ = v___y_11240_;
v___y_11234_ = v___y_11241_;
v___y_11235_ = v___y_11243_;
v___y_11236_ = v_srcParentOrd_11221_;
goto v___jp_11232_;
}
}
else
{
v___y_11233_ = v___y_11240_;
v___y_11234_ = v___y_11241_;
v___y_11235_ = v___y_11243_;
v___y_11236_ = v_srcParentOrd_11221_;
goto v___jp_11232_;
}
}
v___jp_11246_:
{
uint8_t v___x_11248_; uint8_t v___x_11249_;
v___x_11248_ = 1;
v___x_11249_ = lean_uint8_dec_eq(v_itemKind_11217_, v___x_11248_);
if (v___x_11249_ == 0)
{
v___y_11240_ = v___x_11248_;
v___y_11241_ = v___y_11247_;
v___y_11242_ = v___x_11249_;
v___y_11243_ = v___x_11249_;
goto v___jp_11239_;
}
else
{
uint8_t v___x_11250_;
v___x_11250_ = lean_uint8_dec_eq(v_dstIsSelfOrSubtree_11218_, v___x_11248_);
v___y_11240_ = v___x_11248_;
v___y_11241_ = v___y_11247_;
v___y_11242_ = v___x_11249_;
v___y_11243_ = v___x_11250_;
goto v___jp_11239_;
}
}
}
}

LEAN_EXPORT uint64_t orb_sidebar_drag_step(uint8_t v_phase_11357_, uint8_t v_eventKind_11358_, uint8_t v_rowMovable_11359_, uint8_t v_targetCollapsed_11360_, uint8_t v_targetAdmitted_11361_, uint32_t v_distSq_11362_, uint32_t v_elapsedMs_11363_, uint32_t v_springElapsedMs_11364_, uint32_t v_hoverTargetOrd_11365_, uint32_t v_springTargetOrd_11366_, uint32_t v_edgeTopDistPx_11367_, uint32_t v_edgeBottomDistPx_11368_){
_start:
{
uint32_t v___y_11370_; uint32_t v___y_11371_; uint32_t v___y_11378_; uint32_t v___y_11381_; uint8_t v___y_11382_; uint32_t v___y_11386_; uint32_t v___y_11389_; uint32_t v___y_11392_; uint8_t v___y_11393_; uint8_t v___x_11395_; uint32_t v___y_11397_; uint8_t v___y_11398_; uint8_t v___y_11399_; uint8_t v___y_11400_; uint32_t v___y_11403_; uint8_t v___y_11404_; uint8_t v___y_11405_; uint32_t v___y_11409_; uint8_t v___y_11437_; uint32_t v___y_11438_; uint8_t v___y_11440_; uint8_t v___y_11441_; uint8_t v___y_11442_; uint32_t v___y_11443_; uint32_t v___y_11444_; uint8_t v___y_11455_; uint8_t v___y_11456_; uint8_t v___y_11457_; uint32_t v___y_11458_; uint32_t v___y_11459_; uint8_t v___y_11475_; uint8_t v___y_11476_; uint8_t v___y_11477_; uint8_t v___y_11478_; uint32_t v___y_11479_; uint32_t v___y_11480_; uint8_t v___y_11481_; uint8_t v___y_11484_; uint8_t v___y_11485_; uint8_t v___y_11486_; uint8_t v___y_11487_; uint32_t v___y_11488_; uint8_t v___y_11505_; uint8_t v___y_11506_; uint8_t v___y_11507_; uint8_t v___y_11508_; uint32_t v___y_11509_; uint8_t v___y_11513_; uint8_t v___y_11514_; uint32_t v___y_11515_; uint8_t v___y_11516_; uint8_t v___y_11517_; uint32_t v___y_11518_; uint8_t v___y_11522_; uint8_t v___y_11523_; uint32_t v___y_11524_; uint8_t v___y_11525_; uint8_t v___y_11526_; uint8_t v___y_11529_; uint8_t v___y_11530_; uint8_t v___y_11531_; uint8_t v___y_11532_; uint32_t v___y_11533_; uint8_t v___y_11534_; uint32_t v___y_11535_; uint8_t v___y_11547_; uint8_t v___y_11548_; uint8_t v___y_11549_; uint8_t v___y_11565_; uint8_t v___y_11566_; uint8_t v___y_11567_; uint8_t v___y_11568_; uint8_t v___y_11569_; uint8_t v___y_11570_; uint8_t v___y_11573_; uint8_t v___y_11574_; uint8_t v___y_11575_; uint8_t v___y_11576_; uint8_t v___y_11577_; uint8_t v___y_11578_; uint8_t v___y_11583_; uint8_t v___y_11584_; uint8_t v___y_11585_; uint8_t v___y_11586_; uint8_t v___y_11587_; uint8_t v___y_11591_; uint8_t v___y_11594_; uint8_t v___y_11597_; uint8_t v___y_11600_; uint8_t v___x_11645_;
v___x_11395_ = 3;
v___x_11645_ = lean_uint8_dec_lt(v___x_11395_, v_phase_11357_);
if (v___x_11645_ == 0)
{
uint8_t v___x_11646_; uint8_t v___x_11647_;
v___x_11646_ = 5;
v___x_11647_ = lean_uint8_dec_lt(v___x_11646_, v_eventKind_11358_);
v___y_11600_ = v___x_11647_;
goto v___jp_11599_;
}
else
{
v___y_11600_ = v___x_11645_;
goto v___jp_11599_;
}
v___jp_11369_:
{
uint64_t v___x_11372_; uint64_t v___x_11373_; uint64_t v___x_11374_; uint64_t v___x_11375_; uint64_t v___x_11376_;
v___x_11372_ = lean_uint32_to_uint64(v___y_11370_);
v___x_11373_ = lean_uint32_to_uint64(v___y_11371_);
v___x_11374_ = 32ULL;
v___x_11375_ = lean_uint64_shift_left(v___x_11373_, v___x_11374_);
v___x_11376_ = lean_uint64_lor(v___x_11372_, v___x_11375_);
return v___x_11376_;
}
v___jp_11377_:
{
uint32_t v___x_11379_;
v___x_11379_ = 0;
v___y_11370_ = v___y_11378_;
v___y_11371_ = v___x_11379_;
goto v___jp_11369_;
}
v___jp_11380_:
{
if (v___y_11382_ == 0)
{
v___y_11378_ = v___y_11381_;
goto v___jp_11377_;
}
else
{
uint32_t v___x_11383_; uint8_t v___x_11384_;
v___x_11383_ = 0;
v___x_11384_ = lean_uint32_dec_eq(v_hoverTargetOrd_11365_, v___x_11383_);
if (v___x_11384_ == 0)
{
v___y_11370_ = v___y_11381_;
v___y_11371_ = v_hoverTargetOrd_11365_;
goto v___jp_11369_;
}
else
{
v___y_11378_ = v___y_11381_;
goto v___jp_11377_;
}
}
}
v___jp_11385_:
{
uint32_t v___x_11387_;
v___x_11387_ = 0;
v___y_11370_ = v___y_11386_;
v___y_11371_ = v___x_11387_;
goto v___jp_11369_;
}
v___jp_11388_:
{
uint32_t v___x_11390_;
v___x_11390_ = 0;
v___y_11370_ = v___y_11389_;
v___y_11371_ = v___x_11390_;
goto v___jp_11369_;
}
v___jp_11391_:
{
uint8_t v___x_11394_;
v___x_11394_ = lean_uint8_dec_eq(v_targetCollapsed_11360_, v___y_11393_);
v___y_11381_ = v___y_11392_;
v___y_11382_ = v___x_11394_;
goto v___jp_11380_;
}
v___jp_11396_:
{
uint8_t v___x_11401_;
v___x_11401_ = lean_uint8_dec_eq(v_phase_11357_, v___x_11395_);
if (v___x_11401_ == 0)
{
if (v___y_11400_ == 0)
{
v___y_11381_ = v___y_11397_;
v___y_11382_ = v___y_11398_;
goto v___jp_11380_;
}
else
{
v___y_11392_ = v___y_11397_;
v___y_11393_ = v___y_11399_;
goto v___jp_11391_;
}
}
else
{
v___y_11392_ = v___y_11397_;
v___y_11393_ = v___y_11399_;
goto v___jp_11391_;
}
}
v___jp_11402_:
{
uint32_t v___x_11406_; uint8_t v___x_11407_;
v___x_11406_ = 36;
v___x_11407_ = lean_uint32_dec_le(v___x_11406_, v_distSq_11362_);
v___y_11397_ = v___y_11403_;
v___y_11398_ = v___y_11404_;
v___y_11399_ = v___y_11405_;
v___y_11400_ = v___x_11407_;
goto v___jp_11396_;
}
v___jp_11408_:
{
uint8_t v___x_11410_; uint8_t v___x_11411_;
v___x_11410_ = 5;
v___x_11411_ = lean_uint8_dec_eq(v_eventKind_11358_, v___x_11410_);
if (v___x_11411_ == 0)
{
uint8_t v___x_11412_; uint8_t v___x_11413_;
v___x_11412_ = 0;
v___x_11413_ = lean_uint8_dec_eq(v_eventKind_11358_, v___x_11412_);
if (v___x_11413_ == 0)
{
uint8_t v___x_11414_;
v___x_11414_ = lean_uint8_dec_eq(v_phase_11357_, v___x_11412_);
if (v___x_11414_ == 0)
{
uint8_t v___x_11415_; uint8_t v___x_11416_;
v___x_11415_ = 1;
v___x_11416_ = lean_uint8_dec_eq(v_eventKind_11358_, v___x_11415_);
if (v___x_11416_ == 0)
{
uint8_t v___x_11417_; uint8_t v___x_11418_;
v___x_11417_ = 2;
v___x_11418_ = lean_uint8_dec_eq(v_eventKind_11358_, v___x_11417_);
if (v___x_11418_ == 0)
{
uint8_t v___x_11419_;
v___x_11419_ = lean_uint8_dec_eq(v_eventKind_11358_, v___x_11395_);
if (v___x_11419_ == 0)
{
uint32_t v___x_11420_;
v___x_11420_ = 0;
v___y_11370_ = v___y_11409_;
v___y_11371_ = v___x_11420_;
goto v___jp_11369_;
}
else
{
uint8_t v___x_11421_;
v___x_11421_ = lean_uint8_dec_eq(v_phase_11357_, v___x_11395_);
if (v___x_11421_ == 0)
{
v___y_11386_ = v___y_11409_;
goto v___jp_11385_;
}
else
{
uint8_t v___x_11422_;
v___x_11422_ = lean_uint8_dec_eq(v_targetCollapsed_11360_, v___x_11415_);
if (v___x_11422_ == 0)
{
v___y_11386_ = v___y_11409_;
goto v___jp_11385_;
}
else
{
uint32_t v___x_11423_; uint8_t v___x_11424_;
v___x_11423_ = 0;
v___x_11424_ = lean_uint32_dec_eq(v_hoverTargetOrd_11365_, v___x_11423_);
if (v___x_11424_ == 0)
{
uint8_t v___x_11425_;
v___x_11425_ = lean_uint32_dec_eq(v_hoverTargetOrd_11365_, v_springTargetOrd_11366_);
if (v___x_11425_ == 0)
{
v___y_11386_ = v___y_11409_;
goto v___jp_11385_;
}
else
{
uint32_t v___x_11426_; uint8_t v___x_11427_;
v___x_11426_ = 450;
v___x_11427_ = lean_uint32_dec_le(v___x_11426_, v_springElapsedMs_11364_);
if (v___x_11427_ == 0)
{
v___y_11370_ = v___y_11409_;
v___y_11371_ = v_springTargetOrd_11366_;
goto v___jp_11369_;
}
else
{
v___y_11386_ = v___y_11409_;
goto v___jp_11385_;
}
}
}
else
{
v___y_11386_ = v___y_11409_;
goto v___jp_11385_;
}
}
}
}
}
else
{
uint8_t v___x_11428_;
v___x_11428_ = lean_uint8_dec_eq(v_phase_11357_, v___x_11415_);
if (v___x_11428_ == 0)
{
uint8_t v___x_11429_;
v___x_11429_ = lean_uint8_dec_eq(v_phase_11357_, v___x_11417_);
if (v___x_11429_ == 0)
{
v___y_11397_ = v___y_11409_;
v___y_11398_ = v___x_11416_;
v___y_11399_ = v___x_11415_;
v___y_11400_ = v___x_11416_;
goto v___jp_11396_;
}
else
{
v___y_11403_ = v___y_11409_;
v___y_11404_ = v___x_11416_;
v___y_11405_ = v___x_11415_;
goto v___jp_11402_;
}
}
else
{
v___y_11403_ = v___y_11409_;
v___y_11404_ = v___x_11416_;
v___y_11405_ = v___x_11415_;
goto v___jp_11402_;
}
}
}
else
{
uint8_t v___x_11430_;
v___x_11430_ = lean_uint8_dec_eq(v_phase_11357_, v___x_11415_);
if (v___x_11430_ == 0)
{
v___y_11370_ = v___y_11409_;
v___y_11371_ = v_springTargetOrd_11366_;
goto v___jp_11369_;
}
else
{
uint32_t v___x_11431_; uint8_t v___x_11432_;
v___x_11431_ = 260;
v___x_11432_ = lean_uint32_dec_le(v___x_11431_, v_elapsedMs_11363_);
if (v___x_11432_ == 0)
{
v___y_11370_ = v___y_11409_;
v___y_11371_ = v_springTargetOrd_11366_;
goto v___jp_11369_;
}
else
{
uint32_t v___x_11433_; uint8_t v___x_11434_;
v___x_11433_ = 36;
v___x_11434_ = lean_uint32_dec_lt(v_distSq_11362_, v___x_11433_);
if (v___x_11434_ == 0)
{
v___y_11370_ = v___y_11409_;
v___y_11371_ = v_springTargetOrd_11366_;
goto v___jp_11369_;
}
else
{
uint32_t v___x_11435_;
v___x_11435_ = 0;
v___y_11370_ = v___y_11409_;
v___y_11371_ = v___x_11435_;
goto v___jp_11369_;
}
}
}
}
}
else
{
v___y_11389_ = v___y_11409_;
goto v___jp_11388_;
}
}
else
{
v___y_11389_ = v___y_11409_;
goto v___jp_11388_;
}
}
else
{
v___y_11389_ = v___y_11409_;
goto v___jp_11388_;
}
}
v___jp_11436_:
{
if (v___y_11437_ == 0)
{
v___y_11409_ = v___y_11438_;
goto v___jp_11408_;
}
else
{
v___y_11389_ = v___y_11438_;
goto v___jp_11388_;
}
}
v___jp_11439_:
{
uint32_t v___x_11445_; uint32_t v___x_11446_; uint32_t v___x_11447_; uint32_t v___x_11448_; uint32_t v___x_11449_; uint32_t v___x_11450_; uint32_t v___x_11451_; uint32_t v___x_11452_; uint32_t v___x_11453_;
v___x_11445_ = lean_uint8_to_uint32(v___y_11441_);
v___x_11446_ = lean_uint8_to_uint32(v___y_11440_);
v___x_11447_ = 8;
v___x_11448_ = lean_uint32_shift_left(v___x_11446_, v___x_11447_);
v___x_11449_ = lean_uint32_lor(v___x_11445_, v___x_11448_);
v___x_11450_ = lean_uint32_lor(v___x_11449_, v___y_11444_);
v___x_11451_ = 24;
v___x_11452_ = lean_uint32_shift_left(v___y_11443_, v___x_11451_);
v___x_11453_ = lean_uint32_lor(v___x_11450_, v___x_11452_);
v___y_11437_ = v___y_11442_;
v___y_11438_ = v___x_11453_;
goto v___jp_11436_;
}
v___jp_11454_:
{
uint8_t v___x_11460_;
v___x_11460_ = lean_uint32_dec_lt(v_edgeBottomDistPx_11368_, v___y_11459_);
if (v___x_11460_ == 0)
{
uint32_t v___x_11461_;
v___x_11461_ = 0;
v___y_11440_ = v___y_11455_;
v___y_11441_ = v___y_11456_;
v___y_11442_ = v___y_11457_;
v___y_11443_ = v___y_11458_;
v___y_11444_ = v___x_11461_;
goto v___jp_11439_;
}
else
{
uint32_t v___x_11462_; uint32_t v___x_11463_; uint64_t v___x_11464_; uint64_t v___x_11465_; uint64_t v___x_11466_; uint64_t v___x_11467_; uint64_t v___x_11468_; uint64_t v___x_11469_; uint64_t v___x_11470_; uint32_t v___x_11471_; uint8_t v___x_11472_;
v___x_11462_ = 0;
v___x_11463_ = lean_uint32_sub(v___y_11459_, v_edgeBottomDistPx_11368_);
v___x_11464_ = lean_uint32_to_uint64(v___x_11463_);
v___x_11465_ = 10ULL;
v___x_11466_ = lean_uint64_mul(v___x_11464_, v___x_11465_);
v___x_11467_ = 35ULL;
v___x_11468_ = lean_uint64_add(v___x_11466_, v___x_11467_);
v___x_11469_ = 36ULL;
v___x_11470_ = lean_uint64_div(v___x_11468_, v___x_11469_);
v___x_11471_ = lean_uint64_to_uint32(v___x_11470_);
v___x_11472_ = lean_uint32_dec_lt(v___x_11462_, v___x_11471_);
if (v___x_11472_ == 0)
{
v___y_11440_ = v___y_11455_;
v___y_11441_ = v___y_11456_;
v___y_11442_ = v___y_11457_;
v___y_11443_ = v___y_11458_;
v___y_11444_ = v___x_11462_;
goto v___jp_11439_;
}
else
{
uint32_t v___x_11473_;
v___x_11473_ = 262144;
v___y_11440_ = v___y_11455_;
v___y_11441_ = v___y_11456_;
v___y_11442_ = v___y_11457_;
v___y_11443_ = v___y_11458_;
v___y_11444_ = v___x_11473_;
goto v___jp_11439_;
}
}
}
v___jp_11474_:
{
if (v___y_11476_ == 0)
{
v___y_11455_ = v___y_11475_;
v___y_11456_ = v___y_11477_;
v___y_11457_ = v___y_11478_;
v___y_11458_ = v___y_11479_;
v___y_11459_ = v___y_11480_;
goto v___jp_11454_;
}
else
{
if (v___y_11481_ == 0)
{
uint32_t v___x_11482_;
v___x_11482_ = 0;
v___y_11440_ = v___y_11475_;
v___y_11441_ = v___y_11477_;
v___y_11442_ = v___y_11478_;
v___y_11443_ = v___y_11479_;
v___y_11444_ = v___x_11482_;
goto v___jp_11439_;
}
else
{
v___y_11455_ = v___y_11475_;
v___y_11456_ = v___y_11477_;
v___y_11457_ = v___y_11478_;
v___y_11458_ = v___y_11479_;
v___y_11459_ = v___y_11480_;
goto v___jp_11454_;
}
}
}
v___jp_11483_:
{
if (v___y_11487_ == 0)
{
uint32_t v___x_11489_;
v___x_11489_ = 0;
v___y_11440_ = v___y_11484_;
v___y_11441_ = v___y_11485_;
v___y_11442_ = v___y_11486_;
v___y_11443_ = v___y_11488_;
v___y_11444_ = v___x_11489_;
goto v___jp_11439_;
}
else
{
uint32_t v___x_11490_; uint8_t v___x_11491_;
v___x_11490_ = 36;
v___x_11491_ = lean_uint32_dec_lt(v_edgeTopDistPx_11367_, v___x_11490_);
if (v___x_11491_ == 0)
{
v___y_11475_ = v___y_11484_;
v___y_11476_ = v___x_11491_;
v___y_11477_ = v___y_11485_;
v___y_11478_ = v___y_11486_;
v___y_11479_ = v___y_11488_;
v___y_11480_ = v___x_11490_;
v___y_11481_ = v___x_11491_;
goto v___jp_11474_;
}
else
{
uint32_t v___x_11492_; uint32_t v___x_11493_; uint64_t v___x_11494_; uint64_t v___x_11495_; uint64_t v___x_11496_; uint64_t v___x_11497_; uint64_t v___x_11498_; uint64_t v___x_11499_; uint64_t v___x_11500_; uint32_t v___x_11501_; uint8_t v___x_11502_;
v___x_11492_ = 0;
v___x_11493_ = lean_uint32_sub(v___x_11490_, v_edgeTopDistPx_11367_);
v___x_11494_ = lean_uint32_to_uint64(v___x_11493_);
v___x_11495_ = 10ULL;
v___x_11496_ = lean_uint64_mul(v___x_11494_, v___x_11495_);
v___x_11497_ = 35ULL;
v___x_11498_ = lean_uint64_add(v___x_11496_, v___x_11497_);
v___x_11499_ = 36ULL;
v___x_11500_ = lean_uint64_div(v___x_11498_, v___x_11499_);
v___x_11501_ = lean_uint64_to_uint32(v___x_11500_);
v___x_11502_ = lean_uint32_dec_lt(v___x_11492_, v___x_11501_);
if (v___x_11502_ == 0)
{
v___y_11475_ = v___y_11484_;
v___y_11476_ = v___x_11491_;
v___y_11477_ = v___y_11485_;
v___y_11478_ = v___y_11486_;
v___y_11479_ = v___y_11488_;
v___y_11480_ = v___x_11490_;
v___y_11481_ = v___x_11502_;
goto v___jp_11474_;
}
else
{
uint32_t v___x_11503_;
v___x_11503_ = 131072;
v___y_11440_ = v___y_11484_;
v___y_11441_ = v___y_11485_;
v___y_11442_ = v___y_11486_;
v___y_11443_ = v___y_11488_;
v___y_11444_ = v___x_11503_;
goto v___jp_11439_;
}
}
}
}
v___jp_11504_:
{
uint32_t v___x_11510_; uint8_t v___x_11511_;
v___x_11510_ = 10;
v___x_11511_ = lean_uint32_dec_lt(v___x_11510_, v___y_11509_);
if (v___x_11511_ == 0)
{
v___y_11484_ = v___y_11505_;
v___y_11485_ = v___y_11506_;
v___y_11486_ = v___y_11507_;
v___y_11487_ = v___y_11508_;
v___y_11488_ = v___y_11509_;
goto v___jp_11483_;
}
else
{
v___y_11484_ = v___y_11505_;
v___y_11485_ = v___y_11506_;
v___y_11486_ = v___y_11507_;
v___y_11487_ = v___y_11508_;
v___y_11488_ = v___x_11510_;
goto v___jp_11483_;
}
}
v___jp_11512_:
{
uint32_t v___x_11519_; uint8_t v___x_11520_;
v___x_11519_ = 0;
v___x_11520_ = lean_uint32_dec_lt(v___x_11519_, v___y_11515_);
if (v___x_11520_ == 0)
{
v___y_11505_ = v___y_11513_;
v___y_11506_ = v___y_11514_;
v___y_11507_ = v___y_11516_;
v___y_11508_ = v___y_11517_;
v___y_11509_ = v___y_11518_;
goto v___jp_11504_;
}
else
{
v___y_11505_ = v___y_11513_;
v___y_11506_ = v___y_11514_;
v___y_11507_ = v___y_11516_;
v___y_11508_ = v___y_11517_;
v___y_11509_ = v___y_11515_;
goto v___jp_11504_;
}
}
v___jp_11521_:
{
uint32_t v___x_11527_;
v___x_11527_ = 0;
v___y_11513_ = v___y_11522_;
v___y_11514_ = v___y_11523_;
v___y_11515_ = v___y_11524_;
v___y_11516_ = v___y_11525_;
v___y_11517_ = v___y_11526_;
v___y_11518_ = v___x_11527_;
goto v___jp_11512_;
}
v___jp_11528_:
{
if (v___y_11534_ == 0)
{
uint8_t v___x_11536_;
v___x_11536_ = lean_uint32_dec_lt(v_edgeBottomDistPx_11368_, v___y_11533_);
if (v___x_11536_ == 0)
{
v___y_11522_ = v___y_11529_;
v___y_11523_ = v___y_11530_;
v___y_11524_ = v___y_11535_;
v___y_11525_ = v___y_11531_;
v___y_11526_ = v___y_11532_;
goto v___jp_11521_;
}
else
{
uint32_t v___x_11537_; uint64_t v___x_11538_; uint64_t v___x_11539_; uint64_t v___x_11540_; uint64_t v___x_11541_; uint64_t v___x_11542_; uint64_t v___x_11543_; uint64_t v___x_11544_; uint32_t v___x_11545_;
v___x_11537_ = lean_uint32_sub(v___y_11533_, v_edgeBottomDistPx_11368_);
v___x_11538_ = lean_uint32_to_uint64(v___x_11537_);
v___x_11539_ = 10ULL;
v___x_11540_ = lean_uint64_mul(v___x_11538_, v___x_11539_);
v___x_11541_ = 35ULL;
v___x_11542_ = lean_uint64_add(v___x_11540_, v___x_11541_);
v___x_11543_ = 36ULL;
v___x_11544_ = lean_uint64_div(v___x_11542_, v___x_11543_);
v___x_11545_ = lean_uint64_to_uint32(v___x_11544_);
v___y_11513_ = v___y_11529_;
v___y_11514_ = v___y_11530_;
v___y_11515_ = v___y_11535_;
v___y_11516_ = v___y_11531_;
v___y_11517_ = v___y_11532_;
v___y_11518_ = v___x_11545_;
goto v___jp_11512_;
}
}
else
{
v___y_11522_ = v___y_11529_;
v___y_11523_ = v___y_11530_;
v___y_11524_ = v___y_11535_;
v___y_11525_ = v___y_11531_;
v___y_11526_ = v___y_11532_;
goto v___jp_11521_;
}
}
v___jp_11546_:
{
uint8_t v___x_11550_;
v___x_11550_ = lean_uint8_dec_eq(v___y_11547_, v___x_11395_);
if (v___x_11550_ == 0)
{
uint32_t v___x_11551_;
v___x_11551_ = 0;
v___y_11484_ = v___y_11549_;
v___y_11485_ = v___y_11547_;
v___y_11486_ = v___y_11548_;
v___y_11487_ = v___x_11550_;
v___y_11488_ = v___x_11551_;
goto v___jp_11483_;
}
else
{
uint32_t v___x_11552_; uint8_t v___x_11553_;
v___x_11552_ = 36;
v___x_11553_ = lean_uint32_dec_lt(v_edgeTopDistPx_11367_, v___x_11552_);
if (v___x_11553_ == 0)
{
uint32_t v___x_11554_;
v___x_11554_ = 0;
v___y_11529_ = v___y_11549_;
v___y_11530_ = v___y_11547_;
v___y_11531_ = v___y_11548_;
v___y_11532_ = v___x_11550_;
v___y_11533_ = v___x_11552_;
v___y_11534_ = v___x_11553_;
v___y_11535_ = v___x_11554_;
goto v___jp_11528_;
}
else
{
uint32_t v___x_11555_; uint64_t v___x_11556_; uint64_t v___x_11557_; uint64_t v___x_11558_; uint64_t v___x_11559_; uint64_t v___x_11560_; uint64_t v___x_11561_; uint64_t v___x_11562_; uint32_t v___x_11563_;
v___x_11555_ = lean_uint32_sub(v___x_11552_, v_edgeTopDistPx_11367_);
v___x_11556_ = lean_uint32_to_uint64(v___x_11555_);
v___x_11557_ = 10ULL;
v___x_11558_ = lean_uint64_mul(v___x_11556_, v___x_11557_);
v___x_11559_ = 35ULL;
v___x_11560_ = lean_uint64_add(v___x_11558_, v___x_11559_);
v___x_11561_ = 36ULL;
v___x_11562_ = lean_uint64_div(v___x_11560_, v___x_11561_);
v___x_11563_ = lean_uint64_to_uint32(v___x_11562_);
v___y_11529_ = v___y_11549_;
v___y_11530_ = v___y_11547_;
v___y_11531_ = v___y_11548_;
v___y_11532_ = v___x_11550_;
v___y_11533_ = v___x_11552_;
v___y_11534_ = v___x_11553_;
v___y_11535_ = v___x_11563_;
goto v___jp_11528_;
}
}
}
v___jp_11564_:
{
uint8_t v___x_11571_;
v___x_11571_ = lean_uint8_dec_eq(v_phase_11357_, v___x_11395_);
if (v___x_11571_ == 0)
{
if (v___y_11568_ == 0)
{
if (v___y_11570_ == 0)
{
v___y_11547_ = v___y_11565_;
v___y_11548_ = v___y_11567_;
v___y_11549_ = v___y_11569_;
goto v___jp_11546_;
}
else
{
v___y_11547_ = v___y_11566_;
v___y_11548_ = v___y_11567_;
v___y_11549_ = v___y_11569_;
goto v___jp_11546_;
}
}
else
{
v___y_11547_ = v___x_11395_;
v___y_11548_ = v___y_11567_;
v___y_11549_ = v___y_11566_;
goto v___jp_11546_;
}
}
else
{
if (v___y_11568_ == 0)
{
v___y_11547_ = v___x_11395_;
v___y_11548_ = v___y_11567_;
v___y_11549_ = v___y_11569_;
goto v___jp_11546_;
}
else
{
v___y_11547_ = v___x_11395_;
v___y_11548_ = v___y_11567_;
v___y_11549_ = v___y_11566_;
goto v___jp_11546_;
}
}
}
v___jp_11572_:
{
uint8_t v___x_11579_;
v___x_11579_ = lean_uint8_dec_eq(v_phase_11357_, v___y_11575_);
if (v___x_11579_ == 0)
{
v___y_11565_ = v___y_11574_;
v___y_11566_ = v___y_11575_;
v___y_11567_ = v___y_11576_;
v___y_11568_ = v___y_11578_;
v___y_11569_ = v___y_11577_;
v___y_11570_ = v___y_11573_;
goto v___jp_11564_;
}
else
{
uint32_t v___x_11580_; uint8_t v___x_11581_;
v___x_11580_ = 36;
v___x_11581_ = lean_uint32_dec_lt(v_distSq_11362_, v___x_11580_);
v___y_11565_ = v___y_11574_;
v___y_11566_ = v___y_11575_;
v___y_11567_ = v___y_11576_;
v___y_11568_ = v___y_11578_;
v___y_11569_ = v___y_11577_;
v___y_11570_ = v___x_11581_;
goto v___jp_11564_;
}
}
v___jp_11582_:
{
uint32_t v___x_11588_; uint8_t v___x_11589_;
v___x_11588_ = 36;
v___x_11589_ = lean_uint32_dec_le(v___x_11588_, v_distSq_11362_);
v___y_11573_ = v___y_11583_;
v___y_11574_ = v___y_11584_;
v___y_11575_ = v___y_11585_;
v___y_11576_ = v___y_11586_;
v___y_11577_ = v___y_11587_;
v___y_11578_ = v___x_11589_;
goto v___jp_11572_;
}
v___jp_11590_:
{
uint32_t v___x_11592_;
v___x_11592_ = 67072;
v___y_11437_ = v___y_11591_;
v___y_11438_ = v___x_11592_;
goto v___jp_11436_;
}
v___jp_11593_:
{
uint32_t v___x_11595_;
v___x_11595_ = lean_uint8_to_uint32(v_phase_11357_);
v___y_11437_ = v___y_11594_;
v___y_11438_ = v___x_11595_;
goto v___jp_11436_;
}
v___jp_11596_:
{
uint32_t v___x_11598_;
v___x_11598_ = lean_uint8_to_uint32(v_phase_11357_);
v___y_11437_ = v___y_11597_;
v___y_11438_ = v___x_11598_;
goto v___jp_11436_;
}
v___jp_11599_:
{
if (v___y_11600_ == 0)
{
uint8_t v___x_11601_; uint8_t v___x_11602_;
v___x_11601_ = 5;
v___x_11602_ = lean_uint8_dec_eq(v_eventKind_11358_, v___x_11601_);
if (v___x_11602_ == 0)
{
uint8_t v___x_11603_; uint8_t v___x_11604_;
v___x_11603_ = 0;
v___x_11604_ = lean_uint8_dec_eq(v_eventKind_11358_, v___x_11603_);
if (v___x_11604_ == 0)
{
uint8_t v___x_11605_;
v___x_11605_ = lean_uint8_dec_eq(v_phase_11357_, v___x_11603_);
if (v___x_11605_ == 0)
{
uint8_t v___x_11606_; uint8_t v___x_11607_;
v___x_11606_ = 1;
v___x_11607_ = lean_uint8_dec_eq(v_eventKind_11358_, v___x_11606_);
if (v___x_11607_ == 0)
{
uint8_t v___x_11608_; uint8_t v___x_11609_;
v___x_11608_ = 2;
v___x_11609_ = lean_uint8_dec_eq(v_eventKind_11358_, v___x_11608_);
if (v___x_11609_ == 0)
{
uint8_t v___x_11610_;
v___x_11610_ = lean_uint8_dec_eq(v_eventKind_11358_, v___x_11395_);
if (v___x_11610_ == 0)
{
uint8_t v___x_11611_;
v___x_11611_ = lean_uint8_dec_eq(v_phase_11357_, v___x_11606_);
if (v___x_11611_ == 0)
{
uint8_t v___x_11612_;
v___x_11612_ = lean_uint8_dec_eq(v_phase_11357_, v___x_11608_);
if (v___x_11612_ == 0)
{
uint32_t v___x_11613_; uint8_t v___x_11614_;
v___x_11613_ = 0;
v___x_11614_ = lean_uint32_dec_eq(v_hoverTargetOrd_11365_, v___x_11613_);
if (v___x_11614_ == 0)
{
uint8_t v___x_11615_;
v___x_11615_ = lean_uint8_dec_eq(v_targetAdmitted_11361_, v___x_11606_);
if (v___x_11615_ == 0)
{
v___y_11591_ = v___y_11600_;
goto v___jp_11590_;
}
else
{
uint32_t v___x_11616_;
v___x_11616_ = 66560;
v___y_11409_ = v___x_11616_;
goto v___jp_11408_;
}
}
else
{
v___y_11591_ = v___y_11600_;
goto v___jp_11590_;
}
}
else
{
uint32_t v___x_11617_;
v___x_11617_ = 66816;
v___y_11409_ = v___x_11617_;
goto v___jp_11408_;
}
}
else
{
uint32_t v___x_11618_;
v___x_11618_ = 0;
v___y_11409_ = v___x_11618_;
goto v___jp_11408_;
}
}
else
{
uint8_t v___x_11619_;
v___x_11619_ = lean_uint8_dec_eq(v_phase_11357_, v___x_11395_);
if (v___x_11619_ == 0)
{
v___y_11594_ = v___y_11600_;
goto v___jp_11593_;
}
else
{
uint8_t v___x_11620_;
v___x_11620_ = lean_uint8_dec_eq(v_targetCollapsed_11360_, v___x_11606_);
if (v___x_11620_ == 0)
{
v___y_11594_ = v___y_11600_;
goto v___jp_11593_;
}
else
{
uint32_t v___x_11621_; uint8_t v___x_11622_;
v___x_11621_ = 0;
v___x_11622_ = lean_uint32_dec_eq(v_hoverTargetOrd_11365_, v___x_11621_);
if (v___x_11622_ == 0)
{
uint8_t v___x_11623_;
v___x_11623_ = lean_uint32_dec_eq(v_hoverTargetOrd_11365_, v_springTargetOrd_11366_);
if (v___x_11623_ == 0)
{
v___y_11594_ = v___y_11600_;
goto v___jp_11593_;
}
else
{
uint32_t v___x_11624_; uint8_t v___x_11625_;
v___x_11624_ = 450;
v___x_11625_ = lean_uint32_dec_le(v___x_11624_, v_springElapsedMs_11364_);
if (v___x_11625_ == 0)
{
v___y_11594_ = v___y_11600_;
goto v___jp_11593_;
}
else
{
uint32_t v___x_11626_;
v___x_11626_ = 771;
v___y_11409_ = v___x_11626_;
goto v___jp_11408_;
}
}
}
else
{
v___y_11594_ = v___y_11600_;
goto v___jp_11593_;
}
}
}
}
}
else
{
uint8_t v___x_11627_;
v___x_11627_ = lean_uint8_dec_eq(v_phase_11357_, v___x_11606_);
if (v___x_11627_ == 0)
{
uint8_t v___x_11628_;
v___x_11628_ = lean_uint8_dec_eq(v_phase_11357_, v___x_11608_);
if (v___x_11628_ == 0)
{
v___y_11573_ = v___x_11607_;
v___y_11574_ = v___x_11606_;
v___y_11575_ = v___x_11608_;
v___y_11576_ = v___y_11600_;
v___y_11577_ = v___x_11603_;
v___y_11578_ = v___x_11607_;
goto v___jp_11572_;
}
else
{
v___y_11583_ = v___x_11607_;
v___y_11584_ = v___x_11606_;
v___y_11585_ = v___x_11608_;
v___y_11586_ = v___y_11600_;
v___y_11587_ = v___x_11603_;
goto v___jp_11582_;
}
}
else
{
v___y_11583_ = v___x_11607_;
v___y_11584_ = v___x_11606_;
v___y_11585_ = v___x_11608_;
v___y_11586_ = v___y_11600_;
v___y_11587_ = v___x_11603_;
goto v___jp_11582_;
}
}
}
else
{
uint8_t v___x_11629_;
v___x_11629_ = lean_uint8_dec_eq(v_phase_11357_, v___x_11606_);
if (v___x_11629_ == 0)
{
v___y_11597_ = v___y_11600_;
goto v___jp_11596_;
}
else
{
uint32_t v___x_11630_; uint8_t v___x_11631_;
v___x_11630_ = 260;
v___x_11631_ = lean_uint32_dec_le(v___x_11630_, v_elapsedMs_11363_);
if (v___x_11631_ == 0)
{
v___y_11597_ = v___y_11600_;
goto v___jp_11596_;
}
else
{
uint32_t v___x_11632_; uint8_t v___x_11633_;
v___x_11632_ = 36;
v___x_11633_ = lean_uint32_dec_lt(v_distSq_11362_, v___x_11632_);
if (v___x_11633_ == 0)
{
v___y_11597_ = v___y_11600_;
goto v___jp_11596_;
}
else
{
uint32_t v___x_11634_;
v___x_11634_ = 258;
v___y_11409_ = v___x_11634_;
goto v___jp_11408_;
}
}
}
}
}
else
{
uint32_t v___x_11635_;
v___x_11635_ = 0;
v___y_11409_ = v___x_11635_;
goto v___jp_11408_;
}
}
else
{
uint8_t v___x_11636_; uint8_t v___x_11637_;
v___x_11636_ = 1;
v___x_11637_ = lean_uint8_dec_eq(v_rowMovable_11359_, v___x_11636_);
if (v___x_11637_ == 0)
{
uint32_t v___x_11638_;
v___x_11638_ = 0;
v___y_11409_ = v___x_11638_;
goto v___jp_11408_;
}
else
{
uint32_t v___x_11639_;
v___x_11639_ = 1;
v___y_11409_ = v___x_11639_;
goto v___jp_11408_;
}
}
}
else
{
uint8_t v___x_11640_; uint8_t v___x_11641_;
v___x_11640_ = 0;
v___x_11641_ = lean_uint8_dec_eq(v_phase_11357_, v___x_11640_);
if (v___x_11641_ == 0)
{
uint32_t v___x_11642_;
v___x_11642_ = 1536;
v___y_11409_ = v___x_11642_;
goto v___jp_11408_;
}
else
{
uint32_t v___x_11643_;
v___x_11643_ = 0;
v___y_11409_ = v___x_11643_;
goto v___jp_11408_;
}
}
}
else
{
uint32_t v___x_11644_;
v___x_11644_ = 1536;
v___y_11389_ = v___x_11644_;
goto v___jp_11388_;
}
}
}
}

LEAN_EXPORT uint64_t orb_followup_queue_step(uint8_t v_op_11674_, uint32_t v_serverRev_11675_, uint32_t v_incomingServerRev_11676_, uint32_t v_expectedServerRev_11677_, uint64_t v_clientMsgId_11678_, uint64_t v_trackedMsgId_11679_, uint64_t v_deliveredMsgId_11680_, uint64_t v_postedAfterSeq_11681_, uint64_t v_turnSeq_11682_, uint8_t v_optimisticSending_11683_, uint8_t v_serverListed_11684_, uint8_t v_contentMatched_11685_, uint8_t v_alreadyDelivered_11686_){
_start:
{
uint32_t v___y_11688_; uint32_t v___y_11689_; uint32_t v___y_11690_; uint32_t v___y_11691_; uint32_t v___y_11692_; uint32_t v___y_11702_; uint8_t v___y_11703_; uint32_t v___y_11704_; uint32_t v___y_11705_; uint32_t v___y_11706_; uint32_t v___y_11707_; uint8_t v___y_11710_; uint8_t v___y_11711_; uint32_t v___y_11712_; uint32_t v___y_11713_; uint32_t v___y_11714_; uint32_t v___y_11715_; uint8_t v___x_11721_; uint8_t v_opOk_11722_; uint8_t v___x_11723_; uint8_t v___y_11725_; uint8_t v___y_11726_; uint8_t v___y_11727_; uint32_t v___y_11728_; uint8_t v___y_11729_; uint8_t v___y_11730_; uint32_t v___y_11731_; uint8_t v___y_11732_; uint8_t v___y_11733_; uint8_t v___y_11745_; uint8_t v___y_11746_; uint8_t v___y_11747_; uint8_t v___y_11748_; uint8_t v___y_11749_; uint32_t v___y_11750_; uint8_t v___y_11751_; uint8_t v___y_11752_; uint8_t v___y_11753_; uint32_t v___y_11754_; uint8_t v___y_11755_; uint8_t v___y_11757_; uint8_t v___y_11758_; uint8_t v___y_11759_; uint8_t v___y_11760_; uint8_t v___y_11761_; uint8_t v___y_11762_; uint32_t v___y_11763_; uint8_t v___y_11764_; uint8_t v___y_11765_; uint32_t v___y_11766_; uint8_t v___y_11767_; uint8_t v___y_11768_; uint8_t v___y_11770_; uint8_t v___y_11771_; uint8_t v___y_11772_; uint8_t v___y_11773_; uint8_t v___y_11774_; uint8_t v___y_11775_; uint8_t v___y_11776_; uint8_t v___y_11777_; uint8_t v___y_11778_; uint32_t v___y_11779_; uint32_t v___y_11780_; uint8_t v___y_11783_; uint8_t v___y_11784_; uint8_t v___y_11785_; uint8_t v___y_11786_; uint8_t v___y_11787_; uint8_t v___y_11788_; uint8_t v___y_11789_; uint8_t v___y_11790_; uint8_t v___y_11791_; uint8_t v___y_11792_; uint32_t v___y_11793_; uint32_t v___y_11794_; uint8_t v___y_11796_; uint8_t v___y_11797_; uint8_t v___y_11798_; uint8_t v___y_11799_; uint8_t v___y_11800_; uint8_t v___y_11801_; uint8_t v___y_11802_; uint8_t v___y_11803_; uint8_t v___y_11804_; uint32_t v___y_11805_; uint8_t v___y_11806_; uint8_t v___y_11811_; uint8_t v___y_11812_; uint8_t v___y_11813_; uint8_t v___y_11814_; uint8_t v___y_11815_; uint8_t v___y_11816_; uint8_t v___y_11817_; uint8_t v___y_11818_; uint8_t v___y_11819_; uint8_t v___y_11820_; uint32_t v___y_11821_; uint32_t v___y_11822_; uint8_t v___y_11825_; uint8_t v___y_11826_; uint8_t v___y_11827_; uint8_t v___y_11828_; uint8_t v___y_11829_; uint8_t v___y_11830_; uint8_t v___y_11831_; uint8_t v___y_11832_; uint8_t v___y_11833_; uint32_t v___y_11834_; uint8_t v___y_11835_; uint8_t v___y_11837_; uint8_t v___y_11838_; uint8_t v___y_11839_; uint8_t v___y_11840_; uint8_t v___y_11841_; uint8_t v___y_11842_; uint8_t v___y_11843_; uint8_t v___y_11844_; uint8_t v___y_11845_; uint32_t v___y_11846_; uint8_t v___y_11847_; uint8_t v___y_11854_; uint8_t v___y_11855_; uint8_t v___y_11856_; uint8_t v___y_11857_; uint8_t v___y_11858_; uint8_t v___y_11859_; uint8_t v___y_11860_; uint32_t v___y_11861_; uint8_t v___y_11862_; uint8_t v___y_11867_; uint8_t v___y_11868_; uint8_t v___y_11869_; uint8_t v___y_11870_; uint8_t v___y_11871_; uint8_t v___y_11872_; uint8_t v___y_11873_; uint32_t v___y_11874_; uint8_t v___y_11875_; uint8_t v___y_11877_; uint8_t v___y_11878_; uint8_t v___y_11879_; uint8_t v___y_11880_; uint8_t v___y_11881_; uint8_t v___y_11882_; uint32_t v___y_11883_; uint8_t v___y_11884_; uint8_t v___y_11890_; uint8_t v___y_11891_; uint8_t v___y_11892_; uint8_t v___y_11893_; uint8_t v___y_11894_; uint8_t v___y_11895_; uint8_t v___y_11896_; uint32_t v___y_11897_; uint8_t v___y_11898_; uint8_t v___y_11901_; uint64_t v___y_11902_; uint8_t v___y_11903_; uint32_t v___y_11904_; uint8_t v___y_11905_; uint8_t v___y_11914_; uint8_t v___x_11919_;
v___x_11721_ = 3;
v_opOk_11722_ = lean_uint8_dec_le(v_op_11674_, v___x_11721_);
v___x_11723_ = 1;
v___x_11919_ = lean_uint8_dec_le(v_optimisticSending_11683_, v___x_11723_);
if (v___x_11919_ == 0)
{
v___y_11914_ = v___x_11919_;
goto v___jp_11913_;
}
else
{
uint8_t v___x_11920_;
v___x_11920_ = lean_uint8_dec_le(v_serverListed_11684_, v___x_11723_);
if (v___x_11920_ == 0)
{
v___y_11914_ = v___x_11920_;
goto v___jp_11913_;
}
else
{
uint8_t v___x_11921_;
v___x_11921_ = lean_uint8_dec_le(v_contentMatched_11685_, v___x_11723_);
if (v___x_11921_ == 0)
{
v___y_11914_ = v___x_11921_;
goto v___jp_11913_;
}
else
{
uint8_t v___x_11922_;
v___x_11922_ = lean_uint8_dec_le(v_alreadyDelivered_11686_, v___x_11723_);
v___y_11914_ = v___x_11922_;
goto v___jp_11913_;
}
}
}
v___jp_11687_:
{
uint32_t v___x_11693_; uint32_t v___x_11694_; uint32_t v_lo32_11695_; uint64_t v___x_11696_; uint64_t v___x_11697_; uint64_t v___x_11698_; uint64_t v___x_11699_; uint64_t v___x_11700_;
v___x_11693_ = lean_uint32_lor(v___y_11690_, v___y_11688_);
v___x_11694_ = lean_uint32_lor(v___x_11693_, v___y_11691_);
v_lo32_11695_ = lean_uint32_lor(v___x_11694_, v___y_11692_);
v___x_11696_ = lean_uint32_to_uint64(v_lo32_11695_);
v___x_11697_ = lean_uint32_to_uint64(v___y_11689_);
v___x_11698_ = 32ULL;
v___x_11699_ = lean_uint64_shift_left(v___x_11697_, v___x_11698_);
v___x_11700_ = lean_uint64_lor(v___x_11696_, v___x_11699_);
return v___x_11700_;
}
v___jp_11701_:
{
if (v___y_11703_ == 0)
{
v___y_11688_ = v___y_11702_;
v___y_11689_ = v___y_11704_;
v___y_11690_ = v___y_11705_;
v___y_11691_ = v___y_11707_;
v___y_11692_ = v___y_11706_;
goto v___jp_11687_;
}
else
{
uint32_t v___x_11708_;
v___x_11708_ = 1024;
v___y_11688_ = v___y_11702_;
v___y_11689_ = v___y_11704_;
v___y_11690_ = v___y_11705_;
v___y_11691_ = v___y_11707_;
v___y_11692_ = v___x_11708_;
goto v___jp_11687_;
}
}
v___jp_11709_:
{
if (v___y_11710_ == 0)
{
v___y_11702_ = v___y_11715_;
v___y_11703_ = v___y_11711_;
v___y_11704_ = v___y_11712_;
v___y_11705_ = v___y_11713_;
v___y_11706_ = v___y_11714_;
v___y_11707_ = v___y_11714_;
goto v___jp_11701_;
}
else
{
uint32_t v___x_11716_;
v___x_11716_ = 512;
v___y_11702_ = v___y_11715_;
v___y_11703_ = v___y_11711_;
v___y_11704_ = v___y_11712_;
v___y_11705_ = v___y_11713_;
v___y_11706_ = v___y_11714_;
v___y_11707_ = v___x_11716_;
goto v___jp_11701_;
}
}
v___jp_11717_:
{
uint64_t v___x_11718_; uint64_t v___x_11719_; uint64_t v___x_11720_;
v___x_11718_ = lean_uint32_to_uint64(v_serverRev_11675_);
v___x_11719_ = 32ULL;
v___x_11720_ = lean_uint64_shift_left(v___x_11718_, v___x_11719_);
return v___x_11720_;
}
v___jp_11724_:
{
if (v___y_11732_ == 0)
{
if (v___y_11726_ == 0)
{
uint8_t v___x_11734_;
v___x_11734_ = lean_uint8_dec_eq(v_op_11674_, v___x_11723_);
if (v___x_11734_ == 0)
{
if (v___y_11729_ == 0)
{
if (v___y_11730_ == 0)
{
uint32_t v___x_11735_;
v___x_11735_ = 4;
v___y_11710_ = v___y_11733_;
v___y_11711_ = v___y_11727_;
v___y_11712_ = v___y_11728_;
v___y_11713_ = v___x_11735_;
v___y_11714_ = v___y_11731_;
v___y_11715_ = v___y_11731_;
goto v___jp_11709_;
}
else
{
uint32_t v___x_11736_;
v___x_11736_ = 3;
v___y_11710_ = v___y_11733_;
v___y_11711_ = v___y_11727_;
v___y_11712_ = v___y_11728_;
v___y_11713_ = v___x_11736_;
v___y_11714_ = v___y_11731_;
v___y_11715_ = v___y_11731_;
goto v___jp_11709_;
}
}
else
{
if (v___y_11725_ == 0)
{
v___y_11710_ = v___y_11733_;
v___y_11711_ = v___y_11727_;
v___y_11712_ = v___y_11728_;
v___y_11713_ = v___y_11731_;
v___y_11714_ = v___y_11731_;
v___y_11715_ = v___y_11731_;
goto v___jp_11709_;
}
else
{
uint32_t v___x_11737_;
v___x_11737_ = 3;
v___y_11710_ = v___y_11733_;
v___y_11711_ = v___y_11727_;
v___y_11712_ = v___y_11728_;
v___y_11713_ = v___x_11737_;
v___y_11714_ = v___y_11731_;
v___y_11715_ = v___y_11731_;
goto v___jp_11709_;
}
}
}
else
{
uint8_t v___x_11738_;
v___x_11738_ = lean_uint32_dec_eq(v_expectedServerRev_11677_, v_serverRev_11675_);
if (v___x_11738_ == 0)
{
uint32_t v___x_11739_;
v___x_11739_ = 2;
v___y_11710_ = v___y_11733_;
v___y_11711_ = v___y_11727_;
v___y_11712_ = v___y_11728_;
v___y_11713_ = v___x_11739_;
v___y_11714_ = v___y_11731_;
v___y_11715_ = v___y_11731_;
goto v___jp_11709_;
}
else
{
uint32_t v___x_11740_;
v___x_11740_ = 5;
v___y_11710_ = v___y_11733_;
v___y_11711_ = v___y_11727_;
v___y_11712_ = v___y_11728_;
v___y_11713_ = v___x_11740_;
v___y_11714_ = v___y_11731_;
v___y_11715_ = v___y_11731_;
goto v___jp_11709_;
}
}
}
else
{
uint32_t v___x_11741_;
v___x_11741_ = 2;
v___y_11710_ = v___y_11733_;
v___y_11711_ = v___y_11727_;
v___y_11712_ = v___y_11728_;
v___y_11713_ = v___x_11741_;
v___y_11714_ = v___y_11731_;
v___y_11715_ = v___y_11731_;
goto v___jp_11709_;
}
}
else
{
uint32_t v___x_11742_; uint32_t v___x_11743_;
v___x_11742_ = 1;
v___x_11743_ = 256;
v___y_11710_ = v___y_11733_;
v___y_11711_ = v___y_11727_;
v___y_11712_ = v___y_11728_;
v___y_11713_ = v___x_11742_;
v___y_11714_ = v___y_11731_;
v___y_11715_ = v___x_11743_;
goto v___jp_11709_;
}
}
v___jp_11744_:
{
if (v___y_11755_ == 0)
{
if (v___y_11749_ == 0)
{
if (v___y_11746_ == 0)
{
v___y_11725_ = v___y_11748_;
v___y_11726_ = v___y_11747_;
v___y_11727_ = v___y_11749_;
v___y_11728_ = v___y_11750_;
v___y_11729_ = v___y_11751_;
v___y_11730_ = v___y_11755_;
v___y_11731_ = v___y_11754_;
v___y_11732_ = v___y_11753_;
v___y_11733_ = v___y_11745_;
goto v___jp_11724_;
}
else
{
v___y_11725_ = v___y_11748_;
v___y_11726_ = v___y_11747_;
v___y_11727_ = v___y_11749_;
v___y_11728_ = v___y_11750_;
v___y_11729_ = v___y_11751_;
v___y_11730_ = v___y_11755_;
v___y_11731_ = v___y_11754_;
v___y_11732_ = v___y_11753_;
v___y_11733_ = v___y_11752_;
goto v___jp_11724_;
}
}
else
{
v___y_11725_ = v___y_11748_;
v___y_11726_ = v___y_11747_;
v___y_11727_ = v___y_11749_;
v___y_11728_ = v___y_11750_;
v___y_11729_ = v___y_11751_;
v___y_11730_ = v___y_11755_;
v___y_11731_ = v___y_11754_;
v___y_11732_ = v___y_11753_;
v___y_11733_ = v___y_11745_;
goto v___jp_11724_;
}
}
else
{
v___y_11725_ = v___y_11748_;
v___y_11726_ = v___y_11747_;
v___y_11727_ = v___y_11749_;
v___y_11728_ = v___y_11750_;
v___y_11729_ = v___y_11751_;
v___y_11730_ = v___y_11755_;
v___y_11731_ = v___y_11754_;
v___y_11732_ = v___y_11753_;
v___y_11733_ = v___y_11745_;
goto v___jp_11724_;
}
}
v___jp_11756_:
{
if (v___y_11758_ == 0)
{
v___y_11745_ = v___y_11757_;
v___y_11746_ = v___y_11761_;
v___y_11747_ = v___y_11760_;
v___y_11748_ = v___y_11759_;
v___y_11749_ = v___y_11762_;
v___y_11750_ = v___y_11763_;
v___y_11751_ = v___y_11764_;
v___y_11752_ = v___y_11768_;
v___y_11753_ = v___y_11767_;
v___y_11754_ = v___y_11766_;
v___y_11755_ = v___y_11765_;
goto v___jp_11744_;
}
else
{
v___y_11745_ = v___y_11757_;
v___y_11746_ = v___y_11761_;
v___y_11747_ = v___y_11760_;
v___y_11748_ = v___y_11759_;
v___y_11749_ = v___y_11762_;
v___y_11750_ = v___y_11763_;
v___y_11751_ = v___y_11764_;
v___y_11752_ = v___y_11768_;
v___y_11753_ = v___y_11767_;
v___y_11754_ = v___y_11766_;
v___y_11755_ = v___y_11757_;
goto v___jp_11744_;
}
}
v___jp_11769_:
{
uint8_t v___x_11781_;
v___x_11781_ = lean_uint64_dec_eq(v_clientMsgId_11678_, v_trackedMsgId_11679_);
v___y_11757_ = v___y_11770_;
v___y_11758_ = v___y_11774_;
v___y_11759_ = v___y_11773_;
v___y_11760_ = v___y_11772_;
v___y_11761_ = v___y_11771_;
v___y_11762_ = v___y_11775_;
v___y_11763_ = v___y_11780_;
v___y_11764_ = v___y_11776_;
v___y_11765_ = v___y_11777_;
v___y_11766_ = v___y_11779_;
v___y_11767_ = v___y_11778_;
v___y_11768_ = v___x_11781_;
goto v___jp_11756_;
}
v___jp_11782_:
{
if (v___y_11790_ == 0)
{
v___y_11757_ = v___y_11783_;
v___y_11758_ = v___y_11787_;
v___y_11759_ = v___y_11786_;
v___y_11760_ = v___y_11785_;
v___y_11761_ = v___y_11784_;
v___y_11762_ = v___y_11788_;
v___y_11763_ = v___y_11794_;
v___y_11764_ = v___y_11790_;
v___y_11765_ = v___y_11791_;
v___y_11766_ = v___y_11793_;
v___y_11767_ = v___y_11792_;
v___y_11768_ = v___y_11789_;
goto v___jp_11756_;
}
else
{
if (v___y_11792_ == 0)
{
v___y_11770_ = v___y_11783_;
v___y_11771_ = v___y_11784_;
v___y_11772_ = v___y_11785_;
v___y_11773_ = v___y_11786_;
v___y_11774_ = v___y_11787_;
v___y_11775_ = v___y_11788_;
v___y_11776_ = v___y_11790_;
v___y_11777_ = v___y_11791_;
v___y_11778_ = v___y_11792_;
v___y_11779_ = v___y_11793_;
v___y_11780_ = v___y_11794_;
goto v___jp_11769_;
}
else
{
v___y_11757_ = v___y_11783_;
v___y_11758_ = v___y_11787_;
v___y_11759_ = v___y_11786_;
v___y_11760_ = v___y_11785_;
v___y_11761_ = v___y_11784_;
v___y_11762_ = v___y_11788_;
v___y_11763_ = v___y_11794_;
v___y_11764_ = v___y_11790_;
v___y_11765_ = v___y_11791_;
v___y_11766_ = v___y_11793_;
v___y_11767_ = v___y_11792_;
v___y_11768_ = v___y_11791_;
goto v___jp_11756_;
}
}
}
v___jp_11795_:
{
uint8_t v___x_11807_;
v___x_11807_ = lean_uint8_dec_eq(v_op_11674_, v___x_11723_);
if (v___x_11807_ == 0)
{
v___y_11783_ = v___y_11796_;
v___y_11784_ = v___y_11800_;
v___y_11785_ = v___y_11799_;
v___y_11786_ = v___y_11798_;
v___y_11787_ = v___y_11797_;
v___y_11788_ = v___y_11801_;
v___y_11789_ = v___y_11802_;
v___y_11790_ = v___y_11803_;
v___y_11791_ = v___y_11804_;
v___y_11792_ = v___y_11806_;
v___y_11793_ = v___y_11805_;
v___y_11794_ = v_serverRev_11675_;
goto v___jp_11782_;
}
else
{
uint32_t v___x_11808_; uint32_t v___x_11809_;
v___x_11808_ = 1;
v___x_11809_ = lean_uint32_add(v_serverRev_11675_, v___x_11808_);
v___y_11783_ = v___y_11796_;
v___y_11784_ = v___y_11800_;
v___y_11785_ = v___y_11799_;
v___y_11786_ = v___y_11798_;
v___y_11787_ = v___y_11797_;
v___y_11788_ = v___y_11801_;
v___y_11789_ = v___y_11802_;
v___y_11790_ = v___y_11803_;
v___y_11791_ = v___y_11804_;
v___y_11792_ = v___y_11806_;
v___y_11793_ = v___y_11805_;
v___y_11794_ = v___x_11809_;
goto v___jp_11782_;
}
}
v___jp_11810_:
{
uint8_t v___x_11823_;
v___x_11823_ = lean_uint32_dec_lt(v_incomingServerRev_11676_, v_serverRev_11675_);
if (v___x_11823_ == 0)
{
v___y_11757_ = v___y_11811_;
v___y_11758_ = v___y_11815_;
v___y_11759_ = v___y_11814_;
v___y_11760_ = v___y_11813_;
v___y_11761_ = v___y_11812_;
v___y_11762_ = v___y_11816_;
v___y_11763_ = v___y_11822_;
v___y_11764_ = v___y_11818_;
v___y_11765_ = v___y_11819_;
v___y_11766_ = v___y_11821_;
v___y_11767_ = v___y_11820_;
v___y_11768_ = v___y_11817_;
goto v___jp_11756_;
}
else
{
v___y_11757_ = v___y_11811_;
v___y_11758_ = v___y_11815_;
v___y_11759_ = v___y_11814_;
v___y_11760_ = v___y_11813_;
v___y_11761_ = v___y_11812_;
v___y_11762_ = v___y_11816_;
v___y_11763_ = v___y_11822_;
v___y_11764_ = v___y_11818_;
v___y_11765_ = v___y_11819_;
v___y_11766_ = v___y_11821_;
v___y_11767_ = v___y_11820_;
v___y_11768_ = v___y_11819_;
goto v___jp_11756_;
}
}
v___jp_11824_:
{
if (v___y_11835_ == 0)
{
if (v___y_11828_ == 0)
{
v___y_11783_ = v___y_11825_;
v___y_11784_ = v___y_11829_;
v___y_11785_ = v___y_11828_;
v___y_11786_ = v___y_11827_;
v___y_11787_ = v___y_11826_;
v___y_11788_ = v___y_11830_;
v___y_11789_ = v___y_11831_;
v___y_11790_ = v___y_11832_;
v___y_11791_ = v___y_11833_;
v___y_11792_ = v___y_11835_;
v___y_11793_ = v___y_11834_;
v___y_11794_ = v_serverRev_11675_;
goto v___jp_11782_;
}
else
{
v___y_11811_ = v___y_11825_;
v___y_11812_ = v___y_11829_;
v___y_11813_ = v___y_11828_;
v___y_11814_ = v___y_11827_;
v___y_11815_ = v___y_11826_;
v___y_11816_ = v___y_11830_;
v___y_11817_ = v___y_11831_;
v___y_11818_ = v___y_11832_;
v___y_11819_ = v___y_11833_;
v___y_11820_ = v___y_11835_;
v___y_11821_ = v___y_11834_;
v___y_11822_ = v_serverRev_11675_;
goto v___jp_11810_;
}
}
else
{
if (v___y_11828_ == 0)
{
v___y_11796_ = v___y_11825_;
v___y_11797_ = v___y_11826_;
v___y_11798_ = v___y_11827_;
v___y_11799_ = v___y_11828_;
v___y_11800_ = v___y_11829_;
v___y_11801_ = v___y_11830_;
v___y_11802_ = v___y_11831_;
v___y_11803_ = v___y_11832_;
v___y_11804_ = v___y_11833_;
v___y_11805_ = v___y_11834_;
v___y_11806_ = v___y_11835_;
goto v___jp_11795_;
}
else
{
v___y_11811_ = v___y_11825_;
v___y_11812_ = v___y_11829_;
v___y_11813_ = v___y_11828_;
v___y_11814_ = v___y_11827_;
v___y_11815_ = v___y_11826_;
v___y_11816_ = v___y_11830_;
v___y_11817_ = v___y_11831_;
v___y_11818_ = v___y_11832_;
v___y_11819_ = v___y_11833_;
v___y_11820_ = v___y_11835_;
v___y_11821_ = v___y_11834_;
v___y_11822_ = v_incomingServerRev_11676_;
goto v___jp_11810_;
}
}
}
v___jp_11836_:
{
if (v___y_11839_ == 0)
{
uint8_t v___x_11848_;
v___x_11848_ = lean_uint8_dec_eq(v_op_11674_, v___x_11723_);
if (v___x_11848_ == 0)
{
if (v___y_11843_ == 0)
{
v___y_11825_ = v___y_11837_;
v___y_11826_ = v___y_11840_;
v___y_11827_ = v___y_11847_;
v___y_11828_ = v___y_11839_;
v___y_11829_ = v___y_11838_;
v___y_11830_ = v___y_11841_;
v___y_11831_ = v___y_11842_;
v___y_11832_ = v___y_11843_;
v___y_11833_ = v___y_11845_;
v___y_11834_ = v___y_11846_;
v___y_11835_ = v___y_11844_;
goto v___jp_11824_;
}
else
{
if (v___y_11838_ == 0)
{
v___y_11770_ = v___y_11837_;
v___y_11771_ = v___y_11838_;
v___y_11772_ = v___y_11839_;
v___y_11773_ = v___y_11847_;
v___y_11774_ = v___y_11840_;
v___y_11775_ = v___y_11841_;
v___y_11776_ = v___y_11843_;
v___y_11777_ = v___y_11845_;
v___y_11778_ = v___y_11838_;
v___y_11779_ = v___y_11846_;
v___y_11780_ = v_serverRev_11675_;
goto v___jp_11769_;
}
else
{
if (v___y_11847_ == 0)
{
v___y_11796_ = v___y_11837_;
v___y_11797_ = v___y_11840_;
v___y_11798_ = v___y_11847_;
v___y_11799_ = v___y_11839_;
v___y_11800_ = v___y_11838_;
v___y_11801_ = v___y_11841_;
v___y_11802_ = v___y_11842_;
v___y_11803_ = v___y_11843_;
v___y_11804_ = v___y_11845_;
v___y_11805_ = v___y_11846_;
v___y_11806_ = v___y_11843_;
goto v___jp_11795_;
}
else
{
v___y_11825_ = v___y_11837_;
v___y_11826_ = v___y_11840_;
v___y_11827_ = v___y_11847_;
v___y_11828_ = v___y_11839_;
v___y_11829_ = v___y_11838_;
v___y_11830_ = v___y_11841_;
v___y_11831_ = v___y_11842_;
v___y_11832_ = v___y_11843_;
v___y_11833_ = v___y_11845_;
v___y_11834_ = v___y_11846_;
v___y_11835_ = v___x_11848_;
goto v___jp_11824_;
}
}
}
}
else
{
uint8_t v___x_11849_;
v___x_11849_ = lean_uint32_dec_eq(v_expectedServerRev_11677_, v_serverRev_11675_);
if (v___x_11849_ == 0)
{
v___y_11825_ = v___y_11837_;
v___y_11826_ = v___y_11840_;
v___y_11827_ = v___y_11847_;
v___y_11828_ = v___y_11839_;
v___y_11829_ = v___y_11838_;
v___y_11830_ = v___y_11841_;
v___y_11831_ = v___y_11842_;
v___y_11832_ = v___y_11843_;
v___y_11833_ = v___y_11845_;
v___y_11834_ = v___y_11846_;
v___y_11835_ = v___x_11849_;
goto v___jp_11824_;
}
else
{
uint32_t v___x_11850_; uint8_t v___x_11851_;
v___x_11850_ = 4294967295;
v___x_11851_ = lean_uint32_dec_lt(v_serverRev_11675_, v___x_11850_);
v___y_11825_ = v___y_11837_;
v___y_11826_ = v___y_11840_;
v___y_11827_ = v___y_11847_;
v___y_11828_ = v___y_11839_;
v___y_11829_ = v___y_11838_;
v___y_11830_ = v___y_11841_;
v___y_11831_ = v___y_11842_;
v___y_11832_ = v___y_11843_;
v___y_11833_ = v___y_11845_;
v___y_11834_ = v___y_11846_;
v___y_11835_ = v___x_11851_;
goto v___jp_11824_;
}
}
}
else
{
uint8_t v___x_11852_;
v___x_11852_ = lean_uint32_dec_le(v_serverRev_11675_, v_incomingServerRev_11676_);
v___y_11825_ = v___y_11837_;
v___y_11826_ = v___y_11840_;
v___y_11827_ = v___y_11847_;
v___y_11828_ = v___y_11839_;
v___y_11829_ = v___y_11838_;
v___y_11830_ = v___y_11841_;
v___y_11831_ = v___y_11842_;
v___y_11832_ = v___y_11843_;
v___y_11833_ = v___y_11845_;
v___y_11834_ = v___y_11846_;
v___y_11835_ = v___x_11852_;
goto v___jp_11824_;
}
}
v___jp_11853_:
{
uint8_t v___x_11863_; uint8_t v___x_11864_;
v___x_11863_ = 2;
v___x_11864_ = lean_uint8_dec_eq(v_op_11674_, v___x_11863_);
if (v___x_11864_ == 0)
{
v___y_11837_ = v___y_11854_;
v___y_11838_ = v___y_11857_;
v___y_11839_ = v___y_11856_;
v___y_11840_ = v___y_11855_;
v___y_11841_ = v___y_11862_;
v___y_11842_ = v___y_11858_;
v___y_11843_ = v___x_11864_;
v___y_11844_ = v___y_11859_;
v___y_11845_ = v___y_11860_;
v___y_11846_ = v___y_11861_;
v___y_11847_ = v___x_11864_;
goto v___jp_11836_;
}
else
{
if (v___y_11857_ == 0)
{
v___y_11837_ = v___y_11854_;
v___y_11838_ = v___y_11857_;
v___y_11839_ = v___y_11856_;
v___y_11840_ = v___y_11855_;
v___y_11841_ = v___y_11862_;
v___y_11842_ = v___y_11858_;
v___y_11843_ = v___x_11864_;
v___y_11844_ = v___y_11859_;
v___y_11845_ = v___y_11860_;
v___y_11846_ = v___y_11861_;
v___y_11847_ = v___y_11857_;
goto v___jp_11836_;
}
else
{
uint8_t v___x_11865_;
v___x_11865_ = lean_uint64_dec_eq(v_clientMsgId_11678_, v_trackedMsgId_11679_);
if (v___x_11865_ == 0)
{
if (v___y_11855_ == 0)
{
v___y_11837_ = v___y_11854_;
v___y_11838_ = v___y_11857_;
v___y_11839_ = v___y_11856_;
v___y_11840_ = v___y_11855_;
v___y_11841_ = v___y_11862_;
v___y_11842_ = v___y_11858_;
v___y_11843_ = v___x_11864_;
v___y_11844_ = v___y_11859_;
v___y_11845_ = v___y_11860_;
v___y_11846_ = v___y_11861_;
v___y_11847_ = v___y_11857_;
goto v___jp_11836_;
}
else
{
v___y_11837_ = v___y_11854_;
v___y_11838_ = v___y_11857_;
v___y_11839_ = v___y_11856_;
v___y_11840_ = v___y_11855_;
v___y_11841_ = v___y_11862_;
v___y_11842_ = v___y_11858_;
v___y_11843_ = v___x_11864_;
v___y_11844_ = v___y_11859_;
v___y_11845_ = v___y_11860_;
v___y_11846_ = v___y_11861_;
v___y_11847_ = v___y_11854_;
goto v___jp_11836_;
}
}
else
{
v___y_11837_ = v___y_11854_;
v___y_11838_ = v___y_11857_;
v___y_11839_ = v___y_11856_;
v___y_11840_ = v___y_11855_;
v___y_11841_ = v___y_11862_;
v___y_11842_ = v___y_11858_;
v___y_11843_ = v___x_11864_;
v___y_11844_ = v___y_11859_;
v___y_11845_ = v___y_11860_;
v___y_11846_ = v___y_11861_;
v___y_11847_ = v___y_11860_;
goto v___jp_11836_;
}
}
}
}
v___jp_11866_:
{
if (v___y_11872_ == 0)
{
v___y_11854_ = v___y_11867_;
v___y_11855_ = v___y_11870_;
v___y_11856_ = v___y_11869_;
v___y_11857_ = v___y_11868_;
v___y_11858_ = v___y_11871_;
v___y_11859_ = v___y_11872_;
v___y_11860_ = v___y_11873_;
v___y_11861_ = v___y_11874_;
v___y_11862_ = v___y_11875_;
goto v___jp_11853_;
}
else
{
v___y_11854_ = v___y_11867_;
v___y_11855_ = v___y_11870_;
v___y_11856_ = v___y_11869_;
v___y_11857_ = v___y_11868_;
v___y_11858_ = v___y_11871_;
v___y_11859_ = v___y_11872_;
v___y_11860_ = v___y_11873_;
v___y_11861_ = v___y_11874_;
v___y_11862_ = v___y_11873_;
goto v___jp_11853_;
}
}
v___jp_11876_:
{
uint8_t v___x_11885_;
v___x_11885_ = lean_uint8_dec_eq(v_op_11674_, v___y_11881_);
if (v___x_11885_ == 0)
{
v___y_11867_ = v___y_11877_;
v___y_11868_ = v___y_11878_;
v___y_11869_ = v___x_11885_;
v___y_11870_ = v___y_11879_;
v___y_11871_ = v___y_11880_;
v___y_11872_ = v___y_11884_;
v___y_11873_ = v___y_11882_;
v___y_11874_ = v___y_11883_;
v___y_11875_ = v___x_11885_;
goto v___jp_11866_;
}
else
{
uint8_t v___x_11886_;
v___x_11886_ = lean_uint32_dec_le(v_serverRev_11675_, v_incomingServerRev_11676_);
if (v___x_11886_ == 0)
{
v___y_11867_ = v___y_11877_;
v___y_11868_ = v___y_11878_;
v___y_11869_ = v___x_11885_;
v___y_11870_ = v___y_11879_;
v___y_11871_ = v___y_11880_;
v___y_11872_ = v___y_11884_;
v___y_11873_ = v___y_11882_;
v___y_11874_ = v___y_11883_;
v___y_11875_ = v___x_11886_;
goto v___jp_11866_;
}
else
{
if (v___y_11878_ == 0)
{
v___y_11867_ = v___y_11877_;
v___y_11868_ = v___y_11878_;
v___y_11869_ = v___x_11885_;
v___y_11870_ = v___y_11879_;
v___y_11871_ = v___y_11880_;
v___y_11872_ = v___y_11884_;
v___y_11873_ = v___y_11882_;
v___y_11874_ = v___y_11883_;
v___y_11875_ = v___y_11878_;
goto v___jp_11866_;
}
else
{
if (v___y_11879_ == 0)
{
v___y_11867_ = v___y_11877_;
v___y_11868_ = v___y_11878_;
v___y_11869_ = v___x_11885_;
v___y_11870_ = v___y_11879_;
v___y_11871_ = v___y_11880_;
v___y_11872_ = v___y_11884_;
v___y_11873_ = v___y_11882_;
v___y_11874_ = v___y_11883_;
v___y_11875_ = v___y_11879_;
goto v___jp_11866_;
}
else
{
if (v___y_11880_ == 0)
{
v___y_11867_ = v___y_11877_;
v___y_11868_ = v___y_11878_;
v___y_11869_ = v___x_11885_;
v___y_11870_ = v___y_11879_;
v___y_11871_ = v___y_11880_;
v___y_11872_ = v___y_11884_;
v___y_11873_ = v___y_11882_;
v___y_11874_ = v___y_11883_;
v___y_11875_ = v___y_11880_;
goto v___jp_11866_;
}
else
{
uint8_t v___x_11887_;
v___x_11887_ = lean_uint8_dec_eq(v_optimisticSending_11683_, v___y_11881_);
if (v___x_11887_ == 0)
{
v___y_11867_ = v___y_11877_;
v___y_11868_ = v___y_11878_;
v___y_11869_ = v___x_11885_;
v___y_11870_ = v___y_11879_;
v___y_11871_ = v___y_11880_;
v___y_11872_ = v___y_11884_;
v___y_11873_ = v___y_11882_;
v___y_11874_ = v___y_11883_;
v___y_11875_ = v___x_11887_;
goto v___jp_11866_;
}
else
{
uint8_t v___x_11888_;
v___x_11888_ = lean_uint64_dec_lt(v_postedAfterSeq_11681_, v_turnSeq_11682_);
v___y_11867_ = v___y_11877_;
v___y_11868_ = v___y_11878_;
v___y_11869_ = v___x_11885_;
v___y_11870_ = v___y_11879_;
v___y_11871_ = v___y_11880_;
v___y_11872_ = v___y_11884_;
v___y_11873_ = v___y_11882_;
v___y_11874_ = v___y_11883_;
v___y_11875_ = v___x_11888_;
goto v___jp_11866_;
}
}
}
}
}
}
}
v___jp_11889_:
{
uint8_t v___x_11899_;
v___x_11899_ = lean_uint8_dec_eq(v_op_11674_, v___x_11721_);
if (v___x_11899_ == 0)
{
v___y_11877_ = v___y_11890_;
v___y_11878_ = v___y_11892_;
v___y_11879_ = v___y_11891_;
v___y_11880_ = v___y_11893_;
v___y_11881_ = v___y_11894_;
v___y_11882_ = v___y_11896_;
v___y_11883_ = v___y_11897_;
v___y_11884_ = v___x_11899_;
goto v___jp_11876_;
}
else
{
if (v___y_11895_ == 0)
{
v___y_11877_ = v___y_11890_;
v___y_11878_ = v___y_11892_;
v___y_11879_ = v___y_11891_;
v___y_11880_ = v___y_11893_;
v___y_11881_ = v___y_11894_;
v___y_11882_ = v___y_11896_;
v___y_11883_ = v___y_11897_;
v___y_11884_ = v___y_11898_;
goto v___jp_11876_;
}
else
{
v___y_11877_ = v___y_11890_;
v___y_11878_ = v___y_11892_;
v___y_11879_ = v___y_11891_;
v___y_11880_ = v___y_11893_;
v___y_11881_ = v___y_11894_;
v___y_11882_ = v___y_11896_;
v___y_11883_ = v___y_11897_;
v___y_11884_ = v___y_11896_;
goto v___jp_11876_;
}
}
}
v___jp_11900_:
{
uint8_t v___x_11906_; uint8_t v_notDelivered_11907_; uint8_t v_serverUnlisted_11908_;
v___x_11906_ = 0;
v_notDelivered_11907_ = lean_uint8_dec_eq(v_alreadyDelivered_11686_, v___x_11906_);
v_serverUnlisted_11908_ = lean_uint8_dec_eq(v_serverListed_11684_, v___x_11906_);
if (v___y_11905_ == 0)
{
v___y_11890_ = v___y_11901_;
v___y_11891_ = v_notDelivered_11907_;
v___y_11892_ = v___y_11905_;
v___y_11893_ = v_serverUnlisted_11908_;
v___y_11894_ = v___x_11906_;
v___y_11895_ = v___y_11905_;
v___y_11896_ = v___y_11903_;
v___y_11897_ = v___y_11904_;
v___y_11898_ = v___y_11905_;
goto v___jp_11889_;
}
else
{
if (v_notDelivered_11907_ == 0)
{
v___y_11890_ = v___y_11901_;
v___y_11891_ = v_notDelivered_11907_;
v___y_11892_ = v___y_11905_;
v___y_11893_ = v_serverUnlisted_11908_;
v___y_11894_ = v___x_11906_;
v___y_11895_ = v_notDelivered_11907_;
v___y_11896_ = v___y_11903_;
v___y_11897_ = v___y_11904_;
v___y_11898_ = v_notDelivered_11907_;
goto v___jp_11889_;
}
else
{
uint8_t v___x_11909_; uint8_t v___x_11910_;
v___x_11909_ = lean_uint64_dec_eq(v_deliveredMsgId_11680_, v_clientMsgId_11678_);
v___x_11910_ = lean_uint64_dec_eq(v_deliveredMsgId_11680_, v___y_11902_);
if (v___x_11910_ == 0)
{
v___y_11890_ = v___y_11901_;
v___y_11891_ = v_notDelivered_11907_;
v___y_11892_ = v___y_11905_;
v___y_11893_ = v_serverUnlisted_11908_;
v___y_11894_ = v___x_11906_;
v___y_11895_ = v___x_11909_;
v___y_11896_ = v___y_11903_;
v___y_11897_ = v___y_11904_;
v___y_11898_ = v___x_11910_;
goto v___jp_11889_;
}
else
{
uint8_t v___x_11911_;
v___x_11911_ = lean_uint8_dec_eq(v_contentMatched_11685_, v___x_11723_);
if (v___x_11911_ == 0)
{
v___y_11890_ = v___y_11901_;
v___y_11891_ = v_notDelivered_11907_;
v___y_11892_ = v___y_11905_;
v___y_11893_ = v_serverUnlisted_11908_;
v___y_11894_ = v___x_11906_;
v___y_11895_ = v___x_11909_;
v___y_11896_ = v___y_11903_;
v___y_11897_ = v___y_11904_;
v___y_11898_ = v___x_11911_;
goto v___jp_11889_;
}
else
{
uint8_t v___x_11912_;
v___x_11912_ = lean_uint64_dec_lt(v_postedAfterSeq_11681_, v_turnSeq_11682_);
v___y_11890_ = v___y_11901_;
v___y_11891_ = v_notDelivered_11907_;
v___y_11892_ = v___y_11905_;
v___y_11893_ = v_serverUnlisted_11908_;
v___y_11894_ = v___x_11906_;
v___y_11895_ = v___x_11909_;
v___y_11896_ = v___y_11903_;
v___y_11897_ = v___y_11904_;
v___y_11898_ = v___x_11912_;
goto v___jp_11889_;
}
}
}
}
}
v___jp_11913_:
{
if (v_opOk_11722_ == 0)
{
goto v___jp_11717_;
}
else
{
if (v___y_11914_ == 0)
{
goto v___jp_11717_;
}
else
{
uint32_t v___x_11915_; uint8_t v___x_11916_;
v___x_11915_ = 0;
v___x_11916_ = lean_uint32_dec_eq(v_serverRev_11675_, v___x_11915_);
if (v___x_11916_ == 0)
{
uint64_t v___x_11917_; uint8_t v___x_11918_;
v___x_11917_ = 0ULL;
v___x_11918_ = lean_uint64_dec_eq(v_clientMsgId_11678_, v___x_11917_);
if (v___x_11918_ == 0)
{
v___y_11901_ = v___x_11916_;
v___y_11902_ = v___x_11917_;
v___y_11903_ = v___y_11914_;
v___y_11904_ = v___x_11915_;
v___y_11905_ = v___y_11914_;
goto v___jp_11900_;
}
else
{
v___y_11901_ = v___x_11916_;
v___y_11902_ = v___x_11917_;
v___y_11903_ = v___y_11914_;
v___y_11904_ = v___x_11915_;
v___y_11905_ = v___x_11916_;
goto v___jp_11900_;
}
}
else
{
goto v___jp_11717_;
}
}
}
}
}
}

LEAN_EXPORT uint64_t orb_transport_epoch_step(uint8_t v_mode_11951_, uint8_t v_eventKind_11952_, uint8_t v_everReady_11953_, uint8_t v_stickyUnsupported_11954_, uint8_t v_endpointClass_11955_, uint8_t v_prevEndpointClass_11956_, uint8_t v_hasSinceSeq_11957_, uint32_t v_failureStreak_11958_, uint32_t v_failThreshold_11959_, uint32_t v_httpStatus_11960_, uint32_t v_sinceSeq32_11961_, uint64_t v_nowMs_11962_, uint64_t v_cooldownUntilMs_11963_){
_start:
{
uint32_t v___y_11965_; uint32_t v___y_11966_; uint32_t v___y_11973_; uint32_t v___y_11974_; uint32_t v___y_11975_; uint32_t v___y_11976_; uint8_t v___y_11977_; uint8_t v___y_11978_; uint32_t v___y_11979_; uint32_t v___y_11980_; uint32_t v___y_11981_; uint32_t v___y_11993_; uint32_t v___y_11994_; uint32_t v___y_11995_; uint8_t v___y_11996_; uint8_t v___y_11997_; uint32_t v___y_11998_; uint32_t v___y_11999_; uint32_t v___y_12002_; uint8_t v___y_12003_; uint32_t v___y_12004_; uint8_t v___y_12005_; uint32_t v___y_12006_; uint32_t v___y_12007_; uint32_t v___y_12008_; uint32_t v___y_12013_; uint8_t v___y_12014_; uint8_t v___y_12015_; uint32_t v___y_12016_; uint32_t v___y_12017_; uint8_t v___y_12018_; uint32_t v___y_12019_; uint8_t v___y_12026_; uint8_t v___y_12027_; uint32_t v___y_12028_; uint32_t v___y_12029_; uint8_t v___y_12030_; uint8_t v___y_12034_; uint8_t v___y_12035_; uint32_t v___y_12036_; uint32_t v___y_12037_; uint8_t v___y_12038_; uint32_t v___y_12039_; uint8_t v___y_12042_; uint8_t v___y_12043_; uint32_t v___y_12044_; uint8_t v___y_12045_; uint32_t v___y_12046_; uint8_t v___y_12047_; uint8_t v___y_12050_; uint8_t v___y_12051_; uint32_t v___y_12052_; uint8_t v___y_12053_; uint32_t v___y_12054_; uint8_t v___y_12055_; uint8_t v___y_12058_; uint8_t v___y_12059_; uint32_t v___y_12060_; uint8_t v___y_12061_; uint32_t v___y_12062_; uint8_t v___y_12063_; uint8_t v___y_12064_; uint8_t v___x_12065_; uint8_t v___y_12067_; uint8_t v___y_12068_; uint32_t v___y_12069_; uint8_t v___y_12070_; uint32_t v___y_12071_; uint8_t v___y_12072_; uint8_t v___y_12073_; uint8_t v___y_12078_; uint8_t v___y_12079_; uint8_t v___y_12080_; uint8_t v___y_12081_; uint32_t v___y_12082_; uint8_t v___y_12083_; uint32_t v___y_12084_; uint32_t v___y_12085_; uint8_t v___y_12097_; uint8_t v___y_12098_; uint8_t v___y_12099_; uint8_t v___y_12100_; uint8_t v___y_12101_; uint32_t v___y_12102_; uint8_t v___y_12103_; uint32_t v___y_12104_; uint8_t v___y_12110_; uint8_t v___y_12111_; uint8_t v___y_12112_; uint8_t v___y_12113_; uint8_t v___y_12114_; uint32_t v___y_12115_; uint32_t v___y_12116_; uint8_t v___y_12117_; uint32_t v___y_12118_; uint8_t v___y_12119_; uint8_t v___y_12125_; uint8_t v___y_12126_; uint8_t v___y_12127_; uint8_t v___y_12128_; uint32_t v___y_12129_; uint8_t v___y_12130_; uint32_t v___y_12131_; uint32_t v___y_12132_; uint8_t v___y_12141_; uint8_t v___y_12142_; uint8_t v___y_12143_; uint8_t v___y_12144_; uint32_t v___y_12145_; uint8_t v___y_12146_; uint32_t v___y_12147_; uint8_t v___y_12150_; uint8_t v___y_12151_; uint8_t v___y_12152_; uint8_t v___y_12153_; uint8_t v___y_12154_; uint8_t v___y_12160_; uint8_t v___y_12161_; uint8_t v___y_12162_; uint8_t v___y_12163_; uint8_t v___y_12168_; uint8_t v___y_12169_; uint8_t v___y_12170_; uint8_t v___y_12173_; uint8_t v___y_12174_; uint8_t v___y_12175_; uint8_t v___y_12182_; uint8_t v___x_12187_;
v___x_12065_ = 2;
v___x_12187_ = lean_uint8_dec_le(v_mode_11951_, v___x_12065_);
if (v___x_12187_ == 0)
{
v___y_12182_ = v___x_12187_;
goto v___jp_12181_;
}
else
{
uint8_t v___x_12188_; uint8_t v___x_12189_;
v___x_12188_ = 4;
v___x_12189_ = lean_uint8_dec_le(v_eventKind_11952_, v___x_12188_);
if (v___x_12189_ == 0)
{
v___y_12182_ = v___x_12189_;
goto v___jp_12181_;
}
else
{
uint8_t v___x_12190_; uint8_t v___x_12191_;
v___x_12190_ = 1;
v___x_12191_ = lean_uint8_dec_le(v_everReady_11953_, v___x_12190_);
if (v___x_12191_ == 0)
{
v___y_12182_ = v___x_12191_;
goto v___jp_12181_;
}
else
{
uint8_t v___x_12192_;
v___x_12192_ = lean_uint8_dec_le(v_stickyUnsupported_11954_, v___x_12190_);
if (v___x_12192_ == 0)
{
v___y_12182_ = v___x_12192_;
goto v___jp_12181_;
}
else
{
uint8_t v___x_12193_; uint8_t v___x_12194_;
v___x_12193_ = 3;
v___x_12194_ = lean_uint8_dec_le(v_endpointClass_11955_, v___x_12193_);
if (v___x_12194_ == 0)
{
v___y_12182_ = v___x_12194_;
goto v___jp_12181_;
}
else
{
uint8_t v___x_12195_;
v___x_12195_ = lean_uint8_dec_le(v_prevEndpointClass_11956_, v___x_12193_);
if (v___x_12195_ == 0)
{
v___y_12182_ = v___x_12195_;
goto v___jp_12181_;
}
else
{
uint8_t v___x_12196_;
v___x_12196_ = lean_uint8_dec_le(v_hasSinceSeq_11957_, v___x_12190_);
if (v___x_12196_ == 0)
{
v___y_12182_ = v___x_12196_;
goto v___jp_12181_;
}
else
{
uint32_t v___x_12197_; uint8_t v___x_12198_;
v___x_12197_ = 1;
v___x_12198_ = lean_uint32_dec_le(v___x_12197_, v_failThreshold_11959_);
v___y_12182_ = v___x_12198_;
goto v___jp_12181_;
}
}
}
}
}
}
}
v___jp_11964_:
{
uint64_t v___x_11967_; uint64_t v___x_11968_; uint64_t v___x_11969_; uint64_t v___x_11970_; uint64_t v___x_11971_;
v___x_11967_ = lean_uint32_to_uint64(v___y_11966_);
v___x_11968_ = lean_uint32_to_uint64(v___y_11965_);
v___x_11969_ = 32ULL;
v___x_11970_ = lean_uint64_shift_left(v___x_11968_, v___x_11969_);
v___x_11971_ = lean_uint64_lor(v___x_11967_, v___x_11970_);
return v___x_11971_;
}
v___jp_11972_:
{
if (v___y_11978_ == 0)
{
uint32_t v___x_11982_; uint32_t v___x_11983_; uint32_t v___x_11984_; uint32_t v___x_11985_; uint32_t v___x_11986_; uint32_t v___x_11987_; uint32_t v___x_11988_; uint32_t v___x_11989_; uint32_t v___x_11990_; uint32_t v___x_11991_;
v___x_11982_ = lean_uint8_to_uint32(v___y_11977_);
v___x_11983_ = 256;
v___x_11984_ = lean_uint32_lor(v___x_11982_, v___x_11983_);
v___x_11985_ = lean_uint32_lor(v___x_11984_, v___y_11976_);
v___x_11986_ = lean_uint32_lor(v___x_11985_, v___y_11975_);
v___x_11987_ = lean_uint32_lor(v___x_11986_, v___y_11973_);
v___x_11988_ = lean_uint32_lor(v___x_11987_, v___y_11974_);
v___x_11989_ = 16;
v___x_11990_ = lean_uint32_shift_left(v___y_11979_, v___x_11989_);
v___x_11991_ = lean_uint32_lor(v___x_11988_, v___x_11990_);
v___y_11965_ = v___y_11981_;
v___y_11966_ = v___x_11991_;
goto v___jp_11964_;
}
else
{
v___y_11965_ = v___y_11981_;
v___y_11966_ = v___y_11980_;
goto v___jp_11964_;
}
}
v___jp_11992_:
{
uint32_t v___x_12000_;
v___x_12000_ = 0;
v___y_11973_ = v___y_11993_;
v___y_11974_ = v___x_12000_;
v___y_11975_ = v___y_11994_;
v___y_11976_ = v___y_11995_;
v___y_11977_ = v___y_11996_;
v___y_11978_ = v___y_11997_;
v___y_11979_ = v___y_11998_;
v___y_11980_ = v___y_11999_;
v___y_11981_ = v___x_12000_;
goto v___jp_11972_;
}
v___jp_12001_:
{
uint8_t v___x_12009_; uint8_t v___x_12010_;
v___x_12009_ = 1;
v___x_12010_ = lean_uint8_dec_eq(v_hasSinceSeq_11957_, v___x_12009_);
if (v___x_12010_ == 0)
{
v___y_11993_ = v___y_12002_;
v___y_11994_ = v___y_12008_;
v___y_11995_ = v___y_12004_;
v___y_11996_ = v___y_12003_;
v___y_11997_ = v___y_12005_;
v___y_11998_ = v___y_12006_;
v___y_11999_ = v___y_12007_;
goto v___jp_11992_;
}
else
{
uint32_t v___x_12011_;
v___x_12011_ = 4096;
v___y_11973_ = v___y_12002_;
v___y_11974_ = v___x_12011_;
v___y_11975_ = v___y_12008_;
v___y_11976_ = v___y_12004_;
v___y_11977_ = v___y_12003_;
v___y_11978_ = v___y_12005_;
v___y_11979_ = v___y_12006_;
v___y_11980_ = v___y_12007_;
v___y_11981_ = v_sinceSeq32_11961_;
goto v___jp_11972_;
}
}
v___jp_12012_:
{
if (v___y_12018_ == 0)
{
uint32_t v___x_12020_;
v___x_12020_ = 0;
v___y_11993_ = v___y_12013_;
v___y_11994_ = v___x_12020_;
v___y_11995_ = v___y_12019_;
v___y_11996_ = v___y_12014_;
v___y_11997_ = v___y_12015_;
v___y_11998_ = v___y_12016_;
v___y_11999_ = v___y_12017_;
goto v___jp_11992_;
}
else
{
uint8_t v___x_12021_; uint8_t v___x_12022_;
v___x_12021_ = 1;
v___x_12022_ = lean_uint8_dec_eq(v___y_12014_, v___x_12021_);
if (v___x_12022_ == 0)
{
uint32_t v___x_12023_;
v___x_12023_ = 0;
v___y_12002_ = v___y_12013_;
v___y_12003_ = v___y_12014_;
v___y_12004_ = v___y_12019_;
v___y_12005_ = v___y_12015_;
v___y_12006_ = v___y_12016_;
v___y_12007_ = v___y_12017_;
v___y_12008_ = v___x_12023_;
goto v___jp_12001_;
}
else
{
uint32_t v___x_12024_;
v___x_12024_ = 1024;
v___y_12002_ = v___y_12013_;
v___y_12003_ = v___y_12014_;
v___y_12004_ = v___y_12019_;
v___y_12005_ = v___y_12015_;
v___y_12006_ = v___y_12016_;
v___y_12007_ = v___y_12017_;
v___y_12008_ = v___x_12024_;
goto v___jp_12001_;
}
}
}
v___jp_12025_:
{
uint32_t v___x_12031_; uint32_t v___x_12032_;
v___x_12031_ = 0;
v___x_12032_ = 512;
v___y_12013_ = v___x_12031_;
v___y_12014_ = v___y_12026_;
v___y_12015_ = v___y_12027_;
v___y_12016_ = v___y_12028_;
v___y_12017_ = v___y_12029_;
v___y_12018_ = v___y_12030_;
v___y_12019_ = v___x_12032_;
goto v___jp_12012_;
}
v___jp_12033_:
{
uint32_t v___x_12040_;
v___x_12040_ = 0;
v___y_12013_ = v___y_12039_;
v___y_12014_ = v___y_12034_;
v___y_12015_ = v___y_12035_;
v___y_12016_ = v___y_12036_;
v___y_12017_ = v___y_12037_;
v___y_12018_ = v___y_12038_;
v___y_12019_ = v___x_12040_;
goto v___jp_12012_;
}
v___jp_12041_:
{
if (v___y_12045_ == 0)
{
uint32_t v___x_12048_;
v___x_12048_ = 2048;
v___y_12034_ = v___y_12042_;
v___y_12035_ = v___y_12043_;
v___y_12036_ = v___y_12044_;
v___y_12037_ = v___y_12046_;
v___y_12038_ = v___y_12047_;
v___y_12039_ = v___x_12048_;
goto v___jp_12033_;
}
else
{
v___y_12026_ = v___y_12042_;
v___y_12027_ = v___y_12043_;
v___y_12028_ = v___y_12044_;
v___y_12029_ = v___y_12046_;
v___y_12030_ = v___y_12047_;
goto v___jp_12025_;
}
}
v___jp_12049_:
{
if (v___y_12053_ == 0)
{
uint32_t v___x_12056_;
v___x_12056_ = 0;
v___y_12034_ = v___y_12050_;
v___y_12035_ = v___y_12051_;
v___y_12036_ = v___y_12052_;
v___y_12037_ = v___y_12054_;
v___y_12038_ = v___y_12055_;
v___y_12039_ = v___x_12056_;
goto v___jp_12033_;
}
else
{
v___y_12026_ = v___y_12050_;
v___y_12027_ = v___y_12051_;
v___y_12028_ = v___y_12052_;
v___y_12029_ = v___y_12054_;
v___y_12030_ = v___y_12055_;
goto v___jp_12025_;
}
}
v___jp_12057_:
{
if (v___y_12064_ == 0)
{
v___y_12050_ = v___y_12058_;
v___y_12051_ = v___y_12059_;
v___y_12052_ = v___y_12060_;
v___y_12053_ = v___y_12061_;
v___y_12054_ = v___y_12062_;
v___y_12055_ = v___y_12063_;
goto v___jp_12049_;
}
else
{
v___y_12042_ = v___y_12058_;
v___y_12043_ = v___y_12059_;
v___y_12044_ = v___y_12060_;
v___y_12045_ = v___y_12061_;
v___y_12046_ = v___y_12062_;
v___y_12047_ = v___y_12063_;
goto v___jp_12041_;
}
}
v___jp_12066_:
{
if (v___y_12072_ == 0)
{
v___y_12050_ = v___y_12073_;
v___y_12051_ = v___y_12067_;
v___y_12052_ = v___y_12069_;
v___y_12053_ = v___y_12070_;
v___y_12054_ = v___y_12071_;
v___y_12055_ = v___y_12072_;
goto v___jp_12049_;
}
else
{
uint8_t v___x_12074_; uint8_t v___x_12075_;
v___x_12074_ = 1;
v___x_12075_ = lean_uint8_dec_eq(v_mode_11951_, v___x_12074_);
if (v___x_12075_ == 0)
{
v___y_12058_ = v___y_12073_;
v___y_12059_ = v___y_12067_;
v___y_12060_ = v___y_12069_;
v___y_12061_ = v___y_12070_;
v___y_12062_ = v___y_12071_;
v___y_12063_ = v___y_12072_;
v___y_12064_ = v___y_12068_;
goto v___jp_12057_;
}
else
{
uint8_t v___x_12076_;
v___x_12076_ = lean_uint8_dec_eq(v___y_12073_, v___x_12065_);
if (v___x_12076_ == 0)
{
v___y_12058_ = v___y_12073_;
v___y_12059_ = v___y_12067_;
v___y_12060_ = v___y_12069_;
v___y_12061_ = v___y_12070_;
v___y_12062_ = v___y_12071_;
v___y_12063_ = v___y_12072_;
v___y_12064_ = v___y_12068_;
goto v___jp_12057_;
}
else
{
v___y_12042_ = v___y_12073_;
v___y_12043_ = v___y_12067_;
v___y_12044_ = v___y_12069_;
v___y_12045_ = v___y_12070_;
v___y_12046_ = v___y_12071_;
v___y_12047_ = v___y_12072_;
goto v___jp_12041_;
}
}
}
}
v___jp_12077_:
{
if (v___y_12081_ == 0)
{
uint8_t v___x_12086_; uint8_t v___x_12087_;
v___x_12086_ = 0;
v___x_12087_ = lean_uint8_dec_eq(v_eventKind_11952_, v___x_12086_);
if (v___x_12087_ == 0)
{
if (v___y_12079_ == 0)
{
uint8_t v___x_12088_; uint8_t v___x_12089_;
v___x_12088_ = 3;
v___x_12089_ = lean_uint8_dec_eq(v_eventKind_11952_, v___x_12088_);
if (v___x_12089_ == 0)
{
v___y_12067_ = v___y_12078_;
v___y_12068_ = v___y_12080_;
v___y_12069_ = v___y_12085_;
v___y_12070_ = v___y_12081_;
v___y_12071_ = v___y_12082_;
v___y_12072_ = v___y_12083_;
v___y_12073_ = v_mode_11951_;
goto v___jp_12066_;
}
else
{
uint8_t v___x_12090_; uint8_t v___x_12091_;
v___x_12090_ = 1;
v___x_12091_ = lean_uint8_dec_eq(v_mode_11951_, v___x_12090_);
if (v___x_12091_ == 0)
{
v___y_12067_ = v___y_12078_;
v___y_12068_ = v___y_12080_;
v___y_12069_ = v___y_12085_;
v___y_12070_ = v___y_12081_;
v___y_12071_ = v___y_12082_;
v___y_12072_ = v___y_12083_;
v___y_12073_ = v_mode_11951_;
goto v___jp_12066_;
}
else
{
uint8_t v___x_12092_;
v___x_12092_ = lean_uint64_dec_le(v_cooldownUntilMs_11963_, v_nowMs_11962_);
if (v___x_12092_ == 0)
{
v___y_12067_ = v___y_12078_;
v___y_12068_ = v___y_12080_;
v___y_12069_ = v___y_12085_;
v___y_12070_ = v___y_12081_;
v___y_12071_ = v___y_12082_;
v___y_12072_ = v___y_12083_;
v___y_12073_ = v_mode_11951_;
goto v___jp_12066_;
}
else
{
v___y_12067_ = v___y_12078_;
v___y_12068_ = v___y_12080_;
v___y_12069_ = v___y_12085_;
v___y_12070_ = v___y_12081_;
v___y_12071_ = v___y_12082_;
v___y_12072_ = v___y_12083_;
v___y_12073_ = v___x_12065_;
goto v___jp_12066_;
}
}
}
}
else
{
uint8_t v___x_12093_;
v___x_12093_ = lean_uint32_dec_le(v_failThreshold_11959_, v___y_12084_);
if (v___x_12093_ == 0)
{
v___y_12067_ = v___y_12078_;
v___y_12068_ = v___y_12080_;
v___y_12069_ = v___y_12085_;
v___y_12070_ = v___y_12081_;
v___y_12071_ = v___y_12082_;
v___y_12072_ = v___y_12083_;
v___y_12073_ = v___x_12086_;
goto v___jp_12066_;
}
else
{
uint8_t v___x_12094_;
v___x_12094_ = 1;
v___y_12067_ = v___y_12078_;
v___y_12068_ = v___y_12080_;
v___y_12069_ = v___y_12085_;
v___y_12070_ = v___y_12081_;
v___y_12071_ = v___y_12082_;
v___y_12072_ = v___y_12083_;
v___y_12073_ = v___x_12094_;
goto v___jp_12066_;
}
}
}
else
{
v___y_12067_ = v___y_12078_;
v___y_12068_ = v___y_12080_;
v___y_12069_ = v___y_12085_;
v___y_12070_ = v___y_12081_;
v___y_12071_ = v___y_12082_;
v___y_12072_ = v___y_12083_;
v___y_12073_ = v___x_12086_;
goto v___jp_12066_;
}
}
else
{
uint8_t v___x_12095_;
v___x_12095_ = 1;
v___y_12067_ = v___y_12078_;
v___y_12068_ = v___y_12080_;
v___y_12069_ = v___y_12085_;
v___y_12070_ = v___y_12081_;
v___y_12071_ = v___y_12082_;
v___y_12072_ = v___y_12083_;
v___y_12073_ = v___x_12095_;
goto v___jp_12066_;
}
}
v___jp_12096_:
{
uint32_t v___x_12105_;
v___x_12105_ = 0;
if (v___y_12097_ == 0)
{
v___y_12078_ = v___y_12098_;
v___y_12079_ = v___y_12100_;
v___y_12080_ = v___y_12099_;
v___y_12081_ = v___y_12101_;
v___y_12082_ = v___y_12102_;
v___y_12083_ = v___y_12103_;
v___y_12084_ = v___y_12104_;
v___y_12085_ = v___x_12105_;
goto v___jp_12077_;
}
else
{
uint8_t v___x_12106_; uint8_t v___x_12107_;
v___x_12106_ = 1;
v___x_12107_ = lean_uint8_dec_eq(v_mode_11951_, v___x_12106_);
if (v___x_12107_ == 0)
{
if (v___y_12099_ == 0)
{
uint8_t v___x_12108_;
v___x_12108_ = 0;
v___y_12067_ = v___y_12098_;
v___y_12068_ = v___y_12099_;
v___y_12069_ = v___x_12105_;
v___y_12070_ = v___y_12101_;
v___y_12071_ = v___y_12102_;
v___y_12072_ = v___y_12103_;
v___y_12073_ = v___x_12108_;
goto v___jp_12066_;
}
else
{
v___y_12067_ = v___y_12098_;
v___y_12068_ = v___y_12099_;
v___y_12069_ = v___x_12105_;
v___y_12070_ = v___y_12101_;
v___y_12071_ = v___y_12102_;
v___y_12072_ = v___y_12103_;
v___y_12073_ = v___x_12065_;
goto v___jp_12066_;
}
}
else
{
v___y_12067_ = v___y_12098_;
v___y_12068_ = v___y_12099_;
v___y_12069_ = v___x_12105_;
v___y_12070_ = v___y_12101_;
v___y_12071_ = v___y_12102_;
v___y_12072_ = v___y_12103_;
v___y_12073_ = v___x_12065_;
goto v___jp_12066_;
}
}
}
v___jp_12109_:
{
uint8_t v___x_12120_; uint8_t v___x_12121_;
v___x_12120_ = 0;
v___x_12121_ = lean_uint8_dec_eq(v_eventKind_11952_, v___x_12120_);
if (v___x_12121_ == 0)
{
if (v___y_12110_ == 0)
{
if (v___y_12114_ == 0)
{
if (v___y_12113_ == 0)
{
uint8_t v___x_12122_;
v___x_12122_ = lean_uint32_dec_le(v_failureStreak_11958_, v___y_12115_);
if (v___x_12122_ == 0)
{
v___y_12078_ = v___y_12111_;
v___y_12079_ = v___y_12113_;
v___y_12080_ = v___y_12112_;
v___y_12081_ = v___y_12119_;
v___y_12082_ = v___y_12115_;
v___y_12083_ = v___y_12117_;
v___y_12084_ = v___y_12118_;
v___y_12085_ = v___y_12115_;
goto v___jp_12077_;
}
else
{
v___y_12078_ = v___y_12111_;
v___y_12079_ = v___y_12113_;
v___y_12080_ = v___y_12112_;
v___y_12081_ = v___y_12119_;
v___y_12082_ = v___y_12115_;
v___y_12083_ = v___y_12117_;
v___y_12084_ = v___y_12118_;
v___y_12085_ = v_failureStreak_11958_;
goto v___jp_12077_;
}
}
else
{
v___y_12078_ = v___y_12111_;
v___y_12079_ = v___y_12113_;
v___y_12080_ = v___y_12112_;
v___y_12081_ = v___y_12119_;
v___y_12082_ = v___y_12115_;
v___y_12083_ = v___y_12117_;
v___y_12084_ = v___y_12118_;
v___y_12085_ = v___y_12118_;
goto v___jp_12077_;
}
}
else
{
uint8_t v___x_12123_;
v___x_12123_ = lean_uint32_dec_le(v___y_12116_, v___y_12118_);
if (v___x_12123_ == 0)
{
v___y_12078_ = v___y_12111_;
v___y_12079_ = v___y_12113_;
v___y_12080_ = v___y_12112_;
v___y_12081_ = v___y_12119_;
v___y_12082_ = v___y_12115_;
v___y_12083_ = v___y_12117_;
v___y_12084_ = v___y_12118_;
v___y_12085_ = v___y_12116_;
goto v___jp_12077_;
}
else
{
v___y_12078_ = v___y_12111_;
v___y_12079_ = v___y_12113_;
v___y_12080_ = v___y_12112_;
v___y_12081_ = v___y_12119_;
v___y_12082_ = v___y_12115_;
v___y_12083_ = v___y_12117_;
v___y_12084_ = v___y_12118_;
v___y_12085_ = v___y_12118_;
goto v___jp_12077_;
}
}
}
else
{
v___y_12097_ = v___y_12110_;
v___y_12098_ = v___y_12111_;
v___y_12099_ = v___y_12112_;
v___y_12100_ = v___y_12113_;
v___y_12101_ = v___y_12119_;
v___y_12102_ = v___y_12115_;
v___y_12103_ = v___y_12117_;
v___y_12104_ = v___y_12118_;
goto v___jp_12096_;
}
}
else
{
v___y_12097_ = v___y_12110_;
v___y_12098_ = v___y_12111_;
v___y_12099_ = v___y_12112_;
v___y_12100_ = v___y_12113_;
v___y_12101_ = v___y_12119_;
v___y_12102_ = v___y_12115_;
v___y_12103_ = v___y_12117_;
v___y_12104_ = v___y_12118_;
goto v___jp_12096_;
}
}
v___jp_12124_:
{
if (v___y_12130_ == 0)
{
uint8_t v___x_12133_; uint8_t v___x_12134_; uint8_t v___x_12135_; uint8_t v___x_12136_;
v___x_12133_ = 1;
v___x_12134_ = 1;
v___x_12135_ = lean_uint8_dec_eq(v_stickyUnsupported_11954_, v___x_12134_);
v___x_12136_ = lean_uint32_dec_le(v_failureStreak_11958_, v___y_12129_);
if (v___x_12136_ == 0)
{
v___y_12050_ = v_mode_11951_;
v___y_12051_ = v___x_12133_;
v___y_12052_ = v___y_12129_;
v___y_12053_ = v___x_12135_;
v___y_12054_ = v___y_12129_;
v___y_12055_ = v___y_12130_;
goto v___jp_12049_;
}
else
{
v___y_12050_ = v_mode_11951_;
v___y_12051_ = v___x_12133_;
v___y_12052_ = v_failureStreak_11958_;
v___y_12053_ = v___x_12135_;
v___y_12054_ = v___y_12129_;
v___y_12055_ = v___y_12130_;
goto v___jp_12049_;
}
}
else
{
uint8_t v___x_12137_;
v___x_12137_ = 0;
if (v___y_12125_ == 0)
{
if (v___y_12128_ == 0)
{
uint8_t v___x_12138_; uint8_t v___x_12139_;
v___x_12138_ = 1;
v___x_12139_ = lean_uint8_dec_eq(v_stickyUnsupported_11954_, v___x_12138_);
v___y_12110_ = v___y_12125_;
v___y_12111_ = v___x_12137_;
v___y_12112_ = v___y_12126_;
v___y_12113_ = v___y_12127_;
v___y_12114_ = v___y_12128_;
v___y_12115_ = v___y_12129_;
v___y_12116_ = v___y_12132_;
v___y_12117_ = v___y_12130_;
v___y_12118_ = v___y_12131_;
v___y_12119_ = v___x_12139_;
goto v___jp_12109_;
}
else
{
v___y_12110_ = v___y_12125_;
v___y_12111_ = v___x_12137_;
v___y_12112_ = v___y_12126_;
v___y_12113_ = v___y_12127_;
v___y_12114_ = v___y_12128_;
v___y_12115_ = v___y_12129_;
v___y_12116_ = v___y_12132_;
v___y_12117_ = v___y_12130_;
v___y_12118_ = v___y_12131_;
v___y_12119_ = v___y_12128_;
goto v___jp_12109_;
}
}
else
{
v___y_12110_ = v___y_12125_;
v___y_12111_ = v___x_12137_;
v___y_12112_ = v___y_12126_;
v___y_12113_ = v___y_12127_;
v___y_12114_ = v___y_12128_;
v___y_12115_ = v___y_12129_;
v___y_12116_ = v___y_12132_;
v___y_12117_ = v___y_12130_;
v___y_12118_ = v___y_12131_;
v___y_12119_ = v___x_12137_;
goto v___jp_12109_;
}
}
}
v___jp_12140_:
{
uint8_t v___x_12148_;
v___x_12148_ = lean_uint32_dec_le(v_failThreshold_11959_, v___y_12145_);
if (v___x_12148_ == 0)
{
v___y_12125_ = v___y_12141_;
v___y_12126_ = v___y_12143_;
v___y_12127_ = v___y_12142_;
v___y_12128_ = v___y_12144_;
v___y_12129_ = v___y_12145_;
v___y_12130_ = v___y_12146_;
v___y_12131_ = v___y_12147_;
v___y_12132_ = v___y_12145_;
goto v___jp_12124_;
}
else
{
v___y_12125_ = v___y_12141_;
v___y_12126_ = v___y_12143_;
v___y_12127_ = v___y_12142_;
v___y_12128_ = v___y_12144_;
v___y_12129_ = v___y_12145_;
v___y_12130_ = v___y_12146_;
v___y_12131_ = v___y_12147_;
v___y_12132_ = v_failThreshold_11959_;
goto v___jp_12124_;
}
}
v___jp_12149_:
{
uint32_t v___x_12155_; uint8_t v___x_12156_;
v___x_12155_ = 255;
v___x_12156_ = lean_uint32_dec_lt(v_failureStreak_11958_, v___x_12155_);
if (v___x_12156_ == 0)
{
v___y_12141_ = v___y_12150_;
v___y_12142_ = v___y_12154_;
v___y_12143_ = v___y_12151_;
v___y_12144_ = v___y_12152_;
v___y_12145_ = v___x_12155_;
v___y_12146_ = v___y_12153_;
v___y_12147_ = v___x_12155_;
goto v___jp_12140_;
}
else
{
uint32_t v___x_12157_; uint32_t v___x_12158_;
v___x_12157_ = 1;
v___x_12158_ = lean_uint32_add(v_failureStreak_11958_, v___x_12157_);
v___y_12141_ = v___y_12150_;
v___y_12142_ = v___y_12154_;
v___y_12143_ = v___y_12151_;
v___y_12144_ = v___y_12152_;
v___y_12145_ = v___x_12155_;
v___y_12146_ = v___y_12153_;
v___y_12147_ = v___x_12158_;
goto v___jp_12140_;
}
}
v___jp_12159_:
{
uint8_t v___x_12164_; uint8_t v___x_12165_;
v___x_12164_ = 1;
v___x_12165_ = lean_uint8_dec_eq(v_eventKind_11952_, v___x_12164_);
if (v___x_12165_ == 0)
{
uint8_t v___x_12166_;
v___x_12166_ = lean_uint8_dec_eq(v_eventKind_11952_, v___x_12065_);
if (v___x_12166_ == 0)
{
v___y_12150_ = v___y_12160_;
v___y_12151_ = v___y_12161_;
v___y_12152_ = v___y_12163_;
v___y_12153_ = v___y_12162_;
v___y_12154_ = v___x_12166_;
goto v___jp_12149_;
}
else
{
if (v___y_12163_ == 0)
{
v___y_12150_ = v___y_12160_;
v___y_12151_ = v___y_12161_;
v___y_12152_ = v___y_12163_;
v___y_12153_ = v___y_12162_;
v___y_12154_ = v___x_12166_;
goto v___jp_12149_;
}
else
{
v___y_12150_ = v___y_12160_;
v___y_12151_ = v___y_12161_;
v___y_12152_ = v___y_12163_;
v___y_12153_ = v___y_12162_;
v___y_12154_ = v___x_12165_;
goto v___jp_12149_;
}
}
}
else
{
v___y_12150_ = v___y_12160_;
v___y_12151_ = v___y_12161_;
v___y_12152_ = v___y_12163_;
v___y_12153_ = v___y_12162_;
v___y_12154_ = v___x_12165_;
goto v___jp_12149_;
}
}
v___jp_12167_:
{
uint8_t v___x_12171_;
v___x_12171_ = 0;
v___y_12150_ = v___y_12170_;
v___y_12151_ = v___y_12168_;
v___y_12152_ = v___x_12171_;
v___y_12153_ = v___y_12169_;
v___y_12154_ = v___x_12171_;
goto v___jp_12149_;
}
v___jp_12172_:
{
if (v___y_12175_ == 0)
{
uint8_t v___x_12176_;
v___x_12176_ = lean_uint8_dec_eq(v_eventKind_11952_, v___x_12065_);
if (v___x_12176_ == 0)
{
v___y_12160_ = v___y_12175_;
v___y_12161_ = v___y_12173_;
v___y_12162_ = v___y_12174_;
v___y_12163_ = v___x_12176_;
goto v___jp_12159_;
}
else
{
uint32_t v___x_12177_; uint8_t v___x_12178_;
v___x_12177_ = 404;
v___x_12178_ = lean_uint32_dec_eq(v_httpStatus_11960_, v___x_12177_);
if (v___x_12178_ == 0)
{
uint32_t v___x_12179_; uint8_t v___x_12180_;
v___x_12179_ = 501;
v___x_12180_ = lean_uint32_dec_eq(v_httpStatus_11960_, v___x_12179_);
v___y_12160_ = v___y_12175_;
v___y_12161_ = v___y_12173_;
v___y_12162_ = v___y_12174_;
v___y_12163_ = v___x_12180_;
goto v___jp_12159_;
}
else
{
v___y_12160_ = v___y_12175_;
v___y_12161_ = v___y_12173_;
v___y_12162_ = v___y_12174_;
v___y_12163_ = v___x_12178_;
goto v___jp_12159_;
}
}
}
else
{
v___y_12168_ = v___y_12173_;
v___y_12169_ = v___y_12174_;
v___y_12170_ = v___y_12175_;
goto v___jp_12167_;
}
}
v___jp_12181_:
{
uint8_t v___x_12183_; uint8_t v___x_12184_;
v___x_12183_ = 4;
v___x_12184_ = lean_uint8_dec_eq(v_eventKind_11952_, v___x_12183_);
if (v___x_12184_ == 0)
{
uint8_t v___x_12185_;
v___x_12185_ = lean_uint8_dec_eq(v_endpointClass_11955_, v_prevEndpointClass_11956_);
if (v___x_12185_ == 0)
{
uint8_t v___x_12186_;
v___x_12186_ = 1;
v___y_12168_ = v___x_12184_;
v___y_12169_ = v___y_12182_;
v___y_12170_ = v___x_12186_;
goto v___jp_12167_;
}
else
{
v___y_12173_ = v___x_12184_;
v___y_12174_ = v___y_12182_;
v___y_12175_ = v___x_12184_;
goto v___jp_12172_;
}
}
else
{
v___y_12173_ = v___x_12184_;
v___y_12174_ = v___y_12182_;
v___y_12175_ = v___x_12184_;
goto v___jp_12172_;
}
}
}
}

LEAN_EXPORT uint64_t orb_stream_open_tail_cap_step(uint32_t v_prevLen_12227_, uint32_t v_prevCommit_12228_, uint32_t v_prevCheckpoint_12229_, uint32_t v_newLen_12230_, uint32_t v_rawCommit_12231_, uint32_t v_maxOpenTailBytes_12232_, uint8_t v_openFenceActive_12233_){
_start:
{
uint64_t v___y_12235_; uint32_t v___y_12236_; uint32_t v___y_12237_; uint8_t v___x_12242_; uint8_t v_validFlags_12243_; uint32_t v___x_12244_; uint32_t v___y_12246_; uint32_t v___y_12247_; uint64_t v___y_12248_; uint8_t v___y_12249_; uint32_t v___y_12250_; uint32_t v___y_12253_; uint32_t v___y_12254_; uint64_t v___y_12255_; uint8_t v___y_12256_; uint8_t v___y_12257_; uint32_t v___y_12261_; uint32_t v___y_12262_; uint64_t v___y_12263_; uint8_t v___y_12264_; uint32_t v___y_12271_; uint32_t v___y_12272_; uint64_t v___y_12273_; uint8_t v___y_12274_; uint32_t v___y_12276_; uint32_t v___y_12277_; uint8_t v_validCap_12293_; uint8_t v___y_12295_; uint32_t v___y_12296_; uint32_t v___y_12297_; uint8_t v___y_12301_; uint32_t v___y_12302_; uint32_t v___y_12303_; uint8_t v___y_12307_; uint32_t v___y_12308_; uint32_t v___y_12309_; uint32_t v___y_12310_; uint8_t v___y_12313_; uint32_t v___y_12314_; uint32_t v___y_12315_; uint8_t v___y_12319_; uint32_t v___y_12320_; uint8_t v___y_12323_; uint32_t v___y_12324_; uint8_t v___y_12327_; uint8_t v___x_12329_;
v___x_12242_ = 1;
v_validFlags_12243_ = lean_uint8_dec_le(v_openFenceActive_12233_, v___x_12242_);
v___x_12244_ = 0;
v_validCap_12293_ = lean_uint32_dec_lt(v___x_12244_, v_maxOpenTailBytes_12232_);
v___x_12329_ = lean_uint32_dec_le(v_prevCommit_12228_, v_prevCheckpoint_12229_);
if (v___x_12329_ == 0)
{
v___y_12327_ = v___x_12329_;
goto v___jp_12326_;
}
else
{
uint8_t v___x_12330_;
v___x_12330_ = lean_uint32_dec_le(v_prevCheckpoint_12229_, v_prevLen_12227_);
if (v___x_12330_ == 0)
{
v___y_12327_ = v___x_12330_;
goto v___jp_12326_;
}
else
{
uint8_t v___x_12331_;
v___x_12331_ = lean_uint32_dec_le(v_prevLen_12227_, v_newLen_12230_);
v___y_12327_ = v___x_12331_;
goto v___jp_12326_;
}
}
v___jp_12234_:
{
uint64_t v___x_12238_; uint64_t v___x_12239_; uint64_t v___x_12240_; uint64_t v___x_12241_;
v___x_12238_ = lean_uint32_to_uint64(v___y_12236_);
v___x_12239_ = lean_uint32_to_uint64(v___y_12237_);
v___x_12240_ = lean_uint64_shift_left(v___x_12239_, v___y_12235_);
v___x_12241_ = lean_uint64_lor(v___x_12238_, v___x_12240_);
return v___x_12241_;
}
v___jp_12245_:
{
if (v___y_12249_ == 0)
{
v___y_12235_ = v___y_12248_;
v___y_12236_ = v___x_12244_;
v___y_12237_ = v_prevCheckpoint_12229_;
goto v___jp_12234_;
}
else
{
uint32_t v___x_12251_;
v___x_12251_ = lean_uint32_lor(v___y_12247_, v___y_12250_);
v___y_12235_ = v___y_12248_;
v___y_12236_ = v___x_12251_;
v___y_12237_ = v___y_12246_;
goto v___jp_12234_;
}
}
v___jp_12252_:
{
uint8_t v___x_12258_;
v___x_12258_ = lean_uint8_dec_eq(v_openFenceActive_12233_, v___x_12242_);
if (v___x_12258_ == 0)
{
v___y_12246_ = v___y_12253_;
v___y_12247_ = v___y_12254_;
v___y_12248_ = v___y_12255_;
v___y_12249_ = v___y_12256_;
v___y_12250_ = v___x_12244_;
goto v___jp_12245_;
}
else
{
if (v___y_12257_ == 0)
{
v___y_12246_ = v___y_12253_;
v___y_12247_ = v___y_12254_;
v___y_12248_ = v___y_12255_;
v___y_12249_ = v___y_12256_;
v___y_12250_ = v___x_12244_;
goto v___jp_12245_;
}
else
{
uint32_t v___x_12259_;
v___x_12259_ = 1024;
v___y_12246_ = v___y_12253_;
v___y_12247_ = v___y_12254_;
v___y_12248_ = v___y_12255_;
v___y_12249_ = v___y_12256_;
v___y_12250_ = v___x_12259_;
goto v___jp_12245_;
}
}
}
v___jp_12260_:
{
uint32_t v___x_12265_; uint32_t v___x_12266_; uint8_t v___x_12267_;
v___x_12265_ = 512;
v___x_12266_ = lean_uint32_land(v___y_12262_, v___x_12265_);
v___x_12267_ = lean_uint32_dec_eq(v___x_12266_, v___x_12244_);
if (v___x_12267_ == 0)
{
uint8_t v___x_12268_;
v___x_12268_ = 1;
v___y_12253_ = v___y_12261_;
v___y_12254_ = v___y_12262_;
v___y_12255_ = v___y_12263_;
v___y_12256_ = v___y_12264_;
v___y_12257_ = v___x_12268_;
goto v___jp_12252_;
}
else
{
uint8_t v___x_12269_;
v___x_12269_ = 0;
v___y_12253_ = v___y_12261_;
v___y_12254_ = v___y_12262_;
v___y_12255_ = v___y_12263_;
v___y_12256_ = v___y_12264_;
v___y_12257_ = v___x_12269_;
goto v___jp_12252_;
}
}
v___jp_12270_:
{
if (v_validFlags_12243_ == 0)
{
v___y_12261_ = v___y_12271_;
v___y_12262_ = v___y_12272_;
v___y_12263_ = v___y_12273_;
v___y_12264_ = v_validFlags_12243_;
goto v___jp_12260_;
}
else
{
v___y_12261_ = v___y_12271_;
v___y_12262_ = v___y_12272_;
v___y_12263_ = v___y_12273_;
v___y_12264_ = v___y_12274_;
goto v___jp_12260_;
}
}
v___jp_12275_:
{
uint64_t v___x_12278_; uint64_t v___x_12279_; uint64_t v___x_12280_; uint64_t v___x_12281_; uint64_t v___x_12282_; uint64_t v___x_12283_; uint64_t v___x_12284_; uint32_t v_baseLo_12285_; uint64_t v___x_12286_; uint32_t v_nextCheckpoint_12287_; uint32_t v___x_12288_; uint32_t v___x_12289_; uint8_t v___x_12290_;
v___x_12278_ = lean_uint32_to_uint64(v___y_12276_);
v___x_12279_ = lean_uint32_to_uint64(v___y_12277_);
v___x_12280_ = 32ULL;
v___x_12281_ = lean_uint64_shift_left(v___x_12279_, v___x_12280_);
v___x_12282_ = lean_uint64_lor(v___x_12278_, v___x_12281_);
v___x_12283_ = 4294967295ULL;
v___x_12284_ = lean_uint64_land(v___x_12282_, v___x_12283_);
v_baseLo_12285_ = lean_uint64_to_uint32(v___x_12284_);
v___x_12286_ = lean_uint64_shift_right(v___x_12282_, v___x_12280_);
v_nextCheckpoint_12287_ = lean_uint64_to_uint32(v___x_12286_);
v___x_12288_ = 256;
v___x_12289_ = lean_uint32_land(v_baseLo_12285_, v___x_12288_);
v___x_12290_ = lean_uint32_dec_eq(v___x_12289_, v___x_12244_);
if (v___x_12290_ == 0)
{
uint8_t v___x_12291_;
v___x_12291_ = 1;
v___y_12271_ = v_nextCheckpoint_12287_;
v___y_12272_ = v_baseLo_12285_;
v___y_12273_ = v___x_12280_;
v___y_12274_ = v___x_12291_;
goto v___jp_12270_;
}
else
{
uint8_t v___x_12292_;
v___x_12292_ = 0;
v___y_12271_ = v_nextCheckpoint_12287_;
v___y_12272_ = v_baseLo_12285_;
v___y_12273_ = v___x_12280_;
v___y_12274_ = v___x_12292_;
goto v___jp_12270_;
}
}
v___jp_12294_:
{
if (v_validCap_12293_ == 0)
{
v___y_12276_ = v___x_12244_;
v___y_12277_ = v_prevCheckpoint_12229_;
goto v___jp_12275_;
}
else
{
if (v___y_12295_ == 0)
{
v___y_12276_ = v___x_12244_;
v___y_12277_ = v_prevCheckpoint_12229_;
goto v___jp_12275_;
}
else
{
uint32_t v___x_12298_; uint32_t v___x_12299_;
v___x_12298_ = 257;
v___x_12299_ = lean_uint32_lor(v___x_12298_, v___y_12297_);
v___y_12276_ = v___x_12299_;
v___y_12277_ = v___y_12296_;
goto v___jp_12275_;
}
}
}
v___jp_12300_:
{
uint8_t v___x_12304_;
v___x_12304_ = lean_uint32_dec_lt(v___y_12302_, v___y_12303_);
if (v___x_12304_ == 0)
{
v___y_12295_ = v___y_12301_;
v___y_12296_ = v___y_12303_;
v___y_12297_ = v___x_12244_;
goto v___jp_12294_;
}
else
{
uint32_t v___x_12305_;
v___x_12305_ = 512;
v___y_12295_ = v___y_12301_;
v___y_12296_ = v___y_12303_;
v___y_12297_ = v___x_12305_;
goto v___jp_12294_;
}
}
v___jp_12306_:
{
uint8_t v___x_12311_;
v___x_12311_ = lean_uint32_dec_le(v___y_12309_, v___y_12310_);
if (v___x_12311_ == 0)
{
v___y_12301_ = v___y_12307_;
v___y_12302_ = v___y_12308_;
v___y_12303_ = v___y_12309_;
goto v___jp_12300_;
}
else
{
v___y_12301_ = v___y_12307_;
v___y_12302_ = v___y_12308_;
v___y_12303_ = v___y_12310_;
goto v___jp_12300_;
}
}
v___jp_12312_:
{
uint8_t v___x_12316_;
v___x_12316_ = lean_uint32_dec_le(v_maxOpenTailBytes_12232_, v_newLen_12230_);
if (v___x_12316_ == 0)
{
v___y_12307_ = v___y_12313_;
v___y_12308_ = v___y_12314_;
v___y_12309_ = v___y_12315_;
v___y_12310_ = v___x_12244_;
goto v___jp_12306_;
}
else
{
uint32_t v___x_12317_;
v___x_12317_ = lean_uint32_sub(v_newLen_12230_, v_maxOpenTailBytes_12232_);
v___y_12307_ = v___y_12313_;
v___y_12308_ = v___y_12314_;
v___y_12309_ = v___y_12315_;
v___y_12310_ = v___x_12317_;
goto v___jp_12306_;
}
}
v___jp_12318_:
{
uint8_t v___x_12321_;
v___x_12321_ = lean_uint32_dec_le(v_prevCheckpoint_12229_, v___y_12320_);
if (v___x_12321_ == 0)
{
v___y_12313_ = v___y_12319_;
v___y_12314_ = v___y_12320_;
v___y_12315_ = v_prevCheckpoint_12229_;
goto v___jp_12312_;
}
else
{
v___y_12313_ = v___y_12319_;
v___y_12314_ = v___y_12320_;
v___y_12315_ = v___y_12320_;
goto v___jp_12312_;
}
}
v___jp_12322_:
{
uint8_t v___x_12325_;
v___x_12325_ = lean_uint32_dec_le(v_prevCommit_12228_, v___y_12324_);
if (v___x_12325_ == 0)
{
v___y_12319_ = v___y_12323_;
v___y_12320_ = v_prevCommit_12228_;
goto v___jp_12318_;
}
else
{
v___y_12319_ = v___y_12323_;
v___y_12320_ = v___y_12324_;
goto v___jp_12318_;
}
}
v___jp_12326_:
{
uint8_t v___x_12328_;
v___x_12328_ = lean_uint32_dec_le(v_rawCommit_12231_, v_newLen_12230_);
if (v___x_12328_ == 0)
{
v___y_12323_ = v___y_12327_;
v___y_12324_ = v_newLen_12230_;
goto v___jp_12322_;
}
else
{
v___y_12323_ = v___y_12327_;
v___y_12324_ = v_rawCommit_12231_;
goto v___jp_12322_;
}
}
}
}

LEAN_EXPORT uint64_t orb_rtt_ewma_step(uint32_t v_srttMs_12348_, uint32_t v_rttVarMs_12349_, uint32_t v_sampleMs_12350_){
_start:
{
uint32_t v___y_12352_; uint32_t v___y_12353_; uint32_t v___y_12360_; uint32_t v___y_12361_; uint64_t v___y_12368_; uint32_t v___y_12369_; uint64_t v___y_12370_; uint64_t v___y_12371_; uint32_t v___y_12372_; uint64_t v___y_12384_; uint64_t v___y_12385_; uint32_t v___y_12386_; uint64_t v___y_12387_; uint64_t v___y_12388_; uint64_t v___y_12401_; uint32_t v___y_12402_; uint32_t v___y_12403_; uint64_t v___y_12404_; uint32_t v___y_12410_; uint32_t v___y_12411_; uint64_t v___y_12412_; uint32_t v___x_12416_; uint32_t v___y_12418_; uint8_t v___x_12428_;
v___x_12416_ = 0;
v___x_12428_ = lean_uint32_dec_eq(v_sampleMs_12350_, v___x_12416_);
if (v___x_12428_ == 0)
{
uint32_t v___x_12429_; uint8_t v___x_12430_;
v___x_12429_ = 60000;
v___x_12430_ = lean_uint32_dec_lt(v___x_12429_, v_sampleMs_12350_);
if (v___x_12430_ == 0)
{
v___y_12418_ = v_sampleMs_12350_;
goto v___jp_12417_;
}
else
{
v___y_12418_ = v___x_12429_;
goto v___jp_12417_;
}
}
else
{
uint32_t v___x_12431_;
v___x_12431_ = 1;
v___y_12418_ = v___x_12431_;
goto v___jp_12417_;
}
v___jp_12351_:
{
uint64_t v___x_12354_; uint64_t v___x_12355_; uint64_t v___x_12356_; uint64_t v___x_12357_; uint64_t v___x_12358_;
v___x_12354_ = lean_uint32_to_uint64(v___y_12352_);
v___x_12355_ = lean_uint32_to_uint64(v___y_12353_);
v___x_12356_ = 32ULL;
v___x_12357_ = lean_uint64_shift_left(v___x_12355_, v___x_12356_);
v___x_12358_ = lean_uint64_lor(v___x_12354_, v___x_12357_);
return v___x_12358_;
}
v___jp_12359_:
{
uint64_t v___x_12362_; uint64_t v___x_12363_; uint64_t v___x_12364_; uint64_t v___x_12365_; uint64_t v___x_12366_;
v___x_12362_ = lean_uint32_to_uint64(v___y_12361_);
v___x_12363_ = lean_uint32_to_uint64(v___y_12360_);
v___x_12364_ = 32ULL;
v___x_12365_ = lean_uint64_shift_left(v___x_12363_, v___x_12364_);
v___x_12366_ = lean_uint64_lor(v___x_12362_, v___x_12365_);
return v___x_12366_;
}
v___jp_12367_:
{
uint64_t v___x_12373_; uint64_t v___x_12374_; uint64_t v___x_12375_; uint64_t v_rawSrtt_12376_; uint64_t v___x_12377_; uint8_t v___x_12378_;
v___x_12373_ = 7ULL;
v___x_12374_ = lean_uint64_mul(v___x_12373_, v___y_12368_);
v___x_12375_ = lean_uint64_add(v___x_12374_, v___y_12371_);
v_rawSrtt_12376_ = lean_uint64_shift_right(v___x_12375_, v___y_12370_);
v___x_12377_ = 1ULL;
v___x_12378_ = lean_uint64_dec_lt(v_rawSrtt_12376_, v___x_12377_);
if (v___x_12378_ == 0)
{
uint64_t v___x_12379_; uint8_t v___x_12380_;
v___x_12379_ = 60000ULL;
v___x_12380_ = lean_uint64_dec_lt(v___x_12379_, v_rawSrtt_12376_);
if (v___x_12380_ == 0)
{
uint32_t v___x_12381_;
v___x_12381_ = lean_uint64_to_uint32(v_rawSrtt_12376_);
v___y_12360_ = v___y_12372_;
v___y_12361_ = v___x_12381_;
goto v___jp_12359_;
}
else
{
v___y_12360_ = v___y_12372_;
v___y_12361_ = v___y_12369_;
goto v___jp_12359_;
}
}
else
{
uint32_t v___x_12382_;
v___x_12382_ = 1;
v___y_12360_ = v___y_12372_;
v___y_12361_ = v___x_12382_;
goto v___jp_12359_;
}
}
v___jp_12383_:
{
uint64_t v___x_12389_; uint64_t v___x_12390_; uint64_t v___x_12391_; uint64_t v___x_12392_; uint64_t v_rawVar_12393_; uint64_t v___x_12394_; uint8_t v___x_12395_;
v___x_12389_ = 3ULL;
v___x_12390_ = lean_uint64_mul(v___x_12389_, v___y_12384_);
v___x_12391_ = lean_uint64_add(v___x_12390_, v___y_12388_);
v___x_12392_ = 2ULL;
v_rawVar_12393_ = lean_uint64_shift_right(v___x_12391_, v___x_12392_);
v___x_12394_ = 10ULL;
v___x_12395_ = lean_uint64_dec_lt(v_rawVar_12393_, v___x_12394_);
if (v___x_12395_ == 0)
{
uint64_t v___x_12396_; uint8_t v___x_12397_;
v___x_12396_ = 60000ULL;
v___x_12397_ = lean_uint64_dec_lt(v___x_12396_, v_rawVar_12393_);
if (v___x_12397_ == 0)
{
uint32_t v___x_12398_;
v___x_12398_ = lean_uint64_to_uint32(v_rawVar_12393_);
v___y_12368_ = v___y_12385_;
v___y_12369_ = v___y_12386_;
v___y_12370_ = v___x_12389_;
v___y_12371_ = v___y_12387_;
v___y_12372_ = v___x_12398_;
goto v___jp_12367_;
}
else
{
v___y_12368_ = v___y_12385_;
v___y_12369_ = v___y_12386_;
v___y_12370_ = v___x_12389_;
v___y_12371_ = v___y_12387_;
v___y_12372_ = v___y_12386_;
goto v___jp_12367_;
}
}
else
{
uint32_t v___x_12399_;
v___x_12399_ = 10;
v___y_12368_ = v___y_12385_;
v___y_12369_ = v___y_12386_;
v___y_12370_ = v___x_12389_;
v___y_12371_ = v___y_12387_;
v___y_12372_ = v___x_12399_;
goto v___jp_12367_;
}
}
v___jp_12400_:
{
uint64_t v_sample64_12405_; uint8_t v___x_12406_;
v_sample64_12405_ = lean_uint32_to_uint64(v___y_12402_);
v___x_12406_ = lean_uint64_dec_le(v_sample64_12405_, v___y_12401_);
if (v___x_12406_ == 0)
{
uint64_t v___x_12407_;
v___x_12407_ = lean_uint64_sub(v_sample64_12405_, v___y_12401_);
v___y_12384_ = v___y_12404_;
v___y_12385_ = v___y_12401_;
v___y_12386_ = v___y_12403_;
v___y_12387_ = v_sample64_12405_;
v___y_12388_ = v___x_12407_;
goto v___jp_12383_;
}
else
{
uint64_t v___x_12408_;
v___x_12408_ = lean_uint64_sub(v___y_12401_, v_sample64_12405_);
v___y_12384_ = v___y_12404_;
v___y_12385_ = v___y_12401_;
v___y_12386_ = v___y_12403_;
v___y_12387_ = v_sample64_12405_;
v___y_12388_ = v___x_12408_;
goto v___jp_12383_;
}
}
v___jp_12409_:
{
uint8_t v___x_12413_;
v___x_12413_ = lean_uint32_dec_lt(v___y_12411_, v_rttVarMs_12349_);
if (v___x_12413_ == 0)
{
uint64_t v___x_12414_;
v___x_12414_ = lean_uint32_to_uint64(v_rttVarMs_12349_);
v___y_12401_ = v___y_12412_;
v___y_12402_ = v___y_12410_;
v___y_12403_ = v___y_12411_;
v___y_12404_ = v___x_12414_;
goto v___jp_12400_;
}
else
{
uint64_t v___x_12415_;
v___x_12415_ = 60000ULL;
v___y_12401_ = v___y_12412_;
v___y_12402_ = v___y_12410_;
v___y_12403_ = v___y_12411_;
v___y_12404_ = v___x_12415_;
goto v___jp_12400_;
}
}
v___jp_12417_:
{
uint8_t v___x_12419_;
v___x_12419_ = lean_uint32_dec_eq(v_srttMs_12348_, v___x_12416_);
if (v___x_12419_ == 0)
{
uint32_t v___x_12420_; uint8_t v___x_12421_;
v___x_12420_ = 60000;
v___x_12421_ = lean_uint32_dec_lt(v___x_12420_, v_srttMs_12348_);
if (v___x_12421_ == 0)
{
uint64_t v___x_12422_;
v___x_12422_ = lean_uint32_to_uint64(v_srttMs_12348_);
v___y_12410_ = v___y_12418_;
v___y_12411_ = v___x_12420_;
v___y_12412_ = v___x_12422_;
goto v___jp_12409_;
}
else
{
uint64_t v___x_12423_;
v___x_12423_ = 60000ULL;
v___y_12410_ = v___y_12418_;
v___y_12411_ = v___x_12420_;
v___y_12412_ = v___x_12423_;
goto v___jp_12409_;
}
}
else
{
uint32_t v___x_12424_; uint32_t v_halfSample_12425_; uint32_t v___x_12426_; uint8_t v___x_12427_;
v___x_12424_ = 1;
v_halfSample_12425_ = lean_uint32_shift_right(v___y_12418_, v___x_12424_);
v___x_12426_ = 50;
v___x_12427_ = lean_uint32_dec_lt(v_halfSample_12425_, v___x_12426_);
if (v___x_12427_ == 0)
{
v___y_12352_ = v___y_12418_;
v___y_12353_ = v_halfSample_12425_;
goto v___jp_12351_;
}
else
{
v___y_12352_ = v___y_12418_;
v___y_12353_ = v___x_12426_;
goto v___jp_12351_;
}
}
}
}
}

LEAN_EXPORT uint64_t orb_client_link_budget_step(uint32_t v_srttMs_12440_, uint32_t v_rttVarMs_12441_, uint32_t v_consecutiveFailures_12442_, uint8_t v_isConstrained_12443_, uint32_t v_p0InFlight_12444_){
_start:
{
uint32_t v___y_12446_; uint32_t v___y_12447_; uint32_t v___y_12448_; uint32_t v___y_12449_; uint32_t v___y_12450_; uint32_t v___y_12465_; uint32_t v___y_12466_; uint32_t v___y_12467_; uint32_t v___y_12468_; uint64_t v___y_12469_; uint64_t v___y_12478_; uint64_t v___y_12479_; uint32_t v___y_12480_; uint8_t v___y_12481_; uint32_t v___y_12482_; uint32_t v___y_12483_; uint32_t v___y_12484_; uint64_t v___y_12492_; uint64_t v___y_12493_; uint32_t v___y_12494_; uint8_t v___y_12495_; uint32_t v___y_12496_; uint32_t v___y_12497_; uint64_t v___y_12498_; uint64_t v___y_12499_; uint64_t v___y_12507_; uint64_t v___y_12508_; uint8_t v___y_12509_; uint32_t v___y_12510_; uint32_t v___y_12511_; uint64_t v___y_12512_; uint32_t v___y_12513_; uint64_t v___y_12520_; uint64_t v___y_12521_; uint64_t v___y_12522_; uint8_t v___y_12523_; uint32_t v___y_12524_; uint32_t v___y_12525_; uint64_t v___y_12526_; uint64_t v___y_12538_; uint64_t v___y_12539_; uint32_t v___y_12540_; uint32_t v___y_12541_; uint64_t v___y_12542_; uint64_t v___y_12552_; uint32_t v___y_12553_; uint32_t v___y_12554_; uint64_t v___y_12555_; uint32_t v___y_12561_; uint32_t v___y_12562_; uint32_t v___y_12563_; uint64_t v___y_12564_; uint32_t v___y_12569_; uint32_t v___y_12570_; uint8_t v___y_12576_; uint8_t v___y_12577_; uint32_t v___y_12578_; uint8_t v___y_12584_; uint8_t v___y_12588_; uint32_t v___x_12593_; uint8_t v___x_12594_;
v___x_12593_ = 1200;
v___x_12594_ = lean_uint32_dec_lt(v___x_12593_, v_srttMs_12440_);
if (v___x_12594_ == 0)
{
uint32_t v___x_12595_; uint8_t v___x_12596_;
v___x_12595_ = 0;
v___x_12596_ = lean_uint32_dec_lt(v___x_12595_, v_consecutiveFailures_12442_);
if (v___x_12596_ == 0)
{
uint8_t v___x_12597_; uint8_t v___x_12598_;
v___x_12597_ = 0;
v___x_12598_ = lean_uint8_dec_eq(v_isConstrained_12443_, v___x_12597_);
if (v___x_12598_ == 0)
{
uint8_t v___x_12599_;
v___x_12599_ = 1;
v___y_12584_ = v___x_12599_;
goto v___jp_12583_;
}
else
{
v___y_12588_ = v___x_12596_;
goto v___jp_12587_;
}
}
else
{
v___y_12588_ = v___x_12596_;
goto v___jp_12587_;
}
}
else
{
v___y_12588_ = v___x_12594_;
goto v___jp_12587_;
}
v___jp_12445_:
{
uint32_t v___x_12451_; uint32_t v___x_12452_; uint32_t v___x_12453_; uint32_t v___x_12454_; uint32_t v___x_12455_; uint32_t v_lo32_12456_; uint32_t v___x_12457_; uint32_t v_hi32_12458_; uint64_t v___x_12459_; uint64_t v___x_12460_; uint64_t v___x_12461_; uint64_t v___x_12462_; uint64_t v___x_12463_;
v___x_12451_ = 8;
v___x_12452_ = lean_uint32_shift_left(v___y_12448_, v___x_12451_);
v___x_12453_ = lean_uint32_lor(v___y_12447_, v___x_12452_);
v___x_12454_ = 16;
v___x_12455_ = lean_uint32_shift_left(v___y_12446_, v___x_12454_);
v_lo32_12456_ = lean_uint32_lor(v___x_12453_, v___x_12455_);
v___x_12457_ = lean_uint32_shift_left(v___y_12450_, v___x_12454_);
v_hi32_12458_ = lean_uint32_lor(v___y_12449_, v___x_12457_);
v___x_12459_ = lean_uint32_to_uint64(v_lo32_12456_);
v___x_12460_ = lean_uint32_to_uint64(v_hi32_12458_);
v___x_12461_ = 32ULL;
v___x_12462_ = lean_uint64_shift_left(v___x_12460_, v___x_12461_);
v___x_12463_ = lean_uint64_lor(v___x_12459_, v___x_12462_);
return v___x_12463_;
}
v___jp_12464_:
{
uint64_t v___x_12470_; uint8_t v___x_12471_;
v___x_12470_ = 6000ULL;
v___x_12471_ = lean_uint64_dec_lt(v___y_12469_, v___x_12470_);
if (v___x_12471_ == 0)
{
uint64_t v___x_12472_; uint8_t v___x_12473_;
v___x_12472_ = 15000ULL;
v___x_12473_ = lean_uint64_dec_lt(v___x_12472_, v___y_12469_);
if (v___x_12473_ == 0)
{
uint32_t v___x_12474_;
v___x_12474_ = lean_uint64_to_uint32(v___y_12469_);
v___y_12446_ = v___y_12465_;
v___y_12447_ = v___y_12466_;
v___y_12448_ = v___y_12467_;
v___y_12449_ = v___y_12468_;
v___y_12450_ = v___x_12474_;
goto v___jp_12445_;
}
else
{
uint32_t v___x_12475_;
v___x_12475_ = 15000;
v___y_12446_ = v___y_12465_;
v___y_12447_ = v___y_12466_;
v___y_12448_ = v___y_12467_;
v___y_12449_ = v___y_12468_;
v___y_12450_ = v___x_12475_;
goto v___jp_12445_;
}
}
else
{
uint32_t v___x_12476_;
v___x_12476_ = 6000;
v___y_12446_ = v___y_12465_;
v___y_12447_ = v___y_12466_;
v___y_12448_ = v___y_12467_;
v___y_12449_ = v___y_12468_;
v___y_12450_ = v___x_12476_;
goto v___jp_12445_;
}
}
v___jp_12477_:
{
if (v___y_12481_ == 0)
{
uint64_t v___x_12485_; uint64_t v___x_12486_; uint64_t v___x_12487_; uint64_t v___x_12488_; uint64_t v___x_12489_;
v___x_12485_ = 1ULL;
v___x_12486_ = lean_uint64_shift_left(v___y_12478_, v___x_12485_);
v___x_12487_ = lean_uint64_add(v___y_12479_, v___x_12486_);
v___x_12488_ = 2500ULL;
v___x_12489_ = lean_uint64_add(v___x_12487_, v___x_12488_);
v___y_12465_ = v___y_12480_;
v___y_12466_ = v___y_12482_;
v___y_12467_ = v___y_12483_;
v___y_12468_ = v___y_12484_;
v___y_12469_ = v___x_12489_;
goto v___jp_12464_;
}
else
{
uint64_t v___x_12490_;
v___x_12490_ = 6000ULL;
v___y_12465_ = v___y_12480_;
v___y_12466_ = v___y_12482_;
v___y_12467_ = v___y_12483_;
v___y_12468_ = v___y_12484_;
v___y_12469_ = v___x_12490_;
goto v___jp_12464_;
}
}
v___jp_12491_:
{
uint8_t v___x_12500_;
v___x_12500_ = lean_uint64_dec_lt(v___y_12499_, v___y_12498_);
if (v___x_12500_ == 0)
{
uint64_t v___x_12501_; uint8_t v___x_12502_;
v___x_12501_ = 25000ULL;
v___x_12502_ = lean_uint64_dec_lt(v___x_12501_, v___y_12499_);
if (v___x_12502_ == 0)
{
uint32_t v___x_12503_;
v___x_12503_ = lean_uint64_to_uint32(v___y_12499_);
v___y_12478_ = v___y_12492_;
v___y_12479_ = v___y_12493_;
v___y_12480_ = v___y_12494_;
v___y_12481_ = v___y_12495_;
v___y_12482_ = v___y_12496_;
v___y_12483_ = v___y_12497_;
v___y_12484_ = v___x_12503_;
goto v___jp_12477_;
}
else
{
uint32_t v___x_12504_;
v___x_12504_ = 25000;
v___y_12478_ = v___y_12492_;
v___y_12479_ = v___y_12493_;
v___y_12480_ = v___y_12494_;
v___y_12481_ = v___y_12495_;
v___y_12482_ = v___y_12496_;
v___y_12483_ = v___y_12497_;
v___y_12484_ = v___x_12504_;
goto v___jp_12477_;
}
}
else
{
uint32_t v___x_12505_;
v___x_12505_ = 8000;
v___y_12478_ = v___y_12492_;
v___y_12479_ = v___y_12493_;
v___y_12480_ = v___y_12494_;
v___y_12481_ = v___y_12495_;
v___y_12482_ = v___y_12496_;
v___y_12483_ = v___y_12497_;
v___y_12484_ = v___x_12505_;
goto v___jp_12477_;
}
}
v___jp_12506_:
{
if (v___y_12509_ == 0)
{
uint64_t v___x_12514_; uint64_t v___x_12515_; uint64_t v___x_12516_; uint64_t v___x_12517_; uint64_t v___x_12518_;
v___x_12514_ = 2ULL;
v___x_12515_ = lean_uint64_shift_left(v___y_12507_, v___x_12514_);
v___x_12516_ = lean_uint64_add(v___y_12508_, v___x_12515_);
v___x_12517_ = 3000ULL;
v___x_12518_ = lean_uint64_add(v___x_12516_, v___x_12517_);
v___y_12492_ = v___y_12507_;
v___y_12493_ = v___y_12508_;
v___y_12494_ = v___y_12513_;
v___y_12495_ = v___y_12509_;
v___y_12496_ = v___y_12510_;
v___y_12497_ = v___y_12511_;
v___y_12498_ = v___y_12512_;
v___y_12499_ = v___x_12518_;
goto v___jp_12491_;
}
else
{
v___y_12492_ = v___y_12507_;
v___y_12493_ = v___y_12508_;
v___y_12494_ = v___y_12513_;
v___y_12495_ = v___y_12509_;
v___y_12496_ = v___y_12510_;
v___y_12497_ = v___y_12511_;
v___y_12498_ = v___y_12512_;
v___y_12499_ = v___y_12512_;
goto v___jp_12491_;
}
}
v___jp_12519_:
{
uint64_t v___x_12527_; uint64_t v___x_12528_; uint64_t v_rawConn_12529_; uint64_t v___x_12530_; uint8_t v___x_12531_;
v___x_12527_ = 2000ULL;
v___x_12528_ = lean_uint64_mul(v___x_12527_, v___y_12522_);
v_rawConn_12529_ = lean_uint64_add(v___y_12526_, v___x_12528_);
v___x_12530_ = 8000ULL;
v___x_12531_ = lean_uint64_dec_lt(v_rawConn_12529_, v___x_12530_);
if (v___x_12531_ == 0)
{
uint64_t v___x_12532_; uint8_t v___x_12533_;
v___x_12532_ = 30000ULL;
v___x_12533_ = lean_uint64_dec_lt(v___x_12532_, v_rawConn_12529_);
if (v___x_12533_ == 0)
{
uint32_t v___x_12534_;
v___x_12534_ = lean_uint64_to_uint32(v_rawConn_12529_);
v___y_12507_ = v___y_12520_;
v___y_12508_ = v___y_12521_;
v___y_12509_ = v___y_12523_;
v___y_12510_ = v___y_12524_;
v___y_12511_ = v___y_12525_;
v___y_12512_ = v___x_12530_;
v___y_12513_ = v___x_12534_;
goto v___jp_12506_;
}
else
{
uint32_t v___x_12535_;
v___x_12535_ = 30000;
v___y_12507_ = v___y_12520_;
v___y_12508_ = v___y_12521_;
v___y_12509_ = v___y_12523_;
v___y_12510_ = v___y_12524_;
v___y_12511_ = v___y_12525_;
v___y_12512_ = v___x_12530_;
v___y_12513_ = v___x_12535_;
goto v___jp_12506_;
}
}
else
{
uint32_t v___x_12536_;
v___x_12536_ = 8000;
v___y_12507_ = v___y_12520_;
v___y_12508_ = v___y_12521_;
v___y_12509_ = v___y_12523_;
v___y_12510_ = v___y_12524_;
v___y_12511_ = v___y_12525_;
v___y_12512_ = v___x_12530_;
v___y_12513_ = v___x_12536_;
goto v___jp_12506_;
}
}
v___jp_12537_:
{
uint64_t v___x_12543_; uint8_t v___x_12544_;
v___x_12543_ = 0ULL;
v___x_12544_ = lean_uint64_dec_eq(v___y_12539_, v___x_12543_);
if (v___x_12544_ == 0)
{
uint64_t v___x_12545_; uint64_t v___x_12546_; uint64_t v___x_12547_; uint64_t v___x_12548_; uint64_t v___x_12549_;
v___x_12545_ = 2ULL;
v___x_12546_ = lean_uint64_shift_left(v___y_12538_, v___x_12545_);
v___x_12547_ = lean_uint64_add(v___y_12539_, v___x_12546_);
v___x_12548_ = 4000ULL;
v___x_12549_ = lean_uint64_add(v___x_12547_, v___x_12548_);
v___y_12520_ = v___y_12538_;
v___y_12521_ = v___y_12539_;
v___y_12522_ = v___y_12542_;
v___y_12523_ = v___x_12544_;
v___y_12524_ = v___y_12540_;
v___y_12525_ = v___y_12541_;
v___y_12526_ = v___x_12549_;
goto v___jp_12519_;
}
else
{
uint64_t v___x_12550_;
v___x_12550_ = 10000ULL;
v___y_12520_ = v___y_12538_;
v___y_12521_ = v___y_12539_;
v___y_12522_ = v___y_12542_;
v___y_12523_ = v___x_12544_;
v___y_12524_ = v___y_12540_;
v___y_12525_ = v___y_12541_;
v___y_12526_ = v___x_12550_;
goto v___jp_12519_;
}
}
v___jp_12551_:
{
uint32_t v___x_12556_; uint8_t v___x_12557_;
v___x_12556_ = 4;
v___x_12557_ = lean_uint32_dec_le(v___x_12556_, v_consecutiveFailures_12442_);
if (v___x_12557_ == 0)
{
uint64_t v___x_12558_;
v___x_12558_ = lean_uint32_to_uint64(v_consecutiveFailures_12442_);
v___y_12538_ = v___y_12555_;
v___y_12539_ = v___y_12552_;
v___y_12540_ = v___y_12553_;
v___y_12541_ = v___y_12554_;
v___y_12542_ = v___x_12558_;
goto v___jp_12537_;
}
else
{
uint64_t v___x_12559_;
v___x_12559_ = 4ULL;
v___y_12538_ = v___y_12555_;
v___y_12539_ = v___y_12552_;
v___y_12540_ = v___y_12553_;
v___y_12541_ = v___y_12554_;
v___y_12542_ = v___x_12559_;
goto v___jp_12537_;
}
}
v___jp_12560_:
{
uint8_t v___x_12565_;
v___x_12565_ = lean_uint32_dec_lt(v___y_12562_, v_rttVarMs_12441_);
if (v___x_12565_ == 0)
{
uint64_t v___x_12566_;
v___x_12566_ = lean_uint32_to_uint64(v_rttVarMs_12441_);
v___y_12552_ = v___y_12564_;
v___y_12553_ = v___y_12561_;
v___y_12554_ = v___y_12563_;
v___y_12555_ = v___x_12566_;
goto v___jp_12551_;
}
else
{
uint64_t v___x_12567_;
v___x_12567_ = 60000ULL;
v___y_12552_ = v___y_12564_;
v___y_12553_ = v___y_12561_;
v___y_12554_ = v___y_12563_;
v___y_12555_ = v___x_12567_;
goto v___jp_12551_;
}
}
v___jp_12568_:
{
uint32_t v___x_12571_; uint8_t v___x_12572_;
v___x_12571_ = 60000;
v___x_12572_ = lean_uint32_dec_lt(v___x_12571_, v_srttMs_12440_);
if (v___x_12572_ == 0)
{
uint64_t v___x_12573_;
v___x_12573_ = lean_uint32_to_uint64(v_srttMs_12440_);
v___y_12561_ = v___y_12569_;
v___y_12562_ = v___x_12571_;
v___y_12563_ = v___y_12570_;
v___y_12564_ = v___x_12573_;
goto v___jp_12560_;
}
else
{
uint64_t v___x_12574_;
v___x_12574_ = 60000ULL;
v___y_12561_ = v___y_12569_;
v___y_12562_ = v___x_12571_;
v___y_12563_ = v___y_12570_;
v___y_12564_ = v___x_12574_;
goto v___jp_12560_;
}
}
v___jp_12575_:
{
uint32_t v___x_12579_; uint8_t v___x_12580_;
v___x_12579_ = 0;
v___x_12580_ = lean_uint32_dec_lt(v___x_12579_, v_p0InFlight_12444_);
if (v___x_12580_ == 0)
{
if (v___y_12577_ == 0)
{
if (v___y_12576_ == 0)
{
uint32_t v___x_12581_;
v___x_12581_ = 4;
v___y_12569_ = v___y_12578_;
v___y_12570_ = v___x_12581_;
goto v___jp_12568_;
}
else
{
uint32_t v___x_12582_;
v___x_12582_ = 1;
v___y_12569_ = v___y_12578_;
v___y_12570_ = v___x_12582_;
goto v___jp_12568_;
}
}
else
{
v___y_12569_ = v___y_12578_;
v___y_12570_ = v___x_12579_;
goto v___jp_12568_;
}
}
else
{
v___y_12569_ = v___y_12578_;
v___y_12570_ = v___x_12579_;
goto v___jp_12568_;
}
}
v___jp_12583_:
{
uint8_t v___x_12585_; uint32_t v___x_12586_;
v___x_12585_ = 0;
v___x_12586_ = 2;
v___y_12576_ = v___x_12585_;
v___y_12577_ = v___y_12584_;
v___y_12578_ = v___x_12586_;
goto v___jp_12575_;
}
v___jp_12587_:
{
if (v___y_12588_ == 0)
{
uint32_t v___x_12589_; uint8_t v___x_12590_;
v___x_12589_ = 400;
v___x_12590_ = lean_uint32_dec_lt(v___x_12589_, v_srttMs_12440_);
if (v___x_12590_ == 0)
{
uint32_t v___x_12591_;
v___x_12591_ = 6;
v___y_12576_ = v___x_12590_;
v___y_12577_ = v___y_12588_;
v___y_12578_ = v___x_12591_;
goto v___jp_12575_;
}
else
{
uint32_t v___x_12592_;
v___x_12592_ = 3;
v___y_12576_ = v___x_12590_;
v___y_12577_ = v___y_12588_;
v___y_12578_ = v___x_12592_;
goto v___jp_12575_;
}
}
else
{
v___y_12584_ = v___y_12588_;
goto v___jp_12583_;
}
}
}
}

LEAN_EXPORT uint32_t orb_multiuser_rbac_step(uint8_t v_callerAuthed_12706_, uint8_t v_callerDisabled_12707_, uint8_t v_epochMatches_12708_, uint8_t v_callerRole_12709_, uint8_t v_opClass_12710_, uint8_t v_isOwner_12711_, uint8_t v_isSharedParticipant_12712_){
_start:
{
uint8_t v___x_12713_; uint8_t v___x_12714_;
v___x_12713_ = 1;
v___x_12714_ = lean_uint8_dec_eq(v_callerAuthed_12706_, v___x_12713_);
if (v___x_12714_ == 0)
{
uint32_t v___x_12715_;
v___x_12715_ = 131874;
return v___x_12715_;
}
else
{
uint8_t v___x_12716_;
v___x_12716_ = lean_uint8_dec_eq(v_epochMatches_12708_, v___x_12713_);
if (v___x_12716_ == 0)
{
uint32_t v___x_12717_;
v___x_12717_ = 131874;
return v___x_12717_;
}
else
{
uint8_t v___x_12718_; uint8_t v___x_12719_;
v___x_12718_ = 0;
v___x_12719_ = lean_uint8_dec_eq(v_callerDisabled_12707_, v___x_12718_);
if (v___x_12719_ == 0)
{
uint32_t v___x_12720_;
v___x_12720_ = 262950;
return v___x_12720_;
}
else
{
uint8_t v___x_12721_;
v___x_12721_ = lean_uint8_dec_lt(v___x_12713_, v_callerRole_12709_);
if (v___x_12721_ == 0)
{
uint8_t v___x_12722_;
v___x_12722_ = lean_uint8_dec_eq(v_opClass_12710_, v___x_12718_);
if (v___x_12722_ == 0)
{
uint8_t v___x_12723_;
v___x_12723_ = lean_uint8_dec_eq(v_opClass_12710_, v___x_12713_);
if (v___x_12723_ == 0)
{
uint8_t v___x_12724_; uint8_t v___x_12725_;
v___x_12724_ = 2;
v___x_12725_ = lean_uint8_dec_eq(v_opClass_12710_, v___x_12724_);
if (v___x_12725_ == 0)
{
uint8_t v___x_12726_; uint8_t v___x_12727_;
v___x_12726_ = 3;
v___x_12727_ = lean_uint8_dec_eq(v_opClass_12710_, v___x_12726_);
if (v___x_12727_ == 0)
{
uint8_t v___x_12728_; uint8_t v___x_12729_;
v___x_12728_ = 4;
v___x_12729_ = lean_uint8_dec_eq(v_opClass_12710_, v___x_12728_);
if (v___x_12729_ == 0)
{
uint32_t v___x_12730_;
v___x_12730_ = 787238;
return v___x_12730_;
}
else
{
uint8_t v___x_12731_;
v___x_12731_ = lean_uint8_dec_eq(v_isOwner_12711_, v___x_12713_);
if (v___x_12731_ == 0)
{
uint32_t v___x_12732_;
v___x_12732_ = 525096;
return v___x_12732_;
}
else
{
uint32_t v___x_12733_;
v___x_12733_ = 401;
return v___x_12733_;
}
}
}
else
{
uint8_t v___x_12734_;
v___x_12734_ = lean_uint8_dec_eq(v_isOwner_12711_, v___x_12713_);
if (v___x_12734_ == 0)
{
uint8_t v___x_12735_;
v___x_12735_ = lean_uint8_dec_eq(v_isSharedParticipant_12712_, v___x_12713_);
if (v___x_12735_ == 0)
{
uint32_t v___x_12736_;
v___x_12736_ = 525096;
return v___x_12736_;
}
else
{
uint32_t v___x_12737_;
v___x_12737_ = 656166;
return v___x_12737_;
}
}
else
{
uint32_t v___x_12738_;
v___x_12738_ = 401;
return v___x_12738_;
}
}
}
else
{
uint8_t v___x_12739_;
v___x_12739_ = lean_uint8_dec_eq(v_isOwner_12711_, v___x_12713_);
if (v___x_12739_ == 0)
{
uint8_t v___x_12740_;
v___x_12740_ = lean_uint8_dec_eq(v_isSharedParticipant_12712_, v___x_12713_);
if (v___x_12740_ == 0)
{
uint32_t v___x_12741_;
v___x_12741_ = 525096;
return v___x_12741_;
}
else
{
uint32_t v___x_12742_;
v___x_12742_ = 401;
return v___x_12742_;
}
}
else
{
uint32_t v___x_12743_;
v___x_12743_ = 401;
return v___x_12743_;
}
}
}
else
{
uint8_t v___x_12744_;
v___x_12744_ = lean_uint8_dec_eq(v_callerRole_12709_, v___x_12713_);
if (v___x_12744_ == 0)
{
uint32_t v___x_12745_;
v___x_12745_ = 394022;
return v___x_12745_;
}
else
{
uint32_t v___x_12746_;
v___x_12746_ = 401;
return v___x_12746_;
}
}
}
else
{
uint32_t v___x_12747_;
v___x_12747_ = 401;
return v___x_12747_;
}
}
else
{
uint32_t v___x_12748_;
v___x_12748_ = 787238;
return v___x_12748_;
}
}
}
}
}
}

LEAN_EXPORT uint8_t orb_placement_role_admit(uint8_t v_callerRole_12765_, uint8_t v_targetKind_12766_, uint8_t v_nodeAdminOnly_12767_, uint8_t v_hasValidUnixUser_12768_){
_start:
{
uint8_t v___x_12769_; uint8_t v___x_12770_;
v___x_12769_ = 4;
v___x_12770_ = lean_uint8_dec_lt(v___x_12769_, v_targetKind_12766_);
if (v___x_12770_ == 0)
{
uint8_t v___x_12771_; uint8_t v___x_12772_;
v___x_12771_ = 1;
v___x_12772_ = lean_uint8_dec_eq(v_callerRole_12765_, v___x_12771_);
if (v___x_12772_ == 0)
{
uint8_t v___x_12773_; uint8_t v___x_12777_;
v___x_12773_ = 0;
v___x_12777_ = lean_uint8_dec_eq(v_callerRole_12765_, v___x_12773_);
if (v___x_12777_ == 0)
{
return v___x_12773_;
}
else
{
uint8_t v___x_12778_;
v___x_12778_ = lean_uint8_dec_eq(v_targetKind_12766_, v___x_12769_);
if (v___x_12778_ == 0)
{
uint8_t v___x_12779_; uint8_t v___x_12780_;
v___x_12779_ = 2;
v___x_12780_ = lean_uint8_dec_eq(v_targetKind_12766_, v___x_12779_);
if (v___x_12780_ == 0)
{
uint8_t v___x_12781_; uint8_t v___x_12782_;
v___x_12781_ = 3;
v___x_12782_ = lean_uint8_dec_eq(v_targetKind_12766_, v___x_12781_);
if (v___x_12782_ == 0)
{
return v___x_12773_;
}
else
{
goto v___jp_12774_;
}
}
else
{
goto v___jp_12774_;
}
}
else
{
return v___x_12771_;
}
}
v___jp_12774_:
{
uint8_t v___x_12775_;
v___x_12775_ = lean_uint8_dec_eq(v_nodeAdminOnly_12767_, v___x_12773_);
if (v___x_12775_ == 0)
{
return v___x_12773_;
}
else
{
uint8_t v___x_12776_;
v___x_12776_ = lean_uint8_dec_eq(v_hasValidUnixUser_12768_, v___x_12771_);
if (v___x_12776_ == 0)
{
return v___x_12773_;
}
else
{
return v___x_12771_;
}
}
}
}
else
{
return v___x_12771_;
}
}
else
{
uint8_t v___x_12783_;
v___x_12783_ = 0;
return v___x_12783_;
}
}
}

LEAN_EXPORT uint64_t orb_user_spend_cap_step(uint8_t v_globalCapActive_12794_, uint32_t v_globalSpentCents_12795_, uint32_t v_globalCapCents_12796_, uint8_t v_userCapActive_12797_, uint32_t v_userSpentCents_12798_, uint32_t v_userCapCents_12799_, uint32_t v_deltaCents_12800_){
_start:
{
uint64_t v___y_12802_; uint64_t v___y_12803_; uint8_t v___y_12804_; uint8_t v___y_12805_; uint64_t v___y_12806_; uint64_t v___y_12807_; uint8_t v___y_12808_; uint64_t v___y_12837_; uint64_t v___y_12838_; uint8_t v___y_12839_; uint64_t v___y_12840_; uint64_t v___y_12841_; uint8_t v___y_12842_; uint8_t v___y_12843_; uint64_t v___y_12849_; uint64_t v___y_12850_; uint64_t v___y_12851_; uint64_t v___y_12852_; uint8_t v___y_12853_; uint64_t v_maxLedger64_12859_; uint64_t v___x_12860_; uint64_t v___y_12862_; uint64_t v___y_12863_; uint64_t v___y_12864_; uint64_t v___y_12871_; uint8_t v___x_12874_;
v_maxLedger64_12859_ = 1073741823ULL;
v___x_12860_ = lean_uint32_to_uint64(v_globalSpentCents_12795_);
v___x_12874_ = lean_uint64_dec_le(v___x_12860_, v_maxLedger64_12859_);
if (v___x_12874_ == 0)
{
v___y_12871_ = v_maxLedger64_12859_;
goto v___jp_12870_;
}
else
{
v___y_12871_ = v___x_12860_;
goto v___jp_12870_;
}
v___jp_12801_:
{
if (v___y_12805_ == 0)
{
if (v___y_12808_ == 0)
{
if (v___y_12804_ == 0)
{
uint64_t v___x_12809_; uint64_t v___x_12810_; uint64_t v___x_12811_; uint64_t v___x_12812_; uint64_t v___x_12813_; uint64_t v___x_12814_; uint64_t v___x_12815_;
v___x_12809_ = 1ULL;
v___x_12810_ = 4ULL;
v___x_12811_ = lean_uint64_shift_left(v___y_12807_, v___x_12810_);
v___x_12812_ = lean_uint64_lor(v___x_12809_, v___x_12811_);
v___x_12813_ = 34ULL;
v___x_12814_ = lean_uint64_shift_left(v___y_12803_, v___x_12813_);
v___x_12815_ = lean_uint64_lor(v___x_12812_, v___x_12814_);
return v___x_12815_;
}
else
{
uint64_t v___x_12816_; uint64_t v___x_12817_; uint64_t v___x_12818_; uint64_t v___x_12819_; uint64_t v___x_12820_; uint64_t v___x_12821_; uint64_t v___x_12822_;
v___x_12816_ = 6ULL;
v___x_12817_ = 4ULL;
v___x_12818_ = lean_uint64_shift_left(v___y_12802_, v___x_12817_);
v___x_12819_ = lean_uint64_lor(v___x_12816_, v___x_12818_);
v___x_12820_ = 34ULL;
v___x_12821_ = lean_uint64_shift_left(v___y_12806_, v___x_12820_);
v___x_12822_ = lean_uint64_lor(v___x_12819_, v___x_12821_);
return v___x_12822_;
}
}
else
{
uint64_t v___x_12823_; uint64_t v___x_12824_; uint64_t v___x_12825_; uint64_t v___x_12826_; uint64_t v___x_12827_; uint64_t v___x_12828_;
v___x_12823_ = 4ULL;
v___x_12824_ = lean_uint64_shift_left(v___y_12802_, v___x_12823_);
v___x_12825_ = lean_uint64_lor(v___x_12823_, v___x_12824_);
v___x_12826_ = 34ULL;
v___x_12827_ = lean_uint64_shift_left(v___y_12806_, v___x_12826_);
v___x_12828_ = lean_uint64_lor(v___x_12825_, v___x_12827_);
return v___x_12828_;
}
}
else
{
uint64_t v___x_12829_; uint64_t v___x_12830_; uint64_t v___x_12831_; uint64_t v___x_12832_; uint64_t v___x_12833_; uint64_t v___x_12834_; uint64_t v___x_12835_;
v___x_12829_ = 2ULL;
v___x_12830_ = 4ULL;
v___x_12831_ = lean_uint64_shift_left(v___y_12802_, v___x_12830_);
v___x_12832_ = lean_uint64_lor(v___x_12829_, v___x_12831_);
v___x_12833_ = 34ULL;
v___x_12834_ = lean_uint64_shift_left(v___y_12806_, v___x_12833_);
v___x_12835_ = lean_uint64_lor(v___x_12832_, v___x_12834_);
return v___x_12835_;
}
}
v___jp_12836_:
{
uint8_t v___x_12844_;
v___x_12844_ = lean_uint8_dec_eq(v_userCapActive_12797_, v___y_12842_);
if (v___x_12844_ == 0)
{
uint64_t v___x_12845_; uint8_t v___x_12846_;
v___x_12845_ = lean_uint32_to_uint64(v_userCapCents_12799_);
v___x_12846_ = lean_uint64_dec_lt(v___x_12845_, v___y_12838_);
v___y_12802_ = v___y_12837_;
v___y_12803_ = v___y_12838_;
v___y_12804_ = v___y_12839_;
v___y_12805_ = v___y_12843_;
v___y_12806_ = v___y_12841_;
v___y_12807_ = v___y_12840_;
v___y_12808_ = v___x_12846_;
goto v___jp_12801_;
}
else
{
uint8_t v___x_12847_;
v___x_12847_ = 0;
v___y_12802_ = v___y_12837_;
v___y_12803_ = v___y_12838_;
v___y_12804_ = v___y_12839_;
v___y_12805_ = v___y_12843_;
v___y_12806_ = v___y_12841_;
v___y_12807_ = v___y_12840_;
v___y_12808_ = v___x_12847_;
goto v___jp_12801_;
}
}
v___jp_12848_:
{
uint8_t v___x_12854_; uint8_t v___x_12855_;
v___x_12854_ = 0;
v___x_12855_ = lean_uint8_dec_eq(v_globalCapActive_12794_, v___x_12854_);
if (v___x_12855_ == 0)
{
uint64_t v___x_12856_; uint8_t v___x_12857_;
v___x_12856_ = lean_uint32_to_uint64(v_globalCapCents_12796_);
v___x_12857_ = lean_uint64_dec_lt(v___x_12856_, v___y_12852_);
v___y_12837_ = v___y_12849_;
v___y_12838_ = v___y_12850_;
v___y_12839_ = v___y_12853_;
v___y_12840_ = v___y_12852_;
v___y_12841_ = v___y_12851_;
v___y_12842_ = v___x_12854_;
v___y_12843_ = v___x_12857_;
goto v___jp_12836_;
}
else
{
uint8_t v___x_12858_;
v___x_12858_ = 0;
v___y_12837_ = v___y_12849_;
v___y_12838_ = v___y_12850_;
v___y_12839_ = v___y_12853_;
v___y_12840_ = v___y_12852_;
v___y_12841_ = v___y_12851_;
v___y_12842_ = v___x_12854_;
v___y_12843_ = v___x_12858_;
goto v___jp_12836_;
}
}
v___jp_12861_:
{
uint64_t v___x_12865_; uint64_t v_rawG64_12866_; uint64_t v_rawU64_12867_; uint8_t v___x_12868_;
v___x_12865_ = lean_uint32_to_uint64(v_deltaCents_12800_);
v_rawG64_12866_ = lean_uint64_add(v___x_12860_, v___x_12865_);
v_rawU64_12867_ = lean_uint64_add(v___y_12863_, v___x_12865_);
v___x_12868_ = lean_uint64_dec_lt(v_maxLedger64_12859_, v_rawG64_12866_);
if (v___x_12868_ == 0)
{
uint8_t v___x_12869_;
v___x_12869_ = lean_uint64_dec_lt(v_maxLedger64_12859_, v_rawU64_12867_);
v___y_12849_ = v___y_12862_;
v___y_12850_ = v_rawU64_12867_;
v___y_12851_ = v___y_12864_;
v___y_12852_ = v_rawG64_12866_;
v___y_12853_ = v___x_12869_;
goto v___jp_12848_;
}
else
{
v___y_12849_ = v___y_12862_;
v___y_12850_ = v_rawU64_12867_;
v___y_12851_ = v___y_12864_;
v___y_12852_ = v_rawG64_12866_;
v___y_12853_ = v___x_12868_;
goto v___jp_12848_;
}
}
v___jp_12870_:
{
uint64_t v___x_12872_; uint8_t v___x_12873_;
v___x_12872_ = lean_uint32_to_uint64(v_userSpentCents_12798_);
v___x_12873_ = lean_uint64_dec_le(v___x_12872_, v_maxLedger64_12859_);
if (v___x_12873_ == 0)
{
v___y_12862_ = v___y_12871_;
v___y_12863_ = v___x_12872_;
v___y_12864_ = v_maxLedger64_12859_;
goto v___jp_12861_;
}
else
{
v___y_12862_ = v___y_12871_;
v___y_12863_ = v___x_12872_;
v___y_12864_ = v___x_12872_;
goto v___jp_12861_;
}
}
}
}

LEAN_EXPORT uint32_t orb_privd_user_exec_step(uint8_t v_peerIsNodeUid_12891_, uint8_t v_leaseVerified_12892_, uint8_t v_nodeAdminOnly_12893_, uint8_t v_callerRole_12894_, uint8_t v_usernameValid_12895_, uint32_t v_targetUid_12896_, uint32_t v_targetGid_12897_, uint8_t v_gidDisjointPriv_12898_, uint8_t v_homeConfinedNoSymlink_12899_, uint8_t v_elanRootOwned_12900_){
_start:
{
uint8_t v___x_12901_; uint8_t v___x_12922_;
v___x_12901_ = 1;
v___x_12922_ = lean_uint8_dec_eq(v_peerIsNodeUid_12891_, v___x_12901_);
if (v___x_12922_ == 0)
{
uint32_t v___x_12923_;
v___x_12923_ = 256;
return v___x_12923_;
}
else
{
uint8_t v___x_12924_;
v___x_12924_ = lean_uint8_dec_eq(v_leaseVerified_12892_, v___x_12901_);
if (v___x_12924_ == 0)
{
uint32_t v___x_12925_;
v___x_12925_ = 512;
return v___x_12925_;
}
else
{
uint8_t v___x_12926_;
v___x_12926_ = lean_uint8_dec_lt(v___x_12901_, v_callerRole_12894_);
if (v___x_12926_ == 0)
{
uint8_t v___x_12927_; uint8_t v___x_12928_;
v___x_12927_ = 0;
v___x_12928_ = lean_uint8_dec_eq(v_callerRole_12894_, v___x_12927_);
if (v___x_12928_ == 0)
{
goto v___jp_12902_;
}
else
{
uint8_t v___x_12929_;
v___x_12929_ = lean_uint8_dec_eq(v_nodeAdminOnly_12893_, v___x_12927_);
if (v___x_12929_ == 0)
{
uint32_t v___x_12930_;
v___x_12930_ = 1024;
return v___x_12930_;
}
else
{
goto v___jp_12902_;
}
}
}
else
{
uint32_t v___x_12931_;
v___x_12931_ = 768;
return v___x_12931_;
}
}
}
v___jp_12902_:
{
uint8_t v___x_12903_;
v___x_12903_ = lean_uint8_dec_eq(v_usernameValid_12895_, v___x_12901_);
if (v___x_12903_ == 0)
{
uint32_t v___x_12904_;
v___x_12904_ = 1280;
return v___x_12904_;
}
else
{
uint32_t v___x_12905_; uint8_t v___x_12906_;
v___x_12905_ = 2000;
v___x_12906_ = lean_uint32_dec_lt(v_targetUid_12896_, v___x_12905_);
if (v___x_12906_ == 0)
{
uint32_t v___x_12907_; uint8_t v___x_12908_;
v___x_12907_ = 65534;
v___x_12908_ = lean_uint32_dec_le(v___x_12907_, v_targetUid_12896_);
if (v___x_12908_ == 0)
{
uint8_t v___x_12909_;
v___x_12909_ = lean_uint32_dec_lt(v_targetGid_12897_, v___x_12905_);
if (v___x_12909_ == 0)
{
uint8_t v___x_12910_;
v___x_12910_ = lean_uint32_dec_le(v___x_12907_, v_targetGid_12897_);
if (v___x_12910_ == 0)
{
uint8_t v___x_12911_;
v___x_12911_ = lean_uint8_dec_eq(v_gidDisjointPriv_12898_, v___x_12901_);
if (v___x_12911_ == 0)
{
uint32_t v___x_12912_;
v___x_12912_ = 1792;
return v___x_12912_;
}
else
{
uint8_t v___x_12913_;
v___x_12913_ = lean_uint8_dec_eq(v_homeConfinedNoSymlink_12899_, v___x_12901_);
if (v___x_12913_ == 0)
{
uint32_t v___x_12914_;
v___x_12914_ = 2048;
return v___x_12914_;
}
else
{
uint8_t v___x_12915_;
v___x_12915_ = lean_uint8_dec_eq(v_elanRootOwned_12900_, v___x_12901_);
if (v___x_12915_ == 0)
{
uint32_t v___x_12916_;
v___x_12916_ = 2304;
return v___x_12916_;
}
else
{
uint32_t v___x_12917_;
v___x_12917_ = 1;
return v___x_12917_;
}
}
}
}
else
{
uint32_t v___x_12918_;
v___x_12918_ = 1536;
return v___x_12918_;
}
}
else
{
uint32_t v___x_12919_;
v___x_12919_ = 1536;
return v___x_12919_;
}
}
else
{
uint32_t v___x_12920_;
v___x_12920_ = 1536;
return v___x_12920_;
}
}
else
{
uint32_t v___x_12921_;
v___x_12921_ = 1536;
return v___x_12921_;
}
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

LEAN_EXPORT uint8_t leansys_verify_jsonl_tape(uint64_t v_keyOff_1360_, uint64_t v_keyLen_1361_, uint64_t v_valOff_1362_, uint64_t v_valLen_1363_, uint64_t v_bufCap_1364_, uint32_t v_depth_1365_){
_start:
{
uint8_t v___x_1366_;
v___x_1366_ = lean_uint64_dec_le(v_keyOff_1360_, v_bufCap_1364_);
if (v___x_1366_ == 0)
{
uint8_t v___x_1367_;
v___x_1367_ = 0;
return v___x_1367_;
}
else
{
uint64_t v___x_1368_; uint8_t v___x_1369_;
v___x_1368_ = lean_uint64_sub(v_bufCap_1364_, v_keyOff_1360_);
v___x_1369_ = lean_uint64_dec_le(v_keyLen_1361_, v___x_1368_);
if (v___x_1369_ == 0)
{
uint8_t v___x_1370_;
v___x_1370_ = 0;
return v___x_1370_;
}
else
{
uint8_t v___x_1371_;
v___x_1371_ = lean_uint64_dec_le(v_valOff_1362_, v_bufCap_1364_);
if (v___x_1371_ == 0)
{
uint8_t v___x_1372_;
v___x_1372_ = 0;
return v___x_1372_;
}
else
{
uint64_t v___x_1373_; uint8_t v___x_1374_;
v___x_1373_ = lean_uint64_sub(v_bufCap_1364_, v_valOff_1362_);
v___x_1374_ = lean_uint64_dec_le(v_valLen_1363_, v___x_1373_);
if (v___x_1374_ == 0)
{
uint8_t v___x_1375_;
v___x_1375_ = 0;
return v___x_1375_;
}
else
{
uint64_t v___x_1376_; uint8_t v___x_1377_;
v___x_1376_ = lean_uint64_add(v_keyOff_1360_, v_keyLen_1361_);
v___x_1377_ = lean_uint64_dec_le(v___x_1376_, v_valOff_1362_);
if (v___x_1377_ == 0)
{
uint8_t v___x_1378_;
v___x_1378_ = 0;
return v___x_1378_;
}
else
{
uint32_t v___x_1379_; uint8_t v___x_1380_;
v___x_1379_ = 64;
v___x_1380_ = lean_uint32_dec_le(v_depth_1365_, v___x_1379_);
if (v___x_1380_ == 0)
{
uint8_t v___x_1381_;
v___x_1381_ = 0;
return v___x_1381_;
}
else
{
uint8_t v___x_1382_;
v___x_1382_ = 1;
return v___x_1382_;
}
}
}
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_verify_ring_cursor(uint64_t v_head_1613_, uint64_t v_tail_1614_, uint64_t v_cap_1615_, uint64_t v_msgLen_1616_){
_start:
{
uint64_t v___x_1617_; uint8_t v___x_1618_;
v___x_1617_ = 0ULL;
v___x_1618_ = lean_uint64_dec_lt(v___x_1617_, v_cap_1615_);
if (v___x_1618_ == 0)
{
uint8_t v___x_1619_;
v___x_1619_ = 0;
return v___x_1619_;
}
else
{
uint8_t v___x_1620_;
v___x_1620_ = lean_uint64_dec_le(v_tail_1614_, v_head_1613_);
if (v___x_1620_ == 0)
{
uint8_t v___x_1621_;
v___x_1621_ = 0;
return v___x_1621_;
}
else
{
uint64_t v___x_1622_; uint8_t v___x_1623_;
v___x_1622_ = lean_uint64_sub(v_head_1613_, v_tail_1614_);
v___x_1623_ = lean_uint64_dec_le(v___x_1622_, v_cap_1615_);
if (v___x_1623_ == 0)
{
uint8_t v___x_1624_;
v___x_1624_ = 0;
return v___x_1624_;
}
else
{
uint64_t v___x_1625_; uint8_t v___x_1626_;
v___x_1625_ = lean_uint64_sub(v_cap_1615_, v___x_1622_);
v___x_1626_ = lean_uint64_dec_le(v_msgLen_1616_, v___x_1625_);
if (v___x_1626_ == 0)
{
uint8_t v___x_1627_;
v___x_1627_ = 0;
return v___x_1627_;
}
else
{
uint8_t v___x_1628_;
v___x_1628_ = 1;
return v___x_1628_;
}
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_verify_sst_block(uint32_t v_magic_1808_, uint32_t v_numEntries_1809_, uint64_t v_indexOff_1810_, uint64_t v_footerOff_1811_, uint64_t v_fileSize_1812_, uint64_t v_bloomMask_1813_){
_start:
{
uint32_t v___x_1814_; uint8_t v___x_1815_;
v___x_1814_ = 1280529236;
v___x_1815_ = lean_uint32_dec_eq(v_magic_1808_, v___x_1814_);
if (v___x_1815_ == 0)
{
uint8_t v___x_1816_;
v___x_1816_ = 0;
return v___x_1816_;
}
else
{
uint8_t v___x_1817_;
v___x_1817_ = lean_uint64_dec_le(v_indexOff_1810_, v_footerOff_1811_);
if (v___x_1817_ == 0)
{
uint8_t v___x_1818_;
v___x_1818_ = 0;
return v___x_1818_;
}
else
{
uint8_t v___x_1819_;
v___x_1819_ = lean_uint64_dec_le(v_footerOff_1811_, v_fileSize_1812_);
if (v___x_1819_ == 0)
{
uint8_t v___x_1820_;
v___x_1820_ = 0;
return v___x_1820_;
}
else
{
uint32_t v___x_1821_; uint8_t v___x_1822_;
v___x_1821_ = 0;
v___x_1822_ = lean_uint32_dec_eq(v_numEntries_1809_, v___x_1821_);
if (v___x_1822_ == 0)
{
uint64_t v___x_1823_; uint8_t v___x_1824_;
v___x_1823_ = 0ULL;
v___x_1824_ = lean_uint64_dec_eq(v_bloomMask_1813_, v___x_1823_);
if (v___x_1824_ == 0)
{
uint8_t v___x_1825_;
v___x_1825_ = 1;
return v___x_1825_;
}
else
{
uint8_t v___x_1826_;
v___x_1826_ = 0;
return v___x_1826_;
}
}
else
{
uint8_t v___x_1827_;
v___x_1827_ = 1;
return v___x_1827_;
}
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_verify_poll_interest(uint32_t v_activeConns_2050_, uint32_t v_maxConns_2051_, uint32_t v_keepAliveReqs_2052_, uint32_t v_maxKeepAlive_2053_, uint32_t v_idleMs_2054_, uint32_t v_maxIdleMs_2055_){
_start:
{
uint8_t v___x_2056_;
v___x_2056_ = lean_uint32_dec_le(v_activeConns_2050_, v_maxConns_2051_);
if (v___x_2056_ == 0)
{
uint8_t v___x_2057_;
v___x_2057_ = 0;
return v___x_2057_;
}
else
{
uint32_t v___x_2058_; uint8_t v___x_2059_;
v___x_2058_ = 1024;
v___x_2059_ = lean_uint32_dec_le(v_maxConns_2051_, v___x_2058_);
if (v___x_2059_ == 0)
{
uint8_t v___x_2060_;
v___x_2060_ = 0;
return v___x_2060_;
}
else
{
uint8_t v___x_2061_;
v___x_2061_ = lean_uint32_dec_lt(v_keepAliveReqs_2052_, v_maxKeepAlive_2053_);
if (v___x_2061_ == 0)
{
uint8_t v___x_2062_;
v___x_2062_ = 0;
return v___x_2062_;
}
else
{
uint8_t v___x_2063_;
v___x_2063_ = lean_uint32_dec_le(v_idleMs_2054_, v_maxIdleMs_2055_);
if (v___x_2063_ == 0)
{
uint8_t v___x_2064_;
v___x_2064_ = 0;
return v___x_2064_;
}
else
{
uint8_t v___x_2065_;
v___x_2065_ = 1;
return v___x_2065_;
}
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_verify_rlimit_budget(uint64_t v_rssBytes_2288_, uint64_t v_maxRssBytes_2289_, uint64_t v_elapsedMs_2290_, uint64_t v_timeoutMs_2291_, uint64_t v_pipeBytes_2292_, uint64_t v_maxPipeBytes_2293_){
_start:
{
uint8_t v___x_2294_;
v___x_2294_ = lean_uint64_dec_le(v_rssBytes_2288_, v_maxRssBytes_2289_);
if (v___x_2294_ == 0)
{
uint8_t v___x_2295_;
v___x_2295_ = 0;
return v___x_2295_;
}
else
{
uint8_t v___x_2296_;
v___x_2296_ = lean_uint64_dec_le(v_elapsedMs_2290_, v_timeoutMs_2291_);
if (v___x_2296_ == 0)
{
uint8_t v___x_2297_;
v___x_2297_ = 0;
return v___x_2297_;
}
else
{
uint8_t v___x_2298_;
v___x_2298_ = lean_uint64_dec_le(v_pipeBytes_2292_, v_maxPipeBytes_2293_);
if (v___x_2298_ == 0)
{
uint8_t v___x_2299_;
v___x_2299_ = 0;
return v___x_2299_;
}
else
{
uint8_t v___x_2300_;
v___x_2300_ = 1;
return v___x_2300_;
}
}
}
}
}

LEAN_EXPORT uint64_t leansys_mix64_word(uint64_t v_acc_2516_, uint64_t v_word_2517_){
_start:
{
uint64_t v___x_2518_; uint64_t v___x_2519_; uint64_t v___x_2520_; uint64_t v___x_2521_; uint64_t v_z_2522_; uint64_t v___x_2523_; uint64_t v___x_2524_; uint64_t v___x_2525_; uint64_t v___x_2526_; uint64_t v_z1_2527_; uint64_t v___x_2528_; uint64_t v___x_2529_; uint64_t v___x_2530_;
v___x_2518_ = 11400714819323198485ULL;
v___x_2519_ = lean_uint64_mul(v_word_2517_, v___x_2518_);
v___x_2520_ = lean_uint64_xor(v_acc_2516_, v___x_2519_);
v___x_2521_ = 13787848793156543929ULL;
v_z_2522_ = lean_uint64_mul(v___x_2520_, v___x_2521_);
v___x_2523_ = 30ULL;
v___x_2524_ = lean_uint64_shift_right(v_z_2522_, v___x_2523_);
v___x_2525_ = lean_uint64_xor(v_z_2522_, v___x_2524_);
v___x_2526_ = 10723151780598845931ULL;
v_z1_2527_ = lean_uint64_mul(v___x_2525_, v___x_2526_);
v___x_2528_ = 31ULL;
v___x_2529_ = lean_uint64_shift_right(v_z1_2527_, v___x_2528_);
v___x_2530_ = lean_uint64_xor(v_z1_2527_, v___x_2529_);
return v___x_2530_;
}
}

LEAN_EXPORT uint8_t leansys_verify_composite_key_order(uint64_t v_hiA_2537_, uint64_t v_loA_2538_, uint64_t v_seqA_2539_, uint64_t v_hiB_2540_, uint64_t v_loB_2541_, uint64_t v_seqB_2542_){
_start:
{
uint8_t v___x_2543_;
v___x_2543_ = lean_uint64_dec_lt(v_hiA_2537_, v_hiB_2540_);
if (v___x_2543_ == 0)
{
uint8_t v___x_2544_;
v___x_2544_ = lean_uint64_dec_eq(v_hiA_2537_, v_hiB_2540_);
if (v___x_2544_ == 0)
{
uint8_t v___x_2545_;
v___x_2545_ = 0;
return v___x_2545_;
}
else
{
uint8_t v___x_2546_;
v___x_2546_ = lean_uint64_dec_lt(v_loA_2538_, v_loB_2541_);
if (v___x_2546_ == 0)
{
uint8_t v___x_2547_;
v___x_2547_ = lean_uint64_dec_eq(v_loA_2538_, v_loB_2541_);
if (v___x_2547_ == 0)
{
uint8_t v___x_2548_;
v___x_2548_ = 0;
return v___x_2548_;
}
else
{
uint8_t v___x_2549_;
v___x_2549_ = lean_uint64_dec_le(v_seqA_2539_, v_seqB_2542_);
if (v___x_2549_ == 0)
{
uint8_t v___x_2550_;
v___x_2550_ = 0;
return v___x_2550_;
}
else
{
uint8_t v___x_2551_;
v___x_2551_ = 1;
return v___x_2551_;
}
}
}
else
{
uint8_t v___x_2552_;
v___x_2552_ = 1;
return v___x_2552_;
}
}
}
else
{
uint8_t v___x_2553_;
v___x_2553_ = 1;
return v___x_2553_;
}
}
}

LEAN_EXPORT uint8_t leansys_verify_token_auth(uint8_t v_matchCurrent_2773_, uint8_t v_hasPrev_2774_, uint8_t v_matchPrev_2775_, uint8_t v_scopeOk_2776_, uint64_t v_nowEpoch_2777_, uint64_t v_expiresAt_2778_){
_start:
{
uint8_t v___x_2779_; uint8_t v___x_2785_;
v___x_2779_ = 1;
v___x_2785_ = lean_uint8_dec_eq(v_matchCurrent_2773_, v___x_2779_);
if (v___x_2785_ == 0)
{
uint8_t v___x_2786_;
v___x_2786_ = lean_uint8_dec_eq(v_hasPrev_2774_, v___x_2779_);
if (v___x_2786_ == 0)
{
uint8_t v___x_2787_;
v___x_2787_ = 0;
return v___x_2787_;
}
else
{
uint8_t v___x_2788_;
v___x_2788_ = lean_uint8_dec_eq(v_matchPrev_2775_, v___x_2779_);
if (v___x_2788_ == 0)
{
uint8_t v___x_2789_;
v___x_2789_ = 0;
return v___x_2789_;
}
else
{
goto v___jp_2780_;
}
}
}
else
{
goto v___jp_2780_;
}
v___jp_2780_:
{
uint8_t v___x_2781_;
v___x_2781_ = lean_uint8_dec_eq(v_scopeOk_2776_, v___x_2779_);
if (v___x_2781_ == 0)
{
uint8_t v___x_2782_;
v___x_2782_ = 0;
return v___x_2782_;
}
else
{
uint8_t v___x_2783_;
v___x_2783_ = lean_uint64_dec_lt(v_nowEpoch_2777_, v_expiresAt_2778_);
if (v___x_2783_ == 0)
{
uint8_t v___x_2784_;
v___x_2784_ = 0;
return v___x_2784_;
}
else
{
return v___x_2779_;
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_verify_log_window(uint64_t v_startOff_3016_, uint64_t v_nextOff_3017_, uint64_t v_fileLen_3018_, uint64_t v_maxBytes_3019_){
_start:
{
uint8_t v___x_3020_;
v___x_3020_ = lean_uint64_dec_le(v_startOff_3016_, v_nextOff_3017_);
if (v___x_3020_ == 0)
{
uint8_t v___x_3021_;
v___x_3021_ = 0;
return v___x_3021_;
}
else
{
uint8_t v___x_3022_;
v___x_3022_ = lean_uint64_dec_le(v_nextOff_3017_, v_fileLen_3018_);
if (v___x_3022_ == 0)
{
uint8_t v___x_3023_;
v___x_3023_ = 0;
return v___x_3023_;
}
else
{
uint64_t v___x_3024_; uint8_t v___x_3025_;
v___x_3024_ = lean_uint64_sub(v_nextOff_3017_, v_startOff_3016_);
v___x_3025_ = lean_uint64_dec_le(v___x_3024_, v_maxBytes_3019_);
if (v___x_3025_ == 0)
{
uint8_t v___x_3026_;
v___x_3026_ = 0;
return v___x_3026_;
}
else
{
uint64_t v___x_3027_; uint8_t v___x_3028_;
v___x_3027_ = 262144ULL;
v___x_3028_ = lean_uint64_dec_le(v_maxBytes_3019_, v___x_3027_);
if (v___x_3028_ == 0)
{
uint8_t v___x_3029_;
v___x_3029_ = 0;
return v___x_3029_;
}
else
{
uint8_t v___x_3030_;
v___x_3030_ = 1;
return v___x_3030_;
}
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_verify_jsonrpc_frame(uint8_t v_hasV2_3207_, uint8_t v_hasId_3208_, uint32_t v_methodLen_3209_, uint64_t v_payloadLen_3210_){
_start:
{
uint8_t v___x_3211_; uint8_t v___x_3212_;
v___x_3211_ = 1;
v___x_3212_ = lean_uint8_dec_eq(v_hasV2_3207_, v___x_3211_);
if (v___x_3212_ == 0)
{
uint8_t v___x_3213_;
v___x_3213_ = 0;
return v___x_3213_;
}
else
{
uint8_t v___x_3214_;
v___x_3214_ = lean_uint8_dec_le(v_hasId_3208_, v___x_3211_);
if (v___x_3214_ == 0)
{
uint8_t v___x_3215_;
v___x_3215_ = 0;
return v___x_3215_;
}
else
{
uint32_t v___x_3216_; uint8_t v___x_3217_;
v___x_3216_ = 0;
v___x_3217_ = lean_uint32_dec_lt(v___x_3216_, v_methodLen_3209_);
if (v___x_3217_ == 0)
{
uint8_t v___x_3218_;
v___x_3218_ = 0;
return v___x_3218_;
}
else
{
uint32_t v___x_3219_; uint8_t v___x_3220_;
v___x_3219_ = 128;
v___x_3220_ = lean_uint32_dec_le(v_methodLen_3209_, v___x_3219_);
if (v___x_3220_ == 0)
{
uint8_t v___x_3221_;
v___x_3221_ = 0;
return v___x_3221_;
}
else
{
uint64_t v___x_3222_; uint8_t v___x_3223_;
v___x_3222_ = 4194304ULL;
v___x_3223_ = lean_uint64_dec_le(v_payloadLen_3210_, v___x_3222_);
if (v___x_3223_ == 0)
{
uint8_t v___x_3224_;
v___x_3224_ = 0;
return v___x_3224_;
}
else
{
return v___x_3211_;
}
}
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_gate_admit(uint8_t v_noSorryAx_3405_, uint8_t v_statementPinned_3406_, uint8_t v_certVerified_3407_){
_start:
{
uint8_t v___x_3408_; uint8_t v___x_3409_;
v___x_3408_ = 1;
v___x_3409_ = lean_uint8_dec_eq(v_noSorryAx_3405_, v___x_3408_);
if (v___x_3409_ == 0)
{
uint8_t v___x_3410_;
v___x_3410_ = 0;
return v___x_3410_;
}
else
{
uint8_t v___x_3411_;
v___x_3411_ = lean_uint8_dec_eq(v_statementPinned_3406_, v___x_3408_);
if (v___x_3411_ == 0)
{
uint8_t v___x_3412_;
v___x_3412_ = 0;
return v___x_3412_;
}
else
{
uint8_t v___x_3413_;
v___x_3413_ = lean_uint8_dec_eq(v_certVerified_3407_, v___x_3408_);
if (v___x_3413_ == 0)
{
uint8_t v___x_3414_;
v___x_3414_ = 0;
return v___x_3414_;
}
else
{
return v___x_3408_;
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_verify_mmap_seqlock(uint32_t v_magic_3567_, uint32_t v_schemaVersion_3568_, uint32_t v_expectedVersion_3569_, uint64_t v_seqBefore_3570_, uint64_t v_seqAfter_3571_, uint64_t v_writerEpoch_3572_, uint64_t v_minEpoch_3573_, uint64_t v_payloadLen_3574_, uint64_t v_ringCap_3575_){
_start:
{
uint32_t v___x_3576_; uint8_t v___x_3577_;
v___x_3576_ = 1280527693;
v___x_3577_ = lean_uint32_dec_eq(v_magic_3567_, v___x_3576_);
if (v___x_3577_ == 0)
{
uint8_t v___x_3578_;
v___x_3578_ = 0;
return v___x_3578_;
}
else
{
uint8_t v___x_3579_;
v___x_3579_ = lean_uint32_dec_eq(v_schemaVersion_3568_, v_expectedVersion_3569_);
if (v___x_3579_ == 0)
{
uint8_t v___x_3580_;
v___x_3580_ = 0;
return v___x_3580_;
}
else
{
uint8_t v___x_3581_;
v___x_3581_ = lean_uint64_dec_eq(v_seqBefore_3570_, v_seqAfter_3571_);
if (v___x_3581_ == 0)
{
uint8_t v___x_3582_;
v___x_3582_ = 0;
return v___x_3582_;
}
else
{
uint64_t v___x_3583_; uint64_t v___x_3584_; uint64_t v___x_3585_; uint8_t v___x_3586_;
v___x_3583_ = 2ULL;
v___x_3584_ = lean_uint64_mod(v_seqBefore_3570_, v___x_3583_);
v___x_3585_ = 0ULL;
v___x_3586_ = lean_uint64_dec_eq(v___x_3584_, v___x_3585_);
if (v___x_3586_ == 0)
{
uint8_t v___x_3587_;
v___x_3587_ = 0;
return v___x_3587_;
}
else
{
uint8_t v___x_3588_;
v___x_3588_ = lean_uint64_dec_le(v_minEpoch_3573_, v_writerEpoch_3572_);
if (v___x_3588_ == 0)
{
uint8_t v___x_3589_;
v___x_3589_ = 0;
return v___x_3589_;
}
else
{
uint8_t v___x_3590_;
v___x_3590_ = lean_uint64_dec_le(v_payloadLen_3574_, v_ringCap_3575_);
if (v___x_3590_ == 0)
{
uint8_t v___x_3591_;
v___x_3591_ = 0;
return v___x_3591_;
}
else
{
uint8_t v___x_3592_;
v___x_3592_ = 1;
return v___x_3592_;
}
}
}
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_verify_proc_stat_fields(uint64_t v_commOpenIdx_3968_, uint64_t v_commCloseIdx_3969_, uint64_t v_totalLen_3970_, uint64_t v_minFieldsAfterComm_3971_, uint64_t v_actualFields_3972_){
_start:
{
uint8_t v___x_3973_;
v___x_3973_ = lean_uint64_dec_lt(v_commOpenIdx_3968_, v_commCloseIdx_3969_);
if (v___x_3973_ == 0)
{
uint8_t v___x_3974_;
v___x_3974_ = 0;
return v___x_3974_;
}
else
{
uint64_t v___x_3975_; uint64_t v___x_3976_; uint8_t v___x_3977_;
v___x_3975_ = 2ULL;
v___x_3976_ = lean_uint64_add(v_commCloseIdx_3969_, v___x_3975_);
v___x_3977_ = lean_uint64_dec_le(v___x_3976_, v_totalLen_3970_);
if (v___x_3977_ == 0)
{
uint8_t v___x_3978_;
v___x_3978_ = 0;
return v___x_3978_;
}
else
{
uint8_t v___x_3979_;
v___x_3979_ = lean_uint64_dec_le(v_minFieldsAfterComm_3971_, v_actualFields_3972_);
if (v___x_3979_ == 0)
{
uint8_t v___x_3980_;
v___x_3980_ = 0;
return v___x_3980_;
}
else
{
uint8_t v___x_3981_;
v___x_3981_ = 1;
return v___x_3981_;
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_sse_frame_scan(uint64_t v_frameOff_4237_, uint64_t v_frameLen_4238_, uint64_t v_chunkLen_4239_, uint8_t v_fieldKind_4240_, uint8_t v_nextByte_4241_, uint8_t v_lastByte_4242_){
_start:
{
uint64_t v___x_4248_; uint8_t v___x_4249_;
v___x_4248_ = 0ULL;
v___x_4249_ = lean_uint64_dec_lt(v___x_4248_, v_frameLen_4238_);
if (v___x_4249_ == 0)
{
uint8_t v___x_4250_;
v___x_4250_ = 0;
return v___x_4250_;
}
else
{
uint8_t v___x_4251_;
v___x_4251_ = lean_uint64_dec_le(v_frameOff_4237_, v_chunkLen_4239_);
if (v___x_4251_ == 0)
{
uint8_t v___x_4252_;
v___x_4252_ = 0;
return v___x_4252_;
}
else
{
uint64_t v___x_4253_; uint8_t v___x_4254_;
v___x_4253_ = lean_uint64_sub(v_chunkLen_4239_, v_frameOff_4237_);
v___x_4254_ = lean_uint64_dec_le(v_frameLen_4238_, v___x_4253_);
if (v___x_4254_ == 0)
{
uint8_t v___x_4255_;
v___x_4255_ = 0;
return v___x_4255_;
}
else
{
uint8_t v___x_4256_; uint8_t v___x_4257_;
v___x_4256_ = 1;
v___x_4257_ = lean_uint8_dec_le(v___x_4256_, v_fieldKind_4240_);
if (v___x_4257_ == 0)
{
uint8_t v___x_4258_;
v___x_4258_ = 0;
return v___x_4258_;
}
else
{
uint8_t v___x_4259_; uint8_t v___x_4260_;
v___x_4259_ = 4;
v___x_4260_ = lean_uint8_dec_le(v_fieldKind_4240_, v___x_4259_);
if (v___x_4260_ == 0)
{
uint8_t v___x_4261_;
v___x_4261_ = 0;
return v___x_4261_;
}
else
{
uint8_t v___x_4262_; uint8_t v___x_4263_;
v___x_4262_ = 128;
v___x_4263_ = lean_uint8_dec_lt(v_nextByte_4241_, v___x_4262_);
if (v___x_4263_ == 0)
{
uint8_t v___x_4264_; uint8_t v___x_4265_;
v___x_4264_ = 191;
v___x_4265_ = lean_uint8_dec_lt(v___x_4264_, v_nextByte_4241_);
if (v___x_4265_ == 0)
{
uint8_t v___x_4266_;
v___x_4266_ = 0;
return v___x_4266_;
}
else
{
goto v___jp_4243_;
}
}
else
{
goto v___jp_4243_;
}
}
}
}
}
}
v___jp_4243_:
{
uint8_t v___x_4244_; uint8_t v___x_4245_;
v___x_4244_ = 192;
v___x_4245_ = lean_uint8_dec_lt(v_lastByte_4242_, v___x_4244_);
if (v___x_4245_ == 0)
{
uint8_t v___x_4246_;
v___x_4246_ = 0;
return v___x_4246_;
}
else
{
uint8_t v___x_4247_;
v___x_4247_ = 1;
return v___x_4247_;
}
}
}
}

LEAN_EXPORT uint8_t leansys_gfm_pipe_scan(uint64_t v_rowOff_4510_, uint64_t v_rowLen_4511_, uint64_t v_bufLen_4512_, uint32_t v_colCount_4513_, uint32_t v_sepCols_4514_, uint8_t v_unterminatedEscape_4515_){
_start:
{
uint64_t v___x_4516_; uint8_t v___x_4517_;
v___x_4516_ = 0ULL;
v___x_4517_ = lean_uint64_dec_lt(v___x_4516_, v_rowLen_4511_);
if (v___x_4517_ == 0)
{
uint8_t v___x_4518_;
v___x_4518_ = 0;
return v___x_4518_;
}
else
{
uint8_t v___x_4519_;
v___x_4519_ = lean_uint64_dec_le(v_rowOff_4510_, v_bufLen_4512_);
if (v___x_4519_ == 0)
{
uint8_t v___x_4520_;
v___x_4520_ = 0;
return v___x_4520_;
}
else
{
uint64_t v___x_4521_; uint8_t v___x_4522_;
v___x_4521_ = lean_uint64_sub(v_bufLen_4512_, v_rowOff_4510_);
v___x_4522_ = lean_uint64_dec_le(v_rowLen_4511_, v___x_4521_);
if (v___x_4522_ == 0)
{
uint8_t v___x_4523_;
v___x_4523_ = 0;
return v___x_4523_;
}
else
{
uint32_t v___x_4524_; uint8_t v___x_4525_;
v___x_4524_ = 0;
v___x_4525_ = lean_uint32_dec_lt(v___x_4524_, v_colCount_4513_);
if (v___x_4525_ == 0)
{
uint8_t v___x_4526_;
v___x_4526_ = 0;
return v___x_4526_;
}
else
{
uint32_t v___x_4527_; uint8_t v___x_4528_;
v___x_4527_ = 64;
v___x_4528_ = lean_uint32_dec_le(v_colCount_4513_, v___x_4527_);
if (v___x_4528_ == 0)
{
uint8_t v___x_4529_;
v___x_4529_ = 0;
return v___x_4529_;
}
else
{
uint8_t v___x_4530_;
v___x_4530_ = lean_uint32_dec_eq(v_colCount_4513_, v_sepCols_4514_);
if (v___x_4530_ == 0)
{
uint8_t v___x_4531_;
v___x_4531_ = 0;
return v___x_4531_;
}
else
{
uint8_t v___x_4532_; uint8_t v___x_4533_;
v___x_4532_ = 0;
v___x_4533_ = lean_uint8_dec_eq(v_unterminatedEscape_4515_, v___x_4532_);
if (v___x_4533_ == 0)
{
return v___x_4532_;
}
else
{
uint8_t v___x_4534_;
v___x_4534_ = 1;
return v___x_4534_;
}
}
}
}
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_tag_scan(uint64_t v_tagOff_4768_, uint64_t v_tagLen_4769_, uint64_t v_attrOff_4770_, uint64_t v_attrLen_4771_, uint64_t v_bufLen_4772_, uint8_t v_tagKind_4773_){
_start:
{
uint64_t v___x_4774_; uint8_t v___x_4775_;
v___x_4774_ = 0ULL;
v___x_4775_ = lean_uint64_dec_lt(v___x_4774_, v_tagLen_4769_);
if (v___x_4775_ == 0)
{
uint8_t v___x_4776_;
v___x_4776_ = 0;
return v___x_4776_;
}
else
{
uint8_t v___x_4777_;
v___x_4777_ = lean_uint64_dec_le(v_tagOff_4768_, v_bufLen_4772_);
if (v___x_4777_ == 0)
{
uint8_t v___x_4778_;
v___x_4778_ = 0;
return v___x_4778_;
}
else
{
uint64_t v___x_4779_; uint8_t v___x_4780_;
v___x_4779_ = lean_uint64_sub(v_bufLen_4772_, v_tagOff_4768_);
v___x_4780_ = lean_uint64_dec_le(v_tagLen_4769_, v___x_4779_);
if (v___x_4780_ == 0)
{
uint8_t v___x_4781_;
v___x_4781_ = 0;
return v___x_4781_;
}
else
{
uint8_t v___x_4782_;
v___x_4782_ = lean_uint64_dec_le(v_tagOff_4768_, v_attrOff_4770_);
if (v___x_4782_ == 0)
{
uint8_t v___x_4783_;
v___x_4783_ = 0;
return v___x_4783_;
}
else
{
uint64_t v___x_4784_; uint8_t v___x_4785_;
v___x_4784_ = lean_uint64_sub(v_attrOff_4770_, v_tagOff_4768_);
v___x_4785_ = lean_uint64_dec_le(v___x_4784_, v_tagLen_4769_);
if (v___x_4785_ == 0)
{
uint8_t v___x_4786_;
v___x_4786_ = 0;
return v___x_4786_;
}
else
{
uint64_t v___x_4787_; uint8_t v___x_4788_;
v___x_4787_ = lean_uint64_sub(v_tagLen_4769_, v___x_4784_);
v___x_4788_ = lean_uint64_dec_le(v_attrLen_4771_, v___x_4787_);
if (v___x_4788_ == 0)
{
uint8_t v___x_4789_;
v___x_4789_ = 0;
return v___x_4789_;
}
else
{
uint8_t v___x_4790_; uint8_t v___x_4791_;
v___x_4790_ = 1;
v___x_4791_ = lean_uint8_dec_le(v___x_4790_, v_tagKind_4773_);
if (v___x_4791_ == 0)
{
uint8_t v___x_4792_;
v___x_4792_ = 0;
return v___x_4792_;
}
else
{
uint8_t v___x_4793_; uint8_t v___x_4794_;
v___x_4793_ = 3;
v___x_4794_ = lean_uint8_dec_le(v_tagKind_4773_, v___x_4793_);
if (v___x_4794_ == 0)
{
uint8_t v___x_4795_;
v___x_4795_ = 0;
return v___x_4795_;
}
else
{
return v___x_4790_;
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

LEAN_EXPORT uint64_t leansys_transcript_index(uint64_t v_turnOff_5004_, uint64_t v_turnLen_5005_, uint64_t v_bufLen_5006_, uint64_t v_prevDigest_5007_, uint64_t v_blockHash_5008_){
_start:
{
uint64_t v___x_5009_; uint8_t v___x_5010_;
v___x_5009_ = 0ULL;
v___x_5010_ = lean_uint64_dec_lt(v___x_5009_, v_turnLen_5005_);
if (v___x_5010_ == 0)
{
return v___x_5009_;
}
else
{
uint8_t v___x_5011_;
v___x_5011_ = lean_uint64_dec_le(v_turnOff_5004_, v_bufLen_5006_);
if (v___x_5011_ == 0)
{
return v___x_5009_;
}
else
{
uint64_t v___x_5012_; uint8_t v___x_5013_;
v___x_5012_ = lean_uint64_sub(v_bufLen_5006_, v_turnOff_5004_);
v___x_5013_ = lean_uint64_dec_le(v_turnLen_5005_, v___x_5012_);
if (v___x_5013_ == 0)
{
return v___x_5009_;
}
else
{
uint64_t v___x_5014_; uint64_t v___x_5015_; uint64_t v___x_5016_; uint64_t v___x_5017_; uint64_t v___x_5018_; uint64_t v_z_5019_; uint64_t v___x_5020_; uint64_t v___x_5021_; uint64_t v___x_5022_; uint64_t v___x_5023_; uint64_t v_z1_5024_; uint64_t v___x_5025_; uint64_t v___x_5026_; uint64_t v_mixed_5027_; uint8_t v___x_5028_;
v___x_5014_ = lean_uint64_xor(v_prevDigest_5007_, v_turnLen_5005_);
v___x_5015_ = 11400714819323198485ULL;
v___x_5016_ = lean_uint64_mul(v_blockHash_5008_, v___x_5015_);
v___x_5017_ = lean_uint64_xor(v___x_5014_, v___x_5016_);
v___x_5018_ = 13787848793156543929ULL;
v_z_5019_ = lean_uint64_mul(v___x_5017_, v___x_5018_);
v___x_5020_ = 30ULL;
v___x_5021_ = lean_uint64_shift_right(v_z_5019_, v___x_5020_);
v___x_5022_ = lean_uint64_xor(v_z_5019_, v___x_5021_);
v___x_5023_ = 10723151780598845931ULL;
v_z1_5024_ = lean_uint64_mul(v___x_5022_, v___x_5023_);
v___x_5025_ = 31ULL;
v___x_5026_ = lean_uint64_shift_right(v_z1_5024_, v___x_5025_);
v_mixed_5027_ = lean_uint64_xor(v_z1_5024_, v___x_5026_);
v___x_5028_ = lean_uint64_dec_eq(v_mixed_5027_, v___x_5009_);
if (v___x_5028_ == 0)
{
return v_mixed_5027_;
}
else
{
uint64_t v___x_5029_;
v___x_5029_ = 1ULL;
return v___x_5029_;
}
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_verify_par_chunk(uint64_t v_chunkStart_5207_, uint64_t v_chunkEnd_5208_, uint64_t v_totalLen_5209_, uint64_t v_minGrain_5210_){
_start:
{
uint8_t v___x_5211_;
v___x_5211_ = lean_uint64_dec_lt(v_chunkStart_5207_, v_chunkEnd_5208_);
if (v___x_5211_ == 0)
{
uint8_t v___x_5212_;
v___x_5212_ = 0;
return v___x_5212_;
}
else
{
uint8_t v___x_5213_;
v___x_5213_ = lean_uint64_dec_le(v_chunkEnd_5208_, v_totalLen_5209_);
if (v___x_5213_ == 0)
{
uint8_t v___x_5214_;
v___x_5214_ = 0;
return v___x_5214_;
}
else
{
uint64_t v___x_5215_; uint8_t v___x_5216_;
v___x_5215_ = lean_uint64_sub(v_chunkEnd_5208_, v_chunkStart_5207_);
v___x_5216_ = lean_uint64_dec_le(v_minGrain_5210_, v___x_5215_);
if (v___x_5216_ == 0)
{
uint8_t v___x_5217_;
v___x_5217_ = lean_uint64_dec_eq(v_chunkEnd_5208_, v_totalLen_5209_);
if (v___x_5217_ == 0)
{
uint8_t v___x_5218_;
v___x_5218_ = 0;
return v___x_5218_;
}
else
{
uint8_t v___x_5219_;
v___x_5219_ = 1;
return v___x_5219_;
}
}
else
{
uint8_t v___x_5220_;
v___x_5220_ = 1;
return v___x_5220_;
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_verify_arena_disjoint(uint64_t v_offA_5388_, uint64_t v_lenA_5389_, uint64_t v_offB_5390_, uint64_t v_lenB_5391_, uint64_t v_arenaCap_5392_){
_start:
{
uint8_t v___x_5393_;
v___x_5393_ = lean_uint64_dec_le(v_offA_5388_, v_arenaCap_5392_);
if (v___x_5393_ == 0)
{
uint8_t v___x_5394_;
v___x_5394_ = 0;
return v___x_5394_;
}
else
{
uint64_t v___x_5395_; uint8_t v___x_5396_;
v___x_5395_ = lean_uint64_sub(v_arenaCap_5392_, v_offA_5388_);
v___x_5396_ = lean_uint64_dec_le(v_lenA_5389_, v___x_5395_);
if (v___x_5396_ == 0)
{
uint8_t v___x_5397_;
v___x_5397_ = 0;
return v___x_5397_;
}
else
{
uint8_t v___x_5398_;
v___x_5398_ = lean_uint64_dec_le(v_offB_5390_, v_arenaCap_5392_);
if (v___x_5398_ == 0)
{
uint8_t v___x_5399_;
v___x_5399_ = 0;
return v___x_5399_;
}
else
{
uint64_t v___x_5400_; uint8_t v___x_5401_;
v___x_5400_ = lean_uint64_sub(v_arenaCap_5392_, v_offB_5390_);
v___x_5401_ = lean_uint64_dec_le(v_lenB_5391_, v___x_5400_);
if (v___x_5401_ == 0)
{
uint8_t v___x_5402_;
v___x_5402_ = 0;
return v___x_5402_;
}
else
{
uint64_t v___x_5403_; uint8_t v___x_5404_;
v___x_5403_ = lean_uint64_add(v_offA_5388_, v_lenA_5389_);
v___x_5404_ = lean_uint64_dec_le(v___x_5403_, v_offB_5390_);
if (v___x_5404_ == 0)
{
uint64_t v___x_5405_; uint8_t v___x_5406_;
v___x_5405_ = lean_uint64_add(v_offB_5390_, v_lenB_5391_);
v___x_5406_ = lean_uint64_dec_le(v___x_5405_, v_offA_5388_);
if (v___x_5406_ == 0)
{
uint8_t v___x_5407_;
v___x_5407_ = 0;
return v___x_5407_;
}
else
{
uint8_t v___x_5408_;
v___x_5408_ = 1;
return v___x_5408_;
}
}
else
{
uint8_t v___x_5409_;
v___x_5409_ = 1;
return v___x_5409_;
}
}
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_verify_snapshot_visibility(uint64_t v_entrySeq_5605_, uint64_t v_maxSnapshotSeq_5606_, uint8_t v_isTombstone_5607_){
_start:
{
uint8_t v___x_5608_;
v___x_5608_ = lean_uint64_dec_le(v_entrySeq_5605_, v_maxSnapshotSeq_5606_);
if (v___x_5608_ == 0)
{
uint8_t v___x_5609_;
v___x_5609_ = 0;
return v___x_5609_;
}
else
{
uint8_t v___x_5610_; uint8_t v___x_5611_;
v___x_5610_ = 0;
v___x_5611_ = lean_uint8_dec_eq(v_isTombstone_5607_, v___x_5610_);
if (v___x_5611_ == 0)
{
return v___x_5610_;
}
else
{
uint8_t v___x_5612_;
v___x_5612_ = 1;
return v___x_5612_;
}
}
}
}

LEAN_EXPORT uint8_t leansys_verify_http_route_match(uint8_t v_methodMatch_5759_, uint8_t v_pathMatch_5760_, uint32_t v_routeIdx_5761_, uint32_t v_routeCount_5762_){
_start:
{
uint8_t v___x_5763_; uint8_t v___x_5764_;
v___x_5763_ = 1;
v___x_5764_ = lean_uint8_dec_eq(v_methodMatch_5759_, v___x_5763_);
if (v___x_5764_ == 0)
{
uint8_t v___x_5765_;
v___x_5765_ = 0;
return v___x_5765_;
}
else
{
uint8_t v___x_5766_;
v___x_5766_ = lean_uint8_dec_eq(v_pathMatch_5760_, v___x_5763_);
if (v___x_5766_ == 0)
{
uint8_t v___x_5767_;
v___x_5767_ = 0;
return v___x_5767_;
}
else
{
uint8_t v___x_5768_;
v___x_5768_ = lean_uint32_dec_lt(v_routeIdx_5761_, v_routeCount_5762_);
if (v___x_5768_ == 0)
{
uint8_t v___x_5769_;
v___x_5769_ = 0;
return v___x_5769_;
}
else
{
uint32_t v___x_5770_; uint8_t v___x_5771_;
v___x_5770_ = 64;
v___x_5771_ = lean_uint32_dec_le(v_routeCount_5762_, v___x_5770_);
if (v___x_5771_ == 0)
{
uint8_t v___x_5772_;
v___x_5772_ = 0;
return v___x_5772_;
}
else
{
return v___x_5763_;
}
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_verify_counterexample_triage(uint8_t v_hasViolation_5934_, uint8_t v_hasMissingHypHint_5935_, uint8_t v_refDisagreesWithCandidate_5936_, uint8_t v_triageClass_5937_){
_start:
{
uint8_t v___x_5938_; uint8_t v___x_5951_;
v___x_5938_ = 1;
v___x_5951_ = lean_uint8_dec_eq(v_hasViolation_5934_, v___x_5938_);
if (v___x_5951_ == 0)
{
uint8_t v___x_5952_;
v___x_5952_ = 0;
return v___x_5952_;
}
else
{
uint8_t v___x_5953_;
v___x_5953_ = lean_uint8_dec_eq(v_hasMissingHypHint_5935_, v___x_5938_);
if (v___x_5953_ == 0)
{
goto v___jp_5945_;
}
else
{
uint8_t v___x_5954_;
v___x_5954_ = lean_uint8_dec_eq(v_triageClass_5937_, v___x_5938_);
if (v___x_5954_ == 0)
{
goto v___jp_5945_;
}
else
{
return v___x_5938_;
}
}
}
v___jp_5939_:
{
uint8_t v___x_5940_; uint8_t v___x_5941_;
v___x_5940_ = 0;
v___x_5941_ = lean_uint8_dec_eq(v_hasMissingHypHint_5935_, v___x_5940_);
if (v___x_5941_ == 0)
{
return v___x_5940_;
}
else
{
uint8_t v___x_5942_;
v___x_5942_ = lean_uint8_dec_eq(v_refDisagreesWithCandidate_5936_, v___x_5940_);
if (v___x_5942_ == 0)
{
return v___x_5940_;
}
else
{
uint8_t v___x_5943_; uint8_t v___x_5944_;
v___x_5943_ = 3;
v___x_5944_ = lean_uint8_dec_eq(v_triageClass_5937_, v___x_5943_);
if (v___x_5944_ == 0)
{
return v___x_5940_;
}
else
{
return v___x_5938_;
}
}
}
}
v___jp_5945_:
{
uint8_t v___x_5946_; uint8_t v___x_5947_;
v___x_5946_ = 0;
v___x_5947_ = lean_uint8_dec_eq(v_hasMissingHypHint_5935_, v___x_5946_);
if (v___x_5947_ == 0)
{
goto v___jp_5939_;
}
else
{
uint8_t v___x_5948_;
v___x_5948_ = lean_uint8_dec_eq(v_refDisagreesWithCandidate_5936_, v___x_5938_);
if (v___x_5948_ == 0)
{
goto v___jp_5939_;
}
else
{
uint8_t v___x_5949_; uint8_t v___x_5950_;
v___x_5949_ = 2;
v___x_5950_ = lean_uint8_dec_eq(v_triageClass_5937_, v___x_5949_);
if (v___x_5950_ == 0)
{
goto v___jp_5939_;
}
else
{
return v___x_5938_;
}
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_verify_dag_wave_step(uint64_t v_inDegreeSum_6131_, uint64_t v_waveSize_6132_, uint64_t v_completedTasks_6133_, uint64_t v_totalTasks_6134_, uint64_t v_activeWorkers_6135_, uint64_t v_maxWorkers_6136_){
_start:
{
uint64_t v___x_6137_; uint8_t v___x_6138_;
v___x_6137_ = 0ULL;
v___x_6138_ = lean_uint64_dec_eq(v_inDegreeSum_6131_, v___x_6137_);
if (v___x_6138_ == 0)
{
uint8_t v___x_6139_;
v___x_6139_ = 0;
return v___x_6139_;
}
else
{
uint8_t v___x_6140_;
v___x_6140_ = lean_uint64_dec_lt(v___x_6137_, v_waveSize_6132_);
if (v___x_6140_ == 0)
{
uint8_t v___x_6141_;
v___x_6141_ = 0;
return v___x_6141_;
}
else
{
uint8_t v___x_6142_;
v___x_6142_ = lean_uint64_dec_le(v_completedTasks_6133_, v_totalTasks_6134_);
if (v___x_6142_ == 0)
{
uint8_t v___x_6143_;
v___x_6143_ = 0;
return v___x_6143_;
}
else
{
uint64_t v___x_6144_; uint8_t v___x_6145_;
v___x_6144_ = lean_uint64_sub(v_totalTasks_6134_, v_completedTasks_6133_);
v___x_6145_ = lean_uint64_dec_le(v_waveSize_6132_, v___x_6144_);
if (v___x_6145_ == 0)
{
uint8_t v___x_6146_;
v___x_6146_ = 0;
return v___x_6146_;
}
else
{
uint8_t v___x_6147_;
v___x_6147_ = lean_uint64_dec_lt(v___x_6137_, v_activeWorkers_6135_);
if (v___x_6147_ == 0)
{
uint8_t v___x_6148_;
v___x_6148_ = 0;
return v___x_6148_;
}
else
{
uint8_t v___x_6149_;
v___x_6149_ = lean_uint64_dec_le(v_activeWorkers_6135_, v_maxWorkers_6136_);
if (v___x_6149_ == 0)
{
uint8_t v___x_6150_;
v___x_6150_ = 0;
return v___x_6150_;
}
else
{
uint8_t v___x_6151_;
v___x_6151_ = 1;
return v___x_6151_;
}
}
}
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_verify_ios_jetsam_budget(uint64_t v_dirtyRssBytes_6344_, uint64_t v_allocBytes_6345_, uint64_t v_maxJetsamBytes_6346_, uint64_t v_pageAlignMask_6347_, uint8_t v_isAppExtension_6348_){
_start:
{
uint64_t v___x_6349_; uint8_t v___x_6350_;
v___x_6349_ = 0ULL;
v___x_6350_ = lean_uint64_dec_lt(v___x_6349_, v_allocBytes_6345_);
if (v___x_6350_ == 0)
{
uint8_t v___x_6351_;
v___x_6351_ = 0;
return v___x_6351_;
}
else
{
uint64_t v___x_6352_; uint8_t v___x_6353_;
v___x_6352_ = 16383ULL;
v___x_6353_ = lean_uint64_dec_eq(v_pageAlignMask_6347_, v___x_6352_);
if (v___x_6353_ == 0)
{
uint8_t v___x_6354_;
v___x_6354_ = 0;
return v___x_6354_;
}
else
{
uint8_t v___x_6355_;
v___x_6355_ = lean_uint64_dec_le(v_dirtyRssBytes_6344_, v_maxJetsamBytes_6346_);
if (v___x_6355_ == 0)
{
uint8_t v___x_6356_;
v___x_6356_ = 0;
return v___x_6356_;
}
else
{
uint64_t v___x_6357_; uint8_t v___x_6358_;
v___x_6357_ = lean_uint64_sub(v_maxJetsamBytes_6346_, v_dirtyRssBytes_6344_);
v___x_6358_ = lean_uint64_dec_le(v_allocBytes_6345_, v___x_6357_);
if (v___x_6358_ == 0)
{
uint8_t v___x_6359_;
v___x_6359_ = 0;
return v___x_6359_;
}
else
{
uint8_t v___x_6360_; uint8_t v___x_6361_;
v___x_6360_ = 1;
v___x_6361_ = lean_uint8_dec_le(v_isAppExtension_6348_, v___x_6360_);
if (v___x_6361_ == 0)
{
uint8_t v___x_6362_;
v___x_6362_ = 0;
return v___x_6362_;
}
else
{
uint8_t v___x_6363_; uint8_t v___x_6364_;
v___x_6363_ = 0;
v___x_6364_ = lean_uint8_dec_eq(v_isAppExtension_6348_, v___x_6363_);
if (v___x_6364_ == 0)
{
uint64_t v___x_6365_; uint8_t v___x_6366_;
v___x_6365_ = 25165824ULL;
v___x_6366_ = lean_uint64_dec_le(v_maxJetsamBytes_6346_, v___x_6365_);
if (v___x_6366_ == 0)
{
return v___x_6363_;
}
else
{
return v___x_6360_;
}
}
else
{
return v___x_6360_;
}
}
}
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_verify_worker_budget(uint64_t v_activeWorkers_6559_, uint64_t v_maxWorkers_6560_, uint64_t v_microChunks_6561_, uint64_t v_totalLen_6562_, uint8_t v_topologyKind_6563_){
_start:
{
uint64_t v___x_6572_; uint8_t v___x_6573_;
v___x_6572_ = 0ULL;
v___x_6573_ = lean_uint64_dec_lt(v___x_6572_, v_activeWorkers_6559_);
if (v___x_6573_ == 0)
{
uint8_t v___x_6574_;
v___x_6574_ = 0;
return v___x_6574_;
}
else
{
uint8_t v___x_6575_;
v___x_6575_ = lean_uint64_dec_le(v_activeWorkers_6559_, v_maxWorkers_6560_);
if (v___x_6575_ == 0)
{
uint8_t v___x_6576_;
v___x_6576_ = 0;
return v___x_6576_;
}
else
{
uint64_t v___x_6577_; uint8_t v___x_6578_;
v___x_6577_ = 64ULL;
v___x_6578_ = lean_uint64_dec_le(v_maxWorkers_6560_, v___x_6577_);
if (v___x_6578_ == 0)
{
uint8_t v___x_6579_;
v___x_6579_ = 0;
return v___x_6579_;
}
else
{
uint8_t v___x_6580_;
v___x_6580_ = lean_uint64_dec_lt(v___x_6572_, v_totalLen_6562_);
if (v___x_6580_ == 0)
{
uint8_t v___x_6581_;
v___x_6581_ = 0;
return v___x_6581_;
}
else
{
uint8_t v___x_6582_;
v___x_6582_ = lean_uint64_dec_le(v_activeWorkers_6559_, v_microChunks_6561_);
if (v___x_6582_ == 0)
{
uint8_t v___x_6583_;
v___x_6583_ = 0;
return v___x_6583_;
}
else
{
uint64_t v___x_6584_; uint64_t v___x_6585_; uint8_t v___x_6586_;
v___x_6584_ = 3ULL;
v___x_6585_ = lean_uint64_shift_left(v_maxWorkers_6560_, v___x_6584_);
v___x_6586_ = lean_uint64_dec_le(v_microChunks_6561_, v___x_6585_);
if (v___x_6586_ == 0)
{
uint8_t v___x_6587_;
v___x_6587_ = 0;
return v___x_6587_;
}
else
{
uint8_t v___x_6588_; uint8_t v___x_6589_;
v___x_6588_ = 2;
v___x_6589_ = lean_uint8_dec_le(v_topologyKind_6563_, v___x_6588_);
if (v___x_6589_ == 0)
{
uint8_t v___x_6590_;
v___x_6590_ = 0;
return v___x_6590_;
}
else
{
uint8_t v___x_6591_; uint8_t v___x_6592_;
v___x_6591_ = 1;
v___x_6592_ = lean_uint8_dec_eq(v_topologyKind_6563_, v___x_6591_);
if (v___x_6592_ == 0)
{
goto v___jp_6564_;
}
else
{
uint64_t v___x_6593_; uint8_t v___x_6594_;
v___x_6593_ = 6ULL;
v___x_6594_ = lean_uint64_dec_le(v_maxWorkers_6560_, v___x_6593_);
if (v___x_6594_ == 0)
{
uint8_t v___x_6595_;
v___x_6595_ = 0;
return v___x_6595_;
}
else
{
goto v___jp_6564_;
}
}
}
}
}
}
}
}
}
v___jp_6564_:
{
uint8_t v___x_6565_; uint8_t v___x_6566_;
v___x_6565_ = 2;
v___x_6566_ = lean_uint8_dec_eq(v_topologyKind_6563_, v___x_6565_);
if (v___x_6566_ == 0)
{
uint8_t v___x_6567_;
v___x_6567_ = 1;
return v___x_6567_;
}
else
{
uint64_t v___x_6568_; uint8_t v___x_6569_;
v___x_6568_ = 9ULL;
v___x_6569_ = lean_uint64_dec_le(v_maxWorkers_6560_, v___x_6568_);
if (v___x_6569_ == 0)
{
uint8_t v___x_6570_;
v___x_6570_ = 0;
return v___x_6570_;
}
else
{
uint8_t v___x_6571_;
v___x_6571_ = 1;
return v___x_6571_;
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_verify_page_aligned_buffer(uint64_t v_addr_6812_, uint64_t v_allocBytes_6813_, uint64_t v_capacityBytes_6814_, uint64_t v_dirtyRssBytes_6815_, uint64_t v_maxBudgetBytes_6816_, uint64_t v_pageAlignMask_6817_){
_start:
{
uint64_t v___x_6830_; uint8_t v___x_6831_;
v___x_6830_ = 0ULL;
v___x_6831_ = lean_uint64_dec_lt(v___x_6830_, v_addr_6812_);
if (v___x_6831_ == 0)
{
uint8_t v___x_6832_;
v___x_6832_ = 0;
return v___x_6832_;
}
else
{
uint8_t v___x_6833_;
v___x_6833_ = lean_uint64_dec_lt(v___x_6830_, v_allocBytes_6813_);
if (v___x_6833_ == 0)
{
uint8_t v___x_6834_;
v___x_6834_ = 0;
return v___x_6834_;
}
else
{
uint8_t v___x_6835_;
v___x_6835_ = lean_uint64_dec_le(v_allocBytes_6813_, v_capacityBytes_6814_);
if (v___x_6835_ == 0)
{
uint8_t v___x_6836_;
v___x_6836_ = 0;
return v___x_6836_;
}
else
{
uint64_t v___x_6837_; uint8_t v___x_6838_;
v___x_6837_ = 4095ULL;
v___x_6838_ = lean_uint64_dec_eq(v_pageAlignMask_6817_, v___x_6837_);
if (v___x_6838_ == 0)
{
uint64_t v___x_6839_; uint8_t v___x_6840_;
v___x_6839_ = 16383ULL;
v___x_6840_ = lean_uint64_dec_eq(v_pageAlignMask_6817_, v___x_6839_);
if (v___x_6840_ == 0)
{
uint8_t v___x_6841_;
v___x_6841_ = 0;
return v___x_6841_;
}
else
{
goto v___jp_6818_;
}
}
else
{
goto v___jp_6818_;
}
}
}
}
v___jp_6818_:
{
uint64_t v___x_6819_; uint64_t v___x_6820_; uint64_t v___x_6821_; uint8_t v___x_6822_;
v___x_6819_ = lean_uint64_lor(v_addr_6812_, v_capacityBytes_6814_);
v___x_6820_ = lean_uint64_land(v___x_6819_, v_pageAlignMask_6817_);
v___x_6821_ = 0ULL;
v___x_6822_ = lean_uint64_dec_eq(v___x_6820_, v___x_6821_);
if (v___x_6822_ == 0)
{
uint8_t v___x_6823_;
v___x_6823_ = 0;
return v___x_6823_;
}
else
{
uint8_t v___x_6824_;
v___x_6824_ = lean_uint64_dec_le(v_dirtyRssBytes_6815_, v_maxBudgetBytes_6816_);
if (v___x_6824_ == 0)
{
uint8_t v___x_6825_;
v___x_6825_ = 0;
return v___x_6825_;
}
else
{
uint64_t v___x_6826_; uint8_t v___x_6827_;
v___x_6826_ = lean_uint64_sub(v_maxBudgetBytes_6816_, v_dirtyRssBytes_6815_);
v___x_6827_ = lean_uint64_dec_le(v_capacityBytes_6814_, v___x_6826_);
if (v___x_6827_ == 0)
{
uint8_t v___x_6828_;
v___x_6828_ = 0;
return v___x_6828_;
}
else
{
uint8_t v___x_6829_;
v___x_6829_ = 1;
return v___x_6829_;
}
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_select_isa(uint64_t v_detectedHwCaps_7084_, uint64_t v_requiredMask_7085_, uint8_t v_requestedVariantId_7086_, uint8_t v_maxVariantId_7087_){
_start:
{
uint8_t v___x_7088_; uint64_t v___y_7090_; uint8_t v___x_7094_;
v___x_7088_ = 0;
v___x_7094_ = lean_uint8_dec_lt(v___x_7088_, v_requestedVariantId_7086_);
if (v___x_7094_ == 0)
{
return v___x_7088_;
}
else
{
uint8_t v___x_7095_;
v___x_7095_ = lean_uint8_dec_le(v_requestedVariantId_7086_, v_maxVariantId_7087_);
if (v___x_7095_ == 0)
{
return v___x_7088_;
}
else
{
uint8_t v___x_7096_; uint8_t v___x_7097_;
v___x_7096_ = 6;
v___x_7097_ = lean_uint8_dec_le(v_maxVariantId_7087_, v___x_7096_);
if (v___x_7097_ == 0)
{
return v___x_7088_;
}
else
{
uint8_t v___x_7098_;
v___x_7098_ = lean_uint8_dec_eq(v_requestedVariantId_7086_, v___x_7088_);
if (v___x_7098_ == 0)
{
uint8_t v___x_7099_; uint8_t v___x_7100_;
v___x_7099_ = 1;
v___x_7100_ = lean_uint8_dec_eq(v_requestedVariantId_7086_, v___x_7099_);
if (v___x_7100_ == 0)
{
uint8_t v___x_7101_; uint8_t v___x_7102_;
v___x_7101_ = 2;
v___x_7102_ = lean_uint8_dec_eq(v_requestedVariantId_7086_, v___x_7101_);
if (v___x_7102_ == 0)
{
uint8_t v___x_7103_; uint8_t v___x_7104_;
v___x_7103_ = 3;
v___x_7104_ = lean_uint8_dec_eq(v_requestedVariantId_7086_, v___x_7103_);
if (v___x_7104_ == 0)
{
uint8_t v___x_7105_; uint8_t v___x_7106_;
v___x_7105_ = 4;
v___x_7106_ = lean_uint8_dec_eq(v_requestedVariantId_7086_, v___x_7105_);
if (v___x_7106_ == 0)
{
uint8_t v___x_7107_; uint8_t v___x_7108_;
v___x_7107_ = 5;
v___x_7108_ = lean_uint8_dec_eq(v_requestedVariantId_7086_, v___x_7107_);
if (v___x_7108_ == 0)
{
uint8_t v___x_7109_;
v___x_7109_ = lean_uint8_dec_eq(v_requestedVariantId_7086_, v___x_7096_);
if (v___x_7109_ == 0)
{
uint64_t v___x_7110_;
v___x_7110_ = 18446744073709551615ULL;
v___y_7090_ = v___x_7110_;
goto v___jp_7089_;
}
else
{
uint64_t v___x_7111_;
v___x_7111_ = 64512ULL;
v___y_7090_ = v___x_7111_;
goto v___jp_7089_;
}
}
else
{
uint64_t v___x_7112_;
v___x_7112_ = 31744ULL;
v___y_7090_ = v___x_7112_;
goto v___jp_7089_;
}
}
else
{
uint64_t v___x_7113_;
v___x_7113_ = 927ULL;
v___y_7090_ = v___x_7113_;
goto v___jp_7089_;
}
}
else
{
uint64_t v___x_7114_;
v___x_7114_ = 895ULL;
v___y_7090_ = v___x_7114_;
goto v___jp_7089_;
}
}
else
{
uint64_t v___x_7115_;
v___x_7115_ = 799ULL;
v___y_7090_ = v___x_7115_;
goto v___jp_7089_;
}
}
else
{
uint64_t v___x_7116_;
v___x_7116_ = 775ULL;
v___y_7090_ = v___x_7116_;
goto v___jp_7089_;
}
}
else
{
uint64_t v___x_7117_;
v___x_7117_ = 263ULL;
v___y_7090_ = v___x_7117_;
goto v___jp_7089_;
}
}
}
}
v___jp_7089_:
{
uint8_t v___x_7091_;
v___x_7091_ = lean_uint64_dec_eq(v_requiredMask_7085_, v___y_7090_);
if (v___x_7091_ == 0)
{
return v___x_7088_;
}
else
{
uint64_t v___x_7092_; uint8_t v___x_7093_;
v___x_7092_ = lean_uint64_land(v_detectedHwCaps_7084_, v_requiredMask_7085_);
v___x_7093_ = lean_uint64_dec_eq(v___x_7092_, v_requiredMask_7085_);
if (v___x_7093_ == 0)
{
return v___x_7088_;
}
else
{
return v_requestedVariantId_7086_;
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_verify_isa_selection(uint64_t v_detectedHwCaps_7128_, uint64_t v_requiredMask_7129_, uint8_t v_selectedVariantId_7130_, uint8_t v_maxVariantId_7131_){
_start:
{
uint64_t v___y_7133_; uint8_t v___x_7142_;
v___x_7142_ = lean_uint8_dec_le(v_selectedVariantId_7130_, v_maxVariantId_7131_);
if (v___x_7142_ == 0)
{
uint8_t v___x_7143_;
v___x_7143_ = 0;
return v___x_7143_;
}
else
{
uint8_t v___x_7144_; uint8_t v___x_7145_;
v___x_7144_ = 6;
v___x_7145_ = lean_uint8_dec_le(v_maxVariantId_7131_, v___x_7144_);
if (v___x_7145_ == 0)
{
uint8_t v___x_7146_;
v___x_7146_ = 0;
return v___x_7146_;
}
else
{
uint8_t v___x_7147_; uint8_t v___x_7148_;
v___x_7147_ = 0;
v___x_7148_ = lean_uint8_dec_eq(v_selectedVariantId_7130_, v___x_7147_);
if (v___x_7148_ == 0)
{
uint8_t v___x_7149_; uint8_t v___x_7150_;
v___x_7149_ = 1;
v___x_7150_ = lean_uint8_dec_eq(v_selectedVariantId_7130_, v___x_7149_);
if (v___x_7150_ == 0)
{
uint8_t v___x_7151_; uint8_t v___x_7152_;
v___x_7151_ = 2;
v___x_7152_ = lean_uint8_dec_eq(v_selectedVariantId_7130_, v___x_7151_);
if (v___x_7152_ == 0)
{
uint8_t v___x_7153_; uint8_t v___x_7154_;
v___x_7153_ = 3;
v___x_7154_ = lean_uint8_dec_eq(v_selectedVariantId_7130_, v___x_7153_);
if (v___x_7154_ == 0)
{
uint8_t v___x_7155_; uint8_t v___x_7156_;
v___x_7155_ = 4;
v___x_7156_ = lean_uint8_dec_eq(v_selectedVariantId_7130_, v___x_7155_);
if (v___x_7156_ == 0)
{
uint8_t v___x_7157_; uint8_t v___x_7158_;
v___x_7157_ = 5;
v___x_7158_ = lean_uint8_dec_eq(v_selectedVariantId_7130_, v___x_7157_);
if (v___x_7158_ == 0)
{
uint8_t v___x_7159_;
v___x_7159_ = lean_uint8_dec_eq(v_selectedVariantId_7130_, v___x_7144_);
if (v___x_7159_ == 0)
{
uint64_t v___x_7160_;
v___x_7160_ = 18446744073709551615ULL;
v___y_7133_ = v___x_7160_;
goto v___jp_7132_;
}
else
{
uint64_t v___x_7161_;
v___x_7161_ = 64512ULL;
v___y_7133_ = v___x_7161_;
goto v___jp_7132_;
}
}
else
{
uint64_t v___x_7162_;
v___x_7162_ = 31744ULL;
v___y_7133_ = v___x_7162_;
goto v___jp_7132_;
}
}
else
{
uint64_t v___x_7163_;
v___x_7163_ = 927ULL;
v___y_7133_ = v___x_7163_;
goto v___jp_7132_;
}
}
else
{
uint64_t v___x_7164_;
v___x_7164_ = 895ULL;
v___y_7133_ = v___x_7164_;
goto v___jp_7132_;
}
}
else
{
uint64_t v___x_7165_;
v___x_7165_ = 799ULL;
v___y_7133_ = v___x_7165_;
goto v___jp_7132_;
}
}
else
{
uint64_t v___x_7166_;
v___x_7166_ = 775ULL;
v___y_7133_ = v___x_7166_;
goto v___jp_7132_;
}
}
else
{
uint64_t v___x_7167_;
v___x_7167_ = 263ULL;
v___y_7133_ = v___x_7167_;
goto v___jp_7132_;
}
}
}
v___jp_7132_:
{
uint8_t v___x_7134_;
v___x_7134_ = lean_uint64_dec_eq(v_requiredMask_7129_, v___y_7133_);
if (v___x_7134_ == 0)
{
uint8_t v___x_7135_;
v___x_7135_ = 0;
return v___x_7135_;
}
else
{
uint8_t v___x_7136_; uint8_t v___x_7137_;
v___x_7136_ = 0;
v___x_7137_ = lean_uint8_dec_eq(v_selectedVariantId_7130_, v___x_7136_);
if (v___x_7137_ == 0)
{
uint64_t v___x_7138_; uint8_t v___x_7139_;
v___x_7138_ = lean_uint64_land(v_detectedHwCaps_7128_, v_requiredMask_7129_);
v___x_7139_ = lean_uint64_dec_eq(v___x_7138_, v_requiredMask_7129_);
if (v___x_7139_ == 0)
{
return v___x_7136_;
}
else
{
uint8_t v___x_7140_;
v___x_7140_ = 1;
return v___x_7140_;
}
}
else
{
uint8_t v___x_7141_;
v___x_7141_ = 1;
return v___x_7141_;
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_verify_fd_bounds(uint64_t v_rawWord_7450_, uint32_t v_fdOut_7451_){
_start:
{
uint64_t v___x_7452_; uint8_t v___x_7453_;
v___x_7452_ = 2147483647ULL;
v___x_7453_ = lean_uint64_dec_le(v_rawWord_7450_, v___x_7452_);
if (v___x_7453_ == 0)
{
uint8_t v___x_7454_;
v___x_7454_ = 0;
return v___x_7454_;
}
else
{
uint64_t v___x_7455_; uint8_t v___x_7456_;
v___x_7455_ = lean_uint32_to_uint64(v_fdOut_7451_);
v___x_7456_ = lean_uint64_dec_eq(v_rawWord_7450_, v___x_7455_);
if (v___x_7456_ == 0)
{
uint8_t v___x_7457_;
v___x_7457_ = 0;
return v___x_7457_;
}
else
{
uint8_t v___x_7458_;
v___x_7458_ = 1;
return v___x_7458_;
}
}
}
}

LEAN_EXPORT uint8_t leansys_verify_unix_path_bounds(uint64_t v_pathLen_7585_, uint8_t v_noInteriorNull_7586_){
_start:
{
uint64_t v___x_7587_; uint8_t v___x_7588_;
v___x_7587_ = 0ULL;
v___x_7588_ = lean_uint64_dec_lt(v___x_7587_, v_pathLen_7585_);
if (v___x_7588_ == 0)
{
uint8_t v___x_7589_;
v___x_7589_ = 0;
return v___x_7589_;
}
else
{
uint64_t v___x_7590_; uint8_t v___x_7591_;
v___x_7590_ = 103ULL;
v___x_7591_ = lean_uint64_dec_le(v_pathLen_7585_, v___x_7590_);
if (v___x_7591_ == 0)
{
uint8_t v___x_7592_;
v___x_7592_ = 0;
return v___x_7592_;
}
else
{
uint8_t v___x_7593_; uint8_t v___x_7594_;
v___x_7593_ = 1;
v___x_7594_ = lean_uint8_dec_eq(v_noInteriorNull_7586_, v___x_7593_);
if (v___x_7594_ == 0)
{
uint8_t v___x_7595_;
v___x_7595_ = 0;
return v___x_7595_;
}
else
{
return v___x_7593_;
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_verify_cas_digest256(uint64_t v_e0_7726_, uint64_t v_e1_7727_, uint64_t v_e2_7728_, uint64_t v_e3_7729_, uint64_t v_c0_7730_, uint64_t v_c1_7731_, uint64_t v_c2_7732_, uint64_t v_c3_7733_, uint8_t v_hasPathSep_7734_){
_start:
{
uint64_t v___x_7735_; uint64_t v___x_7736_; uint64_t v___x_7737_; uint64_t v___x_7738_; uint8_t v___x_7739_;
v___x_7735_ = lean_uint64_lor(v_e0_7726_, v_e1_7727_);
v___x_7736_ = lean_uint64_lor(v___x_7735_, v_e2_7728_);
v___x_7737_ = lean_uint64_lor(v___x_7736_, v_e3_7729_);
v___x_7738_ = 0ULL;
v___x_7739_ = lean_uint64_dec_eq(v___x_7737_, v___x_7738_);
if (v___x_7739_ == 0)
{
uint64_t v___x_7740_; uint64_t v___x_7741_; uint64_t v___x_7742_; uint64_t v___x_7743_; uint64_t v___x_7744_; uint64_t v___x_7745_; uint64_t v___x_7746_; uint8_t v___x_7747_;
v___x_7740_ = lean_uint64_xor(v_e0_7726_, v_c0_7730_);
v___x_7741_ = lean_uint64_xor(v_e1_7727_, v_c1_7731_);
v___x_7742_ = lean_uint64_lor(v___x_7740_, v___x_7741_);
v___x_7743_ = lean_uint64_xor(v_e2_7728_, v_c2_7732_);
v___x_7744_ = lean_uint64_lor(v___x_7742_, v___x_7743_);
v___x_7745_ = lean_uint64_xor(v_e3_7729_, v_c3_7733_);
v___x_7746_ = lean_uint64_lor(v___x_7744_, v___x_7745_);
v___x_7747_ = lean_uint64_dec_eq(v___x_7746_, v___x_7738_);
if (v___x_7747_ == 0)
{
uint8_t v___x_7748_;
v___x_7748_ = 0;
return v___x_7748_;
}
else
{
uint8_t v___x_7749_; uint8_t v___x_7750_;
v___x_7749_ = 0;
v___x_7750_ = lean_uint8_dec_eq(v_hasPathSep_7734_, v___x_7749_);
if (v___x_7750_ == 0)
{
return v___x_7749_;
}
else
{
uint8_t v___x_7751_;
v___x_7751_ = 1;
return v___x_7751_;
}
}
}
else
{
uint8_t v___x_7752_;
v___x_7752_ = 0;
return v___x_7752_;
}
}
}

LEAN_EXPORT uint8_t leansys_verify_sigv4_envelope(uint64_t v_signedAtEpoch_8027_, uint64_t v_nowEpoch_8028_, uint64_t v_expiresSecs_8029_, uint32_t v_signedHeaderCount_8030_, uint8_t v_noHeaderCtl_8031_, uint8_t v_hostSigned_8032_){
_start:
{
uint8_t v___x_8033_; uint8_t v___x_8034_;
v___x_8033_ = 1;
v___x_8034_ = lean_uint8_dec_eq(v_noHeaderCtl_8031_, v___x_8033_);
if (v___x_8034_ == 0)
{
uint8_t v___x_8035_;
v___x_8035_ = 0;
return v___x_8035_;
}
else
{
uint8_t v___x_8036_;
v___x_8036_ = lean_uint8_dec_eq(v_hostSigned_8032_, v___x_8033_);
if (v___x_8036_ == 0)
{
uint8_t v___x_8037_;
v___x_8037_ = 0;
return v___x_8037_;
}
else
{
uint32_t v___x_8038_; uint8_t v___x_8039_;
v___x_8038_ = 0;
v___x_8039_ = lean_uint32_dec_lt(v___x_8038_, v_signedHeaderCount_8030_);
if (v___x_8039_ == 0)
{
uint8_t v___x_8040_;
v___x_8040_ = 0;
return v___x_8040_;
}
else
{
uint32_t v___x_8041_; uint8_t v___x_8042_;
v___x_8041_ = 32;
v___x_8042_ = lean_uint32_dec_le(v_signedHeaderCount_8030_, v___x_8041_);
if (v___x_8042_ == 0)
{
uint8_t v___x_8043_;
v___x_8043_ = 0;
return v___x_8043_;
}
else
{
uint64_t v___x_8044_; uint8_t v___x_8045_;
v___x_8044_ = 0ULL;
v___x_8045_ = lean_uint64_dec_lt(v___x_8044_, v_expiresSecs_8029_);
if (v___x_8045_ == 0)
{
uint8_t v___x_8046_;
v___x_8046_ = 0;
return v___x_8046_;
}
else
{
uint64_t v___x_8047_; uint8_t v___x_8048_;
v___x_8047_ = 604800ULL;
v___x_8048_ = lean_uint64_dec_le(v_expiresSecs_8029_, v___x_8047_);
if (v___x_8048_ == 0)
{
uint8_t v___x_8049_;
v___x_8049_ = 0;
return v___x_8049_;
}
else
{
uint64_t v___x_8050_; uint64_t v___x_8051_; uint8_t v___x_8052_;
v___x_8050_ = 18446744073709551615ULL;
v___x_8051_ = lean_uint64_sub(v___x_8050_, v_expiresSecs_8029_);
v___x_8052_ = lean_uint64_dec_le(v_signedAtEpoch_8027_, v___x_8051_);
if (v___x_8052_ == 0)
{
uint8_t v___x_8053_;
v___x_8053_ = 0;
return v___x_8053_;
}
else
{
uint64_t v___x_8054_; uint8_t v___x_8055_;
v___x_8054_ = lean_uint64_add(v_signedAtEpoch_8027_, v_expiresSecs_8029_);
v___x_8055_ = lean_uint64_dec_lt(v_nowEpoch_8028_, v___x_8054_);
if (v___x_8055_ == 0)
{
uint8_t v___x_8056_;
v___x_8056_ = 0;
return v___x_8056_;
}
else
{
return v___x_8033_;
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

LEAN_EXPORT uint8_t leansys_verify_cgroup_v2_budget(uint64_t v_memCurrentBytes_8302_, uint64_t v_memMaxBytes_8303_, uint64_t v_oomKillCount_8304_, uint8_t v_cgroupAttached_8305_){
_start:
{
uint8_t v___x_8306_; uint8_t v___x_8307_;
v___x_8306_ = 1;
v___x_8307_ = lean_uint8_dec_eq(v_cgroupAttached_8305_, v___x_8306_);
if (v___x_8307_ == 0)
{
uint8_t v___x_8308_;
v___x_8308_ = 0;
return v___x_8308_;
}
else
{
uint64_t v___x_8309_; uint8_t v___x_8310_;
v___x_8309_ = 0ULL;
v___x_8310_ = lean_uint64_dec_eq(v_oomKillCount_8304_, v___x_8309_);
if (v___x_8310_ == 0)
{
uint8_t v___x_8311_;
v___x_8311_ = 0;
return v___x_8311_;
}
else
{
uint8_t v___x_8312_;
v___x_8312_ = lean_uint64_dec_le(v_memCurrentBytes_8302_, v_memMaxBytes_8303_);
if (v___x_8312_ == 0)
{
uint8_t v___x_8313_;
v___x_8313_ = 0;
return v___x_8313_;
}
else
{
return v___x_8306_;
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_verify_io_uring_ring(uint32_t v_sqHead_8471_, uint32_t v_sqTail_8472_, uint32_t v_ringEntries_8473_, uint32_t v_ringMask_8474_, uint32_t v_toSubmit_8475_){
_start:
{
uint32_t v___x_8476_; uint8_t v___x_8477_;
v___x_8476_ = 0;
v___x_8477_ = lean_uint32_dec_lt(v___x_8476_, v_ringEntries_8473_);
if (v___x_8477_ == 0)
{
uint8_t v___x_8478_;
v___x_8478_ = 0;
return v___x_8478_;
}
else
{
uint32_t v___x_8479_; uint8_t v___x_8480_;
v___x_8479_ = 4096;
v___x_8480_ = lean_uint32_dec_le(v_ringEntries_8473_, v___x_8479_);
if (v___x_8480_ == 0)
{
uint8_t v___x_8481_;
v___x_8481_ = 0;
return v___x_8481_;
}
else
{
uint32_t v___x_8482_; uint32_t v___x_8483_; uint32_t v___x_8484_; uint8_t v___x_8485_;
v___x_8482_ = 1;
v___x_8483_ = lean_uint32_sub(v_ringEntries_8473_, v___x_8482_);
v___x_8484_ = lean_uint32_land(v_ringEntries_8473_, v___x_8483_);
v___x_8485_ = lean_uint32_dec_eq(v___x_8484_, v___x_8476_);
if (v___x_8485_ == 0)
{
uint8_t v___x_8486_;
v___x_8486_ = 0;
return v___x_8486_;
}
else
{
uint8_t v___x_8487_;
v___x_8487_ = lean_uint32_dec_eq(v_ringMask_8474_, v___x_8483_);
if (v___x_8487_ == 0)
{
uint8_t v___x_8488_;
v___x_8488_ = 0;
return v___x_8488_;
}
else
{
uint32_t v___x_8489_; uint8_t v___x_8490_;
v___x_8489_ = lean_uint32_sub(v_sqTail_8472_, v_sqHead_8471_);
v___x_8490_ = lean_uint32_dec_le(v___x_8489_, v_ringEntries_8473_);
if (v___x_8490_ == 0)
{
uint8_t v___x_8491_;
v___x_8491_ = 0;
return v___x_8491_;
}
else
{
uint32_t v___x_8492_; uint8_t v___x_8493_;
v___x_8492_ = lean_uint32_sub(v_ringEntries_8473_, v___x_8489_);
v___x_8493_ = lean_uint32_dec_le(v_toSubmit_8475_, v___x_8492_);
if (v___x_8493_ == 0)
{
uint8_t v___x_8494_;
v___x_8494_ = 0;
return v___x_8494_;
}
else
{
uint8_t v___x_8495_;
v___x_8495_ = 1;
return v___x_8495_;
}
}
}
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_verify_borrowed_view(uint64_t v_ptrAddr_8724_, uint64_t v_viewLen_8725_, uint64_t v_relOff_8726_, uint64_t v_subLen_8727_){
_start:
{
uint64_t v___x_8728_; uint8_t v___x_8729_;
v___x_8728_ = 0ULL;
v___x_8729_ = lean_uint64_dec_eq(v_ptrAddr_8724_, v___x_8728_);
if (v___x_8729_ == 0)
{
uint64_t v___x_8730_; uint64_t v___x_8731_; uint8_t v___x_8732_;
v___x_8730_ = 18446744073709551615ULL;
v___x_8731_ = lean_uint64_sub(v___x_8730_, v_viewLen_8725_);
v___x_8732_ = lean_uint64_dec_le(v_ptrAddr_8724_, v___x_8731_);
if (v___x_8732_ == 0)
{
uint8_t v___x_8733_;
v___x_8733_ = 0;
return v___x_8733_;
}
else
{
uint8_t v___x_8734_;
v___x_8734_ = lean_uint64_dec_le(v_relOff_8726_, v_viewLen_8725_);
if (v___x_8734_ == 0)
{
uint8_t v___x_8735_;
v___x_8735_ = 0;
return v___x_8735_;
}
else
{
uint64_t v___x_8736_; uint8_t v___x_8737_;
v___x_8736_ = lean_uint64_sub(v_viewLen_8725_, v_relOff_8726_);
v___x_8737_ = lean_uint64_dec_le(v_subLen_8727_, v___x_8736_);
if (v___x_8737_ == 0)
{
uint8_t v___x_8738_;
v___x_8738_ = 0;
return v___x_8738_;
}
else
{
uint8_t v___x_8739_;
v___x_8739_ = 1;
return v___x_8739_;
}
}
}
}
else
{
uint8_t v___x_8740_;
v___x_8740_ = 0;
return v___x_8740_;
}
}
}

LEAN_EXPORT uint8_t leansys_verify_step_reactor(uint64_t v_cmdEpoch_8933_, uint64_t v_minEpoch_8934_, uint64_t v_usedAfter_8935_, uint64_t v_quotaCap_8936_, uint32_t v_activeConns_8937_, uint32_t v_maxConns_8938_, uint8_t v_alreadySeen_8939_){
_start:
{
uint8_t v___x_8940_; uint8_t v___x_8941_;
v___x_8940_ = 0;
v___x_8941_ = lean_uint8_dec_eq(v_alreadySeen_8939_, v___x_8940_);
if (v___x_8941_ == 0)
{
return v___x_8940_;
}
else
{
uint8_t v___x_8942_;
v___x_8942_ = lean_uint64_dec_le(v_minEpoch_8934_, v_cmdEpoch_8933_);
if (v___x_8942_ == 0)
{
return v___x_8940_;
}
else
{
uint8_t v___x_8943_;
v___x_8943_ = lean_uint64_dec_le(v_usedAfter_8935_, v_quotaCap_8936_);
if (v___x_8943_ == 0)
{
return v___x_8940_;
}
else
{
uint8_t v___x_8944_;
v___x_8944_ = lean_uint32_dec_le(v_activeConns_8937_, v_maxConns_8938_);
if (v___x_8944_ == 0)
{
return v___x_8940_;
}
else
{
uint32_t v___x_8945_; uint8_t v___x_8946_;
v___x_8945_ = 1024;
v___x_8946_ = lean_uint32_dec_le(v_maxConns_8938_, v___x_8945_);
if (v___x_8946_ == 0)
{
return v___x_8940_;
}
else
{
uint8_t v___x_8947_;
v___x_8947_ = 1;
return v___x_8947_;
}
}
}
}
}
}
}

LEAN_EXPORT uint8_t leansys_verify_stream_relay(uint8_t v_clientGone_9165_, uint8_t v_upstreamDead_9166_, uint8_t v_firstChunkSeen_9167_, uint8_t v_atFrameBoundary_9168_, uint64_t v_prefillElapsedMs_9169_, uint64_t v_prefillMaxMs_9170_, uint64_t v_idleMs_9171_, uint64_t v_idleMaxMs_9172_, uint64_t v_keepaliveDueMs_9173_, uint64_t v_pendingTxBytes_9174_, uint64_t v_maxBufferBytes_9175_){
_start:
{
uint8_t v___x_9187_; uint8_t v___x_9191_;
v___x_9187_ = 0;
v___x_9191_ = lean_uint8_dec_eq(v_clientGone_9165_, v___x_9187_);
if (v___x_9191_ == 0)
{
return v___x_9187_;
}
else
{
uint8_t v___x_9192_;
v___x_9192_ = lean_uint8_dec_eq(v_upstreamDead_9166_, v___x_9187_);
if (v___x_9192_ == 0)
{
return v___x_9187_;
}
else
{
uint64_t v___x_9193_; uint8_t v___x_9194_;
v___x_9193_ = 0ULL;
v___x_9194_ = lean_uint64_dec_lt(v___x_9193_, v_maxBufferBytes_9175_);
if (v___x_9194_ == 0)
{
return v___x_9187_;
}
else
{
uint8_t v___x_9195_;
v___x_9195_ = lean_uint64_dec_le(v_pendingTxBytes_9174_, v_maxBufferBytes_9175_);
if (v___x_9195_ == 0)
{
return v___x_9187_;
}
else
{
uint8_t v___x_9196_;
v___x_9196_ = lean_uint8_dec_eq(v_firstChunkSeen_9167_, v___x_9187_);
if (v___x_9196_ == 0)
{
goto v___jp_9188_;
}
else
{
uint8_t v___x_9197_;
v___x_9197_ = lean_uint64_dec_le(v_prefillElapsedMs_9169_, v_prefillMaxMs_9170_);
if (v___x_9197_ == 0)
{
return v___x_9187_;
}
else
{
goto v___jp_9188_;
}
}
}
}
}
}
v___jp_9176_:
{
uint8_t v___x_9177_; uint8_t v___x_9178_;
v___x_9177_ = 1;
v___x_9178_ = lean_uint8_dec_eq(v_atFrameBoundary_9168_, v___x_9177_);
if (v___x_9178_ == 0)
{
uint8_t v___x_9179_;
v___x_9179_ = 2;
return v___x_9179_;
}
else
{
uint64_t v___x_9180_; uint8_t v___x_9181_;
v___x_9180_ = 0ULL;
v___x_9181_ = lean_uint64_dec_lt(v___x_9180_, v_keepaliveDueMs_9173_);
if (v___x_9181_ == 0)
{
uint8_t v___x_9182_;
v___x_9182_ = 2;
return v___x_9182_;
}
else
{
uint8_t v___x_9183_;
v___x_9183_ = lean_uint64_dec_le(v_keepaliveDueMs_9173_, v_idleMs_9171_);
if (v___x_9183_ == 0)
{
uint8_t v___x_9184_;
v___x_9184_ = 2;
return v___x_9184_;
}
else
{
uint8_t v___x_9185_;
v___x_9185_ = lean_uint64_dec_eq(v_pendingTxBytes_9174_, v___x_9180_);
if (v___x_9185_ == 0)
{
uint8_t v___x_9186_;
v___x_9186_ = 2;
return v___x_9186_;
}
else
{
return v___x_9177_;
}
}
}
}
}
v___jp_9188_:
{
uint8_t v___x_9189_;
v___x_9189_ = lean_uint8_dec_eq(v_firstChunkSeen_9167_, v___x_9187_);
if (v___x_9189_ == 0)
{
uint8_t v___x_9190_;
v___x_9190_ = lean_uint64_dec_le(v_idleMs_9171_, v_idleMaxMs_9172_);
if (v___x_9190_ == 0)
{
return v___x_9187_;
}
else
{
goto v___jp_9176_;
}
}
else
{
goto v___jp_9176_;
}
}
}
}
