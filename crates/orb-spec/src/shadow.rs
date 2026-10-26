//! Phase 0 (`0A` & `0C`): `OrbWire` Canonical Word+Arena Wire Codec, `EventContext`,
//! `RefinementSimulation`, and Bounded `ShadowRunner` Harness.
//!
//! All frame bounds, arena offsets, schema migrations, and effect safety preconditions are
//! gated by the freestanding Lean 4 C-ABI exports (`orb_wire_validate_frame`,
//! `orb_wire_pack_record`, `orb_wire_schema_migrate_step`, `orb_effect_admissible`).

use crate::{
    effect_admissible, wire_pack_record, wire_schema_migrate_step, wire_unpack_record,
    wire_validate_frame, EffectAdmissibleInput, OrbWireRecordWord, OrbWireStatus, WireFrameInput,
};

pub const ORB_WIRE_MAGIC: u32 = 0x4F52_4257; // "ORBW"
pub const ORB_WIRE_ABI_VERSION: u32 = 1;
pub const ORB_WIRE_HEADER_BYTES: usize = 24;
pub const ORB_WIRE_DEFAULT_MAX_BUDGET: u32 = 65_536;

/// Canonical 24-byte little-endian `OrbWire` frame header.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct OrbWireHeader {
    pub magic: u32,
    pub abi_version: u16,
    pub schema_id: u16,
    pub flags: u32,
    pub total_len: u32,
    pub payload_len: u32,
    pub arena_off: u16,
    pub arena_len: u16,
}

impl OrbWireHeader {
    pub fn to_le_bytes(self) -> [u8; ORB_WIRE_HEADER_BYTES] {
        let mut out = [0u8; ORB_WIRE_HEADER_BYTES];
        out[0..4].copy_from_slice(&self.magic.to_le_bytes());
        out[4..6].copy_from_slice(&self.abi_version.to_le_bytes());
        out[6..8].copy_from_slice(&self.schema_id.to_le_bytes());
        out[8..12].copy_from_slice(&self.flags.to_le_bytes());
        out[12..16].copy_from_slice(&self.total_len.to_le_bytes());
        out[16..20].copy_from_slice(&self.payload_len.to_le_bytes());
        out[20..22].copy_from_slice(&self.arena_off.to_le_bytes());
        out[22..24].copy_from_slice(&self.arena_len.to_le_bytes());
        out
    }

    pub fn from_le_bytes(bytes: &[u8]) -> Option<Self> {
        if bytes.len() < ORB_WIRE_HEADER_BYTES {
            return None;
        }
        Some(Self {
            magic: u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]),
            abi_version: u16::from_le_bytes([bytes[4], bytes[5]]),
            schema_id: u16::from_le_bytes([bytes[6], bytes[7]]),
            flags: u32::from_le_bytes([bytes[8], bytes[9], bytes[10], bytes[11]]),
            total_len: u32::from_le_bytes([bytes[12], bytes[13], bytes[14], bytes[15]]),
            payload_len: u32::from_le_bytes([bytes[16], bytes[17], bytes[18], bytes[19]]),
            arena_off: u16::from_le_bytes([bytes[20], bytes[21]]),
            arena_len: u16::from_le_bytes([bytes[22], bytes[23]]),
        })
    }
}

/// Canonical `OrbWire` frame consisting of 64-bit packed record words + contiguous byte arena.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OrbWireFrame {
    pub schema_id: u16,
    pub flags: u32,
    pub records: Vec<OrbWireRecordWord>,
    pub arena: Vec<u8>,
}

