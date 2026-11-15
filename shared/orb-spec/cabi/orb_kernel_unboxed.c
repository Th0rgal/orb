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
uint32_t v___x_393_;
v___x_393_ = 65536;
return v___x_393_;
}
else
{
uint32_t v___x_394_;
v___x_394_ = 65792;
return v___x_394_;
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
uint8_t v___x_395_;
v___x_395_ = lean_uint32_dec_le(v_transientThreshold_373_, v_transientStreak_372_);
if (v___x_395_ == 0)
{
uint32_t v___x_396_;
v___x_396_ = 0;
return v___x_396_;
}
else
{
uint32_t v___x_397_; uint8_t v___x_398_;
v___x_397_ = 1;
v___x_398_ = lean_uint32_dec_le(v___x_397_, v_transientThreshold_373_);
if (v___x_398_ == 0)
{
uint32_t v___x_399_;
v___x_399_ = 0;
return v___x_399_;
}
else
{
uint32_t v___x_400_;
v___x_400_ = 65536;
return v___x_400_;
}
}
}
}
else
{
uint32_t v___x_401_;
v___x_401_ = 0;
return v___x_401_;
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

LEAN_EXPORT uint8_t orb_mission_step(uint8_t v_armed_410_, uint8_t v_signal_411_, uint8_t v_continuationPending_412_, uint8_t v_wakeupArmed_413_, uint8_t v_madeProgress_414_, uint32_t v_priorNoProgress_415_, uint32_t v_maxNoProgress_416_, uint32_t v_priorContinuations_417_, uint32_t v_maxContinuations_418_, uint32_t v_hasMaxCont_419_){
_start:
{
uint8_t v___x_420_; uint8_t v___x_421_;
v___x_420_ = 0;
v___x_421_ = lean_uint8_dec_eq(v_armed_410_, v___x_420_);
if (v___x_421_ == 0)
{
uint8_t v___x_422_; uint8_t v___x_423_;
v___x_422_ = 1;
v___x_423_ = lean_uint8_dec_eq(v_signal_411_, v___x_422_);
if (v___x_423_ == 0)
{
uint8_t v___x_424_; uint8_t v___x_425_;
v___x_424_ = 2;
v___x_425_ = lean_uint8_dec_eq(v_signal_411_, v___x_424_);
if (v___x_425_ == 0)
{
uint8_t v___x_426_;
v___x_426_ = lean_uint8_dec_eq(v_continuationPending_412_, v___x_422_);
if (v___x_426_ == 0)
{
uint8_t v___x_427_;
v___x_427_ = lean_uint8_dec_eq(v_wakeupArmed_413_, v___x_422_);
if (v___x_427_ == 0)
{
uint32_t v___x_428_; uint32_t v___y_430_; uint32_t v___y_431_; uint32_t v___y_441_; uint8_t v___x_445_;
v___x_428_ = 1;
v___x_445_ = lean_uint32_dec_le(v___x_428_, v_maxNoProgress_416_);
if (v___x_445_ == 0)
{
v___y_441_ = v___x_428_;
goto v___jp_440_;
}
else
{
v___y_441_ = v_maxNoProgress_416_;
goto v___jp_440_;
}
v___jp_429_:
{
uint8_t v___x_432_;
v___x_432_ = lean_uint32_dec_le(v___y_430_, v___y_431_);
if (v___x_432_ == 0)
{
uint8_t v___x_433_;
v___x_433_ = lean_uint32_dec_eq(v_hasMaxCont_419_, v___x_428_);
if (v___x_433_ == 0)
{
uint8_t v___x_434_;
v___x_434_ = 7;
return v___x_434_;
}
else
{
uint32_t v___x_435_; uint8_t v___x_436_;
v___x_435_ = lean_uint32_add(v_priorContinuations_417_, v___x_428_);
v___x_436_ = lean_uint32_dec_lt(v_maxContinuations_418_, v___x_435_);
if (v___x_436_ == 0)
{
uint8_t v___x_437_;
v___x_437_ = 7;
return v___x_437_;
}
else
{
uint8_t v___x_438_;
v___x_438_ = 6;
return v___x_438_;
}
}
}
else
{
uint8_t v___x_439_;
v___x_439_ = 5;
return v___x_439_;
}
}
v___jp_440_:
{
uint8_t v___x_442_;
v___x_442_ = lean_uint8_dec_eq(v_madeProgress_414_, v___x_422_);
if (v___x_442_ == 0)
{
uint32_t v___x_443_;
v___x_443_ = lean_uint32_add(v_priorNoProgress_415_, v___x_428_);
v___y_430_ = v___y_441_;
v___y_431_ = v___x_443_;
goto v___jp_429_;
}
else
{
uint32_t v___x_444_;
v___x_444_ = 0;
v___y_430_ = v___y_441_;
v___y_431_ = v___x_444_;
goto v___jp_429_;
}
}
}
else
{
uint8_t v___x_446_;
v___x_446_ = 4;
return v___x_446_;
}
}
else
{
uint8_t v___x_447_;
v___x_447_ = 3;
return v___x_447_;
}
}
else
{
return v___x_424_;
}
}
else
{
return v___x_422_;
}
}
else
{
return v___x_420_;
}
}
}

LEAN_EXPORT uint8_t orb_reconcile_step(uint8_t v_status_470_, uint8_t v_isClientPlaced_471_, uint8_t v_sameBootId_472_, uint8_t v_isAssistantMode_473_, uint8_t v_runningInActor_474_, uint8_t v_hasLiveScope_475_, uint8_t v_hasDurableRun_476_, uint8_t v_recentlyUpdated_477_, uint8_t v_hasEvents_478_, uint8_t v_alreadyOrphaned_479_, uint8_t v_isServiceRestart_480_, uint8_t v_withinHorizon_481_, uint8_t v_liveRetryExists_482_){
_start:
{
uint8_t v___x_483_; uint8_t v___x_484_;
v___x_483_ = 1;
v___x_484_ = lean_uint8_dec_eq(v_isClientPlaced_471_, v___x_483_);
if (v___x_484_ == 0)
{
uint8_t v___x_485_;
v___x_485_ = lean_uint8_dec_eq(v_sameBootId_472_, v___x_483_);
if (v___x_485_ == 0)
{
uint8_t v___x_486_;
v___x_486_ = lean_uint8_dec_eq(v_runningInActor_474_, v___x_483_);
if (v___x_486_ == 0)
{
uint8_t v___x_487_;
v___x_487_ = lean_uint8_dec_eq(v_hasLiveScope_475_, v___x_483_);
if (v___x_487_ == 0)
{
uint8_t v___x_488_;
v___x_488_ = lean_uint8_dec_eq(v_hasDurableRun_476_, v___x_483_);
if (v___x_488_ == 0)
{
uint8_t v___x_489_; uint8_t v___x_490_;
v___x_489_ = 0;
v___x_490_ = lean_uint8_dec_eq(v_status_470_, v___x_489_);
if (v___x_490_ == 0)
{
uint8_t v___x_491_;
v___x_491_ = lean_uint8_dec_eq(v_status_470_, v___x_483_);
if (v___x_491_ == 0)
{
uint8_t v___x_492_; uint8_t v___x_493_;
v___x_492_ = 2;
v___x_493_ = lean_uint8_dec_eq(v_status_470_, v___x_492_);
if (v___x_493_ == 0)
{
return v___x_489_;
}
else
{
uint8_t v___x_494_;
v___x_494_ = lean_uint8_dec_eq(v_isServiceRestart_480_, v___x_483_);
if (v___x_494_ == 0)
{
return v___x_489_;
}
else
{
uint8_t v___x_495_;
v___x_495_ = lean_uint8_dec_eq(v_withinHorizon_481_, v___x_483_);
if (v___x_495_ == 0)
{
return v___x_489_;
}
else
{
uint8_t v___x_496_;
v___x_496_ = lean_uint8_dec_eq(v_liveRetryExists_482_, v___x_489_);
if (v___x_496_ == 0)
{
return v___x_489_;
}
else
{
uint8_t v___x_497_;
v___x_497_ = 3;
return v___x_497_;
}
}
}
}
}
else
{
uint8_t v___x_498_;
v___x_498_ = lean_uint8_dec_eq(v_hasEvents_478_, v___x_489_);
if (v___x_498_ == 0)
{
return v___x_489_;
}
else
{
uint8_t v___x_499_;
v___x_499_ = lean_uint8_dec_eq(v_alreadyOrphaned_479_, v___x_489_);
if (v___x_499_ == 0)
{
return v___x_489_;
}
else
{
uint8_t v___x_500_;
v___x_500_ = 2;
return v___x_500_;
}
}
}
}
else
{
uint8_t v___x_501_;
v___x_501_ = lean_uint8_dec_eq(v_isAssistantMode_473_, v___x_489_);
if (v___x_501_ == 0)
{
return v___x_489_;
}
else
{
uint8_t v___x_502_;
v___x_502_ = lean_uint8_dec_eq(v_recentlyUpdated_477_, v___x_489_);
if (v___x_502_ == 0)
{
return v___x_489_;
}
else
{
return v___x_483_;
}
}
}
}
else
{
uint8_t v___x_503_;
v___x_503_ = 0;
return v___x_503_;
}
}
else
{
uint8_t v___x_504_;
v___x_504_ = 0;
return v___x_504_;
}
}
else
{
uint8_t v___x_505_;
v___x_505_ = 0;
return v___x_505_;
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
}

LEAN_EXPORT uint32_t orb_queue_step(uint8_t v_deliveryOutcome_536_, uint8_t v_durablyStarted_537_){
_start:
{
uint8_t v___x_543_; uint8_t v___x_544_;
v___x_543_ = 0;
v___x_544_ = lean_uint8_dec_eq(v_deliveryOutcome_536_, v___x_543_);
if (v___x_544_ == 0)
{
goto v___jp_538_;
}
else
{
uint8_t v___x_545_; uint8_t v___x_546_;
v___x_545_ = 1;
v___x_546_ = lean_uint8_dec_eq(v_durablyStarted_537_, v___x_545_);
if (v___x_546_ == 0)
{
goto v___jp_538_;
}
else
{
uint32_t v___x_547_;
v___x_547_ = 256;
return v___x_547_;
}
}
v___jp_538_:
{
uint8_t v___x_539_; uint8_t v___x_540_;
v___x_539_ = 2;
v___x_540_ = lean_uint8_dec_eq(v_deliveryOutcome_536_, v___x_539_);
if (v___x_540_ == 0)
{
uint32_t v___x_541_;
v___x_541_ = 1;
return v___x_541_;
}
else
{
uint32_t v___x_542_;
v___x_542_ = 65537;
return v___x_542_;
}
}
}
}

LEAN_EXPORT uint8_t orb_vm_step(uint8_t v_op_554_, uint8_t v_sizeRank_555_, uint8_t v_maxSizeRank_556_, uint8_t v_secretProjected_557_, uint8_t v_ttlExpired_558_, uint8_t v_busy_559_, uint8_t v_ownerEnded_560_, uint8_t v_idleExpired_561_, uint32_t v_activeCount_562_, uint32_t v_maxConcurrent_563_, uint32_t v_ttlMinutes_564_, uint32_t v_maxTtlMinutes_565_, uint32_t v_jobMemPct_566_, uint64_t v_spentPlusNewCents_567_, uint64_t v_dailyCapCents_568_){
_start:
{
uint8_t v___x_569_; uint8_t v___x_570_;
v___x_569_ = 0;
v___x_570_ = lean_uint8_dec_eq(v_op_554_, v___x_569_);
if (v___x_570_ == 0)
{
uint8_t v___x_571_; uint8_t v___x_572_;
v___x_571_ = 1;
v___x_572_ = lean_uint8_dec_eq(v_ttlExpired_558_, v___x_571_);
if (v___x_572_ == 0)
{
uint8_t v___x_573_;
v___x_573_ = lean_uint8_dec_eq(v_busy_559_, v___x_569_);
if (v___x_573_ == 0)
{
return v___x_569_;
}
else
{
uint8_t v___x_574_;
v___x_574_ = lean_uint8_dec_eq(v_ownerEnded_560_, v___x_571_);
if (v___x_574_ == 0)
{
uint8_t v___x_575_;
v___x_575_ = lean_uint8_dec_eq(v_idleExpired_561_, v___x_571_);
if (v___x_575_ == 0)
{
return v___x_569_;
}
else
{
return v___x_571_;
}
}
else
{
return v___x_571_;
}
}
}
else
{
return v___x_571_;
}
}
else
{
uint8_t v___x_576_;
v___x_576_ = lean_uint8_dec_le(v_sizeRank_555_, v_maxSizeRank_556_);
if (v___x_576_ == 0)
{
return v___x_569_;
}
else
{
uint8_t v___x_577_;
v___x_577_ = lean_uint32_dec_lt(v_activeCount_562_, v_maxConcurrent_563_);
if (v___x_577_ == 0)
{
return v___x_569_;
}
else
{
uint8_t v___x_578_;
v___x_578_ = lean_uint64_dec_le(v_spentPlusNewCents_567_, v_dailyCapCents_568_);
if (v___x_578_ == 0)
{
return v___x_569_;
}
else
{
uint32_t v___x_579_; uint8_t v___x_580_;
v___x_579_ = 5;
v___x_580_ = lean_uint32_dec_le(v___x_579_, v_ttlMinutes_564_);
if (v___x_580_ == 0)
{
return v___x_569_;
}
else
{
uint8_t v___x_581_;
v___x_581_ = lean_uint32_dec_le(v_ttlMinutes_564_, v_maxTtlMinutes_565_);
if (v___x_581_ == 0)
{
return v___x_569_;
}
else
{
uint32_t v___x_582_; uint8_t v___x_583_;
v___x_582_ = 90;
v___x_583_ = lean_uint32_dec_le(v_jobMemPct_566_, v___x_582_);
if (v___x_583_ == 0)
{
return v___x_569_;
}
else
{
uint8_t v___x_584_;
v___x_584_ = lean_uint8_dec_eq(v_secretProjected_557_, v___x_569_);
if (v___x_584_ == 0)
{
return v___x_569_;
}
else
{
uint8_t v___x_585_;
v___x_585_ = 1;
return v___x_585_;
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

LEAN_EXPORT uint32_t lp_orb_x2dspec_Orb_Kernel_accessStep___redArg(uint8_t v_sameOwner_618_, uint8_t v_isSelfOrChild_619_, uint8_t v_isReadTool_620_, uint8_t v_grantApproved_621_, uint8_t v_grantUnexpired_622_){
_start:
{
uint32_t v___y_624_; uint8_t v___x_627_; uint8_t v___x_628_;
v___x_627_ = 1;
v___x_628_ = lean_uint8_dec_eq(v_sameOwner_618_, v___x_627_);
if (v___x_628_ == 0)
{
goto v___jp_629_;
}
else
{
uint8_t v___x_638_;
v___x_638_ = lean_uint8_dec_eq(v_isSelfOrChild_619_, v___x_627_);
if (v___x_638_ == 0)
{
goto v___jp_629_;
}
else
{
uint32_t v___x_639_;
v___x_639_ = 65793;
return v___x_639_;
}
}
v___jp_623_:
{
uint32_t v___x_625_; uint32_t v___x_626_;
v___x_625_ = 256;
v___x_626_ = lean_uint32_lor(v___y_624_, v___x_625_);
return v___x_626_;
}
v___jp_629_:
{
if (v___x_628_ == 0)
{
uint32_t v___x_630_;
v___x_630_ = 0;
return v___x_630_;
}
else
{
uint8_t v___x_631_;
v___x_631_ = lean_uint8_dec_eq(v_grantApproved_621_, v___x_627_);
if (v___x_631_ == 0)
{
uint32_t v___x_632_;
v___x_632_ = 0;
return v___x_632_;
}
else
{
uint8_t v___x_633_;
v___x_633_ = lean_uint8_dec_eq(v_grantUnexpired_622_, v___x_627_);
if (v___x_633_ == 0)
{
uint32_t v___x_634_;
v___x_634_ = 0;
return v___x_634_;
}
else
{
uint8_t v___x_635_;
v___x_635_ = lean_uint8_dec_eq(v_isReadTool_620_, v___x_627_);
if (v___x_635_ == 0)
{
uint32_t v___x_636_;
v___x_636_ = 0;
v___y_624_ = v___x_636_;
goto v___jp_623_;
}
else
{
uint32_t v___x_637_;
v___x_637_ = 1;
v___y_624_ = v___x_637_;
goto v___jp_623_;
}
}
}
}
}
}
}

LEAN_EXPORT uint32_t orb_access_step(uint8_t v_sameOwner_652_, uint8_t v_isSelfOrChild_653_, uint8_t v_isReadTool_654_, uint8_t v_grantApproved_655_, uint8_t v_grantUnexpired_656_, uint8_t v___targetExists_657_){
_start:
{
uint32_t v___y_659_; uint8_t v___x_662_; uint8_t v___x_663_;
v___x_662_ = 1;
v___x_663_ = lean_uint8_dec_eq(v_sameOwner_652_, v___x_662_);
if (v___x_663_ == 0)
{
goto v___jp_664_;
}
else
{
uint8_t v___x_673_;
v___x_673_ = lean_uint8_dec_eq(v_isSelfOrChild_653_, v___x_662_);
if (v___x_673_ == 0)
{
goto v___jp_664_;
}
else
{
uint32_t v___x_674_;
v___x_674_ = 65793;
return v___x_674_;
}
}
v___jp_658_:
{
uint32_t v___x_660_; uint32_t v___x_661_;
v___x_660_ = 256;
v___x_661_ = lean_uint32_lor(v___y_659_, v___x_660_);
return v___x_661_;
}
v___jp_664_:
{
if (v___x_663_ == 0)
{
uint32_t v___x_665_;
v___x_665_ = 0;
return v___x_665_;
}
else
{
uint8_t v___x_666_;
v___x_666_ = lean_uint8_dec_eq(v_grantApproved_655_, v___x_662_);
if (v___x_666_ == 0)
{
uint32_t v___x_667_;
v___x_667_ = 0;
return v___x_667_;
}
else
{
uint8_t v___x_668_;
v___x_668_ = lean_uint8_dec_eq(v_grantUnexpired_656_, v___x_662_);
if (v___x_668_ == 0)
{
uint32_t v___x_669_;
v___x_669_ = 0;
return v___x_669_;
}
else
{
uint8_t v___x_670_;
v___x_670_ = lean_uint8_dec_eq(v_isReadTool_654_, v___x_662_);
if (v___x_670_ == 0)
{
uint32_t v___x_671_;
v___x_671_ = 0;
v___y_659_ = v___x_671_;
goto v___jp_658_;
}
else
{
uint32_t v___x_672_;
v___x_672_ = 1;
v___y_659_ = v___x_672_;
goto v___jp_658_;
}
}
}
}
}
}
}

LEAN_EXPORT uint32_t orb_workfold_step(uint8_t v_itemKind_689_, uint8_t v_isCumulative_690_, uint8_t v_isNonEmpty_691_, uint8_t v_toolAhead_692_, uint8_t v_nextIsTool_693_, uint8_t v_foldHasTool_694_){
_start:
{
uint8_t v___x_695_; uint8_t v___x_696_;
v___x_695_ = 3;
v___x_696_ = lean_uint8_dec_eq(v_itemKind_689_, v___x_695_);
if (v___x_696_ == 0)
{
uint8_t v___x_697_; uint8_t v___x_702_;
v___x_697_ = 1;
v___x_702_ = lean_uint8_dec_eq(v_itemKind_689_, v___x_697_);
if (v___x_702_ == 0)
{
uint8_t v___x_703_; uint8_t v___x_704_;
v___x_703_ = 2;
v___x_704_ = lean_uint8_dec_eq(v_itemKind_689_, v___x_703_);
if (v___x_704_ == 0)
{
uint32_t v___x_705_;
v___x_705_ = 0;
return v___x_705_;
}
else
{
uint8_t v___x_706_; uint8_t v___x_707_;
v___x_706_ = 0;
v___x_707_ = lean_uint8_dec_eq(v_isCumulative_690_, v___x_706_);
if (v___x_707_ == 0)
{
uint32_t v___x_708_;
v___x_708_ = 0;
return v___x_708_;
}
else
{
uint8_t v___x_709_;
v___x_709_ = lean_uint8_dec_eq(v_isNonEmpty_691_, v___x_697_);
if (v___x_709_ == 0)
{
uint32_t v___x_710_;
v___x_710_ = 0;
return v___x_710_;
}
else
{
uint8_t v___x_711_;
v___x_711_ = lean_uint8_dec_eq(v_toolAhead_692_, v___x_697_);
if (v___x_711_ == 0)
{
uint32_t v___x_712_;
v___x_712_ = 0;
return v___x_712_;
}
else
{
uint8_t v___x_713_;
v___x_713_ = lean_uint8_dec_eq(v_foldHasTool_694_, v___x_697_);
if (v___x_713_ == 0)
{
uint8_t v___x_714_;
v___x_714_ = lean_uint8_dec_eq(v_nextIsTool_693_, v___x_697_);
if (v___x_714_ == 0)
{
uint32_t v___x_715_;
v___x_715_ = 0;
return v___x_715_;
}
else
{
goto v___jp_698_;
}
}
else
{
goto v___jp_698_;
}
}
}
}
}
}
else
{
uint8_t v___x_716_;
v___x_716_ = lean_uint8_dec_eq(v_foldHasTool_694_, v___x_697_);
if (v___x_716_ == 0)
{
uint32_t v___x_717_;
v___x_717_ = 1;
return v___x_717_;
}
else
{
uint32_t v___x_718_;
v___x_718_ = 257;
return v___x_718_;
}
}
v___jp_698_:
{
uint8_t v___x_699_;
v___x_699_ = lean_uint8_dec_eq(v_foldHasTool_694_, v___x_697_);
if (v___x_699_ == 0)
{
uint32_t v___x_700_;
v___x_700_ = 1;
return v___x_700_;
}
else
{
uint32_t v___x_701_;
v___x_701_ = 257;
return v___x_701_;
}
}
}
else
{
uint32_t v___x_719_;
v___x_719_ = 257;
return v___x_719_;
}
}
}

LEAN_EXPORT uint8_t orb_taskcard_step(uint8_t v_turnEnded_734_, uint8_t v_allClosed_735_, uint8_t v_turnOutcomeFinished_736_){
_start:
{
uint8_t v___x_737_; uint8_t v___x_738_;
v___x_737_ = 0;
v___x_738_ = lean_uint8_dec_eq(v_turnEnded_734_, v___x_737_);
if (v___x_738_ == 0)
{
uint8_t v___x_739_; uint8_t v___x_740_;
v___x_739_ = 1;
v___x_740_ = lean_uint8_dec_eq(v_allClosed_735_, v___x_739_);
if (v___x_740_ == 0)
{
uint8_t v___x_741_;
v___x_741_ = lean_uint8_dec_eq(v_turnOutcomeFinished_736_, v___x_739_);
if (v___x_741_ == 0)
{
uint8_t v___x_742_;
v___x_742_ = 3;
return v___x_742_;
}
else
{
uint8_t v___x_743_;
v___x_743_ = 2;
return v___x_743_;
}
}
else
{
return v___x_739_;
}
}
else
{
return v___x_737_;
}
}
}

LEAN_EXPORT uint32_t orb_sidebar_visibility(uint8_t v_matchesFilter_752_, uint8_t v_hasVisibleDescendant_753_, uint8_t v_isAcknowledged_754_, uint8_t v_hasParent_755_, uint8_t v_isFork_756_, uint8_t v_parentReachesSelf_757_){
_start:
{
uint32_t v___y_759_; uint32_t v___y_760_; uint32_t v___y_761_; uint32_t v___y_765_; uint32_t v___y_766_; uint8_t v___x_768_; uint32_t v___y_770_; uint32_t v___y_771_; uint32_t v___y_778_; uint32_t v___y_781_; uint8_t v___x_788_;
v___x_768_ = 1;
v___x_788_ = lean_uint8_dec_eq(v_matchesFilter_752_, v___x_768_);
if (v___x_788_ == 0)
{
uint8_t v___x_789_;
v___x_789_ = lean_uint8_dec_eq(v_hasVisibleDescendant_753_, v___x_768_);
if (v___x_789_ == 0)
{
uint32_t v___x_790_;
v___x_790_ = 0;
v___y_781_ = v___x_790_;
goto v___jp_780_;
}
else
{
goto v___jp_786_;
}
}
else
{
goto v___jp_786_;
}
v___jp_758_:
{
uint32_t v___x_762_; uint32_t v___x_763_;
v___x_762_ = lean_uint32_lor(v___y_759_, v___y_760_);
v___x_763_ = lean_uint32_lor(v___x_762_, v___y_761_);
return v___x_763_;
}
v___jp_764_:
{
uint32_t v___x_767_;
v___x_767_ = 0;
v___y_759_ = v___y_765_;
v___y_760_ = v___y_766_;
v___y_761_ = v___x_767_;
goto v___jp_758_;
}
v___jp_769_:
{
uint8_t v___x_772_;
v___x_772_ = lean_uint8_dec_eq(v_hasParent_755_, v___x_768_);
if (v___x_772_ == 0)
{
v___y_765_ = v___y_770_;
v___y_766_ = v___y_771_;
goto v___jp_764_;
}
else
{
uint8_t v___x_773_; uint8_t v___x_774_;
v___x_773_ = 0;
v___x_774_ = lean_uint8_dec_eq(v_isFork_756_, v___x_773_);
if (v___x_774_ == 0)
{
v___y_765_ = v___y_770_;
v___y_766_ = v___y_771_;
goto v___jp_764_;
}
else
{
uint8_t v___x_775_;
v___x_775_ = lean_uint8_dec_eq(v_parentReachesSelf_757_, v___x_773_);
if (v___x_775_ == 0)
{
v___y_765_ = v___y_770_;
v___y_766_ = v___y_771_;
goto v___jp_764_;
}
else
{
uint32_t v___x_776_;
v___x_776_ = 65536;
v___y_759_ = v___y_770_;
v___y_760_ = v___y_771_;
v___y_761_ = v___x_776_;
goto v___jp_758_;
}
}
}
}
v___jp_777_:
{
uint32_t v___x_779_;
v___x_779_ = 0;
v___y_770_ = v___y_778_;
v___y_771_ = v___x_779_;
goto v___jp_769_;
}
v___jp_780_:
{
uint8_t v___x_782_;
v___x_782_ = lean_uint8_dec_eq(v_isAcknowledged_754_, v___x_768_);
if (v___x_782_ == 0)
{
v___y_778_ = v___y_781_;
goto v___jp_777_;
}
else
{
uint32_t v___x_783_; uint8_t v___x_784_;
v___x_783_ = 0;
v___x_784_ = lean_uint32_dec_eq(v___y_781_, v___x_783_);
if (v___x_784_ == 0)
{
v___y_778_ = v___y_781_;
goto v___jp_777_;
}
else
{
uint32_t v___x_785_;
v___x_785_ = 256;
v___y_770_ = v___y_781_;
v___y_771_ = v___x_785_;
goto v___jp_769_;
}
}
}
v___jp_786_:
{
uint32_t v___x_787_;
v___x_787_ = 1;
v___y_781_ = v___x_787_;
goto v___jp_780_;
}
}
}

LEAN_EXPORT uint32_t orb_admission_step(uint8_t v_recoveryPhase_805_, uint8_t v_isQuiescent_806_, uint8_t v_reservedTagForged_807_, uint64_t v_emergencyPlusCandBytes_808_, uint64_t v_freeDiskBytes_809_){
_start:
{
uint8_t v___x_810_; uint8_t v___x_811_;
v___x_810_ = 1;
v___x_811_ = lean_uint8_dec_eq(v_recoveryPhase_805_, v___x_810_);
if (v___x_811_ == 0)
{
uint8_t v___x_812_; uint8_t v___x_813_;
v___x_812_ = 2;
v___x_813_ = lean_uint8_dec_eq(v_recoveryPhase_805_, v___x_812_);
if (v___x_813_ == 0)
{
uint8_t v___x_814_;
v___x_814_ = lean_uint8_dec_eq(v_isQuiescent_806_, v___x_810_);
if (v___x_814_ == 0)
{
uint32_t v___x_815_;
v___x_815_ = 0;
return v___x_815_;
}
else
{
uint8_t v___x_816_; uint8_t v___x_817_;
v___x_816_ = 0;
v___x_817_ = lean_uint8_dec_eq(v_reservedTagForged_807_, v___x_816_);
if (v___x_817_ == 0)
{
uint32_t v___x_818_;
v___x_818_ = 0;
return v___x_818_;
}
else
{
uint8_t v___x_819_;
v___x_819_ = lean_uint64_dec_le(v_emergencyPlusCandBytes_808_, v_freeDiskBytes_809_);
if (v___x_819_ == 0)
{
uint32_t v___x_820_;
v___x_820_ = 0;
return v___x_820_;
}
else
{
uint32_t v___x_821_;
v___x_821_ = 1;
return v___x_821_;
}
}
}
}
else
{
uint32_t v___x_822_;
v___x_822_ = 65536;
return v___x_822_;
}
}
else
{
uint32_t v___x_823_;
v___x_823_ = 256;
return v___x_823_;
}
}
}

LEAN_EXPORT uint64_t orb_account_cooldown_secs(uint64_t v_baseSecs_836_, uint64_t v_maxSecs_837_, uint32_t v_consecutive_838_){
_start:
{
uint64_t v___x_839_; uint64_t v___y_841_; uint64_t v___y_842_; uint32_t v___y_843_; uint64_t v___y_850_; uint64_t v___y_851_; uint32_t v___y_852_; uint64_t v___y_856_; uint64_t v___y_857_; uint64_t v___y_863_; uint8_t v___x_865_;
v___x_839_ = 1ULL;
v___x_865_ = lean_uint64_dec_le(v___x_839_, v_baseSecs_836_);
if (v___x_865_ == 0)
{
uint64_t v___x_866_;
v___x_866_ = 600ULL;
v___y_863_ = v___x_866_;
goto v___jp_862_;
}
else
{
v___y_863_ = v_baseSecs_836_;
goto v___jp_862_;
}
v___jp_840_:
{
uint64_t v_exp_844_; uint64_t v_factor_845_; uint64_t v___x_846_; uint8_t v___x_847_;
v_exp_844_ = lean_uint32_to_uint64(v___y_843_);
v_factor_845_ = lean_uint64_shift_left(v___x_839_, v_exp_844_);
v___x_846_ = lean_uint64_div(v___y_842_, v_factor_845_);
v___x_847_ = lean_uint64_dec_lt(v___x_846_, v___y_841_);
if (v___x_847_ == 0)
{
uint64_t v___x_848_;
v___x_848_ = lean_uint64_mul(v___y_841_, v_factor_845_);
return v___x_848_;
}
else
{
return v___y_842_;
}
}
v___jp_849_:
{
uint32_t v___x_853_; uint8_t v___x_854_;
v___x_853_ = 20;
v___x_854_ = lean_uint32_dec_lt(v___x_853_, v___y_852_);
if (v___x_854_ == 0)
{
v___y_841_ = v___y_850_;
v___y_842_ = v___y_851_;
v___y_843_ = v___y_852_;
goto v___jp_840_;
}
else
{
v___y_841_ = v___y_850_;
v___y_842_ = v___y_851_;
v___y_843_ = v___x_853_;
goto v___jp_840_;
}
}
v___jp_855_:
{
uint32_t v___x_858_; uint8_t v___x_859_;
v___x_858_ = 1;
v___x_859_ = lean_uint32_dec_lt(v___x_858_, v_consecutive_838_);
if (v___x_859_ == 0)
{
uint32_t v___x_860_;
v___x_860_ = 0;
v___y_850_ = v___y_856_;
v___y_851_ = v___y_857_;
v___y_852_ = v___x_860_;
goto v___jp_849_;
}
else
{
uint32_t v___x_861_;
v___x_861_ = lean_uint32_sub(v_consecutive_838_, v___x_858_);
v___y_850_ = v___y_856_;
v___y_851_ = v___y_857_;
v___y_852_ = v___x_861_;
goto v___jp_849_;
}
}
v___jp_862_:
{
uint8_t v___x_864_;
v___x_864_ = lean_uint64_dec_lt(v___y_863_, v_maxSecs_837_);
if (v___x_864_ == 0)
{
v___y_856_ = v___y_863_;
v___y_857_ = v___y_863_;
goto v___jp_855_;
}
else
{
v___y_856_ = v___y_863_;
v___y_857_ = v_maxSecs_837_;
goto v___jp_855_;
}
}
}
}

LEAN_EXPORT uint64_t orb_cost_cents_step(uint64_t v_inputTokens_875_, uint64_t v_outputTokens_876_, uint64_t v_cacheCreateTokens_877_, uint64_t v_cacheReadTokens_878_, uint64_t v_inputNano_879_, uint64_t v_outputNano_880_, uint64_t v_cacheCreateNano_881_, uint64_t v_cacheReadNano_882_){
_start:
{
uint64_t v___y_884_; uint8_t v___x_896_;
v___x_896_ = lean_uint64_dec_le(v_cacheCreateTokens_877_, v_inputTokens_875_);
if (v___x_896_ == 0)
{
uint64_t v___x_897_;
v___x_897_ = 0ULL;
v___y_884_ = v___x_897_;
goto v___jp_883_;
}
else
{
uint64_t v___x_898_;
v___x_898_ = lean_uint64_sub(v_inputTokens_875_, v_cacheCreateTokens_877_);
v___y_884_ = v___x_898_;
goto v___jp_883_;
}
v___jp_883_:
{
uint64_t v___x_885_; uint64_t v___x_886_; uint64_t v___x_887_; uint64_t v___x_888_; uint64_t v___x_889_; uint64_t v___x_890_; uint64_t v_totalNano_891_; uint64_t v___x_892_; uint64_t v___x_893_; uint64_t v___x_894_; uint64_t v___x_895_;
v___x_885_ = lean_uint64_mul(v___y_884_, v_inputNano_879_);
v___x_886_ = lean_uint64_mul(v_outputTokens_876_, v_outputNano_880_);
v___x_887_ = lean_uint64_add(v___x_885_, v___x_886_);
v___x_888_ = lean_uint64_mul(v_cacheCreateTokens_877_, v_cacheCreateNano_881_);
v___x_889_ = lean_uint64_add(v___x_887_, v___x_888_);
v___x_890_ = lean_uint64_mul(v_cacheReadTokens_878_, v_cacheReadNano_882_);
v_totalNano_891_ = lean_uint64_add(v___x_889_, v___x_890_);
v___x_892_ = 5000000ULL;
v___x_893_ = lean_uint64_add(v_totalNano_891_, v___x_892_);
v___x_894_ = 10000000ULL;
v___x_895_ = lean_uint64_div(v___x_893_, v___x_894_);
return v___x_895_;
}
}
}

LEAN_EXPORT uint8_t orb_stream_loop_step(uint8_t v_cancelledOrTimedOut_917_, uint8_t v_hashCollision_918_, uint32_t v_windowLen_919_, uint32_t v_minLen_920_, uint32_t v_repeats_921_, uint32_t v_nonOverlappingCount_922_, uint32_t v_distinctWords4Plus_923_, uint64_t v_comparisons_924_, uint64_t v_comparisonBudget_925_){
_start:
{
uint8_t v___x_926_; uint8_t v___x_927_;
v___x_926_ = 1;
v___x_927_ = lean_uint8_dec_eq(v_cancelledOrTimedOut_917_, v___x_926_);
if (v___x_927_ == 0)
{
uint32_t v___x_928_; uint8_t v___x_929_;
v___x_928_ = 256;
v___x_929_ = lean_uint32_dec_lt(v___x_928_, v_minLen_920_);
if (v___x_929_ == 0)
{
uint8_t v___x_930_;
v___x_930_ = lean_uint64_dec_lt(v_comparisonBudget_925_, v_comparisons_924_);
if (v___x_930_ == 0)
{
uint32_t v___x_931_; uint8_t v___x_932_;
v___x_931_ = 0;
v___x_932_ = lean_uint32_dec_eq(v_minLen_920_, v___x_931_);
if (v___x_932_ == 0)
{
uint32_t v___x_933_; uint8_t v___x_934_;
v___x_933_ = 2;
v___x_934_ = lean_uint32_dec_lt(v_repeats_921_, v___x_933_);
if (v___x_934_ == 0)
{
uint32_t v___x_935_; uint8_t v___x_936_;
v___x_935_ = lean_uint32_mul(v_minLen_920_, v_repeats_921_);
v___x_936_ = lean_uint32_dec_lt(v_windowLen_919_, v___x_935_);
if (v___x_936_ == 0)
{
uint8_t v___x_937_;
v___x_937_ = lean_uint8_dec_eq(v_hashCollision_918_, v___x_926_);
if (v___x_937_ == 0)
{
uint8_t v___x_938_;
v___x_938_ = lean_uint32_dec_le(v_repeats_921_, v_nonOverlappingCount_922_);
if (v___x_938_ == 0)
{
uint8_t v___x_939_;
v___x_939_ = 0;
return v___x_939_;
}
else
{
uint8_t v___x_940_;
v___x_940_ = lean_uint32_dec_le(v___x_933_, v_distinctWords4Plus_923_);
if (v___x_940_ == 0)
{
uint8_t v___x_941_;
v___x_941_ = 0;
return v___x_941_;
}
else
{
return v___x_926_;
}
}
}
else
{
uint8_t v___x_942_;
v___x_942_ = 2;
return v___x_942_;
}
}
else
{
uint8_t v___x_943_;
v___x_943_ = 0;
return v___x_943_;
}
}
else
{
uint8_t v___x_944_;
v___x_944_ = 0;
return v___x_944_;
}
}
else
{
uint8_t v___x_945_;
v___x_945_ = 0;
return v___x_945_;
}
}
else
{
uint8_t v___x_946_;
v___x_946_ = 2;
return v___x_946_;
}
}
else
{
uint8_t v___x_947_;
v___x_947_ = 2;
return v___x_947_;
}
}
else
{
uint8_t v___x_948_;
v___x_948_ = 2;
return v___x_948_;
}
}
}

LEAN_EXPORT uint32_t orb_job_ledger_step(uint8_t v_isAcceptedRemoteBuild_969_, uint8_t v_expectsContinuation_970_, uint8_t v_newerTerminalExists_971_, uint8_t v_newerAmbiguousTentative_972_){
_start:
{
uint8_t v___x_973_; uint32_t v___y_975_; uint8_t v___x_982_;
v___x_973_ = 1;
v___x_982_ = lean_uint8_dec_eq(v_newerTerminalExists_971_, v___x_973_);
if (v___x_982_ == 0)
{
uint8_t v___x_983_;
v___x_983_ = lean_uint8_dec_eq(v_newerAmbiguousTentative_972_, v___x_973_);
if (v___x_983_ == 0)
{
uint32_t v___x_984_;
v___x_984_ = 0;
v___y_975_ = v___x_984_;
goto v___jp_974_;
}
else
{
uint32_t v___x_985_;
v___x_985_ = 256;
v___y_975_ = v___x_985_;
goto v___jp_974_;
}
}
else
{
uint32_t v___x_986_;
v___x_986_ = 512;
v___y_975_ = v___x_986_;
goto v___jp_974_;
}
v___jp_974_:
{
uint8_t v___x_976_;
v___x_976_ = lean_uint8_dec_eq(v_isAcceptedRemoteBuild_969_, v___x_973_);
if (v___x_976_ == 0)
{
return v___y_975_;
}
else
{
uint8_t v___x_977_;
v___x_977_ = lean_uint8_dec_eq(v_expectsContinuation_970_, v___x_973_);
if (v___x_977_ == 0)
{
return v___y_975_;
}
else
{
uint32_t v___x_978_; uint8_t v___x_979_;
v___x_978_ = 0;
v___x_979_ = lean_uint32_dec_eq(v___y_975_, v___x_978_);
if (v___x_979_ == 0)
{
return v___y_975_;
}
else
{
uint32_t v___x_980_; uint32_t v___x_981_;
v___x_980_ = 1;
v___x_981_ = lean_uint32_lor(v___x_980_, v___y_975_);
return v___x_981_;
}
}
}
}
}
}

LEAN_EXPORT uint8_t orb_proc_liveness_step(uint8_t v_procMissing_997_, uint8_t v_procReadError_998_, uint8_t v_isZombieOrDeadState_999_, uint8_t v_hasExpectedTicks_1000_, uint32_t v_fieldsAfterComm_1001_, uint64_t v_expectedStartTicks_1002_, uint64_t v_actualStartTicks_1003_){
_start:
{
uint8_t v___x_1004_; uint8_t v___x_1005_;
v___x_1004_ = 1;
v___x_1005_ = lean_uint8_dec_eq(v_procMissing_997_, v___x_1004_);
if (v___x_1005_ == 0)
{
uint8_t v___x_1006_;
v___x_1006_ = lean_uint8_dec_eq(v_procReadError_998_, v___x_1004_);
if (v___x_1006_ == 0)
{
uint8_t v___x_1007_;
v___x_1007_ = lean_uint8_dec_eq(v_isZombieOrDeadState_999_, v___x_1004_);
if (v___x_1007_ == 0)
{
uint32_t v___x_1008_; uint8_t v___x_1009_;
v___x_1008_ = 20;
v___x_1009_ = lean_uint32_dec_lt(v_fieldsAfterComm_1001_, v___x_1008_);
if (v___x_1009_ == 0)
{
uint8_t v___x_1010_;
v___x_1010_ = lean_uint8_dec_eq(v_hasExpectedTicks_1000_, v___x_1004_);
if (v___x_1010_ == 0)
{
return v___x_1004_;
}
else
{
uint8_t v___x_1011_;
v___x_1011_ = lean_uint64_dec_eq(v_actualStartTicks_1003_, v_expectedStartTicks_1002_);
if (v___x_1011_ == 0)
{
uint8_t v___x_1012_;
v___x_1012_ = 0;
return v___x_1012_;
}
else
{
return v___x_1004_;
}
}
}
else
{
uint8_t v___x_1013_;
v___x_1013_ = 0;
return v___x_1013_;
}
}
else
{
uint8_t v___x_1014_;
v___x_1014_ = 0;
return v___x_1014_;
}
}
else
{
uint8_t v___x_1015_;
v___x_1015_ = 2;
return v___x_1015_;
}
}
else
{
uint8_t v___x_1016_;
v___x_1016_ = 0;
return v___x_1016_;
}
}
}

LEAN_EXPORT uint8_t orb_pr_gate_step(uint8_t v_merged_1033_, uint8_t v_draft_1034_, uint8_t v_closed_1035_, uint8_t v_exactHead_1036_, uint8_t v_actionRequired_1037_, uint8_t v_blocked_1038_, uint8_t v_behind_1039_, uint8_t v_conflicting_1040_, uint8_t v_checksGreen_1041_, uint8_t v_workflowsGreen_1042_){
_start:
{
uint8_t v___x_1043_; uint8_t v___x_1044_;
v___x_1043_ = 1;
v___x_1044_ = lean_uint8_dec_eq(v_merged_1033_, v___x_1043_);
if (v___x_1044_ == 0)
{
uint8_t v___x_1045_;
v___x_1045_ = lean_uint8_dec_eq(v_draft_1034_, v___x_1043_);
if (v___x_1045_ == 0)
{
uint8_t v___x_1046_;
v___x_1046_ = lean_uint8_dec_eq(v_closed_1035_, v___x_1043_);
if (v___x_1046_ == 0)
{
uint8_t v___x_1047_; uint8_t v___x_1048_;
v___x_1047_ = 0;
v___x_1048_ = lean_uint8_dec_eq(v_exactHead_1036_, v___x_1047_);
if (v___x_1048_ == 0)
{
uint8_t v___x_1049_;
v___x_1049_ = lean_uint8_dec_eq(v_actionRequired_1037_, v___x_1043_);
if (v___x_1049_ == 0)
{
uint8_t v___x_1050_;
v___x_1050_ = lean_uint8_dec_eq(v_blocked_1038_, v___x_1043_);
if (v___x_1050_ == 0)
{
uint8_t v___x_1051_;
v___x_1051_ = lean_uint8_dec_eq(v_behind_1039_, v___x_1043_);
if (v___x_1051_ == 0)
{
uint8_t v___x_1052_;
v___x_1052_ = lean_uint8_dec_eq(v_conflicting_1040_, v___x_1043_);
if (v___x_1052_ == 0)
{
uint8_t v___x_1053_;
v___x_1053_ = lean_uint8_dec_eq(v_checksGreen_1041_, v___x_1043_);
if (v___x_1053_ == 0)
{
uint8_t v___x_1054_;
v___x_1054_ = 9;
return v___x_1054_;
}
else
{
uint8_t v___x_1055_;
v___x_1055_ = lean_uint8_dec_eq(v_workflowsGreen_1042_, v___x_1043_);
if (v___x_1055_ == 0)
{
uint8_t v___x_1056_;
v___x_1056_ = 9;
return v___x_1056_;
}
else
{
uint8_t v___x_1057_;
v___x_1057_ = 8;
return v___x_1057_;
}
}
}
else
{
uint8_t v___x_1058_;
v___x_1058_ = 7;
return v___x_1058_;
}
}
else
{
uint8_t v___x_1059_;
v___x_1059_ = 6;
return v___x_1059_;
}
}
else
{
uint8_t v___x_1060_;
v___x_1060_ = 5;
return v___x_1060_;
}
}
else
{
uint8_t v___x_1061_;
v___x_1061_ = 4;
return v___x_1061_;
}
}
else
{
uint8_t v___x_1062_;
v___x_1062_ = 3;
return v___x_1062_;
}
}
else
{
uint8_t v___x_1063_;
v___x_1063_ = 2;
return v___x_1063_;
}
}
else
{
return v___x_1043_;
}
}
else
{
uint8_t v___x_1064_;
v___x_1064_ = 0;
return v___x_1064_;
}
}
}

LEAN_EXPORT uint32_t orb_turn_summary_step(uint8_t v_rawStatus_1087_, uint8_t v_turnEnded_1088_, uint8_t v_allClosed_1089_, uint8_t v_turnOutcomeFinished_1090_){
_start:
{
uint8_t v___y_1092_; uint32_t v___y_1093_; uint32_t v___y_1094_; uint8_t v___y_1095_; uint8_t v___x_1103_; uint8_t v___y_1105_; uint32_t v___y_1106_; uint32_t v___y_1107_; uint8_t v___y_1115_; uint32_t v___y_1116_; uint8_t v___y_1122_; uint8_t v___x_1128_;
v___x_1103_ = 2;
v___x_1128_ = lean_uint8_dec_eq(v_rawStatus_1087_, v___x_1103_);
if (v___x_1128_ == 0)
{
uint8_t v___x_1129_; uint8_t v___x_1130_;
v___x_1129_ = 3;
v___x_1130_ = lean_uint8_dec_eq(v_rawStatus_1087_, v___x_1129_);
if (v___x_1130_ == 0)
{
uint8_t v___x_1131_; uint8_t v___x_1132_;
v___x_1131_ = 1;
v___x_1132_ = lean_uint8_dec_eq(v_rawStatus_1087_, v___x_1131_);
if (v___x_1132_ == 0)
{
goto v___jp_1126_;
}
else
{
uint8_t v___x_1133_; uint8_t v___x_1134_;
v___x_1133_ = 0;
v___x_1134_ = lean_uint8_dec_eq(v_turnEnded_1088_, v___x_1133_);
if (v___x_1134_ == 0)
{
goto v___jp_1126_;
}
else
{
v___y_1122_ = v___x_1131_;
goto v___jp_1121_;
}
}
}
else
{
v___y_1122_ = v___x_1129_;
goto v___jp_1121_;
}
}
else
{
v___y_1122_ = v___x_1103_;
goto v___jp_1121_;
}
v___jp_1091_:
{
uint32_t v___x_1096_; uint32_t v___x_1097_; uint32_t v_card_1098_; uint32_t v___x_1099_; uint32_t v___x_1100_; uint32_t v___x_1101_; uint32_t v___x_1102_;
v___x_1096_ = lean_uint8_to_uint32(v___y_1095_);
v___x_1097_ = 24;
v_card_1098_ = lean_uint32_shift_left(v___x_1096_, v___x_1097_);
v___x_1099_ = lean_uint8_to_uint32(v___y_1092_);
v___x_1100_ = lean_uint32_lor(v___x_1099_, v___y_1094_);
v___x_1101_ = lean_uint32_lor(v___x_1100_, v___y_1093_);
v___x_1102_ = lean_uint32_lor(v___x_1101_, v_card_1098_);
return v___x_1102_;
}
v___jp_1104_:
{
uint8_t v___x_1108_; uint8_t v___x_1109_;
v___x_1108_ = 0;
v___x_1109_ = lean_uint8_dec_eq(v_turnEnded_1088_, v___x_1108_);
if (v___x_1109_ == 0)
{
uint8_t v___x_1110_; uint8_t v___x_1111_;
v___x_1110_ = 1;
v___x_1111_ = lean_uint8_dec_eq(v_allClosed_1089_, v___x_1110_);
if (v___x_1111_ == 0)
{
uint8_t v___x_1112_;
v___x_1112_ = lean_uint8_dec_eq(v_turnOutcomeFinished_1090_, v___x_1110_);
if (v___x_1112_ == 0)
{
uint8_t v___x_1113_;
v___x_1113_ = 3;
v___y_1092_ = v___y_1105_;
v___y_1093_ = v___y_1107_;
v___y_1094_ = v___y_1106_;
v___y_1095_ = v___x_1113_;
goto v___jp_1091_;
}
else
{
v___y_1092_ = v___y_1105_;
v___y_1093_ = v___y_1107_;
v___y_1094_ = v___y_1106_;
v___y_1095_ = v___x_1103_;
goto v___jp_1091_;
}
}
else
{
v___y_1092_ = v___y_1105_;
v___y_1093_ = v___y_1107_;
v___y_1094_ = v___y_1106_;
v___y_1095_ = v___x_1110_;
goto v___jp_1091_;
}
}
else
{
v___y_1092_ = v___y_1105_;
v___y_1093_ = v___y_1107_;
v___y_1094_ = v___y_1106_;
v___y_1095_ = v___x_1108_;
goto v___jp_1091_;
}
}
v___jp_1114_:
{
uint8_t v___x_1117_; uint8_t v___x_1118_;
v___x_1117_ = 1;
v___x_1118_ = lean_uint8_dec_eq(v___y_1115_, v___x_1117_);
if (v___x_1118_ == 0)
{
uint32_t v___x_1119_;
v___x_1119_ = 0;
v___y_1105_ = v___y_1115_;
v___y_1106_ = v___y_1116_;
v___y_1107_ = v___x_1119_;
goto v___jp_1104_;
}
else
{
uint32_t v___x_1120_;
v___x_1120_ = 65536;
v___y_1105_ = v___y_1115_;
v___y_1106_ = v___y_1116_;
v___y_1107_ = v___x_1120_;
goto v___jp_1104_;
}
}
v___jp_1121_:
{
uint8_t v___x_1123_;
v___x_1123_ = lean_uint8_dec_eq(v___y_1122_, v___x_1103_);
if (v___x_1123_ == 0)
{
uint32_t v___x_1124_;
v___x_1124_ = 0;
v___y_1115_ = v___y_1122_;
v___y_1116_ = v___x_1124_;
goto v___jp_1114_;
}
else
{
uint32_t v___x_1125_;
v___x_1125_ = 256;
v___y_1115_ = v___y_1122_;
v___y_1116_ = v___x_1125_;
goto v___jp_1114_;
}
}
v___jp_1126_:
{
uint8_t v___x_1127_;
v___x_1127_ = 0;
v___y_1122_ = v___x_1127_;
goto v___jp_1121_;
}
}
}

LEAN_EXPORT uint64_t orb_usage_limit_status(uint8_t v_statusKind_1145_, uint8_t v_claimKind_1146_, uint8_t v_hasUtilization_1147_, uint8_t v_utilizationPct_1148_, uint8_t v_hasReset_1149_, uint64_t v_resetRemSecs_1150_){
_start:
{
uint64_t v___y_1152_; uint64_t v___y_1153_; uint64_t v___y_1162_; uint64_t v___y_1163_; uint64_t v___y_1167_; uint64_t v___y_1168_; uint64_t v___y_1169_; uint64_t v___y_1175_; uint64_t v___y_1176_; uint64_t v___y_1183_; uint8_t v___x_1185_; uint8_t v___x_1186_;
v___x_1185_ = 0;
v___x_1186_ = lean_uint8_dec_eq(v_statusKind_1145_, v___x_1185_);
if (v___x_1186_ == 0)
{
uint8_t v___x_1187_; uint64_t v___y_1189_; uint64_t v___y_1195_; uint8_t v___x_1201_;
v___x_1187_ = 1;
v___x_1201_ = lean_uint8_dec_eq(v_statusKind_1145_, v___x_1187_);
if (v___x_1201_ == 0)
{
uint8_t v___x_1202_; uint8_t v___x_1203_;
v___x_1202_ = 2;
v___x_1203_ = lean_uint8_dec_eq(v_statusKind_1145_, v___x_1202_);
if (v___x_1203_ == 0)
{
uint64_t v___x_1204_;
v___x_1204_ = 3ULL;
return v___x_1204_;
}
else
{
uint8_t v___x_1205_;
v___x_1205_ = lean_uint8_dec_eq(v_hasReset_1149_, v___x_1187_);
if (v___x_1205_ == 0)
{
uint64_t v___x_1206_;
v___x_1206_ = 2ULL;
return v___x_1206_;
}
else
{
uint64_t v___x_1207_; uint8_t v___x_1208_;
v___x_1207_ = 0ULL;
v___x_1208_ = lean_uint64_dec_lt(v___x_1207_, v_resetRemSecs_1150_);
if (v___x_1208_ == 0)
{
uint64_t v___x_1209_;
v___x_1209_ = 2ULL;
return v___x_1209_;
}
else
{
uint64_t v___x_1210_; uint64_t v_mins_1211_; uint64_t v___x_1212_; uint64_t v_hrs_1213_; uint64_t v___x_1214_; uint64_t v_days_1215_; uint8_t v___x_1216_; uint64_t v___y_1218_;
v___x_1210_ = 60ULL;
v_mins_1211_ = lean_uint64_div(v_resetRemSecs_1150_, v___x_1210_);
v___x_1212_ = 3600ULL;
v_hrs_1213_ = lean_uint64_div(v_resetRemSecs_1150_, v___x_1212_);
v___x_1214_ = 86400ULL;
v_days_1215_ = lean_uint64_div(v_resetRemSecs_1150_, v___x_1214_);
v___x_1216_ = lean_uint64_dec_lt(v_mins_1211_, v___x_1210_);
if (v___x_1216_ == 0)
{
uint64_t v___x_1223_; uint8_t v___x_1224_;
v___x_1223_ = 48ULL;
v___x_1224_ = lean_uint64_dec_lt(v_hrs_1213_, v___x_1223_);
if (v___x_1224_ == 0)
{
uint64_t v___x_1225_;
v___x_1225_ = 3ULL;
v___y_1218_ = v___x_1225_;
goto v___jp_1217_;
}
else
{
uint64_t v___x_1226_;
v___x_1226_ = 2ULL;
v___y_1218_ = v___x_1226_;
goto v___jp_1217_;
}
}
else
{
uint64_t v___x_1227_;
v___x_1227_ = 1ULL;
v___y_1218_ = v___x_1227_;
goto v___jp_1217_;
}
v___jp_1217_:
{
if (v___x_1216_ == 0)
{
uint64_t v___x_1219_; uint8_t v___x_1220_;
v___x_1219_ = 48ULL;
v___x_1220_ = lean_uint64_dec_lt(v_hrs_1213_, v___x_1219_);
if (v___x_1220_ == 0)
{
v___y_1162_ = v___y_1218_;
v___y_1163_ = v_days_1215_;
goto v___jp_1161_;
}
else
{
v___y_1162_ = v___y_1218_;
v___y_1163_ = v_hrs_1213_;
goto v___jp_1161_;
}
}
else
{
uint64_t v___x_1221_; uint8_t v___x_1222_;
v___x_1221_ = 1ULL;
v___x_1222_ = lean_uint64_dec_le(v___x_1221_, v_mins_1211_);
if (v___x_1222_ == 0)
{
v___y_1162_ = v___y_1218_;
v___y_1163_ = v___x_1221_;
goto v___jp_1161_;
}
else
{
v___y_1162_ = v___y_1218_;
v___y_1163_ = v_mins_1211_;
goto v___jp_1161_;
}
}
}
}
}
}
}
else
{
uint8_t v___x_1228_;
v___x_1228_ = lean_uint8_dec_le(v___x_1187_, v_claimKind_1146_);
if (v___x_1228_ == 0)
{
goto v___jp_1199_;
}
else
{
uint8_t v___x_1229_; uint8_t v___x_1230_;
v___x_1229_ = 4;
v___x_1230_ = lean_uint8_dec_le(v_claimKind_1146_, v___x_1229_);
if (v___x_1230_ == 0)
{
goto v___jp_1199_;
}
else
{
uint64_t v___x_1231_; uint64_t v___x_1232_; uint64_t v___x_1233_;
v___x_1231_ = lean_uint8_to_uint64(v_claimKind_1146_);
v___x_1232_ = 8ULL;
v___x_1233_ = lean_uint64_shift_left(v___x_1231_, v___x_1232_);
v___y_1195_ = v___x_1233_;
goto v___jp_1194_;
}
}
}
v___jp_1188_:
{
uint8_t v___x_1190_;
v___x_1190_ = lean_uint8_dec_eq(v_hasUtilization_1147_, v___x_1187_);
if (v___x_1190_ == 0)
{
v___y_1183_ = v___y_1189_;
goto v___jp_1182_;
}
else
{
uint8_t v___x_1191_; uint8_t v___x_1192_;
v___x_1191_ = 100;
v___x_1192_ = lean_uint8_dec_le(v_utilizationPct_1148_, v___x_1191_);
if (v___x_1192_ == 0)
{
v___y_1183_ = v___y_1189_;
goto v___jp_1182_;
}
else
{
uint64_t v___x_1193_;
v___x_1193_ = 65536ULL;
v___y_1175_ = v___y_1189_;
v___y_1176_ = v___x_1193_;
goto v___jp_1174_;
}
}
}
v___jp_1194_:
{
uint8_t v___x_1196_;
v___x_1196_ = lean_uint8_dec_eq(v_claimKind_1146_, v___x_1187_);
if (v___x_1196_ == 0)
{
uint8_t v___x_1197_; uint8_t v___x_1198_;
v___x_1197_ = 2;
v___x_1198_ = lean_uint8_dec_eq(v_claimKind_1146_, v___x_1197_);
if (v___x_1198_ == 0)
{
v___y_1183_ = v___y_1195_;
goto v___jp_1182_;
}
else
{
v___y_1189_ = v___y_1195_;
goto v___jp_1188_;
}
}
else
{
v___y_1189_ = v___y_1195_;
goto v___jp_1188_;
}
}
v___jp_1199_:
{
uint64_t v___x_1200_;
v___x_1200_ = 0ULL;
v___y_1195_ = v___x_1200_;
goto v___jp_1194_;
}
}
else
{
uint64_t v___x_1234_;
v___x_1234_ = 0ULL;
return v___x_1234_;
}
v___jp_1151_:
{
uint64_t v___x_1154_; uint64_t v___x_1155_; uint64_t v___x_1156_; uint64_t v___x_1157_; uint64_t v___x_1158_; uint64_t v___x_1159_; uint64_t v___x_1160_;
v___x_1154_ = 2ULL;
v___x_1155_ = 32ULL;
v___x_1156_ = lean_uint64_shift_left(v___y_1152_, v___x_1155_);
v___x_1157_ = lean_uint64_lor(v___x_1154_, v___x_1156_);
v___x_1158_ = 40ULL;
v___x_1159_ = lean_uint64_shift_left(v___y_1153_, v___x_1158_);
v___x_1160_ = lean_uint64_lor(v___x_1157_, v___x_1159_);
return v___x_1160_;
}
v___jp_1161_:
{
uint64_t v___x_1164_; uint8_t v___x_1165_;
v___x_1164_ = 16777215ULL;
v___x_1165_ = lean_uint64_dec_lt(v___x_1164_, v___y_1163_);
if (v___x_1165_ == 0)
{
v___y_1152_ = v___y_1162_;
v___y_1153_ = v___y_1163_;
goto v___jp_1151_;
}
else
{
v___y_1152_ = v___y_1162_;
v___y_1153_ = v___x_1164_;
goto v___jp_1151_;
}
}
v___jp_1166_:
{
uint64_t v___x_1170_; uint64_t v___x_1171_; uint64_t v___x_1172_; uint64_t v___x_1173_;
v___x_1170_ = 1ULL;
v___x_1171_ = lean_uint64_lor(v___x_1170_, v___y_1168_);
v___x_1172_ = lean_uint64_lor(v___x_1171_, v___y_1167_);
v___x_1173_ = lean_uint64_lor(v___x_1172_, v___y_1169_);
return v___x_1173_;
}
v___jp_1174_:
{
uint64_t v___x_1177_; uint8_t v___x_1178_;
v___x_1177_ = 0ULL;
v___x_1178_ = lean_uint64_dec_eq(v___y_1176_, v___x_1177_);
if (v___x_1178_ == 0)
{
uint64_t v___x_1179_; uint64_t v___x_1180_; uint64_t v___x_1181_;
v___x_1179_ = lean_uint8_to_uint64(v_utilizationPct_1148_);
v___x_1180_ = 24ULL;
v___x_1181_ = lean_uint64_shift_left(v___x_1179_, v___x_1180_);
v___y_1167_ = v___y_1176_;
v___y_1168_ = v___y_1175_;
v___y_1169_ = v___x_1181_;
goto v___jp_1166_;
}
else
{
v___y_1167_ = v___y_1176_;
v___y_1168_ = v___y_1175_;
v___y_1169_ = v___x_1177_;
goto v___jp_1166_;
}
}
v___jp_1182_:
{
uint64_t v___x_1184_;
v___x_1184_ = 0ULL;
v___y_1175_ = v___y_1183_;
v___y_1176_ = v___x_1184_;
goto v___jp_1174_;
}
}
}

LEAN_EXPORT uint64_t orb_relative_time_bucket(uint64_t v_elapsedSecs_1249_){
_start:
{
uint64_t v___y_1251_; uint64_t v___x_1256_; uint8_t v___x_1257_;
v___x_1256_ = 45ULL;
v___x_1257_ = lean_uint64_dec_lt(v_elapsedSecs_1249_, v___x_1256_);
if (v___x_1257_ == 0)
{
uint64_t v___x_1258_; uint8_t v___x_1259_;
v___x_1258_ = 3600ULL;
v___x_1259_ = lean_uint64_dec_lt(v_elapsedSecs_1249_, v___x_1258_);
if (v___x_1259_ == 0)
{
uint64_t v___x_1260_; uint8_t v___x_1261_;
v___x_1260_ = 86400ULL;
v___x_1261_ = lean_uint64_dec_lt(v_elapsedSecs_1249_, v___x_1260_);
if (v___x_1261_ == 0)
{
uint64_t v___x_1262_; uint8_t v___x_1263_;
v___x_1262_ = 604800ULL;
v___x_1263_ = lean_uint64_dec_lt(v_elapsedSecs_1249_, v___x_1262_);
if (v___x_1263_ == 0)
{
uint64_t v_wks_1264_; uint64_t v___x_1265_; uint8_t v___x_1266_;
v_wks_1264_ = lean_uint64_div(v_elapsedSecs_1249_, v___x_1262_);
v___x_1265_ = 4294967295ULL;
v___x_1266_ = lean_uint64_dec_lt(v___x_1265_, v_wks_1264_);
if (v___x_1266_ == 0)
{
v___y_1251_ = v_wks_1264_;
goto v___jp_1250_;
}
else
{
v___y_1251_ = v___x_1265_;
goto v___jp_1250_;
}
}
else
{
uint64_t v___x_1267_; uint64_t v___x_1268_; uint64_t v___x_1269_; uint64_t v___x_1270_; uint64_t v___x_1271_;
v___x_1267_ = 3ULL;
v___x_1268_ = lean_uint64_div(v_elapsedSecs_1249_, v___x_1260_);
v___x_1269_ = 8ULL;
v___x_1270_ = lean_uint64_shift_left(v___x_1268_, v___x_1269_);
v___x_1271_ = lean_uint64_lor(v___x_1267_, v___x_1270_);
return v___x_1271_;
}
}
else
{
uint64_t v___x_1272_; uint64_t v___x_1273_; uint64_t v___x_1274_; uint64_t v___x_1275_; uint64_t v___x_1276_;
v___x_1272_ = 2ULL;
v___x_1273_ = lean_uint64_div(v_elapsedSecs_1249_, v___x_1258_);
v___x_1274_ = 8ULL;
v___x_1275_ = lean_uint64_shift_left(v___x_1273_, v___x_1274_);
v___x_1276_ = lean_uint64_lor(v___x_1272_, v___x_1275_);
return v___x_1276_;
}
}
else
{
uint64_t v___x_1277_; uint64_t v_mins_1278_; uint64_t v___x_1279_; uint64_t v___y_1281_; uint8_t v___x_1285_;
v___x_1277_ = 60ULL;
v_mins_1278_ = lean_uint64_div(v_elapsedSecs_1249_, v___x_1277_);
v___x_1279_ = 1ULL;
v___x_1285_ = lean_uint64_dec_le(v___x_1279_, v_mins_1278_);
if (v___x_1285_ == 0)
{
v___y_1281_ = v___x_1279_;
goto v___jp_1280_;
}
else
{
v___y_1281_ = v_mins_1278_;
goto v___jp_1280_;
}
v___jp_1280_:
{
uint64_t v___x_1282_; uint64_t v___x_1283_; uint64_t v___x_1284_;
v___x_1282_ = 8ULL;
v___x_1283_ = lean_uint64_shift_left(v___y_1281_, v___x_1282_);
v___x_1284_ = lean_uint64_lor(v___x_1279_, v___x_1283_);
return v___x_1284_;
}
}
}
else
{
uint64_t v___x_1286_;
v___x_1286_ = 0ULL;
return v___x_1286_;
}
v___jp_1250_:
{
uint64_t v___x_1252_; uint64_t v___x_1253_; uint64_t v___x_1254_; uint64_t v___x_1255_;
v___x_1252_ = 4ULL;
v___x_1253_ = 8ULL;
v___x_1254_ = lean_uint64_shift_left(v___y_1251_, v___x_1253_);
v___x_1255_ = lean_uint64_lor(v___x_1252_, v___x_1254_);
return v___x_1255_;
}
}
}

LEAN_EXPORT uint64_t orb_transcript_patch_step(uint32_t v_stateLen_1303_, uint32_t v_stateSeq_1304_, uint8_t v_eventKind_1305_, uint32_t v_deltaLen_1306_){
_start:
{
uint64_t v___y_1308_; uint32_t v___y_1309_; uint32_t v___y_1315_; uint8_t v___x_1322_; uint8_t v___x_1323_;
v___x_1322_ = 2;
v___x_1323_ = lean_uint8_dec_le(v_eventKind_1305_, v___x_1322_);
if (v___x_1323_ == 0)
{
uint64_t v___x_1324_; uint64_t v___x_1325_; uint64_t v___x_1326_; uint64_t v___x_1327_; uint64_t v___x_1328_;
v___x_1324_ = lean_uint32_to_uint64(v_stateLen_1303_);
v___x_1325_ = lean_uint32_to_uint64(v_stateSeq_1304_);
v___x_1326_ = 32ULL;
v___x_1327_ = lean_uint64_shift_left(v___x_1325_, v___x_1326_);
v___x_1328_ = lean_uint64_lor(v___x_1324_, v___x_1327_);
return v___x_1328_;
}
else
{
uint8_t v___x_1329_;
v___x_1329_ = lean_uint8_dec_eq(v_eventKind_1305_, v___x_1322_);
if (v___x_1329_ == 0)
{
uint8_t v___x_1330_; uint8_t v___x_1331_;
v___x_1330_ = 1;
v___x_1331_ = lean_uint8_dec_eq(v_eventKind_1305_, v___x_1330_);
if (v___x_1331_ == 0)
{
uint32_t v___x_1332_; uint32_t v___x_1333_; uint8_t v___x_1334_;
v___x_1332_ = 4294967295;
v___x_1333_ = lean_uint32_sub(v___x_1332_, v_deltaLen_1306_);
v___x_1334_ = lean_uint32_dec_le(v_stateLen_1303_, v___x_1333_);
if (v___x_1334_ == 0)
{
v___y_1315_ = v___x_1332_;
goto v___jp_1314_;
}
else
{
uint32_t v___x_1335_;
v___x_1335_ = lean_uint32_add(v_stateLen_1303_, v_deltaLen_1306_);
v___y_1315_ = v___x_1335_;
goto v___jp_1314_;
}
}
else
{
uint32_t v___x_1336_; uint8_t v___x_1337_;
v___x_1336_ = 0;
v___x_1337_ = lean_uint32_dec_lt(v___x_1336_, v_deltaLen_1306_);
if (v___x_1337_ == 0)
{
v___y_1315_ = v_stateLen_1303_;
goto v___jp_1314_;
}
else
{
v___y_1315_ = v_deltaLen_1306_;
goto v___jp_1314_;
}
}
}
else
{
uint32_t v___x_1338_;
v___x_1338_ = 0;
v___y_1315_ = v___x_1338_;
goto v___jp_1314_;
}
}
v___jp_1307_:
{
uint64_t v___x_1310_; uint64_t v___x_1311_; uint64_t v___x_1312_; uint64_t v___x_1313_;
v___x_1310_ = lean_uint32_to_uint64(v___y_1309_);
v___x_1311_ = 32ULL;
v___x_1312_ = lean_uint64_shift_left(v___x_1310_, v___x_1311_);
v___x_1313_ = lean_uint64_lor(v___y_1308_, v___x_1312_);
return v___x_1313_;
}
v___jp_1314_:
{
uint64_t v___x_1316_; uint32_t v___x_1317_; uint8_t v___x_1318_;
v___x_1316_ = lean_uint32_to_uint64(v___y_1315_);
v___x_1317_ = 4294967294;
v___x_1318_ = lean_uint32_dec_le(v_stateSeq_1304_, v___x_1317_);
if (v___x_1318_ == 0)
{
uint32_t v___x_1319_;
v___x_1319_ = 4294967295;
v___y_1308_ = v___x_1316_;
v___y_1309_ = v___x_1319_;
goto v___jp_1307_;
}
else
{
uint32_t v___x_1320_; uint32_t v___x_1321_;
v___x_1320_ = 1;
v___x_1321_ = lean_uint32_add(v_stateSeq_1304_, v___x_1320_);
v___y_1308_ = v___x_1316_;
v___y_1309_ = v___x_1321_;
goto v___jp_1307_;
}
}
}
}

LEAN_EXPORT uint32_t orb_attribution_step(uint8_t v_principalKind_1460_, uint8_t v_claimedKind_1461_, uint8_t v_sameMission_1462_, uint8_t v_isDescendant_1463_){
_start:
{
uint8_t v___y_1465_; uint8_t v___y_1470_; uint8_t v___y_1474_; uint8_t v___y_1475_; uint8_t v___y_1478_; uint8_t v___x_1513_; uint8_t v___x_1514_;
v___x_1513_ = 6;
v___x_1514_ = lean_uint8_dec_le(v_principalKind_1460_, v___x_1513_);
if (v___x_1514_ == 0)
{
uint8_t v___x_1515_;
v___x_1515_ = 0;
v___y_1478_ = v___x_1515_;
goto v___jp_1477_;
}
else
{
v___y_1478_ = v_principalKind_1460_;
goto v___jp_1477_;
}
v___jp_1464_:
{
uint32_t v___x_1466_; uint32_t v___x_1467_; uint32_t v___x_1468_;
v___x_1466_ = lean_uint8_to_uint32(v___y_1465_);
v___x_1467_ = 256;
v___x_1468_ = lean_uint32_lor(v___x_1466_, v___x_1467_);
return v___x_1468_;
}
v___jp_1469_:
{
uint8_t v___x_1471_; uint8_t v___x_1472_;
v___x_1471_ = 0;
v___x_1472_ = lean_uint8_dec_eq(v_claimedKind_1461_, v___x_1471_);
if (v___x_1472_ == 0)
{
v___y_1465_ = v_claimedKind_1461_;
goto v___jp_1464_;
}
else
{
v___y_1465_ = v___y_1470_;
goto v___jp_1464_;
}
}
v___jp_1473_:
{
if (v___y_1475_ == 0)
{
uint32_t v___x_1476_;
v___x_1476_ = lean_uint8_to_uint32(v___y_1474_);
return v___x_1476_;
}
else
{
v___y_1470_ = v___y_1474_;
goto v___jp_1469_;
}
}
v___jp_1477_:
{
uint8_t v___x_1479_; uint8_t v___x_1480_;
v___x_1479_ = 0;
v___x_1480_ = lean_uint8_dec_eq(v_claimedKind_1461_, v___x_1479_);
if (v___x_1480_ == 0)
{
uint8_t v___x_1481_; uint8_t v___x_1482_;
v___x_1481_ = 5;
v___x_1482_ = lean_uint8_dec_eq(v___y_1478_, v___x_1481_);
if (v___x_1482_ == 0)
{
uint8_t v___x_1483_; uint8_t v___x_1484_;
v___x_1483_ = 1;
v___x_1484_ = lean_uint8_dec_eq(v___y_1478_, v___x_1483_);
if (v___x_1484_ == 0)
{
uint8_t v___x_1485_; uint8_t v___x_1486_;
v___x_1485_ = 2;
v___x_1486_ = lean_uint8_dec_eq(v___y_1478_, v___x_1485_);
if (v___x_1486_ == 0)
{
uint8_t v___x_1487_; uint8_t v___x_1488_;
v___x_1487_ = 3;
v___x_1488_ = lean_uint8_dec_eq(v___y_1478_, v___x_1487_);
if (v___x_1488_ == 0)
{
uint8_t v___x_1489_; uint8_t v___x_1490_;
v___x_1489_ = 4;
v___x_1490_ = lean_uint8_dec_eq(v___y_1478_, v___x_1489_);
if (v___x_1490_ == 0)
{
uint8_t v___x_1491_; uint8_t v___x_1492_;
v___x_1491_ = 6;
v___x_1492_ = lean_uint8_dec_eq(v___y_1478_, v___x_1491_);
if (v___x_1492_ == 0)
{
uint32_t v___x_1493_;
v___x_1493_ = lean_uint8_to_uint32(v___y_1478_);
return v___x_1493_;
}
else
{
uint8_t v___x_1494_;
v___x_1494_ = lean_uint8_dec_eq(v_claimedKind_1461_, v___x_1491_);
v___y_1474_ = v___y_1478_;
v___y_1475_ = v___x_1494_;
goto v___jp_1473_;
}
}
else
{
uint8_t v___x_1495_;
v___x_1495_ = lean_uint8_dec_eq(v_claimedKind_1461_, v___x_1489_);
v___y_1474_ = v___y_1478_;
v___y_1475_ = v___x_1495_;
goto v___jp_1473_;
}
}
else
{
uint8_t v___x_1496_;
v___x_1496_ = lean_uint8_dec_eq(v_claimedKind_1461_, v___x_1487_);
v___y_1474_ = v___y_1478_;
v___y_1475_ = v___x_1496_;
goto v___jp_1473_;
}
}
else
{
uint8_t v___x_1497_;
v___x_1497_ = lean_uint8_dec_eq(v_claimedKind_1461_, v___x_1483_);
if (v___x_1497_ == 0)
{
uint8_t v___x_1498_;
v___x_1498_ = lean_uint8_dec_eq(v_claimedKind_1461_, v___x_1485_);
if (v___x_1498_ == 0)
{
uint32_t v___x_1499_;
v___x_1499_ = lean_uint8_to_uint32(v___y_1478_);
return v___x_1499_;
}
else
{
uint8_t v___x_1500_;
v___x_1500_ = lean_uint8_dec_eq(v_isDescendant_1463_, v___x_1483_);
v___y_1474_ = v___y_1478_;
v___y_1475_ = v___x_1500_;
goto v___jp_1473_;
}
}
else
{
uint8_t v___x_1501_;
v___x_1501_ = lean_uint8_dec_eq(v_sameMission_1462_, v___x_1483_);
v___y_1474_ = v___y_1478_;
v___y_1475_ = v___x_1501_;
goto v___jp_1473_;
}
}
}
else
{
uint8_t v___x_1502_;
v___x_1502_ = lean_uint8_dec_eq(v_claimedKind_1461_, v___x_1483_);
if (v___x_1502_ == 0)
{
uint8_t v___x_1503_; uint8_t v___x_1504_;
v___x_1503_ = 2;
v___x_1504_ = lean_uint8_dec_eq(v_claimedKind_1461_, v___x_1503_);
if (v___x_1504_ == 0)
{
uint32_t v___x_1505_;
v___x_1505_ = lean_uint8_to_uint32(v___y_1478_);
return v___x_1505_;
}
else
{
uint8_t v___x_1506_;
v___x_1506_ = lean_uint8_dec_eq(v_isDescendant_1463_, v___x_1483_);
v___y_1474_ = v___y_1478_;
v___y_1475_ = v___x_1506_;
goto v___jp_1473_;
}
}
else
{
uint8_t v___x_1507_;
v___x_1507_ = lean_uint8_dec_eq(v_sameMission_1462_, v___x_1483_);
v___y_1474_ = v___y_1478_;
v___y_1475_ = v___x_1507_;
goto v___jp_1473_;
}
}
}
else
{
uint8_t v___x_1508_; uint8_t v___x_1509_;
v___x_1508_ = 1;
v___x_1509_ = lean_uint8_dec_eq(v_claimedKind_1461_, v___x_1508_);
if (v___x_1509_ == 0)
{
uint8_t v___x_1510_; uint8_t v___x_1511_;
v___x_1510_ = 2;
v___x_1511_ = lean_uint8_dec_eq(v_claimedKind_1461_, v___x_1510_);
if (v___x_1511_ == 0)
{
uint8_t v___x_1512_;
v___x_1512_ = lean_uint8_dec_eq(v_claimedKind_1461_, v___x_1481_);
v___y_1474_ = v___y_1478_;
v___y_1475_ = v___x_1512_;
goto v___jp_1473_;
}
else
{
v___y_1470_ = v___y_1478_;
goto v___jp_1469_;
}
}
else
{
v___y_1470_ = v___y_1478_;
goto v___jp_1469_;
}
}
}
else
{
v___y_1470_ = v___y_1478_;
goto v___jp_1469_;
}
}
}
}

LEAN_EXPORT uint8_t orb_schedule_step(uint8_t v_op_1585_, uint8_t v_known_1586_, uint8_t v_cancelled_1587_, uint8_t v_ownerTerminal_1588_, uint8_t v_authorized_1589_, uint8_t v_busy_1590_, uint64_t v_lastFired_1591_, uint64_t v_nextDue_1592_, uint64_t v_now_1593_){
_start:
{
uint8_t v___x_1594_; uint8_t v___x_1595_;
v___x_1594_ = 1;
v___x_1595_ = lean_uint8_dec_eq(v_authorized_1589_, v___x_1594_);
if (v___x_1595_ == 0)
{
uint8_t v___x_1596_;
v___x_1596_ = 0;
return v___x_1596_;
}
else
{
uint8_t v___x_1597_; uint8_t v___x_1598_;
v___x_1597_ = 0;
v___x_1598_ = lean_uint8_dec_eq(v_op_1585_, v___x_1597_);
if (v___x_1598_ == 0)
{
uint8_t v___x_1599_;
v___x_1599_ = lean_uint8_dec_eq(v_cancelled_1587_, v___x_1594_);
if (v___x_1599_ == 0)
{
uint8_t v___x_1600_;
v___x_1600_ = lean_uint8_dec_eq(v_ownerTerminal_1588_, v___x_1594_);
if (v___x_1600_ == 0)
{
uint8_t v___x_1601_;
v___x_1601_ = lean_uint64_dec_lt(v_lastFired_1591_, v_nextDue_1592_);
if (v___x_1601_ == 0)
{
uint8_t v___x_1602_;
v___x_1602_ = 4;
return v___x_1602_;
}
else
{
uint8_t v___x_1603_;
v___x_1603_ = lean_uint64_dec_le(v_nextDue_1592_, v_now_1593_);
if (v___x_1603_ == 0)
{
uint8_t v___x_1604_;
v___x_1604_ = 4;
return v___x_1604_;
}
else
{
uint8_t v___x_1605_;
v___x_1605_ = lean_uint8_dec_eq(v_busy_1590_, v___x_1594_);
if (v___x_1605_ == 0)
{
uint8_t v___x_1606_;
v___x_1606_ = 3;
return v___x_1606_;
}
else
{
uint8_t v___x_1607_;
v___x_1607_ = 4;
return v___x_1607_;
}
}
}
}
else
{
return v___x_1597_;
}
}
else
{
return v___x_1597_;
}
}
else
{
uint8_t v___x_1608_;
v___x_1608_ = lean_uint8_dec_eq(v_known_1586_, v___x_1594_);
if (v___x_1608_ == 0)
{
uint8_t v___x_1609_;
v___x_1609_ = lean_uint8_dec_eq(v_ownerTerminal_1588_, v___x_1594_);
if (v___x_1609_ == 0)
{
return v___x_1594_;
}
else
{
return v___x_1597_;
}
}
else
{
uint8_t v___x_1610_;
v___x_1610_ = 2;
return v___x_1610_;
}
}
}
}
}

LEAN_EXPORT uint64_t orb_stats_settle_step(uint64_t v_acc_1648_, uint64_t v_cost_1649_, uint8_t v_seen_1650_){
_start:
{
uint8_t v___x_1651_; uint8_t v___x_1652_;
v___x_1651_ = 1;
v___x_1652_ = lean_uint8_dec_eq(v_seen_1650_, v___x_1651_);
if (v___x_1652_ == 0)
{
uint64_t v___x_1653_; uint64_t v___x_1654_; uint8_t v___x_1655_;
v___x_1653_ = 18446744073709551615ULL;
v___x_1654_ = lean_uint64_sub(v___x_1653_, v_cost_1649_);
v___x_1655_ = lean_uint64_dec_le(v_acc_1648_, v___x_1654_);
if (v___x_1655_ == 0)
{
return v___x_1653_;
}
else
{
uint64_t v___x_1656_;
v___x_1656_ = lean_uint64_add(v_acc_1648_, v_cost_1649_);
return v___x_1656_;
}
}
else
{
return v_acc_1648_;
}
}
}

LEAN_EXPORT uint32_t orb_privilege_step(uint8_t v_sameOwner_1665_, uint8_t v_missionActive_1666_, uint8_t v_biometricSigned_1667_, uint8_t v_scopeRank_1668_, uint8_t v_maxGrantedScope_1669_, uint8_t v_bunkerState_1670_, uint8_t v_revoked_1671_, uint64_t v_nowEpoch_1672_, uint64_t v_grantExpiresAt_1673_, uint64_t v_sessionExpiresAt_1674_){
_start:
{
uint8_t v___x_1675_; uint8_t v___x_1676_;
v___x_1675_ = 0;
v___x_1676_ = lean_uint8_dec_eq(v_missionActive_1666_, v___x_1675_);
if (v___x_1676_ == 0)
{
uint8_t v___x_1677_; uint8_t v___x_1678_;
v___x_1677_ = 1;
v___x_1678_ = lean_uint8_dec_eq(v_revoked_1671_, v___x_1677_);
if (v___x_1678_ == 0)
{
uint8_t v___x_1679_;
v___x_1679_ = lean_uint8_dec_eq(v_bunkerState_1670_, v___x_1675_);
if (v___x_1679_ == 0)
{
uint32_t v___x_1680_;
v___x_1680_ = 65536;
return v___x_1680_;
}
else
{
uint8_t v___x_1681_;
v___x_1681_ = lean_uint64_dec_le(v_grantExpiresAt_1673_, v_nowEpoch_1672_);
if (v___x_1681_ == 0)
{
uint8_t v___x_1682_;
v___x_1682_ = lean_uint64_dec_le(v_sessionExpiresAt_1674_, v_nowEpoch_1672_);
if (v___x_1682_ == 0)
{
uint8_t v___x_1683_;
v___x_1683_ = lean_uint8_dec_eq(v_sameOwner_1665_, v___x_1677_);
if (v___x_1683_ == 0)
{
uint32_t v___x_1684_;
v___x_1684_ = 0;
return v___x_1684_;
}
else
{
uint8_t v___x_1685_;
v___x_1685_ = lean_uint8_dec_eq(v_biometricSigned_1667_, v___x_1677_);
if (v___x_1685_ == 0)
{
uint32_t v___x_1686_;
v___x_1686_ = 0;
return v___x_1686_;
}
else
{
uint8_t v___x_1687_;
v___x_1687_ = lean_uint8_dec_le(v_scopeRank_1668_, v_maxGrantedScope_1669_);
if (v___x_1687_ == 0)
{
uint32_t v___x_1688_;
v___x_1688_ = 0;
return v___x_1688_;
}
else
{
uint8_t v___x_1689_; uint8_t v___x_1690_;
v___x_1689_ = 2;
v___x_1690_ = lean_uint8_dec_lt(v_scopeRank_1668_, v___x_1689_);
if (v___x_1690_ == 0)
{
uint32_t v___x_1691_;
v___x_1691_ = 1;
return v___x_1691_;
}
else
{
uint32_t v___x_1692_;
v___x_1692_ = 257;
return v___x_1692_;
}
}
}
}
}
else
{
uint32_t v___x_1693_;
v___x_1693_ = 65536;
return v___x_1693_;
}
}
else
{
uint32_t v___x_1694_;
v___x_1694_ = 65536;
return v___x_1694_;
}
}
}
else
{
uint32_t v___x_1695_;
v___x_1695_ = 65536;
return v___x_1695_;
}
}
else
{
uint32_t v___x_1696_;
v___x_1696_ = 65536;
return v___x_1696_;
}
}
}

LEAN_EXPORT uint32_t orb_bunker_step(uint8_t v_currentState_1719_, uint8_t v_canaryTripped_1720_, uint8_t v_authFailureBurst_1721_, uint8_t v_manualTrigger_1722_, uint8_t v_biometricUnbunker_1723_){
_start:
{
uint8_t v___x_1724_; uint32_t v___y_1726_; uint8_t v___y_1727_; uint32_t v___y_1728_; uint8_t v___y_1734_; uint8_t v___y_1735_; uint8_t v___y_1741_; uint8_t v___x_1754_;
v___x_1724_ = 2;
v___x_1754_ = lean_uint8_dec_le(v_currentState_1719_, v___x_1724_);
if (v___x_1754_ == 0)
{
v___y_1741_ = v___x_1724_;
goto v___jp_1740_;
}
else
{
v___y_1741_ = v_currentState_1719_;
goto v___jp_1740_;
}
v___jp_1725_:
{
uint32_t v___x_1729_; uint8_t v___x_1730_;
v___x_1729_ = lean_uint32_lor(v___y_1726_, v___y_1728_);
v___x_1730_ = lean_uint8_dec_eq(v___y_1727_, v___x_1724_);
if (v___x_1730_ == 0)
{
return v___x_1729_;
}
else
{
uint32_t v___x_1731_; uint32_t v___x_1732_;
v___x_1731_ = 65536;
v___x_1732_ = lean_uint32_lor(v___x_1729_, v___x_1731_);
return v___x_1732_;
}
}
v___jp_1733_:
{
uint32_t v___x_1736_; uint8_t v___x_1737_;
v___x_1736_ = lean_uint8_to_uint32(v___y_1735_);
v___x_1737_ = lean_uint8_dec_le(v___y_1734_, v___y_1735_);
if (v___x_1737_ == 0)
{
uint32_t v___x_1738_;
v___x_1738_ = 0;
v___y_1726_ = v___x_1736_;
v___y_1727_ = v___y_1735_;
v___y_1728_ = v___x_1738_;
goto v___jp_1725_;
}
else
{
uint32_t v___x_1739_;
v___x_1739_ = 256;
v___y_1726_ = v___x_1736_;
v___y_1727_ = v___y_1735_;
v___y_1728_ = v___x_1739_;
goto v___jp_1725_;
}
}
v___jp_1740_:
{
uint8_t v___x_1742_; uint8_t v___x_1743_;
v___x_1742_ = 1;
v___x_1743_ = lean_uint8_dec_eq(v_canaryTripped_1720_, v___x_1742_);
if (v___x_1743_ == 0)
{
uint8_t v___x_1744_;
v___x_1744_ = lean_uint8_dec_eq(v_manualTrigger_1722_, v___x_1724_);
if (v___x_1744_ == 0)
{
uint8_t v___x_1745_;
v___x_1745_ = lean_uint8_dec_eq(v___y_1741_, v___x_1724_);
if (v___x_1745_ == 0)
{
uint8_t v___x_1746_;
v___x_1746_ = lean_uint8_dec_eq(v_authFailureBurst_1721_, v___x_1742_);
if (v___x_1746_ == 0)
{
uint8_t v___x_1747_;
v___x_1747_ = lean_uint8_dec_eq(v_manualTrigger_1722_, v___x_1742_);
if (v___x_1747_ == 0)
{
uint8_t v___x_1748_;
v___x_1748_ = lean_uint8_dec_eq(v___y_1741_, v___x_1742_);
if (v___x_1748_ == 0)
{
uint8_t v___x_1749_;
v___x_1749_ = 0;
v___y_1734_ = v___x_1742_;
v___y_1735_ = v___x_1749_;
goto v___jp_1733_;
}
else
{
uint8_t v___x_1750_;
v___x_1750_ = lean_uint8_dec_eq(v_biometricUnbunker_1723_, v___x_1742_);
if (v___x_1750_ == 0)
{
v___y_1734_ = v___x_1742_;
v___y_1735_ = v___x_1742_;
goto v___jp_1733_;
}
else
{
uint8_t v___x_1751_;
v___x_1751_ = 0;
v___y_1734_ = v___x_1742_;
v___y_1735_ = v___x_1751_;
goto v___jp_1733_;
}
}
}
else
{
v___y_1734_ = v___x_1742_;
v___y_1735_ = v___x_1742_;
goto v___jp_1733_;
}
}
else
{
v___y_1734_ = v___x_1742_;
v___y_1735_ = v___x_1742_;
goto v___jp_1733_;
}
}
else
{
uint8_t v___x_1752_;
v___x_1752_ = lean_uint8_dec_eq(v_biometricUnbunker_1723_, v___x_1742_);
if (v___x_1752_ == 0)
{
v___y_1734_ = v___x_1742_;
v___y_1735_ = v___x_1724_;
goto v___jp_1733_;
}
else
{
uint8_t v___x_1753_;
v___x_1753_ = 0;
v___y_1734_ = v___x_1742_;
v___y_1735_ = v___x_1753_;
goto v___jp_1733_;
}
}
}
else
{
v___y_1734_ = v___x_1742_;
v___y_1735_ = v___x_1724_;
goto v___jp_1733_;
}
}
else
{
v___y_1734_ = v___x_1742_;
v___y_1735_ = v___x_1724_;
goto v___jp_1733_;
}
}
}
}

LEAN_EXPORT uint8_t orb_deploy_gate_step(uint8_t v_isProdService_1767_, uint8_t v_serviceMatches_1768_, uint8_t v_callingOnSelf_1769_, uint8_t v_debounceOk_1770_, uint8_t v_forceFlag_1771_, uint8_t v_biometricApproved_1772_, uint8_t v_bunkerState_1773_, uint32_t v_liveWriters_1774_){
_start:
{
uint8_t v___x_1775_; uint8_t v___y_1777_; uint8_t v___x_1786_;
v___x_1775_ = 1;
v___x_1786_ = lean_uint8_dec_eq(v_serviceMatches_1768_, v___x_1775_);
if (v___x_1786_ == 0)
{
v___y_1777_ = v___x_1786_;
goto v___jp_1776_;
}
else
{
uint8_t v___x_1787_; uint8_t v___x_1788_;
v___x_1787_ = 0;
v___x_1788_ = lean_uint8_dec_eq(v_callingOnSelf_1769_, v___x_1787_);
if (v___x_1788_ == 0)
{
v___y_1777_ = v___x_1788_;
goto v___jp_1776_;
}
else
{
uint8_t v___x_1789_;
v___x_1789_ = lean_uint8_dec_eq(v_debounceOk_1770_, v___x_1775_);
if (v___x_1789_ == 0)
{
v___y_1777_ = v___x_1789_;
goto v___jp_1776_;
}
else
{
uint32_t v___x_1790_; uint8_t v___x_1791_;
v___x_1790_ = 0;
v___x_1791_ = lean_uint32_dec_eq(v_liveWriters_1774_, v___x_1790_);
if (v___x_1791_ == 0)
{
uint8_t v___x_1792_;
v___x_1792_ = lean_uint8_dec_eq(v_forceFlag_1771_, v___x_1775_);
if (v___x_1792_ == 0)
{
v___y_1777_ = v___x_1792_;
goto v___jp_1776_;
}
else
{
goto v___jp_1783_;
}
}
else
{
goto v___jp_1783_;
}
}
}
}
v___jp_1776_:
{
uint8_t v___x_1778_;
v___x_1778_ = lean_uint8_dec_eq(v_isProdService_1767_, v___x_1775_);
if (v___x_1778_ == 0)
{
if (v___y_1777_ == 0)
{
uint8_t v___x_1779_;
v___x_1779_ = 0;
return v___x_1779_;
}
else
{
return v___x_1775_;
}
}
else
{
if (v___y_1777_ == 0)
{
uint8_t v___x_1780_;
v___x_1780_ = 0;
return v___x_1780_;
}
else
{
uint8_t v___x_1781_;
v___x_1781_ = lean_uint8_dec_eq(v_biometricApproved_1772_, v___x_1775_);
if (v___x_1781_ == 0)
{
uint8_t v___x_1782_;
v___x_1782_ = 0;
return v___x_1782_;
}
else
{
return v___x_1775_;
}
}
}
}
v___jp_1783_:
{
uint8_t v___x_1784_; uint8_t v___x_1785_;
v___x_1784_ = 0;
v___x_1785_ = lean_uint8_dec_eq(v_bunkerState_1773_, v___x_1784_);
v___y_1777_ = v___x_1785_;
goto v___jp_1776_;
}
}
}

LEAN_EXPORT uint64_t orb_scroll_max_top(uint64_t v_content_1811_, uint64_t v_viewport_1812_){
_start:
{
uint8_t v___x_1813_;
v___x_1813_ = lean_uint64_dec_le(v_viewport_1812_, v_content_1811_);
if (v___x_1813_ == 0)
{
uint64_t v___x_1814_;
v___x_1814_ = 0ULL;
return v___x_1814_;
}
else
{
uint64_t v___x_1815_;
v___x_1815_ = lean_uint64_sub(v_content_1811_, v_viewport_1812_);
return v___x_1815_;
}
}
}

LEAN_EXPORT uint64_t orb_scroll_clamp_top(uint64_t v_content_1822_, uint64_t v_viewport_1823_, uint64_t v_top_1824_){
_start:
{
uint64_t v___y_1826_; uint8_t v___x_1828_;
v___x_1828_ = lean_uint64_dec_le(v_viewport_1823_, v_content_1822_);
if (v___x_1828_ == 0)
{
uint64_t v___x_1829_;
v___x_1829_ = 0ULL;
v___y_1826_ = v___x_1829_;
goto v___jp_1825_;
}
else
{
uint64_t v___x_1830_;
v___x_1830_ = lean_uint64_sub(v_content_1822_, v_viewport_1823_);
v___y_1826_ = v___x_1830_;
goto v___jp_1825_;
}
v___jp_1825_:
{
uint8_t v___x_1827_;
v___x_1827_ = lean_uint64_dec_le(v_top_1824_, v___y_1826_);
if (v___x_1827_ == 0)
{
return v___y_1826_;
}
else
{
return v_top_1824_;
}
}
}
}

LEAN_EXPORT uint64_t orb_scroll_gap(uint64_t v_content_1839_, uint64_t v_viewport_1840_, uint64_t v_top_1841_){
_start:
{
uint64_t v___y_1843_; uint64_t v___y_1844_; uint64_t v___y_1849_; uint64_t v___y_1850_; uint64_t v___y_1853_; uint8_t v___x_1857_;
v___x_1857_ = lean_uint64_dec_le(v_viewport_1840_, v_content_1839_);
if (v___x_1857_ == 0)
{
uint64_t v___x_1858_;
v___x_1858_ = 0ULL;
v___y_1853_ = v___x_1858_;
goto v___jp_1852_;
}
else
{
uint64_t v___x_1859_;
v___x_1859_ = lean_uint64_sub(v_content_1839_, v_viewport_1840_);
v___y_1853_ = v___x_1859_;
goto v___jp_1852_;
}
v___jp_1842_:
{
uint8_t v___x_1845_;
v___x_1845_ = lean_uint64_dec_le(v___y_1844_, v___y_1843_);
if (v___x_1845_ == 0)
{
uint64_t v___x_1846_;
v___x_1846_ = 0ULL;
return v___x_1846_;
}
else
{
uint64_t v___x_1847_;
v___x_1847_ = lean_uint64_sub(v___y_1843_, v___y_1844_);
return v___x_1847_;
}
}
v___jp_1848_:
{
uint8_t v___x_1851_;
v___x_1851_ = lean_uint64_dec_le(v_top_1841_, v___y_1850_);
if (v___x_1851_ == 0)
{
v___y_1843_ = v___y_1849_;
v___y_1844_ = v___y_1850_;
goto v___jp_1842_;
}
else
{
v___y_1843_ = v___y_1849_;
v___y_1844_ = v_top_1841_;
goto v___jp_1842_;
}
}
v___jp_1852_:
{
uint8_t v___x_1854_;
v___x_1854_ = lean_uint64_dec_le(v_viewport_1840_, v_content_1839_);
if (v___x_1854_ == 0)
{
uint64_t v___x_1855_;
v___x_1855_ = 0ULL;
v___y_1849_ = v___y_1853_;
v___y_1850_ = v___x_1855_;
goto v___jp_1848_;
}
else
{
uint64_t v___x_1856_;
v___x_1856_ = lean_uint64_sub(v_content_1839_, v_viewport_1840_);
v___y_1849_ = v___y_1853_;
v___y_1850_ = v___x_1856_;
goto v___jp_1848_;
}
}
}
}

LEAN_EXPORT uint64_t orb_scroll_layout_step(uint8_t v_pinned_1868_, uint64_t v_content_1869_, uint64_t v_viewport_1870_, uint64_t v_top_1871_){
_start:
{
uint64_t v___y_1873_; uint8_t v___x_1875_; uint8_t v___x_1876_;
v___x_1875_ = 1;
v___x_1876_ = lean_uint8_dec_eq(v_pinned_1868_, v___x_1875_);
if (v___x_1876_ == 0)
{
uint8_t v___x_1877_;
v___x_1877_ = lean_uint64_dec_le(v_viewport_1870_, v_content_1869_);
if (v___x_1877_ == 0)
{
uint64_t v___x_1878_;
v___x_1878_ = 0ULL;
v___y_1873_ = v___x_1878_;
goto v___jp_1872_;
}
else
{
uint64_t v___x_1879_;
v___x_1879_ = lean_uint64_sub(v_content_1869_, v_viewport_1870_);
v___y_1873_ = v___x_1879_;
goto v___jp_1872_;
}
}
else
{
uint8_t v___x_1880_;
v___x_1880_ = lean_uint64_dec_le(v_viewport_1870_, v_content_1869_);
if (v___x_1880_ == 0)
{
uint64_t v___x_1881_;
v___x_1881_ = 0ULL;
return v___x_1881_;
}
else
{
uint64_t v___x_1882_;
v___x_1882_ = lean_uint64_sub(v_content_1869_, v_viewport_1870_);
return v___x_1882_;
}
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

LEAN_EXPORT uint8_t orb_scroll_user_step(uint64_t v_content_1893_, uint64_t v_viewport_1894_, uint64_t v_top_1895_, uint64_t v_threshold_1896_){
_start:
{
uint64_t v___y_1898_; uint64_t v___y_1903_; uint64_t v___y_1904_; uint64_t v___y_1909_; uint64_t v___y_1910_; uint64_t v___y_1913_; uint8_t v___x_1917_;
v___x_1917_ = lean_uint64_dec_le(v_viewport_1894_, v_content_1893_);
if (v___x_1917_ == 0)
{
uint64_t v___x_1918_;
v___x_1918_ = 0ULL;
v___y_1913_ = v___x_1918_;
goto v___jp_1912_;
}
else
{
uint64_t v___x_1919_;
v___x_1919_ = lean_uint64_sub(v_content_1893_, v_viewport_1894_);
v___y_1913_ = v___x_1919_;
goto v___jp_1912_;
}
v___jp_1897_:
{
uint8_t v___x_1899_;
v___x_1899_ = lean_uint64_dec_le(v___y_1898_, v_threshold_1896_);
if (v___x_1899_ == 0)
{
uint8_t v___x_1900_;
v___x_1900_ = 0;
return v___x_1900_;
}
else
{
uint8_t v___x_1901_;
v___x_1901_ = 1;
return v___x_1901_;
}
}
v___jp_1902_:
{
uint8_t v___x_1905_;
v___x_1905_ = lean_uint64_dec_le(v___y_1904_, v___y_1903_);
if (v___x_1905_ == 0)
{
uint64_t v___x_1906_;
v___x_1906_ = 0ULL;
v___y_1898_ = v___x_1906_;
goto v___jp_1897_;
}
else
{
uint64_t v___x_1907_;
v___x_1907_ = lean_uint64_sub(v___y_1903_, v___y_1904_);
v___y_1898_ = v___x_1907_;
goto v___jp_1897_;
}
}
v___jp_1908_:
{
uint8_t v___x_1911_;
v___x_1911_ = lean_uint64_dec_le(v_top_1895_, v___y_1910_);
if (v___x_1911_ == 0)
{
v___y_1903_ = v___y_1909_;
v___y_1904_ = v___y_1910_;
goto v___jp_1902_;
}
else
{
v___y_1903_ = v___y_1909_;
v___y_1904_ = v_top_1895_;
goto v___jp_1902_;
}
}
v___jp_1912_:
{
uint8_t v___x_1914_;
v___x_1914_ = lean_uint64_dec_le(v_viewport_1894_, v_content_1893_);
if (v___x_1914_ == 0)
{
uint64_t v___x_1915_;
v___x_1915_ = 0ULL;
v___y_1909_ = v___y_1913_;
v___y_1910_ = v___x_1915_;
goto v___jp_1908_;
}
else
{
uint64_t v___x_1916_;
v___x_1916_ = lean_uint64_sub(v_content_1893_, v_viewport_1894_);
v___y_1909_ = v___y_1913_;
v___y_1910_ = v___x_1916_;
goto v___jp_1908_;
}
}
}
}

LEAN_EXPORT uint64_t orb_scroll_jump_step(uint64_t v_content_1930_, uint64_t v_viewport_1931_){
_start:
{
uint8_t v___x_1932_;
v___x_1932_ = lean_uint64_dec_le(v_viewport_1931_, v_content_1930_);
if (v___x_1932_ == 0)
{
uint64_t v___x_1933_;
v___x_1933_ = 0ULL;
return v___x_1933_;
}
else
{
uint64_t v___x_1934_;
v___x_1934_ = lean_uint64_sub(v_content_1930_, v_viewport_1931_);
return v___x_1934_;
}
}
}

LEAN_EXPORT uint64_t orb_scroll_correct(uint8_t v_pinned_1941_, uint64_t v_content_1942_, uint64_t v_viewport_1943_, uint64_t v_top_1944_){
_start:
{
uint64_t v___y_1946_; uint8_t v___x_1948_; uint8_t v___x_1949_;
v___x_1948_ = 1;
v___x_1949_ = lean_uint8_dec_eq(v_pinned_1941_, v___x_1948_);
if (v___x_1949_ == 0)
{
uint8_t v___x_1950_;
v___x_1950_ = lean_uint64_dec_le(v_viewport_1943_, v_content_1942_);
if (v___x_1950_ == 0)
{
uint64_t v___x_1951_;
v___x_1951_ = 0ULL;
v___y_1946_ = v___x_1951_;
goto v___jp_1945_;
}
else
{
uint64_t v___x_1952_;
v___x_1952_ = lean_uint64_sub(v_content_1942_, v_viewport_1943_);
v___y_1946_ = v___x_1952_;
goto v___jp_1945_;
}
}
else
{
uint8_t v___x_1953_;
v___x_1953_ = lean_uint64_dec_le(v_viewport_1943_, v_content_1942_);
if (v___x_1953_ == 0)
{
uint64_t v___x_1954_;
v___x_1954_ = 0ULL;
return v___x_1954_;
}
else
{
uint64_t v___x_1955_;
v___x_1955_ = lean_uint64_sub(v_content_1942_, v_viewport_1943_);
return v___x_1955_;
}
}
v___jp_1945_:
{
uint8_t v___x_1947_;
v___x_1947_ = lean_uint64_dec_le(v_top_1944_, v___y_1946_);
if (v___x_1947_ == 0)
{
return v___y_1946_;
}
else
{
return v_top_1944_;
}
}
}
}

LEAN_EXPORT uint8_t orb_scroll_shows_jump(uint8_t v_pinned_1966_, uint64_t v_content_1967_, uint64_t v_viewport_1968_, uint64_t v_top_1969_, uint64_t v_pillThreshold_1970_){
_start:
{
uint8_t v___x_1971_; uint64_t v___y_1973_; uint64_t v___y_1977_; uint64_t v___y_1978_; uint64_t v___y_1983_; uint64_t v___y_1984_; uint64_t v___y_1987_; uint8_t v___x_1991_;
v___x_1971_ = 0;
v___x_1991_ = lean_uint8_dec_eq(v_pinned_1966_, v___x_1971_);
if (v___x_1991_ == 0)
{
return v___x_1971_;
}
else
{
uint64_t v___x_1992_; uint8_t v___x_1993_;
v___x_1992_ = 18446744073709551591ULL;
v___x_1993_ = lean_uint64_dec_le(v_viewport_1968_, v___x_1992_);
if (v___x_1993_ == 0)
{
return v___x_1971_;
}
else
{
uint64_t v___x_1994_; uint64_t v___x_1995_; uint8_t v___x_1996_;
v___x_1994_ = 24ULL;
v___x_1995_ = lean_uint64_add(v_viewport_1968_, v___x_1994_);
v___x_1996_ = lean_uint64_dec_lt(v___x_1995_, v_content_1967_);
if (v___x_1996_ == 0)
{
return v___x_1971_;
}
else
{
uint8_t v___x_1997_;
v___x_1997_ = lean_uint64_dec_le(v_viewport_1968_, v_content_1967_);
if (v___x_1997_ == 0)
{
uint64_t v___x_1998_;
v___x_1998_ = 0ULL;
v___y_1987_ = v___x_1998_;
goto v___jp_1986_;
}
else
{
uint64_t v___x_1999_;
v___x_1999_ = lean_uint64_sub(v_content_1967_, v_viewport_1968_);
v___y_1987_ = v___x_1999_;
goto v___jp_1986_;
}
}
}
}
v___jp_1972_:
{
uint8_t v___x_1974_;
v___x_1974_ = lean_uint64_dec_lt(v_pillThreshold_1970_, v___y_1973_);
if (v___x_1974_ == 0)
{
return v___x_1971_;
}
else
{
uint8_t v___x_1975_;
v___x_1975_ = 1;
return v___x_1975_;
}
}
v___jp_1976_:
{
uint8_t v___x_1979_;
v___x_1979_ = lean_uint64_dec_le(v___y_1978_, v___y_1977_);
if (v___x_1979_ == 0)
{
uint64_t v___x_1980_;
v___x_1980_ = 0ULL;
v___y_1973_ = v___x_1980_;
goto v___jp_1972_;
}
else
{
uint64_t v___x_1981_;
v___x_1981_ = lean_uint64_sub(v___y_1977_, v___y_1978_);
v___y_1973_ = v___x_1981_;
goto v___jp_1972_;
}
}
v___jp_1982_:
{
uint8_t v___x_1985_;
v___x_1985_ = lean_uint64_dec_le(v_top_1969_, v___y_1984_);
if (v___x_1985_ == 0)
{
v___y_1977_ = v___y_1983_;
v___y_1978_ = v___y_1984_;
goto v___jp_1976_;
}
else
{
v___y_1977_ = v___y_1983_;
v___y_1978_ = v_top_1969_;
goto v___jp_1976_;
}
}
v___jp_1986_:
{
uint8_t v___x_1988_;
v___x_1988_ = lean_uint64_dec_le(v_viewport_1968_, v_content_1967_);
if (v___x_1988_ == 0)
{
uint64_t v___x_1989_;
v___x_1989_ = 0ULL;
v___y_1983_ = v___y_1987_;
v___y_1984_ = v___x_1989_;
goto v___jp_1982_;
}
else
{
uint64_t v___x_1990_;
v___x_1990_ = lean_uint64_sub(v_content_1967_, v_viewport_1968_);
v___y_1983_ = v___y_1987_;
v___y_1984_ = v___x_1990_;
goto v___jp_1982_;
}
}
}
}

LEAN_EXPORT uint64_t orb_stream_coalescer_step(uint8_t v_op_2012_, uint32_t v_shownLen_2013_, uint32_t v_pendingLen_2014_, uint32_t v_deltaLen_2015_){
_start:
{
uint32_t v___y_2017_; uint32_t v___y_2022_; uint8_t v___x_2030_; uint8_t v___x_2031_;
v___x_2030_ = 0;
v___x_2031_ = lean_uint8_dec_eq(v_op_2012_, v___x_2030_);
if (v___x_2031_ == 0)
{
uint8_t v___x_2032_; uint8_t v___x_2033_;
v___x_2032_ = 1;
v___x_2033_ = lean_uint8_dec_eq(v_op_2012_, v___x_2032_);
if (v___x_2033_ == 0)
{
uint64_t v___x_2034_;
v___x_2034_ = 0ULL;
return v___x_2034_;
}
else
{
uint32_t v___x_2035_; uint8_t v___x_2036_;
v___x_2035_ = 0;
v___x_2036_ = lean_uint32_dec_eq(v_pendingLen_2014_, v___x_2035_);
if (v___x_2036_ == 0)
{
uint32_t v___x_2037_; uint32_t v___x_2038_; uint8_t v___x_2039_;
v___x_2037_ = 4294967295;
v___x_2038_ = lean_uint32_sub(v___x_2037_, v_pendingLen_2014_);
v___x_2039_ = lean_uint32_dec_le(v_shownLen_2013_, v___x_2038_);
if (v___x_2039_ == 0)
{
v___y_2017_ = v___x_2037_;
goto v___jp_2016_;
}
else
{
uint32_t v___x_2040_;
v___x_2040_ = lean_uint32_add(v_shownLen_2013_, v_pendingLen_2014_);
v___y_2017_ = v___x_2040_;
goto v___jp_2016_;
}
}
else
{
uint64_t v___x_2041_;
v___x_2041_ = lean_uint32_to_uint64(v_shownLen_2013_);
return v___x_2041_;
}
}
}
else
{
uint32_t v___x_2042_; uint32_t v___x_2043_; uint8_t v___x_2044_;
v___x_2042_ = 4294967295;
v___x_2043_ = lean_uint32_sub(v___x_2042_, v_deltaLen_2015_);
v___x_2044_ = lean_uint32_dec_le(v_pendingLen_2014_, v___x_2043_);
if (v___x_2044_ == 0)
{
v___y_2022_ = v___x_2042_;
goto v___jp_2021_;
}
else
{
uint32_t v___x_2045_;
v___x_2045_ = lean_uint32_add(v_pendingLen_2014_, v_deltaLen_2015_);
v___y_2022_ = v___x_2045_;
goto v___jp_2021_;
}
}
v___jp_2016_:
{
uint64_t v___x_2018_; uint64_t v___x_2019_; uint64_t v___x_2020_;
v___x_2018_ = lean_uint32_to_uint64(v___y_2017_);
v___x_2019_ = 9223372036854775808ULL;
v___x_2020_ = lean_uint64_lor(v___x_2018_, v___x_2019_);
return v___x_2020_;
}
v___jp_2021_:
{
uint64_t v___x_2023_; uint64_t v___x_2024_; uint64_t v___x_2025_; uint64_t v___x_2026_; uint64_t v___x_2027_; uint64_t v___x_2028_; uint64_t v___x_2029_;
v___x_2023_ = lean_uint32_to_uint64(v_shownLen_2013_);
v___x_2024_ = lean_uint32_to_uint64(v___y_2022_);
v___x_2025_ = 2147483647ULL;
v___x_2026_ = lean_uint64_land(v___x_2024_, v___x_2025_);
v___x_2027_ = 32ULL;
v___x_2028_ = lean_uint64_shift_left(v___x_2026_, v___x_2027_);
v___x_2029_ = lean_uint64_lor(v___x_2023_, v___x_2028_);
return v___x_2029_;
}
}
}

LEAN_EXPORT uint64_t orb_stream_fence_step(uint8_t v_openKind_2113_, uint32_t v_openCount_2114_, uint8_t v_markerKind_2115_, uint32_t v_markerCount_2116_){
_start:
{
uint8_t v___y_2118_; uint32_t v___y_2119_; uint8_t v___y_2126_; uint8_t v___y_2131_; uint8_t v___x_2144_; uint8_t v___x_2148_;
v___x_2144_ = 0;
v___x_2148_ = lean_uint8_dec_eq(v_openKind_2113_, v___x_2144_);
if (v___x_2148_ == 0)
{
uint8_t v___x_2149_;
v___x_2149_ = lean_uint8_dec_eq(v_markerKind_2115_, v_openKind_2113_);
if (v___x_2149_ == 0)
{
v___y_2131_ = v_openKind_2113_;
goto v___jp_2130_;
}
else
{
uint8_t v___x_2150_;
v___x_2150_ = lean_uint32_dec_le(v_openCount_2114_, v_markerCount_2116_);
if (v___x_2150_ == 0)
{
v___y_2131_ = v_openKind_2113_;
goto v___jp_2130_;
}
else
{
uint32_t v___x_2151_; uint8_t v___x_2152_;
v___x_2151_ = 3;
v___x_2152_ = lean_uint32_dec_le(v___x_2151_, v_markerCount_2116_);
if (v___x_2152_ == 0)
{
v___y_2131_ = v_openKind_2113_;
goto v___jp_2130_;
}
else
{
v___y_2131_ = v___x_2144_;
goto v___jp_2130_;
}
}
}
}
else
{
uint8_t v___x_2153_; uint8_t v___x_2154_;
v___x_2153_ = 1;
v___x_2154_ = lean_uint8_dec_eq(v_markerKind_2115_, v___x_2153_);
if (v___x_2154_ == 0)
{
uint8_t v___x_2155_; uint8_t v___x_2156_;
v___x_2155_ = 2;
v___x_2156_ = lean_uint8_dec_eq(v_markerKind_2115_, v___x_2155_);
if (v___x_2156_ == 0)
{
v___y_2131_ = v___x_2144_;
goto v___jp_2130_;
}
else
{
goto v___jp_2145_;
}
}
else
{
goto v___jp_2145_;
}
}
v___jp_2117_:
{
uint64_t v___x_2120_; uint64_t v___x_2121_; uint64_t v___x_2122_; uint64_t v___x_2123_; uint64_t v___x_2124_;
v___x_2120_ = lean_uint8_to_uint64(v___y_2118_);
v___x_2121_ = lean_uint32_to_uint64(v___y_2119_);
v___x_2122_ = 32ULL;
v___x_2123_ = lean_uint64_shift_left(v___x_2121_, v___x_2122_);
v___x_2124_ = lean_uint64_lor(v___x_2120_, v___x_2123_);
return v___x_2124_;
}
v___jp_2125_:
{
uint32_t v___x_2127_; uint8_t v___x_2128_;
v___x_2127_ = 3;
v___x_2128_ = lean_uint32_dec_le(v___x_2127_, v_markerCount_2116_);
if (v___x_2128_ == 0)
{
uint32_t v___x_2129_;
v___x_2129_ = 0;
v___y_2118_ = v___y_2126_;
v___y_2119_ = v___x_2129_;
goto v___jp_2117_;
}
else
{
v___y_2118_ = v___y_2126_;
v___y_2119_ = v_markerCount_2116_;
goto v___jp_2117_;
}
}
v___jp_2130_:
{
uint8_t v___x_2132_; uint8_t v___x_2133_;
v___x_2132_ = 0;
v___x_2133_ = lean_uint8_dec_eq(v_openKind_2113_, v___x_2132_);
if (v___x_2133_ == 0)
{
uint8_t v___x_2134_;
v___x_2134_ = lean_uint8_dec_eq(v_markerKind_2115_, v_openKind_2113_);
if (v___x_2134_ == 0)
{
v___y_2118_ = v___y_2131_;
v___y_2119_ = v_openCount_2114_;
goto v___jp_2117_;
}
else
{
uint8_t v___x_2135_;
v___x_2135_ = lean_uint32_dec_le(v_openCount_2114_, v_markerCount_2116_);
if (v___x_2135_ == 0)
{
v___y_2118_ = v___y_2131_;
v___y_2119_ = v_openCount_2114_;
goto v___jp_2117_;
}
else
{
uint32_t v___x_2136_; uint8_t v___x_2137_;
v___x_2136_ = 3;
v___x_2137_ = lean_uint32_dec_le(v___x_2136_, v_markerCount_2116_);
if (v___x_2137_ == 0)
{
v___y_2118_ = v___y_2131_;
v___y_2119_ = v_openCount_2114_;
goto v___jp_2117_;
}
else
{
uint32_t v___x_2138_;
v___x_2138_ = 0;
v___y_2118_ = v___y_2131_;
v___y_2119_ = v___x_2138_;
goto v___jp_2117_;
}
}
}
}
else
{
uint8_t v___x_2139_; uint8_t v___x_2140_;
v___x_2139_ = 1;
v___x_2140_ = lean_uint8_dec_eq(v_markerKind_2115_, v___x_2139_);
if (v___x_2140_ == 0)
{
uint8_t v___x_2141_; uint8_t v___x_2142_;
v___x_2141_ = 2;
v___x_2142_ = lean_uint8_dec_eq(v_markerKind_2115_, v___x_2141_);
if (v___x_2142_ == 0)
{
uint32_t v___x_2143_;
v___x_2143_ = 0;
v___y_2118_ = v___y_2131_;
v___y_2119_ = v___x_2143_;
goto v___jp_2117_;
}
else
{
v___y_2126_ = v___y_2131_;
goto v___jp_2125_;
}
}
else
{
v___y_2126_ = v___y_2131_;
goto v___jp_2125_;
}
}
}
v___jp_2145_:
{
uint32_t v___x_2146_; uint8_t v___x_2147_;
v___x_2146_ = 3;
v___x_2147_ = lean_uint32_dec_le(v___x_2146_, v_markerCount_2116_);
if (v___x_2147_ == 0)
{
v___y_2131_ = v___x_2144_;
goto v___jp_2130_;
}
else
{
v___y_2131_ = v_markerKind_2115_;
goto v___jp_2130_;
}
}
}
}

LEAN_EXPORT uint64_t orb_stream_commit_step(uint8_t v_tick_2167_, uint8_t v_openKind_2168_, uint32_t v_openCount_2169_, uint8_t v_lineBlank_2170_, uint8_t v_lineTick_2171_, uint8_t v_markerKind_2172_, uint32_t v_markerCount_2173_, uint32_t v_pos_2174_, uint32_t v_commit_2175_){
_start:
{
uint32_t v___y_2177_; uint8_t v___y_2178_; uint32_t v___y_2179_; uint32_t v___y_2180_; uint32_t v___y_2190_; uint8_t v___y_2191_; uint8_t v___y_2192_; uint32_t v___y_2193_; uint8_t v___x_2196_; uint8_t v___y_2198_; uint8_t v___y_2199_; uint8_t v___y_2200_; uint32_t v___y_2201_; uint8_t v___y_2209_; uint32_t v___y_2210_; uint8_t v___y_2211_; uint8_t v___y_2212_; uint8_t v___y_2215_; uint32_t v___y_2216_; uint8_t v___y_2217_; uint8_t v___y_2220_; uint8_t v___y_2221_; uint32_t v___y_2222_; uint8_t v___y_2228_; uint8_t v___y_2229_; uint8_t v___y_2236_; uint8_t v___y_2237_; uint8_t v___y_2241_; uint8_t v___x_2251_;
v___x_2196_ = 1;
v___x_2251_ = lean_uint8_dec_eq(v_lineTick_2171_, v___x_2196_);
if (v___x_2251_ == 0)
{
uint8_t v___x_2252_;
v___x_2252_ = lean_uint8_dec_eq(v_tick_2167_, v___x_2196_);
if (v___x_2252_ == 0)
{
uint8_t v___x_2253_;
v___x_2253_ = 0;
v___y_2241_ = v___x_2253_;
goto v___jp_2240_;
}
else
{
v___y_2241_ = v___x_2196_;
goto v___jp_2240_;
}
}
else
{
uint8_t v___x_2254_;
v___x_2254_ = lean_uint8_dec_eq(v_tick_2167_, v___x_2196_);
if (v___x_2254_ == 0)
{
v___y_2241_ = v___x_2196_;
goto v___jp_2240_;
}
else
{
uint8_t v___x_2255_;
v___x_2255_ = 0;
v___y_2241_ = v___x_2255_;
goto v___jp_2240_;
}
}
v___jp_2176_:
{
uint32_t v___x_2181_; uint32_t v___x_2182_; uint32_t v_lo32_2183_; uint64_t v___x_2184_; uint64_t v___x_2185_; uint64_t v___x_2186_; uint64_t v___x_2187_; uint64_t v___x_2188_;
v___x_2181_ = lean_uint8_to_uint32(v___y_2178_);
v___x_2182_ = lean_uint32_lor(v___x_2181_, v___y_2179_);
v_lo32_2183_ = lean_uint32_lor(v___x_2182_, v___y_2180_);
v___x_2184_ = lean_uint32_to_uint64(v_lo32_2183_);
v___x_2185_ = lean_uint32_to_uint64(v___y_2177_);
v___x_2186_ = 32ULL;
v___x_2187_ = lean_uint64_shift_left(v___x_2185_, v___x_2186_);
v___x_2188_ = lean_uint64_lor(v___x_2184_, v___x_2187_);
return v___x_2188_;
}
v___jp_2189_:
{
if (v___y_2191_ == 0)
{
uint32_t v___x_2194_;
v___x_2194_ = 0;
v___y_2177_ = v___y_2190_;
v___y_2178_ = v___y_2192_;
v___y_2179_ = v___y_2193_;
v___y_2180_ = v___x_2194_;
goto v___jp_2176_;
}
else
{
uint32_t v___x_2195_;
v___x_2195_ = 65536;
v___y_2177_ = v___y_2190_;
v___y_2178_ = v___y_2192_;
v___y_2179_ = v___y_2193_;
v___y_2180_ = v___x_2195_;
goto v___jp_2176_;
}
}
v___jp_2197_:
{
uint8_t v___x_2202_;
v___x_2202_ = lean_uint8_dec_eq(v___y_2200_, v___x_2196_);
if (v___x_2202_ == 0)
{
uint8_t v___x_2203_; uint8_t v___x_2204_;
v___x_2203_ = 2;
v___x_2204_ = lean_uint8_dec_eq(v___y_2200_, v___x_2203_);
if (v___x_2204_ == 0)
{
uint32_t v___x_2205_;
v___x_2205_ = 0;
v___y_2190_ = v___y_2201_;
v___y_2191_ = v___y_2199_;
v___y_2192_ = v___y_2198_;
v___y_2193_ = v___x_2205_;
goto v___jp_2189_;
}
else
{
uint32_t v___x_2206_;
v___x_2206_ = 512;
v___y_2190_ = v___y_2201_;
v___y_2191_ = v___y_2199_;
v___y_2192_ = v___y_2198_;
v___y_2193_ = v___x_2206_;
goto v___jp_2189_;
}
}
else
{
uint32_t v___x_2207_;
v___x_2207_ = 256;
v___y_2190_ = v___y_2201_;
v___y_2191_ = v___y_2199_;
v___y_2192_ = v___y_2198_;
v___y_2193_ = v___x_2207_;
goto v___jp_2189_;
}
}
v___jp_2208_:
{
uint8_t v___x_2213_;
v___x_2213_ = lean_uint8_dec_eq(v___y_2212_, v___x_2196_);
if (v___x_2213_ == 0)
{
v___y_2198_ = v___y_2209_;
v___y_2199_ = v___x_2213_;
v___y_2200_ = v___y_2211_;
v___y_2201_ = v_commit_2175_;
goto v___jp_2197_;
}
else
{
v___y_2198_ = v___y_2209_;
v___y_2199_ = v___x_2213_;
v___y_2200_ = v___y_2211_;
v___y_2201_ = v___y_2210_;
goto v___jp_2197_;
}
}
v___jp_2214_:
{
uint8_t v___x_2218_;
v___x_2218_ = 0;
v___y_2209_ = v___y_2215_;
v___y_2210_ = v___y_2216_;
v___y_2211_ = v___y_2217_;
v___y_2212_ = v___x_2218_;
goto v___jp_2208_;
}
v___jp_2219_:
{
uint8_t v___x_2223_;
v___x_2223_ = lean_uint8_dec_eq(v_lineBlank_2170_, v___x_2196_);
if (v___x_2223_ == 0)
{
v___y_2215_ = v___y_2220_;
v___y_2216_ = v___y_2222_;
v___y_2217_ = v___y_2221_;
goto v___jp_2214_;
}
else
{
uint8_t v___x_2224_; uint8_t v___x_2225_;
v___x_2224_ = 0;
v___x_2225_ = lean_uint8_dec_eq(v___y_2220_, v___x_2224_);
if (v___x_2225_ == 0)
{
v___y_2215_ = v___y_2220_;
v___y_2216_ = v___y_2222_;
v___y_2217_ = v___y_2221_;
goto v___jp_2214_;
}
else
{
uint8_t v___x_2226_;
v___x_2226_ = lean_uint8_dec_eq(v___y_2221_, v___x_2224_);
if (v___x_2226_ == 0)
{
v___y_2215_ = v___y_2220_;
v___y_2216_ = v___y_2222_;
v___y_2217_ = v___y_2221_;
goto v___jp_2214_;
}
else
{
v___y_2209_ = v___y_2220_;
v___y_2210_ = v___y_2222_;
v___y_2211_ = v___y_2221_;
v___y_2212_ = v___x_2196_;
goto v___jp_2208_;
}
}
}
}
v___jp_2227_:
{
uint32_t v___x_2230_; uint8_t v___x_2231_;
v___x_2230_ = 4294967294;
v___x_2231_ = lean_uint32_dec_le(v_pos_2174_, v___x_2230_);
if (v___x_2231_ == 0)
{
uint32_t v___x_2232_;
v___x_2232_ = 4294967295;
v___y_2220_ = v___y_2228_;
v___y_2221_ = v___y_2229_;
v___y_2222_ = v___x_2232_;
goto v___jp_2219_;
}
else
{
uint32_t v___x_2233_; uint32_t v___x_2234_;
v___x_2233_ = 1;
v___x_2234_ = lean_uint32_add(v_pos_2174_, v___x_2233_);
v___y_2220_ = v___y_2228_;
v___y_2221_ = v___y_2229_;
v___y_2222_ = v___x_2234_;
goto v___jp_2219_;
}
}
v___jp_2235_:
{
uint32_t v___x_2238_; uint8_t v___x_2239_;
v___x_2238_ = 3;
v___x_2239_ = lean_uint32_dec_le(v___x_2238_, v_markerCount_2173_);
if (v___x_2239_ == 0)
{
v___y_2228_ = v___y_2236_;
v___y_2229_ = v___y_2237_;
goto v___jp_2227_;
}
else
{
v___y_2228_ = v___y_2236_;
v___y_2229_ = v_markerKind_2172_;
goto v___jp_2227_;
}
}
v___jp_2240_:
{
uint8_t v___x_2242_; uint8_t v___x_2243_;
v___x_2242_ = 0;
v___x_2243_ = lean_uint8_dec_eq(v_openKind_2168_, v___x_2242_);
if (v___x_2243_ == 0)
{
uint8_t v___x_2244_;
v___x_2244_ = lean_uint8_dec_eq(v_markerKind_2172_, v_openKind_2168_);
if (v___x_2244_ == 0)
{
v___y_2228_ = v___y_2241_;
v___y_2229_ = v_openKind_2168_;
goto v___jp_2227_;
}
else
{
uint8_t v___x_2245_;
v___x_2245_ = lean_uint32_dec_le(v_openCount_2169_, v_markerCount_2173_);
if (v___x_2245_ == 0)
{
v___y_2228_ = v___y_2241_;
v___y_2229_ = v_openKind_2168_;
goto v___jp_2227_;
}
else
{
uint32_t v___x_2246_; uint8_t v___x_2247_;
v___x_2246_ = 3;
v___x_2247_ = lean_uint32_dec_le(v___x_2246_, v_markerCount_2173_);
if (v___x_2247_ == 0)
{
v___y_2228_ = v___y_2241_;
v___y_2229_ = v_openKind_2168_;
goto v___jp_2227_;
}
else
{
v___y_2228_ = v___y_2241_;
v___y_2229_ = v___x_2242_;
goto v___jp_2227_;
}
}
}
}
else
{
uint8_t v___x_2248_;
v___x_2248_ = lean_uint8_dec_eq(v_markerKind_2172_, v___x_2196_);
if (v___x_2248_ == 0)
{
uint8_t v___x_2249_; uint8_t v___x_2250_;
v___x_2249_ = 2;
v___x_2250_ = lean_uint8_dec_eq(v_markerKind_2172_, v___x_2249_);
if (v___x_2250_ == 0)
{
v___y_2228_ = v___y_2241_;
v___y_2229_ = v___x_2242_;
goto v___jp_2227_;
}
else
{
v___y_2236_ = v___y_2241_;
v___y_2237_ = v___x_2242_;
goto v___jp_2235_;
}
}
else
{
v___y_2236_ = v___y_2241_;
v___y_2237_ = v___x_2242_;
goto v___jp_2235_;
}
}
}
}
}

LEAN_EXPORT uint64_t orb_stream_token_cost_step(uint64_t v_prevCost_2276_, uint64_t v_newAdvance_2277_, uint64_t v_tailBytes_2278_){
_start:
{
uint64_t v___y_2280_; uint64_t v___x_2285_; uint64_t v___x_2286_; uint8_t v___x_2287_;
v___x_2285_ = 18446744073709551615ULL;
v___x_2286_ = lean_uint64_sub(v___x_2285_, v_tailBytes_2278_);
v___x_2287_ = lean_uint64_dec_le(v_newAdvance_2277_, v___x_2286_);
if (v___x_2287_ == 0)
{
v___y_2280_ = v___x_2285_;
goto v___jp_2279_;
}
else
{
uint64_t v___x_2288_;
v___x_2288_ = lean_uint64_add(v_newAdvance_2277_, v_tailBytes_2278_);
v___y_2280_ = v___x_2288_;
goto v___jp_2279_;
}
v___jp_2279_:
{
uint64_t v___x_2281_; uint64_t v___x_2282_; uint8_t v___x_2283_;
v___x_2281_ = 18446744073709551615ULL;
v___x_2282_ = lean_uint64_sub(v___x_2281_, v___y_2280_);
v___x_2283_ = lean_uint64_dec_le(v_prevCost_2276_, v___x_2282_);
if (v___x_2283_ == 0)
{
return v___x_2281_;
}
else
{
uint64_t v___x_2284_;
v___x_2284_ = lean_uint64_add(v_prevCost_2276_, v___y_2280_);
return v___x_2284_;
}
}
}
}

LEAN_EXPORT uint8_t orb_mission_state_classify(uint8_t v_stateId_2297_){
_start:
{
uint8_t v___x_2298_; uint8_t v___x_2299_;
v___x_2298_ = 8;
v___x_2299_ = lean_uint8_dec_le(v_stateId_2297_, v___x_2298_);
if (v___x_2299_ == 0)
{
uint8_t v___x_2300_; uint8_t v___x_2301_;
v___x_2300_ = 10;
v___x_2301_ = lean_uint8_dec_le(v_stateId_2297_, v___x_2300_);
if (v___x_2301_ == 0)
{
uint8_t v___x_2302_; uint8_t v___x_2303_;
v___x_2302_ = 15;
v___x_2303_ = lean_uint8_dec_le(v_stateId_2297_, v___x_2302_);
if (v___x_2303_ == 0)
{
uint8_t v___x_2304_; uint8_t v___x_2305_;
v___x_2304_ = 16;
v___x_2305_ = lean_uint8_dec_eq(v_stateId_2297_, v___x_2304_);
if (v___x_2305_ == 0)
{
uint8_t v___x_2306_; uint8_t v___x_2307_;
v___x_2306_ = 21;
v___x_2307_ = lean_uint8_dec_le(v_stateId_2297_, v___x_2306_);
if (v___x_2307_ == 0)
{
uint8_t v___x_2308_; uint8_t v___x_2309_;
v___x_2308_ = 23;
v___x_2309_ = lean_uint8_dec_le(v_stateId_2297_, v___x_2308_);
if (v___x_2309_ == 0)
{
uint8_t v___x_2310_; uint8_t v___x_2311_;
v___x_2310_ = 24;
v___x_2311_ = lean_uint8_dec_eq(v_stateId_2297_, v___x_2310_);
if (v___x_2311_ == 0)
{
uint8_t v___x_2312_; uint8_t v___x_2313_;
v___x_2312_ = 26;
v___x_2313_ = lean_uint8_dec_le(v_stateId_2297_, v___x_2312_);
if (v___x_2313_ == 0)
{
uint8_t v___x_2314_; uint8_t v___x_2315_;
v___x_2314_ = 28;
v___x_2315_ = lean_uint8_dec_le(v_stateId_2297_, v___x_2314_);
if (v___x_2315_ == 0)
{
uint8_t v___x_2316_;
v___x_2316_ = 9;
return v___x_2316_;
}
else
{
return v___x_2298_;
}
}
else
{
uint8_t v___x_2317_;
v___x_2317_ = 7;
return v___x_2317_;
}
}
else
{
uint8_t v___x_2318_;
v___x_2318_ = 5;
return v___x_2318_;
}
}
else
{
uint8_t v___x_2319_;
v___x_2319_ = 6;
return v___x_2319_;
}
}
else
{
uint8_t v___x_2320_;
v___x_2320_ = 2;
return v___x_2320_;
}
}
else
{
uint8_t v___x_2321_;
v___x_2321_ = 1;
return v___x_2321_;
}
}
else
{
uint8_t v___x_2322_;
v___x_2322_ = 0;
return v___x_2322_;
}
}
else
{
uint8_t v___x_2323_;
v___x_2323_ = 4;
return v___x_2323_;
}
}
else
{
uint8_t v___x_2324_;
v___x_2324_ = 3;
return v___x_2324_;
}
}
}

LEAN_EXPORT uint8_t orb_mission_sort_rank(uint8_t v_stateId_2329_){
_start:
{
uint8_t v___x_2330_; uint8_t v___x_2331_;
v___x_2330_ = 8;
v___x_2331_ = lean_uint8_dec_le(v_stateId_2329_, v___x_2330_);
if (v___x_2331_ == 0)
{
uint8_t v___x_2332_; uint8_t v___x_2333_;
v___x_2332_ = 10;
v___x_2333_ = lean_uint8_dec_le(v_stateId_2329_, v___x_2332_);
if (v___x_2333_ == 0)
{
uint8_t v___x_2334_; uint8_t v___x_2335_;
v___x_2334_ = 15;
v___x_2335_ = lean_uint8_dec_le(v_stateId_2329_, v___x_2334_);
if (v___x_2335_ == 0)
{
uint8_t v___x_2336_; uint8_t v___x_2337_;
v___x_2336_ = 16;
v___x_2337_ = lean_uint8_dec_eq(v_stateId_2329_, v___x_2336_);
if (v___x_2337_ == 0)
{
uint8_t v___x_2338_; uint8_t v___x_2339_;
v___x_2338_ = 21;
v___x_2339_ = lean_uint8_dec_le(v_stateId_2329_, v___x_2338_);
if (v___x_2339_ == 0)
{
uint8_t v___x_2340_; uint8_t v___x_2341_;
v___x_2340_ = 23;
v___x_2341_ = lean_uint8_dec_le(v_stateId_2329_, v___x_2340_);
if (v___x_2341_ == 0)
{
uint8_t v___x_2342_; uint8_t v___x_2343_;
v___x_2342_ = 24;
v___x_2343_ = lean_uint8_dec_eq(v_stateId_2329_, v___x_2342_);
if (v___x_2343_ == 0)
{
uint8_t v___x_2344_; uint8_t v___x_2345_;
v___x_2344_ = 26;
v___x_2345_ = lean_uint8_dec_le(v_stateId_2329_, v___x_2344_);
if (v___x_2345_ == 0)
{
uint8_t v___x_2346_; uint8_t v___x_2347_;
v___x_2346_ = 28;
v___x_2347_ = lean_uint8_dec_le(v_stateId_2329_, v___x_2346_);
if (v___x_2347_ == 0)
{
uint8_t v___x_2348_;
v___x_2348_ = 9;
return v___x_2348_;
}
else
{
return v___x_2330_;
}
}
else
{
uint8_t v___x_2349_;
v___x_2349_ = 7;
return v___x_2349_;
}
}
else
{
uint8_t v___x_2350_;
v___x_2350_ = 5;
return v___x_2350_;
}
}
else
{
uint8_t v___x_2351_;
v___x_2351_ = 6;
return v___x_2351_;
}
}
else
{
uint8_t v___x_2352_;
v___x_2352_ = 2;
return v___x_2352_;
}
}
else
{
uint8_t v___x_2353_;
v___x_2353_ = 1;
return v___x_2353_;
}
}
else
{
uint8_t v___x_2354_;
v___x_2354_ = 0;
return v___x_2354_;
}
}
else
{
uint8_t v___x_2355_;
v___x_2355_ = 4;
return v___x_2355_;
}
}
else
{
uint8_t v___x_2356_;
v___x_2356_ = 3;
return v___x_2356_;
}
}
}

LEAN_EXPORT uint32_t orb_mission_flags(uint8_t v_stateId_2447_){
_start:
{
uint32_t v___y_2449_; uint8_t v___y_2487_; uint8_t v___x_2513_; uint8_t v___x_2514_;
v___x_2513_ = 8;
v___x_2514_ = lean_uint8_dec_le(v_stateId_2447_, v___x_2513_);
if (v___x_2514_ == 0)
{
uint8_t v___x_2515_; uint8_t v___x_2516_;
v___x_2515_ = 10;
v___x_2516_ = lean_uint8_dec_le(v_stateId_2447_, v___x_2515_);
if (v___x_2516_ == 0)
{
uint8_t v___x_2517_; uint8_t v___x_2518_;
v___x_2517_ = 15;
v___x_2518_ = lean_uint8_dec_le(v_stateId_2447_, v___x_2517_);
if (v___x_2518_ == 0)
{
uint8_t v___x_2519_; uint8_t v___x_2520_;
v___x_2519_ = 16;
v___x_2520_ = lean_uint8_dec_eq(v_stateId_2447_, v___x_2519_);
if (v___x_2520_ == 0)
{
uint8_t v___x_2521_; uint8_t v___x_2522_;
v___x_2521_ = 21;
v___x_2522_ = lean_uint8_dec_le(v_stateId_2447_, v___x_2521_);
if (v___x_2522_ == 0)
{
uint8_t v___x_2523_; uint8_t v___x_2524_;
v___x_2523_ = 23;
v___x_2524_ = lean_uint8_dec_le(v_stateId_2447_, v___x_2523_);
if (v___x_2524_ == 0)
{
uint8_t v___x_2525_; uint8_t v___x_2526_;
v___x_2525_ = 24;
v___x_2526_ = lean_uint8_dec_eq(v_stateId_2447_, v___x_2525_);
if (v___x_2526_ == 0)
{
uint8_t v___x_2527_; uint8_t v___x_2528_;
v___x_2527_ = 26;
v___x_2528_ = lean_uint8_dec_le(v_stateId_2447_, v___x_2527_);
if (v___x_2528_ == 0)
{
uint8_t v___x_2529_; uint8_t v___x_2530_;
v___x_2529_ = 28;
v___x_2530_ = lean_uint8_dec_le(v_stateId_2447_, v___x_2529_);
if (v___x_2530_ == 0)
{
uint8_t v___x_2531_;
v___x_2531_ = 9;
v___y_2487_ = v___x_2531_;
goto v___jp_2486_;
}
else
{
v___y_2487_ = v___x_2513_;
goto v___jp_2486_;
}
}
else
{
uint8_t v___x_2532_;
v___x_2532_ = 7;
v___y_2487_ = v___x_2532_;
goto v___jp_2486_;
}
}
else
{
uint8_t v___x_2533_;
v___x_2533_ = 5;
v___y_2487_ = v___x_2533_;
goto v___jp_2486_;
}
}
else
{
uint8_t v___x_2534_;
v___x_2534_ = 6;
v___y_2487_ = v___x_2534_;
goto v___jp_2486_;
}
}
else
{
uint8_t v___x_2535_;
v___x_2535_ = 2;
v___y_2487_ = v___x_2535_;
goto v___jp_2486_;
}
}
else
{
uint8_t v___x_2536_;
v___x_2536_ = 1;
v___y_2487_ = v___x_2536_;
goto v___jp_2486_;
}
}
else
{
uint8_t v___x_2537_;
v___x_2537_ = 0;
v___y_2487_ = v___x_2537_;
goto v___jp_2486_;
}
}
else
{
uint8_t v___x_2538_;
v___x_2538_ = 4;
v___y_2487_ = v___x_2538_;
goto v___jp_2486_;
}
}
else
{
uint8_t v___x_2539_;
v___x_2539_ = 3;
v___y_2487_ = v___x_2539_;
goto v___jp_2486_;
}
v___jp_2448_:
{
uint8_t v___x_2450_; uint8_t v___x_2451_;
v___x_2450_ = 11;
v___x_2451_ = lean_uint8_dec_eq(v_stateId_2447_, v___x_2450_);
if (v___x_2451_ == 0)
{
uint8_t v___x_2452_; uint8_t v___x_2453_;
v___x_2452_ = 12;
v___x_2453_ = lean_uint8_dec_eq(v_stateId_2447_, v___x_2452_);
if (v___x_2453_ == 0)
{
uint8_t v___x_2454_; uint8_t v___x_2455_;
v___x_2454_ = 24;
v___x_2455_ = lean_uint8_dec_eq(v_stateId_2447_, v___x_2454_);
if (v___x_2455_ == 0)
{
uint8_t v___x_2456_; uint8_t v___x_2457_;
v___x_2456_ = 25;
v___x_2457_ = lean_uint8_dec_eq(v_stateId_2447_, v___x_2456_);
if (v___x_2457_ == 0)
{
uint8_t v___x_2458_; uint8_t v___x_2459_;
v___x_2458_ = 26;
v___x_2459_ = lean_uint8_dec_eq(v_stateId_2447_, v___x_2458_);
if (v___x_2459_ == 0)
{
uint8_t v___x_2460_; uint8_t v___x_2461_;
v___x_2460_ = 16;
v___x_2461_ = lean_uint8_dec_eq(v_stateId_2447_, v___x_2460_);
if (v___x_2461_ == 0)
{
uint8_t v___x_2462_; uint8_t v___x_2463_;
v___x_2462_ = 17;
v___x_2463_ = lean_uint8_dec_eq(v_stateId_2447_, v___x_2462_);
if (v___x_2463_ == 0)
{
uint8_t v___x_2464_; uint8_t v___x_2465_;
v___x_2464_ = 20;
v___x_2465_ = lean_uint8_dec_eq(v_stateId_2447_, v___x_2464_);
if (v___x_2465_ == 0)
{
uint8_t v___x_2466_; uint8_t v___x_2467_;
v___x_2466_ = 22;
v___x_2467_ = lean_uint8_dec_eq(v_stateId_2447_, v___x_2466_);
if (v___x_2467_ == 0)
{
return v___y_2449_;
}
else
{
uint32_t v___x_2468_; uint32_t v___x_2469_;
v___x_2468_ = 24;
v___x_2469_ = lean_uint32_lor(v___y_2449_, v___x_2468_);
return v___x_2469_;
}
}
else
{
uint32_t v___x_2470_; uint32_t v___x_2471_;
v___x_2470_ = 24;
v___x_2471_ = lean_uint32_lor(v___y_2449_, v___x_2470_);
return v___x_2471_;
}
}
else
{
uint32_t v___x_2472_; uint32_t v___x_2473_;
v___x_2472_ = 24;
v___x_2473_ = lean_uint32_lor(v___y_2449_, v___x_2472_);
return v___x_2473_;
}
}
else
{
uint32_t v___x_2474_; uint32_t v___x_2475_;
v___x_2474_ = 24;
v___x_2475_ = lean_uint32_lor(v___y_2449_, v___x_2474_);
return v___x_2475_;
}
}
else
{
uint32_t v___x_2476_; uint32_t v___x_2477_;
v___x_2476_ = 8;
v___x_2477_ = lean_uint32_lor(v___y_2449_, v___x_2476_);
return v___x_2477_;
}
}
else
{
uint32_t v___x_2478_; uint32_t v___x_2479_;
v___x_2478_ = 8;
v___x_2479_ = lean_uint32_lor(v___y_2449_, v___x_2478_);
return v___x_2479_;
}
}
else
{
uint32_t v___x_2480_; uint32_t v___x_2481_;
v___x_2480_ = 8;
v___x_2481_ = lean_uint32_lor(v___y_2449_, v___x_2480_);
return v___x_2481_;
}
}
else
{
uint32_t v___x_2482_; uint32_t v___x_2483_;
v___x_2482_ = 8;
v___x_2483_ = lean_uint32_lor(v___y_2449_, v___x_2482_);
return v___x_2483_;
}
}
else
{
uint32_t v___x_2484_; uint32_t v___x_2485_;
v___x_2484_ = 8;
v___x_2485_ = lean_uint32_lor(v___y_2449_, v___x_2484_);
return v___x_2485_;
}
}
v___jp_2486_:
{
uint8_t v___x_2488_; uint8_t v___x_2489_;
v___x_2488_ = 0;
v___x_2489_ = lean_uint8_dec_eq(v___y_2487_, v___x_2488_);
if (v___x_2489_ == 0)
{
uint8_t v___x_2490_; uint8_t v___x_2491_;
v___x_2490_ = 1;
v___x_2491_ = lean_uint8_dec_eq(v___y_2487_, v___x_2490_);
if (v___x_2491_ == 0)
{
uint8_t v___x_2492_; uint8_t v___x_2493_;
v___x_2492_ = 2;
v___x_2493_ = lean_uint8_dec_eq(v___y_2487_, v___x_2492_);
if (v___x_2493_ == 0)
{
uint8_t v___x_2494_; uint8_t v___x_2495_;
v___x_2494_ = 3;
v___x_2495_ = lean_uint8_dec_eq(v___y_2487_, v___x_2494_);
if (v___x_2495_ == 0)
{
uint8_t v___x_2496_; uint8_t v___x_2497_;
v___x_2496_ = 4;
v___x_2497_ = lean_uint8_dec_eq(v___y_2487_, v___x_2496_);
if (v___x_2497_ == 0)
{
uint8_t v___x_2498_; uint8_t v___x_2499_;
v___x_2498_ = 7;
v___x_2499_ = lean_uint8_dec_eq(v___y_2487_, v___x_2498_);
if (v___x_2499_ == 0)
{
uint8_t v___x_2500_; uint8_t v___x_2501_;
v___x_2500_ = 6;
v___x_2501_ = lean_uint8_dec_eq(v___y_2487_, v___x_2500_);
if (v___x_2501_ == 0)
{
uint8_t v___x_2502_; uint8_t v___x_2503_;
v___x_2502_ = 8;
v___x_2503_ = lean_uint8_dec_eq(v___y_2487_, v___x_2502_);
if (v___x_2503_ == 0)
{
uint32_t v___x_2504_;
v___x_2504_ = 0;
v___y_2449_ = v___x_2504_;
goto v___jp_2448_;
}
else
{
uint32_t v___x_2505_;
v___x_2505_ = 128;
v___y_2449_ = v___x_2505_;
goto v___jp_2448_;
}
}
else
{
uint32_t v___x_2506_;
v___x_2506_ = 128;
v___y_2449_ = v___x_2506_;
goto v___jp_2448_;
}
}
else
{
uint32_t v___x_2507_;
v___x_2507_ = 194;
v___y_2449_ = v___x_2507_;
goto v___jp_2448_;
}
}
else
{
uint32_t v___x_2508_;
v___x_2508_ = 1;
v___y_2449_ = v___x_2508_;
goto v___jp_2448_;
}
}
else
{
uint32_t v___x_2509_;
v___x_2509_ = 1;
v___y_2449_ = v___x_2509_;
goto v___jp_2448_;
}
}
else
{
uint32_t v___x_2510_;
v___x_2510_ = 166;
v___y_2449_ = v___x_2510_;
goto v___jp_2448_;
}
}
else
{
uint32_t v___x_2511_;
v___x_2511_ = 36;
v___y_2449_ = v___x_2511_;
goto v___jp_2448_;
}
}
else
{
uint32_t v___x_2512_;
v___x_2512_ = 4;
v___y_2449_ = v___x_2512_;
goto v___jp_2448_;
}
}
}
}

LEAN_EXPORT uint8_t orb_mission_inbox_section(uint8_t v_stateId_2544_){
_start:
{
uint8_t v___y_2546_; uint8_t v___x_2580_; uint8_t v___x_2581_;
v___x_2580_ = 8;
v___x_2581_ = lean_uint8_dec_le(v_stateId_2544_, v___x_2580_);
if (v___x_2581_ == 0)
{
uint8_t v___x_2582_; uint8_t v___x_2583_;
v___x_2582_ = 10;
v___x_2583_ = lean_uint8_dec_le(v_stateId_2544_, v___x_2582_);
if (v___x_2583_ == 0)
{
uint8_t v___x_2584_; uint8_t v___x_2585_;
v___x_2584_ = 15;
v___x_2585_ = lean_uint8_dec_le(v_stateId_2544_, v___x_2584_);
if (v___x_2585_ == 0)
{
uint8_t v___x_2586_; uint8_t v___x_2587_;
v___x_2586_ = 16;
v___x_2587_ = lean_uint8_dec_eq(v_stateId_2544_, v___x_2586_);
if (v___x_2587_ == 0)
{
uint8_t v___x_2588_; uint8_t v___x_2589_;
v___x_2588_ = 21;
v___x_2589_ = lean_uint8_dec_le(v_stateId_2544_, v___x_2588_);
if (v___x_2589_ == 0)
{
uint8_t v___x_2590_; uint8_t v___x_2591_;
v___x_2590_ = 23;
v___x_2591_ = lean_uint8_dec_le(v_stateId_2544_, v___x_2590_);
if (v___x_2591_ == 0)
{
uint8_t v___x_2592_; uint8_t v___x_2593_;
v___x_2592_ = 24;
v___x_2593_ = lean_uint8_dec_eq(v_stateId_2544_, v___x_2592_);
if (v___x_2593_ == 0)
{
uint8_t v___x_2594_; uint8_t v___x_2595_;
v___x_2594_ = 26;
v___x_2595_ = lean_uint8_dec_le(v_stateId_2544_, v___x_2594_);
if (v___x_2595_ == 0)
{
uint8_t v___x_2596_; uint8_t v___x_2597_;
v___x_2596_ = 28;
v___x_2597_ = lean_uint8_dec_le(v_stateId_2544_, v___x_2596_);
if (v___x_2597_ == 0)
{
uint8_t v___x_2598_;
v___x_2598_ = 9;
v___y_2546_ = v___x_2598_;
goto v___jp_2545_;
}
else
{
v___y_2546_ = v___x_2580_;
goto v___jp_2545_;
}
}
else
{
uint8_t v___x_2599_;
v___x_2599_ = 7;
v___y_2546_ = v___x_2599_;
goto v___jp_2545_;
}
}
else
{
uint8_t v___x_2600_;
v___x_2600_ = 5;
v___y_2546_ = v___x_2600_;
goto v___jp_2545_;
}
}
else
{
uint8_t v___x_2601_;
v___x_2601_ = 6;
v___y_2546_ = v___x_2601_;
goto v___jp_2545_;
}
}
else
{
uint8_t v___x_2602_;
v___x_2602_ = 2;
v___y_2546_ = v___x_2602_;
goto v___jp_2545_;
}
}
else
{
uint8_t v___x_2603_;
v___x_2603_ = 1;
v___y_2546_ = v___x_2603_;
goto v___jp_2545_;
}
}
else
{
uint8_t v___x_2604_;
v___x_2604_ = 0;
v___y_2546_ = v___x_2604_;
goto v___jp_2545_;
}
}
else
{
uint8_t v___x_2605_;
v___x_2605_ = 4;
v___y_2546_ = v___x_2605_;
goto v___jp_2545_;
}
}
else
{
uint8_t v___x_2606_;
v___x_2606_ = 3;
v___y_2546_ = v___x_2606_;
goto v___jp_2545_;
}
v___jp_2545_:
{
uint8_t v___x_2547_; uint8_t v___x_2548_;
v___x_2547_ = 3;
v___x_2548_ = lean_uint8_dec_eq(v___y_2546_, v___x_2547_);
if (v___x_2548_ == 0)
{
uint8_t v___x_2549_; uint8_t v___x_2550_;
v___x_2549_ = 4;
v___x_2550_ = lean_uint8_dec_eq(v___y_2546_, v___x_2549_);
if (v___x_2550_ == 0)
{
uint8_t v___x_2551_; uint8_t v___x_2552_;
v___x_2551_ = 2;
v___x_2552_ = lean_uint8_dec_le(v___y_2546_, v___x_2551_);
if (v___x_2552_ == 0)
{
uint8_t v___x_2553_; uint8_t v___x_2554_;
v___x_2553_ = 7;
v___x_2554_ = lean_uint8_dec_eq(v___y_2546_, v___x_2553_);
if (v___x_2554_ == 0)
{
uint8_t v___x_2555_; uint8_t v___x_2556_;
v___x_2555_ = 5;
v___x_2556_ = lean_uint8_dec_eq(v___y_2546_, v___x_2555_);
if (v___x_2556_ == 0)
{
uint8_t v___x_2557_; uint8_t v___x_2558_;
v___x_2557_ = 6;
v___x_2558_ = lean_uint8_dec_eq(v___y_2546_, v___x_2557_);
if (v___x_2558_ == 0)
{
return v___x_2547_;
}
else
{
uint8_t v___x_2559_; uint8_t v___x_2560_;
v___x_2559_ = 11;
v___x_2560_ = lean_uint8_dec_eq(v_stateId_2544_, v___x_2559_);
if (v___x_2560_ == 0)
{
uint8_t v___x_2561_; uint8_t v___x_2562_;
v___x_2561_ = 12;
v___x_2562_ = lean_uint8_dec_eq(v_stateId_2544_, v___x_2561_);
if (v___x_2562_ == 0)
{
uint8_t v___x_2563_; uint8_t v___x_2564_;
v___x_2563_ = 16;
v___x_2564_ = lean_uint8_dec_eq(v_stateId_2544_, v___x_2563_);
if (v___x_2564_ == 0)
{
uint8_t v___x_2565_; uint8_t v___x_2566_;
v___x_2565_ = 17;
v___x_2566_ = lean_uint8_dec_eq(v_stateId_2544_, v___x_2565_);
if (v___x_2566_ == 0)
{
uint8_t v___x_2567_; uint8_t v___x_2568_;
v___x_2567_ = 20;
v___x_2568_ = lean_uint8_dec_eq(v_stateId_2544_, v___x_2567_);
if (v___x_2568_ == 0)
{
uint8_t v___x_2569_; uint8_t v___x_2570_;
v___x_2569_ = 22;
v___x_2570_ = lean_uint8_dec_eq(v_stateId_2544_, v___x_2569_);
if (v___x_2570_ == 0)
{
uint8_t v___x_2571_; uint8_t v___x_2572_;
v___x_2571_ = 24;
v___x_2572_ = lean_uint8_dec_eq(v_stateId_2544_, v___x_2571_);
if (v___x_2572_ == 0)
{
uint8_t v___x_2573_; uint8_t v___x_2574_;
v___x_2573_ = 25;
v___x_2574_ = lean_uint8_dec_eq(v_stateId_2544_, v___x_2573_);
if (v___x_2574_ == 0)
{
uint8_t v___x_2575_; uint8_t v___x_2576_;
v___x_2575_ = 26;
v___x_2576_ = lean_uint8_dec_eq(v_stateId_2544_, v___x_2575_);
if (v___x_2576_ == 0)
{
return v___x_2547_;
}
else
{
return v___x_2551_;
}
}
else
{
return v___x_2551_;
}
}
else
{
return v___x_2551_;
}
}
else
{
return v___x_2551_;
}
}
else
{
return v___x_2551_;
}
}
else
{
return v___x_2551_;
}
}
else
{
return v___x_2551_;
}
}
else
{
return v___x_2551_;
}
}
else
{
return v___x_2551_;
}
}
}
else
{
return v___x_2551_;
}
}
else
{
return v___x_2551_;
}
}
else
{
uint8_t v___x_2577_;
v___x_2577_ = 1;
return v___x_2577_;
}
}
else
{
uint8_t v___x_2578_;
v___x_2578_ = 0;
return v___x_2578_;
}
}
else
{
uint8_t v___x_2579_;
v___x_2579_ = 0;
return v___x_2579_;
}
}
}
}

LEAN_EXPORT uint32_t orb_connection_issue_classify(uint8_t v_isUnreachable_2611_, uint8_t v_isUsingDefault_2612_, uint8_t v_isPrivateAddr_2613_, uint8_t v_defaultReachable_2614_, uint8_t v_hasExternalProxy_2615_){
_start:
{
uint32_t v___y_2617_; uint32_t v___y_2618_; uint32_t v___y_2619_; uint32_t v___y_2620_; uint8_t v___x_2628_; uint32_t v___y_2630_; uint32_t v___y_2631_; uint32_t v___y_2639_; uint8_t v___y_2640_; uint32_t v___y_2641_; uint32_t v___y_2652_; uint8_t v___y_2653_; uint8_t v___x_2655_;
v___x_2628_ = 1;
v___x_2655_ = lean_uint8_dec_eq(v_isUnreachable_2611_, v___x_2628_);
if (v___x_2655_ == 0)
{
uint32_t v___x_2656_;
v___x_2656_ = 0;
return v___x_2656_;
}
else
{
uint8_t v___x_2657_; uint8_t v___x_2658_; uint8_t v___x_2659_; uint32_t v___y_2661_;
v___x_2657_ = 0;
v___x_2658_ = 0;
v___x_2659_ = lean_uint8_dec_eq(v_isUsingDefault_2612_, v___x_2658_);
if (v___x_2659_ == 0)
{
uint32_t v___x_2664_;
v___x_2664_ = 0;
v___y_2661_ = v___x_2664_;
goto v___jp_2660_;
}
else
{
uint32_t v___x_2665_;
v___x_2665_ = 256;
v___y_2661_ = v___x_2665_;
goto v___jp_2660_;
}
v___jp_2660_:
{
if (v___x_2659_ == 0)
{
v___y_2652_ = v___y_2661_;
v___y_2653_ = v___x_2657_;
goto v___jp_2651_;
}
else
{
uint8_t v___x_2662_;
v___x_2662_ = lean_uint8_dec_eq(v_isPrivateAddr_2613_, v___x_2628_);
if (v___x_2662_ == 0)
{
v___y_2652_ = v___y_2661_;
v___y_2653_ = v___x_2662_;
goto v___jp_2651_;
}
else
{
uint32_t v___x_2663_;
v___x_2663_ = 16777216;
v___y_2639_ = v___y_2661_;
v___y_2640_ = v___x_2662_;
v___y_2641_ = v___x_2663_;
goto v___jp_2638_;
}
}
}
}
v___jp_2616_:
{
uint32_t v___x_2621_; uint32_t v___x_2622_; uint32_t v___x_2623_; uint32_t v___x_2624_; uint32_t v___x_2625_; uint32_t v___x_2626_; uint32_t v___x_2627_;
v___x_2621_ = 1;
v___x_2622_ = lean_uint32_lor(v___x_2621_, v___y_2618_);
v___x_2623_ = lean_uint32_lor(v___x_2622_, v___y_2617_);
v___x_2624_ = lean_uint32_lor(v___x_2623_, v___y_2619_);
v___x_2625_ = 28;
v___x_2626_ = lean_uint32_shift_left(v___y_2620_, v___x_2625_);
v___x_2627_ = lean_uint32_lor(v___x_2624_, v___x_2626_);
return v___x_2627_;
}
v___jp_2629_:
{
uint32_t v___x_2632_; uint8_t v___x_2633_;
v___x_2632_ = 0;
v___x_2633_ = lean_uint8_dec_eq(v_isPrivateAddr_2613_, v___x_2628_);
if (v___x_2633_ == 0)
{
uint8_t v___x_2634_;
v___x_2634_ = lean_uint8_dec_eq(v_isUsingDefault_2612_, v___x_2628_);
if (v___x_2634_ == 0)
{
uint32_t v___x_2635_;
v___x_2635_ = 5;
v___y_2617_ = v___x_2632_;
v___y_2618_ = v___y_2630_;
v___y_2619_ = v___y_2631_;
v___y_2620_ = v___x_2635_;
goto v___jp_2616_;
}
else
{
uint32_t v___x_2636_;
v___x_2636_ = 4;
v___y_2617_ = v___x_2632_;
v___y_2618_ = v___y_2630_;
v___y_2619_ = v___y_2631_;
v___y_2620_ = v___x_2636_;
goto v___jp_2616_;
}
}
else
{
uint32_t v___x_2637_;
v___x_2637_ = 3;
v___y_2617_ = v___x_2632_;
v___y_2618_ = v___y_2630_;
v___y_2619_ = v___y_2631_;
v___y_2620_ = v___x_2637_;
goto v___jp_2616_;
}
}
v___jp_2638_:
{
uint8_t v___x_2642_;
v___x_2642_ = lean_uint8_dec_eq(v_hasExternalProxy_2615_, v___x_2628_);
if (v___x_2642_ == 0)
{
if (v___y_2640_ == 0)
{
v___y_2630_ = v___y_2639_;
v___y_2631_ = v___y_2641_;
goto v___jp_2629_;
}
else
{
uint8_t v___x_2643_;
v___x_2643_ = lean_uint8_dec_eq(v_defaultReachable_2614_, v___x_2628_);
if (v___x_2643_ == 0)
{
v___y_2630_ = v___y_2639_;
v___y_2631_ = v___y_2641_;
goto v___jp_2629_;
}
else
{
uint32_t v___x_2644_; uint32_t v___x_2645_;
v___x_2644_ = 65536;
v___x_2645_ = 2;
v___y_2617_ = v___x_2644_;
v___y_2618_ = v___y_2639_;
v___y_2619_ = v___y_2641_;
v___y_2620_ = v___x_2645_;
goto v___jp_2616_;
}
}
}
else
{
uint32_t v___x_2646_; uint32_t v___x_2647_; uint32_t v___x_2648_; uint32_t v___x_2649_; uint32_t v___x_2650_;
v___x_2646_ = 1;
v___x_2647_ = lean_uint32_lor(v___x_2646_, v___y_2639_);
v___x_2648_ = lean_uint32_lor(v___x_2647_, v___y_2641_);
v___x_2649_ = 268435456;
v___x_2650_ = lean_uint32_lor(v___x_2648_, v___x_2649_);
return v___x_2650_;
}
}
v___jp_2651_:
{
uint32_t v___x_2654_;
v___x_2654_ = 0;
v___y_2639_ = v___y_2652_;
v___y_2640_ = v___y_2653_;
v___y_2641_ = v___x_2654_;
goto v___jp_2638_;
}
}
}

LEAN_EXPORT uint64_t orb_worked_duration_bucket(uint64_t v_seconds_2678_){
_start:
{
uint64_t v___x_2679_; uint8_t v___x_2680_;
v___x_2679_ = 60ULL;
v___x_2680_ = lean_uint64_dec_lt(v_seconds_2678_, v___x_2679_);
if (v___x_2680_ == 0)
{
uint64_t v___x_2681_; uint8_t v___x_2682_;
v___x_2681_ = 3600ULL;
v___x_2682_ = lean_uint64_dec_lt(v_seconds_2678_, v___x_2681_);
if (v___x_2682_ == 0)
{
uint64_t v___x_2683_; uint8_t v___x_2684_;
v___x_2683_ = 86400ULL;
v___x_2684_ = lean_uint64_dec_lt(v_seconds_2678_, v___x_2683_);
if (v___x_2684_ == 0)
{
uint64_t v_totalH_2685_; uint64_t v___x_2686_; uint64_t v___y_2688_; uint64_t v___x_2697_; uint64_t v___x_2698_; uint8_t v___x_2699_;
v_totalH_2685_ = lean_uint64_div(v_seconds_2678_, v___x_2681_);
v___x_2686_ = 24ULL;
v___x_2697_ = lean_uint64_div(v_totalH_2685_, v___x_2686_);
v___x_2698_ = 4294967295ULL;
v___x_2699_ = lean_uint64_dec_le(v___x_2697_, v___x_2698_);
if (v___x_2699_ == 0)
{
v___y_2688_ = v___x_2698_;
goto v___jp_2687_;
}
else
{
v___y_2688_ = v___x_2697_;
goto v___jp_2687_;
}
v___jp_2687_:
{
uint64_t v_remH_2689_; uint64_t v___x_2690_; uint64_t v___x_2691_; uint64_t v___x_2692_; uint64_t v___x_2693_; uint64_t v___x_2694_; uint64_t v___x_2695_; uint64_t v___x_2696_;
v_remH_2689_ = lean_uint64_mod(v_totalH_2685_, v___x_2686_);
v___x_2690_ = 3ULL;
v___x_2691_ = 8ULL;
v___x_2692_ = lean_uint64_shift_left(v_remH_2689_, v___x_2691_);
v___x_2693_ = lean_uint64_lor(v___x_2690_, v___x_2692_);
v___x_2694_ = 32ULL;
v___x_2695_ = lean_uint64_shift_left(v___y_2688_, v___x_2694_);
v___x_2696_ = lean_uint64_lor(v___x_2693_, v___x_2695_);
return v___x_2696_;
}
}
else
{
uint64_t v_totalM_2700_; uint64_t v_h_2701_; uint64_t v_remM_2702_; uint64_t v___x_2703_; uint64_t v___x_2704_; uint64_t v___x_2705_; uint64_t v___x_2706_; uint64_t v___x_2707_; uint64_t v___x_2708_; uint64_t v___x_2709_;
v_totalM_2700_ = lean_uint64_div(v_seconds_2678_, v___x_2679_);
v_h_2701_ = lean_uint64_div(v_totalM_2700_, v___x_2679_);
v_remM_2702_ = lean_uint64_mod(v_totalM_2700_, v___x_2679_);
v___x_2703_ = 2ULL;
v___x_2704_ = 8ULL;
v___x_2705_ = lean_uint64_shift_left(v_remM_2702_, v___x_2704_);
v___x_2706_ = lean_uint64_lor(v___x_2703_, v___x_2705_);
v___x_2707_ = 32ULL;
v___x_2708_ = lean_uint64_shift_left(v_h_2701_, v___x_2707_);
v___x_2709_ = lean_uint64_lor(v___x_2706_, v___x_2708_);
return v___x_2709_;
}
}
else
{
uint64_t v_m_2710_; uint64_t v_rem_2711_; uint64_t v___x_2712_; uint64_t v___x_2713_; uint64_t v___x_2714_; uint64_t v___x_2715_; uint64_t v___x_2716_; uint64_t v___x_2717_; uint64_t v___x_2718_;
v_m_2710_ = lean_uint64_div(v_seconds_2678_, v___x_2679_);
v_rem_2711_ = lean_uint64_mod(v_seconds_2678_, v___x_2679_);
v___x_2712_ = 1ULL;
v___x_2713_ = 8ULL;
v___x_2714_ = lean_uint64_shift_left(v_rem_2711_, v___x_2713_);
v___x_2715_ = lean_uint64_lor(v___x_2712_, v___x_2714_);
v___x_2716_ = 32ULL;
v___x_2717_ = lean_uint64_shift_left(v_m_2710_, v___x_2716_);
v___x_2718_ = lean_uint64_lor(v___x_2715_, v___x_2717_);
return v___x_2718_;
}
}
else
{
uint64_t v___x_2719_; uint64_t v___x_2720_;
v___x_2719_ = 32ULL;
v___x_2720_ = lean_uint64_shift_left(v_seconds_2678_, v___x_2719_);
return v___x_2720_;
}
}
}

LEAN_EXPORT uint32_t orb_turn_outcome_step(uint8_t v_prevOutcome_2725_, uint8_t v_prevFailed_2726_, uint8_t v_eventKind_2727_, uint8_t v_isNarration_2728_, uint8_t v_isSuccessFalse_2729_, uint8_t v_isTextNonEmpty_2730_){
_start:
{
uint8_t v___x_2731_; uint8_t v___x_2732_;
v___x_2731_ = 0;
v___x_2732_ = lean_uint8_dec_eq(v_eventKind_2727_, v___x_2731_);
if (v___x_2732_ == 0)
{
uint8_t v___x_2733_; uint32_t v___y_2735_; uint32_t v___y_2740_; uint32_t v___y_2749_; uint8_t v___x_2753_;
v___x_2733_ = 1;
v___x_2753_ = lean_uint8_dec_eq(v_eventKind_2727_, v___x_2733_);
if (v___x_2753_ == 0)
{
uint8_t v___x_2754_; uint8_t v___x_2755_;
v___x_2754_ = 2;
v___x_2755_ = lean_uint8_dec_eq(v_eventKind_2727_, v___x_2754_);
if (v___x_2755_ == 0)
{
uint8_t v___x_2756_;
v___x_2756_ = lean_uint8_dec_eq(v_prevOutcome_2725_, v___x_2733_);
if (v___x_2756_ == 0)
{
uint32_t v___x_2757_;
v___x_2757_ = 0;
v___y_2749_ = v___x_2757_;
goto v___jp_2748_;
}
else
{
uint32_t v___x_2758_;
v___x_2758_ = 1;
v___y_2749_ = v___x_2758_;
goto v___jp_2748_;
}
}
else
{
uint8_t v___x_2759_;
v___x_2759_ = lean_uint8_dec_eq(v_isNarration_2728_, v___x_2733_);
if (v___x_2759_ == 0)
{
uint8_t v___x_2760_;
v___x_2760_ = lean_uint8_dec_eq(v_isSuccessFalse_2729_, v___x_2733_);
if (v___x_2760_ == 0)
{
uint8_t v___x_2761_;
v___x_2761_ = lean_uint8_dec_eq(v_prevFailed_2726_, v___x_2731_);
if (v___x_2761_ == 0)
{
goto v___jp_2744_;
}
else
{
uint8_t v___x_2762_;
v___x_2762_ = lean_uint8_dec_eq(v_isTextNonEmpty_2730_, v___x_2733_);
if (v___x_2762_ == 0)
{
goto v___jp_2744_;
}
else
{
uint32_t v___x_2763_;
v___x_2763_ = 1;
return v___x_2763_;
}
}
}
else
{
uint32_t v___x_2764_;
v___x_2764_ = 256;
return v___x_2764_;
}
}
else
{
uint8_t v___x_2765_;
v___x_2765_ = lean_uint8_dec_eq(v_prevOutcome_2725_, v___x_2733_);
if (v___x_2765_ == 0)
{
uint32_t v___x_2766_;
v___x_2766_ = 0;
v___y_2735_ = v___x_2766_;
goto v___jp_2734_;
}
else
{
uint32_t v___x_2767_;
v___x_2767_ = 1;
v___y_2735_ = v___x_2767_;
goto v___jp_2734_;
}
}
}
}
else
{
uint32_t v___x_2768_;
v___x_2768_ = 0;
return v___x_2768_;
}
v___jp_2734_:
{
uint8_t v___x_2736_;
v___x_2736_ = lean_uint8_dec_eq(v_prevFailed_2726_, v___x_2733_);
if (v___x_2736_ == 0)
{
return v___y_2735_;
}
else
{
uint32_t v___x_2737_; uint32_t v___x_2738_;
v___x_2737_ = 256;
v___x_2738_ = lean_uint32_lor(v___y_2735_, v___x_2737_);
return v___x_2738_;
}
}
v___jp_2739_:
{
uint8_t v___x_2741_;
v___x_2741_ = lean_uint8_dec_eq(v_prevFailed_2726_, v___x_2733_);
if (v___x_2741_ == 0)
{
return v___y_2740_;
}
else
{
uint32_t v___x_2742_; uint32_t v___x_2743_;
v___x_2742_ = 256;
v___x_2743_ = lean_uint32_lor(v___y_2740_, v___x_2742_);
return v___x_2743_;
}
}
v___jp_2744_:
{
uint8_t v___x_2745_;
v___x_2745_ = lean_uint8_dec_eq(v_prevOutcome_2725_, v___x_2733_);
if (v___x_2745_ == 0)
{
uint32_t v___x_2746_;
v___x_2746_ = 0;
v___y_2740_ = v___x_2746_;
goto v___jp_2739_;
}
else
{
uint32_t v___x_2747_;
v___x_2747_ = 1;
v___y_2740_ = v___x_2747_;
goto v___jp_2739_;
}
}
v___jp_2748_:
{
uint8_t v___x_2750_;
v___x_2750_ = lean_uint8_dec_eq(v_prevFailed_2726_, v___x_2733_);
if (v___x_2750_ == 0)
{
return v___y_2749_;
}
else
{
uint32_t v___x_2751_; uint32_t v___x_2752_;
v___x_2751_ = 256;
v___x_2752_ = lean_uint32_lor(v___y_2749_, v___x_2751_);
return v___x_2752_;
}
}
}
else
{
uint32_t v___x_2769_;
v___x_2769_ = 0;
return v___x_2769_;
}
}
}

LEAN_EXPORT uint8_t orb_numeric_cell_scan(uint8_t v_nonEmpty_2784_, uint8_t v_hasLeadingDigitOrSign_2785_, uint8_t v_hasDigit_2786_, uint8_t v_allAllowedChars_2787_){
_start:
{
uint8_t v___x_2788_; uint8_t v___x_2789_;
v___x_2788_ = 1;
v___x_2789_ = lean_uint8_dec_eq(v_nonEmpty_2784_, v___x_2788_);
if (v___x_2789_ == 0)
{
uint8_t v___x_2790_;
v___x_2790_ = 0;
return v___x_2790_;
}
else
{
uint8_t v___x_2791_;
v___x_2791_ = lean_uint8_dec_eq(v_hasLeadingDigitOrSign_2785_, v___x_2788_);
if (v___x_2791_ == 0)
{
uint8_t v___x_2792_;
v___x_2792_ = 0;
return v___x_2792_;
}
else
{
uint8_t v___x_2793_;
v___x_2793_ = lean_uint8_dec_eq(v_hasDigit_2786_, v___x_2788_);
if (v___x_2793_ == 0)
{
uint8_t v___x_2794_;
v___x_2794_ = 0;
return v___x_2794_;
}
else
{
uint8_t v___x_2795_;
v___x_2795_ = lean_uint8_dec_eq(v_allAllowedChars_2787_, v___x_2788_);
if (v___x_2795_ == 0)
{
uint8_t v___x_2796_;
v___x_2796_ = 0;
return v___x_2796_;
}
else
{
return v___x_2788_;
}
}
}
}
}
}

LEAN_EXPORT uint64_t orb_file_ref_line_span(uint32_t v_startLine_2807_, uint32_t v_endLine_2808_, uint32_t v_totalLines_2809_){
_start:
{
uint32_t v___x_2810_; uint8_t v___x_2819_;
v___x_2810_ = 1;
v___x_2819_ = lean_uint32_dec_le(v___x_2810_, v_startLine_2807_);
if (v___x_2819_ == 0)
{
uint64_t v___x_2820_;
v___x_2820_ = 0ULL;
return v___x_2820_;
}
else
{
uint8_t v___x_2821_;
v___x_2821_ = lean_uint32_dec_le(v_startLine_2807_, v_endLine_2808_);
if (v___x_2821_ == 0)
{
uint64_t v___x_2822_;
v___x_2822_ = 0ULL;
return v___x_2822_;
}
else
{
uint32_t v___x_2823_; uint8_t v___x_2824_;
v___x_2823_ = 0;
v___x_2824_ = lean_uint32_dec_eq(v_totalLines_2809_, v___x_2823_);
if (v___x_2824_ == 0)
{
uint8_t v___x_2825_;
v___x_2825_ = lean_uint32_dec_le(v_endLine_2808_, v_totalLines_2809_);
if (v___x_2825_ == 0)
{
uint64_t v___x_2826_;
v___x_2826_ = 0ULL;
return v___x_2826_;
}
else
{
goto v___jp_2811_;
}
}
else
{
goto v___jp_2811_;
}
}
}
v___jp_2811_:
{
uint32_t v___x_2812_; uint32_t v_count_2813_; uint64_t v___x_2814_; uint64_t v___x_2815_; uint64_t v___x_2816_; uint64_t v___x_2817_; uint64_t v___x_2818_;
v___x_2812_ = lean_uint32_sub(v_endLine_2808_, v_startLine_2807_);
v_count_2813_ = lean_uint32_add(v___x_2812_, v___x_2810_);
v___x_2814_ = 1ULL;
v___x_2815_ = lean_uint32_to_uint64(v_count_2813_);
v___x_2816_ = 32ULL;
v___x_2817_ = lean_uint64_shift_left(v___x_2815_, v___x_2816_);
v___x_2818_ = lean_uint64_lor(v___x_2814_, v___x_2817_);
return v___x_2818_;
}
}
}

LEAN_EXPORT uint32_t orb_machine_action_admitted(uint8_t v_stateKind_2835_, uint8_t v_isBusy_2836_, uint8_t v_isMuted_2837_){
_start:
{
uint32_t v___y_2839_; uint32_t v___y_2840_; uint32_t v___y_2841_; uint32_t v___y_2842_; uint32_t v___y_2843_; uint32_t v___y_2849_; uint32_t v___y_2850_; uint32_t v___y_2851_; uint32_t v___y_2852_; uint8_t v___y_2855_; uint32_t v___y_2856_; uint32_t v___y_2857_; uint32_t v___y_2858_; uint8_t v___y_2859_; uint32_t v___y_2860_; uint32_t v___y_2863_; uint32_t v___y_2864_; uint8_t v___y_2865_; uint32_t v___y_2866_; uint32_t v___y_2872_; uint8_t v___y_2873_; uint8_t v___y_2874_; uint32_t v___y_2875_; uint32_t v___y_2879_; uint8_t v___y_2880_; uint8_t v___y_2881_; uint8_t v___y_2884_; uint32_t v___y_2885_; uint8_t v___y_2890_; uint8_t v___x_2895_; uint8_t v___x_2896_;
v___x_2895_ = 0;
v___x_2896_ = lean_uint8_dec_eq(v_isBusy_2836_, v___x_2895_);
if (v___x_2896_ == 0)
{
v___y_2890_ = v___x_2896_;
goto v___jp_2889_;
}
else
{
uint8_t v___x_2897_;
v___x_2897_ = lean_uint8_dec_eq(v_isMuted_2837_, v___x_2895_);
v___y_2890_ = v___x_2897_;
goto v___jp_2889_;
}
v___jp_2838_:
{
uint32_t v___x_2844_; uint32_t v___x_2845_; uint32_t v___x_2846_; uint32_t v___x_2847_;
v___x_2844_ = lean_uint32_lor(v___y_2841_, v___y_2839_);
v___x_2845_ = lean_uint32_lor(v___x_2844_, v___y_2840_);
v___x_2846_ = lean_uint32_lor(v___x_2845_, v___y_2842_);
v___x_2847_ = lean_uint32_lor(v___x_2846_, v___y_2843_);
return v___x_2847_;
}
v___jp_2848_:
{
uint32_t v___x_2853_;
v___x_2853_ = 0;
v___y_2839_ = v___y_2849_;
v___y_2840_ = v___y_2850_;
v___y_2841_ = v___y_2851_;
v___y_2842_ = v___y_2852_;
v___y_2843_ = v___x_2853_;
goto v___jp_2838_;
}
v___jp_2854_:
{
if (v___y_2855_ == 0)
{
v___y_2849_ = v___y_2856_;
v___y_2850_ = v___y_2857_;
v___y_2851_ = v___y_2858_;
v___y_2852_ = v___y_2860_;
goto v___jp_2848_;
}
else
{
if (v___y_2859_ == 0)
{
v___y_2849_ = v___y_2856_;
v___y_2850_ = v___y_2857_;
v___y_2851_ = v___y_2858_;
v___y_2852_ = v___y_2860_;
goto v___jp_2848_;
}
else
{
uint32_t v___x_2861_;
v___x_2861_ = 33554432;
v___y_2839_ = v___y_2856_;
v___y_2840_ = v___y_2857_;
v___y_2841_ = v___y_2858_;
v___y_2842_ = v___y_2860_;
v___y_2843_ = v___x_2861_;
goto v___jp_2838_;
}
}
}
v___jp_2862_:
{
uint8_t v___x_2867_; uint8_t v___x_2868_;
v___x_2867_ = 6;
v___x_2868_ = lean_uint8_dec_eq(v_stateKind_2835_, v___x_2867_);
if (v___x_2868_ == 0)
{
uint32_t v___x_2869_;
v___x_2869_ = 0;
v___y_2855_ = v___x_2868_;
v___y_2856_ = v___y_2863_;
v___y_2857_ = v___y_2866_;
v___y_2858_ = v___y_2864_;
v___y_2859_ = v___y_2865_;
v___y_2860_ = v___x_2869_;
goto v___jp_2854_;
}
else
{
uint32_t v___x_2870_;
v___x_2870_ = 16777216;
v___y_2855_ = v___x_2868_;
v___y_2856_ = v___y_2863_;
v___y_2857_ = v___y_2866_;
v___y_2858_ = v___y_2864_;
v___y_2859_ = v___y_2865_;
v___y_2860_ = v___x_2870_;
goto v___jp_2854_;
}
}
v___jp_2871_:
{
if (v___y_2873_ == 0)
{
uint32_t v___x_2876_;
v___x_2876_ = 0;
v___y_2863_ = v___y_2875_;
v___y_2864_ = v___y_2872_;
v___y_2865_ = v___y_2874_;
v___y_2866_ = v___x_2876_;
goto v___jp_2862_;
}
else
{
uint32_t v___x_2877_;
v___x_2877_ = 65536;
v___y_2863_ = v___y_2875_;
v___y_2864_ = v___y_2872_;
v___y_2865_ = v___y_2874_;
v___y_2866_ = v___x_2877_;
goto v___jp_2862_;
}
}
v___jp_2878_:
{
uint32_t v___x_2882_;
v___x_2882_ = 0;
v___y_2872_ = v___y_2879_;
v___y_2873_ = v___y_2880_;
v___y_2874_ = v___y_2881_;
v___y_2875_ = v___x_2882_;
goto v___jp_2871_;
}
v___jp_2883_:
{
uint8_t v___x_2886_; uint8_t v___x_2887_;
v___x_2886_ = 2;
v___x_2887_ = lean_uint8_dec_le(v_stateKind_2835_, v___x_2886_);
if (v___x_2887_ == 0)
{
v___y_2879_ = v___y_2885_;
v___y_2880_ = v___x_2887_;
v___y_2881_ = v___y_2884_;
goto v___jp_2878_;
}
else
{
if (v___y_2884_ == 0)
{
v___y_2879_ = v___y_2885_;
v___y_2880_ = v___x_2887_;
v___y_2881_ = v___y_2884_;
goto v___jp_2878_;
}
else
{
uint32_t v___x_2888_;
v___x_2888_ = 256;
v___y_2872_ = v___y_2885_;
v___y_2873_ = v___x_2887_;
v___y_2874_ = v___y_2884_;
v___y_2875_ = v___x_2888_;
goto v___jp_2871_;
}
}
}
v___jp_2889_:
{
uint8_t v___x_2891_; uint8_t v___x_2892_;
v___x_2891_ = 3;
v___x_2892_ = lean_uint8_dec_le(v_stateKind_2835_, v___x_2891_);
if (v___x_2892_ == 0)
{
uint32_t v___x_2893_;
v___x_2893_ = 0;
v___y_2884_ = v___y_2890_;
v___y_2885_ = v___x_2893_;
goto v___jp_2883_;
}
else
{
uint32_t v___x_2894_;
v___x_2894_ = 1;
v___y_2884_ = v___y_2890_;
v___y_2885_ = v___x_2894_;
goto v___jp_2883_;
}
}
}
}

LEAN_EXPORT uint32_t orb_send_flow_step(uint8_t v_isBusy_2906_, uint8_t v_hasNonEmptyText_2907_, uint8_t v_canQueue_2908_, uint8_t v_awaitingAck_2909_, uint8_t v_isDraining_2910_, uint8_t v_pendingCount_2911_, uint32_t v_httpStatus_2912_){
_start:
{
uint32_t v___y_2914_; uint32_t v___y_2915_; uint32_t v___y_2916_; uint32_t v___y_2922_; uint32_t v___y_2923_; uint32_t v___y_2926_; uint32_t v___y_2927_; uint32_t v___y_2937_; uint32_t v___y_2938_; uint32_t v___y_2945_; uint8_t v___x_2947_; uint32_t v___y_2949_; uint8_t v___x_2954_;
v___x_2947_ = 0;
v___x_2954_ = lean_uint8_dec_eq(v_hasNonEmptyText_2907_, v___x_2947_);
if (v___x_2954_ == 0)
{
uint8_t v___x_2955_;
v___x_2955_ = lean_uint8_dec_eq(v_isBusy_2906_, v___x_2947_);
if (v___x_2955_ == 0)
{
uint8_t v___x_2956_; uint8_t v___x_2957_;
v___x_2956_ = 1;
v___x_2957_ = lean_uint8_dec_eq(v_canQueue_2908_, v___x_2956_);
if (v___x_2957_ == 0)
{
uint32_t v___x_2958_;
v___x_2958_ = 0;
v___y_2949_ = v___x_2958_;
goto v___jp_2948_;
}
else
{
uint32_t v___x_2959_;
v___x_2959_ = 2;
v___y_2949_ = v___x_2959_;
goto v___jp_2948_;
}
}
else
{
uint32_t v___x_2960_;
v___x_2960_ = 1;
v___y_2949_ = v___x_2960_;
goto v___jp_2948_;
}
}
else
{
uint32_t v___x_2961_;
v___x_2961_ = 0;
v___y_2949_ = v___x_2961_;
goto v___jp_2948_;
}
v___jp_2913_:
{
uint32_t v___x_2917_; uint32_t v___x_2918_; uint32_t v___x_2919_; uint32_t v___x_2920_;
v___x_2917_ = lean_uint32_lor(v___y_2914_, v___y_2915_);
v___x_2918_ = 16;
v___x_2919_ = lean_uint32_shift_left(v___y_2916_, v___x_2918_);
v___x_2920_ = lean_uint32_lor(v___x_2917_, v___x_2919_);
return v___x_2920_;
}
v___jp_2921_:
{
uint32_t v___x_2924_;
v___x_2924_ = 2;
v___y_2914_ = v___y_2922_;
v___y_2915_ = v___y_2923_;
v___y_2916_ = v___x_2924_;
goto v___jp_2913_;
}
v___jp_2925_:
{
uint32_t v___x_2928_; uint8_t v___x_2929_;
v___x_2928_ = 404;
v___x_2929_ = lean_uint32_dec_eq(v_httpStatus_2912_, v___x_2928_);
if (v___x_2929_ == 0)
{
uint32_t v___x_2930_; uint8_t v___x_2931_;
v___x_2930_ = 405;
v___x_2931_ = lean_uint32_dec_eq(v_httpStatus_2912_, v___x_2930_);
if (v___x_2931_ == 0)
{
uint32_t v___x_2932_; uint8_t v___x_2933_;
v___x_2932_ = 409;
v___x_2933_ = lean_uint32_dec_eq(v_httpStatus_2912_, v___x_2932_);
if (v___x_2933_ == 0)
{
uint32_t v___x_2934_;
v___x_2934_ = 0;
v___y_2914_ = v___y_2926_;
v___y_2915_ = v___y_2927_;
v___y_2916_ = v___x_2934_;
goto v___jp_2913_;
}
else
{
uint32_t v___x_2935_;
v___x_2935_ = 3;
v___y_2914_ = v___y_2926_;
v___y_2915_ = v___y_2927_;
v___y_2916_ = v___x_2935_;
goto v___jp_2913_;
}
}
else
{
v___y_2922_ = v___y_2926_;
v___y_2923_ = v___y_2927_;
goto v___jp_2921_;
}
}
else
{
v___y_2922_ = v___y_2926_;
v___y_2923_ = v___y_2927_;
goto v___jp_2921_;
}
}
v___jp_2936_:
{
uint32_t v___x_2939_; uint8_t v___x_2940_;
v___x_2939_ = 200;
v___x_2940_ = lean_uint32_dec_le(v___x_2939_, v_httpStatus_2912_);
if (v___x_2940_ == 0)
{
v___y_2926_ = v___y_2937_;
v___y_2927_ = v___y_2938_;
goto v___jp_2925_;
}
else
{
uint32_t v___x_2941_; uint8_t v___x_2942_;
v___x_2941_ = 300;
v___x_2942_ = lean_uint32_dec_lt(v_httpStatus_2912_, v___x_2941_);
if (v___x_2942_ == 0)
{
v___y_2926_ = v___y_2937_;
v___y_2927_ = v___y_2938_;
goto v___jp_2925_;
}
else
{
uint32_t v___x_2943_;
v___x_2943_ = 1;
v___y_2914_ = v___y_2937_;
v___y_2915_ = v___y_2938_;
v___y_2916_ = v___x_2943_;
goto v___jp_2913_;
}
}
}
v___jp_2944_:
{
uint32_t v___x_2946_;
v___x_2946_ = 0;
v___y_2937_ = v___y_2945_;
v___y_2938_ = v___x_2946_;
goto v___jp_2936_;
}
v___jp_2948_:
{
uint8_t v___x_2950_;
v___x_2950_ = lean_uint8_dec_lt(v___x_2947_, v_pendingCount_2911_);
if (v___x_2950_ == 0)
{
v___y_2945_ = v___y_2949_;
goto v___jp_2944_;
}
else
{
uint8_t v___x_2951_;
v___x_2951_ = lean_uint8_dec_eq(v_awaitingAck_2909_, v___x_2947_);
if (v___x_2951_ == 0)
{
v___y_2945_ = v___y_2949_;
goto v___jp_2944_;
}
else
{
uint8_t v___x_2952_;
v___x_2952_ = lean_uint8_dec_eq(v_isDraining_2910_, v___x_2947_);
if (v___x_2952_ == 0)
{
v___y_2945_ = v___y_2949_;
goto v___jp_2944_;
}
else
{
uint32_t v___x_2953_;
v___x_2953_ = 256;
v___y_2937_ = v___y_2949_;
v___y_2938_ = v___x_2953_;
goto v___jp_2936_;
}
}
}
}
}
}

LEAN_EXPORT uint8_t orb_wire_validate_frame(uint32_t v_magic_2978_, uint32_t v_abiVersion_2979_, uint32_t v_schemaId_2980_, uint32_t v_expectedSchemaId_2981_, uint32_t v_totalLen_2982_, uint32_t v_payloadLen_2983_, uint32_t v_arenaOff_2984_, uint32_t v_arenaLen_2985_, uint32_t v_maxBudgetBytes_2986_, uint32_t v_outCap_2987_, uint32_t v_requiredOutBytes_2988_){
_start:
{
uint32_t v___x_2989_; uint8_t v___x_2990_;
v___x_2989_ = 1330790999;
v___x_2990_ = lean_uint32_dec_eq(v_magic_2978_, v___x_2989_);
if (v___x_2990_ == 0)
{
uint8_t v___x_2991_;
v___x_2991_ = 1;
return v___x_2991_;
}
else
{
uint32_t v___x_2992_; uint8_t v___x_2993_;
v___x_2992_ = 1;
v___x_2993_ = lean_uint32_dec_eq(v_abiVersion_2979_, v___x_2992_);
if (v___x_2993_ == 0)
{
uint8_t v___x_2994_;
v___x_2994_ = 1;
return v___x_2994_;
}
else
{
uint8_t v___x_2995_;
v___x_2995_ = lean_uint32_dec_eq(v_schemaId_2980_, v_expectedSchemaId_2981_);
if (v___x_2995_ == 0)
{
uint8_t v___x_2996_;
v___x_2996_ = 2;
return v___x_2996_;
}
else
{
uint32_t v___x_2997_; uint8_t v___x_2998_;
v___x_2997_ = 24;
v___x_2998_ = lean_uint32_dec_le(v___x_2997_, v_totalLen_2982_);
if (v___x_2998_ == 0)
{
uint8_t v___x_2999_;
v___x_2999_ = 3;
return v___x_2999_;
}
else
{
uint8_t v___x_3000_;
v___x_3000_ = lean_uint32_dec_le(v_totalLen_2982_, v_maxBudgetBytes_2986_);
if (v___x_3000_ == 0)
{
uint8_t v___x_3001_;
v___x_3001_ = 4;
return v___x_3001_;
}
else
{
uint32_t v___x_3002_; uint8_t v___x_3003_;
v___x_3002_ = lean_uint32_sub(v_totalLen_2982_, v___x_2997_);
v___x_3003_ = lean_uint32_dec_le(v_payloadLen_2983_, v___x_3002_);
if (v___x_3003_ == 0)
{
uint8_t v___x_3004_;
v___x_3004_ = 3;
return v___x_3004_;
}
else
{
uint8_t v___x_3005_;
v___x_3005_ = lean_uint32_dec_le(v_arenaOff_2984_, v_payloadLen_2983_);
if (v___x_3005_ == 0)
{
uint8_t v___x_3006_;
v___x_3006_ = 3;
return v___x_3006_;
}
else
{
uint32_t v___x_3007_; uint8_t v___x_3008_;
v___x_3007_ = lean_uint32_sub(v_payloadLen_2983_, v_arenaOff_2984_);
v___x_3008_ = lean_uint32_dec_le(v_arenaLen_2985_, v___x_3007_);
if (v___x_3008_ == 0)
{
uint8_t v___x_3009_;
v___x_3009_ = 3;
return v___x_3009_;
}
else
{
uint8_t v___x_3010_;
v___x_3010_ = lean_uint32_dec_le(v_requiredOutBytes_2988_, v_outCap_2987_);
if (v___x_3010_ == 0)
{
uint8_t v___x_3011_;
v___x_3011_ = 5;
return v___x_3011_;
}
else
{
uint8_t v___x_3012_;
v___x_3012_ = 0;
return v___x_3012_;
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

LEAN_EXPORT uint64_t orb_wire_pack_record(uint8_t v_tag_3037_, uint8_t v_flags_3038_, uint32_t v_len16_3039_, uint32_t v_payload32_3040_){
_start:
{
uint32_t v___x_3041_; uint32_t v___x_3042_; uint32_t v___x_3043_; uint32_t v___x_3044_; uint32_t v___x_3045_; uint32_t v___x_3046_; uint32_t v___x_3047_; uint32_t v___x_3048_; uint32_t v___x_3049_; uint32_t v_lo32_3050_; uint64_t v___x_3051_; uint64_t v___x_3052_; uint64_t v___x_3053_; uint64_t v___x_3054_; uint64_t v___x_3055_;
v___x_3041_ = lean_uint8_to_uint32(v_tag_3037_);
v___x_3042_ = lean_uint8_to_uint32(v_flags_3038_);
v___x_3043_ = 8;
v___x_3044_ = lean_uint32_shift_left(v___x_3042_, v___x_3043_);
v___x_3045_ = lean_uint32_lor(v___x_3041_, v___x_3044_);
v___x_3046_ = 65535;
v___x_3047_ = lean_uint32_land(v_len16_3039_, v___x_3046_);
v___x_3048_ = 16;
v___x_3049_ = lean_uint32_shift_left(v___x_3047_, v___x_3048_);
v_lo32_3050_ = lean_uint32_lor(v___x_3045_, v___x_3049_);
v___x_3051_ = lean_uint32_to_uint64(v_lo32_3050_);
v___x_3052_ = lean_uint32_to_uint64(v_payload32_3040_);
v___x_3053_ = 32ULL;
v___x_3054_ = lean_uint64_shift_left(v___x_3052_, v___x_3053_);
v___x_3055_ = lean_uint64_lor(v___x_3051_, v___x_3054_);
return v___x_3055_;
}
}

LEAN_EXPORT uint8_t orb_wire_schema_migrate_step(uint32_t v_fromSchema_3102_, uint32_t v_toSchema_3103_, uint32_t v_currentSchema_3104_, uint64_t v_payloadBytes_3105_, uint64_t v_maxBytes_3106_){
_start:
{
uint8_t v___x_3107_;
v___x_3107_ = lean_uint32_dec_eq(v_fromSchema_3102_, v_currentSchema_3104_);
if (v___x_3107_ == 0)
{
uint8_t v___x_3108_;
v___x_3108_ = 0;
return v___x_3108_;
}
else
{
uint8_t v___x_3109_;
v___x_3109_ = lean_uint32_dec_lt(v_fromSchema_3102_, v_toSchema_3103_);
if (v___x_3109_ == 0)
{
uint8_t v___x_3110_;
v___x_3110_ = 0;
return v___x_3110_;
}
else
{
uint32_t v___x_3111_; uint32_t v___x_3112_; uint8_t v___x_3113_;
v___x_3111_ = lean_uint32_sub(v_toSchema_3103_, v_fromSchema_3102_);
v___x_3112_ = 1;
v___x_3113_ = lean_uint32_dec_eq(v___x_3111_, v___x_3112_);
if (v___x_3113_ == 0)
{
uint8_t v___x_3114_;
v___x_3114_ = 0;
return v___x_3114_;
}
else
{
uint64_t v___x_3115_; uint8_t v___x_3116_;
v___x_3115_ = 0ULL;
v___x_3116_ = lean_uint64_dec_lt(v___x_3115_, v_payloadBytes_3105_);
if (v___x_3116_ == 0)
{
uint8_t v___x_3117_;
v___x_3117_ = 0;
return v___x_3117_;
}
else
{
uint8_t v___x_3118_;
v___x_3118_ = lean_uint64_dec_le(v_payloadBytes_3105_, v_maxBytes_3106_);
if (v___x_3118_ == 0)
{
uint8_t v___x_3119_;
v___x_3119_ = 0;
return v___x_3119_;
}
else
{
uint8_t v___x_3120_;
v___x_3120_ = 1;
return v___x_3120_;
}
}
}
}
}
}
}

LEAN_EXPORT uint8_t orb_effect_admissible(uint8_t v_effectKind_3133_, uint8_t v_hasValidLease_3134_, uint8_t v_sessionCreated_3135_, uint8_t v_lineageVerified_3136_, uint8_t v_isArchived_3137_, uint8_t v_idempotencyFresh_3138_, uint8_t v_accountBound_3139_, uint8_t v_accountRejected_3140_, uint8_t v_firstByteLocked_3141_, uint8_t v_grammarAllowed_3142_, uint8_t v_envScrubbed_3143_, uint8_t v_budgetOk_3144_){
_start:
{
uint8_t v___x_3145_; uint8_t v___x_3146_;
v___x_3145_ = 1;
v___x_3146_ = lean_uint8_dec_eq(v_budgetOk_3144_, v___x_3145_);
if (v___x_3146_ == 0)
{
uint8_t v___x_3147_;
v___x_3147_ = 0;
return v___x_3147_;
}
else
{
uint8_t v___x_3148_; uint8_t v___x_3149_;
v___x_3148_ = 0;
v___x_3149_ = lean_uint8_dec_eq(v_effectKind_3133_, v___x_3148_);
if (v___x_3149_ == 0)
{
uint8_t v___x_3150_;
v___x_3150_ = lean_uint8_dec_eq(v_effectKind_3133_, v___x_3145_);
if (v___x_3150_ == 0)
{
uint8_t v___x_3151_; uint8_t v___x_3152_;
v___x_3151_ = 2;
v___x_3152_ = lean_uint8_dec_eq(v_effectKind_3133_, v___x_3151_);
if (v___x_3152_ == 0)
{
uint8_t v___x_3153_; uint8_t v___x_3154_;
v___x_3153_ = 3;
v___x_3154_ = lean_uint8_dec_eq(v_effectKind_3133_, v___x_3153_);
if (v___x_3154_ == 0)
{
uint8_t v___x_3155_; uint8_t v___x_3156_;
v___x_3155_ = 4;
v___x_3156_ = lean_uint8_dec_eq(v_effectKind_3133_, v___x_3155_);
if (v___x_3156_ == 0)
{
uint8_t v___x_3157_; uint8_t v___x_3158_;
v___x_3157_ = 5;
v___x_3158_ = lean_uint8_dec_eq(v_effectKind_3133_, v___x_3157_);
if (v___x_3158_ == 0)
{
return v___x_3148_;
}
else
{
uint8_t v___x_3159_;
v___x_3159_ = lean_uint8_dec_eq(v_hasValidLease_3134_, v___x_3145_);
if (v___x_3159_ == 0)
{
return v___x_3148_;
}
else
{
uint8_t v___x_3160_;
v___x_3160_ = lean_uint8_dec_eq(v_idempotencyFresh_3138_, v___x_3145_);
if (v___x_3160_ == 0)
{
return v___x_3148_;
}
else
{
return v___x_3145_;
}
}
}
}
else
{
uint8_t v___x_3161_;
v___x_3161_ = lean_uint8_dec_eq(v_grammarAllowed_3142_, v___x_3145_);
if (v___x_3161_ == 0)
{
return v___x_3148_;
}
else
{
uint8_t v___x_3162_;
v___x_3162_ = lean_uint8_dec_eq(v_envScrubbed_3143_, v___x_3145_);
if (v___x_3162_ == 0)
{
return v___x_3148_;
}
else
{
uint8_t v___x_3163_;
v___x_3163_ = lean_uint8_dec_eq(v_hasValidLease_3134_, v___x_3145_);
if (v___x_3163_ == 0)
{
return v___x_3148_;
}
else
{
uint8_t v___x_3164_;
v___x_3164_ = lean_uint8_dec_eq(v_isArchived_3137_, v___x_3148_);
if (v___x_3164_ == 0)
{
return v___x_3148_;
}
else
{
return v___x_3145_;
}
}
}
}
}
}
else
{
uint8_t v___x_3165_;
v___x_3165_ = lean_uint8_dec_eq(v_accountBound_3139_, v___x_3145_);
if (v___x_3165_ == 0)
{
return v___x_3148_;
}
else
{
uint8_t v___x_3166_;
v___x_3166_ = lean_uint8_dec_eq(v_accountRejected_3140_, v___x_3148_);
if (v___x_3166_ == 0)
{
return v___x_3148_;
}
else
{
uint8_t v___x_3167_;
v___x_3167_ = lean_uint8_dec_eq(v_firstByteLocked_3141_, v___x_3148_);
if (v___x_3167_ == 0)
{
return v___x_3148_;
}
else
{
return v___x_3145_;
}
}
}
}
}
else
{
uint8_t v___x_3168_;
v___x_3168_ = lean_uint8_dec_eq(v_hasValidLease_3134_, v___x_3145_);
if (v___x_3168_ == 0)
{
return v___x_3148_;
}
else
{
uint8_t v___x_3169_;
v___x_3169_ = lean_uint8_dec_eq(v_sessionCreated_3135_, v___x_3145_);
if (v___x_3169_ == 0)
{
return v___x_3148_;
}
else
{
uint8_t v___x_3170_;
v___x_3170_ = lean_uint8_dec_eq(v_lineageVerified_3136_, v___x_3145_);
if (v___x_3170_ == 0)
{
return v___x_3148_;
}
else
{
uint8_t v___x_3171_;
v___x_3171_ = lean_uint8_dec_eq(v_isArchived_3137_, v___x_3148_);
if (v___x_3171_ == 0)
{
return v___x_3148_;
}
else
{
return v___x_3145_;
}
}
}
}
}
}
else
{
uint8_t v___x_3172_;
v___x_3172_ = lean_uint8_dec_eq(v_hasValidLease_3134_, v___x_3145_);
if (v___x_3172_ == 0)
{
return v___x_3148_;
}
else
{
uint8_t v___x_3173_;
v___x_3173_ = lean_uint8_dec_eq(v_isArchived_3137_, v___x_3148_);
if (v___x_3173_ == 0)
{
return v___x_3148_;
}
else
{
uint8_t v___x_3174_;
v___x_3174_ = lean_uint8_dec_eq(v_idempotencyFresh_3138_, v___x_3145_);
if (v___x_3174_ == 0)
{
return v___x_3148_;
}
else
{
return v___x_3145_;
}
}
}
}
}
else
{
return v___x_3145_;
}
}
}
}

LEAN_EXPORT uint64_t orb_provider_pool_step(uint8_t v_hasBoundAccount_3201_, uint32_t v_boundAccountId_3202_, uint32_t v_candidateAccountId_3203_, uint8_t v_isRejected_3204_, uint8_t v_firstByteSent_3205_, uint8_t v_isFailoverAttempt_3206_, uint32_t v_attempts_3207_, uint32_t v_maxAttempts_3208_, uint64_t v_nowEpoch_3209_, uint64_t v_resetEpoch_3210_){
_start:
{
uint32_t v___y_3212_; uint32_t v___y_3213_; uint32_t v___y_3220_; uint32_t v___y_3223_; uint32_t v___y_3227_; uint32_t v___y_3230_; uint8_t v___x_3232_; uint32_t v___y_3234_; uint32_t v___y_3239_; uint8_t v___y_3240_; uint8_t v___y_3244_; uint32_t v___y_3245_; uint32_t v___y_3251_; uint8_t v___y_3252_; uint32_t v___y_3253_; uint8_t v___y_3258_; uint32_t v___y_3259_; uint8_t v___y_3260_; uint32_t v___y_3266_; uint8_t v___y_3267_; uint8_t v___y_3271_; uint32_t v___y_3272_; uint8_t v___y_3273_; uint32_t v___y_3277_; uint8_t v___y_3278_; uint8_t v___y_3279_; uint32_t v___y_3283_; uint8_t v___y_3284_; uint8_t v___x_3291_; uint32_t v___y_3293_;
v___x_3232_ = 1;
v___x_3291_ = lean_uint8_dec_eq(v_firstByteSent_3205_, v___x_3232_);
if (v___x_3291_ == 0)
{
uint32_t v___x_3295_;
v___x_3295_ = 0;
v___y_3293_ = v___x_3295_;
goto v___jp_3292_;
}
else
{
uint32_t v___x_3296_;
v___x_3296_ = 65536;
v___y_3293_ = v___x_3296_;
goto v___jp_3292_;
}
v___jp_3211_:
{
uint64_t v___x_3214_; uint64_t v___x_3215_; uint64_t v___x_3216_; uint64_t v___x_3217_; uint64_t v___x_3218_;
v___x_3214_ = lean_uint32_to_uint64(v___y_3212_);
v___x_3215_ = lean_uint32_to_uint64(v___y_3213_);
v___x_3216_ = 32ULL;
v___x_3217_ = lean_uint64_shift_left(v___x_3215_, v___x_3216_);
v___x_3218_ = lean_uint64_lor(v___x_3214_, v___x_3217_);
return v___x_3218_;
}
v___jp_3219_:
{
uint32_t v___x_3221_;
v___x_3221_ = 0;
v___y_3212_ = v___y_3220_;
v___y_3213_ = v___x_3221_;
goto v___jp_3211_;
}
v___jp_3222_:
{
uint32_t v___x_3224_; uint8_t v___x_3225_;
v___x_3224_ = 0;
v___x_3225_ = lean_uint32_dec_eq(v_candidateAccountId_3203_, v___x_3224_);
if (v___x_3225_ == 0)
{
v___y_3212_ = v___y_3223_;
v___y_3213_ = v_candidateAccountId_3203_;
goto v___jp_3211_;
}
else
{
v___y_3212_ = v___y_3223_;
v___y_3213_ = v___x_3224_;
goto v___jp_3211_;
}
}
v___jp_3226_:
{
uint32_t v___x_3228_;
v___x_3228_ = 0;
v___y_3212_ = v___y_3227_;
v___y_3213_ = v___x_3228_;
goto v___jp_3211_;
}
v___jp_3229_:
{
uint32_t v___x_3231_;
v___x_3231_ = 0;
v___y_3212_ = v___y_3230_;
v___y_3213_ = v___x_3231_;
goto v___jp_3211_;
}
v___jp_3233_:
{
uint8_t v___x_3235_;
v___x_3235_ = lean_uint8_dec_eq(v_isRejected_3204_, v___x_3232_);
if (v___x_3235_ == 0)
{
v___y_3223_ = v___y_3234_;
goto v___jp_3222_;
}
else
{
uint8_t v___x_3236_;
v___x_3236_ = lean_uint64_dec_lt(v_nowEpoch_3209_, v_resetEpoch_3210_);
if (v___x_3236_ == 0)
{
v___y_3223_ = v___y_3234_;
goto v___jp_3222_;
}
else
{
uint32_t v___x_3237_;
v___x_3237_ = 0;
v___y_3212_ = v___y_3234_;
v___y_3213_ = v___x_3237_;
goto v___jp_3211_;
}
}
}
v___jp_3238_:
{
uint8_t v___x_3241_;
v___x_3241_ = lean_uint8_dec_eq(v_hasBoundAccount_3201_, v___x_3232_);
if (v___x_3241_ == 0)
{
v___y_3234_ = v___y_3239_;
goto v___jp_3233_;
}
else
{
uint8_t v___x_3242_;
v___x_3242_ = lean_uint32_dec_eq(v_candidateAccountId_3203_, v_boundAccountId_3202_);
if (v___x_3242_ == 0)
{
v___y_3227_ = v___y_3239_;
goto v___jp_3226_;
}
else
{
if (v___y_3240_ == 0)
{
v___y_3234_ = v___y_3239_;
goto v___jp_3233_;
}
else
{
v___y_3227_ = v___y_3239_;
goto v___jp_3226_;
}
}
}
}
v___jp_3243_:
{
if (v___y_3244_ == 0)
{
uint8_t v___x_3246_;
v___x_3246_ = lean_uint8_dec_eq(v_isFailoverAttempt_3206_, v___x_3232_);
if (v___x_3246_ == 0)
{
v___y_3239_ = v___y_3245_;
v___y_3240_ = v___x_3246_;
goto v___jp_3238_;
}
else
{
uint32_t v___x_3247_; uint8_t v___x_3248_;
v___x_3247_ = 1;
v___x_3248_ = lean_uint32_dec_le(v___x_3247_, v_maxAttempts_3208_);
if (v___x_3248_ == 0)
{
v___y_3230_ = v___y_3245_;
goto v___jp_3229_;
}
else
{
uint8_t v___x_3249_;
v___x_3249_ = lean_uint32_dec_lt(v_attempts_3207_, v_maxAttempts_3208_);
if (v___x_3249_ == 0)
{
v___y_3230_ = v___y_3245_;
goto v___jp_3229_;
}
else
{
v___y_3239_ = v___y_3245_;
v___y_3240_ = v___y_3244_;
goto v___jp_3238_;
}
}
}
}
else
{
v___y_3220_ = v___y_3245_;
goto v___jp_3219_;
}
}
v___jp_3250_:
{
uint32_t v___x_3254_; uint32_t v___x_3255_; uint32_t v___x_3256_;
v___x_3254_ = 256;
v___x_3255_ = lean_uint32_add(v___y_3253_, v___x_3254_);
v___x_3256_ = lean_uint32_add(v___x_3255_, v___y_3251_);
v___y_3244_ = v___y_3252_;
v___y_3245_ = v___x_3256_;
goto v___jp_3243_;
}
v___jp_3257_:
{
uint32_t v___x_3261_; uint8_t v___x_3262_;
v___x_3261_ = 0;
v___x_3262_ = lean_uint32_dec_eq(v_candidateAccountId_3203_, v___x_3261_);
if (v___x_3262_ == 0)
{
if (v___y_3258_ == 0)
{
uint32_t v___x_3263_;
v___x_3263_ = 2;
v___y_3251_ = v___y_3259_;
v___y_3252_ = v___y_3260_;
v___y_3253_ = v___x_3263_;
goto v___jp_3250_;
}
else
{
uint32_t v___x_3264_;
v___x_3264_ = 1;
v___y_3251_ = v___y_3259_;
v___y_3252_ = v___y_3260_;
v___y_3253_ = v___x_3264_;
goto v___jp_3250_;
}
}
else
{
v___y_3244_ = v___y_3260_;
v___y_3245_ = v___y_3259_;
goto v___jp_3243_;
}
}
v___jp_3265_:
{
uint32_t v___x_3268_; uint32_t v___x_3269_;
v___x_3268_ = 4;
v___x_3269_ = lean_uint32_add(v___x_3268_, v___y_3266_);
v___y_3244_ = v___y_3267_;
v___y_3245_ = v___x_3269_;
goto v___jp_3243_;
}
v___jp_3270_:
{
uint8_t v___x_3274_;
v___x_3274_ = lean_uint8_dec_eq(v_isRejected_3204_, v___x_3232_);
if (v___x_3274_ == 0)
{
v___y_3258_ = v___y_3271_;
v___y_3259_ = v___y_3272_;
v___y_3260_ = v___y_3273_;
goto v___jp_3257_;
}
else
{
uint8_t v___x_3275_;
v___x_3275_ = lean_uint64_dec_lt(v_nowEpoch_3209_, v_resetEpoch_3210_);
if (v___x_3275_ == 0)
{
v___y_3258_ = v___y_3271_;
v___y_3259_ = v___y_3272_;
v___y_3260_ = v___y_3273_;
goto v___jp_3257_;
}
else
{
v___y_3244_ = v___y_3273_;
v___y_3245_ = v___y_3272_;
goto v___jp_3243_;
}
}
}
v___jp_3276_:
{
uint8_t v___x_3280_;
v___x_3280_ = lean_uint8_dec_eq(v_hasBoundAccount_3201_, v___x_3232_);
if (v___x_3280_ == 0)
{
v___y_3271_ = v___x_3280_;
v___y_3272_ = v___y_3277_;
v___y_3273_ = v___y_3278_;
goto v___jp_3270_;
}
else
{
uint8_t v___x_3281_;
v___x_3281_ = lean_uint32_dec_eq(v_candidateAccountId_3203_, v_boundAccountId_3202_);
if (v___x_3281_ == 0)
{
v___y_3244_ = v___y_3278_;
v___y_3245_ = v___y_3277_;
goto v___jp_3243_;
}
else
{
if (v___y_3279_ == 0)
{
v___y_3271_ = v___x_3280_;
v___y_3272_ = v___y_3277_;
v___y_3273_ = v___y_3278_;
goto v___jp_3270_;
}
else
{
v___y_3244_ = v___y_3278_;
v___y_3245_ = v___y_3277_;
goto v___jp_3243_;
}
}
}
}
v___jp_3282_:
{
if (v___y_3284_ == 0)
{
uint8_t v___x_3285_;
v___x_3285_ = lean_uint8_dec_eq(v_isFailoverAttempt_3206_, v___x_3232_);
if (v___x_3285_ == 0)
{
v___y_3277_ = v___y_3283_;
v___y_3278_ = v___y_3284_;
v___y_3279_ = v___x_3285_;
goto v___jp_3276_;
}
else
{
uint32_t v___x_3286_; uint8_t v___x_3287_;
v___x_3286_ = 1;
v___x_3287_ = lean_uint32_dec_le(v___x_3286_, v_maxAttempts_3208_);
if (v___x_3287_ == 0)
{
v___y_3266_ = v___y_3283_;
v___y_3267_ = v___y_3284_;
goto v___jp_3265_;
}
else
{
uint8_t v___x_3288_;
v___x_3288_ = lean_uint32_dec_lt(v_attempts_3207_, v_maxAttempts_3208_);
if (v___x_3288_ == 0)
{
v___y_3266_ = v___y_3283_;
v___y_3267_ = v___y_3284_;
goto v___jp_3265_;
}
else
{
v___y_3277_ = v___y_3283_;
v___y_3278_ = v___y_3284_;
v___y_3279_ = v___y_3284_;
goto v___jp_3276_;
}
}
}
}
else
{
uint32_t v___x_3289_; uint32_t v___x_3290_;
v___x_3289_ = 3;
v___x_3290_ = lean_uint32_add(v___x_3289_, v___y_3283_);
v___y_3220_ = v___x_3290_;
goto v___jp_3219_;
}
}
v___jp_3292_:
{
if (v___x_3291_ == 0)
{
v___y_3283_ = v___y_3293_;
v___y_3284_ = v___x_3291_;
goto v___jp_3282_;
}
else
{
uint8_t v___x_3294_;
v___x_3294_ = lean_uint8_dec_eq(v_isFailoverAttempt_3206_, v___x_3232_);
v___y_3283_ = v___y_3293_;
v___y_3284_ = v___x_3294_;
goto v___jp_3282_;
}
}
}
}

LEAN_EXPORT uint64_t orb_route_argmin_step(uint8_t v_hasBest_3319_, uint32_t v_bestId_3320_, uint64_t v_bestScore_3321_, uint32_t v_candId_3322_, uint64_t v_candScore_3323_, uint8_t v_candAdmissible_3324_){
_start:
{
uint32_t v___y_3326_; uint32_t v___y_3327_; uint8_t v___x_3333_; uint32_t v___y_3335_; uint8_t v___y_3339_; uint8_t v___x_3344_;
v___x_3333_ = 1;
v___x_3344_ = lean_uint8_dec_eq(v_candAdmissible_3324_, v___x_3333_);
if (v___x_3344_ == 0)
{
v___y_3339_ = v___x_3344_;
goto v___jp_3338_;
}
else
{
uint8_t v___x_3345_; uint8_t v___x_3346_;
v___x_3345_ = 0;
v___x_3346_ = lean_uint8_dec_eq(v_hasBest_3319_, v___x_3345_);
if (v___x_3346_ == 0)
{
uint8_t v___x_3347_;
v___x_3347_ = lean_uint64_dec_lt(v_candScore_3323_, v_bestScore_3321_);
v___y_3339_ = v___x_3347_;
goto v___jp_3338_;
}
else
{
v___y_3339_ = v___x_3346_;
goto v___jp_3338_;
}
}
v___jp_3325_:
{
uint64_t v___x_3328_; uint64_t v___x_3329_; uint64_t v___x_3330_; uint64_t v___x_3331_; uint64_t v___x_3332_;
v___x_3328_ = lean_uint32_to_uint64(v___y_3326_);
v___x_3329_ = lean_uint32_to_uint64(v___y_3327_);
v___x_3330_ = 32ULL;
v___x_3331_ = lean_uint64_shift_left(v___x_3329_, v___x_3330_);
v___x_3332_ = lean_uint64_lor(v___x_3328_, v___x_3331_);
return v___x_3332_;
}
v___jp_3334_:
{
uint8_t v___x_3336_;
v___x_3336_ = lean_uint8_dec_eq(v_hasBest_3319_, v___x_3333_);
if (v___x_3336_ == 0)
{
uint32_t v___x_3337_;
v___x_3337_ = 0;
v___y_3326_ = v___y_3335_;
v___y_3327_ = v___x_3337_;
goto v___jp_3325_;
}
else
{
v___y_3326_ = v___y_3335_;
v___y_3327_ = v_bestId_3320_;
goto v___jp_3325_;
}
}
v___jp_3338_:
{
if (v___y_3339_ == 0)
{
uint8_t v___x_3340_;
v___x_3340_ = lean_uint8_dec_eq(v_hasBest_3319_, v___x_3333_);
if (v___x_3340_ == 0)
{
uint32_t v___x_3341_;
v___x_3341_ = 0;
v___y_3335_ = v___x_3341_;
goto v___jp_3334_;
}
else
{
uint32_t v___x_3342_;
v___x_3342_ = 1;
v___y_3335_ = v___x_3342_;
goto v___jp_3334_;
}
}
else
{
uint32_t v___x_3343_;
v___x_3343_ = 257;
v___y_3326_ = v___x_3343_;
v___y_3327_ = v_candId_3322_;
goto v___jp_3325_;
}
}
}
}

LEAN_EXPORT uint64_t orb_mission_control_step(uint8_t v_isArchived_3362_, uint32_t v_activeTrackWriters_3363_, uint8_t v_hasLease_3364_, uint8_t v_msgAlreadyDelivered_3365_, uint8_t v_isResume_3366_, uint8_t v_sessionCreated_3367_, uint8_t v_lineageVerified_3368_, uint8_t v_rolloutExists_3369_, uint8_t v_hasFallbackPrompt_3370_){
_start:
{
uint32_t v___y_3372_; uint32_t v___y_3373_; uint32_t v___y_3380_; uint8_t v___x_3382_; uint32_t v___y_3384_; uint8_t v___x_3388_; uint32_t v___y_3390_;
v___x_3382_ = 1;
v___x_3388_ = lean_uint8_dec_eq(v_isArchived_3362_, v___x_3382_);
if (v___x_3388_ == 0)
{
uint8_t v___x_3409_;
v___x_3409_ = lean_uint8_dec_eq(v_msgAlreadyDelivered_3365_, v___x_3382_);
if (v___x_3409_ == 0)
{
uint8_t v___x_3410_;
v___x_3410_ = lean_uint8_dec_eq(v_hasLease_3364_, v___x_3382_);
if (v___x_3410_ == 0)
{
goto v___jp_3403_;
}
else
{
uint32_t v___x_3411_; uint8_t v___x_3412_;
v___x_3411_ = 0;
v___x_3412_ = lean_uint32_dec_eq(v_activeTrackWriters_3363_, v___x_3411_);
if (v___x_3412_ == 0)
{
goto v___jp_3403_;
}
else
{
uint8_t v___x_3413_;
v___x_3413_ = lean_uint8_dec_eq(v_isResume_3366_, v___x_3382_);
if (v___x_3413_ == 0)
{
uint32_t v___x_3414_;
v___x_3414_ = 257;
v___y_3390_ = v___x_3414_;
goto v___jp_3389_;
}
else
{
uint8_t v___x_3415_;
v___x_3415_ = lean_uint8_dec_eq(v_sessionCreated_3367_, v___x_3382_);
if (v___x_3415_ == 0)
{
goto v___jp_3405_;
}
else
{
uint8_t v___x_3416_;
v___x_3416_ = lean_uint8_dec_eq(v_lineageVerified_3368_, v___x_3382_);
if (v___x_3416_ == 0)
{
goto v___jp_3405_;
}
else
{
uint8_t v___x_3417_;
v___x_3417_ = lean_uint8_dec_eq(v_rolloutExists_3369_, v___x_3382_);
if (v___x_3417_ == 0)
{
goto v___jp_3405_;
}
else
{
uint32_t v___x_3418_;
v___x_3418_ = 258;
v___y_3390_ = v___x_3418_;
goto v___jp_3389_;
}
}
}
}
}
}
}
else
{
uint32_t v___x_3419_;
v___x_3419_ = 4;
v___y_3390_ = v___x_3419_;
goto v___jp_3389_;
}
}
else
{
uint32_t v___x_3420_;
v___x_3420_ = 65536;
v___y_3390_ = v___x_3420_;
goto v___jp_3389_;
}
v___jp_3371_:
{
uint64_t v___x_3374_; uint64_t v___x_3375_; uint64_t v___x_3376_; uint64_t v___x_3377_; uint64_t v___x_3378_;
v___x_3374_ = lean_uint32_to_uint64(v___y_3372_);
v___x_3375_ = lean_uint32_to_uint64(v___y_3373_);
v___x_3376_ = 32ULL;
v___x_3377_ = lean_uint64_shift_left(v___x_3375_, v___x_3376_);
v___x_3378_ = lean_uint64_lor(v___x_3374_, v___x_3377_);
return v___x_3378_;
}
v___jp_3379_:
{
uint32_t v___x_3381_;
v___x_3381_ = 0;
v___y_3372_ = v___y_3380_;
v___y_3373_ = v___x_3381_;
goto v___jp_3371_;
}
v___jp_3383_:
{
uint8_t v___x_3385_;
v___x_3385_ = lean_uint8_dec_eq(v_hasFallbackPrompt_3370_, v___x_3382_);
if (v___x_3385_ == 0)
{
uint32_t v___x_3386_;
v___x_3386_ = 0;
v___y_3372_ = v___y_3384_;
v___y_3373_ = v___x_3386_;
goto v___jp_3371_;
}
else
{
uint32_t v___x_3387_;
v___x_3387_ = 1;
v___y_3372_ = v___y_3384_;
v___y_3373_ = v___x_3387_;
goto v___jp_3371_;
}
}
v___jp_3389_:
{
if (v___x_3388_ == 0)
{
uint8_t v___x_3391_;
v___x_3391_ = lean_uint8_dec_eq(v_msgAlreadyDelivered_3365_, v___x_3382_);
if (v___x_3391_ == 0)
{
uint8_t v___x_3392_;
v___x_3392_ = lean_uint8_dec_eq(v_hasLease_3364_, v___x_3382_);
if (v___x_3392_ == 0)
{
v___y_3380_ = v___y_3390_;
goto v___jp_3379_;
}
else
{
uint32_t v___x_3393_; uint8_t v___x_3394_;
v___x_3393_ = 0;
v___x_3394_ = lean_uint32_dec_eq(v_activeTrackWriters_3363_, v___x_3393_);
if (v___x_3394_ == 0)
{
v___y_3380_ = v___y_3390_;
goto v___jp_3379_;
}
else
{
uint8_t v___x_3395_;
v___x_3395_ = lean_uint8_dec_eq(v_isResume_3366_, v___x_3382_);
if (v___x_3395_ == 0)
{
uint32_t v___x_3396_;
v___x_3396_ = 1;
v___y_3372_ = v___y_3390_;
v___y_3373_ = v___x_3396_;
goto v___jp_3371_;
}
else
{
uint8_t v___x_3397_;
v___x_3397_ = lean_uint8_dec_eq(v_sessionCreated_3367_, v___x_3382_);
if (v___x_3397_ == 0)
{
v___y_3384_ = v___y_3390_;
goto v___jp_3383_;
}
else
{
uint8_t v___x_3398_;
v___x_3398_ = lean_uint8_dec_eq(v_lineageVerified_3368_, v___x_3382_);
if (v___x_3398_ == 0)
{
v___y_3384_ = v___y_3390_;
goto v___jp_3383_;
}
else
{
uint8_t v___x_3399_;
v___x_3399_ = lean_uint8_dec_eq(v_rolloutExists_3369_, v___x_3382_);
if (v___x_3399_ == 0)
{
v___y_3384_ = v___y_3390_;
goto v___jp_3383_;
}
else
{
uint32_t v___x_3400_;
v___x_3400_ = 1;
v___y_3372_ = v___y_3390_;
v___y_3373_ = v___x_3400_;
goto v___jp_3371_;
}
}
}
}
}
}
}
else
{
uint32_t v___x_3401_;
v___x_3401_ = 0;
v___y_3372_ = v___y_3390_;
v___y_3373_ = v___x_3401_;
goto v___jp_3371_;
}
}
else
{
uint32_t v___x_3402_;
v___x_3402_ = 0;
v___y_3372_ = v___y_3390_;
v___y_3373_ = v___x_3402_;
goto v___jp_3371_;
}
}
v___jp_3403_:
{
uint32_t v___x_3404_;
v___x_3404_ = 5;
v___y_3390_ = v___x_3404_;
goto v___jp_3389_;
}
v___jp_3405_:
{
uint8_t v___x_3406_;
v___x_3406_ = lean_uint8_dec_eq(v_hasFallbackPrompt_3370_, v___x_3382_);
if (v___x_3406_ == 0)
{
uint32_t v___x_3407_;
v___x_3407_ = 6;
v___y_3390_ = v___x_3407_;
goto v___jp_3389_;
}
else
{
uint32_t v___x_3408_;
v___x_3408_ = 771;
v___y_3390_ = v___x_3408_;
goto v___jp_3389_;
}
}
}
}

LEAN_EXPORT uint64_t orb_fork_home_step(uint8_t v_isForkOrSide_3491_, uint8_t v_sourceExists_3492_, uint8_t v_sourceIsSymlink_3493_, uint8_t v_sameWorkspace_3494_, uint8_t v_sameNode_3495_, uint8_t v_hasCommittedTransfer_3496_, uint8_t v_requestedOverrideHome_3497_){
_start:
{
uint32_t v___y_3499_; uint32_t v___y_3500_; uint8_t v___y_3507_; uint8_t v___y_3508_; uint32_t v___y_3509_; uint8_t v___x_3513_; uint8_t v___y_3515_; uint8_t v___x_3523_;
v___x_3513_ = 1;
v___x_3523_ = lean_uint8_dec_eq(v_sourceExists_3492_, v___x_3513_);
if (v___x_3523_ == 0)
{
v___y_3515_ = v___x_3523_;
goto v___jp_3514_;
}
else
{
uint8_t v___x_3524_; uint8_t v___x_3525_;
v___x_3524_ = 0;
v___x_3525_ = lean_uint8_dec_eq(v_sourceIsSymlink_3493_, v___x_3524_);
if (v___x_3525_ == 0)
{
v___y_3515_ = v___x_3525_;
goto v___jp_3514_;
}
else
{
uint8_t v___x_3526_;
v___x_3526_ = lean_uint8_dec_eq(v_sameWorkspace_3494_, v___x_3513_);
if (v___x_3526_ == 0)
{
v___y_3515_ = v___x_3526_;
goto v___jp_3514_;
}
else
{
uint8_t v___x_3527_;
v___x_3527_ = lean_uint8_dec_eq(v_sameNode_3495_, v___x_3513_);
v___y_3515_ = v___x_3527_;
goto v___jp_3514_;
}
}
}
v___jp_3498_:
{
uint64_t v___x_3501_; uint64_t v___x_3502_; uint64_t v___x_3503_; uint64_t v___x_3504_; uint64_t v___x_3505_;
v___x_3501_ = lean_uint32_to_uint64(v___y_3499_);
v___x_3502_ = lean_uint32_to_uint64(v___y_3500_);
v___x_3503_ = 32ULL;
v___x_3504_ = lean_uint64_shift_left(v___x_3502_, v___x_3503_);
v___x_3505_ = lean_uint64_lor(v___x_3501_, v___x_3504_);
return v___x_3505_;
}
v___jp_3506_:
{
if (v___y_3507_ == 0)
{
if (v___y_3508_ == 0)
{
uint32_t v___x_3510_;
v___x_3510_ = 78;
v___y_3499_ = v___y_3509_;
v___y_3500_ = v___x_3510_;
goto v___jp_3498_;
}
else
{
uint32_t v___x_3511_;
v___x_3511_ = 0;
v___y_3499_ = v___y_3509_;
v___y_3500_ = v___x_3511_;
goto v___jp_3498_;
}
}
else
{
uint32_t v___x_3512_;
v___x_3512_ = 0;
v___y_3499_ = v___y_3509_;
v___y_3500_ = v___x_3512_;
goto v___jp_3498_;
}
}
v___jp_3514_:
{
uint8_t v___x_3516_; uint8_t v___x_3517_;
v___x_3516_ = 0;
v___x_3517_ = lean_uint8_dec_eq(v_isForkOrSide_3491_, v___x_3516_);
if (v___x_3517_ == 0)
{
if (v___y_3515_ == 0)
{
uint32_t v___x_3518_;
v___x_3518_ = 131072;
v___y_3507_ = v___x_3517_;
v___y_3508_ = v___y_3515_;
v___y_3509_ = v___x_3518_;
goto v___jp_3506_;
}
else
{
uint8_t v___x_3519_;
v___x_3519_ = lean_uint8_dec_eq(v_hasCommittedTransfer_3496_, v___x_3513_);
if (v___x_3519_ == 0)
{
uint32_t v___x_3520_;
v___x_3520_ = 131842;
v___y_3507_ = v___x_3517_;
v___y_3508_ = v___y_3515_;
v___y_3509_ = v___x_3520_;
goto v___jp_3506_;
}
else
{
uint32_t v___x_3521_;
v___x_3521_ = 131843;
v___y_3507_ = v___x_3517_;
v___y_3508_ = v___y_3515_;
v___y_3509_ = v___x_3521_;
goto v___jp_3506_;
}
}
}
else
{
uint32_t v___x_3522_;
v___x_3522_ = 131329;
v___y_3507_ = v___x_3517_;
v___y_3508_ = v___y_3515_;
v___y_3509_ = v___x_3522_;
goto v___jp_3506_;
}
}
}
}

LEAN_EXPORT uint64_t orb_privd_command_step(uint8_t v_leaseValid_3544_, uint8_t v_grantScope_3545_, uint8_t v_commandClass_3546_, uint8_t v_unitMatchesAllowed_3547_, uint8_t v_hasShellMetacharOrFlagBypass_3548_, uint8_t v_hasPathTraversalOrSymlink_3549_, uint8_t v_hasUnsafeEnvVar_3550_, uint8_t v_requireForceCmd_3551_){
_start:
{
uint32_t v___y_3553_; uint32_t v___y_3554_; uint32_t v___y_3561_; uint8_t v___x_3570_; uint8_t v___x_3571_;
v___x_3570_ = 1;
v___x_3571_ = lean_uint8_dec_eq(v_leaseValid_3544_, v___x_3570_);
if (v___x_3571_ == 0)
{
goto v___jp_3566_;
}
else
{
uint8_t v___x_3572_; uint8_t v___x_3573_;
v___x_3572_ = 0;
v___x_3573_ = lean_uint8_dec_eq(v_hasShellMetacharOrFlagBypass_3548_, v___x_3572_);
if (v___x_3573_ == 0)
{
goto v___jp_3566_;
}
else
{
uint8_t v___x_3574_;
v___x_3574_ = lean_uint8_dec_eq(v_hasPathTraversalOrSymlink_3549_, v___x_3572_);
if (v___x_3574_ == 0)
{
goto v___jp_3566_;
}
else
{
uint8_t v___x_3575_;
v___x_3575_ = lean_uint8_dec_eq(v_hasUnsafeEnvVar_3550_, v___x_3572_);
if (v___x_3575_ == 0)
{
goto v___jp_3566_;
}
else
{
uint8_t v___x_3576_; uint8_t v___x_3588_;
v___x_3576_ = 2;
v___x_3588_ = lean_uint8_dec_le(v_grantScope_3545_, v___x_3576_);
if (v___x_3588_ == 0)
{
uint32_t v___x_3589_;
v___x_3589_ = 1536;
v___y_3561_ = v___x_3589_;
goto v___jp_3560_;
}
else
{
uint8_t v___x_3590_;
v___x_3590_ = lean_uint8_dec_eq(v_commandClass_3546_, v___x_3570_);
if (v___x_3590_ == 0)
{
uint8_t v___x_3591_;
v___x_3591_ = lean_uint8_dec_eq(v_commandClass_3546_, v___x_3576_);
if (v___x_3591_ == 0)
{
goto v___jp_3583_;
}
else
{
uint8_t v___x_3592_;
v___x_3592_ = lean_uint8_dec_le(v___x_3570_, v_grantScope_3545_);
if (v___x_3592_ == 0)
{
goto v___jp_3583_;
}
else
{
uint8_t v___x_3593_;
v___x_3593_ = lean_uint8_dec_eq(v_unitMatchesAllowed_3547_, v___x_3570_);
if (v___x_3593_ == 0)
{
goto v___jp_3583_;
}
else
{
uint32_t v___x_3594_;
v___x_3594_ = 1794;
v___y_3561_ = v___x_3594_;
goto v___jp_3560_;
}
}
}
}
else
{
uint32_t v___x_3595_;
v___x_3595_ = 1793;
v___y_3561_ = v___x_3595_;
goto v___jp_3560_;
}
}
v___jp_3577_:
{
uint8_t v___x_3578_; uint8_t v___x_3579_;
v___x_3578_ = 4;
v___x_3579_ = lean_uint8_dec_eq(v_commandClass_3546_, v___x_3578_);
if (v___x_3579_ == 0)
{
goto v___jp_3568_;
}
else
{
uint8_t v___x_3580_;
v___x_3580_ = lean_uint8_dec_eq(v_grantScope_3545_, v___x_3576_);
if (v___x_3580_ == 0)
{
goto v___jp_3568_;
}
else
{
uint8_t v___x_3581_;
v___x_3581_ = lean_uint8_dec_eq(v_requireForceCmd_3551_, v___x_3572_);
if (v___x_3581_ == 0)
{
goto v___jp_3568_;
}
else
{
uint32_t v___x_3582_;
v___x_3582_ = 1795;
v___y_3561_ = v___x_3582_;
goto v___jp_3560_;
}
}
}
}
v___jp_3583_:
{
uint8_t v___x_3584_; uint8_t v___x_3585_;
v___x_3584_ = 3;
v___x_3585_ = lean_uint8_dec_eq(v_commandClass_3546_, v___x_3584_);
if (v___x_3585_ == 0)
{
goto v___jp_3577_;
}
else
{
uint8_t v___x_3586_;
v___x_3586_ = lean_uint8_dec_le(v___x_3570_, v_grantScope_3545_);
if (v___x_3586_ == 0)
{
goto v___jp_3577_;
}
else
{
uint32_t v___x_3587_;
v___x_3587_ = 1794;
v___y_3561_ = v___x_3587_;
goto v___jp_3560_;
}
}
}
}
}
}
}
v___jp_3552_:
{
uint64_t v___x_3555_; uint64_t v___x_3556_; uint64_t v___x_3557_; uint64_t v___x_3558_; uint64_t v___x_3559_;
v___x_3555_ = lean_uint32_to_uint64(v___y_3553_);
v___x_3556_ = lean_uint32_to_uint64(v___y_3554_);
v___x_3557_ = 32ULL;
v___x_3558_ = lean_uint64_shift_left(v___x_3556_, v___x_3557_);
v___x_3559_ = lean_uint64_lor(v___x_3555_, v___x_3558_);
return v___x_3559_;
}
v___jp_3560_:
{
uint32_t v___x_3562_; uint8_t v___x_3563_;
v___x_3562_ = 1536;
v___x_3563_ = lean_uint32_dec_eq(v___y_3561_, v___x_3562_);
if (v___x_3563_ == 0)
{
uint32_t v___x_3564_;
v___x_3564_ = 0;
v___y_3553_ = v___y_3561_;
v___y_3554_ = v___x_3564_;
goto v___jp_3552_;
}
else
{
uint32_t v___x_3565_;
v___x_3565_ = 126;
v___y_3553_ = v___y_3561_;
v___y_3554_ = v___x_3565_;
goto v___jp_3552_;
}
}
v___jp_3566_:
{
uint32_t v___x_3567_;
v___x_3567_ = 1536;
v___y_3561_ = v___x_3567_;
goto v___jp_3560_;
}
v___jp_3568_:
{
uint32_t v___x_3569_;
v___x_3569_ = 1536;
v___y_3561_ = v___x_3569_;
goto v___jp_3560_;
}
}
}

LEAN_EXPORT uint64_t orb_ssh_identity_step(uint8_t v_isWorkerOrContainerTarget_3614_, uint8_t v_bundleHasControlPlaneKey_3615_, uint8_t v_parentDirIsSymlink_3616_, uint8_t v_pubKeyIsEd25519WithoutPrivate_3617_, uint8_t v_proxyJumpValid_3618_, uint8_t v_codexCyberProgramValid_3619_, uint8_t v_codexGoalBudgetExhausted_3620_){
_start:
{
uint32_t v___y_3622_; uint32_t v___y_3623_; uint32_t v___y_3630_; uint32_t v___y_3633_; uint8_t v___y_3641_; uint8_t v___x_3646_; uint8_t v___x_3647_;
v___x_3646_ = 0;
v___x_3647_ = lean_uint8_dec_eq(v_parentDirIsSymlink_3616_, v___x_3646_);
if (v___x_3647_ == 0)
{
v___y_3641_ = v___x_3647_;
goto v___jp_3640_;
}
else
{
uint8_t v___x_3648_; uint8_t v___x_3649_;
v___x_3648_ = 1;
v___x_3649_ = lean_uint8_dec_eq(v_pubKeyIsEd25519WithoutPrivate_3617_, v___x_3648_);
if (v___x_3649_ == 0)
{
v___y_3641_ = v___x_3649_;
goto v___jp_3640_;
}
else
{
uint8_t v___x_3650_;
v___x_3650_ = lean_uint8_dec_eq(v_proxyJumpValid_3618_, v___x_3648_);
if (v___x_3650_ == 0)
{
v___y_3641_ = v___x_3650_;
goto v___jp_3640_;
}
else
{
uint8_t v___x_3651_;
v___x_3651_ = lean_uint8_dec_eq(v_codexCyberProgramValid_3619_, v___x_3648_);
if (v___x_3651_ == 0)
{
v___y_3641_ = v___x_3651_;
goto v___jp_3640_;
}
else
{
uint8_t v___x_3652_;
v___x_3652_ = lean_uint8_dec_eq(v_codexGoalBudgetExhausted_3620_, v___x_3646_);
if (v___x_3652_ == 0)
{
v___y_3641_ = v___x_3652_;
goto v___jp_3640_;
}
else
{
uint8_t v___x_3653_;
v___x_3653_ = lean_uint8_dec_eq(v_isWorkerOrContainerTarget_3614_, v___x_3648_);
if (v___x_3653_ == 0)
{
v___y_3641_ = v___x_3652_;
goto v___jp_3640_;
}
else
{
uint8_t v___x_3654_;
v___x_3654_ = lean_uint8_dec_eq(v_bundleHasControlPlaneKey_3615_, v___x_3648_);
if (v___x_3654_ == 0)
{
v___y_3641_ = v___x_3652_;
goto v___jp_3640_;
}
else
{
goto v___jp_3635_;
}
}
}
}
}
}
}
v___jp_3621_:
{
uint64_t v___x_3624_; uint64_t v___x_3625_; uint64_t v___x_3626_; uint64_t v___x_3627_; uint64_t v___x_3628_;
v___x_3624_ = lean_uint32_to_uint64(v___y_3622_);
v___x_3625_ = lean_uint32_to_uint64(v___y_3623_);
v___x_3626_ = 32ULL;
v___x_3627_ = lean_uint64_shift_left(v___x_3625_, v___x_3626_);
v___x_3628_ = lean_uint64_lor(v___x_3624_, v___x_3627_);
return v___x_3628_;
}
v___jp_3629_:
{
uint32_t v___x_3631_;
v___x_3631_ = 78;
v___y_3622_ = v___y_3630_;
v___y_3623_ = v___x_3631_;
goto v___jp_3621_;
}
v___jp_3632_:
{
uint32_t v___x_3634_;
v___x_3634_ = 0;
v___y_3622_ = v___y_3633_;
v___y_3623_ = v___x_3634_;
goto v___jp_3621_;
}
v___jp_3635_:
{
uint8_t v___x_3636_; uint8_t v___x_3637_;
v___x_3636_ = 1;
v___x_3637_ = lean_uint8_dec_eq(v_isWorkerOrContainerTarget_3614_, v___x_3636_);
if (v___x_3637_ == 0)
{
uint32_t v___x_3638_;
v___x_3638_ = 1024;
v___y_3630_ = v___x_3638_;
goto v___jp_3629_;
}
else
{
uint32_t v___x_3639_;
v___x_3639_ = 1536;
v___y_3630_ = v___x_3639_;
goto v___jp_3629_;
}
}
v___jp_3640_:
{
if (v___y_3641_ == 0)
{
goto v___jp_3635_;
}
else
{
uint8_t v___x_3642_; uint8_t v___x_3643_;
v___x_3642_ = 1;
v___x_3643_ = lean_uint8_dec_eq(v_isWorkerOrContainerTarget_3614_, v___x_3642_);
if (v___x_3643_ == 0)
{
uint32_t v___x_3644_;
v___x_3644_ = 1282;
v___y_3633_ = v___x_3644_;
goto v___jp_3632_;
}
else
{
uint32_t v___x_3645_;
v___x_3645_ = 1793;
v___y_3633_ = v___x_3645_;
goto v___jp_3632_;
}
}
}
}
}

LEAN_EXPORT uint64_t orb_agent_event_normalize_step(uint8_t v_harnessKind_3671_, uint8_t v_rawEventKind_3672_, uint8_t v_isCompleted_3673_, uint8_t v_hasNonEmptyText_3674_, uint32_t v_sessionMatchesExpected_3675_, uint32_t v_isDuplicateTurnOrTool_3676_, uint32_t v_payloadBytes_3677_, uint32_t v_maxPayloadBytes_3678_){
_start:
{
uint32_t v___y_3680_; uint32_t v___y_3681_; uint8_t v_bounded_3687_; uint32_t v___y_3689_; uint8_t v___x_3692_; uint8_t v_harnessValid_3693_; uint8_t v___y_3695_; uint32_t v___x_3729_; uint8_t v___x_3730_;
v_bounded_3687_ = lean_uint32_dec_le(v_payloadBytes_3677_, v_maxPayloadBytes_3678_);
v___x_3692_ = 5;
v_harnessValid_3693_ = lean_uint8_dec_le(v_harnessKind_3671_, v___x_3692_);
v___x_3729_ = 1;
v___x_3730_ = lean_uint32_dec_eq(v_sessionMatchesExpected_3675_, v___x_3729_);
if (v___x_3730_ == 0)
{
uint8_t v___x_3731_; uint8_t v___x_3732_;
v___x_3731_ = 0;
v___x_3732_ = lean_uint8_dec_eq(v_rawEventKind_3672_, v___x_3731_);
if (v___x_3732_ == 0)
{
uint8_t v___x_3733_; uint8_t v___x_3734_;
v___x_3733_ = 1;
v___x_3734_ = lean_uint8_dec_eq(v_rawEventKind_3672_, v___x_3733_);
if (v___x_3734_ == 0)
{
uint8_t v___x_3735_; uint8_t v___x_3736_;
v___x_3735_ = 7;
v___x_3736_ = lean_uint8_dec_eq(v_rawEventKind_3672_, v___x_3735_);
v___y_3695_ = v___x_3736_;
goto v___jp_3694_;
}
else
{
v___y_3695_ = v___x_3734_;
goto v___jp_3694_;
}
}
else
{
v___y_3695_ = v___x_3732_;
goto v___jp_3694_;
}
}
else
{
v___y_3695_ = v___x_3730_;
goto v___jp_3694_;
}
v___jp_3679_:
{
uint64_t v___x_3682_; uint64_t v___x_3683_; uint64_t v___x_3684_; uint64_t v___x_3685_; uint64_t v___x_3686_;
v___x_3682_ = lean_uint32_to_uint64(v___y_3680_);
v___x_3683_ = lean_uint32_to_uint64(v___y_3681_);
v___x_3684_ = 32ULL;
v___x_3685_ = lean_uint64_shift_left(v___x_3683_, v___x_3684_);
v___x_3686_ = lean_uint64_lor(v___x_3682_, v___x_3685_);
return v___x_3686_;
}
v___jp_3688_:
{
if (v_bounded_3687_ == 0)
{
v___y_3680_ = v___y_3689_;
v___y_3681_ = v_maxPayloadBytes_3678_;
goto v___jp_3679_;
}
else
{
v___y_3680_ = v___y_3689_;
v___y_3681_ = v_payloadBytes_3677_;
goto v___jp_3679_;
}
}
v___jp_3690_:
{
uint32_t v___x_3691_;
v___x_3691_ = 2049;
v___y_3689_ = v___x_3691_;
goto v___jp_3688_;
}
v___jp_3694_:
{
if (v_bounded_3687_ == 0)
{
uint32_t v___x_3696_;
v___x_3696_ = 2048;
v___y_3689_ = v___x_3696_;
goto v___jp_3688_;
}
else
{
if (v_harnessValid_3693_ == 0)
{
goto v___jp_3690_;
}
else
{
if (v___y_3695_ == 0)
{
goto v___jp_3690_;
}
else
{
uint32_t v___x_3697_; uint8_t v_notDup_3698_;
v___x_3697_ = 0;
v_notDup_3698_ = lean_uint32_dec_eq(v_isDuplicateTurnOrTool_3676_, v___x_3697_);
if (v_notDup_3698_ == 0)
{
goto v___jp_3690_;
}
else
{
uint8_t v___x_3699_; uint8_t v___x_3700_;
v___x_3699_ = 0;
v___x_3700_ = lean_uint8_dec_eq(v_rawEventKind_3672_, v___x_3699_);
if (v___x_3700_ == 0)
{
uint8_t v___x_3701_; uint8_t v___x_3702_;
v___x_3701_ = 1;
v___x_3702_ = lean_uint8_dec_eq(v_rawEventKind_3672_, v___x_3701_);
if (v___x_3702_ == 0)
{
uint8_t v___x_3703_; uint8_t v___x_3704_;
v___x_3703_ = 2;
v___x_3704_ = lean_uint8_dec_eq(v_rawEventKind_3672_, v___x_3703_);
if (v___x_3704_ == 0)
{
uint8_t v___x_3705_; uint8_t v___x_3706_;
v___x_3705_ = 3;
v___x_3706_ = lean_uint8_dec_eq(v_rawEventKind_3672_, v___x_3705_);
if (v___x_3706_ == 0)
{
uint8_t v___x_3707_; uint8_t v___x_3708_;
v___x_3707_ = 4;
v___x_3708_ = lean_uint8_dec_eq(v_rawEventKind_3672_, v___x_3707_);
if (v___x_3708_ == 0)
{
uint8_t v___x_3709_;
v___x_3709_ = lean_uint8_dec_eq(v_rawEventKind_3672_, v___x_3692_);
if (v___x_3709_ == 0)
{
uint8_t v___x_3710_; uint8_t v___x_3711_;
v___x_3710_ = 6;
v___x_3711_ = lean_uint8_dec_eq(v_rawEventKind_3672_, v___x_3710_);
if (v___x_3711_ == 0)
{
uint8_t v___x_3712_; uint8_t v___x_3713_;
v___x_3712_ = 7;
v___x_3713_ = lean_uint8_dec_eq(v_rawEventKind_3672_, v___x_3712_);
if (v___x_3713_ == 0)
{
uint32_t v___x_3714_;
v___x_3714_ = 2049;
v___y_3689_ = v___x_3714_;
goto v___jp_3688_;
}
else
{
uint32_t v___x_3715_;
v___x_3715_ = 3338;
v___y_3689_ = v___x_3715_;
goto v___jp_3688_;
}
}
else
{
uint32_t v___x_3716_;
v___x_3716_ = 3337;
v___y_3689_ = v___x_3716_;
goto v___jp_3688_;
}
}
else
{
uint32_t v___x_3717_;
v___x_3717_ = 2312;
v___y_3689_ = v___x_3717_;
goto v___jp_3688_;
}
}
else
{
uint8_t v___x_3718_;
v___x_3718_ = lean_uint8_dec_eq(v_isCompleted_3673_, v___x_3701_);
if (v___x_3718_ == 0)
{
uint32_t v___x_3719_;
v___x_3719_ = 3335;
v___y_3689_ = v___x_3719_;
goto v___jp_3688_;
}
else
{
uint32_t v___x_3720_;
v___x_3720_ = 3334;
v___y_3689_ = v___x_3720_;
goto v___jp_3688_;
}
}
}
else
{
uint8_t v___x_3721_;
v___x_3721_ = lean_uint8_dec_eq(v_hasNonEmptyText_3674_, v___x_3701_);
if (v___x_3721_ == 0)
{
uint32_t v___x_3722_;
v___x_3722_ = 2049;
v___y_3689_ = v___x_3722_;
goto v___jp_3688_;
}
else
{
uint32_t v___x_3723_;
v___x_3723_ = 3333;
v___y_3689_ = v___x_3723_;
goto v___jp_3688_;
}
}
}
else
{
uint8_t v___x_3724_;
v___x_3724_ = lean_uint8_dec_eq(v_hasNonEmptyText_3674_, v___x_3701_);
if (v___x_3724_ == 0)
{
uint32_t v___x_3725_;
v___x_3725_ = 2049;
v___y_3689_ = v___x_3725_;
goto v___jp_3688_;
}
else
{
uint32_t v___x_3726_;
v___x_3726_ = 2820;
v___y_3689_ = v___x_3726_;
goto v___jp_3688_;
}
}
}
else
{
uint32_t v___x_3727_;
v___x_3727_ = 2307;
v___y_3689_ = v___x_3727_;
goto v___jp_3688_;
}
}
else
{
uint32_t v___x_3728_;
v___x_3728_ = 2306;
v___y_3689_ = v___x_3728_;
goto v___jp_3688_;
}
}
}
}
}
}
}
}

LEAN_EXPORT uint64_t orb_transcript_reduce_step(uint64_t v_lastAppliedSeq_3820_, uint64_t v_incomingSeq_3821_, uint8_t v_thinkingOpen_3822_, uint8_t v_normalizedAction_3823_, uint8_t v_isReplayFromLog_3824_){
_start:
{
uint32_t v___y_3826_; uint32_t v___y_3827_; uint32_t v___y_3834_; uint32_t v___y_3840_; uint8_t v_seqAdvances_3845_; uint64_t v___y_3847_;
v_seqAdvances_3845_ = lean_uint64_dec_lt(v_lastAppliedSeq_3820_, v_incomingSeq_3821_);
if (v_seqAdvances_3845_ == 0)
{
v___y_3847_ = v_lastAppliedSeq_3820_;
goto v___jp_3846_;
}
else
{
v___y_3847_ = v_incomingSeq_3821_;
goto v___jp_3846_;
}
v___jp_3825_:
{
uint64_t v___x_3828_; uint64_t v___x_3829_; uint64_t v___x_3830_; uint64_t v___x_3831_; uint64_t v___x_3832_;
v___x_3828_ = lean_uint32_to_uint64(v___y_3827_);
v___x_3829_ = lean_uint32_to_uint64(v___y_3826_);
v___x_3830_ = 32ULL;
v___x_3831_ = lean_uint64_shift_left(v___x_3829_, v___x_3830_);
v___x_3832_ = lean_uint64_lor(v___x_3828_, v___x_3831_);
return v___x_3832_;
}
v___jp_3833_:
{
uint8_t v___x_3835_; uint8_t v___x_3836_;
v___x_3835_ = 1;
v___x_3836_ = lean_uint8_dec_eq(v_thinkingOpen_3822_, v___x_3835_);
if (v___x_3836_ == 0)
{
uint32_t v___x_3837_;
v___x_3837_ = 258;
v___y_3826_ = v___y_3834_;
v___y_3827_ = v___x_3837_;
goto v___jp_3825_;
}
else
{
uint32_t v___x_3838_;
v___x_3838_ = 1282;
v___y_3826_ = v___y_3834_;
v___y_3827_ = v___x_3838_;
goto v___jp_3825_;
}
}
v___jp_3839_:
{
uint8_t v___x_3841_; uint8_t v___x_3842_;
v___x_3841_ = 1;
v___x_3842_ = lean_uint8_dec_eq(v_thinkingOpen_3822_, v___x_3841_);
if (v___x_3842_ == 0)
{
uint32_t v___x_3843_;
v___x_3843_ = 259;
v___y_3826_ = v___y_3840_;
v___y_3827_ = v___x_3843_;
goto v___jp_3825_;
}
else
{
uint32_t v___x_3844_;
v___x_3844_ = 771;
v___y_3826_ = v___y_3840_;
v___y_3827_ = v___x_3844_;
goto v___jp_3825_;
}
}
v___jp_3846_:
{
uint32_t v_nextSeq32_3848_;
v_nextSeq32_3848_ = lean_uint64_to_uint32(v___y_3847_);
if (v_seqAdvances_3845_ == 0)
{
uint8_t v___x_3849_; uint8_t v___x_3850_;
v___x_3849_ = 1;
v___x_3850_ = lean_uint8_dec_eq(v_thinkingOpen_3822_, v___x_3849_);
if (v___x_3850_ == 0)
{
uint32_t v___x_3851_;
v___x_3851_ = 0;
v___y_3826_ = v_nextSeq32_3848_;
v___y_3827_ = v___x_3851_;
goto v___jp_3825_;
}
else
{
uint32_t v___x_3852_;
v___x_3852_ = 512;
v___y_3826_ = v_nextSeq32_3848_;
v___y_3827_ = v___x_3852_;
goto v___jp_3825_;
}
}
else
{
uint8_t v___x_3853_; uint8_t v___x_3854_;
v___x_3853_ = 4;
v___x_3854_ = lean_uint8_dec_eq(v_normalizedAction_3823_, v___x_3853_);
if (v___x_3854_ == 0)
{
uint8_t v___x_3855_; uint8_t v___x_3856_;
v___x_3855_ = 5;
v___x_3856_ = lean_uint8_dec_eq(v_normalizedAction_3823_, v___x_3855_);
if (v___x_3856_ == 0)
{
uint8_t v___x_3857_; uint8_t v___x_3858_;
v___x_3857_ = 6;
v___x_3858_ = lean_uint8_dec_eq(v_normalizedAction_3823_, v___x_3857_);
if (v___x_3858_ == 0)
{
uint8_t v___x_3859_; uint8_t v___x_3860_;
v___x_3859_ = 7;
v___x_3860_ = lean_uint8_dec_eq(v_normalizedAction_3823_, v___x_3859_);
if (v___x_3860_ == 0)
{
uint8_t v___x_3861_; uint8_t v___x_3862_;
v___x_3861_ = 9;
v___x_3862_ = lean_uint8_dec_eq(v_normalizedAction_3823_, v___x_3861_);
if (v___x_3862_ == 0)
{
uint8_t v___x_3863_; uint8_t v___x_3864_;
v___x_3863_ = 10;
v___x_3864_ = lean_uint8_dec_eq(v_normalizedAction_3823_, v___x_3863_);
if (v___x_3864_ == 0)
{
uint8_t v___x_3865_; uint8_t v___x_3866_;
v___x_3865_ = 2;
v___x_3866_ = lean_uint8_dec_eq(v_normalizedAction_3823_, v___x_3865_);
if (v___x_3866_ == 0)
{
uint8_t v___x_3867_; uint8_t v___x_3868_;
v___x_3867_ = 3;
v___x_3868_ = lean_uint8_dec_eq(v_normalizedAction_3823_, v___x_3867_);
if (v___x_3868_ == 0)
{
uint8_t v___x_3869_; uint8_t v___x_3870_;
v___x_3869_ = 8;
v___x_3870_ = lean_uint8_dec_eq(v_normalizedAction_3823_, v___x_3869_);
if (v___x_3870_ == 0)
{
uint8_t v___x_3871_; uint8_t v___x_3872_;
v___x_3871_ = 1;
v___x_3872_ = lean_uint8_dec_eq(v_thinkingOpen_3822_, v___x_3871_);
if (v___x_3872_ == 0)
{
uint32_t v___x_3873_;
v___x_3873_ = 0;
v___y_3826_ = v_nextSeq32_3848_;
v___y_3827_ = v___x_3873_;
goto v___jp_3825_;
}
else
{
uint32_t v___x_3874_;
v___x_3874_ = 512;
v___y_3826_ = v_nextSeq32_3848_;
v___y_3827_ = v___x_3874_;
goto v___jp_3825_;
}
}
else
{
v___y_3840_ = v_nextSeq32_3848_;
goto v___jp_3839_;
}
}
else
{
v___y_3840_ = v_nextSeq32_3848_;
goto v___jp_3839_;
}
}
else
{
v___y_3840_ = v_nextSeq32_3848_;
goto v___jp_3839_;
}
}
else
{
v___y_3834_ = v_nextSeq32_3848_;
goto v___jp_3833_;
}
}
else
{
v___y_3834_ = v_nextSeq32_3848_;
goto v___jp_3833_;
}
}
else
{
v___y_3834_ = v_nextSeq32_3848_;
goto v___jp_3833_;
}
}
else
{
v___y_3834_ = v_nextSeq32_3848_;
goto v___jp_3833_;
}
}
else
{
v___y_3834_ = v_nextSeq32_3848_;
goto v___jp_3833_;
}
}
else
{
uint32_t v___x_3875_;
v___x_3875_ = 769;
v___y_3826_ = v_nextSeq32_3848_;
v___y_3827_ = v___x_3875_;
goto v___jp_3825_;
}
}
}
}
}

LEAN_EXPORT uint64_t orb_cursor_page_step(uint64_t v_sinceSeq_3888_, uint64_t v_beforeSeq_3889_, uint64_t v_itemSeq_3890_, uint32_t v_hasSinceCursor_3891_, uint32_t v_hasBeforeCursor_3892_, uint32_t v_isPartialResponse_3893_, uint32_t v_existingCount_3894_){
_start:
{
uint32_t v___y_3896_; uint32_t v___y_3897_; uint32_t v___x_3903_; uint32_t v___y_3905_; uint8_t v___y_3908_; uint8_t v___y_3909_; uint32_t v___y_3910_; uint8_t v___y_3918_; uint32_t v___y_3919_; uint8_t v___y_3920_; uint8_t v___y_3924_; uint8_t v___y_3925_; uint32_t v___y_3926_; uint8_t v___y_3927_; uint8_t v___y_3929_; uint32_t v___y_3930_; uint8_t v___y_3931_; uint8_t v___y_3935_; uint8_t v___x_3941_;
v___x_3903_ = 1;
v___x_3941_ = lean_uint32_dec_eq(v_hasSinceCursor_3891_, v___x_3903_);
if (v___x_3941_ == 0)
{
goto v___jp_3939_;
}
else
{
uint8_t v___x_3942_;
v___x_3942_ = lean_uint32_dec_eq(v_hasBeforeCursor_3892_, v___x_3903_);
if (v___x_3942_ == 0)
{
goto v___jp_3939_;
}
else
{
uint8_t v___x_3943_;
v___x_3943_ = lean_uint64_dec_le(v_beforeSeq_3889_, v_sinceSeq_3888_);
if (v___x_3943_ == 0)
{
goto v___jp_3939_;
}
else
{
uint8_t v___x_3944_;
v___x_3944_ = 0;
v___y_3935_ = v___x_3944_;
goto v___jp_3934_;
}
}
}
v___jp_3895_:
{
uint64_t v___x_3898_; uint64_t v___x_3899_; uint64_t v___x_3900_; uint64_t v___x_3901_; uint64_t v___x_3902_;
v___x_3898_ = lean_uint32_to_uint64(v___y_3896_);
v___x_3899_ = lean_uint32_to_uint64(v___y_3897_);
v___x_3900_ = 32ULL;
v___x_3901_ = lean_uint64_shift_left(v___x_3899_, v___x_3900_);
v___x_3902_ = lean_uint64_lor(v___x_3898_, v___x_3901_);
return v___x_3902_;
}
v___jp_3904_:
{
uint32_t v___x_3906_;
v___x_3906_ = lean_uint32_add(v_existingCount_3894_, v___x_3903_);
v___y_3896_ = v___y_3905_;
v___y_3897_ = v___x_3906_;
goto v___jp_3895_;
}
v___jp_3907_:
{
if (v___y_3908_ == 0)
{
uint32_t v___x_3911_; uint32_t v___x_3912_;
v___x_3911_ = 512;
v___x_3912_ = lean_uint32_lor(v___x_3911_, v___y_3910_);
if (v___y_3909_ == 0)
{
v___y_3896_ = v___x_3912_;
v___y_3897_ = v_existingCount_3894_;
goto v___jp_3895_;
}
else
{
v___y_3905_ = v___x_3912_;
goto v___jp_3904_;
}
}
else
{
if (v___y_3909_ == 0)
{
uint32_t v___x_3913_; uint32_t v___x_3914_;
v___x_3913_ = 514;
v___x_3914_ = lean_uint32_lor(v___x_3913_, v___y_3910_);
v___y_3896_ = v___x_3914_;
v___y_3897_ = v_existingCount_3894_;
goto v___jp_3895_;
}
else
{
uint32_t v___x_3915_; uint32_t v___x_3916_;
v___x_3915_ = 769;
v___x_3916_ = lean_uint32_lor(v___x_3915_, v___y_3910_);
v___y_3905_ = v___x_3916_;
goto v___jp_3904_;
}
}
}
v___jp_3917_:
{
uint8_t v___x_3921_;
v___x_3921_ = lean_uint32_dec_eq(v_isPartialResponse_3893_, v___x_3903_);
if (v___x_3921_ == 0)
{
v___y_3908_ = v___y_3918_;
v___y_3909_ = v___y_3920_;
v___y_3910_ = v___y_3919_;
goto v___jp_3907_;
}
else
{
uint32_t v___x_3922_;
v___x_3922_ = 1024;
v___y_3908_ = v___y_3918_;
v___y_3909_ = v___y_3920_;
v___y_3910_ = v___x_3922_;
goto v___jp_3907_;
}
}
v___jp_3923_:
{
if (v___y_3925_ == 0)
{
v___y_3918_ = v___y_3925_;
v___y_3919_ = v___y_3926_;
v___y_3920_ = v___y_3925_;
goto v___jp_3917_;
}
else
{
if (v___y_3924_ == 0)
{
v___y_3918_ = v___y_3925_;
v___y_3919_ = v___y_3926_;
v___y_3920_ = v___y_3924_;
goto v___jp_3917_;
}
else
{
v___y_3918_ = v___y_3925_;
v___y_3919_ = v___y_3926_;
v___y_3920_ = v___y_3927_;
goto v___jp_3917_;
}
}
}
v___jp_3928_:
{
uint8_t v___x_3932_;
v___x_3932_ = lean_uint32_dec_eq(v_hasBeforeCursor_3892_, v___y_3930_);
if (v___x_3932_ == 0)
{
uint8_t v___x_3933_;
v___x_3933_ = lean_uint64_dec_lt(v_itemSeq_3890_, v_beforeSeq_3889_);
v___y_3924_ = v___y_3931_;
v___y_3925_ = v___y_3929_;
v___y_3926_ = v___y_3930_;
v___y_3927_ = v___x_3933_;
goto v___jp_3923_;
}
else
{
v___y_3924_ = v___y_3931_;
v___y_3925_ = v___y_3929_;
v___y_3926_ = v___y_3930_;
v___y_3927_ = v___x_3932_;
goto v___jp_3923_;
}
}
v___jp_3934_:
{
uint32_t v___x_3936_; uint8_t v___x_3937_;
v___x_3936_ = 0;
v___x_3937_ = lean_uint32_dec_eq(v_hasSinceCursor_3891_, v___x_3936_);
if (v___x_3937_ == 0)
{
uint8_t v___x_3938_;
v___x_3938_ = lean_uint64_dec_lt(v_sinceSeq_3888_, v_itemSeq_3890_);
v___y_3929_ = v___y_3935_;
v___y_3930_ = v___x_3936_;
v___y_3931_ = v___x_3938_;
goto v___jp_3928_;
}
else
{
v___y_3929_ = v___y_3935_;
v___y_3930_ = v___x_3936_;
v___y_3931_ = v___x_3937_;
goto v___jp_3928_;
}
}
v___jp_3939_:
{
uint8_t v___x_3940_;
v___x_3940_ = 1;
v___y_3935_ = v___x_3940_;
goto v___jp_3934_;
}
}
}

LEAN_EXPORT uint64_t orb_sidebar_merge_step(uint32_t v_existingIdOrd_3961_, uint32_t v_incomingIdOrd_3962_, uint64_t v_existingUpdatedAtMs_3963_, uint64_t v_incomingUpdatedAtMs_3964_, uint8_t v_incomingSupersededOrArchived_3965_, uint8_t v_isPartialPage_3966_){
_start:
{
uint32_t v___y_3968_; uint32_t v___y_3969_; uint32_t v___x_3975_; uint8_t v___y_3977_; uint8_t v___y_3978_; uint32_t v___y_3979_; uint8_t v___y_3982_; uint8_t v___y_3983_; uint32_t v___y_3984_; uint32_t v___y_3985_; uint8_t v___y_3988_; uint8_t v___y_3989_; uint32_t v___y_3990_; uint32_t v___y_3991_; uint8_t v___y_3994_; uint8_t v___y_3995_; uint8_t v___y_3996_; uint32_t v___y_3997_; uint8_t v___y_4006_; uint8_t v___x_4011_;
v___x_3975_ = 0;
v___x_4011_ = lean_uint32_dec_eq(v_existingIdOrd_3961_, v___x_3975_);
if (v___x_4011_ == 0)
{
uint8_t v___x_4012_;
v___x_4012_ = lean_uint32_dec_eq(v_existingIdOrd_3961_, v_incomingIdOrd_3962_);
v___y_4006_ = v___x_4012_;
goto v___jp_4005_;
}
else
{
uint8_t v___x_4013_;
v___x_4013_ = 0;
v___y_4006_ = v___x_4013_;
goto v___jp_4005_;
}
v___jp_3967_:
{
uint64_t v___x_3970_; uint64_t v___x_3971_; uint64_t v___x_3972_; uint64_t v___x_3973_; uint64_t v___x_3974_;
v___x_3970_ = lean_uint32_to_uint64(v___y_3968_);
v___x_3971_ = lean_uint32_to_uint64(v___y_3969_);
v___x_3972_ = 32ULL;
v___x_3973_ = lean_uint64_shift_left(v___x_3971_, v___x_3972_);
v___x_3974_ = lean_uint64_lor(v___x_3970_, v___x_3973_);
return v___x_3974_;
}
v___jp_3976_:
{
if (v___y_3977_ == 0)
{
if (v___y_3978_ == 0)
{
uint32_t v___x_3980_;
v___x_3980_ = 1;
v___y_3968_ = v___y_3979_;
v___y_3969_ = v___x_3980_;
goto v___jp_3967_;
}
else
{
v___y_3968_ = v___y_3979_;
v___y_3969_ = v___x_3975_;
goto v___jp_3967_;
}
}
else
{
v___y_3968_ = v___y_3979_;
v___y_3969_ = v___x_3975_;
goto v___jp_3967_;
}
}
v___jp_3981_:
{
uint32_t v___x_3986_;
v___x_3986_ = lean_uint32_lor(v___y_3985_, v___y_3984_);
v___y_3977_ = v___y_3982_;
v___y_3978_ = v___y_3983_;
v___y_3979_ = v___x_3986_;
goto v___jp_3976_;
}
v___jp_3987_:
{
uint32_t v___x_3992_;
v___x_3992_ = lean_uint32_lor(v___y_3991_, v___y_3990_);
v___y_3977_ = v___y_3988_;
v___y_3978_ = v___y_3989_;
v___y_3979_ = v___x_3992_;
goto v___jp_3976_;
}
v___jp_3993_:
{
uint8_t v___x_3998_;
v___x_3998_ = lean_uint8_dec_eq(v_incomingSupersededOrArchived_3965_, v___y_3996_);
if (v___x_3998_ == 0)
{
if (v___y_3995_ == 0)
{
uint32_t v___x_3999_; uint32_t v___x_4000_;
v___x_3999_ = 1795;
v___x_4000_ = lean_uint32_lor(v___x_3999_, v___y_3997_);
v___y_3977_ = v___x_3998_;
v___y_3978_ = v___y_3995_;
v___y_3979_ = v___x_4000_;
goto v___jp_3976_;
}
else
{
if (v___y_3994_ == 0)
{
uint32_t v___x_4001_;
v___x_4001_ = 1282;
v___y_3982_ = v___x_3998_;
v___y_3983_ = v___y_3995_;
v___y_3984_ = v___y_3997_;
v___y_3985_ = v___x_4001_;
goto v___jp_3981_;
}
else
{
uint32_t v___x_4002_;
v___x_4002_ = 1281;
v___y_3982_ = v___x_3998_;
v___y_3983_ = v___y_3995_;
v___y_3984_ = v___y_3997_;
v___y_3985_ = v___x_4002_;
goto v___jp_3981_;
}
}
}
else
{
if (v___y_3995_ == 0)
{
uint32_t v___x_4003_;
v___x_4003_ = 1024;
v___y_3988_ = v___x_3998_;
v___y_3989_ = v___y_3995_;
v___y_3990_ = v___y_3997_;
v___y_3991_ = v___x_4003_;
goto v___jp_3987_;
}
else
{
uint32_t v___x_4004_;
v___x_4004_ = 1028;
v___y_3988_ = v___x_3998_;
v___y_3989_ = v___y_3995_;
v___y_3990_ = v___y_3997_;
v___y_3991_ = v___x_4004_;
goto v___jp_3987_;
}
}
}
v___jp_4005_:
{
uint8_t v_incomingNewer_4007_; uint8_t v___x_4008_; uint8_t v___x_4009_;
v_incomingNewer_4007_ = lean_uint64_dec_le(v_existingUpdatedAtMs_3963_, v_incomingUpdatedAtMs_3964_);
v___x_4008_ = 1;
v___x_4009_ = lean_uint8_dec_eq(v_isPartialPage_3966_, v___x_4008_);
if (v___x_4009_ == 0)
{
v___y_3994_ = v_incomingNewer_4007_;
v___y_3995_ = v___y_4006_;
v___y_3996_ = v___x_4008_;
v___y_3997_ = v___x_3975_;
goto v___jp_3993_;
}
else
{
uint32_t v___x_4010_;
v___x_4010_ = 2048;
v___y_3994_ = v_incomingNewer_4007_;
v___y_3995_ = v___y_4006_;
v___y_3996_ = v___x_4008_;
v___y_3997_ = v___x_4010_;
goto v___jp_3993_;
}
}
}
}

LEAN_EXPORT uint64_t orb_scroll_epoch_step(uint32_t v_layoutEpoch_4028_, uint32_t v_lastCorrectedEpoch_4029_, uint8_t v_correctionsInEpoch_4030_, uint8_t v_isPinnedToBottom_4031_, uint8_t v_userIsDragging_4032_, uint32_t v_targetScrollTopPx_4033_, uint32_t v_currentScrollTopPx_4034_){
_start:
{
uint32_t v___y_4036_; uint32_t v___y_4037_; uint8_t v___y_4046_; uint8_t v___y_4047_; uint8_t v___y_4051_; uint8_t v___y_4052_; uint8_t v___y_4058_; uint8_t v_newEpoch_4062_;
v_newEpoch_4062_ = lean_uint32_dec_lt(v_lastCorrectedEpoch_4029_, v_layoutEpoch_4028_);
if (v_newEpoch_4062_ == 0)
{
uint8_t v___x_4063_; uint8_t v___x_4064_;
v___x_4063_ = 0;
v___x_4064_ = lean_uint8_dec_lt(v___x_4063_, v_correctionsInEpoch_4030_);
v___y_4058_ = v___x_4064_;
goto v___jp_4057_;
}
else
{
uint8_t v___x_4065_;
v___x_4065_ = 0;
v___y_4058_ = v___x_4065_;
goto v___jp_4057_;
}
v___jp_4035_:
{
uint64_t v___x_4038_; uint64_t v___x_4039_; uint64_t v___x_4040_; uint64_t v___x_4041_; uint64_t v___x_4042_;
v___x_4038_ = lean_uint32_to_uint64(v___y_4036_);
v___x_4039_ = lean_uint32_to_uint64(v___y_4037_);
v___x_4040_ = 32ULL;
v___x_4041_ = lean_uint64_shift_left(v___x_4039_, v___x_4040_);
v___x_4042_ = lean_uint64_lor(v___x_4038_, v___x_4041_);
return v___x_4042_;
}
v___jp_4043_:
{
uint32_t v___x_4044_;
v___x_4044_ = 1026;
v___y_4036_ = v___x_4044_;
v___y_4037_ = v_currentScrollTopPx_4034_;
goto v___jp_4035_;
}
v___jp_4045_:
{
if (v___y_4047_ == 0)
{
if (v___y_4046_ == 0)
{
uint32_t v___x_4048_;
v___x_4048_ = 0;
v___y_4036_ = v___x_4048_;
v___y_4037_ = v_currentScrollTopPx_4034_;
goto v___jp_4035_;
}
else
{
goto v___jp_4043_;
}
}
else
{
uint32_t v___x_4049_;
v___x_4049_ = 1281;
v___y_4036_ = v___x_4049_;
v___y_4037_ = v_targetScrollTopPx_4033_;
goto v___jp_4035_;
}
}
v___jp_4050_:
{
uint8_t v___x_4053_; uint8_t v___x_4054_;
v___x_4053_ = 1;
v___x_4054_ = lean_uint8_dec_eq(v_isPinnedToBottom_4031_, v___x_4053_);
if (v___x_4054_ == 0)
{
v___y_4046_ = v___y_4051_;
v___y_4047_ = v___x_4054_;
goto v___jp_4045_;
}
else
{
uint8_t v___x_4055_; uint8_t v___x_4056_;
v___x_4055_ = 0;
v___x_4056_ = lean_uint8_dec_eq(v_userIsDragging_4032_, v___x_4055_);
if (v___x_4056_ == 0)
{
v___y_4046_ = v___y_4051_;
v___y_4047_ = v___x_4056_;
goto v___jp_4045_;
}
else
{
if (v___y_4051_ == 0)
{
v___y_4046_ = v___y_4051_;
v___y_4047_ = v___y_4052_;
goto v___jp_4045_;
}
else
{
goto v___jp_4043_;
}
}
}
}
v___jp_4057_:
{
uint8_t v___x_4059_;
v___x_4059_ = lean_uint32_dec_eq(v_targetScrollTopPx_4033_, v_currentScrollTopPx_4034_);
if (v___x_4059_ == 0)
{
uint8_t v___x_4060_;
v___x_4060_ = 1;
v___y_4051_ = v___y_4058_;
v___y_4052_ = v___x_4060_;
goto v___jp_4050_;
}
else
{
uint8_t v___x_4061_;
v___x_4061_ = 0;
v___y_4051_ = v___y_4058_;
v___y_4052_ = v___x_4061_;
goto v___jp_4050_;
}
}
}
}

LEAN_EXPORT uint64_t orb_client_parity_step(uint8_t v_clientTarget_4082_, uint32_t v_wireSchemaId_4083_, uint32_t v_transcriptSeq_4084_, uint32_t v_markdownBlocksCount_4085_, uint32_t v_sendQueueDepth_4086_, uint8_t v_scrollCorrectedInEpoch_4087_){
_start:
{
uint32_t v___y_4089_; uint32_t v___y_4090_; uint32_t v___y_4099_; uint8_t v___x_4106_; uint8_t v_validTarget_4107_; uint8_t v___y_4109_; uint32_t v___x_4114_; uint8_t v___x_4115_;
v___x_4106_ = 3;
v_validTarget_4107_ = lean_uint8_dec_le(v_clientTarget_4082_, v___x_4106_);
v___x_4114_ = 1;
v___x_4115_ = lean_uint32_dec_le(v___x_4114_, v_wireSchemaId_4083_);
if (v___x_4115_ == 0)
{
v___y_4109_ = v___x_4115_;
goto v___jp_4108_;
}
else
{
uint32_t v___x_4116_; uint8_t v___x_4117_;
v___x_4116_ = 2;
v___x_4117_ = lean_uint32_dec_le(v_wireSchemaId_4083_, v___x_4116_);
v___y_4109_ = v___x_4117_;
goto v___jp_4108_;
}
v___jp_4088_:
{
uint64_t v___x_4091_; uint64_t v___x_4092_; uint64_t v___x_4093_; uint64_t v___x_4094_; uint64_t v___x_4095_;
v___x_4091_ = lean_uint32_to_uint64(v___y_4089_);
v___x_4092_ = lean_uint32_to_uint64(v___y_4090_);
v___x_4093_ = 32ULL;
v___x_4094_ = lean_uint64_shift_left(v___x_4092_, v___x_4093_);
v___x_4095_ = lean_uint64_lor(v___x_4091_, v___x_4094_);
return v___x_4095_;
}
v___jp_4096_:
{
uint32_t v___x_4097_;
v___x_4097_ = 0;
v___y_4089_ = v___x_4097_;
v___y_4090_ = v___x_4097_;
goto v___jp_4088_;
}
v___jp_4098_:
{
uint32_t v___x_4100_; uint32_t v___x_4101_; uint32_t v___x_4102_; uint32_t v___x_4103_; uint32_t v___x_4104_; uint32_t v___x_4105_;
v___x_4100_ = 16;
v___x_4101_ = lean_uint32_shift_left(v_markdownBlocksCount_4085_, v___x_4100_);
v___x_4102_ = lean_uint32_xor(v_transcriptSeq_4084_, v___x_4101_);
v___x_4103_ = 24;
v___x_4104_ = lean_uint32_shift_left(v_sendQueueDepth_4086_, v___x_4103_);
v___x_4105_ = lean_uint32_xor(v___x_4102_, v___x_4104_);
v___y_4089_ = v___y_4099_;
v___y_4090_ = v___x_4105_;
goto v___jp_4088_;
}
v___jp_4108_:
{
if (v_validTarget_4107_ == 0)
{
goto v___jp_4096_;
}
else
{
if (v___y_4109_ == 0)
{
goto v___jp_4096_;
}
else
{
uint8_t v___x_4110_; uint8_t v___x_4111_;
v___x_4110_ = 1;
v___x_4111_ = lean_uint8_dec_eq(v_scrollCorrectedInEpoch_4087_, v___x_4110_);
if (v___x_4111_ == 0)
{
uint32_t v___x_4112_;
v___x_4112_ = 257;
v___y_4099_ = v___x_4112_;
goto v___jp_4098_;
}
else
{
uint32_t v___x_4113_;
v___x_4113_ = 769;
v___y_4099_ = v___x_4113_;
goto v___jp_4098_;
}
}
}
}
}
}

LEAN_EXPORT uint8_t orb_verify_approval(uint8_t v_signed_4396_, uint8_t v_owned_4397_, uint8_t v_pending_4398_, uint8_t v_unexpired_4399_, uint8_t v_unchanged_4400_, uint8_t v_risk_4401_, uint8_t v_confirmed_4402_){
_start:
{
uint8_t v___x_4403_; uint8_t v___x_4404_;
v___x_4403_ = 1;
v___x_4404_ = lean_uint8_dec_eq(v_signed_4396_, v___x_4403_);
if (v___x_4404_ == 0)
{
uint8_t v___x_4405_;
v___x_4405_ = 0;
return v___x_4405_;
}
else
{
uint8_t v___x_4406_;
v___x_4406_ = lean_uint8_dec_eq(v_owned_4397_, v___x_4403_);
if (v___x_4406_ == 0)
{
uint8_t v___x_4407_;
v___x_4407_ = 0;
return v___x_4407_;
}
else
{
uint8_t v___x_4408_;
v___x_4408_ = lean_uint8_dec_eq(v_pending_4398_, v___x_4403_);
if (v___x_4408_ == 0)
{
uint8_t v___x_4409_;
v___x_4409_ = 0;
return v___x_4409_;
}
else
{
uint8_t v___x_4410_;
v___x_4410_ = lean_uint8_dec_eq(v_unexpired_4399_, v___x_4403_);
if (v___x_4410_ == 0)
{
uint8_t v___x_4411_;
v___x_4411_ = 0;
return v___x_4411_;
}
else
{
uint8_t v___x_4412_;
v___x_4412_ = lean_uint8_dec_eq(v_unchanged_4400_, v___x_4403_);
if (v___x_4412_ == 0)
{
uint8_t v___x_4413_;
v___x_4413_ = 0;
return v___x_4413_;
}
else
{
uint8_t v___x_4414_; uint8_t v___x_4415_;
v___x_4414_ = 2;
v___x_4415_ = lean_uint8_dec_lt(v_risk_4401_, v___x_4414_);
if (v___x_4415_ == 0)
{
uint8_t v___x_4416_;
v___x_4416_ = lean_uint8_dec_eq(v_confirmed_4402_, v___x_4403_);
if (v___x_4416_ == 0)
{
uint8_t v___x_4417_;
v___x_4417_ = 0;
return v___x_4417_;
}
else
{
return v___x_4403_;
}
}
else
{
return v___x_4403_;
}
}
}
}
}
}
}
}

LEAN_EXPORT uint64_t orb_node_gc_step(uint64_t v_freeBytes_4434_, uint64_t v_floorBytes_4435_, uint64_t v_emergencyFloorBytes_4436_, uint64_t v_agedScratchBytes_4437_, uint64_t v_freshScratchBytes_4438_, uint64_t v_coldCacheBytes_4439_, uint64_t v_hotCacheBytes_4440_){
_start:
{
uint32_t v___y_4442_; uint32_t v___y_4443_; uint8_t v___y_4450_; uint32_t v___y_4451_; uint32_t v___y_4452_; uint8_t v___y_4457_; uint32_t v___y_4458_; uint8_t v___y_4459_; uint32_t v___y_4460_; uint32_t v___y_4465_; uint8_t v___y_4466_; uint8_t v___y_4467_; uint8_t v___y_4468_; uint32_t v___y_4469_; uint32_t v___y_4474_; uint8_t v___y_4475_; uint8_t v___y_4476_; uint8_t v___y_4477_; uint32_t v___y_4478_; uint8_t v___y_4483_; uint8_t v___y_4484_; uint8_t v___y_4485_; uint8_t v___y_4486_; uint32_t v___y_4487_; uint8_t v___y_4493_; uint8_t v___y_4494_; uint8_t v___y_4495_; uint8_t v___y_4496_; uint8_t v___y_4499_; uint8_t v___y_4500_; uint8_t v___y_4501_; uint8_t v___y_4502_; uint8_t v___y_4507_; uint8_t v___y_4508_; uint8_t v___y_4509_; uint8_t v___y_4510_; uint8_t v___y_4513_; uint8_t v___y_4514_; uint8_t v___y_4515_; uint8_t v___y_4516_; uint8_t v_underFloor_4517_;
v_underFloor_4517_ = lean_uint64_dec_lt(v_freeBytes_4434_, v_floorBytes_4435_);
if (v_underFloor_4517_ == 0)
{
uint64_t v___x_4518_;
v___x_4518_ = 309237645312ULL;
return v___x_4518_;
}
else
{
uint8_t v___x_4519_; uint8_t v_emerg_4520_; uint8_t v___y_4522_; uint8_t v___y_4523_; uint8_t v___y_4524_; uint64_t v___y_4525_; uint8_t v___y_4526_; uint64_t v___y_4529_; uint64_t v___y_4530_; uint64_t v___y_4531_; uint64_t v___y_4538_; uint64_t v___y_4539_; uint64_t v___y_4544_; uint64_t v_deficit_4548_; uint8_t v___x_4549_;
v___x_4519_ = 0;
v_emerg_4520_ = lean_uint64_dec_lt(v_freeBytes_4434_, v_emergencyFloorBytes_4436_);
v_deficit_4548_ = lean_uint64_sub(v_floorBytes_4435_, v_freeBytes_4434_);
v___x_4549_ = lean_uint64_dec_le(v_deficit_4548_, v_agedScratchBytes_4437_);
if (v___x_4549_ == 0)
{
uint64_t v___x_4550_;
v___x_4550_ = lean_uint64_sub(v_deficit_4548_, v_agedScratchBytes_4437_);
v___y_4544_ = v___x_4550_;
goto v___jp_4543_;
}
else
{
uint64_t v___x_4551_;
v___x_4551_ = 0ULL;
v___y_4544_ = v___x_4551_;
goto v___jp_4543_;
}
v___jp_4521_:
{
if (v___y_4522_ == 0)
{
if (v___y_4524_ == 0)
{
v___y_4499_ = v___y_4526_;
v___y_4500_ = v___y_4523_;
v___y_4501_ = v___y_4524_;
v___y_4502_ = v___x_4519_;
goto v___jp_4498_;
}
else
{
v___y_4493_ = v___y_4526_;
v___y_4494_ = v___y_4523_;
v___y_4495_ = v___y_4524_;
v___y_4496_ = v___x_4519_;
goto v___jp_4492_;
}
}
else
{
if (v___y_4524_ == 0)
{
if (v_underFloor_4517_ == 0)
{
v___y_4499_ = v___y_4526_;
v___y_4500_ = v___y_4523_;
v___y_4501_ = v___y_4524_;
v___y_4502_ = v_underFloor_4517_;
goto v___jp_4498_;
}
else
{
v___y_4507_ = v___y_4526_;
v___y_4508_ = v___y_4523_;
v___y_4509_ = v_underFloor_4517_;
v___y_4510_ = v___y_4524_;
goto v___jp_4506_;
}
}
else
{
if (v_emerg_4520_ == 0)
{
v___y_4513_ = v___y_4526_;
v___y_4514_ = v___y_4523_;
v___y_4515_ = v___y_4524_;
v___y_4516_ = v_emerg_4520_;
goto v___jp_4512_;
}
else
{
uint8_t v___x_4527_;
v___x_4527_ = lean_uint64_dec_lt(v___y_4525_, v_hotCacheBytes_4440_);
v___y_4513_ = v___y_4526_;
v___y_4514_ = v___y_4523_;
v___y_4515_ = v___y_4524_;
v___y_4516_ = v___x_4527_;
goto v___jp_4512_;
}
}
}
}
v___jp_4528_:
{
uint8_t v_unrecoverable_4532_; uint64_t v___x_4533_; uint8_t v_evictCold_4534_; uint8_t v_hasRem2_4535_; uint8_t v_hasRem3_4536_;
v_unrecoverable_4532_ = lean_uint64_dec_lt(v_hotCacheBytes_4440_, v___y_4531_);
v___x_4533_ = 0ULL;
v_evictCold_4534_ = lean_uint64_dec_lt(v___x_4533_, v___y_4529_);
v_hasRem2_4535_ = lean_uint64_dec_lt(v___x_4533_, v___y_4530_);
v_hasRem3_4536_ = lean_uint64_dec_lt(v___x_4533_, v___y_4531_);
if (v_hasRem2_4535_ == 0)
{
v___y_4522_ = v_hasRem3_4536_;
v___y_4523_ = v_evictCold_4534_;
v___y_4524_ = v_unrecoverable_4532_;
v___y_4525_ = v___x_4533_;
v___y_4526_ = v_emerg_4520_;
goto v___jp_4521_;
}
else
{
v___y_4522_ = v_hasRem3_4536_;
v___y_4523_ = v_evictCold_4534_;
v___y_4524_ = v_unrecoverable_4532_;
v___y_4525_ = v___x_4533_;
v___y_4526_ = v_underFloor_4517_;
goto v___jp_4521_;
}
}
v___jp_4537_:
{
uint8_t v___x_4540_;
v___x_4540_ = lean_uint64_dec_le(v___y_4539_, v_freshScratchBytes_4438_);
if (v___x_4540_ == 0)
{
uint64_t v___x_4541_;
v___x_4541_ = lean_uint64_sub(v___y_4539_, v_freshScratchBytes_4438_);
v___y_4529_ = v___y_4538_;
v___y_4530_ = v___y_4539_;
v___y_4531_ = v___x_4541_;
goto v___jp_4528_;
}
else
{
uint64_t v___x_4542_;
v___x_4542_ = 0ULL;
v___y_4529_ = v___y_4538_;
v___y_4530_ = v___y_4539_;
v___y_4531_ = v___x_4542_;
goto v___jp_4528_;
}
}
v___jp_4543_:
{
uint8_t v___x_4545_;
v___x_4545_ = lean_uint64_dec_le(v___y_4544_, v_coldCacheBytes_4439_);
if (v___x_4545_ == 0)
{
uint64_t v___x_4546_;
v___x_4546_ = lean_uint64_sub(v___y_4544_, v_coldCacheBytes_4439_);
v___y_4538_ = v___y_4544_;
v___y_4539_ = v___x_4546_;
goto v___jp_4537_;
}
else
{
uint64_t v___x_4547_;
v___x_4547_ = 0ULL;
v___y_4538_ = v___y_4544_;
v___y_4539_ = v___x_4547_;
goto v___jp_4537_;
}
}
}
v___jp_4441_:
{
uint64_t v___x_4444_; uint64_t v___x_4445_; uint64_t v___x_4446_; uint64_t v___x_4447_; uint64_t v___x_4448_;
v___x_4444_ = lean_uint32_to_uint64(v___y_4442_);
v___x_4445_ = lean_uint32_to_uint64(v___y_4443_);
v___x_4446_ = 32ULL;
v___x_4447_ = lean_uint64_shift_left(v___x_4445_, v___x_4446_);
v___x_4448_ = lean_uint64_lor(v___x_4444_, v___x_4447_);
return v___x_4448_;
}
v___jp_4449_:
{
uint32_t v_lo32_4453_;
v_lo32_4453_ = lean_uint32_lor(v___y_4451_, v___y_4452_);
if (v___y_4450_ == 0)
{
uint32_t v___x_4454_;
v___x_4454_ = 6;
v___y_4442_ = v_lo32_4453_;
v___y_4443_ = v___x_4454_;
goto v___jp_4441_;
}
else
{
uint32_t v___x_4455_;
v___x_4455_ = 0;
v___y_4442_ = v_lo32_4453_;
v___y_4443_ = v___x_4455_;
goto v___jp_4441_;
}
}
v___jp_4456_:
{
uint32_t v___x_4461_;
v___x_4461_ = lean_uint32_lor(v___y_4458_, v___y_4460_);
if (v___y_4459_ == 0)
{
uint32_t v___x_4462_;
v___x_4462_ = 0;
v___y_4450_ = v___y_4457_;
v___y_4451_ = v___x_4461_;
v___y_4452_ = v___x_4462_;
goto v___jp_4449_;
}
else
{
uint32_t v___x_4463_;
v___x_4463_ = 4096;
v___y_4450_ = v___y_4457_;
v___y_4451_ = v___x_4461_;
v___y_4452_ = v___x_4463_;
goto v___jp_4449_;
}
}
v___jp_4464_:
{
uint32_t v___x_4470_;
v___x_4470_ = lean_uint32_lor(v___y_4465_, v___y_4469_);
if (v___y_4467_ == 0)
{
uint32_t v___x_4471_;
v___x_4471_ = 0;
v___y_4457_ = v___y_4466_;
v___y_4458_ = v___x_4470_;
v___y_4459_ = v___y_4468_;
v___y_4460_ = v___x_4471_;
goto v___jp_4456_;
}
else
{
uint32_t v___x_4472_;
v___x_4472_ = 2048;
v___y_4457_ = v___y_4466_;
v___y_4458_ = v___x_4470_;
v___y_4459_ = v___y_4468_;
v___y_4460_ = v___x_4472_;
goto v___jp_4456_;
}
}
v___jp_4473_:
{
uint32_t v___x_4479_;
v___x_4479_ = lean_uint32_lor(v___y_4474_, v___y_4478_);
if (v___y_4475_ == 0)
{
uint32_t v___x_4480_;
v___x_4480_ = 0;
v___y_4465_ = v___x_4479_;
v___y_4466_ = v___y_4475_;
v___y_4467_ = v___y_4476_;
v___y_4468_ = v___y_4477_;
v___y_4469_ = v___x_4480_;
goto v___jp_4464_;
}
else
{
uint32_t v___x_4481_;
v___x_4481_ = 1024;
v___y_4465_ = v___x_4479_;
v___y_4466_ = v___y_4475_;
v___y_4467_ = v___y_4476_;
v___y_4468_ = v___y_4477_;
v___y_4469_ = v___x_4481_;
goto v___jp_4464_;
}
}
v___jp_4482_:
{
uint32_t v___x_4488_; uint32_t v___x_4489_;
v___x_4488_ = 256;
v___x_4489_ = lean_uint32_lor(v___y_4487_, v___x_4488_);
if (v___y_4484_ == 0)
{
uint32_t v___x_4490_;
v___x_4490_ = 0;
v___y_4474_ = v___x_4489_;
v___y_4475_ = v___y_4483_;
v___y_4476_ = v___y_4485_;
v___y_4477_ = v___y_4486_;
v___y_4478_ = v___x_4490_;
goto v___jp_4473_;
}
else
{
uint32_t v___x_4491_;
v___x_4491_ = 512;
v___y_4474_ = v___x_4489_;
v___y_4475_ = v___y_4483_;
v___y_4476_ = v___y_4485_;
v___y_4477_ = v___y_4486_;
v___y_4478_ = v___x_4491_;
goto v___jp_4473_;
}
}
v___jp_4492_:
{
uint32_t v___x_4497_;
v___x_4497_ = 5;
v___y_4483_ = v___y_4493_;
v___y_4484_ = v___y_4494_;
v___y_4485_ = v___y_4496_;
v___y_4486_ = v___y_4495_;
v___y_4487_ = v___x_4497_;
goto v___jp_4482_;
}
v___jp_4498_:
{
if (v___y_4499_ == 0)
{
if (v___y_4500_ == 0)
{
uint32_t v___x_4503_;
v___x_4503_ = 1;
v___y_4483_ = v___y_4499_;
v___y_4484_ = v___y_4500_;
v___y_4485_ = v___y_4502_;
v___y_4486_ = v___y_4501_;
v___y_4487_ = v___x_4503_;
goto v___jp_4482_;
}
else
{
uint32_t v___x_4504_;
v___x_4504_ = 2;
v___y_4483_ = v___y_4499_;
v___y_4484_ = v___y_4500_;
v___y_4485_ = v___y_4502_;
v___y_4486_ = v___y_4501_;
v___y_4487_ = v___x_4504_;
goto v___jp_4482_;
}
}
else
{
uint32_t v___x_4505_;
v___x_4505_ = 3;
v___y_4483_ = v___y_4499_;
v___y_4484_ = v___y_4500_;
v___y_4485_ = v___y_4502_;
v___y_4486_ = v___y_4501_;
v___y_4487_ = v___x_4505_;
goto v___jp_4482_;
}
}
v___jp_4506_:
{
uint32_t v___x_4511_;
v___x_4511_ = 4;
v___y_4483_ = v___y_4507_;
v___y_4484_ = v___y_4508_;
v___y_4485_ = v___y_4509_;
v___y_4486_ = v___y_4510_;
v___y_4487_ = v___x_4511_;
goto v___jp_4482_;
}
v___jp_4512_:
{
if (v___y_4516_ == 0)
{
v___y_4493_ = v___y_4513_;
v___y_4494_ = v___y_4514_;
v___y_4495_ = v___y_4515_;
v___y_4496_ = v___y_4516_;
goto v___jp_4492_;
}
else
{
v___y_4507_ = v___y_4513_;
v___y_4508_ = v___y_4514_;
v___y_4509_ = v___y_4516_;
v___y_4510_ = v___y_4515_;
goto v___jp_4506_;
}
}
}
}

LEAN_EXPORT uint64_t orb_node_disk_admission_step(uint64_t v_freeBytes_4568_, uint64_t v_reservedBytes_4569_, uint64_t v_nodeFloorBytes_4570_, uint64_t v_coreFloorBytes_4571_, uint64_t v_hysteresisBytes_4572_, uint8_t v_nodePinnedPressure_4573_){
_start:
{
uint32_t v___y_4575_; uint32_t v___y_4576_; uint8_t v___y_4583_; uint8_t v___y_4584_; uint8_t v___y_4585_; uint32_t v___y_4586_; uint8_t v___y_4592_; uint64_t v___y_4593_; uint8_t v___y_4594_; uint8_t v___y_4595_; uint8_t v___y_4603_; uint8_t v___y_4604_; uint8_t v___y_4605_; uint64_t v___y_4608_; uint64_t v___y_4609_; uint64_t v___y_4619_; uint8_t v___x_4623_;
v___x_4623_ = lean_uint64_dec_le(v_coreFloorBytes_4571_, v_nodeFloorBytes_4570_);
if (v___x_4623_ == 0)
{
v___y_4619_ = v_coreFloorBytes_4571_;
goto v___jp_4618_;
}
else
{
v___y_4619_ = v_nodeFloorBytes_4570_;
goto v___jp_4618_;
}
v___jp_4574_:
{
uint64_t v___x_4577_; uint64_t v___x_4578_; uint64_t v___x_4579_; uint64_t v___x_4580_; uint64_t v___x_4581_;
v___x_4577_ = lean_uint32_to_uint64(v___y_4576_);
v___x_4578_ = lean_uint32_to_uint64(v___y_4575_);
v___x_4579_ = 32ULL;
v___x_4580_ = lean_uint64_shift_left(v___x_4578_, v___x_4579_);
v___x_4581_ = lean_uint64_lor(v___x_4577_, v___x_4580_);
return v___x_4581_;
}
v___jp_4582_:
{
if (v___y_4583_ == 0)
{
if (v___y_4585_ == 0)
{
uint32_t v___x_4587_;
v___x_4587_ = 0;
v___y_4575_ = v___y_4586_;
v___y_4576_ = v___x_4587_;
goto v___jp_4574_;
}
else
{
if (v___y_4584_ == 0)
{
uint32_t v___x_4588_;
v___x_4588_ = 257;
v___y_4575_ = v___y_4586_;
v___y_4576_ = v___x_4588_;
goto v___jp_4574_;
}
else
{
uint32_t v___x_4589_;
v___x_4589_ = 769;
v___y_4575_ = v___y_4586_;
v___y_4576_ = v___x_4589_;
goto v___jp_4574_;
}
}
}
else
{
uint32_t v___x_4590_;
v___x_4590_ = 2;
v___y_4575_ = v___y_4586_;
v___y_4576_ = v___x_4590_;
goto v___jp_4574_;
}
}
v___jp_4591_:
{
uint64_t v___x_4596_; uint64_t v_rawHeadroomGiB_4597_; uint64_t v___x_4598_; uint8_t v___x_4599_;
v___x_4596_ = 30ULL;
v_rawHeadroomGiB_4597_ = lean_uint64_shift_right(v___y_4593_, v___x_4596_);
v___x_4598_ = 4294967295ULL;
v___x_4599_ = lean_uint64_dec_lt(v___x_4598_, v_rawHeadroomGiB_4597_);
if (v___x_4599_ == 0)
{
uint32_t v___x_4600_;
v___x_4600_ = lean_uint64_to_uint32(v_rawHeadroomGiB_4597_);
v___y_4583_ = v___y_4592_;
v___y_4584_ = v___y_4595_;
v___y_4585_ = v___y_4594_;
v___y_4586_ = v___x_4600_;
goto v___jp_4582_;
}
else
{
uint32_t v___x_4601_;
v___x_4601_ = 4294967295;
v___y_4583_ = v___y_4592_;
v___y_4584_ = v___y_4595_;
v___y_4585_ = v___y_4594_;
v___y_4586_ = v___x_4601_;
goto v___jp_4582_;
}
}
v___jp_4602_:
{
uint64_t v___x_4606_;
v___x_4606_ = 0ULL;
v___y_4592_ = v___y_4603_;
v___y_4593_ = v___x_4606_;
v___y_4594_ = v___y_4604_;
v___y_4595_ = v___y_4605_;
goto v___jp_4591_;
}
v___jp_4607_:
{
uint8_t v___x_4610_; uint8_t v___x_4611_;
v___x_4610_ = 0;
v___x_4611_ = lean_uint8_dec_eq(v_nodePinnedPressure_4573_, v___x_4610_);
if (v___x_4611_ == 0)
{
uint8_t v___x_4612_; uint8_t v_aboveFloor_4613_;
v___x_4612_ = 1;
v_aboveFloor_4613_ = lean_uint64_dec_le(v___y_4608_, v___y_4609_);
v___y_4603_ = v___x_4612_;
v___y_4604_ = v_aboveFloor_4613_;
v___y_4605_ = v___x_4611_;
goto v___jp_4602_;
}
else
{
uint8_t v___x_4614_; uint8_t v_aboveFloor_4615_;
v___x_4614_ = 0;
v_aboveFloor_4615_ = lean_uint64_dec_le(v___y_4608_, v___y_4609_);
if (v_aboveFloor_4615_ == 0)
{
v___y_4603_ = v___x_4614_;
v___y_4604_ = v_aboveFloor_4615_;
v___y_4605_ = v_aboveFloor_4615_;
goto v___jp_4602_;
}
else
{
uint64_t v___x_4616_; uint8_t v___x_4617_;
v___x_4616_ = lean_uint64_sub(v___y_4609_, v___y_4608_);
v___x_4617_ = lean_uint64_dec_lt(v___x_4616_, v_hysteresisBytes_4572_);
v___y_4592_ = v___x_4614_;
v___y_4593_ = v___x_4616_;
v___y_4594_ = v_aboveFloor_4615_;
v___y_4595_ = v___x_4617_;
goto v___jp_4591_;
}
}
}
v___jp_4618_:
{
uint8_t v___x_4620_;
v___x_4620_ = lean_uint64_dec_le(v_reservedBytes_4569_, v_freeBytes_4568_);
if (v___x_4620_ == 0)
{
uint64_t v___x_4621_;
v___x_4621_ = 0ULL;
v___y_4608_ = v___y_4619_;
v___y_4609_ = v___x_4621_;
goto v___jp_4607_;
}
else
{
uint64_t v___x_4622_;
v___x_4622_ = lean_uint64_sub(v_freeBytes_4568_, v_reservedBytes_4569_);
v___y_4608_ = v___y_4619_;
v___y_4609_ = v___x_4622_;
goto v___jp_4607_;
}
}
}
}

LEAN_EXPORT uint32_t orb_vm_lifecycle_step(uint8_t v_ownerClass_4638_, uint8_t v_busy_4639_, uint8_t v_ttlExpired_4640_, uint8_t v_graceOrIdleElapsed_4641_, uint8_t v_workingIdleEnabled_4642_, uint8_t v_supportsFreeStop_4643_, uint8_t v_minDeletePending_4644_){
_start:
{
uint8_t v___x_4645_; uint8_t v___x_4646_;
v___x_4645_ = 1;
v___x_4646_ = lean_uint8_dec_eq(v_ttlExpired_4640_, v___x_4645_);
if (v___x_4646_ == 0)
{
uint8_t v___x_4647_;
v___x_4647_ = lean_uint8_dec_eq(v_busy_4639_, v___x_4645_);
if (v___x_4647_ == 0)
{
uint8_t v___x_4648_; uint8_t v___x_4649_;
v___x_4648_ = 0;
v___x_4649_ = lean_uint8_dec_eq(v_ownerClass_4638_, v___x_4648_);
if (v___x_4649_ == 0)
{
uint8_t v___x_4650_;
v___x_4650_ = lean_uint8_dec_eq(v_ownerClass_4638_, v___x_4645_);
if (v___x_4650_ == 0)
{
uint8_t v___x_4651_; uint8_t v___x_4652_;
v___x_4651_ = 2;
v___x_4652_ = lean_uint8_dec_eq(v_ownerClass_4638_, v___x_4651_);
if (v___x_4652_ == 0)
{
uint8_t v___x_4653_;
v___x_4653_ = lean_uint8_dec_eq(v_graceOrIdleElapsed_4641_, v___x_4648_);
if (v___x_4653_ == 0)
{
uint8_t v___x_4654_;
v___x_4654_ = lean_uint8_dec_eq(v_minDeletePending_4644_, v___x_4645_);
if (v___x_4654_ == 0)
{
uint32_t v___x_4655_;
v___x_4655_ = 259;
return v___x_4655_;
}
else
{
uint32_t v___x_4656_;
v___x_4656_ = 65537;
return v___x_4656_;
}
}
else
{
uint32_t v___x_4657_;
v___x_4657_ = 1;
return v___x_4657_;
}
}
else
{
uint8_t v___x_4658_;
v___x_4658_ = lean_uint8_dec_eq(v_graceOrIdleElapsed_4641_, v___x_4648_);
if (v___x_4658_ == 0)
{
uint8_t v___x_4659_;
v___x_4659_ = lean_uint8_dec_eq(v_supportsFreeStop_4643_, v___x_4645_);
if (v___x_4659_ == 0)
{
uint8_t v___x_4660_;
v___x_4660_ = lean_uint8_dec_eq(v_minDeletePending_4644_, v___x_4645_);
if (v___x_4660_ == 0)
{
uint32_t v___x_4661_;
v___x_4661_ = 259;
return v___x_4661_;
}
else
{
uint32_t v___x_4662_;
v___x_4662_ = 65537;
return v___x_4662_;
}
}
else
{
uint32_t v___x_4663_;
v___x_4663_ = 258;
return v___x_4663_;
}
}
else
{
uint32_t v___x_4664_;
v___x_4664_ = 1;
return v___x_4664_;
}
}
}
else
{
uint8_t v___x_4665_;
v___x_4665_ = lean_uint8_dec_eq(v_workingIdleEnabled_4642_, v___x_4648_);
if (v___x_4665_ == 0)
{
uint8_t v___x_4666_;
v___x_4666_ = lean_uint8_dec_eq(v_graceOrIdleElapsed_4641_, v___x_4648_);
if (v___x_4666_ == 0)
{
uint8_t v___x_4667_;
v___x_4667_ = lean_uint8_dec_eq(v_minDeletePending_4644_, v___x_4645_);
if (v___x_4667_ == 0)
{
uint32_t v___x_4668_;
v___x_4668_ = 259;
return v___x_4668_;
}
else
{
uint32_t v___x_4669_;
v___x_4669_ = 65537;
return v___x_4669_;
}
}
else
{
uint32_t v___x_4670_;
v___x_4670_ = 1;
return v___x_4670_;
}
}
else
{
uint32_t v___x_4671_;
v___x_4671_ = 0;
return v___x_4671_;
}
}
}
else
{
uint32_t v___x_4672_;
v___x_4672_ = 0;
return v___x_4672_;
}
}
else
{
uint32_t v___x_4673_;
v___x_4673_ = 0;
return v___x_4673_;
}
}
else
{
uint8_t v___x_4674_;
v___x_4674_ = lean_uint8_dec_eq(v_minDeletePending_4644_, v___x_4645_);
if (v___x_4674_ == 0)
{
uint32_t v___x_4675_;
v___x_4675_ = 259;
return v___x_4675_;
}
else
{
uint32_t v___x_4676_;
v___x_4676_ = 65537;
return v___x_4676_;
}
}
}
}

LEAN_EXPORT uint32_t orb_vm_claim_step(uint8_t v_isLive_4693_, uint8_t v_sameTenant_4694_, uint8_t v_ownerNone_4695_, uint8_t v_ownerInLineage_4696_){
_start:
{
uint8_t v___x_4697_; uint8_t v___x_4698_;
v___x_4697_ = 1;
v___x_4698_ = lean_uint8_dec_eq(v_isLive_4693_, v___x_4697_);
if (v___x_4698_ == 0)
{
uint32_t v___x_4699_;
v___x_4699_ = 512;
return v___x_4699_;
}
else
{
uint8_t v___x_4700_;
v___x_4700_ = lean_uint8_dec_eq(v_sameTenant_4694_, v___x_4697_);
if (v___x_4700_ == 0)
{
uint32_t v___x_4701_;
v___x_4701_ = 512;
return v___x_4701_;
}
else
{
uint8_t v___x_4702_;
v___x_4702_ = lean_uint8_dec_eq(v_ownerNone_4695_, v___x_4697_);
if (v___x_4702_ == 0)
{
uint8_t v___x_4703_;
v___x_4703_ = lean_uint8_dec_eq(v_ownerInLineage_4696_, v___x_4697_);
if (v___x_4703_ == 0)
{
uint32_t v___x_4704_;
v___x_4704_ = 512;
return v___x_4704_;
}
else
{
uint32_t v___x_4705_;
v___x_4705_ = 257;
return v___x_4705_;
}
}
else
{
uint32_t v___x_4706_;
v___x_4706_ = 257;
return v___x_4706_;
}
}
}
}
}

LEAN_EXPORT uint32_t orb_compute_secret_gate(uint8_t v_isCoreReservedComputeKey_4717_, uint8_t v_callerOnManagedNode_4718_, uint8_t v_isAllowlistedManagedSecret_4719_, uint8_t v_operatorBreakGlass_4720_){
_start:
{
uint8_t v___x_4721_; uint8_t v___x_4729_;
v___x_4721_ = 1;
v___x_4729_ = lean_uint8_dec_eq(v_isCoreReservedComputeKey_4717_, v___x_4721_);
if (v___x_4729_ == 0)
{
goto v___jp_4722_;
}
else
{
uint8_t v___x_4730_; uint8_t v___x_4731_;
v___x_4730_ = 0;
v___x_4731_ = lean_uint8_dec_eq(v_operatorBreakGlass_4720_, v___x_4730_);
if (v___x_4731_ == 0)
{
goto v___jp_4722_;
}
else
{
uint32_t v___x_4732_;
v___x_4732_ = 512;
return v___x_4732_;
}
}
v___jp_4722_:
{
uint8_t v___x_4723_;
v___x_4723_ = lean_uint8_dec_eq(v_callerOnManagedNode_4718_, v___x_4721_);
if (v___x_4723_ == 0)
{
uint32_t v___x_4724_;
v___x_4724_ = 257;
return v___x_4724_;
}
else
{
uint8_t v___x_4725_; uint8_t v___x_4726_;
v___x_4725_ = 0;
v___x_4726_ = lean_uint8_dec_eq(v_isAllowlistedManagedSecret_4719_, v___x_4725_);
if (v___x_4726_ == 0)
{
uint32_t v___x_4727_;
v___x_4727_ = 257;
return v___x_4727_;
}
else
{
uint32_t v___x_4728_;
v___x_4728_ = 512;
return v___x_4728_;
}
}
}
}
}

LEAN_EXPORT uint64_t orb_wire_apply_patch_step(uint64_t v_currentRev_4743_, uint64_t v_incomingRev_4744_, uint8_t v_currentHasVal_4745_, uint32_t v_currentVal_4746_, uint8_t v_presence_4747_, uint32_t v_incomingVal_4748_){
_start:
{
uint32_t v___y_4750_; uint32_t v___y_4751_; uint8_t v___x_4757_; uint32_t v___y_4759_; uint8_t v___y_4760_; uint8_t v___y_4761_; uint32_t v___y_4762_; uint32_t v___y_4768_; uint32_t v___y_4769_; uint8_t v___x_4783_; uint32_t v___y_4785_;
v___x_4757_ = 1;
v___x_4783_ = lean_uint8_dec_eq(v_currentHasVal_4745_, v___x_4757_);
if (v___x_4783_ == 0)
{
uint32_t v___x_4787_;
v___x_4787_ = 0;
v___y_4785_ = v___x_4787_;
goto v___jp_4784_;
}
else
{
uint32_t v___x_4788_;
v___x_4788_ = 512;
v___y_4785_ = v___x_4788_;
goto v___jp_4784_;
}
v___jp_4749_:
{
uint64_t v___x_4752_; uint64_t v___x_4753_; uint64_t v___x_4754_; uint64_t v___x_4755_; uint64_t v___x_4756_;
v___x_4752_ = lean_uint32_to_uint64(v___y_4750_);
v___x_4753_ = lean_uint32_to_uint64(v___y_4751_);
v___x_4754_ = 32ULL;
v___x_4755_ = lean_uint64_shift_left(v___x_4753_, v___x_4754_);
v___x_4756_ = lean_uint64_lor(v___x_4752_, v___x_4755_);
return v___x_4756_;
}
v___jp_4758_:
{
if (v___y_4760_ == 0)
{
v___y_4750_ = v___y_4762_;
v___y_4751_ = v___y_4759_;
goto v___jp_4749_;
}
else
{
if (v___y_4761_ == 0)
{
v___y_4750_ = v___y_4762_;
v___y_4751_ = v___y_4759_;
goto v___jp_4749_;
}
else
{
uint8_t v___x_4763_; uint8_t v___x_4764_;
v___x_4763_ = 0;
v___x_4764_ = lean_uint8_dec_eq(v_presence_4747_, v___x_4763_);
if (v___x_4764_ == 0)
{
uint8_t v___x_4765_;
v___x_4765_ = lean_uint8_dec_eq(v_presence_4747_, v___x_4757_);
if (v___x_4765_ == 0)
{
uint32_t v___x_4766_;
v___x_4766_ = 0;
v___y_4750_ = v___y_4762_;
v___y_4751_ = v___x_4766_;
goto v___jp_4749_;
}
else
{
v___y_4750_ = v___y_4762_;
v___y_4751_ = v_incomingVal_4748_;
goto v___jp_4749_;
}
}
else
{
v___y_4750_ = v___y_4762_;
v___y_4751_ = v___y_4759_;
goto v___jp_4749_;
}
}
}
}
v___jp_4767_:
{
uint8_t v___x_4770_; uint8_t v_validPresence_4771_; uint8_t v_freshRev_4772_;
v___x_4770_ = 2;
v_validPresence_4771_ = lean_uint8_dec_le(v_presence_4747_, v___x_4770_);
v_freshRev_4772_ = lean_uint64_dec_lt(v_currentRev_4743_, v_incomingRev_4744_);
if (v_validPresence_4771_ == 0)
{
uint32_t v___x_4773_;
v___x_4773_ = 0;
v___y_4759_ = v___y_4769_;
v___y_4760_ = v_validPresence_4771_;
v___y_4761_ = v_freshRev_4772_;
v___y_4762_ = v___x_4773_;
goto v___jp_4758_;
}
else
{
if (v_freshRev_4772_ == 0)
{
uint32_t v___x_4774_; uint32_t v___x_4775_;
v___x_4774_ = 2;
v___x_4775_ = lean_uint32_lor(v___x_4774_, v___y_4768_);
v___y_4759_ = v___y_4769_;
v___y_4760_ = v_validPresence_4771_;
v___y_4761_ = v_freshRev_4772_;
v___y_4762_ = v___x_4775_;
goto v___jp_4758_;
}
else
{
uint8_t v___x_4776_; uint8_t v___x_4777_;
v___x_4776_ = 0;
v___x_4777_ = lean_uint8_dec_eq(v_presence_4747_, v___x_4776_);
if (v___x_4777_ == 0)
{
uint8_t v___x_4778_;
v___x_4778_ = lean_uint8_dec_eq(v_presence_4747_, v___x_4757_);
if (v___x_4778_ == 0)
{
uint32_t v___x_4779_;
v___x_4779_ = 260;
v___y_4759_ = v___y_4769_;
v___y_4760_ = v_validPresence_4771_;
v___y_4761_ = v_freshRev_4772_;
v___y_4762_ = v___x_4779_;
goto v___jp_4758_;
}
else
{
uint32_t v___x_4780_;
v___x_4780_ = 769;
v___y_4759_ = v___y_4769_;
v___y_4760_ = v_validPresence_4771_;
v___y_4761_ = v_freshRev_4772_;
v___y_4762_ = v___x_4780_;
goto v___jp_4758_;
}
}
else
{
uint32_t v___x_4781_; uint32_t v___x_4782_;
v___x_4781_ = 259;
v___x_4782_ = lean_uint32_lor(v___x_4781_, v___y_4768_);
v___y_4759_ = v___y_4769_;
v___y_4760_ = v_validPresence_4771_;
v___y_4761_ = v_freshRev_4772_;
v___y_4762_ = v___x_4782_;
goto v___jp_4758_;
}
}
}
}
v___jp_4784_:
{
if (v___x_4783_ == 0)
{
uint32_t v___x_4786_;
v___x_4786_ = 0;
v___y_4768_ = v___y_4785_;
v___y_4769_ = v___x_4786_;
goto v___jp_4767_;
}
else
{
v___y_4768_ = v___y_4785_;
v___y_4769_ = v_currentVal_4746_;
goto v___jp_4767_;
}
}
}
}

LEAN_EXPORT uint64_t orb_wire_machine_step(uint32_t v_schemaId_4803_, uint64_t v_stateRev_4804_, uint64_t v_eventSeq_4805_, uint8_t v_effectKind_4806_, uint8_t v_effectAdmitted_4807_, uint32_t v_outCap_4808_, uint32_t v_requiredOutBytes_4809_){
_start:
{
uint32_t v___y_4811_; uint32_t v___y_4812_; uint32_t v_curRev32_4818_; uint8_t v_capOk_4819_; uint8_t v___y_4821_; uint8_t v___y_4822_; uint8_t v___y_4823_; uint32_t v___y_4824_; uint8_t v___y_4827_; uint8_t v___y_4828_; uint8_t v___y_4829_; uint32_t v___y_4830_; uint8_t v___y_4838_; uint8_t v___y_4839_; uint8_t v___y_4840_; uint8_t v___y_4846_; uint32_t v___x_4852_; uint8_t v___x_4853_;
v_curRev32_4818_ = lean_uint64_to_uint32(v_stateRev_4804_);
v_capOk_4819_ = lean_uint32_dec_le(v_requiredOutBytes_4809_, v_outCap_4808_);
v___x_4852_ = 1;
v___x_4853_ = lean_uint32_dec_le(v___x_4852_, v_schemaId_4803_);
if (v___x_4853_ == 0)
{
v___y_4846_ = v___x_4853_;
goto v___jp_4845_;
}
else
{
uint32_t v___x_4854_; uint8_t v___x_4855_;
v___x_4854_ = 2;
v___x_4855_ = lean_uint32_dec_le(v_schemaId_4803_, v___x_4854_);
v___y_4846_ = v___x_4855_;
goto v___jp_4845_;
}
v___jp_4810_:
{
uint64_t v___x_4813_; uint64_t v___x_4814_; uint64_t v___x_4815_; uint64_t v___x_4816_; uint64_t v___x_4817_;
v___x_4813_ = lean_uint32_to_uint64(v___y_4811_);
v___x_4814_ = lean_uint32_to_uint64(v___y_4812_);
v___x_4815_ = 32ULL;
v___x_4816_ = lean_uint64_shift_left(v___x_4814_, v___x_4815_);
v___x_4817_ = lean_uint64_lor(v___x_4813_, v___x_4816_);
return v___x_4817_;
}
v___jp_4820_:
{
if (v_capOk_4819_ == 0)
{
v___y_4811_ = v___y_4824_;
v___y_4812_ = v_curRev32_4818_;
goto v___jp_4810_;
}
else
{
if (v___y_4823_ == 0)
{
v___y_4811_ = v___y_4824_;
v___y_4812_ = v_curRev32_4818_;
goto v___jp_4810_;
}
else
{
if (v___y_4821_ == 0)
{
v___y_4811_ = v___y_4824_;
v___y_4812_ = v_curRev32_4818_;
goto v___jp_4810_;
}
else
{
if (v___y_4822_ == 0)
{
v___y_4811_ = v___y_4824_;
v___y_4812_ = v_curRev32_4818_;
goto v___jp_4810_;
}
else
{
uint32_t v___x_4825_;
v___x_4825_ = lean_uint64_to_uint32(v_eventSeq_4805_);
v___y_4811_ = v___y_4824_;
v___y_4812_ = v___x_4825_;
goto v___jp_4810_;
}
}
}
}
}
v___jp_4826_:
{
if (v_capOk_4819_ == 0)
{
uint32_t v___x_4831_;
v___x_4831_ = 5;
v___y_4821_ = v___y_4827_;
v___y_4822_ = v___y_4828_;
v___y_4823_ = v___y_4829_;
v___y_4824_ = v___x_4831_;
goto v___jp_4820_;
}
else
{
if (v___y_4829_ == 0)
{
uint32_t v___x_4832_;
v___x_4832_ = 2;
v___y_4821_ = v___y_4827_;
v___y_4822_ = v___y_4828_;
v___y_4823_ = v___y_4829_;
v___y_4824_ = v___x_4832_;
goto v___jp_4820_;
}
else
{
if (v___y_4827_ == 0)
{
uint32_t v___x_4833_;
v___x_4833_ = 3;
v___y_4821_ = v___y_4827_;
v___y_4822_ = v___y_4828_;
v___y_4823_ = v___y_4829_;
v___y_4824_ = v___x_4833_;
goto v___jp_4820_;
}
else
{
if (v___y_4828_ == 0)
{
uint32_t v___x_4834_;
v___x_4834_ = 4;
v___y_4821_ = v___y_4827_;
v___y_4822_ = v___y_4828_;
v___y_4823_ = v___y_4829_;
v___y_4824_ = v___x_4834_;
goto v___jp_4820_;
}
else
{
uint32_t v___x_4835_; uint32_t v___x_4836_;
v___x_4835_ = 257;
v___x_4836_ = lean_uint32_lor(v___x_4835_, v___y_4830_);
v___y_4821_ = v___y_4827_;
v___y_4822_ = v___y_4828_;
v___y_4823_ = v___y_4829_;
v___y_4824_ = v___x_4836_;
goto v___jp_4820_;
}
}
}
}
}
v___jp_4837_:
{
uint8_t v___x_4841_; uint8_t v___x_4842_;
v___x_4841_ = 0;
v___x_4842_ = lean_uint8_dec_eq(v_effectKind_4806_, v___x_4841_);
if (v___x_4842_ == 0)
{
uint32_t v___x_4843_;
v___x_4843_ = 512;
v___y_4827_ = v___y_4838_;
v___y_4828_ = v___y_4840_;
v___y_4829_ = v___y_4839_;
v___y_4830_ = v___x_4843_;
goto v___jp_4826_;
}
else
{
uint32_t v___x_4844_;
v___x_4844_ = 0;
v___y_4827_ = v___y_4838_;
v___y_4828_ = v___y_4840_;
v___y_4829_ = v___y_4839_;
v___y_4830_ = v___x_4844_;
goto v___jp_4826_;
}
}
v___jp_4845_:
{
uint8_t v_seqFresh_4847_; uint8_t v___x_4848_; uint8_t v___x_4849_;
v_seqFresh_4847_ = lean_uint64_dec_lt(v_stateRev_4804_, v_eventSeq_4805_);
v___x_4848_ = 1;
v___x_4849_ = lean_uint8_dec_eq(v_effectAdmitted_4807_, v___x_4848_);
if (v___x_4849_ == 0)
{
v___y_4838_ = v_seqFresh_4847_;
v___y_4839_ = v___y_4846_;
v___y_4840_ = v___x_4849_;
goto v___jp_4837_;
}
else
{
uint8_t v___x_4850_; uint8_t v___x_4851_;
v___x_4850_ = 5;
v___x_4851_ = lean_uint8_dec_le(v_effectKind_4806_, v___x_4850_);
v___y_4838_ = v_seqFresh_4847_;
v___y_4839_ = v___y_4846_;
v___y_4840_ = v___x_4851_;
goto v___jp_4837_;
}
}
}
}

LEAN_EXPORT uint64_t orb_hierarchy_merge_step(uint64_t v_currentEpoch_4872_, uint64_t v_incomingEpoch_4873_, uint64_t v_archiveEpoch_4874_, uint8_t v_curArchived_4875_, uint8_t v_curSuperseded_4876_, uint8_t v_isPartialPatch_4877_, uint8_t v_parentPresence_4878_, uint32_t v_curParentOrd_4879_, uint32_t v_incParentOrd_4880_, uint8_t v_incArchive_4881_, uint8_t v_incUnarchive_4882_, uint8_t v_incSupersede_4883_){
_start:
{
uint32_t v___y_4885_; uint32_t v___y_4886_; uint32_t v___y_4887_; uint32_t v___y_4888_; uint32_t v___y_4889_; uint32_t v___y_4899_; uint32_t v___y_4900_; uint32_t v___y_4901_; uint32_t v___y_4902_; uint32_t v___y_4905_; uint32_t v___y_4906_; uint32_t v___y_4907_; uint8_t v___y_4910_; uint32_t v___y_4911_; uint32_t v___y_4912_; uint8_t v___y_4913_; uint8_t v___y_4914_; uint32_t v___y_4915_; uint8_t v___y_4920_; uint8_t v___y_4921_; uint32_t v___y_4922_; uint8_t v___y_4923_; uint8_t v___y_4924_; uint32_t v___y_4925_; uint8_t v___y_4929_; uint8_t v___y_4930_; uint8_t v___y_4931_; uint8_t v___y_4932_; uint8_t v___y_4933_; uint32_t v___y_4934_; uint8_t v___x_4937_; uint8_t v___y_4939_; uint8_t v___y_4940_; uint8_t v___y_4941_; uint8_t v___y_4942_; uint8_t v___y_4943_; uint8_t v___y_4944_; uint8_t v___y_4945_; uint8_t v___y_4946_; uint8_t v___y_4947_; uint8_t v___y_4956_; uint8_t v___y_4957_; uint8_t v___y_4958_; uint8_t v___y_4959_; uint8_t v___y_4960_; uint8_t v___y_4961_; uint8_t v___y_4962_; uint8_t v___y_4963_; uint8_t v___y_4964_; uint8_t v___x_4966_; uint8_t v___y_4968_; uint8_t v___y_4969_; uint8_t v___y_4970_; uint8_t v___y_4971_; uint8_t v___y_4972_; uint8_t v___y_4973_; uint8_t v___y_4974_; uint8_t v___y_4975_; uint8_t v___y_4976_; uint8_t v___y_4979_; uint8_t v___y_4980_; uint8_t v___y_4981_; uint8_t v___y_4982_; uint8_t v___y_4983_; uint8_t v___y_4984_; uint8_t v___y_4985_; uint8_t v___y_4986_; uint8_t v___y_4987_; uint8_t v___y_4989_; uint8_t v___y_4990_; uint8_t v___y_4991_; uint8_t v___y_4992_; uint8_t v___y_4993_; uint8_t v___y_4994_; uint8_t v___y_4995_; uint8_t v___y_4996_; uint8_t v___y_4997_; uint8_t v___y_5001_;
v___x_4937_ = 1;
v___x_4966_ = lean_uint8_dec_eq(v_curSuperseded_4876_, v___x_4937_);
if (v___x_4966_ == 0)
{
uint8_t v___x_5012_;
v___x_5012_ = lean_uint8_dec_eq(v_incSupersede_4883_, v___x_4937_);
v___y_5001_ = v___x_5012_;
goto v___jp_5000_;
}
else
{
v___y_5001_ = v___x_4966_;
goto v___jp_5000_;
}
v___jp_4884_:
{
uint32_t v___x_4890_; uint32_t v___x_4891_; uint32_t v_lo32_4892_; uint64_t v___x_4893_; uint64_t v___x_4894_; uint64_t v___x_4895_; uint64_t v___x_4896_; uint64_t v___x_4897_;
v___x_4890_ = lean_uint32_lor(v___y_4889_, v___y_4886_);
v___x_4891_ = lean_uint32_lor(v___x_4890_, v___y_4885_);
v_lo32_4892_ = lean_uint32_lor(v___x_4891_, v___y_4888_);
v___x_4893_ = lean_uint32_to_uint64(v_lo32_4892_);
v___x_4894_ = lean_uint32_to_uint64(v___y_4887_);
v___x_4895_ = 32ULL;
v___x_4896_ = lean_uint64_shift_left(v___x_4894_, v___x_4895_);
v___x_4897_ = lean_uint64_lor(v___x_4893_, v___x_4896_);
return v___x_4897_;
}
v___jp_4898_:
{
uint32_t v___x_4903_;
v___x_4903_ = 257;
v___y_4885_ = v___y_4899_;
v___y_4886_ = v___y_4900_;
v___y_4887_ = v___y_4901_;
v___y_4888_ = v___y_4902_;
v___y_4889_ = v___x_4903_;
goto v___jp_4884_;
}
v___jp_4904_:
{
uint32_t v___x_4908_;
v___x_4908_ = 0;
v___y_4899_ = v___y_4905_;
v___y_4900_ = v___y_4906_;
v___y_4901_ = v___y_4907_;
v___y_4902_ = v___x_4908_;
goto v___jp_4898_;
}
v___jp_4909_:
{
if (v___y_4913_ == 0)
{
uint32_t v___x_4916_; uint32_t v___x_4917_;
v___x_4916_ = 0;
v___x_4917_ = 2;
v___y_4885_ = v___y_4915_;
v___y_4886_ = v___y_4911_;
v___y_4887_ = v___y_4912_;
v___y_4888_ = v___x_4916_;
v___y_4889_ = v___x_4917_;
goto v___jp_4884_;
}
else
{
if (v___y_4910_ == 0)
{
v___y_4905_ = v___y_4915_;
v___y_4906_ = v___y_4911_;
v___y_4907_ = v___y_4912_;
goto v___jp_4904_;
}
else
{
if (v___y_4914_ == 0)
{
v___y_4905_ = v___y_4915_;
v___y_4906_ = v___y_4911_;
v___y_4907_ = v___y_4912_;
goto v___jp_4904_;
}
else
{
uint32_t v___x_4918_;
v___x_4918_ = 2048;
v___y_4899_ = v___y_4915_;
v___y_4900_ = v___y_4911_;
v___y_4901_ = v___y_4912_;
v___y_4902_ = v___x_4918_;
goto v___jp_4898_;
}
}
}
}
v___jp_4919_:
{
if (v___y_4923_ == 0)
{
uint32_t v___x_4926_;
v___x_4926_ = 0;
v___y_4910_ = v___y_4920_;
v___y_4911_ = v___y_4925_;
v___y_4912_ = v___y_4922_;
v___y_4913_ = v___y_4921_;
v___y_4914_ = v___y_4924_;
v___y_4915_ = v___x_4926_;
goto v___jp_4909_;
}
else
{
uint32_t v___x_4927_;
v___x_4927_ = 1024;
v___y_4910_ = v___y_4920_;
v___y_4911_ = v___y_4925_;
v___y_4912_ = v___y_4922_;
v___y_4913_ = v___y_4921_;
v___y_4914_ = v___y_4924_;
v___y_4915_ = v___x_4927_;
goto v___jp_4909_;
}
}
v___jp_4928_:
{
if (v___y_4931_ == 0)
{
uint32_t v___x_4935_;
v___x_4935_ = 0;
v___y_4920_ = v___y_4929_;
v___y_4921_ = v___y_4930_;
v___y_4922_ = v___y_4934_;
v___y_4923_ = v___y_4932_;
v___y_4924_ = v___y_4933_;
v___y_4925_ = v___x_4935_;
goto v___jp_4919_;
}
else
{
uint32_t v___x_4936_;
v___x_4936_ = 512;
v___y_4920_ = v___y_4929_;
v___y_4921_ = v___y_4930_;
v___y_4922_ = v___y_4934_;
v___y_4923_ = v___y_4932_;
v___y_4924_ = v___y_4933_;
v___y_4925_ = v___x_4936_;
goto v___jp_4919_;
}
}
v___jp_4938_:
{
if (v___y_4941_ == 0)
{
v___y_4929_ = v___y_4939_;
v___y_4930_ = v___y_4941_;
v___y_4931_ = v___y_4942_;
v___y_4932_ = v___y_4943_;
v___y_4933_ = v___y_4944_;
v___y_4934_ = v_curParentOrd_4879_;
goto v___jp_4928_;
}
else
{
if (v___y_4946_ == 0)
{
v___y_4929_ = v___y_4939_;
v___y_4930_ = v___y_4946_;
v___y_4931_ = v___y_4942_;
v___y_4932_ = v___y_4943_;
v___y_4933_ = v___y_4944_;
v___y_4934_ = v_curParentOrd_4879_;
goto v___jp_4928_;
}
else
{
if (v___y_4940_ == 0)
{
if (v___y_4947_ == 0)
{
if (v___y_4945_ == 0)
{
uint8_t v___x_4948_;
v___x_4948_ = lean_uint8_dec_eq(v_parentPresence_4878_, v___x_4937_);
if (v___x_4948_ == 0)
{
uint32_t v___x_4949_;
v___x_4949_ = 0;
v___y_4929_ = v___y_4939_;
v___y_4930_ = v___y_4946_;
v___y_4931_ = v___y_4942_;
v___y_4932_ = v___y_4943_;
v___y_4933_ = v___y_4944_;
v___y_4934_ = v___x_4949_;
goto v___jp_4928_;
}
else
{
v___y_4929_ = v___y_4939_;
v___y_4930_ = v___y_4946_;
v___y_4931_ = v___y_4942_;
v___y_4932_ = v___y_4943_;
v___y_4933_ = v___y_4944_;
v___y_4934_ = v_incParentOrd_4880_;
goto v___jp_4928_;
}
}
else
{
uint8_t v___x_4950_; uint8_t v___x_4951_;
v___x_4950_ = 0;
v___x_4951_ = lean_uint8_dec_eq(v_parentPresence_4878_, v___x_4950_);
if (v___x_4951_ == 0)
{
uint8_t v___x_4952_;
v___x_4952_ = lean_uint8_dec_eq(v_parentPresence_4878_, v___x_4937_);
if (v___x_4952_ == 0)
{
uint32_t v___x_4953_;
v___x_4953_ = 0;
v___y_4929_ = v___y_4939_;
v___y_4930_ = v___y_4946_;
v___y_4931_ = v___y_4942_;
v___y_4932_ = v___y_4943_;
v___y_4933_ = v___y_4944_;
v___y_4934_ = v___x_4953_;
goto v___jp_4928_;
}
else
{
v___y_4929_ = v___y_4939_;
v___y_4930_ = v___y_4946_;
v___y_4931_ = v___y_4942_;
v___y_4932_ = v___y_4943_;
v___y_4933_ = v___y_4944_;
v___y_4934_ = v_incParentOrd_4880_;
goto v___jp_4928_;
}
}
else
{
v___y_4929_ = v___y_4939_;
v___y_4930_ = v___y_4946_;
v___y_4931_ = v___y_4942_;
v___y_4932_ = v___y_4943_;
v___y_4933_ = v___y_4944_;
v___y_4934_ = v_curParentOrd_4879_;
goto v___jp_4928_;
}
}
}
else
{
v___y_4929_ = v___y_4939_;
v___y_4930_ = v___y_4940_;
v___y_4931_ = v___y_4942_;
v___y_4932_ = v___y_4943_;
v___y_4933_ = v___y_4944_;
v___y_4934_ = v_curParentOrd_4879_;
goto v___jp_4928_;
}
}
else
{
uint8_t v___x_4954_;
v___x_4954_ = 0;
v___y_4929_ = v___y_4939_;
v___y_4930_ = v___x_4954_;
v___y_4931_ = v___y_4942_;
v___y_4932_ = v___y_4943_;
v___y_4933_ = v___y_4944_;
v___y_4934_ = v_curParentOrd_4879_;
goto v___jp_4928_;
}
}
}
}
v___jp_4955_:
{
if (v___y_4962_ == 0)
{
v___y_4939_ = v___y_4957_;
v___y_4940_ = v___y_4964_;
v___y_4941_ = v___y_4958_;
v___y_4942_ = v___y_4960_;
v___y_4943_ = v___y_4959_;
v___y_4944_ = v___y_4962_;
v___y_4945_ = v___y_4961_;
v___y_4946_ = v___y_4963_;
v___y_4947_ = v___y_4962_;
goto v___jp_4938_;
}
else
{
if (v___y_4959_ == 0)
{
if (v___y_4956_ == 0)
{
if (v___y_4957_ == 0)
{
v___y_4939_ = v___y_4957_;
v___y_4940_ = v___y_4964_;
v___y_4941_ = v___y_4958_;
v___y_4942_ = v___y_4960_;
v___y_4943_ = v___y_4959_;
v___y_4944_ = v___y_4962_;
v___y_4945_ = v___y_4961_;
v___y_4946_ = v___y_4963_;
v___y_4947_ = v___y_4962_;
goto v___jp_4938_;
}
else
{
v___y_4939_ = v___y_4957_;
v___y_4940_ = v___y_4964_;
v___y_4941_ = v___y_4958_;
v___y_4942_ = v___y_4960_;
v___y_4943_ = v___y_4959_;
v___y_4944_ = v___y_4962_;
v___y_4945_ = v___y_4961_;
v___y_4946_ = v___y_4963_;
v___y_4947_ = v___y_4956_;
goto v___jp_4938_;
}
}
else
{
v___y_4939_ = v___y_4957_;
v___y_4940_ = v___y_4964_;
v___y_4941_ = v___y_4958_;
v___y_4942_ = v___y_4960_;
v___y_4943_ = v___y_4959_;
v___y_4944_ = v___y_4962_;
v___y_4945_ = v___y_4961_;
v___y_4946_ = v___y_4963_;
v___y_4947_ = v___y_4959_;
goto v___jp_4938_;
}
}
else
{
uint8_t v___x_4965_;
v___x_4965_ = 0;
v___y_4939_ = v___y_4957_;
v___y_4940_ = v___y_4964_;
v___y_4941_ = v___y_4958_;
v___y_4942_ = v___y_4960_;
v___y_4943_ = v___y_4959_;
v___y_4944_ = v___y_4962_;
v___y_4945_ = v___y_4961_;
v___y_4946_ = v___y_4963_;
v___y_4947_ = v___x_4965_;
goto v___jp_4938_;
}
}
}
v___jp_4967_:
{
if (v___x_4966_ == 0)
{
v___y_4956_ = v___y_4968_;
v___y_4957_ = v___y_4970_;
v___y_4958_ = v___y_4971_;
v___y_4959_ = v___y_4972_;
v___y_4960_ = v___y_4976_;
v___y_4961_ = v___y_4974_;
v___y_4962_ = v___y_4973_;
v___y_4963_ = v___y_4975_;
v___y_4964_ = v___x_4966_;
goto v___jp_4955_;
}
else
{
if (v___y_4969_ == 0)
{
v___y_4956_ = v___y_4968_;
v___y_4957_ = v___y_4970_;
v___y_4958_ = v___y_4971_;
v___y_4959_ = v___y_4972_;
v___y_4960_ = v___y_4976_;
v___y_4961_ = v___y_4974_;
v___y_4962_ = v___y_4973_;
v___y_4963_ = v___y_4975_;
v___y_4964_ = v___x_4966_;
goto v___jp_4955_;
}
else
{
uint8_t v___x_4977_;
v___x_4977_ = 0;
v___y_4956_ = v___y_4968_;
v___y_4957_ = v___y_4970_;
v___y_4958_ = v___y_4971_;
v___y_4959_ = v___y_4972_;
v___y_4960_ = v___y_4976_;
v___y_4961_ = v___y_4974_;
v___y_4962_ = v___y_4973_;
v___y_4963_ = v___y_4975_;
v___y_4964_ = v___x_4977_;
goto v___jp_4955_;
}
}
}
v___jp_4978_:
{
if (v___y_4982_ == 0)
{
v___y_4968_ = v___y_4980_;
v___y_4969_ = v___y_4981_;
v___y_4970_ = v___y_4987_;
v___y_4971_ = v___y_4982_;
v___y_4972_ = v___y_4983_;
v___y_4973_ = v___y_4985_;
v___y_4974_ = v___y_4984_;
v___y_4975_ = v___y_4986_;
v___y_4976_ = v___y_4985_;
goto v___jp_4967_;
}
else
{
if (v___y_4986_ == 0)
{
v___y_4968_ = v___y_4980_;
v___y_4969_ = v___y_4981_;
v___y_4970_ = v___y_4987_;
v___y_4971_ = v___y_4982_;
v___y_4972_ = v___y_4983_;
v___y_4973_ = v___y_4985_;
v___y_4974_ = v___y_4984_;
v___y_4975_ = v___y_4986_;
v___y_4976_ = v___y_4985_;
goto v___jp_4967_;
}
else
{
if (v___y_4980_ == 0)
{
if (v___y_4987_ == 0)
{
v___y_4968_ = v___y_4980_;
v___y_4969_ = v___y_4981_;
v___y_4970_ = v___y_4987_;
v___y_4971_ = v___y_4982_;
v___y_4972_ = v___y_4983_;
v___y_4973_ = v___y_4985_;
v___y_4974_ = v___y_4984_;
v___y_4975_ = v___y_4986_;
v___y_4976_ = v___y_4985_;
goto v___jp_4967_;
}
else
{
v___y_4968_ = v___y_4980_;
v___y_4969_ = v___y_4981_;
v___y_4970_ = v___y_4987_;
v___y_4971_ = v___y_4982_;
v___y_4972_ = v___y_4983_;
v___y_4973_ = v___y_4985_;
v___y_4974_ = v___y_4984_;
v___y_4975_ = v___y_4986_;
v___y_4976_ = v___y_4980_;
goto v___jp_4967_;
}
}
else
{
v___y_4968_ = v___y_4980_;
v___y_4969_ = v___y_4981_;
v___y_4970_ = v___y_4987_;
v___y_4971_ = v___y_4982_;
v___y_4972_ = v___y_4983_;
v___y_4973_ = v___y_4985_;
v___y_4974_ = v___y_4984_;
v___y_4975_ = v___y_4986_;
v___y_4976_ = v___y_4979_;
goto v___jp_4967_;
}
}
}
}
v___jp_4988_:
{
if (v___y_4994_ == 0)
{
if (v___y_4992_ == 0)
{
v___y_4979_ = v___y_4990_;
v___y_4980_ = v___y_4989_;
v___y_4981_ = v___y_4991_;
v___y_4982_ = v___y_4993_;
v___y_4983_ = v___y_4994_;
v___y_4984_ = v___y_4996_;
v___y_4985_ = v___y_4995_;
v___y_4986_ = v___y_4997_;
v___y_4987_ = v___y_4992_;
goto v___jp_4978_;
}
else
{
if (v___y_4989_ == 0)
{
uint8_t v_unarchEpochOk_4998_;
v_unarchEpochOk_4998_ = lean_uint64_dec_lt(v_archiveEpoch_4874_, v_incomingEpoch_4873_);
v___y_4979_ = v___y_4990_;
v___y_4980_ = v___y_4989_;
v___y_4981_ = v___y_4991_;
v___y_4982_ = v___y_4993_;
v___y_4983_ = v___y_4994_;
v___y_4984_ = v___y_4996_;
v___y_4985_ = v___y_4995_;
v___y_4986_ = v___y_4997_;
v___y_4987_ = v_unarchEpochOk_4998_;
goto v___jp_4978_;
}
else
{
v___y_4979_ = v___y_4990_;
v___y_4980_ = v___y_4989_;
v___y_4981_ = v___y_4991_;
v___y_4982_ = v___y_4993_;
v___y_4983_ = v___y_4994_;
v___y_4984_ = v___y_4996_;
v___y_4985_ = v___y_4995_;
v___y_4986_ = v___y_4997_;
v___y_4987_ = v___y_4994_;
goto v___jp_4978_;
}
}
}
else
{
uint8_t v___x_4999_;
v___x_4999_ = 0;
v___y_4968_ = v___y_4989_;
v___y_4969_ = v___y_4991_;
v___y_4970_ = v___x_4999_;
v___y_4971_ = v___y_4993_;
v___y_4972_ = v___y_4994_;
v___y_4973_ = v___y_4995_;
v___y_4974_ = v___y_4996_;
v___y_4975_ = v___y_4997_;
v___y_4976_ = v___y_4990_;
goto v___jp_4967_;
}
}
v___jp_5000_:
{
uint8_t v_curArchBool_5002_; uint8_t v_incArchBool_5003_; uint8_t v_incUnarchBool_5004_; uint8_t v_incSupBool_5005_; uint8_t v___x_5006_; uint8_t v_validPresence_5007_; uint8_t v___x_5008_; uint8_t v___x_5009_;
v_curArchBool_5002_ = lean_uint8_dec_eq(v_curArchived_4875_, v___x_4937_);
v_incArchBool_5003_ = lean_uint8_dec_eq(v_incArchive_4881_, v___x_4937_);
v_incUnarchBool_5004_ = lean_uint8_dec_eq(v_incUnarchive_4882_, v___x_4937_);
v_incSupBool_5005_ = lean_uint8_dec_eq(v_incSupersede_4883_, v___x_4937_);
v___x_5006_ = 2;
v_validPresence_5007_ = lean_uint8_dec_le(v_parentPresence_4878_, v___x_5006_);
v___x_5008_ = lean_uint8_dec_eq(v_isPartialPatch_4877_, v___x_4937_);
v___x_5009_ = 1;
if (v___x_5008_ == 0)
{
uint8_t v___x_5010_;
v___x_5010_ = lean_uint64_dec_le(v_currentEpoch_4872_, v_incomingEpoch_4873_);
v___y_4989_ = v_incArchBool_5003_;
v___y_4990_ = v___x_5009_;
v___y_4991_ = v_incSupBool_5005_;
v___y_4992_ = v_incUnarchBool_5004_;
v___y_4993_ = v_validPresence_5007_;
v___y_4994_ = v___y_5001_;
v___y_4995_ = v_curArchBool_5002_;
v___y_4996_ = v___x_5008_;
v___y_4997_ = v___x_5010_;
goto v___jp_4988_;
}
else
{
uint8_t v___x_5011_;
v___x_5011_ = lean_uint64_dec_lt(v_currentEpoch_4872_, v_incomingEpoch_4873_);
v___y_4989_ = v_incArchBool_5003_;
v___y_4990_ = v___x_5009_;
v___y_4991_ = v_incSupBool_5005_;
v___y_4992_ = v_incUnarchBool_5004_;
v___y_4993_ = v_validPresence_5007_;
v___y_4994_ = v___y_5001_;
v___y_4995_ = v_curArchBool_5002_;
v___y_4996_ = v___x_5008_;
v___y_4997_ = v___x_5011_;
goto v___jp_4988_;
}
}
}
}

LEAN_EXPORT uint64_t orb_transcript_fold_step(uint64_t v_lastAppliedSeq_5132_, uint64_t v_incomingSeq_5133_, uint32_t v_entryCount_5134_, uint8_t v_thinkingOpen_5135_, uint8_t v_normalizedAction_5136_, uint8_t v_isReplayFromLog_5137_){
_start:
{
uint32_t v___y_5139_; uint32_t v___y_5140_; uint32_t v___y_5147_; uint8_t v___y_5154_; uint32_t v___y_5155_; uint8_t v___x_5156_; uint8_t v___x_5157_; uint8_t v___y_5159_; uint8_t v___y_5160_; uint8_t v___y_5161_; uint32_t v___y_5162_; uint8_t v___y_5163_; uint8_t v___y_5164_; uint8_t v___x_5176_; uint8_t v___y_5178_; uint8_t v___y_5179_; uint32_t v___y_5180_; uint8_t v___y_5181_; uint8_t v___y_5182_; uint8_t v___y_5190_; uint32_t v___y_5191_; uint8_t v___y_5192_; uint32_t v___y_5206_;
v___x_5156_ = 1;
v___x_5157_ = lean_uint8_dec_eq(v_thinkingOpen_5135_, v___x_5156_);
v___x_5176_ = 1;
if (v___x_5157_ == 0)
{
uint32_t v___x_5212_;
v___x_5212_ = 0;
v___y_5206_ = v___x_5212_;
goto v___jp_5205_;
}
else
{
uint32_t v___x_5213_;
v___x_5213_ = 512;
v___y_5206_ = v___x_5213_;
goto v___jp_5205_;
}
v___jp_5138_:
{
uint64_t v___x_5141_; uint64_t v___x_5142_; uint64_t v___x_5143_; uint64_t v___x_5144_; uint64_t v___x_5145_;
v___x_5141_ = lean_uint32_to_uint64(v___y_5139_);
v___x_5142_ = lean_uint32_to_uint64(v___y_5140_);
v___x_5143_ = 32ULL;
v___x_5144_ = lean_uint64_shift_left(v___x_5142_, v___x_5143_);
v___x_5145_ = lean_uint64_lor(v___x_5141_, v___x_5144_);
return v___x_5145_;
}
v___jp_5146_:
{
uint32_t v___x_5148_; uint8_t v___x_5149_;
v___x_5148_ = 4294967294;
v___x_5149_ = lean_uint32_dec_le(v_entryCount_5134_, v___x_5148_);
if (v___x_5149_ == 0)
{
uint32_t v___x_5150_;
v___x_5150_ = 4294967295;
v___y_5139_ = v___y_5147_;
v___y_5140_ = v___x_5150_;
goto v___jp_5138_;
}
else
{
uint32_t v___x_5151_; uint32_t v___x_5152_;
v___x_5151_ = 1;
v___x_5152_ = lean_uint32_add(v_entryCount_5134_, v___x_5151_);
v___y_5139_ = v___y_5147_;
v___y_5140_ = v___x_5152_;
goto v___jp_5138_;
}
}
v___jp_5153_:
{
if (v___y_5154_ == 0)
{
v___y_5139_ = v___y_5155_;
v___y_5140_ = v_entryCount_5134_;
goto v___jp_5138_;
}
else
{
v___y_5147_ = v___y_5155_;
goto v___jp_5146_;
}
}
v___jp_5158_:
{
if (v___y_5160_ == 0)
{
if (v___y_5161_ == 0)
{
uint32_t v___x_5165_; uint32_t v___x_5166_;
v___x_5165_ = 2051;
v___x_5166_ = lean_uint32_lor(v___x_5165_, v___y_5162_);
v___y_5139_ = v___x_5166_;
v___y_5140_ = v_entryCount_5134_;
goto v___jp_5138_;
}
else
{
if (v___y_5163_ == 0)
{
if (v___y_5159_ == 0)
{
if (v___y_5164_ == 0)
{
uint32_t v___x_5167_; uint32_t v___x_5168_;
v___x_5167_ = 4;
v___x_5168_ = lean_uint32_lor(v___x_5167_, v___y_5162_);
v___y_5139_ = v___x_5168_;
v___y_5140_ = v_entryCount_5134_;
goto v___jp_5138_;
}
else
{
uint32_t v___x_5169_; uint32_t v___x_5170_;
v___x_5169_ = 260;
v___x_5170_ = lean_uint32_lor(v___x_5169_, v___y_5162_);
v___y_5139_ = v___x_5170_;
v___y_5140_ = v_entryCount_5134_;
goto v___jp_5138_;
}
}
else
{
if (v___x_5157_ == 0)
{
uint32_t v___x_5171_;
v___x_5171_ = 257;
v___y_5147_ = v___x_5171_;
goto v___jp_5146_;
}
else
{
uint32_t v___x_5172_;
v___x_5172_ = 1281;
v___y_5147_ = v___x_5172_;
goto v___jp_5146_;
}
}
}
else
{
uint32_t v___x_5173_;
v___x_5173_ = 769;
v___y_5154_ = v___y_5159_;
v___y_5155_ = v___x_5173_;
goto v___jp_5153_;
}
}
}
else
{
uint32_t v___x_5174_; uint32_t v___x_5175_;
v___x_5174_ = 2;
v___x_5175_ = lean_uint32_lor(v___x_5174_, v___y_5162_);
if (v___y_5161_ == 0)
{
v___y_5139_ = v___x_5175_;
v___y_5140_ = v_entryCount_5134_;
goto v___jp_5138_;
}
else
{
v___y_5154_ = v___y_5159_;
v___y_5155_ = v___x_5175_;
goto v___jp_5153_;
}
}
}
v___jp_5177_:
{
uint8_t v___x_5183_; uint8_t v___x_5184_;
v___x_5183_ = 2;
v___x_5184_ = lean_uint8_dec_eq(v_normalizedAction_5136_, v___x_5183_);
if (v___x_5184_ == 0)
{
uint8_t v___x_5185_; uint8_t v___x_5186_;
v___x_5185_ = 3;
v___x_5186_ = lean_uint8_dec_eq(v_normalizedAction_5136_, v___x_5185_);
if (v___x_5186_ == 0)
{
uint8_t v___x_5187_; uint8_t v___x_5188_;
v___x_5187_ = 8;
v___x_5188_ = lean_uint8_dec_eq(v_normalizedAction_5136_, v___x_5187_);
v___y_5159_ = v___y_5182_;
v___y_5160_ = v___y_5178_;
v___y_5161_ = v___y_5179_;
v___y_5162_ = v___y_5180_;
v___y_5163_ = v___y_5181_;
v___y_5164_ = v___x_5188_;
goto v___jp_5158_;
}
else
{
v___y_5159_ = v___y_5182_;
v___y_5160_ = v___y_5178_;
v___y_5161_ = v___y_5179_;
v___y_5162_ = v___y_5180_;
v___y_5163_ = v___y_5181_;
v___y_5164_ = v___x_5176_;
goto v___jp_5158_;
}
}
else
{
v___y_5159_ = v___y_5182_;
v___y_5160_ = v___y_5178_;
v___y_5161_ = v___y_5179_;
v___y_5162_ = v___y_5180_;
v___y_5163_ = v___y_5181_;
v___y_5164_ = v___x_5176_;
goto v___jp_5158_;
}
}
v___jp_5189_:
{
uint8_t v___x_5193_; uint8_t v_isOpenThink_5194_; uint8_t v___x_5195_; uint8_t v___x_5196_;
v___x_5193_ = 4;
v_isOpenThink_5194_ = lean_uint8_dec_eq(v_normalizedAction_5136_, v___x_5193_);
v___x_5195_ = 5;
v___x_5196_ = lean_uint8_dec_eq(v_normalizedAction_5136_, v___x_5195_);
if (v___x_5196_ == 0)
{
uint8_t v___x_5197_; uint8_t v___x_5198_;
v___x_5197_ = 6;
v___x_5198_ = lean_uint8_dec_eq(v_normalizedAction_5136_, v___x_5197_);
if (v___x_5198_ == 0)
{
uint8_t v___x_5199_; uint8_t v___x_5200_;
v___x_5199_ = 7;
v___x_5200_ = lean_uint8_dec_eq(v_normalizedAction_5136_, v___x_5199_);
if (v___x_5200_ == 0)
{
uint8_t v___x_5201_; uint8_t v___x_5202_;
v___x_5201_ = 9;
v___x_5202_ = lean_uint8_dec_eq(v_normalizedAction_5136_, v___x_5201_);
if (v___x_5202_ == 0)
{
uint8_t v___x_5203_; uint8_t v___x_5204_;
v___x_5203_ = 10;
v___x_5204_ = lean_uint8_dec_eq(v_normalizedAction_5136_, v___x_5203_);
v___y_5178_ = v___y_5190_;
v___y_5179_ = v___y_5192_;
v___y_5180_ = v___y_5191_;
v___y_5181_ = v_isOpenThink_5194_;
v___y_5182_ = v___x_5204_;
goto v___jp_5177_;
}
else
{
v___y_5178_ = v___y_5190_;
v___y_5179_ = v___y_5192_;
v___y_5180_ = v___y_5191_;
v___y_5181_ = v_isOpenThink_5194_;
v___y_5182_ = v___x_5176_;
goto v___jp_5177_;
}
}
else
{
v___y_5178_ = v___y_5190_;
v___y_5179_ = v___y_5192_;
v___y_5180_ = v___y_5191_;
v___y_5181_ = v_isOpenThink_5194_;
v___y_5182_ = v___x_5176_;
goto v___jp_5177_;
}
}
else
{
v___y_5178_ = v___y_5190_;
v___y_5179_ = v___y_5192_;
v___y_5180_ = v___y_5191_;
v___y_5181_ = v_isOpenThink_5194_;
v___y_5182_ = v___x_5176_;
goto v___jp_5177_;
}
}
else
{
v___y_5178_ = v___y_5190_;
v___y_5179_ = v___y_5192_;
v___y_5180_ = v___y_5191_;
v___y_5181_ = v_isOpenThink_5194_;
v___y_5182_ = v___x_5176_;
goto v___jp_5177_;
}
}
v___jp_5205_:
{
uint8_t v_isDuplicate_5207_;
v_isDuplicate_5207_ = lean_uint64_dec_le(v_incomingSeq_5133_, v_lastAppliedSeq_5132_);
if (v_isDuplicate_5207_ == 0)
{
uint64_t v___x_5208_; uint64_t v___x_5209_; uint8_t v___x_5210_;
v___x_5208_ = lean_uint64_sub(v_incomingSeq_5133_, v_lastAppliedSeq_5132_);
v___x_5209_ = 1ULL;
v___x_5210_ = lean_uint64_dec_eq(v___x_5208_, v___x_5209_);
v___y_5190_ = v_isDuplicate_5207_;
v___y_5191_ = v___y_5206_;
v___y_5192_ = v___x_5210_;
goto v___jp_5189_;
}
else
{
uint8_t v___x_5211_;
v___x_5211_ = 0;
v___y_5190_ = v_isDuplicate_5207_;
v___y_5191_ = v___y_5206_;
v___y_5192_ = v___x_5211_;
goto v___jp_5189_;
}
}
}
}

LEAN_EXPORT uint64_t orb_outbox_crash_reconcile_step(uint32_t v_durableQueued_5228_, uint32_t v_durableAcked_5229_, uint32_t v_volatileInFlight_5230_, uint64_t v_leaseBootEpoch_5231_, uint64_t v_nodeBootEpoch_5232_, uint32_t v_volatileLeaseOwner_5233_, uint32_t v_reqOwner_5234_){
_start:
{
uint32_t v___y_5236_; uint32_t v___y_5237_; uint32_t v___y_5244_; uint32_t v___y_5245_; uint32_t v___y_5246_; uint32_t v___y_5247_; uint8_t v_validWal_5250_; uint8_t v___y_5252_; uint32_t v___y_5253_; uint32_t v___y_5254_; uint32_t v___y_5255_; uint32_t v___y_5256_; uint8_t v___y_5264_; uint8_t v___y_5265_; uint32_t v___y_5266_; uint32_t v___y_5267_; uint32_t v___y_5268_; uint8_t v___y_5271_; uint8_t v___y_5272_; uint32_t v___y_5273_; uint32_t v___y_5274_; uint32_t v___y_5279_; uint8_t v___y_5280_; uint32_t v___y_5281_; uint8_t v___y_5282_; uint32_t v___y_5284_; uint8_t v___y_5285_; uint32_t v___y_5286_; uint32_t v___y_5287_; uint32_t v___y_5290_; uint8_t v___y_5291_; uint32_t v___y_5292_; uint32_t v___y_5293_; uint32_t v___y_5301_;
v_validWal_5250_ = lean_uint32_dec_le(v_durableAcked_5229_, v_durableQueued_5228_);
if (v_validWal_5250_ == 0)
{
uint32_t v___x_5306_;
v___x_5306_ = 0;
v___y_5301_ = v___x_5306_;
goto v___jp_5300_;
}
else
{
uint32_t v___x_5307_;
v___x_5307_ = lean_uint32_sub(v_durableQueued_5228_, v_durableAcked_5229_);
v___y_5301_ = v___x_5307_;
goto v___jp_5300_;
}
v___jp_5235_:
{
uint64_t v___x_5238_; uint64_t v___x_5239_; uint64_t v___x_5240_; uint64_t v___x_5241_; uint64_t v___x_5242_;
v___x_5238_ = lean_uint32_to_uint64(v___y_5237_);
v___x_5239_ = lean_uint32_to_uint64(v___y_5236_);
v___x_5240_ = 32ULL;
v___x_5241_ = lean_uint64_shift_left(v___x_5239_, v___x_5240_);
v___x_5242_ = lean_uint64_lor(v___x_5238_, v___x_5241_);
return v___x_5242_;
}
v___jp_5243_:
{
uint32_t v___x_5248_; uint32_t v___x_5249_;
v___x_5248_ = lean_uint32_lor(v___y_5247_, v___y_5244_);
v___x_5249_ = lean_uint32_lor(v___x_5248_, v___y_5245_);
v___y_5236_ = v___y_5246_;
v___y_5237_ = v___x_5249_;
goto v___jp_5235_;
}
v___jp_5251_:
{
if (v_validWal_5250_ == 0)
{
v___y_5236_ = v___y_5255_;
v___y_5237_ = v___y_5254_;
goto v___jp_5235_;
}
else
{
if (v___y_5252_ == 0)
{
uint8_t v___x_5257_;
v___x_5257_ = lean_uint32_dec_eq(v___y_5255_, v___y_5254_);
if (v___x_5257_ == 0)
{
uint32_t v___x_5258_;
v___x_5258_ = 3;
v___y_5244_ = v___y_5256_;
v___y_5245_ = v___y_5253_;
v___y_5246_ = v___y_5255_;
v___y_5247_ = v___x_5258_;
goto v___jp_5243_;
}
else
{
uint32_t v___x_5259_;
v___x_5259_ = 2;
v___y_5244_ = v___y_5256_;
v___y_5245_ = v___y_5253_;
v___y_5246_ = v___y_5255_;
v___y_5247_ = v___x_5259_;
goto v___jp_5243_;
}
}
else
{
uint32_t v___x_5260_; uint32_t v___x_5261_; uint32_t v___x_5262_;
v___x_5260_ = 257;
v___x_5261_ = lean_uint32_lor(v___x_5260_, v___y_5256_);
v___x_5262_ = lean_uint32_lor(v___x_5261_, v___y_5253_);
v___y_5236_ = v___y_5255_;
v___y_5237_ = v___x_5262_;
goto v___jp_5235_;
}
}
}
v___jp_5263_:
{
if (v___y_5265_ == 0)
{
v___y_5252_ = v___y_5264_;
v___y_5253_ = v___y_5268_;
v___y_5254_ = v___y_5266_;
v___y_5255_ = v___y_5267_;
v___y_5256_ = v___y_5266_;
goto v___jp_5251_;
}
else
{
uint32_t v___x_5269_;
v___x_5269_ = 512;
v___y_5252_ = v___y_5264_;
v___y_5253_ = v___y_5268_;
v___y_5254_ = v___y_5266_;
v___y_5255_ = v___y_5267_;
v___y_5256_ = v___x_5269_;
goto v___jp_5251_;
}
}
v___jp_5270_:
{
uint32_t v___x_5275_; uint8_t v___x_5276_;
v___x_5275_ = 0;
v___x_5276_ = lean_uint32_dec_eq(v___y_5274_, v___x_5275_);
if (v___x_5276_ == 0)
{
uint32_t v___x_5277_;
v___x_5277_ = 1024;
v___y_5264_ = v___y_5271_;
v___y_5265_ = v___y_5272_;
v___y_5266_ = v___x_5275_;
v___y_5267_ = v___y_5273_;
v___y_5268_ = v___x_5277_;
goto v___jp_5263_;
}
else
{
v___y_5264_ = v___y_5271_;
v___y_5265_ = v___y_5272_;
v___y_5266_ = v___x_5275_;
v___y_5267_ = v___y_5273_;
v___y_5268_ = v___x_5275_;
goto v___jp_5263_;
}
}
v___jp_5278_:
{
if (v___y_5282_ == 0)
{
v___y_5271_ = v___y_5282_;
v___y_5272_ = v___y_5280_;
v___y_5273_ = v___y_5281_;
v___y_5274_ = v___y_5279_;
goto v___jp_5270_;
}
else
{
v___y_5271_ = v___y_5282_;
v___y_5272_ = v___y_5280_;
v___y_5273_ = v___y_5281_;
v___y_5274_ = v_reqOwner_5234_;
goto v___jp_5270_;
}
}
v___jp_5283_:
{
uint8_t v___x_5288_;
v___x_5288_ = lean_uint32_dec_lt(v___y_5286_, v___y_5287_);
v___y_5279_ = v___y_5284_;
v___y_5280_ = v___y_5285_;
v___y_5281_ = v___y_5287_;
v___y_5282_ = v___x_5288_;
goto v___jp_5278_;
}
v___jp_5289_:
{
if (v_validWal_5250_ == 0)
{
v___y_5279_ = v___y_5290_;
v___y_5280_ = v___y_5291_;
v___y_5281_ = v___y_5292_;
v___y_5282_ = v_validWal_5250_;
goto v___jp_5278_;
}
else
{
uint32_t v___x_5294_; uint8_t v___x_5295_;
v___x_5294_ = 0;
v___x_5295_ = lean_uint32_dec_lt(v___x_5294_, v___y_5292_);
if (v___x_5295_ == 0)
{
v___y_5279_ = v___y_5290_;
v___y_5280_ = v___y_5291_;
v___y_5281_ = v___y_5292_;
v___y_5282_ = v___x_5295_;
goto v___jp_5278_;
}
else
{
uint8_t v___x_5296_;
v___x_5296_ = lean_uint32_dec_eq(v_reqOwner_5234_, v___x_5294_);
if (v___x_5296_ == 0)
{
uint8_t v___x_5297_;
v___x_5297_ = lean_uint32_dec_eq(v___y_5290_, v___x_5294_);
if (v___x_5297_ == 0)
{
uint8_t v___x_5298_;
v___x_5298_ = lean_uint32_dec_eq(v___y_5290_, v_reqOwner_5234_);
if (v___x_5298_ == 0)
{
v___y_5279_ = v___y_5290_;
v___y_5280_ = v___y_5291_;
v___y_5281_ = v___y_5292_;
v___y_5282_ = v___x_5298_;
goto v___jp_5278_;
}
else
{
v___y_5284_ = v___y_5290_;
v___y_5285_ = v___y_5291_;
v___y_5286_ = v___y_5293_;
v___y_5287_ = v___y_5292_;
goto v___jp_5283_;
}
}
else
{
v___y_5284_ = v___y_5290_;
v___y_5285_ = v___y_5291_;
v___y_5286_ = v___y_5293_;
v___y_5287_ = v___y_5292_;
goto v___jp_5283_;
}
}
else
{
uint8_t v___x_5299_;
v___x_5299_ = 0;
v___y_5271_ = v___x_5299_;
v___y_5272_ = v___y_5291_;
v___y_5273_ = v___y_5292_;
v___y_5274_ = v___y_5290_;
goto v___jp_5270_;
}
}
}
}
v___jp_5300_:
{
uint8_t v___x_5302_;
v___x_5302_ = lean_uint64_dec_eq(v_leaseBootEpoch_5231_, v_nodeBootEpoch_5232_);
if (v___x_5302_ == 0)
{
uint8_t v___x_5303_; uint32_t v___x_5304_;
v___x_5303_ = 1;
v___x_5304_ = 0;
v___y_5290_ = v___x_5304_;
v___y_5291_ = v___x_5303_;
v___y_5292_ = v___y_5301_;
v___y_5293_ = v___x_5304_;
goto v___jp_5289_;
}
else
{
uint8_t v___x_5305_;
v___x_5305_ = 0;
v___y_5290_ = v_volatileLeaseOwner_5233_;
v___y_5291_ = v___x_5305_;
v___y_5292_ = v___y_5301_;
v___y_5293_ = v_volatileInFlight_5230_;
goto v___jp_5289_;
}
}
}
}

LEAN_EXPORT uint64_t orb_provider_attempt_step(uint32_t v_pinnedAccountId_5324_, uint32_t v_candidateAccountId_5325_, uint32_t v_attemptsUsed_5326_, uint32_t v_retryBudget_5327_, uint8_t v_firstByteCommitted_5328_, uint8_t v_failureKind_5329_, uint64_t v_upstreamNowEpoch_5330_, uint64_t v_cooldownUntilEpoch_5331_, uint64_t v_upstreamDeadline_5332_, uint8_t v_authValid_5333_){
_start:
{
uint32_t v___y_5335_; uint32_t v___y_5336_; uint32_t v___y_5343_; uint32_t v___y_5344_; uint8_t v___y_5348_; uint8_t v___y_5349_; uint8_t v___y_5350_; uint8_t v___y_5351_; uint8_t v___y_5352_; uint32_t v___y_5353_; uint8_t v___y_5354_; uint8_t v___x_5370_; uint8_t v___x_5371_; uint8_t v___y_5373_; uint8_t v___y_5374_; uint8_t v___y_5375_; uint8_t v___y_5376_; uint32_t v___y_5377_; uint8_t v___y_5378_; uint8_t v___y_5380_; uint8_t v___y_5381_; uint8_t v___y_5382_; uint32_t v___y_5383_; uint8_t v___y_5384_; uint8_t v___y_5388_; uint8_t v___y_5389_; uint8_t v___y_5390_; uint32_t v___y_5391_; uint8_t v___y_5392_; uint8_t v___y_5396_; uint8_t v___y_5397_; uint32_t v___y_5398_; uint8_t v___y_5399_; uint32_t v___y_5403_; uint8_t v___y_5404_; uint32_t v___y_5410_;
v___x_5370_ = 1;
v___x_5371_ = lean_uint8_dec_eq(v_firstByteCommitted_5328_, v___x_5370_);
if (v___x_5371_ == 0)
{
uint8_t v___x_5418_; uint8_t v___x_5419_;
v___x_5418_ = 3;
v___x_5419_ = lean_uint8_dec_eq(v_failureKind_5329_, v___x_5418_);
if (v___x_5419_ == 0)
{
uint32_t v___x_5420_;
v___x_5420_ = 0;
v___y_5410_ = v___x_5420_;
goto v___jp_5409_;
}
else
{
goto v___jp_5416_;
}
}
else
{
goto v___jp_5416_;
}
v___jp_5334_:
{
uint64_t v___x_5337_; uint64_t v___x_5338_; uint64_t v___x_5339_; uint64_t v___x_5340_; uint64_t v___x_5341_;
v___x_5337_ = lean_uint32_to_uint64(v___y_5336_);
v___x_5338_ = lean_uint32_to_uint64(v___y_5335_);
v___x_5339_ = 32ULL;
v___x_5340_ = lean_uint64_shift_left(v___x_5338_, v___x_5339_);
v___x_5341_ = lean_uint64_lor(v___x_5337_, v___x_5340_);
return v___x_5341_;
}
v___jp_5342_:
{
uint32_t v___x_5345_; uint32_t v___x_5346_;
v___x_5345_ = 257;
v___x_5346_ = lean_uint32_lor(v___x_5345_, v___y_5343_);
v___y_5335_ = v___y_5344_;
v___y_5336_ = v___x_5346_;
goto v___jp_5334_;
}
v___jp_5347_:
{
if (v___y_5354_ == 0)
{
if (v___y_5350_ == 0)
{
uint32_t v___x_5355_; uint32_t v___x_5356_;
v___x_5355_ = 4;
v___x_5356_ = lean_uint32_lor(v___x_5355_, v___y_5353_);
v___y_5335_ = v_attemptsUsed_5326_;
v___y_5336_ = v___x_5356_;
goto v___jp_5334_;
}
else
{
if (v___y_5349_ == 0)
{
uint32_t v___x_5357_; uint32_t v___x_5358_;
v___x_5357_ = 5;
v___x_5358_ = lean_uint32_lor(v___x_5357_, v___y_5353_);
v___y_5335_ = v_attemptsUsed_5326_;
v___y_5336_ = v___x_5358_;
goto v___jp_5334_;
}
else
{
if (v___y_5348_ == 0)
{
uint32_t v___x_5359_; uint32_t v___x_5360_;
v___x_5359_ = 6;
v___x_5360_ = lean_uint32_lor(v___x_5359_, v___y_5353_);
v___y_5335_ = v_attemptsUsed_5326_;
v___y_5336_ = v___x_5360_;
goto v___jp_5334_;
}
else
{
if (v___y_5351_ == 0)
{
uint32_t v___x_5361_; uint32_t v___x_5362_;
v___x_5361_ = 7;
v___x_5362_ = lean_uint32_lor(v___x_5361_, v___y_5353_);
v___y_5335_ = v_attemptsUsed_5326_;
v___y_5336_ = v___x_5362_;
goto v___jp_5334_;
}
else
{
if (v___y_5352_ == 0)
{
v___y_5343_ = v___y_5353_;
v___y_5344_ = v_attemptsUsed_5326_;
goto v___jp_5342_;
}
else
{
uint32_t v___x_5363_; uint8_t v___x_5364_;
v___x_5363_ = 4294967294;
v___x_5364_ = lean_uint32_dec_le(v_attemptsUsed_5326_, v___x_5363_);
if (v___x_5364_ == 0)
{
uint32_t v___x_5365_;
v___x_5365_ = 4294967295;
v___y_5343_ = v___y_5353_;
v___y_5344_ = v___x_5365_;
goto v___jp_5342_;
}
else
{
uint32_t v___x_5366_; uint32_t v___x_5367_;
v___x_5366_ = 1;
v___x_5367_ = lean_uint32_add(v_attemptsUsed_5326_, v___x_5366_);
v___y_5343_ = v___y_5353_;
v___y_5344_ = v___x_5367_;
goto v___jp_5342_;
}
}
}
}
}
}
}
else
{
uint32_t v___x_5368_; uint32_t v___x_5369_;
v___x_5368_ = 3;
v___x_5369_ = lean_uint32_lor(v___x_5368_, v___y_5353_);
v___y_5335_ = v_attemptsUsed_5326_;
v___y_5336_ = v___x_5369_;
goto v___jp_5334_;
}
}
v___jp_5372_:
{
if (v___x_5371_ == 0)
{
v___y_5348_ = v___y_5373_;
v___y_5349_ = v___y_5374_;
v___y_5350_ = v___y_5375_;
v___y_5351_ = v___y_5378_;
v___y_5352_ = v___y_5376_;
v___y_5353_ = v___y_5377_;
v___y_5354_ = v___x_5371_;
goto v___jp_5347_;
}
else
{
v___y_5348_ = v___y_5373_;
v___y_5349_ = v___y_5374_;
v___y_5350_ = v___y_5375_;
v___y_5351_ = v___y_5378_;
v___y_5352_ = v___y_5376_;
v___y_5353_ = v___y_5377_;
v___y_5354_ = v___y_5376_;
goto v___jp_5347_;
}
}
v___jp_5379_:
{
if (v___y_5384_ == 0)
{
uint8_t v___x_5385_;
v___x_5385_ = lean_uint32_dec_le(v_attemptsUsed_5326_, v_retryBudget_5327_);
v___y_5373_ = v___y_5380_;
v___y_5374_ = v___y_5381_;
v___y_5375_ = v___y_5382_;
v___y_5376_ = v___y_5384_;
v___y_5377_ = v___y_5383_;
v___y_5378_ = v___x_5385_;
goto v___jp_5372_;
}
else
{
uint8_t v___x_5386_;
v___x_5386_ = lean_uint32_dec_lt(v_attemptsUsed_5326_, v_retryBudget_5327_);
v___y_5373_ = v___y_5380_;
v___y_5374_ = v___y_5381_;
v___y_5375_ = v___y_5382_;
v___y_5376_ = v___y_5384_;
v___y_5377_ = v___y_5383_;
v___y_5378_ = v___x_5386_;
goto v___jp_5372_;
}
}
v___jp_5387_:
{
uint8_t v___x_5393_;
v___x_5393_ = lean_uint8_dec_eq(v_failureKind_5329_, v___x_5370_);
if (v___x_5393_ == 0)
{
uint8_t v___x_5394_;
v___x_5394_ = lean_uint8_dec_eq(v_failureKind_5329_, v___y_5388_);
v___y_5380_ = v___y_5392_;
v___y_5381_ = v___y_5389_;
v___y_5382_ = v___y_5390_;
v___y_5383_ = v___y_5391_;
v___y_5384_ = v___x_5394_;
goto v___jp_5379_;
}
else
{
v___y_5380_ = v___y_5392_;
v___y_5381_ = v___y_5389_;
v___y_5382_ = v___y_5390_;
v___y_5383_ = v___y_5391_;
v___y_5384_ = v___x_5393_;
goto v___jp_5379_;
}
}
v___jp_5395_:
{
uint8_t v___x_5400_;
v___x_5400_ = lean_uint64_dec_lt(v_upstreamNowEpoch_5330_, v_upstreamDeadline_5332_);
if (v___x_5400_ == 0)
{
v___y_5388_ = v___y_5396_;
v___y_5389_ = v___y_5399_;
v___y_5390_ = v___y_5397_;
v___y_5391_ = v___y_5398_;
v___y_5392_ = v___x_5400_;
goto v___jp_5387_;
}
else
{
uint8_t v___x_5401_;
v___x_5401_ = lean_uint8_dec_eq(v_authValid_5333_, v___x_5370_);
v___y_5388_ = v___y_5396_;
v___y_5389_ = v___y_5399_;
v___y_5390_ = v___y_5397_;
v___y_5391_ = v___y_5398_;
v___y_5392_ = v___x_5401_;
goto v___jp_5387_;
}
}
v___jp_5402_:
{
uint8_t v___x_5405_; uint8_t v___x_5406_;
v___x_5405_ = 2;
v___x_5406_ = lean_uint8_dec_eq(v_failureKind_5329_, v___x_5405_);
if (v___x_5406_ == 0)
{
uint8_t v___x_5407_;
v___x_5407_ = lean_uint64_dec_le(v_cooldownUntilEpoch_5331_, v_upstreamNowEpoch_5330_);
v___y_5396_ = v___x_5405_;
v___y_5397_ = v___y_5404_;
v___y_5398_ = v___y_5403_;
v___y_5399_ = v___x_5407_;
goto v___jp_5395_;
}
else
{
uint8_t v___x_5408_;
v___x_5408_ = 0;
v___y_5396_ = v___x_5405_;
v___y_5397_ = v___y_5404_;
v___y_5398_ = v___y_5403_;
v___y_5399_ = v___x_5408_;
goto v___jp_5395_;
}
}
v___jp_5409_:
{
uint32_t v___x_5411_; uint8_t v___x_5412_;
v___x_5411_ = 0;
v___x_5412_ = lean_uint32_dec_eq(v_candidateAccountId_5325_, v___x_5411_);
if (v___x_5412_ == 0)
{
uint8_t v___x_5413_;
v___x_5413_ = lean_uint32_dec_eq(v_pinnedAccountId_5324_, v___x_5411_);
if (v___x_5413_ == 0)
{
uint8_t v___x_5414_;
v___x_5414_ = lean_uint32_dec_eq(v_candidateAccountId_5325_, v_pinnedAccountId_5324_);
v___y_5403_ = v___y_5410_;
v___y_5404_ = v___x_5414_;
goto v___jp_5402_;
}
else
{
v___y_5403_ = v___y_5410_;
v___y_5404_ = v___x_5413_;
goto v___jp_5402_;
}
}
else
{
uint8_t v___x_5415_;
v___x_5415_ = 0;
v___y_5403_ = v___y_5410_;
v___y_5404_ = v___x_5415_;
goto v___jp_5402_;
}
}
v___jp_5416_:
{
uint32_t v___x_5417_;
v___x_5417_ = 512;
v___y_5410_ = v___x_5417_;
goto v___jp_5409_;
}
}
}

LEAN_EXPORT uint32_t orb_auth_toctou_execute_step(uint8_t v_principalKind_5443_, uint8_t v_bunkerState_5444_, uint32_t v_observedTargetId_5445_, uint32_t v_execTargetId_5446_, uint64_t v_observedLeaseEpoch_5447_, uint64_t v_liveLeaseEpoch_5448_, uint64_t v_nowTick_5449_, uint64_t v_expiryTick_5450_, uint64_t v_observedDigest_5451_, uint64_t v_execDigest_5452_){
_start:
{
uint8_t v___x_5453_; uint8_t v___x_5454_;
v___x_5453_ = 0;
v___x_5454_ = lean_uint8_dec_eq(v_bunkerState_5444_, v___x_5453_);
if (v___x_5454_ == 0)
{
uint32_t v___x_5455_;
v___x_5455_ = 513;
return v___x_5455_;
}
else
{
uint8_t v___x_5456_; uint8_t v___x_5457_;
v___x_5456_ = 1;
v___x_5457_ = lean_uint8_dec_le(v___x_5456_, v_principalKind_5443_);
if (v___x_5457_ == 0)
{
uint32_t v___x_5458_;
v___x_5458_ = 514;
return v___x_5458_;
}
else
{
uint8_t v___x_5459_; uint8_t v___x_5460_;
v___x_5459_ = 3;
v___x_5460_ = lean_uint8_dec_le(v_principalKind_5443_, v___x_5459_);
if (v___x_5460_ == 0)
{
uint32_t v___x_5461_;
v___x_5461_ = 514;
return v___x_5461_;
}
else
{
uint8_t v___x_5462_;
v___x_5462_ = lean_uint64_dec_lt(v_nowTick_5449_, v_expiryTick_5450_);
if (v___x_5462_ == 0)
{
uint32_t v___x_5463_;
v___x_5463_ = 515;
return v___x_5463_;
}
else
{
uint64_t v___x_5464_; uint8_t v___x_5465_;
v___x_5464_ = 0ULL;
v___x_5465_ = lean_uint64_dec_eq(v_observedLeaseEpoch_5447_, v___x_5464_);
if (v___x_5465_ == 0)
{
uint8_t v___x_5466_;
v___x_5466_ = lean_uint64_dec_eq(v_observedLeaseEpoch_5447_, v_liveLeaseEpoch_5448_);
if (v___x_5466_ == 0)
{
uint32_t v___x_5467_;
v___x_5467_ = 516;
return v___x_5467_;
}
else
{
uint32_t v___x_5468_; uint8_t v___x_5469_;
v___x_5468_ = 0;
v___x_5469_ = lean_uint32_dec_eq(v_observedTargetId_5445_, v___x_5468_);
if (v___x_5469_ == 0)
{
uint8_t v___x_5470_;
v___x_5470_ = lean_uint32_dec_eq(v_observedTargetId_5445_, v_execTargetId_5446_);
if (v___x_5470_ == 0)
{
uint32_t v___x_5471_;
v___x_5471_ = 517;
return v___x_5471_;
}
else
{
uint8_t v___x_5472_;
v___x_5472_ = lean_uint64_dec_eq(v_observedDigest_5451_, v___x_5464_);
if (v___x_5472_ == 0)
{
uint8_t v___x_5473_;
v___x_5473_ = lean_uint64_dec_eq(v_observedDigest_5451_, v_execDigest_5452_);
if (v___x_5473_ == 0)
{
uint32_t v___x_5474_;
v___x_5474_ = 518;
return v___x_5474_;
}
else
{
uint32_t v___x_5475_;
v___x_5475_ = 257;
return v___x_5475_;
}
}
else
{
uint32_t v___x_5476_;
v___x_5476_ = 518;
return v___x_5476_;
}
}
}
else
{
uint32_t v___x_5477_;
v___x_5477_ = 517;
return v___x_5477_;
}
}
}
else
{
uint32_t v___x_5478_;
v___x_5478_ = 516;
return v___x_5478_;
}
}
}
}
}
}
}

LEAN_EXPORT uint64_t orb_resource_ledger_step(uint8_t v_opKind_5501_, uint32_t v_reservedSlots_5502_, uint32_t v_activeSlots_5503_, uint32_t v_maxSlots_5504_, uint64_t v_spentCents_5505_, uint64_t v_costDeltaCents_5506_, uint64_t v_budgetCents_5507_, uint64_t v_nowTick_5508_, uint64_t v_ttlExpiryTick_5509_){
_start:
{
uint32_t v___y_5511_; uint32_t v___y_5512_; uint32_t v___y_5513_; uint32_t v___y_5526_; uint32_t v___y_5527_; uint8_t v___y_5528_; uint32_t v___y_5529_; uint8_t v___y_5530_; uint8_t v_activeFits_5539_; uint8_t v___x_5540_; uint8_t v___y_5542_; uint32_t v___y_5543_; uint8_t v___y_5544_; uint32_t v___y_5545_; uint8_t v___y_5546_; uint8_t v___y_5547_; uint8_t v___y_5548_; uint32_t v___y_5549_; uint8_t v___y_5551_; uint32_t v___y_5552_; uint8_t v___y_5553_; uint8_t v___y_5554_; uint8_t v___y_5555_; uint8_t v___y_5556_; uint32_t v___y_5557_; uint8_t v___y_5561_; uint32_t v___y_5562_; uint8_t v___y_5563_; uint8_t v___y_5564_; uint8_t v___y_5565_; uint8_t v___y_5566_; uint32_t v___y_5567_; uint8_t v___y_5571_; uint32_t v___y_5572_; uint8_t v___y_5573_; uint8_t v___y_5574_; uint8_t v___y_5575_; uint8_t v___y_5576_; uint8_t v___y_5580_; uint32_t v___y_5581_; uint8_t v___y_5582_; uint8_t v___y_5583_; uint8_t v___y_5584_; uint8_t v___y_5585_; uint32_t v___y_5589_; uint8_t v___y_5590_; uint8_t v___y_5591_; uint8_t v___y_5592_; uint8_t v___y_5593_; uint8_t v___y_5594_; uint8_t v___y_5595_; uint32_t v___y_5599_; uint8_t v___y_5600_; uint8_t v___y_5601_; uint8_t v___y_5602_; uint8_t v___y_5603_; uint8_t v___y_5604_; uint8_t v___y_5605_; uint32_t v___y_5609_; uint8_t v___y_5610_; uint8_t v___y_5611_; uint8_t v___y_5612_; uint8_t v___y_5613_; uint8_t v___y_5614_; uint8_t v___y_5615_; uint32_t v___y_5619_; uint8_t v___y_5620_; uint8_t v___y_5621_; uint32_t v___y_5631_; uint8_t v___y_5632_; uint64_t v___y_5633_; uint8_t v___y_5636_; uint32_t v___y_5637_; uint8_t v___y_5638_; uint32_t v___y_5642_;
v_activeFits_5539_ = lean_uint32_dec_le(v_activeSlots_5503_, v_maxSlots_5504_);
v___x_5540_ = 1;
if (v_activeFits_5539_ == 0)
{
uint32_t v___x_5645_;
v___x_5645_ = 0;
v___y_5642_ = v___x_5645_;
goto v___jp_5641_;
}
else
{
uint32_t v___x_5646_;
v___x_5646_ = lean_uint32_sub(v_maxSlots_5504_, v_activeSlots_5503_);
v___y_5642_ = v___x_5646_;
goto v___jp_5641_;
}
v___jp_5510_:
{
uint32_t v___x_5514_; uint32_t v___x_5515_; uint32_t v___x_5516_; uint32_t v___x_5517_; uint32_t v___x_5518_; uint32_t v_hi32_5519_; uint64_t v___x_5520_; uint64_t v___x_5521_; uint64_t v___x_5522_; uint64_t v___x_5523_; uint64_t v___x_5524_;
v___x_5514_ = 65535;
v___x_5515_ = lean_uint32_land(v___y_5512_, v___x_5514_);
v___x_5516_ = lean_uint32_land(v___y_5511_, v___x_5514_);
v___x_5517_ = 16;
v___x_5518_ = lean_uint32_shift_left(v___x_5516_, v___x_5517_);
v_hi32_5519_ = lean_uint32_lor(v___x_5515_, v___x_5518_);
v___x_5520_ = lean_uint32_to_uint64(v___y_5513_);
v___x_5521_ = lean_uint32_to_uint64(v_hi32_5519_);
v___x_5522_ = 32ULL;
v___x_5523_ = lean_uint64_shift_left(v___x_5521_, v___x_5522_);
v___x_5524_ = lean_uint64_lor(v___x_5520_, v___x_5523_);
return v___x_5524_;
}
v___jp_5525_:
{
if (v___y_5528_ == 0)
{
v___y_5511_ = v___y_5526_;
v___y_5512_ = v___y_5529_;
v___y_5513_ = v___y_5527_;
goto v___jp_5510_;
}
else
{
if (v___y_5530_ == 0)
{
uint32_t v___x_5531_;
v___x_5531_ = 2;
v___y_5511_ = v___y_5526_;
v___y_5512_ = v___y_5529_;
v___y_5513_ = v___x_5531_;
goto v___jp_5510_;
}
else
{
uint32_t v___x_5532_; uint32_t v___x_5533_; uint32_t v___x_5534_; uint32_t v___x_5535_; uint32_t v___x_5536_; uint32_t v___x_5537_; uint32_t v___x_5538_;
v___x_5532_ = 257;
v___x_5533_ = lean_uint8_to_uint32(v_opKind_5501_);
v___x_5534_ = 255;
v___x_5535_ = lean_uint32_land(v___x_5533_, v___x_5534_);
v___x_5536_ = 1;
v___x_5537_ = lean_uint32_shift_left(v___x_5535_, v___x_5536_);
v___x_5538_ = lean_uint32_lor(v___x_5532_, v___x_5537_);
v___y_5511_ = v___y_5526_;
v___y_5512_ = v___y_5529_;
v___y_5513_ = v___x_5538_;
goto v___jp_5510_;
}
}
}
v___jp_5541_:
{
if (v___y_5548_ == 0)
{
if (v___y_5547_ == 0)
{
if (v___y_5542_ == 0)
{
v___y_5526_ = v___y_5549_;
v___y_5527_ = v___y_5543_;
v___y_5528_ = v___y_5544_;
v___y_5529_ = v___y_5545_;
v___y_5530_ = v___y_5546_;
goto v___jp_5525_;
}
else
{
v___y_5526_ = v___y_5549_;
v___y_5527_ = v___y_5543_;
v___y_5528_ = v___y_5544_;
v___y_5529_ = v___y_5545_;
v___y_5530_ = v___x_5540_;
goto v___jp_5525_;
}
}
else
{
v___y_5526_ = v___y_5549_;
v___y_5527_ = v___y_5543_;
v___y_5528_ = v___y_5544_;
v___y_5529_ = v___y_5545_;
v___y_5530_ = v___x_5540_;
goto v___jp_5525_;
}
}
else
{
v___y_5526_ = v___y_5549_;
v___y_5527_ = v___y_5543_;
v___y_5528_ = v___y_5544_;
v___y_5529_ = v___y_5545_;
v___y_5530_ = v___x_5540_;
goto v___jp_5525_;
}
}
v___jp_5550_:
{
if (v___y_5551_ == 0)
{
v___y_5542_ = v___y_5551_;
v___y_5543_ = v___y_5552_;
v___y_5544_ = v___y_5553_;
v___y_5545_ = v___y_5557_;
v___y_5546_ = v___y_5554_;
v___y_5547_ = v___y_5555_;
v___y_5548_ = v___y_5556_;
v___y_5549_ = v_activeSlots_5503_;
goto v___jp_5541_;
}
else
{
uint32_t v___x_5558_; uint32_t v___x_5559_;
v___x_5558_ = 1;
v___x_5559_ = lean_uint32_sub(v_activeSlots_5503_, v___x_5558_);
v___y_5542_ = v___y_5551_;
v___y_5543_ = v___y_5552_;
v___y_5544_ = v___y_5553_;
v___y_5545_ = v___y_5557_;
v___y_5546_ = v___y_5554_;
v___y_5547_ = v___y_5555_;
v___y_5548_ = v___y_5556_;
v___y_5549_ = v___x_5559_;
goto v___jp_5541_;
}
}
v___jp_5560_:
{
if (v___y_5565_ == 0)
{
v___y_5551_ = v___y_5561_;
v___y_5552_ = v___y_5562_;
v___y_5553_ = v___y_5563_;
v___y_5554_ = v___y_5564_;
v___y_5555_ = v___y_5565_;
v___y_5556_ = v___y_5566_;
v___y_5557_ = v___y_5567_;
goto v___jp_5550_;
}
else
{
uint32_t v___x_5568_; uint32_t v___x_5569_;
v___x_5568_ = 1;
v___x_5569_ = lean_uint32_add(v_activeSlots_5503_, v___x_5568_);
v___y_5542_ = v___y_5561_;
v___y_5543_ = v___y_5562_;
v___y_5544_ = v___y_5563_;
v___y_5545_ = v___y_5567_;
v___y_5546_ = v___y_5564_;
v___y_5547_ = v___y_5565_;
v___y_5548_ = v___y_5566_;
v___y_5549_ = v___x_5569_;
goto v___jp_5541_;
}
}
v___jp_5570_:
{
uint32_t v___x_5577_; uint32_t v___x_5578_;
v___x_5577_ = 1;
v___x_5578_ = lean_uint32_sub(v_reservedSlots_5502_, v___x_5577_);
v___y_5561_ = v___y_5571_;
v___y_5562_ = v___y_5572_;
v___y_5563_ = v___y_5573_;
v___y_5564_ = v___y_5574_;
v___y_5565_ = v___y_5575_;
v___y_5566_ = v___y_5576_;
v___y_5567_ = v___x_5578_;
goto v___jp_5560_;
}
v___jp_5579_:
{
if (v___y_5584_ == 0)
{
if (v___y_5583_ == 0)
{
if (v___y_5585_ == 0)
{
v___y_5551_ = v___y_5580_;
v___y_5552_ = v___y_5581_;
v___y_5553_ = v___y_5582_;
v___y_5554_ = v___y_5585_;
v___y_5555_ = v___y_5583_;
v___y_5556_ = v___y_5584_;
v___y_5557_ = v_reservedSlots_5502_;
goto v___jp_5550_;
}
else
{
v___y_5571_ = v___y_5580_;
v___y_5572_ = v___y_5581_;
v___y_5573_ = v___y_5582_;
v___y_5574_ = v___y_5585_;
v___y_5575_ = v___y_5583_;
v___y_5576_ = v___y_5584_;
goto v___jp_5570_;
}
}
else
{
v___y_5571_ = v___y_5580_;
v___y_5572_ = v___y_5581_;
v___y_5573_ = v___y_5582_;
v___y_5574_ = v___y_5585_;
v___y_5575_ = v___y_5583_;
v___y_5576_ = v___y_5584_;
goto v___jp_5570_;
}
}
else
{
uint32_t v___x_5586_; uint32_t v___x_5587_;
v___x_5586_ = 1;
v___x_5587_ = lean_uint32_add(v_reservedSlots_5502_, v___x_5586_);
v___y_5561_ = v___y_5580_;
v___y_5562_ = v___y_5581_;
v___y_5563_ = v___y_5582_;
v___y_5564_ = v___y_5585_;
v___y_5565_ = v___y_5583_;
v___y_5566_ = v___y_5584_;
v___y_5567_ = v___x_5587_;
goto v___jp_5560_;
}
}
v___jp_5588_:
{
uint8_t v___x_5596_; uint8_t v___x_5597_;
v___x_5596_ = 3;
v___x_5597_ = lean_uint8_dec_eq(v_opKind_5501_, v___x_5596_);
if (v___x_5597_ == 0)
{
v___y_5580_ = v___y_5595_;
v___y_5581_ = v___y_5589_;
v___y_5582_ = v___y_5590_;
v___y_5583_ = v___y_5592_;
v___y_5584_ = v___y_5593_;
v___y_5585_ = v___x_5597_;
goto v___jp_5579_;
}
else
{
if (v___y_5590_ == 0)
{
v___y_5580_ = v___y_5595_;
v___y_5581_ = v___y_5589_;
v___y_5582_ = v___y_5590_;
v___y_5583_ = v___y_5592_;
v___y_5584_ = v___y_5593_;
v___y_5585_ = v___y_5590_;
goto v___jp_5579_;
}
else
{
if (v___y_5594_ == 0)
{
v___y_5580_ = v___y_5595_;
v___y_5581_ = v___y_5589_;
v___y_5582_ = v___y_5590_;
v___y_5583_ = v___y_5592_;
v___y_5584_ = v___y_5593_;
v___y_5585_ = v___y_5594_;
goto v___jp_5579_;
}
else
{
v___y_5580_ = v___y_5595_;
v___y_5581_ = v___y_5589_;
v___y_5582_ = v___y_5590_;
v___y_5583_ = v___y_5592_;
v___y_5584_ = v___y_5593_;
v___y_5585_ = v___y_5591_;
goto v___jp_5579_;
}
}
}
}
v___jp_5598_:
{
uint8_t v___x_5606_; uint8_t v___x_5607_;
v___x_5606_ = 2;
v___x_5607_ = lean_uint8_dec_eq(v_opKind_5501_, v___x_5606_);
if (v___x_5607_ == 0)
{
v___y_5589_ = v___y_5599_;
v___y_5590_ = v___y_5600_;
v___y_5591_ = v___y_5602_;
v___y_5592_ = v___y_5605_;
v___y_5593_ = v___y_5603_;
v___y_5594_ = v___y_5604_;
v___y_5595_ = v___x_5607_;
goto v___jp_5588_;
}
else
{
if (v___y_5600_ == 0)
{
v___y_5589_ = v___y_5599_;
v___y_5590_ = v___y_5600_;
v___y_5591_ = v___y_5602_;
v___y_5592_ = v___y_5605_;
v___y_5593_ = v___y_5603_;
v___y_5594_ = v___y_5604_;
v___y_5595_ = v___y_5600_;
goto v___jp_5588_;
}
else
{
v___y_5589_ = v___y_5599_;
v___y_5590_ = v___y_5600_;
v___y_5591_ = v___y_5602_;
v___y_5592_ = v___y_5605_;
v___y_5593_ = v___y_5603_;
v___y_5594_ = v___y_5604_;
v___y_5595_ = v___y_5601_;
goto v___jp_5588_;
}
}
}
v___jp_5608_:
{
uint8_t v___x_5616_; uint8_t v___x_5617_;
v___x_5616_ = 1;
v___x_5617_ = lean_uint8_dec_eq(v_opKind_5501_, v___x_5616_);
if (v___x_5617_ == 0)
{
v___y_5599_ = v___y_5609_;
v___y_5600_ = v___y_5610_;
v___y_5601_ = v___y_5611_;
v___y_5602_ = v___y_5612_;
v___y_5603_ = v___y_5615_;
v___y_5604_ = v___y_5614_;
v___y_5605_ = v___x_5617_;
goto v___jp_5598_;
}
else
{
if (v___y_5610_ == 0)
{
v___y_5599_ = v___y_5609_;
v___y_5600_ = v___y_5610_;
v___y_5601_ = v___y_5611_;
v___y_5602_ = v___y_5612_;
v___y_5603_ = v___y_5615_;
v___y_5604_ = v___y_5614_;
v___y_5605_ = v___y_5610_;
goto v___jp_5598_;
}
else
{
if (v___y_5614_ == 0)
{
v___y_5599_ = v___y_5609_;
v___y_5600_ = v___y_5610_;
v___y_5601_ = v___y_5611_;
v___y_5602_ = v___y_5612_;
v___y_5603_ = v___y_5615_;
v___y_5604_ = v___y_5614_;
v___y_5605_ = v___y_5614_;
goto v___jp_5598_;
}
else
{
v___y_5599_ = v___y_5609_;
v___y_5600_ = v___y_5610_;
v___y_5601_ = v___y_5611_;
v___y_5602_ = v___y_5612_;
v___y_5603_ = v___y_5615_;
v___y_5604_ = v___y_5614_;
v___y_5605_ = v___y_5613_;
goto v___jp_5598_;
}
}
}
}
v___jp_5618_:
{
uint8_t v_hasFreeSlot_5622_; uint32_t v___x_5623_; uint8_t v_hasReserved_5624_; uint8_t v_hasActive_5625_; uint8_t v_ttlLive_5626_; uint8_t v_ttlExpired_5627_; uint8_t v___x_5628_; uint8_t v___x_5629_;
v_hasFreeSlot_5622_ = lean_uint32_dec_lt(v_reservedSlots_5502_, v___y_5619_);
v___x_5623_ = 0;
v_hasReserved_5624_ = lean_uint32_dec_lt(v___x_5623_, v_reservedSlots_5502_);
v_hasActive_5625_ = lean_uint32_dec_lt(v___x_5623_, v_activeSlots_5503_);
v_ttlLive_5626_ = lean_uint64_dec_lt(v_nowTick_5508_, v_ttlExpiryTick_5509_);
v_ttlExpired_5627_ = lean_uint64_dec_le(v_ttlExpiryTick_5509_, v_nowTick_5508_);
v___x_5628_ = 0;
v___x_5629_ = lean_uint8_dec_eq(v_opKind_5501_, v___x_5628_);
if (v___x_5629_ == 0)
{
v___y_5609_ = v___x_5623_;
v___y_5610_ = v___y_5620_;
v___y_5611_ = v_hasActive_5625_;
v___y_5612_ = v_ttlExpired_5627_;
v___y_5613_ = v_ttlLive_5626_;
v___y_5614_ = v_hasReserved_5624_;
v___y_5615_ = v___x_5629_;
goto v___jp_5608_;
}
else
{
if (v___y_5621_ == 0)
{
v___y_5609_ = v___x_5623_;
v___y_5610_ = v___y_5620_;
v___y_5611_ = v_hasActive_5625_;
v___y_5612_ = v_ttlExpired_5627_;
v___y_5613_ = v_ttlLive_5626_;
v___y_5614_ = v_hasReserved_5624_;
v___y_5615_ = v___y_5621_;
goto v___jp_5608_;
}
else
{
if (v_hasFreeSlot_5622_ == 0)
{
v___y_5609_ = v___x_5623_;
v___y_5610_ = v___y_5620_;
v___y_5611_ = v_hasActive_5625_;
v___y_5612_ = v_ttlExpired_5627_;
v___y_5613_ = v_ttlLive_5626_;
v___y_5614_ = v_hasReserved_5624_;
v___y_5615_ = v_hasFreeSlot_5622_;
goto v___jp_5608_;
}
else
{
v___y_5609_ = v___x_5623_;
v___y_5610_ = v___y_5620_;
v___y_5611_ = v_hasActive_5625_;
v___y_5612_ = v_ttlExpired_5627_;
v___y_5613_ = v_ttlLive_5626_;
v___y_5614_ = v_hasReserved_5624_;
v___y_5615_ = v_ttlLive_5626_;
goto v___jp_5608_;
}
}
}
}
v___jp_5630_:
{
if (v___y_5632_ == 0)
{
v___y_5619_ = v___y_5631_;
v___y_5620_ = v___y_5632_;
v___y_5621_ = v___y_5632_;
goto v___jp_5618_;
}
else
{
uint8_t v___x_5634_;
v___x_5634_ = lean_uint64_dec_le(v_costDeltaCents_5506_, v___y_5633_);
v___y_5619_ = v___y_5631_;
v___y_5620_ = v___y_5632_;
v___y_5621_ = v___x_5634_;
goto v___jp_5618_;
}
}
v___jp_5635_:
{
if (v___y_5636_ == 0)
{
uint64_t v___x_5639_;
v___x_5639_ = 0ULL;
v___y_5631_ = v___y_5637_;
v___y_5632_ = v___y_5638_;
v___y_5633_ = v___x_5639_;
goto v___jp_5630_;
}
else
{
uint64_t v___x_5640_;
v___x_5640_ = lean_uint64_sub(v_budgetCents_5507_, v_spentCents_5505_);
v___y_5631_ = v___y_5637_;
v___y_5632_ = v___y_5638_;
v___y_5633_ = v___x_5640_;
goto v___jp_5630_;
}
}
v___jp_5641_:
{
uint8_t v_budgetValid_5643_;
v_budgetValid_5643_ = lean_uint64_dec_le(v_spentCents_5505_, v_budgetCents_5507_);
if (v_activeFits_5539_ == 0)
{
v___y_5636_ = v_budgetValid_5643_;
v___y_5637_ = v___y_5642_;
v___y_5638_ = v_activeFits_5539_;
goto v___jp_5635_;
}
else
{
uint8_t v_reservedFits_5644_;
v_reservedFits_5644_ = lean_uint32_dec_le(v_reservedSlots_5502_, v___y_5642_);
if (v_reservedFits_5644_ == 0)
{
v___y_5636_ = v_budgetValid_5643_;
v___y_5637_ = v___y_5642_;
v___y_5638_ = v_reservedFits_5644_;
goto v___jp_5635_;
}
else
{
v___y_5636_ = v_budgetValid_5643_;
v___y_5637_ = v___y_5642_;
v___y_5638_ = v_budgetValid_5643_;
goto v___jp_5635_;
}
}
}
}
}

LEAN_EXPORT uint64_t orb_stream_bounded_commit_step(uint32_t v_prevLen_5667_, uint32_t v_prevCommit_5668_, uint32_t v_prevCheckpoint_5669_, uint32_t v_newLen_5670_, uint32_t v_rawCommit_5671_, uint32_t v_maxOpenTailBytes_5672_){
_start:
{
uint32_t v___y_5674_; uint32_t v___y_5675_; uint32_t v___x_5681_; uint8_t v_validCap_5682_; uint8_t v___y_5684_; uint32_t v___y_5685_; uint32_t v___y_5686_; uint8_t v___y_5690_; uint32_t v___y_5691_; uint32_t v___y_5692_; uint8_t v___y_5696_; uint32_t v___y_5697_; uint32_t v___y_5698_; uint32_t v___y_5699_; uint8_t v___y_5702_; uint32_t v___y_5703_; uint32_t v___y_5704_; uint8_t v___y_5708_; uint32_t v___y_5709_; uint8_t v___y_5712_; uint32_t v___y_5713_; uint8_t v___y_5716_; uint8_t v___x_5718_;
v___x_5681_ = 0;
v_validCap_5682_ = lean_uint32_dec_lt(v___x_5681_, v_maxOpenTailBytes_5672_);
v___x_5718_ = lean_uint32_dec_le(v_prevCommit_5668_, v_prevCheckpoint_5669_);
if (v___x_5718_ == 0)
{
v___y_5716_ = v___x_5718_;
goto v___jp_5715_;
}
else
{
uint8_t v___x_5719_;
v___x_5719_ = lean_uint32_dec_le(v_prevCheckpoint_5669_, v_prevLen_5667_);
if (v___x_5719_ == 0)
{
v___y_5716_ = v___x_5719_;
goto v___jp_5715_;
}
else
{
uint8_t v___x_5720_;
v___x_5720_ = lean_uint32_dec_le(v_prevLen_5667_, v_newLen_5670_);
v___y_5716_ = v___x_5720_;
goto v___jp_5715_;
}
}
v___jp_5673_:
{
uint64_t v___x_5676_; uint64_t v___x_5677_; uint64_t v___x_5678_; uint64_t v___x_5679_; uint64_t v___x_5680_;
v___x_5676_ = lean_uint32_to_uint64(v___y_5674_);
v___x_5677_ = lean_uint32_to_uint64(v___y_5675_);
v___x_5678_ = 32ULL;
v___x_5679_ = lean_uint64_shift_left(v___x_5677_, v___x_5678_);
v___x_5680_ = lean_uint64_lor(v___x_5676_, v___x_5679_);
return v___x_5680_;
}
v___jp_5683_:
{
if (v_validCap_5682_ == 0)
{
v___y_5674_ = v___x_5681_;
v___y_5675_ = v_prevCheckpoint_5669_;
goto v___jp_5673_;
}
else
{
if (v___y_5684_ == 0)
{
v___y_5674_ = v___x_5681_;
v___y_5675_ = v_prevCheckpoint_5669_;
goto v___jp_5673_;
}
else
{
uint32_t v___x_5687_; uint32_t v___x_5688_;
v___x_5687_ = 257;
v___x_5688_ = lean_uint32_lor(v___x_5687_, v___y_5686_);
v___y_5674_ = v___x_5688_;
v___y_5675_ = v___y_5685_;
goto v___jp_5673_;
}
}
}
v___jp_5689_:
{
uint8_t v___x_5693_;
v___x_5693_ = lean_uint32_dec_lt(v___y_5691_, v___y_5692_);
if (v___x_5693_ == 0)
{
v___y_5684_ = v___y_5690_;
v___y_5685_ = v___y_5692_;
v___y_5686_ = v___x_5681_;
goto v___jp_5683_;
}
else
{
uint32_t v___x_5694_;
v___x_5694_ = 512;
v___y_5684_ = v___y_5690_;
v___y_5685_ = v___y_5692_;
v___y_5686_ = v___x_5694_;
goto v___jp_5683_;
}
}
v___jp_5695_:
{
uint8_t v___x_5700_;
v___x_5700_ = lean_uint32_dec_le(v___y_5697_, v___y_5699_);
if (v___x_5700_ == 0)
{
v___y_5690_ = v___y_5696_;
v___y_5691_ = v___y_5698_;
v___y_5692_ = v___y_5697_;
goto v___jp_5689_;
}
else
{
v___y_5690_ = v___y_5696_;
v___y_5691_ = v___y_5698_;
v___y_5692_ = v___y_5699_;
goto v___jp_5689_;
}
}
v___jp_5701_:
{
uint8_t v___x_5705_;
v___x_5705_ = lean_uint32_dec_le(v_maxOpenTailBytes_5672_, v_newLen_5670_);
if (v___x_5705_ == 0)
{
v___y_5696_ = v___y_5702_;
v___y_5697_ = v___y_5704_;
v___y_5698_ = v___y_5703_;
v___y_5699_ = v___x_5681_;
goto v___jp_5695_;
}
else
{
uint32_t v___x_5706_;
v___x_5706_ = lean_uint32_sub(v_newLen_5670_, v_maxOpenTailBytes_5672_);
v___y_5696_ = v___y_5702_;
v___y_5697_ = v___y_5704_;
v___y_5698_ = v___y_5703_;
v___y_5699_ = v___x_5706_;
goto v___jp_5695_;
}
}
v___jp_5707_:
{
uint8_t v___x_5710_;
v___x_5710_ = lean_uint32_dec_le(v_prevCheckpoint_5669_, v___y_5709_);
if (v___x_5710_ == 0)
{
v___y_5702_ = v___y_5708_;
v___y_5703_ = v___y_5709_;
v___y_5704_ = v_prevCheckpoint_5669_;
goto v___jp_5701_;
}
else
{
v___y_5702_ = v___y_5708_;
v___y_5703_ = v___y_5709_;
v___y_5704_ = v___y_5709_;
goto v___jp_5701_;
}
}
v___jp_5711_:
{
uint8_t v___x_5714_;
v___x_5714_ = lean_uint32_dec_le(v_prevCommit_5668_, v___y_5713_);
if (v___x_5714_ == 0)
{
v___y_5708_ = v___y_5712_;
v___y_5709_ = v_prevCommit_5668_;
goto v___jp_5707_;
}
else
{
v___y_5708_ = v___y_5712_;
v___y_5709_ = v___y_5713_;
goto v___jp_5707_;
}
}
v___jp_5715_:
{
uint8_t v___x_5717_;
v___x_5717_ = lean_uint32_dec_le(v_rawCommit_5671_, v_newLen_5670_);
if (v___x_5717_ == 0)
{
v___y_5712_ = v___y_5716_;
v___y_5713_ = v_newLen_5670_;
goto v___jp_5711_;
}
else
{
v___y_5712_ = v___y_5716_;
v___y_5713_ = v_rawCommit_5671_;
goto v___jp_5711_;
}
}
}
}

LEAN_EXPORT uint32_t orb_vm_cap_admit(uint8_t v_hasPoolOverride_5735_, uint8_t v_hasPoolMax_5736_, uint8_t v_hasProviderMax_5737_, uint8_t v_hasGlobalMax_5738_, uint8_t v_ancestorBlocked_5739_, uint32_t v_sharedActive_5740_, uint32_t v_globalMax_5741_, uint32_t v_poolActive_5742_, uint32_t v_poolMax_5743_, uint32_t v_providerActive_5744_, uint32_t v_providerMax_5745_){
_start:
{
uint8_t v___x_5758_; uint8_t v___x_5759_;
v___x_5758_ = 1;
v___x_5759_ = lean_uint8_dec_eq(v_ancestorBlocked_5739_, v___x_5758_);
if (v___x_5759_ == 0)
{
uint8_t v___x_5760_;
v___x_5760_ = lean_uint8_dec_eq(v_hasPoolOverride_5735_, v___x_5758_);
if (v___x_5760_ == 0)
{
uint8_t v___x_5761_; uint8_t v___x_5762_;
v___x_5761_ = 0;
v___x_5762_ = lean_uint8_dec_eq(v_hasGlobalMax_5738_, v___x_5761_);
if (v___x_5762_ == 0)
{
uint8_t v___x_5763_;
v___x_5763_ = lean_uint32_dec_lt(v_sharedActive_5740_, v_globalMax_5741_);
if (v___x_5763_ == 0)
{
uint32_t v___x_5764_;
v___x_5764_ = 512;
return v___x_5764_;
}
else
{
uint32_t v___x_5765_;
v___x_5765_ = 257;
return v___x_5765_;
}
}
else
{
uint32_t v___x_5766_;
v___x_5766_ = 257;
return v___x_5766_;
}
}
else
{
uint8_t v___x_5767_;
v___x_5767_ = lean_uint8_dec_eq(v_hasPoolMax_5736_, v___x_5758_);
if (v___x_5767_ == 0)
{
uint8_t v___x_5768_;
v___x_5768_ = lean_uint8_dec_eq(v_hasProviderMax_5737_, v___x_5758_);
if (v___x_5768_ == 0)
{
uint32_t v___x_5769_;
v___x_5769_ = 512;
return v___x_5769_;
}
else
{
goto v___jp_5753_;
}
}
else
{
goto v___jp_5753_;
}
}
}
else
{
uint32_t v___x_5770_;
v___x_5770_ = 512;
return v___x_5770_;
}
v___jp_5746_:
{
uint8_t v___x_5747_; uint8_t v___x_5748_;
v___x_5747_ = 0;
v___x_5748_ = lean_uint8_dec_eq(v_hasPoolMax_5736_, v___x_5747_);
if (v___x_5748_ == 0)
{
uint8_t v___x_5749_;
v___x_5749_ = lean_uint32_dec_lt(v_poolActive_5742_, v_poolMax_5743_);
if (v___x_5749_ == 0)
{
uint32_t v___x_5750_;
v___x_5750_ = 512;
return v___x_5750_;
}
else
{
uint32_t v___x_5751_;
v___x_5751_ = 257;
return v___x_5751_;
}
}
else
{
uint32_t v___x_5752_;
v___x_5752_ = 257;
return v___x_5752_;
}
}
v___jp_5753_:
{
uint8_t v___x_5754_; uint8_t v___x_5755_;
v___x_5754_ = 0;
v___x_5755_ = lean_uint8_dec_eq(v_hasProviderMax_5737_, v___x_5754_);
if (v___x_5755_ == 0)
{
uint8_t v___x_5756_;
v___x_5756_ = lean_uint32_dec_lt(v_providerActive_5744_, v_providerMax_5745_);
if (v___x_5756_ == 0)
{
uint32_t v___x_5757_;
v___x_5757_ = 512;
return v___x_5757_;
}
else
{
goto v___jp_5746_;
}
}
else
{
goto v___jp_5746_;
}
}
}
}

LEAN_EXPORT uint32_t orb_slot_bypass_step(uint8_t v_isOperatorForce_5795_, uint8_t v_isAgentCaller_5796_, uint8_t v_isWaitingSlot_5797_, uint32_t v_regularRunning_5798_, uint32_t v_regularMax_5799_, uint32_t v_forcedRunning_5800_, uint32_t v_forcedMax_5801_){
_start:
{
uint8_t v___x_5802_; uint8_t v___x_5803_;
v___x_5802_ = 1;
v___x_5803_ = lean_uint8_dec_eq(v_isOperatorForce_5795_, v___x_5802_);
if (v___x_5803_ == 0)
{
uint8_t v___x_5804_;
v___x_5804_ = lean_uint32_dec_lt(v_regularRunning_5798_, v_regularMax_5799_);
if (v___x_5804_ == 0)
{
uint32_t v___x_5805_;
v___x_5805_ = 512;
return v___x_5805_;
}
else
{
uint32_t v___x_5806_;
v___x_5806_ = 257;
return v___x_5806_;
}
}
else
{
uint8_t v___x_5807_;
v___x_5807_ = lean_uint8_dec_eq(v_isAgentCaller_5796_, v___x_5802_);
if (v___x_5807_ == 0)
{
uint8_t v___x_5808_;
v___x_5808_ = lean_uint8_dec_eq(v_isWaitingSlot_5797_, v___x_5802_);
if (v___x_5808_ == 0)
{
uint32_t v___x_5809_;
v___x_5809_ = 514;
return v___x_5809_;
}
else
{
uint8_t v___x_5810_;
v___x_5810_ = lean_uint32_dec_lt(v_forcedRunning_5800_, v_forcedMax_5801_);
if (v___x_5810_ == 0)
{
uint32_t v___x_5811_;
v___x_5811_ = 512;
return v___x_5811_;
}
else
{
uint32_t v___x_5812_;
v___x_5812_ = 258;
return v___x_5812_;
}
}
}
else
{
uint32_t v___x_5813_;
v___x_5813_ = 513;
return v___x_5813_;
}
}
}
}

LEAN_EXPORT uint64_t orb_node_resize_step(uint8_t v_isOperatorCaller_5830_, uint8_t v_isAgentCaller_5831_, uint8_t v_isStaticNode_5832_, uint32_t v_curCap_5833_, uint32_t v_curDebt_5834_, uint32_t v_idlePermits_5835_, uint32_t v_targetCap_5836_, uint32_t v_maxCap_5837_){
_start:
{
uint32_t v___y_5839_; uint32_t v___y_5840_; uint32_t v___y_5847_; uint32_t v___y_5848_; uint32_t v___y_5849_; uint32_t v___y_5856_; uint8_t v___y_5866_; uint8_t v___y_5867_; uint8_t v___y_5868_; uint8_t v___x_5877_; uint8_t v___y_5879_; uint8_t v___x_5884_;
v___x_5877_ = 1;
v___x_5884_ = lean_uint8_dec_eq(v_isOperatorCaller_5830_, v___x_5877_);
if (v___x_5884_ == 0)
{
v___y_5879_ = v___x_5884_;
goto v___jp_5878_;
}
else
{
uint8_t v___x_5885_;
v___x_5885_ = lean_uint8_dec_eq(v_isAgentCaller_5831_, v___x_5877_);
if (v___x_5885_ == 0)
{
v___y_5879_ = v___x_5884_;
goto v___jp_5878_;
}
else
{
uint8_t v___x_5886_;
v___x_5886_ = 0;
v___y_5879_ = v___x_5886_;
goto v___jp_5878_;
}
}
v___jp_5838_:
{
uint64_t v___x_5841_; uint64_t v___x_5842_; uint64_t v___x_5843_; uint64_t v___x_5844_; uint64_t v___x_5845_;
v___x_5841_ = lean_uint32_to_uint64(v___y_5839_);
v___x_5842_ = lean_uint32_to_uint64(v___y_5840_);
v___x_5843_ = 32ULL;
v___x_5844_ = lean_uint64_shift_left(v___x_5842_, v___x_5843_);
v___x_5845_ = lean_uint64_lor(v___x_5841_, v___x_5844_);
return v___x_5845_;
}
v___jp_5846_:
{
uint32_t v___x_5850_; uint32_t v___x_5851_; uint32_t v___x_5852_; uint8_t v___x_5853_;
v___x_5850_ = lean_uint32_sub(v___y_5848_, v___y_5849_);
v___x_5851_ = 4294967295;
v___x_5852_ = lean_uint32_sub(v___x_5851_, v___x_5850_);
v___x_5853_ = lean_uint32_dec_le(v_curDebt_5834_, v___x_5852_);
if (v___x_5853_ == 0)
{
v___y_5839_ = v___y_5847_;
v___y_5840_ = v___x_5851_;
goto v___jp_5838_;
}
else
{
uint32_t v___x_5854_;
v___x_5854_ = lean_uint32_add(v_curDebt_5834_, v___x_5850_);
v___y_5839_ = v___y_5847_;
v___y_5840_ = v___x_5854_;
goto v___jp_5838_;
}
}
v___jp_5855_:
{
uint8_t v___x_5857_;
v___x_5857_ = lean_uint32_dec_lt(v_curCap_5833_, v_targetCap_5836_);
if (v___x_5857_ == 0)
{
uint8_t v___x_5858_;
v___x_5858_ = lean_uint32_dec_lt(v_targetCap_5836_, v_curCap_5833_);
if (v___x_5858_ == 0)
{
v___y_5839_ = v___y_5856_;
v___y_5840_ = v_curDebt_5834_;
goto v___jp_5838_;
}
else
{
uint32_t v_shrink_5859_; uint8_t v___x_5860_;
v_shrink_5859_ = lean_uint32_sub(v_curCap_5833_, v_targetCap_5836_);
v___x_5860_ = lean_uint32_dec_le(v_shrink_5859_, v_idlePermits_5835_);
if (v___x_5860_ == 0)
{
v___y_5847_ = v___y_5856_;
v___y_5848_ = v_shrink_5859_;
v___y_5849_ = v_idlePermits_5835_;
goto v___jp_5846_;
}
else
{
v___y_5847_ = v___y_5856_;
v___y_5848_ = v_shrink_5859_;
v___y_5849_ = v_shrink_5859_;
goto v___jp_5846_;
}
}
}
else
{
uint32_t v_grow_5861_; uint8_t v___x_5862_;
v_grow_5861_ = lean_uint32_sub(v_targetCap_5836_, v_curCap_5833_);
v___x_5862_ = lean_uint32_dec_le(v_curDebt_5834_, v_grow_5861_);
if (v___x_5862_ == 0)
{
uint32_t v___x_5863_;
v___x_5863_ = lean_uint32_sub(v_curDebt_5834_, v_grow_5861_);
v___y_5839_ = v___y_5856_;
v___y_5840_ = v___x_5863_;
goto v___jp_5838_;
}
else
{
uint32_t v___x_5864_;
v___x_5864_ = 0;
v___y_5839_ = v___y_5856_;
v___y_5840_ = v___x_5864_;
goto v___jp_5838_;
}
}
}
v___jp_5865_:
{
if (v___y_5867_ == 0)
{
uint32_t v___x_5869_;
v___x_5869_ = 513;
v___y_5839_ = v___x_5869_;
v___y_5840_ = v_curDebt_5834_;
goto v___jp_5838_;
}
else
{
if (v___y_5866_ == 0)
{
uint32_t v___x_5870_;
v___x_5870_ = 514;
v___y_5839_ = v___x_5870_;
v___y_5840_ = v_curDebt_5834_;
goto v___jp_5838_;
}
else
{
if (v___y_5868_ == 0)
{
uint32_t v___x_5871_;
v___x_5871_ = 515;
v___y_5839_ = v___x_5871_;
v___y_5840_ = v_curDebt_5834_;
goto v___jp_5838_;
}
else
{
uint8_t v___x_5872_;
v___x_5872_ = lean_uint32_dec_lt(v_curCap_5833_, v_targetCap_5836_);
if (v___x_5872_ == 0)
{
uint8_t v___x_5873_;
v___x_5873_ = lean_uint32_dec_lt(v_targetCap_5836_, v_curCap_5833_);
if (v___x_5873_ == 0)
{
uint32_t v___x_5874_;
v___x_5874_ = 259;
v___y_5856_ = v___x_5874_;
goto v___jp_5855_;
}
else
{
uint32_t v___x_5875_;
v___x_5875_ = 1282;
v___y_5856_ = v___x_5875_;
goto v___jp_5855_;
}
}
else
{
uint32_t v___x_5876_;
v___x_5876_ = 1281;
v___y_5856_ = v___x_5876_;
goto v___jp_5855_;
}
}
}
}
}
v___jp_5878_:
{
uint8_t v_staticOk_5880_; uint32_t v___x_5881_; uint8_t v___x_5882_;
v_staticOk_5880_ = lean_uint8_dec_eq(v_isStaticNode_5832_, v___x_5877_);
v___x_5881_ = 1;
v___x_5882_ = lean_uint32_dec_le(v___x_5881_, v_targetCap_5836_);
if (v___x_5882_ == 0)
{
v___y_5866_ = v_staticOk_5880_;
v___y_5867_ = v___y_5879_;
v___y_5868_ = v___x_5882_;
goto v___jp_5865_;
}
else
{
uint8_t v___x_5883_;
v___x_5883_ = lean_uint32_dec_le(v_targetCap_5836_, v_maxCap_5837_);
v___y_5866_ = v_staticOk_5880_;
v___y_5867_ = v___y_5879_;
v___y_5868_ = v___x_5883_;
goto v___jp_5865_;
}
}
}
}

LEAN_EXPORT uint32_t orb_node_lane_step(uint8_t v_isSideQuestion_5905_, uint8_t v_isCoordinatorPriority_5906_, uint8_t v_hasWorkspaceBg_5907_, uint8_t v_isChildWorker_5908_, uint8_t v_isLongRunning_5909_, uint32_t v_mainRunning_5910_, uint32_t v_mainMax_5911_, uint32_t v_sideRunning_5912_, uint32_t v_sideMax_5913_, uint32_t v_coordRunning_5914_, uint32_t v_coordMax_5915_){
_start:
{
uint8_t v___x_5920_; uint8_t v___x_5921_;
v___x_5920_ = 1;
v___x_5921_ = lean_uint8_dec_eq(v_isSideQuestion_5905_, v___x_5920_);
if (v___x_5921_ == 0)
{
uint8_t v___x_5922_;
v___x_5922_ = lean_uint8_dec_eq(v_hasWorkspaceBg_5907_, v___x_5920_);
if (v___x_5922_ == 0)
{
uint8_t v___x_5923_;
v___x_5923_ = lean_uint8_dec_eq(v_isCoordinatorPriority_5906_, v___x_5920_);
if (v___x_5923_ == 0)
{
goto v___jp_5916_;
}
else
{
uint8_t v___x_5924_;
v___x_5924_ = lean_uint8_dec_eq(v_isChildWorker_5908_, v___x_5920_);
if (v___x_5924_ == 0)
{
uint8_t v___x_5925_;
v___x_5925_ = lean_uint8_dec_eq(v_isLongRunning_5909_, v___x_5920_);
if (v___x_5925_ == 0)
{
uint8_t v___x_5926_;
v___x_5926_ = lean_uint32_dec_lt(v_mainRunning_5910_, v_mainMax_5911_);
if (v___x_5926_ == 0)
{
uint8_t v___x_5927_;
v___x_5927_ = lean_uint32_dec_lt(v_coordRunning_5914_, v_coordMax_5915_);
if (v___x_5927_ == 0)
{
uint32_t v___x_5928_;
v___x_5928_ = 515;
return v___x_5928_;
}
else
{
uint32_t v___x_5929_;
v___x_5929_ = 259;
return v___x_5929_;
}
}
else
{
uint32_t v___x_5930_;
v___x_5930_ = 257;
return v___x_5930_;
}
}
else
{
goto v___jp_5916_;
}
}
else
{
goto v___jp_5916_;
}
}
}
else
{
uint8_t v___x_5931_;
v___x_5931_ = lean_uint32_dec_lt(v_coordRunning_5914_, v_coordMax_5915_);
if (v___x_5931_ == 0)
{
uint8_t v___x_5932_;
v___x_5932_ = lean_uint32_dec_lt(v_mainRunning_5910_, v_mainMax_5911_);
if (v___x_5932_ == 0)
{
uint32_t v___x_5933_;
v___x_5933_ = 515;
return v___x_5933_;
}
else
{
uint32_t v___x_5934_;
v___x_5934_ = 257;
return v___x_5934_;
}
}
else
{
uint32_t v___x_5935_;
v___x_5935_ = 260;
return v___x_5935_;
}
}
}
else
{
uint8_t v___x_5936_;
v___x_5936_ = lean_uint32_dec_lt(v_sideRunning_5912_, v_sideMax_5913_);
if (v___x_5936_ == 0)
{
uint32_t v___x_5937_;
v___x_5937_ = 514;
return v___x_5937_;
}
else
{
uint32_t v___x_5938_;
v___x_5938_ = 258;
return v___x_5938_;
}
}
v___jp_5916_:
{
uint8_t v___x_5917_;
v___x_5917_ = lean_uint32_dec_lt(v_mainRunning_5910_, v_mainMax_5911_);
if (v___x_5917_ == 0)
{
uint32_t v___x_5918_;
v___x_5918_ = 513;
return v___x_5918_;
}
else
{
uint32_t v___x_5919_;
v___x_5919_ = 257;
return v___x_5919_;
}
}
}
}

LEAN_EXPORT uint8_t orb_wire_verify_slice_io(uint64_t v_inPtr_5991_, uint64_t v_inLen_5992_, uint64_t v_outPtr_5993_, uint64_t v_outCap_5994_, uint64_t v_writtenLen_5995_, uint8_t v_is32Bit_5996_){
_start:
{
uint8_t v___x_6007_; uint8_t v___x_6008_;
v___x_6007_ = 1;
v___x_6008_ = lean_uint8_dec_le(v_is32Bit_5996_, v___x_6007_);
if (v___x_6008_ == 0)
{
uint8_t v___x_6009_;
v___x_6009_ = 6;
return v___x_6009_;
}
else
{
uint64_t v___x_6010_; uint8_t v___x_6011_; uint8_t v___y_6018_; uint8_t v___y_6021_; uint8_t v___y_6040_; uint8_t v___y_6057_;
v___x_6010_ = 0ULL;
v___x_6011_ = lean_uint64_dec_eq(v_inLen_5992_, v___x_6010_);
if (v___x_6011_ == 0)
{
uint8_t v___x_6061_;
v___x_6061_ = lean_uint64_dec_eq(v_inPtr_5991_, v___x_6010_);
if (v___x_6061_ == 0)
{
v___y_6057_ = v___x_6008_;
goto v___jp_6056_;
}
else
{
uint8_t v___x_6062_;
v___x_6062_ = 7;
return v___x_6062_;
}
}
else
{
v___y_6057_ = v___x_6008_;
goto v___jp_6056_;
}
v___jp_6012_:
{
if (v___x_6011_ == 0)
{
uint8_t v___x_6013_;
v___x_6013_ = lean_uint64_dec_eq(v_outCap_5994_, v___x_6010_);
if (v___x_6013_ == 0)
{
uint8_t v___x_6014_;
v___x_6014_ = lean_uint64_dec_le(v_inLen_5992_, v_outPtr_5993_);
if (v___x_6014_ == 0)
{
goto v___jp_6001_;
}
else
{
uint64_t v___x_6015_; uint8_t v___x_6016_;
v___x_6015_ = lean_uint64_sub(v_outPtr_5993_, v_inLen_5992_);
v___x_6016_ = lean_uint64_dec_le(v_inPtr_5991_, v___x_6015_);
if (v___x_6016_ == 0)
{
goto v___jp_6001_;
}
else
{
goto v___jp_5997_;
}
}
}
else
{
goto v___jp_5997_;
}
}
else
{
goto v___jp_5997_;
}
}
v___jp_6017_:
{
if (v___y_6018_ == 0)
{
uint8_t v___x_6019_;
v___x_6019_ = 8;
return v___x_6019_;
}
else
{
goto v___jp_6012_;
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
uint8_t v___x_6023_;
v___x_6023_ = lean_uint8_dec_eq(v_is32Bit_5996_, v___x_6007_);
if (v___x_6023_ == 0)
{
uint8_t v___x_6024_;
v___x_6024_ = lean_uint64_dec_eq(v_outPtr_5993_, v___x_6010_);
if (v___x_6024_ == 0)
{
uint8_t v___x_6025_;
v___x_6025_ = lean_uint64_dec_eq(v_outCap_5994_, v___x_6010_);
if (v___x_6025_ == 0)
{
uint64_t v___x_6026_; uint64_t v___x_6027_; uint64_t v___x_6028_; uint64_t v___x_6029_; uint8_t v___x_6030_;
v___x_6026_ = 1ULL;
v___x_6027_ = lean_uint64_sub(v_outPtr_5993_, v___x_6026_);
v___x_6028_ = 18446744073709551615ULL;
v___x_6029_ = lean_uint64_sub(v___x_6028_, v_outCap_5994_);
v___x_6030_ = lean_uint64_dec_le(v___x_6027_, v___x_6029_);
v___y_6018_ = v___x_6030_;
goto v___jp_6017_;
}
else
{
goto v___jp_6012_;
}
}
else
{
goto v___jp_6012_;
}
}
else
{
uint64_t v___x_6031_; uint8_t v___x_6032_;
v___x_6031_ = 4294967295ULL;
v___x_6032_ = lean_uint64_dec_le(v_outPtr_5993_, v___x_6031_);
if (v___x_6032_ == 0)
{
uint8_t v___x_6033_;
v___x_6033_ = 8;
return v___x_6033_;
}
else
{
uint8_t v___x_6034_;
v___x_6034_ = lean_uint64_dec_le(v_outCap_5994_, v___x_6031_);
if (v___x_6034_ == 0)
{
uint8_t v___x_6035_;
v___x_6035_ = 8;
return v___x_6035_;
}
else
{
uint64_t v___x_6036_; uint64_t v___x_6037_; uint8_t v___x_6038_;
v___x_6036_ = lean_uint64_add(v_outPtr_5993_, v_outCap_5994_);
v___x_6037_ = 4294967296ULL;
v___x_6038_ = lean_uint64_dec_le(v___x_6036_, v___x_6037_);
v___y_6018_ = v___x_6038_;
goto v___jp_6017_;
}
}
}
}
}
v___jp_6039_:
{
uint8_t v___x_6041_;
v___x_6041_ = lean_uint8_dec_eq(v_is32Bit_5996_, v___x_6007_);
if (v___x_6041_ == 0)
{
uint8_t v___x_6042_;
v___x_6042_ = lean_uint64_dec_eq(v_inPtr_5991_, v___x_6010_);
if (v___x_6042_ == 0)
{
if (v___x_6011_ == 0)
{
uint64_t v___x_6043_; uint64_t v___x_6044_; uint64_t v___x_6045_; uint64_t v___x_6046_; uint8_t v___x_6047_;
v___x_6043_ = 1ULL;
v___x_6044_ = lean_uint64_sub(v_inPtr_5991_, v___x_6043_);
v___x_6045_ = 18446744073709551615ULL;
v___x_6046_ = lean_uint64_sub(v___x_6045_, v_inLen_5992_);
v___x_6047_ = lean_uint64_dec_le(v___x_6044_, v___x_6046_);
v___y_6021_ = v___x_6047_;
goto v___jp_6020_;
}
else
{
v___y_6021_ = v___y_6040_;
goto v___jp_6020_;
}
}
else
{
v___y_6021_ = v___y_6040_;
goto v___jp_6020_;
}
}
else
{
uint64_t v___x_6048_; uint8_t v___x_6049_;
v___x_6048_ = 4294967295ULL;
v___x_6049_ = lean_uint64_dec_le(v_inPtr_5991_, v___x_6048_);
if (v___x_6049_ == 0)
{
uint8_t v___x_6050_;
v___x_6050_ = 8;
return v___x_6050_;
}
else
{
uint8_t v___x_6051_;
v___x_6051_ = lean_uint64_dec_le(v_inLen_5992_, v___x_6048_);
if (v___x_6051_ == 0)
{
uint8_t v___x_6052_;
v___x_6052_ = 8;
return v___x_6052_;
}
else
{
uint64_t v___x_6053_; uint64_t v___x_6054_; uint8_t v___x_6055_;
v___x_6053_ = lean_uint64_add(v_inPtr_5991_, v_inLen_5992_);
v___x_6054_ = 4294967296ULL;
v___x_6055_ = lean_uint64_dec_le(v___x_6053_, v___x_6054_);
v___y_6021_ = v___x_6055_;
goto v___jp_6020_;
}
}
}
}
v___jp_6056_:
{
uint8_t v___x_6058_;
v___x_6058_ = lean_uint64_dec_eq(v_outCap_5994_, v___x_6010_);
if (v___x_6058_ == 0)
{
uint8_t v___x_6059_;
v___x_6059_ = lean_uint64_dec_eq(v_outPtr_5993_, v___x_6010_);
if (v___x_6059_ == 0)
{
v___y_6040_ = v___y_6057_;
goto v___jp_6039_;
}
else
{
uint8_t v___x_6060_;
v___x_6060_ = 7;
return v___x_6060_;
}
}
else
{
v___y_6040_ = v___x_6008_;
goto v___jp_6039_;
}
}
}
v___jp_5997_:
{
uint8_t v___x_5998_;
v___x_5998_ = lean_uint64_dec_le(v_writtenLen_5995_, v_outCap_5994_);
if (v___x_5998_ == 0)
{
uint8_t v___x_5999_;
v___x_5999_ = 5;
return v___x_5999_;
}
else
{
uint8_t v___x_6000_;
v___x_6000_ = 0;
return v___x_6000_;
}
}
v___jp_6001_:
{
uint8_t v___x_6002_;
v___x_6002_ = lean_uint64_dec_le(v_outCap_5994_, v_inPtr_5991_);
if (v___x_6002_ == 0)
{
uint8_t v___x_6003_;
v___x_6003_ = 9;
return v___x_6003_;
}
else
{
uint64_t v___x_6004_; uint8_t v___x_6005_;
v___x_6004_ = lean_uint64_sub(v_inPtr_5991_, v_outCap_5994_);
v___x_6005_ = lean_uint64_dec_le(v_outPtr_5993_, v___x_6004_);
if (v___x_6005_ == 0)
{
uint8_t v___x_6006_;
v___x_6006_ = 9;
return v___x_6006_;
}
else
{
goto v___jp_5997_;
}
}
}
}
}

LEAN_EXPORT uint8_t orb_wire_encode_slice_step(uint64_t v_inArenaPtr_6077_, uint64_t v_outPtr_6078_, uint64_t v_outCap_6079_, uint32_t v_schemaId_6080_, uint32_t v_recordsCount_6081_, uint32_t v_arenaLen_6082_, uint32_t v_maxBudgetBytes_6083_, uint8_t v_is32Bit_6084_){
_start:
{
uint32_t v___x_6085_; uint8_t v___x_6086_;
v___x_6085_ = 1;
v___x_6086_ = lean_uint32_dec_le(v___x_6085_, v_schemaId_6080_);
if (v___x_6086_ == 0)
{
uint8_t v___x_6087_;
v___x_6087_ = 2;
return v___x_6087_;
}
else
{
uint32_t v___x_6088_; uint8_t v___x_6089_;
v___x_6088_ = 65535;
v___x_6089_ = lean_uint32_dec_le(v_schemaId_6080_, v___x_6088_);
if (v___x_6089_ == 0)
{
uint8_t v___x_6090_;
v___x_6090_ = 2;
return v___x_6090_;
}
else
{
uint32_t v___x_6091_; uint8_t v___x_6092_;
v___x_6091_ = 8191;
v___x_6092_ = lean_uint32_dec_le(v_recordsCount_6081_, v___x_6091_);
if (v___x_6092_ == 0)
{
uint8_t v___x_6093_;
v___x_6093_ = 3;
return v___x_6093_;
}
else
{
uint8_t v___x_6094_;
v___x_6094_ = lean_uint32_dec_le(v_arenaLen_6082_, v___x_6088_);
if (v___x_6094_ == 0)
{
uint8_t v___x_6095_;
v___x_6095_ = 3;
return v___x_6095_;
}
else
{
uint32_t v___x_6096_; uint32_t v_recordsBytes_6097_; uint32_t v_payloadLen_6098_; uint32_t v___x_6099_; uint32_t v_totalLen_6100_; uint8_t v___x_6101_;
v___x_6096_ = 3;
v_recordsBytes_6097_ = lean_uint32_shift_left(v_recordsCount_6081_, v___x_6096_);
v_payloadLen_6098_ = lean_uint32_add(v_recordsBytes_6097_, v_arenaLen_6082_);
v___x_6099_ = 24;
v_totalLen_6100_ = lean_uint32_add(v___x_6099_, v_payloadLen_6098_);
v___x_6101_ = lean_uint32_dec_le(v_totalLen_6100_, v_maxBudgetBytes_6083_);
if (v___x_6101_ == 0)
{
uint8_t v___x_6102_;
v___x_6102_ = 4;
return v___x_6102_;
}
else
{
uint8_t v___x_6103_; uint8_t v___x_6104_;
v___x_6103_ = 1;
v___x_6104_ = lean_uint8_dec_le(v_is32Bit_6084_, v___x_6103_);
if (v___x_6104_ == 0)
{
uint8_t v___x_6105_;
v___x_6105_ = 6;
return v___x_6105_;
}
else
{
uint64_t v___x_6106_; uint64_t v___x_6107_; uint64_t v___x_6118_; uint8_t v___x_6119_; uint8_t v___y_6126_; uint8_t v___y_6129_; uint8_t v___y_6148_; uint8_t v___y_6165_;
v___x_6106_ = lean_uint32_to_uint64(v_arenaLen_6082_);
v___x_6107_ = lean_uint32_to_uint64(v_totalLen_6100_);
v___x_6118_ = 0ULL;
v___x_6119_ = lean_uint64_dec_eq(v___x_6106_, v___x_6118_);
if (v___x_6119_ == 0)
{
uint8_t v___x_6169_;
v___x_6169_ = lean_uint64_dec_eq(v_inArenaPtr_6077_, v___x_6118_);
if (v___x_6169_ == 0)
{
v___y_6165_ = v___x_6104_;
goto v___jp_6164_;
}
else
{
uint8_t v___x_6170_;
v___x_6170_ = 7;
return v___x_6170_;
}
}
else
{
v___y_6165_ = v___x_6104_;
goto v___jp_6164_;
}
v___jp_6108_:
{
uint8_t v___x_6109_;
v___x_6109_ = lean_uint64_dec_le(v___x_6107_, v_outCap_6079_);
if (v___x_6109_ == 0)
{
uint8_t v___x_6110_;
v___x_6110_ = 5;
return v___x_6110_;
}
else
{
uint8_t v___x_6111_;
v___x_6111_ = 0;
return v___x_6111_;
}
}
v___jp_6112_:
{
uint8_t v___x_6113_;
v___x_6113_ = lean_uint64_dec_le(v_outCap_6079_, v_inArenaPtr_6077_);
if (v___x_6113_ == 0)
{
uint8_t v___x_6114_;
v___x_6114_ = 9;
return v___x_6114_;
}
else
{
uint64_t v___x_6115_; uint8_t v___x_6116_;
v___x_6115_ = lean_uint64_sub(v_inArenaPtr_6077_, v_outCap_6079_);
v___x_6116_ = lean_uint64_dec_le(v_outPtr_6078_, v___x_6115_);
if (v___x_6116_ == 0)
{
uint8_t v___x_6117_;
v___x_6117_ = 9;
return v___x_6117_;
}
else
{
goto v___jp_6108_;
}
}
}
v___jp_6120_:
{
if (v___x_6119_ == 0)
{
uint8_t v___x_6121_;
v___x_6121_ = lean_uint64_dec_eq(v_outCap_6079_, v___x_6118_);
if (v___x_6121_ == 0)
{
uint8_t v___x_6122_;
v___x_6122_ = lean_uint64_dec_le(v___x_6106_, v_outPtr_6078_);
if (v___x_6122_ == 0)
{
goto v___jp_6112_;
}
else
{
uint64_t v___x_6123_; uint8_t v___x_6124_;
v___x_6123_ = lean_uint64_sub(v_outPtr_6078_, v___x_6106_);
v___x_6124_ = lean_uint64_dec_le(v_inArenaPtr_6077_, v___x_6123_);
if (v___x_6124_ == 0)
{
goto v___jp_6112_;
}
else
{
goto v___jp_6108_;
}
}
}
else
{
goto v___jp_6108_;
}
}
else
{
goto v___jp_6108_;
}
}
v___jp_6125_:
{
if (v___y_6126_ == 0)
{
uint8_t v___x_6127_;
v___x_6127_ = 8;
return v___x_6127_;
}
else
{
goto v___jp_6120_;
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
uint8_t v___x_6131_;
v___x_6131_ = lean_uint8_dec_eq(v_is32Bit_6084_, v___x_6103_);
if (v___x_6131_ == 0)
{
uint8_t v___x_6132_;
v___x_6132_ = lean_uint64_dec_eq(v_outPtr_6078_, v___x_6118_);
if (v___x_6132_ == 0)
{
uint8_t v___x_6133_;
v___x_6133_ = lean_uint64_dec_eq(v_outCap_6079_, v___x_6118_);
if (v___x_6133_ == 0)
{
uint64_t v___x_6134_; uint64_t v___x_6135_; uint64_t v___x_6136_; uint64_t v___x_6137_; uint8_t v___x_6138_;
v___x_6134_ = 1ULL;
v___x_6135_ = lean_uint64_sub(v_outPtr_6078_, v___x_6134_);
v___x_6136_ = 18446744073709551615ULL;
v___x_6137_ = lean_uint64_sub(v___x_6136_, v_outCap_6079_);
v___x_6138_ = lean_uint64_dec_le(v___x_6135_, v___x_6137_);
v___y_6126_ = v___x_6138_;
goto v___jp_6125_;
}
else
{
goto v___jp_6120_;
}
}
else
{
goto v___jp_6120_;
}
}
else
{
uint64_t v___x_6139_; uint8_t v___x_6140_;
v___x_6139_ = 4294967295ULL;
v___x_6140_ = lean_uint64_dec_le(v_outPtr_6078_, v___x_6139_);
if (v___x_6140_ == 0)
{
uint8_t v___x_6141_;
v___x_6141_ = 8;
return v___x_6141_;
}
else
{
uint8_t v___x_6142_;
v___x_6142_ = lean_uint64_dec_le(v_outCap_6079_, v___x_6139_);
if (v___x_6142_ == 0)
{
uint8_t v___x_6143_;
v___x_6143_ = 8;
return v___x_6143_;
}
else
{
uint64_t v___x_6144_; uint64_t v___x_6145_; uint8_t v___x_6146_;
v___x_6144_ = lean_uint64_add(v_outPtr_6078_, v_outCap_6079_);
v___x_6145_ = 4294967296ULL;
v___x_6146_ = lean_uint64_dec_le(v___x_6144_, v___x_6145_);
v___y_6126_ = v___x_6146_;
goto v___jp_6125_;
}
}
}
}
}
v___jp_6147_:
{
uint8_t v___x_6149_;
v___x_6149_ = lean_uint8_dec_eq(v_is32Bit_6084_, v___x_6103_);
if (v___x_6149_ == 0)
{
uint8_t v___x_6150_;
v___x_6150_ = lean_uint64_dec_eq(v_inArenaPtr_6077_, v___x_6118_);
if (v___x_6150_ == 0)
{
if (v___x_6119_ == 0)
{
uint64_t v___x_6151_; uint64_t v___x_6152_; uint64_t v___x_6153_; uint64_t v___x_6154_; uint8_t v___x_6155_;
v___x_6151_ = 1ULL;
v___x_6152_ = lean_uint64_sub(v_inArenaPtr_6077_, v___x_6151_);
v___x_6153_ = 18446744073709551615ULL;
v___x_6154_ = lean_uint64_sub(v___x_6153_, v___x_6106_);
v___x_6155_ = lean_uint64_dec_le(v___x_6152_, v___x_6154_);
v___y_6129_ = v___x_6155_;
goto v___jp_6128_;
}
else
{
v___y_6129_ = v___y_6148_;
goto v___jp_6128_;
}
}
else
{
v___y_6129_ = v___y_6148_;
goto v___jp_6128_;
}
}
else
{
uint64_t v___x_6156_; uint8_t v___x_6157_;
v___x_6156_ = 4294967295ULL;
v___x_6157_ = lean_uint64_dec_le(v_inArenaPtr_6077_, v___x_6156_);
if (v___x_6157_ == 0)
{
uint8_t v___x_6158_;
v___x_6158_ = 8;
return v___x_6158_;
}
else
{
uint8_t v___x_6159_;
v___x_6159_ = lean_uint64_dec_le(v___x_6106_, v___x_6156_);
if (v___x_6159_ == 0)
{
uint8_t v___x_6160_;
v___x_6160_ = 8;
return v___x_6160_;
}
else
{
uint64_t v___x_6161_; uint64_t v___x_6162_; uint8_t v___x_6163_;
v___x_6161_ = lean_uint64_add(v_inArenaPtr_6077_, v___x_6106_);
v___x_6162_ = 4294967296ULL;
v___x_6163_ = lean_uint64_dec_le(v___x_6161_, v___x_6162_);
v___y_6129_ = v___x_6163_;
goto v___jp_6128_;
}
}
}
}
v___jp_6164_:
{
uint8_t v___x_6166_;
v___x_6166_ = lean_uint64_dec_eq(v_outCap_6079_, v___x_6118_);
if (v___x_6166_ == 0)
{
uint8_t v___x_6167_;
v___x_6167_ = lean_uint64_dec_eq(v_outPtr_6078_, v___x_6118_);
if (v___x_6167_ == 0)
{
v___y_6148_ = v___y_6165_;
goto v___jp_6147_;
}
else
{
uint8_t v___x_6168_;
v___x_6168_ = 7;
return v___x_6168_;
}
}
else
{
v___y_6148_ = v___x_6104_;
goto v___jp_6147_;
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

LEAN_EXPORT uint8_t orb_wire_decode_slice_step(uint64_t v_inPtr_6189_, uint64_t v_inLen_6190_, uint8_t v_is32Bit_6191_, uint32_t v_magic_6192_, uint32_t v_abiVersion_6193_, uint32_t v_schemaId_6194_, uint32_t v_expectedSchemaId_6195_, uint32_t v_totalLen_6196_, uint32_t v_payloadLen_6197_, uint32_t v_arenaOff_6198_, uint32_t v_arenaLen_6199_, uint32_t v_maxBudgetBytes_6200_){
_start:
{
uint8_t v___y_6202_; uint32_t v___y_6203_; uint8_t v___y_6204_; uint8_t v___y_6226_; uint8_t v___y_6252_; uint8_t v___x_6255_; uint8_t v___x_6256_;
v___x_6255_ = 1;
v___x_6256_ = lean_uint8_dec_le(v_is32Bit_6191_, v___x_6255_);
if (v___x_6256_ == 0)
{
uint8_t v___x_6257_;
v___x_6257_ = 6;
v___y_6226_ = v___x_6257_;
goto v___jp_6225_;
}
else
{
uint64_t v___x_6258_; uint8_t v___x_6259_;
v___x_6258_ = 0ULL;
v___x_6259_ = lean_uint64_dec_eq(v_inLen_6190_, v___x_6258_);
if (v___x_6259_ == 0)
{
uint8_t v___x_6276_;
v___x_6276_ = lean_uint64_dec_eq(v_inPtr_6189_, v___x_6258_);
if (v___x_6276_ == 0)
{
goto v___jp_6260_;
}
else
{
uint8_t v___x_6277_;
v___x_6277_ = 7;
v___y_6226_ = v___x_6277_;
goto v___jp_6225_;
}
}
else
{
goto v___jp_6260_;
}
v___jp_6260_:
{
uint8_t v___x_6261_;
v___x_6261_ = lean_uint8_dec_eq(v_is32Bit_6191_, v___x_6255_);
if (v___x_6261_ == 0)
{
uint8_t v___x_6262_;
v___x_6262_ = lean_uint64_dec_eq(v_inPtr_6189_, v___x_6258_);
if (v___x_6262_ == 0)
{
if (v___x_6259_ == 0)
{
uint64_t v___x_6263_; uint64_t v___x_6264_; uint64_t v___x_6265_; uint64_t v___x_6266_; uint8_t v___x_6267_;
v___x_6263_ = 1ULL;
v___x_6264_ = lean_uint64_sub(v_inPtr_6189_, v___x_6263_);
v___x_6265_ = 18446744073709551615ULL;
v___x_6266_ = lean_uint64_sub(v___x_6265_, v_inLen_6190_);
v___x_6267_ = lean_uint64_dec_le(v___x_6264_, v___x_6266_);
v___y_6252_ = v___x_6267_;
goto v___jp_6251_;
}
else
{
v___y_6252_ = v___x_6256_;
goto v___jp_6251_;
}
}
else
{
v___y_6252_ = v___x_6256_;
goto v___jp_6251_;
}
}
else
{
uint64_t v___x_6268_; uint8_t v___x_6269_;
v___x_6268_ = 4294967295ULL;
v___x_6269_ = lean_uint64_dec_le(v_inPtr_6189_, v___x_6268_);
if (v___x_6269_ == 0)
{
uint8_t v___x_6270_;
v___x_6270_ = 8;
v___y_6226_ = v___x_6270_;
goto v___jp_6225_;
}
else
{
uint8_t v___x_6271_;
v___x_6271_ = lean_uint64_dec_le(v_inLen_6190_, v___x_6268_);
if (v___x_6271_ == 0)
{
uint8_t v___x_6272_;
v___x_6272_ = 8;
v___y_6226_ = v___x_6272_;
goto v___jp_6225_;
}
else
{
uint64_t v___x_6273_; uint64_t v___x_6274_; uint8_t v___x_6275_;
v___x_6273_ = lean_uint64_add(v_inPtr_6189_, v_inLen_6190_);
v___x_6274_ = 4294967296ULL;
v___x_6275_ = lean_uint64_dec_le(v___x_6273_, v___x_6274_);
v___y_6252_ = v___x_6275_;
goto v___jp_6251_;
}
}
}
}
}
v___jp_6201_:
{
uint8_t v___x_6205_;
v___x_6205_ = lean_uint8_dec_eq(v___y_6204_, v___y_6202_);
if (v___x_6205_ == 0)
{
return v___y_6204_;
}
else
{
uint64_t v___x_6206_; uint8_t v___x_6207_;
v___x_6206_ = lean_uint32_to_uint64(v_totalLen_6196_);
v___x_6207_ = lean_uint64_dec_eq(v_inLen_6190_, v___x_6206_);
if (v___x_6207_ == 0)
{
uint8_t v___x_6208_;
v___x_6208_ = 3;
return v___x_6208_;
}
else
{
uint32_t v___x_6209_; uint32_t v___x_6210_; uint8_t v___x_6211_;
v___x_6209_ = 7;
v___x_6210_ = lean_uint32_land(v_arenaOff_6198_, v___x_6209_);
v___x_6211_ = lean_uint32_dec_eq(v___x_6210_, v___y_6203_);
if (v___x_6211_ == 0)
{
uint8_t v___x_6212_;
v___x_6212_ = 3;
return v___x_6212_;
}
else
{
uint32_t v___x_6213_; uint8_t v___x_6214_;
v___x_6213_ = 65535;
v___x_6214_ = lean_uint32_dec_le(v_arenaOff_6198_, v___x_6213_);
if (v___x_6214_ == 0)
{
uint8_t v___x_6215_;
v___x_6215_ = 3;
return v___x_6215_;
}
else
{
uint8_t v___x_6216_;
v___x_6216_ = lean_uint32_dec_le(v_arenaLen_6199_, v___x_6213_);
if (v___x_6216_ == 0)
{
uint8_t v___x_6217_;
v___x_6217_ = 3;
return v___x_6217_;
}
else
{
uint32_t v___x_6218_; uint8_t v___x_6219_;
v___x_6218_ = lean_uint32_add(v_arenaOff_6198_, v_arenaLen_6199_);
v___x_6219_ = lean_uint32_dec_eq(v___x_6218_, v_payloadLen_6197_);
if (v___x_6219_ == 0)
{
uint8_t v___x_6220_;
v___x_6220_ = 3;
return v___x_6220_;
}
else
{
uint32_t v___x_6221_; uint32_t v___x_6222_; uint8_t v___x_6223_;
v___x_6221_ = 24;
v___x_6222_ = lean_uint32_add(v___x_6221_, v_payloadLen_6197_);
v___x_6223_ = lean_uint32_dec_eq(v___x_6222_, v_totalLen_6196_);
if (v___x_6223_ == 0)
{
uint8_t v___x_6224_;
v___x_6224_ = 3;
return v___x_6224_;
}
else
{
return v___y_6202_;
}
}
}
}
}
}
}
}
v___jp_6225_:
{
uint8_t v___x_6227_; uint8_t v___x_6228_;
v___x_6227_ = 0;
v___x_6228_ = lean_uint8_dec_eq(v___y_6226_, v___x_6227_);
if (v___x_6228_ == 0)
{
return v___y_6226_;
}
else
{
uint32_t v___x_6229_; uint32_t v___x_6230_; uint8_t v___x_6231_;
v___x_6229_ = 0;
v___x_6230_ = 1330790999;
v___x_6231_ = lean_uint32_dec_eq(v_magic_6192_, v___x_6230_);
if (v___x_6231_ == 0)
{
uint8_t v___x_6232_;
v___x_6232_ = 1;
v___y_6202_ = v___x_6227_;
v___y_6203_ = v___x_6229_;
v___y_6204_ = v___x_6232_;
goto v___jp_6201_;
}
else
{
uint32_t v___x_6233_; uint8_t v___x_6234_;
v___x_6233_ = 1;
v___x_6234_ = lean_uint32_dec_eq(v_abiVersion_6193_, v___x_6233_);
if (v___x_6234_ == 0)
{
uint8_t v___x_6235_;
v___x_6235_ = 1;
v___y_6202_ = v___x_6227_;
v___y_6203_ = v___x_6229_;
v___y_6204_ = v___x_6235_;
goto v___jp_6201_;
}
else
{
uint8_t v___x_6236_;
v___x_6236_ = lean_uint32_dec_eq(v_schemaId_6194_, v_expectedSchemaId_6195_);
if (v___x_6236_ == 0)
{
uint8_t v___x_6237_;
v___x_6237_ = 2;
v___y_6202_ = v___x_6227_;
v___y_6203_ = v___x_6229_;
v___y_6204_ = v___x_6237_;
goto v___jp_6201_;
}
else
{
uint32_t v___x_6238_; uint8_t v___x_6239_;
v___x_6238_ = 24;
v___x_6239_ = lean_uint32_dec_le(v___x_6238_, v_totalLen_6196_);
if (v___x_6239_ == 0)
{
uint8_t v___x_6240_;
v___x_6240_ = 3;
v___y_6202_ = v___x_6227_;
v___y_6203_ = v___x_6229_;
v___y_6204_ = v___x_6240_;
goto v___jp_6201_;
}
else
{
uint8_t v___x_6241_;
v___x_6241_ = lean_uint32_dec_le(v_totalLen_6196_, v_maxBudgetBytes_6200_);
if (v___x_6241_ == 0)
{
uint8_t v___x_6242_;
v___x_6242_ = 4;
v___y_6202_ = v___x_6227_;
v___y_6203_ = v___x_6229_;
v___y_6204_ = v___x_6242_;
goto v___jp_6201_;
}
else
{
uint32_t v___x_6243_; uint8_t v___x_6244_;
v___x_6243_ = lean_uint32_sub(v_totalLen_6196_, v___x_6238_);
v___x_6244_ = lean_uint32_dec_le(v_payloadLen_6197_, v___x_6243_);
if (v___x_6244_ == 0)
{
uint8_t v___x_6245_;
v___x_6245_ = 3;
v___y_6202_ = v___x_6227_;
v___y_6203_ = v___x_6229_;
v___y_6204_ = v___x_6245_;
goto v___jp_6201_;
}
else
{
uint8_t v___x_6246_;
v___x_6246_ = lean_uint32_dec_le(v_arenaOff_6198_, v_payloadLen_6197_);
if (v___x_6246_ == 0)
{
uint8_t v___x_6247_;
v___x_6247_ = 3;
v___y_6202_ = v___x_6227_;
v___y_6203_ = v___x_6229_;
v___y_6204_ = v___x_6247_;
goto v___jp_6201_;
}
else
{
uint32_t v___x_6248_; uint8_t v___x_6249_;
v___x_6248_ = lean_uint32_sub(v_payloadLen_6197_, v_arenaOff_6198_);
v___x_6249_ = lean_uint32_dec_le(v_arenaLen_6199_, v___x_6248_);
if (v___x_6249_ == 0)
{
uint8_t v___x_6250_;
v___x_6250_ = 3;
v___y_6202_ = v___x_6227_;
v___y_6203_ = v___x_6229_;
v___y_6204_ = v___x_6250_;
goto v___jp_6201_;
}
else
{
v___y_6202_ = v___x_6227_;
v___y_6203_ = v___x_6229_;
v___y_6204_ = v___x_6227_;
goto v___jp_6201_;
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
v___jp_6251_:
{
if (v___y_6252_ == 0)
{
uint8_t v___x_6253_;
v___x_6253_ = 8;
v___y_6226_ = v___x_6253_;
goto v___jp_6225_;
}
else
{
uint8_t v___x_6254_;
v___x_6254_ = 0;
v___y_6226_ = v___x_6254_;
goto v___jp_6225_;
}
}
}
}

LEAN_EXPORT uint8_t orb_fleet_endpoint_gate(uint8_t v_meshReachable_6304_, uint8_t v_routerReady_6305_, uint8_t v_modelLoaded_6306_, uint8_t v_breakerOpen_6307_){
_start:
{
uint8_t v___x_6308_; uint8_t v___x_6309_;
v___x_6308_ = 1;
v___x_6309_ = lean_uint8_dec_eq(v_meshReachable_6304_, v___x_6308_);
if (v___x_6309_ == 0)
{
uint8_t v___x_6310_;
v___x_6310_ = 0;
return v___x_6310_;
}
else
{
uint8_t v___x_6311_;
v___x_6311_ = lean_uint8_dec_eq(v_routerReady_6305_, v___x_6308_);
if (v___x_6311_ == 0)
{
uint8_t v___x_6312_;
v___x_6312_ = 0;
return v___x_6312_;
}
else
{
uint8_t v___x_6313_;
v___x_6313_ = lean_uint8_dec_eq(v_modelLoaded_6306_, v___x_6308_);
if (v___x_6313_ == 0)
{
uint8_t v___x_6314_;
v___x_6314_ = 0;
return v___x_6314_;
}
else
{
uint8_t v___x_6315_; uint8_t v___x_6316_;
v___x_6315_ = 0;
v___x_6316_ = lean_uint8_dec_eq(v_breakerOpen_6307_, v___x_6315_);
if (v___x_6316_ == 0)
{
return v___x_6315_;
}
else
{
return v___x_6308_;
}
}
}
}
}
}

LEAN_EXPORT uint64_t orb_prefill_deadline_ms(uint64_t v_promptTokens_6327_, uint64_t v_baseMs_6328_, uint64_t v_perKTokensMs_6329_, uint64_t v_maxPrefillMs_6330_){
_start:
{
uint8_t v___x_6331_;
v___x_6331_ = lean_uint64_dec_le(v_maxPrefillMs_6330_, v_baseMs_6328_);
if (v___x_6331_ == 0)
{
uint64_t v___x_6332_; uint8_t v___x_6333_;
v___x_6332_ = 0ULL;
v___x_6333_ = lean_uint64_dec_eq(v_perKTokensMs_6329_, v___x_6332_);
if (v___x_6333_ == 0)
{
uint64_t v___x_6334_; uint64_t v___x_6335_; uint8_t v___x_6336_;
v___x_6334_ = 10ULL;
v___x_6335_ = lean_uint64_shift_right(v_promptTokens_6327_, v___x_6334_);
v___x_6336_ = lean_uint64_dec_eq(v___x_6335_, v___x_6332_);
if (v___x_6336_ == 0)
{
uint64_t v___x_6337_; uint64_t v___x_6338_; uint8_t v___x_6339_;
v___x_6337_ = lean_uint64_sub(v_maxPrefillMs_6330_, v_baseMs_6328_);
v___x_6338_ = lean_uint64_div(v___x_6337_, v_perKTokensMs_6329_);
v___x_6339_ = lean_uint64_dec_lt(v___x_6338_, v___x_6335_);
if (v___x_6339_ == 0)
{
uint64_t v___x_6340_; uint64_t v___x_6341_;
v___x_6340_ = lean_uint64_mul(v___x_6335_, v_perKTokensMs_6329_);
v___x_6341_ = lean_uint64_add(v_baseMs_6328_, v___x_6340_);
return v___x_6341_;
}
else
{
return v_maxPrefillMs_6330_;
}
}
else
{
return v_baseMs_6328_;
}
}
else
{
return v_baseMs_6328_;
}
}
else
{
return v_baseMs_6328_;
}
}
}

LEAN_EXPORT uint64_t orb_scroll_policy_gap(uint64_t v_height_6516_, uint64_t v_client_6517_, uint64_t v_top_6518_){
_start:
{
uint64_t v___y_6520_; uint8_t v___y_6521_; uint8_t v___y_6522_; uint64_t v___y_6523_; uint8_t v___y_6525_; uint64_t v___y_6526_; uint8_t v___y_6527_; uint8_t v___y_6528_; uint64_t v___y_6529_; uint8_t v___y_6530_; uint64_t v___y_6532_; uint64_t v_diff_6540_; uint64_t v___x_6541_; uint8_t v_aNeg_6542_; uint8_t v_bNeg_6543_; uint8_t v_dNeg_6544_; uint8_t v___y_6546_; uint8_t v___y_6548_;
v_diff_6540_ = lean_uint64_sub(v_height_6516_, v_top_6518_);
v___x_6541_ = 9223372036854775808ULL;
v_aNeg_6542_ = lean_uint64_dec_le(v___x_6541_, v_height_6516_);
v_bNeg_6543_ = lean_uint64_dec_le(v___x_6541_, v_top_6518_);
v_dNeg_6544_ = lean_uint64_dec_le(v___x_6541_, v_diff_6540_);
if (v_aNeg_6542_ == 0)
{
if (v_bNeg_6543_ == 0)
{
v___y_6548_ = v_bNeg_6543_;
goto v___jp_6547_;
}
else
{
if (v_dNeg_6544_ == 0)
{
v___y_6548_ = v_dNeg_6544_;
goto v___jp_6547_;
}
else
{
uint64_t v___x_6549_;
v___x_6549_ = 9223372036854775807ULL;
v___y_6532_ = v___x_6549_;
goto v___jp_6531_;
}
}
}
else
{
uint8_t v___x_6550_;
v___x_6550_ = 0;
v___y_6548_ = v___x_6550_;
goto v___jp_6547_;
}
v___jp_6519_:
{
if (v___y_6522_ == 0)
{
return v___y_6520_;
}
else
{
if (v___y_6521_ == 0)
{
return v___y_6523_;
}
else
{
return v___y_6520_;
}
}
}
v___jp_6524_:
{
if (v___y_6527_ == 0)
{
return v___y_6529_;
}
else
{
if (v___y_6525_ == 0)
{
v___y_6520_ = v___y_6526_;
v___y_6521_ = v___y_6530_;
v___y_6522_ = v___y_6528_;
v___y_6523_ = v___y_6529_;
goto v___jp_6519_;
}
else
{
if (v___y_6530_ == 0)
{
return v___y_6529_;
}
else
{
v___y_6520_ = v___y_6526_;
v___y_6521_ = v___y_6530_;
v___y_6522_ = v___y_6528_;
v___y_6523_ = v___y_6529_;
goto v___jp_6519_;
}
}
}
}
v___jp_6531_:
{
uint64_t v_diff_6533_; uint64_t v___x_6534_; uint8_t v_aNeg_6535_; uint8_t v_bNeg_6536_; uint8_t v_dNeg_6537_;
v_diff_6533_ = lean_uint64_sub(v___y_6532_, v_client_6517_);
v___x_6534_ = 9223372036854775808ULL;
v_aNeg_6535_ = lean_uint64_dec_le(v___x_6534_, v___y_6532_);
v_bNeg_6536_ = lean_uint64_dec_le(v___x_6534_, v_client_6517_);
v_dNeg_6537_ = lean_uint64_dec_le(v___x_6534_, v_diff_6533_);
if (v_aNeg_6535_ == 0)
{
if (v_bNeg_6536_ == 0)
{
v___y_6525_ = v_bNeg_6536_;
v___y_6526_ = v___x_6534_;
v___y_6527_ = v_aNeg_6535_;
v___y_6528_ = v_dNeg_6537_;
v___y_6529_ = v_diff_6533_;
v___y_6530_ = v_bNeg_6536_;
goto v___jp_6524_;
}
else
{
if (v_dNeg_6537_ == 0)
{
v___y_6525_ = v_bNeg_6536_;
v___y_6526_ = v___x_6534_;
v___y_6527_ = v_aNeg_6535_;
v___y_6528_ = v_dNeg_6537_;
v___y_6529_ = v_diff_6533_;
v___y_6530_ = v_dNeg_6537_;
goto v___jp_6524_;
}
else
{
uint64_t v___x_6538_;
v___x_6538_ = 9223372036854775807ULL;
return v___x_6538_;
}
}
}
else
{
uint8_t v___x_6539_;
v___x_6539_ = 0;
v___y_6525_ = v_bNeg_6536_;
v___y_6526_ = v___x_6534_;
v___y_6527_ = v_aNeg_6535_;
v___y_6528_ = v_dNeg_6537_;
v___y_6529_ = v_diff_6533_;
v___y_6530_ = v___x_6539_;
goto v___jp_6524_;
}
}
v___jp_6545_:
{
if (v_dNeg_6544_ == 0)
{
v___y_6532_ = v___x_6541_;
goto v___jp_6531_;
}
else
{
if (v___y_6546_ == 0)
{
v___y_6532_ = v_diff_6540_;
goto v___jp_6531_;
}
else
{
v___y_6532_ = v___x_6541_;
goto v___jp_6531_;
}
}
}
v___jp_6547_:
{
if (v_aNeg_6542_ == 0)
{
v___y_6532_ = v_diff_6540_;
goto v___jp_6531_;
}
else
{
if (v_bNeg_6543_ == 0)
{
v___y_6546_ = v___y_6548_;
goto v___jp_6545_;
}
else
{
if (v___y_6548_ == 0)
{
v___y_6532_ = v_diff_6540_;
goto v___jp_6531_;
}
else
{
v___y_6546_ = v___y_6548_;
goto v___jp_6545_;
}
}
}
}
}
}

LEAN_EXPORT uint64_t orb_scroll_policy_correct(uint64_t v_height_6559_, uint64_t v_client_6560_, uint64_t v_top_6561_, uint64_t v_anchorDoc_6562_, uint64_t v_y0_6563_){
_start:
{
uint64_t v___y_6565_; uint64_t v___y_6566_; uint64_t v___y_6571_; uint64_t v___y_6572_; uint64_t v___y_6573_; uint64_t v___y_6579_; uint64_t v___y_6580_; uint64_t v___y_6581_; uint64_t v___y_6586_; uint8_t v___y_6587_; uint8_t v___y_6588_; uint64_t v___y_6589_; uint64_t v___y_6590_; uint64_t v___y_6591_; uint8_t v___y_6593_; uint64_t v___y_6594_; uint8_t v___y_6595_; uint8_t v___y_6596_; uint64_t v___y_6597_; uint64_t v___y_6598_; uint64_t v___y_6599_; uint8_t v___y_6600_; uint64_t v___y_6602_; uint64_t v___y_6612_; uint8_t v___y_6613_; uint64_t v___y_6614_; uint8_t v___y_6615_; uint8_t v___y_6616_; uint8_t v___y_6617_; uint64_t v___y_6619_; uint64_t v___y_6628_; uint8_t v___y_6629_; uint64_t v___y_6630_; uint8_t v___y_6631_; uint8_t v___y_6633_; uint64_t v___y_6634_; uint64_t v___y_6635_; uint8_t v___y_6636_; uint8_t v___y_6637_; uint8_t v___y_6638_; uint64_t v___y_6640_; uint64_t v_diff_6648_; uint64_t v___x_6649_; uint8_t v_aNeg_6650_; uint8_t v_bNeg_6651_; uint8_t v_dNeg_6652_; uint8_t v___y_6654_; uint8_t v___y_6656_;
v_diff_6648_ = lean_uint64_sub(v_anchorDoc_6562_, v_top_6561_);
v___x_6649_ = 9223372036854775808ULL;
v_aNeg_6650_ = lean_uint64_dec_le(v___x_6649_, v_anchorDoc_6562_);
v_bNeg_6651_ = lean_uint64_dec_le(v___x_6649_, v_top_6561_);
v_dNeg_6652_ = lean_uint64_dec_le(v___x_6649_, v_diff_6648_);
if (v_aNeg_6650_ == 0)
{
if (v_bNeg_6651_ == 0)
{
v___y_6656_ = v_bNeg_6651_;
goto v___jp_6655_;
}
else
{
if (v_dNeg_6652_ == 0)
{
v___y_6656_ = v_dNeg_6652_;
goto v___jp_6655_;
}
else
{
uint64_t v___x_6657_;
v___x_6657_ = 9223372036854775807ULL;
v___y_6640_ = v___x_6657_;
goto v___jp_6639_;
}
}
}
else
{
uint8_t v___x_6658_;
v___x_6658_ = 0;
v___y_6656_ = v___x_6658_;
goto v___jp_6655_;
}
v___jp_6564_:
{
uint64_t v___x_6567_; uint64_t v___x_6568_; uint8_t v___x_6569_;
v___x_6567_ = 9223372036854775808ULL;
v___x_6568_ = lean_uint64_add(v___y_6566_, v___x_6567_);
v___x_6569_ = lean_uint64_dec_lt(v___x_6567_, v___x_6568_);
if (v___x_6569_ == 0)
{
return v___y_6565_;
}
else
{
return v___y_6566_;
}
}
v___jp_6570_:
{
uint64_t v___x_6574_; uint64_t v___x_6575_; uint64_t v___x_6576_; uint8_t v___x_6577_;
v___x_6574_ = 9223372036854775808ULL;
v___x_6575_ = lean_uint64_add(v___y_6572_, v___x_6574_);
v___x_6576_ = lean_uint64_add(v___y_6573_, v___x_6574_);
v___x_6577_ = lean_uint64_dec_le(v___x_6575_, v___x_6576_);
if (v___x_6577_ == 0)
{
v___y_6565_ = v___y_6571_;
v___y_6566_ = v___y_6573_;
goto v___jp_6564_;
}
else
{
v___y_6565_ = v___y_6571_;
v___y_6566_ = v___y_6572_;
goto v___jp_6564_;
}
}
v___jp_6578_:
{
uint64_t v___x_6582_; uint64_t v___x_6583_; uint8_t v___x_6584_;
v___x_6582_ = 9223372036854775808ULL;
v___x_6583_ = lean_uint64_add(v___y_6581_, v___x_6582_);
v___x_6584_ = lean_uint64_dec_lt(v___x_6582_, v___x_6583_);
if (v___x_6584_ == 0)
{
v___y_6571_ = v___y_6579_;
v___y_6572_ = v___y_6580_;
v___y_6573_ = v___y_6579_;
goto v___jp_6570_;
}
else
{
v___y_6571_ = v___y_6579_;
v___y_6572_ = v___y_6580_;
v___y_6573_ = v___y_6581_;
goto v___jp_6570_;
}
}
v___jp_6585_:
{
if (v___y_6587_ == 0)
{
v___y_6579_ = v___y_6590_;
v___y_6580_ = v___y_6591_;
v___y_6581_ = v___y_6586_;
goto v___jp_6578_;
}
else
{
if (v___y_6588_ == 0)
{
v___y_6579_ = v___y_6590_;
v___y_6580_ = v___y_6591_;
v___y_6581_ = v___y_6589_;
goto v___jp_6578_;
}
else
{
v___y_6579_ = v___y_6590_;
v___y_6580_ = v___y_6591_;
v___y_6581_ = v___y_6586_;
goto v___jp_6578_;
}
}
}
v___jp_6592_:
{
if (v___y_6593_ == 0)
{
v___y_6579_ = v___y_6598_;
v___y_6580_ = v___y_6599_;
v___y_6581_ = v___y_6597_;
goto v___jp_6578_;
}
else
{
if (v___y_6595_ == 0)
{
v___y_6586_ = v___y_6594_;
v___y_6587_ = v___y_6596_;
v___y_6588_ = v___y_6600_;
v___y_6589_ = v___y_6597_;
v___y_6590_ = v___y_6598_;
v___y_6591_ = v___y_6599_;
goto v___jp_6585_;
}
else
{
if (v___y_6600_ == 0)
{
v___y_6579_ = v___y_6598_;
v___y_6580_ = v___y_6599_;
v___y_6581_ = v___y_6597_;
goto v___jp_6578_;
}
else
{
v___y_6586_ = v___y_6594_;
v___y_6587_ = v___y_6596_;
v___y_6588_ = v___y_6600_;
v___y_6589_ = v___y_6597_;
v___y_6590_ = v___y_6598_;
v___y_6591_ = v___y_6599_;
goto v___jp_6585_;
}
}
}
}
v___jp_6601_:
{
uint64_t v___x_6603_; uint64_t v_diff_6604_; uint64_t v___x_6605_; uint8_t v_aNeg_6606_; uint8_t v_bNeg_6607_; uint8_t v_dNeg_6608_;
v___x_6603_ = 0ULL;
v_diff_6604_ = lean_uint64_sub(v_height_6559_, v_client_6560_);
v___x_6605_ = 9223372036854775808ULL;
v_aNeg_6606_ = lean_uint64_dec_le(v___x_6605_, v_height_6559_);
v_bNeg_6607_ = lean_uint64_dec_le(v___x_6605_, v_client_6560_);
v_dNeg_6608_ = lean_uint64_dec_le(v___x_6605_, v_diff_6604_);
if (v_aNeg_6606_ == 0)
{
if (v_bNeg_6607_ == 0)
{
v___y_6593_ = v_aNeg_6606_;
v___y_6594_ = v___x_6605_;
v___y_6595_ = v_bNeg_6607_;
v___y_6596_ = v_dNeg_6608_;
v___y_6597_ = v_diff_6604_;
v___y_6598_ = v___x_6603_;
v___y_6599_ = v___y_6602_;
v___y_6600_ = v_bNeg_6607_;
goto v___jp_6592_;
}
else
{
if (v_dNeg_6608_ == 0)
{
v___y_6593_ = v_aNeg_6606_;
v___y_6594_ = v___x_6605_;
v___y_6595_ = v_bNeg_6607_;
v___y_6596_ = v_dNeg_6608_;
v___y_6597_ = v_diff_6604_;
v___y_6598_ = v___x_6603_;
v___y_6599_ = v___y_6602_;
v___y_6600_ = v_dNeg_6608_;
goto v___jp_6592_;
}
else
{
uint64_t v___x_6609_;
v___x_6609_ = 9223372036854775807ULL;
v___y_6579_ = v___x_6603_;
v___y_6580_ = v___y_6602_;
v___y_6581_ = v___x_6609_;
goto v___jp_6578_;
}
}
}
else
{
uint8_t v___x_6610_;
v___x_6610_ = 0;
v___y_6593_ = v_aNeg_6606_;
v___y_6594_ = v___x_6605_;
v___y_6595_ = v_bNeg_6607_;
v___y_6596_ = v_dNeg_6608_;
v___y_6597_ = v_diff_6604_;
v___y_6598_ = v___x_6603_;
v___y_6599_ = v___y_6602_;
v___y_6600_ = v___x_6610_;
goto v___jp_6592_;
}
}
v___jp_6611_:
{
if (v___y_6613_ == 0)
{
v___y_6602_ = v___y_6612_;
goto v___jp_6601_;
}
else
{
if (v___y_6616_ == 0)
{
v___y_6602_ = v___y_6612_;
goto v___jp_6601_;
}
else
{
if (v___y_6615_ == 0)
{
v___y_6602_ = v___y_6614_;
goto v___jp_6601_;
}
else
{
if (v___y_6617_ == 0)
{
v___y_6602_ = v___y_6612_;
goto v___jp_6601_;
}
else
{
v___y_6602_ = v___y_6614_;
goto v___jp_6601_;
}
}
}
}
}
v___jp_6618_:
{
uint64_t v_sum_6620_; uint64_t v___x_6621_; uint8_t v_aNeg_6622_; uint8_t v_bNeg_6623_; uint8_t v_sNeg_6624_;
v_sum_6620_ = lean_uint64_add(v_top_6561_, v___y_6619_);
v___x_6621_ = 9223372036854775808ULL;
v_aNeg_6622_ = lean_uint64_dec_le(v___x_6621_, v_top_6561_);
v_bNeg_6623_ = lean_uint64_dec_le(v___x_6621_, v___y_6619_);
v_sNeg_6624_ = lean_uint64_dec_le(v___x_6621_, v_sum_6620_);
if (v_aNeg_6622_ == 0)
{
if (v_bNeg_6623_ == 0)
{
if (v_sNeg_6624_ == 0)
{
v___y_6612_ = v_sum_6620_;
v___y_6613_ = v_aNeg_6622_;
v___y_6614_ = v___x_6621_;
v___y_6615_ = v_sNeg_6624_;
v___y_6616_ = v_bNeg_6623_;
v___y_6617_ = v_sNeg_6624_;
goto v___jp_6611_;
}
else
{
uint64_t v___x_6625_;
v___x_6625_ = 9223372036854775807ULL;
v___y_6602_ = v___x_6625_;
goto v___jp_6601_;
}
}
else
{
v___y_6612_ = v_sum_6620_;
v___y_6613_ = v_aNeg_6622_;
v___y_6614_ = v___x_6621_;
v___y_6615_ = v_sNeg_6624_;
v___y_6616_ = v_bNeg_6623_;
v___y_6617_ = v_aNeg_6622_;
goto v___jp_6611_;
}
}
else
{
uint8_t v___x_6626_;
v___x_6626_ = 0;
v___y_6612_ = v_sum_6620_;
v___y_6613_ = v_aNeg_6622_;
v___y_6614_ = v___x_6621_;
v___y_6615_ = v_sNeg_6624_;
v___y_6616_ = v_bNeg_6623_;
v___y_6617_ = v___x_6626_;
goto v___jp_6611_;
}
}
v___jp_6627_:
{
if (v___y_6631_ == 0)
{
v___y_6619_ = v___y_6630_;
goto v___jp_6618_;
}
else
{
if (v___y_6629_ == 0)
{
v___y_6619_ = v___y_6628_;
goto v___jp_6618_;
}
else
{
v___y_6619_ = v___y_6630_;
goto v___jp_6618_;
}
}
}
v___jp_6632_:
{
if (v___y_6633_ == 0)
{
v___y_6619_ = v___y_6635_;
goto v___jp_6618_;
}
else
{
if (v___y_6636_ == 0)
{
v___y_6628_ = v___y_6635_;
v___y_6629_ = v___y_6638_;
v___y_6630_ = v___y_6634_;
v___y_6631_ = v___y_6637_;
goto v___jp_6627_;
}
else
{
if (v___y_6638_ == 0)
{
v___y_6619_ = v___y_6635_;
goto v___jp_6618_;
}
else
{
v___y_6628_ = v___y_6635_;
v___y_6629_ = v___y_6638_;
v___y_6630_ = v___y_6634_;
v___y_6631_ = v___y_6637_;
goto v___jp_6627_;
}
}
}
}
v___jp_6639_:
{
uint64_t v_diff_6641_; uint64_t v___x_6642_; uint8_t v_aNeg_6643_; uint8_t v_bNeg_6644_; uint8_t v_dNeg_6645_;
v_diff_6641_ = lean_uint64_sub(v___y_6640_, v_y0_6563_);
v___x_6642_ = 9223372036854775808ULL;
v_aNeg_6643_ = lean_uint64_dec_le(v___x_6642_, v___y_6640_);
v_bNeg_6644_ = lean_uint64_dec_le(v___x_6642_, v_y0_6563_);
v_dNeg_6645_ = lean_uint64_dec_le(v___x_6642_, v_diff_6641_);
if (v_aNeg_6643_ == 0)
{
if (v_bNeg_6644_ == 0)
{
v___y_6633_ = v_aNeg_6643_;
v___y_6634_ = v___x_6642_;
v___y_6635_ = v_diff_6641_;
v___y_6636_ = v_bNeg_6644_;
v___y_6637_ = v_dNeg_6645_;
v___y_6638_ = v_bNeg_6644_;
goto v___jp_6632_;
}
else
{
if (v_dNeg_6645_ == 0)
{
v___y_6633_ = v_aNeg_6643_;
v___y_6634_ = v___x_6642_;
v___y_6635_ = v_diff_6641_;
v___y_6636_ = v_bNeg_6644_;
v___y_6637_ = v_dNeg_6645_;
v___y_6638_ = v_dNeg_6645_;
goto v___jp_6632_;
}
else
{
uint64_t v___x_6646_;
v___x_6646_ = 9223372036854775807ULL;
v___y_6619_ = v___x_6646_;
goto v___jp_6618_;
}
}
}
else
{
uint8_t v___x_6647_;
v___x_6647_ = 0;
v___y_6633_ = v_aNeg_6643_;
v___y_6634_ = v___x_6642_;
v___y_6635_ = v_diff_6641_;
v___y_6636_ = v_bNeg_6644_;
v___y_6637_ = v_dNeg_6645_;
v___y_6638_ = v___x_6647_;
goto v___jp_6632_;
}
}
v___jp_6653_:
{
if (v_dNeg_6652_ == 0)
{
v___y_6640_ = v___x_6649_;
goto v___jp_6639_;
}
else
{
if (v___y_6654_ == 0)
{
v___y_6640_ = v_diff_6648_;
goto v___jp_6639_;
}
else
{
v___y_6640_ = v___x_6649_;
goto v___jp_6639_;
}
}
}
v___jp_6655_:
{
if (v_aNeg_6650_ == 0)
{
v___y_6640_ = v_diff_6648_;
goto v___jp_6639_;
}
else
{
if (v_bNeg_6651_ == 0)
{
v___y_6654_ = v___y_6656_;
goto v___jp_6653_;
}
else
{
if (v___y_6656_ == 0)
{
v___y_6640_ = v_diff_6648_;
goto v___jp_6639_;
}
else
{
v___y_6654_ = v___y_6656_;
goto v___jp_6653_;
}
}
}
}
}
}

LEAN_EXPORT uint64_t orb_scroll_policy_step(uint8_t v_opKind_7090_, uint8_t v_pinned_7091_, uint8_t v_intent_7092_, uint8_t v_resized_7093_, uint64_t v_curTop_7094_, uint64_t v_height_7095_, uint64_t v_client_7096_, uint64_t v_arg_7097_){
_start:
{
uint64_t v___y_7099_; uint32_t v___y_7100_; uint8_t v___y_7110_; uint64_t v___y_7111_; uint8_t v___y_7115_; uint64_t v___y_7116_; uint64_t v___y_7117_; uint8_t v___y_7122_; uint64_t v___y_7123_; uint64_t v___y_7124_; uint8_t v___y_7130_; uint64_t v___y_7131_; uint64_t v___y_7132_; uint64_t v___y_7137_; uint64_t v___y_7138_; uint8_t v___y_7139_; uint8_t v___y_7140_; uint8_t v___y_7141_; uint64_t v___y_7142_; uint64_t v___y_7144_; uint8_t v___y_7145_; uint8_t v___y_7146_; uint64_t v___y_7147_; uint8_t v___y_7148_; uint8_t v___y_7149_; uint64_t v___y_7150_; uint8_t v___y_7151_; uint8_t v___y_7153_; uint8_t v___y_7154_; uint64_t v___y_7163_; uint8_t v___y_7164_; uint64_t v___y_7165_; uint64_t v___y_7170_; uint8_t v___y_7171_; uint64_t v___y_7172_; uint8_t v___y_7173_; uint8_t v___y_7174_; uint64_t v___y_7175_; uint64_t v___y_7177_; uint64_t v___y_7178_; uint8_t v___y_7179_; uint8_t v___y_7180_; uint8_t v___y_7181_; uint64_t v___y_7182_; uint8_t v___y_7183_; uint8_t v___y_7184_; uint8_t v___y_7186_; uint64_t v___y_7187_; uint64_t v___y_7188_; uint8_t v___y_7193_; uint64_t v___y_7194_; uint64_t v___y_7195_; uint64_t v___y_7196_; uint8_t v___y_7202_; uint64_t v___y_7203_; uint64_t v___y_7204_; uint64_t v___y_7205_; uint8_t v___y_7210_; uint64_t v___y_7211_; uint8_t v___y_7212_; uint64_t v___y_7213_; uint8_t v___y_7214_; uint64_t v___y_7215_; uint64_t v___y_7216_; uint64_t v___y_7218_; uint8_t v___y_7219_; uint8_t v___y_7220_; uint8_t v___y_7221_; uint64_t v___y_7222_; uint8_t v___y_7223_; uint64_t v___y_7224_; uint64_t v___y_7225_; uint8_t v___y_7226_; uint8_t v___y_7228_; uint8_t v___y_7229_; uint64_t v___y_7230_; uint8_t v___y_7239_; uint8_t v___y_7240_; uint8_t v___y_7241_; uint8_t v___y_7242_; uint64_t v___y_7243_; uint64_t v___y_7244_; uint8_t v___y_7245_; uint8_t v___y_7246_; uint8_t v___y_7248_; uint64_t v___y_7249_; uint64_t v___y_7250_; uint64_t v___y_7255_; uint64_t v___y_7256_; uint8_t v___y_7257_; uint8_t v___y_7258_; uint8_t v___y_7259_; uint64_t v___y_7260_; uint64_t v___y_7262_; uint64_t v___y_7263_; uint8_t v___y_7264_; uint8_t v___y_7265_; uint8_t v___y_7266_; uint64_t v___y_7267_; uint8_t v___y_7268_; uint8_t v___y_7269_; uint8_t v___y_7271_; uint8_t v___y_7272_; uint8_t v___y_7302_; uint8_t v___y_7303_; uint8_t v___y_7304_; uint64_t v___y_7305_; uint8_t v___y_7311_; uint8_t v___y_7312_; uint8_t v___y_7313_; uint64_t v___y_7314_; uint8_t v___y_7320_; uint64_t v___y_7321_; uint8_t v___y_7322_; uint8_t v___y_7323_; uint8_t v___y_7324_; uint8_t v___y_7325_; uint64_t v___y_7326_; uint64_t v___y_7328_; uint8_t v___y_7329_; uint8_t v___y_7330_; uint8_t v___y_7331_; uint8_t v___y_7332_; uint8_t v___y_7333_; uint8_t v___y_7334_; uint64_t v___y_7335_; uint8_t v___y_7336_; uint8_t v___y_7338_; uint8_t v___y_7339_; uint8_t v___y_7340_; uint64_t v___y_7341_; uint8_t v___y_7349_; uint8_t v___y_7350_; uint8_t v___y_7351_; uint64_t v___y_7352_; uint8_t v___y_7353_; uint8_t v___y_7354_; uint64_t v___y_7355_; uint8_t v___y_7357_; uint8_t v___y_7358_; uint8_t v___y_7359_; uint8_t v___y_7360_; uint8_t v___y_7361_; uint64_t v___y_7362_; uint8_t v___y_7363_; uint64_t v___y_7364_; uint8_t v___y_7365_; uint8_t v___y_7367_; uint8_t v___y_7368_; uint8_t v___y_7369_; uint64_t v___y_7370_; uint8_t v___y_7371_; uint8_t v___y_7382_; uint8_t v___y_7383_; uint8_t v___y_7384_; uint64_t v___y_7385_; uint8_t v___y_7386_; uint8_t v___y_7388_; uint8_t v___y_7389_; uint8_t v___y_7390_; uint8_t v___y_7391_; uint8_t v___y_7392_; uint64_t v___y_7393_; uint64_t v___y_7396_; uint8_t v___y_7397_; uint8_t v___y_7398_; uint8_t v___y_7399_; uint8_t v___y_7400_; uint8_t v___y_7401_; uint64_t v___y_7402_; uint64_t v___y_7407_; uint8_t v___y_7408_; uint8_t v___y_7409_; uint8_t v___y_7410_; uint8_t v___y_7411_; uint8_t v___y_7412_; uint64_t v___y_7413_; uint64_t v___y_7419_; uint8_t v___y_7420_; uint8_t v___y_7421_; uint8_t v___y_7422_; uint8_t v___y_7423_; uint8_t v___y_7424_; uint64_t v___y_7425_; uint64_t v___y_7430_; uint64_t v___y_7431_; uint8_t v___y_7432_; uint8_t v___y_7433_; uint8_t v___y_7434_; uint8_t v___y_7435_; uint8_t v___y_7436_; uint8_t v___y_7437_; uint8_t v___y_7438_; uint64_t v___y_7439_; uint64_t v___y_7441_; uint64_t v___y_7442_; uint8_t v___y_7443_; uint8_t v___y_7444_; uint8_t v___y_7445_; uint8_t v___y_7446_; uint8_t v___y_7447_; uint8_t v___y_7448_; uint8_t v___y_7449_; uint8_t v___y_7450_; uint64_t v___y_7451_; uint8_t v___y_7452_; uint8_t v___y_7454_; uint8_t v___y_7455_; uint8_t v___y_7456_; uint8_t v___y_7457_; uint8_t v___y_7458_; uint64_t v___y_7469_; uint8_t v___y_7470_; uint8_t v___y_7471_; uint8_t v___y_7472_; uint64_t v___y_7473_; uint8_t v___y_7474_; uint8_t v___y_7475_; uint64_t v___y_7477_; uint8_t v___y_7478_; uint8_t v___y_7479_; uint8_t v___y_7480_; uint8_t v___y_7481_; uint64_t v___y_7482_; uint8_t v___y_7483_; uint8_t v___y_7484_; uint8_t v___y_7485_; uint8_t v___y_7487_; uint8_t v___y_7488_; uint8_t v___y_7489_; uint64_t v___y_7490_; uint8_t v___y_7491_; uint64_t v___y_7492_; uint8_t v___y_7499_; uint64_t v___y_7500_; uint8_t v___y_7501_; uint8_t v___y_7502_; uint8_t v___y_7503_; uint8_t v___y_7504_; uint64_t v___y_7505_; uint8_t v___y_7506_; uint8_t v___y_7508_; uint8_t v___y_7509_; uint64_t v___y_7510_; uint8_t v___y_7511_; uint8_t v___y_7512_; uint8_t v___y_7513_; uint8_t v___y_7514_; uint64_t v___y_7515_; uint8_t v___y_7516_; uint8_t v___y_7517_; uint8_t v___y_7519_; uint8_t v___y_7520_; uint8_t v___y_7521_; uint8_t v___y_7522_; uint64_t v___y_7523_; uint8_t v___y_7534_; uint8_t v___y_7535_; uint64_t v___y_7536_; uint8_t v___y_7537_; uint8_t v___y_7538_; uint64_t v___y_7539_; uint8_t v___y_7544_; uint64_t v___y_7545_; uint8_t v___y_7546_; uint8_t v___y_7547_; uint8_t v___y_7548_; uint64_t v___y_7549_; uint8_t v___y_7555_; uint8_t v___y_7556_; uint64_t v___y_7557_; uint8_t v___y_7558_; uint8_t v___y_7559_; uint64_t v___y_7560_; uint64_t v___y_7565_; uint8_t v___y_7566_; uint64_t v___y_7567_; uint8_t v___y_7568_; uint8_t v___y_7569_; uint64_t v___y_7570_; uint8_t v___y_7571_; uint8_t v___y_7572_; uint8_t v___y_7573_; uint64_t v___y_7575_; uint8_t v___y_7576_; uint8_t v___y_7577_; uint64_t v___y_7578_; uint8_t v___y_7579_; uint64_t v___y_7580_; uint8_t v___y_7581_; uint8_t v___y_7582_; uint8_t v___y_7583_; uint8_t v___y_7584_; uint8_t v___y_7585_; uint8_t v___y_7587_; uint8_t v___y_7588_; uint8_t v___y_7589_; uint8_t v___y_7590_; uint32_t v___y_7599_; uint32_t v___y_7600_; uint8_t v___y_7601_; uint32_t v___y_7628_; uint32_t v___y_7629_; uint32_t v___y_7635_; uint32_t v___y_7636_; uint32_t v___y_7642_; uint32_t v___y_7643_; uint32_t v___y_7649_; uint32_t v___y_7650_; uint32_t v___y_7656_; uint64_t v___y_7657_; uint32_t v___y_7663_; uint8_t v___x_7668_; uint8_t v___x_7669_;
v___x_7668_ = 1;
v___x_7669_ = lean_uint8_dec_eq(v_pinned_7091_, v___x_7668_);
if (v___x_7669_ == 0)
{
uint32_t v___x_7670_;
v___x_7670_ = 0;
v___y_7663_ = v___x_7670_;
goto v___jp_7662_;
}
else
{
uint32_t v___x_7671_;
v___x_7671_ = 512;
v___y_7663_ = v___x_7671_;
goto v___jp_7662_;
}
v___jp_7098_:
{
uint32_t v___x_7101_; uint32_t v_lo32_7102_; uint32_t v_hi32_7103_; uint64_t v___x_7104_; uint64_t v___x_7105_; uint64_t v___x_7106_; uint64_t v___x_7107_; uint64_t v___x_7108_;
v___x_7101_ = 257;
v_lo32_7102_ = lean_uint32_lor(v___x_7101_, v___y_7100_);
v_hi32_7103_ = lean_uint64_to_uint32(v___y_7099_);
v___x_7104_ = lean_uint32_to_uint64(v_lo32_7102_);
v___x_7105_ = lean_uint32_to_uint64(v_hi32_7103_);
v___x_7106_ = 32ULL;
v___x_7107_ = lean_uint64_shift_left(v___x_7105_, v___x_7106_);
v___x_7108_ = lean_uint64_lor(v___x_7104_, v___x_7107_);
return v___x_7108_;
}
v___jp_7109_:
{
if (v___y_7110_ == 0)
{
uint32_t v___x_7112_;
v___x_7112_ = 0;
v___y_7099_ = v___y_7111_;
v___y_7100_ = v___x_7112_;
goto v___jp_7098_;
}
else
{
uint32_t v___x_7113_;
v___x_7113_ = 512;
v___y_7099_ = v___y_7111_;
v___y_7100_ = v___x_7113_;
goto v___jp_7098_;
}
}
v___jp_7114_:
{
uint64_t v___x_7118_; uint64_t v___x_7119_; uint8_t v___x_7120_;
v___x_7118_ = 9223372036854775808ULL;
v___x_7119_ = lean_uint64_add(v___y_7117_, v___x_7118_);
v___x_7120_ = lean_uint64_dec_lt(v___x_7118_, v___x_7119_);
if (v___x_7120_ == 0)
{
v___y_7110_ = v___y_7115_;
v___y_7111_ = v___y_7116_;
goto v___jp_7109_;
}
else
{
v___y_7110_ = v___y_7115_;
v___y_7111_ = v___y_7117_;
goto v___jp_7109_;
}
}
v___jp_7121_:
{
uint64_t v___x_7125_; uint64_t v___x_7126_; uint64_t v___x_7127_; uint8_t v___x_7128_;
v___x_7125_ = 9223372036854775808ULL;
v___x_7126_ = lean_uint64_add(v_arg_7097_, v___x_7125_);
v___x_7127_ = lean_uint64_add(v___y_7124_, v___x_7125_);
v___x_7128_ = lean_uint64_dec_le(v___x_7126_, v___x_7127_);
if (v___x_7128_ == 0)
{
v___y_7115_ = v___y_7122_;
v___y_7116_ = v___y_7123_;
v___y_7117_ = v___y_7124_;
goto v___jp_7114_;
}
else
{
v___y_7115_ = v___y_7122_;
v___y_7116_ = v___y_7123_;
v___y_7117_ = v_arg_7097_;
goto v___jp_7114_;
}
}
v___jp_7129_:
{
uint64_t v___x_7133_; uint64_t v___x_7134_; uint8_t v___x_7135_;
v___x_7133_ = 9223372036854775808ULL;
v___x_7134_ = lean_uint64_add(v___y_7132_, v___x_7133_);
v___x_7135_ = lean_uint64_dec_lt(v___x_7133_, v___x_7134_);
if (v___x_7135_ == 0)
{
v___y_7122_ = v___y_7130_;
v___y_7123_ = v___y_7131_;
v___y_7124_ = v___y_7131_;
goto v___jp_7121_;
}
else
{
v___y_7122_ = v___y_7130_;
v___y_7123_ = v___y_7131_;
v___y_7124_ = v___y_7132_;
goto v___jp_7121_;
}
}
v___jp_7136_:
{
if (v___y_7140_ == 0)
{
v___y_7130_ = v___y_7139_;
v___y_7131_ = v___y_7142_;
v___y_7132_ = v___y_7137_;
goto v___jp_7129_;
}
else
{
if (v___y_7141_ == 0)
{
v___y_7130_ = v___y_7139_;
v___y_7131_ = v___y_7142_;
v___y_7132_ = v___y_7138_;
goto v___jp_7129_;
}
else
{
v___y_7130_ = v___y_7139_;
v___y_7131_ = v___y_7142_;
v___y_7132_ = v___y_7137_;
goto v___jp_7129_;
}
}
}
v___jp_7143_:
{
if (v___y_7145_ == 0)
{
v___y_7130_ = v___y_7146_;
v___y_7131_ = v___y_7150_;
v___y_7132_ = v___y_7147_;
goto v___jp_7129_;
}
else
{
if (v___y_7149_ == 0)
{
v___y_7137_ = v___y_7144_;
v___y_7138_ = v___y_7147_;
v___y_7139_ = v___y_7146_;
v___y_7140_ = v___y_7148_;
v___y_7141_ = v___y_7151_;
v___y_7142_ = v___y_7150_;
goto v___jp_7136_;
}
else
{
if (v___y_7151_ == 0)
{
v___y_7130_ = v___y_7146_;
v___y_7131_ = v___y_7150_;
v___y_7132_ = v___y_7147_;
goto v___jp_7129_;
}
else
{
v___y_7137_ = v___y_7144_;
v___y_7138_ = v___y_7147_;
v___y_7139_ = v___y_7146_;
v___y_7140_ = v___y_7148_;
v___y_7141_ = v___y_7151_;
v___y_7142_ = v___y_7150_;
goto v___jp_7136_;
}
}
}
}
v___jp_7152_:
{
uint64_t v___x_7155_; uint64_t v_diff_7156_; uint64_t v___x_7157_; uint8_t v_aNeg_7158_; uint8_t v_bNeg_7159_; uint8_t v_dNeg_7160_;
v___x_7155_ = 0ULL;
v_diff_7156_ = lean_uint64_sub(v_height_7095_, v_client_7096_);
v___x_7157_ = 9223372036854775808ULL;
v_aNeg_7158_ = lean_uint64_dec_le(v___x_7157_, v_height_7095_);
v_bNeg_7159_ = lean_uint64_dec_le(v___x_7157_, v_client_7096_);
v_dNeg_7160_ = lean_uint64_dec_le(v___x_7157_, v_diff_7156_);
if (v_aNeg_7158_ == 0)
{
if (v_bNeg_7159_ == 0)
{
v___y_7144_ = v___x_7157_;
v___y_7145_ = v_aNeg_7158_;
v___y_7146_ = v___y_7154_;
v___y_7147_ = v_diff_7156_;
v___y_7148_ = v_dNeg_7160_;
v___y_7149_ = v_bNeg_7159_;
v___y_7150_ = v___x_7155_;
v___y_7151_ = v_bNeg_7159_;
goto v___jp_7143_;
}
else
{
if (v_dNeg_7160_ == 0)
{
v___y_7144_ = v___x_7157_;
v___y_7145_ = v_aNeg_7158_;
v___y_7146_ = v___y_7154_;
v___y_7147_ = v_diff_7156_;
v___y_7148_ = v_dNeg_7160_;
v___y_7149_ = v_bNeg_7159_;
v___y_7150_ = v___x_7155_;
v___y_7151_ = v_dNeg_7160_;
goto v___jp_7143_;
}
else
{
uint64_t v___x_7161_;
v___x_7161_ = 9223372036854775807ULL;
v___y_7130_ = v___y_7154_;
v___y_7131_ = v___x_7155_;
v___y_7132_ = v___x_7161_;
goto v___jp_7129_;
}
}
}
else
{
v___y_7144_ = v___x_7157_;
v___y_7145_ = v_aNeg_7158_;
v___y_7146_ = v___y_7154_;
v___y_7147_ = v_diff_7156_;
v___y_7148_ = v_dNeg_7160_;
v___y_7149_ = v_bNeg_7159_;
v___y_7150_ = v___x_7155_;
v___y_7151_ = v___y_7153_;
goto v___jp_7143_;
}
}
v___jp_7162_:
{
uint64_t v___x_7166_; uint64_t v___x_7167_; uint8_t v___x_7168_;
v___x_7166_ = 9223372036854775808ULL;
v___x_7167_ = lean_uint64_add(v___y_7165_, v___x_7166_);
v___x_7168_ = lean_uint64_dec_lt(v___x_7166_, v___x_7167_);
if (v___x_7168_ == 0)
{
v___y_7110_ = v___y_7164_;
v___y_7111_ = v___y_7163_;
goto v___jp_7109_;
}
else
{
v___y_7110_ = v___y_7164_;
v___y_7111_ = v___y_7165_;
goto v___jp_7109_;
}
}
v___jp_7169_:
{
if (v___y_7173_ == 0)
{
v___y_7163_ = v___y_7170_;
v___y_7164_ = v___y_7174_;
v___y_7165_ = v___y_7175_;
goto v___jp_7162_;
}
else
{
if (v___y_7171_ == 0)
{
v___y_7163_ = v___y_7170_;
v___y_7164_ = v___y_7174_;
v___y_7165_ = v___y_7172_;
goto v___jp_7162_;
}
else
{
v___y_7163_ = v___y_7170_;
v___y_7164_ = v___y_7174_;
v___y_7165_ = v___y_7175_;
goto v___jp_7162_;
}
}
}
v___jp_7176_:
{
if (v___y_7179_ == 0)
{
v___y_7163_ = v___y_7177_;
v___y_7164_ = v___y_7181_;
v___y_7165_ = v___y_7178_;
goto v___jp_7162_;
}
else
{
if (v___y_7183_ == 0)
{
v___y_7170_ = v___y_7177_;
v___y_7171_ = v___y_7184_;
v___y_7172_ = v___y_7178_;
v___y_7173_ = v___y_7180_;
v___y_7174_ = v___y_7181_;
v___y_7175_ = v___y_7182_;
goto v___jp_7169_;
}
else
{
if (v___y_7184_ == 0)
{
v___y_7163_ = v___y_7177_;
v___y_7164_ = v___y_7181_;
v___y_7165_ = v___y_7178_;
goto v___jp_7162_;
}
else
{
v___y_7170_ = v___y_7177_;
v___y_7171_ = v___y_7184_;
v___y_7172_ = v___y_7178_;
v___y_7173_ = v___y_7180_;
v___y_7174_ = v___y_7181_;
v___y_7175_ = v___y_7182_;
goto v___jp_7169_;
}
}
}
}
v___jp_7185_:
{
uint64_t v___x_7189_; uint64_t v___x_7190_; uint8_t v___x_7191_;
v___x_7189_ = 9223372036854775808ULL;
v___x_7190_ = lean_uint64_add(v___y_7188_, v___x_7189_);
v___x_7191_ = lean_uint64_dec_lt(v___x_7189_, v___x_7190_);
if (v___x_7191_ == 0)
{
v___y_7110_ = v___y_7186_;
v___y_7111_ = v___y_7187_;
goto v___jp_7109_;
}
else
{
v___y_7110_ = v___y_7186_;
v___y_7111_ = v___y_7188_;
goto v___jp_7109_;
}
}
v___jp_7192_:
{
uint64_t v___x_7197_; uint64_t v___x_7198_; uint64_t v___x_7199_; uint8_t v___x_7200_;
v___x_7197_ = 9223372036854775808ULL;
v___x_7198_ = lean_uint64_add(v___y_7195_, v___x_7197_);
v___x_7199_ = lean_uint64_add(v___y_7196_, v___x_7197_);
v___x_7200_ = lean_uint64_dec_le(v___x_7198_, v___x_7199_);
if (v___x_7200_ == 0)
{
v___y_7186_ = v___y_7193_;
v___y_7187_ = v___y_7194_;
v___y_7188_ = v___y_7196_;
goto v___jp_7185_;
}
else
{
v___y_7186_ = v___y_7193_;
v___y_7187_ = v___y_7194_;
v___y_7188_ = v___y_7195_;
goto v___jp_7185_;
}
}
v___jp_7201_:
{
uint64_t v___x_7206_; uint64_t v___x_7207_; uint8_t v___x_7208_;
v___x_7206_ = 9223372036854775808ULL;
v___x_7207_ = lean_uint64_add(v___y_7205_, v___x_7206_);
v___x_7208_ = lean_uint64_dec_lt(v___x_7206_, v___x_7207_);
if (v___x_7208_ == 0)
{
v___y_7193_ = v___y_7202_;
v___y_7194_ = v___y_7204_;
v___y_7195_ = v___y_7203_;
v___y_7196_ = v___y_7204_;
goto v___jp_7192_;
}
else
{
v___y_7193_ = v___y_7202_;
v___y_7194_ = v___y_7204_;
v___y_7195_ = v___y_7203_;
v___y_7196_ = v___y_7205_;
goto v___jp_7192_;
}
}
v___jp_7209_:
{
if (v___y_7214_ == 0)
{
v___y_7202_ = v___y_7212_;
v___y_7203_ = v___y_7216_;
v___y_7204_ = v___y_7215_;
v___y_7205_ = v___y_7213_;
goto v___jp_7201_;
}
else
{
if (v___y_7210_ == 0)
{
v___y_7202_ = v___y_7212_;
v___y_7203_ = v___y_7216_;
v___y_7204_ = v___y_7215_;
v___y_7205_ = v___y_7211_;
goto v___jp_7201_;
}
else
{
v___y_7202_ = v___y_7212_;
v___y_7203_ = v___y_7216_;
v___y_7204_ = v___y_7215_;
v___y_7205_ = v___y_7213_;
goto v___jp_7201_;
}
}
}
v___jp_7217_:
{
if (v___y_7221_ == 0)
{
v___y_7202_ = v___y_7219_;
v___y_7203_ = v___y_7224_;
v___y_7204_ = v___y_7225_;
v___y_7205_ = v___y_7218_;
goto v___jp_7201_;
}
else
{
if (v___y_7220_ == 0)
{
v___y_7210_ = v___y_7226_;
v___y_7211_ = v___y_7218_;
v___y_7212_ = v___y_7219_;
v___y_7213_ = v___y_7222_;
v___y_7214_ = v___y_7223_;
v___y_7215_ = v___y_7225_;
v___y_7216_ = v___y_7224_;
goto v___jp_7209_;
}
else
{
if (v___y_7226_ == 0)
{
v___y_7202_ = v___y_7219_;
v___y_7203_ = v___y_7224_;
v___y_7204_ = v___y_7225_;
v___y_7205_ = v___y_7218_;
goto v___jp_7201_;
}
else
{
v___y_7210_ = v___y_7226_;
v___y_7211_ = v___y_7218_;
v___y_7212_ = v___y_7219_;
v___y_7213_ = v___y_7222_;
v___y_7214_ = v___y_7223_;
v___y_7215_ = v___y_7225_;
v___y_7216_ = v___y_7224_;
goto v___jp_7209_;
}
}
}
}
v___jp_7227_:
{
uint64_t v___x_7231_; uint64_t v_diff_7232_; uint64_t v___x_7233_; uint8_t v_aNeg_7234_; uint8_t v_bNeg_7235_; uint8_t v_dNeg_7236_;
v___x_7231_ = 0ULL;
v_diff_7232_ = lean_uint64_sub(v_height_7095_, v_client_7096_);
v___x_7233_ = 9223372036854775808ULL;
v_aNeg_7234_ = lean_uint64_dec_le(v___x_7233_, v_height_7095_);
v_bNeg_7235_ = lean_uint64_dec_le(v___x_7233_, v_client_7096_);
v_dNeg_7236_ = lean_uint64_dec_le(v___x_7233_, v_diff_7232_);
if (v_aNeg_7234_ == 0)
{
if (v_bNeg_7235_ == 0)
{
v___y_7218_ = v_diff_7232_;
v___y_7219_ = v___y_7229_;
v___y_7220_ = v_bNeg_7235_;
v___y_7221_ = v_aNeg_7234_;
v___y_7222_ = v___x_7233_;
v___y_7223_ = v_dNeg_7236_;
v___y_7224_ = v___y_7230_;
v___y_7225_ = v___x_7231_;
v___y_7226_ = v_bNeg_7235_;
goto v___jp_7217_;
}
else
{
if (v_dNeg_7236_ == 0)
{
v___y_7218_ = v_diff_7232_;
v___y_7219_ = v___y_7229_;
v___y_7220_ = v_bNeg_7235_;
v___y_7221_ = v_aNeg_7234_;
v___y_7222_ = v___x_7233_;
v___y_7223_ = v_dNeg_7236_;
v___y_7224_ = v___y_7230_;
v___y_7225_ = v___x_7231_;
v___y_7226_ = v_dNeg_7236_;
goto v___jp_7217_;
}
else
{
uint64_t v___x_7237_;
v___x_7237_ = 9223372036854775807ULL;
v___y_7202_ = v___y_7229_;
v___y_7203_ = v___y_7230_;
v___y_7204_ = v___x_7231_;
v___y_7205_ = v___x_7237_;
goto v___jp_7201_;
}
}
}
else
{
v___y_7218_ = v_diff_7232_;
v___y_7219_ = v___y_7229_;
v___y_7220_ = v_bNeg_7235_;
v___y_7221_ = v_aNeg_7234_;
v___y_7222_ = v___x_7233_;
v___y_7223_ = v_dNeg_7236_;
v___y_7224_ = v___y_7230_;
v___y_7225_ = v___x_7231_;
v___y_7226_ = v___y_7228_;
goto v___jp_7217_;
}
}
v___jp_7238_:
{
if (v___y_7241_ == 0)
{
v___y_7228_ = v___y_7240_;
v___y_7229_ = v___y_7242_;
v___y_7230_ = v___y_7243_;
goto v___jp_7227_;
}
else
{
if (v___y_7245_ == 0)
{
v___y_7228_ = v___y_7240_;
v___y_7229_ = v___y_7242_;
v___y_7230_ = v___y_7243_;
goto v___jp_7227_;
}
else
{
if (v___y_7239_ == 0)
{
v___y_7228_ = v___y_7240_;
v___y_7229_ = v___y_7242_;
v___y_7230_ = v___y_7244_;
goto v___jp_7227_;
}
else
{
if (v___y_7246_ == 0)
{
v___y_7228_ = v___y_7240_;
v___y_7229_ = v___y_7242_;
v___y_7230_ = v___y_7243_;
goto v___jp_7227_;
}
else
{
v___y_7228_ = v___y_7240_;
v___y_7229_ = v___y_7242_;
v___y_7230_ = v___y_7244_;
goto v___jp_7227_;
}
}
}
}
}
v___jp_7247_:
{
uint64_t v___x_7251_; uint64_t v___x_7252_; uint8_t v___x_7253_;
v___x_7251_ = 9223372036854775808ULL;
v___x_7252_ = lean_uint64_add(v___y_7250_, v___x_7251_);
v___x_7253_ = lean_uint64_dec_lt(v___x_7251_, v___x_7252_);
if (v___x_7253_ == 0)
{
v___y_7110_ = v___y_7248_;
v___y_7111_ = v___y_7249_;
goto v___jp_7109_;
}
else
{
v___y_7110_ = v___y_7248_;
v___y_7111_ = v___y_7250_;
goto v___jp_7109_;
}
}
v___jp_7254_:
{
if (v___y_7259_ == 0)
{
v___y_7248_ = v___y_7258_;
v___y_7249_ = v___y_7260_;
v___y_7250_ = v___y_7256_;
goto v___jp_7247_;
}
else
{
if (v___y_7257_ == 0)
{
v___y_7248_ = v___y_7258_;
v___y_7249_ = v___y_7260_;
v___y_7250_ = v___y_7255_;
goto v___jp_7247_;
}
else
{
v___y_7248_ = v___y_7258_;
v___y_7249_ = v___y_7260_;
v___y_7250_ = v___y_7256_;
goto v___jp_7247_;
}
}
}
v___jp_7261_:
{
if (v___y_7268_ == 0)
{
v___y_7248_ = v___y_7266_;
v___y_7249_ = v___y_7267_;
v___y_7250_ = v___y_7263_;
goto v___jp_7247_;
}
else
{
if (v___y_7264_ == 0)
{
v___y_7255_ = v___y_7263_;
v___y_7256_ = v___y_7262_;
v___y_7257_ = v___y_7269_;
v___y_7258_ = v___y_7266_;
v___y_7259_ = v___y_7265_;
v___y_7260_ = v___y_7267_;
goto v___jp_7254_;
}
else
{
if (v___y_7269_ == 0)
{
v___y_7248_ = v___y_7266_;
v___y_7249_ = v___y_7267_;
v___y_7250_ = v___y_7263_;
goto v___jp_7247_;
}
else
{
v___y_7255_ = v___y_7263_;
v___y_7256_ = v___y_7262_;
v___y_7257_ = v___y_7269_;
v___y_7258_ = v___y_7266_;
v___y_7259_ = v___y_7265_;
v___y_7260_ = v___y_7267_;
goto v___jp_7254_;
}
}
}
}
v___jp_7270_:
{
uint8_t v___x_7273_; uint8_t v___x_7274_;
v___x_7273_ = 0;
v___x_7274_ = lean_uint8_dec_eq(v_opKind_7090_, v___x_7273_);
if (v___x_7274_ == 0)
{
uint8_t v___x_7275_; uint8_t v___x_7276_;
v___x_7275_ = 1;
v___x_7276_ = lean_uint8_dec_eq(v_opKind_7090_, v___x_7275_);
if (v___x_7276_ == 0)
{
uint8_t v___x_7277_; uint8_t v___x_7278_;
v___x_7277_ = 2;
v___x_7278_ = lean_uint8_dec_eq(v_opKind_7090_, v___x_7277_);
if (v___x_7278_ == 0)
{
uint64_t v___x_7279_; uint64_t v_diff_7280_; uint64_t v___x_7281_; uint8_t v_aNeg_7282_; uint8_t v_bNeg_7283_; uint8_t v_dNeg_7284_;
v___x_7279_ = 0ULL;
v_diff_7280_ = lean_uint64_sub(v_height_7095_, v_client_7096_);
v___x_7281_ = 9223372036854775808ULL;
v_aNeg_7282_ = lean_uint64_dec_le(v___x_7281_, v_height_7095_);
v_bNeg_7283_ = lean_uint64_dec_le(v___x_7281_, v_client_7096_);
v_dNeg_7284_ = lean_uint64_dec_le(v___x_7281_, v_diff_7280_);
if (v_aNeg_7282_ == 0)
{
if (v_bNeg_7283_ == 0)
{
v___y_7177_ = v___x_7279_;
v___y_7178_ = v_diff_7280_;
v___y_7179_ = v_aNeg_7282_;
v___y_7180_ = v_dNeg_7284_;
v___y_7181_ = v___y_7272_;
v___y_7182_ = v___x_7281_;
v___y_7183_ = v_bNeg_7283_;
v___y_7184_ = v_bNeg_7283_;
goto v___jp_7176_;
}
else
{
if (v_dNeg_7284_ == 0)
{
v___y_7177_ = v___x_7279_;
v___y_7178_ = v_diff_7280_;
v___y_7179_ = v_aNeg_7282_;
v___y_7180_ = v_dNeg_7284_;
v___y_7181_ = v___y_7272_;
v___y_7182_ = v___x_7281_;
v___y_7183_ = v_bNeg_7283_;
v___y_7184_ = v_dNeg_7284_;
goto v___jp_7176_;
}
else
{
uint64_t v___x_7285_;
v___x_7285_ = 9223372036854775807ULL;
v___y_7163_ = v___x_7279_;
v___y_7164_ = v___y_7272_;
v___y_7165_ = v___x_7285_;
goto v___jp_7162_;
}
}
}
else
{
v___y_7177_ = v___x_7279_;
v___y_7178_ = v_diff_7280_;
v___y_7179_ = v_aNeg_7282_;
v___y_7180_ = v_dNeg_7284_;
v___y_7181_ = v___y_7272_;
v___y_7182_ = v___x_7281_;
v___y_7183_ = v_bNeg_7283_;
v___y_7184_ = v___x_7278_;
goto v___jp_7176_;
}
}
else
{
v___y_7153_ = v___x_7274_;
v___y_7154_ = v___y_7272_;
goto v___jp_7152_;
}
}
else
{
v___y_7153_ = v___x_7274_;
v___y_7154_ = v___y_7272_;
goto v___jp_7152_;
}
}
else
{
uint8_t v___x_7286_; uint8_t v___x_7287_;
v___x_7286_ = 1;
v___x_7287_ = lean_uint8_dec_eq(v_pinned_7091_, v___x_7286_);
if (v___x_7287_ == 0)
{
uint64_t v_sum_7288_; uint64_t v___x_7289_; uint8_t v_aNeg_7290_; uint8_t v_bNeg_7291_; uint8_t v_sNeg_7292_;
v_sum_7288_ = lean_uint64_add(v_curTop_7094_, v_arg_7097_);
v___x_7289_ = 9223372036854775808ULL;
v_aNeg_7290_ = lean_uint64_dec_le(v___x_7289_, v_curTop_7094_);
v_bNeg_7291_ = lean_uint64_dec_le(v___x_7289_, v_arg_7097_);
v_sNeg_7292_ = lean_uint64_dec_le(v___x_7289_, v_sum_7288_);
if (v_aNeg_7290_ == 0)
{
if (v_bNeg_7291_ == 0)
{
if (v_sNeg_7292_ == 0)
{
v___y_7239_ = v_sNeg_7292_;
v___y_7240_ = v___x_7287_;
v___y_7241_ = v_aNeg_7290_;
v___y_7242_ = v___y_7272_;
v___y_7243_ = v_sum_7288_;
v___y_7244_ = v___x_7289_;
v___y_7245_ = v_bNeg_7291_;
v___y_7246_ = v_sNeg_7292_;
goto v___jp_7238_;
}
else
{
uint64_t v___x_7293_;
v___x_7293_ = 9223372036854775807ULL;
v___y_7228_ = v___x_7287_;
v___y_7229_ = v___y_7272_;
v___y_7230_ = v___x_7293_;
goto v___jp_7227_;
}
}
else
{
v___y_7239_ = v_sNeg_7292_;
v___y_7240_ = v___x_7287_;
v___y_7241_ = v_aNeg_7290_;
v___y_7242_ = v___y_7272_;
v___y_7243_ = v_sum_7288_;
v___y_7244_ = v___x_7289_;
v___y_7245_ = v_bNeg_7291_;
v___y_7246_ = v_aNeg_7290_;
goto v___jp_7238_;
}
}
else
{
v___y_7239_ = v_sNeg_7292_;
v___y_7240_ = v___x_7287_;
v___y_7241_ = v_aNeg_7290_;
v___y_7242_ = v___y_7272_;
v___y_7243_ = v_sum_7288_;
v___y_7244_ = v___x_7289_;
v___y_7245_ = v_bNeg_7291_;
v___y_7246_ = v___x_7287_;
goto v___jp_7238_;
}
}
else
{
uint64_t v___x_7294_; uint64_t v_diff_7295_; uint64_t v___x_7296_; uint8_t v_aNeg_7297_; uint8_t v_bNeg_7298_; uint8_t v_dNeg_7299_;
v___x_7294_ = 0ULL;
v_diff_7295_ = lean_uint64_sub(v_height_7095_, v_client_7096_);
v___x_7296_ = 9223372036854775808ULL;
v_aNeg_7297_ = lean_uint64_dec_le(v___x_7296_, v_height_7095_);
v_bNeg_7298_ = lean_uint64_dec_le(v___x_7296_, v_client_7096_);
v_dNeg_7299_ = lean_uint64_dec_le(v___x_7296_, v_diff_7295_);
if (v_aNeg_7297_ == 0)
{
if (v_bNeg_7298_ == 0)
{
v___y_7262_ = v___x_7296_;
v___y_7263_ = v_diff_7295_;
v___y_7264_ = v_bNeg_7298_;
v___y_7265_ = v_dNeg_7299_;
v___y_7266_ = v___y_7272_;
v___y_7267_ = v___x_7294_;
v___y_7268_ = v_aNeg_7297_;
v___y_7269_ = v_bNeg_7298_;
goto v___jp_7261_;
}
else
{
if (v_dNeg_7299_ == 0)
{
v___y_7262_ = v___x_7296_;
v___y_7263_ = v_diff_7295_;
v___y_7264_ = v_bNeg_7298_;
v___y_7265_ = v_dNeg_7299_;
v___y_7266_ = v___y_7272_;
v___y_7267_ = v___x_7294_;
v___y_7268_ = v_aNeg_7297_;
v___y_7269_ = v_dNeg_7299_;
goto v___jp_7261_;
}
else
{
uint64_t v___x_7300_;
v___x_7300_ = 9223372036854775807ULL;
v___y_7248_ = v___y_7272_;
v___y_7249_ = v___x_7294_;
v___y_7250_ = v___x_7300_;
goto v___jp_7247_;
}
}
}
else
{
v___y_7262_ = v___x_7296_;
v___y_7263_ = v_diff_7295_;
v___y_7264_ = v_bNeg_7298_;
v___y_7265_ = v_dNeg_7299_;
v___y_7266_ = v___y_7272_;
v___y_7267_ = v___x_7294_;
v___y_7268_ = v_aNeg_7297_;
v___y_7269_ = v___y_7271_;
goto v___jp_7261_;
}
}
}
}
v___jp_7301_:
{
uint64_t v___x_7306_; uint64_t v___x_7307_; uint64_t v___x_7308_; uint8_t v___x_7309_;
v___x_7306_ = 9223372036854775808ULL;
v___x_7307_ = lean_uint64_add(v___y_7305_, v___x_7306_);
v___x_7308_ = 9223372036854775832ULL;
v___x_7309_ = lean_uint64_dec_lt(v___x_7307_, v___x_7308_);
if (v___x_7309_ == 0)
{
v___y_7271_ = v___y_7303_;
v___y_7272_ = v___y_7302_;
goto v___jp_7270_;
}
else
{
v___y_7271_ = v___y_7303_;
v___y_7272_ = v___y_7304_;
goto v___jp_7270_;
}
}
v___jp_7310_:
{
uint64_t v___x_7315_; uint64_t v___x_7316_; uint64_t v___x_7317_; uint8_t v___x_7318_;
v___x_7315_ = 9223372036854775808ULL;
v___x_7316_ = 9223372036854775832ULL;
v___x_7317_ = lean_uint64_add(v___y_7314_, v___x_7315_);
v___x_7318_ = lean_uint64_dec_le(v___x_7316_, v___x_7317_);
if (v___x_7318_ == 0)
{
v___y_7271_ = v___y_7313_;
v___y_7272_ = v___y_7312_;
goto v___jp_7270_;
}
else
{
v___y_7271_ = v___y_7313_;
v___y_7272_ = v___y_7311_;
goto v___jp_7270_;
}
}
v___jp_7319_:
{
if (v___y_7324_ == 0)
{
v___y_7311_ = v___y_7320_;
v___y_7312_ = v___y_7322_;
v___y_7313_ = v___y_7325_;
v___y_7314_ = v___y_7321_;
goto v___jp_7310_;
}
else
{
if (v___y_7323_ == 0)
{
v___y_7311_ = v___y_7320_;
v___y_7312_ = v___y_7322_;
v___y_7313_ = v___y_7325_;
v___y_7314_ = v___y_7326_;
goto v___jp_7310_;
}
else
{
v___y_7311_ = v___y_7320_;
v___y_7312_ = v___y_7322_;
v___y_7313_ = v___y_7325_;
v___y_7314_ = v___y_7321_;
goto v___jp_7310_;
}
}
}
v___jp_7327_:
{
if (v___y_7333_ == 0)
{
v___y_7311_ = v___y_7329_;
v___y_7312_ = v___y_7330_;
v___y_7313_ = v___y_7332_;
v___y_7314_ = v___y_7335_;
goto v___jp_7310_;
}
else
{
if (v___y_7334_ == 0)
{
v___y_7320_ = v___y_7329_;
v___y_7321_ = v___y_7328_;
v___y_7322_ = v___y_7330_;
v___y_7323_ = v___y_7336_;
v___y_7324_ = v___y_7331_;
v___y_7325_ = v___y_7332_;
v___y_7326_ = v___y_7335_;
goto v___jp_7319_;
}
else
{
if (v___y_7336_ == 0)
{
v___y_7311_ = v___y_7329_;
v___y_7312_ = v___y_7330_;
v___y_7313_ = v___y_7332_;
v___y_7314_ = v___y_7335_;
goto v___jp_7310_;
}
else
{
v___y_7320_ = v___y_7329_;
v___y_7321_ = v___y_7328_;
v___y_7322_ = v___y_7330_;
v___y_7323_ = v___y_7336_;
v___y_7324_ = v___y_7331_;
v___y_7325_ = v___y_7332_;
v___y_7326_ = v___y_7335_;
goto v___jp_7319_;
}
}
}
}
v___jp_7337_:
{
uint64_t v_diff_7342_; uint64_t v___x_7343_; uint8_t v_aNeg_7344_; uint8_t v_bNeg_7345_; uint8_t v_dNeg_7346_;
v_diff_7342_ = lean_uint64_sub(v___y_7341_, v_client_7096_);
v___x_7343_ = 9223372036854775808ULL;
v_aNeg_7344_ = lean_uint64_dec_le(v___x_7343_, v___y_7341_);
v_bNeg_7345_ = lean_uint64_dec_le(v___x_7343_, v_client_7096_);
v_dNeg_7346_ = lean_uint64_dec_le(v___x_7343_, v_diff_7342_);
if (v_aNeg_7344_ == 0)
{
if (v_bNeg_7345_ == 0)
{
v___y_7328_ = v___x_7343_;
v___y_7329_ = v___y_7338_;
v___y_7330_ = v___y_7339_;
v___y_7331_ = v_dNeg_7346_;
v___y_7332_ = v___y_7340_;
v___y_7333_ = v_aNeg_7344_;
v___y_7334_ = v_bNeg_7345_;
v___y_7335_ = v_diff_7342_;
v___y_7336_ = v_bNeg_7345_;
goto v___jp_7327_;
}
else
{
if (v_dNeg_7346_ == 0)
{
v___y_7328_ = v___x_7343_;
v___y_7329_ = v___y_7338_;
v___y_7330_ = v___y_7339_;
v___y_7331_ = v_dNeg_7346_;
v___y_7332_ = v___y_7340_;
v___y_7333_ = v_aNeg_7344_;
v___y_7334_ = v_bNeg_7345_;
v___y_7335_ = v_diff_7342_;
v___y_7336_ = v_dNeg_7346_;
goto v___jp_7327_;
}
else
{
uint64_t v___x_7347_;
v___x_7347_ = 9223372036854775807ULL;
v___y_7311_ = v___y_7338_;
v___y_7312_ = v___y_7339_;
v___y_7313_ = v___y_7340_;
v___y_7314_ = v___x_7347_;
goto v___jp_7310_;
}
}
}
else
{
v___y_7328_ = v___x_7343_;
v___y_7329_ = v___y_7338_;
v___y_7330_ = v___y_7339_;
v___y_7331_ = v_dNeg_7346_;
v___y_7332_ = v___y_7340_;
v___y_7333_ = v_aNeg_7344_;
v___y_7334_ = v_bNeg_7345_;
v___y_7335_ = v_diff_7342_;
v___y_7336_ = v___y_7338_;
goto v___jp_7327_;
}
}
v___jp_7348_:
{
if (v___y_7349_ == 0)
{
v___y_7338_ = v___y_7350_;
v___y_7339_ = v___y_7351_;
v___y_7340_ = v___y_7353_;
v___y_7341_ = v___y_7352_;
goto v___jp_7337_;
}
else
{
if (v___y_7354_ == 0)
{
v___y_7338_ = v___y_7350_;
v___y_7339_ = v___y_7351_;
v___y_7340_ = v___y_7353_;
v___y_7341_ = v___y_7355_;
goto v___jp_7337_;
}
else
{
v___y_7338_ = v___y_7350_;
v___y_7339_ = v___y_7351_;
v___y_7340_ = v___y_7353_;
v___y_7341_ = v___y_7352_;
goto v___jp_7337_;
}
}
}
v___jp_7356_:
{
if (v___y_7360_ == 0)
{
v___y_7338_ = v___y_7359_;
v___y_7339_ = v___y_7361_;
v___y_7340_ = v___y_7363_;
v___y_7341_ = v___y_7364_;
goto v___jp_7337_;
}
else
{
if (v___y_7357_ == 0)
{
v___y_7349_ = v___y_7358_;
v___y_7350_ = v___y_7359_;
v___y_7351_ = v___y_7361_;
v___y_7352_ = v___y_7362_;
v___y_7353_ = v___y_7363_;
v___y_7354_ = v___y_7365_;
v___y_7355_ = v___y_7364_;
goto v___jp_7348_;
}
else
{
if (v___y_7365_ == 0)
{
v___y_7338_ = v___y_7359_;
v___y_7339_ = v___y_7361_;
v___y_7340_ = v___y_7363_;
v___y_7341_ = v___y_7364_;
goto v___jp_7337_;
}
else
{
v___y_7349_ = v___y_7358_;
v___y_7350_ = v___y_7359_;
v___y_7351_ = v___y_7361_;
v___y_7352_ = v___y_7362_;
v___y_7353_ = v___y_7363_;
v___y_7354_ = v___y_7365_;
v___y_7355_ = v___y_7364_;
goto v___jp_7348_;
}
}
}
}
v___jp_7366_:
{
if (v___y_7371_ == 0)
{
v___y_7271_ = v___y_7369_;
v___y_7272_ = v___y_7368_;
goto v___jp_7270_;
}
else
{
uint64_t v___x_7372_; uint64_t v___x_7373_; uint64_t v___x_7374_; uint8_t v___x_7375_;
v___x_7372_ = 9223372036854775808ULL;
v___x_7373_ = lean_uint64_add(v___y_7370_, v___x_7372_);
v___x_7374_ = lean_uint64_add(v_curTop_7094_, v___x_7372_);
v___x_7375_ = lean_uint64_dec_lt(v___x_7373_, v___x_7374_);
if (v___x_7375_ == 0)
{
v___y_7271_ = v___y_7369_;
v___y_7272_ = v___y_7368_;
goto v___jp_7270_;
}
else
{
uint64_t v_diff_7376_; uint8_t v_aNeg_7377_; uint8_t v_bNeg_7378_; uint8_t v_dNeg_7379_;
v_diff_7376_ = lean_uint64_sub(v_height_7095_, v___y_7370_);
v_aNeg_7377_ = lean_uint64_dec_le(v___x_7372_, v_height_7095_);
v_bNeg_7378_ = lean_uint64_dec_le(v___x_7372_, v___y_7370_);
v_dNeg_7379_ = lean_uint64_dec_le(v___x_7372_, v_diff_7376_);
if (v_aNeg_7377_ == 0)
{
if (v_bNeg_7378_ == 0)
{
v___y_7357_ = v_bNeg_7378_;
v___y_7358_ = v_dNeg_7379_;
v___y_7359_ = v___y_7367_;
v___y_7360_ = v_aNeg_7377_;
v___y_7361_ = v___y_7368_;
v___y_7362_ = v___x_7372_;
v___y_7363_ = v___y_7369_;
v___y_7364_ = v_diff_7376_;
v___y_7365_ = v_bNeg_7378_;
goto v___jp_7356_;
}
else
{
if (v_dNeg_7379_ == 0)
{
v___y_7357_ = v_bNeg_7378_;
v___y_7358_ = v_dNeg_7379_;
v___y_7359_ = v___y_7367_;
v___y_7360_ = v_aNeg_7377_;
v___y_7361_ = v___y_7368_;
v___y_7362_ = v___x_7372_;
v___y_7363_ = v___y_7369_;
v___y_7364_ = v_diff_7376_;
v___y_7365_ = v_dNeg_7379_;
goto v___jp_7356_;
}
else
{
uint64_t v___x_7380_;
v___x_7380_ = 9223372036854775807ULL;
v___y_7338_ = v___y_7367_;
v___y_7339_ = v___y_7368_;
v___y_7340_ = v___y_7369_;
v___y_7341_ = v___x_7380_;
goto v___jp_7337_;
}
}
}
else
{
v___y_7357_ = v_bNeg_7378_;
v___y_7358_ = v_dNeg_7379_;
v___y_7359_ = v___y_7367_;
v___y_7360_ = v_aNeg_7377_;
v___y_7361_ = v___y_7368_;
v___y_7362_ = v___x_7372_;
v___y_7363_ = v___y_7369_;
v___y_7364_ = v_diff_7376_;
v___y_7365_ = v___y_7367_;
goto v___jp_7356_;
}
}
}
}
v___jp_7381_:
{
if (v___y_7386_ == 0)
{
v___y_7367_ = v___y_7382_;
v___y_7368_ = v___y_7383_;
v___y_7369_ = v___y_7384_;
v___y_7370_ = v___y_7385_;
v___y_7371_ = v___y_7382_;
goto v___jp_7366_;
}
else
{
v___y_7367_ = v___y_7382_;
v___y_7368_ = v___y_7383_;
v___y_7369_ = v___y_7384_;
v___y_7370_ = v___y_7385_;
v___y_7371_ = v___y_7383_;
goto v___jp_7366_;
}
}
v___jp_7387_:
{
uint8_t v___x_7394_;
v___x_7394_ = lean_uint8_dec_eq(v_resized_7093_, v___y_7392_);
if (v___x_7394_ == 0)
{
v___y_7382_ = v___y_7389_;
v___y_7383_ = v___y_7390_;
v___y_7384_ = v___y_7391_;
v___y_7385_ = v___y_7393_;
v___y_7386_ = v___y_7388_;
goto v___jp_7381_;
}
else
{
v___y_7382_ = v___y_7389_;
v___y_7383_ = v___y_7390_;
v___y_7384_ = v___y_7391_;
v___y_7385_ = v___y_7393_;
v___y_7386_ = v___y_7389_;
goto v___jp_7381_;
}
}
v___jp_7395_:
{
uint64_t v___x_7403_; uint64_t v___x_7404_; uint8_t v___x_7405_;
v___x_7403_ = 9223372036854775808ULL;
v___x_7404_ = lean_uint64_add(v___y_7402_, v___x_7403_);
v___x_7405_ = lean_uint64_dec_lt(v___x_7403_, v___x_7404_);
if (v___x_7405_ == 0)
{
v___y_7388_ = v___y_7397_;
v___y_7389_ = v___y_7398_;
v___y_7390_ = v___y_7399_;
v___y_7391_ = v___y_7400_;
v___y_7392_ = v___y_7401_;
v___y_7393_ = v___y_7396_;
goto v___jp_7387_;
}
else
{
v___y_7388_ = v___y_7397_;
v___y_7389_ = v___y_7398_;
v___y_7390_ = v___y_7399_;
v___y_7391_ = v___y_7400_;
v___y_7392_ = v___y_7401_;
v___y_7393_ = v___y_7402_;
goto v___jp_7387_;
}
}
v___jp_7406_:
{
uint64_t v___x_7414_; uint64_t v___x_7415_; uint64_t v___x_7416_; uint8_t v___x_7417_;
v___x_7414_ = 9223372036854775808ULL;
v___x_7415_ = lean_uint64_add(v_arg_7097_, v___x_7414_);
v___x_7416_ = lean_uint64_add(v___y_7413_, v___x_7414_);
v___x_7417_ = lean_uint64_dec_le(v___x_7415_, v___x_7416_);
if (v___x_7417_ == 0)
{
v___y_7396_ = v___y_7407_;
v___y_7397_ = v___y_7408_;
v___y_7398_ = v___y_7409_;
v___y_7399_ = v___y_7410_;
v___y_7400_ = v___y_7411_;
v___y_7401_ = v___y_7412_;
v___y_7402_ = v___y_7413_;
goto v___jp_7395_;
}
else
{
v___y_7396_ = v___y_7407_;
v___y_7397_ = v___y_7408_;
v___y_7398_ = v___y_7409_;
v___y_7399_ = v___y_7410_;
v___y_7400_ = v___y_7411_;
v___y_7401_ = v___y_7412_;
v___y_7402_ = v_arg_7097_;
goto v___jp_7395_;
}
}
v___jp_7418_:
{
uint64_t v___x_7426_; uint64_t v___x_7427_; uint8_t v___x_7428_;
v___x_7426_ = 9223372036854775808ULL;
v___x_7427_ = lean_uint64_add(v___y_7425_, v___x_7426_);
v___x_7428_ = lean_uint64_dec_lt(v___x_7426_, v___x_7427_);
if (v___x_7428_ == 0)
{
v___y_7407_ = v___y_7419_;
v___y_7408_ = v___y_7420_;
v___y_7409_ = v___y_7421_;
v___y_7410_ = v___y_7422_;
v___y_7411_ = v___y_7423_;
v___y_7412_ = v___y_7424_;
v___y_7413_ = v___y_7419_;
goto v___jp_7406_;
}
else
{
v___y_7407_ = v___y_7419_;
v___y_7408_ = v___y_7420_;
v___y_7409_ = v___y_7421_;
v___y_7410_ = v___y_7422_;
v___y_7411_ = v___y_7423_;
v___y_7412_ = v___y_7424_;
v___y_7413_ = v___y_7425_;
goto v___jp_7406_;
}
}
v___jp_7429_:
{
if (v___y_7438_ == 0)
{
v___y_7419_ = v___y_7430_;
v___y_7420_ = v___y_7432_;
v___y_7421_ = v___y_7433_;
v___y_7422_ = v___y_7434_;
v___y_7423_ = v___y_7436_;
v___y_7424_ = v___y_7437_;
v___y_7425_ = v___y_7431_;
goto v___jp_7418_;
}
else
{
if (v___y_7435_ == 0)
{
v___y_7419_ = v___y_7430_;
v___y_7420_ = v___y_7432_;
v___y_7421_ = v___y_7433_;
v___y_7422_ = v___y_7434_;
v___y_7423_ = v___y_7436_;
v___y_7424_ = v___y_7437_;
v___y_7425_ = v___y_7439_;
goto v___jp_7418_;
}
else
{
v___y_7419_ = v___y_7430_;
v___y_7420_ = v___y_7432_;
v___y_7421_ = v___y_7433_;
v___y_7422_ = v___y_7434_;
v___y_7423_ = v___y_7436_;
v___y_7424_ = v___y_7437_;
v___y_7425_ = v___y_7431_;
goto v___jp_7418_;
}
}
}
v___jp_7440_:
{
if (v___y_7450_ == 0)
{
v___y_7419_ = v___y_7442_;
v___y_7420_ = v___y_7443_;
v___y_7421_ = v___y_7444_;
v___y_7422_ = v___y_7446_;
v___y_7423_ = v___y_7447_;
v___y_7424_ = v___y_7449_;
v___y_7425_ = v___y_7451_;
goto v___jp_7418_;
}
else
{
if (v___y_7445_ == 0)
{
v___y_7430_ = v___y_7442_;
v___y_7431_ = v___y_7441_;
v___y_7432_ = v___y_7443_;
v___y_7433_ = v___y_7444_;
v___y_7434_ = v___y_7446_;
v___y_7435_ = v___y_7452_;
v___y_7436_ = v___y_7447_;
v___y_7437_ = v___y_7449_;
v___y_7438_ = v___y_7448_;
v___y_7439_ = v___y_7451_;
goto v___jp_7429_;
}
else
{
if (v___y_7452_ == 0)
{
v___y_7419_ = v___y_7442_;
v___y_7420_ = v___y_7443_;
v___y_7421_ = v___y_7444_;
v___y_7422_ = v___y_7446_;
v___y_7423_ = v___y_7447_;
v___y_7424_ = v___y_7449_;
v___y_7425_ = v___y_7451_;
goto v___jp_7418_;
}
else
{
v___y_7430_ = v___y_7442_;
v___y_7431_ = v___y_7441_;
v___y_7432_ = v___y_7443_;
v___y_7433_ = v___y_7444_;
v___y_7434_ = v___y_7446_;
v___y_7435_ = v___y_7452_;
v___y_7436_ = v___y_7447_;
v___y_7437_ = v___y_7449_;
v___y_7438_ = v___y_7448_;
v___y_7439_ = v___y_7451_;
goto v___jp_7429_;
}
}
}
}
v___jp_7453_:
{
uint8_t v___x_7459_; uint8_t v___x_7460_;
v___x_7459_ = 2;
v___x_7460_ = lean_uint8_dec_eq(v_opKind_7090_, v___x_7459_);
if (v___x_7460_ == 0)
{
v___y_7271_ = v___y_7455_;
v___y_7272_ = v___y_7457_;
goto v___jp_7270_;
}
else
{
uint64_t v___x_7461_; uint64_t v_diff_7462_; uint64_t v___x_7463_; uint8_t v_aNeg_7464_; uint8_t v_bNeg_7465_; uint8_t v_dNeg_7466_;
v___x_7461_ = 0ULL;
v_diff_7462_ = lean_uint64_sub(v_height_7095_, v_client_7096_);
v___x_7463_ = 9223372036854775808ULL;
v_aNeg_7464_ = lean_uint64_dec_le(v___x_7463_, v_height_7095_);
v_bNeg_7465_ = lean_uint64_dec_le(v___x_7463_, v_client_7096_);
v_dNeg_7466_ = lean_uint64_dec_le(v___x_7463_, v_diff_7462_);
if (v_aNeg_7464_ == 0)
{
if (v_bNeg_7465_ == 0)
{
v___y_7441_ = v___x_7463_;
v___y_7442_ = v___x_7461_;
v___y_7443_ = v___x_7460_;
v___y_7444_ = v___y_7458_;
v___y_7445_ = v_bNeg_7465_;
v___y_7446_ = v___y_7454_;
v___y_7447_ = v___y_7455_;
v___y_7448_ = v_dNeg_7466_;
v___y_7449_ = v___y_7456_;
v___y_7450_ = v_aNeg_7464_;
v___y_7451_ = v_diff_7462_;
v___y_7452_ = v_bNeg_7465_;
goto v___jp_7440_;
}
else
{
if (v_dNeg_7466_ == 0)
{
v___y_7441_ = v___x_7463_;
v___y_7442_ = v___x_7461_;
v___y_7443_ = v___x_7460_;
v___y_7444_ = v___y_7458_;
v___y_7445_ = v_bNeg_7465_;
v___y_7446_ = v___y_7454_;
v___y_7447_ = v___y_7455_;
v___y_7448_ = v_dNeg_7466_;
v___y_7449_ = v___y_7456_;
v___y_7450_ = v_aNeg_7464_;
v___y_7451_ = v_diff_7462_;
v___y_7452_ = v_dNeg_7466_;
goto v___jp_7440_;
}
else
{
uint64_t v___x_7467_;
v___x_7467_ = 9223372036854775807ULL;
v___y_7419_ = v___x_7461_;
v___y_7420_ = v___x_7460_;
v___y_7421_ = v___y_7458_;
v___y_7422_ = v___y_7454_;
v___y_7423_ = v___y_7455_;
v___y_7424_ = v___y_7456_;
v___y_7425_ = v___x_7467_;
goto v___jp_7418_;
}
}
}
else
{
v___y_7441_ = v___x_7463_;
v___y_7442_ = v___x_7461_;
v___y_7443_ = v___x_7460_;
v___y_7444_ = v___y_7458_;
v___y_7445_ = v_bNeg_7465_;
v___y_7446_ = v___y_7454_;
v___y_7447_ = v___y_7455_;
v___y_7448_ = v_dNeg_7466_;
v___y_7449_ = v___y_7456_;
v___y_7450_ = v_aNeg_7464_;
v___y_7451_ = v_diff_7462_;
v___y_7452_ = v___y_7458_;
goto v___jp_7440_;
}
}
}
v___jp_7468_:
{
if (v___y_7474_ == 0)
{
v___y_7302_ = v___y_7470_;
v___y_7303_ = v___y_7472_;
v___y_7304_ = v___y_7475_;
v___y_7305_ = v___y_7473_;
goto v___jp_7301_;
}
else
{
if (v___y_7471_ == 0)
{
v___y_7302_ = v___y_7470_;
v___y_7303_ = v___y_7472_;
v___y_7304_ = v___y_7475_;
v___y_7305_ = v___y_7469_;
goto v___jp_7301_;
}
else
{
v___y_7302_ = v___y_7470_;
v___y_7303_ = v___y_7472_;
v___y_7304_ = v___y_7475_;
v___y_7305_ = v___y_7473_;
goto v___jp_7301_;
}
}
}
v___jp_7476_:
{
if (v___y_7483_ == 0)
{
v___y_7302_ = v___y_7479_;
v___y_7303_ = v___y_7480_;
v___y_7304_ = v___y_7484_;
v___y_7305_ = v___y_7477_;
goto v___jp_7301_;
}
else
{
if (v___y_7478_ == 0)
{
v___y_7469_ = v___y_7477_;
v___y_7470_ = v___y_7479_;
v___y_7471_ = v___y_7485_;
v___y_7472_ = v___y_7480_;
v___y_7473_ = v___y_7482_;
v___y_7474_ = v___y_7481_;
v___y_7475_ = v___y_7484_;
goto v___jp_7468_;
}
else
{
if (v___y_7485_ == 0)
{
v___y_7302_ = v___y_7479_;
v___y_7303_ = v___y_7480_;
v___y_7304_ = v___y_7484_;
v___y_7305_ = v___y_7477_;
goto v___jp_7301_;
}
else
{
v___y_7469_ = v___y_7477_;
v___y_7470_ = v___y_7479_;
v___y_7471_ = v___y_7485_;
v___y_7472_ = v___y_7480_;
v___y_7473_ = v___y_7482_;
v___y_7474_ = v___y_7481_;
v___y_7475_ = v___y_7484_;
goto v___jp_7468_;
}
}
}
}
v___jp_7486_:
{
uint64_t v_diff_7493_; uint8_t v_aNeg_7494_; uint8_t v_bNeg_7495_; uint8_t v_dNeg_7496_;
v_diff_7493_ = lean_uint64_sub(v___y_7492_, v_client_7096_);
v_aNeg_7494_ = lean_uint64_dec_le(v___y_7490_, v___y_7492_);
v_bNeg_7495_ = lean_uint64_dec_le(v___y_7490_, v_client_7096_);
v_dNeg_7496_ = lean_uint64_dec_le(v___y_7490_, v_diff_7493_);
if (v_aNeg_7494_ == 0)
{
if (v_bNeg_7495_ == 0)
{
v___y_7477_ = v_diff_7493_;
v___y_7478_ = v_bNeg_7495_;
v___y_7479_ = v___y_7488_;
v___y_7480_ = v___y_7489_;
v___y_7481_ = v_dNeg_7496_;
v___y_7482_ = v___y_7490_;
v___y_7483_ = v_aNeg_7494_;
v___y_7484_ = v___y_7491_;
v___y_7485_ = v_bNeg_7495_;
goto v___jp_7476_;
}
else
{
if (v_dNeg_7496_ == 0)
{
v___y_7477_ = v_diff_7493_;
v___y_7478_ = v_bNeg_7495_;
v___y_7479_ = v___y_7488_;
v___y_7480_ = v___y_7489_;
v___y_7481_ = v_dNeg_7496_;
v___y_7482_ = v___y_7490_;
v___y_7483_ = v_aNeg_7494_;
v___y_7484_ = v___y_7491_;
v___y_7485_ = v_dNeg_7496_;
goto v___jp_7476_;
}
else
{
uint64_t v___x_7497_;
v___x_7497_ = 9223372036854775807ULL;
v___y_7302_ = v___y_7488_;
v___y_7303_ = v___y_7489_;
v___y_7304_ = v___y_7491_;
v___y_7305_ = v___x_7497_;
goto v___jp_7301_;
}
}
}
else
{
v___y_7477_ = v_diff_7493_;
v___y_7478_ = v_bNeg_7495_;
v___y_7479_ = v___y_7488_;
v___y_7480_ = v___y_7489_;
v___y_7481_ = v_dNeg_7496_;
v___y_7482_ = v___y_7490_;
v___y_7483_ = v_aNeg_7494_;
v___y_7484_ = v___y_7491_;
v___y_7485_ = v___y_7487_;
goto v___jp_7476_;
}
}
v___jp_7498_:
{
if (v___y_7499_ == 0)
{
v___y_7487_ = v___y_7501_;
v___y_7488_ = v___y_7503_;
v___y_7489_ = v___y_7504_;
v___y_7490_ = v___y_7505_;
v___y_7491_ = v___y_7506_;
v___y_7492_ = v___y_7505_;
goto v___jp_7486_;
}
else
{
if (v___y_7502_ == 0)
{
v___y_7487_ = v___y_7501_;
v___y_7488_ = v___y_7503_;
v___y_7489_ = v___y_7504_;
v___y_7490_ = v___y_7505_;
v___y_7491_ = v___y_7506_;
v___y_7492_ = v___y_7500_;
goto v___jp_7486_;
}
else
{
v___y_7487_ = v___y_7501_;
v___y_7488_ = v___y_7503_;
v___y_7489_ = v___y_7504_;
v___y_7490_ = v___y_7505_;
v___y_7491_ = v___y_7506_;
v___y_7492_ = v___y_7505_;
goto v___jp_7486_;
}
}
}
v___jp_7507_:
{
if (v___y_7514_ == 0)
{
v___y_7487_ = v___y_7509_;
v___y_7488_ = v___y_7511_;
v___y_7489_ = v___y_7513_;
v___y_7490_ = v___y_7515_;
v___y_7491_ = v___y_7516_;
v___y_7492_ = v___y_7510_;
goto v___jp_7486_;
}
else
{
if (v___y_7512_ == 0)
{
v___y_7499_ = v___y_7508_;
v___y_7500_ = v___y_7510_;
v___y_7501_ = v___y_7509_;
v___y_7502_ = v___y_7517_;
v___y_7503_ = v___y_7511_;
v___y_7504_ = v___y_7513_;
v___y_7505_ = v___y_7515_;
v___y_7506_ = v___y_7516_;
goto v___jp_7498_;
}
else
{
if (v___y_7517_ == 0)
{
v___y_7487_ = v___y_7509_;
v___y_7488_ = v___y_7511_;
v___y_7489_ = v___y_7513_;
v___y_7490_ = v___y_7515_;
v___y_7491_ = v___y_7516_;
v___y_7492_ = v___y_7510_;
goto v___jp_7486_;
}
else
{
v___y_7499_ = v___y_7508_;
v___y_7500_ = v___y_7510_;
v___y_7501_ = v___y_7509_;
v___y_7502_ = v___y_7517_;
v___y_7503_ = v___y_7511_;
v___y_7504_ = v___y_7513_;
v___y_7505_ = v___y_7515_;
v___y_7506_ = v___y_7516_;
goto v___jp_7498_;
}
}
}
}
v___jp_7518_:
{
uint64_t v___x_7524_; uint64_t v___x_7525_; uint64_t v___x_7526_; uint8_t v___x_7527_;
v___x_7524_ = 9223372036854775808ULL;
v___x_7525_ = lean_uint64_add(v___y_7523_, v___x_7524_);
v___x_7526_ = lean_uint64_add(v_curTop_7094_, v___x_7524_);
v___x_7527_ = lean_uint64_dec_lt(v___x_7525_, v___x_7526_);
if (v___x_7527_ == 0)
{
uint64_t v_diff_7528_; uint8_t v_aNeg_7529_; uint8_t v_bNeg_7530_; uint8_t v_dNeg_7531_;
v_diff_7528_ = lean_uint64_sub(v_height_7095_, v___y_7523_);
v_aNeg_7529_ = lean_uint64_dec_le(v___x_7524_, v_height_7095_);
v_bNeg_7530_ = lean_uint64_dec_le(v___x_7524_, v___y_7523_);
v_dNeg_7531_ = lean_uint64_dec_le(v___x_7524_, v_diff_7528_);
if (v_aNeg_7529_ == 0)
{
if (v_bNeg_7530_ == 0)
{
v___y_7508_ = v_dNeg_7531_;
v___y_7509_ = v___x_7527_;
v___y_7510_ = v_diff_7528_;
v___y_7511_ = v___y_7519_;
v___y_7512_ = v_bNeg_7530_;
v___y_7513_ = v___y_7521_;
v___y_7514_ = v_aNeg_7529_;
v___y_7515_ = v___x_7524_;
v___y_7516_ = v___y_7522_;
v___y_7517_ = v_bNeg_7530_;
goto v___jp_7507_;
}
else
{
if (v_dNeg_7531_ == 0)
{
v___y_7508_ = v_dNeg_7531_;
v___y_7509_ = v___x_7527_;
v___y_7510_ = v_diff_7528_;
v___y_7511_ = v___y_7519_;
v___y_7512_ = v_bNeg_7530_;
v___y_7513_ = v___y_7521_;
v___y_7514_ = v_aNeg_7529_;
v___y_7515_ = v___x_7524_;
v___y_7516_ = v___y_7522_;
v___y_7517_ = v_dNeg_7531_;
goto v___jp_7507_;
}
else
{
uint64_t v___x_7532_;
v___x_7532_ = 9223372036854775807ULL;
v___y_7487_ = v___x_7527_;
v___y_7488_ = v___y_7519_;
v___y_7489_ = v___y_7521_;
v___y_7490_ = v___x_7524_;
v___y_7491_ = v___y_7522_;
v___y_7492_ = v___x_7532_;
goto v___jp_7486_;
}
}
}
else
{
v___y_7508_ = v_dNeg_7531_;
v___y_7509_ = v___x_7527_;
v___y_7510_ = v_diff_7528_;
v___y_7511_ = v___y_7519_;
v___y_7512_ = v_bNeg_7530_;
v___y_7513_ = v___y_7521_;
v___y_7514_ = v_aNeg_7529_;
v___y_7515_ = v___x_7524_;
v___y_7516_ = v___y_7522_;
v___y_7517_ = v___x_7527_;
goto v___jp_7507_;
}
}
else
{
v___y_7271_ = v___y_7521_;
v___y_7272_ = v___y_7520_;
goto v___jp_7270_;
}
}
v___jp_7533_:
{
uint64_t v___x_7540_; uint64_t v___x_7541_; uint8_t v___x_7542_;
v___x_7540_ = 9223372036854775808ULL;
v___x_7541_ = lean_uint64_add(v___y_7539_, v___x_7540_);
v___x_7542_ = lean_uint64_dec_lt(v___x_7540_, v___x_7541_);
if (v___x_7542_ == 0)
{
v___y_7519_ = v___y_7534_;
v___y_7520_ = v___y_7535_;
v___y_7521_ = v___y_7537_;
v___y_7522_ = v___y_7538_;
v___y_7523_ = v___y_7536_;
goto v___jp_7518_;
}
else
{
v___y_7519_ = v___y_7534_;
v___y_7520_ = v___y_7535_;
v___y_7521_ = v___y_7537_;
v___y_7522_ = v___y_7538_;
v___y_7523_ = v___y_7539_;
goto v___jp_7518_;
}
}
v___jp_7543_:
{
uint64_t v___x_7550_; uint64_t v___x_7551_; uint64_t v___x_7552_; uint8_t v___x_7553_;
v___x_7550_ = 9223372036854775808ULL;
v___x_7551_ = lean_uint64_add(v_arg_7097_, v___x_7550_);
v___x_7552_ = lean_uint64_add(v___y_7549_, v___x_7550_);
v___x_7553_ = lean_uint64_dec_le(v___x_7551_, v___x_7552_);
if (v___x_7553_ == 0)
{
v___y_7534_ = v___y_7544_;
v___y_7535_ = v___y_7546_;
v___y_7536_ = v___y_7545_;
v___y_7537_ = v___y_7547_;
v___y_7538_ = v___y_7548_;
v___y_7539_ = v___y_7549_;
goto v___jp_7533_;
}
else
{
v___y_7534_ = v___y_7544_;
v___y_7535_ = v___y_7546_;
v___y_7536_ = v___y_7545_;
v___y_7537_ = v___y_7547_;
v___y_7538_ = v___y_7548_;
v___y_7539_ = v_arg_7097_;
goto v___jp_7533_;
}
}
v___jp_7554_:
{
uint64_t v___x_7561_; uint64_t v___x_7562_; uint8_t v___x_7563_;
v___x_7561_ = 9223372036854775808ULL;
v___x_7562_ = lean_uint64_add(v___y_7560_, v___x_7561_);
v___x_7563_ = lean_uint64_dec_lt(v___x_7561_, v___x_7562_);
if (v___x_7563_ == 0)
{
v___y_7544_ = v___y_7555_;
v___y_7545_ = v___y_7557_;
v___y_7546_ = v___y_7556_;
v___y_7547_ = v___y_7558_;
v___y_7548_ = v___y_7559_;
v___y_7549_ = v___y_7557_;
goto v___jp_7543_;
}
else
{
v___y_7544_ = v___y_7555_;
v___y_7545_ = v___y_7557_;
v___y_7546_ = v___y_7556_;
v___y_7547_ = v___y_7558_;
v___y_7548_ = v___y_7559_;
v___y_7549_ = v___y_7560_;
goto v___jp_7543_;
}
}
v___jp_7564_:
{
if (v___y_7566_ == 0)
{
v___y_7555_ = v___y_7569_;
v___y_7556_ = v___y_7571_;
v___y_7557_ = v___y_7570_;
v___y_7558_ = v___y_7572_;
v___y_7559_ = v___y_7573_;
v___y_7560_ = v___y_7565_;
goto v___jp_7554_;
}
else
{
if (v___y_7568_ == 0)
{
v___y_7555_ = v___y_7569_;
v___y_7556_ = v___y_7571_;
v___y_7557_ = v___y_7570_;
v___y_7558_ = v___y_7572_;
v___y_7559_ = v___y_7573_;
v___y_7560_ = v___y_7567_;
goto v___jp_7554_;
}
else
{
v___y_7555_ = v___y_7569_;
v___y_7556_ = v___y_7571_;
v___y_7557_ = v___y_7570_;
v___y_7558_ = v___y_7572_;
v___y_7559_ = v___y_7573_;
v___y_7560_ = v___y_7565_;
goto v___jp_7554_;
}
}
}
v___jp_7574_:
{
if (v___y_7582_ == 0)
{
v___y_7555_ = v___y_7577_;
v___y_7556_ = v___y_7579_;
v___y_7557_ = v___y_7580_;
v___y_7558_ = v___y_7581_;
v___y_7559_ = v___y_7584_;
v___y_7560_ = v___y_7578_;
goto v___jp_7554_;
}
else
{
if (v___y_7583_ == 0)
{
v___y_7565_ = v___y_7575_;
v___y_7566_ = v___y_7576_;
v___y_7567_ = v___y_7578_;
v___y_7568_ = v___y_7585_;
v___y_7569_ = v___y_7577_;
v___y_7570_ = v___y_7580_;
v___y_7571_ = v___y_7579_;
v___y_7572_ = v___y_7581_;
v___y_7573_ = v___y_7584_;
goto v___jp_7564_;
}
else
{
if (v___y_7585_ == 0)
{
v___y_7555_ = v___y_7577_;
v___y_7556_ = v___y_7579_;
v___y_7557_ = v___y_7580_;
v___y_7558_ = v___y_7581_;
v___y_7559_ = v___y_7584_;
v___y_7560_ = v___y_7578_;
goto v___jp_7554_;
}
else
{
v___y_7565_ = v___y_7575_;
v___y_7566_ = v___y_7576_;
v___y_7567_ = v___y_7578_;
v___y_7568_ = v___y_7585_;
v___y_7569_ = v___y_7577_;
v___y_7570_ = v___y_7580_;
v___y_7571_ = v___y_7579_;
v___y_7572_ = v___y_7581_;
v___y_7573_ = v___y_7584_;
goto v___jp_7564_;
}
}
}
}
v___jp_7586_:
{
uint64_t v___x_7591_; uint64_t v_diff_7592_; uint64_t v___x_7593_; uint8_t v_aNeg_7594_; uint8_t v_bNeg_7595_; uint8_t v_dNeg_7596_;
v___x_7591_ = 0ULL;
v_diff_7592_ = lean_uint64_sub(v_height_7095_, v_client_7096_);
v___x_7593_ = 9223372036854775808ULL;
v_aNeg_7594_ = lean_uint64_dec_le(v___x_7593_, v_height_7095_);
v_bNeg_7595_ = lean_uint64_dec_le(v___x_7593_, v_client_7096_);
v_dNeg_7596_ = lean_uint64_dec_le(v___x_7593_, v_diff_7592_);
if (v_aNeg_7594_ == 0)
{
if (v_bNeg_7595_ == 0)
{
v___y_7575_ = v___x_7593_;
v___y_7576_ = v_dNeg_7596_;
v___y_7577_ = v___y_7587_;
v___y_7578_ = v_diff_7592_;
v___y_7579_ = v___y_7588_;
v___y_7580_ = v___x_7591_;
v___y_7581_ = v___y_7589_;
v___y_7582_ = v_aNeg_7594_;
v___y_7583_ = v_bNeg_7595_;
v___y_7584_ = v___y_7590_;
v___y_7585_ = v_bNeg_7595_;
goto v___jp_7574_;
}
else
{
if (v_dNeg_7596_ == 0)
{
v___y_7575_ = v___x_7593_;
v___y_7576_ = v_dNeg_7596_;
v___y_7577_ = v___y_7587_;
v___y_7578_ = v_diff_7592_;
v___y_7579_ = v___y_7588_;
v___y_7580_ = v___x_7591_;
v___y_7581_ = v___y_7589_;
v___y_7582_ = v_aNeg_7594_;
v___y_7583_ = v_bNeg_7595_;
v___y_7584_ = v___y_7590_;
v___y_7585_ = v_dNeg_7596_;
goto v___jp_7574_;
}
else
{
uint64_t v___x_7597_;
v___x_7597_ = 9223372036854775807ULL;
v___y_7555_ = v___y_7587_;
v___y_7556_ = v___y_7588_;
v___y_7557_ = v___x_7591_;
v___y_7558_ = v___y_7589_;
v___y_7559_ = v___y_7590_;
v___y_7560_ = v___x_7597_;
goto v___jp_7554_;
}
}
}
else
{
v___y_7575_ = v___x_7593_;
v___y_7576_ = v_dNeg_7596_;
v___y_7577_ = v___y_7587_;
v___y_7578_ = v_diff_7592_;
v___y_7579_ = v___y_7588_;
v___y_7580_ = v___x_7591_;
v___y_7581_ = v___y_7589_;
v___y_7582_ = v_aNeg_7594_;
v___y_7583_ = v_bNeg_7595_;
v___y_7584_ = v___y_7590_;
v___y_7585_ = v___y_7588_;
goto v___jp_7574_;
}
}
v___jp_7598_:
{
uint8_t v___x_7602_; uint8_t v___x_7603_;
v___x_7602_ = 3;
v___x_7603_ = lean_uint8_dec_le(v_opKind_7090_, v___x_7602_);
if (v___x_7603_ == 0)
{
uint32_t v___x_7604_; uint32_t v_lo32Err_7605_; uint64_t v___x_7606_; uint64_t v___x_7607_; uint64_t v___x_7608_; uint64_t v___x_7609_; uint64_t v___x_7610_;
v___x_7604_ = 2;
v_lo32Err_7605_ = lean_uint32_lor(v___x_7604_, v___y_7599_);
v___x_7606_ = lean_uint32_to_uint64(v_lo32Err_7605_);
v___x_7607_ = lean_uint32_to_uint64(v___y_7600_);
v___x_7608_ = 32ULL;
v___x_7609_ = lean_uint64_shift_left(v___x_7607_, v___x_7608_);
v___x_7610_ = lean_uint64_lor(v___x_7606_, v___x_7609_);
return v___x_7610_;
}
else
{
if (v___y_7601_ == 0)
{
uint32_t v___x_7611_; uint32_t v_lo32Dom_7612_; uint64_t v___x_7613_; uint64_t v___x_7614_; uint64_t v___x_7615_; uint64_t v___x_7616_; uint64_t v___x_7617_;
v___x_7611_ = 3;
v_lo32Dom_7612_ = lean_uint32_lor(v___x_7611_, v___y_7599_);
v___x_7613_ = lean_uint32_to_uint64(v_lo32Dom_7612_);
v___x_7614_ = lean_uint32_to_uint64(v___y_7600_);
v___x_7615_ = 32ULL;
v___x_7616_ = lean_uint64_shift_left(v___x_7614_, v___x_7615_);
v___x_7617_ = lean_uint64_lor(v___x_7613_, v___x_7616_);
return v___x_7617_;
}
else
{
uint8_t v___x_7618_; uint8_t v___x_7619_; uint8_t v_pinBool_7620_; uint8_t v___x_7621_; uint8_t v___x_7622_;
v___x_7618_ = 0;
v___x_7619_ = 1;
v_pinBool_7620_ = lean_uint8_dec_eq(v_pinned_7091_, v___x_7619_);
v___x_7621_ = 0;
v___x_7622_ = lean_uint8_dec_eq(v_opKind_7090_, v___x_7621_);
if (v___x_7622_ == 0)
{
uint8_t v___x_7623_;
v___x_7623_ = lean_uint8_dec_eq(v_opKind_7090_, v___x_7619_);
if (v___x_7623_ == 0)
{
uint8_t v___x_7624_; uint8_t v___x_7625_;
v___x_7624_ = 2;
v___x_7625_ = lean_uint8_dec_eq(v_opKind_7090_, v___x_7624_);
if (v___x_7625_ == 0)
{
v___y_7454_ = v_pinBool_7620_;
v___y_7455_ = v___x_7618_;
v___y_7456_ = v___x_7619_;
v___y_7457_ = v___y_7601_;
v___y_7458_ = v___x_7622_;
goto v___jp_7453_;
}
else
{
uint8_t v___x_7626_;
v___x_7626_ = lean_uint8_dec_eq(v_intent_7092_, v___x_7619_);
if (v___x_7626_ == 0)
{
v___y_7454_ = v_pinBool_7620_;
v___y_7455_ = v___x_7618_;
v___y_7456_ = v___x_7619_;
v___y_7457_ = v___y_7601_;
v___y_7458_ = v___x_7626_;
goto v___jp_7453_;
}
else
{
v___y_7587_ = v_pinBool_7620_;
v___y_7588_ = v___x_7622_;
v___y_7589_ = v___x_7618_;
v___y_7590_ = v___y_7601_;
goto v___jp_7586_;
}
}
}
else
{
v___y_7587_ = v_pinBool_7620_;
v___y_7588_ = v___x_7622_;
v___y_7589_ = v___x_7618_;
v___y_7590_ = v___y_7601_;
goto v___jp_7586_;
}
}
else
{
v___y_7271_ = v___x_7618_;
v___y_7272_ = v_pinBool_7620_;
goto v___jp_7270_;
}
}
}
}
v___jp_7627_:
{
uint64_t v___x_7630_; uint8_t v___x_7631_;
v___x_7630_ = 1073741823ULL;
v___x_7631_ = lean_uint64_dec_le(v_arg_7097_, v___x_7630_);
if (v___x_7631_ == 0)
{
uint64_t v___x_7632_; uint8_t v___x_7633_;
v___x_7632_ = 18446744072635809792ULL;
v___x_7633_ = lean_uint64_dec_le(v___x_7632_, v_arg_7097_);
v___y_7599_ = v___y_7628_;
v___y_7600_ = v___y_7629_;
v___y_7601_ = v___x_7633_;
goto v___jp_7598_;
}
else
{
v___y_7599_ = v___y_7628_;
v___y_7600_ = v___y_7629_;
v___y_7601_ = v___x_7631_;
goto v___jp_7598_;
}
}
v___jp_7634_:
{
uint64_t v___x_7637_; uint8_t v___x_7638_;
v___x_7637_ = 1073741823ULL;
v___x_7638_ = lean_uint64_dec_le(v_client_7096_, v___x_7637_);
if (v___x_7638_ == 0)
{
uint64_t v___x_7639_; uint8_t v___x_7640_;
v___x_7639_ = 18446744072635809792ULL;
v___x_7640_ = lean_uint64_dec_le(v___x_7639_, v_client_7096_);
if (v___x_7640_ == 0)
{
v___y_7599_ = v___y_7635_;
v___y_7600_ = v___y_7636_;
v___y_7601_ = v___x_7640_;
goto v___jp_7598_;
}
else
{
v___y_7628_ = v___y_7635_;
v___y_7629_ = v___y_7636_;
goto v___jp_7627_;
}
}
else
{
v___y_7628_ = v___y_7635_;
v___y_7629_ = v___y_7636_;
goto v___jp_7627_;
}
}
v___jp_7641_:
{
uint64_t v___x_7644_; uint8_t v___x_7645_;
v___x_7644_ = 1073741823ULL;
v___x_7645_ = lean_uint64_dec_le(v_height_7095_, v___x_7644_);
if (v___x_7645_ == 0)
{
uint64_t v___x_7646_; uint8_t v___x_7647_;
v___x_7646_ = 18446744072635809792ULL;
v___x_7647_ = lean_uint64_dec_le(v___x_7646_, v_height_7095_);
if (v___x_7647_ == 0)
{
v___y_7599_ = v___y_7642_;
v___y_7600_ = v___y_7643_;
v___y_7601_ = v___x_7647_;
goto v___jp_7598_;
}
else
{
v___y_7635_ = v___y_7642_;
v___y_7636_ = v___y_7643_;
goto v___jp_7634_;
}
}
else
{
v___y_7635_ = v___y_7642_;
v___y_7636_ = v___y_7643_;
goto v___jp_7634_;
}
}
v___jp_7648_:
{
uint64_t v___x_7651_; uint8_t v___x_7652_;
v___x_7651_ = 1073741823ULL;
v___x_7652_ = lean_uint64_dec_le(v_curTop_7094_, v___x_7651_);
if (v___x_7652_ == 0)
{
uint64_t v___x_7653_; uint8_t v___x_7654_;
v___x_7653_ = 18446744072635809792ULL;
v___x_7654_ = lean_uint64_dec_le(v___x_7653_, v_curTop_7094_);
if (v___x_7654_ == 0)
{
v___y_7599_ = v___y_7649_;
v___y_7600_ = v___y_7650_;
v___y_7601_ = v___x_7654_;
goto v___jp_7598_;
}
else
{
v___y_7642_ = v___y_7649_;
v___y_7643_ = v___y_7650_;
goto v___jp_7641_;
}
}
else
{
v___y_7642_ = v___y_7649_;
v___y_7643_ = v___y_7650_;
goto v___jp_7641_;
}
}
v___jp_7655_:
{
uint64_t v___x_7658_; uint8_t v___x_7659_;
v___x_7658_ = 4294967295ULL;
v___x_7659_ = lean_uint64_dec_le(v___y_7657_, v___x_7658_);
if (v___x_7659_ == 0)
{
uint32_t v___x_7660_;
v___x_7660_ = 4294967295;
v___y_7649_ = v___y_7656_;
v___y_7650_ = v___x_7660_;
goto v___jp_7648_;
}
else
{
uint32_t v___x_7661_;
v___x_7661_ = lean_uint64_to_uint32(v___y_7657_);
v___y_7649_ = v___y_7656_;
v___y_7650_ = v___x_7661_;
goto v___jp_7648_;
}
}
v___jp_7662_:
{
uint64_t v___x_7664_; uint64_t v___x_7665_; uint8_t v___x_7666_;
v___x_7664_ = 9223372036854775808ULL;
v___x_7665_ = lean_uint64_add(v_curTop_7094_, v___x_7664_);
v___x_7666_ = lean_uint64_dec_lt(v___x_7664_, v___x_7665_);
if (v___x_7666_ == 0)
{
uint64_t v___x_7667_;
v___x_7667_ = 0ULL;
v___y_7656_ = v___y_7663_;
v___y_7657_ = v___x_7667_;
goto v___jp_7655_;
}
else
{
v___y_7656_ = v___y_7663_;
v___y_7657_ = v_curTop_7094_;
goto v___jp_7655_;
}
}
}
}

LEAN_EXPORT uint64_t orb_wire_scroll_slice_step(uint64_t v_inPtr_7690_, uint64_t v_inLen_7691_, uint64_t v_outPtr_7692_, uint64_t v_outCap_7693_, uint8_t v_is32Bit_7694_, uint8_t v_opKind_7695_, uint8_t v_pinned_7696_, uint8_t v_intent_7697_, uint8_t v_resized_7698_, uint64_t v_curTop_7699_, uint64_t v_height_7700_, uint64_t v_client_7701_, uint64_t v_arg_7702_){
_start:
{
uint64_t v___x_7703_; uint64_t v___y_7705_; uint32_t v___y_7706_; uint8_t v___y_7715_; uint64_t v___y_7716_; uint64_t v___y_7720_; uint8_t v___y_7721_; uint64_t v___y_7722_; uint64_t v___y_7727_; uint8_t v___y_7728_; uint64_t v___y_7729_; uint64_t v___y_7735_; uint8_t v___y_7736_; uint64_t v___y_7737_; uint64_t v___y_7742_; uint8_t v___y_7743_; uint64_t v___y_7744_; uint64_t v___y_7745_; uint8_t v___y_7746_; uint8_t v___y_7747_; uint8_t v___y_7749_; uint64_t v___y_7750_; uint8_t v___y_7751_; uint64_t v___y_7752_; uint64_t v___y_7753_; uint8_t v___y_7754_; uint8_t v___y_7755_; uint8_t v___y_7756_; uint8_t v___y_7758_; uint8_t v___y_7759_; uint64_t v___y_7768_; uint8_t v___y_7769_; uint64_t v___y_7770_; uint64_t v___y_7775_; uint64_t v___y_7776_; uint8_t v___y_7777_; uint8_t v___y_7778_; uint64_t v___y_7779_; uint8_t v___y_7780_; uint64_t v___y_7782_; uint8_t v___y_7783_; uint64_t v___y_7784_; uint8_t v___y_7785_; uint64_t v___y_7786_; uint8_t v___y_7787_; uint8_t v___y_7788_; uint8_t v___y_7789_; uint64_t v___y_7791_; uint8_t v___y_7792_; uint64_t v___y_7793_; uint64_t v___y_7798_; uint64_t v___y_7799_; uint8_t v___y_7800_; uint64_t v___y_7801_; uint64_t v___y_7807_; uint64_t v___y_7808_; uint8_t v___y_7809_; uint64_t v___y_7810_; uint8_t v___y_7815_; uint64_t v___y_7816_; uint64_t v___y_7817_; uint64_t v___y_7818_; uint64_t v___y_7819_; uint8_t v___y_7820_; uint8_t v___y_7821_; uint64_t v___y_7823_; uint64_t v___y_7824_; uint64_t v___y_7825_; uint64_t v___y_7826_; uint8_t v___y_7827_; uint8_t v___y_7828_; uint8_t v___y_7829_; uint8_t v___y_7830_; uint8_t v___y_7831_; uint8_t v___y_7833_; uint8_t v___y_7834_; uint64_t v___y_7835_; uint8_t v___y_7844_; uint8_t v___y_7845_; uint64_t v___y_7846_; uint8_t v___y_7847_; uint64_t v___y_7848_; uint8_t v___y_7849_; uint8_t v___y_7850_; uint8_t v___y_7851_; uint64_t v___y_7853_; uint8_t v___y_7854_; uint64_t v___y_7855_; uint64_t v___y_7860_; uint8_t v___y_7861_; uint64_t v___y_7862_; uint8_t v___y_7863_; uint64_t v___y_7864_; uint8_t v___y_7865_; uint64_t v___y_7867_; uint64_t v___y_7868_; uint8_t v___y_7869_; uint8_t v___y_7870_; uint64_t v___y_7871_; uint8_t v___y_7872_; uint8_t v___y_7873_; uint8_t v___y_7874_; uint8_t v___y_7876_; uint8_t v___y_7877_; uint8_t v___y_7878_; uint8_t v___y_7907_; uint8_t v___y_7908_; uint8_t v___y_7909_; uint8_t v___y_7910_; uint64_t v___y_7911_; uint8_t v___y_7917_; uint8_t v___y_7918_; uint8_t v___y_7919_; uint64_t v___y_7920_; uint8_t v___y_7921_; uint64_t v___y_7922_; uint8_t v___y_7923_; uint8_t v___y_7924_; uint8_t v___y_7926_; uint8_t v___y_7927_; uint8_t v___y_7928_; uint64_t v___y_7929_; uint8_t v___y_7930_; uint8_t v___y_7931_; uint64_t v___y_7932_; uint8_t v___y_7933_; uint8_t v___y_7934_; uint8_t v___y_7935_; uint8_t v___y_7937_; uint8_t v___y_7938_; uint8_t v___y_7939_; uint8_t v___y_7940_; uint64_t v___y_7941_; uint8_t v___y_7949_; uint8_t v___y_7950_; uint64_t v___y_7951_; uint8_t v___y_7952_; uint8_t v___y_7953_; uint64_t v___y_7954_; uint8_t v___y_7955_; uint8_t v___y_7956_; uint8_t v___y_7958_; uint8_t v___y_7959_; uint64_t v___y_7960_; uint8_t v___y_7961_; uint64_t v___y_7962_; uint8_t v___y_7963_; uint8_t v___y_7964_; uint8_t v___y_7965_; uint8_t v___y_7966_; uint8_t v___y_7967_; uint64_t v___y_7969_; uint8_t v___y_7970_; uint8_t v___y_7971_; uint8_t v___y_7972_; uint8_t v___y_7973_; uint8_t v___y_7974_; uint64_t v___y_7985_; uint8_t v___y_7986_; uint8_t v___y_7987_; uint8_t v___y_7988_; uint8_t v___y_7989_; uint8_t v___y_7990_; uint8_t v___y_7992_; uint8_t v___y_7993_; uint8_t v___y_7994_; uint8_t v___y_7995_; uint8_t v___y_7996_; uint8_t v___y_7997_; uint64_t v___y_7998_; uint8_t v___y_8001_; uint64_t v___y_8002_; uint8_t v___y_8003_; uint8_t v___y_8004_; uint8_t v___y_8005_; uint8_t v___y_8006_; uint8_t v___y_8007_; uint64_t v___y_8008_; uint8_t v___y_8013_; uint64_t v___y_8014_; uint8_t v___y_8015_; uint8_t v___y_8016_; uint8_t v___y_8017_; uint8_t v___y_8018_; uint8_t v___y_8019_; uint64_t v___y_8020_; uint8_t v___y_8026_; uint64_t v___y_8027_; uint8_t v___y_8028_; uint8_t v___y_8029_; uint8_t v___y_8030_; uint8_t v___y_8031_; uint8_t v___y_8032_; uint64_t v___y_8033_; uint8_t v___y_8038_; uint8_t v___y_8039_; uint64_t v___y_8040_; uint8_t v___y_8041_; uint64_t v___y_8042_; uint64_t v___y_8043_; uint8_t v___y_8044_; uint8_t v___y_8045_; uint8_t v___y_8046_; uint8_t v___y_8047_; uint8_t v___y_8048_; uint8_t v___y_8050_; uint64_t v___y_8051_; uint8_t v___y_8052_; uint64_t v___y_8053_; uint64_t v___y_8054_; uint8_t v___y_8055_; uint8_t v___y_8056_; uint8_t v___y_8057_; uint8_t v___y_8058_; uint8_t v___y_8059_; uint8_t v___y_8060_; uint8_t v___y_8061_; uint8_t v___y_8062_; uint8_t v___y_8064_; uint8_t v___y_8065_; uint8_t v___y_8066_; uint8_t v___y_8067_; uint8_t v___y_8068_; uint8_t v___y_8069_; uint8_t v___y_8080_; uint8_t v___y_8081_; uint8_t v___y_8082_; uint8_t v___y_8083_; uint64_t v___y_8084_; uint64_t v___y_8090_; uint8_t v___y_8091_; uint64_t v___y_8092_; uint8_t v___y_8093_; uint8_t v___y_8094_; uint8_t v___y_8095_; uint8_t v___y_8096_; uint8_t v___y_8097_; uint64_t v___y_8099_; uint8_t v___y_8100_; uint64_t v___y_8101_; uint8_t v___y_8102_; uint8_t v___y_8103_; uint8_t v___y_8104_; uint8_t v___y_8105_; uint8_t v___y_8106_; uint8_t v___y_8107_; uint8_t v___y_8108_; uint64_t v___y_8110_; uint8_t v___y_8111_; uint8_t v___y_8112_; uint8_t v___y_8113_; uint8_t v___y_8114_; uint8_t v___y_8115_; uint64_t v___y_8116_; uint64_t v___y_8123_; uint64_t v___y_8124_; uint8_t v___y_8125_; uint8_t v___y_8126_; uint8_t v___y_8127_; uint8_t v___y_8128_; uint8_t v___y_8129_; uint8_t v___y_8130_; uint8_t v___y_8131_; uint64_t v___y_8133_; uint8_t v___y_8134_; uint64_t v___y_8135_; uint8_t v___y_8136_; uint8_t v___y_8137_; uint8_t v___y_8138_; uint8_t v___y_8139_; uint8_t v___y_8140_; uint8_t v___y_8141_; uint8_t v___y_8142_; uint8_t v___y_8143_; uint8_t v___y_8145_; uint8_t v___y_8146_; uint8_t v___y_8147_; uint8_t v___y_8148_; uint8_t v___y_8149_; uint64_t v___y_8150_; uint8_t v___y_8161_; uint8_t v___y_8162_; uint64_t v___y_8163_; uint8_t v___y_8164_; uint8_t v___y_8165_; uint8_t v___y_8166_; uint64_t v___y_8167_; uint8_t v___y_8172_; uint8_t v___y_8173_; uint64_t v___y_8174_; uint8_t v___y_8175_; uint8_t v___y_8176_; uint8_t v___y_8177_; uint64_t v___y_8178_; uint8_t v___y_8184_; uint8_t v___y_8185_; uint64_t v___y_8186_; uint8_t v___y_8187_; uint8_t v___y_8188_; uint8_t v___y_8189_; uint64_t v___y_8190_; uint64_t v___y_8195_; uint8_t v___y_8196_; uint64_t v___y_8197_; uint8_t v___y_8198_; uint64_t v___y_8199_; uint8_t v___y_8200_; uint8_t v___y_8201_; uint8_t v___y_8202_; uint8_t v___y_8203_; uint8_t v___y_8204_; uint64_t v___y_8206_; uint8_t v___y_8207_; uint64_t v___y_8208_; uint8_t v___y_8209_; uint64_t v___y_8210_; uint8_t v___y_8211_; uint8_t v___y_8212_; uint8_t v___y_8213_; uint8_t v___y_8214_; uint8_t v___y_8215_; uint8_t v___y_8216_; uint8_t v___y_8217_; uint8_t v___y_8219_; uint8_t v___y_8220_; uint8_t v___y_8221_; uint8_t v___y_8222_; uint8_t v___y_8223_; uint32_t v___y_8232_; uint32_t v___y_8233_; uint8_t v___y_8234_; uint8_t v___y_8235_; uint8_t v___y_8236_; uint32_t v___y_8259_; uint32_t v___y_8260_; uint8_t v___y_8261_; uint8_t v___y_8262_; uint32_t v___y_8268_; uint32_t v___y_8269_; uint8_t v___y_8270_; uint8_t v___y_8271_; uint32_t v___y_8277_; uint32_t v___y_8278_; uint8_t v___y_8279_; uint8_t v___y_8280_; uint32_t v___y_8286_; uint8_t v___y_8287_; uint8_t v___y_8288_; uint32_t v___y_8289_; uint32_t v___y_8295_; uint8_t v___y_8296_; uint8_t v___y_8297_; uint64_t v___y_8298_; uint8_t v___y_8304_; uint8_t v___y_8305_; uint32_t v___y_8306_; uint8_t v___y_8312_; uint32_t v___y_8313_; uint32_t v___y_8314_; uint8_t v___y_8329_; uint32_t v___y_8330_; uint64_t v___y_8331_; uint8_t v___y_8337_; uint32_t v___y_8338_; uint8_t v___y_8344_; uint8_t v___x_8359_; uint8_t v___x_8360_;
v___x_7703_ = 32ULL;
v___x_8359_ = 1;
v___x_8360_ = lean_uint8_dec_le(v_is32Bit_7694_, v___x_8359_);
if (v___x_8360_ == 0)
{
uint8_t v___x_8361_;
v___x_8361_ = 6;
v___y_8344_ = v___x_8361_;
goto v___jp_8343_;
}
else
{
uint64_t v___x_8362_; uint8_t v___x_8363_; uint8_t v___y_8370_; uint8_t v___y_8373_; uint8_t v___y_8392_; uint8_t v___y_8409_;
v___x_8362_ = 0ULL;
v___x_8363_ = lean_uint64_dec_eq(v_inLen_7691_, v___x_8362_);
if (v___x_8363_ == 0)
{
uint8_t v___x_8413_;
v___x_8413_ = lean_uint64_dec_eq(v_inPtr_7690_, v___x_8362_);
if (v___x_8413_ == 0)
{
v___y_8409_ = v___x_8360_;
goto v___jp_8408_;
}
else
{
uint8_t v___x_8414_;
v___x_8414_ = 7;
v___y_8344_ = v___x_8414_;
goto v___jp_8343_;
}
}
else
{
v___y_8409_ = v___x_8360_;
goto v___jp_8408_;
}
v___jp_8364_:
{
if (v___x_8363_ == 0)
{
uint8_t v___x_8365_;
v___x_8365_ = lean_uint64_dec_eq(v_outCap_7693_, v___x_8362_);
if (v___x_8365_ == 0)
{
uint8_t v___x_8366_;
v___x_8366_ = lean_uint64_dec_le(v_inLen_7691_, v_outPtr_7692_);
if (v___x_8366_ == 0)
{
goto v___jp_8353_;
}
else
{
uint64_t v___x_8367_; uint8_t v___x_8368_;
v___x_8367_ = lean_uint64_sub(v_outPtr_7692_, v_inLen_7691_);
v___x_8368_ = lean_uint64_dec_le(v_inPtr_7690_, v___x_8367_);
if (v___x_8368_ == 0)
{
goto v___jp_8353_;
}
else
{
goto v___jp_8349_;
}
}
}
else
{
goto v___jp_8349_;
}
}
else
{
goto v___jp_8349_;
}
}
v___jp_8369_:
{
if (v___y_8370_ == 0)
{
uint8_t v___x_8371_;
v___x_8371_ = 8;
v___y_8344_ = v___x_8371_;
goto v___jp_8343_;
}
else
{
goto v___jp_8364_;
}
}
v___jp_8372_:
{
if (v___y_8373_ == 0)
{
uint8_t v___x_8374_;
v___x_8374_ = 8;
v___y_8344_ = v___x_8374_;
goto v___jp_8343_;
}
else
{
uint8_t v___x_8375_;
v___x_8375_ = lean_uint8_dec_eq(v_is32Bit_7694_, v___x_8359_);
if (v___x_8375_ == 0)
{
uint8_t v___x_8376_;
v___x_8376_ = lean_uint64_dec_eq(v_outPtr_7692_, v___x_8362_);
if (v___x_8376_ == 0)
{
uint8_t v___x_8377_;
v___x_8377_ = lean_uint64_dec_eq(v_outCap_7693_, v___x_8362_);
if (v___x_8377_ == 0)
{
uint64_t v___x_8378_; uint64_t v___x_8379_; uint64_t v___x_8380_; uint64_t v___x_8381_; uint8_t v___x_8382_;
v___x_8378_ = 1ULL;
v___x_8379_ = lean_uint64_sub(v_outPtr_7692_, v___x_8378_);
v___x_8380_ = 18446744073709551615ULL;
v___x_8381_ = lean_uint64_sub(v___x_8380_, v_outCap_7693_);
v___x_8382_ = lean_uint64_dec_le(v___x_8379_, v___x_8381_);
v___y_8370_ = v___x_8382_;
goto v___jp_8369_;
}
else
{
goto v___jp_8364_;
}
}
else
{
goto v___jp_8364_;
}
}
else
{
uint64_t v___x_8383_; uint8_t v___x_8384_;
v___x_8383_ = 4294967295ULL;
v___x_8384_ = lean_uint64_dec_le(v_outPtr_7692_, v___x_8383_);
if (v___x_8384_ == 0)
{
uint8_t v___x_8385_;
v___x_8385_ = 8;
v___y_8344_ = v___x_8385_;
goto v___jp_8343_;
}
else
{
uint8_t v___x_8386_;
v___x_8386_ = lean_uint64_dec_le(v_outCap_7693_, v___x_8383_);
if (v___x_8386_ == 0)
{
uint8_t v___x_8387_;
v___x_8387_ = 8;
v___y_8344_ = v___x_8387_;
goto v___jp_8343_;
}
else
{
uint64_t v___x_8388_; uint64_t v___x_8389_; uint8_t v___x_8390_;
v___x_8388_ = lean_uint64_add(v_outPtr_7692_, v_outCap_7693_);
v___x_8389_ = 4294967296ULL;
v___x_8390_ = lean_uint64_dec_le(v___x_8388_, v___x_8389_);
v___y_8370_ = v___x_8390_;
goto v___jp_8369_;
}
}
}
}
}
v___jp_8391_:
{
uint8_t v___x_8393_;
v___x_8393_ = lean_uint8_dec_eq(v_is32Bit_7694_, v___x_8359_);
if (v___x_8393_ == 0)
{
uint8_t v___x_8394_;
v___x_8394_ = lean_uint64_dec_eq(v_inPtr_7690_, v___x_8362_);
if (v___x_8394_ == 0)
{
if (v___x_8363_ == 0)
{
uint64_t v___x_8395_; uint64_t v___x_8396_; uint64_t v___x_8397_; uint64_t v___x_8398_; uint8_t v___x_8399_;
v___x_8395_ = 1ULL;
v___x_8396_ = lean_uint64_sub(v_inPtr_7690_, v___x_8395_);
v___x_8397_ = 18446744073709551615ULL;
v___x_8398_ = lean_uint64_sub(v___x_8397_, v_inLen_7691_);
v___x_8399_ = lean_uint64_dec_le(v___x_8396_, v___x_8398_);
v___y_8373_ = v___x_8399_;
goto v___jp_8372_;
}
else
{
v___y_8373_ = v___y_8392_;
goto v___jp_8372_;
}
}
else
{
v___y_8373_ = v___y_8392_;
goto v___jp_8372_;
}
}
else
{
uint64_t v___x_8400_; uint8_t v___x_8401_;
v___x_8400_ = 4294967295ULL;
v___x_8401_ = lean_uint64_dec_le(v_inPtr_7690_, v___x_8400_);
if (v___x_8401_ == 0)
{
uint8_t v___x_8402_;
v___x_8402_ = 8;
v___y_8344_ = v___x_8402_;
goto v___jp_8343_;
}
else
{
uint8_t v___x_8403_;
v___x_8403_ = lean_uint64_dec_le(v_inLen_7691_, v___x_8400_);
if (v___x_8403_ == 0)
{
uint8_t v___x_8404_;
v___x_8404_ = 8;
v___y_8344_ = v___x_8404_;
goto v___jp_8343_;
}
else
{
uint64_t v___x_8405_; uint64_t v___x_8406_; uint8_t v___x_8407_;
v___x_8405_ = lean_uint64_add(v_inPtr_7690_, v_inLen_7691_);
v___x_8406_ = 4294967296ULL;
v___x_8407_ = lean_uint64_dec_le(v___x_8405_, v___x_8406_);
v___y_8373_ = v___x_8407_;
goto v___jp_8372_;
}
}
}
}
v___jp_8408_:
{
uint8_t v___x_8410_;
v___x_8410_ = lean_uint64_dec_eq(v_outCap_7693_, v___x_8362_);
if (v___x_8410_ == 0)
{
uint8_t v___x_8411_;
v___x_8411_ = lean_uint64_dec_eq(v_outPtr_7692_, v___x_8362_);
if (v___x_8411_ == 0)
{
v___y_8392_ = v___y_8409_;
goto v___jp_8391_;
}
else
{
uint8_t v___x_8412_;
v___x_8412_ = 7;
v___y_8344_ = v___x_8412_;
goto v___jp_8343_;
}
}
else
{
v___y_8392_ = v___x_8360_;
goto v___jp_8391_;
}
}
}
v___jp_7704_:
{
uint32_t v___x_7707_; uint32_t v_lo32_7708_; uint32_t v_hi32_7709_; uint64_t v___x_7710_; uint64_t v___x_7711_; uint64_t v___x_7712_; uint64_t v___x_7713_;
v___x_7707_ = 257;
v_lo32_7708_ = lean_uint32_lor(v___x_7707_, v___y_7706_);
v_hi32_7709_ = lean_uint64_to_uint32(v___y_7705_);
v___x_7710_ = lean_uint32_to_uint64(v_lo32_7708_);
v___x_7711_ = lean_uint32_to_uint64(v_hi32_7709_);
v___x_7712_ = lean_uint64_shift_left(v___x_7711_, v___x_7703_);
v___x_7713_ = lean_uint64_lor(v___x_7710_, v___x_7712_);
return v___x_7713_;
}
v___jp_7714_:
{
if (v___y_7715_ == 0)
{
uint32_t v___x_7717_;
v___x_7717_ = 0;
v___y_7705_ = v___y_7716_;
v___y_7706_ = v___x_7717_;
goto v___jp_7704_;
}
else
{
uint32_t v___x_7718_;
v___x_7718_ = 512;
v___y_7705_ = v___y_7716_;
v___y_7706_ = v___x_7718_;
goto v___jp_7704_;
}
}
v___jp_7719_:
{
uint64_t v___x_7723_; uint64_t v___x_7724_; uint8_t v___x_7725_;
v___x_7723_ = 9223372036854775808ULL;
v___x_7724_ = lean_uint64_add(v___y_7722_, v___x_7723_);
v___x_7725_ = lean_uint64_dec_lt(v___x_7723_, v___x_7724_);
if (v___x_7725_ == 0)
{
v___y_7715_ = v___y_7721_;
v___y_7716_ = v___y_7720_;
goto v___jp_7714_;
}
else
{
v___y_7715_ = v___y_7721_;
v___y_7716_ = v___y_7722_;
goto v___jp_7714_;
}
}
v___jp_7726_:
{
uint64_t v___x_7730_; uint64_t v___x_7731_; uint64_t v___x_7732_; uint8_t v___x_7733_;
v___x_7730_ = 9223372036854775808ULL;
v___x_7731_ = lean_uint64_add(v_arg_7702_, v___x_7730_);
v___x_7732_ = lean_uint64_add(v___y_7729_, v___x_7730_);
v___x_7733_ = lean_uint64_dec_le(v___x_7731_, v___x_7732_);
if (v___x_7733_ == 0)
{
v___y_7720_ = v___y_7727_;
v___y_7721_ = v___y_7728_;
v___y_7722_ = v___y_7729_;
goto v___jp_7719_;
}
else
{
v___y_7720_ = v___y_7727_;
v___y_7721_ = v___y_7728_;
v___y_7722_ = v_arg_7702_;
goto v___jp_7719_;
}
}
v___jp_7734_:
{
uint64_t v___x_7738_; uint64_t v___x_7739_; uint8_t v___x_7740_;
v___x_7738_ = 9223372036854775808ULL;
v___x_7739_ = lean_uint64_add(v___y_7737_, v___x_7738_);
v___x_7740_ = lean_uint64_dec_lt(v___x_7738_, v___x_7739_);
if (v___x_7740_ == 0)
{
v___y_7727_ = v___y_7735_;
v___y_7728_ = v___y_7736_;
v___y_7729_ = v___y_7735_;
goto v___jp_7726_;
}
else
{
v___y_7727_ = v___y_7735_;
v___y_7728_ = v___y_7736_;
v___y_7729_ = v___y_7737_;
goto v___jp_7726_;
}
}
v___jp_7741_:
{
if (v___y_7743_ == 0)
{
v___y_7735_ = v___y_7745_;
v___y_7736_ = v___y_7746_;
v___y_7737_ = v___y_7742_;
goto v___jp_7734_;
}
else
{
if (v___y_7747_ == 0)
{
v___y_7735_ = v___y_7745_;
v___y_7736_ = v___y_7746_;
v___y_7737_ = v___y_7744_;
goto v___jp_7734_;
}
else
{
v___y_7735_ = v___y_7745_;
v___y_7736_ = v___y_7746_;
v___y_7737_ = v___y_7742_;
goto v___jp_7734_;
}
}
}
v___jp_7748_:
{
if (v___y_7755_ == 0)
{
v___y_7735_ = v___y_7753_;
v___y_7736_ = v___y_7754_;
v___y_7737_ = v___y_7752_;
goto v___jp_7734_;
}
else
{
if (v___y_7749_ == 0)
{
v___y_7742_ = v___y_7750_;
v___y_7743_ = v___y_7751_;
v___y_7744_ = v___y_7752_;
v___y_7745_ = v___y_7753_;
v___y_7746_ = v___y_7754_;
v___y_7747_ = v___y_7756_;
goto v___jp_7741_;
}
else
{
if (v___y_7756_ == 0)
{
v___y_7735_ = v___y_7753_;
v___y_7736_ = v___y_7754_;
v___y_7737_ = v___y_7752_;
goto v___jp_7734_;
}
else
{
v___y_7742_ = v___y_7750_;
v___y_7743_ = v___y_7751_;
v___y_7744_ = v___y_7752_;
v___y_7745_ = v___y_7753_;
v___y_7746_ = v___y_7754_;
v___y_7747_ = v___y_7756_;
goto v___jp_7741_;
}
}
}
}
v___jp_7757_:
{
uint64_t v___x_7760_; uint64_t v_diff_7761_; uint64_t v___x_7762_; uint8_t v_aNeg_7763_; uint8_t v_bNeg_7764_; uint8_t v_dNeg_7765_;
v___x_7760_ = 0ULL;
v_diff_7761_ = lean_uint64_sub(v_height_7700_, v_client_7701_);
v___x_7762_ = 9223372036854775808ULL;
v_aNeg_7763_ = lean_uint64_dec_le(v___x_7762_, v_height_7700_);
v_bNeg_7764_ = lean_uint64_dec_le(v___x_7762_, v_client_7701_);
v_dNeg_7765_ = lean_uint64_dec_le(v___x_7762_, v_diff_7761_);
if (v_aNeg_7763_ == 0)
{
if (v_bNeg_7764_ == 0)
{
v___y_7749_ = v_bNeg_7764_;
v___y_7750_ = v___x_7762_;
v___y_7751_ = v_dNeg_7765_;
v___y_7752_ = v_diff_7761_;
v___y_7753_ = v___x_7760_;
v___y_7754_ = v___y_7759_;
v___y_7755_ = v_aNeg_7763_;
v___y_7756_ = v_bNeg_7764_;
goto v___jp_7748_;
}
else
{
if (v_dNeg_7765_ == 0)
{
v___y_7749_ = v_bNeg_7764_;
v___y_7750_ = v___x_7762_;
v___y_7751_ = v_dNeg_7765_;
v___y_7752_ = v_diff_7761_;
v___y_7753_ = v___x_7760_;
v___y_7754_ = v___y_7759_;
v___y_7755_ = v_aNeg_7763_;
v___y_7756_ = v_dNeg_7765_;
goto v___jp_7748_;
}
else
{
uint64_t v___x_7766_;
v___x_7766_ = 9223372036854775807ULL;
v___y_7735_ = v___x_7760_;
v___y_7736_ = v___y_7759_;
v___y_7737_ = v___x_7766_;
goto v___jp_7734_;
}
}
}
else
{
v___y_7749_ = v_bNeg_7764_;
v___y_7750_ = v___x_7762_;
v___y_7751_ = v_dNeg_7765_;
v___y_7752_ = v_diff_7761_;
v___y_7753_ = v___x_7760_;
v___y_7754_ = v___y_7759_;
v___y_7755_ = v_aNeg_7763_;
v___y_7756_ = v___y_7758_;
goto v___jp_7748_;
}
}
v___jp_7767_:
{
uint64_t v___x_7771_; uint64_t v___x_7772_; uint8_t v___x_7773_;
v___x_7771_ = 9223372036854775808ULL;
v___x_7772_ = lean_uint64_add(v___y_7770_, v___x_7771_);
v___x_7773_ = lean_uint64_dec_lt(v___x_7771_, v___x_7772_);
if (v___x_7773_ == 0)
{
v___y_7715_ = v___y_7769_;
v___y_7716_ = v___y_7768_;
goto v___jp_7714_;
}
else
{
v___y_7715_ = v___y_7769_;
v___y_7716_ = v___y_7770_;
goto v___jp_7714_;
}
}
v___jp_7774_:
{
if (v___y_7777_ == 0)
{
v___y_7768_ = v___y_7775_;
v___y_7769_ = v___y_7780_;
v___y_7770_ = v___y_7779_;
goto v___jp_7767_;
}
else
{
if (v___y_7778_ == 0)
{
v___y_7768_ = v___y_7775_;
v___y_7769_ = v___y_7780_;
v___y_7770_ = v___y_7776_;
goto v___jp_7767_;
}
else
{
v___y_7768_ = v___y_7775_;
v___y_7769_ = v___y_7780_;
v___y_7770_ = v___y_7779_;
goto v___jp_7767_;
}
}
}
v___jp_7781_:
{
if (v___y_7785_ == 0)
{
v___y_7768_ = v___y_7782_;
v___y_7769_ = v___y_7787_;
v___y_7770_ = v___y_7784_;
goto v___jp_7767_;
}
else
{
if (v___y_7788_ == 0)
{
v___y_7775_ = v___y_7782_;
v___y_7776_ = v___y_7784_;
v___y_7777_ = v___y_7783_;
v___y_7778_ = v___y_7789_;
v___y_7779_ = v___y_7786_;
v___y_7780_ = v___y_7787_;
goto v___jp_7774_;
}
else
{
if (v___y_7789_ == 0)
{
v___y_7768_ = v___y_7782_;
v___y_7769_ = v___y_7787_;
v___y_7770_ = v___y_7784_;
goto v___jp_7767_;
}
else
{
v___y_7775_ = v___y_7782_;
v___y_7776_ = v___y_7784_;
v___y_7777_ = v___y_7783_;
v___y_7778_ = v___y_7789_;
v___y_7779_ = v___y_7786_;
v___y_7780_ = v___y_7787_;
goto v___jp_7774_;
}
}
}
}
v___jp_7790_:
{
uint64_t v___x_7794_; uint64_t v___x_7795_; uint8_t v___x_7796_;
v___x_7794_ = 9223372036854775808ULL;
v___x_7795_ = lean_uint64_add(v___y_7793_, v___x_7794_);
v___x_7796_ = lean_uint64_dec_lt(v___x_7794_, v___x_7795_);
if (v___x_7796_ == 0)
{
v___y_7715_ = v___y_7792_;
v___y_7716_ = v___y_7791_;
goto v___jp_7714_;
}
else
{
v___y_7715_ = v___y_7792_;
v___y_7716_ = v___y_7793_;
goto v___jp_7714_;
}
}
v___jp_7797_:
{
uint64_t v___x_7802_; uint64_t v___x_7803_; uint64_t v___x_7804_; uint8_t v___x_7805_;
v___x_7802_ = 9223372036854775808ULL;
v___x_7803_ = lean_uint64_add(v___y_7799_, v___x_7802_);
v___x_7804_ = lean_uint64_add(v___y_7801_, v___x_7802_);
v___x_7805_ = lean_uint64_dec_le(v___x_7803_, v___x_7804_);
if (v___x_7805_ == 0)
{
v___y_7791_ = v___y_7798_;
v___y_7792_ = v___y_7800_;
v___y_7793_ = v___y_7801_;
goto v___jp_7790_;
}
else
{
v___y_7791_ = v___y_7798_;
v___y_7792_ = v___y_7800_;
v___y_7793_ = v___y_7799_;
goto v___jp_7790_;
}
}
v___jp_7806_:
{
uint64_t v___x_7811_; uint64_t v___x_7812_; uint8_t v___x_7813_;
v___x_7811_ = 9223372036854775808ULL;
v___x_7812_ = lean_uint64_add(v___y_7810_, v___x_7811_);
v___x_7813_ = lean_uint64_dec_lt(v___x_7811_, v___x_7812_);
if (v___x_7813_ == 0)
{
v___y_7798_ = v___y_7807_;
v___y_7799_ = v___y_7808_;
v___y_7800_ = v___y_7809_;
v___y_7801_ = v___y_7807_;
goto v___jp_7797_;
}
else
{
v___y_7798_ = v___y_7807_;
v___y_7799_ = v___y_7808_;
v___y_7800_ = v___y_7809_;
v___y_7801_ = v___y_7810_;
goto v___jp_7797_;
}
}
v___jp_7814_:
{
if (v___y_7820_ == 0)
{
v___y_7807_ = v___y_7817_;
v___y_7808_ = v___y_7819_;
v___y_7809_ = v___y_7821_;
v___y_7810_ = v___y_7818_;
goto v___jp_7806_;
}
else
{
if (v___y_7815_ == 0)
{
v___y_7807_ = v___y_7817_;
v___y_7808_ = v___y_7819_;
v___y_7809_ = v___y_7821_;
v___y_7810_ = v___y_7816_;
goto v___jp_7806_;
}
else
{
v___y_7807_ = v___y_7817_;
v___y_7808_ = v___y_7819_;
v___y_7809_ = v___y_7821_;
v___y_7810_ = v___y_7818_;
goto v___jp_7806_;
}
}
}
v___jp_7822_:
{
if (v___y_7828_ == 0)
{
v___y_7807_ = v___y_7824_;
v___y_7808_ = v___y_7826_;
v___y_7809_ = v___y_7829_;
v___y_7810_ = v___y_7825_;
goto v___jp_7806_;
}
else
{
if (v___y_7830_ == 0)
{
v___y_7815_ = v___y_7831_;
v___y_7816_ = v___y_7825_;
v___y_7817_ = v___y_7824_;
v___y_7818_ = v___y_7823_;
v___y_7819_ = v___y_7826_;
v___y_7820_ = v___y_7827_;
v___y_7821_ = v___y_7829_;
goto v___jp_7814_;
}
else
{
if (v___y_7831_ == 0)
{
v___y_7807_ = v___y_7824_;
v___y_7808_ = v___y_7826_;
v___y_7809_ = v___y_7829_;
v___y_7810_ = v___y_7825_;
goto v___jp_7806_;
}
else
{
v___y_7815_ = v___y_7831_;
v___y_7816_ = v___y_7825_;
v___y_7817_ = v___y_7824_;
v___y_7818_ = v___y_7823_;
v___y_7819_ = v___y_7826_;
v___y_7820_ = v___y_7827_;
v___y_7821_ = v___y_7829_;
goto v___jp_7814_;
}
}
}
}
v___jp_7832_:
{
uint64_t v___x_7836_; uint64_t v_diff_7837_; uint64_t v___x_7838_; uint8_t v_aNeg_7839_; uint8_t v_bNeg_7840_; uint8_t v_dNeg_7841_;
v___x_7836_ = 0ULL;
v_diff_7837_ = lean_uint64_sub(v_height_7700_, v_client_7701_);
v___x_7838_ = 9223372036854775808ULL;
v_aNeg_7839_ = lean_uint64_dec_le(v___x_7838_, v_height_7700_);
v_bNeg_7840_ = lean_uint64_dec_le(v___x_7838_, v_client_7701_);
v_dNeg_7841_ = lean_uint64_dec_le(v___x_7838_, v_diff_7837_);
if (v_aNeg_7839_ == 0)
{
if (v_bNeg_7840_ == 0)
{
v___y_7823_ = v___x_7838_;
v___y_7824_ = v___x_7836_;
v___y_7825_ = v_diff_7837_;
v___y_7826_ = v___y_7835_;
v___y_7827_ = v_dNeg_7841_;
v___y_7828_ = v_aNeg_7839_;
v___y_7829_ = v___y_7834_;
v___y_7830_ = v_bNeg_7840_;
v___y_7831_ = v_bNeg_7840_;
goto v___jp_7822_;
}
else
{
if (v_dNeg_7841_ == 0)
{
v___y_7823_ = v___x_7838_;
v___y_7824_ = v___x_7836_;
v___y_7825_ = v_diff_7837_;
v___y_7826_ = v___y_7835_;
v___y_7827_ = v_dNeg_7841_;
v___y_7828_ = v_aNeg_7839_;
v___y_7829_ = v___y_7834_;
v___y_7830_ = v_bNeg_7840_;
v___y_7831_ = v_dNeg_7841_;
goto v___jp_7822_;
}
else
{
uint64_t v___x_7842_;
v___x_7842_ = 9223372036854775807ULL;
v___y_7807_ = v___x_7836_;
v___y_7808_ = v___y_7835_;
v___y_7809_ = v___y_7834_;
v___y_7810_ = v___x_7842_;
goto v___jp_7806_;
}
}
}
else
{
v___y_7823_ = v___x_7838_;
v___y_7824_ = v___x_7836_;
v___y_7825_ = v_diff_7837_;
v___y_7826_ = v___y_7835_;
v___y_7827_ = v_dNeg_7841_;
v___y_7828_ = v_aNeg_7839_;
v___y_7829_ = v___y_7834_;
v___y_7830_ = v_bNeg_7840_;
v___y_7831_ = v___y_7833_;
goto v___jp_7822_;
}
}
v___jp_7843_:
{
if (v___y_7845_ == 0)
{
v___y_7833_ = v___y_7847_;
v___y_7834_ = v___y_7849_;
v___y_7835_ = v___y_7848_;
goto v___jp_7832_;
}
else
{
if (v___y_7850_ == 0)
{
v___y_7833_ = v___y_7847_;
v___y_7834_ = v___y_7849_;
v___y_7835_ = v___y_7848_;
goto v___jp_7832_;
}
else
{
if (v___y_7844_ == 0)
{
v___y_7833_ = v___y_7847_;
v___y_7834_ = v___y_7849_;
v___y_7835_ = v___y_7846_;
goto v___jp_7832_;
}
else
{
if (v___y_7851_ == 0)
{
v___y_7833_ = v___y_7847_;
v___y_7834_ = v___y_7849_;
v___y_7835_ = v___y_7848_;
goto v___jp_7832_;
}
else
{
v___y_7833_ = v___y_7847_;
v___y_7834_ = v___y_7849_;
v___y_7835_ = v___y_7846_;
goto v___jp_7832_;
}
}
}
}
}
v___jp_7852_:
{
uint64_t v___x_7856_; uint64_t v___x_7857_; uint8_t v___x_7858_;
v___x_7856_ = 9223372036854775808ULL;
v___x_7857_ = lean_uint64_add(v___y_7855_, v___x_7856_);
v___x_7858_ = lean_uint64_dec_lt(v___x_7856_, v___x_7857_);
if (v___x_7858_ == 0)
{
v___y_7715_ = v___y_7854_;
v___y_7716_ = v___y_7853_;
goto v___jp_7714_;
}
else
{
v___y_7715_ = v___y_7854_;
v___y_7716_ = v___y_7855_;
goto v___jp_7714_;
}
}
v___jp_7859_:
{
if (v___y_7865_ == 0)
{
v___y_7853_ = v___y_7860_;
v___y_7854_ = v___y_7863_;
v___y_7855_ = v___y_7864_;
goto v___jp_7852_;
}
else
{
if (v___y_7861_ == 0)
{
v___y_7853_ = v___y_7860_;
v___y_7854_ = v___y_7863_;
v___y_7855_ = v___y_7862_;
goto v___jp_7852_;
}
else
{
v___y_7853_ = v___y_7860_;
v___y_7854_ = v___y_7863_;
v___y_7855_ = v___y_7864_;
goto v___jp_7852_;
}
}
}
v___jp_7866_:
{
if (v___y_7869_ == 0)
{
v___y_7853_ = v___y_7867_;
v___y_7854_ = v___y_7872_;
v___y_7855_ = v___y_7868_;
goto v___jp_7852_;
}
else
{
if (v___y_7870_ == 0)
{
v___y_7860_ = v___y_7867_;
v___y_7861_ = v___y_7874_;
v___y_7862_ = v___y_7868_;
v___y_7863_ = v___y_7872_;
v___y_7864_ = v___y_7871_;
v___y_7865_ = v___y_7873_;
goto v___jp_7859_;
}
else
{
if (v___y_7874_ == 0)
{
v___y_7853_ = v___y_7867_;
v___y_7854_ = v___y_7872_;
v___y_7855_ = v___y_7868_;
goto v___jp_7852_;
}
else
{
v___y_7860_ = v___y_7867_;
v___y_7861_ = v___y_7874_;
v___y_7862_ = v___y_7868_;
v___y_7863_ = v___y_7872_;
v___y_7864_ = v___y_7871_;
v___y_7865_ = v___y_7873_;
goto v___jp_7859_;
}
}
}
}
v___jp_7875_:
{
uint8_t v___x_7879_;
v___x_7879_ = lean_uint8_dec_eq(v_opKind_7695_, v___y_7876_);
if (v___x_7879_ == 0)
{
uint8_t v___x_7880_; uint8_t v___x_7881_;
v___x_7880_ = 1;
v___x_7881_ = lean_uint8_dec_eq(v_opKind_7695_, v___x_7880_);
if (v___x_7881_ == 0)
{
uint8_t v___x_7882_; uint8_t v___x_7883_;
v___x_7882_ = 2;
v___x_7883_ = lean_uint8_dec_eq(v_opKind_7695_, v___x_7882_);
if (v___x_7883_ == 0)
{
uint64_t v___x_7884_; uint64_t v_diff_7885_; uint64_t v___x_7886_; uint8_t v_aNeg_7887_; uint8_t v_bNeg_7888_; uint8_t v_dNeg_7889_;
v___x_7884_ = 0ULL;
v_diff_7885_ = lean_uint64_sub(v_height_7700_, v_client_7701_);
v___x_7886_ = 9223372036854775808ULL;
v_aNeg_7887_ = lean_uint64_dec_le(v___x_7886_, v_height_7700_);
v_bNeg_7888_ = lean_uint64_dec_le(v___x_7886_, v_client_7701_);
v_dNeg_7889_ = lean_uint64_dec_le(v___x_7886_, v_diff_7885_);
if (v_aNeg_7887_ == 0)
{
if (v_bNeg_7888_ == 0)
{
v___y_7782_ = v___x_7884_;
v___y_7783_ = v_dNeg_7889_;
v___y_7784_ = v_diff_7885_;
v___y_7785_ = v_aNeg_7887_;
v___y_7786_ = v___x_7886_;
v___y_7787_ = v___y_7878_;
v___y_7788_ = v_bNeg_7888_;
v___y_7789_ = v_bNeg_7888_;
goto v___jp_7781_;
}
else
{
if (v_dNeg_7889_ == 0)
{
v___y_7782_ = v___x_7884_;
v___y_7783_ = v_dNeg_7889_;
v___y_7784_ = v_diff_7885_;
v___y_7785_ = v_aNeg_7887_;
v___y_7786_ = v___x_7886_;
v___y_7787_ = v___y_7878_;
v___y_7788_ = v_bNeg_7888_;
v___y_7789_ = v_dNeg_7889_;
goto v___jp_7781_;
}
else
{
uint64_t v___x_7890_;
v___x_7890_ = 9223372036854775807ULL;
v___y_7768_ = v___x_7884_;
v___y_7769_ = v___y_7878_;
v___y_7770_ = v___x_7890_;
goto v___jp_7767_;
}
}
}
else
{
v___y_7782_ = v___x_7884_;
v___y_7783_ = v_dNeg_7889_;
v___y_7784_ = v_diff_7885_;
v___y_7785_ = v_aNeg_7887_;
v___y_7786_ = v___x_7886_;
v___y_7787_ = v___y_7878_;
v___y_7788_ = v_bNeg_7888_;
v___y_7789_ = v___x_7883_;
goto v___jp_7781_;
}
}
else
{
v___y_7758_ = v___x_7879_;
v___y_7759_ = v___y_7878_;
goto v___jp_7757_;
}
}
else
{
v___y_7758_ = v___x_7879_;
v___y_7759_ = v___y_7878_;
goto v___jp_7757_;
}
}
else
{
uint8_t v___x_7891_; uint8_t v___x_7892_;
v___x_7891_ = 1;
v___x_7892_ = lean_uint8_dec_eq(v_pinned_7696_, v___x_7891_);
if (v___x_7892_ == 0)
{
uint64_t v_sum_7893_; uint64_t v___x_7894_; uint8_t v_aNeg_7895_; uint8_t v_bNeg_7896_; uint8_t v_sNeg_7897_;
v_sum_7893_ = lean_uint64_add(v_curTop_7699_, v_arg_7702_);
v___x_7894_ = 9223372036854775808ULL;
v_aNeg_7895_ = lean_uint64_dec_le(v___x_7894_, v_curTop_7699_);
v_bNeg_7896_ = lean_uint64_dec_le(v___x_7894_, v_arg_7702_);
v_sNeg_7897_ = lean_uint64_dec_le(v___x_7894_, v_sum_7893_);
if (v_aNeg_7895_ == 0)
{
if (v_bNeg_7896_ == 0)
{
if (v_sNeg_7897_ == 0)
{
v___y_7844_ = v_sNeg_7897_;
v___y_7845_ = v_aNeg_7895_;
v___y_7846_ = v___x_7894_;
v___y_7847_ = v___x_7892_;
v___y_7848_ = v_sum_7893_;
v___y_7849_ = v___y_7878_;
v___y_7850_ = v_bNeg_7896_;
v___y_7851_ = v_sNeg_7897_;
goto v___jp_7843_;
}
else
{
uint64_t v___x_7898_;
v___x_7898_ = 9223372036854775807ULL;
v___y_7833_ = v___x_7892_;
v___y_7834_ = v___y_7878_;
v___y_7835_ = v___x_7898_;
goto v___jp_7832_;
}
}
else
{
v___y_7844_ = v_sNeg_7897_;
v___y_7845_ = v_aNeg_7895_;
v___y_7846_ = v___x_7894_;
v___y_7847_ = v___x_7892_;
v___y_7848_ = v_sum_7893_;
v___y_7849_ = v___y_7878_;
v___y_7850_ = v_bNeg_7896_;
v___y_7851_ = v_aNeg_7895_;
goto v___jp_7843_;
}
}
else
{
v___y_7844_ = v_sNeg_7897_;
v___y_7845_ = v_aNeg_7895_;
v___y_7846_ = v___x_7894_;
v___y_7847_ = v___x_7892_;
v___y_7848_ = v_sum_7893_;
v___y_7849_ = v___y_7878_;
v___y_7850_ = v_bNeg_7896_;
v___y_7851_ = v___x_7892_;
goto v___jp_7843_;
}
}
else
{
uint64_t v___x_7899_; uint64_t v_diff_7900_; uint64_t v___x_7901_; uint8_t v_aNeg_7902_; uint8_t v_bNeg_7903_; uint8_t v_dNeg_7904_;
v___x_7899_ = 0ULL;
v_diff_7900_ = lean_uint64_sub(v_height_7700_, v_client_7701_);
v___x_7901_ = 9223372036854775808ULL;
v_aNeg_7902_ = lean_uint64_dec_le(v___x_7901_, v_height_7700_);
v_bNeg_7903_ = lean_uint64_dec_le(v___x_7901_, v_client_7701_);
v_dNeg_7904_ = lean_uint64_dec_le(v___x_7901_, v_diff_7900_);
if (v_aNeg_7902_ == 0)
{
if (v_bNeg_7903_ == 0)
{
v___y_7867_ = v___x_7899_;
v___y_7868_ = v_diff_7900_;
v___y_7869_ = v_aNeg_7902_;
v___y_7870_ = v_bNeg_7903_;
v___y_7871_ = v___x_7901_;
v___y_7872_ = v___y_7878_;
v___y_7873_ = v_dNeg_7904_;
v___y_7874_ = v_bNeg_7903_;
goto v___jp_7866_;
}
else
{
if (v_dNeg_7904_ == 0)
{
v___y_7867_ = v___x_7899_;
v___y_7868_ = v_diff_7900_;
v___y_7869_ = v_aNeg_7902_;
v___y_7870_ = v_bNeg_7903_;
v___y_7871_ = v___x_7901_;
v___y_7872_ = v___y_7878_;
v___y_7873_ = v_dNeg_7904_;
v___y_7874_ = v_dNeg_7904_;
goto v___jp_7866_;
}
else
{
uint64_t v___x_7905_;
v___x_7905_ = 9223372036854775807ULL;
v___y_7853_ = v___x_7899_;
v___y_7854_ = v___y_7878_;
v___y_7855_ = v___x_7905_;
goto v___jp_7852_;
}
}
}
else
{
v___y_7867_ = v___x_7899_;
v___y_7868_ = v_diff_7900_;
v___y_7869_ = v_aNeg_7902_;
v___y_7870_ = v_bNeg_7903_;
v___y_7871_ = v___x_7901_;
v___y_7872_ = v___y_7878_;
v___y_7873_ = v_dNeg_7904_;
v___y_7874_ = v___y_7877_;
goto v___jp_7866_;
}
}
}
}
v___jp_7906_:
{
uint64_t v___x_7912_; uint64_t v___x_7913_; uint64_t v___x_7914_; uint8_t v___x_7915_;
v___x_7912_ = 9223372036854775808ULL;
v___x_7913_ = 9223372036854775832ULL;
v___x_7914_ = lean_uint64_add(v___y_7911_, v___x_7912_);
v___x_7915_ = lean_uint64_dec_le(v___x_7913_, v___x_7914_);
if (v___x_7915_ == 0)
{
v___y_7876_ = v___y_7908_;
v___y_7877_ = v___y_7910_;
v___y_7878_ = v___y_7909_;
goto v___jp_7875_;
}
else
{
v___y_7876_ = v___y_7908_;
v___y_7877_ = v___y_7910_;
v___y_7878_ = v___y_7907_;
goto v___jp_7875_;
}
}
v___jp_7916_:
{
if (v___y_7918_ == 0)
{
v___y_7907_ = v___y_7917_;
v___y_7908_ = v___y_7921_;
v___y_7909_ = v___y_7923_;
v___y_7910_ = v___y_7924_;
v___y_7911_ = v___y_7920_;
goto v___jp_7906_;
}
else
{
if (v___y_7919_ == 0)
{
v___y_7907_ = v___y_7917_;
v___y_7908_ = v___y_7921_;
v___y_7909_ = v___y_7923_;
v___y_7910_ = v___y_7924_;
v___y_7911_ = v___y_7922_;
goto v___jp_7906_;
}
else
{
v___y_7907_ = v___y_7917_;
v___y_7908_ = v___y_7921_;
v___y_7909_ = v___y_7923_;
v___y_7910_ = v___y_7924_;
v___y_7911_ = v___y_7920_;
goto v___jp_7906_;
}
}
}
v___jp_7925_:
{
if (v___y_7926_ == 0)
{
v___y_7907_ = v___y_7928_;
v___y_7908_ = v___y_7931_;
v___y_7909_ = v___y_7933_;
v___y_7910_ = v___y_7934_;
v___y_7911_ = v___y_7932_;
goto v___jp_7906_;
}
else
{
if (v___y_7930_ == 0)
{
v___y_7917_ = v___y_7928_;
v___y_7918_ = v___y_7927_;
v___y_7919_ = v___y_7935_;
v___y_7920_ = v___y_7929_;
v___y_7921_ = v___y_7931_;
v___y_7922_ = v___y_7932_;
v___y_7923_ = v___y_7933_;
v___y_7924_ = v___y_7934_;
goto v___jp_7916_;
}
else
{
if (v___y_7935_ == 0)
{
v___y_7907_ = v___y_7928_;
v___y_7908_ = v___y_7931_;
v___y_7909_ = v___y_7933_;
v___y_7910_ = v___y_7934_;
v___y_7911_ = v___y_7932_;
goto v___jp_7906_;
}
else
{
v___y_7917_ = v___y_7928_;
v___y_7918_ = v___y_7927_;
v___y_7919_ = v___y_7935_;
v___y_7920_ = v___y_7929_;
v___y_7921_ = v___y_7931_;
v___y_7922_ = v___y_7932_;
v___y_7923_ = v___y_7933_;
v___y_7924_ = v___y_7934_;
goto v___jp_7916_;
}
}
}
}
v___jp_7936_:
{
uint64_t v_diff_7942_; uint64_t v___x_7943_; uint8_t v_aNeg_7944_; uint8_t v_bNeg_7945_; uint8_t v_dNeg_7946_;
v_diff_7942_ = lean_uint64_sub(v___y_7941_, v_client_7701_);
v___x_7943_ = 9223372036854775808ULL;
v_aNeg_7944_ = lean_uint64_dec_le(v___x_7943_, v___y_7941_);
v_bNeg_7945_ = lean_uint64_dec_le(v___x_7943_, v_client_7701_);
v_dNeg_7946_ = lean_uint64_dec_le(v___x_7943_, v_diff_7942_);
if (v_aNeg_7944_ == 0)
{
if (v_bNeg_7945_ == 0)
{
v___y_7926_ = v_aNeg_7944_;
v___y_7927_ = v_dNeg_7946_;
v___y_7928_ = v___y_7937_;
v___y_7929_ = v___x_7943_;
v___y_7930_ = v_bNeg_7945_;
v___y_7931_ = v___y_7938_;
v___y_7932_ = v_diff_7942_;
v___y_7933_ = v___y_7939_;
v___y_7934_ = v___y_7940_;
v___y_7935_ = v_bNeg_7945_;
goto v___jp_7925_;
}
else
{
if (v_dNeg_7946_ == 0)
{
v___y_7926_ = v_aNeg_7944_;
v___y_7927_ = v_dNeg_7946_;
v___y_7928_ = v___y_7937_;
v___y_7929_ = v___x_7943_;
v___y_7930_ = v_bNeg_7945_;
v___y_7931_ = v___y_7938_;
v___y_7932_ = v_diff_7942_;
v___y_7933_ = v___y_7939_;
v___y_7934_ = v___y_7940_;
v___y_7935_ = v_dNeg_7946_;
goto v___jp_7925_;
}
else
{
uint64_t v___x_7947_;
v___x_7947_ = 9223372036854775807ULL;
v___y_7907_ = v___y_7937_;
v___y_7908_ = v___y_7938_;
v___y_7909_ = v___y_7939_;
v___y_7910_ = v___y_7940_;
v___y_7911_ = v___x_7947_;
goto v___jp_7906_;
}
}
}
else
{
v___y_7926_ = v_aNeg_7944_;
v___y_7927_ = v_dNeg_7946_;
v___y_7928_ = v___y_7937_;
v___y_7929_ = v___x_7943_;
v___y_7930_ = v_bNeg_7945_;
v___y_7931_ = v___y_7938_;
v___y_7932_ = v_diff_7942_;
v___y_7933_ = v___y_7939_;
v___y_7934_ = v___y_7940_;
v___y_7935_ = v___y_7937_;
goto v___jp_7925_;
}
}
v___jp_7948_:
{
if (v___y_7952_ == 0)
{
v___y_7937_ = v___y_7950_;
v___y_7938_ = v___y_7953_;
v___y_7939_ = v___y_7955_;
v___y_7940_ = v___y_7956_;
v___y_7941_ = v___y_7954_;
goto v___jp_7936_;
}
else
{
if (v___y_7949_ == 0)
{
v___y_7937_ = v___y_7950_;
v___y_7938_ = v___y_7953_;
v___y_7939_ = v___y_7955_;
v___y_7940_ = v___y_7956_;
v___y_7941_ = v___y_7951_;
goto v___jp_7936_;
}
else
{
v___y_7937_ = v___y_7950_;
v___y_7938_ = v___y_7953_;
v___y_7939_ = v___y_7955_;
v___y_7940_ = v___y_7956_;
v___y_7941_ = v___y_7954_;
goto v___jp_7936_;
}
}
}
v___jp_7957_:
{
if (v___y_7958_ == 0)
{
v___y_7937_ = v___y_7959_;
v___y_7938_ = v___y_7963_;
v___y_7939_ = v___y_7965_;
v___y_7940_ = v___y_7966_;
v___y_7941_ = v___y_7960_;
goto v___jp_7936_;
}
else
{
if (v___y_7964_ == 0)
{
v___y_7949_ = v___y_7967_;
v___y_7950_ = v___y_7959_;
v___y_7951_ = v___y_7960_;
v___y_7952_ = v___y_7961_;
v___y_7953_ = v___y_7963_;
v___y_7954_ = v___y_7962_;
v___y_7955_ = v___y_7965_;
v___y_7956_ = v___y_7966_;
goto v___jp_7948_;
}
else
{
if (v___y_7967_ == 0)
{
v___y_7937_ = v___y_7959_;
v___y_7938_ = v___y_7963_;
v___y_7939_ = v___y_7965_;
v___y_7940_ = v___y_7966_;
v___y_7941_ = v___y_7960_;
goto v___jp_7936_;
}
else
{
v___y_7949_ = v___y_7967_;
v___y_7950_ = v___y_7959_;
v___y_7951_ = v___y_7960_;
v___y_7952_ = v___y_7961_;
v___y_7953_ = v___y_7963_;
v___y_7954_ = v___y_7962_;
v___y_7955_ = v___y_7965_;
v___y_7956_ = v___y_7966_;
goto v___jp_7948_;
}
}
}
}
v___jp_7968_:
{
if (v___y_7974_ == 0)
{
v___y_7876_ = v___y_7971_;
v___y_7877_ = v___y_7973_;
v___y_7878_ = v___y_7972_;
goto v___jp_7875_;
}
else
{
uint64_t v___x_7975_; uint64_t v___x_7976_; uint64_t v___x_7977_; uint8_t v___x_7978_;
v___x_7975_ = 9223372036854775808ULL;
v___x_7976_ = lean_uint64_add(v___y_7969_, v___x_7975_);
v___x_7977_ = lean_uint64_add(v_curTop_7699_, v___x_7975_);
v___x_7978_ = lean_uint64_dec_lt(v___x_7976_, v___x_7977_);
if (v___x_7978_ == 0)
{
v___y_7876_ = v___y_7971_;
v___y_7877_ = v___y_7973_;
v___y_7878_ = v___y_7972_;
goto v___jp_7875_;
}
else
{
uint64_t v_diff_7979_; uint8_t v_aNeg_7980_; uint8_t v_bNeg_7981_; uint8_t v_dNeg_7982_;
v_diff_7979_ = lean_uint64_sub(v_height_7700_, v___y_7969_);
v_aNeg_7980_ = lean_uint64_dec_le(v___x_7975_, v_height_7700_);
v_bNeg_7981_ = lean_uint64_dec_le(v___x_7975_, v___y_7969_);
v_dNeg_7982_ = lean_uint64_dec_le(v___x_7975_, v_diff_7979_);
if (v_aNeg_7980_ == 0)
{
if (v_bNeg_7981_ == 0)
{
v___y_7958_ = v_aNeg_7980_;
v___y_7959_ = v___y_7970_;
v___y_7960_ = v_diff_7979_;
v___y_7961_ = v_dNeg_7982_;
v___y_7962_ = v___x_7975_;
v___y_7963_ = v___y_7971_;
v___y_7964_ = v_bNeg_7981_;
v___y_7965_ = v___y_7972_;
v___y_7966_ = v___y_7973_;
v___y_7967_ = v_bNeg_7981_;
goto v___jp_7957_;
}
else
{
if (v_dNeg_7982_ == 0)
{
v___y_7958_ = v_aNeg_7980_;
v___y_7959_ = v___y_7970_;
v___y_7960_ = v_diff_7979_;
v___y_7961_ = v_dNeg_7982_;
v___y_7962_ = v___x_7975_;
v___y_7963_ = v___y_7971_;
v___y_7964_ = v_bNeg_7981_;
v___y_7965_ = v___y_7972_;
v___y_7966_ = v___y_7973_;
v___y_7967_ = v_dNeg_7982_;
goto v___jp_7957_;
}
else
{
uint64_t v___x_7983_;
v___x_7983_ = 9223372036854775807ULL;
v___y_7937_ = v___y_7970_;
v___y_7938_ = v___y_7971_;
v___y_7939_ = v___y_7972_;
v___y_7940_ = v___y_7973_;
v___y_7941_ = v___x_7983_;
goto v___jp_7936_;
}
}
}
else
{
v___y_7958_ = v_aNeg_7980_;
v___y_7959_ = v___y_7970_;
v___y_7960_ = v_diff_7979_;
v___y_7961_ = v_dNeg_7982_;
v___y_7962_ = v___x_7975_;
v___y_7963_ = v___y_7971_;
v___y_7964_ = v_bNeg_7981_;
v___y_7965_ = v___y_7972_;
v___y_7966_ = v___y_7973_;
v___y_7967_ = v___y_7970_;
goto v___jp_7957_;
}
}
}
}
v___jp_7984_:
{
if (v___y_7990_ == 0)
{
v___y_7969_ = v___y_7985_;
v___y_7970_ = v___y_7986_;
v___y_7971_ = v___y_7987_;
v___y_7972_ = v___y_7988_;
v___y_7973_ = v___y_7989_;
v___y_7974_ = v___y_7986_;
goto v___jp_7968_;
}
else
{
v___y_7969_ = v___y_7985_;
v___y_7970_ = v___y_7986_;
v___y_7971_ = v___y_7987_;
v___y_7972_ = v___y_7988_;
v___y_7973_ = v___y_7989_;
v___y_7974_ = v___y_7988_;
goto v___jp_7968_;
}
}
v___jp_7991_:
{
uint8_t v___x_7999_;
v___x_7999_ = lean_uint8_dec_eq(v_resized_7698_, v___y_7995_);
if (v___x_7999_ == 0)
{
v___y_7985_ = v___y_7998_;
v___y_7986_ = v___y_7992_;
v___y_7987_ = v___y_7994_;
v___y_7988_ = v___y_7996_;
v___y_7989_ = v___y_7997_;
v___y_7990_ = v___y_7993_;
goto v___jp_7984_;
}
else
{
v___y_7985_ = v___y_7998_;
v___y_7986_ = v___y_7992_;
v___y_7987_ = v___y_7994_;
v___y_7988_ = v___y_7996_;
v___y_7989_ = v___y_7997_;
v___y_7990_ = v___y_7992_;
goto v___jp_7984_;
}
}
v___jp_8000_:
{
uint64_t v___x_8009_; uint64_t v___x_8010_; uint8_t v___x_8011_;
v___x_8009_ = 9223372036854775808ULL;
v___x_8010_ = lean_uint64_add(v___y_8008_, v___x_8009_);
v___x_8011_ = lean_uint64_dec_lt(v___x_8009_, v___x_8010_);
if (v___x_8011_ == 0)
{
v___y_7992_ = v___y_8001_;
v___y_7993_ = v___y_8003_;
v___y_7994_ = v___y_8004_;
v___y_7995_ = v___y_8006_;
v___y_7996_ = v___y_8005_;
v___y_7997_ = v___y_8007_;
v___y_7998_ = v___y_8002_;
goto v___jp_7991_;
}
else
{
v___y_7992_ = v___y_8001_;
v___y_7993_ = v___y_8003_;
v___y_7994_ = v___y_8004_;
v___y_7995_ = v___y_8006_;
v___y_7996_ = v___y_8005_;
v___y_7997_ = v___y_8007_;
v___y_7998_ = v___y_8008_;
goto v___jp_7991_;
}
}
v___jp_8012_:
{
uint64_t v___x_8021_; uint64_t v___x_8022_; uint64_t v___x_8023_; uint8_t v___x_8024_;
v___x_8021_ = 9223372036854775808ULL;
v___x_8022_ = lean_uint64_add(v_arg_7702_, v___x_8021_);
v___x_8023_ = lean_uint64_add(v___y_8020_, v___x_8021_);
v___x_8024_ = lean_uint64_dec_le(v___x_8022_, v___x_8023_);
if (v___x_8024_ == 0)
{
v___y_8001_ = v___y_8013_;
v___y_8002_ = v___y_8014_;
v___y_8003_ = v___y_8015_;
v___y_8004_ = v___y_8016_;
v___y_8005_ = v___y_8018_;
v___y_8006_ = v___y_8017_;
v___y_8007_ = v___y_8019_;
v___y_8008_ = v___y_8020_;
goto v___jp_8000_;
}
else
{
v___y_8001_ = v___y_8013_;
v___y_8002_ = v___y_8014_;
v___y_8003_ = v___y_8015_;
v___y_8004_ = v___y_8016_;
v___y_8005_ = v___y_8018_;
v___y_8006_ = v___y_8017_;
v___y_8007_ = v___y_8019_;
v___y_8008_ = v_arg_7702_;
goto v___jp_8000_;
}
}
v___jp_8025_:
{
uint64_t v___x_8034_; uint64_t v___x_8035_; uint8_t v___x_8036_;
v___x_8034_ = 9223372036854775808ULL;
v___x_8035_ = lean_uint64_add(v___y_8033_, v___x_8034_);
v___x_8036_ = lean_uint64_dec_lt(v___x_8034_, v___x_8035_);
if (v___x_8036_ == 0)
{
v___y_8013_ = v___y_8026_;
v___y_8014_ = v___y_8027_;
v___y_8015_ = v___y_8028_;
v___y_8016_ = v___y_8029_;
v___y_8017_ = v___y_8031_;
v___y_8018_ = v___y_8030_;
v___y_8019_ = v___y_8032_;
v___y_8020_ = v___y_8027_;
goto v___jp_8012_;
}
else
{
v___y_8013_ = v___y_8026_;
v___y_8014_ = v___y_8027_;
v___y_8015_ = v___y_8028_;
v___y_8016_ = v___y_8029_;
v___y_8017_ = v___y_8031_;
v___y_8018_ = v___y_8030_;
v___y_8019_ = v___y_8032_;
v___y_8020_ = v___y_8033_;
goto v___jp_8012_;
}
}
v___jp_8037_:
{
if (v___y_8039_ == 0)
{
v___y_8026_ = v___y_8041_;
v___y_8027_ = v___y_8042_;
v___y_8028_ = v___y_8044_;
v___y_8029_ = v___y_8045_;
v___y_8030_ = v___y_8047_;
v___y_8031_ = v___y_8046_;
v___y_8032_ = v___y_8048_;
v___y_8033_ = v___y_8043_;
goto v___jp_8025_;
}
else
{
if (v___y_8038_ == 0)
{
v___y_8026_ = v___y_8041_;
v___y_8027_ = v___y_8042_;
v___y_8028_ = v___y_8044_;
v___y_8029_ = v___y_8045_;
v___y_8030_ = v___y_8047_;
v___y_8031_ = v___y_8046_;
v___y_8032_ = v___y_8048_;
v___y_8033_ = v___y_8040_;
goto v___jp_8025_;
}
else
{
v___y_8026_ = v___y_8041_;
v___y_8027_ = v___y_8042_;
v___y_8028_ = v___y_8044_;
v___y_8029_ = v___y_8045_;
v___y_8030_ = v___y_8047_;
v___y_8031_ = v___y_8046_;
v___y_8032_ = v___y_8048_;
v___y_8033_ = v___y_8043_;
goto v___jp_8025_;
}
}
}
v___jp_8049_:
{
if (v___y_8055_ == 0)
{
v___y_8026_ = v___y_8052_;
v___y_8027_ = v___y_8054_;
v___y_8028_ = v___y_8056_;
v___y_8029_ = v___y_8057_;
v___y_8030_ = v___y_8059_;
v___y_8031_ = v___y_8060_;
v___y_8032_ = v___y_8061_;
v___y_8033_ = v___y_8051_;
goto v___jp_8025_;
}
else
{
if (v___y_8058_ == 0)
{
v___y_8038_ = v___y_8062_;
v___y_8039_ = v___y_8050_;
v___y_8040_ = v___y_8051_;
v___y_8041_ = v___y_8052_;
v___y_8042_ = v___y_8054_;
v___y_8043_ = v___y_8053_;
v___y_8044_ = v___y_8056_;
v___y_8045_ = v___y_8057_;
v___y_8046_ = v___y_8060_;
v___y_8047_ = v___y_8059_;
v___y_8048_ = v___y_8061_;
goto v___jp_8037_;
}
else
{
if (v___y_8062_ == 0)
{
v___y_8026_ = v___y_8052_;
v___y_8027_ = v___y_8054_;
v___y_8028_ = v___y_8056_;
v___y_8029_ = v___y_8057_;
v___y_8030_ = v___y_8059_;
v___y_8031_ = v___y_8060_;
v___y_8032_ = v___y_8061_;
v___y_8033_ = v___y_8051_;
goto v___jp_8025_;
}
else
{
v___y_8038_ = v___y_8062_;
v___y_8039_ = v___y_8050_;
v___y_8040_ = v___y_8051_;
v___y_8041_ = v___y_8052_;
v___y_8042_ = v___y_8054_;
v___y_8043_ = v___y_8053_;
v___y_8044_ = v___y_8056_;
v___y_8045_ = v___y_8057_;
v___y_8046_ = v___y_8060_;
v___y_8047_ = v___y_8059_;
v___y_8048_ = v___y_8061_;
goto v___jp_8037_;
}
}
}
}
v___jp_8063_:
{
uint8_t v___x_8070_; uint8_t v___x_8071_;
v___x_8070_ = 2;
v___x_8071_ = lean_uint8_dec_eq(v_opKind_7695_, v___x_8070_);
if (v___x_8071_ == 0)
{
v___y_7876_ = v___y_8065_;
v___y_7877_ = v___y_8068_;
v___y_7878_ = v___y_8064_;
goto v___jp_7875_;
}
else
{
uint64_t v___x_8072_; uint64_t v_diff_8073_; uint64_t v___x_8074_; uint8_t v_aNeg_8075_; uint8_t v_bNeg_8076_; uint8_t v_dNeg_8077_;
v___x_8072_ = 0ULL;
v_diff_8073_ = lean_uint64_sub(v_height_7700_, v_client_7701_);
v___x_8074_ = 9223372036854775808ULL;
v_aNeg_8075_ = lean_uint64_dec_le(v___x_8074_, v_height_7700_);
v_bNeg_8076_ = lean_uint64_dec_le(v___x_8074_, v_client_7701_);
v_dNeg_8077_ = lean_uint64_dec_le(v___x_8074_, v_diff_8073_);
if (v_aNeg_8075_ == 0)
{
if (v_bNeg_8076_ == 0)
{
v___y_8050_ = v_dNeg_8077_;
v___y_8051_ = v_diff_8073_;
v___y_8052_ = v___y_8069_;
v___y_8053_ = v___x_8074_;
v___y_8054_ = v___x_8072_;
v___y_8055_ = v_aNeg_8075_;
v___y_8056_ = v___x_8071_;
v___y_8057_ = v___y_8065_;
v___y_8058_ = v_bNeg_8076_;
v___y_8059_ = v___y_8067_;
v___y_8060_ = v___y_8066_;
v___y_8061_ = v___y_8068_;
v___y_8062_ = v_bNeg_8076_;
goto v___jp_8049_;
}
else
{
if (v_dNeg_8077_ == 0)
{
v___y_8050_ = v_dNeg_8077_;
v___y_8051_ = v_diff_8073_;
v___y_8052_ = v___y_8069_;
v___y_8053_ = v___x_8074_;
v___y_8054_ = v___x_8072_;
v___y_8055_ = v_aNeg_8075_;
v___y_8056_ = v___x_8071_;
v___y_8057_ = v___y_8065_;
v___y_8058_ = v_bNeg_8076_;
v___y_8059_ = v___y_8067_;
v___y_8060_ = v___y_8066_;
v___y_8061_ = v___y_8068_;
v___y_8062_ = v_dNeg_8077_;
goto v___jp_8049_;
}
else
{
uint64_t v___x_8078_;
v___x_8078_ = 9223372036854775807ULL;
v___y_8026_ = v___y_8069_;
v___y_8027_ = v___x_8072_;
v___y_8028_ = v___x_8071_;
v___y_8029_ = v___y_8065_;
v___y_8030_ = v___y_8067_;
v___y_8031_ = v___y_8066_;
v___y_8032_ = v___y_8068_;
v___y_8033_ = v___x_8078_;
goto v___jp_8025_;
}
}
}
else
{
v___y_8050_ = v_dNeg_8077_;
v___y_8051_ = v_diff_8073_;
v___y_8052_ = v___y_8069_;
v___y_8053_ = v___x_8074_;
v___y_8054_ = v___x_8072_;
v___y_8055_ = v_aNeg_8075_;
v___y_8056_ = v___x_8071_;
v___y_8057_ = v___y_8065_;
v___y_8058_ = v_bNeg_8076_;
v___y_8059_ = v___y_8067_;
v___y_8060_ = v___y_8066_;
v___y_8061_ = v___y_8068_;
v___y_8062_ = v___y_8069_;
goto v___jp_8049_;
}
}
}
v___jp_8079_:
{
uint64_t v___x_8085_; uint64_t v___x_8086_; uint64_t v___x_8087_; uint8_t v___x_8088_;
v___x_8085_ = 9223372036854775808ULL;
v___x_8086_ = lean_uint64_add(v___y_8084_, v___x_8085_);
v___x_8087_ = 9223372036854775832ULL;
v___x_8088_ = lean_uint64_dec_lt(v___x_8086_, v___x_8087_);
if (v___x_8088_ == 0)
{
v___y_7876_ = v___y_8081_;
v___y_7877_ = v___y_8083_;
v___y_7878_ = v___y_8082_;
goto v___jp_7875_;
}
else
{
v___y_7876_ = v___y_8081_;
v___y_7877_ = v___y_8083_;
v___y_7878_ = v___y_8080_;
goto v___jp_7875_;
}
}
v___jp_8089_:
{
if (v___y_8094_ == 0)
{
v___y_8080_ = v___y_8091_;
v___y_8081_ = v___y_8095_;
v___y_8082_ = v___y_8096_;
v___y_8083_ = v___y_8097_;
v___y_8084_ = v___y_8090_;
goto v___jp_8079_;
}
else
{
if (v___y_8093_ == 0)
{
v___y_8080_ = v___y_8091_;
v___y_8081_ = v___y_8095_;
v___y_8082_ = v___y_8096_;
v___y_8083_ = v___y_8097_;
v___y_8084_ = v___y_8092_;
goto v___jp_8079_;
}
else
{
v___y_8080_ = v___y_8091_;
v___y_8081_ = v___y_8095_;
v___y_8082_ = v___y_8096_;
v___y_8083_ = v___y_8097_;
v___y_8084_ = v___y_8090_;
goto v___jp_8079_;
}
}
}
v___jp_8098_:
{
if (v___y_8103_ == 0)
{
v___y_8080_ = v___y_8100_;
v___y_8081_ = v___y_8104_;
v___y_8082_ = v___y_8106_;
v___y_8083_ = v___y_8107_;
v___y_8084_ = v___y_8101_;
goto v___jp_8079_;
}
else
{
if (v___y_8105_ == 0)
{
v___y_8090_ = v___y_8099_;
v___y_8091_ = v___y_8100_;
v___y_8092_ = v___y_8101_;
v___y_8093_ = v___y_8108_;
v___y_8094_ = v___y_8102_;
v___y_8095_ = v___y_8104_;
v___y_8096_ = v___y_8106_;
v___y_8097_ = v___y_8107_;
goto v___jp_8089_;
}
else
{
if (v___y_8108_ == 0)
{
v___y_8080_ = v___y_8100_;
v___y_8081_ = v___y_8104_;
v___y_8082_ = v___y_8106_;
v___y_8083_ = v___y_8107_;
v___y_8084_ = v___y_8101_;
goto v___jp_8079_;
}
else
{
v___y_8090_ = v___y_8099_;
v___y_8091_ = v___y_8100_;
v___y_8092_ = v___y_8101_;
v___y_8093_ = v___y_8108_;
v___y_8094_ = v___y_8102_;
v___y_8095_ = v___y_8104_;
v___y_8096_ = v___y_8106_;
v___y_8097_ = v___y_8107_;
goto v___jp_8089_;
}
}
}
}
v___jp_8109_:
{
uint64_t v_diff_8117_; uint8_t v_aNeg_8118_; uint8_t v_bNeg_8119_; uint8_t v_dNeg_8120_;
v_diff_8117_ = lean_uint64_sub(v___y_8116_, v_client_7701_);
v_aNeg_8118_ = lean_uint64_dec_le(v___y_8110_, v___y_8116_);
v_bNeg_8119_ = lean_uint64_dec_le(v___y_8110_, v_client_7701_);
v_dNeg_8120_ = lean_uint64_dec_le(v___y_8110_, v_diff_8117_);
if (v_aNeg_8118_ == 0)
{
if (v_bNeg_8119_ == 0)
{
v___y_8099_ = v___y_8110_;
v___y_8100_ = v___y_8111_;
v___y_8101_ = v_diff_8117_;
v___y_8102_ = v_dNeg_8120_;
v___y_8103_ = v_aNeg_8118_;
v___y_8104_ = v___y_8113_;
v___y_8105_ = v_bNeg_8119_;
v___y_8106_ = v___y_8114_;
v___y_8107_ = v___y_8115_;
v___y_8108_ = v_bNeg_8119_;
goto v___jp_8098_;
}
else
{
if (v_dNeg_8120_ == 0)
{
v___y_8099_ = v___y_8110_;
v___y_8100_ = v___y_8111_;
v___y_8101_ = v_diff_8117_;
v___y_8102_ = v_dNeg_8120_;
v___y_8103_ = v_aNeg_8118_;
v___y_8104_ = v___y_8113_;
v___y_8105_ = v_bNeg_8119_;
v___y_8106_ = v___y_8114_;
v___y_8107_ = v___y_8115_;
v___y_8108_ = v_dNeg_8120_;
goto v___jp_8098_;
}
else
{
uint64_t v___x_8121_;
v___x_8121_ = 9223372036854775807ULL;
v___y_8080_ = v___y_8111_;
v___y_8081_ = v___y_8113_;
v___y_8082_ = v___y_8114_;
v___y_8083_ = v___y_8115_;
v___y_8084_ = v___x_8121_;
goto v___jp_8079_;
}
}
}
else
{
v___y_8099_ = v___y_8110_;
v___y_8100_ = v___y_8111_;
v___y_8101_ = v_diff_8117_;
v___y_8102_ = v_dNeg_8120_;
v___y_8103_ = v_aNeg_8118_;
v___y_8104_ = v___y_8113_;
v___y_8105_ = v_bNeg_8119_;
v___y_8106_ = v___y_8114_;
v___y_8107_ = v___y_8115_;
v___y_8108_ = v___y_8112_;
goto v___jp_8098_;
}
}
v___jp_8122_:
{
if (v___y_8126_ == 0)
{
v___y_8110_ = v___y_8123_;
v___y_8111_ = v___y_8125_;
v___y_8112_ = v___y_8127_;
v___y_8113_ = v___y_8129_;
v___y_8114_ = v___y_8130_;
v___y_8115_ = v___y_8131_;
v___y_8116_ = v___y_8123_;
goto v___jp_8109_;
}
else
{
if (v___y_8128_ == 0)
{
v___y_8110_ = v___y_8123_;
v___y_8111_ = v___y_8125_;
v___y_8112_ = v___y_8127_;
v___y_8113_ = v___y_8129_;
v___y_8114_ = v___y_8130_;
v___y_8115_ = v___y_8131_;
v___y_8116_ = v___y_8124_;
goto v___jp_8109_;
}
else
{
v___y_8110_ = v___y_8123_;
v___y_8111_ = v___y_8125_;
v___y_8112_ = v___y_8127_;
v___y_8113_ = v___y_8129_;
v___y_8114_ = v___y_8130_;
v___y_8115_ = v___y_8131_;
v___y_8116_ = v___y_8123_;
goto v___jp_8109_;
}
}
}
v___jp_8132_:
{
if (v___y_8136_ == 0)
{
v___y_8110_ = v___y_8133_;
v___y_8111_ = v___y_8134_;
v___y_8112_ = v___y_8139_;
v___y_8113_ = v___y_8140_;
v___y_8114_ = v___y_8141_;
v___y_8115_ = v___y_8142_;
v___y_8116_ = v___y_8135_;
goto v___jp_8109_;
}
else
{
if (v___y_8137_ == 0)
{
v___y_8123_ = v___y_8133_;
v___y_8124_ = v___y_8135_;
v___y_8125_ = v___y_8134_;
v___y_8126_ = v___y_8138_;
v___y_8127_ = v___y_8139_;
v___y_8128_ = v___y_8143_;
v___y_8129_ = v___y_8140_;
v___y_8130_ = v___y_8141_;
v___y_8131_ = v___y_8142_;
goto v___jp_8122_;
}
else
{
if (v___y_8143_ == 0)
{
v___y_8110_ = v___y_8133_;
v___y_8111_ = v___y_8134_;
v___y_8112_ = v___y_8139_;
v___y_8113_ = v___y_8140_;
v___y_8114_ = v___y_8141_;
v___y_8115_ = v___y_8142_;
v___y_8116_ = v___y_8135_;
goto v___jp_8109_;
}
else
{
v___y_8123_ = v___y_8133_;
v___y_8124_ = v___y_8135_;
v___y_8125_ = v___y_8134_;
v___y_8126_ = v___y_8138_;
v___y_8127_ = v___y_8139_;
v___y_8128_ = v___y_8143_;
v___y_8129_ = v___y_8140_;
v___y_8130_ = v___y_8141_;
v___y_8131_ = v___y_8142_;
goto v___jp_8122_;
}
}
}
}
v___jp_8144_:
{
uint64_t v___x_8151_; uint64_t v___x_8152_; uint64_t v___x_8153_; uint8_t v___x_8154_;
v___x_8151_ = 9223372036854775808ULL;
v___x_8152_ = lean_uint64_add(v___y_8150_, v___x_8151_);
v___x_8153_ = lean_uint64_add(v_curTop_7699_, v___x_8151_);
v___x_8154_ = lean_uint64_dec_lt(v___x_8152_, v___x_8153_);
if (v___x_8154_ == 0)
{
uint64_t v_diff_8155_; uint8_t v_aNeg_8156_; uint8_t v_bNeg_8157_; uint8_t v_dNeg_8158_;
v_diff_8155_ = lean_uint64_sub(v_height_7700_, v___y_8150_);
v_aNeg_8156_ = lean_uint64_dec_le(v___x_8151_, v_height_7700_);
v_bNeg_8157_ = lean_uint64_dec_le(v___x_8151_, v___y_8150_);
v_dNeg_8158_ = lean_uint64_dec_le(v___x_8151_, v_diff_8155_);
if (v_aNeg_8156_ == 0)
{
if (v_bNeg_8157_ == 0)
{
v___y_8133_ = v___x_8151_;
v___y_8134_ = v___y_8145_;
v___y_8135_ = v_diff_8155_;
v___y_8136_ = v_aNeg_8156_;
v___y_8137_ = v_bNeg_8157_;
v___y_8138_ = v_dNeg_8158_;
v___y_8139_ = v___x_8154_;
v___y_8140_ = v___y_8147_;
v___y_8141_ = v___y_8148_;
v___y_8142_ = v___y_8149_;
v___y_8143_ = v_bNeg_8157_;
goto v___jp_8132_;
}
else
{
if (v_dNeg_8158_ == 0)
{
v___y_8133_ = v___x_8151_;
v___y_8134_ = v___y_8145_;
v___y_8135_ = v_diff_8155_;
v___y_8136_ = v_aNeg_8156_;
v___y_8137_ = v_bNeg_8157_;
v___y_8138_ = v_dNeg_8158_;
v___y_8139_ = v___x_8154_;
v___y_8140_ = v___y_8147_;
v___y_8141_ = v___y_8148_;
v___y_8142_ = v___y_8149_;
v___y_8143_ = v_dNeg_8158_;
goto v___jp_8132_;
}
else
{
uint64_t v___x_8159_;
v___x_8159_ = 9223372036854775807ULL;
v___y_8110_ = v___x_8151_;
v___y_8111_ = v___y_8145_;
v___y_8112_ = v___x_8154_;
v___y_8113_ = v___y_8147_;
v___y_8114_ = v___y_8148_;
v___y_8115_ = v___y_8149_;
v___y_8116_ = v___x_8159_;
goto v___jp_8109_;
}
}
}
else
{
v___y_8133_ = v___x_8151_;
v___y_8134_ = v___y_8145_;
v___y_8135_ = v_diff_8155_;
v___y_8136_ = v_aNeg_8156_;
v___y_8137_ = v_bNeg_8157_;
v___y_8138_ = v_dNeg_8158_;
v___y_8139_ = v___x_8154_;
v___y_8140_ = v___y_8147_;
v___y_8141_ = v___y_8148_;
v___y_8142_ = v___y_8149_;
v___y_8143_ = v___x_8154_;
goto v___jp_8132_;
}
}
else
{
v___y_7876_ = v___y_8147_;
v___y_7877_ = v___y_8149_;
v___y_7878_ = v___y_8146_;
goto v___jp_7875_;
}
}
v___jp_8160_:
{
uint64_t v___x_8168_; uint64_t v___x_8169_; uint8_t v___x_8170_;
v___x_8168_ = 9223372036854775808ULL;
v___x_8169_ = lean_uint64_add(v___y_8167_, v___x_8168_);
v___x_8170_ = lean_uint64_dec_lt(v___x_8168_, v___x_8169_);
if (v___x_8170_ == 0)
{
v___y_8145_ = v___y_8161_;
v___y_8146_ = v___y_8162_;
v___y_8147_ = v___y_8164_;
v___y_8148_ = v___y_8165_;
v___y_8149_ = v___y_8166_;
v___y_8150_ = v___y_8163_;
goto v___jp_8144_;
}
else
{
v___y_8145_ = v___y_8161_;
v___y_8146_ = v___y_8162_;
v___y_8147_ = v___y_8164_;
v___y_8148_ = v___y_8165_;
v___y_8149_ = v___y_8166_;
v___y_8150_ = v___y_8167_;
goto v___jp_8144_;
}
}
v___jp_8171_:
{
uint64_t v___x_8179_; uint64_t v___x_8180_; uint64_t v___x_8181_; uint8_t v___x_8182_;
v___x_8179_ = 9223372036854775808ULL;
v___x_8180_ = lean_uint64_add(v_arg_7702_, v___x_8179_);
v___x_8181_ = lean_uint64_add(v___y_8178_, v___x_8179_);
v___x_8182_ = lean_uint64_dec_le(v___x_8180_, v___x_8181_);
if (v___x_8182_ == 0)
{
v___y_8161_ = v___y_8172_;
v___y_8162_ = v___y_8173_;
v___y_8163_ = v___y_8174_;
v___y_8164_ = v___y_8175_;
v___y_8165_ = v___y_8176_;
v___y_8166_ = v___y_8177_;
v___y_8167_ = v___y_8178_;
goto v___jp_8160_;
}
else
{
v___y_8161_ = v___y_8172_;
v___y_8162_ = v___y_8173_;
v___y_8163_ = v___y_8174_;
v___y_8164_ = v___y_8175_;
v___y_8165_ = v___y_8176_;
v___y_8166_ = v___y_8177_;
v___y_8167_ = v_arg_7702_;
goto v___jp_8160_;
}
}
v___jp_8183_:
{
uint64_t v___x_8191_; uint64_t v___x_8192_; uint8_t v___x_8193_;
v___x_8191_ = 9223372036854775808ULL;
v___x_8192_ = lean_uint64_add(v___y_8190_, v___x_8191_);
v___x_8193_ = lean_uint64_dec_lt(v___x_8191_, v___x_8192_);
if (v___x_8193_ == 0)
{
v___y_8172_ = v___y_8184_;
v___y_8173_ = v___y_8185_;
v___y_8174_ = v___y_8186_;
v___y_8175_ = v___y_8187_;
v___y_8176_ = v___y_8188_;
v___y_8177_ = v___y_8189_;
v___y_8178_ = v___y_8186_;
goto v___jp_8171_;
}
else
{
v___y_8172_ = v___y_8184_;
v___y_8173_ = v___y_8185_;
v___y_8174_ = v___y_8186_;
v___y_8175_ = v___y_8187_;
v___y_8176_ = v___y_8188_;
v___y_8177_ = v___y_8189_;
v___y_8178_ = v___y_8190_;
goto v___jp_8171_;
}
}
v___jp_8194_:
{
if (v___y_8200_ == 0)
{
v___y_8184_ = v___y_8196_;
v___y_8185_ = v___y_8198_;
v___y_8186_ = v___y_8199_;
v___y_8187_ = v___y_8201_;
v___y_8188_ = v___y_8203_;
v___y_8189_ = v___y_8204_;
v___y_8190_ = v___y_8195_;
goto v___jp_8183_;
}
else
{
if (v___y_8202_ == 0)
{
v___y_8184_ = v___y_8196_;
v___y_8185_ = v___y_8198_;
v___y_8186_ = v___y_8199_;
v___y_8187_ = v___y_8201_;
v___y_8188_ = v___y_8203_;
v___y_8189_ = v___y_8204_;
v___y_8190_ = v___y_8197_;
goto v___jp_8183_;
}
else
{
v___y_8184_ = v___y_8196_;
v___y_8185_ = v___y_8198_;
v___y_8186_ = v___y_8199_;
v___y_8187_ = v___y_8201_;
v___y_8188_ = v___y_8203_;
v___y_8189_ = v___y_8204_;
v___y_8190_ = v___y_8195_;
goto v___jp_8183_;
}
}
}
v___jp_8205_:
{
if (v___y_8215_ == 0)
{
v___y_8184_ = v___y_8207_;
v___y_8185_ = v___y_8209_;
v___y_8186_ = v___y_8210_;
v___y_8187_ = v___y_8212_;
v___y_8188_ = v___y_8213_;
v___y_8189_ = v___y_8216_;
v___y_8190_ = v___y_8208_;
goto v___jp_8183_;
}
else
{
if (v___y_8214_ == 0)
{
v___y_8195_ = v___y_8206_;
v___y_8196_ = v___y_8207_;
v___y_8197_ = v___y_8208_;
v___y_8198_ = v___y_8209_;
v___y_8199_ = v___y_8210_;
v___y_8200_ = v___y_8211_;
v___y_8201_ = v___y_8212_;
v___y_8202_ = v___y_8217_;
v___y_8203_ = v___y_8213_;
v___y_8204_ = v___y_8216_;
goto v___jp_8194_;
}
else
{
if (v___y_8217_ == 0)
{
v___y_8184_ = v___y_8207_;
v___y_8185_ = v___y_8209_;
v___y_8186_ = v___y_8210_;
v___y_8187_ = v___y_8212_;
v___y_8188_ = v___y_8213_;
v___y_8189_ = v___y_8216_;
v___y_8190_ = v___y_8208_;
goto v___jp_8183_;
}
else
{
v___y_8195_ = v___y_8206_;
v___y_8196_ = v___y_8207_;
v___y_8197_ = v___y_8208_;
v___y_8198_ = v___y_8209_;
v___y_8199_ = v___y_8210_;
v___y_8200_ = v___y_8211_;
v___y_8201_ = v___y_8212_;
v___y_8202_ = v___y_8217_;
v___y_8203_ = v___y_8213_;
v___y_8204_ = v___y_8216_;
goto v___jp_8194_;
}
}
}
}
v___jp_8218_:
{
uint64_t v___x_8224_; uint64_t v_diff_8225_; uint64_t v___x_8226_; uint8_t v_aNeg_8227_; uint8_t v_bNeg_8228_; uint8_t v_dNeg_8229_;
v___x_8224_ = 0ULL;
v_diff_8225_ = lean_uint64_sub(v_height_7700_, v_client_7701_);
v___x_8226_ = 9223372036854775808ULL;
v_aNeg_8227_ = lean_uint64_dec_le(v___x_8226_, v_height_7700_);
v_bNeg_8228_ = lean_uint64_dec_le(v___x_8226_, v_client_7701_);
v_dNeg_8229_ = lean_uint64_dec_le(v___x_8226_, v_diff_8225_);
if (v_aNeg_8227_ == 0)
{
if (v_bNeg_8228_ == 0)
{
v___y_8206_ = v___x_8226_;
v___y_8207_ = v___y_8219_;
v___y_8208_ = v_diff_8225_;
v___y_8209_ = v___y_8220_;
v___y_8210_ = v___x_8224_;
v___y_8211_ = v_dNeg_8229_;
v___y_8212_ = v___y_8221_;
v___y_8213_ = v___y_8222_;
v___y_8214_ = v_bNeg_8228_;
v___y_8215_ = v_aNeg_8227_;
v___y_8216_ = v___y_8223_;
v___y_8217_ = v_bNeg_8228_;
goto v___jp_8205_;
}
else
{
if (v_dNeg_8229_ == 0)
{
v___y_8206_ = v___x_8226_;
v___y_8207_ = v___y_8219_;
v___y_8208_ = v_diff_8225_;
v___y_8209_ = v___y_8220_;
v___y_8210_ = v___x_8224_;
v___y_8211_ = v_dNeg_8229_;
v___y_8212_ = v___y_8221_;
v___y_8213_ = v___y_8222_;
v___y_8214_ = v_bNeg_8228_;
v___y_8215_ = v_aNeg_8227_;
v___y_8216_ = v___y_8223_;
v___y_8217_ = v_dNeg_8229_;
goto v___jp_8205_;
}
else
{
uint64_t v___x_8230_;
v___x_8230_ = 9223372036854775807ULL;
v___y_8184_ = v___y_8219_;
v___y_8185_ = v___y_8220_;
v___y_8186_ = v___x_8224_;
v___y_8187_ = v___y_8221_;
v___y_8188_ = v___y_8222_;
v___y_8189_ = v___y_8223_;
v___y_8190_ = v___x_8230_;
goto v___jp_8183_;
}
}
}
else
{
v___y_8206_ = v___x_8226_;
v___y_8207_ = v___y_8219_;
v___y_8208_ = v_diff_8225_;
v___y_8209_ = v___y_8220_;
v___y_8210_ = v___x_8224_;
v___y_8211_ = v_dNeg_8229_;
v___y_8212_ = v___y_8221_;
v___y_8213_ = v___y_8222_;
v___y_8214_ = v_bNeg_8228_;
v___y_8215_ = v_aNeg_8227_;
v___y_8216_ = v___y_8223_;
v___y_8217_ = v___y_8220_;
goto v___jp_8205_;
}
}
v___jp_8231_:
{
uint8_t v___x_8237_; uint8_t v___x_8238_;
v___x_8237_ = 3;
v___x_8238_ = lean_uint8_dec_le(v_opKind_7695_, v___x_8237_);
if (v___x_8238_ == 0)
{
uint32_t v___x_8239_; uint32_t v_lo32Err_8240_; uint64_t v___x_8241_; uint64_t v___x_8242_; uint64_t v___x_8243_; uint64_t v___x_8244_;
v___x_8239_ = 2;
v_lo32Err_8240_ = lean_uint32_lor(v___x_8239_, v___y_8233_);
v___x_8241_ = lean_uint32_to_uint64(v_lo32Err_8240_);
v___x_8242_ = lean_uint32_to_uint64(v___y_8232_);
v___x_8243_ = lean_uint64_shift_left(v___x_8242_, v___x_7703_);
v___x_8244_ = lean_uint64_lor(v___x_8241_, v___x_8243_);
return v___x_8244_;
}
else
{
if (v___y_8236_ == 0)
{
uint32_t v___x_8245_; uint32_t v_lo32Dom_8246_; uint64_t v___x_8247_; uint64_t v___x_8248_; uint64_t v___x_8249_; uint64_t v___x_8250_;
v___x_8245_ = 3;
v_lo32Dom_8246_ = lean_uint32_lor(v___x_8245_, v___y_8233_);
v___x_8247_ = lean_uint32_to_uint64(v_lo32Dom_8246_);
v___x_8248_ = lean_uint32_to_uint64(v___y_8232_);
v___x_8249_ = lean_uint64_shift_left(v___x_8248_, v___x_7703_);
v___x_8250_ = lean_uint64_lor(v___x_8247_, v___x_8249_);
return v___x_8250_;
}
else
{
uint8_t v___x_8251_; uint8_t v_pinBool_8252_; uint8_t v___x_8253_;
v___x_8251_ = 1;
v_pinBool_8252_ = lean_uint8_dec_eq(v_pinned_7696_, v___x_8251_);
v___x_8253_ = lean_uint8_dec_eq(v_opKind_7695_, v___y_8234_);
if (v___x_8253_ == 0)
{
uint8_t v___x_8254_;
v___x_8254_ = lean_uint8_dec_eq(v_opKind_7695_, v___x_8251_);
if (v___x_8254_ == 0)
{
uint8_t v___x_8255_; uint8_t v___x_8256_;
v___x_8255_ = 2;
v___x_8256_ = lean_uint8_dec_eq(v_opKind_7695_, v___x_8255_);
if (v___x_8256_ == 0)
{
v___y_8064_ = v___y_8236_;
v___y_8065_ = v___y_8234_;
v___y_8066_ = v___x_8251_;
v___y_8067_ = v_pinBool_8252_;
v___y_8068_ = v___y_8235_;
v___y_8069_ = v___x_8253_;
goto v___jp_8063_;
}
else
{
uint8_t v___x_8257_;
v___x_8257_ = lean_uint8_dec_eq(v_intent_7697_, v___x_8251_);
if (v___x_8257_ == 0)
{
v___y_8064_ = v___y_8236_;
v___y_8065_ = v___y_8234_;
v___y_8066_ = v___x_8251_;
v___y_8067_ = v_pinBool_8252_;
v___y_8068_ = v___y_8235_;
v___y_8069_ = v___x_8257_;
goto v___jp_8063_;
}
else
{
v___y_8219_ = v___y_8236_;
v___y_8220_ = v___x_8253_;
v___y_8221_ = v___y_8234_;
v___y_8222_ = v_pinBool_8252_;
v___y_8223_ = v___y_8235_;
goto v___jp_8218_;
}
}
}
else
{
v___y_8219_ = v___y_8236_;
v___y_8220_ = v___x_8253_;
v___y_8221_ = v___y_8234_;
v___y_8222_ = v_pinBool_8252_;
v___y_8223_ = v___y_8235_;
goto v___jp_8218_;
}
}
else
{
v___y_7876_ = v___y_8234_;
v___y_7877_ = v___y_8235_;
v___y_7878_ = v_pinBool_8252_;
goto v___jp_7875_;
}
}
}
}
v___jp_8258_:
{
uint64_t v___x_8263_; uint8_t v___x_8264_;
v___x_8263_ = 1073741823ULL;
v___x_8264_ = lean_uint64_dec_le(v_arg_7702_, v___x_8263_);
if (v___x_8264_ == 0)
{
uint64_t v___x_8265_; uint8_t v___x_8266_;
v___x_8265_ = 18446744072635809792ULL;
v___x_8266_ = lean_uint64_dec_le(v___x_8265_, v_arg_7702_);
v___y_8232_ = v___y_8259_;
v___y_8233_ = v___y_8260_;
v___y_8234_ = v___y_8261_;
v___y_8235_ = v___y_8262_;
v___y_8236_ = v___x_8266_;
goto v___jp_8231_;
}
else
{
v___y_8232_ = v___y_8259_;
v___y_8233_ = v___y_8260_;
v___y_8234_ = v___y_8261_;
v___y_8235_ = v___y_8262_;
v___y_8236_ = v___x_8264_;
goto v___jp_8231_;
}
}
v___jp_8267_:
{
uint64_t v___x_8272_; uint8_t v___x_8273_;
v___x_8272_ = 1073741823ULL;
v___x_8273_ = lean_uint64_dec_le(v_client_7701_, v___x_8272_);
if (v___x_8273_ == 0)
{
uint64_t v___x_8274_; uint8_t v___x_8275_;
v___x_8274_ = 18446744072635809792ULL;
v___x_8275_ = lean_uint64_dec_le(v___x_8274_, v_client_7701_);
if (v___x_8275_ == 0)
{
v___y_8232_ = v___y_8268_;
v___y_8233_ = v___y_8269_;
v___y_8234_ = v___y_8270_;
v___y_8235_ = v___y_8271_;
v___y_8236_ = v___x_8275_;
goto v___jp_8231_;
}
else
{
v___y_8259_ = v___y_8268_;
v___y_8260_ = v___y_8269_;
v___y_8261_ = v___y_8270_;
v___y_8262_ = v___y_8271_;
goto v___jp_8258_;
}
}
else
{
v___y_8259_ = v___y_8268_;
v___y_8260_ = v___y_8269_;
v___y_8261_ = v___y_8270_;
v___y_8262_ = v___y_8271_;
goto v___jp_8258_;
}
}
v___jp_8276_:
{
uint64_t v___x_8281_; uint8_t v___x_8282_;
v___x_8281_ = 1073741823ULL;
v___x_8282_ = lean_uint64_dec_le(v_height_7700_, v___x_8281_);
if (v___x_8282_ == 0)
{
uint64_t v___x_8283_; uint8_t v___x_8284_;
v___x_8283_ = 18446744072635809792ULL;
v___x_8284_ = lean_uint64_dec_le(v___x_8283_, v_height_7700_);
if (v___x_8284_ == 0)
{
v___y_8232_ = v___y_8277_;
v___y_8233_ = v___y_8278_;
v___y_8234_ = v___y_8279_;
v___y_8235_ = v___y_8280_;
v___y_8236_ = v___x_8284_;
goto v___jp_8231_;
}
else
{
v___y_8268_ = v___y_8277_;
v___y_8269_ = v___y_8278_;
v___y_8270_ = v___y_8279_;
v___y_8271_ = v___y_8280_;
goto v___jp_8267_;
}
}
else
{
v___y_8268_ = v___y_8277_;
v___y_8269_ = v___y_8278_;
v___y_8270_ = v___y_8279_;
v___y_8271_ = v___y_8280_;
goto v___jp_8267_;
}
}
v___jp_8285_:
{
uint64_t v___x_8290_; uint8_t v___x_8291_;
v___x_8290_ = 1073741823ULL;
v___x_8291_ = lean_uint64_dec_le(v_curTop_7699_, v___x_8290_);
if (v___x_8291_ == 0)
{
uint64_t v___x_8292_; uint8_t v___x_8293_;
v___x_8292_ = 18446744072635809792ULL;
v___x_8293_ = lean_uint64_dec_le(v___x_8292_, v_curTop_7699_);
if (v___x_8293_ == 0)
{
v___y_8232_ = v___y_8289_;
v___y_8233_ = v___y_8286_;
v___y_8234_ = v___y_8287_;
v___y_8235_ = v___y_8288_;
v___y_8236_ = v___x_8293_;
goto v___jp_8231_;
}
else
{
v___y_8277_ = v___y_8289_;
v___y_8278_ = v___y_8286_;
v___y_8279_ = v___y_8287_;
v___y_8280_ = v___y_8288_;
goto v___jp_8276_;
}
}
else
{
v___y_8277_ = v___y_8289_;
v___y_8278_ = v___y_8286_;
v___y_8279_ = v___y_8287_;
v___y_8280_ = v___y_8288_;
goto v___jp_8276_;
}
}
v___jp_8294_:
{
uint64_t v___x_8299_; uint8_t v___x_8300_;
v___x_8299_ = 4294967295ULL;
v___x_8300_ = lean_uint64_dec_le(v___y_8298_, v___x_8299_);
if (v___x_8300_ == 0)
{
uint32_t v___x_8301_;
v___x_8301_ = 4294967295;
v___y_8286_ = v___y_8295_;
v___y_8287_ = v___y_8296_;
v___y_8288_ = v___y_8297_;
v___y_8289_ = v___x_8301_;
goto v___jp_8285_;
}
else
{
uint32_t v___x_8302_;
v___x_8302_ = lean_uint64_to_uint32(v___y_8298_);
v___y_8286_ = v___y_8295_;
v___y_8287_ = v___y_8296_;
v___y_8288_ = v___y_8297_;
v___y_8289_ = v___x_8302_;
goto v___jp_8285_;
}
}
v___jp_8303_:
{
uint64_t v___x_8307_; uint64_t v___x_8308_; uint8_t v___x_8309_;
v___x_8307_ = 9223372036854775808ULL;
v___x_8308_ = lean_uint64_add(v_curTop_7699_, v___x_8307_);
v___x_8309_ = lean_uint64_dec_lt(v___x_8307_, v___x_8308_);
if (v___x_8309_ == 0)
{
uint64_t v___x_8310_;
v___x_8310_ = 0ULL;
v___y_8295_ = v___y_8306_;
v___y_8296_ = v___y_8304_;
v___y_8297_ = v___y_8305_;
v___y_8298_ = v___x_8310_;
goto v___jp_8294_;
}
else
{
v___y_8295_ = v___y_8306_;
v___y_8296_ = v___y_8304_;
v___y_8297_ = v___y_8305_;
v___y_8298_ = v_curTop_7699_;
goto v___jp_8294_;
}
}
v___jp_8311_:
{
uint8_t v___x_8315_; uint8_t v___x_8316_;
v___x_8315_ = 0;
v___x_8316_ = lean_uint8_dec_eq(v___y_8312_, v___x_8315_);
if (v___x_8316_ == 0)
{
uint32_t v___x_8317_; uint32_t v___x_8318_; uint64_t v___x_8319_; uint64_t v___x_8320_; uint64_t v___x_8321_; uint64_t v___x_8322_;
v___x_8317_ = lean_uint8_to_uint32(v___y_8312_);
v___x_8318_ = lean_uint32_lor(v___x_8317_, v___y_8313_);
v___x_8319_ = lean_uint32_to_uint64(v___x_8318_);
v___x_8320_ = lean_uint32_to_uint64(v___y_8314_);
v___x_8321_ = lean_uint64_shift_left(v___x_8320_, v___x_7703_);
v___x_8322_ = lean_uint64_lor(v___x_8319_, v___x_8321_);
return v___x_8322_;
}
else
{
uint8_t v___x_8323_; uint8_t v___x_8324_; uint8_t v___x_8325_;
v___x_8323_ = 0;
v___x_8324_ = 1;
v___x_8325_ = lean_uint8_dec_eq(v_pinned_7696_, v___x_8324_);
if (v___x_8325_ == 0)
{
uint32_t v___x_8326_;
v___x_8326_ = 0;
v___y_8304_ = v___x_8315_;
v___y_8305_ = v___x_8323_;
v___y_8306_ = v___x_8326_;
goto v___jp_8303_;
}
else
{
uint32_t v___x_8327_;
v___x_8327_ = 512;
v___y_8304_ = v___x_8315_;
v___y_8305_ = v___x_8323_;
v___y_8306_ = v___x_8327_;
goto v___jp_8303_;
}
}
}
v___jp_8328_:
{
uint64_t v___x_8332_; uint8_t v___x_8333_;
v___x_8332_ = 4294967295ULL;
v___x_8333_ = lean_uint64_dec_le(v___y_8331_, v___x_8332_);
if (v___x_8333_ == 0)
{
uint32_t v___x_8334_;
v___x_8334_ = 4294967295;
v___y_8312_ = v___y_8329_;
v___y_8313_ = v___y_8330_;
v___y_8314_ = v___x_8334_;
goto v___jp_8311_;
}
else
{
uint32_t v___x_8335_;
v___x_8335_ = lean_uint64_to_uint32(v___y_8331_);
v___y_8312_ = v___y_8329_;
v___y_8313_ = v___y_8330_;
v___y_8314_ = v___x_8335_;
goto v___jp_8311_;
}
}
v___jp_8336_:
{
uint64_t v___x_8339_; uint64_t v___x_8340_; uint8_t v___x_8341_;
v___x_8339_ = 9223372036854775808ULL;
v___x_8340_ = lean_uint64_add(v_curTop_7699_, v___x_8339_);
v___x_8341_ = lean_uint64_dec_lt(v___x_8339_, v___x_8340_);
if (v___x_8341_ == 0)
{
uint64_t v___x_8342_;
v___x_8342_ = 0ULL;
v___y_8329_ = v___y_8337_;
v___y_8330_ = v___y_8338_;
v___y_8331_ = v___x_8342_;
goto v___jp_8328_;
}
else
{
v___y_8329_ = v___y_8337_;
v___y_8330_ = v___y_8338_;
v___y_8331_ = v_curTop_7699_;
goto v___jp_8328_;
}
}
v___jp_8343_:
{
uint8_t v___x_8345_; uint8_t v___x_8346_;
v___x_8345_ = 1;
v___x_8346_ = lean_uint8_dec_eq(v_pinned_7696_, v___x_8345_);
if (v___x_8346_ == 0)
{
uint32_t v___x_8347_;
v___x_8347_ = 0;
v___y_8337_ = v___y_8344_;
v___y_8338_ = v___x_8347_;
goto v___jp_8336_;
}
else
{
uint32_t v___x_8348_;
v___x_8348_ = 512;
v___y_8337_ = v___y_8344_;
v___y_8338_ = v___x_8348_;
goto v___jp_8336_;
}
}
v___jp_8349_:
{
uint8_t v___x_8350_;
v___x_8350_ = lean_uint64_dec_le(v___x_7703_, v_outCap_7693_);
if (v___x_8350_ == 0)
{
uint8_t v___x_8351_;
v___x_8351_ = 5;
v___y_8344_ = v___x_8351_;
goto v___jp_8343_;
}
else
{
uint8_t v___x_8352_;
v___x_8352_ = 0;
v___y_8344_ = v___x_8352_;
goto v___jp_8343_;
}
}
v___jp_8353_:
{
uint8_t v___x_8354_;
v___x_8354_ = lean_uint64_dec_le(v_outCap_7693_, v_inPtr_7690_);
if (v___x_8354_ == 0)
{
uint8_t v___x_8355_;
v___x_8355_ = 9;
v___y_8344_ = v___x_8355_;
goto v___jp_8343_;
}
else
{
uint64_t v___x_8356_; uint8_t v___x_8357_;
v___x_8356_ = lean_uint64_sub(v_inPtr_7690_, v_outCap_7693_);
v___x_8357_ = lean_uint64_dec_le(v_outPtr_7692_, v___x_8356_);
if (v___x_8357_ == 0)
{
uint8_t v___x_8358_;
v___x_8358_ = 9;
v___y_8344_ = v___x_8358_;
goto v___jp_8343_;
}
else
{
goto v___jp_8349_;
}
}
}
}
}

LEAN_EXPORT uint64_t orb_wire_stream_slice_step(uint64_t v_inPtr_8443_, uint64_t v_inLen_8444_, uint64_t v_outPtr_8445_, uint64_t v_outCap_8446_, uint8_t v_is32Bit_8447_, uint32_t v_prevLen_8448_, uint32_t v_prevCommit_8449_, uint32_t v_prevCheckpoint_8450_, uint32_t v_newLen_8451_, uint32_t v_rawCommit_8452_, uint32_t v_maxOpenTailBytes_8453_){
_start:
{
uint64_t v___x_8454_; uint32_t v___y_8456_; uint32_t v___y_8457_; uint32_t v___y_8458_; uint32_t v___y_8474_; uint32_t v___y_8475_; uint32_t v___y_8476_; uint8_t v___y_8477_; uint8_t v___y_8481_; uint8_t v___y_8482_; uint32_t v___y_8483_; uint8_t v___y_8484_; uint8_t v___y_8485_; uint32_t v___y_8486_; uint32_t v___y_8487_; uint8_t v___y_8489_; uint8_t v___y_8490_; uint32_t v___y_8491_; uint32_t v___y_8492_; uint8_t v___y_8493_; uint8_t v___y_8494_; uint32_t v___y_8495_; uint8_t v___y_8499_; uint32_t v___y_8500_; uint8_t v___y_8501_; uint32_t v___y_8502_; uint8_t v___y_8503_; uint8_t v___y_8504_; uint32_t v___y_8505_; uint32_t v___y_8506_; uint8_t v___y_8509_; uint8_t v___y_8510_; uint32_t v___y_8511_; uint32_t v___y_8512_; uint8_t v___y_8513_; uint8_t v___y_8514_; uint32_t v___y_8515_; uint8_t v___y_8519_; uint8_t v___y_8520_; uint8_t v___y_8521_; uint8_t v___y_8522_; uint32_t v___y_8523_; uint32_t v___y_8524_; uint8_t v___y_8527_; uint8_t v___y_8528_; uint32_t v___y_8529_; uint8_t v___y_8530_; uint8_t v___y_8531_; uint32_t v___y_8532_; uint8_t v___y_8535_; uint8_t v___y_8536_; uint32_t v___y_8537_; uint8_t v___y_8538_; uint8_t v___y_8539_; uint8_t v___y_8542_; uint8_t v___x_8566_; uint8_t v___x_8567_;
v___x_8454_ = 32ULL;
v___x_8566_ = 1;
v___x_8567_ = lean_uint8_dec_le(v_is32Bit_8447_, v___x_8566_);
if (v___x_8567_ == 0)
{
uint8_t v___x_8568_;
v___x_8568_ = 6;
v___y_8542_ = v___x_8568_;
goto v___jp_8541_;
}
else
{
uint64_t v___x_8569_; uint8_t v___x_8570_; uint8_t v___y_8577_; uint8_t v___y_8580_; uint8_t v___y_8599_; uint8_t v___y_8616_;
v___x_8569_ = 0ULL;
v___x_8570_ = lean_uint64_dec_eq(v_inLen_8444_, v___x_8569_);
if (v___x_8570_ == 0)
{
uint8_t v___x_8620_;
v___x_8620_ = lean_uint64_dec_eq(v_inPtr_8443_, v___x_8569_);
if (v___x_8620_ == 0)
{
v___y_8616_ = v___x_8567_;
goto v___jp_8615_;
}
else
{
uint8_t v___x_8621_;
v___x_8621_ = 7;
v___y_8542_ = v___x_8621_;
goto v___jp_8541_;
}
}
else
{
v___y_8616_ = v___x_8567_;
goto v___jp_8615_;
}
v___jp_8571_:
{
if (v___x_8570_ == 0)
{
uint8_t v___x_8572_;
v___x_8572_ = lean_uint64_dec_eq(v_outCap_8446_, v___x_8569_);
if (v___x_8572_ == 0)
{
uint8_t v___x_8573_;
v___x_8573_ = lean_uint64_dec_le(v_inLen_8444_, v_outPtr_8445_);
if (v___x_8573_ == 0)
{
goto v___jp_8560_;
}
else
{
uint64_t v___x_8574_; uint8_t v___x_8575_;
v___x_8574_ = lean_uint64_sub(v_outPtr_8445_, v_inLen_8444_);
v___x_8575_ = lean_uint64_dec_le(v_inPtr_8443_, v___x_8574_);
if (v___x_8575_ == 0)
{
goto v___jp_8560_;
}
else
{
goto v___jp_8556_;
}
}
}
else
{
goto v___jp_8556_;
}
}
else
{
goto v___jp_8556_;
}
}
v___jp_8576_:
{
if (v___y_8577_ == 0)
{
uint8_t v___x_8578_;
v___x_8578_ = 8;
v___y_8542_ = v___x_8578_;
goto v___jp_8541_;
}
else
{
goto v___jp_8571_;
}
}
v___jp_8579_:
{
if (v___y_8580_ == 0)
{
uint8_t v___x_8581_;
v___x_8581_ = 8;
v___y_8542_ = v___x_8581_;
goto v___jp_8541_;
}
else
{
uint8_t v___x_8582_;
v___x_8582_ = lean_uint8_dec_eq(v_is32Bit_8447_, v___x_8566_);
if (v___x_8582_ == 0)
{
uint8_t v___x_8583_;
v___x_8583_ = lean_uint64_dec_eq(v_outPtr_8445_, v___x_8569_);
if (v___x_8583_ == 0)
{
uint8_t v___x_8584_;
v___x_8584_ = lean_uint64_dec_eq(v_outCap_8446_, v___x_8569_);
if (v___x_8584_ == 0)
{
uint64_t v___x_8585_; uint64_t v___x_8586_; uint64_t v___x_8587_; uint64_t v___x_8588_; uint8_t v___x_8589_;
v___x_8585_ = 1ULL;
v___x_8586_ = lean_uint64_sub(v_outPtr_8445_, v___x_8585_);
v___x_8587_ = 18446744073709551615ULL;
v___x_8588_ = lean_uint64_sub(v___x_8587_, v_outCap_8446_);
v___x_8589_ = lean_uint64_dec_le(v___x_8586_, v___x_8588_);
v___y_8577_ = v___x_8589_;
goto v___jp_8576_;
}
else
{
goto v___jp_8571_;
}
}
else
{
goto v___jp_8571_;
}
}
else
{
uint64_t v___x_8590_; uint8_t v___x_8591_;
v___x_8590_ = 4294967295ULL;
v___x_8591_ = lean_uint64_dec_le(v_outPtr_8445_, v___x_8590_);
if (v___x_8591_ == 0)
{
uint8_t v___x_8592_;
v___x_8592_ = 8;
v___y_8542_ = v___x_8592_;
goto v___jp_8541_;
}
else
{
uint8_t v___x_8593_;
v___x_8593_ = lean_uint64_dec_le(v_outCap_8446_, v___x_8590_);
if (v___x_8593_ == 0)
{
uint8_t v___x_8594_;
v___x_8594_ = 8;
v___y_8542_ = v___x_8594_;
goto v___jp_8541_;
}
else
{
uint64_t v___x_8595_; uint64_t v___x_8596_; uint8_t v___x_8597_;
v___x_8595_ = lean_uint64_add(v_outPtr_8445_, v_outCap_8446_);
v___x_8596_ = 4294967296ULL;
v___x_8597_ = lean_uint64_dec_le(v___x_8595_, v___x_8596_);
v___y_8577_ = v___x_8597_;
goto v___jp_8576_;
}
}
}
}
}
v___jp_8598_:
{
uint8_t v___x_8600_;
v___x_8600_ = lean_uint8_dec_eq(v_is32Bit_8447_, v___x_8566_);
if (v___x_8600_ == 0)
{
uint8_t v___x_8601_;
v___x_8601_ = lean_uint64_dec_eq(v_inPtr_8443_, v___x_8569_);
if (v___x_8601_ == 0)
{
if (v___x_8570_ == 0)
{
uint64_t v___x_8602_; uint64_t v___x_8603_; uint64_t v___x_8604_; uint64_t v___x_8605_; uint8_t v___x_8606_;
v___x_8602_ = 1ULL;
v___x_8603_ = lean_uint64_sub(v_inPtr_8443_, v___x_8602_);
v___x_8604_ = 18446744073709551615ULL;
v___x_8605_ = lean_uint64_sub(v___x_8604_, v_inLen_8444_);
v___x_8606_ = lean_uint64_dec_le(v___x_8603_, v___x_8605_);
v___y_8580_ = v___x_8606_;
goto v___jp_8579_;
}
else
{
v___y_8580_ = v___y_8599_;
goto v___jp_8579_;
}
}
else
{
v___y_8580_ = v___y_8599_;
goto v___jp_8579_;
}
}
else
{
uint64_t v___x_8607_; uint8_t v___x_8608_;
v___x_8607_ = 4294967295ULL;
v___x_8608_ = lean_uint64_dec_le(v_inPtr_8443_, v___x_8607_);
if (v___x_8608_ == 0)
{
uint8_t v___x_8609_;
v___x_8609_ = 8;
v___y_8542_ = v___x_8609_;
goto v___jp_8541_;
}
else
{
uint8_t v___x_8610_;
v___x_8610_ = lean_uint64_dec_le(v_inLen_8444_, v___x_8607_);
if (v___x_8610_ == 0)
{
uint8_t v___x_8611_;
v___x_8611_ = 8;
v___y_8542_ = v___x_8611_;
goto v___jp_8541_;
}
else
{
uint64_t v___x_8612_; uint64_t v___x_8613_; uint8_t v___x_8614_;
v___x_8612_ = lean_uint64_add(v_inPtr_8443_, v_inLen_8444_);
v___x_8613_ = 4294967296ULL;
v___x_8614_ = lean_uint64_dec_le(v___x_8612_, v___x_8613_);
v___y_8580_ = v___x_8614_;
goto v___jp_8579_;
}
}
}
}
v___jp_8615_:
{
uint8_t v___x_8617_;
v___x_8617_ = lean_uint64_dec_eq(v_outCap_8446_, v___x_8569_);
if (v___x_8617_ == 0)
{
uint8_t v___x_8618_;
v___x_8618_ = lean_uint64_dec_eq(v_outPtr_8445_, v___x_8569_);
if (v___x_8618_ == 0)
{
v___y_8599_ = v___y_8616_;
goto v___jp_8598_;
}
else
{
uint8_t v___x_8619_;
v___x_8619_ = 7;
v___y_8542_ = v___x_8619_;
goto v___jp_8541_;
}
}
else
{
v___y_8599_ = v___x_8567_;
goto v___jp_8598_;
}
}
}
v___jp_8455_:
{
uint64_t v___x_8459_; uint64_t v___x_8460_; uint64_t v___x_8461_; uint64_t v___x_8462_; uint64_t v___x_8463_; uint64_t v___x_8464_; uint32_t v_stepLo_8465_; uint32_t v___x_8466_; uint32_t v___x_8467_; uint8_t v___x_8468_;
v___x_8459_ = lean_uint32_to_uint64(v___y_8456_);
v___x_8460_ = lean_uint32_to_uint64(v___y_8458_);
v___x_8461_ = lean_uint64_shift_left(v___x_8460_, v___x_8454_);
v___x_8462_ = lean_uint64_lor(v___x_8459_, v___x_8461_);
v___x_8463_ = 4294967295ULL;
v___x_8464_ = lean_uint64_land(v___x_8462_, v___x_8463_);
v_stepLo_8465_ = lean_uint64_to_uint32(v___x_8464_);
v___x_8466_ = 256;
v___x_8467_ = lean_uint32_land(v_stepLo_8465_, v___x_8466_);
v___x_8468_ = lean_uint32_dec_eq(v___x_8467_, v___y_8457_);
if (v___x_8468_ == 0)
{
return v___x_8462_;
}
else
{
uint64_t v___x_8469_; uint64_t v___x_8470_; uint64_t v___x_8471_; uint64_t v___x_8472_;
v___x_8469_ = 3ULL;
v___x_8470_ = lean_uint32_to_uint64(v_prevCheckpoint_8450_);
v___x_8471_ = lean_uint64_shift_left(v___x_8470_, v___x_8454_);
v___x_8472_ = lean_uint64_lor(v___x_8469_, v___x_8471_);
return v___x_8472_;
}
}
v___jp_8473_:
{
if (v___y_8477_ == 0)
{
uint32_t v___x_8478_; uint32_t v___x_8479_;
v___x_8478_ = 257;
v___x_8479_ = lean_uint32_lor(v___x_8478_, v___y_8474_);
v___y_8456_ = v___x_8479_;
v___y_8457_ = v___y_8476_;
v___y_8458_ = v___y_8475_;
goto v___jp_8455_;
}
else
{
v___y_8456_ = v___y_8476_;
v___y_8457_ = v___y_8476_;
v___y_8458_ = v_prevCheckpoint_8450_;
goto v___jp_8455_;
}
}
v___jp_8480_:
{
if (v___y_8482_ == 0)
{
v___y_8474_ = v___y_8487_;
v___y_8475_ = v___y_8483_;
v___y_8476_ = v___y_8486_;
v___y_8477_ = v___y_8485_;
goto v___jp_8473_;
}
else
{
if (v___y_8484_ == 0)
{
v___y_8474_ = v___y_8487_;
v___y_8475_ = v___y_8483_;
v___y_8476_ = v___y_8486_;
v___y_8477_ = v___y_8485_;
goto v___jp_8473_;
}
else
{
v___y_8474_ = v___y_8487_;
v___y_8475_ = v___y_8483_;
v___y_8476_ = v___y_8486_;
v___y_8477_ = v___y_8481_;
goto v___jp_8473_;
}
}
}
v___jp_8488_:
{
uint8_t v___x_8496_;
v___x_8496_ = lean_uint32_dec_lt(v___y_8491_, v___y_8495_);
if (v___x_8496_ == 0)
{
v___y_8481_ = v___y_8489_;
v___y_8482_ = v___y_8490_;
v___y_8483_ = v___y_8495_;
v___y_8484_ = v___y_8494_;
v___y_8485_ = v___y_8493_;
v___y_8486_ = v___y_8492_;
v___y_8487_ = v___y_8492_;
goto v___jp_8480_;
}
else
{
uint32_t v___x_8497_;
v___x_8497_ = 512;
v___y_8481_ = v___y_8489_;
v___y_8482_ = v___y_8490_;
v___y_8483_ = v___y_8495_;
v___y_8484_ = v___y_8494_;
v___y_8485_ = v___y_8493_;
v___y_8486_ = v___y_8492_;
v___y_8487_ = v___x_8497_;
goto v___jp_8480_;
}
}
v___jp_8498_:
{
uint8_t v___x_8507_;
v___x_8507_ = lean_uint32_dec_le(v___y_8500_, v___y_8506_);
if (v___x_8507_ == 0)
{
v___y_8489_ = v___y_8499_;
v___y_8490_ = v___y_8501_;
v___y_8491_ = v___y_8502_;
v___y_8492_ = v___y_8505_;
v___y_8493_ = v___y_8504_;
v___y_8494_ = v___y_8503_;
v___y_8495_ = v___y_8500_;
goto v___jp_8488_;
}
else
{
v___y_8489_ = v___y_8499_;
v___y_8490_ = v___y_8501_;
v___y_8491_ = v___y_8502_;
v___y_8492_ = v___y_8505_;
v___y_8493_ = v___y_8504_;
v___y_8494_ = v___y_8503_;
v___y_8495_ = v___y_8506_;
goto v___jp_8488_;
}
}
v___jp_8508_:
{
uint8_t v___x_8516_;
v___x_8516_ = lean_uint32_dec_le(v_maxOpenTailBytes_8453_, v_newLen_8451_);
if (v___x_8516_ == 0)
{
v___y_8499_ = v___y_8509_;
v___y_8500_ = v___y_8515_;
v___y_8501_ = v___y_8510_;
v___y_8502_ = v___y_8511_;
v___y_8503_ = v___y_8514_;
v___y_8504_ = v___y_8513_;
v___y_8505_ = v___y_8512_;
v___y_8506_ = v___y_8512_;
goto v___jp_8498_;
}
else
{
uint32_t v___x_8517_;
v___x_8517_ = lean_uint32_sub(v_newLen_8451_, v_maxOpenTailBytes_8453_);
v___y_8499_ = v___y_8509_;
v___y_8500_ = v___y_8515_;
v___y_8501_ = v___y_8510_;
v___y_8502_ = v___y_8511_;
v___y_8503_ = v___y_8514_;
v___y_8504_ = v___y_8513_;
v___y_8505_ = v___y_8512_;
v___y_8506_ = v___x_8517_;
goto v___jp_8498_;
}
}
v___jp_8518_:
{
uint8_t v___x_8525_;
v___x_8525_ = lean_uint32_dec_le(v_prevCheckpoint_8450_, v___y_8524_);
if (v___x_8525_ == 0)
{
v___y_8509_ = v___y_8519_;
v___y_8510_ = v___y_8520_;
v___y_8511_ = v___y_8524_;
v___y_8512_ = v___y_8523_;
v___y_8513_ = v___y_8522_;
v___y_8514_ = v___y_8521_;
v___y_8515_ = v_prevCheckpoint_8450_;
goto v___jp_8508_;
}
else
{
v___y_8509_ = v___y_8519_;
v___y_8510_ = v___y_8520_;
v___y_8511_ = v___y_8524_;
v___y_8512_ = v___y_8523_;
v___y_8513_ = v___y_8522_;
v___y_8514_ = v___y_8521_;
v___y_8515_ = v___y_8524_;
goto v___jp_8508_;
}
}
v___jp_8526_:
{
uint8_t v___x_8533_;
v___x_8533_ = lean_uint32_dec_le(v_prevCommit_8449_, v___y_8532_);
if (v___x_8533_ == 0)
{
v___y_8519_ = v___y_8527_;
v___y_8520_ = v___y_8528_;
v___y_8521_ = v___y_8531_;
v___y_8522_ = v___y_8530_;
v___y_8523_ = v___y_8529_;
v___y_8524_ = v_prevCommit_8449_;
goto v___jp_8518_;
}
else
{
v___y_8519_ = v___y_8527_;
v___y_8520_ = v___y_8528_;
v___y_8521_ = v___y_8531_;
v___y_8522_ = v___y_8530_;
v___y_8523_ = v___y_8529_;
v___y_8524_ = v___y_8532_;
goto v___jp_8518_;
}
}
v___jp_8534_:
{
uint8_t v___x_8540_;
v___x_8540_ = lean_uint32_dec_le(v_rawCommit_8452_, v_newLen_8451_);
if (v___x_8540_ == 0)
{
v___y_8527_ = v___y_8535_;
v___y_8528_ = v___y_8536_;
v___y_8529_ = v___y_8537_;
v___y_8530_ = v___y_8538_;
v___y_8531_ = v___y_8539_;
v___y_8532_ = v_newLen_8451_;
goto v___jp_8526_;
}
else
{
v___y_8527_ = v___y_8535_;
v___y_8528_ = v___y_8536_;
v___y_8529_ = v___y_8537_;
v___y_8530_ = v___y_8538_;
v___y_8531_ = v___y_8539_;
v___y_8532_ = v_rawCommit_8452_;
goto v___jp_8526_;
}
}
v___jp_8541_:
{
uint8_t v___x_8543_; uint8_t v___x_8544_;
v___x_8543_ = 0;
v___x_8544_ = lean_uint8_dec_eq(v___y_8542_, v___x_8543_);
if (v___x_8544_ == 0)
{
uint32_t v___x_8545_; uint64_t v___x_8546_; uint64_t v___x_8547_; uint64_t v___x_8548_; uint64_t v___x_8549_;
v___x_8545_ = lean_uint8_to_uint32(v___y_8542_);
v___x_8546_ = lean_uint32_to_uint64(v___x_8545_);
v___x_8547_ = lean_uint32_to_uint64(v_prevCheckpoint_8450_);
v___x_8548_ = lean_uint64_shift_left(v___x_8547_, v___x_8454_);
v___x_8549_ = lean_uint64_lor(v___x_8546_, v___x_8548_);
return v___x_8549_;
}
else
{
uint8_t v___x_8550_; uint32_t v___x_8551_; uint8_t v_validCap_8552_; uint8_t v___x_8553_;
v___x_8550_ = 0;
v___x_8551_ = 0;
v_validCap_8552_ = lean_uint32_dec_lt(v___x_8551_, v_maxOpenTailBytes_8453_);
v___x_8553_ = lean_uint32_dec_le(v_prevCommit_8449_, v_prevCheckpoint_8450_);
if (v___x_8553_ == 0)
{
v___y_8535_ = v___x_8550_;
v___y_8536_ = v_validCap_8552_;
v___y_8537_ = v___x_8551_;
v___y_8538_ = v___x_8544_;
v___y_8539_ = v___x_8553_;
goto v___jp_8534_;
}
else
{
uint8_t v___x_8554_;
v___x_8554_ = lean_uint32_dec_le(v_prevCheckpoint_8450_, v_prevLen_8448_);
if (v___x_8554_ == 0)
{
v___y_8535_ = v___x_8550_;
v___y_8536_ = v_validCap_8552_;
v___y_8537_ = v___x_8551_;
v___y_8538_ = v___x_8544_;
v___y_8539_ = v___x_8554_;
goto v___jp_8534_;
}
else
{
uint8_t v___x_8555_;
v___x_8555_ = lean_uint32_dec_le(v_prevLen_8448_, v_newLen_8451_);
v___y_8535_ = v___x_8550_;
v___y_8536_ = v_validCap_8552_;
v___y_8537_ = v___x_8551_;
v___y_8538_ = v___x_8544_;
v___y_8539_ = v___x_8555_;
goto v___jp_8534_;
}
}
}
}
v___jp_8556_:
{
uint8_t v___x_8557_;
v___x_8557_ = lean_uint64_dec_le(v___x_8454_, v_outCap_8446_);
if (v___x_8557_ == 0)
{
uint8_t v___x_8558_;
v___x_8558_ = 5;
v___y_8542_ = v___x_8558_;
goto v___jp_8541_;
}
else
{
uint8_t v___x_8559_;
v___x_8559_ = 0;
v___y_8542_ = v___x_8559_;
goto v___jp_8541_;
}
}
v___jp_8560_:
{
uint8_t v___x_8561_;
v___x_8561_ = lean_uint64_dec_le(v_outCap_8446_, v_inPtr_8443_);
if (v___x_8561_ == 0)
{
uint8_t v___x_8562_;
v___x_8562_ = 9;
v___y_8542_ = v___x_8562_;
goto v___jp_8541_;
}
else
{
uint64_t v___x_8563_; uint8_t v___x_8564_;
v___x_8563_ = lean_uint64_sub(v_inPtr_8443_, v_outCap_8446_);
v___x_8564_ = lean_uint64_dec_le(v_outPtr_8445_, v___x_8563_);
if (v___x_8564_ == 0)
{
uint8_t v___x_8565_;
v___x_8565_ = 9;
v___y_8542_ = v___x_8565_;
goto v___jp_8541_;
}
else
{
goto v___jp_8556_;
}
}
}
}
}

LEAN_EXPORT uint64_t orb_wire_transcript_slice_step(uint64_t v_inPtr_8844_, uint64_t v_inLen_8845_, uint64_t v_outPtr_8846_, uint64_t v_outCap_8847_, uint8_t v_is32Bit_8848_, uint64_t v_lastAppliedSeq_8849_, uint64_t v_incomingSeq_8850_, uint32_t v_entryCount_8851_, uint8_t v_thinkingOpen_8852_, uint8_t v_normalizedAction_8853_, uint8_t v_isReplayFromLog_8854_){
_start:
{
uint64_t v___x_8855_; uint32_t v___y_8857_; uint32_t v___y_8858_; uint32_t v___y_8864_; uint8_t v___y_8871_; uint32_t v___y_8872_; uint8_t v___y_8874_; uint32_t v___y_8875_; uint8_t v___y_8876_; uint8_t v___y_8877_; uint8_t v___y_8878_; uint8_t v___y_8879_; uint8_t v___y_8880_; uint8_t v___y_8893_; uint32_t v___y_8894_; uint8_t v___y_8895_; uint8_t v___y_8896_; uint8_t v___y_8897_; uint8_t v___y_8898_; uint8_t v___y_8899_; uint32_t v___y_8907_; uint8_t v___y_8908_; uint8_t v___y_8909_; uint8_t v___y_8910_; uint8_t v___y_8911_; uint8_t v___y_8925_; uint8_t v___y_8926_; uint8_t v___y_8927_; uint32_t v___y_8928_; uint8_t v___y_8934_; uint32_t v___y_8935_; uint8_t v___y_8950_; uint8_t v___x_8965_; uint8_t v___x_8966_;
v___x_8855_ = 32ULL;
v___x_8965_ = 1;
v___x_8966_ = lean_uint8_dec_le(v_is32Bit_8848_, v___x_8965_);
if (v___x_8966_ == 0)
{
uint8_t v___x_8967_;
v___x_8967_ = 6;
v___y_8950_ = v___x_8967_;
goto v___jp_8949_;
}
else
{
uint64_t v___x_8968_; uint8_t v___x_8969_; uint8_t v___y_8976_; uint8_t v___y_8979_; uint8_t v___y_8998_; uint8_t v___y_9015_;
v___x_8968_ = 0ULL;
v___x_8969_ = lean_uint64_dec_eq(v_inLen_8845_, v___x_8968_);
if (v___x_8969_ == 0)
{
uint8_t v___x_9019_;
v___x_9019_ = lean_uint64_dec_eq(v_inPtr_8844_, v___x_8968_);
if (v___x_9019_ == 0)
{
v___y_9015_ = v___x_8966_;
goto v___jp_9014_;
}
else
{
uint8_t v___x_9020_;
v___x_9020_ = 7;
v___y_8950_ = v___x_9020_;
goto v___jp_8949_;
}
}
else
{
v___y_9015_ = v___x_8966_;
goto v___jp_9014_;
}
v___jp_8970_:
{
if (v___x_8969_ == 0)
{
uint8_t v___x_8971_;
v___x_8971_ = lean_uint64_dec_eq(v_outCap_8847_, v___x_8968_);
if (v___x_8971_ == 0)
{
uint8_t v___x_8972_;
v___x_8972_ = lean_uint64_dec_le(v_inLen_8845_, v_outPtr_8846_);
if (v___x_8972_ == 0)
{
goto v___jp_8959_;
}
else
{
uint64_t v___x_8973_; uint8_t v___x_8974_;
v___x_8973_ = lean_uint64_sub(v_outPtr_8846_, v_inLen_8845_);
v___x_8974_ = lean_uint64_dec_le(v_inPtr_8844_, v___x_8973_);
if (v___x_8974_ == 0)
{
goto v___jp_8959_;
}
else
{
goto v___jp_8955_;
}
}
}
else
{
goto v___jp_8955_;
}
}
else
{
goto v___jp_8955_;
}
}
v___jp_8975_:
{
if (v___y_8976_ == 0)
{
uint8_t v___x_8977_;
v___x_8977_ = 8;
v___y_8950_ = v___x_8977_;
goto v___jp_8949_;
}
else
{
goto v___jp_8970_;
}
}
v___jp_8978_:
{
if (v___y_8979_ == 0)
{
uint8_t v___x_8980_;
v___x_8980_ = 8;
v___y_8950_ = v___x_8980_;
goto v___jp_8949_;
}
else
{
uint8_t v___x_8981_;
v___x_8981_ = lean_uint8_dec_eq(v_is32Bit_8848_, v___x_8965_);
if (v___x_8981_ == 0)
{
uint8_t v___x_8982_;
v___x_8982_ = lean_uint64_dec_eq(v_outPtr_8846_, v___x_8968_);
if (v___x_8982_ == 0)
{
uint8_t v___x_8983_;
v___x_8983_ = lean_uint64_dec_eq(v_outCap_8847_, v___x_8968_);
if (v___x_8983_ == 0)
{
uint64_t v___x_8984_; uint64_t v___x_8985_; uint64_t v___x_8986_; uint64_t v___x_8987_; uint8_t v___x_8988_;
v___x_8984_ = 1ULL;
v___x_8985_ = lean_uint64_sub(v_outPtr_8846_, v___x_8984_);
v___x_8986_ = 18446744073709551615ULL;
v___x_8987_ = lean_uint64_sub(v___x_8986_, v_outCap_8847_);
v___x_8988_ = lean_uint64_dec_le(v___x_8985_, v___x_8987_);
v___y_8976_ = v___x_8988_;
goto v___jp_8975_;
}
else
{
goto v___jp_8970_;
}
}
else
{
goto v___jp_8970_;
}
}
else
{
uint64_t v___x_8989_; uint8_t v___x_8990_;
v___x_8989_ = 4294967295ULL;
v___x_8990_ = lean_uint64_dec_le(v_outPtr_8846_, v___x_8989_);
if (v___x_8990_ == 0)
{
uint8_t v___x_8991_;
v___x_8991_ = 8;
v___y_8950_ = v___x_8991_;
goto v___jp_8949_;
}
else
{
uint8_t v___x_8992_;
v___x_8992_ = lean_uint64_dec_le(v_outCap_8847_, v___x_8989_);
if (v___x_8992_ == 0)
{
uint8_t v___x_8993_;
v___x_8993_ = 8;
v___y_8950_ = v___x_8993_;
goto v___jp_8949_;
}
else
{
uint64_t v___x_8994_; uint64_t v___x_8995_; uint8_t v___x_8996_;
v___x_8994_ = lean_uint64_add(v_outPtr_8846_, v_outCap_8847_);
v___x_8995_ = 4294967296ULL;
v___x_8996_ = lean_uint64_dec_le(v___x_8994_, v___x_8995_);
v___y_8976_ = v___x_8996_;
goto v___jp_8975_;
}
}
}
}
}
v___jp_8997_:
{
uint8_t v___x_8999_;
v___x_8999_ = lean_uint8_dec_eq(v_is32Bit_8848_, v___x_8965_);
if (v___x_8999_ == 0)
{
uint8_t v___x_9000_;
v___x_9000_ = lean_uint64_dec_eq(v_inPtr_8844_, v___x_8968_);
if (v___x_9000_ == 0)
{
if (v___x_8969_ == 0)
{
uint64_t v___x_9001_; uint64_t v___x_9002_; uint64_t v___x_9003_; uint64_t v___x_9004_; uint8_t v___x_9005_;
v___x_9001_ = 1ULL;
v___x_9002_ = lean_uint64_sub(v_inPtr_8844_, v___x_9001_);
v___x_9003_ = 18446744073709551615ULL;
v___x_9004_ = lean_uint64_sub(v___x_9003_, v_inLen_8845_);
v___x_9005_ = lean_uint64_dec_le(v___x_9002_, v___x_9004_);
v___y_8979_ = v___x_9005_;
goto v___jp_8978_;
}
else
{
v___y_8979_ = v___y_8998_;
goto v___jp_8978_;
}
}
else
{
v___y_8979_ = v___y_8998_;
goto v___jp_8978_;
}
}
else
{
uint64_t v___x_9006_; uint8_t v___x_9007_;
v___x_9006_ = 4294967295ULL;
v___x_9007_ = lean_uint64_dec_le(v_inPtr_8844_, v___x_9006_);
if (v___x_9007_ == 0)
{
uint8_t v___x_9008_;
v___x_9008_ = 8;
v___y_8950_ = v___x_9008_;
goto v___jp_8949_;
}
else
{
uint8_t v___x_9009_;
v___x_9009_ = lean_uint64_dec_le(v_inLen_8845_, v___x_9006_);
if (v___x_9009_ == 0)
{
uint8_t v___x_9010_;
v___x_9010_ = 8;
v___y_8950_ = v___x_9010_;
goto v___jp_8949_;
}
else
{
uint64_t v___x_9011_; uint64_t v___x_9012_; uint8_t v___x_9013_;
v___x_9011_ = lean_uint64_add(v_inPtr_8844_, v_inLen_8845_);
v___x_9012_ = 4294967296ULL;
v___x_9013_ = lean_uint64_dec_le(v___x_9011_, v___x_9012_);
v___y_8979_ = v___x_9013_;
goto v___jp_8978_;
}
}
}
}
v___jp_9014_:
{
uint8_t v___x_9016_;
v___x_9016_ = lean_uint64_dec_eq(v_outCap_8847_, v___x_8968_);
if (v___x_9016_ == 0)
{
uint8_t v___x_9017_;
v___x_9017_ = lean_uint64_dec_eq(v_outPtr_8846_, v___x_8968_);
if (v___x_9017_ == 0)
{
v___y_8998_ = v___y_9015_;
goto v___jp_8997_;
}
else
{
uint8_t v___x_9018_;
v___x_9018_ = 7;
v___y_8950_ = v___x_9018_;
goto v___jp_8949_;
}
}
else
{
v___y_8998_ = v___x_8966_;
goto v___jp_8997_;
}
}
}
v___jp_8856_:
{
uint64_t v___x_8859_; uint64_t v___x_8860_; uint64_t v___x_8861_; uint64_t v___x_8862_;
v___x_8859_ = lean_uint32_to_uint64(v___y_8857_);
v___x_8860_ = lean_uint32_to_uint64(v___y_8858_);
v___x_8861_ = lean_uint64_shift_left(v___x_8860_, v___x_8855_);
v___x_8862_ = lean_uint64_lor(v___x_8859_, v___x_8861_);
return v___x_8862_;
}
v___jp_8863_:
{
uint32_t v___x_8865_; uint8_t v___x_8866_;
v___x_8865_ = 4294967294;
v___x_8866_ = lean_uint32_dec_le(v_entryCount_8851_, v___x_8865_);
if (v___x_8866_ == 0)
{
uint32_t v___x_8867_;
v___x_8867_ = 4294967295;
v___y_8857_ = v___y_8864_;
v___y_8858_ = v___x_8867_;
goto v___jp_8856_;
}
else
{
uint32_t v___x_8868_; uint32_t v___x_8869_;
v___x_8868_ = 1;
v___x_8869_ = lean_uint32_add(v_entryCount_8851_, v___x_8868_);
v___y_8857_ = v___y_8864_;
v___y_8858_ = v___x_8869_;
goto v___jp_8856_;
}
}
v___jp_8870_:
{
if (v___y_8871_ == 0)
{
v___y_8857_ = v___y_8872_;
v___y_8858_ = v_entryCount_8851_;
goto v___jp_8856_;
}
else
{
v___y_8864_ = v___y_8872_;
goto v___jp_8863_;
}
}
v___jp_8873_:
{
if (v___y_8876_ == 0)
{
if (v___y_8879_ == 0)
{
uint32_t v___x_8881_; uint32_t v___x_8882_;
v___x_8881_ = 2051;
v___x_8882_ = lean_uint32_lor(v___x_8881_, v___y_8875_);
v___y_8857_ = v___x_8882_;
v___y_8858_ = v_entryCount_8851_;
goto v___jp_8856_;
}
else
{
if (v___y_8878_ == 0)
{
if (v___y_8874_ == 0)
{
if (v___y_8880_ == 0)
{
uint32_t v___x_8883_; uint32_t v___x_8884_;
v___x_8883_ = 4;
v___x_8884_ = lean_uint32_lor(v___x_8883_, v___y_8875_);
v___y_8857_ = v___x_8884_;
v___y_8858_ = v_entryCount_8851_;
goto v___jp_8856_;
}
else
{
uint32_t v___x_8885_; uint32_t v___x_8886_;
v___x_8885_ = 260;
v___x_8886_ = lean_uint32_lor(v___x_8885_, v___y_8875_);
v___y_8857_ = v___x_8886_;
v___y_8858_ = v_entryCount_8851_;
goto v___jp_8856_;
}
}
else
{
if (v___y_8877_ == 0)
{
uint32_t v___x_8887_;
v___x_8887_ = 257;
v___y_8864_ = v___x_8887_;
goto v___jp_8863_;
}
else
{
uint32_t v___x_8888_;
v___x_8888_ = 1281;
v___y_8864_ = v___x_8888_;
goto v___jp_8863_;
}
}
}
else
{
uint32_t v___x_8889_;
v___x_8889_ = 769;
v___y_8871_ = v___y_8874_;
v___y_8872_ = v___x_8889_;
goto v___jp_8870_;
}
}
}
else
{
uint32_t v___x_8890_; uint32_t v___x_8891_;
v___x_8890_ = 2;
v___x_8891_ = lean_uint32_lor(v___x_8890_, v___y_8875_);
if (v___y_8879_ == 0)
{
v___y_8857_ = v___x_8891_;
v___y_8858_ = v_entryCount_8851_;
goto v___jp_8856_;
}
else
{
v___y_8871_ = v___y_8874_;
v___y_8872_ = v___x_8891_;
goto v___jp_8870_;
}
}
}
v___jp_8892_:
{
uint8_t v___x_8900_; uint8_t v___x_8901_;
v___x_8900_ = 2;
v___x_8901_ = lean_uint8_dec_eq(v_normalizedAction_8853_, v___x_8900_);
if (v___x_8901_ == 0)
{
uint8_t v___x_8902_; uint8_t v___x_8903_;
v___x_8902_ = 3;
v___x_8903_ = lean_uint8_dec_eq(v_normalizedAction_8853_, v___x_8902_);
if (v___x_8903_ == 0)
{
uint8_t v___x_8904_; uint8_t v___x_8905_;
v___x_8904_ = 8;
v___x_8905_ = lean_uint8_dec_eq(v_normalizedAction_8853_, v___x_8904_);
v___y_8874_ = v___y_8899_;
v___y_8875_ = v___y_8894_;
v___y_8876_ = v___y_8895_;
v___y_8877_ = v___y_8897_;
v___y_8878_ = v___y_8896_;
v___y_8879_ = v___y_8898_;
v___y_8880_ = v___x_8905_;
goto v___jp_8873_;
}
else
{
v___y_8874_ = v___y_8899_;
v___y_8875_ = v___y_8894_;
v___y_8876_ = v___y_8895_;
v___y_8877_ = v___y_8897_;
v___y_8878_ = v___y_8896_;
v___y_8879_ = v___y_8898_;
v___y_8880_ = v___y_8893_;
goto v___jp_8873_;
}
}
else
{
v___y_8874_ = v___y_8899_;
v___y_8875_ = v___y_8894_;
v___y_8876_ = v___y_8895_;
v___y_8877_ = v___y_8897_;
v___y_8878_ = v___y_8896_;
v___y_8879_ = v___y_8898_;
v___y_8880_ = v___y_8893_;
goto v___jp_8873_;
}
}
v___jp_8906_:
{
uint8_t v___x_8912_; uint8_t v_isOpenThink_8913_; uint8_t v___x_8914_; uint8_t v___x_8915_;
v___x_8912_ = 4;
v_isOpenThink_8913_ = lean_uint8_dec_eq(v_normalizedAction_8853_, v___x_8912_);
v___x_8914_ = 5;
v___x_8915_ = lean_uint8_dec_eq(v_normalizedAction_8853_, v___x_8914_);
if (v___x_8915_ == 0)
{
uint8_t v___x_8916_; uint8_t v___x_8917_;
v___x_8916_ = 6;
v___x_8917_ = lean_uint8_dec_eq(v_normalizedAction_8853_, v___x_8916_);
if (v___x_8917_ == 0)
{
uint8_t v___x_8918_; uint8_t v___x_8919_;
v___x_8918_ = 7;
v___x_8919_ = lean_uint8_dec_eq(v_normalizedAction_8853_, v___x_8918_);
if (v___x_8919_ == 0)
{
uint8_t v___x_8920_; uint8_t v___x_8921_;
v___x_8920_ = 9;
v___x_8921_ = lean_uint8_dec_eq(v_normalizedAction_8853_, v___x_8920_);
if (v___x_8921_ == 0)
{
uint8_t v___x_8922_; uint8_t v___x_8923_;
v___x_8922_ = 10;
v___x_8923_ = lean_uint8_dec_eq(v_normalizedAction_8853_, v___x_8922_);
v___y_8893_ = v___y_8908_;
v___y_8894_ = v___y_8907_;
v___y_8895_ = v___y_8909_;
v___y_8896_ = v_isOpenThink_8913_;
v___y_8897_ = v___y_8910_;
v___y_8898_ = v___y_8911_;
v___y_8899_ = v___x_8923_;
goto v___jp_8892_;
}
else
{
v___y_8893_ = v___y_8908_;
v___y_8894_ = v___y_8907_;
v___y_8895_ = v___y_8909_;
v___y_8896_ = v_isOpenThink_8913_;
v___y_8897_ = v___y_8910_;
v___y_8898_ = v___y_8911_;
v___y_8899_ = v___y_8908_;
goto v___jp_8892_;
}
}
else
{
v___y_8893_ = v___y_8908_;
v___y_8894_ = v___y_8907_;
v___y_8895_ = v___y_8909_;
v___y_8896_ = v_isOpenThink_8913_;
v___y_8897_ = v___y_8910_;
v___y_8898_ = v___y_8911_;
v___y_8899_ = v___y_8908_;
goto v___jp_8892_;
}
}
else
{
v___y_8893_ = v___y_8908_;
v___y_8894_ = v___y_8907_;
v___y_8895_ = v___y_8909_;
v___y_8896_ = v_isOpenThink_8913_;
v___y_8897_ = v___y_8910_;
v___y_8898_ = v___y_8911_;
v___y_8899_ = v___y_8908_;
goto v___jp_8892_;
}
}
else
{
v___y_8893_ = v___y_8908_;
v___y_8894_ = v___y_8907_;
v___y_8895_ = v___y_8909_;
v___y_8896_ = v_isOpenThink_8913_;
v___y_8897_ = v___y_8910_;
v___y_8898_ = v___y_8911_;
v___y_8899_ = v___y_8908_;
goto v___jp_8892_;
}
}
v___jp_8924_:
{
uint8_t v_isDuplicate_8929_;
v_isDuplicate_8929_ = lean_uint64_dec_le(v_incomingSeq_8850_, v_lastAppliedSeq_8849_);
if (v_isDuplicate_8929_ == 0)
{
uint64_t v___x_8930_; uint64_t v___x_8931_; uint8_t v___x_8932_;
v___x_8930_ = lean_uint64_sub(v_incomingSeq_8850_, v_lastAppliedSeq_8849_);
v___x_8931_ = 1ULL;
v___x_8932_ = lean_uint64_dec_eq(v___x_8930_, v___x_8931_);
v___y_8907_ = v___y_8928_;
v___y_8908_ = v___y_8925_;
v___y_8909_ = v_isDuplicate_8929_;
v___y_8910_ = v___y_8927_;
v___y_8911_ = v___x_8932_;
goto v___jp_8906_;
}
else
{
v___y_8907_ = v___y_8928_;
v___y_8908_ = v___y_8925_;
v___y_8909_ = v_isDuplicate_8929_;
v___y_8910_ = v___y_8927_;
v___y_8911_ = v___y_8926_;
goto v___jp_8906_;
}
}
v___jp_8933_:
{
uint8_t v___x_8936_; uint8_t v___x_8937_;
v___x_8936_ = 0;
v___x_8937_ = lean_uint8_dec_eq(v___y_8934_, v___x_8936_);
if (v___x_8937_ == 0)
{
uint32_t v___x_8938_; uint32_t v___x_8939_; uint64_t v___x_8940_; uint64_t v___x_8941_; uint64_t v___x_8942_; uint64_t v___x_8943_;
v___x_8938_ = lean_uint8_to_uint32(v___y_8934_);
v___x_8939_ = lean_uint32_lor(v___x_8938_, v___y_8935_);
v___x_8940_ = lean_uint32_to_uint64(v___x_8939_);
v___x_8941_ = lean_uint32_to_uint64(v_entryCount_8851_);
v___x_8942_ = lean_uint64_shift_left(v___x_8941_, v___x_8855_);
v___x_8943_ = lean_uint64_lor(v___x_8940_, v___x_8942_);
return v___x_8943_;
}
else
{
uint8_t v___x_8944_; uint8_t v___x_8945_; uint8_t v___x_8946_;
v___x_8944_ = 0;
v___x_8945_ = 1;
v___x_8946_ = lean_uint8_dec_eq(v_thinkingOpen_8852_, v___x_8945_);
if (v___x_8946_ == 0)
{
uint32_t v___x_8947_;
v___x_8947_ = 0;
v___y_8925_ = v___x_8937_;
v___y_8926_ = v___x_8944_;
v___y_8927_ = v___x_8946_;
v___y_8928_ = v___x_8947_;
goto v___jp_8924_;
}
else
{
uint32_t v___x_8948_;
v___x_8948_ = 512;
v___y_8925_ = v___x_8937_;
v___y_8926_ = v___x_8944_;
v___y_8927_ = v___x_8946_;
v___y_8928_ = v___x_8948_;
goto v___jp_8924_;
}
}
}
v___jp_8949_:
{
uint8_t v___x_8951_; uint8_t v___x_8952_;
v___x_8951_ = 1;
v___x_8952_ = lean_uint8_dec_eq(v_thinkingOpen_8852_, v___x_8951_);
if (v___x_8952_ == 0)
{
uint32_t v___x_8953_;
v___x_8953_ = 0;
v___y_8934_ = v___y_8950_;
v___y_8935_ = v___x_8953_;
goto v___jp_8933_;
}
else
{
uint32_t v___x_8954_;
v___x_8954_ = 512;
v___y_8934_ = v___y_8950_;
v___y_8935_ = v___x_8954_;
goto v___jp_8933_;
}
}
v___jp_8955_:
{
uint8_t v___x_8956_;
v___x_8956_ = lean_uint64_dec_le(v___x_8855_, v_outCap_8847_);
if (v___x_8956_ == 0)
{
uint8_t v___x_8957_;
v___x_8957_ = 5;
v___y_8950_ = v___x_8957_;
goto v___jp_8949_;
}
else
{
uint8_t v___x_8958_;
v___x_8958_ = 0;
v___y_8950_ = v___x_8958_;
goto v___jp_8949_;
}
}
v___jp_8959_:
{
uint8_t v___x_8960_;
v___x_8960_ = lean_uint64_dec_le(v_outCap_8847_, v_inPtr_8844_);
if (v___x_8960_ == 0)
{
uint8_t v___x_8961_;
v___x_8961_ = 9;
v___y_8950_ = v___x_8961_;
goto v___jp_8949_;
}
else
{
uint64_t v___x_8962_; uint8_t v___x_8963_;
v___x_8962_ = lean_uint64_sub(v_inPtr_8844_, v_outCap_8847_);
v___x_8963_ = lean_uint64_dec_le(v_outPtr_8846_, v___x_8962_);
if (v___x_8963_ == 0)
{
uint8_t v___x_8964_;
v___x_8964_ = 9;
v___y_8950_ = v___x_8964_;
goto v___jp_8949_;
}
else
{
goto v___jp_8955_;
}
}
}
}
}

LEAN_EXPORT uint64_t orb_placement_merge_step(uint64_t v_curRev_9173_, uint64_t v_incRev_9174_, uint32_t v_pendingOpId_9175_, uint32_t v_ackOpId_9176_, uint8_t v_sourceKind_9177_, uint8_t v_hasPlacement_9178_){
_start:
{
uint32_t v___y_9180_; uint32_t v___y_9181_; uint32_t v___y_9188_; uint32_t v___y_9189_; uint32_t v___y_9190_; uint32_t v___y_9206_; uint32_t v___y_9207_; uint32_t v___y_9213_; uint32_t v___y_9219_; uint8_t v___x_9222_; uint8_t v___x_9223_;
v___x_9222_ = 3;
v___x_9223_ = lean_uint8_dec_le(v_sourceKind_9177_, v___x_9222_);
if (v___x_9223_ == 0)
{
uint32_t v___x_9224_;
v___x_9224_ = 2;
v___y_9213_ = v___x_9224_;
goto v___jp_9212_;
}
else
{
uint8_t v___x_9225_; uint8_t v___x_9226_;
v___x_9225_ = 2;
v___x_9226_ = lean_uint8_dec_eq(v_sourceKind_9177_, v___x_9225_);
if (v___x_9226_ == 0)
{
uint8_t v___x_9227_;
v___x_9227_ = lean_uint8_dec_eq(v_sourceKind_9177_, v___x_9222_);
if (v___x_9227_ == 0)
{
uint8_t v___x_9228_; uint8_t v___x_9229_;
v___x_9228_ = 1;
v___x_9229_ = lean_uint8_dec_eq(v_hasPlacement_9178_, v___x_9228_);
if (v___x_9229_ == 0)
{
uint32_t v___x_9230_;
v___x_9230_ = 3;
v___y_9213_ = v___x_9230_;
goto v___jp_9212_;
}
else
{
uint32_t v___x_9231_; uint8_t v___x_9232_;
v___x_9231_ = 0;
v___x_9232_ = lean_uint32_dec_eq(v_pendingOpId_9175_, v___x_9231_);
if (v___x_9232_ == 0)
{
uint8_t v___x_9233_;
v___x_9233_ = lean_uint64_dec_lt(v_curRev_9173_, v_incRev_9174_);
if (v___x_9233_ == 0)
{
uint8_t v___x_9234_;
v___x_9234_ = lean_uint8_dec_eq(v_sourceKind_9177_, v___x_9228_);
if (v___x_9234_ == 0)
{
uint32_t v___x_9235_;
v___x_9235_ = 5;
v___y_9213_ = v___x_9235_;
goto v___jp_9212_;
}
else
{
uint8_t v___x_9236_;
v___x_9236_ = lean_uint32_dec_eq(v_ackOpId_9176_, v_pendingOpId_9175_);
if (v___x_9236_ == 0)
{
uint32_t v___x_9237_;
v___x_9237_ = 5;
v___y_9213_ = v___x_9237_;
goto v___jp_9212_;
}
else
{
uint8_t v___x_9238_;
v___x_9238_ = lean_uint64_dec_le(v_curRev_9173_, v_incRev_9174_);
if (v___x_9238_ == 0)
{
uint32_t v___x_9239_;
v___x_9239_ = 5;
v___y_9213_ = v___x_9239_;
goto v___jp_9212_;
}
else
{
uint32_t v___x_9240_;
v___x_9240_ = 1793;
v___y_9213_ = v___x_9240_;
goto v___jp_9212_;
}
}
}
}
else
{
uint8_t v___x_9241_; uint8_t v___x_9242_;
v___x_9241_ = 0;
v___x_9242_ = lean_uint8_dec_eq(v_sourceKind_9177_, v___x_9241_);
if (v___x_9242_ == 0)
{
uint8_t v___x_9243_;
v___x_9243_ = lean_uint8_dec_eq(v_sourceKind_9177_, v___x_9228_);
if (v___x_9243_ == 0)
{
uint32_t v___x_9244_;
v___x_9244_ = 1793;
v___y_9213_ = v___x_9244_;
goto v___jp_9212_;
}
else
{
uint8_t v___x_9245_;
v___x_9245_ = lean_uint32_dec_lt(v_ackOpId_9176_, v_pendingOpId_9175_);
if (v___x_9245_ == 0)
{
uint32_t v___x_9246_;
v___x_9246_ = 1793;
v___y_9213_ = v___x_9246_;
goto v___jp_9212_;
}
else
{
uint32_t v___x_9247_;
v___x_9247_ = 1281;
v___y_9213_ = v___x_9247_;
goto v___jp_9212_;
}
}
}
else
{
uint32_t v___x_9248_;
v___x_9248_ = 1281;
v___y_9213_ = v___x_9248_;
goto v___jp_9212_;
}
}
}
else
{
uint8_t v___x_9249_;
v___x_9249_ = lean_uint8_dec_eq(v_sourceKind_9177_, v___x_9228_);
if (v___x_9249_ == 0)
{
uint8_t v___x_9250_;
v___x_9250_ = lean_uint64_dec_le(v_curRev_9173_, v_incRev_9174_);
if (v___x_9250_ == 0)
{
uint32_t v___x_9251_;
v___x_9251_ = 4;
v___y_9213_ = v___x_9251_;
goto v___jp_9212_;
}
else
{
uint8_t v___x_9252_;
v___x_9252_ = lean_uint64_dec_lt(v_curRev_9173_, v_incRev_9174_);
if (v___x_9252_ == 0)
{
v___y_9219_ = v___x_9231_;
goto v___jp_9218_;
}
else
{
uint32_t v___x_9253_;
v___x_9253_ = 1024;
v___y_9219_ = v___x_9253_;
goto v___jp_9218_;
}
}
}
else
{
uint8_t v___x_9254_;
v___x_9254_ = lean_uint64_dec_le(v_curRev_9173_, v_incRev_9174_);
if (v___x_9254_ == 0)
{
uint32_t v___x_9255_;
v___x_9255_ = 4;
v___y_9213_ = v___x_9255_;
goto v___jp_9212_;
}
else
{
uint32_t v___x_9256_;
v___x_9256_ = 1281;
v___y_9213_ = v___x_9256_;
goto v___jp_9212_;
}
}
}
}
}
else
{
uint32_t v___x_9257_; uint8_t v___x_9258_;
v___x_9257_ = 0;
v___x_9258_ = lean_uint32_dec_eq(v_pendingOpId_9175_, v___x_9257_);
if (v___x_9258_ == 0)
{
uint8_t v___x_9259_;
v___x_9259_ = lean_uint32_dec_eq(v_ackOpId_9176_, v_pendingOpId_9175_);
if (v___x_9259_ == 0)
{
uint32_t v___x_9260_;
v___x_9260_ = 6;
v___y_9213_ = v___x_9260_;
goto v___jp_9212_;
}
else
{
uint32_t v___x_9261_;
v___x_9261_ = 1793;
v___y_9213_ = v___x_9261_;
goto v___jp_9212_;
}
}
else
{
uint32_t v___x_9262_;
v___x_9262_ = 6;
v___y_9213_ = v___x_9262_;
goto v___jp_9212_;
}
}
}
else
{
uint8_t v___x_9263_; uint8_t v___x_9264_;
v___x_9263_ = 1;
v___x_9264_ = lean_uint8_dec_eq(v_hasPlacement_9178_, v___x_9263_);
if (v___x_9264_ == 0)
{
uint32_t v___x_9265_;
v___x_9265_ = 3;
v___y_9213_ = v___x_9265_;
goto v___jp_9212_;
}
else
{
uint32_t v___x_9266_; uint8_t v___x_9267_;
v___x_9266_ = 0;
v___x_9267_ = lean_uint32_dec_eq(v_ackOpId_9176_, v___x_9266_);
if (v___x_9267_ == 0)
{
uint32_t v___x_9268_;
v___x_9268_ = 1281;
v___y_9213_ = v___x_9268_;
goto v___jp_9212_;
}
else
{
uint32_t v___x_9269_;
v___x_9269_ = 3;
v___y_9213_ = v___x_9269_;
goto v___jp_9212_;
}
}
}
}
v___jp_9179_:
{
uint64_t v___x_9182_; uint64_t v___x_9183_; uint64_t v___x_9184_; uint64_t v___x_9185_; uint64_t v___x_9186_;
v___x_9182_ = lean_uint32_to_uint64(v___y_9180_);
v___x_9183_ = lean_uint32_to_uint64(v___y_9181_);
v___x_9184_ = 32ULL;
v___x_9185_ = lean_uint64_shift_left(v___x_9183_, v___x_9184_);
v___x_9186_ = lean_uint64_lor(v___x_9182_, v___x_9185_);
return v___x_9186_;
}
v___jp_9187_:
{
uint8_t v___x_9191_; uint8_t v___x_9192_;
v___x_9191_ = 3;
v___x_9192_ = lean_uint8_dec_le(v_sourceKind_9177_, v___x_9191_);
if (v___x_9192_ == 0)
{
v___y_9180_ = v___y_9189_;
v___y_9181_ = v___y_9188_;
goto v___jp_9179_;
}
else
{
uint8_t v___x_9193_; uint8_t v___x_9194_;
v___x_9193_ = 2;
v___x_9194_ = lean_uint8_dec_eq(v_sourceKind_9177_, v___x_9193_);
if (v___x_9194_ == 0)
{
uint8_t v___x_9195_;
v___x_9195_ = lean_uint8_dec_eq(v_sourceKind_9177_, v___x_9191_);
if (v___x_9195_ == 0)
{
uint8_t v___x_9196_; uint8_t v___x_9197_;
v___x_9196_ = 1;
v___x_9197_ = lean_uint8_dec_eq(v_hasPlacement_9178_, v___x_9196_);
if (v___x_9197_ == 0)
{
v___y_9180_ = v___y_9189_;
v___y_9181_ = v___y_9188_;
goto v___jp_9179_;
}
else
{
uint32_t v___x_9198_; uint8_t v___x_9199_;
v___x_9198_ = 0;
v___x_9199_ = lean_uint32_dec_eq(v_pendingOpId_9175_, v___x_9198_);
if (v___x_9199_ == 0)
{
uint8_t v___x_9200_;
v___x_9200_ = lean_uint64_dec_lt(v_curRev_9173_, v_incRev_9174_);
if (v___x_9200_ == 0)
{
uint8_t v___x_9201_;
v___x_9201_ = lean_uint8_dec_eq(v_sourceKind_9177_, v___x_9196_);
if (v___x_9201_ == 0)
{
v___y_9180_ = v___y_9189_;
v___y_9181_ = v___y_9188_;
goto v___jp_9179_;
}
else
{
uint8_t v___x_9202_;
v___x_9202_ = lean_uint32_dec_eq(v_ackOpId_9176_, v_pendingOpId_9175_);
if (v___x_9202_ == 0)
{
v___y_9180_ = v___y_9189_;
v___y_9181_ = v___y_9188_;
goto v___jp_9179_;
}
else
{
uint8_t v___x_9203_;
v___x_9203_ = lean_uint64_dec_le(v_curRev_9173_, v_incRev_9174_);
if (v___x_9203_ == 0)
{
v___y_9180_ = v___y_9189_;
v___y_9181_ = v___y_9188_;
goto v___jp_9179_;
}
else
{
v___y_9180_ = v___y_9189_;
v___y_9181_ = v___y_9190_;
goto v___jp_9179_;
}
}
}
}
else
{
v___y_9180_ = v___y_9189_;
v___y_9181_ = v___y_9190_;
goto v___jp_9179_;
}
}
else
{
uint8_t v___x_9204_;
v___x_9204_ = lean_uint64_dec_le(v_curRev_9173_, v_incRev_9174_);
if (v___x_9204_ == 0)
{
v___y_9180_ = v___y_9189_;
v___y_9181_ = v___y_9188_;
goto v___jp_9179_;
}
else
{
v___y_9180_ = v___y_9189_;
v___y_9181_ = v___y_9190_;
goto v___jp_9179_;
}
}
}
}
else
{
v___y_9180_ = v___y_9189_;
v___y_9181_ = v___y_9188_;
goto v___jp_9179_;
}
}
else
{
v___y_9180_ = v___y_9189_;
v___y_9181_ = v___y_9188_;
goto v___jp_9179_;
}
}
}
v___jp_9205_:
{
uint64_t v___x_9208_; uint8_t v___x_9209_;
v___x_9208_ = 4294967295ULL;
v___x_9209_ = lean_uint64_dec_le(v_incRev_9174_, v___x_9208_);
if (v___x_9209_ == 0)
{
uint32_t v___x_9210_;
v___x_9210_ = 4294967295;
v___y_9188_ = v___y_9207_;
v___y_9189_ = v___y_9206_;
v___y_9190_ = v___x_9210_;
goto v___jp_9187_;
}
else
{
uint32_t v___x_9211_;
v___x_9211_ = lean_uint64_to_uint32(v_incRev_9174_);
v___y_9188_ = v___y_9207_;
v___y_9189_ = v___y_9206_;
v___y_9190_ = v___x_9211_;
goto v___jp_9187_;
}
}
v___jp_9212_:
{
uint64_t v___x_9214_; uint8_t v___x_9215_;
v___x_9214_ = 4294967295ULL;
v___x_9215_ = lean_uint64_dec_le(v_curRev_9173_, v___x_9214_);
if (v___x_9215_ == 0)
{
uint32_t v___x_9216_;
v___x_9216_ = 4294967295;
v___y_9206_ = v___y_9213_;
v___y_9207_ = v___x_9216_;
goto v___jp_9205_;
}
else
{
uint32_t v___x_9217_;
v___x_9217_ = lean_uint64_to_uint32(v_curRev_9173_);
v___y_9206_ = v___y_9213_;
v___y_9207_ = v___x_9217_;
goto v___jp_9205_;
}
}
v___jp_9218_:
{
uint32_t v___x_9220_; uint32_t v___x_9221_;
v___x_9220_ = 257;
v___x_9221_ = lean_uint32_lor(v___x_9220_, v___y_9219_);
v___y_9213_ = v___x_9221_;
goto v___jp_9212_;
}
}
}

LEAN_EXPORT uint32_t orb_proxy_sse_scan_step(uint8_t v_lineKind_9284_, uint8_t v_hasDoneToken_9285_, uint8_t v_inThinkTag_9286_, uint8_t v_nextStartsThink_9287_, uint8_t v_nextEndsThink_9288_, uint8_t v_hasNonEmptyContent_9289_){
_start:
{
uint32_t v___y_9291_; uint32_t v___y_9292_; uint8_t v___x_9296_; uint32_t v___y_9298_; uint8_t v___x_9306_; uint32_t v___y_9308_;
v___x_9296_ = 1;
v___x_9306_ = lean_uint8_dec_eq(v_inThinkTag_9286_, v___x_9296_);
if (v___x_9306_ == 0)
{
uint32_t v___x_9320_;
v___x_9320_ = 0;
v___y_9308_ = v___x_9320_;
goto v___jp_9307_;
}
else
{
uint32_t v___x_9321_;
v___x_9321_ = 512;
v___y_9308_ = v___x_9321_;
goto v___jp_9307_;
}
v___jp_9290_:
{
uint32_t v___x_9293_; uint32_t v___x_9294_; uint32_t v___x_9295_;
v___x_9293_ = 2;
v___x_9294_ = lean_uint32_lor(v___x_9293_, v___y_9292_);
v___x_9295_ = lean_uint32_lor(v___x_9294_, v___y_9291_);
return v___x_9295_;
}
v___jp_9297_:
{
uint8_t v___x_9299_;
v___x_9299_ = lean_uint8_dec_eq(v_hasNonEmptyContent_9289_, v___x_9296_);
if (v___x_9299_ == 0)
{
uint32_t v___x_9300_;
v___x_9300_ = 0;
v___y_9291_ = v___y_9298_;
v___y_9292_ = v___x_9300_;
goto v___jp_9290_;
}
else
{
uint32_t v___x_9301_;
v___x_9301_ = 256;
v___y_9291_ = v___y_9298_;
v___y_9292_ = v___x_9301_;
goto v___jp_9290_;
}
}
v___jp_9302_:
{
uint32_t v___x_9303_;
v___x_9303_ = 0;
v___y_9298_ = v___x_9303_;
goto v___jp_9297_;
}
v___jp_9304_:
{
uint32_t v___x_9305_;
v___x_9305_ = 512;
v___y_9298_ = v___x_9305_;
goto v___jp_9297_;
}
v___jp_9307_:
{
uint8_t v___x_9309_; uint8_t v___x_9310_;
v___x_9309_ = 0;
v___x_9310_ = lean_uint8_dec_eq(v_lineKind_9284_, v___x_9309_);
if (v___x_9310_ == 0)
{
uint8_t v___x_9311_; uint8_t v___x_9312_;
v___x_9311_ = 2;
v___x_9312_ = lean_uint8_dec_eq(v_lineKind_9284_, v___x_9311_);
if (v___x_9312_ == 0)
{
uint32_t v___x_9313_; uint32_t v___x_9314_;
v___x_9313_ = 1;
v___x_9314_ = lean_uint32_lor(v___x_9313_, v___y_9308_);
return v___x_9314_;
}
else
{
uint8_t v___x_9315_;
v___x_9315_ = lean_uint8_dec_eq(v_hasDoneToken_9285_, v___x_9296_);
if (v___x_9315_ == 0)
{
uint8_t v___x_9316_;
v___x_9316_ = lean_uint8_dec_eq(v_nextEndsThink_9288_, v___x_9296_);
if (v___x_9316_ == 0)
{
uint8_t v___x_9317_;
v___x_9317_ = lean_uint8_dec_eq(v_nextStartsThink_9287_, v___x_9296_);
if (v___x_9317_ == 0)
{
if (v___x_9306_ == 0)
{
goto v___jp_9302_;
}
else
{
goto v___jp_9304_;
}
}
else
{
goto v___jp_9304_;
}
}
else
{
goto v___jp_9302_;
}
}
else
{
uint32_t v___x_9318_; uint32_t v___x_9319_;
v___x_9318_ = 3;
v___x_9319_ = lean_uint32_lor(v___x_9318_, v___y_9308_);
return v___x_9319_;
}
}
}
else
{
return v___y_9308_;
}
}
}
}

LEAN_EXPORT uint64_t orb_stream_repetition_step(uint8_t v_cancelledOrExpired_9336_, uint8_t v_collisionDetected_9337_, uint32_t v_startPos_9338_, uint32_t v_prevEnd_9339_, uint32_t v_candidateLen_9340_, uint32_t v_prevCount_9341_, uint32_t v_requiredRepeats_9342_, uint64_t v_comparisons_9343_, uint64_t v_comparisonBudget_9344_){
_start:
{
uint32_t v___y_9346_; uint32_t v___y_9347_; uint32_t v___y_9348_; uint32_t v___y_9356_; uint32_t v___y_9357_; uint8_t v___x_9367_; uint8_t v___x_9368_;
v___x_9367_ = 1;
v___x_9368_ = lean_uint8_dec_eq(v_cancelledOrExpired_9336_, v___x_9367_);
if (v___x_9368_ == 0)
{
uint8_t v___x_9369_;
v___x_9369_ = lean_uint8_dec_eq(v_collisionDetected_9337_, v___x_9367_);
if (v___x_9369_ == 0)
{
uint8_t v___x_9370_;
v___x_9370_ = lean_uint64_dec_lt(v_comparisonBudget_9344_, v_comparisons_9343_);
if (v___x_9370_ == 0)
{
uint32_t v___x_9371_; uint8_t v___x_9372_;
v___x_9371_ = 0;
v___x_9372_ = lean_uint32_dec_eq(v_candidateLen_9340_, v___x_9371_);
if (v___x_9372_ == 0)
{
uint32_t v___x_9373_; uint8_t v___x_9374_;
v___x_9373_ = 2;
v___x_9374_ = lean_uint32_dec_lt(v_requiredRepeats_9342_, v___x_9373_);
if (v___x_9374_ == 0)
{
uint8_t v___x_9375_;
v___x_9375_ = lean_uint32_dec_lt(v_startPos_9338_, v_prevEnd_9339_);
if (v___x_9375_ == 0)
{
uint64_t v___x_9376_; uint64_t v___x_9377_; uint64_t v___x_9378_; uint64_t v___x_9379_; uint8_t v_contiguous_9380_; uint32_t v___y_9382_;
v___x_9376_ = lean_uint32_to_uint64(v_startPos_9338_);
v___x_9377_ = lean_uint32_to_uint64(v_prevEnd_9339_);
v___x_9378_ = lean_uint32_to_uint64(v_candidateLen_9340_);
v___x_9379_ = lean_uint64_add(v___x_9377_, v___x_9378_);
v_contiguous_9380_ = lean_uint64_dec_le(v___x_9376_, v___x_9379_);
if (v_contiguous_9380_ == 0)
{
uint32_t v___x_9384_;
v___x_9384_ = 1;
v___y_9382_ = v___x_9384_;
goto v___jp_9381_;
}
else
{
uint32_t v___x_9385_; uint8_t v___x_9386_;
v___x_9385_ = 4294967295;
v___x_9386_ = lean_uint32_dec_lt(v_prevCount_9341_, v___x_9385_);
if (v___x_9386_ == 0)
{
v___y_9382_ = v___x_9385_;
goto v___jp_9381_;
}
else
{
uint32_t v___x_9387_; uint32_t v___x_9388_;
v___x_9387_ = 1;
v___x_9388_ = lean_uint32_add(v_prevCount_9341_, v___x_9387_);
v___y_9382_ = v___x_9388_;
goto v___jp_9381_;
}
}
v___jp_9381_:
{
if (v_contiguous_9380_ == 0)
{
uint32_t v___x_9383_;
v___x_9383_ = 512;
v___y_9356_ = v___y_9382_;
v___y_9357_ = v___x_9383_;
goto v___jp_9355_;
}
else
{
v___y_9356_ = v___y_9382_;
v___y_9357_ = v___x_9371_;
goto v___jp_9355_;
}
}
}
else
{
uint64_t v___x_9389_; uint64_t v___x_9390_; uint64_t v___x_9391_;
v___x_9389_ = lean_uint32_to_uint64(v_prevCount_9341_);
v___x_9390_ = 32ULL;
v___x_9391_ = lean_uint64_shift_left(v___x_9389_, v___x_9390_);
return v___x_9391_;
}
}
else
{
goto v___jp_9361_;
}
}
else
{
goto v___jp_9361_;
}
}
else
{
goto v___jp_9361_;
}
}
else
{
goto v___jp_9361_;
}
}
else
{
goto v___jp_9361_;
}
v___jp_9345_:
{
uint32_t v_lo32_9349_; uint64_t v___x_9350_; uint64_t v___x_9351_; uint64_t v___x_9352_; uint64_t v___x_9353_; uint64_t v___x_9354_;
v_lo32_9349_ = lean_uint32_lor(v___y_9348_, v___y_9346_);
v___x_9350_ = lean_uint32_to_uint64(v_lo32_9349_);
v___x_9351_ = lean_uint32_to_uint64(v___y_9347_);
v___x_9352_ = 32ULL;
v___x_9353_ = lean_uint64_shift_left(v___x_9351_, v___x_9352_);
v___x_9354_ = lean_uint64_lor(v___x_9350_, v___x_9353_);
return v___x_9354_;
}
v___jp_9355_:
{
uint8_t v_hit_9358_;
v_hit_9358_ = lean_uint32_dec_le(v_requiredRepeats_9342_, v___y_9356_);
if (v_hit_9358_ == 0)
{
uint32_t v___x_9359_;
v___x_9359_ = 1;
v___y_9346_ = v___y_9357_;
v___y_9347_ = v___y_9356_;
v___y_9348_ = v___x_9359_;
goto v___jp_9345_;
}
else
{
uint32_t v___x_9360_;
v___x_9360_ = 259;
v___y_9346_ = v___y_9357_;
v___y_9347_ = v___y_9356_;
v___y_9348_ = v___x_9360_;
goto v___jp_9345_;
}
}
v___jp_9361_:
{
uint64_t v___x_9362_; uint64_t v___x_9363_; uint64_t v___x_9364_; uint64_t v___x_9365_; uint64_t v___x_9366_;
v___x_9362_ = 2ULL;
v___x_9363_ = lean_uint32_to_uint64(v_prevCount_9341_);
v___x_9364_ = 32ULL;
v___x_9365_ = lean_uint64_shift_left(v___x_9363_, v___x_9364_);
v___x_9366_ = lean_uint64_lor(v___x_9362_, v___x_9365_);
return v___x_9366_;
}
}
}

LEAN_EXPORT uint64_t orb_http_rate_limit_classify_step(uint32_t v_httpStatus_9412_, uint8_t v_hasQuotaBodyHint_9413_, uint8_t v_hasAuthFailureHint_9414_, uint64_t v_retryAfterSecs_9415_, uint64_t v_maxCooldownSecs_9416_){
_start:
{
uint32_t v___y_9418_; uint32_t v___y_9419_; uint32_t v___y_9420_; uint32_t v___y_9430_; uint32_t v___y_9431_; uint32_t v___y_9434_; uint32_t v___y_9435_; uint32_t v___y_9436_; uint32_t v___y_9444_; uint32_t v___y_9445_; uint64_t v___y_9446_; uint32_t v___y_9452_; uint64_t v___y_9453_; uint32_t v___y_9454_; uint64_t v___y_9455_; uint32_t v___y_9458_; uint64_t v___y_9459_; uint64_t v___y_9460_; uint32_t v___y_9461_; uint64_t v___y_9462_; uint32_t v___y_9465_; uint64_t v___y_9466_; uint32_t v___y_9467_; uint64_t v___y_9468_; uint32_t v___y_9474_; uint32_t v___x_9497_; uint8_t v___x_9498_;
v___x_9497_ = 429;
v___x_9498_ = lean_uint32_dec_eq(v_httpStatus_9412_, v___x_9497_);
if (v___x_9498_ == 0)
{
uint32_t v___x_9499_; uint8_t v___x_9500_;
v___x_9499_ = 402;
v___x_9500_ = lean_uint32_dec_eq(v_httpStatus_9412_, v___x_9499_);
if (v___x_9500_ == 0)
{
uint32_t v___x_9501_; uint8_t v___x_9502_;
v___x_9501_ = 401;
v___x_9502_ = lean_uint32_dec_eq(v_httpStatus_9412_, v___x_9501_);
if (v___x_9502_ == 0)
{
uint32_t v___x_9503_; uint8_t v___x_9504_;
v___x_9503_ = 403;
v___x_9504_ = lean_uint32_dec_eq(v_httpStatus_9412_, v___x_9503_);
if (v___x_9504_ == 0)
{
goto v___jp_9487_;
}
else
{
uint8_t v___x_9505_; uint8_t v___x_9506_;
v___x_9505_ = 1;
v___x_9506_ = lean_uint8_dec_eq(v_hasAuthFailureHint_9414_, v___x_9505_);
if (v___x_9506_ == 0)
{
goto v___jp_9487_;
}
else
{
goto v___jp_9481_;
}
}
}
else
{
goto v___jp_9481_;
}
}
else
{
uint32_t v___x_9507_;
v___x_9507_ = 2;
v___y_9474_ = v___x_9507_;
goto v___jp_9473_;
}
}
else
{
uint8_t v___x_9508_; uint8_t v___x_9509_;
v___x_9508_ = 1;
v___x_9509_ = lean_uint8_dec_eq(v_hasQuotaBodyHint_9413_, v___x_9508_);
if (v___x_9509_ == 0)
{
uint32_t v___x_9510_;
v___x_9510_ = 1;
v___y_9474_ = v___x_9510_;
goto v___jp_9473_;
}
else
{
uint32_t v___x_9511_;
v___x_9511_ = 2;
v___y_9474_ = v___x_9511_;
goto v___jp_9473_;
}
}
v___jp_9417_:
{
uint32_t v___x_9421_; uint32_t v___x_9422_; uint32_t v_lo32_9423_; uint64_t v___x_9424_; uint64_t v___x_9425_; uint64_t v___x_9426_; uint64_t v___x_9427_; uint64_t v___x_9428_;
v___x_9421_ = 256;
v___x_9422_ = lean_uint32_lor(v___y_9418_, v___x_9421_);
v_lo32_9423_ = lean_uint32_lor(v___x_9422_, v___y_9420_);
v___x_9424_ = lean_uint32_to_uint64(v_lo32_9423_);
v___x_9425_ = lean_uint32_to_uint64(v___y_9419_);
v___x_9426_ = 32ULL;
v___x_9427_ = lean_uint64_shift_left(v___x_9425_, v___x_9426_);
v___x_9428_ = lean_uint64_lor(v___x_9424_, v___x_9427_);
return v___x_9428_;
}
v___jp_9429_:
{
uint32_t v___x_9432_;
v___x_9432_ = 512;
v___y_9418_ = v___y_9430_;
v___y_9419_ = v___y_9431_;
v___y_9420_ = v___x_9432_;
goto v___jp_9417_;
}
v___jp_9433_:
{
uint32_t v___x_9437_; uint8_t v___x_9438_;
v___x_9437_ = 1;
v___x_9438_ = lean_uint32_dec_eq(v___y_9434_, v___x_9437_);
if (v___x_9438_ == 0)
{
uint32_t v___x_9439_; uint8_t v___x_9440_;
v___x_9439_ = 4;
v___x_9440_ = lean_uint32_dec_eq(v___y_9434_, v___x_9439_);
if (v___x_9440_ == 0)
{
uint32_t v___x_9441_; uint8_t v___x_9442_;
v___x_9441_ = 5;
v___x_9442_ = lean_uint32_dec_eq(v___y_9434_, v___x_9441_);
if (v___x_9442_ == 0)
{
v___y_9418_ = v___y_9434_;
v___y_9419_ = v___y_9436_;
v___y_9420_ = v___y_9435_;
goto v___jp_9417_;
}
else
{
v___y_9430_ = v___y_9434_;
v___y_9431_ = v___y_9436_;
goto v___jp_9429_;
}
}
else
{
v___y_9430_ = v___y_9434_;
v___y_9431_ = v___y_9436_;
goto v___jp_9429_;
}
}
else
{
v___y_9430_ = v___y_9434_;
v___y_9431_ = v___y_9436_;
goto v___jp_9429_;
}
}
v___jp_9443_:
{
uint64_t v___x_9447_; uint8_t v___x_9448_;
v___x_9447_ = 4294967295ULL;
v___x_9448_ = lean_uint64_dec_le(v___y_9446_, v___x_9447_);
if (v___x_9448_ == 0)
{
uint32_t v___x_9449_;
v___x_9449_ = 4294967295;
v___y_9434_ = v___y_9444_;
v___y_9435_ = v___y_9445_;
v___y_9436_ = v___x_9449_;
goto v___jp_9433_;
}
else
{
uint32_t v___x_9450_;
v___x_9450_ = lean_uint64_to_uint32(v___y_9446_);
v___y_9434_ = v___y_9444_;
v___y_9435_ = v___y_9445_;
v___y_9436_ = v___x_9450_;
goto v___jp_9433_;
}
}
v___jp_9451_:
{
uint8_t v___x_9456_;
v___x_9456_ = lean_uint64_dec_le(v___y_9455_, v___y_9453_);
if (v___x_9456_ == 0)
{
v___y_9444_ = v___y_9452_;
v___y_9445_ = v___y_9454_;
v___y_9446_ = v___y_9453_;
goto v___jp_9443_;
}
else
{
v___y_9444_ = v___y_9452_;
v___y_9445_ = v___y_9454_;
v___y_9446_ = v___y_9455_;
goto v___jp_9443_;
}
}
v___jp_9457_:
{
uint8_t v___x_9463_;
v___x_9463_ = lean_uint64_dec_eq(v_retryAfterSecs_9415_, v___y_9460_);
if (v___x_9463_ == 0)
{
v___y_9452_ = v___y_9458_;
v___y_9453_ = v___y_9459_;
v___y_9454_ = v___y_9461_;
v___y_9455_ = v_retryAfterSecs_9415_;
goto v___jp_9451_;
}
else
{
v___y_9452_ = v___y_9458_;
v___y_9453_ = v___y_9459_;
v___y_9454_ = v___y_9461_;
v___y_9455_ = v___y_9462_;
goto v___jp_9451_;
}
}
v___jp_9464_:
{
uint32_t v___x_9469_; uint8_t v___x_9470_;
v___x_9469_ = 2;
v___x_9470_ = lean_uint32_dec_eq(v___y_9465_, v___x_9469_);
if (v___x_9470_ == 0)
{
uint64_t v___x_9471_;
v___x_9471_ = 15ULL;
v___y_9458_ = v___y_9465_;
v___y_9459_ = v___y_9468_;
v___y_9460_ = v___y_9466_;
v___y_9461_ = v___y_9467_;
v___y_9462_ = v___x_9471_;
goto v___jp_9457_;
}
else
{
uint64_t v___x_9472_;
v___x_9472_ = 300ULL;
v___y_9458_ = v___y_9465_;
v___y_9459_ = v___y_9468_;
v___y_9460_ = v___y_9466_;
v___y_9461_ = v___y_9467_;
v___y_9462_ = v___x_9472_;
goto v___jp_9457_;
}
}
v___jp_9473_:
{
uint32_t v___x_9475_; uint8_t v___x_9476_;
v___x_9475_ = 0;
v___x_9476_ = lean_uint32_dec_eq(v___y_9474_, v___x_9475_);
if (v___x_9476_ == 0)
{
uint64_t v___x_9477_; uint8_t v___x_9478_;
v___x_9477_ = 0ULL;
v___x_9478_ = lean_uint64_dec_eq(v_maxCooldownSecs_9416_, v___x_9477_);
if (v___x_9478_ == 0)
{
v___y_9465_ = v___y_9474_;
v___y_9466_ = v___x_9477_;
v___y_9467_ = v___x_9475_;
v___y_9468_ = v_maxCooldownSecs_9416_;
goto v___jp_9464_;
}
else
{
uint64_t v___x_9479_;
v___x_9479_ = 3600ULL;
v___y_9465_ = v___y_9474_;
v___y_9466_ = v___x_9477_;
v___y_9467_ = v___x_9475_;
v___y_9468_ = v___x_9479_;
goto v___jp_9464_;
}
}
else
{
uint64_t v___x_9480_;
v___x_9480_ = 0ULL;
return v___x_9480_;
}
}
v___jp_9481_:
{
uint32_t v___x_9482_;
v___x_9482_ = 3;
v___y_9474_ = v___x_9482_;
goto v___jp_9473_;
}
v___jp_9483_:
{
uint32_t v___x_9484_;
v___x_9484_ = 4;
v___y_9474_ = v___x_9484_;
goto v___jp_9473_;
}
v___jp_9485_:
{
uint32_t v___x_9486_;
v___x_9486_ = 0;
v___y_9474_ = v___x_9486_;
goto v___jp_9473_;
}
v___jp_9487_:
{
uint32_t v___x_9488_; uint8_t v___x_9489_;
v___x_9488_ = 529;
v___x_9489_ = lean_uint32_dec_eq(v_httpStatus_9412_, v___x_9488_);
if (v___x_9489_ == 0)
{
uint32_t v___x_9490_; uint8_t v___x_9491_;
v___x_9490_ = 503;
v___x_9491_ = lean_uint32_dec_eq(v_httpStatus_9412_, v___x_9490_);
if (v___x_9491_ == 0)
{
uint32_t v___x_9492_; uint8_t v___x_9493_;
v___x_9492_ = 500;
v___x_9493_ = lean_uint32_dec_le(v___x_9492_, v_httpStatus_9412_);
if (v___x_9493_ == 0)
{
goto v___jp_9485_;
}
else
{
uint32_t v___x_9494_; uint8_t v___x_9495_;
v___x_9494_ = 600;
v___x_9495_ = lean_uint32_dec_lt(v_httpStatus_9412_, v___x_9494_);
if (v___x_9495_ == 0)
{
goto v___jp_9485_;
}
else
{
uint32_t v___x_9496_;
v___x_9496_ = 5;
v___y_9474_ = v___x_9496_;
goto v___jp_9473_;
}
}
}
else
{
goto v___jp_9483_;
}
}
else
{
goto v___jp_9483_;
}
}
}
}

LEAN_EXPORT uint8_t orb_fleet_place_argmin_step(uint8_t v_aQueued_9524_, uint8_t v_aSpec_9525_, uint8_t v_aSoftDisk_9526_, uint8_t v_bQueued_9527_, uint8_t v_bSpec_9528_, uint8_t v_bSoftDisk_9529_, uint8_t v_idLexLt_9530_, uint32_t v_aLoad_9531_, uint32_t v_aCap_9532_, uint32_t v_aDiskGib_9533_, uint32_t v_bLoad_9534_, uint32_t v_bCap_9535_, uint32_t v_bDiskGib_9536_, uint64_t v_aMemAvail_9537_, uint64_t v_bMemAvail_9538_){
_start:
{
uint8_t v___x_9539_; uint8_t v___y_9541_; uint8_t v___y_9542_; uint8_t v___y_9555_; uint64_t v___y_9559_; uint64_t v___y_9560_; uint32_t v___y_9571_; uint64_t v___y_9572_; uint8_t v___y_9577_; uint8_t v___y_9578_; uint8_t v___y_9587_; uint8_t v___y_9591_; uint8_t v___y_9592_; uint8_t v___y_9599_; uint8_t v___x_9602_;
v___x_9539_ = 0;
v___x_9602_ = lean_uint8_dec_eq(v_aQueued_9524_, v___x_9539_);
if (v___x_9602_ == 0)
{
uint8_t v___x_9603_;
v___x_9603_ = 1;
v___y_9599_ = v___x_9603_;
goto v___jp_9598_;
}
else
{
v___y_9599_ = v___x_9539_;
goto v___jp_9598_;
}
v___jp_9540_:
{
uint8_t v___x_9543_;
v___x_9543_ = lean_uint8_dec_lt(v___y_9541_, v___y_9542_);
if (v___x_9543_ == 0)
{
uint8_t v___x_9544_;
v___x_9544_ = lean_uint8_dec_lt(v___y_9542_, v___y_9541_);
if (v___x_9544_ == 0)
{
uint8_t v___x_9545_;
v___x_9545_ = lean_uint64_dec_lt(v_bMemAvail_9538_, v_aMemAvail_9537_);
if (v___x_9545_ == 0)
{
uint8_t v___x_9546_;
v___x_9546_ = lean_uint64_dec_lt(v_aMemAvail_9537_, v_bMemAvail_9538_);
if (v___x_9546_ == 0)
{
uint8_t v___x_9547_;
v___x_9547_ = lean_uint32_dec_lt(v_bDiskGib_9536_, v_aDiskGib_9533_);
if (v___x_9547_ == 0)
{
uint8_t v___x_9548_;
v___x_9548_ = lean_uint32_dec_lt(v_aDiskGib_9533_, v_bDiskGib_9536_);
if (v___x_9548_ == 0)
{
uint8_t v___x_9549_; uint8_t v___x_9550_;
v___x_9549_ = 1;
v___x_9550_ = lean_uint8_dec_eq(v_idLexLt_9530_, v___x_9549_);
if (v___x_9550_ == 0)
{
return v___x_9539_;
}
else
{
return v___x_9549_;
}
}
else
{
return v___x_9539_;
}
}
else
{
uint8_t v___x_9551_;
v___x_9551_ = 1;
return v___x_9551_;
}
}
else
{
return v___x_9539_;
}
}
else
{
uint8_t v___x_9552_;
v___x_9552_ = 1;
return v___x_9552_;
}
}
else
{
return v___x_9539_;
}
}
else
{
uint8_t v___x_9553_;
v___x_9553_ = 1;
return v___x_9553_;
}
}
v___jp_9554_:
{
uint8_t v___x_9556_;
v___x_9556_ = lean_uint8_dec_eq(v_bSoftDisk_9529_, v___x_9539_);
if (v___x_9556_ == 0)
{
uint8_t v___x_9557_;
v___x_9557_ = 1;
v___y_9541_ = v___y_9555_;
v___y_9542_ = v___x_9557_;
goto v___jp_9540_;
}
else
{
v___y_9541_ = v___y_9555_;
v___y_9542_ = v___x_9539_;
goto v___jp_9540_;
}
}
v___jp_9558_:
{
uint64_t v___x_9561_; uint64_t v_lhs_9562_; uint64_t v___x_9563_; uint64_t v_rhs_9564_; uint8_t v___x_9565_;
v___x_9561_ = lean_uint32_to_uint64(v_aLoad_9531_);
v_lhs_9562_ = lean_uint64_mul(v___x_9561_, v___y_9560_);
v___x_9563_ = lean_uint32_to_uint64(v_bLoad_9534_);
v_rhs_9564_ = lean_uint64_mul(v___x_9563_, v___y_9559_);
v___x_9565_ = lean_uint64_dec_lt(v_lhs_9562_, v_rhs_9564_);
if (v___x_9565_ == 0)
{
uint8_t v___x_9566_;
v___x_9566_ = lean_uint64_dec_lt(v_rhs_9564_, v_lhs_9562_);
if (v___x_9566_ == 0)
{
uint8_t v___x_9567_;
v___x_9567_ = lean_uint8_dec_eq(v_aSoftDisk_9526_, v___x_9539_);
if (v___x_9567_ == 0)
{
uint8_t v___x_9568_;
v___x_9568_ = 1;
v___y_9555_ = v___x_9568_;
goto v___jp_9554_;
}
else
{
v___y_9555_ = v___x_9539_;
goto v___jp_9554_;
}
}
else
{
return v___x_9539_;
}
}
else
{
uint8_t v___x_9569_;
v___x_9569_ = 1;
return v___x_9569_;
}
}
v___jp_9570_:
{
uint8_t v___x_9573_;
v___x_9573_ = lean_uint32_dec_eq(v_bCap_9535_, v___y_9571_);
if (v___x_9573_ == 0)
{
uint64_t v___x_9574_;
v___x_9574_ = lean_uint32_to_uint64(v_bCap_9535_);
v___y_9559_ = v___y_9572_;
v___y_9560_ = v___x_9574_;
goto v___jp_9558_;
}
else
{
uint64_t v___x_9575_;
v___x_9575_ = 1ULL;
v___y_9559_ = v___y_9572_;
v___y_9560_ = v___x_9575_;
goto v___jp_9558_;
}
}
v___jp_9576_:
{
uint8_t v___x_9579_;
v___x_9579_ = lean_uint8_dec_lt(v___y_9577_, v___y_9578_);
if (v___x_9579_ == 0)
{
uint8_t v___x_9580_;
v___x_9580_ = lean_uint8_dec_lt(v___y_9578_, v___y_9577_);
if (v___x_9580_ == 0)
{
uint32_t v___x_9581_; uint8_t v___x_9582_;
v___x_9581_ = 0;
v___x_9582_ = lean_uint32_dec_eq(v_aCap_9532_, v___x_9581_);
if (v___x_9582_ == 0)
{
uint64_t v___x_9583_;
v___x_9583_ = lean_uint32_to_uint64(v_aCap_9532_);
v___y_9571_ = v___x_9581_;
v___y_9572_ = v___x_9583_;
goto v___jp_9570_;
}
else
{
uint64_t v___x_9584_;
v___x_9584_ = 1ULL;
v___y_9571_ = v___x_9581_;
v___y_9572_ = v___x_9584_;
goto v___jp_9570_;
}
}
else
{
return v___x_9539_;
}
}
else
{
uint8_t v___x_9585_;
v___x_9585_ = 1;
return v___x_9585_;
}
}
v___jp_9586_:
{
uint8_t v___x_9588_;
v___x_9588_ = lean_uint8_dec_eq(v_bSpec_9528_, v___x_9539_);
if (v___x_9588_ == 0)
{
uint8_t v___x_9589_;
v___x_9589_ = 1;
v___y_9577_ = v___y_9587_;
v___y_9578_ = v___x_9589_;
goto v___jp_9576_;
}
else
{
v___y_9577_ = v___y_9587_;
v___y_9578_ = v___x_9539_;
goto v___jp_9576_;
}
}
v___jp_9590_:
{
uint8_t v___x_9593_;
v___x_9593_ = lean_uint8_dec_lt(v___y_9591_, v___y_9592_);
if (v___x_9593_ == 0)
{
uint8_t v___x_9594_;
v___x_9594_ = lean_uint8_dec_lt(v___y_9592_, v___y_9591_);
if (v___x_9594_ == 0)
{
uint8_t v___x_9595_;
v___x_9595_ = lean_uint8_dec_eq(v_aSpec_9525_, v___x_9539_);
if (v___x_9595_ == 0)
{
uint8_t v___x_9596_;
v___x_9596_ = 1;
v___y_9587_ = v___x_9596_;
goto v___jp_9586_;
}
else
{
v___y_9587_ = v___x_9539_;
goto v___jp_9586_;
}
}
else
{
return v___x_9539_;
}
}
else
{
uint8_t v___x_9597_;
v___x_9597_ = 1;
return v___x_9597_;
}
}
v___jp_9598_:
{
uint8_t v___x_9600_;
v___x_9600_ = lean_uint8_dec_eq(v_bQueued_9527_, v___x_9539_);
if (v___x_9600_ == 0)
{
uint8_t v___x_9601_;
v___x_9601_ = 1;
v___y_9591_ = v___y_9599_;
v___y_9592_ = v___x_9601_;
goto v___jp_9590_;
}
else
{
v___y_9591_ = v___y_9599_;
v___y_9592_ = v___x_9539_;
goto v___jp_9590_;
}
}
}
}

LEAN_EXPORT uint64_t orb_pool_pacer_step(uint8_t v_mode_9636_, uint64_t v_prevDebtTokenMs_9637_, uint64_t v_elapsedMs_9638_, uint64_t v_rateTokensPerMin_9639_, uint64_t v_addedTokens_9640_, uint64_t v_maxDelayMs_9641_){
_start:
{
uint64_t v___x_9642_; uint64_t v___y_9644_; uint64_t v___y_9645_; uint64_t v___y_9655_; uint64_t v___y_9656_; uint64_t v___y_9657_; uint64_t v___y_9658_; uint64_t v___y_9665_; uint64_t v___y_9666_; uint64_t v___y_9667_; uint64_t v___y_9671_; uint64_t v___y_9672_; uint64_t v___y_9673_; uint64_t v___y_9674_; uint64_t v___y_9679_; uint64_t v___y_9680_; uint64_t v___y_9681_; uint64_t v___y_9682_; uint64_t v___y_9685_; uint8_t v___x_9689_;
v___x_9642_ = 0ULL;
v___x_9689_ = lean_uint64_dec_eq(v_rateTokensPerMin_9639_, v___x_9642_);
if (v___x_9689_ == 0)
{
uint64_t v___x_9690_; uint8_t v___x_9691_;
v___x_9690_ = 100000000000ULL;
v___x_9691_ = lean_uint64_dec_le(v_rateTokensPerMin_9639_, v___x_9690_);
if (v___x_9691_ == 0)
{
v___y_9685_ = v___x_9690_;
goto v___jp_9684_;
}
else
{
v___y_9685_ = v_rateTokensPerMin_9639_;
goto v___jp_9684_;
}
}
else
{
return v___x_9642_;
}
v___jp_9643_:
{
uint8_t v___x_9646_; uint8_t v___x_9647_;
v___x_9646_ = 0;
v___x_9647_ = lean_uint8_dec_eq(v_mode_9636_, v___x_9646_);
if (v___x_9647_ == 0)
{
uint8_t v___x_9648_;
v___x_9648_ = lean_uint64_dec_eq(v___y_9645_, v___x_9642_);
if (v___x_9648_ == 0)
{
uint64_t v___x_9649_; uint64_t v___x_9650_; uint64_t v___x_9651_; uint64_t v_rawDelayMs_9652_; uint8_t v___x_9653_;
v___x_9649_ = 1ULL;
v___x_9650_ = lean_uint64_sub(v___y_9644_, v___x_9649_);
v___x_9651_ = lean_uint64_add(v___y_9645_, v___x_9650_);
v_rawDelayMs_9652_ = lean_uint64_div(v___x_9651_, v___y_9644_);
v___x_9653_ = lean_uint64_dec_le(v_rawDelayMs_9652_, v_maxDelayMs_9641_);
if (v___x_9653_ == 0)
{
return v_maxDelayMs_9641_;
}
else
{
return v_rawDelayMs_9652_;
}
}
else
{
return v___x_9642_;
}
}
else
{
return v___y_9645_;
}
}
v___jp_9654_:
{
uint64_t v___x_9659_; uint64_t v_addUnits_9660_; uint64_t v_room_9661_; uint8_t v___x_9662_;
v___x_9659_ = 60000ULL;
v_addUnits_9660_ = lean_uint64_mul(v___y_9658_, v___x_9659_);
v_room_9661_ = lean_uint64_sub(v___y_9657_, v___y_9655_);
v___x_9662_ = lean_uint64_dec_le(v_addUnits_9660_, v_room_9661_);
if (v___x_9662_ == 0)
{
v___y_9644_ = v___y_9656_;
v___y_9645_ = v___y_9657_;
goto v___jp_9643_;
}
else
{
uint64_t v___x_9663_;
v___x_9663_ = lean_uint64_add(v___y_9655_, v_addUnits_9660_);
v___y_9644_ = v___y_9656_;
v___y_9645_ = v___x_9663_;
goto v___jp_9643_;
}
}
v___jp_9664_:
{
uint64_t v___x_9668_; uint8_t v___x_9669_;
v___x_9668_ = 200000000000ULL;
v___x_9669_ = lean_uint64_dec_le(v_addedTokens_9640_, v___x_9668_);
if (v___x_9669_ == 0)
{
v___y_9655_ = v___y_9667_;
v___y_9656_ = v___y_9665_;
v___y_9657_ = v___y_9666_;
v___y_9658_ = v___x_9668_;
goto v___jp_9654_;
}
else
{
v___y_9655_ = v___y_9667_;
v___y_9656_ = v___y_9665_;
v___y_9657_ = v___y_9666_;
v___y_9658_ = v_addedTokens_9640_;
goto v___jp_9654_;
}
}
v___jp_9670_:
{
uint64_t v_drained_9675_; uint8_t v___x_9676_;
v_drained_9675_ = lean_uint64_mul(v___y_9674_, v___y_9672_);
v___x_9676_ = lean_uint64_dec_le(v_drained_9675_, v___y_9671_);
if (v___x_9676_ == 0)
{
v___y_9665_ = v___y_9672_;
v___y_9666_ = v___y_9673_;
v___y_9667_ = v___x_9642_;
goto v___jp_9664_;
}
else
{
uint64_t v___x_9677_;
v___x_9677_ = lean_uint64_sub(v___y_9671_, v_drained_9675_);
v___y_9665_ = v___y_9672_;
v___y_9666_ = v___y_9673_;
v___y_9667_ = v___x_9677_;
goto v___jp_9664_;
}
}
v___jp_9678_:
{
uint8_t v___x_9683_;
v___x_9683_ = lean_uint64_dec_le(v_elapsedMs_9638_, v___y_9679_);
if (v___x_9683_ == 0)
{
v___y_9671_ = v___y_9682_;
v___y_9672_ = v___y_9680_;
v___y_9673_ = v___y_9681_;
v___y_9674_ = v___y_9679_;
goto v___jp_9670_;
}
else
{
v___y_9671_ = v___y_9682_;
v___y_9672_ = v___y_9680_;
v___y_9673_ = v___y_9681_;
v___y_9674_ = v_elapsedMs_9638_;
goto v___jp_9670_;
}
}
v___jp_9684_:
{
uint64_t v___x_9686_; uint64_t v_maxDebt_9687_; uint8_t v___x_9688_;
v___x_9686_ = 120000ULL;
v_maxDebt_9687_ = lean_uint64_mul(v___y_9685_, v___x_9686_);
v___x_9688_ = lean_uint64_dec_le(v_prevDebtTokenMs_9637_, v_maxDebt_9687_);
if (v___x_9688_ == 0)
{
v___y_9679_ = v___x_9686_;
v___y_9680_ = v___y_9685_;
v___y_9681_ = v_maxDebt_9687_;
v___y_9682_ = v_maxDebt_9687_;
goto v___jp_9678_;
}
else
{
v___y_9679_ = v___x_9686_;
v___y_9680_ = v___y_9685_;
v___y_9681_ = v_maxDebt_9687_;
v___y_9682_ = v_prevDebtTokenMs_9637_;
goto v___jp_9678_;
}
}
}
}

LEAN_EXPORT uint32_t orb_confinement_scan_step(uint8_t v_hasNullByte_9706_, uint8_t v_hasDotDotSegment_9707_, uint8_t v_escapesRoot_9708_, uint8_t v_hasUnsafeEnvKey_9709_, uint8_t v_touchesSensitivePath_9710_, uint8_t v_isSymlinkEscape_9711_, uint32_t v_pathLen_9712_, uint32_t v_maxPathLen_9713_){
_start:
{
uint32_t v___x_9714_; uint8_t v___x_9715_;
v___x_9714_ = 0;
v___x_9715_ = lean_uint32_dec_eq(v_maxPathLen_9713_, v___x_9714_);
if (v___x_9715_ == 0)
{
uint8_t v___x_9716_;
v___x_9716_ = lean_uint32_dec_eq(v_pathLen_9712_, v___x_9714_);
if (v___x_9716_ == 0)
{
uint8_t v___x_9717_;
v___x_9717_ = lean_uint32_dec_lt(v_maxPathLen_9713_, v_pathLen_9712_);
if (v___x_9717_ == 0)
{
uint8_t v___x_9718_; uint8_t v___x_9719_;
v___x_9718_ = 0;
v___x_9719_ = lean_uint8_dec_eq(v_hasNullByte_9706_, v___x_9718_);
if (v___x_9719_ == 0)
{
uint32_t v___x_9720_;
v___x_9720_ = 2;
return v___x_9720_;
}
else
{
uint8_t v___x_9721_;
v___x_9721_ = lean_uint8_dec_eq(v_hasDotDotSegment_9707_, v___x_9718_);
if (v___x_9721_ == 0)
{
uint32_t v___x_9722_;
v___x_9722_ = 3;
return v___x_9722_;
}
else
{
uint8_t v___x_9723_;
v___x_9723_ = lean_uint8_dec_eq(v_escapesRoot_9708_, v___x_9718_);
if (v___x_9723_ == 0)
{
uint32_t v___x_9724_;
v___x_9724_ = 4;
return v___x_9724_;
}
else
{
uint8_t v___x_9725_;
v___x_9725_ = lean_uint8_dec_eq(v_isSymlinkEscape_9711_, v___x_9718_);
if (v___x_9725_ == 0)
{
uint32_t v___x_9726_;
v___x_9726_ = 5;
return v___x_9726_;
}
else
{
uint8_t v___x_9727_;
v___x_9727_ = lean_uint8_dec_eq(v_hasUnsafeEnvKey_9709_, v___x_9718_);
if (v___x_9727_ == 0)
{
uint32_t v___x_9728_;
v___x_9728_ = 6;
return v___x_9728_;
}
else
{
uint8_t v___x_9729_;
v___x_9729_ = lean_uint8_dec_eq(v_touchesSensitivePath_9710_, v___x_9718_);
if (v___x_9729_ == 0)
{
uint32_t v___x_9730_;
v___x_9730_ = 7;
return v___x_9730_;
}
else
{
uint32_t v___x_9731_;
v___x_9731_ = 256;
return v___x_9731_;
}
}
}
}
}
}
}
else
{
uint32_t v___x_9732_;
v___x_9732_ = 1;
return v___x_9732_;
}
}
else
{
uint32_t v___x_9733_;
v___x_9733_ = 1;
return v___x_9733_;
}
}
else
{
uint32_t v___x_9734_;
v___x_9734_ = 1;
return v___x_9734_;
}
}
}

LEAN_EXPORT uint32_t orb_job_identity_eq256_step(uint64_t v_a0_9753_, uint64_t v_a1_9754_, uint64_t v_a2_9755_, uint64_t v_a3_9756_, uint64_t v_b0_9757_, uint64_t v_b1_9758_, uint64_t v_b2_9759_, uint64_t v_b3_9760_, uint8_t v_hasActiveMatch_9761_, uint8_t v_hasTerminalReceipt_9762_){
_start:
{
uint64_t v___x_9763_; uint64_t v___x_9764_; uint64_t v___x_9765_; uint64_t v___x_9766_; uint8_t v___x_9767_;
v___x_9763_ = lean_uint64_lor(v_a0_9753_, v_a1_9754_);
v___x_9764_ = lean_uint64_lor(v___x_9763_, v_a2_9755_);
v___x_9765_ = lean_uint64_lor(v___x_9764_, v_a3_9756_);
v___x_9766_ = 0ULL;
v___x_9767_ = lean_uint64_dec_eq(v___x_9765_, v___x_9766_);
if (v___x_9767_ == 0)
{
uint64_t v___x_9768_; uint64_t v___x_9769_; uint64_t v___x_9770_; uint64_t v___x_9771_; uint64_t v___x_9772_; uint64_t v___x_9773_; uint64_t v_diff_9774_; uint8_t v___x_9775_;
v___x_9768_ = lean_uint64_xor(v_a0_9753_, v_b0_9757_);
v___x_9769_ = lean_uint64_xor(v_a1_9754_, v_b1_9758_);
v___x_9770_ = lean_uint64_lor(v___x_9768_, v___x_9769_);
v___x_9771_ = lean_uint64_xor(v_a2_9755_, v_b2_9759_);
v___x_9772_ = lean_uint64_lor(v___x_9770_, v___x_9771_);
v___x_9773_ = lean_uint64_xor(v_a3_9756_, v_b3_9760_);
v_diff_9774_ = lean_uint64_lor(v___x_9772_, v___x_9773_);
v___x_9775_ = lean_uint64_dec_eq(v_diff_9774_, v___x_9766_);
if (v___x_9775_ == 0)
{
goto v___jp_9776_;
}
else
{
uint8_t v___x_9782_; uint8_t v___x_9783_;
v___x_9782_ = 1;
v___x_9783_ = lean_uint8_dec_eq(v_hasTerminalReceipt_9762_, v___x_9782_);
if (v___x_9783_ == 0)
{
goto v___jp_9776_;
}
else
{
uint32_t v___x_9784_;
v___x_9784_ = 2;
return v___x_9784_;
}
}
v___jp_9776_:
{
if (v___x_9775_ == 0)
{
uint32_t v___x_9777_;
v___x_9777_ = 256;
return v___x_9777_;
}
else
{
uint8_t v___x_9778_; uint8_t v___x_9779_;
v___x_9778_ = 1;
v___x_9779_ = lean_uint8_dec_eq(v_hasActiveMatch_9761_, v___x_9778_);
if (v___x_9779_ == 0)
{
uint32_t v___x_9780_;
v___x_9780_ = 256;
return v___x_9780_;
}
else
{
uint32_t v___x_9781_;
v___x_9781_ = 1;
return v___x_9781_;
}
}
}
}
else
{
uint32_t v___x_9785_;
v___x_9785_ = 3;
return v___x_9785_;
}
}
}

LEAN_EXPORT uint32_t orb_validation_dag_step(uint32_t v_totalDeps_9808_, uint32_t v_passedDeps_9809_, uint32_t v_failedDeps_9810_, uint8_t v_alreadyClaimed_9811_, uint8_t v_alreadyPassed_9812_, uint8_t v_candidateExactMatch_9813_){
_start:
{
uint64_t v___x_9814_; uint64_t v___x_9815_; uint64_t v___x_9816_; uint64_t v___x_9817_; uint8_t v___x_9818_;
v___x_9814_ = lean_uint32_to_uint64(v_totalDeps_9808_);
v___x_9815_ = lean_uint32_to_uint64(v_passedDeps_9809_);
v___x_9816_ = lean_uint32_to_uint64(v_failedDeps_9810_);
v___x_9817_ = lean_uint64_add(v___x_9815_, v___x_9816_);
v___x_9818_ = lean_uint64_dec_lt(v___x_9814_, v___x_9817_);
if (v___x_9818_ == 0)
{
uint8_t v___x_9819_; uint8_t v___x_9820_;
v___x_9819_ = 1;
v___x_9820_ = lean_uint8_dec_eq(v_candidateExactMatch_9813_, v___x_9819_);
if (v___x_9820_ == 0)
{
uint32_t v___x_9821_;
v___x_9821_ = 4;
return v___x_9821_;
}
else
{
uint8_t v___x_9822_; uint8_t v___x_9823_;
v___x_9822_ = 0;
v___x_9823_ = lean_uint8_dec_eq(v_alreadyPassed_9812_, v___x_9822_);
if (v___x_9823_ == 0)
{
uint32_t v___x_9824_;
v___x_9824_ = 3;
return v___x_9824_;
}
else
{
uint32_t v___x_9825_; uint8_t v___x_9826_;
v___x_9825_ = 0;
v___x_9826_ = lean_uint32_dec_lt(v___x_9825_, v_failedDeps_9810_);
if (v___x_9826_ == 0)
{
uint8_t v___x_9827_;
v___x_9827_ = lean_uint8_dec_eq(v_alreadyClaimed_9811_, v___x_9822_);
if (v___x_9827_ == 0)
{
uint32_t v___x_9828_;
v___x_9828_ = 1;
return v___x_9828_;
}
else
{
uint8_t v___x_9829_;
v___x_9829_ = lean_uint32_dec_lt(v_passedDeps_9809_, v_totalDeps_9808_);
if (v___x_9829_ == 0)
{
uint32_t v___x_9830_;
v___x_9830_ = 257;
return v___x_9830_;
}
else
{
uint32_t v___x_9831_;
v___x_9831_ = 1;
return v___x_9831_;
}
}
}
else
{
uint32_t v___x_9832_;
v___x_9832_ = 2;
return v___x_9832_;
}
}
}
}
else
{
uint32_t v___x_9833_;
v___x_9833_ = 0;
return v___x_9833_;
}
}
}

LEAN_EXPORT uint64_t orb_fts5_lexer_step(uint32_t v_state_9848_, uint32_t v_charClass_9849_, uint32_t v_tokenLen_9850_, uint32_t v_maxTokens_9851_, uint32_t v_emittedTokens_9852_){
_start:
{
uint32_t v___y_9854_; uint32_t v___y_9855_; uint32_t v___y_9878_; uint32_t v___y_9879_; uint32_t v___y_9880_; uint32_t v___x_9889_; uint8_t v___x_9890_;
v___x_9889_ = 0;
v___x_9890_ = lean_uint32_dec_eq(v_maxTokens_9851_, v___x_9889_);
if (v___x_9890_ == 0)
{
uint8_t v___x_9891_;
v___x_9891_ = lean_uint32_dec_le(v_maxTokens_9851_, v_emittedTokens_9852_);
if (v___x_9891_ == 0)
{
uint32_t v___x_9892_; uint32_t v___y_9894_; uint32_t v___y_9895_; uint32_t v___y_9900_; uint8_t v___y_9901_; uint8_t v___x_9902_;
v___x_9892_ = 2;
v___x_9902_ = lean_uint32_dec_lt(v___x_9892_, v_state_9848_);
if (v___x_9902_ == 0)
{
uint32_t v___x_9903_; uint8_t v___x_9904_;
v___x_9903_ = 3;
v___x_9904_ = lean_uint32_dec_lt(v___x_9903_, v_charClass_9849_);
if (v___x_9904_ == 0)
{
uint8_t v___x_9905_;
v___x_9905_ = lean_uint32_dec_eq(v_state_9848_, v___x_9889_);
if (v___x_9905_ == 0)
{
uint32_t v___x_9906_; uint8_t v___x_9907_;
v___x_9906_ = 1;
v___x_9907_ = lean_uint32_dec_eq(v_state_9848_, v___x_9906_);
if (v___x_9907_ == 0)
{
uint8_t v___x_9908_;
v___x_9908_ = lean_uint32_dec_eq(v_charClass_9849_, v___x_9892_);
if (v___x_9908_ == 0)
{
uint8_t v___x_9909_;
v___x_9909_ = lean_uint32_dec_eq(v_charClass_9849_, v___x_9906_);
if (v___x_9909_ == 0)
{
uint8_t v___x_9910_;
v___x_9910_ = lean_uint32_dec_lt(v___x_9889_, v_tokenLen_9850_);
if (v___x_9910_ == 0)
{
goto v___jp_9861_;
}
else
{
uint8_t v___x_9911_;
v___x_9911_ = lean_uint32_dec_eq(v_charClass_9849_, v___x_9889_);
if (v___x_9911_ == 0)
{
goto v___jp_9861_;
}
else
{
goto v___jp_9867_;
}
}
}
else
{
goto v___jp_9867_;
}
}
else
{
uint8_t v___x_9912_; uint32_t v___y_9914_;
v___x_9912_ = lean_uint32_dec_lt(v___x_9889_, v_tokenLen_9850_);
if (v___x_9912_ == 0)
{
v___y_9914_ = v_emittedTokens_9852_;
goto v___jp_9913_;
}
else
{
uint32_t v___x_9917_;
v___x_9917_ = lean_uint32_add(v_emittedTokens_9852_, v___x_9906_);
v___y_9914_ = v___x_9917_;
goto v___jp_9913_;
}
v___jp_9913_:
{
if (v___x_9912_ == 0)
{
uint32_t v___x_9915_;
v___x_9915_ = 256;
v___y_9854_ = v___y_9914_;
v___y_9855_ = v___x_9915_;
goto v___jp_9853_;
}
else
{
uint32_t v___x_9916_;
v___x_9916_ = 261;
v___y_9854_ = v___y_9914_;
v___y_9855_ = v___x_9916_;
goto v___jp_9853_;
}
}
}
}
else
{
uint8_t v___x_9918_;
v___x_9918_ = lean_uint32_dec_eq(v_charClass_9849_, v___x_9906_);
if (v___x_9918_ == 0)
{
uint8_t v___x_9923_;
v___x_9923_ = lean_uint32_dec_eq(v_charClass_9849_, v___x_9903_);
if (v___x_9923_ == 0)
{
goto v___jp_9919_;
}
else
{
uint8_t v___x_9924_;
v___x_9924_ = lean_uint32_dec_le(v___x_9892_, v_tokenLen_9850_);
if (v___x_9924_ == 0)
{
goto v___jp_9919_;
}
else
{
uint32_t v_nextEmit_9925_; uint64_t v___x_9926_; uint64_t v___x_9927_; uint64_t v___x_9928_; uint64_t v___x_9929_; uint64_t v___x_9930_;
v_nextEmit_9925_ = lean_uint32_add(v_emittedTokens_9852_, v___x_9906_);
v___x_9926_ = 259ULL;
v___x_9927_ = lean_uint32_to_uint64(v_nextEmit_9925_);
v___x_9928_ = 32ULL;
v___x_9929_ = lean_uint64_shift_left(v___x_9927_, v___x_9928_);
v___x_9930_ = lean_uint64_lor(v___x_9926_, v___x_9929_);
return v___x_9930_;
}
}
}
else
{
uint64_t v___x_9931_; uint64_t v___x_9932_; uint64_t v___x_9933_; uint64_t v___x_9934_; uint64_t v___x_9935_;
v___x_9931_ = 65793ULL;
v___x_9932_ = lean_uint32_to_uint64(v_emittedTokens_9852_);
v___x_9933_ = 32ULL;
v___x_9934_ = lean_uint64_shift_left(v___x_9932_, v___x_9933_);
v___x_9935_ = lean_uint64_lor(v___x_9931_, v___x_9934_);
return v___x_9935_;
}
v___jp_9919_:
{
uint32_t v_nextEmit_9920_; uint8_t v___x_9921_;
v_nextEmit_9920_ = lean_uint32_add(v_emittedTokens_9852_, v___x_9906_);
v___x_9921_ = lean_uint32_dec_eq(v_charClass_9849_, v___x_9892_);
if (v___x_9921_ == 0)
{
v___y_9900_ = v_nextEmit_9920_;
v___y_9901_ = v___x_9918_;
goto v___jp_9899_;
}
else
{
uint8_t v___x_9922_;
v___x_9922_ = lean_uint32_dec_lt(v_nextEmit_9920_, v_maxTokens_9851_);
v___y_9900_ = v_nextEmit_9920_;
v___y_9901_ = v___x_9922_;
goto v___jp_9899_;
}
}
}
}
else
{
uint32_t v___x_9936_; uint8_t v___x_9937_;
v___x_9936_ = 1;
v___x_9937_ = lean_uint32_dec_eq(v_charClass_9849_, v___x_9936_);
if (v___x_9937_ == 0)
{
uint8_t v___x_9938_;
v___x_9938_ = lean_uint32_dec_eq(v_charClass_9849_, v___x_9892_);
if (v___x_9938_ == 0)
{
uint64_t v___x_9939_; uint64_t v___x_9940_; uint64_t v___x_9941_; uint64_t v___x_9942_; uint64_t v___x_9943_;
v___x_9939_ = 256ULL;
v___x_9940_ = lean_uint32_to_uint64(v_emittedTokens_9852_);
v___x_9941_ = 32ULL;
v___x_9942_ = lean_uint64_shift_left(v___x_9940_, v___x_9941_);
v___x_9943_ = lean_uint64_lor(v___x_9939_, v___x_9942_);
return v___x_9943_;
}
else
{
uint64_t v___x_9944_; uint64_t v___x_9945_; uint64_t v___x_9946_; uint64_t v___x_9947_; uint64_t v___x_9948_;
v___x_9944_ = 131332ULL;
v___x_9945_ = lean_uint32_to_uint64(v_emittedTokens_9852_);
v___x_9946_ = 32ULL;
v___x_9947_ = lean_uint64_shift_left(v___x_9945_, v___x_9946_);
v___x_9948_ = lean_uint64_lor(v___x_9944_, v___x_9947_);
return v___x_9948_;
}
}
else
{
uint64_t v___x_9949_; uint64_t v___x_9950_; uint64_t v___x_9951_; uint64_t v___x_9952_; uint64_t v___x_9953_;
v___x_9949_ = 65793ULL;
v___x_9950_ = lean_uint32_to_uint64(v_emittedTokens_9852_);
v___x_9951_ = 32ULL;
v___x_9952_ = lean_uint64_shift_left(v___x_9950_, v___x_9951_);
v___x_9953_ = lean_uint64_lor(v___x_9949_, v___x_9952_);
return v___x_9953_;
}
}
}
else
{
goto v___jp_9873_;
}
}
else
{
goto v___jp_9873_;
}
v___jp_9893_:
{
uint8_t v___x_9896_;
v___x_9896_ = lean_uint32_dec_eq(v___y_9895_, v___x_9892_);
if (v___x_9896_ == 0)
{
uint32_t v___x_9897_;
v___x_9897_ = 258;
v___y_9878_ = v___y_9895_;
v___y_9879_ = v___y_9894_;
v___y_9880_ = v___x_9897_;
goto v___jp_9877_;
}
else
{
uint32_t v___x_9898_;
v___x_9898_ = 262;
v___y_9878_ = v___y_9895_;
v___y_9879_ = v___y_9894_;
v___y_9880_ = v___x_9898_;
goto v___jp_9877_;
}
}
v___jp_9899_:
{
if (v___y_9901_ == 0)
{
v___y_9894_ = v___y_9900_;
v___y_9895_ = v___x_9889_;
goto v___jp_9893_;
}
else
{
v___y_9894_ = v___y_9900_;
v___y_9895_ = v___x_9892_;
goto v___jp_9893_;
}
}
}
else
{
goto v___jp_9873_;
}
}
else
{
goto v___jp_9873_;
}
v___jp_9853_:
{
uint64_t v___x_9856_; uint64_t v___x_9857_; uint64_t v___x_9858_; uint64_t v___x_9859_; uint64_t v___x_9860_;
v___x_9856_ = lean_uint32_to_uint64(v___y_9855_);
v___x_9857_ = lean_uint32_to_uint64(v___y_9854_);
v___x_9858_ = 32ULL;
v___x_9859_ = lean_uint64_shift_left(v___x_9857_, v___x_9858_);
v___x_9860_ = lean_uint64_lor(v___x_9856_, v___x_9859_);
return v___x_9860_;
}
v___jp_9861_:
{
uint64_t v___x_9862_; uint64_t v___x_9863_; uint64_t v___x_9864_; uint64_t v___x_9865_; uint64_t v___x_9866_;
v___x_9862_ = 131328ULL;
v___x_9863_ = lean_uint32_to_uint64(v_emittedTokens_9852_);
v___x_9864_ = 32ULL;
v___x_9865_ = lean_uint64_shift_left(v___x_9863_, v___x_9864_);
v___x_9866_ = lean_uint64_lor(v___x_9862_, v___x_9865_);
return v___x_9866_;
}
v___jp_9867_:
{
uint64_t v___x_9868_; uint64_t v___x_9869_; uint64_t v___x_9870_; uint64_t v___x_9871_; uint64_t v___x_9872_;
v___x_9868_ = 131329ULL;
v___x_9869_ = lean_uint32_to_uint64(v_emittedTokens_9852_);
v___x_9870_ = 32ULL;
v___x_9871_ = lean_uint64_shift_left(v___x_9869_, v___x_9870_);
v___x_9872_ = lean_uint64_lor(v___x_9868_, v___x_9871_);
return v___x_9872_;
}
v___jp_9873_:
{
uint64_t v___x_9874_; uint64_t v___x_9875_; uint64_t v___x_9876_;
v___x_9874_ = lean_uint32_to_uint64(v_emittedTokens_9852_);
v___x_9875_ = 32ULL;
v___x_9876_ = lean_uint64_shift_left(v___x_9874_, v___x_9875_);
return v___x_9876_;
}
v___jp_9877_:
{
uint32_t v___x_9881_; uint32_t v___x_9882_; uint32_t v___x_9883_; uint64_t v___x_9884_; uint64_t v___x_9885_; uint64_t v___x_9886_; uint64_t v___x_9887_; uint64_t v___x_9888_;
v___x_9881_ = 16;
v___x_9882_ = lean_uint32_shift_left(v___y_9878_, v___x_9881_);
v___x_9883_ = lean_uint32_lor(v___y_9880_, v___x_9882_);
v___x_9884_ = lean_uint32_to_uint64(v___x_9883_);
v___x_9885_ = lean_uint32_to_uint64(v___y_9879_);
v___x_9886_ = 32ULL;
v___x_9887_ = lean_uint64_shift_left(v___x_9885_, v___x_9886_);
v___x_9888_ = lean_uint64_lor(v___x_9884_, v___x_9887_);
return v___x_9888_;
}
}
}

LEAN_EXPORT uint64_t orb_utf8_utf16_window_step(uint32_t v_byteIdx_9966_, uint32_t v_byteLen_9967_, uint32_t v_leadByte_9968_, uint32_t v_utf16Units_9969_, uint32_t v_maxUtf16Units_9970_){
_start:
{
uint32_t v___y_9976_; uint32_t v___y_9977_; uint32_t v___y_10002_; uint32_t v___x_10021_; uint8_t v___x_10022_;
v___x_10021_ = 127;
v___x_10022_ = lean_uint32_dec_le(v_leadByte_9968_, v___x_10021_);
if (v___x_10022_ == 0)
{
uint32_t v___x_10023_; uint8_t v___x_10024_;
v___x_10023_ = 194;
v___x_10024_ = lean_uint32_dec_le(v___x_10023_, v_leadByte_9968_);
if (v___x_10024_ == 0)
{
goto v___jp_10015_;
}
else
{
uint32_t v___x_10025_; uint8_t v___x_10026_;
v___x_10025_ = 223;
v___x_10026_ = lean_uint32_dec_le(v_leadByte_9968_, v___x_10025_);
if (v___x_10026_ == 0)
{
goto v___jp_10015_;
}
else
{
uint32_t v___x_10027_;
v___x_10027_ = 2;
v___y_10002_ = v___x_10027_;
goto v___jp_10001_;
}
}
}
else
{
uint32_t v___x_10028_;
v___x_10028_ = 1;
v___y_10002_ = v___x_10028_;
goto v___jp_10001_;
}
v___jp_9971_:
{
uint64_t v___x_9972_; uint64_t v___x_9973_; uint64_t v___x_9974_;
v___x_9972_ = lean_uint32_to_uint64(v_utf16Units_9969_);
v___x_9973_ = 32ULL;
v___x_9974_ = lean_uint64_shift_left(v___x_9972_, v___x_9973_);
return v___x_9974_;
}
v___jp_9975_:
{
uint32_t v___x_9978_; uint8_t v___x_9979_;
v___x_9978_ = 0;
v___x_9979_ = lean_uint32_dec_eq(v___y_9976_, v___x_9978_);
if (v___x_9979_ == 0)
{
uint64_t v___x_9980_; uint64_t v___x_9981_; uint64_t v___x_9982_; uint64_t v___x_9983_; uint8_t v___x_9984_;
v___x_9980_ = lean_uint32_to_uint64(v_byteLen_9967_);
v___x_9981_ = lean_uint32_to_uint64(v_byteIdx_9966_);
v___x_9982_ = lean_uint32_to_uint64(v___y_9976_);
v___x_9983_ = lean_uint64_add(v___x_9981_, v___x_9982_);
v___x_9984_ = lean_uint64_dec_lt(v___x_9980_, v___x_9983_);
if (v___x_9984_ == 0)
{
uint64_t v___x_9985_; uint64_t v___x_9986_; uint64_t v___x_9987_; uint64_t v___x_9988_; uint8_t v___x_9989_;
v___x_9985_ = lean_uint32_to_uint64(v_maxUtf16Units_9970_);
v___x_9986_ = lean_uint32_to_uint64(v_utf16Units_9969_);
v___x_9987_ = lean_uint32_to_uint64(v___y_9977_);
v___x_9988_ = lean_uint64_add(v___x_9986_, v___x_9987_);
v___x_9989_ = lean_uint64_dec_lt(v___x_9985_, v___x_9988_);
if (v___x_9989_ == 0)
{
uint32_t v_nextU16_9990_; uint32_t v___x_9991_; uint32_t v___x_9992_; uint32_t v___x_9993_; uint32_t v___x_9994_; uint32_t v_lo32_9995_; uint64_t v___x_9996_; uint64_t v___x_9997_; uint64_t v___x_9998_; uint64_t v___x_9999_; uint64_t v___x_10000_;
v_nextU16_9990_ = lean_uint32_add(v_utf16Units_9969_, v___y_9977_);
v___x_9991_ = 256;
v___x_9992_ = lean_uint32_lor(v___y_9976_, v___x_9991_);
v___x_9993_ = 16;
v___x_9994_ = lean_uint32_shift_left(v___y_9977_, v___x_9993_);
v_lo32_9995_ = lean_uint32_lor(v___x_9992_, v___x_9994_);
v___x_9996_ = lean_uint32_to_uint64(v_lo32_9995_);
v___x_9997_ = lean_uint32_to_uint64(v_nextU16_9990_);
v___x_9998_ = 32ULL;
v___x_9999_ = lean_uint64_shift_left(v___x_9997_, v___x_9998_);
v___x_10000_ = lean_uint64_lor(v___x_9996_, v___x_9999_);
return v___x_10000_;
}
else
{
goto v___jp_9971_;
}
}
else
{
goto v___jp_9971_;
}
}
else
{
goto v___jp_9971_;
}
}
v___jp_10001_:
{
uint32_t v___x_10003_; uint8_t v___x_10004_;
v___x_10003_ = 4;
v___x_10004_ = lean_uint32_dec_eq(v___y_10002_, v___x_10003_);
if (v___x_10004_ == 0)
{
uint32_t v___x_10005_;
v___x_10005_ = 1;
v___y_9976_ = v___y_10002_;
v___y_9977_ = v___x_10005_;
goto v___jp_9975_;
}
else
{
uint32_t v___x_10006_;
v___x_10006_ = 2;
v___y_9976_ = v___y_10002_;
v___y_9977_ = v___x_10006_;
goto v___jp_9975_;
}
}
v___jp_10007_:
{
uint32_t v___x_10008_;
v___x_10008_ = 0;
v___y_10002_ = v___x_10008_;
goto v___jp_10001_;
}
v___jp_10009_:
{
uint32_t v___x_10010_; uint8_t v___x_10011_;
v___x_10010_ = 240;
v___x_10011_ = lean_uint32_dec_le(v___x_10010_, v_leadByte_9968_);
if (v___x_10011_ == 0)
{
goto v___jp_10007_;
}
else
{
uint32_t v___x_10012_; uint8_t v___x_10013_;
v___x_10012_ = 244;
v___x_10013_ = lean_uint32_dec_le(v_leadByte_9968_, v___x_10012_);
if (v___x_10013_ == 0)
{
goto v___jp_10007_;
}
else
{
uint32_t v___x_10014_;
v___x_10014_ = 4;
v___y_10002_ = v___x_10014_;
goto v___jp_10001_;
}
}
}
v___jp_10015_:
{
uint32_t v___x_10016_; uint8_t v___x_10017_;
v___x_10016_ = 224;
v___x_10017_ = lean_uint32_dec_le(v___x_10016_, v_leadByte_9968_);
if (v___x_10017_ == 0)
{
goto v___jp_10009_;
}
else
{
uint32_t v___x_10018_; uint8_t v___x_10019_;
v___x_10018_ = 239;
v___x_10019_ = lean_uint32_dec_le(v_leadByte_9968_, v___x_10018_);
if (v___x_10019_ == 0)
{
goto v___jp_10009_;
}
else
{
uint32_t v___x_10020_;
v___x_10020_ = 3;
v___y_10002_ = v___x_10020_;
goto v___jp_10001_;
}
}
}
}
}

LEAN_EXPORT uint8_t orb_model_account_admit(uint32_t v_candId_10041_, uint8_t v_ineligible_10042_, uint8_t v_entitlement_10043_, uint8_t v_requireEntitled_10044_){
_start:
{
uint32_t v___x_10045_; uint8_t v___x_10046_;
v___x_10045_ = 0;
v___x_10046_ = lean_uint32_dec_eq(v_candId_10041_, v___x_10045_);
if (v___x_10046_ == 0)
{
uint8_t v___x_10047_; uint8_t v___x_10048_;
v___x_10047_ = 0;
v___x_10048_ = lean_uint8_dec_eq(v_ineligible_10042_, v___x_10047_);
if (v___x_10048_ == 0)
{
return v___x_10047_;
}
else
{
uint8_t v___x_10049_; uint8_t v___x_10050_;
v___x_10049_ = 2;
v___x_10050_ = lean_uint8_dec_eq(v_entitlement_10043_, v___x_10049_);
if (v___x_10050_ == 0)
{
uint8_t v___x_10051_; uint8_t v___x_10052_;
v___x_10051_ = 1;
v___x_10052_ = lean_uint8_dec_eq(v_entitlement_10043_, v___x_10051_);
if (v___x_10052_ == 0)
{
return v___x_10047_;
}
else
{
uint8_t v___x_10053_;
v___x_10053_ = lean_uint8_dec_eq(v_requireEntitled_10044_, v___x_10047_);
if (v___x_10053_ == 0)
{
return v___x_10047_;
}
else
{
return v___x_10051_;
}
}
}
else
{
uint8_t v___x_10054_;
v___x_10054_ = 1;
return v___x_10054_;
}
}
}
else
{
uint8_t v___x_10055_;
v___x_10055_ = 0;
return v___x_10055_;
}
}
}

LEAN_EXPORT uint64_t orb_model_account_score(uint32_t v_candId_10066_, uint8_t v_ineligible_10067_, uint8_t v_entitlement_10068_, uint8_t v_requireEntitled_10069_, uint8_t v_hasPoolQuota_10070_, uint32_t v_priorityRank_10071_, uint32_t v_usableInSecs_10072_){
_start:
{
uint64_t v___y_10074_; uint64_t v___y_10075_; uint64_t v___y_10076_; uint64_t v___y_10077_; uint64_t v___y_10082_; uint64_t v___y_10083_; uint64_t v___y_10084_; uint64_t v___y_10090_; uint8_t v___y_10091_; uint64_t v___y_10092_; uint64_t v___y_10098_; uint8_t v___y_10104_; uint32_t v___x_10112_; uint8_t v___x_10113_;
v___x_10112_ = 0;
v___x_10113_ = lean_uint32_dec_eq(v_candId_10066_, v___x_10112_);
if (v___x_10113_ == 0)
{
uint8_t v___x_10114_; uint8_t v___x_10115_;
v___x_10114_ = 0;
v___x_10115_ = lean_uint8_dec_eq(v_ineligible_10067_, v___x_10114_);
if (v___x_10115_ == 0)
{
v___y_10104_ = v___x_10114_;
goto v___jp_10103_;
}
else
{
uint8_t v___x_10116_; uint8_t v___x_10117_;
v___x_10116_ = 2;
v___x_10117_ = lean_uint8_dec_eq(v_entitlement_10068_, v___x_10116_);
if (v___x_10117_ == 0)
{
uint8_t v___x_10118_; uint8_t v___x_10119_;
v___x_10118_ = 1;
v___x_10119_ = lean_uint8_dec_eq(v_entitlement_10068_, v___x_10118_);
if (v___x_10119_ == 0)
{
v___y_10104_ = v___x_10114_;
goto v___jp_10103_;
}
else
{
uint8_t v___x_10120_;
v___x_10120_ = lean_uint8_dec_eq(v_requireEntitled_10069_, v___x_10114_);
if (v___x_10120_ == 0)
{
v___y_10104_ = v___x_10114_;
goto v___jp_10103_;
}
else
{
v___y_10104_ = v___x_10118_;
goto v___jp_10103_;
}
}
}
else
{
uint8_t v___x_10121_;
v___x_10121_ = 1;
v___y_10104_ = v___x_10121_;
goto v___jp_10103_;
}
}
}
else
{
uint8_t v___x_10122_;
v___x_10122_ = 0;
v___y_10104_ = v___x_10122_;
goto v___jp_10103_;
}
v___jp_10073_:
{
uint64_t v___x_10078_; uint64_t v___x_10079_; uint64_t v___x_10080_;
v___x_10078_ = lean_uint64_lor(v___y_10074_, v___y_10075_);
v___x_10079_ = lean_uint64_lor(v___x_10078_, v___y_10076_);
v___x_10080_ = lean_uint64_lor(v___x_10079_, v___y_10077_);
return v___x_10080_;
}
v___jp_10081_:
{
uint32_t v___x_10085_; uint8_t v___x_10086_;
v___x_10085_ = 65535;
v___x_10086_ = lean_uint32_dec_le(v_priorityRank_10071_, v___x_10085_);
if (v___x_10086_ == 0)
{
uint64_t v___x_10087_;
v___x_10087_ = 65535ULL;
v___y_10074_ = v___y_10082_;
v___y_10075_ = v___y_10083_;
v___y_10076_ = v___y_10084_;
v___y_10077_ = v___x_10087_;
goto v___jp_10073_;
}
else
{
uint64_t v___x_10088_;
v___x_10088_ = lean_uint32_to_uint64(v_priorityRank_10071_);
v___y_10074_ = v___y_10082_;
v___y_10075_ = v___y_10083_;
v___y_10076_ = v___y_10084_;
v___y_10077_ = v___x_10088_;
goto v___jp_10073_;
}
}
v___jp_10089_:
{
if (v___y_10091_ == 0)
{
uint64_t v___x_10093_; uint64_t v___x_10094_; uint64_t v___x_10095_;
v___x_10093_ = lean_uint32_to_uint64(v_usableInSecs_10072_);
v___x_10094_ = 16ULL;
v___x_10095_ = lean_uint64_shift_left(v___x_10093_, v___x_10094_);
v___y_10082_ = v___y_10090_;
v___y_10083_ = v___y_10092_;
v___y_10084_ = v___x_10095_;
goto v___jp_10081_;
}
else
{
uint64_t v___x_10096_;
v___x_10096_ = 0ULL;
v___y_10082_ = v___y_10090_;
v___y_10083_ = v___y_10092_;
v___y_10084_ = v___x_10096_;
goto v___jp_10081_;
}
}
v___jp_10097_:
{
uint8_t v___x_10099_; uint8_t v___x_10100_;
v___x_10099_ = 1;
v___x_10100_ = lean_uint8_dec_eq(v_hasPoolQuota_10070_, v___x_10099_);
if (v___x_10100_ == 0)
{
uint64_t v___x_10101_;
v___x_10101_ = 562949953421312ULL;
v___y_10090_ = v___y_10098_;
v___y_10091_ = v___x_10100_;
v___y_10092_ = v___x_10101_;
goto v___jp_10089_;
}
else
{
uint64_t v___x_10102_;
v___x_10102_ = 0ULL;
v___y_10090_ = v___y_10098_;
v___y_10091_ = v___x_10100_;
v___y_10092_ = v___x_10102_;
goto v___jp_10089_;
}
}
v___jp_10103_:
{
uint8_t v___x_10105_; uint8_t v___x_10106_;
v___x_10105_ = 0;
v___x_10106_ = lean_uint8_dec_eq(v___y_10104_, v___x_10105_);
if (v___x_10106_ == 0)
{
uint8_t v___x_10107_; uint8_t v___x_10108_;
v___x_10107_ = 2;
v___x_10108_ = lean_uint8_dec_eq(v_entitlement_10068_, v___x_10107_);
if (v___x_10108_ == 0)
{
uint64_t v___x_10109_;
v___x_10109_ = 1125899906842624ULL;
v___y_10098_ = v___x_10109_;
goto v___jp_10097_;
}
else
{
uint64_t v___x_10110_;
v___x_10110_ = 0ULL;
v___y_10098_ = v___x_10110_;
goto v___jp_10097_;
}
}
else
{
uint64_t v___x_10111_;
v___x_10111_ = 18446744073709551615ULL;
return v___x_10111_;
}
}
}
}

LEAN_EXPORT uint64_t orb_epoch_fence_step(uint64_t v_durableOwnerEpoch_10139_, uint64_t v_liveOwnerEpoch_10140_, uint64_t v_durableRunGeneration_10141_, uint64_t v_liveRunGeneration_10142_, uint64_t v_durableBootEpoch_10143_, uint64_t v_liveBootEpoch_10144_, uint32_t v_durableRevision_10145_, uint32_t v_liveRevision_10146_, uint64_t v_writerOwnerEpoch_10147_){
_start:
{
uint32_t v___y_10149_; uint32_t v___y_10150_; uint32_t v___y_10157_; uint8_t v___y_10165_; uint8_t v___x_10183_;
v___x_10183_ = lean_uint64_dec_eq(v_writerOwnerEpoch_10147_, v_durableOwnerEpoch_10139_);
if (v___x_10183_ == 0)
{
v___y_10165_ = v___x_10183_;
goto v___jp_10164_;
}
else
{
uint8_t v___x_10184_;
v___x_10184_ = lean_uint64_dec_eq(v_writerOwnerEpoch_10147_, v_liveOwnerEpoch_10140_);
v___y_10165_ = v___x_10184_;
goto v___jp_10164_;
}
v___jp_10148_:
{
uint64_t v___x_10151_; uint64_t v___x_10152_; uint64_t v___x_10153_; uint64_t v___x_10154_; uint64_t v___x_10155_;
v___x_10151_ = lean_uint32_to_uint64(v___y_10149_);
v___x_10152_ = lean_uint32_to_uint64(v___y_10150_);
v___x_10153_ = 32ULL;
v___x_10154_ = lean_uint64_shift_left(v___x_10152_, v___x_10153_);
v___x_10155_ = lean_uint64_lor(v___x_10151_, v___x_10154_);
return v___x_10155_;
}
v___jp_10156_:
{
uint32_t v___x_10158_; uint8_t v___x_10159_;
v___x_10158_ = 257;
v___x_10159_ = lean_uint32_dec_eq(v___y_10157_, v___x_10158_);
if (v___x_10159_ == 0)
{
v___y_10149_ = v___y_10157_;
v___y_10150_ = v_durableRevision_10145_;
goto v___jp_10148_;
}
else
{
uint32_t v___x_10160_; uint32_t v___x_10161_;
v___x_10160_ = 1;
v___x_10161_ = lean_uint32_add(v_durableRevision_10145_, v___x_10160_);
v___y_10149_ = v___y_10157_;
v___y_10150_ = v___x_10161_;
goto v___jp_10148_;
}
}
v___jp_10162_:
{
uint32_t v___x_10163_;
v___x_10163_ = 0;
v___y_10157_ = v___x_10163_;
goto v___jp_10156_;
}
v___jp_10164_:
{
uint64_t v___x_10166_; uint8_t v___x_10167_;
v___x_10166_ = 0ULL;
v___x_10167_ = lean_uint64_dec_eq(v_durableOwnerEpoch_10139_, v___x_10166_);
if (v___x_10167_ == 0)
{
uint8_t v_runOk_10168_; uint8_t v___x_10169_;
v_runOk_10168_ = lean_uint64_dec_eq(v_liveRunGeneration_10142_, v_durableRunGeneration_10141_);
v___x_10169_ = lean_uint64_dec_eq(v_durableRunGeneration_10141_, v___x_10166_);
if (v___x_10169_ == 0)
{
uint8_t v_bootOk_10170_; uint8_t v___x_10171_;
v_bootOk_10170_ = lean_uint64_dec_eq(v_liveBootEpoch_10144_, v_durableBootEpoch_10143_);
v___x_10171_ = lean_uint64_dec_eq(v_durableBootEpoch_10143_, v___x_10166_);
if (v___x_10171_ == 0)
{
uint8_t v_revMatch_10172_; uint32_t v___x_10173_; uint8_t v_revRoom_10174_; uint32_t v___x_10175_; uint8_t v___x_10176_;
v_revMatch_10172_ = lean_uint32_dec_eq(v_liveRevision_10146_, v_durableRevision_10145_);
v___x_10173_ = 4294967295;
v_revRoom_10174_ = lean_uint32_dec_lt(v_durableRevision_10145_, v___x_10173_);
v___x_10175_ = 0;
v___x_10176_ = lean_uint32_dec_eq(v_durableRevision_10145_, v___x_10175_);
if (v___x_10176_ == 0)
{
if (v___y_10165_ == 0)
{
uint32_t v___x_10177_;
v___x_10177_ = 5;
v___y_10157_ = v___x_10177_;
goto v___jp_10156_;
}
else
{
if (v_revMatch_10172_ == 0)
{
uint32_t v___x_10178_;
v___x_10178_ = 2;
v___y_10157_ = v___x_10178_;
goto v___jp_10156_;
}
else
{
if (v_runOk_10168_ == 0)
{
uint32_t v___x_10179_;
v___x_10179_ = 3;
v___y_10157_ = v___x_10179_;
goto v___jp_10156_;
}
else
{
if (v_bootOk_10170_ == 0)
{
uint32_t v___x_10180_;
v___x_10180_ = 4;
v___y_10157_ = v___x_10180_;
goto v___jp_10156_;
}
else
{
if (v_revRoom_10174_ == 0)
{
uint32_t v___x_10181_;
v___x_10181_ = 6;
v___y_10157_ = v___x_10181_;
goto v___jp_10156_;
}
else
{
uint32_t v___x_10182_;
v___x_10182_ = 257;
v___y_10157_ = v___x_10182_;
goto v___jp_10156_;
}
}
}
}
}
}
else
{
goto v___jp_10162_;
}
}
else
{
goto v___jp_10162_;
}
}
else
{
goto v___jp_10162_;
}
}
else
{
goto v___jp_10162_;
}
}
}
}

LEAN_EXPORT uint64_t orb_effect_outbox_step(uint8_t v_phase_10205_, uint8_t v_delivered_10206_, uint8_t v_op_10207_, uint8_t v_fenceMatches_10208_, uint64_t v_attemptEpoch_10209_, uint64_t v_nodeBootEpoch_10210_){
_start:
{
uint8_t v___y_10212_; uint32_t v___y_10213_; uint8_t v___y_10221_; uint8_t v___y_10224_; uint8_t v___y_10225_; uint8_t v___y_10226_; uint8_t v___y_10227_; uint8_t v___y_10228_; uint8_t v___y_10229_; uint8_t v___y_10230_; uint8_t v___y_10240_; uint8_t v___y_10241_; uint8_t v___y_10242_; uint8_t v___y_10243_; uint8_t v___y_10244_; uint8_t v___y_10245_; uint8_t v___x_10248_; uint8_t v___y_10250_; uint8_t v___y_10251_; uint8_t v___y_10252_; uint8_t v___y_10253_; uint8_t v___y_10254_; uint8_t v___y_10255_; uint8_t v___y_10260_; uint8_t v___y_10261_; uint8_t v___y_10262_; uint8_t v___y_10263_; uint8_t v___y_10274_; uint8_t v___x_10298_;
v___x_10248_ = 1;
v___x_10298_ = lean_uint8_dec_eq(v_fenceMatches_10208_, v___x_10248_);
if (v___x_10298_ == 0)
{
v___y_10274_ = v___x_10298_;
goto v___jp_10273_;
}
else
{
uint8_t v___x_10299_;
v___x_10299_ = lean_uint64_dec_eq(v_attemptEpoch_10209_, v_nodeBootEpoch_10210_);
if (v___x_10299_ == 0)
{
v___y_10274_ = v___x_10299_;
goto v___jp_10273_;
}
else
{
uint64_t v___x_10300_; uint8_t v___x_10301_;
v___x_10300_ = 0ULL;
v___x_10301_ = lean_uint64_dec_eq(v_attemptEpoch_10209_, v___x_10300_);
if (v___x_10301_ == 0)
{
v___y_10274_ = v___x_10299_;
goto v___jp_10273_;
}
else
{
uint8_t v___x_10302_;
v___x_10302_ = 0;
v___y_10274_ = v___x_10302_;
goto v___jp_10273_;
}
}
}
v___jp_10211_:
{
uint64_t v___x_10214_; uint32_t v___x_10215_; uint64_t v___x_10216_; uint64_t v___x_10217_; uint64_t v___x_10218_; uint64_t v___x_10219_;
v___x_10214_ = lean_uint32_to_uint64(v___y_10213_);
v___x_10215_ = lean_uint8_to_uint32(v___y_10212_);
v___x_10216_ = lean_uint32_to_uint64(v___x_10215_);
v___x_10217_ = 32ULL;
v___x_10218_ = lean_uint64_shift_left(v___x_10216_, v___x_10217_);
v___x_10219_ = lean_uint64_lor(v___x_10214_, v___x_10218_);
return v___x_10219_;
}
v___jp_10220_:
{
uint32_t v___x_10222_;
v___x_10222_ = 0;
v___y_10212_ = v___y_10221_;
v___y_10213_ = v___x_10222_;
goto v___jp_10211_;
}
v___jp_10223_:
{
if (v___y_10228_ == 0)
{
if (v___y_10227_ == 0)
{
v___y_10221_ = v___y_10225_;
goto v___jp_10220_;
}
else
{
if (v___y_10224_ == 0)
{
v___y_10221_ = v___y_10225_;
goto v___jp_10220_;
}
else
{
if (v___y_10230_ == 0)
{
if (v___y_10226_ == 0)
{
uint32_t v___x_10231_;
v___x_10231_ = 2;
v___y_10212_ = v___y_10225_;
v___y_10213_ = v___x_10231_;
goto v___jp_10211_;
}
else
{
uint32_t v___x_10232_; uint32_t v___x_10233_; uint32_t v___x_10234_; uint32_t v___x_10235_; uint32_t v___x_10236_;
v___x_10232_ = 257;
v___x_10233_ = lean_uint8_to_uint32(v___y_10229_);
v___x_10234_ = 16;
v___x_10235_ = lean_uint32_shift_left(v___x_10233_, v___x_10234_);
v___x_10236_ = lean_uint32_lor(v___x_10232_, v___x_10235_);
v___y_10212_ = v___y_10225_;
v___y_10213_ = v___x_10236_;
goto v___jp_10211_;
}
}
else
{
uint32_t v___x_10237_;
v___x_10237_ = 3;
v___y_10212_ = v___y_10225_;
v___y_10213_ = v___x_10237_;
goto v___jp_10211_;
}
}
}
}
else
{
uint32_t v___x_10238_;
v___x_10238_ = 4;
v___y_10212_ = v___y_10225_;
v___y_10213_ = v___x_10238_;
goto v___jp_10211_;
}
}
v___jp_10239_:
{
uint8_t v___x_10246_; uint8_t v___x_10247_;
v___x_10246_ = 4;
v___x_10247_ = lean_uint8_dec_eq(v_phase_10205_, v___x_10246_);
v___y_10224_ = v___y_10240_;
v___y_10225_ = v___y_10241_;
v___y_10226_ = v___y_10242_;
v___y_10227_ = v___y_10243_;
v___y_10228_ = v___y_10244_;
v___y_10229_ = v___y_10245_;
v___y_10230_ = v___x_10247_;
goto v___jp_10223_;
}
v___jp_10249_:
{
uint8_t v___x_10256_;
v___x_10256_ = lean_uint8_dec_eq(v_op_10207_, v___x_10248_);
if (v___x_10256_ == 0)
{
uint8_t v___x_10257_; uint8_t v___x_10258_;
v___x_10257_ = 2;
v___x_10258_ = lean_uint8_dec_eq(v_op_10207_, v___x_10257_);
if (v___x_10258_ == 0)
{
v___y_10224_ = v___y_10250_;
v___y_10225_ = v___y_10255_;
v___y_10226_ = v___y_10251_;
v___y_10227_ = v___y_10252_;
v___y_10228_ = v___y_10253_;
v___y_10229_ = v___y_10254_;
v___y_10230_ = v___x_10258_;
goto v___jp_10223_;
}
else
{
v___y_10240_ = v___y_10250_;
v___y_10241_ = v___y_10255_;
v___y_10242_ = v___y_10251_;
v___y_10243_ = v___y_10252_;
v___y_10244_ = v___y_10253_;
v___y_10245_ = v___y_10254_;
goto v___jp_10239_;
}
}
else
{
v___y_10240_ = v___y_10250_;
v___y_10241_ = v___y_10255_;
v___y_10242_ = v___y_10251_;
v___y_10243_ = v___y_10252_;
v___y_10244_ = v___y_10253_;
v___y_10245_ = v___y_10254_;
goto v___jp_10239_;
}
}
v___jp_10259_:
{
uint8_t v___x_10264_;
v___x_10264_ = lean_uint8_dec_eq(v___y_10263_, v_phase_10205_);
if (v___x_10264_ == 0)
{
uint8_t v___x_10265_; uint8_t v___x_10266_; uint8_t v___x_10267_;
v___x_10265_ = 1;
v___x_10266_ = 2;
v___x_10267_ = lean_uint8_dec_eq(v___y_10263_, v___x_10266_);
if (v___x_10267_ == 0)
{
uint8_t v___x_10268_; uint8_t v___x_10269_;
v___x_10268_ = 0;
v___x_10269_ = lean_uint8_dec_eq(v___y_10263_, v___x_10268_);
if (v___x_10269_ == 0)
{
uint8_t v___x_10270_; uint8_t v___x_10271_;
v___x_10270_ = 3;
v___x_10271_ = lean_uint8_dec_eq(v___y_10263_, v___x_10270_);
if (v___x_10271_ == 0)
{
v___y_10250_ = v___y_10260_;
v___y_10251_ = v___x_10265_;
v___y_10252_ = v___y_10261_;
v___y_10253_ = v___y_10262_;
v___y_10254_ = v___y_10263_;
v___y_10255_ = v_delivered_10206_;
goto v___jp_10249_;
}
else
{
v___y_10250_ = v___y_10260_;
v___y_10251_ = v___x_10265_;
v___y_10252_ = v___y_10261_;
v___y_10253_ = v___y_10262_;
v___y_10254_ = v___y_10263_;
v___y_10255_ = v___x_10268_;
goto v___jp_10249_;
}
}
else
{
v___y_10250_ = v___y_10260_;
v___y_10251_ = v___x_10265_;
v___y_10252_ = v___y_10261_;
v___y_10253_ = v___y_10262_;
v___y_10254_ = v___y_10263_;
v___y_10255_ = v___x_10268_;
goto v___jp_10249_;
}
}
else
{
v___y_10250_ = v___y_10260_;
v___y_10251_ = v___x_10265_;
v___y_10252_ = v___y_10261_;
v___y_10253_ = v___y_10262_;
v___y_10254_ = v___y_10263_;
v___y_10255_ = v___x_10248_;
goto v___jp_10249_;
}
}
else
{
uint8_t v___x_10272_;
v___x_10272_ = 0;
v___y_10250_ = v___y_10260_;
v___y_10251_ = v___x_10272_;
v___y_10252_ = v___y_10261_;
v___y_10253_ = v___y_10262_;
v___y_10254_ = v___y_10263_;
v___y_10255_ = v_delivered_10206_;
goto v___jp_10249_;
}
}
v___jp_10273_:
{
uint8_t v___x_10275_; uint8_t v_phaseOk_10276_; uint8_t v_opOk_10277_;
v___x_10275_ = 5;
v_phaseOk_10276_ = lean_uint8_dec_le(v_phase_10205_, v___x_10275_);
v_opOk_10277_ = lean_uint8_dec_le(v_op_10207_, v___x_10275_);
if (v___y_10274_ == 0)
{
uint8_t v___x_10278_;
v___x_10278_ = 1;
v___y_10260_ = v_opOk_10277_;
v___y_10261_ = v_phaseOk_10276_;
v___y_10262_ = v___x_10278_;
v___y_10263_ = v_phase_10205_;
goto v___jp_10259_;
}
else
{
uint8_t v___x_10279_;
v___x_10279_ = 0;
if (v_phaseOk_10276_ == 0)
{
v___y_10260_ = v_opOk_10277_;
v___y_10261_ = v_phaseOk_10276_;
v___y_10262_ = v___x_10279_;
v___y_10263_ = v_phase_10205_;
goto v___jp_10259_;
}
else
{
if (v_opOk_10277_ == 0)
{
v___y_10260_ = v_opOk_10277_;
v___y_10261_ = v_phaseOk_10276_;
v___y_10262_ = v___x_10279_;
v___y_10263_ = v_phase_10205_;
goto v___jp_10259_;
}
else
{
uint8_t v___x_10280_; uint8_t v___x_10281_;
v___x_10280_ = 0;
v___x_10281_ = lean_uint8_dec_eq(v_op_10207_, v___x_10280_);
if (v___x_10281_ == 0)
{
uint8_t v___x_10282_;
v___x_10282_ = lean_uint8_dec_eq(v_op_10207_, v___x_10248_);
if (v___x_10282_ == 0)
{
uint8_t v___x_10283_; uint8_t v___x_10284_;
v___x_10283_ = 2;
v___x_10284_ = lean_uint8_dec_eq(v_op_10207_, v___x_10283_);
if (v___x_10284_ == 0)
{
uint8_t v___x_10285_; uint8_t v___x_10286_;
v___x_10285_ = 3;
v___x_10286_ = lean_uint8_dec_eq(v_op_10207_, v___x_10285_);
if (v___x_10286_ == 0)
{
uint8_t v___x_10287_; uint8_t v___x_10288_;
v___x_10287_ = 4;
v___x_10288_ = lean_uint8_dec_eq(v_op_10207_, v___x_10287_);
if (v___x_10288_ == 0)
{
uint8_t v___x_10289_;
v___x_10289_ = lean_uint8_dec_eq(v_op_10207_, v___x_10275_);
if (v___x_10289_ == 0)
{
v___y_10260_ = v_opOk_10277_;
v___y_10261_ = v_phaseOk_10276_;
v___y_10262_ = v___x_10279_;
v___y_10263_ = v_phase_10205_;
goto v___jp_10259_;
}
else
{
uint8_t v___x_10290_;
v___x_10290_ = lean_uint8_dec_eq(v_phase_10205_, v___x_10287_);
if (v___x_10290_ == 0)
{
v___y_10260_ = v_opOk_10277_;
v___y_10261_ = v_phaseOk_10276_;
v___y_10262_ = v___x_10279_;
v___y_10263_ = v_phase_10205_;
goto v___jp_10259_;
}
else
{
v___y_10260_ = v_opOk_10277_;
v___y_10261_ = v_phaseOk_10276_;
v___y_10262_ = v___x_10279_;
v___y_10263_ = v___x_10275_;
goto v___jp_10259_;
}
}
}
else
{
uint8_t v___x_10291_;
v___x_10291_ = lean_uint8_dec_eq(v_phase_10205_, v___x_10248_);
if (v___x_10291_ == 0)
{
v___y_10260_ = v_opOk_10277_;
v___y_10261_ = v_phaseOk_10276_;
v___y_10262_ = v___x_10279_;
v___y_10263_ = v_phase_10205_;
goto v___jp_10259_;
}
else
{
v___y_10260_ = v_opOk_10277_;
v___y_10261_ = v_phaseOk_10276_;
v___y_10262_ = v___x_10279_;
v___y_10263_ = v___x_10287_;
goto v___jp_10259_;
}
}
}
else
{
uint8_t v___x_10292_;
v___x_10292_ = lean_uint8_dec_eq(v_phase_10205_, v___x_10248_);
if (v___x_10292_ == 0)
{
v___y_10260_ = v_opOk_10277_;
v___y_10261_ = v_phaseOk_10276_;
v___y_10262_ = v___x_10279_;
v___y_10263_ = v_phase_10205_;
goto v___jp_10259_;
}
else
{
v___y_10260_ = v_opOk_10277_;
v___y_10261_ = v_phaseOk_10276_;
v___y_10262_ = v___x_10279_;
v___y_10263_ = v___x_10285_;
goto v___jp_10259_;
}
}
}
else
{
uint8_t v___x_10293_;
v___x_10293_ = lean_uint8_dec_eq(v_phase_10205_, v___x_10248_);
if (v___x_10293_ == 0)
{
v___y_10260_ = v_opOk_10277_;
v___y_10261_ = v_phaseOk_10276_;
v___y_10262_ = v___x_10279_;
v___y_10263_ = v_phase_10205_;
goto v___jp_10259_;
}
else
{
v___y_10260_ = v_opOk_10277_;
v___y_10261_ = v_phaseOk_10276_;
v___y_10262_ = v___x_10279_;
v___y_10263_ = v___x_10283_;
goto v___jp_10259_;
}
}
}
else
{
uint8_t v___x_10294_;
v___x_10294_ = lean_uint8_dec_eq(v_phase_10205_, v___x_10280_);
if (v___x_10294_ == 0)
{
v___y_10260_ = v_opOk_10277_;
v___y_10261_ = v_phaseOk_10276_;
v___y_10262_ = v___x_10279_;
v___y_10263_ = v_phase_10205_;
goto v___jp_10259_;
}
else
{
v___y_10260_ = v_opOk_10277_;
v___y_10261_ = v_phaseOk_10276_;
v___y_10262_ = v___x_10279_;
v___y_10263_ = v___x_10248_;
goto v___jp_10259_;
}
}
}
else
{
uint8_t v___x_10295_; uint8_t v___x_10296_;
v___x_10295_ = 3;
v___x_10296_ = lean_uint8_dec_eq(v_phase_10205_, v___x_10295_);
if (v___x_10296_ == 0)
{
uint8_t v___x_10297_;
v___x_10297_ = lean_uint8_dec_eq(v_phase_10205_, v___x_10275_);
if (v___x_10297_ == 0)
{
v___y_10260_ = v_opOk_10277_;
v___y_10261_ = v_phaseOk_10276_;
v___y_10262_ = v___x_10279_;
v___y_10263_ = v_phase_10205_;
goto v___jp_10259_;
}
else
{
v___y_10260_ = v_opOk_10277_;
v___y_10261_ = v_phaseOk_10276_;
v___y_10262_ = v___x_10279_;
v___y_10263_ = v___x_10280_;
goto v___jp_10259_;
}
}
else
{
v___y_10260_ = v_opOk_10277_;
v___y_10261_ = v_phaseOk_10276_;
v___y_10262_ = v___x_10279_;
v___y_10263_ = v___x_10280_;
goto v___jp_10259_;
}
}
}
}
}
}
}
}

LEAN_EXPORT uint64_t orb_crash_boundary_step(uint32_t v_durableQueued_10317_, uint32_t v_durableAcked_10318_, uint64_t v_stateRevision_10319_, uint32_t v_volatileInFlight_10320_, uint64_t v_leaseBootEpoch_10321_, uint64_t v_nodeBootEpoch_10322_, uint32_t v_volatileLeaseOwner_10323_, uint32_t v_reqOwner_10324_){
_start:
{
uint32_t v___y_10326_; uint32_t v___y_10327_; uint32_t v___y_10334_; uint32_t v___y_10335_; uint32_t v___y_10336_; uint32_t v___y_10337_; uint8_t v___y_10341_; uint32_t v___y_10342_; uint32_t v___y_10343_; uint8_t v___y_10344_; uint32_t v___y_10345_; uint32_t v___y_10346_; uint8_t v___y_10354_; uint32_t v___y_10355_; uint8_t v___y_10356_; uint8_t v___y_10357_; uint32_t v___y_10358_; uint32_t v___y_10359_; uint8_t v___y_10362_; uint32_t v___y_10363_; uint8_t v___y_10364_; uint8_t v___y_10365_; uint32_t v___y_10366_; uint32_t v___y_10371_; uint8_t v___y_10372_; uint8_t v___y_10373_; uint32_t v___y_10374_; uint8_t v___y_10375_; uint32_t v___y_10377_; uint8_t v___y_10378_; uint8_t v___y_10379_; uint32_t v___y_10380_; uint32_t v___y_10381_; uint32_t v___y_10384_; uint8_t v___y_10385_; uint8_t v___y_10386_; uint32_t v___y_10387_; uint32_t v___y_10388_; uint8_t v___y_10396_; uint32_t v___y_10397_; uint8_t v___y_10403_; uint8_t v___y_10406_; uint8_t v___x_10408_;
v___x_10408_ = lean_uint32_dec_le(v_durableAcked_10318_, v_durableQueued_10317_);
if (v___x_10408_ == 0)
{
v___y_10406_ = v___x_10408_;
goto v___jp_10405_;
}
else
{
uint64_t v___x_10409_; uint8_t v___x_10410_;
v___x_10409_ = 0ULL;
v___x_10410_ = lean_uint64_dec_eq(v_stateRevision_10319_, v___x_10409_);
if (v___x_10410_ == 0)
{
v___y_10406_ = v___x_10408_;
goto v___jp_10405_;
}
else
{
uint8_t v___x_10411_;
v___x_10411_ = 0;
v___y_10403_ = v___x_10411_;
goto v___jp_10402_;
}
}
v___jp_10325_:
{
uint64_t v___x_10328_; uint64_t v___x_10329_; uint64_t v___x_10330_; uint64_t v___x_10331_; uint64_t v___x_10332_;
v___x_10328_ = lean_uint32_to_uint64(v___y_10327_);
v___x_10329_ = lean_uint32_to_uint64(v___y_10326_);
v___x_10330_ = 32ULL;
v___x_10331_ = lean_uint64_shift_left(v___x_10329_, v___x_10330_);
v___x_10332_ = lean_uint64_lor(v___x_10328_, v___x_10331_);
return v___x_10332_;
}
v___jp_10333_:
{
uint32_t v___x_10338_; uint32_t v___x_10339_;
v___x_10338_ = lean_uint32_lor(v___y_10337_, v___y_10336_);
v___x_10339_ = lean_uint32_lor(v___x_10338_, v___y_10334_);
v___y_10326_ = v___y_10335_;
v___y_10327_ = v___x_10339_;
goto v___jp_10325_;
}
v___jp_10340_:
{
if (v___y_10344_ == 0)
{
v___y_10326_ = v___y_10343_;
v___y_10327_ = v___y_10345_;
goto v___jp_10325_;
}
else
{
if (v___y_10341_ == 0)
{
uint8_t v___x_10347_;
v___x_10347_ = lean_uint32_dec_eq(v___y_10343_, v___y_10345_);
if (v___x_10347_ == 0)
{
uint32_t v___x_10348_;
v___x_10348_ = 3;
v___y_10334_ = v___y_10342_;
v___y_10335_ = v___y_10343_;
v___y_10336_ = v___y_10346_;
v___y_10337_ = v___x_10348_;
goto v___jp_10333_;
}
else
{
uint32_t v___x_10349_;
v___x_10349_ = 2;
v___y_10334_ = v___y_10342_;
v___y_10335_ = v___y_10343_;
v___y_10336_ = v___y_10346_;
v___y_10337_ = v___x_10349_;
goto v___jp_10333_;
}
}
else
{
uint32_t v___x_10350_; uint32_t v___x_10351_; uint32_t v___x_10352_;
v___x_10350_ = 257;
v___x_10351_ = lean_uint32_lor(v___x_10350_, v___y_10346_);
v___x_10352_ = lean_uint32_lor(v___x_10351_, v___y_10342_);
v___y_10326_ = v___y_10343_;
v___y_10327_ = v___x_10352_;
goto v___jp_10325_;
}
}
}
v___jp_10353_:
{
if (v___y_10357_ == 0)
{
v___y_10341_ = v___y_10354_;
v___y_10342_ = v___y_10359_;
v___y_10343_ = v___y_10355_;
v___y_10344_ = v___y_10356_;
v___y_10345_ = v___y_10358_;
v___y_10346_ = v___y_10358_;
goto v___jp_10340_;
}
else
{
uint32_t v___x_10360_;
v___x_10360_ = 512;
v___y_10341_ = v___y_10354_;
v___y_10342_ = v___y_10359_;
v___y_10343_ = v___y_10355_;
v___y_10344_ = v___y_10356_;
v___y_10345_ = v___y_10358_;
v___y_10346_ = v___x_10360_;
goto v___jp_10340_;
}
}
v___jp_10361_:
{
uint32_t v___x_10367_; uint8_t v___x_10368_;
v___x_10367_ = 0;
v___x_10368_ = lean_uint32_dec_eq(v___y_10366_, v___x_10367_);
if (v___x_10368_ == 0)
{
uint32_t v___x_10369_;
v___x_10369_ = 1024;
v___y_10354_ = v___y_10362_;
v___y_10355_ = v___y_10363_;
v___y_10356_ = v___y_10364_;
v___y_10357_ = v___y_10365_;
v___y_10358_ = v___x_10367_;
v___y_10359_ = v___x_10369_;
goto v___jp_10353_;
}
else
{
v___y_10354_ = v___y_10362_;
v___y_10355_ = v___y_10363_;
v___y_10356_ = v___y_10364_;
v___y_10357_ = v___y_10365_;
v___y_10358_ = v___x_10367_;
v___y_10359_ = v___x_10367_;
goto v___jp_10353_;
}
}
v___jp_10370_:
{
if (v___y_10375_ == 0)
{
v___y_10362_ = v___y_10375_;
v___y_10363_ = v___y_10371_;
v___y_10364_ = v___y_10372_;
v___y_10365_ = v___y_10373_;
v___y_10366_ = v___y_10374_;
goto v___jp_10361_;
}
else
{
v___y_10362_ = v___y_10375_;
v___y_10363_ = v___y_10371_;
v___y_10364_ = v___y_10372_;
v___y_10365_ = v___y_10373_;
v___y_10366_ = v_reqOwner_10324_;
goto v___jp_10361_;
}
}
v___jp_10376_:
{
uint8_t v___x_10382_;
v___x_10382_ = lean_uint32_dec_lt(v___y_10380_, v___y_10377_);
v___y_10371_ = v___y_10377_;
v___y_10372_ = v___y_10378_;
v___y_10373_ = v___y_10379_;
v___y_10374_ = v___y_10381_;
v___y_10375_ = v___x_10382_;
goto v___jp_10370_;
}
v___jp_10383_:
{
if (v___y_10385_ == 0)
{
v___y_10362_ = v___y_10385_;
v___y_10363_ = v___y_10384_;
v___y_10364_ = v___y_10385_;
v___y_10365_ = v___y_10386_;
v___y_10366_ = v___y_10387_;
goto v___jp_10361_;
}
else
{
uint32_t v___x_10389_; uint8_t v___x_10390_;
v___x_10389_ = 0;
v___x_10390_ = lean_uint32_dec_lt(v___x_10389_, v___y_10384_);
if (v___x_10390_ == 0)
{
v___y_10371_ = v___y_10384_;
v___y_10372_ = v___y_10385_;
v___y_10373_ = v___y_10386_;
v___y_10374_ = v___y_10387_;
v___y_10375_ = v___x_10390_;
goto v___jp_10370_;
}
else
{
uint8_t v___x_10391_;
v___x_10391_ = lean_uint32_dec_eq(v_reqOwner_10324_, v___x_10389_);
if (v___x_10391_ == 0)
{
uint8_t v___x_10392_;
v___x_10392_ = lean_uint32_dec_eq(v___y_10387_, v___x_10389_);
if (v___x_10392_ == 0)
{
uint8_t v___x_10393_;
v___x_10393_ = lean_uint32_dec_eq(v___y_10387_, v_reqOwner_10324_);
if (v___x_10393_ == 0)
{
v___y_10371_ = v___y_10384_;
v___y_10372_ = v___y_10385_;
v___y_10373_ = v___y_10386_;
v___y_10374_ = v___y_10387_;
v___y_10375_ = v___x_10393_;
goto v___jp_10370_;
}
else
{
v___y_10377_ = v___y_10384_;
v___y_10378_ = v___y_10385_;
v___y_10379_ = v___y_10386_;
v___y_10380_ = v___y_10388_;
v___y_10381_ = v___y_10387_;
goto v___jp_10376_;
}
}
else
{
v___y_10377_ = v___y_10384_;
v___y_10378_ = v___y_10385_;
v___y_10379_ = v___y_10386_;
v___y_10380_ = v___y_10388_;
v___y_10381_ = v___y_10387_;
goto v___jp_10376_;
}
}
else
{
uint8_t v___x_10394_;
v___x_10394_ = 0;
v___y_10362_ = v___x_10394_;
v___y_10363_ = v___y_10384_;
v___y_10364_ = v___y_10385_;
v___y_10365_ = v___y_10386_;
v___y_10366_ = v___y_10387_;
goto v___jp_10361_;
}
}
}
}
v___jp_10395_:
{
uint8_t v___x_10398_;
v___x_10398_ = lean_uint64_dec_eq(v_leaseBootEpoch_10321_, v_nodeBootEpoch_10322_);
if (v___x_10398_ == 0)
{
uint8_t v___x_10399_; uint32_t v___x_10400_;
v___x_10399_ = 1;
v___x_10400_ = 0;
v___y_10384_ = v___y_10397_;
v___y_10385_ = v___y_10396_;
v___y_10386_ = v___x_10399_;
v___y_10387_ = v___x_10400_;
v___y_10388_ = v___x_10400_;
goto v___jp_10383_;
}
else
{
uint8_t v___x_10401_;
v___x_10401_ = 0;
v___y_10384_ = v___y_10397_;
v___y_10385_ = v___y_10396_;
v___y_10386_ = v___x_10401_;
v___y_10387_ = v_volatileLeaseOwner_10323_;
v___y_10388_ = v_volatileInFlight_10320_;
goto v___jp_10383_;
}
}
v___jp_10402_:
{
uint32_t v___x_10404_;
v___x_10404_ = 0;
v___y_10396_ = v___y_10403_;
v___y_10397_ = v___x_10404_;
goto v___jp_10395_;
}
v___jp_10405_:
{
if (v___y_10406_ == 0)
{
v___y_10403_ = v___y_10406_;
goto v___jp_10402_;
}
else
{
uint32_t v___x_10407_;
v___x_10407_ = lean_uint32_sub(v_durableQueued_10317_, v_durableAcked_10318_);
v___y_10396_ = v___y_10406_;
v___y_10397_ = v___x_10407_;
goto v___jp_10395_;
}
}
}
}

LEAN_EXPORT uint8_t orb_activation_rollback_admit(uint8_t v_currentStatus_10430_, uint8_t v_snapshotStatus_10431_, uint8_t v_hasActiveRun_10432_){
_start:
{
uint8_t v___x_10433_; uint8_t v___x_10434_;
v___x_10433_ = 0;
v___x_10434_ = lean_uint8_dec_eq(v_hasActiveRun_10432_, v___x_10433_);
if (v___x_10434_ == 0)
{
return v___x_10433_;
}
else
{
uint8_t v___x_10435_; uint8_t v___x_10436_;
v___x_10435_ = 10;
v___x_10436_ = lean_uint8_dec_le(v_currentStatus_10430_, v___x_10435_);
if (v___x_10436_ == 0)
{
return v___x_10433_;
}
else
{
uint8_t v___x_10437_;
v___x_10437_ = lean_uint8_dec_le(v_snapshotStatus_10431_, v___x_10435_);
if (v___x_10437_ == 0)
{
return v___x_10433_;
}
else
{
uint8_t v___x_10438_; uint8_t v___x_10439_;
v___x_10438_ = 3;
v___x_10439_ = lean_uint8_dec_eq(v_currentStatus_10430_, v___x_10438_);
if (v___x_10439_ == 0)
{
uint8_t v___x_10440_;
v___x_10440_ = lean_uint8_dec_eq(v_currentStatus_10430_, v___x_10433_);
if (v___x_10440_ == 0)
{
uint8_t v___x_10441_; uint8_t v___x_10442_;
v___x_10441_ = 1;
v___x_10442_ = lean_uint8_dec_eq(v_currentStatus_10430_, v___x_10441_);
if (v___x_10442_ == 0)
{
uint8_t v___x_10443_;
v___x_10443_ = lean_uint8_dec_eq(v_currentStatus_10430_, v_snapshotStatus_10431_);
if (v___x_10443_ == 0)
{
return v___x_10433_;
}
else
{
return v___x_10441_;
}
}
else
{
return v___x_10441_;
}
}
else
{
uint8_t v___x_10444_;
v___x_10444_ = 1;
return v___x_10444_;
}
}
else
{
return v___x_10433_;
}
}
}
}
}
}

LEAN_EXPORT uint32_t orb_remote_replay_step(uint8_t v_op_10453_, uint8_t v_isWaitingRemote_10454_, uint8_t v_waitMatches_10455_, uint8_t v_pastDeadline_10456_, uint8_t v_dispatchOutcome_10457_, uint8_t v_hasRecoveryHandle_10458_, uint8_t v_retryFitsDeadline_10459_, uint32_t v_retries_10460_, uint32_t v_maxRetries_10461_){
_start:
{
uint32_t v___y_10463_; uint8_t v___x_10466_; uint32_t v___y_10468_; uint8_t v___y_10469_; uint8_t v___x_10473_;
v___x_10466_ = 1;
v___x_10473_ = lean_uint8_dec_eq(v_op_10453_, v___x_10466_);
if (v___x_10473_ == 0)
{
uint8_t v___x_10474_; uint8_t v___x_10475_;
v___x_10474_ = 0;
v___x_10475_ = lean_uint8_dec_eq(v_op_10453_, v___x_10474_);
if (v___x_10475_ == 0)
{
uint32_t v___x_10476_;
v___x_10476_ = 0;
return v___x_10476_;
}
else
{
uint8_t v___x_10477_;
v___x_10477_ = lean_uint8_dec_eq(v_waitMatches_10455_, v___x_10466_);
if (v___x_10477_ == 0)
{
uint32_t v___x_10478_;
v___x_10478_ = 0;
return v___x_10478_;
}
else
{
uint8_t v___x_10479_;
v___x_10479_ = lean_uint8_dec_eq(v_isWaitingRemote_10454_, v___x_10466_);
if (v___x_10479_ == 0)
{
uint32_t v___x_10480_;
v___x_10480_ = 257;
return v___x_10480_;
}
else
{
uint8_t v___x_10481_;
v___x_10481_ = lean_uint8_dec_eq(v_pastDeadline_10456_, v___x_10466_);
if (v___x_10481_ == 0)
{
uint8_t v___x_10482_; uint32_t v___y_10484_;
v___x_10482_ = lean_uint8_dec_eq(v_dispatchOutcome_10457_, v___x_10474_);
if (v___x_10482_ == 0)
{
uint8_t v___x_10487_;
v___x_10487_ = lean_uint8_dec_eq(v_hasRecoveryHandle_10458_, v___x_10474_);
if (v___x_10487_ == 0)
{
uint32_t v___x_10488_;
v___x_10488_ = 512;
v___y_10484_ = v___x_10488_;
goto v___jp_10483_;
}
else
{
uint32_t v___x_10489_;
v___x_10489_ = 1536;
v___y_10484_ = v___x_10489_;
goto v___jp_10483_;
}
}
else
{
uint32_t v___x_10490_;
v___x_10490_ = 259;
return v___x_10490_;
}
v___jp_10483_:
{
uint8_t v___x_10485_;
v___x_10485_ = lean_uint8_dec_eq(v_dispatchOutcome_10457_, v___x_10466_);
if (v___x_10485_ == 0)
{
v___y_10468_ = v___y_10484_;
v___y_10469_ = v___x_10482_;
goto v___jp_10467_;
}
else
{
uint8_t v___x_10486_;
v___x_10486_ = lean_uint32_dec_lt(v_retries_10460_, v_maxRetries_10461_);
v___y_10468_ = v___y_10484_;
v___y_10469_ = v___x_10486_;
goto v___jp_10467_;
}
}
}
else
{
uint32_t v___x_10491_;
v___x_10491_ = 258;
return v___x_10491_;
}
}
}
}
}
else
{
uint8_t v___x_10492_;
v___x_10492_ = lean_uint8_dec_eq(v_isWaitingRemote_10454_, v___x_10466_);
if (v___x_10492_ == 0)
{
uint32_t v___x_10493_;
v___x_10493_ = 0;
return v___x_10493_;
}
else
{
uint8_t v___x_10494_;
v___x_10494_ = lean_uint8_dec_eq(v_waitMatches_10455_, v___x_10466_);
if (v___x_10494_ == 0)
{
uint32_t v___x_10495_;
v___x_10495_ = 0;
return v___x_10495_;
}
else
{
uint8_t v___x_10496_; uint8_t v___x_10497_;
v___x_10496_ = 0;
v___x_10497_ = lean_uint8_dec_eq(v_hasRecoveryHandle_10458_, v___x_10496_);
if (v___x_10497_ == 0)
{
uint32_t v___x_10498_;
v___x_10498_ = 0;
return v___x_10498_;
}
else
{
uint8_t v___x_10499_;
v___x_10499_ = lean_uint8_dec_eq(v_pastDeadline_10456_, v___x_10466_);
if (v___x_10499_ == 0)
{
uint32_t v___x_10500_;
v___x_10500_ = 0;
return v___x_10500_;
}
else
{
uint8_t v___x_10501_;
v___x_10501_ = lean_uint8_dec_eq(v_dispatchOutcome_10457_, v___x_10466_);
if (v___x_10501_ == 0)
{
uint32_t v___x_10502_;
v___x_10502_ = 0;
return v___x_10502_;
}
else
{
uint32_t v___x_10503_;
v___x_10503_ = 262;
return v___x_10503_;
}
}
}
}
}
}
v___jp_10462_:
{
uint32_t v___x_10464_; uint32_t v___x_10465_;
v___x_10464_ = 261;
v___x_10465_ = lean_uint32_lor(v___x_10464_, v___y_10463_);
return v___x_10465_;
}
v___jp_10467_:
{
if (v___y_10469_ == 0)
{
v___y_10463_ = v___y_10468_;
goto v___jp_10462_;
}
else
{
uint8_t v___x_10470_;
v___x_10470_ = lean_uint8_dec_eq(v_retryFitsDeadline_10459_, v___x_10466_);
if (v___x_10470_ == 0)
{
v___y_10463_ = v___y_10468_;
goto v___jp_10462_;
}
else
{
uint32_t v___x_10471_; uint32_t v___x_10472_;
v___x_10471_ = 260;
v___x_10472_ = lean_uint32_lor(v___x_10471_, v___y_10468_);
return v___x_10472_;
}
}
}
}
}

LEAN_EXPORT uint8_t orb_memory_tool_gate(uint8_t v_opKind_10524_, uint8_t v_callerRole_10525_, uint8_t v_isExternalSession_10526_, uint8_t v_bunkerState_10527_, uint8_t v_onManagedNode_10528_, uint8_t v_hasProjectMemorySkill_10529_, uint8_t v_hasSecretAccess_10530_, uint8_t v_bankKind_10531_, uint32_t v_requestedLimit_10532_, uint32_t v_maxLimit_10533_, uint32_t v_requestedTokens_10534_, uint32_t v_maxTokens_10535_){
_start:
{
uint8_t v___x_10536_; uint8_t v___y_10538_; uint8_t v___y_10539_; uint8_t v___y_10540_; uint8_t v___y_10541_; uint8_t v___y_10547_; uint8_t v___y_10548_; uint8_t v___y_10549_; uint8_t v___y_10559_; uint8_t v___x_10565_;
v___x_10536_ = 1;
v___x_10565_ = lean_uint8_dec_eq(v_callerRole_10525_, v___x_10536_);
if (v___x_10565_ == 0)
{
uint8_t v___x_10566_; uint8_t v___x_10567_;
v___x_10566_ = 2;
v___x_10567_ = lean_uint8_dec_eq(v_callerRole_10525_, v___x_10566_);
if (v___x_10567_ == 0)
{
uint8_t v___x_10568_; uint8_t v___x_10569_;
v___x_10568_ = 0;
v___x_10569_ = lean_uint8_dec_eq(v_callerRole_10525_, v___x_10568_);
if (v___x_10569_ == 0)
{
v___y_10559_ = v___x_10569_;
goto v___jp_10558_;
}
else
{
uint8_t v___x_10570_;
v___x_10570_ = lean_uint8_dec_eq(v_isExternalSession_10526_, v___x_10568_);
if (v___x_10570_ == 0)
{
goto v___jp_10563_;
}
else
{
uint8_t v___x_10571_;
v___x_10571_ = lean_uint8_dec_eq(v_hasProjectMemorySkill_10529_, v___x_10536_);
if (v___x_10571_ == 0)
{
goto v___jp_10563_;
}
else
{
v___y_10559_ = v___x_10571_;
goto v___jp_10558_;
}
}
}
}
else
{
v___y_10559_ = v___x_10567_;
goto v___jp_10558_;
}
}
else
{
v___y_10559_ = v___x_10565_;
goto v___jp_10558_;
}
v___jp_10537_:
{
uint8_t v___x_10542_; uint8_t v___x_10543_;
v___x_10542_ = 3;
v___x_10543_ = lean_uint8_dec_le(v_opKind_10524_, v___x_10542_);
if (v___x_10543_ == 0)
{
return v___y_10539_;
}
else
{
uint8_t v___x_10544_;
v___x_10544_ = lean_uint8_dec_le(v_bankKind_10531_, v___x_10536_);
if (v___x_10544_ == 0)
{
return v___y_10539_;
}
else
{
uint8_t v___x_10545_;
v___x_10545_ = lean_uint8_dec_eq(v_onManagedNode_10528_, v___y_10539_);
if (v___x_10545_ == 0)
{
return v___y_10539_;
}
else
{
if (v___y_10538_ == 0)
{
return v___y_10539_;
}
else
{
if (v___y_10540_ == 0)
{
return v___y_10539_;
}
else
{
if (v___y_10541_ == 0)
{
return v___y_10539_;
}
else
{
return v___x_10536_;
}
}
}
}
}
}
}
v___jp_10546_:
{
uint32_t v___x_10550_; uint8_t v___x_10551_;
v___x_10550_ = 1;
v___x_10551_ = lean_uint32_dec_le(v___x_10550_, v_maxLimit_10533_);
if (v___x_10551_ == 0)
{
v___y_10538_ = v___y_10549_;
v___y_10539_ = v___y_10547_;
v___y_10540_ = v___y_10548_;
v___y_10541_ = v___x_10551_;
goto v___jp_10537_;
}
else
{
uint8_t v___x_10552_;
v___x_10552_ = lean_uint32_dec_le(v___x_10550_, v_requestedLimit_10532_);
if (v___x_10552_ == 0)
{
v___y_10538_ = v___y_10549_;
v___y_10539_ = v___y_10547_;
v___y_10540_ = v___y_10548_;
v___y_10541_ = v___x_10552_;
goto v___jp_10537_;
}
else
{
uint8_t v___x_10553_;
v___x_10553_ = lean_uint32_dec_le(v_requestedLimit_10532_, v_maxLimit_10533_);
if (v___x_10553_ == 0)
{
v___y_10538_ = v___y_10549_;
v___y_10539_ = v___y_10547_;
v___y_10540_ = v___y_10548_;
v___y_10541_ = v___x_10553_;
goto v___jp_10537_;
}
else
{
uint32_t v___x_10554_; uint8_t v___x_10555_;
v___x_10554_ = 256;
v___x_10555_ = lean_uint32_dec_le(v___x_10554_, v_maxTokens_10535_);
if (v___x_10555_ == 0)
{
v___y_10538_ = v___y_10549_;
v___y_10539_ = v___y_10547_;
v___y_10540_ = v___y_10548_;
v___y_10541_ = v___x_10555_;
goto v___jp_10537_;
}
else
{
uint8_t v___x_10556_;
v___x_10556_ = lean_uint32_dec_le(v___x_10550_, v_requestedTokens_10534_);
if (v___x_10556_ == 0)
{
v___y_10538_ = v___y_10549_;
v___y_10539_ = v___y_10547_;
v___y_10540_ = v___y_10548_;
v___y_10541_ = v___x_10556_;
goto v___jp_10537_;
}
else
{
uint8_t v___x_10557_;
v___x_10557_ = lean_uint32_dec_le(v_requestedTokens_10534_, v_maxTokens_10535_);
v___y_10538_ = v___y_10549_;
v___y_10539_ = v___y_10547_;
v___y_10540_ = v___y_10548_;
v___y_10541_ = v___x_10557_;
goto v___jp_10537_;
}
}
}
}
}
}
v___jp_10558_:
{
uint8_t v___x_10560_; uint8_t v___x_10561_;
v___x_10560_ = 0;
v___x_10561_ = lean_uint8_dec_eq(v_isExternalSession_10526_, v___x_10560_);
if (v___x_10561_ == 0)
{
uint8_t v___x_10562_;
v___x_10562_ = lean_uint8_dec_eq(v_bunkerState_10527_, v___x_10560_);
v___y_10547_ = v___x_10560_;
v___y_10548_ = v___y_10559_;
v___y_10549_ = v___x_10562_;
goto v___jp_10546_;
}
else
{
v___y_10547_ = v___x_10560_;
v___y_10548_ = v___y_10559_;
v___y_10549_ = v___x_10561_;
goto v___jp_10546_;
}
}
v___jp_10563_:
{
uint8_t v___x_10564_;
v___x_10564_ = lean_uint8_dec_eq(v_hasSecretAccess_10530_, v___x_10536_);
v___y_10559_ = v___x_10564_;
goto v___jp_10558_;
}
}
}

LEAN_EXPORT uint8_t orb_upload_cleanup_gate(uint8_t v_hasValidUuid_10598_, uint8_t v_isSharedLibraryArchive_10599_, uint8_t v_isExpiredForGc_10600_){
_start:
{
uint8_t v___x_10601_; uint8_t v___x_10602_;
v___x_10601_ = 1;
v___x_10602_ = lean_uint8_dec_eq(v_hasValidUuid_10598_, v___x_10601_);
if (v___x_10602_ == 0)
{
uint8_t v___x_10603_;
v___x_10603_ = 0;
return v___x_10603_;
}
else
{
uint8_t v___x_10604_; uint8_t v___x_10605_;
v___x_10604_ = 0;
v___x_10605_ = lean_uint8_dec_eq(v_isSharedLibraryArchive_10599_, v___x_10604_);
if (v___x_10605_ == 0)
{
uint8_t v___x_10606_;
v___x_10606_ = lean_uint8_dec_eq(v_isExpiredForGc_10600_, v___x_10601_);
if (v___x_10606_ == 0)
{
return v___x_10604_;
}
else
{
return v___x_10601_;
}
}
else
{
return v___x_10601_;
}
}
}
}

LEAN_EXPORT uint8_t orb_proxy_exhaustion_step(uint32_t v_rateLimitCount_10615_, uint32_t v_paymentRequiredCount_10616_, uint32_t v_clientAuthErrorCount_10617_, uint32_t v_serverErrorCount_10618_, uint32_t v_transportValidationCount_10619_, uint8_t v_hasContextOverflow_10620_){
_start:
{
uint32_t v___x_10621_; uint8_t v___y_10627_; uint8_t v___y_10631_; uint8_t v___y_10632_; uint8_t v___y_10636_; uint8_t v___y_10637_; uint8_t v___y_10640_; uint8_t v___y_10643_; uint8_t v___y_10644_; uint8_t v___y_10647_; uint8_t v___y_10648_; uint8_t v___y_10652_; uint8_t v___y_10655_; uint8_t v___y_10656_; uint8_t v___x_10674_;
v___x_10621_ = 0;
v___x_10674_ = lean_uint32_dec_eq(v_rateLimitCount_10615_, v___x_10621_);
if (v___x_10674_ == 0)
{
goto v___jp_10658_;
}
else
{
uint8_t v___x_10675_;
v___x_10675_ = lean_uint32_dec_eq(v_paymentRequiredCount_10616_, v___x_10621_);
if (v___x_10675_ == 0)
{
goto v___jp_10658_;
}
else
{
uint8_t v___x_10676_;
v___x_10676_ = lean_uint32_dec_eq(v_clientAuthErrorCount_10617_, v___x_10621_);
if (v___x_10676_ == 0)
{
goto v___jp_10658_;
}
else
{
uint8_t v___x_10677_;
v___x_10677_ = lean_uint32_dec_eq(v_serverErrorCount_10618_, v___x_10621_);
if (v___x_10677_ == 0)
{
goto v___jp_10658_;
}
else
{
uint8_t v___x_10678_;
v___x_10678_ = 1;
return v___x_10678_;
}
}
}
}
v___jp_10622_:
{
uint8_t v___x_10623_;
v___x_10623_ = lean_uint32_dec_eq(v_rateLimitCount_10615_, v___x_10621_);
if (v___x_10623_ == 0)
{
uint8_t v___x_10624_;
v___x_10624_ = 7;
return v___x_10624_;
}
else
{
uint8_t v___x_10625_;
v___x_10625_ = 6;
return v___x_10625_;
}
}
v___jp_10626_:
{
uint8_t v___x_10628_;
v___x_10628_ = lean_uint32_dec_eq(v_serverErrorCount_10618_, v___x_10621_);
if (v___x_10628_ == 0)
{
goto v___jp_10622_;
}
else
{
if (v___y_10627_ == 0)
{
uint8_t v___x_10629_;
v___x_10629_ = 7;
return v___x_10629_;
}
else
{
goto v___jp_10622_;
}
}
}
v___jp_10630_:
{
if (v___y_10632_ == 0)
{
v___y_10627_ = v___y_10631_;
goto v___jp_10626_;
}
else
{
uint8_t v___x_10633_;
v___x_10633_ = lean_uint32_dec_eq(v_serverErrorCount_10618_, v___x_10621_);
if (v___x_10633_ == 0)
{
v___y_10627_ = v___x_10633_;
goto v___jp_10626_;
}
else
{
uint8_t v___x_10634_;
v___x_10634_ = 5;
return v___x_10634_;
}
}
}
v___jp_10635_:
{
if (v___y_10637_ == 0)
{
v___y_10631_ = v___y_10636_;
v___y_10632_ = v___y_10636_;
goto v___jp_10630_;
}
else
{
uint8_t v___x_10638_;
v___x_10638_ = lean_uint32_dec_eq(v_rateLimitCount_10615_, v___x_10621_);
v___y_10631_ = v___y_10636_;
v___y_10632_ = v___x_10638_;
goto v___jp_10630_;
}
}
v___jp_10639_:
{
uint8_t v___x_10641_;
v___x_10641_ = lean_uint32_dec_eq(v_paymentRequiredCount_10616_, v___x_10621_);
v___y_10636_ = v___y_10640_;
v___y_10637_ = v___x_10641_;
goto v___jp_10635_;
}
v___jp_10642_:
{
uint8_t v___x_10645_;
v___x_10645_ = lean_uint32_dec_eq(v_clientAuthErrorCount_10617_, v___x_10621_);
if (v___x_10645_ == 0)
{
v___y_10640_ = v___y_10643_;
goto v___jp_10639_;
}
else
{
if (v___y_10644_ == 0)
{
v___y_10636_ = v___y_10643_;
v___y_10637_ = v___y_10643_;
goto v___jp_10635_;
}
else
{
v___y_10640_ = v___y_10643_;
goto v___jp_10639_;
}
}
}
v___jp_10646_:
{
if (v___y_10648_ == 0)
{
v___y_10643_ = v___y_10647_;
v___y_10644_ = v___y_10647_;
goto v___jp_10642_;
}
else
{
uint8_t v___x_10649_;
v___x_10649_ = lean_uint32_dec_eq(v_serverErrorCount_10618_, v___x_10621_);
if (v___x_10649_ == 0)
{
v___y_10643_ = v___y_10647_;
v___y_10644_ = v___x_10649_;
goto v___jp_10642_;
}
else
{
uint8_t v___x_10650_;
v___x_10650_ = 4;
return v___x_10650_;
}
}
}
v___jp_10651_:
{
uint8_t v___x_10653_;
v___x_10653_ = lean_uint32_dec_eq(v_rateLimitCount_10615_, v___x_10621_);
v___y_10647_ = v___y_10652_;
v___y_10648_ = v___x_10653_;
goto v___jp_10646_;
}
v___jp_10654_:
{
uint8_t v___x_10657_;
v___x_10657_ = lean_uint32_dec_eq(v_paymentRequiredCount_10616_, v___x_10621_);
if (v___x_10657_ == 0)
{
v___y_10652_ = v___y_10655_;
goto v___jp_10651_;
}
else
{
if (v___y_10656_ == 0)
{
v___y_10647_ = v___y_10655_;
v___y_10648_ = v___y_10655_;
goto v___jp_10646_;
}
else
{
v___y_10652_ = v___y_10655_;
goto v___jp_10651_;
}
}
}
v___jp_10658_:
{
uint64_t v___x_10659_; uint64_t v___x_10660_; uint64_t v___x_10661_; uint64_t v___x_10662_; uint64_t v___x_10663_; uint64_t v___x_10664_; uint64_t v_attempted_10665_; uint64_t v___x_10666_; uint8_t v___x_10667_;
v___x_10659_ = lean_uint32_to_uint64(v_rateLimitCount_10615_);
v___x_10660_ = lean_uint32_to_uint64(v_paymentRequiredCount_10616_);
v___x_10661_ = lean_uint64_add(v___x_10659_, v___x_10660_);
v___x_10662_ = lean_uint32_to_uint64(v_clientAuthErrorCount_10617_);
v___x_10663_ = lean_uint64_add(v___x_10661_, v___x_10662_);
v___x_10664_ = lean_uint32_to_uint64(v_serverErrorCount_10618_);
v_attempted_10665_ = lean_uint64_add(v___x_10663_, v___x_10664_);
v___x_10666_ = lean_uint32_to_uint64(v_transportValidationCount_10619_);
v___x_10667_ = lean_uint64_dec_eq(v___x_10666_, v_attempted_10665_);
if (v___x_10667_ == 0)
{
uint8_t v___x_10668_; uint8_t v___x_10669_;
v___x_10668_ = 1;
v___x_10669_ = lean_uint8_dec_eq(v_hasContextOverflow_10620_, v___x_10668_);
if (v___x_10669_ == 0)
{
v___y_10655_ = v___x_10667_;
v___y_10656_ = v___x_10667_;
goto v___jp_10654_;
}
else
{
uint8_t v___x_10670_;
v___x_10670_ = lean_uint32_dec_eq(v_rateLimitCount_10615_, v___x_10621_);
if (v___x_10670_ == 0)
{
v___y_10655_ = v___x_10667_;
v___y_10656_ = v___x_10667_;
goto v___jp_10654_;
}
else
{
uint8_t v___x_10671_;
v___x_10671_ = lean_uint32_dec_eq(v_paymentRequiredCount_10616_, v___x_10621_);
if (v___x_10671_ == 0)
{
v___y_10655_ = v___x_10667_;
v___y_10656_ = v___x_10671_;
goto v___jp_10654_;
}
else
{
uint8_t v___x_10672_;
v___x_10672_ = 3;
return v___x_10672_;
}
}
}
}
else
{
uint8_t v___x_10673_;
v___x_10673_ = 2;
return v___x_10673_;
}
}
}
}

LEAN_EXPORT uint8_t orb_composer_default_step(uint8_t v_hasExplicitChoice_10693_, uint8_t v_hasPinnedContext_10694_, uint8_t v_hermesAvailable_10695_, uint8_t v_hasNativeHarness_10696_){
_start:
{
uint8_t v___x_10697_; uint8_t v___x_10702_;
v___x_10697_ = 1;
v___x_10702_ = lean_uint8_dec_eq(v_hasExplicitChoice_10693_, v___x_10697_);
if (v___x_10702_ == 0)
{
uint8_t v___x_10703_; uint8_t v___x_10704_;
v___x_10703_ = 0;
v___x_10704_ = lean_uint8_dec_eq(v_hasPinnedContext_10694_, v___x_10703_);
if (v___x_10704_ == 0)
{
goto v___jp_10698_;
}
else
{
uint8_t v___x_10705_;
v___x_10705_ = lean_uint8_dec_eq(v_hermesAvailable_10695_, v___x_10697_);
if (v___x_10705_ == 0)
{
goto v___jp_10698_;
}
else
{
return v___x_10697_;
}
}
}
else
{
uint8_t v___x_10706_;
v___x_10706_ = 0;
return v___x_10706_;
}
v___jp_10698_:
{
uint8_t v___x_10699_;
v___x_10699_ = lean_uint8_dec_eq(v_hasNativeHarness_10696_, v___x_10697_);
if (v___x_10699_ == 0)
{
uint8_t v___x_10700_;
v___x_10700_ = 3;
return v___x_10700_;
}
else
{
uint8_t v___x_10701_;
v___x_10701_ = 2;
return v___x_10701_;
}
}
}
}

LEAN_EXPORT uint32_t orb_cloud_handoff_step(uint8_t v_sourceIsCloud_10717_, uint8_t v_isSideQuestion_10718_, uint8_t v_targetIsNative_10719_, uint8_t v_hasHistoryTurns_10720_, uint8_t v_targetPlacementValid_10721_){
_start:
{
uint8_t v___x_10722_; uint8_t v___x_10723_;
v___x_10722_ = 1;
v___x_10723_ = lean_uint8_dec_eq(v_targetIsNative_10719_, v___x_10722_);
if (v___x_10723_ == 0)
{
uint32_t v___x_10724_;
v___x_10724_ = 0;
return v___x_10724_;
}
else
{
uint8_t v___x_10725_;
v___x_10725_ = lean_uint8_dec_eq(v_targetPlacementValid_10721_, v___x_10722_);
if (v___x_10725_ == 0)
{
uint32_t v___x_10726_;
v___x_10726_ = 0;
return v___x_10726_;
}
else
{
uint8_t v___x_10727_;
v___x_10727_ = lean_uint8_dec_eq(v_sourceIsCloud_10717_, v___x_10722_);
if (v___x_10727_ == 0)
{
uint32_t v___x_10728_;
v___x_10728_ = 65537;
return v___x_10728_;
}
else
{
uint8_t v___x_10729_; uint8_t v___x_10730_;
v___x_10729_ = 0;
v___x_10730_ = lean_uint8_dec_eq(v_isSideQuestion_10718_, v___x_10729_);
if (v___x_10730_ == 0)
{
uint32_t v___x_10731_;
v___x_10731_ = 0;
return v___x_10731_;
}
else
{
uint8_t v___x_10732_;
v___x_10732_ = lean_uint8_dec_eq(v_hasHistoryTurns_10720_, v___x_10722_);
if (v___x_10732_ == 0)
{
uint32_t v___x_10733_;
v___x_10733_ = 0;
return v___x_10733_;
}
else
{
uint32_t v___x_10734_;
v___x_10734_ = 16777473;
return v___x_10734_;
}
}
}
}
}
}
}

LEAN_EXPORT uint64_t orb_fast_poll_delay_ms(uint8_t v_isStopping_10747_, uint64_t v_elapsedMs_10748_, uint32_t v_consecutiveFailures_10749_){
_start:
{
uint32_t v___x_10750_; uint8_t v___x_10751_;
v___x_10750_ = 4;
v___x_10751_ = lean_uint32_dec_le(v___x_10750_, v_consecutiveFailures_10749_);
if (v___x_10751_ == 0)
{
uint32_t v___x_10752_; uint8_t v___x_10753_;
v___x_10752_ = 3;
v___x_10753_ = lean_uint32_dec_eq(v_consecutiveFailures_10749_, v___x_10752_);
if (v___x_10753_ == 0)
{
uint32_t v___x_10754_; uint8_t v___x_10755_;
v___x_10754_ = 2;
v___x_10755_ = lean_uint32_dec_eq(v_consecutiveFailures_10749_, v___x_10754_);
if (v___x_10755_ == 0)
{
uint32_t v___x_10756_; uint8_t v___x_10757_;
v___x_10756_ = 1;
v___x_10757_ = lean_uint32_dec_eq(v_consecutiveFailures_10749_, v___x_10756_);
if (v___x_10757_ == 0)
{
uint8_t v___x_10758_; uint8_t v___x_10759_;
v___x_10758_ = 1;
v___x_10759_ = lean_uint8_dec_eq(v_isStopping_10747_, v___x_10758_);
if (v___x_10759_ == 0)
{
uint64_t v___x_10760_; uint8_t v___x_10761_;
v___x_10760_ = 4000ULL;
v___x_10761_ = lean_uint64_dec_lt(v_elapsedMs_10748_, v___x_10760_);
if (v___x_10761_ == 0)
{
uint64_t v___x_10762_; uint8_t v___x_10763_;
v___x_10762_ = 15000ULL;
v___x_10763_ = lean_uint64_dec_lt(v_elapsedMs_10748_, v___x_10762_);
if (v___x_10763_ == 0)
{
uint64_t v___x_10764_;
v___x_10764_ = 500ULL;
return v___x_10764_;
}
else
{
uint64_t v___x_10765_;
v___x_10765_ = 200ULL;
return v___x_10765_;
}
}
else
{
uint64_t v___x_10766_;
v___x_10766_ = 80ULL;
return v___x_10766_;
}
}
else
{
uint64_t v___x_10767_;
v___x_10767_ = 500ULL;
return v___x_10767_;
}
}
else
{
uint64_t v___x_10768_;
v___x_10768_ = 1000ULL;
return v___x_10768_;
}
}
else
{
uint64_t v___x_10769_;
v___x_10769_ = 2000ULL;
return v___x_10769_;
}
}
else
{
uint64_t v___x_10770_;
v___x_10770_ = 4000ULL;
return v___x_10770_;
}
}
else
{
uint64_t v___x_10771_;
v___x_10771_ = 5000ULL;
return v___x_10771_;
}
}
}

LEAN_EXPORT uint8_t orb_mcp_preflight_cache_gate(uint8_t v_hasCached_10780_, uint8_t v_identityMatches_10781_, uint8_t v_contractMatches_10782_, uint8_t v_sessionUnexpired_10783_, uint64_t v_ageSecs_10784_, uint64_t v_maxTtlSecs_10785_){
_start:
{
uint8_t v___x_10786_; uint8_t v___x_10787_;
v___x_10786_ = 1;
v___x_10787_ = lean_uint8_dec_eq(v_hasCached_10780_, v___x_10786_);
if (v___x_10787_ == 0)
{
uint8_t v___x_10788_;
v___x_10788_ = 0;
return v___x_10788_;
}
else
{
uint8_t v___x_10789_;
v___x_10789_ = lean_uint8_dec_eq(v_identityMatches_10781_, v___x_10786_);
if (v___x_10789_ == 0)
{
uint8_t v___x_10790_;
v___x_10790_ = 0;
return v___x_10790_;
}
else
{
uint8_t v___x_10791_;
v___x_10791_ = lean_uint8_dec_eq(v_contractMatches_10782_, v___x_10786_);
if (v___x_10791_ == 0)
{
uint8_t v___x_10792_;
v___x_10792_ = 0;
return v___x_10792_;
}
else
{
uint8_t v___x_10793_;
v___x_10793_ = lean_uint8_dec_eq(v_sessionUnexpired_10783_, v___x_10786_);
if (v___x_10793_ == 0)
{
uint8_t v___x_10794_;
v___x_10794_ = 0;
return v___x_10794_;
}
else
{
uint64_t v___x_10795_; uint8_t v___x_10796_;
v___x_10795_ = 1ULL;
v___x_10796_ = lean_uint64_dec_le(v___x_10795_, v_maxTtlSecs_10785_);
if (v___x_10796_ == 0)
{
uint8_t v___x_10797_;
v___x_10797_ = 0;
return v___x_10797_;
}
else
{
uint64_t v___x_10798_; uint8_t v___x_10799_;
v___x_10798_ = 300ULL;
v___x_10799_ = lean_uint64_dec_le(v_maxTtlSecs_10785_, v___x_10798_);
if (v___x_10799_ == 0)
{
uint8_t v___x_10800_;
v___x_10800_ = 0;
return v___x_10800_;
}
else
{
uint8_t v___x_10801_;
v___x_10801_ = lean_uint64_dec_le(v_ageSecs_10784_, v_maxTtlSecs_10785_);
if (v___x_10801_ == 0)
{
uint8_t v___x_10802_;
v___x_10802_ = 0;
return v___x_10802_;
}
else
{
return v___x_10786_;
}
}
}
}
}
}
}
}
}

LEAN_EXPORT uint32_t orb_codex_goal_launch_step(uint8_t v_isGoalRequest_10817_, uint8_t v_hasNonEmptyObjective_10818_, uint8_t v_hasImages_10819_, uint8_t v_hasExplicitCyber_10820_, uint8_t v_hasChatGptAuth_10821_, uint8_t v_modelCompatible_10822_, uint8_t v_accountSupportsProgram_10823_, uint8_t v_resumedGoalActive_10824_, uint8_t v_hasRetiredAlias_10825_){
_start:
{
uint32_t v___y_10827_; uint8_t v___x_10830_; uint32_t v___y_10832_; uint8_t v___y_10833_; uint8_t v___y_10840_; uint32_t v___y_10841_; uint8_t v___y_10842_; uint8_t v___y_10843_; uint8_t v___y_10850_; uint8_t v___y_10851_; uint32_t v___y_10852_; uint8_t v___y_10859_; uint8_t v___y_10860_; uint8_t v___x_10862_;
v___x_10830_ = 0;
v___x_10862_ = lean_uint8_dec_eq(v_isGoalRequest_10817_, v___x_10830_);
if (v___x_10862_ == 0)
{
uint8_t v___x_10863_;
v___x_10863_ = 1;
v___y_10859_ = v___x_10863_;
v___y_10860_ = v___x_10863_;
goto v___jp_10858_;
}
else
{
uint8_t v___x_10864_; uint8_t v___x_10865_;
v___x_10864_ = 0;
v___x_10865_ = lean_uint8_dec_eq(v_resumedGoalActive_10824_, v___x_10830_);
if (v___x_10865_ == 0)
{
v___y_10859_ = v___x_10864_;
v___y_10860_ = v___x_10862_;
goto v___jp_10858_;
}
else
{
uint32_t v___x_10866_;
v___x_10866_ = 0;
v___y_10850_ = v___x_10864_;
v___y_10851_ = v___x_10864_;
v___y_10852_ = v___x_10866_;
goto v___jp_10849_;
}
}
v___jp_10826_:
{
uint32_t v___x_10828_; uint32_t v___x_10829_;
v___x_10828_ = 256;
v___x_10829_ = lean_uint32_lor(v___x_10828_, v___y_10827_);
return v___x_10829_;
}
v___jp_10831_:
{
if (v___y_10833_ == 0)
{
v___y_10827_ = v___y_10832_;
goto v___jp_10826_;
}
else
{
uint8_t v___x_10834_;
v___x_10834_ = lean_uint8_dec_eq(v_hasNonEmptyObjective_10818_, v___x_10830_);
if (v___x_10834_ == 0)
{
uint8_t v___x_10835_;
v___x_10835_ = lean_uint8_dec_eq(v_hasImages_10819_, v___x_10830_);
if (v___x_10835_ == 0)
{
uint32_t v___x_10836_;
v___x_10836_ = 7;
return v___x_10836_;
}
else
{
if (v___x_10834_ == 0)
{
v___y_10827_ = v___y_10832_;
goto v___jp_10826_;
}
else
{
uint32_t v___x_10837_;
v___x_10837_ = 7;
return v___x_10837_;
}
}
}
else
{
uint32_t v___x_10838_;
v___x_10838_ = 6;
return v___x_10838_;
}
}
}
v___jp_10839_:
{
if (v___y_10843_ == 0)
{
v___y_10832_ = v___y_10841_;
v___y_10833_ = v___y_10842_;
goto v___jp_10831_;
}
else
{
uint8_t v___x_10844_;
v___x_10844_ = lean_uint8_dec_eq(v_hasChatGptAuth_10821_, v___x_10830_);
if (v___x_10844_ == 0)
{
uint8_t v___x_10845_;
v___x_10845_ = lean_uint8_dec_eq(v_accountSupportsProgram_10823_, v___x_10830_);
if (v___x_10845_ == 0)
{
if (v___y_10840_ == 0)
{
v___y_10832_ = v___y_10841_;
v___y_10833_ = v___y_10842_;
goto v___jp_10831_;
}
else
{
uint32_t v___x_10846_;
v___x_10846_ = 5;
return v___x_10846_;
}
}
else
{
uint32_t v___x_10847_;
v___x_10847_ = 4;
return v___x_10847_;
}
}
else
{
uint32_t v___x_10848_;
v___x_10848_ = 3;
return v___x_10848_;
}
}
}
v___jp_10849_:
{
uint8_t v___x_10853_;
v___x_10853_ = lean_uint8_dec_eq(v_hasRetiredAlias_10825_, v___x_10830_);
if (v___x_10853_ == 0)
{
uint32_t v___x_10854_;
v___x_10854_ = 1;
return v___x_10854_;
}
else
{
uint8_t v___x_10855_;
v___x_10855_ = lean_uint8_dec_eq(v_modelCompatible_10822_, v___x_10830_);
if (v___x_10855_ == 0)
{
uint8_t v___x_10856_;
v___x_10856_ = lean_uint8_dec_eq(v_hasExplicitCyber_10820_, v___x_10830_);
if (v___x_10856_ == 0)
{
v___y_10840_ = v___y_10850_;
v___y_10841_ = v___y_10852_;
v___y_10842_ = v___y_10851_;
v___y_10843_ = v___x_10853_;
goto v___jp_10839_;
}
else
{
v___y_10840_ = v___y_10850_;
v___y_10841_ = v___y_10852_;
v___y_10842_ = v___y_10851_;
v___y_10843_ = v___x_10855_;
goto v___jp_10839_;
}
}
else
{
uint32_t v___x_10857_;
v___x_10857_ = 2;
return v___x_10857_;
}
}
}
v___jp_10858_:
{
uint32_t v___x_10861_;
v___x_10861_ = 512;
v___y_10850_ = v___y_10860_;
v___y_10851_ = v___y_10859_;
v___y_10852_ = v___x_10861_;
goto v___jp_10849_;
}
}
}

LEAN_EXPORT uint8_t orb_codex_goal_preact_filter(uint8_t v_msgKind_10887_, uint8_t v_isRequest_10888_, uint8_t v_sameThread_10889_, uint8_t v_hasTurnId_10890_, uint8_t v_threadAlreadyActive_10891_, uint8_t v_goalGetWasNull_10892_, uint8_t v_snapshotMatchesGoalGet_10893_){
_start:
{
uint8_t v___x_10894_; uint8_t v___y_10896_; uint8_t v___x_10900_;
v___x_10894_ = 0;
v___x_10900_ = lean_uint8_dec_eq(v_isRequest_10888_, v___x_10894_);
if (v___x_10900_ == 0)
{
return v___x_10894_;
}
else
{
uint8_t v___x_10901_;
v___x_10901_ = lean_uint8_dec_eq(v_sameThread_10889_, v___x_10894_);
if (v___x_10901_ == 0)
{
uint8_t v___x_10902_;
v___x_10902_ = lean_uint8_dec_eq(v_hasTurnId_10890_, v___x_10894_);
if (v___x_10902_ == 0)
{
return v___x_10894_;
}
else
{
uint8_t v___x_10903_;
v___x_10903_ = lean_uint8_dec_eq(v_threadAlreadyActive_10891_, v___x_10894_);
if (v___x_10903_ == 0)
{
return v___x_10894_;
}
else
{
uint8_t v___x_10904_; uint8_t v___x_10905_;
v___x_10904_ = 2;
v___x_10905_ = lean_uint8_dec_eq(v_msgKind_10887_, v___x_10904_);
if (v___x_10905_ == 0)
{
v___y_10896_ = v___x_10901_;
goto v___jp_10895_;
}
else
{
uint8_t v___x_10906_;
v___x_10906_ = lean_uint8_dec_eq(v_goalGetWasNull_10892_, v___x_10894_);
if (v___x_10906_ == 0)
{
uint8_t v___x_10907_;
v___x_10907_ = 1;
return v___x_10907_;
}
else
{
v___y_10896_ = v___x_10901_;
goto v___jp_10895_;
}
}
}
}
}
else
{
return v___x_10894_;
}
}
v___jp_10895_:
{
uint8_t v___x_10897_; uint8_t v___x_10898_;
v___x_10897_ = 1;
v___x_10898_ = lean_uint8_dec_eq(v_msgKind_10887_, v___x_10897_);
if (v___x_10898_ == 0)
{
return v___x_10894_;
}
else
{
uint8_t v___x_10899_;
v___x_10899_ = lean_uint8_dec_eq(v_snapshotMatchesGoalGet_10893_, v___x_10894_);
if (v___x_10899_ == 0)
{
return v___x_10897_;
}
else
{
if (v___y_10896_ == 0)
{
return v___x_10894_;
}
else
{
return v___x_10897_;
}
}
}
}
}
}

LEAN_EXPORT uint64_t orb_skill_slash_step(uint8_t v_harnessKind_10924_, uint8_t v_isDelivered_10925_, uint8_t v_alreadySelected_10926_, uint8_t v_nameCharsValid_10927_, uint32_t v_nameLen_10928_, uint32_t v_maxNameLen_10929_, uint32_t v_selectedCount_10930_, uint32_t v_maxSelected_10931_){
_start:
{
uint32_t v___y_10945_; uint32_t v___x_10959_; uint8_t v___x_10960_;
v___x_10959_ = 0;
v___x_10960_ = lean_uint32_dec_eq(v_nameLen_10928_, v___x_10959_);
if (v___x_10960_ == 0)
{
uint8_t v___x_10961_;
v___x_10961_ = lean_uint32_dec_eq(v_maxNameLen_10929_, v___x_10959_);
if (v___x_10961_ == 0)
{
uint8_t v___x_10962_;
v___x_10962_ = lean_uint32_dec_lt(v_maxNameLen_10929_, v_nameLen_10928_);
if (v___x_10962_ == 0)
{
uint8_t v___x_10963_; uint8_t v___x_10964_;
v___x_10963_ = 0;
v___x_10964_ = lean_uint8_dec_eq(v_nameCharsValid_10927_, v___x_10963_);
if (v___x_10964_ == 0)
{
uint8_t v___x_10965_;
v___x_10965_ = lean_uint8_dec_eq(v_isDelivered_10925_, v___x_10963_);
if (v___x_10965_ == 0)
{
uint8_t v___x_10966_;
v___x_10966_ = lean_uint8_dec_eq(v_alreadySelected_10926_, v___x_10963_);
if (v___x_10966_ == 0)
{
uint64_t v___x_10967_; uint64_t v___x_10968_; uint64_t v___x_10969_; uint64_t v___x_10970_; uint64_t v___x_10971_;
v___x_10967_ = 4ULL;
v___x_10968_ = lean_uint32_to_uint64(v_selectedCount_10930_);
v___x_10969_ = 32ULL;
v___x_10970_ = lean_uint64_shift_left(v___x_10968_, v___x_10969_);
v___x_10971_ = lean_uint64_lor(v___x_10967_, v___x_10970_);
return v___x_10971_;
}
else
{
uint8_t v___x_10972_;
v___x_10972_ = lean_uint32_dec_eq(v_maxSelected_10931_, v___x_10959_);
if (v___x_10972_ == 0)
{
uint8_t v___x_10973_;
v___x_10973_ = lean_uint32_dec_le(v_maxSelected_10931_, v_selectedCount_10930_);
if (v___x_10973_ == 0)
{
uint8_t v___x_10974_; uint8_t v___x_10975_;
v___x_10974_ = 1;
v___x_10975_ = lean_uint8_dec_eq(v_harnessKind_10924_, v___x_10974_);
if (v___x_10975_ == 0)
{
uint8_t v___x_10976_; uint8_t v___x_10977_;
v___x_10976_ = 2;
v___x_10977_ = lean_uint8_dec_eq(v_harnessKind_10924_, v___x_10976_);
if (v___x_10977_ == 0)
{
uint32_t v___x_10978_;
v___x_10978_ = 2;
v___y_10945_ = v___x_10978_;
goto v___jp_10944_;
}
else
{
goto v___jp_10957_;
}
}
else
{
goto v___jp_10957_;
}
}
else
{
goto v___jp_10938_;
}
}
else
{
goto v___jp_10938_;
}
}
}
else
{
uint64_t v___x_10979_; uint64_t v___x_10980_; uint64_t v___x_10981_; uint64_t v___x_10982_; uint64_t v___x_10983_;
v___x_10979_ = 3ULL;
v___x_10980_ = lean_uint32_to_uint64(v_selectedCount_10930_);
v___x_10981_ = 32ULL;
v___x_10982_ = lean_uint64_shift_left(v___x_10980_, v___x_10981_);
v___x_10983_ = lean_uint64_lor(v___x_10979_, v___x_10982_);
return v___x_10983_;
}
}
else
{
uint64_t v___x_10984_; uint64_t v___x_10985_; uint64_t v___x_10986_; uint64_t v___x_10987_; uint64_t v___x_10988_;
v___x_10984_ = 2ULL;
v___x_10985_ = lean_uint32_to_uint64(v_selectedCount_10930_);
v___x_10986_ = 32ULL;
v___x_10987_ = lean_uint64_shift_left(v___x_10985_, v___x_10986_);
v___x_10988_ = lean_uint64_lor(v___x_10984_, v___x_10987_);
return v___x_10988_;
}
}
else
{
goto v___jp_10932_;
}
}
else
{
goto v___jp_10932_;
}
}
else
{
goto v___jp_10932_;
}
v___jp_10932_:
{
uint64_t v___x_10933_; uint64_t v___x_10934_; uint64_t v___x_10935_; uint64_t v___x_10936_; uint64_t v___x_10937_;
v___x_10933_ = 1ULL;
v___x_10934_ = lean_uint32_to_uint64(v_selectedCount_10930_);
v___x_10935_ = 32ULL;
v___x_10936_ = lean_uint64_shift_left(v___x_10934_, v___x_10935_);
v___x_10937_ = lean_uint64_lor(v___x_10933_, v___x_10936_);
return v___x_10937_;
}
v___jp_10938_:
{
uint64_t v___x_10939_; uint64_t v___x_10940_; uint64_t v___x_10941_; uint64_t v___x_10942_; uint64_t v___x_10943_;
v___x_10939_ = 5ULL;
v___x_10940_ = lean_uint32_to_uint64(v_selectedCount_10930_);
v___x_10941_ = 32ULL;
v___x_10942_ = lean_uint64_shift_left(v___x_10940_, v___x_10941_);
v___x_10943_ = lean_uint64_lor(v___x_10939_, v___x_10942_);
return v___x_10943_;
}
v___jp_10944_:
{
uint32_t v___x_10946_; uint32_t v_nextCount_10947_; uint32_t v___x_10948_; uint32_t v___x_10949_; uint32_t v___x_10950_; uint32_t v_lo32_10951_; uint64_t v___x_10952_; uint64_t v___x_10953_; uint64_t v___x_10954_; uint64_t v___x_10955_; uint64_t v___x_10956_;
v___x_10946_ = 1;
v_nextCount_10947_ = lean_uint32_add(v_selectedCount_10930_, v___x_10946_);
v___x_10948_ = 256;
v___x_10949_ = 16;
v___x_10950_ = lean_uint32_shift_left(v___y_10945_, v___x_10949_);
v_lo32_10951_ = lean_uint32_lor(v___x_10948_, v___x_10950_);
v___x_10952_ = lean_uint32_to_uint64(v_lo32_10951_);
v___x_10953_ = lean_uint32_to_uint64(v_nextCount_10947_);
v___x_10954_ = 32ULL;
v___x_10955_ = lean_uint64_shift_left(v___x_10953_, v___x_10954_);
v___x_10956_ = lean_uint64_lor(v___x_10952_, v___x_10955_);
return v___x_10956_;
}
v___jp_10957_:
{
uint32_t v___x_10958_;
v___x_10958_ = 1;
v___y_10945_ = v___x_10958_;
goto v___jp_10944_;
}
}
}

LEAN_EXPORT uint32_t orb_worktree_decision_step(uint8_t v_opKind_11007_, uint8_t v_isOccupied_11008_, uint8_t v_isGitRepo_11009_, uint8_t v_branchCharsValid_11010_, uint8_t v_targetPathExists_11011_, uint8_t v_parentDirValid_11012_, uint32_t v_slugLen_11013_, uint32_t v_maxSlugLen_11014_, uint32_t v_activeWorktrees_11015_, uint32_t v_maxWorktrees_11016_){
_start:
{
uint8_t v___x_11017_; uint8_t v___x_11018_;
v___x_11017_ = 0;
v___x_11018_ = lean_uint8_dec_eq(v_opKind_11007_, v___x_11017_);
if (v___x_11018_ == 0)
{
uint8_t v___x_11019_; uint8_t v___x_11020_;
v___x_11019_ = 1;
v___x_11020_ = lean_uint8_dec_eq(v_opKind_11007_, v___x_11019_);
if (v___x_11020_ == 0)
{
uint32_t v___x_11021_;
v___x_11021_ = 7;
return v___x_11021_;
}
else
{
uint8_t v___x_11022_;
v___x_11022_ = lean_uint8_dec_eq(v_isGitRepo_11009_, v___x_11017_);
if (v___x_11022_ == 0)
{
uint8_t v___x_11023_;
v___x_11023_ = lean_uint8_dec_eq(v_parentDirValid_11012_, v___x_11017_);
if (v___x_11023_ == 0)
{
uint8_t v___x_11024_;
v___x_11024_ = lean_uint8_dec_eq(v_branchCharsValid_11010_, v___x_11017_);
if (v___x_11024_ == 0)
{
uint32_t v___x_11025_; uint8_t v___x_11026_;
v___x_11025_ = 0;
v___x_11026_ = lean_uint32_dec_eq(v_slugLen_11013_, v___x_11025_);
if (v___x_11026_ == 0)
{
uint8_t v___x_11027_;
v___x_11027_ = lean_uint32_dec_eq(v_maxSlugLen_11014_, v___x_11025_);
if (v___x_11027_ == 0)
{
uint8_t v___x_11028_;
v___x_11028_ = lean_uint32_dec_lt(v_maxSlugLen_11014_, v_slugLen_11013_);
if (v___x_11028_ == 0)
{
uint8_t v___x_11029_;
v___x_11029_ = lean_uint8_dec_eq(v_targetPathExists_11011_, v___x_11017_);
if (v___x_11029_ == 0)
{
uint32_t v___x_11030_;
v___x_11030_ = 5;
return v___x_11030_;
}
else
{
uint8_t v___x_11031_;
v___x_11031_ = lean_uint32_dec_eq(v_maxWorktrees_11016_, v___x_11025_);
if (v___x_11031_ == 0)
{
uint8_t v___x_11032_;
v___x_11032_ = lean_uint32_dec_le(v_maxWorktrees_11016_, v_activeWorktrees_11015_);
if (v___x_11032_ == 0)
{
uint32_t v___x_11033_;
v___x_11033_ = 257;
return v___x_11033_;
}
else
{
uint32_t v___x_11034_;
v___x_11034_ = 6;
return v___x_11034_;
}
}
else
{
uint32_t v___x_11035_;
v___x_11035_ = 6;
return v___x_11035_;
}
}
}
else
{
uint32_t v___x_11036_;
v___x_11036_ = 4;
return v___x_11036_;
}
}
else
{
uint32_t v___x_11037_;
v___x_11037_ = 4;
return v___x_11037_;
}
}
else
{
uint32_t v___x_11038_;
v___x_11038_ = 4;
return v___x_11038_;
}
}
else
{
uint32_t v___x_11039_;
v___x_11039_ = 4;
return v___x_11039_;
}
}
else
{
uint32_t v___x_11040_;
v___x_11040_ = 3;
return v___x_11040_;
}
}
else
{
uint32_t v___x_11041_;
v___x_11041_ = 2;
return v___x_11041_;
}
}
}
else
{
uint8_t v___x_11042_;
v___x_11042_ = lean_uint8_dec_eq(v_isOccupied_11008_, v___x_11017_);
if (v___x_11042_ == 0)
{
uint8_t v___x_11043_;
v___x_11043_ = lean_uint8_dec_eq(v_isGitRepo_11009_, v___x_11017_);
if (v___x_11043_ == 0)
{
uint8_t v___x_11044_;
v___x_11044_ = lean_uint8_dec_eq(v_parentDirValid_11012_, v___x_11017_);
if (v___x_11044_ == 0)
{
uint32_t v___x_11045_;
v___x_11045_ = 513;
return v___x_11045_;
}
else
{
uint32_t v___x_11046_;
v___x_11046_ = 1;
return v___x_11046_;
}
}
else
{
uint32_t v___x_11047_;
v___x_11047_ = 1;
return v___x_11047_;
}
}
else
{
uint32_t v___x_11048_;
v___x_11048_ = 256;
return v___x_11048_;
}
}
}
}

LEAN_EXPORT uint64_t orb_repo_diff_budget_step(uint8_t v_isGitRepo_11071_, uint8_t v_pathSafe_11072_, uint8_t v_hasUntracked_11073_, uint32_t v_modifiedCount_11074_, uint32_t v_stagedCount_11075_, uint32_t v_aheadCount_11076_, uint32_t v_behindCount_11077_, uint32_t v_diffBytes_11078_, uint32_t v_maxFiles_11079_, uint32_t v_maxBytes_11080_){
_start:
{
uint32_t v___y_11082_; uint32_t v___y_11083_; uint32_t v___y_11084_; uint32_t v___y_11085_; uint32_t v___y_11086_; uint32_t v___y_11100_; uint32_t v___y_11101_; uint32_t v___y_11102_; uint32_t v___y_11103_; uint8_t v___x_11105_; uint8_t v___x_11106_;
v___x_11105_ = 0;
v___x_11106_ = lean_uint8_dec_eq(v_isGitRepo_11071_, v___x_11105_);
if (v___x_11106_ == 0)
{
uint8_t v___x_11107_;
v___x_11107_ = lean_uint8_dec_eq(v_pathSafe_11072_, v___x_11105_);
if (v___x_11107_ == 0)
{
uint32_t v___x_11108_; uint32_t v___y_11110_; uint32_t v___y_11111_; uint8_t v___y_11112_; uint32_t v___y_11113_; uint32_t v___y_11118_; uint32_t v___y_11119_; uint32_t v___y_11120_; uint32_t v___y_11125_; uint32_t v___y_11126_; uint64_t v___y_11130_; uint32_t v___y_11131_; uint8_t v___x_11135_;
v___x_11108_ = 0;
v___x_11135_ = lean_uint32_dec_eq(v_maxFiles_11079_, v___x_11108_);
if (v___x_11135_ == 0)
{
uint8_t v___x_11136_;
v___x_11136_ = lean_uint32_dec_eq(v_maxBytes_11080_, v___x_11108_);
if (v___x_11136_ == 0)
{
uint64_t v___x_11137_; uint64_t v___x_11138_; uint64_t v___x_11139_; uint64_t v___y_11141_; uint8_t v___x_11146_;
v___x_11137_ = lean_uint32_to_uint64(v_modifiedCount_11074_);
v___x_11138_ = lean_uint32_to_uint64(v_stagedCount_11075_);
v___x_11139_ = lean_uint64_add(v___x_11137_, v___x_11138_);
v___x_11146_ = lean_uint8_dec_eq(v_hasUntracked_11073_, v___x_11105_);
if (v___x_11146_ == 0)
{
uint64_t v___x_11147_;
v___x_11147_ = 1ULL;
v___y_11141_ = v___x_11147_;
goto v___jp_11140_;
}
else
{
uint64_t v___x_11148_;
v___x_11148_ = 0ULL;
v___y_11141_ = v___x_11148_;
goto v___jp_11140_;
}
v___jp_11140_:
{
uint64_t v_totalChanges64_11142_; uint64_t v___x_11143_; uint8_t v___x_11144_;
v_totalChanges64_11142_ = lean_uint64_add(v___x_11139_, v___y_11141_);
v___x_11143_ = 0ULL;
v___x_11144_ = lean_uint64_dec_lt(v___x_11143_, v_totalChanges64_11142_);
if (v___x_11144_ == 0)
{
v___y_11130_ = v_totalChanges64_11142_;
v___y_11131_ = v___x_11108_;
goto v___jp_11129_;
}
else
{
uint32_t v___x_11145_;
v___x_11145_ = 512;
v___y_11130_ = v_totalChanges64_11142_;
v___y_11131_ = v___x_11145_;
goto v___jp_11129_;
}
}
}
else
{
uint64_t v___x_11149_;
v___x_11149_ = 3ULL;
return v___x_11149_;
}
}
else
{
uint64_t v___x_11150_;
v___x_11150_ = 3ULL;
return v___x_11150_;
}
v___jp_11109_:
{
if (v___y_11112_ == 0)
{
uint8_t v___x_11114_;
v___x_11114_ = lean_uint32_dec_lt(v___x_11108_, v_behindCount_11077_);
if (v___x_11114_ == 0)
{
v___y_11100_ = v___y_11110_;
v___y_11101_ = v___y_11111_;
v___y_11102_ = v___y_11113_;
v___y_11103_ = v___x_11108_;
goto v___jp_11099_;
}
else
{
uint32_t v___x_11115_;
v___x_11115_ = 2;
v___y_11100_ = v___y_11110_;
v___y_11101_ = v___y_11111_;
v___y_11102_ = v___y_11113_;
v___y_11103_ = v___x_11115_;
goto v___jp_11099_;
}
}
else
{
uint32_t v___x_11116_;
v___x_11116_ = 1;
v___y_11100_ = v___y_11110_;
v___y_11101_ = v___y_11111_;
v___y_11102_ = v___y_11113_;
v___y_11103_ = v___x_11116_;
goto v___jp_11099_;
}
}
v___jp_11117_:
{
uint8_t v___x_11121_;
v___x_11121_ = lean_uint32_dec_lt(v___x_11108_, v_aheadCount_11076_);
if (v___x_11121_ == 0)
{
v___y_11110_ = v___y_11118_;
v___y_11111_ = v___y_11120_;
v___y_11112_ = v___x_11121_;
v___y_11113_ = v___y_11119_;
goto v___jp_11109_;
}
else
{
uint8_t v___x_11122_;
v___x_11122_ = lean_uint32_dec_lt(v___x_11108_, v_behindCount_11077_);
if (v___x_11122_ == 0)
{
v___y_11110_ = v___y_11118_;
v___y_11111_ = v___y_11120_;
v___y_11112_ = v___x_11121_;
v___y_11113_ = v___y_11119_;
goto v___jp_11109_;
}
else
{
uint32_t v___x_11123_;
v___x_11123_ = 3;
v___y_11100_ = v___y_11118_;
v___y_11101_ = v___y_11120_;
v___y_11102_ = v___y_11119_;
v___y_11103_ = v___x_11123_;
goto v___jp_11099_;
}
}
}
v___jp_11124_:
{
uint8_t v___x_11127_;
v___x_11127_ = lean_uint32_dec_lt(v_maxBytes_11080_, v_diffBytes_11078_);
if (v___x_11127_ == 0)
{
v___y_11118_ = v___y_11126_;
v___y_11119_ = v___y_11125_;
v___y_11120_ = v___x_11108_;
goto v___jp_11117_;
}
else
{
uint32_t v___x_11128_;
v___x_11128_ = 2048;
v___y_11118_ = v___y_11126_;
v___y_11119_ = v___y_11125_;
v___y_11120_ = v___x_11128_;
goto v___jp_11117_;
}
}
v___jp_11129_:
{
uint64_t v___x_11132_; uint8_t v___x_11133_;
v___x_11132_ = lean_uint32_to_uint64(v_maxFiles_11079_);
v___x_11133_ = lean_uint64_dec_lt(v___x_11132_, v___y_11130_);
if (v___x_11133_ == 0)
{
v___y_11125_ = v___y_11131_;
v___y_11126_ = v___x_11108_;
goto v___jp_11124_;
}
else
{
uint32_t v___x_11134_;
v___x_11134_ = 1024;
v___y_11125_ = v___y_11131_;
v___y_11126_ = v___x_11134_;
goto v___jp_11124_;
}
}
}
else
{
uint64_t v___x_11151_;
v___x_11151_ = 2ULL;
return v___x_11151_;
}
}
else
{
uint64_t v___x_11152_;
v___x_11152_ = 1ULL;
return v___x_11152_;
}
v___jp_11081_:
{
uint32_t v___x_11087_; uint32_t v___x_11088_; uint32_t v___x_11089_; uint32_t v___x_11090_; uint32_t v___x_11091_; uint32_t v___x_11092_; uint32_t v_lo32_11093_; uint64_t v___x_11094_; uint64_t v___x_11095_; uint64_t v___x_11096_; uint64_t v___x_11097_; uint64_t v___x_11098_;
v___x_11087_ = 256;
v___x_11088_ = lean_uint32_lor(v___x_11087_, v___y_11085_);
v___x_11089_ = lean_uint32_lor(v___x_11088_, v___y_11082_);
v___x_11090_ = lean_uint32_lor(v___x_11089_, v___y_11084_);
v___x_11091_ = 16;
v___x_11092_ = lean_uint32_shift_left(v___y_11083_, v___x_11091_);
v_lo32_11093_ = lean_uint32_lor(v___x_11090_, v___x_11092_);
v___x_11094_ = lean_uint32_to_uint64(v_lo32_11093_);
v___x_11095_ = lean_uint32_to_uint64(v___y_11086_);
v___x_11096_ = 32ULL;
v___x_11097_ = lean_uint64_shift_left(v___x_11095_, v___x_11096_);
v___x_11098_ = lean_uint64_lor(v___x_11094_, v___x_11097_);
return v___x_11098_;
}
v___jp_11099_:
{
uint8_t v___x_11104_;
v___x_11104_ = lean_uint32_dec_le(v_diffBytes_11078_, v_maxBytes_11080_);
if (v___x_11104_ == 0)
{
v___y_11082_ = v___y_11100_;
v___y_11083_ = v___y_11103_;
v___y_11084_ = v___y_11101_;
v___y_11085_ = v___y_11102_;
v___y_11086_ = v_maxBytes_11080_;
goto v___jp_11081_;
}
else
{
v___y_11082_ = v___y_11100_;
v___y_11083_ = v___y_11103_;
v___y_11084_ = v___y_11101_;
v___y_11085_ = v___y_11102_;
v___y_11086_ = v_diffBytes_11078_;
goto v___jp_11081_;
}
}
}
}

LEAN_EXPORT uint8_t orb_sidebar_move_target_admit(uint8_t v_itemKind_11175_, uint8_t v_dstIsSelfOrSubtree_11176_, uint32_t v_srcProjectOrd_11177_, uint32_t v_srcPathOrd_11178_, uint32_t v_srcParentOrd_11179_, uint32_t v_dstProjectOrd_11180_, uint32_t v_dstPathOrd_11181_){
_start:
{
uint8_t v___y_11183_; uint8_t v___y_11184_; uint8_t v___y_11185_; uint8_t v___y_11186_; uint8_t v___y_11191_; uint8_t v___y_11192_; uint8_t v___y_11193_; uint32_t v___y_11194_; uint8_t v___y_11198_; uint8_t v___y_11199_; uint8_t v___y_11200_; uint8_t v___y_11201_; uint8_t v___y_11205_; uint8_t v___x_11209_; uint8_t v___x_11210_;
v___x_11209_ = 3;
v___x_11210_ = lean_uint8_dec_le(v_itemKind_11175_, v___x_11209_);
if (v___x_11210_ == 0)
{
v___y_11205_ = v___x_11210_;
goto v___jp_11204_;
}
else
{
uint32_t v___x_11211_; uint8_t v___x_11212_;
v___x_11211_ = 0;
v___x_11212_ = lean_uint32_dec_eq(v_srcProjectOrd_11177_, v___x_11211_);
if (v___x_11212_ == 0)
{
uint8_t v___x_11213_;
v___x_11213_ = lean_uint32_dec_eq(v_dstProjectOrd_11180_, v___x_11211_);
if (v___x_11213_ == 0)
{
v___y_11205_ = v___x_11210_;
goto v___jp_11204_;
}
else
{
v___y_11205_ = v___x_11212_;
goto v___jp_11204_;
}
}
else
{
uint8_t v___x_11214_;
v___x_11214_ = 0;
v___y_11205_ = v___x_11214_;
goto v___jp_11204_;
}
}
v___jp_11182_:
{
if (v___y_11185_ == 0)
{
uint8_t v___x_11187_;
v___x_11187_ = 0;
return v___x_11187_;
}
else
{
if (v___y_11183_ == 0)
{
if (v___y_11186_ == 0)
{
return v___y_11184_;
}
else
{
uint8_t v___x_11188_;
v___x_11188_ = 0;
return v___x_11188_;
}
}
else
{
uint8_t v___x_11189_;
v___x_11189_ = 0;
return v___x_11189_;
}
}
}
v___jp_11190_:
{
uint8_t v___x_11195_;
v___x_11195_ = lean_uint32_dec_eq(v_srcProjectOrd_11177_, v_dstProjectOrd_11180_);
if (v___x_11195_ == 0)
{
v___y_11183_ = v___y_11191_;
v___y_11184_ = v___y_11192_;
v___y_11185_ = v___y_11193_;
v___y_11186_ = v___x_11195_;
goto v___jp_11182_;
}
else
{
uint8_t v___x_11196_;
v___x_11196_ = lean_uint32_dec_eq(v___y_11194_, v_dstPathOrd_11181_);
v___y_11183_ = v___y_11191_;
v___y_11184_ = v___y_11192_;
v___y_11185_ = v___y_11193_;
v___y_11186_ = v___x_11196_;
goto v___jp_11182_;
}
}
v___jp_11197_:
{
if (v___y_11199_ == 0)
{
uint8_t v___x_11202_; uint8_t v___x_11203_;
v___x_11202_ = 2;
v___x_11203_ = lean_uint8_dec_eq(v_itemKind_11175_, v___x_11202_);
if (v___x_11203_ == 0)
{
v___y_11191_ = v___y_11201_;
v___y_11192_ = v___y_11198_;
v___y_11193_ = v___y_11200_;
v___y_11194_ = v_srcPathOrd_11178_;
goto v___jp_11190_;
}
else
{
v___y_11191_ = v___y_11201_;
v___y_11192_ = v___y_11198_;
v___y_11193_ = v___y_11200_;
v___y_11194_ = v_srcParentOrd_11179_;
goto v___jp_11190_;
}
}
else
{
v___y_11191_ = v___y_11201_;
v___y_11192_ = v___y_11198_;
v___y_11193_ = v___y_11200_;
v___y_11194_ = v_srcParentOrd_11179_;
goto v___jp_11190_;
}
}
v___jp_11204_:
{
uint8_t v___x_11206_; uint8_t v___x_11207_;
v___x_11206_ = 1;
v___x_11207_ = lean_uint8_dec_eq(v_itemKind_11175_, v___x_11206_);
if (v___x_11207_ == 0)
{
v___y_11198_ = v___x_11206_;
v___y_11199_ = v___x_11207_;
v___y_11200_ = v___y_11205_;
v___y_11201_ = v___x_11207_;
goto v___jp_11197_;
}
else
{
uint8_t v___x_11208_;
v___x_11208_ = lean_uint8_dec_eq(v_dstIsSelfOrSubtree_11176_, v___x_11206_);
v___y_11198_ = v___x_11206_;
v___y_11199_ = v___x_11207_;
v___y_11200_ = v___y_11205_;
v___y_11201_ = v___x_11208_;
goto v___jp_11197_;
}
}
}
}

LEAN_EXPORT uint64_t orb_sidebar_drag_step(uint8_t v_phase_11315_, uint8_t v_eventKind_11316_, uint8_t v_rowMovable_11317_, uint8_t v_targetCollapsed_11318_, uint8_t v_targetAdmitted_11319_, uint32_t v_distSq_11320_, uint32_t v_elapsedMs_11321_, uint32_t v_springElapsedMs_11322_, uint32_t v_hoverTargetOrd_11323_, uint32_t v_springTargetOrd_11324_, uint32_t v_edgeTopDistPx_11325_, uint32_t v_edgeBottomDistPx_11326_){
_start:
{
uint32_t v___y_11328_; uint32_t v___y_11329_; uint32_t v___y_11336_; uint32_t v___y_11339_; uint8_t v___y_11340_; uint32_t v___y_11344_; uint32_t v___y_11347_; uint8_t v___y_11350_; uint32_t v___y_11351_; uint8_t v___x_11353_; uint8_t v___y_11355_; uint32_t v___y_11356_; uint8_t v___y_11357_; uint8_t v___y_11358_; uint8_t v___y_11361_; uint32_t v___y_11362_; uint8_t v___y_11363_; uint32_t v___y_11367_; uint8_t v___y_11395_; uint32_t v___y_11396_; uint8_t v___y_11398_; uint8_t v___y_11399_; uint32_t v___y_11400_; uint8_t v___y_11401_; uint32_t v___y_11402_; uint32_t v___y_11413_; uint8_t v___y_11414_; uint8_t v___y_11415_; uint8_t v___y_11416_; uint32_t v___y_11417_; uint8_t v___y_11433_; uint32_t v___y_11434_; uint8_t v___y_11435_; uint8_t v___y_11436_; uint32_t v___y_11437_; uint8_t v___y_11438_; uint8_t v___y_11439_; uint8_t v___y_11442_; uint8_t v___y_11443_; uint8_t v___y_11444_; uint8_t v___y_11445_; uint32_t v___y_11446_; uint8_t v___y_11463_; uint8_t v___y_11464_; uint8_t v___y_11465_; uint8_t v___y_11466_; uint32_t v___y_11467_; uint8_t v___y_11471_; uint8_t v___y_11472_; uint32_t v___y_11473_; uint8_t v___y_11474_; uint8_t v___y_11475_; uint32_t v___y_11476_; uint8_t v___y_11480_; uint32_t v___y_11481_; uint8_t v___y_11482_; uint8_t v___y_11483_; uint8_t v___y_11484_; uint8_t v___y_11487_; uint8_t v___y_11488_; uint8_t v___y_11489_; uint32_t v___y_11490_; uint8_t v___y_11491_; uint8_t v___y_11492_; uint32_t v___y_11493_; uint8_t v___y_11505_; uint8_t v___y_11506_; uint8_t v___y_11507_; uint8_t v___y_11523_; uint8_t v___y_11524_; uint8_t v___y_11525_; uint8_t v___y_11526_; uint8_t v___y_11527_; uint8_t v___y_11528_; uint8_t v___y_11531_; uint8_t v___y_11532_; uint8_t v___y_11533_; uint8_t v___y_11534_; uint8_t v___y_11535_; uint8_t v___y_11536_; uint8_t v___y_11541_; uint8_t v___y_11542_; uint8_t v___y_11543_; uint8_t v___y_11544_; uint8_t v___y_11545_; uint8_t v___y_11549_; uint8_t v___y_11552_; uint8_t v___y_11555_; uint8_t v___y_11558_; uint8_t v___x_11603_;
v___x_11353_ = 3;
v___x_11603_ = lean_uint8_dec_lt(v___x_11353_, v_phase_11315_);
if (v___x_11603_ == 0)
{
uint8_t v___x_11604_; uint8_t v___x_11605_;
v___x_11604_ = 5;
v___x_11605_ = lean_uint8_dec_lt(v___x_11604_, v_eventKind_11316_);
v___y_11558_ = v___x_11605_;
goto v___jp_11557_;
}
else
{
v___y_11558_ = v___x_11603_;
goto v___jp_11557_;
}
v___jp_11327_:
{
uint64_t v___x_11330_; uint64_t v___x_11331_; uint64_t v___x_11332_; uint64_t v___x_11333_; uint64_t v___x_11334_;
v___x_11330_ = lean_uint32_to_uint64(v___y_11328_);
v___x_11331_ = lean_uint32_to_uint64(v___y_11329_);
v___x_11332_ = 32ULL;
v___x_11333_ = lean_uint64_shift_left(v___x_11331_, v___x_11332_);
v___x_11334_ = lean_uint64_lor(v___x_11330_, v___x_11333_);
return v___x_11334_;
}
v___jp_11335_:
{
uint32_t v___x_11337_;
v___x_11337_ = 0;
v___y_11328_ = v___y_11336_;
v___y_11329_ = v___x_11337_;
goto v___jp_11327_;
}
v___jp_11338_:
{
if (v___y_11340_ == 0)
{
v___y_11336_ = v___y_11339_;
goto v___jp_11335_;
}
else
{
uint32_t v___x_11341_; uint8_t v___x_11342_;
v___x_11341_ = 0;
v___x_11342_ = lean_uint32_dec_eq(v_hoverTargetOrd_11323_, v___x_11341_);
if (v___x_11342_ == 0)
{
v___y_11328_ = v___y_11339_;
v___y_11329_ = v_hoverTargetOrd_11323_;
goto v___jp_11327_;
}
else
{
v___y_11336_ = v___y_11339_;
goto v___jp_11335_;
}
}
}
v___jp_11343_:
{
uint32_t v___x_11345_;
v___x_11345_ = 0;
v___y_11328_ = v___y_11344_;
v___y_11329_ = v___x_11345_;
goto v___jp_11327_;
}
v___jp_11346_:
{
uint32_t v___x_11348_;
v___x_11348_ = 0;
v___y_11328_ = v___y_11347_;
v___y_11329_ = v___x_11348_;
goto v___jp_11327_;
}
v___jp_11349_:
{
uint8_t v___x_11352_;
v___x_11352_ = lean_uint8_dec_eq(v_targetCollapsed_11318_, v___y_11350_);
v___y_11339_ = v___y_11351_;
v___y_11340_ = v___x_11352_;
goto v___jp_11338_;
}
v___jp_11354_:
{
uint8_t v___x_11359_;
v___x_11359_ = lean_uint8_dec_eq(v_phase_11315_, v___x_11353_);
if (v___x_11359_ == 0)
{
if (v___y_11358_ == 0)
{
v___y_11339_ = v___y_11356_;
v___y_11340_ = v___y_11357_;
goto v___jp_11338_;
}
else
{
v___y_11350_ = v___y_11355_;
v___y_11351_ = v___y_11356_;
goto v___jp_11349_;
}
}
else
{
v___y_11350_ = v___y_11355_;
v___y_11351_ = v___y_11356_;
goto v___jp_11349_;
}
}
v___jp_11360_:
{
uint32_t v___x_11364_; uint8_t v___x_11365_;
v___x_11364_ = 36;
v___x_11365_ = lean_uint32_dec_le(v___x_11364_, v_distSq_11320_);
v___y_11355_ = v___y_11361_;
v___y_11356_ = v___y_11362_;
v___y_11357_ = v___y_11363_;
v___y_11358_ = v___x_11365_;
goto v___jp_11354_;
}
v___jp_11366_:
{
uint8_t v___x_11368_; uint8_t v___x_11369_;
v___x_11368_ = 5;
v___x_11369_ = lean_uint8_dec_eq(v_eventKind_11316_, v___x_11368_);
if (v___x_11369_ == 0)
{
uint8_t v___x_11370_; uint8_t v___x_11371_;
v___x_11370_ = 0;
v___x_11371_ = lean_uint8_dec_eq(v_eventKind_11316_, v___x_11370_);
if (v___x_11371_ == 0)
{
uint8_t v___x_11372_;
v___x_11372_ = lean_uint8_dec_eq(v_phase_11315_, v___x_11370_);
if (v___x_11372_ == 0)
{
uint8_t v___x_11373_; uint8_t v___x_11374_;
v___x_11373_ = 1;
v___x_11374_ = lean_uint8_dec_eq(v_eventKind_11316_, v___x_11373_);
if (v___x_11374_ == 0)
{
uint8_t v___x_11375_; uint8_t v___x_11376_;
v___x_11375_ = 2;
v___x_11376_ = lean_uint8_dec_eq(v_eventKind_11316_, v___x_11375_);
if (v___x_11376_ == 0)
{
uint8_t v___x_11377_;
v___x_11377_ = lean_uint8_dec_eq(v_eventKind_11316_, v___x_11353_);
if (v___x_11377_ == 0)
{
uint32_t v___x_11378_;
v___x_11378_ = 0;
v___y_11328_ = v___y_11367_;
v___y_11329_ = v___x_11378_;
goto v___jp_11327_;
}
else
{
uint8_t v___x_11379_;
v___x_11379_ = lean_uint8_dec_eq(v_phase_11315_, v___x_11353_);
if (v___x_11379_ == 0)
{
v___y_11344_ = v___y_11367_;
goto v___jp_11343_;
}
else
{
uint8_t v___x_11380_;
v___x_11380_ = lean_uint8_dec_eq(v_targetCollapsed_11318_, v___x_11373_);
if (v___x_11380_ == 0)
{
v___y_11344_ = v___y_11367_;
goto v___jp_11343_;
}
else
{
uint32_t v___x_11381_; uint8_t v___x_11382_;
v___x_11381_ = 0;
v___x_11382_ = lean_uint32_dec_eq(v_hoverTargetOrd_11323_, v___x_11381_);
if (v___x_11382_ == 0)
{
uint8_t v___x_11383_;
v___x_11383_ = lean_uint32_dec_eq(v_hoverTargetOrd_11323_, v_springTargetOrd_11324_);
if (v___x_11383_ == 0)
{
v___y_11344_ = v___y_11367_;
goto v___jp_11343_;
}
else
{
uint32_t v___x_11384_; uint8_t v___x_11385_;
v___x_11384_ = 450;
v___x_11385_ = lean_uint32_dec_le(v___x_11384_, v_springElapsedMs_11322_);
if (v___x_11385_ == 0)
{
v___y_11328_ = v___y_11367_;
v___y_11329_ = v_springTargetOrd_11324_;
goto v___jp_11327_;
}
else
{
v___y_11344_ = v___y_11367_;
goto v___jp_11343_;
}
}
}
else
{
v___y_11344_ = v___y_11367_;
goto v___jp_11343_;
}
}
}
}
}
else
{
uint8_t v___x_11386_;
v___x_11386_ = lean_uint8_dec_eq(v_phase_11315_, v___x_11373_);
if (v___x_11386_ == 0)
{
uint8_t v___x_11387_;
v___x_11387_ = lean_uint8_dec_eq(v_phase_11315_, v___x_11375_);
if (v___x_11387_ == 0)
{
v___y_11355_ = v___x_11373_;
v___y_11356_ = v___y_11367_;
v___y_11357_ = v___x_11374_;
v___y_11358_ = v___x_11374_;
goto v___jp_11354_;
}
else
{
v___y_11361_ = v___x_11373_;
v___y_11362_ = v___y_11367_;
v___y_11363_ = v___x_11374_;
goto v___jp_11360_;
}
}
else
{
v___y_11361_ = v___x_11373_;
v___y_11362_ = v___y_11367_;
v___y_11363_ = v___x_11374_;
goto v___jp_11360_;
}
}
}
else
{
uint8_t v___x_11388_;
v___x_11388_ = lean_uint8_dec_eq(v_phase_11315_, v___x_11373_);
if (v___x_11388_ == 0)
{
v___y_11328_ = v___y_11367_;
v___y_11329_ = v_springTargetOrd_11324_;
goto v___jp_11327_;
}
else
{
uint32_t v___x_11389_; uint8_t v___x_11390_;
v___x_11389_ = 260;
v___x_11390_ = lean_uint32_dec_le(v___x_11389_, v_elapsedMs_11321_);
if (v___x_11390_ == 0)
{
v___y_11328_ = v___y_11367_;
v___y_11329_ = v_springTargetOrd_11324_;
goto v___jp_11327_;
}
else
{
uint32_t v___x_11391_; uint8_t v___x_11392_;
v___x_11391_ = 36;
v___x_11392_ = lean_uint32_dec_lt(v_distSq_11320_, v___x_11391_);
if (v___x_11392_ == 0)
{
v___y_11328_ = v___y_11367_;
v___y_11329_ = v_springTargetOrd_11324_;
goto v___jp_11327_;
}
else
{
uint32_t v___x_11393_;
v___x_11393_ = 0;
v___y_11328_ = v___y_11367_;
v___y_11329_ = v___x_11393_;
goto v___jp_11327_;
}
}
}
}
}
else
{
v___y_11347_ = v___y_11367_;
goto v___jp_11346_;
}
}
else
{
v___y_11347_ = v___y_11367_;
goto v___jp_11346_;
}
}
else
{
v___y_11347_ = v___y_11367_;
goto v___jp_11346_;
}
}
v___jp_11394_:
{
if (v___y_11395_ == 0)
{
v___y_11367_ = v___y_11396_;
goto v___jp_11366_;
}
else
{
v___y_11347_ = v___y_11396_;
goto v___jp_11346_;
}
}
v___jp_11397_:
{
uint32_t v___x_11403_; uint32_t v___x_11404_; uint32_t v___x_11405_; uint32_t v___x_11406_; uint32_t v___x_11407_; uint32_t v___x_11408_; uint32_t v___x_11409_; uint32_t v___x_11410_; uint32_t v___x_11411_;
v___x_11403_ = lean_uint8_to_uint32(v___y_11401_);
v___x_11404_ = lean_uint8_to_uint32(v___y_11398_);
v___x_11405_ = 8;
v___x_11406_ = lean_uint32_shift_left(v___x_11404_, v___x_11405_);
v___x_11407_ = lean_uint32_lor(v___x_11403_, v___x_11406_);
v___x_11408_ = lean_uint32_lor(v___x_11407_, v___y_11402_);
v___x_11409_ = 24;
v___x_11410_ = lean_uint32_shift_left(v___y_11400_, v___x_11409_);
v___x_11411_ = lean_uint32_lor(v___x_11408_, v___x_11410_);
v___y_11395_ = v___y_11399_;
v___y_11396_ = v___x_11411_;
goto v___jp_11394_;
}
v___jp_11412_:
{
uint8_t v___x_11418_;
v___x_11418_ = lean_uint32_dec_lt(v_edgeBottomDistPx_11326_, v___y_11413_);
if (v___x_11418_ == 0)
{
uint32_t v___x_11419_;
v___x_11419_ = 0;
v___y_11398_ = v___y_11414_;
v___y_11399_ = v___y_11415_;
v___y_11400_ = v___y_11417_;
v___y_11401_ = v___y_11416_;
v___y_11402_ = v___x_11419_;
goto v___jp_11397_;
}
else
{
uint32_t v___x_11420_; uint32_t v___x_11421_; uint64_t v___x_11422_; uint64_t v___x_11423_; uint64_t v___x_11424_; uint64_t v___x_11425_; uint64_t v___x_11426_; uint64_t v___x_11427_; uint64_t v___x_11428_; uint32_t v___x_11429_; uint8_t v___x_11430_;
v___x_11420_ = 0;
v___x_11421_ = lean_uint32_sub(v___y_11413_, v_edgeBottomDistPx_11326_);
v___x_11422_ = lean_uint32_to_uint64(v___x_11421_);
v___x_11423_ = 10ULL;
v___x_11424_ = lean_uint64_mul(v___x_11422_, v___x_11423_);
v___x_11425_ = 35ULL;
v___x_11426_ = lean_uint64_add(v___x_11424_, v___x_11425_);
v___x_11427_ = 36ULL;
v___x_11428_ = lean_uint64_div(v___x_11426_, v___x_11427_);
v___x_11429_ = lean_uint64_to_uint32(v___x_11428_);
v___x_11430_ = lean_uint32_dec_lt(v___x_11420_, v___x_11429_);
if (v___x_11430_ == 0)
{
v___y_11398_ = v___y_11414_;
v___y_11399_ = v___y_11415_;
v___y_11400_ = v___y_11417_;
v___y_11401_ = v___y_11416_;
v___y_11402_ = v___x_11420_;
goto v___jp_11397_;
}
else
{
uint32_t v___x_11431_;
v___x_11431_ = 262144;
v___y_11398_ = v___y_11414_;
v___y_11399_ = v___y_11415_;
v___y_11400_ = v___y_11417_;
v___y_11401_ = v___y_11416_;
v___y_11402_ = v___x_11431_;
goto v___jp_11397_;
}
}
}
v___jp_11432_:
{
if (v___y_11433_ == 0)
{
v___y_11413_ = v___y_11434_;
v___y_11414_ = v___y_11435_;
v___y_11415_ = v___y_11436_;
v___y_11416_ = v___y_11438_;
v___y_11417_ = v___y_11437_;
goto v___jp_11412_;
}
else
{
if (v___y_11439_ == 0)
{
uint32_t v___x_11440_;
v___x_11440_ = 0;
v___y_11398_ = v___y_11435_;
v___y_11399_ = v___y_11436_;
v___y_11400_ = v___y_11437_;
v___y_11401_ = v___y_11438_;
v___y_11402_ = v___x_11440_;
goto v___jp_11397_;
}
else
{
v___y_11413_ = v___y_11434_;
v___y_11414_ = v___y_11435_;
v___y_11415_ = v___y_11436_;
v___y_11416_ = v___y_11438_;
v___y_11417_ = v___y_11437_;
goto v___jp_11412_;
}
}
}
v___jp_11441_:
{
if (v___y_11442_ == 0)
{
uint32_t v___x_11447_;
v___x_11447_ = 0;
v___y_11398_ = v___y_11443_;
v___y_11399_ = v___y_11444_;
v___y_11400_ = v___y_11446_;
v___y_11401_ = v___y_11445_;
v___y_11402_ = v___x_11447_;
goto v___jp_11397_;
}
else
{
uint32_t v___x_11448_; uint8_t v___x_11449_;
v___x_11448_ = 36;
v___x_11449_ = lean_uint32_dec_lt(v_edgeTopDistPx_11325_, v___x_11448_);
if (v___x_11449_ == 0)
{
v___y_11433_ = v___x_11449_;
v___y_11434_ = v___x_11448_;
v___y_11435_ = v___y_11443_;
v___y_11436_ = v___y_11444_;
v___y_11437_ = v___y_11446_;
v___y_11438_ = v___y_11445_;
v___y_11439_ = v___x_11449_;
goto v___jp_11432_;
}
else
{
uint32_t v___x_11450_; uint32_t v___x_11451_; uint64_t v___x_11452_; uint64_t v___x_11453_; uint64_t v___x_11454_; uint64_t v___x_11455_; uint64_t v___x_11456_; uint64_t v___x_11457_; uint64_t v___x_11458_; uint32_t v___x_11459_; uint8_t v___x_11460_;
v___x_11450_ = 0;
v___x_11451_ = lean_uint32_sub(v___x_11448_, v_edgeTopDistPx_11325_);
v___x_11452_ = lean_uint32_to_uint64(v___x_11451_);
v___x_11453_ = 10ULL;
v___x_11454_ = lean_uint64_mul(v___x_11452_, v___x_11453_);
v___x_11455_ = 35ULL;
v___x_11456_ = lean_uint64_add(v___x_11454_, v___x_11455_);
v___x_11457_ = 36ULL;
v___x_11458_ = lean_uint64_div(v___x_11456_, v___x_11457_);
v___x_11459_ = lean_uint64_to_uint32(v___x_11458_);
v___x_11460_ = lean_uint32_dec_lt(v___x_11450_, v___x_11459_);
if (v___x_11460_ == 0)
{
v___y_11433_ = v___x_11449_;
v___y_11434_ = v___x_11448_;
v___y_11435_ = v___y_11443_;
v___y_11436_ = v___y_11444_;
v___y_11437_ = v___y_11446_;
v___y_11438_ = v___y_11445_;
v___y_11439_ = v___x_11460_;
goto v___jp_11432_;
}
else
{
uint32_t v___x_11461_;
v___x_11461_ = 131072;
v___y_11398_ = v___y_11443_;
v___y_11399_ = v___y_11444_;
v___y_11400_ = v___y_11446_;
v___y_11401_ = v___y_11445_;
v___y_11402_ = v___x_11461_;
goto v___jp_11397_;
}
}
}
}
v___jp_11462_:
{
uint32_t v___x_11468_; uint8_t v___x_11469_;
v___x_11468_ = 10;
v___x_11469_ = lean_uint32_dec_lt(v___x_11468_, v___y_11467_);
if (v___x_11469_ == 0)
{
v___y_11442_ = v___y_11463_;
v___y_11443_ = v___y_11464_;
v___y_11444_ = v___y_11465_;
v___y_11445_ = v___y_11466_;
v___y_11446_ = v___y_11467_;
goto v___jp_11441_;
}
else
{
v___y_11442_ = v___y_11463_;
v___y_11443_ = v___y_11464_;
v___y_11444_ = v___y_11465_;
v___y_11445_ = v___y_11466_;
v___y_11446_ = v___x_11468_;
goto v___jp_11441_;
}
}
v___jp_11470_:
{
uint32_t v___x_11477_; uint8_t v___x_11478_;
v___x_11477_ = 0;
v___x_11478_ = lean_uint32_dec_lt(v___x_11477_, v___y_11473_);
if (v___x_11478_ == 0)
{
v___y_11463_ = v___y_11471_;
v___y_11464_ = v___y_11472_;
v___y_11465_ = v___y_11474_;
v___y_11466_ = v___y_11475_;
v___y_11467_ = v___y_11476_;
goto v___jp_11462_;
}
else
{
v___y_11463_ = v___y_11471_;
v___y_11464_ = v___y_11472_;
v___y_11465_ = v___y_11474_;
v___y_11466_ = v___y_11475_;
v___y_11467_ = v___y_11473_;
goto v___jp_11462_;
}
}
v___jp_11479_:
{
uint32_t v___x_11485_;
v___x_11485_ = 0;
v___y_11471_ = v___y_11480_;
v___y_11472_ = v___y_11482_;
v___y_11473_ = v___y_11481_;
v___y_11474_ = v___y_11483_;
v___y_11475_ = v___y_11484_;
v___y_11476_ = v___x_11485_;
goto v___jp_11470_;
}
v___jp_11486_:
{
if (v___y_11489_ == 0)
{
uint8_t v___x_11494_;
v___x_11494_ = lean_uint32_dec_lt(v_edgeBottomDistPx_11326_, v___y_11490_);
if (v___x_11494_ == 0)
{
v___y_11480_ = v___y_11487_;
v___y_11481_ = v___y_11493_;
v___y_11482_ = v___y_11488_;
v___y_11483_ = v___y_11491_;
v___y_11484_ = v___y_11492_;
goto v___jp_11479_;
}
else
{
uint32_t v___x_11495_; uint64_t v___x_11496_; uint64_t v___x_11497_; uint64_t v___x_11498_; uint64_t v___x_11499_; uint64_t v___x_11500_; uint64_t v___x_11501_; uint64_t v___x_11502_; uint32_t v___x_11503_;
v___x_11495_ = lean_uint32_sub(v___y_11490_, v_edgeBottomDistPx_11326_);
v___x_11496_ = lean_uint32_to_uint64(v___x_11495_);
v___x_11497_ = 10ULL;
v___x_11498_ = lean_uint64_mul(v___x_11496_, v___x_11497_);
v___x_11499_ = 35ULL;
v___x_11500_ = lean_uint64_add(v___x_11498_, v___x_11499_);
v___x_11501_ = 36ULL;
v___x_11502_ = lean_uint64_div(v___x_11500_, v___x_11501_);
v___x_11503_ = lean_uint64_to_uint32(v___x_11502_);
v___y_11471_ = v___y_11487_;
v___y_11472_ = v___y_11488_;
v___y_11473_ = v___y_11493_;
v___y_11474_ = v___y_11491_;
v___y_11475_ = v___y_11492_;
v___y_11476_ = v___x_11503_;
goto v___jp_11470_;
}
}
else
{
v___y_11480_ = v___y_11487_;
v___y_11481_ = v___y_11493_;
v___y_11482_ = v___y_11488_;
v___y_11483_ = v___y_11491_;
v___y_11484_ = v___y_11492_;
goto v___jp_11479_;
}
}
v___jp_11504_:
{
uint8_t v___x_11508_;
v___x_11508_ = lean_uint8_dec_eq(v___y_11506_, v___x_11353_);
if (v___x_11508_ == 0)
{
uint32_t v___x_11509_;
v___x_11509_ = 0;
v___y_11442_ = v___x_11508_;
v___y_11443_ = v___y_11507_;
v___y_11444_ = v___y_11505_;
v___y_11445_ = v___y_11506_;
v___y_11446_ = v___x_11509_;
goto v___jp_11441_;
}
else
{
uint32_t v___x_11510_; uint8_t v___x_11511_;
v___x_11510_ = 36;
v___x_11511_ = lean_uint32_dec_lt(v_edgeTopDistPx_11325_, v___x_11510_);
if (v___x_11511_ == 0)
{
uint32_t v___x_11512_;
v___x_11512_ = 0;
v___y_11487_ = v___x_11508_;
v___y_11488_ = v___y_11507_;
v___y_11489_ = v___x_11511_;
v___y_11490_ = v___x_11510_;
v___y_11491_ = v___y_11505_;
v___y_11492_ = v___y_11506_;
v___y_11493_ = v___x_11512_;
goto v___jp_11486_;
}
else
{
uint32_t v___x_11513_; uint64_t v___x_11514_; uint64_t v___x_11515_; uint64_t v___x_11516_; uint64_t v___x_11517_; uint64_t v___x_11518_; uint64_t v___x_11519_; uint64_t v___x_11520_; uint32_t v___x_11521_;
v___x_11513_ = lean_uint32_sub(v___x_11510_, v_edgeTopDistPx_11325_);
v___x_11514_ = lean_uint32_to_uint64(v___x_11513_);
v___x_11515_ = 10ULL;
v___x_11516_ = lean_uint64_mul(v___x_11514_, v___x_11515_);
v___x_11517_ = 35ULL;
v___x_11518_ = lean_uint64_add(v___x_11516_, v___x_11517_);
v___x_11519_ = 36ULL;
v___x_11520_ = lean_uint64_div(v___x_11518_, v___x_11519_);
v___x_11521_ = lean_uint64_to_uint32(v___x_11520_);
v___y_11487_ = v___x_11508_;
v___y_11488_ = v___y_11507_;
v___y_11489_ = v___x_11511_;
v___y_11490_ = v___x_11510_;
v___y_11491_ = v___y_11505_;
v___y_11492_ = v___y_11506_;
v___y_11493_ = v___x_11521_;
goto v___jp_11486_;
}
}
}
v___jp_11522_:
{
uint8_t v___x_11529_;
v___x_11529_ = lean_uint8_dec_eq(v_phase_11315_, v___x_11353_);
if (v___x_11529_ == 0)
{
if (v___y_11524_ == 0)
{
if (v___y_11528_ == 0)
{
v___y_11505_ = v___y_11526_;
v___y_11506_ = v___y_11527_;
v___y_11507_ = v___y_11523_;
goto v___jp_11504_;
}
else
{
v___y_11505_ = v___y_11526_;
v___y_11506_ = v___y_11525_;
v___y_11507_ = v___y_11523_;
goto v___jp_11504_;
}
}
else
{
v___y_11505_ = v___y_11526_;
v___y_11506_ = v___x_11353_;
v___y_11507_ = v___y_11525_;
goto v___jp_11504_;
}
}
else
{
if (v___y_11524_ == 0)
{
v___y_11505_ = v___y_11526_;
v___y_11506_ = v___x_11353_;
v___y_11507_ = v___y_11523_;
goto v___jp_11504_;
}
else
{
v___y_11505_ = v___y_11526_;
v___y_11506_ = v___x_11353_;
v___y_11507_ = v___y_11525_;
goto v___jp_11504_;
}
}
}
v___jp_11530_:
{
uint8_t v___x_11537_;
v___x_11537_ = lean_uint8_dec_eq(v_phase_11315_, v___y_11533_);
if (v___x_11537_ == 0)
{
v___y_11523_ = v___y_11532_;
v___y_11524_ = v___y_11536_;
v___y_11525_ = v___y_11533_;
v___y_11526_ = v___y_11534_;
v___y_11527_ = v___y_11535_;
v___y_11528_ = v___y_11531_;
goto v___jp_11522_;
}
else
{
uint32_t v___x_11538_; uint8_t v___x_11539_;
v___x_11538_ = 36;
v___x_11539_ = lean_uint32_dec_lt(v_distSq_11320_, v___x_11538_);
v___y_11523_ = v___y_11532_;
v___y_11524_ = v___y_11536_;
v___y_11525_ = v___y_11533_;
v___y_11526_ = v___y_11534_;
v___y_11527_ = v___y_11535_;
v___y_11528_ = v___x_11539_;
goto v___jp_11522_;
}
}
v___jp_11540_:
{
uint32_t v___x_11546_; uint8_t v___x_11547_;
v___x_11546_ = 36;
v___x_11547_ = lean_uint32_dec_le(v___x_11546_, v_distSq_11320_);
v___y_11531_ = v___y_11541_;
v___y_11532_ = v___y_11542_;
v___y_11533_ = v___y_11543_;
v___y_11534_ = v___y_11544_;
v___y_11535_ = v___y_11545_;
v___y_11536_ = v___x_11547_;
goto v___jp_11530_;
}
v___jp_11548_:
{
uint32_t v___x_11550_;
v___x_11550_ = 67072;
v___y_11395_ = v___y_11549_;
v___y_11396_ = v___x_11550_;
goto v___jp_11394_;
}
v___jp_11551_:
{
uint32_t v___x_11553_;
v___x_11553_ = lean_uint8_to_uint32(v_phase_11315_);
v___y_11395_ = v___y_11552_;
v___y_11396_ = v___x_11553_;
goto v___jp_11394_;
}
v___jp_11554_:
{
uint32_t v___x_11556_;
v___x_11556_ = lean_uint8_to_uint32(v_phase_11315_);
v___y_11395_ = v___y_11555_;
v___y_11396_ = v___x_11556_;
goto v___jp_11394_;
}
v___jp_11557_:
{
if (v___y_11558_ == 0)
{
uint8_t v___x_11559_; uint8_t v___x_11560_;
v___x_11559_ = 5;
v___x_11560_ = lean_uint8_dec_eq(v_eventKind_11316_, v___x_11559_);
if (v___x_11560_ == 0)
{
uint8_t v___x_11561_; uint8_t v___x_11562_;
v___x_11561_ = 0;
v___x_11562_ = lean_uint8_dec_eq(v_eventKind_11316_, v___x_11561_);
if (v___x_11562_ == 0)
{
uint8_t v___x_11563_;
v___x_11563_ = lean_uint8_dec_eq(v_phase_11315_, v___x_11561_);
if (v___x_11563_ == 0)
{
uint8_t v___x_11564_; uint8_t v___x_11565_;
v___x_11564_ = 1;
v___x_11565_ = lean_uint8_dec_eq(v_eventKind_11316_, v___x_11564_);
if (v___x_11565_ == 0)
{
uint8_t v___x_11566_; uint8_t v___x_11567_;
v___x_11566_ = 2;
v___x_11567_ = lean_uint8_dec_eq(v_eventKind_11316_, v___x_11566_);
if (v___x_11567_ == 0)
{
uint8_t v___x_11568_;
v___x_11568_ = lean_uint8_dec_eq(v_eventKind_11316_, v___x_11353_);
if (v___x_11568_ == 0)
{
uint8_t v___x_11569_;
v___x_11569_ = lean_uint8_dec_eq(v_phase_11315_, v___x_11564_);
if (v___x_11569_ == 0)
{
uint8_t v___x_11570_;
v___x_11570_ = lean_uint8_dec_eq(v_phase_11315_, v___x_11566_);
if (v___x_11570_ == 0)
{
uint32_t v___x_11571_; uint8_t v___x_11572_;
v___x_11571_ = 0;
v___x_11572_ = lean_uint32_dec_eq(v_hoverTargetOrd_11323_, v___x_11571_);
if (v___x_11572_ == 0)
{
uint8_t v___x_11573_;
v___x_11573_ = lean_uint8_dec_eq(v_targetAdmitted_11319_, v___x_11564_);
if (v___x_11573_ == 0)
{
v___y_11549_ = v___y_11558_;
goto v___jp_11548_;
}
else
{
uint32_t v___x_11574_;
v___x_11574_ = 66560;
v___y_11367_ = v___x_11574_;
goto v___jp_11366_;
}
}
else
{
v___y_11549_ = v___y_11558_;
goto v___jp_11548_;
}
}
else
{
uint32_t v___x_11575_;
v___x_11575_ = 66816;
v___y_11367_ = v___x_11575_;
goto v___jp_11366_;
}
}
else
{
uint32_t v___x_11576_;
v___x_11576_ = 0;
v___y_11367_ = v___x_11576_;
goto v___jp_11366_;
}
}
else
{
uint8_t v___x_11577_;
v___x_11577_ = lean_uint8_dec_eq(v_phase_11315_, v___x_11353_);
if (v___x_11577_ == 0)
{
v___y_11552_ = v___y_11558_;
goto v___jp_11551_;
}
else
{
uint8_t v___x_11578_;
v___x_11578_ = lean_uint8_dec_eq(v_targetCollapsed_11318_, v___x_11564_);
if (v___x_11578_ == 0)
{
v___y_11552_ = v___y_11558_;
goto v___jp_11551_;
}
else
{
uint32_t v___x_11579_; uint8_t v___x_11580_;
v___x_11579_ = 0;
v___x_11580_ = lean_uint32_dec_eq(v_hoverTargetOrd_11323_, v___x_11579_);
if (v___x_11580_ == 0)
{
uint8_t v___x_11581_;
v___x_11581_ = lean_uint32_dec_eq(v_hoverTargetOrd_11323_, v_springTargetOrd_11324_);
if (v___x_11581_ == 0)
{
v___y_11552_ = v___y_11558_;
goto v___jp_11551_;
}
else
{
uint32_t v___x_11582_; uint8_t v___x_11583_;
v___x_11582_ = 450;
v___x_11583_ = lean_uint32_dec_le(v___x_11582_, v_springElapsedMs_11322_);
if (v___x_11583_ == 0)
{
v___y_11552_ = v___y_11558_;
goto v___jp_11551_;
}
else
{
uint32_t v___x_11584_;
v___x_11584_ = 771;
v___y_11367_ = v___x_11584_;
goto v___jp_11366_;
}
}
}
else
{
v___y_11552_ = v___y_11558_;
goto v___jp_11551_;
}
}
}
}
}
else
{
uint8_t v___x_11585_;
v___x_11585_ = lean_uint8_dec_eq(v_phase_11315_, v___x_11564_);
if (v___x_11585_ == 0)
{
uint8_t v___x_11586_;
v___x_11586_ = lean_uint8_dec_eq(v_phase_11315_, v___x_11566_);
if (v___x_11586_ == 0)
{
v___y_11531_ = v___x_11565_;
v___y_11532_ = v___x_11561_;
v___y_11533_ = v___x_11566_;
v___y_11534_ = v___y_11558_;
v___y_11535_ = v___x_11564_;
v___y_11536_ = v___x_11565_;
goto v___jp_11530_;
}
else
{
v___y_11541_ = v___x_11565_;
v___y_11542_ = v___x_11561_;
v___y_11543_ = v___x_11566_;
v___y_11544_ = v___y_11558_;
v___y_11545_ = v___x_11564_;
goto v___jp_11540_;
}
}
else
{
v___y_11541_ = v___x_11565_;
v___y_11542_ = v___x_11561_;
v___y_11543_ = v___x_11566_;
v___y_11544_ = v___y_11558_;
v___y_11545_ = v___x_11564_;
goto v___jp_11540_;
}
}
}
else
{
uint8_t v___x_11587_;
v___x_11587_ = lean_uint8_dec_eq(v_phase_11315_, v___x_11564_);
if (v___x_11587_ == 0)
{
v___y_11555_ = v___y_11558_;
goto v___jp_11554_;
}
else
{
uint32_t v___x_11588_; uint8_t v___x_11589_;
v___x_11588_ = 260;
v___x_11589_ = lean_uint32_dec_le(v___x_11588_, v_elapsedMs_11321_);
if (v___x_11589_ == 0)
{
v___y_11555_ = v___y_11558_;
goto v___jp_11554_;
}
else
{
uint32_t v___x_11590_; uint8_t v___x_11591_;
v___x_11590_ = 36;
v___x_11591_ = lean_uint32_dec_lt(v_distSq_11320_, v___x_11590_);
if (v___x_11591_ == 0)
{
v___y_11555_ = v___y_11558_;
goto v___jp_11554_;
}
else
{
uint32_t v___x_11592_;
v___x_11592_ = 258;
v___y_11367_ = v___x_11592_;
goto v___jp_11366_;
}
}
}
}
}
else
{
uint32_t v___x_11593_;
v___x_11593_ = 0;
v___y_11367_ = v___x_11593_;
goto v___jp_11366_;
}
}
else
{
uint8_t v___x_11594_; uint8_t v___x_11595_;
v___x_11594_ = 1;
v___x_11595_ = lean_uint8_dec_eq(v_rowMovable_11317_, v___x_11594_);
if (v___x_11595_ == 0)
{
uint32_t v___x_11596_;
v___x_11596_ = 0;
v___y_11367_ = v___x_11596_;
goto v___jp_11366_;
}
else
{
uint32_t v___x_11597_;
v___x_11597_ = 1;
v___y_11367_ = v___x_11597_;
goto v___jp_11366_;
}
}
}
else
{
uint8_t v___x_11598_; uint8_t v___x_11599_;
v___x_11598_ = 0;
v___x_11599_ = lean_uint8_dec_eq(v_phase_11315_, v___x_11598_);
if (v___x_11599_ == 0)
{
uint32_t v___x_11600_;
v___x_11600_ = 1536;
v___y_11367_ = v___x_11600_;
goto v___jp_11366_;
}
else
{
uint32_t v___x_11601_;
v___x_11601_ = 0;
v___y_11367_ = v___x_11601_;
goto v___jp_11366_;
}
}
}
else
{
uint32_t v___x_11602_;
v___x_11602_ = 1536;
v___y_11347_ = v___x_11602_;
goto v___jp_11346_;
}
}
}
}

LEAN_EXPORT uint64_t orb_followup_queue_step(uint8_t v_op_11632_, uint32_t v_serverRev_11633_, uint32_t v_incomingServerRev_11634_, uint32_t v_expectedServerRev_11635_, uint64_t v_clientMsgId_11636_, uint64_t v_trackedMsgId_11637_, uint64_t v_deliveredMsgId_11638_, uint64_t v_postedAfterSeq_11639_, uint64_t v_turnSeq_11640_, uint8_t v_optimisticSending_11641_, uint8_t v_serverListed_11642_, uint8_t v_contentMatched_11643_, uint8_t v_alreadyDelivered_11644_){
_start:
{
uint32_t v___y_11646_; uint32_t v___y_11647_; uint32_t v___y_11648_; uint32_t v___y_11649_; uint32_t v___y_11650_; uint32_t v___y_11660_; uint32_t v___y_11661_; uint32_t v___y_11662_; uint8_t v___y_11663_; uint32_t v___y_11664_; uint32_t v___y_11665_; uint32_t v___y_11668_; uint32_t v___y_11669_; uint8_t v___y_11670_; uint32_t v___y_11671_; uint8_t v___y_11672_; uint32_t v___y_11673_; uint8_t v___x_11679_; uint8_t v_opOk_11680_; uint8_t v___x_11681_; uint32_t v___y_11683_; uint32_t v___y_11684_; uint8_t v___y_11685_; uint8_t v___y_11686_; uint8_t v___y_11687_; uint8_t v___y_11688_; uint8_t v___y_11689_; uint8_t v___y_11690_; uint8_t v___y_11691_; uint32_t v___y_11703_; uint32_t v___y_11704_; uint8_t v___y_11705_; uint8_t v___y_11706_; uint8_t v___y_11707_; uint8_t v___y_11708_; uint8_t v___y_11709_; uint8_t v___y_11710_; uint8_t v___y_11711_; uint8_t v___y_11712_; uint8_t v___y_11713_; uint8_t v___y_11715_; uint32_t v___y_11716_; uint32_t v___y_11717_; uint8_t v___y_11718_; uint8_t v___y_11719_; uint8_t v___y_11720_; uint8_t v___y_11721_; uint8_t v___y_11722_; uint8_t v___y_11723_; uint8_t v___y_11724_; uint8_t v___y_11725_; uint8_t v___y_11726_; uint32_t v___y_11728_; uint8_t v___y_11729_; uint8_t v___y_11730_; uint8_t v___y_11731_; uint8_t v___y_11732_; uint8_t v___y_11733_; uint8_t v___y_11734_; uint8_t v___y_11735_; uint8_t v___y_11736_; uint8_t v___y_11737_; uint32_t v___y_11738_; uint8_t v___y_11741_; uint32_t v___y_11742_; uint8_t v___y_11743_; uint8_t v___y_11744_; uint8_t v___y_11745_; uint8_t v___y_11746_; uint8_t v___y_11747_; uint8_t v___y_11748_; uint8_t v___y_11749_; uint8_t v___y_11750_; uint8_t v___y_11751_; uint32_t v___y_11752_; uint8_t v___y_11754_; uint8_t v___y_11755_; uint32_t v___y_11756_; uint8_t v___y_11757_; uint8_t v___y_11758_; uint8_t v___y_11759_; uint8_t v___y_11760_; uint8_t v___y_11761_; uint8_t v___y_11762_; uint8_t v___y_11763_; uint8_t v___y_11764_; uint8_t v___y_11769_; uint32_t v___y_11770_; uint8_t v___y_11771_; uint8_t v___y_11772_; uint8_t v___y_11773_; uint8_t v___y_11774_; uint8_t v___y_11775_; uint8_t v___y_11776_; uint8_t v___y_11777_; uint8_t v___y_11778_; uint8_t v___y_11779_; uint32_t v___y_11780_; uint8_t v___y_11783_; uint8_t v___y_11784_; uint32_t v___y_11785_; uint8_t v___y_11786_; uint8_t v___y_11787_; uint8_t v___y_11788_; uint8_t v___y_11789_; uint8_t v___y_11790_; uint8_t v___y_11791_; uint8_t v___y_11792_; uint8_t v___y_11793_; uint8_t v___y_11795_; uint32_t v___y_11796_; uint8_t v___y_11797_; uint8_t v___y_11798_; uint8_t v___y_11799_; uint8_t v___y_11800_; uint8_t v___y_11801_; uint8_t v___y_11802_; uint8_t v___y_11803_; uint8_t v___y_11804_; uint8_t v___y_11805_; uint8_t v___y_11812_; uint8_t v___y_11813_; uint32_t v___y_11814_; uint8_t v___y_11815_; uint8_t v___y_11816_; uint8_t v___y_11817_; uint8_t v___y_11818_; uint8_t v___y_11819_; uint8_t v___y_11820_; uint8_t v___y_11825_; uint32_t v___y_11826_; uint8_t v___y_11827_; uint8_t v___y_11828_; uint8_t v___y_11829_; uint8_t v___y_11830_; uint8_t v___y_11831_; uint8_t v___y_11832_; uint8_t v___y_11833_; uint8_t v___y_11835_; uint32_t v___y_11836_; uint8_t v___y_11837_; uint8_t v___y_11838_; uint8_t v___y_11839_; uint8_t v___y_11840_; uint8_t v___y_11841_; uint8_t v___y_11842_; uint8_t v___y_11848_; uint8_t v___y_11849_; uint32_t v___y_11850_; uint8_t v___y_11851_; uint8_t v___y_11852_; uint8_t v___y_11853_; uint8_t v___y_11854_; uint8_t v___y_11855_; uint8_t v___y_11856_; uint8_t v___y_11859_; uint32_t v___y_11860_; uint64_t v___y_11861_; uint8_t v___y_11862_; uint8_t v___y_11863_; uint8_t v___y_11872_; uint8_t v___x_11877_;
v___x_11679_ = 3;
v_opOk_11680_ = lean_uint8_dec_le(v_op_11632_, v___x_11679_);
v___x_11681_ = 1;
v___x_11877_ = lean_uint8_dec_le(v_optimisticSending_11641_, v___x_11681_);
if (v___x_11877_ == 0)
{
v___y_11872_ = v___x_11877_;
goto v___jp_11871_;
}
else
{
uint8_t v___x_11878_;
v___x_11878_ = lean_uint8_dec_le(v_serverListed_11642_, v___x_11681_);
if (v___x_11878_ == 0)
{
v___y_11872_ = v___x_11878_;
goto v___jp_11871_;
}
else
{
uint8_t v___x_11879_;
v___x_11879_ = lean_uint8_dec_le(v_contentMatched_11643_, v___x_11681_);
if (v___x_11879_ == 0)
{
v___y_11872_ = v___x_11879_;
goto v___jp_11871_;
}
else
{
uint8_t v___x_11880_;
v___x_11880_ = lean_uint8_dec_le(v_alreadyDelivered_11644_, v___x_11681_);
v___y_11872_ = v___x_11880_;
goto v___jp_11871_;
}
}
}
v___jp_11645_:
{
uint32_t v___x_11651_; uint32_t v___x_11652_; uint32_t v_lo32_11653_; uint64_t v___x_11654_; uint64_t v___x_11655_; uint64_t v___x_11656_; uint64_t v___x_11657_; uint64_t v___x_11658_;
v___x_11651_ = lean_uint32_lor(v___y_11649_, v___y_11647_);
v___x_11652_ = lean_uint32_lor(v___x_11651_, v___y_11648_);
v_lo32_11653_ = lean_uint32_lor(v___x_11652_, v___y_11650_);
v___x_11654_ = lean_uint32_to_uint64(v_lo32_11653_);
v___x_11655_ = lean_uint32_to_uint64(v___y_11646_);
v___x_11656_ = 32ULL;
v___x_11657_ = lean_uint64_shift_left(v___x_11655_, v___x_11656_);
v___x_11658_ = lean_uint64_lor(v___x_11654_, v___x_11657_);
return v___x_11658_;
}
v___jp_11659_:
{
if (v___y_11663_ == 0)
{
v___y_11646_ = v___y_11661_;
v___y_11647_ = v___y_11662_;
v___y_11648_ = v___y_11665_;
v___y_11649_ = v___y_11664_;
v___y_11650_ = v___y_11660_;
goto v___jp_11645_;
}
else
{
uint32_t v___x_11666_;
v___x_11666_ = 1024;
v___y_11646_ = v___y_11661_;
v___y_11647_ = v___y_11662_;
v___y_11648_ = v___y_11665_;
v___y_11649_ = v___y_11664_;
v___y_11650_ = v___x_11666_;
goto v___jp_11645_;
}
}
v___jp_11667_:
{
if (v___y_11670_ == 0)
{
v___y_11660_ = v___y_11669_;
v___y_11661_ = v___y_11668_;
v___y_11662_ = v___y_11673_;
v___y_11663_ = v___y_11672_;
v___y_11664_ = v___y_11671_;
v___y_11665_ = v___y_11669_;
goto v___jp_11659_;
}
else
{
uint32_t v___x_11674_;
v___x_11674_ = 512;
v___y_11660_ = v___y_11669_;
v___y_11661_ = v___y_11668_;
v___y_11662_ = v___y_11673_;
v___y_11663_ = v___y_11672_;
v___y_11664_ = v___y_11671_;
v___y_11665_ = v___x_11674_;
goto v___jp_11659_;
}
}
v___jp_11675_:
{
uint64_t v___x_11676_; uint64_t v___x_11677_; uint64_t v___x_11678_;
v___x_11676_ = lean_uint32_to_uint64(v_serverRev_11633_);
v___x_11677_ = 32ULL;
v___x_11678_ = lean_uint64_shift_left(v___x_11676_, v___x_11677_);
return v___x_11678_;
}
v___jp_11682_:
{
if (v___y_11686_ == 0)
{
if (v___y_11687_ == 0)
{
uint8_t v___x_11692_;
v___x_11692_ = lean_uint8_dec_eq(v_op_11632_, v___x_11681_);
if (v___x_11692_ == 0)
{
if (v___y_11689_ == 0)
{
if (v___y_11690_ == 0)
{
uint32_t v___x_11693_;
v___x_11693_ = 4;
v___y_11668_ = v___y_11683_;
v___y_11669_ = v___y_11684_;
v___y_11670_ = v___y_11691_;
v___y_11671_ = v___x_11693_;
v___y_11672_ = v___y_11688_;
v___y_11673_ = v___y_11684_;
goto v___jp_11667_;
}
else
{
uint32_t v___x_11694_;
v___x_11694_ = 3;
v___y_11668_ = v___y_11683_;
v___y_11669_ = v___y_11684_;
v___y_11670_ = v___y_11691_;
v___y_11671_ = v___x_11694_;
v___y_11672_ = v___y_11688_;
v___y_11673_ = v___y_11684_;
goto v___jp_11667_;
}
}
else
{
if (v___y_11685_ == 0)
{
v___y_11668_ = v___y_11683_;
v___y_11669_ = v___y_11684_;
v___y_11670_ = v___y_11691_;
v___y_11671_ = v___y_11684_;
v___y_11672_ = v___y_11688_;
v___y_11673_ = v___y_11684_;
goto v___jp_11667_;
}
else
{
uint32_t v___x_11695_;
v___x_11695_ = 3;
v___y_11668_ = v___y_11683_;
v___y_11669_ = v___y_11684_;
v___y_11670_ = v___y_11691_;
v___y_11671_ = v___x_11695_;
v___y_11672_ = v___y_11688_;
v___y_11673_ = v___y_11684_;
goto v___jp_11667_;
}
}
}
else
{
uint8_t v___x_11696_;
v___x_11696_ = lean_uint32_dec_eq(v_expectedServerRev_11635_, v_serverRev_11633_);
if (v___x_11696_ == 0)
{
uint32_t v___x_11697_;
v___x_11697_ = 2;
v___y_11668_ = v___y_11683_;
v___y_11669_ = v___y_11684_;
v___y_11670_ = v___y_11691_;
v___y_11671_ = v___x_11697_;
v___y_11672_ = v___y_11688_;
v___y_11673_ = v___y_11684_;
goto v___jp_11667_;
}
else
{
uint32_t v___x_11698_;
v___x_11698_ = 5;
v___y_11668_ = v___y_11683_;
v___y_11669_ = v___y_11684_;
v___y_11670_ = v___y_11691_;
v___y_11671_ = v___x_11698_;
v___y_11672_ = v___y_11688_;
v___y_11673_ = v___y_11684_;
goto v___jp_11667_;
}
}
}
else
{
uint32_t v___x_11699_;
v___x_11699_ = 2;
v___y_11668_ = v___y_11683_;
v___y_11669_ = v___y_11684_;
v___y_11670_ = v___y_11691_;
v___y_11671_ = v___x_11699_;
v___y_11672_ = v___y_11688_;
v___y_11673_ = v___y_11684_;
goto v___jp_11667_;
}
}
else
{
uint32_t v___x_11700_; uint32_t v___x_11701_;
v___x_11700_ = 1;
v___x_11701_ = 256;
v___y_11668_ = v___y_11683_;
v___y_11669_ = v___y_11684_;
v___y_11670_ = v___y_11691_;
v___y_11671_ = v___x_11700_;
v___y_11672_ = v___y_11688_;
v___y_11673_ = v___x_11701_;
goto v___jp_11667_;
}
}
v___jp_11702_:
{
if (v___y_11713_ == 0)
{
if (v___y_11707_ == 0)
{
if (v___y_11709_ == 0)
{
v___y_11683_ = v___y_11704_;
v___y_11684_ = v___y_11703_;
v___y_11685_ = v___y_11706_;
v___y_11686_ = v___y_11705_;
v___y_11687_ = v___y_11708_;
v___y_11688_ = v___y_11707_;
v___y_11689_ = v___y_11711_;
v___y_11690_ = v___y_11713_;
v___y_11691_ = v___y_11712_;
goto v___jp_11682_;
}
else
{
v___y_11683_ = v___y_11704_;
v___y_11684_ = v___y_11703_;
v___y_11685_ = v___y_11706_;
v___y_11686_ = v___y_11705_;
v___y_11687_ = v___y_11708_;
v___y_11688_ = v___y_11707_;
v___y_11689_ = v___y_11711_;
v___y_11690_ = v___y_11713_;
v___y_11691_ = v___y_11710_;
goto v___jp_11682_;
}
}
else
{
v___y_11683_ = v___y_11704_;
v___y_11684_ = v___y_11703_;
v___y_11685_ = v___y_11706_;
v___y_11686_ = v___y_11705_;
v___y_11687_ = v___y_11708_;
v___y_11688_ = v___y_11707_;
v___y_11689_ = v___y_11711_;
v___y_11690_ = v___y_11713_;
v___y_11691_ = v___y_11712_;
goto v___jp_11682_;
}
}
else
{
v___y_11683_ = v___y_11704_;
v___y_11684_ = v___y_11703_;
v___y_11685_ = v___y_11706_;
v___y_11686_ = v___y_11705_;
v___y_11687_ = v___y_11708_;
v___y_11688_ = v___y_11707_;
v___y_11689_ = v___y_11711_;
v___y_11690_ = v___y_11713_;
v___y_11691_ = v___y_11712_;
goto v___jp_11682_;
}
}
v___jp_11714_:
{
if (v___y_11723_ == 0)
{
v___y_11703_ = v___y_11717_;
v___y_11704_ = v___y_11716_;
v___y_11705_ = v___y_11719_;
v___y_11706_ = v___y_11718_;
v___y_11707_ = v___y_11721_;
v___y_11708_ = v___y_11720_;
v___y_11709_ = v___y_11722_;
v___y_11710_ = v___y_11726_;
v___y_11711_ = v___y_11724_;
v___y_11712_ = v___y_11725_;
v___y_11713_ = v___y_11715_;
goto v___jp_11702_;
}
else
{
v___y_11703_ = v___y_11717_;
v___y_11704_ = v___y_11716_;
v___y_11705_ = v___y_11719_;
v___y_11706_ = v___y_11718_;
v___y_11707_ = v___y_11721_;
v___y_11708_ = v___y_11720_;
v___y_11709_ = v___y_11722_;
v___y_11710_ = v___y_11726_;
v___y_11711_ = v___y_11724_;
v___y_11712_ = v___y_11725_;
v___y_11713_ = v___y_11725_;
goto v___jp_11702_;
}
}
v___jp_11727_:
{
uint8_t v___x_11739_;
v___x_11739_ = lean_uint64_dec_eq(v_clientMsgId_11636_, v_trackedMsgId_11637_);
v___y_11715_ = v___y_11729_;
v___y_11716_ = v___y_11738_;
v___y_11717_ = v___y_11728_;
v___y_11718_ = v___y_11731_;
v___y_11719_ = v___y_11730_;
v___y_11720_ = v___y_11733_;
v___y_11721_ = v___y_11732_;
v___y_11722_ = v___y_11734_;
v___y_11723_ = v___y_11735_;
v___y_11724_ = v___y_11736_;
v___y_11725_ = v___y_11737_;
v___y_11726_ = v___x_11739_;
goto v___jp_11714_;
}
v___jp_11740_:
{
if (v___y_11750_ == 0)
{
v___y_11715_ = v___y_11743_;
v___y_11716_ = v___y_11752_;
v___y_11717_ = v___y_11742_;
v___y_11718_ = v___y_11745_;
v___y_11719_ = v___y_11744_;
v___y_11720_ = v___y_11747_;
v___y_11721_ = v___y_11746_;
v___y_11722_ = v___y_11748_;
v___y_11723_ = v___y_11749_;
v___y_11724_ = v___y_11750_;
v___y_11725_ = v___y_11751_;
v___y_11726_ = v___y_11741_;
goto v___jp_11714_;
}
else
{
if (v___y_11744_ == 0)
{
v___y_11728_ = v___y_11742_;
v___y_11729_ = v___y_11743_;
v___y_11730_ = v___y_11744_;
v___y_11731_ = v___y_11745_;
v___y_11732_ = v___y_11746_;
v___y_11733_ = v___y_11747_;
v___y_11734_ = v___y_11748_;
v___y_11735_ = v___y_11749_;
v___y_11736_ = v___y_11750_;
v___y_11737_ = v___y_11751_;
v___y_11738_ = v___y_11752_;
goto v___jp_11727_;
}
else
{
v___y_11715_ = v___y_11743_;
v___y_11716_ = v___y_11752_;
v___y_11717_ = v___y_11742_;
v___y_11718_ = v___y_11745_;
v___y_11719_ = v___y_11744_;
v___y_11720_ = v___y_11747_;
v___y_11721_ = v___y_11746_;
v___y_11722_ = v___y_11748_;
v___y_11723_ = v___y_11749_;
v___y_11724_ = v___y_11750_;
v___y_11725_ = v___y_11751_;
v___y_11726_ = v___y_11743_;
goto v___jp_11714_;
}
}
}
v___jp_11753_:
{
uint8_t v___x_11765_;
v___x_11765_ = lean_uint8_dec_eq(v_op_11632_, v___x_11681_);
if (v___x_11765_ == 0)
{
v___y_11741_ = v___y_11754_;
v___y_11742_ = v___y_11756_;
v___y_11743_ = v___y_11755_;
v___y_11744_ = v___y_11764_;
v___y_11745_ = v___y_11757_;
v___y_11746_ = v___y_11759_;
v___y_11747_ = v___y_11758_;
v___y_11748_ = v___y_11760_;
v___y_11749_ = v___y_11761_;
v___y_11750_ = v___y_11762_;
v___y_11751_ = v___y_11763_;
v___y_11752_ = v_serverRev_11633_;
goto v___jp_11740_;
}
else
{
uint32_t v___x_11766_; uint32_t v___x_11767_;
v___x_11766_ = 1;
v___x_11767_ = lean_uint32_add(v_serverRev_11633_, v___x_11766_);
v___y_11741_ = v___y_11754_;
v___y_11742_ = v___y_11756_;
v___y_11743_ = v___y_11755_;
v___y_11744_ = v___y_11764_;
v___y_11745_ = v___y_11757_;
v___y_11746_ = v___y_11759_;
v___y_11747_ = v___y_11758_;
v___y_11748_ = v___y_11760_;
v___y_11749_ = v___y_11761_;
v___y_11750_ = v___y_11762_;
v___y_11751_ = v___y_11763_;
v___y_11752_ = v___x_11767_;
goto v___jp_11740_;
}
}
v___jp_11768_:
{
uint8_t v___x_11781_;
v___x_11781_ = lean_uint32_dec_lt(v_incomingServerRev_11634_, v_serverRev_11633_);
if (v___x_11781_ == 0)
{
v___y_11715_ = v___y_11771_;
v___y_11716_ = v___y_11780_;
v___y_11717_ = v___y_11770_;
v___y_11718_ = v___y_11773_;
v___y_11719_ = v___y_11772_;
v___y_11720_ = v___y_11775_;
v___y_11721_ = v___y_11774_;
v___y_11722_ = v___y_11776_;
v___y_11723_ = v___y_11777_;
v___y_11724_ = v___y_11778_;
v___y_11725_ = v___y_11779_;
v___y_11726_ = v___y_11769_;
goto v___jp_11714_;
}
else
{
v___y_11715_ = v___y_11771_;
v___y_11716_ = v___y_11780_;
v___y_11717_ = v___y_11770_;
v___y_11718_ = v___y_11773_;
v___y_11719_ = v___y_11772_;
v___y_11720_ = v___y_11775_;
v___y_11721_ = v___y_11774_;
v___y_11722_ = v___y_11776_;
v___y_11723_ = v___y_11777_;
v___y_11724_ = v___y_11778_;
v___y_11725_ = v___y_11779_;
v___y_11726_ = v___y_11771_;
goto v___jp_11714_;
}
}
v___jp_11782_:
{
if (v___y_11793_ == 0)
{
if (v___y_11787_ == 0)
{
v___y_11741_ = v___y_11783_;
v___y_11742_ = v___y_11785_;
v___y_11743_ = v___y_11784_;
v___y_11744_ = v___y_11793_;
v___y_11745_ = v___y_11786_;
v___y_11746_ = v___y_11788_;
v___y_11747_ = v___y_11787_;
v___y_11748_ = v___y_11789_;
v___y_11749_ = v___y_11790_;
v___y_11750_ = v___y_11791_;
v___y_11751_ = v___y_11792_;
v___y_11752_ = v_serverRev_11633_;
goto v___jp_11740_;
}
else
{
v___y_11769_ = v___y_11783_;
v___y_11770_ = v___y_11785_;
v___y_11771_ = v___y_11784_;
v___y_11772_ = v___y_11793_;
v___y_11773_ = v___y_11786_;
v___y_11774_ = v___y_11788_;
v___y_11775_ = v___y_11787_;
v___y_11776_ = v___y_11789_;
v___y_11777_ = v___y_11790_;
v___y_11778_ = v___y_11791_;
v___y_11779_ = v___y_11792_;
v___y_11780_ = v_serverRev_11633_;
goto v___jp_11768_;
}
}
else
{
if (v___y_11787_ == 0)
{
v___y_11754_ = v___y_11783_;
v___y_11755_ = v___y_11784_;
v___y_11756_ = v___y_11785_;
v___y_11757_ = v___y_11786_;
v___y_11758_ = v___y_11787_;
v___y_11759_ = v___y_11788_;
v___y_11760_ = v___y_11789_;
v___y_11761_ = v___y_11790_;
v___y_11762_ = v___y_11791_;
v___y_11763_ = v___y_11792_;
v___y_11764_ = v___y_11793_;
goto v___jp_11753_;
}
else
{
v___y_11769_ = v___y_11783_;
v___y_11770_ = v___y_11785_;
v___y_11771_ = v___y_11784_;
v___y_11772_ = v___y_11793_;
v___y_11773_ = v___y_11786_;
v___y_11774_ = v___y_11788_;
v___y_11775_ = v___y_11787_;
v___y_11776_ = v___y_11789_;
v___y_11777_ = v___y_11790_;
v___y_11778_ = v___y_11791_;
v___y_11779_ = v___y_11792_;
v___y_11780_ = v_incomingServerRev_11634_;
goto v___jp_11768_;
}
}
}
v___jp_11794_:
{
if (v___y_11799_ == 0)
{
uint8_t v___x_11806_;
v___x_11806_ = lean_uint8_dec_eq(v_op_11632_, v___x_11681_);
if (v___x_11806_ == 0)
{
if (v___y_11803_ == 0)
{
v___y_11783_ = v___y_11795_;
v___y_11784_ = v___y_11797_;
v___y_11785_ = v___y_11796_;
v___y_11786_ = v___y_11805_;
v___y_11787_ = v___y_11799_;
v___y_11788_ = v___y_11798_;
v___y_11789_ = v___y_11800_;
v___y_11790_ = v___y_11802_;
v___y_11791_ = v___y_11803_;
v___y_11792_ = v___y_11804_;
v___y_11793_ = v___y_11801_;
goto v___jp_11782_;
}
else
{
if (v___y_11800_ == 0)
{
v___y_11728_ = v___y_11796_;
v___y_11729_ = v___y_11797_;
v___y_11730_ = v___y_11800_;
v___y_11731_ = v___y_11805_;
v___y_11732_ = v___y_11798_;
v___y_11733_ = v___y_11799_;
v___y_11734_ = v___y_11800_;
v___y_11735_ = v___y_11802_;
v___y_11736_ = v___y_11803_;
v___y_11737_ = v___y_11804_;
v___y_11738_ = v_serverRev_11633_;
goto v___jp_11727_;
}
else
{
if (v___y_11805_ == 0)
{
v___y_11754_ = v___y_11795_;
v___y_11755_ = v___y_11797_;
v___y_11756_ = v___y_11796_;
v___y_11757_ = v___y_11805_;
v___y_11758_ = v___y_11799_;
v___y_11759_ = v___y_11798_;
v___y_11760_ = v___y_11800_;
v___y_11761_ = v___y_11802_;
v___y_11762_ = v___y_11803_;
v___y_11763_ = v___y_11804_;
v___y_11764_ = v___y_11803_;
goto v___jp_11753_;
}
else
{
v___y_11783_ = v___y_11795_;
v___y_11784_ = v___y_11797_;
v___y_11785_ = v___y_11796_;
v___y_11786_ = v___y_11805_;
v___y_11787_ = v___y_11799_;
v___y_11788_ = v___y_11798_;
v___y_11789_ = v___y_11800_;
v___y_11790_ = v___y_11802_;
v___y_11791_ = v___y_11803_;
v___y_11792_ = v___y_11804_;
v___y_11793_ = v___x_11806_;
goto v___jp_11782_;
}
}
}
}
else
{
uint8_t v___x_11807_;
v___x_11807_ = lean_uint32_dec_eq(v_expectedServerRev_11635_, v_serverRev_11633_);
if (v___x_11807_ == 0)
{
v___y_11783_ = v___y_11795_;
v___y_11784_ = v___y_11797_;
v___y_11785_ = v___y_11796_;
v___y_11786_ = v___y_11805_;
v___y_11787_ = v___y_11799_;
v___y_11788_ = v___y_11798_;
v___y_11789_ = v___y_11800_;
v___y_11790_ = v___y_11802_;
v___y_11791_ = v___y_11803_;
v___y_11792_ = v___y_11804_;
v___y_11793_ = v___x_11807_;
goto v___jp_11782_;
}
else
{
uint32_t v___x_11808_; uint8_t v___x_11809_;
v___x_11808_ = 4294967295;
v___x_11809_ = lean_uint32_dec_lt(v_serverRev_11633_, v___x_11808_);
v___y_11783_ = v___y_11795_;
v___y_11784_ = v___y_11797_;
v___y_11785_ = v___y_11796_;
v___y_11786_ = v___y_11805_;
v___y_11787_ = v___y_11799_;
v___y_11788_ = v___y_11798_;
v___y_11789_ = v___y_11800_;
v___y_11790_ = v___y_11802_;
v___y_11791_ = v___y_11803_;
v___y_11792_ = v___y_11804_;
v___y_11793_ = v___x_11809_;
goto v___jp_11782_;
}
}
}
else
{
uint8_t v___x_11810_;
v___x_11810_ = lean_uint32_dec_le(v_serverRev_11633_, v_incomingServerRev_11634_);
v___y_11783_ = v___y_11795_;
v___y_11784_ = v___y_11797_;
v___y_11785_ = v___y_11796_;
v___y_11786_ = v___y_11805_;
v___y_11787_ = v___y_11799_;
v___y_11788_ = v___y_11798_;
v___y_11789_ = v___y_11800_;
v___y_11790_ = v___y_11802_;
v___y_11791_ = v___y_11803_;
v___y_11792_ = v___y_11804_;
v___y_11793_ = v___x_11810_;
goto v___jp_11782_;
}
}
v___jp_11811_:
{
uint8_t v___x_11821_; uint8_t v___x_11822_;
v___x_11821_ = 2;
v___x_11822_ = lean_uint8_dec_eq(v_op_11632_, v___x_11821_);
if (v___x_11822_ == 0)
{
v___y_11795_ = v___y_11812_;
v___y_11796_ = v___y_11814_;
v___y_11797_ = v___y_11813_;
v___y_11798_ = v___y_11820_;
v___y_11799_ = v___y_11815_;
v___y_11800_ = v___y_11816_;
v___y_11801_ = v___y_11818_;
v___y_11802_ = v___y_11817_;
v___y_11803_ = v___x_11822_;
v___y_11804_ = v___y_11819_;
v___y_11805_ = v___x_11822_;
goto v___jp_11794_;
}
else
{
if (v___y_11816_ == 0)
{
v___y_11795_ = v___y_11812_;
v___y_11796_ = v___y_11814_;
v___y_11797_ = v___y_11813_;
v___y_11798_ = v___y_11820_;
v___y_11799_ = v___y_11815_;
v___y_11800_ = v___y_11816_;
v___y_11801_ = v___y_11818_;
v___y_11802_ = v___y_11817_;
v___y_11803_ = v___x_11822_;
v___y_11804_ = v___y_11819_;
v___y_11805_ = v___y_11816_;
goto v___jp_11794_;
}
else
{
uint8_t v___x_11823_;
v___x_11823_ = lean_uint64_dec_eq(v_clientMsgId_11636_, v_trackedMsgId_11637_);
if (v___x_11823_ == 0)
{
if (v___y_11817_ == 0)
{
v___y_11795_ = v___y_11812_;
v___y_11796_ = v___y_11814_;
v___y_11797_ = v___y_11813_;
v___y_11798_ = v___y_11820_;
v___y_11799_ = v___y_11815_;
v___y_11800_ = v___y_11816_;
v___y_11801_ = v___y_11818_;
v___y_11802_ = v___y_11817_;
v___y_11803_ = v___x_11822_;
v___y_11804_ = v___y_11819_;
v___y_11805_ = v___y_11816_;
goto v___jp_11794_;
}
else
{
v___y_11795_ = v___y_11812_;
v___y_11796_ = v___y_11814_;
v___y_11797_ = v___y_11813_;
v___y_11798_ = v___y_11820_;
v___y_11799_ = v___y_11815_;
v___y_11800_ = v___y_11816_;
v___y_11801_ = v___y_11818_;
v___y_11802_ = v___y_11817_;
v___y_11803_ = v___x_11822_;
v___y_11804_ = v___y_11819_;
v___y_11805_ = v___y_11819_;
goto v___jp_11794_;
}
}
else
{
v___y_11795_ = v___y_11812_;
v___y_11796_ = v___y_11814_;
v___y_11797_ = v___y_11813_;
v___y_11798_ = v___y_11820_;
v___y_11799_ = v___y_11815_;
v___y_11800_ = v___y_11816_;
v___y_11801_ = v___y_11818_;
v___y_11802_ = v___y_11817_;
v___y_11803_ = v___x_11822_;
v___y_11804_ = v___y_11819_;
v___y_11805_ = v___y_11813_;
goto v___jp_11794_;
}
}
}
}
v___jp_11824_:
{
if (v___y_11831_ == 0)
{
v___y_11812_ = v___y_11825_;
v___y_11813_ = v___y_11827_;
v___y_11814_ = v___y_11826_;
v___y_11815_ = v___y_11828_;
v___y_11816_ = v___y_11829_;
v___y_11817_ = v___y_11830_;
v___y_11818_ = v___y_11831_;
v___y_11819_ = v___y_11832_;
v___y_11820_ = v___y_11833_;
goto v___jp_11811_;
}
else
{
v___y_11812_ = v___y_11825_;
v___y_11813_ = v___y_11827_;
v___y_11814_ = v___y_11826_;
v___y_11815_ = v___y_11828_;
v___y_11816_ = v___y_11829_;
v___y_11817_ = v___y_11830_;
v___y_11818_ = v___y_11831_;
v___y_11819_ = v___y_11832_;
v___y_11820_ = v___y_11827_;
goto v___jp_11811_;
}
}
v___jp_11834_:
{
uint8_t v___x_11843_;
v___x_11843_ = lean_uint8_dec_eq(v_op_11632_, v___y_11838_);
if (v___x_11843_ == 0)
{
v___y_11825_ = v___y_11835_;
v___y_11826_ = v___y_11836_;
v___y_11827_ = v___y_11837_;
v___y_11828_ = v___x_11843_;
v___y_11829_ = v___y_11839_;
v___y_11830_ = v___y_11840_;
v___y_11831_ = v___y_11842_;
v___y_11832_ = v___y_11841_;
v___y_11833_ = v___x_11843_;
goto v___jp_11824_;
}
else
{
uint8_t v___x_11844_;
v___x_11844_ = lean_uint32_dec_le(v_serverRev_11633_, v_incomingServerRev_11634_);
if (v___x_11844_ == 0)
{
v___y_11825_ = v___y_11835_;
v___y_11826_ = v___y_11836_;
v___y_11827_ = v___y_11837_;
v___y_11828_ = v___x_11843_;
v___y_11829_ = v___y_11839_;
v___y_11830_ = v___y_11840_;
v___y_11831_ = v___y_11842_;
v___y_11832_ = v___y_11841_;
v___y_11833_ = v___x_11844_;
goto v___jp_11824_;
}
else
{
if (v___y_11839_ == 0)
{
v___y_11825_ = v___y_11835_;
v___y_11826_ = v___y_11836_;
v___y_11827_ = v___y_11837_;
v___y_11828_ = v___x_11843_;
v___y_11829_ = v___y_11839_;
v___y_11830_ = v___y_11840_;
v___y_11831_ = v___y_11842_;
v___y_11832_ = v___y_11841_;
v___y_11833_ = v___y_11839_;
goto v___jp_11824_;
}
else
{
if (v___y_11840_ == 0)
{
v___y_11825_ = v___y_11835_;
v___y_11826_ = v___y_11836_;
v___y_11827_ = v___y_11837_;
v___y_11828_ = v___x_11843_;
v___y_11829_ = v___y_11839_;
v___y_11830_ = v___y_11840_;
v___y_11831_ = v___y_11842_;
v___y_11832_ = v___y_11841_;
v___y_11833_ = v___y_11840_;
goto v___jp_11824_;
}
else
{
if (v___y_11835_ == 0)
{
v___y_11825_ = v___y_11835_;
v___y_11826_ = v___y_11836_;
v___y_11827_ = v___y_11837_;
v___y_11828_ = v___x_11843_;
v___y_11829_ = v___y_11839_;
v___y_11830_ = v___y_11840_;
v___y_11831_ = v___y_11842_;
v___y_11832_ = v___y_11841_;
v___y_11833_ = v___y_11835_;
goto v___jp_11824_;
}
else
{
uint8_t v___x_11845_;
v___x_11845_ = lean_uint8_dec_eq(v_optimisticSending_11641_, v___y_11838_);
if (v___x_11845_ == 0)
{
v___y_11825_ = v___y_11835_;
v___y_11826_ = v___y_11836_;
v___y_11827_ = v___y_11837_;
v___y_11828_ = v___x_11843_;
v___y_11829_ = v___y_11839_;
v___y_11830_ = v___y_11840_;
v___y_11831_ = v___y_11842_;
v___y_11832_ = v___y_11841_;
v___y_11833_ = v___x_11845_;
goto v___jp_11824_;
}
else
{
uint8_t v___x_11846_;
v___x_11846_ = lean_uint64_dec_lt(v_postedAfterSeq_11639_, v_turnSeq_11640_);
v___y_11825_ = v___y_11835_;
v___y_11826_ = v___y_11836_;
v___y_11827_ = v___y_11837_;
v___y_11828_ = v___x_11843_;
v___y_11829_ = v___y_11839_;
v___y_11830_ = v___y_11840_;
v___y_11831_ = v___y_11842_;
v___y_11832_ = v___y_11841_;
v___y_11833_ = v___x_11846_;
goto v___jp_11824_;
}
}
}
}
}
}
}
v___jp_11847_:
{
uint8_t v___x_11857_;
v___x_11857_ = lean_uint8_dec_eq(v_op_11632_, v___x_11679_);
if (v___x_11857_ == 0)
{
v___y_11835_ = v___y_11848_;
v___y_11836_ = v___y_11850_;
v___y_11837_ = v___y_11849_;
v___y_11838_ = v___y_11851_;
v___y_11839_ = v___y_11852_;
v___y_11840_ = v___y_11853_;
v___y_11841_ = v___y_11855_;
v___y_11842_ = v___x_11857_;
goto v___jp_11834_;
}
else
{
if (v___y_11854_ == 0)
{
v___y_11835_ = v___y_11848_;
v___y_11836_ = v___y_11850_;
v___y_11837_ = v___y_11849_;
v___y_11838_ = v___y_11851_;
v___y_11839_ = v___y_11852_;
v___y_11840_ = v___y_11853_;
v___y_11841_ = v___y_11855_;
v___y_11842_ = v___y_11856_;
goto v___jp_11834_;
}
else
{
v___y_11835_ = v___y_11848_;
v___y_11836_ = v___y_11850_;
v___y_11837_ = v___y_11849_;
v___y_11838_ = v___y_11851_;
v___y_11839_ = v___y_11852_;
v___y_11840_ = v___y_11853_;
v___y_11841_ = v___y_11855_;
v___y_11842_ = v___y_11849_;
goto v___jp_11834_;
}
}
}
v___jp_11858_:
{
uint8_t v___x_11864_; uint8_t v_notDelivered_11865_; uint8_t v_serverUnlisted_11866_;
v___x_11864_ = 0;
v_notDelivered_11865_ = lean_uint8_dec_eq(v_alreadyDelivered_11644_, v___x_11864_);
v_serverUnlisted_11866_ = lean_uint8_dec_eq(v_serverListed_11642_, v___x_11864_);
if (v___y_11863_ == 0)
{
v___y_11848_ = v_serverUnlisted_11866_;
v___y_11849_ = v___y_11859_;
v___y_11850_ = v___y_11860_;
v___y_11851_ = v___x_11864_;
v___y_11852_ = v___y_11863_;
v___y_11853_ = v_notDelivered_11865_;
v___y_11854_ = v___y_11863_;
v___y_11855_ = v___y_11862_;
v___y_11856_ = v___y_11863_;
goto v___jp_11847_;
}
else
{
if (v_notDelivered_11865_ == 0)
{
v___y_11848_ = v_serverUnlisted_11866_;
v___y_11849_ = v___y_11859_;
v___y_11850_ = v___y_11860_;
v___y_11851_ = v___x_11864_;
v___y_11852_ = v___y_11863_;
v___y_11853_ = v_notDelivered_11865_;
v___y_11854_ = v_notDelivered_11865_;
v___y_11855_ = v___y_11862_;
v___y_11856_ = v_notDelivered_11865_;
goto v___jp_11847_;
}
else
{
uint8_t v___x_11867_; uint8_t v___x_11868_;
v___x_11867_ = lean_uint64_dec_eq(v_deliveredMsgId_11638_, v_clientMsgId_11636_);
v___x_11868_ = lean_uint64_dec_eq(v_deliveredMsgId_11638_, v___y_11861_);
if (v___x_11868_ == 0)
{
v___y_11848_ = v_serverUnlisted_11866_;
v___y_11849_ = v___y_11859_;
v___y_11850_ = v___y_11860_;
v___y_11851_ = v___x_11864_;
v___y_11852_ = v___y_11863_;
v___y_11853_ = v_notDelivered_11865_;
v___y_11854_ = v___x_11867_;
v___y_11855_ = v___y_11862_;
v___y_11856_ = v___x_11868_;
goto v___jp_11847_;
}
else
{
uint8_t v___x_11869_;
v___x_11869_ = lean_uint8_dec_eq(v_contentMatched_11643_, v___x_11681_);
if (v___x_11869_ == 0)
{
v___y_11848_ = v_serverUnlisted_11866_;
v___y_11849_ = v___y_11859_;
v___y_11850_ = v___y_11860_;
v___y_11851_ = v___x_11864_;
v___y_11852_ = v___y_11863_;
v___y_11853_ = v_notDelivered_11865_;
v___y_11854_ = v___x_11867_;
v___y_11855_ = v___y_11862_;
v___y_11856_ = v___x_11869_;
goto v___jp_11847_;
}
else
{
uint8_t v___x_11870_;
v___x_11870_ = lean_uint64_dec_lt(v_postedAfterSeq_11639_, v_turnSeq_11640_);
v___y_11848_ = v_serverUnlisted_11866_;
v___y_11849_ = v___y_11859_;
v___y_11850_ = v___y_11860_;
v___y_11851_ = v___x_11864_;
v___y_11852_ = v___y_11863_;
v___y_11853_ = v_notDelivered_11865_;
v___y_11854_ = v___x_11867_;
v___y_11855_ = v___y_11862_;
v___y_11856_ = v___x_11870_;
goto v___jp_11847_;
}
}
}
}
}
v___jp_11871_:
{
if (v_opOk_11680_ == 0)
{
goto v___jp_11675_;
}
else
{
if (v___y_11872_ == 0)
{
goto v___jp_11675_;
}
else
{
uint32_t v___x_11873_; uint8_t v___x_11874_;
v___x_11873_ = 0;
v___x_11874_ = lean_uint32_dec_eq(v_serverRev_11633_, v___x_11873_);
if (v___x_11874_ == 0)
{
uint64_t v___x_11875_; uint8_t v___x_11876_;
v___x_11875_ = 0ULL;
v___x_11876_ = lean_uint64_dec_eq(v_clientMsgId_11636_, v___x_11875_);
if (v___x_11876_ == 0)
{
v___y_11859_ = v___y_11872_;
v___y_11860_ = v___x_11873_;
v___y_11861_ = v___x_11875_;
v___y_11862_ = v___x_11874_;
v___y_11863_ = v___y_11872_;
goto v___jp_11858_;
}
else
{
v___y_11859_ = v___y_11872_;
v___y_11860_ = v___x_11873_;
v___y_11861_ = v___x_11875_;
v___y_11862_ = v___x_11874_;
v___y_11863_ = v___x_11874_;
goto v___jp_11858_;
}
}
else
{
goto v___jp_11675_;
}
}
}
}
}
}

LEAN_EXPORT uint64_t orb_transport_epoch_step(uint8_t v_mode_11909_, uint8_t v_eventKind_11910_, uint8_t v_everReady_11911_, uint8_t v_stickyUnsupported_11912_, uint8_t v_endpointClass_11913_, uint8_t v_prevEndpointClass_11914_, uint8_t v_hasSinceSeq_11915_, uint32_t v_failureStreak_11916_, uint32_t v_failThreshold_11917_, uint32_t v_httpStatus_11918_, uint32_t v_sinceSeq32_11919_, uint64_t v_nowMs_11920_, uint64_t v_cooldownUntilMs_11921_){
_start:
{
uint32_t v___y_11923_; uint32_t v___y_11924_; uint32_t v___y_11931_; uint32_t v___y_11932_; uint32_t v___y_11933_; uint8_t v___y_11934_; uint32_t v___y_11935_; uint8_t v___y_11936_; uint32_t v___y_11937_; uint32_t v___y_11938_; uint32_t v___y_11939_; uint32_t v___y_11951_; uint32_t v___y_11952_; uint32_t v___y_11953_; uint8_t v___y_11954_; uint32_t v___y_11955_; uint8_t v___y_11956_; uint32_t v___y_11957_; uint32_t v___y_11960_; uint32_t v___y_11961_; uint8_t v___y_11962_; uint32_t v___y_11963_; uint8_t v___y_11964_; uint32_t v___y_11965_; uint32_t v___y_11966_; uint32_t v___y_11971_; uint32_t v___y_11972_; uint32_t v___y_11973_; uint8_t v___y_11974_; uint8_t v___y_11975_; uint8_t v___y_11976_; uint32_t v___y_11977_; uint32_t v___y_11984_; uint32_t v___y_11985_; uint8_t v___y_11986_; uint8_t v___y_11987_; uint8_t v___y_11988_; uint32_t v___y_11992_; uint32_t v___y_11993_; uint8_t v___y_11994_; uint8_t v___y_11995_; uint8_t v___y_11996_; uint32_t v___y_11997_; uint32_t v___y_12000_; uint32_t v___y_12001_; uint8_t v___y_12002_; uint8_t v___y_12003_; uint8_t v___y_12004_; uint8_t v___y_12005_; uint32_t v___y_12008_; uint32_t v___y_12009_; uint8_t v___y_12010_; uint8_t v___y_12011_; uint8_t v___y_12012_; uint8_t v___y_12013_; uint32_t v___y_12016_; uint32_t v___y_12017_; uint8_t v___y_12018_; uint8_t v___y_12019_; uint8_t v___y_12020_; uint8_t v___y_12021_; uint8_t v___y_12022_; uint8_t v___x_12023_; uint32_t v___y_12025_; uint32_t v___y_12026_; uint8_t v___y_12027_; uint8_t v___y_12028_; uint8_t v___y_12029_; uint8_t v___y_12030_; uint8_t v___y_12031_; uint32_t v___y_12036_; uint8_t v___y_12037_; uint8_t v___y_12038_; uint8_t v___y_12039_; uint8_t v___y_12040_; uint8_t v___y_12041_; uint32_t v___y_12042_; uint32_t v___y_12043_; uint32_t v___y_12055_; uint8_t v___y_12056_; uint8_t v___y_12057_; uint8_t v___y_12058_; uint8_t v___y_12059_; uint8_t v___y_12060_; uint8_t v___y_12061_; uint32_t v___y_12062_; uint32_t v___y_12068_; uint8_t v___y_12069_; uint8_t v___y_12070_; uint8_t v___y_12071_; uint8_t v___y_12072_; uint8_t v___y_12073_; uint32_t v___y_12074_; uint8_t v___y_12075_; uint32_t v___y_12076_; uint8_t v___y_12077_; uint32_t v___y_12083_; uint8_t v___y_12084_; uint8_t v___y_12085_; uint8_t v___y_12086_; uint8_t v___y_12087_; uint8_t v___y_12088_; uint32_t v___y_12089_; uint32_t v___y_12090_; uint32_t v___y_12099_; uint8_t v___y_12100_; uint8_t v___y_12101_; uint8_t v___y_12102_; uint8_t v___y_12103_; uint8_t v___y_12104_; uint32_t v___y_12105_; uint8_t v___y_12108_; uint8_t v___y_12109_; uint8_t v___y_12110_; uint8_t v___y_12111_; uint8_t v___y_12112_; uint8_t v___y_12118_; uint8_t v___y_12119_; uint8_t v___y_12120_; uint8_t v___y_12121_; uint8_t v___y_12126_; uint8_t v___y_12127_; uint8_t v___y_12128_; uint8_t v___y_12131_; uint8_t v___y_12132_; uint8_t v___y_12133_; uint8_t v___y_12140_; uint8_t v___x_12145_;
v___x_12023_ = 2;
v___x_12145_ = lean_uint8_dec_le(v_mode_11909_, v___x_12023_);
if (v___x_12145_ == 0)
{
v___y_12140_ = v___x_12145_;
goto v___jp_12139_;
}
else
{
uint8_t v___x_12146_; uint8_t v___x_12147_;
v___x_12146_ = 4;
v___x_12147_ = lean_uint8_dec_le(v_eventKind_11910_, v___x_12146_);
if (v___x_12147_ == 0)
{
v___y_12140_ = v___x_12147_;
goto v___jp_12139_;
}
else
{
uint8_t v___x_12148_; uint8_t v___x_12149_;
v___x_12148_ = 1;
v___x_12149_ = lean_uint8_dec_le(v_everReady_11911_, v___x_12148_);
if (v___x_12149_ == 0)
{
v___y_12140_ = v___x_12149_;
goto v___jp_12139_;
}
else
{
uint8_t v___x_12150_;
v___x_12150_ = lean_uint8_dec_le(v_stickyUnsupported_11912_, v___x_12148_);
if (v___x_12150_ == 0)
{
v___y_12140_ = v___x_12150_;
goto v___jp_12139_;
}
else
{
uint8_t v___x_12151_; uint8_t v___x_12152_;
v___x_12151_ = 3;
v___x_12152_ = lean_uint8_dec_le(v_endpointClass_11913_, v___x_12151_);
if (v___x_12152_ == 0)
{
v___y_12140_ = v___x_12152_;
goto v___jp_12139_;
}
else
{
uint8_t v___x_12153_;
v___x_12153_ = lean_uint8_dec_le(v_prevEndpointClass_11914_, v___x_12151_);
if (v___x_12153_ == 0)
{
v___y_12140_ = v___x_12153_;
goto v___jp_12139_;
}
else
{
uint8_t v___x_12154_;
v___x_12154_ = lean_uint8_dec_le(v_hasSinceSeq_11915_, v___x_12148_);
if (v___x_12154_ == 0)
{
v___y_12140_ = v___x_12154_;
goto v___jp_12139_;
}
else
{
uint32_t v___x_12155_; uint8_t v___x_12156_;
v___x_12155_ = 1;
v___x_12156_ = lean_uint32_dec_le(v___x_12155_, v_failThreshold_11917_);
v___y_12140_ = v___x_12156_;
goto v___jp_12139_;
}
}
}
}
}
}
}
v___jp_11922_:
{
uint64_t v___x_11925_; uint64_t v___x_11926_; uint64_t v___x_11927_; uint64_t v___x_11928_; uint64_t v___x_11929_;
v___x_11925_ = lean_uint32_to_uint64(v___y_11924_);
v___x_11926_ = lean_uint32_to_uint64(v___y_11923_);
v___x_11927_ = 32ULL;
v___x_11928_ = lean_uint64_shift_left(v___x_11926_, v___x_11927_);
v___x_11929_ = lean_uint64_lor(v___x_11925_, v___x_11928_);
return v___x_11929_;
}
v___jp_11930_:
{
if (v___y_11936_ == 0)
{
uint32_t v___x_11940_; uint32_t v___x_11941_; uint32_t v___x_11942_; uint32_t v___x_11943_; uint32_t v___x_11944_; uint32_t v___x_11945_; uint32_t v___x_11946_; uint32_t v___x_11947_; uint32_t v___x_11948_; uint32_t v___x_11949_;
v___x_11940_ = lean_uint8_to_uint32(v___y_11934_);
v___x_11941_ = 256;
v___x_11942_ = lean_uint32_lor(v___x_11940_, v___x_11941_);
v___x_11943_ = lean_uint32_lor(v___x_11942_, v___y_11938_);
v___x_11944_ = lean_uint32_lor(v___x_11943_, v___y_11935_);
v___x_11945_ = lean_uint32_lor(v___x_11944_, v___y_11933_);
v___x_11946_ = lean_uint32_lor(v___x_11945_, v___y_11937_);
v___x_11947_ = 16;
v___x_11948_ = lean_uint32_shift_left(v___y_11932_, v___x_11947_);
v___x_11949_ = lean_uint32_lor(v___x_11946_, v___x_11948_);
v___y_11923_ = v___y_11939_;
v___y_11924_ = v___x_11949_;
goto v___jp_11922_;
}
else
{
v___y_11923_ = v___y_11939_;
v___y_11924_ = v___y_11931_;
goto v___jp_11922_;
}
}
v___jp_11950_:
{
uint32_t v___x_11958_;
v___x_11958_ = 0;
v___y_11931_ = v___y_11951_;
v___y_11932_ = v___y_11952_;
v___y_11933_ = v___y_11953_;
v___y_11934_ = v___y_11954_;
v___y_11935_ = v___y_11955_;
v___y_11936_ = v___y_11956_;
v___y_11937_ = v___x_11958_;
v___y_11938_ = v___y_11957_;
v___y_11939_ = v___x_11958_;
goto v___jp_11930_;
}
v___jp_11959_:
{
uint8_t v___x_11967_; uint8_t v___x_11968_;
v___x_11967_ = 1;
v___x_11968_ = lean_uint8_dec_eq(v_hasSinceSeq_11915_, v___x_11967_);
if (v___x_11968_ == 0)
{
v___y_11951_ = v___y_11961_;
v___y_11952_ = v___y_11960_;
v___y_11953_ = v___y_11963_;
v___y_11954_ = v___y_11962_;
v___y_11955_ = v___y_11966_;
v___y_11956_ = v___y_11964_;
v___y_11957_ = v___y_11965_;
goto v___jp_11950_;
}
else
{
uint32_t v___x_11969_;
v___x_11969_ = 4096;
v___y_11931_ = v___y_11961_;
v___y_11932_ = v___y_11960_;
v___y_11933_ = v___y_11963_;
v___y_11934_ = v___y_11962_;
v___y_11935_ = v___y_11966_;
v___y_11936_ = v___y_11964_;
v___y_11937_ = v___x_11969_;
v___y_11938_ = v___y_11965_;
v___y_11939_ = v_sinceSeq32_11919_;
goto v___jp_11930_;
}
}
v___jp_11970_:
{
if (v___y_11975_ == 0)
{
uint32_t v___x_11978_;
v___x_11978_ = 0;
v___y_11951_ = v___y_11971_;
v___y_11952_ = v___y_11972_;
v___y_11953_ = v___y_11973_;
v___y_11954_ = v___y_11974_;
v___y_11955_ = v___x_11978_;
v___y_11956_ = v___y_11976_;
v___y_11957_ = v___y_11977_;
goto v___jp_11950_;
}
else
{
uint8_t v___x_11979_; uint8_t v___x_11980_;
v___x_11979_ = 1;
v___x_11980_ = lean_uint8_dec_eq(v___y_11974_, v___x_11979_);
if (v___x_11980_ == 0)
{
uint32_t v___x_11981_;
v___x_11981_ = 0;
v___y_11960_ = v___y_11972_;
v___y_11961_ = v___y_11971_;
v___y_11962_ = v___y_11974_;
v___y_11963_ = v___y_11973_;
v___y_11964_ = v___y_11976_;
v___y_11965_ = v___y_11977_;
v___y_11966_ = v___x_11981_;
goto v___jp_11959_;
}
else
{
uint32_t v___x_11982_;
v___x_11982_ = 1024;
v___y_11960_ = v___y_11972_;
v___y_11961_ = v___y_11971_;
v___y_11962_ = v___y_11974_;
v___y_11963_ = v___y_11973_;
v___y_11964_ = v___y_11976_;
v___y_11965_ = v___y_11977_;
v___y_11966_ = v___x_11982_;
goto v___jp_11959_;
}
}
}
v___jp_11983_:
{
uint32_t v___x_11989_; uint32_t v___x_11990_;
v___x_11989_ = 0;
v___x_11990_ = 512;
v___y_11971_ = v___y_11984_;
v___y_11972_ = v___y_11985_;
v___y_11973_ = v___x_11989_;
v___y_11974_ = v___y_11986_;
v___y_11975_ = v___y_11987_;
v___y_11976_ = v___y_11988_;
v___y_11977_ = v___x_11990_;
goto v___jp_11970_;
}
v___jp_11991_:
{
uint32_t v___x_11998_;
v___x_11998_ = 0;
v___y_11971_ = v___y_11993_;
v___y_11972_ = v___y_11992_;
v___y_11973_ = v___y_11997_;
v___y_11974_ = v___y_11994_;
v___y_11975_ = v___y_11995_;
v___y_11976_ = v___y_11996_;
v___y_11977_ = v___x_11998_;
goto v___jp_11970_;
}
v___jp_11999_:
{
if (v___y_12004_ == 0)
{
uint32_t v___x_12006_;
v___x_12006_ = 2048;
v___y_11992_ = v___y_12001_;
v___y_11993_ = v___y_12000_;
v___y_11994_ = v___y_12002_;
v___y_11995_ = v___y_12003_;
v___y_11996_ = v___y_12005_;
v___y_11997_ = v___x_12006_;
goto v___jp_11991_;
}
else
{
v___y_11984_ = v___y_12000_;
v___y_11985_ = v___y_12001_;
v___y_11986_ = v___y_12002_;
v___y_11987_ = v___y_12003_;
v___y_11988_ = v___y_12005_;
goto v___jp_11983_;
}
}
v___jp_12007_:
{
if (v___y_12012_ == 0)
{
uint32_t v___x_12014_;
v___x_12014_ = 0;
v___y_11992_ = v___y_12009_;
v___y_11993_ = v___y_12008_;
v___y_11994_ = v___y_12010_;
v___y_11995_ = v___y_12011_;
v___y_11996_ = v___y_12013_;
v___y_11997_ = v___x_12014_;
goto v___jp_11991_;
}
else
{
v___y_11984_ = v___y_12008_;
v___y_11985_ = v___y_12009_;
v___y_11986_ = v___y_12010_;
v___y_11987_ = v___y_12011_;
v___y_11988_ = v___y_12013_;
goto v___jp_11983_;
}
}
v___jp_12015_:
{
if (v___y_12022_ == 0)
{
v___y_12008_ = v___y_12017_;
v___y_12009_ = v___y_12016_;
v___y_12010_ = v___y_12018_;
v___y_12011_ = v___y_12019_;
v___y_12012_ = v___y_12020_;
v___y_12013_ = v___y_12021_;
goto v___jp_12007_;
}
else
{
v___y_12000_ = v___y_12017_;
v___y_12001_ = v___y_12016_;
v___y_12002_ = v___y_12018_;
v___y_12003_ = v___y_12019_;
v___y_12004_ = v___y_12020_;
v___y_12005_ = v___y_12021_;
goto v___jp_11999_;
}
}
v___jp_12024_:
{
if (v___y_12027_ == 0)
{
v___y_12008_ = v___y_12025_;
v___y_12009_ = v___y_12026_;
v___y_12010_ = v___y_12031_;
v___y_12011_ = v___y_12027_;
v___y_12012_ = v___y_12029_;
v___y_12013_ = v___y_12030_;
goto v___jp_12007_;
}
else
{
uint8_t v___x_12032_; uint8_t v___x_12033_;
v___x_12032_ = 1;
v___x_12033_ = lean_uint8_dec_eq(v_mode_11909_, v___x_12032_);
if (v___x_12033_ == 0)
{
v___y_12016_ = v___y_12026_;
v___y_12017_ = v___y_12025_;
v___y_12018_ = v___y_12031_;
v___y_12019_ = v___y_12027_;
v___y_12020_ = v___y_12029_;
v___y_12021_ = v___y_12030_;
v___y_12022_ = v___y_12028_;
goto v___jp_12015_;
}
else
{
uint8_t v___x_12034_;
v___x_12034_ = lean_uint8_dec_eq(v___y_12031_, v___x_12023_);
if (v___x_12034_ == 0)
{
v___y_12016_ = v___y_12026_;
v___y_12017_ = v___y_12025_;
v___y_12018_ = v___y_12031_;
v___y_12019_ = v___y_12027_;
v___y_12020_ = v___y_12029_;
v___y_12021_ = v___y_12030_;
v___y_12022_ = v___y_12028_;
goto v___jp_12015_;
}
else
{
v___y_12000_ = v___y_12025_;
v___y_12001_ = v___y_12026_;
v___y_12002_ = v___y_12031_;
v___y_12003_ = v___y_12027_;
v___y_12004_ = v___y_12029_;
v___y_12005_ = v___y_12030_;
goto v___jp_11999_;
}
}
}
}
v___jp_12035_:
{
if (v___y_12040_ == 0)
{
uint8_t v___x_12044_; uint8_t v___x_12045_;
v___x_12044_ = 0;
v___x_12045_ = lean_uint8_dec_eq(v_eventKind_11910_, v___x_12044_);
if (v___x_12045_ == 0)
{
if (v___y_12039_ == 0)
{
uint8_t v___x_12046_; uint8_t v___x_12047_;
v___x_12046_ = 3;
v___x_12047_ = lean_uint8_dec_eq(v_eventKind_11910_, v___x_12046_);
if (v___x_12047_ == 0)
{
v___y_12025_ = v___y_12036_;
v___y_12026_ = v___y_12043_;
v___y_12027_ = v___y_12037_;
v___y_12028_ = v___y_12038_;
v___y_12029_ = v___y_12040_;
v___y_12030_ = v___y_12041_;
v___y_12031_ = v_mode_11909_;
goto v___jp_12024_;
}
else
{
uint8_t v___x_12048_; uint8_t v___x_12049_;
v___x_12048_ = 1;
v___x_12049_ = lean_uint8_dec_eq(v_mode_11909_, v___x_12048_);
if (v___x_12049_ == 0)
{
v___y_12025_ = v___y_12036_;
v___y_12026_ = v___y_12043_;
v___y_12027_ = v___y_12037_;
v___y_12028_ = v___y_12038_;
v___y_12029_ = v___y_12040_;
v___y_12030_ = v___y_12041_;
v___y_12031_ = v_mode_11909_;
goto v___jp_12024_;
}
else
{
uint8_t v___x_12050_;
v___x_12050_ = lean_uint64_dec_le(v_cooldownUntilMs_11921_, v_nowMs_11920_);
if (v___x_12050_ == 0)
{
v___y_12025_ = v___y_12036_;
v___y_12026_ = v___y_12043_;
v___y_12027_ = v___y_12037_;
v___y_12028_ = v___y_12038_;
v___y_12029_ = v___y_12040_;
v___y_12030_ = v___y_12041_;
v___y_12031_ = v_mode_11909_;
goto v___jp_12024_;
}
else
{
v___y_12025_ = v___y_12036_;
v___y_12026_ = v___y_12043_;
v___y_12027_ = v___y_12037_;
v___y_12028_ = v___y_12038_;
v___y_12029_ = v___y_12040_;
v___y_12030_ = v___y_12041_;
v___y_12031_ = v___x_12023_;
goto v___jp_12024_;
}
}
}
}
else
{
uint8_t v___x_12051_;
v___x_12051_ = lean_uint32_dec_le(v_failThreshold_11917_, v___y_12042_);
if (v___x_12051_ == 0)
{
v___y_12025_ = v___y_12036_;
v___y_12026_ = v___y_12043_;
v___y_12027_ = v___y_12037_;
v___y_12028_ = v___y_12038_;
v___y_12029_ = v___y_12040_;
v___y_12030_ = v___y_12041_;
v___y_12031_ = v___x_12044_;
goto v___jp_12024_;
}
else
{
uint8_t v___x_12052_;
v___x_12052_ = 1;
v___y_12025_ = v___y_12036_;
v___y_12026_ = v___y_12043_;
v___y_12027_ = v___y_12037_;
v___y_12028_ = v___y_12038_;
v___y_12029_ = v___y_12040_;
v___y_12030_ = v___y_12041_;
v___y_12031_ = v___x_12052_;
goto v___jp_12024_;
}
}
}
else
{
v___y_12025_ = v___y_12036_;
v___y_12026_ = v___y_12043_;
v___y_12027_ = v___y_12037_;
v___y_12028_ = v___y_12038_;
v___y_12029_ = v___y_12040_;
v___y_12030_ = v___y_12041_;
v___y_12031_ = v___x_12044_;
goto v___jp_12024_;
}
}
else
{
uint8_t v___x_12053_;
v___x_12053_ = 1;
v___y_12025_ = v___y_12036_;
v___y_12026_ = v___y_12043_;
v___y_12027_ = v___y_12037_;
v___y_12028_ = v___y_12038_;
v___y_12029_ = v___y_12040_;
v___y_12030_ = v___y_12041_;
v___y_12031_ = v___x_12053_;
goto v___jp_12024_;
}
}
v___jp_12054_:
{
uint32_t v___x_12063_;
v___x_12063_ = 0;
if (v___y_12060_ == 0)
{
v___y_12036_ = v___y_12055_;
v___y_12037_ = v___y_12056_;
v___y_12038_ = v___y_12057_;
v___y_12039_ = v___y_12059_;
v___y_12040_ = v___y_12058_;
v___y_12041_ = v___y_12061_;
v___y_12042_ = v___y_12062_;
v___y_12043_ = v___x_12063_;
goto v___jp_12035_;
}
else
{
uint8_t v___x_12064_; uint8_t v___x_12065_;
v___x_12064_ = 1;
v___x_12065_ = lean_uint8_dec_eq(v_mode_11909_, v___x_12064_);
if (v___x_12065_ == 0)
{
if (v___y_12057_ == 0)
{
uint8_t v___x_12066_;
v___x_12066_ = 0;
v___y_12025_ = v___y_12055_;
v___y_12026_ = v___x_12063_;
v___y_12027_ = v___y_12056_;
v___y_12028_ = v___y_12057_;
v___y_12029_ = v___y_12058_;
v___y_12030_ = v___y_12061_;
v___y_12031_ = v___x_12066_;
goto v___jp_12024_;
}
else
{
v___y_12025_ = v___y_12055_;
v___y_12026_ = v___x_12063_;
v___y_12027_ = v___y_12056_;
v___y_12028_ = v___y_12057_;
v___y_12029_ = v___y_12058_;
v___y_12030_ = v___y_12061_;
v___y_12031_ = v___x_12023_;
goto v___jp_12024_;
}
}
else
{
v___y_12025_ = v___y_12055_;
v___y_12026_ = v___x_12063_;
v___y_12027_ = v___y_12056_;
v___y_12028_ = v___y_12057_;
v___y_12029_ = v___y_12058_;
v___y_12030_ = v___y_12061_;
v___y_12031_ = v___x_12023_;
goto v___jp_12024_;
}
}
}
v___jp_12067_:
{
uint8_t v___x_12078_; uint8_t v___x_12079_;
v___x_12078_ = 0;
v___x_12079_ = lean_uint8_dec_eq(v_eventKind_11910_, v___x_12078_);
if (v___x_12079_ == 0)
{
if (v___y_12073_ == 0)
{
if (v___y_12069_ == 0)
{
if (v___y_12072_ == 0)
{
uint8_t v___x_12080_;
v___x_12080_ = lean_uint32_dec_le(v_failureStreak_11916_, v___y_12068_);
if (v___x_12080_ == 0)
{
v___y_12036_ = v___y_12068_;
v___y_12037_ = v___y_12070_;
v___y_12038_ = v___y_12071_;
v___y_12039_ = v___y_12072_;
v___y_12040_ = v___y_12077_;
v___y_12041_ = v___y_12075_;
v___y_12042_ = v___y_12076_;
v___y_12043_ = v___y_12068_;
goto v___jp_12035_;
}
else
{
v___y_12036_ = v___y_12068_;
v___y_12037_ = v___y_12070_;
v___y_12038_ = v___y_12071_;
v___y_12039_ = v___y_12072_;
v___y_12040_ = v___y_12077_;
v___y_12041_ = v___y_12075_;
v___y_12042_ = v___y_12076_;
v___y_12043_ = v_failureStreak_11916_;
goto v___jp_12035_;
}
}
else
{
v___y_12036_ = v___y_12068_;
v___y_12037_ = v___y_12070_;
v___y_12038_ = v___y_12071_;
v___y_12039_ = v___y_12072_;
v___y_12040_ = v___y_12077_;
v___y_12041_ = v___y_12075_;
v___y_12042_ = v___y_12076_;
v___y_12043_ = v___y_12076_;
goto v___jp_12035_;
}
}
else
{
uint8_t v___x_12081_;
v___x_12081_ = lean_uint32_dec_le(v___y_12074_, v___y_12076_);
if (v___x_12081_ == 0)
{
v___y_12036_ = v___y_12068_;
v___y_12037_ = v___y_12070_;
v___y_12038_ = v___y_12071_;
v___y_12039_ = v___y_12072_;
v___y_12040_ = v___y_12077_;
v___y_12041_ = v___y_12075_;
v___y_12042_ = v___y_12076_;
v___y_12043_ = v___y_12074_;
goto v___jp_12035_;
}
else
{
v___y_12036_ = v___y_12068_;
v___y_12037_ = v___y_12070_;
v___y_12038_ = v___y_12071_;
v___y_12039_ = v___y_12072_;
v___y_12040_ = v___y_12077_;
v___y_12041_ = v___y_12075_;
v___y_12042_ = v___y_12076_;
v___y_12043_ = v___y_12076_;
goto v___jp_12035_;
}
}
}
else
{
v___y_12055_ = v___y_12068_;
v___y_12056_ = v___y_12070_;
v___y_12057_ = v___y_12071_;
v___y_12058_ = v___y_12077_;
v___y_12059_ = v___y_12072_;
v___y_12060_ = v___y_12073_;
v___y_12061_ = v___y_12075_;
v___y_12062_ = v___y_12076_;
goto v___jp_12054_;
}
}
else
{
v___y_12055_ = v___y_12068_;
v___y_12056_ = v___y_12070_;
v___y_12057_ = v___y_12071_;
v___y_12058_ = v___y_12077_;
v___y_12059_ = v___y_12072_;
v___y_12060_ = v___y_12073_;
v___y_12061_ = v___y_12075_;
v___y_12062_ = v___y_12076_;
goto v___jp_12054_;
}
}
v___jp_12082_:
{
if (v___y_12085_ == 0)
{
uint8_t v___x_12091_; uint8_t v___x_12092_; uint8_t v___x_12093_; uint8_t v___x_12094_;
v___x_12091_ = 1;
v___x_12092_ = 1;
v___x_12093_ = lean_uint8_dec_eq(v_stickyUnsupported_11912_, v___x_12092_);
v___x_12094_ = lean_uint32_dec_le(v_failureStreak_11916_, v___y_12083_);
if (v___x_12094_ == 0)
{
v___y_12008_ = v___y_12083_;
v___y_12009_ = v___y_12083_;
v___y_12010_ = v_mode_11909_;
v___y_12011_ = v___y_12085_;
v___y_12012_ = v___x_12093_;
v___y_12013_ = v___x_12091_;
goto v___jp_12007_;
}
else
{
v___y_12008_ = v___y_12083_;
v___y_12009_ = v_failureStreak_11916_;
v___y_12010_ = v_mode_11909_;
v___y_12011_ = v___y_12085_;
v___y_12012_ = v___x_12093_;
v___y_12013_ = v___x_12091_;
goto v___jp_12007_;
}
}
else
{
uint8_t v___x_12095_;
v___x_12095_ = 0;
if (v___y_12088_ == 0)
{
if (v___y_12084_ == 0)
{
uint8_t v___x_12096_; uint8_t v___x_12097_;
v___x_12096_ = 1;
v___x_12097_ = lean_uint8_dec_eq(v_stickyUnsupported_11912_, v___x_12096_);
v___y_12068_ = v___y_12083_;
v___y_12069_ = v___y_12084_;
v___y_12070_ = v___y_12085_;
v___y_12071_ = v___y_12086_;
v___y_12072_ = v___y_12087_;
v___y_12073_ = v___y_12088_;
v___y_12074_ = v___y_12090_;
v___y_12075_ = v___x_12095_;
v___y_12076_ = v___y_12089_;
v___y_12077_ = v___x_12097_;
goto v___jp_12067_;
}
else
{
v___y_12068_ = v___y_12083_;
v___y_12069_ = v___y_12084_;
v___y_12070_ = v___y_12085_;
v___y_12071_ = v___y_12086_;
v___y_12072_ = v___y_12087_;
v___y_12073_ = v___y_12088_;
v___y_12074_ = v___y_12090_;
v___y_12075_ = v___x_12095_;
v___y_12076_ = v___y_12089_;
v___y_12077_ = v___y_12084_;
goto v___jp_12067_;
}
}
else
{
v___y_12068_ = v___y_12083_;
v___y_12069_ = v___y_12084_;
v___y_12070_ = v___y_12085_;
v___y_12071_ = v___y_12086_;
v___y_12072_ = v___y_12087_;
v___y_12073_ = v___y_12088_;
v___y_12074_ = v___y_12090_;
v___y_12075_ = v___x_12095_;
v___y_12076_ = v___y_12089_;
v___y_12077_ = v___x_12095_;
goto v___jp_12067_;
}
}
}
v___jp_12098_:
{
uint8_t v___x_12106_;
v___x_12106_ = lean_uint32_dec_le(v_failThreshold_11917_, v___y_12099_);
if (v___x_12106_ == 0)
{
v___y_12083_ = v___y_12099_;
v___y_12084_ = v___y_12100_;
v___y_12085_ = v___y_12101_;
v___y_12086_ = v___y_12102_;
v___y_12087_ = v___y_12103_;
v___y_12088_ = v___y_12104_;
v___y_12089_ = v___y_12105_;
v___y_12090_ = v___y_12099_;
goto v___jp_12082_;
}
else
{
v___y_12083_ = v___y_12099_;
v___y_12084_ = v___y_12100_;
v___y_12085_ = v___y_12101_;
v___y_12086_ = v___y_12102_;
v___y_12087_ = v___y_12103_;
v___y_12088_ = v___y_12104_;
v___y_12089_ = v___y_12105_;
v___y_12090_ = v_failThreshold_11917_;
goto v___jp_12082_;
}
}
v___jp_12107_:
{
uint32_t v___x_12113_; uint8_t v___x_12114_;
v___x_12113_ = 255;
v___x_12114_ = lean_uint32_dec_lt(v_failureStreak_11916_, v___x_12113_);
if (v___x_12114_ == 0)
{
v___y_12099_ = v___x_12113_;
v___y_12100_ = v___y_12108_;
v___y_12101_ = v___y_12109_;
v___y_12102_ = v___y_12110_;
v___y_12103_ = v___y_12112_;
v___y_12104_ = v___y_12111_;
v___y_12105_ = v___x_12113_;
goto v___jp_12098_;
}
else
{
uint32_t v___x_12115_; uint32_t v___x_12116_;
v___x_12115_ = 1;
v___x_12116_ = lean_uint32_add(v_failureStreak_11916_, v___x_12115_);
v___y_12099_ = v___x_12113_;
v___y_12100_ = v___y_12108_;
v___y_12101_ = v___y_12109_;
v___y_12102_ = v___y_12110_;
v___y_12103_ = v___y_12112_;
v___y_12104_ = v___y_12111_;
v___y_12105_ = v___x_12116_;
goto v___jp_12098_;
}
}
v___jp_12117_:
{
uint8_t v___x_12122_; uint8_t v___x_12123_;
v___x_12122_ = 1;
v___x_12123_ = lean_uint8_dec_eq(v_eventKind_11910_, v___x_12122_);
if (v___x_12123_ == 0)
{
uint8_t v___x_12124_;
v___x_12124_ = lean_uint8_dec_eq(v_eventKind_11910_, v___x_12023_);
if (v___x_12124_ == 0)
{
v___y_12108_ = v___y_12121_;
v___y_12109_ = v___y_12118_;
v___y_12110_ = v___y_12119_;
v___y_12111_ = v___y_12120_;
v___y_12112_ = v___x_12124_;
goto v___jp_12107_;
}
else
{
if (v___y_12121_ == 0)
{
v___y_12108_ = v___y_12121_;
v___y_12109_ = v___y_12118_;
v___y_12110_ = v___y_12119_;
v___y_12111_ = v___y_12120_;
v___y_12112_ = v___x_12124_;
goto v___jp_12107_;
}
else
{
v___y_12108_ = v___y_12121_;
v___y_12109_ = v___y_12118_;
v___y_12110_ = v___y_12119_;
v___y_12111_ = v___y_12120_;
v___y_12112_ = v___x_12123_;
goto v___jp_12107_;
}
}
}
else
{
v___y_12108_ = v___y_12121_;
v___y_12109_ = v___y_12118_;
v___y_12110_ = v___y_12119_;
v___y_12111_ = v___y_12120_;
v___y_12112_ = v___x_12123_;
goto v___jp_12107_;
}
}
v___jp_12125_:
{
uint8_t v___x_12129_;
v___x_12129_ = 0;
v___y_12108_ = v___x_12129_;
v___y_12109_ = v___y_12126_;
v___y_12110_ = v___y_12127_;
v___y_12111_ = v___y_12128_;
v___y_12112_ = v___x_12129_;
goto v___jp_12107_;
}
v___jp_12130_:
{
if (v___y_12133_ == 0)
{
uint8_t v___x_12134_;
v___x_12134_ = lean_uint8_dec_eq(v_eventKind_11910_, v___x_12023_);
if (v___x_12134_ == 0)
{
v___y_12118_ = v___y_12131_;
v___y_12119_ = v___y_12132_;
v___y_12120_ = v___y_12133_;
v___y_12121_ = v___x_12134_;
goto v___jp_12117_;
}
else
{
uint32_t v___x_12135_; uint8_t v___x_12136_;
v___x_12135_ = 404;
v___x_12136_ = lean_uint32_dec_eq(v_httpStatus_11918_, v___x_12135_);
if (v___x_12136_ == 0)
{
uint32_t v___x_12137_; uint8_t v___x_12138_;
v___x_12137_ = 501;
v___x_12138_ = lean_uint32_dec_eq(v_httpStatus_11918_, v___x_12137_);
v___y_12118_ = v___y_12131_;
v___y_12119_ = v___y_12132_;
v___y_12120_ = v___y_12133_;
v___y_12121_ = v___x_12138_;
goto v___jp_12117_;
}
else
{
v___y_12118_ = v___y_12131_;
v___y_12119_ = v___y_12132_;
v___y_12120_ = v___y_12133_;
v___y_12121_ = v___x_12136_;
goto v___jp_12117_;
}
}
}
else
{
v___y_12126_ = v___y_12131_;
v___y_12127_ = v___y_12132_;
v___y_12128_ = v___y_12133_;
goto v___jp_12125_;
}
}
v___jp_12139_:
{
uint8_t v___x_12141_; uint8_t v___x_12142_;
v___x_12141_ = 4;
v___x_12142_ = lean_uint8_dec_eq(v_eventKind_11910_, v___x_12141_);
if (v___x_12142_ == 0)
{
uint8_t v___x_12143_;
v___x_12143_ = lean_uint8_dec_eq(v_endpointClass_11913_, v_prevEndpointClass_11914_);
if (v___x_12143_ == 0)
{
uint8_t v___x_12144_;
v___x_12144_ = 1;
v___y_12126_ = v___y_12140_;
v___y_12127_ = v___x_12142_;
v___y_12128_ = v___x_12144_;
goto v___jp_12125_;
}
else
{
v___y_12131_ = v___y_12140_;
v___y_12132_ = v___x_12142_;
v___y_12133_ = v___x_12142_;
goto v___jp_12130_;
}
}
else
{
v___y_12131_ = v___y_12140_;
v___y_12132_ = v___x_12142_;
v___y_12133_ = v___x_12142_;
goto v___jp_12130_;
}
}
}
}

LEAN_EXPORT uint64_t orb_stream_open_tail_cap_step(uint32_t v_prevLen_12185_, uint32_t v_prevCommit_12186_, uint32_t v_prevCheckpoint_12187_, uint32_t v_newLen_12188_, uint32_t v_rawCommit_12189_, uint32_t v_maxOpenTailBytes_12190_, uint8_t v_openFenceActive_12191_){
_start:
{
uint64_t v___y_12193_; uint32_t v___y_12194_; uint32_t v___y_12195_; uint8_t v___x_12200_; uint8_t v_validFlags_12201_; uint32_t v___x_12202_; uint64_t v___y_12204_; uint32_t v___y_12205_; uint32_t v___y_12206_; uint8_t v___y_12207_; uint32_t v___y_12208_; uint64_t v___y_12211_; uint32_t v___y_12212_; uint32_t v___y_12213_; uint8_t v___y_12214_; uint8_t v___y_12215_; uint64_t v___y_12219_; uint32_t v___y_12220_; uint32_t v___y_12221_; uint8_t v___y_12222_; uint64_t v___y_12229_; uint32_t v___y_12230_; uint32_t v___y_12231_; uint8_t v___y_12232_; uint32_t v___y_12234_; uint32_t v___y_12235_; uint8_t v_validCap_12251_; uint8_t v___y_12253_; uint32_t v___y_12254_; uint32_t v___y_12255_; uint32_t v___y_12259_; uint8_t v___y_12260_; uint32_t v___y_12261_; uint32_t v___y_12265_; uint32_t v___y_12266_; uint8_t v___y_12267_; uint32_t v___y_12268_; uint32_t v___y_12271_; uint8_t v___y_12272_; uint32_t v___y_12273_; uint8_t v___y_12277_; uint32_t v___y_12278_; uint8_t v___y_12281_; uint32_t v___y_12282_; uint8_t v___y_12285_; uint8_t v___x_12287_;
v___x_12200_ = 1;
v_validFlags_12201_ = lean_uint8_dec_le(v_openFenceActive_12191_, v___x_12200_);
v___x_12202_ = 0;
v_validCap_12251_ = lean_uint32_dec_lt(v___x_12202_, v_maxOpenTailBytes_12190_);
v___x_12287_ = lean_uint32_dec_le(v_prevCommit_12186_, v_prevCheckpoint_12187_);
if (v___x_12287_ == 0)
{
v___y_12285_ = v___x_12287_;
goto v___jp_12284_;
}
else
{
uint8_t v___x_12288_;
v___x_12288_ = lean_uint32_dec_le(v_prevCheckpoint_12187_, v_prevLen_12185_);
if (v___x_12288_ == 0)
{
v___y_12285_ = v___x_12288_;
goto v___jp_12284_;
}
else
{
uint8_t v___x_12289_;
v___x_12289_ = lean_uint32_dec_le(v_prevLen_12185_, v_newLen_12188_);
v___y_12285_ = v___x_12289_;
goto v___jp_12284_;
}
}
v___jp_12192_:
{
uint64_t v___x_12196_; uint64_t v___x_12197_; uint64_t v___x_12198_; uint64_t v___x_12199_;
v___x_12196_ = lean_uint32_to_uint64(v___y_12194_);
v___x_12197_ = lean_uint32_to_uint64(v___y_12195_);
v___x_12198_ = lean_uint64_shift_left(v___x_12197_, v___y_12193_);
v___x_12199_ = lean_uint64_lor(v___x_12196_, v___x_12198_);
return v___x_12199_;
}
v___jp_12203_:
{
if (v___y_12207_ == 0)
{
v___y_12193_ = v___y_12204_;
v___y_12194_ = v___x_12202_;
v___y_12195_ = v_prevCheckpoint_12187_;
goto v___jp_12192_;
}
else
{
uint32_t v___x_12209_;
v___x_12209_ = lean_uint32_lor(v___y_12205_, v___y_12208_);
v___y_12193_ = v___y_12204_;
v___y_12194_ = v___x_12209_;
v___y_12195_ = v___y_12206_;
goto v___jp_12192_;
}
}
v___jp_12210_:
{
uint8_t v___x_12216_;
v___x_12216_ = lean_uint8_dec_eq(v_openFenceActive_12191_, v___x_12200_);
if (v___x_12216_ == 0)
{
v___y_12204_ = v___y_12211_;
v___y_12205_ = v___y_12212_;
v___y_12206_ = v___y_12213_;
v___y_12207_ = v___y_12214_;
v___y_12208_ = v___x_12202_;
goto v___jp_12203_;
}
else
{
if (v___y_12215_ == 0)
{
v___y_12204_ = v___y_12211_;
v___y_12205_ = v___y_12212_;
v___y_12206_ = v___y_12213_;
v___y_12207_ = v___y_12214_;
v___y_12208_ = v___x_12202_;
goto v___jp_12203_;
}
else
{
uint32_t v___x_12217_;
v___x_12217_ = 1024;
v___y_12204_ = v___y_12211_;
v___y_12205_ = v___y_12212_;
v___y_12206_ = v___y_12213_;
v___y_12207_ = v___y_12214_;
v___y_12208_ = v___x_12217_;
goto v___jp_12203_;
}
}
}
v___jp_12218_:
{
uint32_t v___x_12223_; uint32_t v___x_12224_; uint8_t v___x_12225_;
v___x_12223_ = 512;
v___x_12224_ = lean_uint32_land(v___y_12220_, v___x_12223_);
v___x_12225_ = lean_uint32_dec_eq(v___x_12224_, v___x_12202_);
if (v___x_12225_ == 0)
{
uint8_t v___x_12226_;
v___x_12226_ = 1;
v___y_12211_ = v___y_12219_;
v___y_12212_ = v___y_12220_;
v___y_12213_ = v___y_12221_;
v___y_12214_ = v___y_12222_;
v___y_12215_ = v___x_12226_;
goto v___jp_12210_;
}
else
{
uint8_t v___x_12227_;
v___x_12227_ = 0;
v___y_12211_ = v___y_12219_;
v___y_12212_ = v___y_12220_;
v___y_12213_ = v___y_12221_;
v___y_12214_ = v___y_12222_;
v___y_12215_ = v___x_12227_;
goto v___jp_12210_;
}
}
v___jp_12228_:
{
if (v_validFlags_12201_ == 0)
{
v___y_12219_ = v___y_12229_;
v___y_12220_ = v___y_12230_;
v___y_12221_ = v___y_12231_;
v___y_12222_ = v_validFlags_12201_;
goto v___jp_12218_;
}
else
{
v___y_12219_ = v___y_12229_;
v___y_12220_ = v___y_12230_;
v___y_12221_ = v___y_12231_;
v___y_12222_ = v___y_12232_;
goto v___jp_12218_;
}
}
v___jp_12233_:
{
uint64_t v___x_12236_; uint64_t v___x_12237_; uint64_t v___x_12238_; uint64_t v___x_12239_; uint64_t v___x_12240_; uint64_t v___x_12241_; uint64_t v___x_12242_; uint32_t v_baseLo_12243_; uint64_t v___x_12244_; uint32_t v_nextCheckpoint_12245_; uint32_t v___x_12246_; uint32_t v___x_12247_; uint8_t v___x_12248_;
v___x_12236_ = lean_uint32_to_uint64(v___y_12234_);
v___x_12237_ = lean_uint32_to_uint64(v___y_12235_);
v___x_12238_ = 32ULL;
v___x_12239_ = lean_uint64_shift_left(v___x_12237_, v___x_12238_);
v___x_12240_ = lean_uint64_lor(v___x_12236_, v___x_12239_);
v___x_12241_ = 4294967295ULL;
v___x_12242_ = lean_uint64_land(v___x_12240_, v___x_12241_);
v_baseLo_12243_ = lean_uint64_to_uint32(v___x_12242_);
v___x_12244_ = lean_uint64_shift_right(v___x_12240_, v___x_12238_);
v_nextCheckpoint_12245_ = lean_uint64_to_uint32(v___x_12244_);
v___x_12246_ = 256;
v___x_12247_ = lean_uint32_land(v_baseLo_12243_, v___x_12246_);
v___x_12248_ = lean_uint32_dec_eq(v___x_12247_, v___x_12202_);
if (v___x_12248_ == 0)
{
uint8_t v___x_12249_;
v___x_12249_ = 1;
v___y_12229_ = v___x_12238_;
v___y_12230_ = v_baseLo_12243_;
v___y_12231_ = v_nextCheckpoint_12245_;
v___y_12232_ = v___x_12249_;
goto v___jp_12228_;
}
else
{
uint8_t v___x_12250_;
v___x_12250_ = 0;
v___y_12229_ = v___x_12238_;
v___y_12230_ = v_baseLo_12243_;
v___y_12231_ = v_nextCheckpoint_12245_;
v___y_12232_ = v___x_12250_;
goto v___jp_12228_;
}
}
v___jp_12252_:
{
if (v_validCap_12251_ == 0)
{
v___y_12234_ = v___x_12202_;
v___y_12235_ = v_prevCheckpoint_12187_;
goto v___jp_12233_;
}
else
{
if (v___y_12253_ == 0)
{
v___y_12234_ = v___x_12202_;
v___y_12235_ = v_prevCheckpoint_12187_;
goto v___jp_12233_;
}
else
{
uint32_t v___x_12256_; uint32_t v___x_12257_;
v___x_12256_ = 257;
v___x_12257_ = lean_uint32_lor(v___x_12256_, v___y_12255_);
v___y_12234_ = v___x_12257_;
v___y_12235_ = v___y_12254_;
goto v___jp_12233_;
}
}
}
v___jp_12258_:
{
uint8_t v___x_12262_;
v___x_12262_ = lean_uint32_dec_lt(v___y_12259_, v___y_12261_);
if (v___x_12262_ == 0)
{
v___y_12253_ = v___y_12260_;
v___y_12254_ = v___y_12261_;
v___y_12255_ = v___x_12202_;
goto v___jp_12252_;
}
else
{
uint32_t v___x_12263_;
v___x_12263_ = 512;
v___y_12253_ = v___y_12260_;
v___y_12254_ = v___y_12261_;
v___y_12255_ = v___x_12263_;
goto v___jp_12252_;
}
}
v___jp_12264_:
{
uint8_t v___x_12269_;
v___x_12269_ = lean_uint32_dec_le(v___y_12265_, v___y_12268_);
if (v___x_12269_ == 0)
{
v___y_12259_ = v___y_12266_;
v___y_12260_ = v___y_12267_;
v___y_12261_ = v___y_12265_;
goto v___jp_12258_;
}
else
{
v___y_12259_ = v___y_12266_;
v___y_12260_ = v___y_12267_;
v___y_12261_ = v___y_12268_;
goto v___jp_12258_;
}
}
v___jp_12270_:
{
uint8_t v___x_12274_;
v___x_12274_ = lean_uint32_dec_le(v_maxOpenTailBytes_12190_, v_newLen_12188_);
if (v___x_12274_ == 0)
{
v___y_12265_ = v___y_12273_;
v___y_12266_ = v___y_12271_;
v___y_12267_ = v___y_12272_;
v___y_12268_ = v___x_12202_;
goto v___jp_12264_;
}
else
{
uint32_t v___x_12275_;
v___x_12275_ = lean_uint32_sub(v_newLen_12188_, v_maxOpenTailBytes_12190_);
v___y_12265_ = v___y_12273_;
v___y_12266_ = v___y_12271_;
v___y_12267_ = v___y_12272_;
v___y_12268_ = v___x_12275_;
goto v___jp_12264_;
}
}
v___jp_12276_:
{
uint8_t v___x_12279_;
v___x_12279_ = lean_uint32_dec_le(v_prevCheckpoint_12187_, v___y_12278_);
if (v___x_12279_ == 0)
{
v___y_12271_ = v___y_12278_;
v___y_12272_ = v___y_12277_;
v___y_12273_ = v_prevCheckpoint_12187_;
goto v___jp_12270_;
}
else
{
v___y_12271_ = v___y_12278_;
v___y_12272_ = v___y_12277_;
v___y_12273_ = v___y_12278_;
goto v___jp_12270_;
}
}
v___jp_12280_:
{
uint8_t v___x_12283_;
v___x_12283_ = lean_uint32_dec_le(v_prevCommit_12186_, v___y_12282_);
if (v___x_12283_ == 0)
{
v___y_12277_ = v___y_12281_;
v___y_12278_ = v_prevCommit_12186_;
goto v___jp_12276_;
}
else
{
v___y_12277_ = v___y_12281_;
v___y_12278_ = v___y_12282_;
goto v___jp_12276_;
}
}
v___jp_12284_:
{
uint8_t v___x_12286_;
v___x_12286_ = lean_uint32_dec_le(v_rawCommit_12189_, v_newLen_12188_);
if (v___x_12286_ == 0)
{
v___y_12281_ = v___y_12285_;
v___y_12282_ = v_newLen_12188_;
goto v___jp_12280_;
}
else
{
v___y_12281_ = v___y_12285_;
v___y_12282_ = v_rawCommit_12189_;
goto v___jp_12280_;
}
}
}
}

LEAN_EXPORT uint64_t orb_rtt_ewma_step(uint32_t v_srttMs_12306_, uint32_t v_rttVarMs_12307_, uint32_t v_sampleMs_12308_){
_start:
{
uint32_t v___y_12310_; uint32_t v___y_12311_; uint32_t v___y_12318_; uint32_t v___y_12319_; uint64_t v___y_12326_; uint64_t v___y_12327_; uint64_t v___y_12328_; uint32_t v___y_12329_; uint32_t v___y_12330_; uint64_t v___y_12342_; uint64_t v___y_12343_; uint64_t v___y_12344_; uint32_t v___y_12345_; uint64_t v___y_12346_; uint64_t v___y_12359_; uint32_t v___y_12360_; uint32_t v___y_12361_; uint64_t v___y_12362_; uint32_t v___y_12368_; uint32_t v___y_12369_; uint64_t v___y_12370_; uint32_t v___x_12374_; uint32_t v___y_12376_; uint8_t v___x_12386_;
v___x_12374_ = 0;
v___x_12386_ = lean_uint32_dec_eq(v_sampleMs_12308_, v___x_12374_);
if (v___x_12386_ == 0)
{
uint32_t v___x_12387_; uint8_t v___x_12388_;
v___x_12387_ = 60000;
v___x_12388_ = lean_uint32_dec_lt(v___x_12387_, v_sampleMs_12308_);
if (v___x_12388_ == 0)
{
v___y_12376_ = v_sampleMs_12308_;
goto v___jp_12375_;
}
else
{
v___y_12376_ = v___x_12387_;
goto v___jp_12375_;
}
}
else
{
uint32_t v___x_12389_;
v___x_12389_ = 1;
v___y_12376_ = v___x_12389_;
goto v___jp_12375_;
}
v___jp_12309_:
{
uint64_t v___x_12312_; uint64_t v___x_12313_; uint64_t v___x_12314_; uint64_t v___x_12315_; uint64_t v___x_12316_;
v___x_12312_ = lean_uint32_to_uint64(v___y_12310_);
v___x_12313_ = lean_uint32_to_uint64(v___y_12311_);
v___x_12314_ = 32ULL;
v___x_12315_ = lean_uint64_shift_left(v___x_12313_, v___x_12314_);
v___x_12316_ = lean_uint64_lor(v___x_12312_, v___x_12315_);
return v___x_12316_;
}
v___jp_12317_:
{
uint64_t v___x_12320_; uint64_t v___x_12321_; uint64_t v___x_12322_; uint64_t v___x_12323_; uint64_t v___x_12324_;
v___x_12320_ = lean_uint32_to_uint64(v___y_12319_);
v___x_12321_ = lean_uint32_to_uint64(v___y_12318_);
v___x_12322_ = 32ULL;
v___x_12323_ = lean_uint64_shift_left(v___x_12321_, v___x_12322_);
v___x_12324_ = lean_uint64_lor(v___x_12320_, v___x_12323_);
return v___x_12324_;
}
v___jp_12325_:
{
uint64_t v___x_12331_; uint64_t v___x_12332_; uint64_t v___x_12333_; uint64_t v_rawSrtt_12334_; uint64_t v___x_12335_; uint8_t v___x_12336_;
v___x_12331_ = 7ULL;
v___x_12332_ = lean_uint64_mul(v___x_12331_, v___y_12327_);
v___x_12333_ = lean_uint64_add(v___x_12332_, v___y_12328_);
v_rawSrtt_12334_ = lean_uint64_shift_right(v___x_12333_, v___y_12326_);
v___x_12335_ = 1ULL;
v___x_12336_ = lean_uint64_dec_lt(v_rawSrtt_12334_, v___x_12335_);
if (v___x_12336_ == 0)
{
uint64_t v___x_12337_; uint8_t v___x_12338_;
v___x_12337_ = 60000ULL;
v___x_12338_ = lean_uint64_dec_lt(v___x_12337_, v_rawSrtt_12334_);
if (v___x_12338_ == 0)
{
uint32_t v___x_12339_;
v___x_12339_ = lean_uint64_to_uint32(v_rawSrtt_12334_);
v___y_12318_ = v___y_12330_;
v___y_12319_ = v___x_12339_;
goto v___jp_12317_;
}
else
{
v___y_12318_ = v___y_12330_;
v___y_12319_ = v___y_12329_;
goto v___jp_12317_;
}
}
else
{
uint32_t v___x_12340_;
v___x_12340_ = 1;
v___y_12318_ = v___y_12330_;
v___y_12319_ = v___x_12340_;
goto v___jp_12317_;
}
}
v___jp_12341_:
{
uint64_t v___x_12347_; uint64_t v___x_12348_; uint64_t v___x_12349_; uint64_t v___x_12350_; uint64_t v_rawVar_12351_; uint64_t v___x_12352_; uint8_t v___x_12353_;
v___x_12347_ = 3ULL;
v___x_12348_ = lean_uint64_mul(v___x_12347_, v___y_12342_);
v___x_12349_ = lean_uint64_add(v___x_12348_, v___y_12346_);
v___x_12350_ = 2ULL;
v_rawVar_12351_ = lean_uint64_shift_right(v___x_12349_, v___x_12350_);
v___x_12352_ = 10ULL;
v___x_12353_ = lean_uint64_dec_lt(v_rawVar_12351_, v___x_12352_);
if (v___x_12353_ == 0)
{
uint64_t v___x_12354_; uint8_t v___x_12355_;
v___x_12354_ = 60000ULL;
v___x_12355_ = lean_uint64_dec_lt(v___x_12354_, v_rawVar_12351_);
if (v___x_12355_ == 0)
{
uint32_t v___x_12356_;
v___x_12356_ = lean_uint64_to_uint32(v_rawVar_12351_);
v___y_12326_ = v___x_12347_;
v___y_12327_ = v___y_12343_;
v___y_12328_ = v___y_12344_;
v___y_12329_ = v___y_12345_;
v___y_12330_ = v___x_12356_;
goto v___jp_12325_;
}
else
{
v___y_12326_ = v___x_12347_;
v___y_12327_ = v___y_12343_;
v___y_12328_ = v___y_12344_;
v___y_12329_ = v___y_12345_;
v___y_12330_ = v___y_12345_;
goto v___jp_12325_;
}
}
else
{
uint32_t v___x_12357_;
v___x_12357_ = 10;
v___y_12326_ = v___x_12347_;
v___y_12327_ = v___y_12343_;
v___y_12328_ = v___y_12344_;
v___y_12329_ = v___y_12345_;
v___y_12330_ = v___x_12357_;
goto v___jp_12325_;
}
}
v___jp_12358_:
{
uint64_t v_sample64_12363_; uint8_t v___x_12364_;
v_sample64_12363_ = lean_uint32_to_uint64(v___y_12360_);
v___x_12364_ = lean_uint64_dec_le(v_sample64_12363_, v___y_12359_);
if (v___x_12364_ == 0)
{
uint64_t v___x_12365_;
v___x_12365_ = lean_uint64_sub(v_sample64_12363_, v___y_12359_);
v___y_12342_ = v___y_12362_;
v___y_12343_ = v___y_12359_;
v___y_12344_ = v_sample64_12363_;
v___y_12345_ = v___y_12361_;
v___y_12346_ = v___x_12365_;
goto v___jp_12341_;
}
else
{
uint64_t v___x_12366_;
v___x_12366_ = lean_uint64_sub(v___y_12359_, v_sample64_12363_);
v___y_12342_ = v___y_12362_;
v___y_12343_ = v___y_12359_;
v___y_12344_ = v_sample64_12363_;
v___y_12345_ = v___y_12361_;
v___y_12346_ = v___x_12366_;
goto v___jp_12341_;
}
}
v___jp_12367_:
{
uint8_t v___x_12371_;
v___x_12371_ = lean_uint32_dec_lt(v___y_12369_, v_rttVarMs_12307_);
if (v___x_12371_ == 0)
{
uint64_t v___x_12372_;
v___x_12372_ = lean_uint32_to_uint64(v_rttVarMs_12307_);
v___y_12359_ = v___y_12370_;
v___y_12360_ = v___y_12368_;
v___y_12361_ = v___y_12369_;
v___y_12362_ = v___x_12372_;
goto v___jp_12358_;
}
else
{
uint64_t v___x_12373_;
v___x_12373_ = 60000ULL;
v___y_12359_ = v___y_12370_;
v___y_12360_ = v___y_12368_;
v___y_12361_ = v___y_12369_;
v___y_12362_ = v___x_12373_;
goto v___jp_12358_;
}
}
v___jp_12375_:
{
uint8_t v___x_12377_;
v___x_12377_ = lean_uint32_dec_eq(v_srttMs_12306_, v___x_12374_);
if (v___x_12377_ == 0)
{
uint32_t v___x_12378_; uint8_t v___x_12379_;
v___x_12378_ = 60000;
v___x_12379_ = lean_uint32_dec_lt(v___x_12378_, v_srttMs_12306_);
if (v___x_12379_ == 0)
{
uint64_t v___x_12380_;
v___x_12380_ = lean_uint32_to_uint64(v_srttMs_12306_);
v___y_12368_ = v___y_12376_;
v___y_12369_ = v___x_12378_;
v___y_12370_ = v___x_12380_;
goto v___jp_12367_;
}
else
{
uint64_t v___x_12381_;
v___x_12381_ = 60000ULL;
v___y_12368_ = v___y_12376_;
v___y_12369_ = v___x_12378_;
v___y_12370_ = v___x_12381_;
goto v___jp_12367_;
}
}
else
{
uint32_t v___x_12382_; uint32_t v_halfSample_12383_; uint32_t v___x_12384_; uint8_t v___x_12385_;
v___x_12382_ = 1;
v_halfSample_12383_ = lean_uint32_shift_right(v___y_12376_, v___x_12382_);
v___x_12384_ = 50;
v___x_12385_ = lean_uint32_dec_lt(v_halfSample_12383_, v___x_12384_);
if (v___x_12385_ == 0)
{
v___y_12310_ = v___y_12376_;
v___y_12311_ = v_halfSample_12383_;
goto v___jp_12309_;
}
else
{
v___y_12310_ = v___y_12376_;
v___y_12311_ = v___x_12384_;
goto v___jp_12309_;
}
}
}
}
}

LEAN_EXPORT uint64_t orb_client_link_budget_step(uint32_t v_srttMs_12398_, uint32_t v_rttVarMs_12399_, uint32_t v_consecutiveFailures_12400_, uint8_t v_isConstrained_12401_, uint32_t v_p0InFlight_12402_){
_start:
{
uint32_t v___y_12404_; uint32_t v___y_12405_; uint32_t v___y_12406_; uint32_t v___y_12407_; uint32_t v___y_12408_; uint32_t v___y_12423_; uint32_t v___y_12424_; uint32_t v___y_12425_; uint32_t v___y_12426_; uint64_t v___y_12427_; uint64_t v___y_12436_; uint32_t v___y_12437_; uint32_t v___y_12438_; uint32_t v___y_12439_; uint64_t v___y_12440_; uint8_t v___y_12441_; uint32_t v___y_12442_; uint64_t v___y_12450_; uint32_t v___y_12451_; uint32_t v___y_12452_; uint32_t v___y_12453_; uint64_t v___y_12454_; uint64_t v___y_12455_; uint8_t v___y_12456_; uint64_t v___y_12457_; uint64_t v___y_12465_; uint32_t v___y_12466_; uint32_t v___y_12467_; uint64_t v___y_12468_; uint64_t v___y_12469_; uint8_t v___y_12470_; uint32_t v___y_12471_; uint64_t v___y_12478_; uint32_t v___y_12479_; uint64_t v___y_12480_; uint32_t v___y_12481_; uint64_t v___y_12482_; uint8_t v___y_12483_; uint64_t v___y_12484_; uint64_t v___y_12496_; uint32_t v___y_12497_; uint32_t v___y_12498_; uint64_t v___y_12499_; uint64_t v___y_12500_; uint64_t v___y_12510_; uint32_t v___y_12511_; uint32_t v___y_12512_; uint64_t v___y_12513_; uint32_t v___y_12519_; uint32_t v___y_12520_; uint32_t v___y_12521_; uint64_t v___y_12522_; uint32_t v___y_12527_; uint32_t v___y_12528_; uint8_t v___y_12534_; uint8_t v___y_12535_; uint32_t v___y_12536_; uint8_t v___y_12542_; uint8_t v___y_12546_; uint32_t v___x_12551_; uint8_t v___x_12552_;
v___x_12551_ = 1200;
v___x_12552_ = lean_uint32_dec_lt(v___x_12551_, v_srttMs_12398_);
if (v___x_12552_ == 0)
{
uint32_t v___x_12553_; uint8_t v___x_12554_;
v___x_12553_ = 0;
v___x_12554_ = lean_uint32_dec_lt(v___x_12553_, v_consecutiveFailures_12400_);
if (v___x_12554_ == 0)
{
uint8_t v___x_12555_; uint8_t v___x_12556_;
v___x_12555_ = 0;
v___x_12556_ = lean_uint8_dec_eq(v_isConstrained_12401_, v___x_12555_);
if (v___x_12556_ == 0)
{
uint8_t v___x_12557_;
v___x_12557_ = 1;
v___y_12542_ = v___x_12557_;
goto v___jp_12541_;
}
else
{
v___y_12546_ = v___x_12554_;
goto v___jp_12545_;
}
}
else
{
v___y_12546_ = v___x_12554_;
goto v___jp_12545_;
}
}
else
{
v___y_12546_ = v___x_12552_;
goto v___jp_12545_;
}
v___jp_12403_:
{
uint32_t v___x_12409_; uint32_t v___x_12410_; uint32_t v___x_12411_; uint32_t v___x_12412_; uint32_t v___x_12413_; uint32_t v_lo32_12414_; uint32_t v___x_12415_; uint32_t v_hi32_12416_; uint64_t v___x_12417_; uint64_t v___x_12418_; uint64_t v___x_12419_; uint64_t v___x_12420_; uint64_t v___x_12421_;
v___x_12409_ = 8;
v___x_12410_ = lean_uint32_shift_left(v___y_12406_, v___x_12409_);
v___x_12411_ = lean_uint32_lor(v___y_12405_, v___x_12410_);
v___x_12412_ = 16;
v___x_12413_ = lean_uint32_shift_left(v___y_12404_, v___x_12412_);
v_lo32_12414_ = lean_uint32_lor(v___x_12411_, v___x_12413_);
v___x_12415_ = lean_uint32_shift_left(v___y_12408_, v___x_12412_);
v_hi32_12416_ = lean_uint32_lor(v___y_12407_, v___x_12415_);
v___x_12417_ = lean_uint32_to_uint64(v_lo32_12414_);
v___x_12418_ = lean_uint32_to_uint64(v_hi32_12416_);
v___x_12419_ = 32ULL;
v___x_12420_ = lean_uint64_shift_left(v___x_12418_, v___x_12419_);
v___x_12421_ = lean_uint64_lor(v___x_12417_, v___x_12420_);
return v___x_12421_;
}
v___jp_12422_:
{
uint64_t v___x_12428_; uint8_t v___x_12429_;
v___x_12428_ = 6000ULL;
v___x_12429_ = lean_uint64_dec_lt(v___y_12427_, v___x_12428_);
if (v___x_12429_ == 0)
{
uint64_t v___x_12430_; uint8_t v___x_12431_;
v___x_12430_ = 15000ULL;
v___x_12431_ = lean_uint64_dec_lt(v___x_12430_, v___y_12427_);
if (v___x_12431_ == 0)
{
uint32_t v___x_12432_;
v___x_12432_ = lean_uint64_to_uint32(v___y_12427_);
v___y_12404_ = v___y_12423_;
v___y_12405_ = v___y_12424_;
v___y_12406_ = v___y_12425_;
v___y_12407_ = v___y_12426_;
v___y_12408_ = v___x_12432_;
goto v___jp_12403_;
}
else
{
uint32_t v___x_12433_;
v___x_12433_ = 15000;
v___y_12404_ = v___y_12423_;
v___y_12405_ = v___y_12424_;
v___y_12406_ = v___y_12425_;
v___y_12407_ = v___y_12426_;
v___y_12408_ = v___x_12433_;
goto v___jp_12403_;
}
}
else
{
uint32_t v___x_12434_;
v___x_12434_ = 6000;
v___y_12404_ = v___y_12423_;
v___y_12405_ = v___y_12424_;
v___y_12406_ = v___y_12425_;
v___y_12407_ = v___y_12426_;
v___y_12408_ = v___x_12434_;
goto v___jp_12403_;
}
}
v___jp_12435_:
{
if (v___y_12441_ == 0)
{
uint64_t v___x_12443_; uint64_t v___x_12444_; uint64_t v___x_12445_; uint64_t v___x_12446_; uint64_t v___x_12447_;
v___x_12443_ = 1ULL;
v___x_12444_ = lean_uint64_shift_left(v___y_12440_, v___x_12443_);
v___x_12445_ = lean_uint64_add(v___y_12436_, v___x_12444_);
v___x_12446_ = 2500ULL;
v___x_12447_ = lean_uint64_add(v___x_12445_, v___x_12446_);
v___y_12423_ = v___y_12437_;
v___y_12424_ = v___y_12438_;
v___y_12425_ = v___y_12439_;
v___y_12426_ = v___y_12442_;
v___y_12427_ = v___x_12447_;
goto v___jp_12422_;
}
else
{
uint64_t v___x_12448_;
v___x_12448_ = 6000ULL;
v___y_12423_ = v___y_12437_;
v___y_12424_ = v___y_12438_;
v___y_12425_ = v___y_12439_;
v___y_12426_ = v___y_12442_;
v___y_12427_ = v___x_12448_;
goto v___jp_12422_;
}
}
v___jp_12449_:
{
uint8_t v___x_12458_;
v___x_12458_ = lean_uint64_dec_lt(v___y_12457_, v___y_12454_);
if (v___x_12458_ == 0)
{
uint64_t v___x_12459_; uint8_t v___x_12460_;
v___x_12459_ = 25000ULL;
v___x_12460_ = lean_uint64_dec_lt(v___x_12459_, v___y_12457_);
if (v___x_12460_ == 0)
{
uint32_t v___x_12461_;
v___x_12461_ = lean_uint64_to_uint32(v___y_12457_);
v___y_12436_ = v___y_12450_;
v___y_12437_ = v___y_12451_;
v___y_12438_ = v___y_12452_;
v___y_12439_ = v___y_12453_;
v___y_12440_ = v___y_12455_;
v___y_12441_ = v___y_12456_;
v___y_12442_ = v___x_12461_;
goto v___jp_12435_;
}
else
{
uint32_t v___x_12462_;
v___x_12462_ = 25000;
v___y_12436_ = v___y_12450_;
v___y_12437_ = v___y_12451_;
v___y_12438_ = v___y_12452_;
v___y_12439_ = v___y_12453_;
v___y_12440_ = v___y_12455_;
v___y_12441_ = v___y_12456_;
v___y_12442_ = v___x_12462_;
goto v___jp_12435_;
}
}
else
{
uint32_t v___x_12463_;
v___x_12463_ = 8000;
v___y_12436_ = v___y_12450_;
v___y_12437_ = v___y_12451_;
v___y_12438_ = v___y_12452_;
v___y_12439_ = v___y_12453_;
v___y_12440_ = v___y_12455_;
v___y_12441_ = v___y_12456_;
v___y_12442_ = v___x_12463_;
goto v___jp_12435_;
}
}
v___jp_12464_:
{
if (v___y_12470_ == 0)
{
uint64_t v___x_12472_; uint64_t v___x_12473_; uint64_t v___x_12474_; uint64_t v___x_12475_; uint64_t v___x_12476_;
v___x_12472_ = 2ULL;
v___x_12473_ = lean_uint64_shift_left(v___y_12469_, v___x_12472_);
v___x_12474_ = lean_uint64_add(v___y_12465_, v___x_12473_);
v___x_12475_ = 3000ULL;
v___x_12476_ = lean_uint64_add(v___x_12474_, v___x_12475_);
v___y_12450_ = v___y_12465_;
v___y_12451_ = v___y_12471_;
v___y_12452_ = v___y_12466_;
v___y_12453_ = v___y_12467_;
v___y_12454_ = v___y_12468_;
v___y_12455_ = v___y_12469_;
v___y_12456_ = v___y_12470_;
v___y_12457_ = v___x_12476_;
goto v___jp_12449_;
}
else
{
v___y_12450_ = v___y_12465_;
v___y_12451_ = v___y_12471_;
v___y_12452_ = v___y_12466_;
v___y_12453_ = v___y_12467_;
v___y_12454_ = v___y_12468_;
v___y_12455_ = v___y_12469_;
v___y_12456_ = v___y_12470_;
v___y_12457_ = v___y_12468_;
goto v___jp_12449_;
}
}
v___jp_12477_:
{
uint64_t v___x_12485_; uint64_t v___x_12486_; uint64_t v_rawConn_12487_; uint64_t v___x_12488_; uint8_t v___x_12489_;
v___x_12485_ = 2000ULL;
v___x_12486_ = lean_uint64_mul(v___x_12485_, v___y_12480_);
v_rawConn_12487_ = lean_uint64_add(v___y_12484_, v___x_12486_);
v___x_12488_ = 8000ULL;
v___x_12489_ = lean_uint64_dec_lt(v_rawConn_12487_, v___x_12488_);
if (v___x_12489_ == 0)
{
uint64_t v___x_12490_; uint8_t v___x_12491_;
v___x_12490_ = 30000ULL;
v___x_12491_ = lean_uint64_dec_lt(v___x_12490_, v_rawConn_12487_);
if (v___x_12491_ == 0)
{
uint32_t v___x_12492_;
v___x_12492_ = lean_uint64_to_uint32(v_rawConn_12487_);
v___y_12465_ = v___y_12478_;
v___y_12466_ = v___y_12479_;
v___y_12467_ = v___y_12481_;
v___y_12468_ = v___x_12488_;
v___y_12469_ = v___y_12482_;
v___y_12470_ = v___y_12483_;
v___y_12471_ = v___x_12492_;
goto v___jp_12464_;
}
else
{
uint32_t v___x_12493_;
v___x_12493_ = 30000;
v___y_12465_ = v___y_12478_;
v___y_12466_ = v___y_12479_;
v___y_12467_ = v___y_12481_;
v___y_12468_ = v___x_12488_;
v___y_12469_ = v___y_12482_;
v___y_12470_ = v___y_12483_;
v___y_12471_ = v___x_12493_;
goto v___jp_12464_;
}
}
else
{
uint32_t v___x_12494_;
v___x_12494_ = 8000;
v___y_12465_ = v___y_12478_;
v___y_12466_ = v___y_12479_;
v___y_12467_ = v___y_12481_;
v___y_12468_ = v___x_12488_;
v___y_12469_ = v___y_12482_;
v___y_12470_ = v___y_12483_;
v___y_12471_ = v___x_12494_;
goto v___jp_12464_;
}
}
v___jp_12495_:
{
uint64_t v___x_12501_; uint8_t v___x_12502_;
v___x_12501_ = 0ULL;
v___x_12502_ = lean_uint64_dec_eq(v___y_12496_, v___x_12501_);
if (v___x_12502_ == 0)
{
uint64_t v___x_12503_; uint64_t v___x_12504_; uint64_t v___x_12505_; uint64_t v___x_12506_; uint64_t v___x_12507_;
v___x_12503_ = 2ULL;
v___x_12504_ = lean_uint64_shift_left(v___y_12499_, v___x_12503_);
v___x_12505_ = lean_uint64_add(v___y_12496_, v___x_12504_);
v___x_12506_ = 4000ULL;
v___x_12507_ = lean_uint64_add(v___x_12505_, v___x_12506_);
v___y_12478_ = v___y_12496_;
v___y_12479_ = v___y_12497_;
v___y_12480_ = v___y_12500_;
v___y_12481_ = v___y_12498_;
v___y_12482_ = v___y_12499_;
v___y_12483_ = v___x_12502_;
v___y_12484_ = v___x_12507_;
goto v___jp_12477_;
}
else
{
uint64_t v___x_12508_;
v___x_12508_ = 10000ULL;
v___y_12478_ = v___y_12496_;
v___y_12479_ = v___y_12497_;
v___y_12480_ = v___y_12500_;
v___y_12481_ = v___y_12498_;
v___y_12482_ = v___y_12499_;
v___y_12483_ = v___x_12502_;
v___y_12484_ = v___x_12508_;
goto v___jp_12477_;
}
}
v___jp_12509_:
{
uint32_t v___x_12514_; uint8_t v___x_12515_;
v___x_12514_ = 4;
v___x_12515_ = lean_uint32_dec_le(v___x_12514_, v_consecutiveFailures_12400_);
if (v___x_12515_ == 0)
{
uint64_t v___x_12516_;
v___x_12516_ = lean_uint32_to_uint64(v_consecutiveFailures_12400_);
v___y_12496_ = v___y_12510_;
v___y_12497_ = v___y_12511_;
v___y_12498_ = v___y_12512_;
v___y_12499_ = v___y_12513_;
v___y_12500_ = v___x_12516_;
goto v___jp_12495_;
}
else
{
uint64_t v___x_12517_;
v___x_12517_ = 4ULL;
v___y_12496_ = v___y_12510_;
v___y_12497_ = v___y_12511_;
v___y_12498_ = v___y_12512_;
v___y_12499_ = v___y_12513_;
v___y_12500_ = v___x_12517_;
goto v___jp_12495_;
}
}
v___jp_12518_:
{
uint8_t v___x_12523_;
v___x_12523_ = lean_uint32_dec_lt(v___y_12521_, v_rttVarMs_12399_);
if (v___x_12523_ == 0)
{
uint64_t v___x_12524_;
v___x_12524_ = lean_uint32_to_uint64(v_rttVarMs_12399_);
v___y_12510_ = v___y_12522_;
v___y_12511_ = v___y_12519_;
v___y_12512_ = v___y_12520_;
v___y_12513_ = v___x_12524_;
goto v___jp_12509_;
}
else
{
uint64_t v___x_12525_;
v___x_12525_ = 60000ULL;
v___y_12510_ = v___y_12522_;
v___y_12511_ = v___y_12519_;
v___y_12512_ = v___y_12520_;
v___y_12513_ = v___x_12525_;
goto v___jp_12509_;
}
}
v___jp_12526_:
{
uint32_t v___x_12529_; uint8_t v___x_12530_;
v___x_12529_ = 60000;
v___x_12530_ = lean_uint32_dec_lt(v___x_12529_, v_srttMs_12398_);
if (v___x_12530_ == 0)
{
uint64_t v___x_12531_;
v___x_12531_ = lean_uint32_to_uint64(v_srttMs_12398_);
v___y_12519_ = v___y_12527_;
v___y_12520_ = v___y_12528_;
v___y_12521_ = v___x_12529_;
v___y_12522_ = v___x_12531_;
goto v___jp_12518_;
}
else
{
uint64_t v___x_12532_;
v___x_12532_ = 60000ULL;
v___y_12519_ = v___y_12527_;
v___y_12520_ = v___y_12528_;
v___y_12521_ = v___x_12529_;
v___y_12522_ = v___x_12532_;
goto v___jp_12518_;
}
}
v___jp_12533_:
{
uint32_t v___x_12537_; uint8_t v___x_12538_;
v___x_12537_ = 0;
v___x_12538_ = lean_uint32_dec_lt(v___x_12537_, v_p0InFlight_12402_);
if (v___x_12538_ == 0)
{
if (v___y_12535_ == 0)
{
if (v___y_12534_ == 0)
{
uint32_t v___x_12539_;
v___x_12539_ = 4;
v___y_12527_ = v___y_12536_;
v___y_12528_ = v___x_12539_;
goto v___jp_12526_;
}
else
{
uint32_t v___x_12540_;
v___x_12540_ = 1;
v___y_12527_ = v___y_12536_;
v___y_12528_ = v___x_12540_;
goto v___jp_12526_;
}
}
else
{
v___y_12527_ = v___y_12536_;
v___y_12528_ = v___x_12537_;
goto v___jp_12526_;
}
}
else
{
v___y_12527_ = v___y_12536_;
v___y_12528_ = v___x_12537_;
goto v___jp_12526_;
}
}
v___jp_12541_:
{
uint8_t v___x_12543_; uint32_t v___x_12544_;
v___x_12543_ = 0;
v___x_12544_ = 2;
v___y_12534_ = v___x_12543_;
v___y_12535_ = v___y_12542_;
v___y_12536_ = v___x_12544_;
goto v___jp_12533_;
}
v___jp_12545_:
{
if (v___y_12546_ == 0)
{
uint32_t v___x_12547_; uint8_t v___x_12548_;
v___x_12547_ = 400;
v___x_12548_ = lean_uint32_dec_lt(v___x_12547_, v_srttMs_12398_);
if (v___x_12548_ == 0)
{
uint32_t v___x_12549_;
v___x_12549_ = 6;
v___y_12534_ = v___x_12548_;
v___y_12535_ = v___y_12546_;
v___y_12536_ = v___x_12549_;
goto v___jp_12533_;
}
else
{
uint32_t v___x_12550_;
v___x_12550_ = 3;
v___y_12534_ = v___x_12548_;
v___y_12535_ = v___y_12546_;
v___y_12536_ = v___x_12550_;
goto v___jp_12533_;
}
}
else
{
v___y_12542_ = v___y_12546_;
goto v___jp_12541_;
}
}
}
}

LEAN_EXPORT uint32_t orb_multiuser_rbac_step(uint8_t v_callerAuthed_12664_, uint8_t v_callerDisabled_12665_, uint8_t v_epochMatches_12666_, uint8_t v_callerRole_12667_, uint8_t v_opClass_12668_, uint8_t v_isOwner_12669_, uint8_t v_isSharedParticipant_12670_){
_start:
{
uint8_t v___x_12671_; uint8_t v___x_12672_;
v___x_12671_ = 1;
v___x_12672_ = lean_uint8_dec_eq(v_callerAuthed_12664_, v___x_12671_);
if (v___x_12672_ == 0)
{
uint32_t v___x_12673_;
v___x_12673_ = 131874;
return v___x_12673_;
}
else
{
uint8_t v___x_12674_;
v___x_12674_ = lean_uint8_dec_eq(v_epochMatches_12666_, v___x_12671_);
if (v___x_12674_ == 0)
{
uint32_t v___x_12675_;
v___x_12675_ = 131874;
return v___x_12675_;
}
else
{
uint8_t v___x_12676_; uint8_t v___x_12677_;
v___x_12676_ = 0;
v___x_12677_ = lean_uint8_dec_eq(v_callerDisabled_12665_, v___x_12676_);
if (v___x_12677_ == 0)
{
uint32_t v___x_12678_;
v___x_12678_ = 262950;
return v___x_12678_;
}
else
{
uint8_t v___x_12679_;
v___x_12679_ = lean_uint8_dec_lt(v___x_12671_, v_callerRole_12667_);
if (v___x_12679_ == 0)
{
uint8_t v___x_12680_;
v___x_12680_ = lean_uint8_dec_eq(v_opClass_12668_, v___x_12676_);
if (v___x_12680_ == 0)
{
uint8_t v___x_12681_;
v___x_12681_ = lean_uint8_dec_eq(v_opClass_12668_, v___x_12671_);
if (v___x_12681_ == 0)
{
uint8_t v___x_12682_; uint8_t v___x_12683_;
v___x_12682_ = 2;
v___x_12683_ = lean_uint8_dec_eq(v_opClass_12668_, v___x_12682_);
if (v___x_12683_ == 0)
{
uint8_t v___x_12684_; uint8_t v___x_12685_;
v___x_12684_ = 3;
v___x_12685_ = lean_uint8_dec_eq(v_opClass_12668_, v___x_12684_);
if (v___x_12685_ == 0)
{
uint8_t v___x_12686_; uint8_t v___x_12687_;
v___x_12686_ = 4;
v___x_12687_ = lean_uint8_dec_eq(v_opClass_12668_, v___x_12686_);
if (v___x_12687_ == 0)
{
uint32_t v___x_12688_;
v___x_12688_ = 787238;
return v___x_12688_;
}
else
{
uint8_t v___x_12689_;
v___x_12689_ = lean_uint8_dec_eq(v_isOwner_12669_, v___x_12671_);
if (v___x_12689_ == 0)
{
uint32_t v___x_12690_;
v___x_12690_ = 525096;
return v___x_12690_;
}
else
{
uint32_t v___x_12691_;
v___x_12691_ = 401;
return v___x_12691_;
}
}
}
else
{
uint8_t v___x_12692_;
v___x_12692_ = lean_uint8_dec_eq(v_isOwner_12669_, v___x_12671_);
if (v___x_12692_ == 0)
{
uint8_t v___x_12693_;
v___x_12693_ = lean_uint8_dec_eq(v_isSharedParticipant_12670_, v___x_12671_);
if (v___x_12693_ == 0)
{
uint32_t v___x_12694_;
v___x_12694_ = 525096;
return v___x_12694_;
}
else
{
uint32_t v___x_12695_;
v___x_12695_ = 656166;
return v___x_12695_;
}
}
else
{
uint32_t v___x_12696_;
v___x_12696_ = 401;
return v___x_12696_;
}
}
}
else
{
uint8_t v___x_12697_;
v___x_12697_ = lean_uint8_dec_eq(v_isOwner_12669_, v___x_12671_);
if (v___x_12697_ == 0)
{
uint8_t v___x_12698_;
v___x_12698_ = lean_uint8_dec_eq(v_isSharedParticipant_12670_, v___x_12671_);
if (v___x_12698_ == 0)
{
uint32_t v___x_12699_;
v___x_12699_ = 525096;
return v___x_12699_;
}
else
{
uint32_t v___x_12700_;
v___x_12700_ = 401;
return v___x_12700_;
}
}
else
{
uint32_t v___x_12701_;
v___x_12701_ = 401;
return v___x_12701_;
}
}
}
else
{
uint8_t v___x_12702_;
v___x_12702_ = lean_uint8_dec_eq(v_callerRole_12667_, v___x_12671_);
if (v___x_12702_ == 0)
{
uint32_t v___x_12703_;
v___x_12703_ = 394022;
return v___x_12703_;
}
else
{
uint32_t v___x_12704_;
v___x_12704_ = 401;
return v___x_12704_;
}
}
}
else
{
uint32_t v___x_12705_;
v___x_12705_ = 401;
return v___x_12705_;
}
}
else
{
uint32_t v___x_12706_;
v___x_12706_ = 787238;
return v___x_12706_;
}
}
}
}
}
}

LEAN_EXPORT uint8_t orb_placement_role_admit(uint8_t v_callerRole_12723_, uint8_t v_targetKind_12724_, uint8_t v_nodeAdminOnly_12725_, uint8_t v_hasValidUnixUser_12726_){
_start:
{
uint8_t v___x_12727_; uint8_t v___x_12728_;
v___x_12727_ = 4;
v___x_12728_ = lean_uint8_dec_lt(v___x_12727_, v_targetKind_12724_);
if (v___x_12728_ == 0)
{
uint8_t v___x_12729_; uint8_t v___x_12730_;
v___x_12729_ = 1;
v___x_12730_ = lean_uint8_dec_eq(v_callerRole_12723_, v___x_12729_);
if (v___x_12730_ == 0)
{
uint8_t v___x_12731_; uint8_t v___x_12735_;
v___x_12731_ = 0;
v___x_12735_ = lean_uint8_dec_eq(v_callerRole_12723_, v___x_12731_);
if (v___x_12735_ == 0)
{
return v___x_12731_;
}
else
{
uint8_t v___x_12736_;
v___x_12736_ = lean_uint8_dec_eq(v_targetKind_12724_, v___x_12727_);
if (v___x_12736_ == 0)
{
uint8_t v___x_12737_; uint8_t v___x_12738_;
v___x_12737_ = 2;
v___x_12738_ = lean_uint8_dec_eq(v_targetKind_12724_, v___x_12737_);
if (v___x_12738_ == 0)
{
uint8_t v___x_12739_; uint8_t v___x_12740_;
v___x_12739_ = 3;
v___x_12740_ = lean_uint8_dec_eq(v_targetKind_12724_, v___x_12739_);
if (v___x_12740_ == 0)
{
return v___x_12731_;
}
else
{
goto v___jp_12732_;
}
}
else
{
goto v___jp_12732_;
}
}
else
{
return v___x_12729_;
}
}
v___jp_12732_:
{
uint8_t v___x_12733_;
v___x_12733_ = lean_uint8_dec_eq(v_nodeAdminOnly_12725_, v___x_12731_);
if (v___x_12733_ == 0)
{
return v___x_12731_;
}
else
{
uint8_t v___x_12734_;
v___x_12734_ = lean_uint8_dec_eq(v_hasValidUnixUser_12726_, v___x_12729_);
if (v___x_12734_ == 0)
{
return v___x_12731_;
}
else
{
return v___x_12729_;
}
}
}
}
else
{
return v___x_12729_;
}
}
else
{
uint8_t v___x_12741_;
v___x_12741_ = 0;
return v___x_12741_;
}
}
}

LEAN_EXPORT uint64_t orb_user_spend_cap_step(uint8_t v_globalCapActive_12752_, uint32_t v_globalSpentCents_12753_, uint32_t v_globalCapCents_12754_, uint8_t v_userCapActive_12755_, uint32_t v_userSpentCents_12756_, uint32_t v_userCapCents_12757_, uint32_t v_deltaCents_12758_){
_start:
{
uint64_t v___y_12760_; uint8_t v___y_12761_; uint64_t v___y_12762_; uint64_t v___y_12763_; uint8_t v___y_12764_; uint64_t v___y_12765_; uint8_t v___y_12766_; uint64_t v___y_12795_; uint64_t v___y_12796_; uint64_t v___y_12797_; uint8_t v___y_12798_; uint8_t v___y_12799_; uint64_t v___y_12800_; uint8_t v___y_12801_; uint64_t v___y_12807_; uint64_t v___y_12808_; uint64_t v___y_12809_; uint64_t v___y_12810_; uint8_t v___y_12811_; uint64_t v_maxLedger64_12817_; uint64_t v___x_12818_; uint64_t v___y_12820_; uint64_t v___y_12821_; uint64_t v___y_12822_; uint64_t v___y_12829_; uint8_t v___x_12832_;
v_maxLedger64_12817_ = 1073741823ULL;
v___x_12818_ = lean_uint32_to_uint64(v_globalSpentCents_12753_);
v___x_12832_ = lean_uint64_dec_le(v___x_12818_, v_maxLedger64_12817_);
if (v___x_12832_ == 0)
{
v___y_12829_ = v_maxLedger64_12817_;
goto v___jp_12828_;
}
else
{
v___y_12829_ = v___x_12818_;
goto v___jp_12828_;
}
v___jp_12759_:
{
if (v___y_12761_ == 0)
{
if (v___y_12766_ == 0)
{
if (v___y_12764_ == 0)
{
uint64_t v___x_12767_; uint64_t v___x_12768_; uint64_t v___x_12769_; uint64_t v___x_12770_; uint64_t v___x_12771_; uint64_t v___x_12772_; uint64_t v___x_12773_;
v___x_12767_ = 1ULL;
v___x_12768_ = 4ULL;
v___x_12769_ = lean_uint64_shift_left(v___y_12760_, v___x_12768_);
v___x_12770_ = lean_uint64_lor(v___x_12767_, v___x_12769_);
v___x_12771_ = 34ULL;
v___x_12772_ = lean_uint64_shift_left(v___y_12763_, v___x_12771_);
v___x_12773_ = lean_uint64_lor(v___x_12770_, v___x_12772_);
return v___x_12773_;
}
else
{
uint64_t v___x_12774_; uint64_t v___x_12775_; uint64_t v___x_12776_; uint64_t v___x_12777_; uint64_t v___x_12778_; uint64_t v___x_12779_; uint64_t v___x_12780_;
v___x_12774_ = 6ULL;
v___x_12775_ = 4ULL;
v___x_12776_ = lean_uint64_shift_left(v___y_12765_, v___x_12775_);
v___x_12777_ = lean_uint64_lor(v___x_12774_, v___x_12776_);
v___x_12778_ = 34ULL;
v___x_12779_ = lean_uint64_shift_left(v___y_12762_, v___x_12778_);
v___x_12780_ = lean_uint64_lor(v___x_12777_, v___x_12779_);
return v___x_12780_;
}
}
else
{
uint64_t v___x_12781_; uint64_t v___x_12782_; uint64_t v___x_12783_; uint64_t v___x_12784_; uint64_t v___x_12785_; uint64_t v___x_12786_;
v___x_12781_ = 4ULL;
v___x_12782_ = lean_uint64_shift_left(v___y_12765_, v___x_12781_);
v___x_12783_ = lean_uint64_lor(v___x_12781_, v___x_12782_);
v___x_12784_ = 34ULL;
v___x_12785_ = lean_uint64_shift_left(v___y_12762_, v___x_12784_);
v___x_12786_ = lean_uint64_lor(v___x_12783_, v___x_12785_);
return v___x_12786_;
}
}
else
{
uint64_t v___x_12787_; uint64_t v___x_12788_; uint64_t v___x_12789_; uint64_t v___x_12790_; uint64_t v___x_12791_; uint64_t v___x_12792_; uint64_t v___x_12793_;
v___x_12787_ = 2ULL;
v___x_12788_ = 4ULL;
v___x_12789_ = lean_uint64_shift_left(v___y_12765_, v___x_12788_);
v___x_12790_ = lean_uint64_lor(v___x_12787_, v___x_12789_);
v___x_12791_ = 34ULL;
v___x_12792_ = lean_uint64_shift_left(v___y_12762_, v___x_12791_);
v___x_12793_ = lean_uint64_lor(v___x_12790_, v___x_12792_);
return v___x_12793_;
}
}
v___jp_12794_:
{
uint8_t v___x_12802_;
v___x_12802_ = lean_uint8_dec_eq(v_userCapActive_12755_, v___y_12799_);
if (v___x_12802_ == 0)
{
uint64_t v___x_12803_; uint8_t v___x_12804_;
v___x_12803_ = lean_uint32_to_uint64(v_userCapCents_12757_);
v___x_12804_ = lean_uint64_dec_lt(v___x_12803_, v___y_12797_);
v___y_12760_ = v___y_12795_;
v___y_12761_ = v___y_12801_;
v___y_12762_ = v___y_12796_;
v___y_12763_ = v___y_12797_;
v___y_12764_ = v___y_12798_;
v___y_12765_ = v___y_12800_;
v___y_12766_ = v___x_12804_;
goto v___jp_12759_;
}
else
{
uint8_t v___x_12805_;
v___x_12805_ = 0;
v___y_12760_ = v___y_12795_;
v___y_12761_ = v___y_12801_;
v___y_12762_ = v___y_12796_;
v___y_12763_ = v___y_12797_;
v___y_12764_ = v___y_12798_;
v___y_12765_ = v___y_12800_;
v___y_12766_ = v___x_12805_;
goto v___jp_12759_;
}
}
v___jp_12806_:
{
uint8_t v___x_12812_; uint8_t v___x_12813_;
v___x_12812_ = 0;
v___x_12813_ = lean_uint8_dec_eq(v_globalCapActive_12752_, v___x_12812_);
if (v___x_12813_ == 0)
{
uint64_t v___x_12814_; uint8_t v___x_12815_;
v___x_12814_ = lean_uint32_to_uint64(v_globalCapCents_12754_);
v___x_12815_ = lean_uint64_dec_lt(v___x_12814_, v___y_12807_);
v___y_12795_ = v___y_12807_;
v___y_12796_ = v___y_12808_;
v___y_12797_ = v___y_12809_;
v___y_12798_ = v___y_12811_;
v___y_12799_ = v___x_12812_;
v___y_12800_ = v___y_12810_;
v___y_12801_ = v___x_12815_;
goto v___jp_12794_;
}
else
{
uint8_t v___x_12816_;
v___x_12816_ = 0;
v___y_12795_ = v___y_12807_;
v___y_12796_ = v___y_12808_;
v___y_12797_ = v___y_12809_;
v___y_12798_ = v___y_12811_;
v___y_12799_ = v___x_12812_;
v___y_12800_ = v___y_12810_;
v___y_12801_ = v___x_12816_;
goto v___jp_12794_;
}
}
v___jp_12819_:
{
uint64_t v___x_12823_; uint64_t v_rawG64_12824_; uint64_t v_rawU64_12825_; uint8_t v___x_12826_;
v___x_12823_ = lean_uint32_to_uint64(v_deltaCents_12758_);
v_rawG64_12824_ = lean_uint64_add(v___x_12818_, v___x_12823_);
v_rawU64_12825_ = lean_uint64_add(v___y_12820_, v___x_12823_);
v___x_12826_ = lean_uint64_dec_lt(v_maxLedger64_12817_, v_rawG64_12824_);
if (v___x_12826_ == 0)
{
uint8_t v___x_12827_;
v___x_12827_ = lean_uint64_dec_lt(v_maxLedger64_12817_, v_rawU64_12825_);
v___y_12807_ = v_rawG64_12824_;
v___y_12808_ = v___y_12822_;
v___y_12809_ = v_rawU64_12825_;
v___y_12810_ = v___y_12821_;
v___y_12811_ = v___x_12827_;
goto v___jp_12806_;
}
else
{
v___y_12807_ = v_rawG64_12824_;
v___y_12808_ = v___y_12822_;
v___y_12809_ = v_rawU64_12825_;
v___y_12810_ = v___y_12821_;
v___y_12811_ = v___x_12826_;
goto v___jp_12806_;
}
}
v___jp_12828_:
{
uint64_t v___x_12830_; uint8_t v___x_12831_;
v___x_12830_ = lean_uint32_to_uint64(v_userSpentCents_12756_);
v___x_12831_ = lean_uint64_dec_le(v___x_12830_, v_maxLedger64_12817_);
if (v___x_12831_ == 0)
{
v___y_12820_ = v___x_12830_;
v___y_12821_ = v___y_12829_;
v___y_12822_ = v_maxLedger64_12817_;
goto v___jp_12819_;
}
else
{
v___y_12820_ = v___x_12830_;
v___y_12821_ = v___y_12829_;
v___y_12822_ = v___x_12830_;
goto v___jp_12819_;
}
}
}
}

LEAN_EXPORT uint32_t orb_privd_user_exec_step(uint8_t v_peerIsNodeUid_12849_, uint8_t v_leaseVerified_12850_, uint8_t v_nodeAdminOnly_12851_, uint8_t v_callerRole_12852_, uint8_t v_usernameValid_12853_, uint32_t v_targetUid_12854_, uint32_t v_targetGid_12855_, uint8_t v_gidDisjointPriv_12856_, uint8_t v_homeConfinedNoSymlink_12857_, uint8_t v_elanRootOwned_12858_){
_start:
{
uint8_t v___x_12859_; uint8_t v___x_12880_;
v___x_12859_ = 1;
v___x_12880_ = lean_uint8_dec_eq(v_peerIsNodeUid_12849_, v___x_12859_);
if (v___x_12880_ == 0)
{
uint32_t v___x_12881_;
v___x_12881_ = 256;
return v___x_12881_;
}
else
{
uint8_t v___x_12882_;
v___x_12882_ = lean_uint8_dec_eq(v_leaseVerified_12850_, v___x_12859_);
if (v___x_12882_ == 0)
{
uint32_t v___x_12883_;
v___x_12883_ = 512;
return v___x_12883_;
}
else
{
uint8_t v___x_12884_;
v___x_12884_ = lean_uint8_dec_lt(v___x_12859_, v_callerRole_12852_);
if (v___x_12884_ == 0)
{
uint8_t v___x_12885_; uint8_t v___x_12886_;
v___x_12885_ = 0;
v___x_12886_ = lean_uint8_dec_eq(v_callerRole_12852_, v___x_12885_);
if (v___x_12886_ == 0)
{
goto v___jp_12860_;
}
else
{
uint8_t v___x_12887_;
v___x_12887_ = lean_uint8_dec_eq(v_nodeAdminOnly_12851_, v___x_12885_);
if (v___x_12887_ == 0)
{
uint32_t v___x_12888_;
v___x_12888_ = 1024;
return v___x_12888_;
}
else
{
goto v___jp_12860_;
}
}
}
else
{
uint32_t v___x_12889_;
v___x_12889_ = 768;
return v___x_12889_;
}
}
}
v___jp_12860_:
{
uint8_t v___x_12861_;
v___x_12861_ = lean_uint8_dec_eq(v_usernameValid_12853_, v___x_12859_);
if (v___x_12861_ == 0)
{
uint32_t v___x_12862_;
v___x_12862_ = 1280;
return v___x_12862_;
}
else
{
uint32_t v___x_12863_; uint8_t v___x_12864_;
v___x_12863_ = 2000;
v___x_12864_ = lean_uint32_dec_lt(v_targetUid_12854_, v___x_12863_);
if (v___x_12864_ == 0)
{
uint32_t v___x_12865_; uint8_t v___x_12866_;
v___x_12865_ = 65534;
v___x_12866_ = lean_uint32_dec_le(v___x_12865_, v_targetUid_12854_);
if (v___x_12866_ == 0)
{
uint8_t v___x_12867_;
v___x_12867_ = lean_uint32_dec_lt(v_targetGid_12855_, v___x_12863_);
if (v___x_12867_ == 0)
{
uint8_t v___x_12868_;
v___x_12868_ = lean_uint32_dec_le(v___x_12865_, v_targetGid_12855_);
if (v___x_12868_ == 0)
{
uint8_t v___x_12869_;
v___x_12869_ = lean_uint8_dec_eq(v_gidDisjointPriv_12856_, v___x_12859_);
if (v___x_12869_ == 0)
{
uint32_t v___x_12870_;
v___x_12870_ = 1792;
return v___x_12870_;
}
else
{
uint8_t v___x_12871_;
v___x_12871_ = lean_uint8_dec_eq(v_homeConfinedNoSymlink_12857_, v___x_12859_);
if (v___x_12871_ == 0)
{
uint32_t v___x_12872_;
v___x_12872_ = 2048;
return v___x_12872_;
}
else
{
uint8_t v___x_12873_;
v___x_12873_ = lean_uint8_dec_eq(v_elanRootOwned_12858_, v___x_12859_);
if (v___x_12873_ == 0)
{
uint32_t v___x_12874_;
v___x_12874_ = 2304;
return v___x_12874_;
}
else
{
uint32_t v___x_12875_;
v___x_12875_ = 1;
return v___x_12875_;
}
}
}
}
else
{
uint32_t v___x_12876_;
v___x_12876_ = 1536;
return v___x_12876_;
}
}
else
{
uint32_t v___x_12877_;
v___x_12877_ = 1536;
return v___x_12877_;
}
}
else
{
uint32_t v___x_12878_;
v___x_12878_ = 1536;
return v___x_12878_;
}
}
else
{
uint32_t v___x_12879_;
v___x_12879_ = 1536;
return v___x_12879_;
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
