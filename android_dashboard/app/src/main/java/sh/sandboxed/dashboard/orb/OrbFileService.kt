package sh.sandboxed.dashboard.orb

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.File
import java.io.IOException
import java.net.ConnectException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.security.MessageDigest
import kotlin.coroutines.coroutineContext

/** Why a shared file could not be opened, in words the person can act on. */
sealed class OrbFileError(message: String, val rank: Int) : Exception(message) {
    class NotFound(name: String) : OrbFileError("$name is no longer in the mission workspace.", 0)
    class Failed(detail: String) : OrbFileError(detail, 1)
    object MachineOffline : OrbFileError("The machine running this mission is offline or unreachable. Try again when it is back.", 2)
    object Unauthorized : OrbFileError("Your session expired. Sign in again to open this file.", 3)
    object Offline : OrbFileError("You’re offline. Connect to the internet and try again.", 4)

    companion object {
        /** Core's file routes answer with plain-text errors; map them to a cause. */
        fun from(status: Int, body: String, name: String): OrbFileError {
            val text = body.lowercase()
            if (status == 401) return Unauthorized
            if (listOf("unreachable", "destination unavailable", "remote file source is unavailable", "remote job is unavailable", "update the node").any { it in text } ||
                status in setOf(502, 503, 504)
            ) return MachineOffline
            if (status == 404 || listOf("not found", "no such file", "file is unavailable", "outside").any { it in text }) return NotFound(name)
            return Failed(if (body.isEmpty()) "Couldn’t open $name (HTTP $status)." else "Couldn’t open $name: ${body.take(200)}")
        }

        fun from(error: Throwable, name: String): OrbFileError = when (error) {
            is OrbFileError -> error
            is UnknownHostException -> Offline
            is ConnectException, is SocketTimeoutException -> Failed("Orb couldn’t reach the server. Try again.")
            is OrbError -> from(error.status ?: 0, error.body ?: error.message ?: "", name)
            else -> Failed(error.message ?: "Couldn’t open $name.")
        }
    }
}

data class OrbWorkspaceEntry(val name: String, val path: String, val isDirectory: Boolean, val size: Long?)

/** [source] names another session of the replacement chain (`earlier:<id>`); null is the mission's own workspace. */
data class OrbFileScope(val missionId: String?, val workspaceId: String?, val source: String? = null)

/** An earlier or later attempt of this mission on the same machine, browsable read-only. */
data class OrbFileSession(val id: String, val label: String, val later: Boolean)

/**
 * Fetches shared and workspace files for previews and the share sheet.
 *
 * Order, matching desktop Orb (`fileResources.ts`) and iOS `OrbFileService`:
 * 1. the `shared_files` url Core published (`/api/fs/download`, streamed with progress);
 * 2. the mission's workspace through `POST /api/file-resources` (`resolve`, then 1 MiB
 *    `download` chunks). Core proxies this to remote nodes, managed machines and
 *    transferred workspaces, so it is the only path that reaches them;
 * 3. `/api/fs/download?path=…&mission_id=…` for Core paths outside the workspace.
 */
class OrbFileService(private val core: OrbCore, context: Context) {
    private val cacheRoot = File(context.cacheDir, "orb-files")
    private val locks = mutableMapOf<String, Mutex>()

    companion object {
        @Volatile private var instance: OrbFileService? = null
        fun get(core: OrbCore, context: Context): OrbFileService =
            instance ?: synchronized(this) { instance ?: OrbFileService(core, context.applicationContext).also { instance = it } }
    }

    private fun cacheKey(ref: OrbFileRef, scope: OrbFileScope): String {
        val raw = listOf(runCatching { core.makeURL("/") }.getOrDefault(""), core.token ?: "", scope.workspaceId ?: "", scope.missionId ?: "", scope.source ?: "", ref.url ?: "", ref.path, ref.size?.toString() ?: "")
            .joinToString("\u001f")
        return MessageDigest.getInstance("SHA-256").digest(raw.toByteArray()).take(12).joinToString("") { "%02x".format(it) }
    }

    private fun destination(ref: OrbFileRef, scope: OrbFileScope): File {
        val name = ref.name.let { if (it in setOf("", ".", "..")) "file" else it.replace('/', '_') }
        return File(File(cacheRoot, cacheKey(ref, scope)), name)
    }

    fun cached(ref: OrbFileRef, scope: OrbFileScope): File? = destination(ref, scope).takeIf { it.isFile }

    /** Downloads [ref] to the cache. [progress] gets 0…1, or null while the size is unknown. */
    suspend fun fetch(ref: OrbFileRef, scope: OrbFileScope, progress: (Float?) -> Unit = {}): File {
        cached(ref, scope)?.let { progress(1f); return it }
        val key = cacheKey(ref, scope)
        val lock = synchronized(locks) { locks.getOrPut(key) { Mutex() } }
        return lock.withLock {
            if (key != cacheKey(ref, scope)) throw OrbFileError.Unauthorized
            cached(ref, scope)?.let { progress(1f); return@withLock it }
            val file = withContext(Dispatchers.IO) { download(ref, scope, progress) }
            if (key != cacheKey(ref, scope)) {
                file.delete()
                throw OrbFileError.Unauthorized
            }
            file
        }
    }

