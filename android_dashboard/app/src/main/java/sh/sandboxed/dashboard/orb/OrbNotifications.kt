package sh.sandboxed.dashboard.orb

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import sh.sandboxed.dashboard.MainActivity
import sh.sandboxed.dashboard.R

data class OrbInboxFocusTarget(
    val missionId: String,
    val expandPeek: Boolean = true,
    val openReply: Boolean = false
)

object OrbNotifications {
    private const val PREFS_KEY = "orb.notifications.v1"
    private const val KEY_ENABLED = "enabled"
    private const val KEY_SEEDED_ACCOUNTS = "seeded_accounts"
    private const val KEY_SIGNATURES_PREFIX = "sig:"

    const val CHANNEL_NEEDS_YOU = "orb_inbox_needs_you"
    const val CHANNEL_READY = "orb_inbox_ready"

    private var appContext: Context? = null
    private var prefs: SharedPreferences? = null
    private val deliveredSignatures = mutableMapOf<String, String>()
    private val seededAccounts = mutableSetOf<String>()

    var notificationsEnabled by mutableStateOf(true)
        private set

    var pendingInboxFocus by mutableStateOf<OrbInboxFocusTarget?>(null)
        private set

    fun init(context: Context) {
        if (appContext != null) return
        val ctx = context.applicationContext
        appContext = ctx
        val p = ctx.getSharedPreferences(PREFS_KEY, Context.MODE_PRIVATE)
        prefs = p
        notificationsEnabled = p.getBoolean(KEY_ENABLED, true)
        seededAccounts.addAll(p.getStringSet(KEY_SEEDED_ACCOUNTS, emptySet()) ?: emptySet())
        for ((k, v) in p.all) {
            if (k.startsWith(KEY_SIGNATURES_PREFIX) && v is String) {
                deliveredSignatures[k.removePrefix(KEY_SIGNATURES_PREFIX)] = v
            }
        }
        ensureChannels(ctx)
    }

    fun setEnabled(enabled: Boolean) {
        notificationsEnabled = enabled
        prefs?.edit()?.putBoolean(KEY_ENABLED, enabled)?.apply()
        if (!enabled) {
            appContext?.let { NotificationManagerCompat.from(it).cancelAll() }
        }
    }

    fun requestInboxFocus(missionId: String, expandPeek: Boolean = true, openReply: Boolean = false) {
        val clean = missionId.trim()
        if (clean.isNotEmpty()) {
            pendingInboxFocus = OrbInboxFocusTarget(clean, expandPeek, openReply)
        }
    }

    fun consumeInboxFocus(): OrbInboxFocusTarget? {
        val target = pendingInboxFocus
        pendingInboxFocus = null
        return target
    }

    private fun ensureChannels(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
        val needsYouChannel = NotificationChannel(
            CHANNEL_NEEDS_YOU,
            "Orb — Needs You (Approvals & Blockers)",
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = "Alerts when an autonomous or hybrid agent needs your decision, approval, or is blocked."
        }
        val readyChannel = NotificationChannel(
            CHANNEL_READY,
            "Orb — Ready for Review (AI Summaries)",
            NotificationManager.IMPORTANCE_DEFAULT
        ).apply {
            description = "Notifications with AI Overviews when a background mission finishes."
        }
        nm.createNotificationChannel(needsYouChannel)
        nm.createNotificationChannel(readyChannel)
    }

    data class ChannelState(val id: String, val name: String, val importance: Int, val enabled: Boolean)

