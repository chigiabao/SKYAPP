import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/place.dart';
import '../../models/weather_alerts.dart';
import '../../providers/planner_provider.dart';
import '../../providers/preferences_provider.dart';
import '../../providers/weather_provider.dart';
import '../../ui/weather/app_scene.dart';
import '../../ui/weather/design_tokens.dart';
import '../../ui/weather/weather_insights.dart';
import '../../ui/weather/widgets/bottom_pill_bar.dart';
import '../../ui/weather/widgets/home_motion.dart';
import '../../ui/weather/widgets/home_overview.dart';
import '../../ui/weather/widgets/home_skeleton.dart';
import '../../ui/weather/widgets/hourly_strip.dart';
import '../../widgets/ai_forecast_card.dart';
import '../../widgets/ai_unavailable_card.dart';
import '../../utils/haptics.dart';
import '../../widgets/planner_cards.dart';
import '../activities_screen.dart';
import '../ai_verify_screen.dart';
import '../home_screen.dart';
import 'home_current_snapshot.dart';
import 'home_details_grid.dart';
import 'home_header_info.dart';
import 'home_mode_bar.dart';
import 'home_page_parts.dart';
import 'home_places_pager.dart';
import 'home_status.dart';

/// Mot trang dia diem.
class HomeLocationPage extends StatefulWidget {
  const HomeLocationPage({
    super.key,
    required this.location,
    this.label,
    required this.scene,
    required this.entranceAt,
    required this.dismissedAlert,
    required this.onDismissAlert,
    this.dismissedAlertKey,
    this.onDismissAlertKey,
    this.onOpenAlerts,
    this.onCityLongPress,
    required this.onLocations,
    required this.onTrip,
    this.onPrevious,
    this.onNext,
    this.pageIndex = 0,
    this.pageCount = 1,
    this.nextName,
  });

  final Place location;

  /// Nhan dia diem da luu (vd. "Nhà"), hien canh ten phuong.
  final String? label;
  final AppSceneData scene;
  final DateTime? entranceAt;
  final WeatherAlert? dismissedAlert;
  final ValueChanged<WeatherAlert> onDismissAlert;
  final String? dismissedAlertKey;
  final ValueChanged<String>? onDismissAlertKey;
  final VoidCallback? onOpenAlerts;
  final VoidCallback? onCityLongPress;
  final VoidCallback onLocations;
  final VoidCallback onTrip;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  /// Vi tri trang (cham trang + "2/4") va ten dia diem ke tiep.
  final int pageIndex;
  final int pageCount;
  final String? nextName;

  @override
  State<HomeLocationPage> createState() => _LocationPageState();
}

