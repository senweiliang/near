package com.near.app

import android.Manifest
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.provider.MediaStore
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.OutputStream
import java.util.UUID

class MainActivity : FlutterActivity() {
    private val channelName = "near/files"
    private val backgroundChannelName = "near/background"
    private val notifPermissionRequestCode = 4711

    private data class Session(val uri: Uri, val out: OutputStream)
    private val sessions = mutableMapOf<String, Session>()

    private var shareChannel: MethodChannel? = null
    private val pendingShared = mutableListOf<String>()
    private var shareDartReady = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "beginIncoming" -> beginIncoming(call, result)
                    "appendChunk" -> appendChunk(call, result)
                    "finishIncoming" -> finishIncoming(call, result)
                    "cancelIncoming" -> cancelIncoming(call, result)
                    "openContent" -> openContent(call, result)
                    else -> result.notImplemented()
                }
            }
        shareChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "near/share").apply {
            setMethodCallHandler { call, result ->
                if (call.method == "getInitial") {
                    shareDartReady = true
                    result.success(pendingShared.toList())
                    pendingShared.clear()
                } else {
                    result.notImplemented()
                }
            }
        }
        receiveShare(intent)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, backgroundChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        ensureNotificationPermission()
                        val intent = Intent(this, NearForegroundService::class.java)
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }
                        result.success(null)
                    }
                    "stop" -> {
                        stopService(Intent(this, NearForegroundService::class.java))
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        receiveShare(intent)
    }

    // 其他 app 分享过来的 content:// 在后台线程复制到 cache，再把本地路径交给 Dart
    private fun receiveShare(intent: Intent?) {
        val uris = sharedUris(intent ?: return)
        if (uris.isEmpty()) return
        intent.action = null
        val appContext = applicationContext
        Thread {
            val paths = uris.mapNotNull { copyToCache(appContext, it) }
            Handler(Looper.getMainLooper()).post {
                if (paths.isEmpty()) return@post
                if (shareDartReady) {
                    shareChannel?.invokeMethod("shared", paths)
                } else {
                    pendingShared.addAll(paths)
                }
            }
        }.start()
    }

    @Suppress("DEPRECATION")
    private fun sharedUris(intent: Intent): List<Uri> = when (intent.action) {
        Intent.ACTION_SEND -> listOfNotNull(intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))
        Intent.ACTION_SEND_MULTIPLE ->
            intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM) ?: emptyList()
        else -> emptyList()
    }

    private fun copyToCache(context: android.content.Context, uri: Uri): String? {
        return try {
            val resolver = context.contentResolver
            var name = uri.lastPathSegment ?: "file"
            resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst() && !cursor.isNull(0)) name = cursor.getString(0)
            }
            val safeName = name.replace('/', '_')
            val dir = File(context.cacheDir, "shared/${UUID.randomUUID()}").apply { mkdirs() }
            val target = File(dir, safeName)
            resolver.openInputStream(uri)?.use { input ->
                target.outputStream().use { output -> input.copyTo(output) }
            } ?: return null
            target.absolutePath
        } catch (e: Exception) {
            Log.e("Near", "copy shared uri failed: $uri", e)
            null
        }
    }

    private fun ensureNotificationPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        val granted = ContextCompat.checkSelfPermission(
            this, Manifest.permission.POST_NOTIFICATIONS
        ) == PackageManager.PERMISSION_GRANTED
        if (!granted) {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                notifPermissionRequestCode
            )
        }
    }

    private fun beginIncoming(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.error("UNSUPPORTED", "MediaStore.Downloads requires API 29+", null)
            return
        }
        val name = call.argument<String>("displayName")
        val mime = call.argument<String?>("mimeType")
        if (name == null) {
            result.error("ARGS", "displayName is required", null)
            return
        }
        try {
            val resolver = applicationContext.contentResolver
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, name)
                if (!mime.isNullOrEmpty()) put(MediaStore.Downloads.MIME_TYPE, mime)
                put(
                    MediaStore.Downloads.RELATIVE_PATH,
                    "${Environment.DIRECTORY_DOWNLOADS}/Near"
                )
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw IllegalStateException("MediaStore insert returned null")
            val out = resolver.openOutputStream(uri)
                ?: throw IllegalStateException("openOutputStream returned null")
            val sessionId = UUID.randomUUID().toString()
            sessions[sessionId] = Session(uri, out)
            result.success(mapOf("sessionId" to sessionId, "uri" to uri.toString()))
        } catch (e: Exception) {
            Log.e("Near", "beginIncoming failed", e)
            result.error("IO", e.message, null)
        }
    }

    private fun appendChunk(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
        val sessionId = call.argument<String>("sessionId")
        val bytes = call.argument<ByteArray>("bytes")
        if (sessionId == null || bytes == null) {
            result.error("ARGS", "sessionId and bytes are required", null)
            return
        }
        val session = sessions[sessionId]
        if (session == null) {
            result.error("NO_SESSION", "session not found: $sessionId", null)
            return
        }
        try {
            session.out.write(bytes)
            result.success(null)
        } catch (e: Exception) {
            Log.e("Near", "appendChunk failed", e)
            result.error("IO", e.message, null)
        }
    }

    private fun finishIncoming(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
        val sessionId = call.argument<String>("sessionId")
        if (sessionId == null) {
            result.error("ARGS", "sessionId is required", null)
            return
        }
        val session = sessions.remove(sessionId)
        if (session == null) {
            result.error("NO_SESSION", "session not found: $sessionId", null)
            return
        }
        try {
            session.out.flush()
            session.out.close()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val finalize = ContentValues().apply {
                    put(MediaStore.Downloads.IS_PENDING, 0)
                }
                applicationContext.contentResolver.update(session.uri, finalize, null, null)
            }
            result.success(session.uri.toString())
        } catch (e: Exception) {
            Log.e("Near", "finishIncoming failed", e)
            result.error("IO", e.message, null)
        }
    }

    private fun cancelIncoming(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
        val sessionId = call.argument<String>("sessionId")
        if (sessionId == null) {
            result.success(null)
            return
        }
        val session = sessions.remove(sessionId)
        if (session != null) {
            try { session.out.close() } catch (_: Exception) {}
            try { applicationContext.contentResolver.delete(session.uri, null, null) } catch (_: Exception) {}
        }
        result.success(null)
    }

    private fun openContent(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
        val uriStr = call.argument<String>("uri")
        val mime = call.argument<String?>("mimeType")
        if (uriStr == null) {
            result.error("ARGS", "uri is required", null)
            return
        }
        val view = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(Uri.parse(uriStr), mime ?: "*/*")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        try {
            startActivity(view)
            result.success(true)
            return
        } catch (e: android.content.ActivityNotFoundException) {
            // Fall through to chooser (which surfaces the system "no app" dialog).
        } catch (e: Exception) {
            Log.e("Near", "openContent direct failed", e)
        }
        try {
            val chooser = Intent.createChooser(view, null).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(chooser)
            result.success(true)
        } catch (e: Exception) {
            Log.e("Near", "openContent chooser failed", e)
            result.error("ACTIVITY", e.message, null)
        }
    }
}