    private suspend fun download(ref: OrbFileRef, scope: OrbFileScope, progress: (Float?) -> Unit): File {
        val target = destination(ref, scope)
        target.parentFile?.mkdirs()
        val partial = File(target.path + ".part")
        partial.delete()
        var failure: OrbFileError = OrbFileError.NotFound(ref.label)
        fun remember(e: Throwable) {
            val mapped = OrbFileError.from(e, ref.label)
            if (mapped.rank > failure.rank) failure = mapped
        }
        // 1. Published download url.
        sameOriginUrl(ref.url)?.let { url ->
            try { stream(url, partial, ref.label, progress); return finish(partial, target) }
            catch (e: Throwable) { coroutineContext.ensureActive(); remember(e); if (failure.rank >= OrbFileError.Unauthorized.rank) throw failure }
        }
        // 2. The mission workspace, wherever it runs.
        scope.missionId?.let { mission ->
            try { workspaceDownload(ref, mission, downloadSources(ref, scope), partial, progress); return finish(partial, target) }
            catch (e: Throwable) { coroutineContext.ensureActive(); remember(e); if (failure.rank >= OrbFileError.MachineOffline.rank) throw failure }
        }
        // 3. Core paths outside the workspace (context uploads).
        val queries = mutableListOf<String>()
        val path = core.encodeComponent(ref.path)
        scope.missionId?.let { mission ->
            val ws = scope.workspaceId?.takeIf { it.isNotEmpty() }?.let { "&workspace_id=${core.encodeComponent(it)}" } ?: ""
            queries.add("/api/fs/download?path=$path$ws&mission_id=${core.encodeComponent(mission)}")
        }
        if (ref.path.startsWith("/")) queries.add("/api/fs/download?path=$path")
        for (query in queries) {
            try { stream(core.makeURL(query), partial, ref.label, progress); return finish(partial, target) }
            catch (e: Throwable) { coroutineContext.ensureActive(); remember(e); if (failure.rank >= OrbFileError.Unauthorized.rank) throw failure }
        }
        throw failure
    }

    private fun finish(partial: File, target: File): File {
        target.delete()
        if (!partial.renameTo(target)) throw OrbFileError.Failed("Couldn’t save ${target.name}.")
        return target
    }

    private fun sameOriginUrl(raw: String?): String? {
        if (raw.isNullOrEmpty()) return null
        val absolute = if (raw.startsWith("http://") || raw.startsWith("https://")) raw else runCatching { core.makeURL(raw) }.getOrNull() ?: return null
        val target = absolute.toHttpUrlOrNull() ?: return null
        val base = runCatching { core.makeURL("/").toHttpUrlOrNull() }.getOrNull() ?: return null
        return absolute.takeIf { target.scheme == base.scheme && target.host == base.host && target.port == base.port }
    }

    private fun authorized(builder: Request.Builder): Request.Builder = builder.apply {
        core.token?.trim()?.takeIf { it.isNotEmpty() }?.let { header("Authorization", "Bearer $it") }
    }

    /** Streams a GET to disk with byte progress (large files never sit in memory). */
    private suspend fun stream(url: String, file: File, name: String, progress: (Float?) -> Unit) {
        val response = try { core.httpClient.newCall(authorized(Request.Builder().url(url).get()).build()).execute() }
        catch (e: IOException) { throw OrbFileError.from(e, name) }
        response.use { resp ->
            if (!resp.isSuccessful) throw OrbFileError.from(resp.code, resp.body?.string()?.take(400) ?: "", name)
            val body = resp.body ?: throw OrbFileError.Failed("Empty response for $name.")
            val total = body.contentLength().takeIf { it > 0 }
            progress(if (total == null) null else 0f)
            body.byteStream().use { input ->
                file.outputStream().use { output ->
                    val buffer = ByteArray(64 * 1024)
                    var read = 0L
                    while (true) {
                        coroutineContext.ensureActive()
                        val n = input.read(buffer)
                        if (n < 0) break
                        output.write(buffer, 0, n)
                        read += n
                        if (total != null) progress((read.toFloat() / total).coerceIn(0f, 1f))
                    }
                }
            }
            progress(1f)
        }
    }