impl OrbWireFrame {
    /// Encodes `self` into caller-supplied `out_buf` without partial mutation on error
    /// (`encode_failure_no_partial_mutation`).
    pub fn encode_into(
        &self,
        out_buf: &mut [u8],
        max_budget_bytes: u32,
    ) -> Result<usize, OrbWireStatus> {
        let records_bytes = self.records.len().saturating_mul(8);
        let arena_bytes = self.arena.len();
        let payload_len = records_bytes.saturating_add(arena_bytes);
        let total_len = ORB_WIRE_HEADER_BYTES.saturating_add(payload_len);

        if records_bytes > u16::MAX as usize
            || arena_bytes > u16::MAX as usize
            || total_len > u32::MAX as usize
        {
            return Err(OrbWireStatus::TruncatedOrOutOfBounds);
        }

        let status = wire_validate_frame(WireFrameInput {
            magic: ORB_WIRE_MAGIC,
            abi_version: ORB_WIRE_ABI_VERSION,
            schema_id: u32::from(self.schema_id),
            expected_schema_id: u32::from(self.schema_id),
            total_len: total_len as u32,
            payload_len: payload_len as u32,
            arena_off: records_bytes as u32,
            arena_len: arena_bytes as u32,
            max_budget_bytes,
            out_cap: out_buf.len().min(u32::MAX as usize) as u32,
            required_out_bytes: total_len as u32,
        });
        if status != OrbWireStatus::Ok {
            return Err(status);
        }

        let hdr = OrbWireHeader {
            magic: ORB_WIRE_MAGIC,
            abi_version: ORB_WIRE_ABI_VERSION as u16,
            schema_id: self.schema_id,
            flags: self.flags,
            total_len: total_len as u32,
            payload_len: payload_len as u32,
            arena_off: records_bytes as u16,
            arena_len: arena_bytes as u16,
        };
        out_buf[..ORB_WIRE_HEADER_BYTES].copy_from_slice(&hdr.to_le_bytes());

        let mut cursor = ORB_WIRE_HEADER_BYTES;
        for rec in &self.records {
            let word = wire_pack_record(*rec);
            out_buf[cursor..cursor + 8].copy_from_slice(&word.to_le_bytes());
            cursor += 8;
        }
        out_buf[cursor..cursor + arena_bytes].copy_from_slice(&self.arena);
        Ok(total_len)
    }

    /// Total, bounded decoder backed by `orb_wire_validate_frame`. Never panics on malformed bytes.
    pub fn decode(
        bytes: &[u8],
        expected_schema_id: u16,
        max_budget_bytes: u32,
    ) -> Result<Self, OrbWireStatus> {
        let Some(hdr) = OrbWireHeader::from_le_bytes(bytes) else {
            return Err(OrbWireStatus::TruncatedOrOutOfBounds);
        };
        if bytes.len() != hdr.total_len as usize {
            let status = wire_validate_frame(WireFrameInput {
                magic: hdr.magic,
                abi_version: u32::from(hdr.abi_version),
                schema_id: u32::from(hdr.schema_id),
                expected_schema_id: u32::from(expected_schema_id),
                total_len: bytes.len().min(u32::MAX as usize) as u32,
                payload_len: hdr.payload_len,
                arena_off: u32::from(hdr.arena_off),
                arena_len: u32::from(hdr.arena_len),
                max_budget_bytes,
                out_cap: u32::MAX,
                required_out_bytes: 0,
            });
            return Err(if status == OrbWireStatus::Ok {
                OrbWireStatus::TruncatedOrOutOfBounds
            } else {
                status
            });
        }

        let status = wire_validate_frame(WireFrameInput {
            magic: hdr.magic,
            abi_version: u32::from(hdr.abi_version),
            schema_id: u32::from(hdr.schema_id),
            expected_schema_id: u32::from(expected_schema_id),
            total_len: hdr.total_len,
            payload_len: hdr.payload_len,
            arena_off: u32::from(hdr.arena_off),
            arena_len: u32::from(hdr.arena_len),
            max_budget_bytes,
            out_cap: u32::MAX,
            required_out_bytes: 0,
        });
        if status != OrbWireStatus::Ok {
            return Err(status);
        }

        let arena_off = hdr.arena_off as usize;
        let arena_len = hdr.arena_len as usize;
        if arena_off % 8 != 0 || arena_off.saturating_add(arena_len) != hdr.payload_len as usize {
            return Err(OrbWireStatus::TruncatedOrOutOfBounds);
        }

        let payload = &bytes[ORB_WIRE_HEADER_BYTES..ORB_WIRE_HEADER_BYTES + hdr.payload_len as usize];
        let records_slice = &payload[..arena_off];
        let arena_slice = &payload[arena_off..arena_off + arena_len];

        let mut records = Vec::with_capacity(records_slice.len() / 8);
        for chunk in records_slice.chunks_exact(8) {
            let word = u64::from_le_bytes([
                chunk[0], chunk[1], chunk[2], chunk[3], chunk[4], chunk[5], chunk[6], chunk[7],
            ]);
            records.push(wire_unpack_record(word));
        }

        Ok(Self {
            schema_id: hdr.schema_id,
            flags: hdr.flags,
            records,
            arena: arena_slice.to_vec(),
        })
    }

