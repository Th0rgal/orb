package sh.sandboxed.dashboard.orb

import android.content.Context
import android.content.pm.PackageManager
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID
import java.util.concurrent.TimeUnit

/**
 * Headless NixOS SideSystem bridge (`com.th0rgal.sidesystem`) for running local
 * Orb agents (Claude Code, OpenCode, Codex) directly inside the phone's NixOS
 * container via `orb-locald` without starting the Hyprland/VNC desktop.
 */
object OrbSideSystem {
    const val LOCAL_NODE_ID = "local"
    const val LOCAL_LABEL = "Local computer"
    private const val SIDESYSTEM_PKG = "com.th0rgal.sidesystem"
    private const val CTL_BIN = "/data/local/nixos/bin/sidesystem-ctl"
    private val JSON_MEDIA = "application/json; charset=utf-8".toMediaType()

    private val httpClient: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(60, TimeUnit.SECONDS)
            .writeTimeout(30, TimeUnit.SECONDS)
            .build()
    }

    data class LocaldSession(
        val port: Int,
        val token: String,
        val hostname: String
    )

    data class LocalAgent(
        val id: String,
        val bin: String,
        val path: String?,
        val version: String?,
        val installed: Boolean,
        val authError: String?
    )

    @Volatile
    private var cachedInstalled: Boolean? = null

    /** Fast non-root check: only enables SideSystem integration when the companion app is present. */
    fun isInstalled(context: Context): Boolean {
        cachedInstalled?.let { return it }
        val present = runCatching {
            context.packageManager.getPackageInfo(SIDESYSTEM_PKG, PackageManager.PackageInfoFlags.of(0))
            true
        }.getOrElse {
            File(CTL_BIN).exists()
        }
        cachedInstalled = present
        return present
    }

    private fun runSuCommand(cmd: String, timeoutSec: Long = 35L): String {
        val proc = ProcessBuilder("su", "-c", cmd)
            .redirectErrorStream(false)
            .start()
        val stdout = proc.inputStream.bufferedReader().readText()
        val stderr = proc.errorStream.bufferedReader().readText()
        if (!proc.waitFor(timeoutSec, TimeUnit.SECONDS)) {
            proc.destroyForcibly()
            throw OrbError("SideSystem timed out starting headless NixOS.")
        }
        if (proc.exitValue() != 0) {
            val detail = stderr.trim().ifEmpty { stdout.trim() }.ifEmpty { "exit ${proc.exitValue()}" }
            throw OrbError("SideSystem failed: $detail")
        }
        return stdout.trim()
    }

    /**
     * Ensures the NixOS SideSystem container and headless `orb-locald` daemon are
     * running (without starting Hyprland/wayvnc desktop) and returns connection info.
     */
    suspend fun ensureLocald(): LocaldSession = withContext(Dispatchers.IO) {
        val out = runSuCommand("$CTL_BIN orb-locald start")
        val line = out.lineSequence().map { it.trim() }.lastOrNull { it.startsWith("{") }
            ?: throw OrbError("Unexpected SideSystem response: $out")
        val obj = JSONObject(line)
        if (!obj.optBoolean("running", false)) {
            throw OrbError("Headless orb-locald is not running in SideSystem.")
        }
        val port = obj.optInt("port", 19579)
        val token = obj.optString("token", "")
        val hostname = obj.optString("hostname", "razr").ifBlank { "razr" }
        if (token.length < 32) {
            throw OrbError("SideSystem orb-locald returned an invalid token.")
        }
        LocaldSession(port = port, token = token, hostname = hostname)
    }

    suspend fun rpc(session: LocaldSession, command: String, args: JSONObject = JSONObject()): Any? =
        withContext(Dispatchers.IO) {
            val payload = JSONObject()
                .put("command", command)
                .put("args", args)
                .toString()
            val req = Request.Builder()
                .url("http://127.0.0.1:${session.port}/__orb_rpc")
                .header("X-Orb-Token", session.token)
                .post(payload.toRequestBody(JSON_MEDIA))
                .build()
            httpClient.newCall(req).execute().use { resp ->
                val text = resp.body?.string().orEmpty()
                val parsed = runCatching { JSONObject(text) }.getOrNull()
                if (!resp.isSuccessful) {
                    val err = parsed?.optString("error")?.takeIf { it.isNotBlank() } ?: "HTTP ${resp.code}"
                    throw OrbError("SideSystem orb-locald error: $err")
                }
                val err = parsed?.optString("error")?.takeIf { it.isNotBlank() }
                if (err != null) throw OrbError(err)
                parsed?.opt("result")
            }
        }

    suspend fun scanAgents(session: LocaldSession): List<LocalAgent> {
        val arr = rpc(session, "local_agents_scan") as? JSONArray ?: return emptyList()
        return buildList {
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                add(
                    LocalAgent(
                        id = o.optString("id"),
                        bin = o.optString("bin"),
                        path = o.optString("path").takeIf { it.isNotBlank() && it != "null" },
                        version = o.optString("version").takeIf { it.isNotBlank() && it != "null" },
                        installed = o.optBoolean("installed", false),
                        authError = o.optString("auth_error").takeIf { it.isNotBlank() && it != "null" }
                    )
                )
            }
        }
    }

    suspend fun launchLocalMission(
        core: OrbCore,
        projectSlug: String,
        prompt: String,
        backend: String,
        model: String,
        title: String,
        permissionMode: String? = null
    ): OrbRow {
        val session = ensureLocald()
        val agents = scanAgents(session)
        val effectiveBackend = backend.ifBlank { "claudecode" }
        val agent = agents.firstOrNull { it.id == effectiveBackend }
        val binPath = agent?.path?.takeIf { agent.installed }
            ?: throw OrbError("$effectiveBackend CLI is not installed in NixOS SideSystem.")

        val slug = projectSlug.ifBlank { "default" }
        val cwd = (rpc(session, "local_agents_workspace", JSONObject().put("project", slug)) as? String)
            ?.takeIf { it.isNotBlank() }
            ?: "/home/thomas/.orb/workspaces/$slug"

        val requestObj = JSONObject()
            .put("id", "")
            .put("harness", effectiveBackend)
            .put("bin", binPath)
            .put("cwd", cwd)
            .put("prompt", prompt)
            .put("session_id", JSONObject.NULL)
            .put("image_paths", JSONArray())
        if (model.isNotBlank()) requestObj.put("model", model)
        if (!permissionMode.isNullOrBlank() && effectiveBackend == "claudecode") {
            requestObj.put("permission_mode", permissionMode)
        }

        val draftObj = JSONObject()
            .put("key", UUID.randomUUID().toString())
            .put("title", title.ifBlank { prompt.lineSequence().firstOrNull()?.take(72) ?: "Local mission" })
            .put("project", slug)
            .put("prompt", prompt)
            .put("tags", JSONArray())

        val connObj = JSONObject()
            .put("api_url", core.baseURL)
            .put("token", core.token.orEmpty())

        val args = JSONObject()
            .put("request", requestObj)
            .put("draft", draftObj)
            .put("connection", connObj)

        val raw = rpc(session, "local_origin_launch", args)
        val dict = OrbJSON.dict(OrbJSON.parse(raw?.toString() ?: "{}"))
            ?: throw OrbError("SideSystem orb-locald did not return a mission.")
        return OrbRow(dict)
    }
}
