package com.nlue.velora

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Typeface
import android.text.Layout
import android.text.StaticLayout
import android.text.TextDirectionHeuristics
import android.text.TextPaint
import android.util.LruCache
import android.view.View
import android.view.ViewGroup
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.util.ArrayDeque
import java.util.LinkedHashMap
import kotlin.math.max
import kotlin.math.roundToInt

data class ReaderBindResult(
	val bindMicros: Long,
	val layoutMicros: Long,
)

private object ReaderPageNativeStats {
	private var bindSampleCount = 0
	private var bindTotalMicros = 0L
	private var bindMaxMicros = 0L
	private var layoutSampleCount = 0
	private var layoutTotalMicros = 0L
	private var layoutMaxMicros = 0L
	private var prebindRequestCount = 0
	private var prebindHitCount = 0
	private var visiblePreboundBindSampleCount = 0
	private var visiblePreboundBindTotalMicros = 0L
	private var visiblePreboundBindMaxMicros = 0L
	private var visiblePreboundLayoutSampleCount = 0
	private var visiblePreboundLayoutTotalMicros = 0L
	private var visiblePreboundLayoutMaxMicros = 0L
	private var backgroundPrebindBindSampleCount = 0
	private var backgroundPrebindBindTotalMicros = 0L
	private var backgroundPrebindBindMaxMicros = 0L
	private var backgroundPrebindLayoutSampleCount = 0
	private var backgroundPrebindLayoutTotalMicros = 0L
	private var backgroundPrebindLayoutMaxMicros = 0L

	fun recordVisibleBind(bindMicros: Long, layoutMicros: Long, preboundHit: Boolean) {
		synchronized(this) {
			bindSampleCount += 1
			bindTotalMicros += bindMicros.coerceAtLeast(0)
			bindMaxMicros = max(bindMaxMicros, bindMicros)
			if (layoutMicros > 0) {
				layoutSampleCount += 1
				layoutTotalMicros += layoutMicros
				layoutMaxMicros = max(layoutMaxMicros, layoutMicros)
			}
			if (preboundHit) {
				prebindHitCount += 1
				visiblePreboundBindSampleCount += 1
				visiblePreboundBindTotalMicros += bindMicros.coerceAtLeast(0)
				visiblePreboundBindMaxMicros = max(visiblePreboundBindMaxMicros, bindMicros)
				if (layoutMicros > 0) {
					visiblePreboundLayoutSampleCount += 1
					visiblePreboundLayoutTotalMicros += layoutMicros
					visiblePreboundLayoutMaxMicros = max(visiblePreboundLayoutMaxMicros, layoutMicros)
				}
			}
		}
	}

	fun recordVisibleLayout(layoutMicros: Long) {
		if (layoutMicros <= 0) {
			return
		}
		synchronized(this) {
			layoutSampleCount += 1
			layoutTotalMicros += layoutMicros
			layoutMaxMicros = max(layoutMaxMicros, layoutMicros)
		}
	}

	fun recordPrebindRequests(requestCount: Int) {
		if (requestCount <= 0) {
			return
		}
		synchronized(this) {
			prebindRequestCount += requestCount
		}
	}

	fun recordBackgroundPrebind(bindMicros: Long, layoutMicros: Long) {
		synchronized(this) {
			backgroundPrebindBindSampleCount += 1
			backgroundPrebindBindTotalMicros += bindMicros.coerceAtLeast(0)
			backgroundPrebindBindMaxMicros = max(backgroundPrebindBindMaxMicros, bindMicros)
			if (layoutMicros > 0) {
				backgroundPrebindLayoutSampleCount += 1
				backgroundPrebindLayoutTotalMicros += layoutMicros
				backgroundPrebindLayoutMaxMicros = max(backgroundPrebindLayoutMaxMicros, layoutMicros)
			}
		}
	}

