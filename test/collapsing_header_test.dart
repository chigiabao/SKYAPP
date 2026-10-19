import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sky_weather_app/ui/weather/app_scene.dart';
import 'package:sky_weather_app/ui/weather/glass_ink.dart';
import 'package:sky_weather_app/ui/weather/weather_scene.dart';
import 'package:sky_weather_app/ui/weather/widgets/collapsing_header.dart';
import 'package:sky_weather_app/ui/weather/widgets/glass_card.dart';

/// Loi: thanh gon cua dau trang Home de ten dia diem dai len nut Cai dat.
void main() {
  const city = 'Nhà · Phường Tân Sơn Nhất';
  const info = WeatherHeaderInfo(
    city: city,
    detail: 'Nhà · Phường Tân Sơn Nhất, TP. Hồ Chí Minh',
    temperature: '26°',
    condition: 'Nhiều mây',
    highLow: 'Cao 30° · Thấp 24°',
    feelsLike: 'Cảm giác như 33°',
    updated: 'Cập nhật 12:00',
  );
  final theme = SceneTheme.of(WeatherScene.clearDay, isDay: true);

  Future<void> pumpCollapsed(
    WidgetTester tester, {
    required double width,
    required double scale,
  }) async {
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: AppScene(
            data: const AppSceneData(
              scene: WeatherScene.clearDay,
              isDay: true,
              windSpeedKmh: 0,
              intensity: 0,
              resolved: WeatherScene.clearDay,
            ),
            child: child!,
          ),
        ),
        home: Builder(
          builder: (context) {
            final mq = MediaQuery.of(context);
            return Scaffold(
              body: CustomScrollView(
                slivers: [
                  SliverPersistentHeader(
                    pinned: true,
                    delegate: CollapsingHeaderDelegate(
                      info: info,
                      metrics: HeaderMetrics(
                        mq.textScaler,
                        topPadding: 0,
                        info: info,
                        width: width - 32,
                        viewportHeight: 800,
                      ),
                      // Lam moi: keo de lam moi (khong co nut).
                      actions: GlassIconButton(
                        tooltip: 'Cảnh báo',
                        icon: Icons.notifications_none_rounded,
                        onPressed: () {},
                      ),
                      trailing: GlassIconButton(
                        tooltip: 'Cài đặt',
                        icon: Icons.settings_outlined,
                        onPressed: () {},
                      ),
                      glassColor: theme.glassColor,
                      ink: GlassInk.forTheme(theme),
                    ),
                  ),
                  const SliverToBoxAdapter(child: SizedBox(height: 3000)),
                ],
              ),
            );
          },
        ),
      ),
    );
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -1500));
    await tester.pump();
  }

  for (final width in [360.0, 390.0, 1280.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('thanh gon: ten dai khong de len nut ($width, x$scale)', (
        tester,
      ) async {
        await pumpCollapsed(tester, width: width, scale: scale);
        expect(tester.takeException(), isNull);

        final title = find.text(city);
        expect(title, findsOneWidget);
        final titleRect = tester.getRect(title);
        final block = tester.getRect(
          find.byKey(const ValueKey<String>("compact-title")),
        );
        expect(find.byTooltip('Làm mới'), findsNothing);
        // Tieu de gon can giua man hinh.
        expect((block.center.dx - width / 2).abs(), lessThan(1));
        for (final tip in ['Cảnh báo', 'Cài đặt']) {
          final b = tester.getRect(find.byTooltip(tip));
          expect(b.width, greaterThanOrEqualTo(48));
          expect(b.height, greaterThanOrEqualTo(48));
          expect(
            titleRect.overlaps(b) || block.overlaps(b),
            isFalse,
            reason: '$titleRect / $block vs $tip $b',
          );
        }
        // Mot dong, nam trong man hinh.
        final para = tester.renderObject<RenderParagraph>(title);
        expect(
          para.size.height,
          lessThan(para.text.style!.fontSize! * scale * 2),
        );
        expect(block.right, lessThanOrEqualTo(width));
        expect(find.text('26° | Nhiều mây'), findsOneWidget);
      });
    }
  }
}
