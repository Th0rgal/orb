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

LEAN_EXPORT uint32_t leanmesh_eval_route_step(uint32_t v_srcId_418_, uint32_t v_dstId_419_, uint8_t v_srcClass_420_, uint8_t v_dstClass_421_, uint8_t v_srcRevoked_422_, uint8_t v_dstRevoked_423_, uint8_t v_ruleMatched_424_, uint8_t v_proto_425_, uint32_t v_dstPort_426_, uint32_t v_rulePortMin_427_, uint32_t v_rulePortMax_428_, uint8_t v_jitBiometricGrant_429_, uint8_t v_bunkerState_430_, uint64_t v_nowEpoch_431_, uint64_t v_srcExpiresAt_432_, uint64_t v_dstExpiresAt_433_, uint64_t v_jitExpiresAt_434_){
{
uint8_t v___y_447_; uint8_t v___y_451_; uint8_t v___y_459_; uint8_t v___y_460_; uint8_t v___y_462_; uint8_t v___y_463_; uint8_t v___y_480_; uint8_t v___y_481_; uint8_t v___y_489_; uint8_t v___y_514_; uint8_t v___y_515_; uint8_t v___y_521_; uint8_t v___y_522_; uint8_t v___y_523_; uint8_t v___y_527_; uint8_t v___y_528_; uint8_t v___y_529_; uint8_t v___y_539_; uint8_t v___y_540_; uint8_t v___y_541_; uint8_t v___y_542_; uint8_t v___y_549_; uint8_t v___y_550_; uint8_t v___y_551_; uint8_t v___y_552_; uint8_t v___y_553_; uint8_t v___y_559_; uint8_t v___y_560_; uint8_t v___y_561_; uint8_t v___y_562_; uint8_t v___y_563_; uint8_t v___y_570_; uint8_t v___y_571_; uint8_t v___y_572_; uint8_t v___y_573_; uint8_t v___y_581_; uint8_t v___y_582_; uint8_t v___y_589_; uint32_t v___x_594_; uint8_t v___x_595_; 
v___x_594_ = 3088;
v___x_595_ = lean_uint32_dec_eq(v_dstPort_426_, v___x_594_);
if (v___x_595_ == 0)
{
uint8_t v___x_596_; 
v___x_596_ = lean_uint32_dec_le(v_rulePortMin_427_, v___x_594_);
if (v___x_596_ == 0)
{
v___y_589_ = v___x_596_;
goto v___jp_588_;
}
else
{
uint8_t v___x_597_; 
v___x_597_ = lean_uint32_dec_le(v___x_594_, v_rulePortMax_428_);
v___y_589_ = v___x_597_;
goto v___jp_588_;
}
}
else
{
v___y_589_ = v___x_595_;
goto v___jp_588_;
}
v___jp_435_:
{
uint8_t v___x_436_; uint8_t v___x_437_; 
v___x_436_ = 2;
v___x_437_ = lean_uint8_dec_eq(v_bunkerState_430_, v___x_436_);
if (v___x_437_ == 0)
{
uint32_t v___x_438_; 
v___x_438_ = 1;
return v___x_438_;
}
else
{
uint32_t v___x_439_; 
v___x_439_ = 257;
return v___x_439_;
}
}
v___jp_440_:
{
uint8_t v___x_441_; uint8_t v___x_442_; 
v___x_441_ = 3;
v___x_442_ = lean_uint8_dec_eq(v_dstClass_421_, v___x_441_);
if (v___x_442_ == 0)
{
goto v___jp_435_;
}
else
{
uint8_t v___x_443_; uint8_t v___x_444_; 
v___x_443_ = 1;
v___x_444_ = lean_uint8_dec_le(v_srcClass_420_, v___x_443_);
if (v___x_444_ == 0)
{
goto v___jp_435_;
}
else
{
uint32_t v___x_445_; 
v___x_445_ = 257;
return v___x_445_;
}
}
}
v___jp_446_:
{
if (v___y_447_ == 0)
{
uint32_t v___x_448_; 
v___x_448_ = 0;
return v___x_448_;
}
else
{
uint32_t v___x_449_; 
v___x_449_ = 65536;
return v___x_449_;
}
}
v___jp_450_:
{
if (v___y_451_ == 0)
{
uint8_t v___x_452_; uint8_t v___x_453_; 
v___x_452_ = 5;
v___x_453_ = lean_uint8_dec_eq(v_dstClass_421_, v___x_452_);
if (v___x_453_ == 0)
{
goto v___jp_440_;
}
else
{
uint8_t v___x_454_; uint8_t v___x_455_; 
v___x_454_ = 2;
v___x_455_ = lean_uint8_dec_eq(v_srcClass_420_, v___x_454_);
if (v___x_455_ == 0)
{
goto v___jp_440_;
}
else
{
uint32_t v___x_456_; 
v___x_456_ = 257;
return v___x_456_;
}
}
}
else
{
uint32_t v___x_457_; 
v___x_457_ = 65536;
return v___x_457_;
}
}
v___jp_458_:
{
if (v___y_460_ == 0)
{
v___y_447_ = v___y_459_;
goto v___jp_446_;
}
else
{
v___y_451_ = v___y_459_;
goto v___jp_450_;
}
}
v___jp_461_:
{
if (v___y_463_ == 0)
{
v___y_447_ = v___y_462_;
goto v___jp_446_;
}
else
{
uint8_t v___x_464_; uint8_t v___x_465_; 
v___x_464_ = 0;
v___x_465_ = lean_uint8_dec_eq(v_bunkerState_430_, v___x_464_);
if (v___x_465_ == 0)
{
uint8_t v___x_466_; uint8_t v___x_467_; 
v___x_466_ = 1;
v___x_467_ = lean_uint8_dec_eq(v_bunkerState_430_, v___x_466_);
if (v___x_467_ == 0)
{
uint8_t v___x_468_; uint8_t v___x_469_; 
v___x_468_ = 2;
v___x_469_ = lean_uint8_dec_eq(v_bunkerState_430_, v___x_468_);
if (v___x_469_ == 0)
{
v___y_447_ = v___y_462_;
goto v___jp_446_;
}
else
{
uint8_t v___x_470_; uint8_t v___x_471_; 
v___x_470_ = 6;
v___x_471_ = lean_uint8_dec_eq(v_srcClass_420_, v___x_470_);
if (v___x_471_ == 0)
{
v___y_447_ = v___y_462_;
goto v___jp_446_;
}
else
{
uint8_t v___x_472_; 
v___x_472_ = lean_uint8_dec_eq(v_proto_425_, v___x_470_);
if (v___x_472_ == 0)
{
v___y_447_ = v___y_462_;
goto v___jp_446_;
}
else
{
uint32_t v___x_473_; uint8_t v___x_474_; 
v___x_473_ = 22;
v___x_474_ = lean_uint32_dec_eq(v_dstPort_426_, v___x_473_);
if (v___x_474_ == 0)
{
v___y_447_ = v___y_462_;
goto v___jp_446_;
}
else
{
uint8_t v___x_475_; 
v___x_475_ = lean_uint32_dec_eq(v_rulePortMin_427_, v___x_473_);
if (v___x_475_ == 0)
{
v___y_447_ = v___y_462_;
goto v___jp_446_;
}
else
{
uint8_t v___x_476_; 
v___x_476_ = lean_uint32_dec_eq(v_rulePortMax_428_, v___x_473_);
v___y_459_ = v___y_462_;
v___y_460_ = v___x_476_;
goto v___jp_458_;
}
}
}
}
}
}
else
{
uint8_t v___x_477_; uint8_t v___x_478_; 
v___x_477_ = 2;
v___x_478_ = lean_uint8_dec_le(v___x_477_, v_srcClass_420_);
v___y_459_ = v___y_462_;
v___y_460_ = v___x_478_;
goto v___jp_458_;
}
}
else
{
v___y_451_ = v___y_462_;
goto v___jp_450_;
}
}
}
v___jp_479_:
{
uint32_t v___x_482_; uint8_t v___x_483_; 
v___x_482_ = 1;
v___x_483_ = lean_uint32_dec_le(v___x_482_, v_rulePortMin_427_);
if (v___x_483_ == 0)
{
v___y_462_ = v___y_480_;
v___y_463_ = v___y_481_;
goto v___jp_461_;
}
else
{
uint8_t v___x_484_; 
v___x_484_ = lean_uint32_dec_le(v_rulePortMin_427_, v_dstPort_426_);
if (v___x_484_ == 0)
{
v___y_462_ = v___y_480_;
v___y_463_ = v___y_481_;
goto v___jp_461_;
}
else
{
uint8_t v___x_485_; 
v___x_485_ = lean_uint32_dec_le(v_dstPort_426_, v_rulePortMax_428_);
if (v___x_485_ == 0)
{
v___y_462_ = v___y_480_;
v___y_463_ = v___y_481_;
goto v___jp_461_;
}
else
{
uint32_t v___x_486_; uint8_t v___x_487_; 
v___x_486_ = 65535;
v___x_487_ = lean_uint32_dec_le(v_rulePortMax_428_, v___x_486_);
v___y_462_ = v___y_480_;
v___y_463_ = v___x_487_;
goto v___jp_461_;
}
}
}
}
v___jp_488_:
{
uint32_t v___x_490_; uint8_t v___x_491_; 
v___x_490_ = 0;
v___x_491_ = lean_uint32_dec_eq(v_srcId_418_, v___x_490_);
if (v___x_491_ == 0)
{
uint8_t v___x_492_; 
v___x_492_ = lean_uint32_dec_eq(v_dstId_419_, v___x_490_);
if (v___x_492_ == 0)
{
uint8_t v___x_493_; 
v___x_493_ = lean_uint32_dec_eq(v_srcId_418_, v_dstId_419_);
if (v___x_493_ == 0)
{
uint8_t v___x_494_; uint8_t v___x_495_; 
v___x_494_ = 6;
v___x_495_ = lean_uint8_dec_le(v_srcClass_420_, v___x_494_);
if (v___x_495_ == 0)
{
v___y_447_ = v___y_489_;
goto v___jp_446_;
}
else
{
uint8_t v___x_496_; 
v___x_496_ = lean_uint8_dec_le(v_dstClass_421_, v___x_494_);
if (v___x_496_ == 0)
{
v___y_447_ = v___y_489_;
goto v___jp_446_;
}
else
{
uint8_t v___x_497_; uint8_t v___x_498_; 
v___x_497_ = 3;
v___x_498_ = lean_uint8_dec_le(v_bunkerState_430_, v___x_497_);
if (v___x_498_ == 0)
{
v___y_447_ = v___y_489_;
goto v___jp_446_;
}
else
{
uint8_t v___x_499_; uint8_t v___x_500_; 
v___x_499_ = 0;
v___x_500_ = lean_uint8_dec_eq(v_srcRevoked_422_, v___x_499_);
if (v___x_500_ == 0)
{
v___y_447_ = v___y_489_;
goto v___jp_446_;
}
else
{
uint8_t v___x_501_; 
v___x_501_ = lean_uint8_dec_eq(v_dstRevoked_423_, v___x_499_);
if (v___x_501_ == 0)
{
v___y_447_ = v___y_489_;
goto v___jp_446_;
}
else
{
uint8_t v___x_502_; uint8_t v___x_503_; 
v___x_502_ = 1;
v___x_503_ = lean_uint8_dec_eq(v_ruleMatched_424_, v___x_502_);
if (v___x_503_ == 0)
{
v___y_447_ = v___y_489_;
goto v___jp_446_;
}
else
{
uint8_t v___x_504_; 
v___x_504_ = lean_uint64_dec_lt(v_nowEpoch_431_, v_srcExpiresAt_432_);
if (v___x_504_ == 0)
{
v___y_447_ = v___y_489_;
goto v___jp_446_;
}
else
{
uint8_t v___x_505_; 
v___x_505_ = lean_uint64_dec_lt(v_nowEpoch_431_, v_dstExpiresAt_433_);
if (v___x_505_ == 0)
{
v___y_447_ = v___y_489_;
goto v___jp_446_;
}
else
{
uint8_t v___x_506_; 
v___x_506_ = lean_uint8_dec_eq(v_proto_425_, v___x_502_);
if (v___x_506_ == 0)
{
uint8_t v___x_507_; 
v___x_507_ = lean_uint8_dec_eq(v_proto_425_, v___x_494_);
if (v___x_507_ == 0)
{
uint8_t v___x_508_; uint8_t v___x_509_; 
v___x_508_ = 17;
v___x_509_ = lean_uint8_dec_eq(v_proto_425_, v___x_508_);
if (v___x_509_ == 0)
{
v___y_447_ = v___y_489_;
goto v___jp_446_;
}
else
{
v___y_480_ = v___y_489_;
v___y_481_ = v___x_506_;
goto v___jp_479_;
}
}
else
{
v___y_480_ = v___y_489_;
v___y_481_ = v___x_506_;
goto v___jp_479_;
}
}
else
{
uint8_t v___x_510_; 
v___x_510_ = lean_uint32_dec_eq(v_dstPort_426_, v___x_490_);
if (v___x_510_ == 0)
{
v___y_447_ = v___y_489_;
goto v___jp_446_;
}
else
{
uint8_t v___x_511_; 
v___x_511_ = lean_uint32_dec_eq(v_rulePortMin_427_, v___x_490_);
if (v___x_511_ == 0)
{
v___y_447_ = v___y_489_;
goto v___jp_446_;
}
else
{
uint8_t v___x_512_; 
v___x_512_ = lean_uint32_dec_eq(v_rulePortMax_428_, v___x_490_);
v___y_462_ = v___y_489_;
v___y_463_ = v___x_512_;
goto v___jp_461_;
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
v___y_447_ = v___y_489_;
goto v___jp_446_;
}
}
else
{
v___y_447_ = v___y_489_;
goto v___jp_446_;
}
}
else
{
v___y_447_ = v___y_489_;
goto v___jp_446_;
}
}
v___jp_513_:
{
uint8_t v___x_516_; uint8_t v___x_517_; 
v___x_516_ = 3;
v___x_517_ = lean_uint8_dec_eq(v_dstClass_421_, v___x_516_);
if (v___x_517_ == 0)
{
v___y_489_ = v___x_517_;
goto v___jp_488_;
}
else
{
uint8_t v___x_518_; 
v___x_518_ = lean_uint8_dec_le(v_srcClass_420_, v___y_515_);
if (v___x_518_ == 0)
{
v___y_489_ = v___x_518_;
goto v___jp_488_;
}
else
{
if (v___y_514_ == 0)
{
v___y_489_ = v___x_518_;
goto v___jp_488_;
}
else
{
uint8_t v___x_519_; 
v___x_519_ = 0;
v___y_489_ = v___x_519_;
goto v___jp_488_;
}
}
}
}
v___jp_520_:
{
uint8_t v___x_524_; uint8_t v___x_525_; 
v___x_524_ = 4;
v___x_525_ = lean_uint8_dec_eq(v_srcClass_420_, v___x_524_);
if (v___x_525_ == 0)
{
v___y_514_ = v___y_521_;
v___y_515_ = v___y_523_;
goto v___jp_513_;
}
else
{
if (v___y_522_ == 0)
{
v___y_489_ = v___x_525_;
goto v___jp_488_;
}
else
{
v___y_514_ = v___y_521_;
v___y_515_ = v___y_523_;
goto v___jp_513_;
}
}
}
v___jp_526_:
{
uint8_t v___x_530_; uint8_t v___x_531_; 
v___x_530_ = 5;
v___x_531_ = lean_uint8_dec_eq(v_dstClass_421_, v___x_530_);
if (v___x_531_ == 0)
{
v___y_514_ = v___y_527_;
v___y_515_ = v___y_529_;
goto v___jp_513_;
}
else
{
uint8_t v___x_532_; 
v___x_532_ = lean_uint8_dec_le(v_srcClass_420_, v___y_529_);
if (v___x_532_ == 0)
{
uint8_t v___x_533_; uint8_t v___x_534_; 
v___x_533_ = 3;
v___x_534_ = lean_uint8_dec_eq(v_srcClass_420_, v___x_533_);
if (v___x_534_ == 0)
{
uint8_t v___x_535_; 
v___x_535_ = lean_uint8_dec_eq(v_srcClass_420_, v___x_530_);
if (v___x_535_ == 0)
{
uint8_t v___x_536_; uint8_t v___x_537_; 
v___x_536_ = 2;
v___x_537_ = lean_uint8_dec_eq(v_srcClass_420_, v___x_536_);
if (v___x_537_ == 0)
{
v___y_521_ = v___y_527_;
v___y_522_ = v___y_528_;
v___y_523_ = v___y_529_;
goto v___jp_520_;
}
else
{
if (v___y_527_ == 0)
{
v___y_489_ = v___x_537_;
goto v___jp_488_;
}
else
{
v___y_521_ = v___y_527_;
v___y_522_ = v___y_528_;
v___y_523_ = v___y_529_;
goto v___jp_520_;
}
}
}
else
{
v___y_489_ = v___x_535_;
goto v___jp_488_;
}
}
else
{
v___y_489_ = v___x_534_;
goto v___jp_488_;
}
}
else
{
v___y_489_ = v___x_532_;
goto v___jp_488_;
}
}
}
v___jp_538_:
{
uint8_t v___x_543_; uint8_t v___x_544_; 
v___x_543_ = 6;
v___x_544_ = lean_uint8_dec_eq(v_dstClass_421_, v___x_543_);
if (v___x_544_ == 0)
{
v___y_527_ = v___y_539_;
v___y_528_ = v___y_540_;
v___y_529_ = v___y_541_;
goto v___jp_526_;
}
else
{
uint8_t v___x_545_; uint8_t v___x_546_; 
v___x_545_ = 4;
v___x_546_ = lean_uint8_dec_eq(v_srcClass_420_, v___x_545_);
if (v___x_546_ == 0)
{
uint8_t v___x_547_; 
v___x_547_ = lean_uint8_dec_eq(v_srcClass_420_, v___x_543_);
if (v___x_547_ == 0)
{
v___y_489_ = v___x_544_;
goto v___jp_488_;
}
else
{
if (v___y_542_ == 0)
{
v___y_527_ = v___y_539_;
v___y_528_ = v___y_540_;
v___y_529_ = v___y_541_;
goto v___jp_526_;
}
else
{
v___y_489_ = v___y_542_;
goto v___jp_488_;
}
}
}
else
{
v___y_527_ = v___y_539_;
v___y_528_ = v___y_540_;
v___y_529_ = v___y_541_;
goto v___jp_526_;
}
}
}
v___jp_548_:
{
if (v___y_552_ == 0)
{
v___y_539_ = v___y_549_;
v___y_540_ = v___y_550_;
v___y_541_ = v___y_551_;
v___y_542_ = v___y_552_;
goto v___jp_538_;
}
else
{
uint8_t v___x_554_; uint8_t v___x_555_; 
v___x_554_ = 4;
v___x_555_ = lean_uint8_dec_eq(v_srcClass_420_, v___x_554_);
if (v___x_555_ == 0)
{
uint8_t v___x_556_; uint8_t v___x_557_; 
v___x_556_ = 6;
v___x_557_ = lean_uint8_dec_eq(v_srcClass_420_, v___x_556_);
if (v___x_557_ == 0)
{
v___y_489_ = v___y_552_;
goto v___jp_488_;
}
else
{
v___y_539_ = v___y_549_;
v___y_540_ = v___y_550_;
v___y_541_ = v___y_551_;
v___y_542_ = v___y_553_;
goto v___jp_538_;
}
}
else
{
v___y_539_ = v___y_549_;
v___y_540_ = v___y_550_;
v___y_541_ = v___y_551_;
v___y_542_ = v___y_553_;
goto v___jp_538_;
}
}
}
v___jp_558_:
{
if (v___y_560_ == 0)
{
v___y_549_ = v___y_559_;
v___y_550_ = v___y_563_;
v___y_551_ = v___y_562_;
v___y_552_ = v___y_561_;
v___y_553_ = v___y_560_;
goto v___jp_548_;
}
else
{
uint8_t v___x_564_; uint8_t v___x_565_; 
v___x_564_ = 4;
v___x_565_ = lean_uint8_dec_eq(v_srcClass_420_, v___x_564_);
if (v___x_565_ == 0)
{
uint8_t v___x_566_; uint8_t v___x_567_; 
v___x_566_ = 6;
v___x_567_ = lean_uint8_dec_eq(v_srcClass_420_, v___x_566_);
if (v___x_567_ == 0)
{
v___y_489_ = v___y_560_;
goto v___jp_488_;
}
else
{
v___y_549_ = v___y_559_;
v___y_550_ = v___y_563_;
v___y_551_ = v___y_562_;
v___y_552_ = v___y_561_;
v___y_553_ = v___x_565_;
goto v___jp_548_;
}
}
else
{
uint8_t v___x_568_; 
v___x_568_ = 0;
v___y_549_ = v___y_559_;
v___y_550_ = v___y_563_;
v___y_551_ = v___y_562_;
v___y_552_ = v___y_561_;
v___y_553_ = v___x_568_;
goto v___jp_548_;
}
}
}
v___jp_569_:
{
uint32_t v___x_574_; uint8_t v___x_575_; 
v___x_574_ = 8888;
v___x_575_ = lean_uint32_dec_le(v___x_574_, v_rulePortMin_427_);
if (v___x_575_ == 0)
{
v___y_559_ = v___y_573_;
v___y_560_ = v___y_570_;
v___y_561_ = v___y_571_;
v___y_562_ = v___y_572_;
v___y_563_ = v___x_575_;
goto v___jp_558_;
}
else
{
uint32_t v___x_576_; uint8_t v___x_577_; 
v___x_576_ = 8890;
v___x_577_ = lean_uint32_dec_le(v_rulePortMax_428_, v___x_576_);
if (v___x_577_ == 0)
{
v___y_559_ = v___y_573_;
v___y_560_ = v___y_570_;
v___y_561_ = v___y_571_;
v___y_562_ = v___y_572_;
v___y_563_ = v___x_577_;
goto v___jp_558_;
}
else
{
uint8_t v___x_578_; 
v___x_578_ = lean_uint32_dec_le(v___x_574_, v_dstPort_426_);
if (v___x_578_ == 0)
{
v___y_559_ = v___y_573_;
v___y_560_ = v___y_570_;
v___y_561_ = v___y_571_;
v___y_562_ = v___y_572_;
v___y_563_ = v___x_578_;
goto v___jp_558_;
}
else
{
uint8_t v___x_579_; 
v___x_579_ = lean_uint32_dec_le(v_dstPort_426_, v___x_576_);
v___y_559_ = v___y_573_;
v___y_560_ = v___y_570_;
v___y_561_ = v___y_571_;
v___y_562_ = v___y_572_;
v___y_563_ = v___x_579_;
goto v___jp_558_;
}
}
}
}
v___jp_580_:
{
uint8_t v___x_583_; uint8_t v___x_584_; 
v___x_583_ = 1;
v___x_584_ = lean_uint8_dec_eq(v_jitBiometricGrant_429_, v___x_583_);
if (v___x_584_ == 0)
{
v___y_570_ = v___y_581_;
v___y_571_ = v___y_582_;
v___y_572_ = v___x_583_;
v___y_573_ = v___x_584_;
goto v___jp_569_;
}
else
{
uint8_t v___x_585_; uint8_t v___x_586_; 
v___x_585_ = 0;
v___x_586_ = lean_uint8_dec_eq(v_bunkerState_430_, v___x_585_);
if (v___x_586_ == 0)
{
v___y_570_ = v___y_581_;
v___y_571_ = v___y_582_;
v___y_572_ = v___x_583_;
v___y_573_ = v___x_586_;
goto v___jp_569_;
}
else
{
uint8_t v___x_587_; 
v___x_587_ = lean_uint64_dec_lt(v_nowEpoch_431_, v_jitExpiresAt_434_);
v___y_570_ = v___y_581_;
v___y_571_ = v___y_582_;
v___y_572_ = v___x_583_;
v___y_573_ = v___x_587_;
goto v___jp_569_;
}
}
}
v___jp_588_:
{
uint32_t v___x_590_; uint8_t v___x_591_; 
v___x_590_ = 22;
v___x_591_ = lean_uint32_dec_eq(v_dstPort_426_, v___x_590_);
if (v___x_591_ == 0)
{
uint8_t v___x_592_; 
v___x_592_ = lean_uint32_dec_le(v_rulePortMin_427_, v___x_590_);
if (v___x_592_ == 0)
{
v___y_581_ = v___y_589_;
v___y_582_ = v___x_592_;
goto v___jp_580_;
}
else
{
uint8_t v___x_593_; 
v___x_593_ = lean_uint32_dec_le(v___x_590_, v_rulePortMax_428_);
v___y_581_ = v___y_589_;
v___y_582_ = v___x_593_;
goto v___jp_580_;
}
}
else
{
v___y_581_ = v___y_589_;
v___y_582_ = v___x_591_;
goto v___jp_580_;
}
}
}
}

LEAN_EXPORT uint8_t leanmesh_replay_window_step(uint64_t v_lastMaxSeq_634_, uint64_t v_bitmap_635_, uint64_t v_pktSeq_636_){
{
uint64_t v___x_637_; uint8_t v___x_638_; 
v___x_637_ = 0ULL;
v___x_638_ = lean_uint64_dec_eq(v_pktSeq_636_, v___x_637_);
if (v___x_638_ == 0)
{
uint64_t v___x_639_; uint8_t v___x_640_; 
v___x_639_ = 18446744073709551615ULL;
v___x_640_ = lean_uint64_dec_eq(v_pktSeq_636_, v___x_639_);
if (v___x_640_ == 0)
{
uint8_t v___x_641_; 
v___x_641_ = lean_uint64_dec_lt(v_lastMaxSeq_634_, v_pktSeq_636_);
if (v___x_641_ == 0)
{
uint64_t v_age_642_; uint64_t v___x_643_; uint8_t v___x_644_; 
v_age_642_ = lean_uint64_sub(v_lastMaxSeq_634_, v_pktSeq_636_);
v___x_643_ = 64ULL;
v___x_644_ = lean_uint64_dec_le(v___x_643_, v_age_642_);
if (v___x_644_ == 0)
{
uint64_t v___x_645_; uint64_t v_mask_646_; uint64_t v___x_647_; uint8_t v___x_648_; 
v___x_645_ = 1ULL;
v_mask_646_ = lean_uint64_shift_left(v___x_645_, v_age_642_);
v___x_647_ = lean_uint64_land(v_bitmap_635_, v_mask_646_);
v___x_648_ = lean_uint64_dec_eq(v___x_647_, v___x_637_);
if (v___x_648_ == 0)
{
uint8_t v___x_649_; 
v___x_649_ = 0;
return v___x_649_;
}
else
{
uint8_t v___x_650_; 
v___x_650_ = 1;
return v___x_650_;
}
}
else
{
uint8_t v___x_651_; 
v___x_651_ = 0;
return v___x_651_;
}
}
else
{
uint8_t v___x_652_; 
v___x_652_ = 1;
return v___x_652_;
}
}
else
{
uint8_t v___x_653_; 
v___x_653_ = 0;
return v___x_653_;
}
}
else
{
uint8_t v___x_654_; 
v___x_654_ = 0;
return v___x_654_;
}
}
}

LEAN_EXPORT uint64_t leanmesh_replay_window_next_max(uint64_t v_lastMaxSeq_663_, uint64_t v_bitmap_664_, uint64_t v_pktSeq_665_){
{
uint8_t v___y_667_; uint64_t v___x_671_; uint8_t v___x_672_; 
v___x_671_ = 0ULL;
v___x_672_ = lean_uint64_dec_eq(v_pktSeq_665_, v___x_671_);
if (v___x_672_ == 0)
{
uint64_t v___x_673_; uint8_t v___x_674_; 
v___x_673_ = 18446744073709551615ULL;
v___x_674_ = lean_uint64_dec_eq(v_pktSeq_665_, v___x_673_);
if (v___x_674_ == 0)
{
uint8_t v___x_675_; 
v___x_675_ = lean_uint64_dec_lt(v_lastMaxSeq_663_, v_pktSeq_665_);
if (v___x_675_ == 0)
{
uint64_t v_age_676_; uint64_t v___x_677_; uint8_t v___x_678_; 
v_age_676_ = lean_uint64_sub(v_lastMaxSeq_663_, v_pktSeq_665_);
v___x_677_ = 64ULL;
v___x_678_ = lean_uint64_dec_le(v___x_677_, v_age_676_);
if (v___x_678_ == 0)
{
uint64_t v___x_679_; uint64_t v_mask_680_; uint64_t v___x_681_; uint8_t v___x_682_; 
v___x_679_ = 1ULL;
v_mask_680_ = lean_uint64_shift_left(v___x_679_, v_age_676_);
v___x_681_ = lean_uint64_land(v_bitmap_664_, v_mask_680_);
v___x_682_ = lean_uint64_dec_eq(v___x_681_, v___x_671_);
if (v___x_682_ == 0)
{
uint8_t v___x_683_; 
v___x_683_ = 0;
v___y_667_ = v___x_683_;
goto v___jp_666_;
}
else
{
uint8_t v___x_684_; 
v___x_684_ = 1;
v___y_667_ = v___x_684_;
goto v___jp_666_;
}
}
else
{
uint8_t v___x_685_; 
v___x_685_ = 0;
v___y_667_ = v___x_685_;
goto v___jp_666_;
}
}
else
{
uint8_t v___x_686_; 
v___x_686_ = 1;
v___y_667_ = v___x_686_;
goto v___jp_666_;
}
}
else
{
uint8_t v___x_687_; 
v___x_687_ = 0;
v___y_667_ = v___x_687_;
goto v___jp_666_;
}
}
else
{
uint8_t v___x_688_; 
v___x_688_ = 0;
v___y_667_ = v___x_688_;
goto v___jp_666_;
}
v___jp_666_:
{
uint8_t v___x_668_; uint8_t v___x_669_; 
v___x_668_ = 1;
v___x_669_ = lean_uint8_dec_eq(v___y_667_, v___x_668_);
if (v___x_669_ == 0)
{
return v_lastMaxSeq_663_;
}
else
{
uint8_t v___x_670_; 
v___x_670_ = lean_uint64_dec_lt(v_lastMaxSeq_663_, v_pktSeq_665_);
if (v___x_670_ == 0)
{
return v_lastMaxSeq_663_;
}
else
{
return v_pktSeq_665_;
}
}
}
}
}

LEAN_EXPORT uint64_t leanmesh_replay_window_next_bitmap(uint64_t v_lastMaxSeq_697_, uint64_t v_bitmap_698_, uint64_t v_pktSeq_699_){
{
uint8_t v___y_701_; uint64_t v___x_718_; uint8_t v___x_719_; 
v___x_718_ = 0ULL;
v___x_719_ = lean_uint64_dec_eq(v_pktSeq_699_, v___x_718_);
if (v___x_719_ == 0)
{
uint64_t v___x_720_; uint8_t v___x_721_; 
v___x_720_ = 18446744073709551615ULL;
v___x_721_ = lean_uint64_dec_eq(v_pktSeq_699_, v___x_720_);
if (v___x_721_ == 0)
{
uint8_t v___x_722_; 
v___x_722_ = lean_uint64_dec_lt(v_lastMaxSeq_697_, v_pktSeq_699_);
if (v___x_722_ == 0)
{
uint64_t v_age_723_; uint64_t v___x_724_; uint8_t v___x_725_; 
v_age_723_ = lean_uint64_sub(v_lastMaxSeq_697_, v_pktSeq_699_);
v___x_724_ = 64ULL;
v___x_725_ = lean_uint64_dec_le(v___x_724_, v_age_723_);
if (v___x_725_ == 0)
{
uint64_t v___x_726_; uint64_t v_mask_727_; uint64_t v___x_728_; uint8_t v___x_729_; 
v___x_726_ = 1ULL;
v_mask_727_ = lean_uint64_shift_left(v___x_726_, v_age_723_);
v___x_728_ = lean_uint64_land(v_bitmap_698_, v_mask_727_);
v___x_729_ = lean_uint64_dec_eq(v___x_728_, v___x_718_);
if (v___x_729_ == 0)
{
uint8_t v___x_730_; 
v___x_730_ = 0;
v___y_701_ = v___x_730_;
goto v___jp_700_;
}
else
{
uint8_t v___x_731_; 
v___x_731_ = 1;
v___y_701_ = v___x_731_;
goto v___jp_700_;
}
}
else
{
uint8_t v___x_732_; 
v___x_732_ = 0;
v___y_701_ = v___x_732_;
goto v___jp_700_;
}
}
else
{
uint8_t v___x_733_; 
v___x_733_ = 1;
v___y_701_ = v___x_733_;
goto v___jp_700_;
}
}
else
{
uint8_t v___x_734_; 
v___x_734_ = 0;
v___y_701_ = v___x_734_;
goto v___jp_700_;
}
}
else
{
uint8_t v___x_735_; 
v___x_735_ = 0;
v___y_701_ = v___x_735_;
goto v___jp_700_;
}
v___jp_700_:
{
uint8_t v___x_702_; uint8_t v___x_703_; 
v___x_702_ = 1;
v___x_703_ = lean_uint8_dec_eq(v___y_701_, v___x_702_);
if (v___x_703_ == 0)
{
return v_bitmap_698_;
}
else
{
uint8_t v___x_704_; 
v___x_704_ = lean_uint64_dec_lt(v_lastMaxSeq_697_, v_pktSeq_699_);
if (v___x_704_ == 0)
{
uint64_t v_age_705_; uint64_t v___x_706_; uint8_t v___x_707_; 
v_age_705_ = lean_uint64_sub(v_lastMaxSeq_697_, v_pktSeq_699_);
v___x_706_ = 64ULL;
v___x_707_ = lean_uint64_dec_le(v___x_706_, v_age_705_);
if (v___x_707_ == 0)
{
uint64_t v___x_708_; uint64_t v___x_709_; uint64_t v___x_710_; 
v___x_708_ = 1ULL;
v___x_709_ = lean_uint64_shift_left(v___x_708_, v_age_705_);
v___x_710_ = lean_uint64_lor(v_bitmap_698_, v___x_709_);
return v___x_710_;
}
else
{
return v_bitmap_698_;
}
}
else
{
uint64_t v_delta_711_; uint64_t v___x_712_; uint8_t v___x_713_; 
v_delta_711_ = lean_uint64_sub(v_pktSeq_699_, v_lastMaxSeq_697_);
v___x_712_ = 64ULL;
v___x_713_ = lean_uint64_dec_le(v___x_712_, v_delta_711_);
if (v___x_713_ == 0)
{
uint64_t v___x_714_; uint64_t v___x_715_; uint64_t v___x_716_; 
v___x_714_ = lean_uint64_shift_left(v_bitmap_698_, v_delta_711_);
v___x_715_ = 1ULL;
v___x_716_ = lean_uint64_lor(v___x_714_, v___x_715_);
return v___x_716_;
}
else
{
uint64_t v___x_717_; 
v___x_717_ = 1ULL;
return v___x_717_;
}
}
}
}
}
}

LEAN_EXPORT uint8_t leanmesh_endpoint_roam_step(uint8_t v_aeadAuthOk_808_, uint8_t v_peerPinnedStatic_809_, uint8_t v_candidateIpClass_810_, uint8_t v_allowPrivateRoam_811_, uint8_t v_bunkerState_812_, uint32_t v_candidatePort_813_, uint64_t v_lastRoamSeq_814_, uint64_t v_pktSeq_815_, uint64_t v_lastRoamEpoch_816_, uint64_t v_nowEpoch_817_, uint64_t v_minRoamIntervalSecs_818_){
{
uint8_t v___y_820_; uint8_t v___x_841_; uint8_t v___x_842_; 
v___x_841_ = 5;
v___x_842_ = lean_uint8_dec_eq(v_candidateIpClass_810_, v___x_841_);
if (v___x_842_ == 0)
{
uint8_t v___x_843_; uint8_t v___x_844_; 
v___x_843_ = 1;
v___x_844_ = lean_uint8_dec_eq(v_allowPrivateRoam_811_, v___x_843_);
if (v___x_844_ == 0)
{
v___y_820_ = v___x_844_;
goto v___jp_819_;
}
else
{
uint8_t v___x_845_; uint8_t v___x_846_; 
v___x_845_ = 3;
v___x_846_ = lean_uint8_dec_eq(v_candidateIpClass_810_, v___x_845_);
if (v___x_846_ == 0)
{
uint8_t v___x_847_; uint8_t v___x_848_; 
v___x_847_ = 4;
v___x_848_ = lean_uint8_dec_eq(v_candidateIpClass_810_, v___x_847_);
v___y_820_ = v___x_848_;
goto v___jp_819_;
}
else
{
v___y_820_ = v___x_846_;
goto v___jp_819_;
}
}
}
else
{
v___y_820_ = v___x_842_;
goto v___jp_819_;
}
v___jp_819_:
{
uint8_t v___x_821_; uint8_t v___x_822_; 
v___x_821_ = 1;
v___x_822_ = lean_uint8_dec_eq(v_aeadAuthOk_808_, v___x_821_);
if (v___x_822_ == 0)
{
uint8_t v___x_823_; 
v___x_823_ = 0;
return v___x_823_;
}
else
{
uint8_t v___x_824_; uint8_t v___x_825_; 
v___x_824_ = 0;
v___x_825_ = lean_uint8_dec_eq(v_peerPinnedStatic_809_, v___x_824_);
if (v___x_825_ == 0)
{
return v___x_824_;
}
else
{
uint8_t v___x_826_; 
v___x_826_ = lean_uint8_dec_eq(v_bunkerState_812_, v___x_824_);
if (v___x_826_ == 0)
{
return v___x_824_;
}
else
{
uint32_t v___x_827_; uint8_t v___x_828_; 
v___x_827_ = 1;
v___x_828_ = lean_uint32_dec_le(v___x_827_, v_candidatePort_813_);
if (v___x_828_ == 0)
{
return v___x_824_;
}
else
{
uint32_t v___x_829_; uint8_t v___x_830_; 
v___x_829_ = 65535;
v___x_830_ = lean_uint32_dec_le(v_candidatePort_813_, v___x_829_);
if (v___x_830_ == 0)
{
return v___x_824_;
}
else
{
uint8_t v___x_831_; 
v___x_831_ = lean_uint64_dec_lt(v_lastRoamSeq_814_, v_pktSeq_815_);
if (v___x_831_ == 0)
{
return v___x_824_;
}
else
{
uint64_t v___x_832_; uint8_t v___x_833_; 
v___x_832_ = 18446744073709551615ULL;
v___x_833_ = lean_uint64_dec_lt(v_pktSeq_815_, v___x_832_);
if (v___x_833_ == 0)
{
return v___x_824_;
}
else
{
if (v___y_820_ == 0)
{
return v___x_824_;
}
else
{
uint64_t v___x_834_; uint8_t v___x_835_; 
v___x_834_ = 0ULL;
v___x_835_ = lean_uint64_dec_lt(v___x_834_, v_minRoamIntervalSecs_818_);
if (v___x_835_ == 0)
{
return v___x_824_;
}
else
{
uint64_t v___x_836_; uint8_t v___x_837_; 
v___x_836_ = 86400ULL;
v___x_837_ = lean_uint64_dec_le(v_minRoamIntervalSecs_818_, v___x_836_);
if (v___x_837_ == 0)
{
return v___x_824_;
}
else
{
uint8_t v___x_838_; 
v___x_838_ = lean_uint64_dec_le(v_lastRoamEpoch_816_, v_nowEpoch_817_);
if (v___x_838_ == 0)
{
return v___x_824_;
}
else
{
uint64_t v___x_839_; uint8_t v___x_840_; 
v___x_839_ = lean_uint64_sub(v_nowEpoch_817_, v_lastRoamEpoch_816_);
v___x_840_ = lean_uint64_dec_le(v_minRoamIntervalSecs_818_, v___x_839_);
if (v___x_840_ == 0)
{
return v___x_824_;
}
else
{
return v___x_821_;
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

LEAN_EXPORT uint8_t leanmesh_relay_select_step(uint8_t v_routeAllowed_892_, uint8_t v_lanReachable_893_, uint8_t v_wanReachable_894_, uint8_t v_relayHealthy_895_, uint32_t v_srcId_896_, uint32_t v_dstId_897_, uint32_t v_relayId_898_, uint32_t v_activeRelaySessions_899_, uint32_t v_maxRelaySessions_900_, uint64_t v_nowEpoch_901_, uint64_t v_directHandshakeAt_902_, uint64_t v_maxDirectStaleSecs_903_){
{
uint8_t v___y_909_; uint8_t v___y_913_; uint8_t v___y_917_; uint8_t v___y_918_; uint8_t v___y_921_; uint8_t v___y_922_; uint32_t v___y_923_; uint8_t v___y_924_; uint8_t v___y_928_; uint8_t v___y_929_; uint8_t v___y_930_; uint32_t v___y_931_; uint8_t v___y_934_; uint64_t v___x_947_; uint8_t v___x_948_; 
v___x_947_ = 0ULL;
v___x_948_ = lean_uint64_dec_lt(v___x_947_, v_directHandshakeAt_902_);
if (v___x_948_ == 0)
{
v___y_934_ = v___x_948_;
goto v___jp_933_;
}
else
{
uint8_t v___x_949_; 
v___x_949_ = lean_uint64_dec_lt(v___x_947_, v_maxDirectStaleSecs_903_);
if (v___x_949_ == 0)
{
v___y_934_ = v___x_949_;
goto v___jp_933_;
}
else
{
uint64_t v___x_950_; uint8_t v___x_951_; 
v___x_950_ = 86400ULL;
v___x_951_ = lean_uint64_dec_le(v_maxDirectStaleSecs_903_, v___x_950_);
if (v___x_951_ == 0)
{
v___y_934_ = v___x_951_;
goto v___jp_933_;
}
else
{
uint8_t v___x_952_; 
v___x_952_ = lean_uint64_dec_le(v_directHandshakeAt_902_, v_nowEpoch_901_);
if (v___x_952_ == 0)
{
v___y_934_ = v___x_952_;
goto v___jp_933_;
}
else
{
uint64_t v___x_953_; uint8_t v___x_954_; 
v___x_953_ = lean_uint64_sub(v_nowEpoch_901_, v_directHandshakeAt_902_);
v___x_954_ = lean_uint64_dec_le(v___x_953_, v_maxDirectStaleSecs_903_);
v___y_934_ = v___x_954_;
goto v___jp_933_;
}
}
}
}
v___jp_904_:
{
uint8_t v___x_905_; 
v___x_905_ = lean_uint32_dec_lt(v_activeRelaySessions_899_, v_maxRelaySessions_900_);
if (v___x_905_ == 0)
{
uint8_t v___x_906_; 
v___x_906_ = 0;
return v___x_906_;
}
else
{
uint8_t v___x_907_; 
v___x_907_ = 3;
return v___x_907_;
}
}
v___jp_908_:
{
uint8_t v___x_910_; 
v___x_910_ = lean_uint32_dec_eq(v_relayId_898_, v_dstId_897_);
if (v___x_910_ == 0)
{
goto v___jp_904_;
}
else
{
if (v___y_909_ == 0)
{
uint8_t v___x_911_; 
v___x_911_ = 0;
return v___x_911_;
}
else
{
goto v___jp_904_;
}
}
}
v___jp_912_:
{
uint8_t v___x_914_; 
v___x_914_ = lean_uint32_dec_eq(v_relayId_898_, v_srcId_896_);
if (v___x_914_ == 0)
{
v___y_909_ = v___y_913_;
goto v___jp_908_;
}
else
{
if (v___y_913_ == 0)
{
uint8_t v___x_915_; 
v___x_915_ = 0;
return v___x_915_;
}
else
{
v___y_909_ = v___y_913_;
goto v___jp_908_;
}
}
}
v___jp_916_:
{
if (v___y_918_ == 0)
{
uint8_t v___x_919_; 
v___x_919_ = 0;
return v___x_919_;
}
else
{
v___y_913_ = v___y_917_;
goto v___jp_912_;
}
}
v___jp_920_:
{
uint8_t v___x_925_; 
v___x_925_ = lean_uint8_dec_eq(v_relayHealthy_895_, v___y_922_);
if (v___x_925_ == 0)
{
v___y_917_ = v___y_924_;
v___y_918_ = v___y_921_;
goto v___jp_916_;
}
else
{
uint8_t v___x_926_; 
v___x_926_ = lean_uint32_dec_eq(v_relayId_898_, v___y_923_);
if (v___x_926_ == 0)
{
v___y_913_ = v___y_924_;
goto v___jp_912_;
}
else
{
v___y_917_ = v___y_924_;
v___y_918_ = v___y_924_;
goto v___jp_916_;
}
}
}
v___jp_927_:
{
uint8_t v___x_932_; 
v___x_932_ = lean_uint8_dec_eq(v_wanReachable_894_, v___y_929_);
if (v___x_932_ == 0)
{
v___y_921_ = v___y_928_;
v___y_922_ = v___y_929_;
v___y_923_ = v___y_931_;
v___y_924_ = v___y_928_;
goto v___jp_920_;
}
else
{
if (v___y_930_ == 0)
{
v___y_921_ = v___y_928_;
v___y_922_ = v___y_929_;
v___y_923_ = v___y_931_;
v___y_924_ = v___y_930_;
goto v___jp_920_;
}
else
{
return v___y_929_;
}
}
}
v___jp_933_:
{
uint8_t v___x_935_; uint8_t v___x_936_; 
v___x_935_ = 1;
v___x_936_ = lean_uint8_dec_eq(v_routeAllowed_892_, v___x_935_);
if (v___x_936_ == 0)
{
uint8_t v___x_937_; 
v___x_937_ = 0;
return v___x_937_;
}
else
{
uint32_t v___x_938_; uint8_t v___x_939_; 
v___x_938_ = 0;
v___x_939_ = lean_uint32_dec_eq(v_srcId_896_, v___x_938_);
if (v___x_939_ == 0)
{
uint8_t v___x_940_; 
v___x_940_ = lean_uint32_dec_eq(v_dstId_897_, v___x_938_);
if (v___x_940_ == 0)
{
uint8_t v___x_941_; 
v___x_941_ = lean_uint32_dec_eq(v_srcId_896_, v_dstId_897_);
if (v___x_941_ == 0)
{
uint8_t v___x_942_; 
v___x_942_ = lean_uint8_dec_eq(v_lanReachable_893_, v___x_935_);
if (v___x_942_ == 0)
{
v___y_928_ = v___x_941_;
v___y_929_ = v___x_935_;
v___y_930_ = v___y_934_;
v___y_931_ = v___x_938_;
goto v___jp_927_;
}
else
{
if (v___y_934_ == 0)
{
v___y_928_ = v___x_941_;
v___y_929_ = v___x_935_;
v___y_930_ = v___y_934_;
v___y_931_ = v___x_938_;
goto v___jp_927_;
}
else
{
uint8_t v___x_943_; 
v___x_943_ = 2;
return v___x_943_;
}
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
v___x_946_ = 0;
return v___x_946_;
}
}
}
}
}

LEAN_EXPORT uint32_t leanmesh_bunker_isolate_step(uint8_t v_currentState_1114_, uint8_t v_isSovereignNode_1115_, uint8_t v_canaryTripped_1116_, uint8_t v_authFailureBurst_1117_, uint8_t v_manualTrigger_1118_, uint8_t v_biometricUnbunker_1119_, uint8_t v_heartbeatValid_1120_, uint64_t v_nowEpoch_1121_, uint64_t v_lastHeartbeatAt_1122_, uint64_t v_deadManTimeoutSecs_1123_){
{
uint32_t v___y_1125_; uint8_t v___y_1129_; uint32_t v___y_1130_; uint8_t v___y_1131_; uint8_t v___y_1132_; uint32_t v___y_1133_; uint8_t v___y_1139_; uint8_t v___y_1140_; uint32_t v___y_1141_; uint32_t v___y_1142_; uint8_t v___y_1149_; uint8_t v___y_1156_; uint8_t v___y_1157_; uint8_t v___y_1160_; uint8_t v___y_1163_; uint8_t v___y_1164_; uint8_t v___y_1173_; uint8_t v___y_1174_; uint8_t v___y_1185_; uint8_t v___x_1189_; uint8_t v___x_1190_; 
v___x_1189_ = 0;
v___x_1190_ = lean_uint8_dec_eq(v_currentState_1114_, v___x_1189_);
if (v___x_1190_ == 0)
{
uint8_t v___x_1191_; uint8_t v___x_1192_; 
v___x_1191_ = 1;
v___x_1192_ = lean_uint8_dec_eq(v_currentState_1114_, v___x_1191_);
if (v___x_1192_ == 0)
{
uint8_t v___x_1193_; uint8_t v___x_1194_; 
v___x_1193_ = 2;
v___x_1194_ = lean_uint8_dec_eq(v_currentState_1114_, v___x_1193_);
if (v___x_1194_ == 0)
{
uint8_t v___x_1195_; 
v___x_1195_ = 3;
v___y_1185_ = v___x_1195_;
goto v___jp_1184_;
}
else
{
v___y_1185_ = v___x_1193_;
goto v___jp_1184_;
}
}
else
{
v___y_1185_ = v___x_1191_;
goto v___jp_1184_;
}
}
else
{
v___y_1185_ = v___x_1189_;
goto v___jp_1184_;
}
v___jp_1124_:
{
uint32_t v___x_1126_; uint32_t v___x_1127_; 
v___x_1126_ = 16777216;
v___x_1127_ = lean_uint32_lor(v___y_1125_, v___x_1126_);
return v___x_1127_;
}
v___jp_1128_:
{
uint32_t v___x_1134_; uint8_t v___x_1135_; uint8_t v___x_1136_; 
v___x_1134_ = lean_uint32_lor(v___y_1130_, v___y_1133_);
v___x_1135_ = 3;
v___x_1136_ = lean_uint8_dec_eq(v___y_1129_, v___x_1135_);
if (v___x_1136_ == 0)
{
uint8_t v___x_1137_; 
v___x_1137_ = lean_uint8_dec_eq(v_isSovereignNode_1115_, v___y_1132_);
if (v___x_1137_ == 0)
{
return v___x_1134_;
}
else
{
if (v___y_1131_ == 0)
{
return v___x_1134_;
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
v___y_1125_ = v___x_1134_;
goto v___jp_1124_;
}
}
v___jp_1138_:
{
uint32_t v___x_1143_; uint8_t v___x_1144_; uint8_t v___x_1145_; 
v___x_1143_ = lean_uint32_lor(v___y_1141_, v___y_1142_);
v___x_1144_ = 2;
v___x_1145_ = lean_uint8_dec_le(v___x_1144_, v___y_1139_);
if (v___x_1145_ == 0)
{
uint32_t v___x_1146_; 
v___x_1146_ = 0;
v___y_1129_ = v___y_1139_;
v___y_1130_ = v___x_1143_;
v___y_1131_ = v___x_1145_;
v___y_1132_ = v___y_1140_;
v___y_1133_ = v___x_1146_;
goto v___jp_1128_;
}
else
{
uint32_t v___x_1147_; 
v___x_1147_ = 65536;
v___y_1129_ = v___y_1139_;
v___y_1130_ = v___x_1143_;
v___y_1131_ = v___x_1145_;
v___y_1132_ = v___y_1140_;
v___y_1133_ = v___x_1147_;
goto v___jp_1128_;
}
}
v___jp_1148_:
{
uint32_t v___x_1150_; uint8_t v___x_1151_; uint8_t v___x_1152_; 
v___x_1150_ = lean_uint8_to_uint32(v___y_1149_);
v___x_1151_ = 1;
v___x_1152_ = lean_uint8_dec_le(v___x_1151_, v___y_1149_);
if (v___x_1152_ == 0)
{
uint32_t v___x_1153_; 
v___x_1153_ = 0;
v___y_1139_ = v___y_1149_;
v___y_1140_ = v___x_1151_;
v___y_1141_ = v___x_1150_;
v___y_1142_ = v___x_1153_;
goto v___jp_1138_;
}
else
{
uint32_t v___x_1154_; 
v___x_1154_ = 256;
v___y_1139_ = v___y_1149_;
v___y_1140_ = v___x_1151_;
v___y_1141_ = v___x_1150_;
v___y_1142_ = v___x_1154_;
goto v___jp_1138_;
}
}
v___jp_1155_:
{
uint8_t v___x_1158_; 
v___x_1158_ = lean_uint8_dec_le(v___y_1156_, v___y_1157_);
if (v___x_1158_ == 0)
{
v___y_1149_ = v___y_1156_;
goto v___jp_1148_;
}
else
{
v___y_1149_ = v___y_1157_;
goto v___jp_1148_;
}
}
v___jp_1159_:
{
uint8_t v___x_1161_; 
v___x_1161_ = 3;
v___y_1156_ = v___y_1160_;
v___y_1157_ = v___x_1161_;
goto v___jp_1155_;
}
v___jp_1162_:
{
uint8_t v___x_1165_; 
v___x_1165_ = lean_uint8_dec_eq(v_canaryTripped_1116_, v___y_1163_);
if (v___x_1165_ == 0)
{
uint8_t v___x_1166_; uint8_t v___x_1167_; 
v___x_1166_ = 2;
v___x_1167_ = lean_uint8_dec_eq(v_manualTrigger_1118_, v___x_1166_);
if (v___x_1167_ == 0)
{
uint8_t v___x_1168_; 
v___x_1168_ = lean_uint8_dec_eq(v_authFailureBurst_1117_, v___y_1163_);
if (v___x_1168_ == 0)
{
uint8_t v___x_1169_; 
v___x_1169_ = lean_uint8_dec_eq(v_manualTrigger_1118_, v___y_1163_);
if (v___x_1169_ == 0)
{
uint8_t v___x_1170_; 
v___x_1170_ = 0;
v___y_1156_ = v___y_1164_;
v___y_1157_ = v___x_1170_;
goto v___jp_1155_;
}
else
{
v___y_1156_ = v___y_1164_;
v___y_1157_ = v___y_1163_;
goto v___jp_1155_;
}
}
else
{
v___y_1156_ = v___y_1164_;
v___y_1157_ = v___y_1163_;
goto v___jp_1155_;
}
}
else
{
v___y_1156_ = v___y_1164_;
v___y_1157_ = v___x_1166_;
goto v___jp_1155_;
}
}
else
{
uint8_t v___x_1171_; 
v___x_1171_ = 2;
v___y_1156_ = v___y_1164_;
v___y_1157_ = v___x_1171_;
goto v___jp_1155_;
}
}
v___jp_1172_:
{
uint8_t v___x_1175_; uint8_t v___x_1176_; 
v___x_1175_ = 3;
v___x_1176_ = lean_uint8_dec_eq(v_manualTrigger_1118_, v___x_1175_);
if (v___x_1176_ == 0)
{
uint8_t v___x_1177_; 
v___x_1177_ = lean_uint8_dec_eq(v_isSovereignNode_1115_, v___y_1173_);
if (v___x_1177_ == 0)
{
v___y_1163_ = v___y_1173_;
v___y_1164_ = v___y_1174_;
goto v___jp_1162_;
}
else
{
uint8_t v___x_1178_; 
v___x_1178_ = lean_uint8_dec_eq(v_heartbeatValid_1120_, v___y_1173_);
if (v___x_1178_ == 0)
{
v___y_1160_ = v___y_1174_;
goto v___jp_1159_;
}
else
{
uint64_t v___x_1179_; uint8_t v___x_1180_; 
v___x_1179_ = 0ULL;
v___x_1180_ = lean_uint64_dec_eq(v_deadManTimeoutSecs_1123_, v___x_1179_);
if (v___x_1180_ == 0)
{
uint8_t v___x_1181_; 
v___x_1181_ = lean_uint64_dec_lt(v_nowEpoch_1121_, v_lastHeartbeatAt_1122_);
if (v___x_1181_ == 0)
{
uint64_t v___x_1182_; uint8_t v___x_1183_; 
v___x_1182_ = lean_uint64_sub(v_nowEpoch_1121_, v_lastHeartbeatAt_1122_);
v___x_1183_ = lean_uint64_dec_le(v_deadManTimeoutSecs_1123_, v___x_1182_);
if (v___x_1183_ == 0)
{
v___y_1163_ = v___y_1173_;
v___y_1164_ = v___y_1174_;
goto v___jp_1162_;
}
else
{
v___y_1160_ = v___y_1174_;
goto v___jp_1159_;
}
}
else
{
v___y_1160_ = v___y_1174_;
goto v___jp_1159_;
}
}
else
{
v___y_1160_ = v___y_1174_;
goto v___jp_1159_;
}
}
}
}
else
{
v___y_1160_ = v___y_1174_;
goto v___jp_1159_;
}
}
v___jp_1184_:
{
uint8_t v___x_1186_; uint8_t v___x_1187_; 
v___x_1186_ = 1;
v___x_1187_ = lean_uint8_dec_eq(v_biometricUnbunker_1119_, v___x_1186_);
if (v___x_1187_ == 0)
{
v___y_1173_ = v___x_1186_;
v___y_1174_ = v___y_1185_;
goto v___jp_1172_;
}
else
{
uint8_t v___x_1188_; 
v___x_1188_ = 0;
v___y_1173_ = v___x_1186_;
v___y_1174_ = v___x_1188_;
goto v___jp_1172_;
}
}
}
}

LEAN_EXPORT uint8_t leanmesh_frame_bounds_step(uint32_t v_magic_1218_, uint8_t v_version_1219_, uint8_t v_frameKind_1220_, uint8_t v_tagVerified_1221_, uint64_t v_headerLen_1222_, uint64_t v_payloadLen_1223_, uint64_t v_maxFrameBytes_1224_, uint64_t v_bufCap_1225_){
{
uint32_t v___x_1226_; uint8_t v___x_1227_; 
v___x_1226_ = 1280136008;
v___x_1227_ = lean_uint32_dec_eq(v_magic_1218_, v___x_1226_);
if (v___x_1227_ == 0)
{
uint8_t v___x_1228_; 
v___x_1228_ = 0;
return v___x_1228_;
}
else
{
uint8_t v___x_1229_; uint8_t v___x_1230_; 
v___x_1229_ = 1;
v___x_1230_ = lean_uint8_dec_eq(v_version_1219_, v___x_1229_);
if (v___x_1230_ == 0)
{
uint8_t v___x_1231_; 
v___x_1231_ = 0;
return v___x_1231_;
}
else
{
uint8_t v___x_1232_; 
v___x_1232_ = lean_uint8_dec_le(v___x_1229_, v_frameKind_1220_);
if (v___x_1232_ == 0)
{
uint8_t v___x_1233_; 
v___x_1233_ = 0;
return v___x_1233_;
}
else
{
uint8_t v___x_1234_; uint8_t v___x_1235_; 
v___x_1234_ = 6;
v___x_1235_ = lean_uint8_dec_le(v_frameKind_1220_, v___x_1234_);
if (v___x_1235_ == 0)
{
uint8_t v___x_1236_; 
v___x_1236_ = 0;
return v___x_1236_;
}
else
{
uint8_t v___x_1237_; 
v___x_1237_ = lean_uint8_dec_eq(v_tagVerified_1221_, v___x_1229_);
if (v___x_1237_ == 0)
{
uint8_t v___x_1238_; 
v___x_1238_ = 0;
return v___x_1238_;
}
else
{
uint64_t v___x_1239_; uint8_t v___x_1240_; 
v___x_1239_ = 32ULL;
v___x_1240_ = lean_uint64_dec_le(v___x_1239_, v_headerLen_1222_);
if (v___x_1240_ == 0)
{
uint8_t v___x_1241_; 
v___x_1241_ = 0;
return v___x_1241_;
}
else
{
uint8_t v___x_1242_; 
v___x_1242_ = lean_uint64_dec_le(v_maxFrameBytes_1224_, v_bufCap_1225_);
if (v___x_1242_ == 0)
{
uint8_t v___x_1243_; 
v___x_1243_ = 0;
return v___x_1243_;
}
else
{
uint8_t v___x_1244_; 
v___x_1244_ = lean_uint64_dec_le(v_headerLen_1222_, v_maxFrameBytes_1224_);
if (v___x_1244_ == 0)
{
uint8_t v___x_1245_; 
v___x_1245_ = 0;
return v___x_1245_;
}
else
{
uint64_t v___x_1246_; uint8_t v___x_1247_; 
v___x_1246_ = lean_uint64_sub(v_maxFrameBytes_1224_, v_headerLen_1222_);
v___x_1247_ = lean_uint64_dec_le(v_payloadLen_1223_, v___x_1246_);
if (v___x_1247_ == 0)
{
uint8_t v___x_1248_; 
v___x_1248_ = 0;
return v___x_1248_;
}
else
{
return v___x_1229_;
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

LEAN_EXPORT uint8_t leanmesh_overlay_ip_step(uint32_t v_peerIdA_1276_, uint32_t v_peerIdB_1277_, uint32_t v_ipA_1278_, uint32_t v_ipB_1279_, uint8_t v_prefixLenA_1280_, uint8_t v_prefixLenB_1281_){
{
uint32_t v___x_1282_; uint8_t v___x_1283_; 
v___x_1282_ = 0;
v___x_1283_ = lean_uint32_dec_eq(v_peerIdA_1276_, v___x_1282_);
if (v___x_1283_ == 0)
{
uint8_t v___x_1284_; 
v___x_1284_ = lean_uint32_dec_eq(v_peerIdB_1277_, v___x_1282_);
if (v___x_1284_ == 0)
{
uint8_t v___x_1285_; 
v___x_1285_ = lean_uint32_dec_eq(v_peerIdA_1276_, v_peerIdB_1277_);
if (v___x_1285_ == 0)
{
uint32_t v___x_1286_; uint8_t v___x_1287_; 
v___x_1286_ = 173539329;
v___x_1287_ = lean_uint32_dec_le(v___x_1286_, v_ipA_1278_);
if (v___x_1287_ == 0)
{
uint8_t v___x_1288_; 
v___x_1288_ = 0;
return v___x_1288_;
}
else
{
uint32_t v___x_1289_; uint8_t v___x_1290_; 
v___x_1289_ = 173604862;
v___x_1290_ = lean_uint32_dec_le(v_ipA_1278_, v___x_1289_);
if (v___x_1290_ == 0)
{
uint8_t v___x_1291_; 
v___x_1291_ = 0;
return v___x_1291_;
}
else
{
uint8_t v___x_1292_; 
v___x_1292_ = lean_uint32_dec_le(v___x_1286_, v_ipB_1279_);
if (v___x_1292_ == 0)
{
uint8_t v___x_1293_; 
v___x_1293_ = 0;
return v___x_1293_;
}
else
{
uint8_t v___x_1294_; 
v___x_1294_ = lean_uint32_dec_le(v_ipB_1279_, v___x_1289_);
if (v___x_1294_ == 0)
{
uint8_t v___x_1295_; 
v___x_1295_ = 0;
return v___x_1295_;
}
else
{
uint8_t v___x_1296_; uint8_t v___x_1297_; 
v___x_1296_ = 32;
v___x_1297_ = lean_uint8_dec_eq(v_prefixLenA_1280_, v___x_1296_);
if (v___x_1297_ == 0)
{
uint8_t v___x_1298_; 
v___x_1298_ = 0;
return v___x_1298_;
}
else
{
uint8_t v___x_1299_; 
v___x_1299_ = lean_uint8_dec_eq(v_prefixLenB_1281_, v___x_1296_);
if (v___x_1299_ == 0)
{
uint8_t v___x_1300_; 
v___x_1300_ = 0;
return v___x_1300_;
}
else
{
uint8_t v___x_1301_; 
v___x_1301_ = lean_uint32_dec_eq(v_ipA_1278_, v_ipB_1279_);
if (v___x_1301_ == 0)
{
uint8_t v___x_1302_; 
v___x_1302_ = 1;
return v___x_1302_;
}
else
{
uint8_t v___x_1303_; 
v___x_1303_ = 0;
return v___x_1303_;
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
uint8_t v___x_1304_; 
v___x_1304_ = 0;
return v___x_1304_;
}
}
else
{
uint8_t v___x_1305_; 
v___x_1305_ = 0;
return v___x_1305_;
}
}
else
{
uint8_t v___x_1306_; 
v___x_1306_ = 0;
return v___x_1306_;
}
}
}

LEAN_EXPORT uint8_t leanmesh_reconcile_wg_step(uint8_t v_manifestValid_1345_, uint8_t v_peerPresentInKernel_1346_, uint8_t v_peerRevoked_1347_, uint8_t v_pubkeyMatches_1348_, uint8_t v_allowedIpMatches_1349_, uint8_t v_endpointChanged_1350_, uint8_t v_bunkerPruneNonAdmin_1351_, uint8_t v_peerIsAdmin_1352_, uint64_t v_nowEpoch_1353_, uint64_t v_peerExpiresAt_1354_){
{
uint8_t v___x_1355_; uint8_t v___x_1370_; 
v___x_1355_ = 1;
v___x_1370_ = lean_uint8_dec_eq(v_manifestValid_1345_, v___x_1355_);
if (v___x_1370_ == 0)
{
uint8_t v___x_1371_; 
v___x_1371_ = 0;
return v___x_1371_;
}
else
{
uint8_t v___x_1372_; 
v___x_1372_ = lean_uint8_dec_eq(v_peerRevoked_1347_, v___x_1355_);
if (v___x_1372_ == 0)
{
uint8_t v___x_1373_; 
v___x_1373_ = lean_uint64_dec_le(v_peerExpiresAt_1354_, v_nowEpoch_1353_);
if (v___x_1373_ == 0)
{
uint8_t v___x_1374_; uint8_t v___x_1375_; 
v___x_1374_ = 2;
v___x_1375_ = lean_uint8_dec_le(v___x_1374_, v_bunkerPruneNonAdmin_1351_);
if (v___x_1375_ == 0)
{
uint8_t v___x_1376_; 
v___x_1376_ = lean_uint8_dec_eq(v_bunkerPruneNonAdmin_1351_, v___x_1355_);
if (v___x_1376_ == 0)
{
goto v___jp_1356_;
}
else
{
uint8_t v___x_1377_; 
v___x_1377_ = lean_uint8_dec_eq(v_peerIsAdmin_1352_, v___x_1355_);
if (v___x_1377_ == 0)
{
goto v___jp_1367_;
}
else
{
goto v___jp_1356_;
}
}
}
else
{
goto v___jp_1367_;
}
}
else
{
goto v___jp_1367_;
}
}
else
{
goto v___jp_1367_;
}
}
v___jp_1356_:
{
uint8_t v___x_1357_; uint8_t v___x_1358_; 
v___x_1357_ = 0;
v___x_1358_ = lean_uint8_dec_eq(v_peerPresentInKernel_1346_, v___x_1357_);
if (v___x_1358_ == 0)
{
uint8_t v___x_1359_; 
v___x_1359_ = lean_uint8_dec_eq(v_pubkeyMatches_1348_, v___x_1355_);
if (v___x_1359_ == 0)
{
uint8_t v___x_1360_; 
v___x_1360_ = 3;
return v___x_1360_;
}
else
{
uint8_t v___x_1361_; 
v___x_1361_ = lean_uint8_dec_eq(v_allowedIpMatches_1349_, v___x_1355_);
if (v___x_1361_ == 0)
{
uint8_t v___x_1362_; 
v___x_1362_ = 3;
return v___x_1362_;
}
else
{
uint8_t v___x_1363_; 
v___x_1363_ = lean_uint8_dec_eq(v_endpointChanged_1350_, v___x_1355_);
if (v___x_1363_ == 0)
{
uint8_t v___x_1364_; 
v___x_1364_ = 6;
return v___x_1364_;
}
else
{
uint8_t v___x_1365_; 
v___x_1365_ = 5;
return v___x_1365_;
}
}
}
}
else
{
uint8_t v___x_1366_; 
v___x_1366_ = 4;
return v___x_1366_;
}
}
v___jp_1367_:
{
uint8_t v___x_1368_; 
v___x_1368_ = lean_uint8_dec_eq(v_peerPresentInKernel_1346_, v___x_1355_);
if (v___x_1368_ == 0)
{
uint8_t v___x_1369_; 
v___x_1369_ = 2;
return v___x_1369_;
}
else
{
return v___x_1355_;
}
}
}
}

LEAN_EXPORT uint32_t leanmesh_jit_lease_step(uint8_t v_biometricSigValid_1420_, uint8_t v_operatorSameOwner_1421_, uint8_t v_missionActive_1422_, uint8_t v_grantRevoked_1423_, uint8_t v_bunkerState_1424_, uint8_t v_srcClass_1425_, uint8_t v_dstClass_1426_, uint64_t v_nowEpoch_1427_, uint64_t v_grantIssuedAt_1428_, uint64_t v_grantExpiresAt_1429_, uint64_t v_maxJitTtlSecs_1430_){
{
uint8_t v___x_1456_; uint8_t v___x_1457_; 
v___x_1456_ = 0;
v___x_1457_ = lean_uint8_dec_eq(v_missionActive_1422_, v___x_1456_);
if (v___x_1457_ == 0)
{
uint8_t v___x_1458_; uint8_t v___x_1459_; 
v___x_1458_ = 1;
v___x_1459_ = lean_uint8_dec_eq(v_grantRevoked_1423_, v___x_1458_);
if (v___x_1459_ == 0)
{
uint8_t v___x_1460_; 
v___x_1460_ = lean_uint8_dec_eq(v_bunkerState_1424_, v___x_1456_);
if (v___x_1460_ == 0)
{
uint32_t v___x_1461_; 
v___x_1461_ = 256;
return v___x_1461_;
}
else
{
uint8_t v___x_1462_; 
v___x_1462_ = lean_uint64_dec_le(v_grantExpiresAt_1429_, v_nowEpoch_1427_);
if (v___x_1462_ == 0)
{
uint8_t v___x_1463_; 
v___x_1463_ = lean_uint8_dec_eq(v_biometricSigValid_1420_, v___x_1458_);
if (v___x_1463_ == 0)
{
uint32_t v___x_1464_; 
v___x_1464_ = 0;
return v___x_1464_;
}
else
{
uint8_t v___x_1465_; 
v___x_1465_ = lean_uint8_dec_eq(v_operatorSameOwner_1421_, v___x_1458_);
if (v___x_1465_ == 0)
{
uint32_t v___x_1466_; 
v___x_1466_ = 0;
return v___x_1466_;
}
else
{
uint8_t v___x_1467_; uint8_t v___x_1468_; 
v___x_1467_ = 2;
v___x_1468_ = lean_uint8_dec_eq(v_srcClass_1425_, v___x_1467_);
if (v___x_1468_ == 0)
{
goto v___jp_1450_;
}
else
{
uint8_t v___x_1469_; uint8_t v___x_1470_; 
v___x_1469_ = 5;
v___x_1470_ = lean_uint8_dec_eq(v_dstClass_1426_, v___x_1469_);
if (v___x_1470_ == 0)
{
goto v___jp_1450_;
}
else
{
goto v___jp_1431_;
}
}
}
}
}
else
{
uint32_t v___x_1471_; 
v___x_1471_ = 256;
return v___x_1471_;
}
}
}
else
{
uint32_t v___x_1472_; 
v___x_1472_ = 256;
return v___x_1472_;
}
}
else
{
uint32_t v___x_1473_; 
v___x_1473_ = 256;
return v___x_1473_;
}
v___jp_1431_:
{
uint64_t v___x_1432_; uint8_t v___x_1433_; 
v___x_1432_ = 0ULL;
v___x_1433_ = lean_uint64_dec_lt(v___x_1432_, v_maxJitTtlSecs_1430_);
if (v___x_1433_ == 0)
{
uint32_t v___x_1434_; 
v___x_1434_ = 0;
return v___x_1434_;
}
else
{
uint64_t v___x_1435_; uint8_t v___x_1436_; 
v___x_1435_ = 14400ULL;
v___x_1436_ = lean_uint64_dec_le(v_maxJitTtlSecs_1430_, v___x_1435_);
if (v___x_1436_ == 0)
{
uint32_t v___x_1437_; 
v___x_1437_ = 0;
return v___x_1437_;
}
else
{
uint8_t v___x_1438_; 
v___x_1438_ = lean_uint64_dec_le(v_grantIssuedAt_1428_, v_nowEpoch_1427_);
if (v___x_1438_ == 0)
{
uint32_t v___x_1439_; 
v___x_1439_ = 0;
return v___x_1439_;
}
else
{
uint8_t v___x_1440_; 
v___x_1440_ = lean_uint64_dec_lt(v_grantIssuedAt_1428_, v_grantExpiresAt_1429_);
if (v___x_1440_ == 0)
{
uint32_t v___x_1441_; 
v___x_1441_ = 0;
return v___x_1441_;
}
else
{
uint64_t v___x_1442_; uint8_t v___x_1443_; 
v___x_1442_ = lean_uint64_sub(v_grantExpiresAt_1429_, v_grantIssuedAt_1428_);
v___x_1443_ = lean_uint64_dec_le(v___x_1442_, v_maxJitTtlSecs_1430_);
if (v___x_1443_ == 0)
{
uint32_t v___x_1444_; 
v___x_1444_ = 0;
return v___x_1444_;
}
else
{
uint32_t v___x_1445_; 
v___x_1445_ = 1;
return v___x_1445_;
}
}
}
}
}
}
v___jp_1446_:
{
uint8_t v___x_1447_; uint8_t v___x_1448_; 
v___x_1447_ = 3;
v___x_1448_ = lean_uint8_dec_eq(v_dstClass_1426_, v___x_1447_);
if (v___x_1448_ == 0)
{
uint32_t v___x_1449_; 
v___x_1449_ = 0;
return v___x_1449_;
}
else
{
goto v___jp_1431_;
}
}
v___jp_1450_:
{
uint8_t v___x_1451_; uint8_t v___x_1452_; 
v___x_1451_ = 0;
v___x_1452_ = lean_uint8_dec_eq(v_srcClass_1425_, v___x_1451_);
if (v___x_1452_ == 0)
{
uint8_t v___x_1453_; uint8_t v___x_1454_; 
v___x_1453_ = 1;
v___x_1454_ = lean_uint8_dec_eq(v_srcClass_1425_, v___x_1453_);
if (v___x_1454_ == 0)
{
uint32_t v___x_1455_; 
v___x_1455_ = 0;
return v___x_1455_;
}
else
{
goto v___jp_1446_;
}
}
else
{
goto v___jp_1446_;
}
}
}
}