	fun drain(): Map<String, Any> {
		synchronized(this) {
			val snapshot = mapOf(
				"bindSampleCount" to bindSampleCount,
				"bindTotalMicros" to bindTotalMicros,
				"bindMaxMicros" to bindMaxMicros,
				"layoutSampleCount" to layoutSampleCount,
				"layoutTotalMicros" to layoutTotalMicros,
				"layoutMaxMicros" to layoutMaxMicros,
				"prebindRequestCount" to prebindRequestCount,
				"prebindHitCount" to prebindHitCount,
				"visiblePreboundBindSampleCount" to visiblePreboundBindSampleCount,
				"visiblePreboundBindTotalMicros" to visiblePreboundBindTotalMicros,
				"visiblePreboundBindMaxMicros" to visiblePreboundBindMaxMicros,
				"visiblePreboundLayoutSampleCount" to visiblePreboundLayoutSampleCount,
				"visiblePreboundLayoutTotalMicros" to visiblePreboundLayoutTotalMicros,
				"visiblePreboundLayoutMaxMicros" to visiblePreboundLayoutMaxMicros,
				"backgroundPrebindBindSampleCount" to backgroundPrebindBindSampleCount,
				"backgroundPrebindBindTotalMicros" to backgroundPrebindBindTotalMicros,
				"backgroundPrebindBindMaxMicros" to backgroundPrebindBindMaxMicros,
				"backgroundPrebindLayoutSampleCount" to backgroundPrebindLayoutSampleCount,
				"backgroundPrebindLayoutTotalMicros" to backgroundPrebindLayoutTotalMicros,
				"backgroundPrebindLayoutMaxMicros" to backgroundPrebindLayoutMaxMicros,
			)
			bindSampleCount = 0
			bindTotalMicros = 0L
			bindMaxMicros = 0L
			layoutSampleCount = 0
			layoutTotalMicros = 0L
			layoutMaxMicros = 0L
			prebindRequestCount = 0
			prebindHitCount = 0
			visiblePreboundBindSampleCount = 0
			visiblePreboundBindTotalMicros = 0L
			visiblePreboundBindMaxMicros = 0L
			visiblePreboundLayoutSampleCount = 0
			visiblePreboundLayoutTotalMicros = 0L
			visiblePreboundLayoutMaxMicros = 0L
			backgroundPrebindBindSampleCount = 0
			backgroundPrebindBindTotalMicros = 0L
			backgroundPrebindBindMaxMicros = 0L
			backgroundPrebindLayoutSampleCount = 0
			backgroundPrebindLayoutTotalMicros = 0L
			backgroundPrebindLayoutMaxMicros = 0L
			return snapshot
		}
	}
}

class ReaderPageViewFactory : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
	companion object {
		private const val MAX_VIEW_POOL_SIZE = 6
		private const val MAX_PREBOUND_VIEW_COUNT = 3
		private val viewPool = ArrayDeque<ReaderPageSurfaceView>()
		private val preboundViews = object : LinkedHashMap<String, ReaderPageSurfaceView>(8, 0.75f, true) {
			override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, ReaderPageSurfaceView>?): Boolean {
				if (size <= MAX_PREBOUND_VIEW_COUNT || eldest == null) {
					return false
				}
				recycleToPool(eldest.value)
				return true
			}
		}

		private fun obtainView(context: Context, args: Map<String, Any?>): ReaderPageSurfaceView {
			val bindingKey = bindingKeyOf(args)
			synchronized(viewPool) {
				if (bindingKey != null) {
					val prepared = preboundViews.remove(bindingKey)
					if (prepared != null) {
						if (prepared.matchesBindingKey(bindingKey)) {
							ReaderPageNativeStats.recordVisibleBind(0, 0, true)
							return prepared
						}
						val bindResult = prepared.rebind(args)
						ReaderPageNativeStats.recordVisibleBind(bindResult.bindMicros, bindResult.layoutMicros, true)
						return prepared
					}
				}
				val view = if (viewPool.isEmpty()) {
					ReaderPageSurfaceView(context)
				} else {
					viewPool.removeFirst()
				}
				val bindResult = view.rebind(args)
				ReaderPageNativeStats.recordVisibleBind(bindResult.bindMicros, bindResult.layoutMicros, false)
				return view
			}
		}

		fun prebind(context: Context, pages: List<Map<String, Any?>>) {
			ReaderPageNativeStats.recordPrebindRequests(pages.size)
			synchronized(viewPool) {
				for (args in pages) {
					val bindingKey = bindingKeyOf(args) ?: continue
					if (preboundViews.containsKey(bindingKey)) {
						continue
					}
					val view = if (viewPool.isEmpty()) {
						ReaderPageSurfaceView(context)
					} else {
						viewPool.removeFirst()
					}
					val bindResult = view.rebind(args)
					ReaderPageNativeStats.recordBackgroundPrebind(bindResult.bindMicros, bindResult.layoutMicros)
					preboundViews[bindingKey] = view
				}
			}
		}

		fun recycle(view: ReaderPageSurfaceView) {
			synchronized(viewPool) {
				(view.parent as? ViewGroup)?.removeView(view)
				recycleToPool(view)
			}
		}

		private fun recycleToPool(view: ReaderPageSurfaceView) {
			view.resetForReuse()
			if (viewPool.size < MAX_VIEW_POOL_SIZE) {
				viewPool.addLast(view)
			}
		}

		private fun bindingKeyOf(args: Map<String, Any?>): String? {
			return (args["bindingKey"] as? String)?.takeIf { it.isNotBlank() }
		}

		fun drainStats(): Map<String, Any> {
			return ReaderPageNativeStats.drain()
		}
	}

	override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
		return ReaderPagePlatformView(obtainView(context, args as? Map<String, Any?> ?: emptyMap()))
	}
}