    /// Reads an arena slice referenced by `(offset, len)` inside a record's `payload32` & `len16`.
    pub fn arena_slice(&self, offset: u32, len: u16) -> Option<&[u8]> {
        let start = offset as usize;
        let end = start.checked_add(len as usize)?;
        self.arena.get(start..end)
    }

    /// Validates whether this frame's `schema_id` may migrate to `target_schema_id` under `max_bytes`.
    pub fn can_migrate_to(&self, target_schema_id: u16, max_bytes: u64) -> bool {
        let payload_bytes = (self.records.len() * 8 + self.arena.len()) as u64;
        wire_schema_migrate_step(
            u32::from(self.schema_id),
            u32::from(target_schema_id),
            u32::from(self.schema_id),
            payload_bytes,
            max_bytes,
        )
    }
}

/// Explicit clock & non-determinism envelope injected identically into Legacy Rust and Lean `step`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EventContext {
    pub now_ms: u64,
    pub fresh_nonce: u64,
    pub idempotency_key: u64,
    pub boot_id_matches: bool,
    pub schema_id: u16,
}

/// Classification of a comparison between the Legacy Rust path and the verified Lean `step`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DivergenceKind {
    ExactMatch,
    /// Legacy Rust exhibited a known historical bug that the Lean specification provably blocks.
    LegacyBugFixedByLean(&'static str),
    /// Unexpected mismatch requiring investigation before cutover.
    LeanBug,
    /// Effects are identical up to permutation (non-canonical map iteration in Legacy Rust).
    OrderingNondeterminism,
    /// Wire encoding/decoding failed before comparison.
    SerializationMismatch,
}

/// One recorded shadow comparison entry for `var/log/orb/shadow_divergences.jsonl`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ShadowDivergenceEntry {
    pub subsystem: &'static str,
    pub ctx: EventContext,
    pub kind: DivergenceKind,
    pub state_summary: String,
    pub event_summary: String,
    pub rust_effects_summary: String,
    pub lean_effects_summary: String,
}

impl ShadowDivergenceEntry {
    pub fn to_jsonl_line(&self) -> String {
        let kind_str = match self.kind {
            DivergenceKind::ExactMatch => "exact_match".to_string(),
            DivergenceKind::LegacyBugFixedByLean(tag) => format!("legacy_bug_fixed_by_lean:{tag}"),
            DivergenceKind::LeanBug => "lean_bug".to_string(),
            DivergenceKind::OrderingNondeterminism => "ordering_nondeterminism".to_string(),
            DivergenceKind::SerializationMismatch => "serialization_mismatch".to_string(),
        };
        format!(
            "{{\"subsystem\":\"{}\",\"now_ms\":{},\"idempotency_key\":{},\"kind\":\"{}\",\"state\":\"{}\",\"event\":\"{}\",\"rust_effects\":\"{}\",\"lean_effects\":\"{}\"}}",
            self.subsystem,
            self.ctx.now_ms,
            self.ctx.idempotency_key,
            kind_str,
            self.state_summary.replace('"', "'"),
            self.event_summary.replace('"', "'"),
            self.rust_effects_summary.replace('"', "'"),
            self.lean_effects_summary.replace('"', "'"),
        )
    }

    /// Generates a Lean 4 `#guard` regression snippet from a captured shadow divergence.
    pub fn to_lean_regression_guard(&self, fn_call_expr: &str, expected_lean_expr: &str) -> String {
        format!(
            "/-- Auto-extracted shadow regression ({}): {} -/\n#guard ({}) == ({})",
            self.subsystem, self.event_summary, fn_call_expr, expected_lean_expr
        )
    }
}

