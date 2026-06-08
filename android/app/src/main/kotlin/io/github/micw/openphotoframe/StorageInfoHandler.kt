package io.github.micw.openphotoframe

import android.os.StatFs
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Exposes filesystem capacity/free space to Flutter so the settings screen can
 * show how much space the synced photos use versus what is available.
 */
class StorageInfoHandler {
    companion object {
        private const val TAG = "StorageInfoHandler"
        private const val CHANNEL = "io.github.micw.openphotoframe/storage_info"
    }

    fun configureChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getStorageStats" -> {
                    val path = call.argument<String>("path")
                    if (path == null) {
                        result.error("ARG", "path is required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val stat = StatFs(path)
                        result.success(
                            mapOf(
                                "totalBytes" to stat.totalBytes,
                                "freeBytes" to stat.availableBytes
                            )
                        )
                    } catch (e: Exception) {
                        Log.e(TAG, "StatFs failed for $path", e)
                        result.error("STATFS", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
