package sh.sandboxed.dashboard.orb

import java.time.Instant
import java.time.OffsetDateTime
import java.util.Locale

/**
 * Managed (boat.dev) machines: payload parsing and presentation logic.
 * Mirrors `orb/src/managedMachineModel.ts`; kept free of Android types so it
 * is covered by JVM unit tests.
 */
data class ManagedMachine(
    val id: String,
    /** Human name from the backend ("small-a"); null on older backends. */
    val name: String?,
    val nodeId: String,
    val size: String,
    val cpu: Int,
    val ramGb: Double,
    val diskGb: Double?,
    val usdPerHour: Double,
    val state: String,
    val createdAt: String,
    val expiresAt: String,
    val destroyedAt: String?,
    val costUsd: Double,
    val costIsMetered: Boolean,
    val ownerMissionId: String?,
    val reason: String?,
    val error: String?,
    val ledgerClosed: Boolean,
    val destroyReason: String?,
    /** Mission that rented it for the owner (e.g. a start_mission caller). */
    val requestedByMissionId: String? = null,
    /** "mission" | "user"; null on legacy rows ("No owner"). */
    val ownerKind: String? = null,
    /** When the lifecycle reaper will destroy it, and the reason it will record. */
    val reapAt: String? = null,
    val reapReason: String? = null
)

data class ManagedBudget(
    val spentTodayUsd: Double,
    val committedUsd: Double,
    /** null = unlimited. */
    val dailyCapUsd: Double?,
    val active: Int,
    /** null = unlimited. */
    val maxConcurrent: Int?,
    val defaultTtlMinutes: Int,
    val maxTtlMinutes: Int
)

/** One UTC day of managed spend from Core; missions/sizes highest first. */
data class DailySpend(
    val day: String,
    val usd: Double,
    /** (mission id or null for no mission, usd). */
    val missions: List<Pair<String?, Double>>,
    val sizes: List<Pair<String, Double>>
)

data class SpendSummary(val total: Double, val today: Double, val max: Double)

data class ManagedMachinesResponse(
    val enabled: Boolean,
    val provider: String?,
    val machines: List<ManagedMachine>,
    val budget: ManagedBudget,
    /** Last 7 UTC days, oldest first; null on Cores that predate the spend chart. */
    val dailySpend: List<DailySpend>? = null
)

object OrbManagedMachines {
    const val PATH = "/api/managed-machines"
    const val EXTEND_MINUTES = 60

    fun parseMachine(d: OrbDict): ManagedMachine? {
        val id = OrbJSON.str(d, "id") ?: return null
        return ManagedMachine(
            id = id,
            name = OrbJSON.str(d, "name"),
            nodeId = OrbJSON.str(d, "node_id") ?: "managed-$id",
            size = OrbJSON.str(d, "size") ?: "custom",
            cpu = OrbJSON.int(d, "cpu") ?: 0,
            ramGb = OrbJSON.double(d, "ram_gb") ?: 0.0,
            diskGb = OrbJSON.double(d, "disk_gb"),
            usdPerHour = OrbJSON.double(d, "usd_per_hour") ?: 0.0,
            state = OrbJSON.str(d, "state") ?: "provisioning",
            createdAt = OrbJSON.str(d, "created_at") ?: "",
            expiresAt = OrbJSON.str(d, "expires_at") ?: "",
            destroyedAt = OrbJSON.str(d, "destroyed_at"),
            costUsd = OrbJSON.double(d, "cost_usd") ?: 0.0,
            costIsMetered = OrbJSON.bool(d, "cost_is_metered") ?: false,
            ownerMissionId = OrbJSON.str(d, "owner_mission_id"),
            reason = OrbJSON.str(d, "reason"),
            error = OrbJSON.str(d, "error"),
            ledgerClosed = OrbJSON.bool(d, "ledger_closed") ?: false,
            destroyReason = OrbJSON.str(d, "destroy_reason"),
            requestedByMissionId = OrbJSON.str(d, "requested_by_mission_id"),
            ownerKind = OrbJSON.str(d, "owner_kind"),
            reapAt = OrbJSON.str(d, "reap_at"),
            reapReason = OrbJSON.str(d, "reap_reason")
        )
    }

    fun parseDailySpend(raw: Any?): List<DailySpend>? = (raw as? List<*>)?.let {
        OrbJSON.dictList(raw).map { day ->
            DailySpend(
                day = OrbJSON.str(day, "day") ?: "",
                usd = OrbJSON.double(day, "usd") ?: 0.0,
                missions = OrbJSON.dictList(day["missions"]).map { OrbJSON.str(it, "mission_id") to (OrbJSON.double(it, "usd") ?: 0.0) },
                sizes = OrbJSON.dictList(day["sizes"]).map { (OrbJSON.str(it, "size") ?: "") to (OrbJSON.double(it, "usd") ?: 0.0) }
            )
        }
    }

