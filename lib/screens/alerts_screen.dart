import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/weather_alerts.dart';
import '../providers/location_provider.dart';
import '../providers/planner_provider.dart';
import '../providers/weather_provider.dart';
import '../ui/weather/design_tokens.dart';
import '../ui/weather/glass_ink.dart';
import '../ui/weather/widgets/glass_card.dart';
import '../ui/weather/widgets/glass_page.dart';
import '../utils/constants.dart';
import '../widgets/planner_cards.dart';
import 'alert_settings_screen.dart';

/// Man Canh bao: canh bao hien hanh cua moi dia diem (vi tri hien tai + da
/// luu) trong cac gio toi, lich su thong bao trong app, mien tru.
class AlertsScreen extends StatefulWidget {
  const AlertsScreen({super.key, required this.locations});

  final LocationProvider locations;

  @override
  State<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends State<AlertsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _refresh();
    });
  }

  Future<void> _refresh() async {
    final planner = context.read<PlannerProvider>();
    await planner.refreshAll(context.read<WeatherProvider>(), widget.locations);
    if (mounted) planner.markAllRead();
  }

  @override
  Widget build(BuildContext context) =>
      GlassPage(child: Builder(builder: _buildPage));

  Widget _buildPage(BuildContext context) {
    final theme = Theme.of(context);
    final ink = GlassInk.of(context);
    final planner = context.watch<PlannerProvider>();
    final wp = context.watch<WeatherProvider>();
    final lp = widget.locations;
    final mq = MediaQuery.of(context);
    final gutter = Space.gutter(mq.size.width);
    final hPad = mq.size.width > Space.contentMaxWidth + 2 * gutter
        ? (mq.size.width - Space.contentMaxWidth) / 2
        : gutter;
    final ids = <String>{for (final p in lp.pages) p.locationId}.toList();

    final placeCards = <Widget>[];
    for (final id in ids) {
      final hours =
          planner.hoursFor(id) ??
          (id == wp.locationId ? wp.hourlyForecast : null);
      final err = planner.errorFor(id);
      final events = hours == null
          ? null
          : planner.alertsFor(id, hours, wp.nowHcm);
      final place = lp.placeById(id);
      final label = lp.saved
          .where((s) => s.locationId == id)
          .map((s) => s.labelText)
          .firstOrNull;
      Widget body;
      if (events == null) {
        body = Text(
          err != null
              ? 'Không tải được dữ liệu cho địa điểm này.'
              : (planner.refreshing ? 'Đang tải…' : 'Chưa có dữ liệu.'),
          style: TypeScale.body.copyWith(color: ink.secondary),
        );
      } else if (events.isEmpty) {
        body = Text(
          'Không có cảnh báo trong ${planner.settings.lookaheadHours} giờ tới.',
          style: TypeScale.body.copyWith(color: ink.secondary),
        );
      } else {
        body = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [for (final e in events) AlertEventTile(event: e)],
        );
      }
      placeCards.add(
        Padding(
          padding: const EdgeInsets.only(bottom: Space.cardGap),
          child: GlassCard(
            title: (label == null ? place.name : '$label · ${place.name}')
                .toUpperCase(),
            icon: Icons.place_outlined,
            child: body,
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Cảnh báo',
          style: AppTextStyles.heading2.copyWith(
            color: theme.textTheme.titleLarge?.color,
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Tải lại',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: planner.refreshing ? null : _refresh,
          ),
          IconButton(
            tooltip: 'Cài đặt cảnh báo',
            icon: const Icon(Icons.tune_rounded),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AlertSettingsScreen()),
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: EdgeInsets.fromLTRB(hPad, Space.s, hPad, Space.xxl),
          children: [
            GlassCard(
              icon: Icons.info_outline_rounded,
              title: 'LƯU Ý',
              child: Text(
                kAlertDisclaimer,
                style: TypeScale.body.copyWith(color: Palette.white),
              ),
            ),
            const SizedBox(height: Space.cardGap),
            if (wp.isReplay)
              Padding(
                padding: const EdgeInsets.only(bottom: Space.cardGap),
                child: GlassCard(
                  icon: Icons.history_rounded,
                  title: 'CHẾ ĐỘ XEM LẠI',
                  child: Text(
                    'Cảnh báo tính theo thời điểm xem lại; không ghi vào '
                    'lịch sử thông báo.',
                    style: TypeScale.body.copyWith(color: Palette.white),
                  ),
                ),
              ),
            if (planner.heldByQuietHours > 0)
              Padding(
                padding: const EdgeInsets.only(bottom: Space.cardGap),
                child: GlassCard(
                  icon: Icons.bedtime_outlined,
                  title: 'GIỜ YÊN LẶNG',
                  child: Text(
                    '${planner.heldByQuietHours} cảnh báo chưa thông báo do '
                    'đang trong giờ yên lặng (vẫn hiện ở đây).',
                    style: TypeScale.body.copyWith(color: Palette.white),
                  ),
                ),
              ),
            ...placeCards,
            _HistoryCard(planner: planner),
          ],
        ),
      ),
    );
  }
}

class _HistoryCard extends StatelessWidget {
  const _HistoryCard({required this.planner});

  final PlannerProvider planner;

  @override
  Widget build(BuildContext context) {
    final ink = GlassInk.of(context);
    final items = planner.history;
    return GlassCard(
      title: 'LỊCH SỬ THÔNG BÁO',
      icon: Icons.notifications_none_rounded,
      footer:
          'Thông báo hiện trong ứng dụng; không lặp lại cùng loại, '
          'địa điểm và khung giờ.',
      trailing: items.isEmpty
          ? null
          : TextButton(
              onPressed: planner.clearHistory,
              style: TextButton.styleFrom(
                foregroundColor: Palette.white,
                minimumSize: const Size(Touch.min, Touch.min),
              ),
              child: const Text('Xóa'),
            ),
      child: items.isEmpty
          ? Text(
              'Chưa có thông báo.',
              style: TypeScale.body.copyWith(color: ink.secondary),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final n in items.take(20))
                  Semantics(
                    container: true,
                    excludeSemantics: true,
                    label: '${n.title}. ${n.body}',
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: Space.s),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            alertIcon(n.type),
                            color: levelColor(context, n.level),
                            size: IconSizes.md,
                          ),
                          const SizedBox(width: Space.m),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  n.title,
                                  style: TypeScale.body.copyWith(
                                    color: Palette.white,
                                    fontWeight: n.read
                                        ? FontWeight.w400
                                        : FontWeight.w600,
                                  ),
                                ),
                                Text(
                                  '${n.body} · lúc ${_stamp(n.createdAt)}',
                                  style: TypeScale.small.copyWith(
                                    color: ink.secondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    );
  }

  static String _stamp(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')} ${t.day}/${t.month}';
}
