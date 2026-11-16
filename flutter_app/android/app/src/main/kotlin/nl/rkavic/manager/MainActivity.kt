package nl.rkavic.manager

import android.os.Handler
import android.os.Looper
import bridge.Listener
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val methodName = "nl.rkavic.manager/android_whatsapp_spike"
    private val eventName = "nl.rkavic.manager/android_whatsapp_events"
    private val mainHandler = Handler(Looper.getMainLooper())
    private var eventSink: EventChannel.EventSink? = null
    @Volatile private var pollReader: Listener? = null
    @Volatile private var pollReaderRunning = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        ReaderCache.enforceConsent(this)
        ReaderEventBus.emitJson = { json -> mainHandler.post { eventSink?.success(json) } }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, methodName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        if (notificationAccessEnabled(this)) result.success(true)
                        else {
                            openNotificationAccessSettings(this)
                            result.success(false)
                        }
                    }
                    "startPollReader" -> {
                        try {
                            if (pollReader == null) {
                                val directory = java.io.File(filesDir, "whatsapp-spike")
                                directory.mkdirs()
                                val listener = Listener()
                                listener.start(java.io.File(directory, "session.sqlite").absolutePath)
                                pollReader = listener
                                pollReaderRunning = true
                                Thread {
                                    while (pollReaderRunning) {
                                        try {
                                            val event = listener.nextEvent()
                                            mainHandler.post { eventSink?.success(event) }
                                        } catch (_: Throwable) {
                                            if (!pollReaderRunning) break
                                        }
                                    }
                                }.apply { name = "WhatsAppPollReaderEvents"; isDaemon = true }.start()
                            }
                            result.success(true)
                        } catch (error: Throwable) {
                            result.error("POLL_READER_START", error.message ?: "Could not start linked-device reader.", null)
                        }
                    }
                    "pairPollReader" -> {
                        val phone = call.argument<String>("phone")?.filter(Char::isDigit)
                        if (phone.isNullOrBlank()) {
                            result.error("INVALID_PHONE", "Enter the WhatsApp account phone number with country code.", null)
                        } else {
                            val listener = pollReader
                            if (listener == null) result.error("READER_NOT_STARTED", "Start the linked-device reader first.", null)
                            else Thread {
                                try {
                                    val response = listener.pairPhone(phone)
                                    mainHandler.post { result.success(response) }
                                } catch (error: Throwable) {
                                    mainHandler.post { result.error("PAIR_FAILED", error.message, null) }
                                }
                            }.start()
                        }
                    }
                    "pollGroups" -> result.success(pollReader?.groups() ?: "[]")
                    "selectPollGroup" -> {
                        val group = call.argument<String>("id")
                        val listener = pollReader
                        if (listener == null) result.error("READER_NOT_STARTED", "Start the linked-device reader first.", null)
                        else if (group.isNullOrBlank()) result.error("INVALID_GROUP", "Select a group.", null)
                        else { listener.setGroup(group); result.success(true) }
                    }
                    "readPollToday" -> result.success(pollReader?.readToday() ?: "{\"messages\":[],\"error\":\"Start the linked-device reader first.\"}")
                    "readPollLatest" -> result.success(pollReader?.readLatest() ?: "{\"messages\":[],\"error\":\"Start the linked-device reader first.\"}")
                    "polls" -> {
                        val listener = pollReader
                        if (listener == null) result.success("{\"messages\":[]}")
                        else {
                            val today = org.json.JSONObject(listener.readToday())
                            val latest = org.json.JSONObject(listener.readLatest())
                            val combined = org.json.JSONArray()
                            val seen = mutableSetOf<String>()
                            for (source in listOf(today, latest)) {
                                val messages = source.optJSONArray("messages") ?: continue
                                for (index in 0 until messages.length()) {
                                    val message = messages.optJSONObject(index) ?: continue
                                    if (message.optString("kind") == "poll" && seen.add(message.optString("id"))) combined.put(message)
                                }
                            }
                            result.success(org.json.JSONObject().put("messages", combined).toString())
                        }
                    }
                    "stopPollReader" -> {
                        pollReaderRunning = false
                        pollReader?.stop()
                        pollReader = null
                        result.success(true)
                    }
                    "hasNotificationAccess" -> result.success(notificationAccessEnabled(this))
                    "hasCaptureConsent" -> result.success(ReaderCache.hasCaptureConsent(this))
                    "setCaptureConsent" -> {
                        val allowed = call.argument<Boolean>("allowed") ?: false
                        ReaderCache.setCaptureConsent(this, allowed)
                        result.success(true)
                    }
                    "openNotificationAccess" -> {
                        openNotificationAccessSettings(this)
                        result.success(true)
                    }
                    "groups" -> result.success(
                        pollReader?.groups() ?: ReaderCache.groups(this).toString()
                    )
                    "selectGroup" -> {
                        val group = call.argument<String>("id")
                        if (group.isNullOrBlank()) result.error("INVALID_GROUP", "Select a group.", null)
                        else {
                            val linkedReader = pollReader
                            if (linkedReader != null && group.contains("@")) {
                                linkedReader.setGroup(group)
                            } else {
                                ReaderCache.select(this, group)
                            }
                            result.success(true)
                        }
                    }
                    "readToday" -> result.success(
                        pollReader?.readToday() ?: ReaderCache.read(this, "today").toString()
                    )
                    "readLatest" -> result.success(
                        pollReader?.readLatest() ?: ReaderCache.read(this, "latest").toString()
                    )
                    "stop" -> {
                        ReaderCache.setCaptureConsent(this, false)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, eventName)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                    ReaderEventBus.emitJson = null
                }
            })
    }

    override fun onResume() {
        super.onResume()
        ReaderEventBus.emit("reader_access", mapOf("enabled" to notificationAccessEnabled(this)))
    }

}
