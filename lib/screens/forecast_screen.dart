import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config/api_config.dart';
import '../models/weather.dart';
import '../providers/planner_provider.dart';
import '../providers/weather_provider.dart';
import '../services/feedback_service.dart';
import '../services/share_service.dart';
import '../ui/weather/widgets/glass_page.dart';
import '../ui/weather/design_tokens.dart';
import '../utils/constants.dart';
import '../widgets/planner_cards.dart';
import 'forecast/forecast_charts.dart';
import 'forecast/forecast_format.dart';
import 'forecast/forecast_source.dart';
import 'forecast/forecast_widgets.dart';
import 'feedback_screen.dart';

export 'forecast/forecast_source.dart' show ForecastSource;

/// Man hinh chi tiet mot ngay: tom tat ngay, bieu do theo gio (nhiet do,
/// kha nang mua, gio) neu du lieu theo gio phu ngay do, bieu do 7 ngay
/// (nhiet do cao/thap, kha nang mua, gio manh nhat + gio giat).
class ForecastScreen extends StatefulWidget {
  /// Ngay nguoi dung cham o Home - man hinh mo dung ngay nay.
  final DailyForecast selectedDay;

  /// Du lieu du phong khi provider chua co du lieu (provider uu tien).
  final List<DailyForecast> allDays;
  final List<HourlyForecast> hourlyData;

  /// Ghi de nguon hien o chip; null (mac dinh) = suy ra tu truong `source`
  /// cua cac muc dang hien thi.
  final ForecastSource? source;

  const ForecastScreen({
    super.key,
    required this.selectedDay,
    required this.allDays,
    required this.hourlyData,
    this.source,
  });

  @override
  State<ForecastScreen> createState() => _ForecastScreenState();
}

class _ForecastScreenState extends State<ForecastScreen> {
  late DateTime _selectedDate = HcmTime.startOfDay(widget.selectedDay.date);

  void _select(List<DailyForecast> days, int index) {
    if (index < 0 || index >= days.length) return;
    setState(() => _selectedDate = HcmTime.startOfDay(days[index].date));
  }

  @override
  Widget build(BuildContext context) =>
      GlassPage(child: Builder(builder: _buildPage));

  /// Goi y khung gio cho hoat dong yeu thich trong ngay dang xem (tu gio
  /// hien tai cua app neu la hom nay). Khong co PlannerProvider -> an.
  List<Widget> _activitySection(
    BuildContext context,
    DailyForecast day,
    List<HourlyForecast> hours,
    DateTime now,
  ) {
    final planner = maybePlanner(context);
    if (planner == null) return const [];
    final dayStart = HcmTime.startOfDay(day.date);
    final dayEnd = dayStart.add(const Duration(days: 1));
    if (!now.isBefore(dayEnd)) return const [];
    final from = now.isAfter(dayStart) ? now : dayStart;
    final horizon = dayEnd.difference(HcmTime.startOfHour(from)).inHours;
    final dayHours = [
      for (final h in hours)
        if (!h.time.isBefore(dayStart) && h.time.isBefore(dayEnd)) h,
    ];
    if (dayHours.isEmpty) return const [];
    return [
      const SizedBox(height: AppSizes.paddingM),
      ActivitySuggestionCard(
        title: 'GỢI Ý HOẠT ĐỘNG TRONG NGÀY',
        activities: planner.favorites,
        hours: dayHours,
        nowHcm: from,
        horizonHours: horizon,
        sensitivity: planner.sensitivity,
      ),
    ];
  }

