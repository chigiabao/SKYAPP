/// Thanh tren, thong bao loi va thanh thoi gian cua ban do.
library;

import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../models/place.dart';
import '../../models/weather.dart';
import '../../providers/location_provider.dart';
import '../../services/api_service.dart';

import '../../ui/weather/design_tokens.dart';
import '../../ui/weather/widgets/glass_card.dart';
import '../map_screen.dart';
import 'map_scale.dart';
import '../../ui/weather/widgets/app_segmented_control.dart';
import '../../utils/forecast_format.dart';

class MapTopBar extends StatelessWidget {
  const MapTopBar({
    super.key,
    required this.layer,
    required this.onLayer,
    required this.loading,
    required this.onRefresh,
    required this.onList,
    required this.chips,
  });

  final MapLayerKind layer;
  final ValueChanged<MapLayerKind> onLayer;
  final bool loading;
  final VoidCallback onRefresh;
  final VoidCallback? onList;
  final List<Widget> chips;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GlassSurface(
          tint: Palette.sheetBase,
          radius: Radii.pill,
          padding: const EdgeInsets.symmetric(horizontal: Space.xs),
          child: Row(
            children: [
              // Goc tab Ban do: khong co nut quay lai.
              if (ModalRoute.of(context)?.impliesAppBarDismissal ?? false)
                GlassIconButton(
                  icon: CupertinoIcons.back,
                  tooltip: 'Quay lại',
                  onPressed: () => Navigator.maybePop(context),
                )
              else
                const SizedBox(width: Touch.min),
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    'Bản đồ',
                    textAlign: TextAlign.center,
                    style: TypeScale.headline.copyWith(color: Palette.white),
                  ),
                ),
              ),
              GlassIconButton(
                icon: CupertinoIcons.list_bullet,
                tooltip: 'Xem dạng danh sách',
                onPressed: onList,
              ),
              SizedBox.square(
                dimension: Touch.min,
                child: loading
                    ? const Center(
                        child: CupertinoActivityIndicator(color: Palette.white),
                      )
                    : GlassIconButton(
                        icon: CupertinoIcons.refresh,
                        tooltip: 'Làm mới',
                        onPressed: onRefresh,
                      ),
              ),
            ],
          ),
        ),
        const SizedBox(height: Space.s),
        GlassSurface(
          tint: Palette.sheetBase,
          radius: Radii.small,
          padding: EdgeInsets.zero,
          child: AppSegmentedControl<MapLayerKind>(
            segments: [
              for (final l in MapLayerKind.values)
                AppSegment(value: l, label: l.label, icon: l.icon),
            ],
            selected: layer,
            onChanged: onLayer,
          ),
        ),
        if (chips.isNotEmpty) ...[const SizedBox(height: Space.s), ...chips],
      ],
    );
  }
}

class MapMessageCard extends StatelessWidget {
  const MapMessageCard({super.key, required this.messages});