    /** Spend chart header: the window's sum, today (the last day) and the tallest bar. */
    fun spendSummary(days: List<DailySpend>): SpendSummary =
        SpendSummary(days.sumOf { it.usd }, days.lastOrNull()?.usd ?: 0.0, days.maxOfOrNull { it.usd } ?: 0.0)

    /** Bar height as a 0…1 fraction of the tallest day; zero days stay 0 (a baseline). */
    fun spendFraction(usd: Double, max: Double): Double = if (max > 0 && usd > 0) maxOf(usd / max, 0.04) else 0.0

    /** First [top] mission ids of a day (null = no mission) and how many more there are. */
    fun topMissions(d: DailySpend, top: Int = 2): Pair<List<String?>, Int> =
        d.missions.take(top).map { it.first } to maxOf(0, d.missions.size - top)

    private fun spendDate(day: String): java.time.LocalDate? = runCatching { java.time.LocalDate.parse(day) }.getOrNull()
    /** "Mon" for a UTC `YYYY-MM-DD` day. */
    fun spendWeekday(day: String): String =
        spendDate(day)?.format(java.time.format.DateTimeFormatter.ofPattern("EEE", Locale.getDefault())) ?: day
    /** "Mon 20 Oct". */
    fun spendDayLabel(day: String): String =
        spendDate(day)?.format(java.time.format.DateTimeFormatter.ofPattern("EEE d MMM", Locale.getDefault())) ?: day

    /** "Mon 20 Oct · $0.53 · Fix login $0.50, No mission $0.03 +1 more". */
    fun spendDayDetail(d: DailySpend, titles: Map<String, String?>, top: Int = 2): String {
        if (d.usd <= 0) return "${spendDayLabel(d.day)} · no spend"
        val parts = d.missions.take(top).map { (id, v) ->
            val name = id?.let { titles[it] ?: "Mission ${it.take(8)}" } ?: "No mission"
            "$name ${usd(v)}"
        }
        val more = topMissions(d, top).second
        return "${spendDayLabel(d.day)} · ${usd(d.usd)}" + (if (parts.isEmpty()) "" else " · " + parts.joinToString(", ")) + (if (more > 0) " +$more more" else "")
    }

    /** "$0.25 today of $20.00 daily cap" / "$0.25 today". */
    fun spendTodayLine(today: Double, b: ManagedBudget): String =
        "${usd(today)} today" + (b.dailyCapUsd?.let { " of ${usd(it)} daily cap" } ?: "")

    /** "1 of 3 running" / "1 running". */
    fun runningLine(b: ManagedBudget): String = "${b.active}" + (b.maxConcurrent?.let { " of $it" } ?: "") + " running"

    fun parse(d: OrbDict): ManagedMachinesResponse {
        val b = OrbJSON.dict(d["budget"])
        return ManagedMachinesResponse(
            enabled = OrbJSON.bool(d, "enabled") ?: false,
            provider = OrbJSON.str(d, "provider"),
            machines = OrbJSON.dictList(d["machines"]).mapNotNull { parseMachine(it) },
            budget = ManagedBudget(
                spentTodayUsd = OrbJSON.double(b, "spent_today_usd") ?: 0.0,
                committedUsd = OrbJSON.double(b, "committed_usd") ?: 0.0,
                dailyCapUsd = OrbJSON.double(b, "daily_cap_usd"),
                active = OrbJSON.int(b, "active") ?: 0,
                maxConcurrent = OrbJSON.int(b, "max_concurrent"),
                defaultTtlMinutes = OrbJSON.int(b, "default_ttl_minutes") ?: 60,
                maxTtlMinutes = OrbJSON.int(b, "max_ttl_minutes") ?: 0
            ),
            dailySpend = parseDailySpend(d["daily_spend"])
        )
    }

    /** Older backends answer 404/405: the section is hidden. */
    fun isUnsupported(status: Int?): Boolean = status == 404 || status == 405

    /** Remote nodes provisioned by the managed-machine service. */
    fun isManagedNode(id: String?, labels: List<String>?): Boolean =
        labels?.contains("managed") == true || id?.startsWith("managed-") == true

    fun nodeLabels(node: OrbRow): List<String> =
        (node.raw["labels"] as? List<*>)?.mapNotNull { it as? String } ?: emptyList()

    /** Row title: the machine's name, falling back to its id. */
    fun title(m: ManagedMachine): String = m.name ?: m.id

    /** Fleet row title: `display_name` for nodes that have one, else the id. */
    fun nodeTitle(nodeId: String, node: OrbRow): String = node.str("display_name") ?: nodeId