  /// Noi dung (context nam duoi theme kinh cua GlassPage).
  Widget _buildPage(BuildContext context) {
    final provider = context.watch<WeatherProvider>();
    final now = provider.nowHcm;

    final days = [
      ...(provider.dailyForecast.isNotEmpty
          ? provider.dailyForecast
          : widget.allDays),
    ]..sort((a, b) => a.date.compareTo(b.date));
    final hours = [
      ...(provider.hourlyForecast.isNotEmpty
          ? provider.hourlyForecast
          : widget.hourlyData),
    ]..sort((a, b) => a.time.compareTo(b.time));

    final selectedIndex = days.indexWhere(
      (d) => ForecastFormat.sameDay(d.date, _selectedDate),
    );

    Widget body;
    String title = 'Dự báo chi tiết';
    if (days.isEmpty || selectedIndex < 0) {
      body = _StateView(provider: provider, hasDays: days.isNotEmpty);
    } else {
      final day = days[selectedIndex];
      title = ForecastFormat.title(day.date);
      final width = MediaQuery.sizeOf(context).width;
      final hPad = width > Space.contentMaxWidth + 2 * AppSizes.paddingM
          ? (width - Space.contentMaxWidth) / 2
          : AppSizes.paddingM;
      body = RefreshIndicator(
        onRefresh: provider.fetchWeatherData,
        child: ListView(
          padding: EdgeInsets.fromLTRB(
            hPad,
            AppSizes.paddingS,
            hPad,
            AppSizes.paddingXL,
          ),
          children: [
            if (provider.error != null) ...[
              ForecastMessageCard(
                icon: Icons.cloud_off_rounded,
                message: provider.error!,
                action: TextButton(
                  onPressed: provider.isLoading
                      ? null
                      : provider.fetchWeatherData,
                  child: const Text('Thử lại'),
                ),
              ),
              const SizedBox(height: AppSizes.paddingM),
            ],
            DayPicker(
              days: days,
              selectedIndex: selectedIndex,
              nowHcm: now,
              onSelect: (i) => _select(days, i),
            ),
            const SizedBox(height: AppSizes.paddingM),
            ForecastSourceInfo(
              source:
                  widget.source ??
                  ForecastSource.fromItems([
                    for (final d in days) d.source,
                    for (final h in hours) h.source,
                  ]),
              isFromCache: provider.isFromCache,
              cachedAt: provider.cachedAt,
            ),
            const SizedBox(height: AppSizes.paddingM),
            DaySummaryCard(day: day, provider: provider),
            ..._activitySection(context, day, hours, now),
            ..._hourlySection(day, hours, now, provider),
            ..._dailySection(context, days, selectedIndex, now, provider),
          ],
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        titleTextStyle: AppTextStyles.heading2.copyWith(
          color: Theme.of(context).textTheme.titleLarge?.color,
        ),
        actions: [
          IconButton(
            tooltip: 'Báo dự báo sai',
            icon: const Icon(Icons.report_outlined),
            onPressed: () => _openWrongForecast(context, provider, hours),
          ),
          _ShareMenu(provider: provider, hours: hours),
          IconButton(
            tooltip: 'Làm mới',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: provider.isLoading ? null : provider.fetchWeatherData,
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(2),
          child: provider.isLoading
              ? const LinearProgressIndicator(minHeight: 2)
              : const SizedBox(height: 2),
        ),
      ),
      body: body,
    );
  }

  /// Mo man Gop y voi loai "Dự báo sai" + du bao gio hien tai dinh kem.
  void _openWrongForecast(
    BuildContext context,
    WeatherProvider provider,
    List<HourlyForecast> hours,
  ) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FeedbackScreen(
          initialKind: FeedbackKind.wrongForecast,
          locationId: provider.locationId,
          snapshot: forecastSnapshot(
            locationId: provider.locationId,
            nowHcm: provider.nowHcm,
            hours: hours,
            current: provider.currentWeather,
          ),
        ),
      ),
    );
  }

  List<Widget> _hourlySection(
    DailyForecast day,
    List<HourlyForecast> hours,
    DateTime now,
    WeatherProvider provider,
  ) {
    final isToday = ForecastFormat.sameDay(day.date, now);
    final List<HourlyForecast> shown;
    final String subtitle;

    if (isToday && hours.any((h) => ForecastFormat.sameDay(h.time, now))) {
      // Hom nay: hien du cua so 24 gio toi (co the sang ngay mai).
      shown = hours;
      subtitle =
          '${hours.length} giờ tới · từ ${ForecastFormat.hourMinute(hours.first.time)} '
          '${ForecastFormat.relativeDay(hours.first.time, now).toLowerCase()}';
    } else {
      shown = [
        for (final h in hours)
          if (ForecastFormat.sameDay(h.time, day.date)) h,
      ];
      subtitle = shown.isEmpty
          ? ''
          : 'Có số liệu ${ForecastFormat.hourMinute(shown.first.time)}–'
                '${ForecastFormat.hourMinute(shown.last.time)}'
                '${shown.length < 24 ? ' (các giờ còn lại chưa có)' : ''}';
    }

    if (shown.isEmpty) {
      final String message;
      if (hours.isEmpty) {
        message = 'Chưa có số liệu theo giờ.';
      } else {
        final last = hours.last.time;
        message =
            'Chưa có số liệu theo giờ cho ${ForecastFormat.title(day.date)}. '
            'Số liệu theo giờ chỉ có cho ${hours.length} giờ tới '
            '(đến ${ForecastFormat.hourMinute(last)}, '
            '${ForecastFormat.title(last)}).';
      }
      return [
        const ForecastSectionTitle('Theo giờ'),
        ForecastMessageCard(icon: Icons.schedule_rounded, message: message),
      ];
    }

    final nowHour = HcmTime.startOfHour(now);
    final idx = shown.indexWhere((h) => HcmTime.startOfHour(h.time) == nowHour);
    final nowIndex = idx < 0 ? null : idx;

    return [
      ForecastSectionTitle('Nhiệt độ theo giờ', subtitle: subtitle),
      HourlyTemperatureChart(
        hours: shown,
        nowIndex: nowIndex,
        provider: provider,
      ),
      ForecastSectionTitle(
        'Khả năng mưa (%)',
        subtitle: shown.any((h) => h.isObserved)
            ? 'Giờ "Thực tế": 100% = có mưa, 0% = không mưa.'
            : null,
      ),
      HourlyRainChart(hours: shown, nowIndex: nowIndex),
      const ForecastSectionTitle(
        'Gió theo giờ (km/h)',
        subtitle: 'Tốc độ gió trung bình và gió giật trong giờ.',
      ),
      if (shown.any((h) => h.windSpeed != null || h.windGusts != null))
        HourlyWindChart(hours: shown, nowIndex: nowIndex)
      else
        const ForecastMessageCard(
          icon: Icons.air_rounded,
          message: 'Chưa có số liệu gió theo giờ.',
        ),
      const SizedBox(height: AppSizes.paddingM),
      HourlyTable(hours: shown, nowIndex: nowIndex, provider: provider),
    ];
  }

  List<Widget> _dailySection(
    BuildContext context,
    List<DailyForecast> days,
    int selectedIndex,
    DateTime now,
    WeatherProvider provider,
  ) {
    final p = ChartPalette(context);
    final rainMissing = days.any((d) => d.rainDayProbability == null);
    final windMissing = days.any((d) => d.windSpeed == null);
    final hasGusts = days.any((d) => d.windGusts != null);
    final gustColor = p.isDark
        ? const Color(0xFFFFCC80)
        : const Color(0xFFB45309);
    final rainNotes = [
      if (days.any((d) => d.isObserved))
        'Ngày "Thực tế": 100% = có mưa ≥ 1 mm, 0% = không mưa.',
      if (rainMissing) 'Ngày không có cột: chưa có số liệu.',
    ].join(' ');
    final hint = 'Chạm vào một ngày để xem chi tiết.';
    return [
      ForecastSectionTitle('Nhiệt độ ${days.length} ngày', subtitle: hint),
      DailyTemperatureChart(
        days: days,
        selectedIndex: selectedIndex,
        provider: provider,
        onSelect: (i) => _select(days, i),
      ),
      ForecastSectionTitle(
        'Khả năng mưa theo ngày (%)',
        subtitle: rainNotes.isEmpty ? null : rainNotes,
      ),
      DailyBarChart(
        days: days,
        values: [for (final d in days) d.rainDayPercent?.toDouble()],
        selectedIndex: selectedIndex,
        nowHcm: now,
        color: p.rain,
        unitSuffix: '%',
        fixedMaxY: 100,
        semanticsLabel: 'Biểu đồ khả năng mưa ${days.length} ngày',
        onSelect: (i) => _select(days, i),
      ),
      ForecastSectionTitle(
        'Gió mạnh nhất (km/h)',
        subtitle:
            '${hasGusts ? 'Tốc độ gió và gió giật lớn nhất mỗi ngày.' : 'Tốc độ gió lớn nhất mỗi ngày.'}'
            '${windMissing ? ' Ngày không có cột: chưa có số liệu.' : ''}',
      ),
      DailyBarChart(
        days: days,
        values: [for (final d in days) d.windSpeed],
        selectedIndex: selectedIndex,
        nowHcm: now,
        color: p.wind,
        unitSuffix: ' km/h',
        semanticsLabel: 'Biểu đồ gió mạnh nhất ${days.length} ngày',
        onSelect: (i) => _select(days, i),
        secondaryValues: hasGusts ? [for (final d in days) d.windGusts] : null,
        secondaryColor: gustColor,
        secondaryLabel: 'Giật',
        legend: hasGusts
            ? ChartLegend(
                items: [
                  (p.wind, 'Gió mạnh nhất', false),
                  (gustColor, 'Gió giật mạnh nhất', false),
                ],
              )
            : null,
      ),
    ];
  }
}

