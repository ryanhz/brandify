package dev.brandify.brandify_example

import android.content.Context
import android.graphics.Canvas
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.Typeface
import android.view.View
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.platformViewsController.registry.registerViewFactory(
            FOCUS_CHART_VIEW_TYPE,
            object : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
                override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
                    val view = FocusChartView(context)
                    return object : PlatformView {
                        override fun getView(): View = view
                        override fun dispose() {}
                    }
                }
            },
        )
    }
}

/** Keep in sync with `focusChartViewType` in lib/main.dart. */
const val FOCUS_CHART_VIEW_TYPE = "brandify_example/focus_chart"

/**
 * A weekly bar chart drawn by Android's Canvas: a native view (PlatformView)
 * inside the Flutter UI. Widget-test renderers can't draw it; a capture of
 * the real screen can. Static on purpose, so screenshots are deterministic.
 */
class FocusChartView(context: Context) : View(context) {
    private val hours = floatArrayOf(3.5f, 5f, 2.5f, 6f, 4.5f, 1.5f, 2f)
    private val days = arrayOf("M", "T", "W", "T", "F", "S", "S")
    private val dp = context.resources.displayMetrics.density

    private val card = Paint(Paint.ANTI_ALIAS_FLAG)
    private val bar = Paint(Paint.ANTI_ALIAS_FLAG)
    private val track = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0x33FFFFFF }
    private val label = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0xCCFFFFFF.toInt()
        textSize = 12 * dp
        textAlign = Paint.Align.CENTER
    }
    private val title = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0xFFFFFFFF.toInt()
        textSize = 15 * dp
        typeface = Typeface.DEFAULT_BOLD
    }
    private val caption = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0xB3FFFFFF.toInt()
        textSize = 11 * dp
    }

    override fun onDraw(canvas: Canvas) {
        val w = width.toFloat()
        val h = height.toFloat()
        card.shader = LinearGradient(0f, 0f, w, h, 0xFF2E5BFF.toInt(), 0xFF8E2DE2.toInt(), Shader.TileMode.CLAMP)
        canvas.drawRoundRect(RectF(0f, 0f, w, h), 20 * dp, 20 * dp, card)

        val pad = 16 * dp
        canvas.drawText("24.5 h focused this week", pad, pad + 15 * dp, title)
        canvas.drawText("Native view · Android Canvas", pad, pad + 32 * dp, caption)

        val top = pad + 48 * dp
        val bottom = h - pad - 18 * dp
        val slot = (w - 2 * pad) / hours.size
        val barW = slot * 0.45f
        val max = hours.max()
        bar.shader = LinearGradient(0f, top, 0f, bottom, 0xFFFFFFFF.toInt(), 0xFFB8C6FF.toInt(), Shader.TileMode.CLAMP)
        for (i in hours.indices) {
            val cx = pad + slot * (i + 0.5f)
            val r = barW / 2
            canvas.drawRoundRect(RectF(cx - r, top, cx + r, bottom), r, r, track)
            val y = bottom - (bottom - top) * hours[i] / max
            canvas.drawRoundRect(RectF(cx - r, y, cx + r, bottom), r, r, bar)
            canvas.drawText(days[i], cx, h - pad, label)
        }
    }
}
