package sh.sandboxed.dashboard.orb

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.ContextWrapper
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.security.keystore.StrongBoxUnavailableException
import android.util.Base64
import android.widget.Toast
import androidx.biometric.BiometricPrompt
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.Signature
import java.security.spec.ECGenParameterSpec
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * Device-signed approvals on Android. Core accepts sensitive secret operations
 * only with a signature from an enrolled device key. This phone's key lives in
 * the Android Keystore (StrongBox when available), cannot be exported, and
 * every signature needs a strong biometric (fingerprint / face class 3).
 */
object OrbApprovalKey {
    private const val ALIAS = "orb_approval_key"
    private const val PREFS = "orb_approvals"

    class Cancelled : Exception("Approval cancelled")

    private fun keyStore() = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    fun publicKey(): String? {
        val cert = keyStore().getCertificate(ALIAS) ?: return null
        return Base64.encodeToString(cert.publicKey.encoded, Base64.NO_WRAP)
    }

    fun create(): String {
        fun spec(strongBox: Boolean) = KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_SIGN)
            .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
            .setDigests(KeyProperties.DIGEST_SHA256)
            .setUserAuthenticationRequired(true)
            .setInvalidatedByBiometricEnrollment(true)
            .apply {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG)
                }
                if (strongBox && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) setIsStrongBoxBacked(true)
            }
            .build()
        val gen = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore")
        try {
            gen.initialize(spec(strongBox = true))
            gen.generateKeyPair()
        } catch (e: StrongBoxUnavailableException) {
            gen.initialize(spec(strongBox = false))
            gen.generateKeyPair()
        }
        return publicKey() ?: error("Keystore did not return a public key")
    }

    private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    fun deviceId(context: Context, baseURL: String): String? = prefs(context).getString("device.$baseURL", null)
    fun setDeviceId(context: Context, baseURL: String, id: String?) {
        prefs(context).edit().apply { if (id == null) remove("device.$baseURL") else putString("device.$baseURL", id) }.apply()
    }

    /** Ask for a strong biometric and sign `payload` (ECDSA P-256, DER). */
    suspend fun sign(activity: FragmentActivity, payload: String, summary: String): String =
        suspendCancellableCoroutine { cont ->
            val key = keyStore().getKey(ALIAS, null) as? PrivateKey
            if (key == null) {
                cont.resumeWithException(IllegalStateException("This phone has no approval key"))
                return@suspendCancellableCoroutine
            }
            val signature = Signature.getInstance("SHA256withECDSA")
            try {
                signature.initSign(key)
            } catch (e: android.security.keystore.KeyPermanentlyInvalidatedException) {
                // Biometrics changed: the key can never sign again. Remove it so
                // this phone shows "Enroll" and can get a fresh key and code.
                keyStore().deleteEntry(ALIAS)
                setDeviceId(activity, "", null)
                cont.resumeWithException(IllegalStateException("Your fingerprints or face changed, so this phone's approval key was reset. Enroll it again with a new code."))
                return@suspendCancellableCoroutine
            } catch (e: Exception) {
                cont.resumeWithException(IllegalStateException("Approval key is not usable: ${e.message}"))
                return@suspendCancellableCoroutine
            }
            val prompt = BiometricPrompt(
                activity,
                ContextCompat.getMainExecutor(activity),
                object : BiometricPrompt.AuthenticationCallback() {
                    override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                        try {
                            val s = result.cryptoObject?.signature ?: error("No signature object")
                            s.update(payload.toByteArray(Charsets.UTF_8))
                            cont.resume(Base64.encodeToString(s.sign(), Base64.NO_WRAP))
                        } catch (e: Exception) {
                            cont.resumeWithException(e)
                        }
                    }

                    override fun onAuthenticationError(code: Int, message: CharSequence) {
                        if (code == BiometricPrompt.ERROR_USER_CANCELED || code == BiometricPrompt.ERROR_NEGATIVE_BUTTON ||
                            code == BiometricPrompt.ERROR_CANCELED
                        ) {
                            cont.resumeWithException(Cancelled())
                        } else {
                            cont.resumeWithException(IllegalStateException(message.toString()))
                        }
                    }
                }
            )
            val info = BiometricPrompt.PromptInfo.Builder()
                .setTitle("Approve")
                // Core writes the summary into the signed payload: show that, not caller text.
                .setSubtitle(payload.lines().lastOrNull()?.take(120) ?: summary.take(120))
                .setNegativeButtonText("Cancel")
                .setAllowedAuthenticators(androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_STRONG)
                .build()
            prompt.authenticate(info, BiometricPrompt.CryptoObject(signature))
        }

    /**
     * Send a request Core protects with a device signature. Without an enrolled
     * key the request goes unsigned (accepted only while Core is in warn mode).
     */
    suspend fun signedRequest(
        core: OrbCore,
        activity: FragmentActivity?,
        method: String,
        path: String,
        body: Map<String, Any?>?,
        summary: String,
        /** Usage telemetry for this decision: wait and method are measured here, never the payload. */
        telemetry: UsageTelemetry.Approval? = null
    ): Any? {
        val text = body?.let { OrbJSON.stringify(it) } ?: ""
        fun record(decision: UsageTelemetry.Decision, method: UsageTelemetry.Method, waitMs: Long) {
            telemetry?.let { UsageTelemetry.trackApproval(it.kind, decision, method, waitMs, it.toolName, it.commandClass) }
        }
        val context = activity ?: return core.request(path, method, rawBody = body?.let { text })
            .also { record(telemetry?.decision ?: UsageTelemetry.Decision.Approved, UsageTelemetry.Method.None, 0) }
        val device = deviceId(context, core.baseURLFlow.value)
        val headers = mutableMapOf<String, String>()
        if (device == null || publicKey() == null) {
            record(telemetry?.decision ?: UsageTelemetry.Decision.Approved, UsageTelemetry.Method.None, 0)
        } else {
            val challenge = dictOf(
                core.request(
                    "/api/approvals/challenge",
                    "POST",
                    body = mapOf("method" to method, "path" to path, "body" to text, "summary" to summary)
                )
            )
            val id = OrbJSON.str(challenge, "challenge_id") ?: error("No challenge")
            val payload = OrbJSON.str(challenge, "payload") ?: error("No challenge payload")
            // Wait = biometric prompt shown -> decision. Strong biometric only, so face and
            // fingerprint cannot be told apart: reported as touch_id (see UsageTelemetry).
            val shown = System.currentTimeMillis()
            val signed = try {
                sign(context, payload, summary)
            } catch (e: Cancelled) {
                record(UsageTelemetry.Decision.Dismissed, UsageTelemetry.Method.TouchId, System.currentTimeMillis() - shown)
                throw e
            }
            record(telemetry?.decision ?: UsageTelemetry.Decision.Approved, UsageTelemetry.Method.TouchId, System.currentTimeMillis() - shown)
            headers["X-Paloma-Approval"] = "$id.$device.$signed"
        }
        return core.request(path, method, headers = headers, rawBody = body?.let { text })
    }
}

