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
uint8_t v___x_7_; uint8_t v___y_9_; uint8_t v___x_13_; 
v___x_7_ = 1;
v___x_13_ = lean_uint8_dec_eq(v_hasContinue_1_, v___x_7_);
if (v___x_13_ == 0)
{
uint8_t v___x_14_; uint8_t v___x_15_; 
v___x_14_ = 0;
v___x_15_ = lean_uint8_dec_eq(v_workChanged_5_, v___x_14_);
if (v___x_15_ == 0)
{
uint8_t v___x_16_; 
v___x_16_ = lean_uint8_dec_eq(v_identityUpdated_6_, v___x_7_);
if (v___x_16_ == 0)
{
return v___x_14_;
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
uint8_t v___x_17_; 
v___x_17_ = lean_uint8_dec_eq(v_contTrackNonempty_2_, v___x_7_);
if (v___x_17_ == 0)
{
v___y_9_ = v___x_17_;
goto v___jp_8_;
}
else
{
uint8_t v___x_18_; 
v___x_18_ = lean_uint8_dec_eq(v_contMatchesStored_3_, v___x_7_);
v___y_9_ = v___x_18_;
goto v___jp_8_;
}
}
v___jp_8_:
{
if (v___y_9_ == 0)
{
uint8_t v___x_10_; 
v___x_10_ = 0;
return v___x_10_;
}
else
{
uint8_t v___x_11_; uint8_t v___x_12_; 
v___x_11_ = 0;
v___x_12_ = lean_uint8_dec_eq(v_hasAnyEdit_4_, v___x_11_);
if (v___x_12_ == 0)
{
return v___x_11_;
}
else
{
return v___x_7_;
}
}
}
}
}

LEAN_EXPORT uint8_t orb_verify_lease_mode(uint8_t v_writerFlag_33_, uint8_t v_hasReadonlyTag_34_, uint8_t v_hasWriterTag_35_, uint8_t v_isReadonlyIntent_36_){
_start:
{
uint8_t v___x_37_; uint8_t v___y_39_; uint8_t v___y_40_; uint8_t v___y_43_; uint8_t v___x_47_; 
v___x_37_ = 0;
v___x_47_ = lean_uint8_dec_eq(v_writerFlag_33_, v___x_37_);
if (v___x_47_ == 0)
{
uint8_t v___x_48_; uint8_t v___x_49_; 
v___x_48_ = 1;
v___x_49_ = lean_uint8_dec_eq(v_hasReadonlyTag_34_, v___x_48_);
v___y_43_ = v___x_49_;
goto v___jp_42_;
}
else
{
v___y_43_ = v___x_47_;
goto v___jp_42_;
}
v___jp_38_:
{
if (v___y_40_ == 0)
{
uint8_t v___x_41_; 
v___x_41_ = lean_uint8_dec_eq(v_isReadonlyIntent_36_, v___y_39_);
if (v___x_41_ == 0)
{
return v___y_39_;
}
else
{
return v___x_37_;
}
}
else
{
return v___y_39_;
}
}
v___jp_42_:
{
if (v___y_43_ == 0)
{
uint8_t v___x_44_; uint8_t v___x_45_; 
v___x_44_ = 1;
v___x_45_ = lean_uint8_dec_eq(v_writerFlag_33_, v___x_44_);
if (v___x_45_ == 0)
{
uint8_t v___x_46_; 
v___x_46_ = lean_uint8_dec_eq(v_hasWriterTag_35_, v___x_44_);
v___y_39_ = v___x_44_;
v___y_40_ = v___x_46_;
goto v___jp_38_;
}
else
{
v___y_39_ = v___x_44_;
v___y_40_ = v___x_45_;
goto v___jp_38_;
}
}
else
{
return v___x_37_;
}
}
}
}

LEAN_EXPORT uint8_t orb_verify_track_hold(uint8_t v_inUnresolved_60_, uint8_t v_inQueued_61_, uint8_t v_hasLiveOwner_62_, uint8_t v_nativeGoalHolds_63_){
_start:
{
uint8_t v___x_64_; uint8_t v___y_66_; uint8_t v___x_70_; 
v___x_64_ = 1;
v___x_70_ = lean_uint8_dec_eq(v_inUnresolved_60_, v___x_64_);
if (v___x_70_ == 0)
{
uint8_t v___x_71_; 
v___x_71_ = lean_uint8_dec_eq(v_inQueued_61_, v___x_64_);
v___y_66_ = v___x_71_;
goto v___jp_65_;
}
else
{
v___y_66_ = v___x_70_;
goto v___jp_65_;
}
v___jp_65_:
{
if (v___y_66_ == 0)
{
uint8_t v___x_67_; 
v___x_67_ = lean_uint8_dec_eq(v_hasLiveOwner_62_, v___x_64_);
if (v___x_67_ == 0)
{
uint8_t v___x_68_; 
v___x_68_ = lean_uint8_dec_eq(v_nativeGoalHolds_63_, v___x_64_);
if (v___x_68_ == 0)
{
uint8_t v___x_69_; 
v___x_69_ = 0;
return v___x_69_;
}
else
{
return v___x_64_;
}
}
else
{
return v___x_64_;
}
}
else
{
return v___x_64_;
}
}
}
}

LEAN_EXPORT uint8_t orb_verify_repo_disjoint(uint8_t v_handleRepoKnown_82_, uint8_t v_targetRepoKnown_83_, uint8_t v_sameRepo_84_){
_start:
{
uint8_t v___x_85_; uint8_t v___y_87_; uint8_t v___x_91_; 
v___x_85_ = 1;
v___x_91_ = lean_uint8_dec_eq(v_handleRepoKnown_82_, v___x_85_);
if (v___x_91_ == 0)
{
v___y_87_ = v___x_91_;
goto v___jp_86_;
}
else
{
uint8_t v___x_92_; 
v___x_92_ = lean_uint8_dec_eq(v_targetRepoKnown_83_, v___x_85_);
v___y_87_ = v___x_92_;
goto v___jp_86_;
}
v___jp_86_:
{
if (v___y_87_ == 0)
{
uint8_t v___x_88_; 
v___x_88_ = 0;
return v___x_88_;
}
else
{
uint8_t v___x_89_; uint8_t v___x_90_; 
v___x_89_ = 0;
v___x_90_ = lean_uint8_dec_eq(v_sameRepo_84_, v___x_89_);
if (v___x_90_ == 0)
{
return v___x_89_;
}
else
{
return v___x_85_;
}
}
}
}
}

LEAN_EXPORT uint8_t orb_verify_remote_outbox(uint8_t v_opKind_101_, uint8_t v_alreadyExists_102_, uint8_t v_sameMission_103_, uint8_t v_isCancelled_104_, uint8_t v_isSuperseded_105_, uint8_t v_sessionReady_106_, uint8_t v_prUnsupported_107_, uint8_t v_hasJobId_108_, uint8_t v_deliveryAbandonable_109_){
_start:
{
uint8_t v___x_110_; uint8_t v___y_112_; uint8_t v___y_120_; uint8_t v___y_123_; uint8_t v___y_131_; uint8_t v___x_133_; 
v___x_110_ = 0;
v___x_133_ = lean_uint8_dec_eq(v_opKind_101_, v___x_110_);
if (v___x_133_ == 0)
{
v___y_120_ = v___x_133_;
goto v___jp_119_;
}
else
{
uint8_t v___x_134_; uint8_t v___x_135_; 
v___x_134_ = 1;
v___x_135_ = lean_uint8_dec_eq(v_alreadyExists_102_, v___x_134_);
if (v___x_135_ == 0)
{
v___y_131_ = v___x_135_;
goto v___jp_130_;
}
else
{
uint8_t v___x_136_; 
v___x_136_ = lean_uint8_dec_eq(v_sameMission_103_, v___x_134_);
v___y_131_ = v___x_136_;
goto v___jp_130_;
}
}
v___jp_111_:
{
if (v___y_112_ == 0)
{
return v___x_110_;
}
else
{
uint8_t v___x_113_; 
v___x_113_ = 1;
return v___x_113_;
}
}
v___jp_114_:
{
uint8_t v___x_115_; 
v___x_115_ = lean_uint8_dec_eq(v_opKind_101_, v___x_110_);
if (v___x_115_ == 0)
{
uint8_t v___x_116_; 
v___x_116_ = lean_uint8_dec_eq(v_hasJobId_108_, v___x_110_);
if (v___x_116_ == 0)
{
uint8_t v___x_117_; uint8_t v___x_118_; 
v___x_117_ = 1;
v___x_118_ = lean_uint8_dec_eq(v_deliveryAbandonable_109_, v___x_117_);
v___y_112_ = v___x_118_;
goto v___jp_111_;
}
else
{
v___y_112_ = v___x_116_;
goto v___jp_111_;
}
}
else
{
return v___x_110_;
}
}
v___jp_119_:
{
if (v___y_120_ == 0)
{
goto v___jp_114_;
}
else
{
uint8_t v___x_121_; 
v___x_121_ = 1;
return v___x_121_;
}
}
v___jp_122_:
{
if (v___y_123_ == 0)
{
goto v___jp_114_;
}
else
{
uint8_t v___x_124_; uint8_t v___x_125_; 
v___x_124_ = 1;
v___x_125_ = lean_uint8_dec_eq(v_sessionReady_106_, v___x_124_);
if (v___x_125_ == 0)
{
v___y_120_ = v___x_125_;
goto v___jp_119_;
}
else
{
uint8_t v___x_126_; 
v___x_126_ = lean_uint8_dec_eq(v_prUnsupported_107_, v___x_110_);
v___y_120_ = v___x_126_;
goto v___jp_119_;
}
}
}
v___jp_127_:
{
uint8_t v___x_128_; 
v___x_128_ = lean_uint8_dec_eq(v_alreadyExists_102_, v___x_110_);
if (v___x_128_ == 0)
{
v___y_123_ = v___x_128_;
goto v___jp_122_;
}
else
{
uint8_t v___x_129_; 
v___x_129_ = lean_uint8_dec_eq(v_isSuperseded_105_, v___x_110_);
v___y_123_ = v___x_129_;
goto v___jp_122_;
}
}
v___jp_130_:
{
if (v___y_131_ == 0)
{
goto v___jp_127_;
}
else
{
uint8_t v___x_132_; 
v___x_132_ = lean_uint8_dec_eq(v_isCancelled_104_, v___x_110_);
if (v___x_132_ == 0)
{
goto v___jp_127_;
}
else
{
v___y_120_ = v___x_132_;
goto v___jp_119_;
}
}
}
}
}

LEAN_EXPORT uint8_t orb_verify_board_slots(uint32_t v_maxParallel_157_, uint32_t v_reservedBossSlots_158_, uint32_t v_totalRunning_159_){
_start:
{
uint8_t v___y_161_; uint8_t v___x_167_; uint32_t v___x_168_; uint8_t v___x_169_; 
v___x_167_ = lean_uint32_dec_lt(v_reservedBossSlots_158_, v_maxParallel_157_);
v___x_168_ = 1;
v___x_169_ = lean_uint32_dec_le(v___x_168_, v_reservedBossSlots_158_);
if (v___x_169_ == 0)
{
v___y_161_ = v___x_169_;
goto v___jp_160_;
}
else
{
v___y_161_ = v___x_167_;
goto v___jp_160_;
}
v___jp_160_:
{
if (v___y_161_ == 0)
{
uint8_t v___x_162_; 
v___x_162_ = 0;
return v___x_162_;
}
else
{
uint32_t v___x_163_; uint8_t v___x_164_; 
v___x_163_ = lean_uint32_sub(v_maxParallel_157_, v_reservedBossSlots_158_);
v___x_164_ = lean_uint32_dec_lt(v_totalRunning_159_, v___x_163_);
if (v___x_164_ == 0)
{
uint8_t v___x_165_; 
v___x_165_ = 0;
return v___x_165_;
}
else
{
uint8_t v___x_166_; 
v___x_166_ = 1;
return v___x_166_;
}
}
}
}
}

LEAN_EXPORT uint8_t orb_verify_board_retry(uint32_t v_attempts_178_, uint32_t v_maxAttempts_179_, uint8_t v_requiresExternalRecovery_180_, uint8_t v_preflightMerged_181_, uint8_t v_chatgptUiBlocked_182_){
_start:
{
uint8_t v___y_184_; uint8_t v___x_191_; uint32_t v___x_192_; uint8_t v___x_193_; 
v___x_191_ = lean_uint32_dec_lt(v_attempts_178_, v_maxAttempts_179_);
v___x_192_ = 1;
v___x_193_ = lean_uint32_dec_le(v___x_192_, v_maxAttempts_179_);
if (v___x_193_ == 0)
{
v___y_184_ = v___x_193_;
goto v___jp_183_;
}
else
{
v___y_184_ = v___x_191_;
goto v___jp_183_;
}
v___jp_183_:
{
if (v___y_184_ == 0)
{
uint8_t v___x_185_; 
v___x_185_ = 0;
return v___x_185_;
}
else
{
uint8_t v___x_186_; uint8_t v___x_187_; 
v___x_186_ = 0;
v___x_187_ = lean_uint8_dec_eq(v_requiresExternalRecovery_180_, v___x_186_);
if (v___x_187_ == 0)
{
return v___x_186_;
}
else
{
uint8_t v___x_188_; 
v___x_188_ = lean_uint8_dec_eq(v_preflightMerged_181_, v___x_186_);
if (v___x_188_ == 0)
{
return v___x_186_;
}
else
{
uint8_t v___x_189_; 
v___x_189_ = lean_uint8_dec_eq(v_chatgptUiBlocked_182_, v___x_186_);
if (v___x_189_ == 0)
{
return v___x_186_;
}
else
{
uint8_t v___x_190_; 
v___x_190_ = 1;
return v___x_190_;
}
}
}
}
}
}
}

