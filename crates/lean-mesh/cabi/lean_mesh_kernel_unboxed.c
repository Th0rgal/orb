#include "lean_mesh_kernel.h"
#define LEAN_EXPORT
#define lean_uint8_dec_eq(a, b) ((uint8_t)(((uint8_t)(a)) == ((uint8_t)(b))))
#define lean_uint8_dec_lt(a, b) ((uint8_t)(((uint8_t)(a)) < ((uint8_t)(b))))
#define lean_uint8_dec_le(a, b) ((uint8_t)(((uint8_t)(a)) <= ((uint8_t)(b))))
#define lean_uint8_to_uint32(a) ((uint32_t)(a))
#define lean_uint8_to_uint64(a) ((uint64_t)(a))
#define lean_uint32_dec_eq(a, b) ((uint8_t)(((uint32_t)(a)) == ((uint32_t)(b))))
#define lean_uint32_dec_lt(a, b) ((uint8_t)(((uint32_t)(a)) < ((uint32_t)(b))))
#define lean_uint32_dec_le(a, b) ((uint8_t)(((uint32_t)(a)) <= ((uint32_t)(b))))
#define lean_uint32_add(a, b) ((uint32_t)(((uint32_t)(a)) + ((uint32_t)(b))))
#define lean_uint32_sub(a, b) ((uint32_t)(((uint32_t)(a)) - ((uint32_t)(b))))
#define lean_uint32_mul(a, b) ((uint32_t)(((uint32_t)(a)) * ((uint32_t)(b))))
#define lean_uint32_lor(a, b) ((uint32_t)(((uint32_t)(a)) | ((uint32_t)(b))))
#define lean_uint32_land(a, b) ((uint32_t)(((uint32_t)(a)) & ((uint32_t)(b))))
#define lean_uint32_shift_left(a, b) ((uint32_t)(((uint32_t)(a)) << (((uint32_t)(b)) & 31u)))
#define lean_uint32_shift_right(a, b) ((uint32_t)(((uint32_t)(a)) >> (((uint32_t)(b)) & 31u)))
#define lean_uint32_to_uint64(a) ((uint64_t)(a))
#define lean_uint64_dec_eq(a, b) ((uint8_t)(((uint64_t)(a)) == ((uint64_t)(b))))
#define lean_uint64_dec_lt(a, b) ((uint8_t)(((uint64_t)(a)) < ((uint64_t)(b))))
#define lean_uint64_dec_le(a, b) ((uint8_t)(((uint64_t)(a)) <= ((uint64_t)(b))))
#define lean_uint64_add(a, b) ((uint64_t)(((uint64_t)(a)) + ((uint64_t)(b))))
#define lean_uint64_sub(a, b) ((uint64_t)(((uint64_t)(a)) - ((uint64_t)(b))))
#define lean_uint64_mul(a, b) ((uint64_t)(((uint64_t)(a)) * ((uint64_t)(b))))
#define lean_uint64_div(a, b) ((((uint64_t)(b)) == 0) ? (uint64_t)(0) : (uint64_t)(((uint64_t)(a)) / ((uint64_t)(b))))
#define lean_uint64_mod(a, b) ((((uint64_t)(b)) == 0) ? (uint64_t)(a) : (uint64_t)(((uint64_t)(a)) % ((uint64_t)(b))))
#define lean_uint64_lor(a, b) ((uint64_t)(((uint64_t)(a)) | ((uint64_t)(b))))
#define lean_uint64_land(a, b) ((uint64_t)(((uint64_t)(a)) & ((uint64_t)(b))))
#define lean_uint64_xor(a, b) ((uint64_t)(((uint64_t)(a)) ^ ((uint64_t)(b))))
#define lean_uint64_shift_left(a, b) ((uint64_t)(((uint64_t)(a)) << (((uint64_t)(b)) & 63u)))
#define lean_uint64_shift_right(a, b) ((uint64_t)(((uint64_t)(a)) >> (((uint64_t)(b)) & 63u)))

LEAN_EXPORT uint32_t leanmesh_ratchet_epoch_step(uint8_t v_sigValid_58_, uint8_t v_isEmergencyPanic_59_, uint64_t v_currentEpoch_60_, uint64_t v_candidateEpoch_61_, uint64_t v_currentPanicSeq_62_, uint64_t v_candidatePanicSeq_63_, uint64_t v_nowEpoch_64_, uint64_t v_issuedAt_65_, uint64_t v_expiresAt_66_, uint64_t v_maxTtlSecs_67_){
{
uint8_t v___x_68_; uint32_t v___y_70_; uint32_t v___y_71_; uint8_t v___x_101_; 
v___x_68_ = 1;
v___x_101_ = lean_uint8_dec_eq(v_sigValid_58_, v___x_68_);
if (v___x_101_ == 0)
{
uint32_t v___x_102_; 
v___x_102_ = 0;
return v___x_102_;
}
else
{
uint64_t v___x_103_; uint8_t v___x_104_; 
v___x_103_ = 0ULL;
v___x_104_ = lean_uint64_dec_lt(v___x_103_, v_maxTtlSecs_67_);
if (v___x_104_ == 0)
{
uint32_t v___x_105_; 
v___x_105_ = 0;
return v___x_105_;
}
else
{
uint64_t v___x_106_; uint8_t v___x_107_; 
v___x_106_ = 2592000ULL;
v___x_107_ = lean_uint64_dec_le(v_maxTtlSecs_67_, v___x_106_);
if (v___x_107_ == 0)
{
uint32_t v___x_108_; 
v___x_108_ = 0;
return v___x_108_;
}
else
{
uint8_t v___x_109_; 
v___x_109_ = lean_uint64_dec_lt(v_issuedAt_65_, v_expiresAt_66_);
if (v___x_109_ == 0)
{
uint32_t v___x_110_; 
v___x_110_ = 0;
return v___x_110_;
}
else
{
uint64_t v___x_111_; uint8_t v___x_112_; 
v___x_111_ = lean_uint64_sub(v_expiresAt_66_, v_issuedAt_65_);
v___x_112_ = lean_uint64_dec_le(v___x_111_, v_maxTtlSecs_67_);
if (v___x_112_ == 0)
{
uint32_t v___x_113_; 
v___x_113_ = 0;
return v___x_113_;
}
else
{
uint8_t v___x_114_; 
v___x_114_ = lean_uint64_dec_lt(v_nowEpoch_64_, v_expiresAt_66_);
if (v___x_114_ == 0)
{
uint32_t v___x_115_; 
v___x_115_ = 0;
return v___x_115_;
}
else
{
uint8_t v___x_116_; 
v___x_116_ = lean_uint64_dec_le(v_issuedAt_65_, v_nowEpoch_64_);
if (v___x_116_ == 0)
{
uint64_t v___x_117_; uint64_t v___x_118_; uint8_t v___x_119_; 
v___x_117_ = lean_uint64_sub(v_issuedAt_65_, v_nowEpoch_64_);
v___x_118_ = 60ULL;
v___x_119_ = lean_uint64_dec_le(v___x_117_, v___x_118_);
if (v___x_119_ == 0)
{
uint32_t v___x_120_; 
v___x_120_ = 0;
return v___x_120_;
}
else
{
goto v___jp_89_;
}
}
else
{
goto v___jp_89_;
}
}
}
}
}
}
}
v___jp_69_:
{
uint32_t v___x_72_; uint8_t v___x_73_; 
v___x_72_ = lean_uint32_lor(v___y_70_, v___y_71_);
v___x_73_ = lean_uint8_dec_eq(v_isEmergencyPanic_59_, v___x_68_);
if (v___x_73_ == 0)
{
return v___x_72_;
}
else
{
uint8_t v___x_74_; 
v___x_74_ = lean_uint64_dec_lt(v_currentPanicSeq_62_, v_candidatePanicSeq_63_);
if (v___x_74_ == 0)
{
return v___x_72_;
}
else
{
uint32_t v___x_75_; uint32_t v___x_76_; 
v___x_75_ = 65536;
v___x_76_ = lean_uint32_lor(v___x_72_, v___x_75_);
return v___x_76_;
}
}
}
v___jp_77_:
{
uint32_t v___x_78_; uint8_t v___x_79_; 
v___x_78_ = 1;
v___x_79_ = lean_uint64_dec_lt(v_currentEpoch_60_, v_candidateEpoch_61_);
if (v___x_79_ == 0)
{
uint32_t v___x_80_; 
v___x_80_ = 0;
v___y_70_ = v___x_78_;
v___y_71_ = v___x_80_;
goto v___jp_69_;
}
else
{
uint32_t v___x_81_; 
v___x_81_ = 256;
v___y_70_ = v___x_78_;
v___y_71_ = v___x_81_;
goto v___jp_69_;
}
}
v___jp_82_:
{
uint8_t v___x_83_; 
v___x_83_ = lean_uint8_dec_eq(v_isEmergencyPanic_59_, v___x_68_);
if (v___x_83_ == 0)
{
uint32_t v___x_84_; 
v___x_84_ = 0;
return v___x_84_;
}
else
{
uint8_t v___x_85_; 
v___x_85_ = lean_uint64_dec_le(v_currentEpoch_60_, v_candidateEpoch_61_);
if (v___x_85_ == 0)
{
uint32_t v___x_86_; 
v___x_86_ = 0;
return v___x_86_;
}
else
{
uint8_t v___x_87_; 
v___x_87_ = lean_uint64_dec_lt(v_currentPanicSeq_62_, v_candidatePanicSeq_63_);
if (v___x_87_ == 0)
{
uint32_t v___x_88_; 
v___x_88_ = 0;
return v___x_88_;
}
else
{
goto v___jp_77_;
}
}
}
}
v___jp_89_:
{
uint8_t v___x_90_; 
v___x_90_ = lean_uint8_dec_le(v_isEmergencyPanic_59_, v___x_68_);
if (v___x_90_ == 0)
{
uint32_t v___x_91_; 
v___x_91_ = 0;
return v___x_91_;
}
else
{
uint64_t v___x_92_; uint8_t v___x_93_; 
v___x_92_ = 18446744073709551615ULL;
v___x_93_ = lean_uint64_dec_lt(v_candidateEpoch_61_, v___x_92_);
if (v___x_93_ == 0)
{
uint32_t v___x_94_; 
v___x_94_ = 0;
return v___x_94_;
}
else
{
uint8_t v___x_95_; 
v___x_95_ = lean_uint64_dec_lt(v_candidatePanicSeq_63_, v___x_92_);
if (v___x_95_ == 0)
{
uint32_t v___x_96_; 
v___x_96_ = 0;
return v___x_96_;
}
else
{
uint8_t v___x_97_; uint8_t v___x_98_; 
v___x_97_ = 0;
v___x_98_ = lean_uint8_dec_eq(v_isEmergencyPanic_59_, v___x_97_);
if (v___x_98_ == 0)
{
goto v___jp_82_;
}
else
{
uint8_t v___x_99_; 
v___x_99_ = lean_uint64_dec_lt(v_currentEpoch_60_, v_candidateEpoch_61_);
if (v___x_99_ == 0)
{
goto v___jp_82_;
}
else
{
uint8_t v___x_100_; 
v___x_100_ = lean_uint64_dec_eq(v_candidatePanicSeq_63_, v_currentPanicSeq_62_);
if (v___x_100_ == 0)
{
goto v___jp_82_;
}
else
{
goto v___jp_77_;
}
}
}
}
}
}
}
}
}