internal fun Context.fragmentActivity(): FragmentActivity? {
    var c: Context? = this
    while (c is ContextWrapper) {
        if (c is FragmentActivity) return c
        c = c.baseContext
    }
    return null
}

private const val GRANTS_PREFS = "orb_secret_grants"
private const val GRANTS_EXPANDED_KEY = "expanded"

internal fun grantMinutesLeft(expiresAt: String?): Long? =
    runCatching { java.time.Duration.between(java.time.Instant.now(), java.time.OffsetDateTime.parse(expiresAt).toInstant()).toMinutes().coerceAtLeast(0) }.getOrNull()

internal fun formatMinutes(m: Long): String = if (m >= 60) "${m / 60} h ${m % 60} min" else "$m min"

@Composable
fun OrbSecretsSettingsPage(core: OrbCore, onBack: () -> Unit) {
    val scope = rememberCoroutineScope()
    val activity = LocalContext.current.fragmentActivity()
    val baseURL = core.baseURLFlow.collectAsState().value
    var requests by remember { mutableStateOf<List<Map<String, Any?>>>(emptyList()) }
    var grants by remember { mutableStateOf<List<Map<String, Any?>>>(emptyList()) }
    val context = LocalContext.current
    val grantPrefs = remember { context.getSharedPreferences(GRANTS_PREFS, Context.MODE_PRIVATE) }
    var showGrants by remember { mutableStateOf(grantPrefs.getBoolean(GRANTS_EXPANDED_KEY, false)) }
    var access by remember { mutableStateOf<List<Map<String, Any?>>>(emptyList()) }
    var privilege by remember { mutableStateOf<List<Map<String, Any?>>>(emptyList()) }
    var privilegeCommands by remember { mutableStateOf<List<Map<String, Any?>>>(emptyList()) }
    var bunkerIncidents by remember { mutableStateOf<List<Map<String, Any?>>>(emptyList()) }
    var bunkerState by remember { mutableStateOf(0) }
    var meshEpoch by remember { mutableStateOf<Int?>(null) }
    var meshVerified by remember { mutableStateOf(false) }
    var queue by remember { mutableStateOf<List<Map<String, Any?>>>(emptyList()) }
    var devices by remember { mutableStateOf<List<Map<String, Any?>>>(emptyList()) }
    var mode by remember { mutableStateOf("") }
    var projects by remember { mutableStateOf<Map<String, String>>(emptyMap()) }
    var enrolledHere by remember { mutableStateOf(false) }
    var code by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    suspend fun load() {
        // Mission access requests do not depend on Bitwarden being configured.
        try {
            access = OrbJSON.dictList(dictOf(core.request("/api/mission-access"))["requests"])
        } catch (_: Throwable) {
        }
        try {
            val privSnap = dictOf(core.request("/api/privilege-access"))
            privilege = OrbJSON.dictList(privSnap["requests"])
            privilegeCommands = OrbJSON.dictList(privSnap["command_audit"])
            bunkerIncidents = OrbJSON.dictList(privSnap["bunker_incidents"])
            val snapBunker = (privSnap["bunker_state"] as? Number)?.toInt() ?: 0
            val meshSnap = runCatching { dictOf(core.request("/api/mesh/status")) }.getOrNull()
            if (meshSnap != null) {
                val mBunker = (meshSnap["bunker_state"] as? Number)?.toInt() ?: 0
                bunkerState = maxOf(snapBunker, mBunker)
                meshEpoch = (meshSnap["epoch"] as? Number)?.toInt()
                meshVerified = meshSnap["formal_verified"] == true
            } else {
                bunkerState = snapBunker
            }
        } catch (_: Throwable) {
        }
        // A Core that predates /api/approvals answers 404: the per-kind lists
        // (loaded here anyway) then build the same items. Any other failure
        // keeps what is on screen.
        var queueMissing = false
        try {
            val next = OrbJSON.dictList(dictOf(core.request("/api/approvals/queue"))["items"])
            queue = next
        } catch (e: OrbError) {
            queueMissing = e.status == 404 || e.status == 405
        } catch (_: Throwable) {
        }
        if (queueMissing) {
            val secrets = runCatching { OrbJSON.dictList(dictOf(core.request("/api/bitwarden/broker"))["requests"]) }.getOrDefault(emptyList())
            val next = OrbApprovalQueue.legacyItems(privilege, secrets, access)
            queue = next
        }
        try {
            val d = dictOf(core.request("/api/approvals/devices"))
            devices = OrbJSON.dictList(d["devices"])
            mode = OrbJSON.str(d, "mode") ?: ""
            val mine = OrbApprovalKey.publicKey()
            val match = devices.firstOrNull { mine != null && it["public_key"] == mine }
            activity?.let { OrbApprovalKey.setDeviceId(it, baseURL, match?.get("id") as? String) }
            enrolledHere = match != null
            error = null
        } catch (e: Throwable) {
            error = e.message
        }
        try {
            val broker = dictOf(core.request("/api/bitwarden/broker"))
            requests = OrbJSON.dictList(broker["requests"]).filter { it["status"] == "pending" }
            grants = OrbJSON.dictList(broker["grants"])
            if (projects.isEmpty()) {
                projects = (core.request("/api/bitwarden/projects") as? List<*>).orEmpty()
                    .mapNotNull { it as? Map<*, *> }
                    .associate { (it["id"] as? String ?: "") to (it["name"] as? String ?: "") }
            }
        } catch (_: Throwable) {
        }
    }

    LaunchedEffect(Unit) {
        while (true) {
            load()
            delay(10_000)
        }
    }

    /** One signed approve-all, or, on a Core without the queue, each request through its kind's own route. */
    suspend fun approveQueue(items: List<Map<String, Any?>>) {
        if (items.any { it["legacy"] == true }) {
            for (i in items) {
                val (path, body) = OrbApprovalQueue.legacyApprove(i) { core.encodeComponent(it) }
                OrbApprovalKey.signedRequest(core, activity, "POST", path, body, OrbApprovalQueue.signingReason(listOf(i)))
            }
        } else {
            OrbApprovalKey.signedRequest(
                core, activity, "POST", "/api/approvals/approve-all",
                OrbApprovalQueue.batchBody(items), OrbApprovalQueue.signingReason(items)
            )
        }
    }

    fun act(block: suspend () -> Unit) {
        if (busy) return
        busy = true
        scope.launch {
            try {
                block()
                load()
            } catch (e: OrbApprovalKey.Cancelled) {
                // user dismissed the prompt
            } catch (e: Throwable) {
                error = e.message
            } finally {
                busy = false
            }
        }
    }

    fun describe(r: Map<String, Any?>): String {
        val key = r["key"] as? String
        val project = projects[r["project_id"] as? String] ?: (r["project_id"] as? String)?.take(8) ?: ""
        return when {
            r["kind"] == "write" -> "Store $key in $project"
            r["kind"] == "delete" -> "Delete $key from $project"
            r["kind"] == "move" -> {
                val target = projects[r["target_project_id"] as? String]
                    ?: (r["target_project_id"] as? String)?.take(8) ?: ""
                "Move $key from $project to $target"
            }
            key != null -> "Read $key ($project)"
            r["all_projects"] == true -> "Read every project"
            else -> "Read project $project"
        }
    }

    var showActivity by remember { mutableStateOf(false) }
    var showEnrollDialog by remember { mutableStateOf(false) }
    var selectedCommand by remember { mutableStateOf<OrbActivityCompaction.CoalescedCommand?>(null) }

    val livePrivilege = remember(privilege) { privilege.filter { OrbPrivilegeAccess.isLive(it) } }
    val liveAccess = remember(access) {
        val active = access.filter {
            it["state"] == "approved" && runCatching {
                java.time.Instant.parse(it["expires_at"] as String).isAfter(java.time.Instant.now())
            }.getOrDefault(false)
        }
        OrbActivityCompaction.dedupeMissionGrants(active)
    }
    val totalGrants = livePrivilege.size + liveAccess.size + grants.size
    val coalescedCommands = remember(privilegeCommands) {
        OrbActivityCompaction.coalescePrivilegeCommands(privilegeCommands)
    }
    val historyAccess = remember(access) {
        access.filter { it["state"] != "pending" && it["state"] != "approved" }.take(20)
    }
    val activityCount = bunkerIncidents.size + coalescedCommands.size + historyAccess.size

    fun missionName(title: Any?, id: Any?) =
        (title as? String)?.takeIf { it.isNotBlank() } ?: "Mission ${(id as? String)?.take(8) ?: ""}"

    Column(modifier = Modifier.fillMaxSize().background(OrbStyle.background)) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                modifier = Modifier
                    .size(38.dp)
                    .clip(CircleShape)
                    .background(OrbStyle.surface)
                    .border(1.dp, OrbStyle.border, CircleShape)
                    .orbPressClickable { onBack() },
                contentAlignment = Alignment.Center
            ) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back", tint = Color.White, modifier = Modifier.size(17.dp))
            }
            Text(
                text = "Access",
                color = Color.White,
                fontSize = 17.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.weight(1f),
                textAlign = TextAlign.Center
            )
            Spacer(Modifier.width(38.dp))
        }
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp)
        ) {
            error?.let { Text(it, color = Color(0xFFFF6B6B), fontSize = 13.sp) }

            // 1. Fleet posture (compact 2-line card)
            Card("Fleet posture") {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text(
                            text = OrbPrivilegeAccess.bunkerLabel(bunkerState) +
                                (meshEpoch?.let { " · epoch $it${if (meshVerified) " · Lean verified" else ""}" } ?: ""),
                            color = if (bunkerState > 0) Color(0xFFFF6B6B) else Color.White,
                            fontSize = 14.sp,
                            fontWeight = FontWeight.Medium,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                        Text(
                            text = if (bunkerState > 0) "Privileged requests locked · active grants revoked"
                            else "Canary tripwires & dead-man heartbeats armed",
                            color = OrbStyle.textMuted,
                            fontSize = 12.sp,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                    if (bunkerState > 0) {
                        TextButton(enabled = !busy, onClick = {
                            act {
                                OrbApprovalKey.signedRequest(
                                    core, activity, "POST",
                                    "/api/privilege-access/unbunker",
                                    null,
                                    "exit Fleet Bunker Mode"
                                )
                            }
                        }) { Text("Exit", fontWeight = FontWeight.SemiBold) }
                    } else {
                        TextButton(enabled = !busy, onClick = {
                            act {
                                OrbApprovalKey.signedRequest(
                                    core, activity, "POST",
                                    "/api/privilege-access/bunker",
                                    OrbPrivilegeAccess.bunkerBody(),
                                    "enter Hard Bunker Lockdown across the fleet"
                                )
                            }
                        }) { Text("Lock Down", color = Color(0xFFFF6B6B), fontWeight = FontWeight.SemiBold) }
                    }
                }
            }

            // 2. Unified Pending Approvals (shown only when non-empty)
            if (queue.isNotEmpty()) {
                Card("Pending approvals (${queue.size})") {
                    val normal = queue.filter { !OrbApprovalQueue.isCritical(it) }
                    val critical = queue.filter { OrbApprovalQueue.isCritical(it) }
                    @Composable
                    fun approveButton(items: List<Map<String, Any?>>, label: String, red: Boolean) =
                        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                            TextButton(enabled = !busy && items.isNotEmpty(), onClick = { act { approveQueue(items) } }) {
                                Text(label, color = if (red) Color(0xFFFF6B6B) else OrbStyle.inboxBlue, fontWeight = FontWeight.Medium)
                            }
                        }
                    @Composable
                    fun row(i: Map<String, Any?>) = Column(Modifier.padding(vertical = 4.dp)) {
                        Text(
                            OrbApprovalQueue.title(i),
                            color = if (OrbApprovalQueue.isCritical(i)) Color(0xFFFF6B6B) else Color.White,
                            fontSize = 14.sp,
                            fontWeight = FontWeight.Medium
                        )
                        Text("asked by ${OrbApprovalQueue.requester(i)}", color = OrbStyle.textMuted, fontSize = 12.sp)
                        (i["reason"] as? String)?.takeIf { it.isNotBlank() }?.let {
                            Text("“$it”", color = OrbStyle.textMuted, fontSize = 12.sp, maxLines = 2, overflow = TextOverflow.Ellipsis)
                        }
                        OrbApprovalQueue.detail(i) { projects[it] ?: it.take(8) }.takeIf { it.isNotEmpty() }?.let {
                            Text(it, color = OrbStyle.textMuted, fontSize = 12.sp)
                        }
                        Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                            TextButton(enabled = !busy, onClick = { act { approveQueue(listOf(i)) } }) { Text("Allow") }
                            TextButton(enabled = !busy, onClick = {
                                act {
                                    OrbApprovalKey.signedRequest(
                                        core, activity, "POST", OrbApprovalQueue.denyPath(i) { core.encodeComponent(it) },
                                        null, "Decline: ${OrbApprovalQueue.title(i)}"
                                    )
                                }
                            }) { Text("Deny", color = Color(0xFFFF6B6B)) }
                        }
                    }
                    normal.forEach { row(it) }
                    if (normal.isNotEmpty() && critical.isNotEmpty()) {
                        val normals = OrbApprovalQueue.normalBatch(queue)
                        approveButton(normals, "Approve ${normals.size}", red = false)
                    }
                    critical.forEach { row(it) }
                    if (queue.size > 1) {
                        approveButton(OrbApprovalQueue.allBatch(queue), OrbApprovalQueue.approveAllLabel(queue), red = critical.isNotEmpty())
                    }
                }
            }

            // 3. Approval devices + Require phone signature toggle + Enroll modal trigger
            Card("Approval devices") {
                val enforce = mode == "enforce"
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text("Require phone signature", color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.Medium)
                        Text(
                            if (enforce) "Enforced · unsigned requests rejected"
                            else if (devices.isEmpty()) "Enroll a phone first to enforce signatures"
                            else "Warn mode · unsigned requests allowed",
                            color = OrbStyle.textMuted,
                            fontSize = 12.sp,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                    Switch(
                        checked = enforce,
                        enabled = !busy && (enforce || devices.isNotEmpty()),
                        onCheckedChange = { wantEnforce ->
                            val nextMode = if (wantEnforce) "enforce" else "warn"
                            act {
                                OrbApprovalKey.signedRequest(
                                    core, activity, "PUT",
                                    "/api/approvals/mode",
                                    mapOf("mode" to nextMode),
                                    "set approval mode to $nextMode"
                                )
                            }
                        }
                    )
                }

                if (devices.isNotEmpty()) {
                    HorizontalDivider(color = OrbStyle.border, modifier = Modifier.padding(vertical = 4.dp))
                }
                devices.forEach { d ->
                    val mine = d["public_key"] == OrbApprovalKey.publicKey()
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text("${d["name"]}${if (mine) " (this phone)" else ""}", color = Color.White, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            Text("${d["platform"]}", color = OrbStyle.textMuted, fontSize = 12.sp)
                        }
                        TextButton(enabled = !busy, onClick = {
                            act {
                                OrbApprovalKey.signedRequest(
                                    core, activity, "DELETE",
                                    "/api/approvals/devices/${core.encodeComponent(d["id"] as String)}",
                                    null, "Remove approval device ${d["name"]}"
                                )
                            }
                        }) { Text("Remove", color = Color(0xFFFF6B6B)) }
                    }
                }
                if (!enrolledHere) {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(top = 4.dp)
                            .clip(RoundedCornerShape(12.dp))
                            .background(OrbStyle.card)
                            .border(1.dp, OrbStyle.border, RoundedCornerShape(12.dp))
                            .orbPressClickable { showEnrollDialog = true }
                            .padding(horizontal = 14.dp, vertical = 11.dp),
                        contentAlignment = Alignment.Center
                    ) {
                        Text("Enroll this phone…", color = OrbStyle.inboxBlue, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                    }
                }
            }

            // 4. Unified Active Grants (shown only when > 0)
            if (totalGrants > 0) {
                val expandedGrants = if (totalGrants <= 3) true else showGrants
                Card("Active grants ($totalGrants)") {
                    if (totalGrants > 3) {
                        val expiries = (livePrivilege + liveAccess + grants).mapNotNull { grantMinutesLeft(it["expires_at"] as? String) }
                        val summary = "$totalGrants active grants" +
                            (expiries.minOrNull()?.let { " · next expires in ${formatMinutes(it)}" } ?: "")
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .orbPressClickable {
                                    showGrants = !showGrants
                                    grantPrefs.edit().putBoolean(GRANTS_EXPANDED_KEY, showGrants).apply()
                                }
                                .padding(vertical = 4.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(6.dp)
                        ) {
                            Icon(
                                imageVector = if (showGrants) Icons.Default.ExpandMore else Icons.Default.ChevronRight,
                                contentDescription = null,
                                tint = OrbStyle.textMuted,
                                modifier = Modifier.size(16.dp)
                            )
                            Text(summary, color = OrbStyle.textSecondary, fontSize = 13.sp)
                        }
                    }
                    if (expandedGrants) {
                        livePrivilege.forEach { g ->
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Column(Modifier.weight(1f)) {
                                    Text(
                                        "${OrbPrivilegeAccess.requester(g)} · ${OrbPrivilegeAccess.title(g)}",
                                        color = Color.White, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis
                                    )
                                    Text(
                                        grantMinutesLeft(g["expires_at"] as? String)?.let { "${formatMinutes(it)} left" } ?: "Session grant",
                                        color = OrbStyle.textMuted, fontSize = 12.sp
                                    )
                                }
                                TextButton(enabled = !busy, onClick = {
                                    act { core.request("/api/privilege-access/${core.encodeComponent(g["id"] as String)}", "DELETE") }
                                }) { Text("Revoke", fontSize = 12.sp) }
                            }
                        }
                        liveAccess.forEach { g ->
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Column(Modifier.weight(1f)) {
                                    Text(
                                        "${OrbApprovalQueue.actorLabel(g)} → ${missionName(g["target_title"], g["target_mission_id"])}",
                                        color = Color.White, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis
                                    )
                                    val accessScope = if ((g["scope"] as? String) == "control") "Control" else "Read only"
                                    Text(
                                        "$accessScope · " + (grantMinutesLeft(g["expires_at"] as? String)?.let { "${formatMinutes(it)} left" } ?: ""),
                                        color = OrbStyle.textMuted, fontSize = 12.sp
                                    )
                                }
                                TextButton(enabled = !busy, onClick = {
                                    act { core.request("/api/mission-access/${core.encodeComponent(g["id"] as String)}", "DELETE") }
                                }) { Text("Revoke", fontSize = 12.sp) }
                            }
                        }
                        grants.groupBy { OrbApprovalQueue.subjectKey(it) }.values.forEach { group ->
                            group.forEach { g ->
                                val scopeMap = dictOf(g["scope"])
                                val label = when (scopeMap["kind"]) {
                                    "all" -> "All secrets"
                                    "project" -> "Project ${projects[scopeMap["project_id"] as? String] ?: ""}"
                                    else -> "Secret ${scopeMap["key"]}"
                                }
                                val mTitle = OrbApprovalQueue.actorLabel(g)
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Column(Modifier.weight(1f)) {
                                        Text("$mTitle · $label", color = Color.White, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                        Text(grantMinutesLeft(g["expires_at"] as? String)?.let { "${formatMinutes(it)} left" } ?: "", color = OrbStyle.textMuted, fontSize = 12.sp)
                                    }
                                    TextButton(enabled = !busy, onClick = {
                                        act { core.request("/api/bitwarden/grants/${core.encodeComponent(g["id"] as String)}", "DELETE") }
                                    }) { Text("Revoke", fontSize = 12.sp) }
                                }
                            }
                        }
                    }
                }
            }

            // 5. Collapsed-by-default Activity log (coalesced, 1-line rows, tap-to-inspect)
            if (activityCount > 0) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(16.dp))
                        .background(OrbStyle.surface)
                        .border(1.dp, OrbStyle.border, RoundedCornerShape(16.dp))
                        .padding(horizontal = 14.dp, vertical = 12.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .testTag("activity.toggle")
                            .orbPressClickable { showActivity = !showActivity },
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        Icon(
                            imageVector = if (showActivity) Icons.Default.ExpandMore else Icons.Default.ChevronRight,
                            contentDescription = null,
                            tint = OrbStyle.textMuted,
                            modifier = Modifier.size(16.dp)
                        )
                        Text(
                            text = if (showActivity) "Hide activity ($activityCount)" else "Show activity ($activityCount)",
                            color = Color.White,
                            fontSize = 14.sp,
                            fontWeight = FontWeight.Medium,
                            modifier = Modifier.weight(1f)
                        )
                    }
                    if (showActivity) {
                        bunkerIncidents.take(10).forEach { inc ->
                            val dry = inc["dry_run"] == true
                            val nextState = (inc["new_bunker_state"] as? Number)?.toInt() ?: 0
                            val peer = (inc["peer_name"] as? String)?.takeIf { it.isNotBlank() }?.let { "$it · " } ?: ""
                            val epoch = (inc["epoch"] as? Number)?.toInt() ?: 0
                            Text(
                                "${if (dry) "CANARY TEST" else OrbPrivilegeAccess.bunkerLabel(nextState).uppercase()}: $peer${inc["reason"]} (epoch $epoch)",
                                color = if (!dry && nextState > 0) Color(0xFFFF6B6B) else OrbStyle.textMuted,
                                fontSize = 11.sp,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                        }
                        coalescedCommands.take(25).forEach { cmd ->
                            val statusColor = when {
                                cmd.exitCode != null && cmd.exitCode != 0 -> Color(0xFFFF6B6B)
                                cmd.exitCode == 0 -> OrbStyle.success
                                else -> OrbStyle.warning
                            }
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clip(RoundedCornerShape(8.dp))
                                    .background(OrbStyle.card)
                                    .orbPressClickable { selectedCommand = cmd }
                                    .padding(horizontal = 10.dp, vertical = 7.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(8.dp)
                            ) {
                                Text(
                                    text = cmd.status,
                                    color = statusColor,
                                    fontSize = 10.5.sp,
                                    fontWeight = FontWeight.Bold,
                                    fontFamily = FontFamily.Monospace,
                                    maxLines = 1
                                )
                                if (cmd.host.isNotEmpty()) {
                                    Text(
                                        text = OrbPrivilegeAccess.host(cmd.host),
                                        color = OrbStyle.textMuted,
                                        fontSize = 11.sp,
                                        maxLines = 1
                                    )
                                }
                                Text(
                                    text = cmd.command,
                                    color = OrbStyle.textSecondary,
                                    fontSize = 11.sp,
                                    fontFamily = FontFamily.Monospace,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                    modifier = Modifier.weight(1f)
                                )
                            }
                        }
                        historyAccess.forEach { h ->
                            val stateUpper = ((h["state"] as? String) ?: "").uppercase()
                            Text(
                                text = "$stateUpper · ${OrbApprovalQueue.actorLabel(h)} → ${missionName(h["target_title"], h["target_mission_id"])}",
                                color = OrbStyle.textMuted,
                                fontSize = 11.sp,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                        }
                    }
                }
            }
            Spacer(Modifier.size(16.dp))
        }
    }

    if (showEnrollDialog) {
        AlertDialog(
            onDismissRequest = { if (!busy) showEnrollDialog = false },
            containerColor = OrbStyle.elevated,
            title = { Text("Enroll this phone", color = Color.White, fontSize = 17.sp, fontWeight = FontWeight.SemiBold) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text(
                        "1. Run this command on the Core host to generate a one-time enrollment code:",
                        color = OrbStyle.textSecondary,
                        fontSize = 12.sp
                    )
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(10.dp))
                            .background(OrbStyle.card)
                            .border(1.dp, OrbStyle.border, RoundedCornerShape(10.dp))
                            .padding(10.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        androidx.compose.foundation.text.selection.SelectionContainer(modifier = Modifier.weight(1f)) {
                            Text(
                                OrbPrivilegeAccess.ENROLLMENT_CODE_COMMAND,
                                color = Color.White,
                                fontSize = 11.sp,
                                fontFamily = FontFamily.Monospace
                            )
                        }
                        TextButton(onClick = {
                            val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
                            cm?.setPrimaryClip(ClipData.newPlainText("Enroll command", OrbPrivilegeAccess.ENROLLMENT_CODE_COMMAND))
                            Toast.makeText(context, "Command copied", Toast.LENGTH_SHORT).show()
                        }) { Text("Copy") }
                    }
                    Text(
                        "2. Enter the code below. Your Keystore key will sign approvals after a biometric check.",
                        color = OrbStyle.textSecondary,
                        fontSize = 12.sp
                    )
                    OutlinedTextField(
                        value = code,
                        onValueChange = { code = it },
                        singleLine = true,
                        label = { Text("One-time code") },
                        modifier = Modifier.fillMaxWidth()
                    )
                }
            },
            confirmButton = {
                TextButton(
                    enabled = !busy && code.trim().length >= 8,
                    onClick = {
                        act {
                            val pub = OrbApprovalKey.publicKey() ?: OrbApprovalKey.create()
                            val device = dictOf(
                                core.request(
                                    "/api/approvals/devices", "POST",
                                    body = mapOf(
                                        "name" to "Orb on ${Build.MODEL}",
                                        "platform" to "android",
                                        "public_key" to pub,
                                        "enrollment_code" to code.trim()
                                    )
                                )
                            )
                            activity?.let { OrbApprovalKey.setDeviceId(it, baseURL, device["id"] as? String) }
                            code = ""
                            showEnrollDialog = false
                        }
                    }
                ) { Text("Enroll") }
            },
            dismissButton = {
                TextButton(enabled = !busy, onClick = { showEnrollDialog = false }) { Text("Cancel") }
            }
        )
    }

    selectedCommand?.let { cmd ->
        val fullDetail = buildString {
            append(cmd.status)
            if (cmd.host.isNotEmpty()) append(" · ").append(cmd.host)
            if (cmd.timestamp.isNotEmpty()) append("\nAt: ").append(cmd.timestamp)
            if (cmd.missionId.isNotEmpty()) append("\nMission: ").append(cmd.missionId)
            append("\n\n").append(cmd.command)
            if (cmd.detail.isNotBlank()) append("\n\n").append(cmd.detail)
        }
        AlertDialog(
            onDismissRequest = { selectedCommand = null },
            containerColor = OrbStyle.elevated,
            title = { Text("Command audit", color = Color.White, fontSize = 16.sp, fontWeight = FontWeight.SemiBold) },
            text = {
                androidx.compose.foundation.text.selection.SelectionContainer {
                    Text(fullDetail, color = OrbStyle.textSecondary, fontSize = 12.sp, fontFamily = FontFamily.Monospace)
                }
            },
            confirmButton = {
                TextButton(onClick = {
                    val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
                    cm?.setPrimaryClip(ClipData.newPlainText("Command audit", fullDetail))
                    Toast.makeText(context, "Copied", Toast.LENGTH_SHORT).show()
                    selectedCommand = null
                }) { Text("Copy") }
            },
            dismissButton = {
                TextButton(onClick = { selectedCommand = null }) { Text("Close") }
            }
        )
    }
}

@Composable
private fun Card(title: String, content: @Composable () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(OrbStyle.surface)
            .border(1.dp, OrbStyle.border, RoundedCornerShape(16.dp))
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp)
    ) {
        Text(title, color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
        content()
    }
}

private fun dictOf(value: Any?): Map<String, Any?> = OrbJSON.dict(value) ?: emptyMap()
