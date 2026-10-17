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
import '../ui/weather/widgets/hourly_strip.dart';
import '../ui/weather/widgets/metric_tile.dart';
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

/// Man hinh chinh: nen canh thoi tiet dong + the kinh kieu iOS.
/// Moi dia diem (vi tri hien tai + dia diem da luu) la mot trang PageView.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.locations});

  /// Danh sach dia diem; null -> man hinh tu tao (test / chay don le).
  final LocationProvider? locations;

  /// Chieu rong toi da cua cot noi dung (dien thoai / may tinh bang).
  static const double maxContentWidth = Space.contentMaxWidth;

  /// Tu chieu rong nay: hai cot (dau trang + AI + theo gio | 7 ngay + chi
  /// tiet).
  static const double twoColumnWidth = 900;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final SplashRegistry _splash = SplashRegistry();
  late final LocationProvider _lp = widget.locations ?? LocationProvider();
  late final PageController _pages = PageController(
    initialPage: _lp.selectedIndex,
  );
  bool _splashOn = false;
  bool _splashScheduled = false;

  /// The xuat hien co hieu ung chi o lan dau co du lieu.
  bool _entranceDone = false;
  bool _animateEntrance = false;

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
    _lp.select(i);
    final id = _lp.selectedLocationId;
    final wp = context.read<WeatherProvider>();
    if (wp.locationId != id) wp.setLocation(id);
  }

  void _goTo(int i) {
    _lp.select(i);
    if (_pages.hasClients) {
      _pages.animateToPage(i, duration: Motion.medium, curve: Motion.enter);
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
    final provider = context.watch<WeatherProvider>();
    final pages = _lp.pages;

    if (!_entranceDone && provider.currentWeather != null) {
      _entranceDone = true;
      _animateEntrance = !reduceMotion;
    }

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
            // Than sang o goc tren phai, tren dong ten thanh pho.
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
                    return false;
                  },
                  child: Stack(
                    children: [
                      PageView.builder(
                        controller: _pages,
                        itemCount: pages.length,
                        onPageChanged: _onPageChanged,
                        itemBuilder: (context, i) => _LocationPage(
                          location: _lp.placeById(pages[i].locationId),
                          label: _lp.labelFor(pages[i]),
                          scene: scene,
                          animateEntrance: _animateEntrance,
                          dismissedAlert: _dismissedAlert,
                          onDismissAlert: (a) =>
                              setState(() => _dismissedAlert = a),
                          dismissedAlertKey: _dismissedAlertKey,
                          onDismissAlertKey: (k) =>
                              setState(() => _dismissedAlertKey = k),
                          onOpenAlerts: _openAlerts,
                          onCityLongPress:
                              kDebugMode && maybeSceneOverride(context) != null
                              ? () => _openSimulator(scene)
                              : null,
                        ),
                      ),
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: SafeArea(
                          top: false,
                          minimum: const EdgeInsets.only(bottom: Space.s),
                          child: Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 420),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: Space.l,
                                ),
                                child: BottomPillBar(
                                  pageCount: pages.length,
                                  currentPage: _lp.selectedIndex,
                                  firstIsCurrentLocation:
                                      pages.first.isCurrentLocation,
                                  onMap: _openMap,
                                  onTrip: () =>
                                      openTripScreen(context, locations: _lp),
                                  onLocations: _openLocations,
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
class _LocationPage extends StatelessWidget {
  const _LocationPage({
    required this.location,
    this.label,
    required this.scene,
    required this.animateEntrance,
    required this.dismissedAlert,
    required this.onDismissAlert,
    this.dismissedAlertKey,
    this.onDismissAlertKey,
    this.onOpenAlerts,
    this.onCityLongPress,
  });

  final Place location;

  /// Nhan dia diem da luu (vd. "Nhà"), hien canh ten phuong.
  final String? label;
  final AppSceneData scene;
  final bool animateEntrance;
  final WeatherAlert? dismissedAlert;
  final ValueChanged<WeatherAlert> onDismissAlert;
  final String? dismissedAlertKey;
  final ValueChanged<String>? onDismissAlertKey;
  final VoidCallback? onOpenAlerts;
  final VoidCallback? onCityLongPress;

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<WeatherProvider>();
    final mq = MediaQuery.of(context);
    final width = mq.size.width;
    // Trang dang luot toi (chua phai dia diem dang tai): khong hien du lieu
    // cua dia diem khac.
    final active = provider.locationId == location.id;
    final current = active ? provider.currentWeather : null;
    final info = _headerInfo(provider, current);
    final loading = provider.isLoading && provider.weatherData != null;
    final planner = maybePlanner(context);
    final actions = _HeaderActions(
      provider: provider,
      unread: planner?.unreadCount ?? 0,
      onAlerts: planner == null ? null : onOpenAlerts,
    );
    final bottomSpace =
        BottomPillBar.height + Space.l + Space.s + mq.padding.bottom;
    // Co PlannerProvider (app that): bo luat day du; khong co: banner mua cu.
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

    // Thu tu doc = thu tu hien thi.
    final cards = <Widget>[
      if (active) ..._banners(provider),
      if (alert != null && alert != dismissedAlert)
        _AlertBanner(alert: alert, onDismiss: () => onDismissAlert(alert)),
      if (events.isNotEmpty && events.first.key != dismissedAlertKey)
        AlertsSummaryBanner(
          events: events,
          onOpen: onOpenAlerts ?? () {},
          onDismiss: () => onDismissAlertKey?.call(events.first.key),
        ),
      if (current == null) _StateCard(provider: provider, pending: !active),
    ];
    final left = <Widget>[
      if (current != null) ...[
        if (provider.hourlyForecast.isNotEmpty)
          HourlyStrip(hours: provider.hourlyForecast),
        AIForecastCard(forecast: provider.aiForecast),
        if (planner != null && provider.hourlyForecast.isNotEmpty)
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
      ],
    ];
    final right = <Widget>[
      if (current != null) ...[
        if (provider.dailyForecast.isNotEmpty)
          _daily(context, provider, current),
        _DetailsGrid(current: current),
      ],
    ];

    Widget scroll;
    if (current != null && width >= HomeScreen.twoColumnWidth) {
      scroll = _wideLayout(
        context,
        info,
        actions,
        loading,
        bottomSpace,
        cards,
        left,
        right,
      );
    } else {
      final metrics = HeaderMetrics(
        mq.textScaler,
        topPadding: mq.padding.top,
        info: info,
        width: width - 2 * Space.l,
        viewportHeight: mq.size.height,
      );
      final gutter = Space.gutter(
        width,
        landscape: mq.orientation == Orientation.landscape,
      );
      final hPad = width > Space.contentMaxWidth + 2 * gutter
          ? (width - Space.contentMaxWidth) / 2
          : gutter;
      final all = [...cards, ...left, ...right];
      scroll = CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverPersistentHeader(
            pinned: true,
            delegate: CollapsingHeaderDelegate(
              info: info,
              metrics: metrics,
              actions: actions,
              glassColor: scene.theme.glassColor,
              ink: GlassInk.forTheme(scene.theme),
              loading: loading,
              onCityLongPress: onCityLongPress,
            ),
          ),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(hPad, Space.s, hPad, bottomSpace),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                for (var i = 0; i < all.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Space.cardGap),
                    child: EntranceFade(
                      index: i,
                      animate: animateEntrance,
                      child: all[i],
                    ),
                  ),
              ]),
            ),
          ),
        ],
      );
    }

    return RefreshIndicator(
      onRefresh: provider.refreshWeatherData,
      color: Palette.white,
      backgroundColor: scene.theme.gradient.first,
      edgeOffset: mq.padding.top,
      child: scroll,
    );
  }

  Widget _wideLayout(
    BuildContext context,
    WeatherHeaderInfo info,
    Widget actions,
    bool loading,
    double bottomSpace,
    List<Widget> banners,
    List<Widget> left,
    List<Widget> right,
  ) {
    final mq = MediaQuery.of(context);
    final gutter = Space.gutter(
      mq.size.width,
      landscape: mq.orientation == Orientation.landscape,
    );
    Widget column(List<Widget> children, int offset) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < children.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.cardGap),
            child: EntranceFade(
              index: i + offset,
              animate: animateEntrance,
              child: children[i],
            ),
          ),
      ],
    );
    final ink = GlassInk.forTheme(scene.theme);
    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.only(top: mq.padding.top),
            child: Align(
              alignment: Alignment.centerLeft,
              child: SizedBox(
                height: HeaderMetrics.actionsHeight,
                child: actions,
              ),
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1240),
              child: Padding(
                padding: EdgeInsets.fromLTRB(gutter, 0, gutter, bottomSpace),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: column([
                        DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(
                              alpha: ink.headerScrim,
                            ),
                            borderRadius: BorderRadius.circular(Radii.card),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              vertical: Space.s,
                            ),
                            child: WeatherHeaderBlock(
                              info: info,
                              metrics: HeaderMetrics(
                                mq.textScaler,
                                topPadding: 0,
                              ),
                              loading: loading,
                              onCityLongPress: onCityLongPress,
                            ),
                          ),
                        ),
                        ...banners,
                        ...left,
                      ], 0),
                    ),
                    const SizedBox(width: Space.l),
                    Expanded(child: column(right, 1)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
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
      onDayTap: (d) => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ForecastScreen(
            selectedDay: d,
            allDays: provider.dailyForecast,
            hourlyData: provider.hourlyForecast,
          ),
        ),
      ),
    );
  }

  List<Widget> _banners(WeatherProvider provider) => [
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
    return l == null ? location.detail : '$l · ${location.detail}';
  }

  WeatherHeaderInfo _headerInfo(WeatherProvider provider, CurrentWeather? c) {
    if (c == null) {
      return WeatherHeaderInfo(city: location.name, detail: _detail);
    }
    String t(double v) => '${provider.formatTempValue(v)}°';
    final today = provider.todayForecast;
    final updatedAt = c.lastUpdated;
    final sameDay = ForecastFormat.sameDay(updatedAt, provider.nowHcm);
    final cachedAt = provider.cachedAt;
    return WeatherHeaderInfo(
      city: location.name,
      detail: _detail,
      temperature: t(c.temperature),
      condition: c.condition.description,
      highLow: today == null
          ? null
          : 'Cao ${t(today.tempMax)} · Thấp ${t(today.tempMin)}',
      feelsLike: c.feelsLike == null ? null : 'Cảm giác như ${t(c.feelsLike!)}',
      updated:
          'Cập nhật ${DateFormat(sameDay ? 'HH:mm' : 'dd/MM HH:mm').format(updatedAt)}',
      isStale: provider.isStale,
      cachedNote: provider.isFromCache && cachedAt != null
          ? 'Đã lưu ${DateFormat('dd/MM HH:mm').format(cachedAt)}'
          : null,
      semanticsTemp:
          'Nhiệt độ hiện tại: ${provider.formatTemperature(c.temperature)}',
    );
  }
}

