import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/weather.dart';
import '../providers/location_provider.dart';
import '../providers/planner_provider.dart';
import '../providers/weather_provider.dart';
import '../ui/weather/app_scene.dart';
import '../ui/weather/debug/weather_simulator_screen.dart';
import '../ui/weather/design_tokens.dart';
import '../ui/weather/weather_background.dart';
import '../ui/weather/weather_insights.dart';
import '../ui/weather/widgets/bottom_pill_bar.dart';
import '../ui/weather/widgets/glass_card.dart';
import '../ui/weather/widgets/glass_page.dart';
import '../ui/weather/widgets/home_tab_scope.dart';
import '../ui/weather/widgets/ios_toast.dart';
import 'alerts_screen.dart';
import 'locations_screen.dart';
import 'map_screen.dart' show MapScreen;
import 'trip_screen.dart' show TripScreen;
import 'home/home_location_page.dart';

export 'home/home_header_info.dart' show friendlyRegion;

/// Adaptive weather workspace with location paging and explicit navigation.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.locations});

  /// Danh sach dia diem; null -> man hinh tu tao (test / chay don le).
  final LocationProvider? locations;

  /// Chieu rong toi da cua cot noi dung (dien thoai / may tinh bang).
  static const double maxContentWidth = Space.contentMaxWidth;

  /// Tu chieu rong nay: hai cot (tong quan + dieu kien | du bao).
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

  /// Tab dang mo; moi tab mot Navigator rieng (giu trang thai khi doi tab,
  /// man con day vao van thay thanh tab).
  HomeTab _tab = HomeTab.today;
  final Set<HomeTab> _visited = {HomeTab.today};
  final Map<HomeTab, GlobalKey<NavigatorState>> _navKeys = {
    for (final t in HomeTab.values)
      t: GlobalKey<NavigatorState>(debugLabel: 'tab-${t.name}'),
  };
  final Map<HomeTab, HeroController> _heroes = {
    for (final t in HomeTab.values)
      t: MaterialApp.createMaterialHeroController(),
  };

  /// Tin hieu cho man goc tung tab (xem [HomeTabScope]).
  final ValueNotifier<HomeTab> _selected = ValueNotifier(HomeTab.today);
  final Map<HomeTab, _Pulse> _reselect = {
    for (final t in HomeTab.values) t: _Pulse(),
  };
  late final Map<HomeTab, NavigatorObserver> _observers = {
    for (final t in HomeTab.values) t: _TabObserver(_onTabStackChanged),
  };

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
    // Day trong tab Hom nay (giu thanh tab).
    _navKeys[HomeTab.today]!.currentState?.push(
      MaterialPageRoute<void>(builder: (_) => AlertsScreen(locations: _lp)),
    );
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

  /// Mo trang Home [i] tu tab khac (Ban do / Dia diem): ve tab Hom nay.
  void _showPage(int i) {
    _selectTab(HomeTab.today);
    _lp.select(i);
    if (_pages.hasClients) _pages.jumpToPage(i);
  }

  void _openPlace(String id) {
    if (!_lp.selectLocation(id)) {
      _lp.addSaved(id);
      _lp.selectLocation(id);
    }
    _showPage(_lp.selectedIndex);
  }

  /// Doi tab (giu nguyen trang thai tung tab); cham lai tab dang mo -> ve
  /// goc tab do (Hom nay dang o goc: ve dau trang nhu truoc).
  void _selectTab(HomeTab t) {
    if (t == _tab) {
      final nav = _navKeys[t]!.currentState;
      if (nav != null && nav.canPop()) {
        nav.popUntil((r) => r.isFirst);
      } else if (t == HomeTab.today) {
        setState(() {
          _homeRevision++;
          _bgActive = true;
        });
      } else {
        // Dang o goc tab: man goc tu cuon ve dau (Ban do: khong lam gi).
        _reselect[t]!.fire();
      }
      return;
    }
    // Thong bao thuoc tab cu (vd. "Đã xóa… Hoàn tác" o Dia diem) khong
    // duoc tran sang tab moi.
    hideIosToast();
    setState(() {
      _tab = t;
      _visited.add(t);
    });
    _selected.value = t;
  }

  /// Nut Back Android: pop trong tab, roi ve tab Hom nay, roi thoat app.
  bool get _canExit =>
      _tab == HomeTab.today &&
      !(_navKeys[HomeTab.today]!.currentState?.canPop() ?? false);

  void _onBack(bool didPop, Object? _) {
    if (didPop) return;
    final nav = _navKeys[_tab]!.currentState;
    if (nav != null && nav.canPop()) {
      nav.maybePop();
    } else if (_tab != HomeTab.today) {
      _selectTab(HomeTab.today);
    }
  }

  /// Ngan xep trong mot tab doi -> tinh lai [_canExit] sau khung hinh.
  void _onTabStackChanged() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _wp?.removeListener(_onWeather);
    _lp.removeListener(_onLocations);
    if (widget.locations == null) _lp.dispose();
    _pages.dispose();
    _splash.dispose();
    for (final h in _heroes.values) {
      h.dispose();
    }
    _selected.dispose();
    for (final p in _reselect.values) {
      p.dispose();
    }
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

  /// Thanh tab (dien thoai) hoac rail (may tinh); dung chung moi tab.
  Widget _navigation({required bool desktop, required int? rain2h}) {
    final pages = _lp.pages;
    return BottomPillBar(
      vertical: desktop,
      selected: _tab,
      onHome: () => _selectTab(HomeTab.today),
      pageCount: pages.length,
      currentPage: _lp.selectedIndex,
      currentLocationIndex: pages.indexWhere((p) => p.isCurrentLocation),
      onMap: () => _selectTab(HomeTab.map),
      onTrip: () => _selectTab(HomeTab.trip),
      tripRainPercent: rain2h,
      onLocations: () => _selectTab(HomeTab.places),
    );
  }

  /// Moi tab mot Navigator long nhau + HeroController rieng.
  Widget _tabNavigator(HomeTab t) => HomeTabScope(
    tab: t,
    selected: _selected,
    reselected: _reselect[t]!,
    child: HeroControllerScope(
      controller: _heroes[t]!,
      child: Navigator(
        key: _navKeys[t],
        observers: [_observers[t]!],
        onGenerateInitialRoutes: (_, _) => [
          MaterialPageRoute<void>(builder: (_) => _tabRoot(t)),
        ],
      ),
    ),
  );

  /// Man goc cua tab (khong co nut quay lai).
  Widget _tabRoot(HomeTab t) => switch (t) {
    HomeTab.today => MediaQuery(
      // Trang Home tu chua cho thanh tab: dung MediaQuery goc.
      data: MediaQuery.of(context),
      child: Builder(builder: _buildHome),
    ),
    HomeTab.map => MapScreen(
      locations: _lp,
      focusLocationId: _lp.selectedLocationId,
      onOpenPlace: _openPlace,
    ),
    HomeTab.trip => TripScreen(locations: _lp, quickStart: true),
    HomeTab.places => LocationsScreen(locations: _lp, onOpenPage: _showPage),
  };

  @override
  Widget build(BuildContext context) {
    final scene = AppScene.of(context);
    final st = scene.theme;
    // Mini "mưa 2 giờ tới" tren nut Ra ngoai.
    final rain2h = context.select<WeatherProvider, int?>(
      (p) => maxRainPercent(p.hourlyForecast, nowHcm: p.nowHcm),
    );
    final mq = MediaQuery.of(context);
    final desktop = mq.size.width >= 1100;
    final railWidth = mq.textScaler.scale(13) > 19 ? 180.0 : 120.0;
    // Man trong tab nam sau thanh tab: cong chieu cao thanh vao le duoi
    // (ban phim mo thi thanh bi che, khong cong).
    final bar = desktop || mq.viewInsets.bottom > 0
        ? 0.0
        : BottomPillBar.heightFor(mq.size.width, mq.textScaler);
    final tabMq = mq.copyWith(
      padding: mq.padding.copyWith(bottom: mq.padding.bottom + bar),
      viewPadding: mq.viewPadding.copyWith(bottom: mq.viewPadding.bottom + bar),
    );
    final navigation = Theme(
      data: glassThemeFor(st, Theme.of(context)),
      child: BackdropGroup(
        backdropKey: _bottomBarBackdropKey,
        child: _navigation(desktop: desktop, rain2h: rain2h),
      ),
    );

    return PopScope(
      canPop: _canExit,
      onPopInvokedWithResult: _onBack,
      child: ColoredBox(
        color: st.gradient.last,
        child: Stack(
          children: [
            Positioned.fill(
              child: MediaQuery(
                data: tabMq,
                child: IndexedStack(
                  index: _tab.index,
                  children: [
                    for (final t in HomeTab.values)
                      TickerMode(
                        enabled: t == _tab,
                        child: ExcludeFocus(
                          excluding: t != _tab,
                          child: !_visited.contains(t)
                              ? const SizedBox.shrink()
                              : Padding(
                                  // Home tu chua rail; tab khac lui sang phai.
                                  padding: EdgeInsets.only(
                                    left: desktop && t != HomeTab.today
                                        ? railWidth + Space.l
                                        : 0,
                                  ),
                                  child: _tabNavigator(t),
                                ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (desktop)
              Positioned(
                left: Space.s,
                top: 0,
                bottom: 0,
                width: railWidth,
                child: SafeArea(
                  minimum: const EdgeInsets.only(bottom: Space.s),
                  child: SingleChildScrollView(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: Space.l),
                      child: navigation,
                    ),
                  ),
                ),
              )
            else
              // Thanh tab iOS: day sat mep duoi, tu chua vung an toan (home
              // indicator) ben trong; luon hien tren moi tab.
              Positioned(left: 0, right: 0, bottom: 0, child: navigation),
          ],
        ),
      ),
    );
  }

  /// Goc tab Hom nay: trang thoi tiet theo dia diem (vuot ngang).
  Widget _buildHome(BuildContext context) {
    final scene = AppScene.of(context);
    final st = scene.theme;
    final appTheme = Theme.of(context);
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final hasData = context.select<WeatherProvider, bool>(
      (p) => p.currentWeather != null,
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
                  child: Padding(
                    padding: EdgeInsets.only(
                      left: desktop ? railWidth + Space.l : 0,
                    ),
                    child: PageView.builder(
                      controller: _pages,
                      itemCount: pages.length,
                      onPageChanged: _onPageChanged,
                      itemBuilder: (context, i) => HomeLocationPage(
                        key: ValueKey('${pages[i].locationId}-$_homeRevision'),
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
                        onLocations: () => _selectTab(HomeTab.places),
                        onTrip: () => _selectTab(HomeTab.trip),
                        pageIndex: i,
                        pageCount: pages.length,
                        nextName: i + 1 < pages.length
                            ? _lp.labelFor(pages[i + 1]) ??
                                  _lp.placeById(pages[i + 1].locationId).name
                            : null,
                        onPrevious: i > 0 ? () => _goTo(i - 1) : null,
                        onNext: i + 1 < pages.length
                            ? () => _goTo(i + 1)
                            : null,
                        onCityLongPress:
                            kDebugMode && maybeSceneOverride(context) != null
                            ? () => _openSimulator(scene)
                            : null,
                      ),
                    ),
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

/// Su kien "cham lai tab" (khong mang gia tri).
class _Pulse extends ChangeNotifier {
  void fire() => notifyListeners();
}

/// Bao [HomeScreen] khi ngan xep trong mot tab doi (cho nut Back Android).
class _TabObserver extends NavigatorObserver {
  _TabObserver(this.onChange);

  final VoidCallback onChange;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      onChange();

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      onChange();

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      onChange();

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      onChange();
}
