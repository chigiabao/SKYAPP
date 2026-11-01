import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../providers/location_provider.dart';
import '../../providers/trip_provider.dart';
import '../../ui/weather/design_tokens.dart';
import '../../ui/weather/glass_ink.dart';
import '../../ui/weather/widgets/glass_card.dart';
import 'trip_helpers.dart';
import '../../ui/weather/widgets/ios_list.dart';
import '../../utils/haptics.dart';
import '../../utils/forecast_format.dart';

class EndedCard extends StatelessWidget {
  const EndedCard({super.key, required this.trip, required this.locations});

  final TripProvider trip;
  final LocationProvider locations;

  @override
  Widget build(BuildContext context) {
    final n = trip.alerts.length;
    return GlassCard(
      title: 'CHUYẾN ĐI ĐÃ KẾT THÚC',
      icon: Icons.check_circle_outline_rounded,
      trailing: TextButton(onPressed: trip.reset, child: const Text('Đóng')),
      child: Text(
        n == 0
            ? 'Chưa ghi nhận cảnh báo; không đồng nghĩa tuyến an toàn.'
            : '$n cảnh báo trên đường.',
        style: TypeScale.body.copyWith(color: Palette.white),
      ),
    );
  }
}

class HistoryCard extends StatelessWidget {
  const HistoryCard({super.key, required this.trip, required this.locations});

  final TripProvider trip;
  final LocationProvider locations;

  String _name(String? id) => id == null ? '?' : locations.placeById(id).name;

  @override
  Widget build(BuildContext context) {
    final ink = GlassInk.of(context);
    final items = trip.history;
    return GlassCard(
      title: 'LỊCH SỬ CHUYẾN ĐI',
      icon: Icons.history_rounded,
      footer:
          'Chỉ lưu trên máy: phường đi, phường đến, thời gian và cảnh báo. '
          'Không lưu đường đi GPS.',
      trailing: items.isEmpty
          ? null
          : TextButton(
              onPressed: trip.clearHistory,
              child: const Text('Xóa tất cả'),
            ),
      child: Material(
        type: MaterialType.transparency,
        child: items.isEmpty
            ? Text(
                'Chưa có chuyến đi nào.',
                style: TypeScale.body.copyWith(color: ink.secondary),
              )
            : Column(
                children: [
                  for (final (i, r) in items.indexed) ...[
                    if (i > 0) const Divider(height: 1, color: Palette.divider),
                    // Nut xoa nam ngoai hang (hang gop nghia rieng, nut doc
                    // rieng).
                    Row(
                      children: [
                        Expanded(
                          child: IosListRow(
                            title: '${_name(r.fromId)} → ${_name(r.toId)}',
                            subtitle:
                                '${ForecastFormat.dayMonth(r.startedAt)} '
                                '${formatHhmm(r.startedAt)}–'
                                '${formatHhmm(r.endedAt)} · '
                                '${r.alerts.length} cảnh báo',
                          ),
                        ),
                        CupertinoButton(
                          padding: EdgeInsets.zero,
                          minimumSize: const Size(Touch.min, Touch.min),
                          onPressed: () {
                            AppHaptics.warning();
                            trip.deleteRecord(r.id);
                          },
                          child: const Icon(
                            CupertinoIcons.trash,
                            size: IconSizes.inline + 2,
                            color: Palette.dangerOnGlass,
                            semanticLabel: 'Xóa chuyến đi',
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
      ),
    );
  }
}