/// Nut Lam moi + Cai dat.
class _HeaderActions extends StatelessWidget {
  const _HeaderActions({
    required this.provider,
    this.unread = 0,
    this.onAlerts,
  });

  final WeatherProvider provider;

  /// So thong bao chua doc (man Canh bao).
  final int unread;
  final VoidCallback? onAlerts;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (onAlerts != null)
          GlassIconButton(
            tooltip: unread > 0
                ? 'Cảnh báo, $unread thông báo mới'
                : 'Cảnh báo',
            icon: unread > 0
                ? Icons.notifications_active_outlined
                : Icons.notifications_none_rounded,
            onPressed: onAlerts,
          ),
        GlassIconButton(
          tooltip: 'Làm mới',
          icon: Icons.refresh_rounded,
          onPressed: provider.isLoading ? null : provider.refreshWeatherData,
        ),
        GlassIconButton(
          tooltip: 'Cài đặt',
          icon: Icons.settings_outlined,
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const SettingsScreen()),
          ),
        ),
      ],
    );
  }
}

/// Canh bao mua / dong tinh tu du bao: the kinh, vach amber 3 px ben trai,
/// icon amber, tieu de mot dong, mot dong phu (cat bot), nut dong 48 dp.
class _AlertBanner extends StatelessWidget {
  const _AlertBanner({required this.alert, required this.onDismiss});

