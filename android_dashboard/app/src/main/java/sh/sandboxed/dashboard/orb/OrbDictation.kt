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
class OrbSparkRecorder {
    companion object {
        const val SAMPLE_RATE = 16_000
        const val MAX_SECONDS = 120
        const val MAX_BYTES = 4 * 1024 * 1024
    }

    @Volatile private var running = false
    private var thread: Thread? = null
    private val pcm = ByteArrayOutputStream()

    val elapsedSeconds: Int get() = synchronized(pcm) { pcm.size() / (SAMPLE_RATE * 2) }

    @SuppressLint("MissingPermission")
    fun start(): Boolean {
        val minBuf = AudioRecord.getMinBufferSize(SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        if (minBuf <= 0) return false
        val record = runCatching {
            AudioRecord(
                MediaRecorder.AudioSource.VOICE_RECOGNITION,
                SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                minBuf * 2
            )
        }.getOrNull() ?: return false
        if (record.state != AudioRecord.STATE_INITIALIZED) {
            record.release()
            return false
        }
        synchronized(pcm) { pcm.reset() }
        running = true
        record.startRecording()
        thread = Thread {
            val buf = ByteArray(minBuf)
            val limit = minOf(MAX_SECONDS * SAMPLE_RATE * 2, MAX_BYTES - 44)
            try {
                while (running) {
                    val n = record.read(buf, 0, buf.size)
                    if (n > 0) synchronized(pcm) {
                        val room = limit - pcm.size()
                        if (room <= 0) running = false else pcm.write(buf, 0, minOf(n, room))
                    }
                }
            } finally {
                runCatching { record.stop() }
                record.release()
            }
        }.also { it.start() }
        return true
    }

    /** Stops recording and returns a WAV file, or null when nothing was captured. */
    fun stop(): ByteArray? {
        running = false
        thread?.join(1500)
        thread = null
        val data = synchronized(pcm) { pcm.toByteArray() }
        if (data.isEmpty()) return null
        return wav(data)
    }

    fun cancel() {
        running = false
        thread = null
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