/// Bounded ring buffer of shadow divergences (`ConservedResource`: never grows unboundedly).
#[derive(Debug, Clone)]
pub struct ShadowDivergenceRing<const CAP: usize> {
    entries: Vec<ShadowDivergenceEntry>,
    write_cursor: usize,
    pub total_events: u64,
    pub exact_matches: u64,
    pub legacy_bugs_caught: u64,
    pub unexpected_divergences: u64,
}

impl<const CAP: usize> Default for ShadowDivergenceRing<CAP> {
    fn default() -> Self {
        Self::new()
    }
}

impl<const CAP: usize> ShadowDivergenceRing<CAP> {
    pub const fn new() -> Self {
        Self {
            entries: Vec::new(),
            write_cursor: 0,
            total_events: 0,
            exact_matches: 0,
            legacy_bugs_caught: 0,
            unexpected_divergences: 0,
        }
    }

    pub fn record(&mut self, entry: ShadowDivergenceEntry) {
        self.total_events = self.total_events.saturating_add(1);
        match entry.kind {
            DivergenceKind::ExactMatch => {
                self.exact_matches = self.exact_matches.saturating_add(1);
                return;
            }
            DivergenceKind::LegacyBugFixedByLean(_) => {
                self.legacy_bugs_caught = self.legacy_bugs_caught.saturating_add(1);
            }
            DivergenceKind::LeanBug
            | DivergenceKind::OrderingNondeterminism
            | DivergenceKind::SerializationMismatch => {
                self.unexpected_divergences = self.unexpected_divergences.saturating_add(1);
            }
        }
        if CAP == 0 {
            return;
        }
        if self.entries.len() < CAP {
            self.entries.push(entry);
        } else {
            self.entries[self.write_cursor] = entry;
        }
        self.write_cursor = (self.write_cursor + 1) % CAP;
    }

    pub fn entries(&self) -> &[ShadowDivergenceEntry] {
        &self.entries
    }

    /// Cutover readiness gate: returns `true` iff `total_events >= min_events` and
    /// `unexpected_divergences == 0`.
    pub fn ready_for_cutover(&self, min_events: u64) -> bool {
        self.total_events >= min_events && self.unexpected_divergences == 0
    }
}

/// Refinement simulation contract relating Legacy Rust state/effects to Lean state/effects.
pub struct RefinementSimulation<LegacyState, LeanState, Event, LegacyEff, LeanEff> {
    pub subsystem: &'static str,
    pub abs_state: fn(&LegacyState) -> LeanState,
    pub norm_effects: fn(&[LegacyEff]) -> Vec<LeanEff>,
    pub lean_step: fn(&LeanState, &Event, EventContext) -> (LeanState, Vec<LeanEff>),
    pub classify_known_legacy_bug:
        fn(&LeanState, &Event, &[LeanEff], &[LeanEff]) -> Option<&'static str>,
}

impl<LegacyState, LeanState, Event, LegacyEff, LeanEff>
    RefinementSimulation<LegacyState, LeanState, Event, LegacyEff, LeanEff>
where
    LeanState: PartialEq + core::fmt::Debug,
    Event: core::fmt::Debug,
    LeanEff: PartialEq + Ord + Clone + core::fmt::Debug,
{
    /// Runs one shadow comparison step and records any divergence into `ring`.
    pub fn observe_step<const CAP: usize>(
        &self,
        legacy_before: &LegacyState,
        legacy_after: &LegacyState,
        event: &Event,
        legacy_effects: &[LegacyEff],
        ctx: EventContext,
        ring: &mut ShadowDivergenceRing<CAP>,
    ) -> DivergenceKind {
        let lean_before = (self.abs_state)(legacy_before);
        let lean_expected_after = (self.abs_state)(legacy_after);
        let (lean_after, lean_effects) = (self.lean_step)(&lean_before, event, ctx);
        let rust_norm_effects = (self.norm_effects)(legacy_effects);

        let kind = if lean_after == lean_expected_after && rust_norm_effects == lean_effects {
            DivergenceKind::ExactMatch
        } else if let Some(bug_tag) =
            (self.classify_known_legacy_bug)(&lean_before, event, &rust_norm_effects, &lean_effects)
        {
            DivergenceKind::LegacyBugFixedByLean(bug_tag)
        } else {
            let mut rust_sorted = rust_norm_effects.clone();
            let mut lean_sorted = lean_effects.clone();
            rust_sorted.sort();
            lean_sorted.sort();
            if lean_after == lean_expected_after && rust_sorted == lean_sorted {
                DivergenceKind::OrderingNondeterminism
            } else {
                DivergenceKind::LeanBug
            }
        };

        ring.record(ShadowDivergenceEntry {
            subsystem: self.subsystem,
            ctx,
            kind,
            state_summary: format!("{lean_before:?} -> {lean_after:?}"),
            event_summary: format!("{event:?}"),
            rust_effects_summary: format!("{rust_norm_effects:?}"),
            lean_effects_summary: format!("{lean_effects:?}"),
        });
        kind
    }
}

