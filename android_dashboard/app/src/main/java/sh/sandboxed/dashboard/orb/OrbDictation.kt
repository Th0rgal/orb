package sh.sandboxed.dashboard.orb

import android.annotation.SuppressLint
import android.content.Context
import android.content.SharedPreferences
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.Locale
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/** Dictation language, stored like iOS `orb.dictationLanguage`; empty = device language. */
object OrbDictationSettings {
    private const val PREFS = "orb.dictation"
    private const val KEY = "orb.dictationLanguage"

    /** Languages accepted by `src/api/voice.rs`. */
    val languages: List<Pair<String, String>> = listOf(
        "en" to "English", "fr" to "Français", "de" to "Deutsch", "es" to "Español",
        "it" to "Italiano", "pt" to "Português", "nl" to "Nederlands", "pl" to "Polski",
        "el" to "Ελληνικά", "ar" to "العربية", "ja" to "日本語", "zh" to "中文",
        "vi" to "Tiếng Việt", "ko" to "한국어"
    )

    private var prefs: SharedPreferences? = null
    var stored by mutableStateOf("")
        private set

    fun init(context: Context) {
        if (prefs != null) return
        val p = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        prefs = p
        stored = p.getString(KEY, "") ?: ""
    }

    fun update(code: String) {
        stored = code
        prefs?.edit()?.putString(KEY, code)?.apply()
    }

    val deviceLanguage: String
        get() {
            val code = Locale.getDefault().language
            return if (languages.any { it.first == code }) code else "en"
        }

    fun resolve(code: String = stored): String = if (languages.any { it.first == code }) code else deviceLanguage

    fun name(code: String): String = languages.firstOrNull { it.first == code }?.second ?: code
}

