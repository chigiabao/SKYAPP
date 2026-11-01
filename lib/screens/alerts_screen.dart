import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/weather_alerts.dart';
import '../providers/location_provider.dart';
import '../providers/planner_provider.dart';
import '../providers/weather_provider.dart';
import '../ui/weather/design_tokens.dart';
import '../ui/weather/glass_ink.dart';
import '../ui/weather/widgets/ios_list.dart';
import '../ui/weather/widgets/ios_page.dart';
import '../ui/weather/widgets/glass_page.dart';
import '../widgets/planner_cards.dart';
import 'alert_settings_screen.dart';
import '../utils/haptics.dart';
import '../utils/forecast_format.dart';

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

  /// Tai lai moi dia diem; true khi khong dia diem nao loi.
  Future<bool> _refresh() async {
    final planner = context.read<PlannerProvider>();
    await planner.refreshAll(context.read<WeatherProvider>(), widget.locations);
    if (!mounted) return false;
    planner.markAllRead();
    return widget.locations.pages.every(
      (p) => planner.errorFor(p.locationId) == null,
    );
  }

  @override
  Widget build(BuildContext context) =>
      GlassPage(child: Builder(builder: _buildPage));

  Widget _buildPage(BuildContext context) {
    final ink = GlassInk.of(context);
    final planner = context.watch<PlannerProvider>();
    final wp = context.watch<WeatherProvider>();
    final lp = widget.locations;
    final ids = <String>{for (final p in lp.pages) p.locationId}.toList();

    final placeCards = <Widget>[];
    for (final id in ids) {
      final hours =
          planner.hoursFor(id) ??
          (id == wp.locationId ? wp.hourlyForecast : null);
      final err = planner.errorFor(id);
      final events =
          hours == null ||
              !hasAlertHours(hours, wp.nowHcm, planner.settings.lookaheadHours)
          ? null
          : planner.alertsFor(id, hours, wp.nowHcm);
      final place = lp.placeById(id);
      final label = lp.saved
          .where((s) => s.locationId == id)
          .map((s) => s.labelText)
          .firstOrNull;
      final Widget message = Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Space.l,
          vertical: Space.m,
        ),
        child: Text(
          events == null
              ? (err != null
                    ? 'Không tải được dữ liệu cho địa điểm này.'
                    : (planner.refreshing ? 'Đang tải…' : 'Chưa có dữ liệu.'))
              : 'Chưa phát hiện cảnh báo trong dữ liệu hiện có.',
          style: TypeScale.body.copyWith(color: ink.secondary),
        ),
      );
      placeCards.add(
        IosListSection(
          key: ValueKey('alerts-place-$id'),
          header: label == null ? place.name : '$label · ${place.name}',
          headerTrailing: const ExcludeSemantics(
            child: Padding(
              padding: EdgeInsets.only(right: Space.l),
              child: Icon(
                Icons.place_outlined,
                size: IconSizes.sm,
                color: Palette.secondary,
              ),
            ),
          ),
          dividerIndent: Space.l + IconSizes.md + Space.m,
          children: events == null || events.isEmpty
              ? [message]
              : [for (final e in events) AlertEventTile(event: e, inset: true)],
        ),
      );
    }

    Widget note(IconData icon, String title, String text) => IosListSection(
      header: title,
      children: [
        IosListRow(
          leading: Icon(icon, color: Palette.white, size: IconSizes.md),
          title: text,
        ),
      ],
    );

    return IosPageScaffold(
      title: 'Cảnh báo',
      onRefresh: withRefreshHaptic(_refresh),
      actions: [
        IosBarButton(
          tooltip: 'Tải lại',
          icon: CupertinoIcons.refresh,
          onPressed: planner.refreshing ? null : _refresh,
        ),
        IosBarButton(
          tooltip: 'Cài đặt cảnh báo',
          icon: CupertinoIcons.slider_horizontal_3,
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const AlertSettingsScreen()),
          ),
        ),
      ],
      children: [
        note(CupertinoIcons.info, 'Lưu ý', kAlertDisclaimer),
        if (wp.isReplay)
          note(
            CupertinoIcons.time,
            'Chế độ xem lại',
            'Cảnh báo tính theo thời điểm xem lại; khoảng sau mốc đó '
                'ghi "Đã xảy ra" vì đã có số liệu ghi nhận. Không ghi vào '
                'lịch sử thông báo.',
          ),
        if (planner.heldByQuietHours > 0)
          note(
            CupertinoIcons.moon_zzz,
            'Giờ yên lặng',
            '${planner.heldByQuietHours} cảnh báo chưa thông báo do '
                'đang trong giờ yên lặng (vẫn hiện ở đây).',
          ),
        ...placeCards,
        _HistoryCard(planner: planner),
      ],
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
    return IosListSection(
      key: const ValueKey('alerts-history'),
      header: 'Lịch sử thông báo',
      footer:
          'Thông báo hiện trong ứng dụng; không lặp lại cùng loại, '
          'địa điểm và khung giờ.',
      headerTrailing: items.isEmpty
          ? null
          : CupertinoButton(
              padding: const EdgeInsets.symmetric(horizontal: Space.l),
              minimumSize: const Size(Touch.min, Touch.min),
              onPressed: _clear,
              child: Text(
                'Xóa',
                style: TypeScale.subhead.copyWith(
                  color: Palette.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
      dividerIndent: Space.l + IconSizes.md + Space.m,
      children: items.isEmpty
          ? [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: Space.l,
                  vertical: Space.m,
                ),
                child: Text(
                  'Chưa có thông báo.',
                  style: TypeScale.body.copyWith(color: ink.secondary),
                ),
              ),
            ]
          : [
              for (var i = 0; i < items.length; i++)
                _Enter(
                  key: ValueKey(keys[i]),
                  animate: !still && fresh.contains(keys[i]),
                  child: _row(context, items[i], ink, dur),
                ),
            ],
    );
  }

  Widget _row(BuildContext context, AlertNotice n, GlassInk ink, Duration dur) {
    return Semantics(
      container: true,
      excludeSemantics: true,
      label: '${n.read ? '' : 'Mới. '}${n.title}. ${n.body}',
      child: Padding(
        padding: const EdgeInsets.symmetric(
          vertical: Space.s + 2,
          horizontal: Space.l,
        ),
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

  static String _stamp(DateTime t) => ForecastFormat.dateTime(t);
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
