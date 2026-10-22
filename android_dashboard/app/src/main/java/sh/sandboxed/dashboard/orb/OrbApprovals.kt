package sh.sandboxed.dashboard.orb

import android.content.Context
import android.content.ContextWrapper
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.security.keystore.StrongBoxUnavailableException
import android.util.Base64
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
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
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
import androidx.compose.ui.text.font.FontWeight
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
        summary: String
    ): Any? {
        val text = body?.let { OrbJSON.stringify(it) } ?: ""
        val context = activity ?: return core.request(path, method, rawBody = body?.let { text })
        val device = deviceId(context, core.baseURLFlow.value)
        val headers = mutableMapOf<String, String>()
        if (device != null && publicKey() != null) {
            val challenge = dictOf(
                core.request(
                    "/api/approvals/challenge",
                    "POST",
                    body = mapOf("method" to method, "path" to path, "body" to text, "summary" to summary)
                )
            )
            val id = OrbJSON.str(challenge, "challenge_id") ?: error("No challenge")
            val payload = OrbJSON.str(challenge, "payload") ?: error("No challenge payload")
            headers["X-Paloma-Approval"] = "$id.$device.${sign(context, payload, summary)}"
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

@Composable
fun OrbSecretsSettingsPage(core: OrbCore, onBack: () -> Unit) {
    val scope = rememberCoroutineScope()
    val activity = LocalContext.current.fragmentActivity()
    val baseURL = core.baseURLFlow.collectAsState().value
    var requests by remember { mutableStateOf<List<Map<String, Any?>>>(emptyList()) }
    var grants by remember { mutableStateOf<List<Map<String, Any?>>>(emptyList()) }
    var access by remember { mutableStateOf<List<Map<String, Any?>>>(emptyList()) }
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
            val broker = dictOf(core.request("/api/bitwarden/broker"))
            requests = OrbJSON.dictList(broker["requests"]).filter { it["status"] == "pending" }
            grants = OrbJSON.dictList(broker["grants"])
            val d = dictOf(core.request("/api/approvals/devices"))
            devices = OrbJSON.dictList(d["devices"])
            mode = OrbJSON.str(d, "mode") ?: ""
            val mine = OrbApprovalKey.publicKey()
            val match = devices.firstOrNull { mine != null && it["public_key"] == mine }
            activity?.let { OrbApprovalKey.setDeviceId(it, baseURL, match?.get("id") as? String) }
            enrolledHere = match != null
            if (projects.isEmpty()) {
                projects = (core.request("/api/bitwarden/projects") as? List<*>).orEmpty()
                    .mapNotNull { it as? Map<*, *> }
                    .associate { (it["id"] as? String ?: "") to (it["name"] as? String ?: "") }
            }
            error = null
        } catch (e: Throwable) {
            error = e.message
        }
    }

    LaunchedEffect(Unit) {
        while (true) {
            load()
            delay(10_000)
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

    Column(modifier = Modifier.fillMaxSize().background(OrbStyle.background)) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                modifier = Modifier.size(38.dp).clip(CircleShape).orbPressClickable { onBack() },
                contentAlignment = Alignment.Center
            ) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back", tint = Color.White) }
            Spacer(Modifier.width(8.dp))
            Text("Secrets", color = Color.White, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
        }
        Column(
            modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp)
        ) {
            error?.let { Text(it, color = Color(0xFFFF6B6B), fontSize = 13.sp) }

            Card("Mission requests") {
                if (requests.isEmpty()) Text("No pending requests.", color = OrbStyle.textMuted, fontSize = 13.sp)
                requests.forEach { r ->
                    val id = r["id"] as String
                    val who = listOfNotNull(r["mission_title"] as? String, r["paloma_project"] as? String).joinToString(" · ")
                    Column(Modifier.padding(vertical = 6.dp)) {
                        Text(describe(r), color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.Medium)
                        Text(who, color = OrbStyle.textMuted, fontSize = 12.sp)
                        (r["reason"] as? String)?.takeIf { it.isNotBlank() }?.let {
                            Text("“$it”", color = OrbStyle.textMuted, fontSize = 12.sp)
                        }
                        Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                            @Composable
                            fun approve(scopeName: String?, label: String) = TextButton(enabled = !busy, onClick = {
                                act {
                                    OrbApprovalKey.signedRequest(
                                        core, activity, "POST",
                                        "/api/bitwarden/requests/${core.encodeComponent(id)}/approve",
                                        if (scopeName == null) emptyMap() else mapOf("scope" to scopeName),
                                        "$label: ${describe(r)} for $who"
                                    )
                                }
                            }) { Text(label) }
                            if (r["kind"] != "read") {
                                approve(null, "Approve")
                            } else {
                                if (r["key"] != null) approve("secret", "Secret")
                                if (r["project_id"] != null) approve("project", "Project")
                                approve("all", "All")
                            }
                            TextButton(enabled = !busy, onClick = {
                                act {
                                    OrbApprovalKey.signedRequest(
                                        core, activity, "POST",
                                        "/api/bitwarden/requests/${core.encodeComponent(id)}/reject",
                                        null, "Decline: ${describe(r)}"
                                    )
                                }
                            }) { Text("Decline", color = Color(0xFFFF6B6B)) }
                        }
                    }
                }
            }

            Card("Mission access") {
                fun mission(title: Any?, id: Any?) =
                    (title as? String)?.takeIf { it.isNotBlank() } ?: "Mission ${(id as? String)?.take(8) ?: ""}"
                val pendingAccess = access.filter { it["state"] == "pending" }
                val liveAccess = access.filter {
                    it["state"] == "approved" && runCatching {
                        java.time.Instant.parse(it["expires_at"] as String).isAfter(java.time.Instant.now())
                    }.getOrDefault(false)
                }
                Text(
                    "Read-only grants between missions (events, messages, shared files). Never allows messages, cancel or resume. Approving needs your fingerprint or face.",
                    color = OrbStyle.textMuted, fontSize = 12.sp
                )
                if (pendingAccess.isEmpty() && liveAccess.isEmpty()) Text("No requests or grants.", color = OrbStyle.textMuted, fontSize = 13.sp)
                pendingAccess.forEach { r ->
                    val id = r["id"] as String
                    val who = mission(r["requester_title"], r["requester_mission_id"])
                    val target = mission(r["target_title"], r["target_mission_id"])
                    val hours = (r["ttl_hours"] as? Number)?.toInt() ?: 24
                    Column(Modifier.padding(vertical = 6.dp)) {
                        Text("Read $target", color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.Medium)
                        Text("asked by $who · $hours h", color = OrbStyle.textMuted, fontSize = 12.sp)
                        (r["reason"] as? String)?.takeIf { it.isNotBlank() }?.let {
                            Text("“$it”", color = OrbStyle.textMuted, fontSize = 12.sp)
                        }
                        Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                            TextButton(enabled = !busy, onClick = {
                                act {
                                    OrbApprovalKey.signedRequest(
                                        core, activity, "POST",
                                        "/api/mission-access/${core.encodeComponent(id)}/approve",
                                        mapOf("ttl_hours" to hours),
                                        "Let $who read $target for $hours h"
                                    )
                                }
                            }) { Text("Allow read") }
                            TextButton(enabled = !busy, onClick = {
                                act {
                                    OrbApprovalKey.signedRequest(
                                        core, activity, "POST",
                                        "/api/mission-access/${core.encodeComponent(id)}/deny",
                                        null, "Decline: $who wants to read $target"
                                    )
                                }
                            }) { Text("Deny", color = Color(0xFFFF6B6B)) }
                        }
                    }
                }
                liveAccess.forEach { g ->
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text(
                                "${mission(g["requester_title"], g["requester_mission_id"])} → ${mission(g["target_title"], g["target_mission_id"])}",
                                color = Color.White, fontSize = 14.sp
                            )
                            Text("Read only · until ${g["expires_at"]}", color = OrbStyle.textMuted, fontSize = 12.sp)
                        }
                        TextButton(enabled = !busy, onClick = {
                            act { core.request("/api/mission-access/${core.encodeComponent(g["id"] as String)}", "DELETE") }
                        }) { Text("Revoke") }
                    }
                }
            }

            if (grants.isNotEmpty()) {
                Card("Active grants") {
                    grants.forEach { g ->
                        val scopeMap = dictOf(g["scope"])
                        val label = when (scopeMap["kind"]) {
                            "all" -> "All projects"
                            "project" -> "Project ${projects[scopeMap["project_id"] as? String] ?: ""}"
                            else -> "Secret ${scopeMap["key"]}"
                        }
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Column(Modifier.weight(1f)) {
                                Text(label, color = Color.White, fontSize = 14.sp)
                                Text((g["mission_title"] as? String) ?: "", color = OrbStyle.textMuted, fontSize = 12.sp)
                            }
                            TextButton(enabled = !busy, onClick = {
                                act { core.request("/api/bitwarden/grants/${core.encodeComponent(g["id"] as String)}", "DELETE") }
                            }) { Text("Revoke") }
                        }
                    }
                }
            }

            Card("Approval devices · $mode") {
                devices.forEach { d ->
                    val mine = d["public_key"] == OrbApprovalKey.publicKey()
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text("${d["name"]}${if (mine) " (this phone)" else ""}", color = Color.White, fontSize = 14.sp)
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
                    Text(
                        "Enroll this phone: its Keystore key signs approvals after a fingerprint or face check. " +
                            "Enter the one-time code created on the Core host.",
                        color = OrbStyle.textMuted, fontSize = 12.sp
                    )
                    OutlinedTextField(value = code, onValueChange = { code = it }, singleLine = true,
                        label = { Text("One-time code") }, modifier = Modifier.fillMaxWidth())
                    TextButton(enabled = !busy && code.trim().length >= 8, onClick = {
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
                        }
                    }) { Text("Enroll this phone") }
                }
            }
        }
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
