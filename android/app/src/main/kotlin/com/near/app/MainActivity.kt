package com.near.app

import android.content.ContentValues
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.OutputStream
import java.util.UUID

class MainActivity : FlutterActivity() {
    private val channelName = "near/files"

    private data class Session(val uri: Uri, val out: OutputStream)
    private val sessions = mutableMapOf<String, Session>()

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
