package sh.sandboxed.dashboard.orb

import android.content.Context
import android.content.SharedPreferences
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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * Optional trust window for FIDO / SSH signing approvals. Off by default: every request needs
 * a biometric. When set to N minutes, a biometric approval trusts that exact key on that exact
 * host (or origin) for N minutes; matching requests in that window are approved without a new
 * prompt. The window starts at the biometric approval and is never extended by auto-approvals.
 * Trust lives in memory only, so it ends when the app process ends, on sign-out, or when the
 * setting changes.
 */
class OrbFidoTrust(private val clock: () -> Long = System::currentTimeMillis) {
    var minutes: Int = 0
        set(value) {
            field = value.coerceAtLeast(0)
            trusted.clear()
        }
    private val trusted = mutableMapOf<String, Long>()

    private fun scope(req: OrbFidoRequest): String? {
        if (req.keyFingerprint.isBlank()) return null
        val host = req.hostname?.takeIf { it.isNotBlank() } ?: req.origin.takeIf { it.isNotBlank() } ?: return null
        return req.keyFingerprint + "|" + host.lowercase()
    }

    /** Call after a successful biometric approval. */
    fun recordBiometricApproval(req: OrbFidoRequest) {
        if (minutes <= 0) return
        val key = scope(req) ?: return
        trusted[key] = clock() + minutes * 60_000L
    }

    fun isTrusted(req: OrbFidoRequest): Boolean {
        if (minutes <= 0) return false
        val key = scope(req) ?: return false
        val until = trusted[key] ?: return false
        if (clock() >= until) { trusted.remove(key); return false }
        return true
    }

    fun clear() = trusted.clear()

    companion object {
        val OPTIONS = listOf(0, 5, 15, 30)
        fun label(minutes: Int) = if (minutes <= 0) "Off (always ask)" else "$minutes minutes"
    }
}

/** App-wide trust window, persisted setting. */
object OrbFidoSettings {
    private const val PREFS = "orb.fido"
    private const val KEY = "orb.fido.trustMinutes"
    private var prefs: SharedPreferences? = null
    val trust = OrbFidoTrust()

    fun init(context: Context) {
        if (prefs != null) return
        val p = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        prefs = p
        trust.minutes = p.getInt(KEY, 0).takeIf { it in OrbFidoTrust.OPTIONS } ?: 0
    }

    fun update(minutes: Int) {
        trust.minutes = minutes
        prefs?.edit()?.putInt(KEY, trust.minutes)?.apply()
    }
}

@Composable
fun OrbFidoSettingsPage(onBack: () -> Unit) {
    val context = LocalContext.current
    remember(context) { OrbFidoSettings.init(context); true }
    var current by remember { mutableIntStateOf(OrbFidoSettings.trust.minutes) }
    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(OrbStyle.background)
            .padding(horizontal = 20.dp, vertical = 16.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp)
    ) {
        Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
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
                text = "SSH signing",
                color = Color.White,
                fontSize = 17.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.weight(1f),
                textAlign = androidx.compose.ui.text.style.TextAlign.Center
            )
            Spacer(modifier = Modifier.width(38.dp))
        }
        Text(
            "Every signing request asks for a biometric by default. A trust window lets the same key on the same host sign again without a prompt for the chosen time after a biometric approval. Trust ends when Orb closes or you sign out.",
            color = OrbStyle.textMuted,
            fontSize = 12.sp
        )
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(16.dp))
                .background(OrbStyle.surface)
                .border(1.dp, OrbStyle.border, RoundedCornerShape(16.dp))
        ) {
            OrbFidoTrust.OPTIONS.forEach { minutes ->
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .orbPressClickable { OrbFidoSettings.update(minutes); current = minutes }
                        .padding(horizontal = 16.dp, vertical = 13.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(OrbFidoTrust.label(minutes), color = Color.White, fontSize = 15.sp, modifier = Modifier.weight(1f))
                    if (current == minutes) Icon(Icons.Default.Check, contentDescription = "Selected", tint = Color.White, modifier = Modifier.size(16.dp))
                }
            }
        }
    }
}