/// Verifies via Lean's `orb_effect_admissible` C-ABI gate that every emitted effect satisfies
/// its domain safety precondition.
pub fn verify_effect_batch_admissible(effects: &[EffectAdmissibleInput]) -> bool {
    effects.iter().copied().all(effect_admissible)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn orb_wire_roundtrip_and_failure_no_partial_mutation() {
        let frame = OrbWireFrame {
            schema_id: 7,
            flags: 0xA5,
            records: vec![
                OrbWireRecordWord {
                    tag: 1,
                    flags: 2,
                    len16: 5,
                    payload32: 0,
                },
                OrbWireRecordWord {
                    tag: 9,
                    flags: 0,
                    len16: 4,
                    payload32: 5,
                },
            ],
            arena: b"helloorbw".to_vec(),
        };

        let mut buf = [0xEEu8; 128];
        let written = frame
            .encode_into(&mut buf, ORB_WIRE_DEFAULT_MAX_BUDGET)
            .expect("valid frame should encode");
        assert_eq!(written, 24 + 16 + 9);

        let decoded = OrbWireFrame::decode(&buf[..written], 7, ORB_WIRE_DEFAULT_MAX_BUDGET)
            .expect("encoded frame should decode");
        assert_eq!(decoded, frame);
        assert_eq!(decoded.arena_slice(0, 5), Some(&b"hello"[..]));
        assert_eq!(decoded.arena_slice(5, 4), Some(&b"orbw"[..]));

        // Verify `encode_failure_no_partial_mutation` when output buffer is too small
        let mut small_buf = [0xAAu8; 16];
        let err = frame.encode_into(&mut small_buf, ORB_WIRE_DEFAULT_MAX_BUDGET);
        assert_eq!(err, Err(OrbWireStatus::OutputTooSmall));
        assert_eq!(small_buf, [0xAAu8; 16]);

        // Schema migration gate
        assert!(wire_schema_migrate_step(3, 4, 3, 128, 4096));
        assert!(!wire_schema_migrate_step(3, 5, 3, 128, 4096));
        assert!(!wire_schema_migrate_step(4, 3, 4, 128, 4096));
        assert!(frame.can_migrate_to(8, 4096));
        assert!(!frame.can_migrate_to(9, 4096));
    }

    #[test]
    fn orb_wire_enumerative_boundary_perturbations_rejected() {
        let frame = OrbWireFrame {
            schema_id: 3,
            flags: 0,
            records: vec![OrbWireRecordWord {
                tag: 4,
                flags: 1,
                len16: 6,
                payload32: 0,
            }],
            arena: b"border".to_vec(),
        };
        let mut valid_buf = [0u8; 64];
        let n = frame
            .encode_into(&mut valid_buf, 128)
            .expect("valid frame encodes");
        let valid_hdr = OrbWireHeader::from_le_bytes(&valid_buf[..n]).unwrap();

        // Perturb each header field by ±1 around the valid boundary
        for delta in [-1i64, 1i64] {
            // 1. total_len ± 1
            let mut b = valid_buf;
            let mut h = valid_hdr;
            h.total_len = (i64::from(valid_hdr.total_len) + delta) as u32;
            b[..ORB_WIRE_HEADER_BYTES].copy_from_slice(&h.to_le_bytes());
            assert_eq!(
                OrbWireFrame::decode(&b[..n], 3, 128),
                Err(OrbWireStatus::TruncatedOrOutOfBounds)
            );

            // 2. payload_len ± 1
            let mut b = valid_buf;
            let mut h = valid_hdr;
            h.payload_len = (i64::from(valid_hdr.payload_len) + delta) as u32;
            b[..ORB_WIRE_HEADER_BYTES].copy_from_slice(&h.to_le_bytes());
            assert_eq!(
                OrbWireFrame::decode(&b[..n], 3, 128),
                Err(OrbWireStatus::TruncatedOrOutOfBounds)
            );

            // 3. arena_off ± 1
            let mut b = valid_buf;
            let mut h = valid_hdr;
            h.arena_off = (i64::from(valid_hdr.arena_off) + delta) as u16;
            b[..ORB_WIRE_HEADER_BYTES].copy_from_slice(&h.to_le_bytes());
            assert_eq!(
                OrbWireFrame::decode(&b[..n], 3, 128),
                Err(OrbWireStatus::TruncatedOrOutOfBounds)
            );

            // 4. arena_len ± 1
            let mut b = valid_buf;
            let mut h = valid_hdr;
            h.arena_len = (i64::from(valid_hdr.arena_len) + delta) as u16;
            b[..ORB_WIRE_HEADER_BYTES].copy_from_slice(&h.to_le_bytes());
            assert_eq!(
                OrbWireFrame::decode(&b[..n], 3, 128),
                Err(OrbWireStatus::TruncatedOrOutOfBounds)
            );
        }

        // 5. max_budget_bytes = n (ok) vs n - 1 (BudgetExceeded)
        assert!(OrbWireFrame::decode(&valid_buf[..n], 3, n as u32).is_ok());
        assert_eq!(
            OrbWireFrame::decode(&valid_buf[..n], 3, (n - 1) as u32),
            Err(OrbWireStatus::BudgetExceeded)
        );
    }

    #[test]
    fn phase2_proxy_provider_pool_and_argmin_route_fold_replay() {
        use crate::{
            provider_pool_step, select_best_provider_account, ProviderPoolAction,
            ProviderPoolStepInput, RouteCandidate,
        };

        let candidates = [
            RouteCandidate {
                account_id: 101,
                score: 50,
                is_rejected: false,
                reset_epoch: 0,
            },
            RouteCandidate {
                account_id: 202,
                score: 20,
                is_rejected: true,
                reset_epoch: 5_000,
            },
            RouteCandidate {
                account_id: 303,
                score: 30,
                is_rejected: false,
                reset_epoch: 0,
            },
        ];

        // 1. Antigravity bound-account incident replay: bound to 101 -> must pick 101 even though 303 has lower score (30 < 50)
        assert_eq!(
            select_best_provider_account(Some(101), false, false, 0, 3, 1_000, &candidates),
            Some(101)
        );

        // 2. Unbound pool routing before reset (now = 1_000 < 5_000): 202 is rejected, so 303 (score 30 < 50) wins
        assert_eq!(
            select_best_provider_account(None, false, false, 0, 3, 1_000, &candidates),
            Some(303)
        );

        // 3. Unbound pool routing after reset (now = 6_000 >= 5_000): 202 is eligible again and has lowest score (20)
        assert_eq!(
            select_best_provider_account(None, false, false, 0, 3, 6_000, &candidates),
            Some(202)
        );

        // 4. First-byte lock (`StickyFence`): failover after first byte sent is aborted (`AbortLockedStream`)
        let locked = provider_pool_step(ProviderPoolStepInput {
            bound_account_id: None,
            candidate_account_id: 303,
            is_rejected: false,
            first_byte_sent: true,
            is_failover_attempt: true,
            attempts: 0,
            max_attempts: 3,
            now_epoch: 1_000,
            reset_epoch: 0,
        });
        assert_eq!(locked.action, ProviderPoolAction::AbortLockedStream);
        assert!(!locked.emit_dispatch_effect);
        assert!(locked.first_byte_locked_next);

        // 5. Failover termination at `attempts == max_attempts`
        let exhausted = provider_pool_step(ProviderPoolStepInput {
            bound_account_id: None,
            candidate_account_id: 303,
            is_rejected: false,
            first_byte_sent: false,
            is_failover_attempt: true,
            attempts: 3,
            max_attempts: 3,
            now_epoch: 1_000,
            reset_epoch: 0,
        });
        assert_eq!(exhausted.action, ProviderPoolAction::ExhaustedFailover);
        assert!(!exhausted.emit_dispatch_effect);
    }

    #[test]
    fn orb_wire_fuzz_10000_malformed_frames_never_panics() {
        let mut seed: u64 = 0x9E37_79B9_7F4A_7C15;
        let mut raw = [0u8; 96];
        for i in 0..10_000u32 {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            let len = (seed as usize) % raw.len();
            for b in &mut raw[..len] {
                seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1);
                *b = (seed >> 24) as u8;
            }
            // Also inject near-valid headers with corrupted offsets/lengths
            if i % 3 == 0 && len >= ORB_WIRE_HEADER_BYTES {
                raw[0..4].copy_from_slice(&ORB_WIRE_MAGIC.to_le_bytes());
                raw[4..6].copy_from_slice(&(ORB_WIRE_ABI_VERSION as u16).to_le_bytes());
                raw[6..8].copy_from_slice(&1u16.to_le_bytes());
            }
            let _ = OrbWireFrame::decode(&raw[..len], 1, 4096);
        }
    }

    #[test]
    fn shadow_runner_classifies_exact_matches_and_known_legacy_bugs() {
        #[derive(Debug, Clone, PartialEq, Eq)]
        struct PilotState {
            bound_account: u8,
            dispatched: u8,
        }
        #[derive(Debug, Clone, PartialEq, Eq)]
        struct PilotEvent {
            requested_account: u8,
        }

        let sim = RefinementSimulation::<PilotState, PilotState, PilotEvent, u8, u8> {
            subsystem: "proxy_account_pool",
            abs_state: |s| s.clone(),
            norm_effects: |effs| effs.to_vec(),
            lean_step: |s, _e, _ctx| {
                let next = PilotState {
                    bound_account: s.bound_account,
                    dispatched: s.bound_account,
                };
                (next, vec![s.bound_account])
            },
            classify_known_legacy_bug: |s, _e, rust_effs, lean_effs| {
                if rust_effs != lean_effs && lean_effs == &[s.bound_account] {
                    Some("antigravity_wrong_account")
                } else {
                    None
                }
            },
        };

        let mut ring = ShadowDivergenceRing::<8>::new();
        let ctx = EventContext {
            now_ms: 1_700_000_000_000,
            fresh_nonce: 42,
            idempotency_key: 1001,
            boot_id_matches: true,
            schema_id: 1,
        };

        let s0 = PilotState {
            bound_account: 2,
            dispatched: 0,
        };
        let s1_ok = PilotState {
            bound_account: 2,
            dispatched: 2,
        };
        let k1 = sim.observe_step(
            &s0,
            &s1_ok,
            &PilotEvent {
                requested_account: 2,
            },
            &[2],
            ctx,
            &mut ring,
        );
        assert_eq!(k1, DivergenceKind::ExactMatch);
        assert!(ring.ready_for_cutover(1));

        // Simulate the legacy Antigravity wrong-account bug (Rust picked account 1 instead of bound account 2)
        let s1_legacy_bug = PilotState {
            bound_account: 2,
            dispatched: 1,
        };
        let k2 = sim.observe_step(
            &s0,
            &s1_legacy_bug,
            &PilotEvent {
                requested_account: 1,
            },
            &[1],
            ctx,
            &mut ring,
        );
        assert_eq!(
            k2,
            DivergenceKind::LegacyBugFixedByLean("antigravity_wrong_account")
        );
        assert_eq!(ring.legacy_bugs_caught, 1);
        assert_eq!(ring.unexpected_divergences, 0);
        assert!(ring.ready_for_cutover(2));
        assert!(ring.entries()[0]
            .to_jsonl_line()
            .contains("legacy_bug_fixed_by_lean:antigravity_wrong_account"));
    }
}
