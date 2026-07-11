package com.example.opencfu_mobile

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.widget.RemoteViews

/**
 * Home-screen widget, resizable between two layouts:
 *  - Default/compact (see widget_basic_capture.xml): a single icon-only tap
 *    target that launches straight into basic-mode capture.
 *  - Widened past [EXPANDED_MIN_WIDTH_DP] (see widget_capture_expanded.xml):
 *    two tap targets side by side, adding a second one straight into
 *    Advanced Setup -- the operator opts into this by manually resizing the
 *    widget, so the compact single-icon widget stays the default everyone
 *    gets.
 *
 * Both launch [MainActivity] (see [MainActivity.ACTION_BASIC_CAPTURE] /
 * [MainActivity.ACTION_ADVANCED_CAPTURE] and the `opencfu_mobile/shortcut`
 * method channel they feed).
 */
class BasicCaptureWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        for (appWidgetId in appWidgetIds) {
            updateAppWidget(context, appWidgetManager, appWidgetId, appWidgetManager.getAppWidgetOptions(appWidgetId))
        }
    }

    // Fires whenever the operator drag-resizes the widget (or the launcher
    // otherwise changes its allotted size), independent of onUpdate -- this
    // is what makes the compact/expanded swap live instead of only applying
    // the next time the OS happens to refresh the widget.
    override fun onAppWidgetOptionsChanged(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: Bundle,
    ) {
        updateAppWidget(context, appWidgetManager, appWidgetId, newOptions)
    }

    private fun updateAppWidget(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        options: Bundle,
    ) {
        val minWidthDp = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 0)
        val expanded = minWidthDp >= EXPANDED_MIN_WIDTH_DP

        val views = if (expanded) {
            RemoteViews(context.packageName, R.layout.widget_capture_expanded).apply {
                setOnClickPendingIntent(
                    R.id.widget_expanded_basic,
                    captureIntent(context, appWidgetId, MainActivity.ACTION_BASIC_CAPTURE, BASIC_REQUEST_CODE_OFFSET),
                )
                setOnClickPendingIntent(
                    R.id.widget_expanded_advanced,
                    captureIntent(context, appWidgetId, MainActivity.ACTION_ADVANCED_CAPTURE, ADVANCED_REQUEST_CODE_OFFSET),
                )
            }
        } else {
            RemoteViews(context.packageName, R.layout.widget_basic_capture).apply {
                setOnClickPendingIntent(
                    R.id.widget_basic_capture_root,
                    captureIntent(context, appWidgetId, MainActivity.ACTION_BASIC_CAPTURE, BASIC_REQUEST_CODE_OFFSET),
                )
            }
        }
        appWidgetManager.updateAppWidget(appWidgetId, views)
    }

    private fun captureIntent(context: Context, appWidgetId: Int, action: String, requestCodeOffset: Int): PendingIntent {
        // NEW_TASK is required because a widget's PendingIntent runs outside any
        // activity context; CLEAR_TOP + MainActivity's singleTop launch mode
        // means an already-running instance is reused via onNewIntent() instead
        // of being destroyed and recreated, so in-progress capture state (an
        // unsaved plate, the results list) survives a repeat widget tap.
        val launchIntent = Intent(context, MainActivity::class.java).apply {
            this.action = action
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        // Unique per-widget-instance-and-target request code, so distinct
        // widget instances (if the user adds more than one) and the two tap
        // targets within the same expanded widget don't collide in the
        // PendingIntent cache.
        return PendingIntent.getActivity(
            context,
            appWidgetId + requestCodeOffset,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    companion object {
        // Comfortably fits two ~equal tap targets side by side; below this
        // the compact single-icon layout is used instead. Chosen well above
        // the widget's 40dp default/minimum size so only a deliberate resize
        // crosses it.
        private const val EXPANDED_MIN_WIDTH_DP = 110

        private const val BASIC_REQUEST_CODE_OFFSET = 0
        private const val ADVANCED_REQUEST_CODE_OFFSET = 1_000_000
    }
}