private class ReaderPagePlatformView(
	private val view: ReaderPageSurfaceView,
) : PlatformView {
	override fun getView(): View = view

	override fun dispose() {
		ReaderPageViewFactory.recycle(view)
	}
}

class ReaderPageSurfaceView(
	context: Context,
) : View(context) {
	private val density = context.resources.displayMetrics.density
	private var text = ""
	private var fontSize = 18f
	private var lineHeight = 1.7f
	private var fontFamilyKey = "notoSerif"
	private var textColor = 0xFF111111.toInt()
	private var backgroundColor = 0xFFFFFFFF.toInt()
	private var direction = "ltr"
	private var bindingKey: String? = null
	private var explicitWidthPx = 0
	private var paint = ReaderStaticLayoutPager.createPaint(fontSize * density, textColor, fontFamilyKey)
	private var layout: StaticLayout? = null

	fun matchesBindingKey(candidate: String?): Boolean {
		return bindingKey != null && bindingKey == candidate
	}

	fun rebind(args: Map<String, Any?>): ReaderBindResult {
		val bindStartNanos = System.nanoTime()
		bindingKey = (args["bindingKey"] as? String)?.takeIf { it.isNotBlank() }
		text = args["text"] as? String ?: ""
		explicitWidthPx = (((args["width"] as? Number)?.toDouble() ?: 0.0) * density).roundToInt().coerceAtLeast(0)
		fontSize = (args["fontSize"] as? Number)?.toFloat() ?: 18f
		lineHeight = (args["lineHeight"] as? Number)?.toFloat() ?: 1.7f
		fontFamilyKey = args["fontFamilyKey"] as? String ?: "notoSerif"
		textColor = (args["textColor"] as? Number)?.toInt() ?: 0xFF111111.toInt()
		backgroundColor = (args["backgroundColor"] as? Number)?.toInt() ?: 0xFFFFFFFF.toInt()
		direction = args["textDirection"] as? String ?: "ltr"
		paint = ReaderStaticLayoutPager.createPaint(fontSize * density, textColor, fontFamilyKey)
		var layoutMicros = 0L
		if (width > 0) {
			layoutMicros = rebuildLayout(width)
		} else if (explicitWidthPx > 0) {
			layoutMicros = rebuildLayout(explicitWidthPx)
		} else {
			layout = null
			invalidate()
		}
		return ReaderBindResult(
			bindMicros = ((System.nanoTime() - bindStartNanos) / 1000L).coerceAtLeast(0),
			layoutMicros = layoutMicros,
		)
	}

	fun resetForReuse() {
		bindingKey = null
		text = ""
		explicitWidthPx = 0
		layout = null
		invalidate()
	}

	override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
		super.onSizeChanged(w, h, oldw, oldh)
		ReaderPageNativeStats.recordVisibleLayout(rebuildLayout(w))
	}

	override fun onDraw(canvas: Canvas) {
		canvas.drawColor(backgroundColor)
		val current = layout ?: return
		canvas.save()
		current.draw(canvas)
		canvas.restore()
	}

	private fun rebuildLayout(widthPx: Int): Long {
		val layoutStartNanos = System.nanoTime()
		val contentWidth = (widthPx - paddingLeft - paddingRight).coerceAtLeast(1)
		layout = if (text.isEmpty()) {
			null
		} else {
			ReaderPageLayoutCache.obtain(
				text = text,
				paint = paint,
				widthPx = contentWidth,
				lineHeight = lineHeight,
				direction = direction,
				builder = {
					ReaderStaticLayoutPager.buildLayout(
						text = text,
						start = 0,
						end = text.length,
						paint = paint,
						widthPx = contentWidth,
						lineHeight = lineHeight,
						direction = direction,
					)
				},
			)
		}
		invalidate()
		return ((System.nanoTime() - layoutStartNanos) / 1000L).coerceAtLeast(0)
	}
}