LEAN_EXPORT uint8_t orb_verify_job_transition(uint8_t v_fromState_206_, uint8_t v_toState_207_){
_start:
{
uint8_t v___x_208_; uint8_t v___y_210_; uint8_t v___y_218_; uint8_t v___y_228_; uint8_t v___x_232_; 
v___x_208_ = 0;
v___x_232_ = lean_uint8_dec_eq(v_fromState_206_, v___x_208_);
if (v___x_232_ == 0)
{
v___y_228_ = v___x_232_;
goto v___jp_227_;
}
else
{
uint8_t v___x_233_; uint8_t v___x_234_; 
v___x_233_ = 1;
v___x_234_ = lean_uint8_dec_le(v___x_233_, v_toState_207_);
v___y_228_ = v___x_234_;
goto v___jp_227_;
}
v___jp_209_:
{
if (v___y_210_ == 0)
{
return v___x_208_;
}
else
{
uint8_t v___x_211_; 
v___x_211_ = 1;
return v___x_211_;
}
}
v___jp_212_:
{
uint8_t v___x_213_; uint8_t v___x_214_; 
v___x_213_ = 5;
v___x_214_ = lean_uint8_dec_eq(v_fromState_206_, v___x_213_);
if (v___x_214_ == 0)
{
v___y_210_ = v___x_214_;
goto v___jp_209_;
}
else
{
uint8_t v___x_215_; uint8_t v___x_216_; 
v___x_215_ = 4;
v___x_216_ = lean_uint8_dec_eq(v_toState_207_, v___x_215_);
v___y_210_ = v___x_216_;
goto v___jp_209_;
}
}
v___jp_217_:
{
if (v___y_218_ == 0)
{
goto v___jp_212_;
}
else
{
uint8_t v___x_219_; uint8_t v___x_220_; 
v___x_219_ = 5;
v___x_220_ = lean_uint8_dec_le(v_toState_207_, v___x_219_);
if (v___x_220_ == 0)
{
goto v___jp_212_;
}
else
{
uint8_t v___x_221_; 
v___x_221_ = 1;
return v___x_221_;
}
}
}
v___jp_222_:
{
uint8_t v___x_223_; uint8_t v___x_224_; 
v___x_223_ = 1;
v___x_224_ = lean_uint8_dec_eq(v_fromState_206_, v___x_223_);
if (v___x_224_ == 0)
{
v___y_218_ = v___x_224_;
goto v___jp_217_;
}
else
{
uint8_t v___x_225_; uint8_t v___x_226_; 
v___x_225_ = 2;
v___x_226_ = lean_uint8_dec_le(v___x_225_, v_toState_207_);
v___y_218_ = v___x_226_;
goto v___jp_217_;
}
}
v___jp_227_:
{
if (v___y_228_ == 0)
{
goto v___jp_222_;
}
else
{
uint8_t v___x_229_; uint8_t v___x_230_; 
v___x_229_ = 5;
v___x_230_ = lean_uint8_dec_le(v_toState_207_, v___x_229_);
if (v___x_230_ == 0)
{
goto v___jp_222_;
}
else
{
uint8_t v___x_231_; 
v___x_231_ = 1;
return v___x_231_;
}
}
}
}
}

LEAN_EXPORT uint8_t orb_verify_bundle_budget(uint8_t v_isComplete_241_, uint64_t v_decodedBytes_242_, uint64_t v_overlayCap_243_, uint64_t v_completeCap_244_, uint64_t v_maxBytes_245_){
_start:
{
uint8_t v___x_246_; uint8_t v___y_248_; uint8_t v___x_250_; uint8_t v___x_251_; uint64_t v___y_253_; 
v___x_246_ = 1;
v___x_250_ = lean_uint8_dec_eq(v_isComplete_241_, v___x_246_);
v___x_251_ = lean_uint64_dec_le(v_decodedBytes_242_, v_maxBytes_245_);
if (v___x_250_ == 0)
{
v___y_253_ = v_overlayCap_243_;
goto v___jp_252_;
}
else
{
v___y_253_ = v_completeCap_244_;
goto v___jp_252_;
}
v___jp_247_:
{
if (v___y_248_ == 0)
{
uint8_t v___x_249_; 
v___x_249_ = 0;
return v___x_249_;
}
else
{
return v___x_246_;
}
}
v___jp_252_:
{
uint8_t v___x_254_; 
v___x_254_ = lean_uint64_dec_le(v_decodedBytes_242_, v___y_253_);
if (v___x_254_ == 0)
{
v___y_248_ = v___x_254_;
goto v___jp_247_;
}
else
{
v___y_248_ = v___x_251_;
goto v___jp_247_;
}
}
}
}

LEAN_EXPORT uint8_t orb_verify_token_rotation(uint8_t v_presentedNonEmpty_267_, uint8_t v_matchCurrent_268_, uint8_t v_prevNonEmpty_269_, uint8_t v_matchPrev_270_, uint8_t v_scopeAndExpiryOk_271_){
_start:
{
uint8_t v___x_272_; uint8_t v___y_274_; uint8_t v___x_278_; 
v___x_272_ = 1;
v___x_278_ = lean_uint8_dec_eq(v_presentedNonEmpty_267_, v___x_272_);
if (v___x_278_ == 0)
{
v___y_274_ = v___x_278_;
goto v___jp_273_;
}
else
{
uint8_t v___x_279_; 
v___x_279_ = lean_uint8_dec_eq(v_matchCurrent_268_, v___x_272_);
if (v___x_279_ == 0)
{
uint8_t v___x_280_; 
v___x_280_ = lean_uint8_dec_eq(v_prevNonEmpty_269_, v___x_272_);
if (v___x_280_ == 0)
{
v___y_274_ = v___x_280_;
goto v___jp_273_;
}
else
{
uint8_t v___x_281_; 
v___x_281_ = lean_uint8_dec_eq(v_matchPrev_270_, v___x_272_);
v___y_274_ = v___x_281_;
goto v___jp_273_;
}
}
else
{
v___y_274_ = v___x_279_;
goto v___jp_273_;
}
}
v___jp_273_:
{
if (v___y_274_ == 0)
{
uint8_t v___x_275_; 
v___x_275_ = 0;
return v___x_275_;
}
else
{
uint8_t v___x_276_; 
v___x_276_ = lean_uint8_dec_eq(v_scopeAndExpiryOk_271_, v___x_272_);
if (v___x_276_ == 0)
{
uint8_t v___x_277_; 
v___x_277_ = 0;
return v___x_277_;
}
else
{
return v___x_272_;
}
}
}
}
}

LEAN_EXPORT uint8_t orb_verify_log_window(uint64_t v_offset_294_, uint64_t v_reqLen_295_, uint64_t v_maxChunk_296_, uint64_t v_hardCap_297_, uint64_t v_fileSize_298_, uint64_t v_actualLen_299_){
_start:
{
uint8_t v___x_300_; uint8_t v___x_301_; uint8_t v___y_303_; uint8_t v___x_311_; 
v___x_300_ = lean_uint64_dec_le(v_actualLen_299_, v_reqLen_295_);
v___x_301_ = lean_uint64_dec_le(v_maxChunk_296_, v_hardCap_297_);
v___x_311_ = lean_uint64_dec_le(v_offset_294_, v_fileSize_298_);
if (v___x_311_ == 0)
{
v___y_303_ = v___x_311_;
goto v___jp_302_;
}
else
{
uint8_t v___x_312_; 
v___x_312_ = lean_uint64_dec_le(v_reqLen_295_, v_maxChunk_296_);
v___y_303_ = v___x_312_;
goto v___jp_302_;
}
v___jp_302_:
{
if (v___y_303_ == 0)
{
uint8_t v___x_304_; 
v___x_304_ = 0;
return v___x_304_;
}
else
{
if (v___x_301_ == 0)
{
uint8_t v___x_305_; 
v___x_305_ = 0;
return v___x_305_;
}
else
{
if (v___x_300_ == 0)
{
uint8_t v___x_306_; 
v___x_306_ = 0;
return v___x_306_;
}
else
{
uint64_t v___x_307_; uint8_t v___x_308_; 
v___x_307_ = lean_uint64_sub(v_fileSize_298_, v_offset_294_);
v___x_308_ = lean_uint64_dec_le(v_actualLen_299_, v___x_307_);
if (v___x_308_ == 0)
{
uint8_t v___x_309_; 
v___x_309_ = 0;
return v___x_309_;
}
else
{
uint8_t v___x_310_; 
v___x_310_ = 1;
return v___x_310_;
}
}
}
}
}
}
}

LEAN_EXPORT uint64_t orb_mix64_word(uint64_t v_acc_327_, uint64_t v_word_328_){
_start:
{
uint64_t v___x_329_; uint64_t v___x_330_; uint64_t v_v1_331_; uint64_t v___x_332_; uint64_t v___x_333_; uint64_t v___x_334_; uint64_t v___x_335_; uint64_t v_v2_336_; uint64_t v___x_337_; uint64_t v_v3_338_; uint64_t v___x_339_; uint64_t v___x_340_; uint64_t v___x_341_; 
v___x_329_ = 13787848793156543929ULL;
v___x_330_ = lean_uint64_mul(v_word_328_, v___x_329_);
v_v1_331_ = lean_uint64_add(v_acc_327_, v___x_330_);
v___x_332_ = 31ULL;
v___x_333_ = lean_uint64_shift_left(v_v1_331_, v___x_332_);
v___x_334_ = 33ULL;
v___x_335_ = lean_uint64_shift_right(v_v1_331_, v___x_334_);
v_v2_336_ = lean_uint64_lor(v___x_333_, v___x_335_);
v___x_337_ = 11400714819323198485ULL;
v_v3_338_ = lean_uint64_mul(v_v2_336_, v___x_337_);
v___x_339_ = 27ULL;
v___x_340_ = lean_uint64_shift_right(v_v3_338_, v___x_339_);
v___x_341_ = lean_uint64_xor(v_v3_338_, v___x_340_);
return v___x_341_;
}
}

LEAN_EXPORT uint32_t orb_proxy_step(uint8_t v_committed_348_, uint8_t v_chunkCommits_349_, uint8_t v_stalled_350_, uint32_t v_retries_351_, uint32_t v_maxRetries_352_){
_start:
{
uint32_t v___y_354_; uint8_t v___y_355_; uint8_t v___x_366_; uint32_t v___y_368_; uint8_t v___y_374_; uint8_t v___x_377_; 
v___x_366_ = 1;
v___x_377_ = lean_uint8_dec_eq(v_committed_348_, v___x_366_);
if (v___x_377_ == 0)
{
uint8_t v___x_378_; 
v___x_378_ = lean_uint8_dec_eq(v_chunkCommits_349_, v___x_366_);
v___y_374_ = v___x_378_;
goto v___jp_373_;
}
else
{
v___y_374_ = v___x_377_;
goto v___jp_373_;
}
v___jp_353_:
{
if (v___y_355_ == 0)
{
uint32_t v___x_356_; uint32_t v___x_357_; 
v___x_356_ = 768;
v___x_357_ = lean_uint32_lor(v___y_354_, v___x_356_);
return v___x_357_;
}
else
{
uint32_t v___x_358_; uint32_t v___x_359_; uint32_t v___x_360_; uint8_t v___x_361_; 
v___x_358_ = 2;
v___x_359_ = 1;
v___x_360_ = lean_uint32_add(v_retries_351_, v___x_359_);
v___x_361_ = lean_uint32_dec_le(v___x_358_, v___x_360_);
if (v___x_361_ == 0)
{
uint32_t v___x_362_; uint32_t v___x_363_; 
v___x_362_ = 256;
v___x_363_ = lean_uint32_lor(v___y_354_, v___x_362_);
return v___x_363_;
}
else
{
uint32_t v___x_364_; uint32_t v___x_365_; 
v___x_364_ = 66048;
v___x_365_ = lean_uint32_lor(v___y_354_, v___x_364_);
return v___x_365_;
}
}
}
v___jp_367_:
{
uint8_t v___x_369_; 
v___x_369_ = lean_uint8_dec_eq(v_stalled_350_, v___x_366_);
if (v___x_369_ == 0)
{
return v___y_368_;
}
else
{
uint8_t v___x_370_; uint8_t v___x_371_; 
v___x_370_ = 0;
v___x_371_ = lean_uint8_dec_eq(v_committed_348_, v___x_370_);
if (v___x_371_ == 0)
{
v___y_354_ = v___y_368_;
v___y_355_ = v___x_371_;
goto v___jp_353_;
}
else
{
uint8_t v___x_372_; 
v___x_372_ = lean_uint32_dec_lt(v_retries_351_, v_maxRetries_352_);
v___y_354_ = v___y_368_;
v___y_355_ = v___x_372_;
goto v___jp_353_;
}
}
}
v___jp_373_:
{
if (v___y_374_ == 0)
{
uint32_t v___x_375_; 
v___x_375_ = 0;
v___y_368_ = v___x_375_;
goto v___jp_367_;
}
else
{
uint32_t v___x_376_; 
v___x_376_ = 1;
v___y_368_ = v___x_376_;
goto v___jp_367_;
}
}
}
}

