package com.example.opencfu_mobile

import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

/**
 * Bridges the home-screen widget (see [BasicCaptureWidgetProvider], which
 * offers both a Basic Capture and an Advanced Setup tap target once resized
 * wide enough) to the Dart side over a method channel:
 *
 *  - Cold start (app not running): the widget's tap launches this Activity
 *    with [ACTION_BASIC_CAPTURE] or [ACTION_ADVANCED_CAPTURE]. Dart asks
 *    "getLaunchAction" once it is ready, and we hand back the pending action
 *    recorded here.
 *  - Warm start (app already running, singleTop): [onNewIntent] fires
 *    instead of a fresh `onCreate`, so we push straight to Dart via
 *    "launchBasicCapture"/"launchAdvancedCapture" on the already-live
 *    channel.
 *
 * Also exposes [SAVE_CHANNEL_NAME], used by `lib/services/local_export.dart`
 * to save exports into a persistent "OpenCFU" folder under the public
 * Downloads collection (see [saveToDownloads]).
 */
class MainActivity : FlutterActivity() {
    private var methodChannel: MethodChannel? = null
    private var pendingLaunchAction: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        pendingLaunchAction = actionFor(intent)

        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "getLaunchAction" -> {
                    result.success(pendingLaunchAction)
                    pendingLaunchAction = null
                }
                else -> result.notImplemented()
            }
        }
        methodChannel = channel

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SAVE_CHANNEL_NAME)
            .setMethodCallHandler { call, result ->
                if (call.method != "saveToDownloads") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val fileName = call.argument<String>("fileName")
                val mimeType = call.argument<String>("mimeType")
                val bytes = call.argument<ByteArray>("bytes")
                val subfolder = call.argument<String>("subfolder")
                if (fileName == null || mimeType == null || bytes == null) {
                    result.error("bad_args", "Missing fileName/mimeType/bytes", null)
                    return@setMethodCallHandler
                }
                try {
                    val path = saveToDownloads(fileName, mimeType, bytes, subfolder)
                    if (path == null) {
                        // Only reached on API <= 28 without WRITE_EXTERNAL_STORAGE
                        // granted yet -- Dart requests it and retries.
                        result.error("permission_required", "Storage permission needed", null)
                    } else {
                        result.success(path)
                    }
                } catch (error: Exception) {
                    result.error("save_failed", error.message, null)
                }
            }
    }

    /**
     * Writes [bytes] into a persistent "OpenCFU[/subfolder]" location under
     * the public Downloads collection. Returns the saved location, or null
     * if the caller needs to obtain a permission first (API <= 28 only).
     *
     *  - API 29+ (Android 10, scoped storage): inserted via
     *    [MediaStore.Downloads], which needs no runtime permission at all --
     *    this is exactly the case scoped storage exists for.
     *  - API <= 28: falls back to a direct file write under the public
     *    Downloads directory, which does need WRITE_EXTERNAL_STORAGE
     *    (declared with maxSdkVersion=28 in AndroidManifest.xml, matching
     *    this split).
     */
    private fun saveToDownloads(fileName: String, mimeType: String, bytes: ByteArray, subfolder: String?): String? {
        // subfolder ultimately comes from operator-entered text (file name /
        // plate name fields); strip path separators and ".." so it can't
        // escape the OpenCFU root or traverse elsewhere.
        val safeSubfolder = subfolder
            ?.replace(Regex("[/\\\\]"), "_")
            ?.replace("..", "_")
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
        val relativeDir = if (safeSubfolder != null) {
            "${Environment.DIRECTORY_DOWNLOADS}/OpenCFU/$safeSubfolder"
        } else {
            "${Environment.DIRECTORY_DOWNLOADS}/OpenCFU"
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val resolver = contentResolver
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, fileName)
                put(MediaStore.Downloads.MIME_TYPE, mimeType)
                put(MediaStore.Downloads.RELATIVE_PATH, relativeDir)
            }
            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw IllegalStateException("MediaStore insert returned null")
            resolver.openOutputStream(uri)?.use { it.write(bytes) }
                ?: throw IllegalStateException("Could not open output stream for $uri")
            return uri.toString()
        }

        val granted = ContextCompat.checkSelfPermission(
            this,
            android.Manifest.permission.WRITE_EXTERNAL_STORAGE,
        ) == PackageManager.PERMISSION_GRANTED
        if (!granted) return null

        @Suppress("DEPRECATION")
        val downloadsRoot = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
        val dir = File(downloadsRoot, if (safeSubfolder != null) "OpenCFU/$safeSubfolder" else "OpenCFU")
        if (!dir.exists()) dir.mkdirs()
        val file = File(dir, fileName)
        FileOutputStream(file).use { it.write(bytes) }
        return file.absolutePath
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        when (actionFor(intent)) {
            ACTION_LAUNCH_BASIC_CAPTURE -> methodChannel?.invokeMethod("launchBasicCapture", null)
            ACTION_LAUNCH_ADVANCED_CAPTURE -> methodChannel?.invokeMethod("launchAdvancedCapture", null)
        }
    }

    private fun actionFor(intent: Intent?): String? {
        return when (intent?.action) {
            ACTION_BASIC_CAPTURE -> ACTION_LAUNCH_BASIC_CAPTURE
            ACTION_ADVANCED_CAPTURE -> ACTION_LAUNCH_ADVANCED_CAPTURE
            else -> null
        }
    }

    companion object {
        const val ACTION_BASIC_CAPTURE = "com.example.opencfu_mobile.ACTION_BASIC_CAPTURE"
        const val ACTION_ADVANCED_CAPTURE = "com.example.opencfu_mobile.ACTION_ADVANCED_CAPTURE"
        private const val ACTION_LAUNCH_BASIC_CAPTURE = "basicCapture"
        private const val ACTION_LAUNCH_ADVANCED_CAPTURE = "advancedCapture"
        private const val CHANNEL_NAME = "opencfu_mobile/shortcut"
        private const val SAVE_CHANNEL_NAME = "opencfu_mobile/local_save"
    }
}
