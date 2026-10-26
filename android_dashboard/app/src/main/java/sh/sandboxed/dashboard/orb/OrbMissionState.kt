package sh.sandboxed.dashboard.orb

/**
 * Mission states, mirroring shared/orb-spec/mission-states.json (iOS reads the same table).
 * OrbMissionStateSpecTest fails if this enum and the JSON drift apart.
 */
enum class MissionCategory(val sortRank: Int) {
    Waiting(0), Blocked(1), Failed(2), Live(3), Queued(4), Paused(5), Stopped(6), Done(7), Archived(8), Unknown(9);

    val wire: String get() = name.lowercase()
}

enum class MissionState(
    val wire: String,
    val label: String,
    val category: MissionCategory,
    val unreadResponse: Boolean = false,
    val canRetry: Boolean = false,
) {
    Active("active", "Working", MissionCategory.Live),
    Running("running", "Working", MissionCategory.Live),
    Starting("starting", "Working", MissionCategory.Live),
    Working("working", "Working", MissionCategory.Live),
    InProgress("in_progress", "Working", MissionCategory.Live),
    Processing("processing", "Working", MissionCategory.Live),
    Streaming("streaming", "Working", MissionCategory.Live),
    Resuming("resuming", "Working", MissionCategory.Live),
    WaitingBackground("waiting_background", "Working", MissionCategory.Live),
    Pending("pending", "Queued", MissionCategory.Queued),
    Queued("queued", "Queued", MissionCategory.Queued),
    AwaitingUser("awaiting_user", "Waiting for reply", MissionCategory.Waiting, unreadResponse = true),
    WaitingUser("waiting_user", "Waiting for reply", MissionCategory.Waiting, unreadResponse = true),
    WaitingForUser("waiting_for_user", "Waiting for reply", MissionCategory.Waiting),
    NeedsInput("needs_input", "Needs input", MissionCategory.Waiting),
    AwaitingApproval("awaiting_approval", "Awaiting approval", MissionCategory.Waiting),
    Blocked("blocked", "Blocked", MissionCategory.Blocked, unreadResponse = true, canRetry = true),
    Failed("failed", "Failed", MissionCategory.Failed, unreadResponse = true, canRetry = true),
    Error("error", "Failed", MissionCategory.Failed),
    Errored("errored", "Failed", MissionCategory.Failed),
    NotFeasible("not_feasible", "Not feasible", MissionCategory.Failed, unreadResponse = true, canRetry = true),
    TimedOut("timed_out", "Timed out", MissionCategory.Failed),
    Interrupted("interrupted", "Stopped", MissionCategory.Stopped, unreadResponse = true, canRetry = true),
    Cancelled("cancelled", "Stopped", MissionCategory.Stopped),
    Paused("paused", "Paused", MissionCategory.Paused, unreadResponse = true),
    Completed("completed", "Completed", MissionCategory.Done, unreadResponse = true),
    Succeeded("succeeded", "Completed", MissionCategory.Done, unreadResponse = true),
    Acknowledged("acknowledged", "Archived", MissionCategory.Archived),
    Archived("archived", "Archived", MissionCategory.Archived);

    private val flags: Int get() = OrbKernel.missionFlags(ordinal)
    val sortRank: Int get() = OrbKernel.missionSortRank(ordinal)
    /** Running or queued: work may still happen without the user. */
    val live: Boolean get() = (flags and 1) != 0
    /** Finished for good (done or failed); no pending question can apply. */
    val terminal: Boolean get() = (flags and 2) != 0
    /** Shown under "Needs attention": waiting on the user, blocked, or failed. */
    val needsAttention: Boolean
        get() = (flags and 4) != 0

    companion object {
        private val byWire = entries.associateBy { it.wire }

        fun of(raw: String?): MissionState? = raw?.trim()?.lowercase()?.let(byWire::get)

        fun of(mission: OrbRow): MissionState? = of(mission.str("status", "state"))

        fun label(raw: String): String = of(raw)?.label ?: raw.replace("_", " ")

        fun category(raw: String?): MissionCategory = of(raw)?.category ?: MissionCategory.Unknown
    }
}
