import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../config/api_config.dart';
import '../models/place.dart';
import '../models/weather.dart';
import '../models/weather_alerts.dart';
import '../providers/location_provider.dart';
import '../providers/planner_provider.dart';
import '../providers/preferences_provider.dart';
import '../providers/weather_provider.dart';
import '../ui/weather/app_scene.dart';
import '../ui/weather/debug/weather_simulator_screen.dart';
import '../ui/weather/design_tokens.dart';
import '../ui/weather/glass_ink.dart';
import '../ui/weather/sun_times.dart';
import '../ui/weather/weather_background.dart';
import '../ui/weather/weather_insights.dart';
import '../ui/weather/widgets/aqi_card.dart';
import '../ui/weather/widgets/bottom_pill_bar.dart';
import '../ui/weather/widgets/collapsing_header.dart';
import '../ui/weather/widgets/daily_forecast_list.dart';
import '../ui/weather/widgets/glass_card.dart';
import '../ui/weather/widgets/glass_page.dart';
import '../ui/weather/widgets/home_motion.dart';
import '../ui/weather/widgets/home_overview.dart';
import '../ui/weather/widgets/home_skeleton.dart';
import '../ui/weather/widgets/hourly_strip.dart';
import '../ui/weather/widgets/metric_tile.dart';
import '../ui/weather/widgets/rain_timeline_card.dart';
import '../ui/weather/widgets/uv_card.dart';
import '../utils/formatters.dart';
import '../widgets/ai_forecast_card.dart';
import '../widgets/planner_cards.dart';
import 'activities_screen.dart';
import 'alerts_screen.dart';
import 'forecast/forecast_format.dart';
import 'forecast_screen.dart';
import 'locations_screen.dart';
import 'settings_screen.dart';
import 'trip_screen.dart';