private object ReaderPageLayoutCache {
	private const val MAX_LAYOUT_COUNT = 48
	private val layouts = object : LruCache<String, StaticLayout>(MAX_LAYOUT_COUNT) {}

	fun obtain(
		text: String,
		paint: TextPaint,
		widthPx: Int,
		lineHeight: Float,
		direction: String,
		builder: () -> StaticLayout,
	): StaticLayout {
		val key = cacheKey(text, paint, widthPx, lineHeight, direction)
		synchronized(layouts) {
			val cached = layouts.get(key)
			if (cached != null) {
				return cached
			}
			return builder().also { layouts.put(key, it) }
		}
	}

	fun prewarm(
		text: String,
		paint: TextPaint,
		widthPx: Int,
		lineHeight: Float,
		direction: String,
	) {
		if (text.isEmpty()) return
		obtain(
			text = text,
			paint = paint,
			widthPx = widthPx,
			lineHeight = lineHeight,
			direction = direction,
			builder = {
				ReaderStaticLayoutPager.buildLayout(
					text = text,
					start = 0,
					end = text.length,
					paint = paint,
					widthPx = widthPx,
					lineHeight = lineHeight,
					direction = direction,
				)
			},
		)
	}

	private fun cacheKey(
		text: String,
		paint: TextPaint,
		widthPx: Int,
		lineHeight: Float,
		direction: String,
	): String {
		return listOf(
			widthPx,
			paint.textSize.toBits(),
			lineHeight.toBits(),
			paint.color,
			direction,
			paint.typeface?.style ?: 0,
			text.length,
			text.hashCode(),
		).joinToString("|")
	}
}

object ReaderStaticLayoutPager {
	fun paginate(context: Context, args: Map<String, Any?>): Map<String, Any?> {
		val text = args["text"] as? String ?: ""
		val startOffset = ((args["startOffset"] as? Number)?.toInt() ?: 0).coerceIn(0, text.length)
		val maxPages = ((args["maxPages"] as? Number)?.toInt() ?: 1).coerceIn(1, 64)
		val density = context.resources.displayMetrics.density
		val widthPx = (((args["width"] as? Number)?.toDouble() ?: 0.0) * density).roundToInt().coerceAtLeast(1)
		val heightPx = (((args["height"] as? Number)?.toDouble() ?: 0.0) * density).roundToInt().coerceAtLeast(1)
		val fontSizePx = (((args["fontSize"] as? Number)?.toDouble() ?: 18.0) * density).toFloat()
		val lineHeight = ((args["lineHeight"] as? Number)?.toFloat() ?: 1.7f).coerceAtLeast(1.0f)
		val direction = args["textDirection"] as? String ?: "ltr"
		val fontFamilyKey = args["fontFamilyKey"] as? String ?: "notoSerif"
		val paint = createPaint(fontSizePx, 0xFF111111.toInt(), fontFamilyKey)
		val pages = mutableListOf<Map<String, Int>>()
		var start = startOffset
		while (start < text.length && pages.size < maxPages) {
			val end = nextPage(text, start, paint, widthPx, heightPx, lineHeight, direction)
			if (end <= start) {
				break
			}
			ReaderPageLayoutCache.prewarm(
				text = text.substring(start, end),
				paint = paint,
				widthPx = widthPx,
				lineHeight = lineHeight,
				direction = direction,
			)
			pages.add(mapOf("start" to start, "end" to end))
			start = end
		}
		return mapOf(
			"pages" to pages,
			"nextOffset" to start,
			"hasMore" to (start < text.length),
		)
	}