    /** Optimistic Destroy: the row flips to "destroying" before the call returns. */
    fun markDestroying(machines: List<ManagedMachine>, id: String): List<ManagedMachine> =
        machines.map { if (it.id == id) it.copy(state = "destroying") else it }

    /** Undo `markDestroying` for one machine after a failed call. */
    fun revert(machines: List<ManagedMachine>, original: ManagedMachine): List<ManagedMachine> =
        machines.map { if (it.id == original.id) original else it }

    fun isLive(m: ManagedMachine): Boolean = m.state != "destroyed" && m.state != "failed"

    fun canAct(m: ManagedMachine): Boolean = isLive(m) && m.state != "destroying"

    fun parseTime(s: String?): Long? {
        if (s.isNullOrBlank()) return null
        return try {
            Instant.parse(s).toEpochMilli()
        } catch (_: Throwable) {
            try {
                OffsetDateTime.parse(s).toInstant().toEpochMilli()
            } catch (_: Throwable) {
                null
            }
        }
    }

    /** "$0.42", "$12.30", "<$0.01" for tiny non-zero amounts. */
    fun usd(amount: Double?): String {
        if (amount == null || !amount.isFinite()) return "—"
        if (amount > 0 && amount < 0.01) return "<$0.01"
        return "$" + String.format(Locale.US, "%.2f", amount)
    }

    /** "$0.12/h"; three decimals under ten cents so cheap sizes stay distinct. */
    fun usdPerHour(rate: Double?): String {
        if (rate == null || !rate.isFinite()) return "—"
        val digits = if (rate > 0 && rate < 0.1) 3 else 2
        return "$" + String.format(Locale.US, "%.${digits}f", rate) + "/h"
    }

    /** Time left until `expiresAt`: "1h 05m", "4m 09s", "Expired". */
    fun ttlLeft(expiresAt: String, now: Long): String {
        val end = parseTime(expiresAt) ?: return "—"
        val s = Math.floorDiv(end - now, 1000L)
        if (s <= 0) return "Expired"
        val h = s / 3600
        val m = (s % 3600) / 60
        val sec = s % 60
        return if (h > 0) String.format(Locale.US, "%dh %02dm", h, m)
        else String.format(Locale.US, "%dm %02ds", m, sec)
    }

    /** Under ten minutes left: the countdown is highlighted. */
    fun ttlUrgent(expiresAt: String, now: Long): Boolean {
        val end = parseTime(expiresAt) ?: return false
        return end - now < 10 * 60_000L
    }

    /** Cost so far, extrapolated between polls so it ticks with the countdown. */
    fun liveCost(m: ManagedMachine, fetchedAt: Long, now: Long): Double {
        if (m.state != "online" && m.state != "enrolling" && m.state != "provisioning") return m.costUsd
        val until = minOf(now, parseTime(m.expiresAt) ?: now)
        return m.costUsd + maxOf(0L, until - fetchedAt) / 3_600_000.0 * m.usdPerHour
    }

    fun stateLabel(s: String): String = when (s) {
        "provisioning" -> "Provisioning"
        "enrolling" -> "Enrolling"
        "online" -> "Online"
        "destroying" -> "Destroying…"
        "destroyed" -> "Destroyed"
        "failed" -> "Failed"
        else -> s
    }

    private fun num(v: Double): String =
        if (v == Math.floor(v)) v.toLong().toString() else String.format(Locale.US, "%.1f", v)

    /** "2 vCPU · 4 GB" (plus " · 40 GB disk" when known). */
    fun sizeSpec(m: ManagedMachine): String =
        "${m.cpu} vCPU · ${num(m.ramGb)} GB" + (m.diskGb?.let { " · ${num(it)} GB disk" } ?: "")

    /**
     * "$1.20 spent today of $20.00 · 1 of 3 running"; a null cap or limit is
     * unlimited and drops its "of …" ("$0.11 spent today · 1 running").
     */
    fun budgetLine(b: ManagedBudget): String {
        val spent = "${usd(b.spentTodayUsd)} spent today" + (b.dailyCapUsd?.let { " of ${usd(it)}" } ?: "")
        val running = "${b.active}" + (b.maxConcurrent?.let { " of $it" } ?: "") + " running"
        return "$spent · $running"
    }

    /** True when a cap or limit is set and reached. */
    fun budgetFull(b: ManagedBudget): Boolean =
        (b.maxConcurrent?.let { b.active >= it } ?: false) || (b.dailyCapUsd?.let { b.spentTodayUsd >= it } ?: false)

    /** Size shown to people: the backend's "default" size is "medium". */
    fun sizeLabel(size: String): String = if (size == "default") "medium" else size

    /** "4 vCPU · 8 GB RAM · 50 GB" (disk dropped when unknown). */
    fun specLine(m: ManagedMachine): String =
        "${m.cpu} vCPU · ${num(m.ramGb)} GB RAM" + (m.diskGb?.let { " · ${num(it)} GB" } ?: "")

