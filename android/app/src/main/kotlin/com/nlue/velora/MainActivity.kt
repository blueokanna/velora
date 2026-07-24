package com.nlue.velora

import android.app.Activity
import android.os.Bundle
import android.content.ContentResolver
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import java.io.File
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
	private val channelName = "velora/document_file"
	private val readerLayoutChannelName = "velora/reader_layout"
	private val openDocumentRequest = 61026
	private val maxDocumentBytes = 512L * 1024L * 1024L
	private val ioExecutor = Executors.newSingleThreadExecutor()
	private var pendingOpenResult: MethodChannel.Result? = null
	private var pendingIncomingDocument: Map<String, Any?>? = null
	internal var debugReaderLayoutMessenger: DebugBinaryMessenger? = null
		private set

	override fun onCreate(savedInstanceState: Bundle?) {
		super.onCreate(savedInstanceState)
		captureIncomingDocument(intent)
	}

	override fun onNewIntent(intent: Intent) {
		super.onNewIntent(intent)
		setIntent(intent)
		captureIncomingDocument(intent)
	}

	override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
		super.configureFlutterEngine(flutterEngine)
		val debugMessenger = DebugBinaryMessenger(flutterEngine.dartExecutor.binaryMessenger)
		debugReaderLayoutMessenger = debugMessenger
		flutterEngine.platformViewsController.registry.registerViewFactory("velora/reader_page", ReaderPageViewFactory())
		MethodChannel(debugMessenger, channelName).setMethodCallHandler { call, result ->
			when (call.method) {
				"openBookDocument" -> openBookDocument(result)
				"openTxtDocument" -> openBookDocument(result)
				"consumePendingOpenDocument" -> result.success(consumePendingOpenDocument())
				"importDocument" -> importDocument(call.argument<String>("uri"), result)
				"describeDocument" -> describeDocument(call.argument<String>("uri"), result)
				"readBytes" -> readBytes(call.argument<String>("uri"), result)
				else -> result.notImplemented()
			}
		}
		MethodChannel(debugMessenger, readerLayoutChannelName).setMethodCallHandler { call, result ->
			when (call.method) {
				"drainStaticLayoutStats" -> result.success(ReaderPageViewFactory.drainStats())
				"prebindStaticLayoutPages" -> {
					try {
						val args = call.arguments as? Map<String, Any?> ?: emptyMap()
						@Suppress("UNCHECKED_CAST")
						val pages = args["pages"] as? List<Map<String, Any?>> ?: emptyList()
						ReaderPageViewFactory.prebind(this, pages)
						result.success(null)
					} catch (e: Exception) {
						result.error("prebind_failed", "StaticLayout 预绑定失败", e.message)
					}
				}
				"paginateStaticLayout" -> {
					try {
						val args = call.arguments as? Map<String, Any?> ?: emptyMap()
						result.success(ReaderStaticLayoutPager.paginate(this, args))
					} catch (e: Exception) {
						result.error("paginate_failed", "StaticLayout 分页失败", e.message)
					}
				}
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
			putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("text/plain", "text/*", "text/markdown", "application/epub+zip", "application/x-mobipocket-ebook", "application/vnd.amazon.ebook", "application/vnd.comicbook+zip", "application/zip", "audio/*", "application/octet-stream"))
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
		if (!isSupportedUri(uri)) {
			result.error("invalid_uri", "只允许读取 content URI", null)
			return
		}
		val size = querySize(uri)
		if (size > 0 && size > maxDocumentBytes) {
			result.error("file_too_large", "文档超过 512MB", null)
			return
		}
		try {
			openInputStream(uri).use { input ->
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
					if (total > maxDocumentBytes) {
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
		if (!isSupportedUri(uri)) {
			result.error("invalid_uri", "只允许读取 content URI", null)
			return
		}
		result.success(documentMap(uri))
	}

	private fun importDocument(uriText: String?, result: MethodChannel.Result) {
		if (uriText.isNullOrBlank()) {
			result.error("invalid_uri", "文档 URI 为空", null)
			return
		}
		val uri = Uri.parse(uriText)
		if (!isSupportedUri(uri)) {
			result.error("invalid_uri", "只允许读取 content 或 file URI", null)
			return
		}
		ioExecutor.execute {
			try {
				val map = importDocumentBlocking(uri)
				result.success(map)
			} catch (e: SecurityException) {
				result.error("permission_denied", "没有文档读取权限", e.message)
			} catch (e: Exception) {
				result.error("import_failed", "导入文档失败", e.message)
			}
		}
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

	private fun importedDocumentMap(originalUri: Uri, file: File, originalName: String, originalModified: Long): Map<String, Any?> {
		return mapOf(
			"uri" to originalUri.toString(),
			"name" to originalName,
			"size" to file.length(),
			"lastModified" to if (originalModified > 0) originalModified else file.lastModified(),
			"localPath" to file.absolutePath,
		)
	}

	private fun importDocumentBlocking(uri: Uri): Map<String, Any?> {
		val name = queryName(uri)
		val size = querySize(uri)
		if (size > 0 && size > maxDocumentBytes) {
			throw IllegalStateException("文档超过 512MB")
		}
		val modified = queryLastModified(uri)
		val target = importedFileFor(uri, name, size, modified)
		if (target.exists() && size > 0 && target.length() == size) {
			return importedDocumentMap(uri, target, name, modified)
		}
		val temp = File(target.parentFile, "${target.name}.tmp")
		openInputStream(uri).use { input ->
			if (input == null) {
				throw IllegalStateException("无法打开文档")
			}
			temp.outputStream().use { output ->
				val buffer = ByteArray(256 * 1024)
				var total = 0L
				while (true) {
					val read = input.read(buffer)
					if (read < 0) break
					total += read.toLong()
					if (total > maxDocumentBytes) {
						temp.delete()
						throw IllegalStateException("文档超过 512MB")
					}
					output.write(buffer, 0, read)
				}
			}
		}
		if (target.exists()) {
			target.delete()
		}
		if (!temp.renameTo(target)) {
			temp.copyTo(target, overwrite = true)
			temp.delete()
		}
		if (modified > 0) {
			target.setLastModified(modified)
		}
		return importedDocumentMap(uri, target, name, modified)
	}

	private fun importedFileFor(uri: Uri, name: String, size: Long, modified: Long): File {
		val dir = File(filesDir, "books")
		dir.mkdirs()
		val cleanName = sanitizeFileName(name.ifBlank { "book.txt" })
		val dot = cleanName.lastIndexOf('.')
		val extension = if (dot >= 0 && dot < cleanName.length - 1) cleanName.substring(dot) else ".book"
		val hash = sha256("${uri}|${name}|${size}|${modified}").take(20)
		val cacheDir = File(dir, hash)
		cacheDir.mkdirs()
		val fileName = if (dot >= 0 && dot < cleanName.length - 1) {
			cleanName
		} else {
			"$cleanName${extension.lowercase()}"
		}
		return File(cacheDir, fileName)
	}

	private fun sanitizeFileName(name: String): String {
		val clean = name.replace(Regex("[\\\\/:*?\"<>|]"), "_").trim().trim('.')
		return clean.ifBlank { "book.txt" }
	}

	private fun sha256(text: String): String {
		val digest = MessageDigest.getInstance("SHA-256").digest(text.toByteArray(Charsets.UTF_8))
		return digest.joinToString("") { "%02x".format(it) }
	}

	private fun captureIncomingDocument(intent: Intent?) {
		val document = documentFromIntent(intent) ?: return
		pendingIncomingDocument = document
	}

	private fun consumePendingOpenDocument(): Map<String, Any?>? {
		val next = pendingIncomingDocument
		pendingIncomingDocument = null
		return next
	}

	private fun documentFromIntent(intent: Intent?): Map<String, Any?>? {
		if (intent == null) return null
		val uri = when (intent.action) {
			Intent.ACTION_VIEW -> intent.data
			Intent.ACTION_SEND -> intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
			else -> null
		} ?: return null
		if (!isSupportedUri(uri)) {
			return null
		}
		val flags = intent.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
		if (uri.scheme == ContentResolver.SCHEME_CONTENT) {
			try {
				contentResolver.takePersistableUriPermission(uri, flags and Intent.FLAG_GRANT_READ_URI_PERMISSION)
			} catch (_: Exception) {
			}
		}
		return documentMap(uri)
	}

	private fun isSupportedUri(uri: Uri): Boolean {
		return uri.scheme == ContentResolver.SCHEME_CONTENT || uri.scheme == ContentResolver.SCHEME_FILE
	}

	private fun openInputStream(uri: Uri) = when (uri.scheme) {
		ContentResolver.SCHEME_CONTENT -> contentResolver.openInputStream(uri)
		ContentResolver.SCHEME_FILE -> {
			val path = uri.path ?: return null
			File(path).inputStream()
		}
		else -> null
	}

	private fun queryName(uri: Uri): String {
		if (uri.scheme == ContentResolver.SCHEME_FILE) {
			val path = uri.path
			if (!path.isNullOrBlank()) {
				val file = File(path)
				if (file.name.isNotBlank()) {
					return file.name
				}
			}
		}
		return queryOpenable(uri) { cursor ->
			val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
			if (index >= 0) cursor.getString(index) else null
		} ?: uri.lastPathSegment ?: "未命名"
	}

	private fun querySize(uri: Uri): Long {
		if (uri.scheme == ContentResolver.SCHEME_FILE) {
			val path = uri.path ?: return -1L
			val file = File(path)
			return if (file.exists()) file.length() else -1L
		}
		return queryOpenable(uri) { cursor ->
			val index = cursor.getColumnIndex(OpenableColumns.SIZE)
			if (index >= 0 && !cursor.isNull(index)) cursor.getLong(index) else null
		} ?: -1L
	}

	private fun queryLastModified(uri: Uri): Long {
		if (uri.scheme == ContentResolver.SCHEME_FILE) {
			val path = uri.path ?: return -1L
			val file = File(path)
			return if (file.exists()) file.lastModified() else -1L
		}
		return queryOpenable(uri) { cursor ->
			val index = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_LAST_MODIFIED)
			if (index >= 0 && !cursor.isNull(index)) cursor.getLong(index) else null
		} ?: -1L
	}

	private fun <T> queryOpenable(uri: Uri, read: (Cursor) -> T?): T? {
		if (uri.scheme != ContentResolver.SCHEME_CONTENT) {
			return null
		}
		contentResolver.query(uri, null, null, null, null).use { cursor ->
			if (cursor != null && cursor.moveToFirst()) {
				return read(cursor)
			}
		}
		return null
	}
}

internal class DebugBinaryMessenger(
	private val delegate: BinaryMessenger,
) : BinaryMessenger {
	private val handlers = ConcurrentHashMap<String, BinaryMessenger.BinaryMessageHandler>()

	override fun send(channel: String, message: ByteBuffer?) {
		delegate.send(channel, message)
	}

	override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {
		delegate.send(channel, message, callback)
	}

	override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {
		if (handler == null) {
			handlers.remove(channel)
		} else {
			handlers[channel] = handler
		}
		delegate.setMessageHandler(channel, handler)
	}

	override fun setMessageHandler(
		channel: String,
		handler: BinaryMessenger.BinaryMessageHandler?,
		taskQueue: BinaryMessenger.TaskQueue?,
	) {
		if (handler == null) {
			handlers.remove(channel)
		} else {
			handlers[channel] = handler
		}
		if (taskQueue == null) {
			delegate.setMessageHandler(channel, handler)
		} else {
			delegate.setMessageHandler(channel, handler, taskQueue)
		}
	}

	override fun makeBackgroundTaskQueue(): BinaryMessenger.TaskQueue {
		return delegate.makeBackgroundTaskQueue()
	}

	override fun makeBackgroundTaskQueue(options: BinaryMessenger.TaskQueueOptions): BinaryMessenger.TaskQueue {
		return delegate.makeBackgroundTaskQueue(options)
	}

	fun invokeInboundMethodCall(
		channel: String,
		method: String,
		arguments: Any?,
		callback: (Any?, Throwable?) -> Unit,
	) {
		val handler = handlers[channel]
		if (handler == null) {
			callback(null, IllegalStateException("No MethodChannel handler registered for $channel"))
			return
		}
		val message = StandardMethodCodec.INSTANCE.encodeMethodCall(MethodCall(method, arguments))
		message.position(0)
		handler.onMessage(message) { reply ->
			if (reply == null) {
				callback(null, IllegalStateException("$channel.$method was not implemented"))
				return@onMessage
			}
			try {
				reply.position(0)
				callback(StandardMethodCodec.INSTANCE.decodeEnvelope(reply), null)
			} catch (error: Throwable) {
				callback(null, error)
			}
		}
	}
}
