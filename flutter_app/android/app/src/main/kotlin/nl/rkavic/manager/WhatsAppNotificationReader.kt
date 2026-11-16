package nl.rkavic.manager

import android.app.Notification
import android.app.Person
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

private const val READER_PREFS = "whatsapp_notification_reader"
private const val MESSAGES_KEY = "messages"
private const val GROUPS_KEY = "groups"
private const val SELECTED_GROUP_KEY = "selected_group"
private const val CAPTURE_CONSENT_KEY = "capture_consent"
private const val MAX_MESSAGES = 5000
private const val RETENTION_DAYS = 30L

/** Receives only WhatsApp notifications after the user grants notification access. */
class WhatsAppNotificationReaderService : NotificationListenerService() {
    override fun onNotificationPosted(sbn: StatusBarNotification) {
        if (sbn.packageName !in WHATSAPP_PACKAGES || sbn.isOngoing) return
        val notification = sbn.notification ?: return
        val extras = notification.extras ?: return
        val title = conversationTitle(extras) ?: return
        val messages = notificationMessages(extras, sbn.postTime)

        val groupId = "${sbn.packageName}|$title"
        val prefs = getSharedPreferences(READER_PREFS, Context.MODE_PRIVATE)
        synchronized(ReaderCache.lock) {
            ReaderCache.recordGroup(prefs, groupId, title, sbn.postTime)
            if (messages.isEmpty()) return
            val selectedGroup = prefs.getString(SELECTED_GROUP_KEY, null)
            if (!prefs.getBoolean(CAPTURE_CONSENT_KEY, false) || selectedGroup != groupId) return

            // Only the currently selected group's text is retained locally.
            val all = readMessages(prefs).filter { it.optString("chat") == groupId }.toMutableList()
            val known = all.mapTo(mutableSetOf()) { it.optString("id") }
            val added = mutableListOf<JSONObject>()
            for (message in messages) {
                val text = message.first.trim()
                if (text.isEmpty()) continue
                val sender = message.second.trim().ifEmpty { "Unknown participant" }
                val time = message.third.takeIf { it > 0L } ?: sbn.postTime
                val dedupeKey = "$groupId|$time|$sender|$text"
                val id = MessageDigest.getInstance("SHA-256")
                    .digest(dedupeKey.toByteArray())
                    .joinToString("") { byte -> "%02x".format(byte) }
                if (!known.add(id)) continue
                added += JSONObject()
                    .put("id", id)
                    .put("chat", groupId)
                    .put("groupName", title)
                    .put("senderId", sender)
                    .put("sender", sender)
                    .put("timestamp", Instant.ofEpochMilli(time).toString())
                    .put("kind", "message")
                    .put("text", text)
            }
            if (added.isEmpty()) return
            all.addAll(added)
            val cutoff = System.currentTimeMillis() - RETENTION_DAYS * 24 * 60 * 60 * 1000
            val retained = all.filter { parseTime(it) >= cutoff }.takeLast(MAX_MESSAGES)
            val array = JSONArray()
            retained.forEach(array::put)
            prefs.edit().putString(MESSAGES_KEY, array.toString()).apply()

            added.forEach { ReaderEventBus.emit("reader_message", mapOf("message" to it.toMap())) }
        }
    }

