import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sky_weather_app/models/app_settings.dart';
import 'package:sky_weather_app/providers/location_provider.dart';
import 'package:sky_weather_app/providers/weather_provider.dart';
import 'package:sky_weather_app/screens/home_screen.dart';
import 'package:sky_weather_app/screens/locations_screen.dart';
import 'package:sky_weather_app/screens/map_screen.dart' show MapScreen;
import 'package:sky_weather_app/ui/weather/widgets/home_navigation.dart';
import 'package:sky_weather_app/ui/weather/widgets/ios_page.dart';
import 'package:sky_weather_app/ui/weather/widgets/ios_sheet.dart';
import 'package:sky_weather_app/ui/weather/widgets/ios_toast.dart';
import 'package:sky_weather_app/widgets/replay_banner.dart';
import 'package:sky_weather_app/utils/theme.dart';

class _Locations extends LocationProvider {
  @override
  Future<void> loadLocal() async {}

  @override
  Future<void> refreshRemote({DateTime? at}) async {}
}

class _Weather extends WeatherProvider {
  _Weather() : super(initialSettings: const AppSettings());

  @override
  Future<void> initialize() async {}

  @override
  Future<void> fetchWeatherData() async {}
}

final _tabBar = find.byKey(const ValueKey('ios-tab-bar'));

Finder _tab(String tooltip) => find.byTooltip(tooltip);

