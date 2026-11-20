package com.example.panelshift // <-- Keep your existing package name here

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "panelshift/saf_picker"
        private const val REQ_PICK_COMIC = 4109
        private const val REQ_PICK_FOLDER = 4110

        // Folder import: how deep sub-folders are scanned, and the copy buffer
        // used when streaming one document into cache/file_picker/.
        private const val MAX_SCAN_DEPTH = 8
        private const val COPY_BUFFER_BYTES = 64 * 1024

        private val COMIC_EXTENSIONS = setOf("cbz", "zip", "cbr", "rar")
        private val UNSAFE_NAME_CHARS = Regex("[\\\\/:*?\"<>|]")
    }

    private var pendingPickResult: MethodChannel.Result? = null
    private var pendingFolderResult: MethodChannel.Result? = null
    private var pendingFolderRecursive: Boolean = true

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

                    // Folder import, step 2: stream ONE document into
                    // cache/file_picker/ (same place pickComic uses), so Dart
                    // can hand it to _persistPickedFile exactly like a single
                    // picked file. Dart calls this once per comic.
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

                    "deleteUri" -> {
                        val uriString = call.argument<String>("uri")
                        if (uriString.isNullOrBlank()) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        result.success(deleteDocumentUri(Uri.parse(uriString)))
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

        // Persist read/write access so "Delete all read" can delete this URI later.
        val takeFlags = data.flags and (
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                )
        try {
            contentResolver.takePersistableUriPermission(uri, takeFlags)
        } catch (_: SecurityException) {
            // Provider does not allow persistable grants; copy still succeeds.
        }

        // Copy stream off the UI thread into cache/file_picker/ so _persistPickedFile
        // handles it identically to file_picker.
        Thread {
            try {
                val outFile = copyUriToPickerCache(uri, resolveDisplayName(uri))

                runOnUiThread {
                    callback.success(
                        mapOf(
                            "tempPath" to outFile.absolutePath,
                            "uri" to uri.toString()
                        )
                    )
                }
            } catch (e: Exception) {
                runOnUiThread {
                    callback.error("PICK_FAILED", e.message, null)
                }
            }
        }.start()
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
                runOnUiThread {
                    callback.success(
                        mapOf(
                            "treeUri" to treeUri.toString(),
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

    private fun resolveDisplayName(uri: Uri): String? {
        contentResolver.query(
            uri,
            arrayOf(OpenableColumns.DISPLAY_NAME),
            null,
            null,
            null
        )?.use { cursor ->
            if (cursor.moveToFirst()) {
                val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (idx >= 0) return cursor.getString(idx)
            }
        }
        return null
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
}

