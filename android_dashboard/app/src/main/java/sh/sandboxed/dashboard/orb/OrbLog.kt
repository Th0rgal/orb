package sh.sandboxed.dashboard.orb

import android.util.Log
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import sh.sandboxed.dashboard.BuildConfig
import java.time.Instant

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