LEAN_EXPORT uint32_t orb_stream_deadlines(uint64_t v_clientElapsedMs_391_, uint64_t v_keepaliveMs_392_, uint64_t v_upstreamElapsedMs_393_, uint64_t v_baseIdleMs_394_, uint64_t v_providerFloorMs_395_, uint8_t v_atEventBoundary_396_, uint8_t v_hasMissionHeader_397_, uint8_t v_authVerified_398_){
_start:
{
uint32_t v___y_400_; uint32_t v___y_401_; uint32_t v___y_402_; uint32_t v___y_406_; uint32_t v___y_407_; uint8_t v___y_408_; uint32_t v___y_412_; uint32_t v___y_413_; uint8_t v___y_418_; uint32_t v___y_419_; uint8_t v___y_423_; uint8_t v___y_424_; uint8_t v___x_427_; uint8_t v___x_428_; uint64_t v___y_430_; 
v___x_427_ = lean_uint64_dec_lt(v_baseIdleMs_394_, v_providerFloorMs_395_);
v___x_428_ = lean_uint64_dec_le(v_keepaliveMs_392_, v_clientElapsedMs_391_);
if (v___x_427_ == 0)
{
v___y_430_ = v_baseIdleMs_394_;
goto v___jp_429_;
}
else
{
v___y_430_ = v_providerFloorMs_395_;
goto v___jp_429_;
}
v___jp_399_:
{
uint32_t v___x_403_; uint32_t v___x_404_; 
v___x_403_ = lean_uint32_lor(v___y_401_, v___y_400_);
v___x_404_ = lean_uint32_lor(v___x_403_, v___y_402_);
return v___x_404_;
}
v___jp_405_:
{
if (v___y_408_ == 0)
{
uint32_t v___x_409_; 
v___x_409_ = 0;
v___y_400_ = v___y_406_;
v___y_401_ = v___y_407_;
v___y_402_ = v___x_409_;
goto v___jp_399_;
}
else
{
uint32_t v___x_410_; 
v___x_410_ = 65536;
v___y_400_ = v___y_406_;
v___y_401_ = v___y_407_;
v___y_402_ = v___x_410_;
goto v___jp_399_;
}
}
v___jp_411_:
{
uint8_t v___x_414_; uint8_t v___x_415_; 
v___x_414_ = 1;
v___x_415_ = lean_uint8_dec_eq(v_hasMissionHeader_397_, v___x_414_);
if (v___x_415_ == 0)
{
v___y_406_ = v___y_413_;
v___y_407_ = v___y_412_;
v___y_408_ = v___x_415_;
goto v___jp_405_;
}
else
{
uint8_t v___x_416_; 
v___x_416_ = lean_uint8_dec_eq(v_authVerified_398_, v___x_414_);
v___y_406_ = v___y_413_;
v___y_407_ = v___y_412_;
v___y_408_ = v___x_416_;
goto v___jp_405_;
}
}
v___jp_417_:
{
if (v___y_418_ == 0)
{
uint32_t v___x_420_; 
v___x_420_ = 0;
v___y_412_ = v___y_419_;
v___y_413_ = v___x_420_;
goto v___jp_411_;
}
else
{
uint32_t v___x_421_; 
v___x_421_ = 256;
v___y_412_ = v___y_419_;
v___y_413_ = v___x_421_;
goto v___jp_411_;
}
}
v___jp_422_:
{
if (v___y_424_ == 0)
{
uint32_t v___x_425_; 
v___x_425_ = 0;
v___y_418_ = v___y_423_;
v___y_419_ = v___x_425_;
goto v___jp_417_;
}
else
{
uint32_t v___x_426_; 
v___x_426_ = 1;
v___y_418_ = v___y_423_;
v___y_419_ = v___x_426_;
goto v___jp_417_;
}
}
v___jp_429_:
{
uint8_t v___x_431_; 
v___x_431_ = lean_uint64_dec_le(v___y_430_, v_upstreamElapsedMs_393_);
if (v___x_428_ == 0)
{
v___y_423_ = v___x_431_;
v___y_424_ = v___x_428_;
goto v___jp_422_;
}
else
{
uint8_t v___x_432_; uint8_t v___x_433_; 
v___x_432_ = 1;
v___x_433_ = lean_uint8_dec_eq(v_atEventBoundary_396_, v___x_432_);
v___y_423_ = v___x_431_;
v___y_424_ = v___x_433_;
goto v___jp_422_;
}
}
}
}

LEAN_EXPORT uint32_t orb_breaker_step(uint8_t v_reason_452_, uint32_t v_transientStreak_453_, uint32_t v_transientThreshold_454_){
_start:
{
uint32_t v___y_456_; uint8_t v___y_462_; uint8_t v___x_465_; uint8_t v___x_466_; 
v___x_465_ = 0;
v___x_466_ = lean_uint8_dec_eq(v_reason_452_, v___x_465_);
if (v___x_466_ == 0)
{
uint8_t v___x_467_; uint8_t v___x_468_; 
v___x_467_ = 4;
v___x_468_ = lean_uint8_dec_eq(v_reason_452_, v___x_467_);
if (v___x_468_ == 0)
{
uint8_t v___x_469_; uint8_t v___x_470_; 
v___x_469_ = 2;
v___x_470_ = lean_uint8_dec_eq(v_reason_452_, v___x_469_);
if (v___x_470_ == 0)
{
uint8_t v___x_474_; uint8_t v___x_475_; 
v___x_474_ = 3;
v___x_475_ = lean_uint8_dec_eq(v_reason_452_, v___x_474_);
if (v___x_475_ == 0)
{
uint8_t v___x_476_; uint8_t v___x_477_; 
v___x_476_ = 1;
v___x_477_ = lean_uint8_dec_eq(v_reason_452_, v___x_476_);
if (v___x_477_ == 0)
{
uint32_t v___x_478_; 
v___x_478_ = 65536;
return v___x_478_;
}
else
{
uint32_t v___x_479_; 
v___x_479_ = 65792;
return v___x_479_;
}
}
else
{
goto v___jp_471_;
}
}
else
{
goto v___jp_471_;
}
v___jp_471_:
{
if (v___x_470_ == 0)
{
uint32_t v___x_472_; 
v___x_472_ = 0;
v___y_456_ = v___x_472_;
goto v___jp_455_;
}
else
{
uint32_t v___x_473_; 
v___x_473_ = 256;
v___y_456_ = v___x_473_;
goto v___jp_455_;
}
}
}
else
{
uint8_t v___x_480_; 
v___x_480_ = lean_uint32_dec_le(v_transientThreshold_454_, v_transientStreak_453_);
if (v___x_480_ == 0)
{
v___y_462_ = v___x_480_;
goto v___jp_461_;
}
else
{
uint32_t v___x_481_; uint8_t v___x_482_; 
v___x_481_ = 1;
v___x_482_ = lean_uint32_dec_le(v___x_481_, v_transientThreshold_454_);
v___y_462_ = v___x_482_;
goto v___jp_461_;
}
}
}
else
{
uint32_t v___x_483_; 
v___x_483_ = 0;
return v___x_483_;
}
v___jp_455_:
{
uint32_t v___x_457_; uint32_t v___x_458_; uint32_t v___x_459_; uint32_t v___x_460_; 
v___x_457_ = 1;
v___x_458_ = lean_uint32_lor(v___x_457_, v___y_456_);
v___x_459_ = 65536;
v___x_460_ = lean_uint32_lor(v___x_458_, v___x_459_);
return v___x_460_;
}
v___jp_461_:
{
if (v___y_462_ == 0)
{
uint32_t v___x_463_; 
v___x_463_ = 0;
return v___x_463_;
}
else
{
uint32_t v___x_464_; 
v___x_464_ = 65536;
return v___x_464_;
}
}
}
}

LEAN_EXPORT uint8_t orb_mission_step(uint8_t v_armed_492_, uint8_t v_signal_493_, uint8_t v_continuationPending_494_, uint8_t v_wakeupArmed_495_, uint8_t v_madeProgress_496_, uint32_t v_priorNoProgress_497_, uint32_t v_maxNoProgress_498_, uint32_t v_priorContinuations_499_, uint32_t v_maxContinuations_500_, uint32_t v_hasMaxCont_501_){
_start:
{
uint8_t v___y_503_; uint8_t v___x_506_; uint8_t v___x_507_; 
v___x_506_ = 0;
v___x_507_ = lean_uint8_dec_eq(v_armed_492_, v___x_506_);
if (v___x_507_ == 0)
{
uint8_t v___x_508_; uint8_t v___x_509_; 
v___x_508_ = 1;
v___x_509_ = lean_uint8_dec_eq(v_signal_493_, v___x_508_);
if (v___x_509_ == 0)
{
uint8_t v___x_510_; uint8_t v___x_511_; 
v___x_510_ = 2;
v___x_511_ = lean_uint8_dec_eq(v_signal_493_, v___x_510_);
if (v___x_511_ == 0)
{
uint8_t v___x_512_; 
v___x_512_ = lean_uint8_dec_eq(v_continuationPending_494_, v___x_508_);
if (v___x_512_ == 0)
{
uint8_t v___x_513_; 
v___x_513_ = lean_uint8_dec_eq(v_wakeupArmed_495_, v___x_508_);
if (v___x_513_ == 0)
{
uint32_t v___x_514_; uint32_t v___y_516_; uint32_t v___y_517_; uint32_t v___y_524_; uint8_t v___x_528_; 
v___x_514_ = 1;
v___x_528_ = lean_uint32_dec_le(v___x_514_, v_maxNoProgress_498_);
if (v___x_528_ == 0)
{
v___y_524_ = v___x_514_;
goto v___jp_523_;
}
else
{
v___y_524_ = v_maxNoProgress_498_;
goto v___jp_523_;
}
v___jp_515_:
{
uint8_t v___x_518_; 
v___x_518_ = lean_uint32_dec_le(v___y_516_, v___y_517_);
if (v___x_518_ == 0)
{
uint8_t v___x_519_; 
v___x_519_ = lean_uint32_dec_eq(v_hasMaxCont_501_, v___x_514_);
if (v___x_519_ == 0)
{
v___y_503_ = v___x_519_;
goto v___jp_502_;
}
else
{
uint32_t v___x_520_; uint8_t v___x_521_; 
v___x_520_ = lean_uint32_add(v_priorContinuations_499_, v___x_514_);
v___x_521_ = lean_uint32_dec_lt(v_maxContinuations_500_, v___x_520_);
v___y_503_ = v___x_521_;
goto v___jp_502_;
}
}
else
{
uint8_t v___x_522_; 
v___x_522_ = 5;
return v___x_522_;
}
}
v___jp_523_:
{
uint8_t v___x_525_; 
v___x_525_ = lean_uint8_dec_eq(v_madeProgress_496_, v___x_508_);
if (v___x_525_ == 0)
{
uint32_t v___x_526_; 
v___x_526_ = lean_uint32_add(v_priorNoProgress_497_, v___x_514_);
v___y_516_ = v___y_524_;
v___y_517_ = v___x_526_;
goto v___jp_515_;
}
else
{
uint32_t v___x_527_; 
v___x_527_ = 0;
v___y_516_ = v___y_524_;
v___y_517_ = v___x_527_;
goto v___jp_515_;
}
}
}
else
{
uint8_t v___x_529_; 
v___x_529_ = 4;
return v___x_529_;
}
}
else
{
uint8_t v___x_530_; 
v___x_530_ = 3;
return v___x_530_;
}
}
else
{
return v___x_510_;
}
}
else
{
return v___x_508_;
}
}
else
{
return v___x_506_;
}
v___jp_502_:
{
if (v___y_503_ == 0)
{
uint8_t v___x_504_; 
v___x_504_ = 7;
return v___x_504_;
}
else
{
uint8_t v___x_505_; 
v___x_505_ = 6;
return v___x_505_;
}
}
}
}

LEAN_EXPORT uint8_t orb_reconcile_step(uint8_t v_status_553_, uint8_t v_isClientPlaced_554_, uint8_t v_sameBootId_555_, uint8_t v_isAssistantMode_556_, uint8_t v_runningInActor_557_, uint8_t v_hasLiveScope_558_, uint8_t v_hasDurableRun_559_, uint8_t v_recentlyUpdated_560_, uint8_t v_hasEvents_561_, uint8_t v_alreadyOrphaned_562_, uint8_t v_isServiceRestart_563_, uint8_t v_withinHorizon_564_, uint8_t v_liveRetryExists_565_){
_start:
{
uint8_t v___y_567_; uint8_t v___y_568_; uint8_t v___y_571_; uint8_t v___y_572_; uint8_t v___x_575_; uint8_t v___y_577_; uint8_t v___x_596_; 
v___x_575_ = 1;
v___x_596_ = lean_uint8_dec_eq(v_isClientPlaced_554_, v___x_575_);
if (v___x_596_ == 0)
{
uint8_t v___x_597_; 
v___x_597_ = lean_uint8_dec_eq(v_sameBootId_555_, v___x_575_);
v___y_577_ = v___x_597_;
goto v___jp_576_;
}
else
{
v___y_577_ = v___x_596_;
goto v___jp_576_;
}
v___jp_566_:
{
if (v___y_568_ == 0)
{
return v___y_567_;
}
else
{
uint8_t v___x_569_; 
v___x_569_ = 2;
return v___x_569_;
}
}
v___jp_570_:
{
if (v___y_572_ == 0)
{
return v___y_571_;
}
else
{
uint8_t v___x_573_; 
v___x_573_ = lean_uint8_dec_eq(v_liveRetryExists_565_, v___y_571_);
if (v___x_573_ == 0)
{
return v___y_571_;
}
else
{
uint8_t v___x_574_; 
v___x_574_ = 3;
return v___x_574_;
}
}
}
v___jp_576_:
{
if (v___y_577_ == 0)
{
uint8_t v___x_578_; 
v___x_578_ = lean_uint8_dec_eq(v_runningInActor_557_, v___x_575_);
if (v___x_578_ == 0)
{
uint8_t v___x_579_; 
v___x_579_ = lean_uint8_dec_eq(v_hasLiveScope_558_, v___x_575_);
if (v___x_579_ == 0)
{
uint8_t v___x_580_; 
v___x_580_ = lean_uint8_dec_eq(v_hasDurableRun_559_, v___x_575_);
if (v___x_580_ == 0)
{
uint8_t v___x_581_; uint8_t v___x_582_; 
v___x_581_ = 0;
v___x_582_ = lean_uint8_dec_eq(v_status_553_, v___x_581_);
if (v___x_582_ == 0)
{
uint8_t v___x_583_; 
v___x_583_ = lean_uint8_dec_eq(v_status_553_, v___x_575_);
if (v___x_583_ == 0)
{
uint8_t v___x_584_; uint8_t v___x_585_; 
v___x_584_ = 2;
v___x_585_ = lean_uint8_dec_eq(v_status_553_, v___x_584_);
if (v___x_585_ == 0)
{
return v___x_581_;
}
else
{
uint8_t v___x_586_; 
v___x_586_ = lean_uint8_dec_eq(v_isServiceRestart_563_, v___x_575_);
if (v___x_586_ == 0)
{
v___y_571_ = v___x_581_;
v___y_572_ = v___x_586_;
goto v___jp_570_;
}
else
{
uint8_t v___x_587_; 
v___x_587_ = lean_uint8_dec_eq(v_withinHorizon_564_, v___x_575_);
v___y_571_ = v___x_581_;
v___y_572_ = v___x_587_;
goto v___jp_570_;
}
}
}
else
{
uint8_t v___x_588_; 
v___x_588_ = lean_uint8_dec_eq(v_hasEvents_561_, v___x_581_);
if (v___x_588_ == 0)
{
v___y_567_ = v___x_581_;
v___y_568_ = v___x_588_;
goto v___jp_566_;
}
else
{
uint8_t v___x_589_; 
v___x_589_ = lean_uint8_dec_eq(v_alreadyOrphaned_562_, v___x_581_);
v___y_567_ = v___x_581_;
v___y_568_ = v___x_589_;
goto v___jp_566_;
}
}
}
else
{
uint8_t v___x_590_; 
v___x_590_ = lean_uint8_dec_eq(v_isAssistantMode_556_, v___x_581_);
if (v___x_590_ == 0)
{
if (v___x_590_ == 0)
{
return v___x_581_;
}
else
{
return v___x_575_;
}
}
else
{
uint8_t v___x_591_; 
v___x_591_ = lean_uint8_dec_eq(v_recentlyUpdated_560_, v___x_581_);
if (v___x_591_ == 0)
{
return v___x_581_;
}
else
{
return v___x_575_;
}
}
}
}
else
{
uint8_t v___x_592_; 
v___x_592_ = 0;
return v___x_592_;
}
}
else
{
uint8_t v___x_593_; 
v___x_593_ = 0;
return v___x_593_;
}
}
else
{
uint8_t v___x_594_; 
v___x_594_ = 0;
return v___x_594_;
}
}
else
{
uint8_t v___x_595_; 
v___x_595_ = 0;
return v___x_595_;
}
}
}
}

