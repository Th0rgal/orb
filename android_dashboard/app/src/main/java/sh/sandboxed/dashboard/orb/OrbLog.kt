package sh.sandboxed.dashboard.orb

import android.util.Log
import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import sh.sandboxed.dashboard.BuildConfig
import java.time.Instant
import org.json.JSONObject

/**
 * App-wide logging. Logcat output only in debug builds; every warning/error is
 * also kept in a small in-memory ring shown on Settings → Debug info.
 */
object OrbLog {
    enum class Category(val tag: String) {
        Network("Orb/Network"),
        Cache("Orb/Cache"),
        Notify("Orb/Notify"),
        Background("Orb/Background"),
        Auth("Orb/Auth"),
        Crash("Orb/Crash"),
    }

    enum class Level { Debug, Warning, Error }

    data class Entry(
        val atEpochMs: Long,
        val level: Level,
        val category: Category,
        val message: String,
        val detail: String? = null,
    ) {
        fun format(): String = buildString {
            append(Instant.ofEpochMilli(atEpochMs)).append(' ')
            append(level.name.first()).append(' ')
            append(category.tag).append(": ").append(message)
            if (!detail.isNullOrBlank()) append('\n').append(detail)
        }
    }

    const val RING_SIZE = 50

    private val _ring = MutableStateFlow<List<Entry>>(emptyList())
    /** Most recent warnings and errors, oldest first, capped at [RING_SIZE]. */
    val ring: StateFlow<List<Entry>> = _ring.asStateFlow()

    /** Overridable for JVM tests, where android.util.Log is not available. */
    @Volatile var logcatEnabled: Boolean = BuildConfig.DEBUG

    @Volatile var clock: () -> Long = System::currentTimeMillis

    fun d(category: Category, message: String) {
        logcat(Level.Debug, category, message, null)
    }

    fun w(category: Category, message: String, error: Throwable? = null) {
        record(Level.Warning, category, message, error?.let(::describe))
        logcat(Level.Warning, category, message, error)
    }

    fun e(category: Category, message: String, error: Throwable? = null, detail: String? = null) {
        record(Level.Error, category, message, detail ?: error?.let(::describe))
        logcat(Level.Error, category, message, error)
    }

    fun clear() {
        _ring.value = emptyList()
    }

    fun latest(): Entry? = _ring.value.lastOrNull()

    private fun record(level: Level, category: Category, message: String, detail: String?) {
        val entry = Entry(clock(), level, category, message, detail)
        synchronized(this) {
            _ring.value = (_ring.value + entry).takeLast(RING_SIZE)
        }
    }

    private fun describe(t: Throwable): String = "${t.javaClass.simpleName}: ${t.message ?: ""}".trim()

    private fun logcat(level: Level, category: Category, message: String, error: Throwable?) {
        if (!logcatEnabled) return
        try {
            when (level) {
                Level.Debug -> Log.d(category.tag, message, error)
                Level.Warning -> Log.w(category.tag, message, error)
                Level.Error -> Log.e(category.tag, message, error)
            }
        } catch (_: RuntimeException) {
            // android.util.Log stubs throw on the plain JVM; nothing else to do here.
        }
    }
}

/** Structural, content-free breadcrumbs persisted so a prior-process crash can be diagnosed. */
object OrbCrashBreadcrumbs {
    private const val PREFS = "orb_crash_breadcrumbs"
    @Volatile private var screen = "unknown"
    @Volatile private var missionId: String? = null
    @Volatile private var turnCount = 0
    @Volatile private var installed = false
    @Volatile private var preferences: android.content.SharedPreferences? = null
    @Volatile private var activityManager: ActivityManager? = null

    fun enterConversation(missionId: String, turnCount: Int) {
        this.missionId = missionId; this.turnCount = turnCount; persistActive(); setScreen("conversation")
    }
    fun updateTurnCount(turnCount: Int) { this.turnCount = turnCount; persistActive() }
    fun leaveConversation() { missionId = null; turnCount = 0; setScreen("unknown") }
    fun setScreen(screen: String) { this.screen = screen; persistActive() }

