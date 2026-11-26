package com.example.panelshift // <-- Keep your existing package name here

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.zip.CRC32
import java.util.zip.Deflater
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream
import java.util.zip.ZipOutputStream

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "panelshift/saf_picker"
        private const val REQ_PICK_COMIC = 4109
        private const val REQ_PICK_FOLDER = 4110
        private const val REQ_PICK_ZIP_PARENT = 4111

        // Folder import: how deep sub-folders are scanned, and the copy buffer
        // used when streaming one document into cache/file_picker/ (only done
        // on demand now, to stage a .cbr/.rar for extraction).
        private const val MAX_SCAN_DEPTH = 8
        private const val COPY_BUFFER_BYTES = 64 * 1024

        // Comic identity = MD5 of the first 64 KB + byte size (must match
        // ComicIdentity.fromFile on the Dart side).
        private const val FINGERPRINT_BYTES = 64 * 1024

        private val COMIC_EXTENSIONS = setOf("cbz", "zip", "cbr", "rar")
        private val UNSAFE_NAME_CHARS = Regex("[\\\\/:*?\"<>|]")

        // .zip import
        private const val EXTERNAL_STORAGE_AUTHORITY = "com.android.externalstorage.documents"
        private const val ZIP_ENTRY_MIME = "application/octet-stream"

        // Image-only folders are packed into a truly STORED .cbz. A STORED
        // entry needs its CRC and size before it is written, so one page is
        // held in memory; a page above this size is written with level-0
        // deflate instead (still no compression, still streamed).
        private const val MAX_STORED_ENTRY_BYTES = 8 * 1024 * 1024

        private val PAGE_IMAGE_EXTENSIONS = setOf("jpg", "jpeg", "png", "webp")
        private val IGNORED_ZIP_DIRECTORIES = setOf(
            "__macosx", ".spotlight-v100", ".trashes", "\$recycle.bin", "system volume information"
        )
        private val IGNORED_ZIP_FILES = setOf("thumbs.db", "ehthumbs.db", "desktop.ini", ".ds_store")
    }

    private var pendingPickResult: MethodChannel.Result? = null
    private var pendingFolderResult: MethodChannel.Result? = null
    private var pendingFolderRecursive: Boolean = true

    // Every SAF read/stat/hash runs here, never on the main (UI) thread.
    private val ioExecutor: ExecutorService = Executors.newFixedThreadPool(4)

    /**
     * Runs [block] on [ioExecutor] and delivers its value (or an error) to
     * [result] on the main thread, as MethodChannel requires.
     */
    private fun <T> runIo(result: MethodChannel.Result, errorCode: String, block: () -> T) {
        try {
            ioExecutor.execute {
                try {
                    val value = block()
                    runOnUiThread { result.success(value) }
                } catch (e: Exception) {
                    runOnUiThread { result.error(errorCode, e.message, null) }
                }
            }
        } catch (e: RejectedExecutionException) {
            result.error(errorCode, "Activity is shutting down.", null)
        }
    }

    override fun onDestroy() {
        ioExecutor.shutdown()
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickComic" -> {
                        if (pendingPickResult != null || pendingFolderResult != null) {
                            result.error("BUSY", "File picker is already open.", null)
                            return@setMethodCallHandler
                        }
                        pendingPickResult = result
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "*/*"
                            addFlags(
                                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                        Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                                        Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
                            )
                        }
                        @Suppress("DEPRECATION")
                        startActivityForResult(intent, REQ_PICK_COMIC)
                    }

                    // Folder import, step 1: let the user pick a folder and
                    // return only the *list* of matching child documents
                    // (uri / name / size). Nothing is copied here.
                    "pickComicFolder" -> {
                        if (pendingPickResult != null || pendingFolderResult != null) {
                            result.error("BUSY", "File picker is already open.", null)
                            return@setMethodCallHandler
                        }
                        pendingFolderRecursive = call.argument<Boolean>("recursive") ?: true
                        pendingFolderResult = result
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                            addFlags(
                                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                        Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                                        Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
                            )
                        }
                        try {
                            @Suppress("DEPRECATION")
                            startActivityForResult(intent, REQ_PICK_FOLDER)
                        } catch (e: ActivityNotFoundException) {
                            pendingFolderResult = null
                            result.error(
                                "NO_FOLDER_PICKER",
                                "This device has no folder picker.",
                                null
                            )
                        }
                    }

                    // On-demand staging helper: stream ONE document into
                    // cache/file_picker/. Dart uses it ONLY to extract
                    // .cbr/.rar archives (the RAR plugin needs a POSIX path)
                    // and deletes the copy right after extraction.
                    "copyDocumentToCache" -> {
                        val uriString = call.argument<String>("uri")
                        if (uriString.isNullOrBlank()) {
                            result.error("BAD_ARGS", "Missing document uri.", null)
                            return@setMethodCallHandler
                        }
                        val name = call.argument<String>("name")
                        Thread {
                            try {
                                val outFile = copyUriToPickerCache(Uri.parse(uriString), name)
                                runOnUiThread { result.success(outFile.absolutePath) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("COPY_FAILED", e.message, null) }
                            }
                        }.start()
                    }

                    // Opens the document, hashes at most its first 64 KB (MD5,
                    // lowercase hex) and reports name + size. Never copies.
                    "statAndHashUri" -> {
                        val uriString = call.argument<String>("uri")
                        if (uriString.isNullOrBlank()) {
                            result.success(mapOf("exists" to false))
                            return@setMethodCallHandler
                        }
                        runIo(result, "STAT_FAILED") { statAndHash(Uri.parse(uriString)) }
                    }

                    "existsUri" -> {
                        val uriString = call.argument<String>("uri")
                        if (uriString.isNullOrBlank()) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        runIo(result, "EXISTS_FAILED") { isUriReadable(Uri.parse(uriString)) }
                    }

                    // Random-access read: up to [length] bytes starting at [offset].
                    "readUriRange" -> {
                        val uriString = call.argument<String>("uri")
                        val offset = call.argument<Number>("offset")?.toLong()
                        val length = call.argument<Number>("length")?.toInt()
                        if (uriString.isNullOrBlank() || offset == null || length == null ||
                            offset < 0 || length < 0
                        ) {
                            result.error("BAD_ARGS", "Missing or invalid uri/offset/length.", null)
                            return@setMethodCallHandler
                        }
                        runIo(result, "READ_FAILED") {
                            readUriRange(Uri.parse(uriString), offset, length)
                        }
                    }

                    // Encodes raw 8-bit RGBA pixels (row-major, [width] x [height])
                    // as a JPEG. Used for the small library cover thumbnails.
                    "compressThumbnail" -> {
                        val rgba = call.argument<ByteArray>("rgba")
                        val width = call.argument<Number>("width")?.toInt()
                        val height = call.argument<Number>("height")?.toInt()
                        val quality = call.argument<Number>("quality")?.toInt() ?: 82
                        runIo(result, "COMPRESS_FAILED") {
                            if (rgba == null) {
                                throw IllegalArgumentException("Missing rgba pixels.")
                            }
                            if (width == null || width <= 0 || height == null || height <= 0) {
                                throw IllegalArgumentException("Invalid width/height.")
                            }
                            if (rgba.size.toLong() < width.toLong() * height.toLong() * 4L) {
                                throw IllegalArgumentException("rgba is smaller than width * height * 4.")
                            }
                            val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                            try {
                                bitmap.copyPixelsFromBuffer(ByteBuffer.wrap(rgba))
                                val out = ByteArrayOutputStream()
                                bitmap.compress(Bitmap.CompressFormat.JPEG, quality.coerceIn(1, 100), out)
                                out.toByteArray()
                            } finally {
                                bitmap.recycle()
                            }
                        }
                    }

                    "deleteUri" -> {
                        val uriString = call.argument<String>("uri")
                        if (uriString.isNullOrBlank()) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        result.success(deleteDocumentUri(Uri.parse(uriString)))
                    }

                    // .zip import: extract next to the original .zip, then
                    // delete it. Reply shape matches pickComicFolder.
                    "extractZipToOriginalFolder" -> {
                        val uriString = call.argument<String>("uri")
                        if (uriString.isNullOrBlank()) {
                            result.error("BAD_ARGS", "Missing .zip uri.", null)
                            return@setMethodCallHandler
                        }
                        if (zipImportRunning || pendingPickResult != null || pendingFolderResult != null) {
                            result.error("BUSY", "Another import is already in progress.", null)
                            return@setMethodCallHandler
                        }
                        zipImportRunning = true
                        beginZipImport(Uri.parse(uriString), result)
                    }

                    else -> result.notImplemented()
                }
            }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        when (requestCode) {
            REQ_PICK_COMIC -> handleComicPicked(resultCode, data)
            REQ_PICK_FOLDER -> handleFolderPicked(resultCode, data)
            REQ_PICK_ZIP_PARENT -> handleZipParentPicked(resultCode, data)
        }
    }

    private fun handleComicPicked(resultCode: Int, data: Intent?) {
        val callback = pendingPickResult ?: return
        pendingPickResult = null

        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            callback.success(null)
            return
        }

        // Persist read/write access: needed to re-open the comic after a restart
        // and so "Delete" can remove the original later.
        val takeFlags = data.flags and (
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                )
        try {
            contentResolver.takePersistableUriPermission(uri, takeFlags)
        } catch (_: SecurityException) {
            // Provider does not allow persistable grants; reading works for this session.
        }

        // Metadata only: the archive is read in place through the content://
        // URI (see readUriRange); nothing is copied into app storage.
        try {
            ioExecutor.execute {
                try {
                    val (name, size) = queryNameAndSize(uri)
                    val displayName = name ?: uri.lastPathSegment ?: ""
                    runOnUiThread {
                        callback.success(
                            mapOf(
                                "uri" to uri.toString(),
                                "fileName" to displayName,
                                "size" to size
                            )
                        )
                    }
                } catch (e: Exception) {
                    runOnUiThread {
                        callback.error("PICK_FAILED", e.message, null)
                    }
                }
            }
        } catch (e: RejectedExecutionException) {
            callback.error("PICK_FAILED", "Activity is shutting down.", null)
        }
    }

    private fun handleFolderPicked(resultCode: Int, data: Intent?) {
        val callback = pendingFolderResult ?: return
        pendingFolderResult = null
        val recursive = pendingFolderRecursive

        val treeUri = data?.data
        if (resultCode != Activity.RESULT_OK || treeUri == null) {
            callback.success(null)
            return
        }

        // One persisted grant on the tree covers every document below it, so
        // "Delete all read" can still delete each original later (and we do not
        // burn one persisted-permission slot per comic).
        val takeFlags = data.flags and (
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                )
        try {
            contentResolver.takePersistableUriPermission(treeUri, takeFlags)
        } catch (_: SecurityException) {
            // Provider does not allow persistable grants; importing still works.
        }

        // Listing only reads metadata (a few strings per comic), but it can
        // still touch slow storage, so keep it off the UI thread.
        Thread {
            try {
                val files = listComicDocuments(treeUri, recursive)
                val folderName = queryFolderName(treeUri)
                runOnUiThread {
                    callback.success(
                        mapOf(
                            "treeUri" to treeUri.toString(),
                            "folderName" to folderName,
                            "files" to files
                        )
                    )
                }
            } catch (e: Exception) {
                runOnUiThread {
                    callback.error("LIST_FAILED", e.message, null)
                }
            }
        }.start()
    }

    /**
     * Display name of the folder the user picked (shown on the library shelf).
     * The tree URI is resolved to the picked folder's own document URI and its
     * COLUMN_DISPLAY_NAME is read through the content resolver; when the
     * provider reports nothing, falls back to the URI's last path segment.
     */
    private fun queryFolderName(treeUri: Uri): String {
        val fallback = treeUri.lastPathSegment ?: "Imported Folder"
        return try {
            val folderUri = DocumentsContract.buildDocumentUriUsingTree(
                treeUri,
                DocumentsContract.getTreeDocumentId(treeUri)
            )
            var name: String? = null
            contentResolver.query(
                folderUri,
                arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME),
                null,
                null,
                null
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val idx = cursor.getColumnIndex(
                        DocumentsContract.Document.COLUMN_DISPLAY_NAME
                    )
                    if (idx >= 0 && !cursor.isNull(idx)) name = cursor.getString(idx)
                }
            }
            name?.takeIf { it.isNotBlank() } ?: fallback
        } catch (_: Exception) {
            fallback
        }
    }

    private fun sanitizeFileName(name: String): String =
        name.replace(UNSAFE_NAME_CHARS, "_")

    /**
     * Streams [uri] into cache/file_picker/ with a small fixed buffer, so memory
     * stays flat no matter how large the archive is. Returns the written file.
     */
    private fun copyUriToPickerCache(uri: Uri, rawName: String?): File {
        val name = if (rawName.isNullOrBlank()) {
            "comic_${System.currentTimeMillis()}.cbz"
        } else {
            rawName
        }
        val pickerDir = File(cacheDir, "file_picker").apply { mkdirs() }
        val outFile = File(pickerDir, sanitizeFileName(name))

        try {
            contentResolver.openInputStream(uri)?.use { input ->
                FileOutputStream(outFile).use { output ->
                    input.copyTo(output, COPY_BUFFER_BYTES)
                }
            } ?: throw IllegalStateException("Could not open input stream for $uri")
        } catch (e: Exception) {
            // Never leave a half-written archive behind in the cache.
            try {
                outFile.delete()
            } catch (_: Exception) {
            }
            throw e
        }
        return outFile
    }

    /**
     * Lists every comic archive (.cbz/.zip/.cbr/.rar) below [treeUri] without
     * opening or copying any of them. Sub-folders are scanned breadth-first up
     * to [MAX_SCAN_DEPTH] when [recursive] is true. Each entry carries the
     * child document URI (usable later for deletion through the tree grant),
     * its display name, a file-system-safe name, its path relative to the picked
     * folder (used by Dart for natural ordering) and its byte size (-1 when the
     * provider does not report one).
     */
    private fun listComicDocuments(treeUri: Uri, recursive: Boolean): List<Map<String, Any>> {
        val results = ArrayList<Map<String, Any>>()

        // Breadth-first queue of folders: (document id, relative path prefix, depth).
        val pending = ArrayList<Triple<String, String, Int>>()
        pending.add(Triple(DocumentsContract.getTreeDocumentId(treeUri), "", 0))

        var head = 0
        while (head < pending.size) {
            val (parentId, parentPath, depth) = pending[head++]
            val childrenUri =
                DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, parentId)

            try {
                contentResolver.query(
                    childrenUri,
                    arrayOf(
                        DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                        DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                        DocumentsContract.Document.COLUMN_MIME_TYPE,
                        DocumentsContract.Document.COLUMN_SIZE
                    ),
                    null,
                    null,
                    null
                )?.use { cursor ->
                    val idIdx = cursor.getColumnIndexOrThrow(
                        DocumentsContract.Document.COLUMN_DOCUMENT_ID
                    )
                    val nameIdx = cursor.getColumnIndexOrThrow(
                        DocumentsContract.Document.COLUMN_DISPLAY_NAME
                    )
                    val mimeIdx = cursor.getColumnIndexOrThrow(
                        DocumentsContract.Document.COLUMN_MIME_TYPE
                    )
                    val sizeIdx = cursor.getColumnIndexOrThrow(
                        DocumentsContract.Document.COLUMN_SIZE
                    )

                    while (cursor.moveToNext()) {
                        val docId = cursor.getString(idIdx) ?: continue
                        val name = cursor.getString(nameIdx) ?: continue
                        if (name.startsWith(".")) continue // hidden files / folders

                        val mime = cursor.getString(mimeIdx)
                        if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                            if (recursive && depth < MAX_SCAN_DEPTH) {
                                pending.add(Triple(docId, "$parentPath$name/", depth + 1))
                            }
                            continue
                        }

                        val extension = name.substringAfterLast('.', "").lowercase()
                        if (extension !in COMIC_EXTENSIONS) continue

                        val size = if (cursor.isNull(sizeIdx)) -1L else cursor.getLong(sizeIdx)
                        val documentUri =
                            DocumentsContract.buildDocumentUriUsingTree(treeUri, docId)

                        results.add(
                            mapOf(
                                "uri" to documentUri.toString(),
                                "name" to name,
                                "fileName" to sanitizeFileName(name),
                                "path" to "$parentPath$name",
                                "size" to size
                            )
                        )
                    }
                }
            } catch (e: Exception) {
                // An unreadable sub-folder is skipped; an unreadable picked
                // folder is a real failure.
                if (depth == 0) throw e
            }
        }
        return results
    }

    /** DISPLAY_NAME and SIZE (-1 when the provider reports none) via ContentResolver. */
    private fun queryNameAndSize(uri: Uri): Pair<String?, Long> {
        var name: String? = null
        var size = -1L
        contentResolver.query(
            uri,
            arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
            null,
            null,
            null
        )?.use { cursor ->
            if (cursor.moveToFirst()) {
                val nameIdx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (nameIdx >= 0 && !cursor.isNull(nameIdx)) name = cursor.getString(nameIdx)
                val sizeIdx = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (sizeIdx >= 0 && !cursor.isNull(sizeIdx)) size = cursor.getLong(sizeIdx)
            }
        }
        return Pair(name, size)
    }

    private fun statAndHash(uri: Uri): Map<String, Any> {
        return try {
            val buffer = ByteArray(FINGERPRINT_BYTES)
            var total = 0
            val stream = contentResolver.openInputStream(uri)
                ?: return mapOf("exists" to false)
            stream.use { input ->
                while (total < FINGERPRINT_BYTES) {
                    val n = input.read(buffer, total, FINGERPRINT_BYTES - total)
                    if (n < 0) break
                    total += n
                }
            }
            val digest = MessageDigest.getInstance("MD5")
            digest.update(buffer, 0, total)
            val hex = digest.digest().joinToString("") { "%02x".format(it) }

            val (name, reportedSize) = queryNameAndSize(uri)
            var size = reportedSize
            if (size < 0) {
                // Provider reports no SIZE: ask the file descriptor, and if the
                // whole file fit in the fingerprint read, we already know it.
                size = try {
                    contentResolver.openFileDescriptor(uri, "r")?.use { it.statSize } ?: -1L
                } catch (_: Exception) {
                    -1L
                }
                if (size < 0 && total < FINGERPRINT_BYTES) size = total.toLong()
            }

            mapOf(
                "exists" to true,
                "fileName" to (name ?: ""),
                "size" to size,
                "md5Prefix" to hex
            )
        } catch (_: Exception) {
            // Missing, permission revoked, provider gone...
            mapOf("exists" to false)
        }
    }

    private fun isUriReadable(uri: Uri): Boolean {
        return try {
            contentResolver.openFileDescriptor(uri, "r")?.use { true } ?: false
        } catch (_: Exception) {
            // Some providers cannot hand out descriptors; a row with a display
            // name still means the document exists and the grant works.
            try {
                queryNameAndSize(uri).first != null
            } catch (_: Exception) {
                false
            }
        }
    }

    private fun readUriRange(uri: Uri, offset: Long, length: Int): ByteArray {
        if (length == 0) return ByteArray(0)
        try {
            val pfd = contentResolver.openFileDescriptor(uri, "r")
                ?: throw IllegalStateException("Could not open $uri")
            return pfd.use { descriptor ->
                FileInputStream(descriptor.fileDescriptor).use { stream ->
                    val channel = stream.channel
                    channel.position(offset)
                    val bytes = ByteArray(length)
                    val buffer = ByteBuffer.wrap(bytes)
                    var total = 0
                    while (total < length) {
                        val n = channel.read(buffer)
                        if (n < 0) break
                        total += n
                    }
                    if (total == length) bytes else bytes.copyOf(total)
                }
            }
        } catch (e: java.io.IOException) {
            // Non-seekable descriptor (some cloud providers): slow but correct.
            return readUriRangeSequential(uri, offset, length)
        }
    }

    private fun readUriRangeSequential(uri: Uri, offset: Long, length: Int): ByteArray {
        val stream = contentResolver.openInputStream(uri)
            ?: throw IllegalStateException("Could not open input stream for $uri")
        return stream.use { input ->
            var skipped = 0L
            while (skipped < offset) {
                val n = input.skip(offset - skipped)
                if (n <= 0) break
                skipped += n
            }
            val bytes = ByteArray(length)
            var total = 0
            if (skipped == offset) {
                while (total < length) {
                    val n = input.read(bytes, total, length - total)
                    if (n < 0) break
                    total += n
                }
            }
            if (total == length) bytes else bytes.copyOf(total)
        }
    }

    private fun deleteDocumentUri(uri: Uri): Boolean {
        val deleted = try {
            DocumentsContract.deleteDocument(contentResolver, uri)
        } catch (_: IllegalArgumentException) {
            // Document was already deleted externally.
            true
        } catch (_: SecurityException) {
            // Storage provider or OS denied deletion.
            false
        } catch (_: Exception) {
            false
        }

        // A document that lives under a picked folder is covered by the folder's
        // (tree) grant, which other comics from that folder still rely on, so
        // only per-file grants are released here.
        val isTreeDocument = uri.pathSegments.contains("tree")

        if (deleted && !isTreeDocument) {
            try {
                contentResolver.releasePersistableUriPermission(
                    uri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                            Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                )
            } catch (_: Exception) {
            }
        }
        return deleted
    }

    // =====================================================================
    // .zip import
    // =====================================================================

    private class ZipImportException(val code: String, message: String) : Exception(message)

    private class ZipImportJob(
        val result: MethodChannel.Result,
        val zipUri: Uri,
        val zipName: String,
        val parentDocId: String
    )

    private class ZipScan(
        val archiveCount: Int,
        val imageCounts: LinkedHashMap<String, Int>
    )

    private class OpenCbz(
        val uri: Uri,
        val requestedName: String,
        val output: ZipOutputStream,
        var remaining: Int
    ) {
        val usedNames = HashSet<String>()
    }

    private var zipImportRunning = false
    private var pendingZipTreeJob: ZipImportJob? = null

    private fun completeZipImport(result: MethodChannel.Result, reply: Map<String, Any>) {
        runOnUiThread {
            zipImportRunning = false
            result.success(reply)
        }
    }

    private fun failZipImport(result: MethodChannel.Result, e: Exception) {
        runOnUiThread {
            zipImportRunning = false
            val code = (e as? ZipImportException)?.code ?: "ZIP_FAILED"
            result.error(code, e.message ?: "Could not extract the .zip file.", null)
        }
    }

    /**
     * Resolves the .zip's name and parent folder. If a persisted tree grant
     * already covers that folder the extraction starts right away; otherwise
     * the folder picker opens (pre-navigated to the parent) to get one.
     */
    private fun beginZipImport(zipUri: Uri, result: MethodChannel.Result) {
        try {
            ioExecutor.execute {
                try {
                    val zipName = (queryNameAndSize(zipUri).first
                        ?: zipUri.lastPathSegment?.substringAfterLast('/')
                        ?: "").trim()
                    if (!zipName.lowercase().endsWith(".zip")) {
                        throw ZipImportException("ZIP_NOT_ZIP", "The selected file is not a .zip archive.")
                    }
                    val parentId = parentDocumentId(zipUri) ?: throw ZipImportException(
                        "ZIP_PARENT_UNKNOWN",
                        "Android does not say which folder this .zip is in (it was picked from a " +
                                "provider such as Recent or Downloads). Open it from a storage " +
                                "location in the file picker, or move it into a folder, and try again."
                    )
                    val grant = findParentTreeGrant(zipUri, parentId)
                    if (grant != null) {
                        completeZipImport(result, performZipImport(zipUri, zipName, grant, parentId))
                    } else {
                        runOnUiThread {
                            launchParentTreePicker(ZipImportJob(result, zipUri, zipName, parentId))
                        }
                    }
                } catch (e: Exception) {
                    failZipImport(result, e)
                }
            }
        } catch (e: RejectedExecutionException) {
            zipImportRunning = false
            result.error("ZIP_FAILED", "Activity is shutting down.", null)
        }
    }

    private fun launchParentTreePicker(job: ZipImportJob) {
        pendingZipTreeJob = job
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                        Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
            )
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                putExtra(
                    DocumentsContract.EXTRA_INITIAL_URI,
                    DocumentsContract.buildDocumentUri(job.zipUri.authority, job.parentDocId)
                )
            }
        }
        try {
            @Suppress("DEPRECATION")
            startActivityForResult(intent, REQ_PICK_ZIP_PARENT)
        } catch (e: ActivityNotFoundException) {
            pendingZipTreeJob = null
            failZipImport(
                job.result,
                ZipImportException("NO_FOLDER_PICKER", "This device has no folder picker.")
            )
        }
    }

    private fun handleZipParentPicked(resultCode: Int, data: Intent?) {
        val job = pendingZipTreeJob ?: return
        pendingZipTreeJob = null

        val treeUri = data?.data
        if (resultCode != Activity.RESULT_OK || treeUri == null) {
            failZipImport(
                job.result,
                ZipImportException(
                    "ZIP_PARENT_DENIED",
                    "Folder access was not granted, so the .zip was left untouched. Android " +
                            "refuses access to the Download folder itself and to the root of " +
                            "storage: move the .zip into a sub-folder and try again."
                )
            )
            return
        }

        val takeFlags = data.flags and (
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                )
        try {
            contentResolver.takePersistableUriPermission(treeUri, takeFlags)
        } catch (_: SecurityException) {
            // Provider does not allow persistable grants; this import still works.
        }

        if (treeUri.authority != job.zipUri.authority || !treeCoversDocument(treeUri, job.parentDocId)) {
            failZipImport(
                job.result,
                ZipImportException(
                    "ZIP_PARENT_MISMATCH",
                    "That folder does not contain the .zip, so it was left untouched. Choose the " +
                            "folder the .zip is in (or one above it)."
                )
            )
            return
        }

        try {
            ioExecutor.execute {
                try {
                    completeZipImport(
                        job.result,
                        performZipImport(job.zipUri, job.zipName, treeUri, job.parentDocId)
                    )
                } catch (e: Exception) {
                    failZipImport(job.result, e)
                }
            }
        } catch (e: RejectedExecutionException) {
            failZipImport(job.result, ZipImportException("ZIP_FAILED", "Activity is shutting down."))
        }
    }

    /** Document id of the folder that contains [zipUri], or null when the provider hides it. */
    private fun parentDocumentId(zipUri: Uri): String? {
        val docId = try {
            DocumentsContract.getDocumentId(zipUri)
        } catch (_: Exception) {
            return null
        }
        if (zipUri.authority == EXTERNAL_STORAGE_AUTHORITY) {
            // Ids are paths: "primary:Download/Comics/Pack.zip".
            val slash = docId.lastIndexOf('/')
            if (slash > 0) return docId.substring(0, slash)
            val colon = docId.indexOf(':')
            return if (colon >= 0) docId.substring(0, colon + 1) else null
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            try {
                val ids = DocumentsContract.findDocumentPath(contentResolver, zipUri)?.path
                if (ids != null && ids.size >= 2) return ids[ids.size - 2]
            } catch (_: Exception) {
            }
        }
        return null
    }

    private fun treeCoversDocument(treeUri: Uri, docId: String): Boolean {
        val treeId = try {
            DocumentsContract.getTreeDocumentId(treeUri)
        } catch (_: Exception) {
            return false
        }
        if (docId == treeId) return true
        val prefix = if (treeId.endsWith("/") || treeId.endsWith(":")) treeId else "$treeId/"
        return docId.startsWith(prefix)
    }

    /** A persisted read+write tree grant that covers [parentId], or null. */
    private fun findParentTreeGrant(zipUri: Uri, parentId: String): Uri? {
        for (permission in contentResolver.persistedUriPermissions) {
            if (!permission.isReadPermission || !permission.isWritePermission) continue
            val granted = permission.uri
            if (granted.authority != zipUri.authority) continue
            if (granted.pathSegments.firstOrNull() != "tree") continue
            if (treeCoversDocument(granted, parentId)) return granted
        }
        return null
    }

    private fun cleanSegment(segment: String): String =
        sanitizeFileName(segment).trim().ifEmpty { "_" }

    /**
     * Path components of a zip entry, or null for entries to ignore (hidden
     * files/folders, OS metadata). Throws on ".." so a malicious archive
     * (Zip Slip) is refused as a whole instead of being partly extracted.
     */
    private fun safeEntrySegments(rawName: String): List<String>? {
        val parts = rawName.replace('\\', '/').split('/').filter { it.isNotEmpty() && it != "." }
        if (parts.isEmpty()) return null
        if (parts.any { it == ".." }) {
            throw ZipImportException(
                "ZIP_UNSAFE_PATH",
                "The .zip contains an unsafe path (\"..\") and was not imported."
            )
        }
        for (part in parts) {
            val lower = part.lowercase()
            if (lower.startsWith(".") || lower in IGNORED_ZIP_DIRECTORIES) return null
        }
        if (parts.last().lowercase() in IGNORED_ZIP_FILES) return null
        return parts
    }

    private fun openZipStream(zipUri: Uri): ZipInputStream {
        val raw = contentResolver.openInputStream(zipUri)
            ?: throw IOException("Could not open the .zip file.")
        return ZipInputStream(BufferedInputStream(raw, COPY_BUFFER_BYTES), Charsets.UTF_8)
    }

    /** Pass 1: names only (no disk writes). Counts nested archives and pages per folder. */
    private fun scanZip(zipUri: Uri): ZipScan {
        var archives = 0
        val folders = LinkedHashMap<String, Int>()
        openZipStream(zipUri).use { zin ->
            while (true) {
                val entry = zin.nextEntry ?: break
                if (entry.isDirectory) continue
                val segments = safeEntrySegments(entry.name) ?: continue
                val extension = segments.last().substringAfterLast('.', "").lowercase()
                if (extension in COMIC_EXTENSIONS) {
                    archives++
                } else if (extension in PAGE_IMAGE_EXTENSIONS) {
                    val key = segments.dropLast(1).joinToString("/")
                    folders[key] = (folders[key] ?: 0) + 1
                }
            }
        }
        return ZipScan(archives, folders)
    }

    private fun performZipImport(
        zipUri: Uri,
        zipName: String,
        treeUri: Uri,
        parentId: String
    ): Map<String, Any> {
        val rawBase = zipName.substring(0, zipName.length - 4).trim().ifEmpty { "Comic" }
        val folderBase = cleanSegment(rawBase)

        fun reply(files: List<Map<String, Any>>, zipDeleted: Boolean): Map<String, Any> = mapOf(
            "treeUri" to treeUri.toString(),
            "folderName" to rawBase,
            "files" to files,
            "zipDeleted" to zipDeleted
        )

        val scan = scanZip(zipUri)
        if (scan.archiveCount == 0 && scan.imageCounts.isEmpty()) {
            return reply(emptyList(), false) // nothing created, .zip untouched
        }

        val parentUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, parentId)
        val destName = uniqueChildName(treeUri, parentId, folderBase)
        val destUri = createChild(treeUri, parentUri, DocumentsContract.Document.MIME_TYPE_DIR, destName)

        val files = ArrayList<Map<String, Any>>()
        var succeeded = false
        try {
            if (scan.archiveCount > 0) {
                extractNestedArchives(zipUri, treeUri, destUri, files)
            } else {
                packImageFolders(zipUri, treeUri, destUri, folderBase, scan, files)
            }
            if (files.isEmpty()) return reply(emptyList(), false)
            succeeded = true
        } finally {
            // Failure or nothing usable: remove the partial folder, keep the .zip.
            if (!succeeded) deleteQuietly(destUri)
        }

        // Only now, with at least one comic safely on disk, is the .zip removed.
        return reply(files, deleteOriginalZip(zipUri, treeUri))
    }

    private fun uniqueChildName(treeUri: Uri, parentId: String, wanted: String): String {
        val existing = HashSet<String>()
        contentResolver.query(
            DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, parentId),
            arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME),
            null,
            null,
            null
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                cursor.getString(0)?.let { existing.add(it.lowercase()) }
            }
        }
        var candidate = wanted
        var n = 1
        while (candidate.lowercase() in existing) {
            candidate = "$wanted ($n)"
            n++
        }
        return candidate
    }

    /** Creates a child document and returns its tree-based URI (usable through the tree grant). */
    private fun createChild(treeUri: Uri, parentUri: Uri, mime: String, name: String): Uri {
        val created = DocumentsContract.createDocument(contentResolver, parentUri, mime, name)
            ?: throw IOException("Could not create \"$name\".")
        return DocumentsContract.buildDocumentUriUsingTree(
            treeUri,
            DocumentsContract.getDocumentId(created)
        )
    }

    private fun ensureFolder(treeUri: Uri, cache: HashMap<String, Uri>, parts: List<String>): Uri {
        var key = ""
        var current = cache[""]!!
        for (part in parts) {
            key = if (key.isEmpty()) part else "$key/$part"
            val cached = cache[key]
            current = if (cached != null) {
                cached
            } else {
                createChild(treeUri, current, DocumentsContract.Document.MIME_TYPE_DIR, part)
                    .also { cache[key] = it }
            }
        }
        return current
    }

    private fun fileEntry(
        uri: Uri,
        requestedName: String,
        folderParts: List<String>,
        knownSize: Long?
    ): Map<String, Any> {
        val (reportedName, reportedSize) = queryNameAndSize(uri)
        val name = reportedName ?: requestedName
        return mapOf(
            "uri" to uri.toString(),
            "name" to name,
            "fileName" to sanitizeFileName(name),
            "path" to (folderParts + name).joinToString("/"),
            "size" to (knownSize ?: reportedSize)
        )
    }

    /** Case A: copy every nested comic archive, keeping its relative path. */
    private fun extractNestedArchives(
        zipUri: Uri,
        treeUri: Uri,
        destUri: Uri,
        files: MutableList<Map<String, Any>>
    ) {
        val folders = HashMap<String, Uri>()
        folders[""] = destUri
        val buffer = ByteArray(COPY_BUFFER_BYTES)

        openZipStream(zipUri).use { zin ->
            while (true) {
                val entry = zin.nextEntry ?: break
                if (entry.isDirectory) continue
                val segments = safeEntrySegments(entry.name) ?: continue
                val fileName = cleanSegment(segments.last())
                if (fileName.substringAfterLast('.', "").lowercase() !in COMIC_EXTENSIONS) continue

                val folderParts = segments.dropLast(1).map { cleanSegment(it) }
                val parentUri = ensureFolder(treeUri, folders, folderParts)
                val fileUri = createChild(treeUri, parentUri, ZIP_ENTRY_MIME, fileName)

                var written = 0L
                val out = contentResolver.openOutputStream(fileUri, "w")
                    ?: throw IOException("Could not write \"$fileName\".")
                out.use {
                    while (true) {
                        val n = zin.read(buffer)
                        if (n < 0) break
                        it.write(buffer, 0, n)
                        written += n
                    }
                }
                files.add(fileEntry(fileUri, fileName, folderParts, written))
            }
        }
    }

    /** Case B: one stored .cbz per image folder (root images -> "<ZipName>.cbz"). */
    private fun packImageFolders(
        zipUri: Uri,
        treeUri: Uri,
        destUri: Uri,
        baseName: String,
        scan: ZipScan,
        files: MutableList<Map<String, Any>>
    ) {
        val cbzNames = chooseCbzNames(scan.imageCounts.keys, baseName)
        val open = HashMap<String, OpenCbz>()
        val buffer = ByteArray(COPY_BUFFER_BYTES)

        try {
            openZipStream(zipUri).use { zin ->
                while (true) {
                    val entry = zin.nextEntry ?: break
                    if (entry.isDirectory) continue
                    val segments = safeEntrySegments(entry.name) ?: continue
                    val leaf = segments.last()
                    if (leaf.substringAfterLast('.', "").lowercase() !in PAGE_IMAGE_EXTENSIONS) continue

                    val key = segments.dropLast(1).joinToString("/")
                    var cbz = open[key]
                    if (cbz == null) {
                        val cbzName = (cbzNames[key] ?: throw IllegalStateException("Unexpected image folder.")) + ".cbz"
                        val uri = createChild(treeUri, destUri, ZIP_ENTRY_MIME, cbzName)
                        val out = contentResolver.openOutputStream(uri, "w")
                            ?: throw IOException("Could not write \"$cbzName\".")
                        val zout = ZipOutputStream(BufferedOutputStream(out, COPY_BUFFER_BYTES))
                        zout.setLevel(Deflater.NO_COMPRESSION)
                        cbz = OpenCbz(uri, cbzName, zout, scan.imageCounts[key] ?: 1)
                        open[key] = cbz
                    }

                    writePage(cbz, leaf, zin, buffer)
                    cbz.remaining--
                    if (cbz.remaining <= 0) {
                        finishCbz(cbz, files)
                        open.remove(key)
                    }
                }
            }
            for (cbz in open.values.toList()) finishCbz(cbz, files)
            open.clear()
        } finally {
            for (cbz in open.values) {
                try {
                    cbz.output.close()
                } catch (_: Exception) {
                }
            }
        }
    }

    private fun finishCbz(cbz: OpenCbz, files: MutableList<Map<String, Any>>) {
        cbz.output.close()
        files.add(fileEntry(cbz.uri, cbz.requestedName, emptyList(), null))
    }

    /** Writes one page into [cbz] as a STORED entry (falls back to level-0 deflate for huge pages). */
    private fun writePage(cbz: OpenCbz, leafName: String, zin: ZipInputStream, buffer: ByteArray) {
        val clean = cleanSegment(leafName)
        var name = clean
        var n = 1
        while (!cbz.usedNames.add(name.lowercase())) {
            val dot = clean.lastIndexOf('.')
            name = if (dot > 0) {
                "${clean.substring(0, dot)} ($n)${clean.substring(dot)}"
            } else {
                "$clean ($n)"
            }
            n++
        }

        val held = ByteArrayOutputStream()
        var overflow = false
        while (true) {
            val read = zin.read(buffer)
            if (read < 0) break
            held.write(buffer, 0, read)
            if (held.size() > MAX_STORED_ENTRY_BYTES) {
                overflow = true
                break
            }
        }

        val zout = cbz.output
        if (!overflow) {
            val bytes = held.toByteArray()
            held.reset()
            val checksum = CRC32().apply { update(bytes, 0, bytes.size) }
            val stored = ZipEntry(name).apply {
                method = ZipEntry.STORED
                size = bytes.size.toLong()
                compressedSize = bytes.size.toLong()
                crc = checksum.value
            }
            zout.putNextEntry(stored)
            zout.write(bytes)
            zout.closeEntry()
        } else {
            zout.putNextEntry(ZipEntry(name).apply { method = ZipEntry.DEFLATED })
            held.writeTo(zout)
            held.reset()
            while (true) {
                val read = zin.read(buffer)
                if (read < 0) break
                zout.write(buffer, 0, read)
            }
            zout.closeEntry()
        }
    }

    /** Leaf folder name per image folder; clashes fall back to the full folder path. */
    private fun chooseCbzNames(keys: Collection<String>, baseName: String): Map<String, String> {
        fun leaf(key: String) = cleanSegment(if (key.isEmpty()) baseName else key.substringAfterLast('/'))

        val leafUse = HashMap<String, Int>()
        for (key in keys) {
            val lower = leaf(key).lowercase()
            leafUse[lower] = (leafUse[lower] ?: 0) + 1
        }
        val used = HashSet<String>()
        val names = LinkedHashMap<String, String>()
        for (key in keys) {
            var candidate = leaf(key)
            if (key.isNotEmpty() && (leafUse[candidate.lowercase()] ?: 0) > 1) {
                candidate = cleanSegment(key.replace("/", " - "))
            }
            var unique = candidate
            var n = 1
            while (!used.add(unique.lowercase())) {
                unique = "$candidate ($n)"
                n++
            }
            names[key] = unique
        }
        return names
    }

    private fun deleteQuietly(uri: Uri) {
        try {
            DocumentsContract.deleteDocument(contentResolver, uri)
        } catch (_: Exception) {
        }
    }

    /** Deletes the picked .zip: through its own grant first, then through the tree grant. */
    private fun deleteOriginalZip(zipUri: Uri, treeUri: Uri): Boolean {
        if (deleteDocumentUri(zipUri)) return true
        return try {
            val viaTree = DocumentsContract.buildDocumentUriUsingTree(
                treeUri,
                DocumentsContract.getDocumentId(zipUri)
            )
            DocumentsContract.deleteDocument(contentResolver, viaTree)
        } catch (_: Exception) {
            false
        }
    }
}