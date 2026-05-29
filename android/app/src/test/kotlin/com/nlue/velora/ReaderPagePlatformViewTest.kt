package com.nlue.velora

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.util.UUID

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33])
class ReaderPagePlatformViewTest {
    @Test
    fun prebindTelemetrySeparatesBackgroundAndVisibleHit() {
        ReaderPageViewFactory.drainStats()
        val context = ApplicationProvider.getApplicationContext<Context>()
        val factory = ReaderPageViewFactory()
        val suffix = UUID.randomUUID().toString()
        val firstPage = pageArgs(
            bindingKey = "binding-$suffix-a",
            text = "这是第一页，用于验证预绑定命中之后的可见统计回传。",
        )
        val secondPage = pageArgs(
            bindingKey = "binding-$suffix-b",
            text = "这是第二页，用于验证后台预绑定统计不会串到可见路径。",
        )

        ReaderPageViewFactory.prebind(context, listOf(firstPage, secondPage))

        val background = ReaderPageViewFactory.drainStats()
        assertStat(background, "prebindRequestCount", 2)
        assertStat(background, "bindSampleCount", 0)
        assertStat(background, "prebindHitCount", 0)
        assertStat(background, "backgroundPrebindBindSampleCount", 2)
        assertStat(background, "backgroundPrebindLayoutSampleCount", 2)
        assertTrue(readLong(background, "backgroundPrebindBindTotalMicros") >= 0L)
        assertTrue(readLong(background, "backgroundPrebindLayoutTotalMicros") >= 0L)

        val platformView = factory.create(context, 1, firstPage)
        try {
            val visible = ReaderPageViewFactory.drainStats()
            assertStat(visible, "bindSampleCount", 1)
            assertStat(visible, "prebindHitCount", 1)
            assertStat(visible, "visiblePreboundBindSampleCount", 1)
            assertStat(visible, "visiblePreboundLayoutSampleCount", 0)
            assertStat(visible, "backgroundPrebindBindSampleCount", 0)
            assertStat(visible, "backgroundPrebindLayoutSampleCount", 0)
            assertEquals(0L, readLong(visible, "bindTotalMicros"))
            assertEquals(0L, readLong(visible, "layoutTotalMicros"))
        } finally {
            platformView.dispose()
        }
    }

    @Test
    fun drainStatsResetsTelemetrySnapshot() {
        ReaderPageViewFactory.drainStats()
        val context = ApplicationProvider.getApplicationContext<Context>()
        val factory = ReaderPageViewFactory()
        val platformView = factory.create(
            context,
            2,
            pageArgs(
                bindingKey = "binding-${UUID.randomUUID()}",
                text = "单页绑定，用来验证 telemetry drain 之后会被清零。",
            ),
        )
        try {
            val first = ReaderPageViewFactory.drainStats()
            assertStat(first, "bindSampleCount", 1)

            val second = ReaderPageViewFactory.drainStats()
            assertStat(second, "bindSampleCount", 0)
            assertStat(second, "prebindHitCount", 0)
            assertStat(second, "backgroundPrebindBindSampleCount", 0)
            assertStat(second, "backgroundPrebindLayoutSampleCount", 0)
        } finally {
            platformView.dispose()
        }
    }

    private fun pageArgs(bindingKey: String, text: String): Map<String, Any?> {
        return mapOf(
            "bindingKey" to bindingKey,
            "text" to text,
            "width" to 240.0,
            "fontSize" to 18.0,
            "lineHeight" to 1.7,
            "fontFamilyKey" to "notoSerif",
            "textColor" to 0xFF111111.toInt(),
            "backgroundColor" to 0xFFFFFFFF.toInt(),
            "textDirection" to "ltr",
        )
    }

    private fun assertStat(snapshot: Map<String, Any>, key: String, expected: Int) {
        assertEquals(expected, (snapshot[key] as Number).toInt())
    }

    private fun readLong(snapshot: Map<String, Any>, key: String): Long {
        return (snapshot[key] as Number).toLong()
    }
}