HomeTab _current(WidgetTester tester) =>
    tester.widget<HomeNavigation>(find.byType(HomeNavigation)).selected;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('tab bar persists; tabs keep state; back pops tab then Home', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final weather = _Weather();
    final locations = _Locations();
    addTearDown(weather.dispose);
    addTearDown(locations.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<WeatherProvider>.value(
        value: weather,
        child: MaterialApp(
          theme: AppTheme.darkTheme,
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(390, 844),
              padding: EdgeInsets.only(top: 44, bottom: 34),
              disableAnimations: true,
            ),
            child: HomeScreen(locations: locations),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(_tabBar, findsOneWidget);
    expect(find.byType(LocationsScreen), findsNothing);

    // Doi sang tab Dia diem: van mot thanh tab, khong co nut quay lai.
    await tester.tap(_tab('Danh sách địa điểm'));
    await tester.pumpAndSettle();
    expect(find.byType(LocationsScreen), findsOneWidget);
    expect(_tabBar, findsOneWidget);
    expect(find.byTooltip('Quay lại'), findsNothing);
    expect(_current(tester), HomeTab.places);

    // Trang thai tab: chu trong o tim kiem con nguyen sau khi doi tab.
    await tester.enterText(find.byType(EditableText).first, 'Bến');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(_tab('Thời tiết hôm nay'));
    await tester.pumpAndSettle();
    expect(_current(tester), HomeTab.today);
    expect(_tabBar, findsOneWidget);
    await tester.tap(_tab('Danh sách địa điểm'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<EditableText>(find.byType(EditableText).first)
          .controller
          .text,
      'Bến',
    );

    // Man con trong tab: thanh tab van hien; cham lai tab -> ve goc.
    final nav = Navigator.of(tester.element(find.byType(LocationsScreen)));
    nav.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('chi tiết')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('chi tiết'), findsOneWidget);
    expect(_tabBar, findsOneWidget);
    await tester.tap(_tab('Danh sách địa điểm'));
    await tester.pumpAndSettle();
    expect(find.text('chi tiết'), findsNothing);
    expect(find.byType(LocationsScreen), findsOneWidget);

    // Nut Back he thong: pop trong tab truoc, roi ve tab Hom nay.
    nav.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('chi tiết')),
      ),
    );
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('chi tiết'), findsNothing);
    expect(_current(tester), HomeTab.places);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(_current(tester), HomeTab.today);
    final home = tester.widget<PopScope>(
      find
          .ancestor(
            of: find.byType(HomeNavigation),
            matching: find.byWidgetPredicate((w) => w is PopScope),
          )
          .first,
    );
    // O tab dau, goc: Back thoat app.
    expect(home.canPop, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  Future<void> pumpHome(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final weather = _Weather();
    final locations = _Locations();
    addTearDown(weather.dispose);
    addTearDown(locations.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<WeatherProvider>.value(
        value: weather,
        child: MaterialApp(
          theme: AppTheme.darkTheme,
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(390, 844),
              padding: EdgeInsets.only(top: 44, bottom: 34),
              disableAnimations: true,
            ),
            child: HomeScreen(locations: locations),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('sheet from the map tab covers the tab bar (root navigator)', (
    tester,
  ) async {
    await pumpHome(tester);
    await tester.tap(_tab('Bản đồ'));
    await tester.pumpAndSettle();
    expect(_current(tester), HomeTab.map);
    final mapCtx = tester.element(find.byType(MapScreen));
    showIosSheet<void>(
      mapCtx,
      title: 'Ô dữ liệu',
      builder: (_) => const Text('nội dung sheet'),
    );
    await tester.pumpAndSettle();
    final sheet = find.byKey(const ValueKey('glass-sheet'));
    expect(sheet, findsOneWidget);
    // Sheet nam o Navigator goc, khong phai Navigator cua tab.
    expect(
      Navigator.of(tester.element(sheet)),
      same(Navigator.of(mapCtx, rootNavigator: true)),
    );
    // Thanh tab bi barrier phu: khong bam trung tab duoc.
    final barCenter = tester.getCenter(_tab('Danh sách địa điểm'));
    final hit = tester.hitTestOnBinding(barCenter);
    final barBox = tester.renderObject(_tabBar);
    expect(hit.path.any((e) => identical(e.target, barBox)), isFalse);
    await tester.tapAt(barCenter);
    await tester.pumpAndSettle();
    expect(_current(tester), HomeTab.map);
    expect(find.byType(LocationsScreen), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('re-tapping Địa điểm at its root scrolls to the top', (
    tester,
  ) async {
    await pumpHome(tester);
    await tester.tap(_tab('Danh sách địa điểm'));
    await tester.pumpAndSettle();
    final scrollable = find
        .descendant(
          of: find.byType(LocationsScreen),
          matching: find.byType(Scrollable),
        )
        .first;
    final pos = tester.state<ScrollableState>(scrollable).position;
    pos.jumpTo(math.min(200, pos.maxScrollExtent));
    await tester.pump();
    expect(pos.pixels, greaterThan(0));
    await tester.tap(_tab('Danh sách địa điểm'));
    await tester.pumpAndSettle();
    expect(pos.pixels, 0);
    expect(_current(tester), HomeTab.places);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('large title keeps right inset and >= 28pt, then ellipsis', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const title = 'Kiểm chứng dự báo AI dài hơn màn hình';
    final weather = _Weather();
    addTearDown(weather.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<WeatherProvider>.value(
        value: weather,
        child: MaterialApp(
          theme: AppTheme.darkTheme,
          home: const IosPageScaffold(title: title, children: [SizedBox()]),
        ),
      ),
    );
    final large = find.byKey(const ValueKey('ios-large-title'));
    final text = tester.widget<Text>(large);
    expect(
      text.style!.fontSize,
      greaterThanOrEqualTo(IosLargeTitle.minFontSize),
    );
    expect(text.overflow, TextOverflow.ellipsis);
    expect(tester.getRect(large).right, lessThanOrEqualTo(320 - 16));
    expect(tester.takeException(), isNull);
  });

  testWidgets('replay banner is one line at 200% with full semantics', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final at = DateTime(2026, 10, 7, 12);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 640),
            textScaler: TextScaler.linear(2),
          ),
          child: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: ReplayBanner(at: at, onExit: () {}),
            ),
          ),
        ),
      ),
    );
    final label = find.text(ReplayBanner.text(at));
    final line = tester.getSize(label).height;
    expect(
      tester.getSize(find.byType(ReplayBanner)).height,
      lessThan(line * 2 + 8),
    );
    expect(
      find.bySemanticsLabel(ReplayBanner.semanticsLabel(at)),
      findsOneWidget,
    );
    final exit = tester.widget<Text>(find.text('Thoát'));
    expect(exit.style!.decoration, isNot(TextDecoration.underline));
    expect(tester.takeException(), isNull);
  });

  testWidgets('switching tabs hides a toast from the previous tab', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final weather = _Weather();
    final locations = _Locations();
    addTearDown(weather.dispose);
    addTearDown(locations.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<WeatherProvider>.value(
        value: weather,
        child: MaterialApp(
          theme: AppTheme.darkTheme,
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(390, 844),
              padding: EdgeInsets.only(top: 44, bottom: 34),
              disableAnimations: true,
            ),
            child: HomeScreen(locations: locations),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(_tab('Danh sách địa điểm'));
    await tester.pumpAndSettle();
    showIosToast(
      tester.element(find.byType(LocationsScreen)),
      'Đã xóa Phường Bến Thành',
      actionLabel: 'Hoàn tác',
      onAction: () {},
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Đã xóa Phường Bến Thành'), findsOneWidget);

    await tester.tap(_tab('Bản đồ'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(_current(tester), HomeTab.map);
    expect(find.text('Đã xóa Phường Bến Thành'), findsNothing);
    expect(find.text('Hoàn tác'), findsNothing);
    await tester.pumpAndSettle(const Duration(seconds: 7));
    expect(tester.takeException(), isNull);
  });
}
