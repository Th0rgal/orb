//! Direct C-ABI bindings to `lean/Orb/Spec.lean` (`liborb_spec_cabi.a`).

unsafe extern "C" {
    pub fn orb_verify_writer_reuse(c: u8, t: u8, m: u8, e: u8, w: u8, u: u8) -> u8;
    pub fn orb_verify_lease_mode(wf: u8, ro_tag: u8, wr_tag: u8, ro_intent: u8) -> u8;
    pub fn orb_verify_track_hold(unres: u8, queued: u8, live: u8, goal: u8) -> u8;
    pub fn orb_verify_repo_disjoint(h_known: u8, t_known: u8, same: u8) -> u8;
    pub fn orb_verify_remote_outbox(
        op: u8,
        ex: u8,
        s: u8,
        c: u8,
        sp: u8,
        r: u8,
        p: u8,
        j: u8,
        a: u8,
    ) -> u8;
    pub fn orb_verify_board_slots(max_p: u32, boss: u32, running: u32) -> u8;
    pub fn orb_verify_board_retry(att: u32, max_a: u32, ext: u8, mrg: u8, ui: u8) -> u8;
    pub fn orb_verify_job_transition(from_state: u8, to_state: u8) -> u8;
    pub fn orb_verify_bundle_budget(comp: u8, bytes: u64, ov_cap: u64, comp_cap: u64) -> u8;
    pub fn orb_verify_token_rotation(pres: u8, cur: u8, prev_ne: u8, prev: u8, scope: u8) -> u8;
    pub fn leansys_verify_log_window(off: u64, req: u64, max_c: u64, fsz: u64, act: u64) -> u8;
    pub fn leansys_mix64_word(acc: u64, word: u64) -> u64;
}

pub fn writer_reuse_allowed(c: bool, t: bool, m: bool, e: bool, w: bool, u: bool) -> bool {
    unsafe { orb_verify_writer_reuse(c as u8, t as u8, m as u8, e as u8, w as u8, u as u8) != 0 }
}

pub fn classify_lease_mode(wf: Option<bool>, ro_t: bool, wr_t: bool, ro_i: bool) -> &'static str {
    let f = wf.map_or(2, u8::from);
    if unsafe { orb_verify_lease_mode(f, ro_t as u8, wr_t as u8, ro_i as u8) } == 0 {
        "reader"
    } else {
        "writer"
    }
}

pub fn track_hold_active(unres: bool, queued: bool, live: bool, goal: bool) -> bool {
    unsafe { orb_verify_track_hold(unres as u8, queued as u8, live as u8, goal as u8) != 0 }
}

pub fn repo_disjoint(h_known: bool, t_known: bool, same: bool) -> bool {
    unsafe { orb_verify_repo_disjoint(h_known as u8, t_known as u8, same as u8) != 0 }
}

pub fn remote_outbox_admit_enqueue(ex: bool, s: bool, c: bool, sp: bool, r: bool, p: bool) -> bool {
    unsafe {
        orb_verify_remote_outbox(
            0, ex as u8, s as u8, c as u8, sp as u8, r as u8, p as u8, 0, 0,
        ) != 0
    }
}

pub fn remote_outbox_admit_cancel(job: bool, abn: bool) -> bool {
    unsafe { orb_verify_remote_outbox(1, 0, 0, 0, 0, 0, 0, job as u8, abn as u8) != 0 }
}

pub fn board_slots_available(max_p: u32, boss: u32, running: u32) -> bool {
    unsafe { orb_verify_board_slots(max_p, boss, running) != 0 }
}

pub fn board_retry_allowed(att: u32, max_a: u32, ext: bool, mrg: bool, ui: bool) -> bool {
    unsafe { orb_verify_board_retry(att, max_a, ext as u8, mrg as u8, ui as u8) != 0 }
}

pub fn job_transition_allowed(from_state: u8, to_state: u8) -> bool {
    unsafe { orb_verify_job_transition(from_state, to_state) != 0 }
}

pub fn bundle_budget_ok(comp: bool, bytes: u64, ov_cap: u64, comp_cap: u64) -> bool {
    unsafe { orb_verify_bundle_budget(comp as u8, bytes, ov_cap, comp_cap) != 0 }
}

pub fn token_rotation_allowed(pr: bool, cur: bool, pne: bool, prev: bool, sc: bool) -> bool {
    unsafe { orb_verify_token_rotation(pr as u8, cur as u8, pne as u8, prev as u8, sc as u8) != 0 }
}

pub fn log_window_valid(off: u64, req: u64, max_c: u64, fsz: u64, act: u64) -> bool {
    unsafe { leansys_verify_log_window(off, req, max_c, fsz, act) != 0 }
}
