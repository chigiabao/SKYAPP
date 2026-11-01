/// Phan nho cua trang dia diem: ten, the mua, 7 ngay, bang trang thai.
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../models/weather.dart';
import '../../models/weather_alerts.dart';
import '../../providers/preferences_provider.dart';
import '../../providers/weather_provider.dart';
import '../../ui/weather/design_tokens.dart';
import '../../ui/weather/glass_ink.dart';
import '../../ui/weather/weather_insights.dart';
import '../../ui/weather/widgets/daily_forecast_list.dart';
import '../../ui/weather/widgets/rain_timeline_card.dart';
import '../../widgets/planner_cards.dart';
import '../forecast_screen.dart';
import 'home_status.dart';

/// Ten dia diem tren thanh tren: cham -> danh sach, giu -> gia lap (debug).
class HomeCityTitle extends StatelessWidget {
  const HomeCityTitle({
    super.key,
    required this.city,
    required this.onTap,
    this.onLongPress,
  });

  final String city;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: city,
      child: Semantics(
        button: true,
        label: 'Chọn địa điểm: $city',
        excludeSemantics: true,
        onTap: onTap,
        child: CupertinoButton(
          padding: EdgeInsets.zero,
          minimumSize: const Size(Touch.min, Touch.min),
          onPressed: onTap,
          onLongPress: onLongPress,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: Touch.min),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    city,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TypeScale.headline.copyWith(color: Palette.white),
                  ),
                ),
                const Icon(
                  CupertinoIcons.chevron_down,
                  size: 16,
                  color: Palette.white,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The "dòng thời gian mưa" (thay banner canh bao): hien khi co canh bao
/// chua dong hoac co gio mua >= 30 % trong 24 gio toi. Cham -> man Canh bao.
Widget? homeRainCard(
  BuildContext context,
  WeatherProvider provider,
  List<AlertEvent> events,
  WeatherAlert? alert, {
  required String? dismissedAlertKey,
  required WeatherAlert? dismissedAlert,
  required VoidCallback? onOpenAlerts,
  required ValueChanged<String>? onDismissAlertKey,
  required ValueChanged<WeatherAlert> onDismissAlert,
}) {
  final slots = rainTimeline(provider.hourlyForecast, nowHcm: provider.nowHcm);
  final hasRain = slots.any((s) => (s.p ?? 0) >= 0.3 || s.thunder);
  final top = events.isNotEmpty && events.first.key != dismissedAlertKey
      ? events.first
      : null;
  final legacy = alert != null && alert != dismissedAlert ? alert : null;
  // Nguoi dung da dong canh bao nay -> an ca the (khong hien lai the mua).
  final dismissed =
      (events.isNotEmpty && top == null) || (alert != null && legacy == null);
  if (dismissed || (top == null && legacy == null && !hasRain)) return null;
  final more = events.length > 1 ? ' · +${events.length - 1} khác' : '';
  return RainTimelineCard(
    slots: slots,
    title: top != null
        ? '${top.level.label} · ${top.title}$more'
        : legacy != null
        ? legacy.title
        : 'Mưa theo giờ',
    alertDetail:
        top?.detailFor(PreferencesProvider.unitsOf(context)) ?? legacy?.detail,
    icon: top == null ? null : alertIcon(top.type),
    thunder:
        top?.type == AlertType.thunderstorm ||
        (legacy?.thunder ?? false) ||
        (top == null && legacy == null && slots.any((s) => s.thunder)),
    accent: top != null
        ? levelColor(context, top.level)
        : legacy != null
        ? GlassInk.of(context).alert
        : null,
    onOpen: onOpenAlerts,
    onDismiss: top != null
        ? () => onDismissAlertKey?.call(top.key)
        : legacy != null
        ? () => onDismissAlert(legacy)
        : null,
  );
}

/// The du bao 7 ngay; cham mot ngay -> man chi tiet (Hero).
Widget homeDailyCard(
  BuildContext context,
  WeatherProvider provider,
  CurrentWeather current,
) {
  return DailyForecastCard(
    days: provider.dailyForecast,
    currentTemp: current.temperature,
    heroes: true,
    onDayTap: (d) {
      final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
      // Hero 'day-yyyy-MM-dd' bay sang the ngay o man chi tiet.
      final duration = reduce
          ? Duration.zero
          : const Duration(milliseconds: 350);
      Navigator.push(
        context,
        PageRouteBuilder<void>(
          transitionDuration: duration,
          reverseTransitionDuration: duration,
          pageBuilder: (_, _, _) => ForecastScreen(
            selectedDay: d,
            allDays: provider.dailyForecast,
            hourlyData: provider.hourlyForecast,
          ),
          transitionsBuilder: (_, a, _, child) => FadeTransition(
            opacity: CurvedAnimation(parent: a, curve: Curves.fastOutSlowIn),
            child: child,
          ),
        ),
      );
    },
  );
}

/// Bang trang thai: thong bao, loi tai (co du lieu cu). Loi du bao AI
/// (forecast_error) hien bang [AIUnavailableCard] trong tab Dự báo.
List<Widget> homeBanners(WeatherProvider provider) => [
  if (provider.notice != null)
    HomeGlassBanner(
      icon: Icons.info_outline_rounded,
      message: provider.notice!,
      actionLabel: 'Đóng',
      onAction: provider.clearNotice,
    ),
  if (provider.error != null && provider.weatherData != null)
    HomeGlassBanner(
      icon: Icons.cloud_off_outlined,
      message: provider.error!,
      actionLabel: 'Thử lại',
      onAction: provider.isLoading ? null : provider.refreshWeatherData,
    ),
];
