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
    val destroyReason: String?
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

data class ManagedMachinesResponse(
    val enabled: Boolean,
    val provider: String?,
    val machines: List<ManagedMachine>,
    val budget: ManagedBudget
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
            destroyReason = OrbJSON.str(d, "destroy_reason")
        )
    }

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
            )
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
