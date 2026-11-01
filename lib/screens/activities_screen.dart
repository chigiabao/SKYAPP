import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/activities.dart';
import '../models/habits.dart';
import '../models/weather.dart';
import '../providers/planner_provider.dart';
import '../providers/preferences_provider.dart';
import '../providers/weather_provider.dart';
import '../ui/weather/design_tokens.dart';
import '../ui/weather/glass_ink.dart';
import '../ui/weather/widgets/glass_card.dart';
import '../ui/weather/widgets/glass_page.dart';
import '../ui/weather/widgets/ios_controls.dart';
import '../ui/weather/widgets/ios_list.dart';
import '../ui/weather/widgets/ios_page.dart';
import '../ui/weather/widgets/ios_sheet.dart';
import '../widgets/planner_cards.dart';
import '../ui/weather/widgets/app_segmented_control.dart';
import '../ui/weather/widgets/adaptive_dialog.dart';
import '../ui/weather/widgets/ios_toast.dart';
import '../utils/forecast_format.dart';
import '../utils/haptics.dart';

/// Man Hoat dong: chon hoat dong yeu thich, muc nhay cam, xem 3 khung gio
/// tot nhat trong 48 gio toi cua dia diem dang xem, va lich hoat dong lap
/// lai (gio, thu trong tuan) kem danh gia lan toi.
class ActivitiesScreen extends StatelessWidget {
  const ActivitiesScreen({super.key, this.placeName});

  /// Ten dia diem dang xem (hien o tieu de the).
  final String? placeName;

  @override
  Widget build(BuildContext context) =>
      GlassPage(child: Builder(builder: _buildPage));

  Widget _buildPage(BuildContext context) {
    final ink = GlassInk.of(context);
    final planner = context.watch<PlannerProvider>();
    final wp = context.watch<WeatherProvider>();
    final now = wp.nowHcm;
    final hours = wp.hourlyForecast;

    final detail = <Widget>[];
    for (final a in planner.favorites) {
      if (a == Activity.commute) {
        detail.add(
          Padding(
            padding: const EdgeInsets.only(bottom: Space.cardGap),
            child: _CommuteCard(planner: planner, hours: hours, now: now),
          ),
        );
        continue;
      }
      // Goi y tot nhat (theo diem) roi xep theo thoi gian: doc tu som -> muon,
      // nhan ngay chi hien khi doi ngay.
      final ws = bestWindows(
        a,
        hours,
        nowHcm: now,
        horizonHours: 48,
        limit: 3,
        sensitivity: planner.sensitivity,
        hourBonus: planner.habits.hourBonus(a),
        units: PreferencesProvider.unitsOf(context),
      )..sort((x, y) => x.start.compareTo(y.start));
      detail.add(
        Padding(
          padding: const EdgeInsets.only(bottom: Space.cardGap),
          child: GlassCard(
            title: a.label.toUpperCase(),
            icon: activityIcon(a),
            trailing: planner.habits.enabled
                ? IosButton.plain(
                    onPressed: () {
                      planner.recordDone(a);
                      AppHaptics.success();
                      showIosToast(
                        context,
                        'Đã ghi: ${a.label} lúc '
                        '${planner.realNowHcm.hour} giờ (chỉ lưu trên máy).',
                        tone: IosToastTone.success,
                      );
                    },
                    label: 'Đã làm',
                  )
                : null,
            child: ws.isEmpty
                ? Text(
                    hours.isEmpty
                        ? 'Chưa có dữ liệu theo giờ.'
                        : 'Không có khung giờ phù hợp trong 48 giờ tới.',
                    style: TypeScale.body.copyWith(color: ink.secondary),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < ws.length; i++)
                        ActivityWindowRow(
                          activity: a,
                          window: ws[i],
                          nowHcm: now,
                          // The da co ten hoat dong; ngay chi hien khi doi.
                          showActivity: false,
                          showDay:
                              i == 0 ||
                              HcmTime.startOfDay(ws[i].start) !=
                                  HcmTime.startOfDay(ws[i - 1].start),
                        ),
                    ],
                  ),
          ),
        ),
      );
    }

    return IosPageScaffold(
      title: 'Hoạt động',
      children: [
        GlassCard(
          title: 'HOẠT ĐỘNG YÊU THÍCH',
          icon: Icons.favorite_border_rounded,
          footer: placeName == null
              ? null
              : 'Gợi ý cho $placeName, theo dự báo mô hình.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: Space.s,
                runSpacing: Space.s,
                children: [
                  for (final a in Activity.values)
                    IosPill(
                      icon: activityIcon(a),
                      label: a.label,
                      selected: planner.isFavorite(a),
                      onChanged: (_) => planner.toggleFavorite(a),
                    ),
                ],
              ),
              const SizedBox(height: Space.m),
              Text(
                'Mức nhạy cảm với thời tiết',
                style: TypeScale.body.copyWith(color: Palette.white),
              ),
              const SizedBox(height: Space.s),
              AppSegmentedControl<Sensitivity>(
                segments: [
                  for (final s in Sensitivity.values)
                    AppSegment(value: s, label: s.label),
                ],
                selected: planner.sensitivity,
                onChanged: planner.setSensitivity,
              ),
            ],
          ),
        ),
        const SizedBox(height: Space.cardGap),
        ...detail,
        _RoutinesCard(planner: planner, wp: wp),
        const SizedBox(height: Space.cardGap),
        _HabitsCard(planner: planner, wp: wp),
      ],
    );
  }
}