LEAN_EXPORT uint32_t orb_queue_step(uint8_t v_deliveryOutcome_626_, uint8_t v_durablyStarted_627_){
_start:
{
uint8_t v___y_629_; uint8_t v___x_635_; uint8_t v___x_636_; 
v___x_635_ = 0;
v___x_636_ = lean_uint8_dec_eq(v_deliveryOutcome_626_, v___x_635_);
if (v___x_636_ == 0)
{
v___y_629_ = v___x_636_;
goto v___jp_628_;
}
else
{
uint8_t v___x_637_; uint8_t v___x_638_; 
v___x_637_ = 1;
v___x_638_ = lean_uint8_dec_eq(v_durablyStarted_627_, v___x_637_);
v___y_629_ = v___x_638_;
goto v___jp_628_;
}
v___jp_628_:
{
if (v___y_629_ == 0)
{
uint8_t v___x_630_; uint8_t v___x_631_; 
v___x_630_ = 2;
v___x_631_ = lean_uint8_dec_eq(v_deliveryOutcome_626_, v___x_630_);
if (v___x_631_ == 0)
{
uint32_t v___x_632_; 
v___x_632_ = 1;
return v___x_632_;
}
else
{
uint32_t v___x_633_; 
v___x_633_ = 65537;
return v___x_633_;
}
}
else
{
uint32_t v___x_634_; 
v___x_634_ = 256;
return v___x_634_;
}
}
}
}

LEAN_EXPORT uint8_t orb_vm_step(uint8_t v_op_645_, uint8_t v_sizeRank_646_, uint8_t v_maxSizeRank_647_, uint8_t v_secretProjected_648_, uint8_t v_ttlExpired_649_, uint8_t v_busy_650_, uint8_t v_ownerEnded_651_, uint8_t v_idleExpired_652_, uint32_t v_activeCount_653_, uint32_t v_maxConcurrent_654_, uint32_t v_ttlMinutes_655_, uint32_t v_maxTtlMinutes_656_, uint32_t v_jobMemPct_657_, uint64_t v_spentPlusNewCents_658_, uint64_t v_dailyCapCents_659_){
_start:
{
uint8_t v___x_660_; uint8_t v___y_662_; uint8_t v___x_671_; 
v___x_660_ = 0;
v___x_671_ = lean_uint8_dec_eq(v_op_645_, v___x_660_);
if (v___x_671_ == 0)
{
uint8_t v___x_672_; uint8_t v___x_673_; 
v___x_672_ = 1;
v___x_673_ = lean_uint8_dec_eq(v_ttlExpired_649_, v___x_672_);
if (v___x_673_ == 0)
{
uint8_t v___x_674_; 
v___x_674_ = lean_uint8_dec_eq(v_busy_650_, v___x_660_);
if (v___x_674_ == 0)
{
if (v___x_674_ == 0)
{
return v___x_660_;
}
else
{
return v___x_672_;
}
}
else
{
uint8_t v___x_675_; 
v___x_675_ = lean_uint8_dec_eq(v_ownerEnded_651_, v___x_672_);
if (v___x_675_ == 0)
{
uint8_t v___x_676_; 
v___x_676_ = lean_uint8_dec_eq(v_idleExpired_652_, v___x_672_);
if (v___x_676_ == 0)
{
return v___x_660_;
}
else
{
return v___x_672_;
}
}
else
{
return v___x_672_;
}
}
}
else
{
return v___x_672_;
}
}
else
{
uint8_t v___x_677_; 
v___x_677_ = lean_uint8_dec_le(v_sizeRank_646_, v_maxSizeRank_647_);
if (v___x_677_ == 0)
{
v___y_662_ = v___x_677_;
goto v___jp_661_;
}
else
{
uint8_t v___x_678_; 
v___x_678_ = lean_uint32_dec_lt(v_activeCount_653_, v_maxConcurrent_654_);
v___y_662_ = v___x_678_;
goto v___jp_661_;
}
}
v___jp_661_:
{
if (v___y_662_ == 0)
{
return v___x_660_;
}
else
{
uint8_t v___x_663_; 
v___x_663_ = lean_uint64_dec_le(v_spentPlusNewCents_658_, v_dailyCapCents_659_);
if (v___x_663_ == 0)
{
return v___x_660_;
}
else
{
uint32_t v___x_664_; uint8_t v___x_665_; 
v___x_664_ = 5;
v___x_665_ = lean_uint32_dec_le(v___x_664_, v_ttlMinutes_655_);
if (v___x_665_ == 0)
{
return v___x_660_;
}
else
{
uint8_t v___x_666_; 
v___x_666_ = lean_uint32_dec_le(v_ttlMinutes_655_, v_maxTtlMinutes_656_);
if (v___x_666_ == 0)
{
return v___x_660_;
}
else
{
uint32_t v___x_667_; uint8_t v___x_668_; 
v___x_667_ = 90;
v___x_668_ = lean_uint32_dec_le(v_jobMemPct_657_, v___x_667_);
if (v___x_668_ == 0)
{
return v___x_660_;
}
else
{
uint8_t v___x_669_; 
v___x_669_ = lean_uint8_dec_eq(v_secretProjected_648_, v___x_660_);
if (v___x_669_ == 0)
{
return v___x_660_;
}
else
{
uint8_t v___x_670_; 
v___x_670_ = 1;
return v___x_670_;
}
}
}
}
}
}
}
}
}

LEAN_EXPORT uint32_t lp_orb_x2dspec_Orb_Kernel_accessStep___redArg(uint8_t v_sameOwner_711_, uint8_t v_isSelfOrChild_712_, uint8_t v_isReadTool_713_, uint8_t v_grantApproved_714_, uint8_t v_grantUnexpired_715_){
_start:
{
uint32_t v___y_717_; uint8_t v___x_720_; uint8_t v___y_722_; uint8_t v___x_729_; uint8_t v___y_731_; 
v___x_720_ = 1;
v___x_729_ = lean_uint8_dec_eq(v_sameOwner_711_, v___x_720_);
if (v___x_729_ == 0)
{
v___y_731_ = v___x_729_;
goto v___jp_730_;
}
else
{
uint8_t v___x_734_; 
v___x_734_ = lean_uint8_dec_eq(v_isSelfOrChild_712_, v___x_720_);
v___y_731_ = v___x_734_;
goto v___jp_730_;
}
v___jp_716_:
{
uint32_t v___x_718_; uint32_t v___x_719_; 
v___x_718_ = 256;
v___x_719_ = lean_uint32_lor(v___y_717_, v___x_718_);
return v___x_719_;
}
v___jp_721_:
{
if (v___y_722_ == 0)
{
uint32_t v___x_723_; 
v___x_723_ = 0;
return v___x_723_;
}
else
{
uint8_t v___x_724_; 
v___x_724_ = lean_uint8_dec_eq(v_grantUnexpired_715_, v___x_720_);
if (v___x_724_ == 0)
{
uint32_t v___x_725_; 
v___x_725_ = 0;
return v___x_725_;
}
else
{
uint8_t v___x_726_; 
v___x_726_ = lean_uint8_dec_eq(v_isReadTool_713_, v___x_720_);
if (v___x_726_ == 0)
{
uint32_t v___x_727_; 
v___x_727_ = 0;
v___y_717_ = v___x_727_;
goto v___jp_716_;
}
else
{
uint32_t v___x_728_; 
v___x_728_ = 1;
v___y_717_ = v___x_728_;
goto v___jp_716_;
}
}
}
}
v___jp_730_:
{
if (v___y_731_ == 0)
{
if (v___x_729_ == 0)
{
v___y_722_ = v___x_729_;
goto v___jp_721_;
}
else
{
uint8_t v___x_732_; 
v___x_732_ = lean_uint8_dec_eq(v_grantApproved_714_, v___x_720_);
v___y_722_ = v___x_732_;
goto v___jp_721_;
}
}
else
{
uint32_t v___x_733_; 
v___x_733_ = 65793;
return v___x_733_;
}
}
}
}

LEAN_EXPORT uint32_t orb_access_step(uint8_t v_sameOwner_747_, uint8_t v_isSelfOrChild_748_, uint8_t v_isReadTool_749_, uint8_t v_grantApproved_750_, uint8_t v_grantUnexpired_751_, uint8_t v___targetExists_752_){
_start:
{
uint32_t v___y_754_; uint8_t v___x_757_; uint8_t v___y_759_; uint8_t v___x_766_; uint8_t v___y_768_; 
v___x_757_ = 1;
v___x_766_ = lean_uint8_dec_eq(v_sameOwner_747_, v___x_757_);
if (v___x_766_ == 0)
{
v___y_768_ = v___x_766_;
goto v___jp_767_;
}
else
{
uint8_t v___x_771_; 
v___x_771_ = lean_uint8_dec_eq(v_isSelfOrChild_748_, v___x_757_);
v___y_768_ = v___x_771_;
goto v___jp_767_;
}
v___jp_753_:
{
uint32_t v___x_755_; uint32_t v___x_756_; 
v___x_755_ = 256;
v___x_756_ = lean_uint32_lor(v___y_754_, v___x_755_);
return v___x_756_;
}
v___jp_758_:
{
if (v___y_759_ == 0)
{
uint32_t v___x_760_; 
v___x_760_ = 0;
return v___x_760_;
}
else
{
uint8_t v___x_761_; 
v___x_761_ = lean_uint8_dec_eq(v_grantUnexpired_751_, v___x_757_);
if (v___x_761_ == 0)
{
uint32_t v___x_762_; 
v___x_762_ = 0;
return v___x_762_;
}
else
{
uint8_t v___x_763_; 
v___x_763_ = lean_uint8_dec_eq(v_isReadTool_749_, v___x_757_);
if (v___x_763_ == 0)
{
uint32_t v___x_764_; 
v___x_764_ = 0;
v___y_754_ = v___x_764_;
goto v___jp_753_;
}
else
{
uint32_t v___x_765_; 
v___x_765_ = 1;
v___y_754_ = v___x_765_;
goto v___jp_753_;
}
}
}
}
v___jp_767_:
{
if (v___y_768_ == 0)
{
if (v___x_766_ == 0)
{
v___y_759_ = v___x_766_;
goto v___jp_758_;
}
else
{
uint8_t v___x_769_; 
v___x_769_ = lean_uint8_dec_eq(v_grantApproved_750_, v___x_757_);
v___y_759_ = v___x_769_;
goto v___jp_758_;
}
}
else
{
uint32_t v___x_770_; 
v___x_770_ = 65793;
return v___x_770_;
}
}
}
}