/// Adaptive weather workspace with location paging and explicit navigation.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.locations});

  /// Danh sach dia diem; null -> man hinh tu tao (test / chay don le).
  final LocationProvider? locations;

  /// Chieu rong toi da cua cot noi dung (dien thoai / may tinh bang).
  static const double maxContentWidth = Space.contentMaxWidth;

  /// Tu chieu rong nay: hai cot (dau trang + theo gio + 7 ngay | chi tiet).
  static const double twoColumnWidth = 900;

  /// Nen dong con chay? Dung ticker khi dau trang (hero) da cuon han khoi
  /// man hinh (> 70 % chieu cao khung nhin) de tiet kiem pin.
  static bool backgroundActiveAt(double pixels, double viewport) =>
      pixels < viewport * 0.7;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final SplashRegistry _splash = SplashRegistry();
  final BackdropKey _bottomBarBackdropKey = BackdropKey();
  late final LocationProvider _lp = widget.locations ?? LocationProvider();
  late final PageController _pages = PageController(
    initialPage: _lp.selectedIndex,
  );
  bool _splashOn = false;
  int _homeRevision = 0;

  /// Nen dong dang chay (false khi hero da cuon khoi man hinh).
  bool _bgActive = true;
  bool _splashScheduled = false;

  /// Thoi diem lan dau co du lieu: the hien so le chi trong khoang ngan sau
  /// moc nay (khong chay lai khi rebuild / cuon).
  DateTime? _entranceAt;

  /// Canh bao nguoi dung da dong (hien lai neu canh bao moi khac).
  WeatherAlert? _dismissedAlert;

  /// Khoa canh bao (bo luat tren thiet bi) nguoi dung da dong o banner.
  String? _dismissedAlertKey;

  WeatherProvider? _wp;

  /// Du lieu da danh gia canh bao gan nhat (tranh danh gia lap).
  WeatherData? _recorded;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final wp = context.read<WeatherProvider>();
      wp.setLocation(_lp.selectedLocationId, fetch: false);
      wp.initialize();
      _wp = wp;
      wp.addListener(_onWeather);
      _lp.addListener(_onLocations);
      _lp.loadLocal().then((_) {
        if (!mounted) return;
        _syncPage();
        _lp.refreshRemote(at: wp.isReplay ? wp.replayAt : null);
      });
    });
  }

  /// Danh sach trang doi (them / xoa / sap xep / GPS): giu trang dang chon.
  /// Du lieu moi cua dia diem dang xem -> danh gia canh bao + ghi thong bao
  /// (chong trung trong PlannerProvider). Xem lai: chi tinh, khong ghi.
  void _onWeather() {
    final wp = _wp;
    if (!mounted || wp == null) return;
    // Defer cache side effects until revalidation settles, including offline.
    if (wp.isFromCache && wp.isRefreshing) return;
    final planner = maybePlanner(context, listen: false);
    final data = wp.weatherData;
    if (planner == null || data == null || identical(data, _recorded)) return;
    _recorded = data;
    planner.record(
      wp.locationId,
      _lp.placeById(wp.locationId).name,
      wp.hourlyForecast,
      wp.nowHcm,
      replay: wp.isReplay,
    );
  }

  void _openAlerts() {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => AlertsScreen(locations: _lp)));
  }

  void _onLocations() {
    if (!mounted) return;
    setState(() {});
    _syncPage();
  }

  void _syncPage() {
    final wp = context.read<WeatherProvider>();
    final id = _lp.selectedLocationId;
    if (wp.locationId != id) wp.setLocation(id);
    final i = _lp.selectedIndex;
    if (_pages.hasClients && (_pages.page?.round() ?? i) != i) {
      _pages.jumpToPage(i);
    }
  }

  void _onPageChanged(int i) {
    HapticFeedback.selectionClick();
    // Trang moi bat dau o dau trang.
    if (!_bgActive) setState(() => _bgActive = true);
    _lp.select(i);
    final id = _lp.selectedLocationId;
    final wp = context.read<WeatherProvider>();
    if (wp.locationId != id) wp.setLocation(id);
  }

  void _goTo(int i) {
    _lp.select(i);
    if (_pages.hasClients) {
      if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
        _pages.jumpToPage(i);
      } else {
        _pages.animateToPage(i, duration: Motion.medium, curve: Motion.enter);
      }
    }
  }

  Future<void> _openLocations() async {
    final i = await Navigator.of(context).push<int>(
      MaterialPageRoute(builder: (_) => LocationsScreen(locations: _lp)),
    );
    if (i != null && mounted) _goTo(i);
  }

  Future<void> _openMap() async {
    final id = await openLocationMap(
      context,
      locations: _lp,
      focusLocationId: _lp.selectedLocationId,
    );
    if (id == null || !mounted) return;
    if (!_lp.selectLocation(id)) {
      _lp.addSaved(id);
      _lp.selectLocation(id);
    }
    _goTo(_lp.selectedIndex);
  }

  @override
  void dispose() {
    _wp?.removeListener(_onWeather);
    _lp.removeListener(_onLocations);
    if (widget.locations == null) _lp.dispose();
    _pages.dispose();
    _splash.dispose();
    super.dispose();
  }

  /// Cap nhat vi tri the cho giot mua sau khung hinh hien tai.
  void _scheduleSplashUpdate() {
    if (!_splashOn || _splashScheduled) return;
    _splashScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _splashScheduled = false;
      if (mounted && _splashOn) _splash.update();
    });
  }

  void _openSimulator(AppSceneData scene) {
    final o = maybeSceneOverride(context, listen: false);
    if (!WeatherSimulatorScreen.available || o == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            WeatherSimulatorScreen(sceneOverride: o, initialScene: scene.scene),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scene = AppScene.of(context);
    final st = scene.theme;
    final appTheme = Theme.of(context);
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final hasData = context.select<WeatherProvider, bool>(
      (p) => p.currentWeather != null,
    );
    // Mini "mưa 2 giờ tới" tren nut Ra ngoai.
    final rain2h = context.select<WeatherProvider, int?>(
      (p) => maxRainPercent(p.hourlyForecast, nowHcm: p.nowHcm),
    );
    final pages = _lp.pages;
    final desktop = MediaQuery.sizeOf(context).width >= 1100;
    final railWidth = MediaQuery.textScalerOf(context).scale(13) > 19
        ? 180.0
        : 120.0;

    if (_entranceAt == null && hasData) _entranceAt = DateTime.now();

    _splashOn = sceneHasSplashes(scene.scene) && !reduceMotion;
    if (_splashOn) {
      _scheduleSplashUpdate();
    } else {
      _splash.clear();
    }

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: st.statusBar,
      child: AppThemeScope(
        theme: appTheme,
        child: Scaffold(
          backgroundColor: st.gradient.last,
          body: WeatherBackground(
            key: _splash.backgroundKey,
            scene: scene.scene,
            isDay: scene.isDay,
            windSpeedKmh: scene.windSpeedKmh,
            intensity: scene.intensity,
            transitionDuration: Motion.scene,
            active: _bgActive,
            // Than sang goc tren phai, ben trai nut Cai dat.
            celestial: CelestialPlacement.topRight(
              MediaQuery.sizeOf(context).width,
              top: MediaQuery.paddingOf(context).top,
            ),
            splashTargets: _splash.rects,
            splashEdge: SplashEdge.top,
            child: Theme(
              data: glassThemeFor(st, appTheme),
              child: SplashTargets(
                registry: _splash,
                child: NotificationListener<Notification>(
                  onNotification: (n) {
                    if (n is ScrollNotification ||
                        n is SizeChangedLayoutNotification) {
                      _scheduleSplashUpdate();
                    }
                    if (n is ScrollUpdateNotification &&
                        n.metrics.axis == Axis.vertical) {
                      final on = HomeScreen.backgroundActiveAt(
                        n.metrics.pixels,
                        n.metrics.viewportDimension,
                      );
                      if (on != _bgActive) setState(() => _bgActive = on);
                    }
                    return false;
                  },
                  child: Stack(
                    children: [
                      Padding(
                        padding: EdgeInsets.only(
                          left: desktop ? railWidth + Space.l : 0,
                        ),
                        child: PageView.builder(
                          controller: _pages,
                          itemCount: pages.length,
                          onPageChanged: _onPageChanged,
                          itemBuilder: (context, i) => _LocationPage(
                            key: ValueKey(
                              '${pages[i].locationId}-$_homeRevision',
                            ),
                            location: _lp.placeById(pages[i].locationId),
                            label: _lp.labelFor(pages[i]),
                            scene: scene,
                            entranceAt: _entranceAt,
                            dismissedAlert: _dismissedAlert,
                            onDismissAlert: (a) =>
                                setState(() => _dismissedAlert = a),
                            dismissedAlertKey: _dismissedAlertKey,
                            onDismissAlertKey: (k) =>
                                setState(() => _dismissedAlertKey = k),
                            onOpenAlerts: _openAlerts,
                            onLocations: _openLocations,
                            onTrip: () => openTripScreen(
                              context,
                              locations: _lp,
                              quickStart: true,
                            ),
                            onPrevious: i > 0 ? () => _goTo(i - 1) : null,
                            onNext: i + 1 < pages.length
                                ? () => _goTo(i + 1)
                                : null,
                            onCityLongPress:
                                kDebugMode &&
                                    maybeSceneOverride(context) != null
                                ? () => _openSimulator(scene)
                                : null,
                          ),
                        ),
                      ),
                      Positioned(
                        left: desktop ? Space.s : 0,
                        right: desktop ? null : 0,
                        top: desktop ? 0 : null,
                        bottom: 0,
                        width: desktop ? railWidth : null,
                        child: SafeArea(
                          top: desktop,
                          minimum: const EdgeInsets.only(bottom: Space.s),
                          child: SingleChildScrollView(
                            child: Align(
                              alignment: desktop
                                  ? Alignment.topCenter
                                  : Alignment.bottomCenter,
                              child: ConstrainedBox(
                                constraints: BoxConstraints(
                                  maxWidth: desktop ? railWidth : 640,
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: Space.l,
                                  ),
                                  // This overlay can overlap the scrolling glass.
                                  child: BackdropGroup(
                                    backdropKey: _bottomBarBackdropKey,
                                    child: BottomPillBar(
                                      vertical: desktop,
                                      onHome: () => setState(() {
                                        _homeRevision++;
                                        _bgActive = true;
                                      }),
                                      pageCount: pages.length,
                                      currentPage: _lp.selectedIndex,
                                      currentLocationIndex: pages.indexWhere(
                                        (p) => p.isCurrentLocation,
                                      ),
                                      onMap: _openMap,
                                      onTrip: () => openTripScreen(
                                        context,
                                        locations: _lp,
                                        quickStart: true,
                                      ),
                                      tripRainPercent: rain2h,
                                      onLocations: _openLocations,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Mot trang dia diem.
class _LocationPage extends StatefulWidget {
  const _LocationPage({
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

  @override
  State<_LocationPage> createState() => _LocationPageState();
}

class _LocationPageState extends State<_LocationPage> {
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
    final desktop = mq.size.width >= 1100;
    final rail = mq.textScaler.scale(13) > 19 ? 196.0 : 136.0;
    final width = mq.size.width - (desktop ? rail : 0);
    final active = provider.locationId == location.id;
    final current = active ? provider.currentWeather : null;
    final info = _headerInfo(provider, current);
    final experimentalForecast =
        active &&
        (provider.hourlyForecast.any((hour) => hour.source == DataSource.ai) ||
            provider.dailyForecast.any((day) => day.source == DataSource.ai));
    final planner = maybePlanner(context);
    final bottomSpace = desktop
        ? Space.xl
        : BottomPillBar.heightFor(
                (width > 640 ? 640 : width) - 2 * Space.l,
                mq.textScaler,
              ) +
              Space.xl +
              mq.padding.bottom;
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
        : _rainCard(context, provider, events, alert);
    final forecast = <Widget>[
      if (provider.hourlyForecast.isNotEmpty)
        HourlyStrip(hours: provider.hourlyForecast),
      if (current != null && provider.dailyForecast.isNotEmpty)
        _daily(context, provider, current),
      if (provider.hourlyForecast.isEmpty &&
          provider.dailyForecast.isEmpty &&
          provider.weatherData?.forecastError == null)
        _GlassBanner(
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
      if (provider.aiForecast != null &&
          provider.weatherData?.forecastError == null)
        AIForecastCard(forecast: provider.aiForecast),
    ];
    final gutter = Space.gutter(width);
    final maxWidth = width >= HomeScreen.twoColumnWidth
        ? 1240.0
        : HomeScreen.maxContentWidth;
    final hPad = width > maxWidth + 2 * gutter
        ? (width - maxWidth) / 2
        : gutter;
    final content = <Widget>[
      if (active) ..._banners(provider),
      HomeWeatherOverview(info: info, onTrip: widget.onTrip),
      if (widget.onPrevious != null || widget.onNext != null)
        Row(
          children: [
            const Expanded(
              child: Text(
                'Địa điểm đã lưu',
                style: TextStyle(color: Palette.white, fontSize: 14),
              ),
            ),
            IconButton(
              tooltip: 'Địa điểm trước',
              onPressed: widget.onPrevious,
              icon: const Icon(Icons.chevron_left_rounded),
            ),
            IconButton(
              tooltip: 'Địa điểm tiếp theo',
              onPressed: widget.onNext,
              icon: const Icon(Icons.chevron_right_rounded),
            ),
          ],
        ),
      ?rain,
      if (current == null)
        !active || provider.isLoading
            ? const HomeSkeleton()
            : _StateCard(provider: provider)
      else ...[
        if (!_showDetails && experimentalForecast)
          Semantics(
            container: true,
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'AI thử nghiệm',
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.5,
                    fontWeight: FontWeight.w700,
                    color: Palette.white,
                  ),
                ),
                Text(
                  'Dự báo xa còn sai số; không phải cảnh báo chính thức.',
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.5,
                    color: Palette.white,
                  ),
                ),
              ],
            ),
          ),
        Row(
          children: [
            Expanded(
              child: SegmentedButton<bool>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(
                    value: false,
                    label: Text('Dự báo', textAlign: TextAlign.center),
                  ),
                  ButtonSegment(
                    value: true,
                    label: Text('Điều kiện', textAlign: TextAlign.center),
                  ),
                ],
                selected: {_showDetails},
                onSelectionChanged: (value) =>
                    setState(() => _showDetails = value.first),
                style: SegmentedButton.styleFrom(
                  selectedBackgroundColor: Palette.white,
                  selectedForegroundColor: Palette.onAlert,
                  foregroundColor: Palette.white,
                  minimumSize: const Size(48, 48),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 12,
                  ),
                  textStyle: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            const SizedBox(width: Space.s),
            IconButton(
              tooltip: provider.isRefreshing
                  ? 'Đang cập nhật'
                  : 'Làm mới thời tiết',
              onPressed: provider.isLoading || provider.isRefreshing
                  ? null
                  : provider.refreshWeatherData,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        if (_showDetails)
          _DetailsGrid(current: current)
        else if (width >= HomeScreen.twoColumnWidth)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 7, child: _sectionColumn(forecast)),
              const SizedBox(width: Space.xl),
              Expanded(
                flex: 4,
                child: _sectionColumn([
                  _currentSnapshot(context, provider, current),
                  if (planning.isNotEmpty)
                    Semantics(
                      header: true,
                      child: const Text(
                        'Kế hoạch hôm nay',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                          color: Palette.white,
                        ),
                      ),
                    ),
                  ...planning,
                ]),
              ),
            ],
          )
        else ...[
          ...forecast,
          ...planning,
        ],
      ],
    ];
    final scroll = CustomScrollView(
      key: PageStorageKey('home-${widget.key}'),
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverAppBar(
          pinned: true,
          automaticallyImplyLeading: false,
          backgroundColor: const Color(0xF21C252C),
          surfaceTintColor: Colors.transparent,
          toolbarHeight: mq.textScaler.scale(18) > 26 ? 88 : 64,
          titleSpacing: Space.l,
          title: Tooltip(
            message: info.city,
            child: Semantics(
              button: true,
              label: 'Chọn địa điểm: ${info.city}',
              excludeSemantics: true,
              onTap: widget.onLocations,
              child: InkWell(
                onTap: widget.onLocations,
                onLongPress: widget.onCityLongPress,
                borderRadius: BorderRadius.circular(8),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: Touch.min),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          info.city,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                            color: Palette.white,
                          ),
                        ),
                      ),
                      const Icon(
                        Icons.expand_more_rounded,
                        color: Palette.white,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          actions: [
            _HeaderActions(
              unread: planner?.unreadCount ?? 0,
              onAlerts: planner == null ? null : onOpenAlerts,
            ),
            const _SettingsButton(),
            const SizedBox(width: Space.s),
          ],
        ),
        SliverPadding(
          padding: EdgeInsets.fromLTRB(hPad, 0, hPad, bottomSpace),
          sliver: SliverList(
            delegate: SliverChildListDelegate([
              for (var i = 0; i < content.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: Space.l),
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
      onRefresh: provider.refreshWeatherData,
      backgroundColor: scene.theme.gradient.first,
      edgeOffset: mq.padding.top,
      child: ColoredBox(
        // Isolate white text from bright weather scenes without another card.
        color: Colors.black.withValues(alpha: 0.56),
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

  Widget _currentSnapshot(
    BuildContext context,
    WeatherProvider provider,
    CurrentWeather current,
  ) {
    final units = PreferencesProvider.unitsOf(context);
    final visible =
        PreferencesProvider.maybeOf(context)?.visibleMetrics ??
        HomeMetric.values;
    final rows = [
      (
        HomeMetric.feelsLike,
        Icons.thermostat_outlined,
        'Cảm giác như',
        current.feelsLike == null
            ? kNoData
            : provider.formatTemperature(current.feelsLike!),
      ),
      (
        HomeMetric.wind,
        Icons.air_rounded,
        'Gió',
        units.windText(current.windSpeed),
      ),
      (
        HomeMetric.humidity,
        Icons.water_drop_outlined,
        'Độ ẩm',
        current.humidity == null
            ? kNoData
            : WeatherFormat.percent(current.humidity),
      ),
    ].where((row) => visible.contains(row.$1));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: const Text(
            'Điều kiện hiện tại',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: Palette.white,
            ),
          ),
        ),
        const SizedBox(height: Space.m),
        for (final row in rows) ...[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Space.m),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    ExcludeSemantics(
                      child: Icon(row.$2, size: 20, color: Palette.white),
                    ),
                    const SizedBox(width: Space.s),
                    Expanded(
                      child: Text(
                        row.$3,
                        style: const TextStyle(
                          fontSize: 15,
                          color: Palette.white,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: Space.s),
                Text(
                  row.$4,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                    fontFeatures: TypeScale.tabular,
                    color: Palette.white,
                  ),
                ),
              ],
            ),
          ),
          const Divider(color: Palette.divider, height: 1),
        ],
        const SizedBox(height: Space.s),
        TextButton.icon(
          onPressed: () => setState(() => _showDetails = true),
          icon: const Icon(Icons.arrow_forward_rounded),
          label: const Text('Tất cả chỉ số'),
          style: TextButton.styleFrom(
            foregroundColor: Palette.white,
            minimumSize: const Size(48, 48),
          ),
        ),
      ],
    );
  }

  /// The "dòng thời gian mưa" (thay banner canh bao): hien khi co canh bao
  /// chua dong hoac co gio mua >= 30 % trong 24 gio toi. Cham -> man Canh bao.
  Widget? _rainCard(
    BuildContext context,
    WeatherProvider provider,
    List<AlertEvent> events,
    WeatherAlert? alert,
  ) {
    final slots = rainTimeline(
      provider.hourlyForecast,
      nowHcm: provider.nowHcm,
    );
    if (slots.isEmpty) return null;
    final hasRain = slots.any((s) => s.p >= 0.3 || s.thunder);
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
          : 'Mưa ${slots.length} giờ tới',
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

  Widget _daily(
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

  List<Widget> _banners(WeatherProvider provider) => [
    if (provider.weatherData?.forecastError case final String error)
      _GlassBanner(
        icon: Icons.warning_amber_rounded,
        message: 'Dự báo mô hình không sẵn sàng. $error',
        actionLabel: 'Làm mới',
        onAction: provider.isLoading || provider.isRefreshing
            ? null
            : provider.refreshWeatherData,
      ),
    if (provider.notice != null)
      _GlassBanner(
        icon: Icons.info_outline_rounded,
        message: provider.notice!,
        actionLabel: 'Đóng',
        onAction: provider.clearNotice,
      ),
    if (provider.error != null && provider.weatherData != null)
      _GlassBanner(
        icon: Icons.cloud_off_outlined,
        message: provider.error!,
        actionLabel: 'Thử lại',
        onAction: provider.isLoading ? null : provider.refreshWeatherData,
      ),
  ];

  String get _detail {
    final l = label;
    final d = friendlyRegion(location.detail);
    return l == null ? d : '$l · $d';
  }

  WeatherHeaderInfo _headerInfo(WeatherProvider provider, CurrentWeather? c) {
    if (c == null) {
      return WeatherHeaderInfo(city: location.name, detail: _detail);
    }
    String t(double v) => '${provider.formatTempValue(v)}°';
    final today = provider.todayForecast;
    final summary = heroRainSummary(
      provider.hourlyForecast,
      nowHcm: provider.nowHcm,
    );
    final hiLo = [
      if (today != null) 'Cao ${t(today.tempMax)} · Thấp ${t(today.tempMin)}',
      if (c.feelsLike != null) 'Cảm giác ${t(c.feelsLike!)}',
    ];
    final updatedAt = c.lastUpdated;
    final sameDay = ForecastFormat.sameDay(updatedAt, provider.nowHcm);
    final cachedAt = provider.cachedAt;
    return WeatherHeaderInfo(
      city: location.name,
      detail: _detail,
      temperature: t(c.temperature),
      condition: c.condition.description,
      // Mot dong: Cao · Thap · Cam giac.
      highLow: hiLo.isEmpty ? null : hiLo.join(' · '),
      today: summary,
      todayRain:
          summary != null &&
          !summary.contains('không mưa') &&
          !summary.startsWith('Không mưa'),
      refreshing: provider.isRefreshing && provider.isFromCache,
      updated: provider.isRefreshing && provider.isFromCache && cachedAt != null
          ? 'Cập nhật lúc ${DateFormat('HH:mm').format(cachedAt)}'
          : 'Cập nhật ${DateFormat(sameDay ? 'HH:mm' : 'dd/MM HH:mm').format(updatedAt)}',
      isStale: provider.isStale,
      sourceLabel: c.source == null ? null : 'Nguồn: ${c.source!.label}',
      cachedNote: provider.isFromCache && cachedAt != null
          ? 'Đã lưu ${DateFormat('dd/MM HH:mm').format(cachedAt)}'
          : null,
      semanticsTemp:
          'Nhiệt độ hiện tại: ${provider.formatTemperature(c.temperature)}',
    );
  }
}

/// Vung truoc sap nhap ("TP.HCM cũ") -> "Khu vực TP.HCM" de nguoi dung de
/// hieu; chuoi khac giu nguyen.
String friendlyRegion(String region) {
  final m = RegExp(r'^(.+?)\s+cũ$').firstMatch(region.trim());
  return m == null ? region : 'Khu vực ${m.group(1)}';
}

/// Nut Canh bao (trai thanh tren). Lam moi: keo de lam moi.
class _HeaderActions extends StatelessWidget {
  const _HeaderActions({this.unread = 0, this.onAlerts});

  /// So thong bao chua doc (man Canh bao).
  final int unread;
  final VoidCallback? onAlerts;

  @override
  Widget build(BuildContext context) {
    if (onAlerts == null) return const SizedBox(width: Touch.min);
    return GlassIconButton(
      tooltip: unread > 0 ? 'Cảnh báo, $unread thông báo mới' : 'Cảnh báo',
      icon: unread > 0
          ? Icons.notifications_active_outlined
          : Icons.notifications_none_rounded,
      onPressed: onAlerts,
    );
  }
}

/// Nut Cai dat (phai thanh tren).
class _SettingsButton extends StatelessWidget {
  const _SettingsButton();

  @override
  Widget build(BuildContext context) {
    return GlassIconButton(
      tooltip: 'Cài đặt',
      icon: Icons.settings_outlined,
      onPressed: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const SettingsScreen()),
      ),
    );
  }
}

/// Actionable status band, separate from the weather summary.
class _GlassBanner extends StatelessWidget {
  const _GlassBanner({
    required this.icon,
    required this.message,
    required this.actionLabel,
    required this.onAction,
  });

  final IconData icon;
  final String message;
  final String actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xF2262C30),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.all(Space.l),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                ExcludeSemantics(child: Icon(icon, color: Palette.stale)),
                const SizedBox(width: Space.m),
                Expanded(
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      message,
                      style: const TextStyle(
                        fontSize: 15,
                        height: 1.5,
                        color: Palette.white,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: onAction,
                style: TextButton.styleFrom(
                  minimumSize: const Size(Touch.min, Touch.min),
                  foregroundColor: Palette.white,
                ),
                child: Text(actionLabel),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Chua co du lieu: dang tai / loi / trong.
class _StateCard extends StatelessWidget {
  const _StateCard({required this.provider});

  final WeatherProvider provider;

  @override
  Widget build(BuildContext context) {
    if (provider.isLoading) return const HomeSkeleton();
    final error = provider.error;
    return GlassCard(
      child: Column(
        children: [
          const ExcludeSemantics(
            child: Icon(
              Icons.cloud_off_outlined,
              size: IconSizes.hero,
              color: Palette.white,
            ),
          ),
          const SizedBox(height: Space.m),
          Text(
            error ?? 'Không có dữ liệu',
            textAlign: TextAlign.center,
            style: TypeScale.body.copyWith(color: Palette.white),
          ),
          const SizedBox(height: Space.l),
          ElevatedButton.icon(
            onPressed: provider.fetchWeatherData,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Thử lại'),
          ),
        ],
      ),
    );
  }
}

/// Luoi "Chi tiết" 2 cot o gan vuong: AQI (ca hang), cam giac, UV, gio, do
/// am, tam nhin, ap suat, luong mua, may, mat troi (ca hang).
/// Gia tri null -> "Không có dữ liệu".
class _DetailsGrid extends StatelessWidget {
  const _DetailsGrid({required this.current});

  final CurrentWeather current;

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<WeatherProvider>();
    final c = current;
    final now = provider.nowHcm;
    final hours = provider.hourlyForecast;
    final feels = c.feelsLike;
    final vis = c.visibilityKm;
    final dir = c.windDirection;
    final cloud = c.cloudCover;
    final p = c.pressure;
    final rain = rainTotals(hours, nowHcm: now);
    final sourceLine = c.source == null ? null : 'Nguồn: ${c.source!.label}';

    final aqi = AqiCard(
      usAqi: c.usAqi,
      pm25: c.pm25,
      sentence: aqiSentence(
        aqi: c.usAqi,
        pm25: c.pm25,
        hours: hours,
        nowHcm: now,
      ),
    );

    final u = PreferencesProvider.unitsOf(context);
    final order =
        PreferencesProvider.maybeOf(context)?.visibleMetrics ??
        HomeMetric.values;
    final wind = c.windSpeed == null ? null : u.windParts(c.windSpeed!);
    final pres = p == null ? null : u.pressureParts(p);
    // Khoang trang khong ngat dong trong "12 km/h".
    String nb(String s) => s.replaceAll(' ', ' ');

    Widget tile(HomeMetric m) {
      switch (m) {
        case HomeMetric.aqi:
          return aqi;
        case HomeMetric.sun:
          return _SunTile(nowHcm: now);
        case HomeMetric.feelsLike:
          return MetricTile(
            title: 'Cảm giác như',
            icon: Icons.thermostat_outlined,
            value: feels == null ? null : '${provider.formatTempValue(feels)}°',
            sentence: feels == null
                ? null
                : feelsLikeSentence(
                    temperature: c.temperature,
                    feelsLike: feels,
                    humidity: c.humidity,
                    windKmh: c.windSpeed,
                  ),
          );
        case HomeMetric.uv:
          return UvCard(
            uvIndex: c.uvIndex,
            sentence: uvSentence(hours, nowHcm: now),
          );
        case HomeMetric.wind:
          return MetricTile(
            title: 'Gió',
            icon: Icons.air_rounded,
            value: wind?.value,
            unit: wind?.unit,
            label: dir == null ? null : 'Hướng ${WeatherFormat.compass(dir)}',
            sentence: c.windGusts == null
                ? null
                : 'Gió giật tới ${nb(u.windText(c.windGusts))}.',
            semanticsLabel: c.windSpeed == null
                ? 'Gió: $kNoData'
                : 'Gió ${u.windText(c.windSpeed)}'
                      '${dir == null ? '' : ', thổi từ hướng ${WeatherFormat.compass(dir)} (${dir.round()} độ)'}'
                      '${c.windGusts == null ? '' : ', giật tới ${u.windText(c.windGusts)}'}',
            visual: dir == null
                ? null
                : Center(
                    child: CompassDial(
                      degrees: dir,
                      size: 104,
                      centerText: wind == null
                          ? '--'
                          : [wind.value, ?wind.unit].join('\n'),
                    ),
                  ),
          );
        case HomeMetric.humidity:
          return MetricTile(
            title: 'Độ ẩm',
            icon: Icons.water_drop_outlined,
            value: c.humidity == null
                ? null
                : WeatherFormat.percent(c.humidity),
            sentence: humiditySentence(c.dewPoint),
          );
        case HomeMetric.visibility:
          return MetricTile(
            title: 'Tầm nhìn',
            icon: Icons.visibility_outlined,
            value: vis == null ? null : u.distanceText(vis),
            label: vis == null ? null : _visibilityLabel(vis),
            sentence: vis == null
                ? null
                : vis >= 10
                ? 'Trời trong, nhìn xa rõ.'
                : 'Tầm nhìn bị hạn chế bởi mây, mưa hoặc bụi.',
          );
        case HomeMetric.pressure:
          return MetricTile(
            title: 'Áp suất',
            icon: Icons.speed_rounded,
            value: pres?.value,
            unit: pres?.unit,
            label: p == null ? null : pressureCaption(p),
            sentence: 'Áp suất mực nước biển.',
            visual: p == null
                ? null
                : Center(child: PressureGauge(hpa: p, size: 88)),
          );
        case HomeMetric.rain:
          return MetricTile(
            title: 'Lượng mưa',
            icon: Icons.umbrella_outlined,
            value: c.precipitationMm == null
                ? null
                : u.rainText(c.precipitationMm),
            label: 'Trong giờ hiện tại',
            sentence: [
              rain.past24 == null
                  ? 'Chưa có số liệu 24 giờ qua.'
                  : '24 giờ qua: ${u.rainText(rain.past24)}.',
              if (rain.next24 != null)
                'Dự báo 24 giờ tới: ${u.rainText(rain.next24)}.',
            ].join(' '),
          );
        case HomeMetric.cloud:
          return MetricTile(
            title: 'Mây',
            icon: Icons.cloud_outlined,
            value: cloud == null ? null : WeatherFormat.percent(cloud),
            label: cloud == null ? null : _cloudLabel(cloud),
            sentence: 'Tỉ lệ bầu trời bị mây che phủ.',
          );
      }
    }

    Widget keyed(HomeMetric m) =>
        KeyedSubtree(key: ValueKey('metric-${m.name}'), child: tile(m));

    return Semantics(
      container: true,
      label: 'Chi tiết hiện tại',
      child: LayoutBuilder(
        builder: (context, box) {
          final tileW = (box.maxWidth - Space.cardGap) / 2;
          Widget pair(Widget a, Widget? b) => IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: ConstrainedBox(
                    // O gan vuong; co chu lon thi tu cao them.
                    constraints: BoxConstraints(
                      minHeight: (tileW * 0.9).clamp(0.0, 240.0).toDouble(),
                    ),
                    child: a,
                  ),
                ),
                const SizedBox(width: Space.cardGap),
                Expanded(child: b ?? const SizedBox.shrink()),
              ],
            ),
          );
          // Theo thu tu uu tien: o ca hang dung rieng, o nho ghep cap lien
          // tiep.
          final rows = <Widget>[];
          HomeMetric? pending;
          for (final m in order) {
            if (m.fullWidth) {
              if (pending != null) rows.add(pair(keyed(pending), null));
              pending = null;
              rows.add(keyed(m));
            } else if (pending == null) {
              pending = m;
            } else {
              rows.add(pair(keyed(pending), keyed(m)));
              pending = null;
            }
          }
          if (pending != null) rows.add(pair(keyed(pending), null));
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < rows.length; i++) ...[
                if (i > 0) const SizedBox(height: Space.cardGap),
                rows[i],
              ],
              if (order.isEmpty)
                GlassCard(
                  child: Text(
                    'Chưa chọn chỉ số nào. Bật trong Cài đặt > Chỉ số trên '
                    'trang chủ.',
                    style: TypeScale.body.copyWith(color: Palette.white),
                  ),
                ),
              if (sourceLine != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    Space.xs,
                    Space.s,
                    Space.xs,
                    0,
                  ),
                  child: Text(
                    '$sourceLine · Cập nhật '
                    '${DateFormat('HH:mm dd/MM').format(c.lastUpdated)}',
                    style: TypeScale.small.copyWith(
                      color: GlassInk.of(context).headerSecondary,
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  static String _visibilityLabel(double km) {
    if (km < 1) return 'Rất kém';
    if (km < 5) return 'Hạn chế';
    if (km < 10) return 'Trung bình';
    return 'Tốt';
  }

  static String _cloudLabel(int cover) {
    if (cover < 20) return 'Ít mây';
    if (cover < 60) return 'Mây rải rác';
    if (cover < 90) return 'Nhiều mây';
    return 'U ám';
  }
}

/// O mat troi moc / lan: gio cua ngay (theo nowHcm), cung voi vi tri mat
/// troi hien tai.
class _SunTile extends StatelessWidget {
  const _SunTile({required this.nowHcm});

  final DateTime nowHcm;

  @override
  Widget build(BuildContext context) {
    final today = SunTimes.forDate(
      nowHcm,
      lat: ApiConfig.latitude,
      lon: ApiConfig.longitude,
    );
    final isDay =
        !nowHcm.isBefore(today.sunrise) && nowHcm.isBefore(today.sunset);
    final afterSunset = !nowHcm.isBefore(today.sunset);
    final next = afterSunset
        ? SunTimes.forDate(
            nowHcm.add(const Duration(days: 1)),
            lat: ApiConfig.latitude,
            lon: ApiConfig.longitude,
          )
        : today;
    final hm = ForecastFormat.hourMinute;
    final double? progress = isDay
        ? nowHcm.difference(today.sunrise).inSeconds /
              today.sunset.difference(today.sunrise).inSeconds
        : null;
    final String title = isDay ? 'Mặt trời lặn' : 'Mặt trời mọc';
    final String value = isDay ? hm(today.sunset) : hm(next.sunrise);
    final String label = isDay
        ? 'Mặt trời mọc: ${hm(today.sunrise)}'
        : 'Mặt trời lặn: ${hm(afterSunset ? today.sunset : next.sunset)}';
    final dl = today.dayLength;
    return MetricTile(
      title: title,
      icon: isDay ? Icons.wb_twilight_rounded : Icons.wb_sunny_outlined,
      value: value,
      label: label,
      sentence:
          'Ngày dài ${dl.inHours} giờ ${dl.inMinutes.remainder(60)} phút '
          '(tính theo vị trí điểm dữ liệu).',
      visual: SunArc(progress: progress),
    );
  }
}
