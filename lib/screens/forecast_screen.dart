import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/units.dart';
import '../models/weather.dart';
import '../providers/planner_provider.dart';
import '../providers/preferences_provider.dart';
import '../providers/weather_provider.dart';
import '../services/feedback_service.dart';
import '../services/share_service.dart';
import '../ui/weather/widgets/glass_page.dart';
import '../ui/weather/widgets/ios_page.dart';
import '../ui/weather/design_tokens.dart';
import '../ui/weather/widgets/adaptive_dialog.dart';
import '../widgets/ai_unavailable_card.dart';
import '../widgets/planner_cards.dart';
import 'forecast/forecast_charts.dart';
import '../utils/forecast_format.dart';
import 'forecast/forecast_source.dart';
import 'forecast/forecast_widgets.dart';
import 'feedback_screen.dart';
import '../ui/weather/widgets/ios_toast.dart';
import '../utils/haptics.dart';

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

  /// Cac gio thuoc dung ngay [date] (gio TP.HCM), giu thu tu.
  static List<HourlyForecast> hoursOfDay(
    List<HourlyForecast> hours,
    DateTime date,
  ) => [
    for (final h in hours)
      if (ForecastFormat.sameDay(h.time, date)) h,
  ];

  @override
  State<ForecastScreen> createState() => _ForecastScreenState();
}

class _ForecastScreenState extends State<ForecastScreen> {
  late DateTime _selectedDate = HcmTime.startOfDay(widget.selectedDay.date);

  /// Hieu ung so le chi chay luc mo man; muc cuon toi sau do hien ngay.
  bool _entranceDone = false;