/// Menu chia se: tom tat thoi tiet / goi y khung gio hoat dong (van ban).
class _ShareMenu extends StatelessWidget {
  const _ShareMenu({required this.provider, required this.hours});

  final WeatherProvider provider;
  final List<HourlyForecast> hours;

  String get _place =>
      provider.currentWeather?.locationName ?? ApiConfig.locationName;

  Future<void> _share(BuildContext context, String? text) async {
    final messenger = ScaffoldMessenger.of(context);
    if (text == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Chưa có dữ liệu để chia sẻ.')),
      );
      return;
    }
    final r = await shareOrCopy(text);
    if (r == ShareOutcome.shared) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          r == ShareOutcome.copied
              ? 'Thiết bị không hỗ trợ chia sẻ. Đã sao chép nội dung vào bộ nhớ tạm.'
              : 'Không chia sẻ được.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final planner = maybePlanner(context);
    return PopupMenuButton<int>(
      tooltip: 'Chia sẻ',
      icon: const Icon(Icons.share_outlined),
      onSelected: (v) => _share(
        context,
        v == 0
            ? forecastShareText(
                placeName: _place,
                nowHcm: provider.nowHcm,
                hours: hours,
                current: provider.currentWeather,
                formatTempValue: provider.formatTempValue,
              )
            : (hours.isEmpty || planner == null
                  ? null
                  : activityShareText(
                      placeName: _place,
                      activities: planner.favorites,
                      hours: hours,
                      nowHcm: provider.nowHcm,
                      sensitivity: planner.sensitivity,
                    )),
      ),
      itemBuilder: (_) => [
        const PopupMenuItem(value: 0, child: Text('Chia sẻ thời tiết')),
        if (planner != null)
          const PopupMenuItem(
            value: 1,
            child: Text('Chia sẻ gợi ý giờ hoạt động'),
          ),
      ],
    );
  }
}

