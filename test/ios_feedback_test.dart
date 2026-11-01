// Phan hoi iOS: thong bao (toast) voi trinh doc man hinh, rung khi lam moi
// (chi "thanh cong" khi tai duoc) va rung cua thanh truot (mot kieu).
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sky_weather_app/ui/weather/widgets/ios_controls.dart';
import 'package:sky_weather_app/ui/weather/widgets/ios_toast.dart';
import 'package:sky_weather_app/utils/haptics.dart';

/// Ghi lai cac lan goi HapticFeedback (kieu rung).
List<String> _recordHaptics(WidgetTester tester) {
  final haptics = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'HapticFeedback.vibrate') {
        haptics.add((call.arguments as String?) ?? 'vibrate');
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  return haptics;
}

Future<void> _pumpToastHost(
  WidgetTester tester, {
  required bool accessible,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(disableAnimations: true, accessibleNavigation: accessible),
        child: child!,
      ),
      home: Builder(
        builder: (context) => CupertinoButton(
          onPressed: () => showIosToast(
            context,
            'Đã xóa địa điểm.',
            actionLabel: 'Hoàn tác',
            onAction: () {},
          ),
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pump();
}

void main() {
  group('IosToast', () {
    testWidgets('co nut hanh dong + trinh doc man hinh: khong tu an', (
      tester,
    ) async {
      await _pumpToastHost(tester, accessible: true);
      expect(find.text('Đã xóa địa điểm.'), findsOneWidget);
      await tester.pump(const Duration(seconds: 30));
      expect(find.text('Đã xóa địa điểm.'), findsOneWidget);
      // Bam nut -> an.
      await tester.tap(find.text('Hoàn tác'));
      await tester.pump();
      expect(find.text('Đã xóa địa điểm.'), findsNothing);
    });

    testWidgets('khong co trinh doc man hinh: tu an sau 6 giay', (
      tester,
    ) async {
      await _pumpToastHost(tester, accessible: false);
      expect(find.text('Đã xóa địa điểm.'), findsOneWidget);
      await tester.pump(const Duration(seconds: 7));
      expect(find.text('Đã xóa địa điểm.'), findsNothing);
    });
  });

  group('haptics', () {
    testWidgets('error() la rung manh ngan, khong phai vibrate dai', (
      tester,
    ) async {
      final haptics = _recordHaptics(tester);
      AppHaptics.error();
      await tester.pump();
      expect(haptics, ['HapticFeedbackType.heavyImpact']);
    });

    testWidgets('lam moi: thanh cong -> success; that bai -> error', (
      tester,
    ) async {
      final haptics = _recordHaptics(tester);
      await withRefreshHaptic(() async => true)();
      expect(haptics, ['HapticFeedbackType.mediumImpact']);
      haptics.clear();
      await withRefreshHaptic(() async => false)();
      expect(haptics, ['HapticFeedbackType.heavyImpact']);
      haptics.clear();
      await expectLater(
        withRefreshHaptic(() async => throw StateError('x'))(),
        throwsStateError,
      );
      expect(haptics, ['HapticFeedbackType.heavyImpact']);
    });

    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      testWidgets('IosSlider: mot tick moi nac, khong rung luc tha '
          '(${platform.name})', (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        final haptics = _recordHaptics(tester);
        var value = 5.0;
        var ended = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) => IosSlider(
                  value: value,
                  min: 0,
                  max: 10,
                  divisions: 10,
                  valueLabel: '${value.round()}',
                  semanticLabel: 'Ngưỡng',
                  onChanged: (v) => setState(() => value = v),
                  onChangeEnd: (_) => ended++,
                ),
              ),
            ),
          ),
        );
        CupertinoSlider slider() =>
            tester.widget<CupertinoSlider>(find.byType(CupertinoSlider));
        slider().onChanged!(6);
        await tester.pump();
        expect(haptics, ['HapticFeedbackType.selectionClick']);
        slider().onChangeEnd!(6);
        await tester.pump();
        expect(ended, 1);
        expect(haptics, hasLength(1), reason: 'khong rung them luc tha');
        // Dau thanh: iOS da tu rung trong CupertinoSlider -> khong rung doi.
        slider().onChanged!(10);
        await tester.pump();
        expect(haptics, hasLength(platform == TargetPlatform.iOS ? 1 : 2));
        debugDefaultTargetPlatformOverride = null;
      });
    }
  });
}
