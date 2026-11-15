package nl.rkavic.manager

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val methodName = "nl.rkavic.manager/android_whatsapp_spike"
    private val eventName = "nl.rkavic.manager/android_whatsapp_events"
    private val mainHandler = Handler(Looper.getMainLooper())
    private var eventSink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
                    "hasNotificationAccess" -> result.success(notificationAccessEnabled(this))
                    "openNotificationAccess" -> {
                        openNotificationAccessSettings(this)
                        result.success(true)
                    }
                    "groups" -> result.success(ReaderCache.groups(this).toString())
                    "selectGroup" -> {
                        val group = call.argument<String>("id")
                        if (group.isNullOrBlank()) result.error("INVALID_GROUP", "Select a group.", null)
                        else {
                            ReaderCache.select(this, group)
                            result.success(true)
                        }
                    }
                    "readToday" -> result.success(ReaderCache.read(this, "today").toString())
                    "readLatest" -> result.success(ReaderCache.read(this, "latest").toString())
                    "stop" -> result.success(true)
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
