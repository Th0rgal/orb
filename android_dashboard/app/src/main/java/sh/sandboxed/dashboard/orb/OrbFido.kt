package sh.sandboxed.dashboard.orb

import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume

/** A `fido_sign_request` event from Core (SSH signing through the FIDO agent proxy). */
data class OrbFidoRequest(
    val requestId: String,
    val keyType: String,
    val keyFingerprint: String,
    val origin: String,
    val hostname: String?,
    val workspace: String?,
    val expiresAt: String,
) {
    fun isExpired(nowMs: Long): Boolean {
        val exp = OrbJSON.dateEpochMs(expiresAt) ?: return false
        return nowMs >= exp
    }
}

/**
 * FIDO approvals: listens on Core's control stream while signed in and shows each
 * signing request; Approve needs a biometric (or device credential), Deny does not.
 */
object OrbFido {
    const val EVENT_TYPE = "fido_sign_request"
    const val RESPOND_PATH = "/api/fido/respond"
    /** Filtered to FIDO events so the monitor does not receive every mission event. */
    const val STREAM_PATH = "/api/control/stream?kinds=fido"
    /** Requests still waiting for an answer; fetched on each (re)connect. Core has no push channel. */
    const val PENDING_PATH = "/api/fido/pending"

    private val _pending = MutableStateFlow<List<OrbFidoRequest>>(emptyList())
    val pending: StateFlow<List<OrbFidoRequest>> = _pending.asStateFlow()

    private val _inFlight = MutableStateFlow<Set<String>>(emptySet())
    val inFlight: StateFlow<Set<String>> = _inFlight.asStateFlow()

    private val _errors = MutableStateFlow<Map<String, String>>(emptyMap())
    val errors: StateFlow<Map<String, String>> = _errors.asStateFlow()

    /** Parse a stream event; null if it is not a usable FIDO request. */
    fun parse(eventType: String?, data: String): OrbFidoRequest? {
        val dict = OrbJSON.dict(OrbJSON.parse(data)) ?: return null
        val type = eventType?.takeIf { it.isNotEmpty() && it != "message" } ?: OrbJSON.str(dict, "type")
        if (type != EVENT_TYPE) return null
        return fromDict(dict)
    }

    /** Parse a `GET /api/fido/pending` response (`{"requests":[...]}`). */
    fun parsePending(response: Any?): List<OrbFidoRequest> =
        (OrbJSON.dict(response)?.get("requests") as? List<*>).orEmpty()
            .mapNotNull { item -> OrbJSON.dict(item)?.let(::fromDict) }

    private fun fromDict(dict: OrbDict): OrbFidoRequest? {
        val id = OrbJSON.str(dict, "request_id")?.takeIf { it.isNotBlank() } ?: return null
        return OrbFidoRequest(
            requestId = id,
            keyType = OrbJSON.str(dict, "key_type").orEmpty(),
            keyFingerprint = OrbJSON.str(dict, "key_fingerprint").orEmpty(),
            origin = OrbJSON.str(dict, "origin").orEmpty(),
            hostname = OrbJSON.str(dict, "hostname"),
            workspace = OrbJSON.str(dict, "workspace"),
            expiresAt = OrbJSON.str(dict, "expires_at").orEmpty(),
        )
    }

    /** Body for POST /api/fido/respond (matches Core's FidoRespondBody). */
    fun respondBody(requestId: String, approved: Boolean): Map<String, Any?> =
        mapOf("request_id" to requestId, "approved" to approved)

    /** Reconnect delay after [attempt] consecutive failures: 1 s, 2 s, 4 s … capped at 30 s. */
    fun backoffMs(attempt: Int): Long = (1_000L shl attempt.coerceIn(0, 5)).coerceAtMost(30_000L)

    fun enqueue(req: OrbFidoRequest) {
        if (req.requestId in _inFlight.value) return
        _pending.update { cur -> if (cur.any { it.requestId == req.requestId }) cur else cur + req }
    }

    fun resolve(requestId: String) {
        _pending.update { cur -> cur.filterNot { it.requestId == requestId } }
        _errors.update { it - requestId }
    }

    fun dropExpired(nowMs: Long = System.currentTimeMillis()) {
        _pending.update { cur ->
            cur.filterNot { it.isExpired(nowMs) && it.requestId !in _errors.value && it.requestId !in _inFlight.value }
        }
    }

    fun interface Transport {
        suspend fun post(path: String, body: Map<String, Any?>): Any?
    }

    fun clear() {
        _pending.value = emptyList()
        _inFlight.value = emptySet()
        _errors.value = emptyMap()
        OrbFidoSettings.trust.clear()
    }