  final WeatherAlert alert;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final ink = GlassInk.of(context);
    return Semantics(
      liveRegion: true,
      container: true,
      child: GlassSurface(
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: 3, child: ColoredBox(color: ink.alert)),
              const SizedBox(width: Space.m),
              Center(
                child: ExcludeSemantics(
                  child: Icon(
                    alert.thunder
                        ? Icons.thunderstorm_outlined
                        : Icons.umbrella_outlined,
                    color: ink.alert,
                    size: IconSizes.md,
                  ),
                ),
              ),
              const SizedBox(width: Space.m),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: Space.m),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // Mot dong; thu nho thay vi cat de luon thay du gio.
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          alert.title,
                          maxLines: 1,
                          style: TypeScale.label.copyWith(
                            fontWeight: FontWeight.w600,
                            color: Palette.white,
                            fontFeatures: kTabular,
                          ),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        alert.detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TypeScale.small.copyWith(
                          fontSize: 13,
                          color: ink.secondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Center(
                child: Tooltip(
                  message: 'Đóng cảnh báo',
                  excludeFromSemantics: true,
                  child: Pressable(
                    onTap: onDismiss,
                    semanticsLabel: 'Đóng cảnh báo',
                    child: const SizedBox.square(
                      dimension: Touch.min,
                      child: Icon(
                        Icons.close_rounded,
                        color: Palette.white,
                        size: IconSizes.md,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: Space.xs),
            ],
          ),
        ),
      ),
    );
  }
}