LEAN_EXPORT uint32_t orb_workfold_step(uint8_t v_itemKind_786_, uint8_t v_isCumulative_787_, uint8_t v_isNonEmpty_788_, uint8_t v_toolAhead_789_, uint8_t v_nextIsTool_790_, uint8_t v_foldHasTool_791_){
_start:
{
uint8_t v___x_792_; uint8_t v___x_793_; 
v___x_792_ = 3;
v___x_793_ = lean_uint8_dec_eq(v_itemKind_786_, v___x_792_);
if (v___x_793_ == 0)
{
uint8_t v___x_794_; uint8_t v___y_800_; uint8_t v___x_807_; 
v___x_794_ = 1;
v___x_807_ = lean_uint8_dec_eq(v_itemKind_786_, v___x_794_);
if (v___x_807_ == 0)
{
uint8_t v___x_808_; uint8_t v___x_809_; 
v___x_808_ = 2;
v___x_809_ = lean_uint8_dec_eq(v_itemKind_786_, v___x_808_);
if (v___x_809_ == 0)
{
uint32_t v___x_810_; 
v___x_810_ = 0;
return v___x_810_;
}
else
{
uint8_t v___x_811_; uint8_t v___x_812_; 
v___x_811_ = 0;
v___x_812_ = lean_uint8_dec_eq(v_isCumulative_787_, v___x_811_);
if (v___x_812_ == 0)
{
v___y_800_ = v___x_812_;
goto v___jp_799_;
}
else
{
uint8_t v___x_813_; 
v___x_813_ = lean_uint8_dec_eq(v_isNonEmpty_788_, v___x_794_);
v___y_800_ = v___x_813_;
goto v___jp_799_;
}
}
}
else
{
uint8_t v___x_814_; 
v___x_814_ = lean_uint8_dec_eq(v_foldHasTool_791_, v___x_794_);
if (v___x_814_ == 0)
{
uint32_t v___x_815_; 
v___x_815_ = 1;
return v___x_815_;
}
else
{
uint32_t v___x_816_; 
v___x_816_ = 257;
return v___x_816_;
}
}
v___jp_795_:
{
uint8_t v___x_796_; 
v___x_796_ = lean_uint8_dec_eq(v_foldHasTool_791_, v___x_794_);
if (v___x_796_ == 0)
{
uint32_t v___x_797_; 
v___x_797_ = 1;
return v___x_797_;
}
else
{
uint32_t v___x_798_; 
v___x_798_ = 257;
return v___x_798_;
}
}
v___jp_799_:
{
if (v___y_800_ == 0)
{
uint32_t v___x_801_; 
v___x_801_ = 0;
return v___x_801_;
}
else
{
uint8_t v___x_802_; 
v___x_802_ = lean_uint8_dec_eq(v_toolAhead_789_, v___x_794_);
if (v___x_802_ == 0)
{
uint32_t v___x_803_; 
v___x_803_ = 0;
return v___x_803_;
}
else
{
uint8_t v___x_804_; 
v___x_804_ = lean_uint8_dec_eq(v_foldHasTool_791_, v___x_794_);
if (v___x_804_ == 0)
{
uint8_t v___x_805_; 
v___x_805_ = lean_uint8_dec_eq(v_nextIsTool_790_, v___x_794_);
if (v___x_805_ == 0)
{
uint32_t v___x_806_; 
v___x_806_ = 0;
return v___x_806_;
}
else
{
goto v___jp_795_;
}
}
else
{
goto v___jp_795_;
}
}
}
}
}
else
{
uint32_t v___x_817_; 
v___x_817_ = 257;
return v___x_817_;
}
}
}

LEAN_EXPORT uint8_t orb_taskcard_step(uint8_t v_turnEnded_832_, uint8_t v_allClosed_833_, uint8_t v_turnOutcomeFinished_834_){
_start:
{
uint8_t v___x_835_; uint8_t v___x_836_; 
v___x_835_ = 0;
v___x_836_ = lean_uint8_dec_eq(v_turnEnded_832_, v___x_835_);
if (v___x_836_ == 0)
{
uint8_t v___x_837_; uint8_t v___x_838_; 
v___x_837_ = 1;
v___x_838_ = lean_uint8_dec_eq(v_allClosed_833_, v___x_837_);
if (v___x_838_ == 0)
{
uint8_t v___x_839_; 
v___x_839_ = lean_uint8_dec_eq(v_turnOutcomeFinished_834_, v___x_837_);
if (v___x_839_ == 0)
{
uint8_t v___x_840_; 
v___x_840_ = 3;
return v___x_840_;
}
else
{
uint8_t v___x_841_; 
v___x_841_ = 2;
return v___x_841_;
}
}
else
{
return v___x_837_;
}
}
else
{
return v___x_835_;
}
}
}

LEAN_EXPORT uint32_t orb_sidebar_visibility(uint8_t v_matchesFilter_850_, uint8_t v_hasVisibleDescendant_851_, uint8_t v_isAcknowledged_852_, uint8_t v_hasParent_853_, uint8_t v_isFork_854_, uint8_t v_parentReachesSelf_855_){
_start:
{
uint32_t v___y_857_; uint32_t v___y_858_; uint32_t v___y_859_; uint32_t v___y_863_; uint32_t v___y_864_; uint32_t v___y_867_; uint32_t v___y_868_; uint8_t v___y_869_; uint8_t v___x_873_; uint32_t v___y_875_; uint32_t v___y_876_; uint32_t v___y_881_; uint8_t v___y_882_; uint32_t v___y_886_; uint8_t v___y_891_; uint8_t v___x_894_; 
v___x_873_ = 1;
v___x_894_ = lean_uint8_dec_eq(v_matchesFilter_850_, v___x_873_);
if (v___x_894_ == 0)
{
uint8_t v___x_895_; 
v___x_895_ = lean_uint8_dec_eq(v_hasVisibleDescendant_851_, v___x_873_);
v___y_891_ = v___x_895_;
goto v___jp_890_;
}
else
{
v___y_891_ = v___x_894_;
goto v___jp_890_;
}
v___jp_856_:
{
uint32_t v___x_860_; uint32_t v___x_861_; 
v___x_860_ = lean_uint32_lor(v___y_857_, v___y_858_);
v___x_861_ = lean_uint32_lor(v___x_860_, v___y_859_);
return v___x_861_;
}
v___jp_862_:
{
uint32_t v___x_865_; 
v___x_865_ = 0;
v___y_857_ = v___y_863_;
v___y_858_ = v___y_864_;
v___y_859_ = v___x_865_;
goto v___jp_856_;
}
v___jp_866_:
{
if (v___y_869_ == 0)
{
v___y_863_ = v___y_867_;
v___y_864_ = v___y_868_;
goto v___jp_862_;
}
else
{
uint8_t v___x_870_; uint8_t v___x_871_; 
v___x_870_ = 0;
v___x_871_ = lean_uint8_dec_eq(v_parentReachesSelf_855_, v___x_870_);
if (v___x_871_ == 0)
{
v___y_863_ = v___y_867_;
v___y_864_ = v___y_868_;
goto v___jp_862_;
}
else
{
uint32_t v___x_872_; 
v___x_872_ = 65536;
v___y_857_ = v___y_867_;
v___y_858_ = v___y_868_;
v___y_859_ = v___x_872_;
goto v___jp_856_;
}
}
}
v___jp_874_:
{
uint8_t v___x_877_; 
v___x_877_ = lean_uint8_dec_eq(v_hasParent_853_, v___x_873_);
if (v___x_877_ == 0)
{
v___y_867_ = v___y_875_;
v___y_868_ = v___y_876_;
v___y_869_ = v___x_877_;
goto v___jp_866_;
}
else
{
uint8_t v___x_878_; uint8_t v___x_879_; 
v___x_878_ = 0;
v___x_879_ = lean_uint8_dec_eq(v_isFork_854_, v___x_878_);
v___y_867_ = v___y_875_;
v___y_868_ = v___y_876_;
v___y_869_ = v___x_879_;
goto v___jp_866_;
}
}
v___jp_880_:
{
if (v___y_882_ == 0)
{
uint32_t v___x_883_; 
v___x_883_ = 0;
v___y_875_ = v___y_881_;
v___y_876_ = v___x_883_;
goto v___jp_874_;
}
else
{
uint32_t v___x_884_; 
v___x_884_ = 256;
v___y_875_ = v___y_881_;
v___y_876_ = v___x_884_;
goto v___jp_874_;
}
}
v___jp_885_:
{
uint8_t v___x_887_; 
v___x_887_ = lean_uint8_dec_eq(v_isAcknowledged_852_, v___x_873_);
if (v___x_887_ == 0)
{
v___y_881_ = v___y_886_;
v___y_882_ = v___x_887_;
goto v___jp_880_;
}
else
{
uint32_t v___x_888_; uint8_t v___x_889_; 
v___x_888_ = 0;
v___x_889_ = lean_uint32_dec_eq(v___y_886_, v___x_888_);
v___y_881_ = v___y_886_;
v___y_882_ = v___x_889_;
goto v___jp_880_;
}
}
v___jp_890_:
{
if (v___y_891_ == 0)
{
uint32_t v___x_892_; 
v___x_892_ = 0;
v___y_886_ = v___x_892_;
goto v___jp_885_;
}
else
{
uint32_t v___x_893_; 
v___x_893_ = 1;
v___y_886_ = v___x_893_;
goto v___jp_885_;
}
}
}
}

LEAN_EXPORT uint32_t orb_admission_step(uint8_t v_recoveryPhase_910_, uint8_t v_isQuiescent_911_, uint8_t v_reservedTagForged_912_, uint64_t v_emergencyPlusCandBytes_913_, uint64_t v_freeDiskBytes_914_){
_start:
{
uint8_t v___y_916_; uint8_t v___x_921_; uint8_t v___x_922_; 
v___x_921_ = 1;
v___x_922_ = lean_uint8_dec_eq(v_recoveryPhase_910_, v___x_921_);
if (v___x_922_ == 0)
{
uint8_t v___x_923_; uint8_t v___x_924_; 
v___x_923_ = 2;
v___x_924_ = lean_uint8_dec_eq(v_recoveryPhase_910_, v___x_923_);
if (v___x_924_ == 0)
{
uint8_t v___x_925_; 
v___x_925_ = lean_uint8_dec_eq(v_isQuiescent_911_, v___x_921_);
if (v___x_925_ == 0)
{
v___y_916_ = v___x_925_;
goto v___jp_915_;
}
else
{
uint8_t v___x_926_; uint8_t v___x_927_; 
v___x_926_ = 0;
v___x_927_ = lean_uint8_dec_eq(v_reservedTagForged_912_, v___x_926_);
v___y_916_ = v___x_927_;
goto v___jp_915_;
}
}
else
{
uint32_t v___x_928_; 
v___x_928_ = 65536;
return v___x_928_;
}
}
else
{
uint32_t v___x_929_; 
v___x_929_ = 256;
return v___x_929_;
}
v___jp_915_:
{
if (v___y_916_ == 0)
{
uint32_t v___x_917_; 
v___x_917_ = 0;
return v___x_917_;
}
else
{
uint8_t v___x_918_; 
v___x_918_ = lean_uint64_dec_le(v_emergencyPlusCandBytes_913_, v_freeDiskBytes_914_);
if (v___x_918_ == 0)
{
uint32_t v___x_919_; 
v___x_919_ = 0;
return v___x_919_;
}
else
{
uint32_t v___x_920_; 
v___x_920_ = 1;
return v___x_920_;
}
}
}
}
}

LEAN_EXPORT uint64_t orb_account_cooldown_secs(uint64_t v_baseSecs_942_, uint64_t v_maxSecs_943_, uint32_t v_consecutive_944_){
_start:
{
uint64_t v___x_945_; uint64_t v___y_947_; uint64_t v___y_948_; uint32_t v___y_949_; uint64_t v___y_956_; uint64_t v___y_957_; uint32_t v___y_958_; uint64_t v___y_962_; uint64_t v___y_963_; uint64_t v___y_969_; uint8_t v___x_971_; 
v___x_945_ = 1ULL;
v___x_971_ = lean_uint64_dec_le(v___x_945_, v_baseSecs_942_);
if (v___x_971_ == 0)
{
uint64_t v___x_972_; 
v___x_972_ = 600ULL;
v___y_969_ = v___x_972_;
goto v___jp_968_;
}
else
{
v___y_969_ = v_baseSecs_942_;
goto v___jp_968_;
}
v___jp_946_:
{
uint64_t v_exp_950_; uint64_t v_factor_951_; uint64_t v___x_952_; uint8_t v___x_953_; 
v_exp_950_ = lean_uint32_to_uint64(v___y_949_);
v_factor_951_ = lean_uint64_shift_left(v___x_945_, v_exp_950_);
v___x_952_ = lean_uint64_div(v___y_948_, v_factor_951_);
v___x_953_ = lean_uint64_dec_lt(v___x_952_, v___y_947_);
if (v___x_953_ == 0)
{
uint64_t v___x_954_; 
v___x_954_ = lean_uint64_mul(v___y_947_, v_factor_951_);
return v___x_954_;
}
else
{
return v___y_948_;
}
}
v___jp_955_:
{
uint32_t v___x_959_; uint8_t v___x_960_; 
v___x_959_ = 20;
v___x_960_ = lean_uint32_dec_lt(v___x_959_, v___y_958_);
if (v___x_960_ == 0)
{
v___y_947_ = v___y_956_;
v___y_948_ = v___y_957_;
v___y_949_ = v___y_958_;
goto v___jp_946_;
}
else
{
v___y_947_ = v___y_956_;
v___y_948_ = v___y_957_;
v___y_949_ = v___x_959_;
goto v___jp_946_;
}
}
v___jp_961_:
{
uint32_t v___x_964_; uint8_t v___x_965_; 
v___x_964_ = 1;
v___x_965_ = lean_uint32_dec_lt(v___x_964_, v_consecutive_944_);
if (v___x_965_ == 0)
{
uint32_t v___x_966_; 
v___x_966_ = 0;
v___y_956_ = v___y_962_;
v___y_957_ = v___y_963_;
v___y_958_ = v___x_966_;
goto v___jp_955_;
}
else
{
uint32_t v___x_967_; 
v___x_967_ = lean_uint32_sub(v_consecutive_944_, v___x_964_);
v___y_956_ = v___y_962_;
v___y_957_ = v___y_963_;
v___y_958_ = v___x_967_;
goto v___jp_955_;
}
}
v___jp_968_:
{
uint8_t v___x_970_; 
v___x_970_ = lean_uint64_dec_lt(v___y_969_, v_maxSecs_943_);
if (v___x_970_ == 0)
{
v___y_962_ = v___y_969_;
v___y_963_ = v___y_969_;
goto v___jp_961_;
}
else
{
v___y_962_ = v___y_969_;
v___y_963_ = v_maxSecs_943_;
goto v___jp_961_;
}
}
}
}

