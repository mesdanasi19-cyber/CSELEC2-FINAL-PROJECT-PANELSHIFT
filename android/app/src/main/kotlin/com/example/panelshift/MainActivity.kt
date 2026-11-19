package com.example.panelshift // <-- Keep your existing package name here

import android.app.Activity
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
    }

    private var pendingPickResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickComic" -> {
                        if (pendingPickResult != null) {
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
        if (requestCode != REQ_PICK_COMIC) return

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
                val rawName = resolveDisplayName(uri)
                    ?: "comic_${System.currentTimeMillis()}.cbz"
                val safeName = rawName.replace(Regex("[\\\\/:*?\"<>|]"), "_")
                val pickerDir = File(cacheDir, "file_picker").apply { mkdirs() }
                val outFile = File(pickerDir, safeName)

                contentResolver.openInputStream(uri)?.use { input ->
                    FileOutputStream(outFile).use { output ->
                        input.copyTo(output)
                    }
                } ?: throw IllegalStateException("Could not open input stream for $uri")

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

        if (deleted) {
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