    /** Owner chip kind, mirroring `machineOwner` in managedMachineModel.ts. */
    sealed interface Owner {
        data class Mission(val id: String) : Owner
        data object User : Owner
        data object None : Owner
    }

    fun owner(m: ManagedMachine): Owner = when {
        !m.ownerMissionId.isNullOrEmpty() -> Owner.Mission(m.ownerMissionId)
        m.ownerKind == "user" -> Owner.User
        else -> Owner.None
    }

    fun reapReasonLabel(reason: String): String = when (reason) {
        "ttl_expired" -> "TTL"
        "idle_no_owner" -> "idle, no owner"
        "idle_user_owned" -> "idle"
        "owner_missing" -> "owner deleted"
        else -> reason.replaceFirst(Regex("^owner_"), "owner ").replace(Regex("_idle$"), ", idle").replace('_', ' ')
    }

    /** "Reaps in 5 min (owner completed)", "Reap due (…)"; null when nothing is scheduled. */
    fun reapLine(m: ManagedMachine, now: Long): String? {
        if (!isLive(m)) return null
        val at = parseTime(m.reapAt) ?: return null
        val why = m.reapReason?.let { " (${reapReasonLabel(it)})" } ?: ""
        val mins = Math.ceil((at - now) / 60_000.0).toLong()
        if (mins <= 0) return "Reap due$why"
        if (mins < 60) return "Reaps in $mins min$why"
        return String.format(Locale.US, "Reaps in %d h %02d min", mins / 60, mins % 60) + why
    }

    /** Short TTL: "21 min left", "1 h 05 min left", "<1 min left", "Expired". */
    fun ttlShort(expiresAt: String, now: Long): String {
        val end = parseTime(expiresAt) ?: return "—"
        val left = end - now
        if (left <= 0) return "Expired"
        val mins = left / 60_000
        if (mins < 1) return "<1 min left"
        val h = mins / 60
        val m = mins % 60
        return if (h > 0) String.format(Locale.US, "%d h %02d min left", h, m) else "$mins min left"
    }

    /** Fraction of the TTL left (0..1), from created_at to expires_at; null when unknown. */
    fun ttlFraction(m: ManagedMachine, now: Long): Float? {
        val start = parseTime(m.createdAt) ?: return null
        val end = parseTime(m.expiresAt) ?: return null
        if (end <= start) return null
        return ((end - now).toDouble() / (end - start)).coerceIn(0.0, 1.0).toFloat()
    }

    /** "<$0.01 so far · $0.036/h". */
    fun costLine(m: ManagedMachine, fetchedAt: Long, now: Long): String =
        "${usd(liveCost(m, fetchedAt, now))} so far · ${usdPerHour(m.usdPerHour)}"

    /** Final cost line for a destroyed/failed machine. */
    fun finalCostLine(m: ManagedMachine): String = "${usd(m.costUsd)} total"

    /** Mission chip text: the title (truncated) or the short id. */
    fun missionChip(missionId: String, title: String?, max: Int = 24): String {
        val t = title?.trim()?.takeIf { it.isNotEmpty() } ?: return missionId.take(8)
        return if (t.length > max) t.take(max - 1).trimEnd() + "…" else t
    }

    /** Title from GET /api/control/missions/:id (bare mission or `{mission: …}`). */
    fun missionTitle(d: OrbDict): String? =
        OrbJSON.str(OrbJSON.dict(d["mission"]) ?: d, "title", "name")

    /** Machines destroyed or failed during the last 24 hours, newest first. */
    fun recentMachines(machines: List<ManagedMachine>, now: Long): List<ManagedMachine> =
        machines.filter { !isLive(it) }
            .mapNotNull { m -> (parseTime(m.destroyedAt) ?: parseTime(m.createdAt))?.let { m to it } }
            .filter { now - it.second <= 86_400_000L }
            .sortedByDescending { it.second }
            .map { it.first }

    /** Human message for a failed managed-machine request. */
    fun errorMessage(e: Throwable): String {
        val err = e as? OrbError ?: return e.message ?: e.toString()
        val body = OrbJSON.dict(err.body?.let { OrbJSON.parse(it) })
        val code = OrbJSON.str(body, "error") ?: ""
        val message = OrbJSON.str(body, "message") ?: ""
        val prefix = when (code) {
            "budget_exceeded" -> "Daily budget reached"
            "quota_exceeded" -> "Machine limit reached"
            else -> ""
        }
        if (prefix.isNotEmpty()) return if (message.isNotEmpty()) "$prefix: $message" else "$prefix."
        return message.ifEmpty { err.message.ifEmpty { "Request failed (${err.status})" } }
    }
}