    private fun conversationTitle(extras: Bundle): String? {
        val conversationTitle = extras.getCharSequence(Notification.EXTRA_CONVERSATION_TITLE)
            ?.toString()?.trim()
        val isGroup = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P &&
            extras.containsKey(Notification.EXTRA_IS_GROUP_CONVERSATION)
        ) {
            extras.getBoolean(Notification.EXTRA_IS_GROUP_CONVERSATION, false)
        } else {
            !conversationTitle.isNullOrEmpty()
        }
        if (!isGroup) return null
        val title = conversationTitle?.takeIf(String::isNotEmpty)
            ?: if (isGroup) extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()?.trim() else null
        return title?.takeIf { it.isNotEmpty() && it.lowercase() !in GENERIC_TITLES }
    }

    private fun notificationMessages(extras: Bundle, postTime: Long): List<Triple<String, String, Long>> {
        val result = mutableListOf<Triple<String, String, Long>>()
        @Suppress("DEPRECATION")
        val bundled = extras.getParcelableArray(Notification.EXTRA_MESSAGES)
        bundled?.forEach { parcelable ->
            val bundle = parcelable as? Bundle ?: return@forEach
            val text = bundle.getCharSequence("text")?.toString().orEmpty()
            val sender = bundleSender(bundle)
            val time = bundle.getLong("time", postTime)
            if (text.isNotBlank()) result += Triple(text, sender, time)
        }
        if (result.isNotEmpty()) return result

        val text = extras.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString()
            ?: extras.getCharSequence(Notification.EXTRA_TEXT)?.toString()
        if (!text.isNullOrBlank()) result += Triple(text, "", postTime)
        return result
    }

    @Suppress("DEPRECATION")
    private fun bundleSender(bundle: Bundle): String {
        bundle.getCharSequence("sender")?.toString()?.trim()?.let { if (it.isNotEmpty()) return it }
        val person = bundle.getParcelable("sender_person") as? Person
        return person?.name?.toString()?.trim().orEmpty()
    }

    companion object {
        private val WHATSAPP_PACKAGES = setOf("com.whatsapp", "com.whatsapp.w4b")
        private val GENERIC_TITLES = setOf("whatsapp", "new messages", "messages")
    }
}

internal object ReaderCache {
    val lock = Any()

    fun prefs(context: Context) = context.getSharedPreferences(READER_PREFS, Context.MODE_PRIVATE)

    fun messages(context: Context): JSONArray = synchronized(lock) {
        if (!hasCaptureConsent(context)) {
            prefs(context).edit().remove(MESSAGES_KEY).apply()
            return@synchronized JSONArray()
        }
        val retained = readMessages(prefs(context))
            .filter { System.currentTimeMillis() - parseTime(it) <= RETENTION_DAYS * 24 * 60 * 60 * 1000 }
        JSONArray().apply { retained.forEach(::put) }
    }

    fun groups(context: Context): JSONArray {
        val selected = selectedGroup(context)
        val raw = prefs(context).getString(GROUPS_KEY, null)
        val saved = raw?.let { runCatching { JSONArray(it) }.getOrDefault(JSONArray()) }
            ?: JSONArray()
        return JSONArray().apply {
            for (index in 0 until saved.length()) {
                val group = saved.optJSONObject(index) ?: continue
                put(JSONObject(group.toString()).put("selected", group.optString("id") == selected))
            }
        }
    }

    fun recordGroup(prefs: android.content.SharedPreferences, id: String, name: String, seenAt: Long) {
        val known = runCatching { JSONArray(prefs.getString(GROUPS_KEY, "[]")) }
            .getOrDefault(JSONArray())
        val groups = (0 until known.length()).mapNotNull { known.optJSONObject(it) }
            .associateBy { it.optString("id") }.toMutableMap()
        groups[id] = JSONObject()
            .put("id", id)
            .put("name", name)
            .put("lastSeen", Instant.ofEpochMilli(seenAt).toString())
        val updated = JSONArray()
        groups.values.sortedBy { it.optString("name").lowercase() }.forEach(updated::put)
        prefs.edit().putString(GROUPS_KEY, updated.toString()).apply()
    }

    fun read(context: Context, mode: String): JSONObject {
        val prefs = prefs(context)
        val selected = prefs.getString(SELECTED_GROUP_KEY, null)
        val result = JSONObject().put("type", "history_result").put("mode", mode)
        if (selected.isNullOrEmpty()) {
            return result.put("error", "Select a WhatsApp group first.").put("messages", JSONArray())
        }
        val matching = mutableListOf<JSONObject>()
        val cache = messages(context)
        for (index in 0 until cache.length()) {
            val item = cache.optJSONObject(index) ?: continue
            if (item.optString("chat") == selected) matching += item
        }
        matching.sortBy(::parseTime)
        result.put("cachedGroupMessages", matching.size)
        val selectedMessages = if (mode == "latest") {
            matching.takeLast(1)
        } else {
            val today = LocalDate.now()
            matching.filter { item ->
                runCatching {
                    Instant.parse(item.getString("timestamp")).atZone(ZoneId.systemDefault()).toLocalDate() == today
                }.getOrDefault(false)
            }
        }
        val output = JSONArray().apply { selectedMessages.forEach(::put) }
        result.put("messages", output)
        if (selectedMessages.isEmpty()) {
            result.put(
                "error",
                if (matching.isEmpty()) "No WhatsApp notification messages have been captured for this group yet. Enable message previews in WhatsApp and leave notification access enabled."
                else "No messages from today were captured in this group's notifications."
            )
        }
        return result
    }