LEAN_EXPORT uint64_t orb_cost_cents_step(uint64_t v_inputTokens_981_, uint64_t v_outputTokens_982_, uint64_t v_cacheCreateTokens_983_, uint64_t v_cacheReadTokens_984_, uint64_t v_inputNano_985_, uint64_t v_outputNano_986_, uint64_t v_cacheCreateNano_987_, uint64_t v_cacheReadNano_988_){
_start:
{
uint64_t v___y_990_; uint8_t v___x_1002_; 
v___x_1002_ = lean_uint64_dec_le(v_cacheCreateTokens_983_, v_inputTokens_981_);
if (v___x_1002_ == 0)
{
uint64_t v___x_1003_; 
v___x_1003_ = 0ULL;
v___y_990_ = v___x_1003_;
goto v___jp_989_;
}
else
{
uint64_t v___x_1004_; 
v___x_1004_ = lean_uint64_sub(v_inputTokens_981_, v_cacheCreateTokens_983_);
v___y_990_ = v___x_1004_;
goto v___jp_989_;
}
v___jp_989_:
{
uint64_t v___x_991_; uint64_t v___x_992_; uint64_t v___x_993_; uint64_t v___x_994_; uint64_t v___x_995_; uint64_t v___x_996_; uint64_t v_totalNano_997_; uint64_t v___x_998_; uint64_t v___x_999_; uint64_t v___x_1000_; uint64_t v___x_1001_; 
v___x_991_ = lean_uint64_mul(v___y_990_, v_inputNano_985_);
v___x_992_ = lean_uint64_mul(v_outputTokens_982_, v_outputNano_986_);
v___x_993_ = lean_uint64_add(v___x_991_, v___x_992_);
v___x_994_ = lean_uint64_mul(v_cacheCreateTokens_983_, v_cacheCreateNano_987_);
v___x_995_ = lean_uint64_add(v___x_993_, v___x_994_);
v___x_996_ = lean_uint64_mul(v_cacheReadTokens_984_, v_cacheReadNano_988_);
v_totalNano_997_ = lean_uint64_add(v___x_995_, v___x_996_);
v___x_998_ = 5000000ULL;
v___x_999_ = lean_uint64_add(v_totalNano_997_, v___x_998_);
v___x_1000_ = 10000000ULL;
v___x_1001_ = lean_uint64_div(v___x_999_, v___x_1000_);
return v___x_1001_;
}
}
}

LEAN_EXPORT uint8_t orb_stream_loop_step(uint8_t v_cancelledOrTimedOut_1023_, uint8_t v_hashCollision_1024_, uint32_t v_windowLen_1025_, uint32_t v_minLen_1026_, uint32_t v_repeats_1027_, uint32_t v_nonOverlappingCount_1028_, uint32_t v_distinctWords4Plus_1029_, uint64_t v_comparisons_1030_, uint64_t v_comparisonBudget_1031_){
_start:
{
uint8_t v___x_1032_; uint8_t v___x_1033_; uint8_t v___y_1035_; uint8_t v___y_1038_; uint8_t v___y_1049_; uint8_t v___x_1056_; 
v___x_1032_ = lean_uint64_dec_lt(v_comparisonBudget_1031_, v_comparisons_1030_);
v___x_1033_ = 1;
v___x_1056_ = lean_uint8_dec_eq(v_cancelledOrTimedOut_1023_, v___x_1033_);
if (v___x_1056_ == 0)
{
uint32_t v___x_1057_; uint8_t v___x_1058_; 
v___x_1057_ = 256;
v___x_1058_ = lean_uint32_dec_lt(v___x_1057_, v_minLen_1026_);
v___y_1049_ = v___x_1058_;
goto v___jp_1048_;
}
else
{
v___y_1049_ = v___x_1056_;
goto v___jp_1048_;
}
v___jp_1034_:
{
if (v___y_1035_ == 0)
{
uint8_t v___x_1036_; 
v___x_1036_ = 0;
return v___x_1036_;
}
else
{
return v___x_1033_;
}
}
v___jp_1037_:
{
if (v___y_1038_ == 0)
{
uint32_t v___x_1039_; uint8_t v___x_1040_; 
v___x_1039_ = lean_uint32_mul(v_minLen_1026_, v_repeats_1027_);
v___x_1040_ = lean_uint32_dec_lt(v_windowLen_1025_, v___x_1039_);
if (v___x_1040_ == 0)
{
uint8_t v___x_1041_; 
v___x_1041_ = lean_uint8_dec_eq(v_hashCollision_1024_, v___x_1033_);
if (v___x_1041_ == 0)
{
uint8_t v___x_1042_; 
v___x_1042_ = lean_uint32_dec_le(v_repeats_1027_, v_nonOverlappingCount_1028_);
if (v___x_1042_ == 0)
{
v___y_1035_ = v___x_1042_;
goto v___jp_1034_;
}
else
{
uint32_t v___x_1043_; uint8_t v___x_1044_; 
v___x_1043_ = 2;
v___x_1044_ = lean_uint32_dec_le(v___x_1043_, v_distinctWords4Plus_1029_);
v___y_1035_ = v___x_1044_;
goto v___jp_1034_;
}
}
else
{
uint8_t v___x_1045_; 
v___x_1045_ = 2;
return v___x_1045_;
}
}
else
{
uint8_t v___x_1046_; 
v___x_1046_ = 0;
return v___x_1046_;
}
}
else
{
uint8_t v___x_1047_; 
v___x_1047_ = 0;
return v___x_1047_;
}
}
v___jp_1048_:
{
if (v___y_1049_ == 0)
{
if (v___x_1032_ == 0)
{
uint32_t v___x_1050_; uint8_t v___x_1051_; 
v___x_1050_ = 0;
v___x_1051_ = lean_uint32_dec_eq(v_minLen_1026_, v___x_1050_);
if (v___x_1051_ == 0)
{
uint32_t v___x_1052_; uint8_t v___x_1053_; 
v___x_1052_ = 2;
v___x_1053_ = lean_uint32_dec_lt(v_repeats_1027_, v___x_1052_);
v___y_1038_ = v___x_1053_;
goto v___jp_1037_;
}
else
{
v___y_1038_ = v___x_1051_;
goto v___jp_1037_;
}
}
else
{
uint8_t v___x_1054_; 
v___x_1054_ = 2;
return v___x_1054_;
}
}
else
{
uint8_t v___x_1055_; 
v___x_1055_ = 2;
return v___x_1055_;
}
}
}
}

LEAN_EXPORT uint32_t orb_job_ledger_step(uint8_t v_isAcceptedRemoteBuild_1079_, uint8_t v_expectsContinuation_1080_, uint8_t v_newerTerminalExists_1081_, uint8_t v_newerAmbiguousTentative_1082_){
_start:
{
uint32_t v___y_1084_; uint32_t v___y_1088_; uint8_t v___y_1089_; uint8_t v___x_1094_; uint32_t v___y_1096_; uint8_t v___x_1099_; 
v___x_1094_ = 1;
v___x_1099_ = lean_uint8_dec_eq(v_newerTerminalExists_1081_, v___x_1094_);
if (v___x_1099_ == 0)
{
uint8_t v___x_1100_; 
v___x_1100_ = lean_uint8_dec_eq(v_newerAmbiguousTentative_1082_, v___x_1094_);
if (v___x_1100_ == 0)
{
uint32_t v___x_1101_; 
v___x_1101_ = 0;
v___y_1096_ = v___x_1101_;
goto v___jp_1095_;
}
else
{
uint32_t v___x_1102_; 
v___x_1102_ = 256;
v___y_1096_ = v___x_1102_;
goto v___jp_1095_;
}
}
else
{
uint32_t v___x_1103_; 
v___x_1103_ = 512;
v___y_1096_ = v___x_1103_;
goto v___jp_1095_;
}
v___jp_1083_:
{
uint32_t v___x_1085_; uint32_t v___x_1086_; 
v___x_1085_ = 0;
v___x_1086_ = lean_uint32_lor(v___x_1085_, v___y_1084_);
return v___x_1086_;
}
v___jp_1087_:
{
if (v___y_1089_ == 0)
{
v___y_1084_ = v___y_1088_;
goto v___jp_1083_;
}
else
{
uint32_t v___x_1090_; uint8_t v___x_1091_; 
v___x_1090_ = 0;
v___x_1091_ = lean_uint32_dec_eq(v___y_1088_, v___x_1090_);
if (v___x_1091_ == 0)
{
v___y_1084_ = v___y_1088_;
goto v___jp_1083_;
}
else
{
uint32_t v___x_1092_; uint32_t v___x_1093_; 
v___x_1092_ = 1;
v___x_1093_ = lean_uint32_lor(v___x_1092_, v___y_1088_);
return v___x_1093_;
}
}
}
v___jp_1095_:
{
uint8_t v___x_1097_; 
v___x_1097_ = lean_uint8_dec_eq(v_isAcceptedRemoteBuild_1079_, v___x_1094_);
if (v___x_1097_ == 0)
{
v___y_1088_ = v___y_1096_;
v___y_1089_ = v___x_1097_;
goto v___jp_1087_;
}
else
{
uint8_t v___x_1098_; 
v___x_1098_ = lean_uint8_dec_eq(v_expectsContinuation_1080_, v___x_1094_);
v___y_1088_ = v___y_1096_;
v___y_1089_ = v___x_1098_;
goto v___jp_1087_;
}
}
}
}

LEAN_EXPORT uint8_t orb_proc_liveness_step(uint8_t v_procMissing_1114_, uint8_t v_procReadError_1115_, uint8_t v_isZombieOrDeadState_1116_, uint8_t v_hasExpectedTicks_1117_, uint32_t v_fieldsAfterComm_1118_, uint64_t v_expectedStartTicks_1119_, uint64_t v_actualStartTicks_1120_){
_start:
{
uint8_t v___x_1121_; uint8_t v___y_1123_; uint8_t v___x_1125_; 
v___x_1121_ = 1;
v___x_1125_ = lean_uint8_dec_eq(v_procMissing_1114_, v___x_1121_);
if (v___x_1125_ == 0)
{
uint8_t v___x_1126_; 
v___x_1126_ = lean_uint8_dec_eq(v_procReadError_1115_, v___x_1121_);
if (v___x_1126_ == 0)
{
uint8_t v___x_1127_; 
v___x_1127_ = lean_uint8_dec_eq(v_isZombieOrDeadState_1116_, v___x_1121_);
if (v___x_1127_ == 0)
{
uint32_t v___x_1128_; uint8_t v___x_1129_; 
v___x_1128_ = 20;
v___x_1129_ = lean_uint32_dec_lt(v_fieldsAfterComm_1118_, v___x_1128_);
if (v___x_1129_ == 0)
{
uint8_t v___x_1130_; 
v___x_1130_ = lean_uint8_dec_eq(v_hasExpectedTicks_1117_, v___x_1121_);
if (v___x_1130_ == 0)
{
v___y_1123_ = v___x_1130_;
goto v___jp_1122_;
}
else
{
uint8_t v___x_1131_; 
v___x_1131_ = lean_uint64_dec_eq(v_actualStartTicks_1120_, v_expectedStartTicks_1119_);
if (v___x_1131_ == 0)
{
v___y_1123_ = v___x_1130_;
goto v___jp_1122_;
}
else
{
return v___x_1121_;
}
}
}
else
{
uint8_t v___x_1132_; 
v___x_1132_ = 0;
return v___x_1132_;
}
}
else
{
uint8_t v___x_1133_; 
v___x_1133_ = 0;
return v___x_1133_;
}
}
else
{
uint8_t v___x_1134_; 
v___x_1134_ = 2;
return v___x_1134_;
}
}
else
{
uint8_t v___x_1135_; 
v___x_1135_ = 0;
return v___x_1135_;
}
v___jp_1122_:
{
if (v___y_1123_ == 0)
{
return v___x_1121_;
}
else
{
uint8_t v___x_1124_; 
v___x_1124_ = 0;
return v___x_1124_;
}
}
}
}

LEAN_EXPORT uint8_t orb_pr_gate_step(uint8_t v_merged_1152_, uint8_t v_draft_1153_, uint8_t v_closed_1154_, uint8_t v_exactHead_1155_, uint8_t v_actionRequired_1156_, uint8_t v_blocked_1157_, uint8_t v_behind_1158_, uint8_t v_conflicting_1159_, uint8_t v_checksGreen_1160_, uint8_t v_workflowsGreen_1161_){
_start:
{
uint8_t v___y_1163_; uint8_t v___x_1166_; uint8_t v___x_1167_; 
v___x_1166_ = 1;
v___x_1167_ = lean_uint8_dec_eq(v_merged_1152_, v___x_1166_);
if (v___x_1167_ == 0)
{
uint8_t v___x_1168_; 
v___x_1168_ = lean_uint8_dec_eq(v_draft_1153_, v___x_1166_);
if (v___x_1168_ == 0)
{
uint8_t v___x_1169_; 
v___x_1169_ = lean_uint8_dec_eq(v_closed_1154_, v___x_1166_);
if (v___x_1169_ == 0)
{
uint8_t v___x_1170_; uint8_t v___x_1171_; 
v___x_1170_ = 0;
v___x_1171_ = lean_uint8_dec_eq(v_exactHead_1155_, v___x_1170_);
if (v___x_1171_ == 0)
{
uint8_t v___x_1172_; 
v___x_1172_ = lean_uint8_dec_eq(v_actionRequired_1156_, v___x_1166_);
if (v___x_1172_ == 0)
{
uint8_t v___x_1173_; 
v___x_1173_ = lean_uint8_dec_eq(v_blocked_1157_, v___x_1166_);
if (v___x_1173_ == 0)
{
uint8_t v___x_1174_; 
v___x_1174_ = lean_uint8_dec_eq(v_behind_1158_, v___x_1166_);
if (v___x_1174_ == 0)
{
uint8_t v___x_1175_; 
v___x_1175_ = lean_uint8_dec_eq(v_conflicting_1159_, v___x_1166_);
if (v___x_1175_ == 0)
{
uint8_t v___x_1176_; 
v___x_1176_ = lean_uint8_dec_eq(v_checksGreen_1160_, v___x_1166_);
if (v___x_1176_ == 0)
{
v___y_1163_ = v___x_1176_;
goto v___jp_1162_;
}
else
{
uint8_t v___x_1177_; 
v___x_1177_ = lean_uint8_dec_eq(v_workflowsGreen_1161_, v___x_1166_);
v___y_1163_ = v___x_1177_;
goto v___jp_1162_;
}
}
else
{
uint8_t v___x_1178_; 
v___x_1178_ = 7;
return v___x_1178_;
}
}
else
{
uint8_t v___x_1179_; 
v___x_1179_ = 6;
return v___x_1179_;
}
}
else
{
uint8_t v___x_1180_; 
v___x_1180_ = 5;
return v___x_1180_;
}
}
else
{
uint8_t v___x_1181_; 
v___x_1181_ = 4;
return v___x_1181_;
}
}
else
{
uint8_t v___x_1182_; 
v___x_1182_ = 3;
return v___x_1182_;
}
}
else
{
uint8_t v___x_1183_; 
v___x_1183_ = 2;
return v___x_1183_;
}
}
else
{
return v___x_1166_;
}
}
else
{
uint8_t v___x_1184_; 
v___x_1184_ = 0;
return v___x_1184_;
}
v___jp_1162_:
{
if (v___y_1163_ == 0)
{
uint8_t v___x_1164_; 
v___x_1164_ = 9;
return v___x_1164_;
}
else
{
uint8_t v___x_1165_; 
v___x_1165_ = 8;
return v___x_1165_;
}
}
}
}