class _LocationPageState extends State<HomeLocationPage> {
  bool _showDetails = false;
  Place get location => widget.location;
  String? get label => widget.label;
  AppSceneData get scene => widget.scene;
  DateTime? get entranceAt => widget.entranceAt;
  WeatherAlert? get dismissedAlert => widget.dismissedAlert;
  String? get dismissedAlertKey => widget.dismissedAlertKey;
  VoidCallback? get onOpenAlerts => widget.onOpenAlerts;
  ValueChanged<WeatherAlert> get onDismissAlert => widget.onDismissAlert;
  ValueChanged<String>? get onDismissAlertKey => widget.onDismissAlertKey;

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<WeatherProvider>();
    final mq = MediaQuery.of(context);
    final compact = mq.size.height <= 700;
    final desktop = mq.size.width >= 1100;
    final rail = mq.textScaler.scale(13) > 19 ? 196.0 : 136.0;
    final width = mq.size.width - (desktop ? rail : 0);
    final active = provider.locationId == location.id;
    final current = active ? provider.currentWeather : null;
    final info = homeHeaderInfo(
      provider,
      current,
      location: location,
      label: label,
      units: PreferencesProvider.unitsOf(context),
    );
    final planner = maybePlanner(context);
    // Cuoi danh sach luon ló ra tren thanh tab + home indicator.
    final bottomSpace = desktop
        ? Space.xl
        : BottomPillBar.reservedHeight(context);
    final events = active && planner != null
        ? planner.alertsFor(
            location.id,
            provider.hourlyForecast,
            provider.nowHcm,
          )
        : const <AlertEvent>[];
    final alert = active && planner == null
        ? weatherAlert(provider.hourlyForecast, nowHcm: provider.nowHcm)
        : null;
    final rain = current == null
        ? null
        : homeRainCard(
            context,
            provider,
            events,
            alert,
            dismissedAlertKey: dismissedAlertKey,
            dismissedAlert: dismissedAlert,
            onOpenAlerts: onOpenAlerts,
            onDismissAlertKey: onDismissAlertKey,
            onDismissAlert: onDismissAlert,
          );
    final forecastError = active ? provider.weatherData?.forecastError : null;
    final aiError = active ? provider.weatherData?.aiError : null;
    final forecast = <Widget>[
      if (provider.hourlyForecast.isNotEmpty)
        HourlyStrip(hours: provider.hourlyForecast),
      if (current != null && provider.dailyForecast.isNotEmpty)
        homeDailyCard(context, provider, current),
      if (provider.hourlyForecast.isEmpty &&
          provider.dailyForecast.isEmpty &&
          provider.weatherData?.forecastError == null)
        HomeGlassBanner(
          icon: Icons.event_busy_outlined,
          message: 'Chưa có dữ liệu dự báo cho địa điểm này.',
          actionLabel: 'Làm mới',
          onAction: provider.isLoading ? null : provider.refreshWeatherData,
        ),
    ];
    final planning = <Widget>[
      if (current != null &&
          planner != null &&
          provider.hourlyForecast.isNotEmpty)
        ActivitySuggestionCard(
          activities: planner.favorites,
          hours: provider.hourlyForecast,
          nowHcm: provider.nowHcm,
          sensitivity: planner.sensitivity,
          onOpen: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => ActivitiesScreen(placeName: location.name),
            ),
          ),
        ),
      if (provider.aiForecast != null && forecastError == null)
        AIForecastCard(
          forecast: provider.aiForecast,
          compact: true,
          onVerify: () => openAIVerify(context),
        )
      else if (current != null && forecastError == null && aiError != null)
        AIUnavailableCard(
          detail: aiError,
          shortRange: true,
          onVerify: () => openAIVerify(context),
        ),
    ];
    final gutter = Space.gutter(width);
    final maxWidth = width >= HomeScreen.twoColumnWidth
        ? 1240.0
        : HomeScreen.maxContentWidth;
    final hPad = width > maxWidth + 2 * gutter
        ? (width - maxWidth) / 2
        : gutter;
    final introduction = <Widget>[
      HomeWeatherOverview(info: info, onTrip: widget.onTrip),
      if (widget.onPrevious != null || widget.onNext != null)
        HomePlacesPager(
          index: widget.pageIndex,
          count: widget.pageCount,
          nextName: widget.nextName,
          onPrevious: widget.onPrevious,
          onNext: widget.onNext,
        ),
      ?rain,
    ];
    final information = <Widget>[
      if (current == null)
        !active || provider.isLoading
            ? const HomeSkeleton()
            : HomeStateCard(provider: provider)
      else ...[
        HomeModeBar(
          showDetails: _showDetails,
          onChanged: (value) => setState(() => _showDetails = value),
          refreshing: provider.isRefreshing,
          onRefresh: provider.isLoading || provider.isRefreshing
              ? null
              : provider.refreshWeatherData,
        ),
        // 503 cua AI dai han: giai thich ngay duoi thanh tab (ca hai che
        // do), khong de trong va khong hien nguyen van loi backend.
        if (forecastError != null)
          AIUnavailableCard(
            detail: forecastError,
            onVerify: () => openAIVerify(context),
          ),
        if (_showDetails)
          HomeDetailsGrid(current: current)
        else ...[
          ...forecast,
          if (width < HomeScreen.twoColumnWidth) ...planning,
        ],
      ],
    ];
    final content = <Widget>[
      if (active) ...homeBanners(provider),
      if (current != null && width >= HomeScreen.twoColumnWidth)
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 4,
              child: _sectionColumn([
                ...introduction,
                if (!_showDetails) ...[
                  HomeCurrentSnapshot(
                    current: current,
                    onShowAll: () => setState(() => _showDetails = true),
                  ),

                  if (planning.isNotEmpty)
                    Semantics(
                      header: true,
                      child: Text(
                        'Kế hoạch hôm nay',
                        style: TypeScale.title3.copyWith(color: Palette.white),
                      ),
                    ),
                  ...planning,
                ],
              ]),
            ),
            const SizedBox(width: Space.xl),
            Expanded(flex: 7, child: _sectionColumn(information)),
          ],
        )
      else ...[
        ...introduction,
        ...information,
      ],
    ];
    final scroll = CustomScrollView(
      key: PageStorageKey('home-${widget.key}'),
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      slivers: [
        SliverAppBar(
          pinned: true,
          automaticallyImplyLeading: false,
          // Nen dac ngay tren Material cua AppBar: noi dung cuon ben duoi
          // khong ve de len ten dia diem/nut (ke ca khi blur khong chay).
          backgroundColor: mq.highContrast
              ? Palette.headerSolid
              : Palette.header,
          scrolledUnderElevation: 0,
          flexibleSpace: mq.highContrast
              ? null
              : ClipRect(
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                    child: const SizedBox.expand(),
                  ),
                ),
          surfaceTintColor: Colors.transparent,
          toolbarHeight: mq.textScaler.scale(18) > 26
              ? mq.textScaler.scale(17) * 2.4 + Space.m
              : compact
              ? Touch.min
              : 52,
          titleSpacing: Space.l,

          title: HomeCityTitle(
            city: info.city,
            onTap: widget.onLocations,
            onLongPress: widget.onCityLongPress,
          ),

          actions: [
            HomeHeaderActions(
              unread: planner?.unreadCount ?? 0,
              onAlerts: planner == null ? null : onOpenAlerts,
            ),
            const HomeSettingsButton(),
            const SizedBox(width: Space.s),
          ],
        ),
        SliverPadding(
          padding: EdgeInsets.fromLTRB(hPad, 0, hPad, bottomSpace),
          sliver: SliverList(
            delegate: SliverChildListDelegate([
              for (var i = 0; i < content.length; i++)
                Padding(
                  padding: EdgeInsets.only(bottom: compact ? Space.s : Space.l),
                  child: StaggerIn(
                    index: i,
                    startedAt: entranceAt,
                    child: content[i],
                  ),
                ),
            ]),
          ),
        ),
      ],
    );
    return RainRefresh(
      onRefresh: withRefreshHaptic(() async {
        await provider.refreshWeatherData();
        return provider.error == null;
      }),
      backgroundColor: scene.theme.gradient.first,
      edgeOffset: mq.padding.top,
      child: ColoredBox(
        // Isolate white text from bright weather scenes without another card.
        color: Colors.black.withValues(alpha: 0.42),
        child: scroll,
      ),
    );
  }

  Widget _sectionColumn(List<Widget> children) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final child in children)
        Padding(
          padding: const EdgeInsets.only(bottom: Space.l),
          child: child,
        ),
    ],
  );
}
