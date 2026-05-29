package com.nlue.velora

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import android.content.Intent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

@RunWith(AndroidJUnit4::class)
class ReaderLayoutMethodChannelInstrumentedTest {
    @Test
    fun methodChannelReportsBackgroundAndVisibleTelemetry() {
        val activity = launchActivity()
        try {
            awaitMessenger(activity)

            invokeReaderLayout<Map<String, Any>>(activity, "drainStaticLayoutStats")

            val suffix = UUID.randomUUID().toString()
            val firstPage = pageArgs(
                bindingKey = "binding-$suffix-a",
                text = "第一页通过 MethodChannel 预绑定，然后再由可见路径命中。",
            )
            val secondPage = pageArgs(
                bindingKey = "binding-$suffix-b",
                text = "第二页只用于补齐后台预绑定统计。",
            )

            val prebindResult = invokeReaderLayout<Any?>(
                activity,
                "prebindStaticLayoutPages",
                mapOf("pages" to listOf(firstPage, secondPage)),
            )
            assertNull(prebindResult)

            val background = invokeReaderLayout<Map<String, Any>>(
                activity,
                "drainStaticLayoutStats",
            )!!
            assertStat(background, "prebindRequestCount", 2)
            assertStat(background, "bindSampleCount", 0)
            assertStat(background, "prebindHitCount", 0)
            assertStat(background, "backgroundPrebindBindSampleCount", 2)
            assertStat(background, "backgroundPrebindLayoutSampleCount", 2)

            activity.runOnUiThread {
                val platformView = ReaderPageViewFactory().create(activity, 101, firstPage)
                platformView.dispose()
            }
            InstrumentationRegistry.getInstrumentation().waitForIdleSync()

            val visible = invokeReaderLayout<Map<String, Any>>(
                activity,
                "drainStaticLayoutStats",
            )!!
            assertStat(visible, "bindSampleCount", 1)
            assertStat(visible, "prebindHitCount", 1)
            assertStat(visible, "visiblePreboundBindSampleCount", 1)
            assertStat(visible, "backgroundPrebindBindSampleCount", 0)
            assertEquals(0L, readLong(visible, "bindTotalMicros"))
        } finally {
            finishActivity(activity)
        }
    }

    @Test
    fun methodChannelDrainClearsTelemetryBetweenCalls() {
        val activity = launchActivity()
        try {
            awaitMessenger(activity)

            val singlePage = pageArgs(
                bindingKey = "binding-${UUID.randomUUID()}",
                text = "预绑定后连续 drain，第二次必须是清零快照。",
            )

            invokeReaderLayout<Any?>(
                activity,
                "prebindStaticLayoutPages",
                mapOf("pages" to listOf(singlePage)),
            )

            val first = invokeReaderLayout<Map<String, Any>>(
                activity,
                "drainStaticLayoutStats",
            )!!
            val second = invokeReaderLayout<Map<String, Any>>(
                activity,
                "drainStaticLayoutStats",
            )!!

            assertStat(first, "prebindRequestCount", 1)
            assertStat(second, "prebindRequestCount", 0)
            assertStat(second, "backgroundPrebindBindSampleCount", 0)
            assertStat(second, "bindSampleCount", 0)
        } finally {
            finishActivity(activity)
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

    private fun launchActivity(): MainActivity {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val intent = Intent(instrumentation.targetContext, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        val activity = instrumentation.startActivitySync(intent) as MainActivity
        instrumentation.waitForIdleSync()
        return activity
    }

    private fun finishActivity(activity: MainActivity) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        activity.runOnUiThread {
            activity.finishAndRemoveTask()
        }
        instrumentation.waitForIdleSync()
    }

    private fun awaitMessenger(activity: MainActivity) {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
        while (activity.debugReaderLayoutMessenger == null && System.nanoTime() < deadline) {
            InstrumentationRegistry.getInstrumentation().waitForIdleSync()
        }
        check(activity.debugReaderLayoutMessenger != null) {
            "Flutter binary messenger is not ready"
        }
    }

    private fun <T> invokeReaderLayout(
        activity: MainActivity,
        method: String,
        arguments: Any? = null,
    ): T? {
        val messenger = activity.debugReaderLayoutMessenger
            ?: error("Flutter binary messenger is not ready")
        val result = AtomicReference<Any?>()
        val failure = AtomicReference<Throwable?>()
        val latch = CountDownLatch(1)
        activity.runOnUiThread {
            messenger.invokeInboundMethodCall(
                "velora/reader_layout",
                method,
                arguments,
            ) { value, error ->
                if (error != null) {
                    failure.set(AssertionError("$method failed", error))
                } else {
                    result.set(value)
                }
                latch.countDown()
            }
        }
        assertTrue("MethodChannel timed out for $method", latch.await(5, TimeUnit.SECONDS))
        failure.get()?.let { throw it }
        @Suppress("UNCHECKED_CAST")
        return result.get() as T?
    }
}