	fun createPaint(fontSizePx: Float, textColor: Int, fontFamilyKey: String): TextPaint {
		return TextPaint(Paint.ANTI_ALIAS_FLAG or Paint.SUBPIXEL_TEXT_FLAG).apply {
			color = textColor
			textSize = fontSizePx
			typeface = when (fontFamilyKey) {
				"notoSans", "Noto Sans SC" -> Typeface.create("Noto Sans SC", Typeface.NORMAL)
				"notoSerif", "Noto Serif SC" -> Typeface.create("Noto Serif SC", Typeface.NORMAL)
				"literata", "Literata" -> Typeface.create("Literata", Typeface.NORMAL)
				"merriweather", "Merriweather" -> Typeface.create("Merriweather", Typeface.NORMAL)
				"lora", "Lora" -> Typeface.create("Lora", Typeface.NORMAL)
				else -> Typeface.SERIF
			}
			isLinearText = true
		}
	}

	private fun nextPage(
		text: String,
		start: Int,
		paint: TextPaint,
		widthPx: Int,
		heightPx: Int,
		lineHeight: Float,
		direction: String,
	): Int {
		val remaining = text.length - start
		var best = 1
		var lowFit = 0
		var highFail = remaining + 1
		val estimate = estimatedCharsPerPage(widthPx, heightPx, paint.textSize, lineHeight).coerceIn(1, remaining)
		if (fits(text, start, estimate, paint, widthPx, heightPx, lineHeight, direction)) {
			lowFit = estimate
			var probe = estimate
			while (probe < remaining) {
				val next = ((probe * 13) / 8 + 32).coerceIn(probe + 1, remaining)
				if (fits(text, start, next, paint, widthPx, heightPx, lineHeight, direction)) {
					lowFit = next
					probe = next
				} else {
					highFail = next
					break
				}
			}
			if (lowFit == remaining) {
				best = remaining
			}
		} else {
			highFail = estimate
			var probe = estimate
			while (probe > 1) {
				val next = (probe / 2).coerceIn(1, probe - 1)
				if (fits(text, start, next, paint, widthPx, heightPx, lineHeight, direction)) {
					lowFit = next
					break
				}
				highFail = next
				probe = next
			}
		}
		if (best != remaining) {
			var lo = lowFit + 1
			var hi = highFail - 1
			best = if (lowFit == 0) 1 else lowFit
			while (lo <= hi) {
				val mid = (lo + hi) / 2
				if (fits(text, start, mid, paint, widthPx, heightPx, lineHeight, direction)) {
					best = mid
					lo = mid + 1
				} else {
					hi = mid - 1
				}
			}
		}
		var cut = best.coerceIn(1, remaining)
		val segment = text.substring(start, start + cut)
		val lastNewline = segment.lastIndexOf('\n')
		if (lastNewline > cut * 0.5f) {
			cut = lastNewline + 1
		} else {
			for (punctuation in listOf('。', '！', '？', '.', '!', '?', '”', '」')) {
				val index = segment.lastIndexOf(punctuation)
				if (index > cut * 0.6f) {
					cut = index + 1
					break
				}
			}
		}
		return start + cut
	}

	private fun fits(
		text: String,
		start: Int,
		length: Int,
		paint: TextPaint,
		widthPx: Int,
		heightPx: Int,
		lineHeight: Float,
		direction: String,
	): Boolean {
		val end = (start + length).coerceIn(start + 1, text.length)
		val layout = buildLayout(text, start, end, paint, widthPx, lineHeight, direction)
		return layout.height <= heightPx
	}

	fun buildLayout(
		text: String,
		start: Int,
		end: Int,
		paint: TextPaint,
		widthPx: Int,
		lineHeight: Float,
		direction: String,
	): StaticLayout {
		return StaticLayout.Builder.obtain(text, start, end, paint, widthPx)
			.setAlignment(Layout.Alignment.ALIGN_NORMAL)
			.setIncludePad(false)
			.setLineSpacing(0f, lineHeight)
			.setBreakStrategy(Layout.BREAK_STRATEGY_HIGH_QUALITY)
			.setHyphenationFrequency(Layout.HYPHENATION_FREQUENCY_NONE)
			.setTextDirection(
				if (direction == "rtl") TextDirectionHeuristics.RTL else TextDirectionHeuristics.LTR,
			)
			.build()
	}

	private fun estimatedCharsPerPage(
		widthPx: Int,
		heightPx: Int,
		fontSizePx: Float,
		lineHeight: Float,
	): Int {
		val charsPerLine = (widthPx / (fontSizePx * 0.56f)).toInt().coerceIn(8, 240)
		val lines = (heightPx / (fontSizePx * lineHeight)).toInt().coerceIn(4, 160)
		return (charsPerLine * lines * 0.92f).roundToInt().coerceIn(16, 12000)
	}
}