  @override
  void initState() {
    super.initState();
    // Chi cac muc dung o khung hinh dau moi chay hieu ung so le.
    WidgetsBinding.instance.addPostFrameCallback((_) => _entranceDone = true);
  }

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
      const SizedBox(height: Space.l),
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
      ...(provider.weatherData != null
          ? provider.dailyForecast
          : widget.allDays),
    ]..sort((a, b) => a.date.compareTo(b.date));
    final hours = [
      ...(provider.weatherData != null
          ? provider.hourlyForecast
          : widget.hourlyData),
    ]..sort((a, b) => a.time.compareTo(b.time));

    final selectedIndex = days.indexWhere(
      (d) => ForecastFormat.sameDay(d.date, _selectedDate),
    );

    Widget body;
    String title = 'Dự báo chi tiết';
    if (days.isEmpty || selectedIndex < 0) {
      body = SliverFillRemaining(
        hasScrollBody: false,
        child: _StateView(provider: provider, hasDays: days.isNotEmpty),
      );
    } else {
      final day = days[selectedIndex];
      title = ForecastFormat.title(day.date);
      final hPad = iosPageHPad(context);
      body = SliverPadding(
        padding: EdgeInsets.fromLTRB(
          hPad,
          Space.s,
          hPad,
          Space.xxl + MediaQuery.paddingOf(context).bottom,
        ),
        sliver: SliverList.list(
          children: _stagger([
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
              const SizedBox(height: Space.l),
            ],
            DayPicker(
              days: days,
              selectedIndex: selectedIndex,
              nowHcm: now,
              onSelect: (i) => _select(days, i),
            ),
            const SizedBox(height: Space.l),
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
            const SizedBox(height: Space.l),
            if (day.confidence == ForecastConfidence.low ||
                day.confidence == ForecastConfidence.medium) ...[
              DayConfidenceNotice(day: day),
              const SizedBox(height: Space.l),
            ],
            DaySummaryCard(day: day, hours: hours),
            ..._activitySection(context, day, hours, now),
            ..._hourlySection(day, hours, now, provider),
            ..._dailySection(context, days, selectedIndex, now, provider),
          ]),
        ),
      );
    }

    return IosPageScaffold(
      title: title,
      onRefresh: withRefreshHaptic(() async {
        await provider.fetchWeatherData();
        return provider.error == null;
      }),
      actions: [
        IosBarButton(
          tooltip: 'Báo dự báo sai',
          icon: CupertinoIcons.exclamationmark_bubble,
          onPressed: () => _openWrongForecast(context, provider, hours),
        ),
        _ShareMenu(provider: provider, hours: hours),
        if (provider.isLoading)
          const SizedBox(
            width: 44,
            height: 44,
            child: Center(
              child: CupertinoActivityIndicator(color: Palette.white),
            ),
          )
        else
          IosBarButton(
            tooltip: 'Làm mới',
            icon: CupertinoIcons.refresh,
            onPressed: provider.fetchWeatherData,
          ),
      ],
      slivers: [body],
    );
  }

  /// Boc tung muc trong [_Entrance] (fade + truot nhe, tre 45 ms moi muc).
  List<Widget> _stagger(List<Widget> items) => [
    for (var i = 0; i < items.length; i++)
      _Entrance(index: _entranceDone ? null : i, child: items[i]),
  ];

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
    // Moi ngay (ke ca hom nay) chi hien cac gio cua chinh ngay do: du lieu
    // 48 gio -> phan sau nua dem thuoc ve "Ngày mai".
    final shown = ForecastScreen.hoursOfDay(hours, day.date);
    final String subtitle = shown.isEmpty
        ? ''
        : 'Có số liệu ${ForecastFormat.hourMinute(shown.first.time)}–'
              '${ForecastFormat.hourMinute(shown.last.time)}'
              '${shown.length < 24 ? ' (các giờ còn lại chưa có)' : ''}';

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
    final units = PreferencesProvider.unitsOf(context);

    return [
      ForecastSectionTitle('Nhiệt độ theo giờ', subtitle: subtitle),
      HourlyTemperatureChart(hours: shown, nowIndex: nowIndex, units: units),
      ForecastSectionTitle('Lượng mưa theo giờ', subtitle: _rainSummary(shown)),
      HourlyRainChart(hours: shown, nowIndex: nowIndex),
      ForecastSectionTitle(
        'Gió theo giờ (${units.windAxisUnit.label})',
        subtitle: 'Tốc độ gió trung bình và gió giật trong giờ.',
      ),
      if (shown.any((h) => h.windSpeed != null || h.windGusts != null))
        HourlyWindChart(hours: shown, nowIndex: nowIndex)
      else
        const ForecastMessageCard(
          icon: Icons.air_rounded,
          message: 'Chưa có số liệu gió theo giờ.',
        ),
      const SizedBox(height: Space.l),
      HourlyTable(
        hours: shown,
        nowIndex: nowIndex,
        place: provider.place,
        units: units,
      ),
    ];
  }

  /// "5 giờ có mưa · tổng 12 mm" (gio co >= 0,1 mm); chua co so lieu -> null.
  String? _rainSummary(List<HourlyForecast> shown) {
    final mms = [for (final h in shown) ?HourlyRainChart.mmOf(h)];
    if (mms.isEmpty) return null;
    final rainy = mms.where((v) => v >= 0.1).length;
    final total = mms.fold<double>(0, (a, b) => a + b);
    final coverage = mms.length < shown.length
        ? 'Chỉ có lượng mưa cho ${mms.length}/${shown.length} giờ. '
        : '';
    // Ghi ro khung gio de khong nham voi "Tổng mưa cả ngày" o the tom tat.
    final window = shown.length >= 24
        ? 'Cả ngày'
        : '${ForecastFormat.hourMinute(shown.first.time)}–'
              '${ForecastFormat.hourMinute(shown.last.time)}';
    if (rainy == 0) {
      return '$coverage$window: không có giờ nào mưa đáng kể (≥ 0,1 mm)'
          '${coverage.isEmpty ? '.' : ' trong các giờ có số liệu.'}';
    }
    return '$coverage$window: $rainy giờ có mưa · tổng '
        '${PreferencesProvider.unitsOf(context).rainText(total)}. '
        'Chạm cột để xem chi tiết.';
  }

  List<Widget> _dailySection(
    BuildContext context,
    List<DailyForecast> days,
    int selectedIndex,
    DateTime now,
    WeatherProvider provider,
  ) {
    final p = ChartPalette(context);
    final units = PreferencesProvider.unitsOf(context);
    final inch = units.precip == PrecipUnit.inch;
    final windMissing = days.any((d) => d.windSpeed == null);
    final hasGusts = days.any((d) => d.windGusts != null);
    final gustColor = p.isDark ? Tones.gustOnDark : Tones.amberOnLight;
    final hint = 'Chạm vào một ngày để xem chi tiết.';
    return [
      ForecastSectionTitle('Nhiệt độ ${days.length} ngày', subtitle: hint),
      DailyTemperatureChart(
        days: days,
        selectedIndex: selectedIndex,
        nowHcm: provider.nowHcm,
        units: units,
        onSelect: (i) => _select(days, i),
      ),
      ForecastSectionTitle(
        'Tổng lượng mưa theo ngày (${units.precip.label})',
        subtitle: 'Cộng dồn lượng mưa cả ngày.',
      ),
      DailyBarChart(
        days: days,
        values: [for (final d in days) d.precipitationMm],
        selectedIndex: selectedIndex,
        nowHcm: now,
        color: p.rain,
        unitSuffix: ' ${units.precip.label}',
        toAxis: (mm) => inch ? UnitConvert.mmToInch(mm) : mm,
        format: units.rainText,
        semanticsLabel: 'Biểu đồ tổng lượng mưa ${days.length} ngày',
        onSelect: (i) => _select(days, i),
      ),
      ForecastSectionTitle(
        'Gió mạnh nhất (${PreferencesProvider.unitsOf(context).windAxisUnit.label})',
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
        unitSuffix:
            ' ${PreferencesProvider.unitsOf(context).windAxisUnit.label}',
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

  /// Ten that cua dia diem dang xem (khong dung ten thanh pho co dinh).
  String get _place => provider.place.name;

  Future<void> _share(BuildContext context, String? text) async {
    final overlay = iosToastOverlay(context);
    if (text == null) {
      showIosToastIn(overlay, 'Chưa có dữ liệu để chia sẻ.');
      return;
    }
    final r = await shareOrCopy(text);
    if (r == ShareOutcome.shared) return;
    showIosToastIn(
      overlay,
      r == ShareOutcome.copied
          ? 'Thiết bị không hỗ trợ chia sẻ. Đã sao chép nội dung vào bộ nhớ tạm.'
          : 'Không chia sẻ được.',
      tone: r == ShareOutcome.copied
          ? IosToastTone.success
          : IosToastTone.error,
    );
  }

  @override
  Widget build(BuildContext context) {
    final planner = maybePlanner(context);
    final units = PreferencesProvider.unitsOf(context);
    Future<void> pick() async {
      final v = await showAppActionSheet<int>(
        context,
        title: 'Chia sẻ',
        actions: [
          const AppDialogAction(
            label: 'Chia sẻ thời tiết',
            value: 0,
            icon: CupertinoIcons.cloud_sun,
          ),
          if (planner != null)
            const AppDialogAction(
              label: 'Chia sẻ gợi ý giờ hoạt động',
              value: 1,
              icon: CupertinoIcons.sportscourt,
            ),
        ],
      );
      if (v == null || !context.mounted) return;
      await _share(
        context,
        v == 0
            ? forecastShareText(
                placeName: _place,
                nowHcm: provider.nowHcm,
                hours: hours,
                current: provider.currentWeather,
                formatTempValue: units.tempNumber,
                replay: provider.isReplay,
              )
            : (hours.isEmpty || planner == null
                  ? null
                  : activityShareText(
                      placeName: _place,
                      activities: planner.favorites,
                      hours: hours,
                      nowHcm: provider.nowHcm,
                      sensitivity: planner.sensitivity,
                      replay: provider.isReplay,
                      units: units,
                    )),
      );
    }

    return IosBarButton(
      tooltip: 'Chia sẻ',
      icon: CupertinoIcons.share,
      onPressed: pick,
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
    } else if (provider.weatherData?.forecastError != null) {
      icon = Icons.model_training_rounded;
      message = aiUnavailableMessage(provider.weatherData!.forecastError);
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
        padding: const EdgeInsets.all(Space.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (provider.isLoading)
              const CupertinoActivityIndicator(radius: 14)
            else
              Icon(
                icon,
                size: IconSizes.state,
                color: theme.textTheme.bodySmall?.color,
              ),
            const SizedBox(height: Space.l),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge,
            ),
            if (!provider.isLoading) ...[
              const SizedBox(height: Space.l),
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

/// Hien so le khi mo man: fade + truot len 12 px. Giam chuyen dong ->
/// hien ngay. [index] null = da mo xong, hien ngay (khong doi cau truc cay).
class _Entrance extends StatelessWidget {
  const _Entrance({required this.index, required this.child});

  final int? index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (chartMotionOff(context)) return child;
    final i = index;
    final delay = i == null ? 0 : 45 * i.clamp(0, 8);
    const run = 320;
    final total = run + delay;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: i == null ? 1 : 0, end: 1),
      duration: Duration(milliseconds: total),
      curve: Interval(delay / total, 1, curve: Curves.easeOutCubic),
      child: child,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, (1 - t) * 12),
          child: child,
        ),
      ),
    );
  }
}
