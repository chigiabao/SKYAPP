import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sky_weather_app/ui/weather/app_scene.dart';
import 'package:sky_weather_app/ui/weather/design_tokens.dart';
import 'package:sky_weather_app/ui/weather/weather_scene.dart';
import 'package:sky_weather_app/ui/weather/widgets/bottom_pill_bar.dart';
import 'package:sky_weather_app/ui/weather/widgets/glass_card.dart';

const _sheetKey = ValueKey('glass-sheet');
const _handleKey = ValueKey('glass-sheet-drag-handle');

Future<void> _pumpSurface(
  WidgetTester tester, {
  required Widget child,
  Size size = const Size(375, 667),
  double scale = 1,
  Brightness brightness = Brightness.dark,
  EdgeInsets padding = EdgeInsets.zero,
  EdgeInsets viewInsets = EdgeInsets.zero,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: brightness),
      builder: (context, navigator) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(scale),
          disableAnimations: true,
          padding: padding,
          viewPadding: padding,
          viewInsets: viewInsets,
        ),
        child: AppScene(
          data: AppSceneData(
            scene: brightness == Brightness.light
                ? WeatherScene.clearDay
                : WeatherScene.clearNight,
            isDay: brightness == Brightness.light,
            windSpeedKmh: 0,
            intensity: 0,
            resolved: brightness == Brightness.light
                ? WeatherScene.clearDay
                : WeatherScene.clearNight,
          ),
          child: navigator!,
        ),
      ),
      home: Scaffold(body: child),
    ),
  );
}

Widget _sheetLauncher({
  required WidgetBuilder builder,
  ValueChanged<String?>? onResult,
}) => Builder(
  builder: (context) => Center(
    child: CupertinoButton(
      onPressed: () async {
        final result = await showGlassSheet<String>(
          context,
          title: 'Địa điểm đã lưu',
          builder: builder,
        );
        onResult?.call(result);
      },
      child: const Text('Open sheet'),
    ),
  ),
);