/// Gio di / ve (mac dinh 7:30 / 17:30) + loi khuyen cho lan di / ve toi.
class _CommuteCard extends StatelessWidget {
  const _CommuteCard({
    required this.planner,
    required this.hours,
    required this.now,
  });

  final PlannerProvider planner;
  final List<HourlyForecast> hours;
  final DateTime now;

  Future<void> _pick(BuildContext context, bool leave) async {
    final c = planner.commute;
    final t = await showIosTimeSheet(
      context,
      initial: leave
          ? TimeOfDay(hour: c.leaveHour, minute: c.leaveMinute)
          : TimeOfDay(hour: c.returnHour, minute: c.returnMinute),
      title: leave ? 'Giờ đi làm / đi học' : 'Giờ về',
    );
    if (t == null) return;
    planner.setCommute(
      leave
          ? c.copyWith(leaveHour: t.hour, leaveMinute: t.minute)
          : c.copyWith(returnHour: t.hour, returnMinute: t.minute),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = planner.commute;
    return GlassCard(
      title: Activity.commute.label.toUpperCase(),
      icon: Icons.two_wheeler_rounded,
      footer: 'Theo dự báo mô hình của Nhà (lúc đi) và Nơi làm (lúc về).',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CommuteRows(hours: hours, nowHcm: now),
          const SizedBox(height: Space.s),
          Wrap(
            spacing: Space.s,
            runSpacing: Space.s,
            children: [
              IosButton.tinted(
                onPressed: () => _pick(context, true),
                icon: CupertinoIcons.clock,
                label: 'Đi ${clockHm(c.leaveHour, c.leaveMinute)}',
              ),
              IosButton.tinted(
                onPressed: () => _pick(context, false),
                icon: CupertinoIcons.house,
                label: 'Về ${clockHm(c.returnHour, c.returnMinute)}',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RoutinesCard extends StatelessWidget {
  const _RoutinesCard({required this.planner, required this.wp});

  final PlannerProvider planner;
  final WeatherProvider wp;

  List<HourlyForecast>? _hoursFor(String id) =>
      planner.hoursFor(id) ?? (id == wp.locationId ? wp.hourlyForecast : null);

  @override
  Widget build(BuildContext context) {
    final ink = GlassInk.of(context);
    final now = wp.nowHcm;
    return GlassCard(
      title: 'LỊCH HOẠT ĐỘNG',
      icon: Icons.event_repeat_rounded,
      footer: 'Đánh giá lần tới theo dự báo của địa điểm khi tạo lịch.',
      trailing: IosButton.plain(
        onPressed: () => _add(context),
        label: 'Thêm lịch',
      ),
      child: planner.routines.isEmpty
          ? Text(
              'Chưa có lịch. Thêm giờ đi làm, đi học hoặc tập thể dục.',
              style: TypeScale.body.copyWith(color: ink.secondary),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final r in planner.routines)
                  _routineRow(context, r, now, ink),
              ],
            ),
    );
  }

  Widget _routineRow(
    BuildContext context,
    ActivityRoutine r,
    DateTime now,
    GlassInk ink,
  ) {
    final next = r.nextAfter(now);
    final hours = _hoursFor(r.placeId);
    final score = next == null || hours == null
        ? null
        : scoreRoutineAt(r, hours, next);
    final days = r.weekdays.length == 7
        ? 'Hằng ngày'
        : ([
            ...r.weekdays,
          ]..sort()).map((d) => ForecastFormat.weekdayShortOf(d)).join(', ');
    final time =
        '${r.hour.toString().padLeft(2, '0')}:'
        '${r.minute.toString().padLeft(2, '0')}';
    String status;
    if (next == null) {
      status = 'Chưa chọn ngày';
    } else if (score == null) {
      status = 'Chưa có dự báo cho lần tới';
    } else {
      final rating = score.rating;
      final worst = score.penalties.entries.isEmpty
          ? null
          : score.penalties.entries.reduce(
              (a, b) => a.value >= b.value ? a : b,
            );
      status =
          'Lần tới: ${rating.label}'
          '${score.missing.isNotEmpty ? ' (${score.missing.join(', ')})' : ''}'
          '${worst != null && worst.value >= 10 ? ' · lưu ý ${worst.key}' : ''}';
    }
    final remind = planner.reminderPlan.reminders
        .where((x) => x.routine.id == r.id)
        .firstOrNull;
    if (remind != null) {
      status +=
          ' · nhắc ${remind.fireAt.hour.toString().padLeft(2, '0')}:'
          '${remind.fireAt.minute.toString().padLeft(2, '0')}';
    }
    return Row(
      children: [
        Icon(activityIcon(r.activity), color: Palette.white),
        const SizedBox(width: Space.m),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${r.activity.label} · $time · $days',
                style: TypeScale.body.copyWith(
                  color: Palette.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                status,
                style: TypeScale.small.copyWith(color: ink.secondary),
              ),
            ],
          ),
        ),
        IosBarButton(
          tooltip: 'Sửa lịch ${r.activity.label}',
          icon: CupertinoIcons.pencil,
          onPressed: () => _edit(context, r),
        ),
        IosBarButton(
          tooltip: 'Xóa lịch ${r.activity.label}',
          icon: CupertinoIcons.trash,
          onPressed: () => planner.removeRoutine(r.id),
        ),
      ],
    );
  }

  Future<void> _add(BuildContext context) async {
    final r = await showIosSheet<ActivityRoutine>(
      context,
      form: true,
      scrollable: false,
      builder: (_) => _RoutineDialog(
        placeId: wp.locationId,
        idSeed: wp.realNowHcm.microsecondsSinceEpoch,
      ),
    );
    if (r == null) return;
    planner.noteLive(wp);
    planner.addRoutine(r);
  }

  Future<void> _edit(BuildContext context, ActivityRoutine old) async {
    final r = await showIosSheet<ActivityRoutine>(
      context,
      form: true,
      scrollable: false,
      builder: (_) =>
          _RoutineDialog(placeId: old.placeId, idSeed: 0, initial: old),
    );
    if (r != null) planner.updateRoutine(r);
  }
}

String _hourText(int h) => '${h.toString().padLeft(2, '0')}:00';

/// Hoc thoi quen (de bai 4.4): dong y bat/tat, xem du lieu da ghi, xac nhan /
/// sua / bo qua lich duoc goi y, xoa du lieu. Chi luu tren may.
class _HabitsCard extends StatelessWidget {
  const _HabitsCard({required this.planner, required this.wp});

  final PlannerProvider planner;
  final WeatherProvider wp;

  ActivityRoutine _fromSuggestion(RoutineSuggestion s) => ActivityRoutine(
    id: 'h${wp.realNowHcm.microsecondsSinceEpoch}',
    activity: s.activity,
    placeId: wp.locationId,
    hour: s.hour,
  );

  Future<void> _editSuggestion(
    BuildContext context,
    RoutineSuggestion s,
  ) async {
    final r = await showIosSheet<ActivityRoutine>(
      context,
      form: true,
      scrollable: false,
      builder: (_) => _RoutineDialog(
        placeId: wp.locationId,
        idSeed: wp.realNowHcm.microsecondsSinceEpoch,
        initial: _fromSuggestion(s),
      ),
    );
    if (r == null) return;
    planner.noteLive(wp);
    planner.addRoutine(r);
  }

  Future<void> _clear(BuildContext context) async {
    final ok = await showAppAlert<bool>(
      context,
      title: 'Xóa dữ liệu thói quen?',
      message:
          'Xóa số lần mở ứng dụng và đánh dấu "Đã làm" đã ghi trên máy. '
          'Lịch hoạt động đã lưu không bị xóa.',
      actions: const [
        AppDialogAction(label: 'Hủy', value: false, isDefault: true),
        AppDialogAction(label: 'Xóa', value: true, isDestructive: true),
      ],
    );
    if (ok == true) planner.clearHabits();
  }

  @override
  Widget build(BuildContext context) {
    final ink = GlassInk.of(context);
    final h = planner.habits;
    final learned = <String>[
      for (final a in Activity.values)
        if (h.habitHours(a).isNotEmpty)
          '${a.label}: ${h.habitHours(a).map(_hourText).join(', ')}',
      if (h.openHours.isNotEmpty)
        'Hay mở ứng dụng: ${h.openHours.take(3).map(_hourText).join(', ')}',
    ];
    final suggestions = planner.routineSuggestions;
    final body = TypeScale.body.copyWith(color: Palette.white);
    final small = TypeScale.small.copyWith(color: ink.secondary);
    return GlassCard(
      title: 'HỌC THÓI QUEN',
      icon: Icons.insights_rounded,
      footer:
          'Chỉ đếm số lần theo giờ trong ngày, lưu trên máy, không gửi đi '
          'đâu. Giờ quen được cộng ${kHabitBonus.round()} điểm khi gợi ý '
          '(ghi "Hợp giờ quen").',
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: Text('Cho phép học thói quen', style: body),
              subtitle: Text(
                'Ghi giờ mở ứng dụng và giờ bạn bấm "Đã làm"',
                style: small,
              ),
              value: h.enabled,
              onChanged: planner.setHabitLearning,
            ),
            if (h.enabled && learned.isEmpty)
              Text(
                'Chưa có dữ liệu. Bấm "Đã làm" ở thẻ hoạt động khi bạn '
                'thực hiện.',
                style: small,
              ),
            for (final l in learned) Text(l, style: small),
            for (final sg in suggestions) ...[
              const SizedBox(height: Space.s),
              Text(
                'Gợi ý lịch: ${sg.activity.label} lúc ${_hourText(sg.hour)} '
                '(đã làm ${sg.count} lần)',
                style: body.copyWith(fontWeight: FontWeight.w600),
              ),
              Wrap(
                spacing: Space.s,
                children: [
                  IosButton.plain(
                    onPressed: () {
                      planner.noteLive(wp);
                      planner.addRoutine(_fromSuggestion(sg));
                    },
                    label: 'Xác nhận',
                  ),
                  IosButton.plain(
                    onPressed: () => _editSuggestion(context, sg),
                    label: 'Sửa',
                  ),
                  IosButton.plain(
                    onPressed: () => planner.dismissSuggestion(sg),
                    label: 'Bỏ qua',
                  ),
                ],
              ),
            ],
            if (!h.isEmpty) ...[
              const SizedBox(height: Space.s),
              Align(
                alignment: Alignment.centerLeft,
                child: IosButton.tinted(
                  onPressed: () => _clear(context),
                  icon: CupertinoIcons.trash,
                  destructive: true,
                  label: 'Xóa dữ liệu thói quen',
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _RoutineDialog extends StatefulWidget {
  const _RoutineDialog({
    required this.placeId,
    required this.idSeed,
    this.initial,
  });

  final String placeId;
  final int idSeed;

  /// Lich co san (sua lich / sua goi y): giu id neu sua lich da luu.
  final ActivityRoutine? initial;

  @override
  State<_RoutineDialog> createState() => _RoutineDialogState();
}

class _RoutineDialogState extends State<_RoutineDialog> {
  Activity _activity = Activity.commute;
  TimeOfDay _time = const TimeOfDay(hour: 7, minute: 0);
  final Set<int> _days = {1, 2, 3, 4, 5};
  Sensitivity _sens = Sensitivity.normal;

  @override
  void initState() {
    super.initState();
    final r = widget.initial;
    if (r != null) {
      _activity = r.activity;
      _time = TimeOfDay(hour: r.hour, minute: r.minute);
      _days
        ..clear()
        ..addAll(r.weekdays);
      _sens = r.sensitivity;
    }
  }

  @override
  Widget build(BuildContext context) {
    final ink = GlassInk.of(context);
    final label = TypeScale.footnote.copyWith(color: ink.secondary);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        IosSheetNavBar(
          title: widget.initial == null
              ? 'Thêm lịch hoạt động'
              : 'Sửa lịch hoạt động',
          doneLabel: 'Lưu',
          onDone: _days.isEmpty
              ? null
              : () => Navigator.pop(
                  context,
                  ActivityRoutine(
                    id: widget.initial?.id ?? 'r${widget.idSeed}',
                    activity: _activity,
                    placeId: widget.placeId,
                    hour: _time.hour,
                    minute: _time.minute,
                    weekdays: {..._days},
                    sensitivity: _sens,
                  ),
                ),
        ),
        Flexible(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('HOẠT ĐỘNG', style: label),
                const SizedBox(height: Space.xs),
                Wrap(
                  spacing: Space.s,
                  children: [
                    for (final a in Activity.values)
                      IosPill(
                        key: ValueKey('routine-activity-${a.name}'),
                        icon: activityIcon(a),
                        label: a.label,
                        selected: _activity == a,
                        onChanged: (_) => setState(() => _activity = a),
                      ),
                  ],
                ),
                const SizedBox(height: Space.m),
                IosListSection(
                  margin: EdgeInsets.zero,
                  children: [
                    IosListRow(
                      key: const ValueKey('routine-time'),
                      leading: const Icon(
                        CupertinoIcons.clock,
                        color: Palette.white,
                      ),
                      title: 'Giờ',
                      value:
                          '${_time.hour.toString().padLeft(2, '0')}:'
                          '${_time.minute.toString().padLeft(2, '0')}',
                      onTap: () async {
                        final t = await showIosTimeSheet(
                          context,
                          title: 'Giờ hoạt động',
                          initial: _time,
                        );
                        if (t != null) setState(() => _time = t);
                      },
                    ),
                  ],
                ),
                const SizedBox(height: Space.m),
                Text('LẶP LẠI', style: label),
                const SizedBox(height: Space.xs),
                Wrap(
                  spacing: Space.xs,
                  children: [
                    for (var d = 1; d <= 7; d++)
                      IosPill(
                        label: ForecastFormat.weekdayShortOf(d),
                        selected: _days.contains(d),
                        onChanged: (on) =>
                            setState(() => on ? _days.add(d) : _days.remove(d)),
                      ),
                  ],
                ),
                if (_days.isEmpty)
                  Text(
                    'Chọn ít nhất một ngày.',
                    style: TypeScale.footnote.copyWith(
                      color: Palette.dangerOnGlass,
                    ),
                  ),
                const SizedBox(height: Space.m),
                Text('MỨC NHẠY CẢM', style: label),
                const SizedBox(height: Space.xs),
                AppSegmentedControl<Sensitivity>(
                  segments: [
                    for (final s in Sensitivity.values)
                      AppSegment(value: s, label: s.label),
                  ],
                  selected: _sens,
                  onChanged: (v) => setState(() => _sens = v),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
