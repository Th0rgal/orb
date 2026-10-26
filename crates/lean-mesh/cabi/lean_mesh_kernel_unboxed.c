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

LEAN_EXPORT uint32_t leanmesh_eval_route_step(uint32_t v_srcId_388_, uint32_t v_dstId_389_, uint8_t v_srcClass_390_, uint8_t v_dstClass_391_, uint8_t v_srcRevoked_392_, uint8_t v_dstRevoked_393_, uint8_t v_ruleMatched_394_, uint8_t v_proto_395_, uint32_t v_dstPort_396_, uint32_t v_rulePortMin_397_, uint32_t v_rulePortMax_398_, uint8_t v_jitBiometricGrant_399_, uint8_t v_bunkerState_400_, uint64_t v_nowEpoch_401_, uint64_t v_srcExpiresAt_402_, uint64_t v_dstExpiresAt_403_, uint64_t v_jitExpiresAt_404_){
{
uint8_t v___y_417_; uint8_t v___y_421_; uint8_t v___y_429_; uint8_t v___y_430_; uint8_t v___y_432_; uint8_t v___y_433_; uint8_t v___y_450_; uint8_t v___y_451_; uint8_t v___y_459_; uint8_t v___y_484_; uint8_t v___y_485_; uint8_t v___y_491_; uint8_t v___y_492_; uint8_t v___y_493_; uint8_t v___y_497_; uint8_t v___y_498_; uint8_t v___y_499_; uint8_t v___y_509_; uint8_t v___y_510_; uint8_t v___y_511_; uint8_t v___y_512_; uint8_t v___y_518_; uint8_t v___y_519_; uint8_t v___y_520_; uint8_t v___y_528_; uint32_t v___x_534_; uint8_t v___x_535_; 
v___x_534_ = 3088;
v___x_535_ = lean_uint32_dec_eq(v_dstPort_396_, v___x_534_);
if (v___x_535_ == 0)
{
uint8_t v___x_536_; 
v___x_536_ = lean_uint32_dec_le(v_rulePortMin_397_, v___x_534_);
if (v___x_536_ == 0)
{
v___y_528_ = v___x_536_;
goto v___jp_527_;
}
else
{
uint8_t v___x_537_; 
v___x_537_ = lean_uint32_dec_le(v___x_534_, v_rulePortMax_398_);
v___y_528_ = v___x_537_;
goto v___jp_527_;
}
}
else
{
v___y_528_ = v___x_535_;
goto v___jp_527_;
}
v___jp_405_:
{
uint8_t v___x_406_; uint8_t v___x_407_; 
v___x_406_ = 2;
v___x_407_ = lean_uint8_dec_eq(v_bunkerState_400_, v___x_406_);
if (v___x_407_ == 0)
{
uint32_t v___x_408_; 
v___x_408_ = 1;
return v___x_408_;
}
else
{
uint32_t v___x_409_; 
v___x_409_ = 257;
return v___x_409_;
}
}
v___jp_410_:
{
uint8_t v___x_411_; uint8_t v___x_412_; 
v___x_411_ = 3;
v___x_412_ = lean_uint8_dec_eq(v_dstClass_391_, v___x_411_);
if (v___x_412_ == 0)
{
goto v___jp_405_;
}
else
{
uint8_t v___x_413_; uint8_t v___x_414_; 
v___x_413_ = 1;
v___x_414_ = lean_uint8_dec_le(v_srcClass_390_, v___x_413_);
if (v___x_414_ == 0)
{
goto v___jp_405_;
}
else
{
uint32_t v___x_415_; 
v___x_415_ = 257;
return v___x_415_;
}
}
}
v___jp_416_:
{
if (v___y_417_ == 0)
{
uint32_t v___x_418_; 
v___x_418_ = 0;
return v___x_418_;
}
else
{
uint32_t v___x_419_; 
v___x_419_ = 65536;
return v___x_419_;
}
}
v___jp_420_:
{
if (v___y_421_ == 0)
{
uint8_t v___x_422_; uint8_t v___x_423_; 
v___x_422_ = 5;
v___x_423_ = lean_uint8_dec_eq(v_dstClass_391_, v___x_422_);
if (v___x_423_ == 0)
{
goto v___jp_410_;
}
else
{
uint8_t v___x_424_; uint8_t v___x_425_; 
v___x_424_ = 2;
v___x_425_ = lean_uint8_dec_eq(v_srcClass_390_, v___x_424_);
if (v___x_425_ == 0)
{
goto v___jp_410_;
}
else
{
uint32_t v___x_426_; 
v___x_426_ = 257;
return v___x_426_;
}
}
}
else
{
uint32_t v___x_427_; 
v___x_427_ = 65536;
return v___x_427_;
}
}
v___jp_428_:
{
if (v___y_430_ == 0)
{
v___y_417_ = v___y_429_;
goto v___jp_416_;
}
else
{
v___y_421_ = v___y_429_;
goto v___jp_420_;
}
}
v___jp_431_:
{
if (v___y_433_ == 0)
{
v___y_417_ = v___y_432_;
goto v___jp_416_;
}
else
{
uint8_t v___x_434_; uint8_t v___x_435_; 
v___x_434_ = 0;
v___x_435_ = lean_uint8_dec_eq(v_bunkerState_400_, v___x_434_);
if (v___x_435_ == 0)
{
uint8_t v___x_436_; uint8_t v___x_437_; 
v___x_436_ = 1;
v___x_437_ = lean_uint8_dec_eq(v_bunkerState_400_, v___x_436_);
if (v___x_437_ == 0)
{
uint8_t v___x_438_; uint8_t v___x_439_; 
v___x_438_ = 2;
v___x_439_ = lean_uint8_dec_eq(v_bunkerState_400_, v___x_438_);
if (v___x_439_ == 0)
{
v___y_417_ = v___y_432_;
goto v___jp_416_;
}
else
{
uint8_t v___x_440_; uint8_t v___x_441_; 
v___x_440_ = 6;
v___x_441_ = lean_uint8_dec_eq(v_srcClass_390_, v___x_440_);
if (v___x_441_ == 0)
{
v___y_417_ = v___y_432_;
goto v___jp_416_;
}
else
{
uint8_t v___x_442_; 
v___x_442_ = lean_uint8_dec_eq(v_proto_395_, v___x_440_);
if (v___x_442_ == 0)
{
v___y_417_ = v___y_432_;
goto v___jp_416_;
}
else
{
uint32_t v___x_443_; uint8_t v___x_444_; 
v___x_443_ = 22;
v___x_444_ = lean_uint32_dec_eq(v_dstPort_396_, v___x_443_);
if (v___x_444_ == 0)
{
v___y_417_ = v___y_432_;
goto v___jp_416_;
}
else
{
uint8_t v___x_445_; 
v___x_445_ = lean_uint32_dec_eq(v_rulePortMin_397_, v___x_443_);
if (v___x_445_ == 0)
{
v___y_417_ = v___y_432_;
goto v___jp_416_;
}
else
{
uint8_t v___x_446_; 
v___x_446_ = lean_uint32_dec_eq(v_rulePortMax_398_, v___x_443_);
v___y_429_ = v___y_432_;
v___y_430_ = v___x_446_;
goto v___jp_428_;
}
}
}
}
}
}
else
{
uint8_t v___x_447_; uint8_t v___x_448_; 
v___x_447_ = 2;
v___x_448_ = lean_uint8_dec_le(v___x_447_, v_srcClass_390_);
v___y_429_ = v___y_432_;
v___y_430_ = v___x_448_;
goto v___jp_428_;
}
}
else
{
v___y_421_ = v___y_432_;
goto v___jp_420_;
}
}
}
v___jp_449_:
{
uint32_t v___x_452_; uint8_t v___x_453_; 
v___x_452_ = 1;
v___x_453_ = lean_uint32_dec_le(v___x_452_, v_rulePortMin_397_);
if (v___x_453_ == 0)
{
v___y_432_ = v___y_450_;
v___y_433_ = v___y_451_;
goto v___jp_431_;
}
else
{
uint8_t v___x_454_; 
v___x_454_ = lean_uint32_dec_le(v_rulePortMin_397_, v_dstPort_396_);
if (v___x_454_ == 0)
{
v___y_432_ = v___y_450_;
v___y_433_ = v___y_451_;
goto v___jp_431_;
}
else
{
uint8_t v___x_455_; 
v___x_455_ = lean_uint32_dec_le(v_dstPort_396_, v_rulePortMax_398_);
if (v___x_455_ == 0)
{
v___y_432_ = v___y_450_;
v___y_433_ = v___y_451_;
goto v___jp_431_;
}
else
{
uint32_t v___x_456_; uint8_t v___x_457_; 
v___x_456_ = 65535;
v___x_457_ = lean_uint32_dec_le(v_rulePortMax_398_, v___x_456_);
v___y_432_ = v___y_450_;
v___y_433_ = v___x_457_;
goto v___jp_431_;
}
}
}
}
v___jp_458_:
{
uint32_t v___x_460_; uint8_t v___x_461_; 
v___x_460_ = 0;
v___x_461_ = lean_uint32_dec_eq(v_srcId_388_, v___x_460_);
if (v___x_461_ == 0)
{
uint8_t v___x_462_; 
v___x_462_ = lean_uint32_dec_eq(v_dstId_389_, v___x_460_);
if (v___x_462_ == 0)
{
uint8_t v___x_463_; 
v___x_463_ = lean_uint32_dec_eq(v_srcId_388_, v_dstId_389_);
if (v___x_463_ == 0)
{
uint8_t v___x_464_; uint8_t v___x_465_; 
v___x_464_ = 6;
v___x_465_ = lean_uint8_dec_le(v_srcClass_390_, v___x_464_);
if (v___x_465_ == 0)
{
v___y_417_ = v___y_459_;
goto v___jp_416_;
}
else
{
uint8_t v___x_466_; 
v___x_466_ = lean_uint8_dec_le(v_dstClass_391_, v___x_464_);
if (v___x_466_ == 0)
{
v___y_417_ = v___y_459_;
goto v___jp_416_;
}
else
{
uint8_t v___x_467_; uint8_t v___x_468_; 
v___x_467_ = 3;
v___x_468_ = lean_uint8_dec_le(v_bunkerState_400_, v___x_467_);
if (v___x_468_ == 0)
{
v___y_417_ = v___y_459_;
goto v___jp_416_;
}
else
{
uint8_t v___x_469_; uint8_t v___x_470_; 
v___x_469_ = 0;
v___x_470_ = lean_uint8_dec_eq(v_srcRevoked_392_, v___x_469_);
if (v___x_470_ == 0)
{
v___y_417_ = v___y_459_;
goto v___jp_416_;
}
else
{
uint8_t v___x_471_; 
v___x_471_ = lean_uint8_dec_eq(v_dstRevoked_393_, v___x_469_);
if (v___x_471_ == 0)
{
v___y_417_ = v___y_459_;
goto v___jp_416_;
}
else
{
uint8_t v___x_472_; uint8_t v___x_473_; 
v___x_472_ = 1;
v___x_473_ = lean_uint8_dec_eq(v_ruleMatched_394_, v___x_472_);
if (v___x_473_ == 0)
{
v___y_417_ = v___y_459_;
goto v___jp_416_;
}
else
{
uint8_t v___x_474_; 
v___x_474_ = lean_uint64_dec_lt(v_nowEpoch_401_, v_srcExpiresAt_402_);
if (v___x_474_ == 0)
{
v___y_417_ = v___y_459_;
goto v___jp_416_;
}
else
{
uint8_t v___x_475_; 
v___x_475_ = lean_uint64_dec_lt(v_nowEpoch_401_, v_dstExpiresAt_403_);
if (v___x_475_ == 0)
{
v___y_417_ = v___y_459_;
goto v___jp_416_;
}
else
{
uint8_t v___x_476_; 
v___x_476_ = lean_uint8_dec_eq(v_proto_395_, v___x_472_);
if (v___x_476_ == 0)
{
uint8_t v___x_477_; 
v___x_477_ = lean_uint8_dec_eq(v_proto_395_, v___x_464_);
if (v___x_477_ == 0)
{
uint8_t v___x_478_; uint8_t v___x_479_; 
v___x_478_ = 17;
v___x_479_ = lean_uint8_dec_eq(v_proto_395_, v___x_478_);
if (v___x_479_ == 0)
{
v___y_417_ = v___y_459_;
goto v___jp_416_;
}
else
{
v___y_450_ = v___y_459_;
v___y_451_ = v___x_476_;
goto v___jp_449_;
}
}
else
{
v___y_450_ = v___y_459_;
v___y_451_ = v___x_476_;
goto v___jp_449_;
}
}
else
{
uint8_t v___x_480_; 
v___x_480_ = lean_uint32_dec_eq(v_dstPort_396_, v___x_460_);
if (v___x_480_ == 0)
{
v___y_417_ = v___y_459_;
goto v___jp_416_;
}
else
{
uint8_t v___x_481_; 
v___x_481_ = lean_uint32_dec_eq(v_rulePortMin_397_, v___x_460_);
if (v___x_481_ == 0)
{
v___y_417_ = v___y_459_;
goto v___jp_416_;
}
else
{
uint8_t v___x_482_; 
v___x_482_ = lean_uint32_dec_eq(v_rulePortMax_398_, v___x_460_);
v___y_432_ = v___y_459_;
v___y_433_ = v___x_482_;
goto v___jp_431_;
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
v___y_417_ = v___y_459_;
goto v___jp_416_;
}
}
else
{
v___y_417_ = v___y_459_;
goto v___jp_416_;
}
}
else
{
v___y_417_ = v___y_459_;
goto v___jp_416_;
}
}
v___jp_483_:
{
uint8_t v___x_486_; uint8_t v___x_487_; 
v___x_486_ = 3;
v___x_487_ = lean_uint8_dec_eq(v_dstClass_391_, v___x_486_);
if (v___x_487_ == 0)
{
v___y_459_ = v___x_487_;
goto v___jp_458_;
}
else
{
uint8_t v___x_488_; 
v___x_488_ = lean_uint8_dec_le(v_srcClass_390_, v___y_484_);
if (v___x_488_ == 0)
{
v___y_459_ = v___x_488_;
goto v___jp_458_;
}
else
{
if (v___y_485_ == 0)
{
v___y_459_ = v___x_488_;
goto v___jp_458_;
}
else
{
uint8_t v___x_489_; 
v___x_489_ = 0;
v___y_459_ = v___x_489_;
goto v___jp_458_;
}
}
}
}
v___jp_490_:
{
uint8_t v___x_494_; uint8_t v___x_495_; 
v___x_494_ = 4;
v___x_495_ = lean_uint8_dec_eq(v_srcClass_390_, v___x_494_);
if (v___x_495_ == 0)
{
v___y_484_ = v___y_491_;
v___y_485_ = v___y_492_;
goto v___jp_483_;
}
else
{
if (v___y_493_ == 0)
{
v___y_459_ = v___x_495_;
goto v___jp_458_;
}
else
{
v___y_484_ = v___y_491_;
v___y_485_ = v___y_492_;
goto v___jp_483_;
}
}
}
v___jp_496_:
{
uint8_t v___x_500_; uint8_t v___x_501_; 
v___x_500_ = 5;
v___x_501_ = lean_uint8_dec_eq(v_dstClass_391_, v___x_500_);
if (v___x_501_ == 0)
{
v___y_484_ = v___y_497_;
v___y_485_ = v___y_498_;
goto v___jp_483_;
}
else
{
uint8_t v___x_502_; 
v___x_502_ = lean_uint8_dec_le(v_srcClass_390_, v___y_497_);
if (v___x_502_ == 0)
{
uint8_t v___x_503_; uint8_t v___x_504_; 
v___x_503_ = 3;
v___x_504_ = lean_uint8_dec_eq(v_srcClass_390_, v___x_503_);
if (v___x_504_ == 0)
{
uint8_t v___x_505_; 
v___x_505_ = lean_uint8_dec_eq(v_srcClass_390_, v___x_500_);
if (v___x_505_ == 0)
{
uint8_t v___x_506_; uint8_t v___x_507_; 
v___x_506_ = 2;
v___x_507_ = lean_uint8_dec_eq(v_srcClass_390_, v___x_506_);
if (v___x_507_ == 0)
{
v___y_491_ = v___y_497_;
v___y_492_ = v___y_498_;
v___y_493_ = v___y_499_;
goto v___jp_490_;
}
else
{
if (v___y_498_ == 0)
{
v___y_459_ = v___x_507_;
goto v___jp_458_;
}
else
{
v___y_491_ = v___y_497_;
v___y_492_ = v___y_498_;
v___y_493_ = v___y_499_;
goto v___jp_490_;
}
}
}
else
{
v___y_459_ = v___x_505_;
goto v___jp_458_;
}
}
else
{
v___y_459_ = v___x_504_;
goto v___jp_458_;
}
}
else
{
v___y_459_ = v___x_502_;
goto v___jp_458_;
}
}
}
v___jp_508_:
{
if (v___y_509_ == 0)
{
v___y_497_ = v___y_510_;
v___y_498_ = v___y_511_;
v___y_499_ = v___y_512_;
goto v___jp_496_;
}
else
{
uint8_t v___x_513_; uint8_t v___x_514_; 
v___x_513_ = 4;
v___x_514_ = lean_uint8_dec_eq(v_srcClass_390_, v___x_513_);
if (v___x_514_ == 0)
{
uint8_t v___x_515_; uint8_t v___x_516_; 
v___x_515_ = 6;
v___x_516_ = lean_uint8_dec_eq(v_srcClass_390_, v___x_515_);
if (v___x_516_ == 0)
{
v___y_459_ = v___y_509_;
goto v___jp_458_;
}
else
{
v___y_497_ = v___y_510_;
v___y_498_ = v___y_511_;
v___y_499_ = v___y_512_;
goto v___jp_496_;
}
}
else
{
v___y_497_ = v___y_510_;
v___y_498_ = v___y_511_;
v___y_499_ = v___y_512_;
goto v___jp_496_;
}
}
}
v___jp_517_:
{
uint32_t v___x_521_; uint8_t v___x_522_; 
v___x_521_ = 8888;
v___x_522_ = lean_uint32_dec_le(v___x_521_, v_rulePortMin_397_);
if (v___x_522_ == 0)
{
v___y_509_ = v___y_518_;
v___y_510_ = v___y_519_;
v___y_511_ = v___y_520_;
v___y_512_ = v___x_522_;
goto v___jp_508_;
}
else
{
uint32_t v___x_523_; uint8_t v___x_524_; 
v___x_523_ = 8890;
v___x_524_ = lean_uint32_dec_le(v_rulePortMax_398_, v___x_523_);
if (v___x_524_ == 0)
{
v___y_509_ = v___y_518_;
v___y_510_ = v___y_519_;
v___y_511_ = v___y_520_;
v___y_512_ = v___x_524_;
goto v___jp_508_;
}
else
{
uint8_t v___x_525_; 
v___x_525_ = lean_uint32_dec_le(v___x_521_, v_dstPort_396_);
if (v___x_525_ == 0)
{
v___y_509_ = v___y_518_;
v___y_510_ = v___y_519_;
v___y_511_ = v___y_520_;
v___y_512_ = v___x_525_;
goto v___jp_508_;
}
else
{
uint8_t v___x_526_; 
v___x_526_ = lean_uint32_dec_le(v_dstPort_396_, v___x_523_);
v___y_509_ = v___y_518_;
v___y_510_ = v___y_519_;
v___y_511_ = v___y_520_;
v___y_512_ = v___x_526_;
goto v___jp_508_;
}
}
}
}
v___jp_527_:
{
uint8_t v___x_529_; uint8_t v___x_530_; 
v___x_529_ = 1;
v___x_530_ = lean_uint8_dec_eq(v_jitBiometricGrant_399_, v___x_529_);
if (v___x_530_ == 0)
{
v___y_518_ = v___y_528_;
v___y_519_ = v___x_529_;
v___y_520_ = v___x_530_;
goto v___jp_517_;
}
else
{
uint8_t v___x_531_; uint8_t v___x_532_; 
v___x_531_ = 0;
v___x_532_ = lean_uint8_dec_eq(v_bunkerState_400_, v___x_531_);
if (v___x_532_ == 0)
{
v___y_518_ = v___y_528_;
v___y_519_ = v___x_529_;
v___y_520_ = v___x_532_;
goto v___jp_517_;
}
else
{
uint8_t v___x_533_; 
v___x_533_ = lean_uint64_dec_lt(v_nowEpoch_401_, v_jitExpiresAt_404_);
v___y_518_ = v___y_528_;
v___y_519_ = v___x_529_;
v___y_520_ = v___x_533_;
goto v___jp_517_;
}
}
}
}
}

LEAN_EXPORT uint8_t leanmesh_replay_window_step(uint64_t v_lastMaxSeq_574_, uint64_t v_bitmap_575_, uint64_t v_pktSeq_576_){
{
uint64_t v___x_577_; uint8_t v___x_578_; 
v___x_577_ = 0ULL;
v___x_578_ = lean_uint64_dec_eq(v_pktSeq_576_, v___x_577_);
if (v___x_578_ == 0)
{
uint64_t v___x_579_; uint8_t v___x_580_; 
v___x_579_ = 18446744073709551615ULL;
v___x_580_ = lean_uint64_dec_eq(v_pktSeq_576_, v___x_579_);
if (v___x_580_ == 0)
{
uint8_t v___x_581_; 
v___x_581_ = lean_uint64_dec_lt(v_lastMaxSeq_574_, v_pktSeq_576_);
if (v___x_581_ == 0)
{
uint64_t v_age_582_; uint64_t v___x_583_; uint8_t v___x_584_; 
v_age_582_ = lean_uint64_sub(v_lastMaxSeq_574_, v_pktSeq_576_);
v___x_583_ = 64ULL;
v___x_584_ = lean_uint64_dec_le(v___x_583_, v_age_582_);
if (v___x_584_ == 0)
{
uint64_t v___x_585_; uint64_t v_mask_586_; uint64_t v___x_587_; uint8_t v___x_588_; 
v___x_585_ = 1ULL;
v_mask_586_ = lean_uint64_shift_left(v___x_585_, v_age_582_);
v___x_587_ = lean_uint64_land(v_bitmap_575_, v_mask_586_);
v___x_588_ = lean_uint64_dec_eq(v___x_587_, v___x_577_);
if (v___x_588_ == 0)
{
uint8_t v___x_589_; 
v___x_589_ = 0;
return v___x_589_;
}
else
{
uint8_t v___x_590_; 
v___x_590_ = 1;
return v___x_590_;
}
}
else
{
uint8_t v___x_591_; 
v___x_591_ = 0;
return v___x_591_;
}
}
else
{
uint8_t v___x_592_; 
v___x_592_ = 1;
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
}

LEAN_EXPORT uint64_t leanmesh_replay_window_next_max(uint64_t v_lastMaxSeq_603_, uint64_t v_bitmap_604_, uint64_t v_pktSeq_605_){
{
uint8_t v___y_607_; uint64_t v___x_611_; uint8_t v___x_612_; 
v___x_611_ = 0ULL;
v___x_612_ = lean_uint64_dec_eq(v_pktSeq_605_, v___x_611_);
if (v___x_612_ == 0)
{
uint64_t v___x_613_; uint8_t v___x_614_; 
v___x_613_ = 18446744073709551615ULL;
v___x_614_ = lean_uint64_dec_eq(v_pktSeq_605_, v___x_613_);
if (v___x_614_ == 0)
{
uint8_t v___x_615_; 
v___x_615_ = lean_uint64_dec_lt(v_lastMaxSeq_603_, v_pktSeq_605_);
if (v___x_615_ == 0)
{
uint64_t v_age_616_; uint64_t v___x_617_; uint8_t v___x_618_; 
v_age_616_ = lean_uint64_sub(v_lastMaxSeq_603_, v_pktSeq_605_);
v___x_617_ = 64ULL;
v___x_618_ = lean_uint64_dec_le(v___x_617_, v_age_616_);
if (v___x_618_ == 0)
{
uint64_t v___x_619_; uint64_t v_mask_620_; uint64_t v___x_621_; uint8_t v___x_622_; 
v___x_619_ = 1ULL;
v_mask_620_ = lean_uint64_shift_left(v___x_619_, v_age_616_);
v___x_621_ = lean_uint64_land(v_bitmap_604_, v_mask_620_);
v___x_622_ = lean_uint64_dec_eq(v___x_621_, v___x_611_);
if (v___x_622_ == 0)
{
uint8_t v___x_623_; 
v___x_623_ = 0;
v___y_607_ = v___x_623_;
goto v___jp_606_;
}
else
{
uint8_t v___x_624_; 
v___x_624_ = 1;
v___y_607_ = v___x_624_;
goto v___jp_606_;
}
}
else
{
uint8_t v___x_625_; 
v___x_625_ = 0;
v___y_607_ = v___x_625_;
goto v___jp_606_;
}
}
else
{
uint8_t v___x_626_; 
v___x_626_ = 1;
v___y_607_ = v___x_626_;
goto v___jp_606_;
}
}
else
{
uint8_t v___x_627_; 
v___x_627_ = 0;
v___y_607_ = v___x_627_;
goto v___jp_606_;
}
}
else
{
uint8_t v___x_628_; 
v___x_628_ = 0;
v___y_607_ = v___x_628_;
goto v___jp_606_;
}
v___jp_606_:
{
uint8_t v___x_608_; uint8_t v___x_609_; 
v___x_608_ = 1;
v___x_609_ = lean_uint8_dec_eq(v___y_607_, v___x_608_);
if (v___x_609_ == 0)
{
return v_lastMaxSeq_603_;
}
else
{
uint8_t v___x_610_; 
v___x_610_ = lean_uint64_dec_lt(v_lastMaxSeq_603_, v_pktSeq_605_);
if (v___x_610_ == 0)
{
return v_lastMaxSeq_603_;
}
else
{
return v_pktSeq_605_;
}
}
}
}
}

LEAN_EXPORT uint64_t leanmesh_replay_window_next_bitmap(uint64_t v_lastMaxSeq_637_, uint64_t v_bitmap_638_, uint64_t v_pktSeq_639_){
{
uint8_t v___y_641_; uint64_t v___x_658_; uint8_t v___x_659_; 
v___x_658_ = 0ULL;
v___x_659_ = lean_uint64_dec_eq(v_pktSeq_639_, v___x_658_);
if (v___x_659_ == 0)
{
uint64_t v___x_660_; uint8_t v___x_661_; 
v___x_660_ = 18446744073709551615ULL;
v___x_661_ = lean_uint64_dec_eq(v_pktSeq_639_, v___x_660_);
if (v___x_661_ == 0)
{
uint8_t v___x_662_; 
v___x_662_ = lean_uint64_dec_lt(v_lastMaxSeq_637_, v_pktSeq_639_);
if (v___x_662_ == 0)
{
uint64_t v_age_663_; uint64_t v___x_664_; uint8_t v___x_665_; 
v_age_663_ = lean_uint64_sub(v_lastMaxSeq_637_, v_pktSeq_639_);
v___x_664_ = 64ULL;
v___x_665_ = lean_uint64_dec_le(v___x_664_, v_age_663_);
if (v___x_665_ == 0)
{
uint64_t v___x_666_; uint64_t v_mask_667_; uint64_t v___x_668_; uint8_t v___x_669_; 
v___x_666_ = 1ULL;
v_mask_667_ = lean_uint64_shift_left(v___x_666_, v_age_663_);
v___x_668_ = lean_uint64_land(v_bitmap_638_, v_mask_667_);
v___x_669_ = lean_uint64_dec_eq(v___x_668_, v___x_658_);
if (v___x_669_ == 0)
{
uint8_t v___x_670_; 
v___x_670_ = 0;
v___y_641_ = v___x_670_;
goto v___jp_640_;
}
else
{
uint8_t v___x_671_; 
v___x_671_ = 1;
v___y_641_ = v___x_671_;
goto v___jp_640_;
}
}
else
{
uint8_t v___x_672_; 
v___x_672_ = 0;
v___y_641_ = v___x_672_;
goto v___jp_640_;
}
}
else
{
uint8_t v___x_673_; 
v___x_673_ = 1;
v___y_641_ = v___x_673_;
goto v___jp_640_;
}
}
else
{
uint8_t v___x_674_; 
v___x_674_ = 0;
v___y_641_ = v___x_674_;
goto v___jp_640_;
}
}
else
{
uint8_t v___x_675_; 
v___x_675_ = 0;
v___y_641_ = v___x_675_;
goto v___jp_640_;
}
v___jp_640_:
{
uint8_t v___x_642_; uint8_t v___x_643_; 
v___x_642_ = 1;
v___x_643_ = lean_uint8_dec_eq(v___y_641_, v___x_642_);
if (v___x_643_ == 0)
{
return v_bitmap_638_;
}
else
{
uint8_t v___x_644_; 
v___x_644_ = lean_uint64_dec_lt(v_lastMaxSeq_637_, v_pktSeq_639_);
if (v___x_644_ == 0)
{
uint64_t v_age_645_; uint64_t v___x_646_; uint8_t v___x_647_; 
v_age_645_ = lean_uint64_sub(v_lastMaxSeq_637_, v_pktSeq_639_);
v___x_646_ = 64ULL;
v___x_647_ = lean_uint64_dec_le(v___x_646_, v_age_645_);
if (v___x_647_ == 0)
{
uint64_t v___x_648_; uint64_t v___x_649_; uint64_t v___x_650_; 
v___x_648_ = 1ULL;
v___x_649_ = lean_uint64_shift_left(v___x_648_, v_age_645_);
v___x_650_ = lean_uint64_lor(v_bitmap_638_, v___x_649_);
return v___x_650_;
}
else
{
return v_bitmap_638_;
}
}
else
{
uint64_t v_delta_651_; uint64_t v___x_652_; uint8_t v___x_653_; 
v_delta_651_ = lean_uint64_sub(v_pktSeq_639_, v_lastMaxSeq_637_);
v___x_652_ = 64ULL;
v___x_653_ = lean_uint64_dec_le(v___x_652_, v_delta_651_);
if (v___x_653_ == 0)
{
uint64_t v___x_654_; uint64_t v___x_655_; uint64_t v___x_656_; 
v___x_654_ = lean_uint64_shift_left(v_bitmap_638_, v_delta_651_);
v___x_655_ = 1ULL;
v___x_656_ = lean_uint64_lor(v___x_654_, v___x_655_);
return v___x_656_;
}
else
{
uint64_t v___x_657_; 
v___x_657_ = 1ULL;
return v___x_657_;
}
}
}
}
}
}

LEAN_EXPORT uint8_t leanmesh_endpoint_roam_step(uint8_t v_aeadAuthOk_748_, uint8_t v_peerPinnedStatic_749_, uint8_t v_candidateIpClass_750_, uint8_t v_allowPrivateRoam_751_, uint8_t v_bunkerState_752_, uint32_t v_candidatePort_753_, uint64_t v_lastRoamSeq_754_, uint64_t v_pktSeq_755_, uint64_t v_lastRoamEpoch_756_, uint64_t v_nowEpoch_757_, uint64_t v_minRoamIntervalSecs_758_){
{
uint8_t v___y_760_; uint8_t v___x_781_; uint8_t v___x_782_; 
v___x_781_ = 5;
v___x_782_ = lean_uint8_dec_eq(v_candidateIpClass_750_, v___x_781_);
if (v___x_782_ == 0)
{
uint8_t v___x_783_; uint8_t v___x_784_; 
v___x_783_ = 1;
v___x_784_ = lean_uint8_dec_eq(v_allowPrivateRoam_751_, v___x_783_);
if (v___x_784_ == 0)
{
v___y_760_ = v___x_784_;
goto v___jp_759_;
}
else
{
uint8_t v___x_785_; uint8_t v___x_786_; 
v___x_785_ = 3;
v___x_786_ = lean_uint8_dec_eq(v_candidateIpClass_750_, v___x_785_);
if (v___x_786_ == 0)
{
uint8_t v___x_787_; uint8_t v___x_788_; 
v___x_787_ = 4;
v___x_788_ = lean_uint8_dec_eq(v_candidateIpClass_750_, v___x_787_);
v___y_760_ = v___x_788_;
goto v___jp_759_;
}
else
{
v___y_760_ = v___x_786_;
goto v___jp_759_;
}
}
}
else
{
v___y_760_ = v___x_782_;
goto v___jp_759_;
}
v___jp_759_:
{
uint8_t v___x_761_; uint8_t v___x_762_; 
v___x_761_ = 1;
v___x_762_ = lean_uint8_dec_eq(v_aeadAuthOk_748_, v___x_761_);
if (v___x_762_ == 0)
{
uint8_t v___x_763_; 
v___x_763_ = 0;
return v___x_763_;
}
else
{
uint8_t v___x_764_; uint8_t v___x_765_; 
v___x_764_ = 0;
v___x_765_ = lean_uint8_dec_eq(v_peerPinnedStatic_749_, v___x_764_);
if (v___x_765_ == 0)
{
return v___x_764_;
}
else
{
uint8_t v___x_766_; 
v___x_766_ = lean_uint8_dec_eq(v_bunkerState_752_, v___x_764_);
if (v___x_766_ == 0)
{
return v___x_764_;
}
else
{
uint32_t v___x_767_; uint8_t v___x_768_; 
v___x_767_ = 1;
v___x_768_ = lean_uint32_dec_le(v___x_767_, v_candidatePort_753_);
if (v___x_768_ == 0)
{
return v___x_764_;
}
else
{
uint32_t v___x_769_; uint8_t v___x_770_; 
v___x_769_ = 65535;
v___x_770_ = lean_uint32_dec_le(v_candidatePort_753_, v___x_769_);
if (v___x_770_ == 0)
{
return v___x_764_;
}
else
{
uint8_t v___x_771_; 
v___x_771_ = lean_uint64_dec_lt(v_lastRoamSeq_754_, v_pktSeq_755_);
if (v___x_771_ == 0)
{
return v___x_764_;
}
else
{
uint64_t v___x_772_; uint8_t v___x_773_; 
v___x_772_ = 18446744073709551615ULL;
v___x_773_ = lean_uint64_dec_lt(v_pktSeq_755_, v___x_772_);
if (v___x_773_ == 0)
{
return v___x_764_;
}
else
{
if (v___y_760_ == 0)
{
return v___x_764_;
}
else
{
uint64_t v___x_774_; uint8_t v___x_775_; 
v___x_774_ = 0ULL;
v___x_775_ = lean_uint64_dec_lt(v___x_774_, v_minRoamIntervalSecs_758_);
if (v___x_775_ == 0)
{
return v___x_764_;
}
else
{
uint64_t v___x_776_; uint8_t v___x_777_; 
v___x_776_ = 86400ULL;
v___x_777_ = lean_uint64_dec_le(v_minRoamIntervalSecs_758_, v___x_776_);
if (v___x_777_ == 0)
{
return v___x_764_;
}
else
{
uint8_t v___x_778_; 
v___x_778_ = lean_uint64_dec_le(v_lastRoamEpoch_756_, v_nowEpoch_757_);
if (v___x_778_ == 0)
{
return v___x_764_;
}
else
{
uint64_t v___x_779_; uint8_t v___x_780_; 
v___x_779_ = lean_uint64_sub(v_nowEpoch_757_, v_lastRoamEpoch_756_);
v___x_780_ = lean_uint64_dec_le(v_minRoamIntervalSecs_758_, v___x_779_);
if (v___x_780_ == 0)
{
return v___x_764_;
}
else
{
return v___x_761_;
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

LEAN_EXPORT uint8_t leanmesh_relay_select_step(uint8_t v_routeAllowed_832_, uint8_t v_lanReachable_833_, uint8_t v_wanReachable_834_, uint8_t v_relayHealthy_835_, uint32_t v_srcId_836_, uint32_t v_dstId_837_, uint32_t v_relayId_838_, uint32_t v_activeRelaySessions_839_, uint32_t v_maxRelaySessions_840_, uint64_t v_nowEpoch_841_, uint64_t v_directHandshakeAt_842_, uint64_t v_maxDirectStaleSecs_843_){
{
uint8_t v___y_849_; uint8_t v___y_853_; uint8_t v___y_857_; uint8_t v___y_858_; uint8_t v___y_861_; uint8_t v___y_862_; uint32_t v___y_863_; uint8_t v___y_864_; uint8_t v___y_868_; uint8_t v___y_869_; uint32_t v___y_870_; uint8_t v___y_871_; uint8_t v___y_874_; uint64_t v___x_887_; uint8_t v___x_888_; 
v___x_887_ = 0ULL;
v___x_888_ = lean_uint64_dec_lt(v___x_887_, v_directHandshakeAt_842_);
if (v___x_888_ == 0)
{
v___y_874_ = v___x_888_;
goto v___jp_873_;
}
else
{
uint8_t v___x_889_; 
v___x_889_ = lean_uint64_dec_lt(v___x_887_, v_maxDirectStaleSecs_843_);
if (v___x_889_ == 0)
{
v___y_874_ = v___x_889_;
goto v___jp_873_;
}
else
{
uint64_t v___x_890_; uint8_t v___x_891_; 
v___x_890_ = 86400ULL;
v___x_891_ = lean_uint64_dec_le(v_maxDirectStaleSecs_843_, v___x_890_);
if (v___x_891_ == 0)
{
v___y_874_ = v___x_891_;
goto v___jp_873_;
}
else
{
uint8_t v___x_892_; 
v___x_892_ = lean_uint64_dec_le(v_directHandshakeAt_842_, v_nowEpoch_841_);
if (v___x_892_ == 0)
{
v___y_874_ = v___x_892_;
goto v___jp_873_;
}
else
{
uint64_t v___x_893_; uint8_t v___x_894_; 
v___x_893_ = lean_uint64_sub(v_nowEpoch_841_, v_directHandshakeAt_842_);
v___x_894_ = lean_uint64_dec_le(v___x_893_, v_maxDirectStaleSecs_843_);
v___y_874_ = v___x_894_;
goto v___jp_873_;
}
}
}
}
v___jp_844_:
{
uint8_t v___x_845_; 
v___x_845_ = lean_uint32_dec_lt(v_activeRelaySessions_839_, v_maxRelaySessions_840_);
if (v___x_845_ == 0)
{
uint8_t v___x_846_; 
v___x_846_ = 0;
return v___x_846_;
}
else
{
uint8_t v___x_847_; 
v___x_847_ = 3;
return v___x_847_;
}
}
v___jp_848_:
{
uint8_t v___x_850_; 
v___x_850_ = lean_uint32_dec_eq(v_relayId_838_, v_dstId_837_);
if (v___x_850_ == 0)
{
goto v___jp_844_;
}
else
{
if (v___y_849_ == 0)
{
uint8_t v___x_851_; 
v___x_851_ = 0;
return v___x_851_;
}
else
{
goto v___jp_844_;
}
}
}
v___jp_852_:
{
uint8_t v___x_854_; 
v___x_854_ = lean_uint32_dec_eq(v_relayId_838_, v_srcId_836_);
if (v___x_854_ == 0)
{
v___y_849_ = v___y_853_;
goto v___jp_848_;
}
else
{
if (v___y_853_ == 0)
{
uint8_t v___x_855_; 
v___x_855_ = 0;
return v___x_855_;
}
else
{
v___y_849_ = v___y_853_;
goto v___jp_848_;
}
}
}
v___jp_856_:
{
if (v___y_858_ == 0)
{
uint8_t v___x_859_; 
v___x_859_ = 0;
return v___x_859_;
}
else
{
v___y_853_ = v___y_857_;
goto v___jp_852_;
}
}
v___jp_860_:
{
uint8_t v___x_865_; 
v___x_865_ = lean_uint8_dec_eq(v_relayHealthy_835_, v___y_862_);
if (v___x_865_ == 0)
{
v___y_857_ = v___y_864_;
v___y_858_ = v___y_861_;
goto v___jp_856_;
}
else
{
uint8_t v___x_866_; 
v___x_866_ = lean_uint32_dec_eq(v_relayId_838_, v___y_863_);
if (v___x_866_ == 0)
{
v___y_853_ = v___y_864_;
goto v___jp_852_;
}
else
{
v___y_857_ = v___y_864_;
v___y_858_ = v___y_864_;
goto v___jp_856_;
}
}
}
v___jp_867_:
{
uint8_t v___x_872_; 
v___x_872_ = lean_uint8_dec_eq(v_wanReachable_834_, v___y_869_);
if (v___x_872_ == 0)
{
v___y_861_ = v___y_868_;
v___y_862_ = v___y_869_;
v___y_863_ = v___y_870_;
v___y_864_ = v___y_868_;
goto v___jp_860_;
}
else
{
if (v___y_871_ == 0)
{
v___y_861_ = v___y_868_;
v___y_862_ = v___y_869_;
v___y_863_ = v___y_870_;
v___y_864_ = v___y_871_;
goto v___jp_860_;
}
else
{
return v___y_869_;
}
}
}
v___jp_873_:
{
uint8_t v___x_875_; uint8_t v___x_876_; 
v___x_875_ = 1;
v___x_876_ = lean_uint8_dec_eq(v_routeAllowed_832_, v___x_875_);
if (v___x_876_ == 0)
{
uint8_t v___x_877_; 
v___x_877_ = 0;
return v___x_877_;
}
else
{
uint32_t v___x_878_; uint8_t v___x_879_; 
v___x_878_ = 0;
v___x_879_ = lean_uint32_dec_eq(v_srcId_836_, v___x_878_);
if (v___x_879_ == 0)
{
uint8_t v___x_880_; 
v___x_880_ = lean_uint32_dec_eq(v_dstId_837_, v___x_878_);
if (v___x_880_ == 0)
{
uint8_t v___x_881_; 
v___x_881_ = lean_uint32_dec_eq(v_srcId_836_, v_dstId_837_);
if (v___x_881_ == 0)
{
uint8_t v___x_882_; 
v___x_882_ = lean_uint8_dec_eq(v_lanReachable_833_, v___x_875_);
if (v___x_882_ == 0)
{
v___y_868_ = v___x_881_;
v___y_869_ = v___x_875_;
v___y_870_ = v___x_878_;
v___y_871_ = v___y_874_;
goto v___jp_867_;
}
else
{
if (v___y_874_ == 0)
{
v___y_868_ = v___x_881_;
v___y_869_ = v___x_875_;
v___y_870_ = v___x_878_;
v___y_871_ = v___y_874_;
goto v___jp_867_;
}
else
{
uint8_t v___x_883_; 
v___x_883_ = 2;
return v___x_883_;
}
}
}
else
{
uint8_t v___x_884_; 
v___x_884_ = 0;
return v___x_884_;
}
}
else
{
uint8_t v___x_885_; 
v___x_885_ = 0;
return v___x_885_;
}
}
else
{
uint8_t v___x_886_; 
v___x_886_ = 0;
return v___x_886_;
}
}
}
}
}

LEAN_EXPORT uint32_t leanmesh_bunker_isolate_step(uint8_t v_currentState_1054_, uint8_t v_isSovereignNode_1055_, uint8_t v_canaryTripped_1056_, uint8_t v_authFailureBurst_1057_, uint8_t v_manualTrigger_1058_, uint8_t v_biometricUnbunker_1059_, uint8_t v_heartbeatValid_1060_, uint64_t v_nowEpoch_1061_, uint64_t v_lastHeartbeatAt_1062_, uint64_t v_deadManTimeoutSecs_1063_){
{
uint32_t v___y_1065_; uint32_t v___y_1069_; uint8_t v___y_1070_; uint8_t v___y_1071_; uint8_t v___y_1072_; uint32_t v___y_1073_; uint32_t v___y_1079_; uint8_t v___y_1080_; uint8_t v___y_1081_; uint32_t v___y_1082_; uint8_t v___y_1089_; uint8_t v___y_1096_; uint8_t v___y_1097_; uint8_t v___y_1100_; uint8_t v___y_1103_; uint8_t v___y_1104_; uint8_t v___y_1113_; uint8_t v___y_1114_; uint8_t v___y_1125_; uint8_t v___x_1129_; uint8_t v___x_1130_; 
v___x_1129_ = 0;
v___x_1130_ = lean_uint8_dec_eq(v_currentState_1054_, v___x_1129_);
if (v___x_1130_ == 0)
{
uint8_t v___x_1131_; uint8_t v___x_1132_; 
v___x_1131_ = 1;
v___x_1132_ = lean_uint8_dec_eq(v_currentState_1054_, v___x_1131_);
if (v___x_1132_ == 0)
{
uint8_t v___x_1133_; uint8_t v___x_1134_; 
v___x_1133_ = 2;
v___x_1134_ = lean_uint8_dec_eq(v_currentState_1054_, v___x_1133_);
if (v___x_1134_ == 0)
{
uint8_t v___x_1135_; 
v___x_1135_ = 3;
v___y_1125_ = v___x_1135_;
goto v___jp_1124_;
}
else
{
v___y_1125_ = v___x_1133_;
goto v___jp_1124_;
}
}
else
{
v___y_1125_ = v___x_1131_;
goto v___jp_1124_;
}
}
else
{
v___y_1125_ = v___x_1129_;
goto v___jp_1124_;
}
v___jp_1064_:
{
uint32_t v___x_1066_; uint32_t v___x_1067_; 
v___x_1066_ = 16777216;
v___x_1067_ = lean_uint32_lor(v___y_1065_, v___x_1066_);
return v___x_1067_;
}
v___jp_1068_:
{
uint32_t v___x_1074_; uint8_t v___x_1075_; uint8_t v___x_1076_; 
v___x_1074_ = lean_uint32_lor(v___y_1069_, v___y_1073_);
v___x_1075_ = 3;
v___x_1076_ = lean_uint8_dec_eq(v___y_1072_, v___x_1075_);
if (v___x_1076_ == 0)
{
uint8_t v___x_1077_; 
v___x_1077_ = lean_uint8_dec_eq(v_isSovereignNode_1055_, v___y_1070_);
if (v___x_1077_ == 0)
{
return v___x_1074_;
}
else
{
if (v___y_1071_ == 0)
{
return v___x_1074_;
}
else
{
v___y_1065_ = v___x_1074_;
goto v___jp_1064_;
}
}
}
else
{
v___y_1065_ = v___x_1074_;
goto v___jp_1064_;
}
}
v___jp_1078_:
{
uint32_t v___x_1083_; uint8_t v___x_1084_; uint8_t v___x_1085_; 
v___x_1083_ = lean_uint32_lor(v___y_1079_, v___y_1082_);
v___x_1084_ = 2;
v___x_1085_ = lean_uint8_dec_le(v___x_1084_, v___y_1081_);
if (v___x_1085_ == 0)
{
uint32_t v___x_1086_; 
v___x_1086_ = 0;
v___y_1069_ = v___x_1083_;
v___y_1070_ = v___y_1080_;
v___y_1071_ = v___x_1085_;
v___y_1072_ = v___y_1081_;
v___y_1073_ = v___x_1086_;
goto v___jp_1068_;
}
else
{
uint32_t v___x_1087_; 
v___x_1087_ = 65536;
v___y_1069_ = v___x_1083_;
v___y_1070_ = v___y_1080_;
v___y_1071_ = v___x_1085_;
v___y_1072_ = v___y_1081_;
v___y_1073_ = v___x_1087_;
goto v___jp_1068_;
}
}
v___jp_1088_:
{
uint32_t v___x_1090_; uint8_t v___x_1091_; uint8_t v___x_1092_; 
v___x_1090_ = lean_uint8_to_uint32(v___y_1089_);
v___x_1091_ = 1;
v___x_1092_ = lean_uint8_dec_le(v___x_1091_, v___y_1089_);
if (v___x_1092_ == 0)
{
uint32_t v___x_1093_; 
v___x_1093_ = 0;
v___y_1079_ = v___x_1090_;
v___y_1080_ = v___x_1091_;
v___y_1081_ = v___y_1089_;
v___y_1082_ = v___x_1093_;
goto v___jp_1078_;
}
else
{
uint32_t v___x_1094_; 
v___x_1094_ = 256;
v___y_1079_ = v___x_1090_;
v___y_1080_ = v___x_1091_;
v___y_1081_ = v___y_1089_;
v___y_1082_ = v___x_1094_;
goto v___jp_1078_;
}
}
v___jp_1095_:
{
uint8_t v___x_1098_; 
v___x_1098_ = lean_uint8_dec_le(v___y_1096_, v___y_1097_);
if (v___x_1098_ == 0)
{
v___y_1089_ = v___y_1096_;
goto v___jp_1088_;
}
else
{
v___y_1089_ = v___y_1097_;
goto v___jp_1088_;
}
}
v___jp_1099_:
{
uint8_t v___x_1101_; 
v___x_1101_ = 3;
v___y_1096_ = v___y_1100_;
v___y_1097_ = v___x_1101_;
goto v___jp_1095_;
}
v___jp_1102_:
{
uint8_t v___x_1105_; 
v___x_1105_ = lean_uint8_dec_eq(v_canaryTripped_1056_, v___y_1103_);
if (v___x_1105_ == 0)
{
uint8_t v___x_1106_; uint8_t v___x_1107_; 
v___x_1106_ = 2;
v___x_1107_ = lean_uint8_dec_eq(v_manualTrigger_1058_, v___x_1106_);
if (v___x_1107_ == 0)
{
uint8_t v___x_1108_; 
v___x_1108_ = lean_uint8_dec_eq(v_authFailureBurst_1057_, v___y_1103_);
if (v___x_1108_ == 0)
{
uint8_t v___x_1109_; 
v___x_1109_ = lean_uint8_dec_eq(v_manualTrigger_1058_, v___y_1103_);
if (v___x_1109_ == 0)
{
uint8_t v___x_1110_; 
v___x_1110_ = 0;
v___y_1096_ = v___y_1104_;
v___y_1097_ = v___x_1110_;
goto v___jp_1095_;
}
else
{
v___y_1096_ = v___y_1104_;
v___y_1097_ = v___y_1103_;
goto v___jp_1095_;
}
}
else
{
v___y_1096_ = v___y_1104_;
v___y_1097_ = v___y_1103_;
goto v___jp_1095_;
}
}
else
{
v___y_1096_ = v___y_1104_;
v___y_1097_ = v___x_1106_;
goto v___jp_1095_;
}
}
else
{
uint8_t v___x_1111_; 
v___x_1111_ = 2;
v___y_1096_ = v___y_1104_;
v___y_1097_ = v___x_1111_;
goto v___jp_1095_;
}
}
v___jp_1112_:
{
uint8_t v___x_1115_; uint8_t v___x_1116_; 
v___x_1115_ = 3;
v___x_1116_ = lean_uint8_dec_eq(v_manualTrigger_1058_, v___x_1115_);
if (v___x_1116_ == 0)
{
uint8_t v___x_1117_; 
v___x_1117_ = lean_uint8_dec_eq(v_isSovereignNode_1055_, v___y_1113_);
if (v___x_1117_ == 0)
{
v___y_1103_ = v___y_1113_;
v___y_1104_ = v___y_1114_;
goto v___jp_1102_;
}
else
{
uint8_t v___x_1118_; 
v___x_1118_ = lean_uint8_dec_eq(v_heartbeatValid_1060_, v___y_1113_);
if (v___x_1118_ == 0)
{
v___y_1100_ = v___y_1114_;
goto v___jp_1099_;
}
else
{
uint64_t v___x_1119_; uint8_t v___x_1120_; 
v___x_1119_ = 0ULL;
v___x_1120_ = lean_uint64_dec_eq(v_deadManTimeoutSecs_1063_, v___x_1119_);
if (v___x_1120_ == 0)
{
uint8_t v___x_1121_; 
v___x_1121_ = lean_uint64_dec_lt(v_nowEpoch_1061_, v_lastHeartbeatAt_1062_);
if (v___x_1121_ == 0)
{
uint64_t v___x_1122_; uint8_t v___x_1123_; 
v___x_1122_ = lean_uint64_sub(v_nowEpoch_1061_, v_lastHeartbeatAt_1062_);
v___x_1123_ = lean_uint64_dec_le(v_deadManTimeoutSecs_1063_, v___x_1122_);
if (v___x_1123_ == 0)
{
v___y_1103_ = v___y_1113_;
v___y_1104_ = v___y_1114_;
goto v___jp_1102_;
}
else
{
v___y_1100_ = v___y_1114_;
goto v___jp_1099_;
}
}
else
{
v___y_1100_ = v___y_1114_;
goto v___jp_1099_;
}
}
else
{
v___y_1100_ = v___y_1114_;
goto v___jp_1099_;
}
}
}
}
else
{
v___y_1100_ = v___y_1114_;
goto v___jp_1099_;
}
}
v___jp_1124_:
{
uint8_t v___x_1126_; uint8_t v___x_1127_; 
v___x_1126_ = 1;
v___x_1127_ = lean_uint8_dec_eq(v_biometricUnbunker_1059_, v___x_1126_);
if (v___x_1127_ == 0)
{
v___y_1113_ = v___x_1126_;
v___y_1114_ = v___y_1125_;
goto v___jp_1112_;
}
else
{
uint8_t v___x_1128_; 
v___x_1128_ = 0;
v___y_1113_ = v___x_1126_;
v___y_1114_ = v___x_1128_;
goto v___jp_1112_;
}
}
}
}

LEAN_EXPORT uint8_t leanmesh_frame_bounds_step(uint32_t v_magic_1158_, uint8_t v_version_1159_, uint8_t v_frameKind_1160_, uint8_t v_tagVerified_1161_, uint64_t v_headerLen_1162_, uint64_t v_payloadLen_1163_, uint64_t v_maxFrameBytes_1164_, uint64_t v_bufCap_1165_){
{
uint32_t v___x_1166_; uint8_t v___x_1167_; 
v___x_1166_ = 1280136008;
v___x_1167_ = lean_uint32_dec_eq(v_magic_1158_, v___x_1166_);
if (v___x_1167_ == 0)
{
uint8_t v___x_1168_; 
v___x_1168_ = 0;
return v___x_1168_;
}
else
{
uint8_t v___x_1169_; uint8_t v___x_1170_; 
v___x_1169_ = 1;
v___x_1170_ = lean_uint8_dec_eq(v_version_1159_, v___x_1169_);
if (v___x_1170_ == 0)
{
uint8_t v___x_1171_; 
v___x_1171_ = 0;
return v___x_1171_;
}
else
{
uint8_t v___x_1172_; 
v___x_1172_ = lean_uint8_dec_le(v___x_1169_, v_frameKind_1160_);
if (v___x_1172_ == 0)
{
uint8_t v___x_1173_; 
v___x_1173_ = 0;
return v___x_1173_;
}
else
{
uint8_t v___x_1174_; uint8_t v___x_1175_; 
v___x_1174_ = 6;
v___x_1175_ = lean_uint8_dec_le(v_frameKind_1160_, v___x_1174_);
if (v___x_1175_ == 0)
{
uint8_t v___x_1176_; 
v___x_1176_ = 0;
return v___x_1176_;
}
else
{
uint8_t v___x_1177_; 
v___x_1177_ = lean_uint8_dec_eq(v_tagVerified_1161_, v___x_1169_);
if (v___x_1177_ == 0)
{
uint8_t v___x_1178_; 
v___x_1178_ = 0;
return v___x_1178_;
}
else
{
uint64_t v___x_1179_; uint8_t v___x_1180_; 
v___x_1179_ = 32ULL;
v___x_1180_ = lean_uint64_dec_le(v___x_1179_, v_headerLen_1162_);
if (v___x_1180_ == 0)
{
uint8_t v___x_1181_; 
v___x_1181_ = 0;
return v___x_1181_;
}
else
{
uint8_t v___x_1182_; 
v___x_1182_ = lean_uint64_dec_le(v_maxFrameBytes_1164_, v_bufCap_1165_);
if (v___x_1182_ == 0)
{
uint8_t v___x_1183_; 
v___x_1183_ = 0;
return v___x_1183_;
}
else
{
uint8_t v___x_1184_; 
v___x_1184_ = lean_uint64_dec_le(v_headerLen_1162_, v_maxFrameBytes_1164_);
if (v___x_1184_ == 0)
{
uint8_t v___x_1185_; 
v___x_1185_ = 0;
return v___x_1185_;
}
else
{
uint64_t v___x_1186_; uint8_t v___x_1187_; 
v___x_1186_ = lean_uint64_sub(v_maxFrameBytes_1164_, v_headerLen_1162_);
v___x_1187_ = lean_uint64_dec_le(v_payloadLen_1163_, v___x_1186_);
if (v___x_1187_ == 0)
{
uint8_t v___x_1188_; 
v___x_1188_ = 0;
return v___x_1188_;
}
else
{
return v___x_1169_;
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

LEAN_EXPORT uint8_t leanmesh_overlay_ip_step(uint32_t v_peerIdA_1216_, uint32_t v_peerIdB_1217_, uint32_t v_ipA_1218_, uint32_t v_ipB_1219_, uint8_t v_prefixLenA_1220_, uint8_t v_prefixLenB_1221_){
{
uint32_t v___x_1222_; uint8_t v___x_1223_; 
v___x_1222_ = 0;
v___x_1223_ = lean_uint32_dec_eq(v_peerIdA_1216_, v___x_1222_);
if (v___x_1223_ == 0)
{
uint8_t v___x_1224_; 
v___x_1224_ = lean_uint32_dec_eq(v_peerIdB_1217_, v___x_1222_);
if (v___x_1224_ == 0)
{
uint8_t v___x_1225_; 
v___x_1225_ = lean_uint32_dec_eq(v_peerIdA_1216_, v_peerIdB_1217_);
if (v___x_1225_ == 0)
{
uint32_t v___x_1226_; uint8_t v___x_1227_; 
v___x_1226_ = 173539329;
v___x_1227_ = lean_uint32_dec_le(v___x_1226_, v_ipA_1218_);
if (v___x_1227_ == 0)
{
uint8_t v___x_1228_; 
v___x_1228_ = 0;
return v___x_1228_;
}
else
{
uint32_t v___x_1229_; uint8_t v___x_1230_; 
v___x_1229_ = 173604862;
v___x_1230_ = lean_uint32_dec_le(v_ipA_1218_, v___x_1229_);
if (v___x_1230_ == 0)
{
uint8_t v___x_1231_; 
v___x_1231_ = 0;
return v___x_1231_;
}
else
{
uint8_t v___x_1232_; 
v___x_1232_ = lean_uint32_dec_le(v___x_1226_, v_ipB_1219_);
if (v___x_1232_ == 0)
{
uint8_t v___x_1233_; 
v___x_1233_ = 0;
return v___x_1233_;
}
else
{
uint8_t v___x_1234_; 
v___x_1234_ = lean_uint32_dec_le(v_ipB_1219_, v___x_1229_);
if (v___x_1234_ == 0)
{
uint8_t v___x_1235_; 
v___x_1235_ = 0;
return v___x_1235_;
}
else
{
uint8_t v___x_1236_; uint8_t v___x_1237_; 
v___x_1236_ = 32;
v___x_1237_ = lean_uint8_dec_eq(v_prefixLenA_1220_, v___x_1236_);
if (v___x_1237_ == 0)
{
uint8_t v___x_1238_; 
v___x_1238_ = 0;
return v___x_1238_;
}
else
{
uint8_t v___x_1239_; 
v___x_1239_ = lean_uint8_dec_eq(v_prefixLenB_1221_, v___x_1236_);
if (v___x_1239_ == 0)
{
uint8_t v___x_1240_; 
v___x_1240_ = 0;
return v___x_1240_;
}
else
{
uint8_t v___x_1241_; 
v___x_1241_ = lean_uint32_dec_eq(v_ipA_1218_, v_ipB_1219_);
if (v___x_1241_ == 0)
{
uint8_t v___x_1242_; 
v___x_1242_ = 1;
return v___x_1242_;
}
else
{
uint8_t v___x_1243_; 
v___x_1243_ = 0;
return v___x_1243_;
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
uint8_t v___x_1244_; 
v___x_1244_ = 0;
return v___x_1244_;
}
}
else
{
uint8_t v___x_1245_; 
v___x_1245_ = 0;
return v___x_1245_;
}
}
else
{
uint8_t v___x_1246_; 
v___x_1246_ = 0;
return v___x_1246_;
}
}
}

LEAN_EXPORT uint8_t leanmesh_reconcile_wg_step(uint8_t v_manifestValid_1285_, uint8_t v_peerPresentInKernel_1286_, uint8_t v_peerRevoked_1287_, uint8_t v_pubkeyMatches_1288_, uint8_t v_allowedIpMatches_1289_, uint8_t v_endpointChanged_1290_, uint8_t v_bunkerPruneNonAdmin_1291_, uint8_t v_peerIsAdmin_1292_, uint64_t v_nowEpoch_1293_, uint64_t v_peerExpiresAt_1294_){
{
uint8_t v___x_1295_; uint8_t v___x_1310_; 
v___x_1295_ = 1;
v___x_1310_ = lean_uint8_dec_eq(v_manifestValid_1285_, v___x_1295_);
if (v___x_1310_ == 0)
{
uint8_t v___x_1311_; 
v___x_1311_ = 0;
return v___x_1311_;
}
else
{
uint8_t v___x_1312_; 
v___x_1312_ = lean_uint8_dec_eq(v_peerRevoked_1287_, v___x_1295_);
if (v___x_1312_ == 0)
{
uint8_t v___x_1313_; 
v___x_1313_ = lean_uint64_dec_le(v_peerExpiresAt_1294_, v_nowEpoch_1293_);
if (v___x_1313_ == 0)
{
uint8_t v___x_1314_; uint8_t v___x_1315_; 
v___x_1314_ = 2;
v___x_1315_ = lean_uint8_dec_le(v___x_1314_, v_bunkerPruneNonAdmin_1291_);
if (v___x_1315_ == 0)
{
uint8_t v___x_1316_; 
v___x_1316_ = lean_uint8_dec_eq(v_bunkerPruneNonAdmin_1291_, v___x_1295_);
if (v___x_1316_ == 0)
{
goto v___jp_1296_;
}
else
{
uint8_t v___x_1317_; 
v___x_1317_ = lean_uint8_dec_eq(v_peerIsAdmin_1292_, v___x_1295_);
if (v___x_1317_ == 0)
{
goto v___jp_1307_;
}
else
{
goto v___jp_1296_;
}
}
}
else
{
goto v___jp_1307_;
}
}
else
{
goto v___jp_1307_;
}
}
else
{
goto v___jp_1307_;
}
}
v___jp_1296_:
{
uint8_t v___x_1297_; uint8_t v___x_1298_; 
v___x_1297_ = 0;
v___x_1298_ = lean_uint8_dec_eq(v_peerPresentInKernel_1286_, v___x_1297_);
if (v___x_1298_ == 0)
{
uint8_t v___x_1299_; 
v___x_1299_ = lean_uint8_dec_eq(v_pubkeyMatches_1288_, v___x_1295_);
if (v___x_1299_ == 0)
{
uint8_t v___x_1300_; 
v___x_1300_ = 3;
return v___x_1300_;
}
else
{
uint8_t v___x_1301_; 
v___x_1301_ = lean_uint8_dec_eq(v_allowedIpMatches_1289_, v___x_1295_);
if (v___x_1301_ == 0)
{
uint8_t v___x_1302_; 
v___x_1302_ = 3;
return v___x_1302_;
}
else
{
uint8_t v___x_1303_; 
v___x_1303_ = lean_uint8_dec_eq(v_endpointChanged_1290_, v___x_1295_);
if (v___x_1303_ == 0)
{
uint8_t v___x_1304_; 
v___x_1304_ = 6;
return v___x_1304_;
}
else
{
uint8_t v___x_1305_; 
v___x_1305_ = 5;
return v___x_1305_;
}
}
}
}
else
{
uint8_t v___x_1306_; 
v___x_1306_ = 4;
return v___x_1306_;
}
}
v___jp_1307_:
{
uint8_t v___x_1308_; 
v___x_1308_ = lean_uint8_dec_eq(v_peerPresentInKernel_1286_, v___x_1295_);
if (v___x_1308_ == 0)
{
uint8_t v___x_1309_; 
v___x_1309_ = 2;
return v___x_1309_;
}
else
{
return v___x_1295_;
}
}
}
}

LEAN_EXPORT uint32_t leanmesh_jit_lease_step(uint8_t v_biometricSigValid_1360_, uint8_t v_operatorSameOwner_1361_, uint8_t v_missionActive_1362_, uint8_t v_grantRevoked_1363_, uint8_t v_bunkerState_1364_, uint8_t v_srcClass_1365_, uint8_t v_dstClass_1366_, uint64_t v_nowEpoch_1367_, uint64_t v_grantIssuedAt_1368_, uint64_t v_grantExpiresAt_1369_, uint64_t v_maxJitTtlSecs_1370_){
{
uint8_t v___x_1396_; uint8_t v___x_1397_; 
v___x_1396_ = 0;
v___x_1397_ = lean_uint8_dec_eq(v_missionActive_1362_, v___x_1396_);
if (v___x_1397_ == 0)
{
uint8_t v___x_1398_; uint8_t v___x_1399_; 
v___x_1398_ = 1;
v___x_1399_ = lean_uint8_dec_eq(v_grantRevoked_1363_, v___x_1398_);
if (v___x_1399_ == 0)
{
uint8_t v___x_1400_; 
v___x_1400_ = lean_uint8_dec_eq(v_bunkerState_1364_, v___x_1396_);
if (v___x_1400_ == 0)
{
uint32_t v___x_1401_; 
v___x_1401_ = 256;
return v___x_1401_;
}
else
{
uint8_t v___x_1402_; 
v___x_1402_ = lean_uint64_dec_le(v_grantExpiresAt_1369_, v_nowEpoch_1367_);
if (v___x_1402_ == 0)
{
uint8_t v___x_1403_; 
v___x_1403_ = lean_uint8_dec_eq(v_biometricSigValid_1360_, v___x_1398_);
if (v___x_1403_ == 0)
{
uint32_t v___x_1404_; 
v___x_1404_ = 0;
return v___x_1404_;
}
else
{
uint8_t v___x_1405_; 
v___x_1405_ = lean_uint8_dec_eq(v_operatorSameOwner_1361_, v___x_1398_);
if (v___x_1405_ == 0)
{
uint32_t v___x_1406_; 
v___x_1406_ = 0;
return v___x_1406_;
}
else
{
uint8_t v___x_1407_; uint8_t v___x_1408_; 
v___x_1407_ = 2;
v___x_1408_ = lean_uint8_dec_eq(v_srcClass_1365_, v___x_1407_);
if (v___x_1408_ == 0)
{
goto v___jp_1390_;
}
else
{
uint8_t v___x_1409_; uint8_t v___x_1410_; 
v___x_1409_ = 5;
v___x_1410_ = lean_uint8_dec_eq(v_dstClass_1366_, v___x_1409_);
if (v___x_1410_ == 0)
{
goto v___jp_1390_;
}
else
{
goto v___jp_1371_;
}
}
}
}
}
else
{
uint32_t v___x_1411_; 
v___x_1411_ = 256;
return v___x_1411_;
}
}
}
else
{
uint32_t v___x_1412_; 
v___x_1412_ = 256;
return v___x_1412_;
}
}
else
{
uint32_t v___x_1413_; 
v___x_1413_ = 256;
return v___x_1413_;
}
v___jp_1371_:
{
uint64_t v___x_1372_; uint8_t v___x_1373_; 
v___x_1372_ = 0ULL;
v___x_1373_ = lean_uint64_dec_lt(v___x_1372_, v_maxJitTtlSecs_1370_);
if (v___x_1373_ == 0)
{
uint32_t v___x_1374_; 
v___x_1374_ = 0;
return v___x_1374_;
}
else
{
uint64_t v___x_1375_; uint8_t v___x_1376_; 
v___x_1375_ = 14400ULL;
v___x_1376_ = lean_uint64_dec_le(v_maxJitTtlSecs_1370_, v___x_1375_);
if (v___x_1376_ == 0)
{
uint32_t v___x_1377_; 
v___x_1377_ = 0;
return v___x_1377_;
}
else
{
uint8_t v___x_1378_; 
v___x_1378_ = lean_uint64_dec_le(v_grantIssuedAt_1368_, v_nowEpoch_1367_);
if (v___x_1378_ == 0)
{
uint32_t v___x_1379_; 
v___x_1379_ = 0;
return v___x_1379_;
}
else
{
uint8_t v___x_1380_; 
v___x_1380_ = lean_uint64_dec_lt(v_grantIssuedAt_1368_, v_grantExpiresAt_1369_);
if (v___x_1380_ == 0)
{
uint32_t v___x_1381_; 
v___x_1381_ = 0;
return v___x_1381_;
}
else
{
uint64_t v___x_1382_; uint8_t v___x_1383_; 
v___x_1382_ = lean_uint64_sub(v_grantExpiresAt_1369_, v_grantIssuedAt_1368_);
v___x_1383_ = lean_uint64_dec_le(v___x_1382_, v_maxJitTtlSecs_1370_);
if (v___x_1383_ == 0)
{
uint32_t v___x_1384_; 
v___x_1384_ = 0;
return v___x_1384_;
}
else
{
uint32_t v___x_1385_; 
v___x_1385_ = 1;
return v___x_1385_;
}
}
}
}
}
}
v___jp_1386_:
{
uint8_t v___x_1387_; uint8_t v___x_1388_; 
v___x_1387_ = 3;
v___x_1388_ = lean_uint8_dec_eq(v_dstClass_1366_, v___x_1387_);
if (v___x_1388_ == 0)
{
uint32_t v___x_1389_; 
v___x_1389_ = 0;
return v___x_1389_;
}
else
{
goto v___jp_1371_;
}
}
v___jp_1390_:
{
uint8_t v___x_1391_; uint8_t v___x_1392_; 
v___x_1391_ = 0;
v___x_1392_ = lean_uint8_dec_eq(v_srcClass_1365_, v___x_1391_);
if (v___x_1392_ == 0)
{
uint8_t v___x_1393_; uint8_t v___x_1394_; 
v___x_1393_ = 1;
v___x_1394_ = lean_uint8_dec_eq(v_srcClass_1365_, v___x_1393_);
if (v___x_1394_ == 0)
{
uint32_t v___x_1395_; 
v___x_1395_ = 0;
return v___x_1395_;
}
else
{
goto v___jp_1386_;
}
}
else
{
goto v___jp_1386_;
}
}
}
}