LEAN_EXPORT uint32_t leanmesh_eval_route_step(uint32_t v_srcId_369_, uint32_t v_dstId_370_, uint8_t v_srcClass_371_, uint8_t v_dstClass_372_, uint8_t v_srcRevoked_373_, uint8_t v_dstRevoked_374_, uint8_t v_ruleMatched_375_, uint8_t v_proto_376_, uint32_t v_dstPort_377_, uint32_t v_rulePortMin_378_, uint32_t v_rulePortMax_379_, uint8_t v_jitBiometricGrant_380_, uint8_t v_bunkerState_381_, uint64_t v_nowEpoch_382_, uint64_t v_srcExpiresAt_383_, uint64_t v_dstExpiresAt_384_, uint64_t v_jitExpiresAt_385_){
{
uint8_t v___y_398_; uint8_t v___y_402_; uint8_t v___y_410_; uint8_t v___y_411_; uint8_t v___y_413_; uint8_t v___y_414_; uint8_t v___y_431_; uint8_t v___y_432_; uint8_t v___y_440_; uint8_t v___y_465_; uint8_t v___y_466_; uint8_t v___y_472_; uint8_t v___y_473_; uint8_t v___y_482_; uint8_t v___y_483_; uint8_t v___y_484_; uint8_t v___y_490_; uint32_t v___x_496_; uint8_t v___x_497_; 
v___x_496_ = 3088;
v___x_497_ = lean_uint32_dec_eq(v_dstPort_377_, v___x_496_);
if (v___x_497_ == 0)
{
uint8_t v___x_498_; 
v___x_498_ = lean_uint32_dec_le(v_rulePortMin_378_, v___x_496_);
if (v___x_498_ == 0)
{
v___y_490_ = v___x_498_;
goto v___jp_489_;
}
else
{
uint8_t v___x_499_; 
v___x_499_ = lean_uint32_dec_le(v___x_496_, v_rulePortMax_379_);
v___y_490_ = v___x_499_;
goto v___jp_489_;
}
}
else
{
v___y_490_ = v___x_497_;
goto v___jp_489_;
}
v___jp_386_:
{
uint8_t v___x_387_; uint8_t v___x_388_; 
v___x_387_ = 2;
v___x_388_ = lean_uint8_dec_eq(v_bunkerState_381_, v___x_387_);
if (v___x_388_ == 0)
{
uint32_t v___x_389_; 
v___x_389_ = 1;
return v___x_389_;
}
else
{
uint32_t v___x_390_; 
v___x_390_ = 257;
return v___x_390_;
}
}
v___jp_391_:
{
uint8_t v___x_392_; uint8_t v___x_393_; 
v___x_392_ = 3;
v___x_393_ = lean_uint8_dec_eq(v_dstClass_372_, v___x_392_);
if (v___x_393_ == 0)
{
goto v___jp_386_;
}
else
{
uint8_t v___x_394_; uint8_t v___x_395_; 
v___x_394_ = 1;
v___x_395_ = lean_uint8_dec_le(v_srcClass_371_, v___x_394_);
if (v___x_395_ == 0)
{
goto v___jp_386_;
}
else
{
uint32_t v___x_396_; 
v___x_396_ = 257;
return v___x_396_;
}
}
}
v___jp_397_:
{
if (v___y_398_ == 0)
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
v___jp_401_:
{
if (v___y_402_ == 0)
{
uint8_t v___x_403_; uint8_t v___x_404_; 
v___x_403_ = 5;
v___x_404_ = lean_uint8_dec_eq(v_dstClass_372_, v___x_403_);
if (v___x_404_ == 0)
{
goto v___jp_391_;
}
else
{
uint8_t v___x_405_; uint8_t v___x_406_; 
v___x_405_ = 2;
v___x_406_ = lean_uint8_dec_eq(v_srcClass_371_, v___x_405_);
if (v___x_406_ == 0)
{
goto v___jp_391_;
}
else
{
uint32_t v___x_407_; 
v___x_407_ = 257;
return v___x_407_;
}
}
}
else
{
uint32_t v___x_408_; 
v___x_408_ = 65536;
return v___x_408_;
}
}
v___jp_409_:
{
if (v___y_411_ == 0)
{
v___y_398_ = v___y_410_;
goto v___jp_397_;
}
else
{
v___y_402_ = v___y_410_;
goto v___jp_401_;
}
}
v___jp_412_:
{
if (v___y_414_ == 0)
{
v___y_398_ = v___y_413_;
goto v___jp_397_;
}
else
{
uint8_t v___x_415_; uint8_t v___x_416_; 
v___x_415_ = 0;
v___x_416_ = lean_uint8_dec_eq(v_bunkerState_381_, v___x_415_);
if (v___x_416_ == 0)
{
uint8_t v___x_417_; uint8_t v___x_418_; 
v___x_417_ = 1;
v___x_418_ = lean_uint8_dec_eq(v_bunkerState_381_, v___x_417_);
if (v___x_418_ == 0)
{
uint8_t v___x_419_; uint8_t v___x_420_; 
v___x_419_ = 2;
v___x_420_ = lean_uint8_dec_eq(v_bunkerState_381_, v___x_419_);
if (v___x_420_ == 0)
{
v___y_398_ = v___y_413_;
goto v___jp_397_;
}
else
{
uint8_t v___x_421_; uint8_t v___x_422_; 
v___x_421_ = 6;
v___x_422_ = lean_uint8_dec_eq(v_srcClass_371_, v___x_421_);
if (v___x_422_ == 0)
{
v___y_398_ = v___y_413_;
goto v___jp_397_;
}
else
{
uint8_t v___x_423_; 
v___x_423_ = lean_uint8_dec_eq(v_proto_376_, v___x_421_);
if (v___x_423_ == 0)
{
v___y_398_ = v___y_413_;
goto v___jp_397_;
}
else
{
uint32_t v___x_424_; uint8_t v___x_425_; 
v___x_424_ = 22;
v___x_425_ = lean_uint32_dec_eq(v_dstPort_377_, v___x_424_);
if (v___x_425_ == 0)
{
v___y_398_ = v___y_413_;
goto v___jp_397_;
}
else
{
uint8_t v___x_426_; 
v___x_426_ = lean_uint32_dec_eq(v_rulePortMin_378_, v___x_424_);
if (v___x_426_ == 0)
{
v___y_398_ = v___y_413_;
goto v___jp_397_;
}
else
{
uint8_t v___x_427_; 
v___x_427_ = lean_uint32_dec_eq(v_rulePortMax_379_, v___x_424_);
v___y_410_ = v___y_413_;
v___y_411_ = v___x_427_;
goto v___jp_409_;
}
}
}
}
}
}
else
{
uint8_t v___x_428_; uint8_t v___x_429_; 
v___x_428_ = 2;
v___x_429_ = lean_uint8_dec_le(v___x_428_, v_srcClass_371_);
v___y_410_ = v___y_413_;
v___y_411_ = v___x_429_;
goto v___jp_409_;
}
}
else
{
v___y_402_ = v___y_413_;
goto v___jp_401_;
}
}
}
v___jp_430_:
{
uint32_t v___x_433_; uint8_t v___x_434_; 
v___x_433_ = 1;
v___x_434_ = lean_uint32_dec_le(v___x_433_, v_rulePortMin_378_);
if (v___x_434_ == 0)
{
v___y_413_ = v___y_431_;
v___y_414_ = v___y_432_;
goto v___jp_412_;
}
else
{
uint8_t v___x_435_; 
v___x_435_ = lean_uint32_dec_le(v_rulePortMin_378_, v_dstPort_377_);
if (v___x_435_ == 0)
{
v___y_413_ = v___y_431_;
v___y_414_ = v___y_432_;
goto v___jp_412_;
}
else
{
uint8_t v___x_436_; 
v___x_436_ = lean_uint32_dec_le(v_dstPort_377_, v_rulePortMax_379_);
if (v___x_436_ == 0)
{
v___y_413_ = v___y_431_;
v___y_414_ = v___y_432_;
goto v___jp_412_;
}
else
{
uint32_t v___x_437_; uint8_t v___x_438_; 
v___x_437_ = 65535;
v___x_438_ = lean_uint32_dec_le(v_rulePortMax_379_, v___x_437_);
v___y_413_ = v___y_431_;
v___y_414_ = v___x_438_;
goto v___jp_412_;
}
}
}
}
v___jp_439_:
{
uint32_t v___x_441_; uint8_t v___x_442_; 
v___x_441_ = 0;
v___x_442_ = lean_uint32_dec_eq(v_srcId_369_, v___x_441_);
if (v___x_442_ == 0)
{
uint8_t v___x_443_; 
v___x_443_ = lean_uint32_dec_eq(v_dstId_370_, v___x_441_);
if (v___x_443_ == 0)
{
uint8_t v___x_444_; 
v___x_444_ = lean_uint32_dec_eq(v_srcId_369_, v_dstId_370_);
if (v___x_444_ == 0)
{
uint8_t v___x_445_; uint8_t v___x_446_; 
v___x_445_ = 6;
v___x_446_ = lean_uint8_dec_le(v_srcClass_371_, v___x_445_);
if (v___x_446_ == 0)
{
v___y_398_ = v___y_440_;
goto v___jp_397_;
}
else
{
uint8_t v___x_447_; 
v___x_447_ = lean_uint8_dec_le(v_dstClass_372_, v___x_445_);
if (v___x_447_ == 0)
{
v___y_398_ = v___y_440_;
goto v___jp_397_;
}
else
{
uint8_t v___x_448_; uint8_t v___x_449_; 
v___x_448_ = 3;
v___x_449_ = lean_uint8_dec_le(v_bunkerState_381_, v___x_448_);
if (v___x_449_ == 0)
{
v___y_398_ = v___y_440_;
goto v___jp_397_;
}
else
{
uint8_t v___x_450_; uint8_t v___x_451_; 
v___x_450_ = 0;
v___x_451_ = lean_uint8_dec_eq(v_srcRevoked_373_, v___x_450_);
if (v___x_451_ == 0)
{
v___y_398_ = v___y_440_;
goto v___jp_397_;
}
else
{
uint8_t v___x_452_; 
v___x_452_ = lean_uint8_dec_eq(v_dstRevoked_374_, v___x_450_);
if (v___x_452_ == 0)
{
v___y_398_ = v___y_440_;
goto v___jp_397_;
}
else
{
uint8_t v___x_453_; uint8_t v___x_454_; 
v___x_453_ = 1;
v___x_454_ = lean_uint8_dec_eq(v_ruleMatched_375_, v___x_453_);
if (v___x_454_ == 0)
{
v___y_398_ = v___y_440_;
goto v___jp_397_;
}
else
{
uint8_t v___x_455_; 
v___x_455_ = lean_uint64_dec_lt(v_nowEpoch_382_, v_srcExpiresAt_383_);
if (v___x_455_ == 0)
{
v___y_398_ = v___y_440_;
goto v___jp_397_;
}
else
{
uint8_t v___x_456_; 
v___x_456_ = lean_uint64_dec_lt(v_nowEpoch_382_, v_dstExpiresAt_384_);
if (v___x_456_ == 0)
{
v___y_398_ = v___y_440_;
goto v___jp_397_;
}
else
{
uint8_t v___x_457_; 
v___x_457_ = lean_uint8_dec_eq(v_proto_376_, v___x_453_);
if (v___x_457_ == 0)
{
uint8_t v___x_458_; 
v___x_458_ = lean_uint8_dec_eq(v_proto_376_, v___x_445_);
if (v___x_458_ == 0)
{
uint8_t v___x_459_; uint8_t v___x_460_; 
v___x_459_ = 17;
v___x_460_ = lean_uint8_dec_eq(v_proto_376_, v___x_459_);
if (v___x_460_ == 0)
{
v___y_398_ = v___y_440_;
goto v___jp_397_;
}
else
{
v___y_431_ = v___y_440_;
v___y_432_ = v___x_457_;
goto v___jp_430_;
}
}
else
{
v___y_431_ = v___y_440_;
v___y_432_ = v___x_457_;
goto v___jp_430_;
}
}
else
{
uint8_t v___x_461_; 
v___x_461_ = lean_uint32_dec_eq(v_dstPort_377_, v___x_441_);
if (v___x_461_ == 0)
{
v___y_398_ = v___y_440_;
goto v___jp_397_;
}
else
{
uint8_t v___x_462_; 
v___x_462_ = lean_uint32_dec_eq(v_rulePortMin_378_, v___x_441_);
if (v___x_462_ == 0)
{
v___y_398_ = v___y_440_;
goto v___jp_397_;
}
else
{
uint8_t v___x_463_; 
v___x_463_ = lean_uint32_dec_eq(v_rulePortMax_379_, v___x_441_);
v___y_413_ = v___y_440_;
v___y_414_ = v___x_463_;
goto v___jp_412_;
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
}
else
{
v___y_398_ = v___y_440_;
goto v___jp_397_;
}
}
else
{
v___y_398_ = v___y_440_;
goto v___jp_397_;
}
}
else
{
v___y_398_ = v___y_440_;
goto v___jp_397_;
}
}
v___jp_464_:
{
uint8_t v___x_467_; uint8_t v___x_468_; 
v___x_467_ = 3;
v___x_468_ = lean_uint8_dec_eq(v_dstClass_372_, v___x_467_);
if (v___x_468_ == 0)
{
v___y_440_ = v___x_468_;
goto v___jp_439_;
}
else
{
uint8_t v___x_469_; 
v___x_469_ = lean_uint8_dec_le(v_srcClass_371_, v___y_465_);
if (v___x_469_ == 0)
{
v___y_440_ = v___x_469_;
goto v___jp_439_;
}
else
{
if (v___y_466_ == 0)
{
v___y_440_ = v___x_469_;
goto v___jp_439_;
}
else
{
uint8_t v___x_470_; 
v___x_470_ = 0;
v___y_440_ = v___x_470_;
goto v___jp_439_;
}
}
}
}
v___jp_471_:
{
uint8_t v___x_474_; uint8_t v___x_475_; 
v___x_474_ = 5;
v___x_475_ = lean_uint8_dec_eq(v_dstClass_372_, v___x_474_);
if (v___x_475_ == 0)
{
v___y_465_ = v___y_472_;
v___y_466_ = v___y_473_;
goto v___jp_464_;
}
else
{
uint8_t v___x_476_; 
v___x_476_ = lean_uint8_dec_le(v_srcClass_371_, v___y_472_);
if (v___x_476_ == 0)
{
uint8_t v___x_477_; uint8_t v___x_478_; 
v___x_477_ = 3;
v___x_478_ = lean_uint8_dec_eq(v_srcClass_371_, v___x_477_);
if (v___x_478_ == 0)
{
uint8_t v___x_479_; uint8_t v___x_480_; 
v___x_479_ = 2;
v___x_480_ = lean_uint8_dec_eq(v_srcClass_371_, v___x_479_);
if (v___x_480_ == 0)
{
v___y_465_ = v___y_472_;
v___y_466_ = v___y_473_;
goto v___jp_464_;
}
else
{
if (v___y_473_ == 0)
{
v___y_440_ = v___x_480_;
goto v___jp_439_;
}
else
{
v___y_465_ = v___y_472_;
v___y_466_ = v___y_473_;
goto v___jp_464_;
}
}
}
else
{
v___y_440_ = v___x_478_;
goto v___jp_439_;
}
}
else
{
v___y_440_ = v___x_476_;
goto v___jp_439_;
}
}
}
v___jp_481_:
{
if (v___y_483_ == 0)
{
v___y_472_ = v___y_482_;
v___y_473_ = v___y_484_;
goto v___jp_471_;
}
else
{
uint8_t v___x_485_; uint8_t v___x_486_; 
v___x_485_ = 4;
v___x_486_ = lean_uint8_dec_eq(v_srcClass_371_, v___x_485_);
if (v___x_486_ == 0)
{
uint8_t v___x_487_; uint8_t v___x_488_; 
v___x_487_ = 6;
v___x_488_ = lean_uint8_dec_eq(v_srcClass_371_, v___x_487_);
if (v___x_488_ == 0)
{
v___y_440_ = v___y_483_;
goto v___jp_439_;
}
else
{
v___y_472_ = v___y_482_;
v___y_473_ = v___y_484_;
goto v___jp_471_;
}
}
else
{
v___y_472_ = v___y_482_;
v___y_473_ = v___y_484_;
goto v___jp_471_;
}
}
}
v___jp_489_:
{
uint8_t v___x_491_; uint8_t v___x_492_; 
v___x_491_ = 1;
v___x_492_ = lean_uint8_dec_eq(v_jitBiometricGrant_380_, v___x_491_);
if (v___x_492_ == 0)
{
v___y_482_ = v___x_491_;
v___y_483_ = v___y_490_;
v___y_484_ = v___x_492_;
goto v___jp_481_;
}
else
{
uint8_t v___x_493_; uint8_t v___x_494_; 
v___x_493_ = 0;
v___x_494_ = lean_uint8_dec_eq(v_bunkerState_381_, v___x_493_);
if (v___x_494_ == 0)
{
v___y_482_ = v___x_491_;
v___y_483_ = v___y_490_;
v___y_484_ = v___x_494_;
goto v___jp_481_;
}
else
{
uint8_t v___x_495_; 
v___x_495_ = lean_uint64_dec_lt(v_nowEpoch_382_, v_jitExpiresAt_385_);
v___y_482_ = v___x_491_;
v___y_483_ = v___y_490_;
v___y_484_ = v___x_495_;
goto v___jp_481_;
}
}
}
}
}

LEAN_EXPORT uint8_t leanmesh_replay_window_step(uint64_t v_lastMaxSeq_536_, uint64_t v_bitmap_537_, uint64_t v_pktSeq_538_){
{
uint64_t v___x_539_; uint8_t v___x_540_; 
v___x_539_ = 0ULL;
v___x_540_ = lean_uint64_dec_eq(v_pktSeq_538_, v___x_539_);
if (v___x_540_ == 0)
{
uint64_t v___x_541_; uint8_t v___x_542_; 
v___x_541_ = 18446744073709551615ULL;
v___x_542_ = lean_uint64_dec_eq(v_pktSeq_538_, v___x_541_);
if (v___x_542_ == 0)
{
uint8_t v___x_543_; 
v___x_543_ = lean_uint64_dec_lt(v_lastMaxSeq_536_, v_pktSeq_538_);
if (v___x_543_ == 0)
{
uint64_t v_age_544_; uint64_t v___x_545_; uint8_t v___x_546_; 
v_age_544_ = lean_uint64_sub(v_lastMaxSeq_536_, v_pktSeq_538_);
v___x_545_ = 64ULL;
v___x_546_ = lean_uint64_dec_le(v___x_545_, v_age_544_);
if (v___x_546_ == 0)
{
uint64_t v___x_547_; uint64_t v_mask_548_; uint64_t v___x_549_; uint8_t v___x_550_; 
v___x_547_ = 1ULL;
v_mask_548_ = lean_uint64_shift_left(v___x_547_, v_age_544_);
v___x_549_ = lean_uint64_land(v_bitmap_537_, v_mask_548_);
v___x_550_ = lean_uint64_dec_eq(v___x_549_, v___x_539_);
if (v___x_550_ == 0)
{
uint8_t v___x_551_; 
v___x_551_ = 0;
return v___x_551_;
}
else
{
uint8_t v___x_552_; 
v___x_552_ = 1;
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
v___x_554_ = 1;
return v___x_554_;
}
}
else
{
uint8_t v___x_555_; 
v___x_555_ = 0;
return v___x_555_;
}
}
else
{
uint8_t v___x_556_; 
v___x_556_ = 0;
return v___x_556_;
}
}
}

LEAN_EXPORT uint64_t leanmesh_replay_window_next_max(uint64_t v_lastMaxSeq_565_, uint64_t v_bitmap_566_, uint64_t v_pktSeq_567_){
{
uint8_t v___y_569_; uint64_t v___x_573_; uint8_t v___x_574_; 
v___x_573_ = 0ULL;
v___x_574_ = lean_uint64_dec_eq(v_pktSeq_567_, v___x_573_);
if (v___x_574_ == 0)
{
uint64_t v___x_575_; uint8_t v___x_576_; 
v___x_575_ = 18446744073709551615ULL;
v___x_576_ = lean_uint64_dec_eq(v_pktSeq_567_, v___x_575_);
if (v___x_576_ == 0)
{
uint8_t v___x_577_; 
v___x_577_ = lean_uint64_dec_lt(v_lastMaxSeq_565_, v_pktSeq_567_);
if (v___x_577_ == 0)
{
uint64_t v_age_578_; uint64_t v___x_579_; uint8_t v___x_580_; 
v_age_578_ = lean_uint64_sub(v_lastMaxSeq_565_, v_pktSeq_567_);
v___x_579_ = 64ULL;
v___x_580_ = lean_uint64_dec_le(v___x_579_, v_age_578_);
if (v___x_580_ == 0)
{
uint64_t v___x_581_; uint64_t v_mask_582_; uint64_t v___x_583_; uint8_t v___x_584_; 
v___x_581_ = 1ULL;
v_mask_582_ = lean_uint64_shift_left(v___x_581_, v_age_578_);
v___x_583_ = lean_uint64_land(v_bitmap_566_, v_mask_582_);
v___x_584_ = lean_uint64_dec_eq(v___x_583_, v___x_573_);
if (v___x_584_ == 0)
{
uint8_t v___x_585_; 
v___x_585_ = 0;
v___y_569_ = v___x_585_;
goto v___jp_568_;
}
else
{
uint8_t v___x_586_; 
v___x_586_ = 1;
v___y_569_ = v___x_586_;
goto v___jp_568_;
}
}
else
{
uint8_t v___x_587_; 
v___x_587_ = 0;
v___y_569_ = v___x_587_;
goto v___jp_568_;
}
}
else
{
uint8_t v___x_588_; 
v___x_588_ = 1;
v___y_569_ = v___x_588_;
goto v___jp_568_;
}
}
else
{
uint8_t v___x_589_; 
v___x_589_ = 0;
v___y_569_ = v___x_589_;
goto v___jp_568_;
}
}
else
{
uint8_t v___x_590_; 
v___x_590_ = 0;
v___y_569_ = v___x_590_;
goto v___jp_568_;
}
v___jp_568_:
{
uint8_t v___x_570_; uint8_t v___x_571_; 
v___x_570_ = 1;
v___x_571_ = lean_uint8_dec_eq(v___y_569_, v___x_570_);
if (v___x_571_ == 0)
{
return v_lastMaxSeq_565_;
}
else
{
uint8_t v___x_572_; 
v___x_572_ = lean_uint64_dec_lt(v_lastMaxSeq_565_, v_pktSeq_567_);
if (v___x_572_ == 0)
{
return v_lastMaxSeq_565_;
}
else
{
return v_pktSeq_567_;
}
}
}
}
}

LEAN_EXPORT uint64_t leanmesh_replay_window_next_bitmap(uint64_t v_lastMaxSeq_599_, uint64_t v_bitmap_600_, uint64_t v_pktSeq_601_){
{
uint8_t v___y_603_; uint64_t v___x_620_; uint8_t v___x_621_; 
v___x_620_ = 0ULL;
v___x_621_ = lean_uint64_dec_eq(v_pktSeq_601_, v___x_620_);
if (v___x_621_ == 0)
{
uint64_t v___x_622_; uint8_t v___x_623_; 
v___x_622_ = 18446744073709551615ULL;
v___x_623_ = lean_uint64_dec_eq(v_pktSeq_601_, v___x_622_);
if (v___x_623_ == 0)
{
uint8_t v___x_624_; 
v___x_624_ = lean_uint64_dec_lt(v_lastMaxSeq_599_, v_pktSeq_601_);
if (v___x_624_ == 0)
{
uint64_t v_age_625_; uint64_t v___x_626_; uint8_t v___x_627_; 
v_age_625_ = lean_uint64_sub(v_lastMaxSeq_599_, v_pktSeq_601_);
v___x_626_ = 64ULL;
v___x_627_ = lean_uint64_dec_le(v___x_626_, v_age_625_);
if (v___x_627_ == 0)
{
uint64_t v___x_628_; uint64_t v_mask_629_; uint64_t v___x_630_; uint8_t v___x_631_; 
v___x_628_ = 1ULL;
v_mask_629_ = lean_uint64_shift_left(v___x_628_, v_age_625_);
v___x_630_ = lean_uint64_land(v_bitmap_600_, v_mask_629_);
v___x_631_ = lean_uint64_dec_eq(v___x_630_, v___x_620_);
if (v___x_631_ == 0)
{
uint8_t v___x_632_; 
v___x_632_ = 0;
v___y_603_ = v___x_632_;
goto v___jp_602_;
}
else
{
uint8_t v___x_633_; 
v___x_633_ = 1;
v___y_603_ = v___x_633_;
goto v___jp_602_;
}
}
else
{
uint8_t v___x_634_; 
v___x_634_ = 0;
v___y_603_ = v___x_634_;
goto v___jp_602_;
}
}
else
{
uint8_t v___x_635_; 
v___x_635_ = 1;
v___y_603_ = v___x_635_;
goto v___jp_602_;
}
}
else
{
uint8_t v___x_636_; 
v___x_636_ = 0;
v___y_603_ = v___x_636_;
goto v___jp_602_;
}
}
else
{
uint8_t v___x_637_; 
v___x_637_ = 0;
v___y_603_ = v___x_637_;
goto v___jp_602_;
}
v___jp_602_:
{
uint8_t v___x_604_; uint8_t v___x_605_; 
v___x_604_ = 1;
v___x_605_ = lean_uint8_dec_eq(v___y_603_, v___x_604_);
if (v___x_605_ == 0)
{
return v_bitmap_600_;
}
else
{
uint8_t v___x_606_; 
v___x_606_ = lean_uint64_dec_lt(v_lastMaxSeq_599_, v_pktSeq_601_);
if (v___x_606_ == 0)
{
uint64_t v_age_607_; uint64_t v___x_608_; uint8_t v___x_609_; 
v_age_607_ = lean_uint64_sub(v_lastMaxSeq_599_, v_pktSeq_601_);
v___x_608_ = 64ULL;
v___x_609_ = lean_uint64_dec_le(v___x_608_, v_age_607_);
if (v___x_609_ == 0)
{
uint64_t v___x_610_; uint64_t v___x_611_; uint64_t v___x_612_; 
v___x_610_ = 1ULL;
v___x_611_ = lean_uint64_shift_left(v___x_610_, v_age_607_);
v___x_612_ = lean_uint64_lor(v_bitmap_600_, v___x_611_);
return v___x_612_;
}
else
{
return v_bitmap_600_;
}
}
else
{
uint64_t v_delta_613_; uint64_t v___x_614_; uint8_t v___x_615_; 
v_delta_613_ = lean_uint64_sub(v_pktSeq_601_, v_lastMaxSeq_599_);
v___x_614_ = 64ULL;
v___x_615_ = lean_uint64_dec_le(v___x_614_, v_delta_613_);
if (v___x_615_ == 0)
{
uint64_t v___x_616_; uint64_t v___x_617_; uint64_t v___x_618_; 
v___x_616_ = lean_uint64_shift_left(v_bitmap_600_, v_delta_613_);
v___x_617_ = 1ULL;
v___x_618_ = lean_uint64_lor(v___x_616_, v___x_617_);
return v___x_618_;
}
else
{
uint64_t v___x_619_; 
v___x_619_ = 1ULL;
return v___x_619_;
}
}
}
}
}
}

LEAN_EXPORT uint8_t leanmesh_endpoint_roam_step(uint8_t v_aeadAuthOk_710_, uint8_t v_peerPinnedStatic_711_, uint8_t v_candidateIpClass_712_, uint8_t v_allowPrivateRoam_713_, uint8_t v_bunkerState_714_, uint32_t v_candidatePort_715_, uint64_t v_lastRoamSeq_716_, uint64_t v_pktSeq_717_, uint64_t v_lastRoamEpoch_718_, uint64_t v_nowEpoch_719_, uint64_t v_minRoamIntervalSecs_720_){
{
uint8_t v___y_722_; uint8_t v___x_743_; uint8_t v___x_744_; 
v___x_743_ = 5;
v___x_744_ = lean_uint8_dec_eq(v_candidateIpClass_712_, v___x_743_);
if (v___x_744_ == 0)
{
uint8_t v___x_745_; uint8_t v___x_746_; 
v___x_745_ = 1;
v___x_746_ = lean_uint8_dec_eq(v_allowPrivateRoam_713_, v___x_745_);
if (v___x_746_ == 0)
{
v___y_722_ = v___x_746_;
goto v___jp_721_;
}
else
{
uint8_t v___x_747_; uint8_t v___x_748_; 
v___x_747_ = 3;
v___x_748_ = lean_uint8_dec_eq(v_candidateIpClass_712_, v___x_747_);
if (v___x_748_ == 0)
{
uint8_t v___x_749_; uint8_t v___x_750_; 
v___x_749_ = 4;
v___x_750_ = lean_uint8_dec_eq(v_candidateIpClass_712_, v___x_749_);
v___y_722_ = v___x_750_;
goto v___jp_721_;
}
else
{
v___y_722_ = v___x_748_;
goto v___jp_721_;
}
}
}
else
{
v___y_722_ = v___x_744_;
goto v___jp_721_;
}
v___jp_721_:
{
uint8_t v___x_723_; uint8_t v___x_724_; 
v___x_723_ = 1;
v___x_724_ = lean_uint8_dec_eq(v_aeadAuthOk_710_, v___x_723_);
if (v___x_724_ == 0)
{
uint8_t v___x_725_; 
v___x_725_ = 0;
return v___x_725_;
}
else
{
uint8_t v___x_726_; uint8_t v___x_727_; 
v___x_726_ = 0;
v___x_727_ = lean_uint8_dec_eq(v_peerPinnedStatic_711_, v___x_726_);
if (v___x_727_ == 0)
{
return v___x_726_;
}
else
{
uint8_t v___x_728_; 
v___x_728_ = lean_uint8_dec_eq(v_bunkerState_714_, v___x_726_);
if (v___x_728_ == 0)
{
return v___x_726_;
}
else
{
uint32_t v___x_729_; uint8_t v___x_730_; 
v___x_729_ = 1;
v___x_730_ = lean_uint32_dec_le(v___x_729_, v_candidatePort_715_);
if (v___x_730_ == 0)
{
return v___x_726_;
}
else
{
uint32_t v___x_731_; uint8_t v___x_732_; 
v___x_731_ = 65535;
v___x_732_ = lean_uint32_dec_le(v_candidatePort_715_, v___x_731_);
if (v___x_732_ == 0)
{
return v___x_726_;
}
else
{
uint8_t v___x_733_; 
v___x_733_ = lean_uint64_dec_lt(v_lastRoamSeq_716_, v_pktSeq_717_);
if (v___x_733_ == 0)
{
return v___x_726_;
}
else
{
uint64_t v___x_734_; uint8_t v___x_735_; 
v___x_734_ = 18446744073709551615ULL;
v___x_735_ = lean_uint64_dec_lt(v_pktSeq_717_, v___x_734_);
if (v___x_735_ == 0)
{
return v___x_726_;
}
else
{
if (v___y_722_ == 0)
{
return v___x_726_;
}
else
{
uint64_t v___x_736_; uint8_t v___x_737_; 
v___x_736_ = 0ULL;
v___x_737_ = lean_uint64_dec_lt(v___x_736_, v_minRoamIntervalSecs_720_);
if (v___x_737_ == 0)
{
return v___x_726_;
}
else
{
uint64_t v___x_738_; uint8_t v___x_739_; 
v___x_738_ = 86400ULL;
v___x_739_ = lean_uint64_dec_le(v_minRoamIntervalSecs_720_, v___x_738_);
if (v___x_739_ == 0)
{
return v___x_726_;
}
else
{
uint8_t v___x_740_; 
v___x_740_ = lean_uint64_dec_le(v_lastRoamEpoch_718_, v_nowEpoch_719_);
if (v___x_740_ == 0)
{
return v___x_726_;
}
else
{
uint64_t v___x_741_; uint8_t v___x_742_; 
v___x_741_ = lean_uint64_sub(v_nowEpoch_719_, v_lastRoamEpoch_718_);
v___x_742_ = lean_uint64_dec_le(v_minRoamIntervalSecs_720_, v___x_741_);
if (v___x_742_ == 0)
{
return v___x_726_;
}
else
{
return v___x_723_;
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
}
}
}
}

LEAN_EXPORT uint8_t leanmesh_relay_select_step(uint8_t v_routeAllowed_794_, uint8_t v_lanReachable_795_, uint8_t v_wanReachable_796_, uint8_t v_relayHealthy_797_, uint32_t v_srcId_798_, uint32_t v_dstId_799_, uint32_t v_relayId_800_, uint32_t v_activeRelaySessions_801_, uint32_t v_maxRelaySessions_802_, uint64_t v_nowEpoch_803_, uint64_t v_directHandshakeAt_804_, uint64_t v_maxDirectStaleSecs_805_){
{
uint8_t v___y_811_; uint8_t v___y_815_; uint8_t v___y_819_; uint8_t v___y_820_; uint8_t v___y_823_; uint32_t v___y_824_; uint8_t v___y_825_; uint8_t v___y_826_; uint8_t v___y_830_; uint8_t v___y_831_; uint32_t v___y_832_; uint8_t v___y_833_; uint8_t v___y_836_; uint64_t v___x_849_; uint8_t v___x_850_; 
v___x_849_ = 0ULL;
v___x_850_ = lean_uint64_dec_lt(v___x_849_, v_directHandshakeAt_804_);
if (v___x_850_ == 0)
{
v___y_836_ = v___x_850_;
goto v___jp_835_;
}
else
{
uint8_t v___x_851_; 
v___x_851_ = lean_uint64_dec_lt(v___x_849_, v_maxDirectStaleSecs_805_);
if (v___x_851_ == 0)
{
v___y_836_ = v___x_851_;
goto v___jp_835_;
}
else
{
uint64_t v___x_852_; uint8_t v___x_853_; 
v___x_852_ = 86400ULL;
v___x_853_ = lean_uint64_dec_le(v_maxDirectStaleSecs_805_, v___x_852_);
if (v___x_853_ == 0)
{
v___y_836_ = v___x_853_;
goto v___jp_835_;
}
else
{
uint8_t v___x_854_; 
v___x_854_ = lean_uint64_dec_le(v_directHandshakeAt_804_, v_nowEpoch_803_);
if (v___x_854_ == 0)
{
v___y_836_ = v___x_854_;
goto v___jp_835_;
}
else
{
uint64_t v___x_855_; uint8_t v___x_856_; 
v___x_855_ = lean_uint64_sub(v_nowEpoch_803_, v_directHandshakeAt_804_);
v___x_856_ = lean_uint64_dec_le(v___x_855_, v_maxDirectStaleSecs_805_);
v___y_836_ = v___x_856_;
goto v___jp_835_;
}
}
}
}
v___jp_806_:
{
uint8_t v___x_807_; 
v___x_807_ = lean_uint32_dec_lt(v_activeRelaySessions_801_, v_maxRelaySessions_802_);
if (v___x_807_ == 0)
{
uint8_t v___x_808_; 
v___x_808_ = 0;
return v___x_808_;
}
else
{
uint8_t v___x_809_; 
v___x_809_ = 3;
return v___x_809_;
}
}
v___jp_810_:
{
uint8_t v___x_812_; 
v___x_812_ = lean_uint32_dec_eq(v_relayId_800_, v_dstId_799_);
if (v___x_812_ == 0)
{
goto v___jp_806_;
}
else
{
if (v___y_811_ == 0)
{
uint8_t v___x_813_; 
v___x_813_ = 0;
return v___x_813_;
}
else
{
goto v___jp_806_;
}
}
}
v___jp_814_:
{
uint8_t v___x_816_; 
v___x_816_ = lean_uint32_dec_eq(v_relayId_800_, v_srcId_798_);
if (v___x_816_ == 0)
{
v___y_811_ = v___y_815_;
goto v___jp_810_;
}
else
{
if (v___y_815_ == 0)
{
uint8_t v___x_817_; 
v___x_817_ = 0;
return v___x_817_;
}
else
{
v___y_811_ = v___y_815_;
goto v___jp_810_;
}
}
}
v___jp_818_:
{
if (v___y_820_ == 0)
{
uint8_t v___x_821_; 
v___x_821_ = 0;
return v___x_821_;
}
else
{
v___y_815_ = v___y_819_;
goto v___jp_814_;
}
}
v___jp_822_:
{
uint8_t v___x_827_; 
v___x_827_ = lean_uint8_dec_eq(v_relayHealthy_797_, v___y_823_);
if (v___x_827_ == 0)
{
v___y_819_ = v___y_826_;
v___y_820_ = v___y_825_;
goto v___jp_818_;
}
else
{
uint8_t v___x_828_; 
v___x_828_ = lean_uint32_dec_eq(v_relayId_800_, v___y_824_);
if (v___x_828_ == 0)
{
v___y_815_ = v___y_826_;
goto v___jp_814_;
}
else
{
v___y_819_ = v___y_826_;
v___y_820_ = v___y_826_;
goto v___jp_818_;
}
}
}
v___jp_829_:
{
uint8_t v___x_834_; 
v___x_834_ = lean_uint8_dec_eq(v_wanReachable_796_, v___y_831_);
if (v___x_834_ == 0)
{
v___y_823_ = v___y_831_;
v___y_824_ = v___y_832_;
v___y_825_ = v___y_833_;
v___y_826_ = v___y_833_;
goto v___jp_822_;
}
else
{
if (v___y_830_ == 0)
{
v___y_823_ = v___y_831_;
v___y_824_ = v___y_832_;
v___y_825_ = v___y_833_;
v___y_826_ = v___y_830_;
goto v___jp_822_;
}
else
{
return v___y_831_;
}
}
}
v___jp_835_:
{
uint8_t v___x_837_; uint8_t v___x_838_; 
v___x_837_ = 1;
v___x_838_ = lean_uint8_dec_eq(v_routeAllowed_794_, v___x_837_);
if (v___x_838_ == 0)
{
uint8_t v___x_839_; 
v___x_839_ = 0;
return v___x_839_;
}
else
{
uint32_t v___x_840_; uint8_t v___x_841_; 
v___x_840_ = 0;
v___x_841_ = lean_uint32_dec_eq(v_srcId_798_, v___x_840_);
if (v___x_841_ == 0)
{
uint8_t v___x_842_; 
v___x_842_ = lean_uint32_dec_eq(v_dstId_799_, v___x_840_);
if (v___x_842_ == 0)
{
uint8_t v___x_843_; 
v___x_843_ = lean_uint32_dec_eq(v_srcId_798_, v_dstId_799_);
if (v___x_843_ == 0)
{
uint8_t v___x_844_; 
v___x_844_ = lean_uint8_dec_eq(v_lanReachable_795_, v___x_837_);
if (v___x_844_ == 0)
{
v___y_830_ = v___y_836_;
v___y_831_ = v___x_837_;
v___y_832_ = v___x_840_;
v___y_833_ = v___x_843_;
goto v___jp_829_;
}
else
{
if (v___y_836_ == 0)
{
v___y_830_ = v___y_836_;
v___y_831_ = v___x_837_;
v___y_832_ = v___x_840_;
v___y_833_ = v___x_843_;
goto v___jp_829_;
}
else
{
uint8_t v___x_845_; 
v___x_845_ = 2;
return v___x_845_;
}
}
}
else
{
uint8_t v___x_846_; 
v___x_846_ = 0;
return v___x_846_;
}
}
else
{
uint8_t v___x_847_; 
v___x_847_ = 0;
return v___x_847_;
}
}
else
{
uint8_t v___x_848_; 
v___x_848_ = 0;
return v___x_848_;
}
}
}
}
}

LEAN_EXPORT uint32_t leanmesh_bunker_isolate_step(uint8_t v_currentState_1016_, uint8_t v_isSovereignNode_1017_, uint8_t v_canaryTripped_1018_, uint8_t v_authFailureBurst_1019_, uint8_t v_manualTrigger_1020_, uint8_t v_biometricUnbunker_1021_, uint8_t v_heartbeatValid_1022_, uint64_t v_nowEpoch_1023_, uint64_t v_lastHeartbeatAt_1024_, uint64_t v_deadManTimeoutSecs_1025_){
{
uint32_t v___y_1027_; uint8_t v___y_1031_; uint8_t v___y_1032_; uint32_t v___y_1033_; uint8_t v___y_1034_; uint32_t v___y_1035_; uint8_t v___y_1041_; uint32_t v___y_1042_; uint8_t v___y_1043_; uint32_t v___y_1044_; uint8_t v___y_1051_; uint8_t v___y_1058_; uint8_t v___y_1059_; uint8_t v___y_1062_; uint8_t v___y_1065_; uint8_t v___y_1066_; uint8_t v___y_1075_; uint8_t v___y_1076_; uint8_t v___y_1087_; uint8_t v___x_1091_; uint8_t v___x_1092_; 
v___x_1091_ = 0;
v___x_1092_ = lean_uint8_dec_eq(v_currentState_1016_, v___x_1091_);
if (v___x_1092_ == 0)
{
uint8_t v___x_1093_; uint8_t v___x_1094_; 
v___x_1093_ = 1;
v___x_1094_ = lean_uint8_dec_eq(v_currentState_1016_, v___x_1093_);
if (v___x_1094_ == 0)
{
uint8_t v___x_1095_; uint8_t v___x_1096_; 
v___x_1095_ = 2;
v___x_1096_ = lean_uint8_dec_eq(v_currentState_1016_, v___x_1095_);
if (v___x_1096_ == 0)
{
uint8_t v___x_1097_; 
v___x_1097_ = 3;
v___y_1087_ = v___x_1097_;
goto v___jp_1086_;
}
else
{
v___y_1087_ = v___x_1095_;
goto v___jp_1086_;
}
}
else
{
v___y_1087_ = v___x_1093_;
goto v___jp_1086_;
}
}
else
{
v___y_1087_ = v___x_1091_;
goto v___jp_1086_;
}
v___jp_1026_:
{
uint32_t v___x_1028_; uint32_t v___x_1029_; 
v___x_1028_ = 16777216;
v___x_1029_ = lean_uint32_lor(v___y_1027_, v___x_1028_);
return v___x_1029_;
}
v___jp_1030_:
{
uint32_t v___x_1036_; uint8_t v___x_1037_; uint8_t v___x_1038_; 
v___x_1036_ = lean_uint32_lor(v___y_1033_, v___y_1035_);
v___x_1037_ = 3;
v___x_1038_ = lean_uint8_dec_eq(v___y_1031_, v___x_1037_);
if (v___x_1038_ == 0)
{
uint8_t v___x_1039_; 
v___x_1039_ = lean_uint8_dec_eq(v_isSovereignNode_1017_, v___y_1032_);
if (v___x_1039_ == 0)
{
return v___x_1036_;
}
else
{
if (v___y_1034_ == 0)
{
return v___x_1036_;
}
else
{
v___y_1027_ = v___x_1036_;
goto v___jp_1026_;
}
}
}
else
{
v___y_1027_ = v___x_1036_;
goto v___jp_1026_;
}
}
v___jp_1040_:
{
uint32_t v___x_1045_; uint8_t v___x_1046_; uint8_t v___x_1047_; 
v___x_1045_ = lean_uint32_lor(v___y_1042_, v___y_1044_);
v___x_1046_ = 2;
v___x_1047_ = lean_uint8_dec_le(v___x_1046_, v___y_1041_);
if (v___x_1047_ == 0)
{
uint32_t v___x_1048_; 
v___x_1048_ = 0;
v___y_1031_ = v___y_1041_;
v___y_1032_ = v___y_1043_;
v___y_1033_ = v___x_1045_;
v___y_1034_ = v___x_1047_;
v___y_1035_ = v___x_1048_;
goto v___jp_1030_;
}
else
{
uint32_t v___x_1049_; 
v___x_1049_ = 65536;
v___y_1031_ = v___y_1041_;
v___y_1032_ = v___y_1043_;
v___y_1033_ = v___x_1045_;
v___y_1034_ = v___x_1047_;
v___y_1035_ = v___x_1049_;
goto v___jp_1030_;
}
}
v___jp_1050_:
{
uint32_t v___x_1052_; uint8_t v___x_1053_; uint8_t v___x_1054_; 
v___x_1052_ = lean_uint8_to_uint32(v___y_1051_);
v___x_1053_ = 1;
v___x_1054_ = lean_uint8_dec_le(v___x_1053_, v___y_1051_);
if (v___x_1054_ == 0)
{
uint32_t v___x_1055_; 
v___x_1055_ = 0;
v___y_1041_ = v___y_1051_;
v___y_1042_ = v___x_1052_;
v___y_1043_ = v___x_1053_;
v___y_1044_ = v___x_1055_;
goto v___jp_1040_;
}
else
{
uint32_t v___x_1056_; 
v___x_1056_ = 256;
v___y_1041_ = v___y_1051_;
v___y_1042_ = v___x_1052_;
v___y_1043_ = v___x_1053_;
v___y_1044_ = v___x_1056_;
goto v___jp_1040_;
}
}
v___jp_1057_:
{
uint8_t v___x_1060_; 
v___x_1060_ = lean_uint8_dec_le(v___y_1058_, v___y_1059_);
if (v___x_1060_ == 0)
{
v___y_1051_ = v___y_1058_;
goto v___jp_1050_;
}
else
{
v___y_1051_ = v___y_1059_;
goto v___jp_1050_;
}
}
v___jp_1061_:
{
uint8_t v___x_1063_; 
v___x_1063_ = 3;
v___y_1058_ = v___y_1062_;
v___y_1059_ = v___x_1063_;
goto v___jp_1057_;
}
v___jp_1064_:
{
uint8_t v___x_1067_; 
v___x_1067_ = lean_uint8_dec_eq(v_canaryTripped_1018_, v___y_1065_);
if (v___x_1067_ == 0)
{
uint8_t v___x_1068_; uint8_t v___x_1069_; 
v___x_1068_ = 2;
v___x_1069_ = lean_uint8_dec_eq(v_manualTrigger_1020_, v___x_1068_);
if (v___x_1069_ == 0)
{
uint8_t v___x_1070_; 
v___x_1070_ = lean_uint8_dec_eq(v_authFailureBurst_1019_, v___y_1065_);
if (v___x_1070_ == 0)
{
uint8_t v___x_1071_; 
v___x_1071_ = lean_uint8_dec_eq(v_manualTrigger_1020_, v___y_1065_);
if (v___x_1071_ == 0)
{
uint8_t v___x_1072_; 
v___x_1072_ = 0;
v___y_1058_ = v___y_1066_;
v___y_1059_ = v___x_1072_;
goto v___jp_1057_;
}
else
{
v___y_1058_ = v___y_1066_;
v___y_1059_ = v___y_1065_;
goto v___jp_1057_;
}
}
else
{
v___y_1058_ = v___y_1066_;
v___y_1059_ = v___y_1065_;
goto v___jp_1057_;
}
}
else
{
v___y_1058_ = v___y_1066_;
v___y_1059_ = v___x_1068_;
goto v___jp_1057_;
}
}
else
{
uint8_t v___x_1073_; 
v___x_1073_ = 2;
v___y_1058_ = v___y_1066_;
v___y_1059_ = v___x_1073_;
goto v___jp_1057_;
}
}
v___jp_1074_:
{
uint8_t v___x_1077_; uint8_t v___x_1078_; 
v___x_1077_ = 3;
v___x_1078_ = lean_uint8_dec_eq(v_manualTrigger_1020_, v___x_1077_);
if (v___x_1078_ == 0)
{
uint8_t v___x_1079_; 
v___x_1079_ = lean_uint8_dec_eq(v_isSovereignNode_1017_, v___y_1075_);
if (v___x_1079_ == 0)
{
v___y_1065_ = v___y_1075_;
v___y_1066_ = v___y_1076_;
goto v___jp_1064_;
}
else
{
uint8_t v___x_1080_; 
v___x_1080_ = lean_uint8_dec_eq(v_heartbeatValid_1022_, v___y_1075_);
if (v___x_1080_ == 0)
{
v___y_1062_ = v___y_1076_;
goto v___jp_1061_;
}
else
{
uint64_t v___x_1081_; uint8_t v___x_1082_; 
v___x_1081_ = 0ULL;
v___x_1082_ = lean_uint64_dec_eq(v_deadManTimeoutSecs_1025_, v___x_1081_);
if (v___x_1082_ == 0)
{
uint8_t v___x_1083_; 
v___x_1083_ = lean_uint64_dec_lt(v_nowEpoch_1023_, v_lastHeartbeatAt_1024_);
if (v___x_1083_ == 0)
{
uint64_t v___x_1084_; uint8_t v___x_1085_; 
v___x_1084_ = lean_uint64_sub(v_nowEpoch_1023_, v_lastHeartbeatAt_1024_);
v___x_1085_ = lean_uint64_dec_le(v_deadManTimeoutSecs_1025_, v___x_1084_);
if (v___x_1085_ == 0)
{
v___y_1065_ = v___y_1075_;
v___y_1066_ = v___y_1076_;
goto v___jp_1064_;
}
else
{
v___y_1062_ = v___y_1076_;
goto v___jp_1061_;
}
}
else
{
v___y_1062_ = v___y_1076_;
goto v___jp_1061_;
}
}
else
{
v___y_1062_ = v___y_1076_;
goto v___jp_1061_;
}
}
}
}
else
{
v___y_1062_ = v___y_1076_;
goto v___jp_1061_;
}
}
v___jp_1086_:
{
uint8_t v___x_1088_; uint8_t v___x_1089_; 
v___x_1088_ = 1;
v___x_1089_ = lean_uint8_dec_eq(v_biometricUnbunker_1021_, v___x_1088_);
if (v___x_1089_ == 0)
{
v___y_1075_ = v___x_1088_;
v___y_1076_ = v___y_1087_;
goto v___jp_1074_;
}
else
{
uint8_t v___x_1090_; 
v___x_1090_ = 0;
v___y_1075_ = v___x_1088_;
v___y_1076_ = v___x_1090_;
goto v___jp_1074_;
}
}
}
}

LEAN_EXPORT uint8_t leanmesh_frame_bounds_step(uint32_t v_magic_1120_, uint8_t v_version_1121_, uint8_t v_frameKind_1122_, uint8_t v_tagVerified_1123_, uint64_t v_headerLen_1124_, uint64_t v_payloadLen_1125_, uint64_t v_maxFrameBytes_1126_, uint64_t v_bufCap_1127_){
{
uint32_t v___x_1128_; uint8_t v___x_1129_; 
v___x_1128_ = 1280136008;
v___x_1129_ = lean_uint32_dec_eq(v_magic_1120_, v___x_1128_);
if (v___x_1129_ == 0)
{
uint8_t v___x_1130_; 
v___x_1130_ = 0;
return v___x_1130_;
}
else
{
uint8_t v___x_1131_; uint8_t v___x_1132_; 
v___x_1131_ = 1;
v___x_1132_ = lean_uint8_dec_eq(v_version_1121_, v___x_1131_);
if (v___x_1132_ == 0)
{
uint8_t v___x_1133_; 
v___x_1133_ = 0;
return v___x_1133_;
}
else
{
uint8_t v___x_1134_; 
v___x_1134_ = lean_uint8_dec_le(v___x_1131_, v_frameKind_1122_);
if (v___x_1134_ == 0)
{
uint8_t v___x_1135_; 
v___x_1135_ = 0;
return v___x_1135_;
}
else
{
uint8_t v___x_1136_; uint8_t v___x_1137_; 
v___x_1136_ = 6;
v___x_1137_ = lean_uint8_dec_le(v_frameKind_1122_, v___x_1136_);
if (v___x_1137_ == 0)
{
uint8_t v___x_1138_; 
v___x_1138_ = 0;
return v___x_1138_;
}
else
{
uint8_t v___x_1139_; 
v___x_1139_ = lean_uint8_dec_eq(v_tagVerified_1123_, v___x_1131_);
if (v___x_1139_ == 0)
{
uint8_t v___x_1140_; 
v___x_1140_ = 0;
return v___x_1140_;
}
else
{
uint64_t v___x_1141_; uint8_t v___x_1142_; 
v___x_1141_ = 32ULL;
v___x_1142_ = lean_uint64_dec_le(v___x_1141_, v_headerLen_1124_);
if (v___x_1142_ == 0)
{
uint8_t v___x_1143_; 
v___x_1143_ = 0;
return v___x_1143_;
}
else
{
uint8_t v___x_1144_; 
v___x_1144_ = lean_uint64_dec_le(v_maxFrameBytes_1126_, v_bufCap_1127_);
if (v___x_1144_ == 0)
{
uint8_t v___x_1145_; 
v___x_1145_ = 0;
return v___x_1145_;
}
else
{
uint8_t v___x_1146_; 
v___x_1146_ = lean_uint64_dec_le(v_headerLen_1124_, v_maxFrameBytes_1126_);
if (v___x_1146_ == 0)
{
uint8_t v___x_1147_; 
v___x_1147_ = 0;
return v___x_1147_;
}
else
{
uint64_t v___x_1148_; uint8_t v___x_1149_; 
v___x_1148_ = lean_uint64_sub(v_maxFrameBytes_1126_, v_headerLen_1124_);
v___x_1149_ = lean_uint64_dec_le(v_payloadLen_1125_, v___x_1148_);
if (v___x_1149_ == 0)
{
uint8_t v___x_1150_; 
v___x_1150_ = 0;
return v___x_1150_;
}
else
{
return v___x_1131_;
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

LEAN_EXPORT uint8_t leanmesh_overlay_ip_step(uint32_t v_peerIdA_1178_, uint32_t v_peerIdB_1179_, uint32_t v_ipA_1180_, uint32_t v_ipB_1181_, uint8_t v_prefixLenA_1182_, uint8_t v_prefixLenB_1183_){
{
uint32_t v___x_1184_; uint8_t v___x_1185_; 
v___x_1184_ = 0;
v___x_1185_ = lean_uint32_dec_eq(v_peerIdA_1178_, v___x_1184_);
if (v___x_1185_ == 0)
{
uint8_t v___x_1186_; 
v___x_1186_ = lean_uint32_dec_eq(v_peerIdB_1179_, v___x_1184_);
if (v___x_1186_ == 0)
{
uint8_t v___x_1187_; 
v___x_1187_ = lean_uint32_dec_eq(v_peerIdA_1178_, v_peerIdB_1179_);
if (v___x_1187_ == 0)
{
uint32_t v___x_1188_; uint8_t v___x_1189_; 
v___x_1188_ = 173539329;
v___x_1189_ = lean_uint32_dec_le(v___x_1188_, v_ipA_1180_);
if (v___x_1189_ == 0)
{
uint8_t v___x_1190_; 
v___x_1190_ = 0;
return v___x_1190_;
}
else
{
uint32_t v___x_1191_; uint8_t v___x_1192_; 
v___x_1191_ = 173604862;
v___x_1192_ = lean_uint32_dec_le(v_ipA_1180_, v___x_1191_);
if (v___x_1192_ == 0)
{
uint8_t v___x_1193_; 
v___x_1193_ = 0;
return v___x_1193_;
}
else
{
uint8_t v___x_1194_; 
v___x_1194_ = lean_uint32_dec_le(v___x_1188_, v_ipB_1181_);
if (v___x_1194_ == 0)
{
uint8_t v___x_1195_; 
v___x_1195_ = 0;
return v___x_1195_;
}
else
{
uint8_t v___x_1196_; 
v___x_1196_ = lean_uint32_dec_le(v_ipB_1181_, v___x_1191_);
if (v___x_1196_ == 0)
{
uint8_t v___x_1197_; 
v___x_1197_ = 0;
return v___x_1197_;
}
else
{
uint8_t v___x_1198_; uint8_t v___x_1199_; 
v___x_1198_ = 32;
v___x_1199_ = lean_uint8_dec_eq(v_prefixLenA_1182_, v___x_1198_);
if (v___x_1199_ == 0)
{
uint8_t v___x_1200_; 
v___x_1200_ = 0;
return v___x_1200_;
}
else
{
uint8_t v___x_1201_; 
v___x_1201_ = lean_uint8_dec_eq(v_prefixLenB_1183_, v___x_1198_);
if (v___x_1201_ == 0)
{
uint8_t v___x_1202_; 
v___x_1202_ = 0;
return v___x_1202_;
}
else
{
uint8_t v___x_1203_; 
v___x_1203_ = lean_uint32_dec_eq(v_ipA_1180_, v_ipB_1181_);
if (v___x_1203_ == 0)
{
uint8_t v___x_1204_; 
v___x_1204_ = 1;
return v___x_1204_;
}
else
{
uint8_t v___x_1205_; 
v___x_1205_ = 0;
return v___x_1205_;
}
}
}
}
}
}
}
}
else
{
uint8_t v___x_1206_; 
v___x_1206_ = 0;
return v___x_1206_;
}
}
else
{
uint8_t v___x_1207_; 
v___x_1207_ = 0;
return v___x_1207_;
}
}
else
{
uint8_t v___x_1208_; 
v___x_1208_ = 0;
return v___x_1208_;
}
}
}

LEAN_EXPORT uint8_t leanmesh_reconcile_wg_step(uint8_t v_manifestValid_1247_, uint8_t v_peerPresentInKernel_1248_, uint8_t v_peerRevoked_1249_, uint8_t v_pubkeyMatches_1250_, uint8_t v_allowedIpMatches_1251_, uint8_t v_endpointChanged_1252_, uint8_t v_bunkerPruneNonAdmin_1253_, uint8_t v_peerIsAdmin_1254_, uint64_t v_nowEpoch_1255_, uint64_t v_peerExpiresAt_1256_){
{
uint8_t v___x_1257_; uint8_t v___x_1272_; 
v___x_1257_ = 1;
v___x_1272_ = lean_uint8_dec_eq(v_manifestValid_1247_, v___x_1257_);
if (v___x_1272_ == 0)
{
uint8_t v___x_1273_; 
v___x_1273_ = 0;
return v___x_1273_;
}
else
{
uint8_t v___x_1274_; 
v___x_1274_ = lean_uint8_dec_eq(v_peerRevoked_1249_, v___x_1257_);
if (v___x_1274_ == 0)
{
uint8_t v___x_1275_; 
v___x_1275_ = lean_uint64_dec_le(v_peerExpiresAt_1256_, v_nowEpoch_1255_);
if (v___x_1275_ == 0)
{
uint8_t v___x_1276_; uint8_t v___x_1277_; 
v___x_1276_ = 2;
v___x_1277_ = lean_uint8_dec_le(v___x_1276_, v_bunkerPruneNonAdmin_1253_);
if (v___x_1277_ == 0)
{
uint8_t v___x_1278_; 
v___x_1278_ = lean_uint8_dec_eq(v_bunkerPruneNonAdmin_1253_, v___x_1257_);
if (v___x_1278_ == 0)
{
goto v___jp_1258_;
}
else
{
uint8_t v___x_1279_; 
v___x_1279_ = lean_uint8_dec_eq(v_peerIsAdmin_1254_, v___x_1257_);
if (v___x_1279_ == 0)
{
goto v___jp_1269_;
}
else
{
goto v___jp_1258_;
}
}
}
else
{
goto v___jp_1269_;
}
}
else
{
goto v___jp_1269_;
}
}
else
{
goto v___jp_1269_;
}
}
v___jp_1258_:
{
uint8_t v___x_1259_; uint8_t v___x_1260_; 
v___x_1259_ = 0;
v___x_1260_ = lean_uint8_dec_eq(v_peerPresentInKernel_1248_, v___x_1259_);
if (v___x_1260_ == 0)
{
uint8_t v___x_1261_; 
v___x_1261_ = lean_uint8_dec_eq(v_pubkeyMatches_1250_, v___x_1257_);
if (v___x_1261_ == 0)
{
uint8_t v___x_1262_; 
v___x_1262_ = 3;
return v___x_1262_;
}
else
{
uint8_t v___x_1263_; 
v___x_1263_ = lean_uint8_dec_eq(v_allowedIpMatches_1251_, v___x_1257_);
if (v___x_1263_ == 0)
{
uint8_t v___x_1264_; 
v___x_1264_ = 3;
return v___x_1264_;
}
else
{
uint8_t v___x_1265_; 
v___x_1265_ = lean_uint8_dec_eq(v_endpointChanged_1252_, v___x_1257_);
if (v___x_1265_ == 0)
{
uint8_t v___x_1266_; 
v___x_1266_ = 6;
return v___x_1266_;
}
else
{
uint8_t v___x_1267_; 
v___x_1267_ = 5;
return v___x_1267_;
}
}
}
}
else
{
uint8_t v___x_1268_; 
v___x_1268_ = 4;
return v___x_1268_;
}
}
v___jp_1269_:
{
uint8_t v___x_1270_; 
v___x_1270_ = lean_uint8_dec_eq(v_peerPresentInKernel_1248_, v___x_1257_);
if (v___x_1270_ == 0)
{
uint8_t v___x_1271_; 
v___x_1271_ = 2;
return v___x_1271_;
}
else
{
return v___x_1257_;
}
}
}
}

LEAN_EXPORT uint32_t leanmesh_jit_lease_step(uint8_t v_biometricSigValid_1322_, uint8_t v_operatorSameOwner_1323_, uint8_t v_missionActive_1324_, uint8_t v_grantRevoked_1325_, uint8_t v_bunkerState_1326_, uint8_t v_srcClass_1327_, uint8_t v_dstClass_1328_, uint64_t v_nowEpoch_1329_, uint64_t v_grantIssuedAt_1330_, uint64_t v_grantExpiresAt_1331_, uint64_t v_maxJitTtlSecs_1332_){
{
uint8_t v___x_1358_; uint8_t v___x_1359_; 
v___x_1358_ = 0;
v___x_1359_ = lean_uint8_dec_eq(v_missionActive_1324_, v___x_1358_);
if (v___x_1359_ == 0)
{
uint8_t v___x_1360_; uint8_t v___x_1361_; 
v___x_1360_ = 1;
v___x_1361_ = lean_uint8_dec_eq(v_grantRevoked_1325_, v___x_1360_);
if (v___x_1361_ == 0)
{
uint8_t v___x_1362_; 
v___x_1362_ = lean_uint8_dec_eq(v_bunkerState_1326_, v___x_1358_);
if (v___x_1362_ == 0)
{
uint32_t v___x_1363_; 
v___x_1363_ = 256;
return v___x_1363_;
}
else
{
uint8_t v___x_1364_; 
v___x_1364_ = lean_uint64_dec_le(v_grantExpiresAt_1331_, v_nowEpoch_1329_);
if (v___x_1364_ == 0)
{
uint8_t v___x_1365_; 
v___x_1365_ = lean_uint8_dec_eq(v_biometricSigValid_1322_, v___x_1360_);
if (v___x_1365_ == 0)
{
uint32_t v___x_1366_; 
v___x_1366_ = 0;
return v___x_1366_;
}
else
{
uint8_t v___x_1367_; 
v___x_1367_ = lean_uint8_dec_eq(v_operatorSameOwner_1323_, v___x_1360_);
if (v___x_1367_ == 0)
{
uint32_t v___x_1368_; 
v___x_1368_ = 0;
return v___x_1368_;
}
else
{
uint8_t v___x_1369_; uint8_t v___x_1370_; 
v___x_1369_ = 2;
v___x_1370_ = lean_uint8_dec_eq(v_srcClass_1327_, v___x_1369_);
if (v___x_1370_ == 0)
{
goto v___jp_1352_;
}
else
{
uint8_t v___x_1371_; uint8_t v___x_1372_; 
v___x_1371_ = 5;
v___x_1372_ = lean_uint8_dec_eq(v_dstClass_1328_, v___x_1371_);
if (v___x_1372_ == 0)
{
goto v___jp_1352_;
}
else
{
goto v___jp_1333_;
}
}
}
}
}
else
{
uint32_t v___x_1373_; 
v___x_1373_ = 256;
return v___x_1373_;
}
}
}
else
{
uint32_t v___x_1374_; 
v___x_1374_ = 256;
return v___x_1374_;
}
}
else
{
uint32_t v___x_1375_; 
v___x_1375_ = 256;
return v___x_1375_;
}
v___jp_1333_:
{
uint64_t v___x_1334_; uint8_t v___x_1335_; 
v___x_1334_ = 0ULL;
v___x_1335_ = lean_uint64_dec_lt(v___x_1334_, v_maxJitTtlSecs_1332_);
if (v___x_1335_ == 0)
{
uint32_t v___x_1336_; 
v___x_1336_ = 0;
return v___x_1336_;
}
else
{
uint64_t v___x_1337_; uint8_t v___x_1338_; 
v___x_1337_ = 14400ULL;
v___x_1338_ = lean_uint64_dec_le(v_maxJitTtlSecs_1332_, v___x_1337_);
if (v___x_1338_ == 0)
{
uint32_t v___x_1339_; 
v___x_1339_ = 0;
return v___x_1339_;
}
else
{
uint8_t v___x_1340_; 
v___x_1340_ = lean_uint64_dec_le(v_grantIssuedAt_1330_, v_nowEpoch_1329_);
if (v___x_1340_ == 0)
{
uint32_t v___x_1341_; 
v___x_1341_ = 0;
return v___x_1341_;
}
else
{
uint8_t v___x_1342_; 
v___x_1342_ = lean_uint64_dec_lt(v_grantIssuedAt_1330_, v_grantExpiresAt_1331_);
if (v___x_1342_ == 0)
{
uint32_t v___x_1343_; 
v___x_1343_ = 0;
return v___x_1343_;
}
else
{
uint64_t v___x_1344_; uint8_t v___x_1345_; 
v___x_1344_ = lean_uint64_sub(v_grantExpiresAt_1331_, v_grantIssuedAt_1330_);
v___x_1345_ = lean_uint64_dec_le(v___x_1344_, v_maxJitTtlSecs_1332_);
if (v___x_1345_ == 0)
{
uint32_t v___x_1346_; 
v___x_1346_ = 0;
return v___x_1346_;
}
else
{
uint32_t v___x_1347_; 
v___x_1347_ = 1;
return v___x_1347_;
}
}
}
}
}
}
v___jp_1348_:
{
uint8_t v___x_1349_; uint8_t v___x_1350_; 
v___x_1349_ = 3;
v___x_1350_ = lean_uint8_dec_eq(v_dstClass_1328_, v___x_1349_);
if (v___x_1350_ == 0)
{
uint32_t v___x_1351_; 
v___x_1351_ = 0;
return v___x_1351_;
}
else
{
goto v___jp_1333_;
}
}
v___jp_1352_:
{
uint8_t v___x_1353_; uint8_t v___x_1354_; 
v___x_1353_ = 0;
v___x_1354_ = lean_uint8_dec_eq(v_srcClass_1327_, v___x_1353_);
if (v___x_1354_ == 0)
{
uint8_t v___x_1355_; uint8_t v___x_1356_; 
v___x_1355_ = 1;
v___x_1356_ = lean_uint8_dec_eq(v_srcClass_1327_, v___x_1355_);
if (v___x_1356_ == 0)
{
uint32_t v___x_1357_; 
v___x_1357_ = 0;
return v___x_1357_;
}
else
{
goto v___jp_1348_;
}
}
else
{
goto v___jp_1348_;
}
}
}
}