    /** Permission + channel state for Settings → Debug info. */
    fun diagnostics(context: Context): Pair<Boolean, List<ChannelState>> {
        val permitted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        } else {
            NotificationManagerCompat.from(context).areNotificationsEnabled()
        }
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
        val channels = listOf(CHANNEL_NEEDS_YOU, CHANNEL_READY).map { id ->
            val ch = nm?.getNotificationChannel(id)
            ChannelState(
                id = id,
                name = ch?.name?.toString() ?: "(missing)",
                importance = ch?.importance ?: -1,
                enabled = ch != null && ch.importance != NotificationManager.IMPORTANCE_NONE
            )
        }
        return permitted to channels
    }

    private fun canPostNotifications(context: Context): Boolean {
        if (!notificationsEnabled) return false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            return ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.POST_NOTIFICATIONS
            ) == PackageManager.PERMISSION_GRANTED
        }
        return NotificationManagerCompat.from(context).areNotificationsEnabled()
    }

    private fun notificationIdFor(missionId: String): Int =
        ("orb.inbox.$missionId").hashCode()

    fun reconcile(items: List<OrbInboxItem>, workingMissions: List<OrbRow>) {
        val ctx = appContext ?: return
        val core = OrbCore.shared
        val account = inboxAccountScope(core.baseURL, core.token)
        if (account.isEmpty() || !core.isConfigured) return

        val unreadItems = items.filter { it.isUnread }
        val activeUnreadIds = unreadItems.map { it.id }.toSet()
        val nm = NotificationManagerCompat.from(ctx)

        // Cancel notifications for missions already read/archived on PC or resumed into working
        val toRemove = deliveredSignatures.keys.filter { it !in activeUnreadIds }
        if (toRemove.isNotEmpty()) {
            val editor = prefs?.edit()
            for (mid in toRemove) {
                nm.cancel(notificationIdFor(mid))
                if (workingMissions.any { it.id == mid } || items.any { it.id == mid && !it.isUnread }) {
                    deliveredSignatures.remove(mid)
                    editor?.remove("$KEY_SIGNATURES_PREFIX$mid")
                }
            }
            editor?.apply()
        }

        if (!canPostNotifications(ctx)) return

        // First sync on a fresh account seeds existing unread items silently
        if (seededAccounts.add(account)) {
            val editor = prefs?.edit()
            editor?.putStringSet(KEY_SEEDED_ACCOUNTS, seededAccounts.toSet())
            for (item in unreadItems) {
                val sig = signatureFor(item)
                deliveredSignatures[item.id] = sig
                editor?.putString("$KEY_SIGNATURES_PREFIX${item.id}", sig)
            }
            editor?.apply()
            return
        }

        for (item in unreadItems.take(8)) {
            val sig = signatureFor(item)
            val prev = deliveredSignatures[item.id]
            if (prev == sig) continue

            val status = (item.mission.str("status", "state") ?: "").lowercase()
            val silentUpdate = prev != null && prev.startsWith("$status|${item.updatedAt ?: ""}|")

            deliveredSignatures[item.id] = sig
            prefs?.edit()?.putString("$KEY_SIGNATURES_PREFIX${item.id}", sig)?.apply()
            postNotification(ctx, nm, item, silentUpdate)
        }
    }

    private fun signatureFor(item: OrbInboxItem): String {
        val status = (item.mission.str("status", "state") ?: "").lowercase()
        val callId = item.pendingInteraction?.callId ?: ""
        val digestRev = item.aiOverview?.sourceRevision ?: ""
        return "$status|${item.updatedAt ?: ""}|$callId|$digestRev"
    }

    private fun postNotification(
        context: Context,
        nm: NotificationManagerCompat,
        item: OrbInboxItem,
        silentUpdate: Boolean
    ) {
        val projectName = item.project.str("title", "name", "slug") ?: "Project"
        val projectSlug = OrbProjectAppearance.slug(item.project)
        val isUrgent = item.kind == OrbInboxKind.NeedsInput || item.isAttention
        val channelId = if (isUrgent) CHANNEL_NEEDS_YOU else CHANNEL_READY

        val iconPrefix = when {
            item.pendingInteraction?.kind == "permission" -> "⚡"
            item.pendingInteraction?.kind == "plan" -> "📋"
            item.pendingInteraction != null -> "❓"
            item.badge == "Blocked" -> "⚠️"
            item.badge == "Failed" || item.badge == "Not feasible" -> "⛔"
            item.kind == OrbInboxKind.NeedsInput -> "💬"
            else -> "✅"
        }

        val title = "$iconPrefix $projectName · ${item.headline}"
        val subtitleParts = mutableListOf(item.badge)
        if (item.aiOverview != null && item.aiOverview.outcome.isNotBlank()) {
            subtitleParts.add("AI Summary")
        }
        if (!item.workReceipt.isNullOrBlank()) {
            subtitleParts.add(item.workReceipt)
        }
        val subText = subtitleParts.joinToString(" · ")

        val bodyLines = mutableListOf<String>()
        val digest = item.aiOverview
        if (digest != null && digest.outcome.isNotBlank() && item.pendingInteraction == null) {
            bodyLines.add(digest.outcome)
            if (digest.decision.isNotBlank()) {
                bodyLines.add("To decide: ${digest.decision}")
            } else if (digest.unresolved.isNotBlank()) {
                bodyLines.add("Open: ${digest.unresolved}")
            }
        } else {
            bodyLines.add(item.summary)
            if (!item.commandPreview.isNullOrBlank()) {
                bodyLines.add("$ ${item.commandPreview}")
            }
            if (digest != null && digest.outcome.isNotBlank() && digest.outcome != item.summary) {
                bodyLines.add("AI Summary: ${digest.outcome}")
            }
        }
        val body = bodyLines.filter { it.isNotBlank() }.joinToString("\n").ifEmpty {
            "Open Inbox to review the agent response."
        }

        val deepLinkUri = Uri.parse("orb://inbox/${Uri.encode(item.id)}?peek=1")
        val openInboxIntent = Intent(context, MainActivity::class.java).apply {
            action = Intent.ACTION_VIEW
            data = deepLinkUri
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val contentPendingIntent = PendingIntent.getActivity(
            context,
            notificationIdFor(item.id),
            openInboxIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val replyUri = Uri.parse("orb://inbox/${Uri.encode(item.id)}?peek=1&reply=1")
        val replyIntent = Intent(context, MainActivity::class.java).apply {
            action = Intent.ACTION_VIEW
            data = replyUri
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val replyPendingIntent = PendingIntent.getActivity(
            context,
            notificationIdFor(item.id) + 1,
            replyIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val builder = NotificationCompat.Builder(context, channelId)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setSubText(subText)
            .setContentText(body.lineSequence().firstOrNull() ?: body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body).setSummaryText(subText))
            .setGroup("orb.project.$projectSlug")
            .setAutoCancel(true)
            .setOnlyAlertOnce(silentUpdate)
            .setSilent(silentUpdate)
            .setPriority(if (isUrgent) NotificationCompat.PRIORITY_HIGH else NotificationCompat.PRIORITY_DEFAULT)
            .setContentIntent(contentPendingIntent)
            .addAction(0, "Inspect Summary", contentPendingIntent)
            .addAction(0, "Reply", replyPendingIntent)

        orbTry(OrbLog.Category.Notify, "post notification") {
            nm.notify(notificationIdFor(item.id), builder.build())
        }
    }
}