    private fun fileResources(body: Map<String, Any?>, name: String): OrbDict {
        val request = authorized(
            Request.Builder().url(core.makeURL("/api/file-resources"))
                .post(OrbJSON.stringify(body).toRequestBody("application/json; charset=utf-8".toMediaType()))
        ).header("Accept", "application/json").build()
        val response = try { core.httpClient.newCall(request).execute() } catch (e: IOException) { throw OrbFileError.from(e, name) }
        response.use { resp ->
            val bytes = resp.body?.bytes() ?: ByteArray(0)
            if (!resp.isSuccessful) throw OrbFileError.from(resp.code, bytes.decodeToString().take(400), name)
            return OrbJSON.dict(OrbJSON.parse(bytes)) ?: throw OrbFileError.Failed("Invalid response for $name.")
        }
    }

    /** The workspace first; an absolute path cited from an earlier session resolves there (Core checks the chain). */
    private fun downloadSources(ref: OrbFileRef, scope: OrbFileScope): List<String> {
        scope.source?.let { return listOf(it) }
        if (!ref.path.startsWith("/")) return listOf("workspace")
        return listOf("workspace") + runCatching { rootsBlocking(scope).second }.getOrDefault(emptyList()).map { it.id }
    }

    private suspend fun workspaceDownload(ref: OrbFileRef, mission: String, sources: List<String>, file: File, progress: (Float?) -> Unit) {
        var found: Pair<String, OrbDict>? = null
        for (source in sources) {
            val resolved = fileResources(mapOf("mission_id" to mission, "source" to source, "action" to "resolve", "paths" to listOf(ref.path)), ref.label)
            OrbJSON.dictList(OrbJSON.dictList(resolved["results"]).firstOrNull()?.get("matches")).firstOrNull()?.let { found = source to it; break }
        }
        val (source, match) = found ?: throw OrbFileError.NotFound(ref.label)
        val base = mapOf("mission_id" to mission, "source" to source)
        val path = match["path"] as? String ?: throw OrbFileError.NotFound(ref.label)
        var total = (match["size"] as? Number)?.toLong() ?: ref.size
        var offset = 0L
        progress(total?.let { if (it > 0) 0f else 1f })
        file.outputStream().use { output ->
            while (true) {
                coroutineContext.ensureActive()
                val chunk = fileResources(base + mapOf("action" to "download", "path" to path, "offset" to offset), ref.label)
                val bytes = (chunk["bytes"] as? List<*>)?.let { list -> ByteArray(list.size) { (list[it] as Number).toInt().toByte() } } ?: ByteArray(0)
                output.write(bytes)
                total = (chunk["size"] as? Number)?.toLong() ?: total
                offset = (chunk["next"] as? Number)?.toLong() ?: (offset + bytes.size)
                total?.takeIf { it > 0 }?.let { progress((offset.toFloat() / it).coerceIn(0f, 1f)) }
                if (bytes.isEmpty() || total?.let { offset >= it } != false) break
            }
        }
        progress(1f)
    }

    /** Whether the mission has a workspace, and the other sessions of its chain on the same machine. */
    suspend fun roots(scope: OrbFileScope): Pair<Boolean, List<OrbFileSession>> = withContext(Dispatchers.IO) { rootsBlocking(scope) }

    private fun rootsBlocking(scope: OrbFileScope): Pair<Boolean, List<OrbFileSession>> {
        val mission = scope.missionId ?: return false to emptyList()
        val sources = OrbJSON.dictList(fileResources(mapOf("mission_id" to mission, "action" to "roots"), "workspace")["sources"])
            .filter { it["available"] != false }
        return sources.any { it["id"] == "workspace" } to sources.filter { it["group"] is String }.map {
            val id = it["id"] as? String ?: ""
            OrbFileSession(id, it["label"] as? String ?: id, it["group"] == "later")
        }
    }

    /** Read-only listing of one workspace directory ("" is the root). */
    suspend fun list(scope: OrbFileScope, path: String): List<OrbWorkspaceEntry> = withContext(Dispatchers.IO) {
        val mission = scope.missionId ?: return@withContext emptyList()
        val name = path.ifEmpty { "Workspace" }
        try {
            OrbJSON.dictList(fileResources(mapOf("mission_id" to mission, "source" to (scope.source ?: "workspace"), "action" to "list", "path" to path), name)["entries"])
                .map { OrbWorkspaceEntry(it["name"] as? String ?: "", it["path"] as? String ?: "", it["kind"] == "dir", (it["size"] as? Number)?.toLong()) }
        } catch (e: Throwable) { throw OrbFileError.from(e, name) }
    }

    /** Assistant messages of the mission (tags and `shared_files`), for chips and the Files tab. */
    suspend fun messages(scope: OrbFileScope): List<OrbFileRefs.Message> {
        val mission = scope.missionId ?: return emptyList()
        return try {
            OrbFileRefs.messages(core.request("/api/control/missions/${core.encodeComponent(mission)}/events?types=assistant_message&limit=4000&include_counts=false"))
        } catch (e: Throwable) { throw OrbFileError.from(e, "Files") }
    }
}