    fun select(context: Context, groupId: String) {
        val prefs = prefs(context)
        synchronized(lock) {
            val previousGroup = prefs.getString(SELECTED_GROUP_KEY, null)
            val retained = if (previousGroup == groupId && hasCaptureConsent(context)) {
                readMessages(prefs).filter { it.optString("chat") == groupId }
            } else {
                emptyList()
            }
            val array = JSONArray().apply { retained.forEach(::put) }
            prefs.edit()
                .putString(SELECTED_GROUP_KEY, groupId)
                .putString(MESSAGES_KEY, array.toString())
                .putBoolean(CAPTURE_CONSENT_KEY, previousGroup == groupId && hasCaptureConsent(context))
                .apply()
        }
    }

    fun setCaptureConsent(context: Context, allowed: Boolean) {
        val prefs = prefs(context)
        synchronized(lock) {
            val hadConsent = prefs.getBoolean(CAPTURE_CONSENT_KEY, false)
            val editor = prefs.edit().putBoolean(CAPTURE_CONSENT_KEY, allowed)
            if (!allowed || !hadConsent) editor.remove(MESSAGES_KEY)
            editor.apply()
        }
    }

    fun hasCaptureConsent(context: Context): Boolean =
        prefs(context).getBoolean(CAPTURE_CONSENT_KEY, false)

    fun selectedGroup(context: Context): String? =
        prefs(context).getString(SELECTED_GROUP_KEY, null)

    fun clearMessages(context: Context) {
        prefs(context).edit().remove(MESSAGES_KEY).apply()
    }

    fun enforceConsent(context: Context) {
        if (!hasCaptureConsent(context)) clearMessages(context)
    }
}

private fun readMessages(prefs: android.content.SharedPreferences): MutableList<JSONObject> {
    val raw = prefs.getString(MESSAGES_KEY, null) ?: return mutableListOf()
    return runCatching {
        val array = JSONArray(raw)
        MutableList(array.length()) { index -> array.getJSONObject(index) }
    }.getOrDefault(mutableListOf())
}

private fun parseTime(item: JSONObject): Long = runCatching {
    Instant.parse(item.getString("timestamp")).toEpochMilli()
}.getOrDefault(0L)

private fun JSONObject.toMap(): Map<String, Any?> = keys().asSequence().associateWith { key ->
    when (val value = get(key)) {
        JSONObject.NULL -> null
        is JSONObject -> value.toMap()
        is JSONArray -> value.toList()
        else -> value
    }
}

private fun JSONArray.toList(): List<Any?> = (0 until length()).map { index ->
    when (val value = get(index)) {
        JSONObject.NULL -> null
        is JSONObject -> value.toMap()
        is JSONArray -> value.toList()
        else -> value
    }
}

/** Shared with the activity so notification events arrive on Flutter's main thread. */
internal object ReaderEventBus {
    @Volatile var emitJson: ((String) -> Unit)? = null
    fun emit(type: String, fields: Map<String, Any?>) {
        val event = JSONObject().put("type", type)
        fields.forEach { (key, value) -> event.put(key, value) }
        emitJson?.invoke(event.toString())
    }
}

internal fun notificationAccessEnabled(context: Context): Boolean {
    val component = ComponentName(context, WhatsAppNotificationReaderService::class.java).flattenToString()
    val enabled = Settings.Secure.getString(context.contentResolver, "enabled_notification_listeners") ?: return false
    return enabled.split(':').any { it.equals(component, ignoreCase = true) }
}

internal fun openNotificationAccessSettings(context: Context) {
    context.startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
}
