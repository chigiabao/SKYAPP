/// So sanh thoi tiet giua 2-3 dia diem: cot kinh canh nhau (hien tai) va
/// bieu do nhiet do 24 gio toi tren cung truc, co chu giai (mau + nhan +
/// kieu net + hinh diem, khong chi dua vao mau).
library;

import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/place.dart';
import '../models/units.dart';
import '../models/weather.dart';
import '../providers/location_provider.dart';
import '../providers/preferences_provider.dart';
import '../providers/weather_provider.dart';
import '../services/api_service.dart';
import '../ui/weather/app_scene.dart';
import '../ui/weather/design_tokens.dart';
import '../ui/weather/glass_ink.dart';
import '../ui/weather/weather_icons.dart';
import '../ui/weather/widgets/glass_card.dart';
import '../ui/weather/widgets/glass_page.dart';
import '../ui/weather/widgets/ios_page.dart';
import '../utils/forecast_format.dart';
import '../utils/haptics.dart';

part 'compare/compare_helpers.dart';
part 'compare/compare_column.dart';
part 'compare/compare_chart.dart';

class CompareScreen extends StatefulWidget {
  const CompareScreen({
    super.key,
    required this.locations,
    required this.locationIds,
  });

  final LocationProvider locations;
  final List<String> locationIds;

  @override
  State<CompareScreen> createState() => _CompareScreenState();
}

class _CompareScreenState extends State<CompareScreen> {
  final Map<String, WeatherResult> _data = {};
  final Map<String, ApiException> _errors = {};
  bool _loading = true;
  bool _loaded = false;
  DateTime? _loadedFor;
  int _request = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final wp = context.watch<WeatherProvider>();
    final at = wp.isReplay ? wp.replayAt : null;
    if (!_loaded || at != _loadedFor) _load(clear: true);
  }

  /// Tai lai moi dia diem; true khi khong co loi (rung keo-de-lam-moi).
  Future<bool> _load({bool clear = false}) async {
    if (!mounted) return false;
    final wp = context.read<WeatherProvider>();
    final request = ++_request;
    _loaded = true;
    _loadedFor = wp.isReplay ? wp.replayAt : null;
    final data = <String, WeatherResult>{};
    final errors = <String, ApiException>{};
    setState(() {
      _loading = true;
      _errors.clear();
      if (clear) _data.clear();
    });
    Future<void> one(String id) async {
      try {
        data[id] = await wp.fetchWeatherFor(id);
      } on ApiException catch (e) {
        errors[id] = e;
      } catch (e) {
        debugPrint('CompareScreen: $e');
        errors[id] = ApiException(ApiErrorKind.invalidData);
      }
    }

    await Future.wait([for (final id in widget.locationIds) one(id)]);
    if (!mounted || request != _request) return false;
    setState(() {
      _data.addAll(data);
      _errors.addAll(errors);
      _loading = false;
    });
    return errors.isEmpty;
  }

  @override
  Widget build(BuildContext context) =>
      GlassPage(child: Builder(builder: _buildPage));

  Widget _buildPage(BuildContext context) {
    final wp = context.watch<WeatherProvider>();
    final units = PreferencesProvider.unitsOf(context);
    final lp = widget.locations;
    final ids = widget.locationIds.take(CompareSeriesStyle.all.length).toList();

    final series = <CompareSeries>[
      for (var i = 0; i < ids.length; i++)
        CompareSeries(
          place: lp.placeById(ids[i]),
          label: _labelFor(lp, ids[i]),
          style: CompareSeriesStyle.all[i],
          result: _errors.containsKey(ids[i]) ? null : _data[ids[i]],
          error: _errors[ids[i]],
        ),
    ];

    final highlights = _loading ? null : compareHighlights(series, wp.nowHcm);
    final verdict = _loading
        ? null
        : compareVerdict(series, wp.nowHcm, units.tempNumber);
    return IosPageScaffold(
      title: 'So sánh',
      onRefresh: withRefreshHaptic(_load),
      actions: [
        IosBarButton(
          tooltip: 'Tải lại',
          icon: CupertinoIcons.refresh,
          onPressed: _loading ? null : _load,
        ),
      ],
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            Widget column(int i, {bool aligned = false}) => _CompareColumn(
              series: series[i],
              reserveNameLines: aligned,
              highlights: highlights,
              loading: _loading && series[i].result == null,
              nowHcm: wp.nowHcm,
              units: units,
            );
            // Chu lon (> 130%) hoac cot qua hep: ten phuong bi cat giua tu
            // ("Phườ / ng") -> xep doc, moi dia diem mot the full ngang.
            final colWidth =
                (constraints.maxWidth - Space.s * (series.length - 1)) /
                math.max(1, series.length);
            final stacked =
                MediaQuery.textScalerOf(context).scale(1) > 1.3 ||
                colWidth < 104;
            if (stacked) {
              return Column(
                key: const ValueKey('compare-stacked'),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < series.length; i++) ...[
                    if (i > 0) const SizedBox(height: Space.s),
                    column(i),
                  ],
                ],
              );
            }
            return IntrinsicHeight(
              key: const ValueKey('compare-columns'),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < series.length; i++) ...[
                    if (i > 0) const SizedBox(width: Space.s),
                    Expanded(child: column(i, aligned: true)),
                  ],
                ],
              ),
            );
          },
        ),
        if (verdict case final v?) ...[
          const SizedBox(height: Space.cardGap),
          GlassCard(
            title: 'KẾT LUẬN',
            icon: Icons.lightbulb_outline_rounded,
            child: Semantics(
              liveRegion: true,
              child: Text(
                v,
                style: TypeScale.label.copyWith(color: Palette.white),
              ),
            ),
          ),
        ],
        const SizedBox(height: Space.cardGap),
        GlassCard(
          title: 'Nhiệt độ 24 giờ tới',
          icon: Icons.show_chart_rounded,
          footer:
              'Mỗi đường một địa điểm; xem chú giải để phân biệt '
              '(màu, kiểu nét và hình điểm).',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              CompareLegend(series: series),
              const SizedBox(height: Space.m),
              SizedBox(
                height: 220,
                child: _loading && _data.isEmpty
                    ? const Center(child: CupertinoActivityIndicator())
                    : CompareChart(
                        series: series,
                        nowHcm: wp.nowHcm,
                        units: units,
                      ),
              ),
            ],
          ),
        ),
        const SizedBox(height: Space.m),
        Text(
          'Số liệu của mỗi địa điểm lấy theo ô dữ liệu ≈ 8 km chứa địa '
          'điểm; hai phường trong cùng ô sẽ giống nhau.',
          style: TypeScale.footnote.copyWith(
            fontWeight: FontWeight.w500,
            color: GlassInk.of(context).headerSecondary,
          ),
        ),
      ],
    );
  }

  static String? _labelFor(LocationProvider lp, String id) {
    for (final s in lp.saved) {
      if (s.locationId == id) return s.shortLabelText;
    }
    return id == lp.currentLocationId ? 'Vị trí hiện tại' : null;
  }
}