LEAN_EXPORT uint32_t orb_turn_summary_step(uint8_t v_rawStatus_1207_, uint8_t v_turnEnded_1208_, uint8_t v_allClosed_1209_, uint8_t v_turnOutcomeFinished_1210_){
_start:
{
uint32_t v___y_1212_; uint32_t v___y_1213_; uint8_t v___y_1214_; uint8_t v___y_1215_; uint8_t v___x_1223_; uint32_t v___y_1225_; uint8_t v___y_1226_; uint32_t v___y_1227_; uint8_t v___y_1235_; uint32_t v___y_1236_; uint8_t v___y_1242_; uint8_t v___x_1246_; 
v___x_1223_ = 2;
v___x_1246_ = lean_uint8_dec_eq(v_rawStatus_1207_, v___x_1223_);
if (v___x_1246_ == 0)
{
uint8_t v___x_1247_; uint8_t v___x_1248_; 
v___x_1247_ = 3;
v___x_1248_ = lean_uint8_dec_eq(v_rawStatus_1207_, v___x_1247_);
if (v___x_1248_ == 0)
{
uint8_t v___x_1249_; uint8_t v___y_1251_; uint8_t v___x_1253_; 
v___x_1249_ = 1;
v___x_1253_ = lean_uint8_dec_eq(v_rawStatus_1207_, v___x_1249_);
if (v___x_1253_ == 0)
{
v___y_1251_ = v___x_1253_;
goto v___jp_1250_;
}
else
{
uint8_t v___x_1254_; uint8_t v___x_1255_; 
v___x_1254_ = 0;
v___x_1255_ = lean_uint8_dec_eq(v_turnEnded_1208_, v___x_1254_);
v___y_1251_ = v___x_1255_;
goto v___jp_1250_;
}
v___jp_1250_:
{
if (v___y_1251_ == 0)
{
uint8_t v___x_1252_; 
v___x_1252_ = 0;
v___y_1242_ = v___x_1252_;
goto v___jp_1241_;
}
else
{
v___y_1242_ = v___x_1249_;
goto v___jp_1241_;
}
}
}
else
{
v___y_1242_ = v___x_1247_;
goto v___jp_1241_;
}
}
else
{
v___y_1242_ = v___x_1223_;
goto v___jp_1241_;
}
v___jp_1211_:
{
uint32_t v___x_1216_; uint32_t v___x_1217_; uint32_t v_card_1218_; uint32_t v___x_1219_; uint32_t v___x_1220_; uint32_t v___x_1221_; uint32_t v___x_1222_; 
v___x_1216_ = lean_uint8_to_uint32(v___y_1215_);
v___x_1217_ = 24;
v_card_1218_ = lean_uint32_shift_left(v___x_1216_, v___x_1217_);
v___x_1219_ = lean_uint8_to_uint32(v___y_1214_);
v___x_1220_ = lean_uint32_lor(v___x_1219_, v___y_1212_);
v___x_1221_ = lean_uint32_lor(v___x_1220_, v___y_1213_);
v___x_1222_ = lean_uint32_lor(v___x_1221_, v_card_1218_);
return v___x_1222_;
}
v___jp_1224_:
{
uint8_t v___x_1228_; uint8_t v___x_1229_; 
v___x_1228_ = 0;
v___x_1229_ = lean_uint8_dec_eq(v_turnEnded_1208_, v___x_1228_);
if (v___x_1229_ == 0)
{
uint8_t v___x_1230_; uint8_t v___x_1231_; 
v___x_1230_ = 1;
v___x_1231_ = lean_uint8_dec_eq(v_allClosed_1209_, v___x_1230_);
if (v___x_1231_ == 0)
{
uint8_t v___x_1232_; 
v___x_1232_ = lean_uint8_dec_eq(v_turnOutcomeFinished_1210_, v___x_1230_);
if (v___x_1232_ == 0)
{
uint8_t v___x_1233_; 
v___x_1233_ = 3;
v___y_1212_ = v___y_1225_;
v___y_1213_ = v___y_1227_;
v___y_1214_ = v___y_1226_;
v___y_1215_ = v___x_1233_;
goto v___jp_1211_;
}
else
{
v___y_1212_ = v___y_1225_;
v___y_1213_ = v___y_1227_;
v___y_1214_ = v___y_1226_;
v___y_1215_ = v___x_1223_;
goto v___jp_1211_;
}
}
else
{
v___y_1212_ = v___y_1225_;
v___y_1213_ = v___y_1227_;
v___y_1214_ = v___y_1226_;
v___y_1215_ = v___x_1230_;
goto v___jp_1211_;
}
}
else
{
v___y_1212_ = v___y_1225_;
v___y_1213_ = v___y_1227_;
v___y_1214_ = v___y_1226_;
v___y_1215_ = v___x_1228_;
goto v___jp_1211_;
}
}
v___jp_1234_:
{
uint8_t v___x_1237_; uint8_t v___x_1238_; 
v___x_1237_ = 1;
v___x_1238_ = lean_uint8_dec_eq(v___y_1235_, v___x_1237_);
if (v___x_1238_ == 0)
{
uint32_t v___x_1239_; 
v___x_1239_ = 0;
v___y_1225_ = v___y_1236_;
v___y_1226_ = v___y_1235_;
v___y_1227_ = v___x_1239_;
goto v___jp_1224_;
}
else
{
uint32_t v___x_1240_; 
v___x_1240_ = 65536;
v___y_1225_ = v___y_1236_;
v___y_1226_ = v___y_1235_;
v___y_1227_ = v___x_1240_;
goto v___jp_1224_;
}
}
v___jp_1241_:
{
uint8_t v___x_1243_; 
v___x_1243_ = lean_uint8_dec_eq(v___y_1242_, v___x_1223_);
if (v___x_1243_ == 0)
{
uint32_t v___x_1244_; 
v___x_1244_ = 0;
v___y_1235_ = v___y_1242_;
v___y_1236_ = v___x_1244_;
goto v___jp_1234_;
}
else
{
uint32_t v___x_1245_; 
v___x_1245_ = 256;
v___y_1235_ = v___y_1242_;
v___y_1236_ = v___x_1245_;
goto v___jp_1234_;
}
}
}
}

LEAN_EXPORT uint64_t orb_usage_limit_status(uint8_t v_statusKind_1266_, uint8_t v_claimKind_1267_, uint8_t v_hasUtilization_1268_, uint8_t v_utilizationPct_1269_, uint8_t v_hasReset_1270_, uint64_t v_resetRemSecs_1271_){
_start:
{
uint64_t v___y_1273_; uint64_t v___y_1274_; uint64_t v___y_1275_; uint64_t v___y_1281_; uint64_t v___y_1282_; uint64_t v___y_1283_; uint8_t v___y_1284_; uint64_t v___y_1289_; uint64_t v___y_1290_; uint64_t v___y_1299_; uint64_t v___y_1300_; uint64_t v___y_1304_; uint64_t v___y_1305_; uint64_t v___y_1306_; uint8_t v___y_1307_; uint64_t v___y_1308_; uint8_t v___y_1314_; uint8_t v___x_1328_; uint8_t v___x_1329_; 
v___x_1328_ = 0;
v___x_1329_ = lean_uint8_dec_eq(v_statusKind_1266_, v___x_1328_);
if (v___x_1329_ == 0)
{
uint8_t v___x_1330_; uint8_t v___x_1331_; uint64_t v___y_1333_; uint64_t v___y_1334_; uint64_t v___y_1338_; uint64_t v___y_1341_; uint8_t v___y_1342_; uint64_t v___y_1348_; uint8_t v___y_1353_; 
v___x_1330_ = 1;
v___x_1331_ = lean_uint8_dec_eq(v_statusKind_1266_, v___x_1330_);
if (v___x_1331_ == 0)
{
uint8_t v___x_1358_; uint8_t v___x_1359_; 
v___x_1358_ = 2;
v___x_1359_ = lean_uint8_dec_eq(v_statusKind_1266_, v___x_1358_);
if (v___x_1359_ == 0)
{
uint64_t v___x_1360_; 
v___x_1360_ = 3ULL;
return v___x_1360_;
}
else
{
uint8_t v___x_1361_; 
v___x_1361_ = lean_uint8_dec_eq(v_hasReset_1270_, v___x_1330_);
if (v___x_1361_ == 0)
{
v___y_1314_ = v___x_1361_;
goto v___jp_1313_;
}
else
{
uint64_t v___x_1362_; uint8_t v___x_1363_; 
v___x_1362_ = 0ULL;
v___x_1363_ = lean_uint64_dec_lt(v___x_1362_, v_resetRemSecs_1271_);
v___y_1314_ = v___x_1363_;
goto v___jp_1313_;
}
}
}
else
{
uint8_t v___x_1364_; 
v___x_1364_ = lean_uint8_dec_le(v___x_1330_, v_claimKind_1267_);
if (v___x_1364_ == 0)
{
v___y_1353_ = v___x_1364_;
goto v___jp_1352_;
}
else
{
uint8_t v___x_1365_; uint8_t v___x_1366_; 
v___x_1365_ = 4;
v___x_1366_ = lean_uint8_dec_le(v_claimKind_1267_, v___x_1365_);
v___y_1353_ = v___x_1366_;
goto v___jp_1352_;
}
}
v___jp_1332_:
{
uint64_t v___x_1335_; uint8_t v___x_1336_; 
v___x_1335_ = 0ULL;
v___x_1336_ = lean_uint64_dec_eq(v___y_1334_, v___x_1335_);
if (v___x_1336_ == 0)
{
v___y_1281_ = v___x_1335_;
v___y_1282_ = v___y_1333_;
v___y_1283_ = v___y_1334_;
v___y_1284_ = v___x_1331_;
goto v___jp_1280_;
}
else
{
v___y_1281_ = v___x_1335_;
v___y_1282_ = v___y_1333_;
v___y_1283_ = v___y_1334_;
v___y_1284_ = v___x_1329_;
goto v___jp_1280_;
}
}
v___jp_1337_:
{
uint64_t v___x_1339_; 
v___x_1339_ = 0ULL;
v___y_1333_ = v___y_1338_;
v___y_1334_ = v___x_1339_;
goto v___jp_1332_;
}
v___jp_1340_:
{
if (v___y_1342_ == 0)
{
v___y_1338_ = v___y_1341_;
goto v___jp_1337_;
}
else
{
uint8_t v___x_1343_; 
v___x_1343_ = lean_uint8_dec_eq(v_hasUtilization_1268_, v___x_1330_);
if (v___x_1343_ == 0)
{
v___y_1338_ = v___y_1341_;
goto v___jp_1337_;
}
else
{
uint8_t v___x_1344_; uint8_t v___x_1345_; 
v___x_1344_ = 100;
v___x_1345_ = lean_uint8_dec_le(v_utilizationPct_1269_, v___x_1344_);
if (v___x_1345_ == 0)
{
v___y_1338_ = v___y_1341_;
goto v___jp_1337_;
}
else
{
uint64_t v___x_1346_; 
v___x_1346_ = 65536ULL;
v___y_1333_ = v___y_1341_;
v___y_1334_ = v___x_1346_;
goto v___jp_1332_;
}
}
}
}
v___jp_1347_:
{
uint8_t v___x_1349_; 
v___x_1349_ = lean_uint8_dec_eq(v_claimKind_1267_, v___x_1330_);
if (v___x_1349_ == 0)
{
uint8_t v___x_1350_; uint8_t v___x_1351_; 
v___x_1350_ = 2;
v___x_1351_ = lean_uint8_dec_eq(v_claimKind_1267_, v___x_1350_);
v___y_1341_ = v___y_1348_;
v___y_1342_ = v___x_1351_;
goto v___jp_1340_;
}
else
{
v___y_1341_ = v___y_1348_;
v___y_1342_ = v___x_1331_;
goto v___jp_1340_;
}
}
v___jp_1352_:
{
if (v___y_1353_ == 0)
{
uint64_t v___x_1354_; 
v___x_1354_ = 0ULL;
v___y_1348_ = v___x_1354_;
goto v___jp_1347_;
}
else
{
uint64_t v___x_1355_; uint64_t v___x_1356_; uint64_t v___x_1357_; 
v___x_1355_ = lean_uint8_to_uint64(v_claimKind_1267_);
v___x_1356_ = 8ULL;
v___x_1357_ = lean_uint64_shift_left(v___x_1355_, v___x_1356_);
v___y_1348_ = v___x_1357_;
goto v___jp_1347_;
}
}
}
else
{
uint64_t v___x_1367_; 
v___x_1367_ = 0ULL;
return v___x_1367_;
}
v___jp_1272_:
{
uint64_t v___x_1276_; uint64_t v___x_1277_; uint64_t v___x_1278_; uint64_t v___x_1279_; 
v___x_1276_ = 1ULL;
v___x_1277_ = lean_uint64_lor(v___x_1276_, v___y_1273_);
v___x_1278_ = lean_uint64_lor(v___x_1277_, v___y_1274_);
v___x_1279_ = lean_uint64_lor(v___x_1278_, v___y_1275_);
return v___x_1279_;
}
v___jp_1280_:
{
if (v___y_1284_ == 0)
{
v___y_1273_ = v___y_1282_;
v___y_1274_ = v___y_1283_;
v___y_1275_ = v___y_1281_;
goto v___jp_1272_;
}
else
{
uint64_t v___x_1285_; uint64_t v___x_1286_; uint64_t v___x_1287_; 
v___x_1285_ = lean_uint8_to_uint64(v_utilizationPct_1269_);
v___x_1286_ = 24ULL;
v___x_1287_ = lean_uint64_shift_left(v___x_1285_, v___x_1286_);
v___y_1273_ = v___y_1282_;
v___y_1274_ = v___y_1283_;
v___y_1275_ = v___x_1287_;
goto v___jp_1272_;
}
}
v___jp_1288_:
{
uint64_t v___x_1291_; uint64_t v___x_1292_; uint64_t v___x_1293_; uint64_t v___x_1294_; uint64_t v___x_1295_; uint64_t v___x_1296_; uint64_t v___x_1297_; 
v___x_1291_ = 2ULL;
v___x_1292_ = 32ULL;
v___x_1293_ = lean_uint64_shift_left(v___y_1289_, v___x_1292_);
v___x_1294_ = lean_uint64_lor(v___x_1291_, v___x_1293_);
v___x_1295_ = 40ULL;
v___x_1296_ = lean_uint64_shift_left(v___y_1290_, v___x_1295_);
v___x_1297_ = lean_uint64_lor(v___x_1294_, v___x_1296_);
return v___x_1297_;
}
v___jp_1298_:
{
uint64_t v___x_1301_; uint8_t v___x_1302_; 
v___x_1301_ = 16777215ULL;
v___x_1302_ = lean_uint64_dec_lt(v___x_1301_, v___y_1300_);
if (v___x_1302_ == 0)
{
v___y_1289_ = v___y_1299_;
v___y_1290_ = v___y_1300_;
goto v___jp_1288_;
}
else
{
v___y_1289_ = v___y_1299_;
v___y_1290_ = v___x_1301_;
goto v___jp_1288_;
}
}
v___jp_1303_:
{
if (v___y_1307_ == 0)
{
uint64_t v___x_1309_; uint8_t v___x_1310_; 
v___x_1309_ = 48ULL;
v___x_1310_ = lean_uint64_dec_lt(v___y_1306_, v___x_1309_);
if (v___x_1310_ == 0)
{
v___y_1299_ = v___y_1308_;
v___y_1300_ = v___y_1305_;
goto v___jp_1298_;
}
else
{
v___y_1299_ = v___y_1308_;
v___y_1300_ = v___y_1306_;
goto v___jp_1298_;
}
}
else
{
uint64_t v___x_1311_; uint8_t v___x_1312_; 
v___x_1311_ = 1ULL;
v___x_1312_ = lean_uint64_dec_le(v___x_1311_, v___y_1304_);
if (v___x_1312_ == 0)
{
v___y_1299_ = v___y_1308_;
v___y_1300_ = v___x_1311_;
goto v___jp_1298_;
}
else
{
v___y_1299_ = v___y_1308_;
v___y_1300_ = v___y_1304_;
goto v___jp_1298_;
}
}
}
v___jp_1313_:
{
if (v___y_1314_ == 0)
{
uint64_t v___x_1315_; 
v___x_1315_ = 2ULL;
return v___x_1315_;
}
else
{
uint64_t v___x_1316_; uint64_t v_mins_1317_; uint64_t v___x_1318_; uint64_t v_hrs_1319_; uint64_t v___x_1320_; uint64_t v_days_1321_; uint8_t v___x_1322_; 
v___x_1316_ = 60ULL;
v_mins_1317_ = lean_uint64_div(v_resetRemSecs_1271_, v___x_1316_);
v___x_1318_ = 3600ULL;
v_hrs_1319_ = lean_uint64_div(v_resetRemSecs_1271_, v___x_1318_);
v___x_1320_ = 86400ULL;
v_days_1321_ = lean_uint64_div(v_resetRemSecs_1271_, v___x_1320_);
v___x_1322_ = lean_uint64_dec_lt(v_mins_1317_, v___x_1316_);
if (v___x_1322_ == 0)
{
uint64_t v___x_1323_; uint8_t v___x_1324_; 
v___x_1323_ = 48ULL;
v___x_1324_ = lean_uint64_dec_lt(v_hrs_1319_, v___x_1323_);
if (v___x_1324_ == 0)
{
uint64_t v___x_1325_; 
v___x_1325_ = 3ULL;
v___y_1304_ = v_mins_1317_;
v___y_1305_ = v_days_1321_;
v___y_1306_ = v_hrs_1319_;
v___y_1307_ = v___x_1322_;
v___y_1308_ = v___x_1325_;
goto v___jp_1303_;
}
else
{
uint64_t v___x_1326_; 
v___x_1326_ = 2ULL;
v___y_1304_ = v_mins_1317_;
v___y_1305_ = v_days_1321_;
v___y_1306_ = v_hrs_1319_;
v___y_1307_ = v___x_1322_;
v___y_1308_ = v___x_1326_;
goto v___jp_1303_;
}
}
else
{
uint64_t v___x_1327_; 
v___x_1327_ = 1ULL;
v___y_1304_ = v_mins_1317_;
v___y_1305_ = v_days_1321_;
v___y_1306_ = v_hrs_1319_;
v___y_1307_ = v___x_1322_;
v___y_1308_ = v___x_1327_;
goto v___jp_1303_;
}
}
}
}
}

