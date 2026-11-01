/// The "Vị trí hiện tại" va chu thich cuoi danh sach.
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../providers/location_provider.dart';
import '../../ui/weather/design_tokens.dart';
import '../../ui/weather/glass_ink.dart';
import '../../ui/weather/widgets/glass_card.dart';
import '../locations_screen.dart';
import 'locations_widgets.dart';
import '../../utils/forecast_format.dart';

class LocationsGpsCard extends StatelessWidget {
  const LocationsGpsCard({
    super.key,
    required this.lp,
    required this.onUse,
    required this.onOpen,
  });

  final LocationProvider lp;
  final VoidCallback onUse;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    final ink = GlassInk.of(context);
    final id = lp.currentLocationId;
    final outcome = lp.gpsOutcome;
    final viewing = lp.selectedPage.isCurrentLocation;
    final children = <Widget>[];
    if (id != null) {
      final p = lp.placeById(id);
      children.add(
        Row(
          children: [
            Expanded(
              child: Pressable(
                onTap: () => onOpen(id),
                semanticsLabel:
                    'Vị trí hiện tại: ${p.name}${viewing ? ', đang xem' : ''}',
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: Space.xs),
                  child: Row(
                    children: [
                      const Icon(Icons.near_me_rounded, color: Palette.white),
                      const SizedBox(width: Space.m),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Vị trí hiện tại',
                              style: TypeScale.footnote.copyWith(
                                fontWeight: FontWeight.w500,
                                color: ink.secondary,
                              ),
                            ),
                            Text(
                              p.name,
                              style: TypeScale.label.copyWith(
                                color: Palette.white,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                      ExcludeSemantics(
                        child: PlaceWeatherSummary(cell: lp.cellFor(id)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            GlassIconButton(
              icon: lp.gpsBusy
                  ? Icons.hourglass_top_rounded
                  : Icons.refresh_rounded,
              tooltip: 'Cập nhật vị trí',
              onPressed: lp.gpsBusy ? null : onUse,
            ),
            GlassIconButton(
              icon: Icons.location_disabled_rounded,
              tooltip: 'Tắt vị trí hiện tại',
              onPressed: lp.disableCurrentLocation,
            ),
          ],
        ),
      );
    } else {
      children.add(
        Pressable(
          onTap: lp.gpsBusy ? null : onUse,
          semanticsLabel: 'Dùng vị trí hiện tại',
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: Touch.min),
            child: Row(
              children: [
                const Icon(Icons.near_me_outlined, color: Palette.white),
                const SizedBox(width: Space.m),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Dùng vị trí hiện tại',
                        style: TypeScale.label.copyWith(
                          color: Palette.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        'Chỉ lưu tên phường, xã — không lưu tọa độ.',
                        style: TypeScale.footnote.copyWith(
                          fontWeight: FontWeight.w500,
                          color: ink.secondary,
                        ),
                      ),
                    ],
                  ),
                ),
                if (lp.gpsBusy)
                  const SizedBox.square(
                    dimension: 22,
                    child: CupertinoActivityIndicator(color: Palette.white),
                  )
                else
                  const Icon(
                    CupertinoIcons.chevron_forward,
                    color: Palette.white,
                  ),
              ],
            ),
          ),
        ),
      );
    }
    if (outcome != null && !outcome.ok) {
      children.add(
        Padding(
          padding: const EdgeInsets.only(top: Space.m),
          child: Semantics(
            liveRegion: true,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  outcome.kind == GpsOutcomeKind.outsideArea
                      ? Icons.wrong_location_outlined
                      : Icons.location_off_outlined,
                  color: ink.warning,
                  size: IconSizes.md - 4,
                ),
                const SizedBox(width: Space.s),
                Expanded(
                  child: Text(
                    outcome.message,
                    style: TypeScale.subhead.copyWith(color: Palette.white),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      children.add(
        Padding(
          padding: const EdgeInsets.only(top: Space.s),
          child: Wrap(
            spacing: Space.s,
            children: [
              if (outcome.canOpenSettings)
                OutlinedButton.icon(
                  onPressed: () => lp.openSettingsFor(outcome),
                  icon: const Icon(Icons.settings_outlined, size: 18),
                  label: const Text('Mở cài đặt'),
                ),
              TextButton(
                onPressed: lp.clearGpsOutcome,
                child: const Text('Đóng'),
              ),
            ],
          ),
        ),
      );
    }
    return GlassSurface(
      padding: const EdgeInsets.fromLTRB(Space.l, Space.s, Space.xs, Space.s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}

class LocationsFooter extends StatelessWidget {
  const LocationsFooter({
    super.key,
    required this.lp,
    this.showEditHint = true,
  });

  /// false o che do chon de so sanh: vuot/keo bi tat, khong huong dan sai.
  final bool showEditHint;

  final LocationProvider lp;

  @override
  Widget build(BuildContext context) {
    final ink = GlassInk.of(context);
    final lines = <String>[
      'Nhiệt độ và khả năng mưa 3 giờ tới lấy theo ô dữ liệu ≈ 8 km chứa '
          'địa điểm.',
      if (lp.cellsStale && lp.cells.isNotEmpty)
        'Dữ liệu cũ${lp.cellsSavedAt == null ? '' : ' (lưu ${ForecastFormat.dateTime(lp.cellsSavedAt!)})'}.',
      if (lp.cells.isEmpty && !lp.mapLoading)
        'Chưa có số liệu nhanh cho danh sách (máy chủ chưa hỗ trợ hoặc '
            'đang ngoại tuyến).',
    ];
    final style = TypeScale.footnote.copyWith(
      color: ink.headerSecondary,
      height: 1.45,
    );
    // Bieu tuong ve bang widget (khong dung ky tu dac biet: font co the
    // thieu glyph -> hien "▯▯").
    WidgetSpan icon(IconData data, String label) => WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: Semantics(
        label: label,
        child: Icon(data, size: 15, color: ink.headerSecondary),
      ),
    );
    return Text.rich(
      TextSpan(
        style: style,
        children: [
          TextSpan(text: lines.join('\n')),
          if (showEditHint) ...[
            const TextSpan(text: '\nVuốt sang trái để xóa. Đổi thứ tự: giữ '),
            icon(CupertinoIcons.line_horizontal_3, 'biểu tượng kéo'),
            const TextSpan(text: ' rồi kéo, hoặc bấm '),
            icon(CupertinoIcons.ellipsis_circle, 'nút tùy chọn'),
            const TextSpan(text: ' › Di chuyển lên / Di chuyển xuống.'),
          ],
        ],
      ),
    );
  }
}
