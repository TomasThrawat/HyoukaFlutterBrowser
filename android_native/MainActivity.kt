package com.search.browser

import android.app.DownloadManager
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.os.Environment
import android.provider.MediaStore
import android.webkit.CookieManager
import android.webkit.WebSettings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.net.HttpURLConnection
import java.net.URL
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicLong

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "hyouka.browser/native_downloads"
    }

    private lateinit var downloadManager: DownloadManager
    private lateinit var channel: MethodChannel
    private val requestMetadata = ConcurrentHashMap<Long, DownloadRequest>()
    private val fallbackJobs = ConcurrentHashMap<Long, FallbackJob>()
    private val fallbackExecutor = Executors.newCachedThreadPool()
    private val managedDownloads = ConcurrentHashMap<Long, ManagedDownload>()
    private val managedId = AtomicLong(System.currentTimeMillis())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        downloadManager = getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "startDownload" -> startDownload(call, result)
                "getDownloadStatus" -> getDownloadStatus(call, result)
                "pauseDownload" -> pauseDownload(call, result)
                "resumeDownload" -> resumeDownload(call, result)
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

        val request = DownloadRequest(
            url = url,
            fileName = sanitizeFileName(call.argument<String>("fileName")),
            referer = call.argument<String>("referer")
                ?.trim()
                ?.takeIf { it.startsWith("http://") || it.startsWith("https://") },
            userAgent = call.argument<String>("userAgent")
                ?.trim()
                ?.takeIf { it.isNotEmpty() }
                ?: WebSettings.getDefaultUserAgent(this),
            mimeType = call.argument<String>("mimeType")
                ?.trim()
                ?.takeIf { it.isNotEmpty() },
        )

        val id = managedId.incrementAndGet()
        val job = ManagedDownload(request)
        managedDownloads[id] = job
        job.running = true
        fallbackExecutor.execute {
            performManagedDownload(id, job)
        }
        result.success(id)
    }

    private fun getDownloadStatus(call: MethodCall, result: MethodChannel.Result) {

        val id = call.arguments as? Number
        if (id == null) {
            result.error("INVALID_ID", "Download id is required.", null)
            return
        }

        val downloadId = id.toLong()
        managedDownloads[downloadId]?.let {
            result.success(it.toMap())
            return
        }
        fallbackJobs[downloadId]?.let {
            result.success(it.toMap())
            return
        }

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

            if (status == DownloadManager.STATUS_FAILED && reason == 403) {
                requestMetadata[downloadId]?.let { metadata ->
                    startFallbackDownload(downloadId, metadata)
                    result.success(
                        hashMapOf(
                            "status" to "Queued",
                            "receivedBytes" to 0L,
                            "totalBytes" to 0L,
                            "reason" to null,
                            "localUri" to null,
                        )
                    )
                    return
                }
            }

            val statusText = when (status) {
                DownloadManager.STATUS_PENDING -> "Queued"
                DownloadManager.STATUS_RUNNING -> "Downloading"
                DownloadManager.STATUS_SUCCESSFUL -> "Completed"
                DownloadManager.STATUS_FAILED -> "Failed"
                else -> "Unknown"
            }

            if (statusText == "Completed" || statusText == "Failed") {
                requestMetadata.remove(downloadId)
            }

            result.success(
                hashMapOf(
                    "status" to statusText,
                    "receivedBytes" to received,
                    "totalBytes" to total,
                    "reason" to if (status == DownloadManager.STATUS_FAILED) {
                        "DownloadManager reason code: " + reason
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

    private fun startFallbackDownload(id: Long, metadata: DownloadRequest) {
        if (fallbackJobs.containsKey(id)) {
            return
        }

        val job = FallbackJob()
        fallbackJobs[id] = job
        fallbackExecutor.execute {
            performFallbackDownload(id, metadata, job)
        }
    }

    private fun performFallbackDownload(
        id: Long,
        metadata: DownloadRequest,
        job: FallbackJob,
    ) {
        var connection: HttpURLConnection? = null
        var outputUri: Uri? = null
        var currentUrl = metadata.url
        var currentReferer = metadata.referer
        var redirectCount = 0

        try {
            job.status = "Downloading"

            while (redirectCount <= 6) {
                val cookie = CookieManager.getInstance().getCookie(currentUrl)
                val requestProfiles = listOf(
                    true to true,
                    true to false,
                    false to false,
                )
                var responseCode = -1

                for ((sendReferer, browserAccept) in requestProfiles) {
                    connection?.disconnect()
                    connection = (URL(currentUrl).openConnection() as HttpURLConnection).apply {
                        requestMethod = "GET"
                        instanceFollowRedirects = false
                        connectTimeout = 20_000
                        readTimeout = 30_000
                        setRequestProperty("User-Agent", metadata.userAgent)
                        setRequestProperty(
                            "Accept",
                            if (browserAccept) {
                                "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8"
                            } else {
                                "*/*"
                            },
                        )
                        setRequestProperty(
                            "Accept-Language",
                            Locale.getDefault().toLanguageTag(),
                        )
                        setRequestProperty("Sec-Fetch-Dest", "document")
                        setRequestProperty("Sec-Fetch-Mode", "navigate")
                        setRequestProperty("Sec-Fetch-User", "?1")
                        if (!cookie.isNullOrBlank()) {
                            setRequestProperty("Cookie", cookie)
                        }
                        if (sendReferer &&
                            !currentReferer.isNullOrBlank() &&
                            currentReferer != currentUrl
                        ) {
                            setRequestProperty("Referer", currentReferer)
                            try {
                                val refererUri = Uri.parse(currentReferer)
                                val targetUri = Uri.parse(currentUrl)
                                if (refererUri.scheme == targetUri.scheme &&
                                    refererUri.host == targetUri.host
                                ) {
                                    setRequestProperty("Sec-Fetch-Site", "same-origin")
                                    setRequestProperty(
                                        "Origin",
                                        refererUri.scheme + "://" + refererUri.host,
                                    )
                                } else {
                                    setRequestProperty("Sec-Fetch-Site", "cross-site")
                                }
                            } catch (_: Exception) {
                                setRequestProperty("Sec-Fetch-Site", "cross-site")
                            }
                        } else {
                            setRequestProperty("Sec-Fetch-Site", "none")
                        }
                    }
                    responseCode = connection.responseCode
                    if (responseCode != 403) {
                        break
                    }
                }

                if (responseCode in 300..399) {
                    val location = connection.getHeaderField("Location")
                    if (location.isNullOrBlank() || redirectCount >= 6) {
                        throw IllegalStateException("Redirect chain could not be completed.")
                    }

                    val nextUrl = URL(URL(currentUrl), location).toString()
                    currentReferer = currentUrl
                    currentUrl = nextUrl
                    redirectCount++
                    connection.disconnect()
                    connection = null
                    continue
                }

                if (responseCode == 403) {
                    throw HttpException(403)
                }
                if (responseCode !in 200..299) {
                    throw HttpException(responseCode)
                }

                val responseType = connection.contentType
                    ?.substringBefore(';')
                    ?.trim()
                val mimeType = metadata.mimeType
                    ?: responseType
                    ?: "application/octet-stream"
                val resolvedFileName = connection.getHeaderField("Content-Disposition")
                    ?.let { disposition ->
                        Regex("""filename\*=(?:UTF-8''|)([^;]+)""", RegexOption.IGNORE_CASE)
                            .find(disposition)
                            ?.groupValues
                            ?.getOrNull(1)
                            ?.trim()
                            ?.trim('"')
                            ?.let { java.net.URLDecoder.decode(it, "UTF-8") }
                            ?: Regex("""filename\s*=\s*"?([^";]+)"?""", RegexOption.IGNORE_CASE)
                                .find(disposition)
                                ?.groupValues
                                ?.getOrNull(1)
                                ?.trim()
                    }
                    ?.takeIf { it.isNotBlank() }
                    ?.let(::sanitizeFileName)
                    ?: metadata.fileName
                val total = connection.contentLengthLong
                job.totalBytes = if (total > 0) total else 0

                if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.Q) {
                    throw IllegalStateException("Fallback downloader requires Android 10 or newer.")
                }

                val values = ContentValues().apply {
                    put(MediaStore.Downloads.DISPLAY_NAME, resolvedFileName)
                    put(MediaStore.Downloads.MIME_TYPE, mimeType)
                    put(
                        MediaStore.Downloads.RELATIVE_PATH,
                        Environment.DIRECTORY_DOWNLOADS,
                    )
                    put(MediaStore.Downloads.IS_PENDING, 1)
                }

                outputUri = contentResolver.insert(
                    MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                    values,
                ) ?: throw IllegalStateException("Could not create the Downloads file.")

                job.localUri = outputUri.toString()

                connection.inputStream.use { input ->
                    contentResolver.openOutputStream(outputUri!!).use { output ->
                        requireNotNull(output) { "Could not open the Downloads file." }
                        val buffer = ByteArray(32 * 1024)
                        while (true) {
                            val count = input.read(buffer)
                            if (count < 0) {
                                break
                            }
                            output.write(buffer, 0, count)
                            job.receivedBytes += count
                        }
                        output.flush()
                    }
                }

                contentResolver.update(
                    outputUri!!,
                    ContentValues().apply {
                        put(MediaStore.Downloads.IS_PENDING, 0)
                    },
                    null,
                    null,
                )

                job.status = "Completed"
                requestMetadata.remove(id)
                return
            }

            throw IllegalStateException("Too many redirects.")
        } catch (exception: HttpException) {
            job.status = "Failed"
            job.reason = "HTTP " + exception.code
            outputUri?.let { contentResolver.delete(it, null, null) }
        } catch (exception: Exception) {
            job.status = "Failed"
            job.reason = exception.message ?: "Fallback download failed."
            outputUri?.let { contentResolver.delete(it, null, null) }
        } finally {
            connection?.disconnect()
        }
    }


    private fun pauseDownload(call: MethodCall, result: MethodChannel.Result) {
        val id = call.arguments as? Number
        if (id == null) {
            result.error("INVALID_ID", "Download id is required.", null)
            return
        }

        val job = managedDownloads[id.toLong()]
        if (job == null) {
            result.error("NOT_FOUND", "Download is not managed by the resumable downloader.", null)
            return
        }

        synchronized(job) {
            when (job.status) {
                "Queued", "Downloading" -> {
                    job.paused = true
                    job.status = "Paused"
                    job.connection?.disconnect()
                    result.success(true)
                }
                "Paused" -> result.success(true)
                else -> result.success(false)
            }
        }
    }

    private fun resumeDownload(call: MethodCall, result: MethodChannel.Result) {
        val id = call.arguments as? Number
        if (id == null) {
            result.error("INVALID_ID", "Download id is required.", null)
            return
        }

        val downloadId = id.toLong()
        val job = managedDownloads[downloadId]
        if (job == null) {
            result.error("NOT_FOUND", "Download is not managed by the resumable downloader.", null)
            return
        }

        synchronized(job) {
            if (job.status != "Paused") {
                result.success(false)
                return
            }
            job.paused = false
            job.reason = null
            if (!job.running) {
                job.running = true
                fallbackExecutor.execute {
                    performManagedDownload(downloadId, job)
                }
            }
            result.success(true)
        }
    }

    private fun performManagedDownload(id: Long, job: ManagedDownload) {
        var connection: HttpURLConnection? = null
        var redirectCount = 0
        var currentUrl = job.request.url
        var currentReferer = job.request.referer

        try {
            synchronized(job) {
                if (job.paused) {
                    job.status = "Paused"
                    job.running = false
                    return
                }
                job.status = "Downloading"
                job.reason = null
            }

            while (redirectCount <= 6) {
                synchronized(job) {
                    if (job.paused) {
                        job.status = "Paused"
                        job.running = false
                        return
                    }
                }

                val cookie = CookieManager.getInstance().getCookie(currentUrl)
                val resumeFrom = job.receivedBytes

                connection = (URL(currentUrl).openConnection() as HttpURLConnection).apply {
                    requestMethod = "GET"
                    instanceFollowRedirects = false
                    connectTimeout = 20_000
                    readTimeout = 30_000
                    setRequestProperty("User-Agent", job.request.userAgent)
                    setRequestProperty("Accept", "*/*")
                    setRequestProperty("Accept-Language", Locale.getDefault().toLanguageTag())
                    if (!cookie.isNullOrBlank()) {
                        setRequestProperty("Cookie", cookie)
                    }
                    if (!currentReferer.isNullOrBlank() && currentReferer != currentUrl) {
                        setRequestProperty("Referer", currentReferer)
                    }
                    if (resumeFrom > 0) {
                        setRequestProperty("Range", "bytes=" + resumeFrom + "-")
                    }
                }
                job.connection = connection

                val responseCode = connection.responseCode

                if (responseCode in 300..399) {
                    val location = connection.getHeaderField("Location")
                    if (location.isNullOrBlank() || redirectCount >= 6) {
                        throw IllegalStateException("Redirect chain could not be completed.")
                    }
                    val nextUrl = URL(URL(currentUrl), location).toString()
                    currentReferer = currentUrl
                    currentUrl = nextUrl
                    redirectCount++
                    connection.disconnect()
                    connection = null
                    continue
                }

                if (responseCode == 403) {
                    throw HttpException(403)
                }
                if (responseCode == 416 && resumeFrom > 0 && job.totalBytes > 0 && resumeFrom >= job.totalBytes) {
                    completeManagedFile(job)
                    return
                }
                if (responseCode !in 200..299) {
                    throw HttpException(responseCode)
                }

                val append = resumeFrom > 0 && responseCode == HttpURLConnection.HTTP_PARTIAL
                if (!append && resumeFrom > 0) {
                    job.receivedBytes = 0
                    job.totalBytes = 0
                }

                val responseType = connection.contentType
                    ?.substringBefore(';')
                    ?.trim()
                val mimeType = job.request.mimeType
                    ?: responseType
                    ?: "application/octet-stream"
                val contentLength = connection.contentLengthLong
                val total = if (append && contentLength > 0) {
                    resumeFrom + contentLength
                } else {
                    contentLength
                }
                if (total > 0) {
                    job.totalBytes = total
                }

                ensureManagedFile(job, mimeType)

                val outputUri = Uri.parse(requireNotNull(job.localUri))
                val mode = if (append) "wa" else "wt"

                connection.inputStream.use { input ->
                    contentResolver.openOutputStream(outputUri, mode).use { output ->
                        requireNotNull(output) { "Could not open the Downloads file." }
                        val buffer = ByteArray(32 * 1024)
                        while (true) {
                            synchronized(job) {
                                if (job.paused) {
                                    job.status = "Paused"
                                    return
                                }
                            }

                            val count = input.read(buffer)
                            if (count < 0) {
                                break
                            }
                            output.write(buffer, 0, count)
                            job.receivedBytes += count
                        }
                        output.flush()
                    }
                }

                completeManagedFile(job)
                return
            }

            throw IllegalStateException("Too many redirects.")
        } catch (exception: HttpException) {
            synchronized(job) {
                if (job.paused) {
                    job.status = "Paused"
                } else {
                    job.status = "Failed"
                    job.reason = if (exception.code == 403) {
                        "HTTP 403: Access denied."
                    } else {
                        "HTTP " + exception.code
                    }
                }
            }
        } catch (exception: Exception) {
            synchronized(job) {
                if (job.paused) {
                    job.status = "Paused"
                } else {
                    job.status = "Failed"
                    job.reason = exception.message ?: "Download failed."
                }
            }
        } finally {
            job.connection = null
            connection?.disconnect()
            job.running = false
        }
    }

    private fun ensureManagedFile(job: ManagedDownload, mimeType: String) {
        if (job.localUri != null) {
            return
        }

        if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.Q) {
            throw IllegalStateException("Downloads require Android 10 or newer.")
        }

        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, job.request.fileName)
            put(MediaStore.Downloads.MIME_TYPE, mimeType)
            put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
            put(MediaStore.Downloads.IS_PENDING, 1)
        }

        val uri = contentResolver.insert(
            MediaStore.Downloads.EXTERNAL_CONTENT_URI,
            values,
        ) ?: throw IllegalStateException("Could not create the Downloads file.")

        job.localUri = uri.toString()
    }

    private fun completeManagedFile(job: ManagedDownload) {
        val uri = job.localUri?.let(Uri::parse)
            ?: throw IllegalStateException("Download file is missing.")

        contentResolver.update(
            uri,
            ContentValues().apply {
                put(MediaStore.Downloads.IS_PENDING, 0)
            },
            null,
            null,
        )
        synchronized(job) {
            job.status = "Completed"
            job.reason = null
        }
    }

    private fun removeDownload(call: MethodCall, result: MethodChannel.Result) {
        val id = call.arguments as? Number
        if (id == null) {
            result.error("INVALID_ID", "Download id is required.", null)
            return
        }

        val downloadId = id.toLong()
        managedDownloads.remove(downloadId)?.let { job ->
            synchronized(job) {
                job.paused = true
                job.connection?.disconnect()
            }
            job.localUri?.let { contentResolver.delete(Uri.parse(it), null, null) }
            requestMetadata.remove(downloadId)
            result.success(1)
            return
        }

        try {
            val removed = downloadManager.remove(downloadId)
            fallbackJobs.remove(downloadId)?.let { job ->
                job.localUri?.let {
                    contentResolver.delete(Uri.parse(it), null, null)
                }
            }
            requestMetadata.remove(downloadId)
            result.success(removed)
        } catch (exception: Exception) {
            result.error(
                "DOWNLOAD_REMOVE_FAILED",
                exception.message ?: "Could not remove download.",
                null,
            )
        }
    }

    private class ManagedDownload(
        val request: DownloadRequest,
    ) {
        @Volatile var status: String = "Queued"
        @Volatile var paused: Boolean = false
        @Volatile var running: Boolean = false
        @Volatile var receivedBytes: Long = 0
        @Volatile var totalBytes: Long = 0
        @Volatile var reason: String? = null
        @Volatile var localUri: String? = null
        @Volatile var connection: HttpURLConnection? = null

        fun toMap(): HashMap<String, Any?> = hashMapOf(
            "status" to status,
            "receivedBytes" to receivedBytes,
            "totalBytes" to totalBytes,
            "reason" to reason,
            "localUri" to localUri,
        )
    }

    private data class DownloadRequest(
        val url: String,
        val fileName: String,
        val referer: String?,
        val userAgent: String,
        val mimeType: String?,
    )

    private class FallbackJob {
        @Volatile var status: String = "Queued"
        @Volatile var receivedBytes: Long = 0
        @Volatile var totalBytes: Long = 0
        @Volatile var reason: String? = null
        @Volatile var localUri: String? = null

        fun toMap(): HashMap<String, Any?> = hashMapOf(
            "status" to status,
            "receivedBytes" to receivedBytes,
            "totalBytes" to totalBytes,
            "reason" to reason,
            "localUri" to localUri,
        )
    }

    private class HttpException(val code: Int) : Exception()

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