void main() {
  for (final size in [
    const Size(320, 740),
    const Size(375, 667),
    const Size(844, 390),
    const Size(1280, 900),
  ]) {
    for (final scale in [1.0, 2.0, 3.0]) {
      for (final withTrip in [false, true]) {
        testWidgets('iOS tabs fit $size x$scale, trip=$withTrip', (
          tester,
        ) async {
          final semantics = tester.ensureSemantics();
          final calls = <String>[];
          final vertical = size.width >= 1100;
          await _pumpSurface(
            tester,
            size: size,
            scale: scale,
            brightness: scale == 1 ? Brightness.light : Brightness.dark,
            child: Align(
              alignment: Alignment.bottomLeft,
              child: SizedBox(
                width: vertical ? 104 : size.width - 32,
                child: BottomPillBar(
                  pageCount: 12,
                  currentPage: 3,
                  currentLocationIndex: 3,
                  vertical: vertical,
                  onHome: () => calls.add('home'),
                  onMap: () => calls.add('map'),
                  onTrip: withTrip ? () => calls.add('trip') : null,
                  onLocations: () => calls.add('locations'),
                  tripRainPercent: 70,
                ),
              ),
            ),
          );
          expect(tester.takeException(), isNull);
          final bar = find.byType(BottomPillBar);
          final buttons = find.descendant(
            of: bar,
            matching: find.byType(CupertinoButton),
          );
          final count = withTrip ? 4 : 3;
          expect(buttons, findsNWidgets(count));
          for (final type in [Material, InkWell, Badge, FittedBox]) {
            expect(
              find.descendant(of: bar, matching: find.byType(type)),
              findsNothing,
            );
          }
          final height = BottomPillBar.heightFor(
            size.width - 32,
            TextScaler.linear(scale),
          );
          expect(
            tester.getSize(bar).height,
            vertical
                ? count * (height < 64 ? 64 : height) + 2 * Space.xs
                : height,
          );
          // iOS tab bar: 49-50 pt, tang nhe khi chu lon (toi da x1.3).
          expect(height, inInclusiveRange(50, 54));
          if (vertical) {
            final surface = tester.widget<GlassSurface>(
              find.descendant(of: bar, matching: find.byType(GlassSurface)),
            );
            expect(surface.tint!.a, lessThan(0.85));
          } else {
            final box = tester.widget<DecoratedBox>(
              find.byKey(const ValueKey('ios-tab-bar')),
            );
            final decoration = box.decoration as BoxDecoration;
            // Nen mo + lam mo (blur) + vach manh 0.5 phia tren.
            expect(decoration.color!.a, lessThan(0.85));
            expect((decoration.border! as Border).top.width, 0.5);
            expect(
              find.descendant(of: bar, matching: find.byType(BackdropFilter)),
              findsOneWidget,
            );
            expect(tester.getSize(bar).width, size.width - 32);
          }
          expect(tester.widget<Text>(find.text('Bản đồ')).style!.fontSize, 11);
          expect(tester.widget<CupertinoButton>(buttons.first).color, isNull);
          for (final button in buttons.evaluate()) {
            final bounds = tester.getRect(find.byWidget(button.widget));
            expect(bounds.width, greaterThanOrEqualTo(Touch.min));
            expect(bounds.height, greaterThanOrEqualTo(Touch.min));
          }
          final labels = [
            'Hôm nay',
            'Bản đồ',
            if (withTrip) 'Ra ngoài',
            'Địa điểm',
          ];
          for (var i = 0; i < labels.length; i++) {
            final text = tester.widget<Text>(find.text(labels[i]));
            expect(text.maxLines, 1);
            expect(text.softWrap, isFalse);
            expect(
              text.style!.color,
              i == 0 ? Palette.rain : Palette.secondary,
            );
            if (i > 0) {
              final previous = tester.getCenter(find.text(labels[i - 1]));
              final current = tester.getCenter(find.text(labels[i]));
              expect(
                vertical ? current.dy > previous.dy : current.dx > previous.dx,
                isTrue,
              );
            }
          }
          expect(
            tester.getSemantics(find.bySemanticsLabel('Hôm nay')),
            matchesSemantics(
              label: 'Hôm nay',
              isButton: true,
              isSelected: true,
              hasSelectedState: true,
              hasTapAction: true,
            ),
          );
          expect(
            find.bySemanticsLabel(
              'Danh sách địa điểm. Vị trí hiện tại. Địa điểm 4 trên 12',
            ),
            findsOneWidget,
          );
          if (withTrip) {
            expect(find.text('70%'), findsNothing);
            final trip = tester.getSemantics(
              find.bySemanticsLabel(
                'Tôi sắp ra ngoài. Khả năng mưa 2 giờ tới 70%',
              ),
            );
            trip.owner!.performAction(trip.id, SemanticsAction.tap);
            expect(calls.removeLast(), 'trip');
          }
          for (final tooltip in [
            'Thời tiết hôm nay',
            'Bản đồ',
            if (withTrip) 'Tôi sắp ra ngoài',
            'Danh sách địa điểm',
          ]) {
            await tester.tap(find.byTooltip(tooltip));
          }
          expect(calls, ['home', 'map', if (withTrip) 'trip', 'locations']);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          semantics.dispose();
        });
      }
    }
  }

  testWidgets('three tabs retain optional Home and desktop keyboard access', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    var maps = 0;
    await _pumpSurface(
      tester,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: BottomPillBar(
          pageCount: 2,
          currentPage: 0,
          firstIsCurrentLocation: false,
          onMap: () => maps++,
          onLocations: () {},
        ),
      ),
    );
    expect(find.byTooltip('Tôi sắp ra ngoài'), findsNothing);
    expect(
      tester.getSemantics(find.bySemanticsLabel('Hôm nay')),
      matchesSemantics(
        label: 'Hôm nay',
        isButton: true,
        isSelected: true,
        hasSelectedState: true,
      ),
    );
    expect(
      find.bySemanticsLabel('Danh sách địa điểm. Địa điểm 1 trên 2'),
      findsOneWidget,
    );
    Focus.of(tester.element(find.text('Bản đồ'))).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(maps, 1);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('rain data stays accessible without resizing the bar', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final rain = ValueNotifier<int?>(null);
    addTearDown(rain.dispose);
    await _pumpSurface(
      tester,
      scale: 3,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: ValueListenableBuilder<int?>(
          valueListenable: rain,
          builder: (_, value, _) => BottomPillBar(
            pageCount: 1,
            currentPage: 0,
            onMap: () {},
            onLocations: () {},
            onTrip: () {},
            tripRainPercent: value,
          ),
        ),
      ),
    );
    final size = tester.getSize(find.byType(BottomPillBar));
    final dot = find.byWidgetPredicate(
      (widget) => widget is SizedBox && widget.width == 5 && widget.height == 5,
    );
    expect(dot, findsNothing);
    expect(find.bySemanticsLabel('Tôi sắp ra ngoài'), findsOneWidget);
    for (final value in [0, 100]) {
      rain.value = value;
      await tester.pump();
      expect(dot, findsOneWidget);
      expect(find.text('$value%'), findsNothing);
      expect(
        find.bySemanticsLabel(
          'Tôi sắp ra ngoài. Khả năng mưa 2 giờ tới $value%',
        ),
        findsOneWidget,
      );
      expect(tester.getSize(find.byType(BottomPillBar)), size);
    }
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  for (final size in [const Size(320, 667), const Size(1280, 900)]) {
    testWidgets(
      'sheet fits safe area and keyboard, scrolls and returns $size',
      (tester) async {
        final semantics = tester.ensureSemantics();
        String? result;
        await _pumpSurface(
          tester,
          size: size,
          scale: 2,
          padding: const EdgeInsets.fromLTRB(0, 44, 0, 34),
          viewInsets: const EdgeInsets.only(bottom: 240),
          child: _sheetLauncher(
            onResult: (value) => result = value,
            builder: (context) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < 30; i++) Text('Saved location $i'),
                CupertinoButton(
                  key: const ValueKey('choose-location'),
                  onPressed: () => Navigator.of(context).pop('saved-place'),
                  child: const Text('Choose location'),
                ),
              ],
            ),
          ),
        );
        await tester.tap(find.text('Open sheet'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final bounds = tester.getRect(find.byKey(_sheetKey));
        expect(bounds.width, lessThanOrEqualTo(Space.contentMaxWidth));
        expect(bounds.center.dx, closeTo(size.width / 2, 0.01));
        expect(bounds.top, greaterThanOrEqualTo(44));
        expect(bounds.bottom, lessThanOrEqualTo(size.height - 240));
        final clip = tester.widget<ClipRRect>(find.byKey(_sheetKey));
        expect(
          clip.borderRadius,
          const BorderRadius.vertical(top: Radius.circular(Radii.sheet)),
        );
        expect(find.byKey(_handleKey), findsOneWidget);
        expect(
          tester.getSize(find.text('Địa điểm đã lưu')).height,
          lessThanOrEqualTo(100),
        );
        expect(
          tester.getSemantics(find.text('Địa điểm đã lưu')),
          matchesSemantics(label: 'Địa điểm đã lưu', isHeader: true),
        );
        expect(
          tester.getSize(find.byTooltip('Đóng')).shortestSide,
          greaterThanOrEqualTo(Touch.min),
        );
        await tester.ensureVisible(
          find.byKey(const ValueKey('choose-location')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('choose-location')));
        await tester.pumpAndSettle();
        expect(result, 'saved-place');
        expect(find.byKey(_sheetKey), findsNothing);
        expect(tester.takeException(), isNull);
        semantics.dispose();
      },
    );
  }

  for (final dismiss in ['close', 'barrier', 'drag', 'back']) {
    testWidgets('sheet $dismiss dismissal returns null', (tester) async {
      var completed = false;
      String? result = 'not closed';
      await _pumpSurface(
        tester,
        child: _sheetLauncher(
          onResult: (value) {
            completed = true;
            result = value;
          },
          builder: (_) => const Text('Saved locations'),
        ),
      );
      await tester.tap(find.text('Open sheet'));
      await tester.pumpAndSettle();
      switch (dismiss) {
        case 'close':
          await tester.tap(find.byTooltip('Đóng'));
        case 'barrier':
          await tester.tapAt(const Offset(8, 8));
        case 'drag':
          await tester.fling(
            find.byKey(_handleKey),
            const Offset(0, 360),
            1200,
          );
        case 'back':
          await tester.binding.handlePopRoute();
      }
      await tester.pumpAndSettle();
      expect(completed, isTrue);
      expect(result, isNull);
      expect(find.byKey(_sheetKey), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