    fun install(context: Context) {
        if (installed) return
        synchronized(this) {
            if (installed) return
            val app = context.applicationContext
            val prefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            preferences = prefs
            activityManager = app.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
            screen = prefs.getString("active_screen", screen) ?: screen
            missionId = prefs.getString("active_mission_id", missionId)
            turnCount = prefs.getInt("active_turn_count", turnCount)
            drain(prefs)
            if (Build.VERSION.SDK_INT >= 30) {
                val exit = activityManager
                    ?.getHistoricalProcessExitReasons(context.packageName, 0, 1)?.firstOrNull()
                if (exit != null && exit.timestamp > prefs.getLong("last_reported_exit_ts", 0) &&
                    exit.reason in setOf(ApplicationExitInfo.REASON_CRASH_NATIVE, ApplicationExitInfo.REASON_CRASH, ApplicationExitInfo.REASON_ANR, ApplicationExitInfo.REASON_LOW_MEMORY)) {
                    val stateHint = exit.processStateSummary?.toString(Charsets.UTF_8)
                    OrbLog.e(OrbLog.Category.Crash, formatCrashSummary("exit:${exit.reason}", stateHint ?: screen, missionId, turnCount, null, null))
                    prefs.edit().putLong("last_reported_exit_ts", exit.timestamp).apply()
                }
            }
            val previous = Thread.getDefaultUncaughtExceptionHandler()
            Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
                record(prefs, thread.name, throwable)
                previous?.uncaughtException(thread, throwable)
            }
            installed = true
        }
    }

    fun formatCrashSummary(reason: String, screen: String?, missionId: String?, turnCount: Int?, exceptionClass: String?, topFrame: String?): String =
        listOfNotNull("reason=$reason", screen?.let { "screen=$it" }, missionId?.let { "missionId=$it" }, turnCount?.let { "turnCount=$it" }, exceptionClass?.let { "exception=$it" }, topFrame?.let { "frame=$it" }).joinToString(" ")

    fun recordCrashForTest(context: Context, throwable: Throwable) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        record(prefs, "test", throwable)
    }
    fun drainPendingForTest(context: Context) {
        drain(context.getSharedPreferences(PREFS, Context.MODE_PRIVATE))
    }
    private fun record(prefs: android.content.SharedPreferences, thread: String, throwable: Throwable) {
        val top = throwable.stackTrace.firstOrNull()?.let { "${it.className}.${it.methodName}:${it.lineNumber}" }
        val json = JSONObject().put("atEpochMs", System.currentTimeMillis()).put("screen", screen)
            .put("missionId", missionId).put("turnCount", turnCount).put("exceptionClass", throwable.javaClass.name)
            .put("topFrame", top).put("memoryMb", Runtime.getRuntime().totalMemory() / 1024 / 1024).put("thread", thread)
        prefs.edit().putString("last_crash", json.toString()).commit()
    }
    private fun persistActive() {
        preferences?.edit()?.putString("active_screen", screen)?.putString("active_mission_id", missionId)
            ?.putInt("active_turn_count", turnCount)?.apply()
        if (Build.VERSION.SDK_INT >= 30) {
            val summary = "$screen:${missionId.orEmpty().take(36)}:$turnCount".toByteArray(Charsets.UTF_8)
            runCatching { activityManager?.setProcessStateSummary(summary.copyOf(minOf(summary.size, 128))) }
        }
    }
    private fun drain(prefs: android.content.SharedPreferences) {
        val raw = prefs.getString("last_crash", null) ?: return
        runCatching { JSONObject(raw) }.getOrNull()?.let { json ->
            OrbLog.e(OrbLog.Category.Crash, formatCrashSummary("uncaught", json.optString("screen"), json.optString("missionId").ifBlank { null }, json.optInt("turnCount"), json.optString("exceptionClass"), json.optString("topFrame")))
        }
        prefs.edit().remove("last_crash").commit()
    }
}

/**
 * [runCatching] that records failures in [OrbLog] instead of dropping them.
 * Cancellation is not logged (it is normal when a screen goes away).
 */
inline fun <T> orbTry(category: OrbLog.Category, what: String, block: () -> T): Result<T> =
    try {
        Result.success(block())
    } catch (t: Throwable) {
        if (t !is CancellationException) OrbLog.w(category, "$what failed", t)
        Result.failure(t)
    }