LEAN_EXPORT uint64_t orb_relative_time_bucket(uint64_t v_elapsedSecs_1382_){
_start:
{
uint64_t v___y_1384_; uint64_t v___x_1389_; uint8_t v___x_1390_; 
v___x_1389_ = 45ULL;
v___x_1390_ = lean_uint64_dec_lt(v_elapsedSecs_1382_, v___x_1389_);
if (v___x_1390_ == 0)
{
uint64_t v___x_1391_; uint8_t v___x_1392_; 
v___x_1391_ = 3600ULL;
v___x_1392_ = lean_uint64_dec_lt(v_elapsedSecs_1382_, v___x_1391_);
if (v___x_1392_ == 0)
{
uint64_t v___x_1393_; uint8_t v___x_1394_; 
v___x_1393_ = 86400ULL;
v___x_1394_ = lean_uint64_dec_lt(v_elapsedSecs_1382_, v___x_1393_);
if (v___x_1394_ == 0)
{
uint64_t v___x_1395_; uint8_t v___x_1396_; 
v___x_1395_ = 604800ULL;
v___x_1396_ = lean_uint64_dec_lt(v_elapsedSecs_1382_, v___x_1395_);
if (v___x_1396_ == 0)
{
uint64_t v_wks_1397_; uint64_t v___x_1398_; uint8_t v___x_1399_; 
v_wks_1397_ = lean_uint64_div(v_elapsedSecs_1382_, v___x_1395_);
v___x_1398_ = 4294967295ULL;
v___x_1399_ = lean_uint64_dec_lt(v___x_1398_, v_wks_1397_);
if (v___x_1399_ == 0)
{
v___y_1384_ = v_wks_1397_;
goto v___jp_1383_;
}
else
{
v___y_1384_ = v___x_1398_;
goto v___jp_1383_;
}
}
else
{
uint64_t v___x_1400_; uint64_t v___x_1401_; uint64_t v___x_1402_; uint64_t v___x_1403_; uint64_t v___x_1404_; 
v___x_1400_ = 3ULL;
v___x_1401_ = lean_uint64_div(v_elapsedSecs_1382_, v___x_1393_);
v___x_1402_ = 8ULL;
v___x_1403_ = lean_uint64_shift_left(v___x_1401_, v___x_1402_);
v___x_1404_ = lean_uint64_lor(v___x_1400_, v___x_1403_);
return v___x_1404_;
}
}
else
{
uint64_t v___x_1405_; uint64_t v___x_1406_; uint64_t v___x_1407_; uint64_t v___x_1408_; uint64_t v___x_1409_; 
v___x_1405_ = 2ULL;
v___x_1406_ = lean_uint64_div(v_elapsedSecs_1382_, v___x_1391_);
v___x_1407_ = 8ULL;
v___x_1408_ = lean_uint64_shift_left(v___x_1406_, v___x_1407_);
v___x_1409_ = lean_uint64_lor(v___x_1405_, v___x_1408_);
return v___x_1409_;
}
}
else
{
uint64_t v___x_1410_; uint64_t v_mins_1411_; uint64_t v___x_1412_; uint64_t v___y_1414_; uint8_t v___x_1418_; 
v___x_1410_ = 60ULL;
v_mins_1411_ = lean_uint64_div(v_elapsedSecs_1382_, v___x_1410_);
v___x_1412_ = 1ULL;
v___x_1418_ = lean_uint64_dec_le(v___x_1412_, v_mins_1411_);
if (v___x_1418_ == 0)
{
v___y_1414_ = v___x_1412_;
goto v___jp_1413_;
}
else
{
v___y_1414_ = v_mins_1411_;
goto v___jp_1413_;
}
v___jp_1413_:
{
uint64_t v___x_1415_; uint64_t v___x_1416_; uint64_t v___x_1417_; 
v___x_1415_ = 8ULL;
v___x_1416_ = lean_uint64_shift_left(v___y_1414_, v___x_1415_);
v___x_1417_ = lean_uint64_lor(v___x_1412_, v___x_1416_);
return v___x_1417_;
}
}
}
else
{
uint64_t v___x_1419_; 
v___x_1419_ = 0ULL;
return v___x_1419_;
}
v___jp_1383_:
{
uint64_t v___x_1385_; uint64_t v___x_1386_; uint64_t v___x_1387_; uint64_t v___x_1388_; 
v___x_1385_ = 4ULL;
v___x_1386_ = 8ULL;
v___x_1387_ = lean_uint64_shift_left(v___y_1384_, v___x_1386_);
v___x_1388_ = lean_uint64_lor(v___x_1385_, v___x_1387_);
return v___x_1388_;
}
}
}

LEAN_EXPORT uint64_t orb_transcript_patch_step(uint32_t v_stateLen_1436_, uint32_t v_stateSeq_1437_, uint8_t v_eventKind_1438_, uint32_t v_deltaLen_1439_){
_start:
{
uint64_t v___y_1441_; uint32_t v___y_1442_; uint32_t v___y_1448_; uint8_t v___x_1455_; uint8_t v___x_1456_; 
v___x_1455_ = 2;
v___x_1456_ = lean_uint8_dec_le(v_eventKind_1438_, v___x_1455_);
if (v___x_1456_ == 0)
{
uint64_t v___x_1457_; uint64_t v___x_1458_; uint64_t v___x_1459_; uint64_t v___x_1460_; uint64_t v___x_1461_; 
v___x_1457_ = lean_uint32_to_uint64(v_stateLen_1436_);
v___x_1458_ = lean_uint32_to_uint64(v_stateSeq_1437_);
v___x_1459_ = 32ULL;
v___x_1460_ = lean_uint64_shift_left(v___x_1458_, v___x_1459_);
v___x_1461_ = lean_uint64_lor(v___x_1457_, v___x_1460_);
return v___x_1461_;
}
else
{
uint8_t v___x_1462_; 
v___x_1462_ = lean_uint8_dec_eq(v_eventKind_1438_, v___x_1455_);
if (v___x_1462_ == 0)
{
uint8_t v___x_1463_; uint8_t v___x_1464_; 
v___x_1463_ = 1;
v___x_1464_ = lean_uint8_dec_eq(v_eventKind_1438_, v___x_1463_);
if (v___x_1464_ == 0)
{
uint32_t v___x_1465_; uint32_t v___x_1466_; uint8_t v___x_1467_; 
v___x_1465_ = 4294967295;
v___x_1466_ = lean_uint32_sub(v___x_1465_, v_deltaLen_1439_);
v___x_1467_ = lean_uint32_dec_le(v_stateLen_1436_, v___x_1466_);
if (v___x_1467_ == 0)
{
v___y_1448_ = v___x_1465_;
goto v___jp_1447_;
}
else
{
uint32_t v___x_1468_; 
v___x_1468_ = lean_uint32_add(v_stateLen_1436_, v_deltaLen_1439_);
v___y_1448_ = v___x_1468_;
goto v___jp_1447_;
}
}
else
{
uint32_t v___x_1469_; uint8_t v___x_1470_; 
v___x_1469_ = 0;
v___x_1470_ = lean_uint32_dec_lt(v___x_1469_, v_deltaLen_1439_);
if (v___x_1470_ == 0)
{
v___y_1448_ = v_stateLen_1436_;
goto v___jp_1447_;
}
else
{
v___y_1448_ = v_deltaLen_1439_;
goto v___jp_1447_;
}
}
}
else
{
uint32_t v___x_1471_; 
v___x_1471_ = 0;
v___y_1448_ = v___x_1471_;
goto v___jp_1447_;
}
}
v___jp_1440_:
{
uint64_t v___x_1443_; uint64_t v___x_1444_; uint64_t v___x_1445_; uint64_t v___x_1446_; 
v___x_1443_ = lean_uint32_to_uint64(v___y_1442_);
v___x_1444_ = 32ULL;
v___x_1445_ = lean_uint64_shift_left(v___x_1443_, v___x_1444_);
v___x_1446_ = lean_uint64_lor(v___y_1441_, v___x_1445_);
return v___x_1446_;
}
v___jp_1447_:
{
uint64_t v___x_1449_; uint32_t v___x_1450_; uint8_t v___x_1451_; 
v___x_1449_ = lean_uint32_to_uint64(v___y_1448_);
v___x_1450_ = 4294967294;
v___x_1451_ = lean_uint32_dec_le(v_stateSeq_1437_, v___x_1450_);
if (v___x_1451_ == 0)
{
uint32_t v___x_1452_; 
v___x_1452_ = 4294967295;
v___y_1441_ = v___x_1449_;
v___y_1442_ = v___x_1452_;
goto v___jp_1440_;
}
else
{
uint32_t v___x_1453_; uint32_t v___x_1454_; 
v___x_1453_ = 1;
v___x_1454_ = lean_uint32_add(v_stateSeq_1437_, v___x_1453_);
v___y_1441_ = v___x_1449_;
v___y_1442_ = v___x_1454_;
goto v___jp_1440_;
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