/// Trang thai khong co du lieu: dang tai / loi / trong.
class _StateView extends StatelessWidget {
  const _StateView({required this.provider, required this.hasDays});

  final WeatherProvider provider;
  final bool hasDays;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final IconData icon;
    final String message;
    if (provider.isLoading) {
      icon = Icons.hourglass_top_rounded;
      message = 'Đang tải dữ liệu…';
    } else if (provider.error != null) {
      icon = Icons.cloud_off_rounded;
      message = provider.error!;
    } else if (hasDays) {
      icon = Icons.event_busy_rounded;
      message =
          'Ngày này không còn trong dữ liệu. Hãy chọn lại từ màn hình chính.';
    } else {
      icon = Icons.inbox_rounded;
      message = 'Chưa có dữ liệu dự báo.';
    }

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSizes.paddingL),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (provider.isLoading)
              const CircularProgressIndicator()
            else
              Icon(
                icon,
                size: AppSizes.iconSizeL,
                color: theme.textTheme.bodySmall?.color,
              ),
            const SizedBox(height: AppSizes.paddingM),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge,
            ),
            if (!provider.isLoading) ...[
              const SizedBox(height: AppSizes.paddingM),
              ElevatedButton.icon(
                onPressed: provider.fetchWeatherData,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Thử lại'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
