package com.example.sky_weather_app

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider

/**
 * Widget man hinh chinh: nhiet do, trang thai, kha nang mua 3 gio toi va ten
 * dia diem dau tien. Du lieu do Dart ghi qua HomeWidget.saveWidgetData
 * (lib/services/home_widget_service.dart); cham vao widget -> mo app.
 */
class WeatherWidgetProvider : HomeWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        for (id in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.weather_widget).apply {
                setTextViewText(R.id.widget_place, widgetData.getString("sw_place", null) ?: "Sky Weather")
                setTextViewText(R.id.widget_temp, widgetData.getString("sw_temp", null) ?: "--°")
                setTextViewText(
                    R.id.widget_condition,
                    widgetData.getString("sw_condition", null) ?: "Mở ứng dụng để tải dữ liệu",
                )
                setTextViewText(R.id.widget_rain, widgetData.getString("sw_rain3h", null) ?: "")
                setOnClickPendingIntent(
                    R.id.widget_root,
                    HomeWidgetLaunchIntent.getActivity(context, MainActivity::class.java),
                )
            }
            appWidgetManager.updateAppWidget(id, views)
        }
    }
}
