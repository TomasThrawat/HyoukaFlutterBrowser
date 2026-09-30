package com.search.browser

import android.app.DownloadManager
import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.os.Environment
import android.webkit.CookieManager
import android.webkit.WebSettings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "hyouka.browser/native_downloads"
    }

    private lateinit var downloadManager: DownloadManager
    private lateinit var channel: MethodChannel

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        downloadManager = getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "startDownload" -> startDownload(call, result)
                "getDownloadStatus" -> getDownloadStatus(call, result)
                "removeDownload" -> removeDownload(call, result)
                else -> result.notImplemented()
            }
        }
    }

    private fun startDownload(call: MethodCall, result: MethodChannel.Result) {
        val url = call.argument<String>("url")
        if (url.isNullOrBlank()) {
            result.error("INVALID_URL", "Download URL is empty.", null)
            return
        }

        val fileName = sanitizeFileName(call.argument<String>("fileName"))
        val referer = call.argument<String>("referer")
            ?.trim()
            ?.takeIf { it.startsWith("http://") || it.startsWith("https://") }
        val userAgent = call.argument<String>("userAgent")
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?: WebSettings.getDefaultUserAgent(this)

        try {
            val cookieManager = CookieManager.getInstance()
            cookieManager.flush()
            val cookie = cookieManager.getCookie(url)

            val request = DownloadManager.Request(Uri.parse(url))
                .setTitle(fileName)
                .setDescription("Browser download")
                .setNotificationVisibility(
                    DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED
                )
                .setAllowedOverMetered(true)
                .setAllowedOverRoaming(true)
                .setDestinationInExternalPublicDir(
                    Environment.DIRECTORY_DOWNLOADS,
                    fileName,
                )

            if (!cookie.isNullOrBlank()) {
                request.addRequestHeader("Cookie", cookie)
            }

            request.addRequestHeader("User-Agent", userAgent)
            request.addRequestHeader("Accept", "*/*")
            request.addRequestHeader(
                "Accept-Language",
                Locale.getDefault().toLanguageTag(),
            )
            if (referer != null && referer != url) {
                request.addRequestHeader("Referer", referer)
            }

            result.success(downloadManager.enqueue(request))
        } catch (exception: Exception) {
            result.error(
                "DOWNLOAD_START_FAILED",
                exception.message ?: "Could not start download.",
                null,
            )
        }
    }

    private fun getDownloadStatus(call: MethodCall, result: MethodChannel.Result) {
        val id = call.arguments as? Number
        if (id == null) {
            result.error("INVALID_ID", "Download id is required.", null)
            return
        }
        val downloadId = id.toLong()
        var cursor: Cursor? = null
        try {
            cursor = downloadManager.query(
                DownloadManager.Query().setFilterById(downloadId)
            )
            if (cursor == null || !cursor.moveToFirst()) {
                result.error(
                    "NOT_FOUND",
                    "Download no longer exists.",
                    null,
                )
                return
            }

            val status = cursor.getInt(
                cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS)
            )
            val reason = cursor.getInt(
                cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_REASON)
            )
            val received = cursor.getLong(
                cursor.getColumnIndexOrThrow(
                    DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR
                )
            )
            val total = cursor.getLong(
                cursor.getColumnIndexOrThrow(
                    DownloadManager.COLUMN_TOTAL_SIZE_BYTES
                )
            )
            val localUri = cursor.getString(
                cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_LOCAL_URI)
            )

            val statusText = when (status) {
                DownloadManager.STATUS_PENDING -> "Queued"
                DownloadManager.STATUS_RUNNING -> "Downloading"
                DownloadManager.STATUS_SUCCESSFUL -> "Completed"
                DownloadManager.STATUS_FAILED -> "Failed"
                else -> "Unknown"
            }

            result.success(
                hashMapOf(
                    "status" to statusText,
                    "receivedBytes" to received,
                    "totalBytes" to total,
                    "reason" to if (status == DownloadManager.STATUS_FAILED) {
                        "DownloadManager reason code: $reason"
                    } else {
                        null
                    },
                    "localUri" to localUri,
                )
            )
        } catch (exception: Exception) {
            result.error(
                "DOWNLOAD_STATUS_FAILED",
                exception.message ?: "Could not read download status.",
                null,
            )
        } finally {
            cursor?.close()
        }
    }

    private fun removeDownload(call: MethodCall, result: MethodChannel.Result) {
        val id = call.arguments as? Number
        if (id == null) {
            result.error("INVALID_ID", "Download id is required.", null)
            return
        }
        try {
            result.success(downloadManager.remove(id.toLong()))
        } catch (exception: Exception) {
            result.error(
                "DOWNLOAD_REMOVE_FAILED",
                exception.message ?: "Could not remove download.",
                null,
            )
        }
    }

    private fun sanitizeFileName(value: String?): String {
        val input = value?.trim().orEmpty()
        val sanitized = input
            .replace(Regex("""[<>:"/\\|?*]"""), "_")
            .replace(Regex("""\s+"""), " ")
            .trim()
            .take(180)

        var normalized = sanitized.ifBlank { "browser_download.bin" }

        while (normalized.endsWith(".kkl", ignoreCase = true)) {
            normalized = normalized.dropLast(4).trim()
        }

        while (
            normalized.endsWith(".crdownload", ignoreCase = true) ||
            normalized.endsWith(".download", ignoreCase = true) ||
            normalized.endsWith(".part", ignoreCase = true) ||
            normalized.endsWith(".tmp", ignoreCase = true)
        ) {
            normalized = when {
                normalized.endsWith(".crdownload", ignoreCase = true) ->
                    normalized.dropLast(".crdownload".length)
                normalized.endsWith(".download", ignoreCase = true) ->
                    normalized.dropLast(".download".length)
                normalized.endsWith(".part", ignoreCase = true) ->
                    normalized.dropLast(".part".length)
                else -> normalized.dropLast(".tmp".length)
            }.trim()
        }

        for (extension in listOf(".apk", ".zip")) {
            while (
                normalized.endsWith(extension + extension, ignoreCase = true)
            ) {
                normalized = normalized.dropLast(extension.length).trim()
            }
        }

        return normalized.ifBlank { "browser_download.bin" }
    }
}
