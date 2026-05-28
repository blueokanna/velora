package com.example.velora

import android.app.Activity
import android.content.ContentResolver
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

class MainActivity : FlutterActivity() {
	private val channelName = "velora/document_file"
	private val openDocumentRequest = 61026
	private var pendingOpenResult: MethodChannel.Result? = null

	override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
		super.configureFlutterEngine(flutterEngine)
		MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
			when (call.method) {
				"openBookDocument" -> openBookDocument(result)
				"openTxtDocument" -> openBookDocument(result)
				"describeDocument" -> describeDocument(call.argument<String>("uri"), result)
				"readBytes" -> readBytes(call.argument<String>("uri"), result)
				else -> result.notImplemented()
			}
		}
	}

	private fun openBookDocument(result: MethodChannel.Result) {
		if (pendingOpenResult != null) {
			result.error("busy", "已有文档选择正在进行", null)
			return
		}
		pendingOpenResult = result
		val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
			addCategory(Intent.CATEGORY_OPENABLE)
			type = "*/*"
			putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("text/plain", "text/*", "application/epub+zip", "application/x-mobipocket-ebook", "application/vnd.amazon.ebook", "application/octet-stream"))
			addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
		}
		startActivityForResult(intent, openDocumentRequest)
	}

	private fun readBytes(uriText: String?, result: MethodChannel.Result) {
		if (uriText.isNullOrBlank()) {
			result.error("invalid_uri", "文档 URI 为空", null)
			return
		}
		val uri = Uri.parse(uriText)
		if (uri.scheme != ContentResolver.SCHEME_CONTENT) {
			result.error("invalid_uri", "只允许读取 content URI", null)
			return
		}
		val size = querySize(uri)
		if (size > 0 && size > 512L * 1024L * 1024L) {
			result.error("file_too_large", "文档超过 512MB", null)
			return
		}
		try {
			contentResolver.openInputStream(uri).use { input ->
				if (input == null) {
					result.error("open_failed", "无法打开文档", null)
					return
				}
				val out = ByteArrayOutputStream(if (size > 0 && size < Int.MAX_VALUE) size.toInt() else 64 * 1024)
				val buffer = ByteArray(64 * 1024)
				var total = 0L
				while (true) {
					val read = input.read(buffer)
					if (read < 0) break
					total += read.toLong()
					if (total > 512L * 1024L * 1024L) {
						result.error("file_too_large", "文档超过 512MB", null)
						return
					}
					out.write(buffer, 0, read)
				}
				result.success(out.toByteArray())
			}
		} catch (e: SecurityException) {
			result.error("permission_denied", "没有文档读取权限", e.message)
		} catch (e: Exception) {
			result.error("read_failed", "读取文档失败", e.message)
		}
	}

	private fun describeDocument(uriText: String?, result: MethodChannel.Result) {
		if (uriText.isNullOrBlank()) {
			result.error("invalid_uri", "文档 URI 为空", null)
			return
		}
		val uri = Uri.parse(uriText)
		if (uri.scheme != ContentResolver.SCHEME_CONTENT) {
			result.error("invalid_uri", "只允许读取 content URI", null)
			return
		}
		result.success(documentMap(uri))
	}

	override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
		if (requestCode != openDocumentRequest) {
			super.onActivityResult(requestCode, resultCode, data)
			return
		}
		val result = pendingOpenResult
		pendingOpenResult = null
		if (result == null) return
		if (resultCode != Activity.RESULT_OK || data?.data == null) {
			result.success(null)
			return
		}
		val uri = data.data!!
		val flags = data.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
		try {
			contentResolver.takePersistableUriPermission(uri, flags and Intent.FLAG_GRANT_READ_URI_PERMISSION)
		} catch (_: Exception) {
		}
		result.success(documentMap(uri))
	}

	private fun documentMap(uri: Uri): Map<String, Any?> {
		return mapOf(
			"uri" to uri.toString(),
			"name" to queryName(uri),
			"size" to querySize(uri),
			"lastModified" to queryLastModified(uri),
		)
	}

	private fun queryName(uri: Uri): String {
		return queryOpenable(uri) { cursor ->
			val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
			if (index >= 0) cursor.getString(index) else null
		} ?: uri.lastPathSegment ?: "未命名"
	}

	private fun querySize(uri: Uri): Long {
		return queryOpenable(uri) { cursor ->
			val index = cursor.getColumnIndex(OpenableColumns.SIZE)
			if (index >= 0 && !cursor.isNull(index)) cursor.getLong(index) else null
		} ?: -1L
	}

	private fun queryLastModified(uri: Uri): Long {
		return queryOpenable(uri) { cursor ->
			val index = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_LAST_MODIFIED)
			if (index >= 0 && !cursor.isNull(index)) cursor.getLong(index) else null
		} ?: -1L
	}

	private fun <T> queryOpenable(uri: Uri, read: (Cursor) -> T?): T? {
		contentResolver.query(uri, null, null, null, null).use { cursor ->
			if (cursor != null && cursor.moveToFirst()) {
				return read(cursor)
			}
		}
		return null
	}
}