/// Thong bao / loi (kem nut) dang the kinh.
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
    return GlassCard(
      padding: const EdgeInsets.fromLTRB(Space.l, Space.s, Space.s, Space.s),
      child: Row(
        children: [
          ExcludeSemantics(child: Icon(icon, color: Palette.white)),
          const SizedBox(width: Space.m),
          Expanded(
            child: Semantics(
              liveRegion: true,
              child: Text(
                message,
                style: TypeScale.body.copyWith(color: Palette.white),
              ),
            ),
          ),
          TextButton(
            onPressed: onAction,
            style: TextButton.styleFrom(
              minimumSize: const Size(Touch.min, Touch.min),
            ),
            child: Text(actionLabel),
          ),
        ],
      ),
    );
  }
}

/// Chua co du lieu: dang tai / loi / trong.
class _StateCard extends StatelessWidget {
  const _StateCard({required this.provider, this.pending = false});

  final WeatherProvider provider;

  /// Trang chua duoc chon: chi hien dang tai.
  final bool pending;

  @override
  Widget build(BuildContext context) {
    if (pending || provider.isLoading) {
      return GlassCard(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Space.m),
          child: Column(
            children: [
              const CircularProgressIndicator(color: Palette.white),
              const SizedBox(height: Space.l),
              Text(
                'Đang tải dữ liệu thời tiết...',
                textAlign: TextAlign.center,
                style: TypeScale.body.copyWith(color: Palette.white),
              ),
            ],
          ),
        ),
      );
    }
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
                    constraints: BoxConstraints(minHeight: tileW * 0.9),
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
