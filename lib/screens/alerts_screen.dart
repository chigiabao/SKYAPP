import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
            child: AnimatedSwitcher(
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : Motion.short,
              layoutBuilder: (cur, prev) => Stack(
                alignment: Alignment.topLeft,
                children: [...prev, ?cur],
              ),
              child: KeyedSubtree(
                key: ValueKey(
                  events == null ? 'x$err' : events.map((e) => e.key).join(),
                ),
                child: body,
              ),
            ),
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

class _HistoryCard extends StatefulWidget {
  const _HistoryCard({required this.planner});

  final PlannerProvider planner;

  @override
  State<_HistoryCard> createState() => _HistoryCardState();
}

/// Lich su co hieu ung: muc moi truot + hien dan, muc da doc nhat dan (chu
/// dam -> thuong, cham "mới" tat dan). Giam chuyen dong -> khong hieu ung.
class _HistoryCardState extends State<_HistoryCard> {
  /// Khoa cac muc da ve (muc moi = chua co trong tap nay).
  Set<String>? _seen;
  int _unread = 0;

  void _clear() {
    HapticFeedback.mediumImpact();
    widget.planner.clearHistory();
  }

  @override
  Widget build(BuildContext context) {
    final ink = GlassInk.of(context);
    final planner = widget.planner;
    final items = planner.history.take(20).toList();
    final still = MediaQuery.disableAnimationsOf(context);
    final dur = still ? Duration.zero : Motion.medium;
    final keys = [for (final n in items) noticeKey(n)];
    final first = _seen == null;
    final fresh = first ? const <String>{} : {...keys}.difference(_seen!);
    final unread = planner.unreadCount;
    // Rung nhe khi co muc moi / khi danh dau da doc (khong rung lan dau).
    if (!first && (fresh.isNotEmpty || unread < _unread)) {
      final added = fresh.isNotEmpty;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => added
            ? HapticFeedback.lightImpact()
            : HapticFeedback.selectionClick(),
      );
    }
    _seen = {...keys};
    _unread = unread;
    return GlassCard(
      title: 'LỊCH SỬ THÔNG BÁO',
      icon: Icons.notifications_none_rounded,
      footer:
          'Thông báo hiện trong ứng dụng; không lặp lại cùng loại, '
          'địa điểm và khung giờ.',
      trailing: items.isEmpty
          ? null
          : TextButton(
              onPressed: _clear,
              style: TextButton.styleFrom(
                foregroundColor: Palette.white,
                minimumSize: const Size(Touch.min, Touch.min),
              ),
              child: const Text('Xóa'),
            ),
      // AnimatedSize voi thoi luong 0 loi bo cuc -> chi dung khi co hieu ung.
      child: _MaybeAnimatedSize(
        duration: dur,
        child: items.isEmpty
            ? Text(
                'Chưa có thông báo.',
                style: TypeScale.body.copyWith(color: ink.secondary),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < items.length; i++)
                    _Enter(
                      key: ValueKey(keys[i]),
                      animate: !still && fresh.contains(keys[i]),
                      child: _row(context, items[i], ink, dur),
                    ),
                ],
              ),
      ),
    );
  }

  Widget _row(
    BuildContext context,
    AlertNotice n,
    GlassInk ink,
    Duration dur,
  ) {
    return Semantics(
      container: true,
      excludeSemantics: true,
      label: '${n.read ? '' : 'Mới. '}${n.title}. ${n.body}',
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
                  AnimatedDefaultTextStyle(
                    duration: dur,
                    style: TypeScale.body.copyWith(
                      color: Palette.white,
                      fontWeight: n.read ? FontWeight.w400 : FontWeight.w600,
                    ),
                    child: Text(n.title),
                  ),
                  Text(
                    '${n.body} · lúc ${_stamp(n.createdAt)}',
                    style: TypeScale.small.copyWith(color: ink.secondary),
                  ),
                ],
              ),
            ),
            // Cham "mới" (tin hieu phu; chu dam la tin hieu chinh).
            AnimatedOpacity(
              duration: dur,
              opacity: n.read ? 0 : 1,
              child: Padding(
                padding: const EdgeInsets.only(left: Space.s, top: 6),
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: GlassInk.of(context).alert,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _stamp(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')} ${t.day}/${t.month}';
}

/// Muc moi: truot len + hien dan mot lan.
class _Enter extends StatelessWidget {
  const _Enter({super.key, required this.animate, required this.child});

  final bool animate;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Luon cung kieu widget: rebuild giua chung khong lam nhay hieu ung.
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: animate ? 0 : 1, end: 1),
      duration: Motion.medium,
      curve: Motion.enter,
      builder: (context, t, c) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, (1 - t) * Motion.riseOffset),
          child: c,
        ),
      ),
      child: child,
    );
  }
}

class _MaybeAnimatedSize extends StatelessWidget {
  const _MaybeAnimatedSize({required this.duration, required this.child});

  final Duration duration;
  final Widget child;

  @override
  Widget build(BuildContext context) => duration == Duration.zero
      ? child
      : AnimatedSize(
          duration: duration,
          curve: Motion.enter,
          alignment: Alignment.topCenter,
          child: child,
        );
}