/** Records mono 16 kHz 16-bit PCM, the only format `/api/voice/transcribe` accepts. */
class OrbSparkRecorder(
    private val sourceFactory: () -> AudioSource? = ::createPlatformAudioSource,
    private val joinTimeoutMs: Long = JOIN_TIMEOUT_MS,
) {
    interface AudioSource {
        val bufferSize: Int
        fun startRecording()
        fun read(buffer: ByteArray, offset: Int, size: Int): Int
        fun stop()
        fun release()
    }

    internal class SessionState(
        val sessionGeneration: Long,
        val pcmBuffer: ByteArrayOutputStream,
        val running: AtomicBoolean,
        val workerThread: Thread,
        private val source: AudioSource,
    ) {
        val completed = AtomicBoolean(false)
        private val stopped = AtomicBoolean(false)
        private val released = AtomicBoolean(false)

        fun stopSourceOnce() {
            if (stopped.compareAndSet(false, true)) {
                runCatching { source.stop() }
            }
        }

        fun releaseSourceOnce() {
            stopSourceOnce()
            if (released.compareAndSet(false, true)) {
                runCatching { source.release() }
            }
        }
    }

    companion object {
        const val SAMPLE_RATE = 16_000
        const val MAX_SECONDS = 120
        const val MAX_BYTES = 4 * 1024 * 1024
        const val JOIN_TIMEOUT_MS = 1_500L

        @SuppressLint("MissingPermission")
        private fun createPlatformAudioSource(): AudioSource? {
            val minBuf = AudioRecord.getMinBufferSize(
                SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
            )
            if (minBuf <= 0) return null
            val record = runCatching {
                AudioRecord(
                    MediaRecorder.AudioSource.VOICE_RECOGNITION,
                    SAMPLE_RATE,
                    AudioFormat.CHANNEL_IN_MONO,
                    AudioFormat.ENCODING_PCM_16BIT,
                    minBuf * 2,
                )
            }.getOrNull() ?: return null
            if (record.state != AudioRecord.STATE_INITIALIZED) {
                record.release()
                return null
            }
            return object : AudioSource {
                override val bufferSize: Int = minBuf
                override fun startRecording() = record.startRecording()
                override fun read(buffer: ByteArray, offset: Int, size: Int): Int =
                    record.read(buffer, offset, size)
                override fun stop() = record.stop()
                override fun release() = record.release()
            }
        }
    }

    private val stateLock = Any()
    private val generationCounter = AtomicLong(0L)
    @Volatile private var activeSession: SessionState? = null

    val currentGeneration: Long
        get() = generationCounter.get()

    val elapsedSeconds: Int
        get() {
            val session = activeSession ?: return 0
            if (session.sessionGeneration != generationCounter.get()) return 0
            return synchronized(session.pcmBuffer) { session.pcmBuffer.size() / (SAMPLE_RATE * 2) }
        }

    fun isCurrentGeneration(generation: Long): Boolean =
        generation > 0L && generationCounter.get() == generation

    fun runIfCurrent(generation: Long, block: () -> Unit): Boolean {
        synchronized(stateLock) {
            if (!isCurrentGeneration(generation)) return false
        }
        block()
        return true
    }

    suspend fun transcribeSession(
        generation: Long,
        wav: ByteArray,
        transcribe: suspend (ByteArray) -> String,
        onResult: (String?) -> Unit,
    ): Boolean {
        if (!isCurrentGeneration(generation)) return false
        val text = runCatching { transcribe(wav) }.getOrNull()
        val shouldPublish = synchronized(stateLock) {
            isCurrentGeneration(generation)
        }
        if (!shouldPublish) return false
        onResult(text)
        return true
    }

    fun start(): Boolean {
        val (previous, myGen) = synchronized(stateLock) {
            val prev = activeSession
            activeSession = null
            val next = generationCounter.incrementAndGet()
            prev to next
        }
        if (previous != null) {
            terminateSession(previous)
        }
        if (generationCounter.get() != myGen) {
            return false
        }

        val source = sourceFactory() ?: return false
        val minBuf = source.bufferSize
        if (minBuf <= 0 || generationCounter.get() != myGen) {
            runCatching { source.release() }
            return false
        }
        val startedOk = runCatching { source.startRecording() }.isSuccess
        if (!startedOk || generationCounter.get() != myGen) {
            runCatching { source.stop() }
            runCatching { source.release() }
            return false
        }

        val pcmBuffer = ByteArrayOutputStream()
        val running = AtomicBoolean(true)
        lateinit var session: SessionState
        val worker = Thread(
            {
                val buf = ByteArray(minBuf)
                val limit = minOf(MAX_SECONDS * SAMPLE_RATE * 2, MAX_BYTES - 44)
                try {
                    while (running.get() && generationCounter.get() == myGen) {
                        val n = runCatching { source.read(buf, 0, buf.size) }.getOrDefault(-1)
                        if (!running.get() || generationCounter.get() != myGen) break
                        if (n > 0) {
                            synchronized(pcmBuffer) {
                                if (!running.get() || generationCounter.get() != myGen || session.completed.get()) return@synchronized
                                val room = limit - pcmBuffer.size()
                                if (room <= 0) {
                                    running.set(false)
                                } else {
                                    pcmBuffer.write(buf, 0, minOf(n, room))
                                    if (pcmBuffer.size() >= limit) {
                                        running.set(false)
                                    }
                                }
                            }
                        } else if (n < 0) {
                            running.set(false)
                        }
                    }
                } finally {
                    session.completed.set(true)
                    session.releaseSourceOnce()
                }
            },
            "OrbSparkRecorder-$myGen",
        )
        session = SessionState(
            sessionGeneration = myGen,
            pcmBuffer = pcmBuffer,
            running = running,
            workerThread = worker,
            source = source,
        )
        val installed = synchronized(stateLock) {
            if (generationCounter.get() != myGen) {
                false
            } else {
                activeSession = session
                true
            }
        }
        if (!installed) {
            running.set(false)
            session.releaseSourceOnce()
            return false
        }
        worker.start()
        return true
    }

    /** Stops recording and returns a WAV file, or null when nothing was captured. */
    fun stop(): ByteArray? = stopSession()?.second

    fun stopSession(): Pair<Long, ByteArray>? {
        val session = synchronized(stateLock) {
            val cur = activeSession ?: return null
            if (cur.sessionGeneration != generationCounter.get()) {
                activeSession = null
                return null
            }
            activeSession = null
            cur
        }
        val joined = terminateSession(session)
        if (!isCurrentGeneration(session.sessionGeneration)) return null
        val data = synchronized(session.pcmBuffer) {
            session.completed.set(true)
            session.pcmBuffer.toByteArray()
        }
        if (!joined && session.workerThread.isAlive) {
            session.running.set(false)
        }
        if (data.isEmpty() || !isCurrentGeneration(session.sessionGeneration)) return null
        return session.sessionGeneration to wav(data)
    }

    fun cancel() {
        val session = synchronized(stateLock) {
            generationCounter.incrementAndGet()
            val cur = activeSession
            activeSession = null
            cur
        }
        if (session != null) {
            session.completed.set(true)
            terminateSession(session)
        }
    }

    private fun terminateSession(session: SessionState): Boolean {
        session.running.set(false)
        session.stopSourceOnce()
        if (Thread.currentThread() !== session.workerThread) {
            runCatching { session.workerThread.join(joinTimeoutMs) }
        }
        if (!session.workerThread.isAlive) {
            session.releaseSourceOnce()
            return true
        }
        return false
    }

    private fun wav(data: ByteArray): ByteArray {
        val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
        header.put("RIFF".toByteArray()).putInt(36 + data.size).put("WAVE".toByteArray())
        header.put("fmt ".toByteArray()).putInt(16).putShort(1).putShort(1)
            .putInt(SAMPLE_RATE).putInt(SAMPLE_RATE * 2).putShort(2).putShort(16)
        header.put("data".toByteArray()).putInt(data.size)
        return header.array() + data
    }
}

object OrbSparkTranscriber {
    /** `POST /api/voice/transcribe?language=` with raw WAV bytes; returns `text`. */
    suspend fun transcribe(core: OrbCore, wav: ByteArray, language: String): String = withContext(Dispatchers.IO) {
        if (wav.size > OrbSparkRecorder.MAX_BYTES) throw OrbError("Recording is too long.")
        val client = core.httpClient.newBuilder()
            .callTimeout(100, TimeUnit.SECONDS)
            .readTimeout(100, TimeUnit.SECONDS)
            .build()
        val req = Request.Builder()
            .url(core.makeURL("/api/voice/transcribe?language=${core.encodeComponent(language)}"))
            .post(wav.toRequestBody("audio/wav".toMediaType()))
            .header("Accept", "application/json")
            .apply { core.token?.trim()?.takeIf { it.isNotEmpty() }?.let { header("Authorization", "Bearer $it") } }
            .build()
        client.newCall(req).execute().use { resp ->
            val bytes = resp.body?.bytes() ?: ByteArray(0)
            val dict = OrbJSON.dict(OrbJSON.parse(bytes))
            if (!resp.isSuccessful) {
                throw OrbError(OrbJSON.str(dict, "error", "message") ?: "Transcription failed (HTTP ${resp.code})", resp.code)
            }
            OrbJSON.rawStr(dict, "text")?.trim().orEmpty()
        }
    }
}