    /**
     * Stream until cancelled (the caller scopes this to "signed in and visible").
     * Returns at once if the session has no endpoint or token.
     */
    suspend fun listen(core: OrbCore) {
        var attempt = 0
        while (true) {
            if (!core.isConfigured || core.token.isNullOrBlank()) return
            val error: Throwable? = try {
                // Requests made while the app was closed or the stream was down.
                val now = System.currentTimeMillis()
                parsePending(core.request(PENDING_PATH)).filterNot { it.isExpired(now) }.forEach(::enqueue)
                streamOnce(core) { attempt = 0 }
            } catch (c: CancellationException) {
                throw c
            } catch (t: Throwable) {
                t
            }
            if (error != null) OrbLog.w(OrbLog.Category.Network, "FIDO stream closed", error)
            dropExpired()
            delay(backoffMs(attempt))
            attempt += 1
        }
    }

    private suspend fun streamOnce(core: OrbCore, onAnyEvent: () -> Unit): Throwable? =
        suspendCancellableCoroutine { cont ->
            val source = core.openSSE(
                path = STREAM_PATH,
                onEvent = { type, data ->
                    onAnyEvent()
                    parse(type, data)?.let { req ->
                        if (!req.isExpired(System.currentTimeMillis())) enqueue(req)
                    }
                },
                onClosed = { t -> if (cont.isActive) cont.resume(t) }
            )
            cont.invokeOnCancellation { source.cancel() }
        }

    private fun tryStartInFlight(requestId: String): Boolean {
        var added = false
        _inFlight.update { cur ->
            if (requestId in cur) {
                added = false
                cur
            } else {
                added = true
                cur + requestId
            }
        }
        return added
    }

    internal fun isTerminalRespondError(t: Throwable): Boolean {
        val err = t as? OrbError ?: return false
        val status = err.status ?: return false
        if (status == 404 || status == 410) return true
        if (status !in 400..499) return false
        val dict = err.body?.let { OrbJSON.dict(OrbJSON.parse(it)) } ?: return false
        return dict["error"] == "already_resolved" || dict["code"] == "already_resolved"
    }

    suspend fun respond(core: OrbCore, requestId: String, approved: Boolean): Boolean =
        respond(Transport { path, body -> core.request(path, method = "POST", body = body) }, requestId, approved)

    suspend fun respond(
        transport: Transport,
        requestId: String,
        approved: Boolean,
    ): Boolean {
        if (!tryStartInFlight(requestId)) return false
        _errors.update { it - requestId }
        try {
            transport.post(RESPOND_PATH, respondBody(requestId, approved))
            resolve(requestId)
            return true
        } catch (c: CancellationException) {
            _errors.update { it + (requestId to "Response interrupted. Retry approval or deny.") }
            throw c
        } catch (t: Throwable) {
            OrbLog.w(OrbLog.Category.Network, "FIDO respond ($approved) failed", t)
            if (isTerminalRespondError(t)) {
                resolve(requestId)
                return true
            }
            val msg = t.message?.takeIf { it.isNotBlank() } ?: t::class.simpleName ?: "Request failed"
            _errors.update { it + (requestId to msg) }
            return false
        } finally {
            _inFlight.update { it - requestId }
        }
    }

    private const val AUTHENTICATORS =
        BiometricManager.Authenticators.BIOMETRIC_STRONG or BiometricManager.Authenticators.DEVICE_CREDENTIAL

    /**
     * Biometric (fingerprint / face) with device-credential fallback. Null if cancelled or
     * unavailable, otherwise the telemetry method (biometric -> touch_id, PIN/pattern -> passcode).
     */
    suspend fun authenticate(activity: FragmentActivity, req: OrbFidoRequest): UsageTelemetry.Method? {
        if (BiometricManager.from(activity).canAuthenticate(AUTHENTICATORS) != BiometricManager.BIOMETRIC_SUCCESS) {
            OrbLog.w(OrbLog.Category.Auth, "FIDO approval: no biometric or device credential enrolled")
            return null
        }
        return suspendCancellableCoroutine { cont ->
            val prompt = BiometricPrompt(
                activity,
                ContextCompat.getMainExecutor(activity),
                object : BiometricPrompt.AuthenticationCallback() {
                    override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                        if (cont.isActive) cont.resume(
                            if (result.authenticationType == BiometricPrompt.AUTHENTICATION_RESULT_TYPE_DEVICE_CREDENTIAL) UsageTelemetry.Method.Passcode
                            else UsageTelemetry.Method.TouchId
                        )
                    }

                    override fun onAuthenticationError(code: Int, message: CharSequence) {
                        if (cont.isActive) cont.resume(null)
                    }
                }
            )
            val info = BiometricPrompt.PromptInfo.Builder()
                .setTitle("Approve SSH signing")
                .setSubtitle((req.hostname ?: req.origin).take(120))
                .setAllowedAuthenticators(AUTHENTICATORS)
                .build()
            prompt.authenticate(info)
            cont.invokeOnCancellation { prompt.cancelAuthentication() }
        }
    }
}