  final List<String> messages;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: GlassSurface(
        tint: Palette.sheetBase,
        padding: const EdgeInsets.all(Space.m),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final m in messages)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.cloud_off_outlined,
                      size: IconSizes.sm,
                      color: Palette.white,
                    ),
                    const SizedBox(width: Space.s),
                    Expanded(
                      child: Text(
                        m,
                        style: TypeScale.footnote.copyWith(
                          fontWeight: FontWeight.w500,
                          color: Palette.white,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Thanh thoi gian 0..[max] gio (thay radar). Xem lai: khoa, chi hien loi
/// giai thich. Giam chuyen dong: tat nut tu chay.
class MapTimeBar extends StatelessWidget {
  const MapTimeBar({
    super.key,
    required this.value,
    required this.max,
    required this.base,
    required this.locked,
    required this.loading,
    required this.playing,
    required this.reduceMotion,
    required this.onChanged,
    required this.onChangeEnd,
    required this.onTogglePlay,
  });

  final int value;
  final int max;

  /// Gio TP.HCM ung voi offset 0.
  final DateTime base;
  final bool locked;
  final bool loading;
  final bool playing;
  final bool reduceMotion;
  final ValueChanged<int> onChanged;
  final ValueChanged<int> onChangeEnd;
  final VoidCallback onTogglePlay;

  static const String lockedText =
      'Chế độ xem lại chỉ xem được thời điểm đã chọn';

  /// "+3 giờ, 18:00 Thứ 7, 17/10" (Semantics + nhan).
  String textFor(int h) =>
      '${offsetLabel(h)}, ${mapClockLabel(base.add(Duration(hours: h)))}';

  @override
  Widget build(BuildContext context) {
    final small = TypeScale.small.copyWith(color: Palette.white);
    if (locked) {
      return GlassSurface(
        tint: Palette.sheetBase,
        padding: const EdgeInsets.all(Space.m),
        child: Row(
          children: [
            const Icon(
              Icons.lock_clock_outlined,
              size: IconSizes.sm + 2,
              color: Palette.white,
            ),
            const SizedBox(width: Space.s),
            Expanded(child: Text(lockedText, style: small)),
          ],
        ),
      );
    }
    final v = value.clamp(0, max);
    final ticks = max <= 0 ? [0] : [for (var i = 0; i <= 3; i++) max * i ~/ 3];
    return GlassSurface(
      tint: Palette.sheetBase,
      padding: const EdgeInsets.fromLTRB(Space.xs, Space.xs, Space.m, Space.s),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              GlassIconButton(
                icon: playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                tooltip: reduceMotion
                    ? 'Tự chạy đã tắt (giảm chuyển động)'
                    : playing
                    ? 'Dừng'
                    : 'Tự chạy qua các giờ',
                onPressed: reduceMotion || max <= 0 ? null : onTogglePlay,
              ),
              const SizedBox(width: Space.xs),
              Expanded(
                child: Text(
                  '${offsetLabel(v)} · '
                  '${mapClockLabel(base.add(Duration(hours: v)))}',
                  style: TypeScale.label.copyWith(
                    color: Palette.white,
                    fontWeight: FontWeight.w600,
                    fontFeatures: kTabular,
                  ),
                ),
              ),
              if (loading)
                const SizedBox.square(
                  dimension: 16,
                  child: CupertinoActivityIndicator(
                    radius: 8,
                    color: Palette.white,
                  ),
                ),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: Palette.white,
              inactiveTrackColor: Palette.track,
              thumbColor: Palette.white,
              overlayColor: Palette.highlight,
              activeTickMarkColor: Colors.transparent,
              inactiveTickMarkColor: Colors.transparent,
            ),
            child: Slider(
              value: v.toDouble(),
              max: math.max(max, 1).toDouble(),
              divisions: math.max(max, 1),
              label: offsetLabel(v),
              semanticFormatterCallback: (d) => textFor(d.round()),
              onChanged: max <= 0 ? null : (d) => onChanged(d.round()),
              onChangeEnd: max <= 0 ? null : (d) => onChangeEnd(d.round()),
            ),
          ),
          // Moc gio dat dung vi tri tren ray slider (ray thut ~24dp).
          ExcludeSemantics(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.m),
              child: SizedBox(
                // Cao theo dung token chu cua nhan (TypeScale.small 12 pt).
                height:
                    MediaQuery.textScalerOf(context)
                        .scale(TypeScale.small.fontSize!) *
                    1.5,
                child: Stack(
                  children: [
                    for (final t in ticks)
                      Align(
                        alignment: Alignment(
                          max <= 0 ? -1 : -1 + 2 * t / max,
                          0,
                        ),
                        child: Text(
                          offsetLabel(t),
                          maxLines: 1,
                          style: small.copyWith(
                            color: Palette.secondary,
                            fontFeatures: kTabular,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Cac phan cua dong trang thai: khung dang xem, xem lai, du lieu cu.
List<String> mapStatusParts({
  required List<MapCell> cells,
  required bool isReplay,
  required DateTime? replayAt,
  required LocationProvider lp,
  required DateTime nowHcm,
}) {
  final first = cells.isEmpty ? null : cells.first;
  final observed = cells.where((c) => c.source == DataSource.observed).toList();
  final times = observed.map((c) => c.observedAt).nonNulls.toList()..sort();
  final frameLabel = observed.isEmpty
      ? mapFrameLabel(first?.source, first?.validTime)
      : times.isEmpty
      ? mapFrameLabel(DataSource.observed, null)
      : times.first != times.last
      ? 'Đã ghi nhận (mô hình) từ ${ForecastFormat.dateTime(times.first)} '
            'đến ${ForecastFormat.dateTime(times.last)}'
      : mapFrameLabel(DataSource.observed, null, observedAt: times.first);
  return [
    ?frameLabel,
    if (times.isNotEmpty && times.length < observed.length)
      'Có ô chưa rõ giờ dữ liệu',
    if (isReplay) 'Xem lại ${ForecastFormat.dateTime(replayAt!)}',
    if (cells.any((c) => c.isStaleAt(nowHcm))) 'Dữ liệu cũ',
    if (lp.cellsStale && cells.isNotEmpty) 'Đang dùng bản lưu trên máy',
  ];
}

/// MOT dong trang thai gon (thay 2-3 chip xep chong): "Dự báo lúc 18:00
/// T7 · Xem lại 21/10 21:00 · Dữ liệu cũ". Icon dong ho doi mau khi du lieu
/// cu; chu tu xuong dong khi chu lon.
List<Widget> mapStatusChips({
  required List<MapCell> cells,
  required bool isReplay,
  required DateTime? replayAt,
  required LocationProvider lp,
  required DateTime nowHcm,
}) {
  final parts = mapStatusParts(
    cells: cells,
    isReplay: isReplay,
    replayAt: replayAt,
    lp: lp,
    nowHcm: nowHcm,
  );
  if (parts.isEmpty) return const [];
  final stale =
      lp.cellsStale && cells.isNotEmpty ||
      cells.any((c) => c.isStaleAt(nowHcm));
  final first = cells.isEmpty ? null : cells.first;
  return [
    Semantics(
      key: const ValueKey('map-status-line'),
      liveRegion: true,
      container: true,
      label: parts.join('. '),
      excludeSemantics: true,
      child: Align(
        alignment: Alignment.centerLeft,
        child: GlassSurface(
          tint: Palette.sheetBase,
          radius: Radii.pill,
          padding: const EdgeInsets.symmetric(
            horizontal: Space.m,
            vertical: Space.xs + 2,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isReplay
                    ? CupertinoIcons.time
                    : first?.source == DataSource.observed
                    ? CupertinoIcons.checkmark_seal
                    : CupertinoIcons.clock,
                size: 14,
                color: stale ? Palette.stale : Palette.white,
              ),
              const SizedBox(width: Space.xs + 2),
              Flexible(
                child: Text(
                  parts.join(' · '),
                  style: TypeScale.footnote.copyWith(
                    color: Palette.white,
                    fontFeatures: kTabular,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  ];
}

/// Thong bao khi mat ban do nen hoac chua co du lieu o.
List<String> mapMessages({
  required bool tilesFailed,
  required List<MapCell> cells,
  required LocationProvider lp,
}) => [
  if (tilesFailed) 'Mất bản đồ nền; dữ liệu thời tiết vẫn hiển thị.',
  if (cells.isEmpty && !lp.mapLoading)
    lp.mapError == ApiErrorKind.notFound
        ? 'Máy chủ chưa hỗ trợ dữ liệu bản đồ.'
        : lp.mapError != null
        ? 'Không tải được dữ liệu bản đồ. '
              '${ApiException.messageFor(lp.mapError!)}'
        : 'Chưa có dữ liệu bản đồ.',
];
