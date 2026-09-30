package com.jianyue.mdreader

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var pending: MethodChannel.Result? = null
    private val folderRequest = 4101
    private val fileRequest = 4102

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "md_reader/documents")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "pickFolder" -> pick(Intent.ACTION_OPEN_DOCUMENT_TREE, folderRequest, result)
                        "pickFile" -> pick(Intent.ACTION_OPEN_DOCUMENT, fileRequest, result)
                        "savedFolder" -> result.success(getPreferences(MODE_PRIVATE).getString("folder", null))
                        "savedFile" -> result.success(getPreferences(MODE_PRIVATE).getString("file", null))
                        "fileName" -> {
                            val uri = Uri.parse(call.argument<String>("uri")!!)
                            contentResolver.query(uri, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)
                                ?.use { cursor -> result.success(if (cursor.moveToFirst()) cursor.getString(0) else null) }
                                ?: result.success(null)
                        }
                        "listFolder" -> result.success(listFolder(Uri.parse(call.argument<String>("uri")!!)))
                        "readFile" -> result.success(
                            contentResolver.openInputStream(Uri.parse(call.argument<String>("uri")!!))
                                ?.use { it.readBytes() }
                        )
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("DOCUMENT_ERROR", e.message, null)
                }
            }
    }

    private fun pick(action: String, requestCode: Int, result: MethodChannel.Result) {
        if (pending != null) {
            result.error("BUSY", "A picker is already open", null)
            return
        }
        pending = result
        val intent = Intent(action).apply {
            if (action == Intent.ACTION_OPEN_DOCUMENT) {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "*/*"
            }
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }
        startActivityForResult(intent, requestCode)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != folderRequest && requestCode != fileRequest) return
        val result = pending ?: return
        pending = null
        val uri = if (resultCode == Activity.RESULT_OK) data?.data else null
        if (uri == null) {
            result.success(null)
            return
        }
        try {
            contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            if (requestCode == folderRequest) {
                getPreferences(MODE_PRIVATE).edit().putString("folder", uri.toString()).remove("file").apply()
            } else {
                getPreferences(MODE_PRIVATE).edit().putString("file", uri.toString()).remove("folder").apply()
            }
            result.success(uri.toString())
        } catch (e: Exception) {
            result.error("DOCUMENT_ERROR", e.message, null)
        }
    }

    private fun listFolder(tree: Uri): List<Map<String, String>> {
        val result = mutableListOf<Map<String, String>>()
        val rootId = DocumentsContract.getTreeDocumentId(tree)
        fun visit(parentId: String, prefix: String, depth: Int) {
            if (depth > 12 || result.size >= 3000) return
            val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, parentId)
            val projection = arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE
            )
            contentResolver.query(children, projection, null, null, null)?.use { cursor ->
                while (cursor.moveToNext() && result.size < 3000) {
                    val id = cursor.getString(0)
                    val name = cursor.getString(1) ?: continue
                    val mime = cursor.getString(2) ?: ""
                    val path = if (prefix.isEmpty()) name else "$prefix/$name"
                    if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                        visit(id, path, depth + 1)
                    } else {
                        result.add(mapOf(
                            "name" to name,
                            "path" to path,
                            "uri" to DocumentsContract.buildDocumentUriUsingTree(tree, id).toString(),
                            "mime" to mime
                        ))
                    }
                }
            }
        }
        visit(rootId, "", 0)
        return result
    }
}