@Composable
fun OrbFidoApprovalDialog(core: OrbCore) {
    val pending by OrbFido.pending.collectAsState()
    val inFlight by OrbFido.inFlight.collectAsState()
    val errors by OrbFido.errors.collectAsState()
    val req = pending.firstOrNull() ?: return
    var authenticating by remember(req.requestId) { mutableStateOf(false) }
    val busy = req.requestId in inFlight || authenticating
    val errorText = errors[req.requestId]
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    remember(context) { OrbFidoSettings.init(context); true }
    val shownAt = remember(req.requestId) { System.currentTimeMillis() }
    var autoAttempted by remember(req.requestId) { mutableStateOf(false) }
    var approvedMethod by remember(req.requestId) { mutableStateOf<UsageTelemetry.Method?>(null) }
    fun record(decision: UsageTelemetry.Decision, method: UsageTelemetry.Method) = UsageTelemetry.trackApproval(
        UsageTelemetry.ApprovalKind.Tool, decision, method, System.currentTimeMillis() - shownAt, toolName = "ssh_sign"
    )
    // Opt-in trust window (default off): same key + host, shortly after a biometric approval.
    val isTrusted = OrbFidoSettings.trust.isTrusted(req)
    LaunchedEffect(req.requestId, isTrusted) {
        if (isTrusted && !autoAttempted && errorText == null) {
            autoAttempted = true
            OrbLog.d(OrbLog.Category.Auth, "FIDO request approved by trust window")
            OrbFido.respond(core, req.requestId, approved = true)
        }
    }
    if (isTrusted && (!autoAttempted || busy) && errorText == null) {
        return
    }
    AlertDialog(
        onDismissRequest = { /* explicit decision required */ },
        containerColor = OrbStyle.card,
        title = { Text("Approve signing request?", color = Color.White) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("Origin: ${req.origin}", color = Color.White, fontSize = 14.sp)
                req.hostname?.let { Text("Host: $it", color = Color.White, fontSize = 14.sp) }
                req.workspace?.let { Text("Workspace: $it", color = Color.White, fontSize = 14.sp) }
                Text("Key: ${req.keyType}", color = Color.White, fontSize = 14.sp)
                Text(req.keyFingerprint, color = OrbStyle.textMuted, fontSize = 11.sp, fontFamily = FontFamily.Monospace)
                if (!errorText.isNullOrBlank()) {
                    Text(errorText, color = OrbStyle.warning, fontSize = 12.sp)
                }
            }
        },
        confirmButton = {
            TextButton(
                enabled = !busy,
                onClick = {
                    if (busy) return@TextButton
                    scope.launch {
                        if (OrbFidoSettings.trust.isTrusted(req) || approvedMethod != null) {
                            val method = approvedMethod
                            if (OrbFido.respond(core, req.requestId, approved = true) && method != null) {
                                record(UsageTelemetry.Decision.Approved, method)
                            }
                            return@launch
                        }
                        val activity = context.fragmentActivity()
                        val method = try {
                            authenticating = true
                            activity?.let { OrbFido.authenticate(it, req) }
                        } finally {
                            authenticating = false
                        }
                        if (method != null) {
                            approvedMethod = method
                            OrbFidoSettings.trust.recordBiometricApproval(req)
                            if (OrbFido.respond(core, req.requestId, approved = true)) {
                                record(UsageTelemetry.Decision.Approved, method)
                            }
                        }
                        // Cancelled prompt: keep the request on screen so the user can retry or deny.
                    }
                }
            ) { Text(if (busy) "Sending…" else if (errorText != null) "Retry" else "Approve", color = Color.White) }
        },
        dismissButton = {
            TextButton(
                enabled = !busy,
                onClick = {
                    if (busy) return@TextButton
                    scope.launch {
                        if (OrbFido.respond(core, req.requestId, approved = false)) {
                            record(UsageTelemetry.Decision.Denied, UsageTelemetry.Method.None)
                        }
                    }
                }
            ) { Text("Deny", color = OrbStyle.error) }
        }
    )
}
