/// Huong dan lan dau (3 buoc, bo qua duoc): Nha + Noi lam / hoc, gio di /
/// ve, thong bao buoi sang. Chi hien mot lan (co [OnboardingGate.doneKey]);
/// xem lai tu Cai dat.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/activities.dart';
import '../models/place.dart';
import '../providers/location_provider.dart';
import '../providers/planner_provider.dart';
import '../services/notification_service.dart';
import '../ui/weather/design_tokens.dart';
import '../ui/weather/glass_ink.dart';
import '../ui/weather/weather_icons.dart';
import '../ui/weather/weather_scene.dart';
import '../ui/weather/widgets/glass_card.dart';
import '../ui/weather/widgets/glass_page.dart';

/// Boc man chinh: lan dau phu huong dan len tren (man chinh van tai du lieu
/// phia sau, nen xong huong dan la co so lieu ngay).
class OnboardingGate extends StatefulWidget {
  const OnboardingGate({super.key, required this.child});

  static const String doneKey = 'onboarding_done_v1';

  final Widget child;

  static Future<void> markDone() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(doneKey, true);
    } catch (e) {
      debugPrint('Onboarding.markDone: $e');
    }
  }

  @override
  State<OnboardingGate> createState() => _OnboardingGateState();
}

class _OnboardingGateState extends State<OnboardingGate> {
  /// null = dang doc co.
  bool? _show;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance()
        .then((p) => p.getBool(OnboardingGate.doneKey) != true)
        .catchError((Object _) => false)
        .then((show) {
          if (mounted) setState(() => _show = show);
        });
  }

  void _finish() {
    OnboardingGate.markDone();
    setState(() => _show = false);
  }

  @override
  Widget build(BuildContext context) {
    final cover = _show != false;
    return Stack(
      fit: StackFit.expand,
      children: [
        ExcludeSemantics(
          excluding: cover,
          child: TickerMode(enabled: !cover, child: widget.child),
        ),
        AnimatedSwitcher(
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : Motion.medium,
          child: _show == true
              ? OnboardingScreen(onDone: _finish)
              // Chua biet co -> che man chinh bang nen canh (khong nhay).
              : _show == null
              ? const GlassPage(child: SizedBox.expand())
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

/// Ba buoc huong dan. [onDone] goi khi xong hoac bo qua.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.onDone});

  final VoidCallback onDone;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  int _step = 0;
  bool _forward = true;

  static const int _count = 3;

  void _go(int step) {
    if (step >= _count) {
      widget.onDone();
      return;
    }
    setState(() {
      _forward = step > _step;
      _step = step;
    });
  }

  @override
  Widget build(BuildContext context) =>
      GlassPage(child: Builder(builder: _buildPage));

  Widget _buildPage(BuildContext context) {
    final ink = GlassInk.of(context);
    final still = MediaQuery.disableAnimationsOf(context);
    final width = MediaQuery.sizeOf(context).width;
    final hPad = width > Space.contentMaxWidth + 2 * Space.l
        ? (width - Space.contentMaxWidth) / 2
        : Space.l;
    final last = _step == _count - 1;
    final steps = [
      const _PlacesStep(key: ValueKey(0)),
      const _TimesStep(key: ValueKey(1)),
      const _NotifyStep(key: ValueKey(2)),
    ];
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: hPad),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  if (_step > 0)
                    IconButton(
                      tooltip: 'Quay lại',
                      color: Palette.white,
                      icon: const Icon(Icons.arrow_back_rounded),
                      onPressed: () => _go(_step - 1),
                    )
                  else
                    const SizedBox(width: Touch.min),
                  Expanded(
                    child: _Dots(step: _step, count: _count, still: still),
                  ),
                  TextButton(
                    onPressed: widget.onDone,
                    style: TextButton.styleFrom(
                      foregroundColor: Palette.white,
                      minimumSize: const Size(Touch.min, Touch.min),
                    ),
                    child: const Text('Bỏ qua'),
                  ),
                ],
              ),
              Expanded(
                child: AnimatedSwitcher(
                  duration: still ? Duration.zero : Motion.medium,
                  switchInCurve: Motion.enter,
                  switchOutCurve: Motion.exit,
                  transitionBuilder: (child, anim) {
                    final incoming = child.key == ValueKey(_step);
                    final dx = (_forward == incoming ? 1 : -1) * 0.12;
                    return FadeTransition(
                      opacity: anim,
                      child: SlideTransition(
                        position: Tween(
                          begin: Offset(dx, 0),
                          end: Offset.zero,
                        ).animate(anim),
                        child: child,
                      ),
                    );
                  },
                  child: steps[_step],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Space.m),
                child: FilledButton(
                  onPressed: () => _go(_step + 1),
                  style: FilledButton.styleFrom(
                    backgroundColor: Palette.white,
                    foregroundColor: Palette.onAlert,
                    minimumSize: const Size.fromHeight(52),
                    textStyle: TypeScale.body.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  child: Text(last ? 'Bắt đầu dùng' : 'Tiếp tục'),
                ),
              ),
              Semantics(
                liveRegion: true,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: Space.s),
                  child: Text(
                    'Bước ${_step + 1}/$_count · đổi lại bất cứ lúc nào '
                    'trong Cài đặt',
                    textAlign: TextAlign.center,
                    style: TypeScale.small.copyWith(color: ink.secondary),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Cham chi buoc (buoc hien tai dai hon).
class _Dots extends StatelessWidget {
  const _Dots({required this.step, required this.count, required this.still});

  final int step;
  final int count;
  final bool still;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < count; i++)
            AnimatedContainer(
              duration: still ? Duration.zero : Motion.short,
              curve: Motion.enter,
              margin: const EdgeInsets.symmetric(horizontal: 3),
              width: i == step ? 22 : 8,
              height: 8,
              decoration: BoxDecoration(
                color: i <= step ? Palette.white : Palette.track,
                borderRadius: BorderRadius.circular(Radii.pill),
              ),
            ),
        ],
      ),
    );
  }
}

/// Khung chung mot buoc: minh hoa (icon canh thoi tiet, nhun nhe) + tieu de
/// + mo ta + noi dung. Cuon duoc khi chu lon.
class _StepFrame extends StatelessWidget {
  const _StepFrame({
    required this.scene,
    required this.title,
    required this.body,
    required this.children,
  });

  final WeatherScene scene;
  final String title;
  final String body;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final ink = GlassInk.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.only(top: Space.l, bottom: Space.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(child: _Float(child: WeatherIcon(scene: scene, size: 96))),
          const SizedBox(height: Space.l),
          Semantics(
            header: true,
            child: Text(
              title,
              textAlign: TextAlign.center,
              style: TypeScale.city.copyWith(color: Palette.white),
            ),
          ),
          const SizedBox(height: Space.s),
          Text(
            body,
            textAlign: TextAlign.center,
            style: TypeScale.body.copyWith(color: ink.secondary),
          ),
          const SizedBox(height: Space.xl),
          ...children,
        ],
      ),
    );
  }
}

/// Nhun len xuong nhe (4 px, 3 s); tat khi giam chuyen dong.
class _Float extends StatefulWidget {
  const _Float({required this.child});

  final Widget child;

  @override
  State<_Float> createState() => _FloatState();
}

class _FloatState extends State<_Float> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 3),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _c,
    builder: (context, child) => Transform.translate(
      offset: Offset(0, -4 * Curves.easeInOut.transform(_c.value)),
      child: child,
    ),
    child: widget.child,
  );
}

// ---------------------------------------------------------------------------
// Buoc 1: Nha + Noi lam / hoc

class _PlacesStep extends StatelessWidget {
  const _PlacesStep({super.key});

  @override
  Widget build(BuildContext context) {
    final planner = context.watch<PlannerProvider>();
    final lp = context.watch<LocationProvider>();
    final c = planner.commute;
    return _StepFrame(
      scene: WeatherScene.partlyCloudyDay,
      title: 'Bạn đi lại giữa đâu?',
      body:
          'Chọn phường nơi bạn ở và nơi làm, học. Sky Weather báo mưa đúng '
          'chỗ lúc bạn đi và về.',
      children: [
        _PlaceTile(
          icon: Icons.home_outlined,
          label: 'Nhà',
          place: c.homeId == null ? null : lp.placeById(c.homeId!),
          onTap: () => _pick(context, home: true),
        ),
        const SizedBox(height: Space.cardGap),
        _PlaceTile(
          icon: Icons.work_outline_rounded,
          label: 'Nơi làm / học',
          place: c.workId == null ? null : lp.placeById(c.workId!),
          onTap: () => _pick(context, home: false),
        ),
      ],
    );
  }

  Future<void> _pick(BuildContext context, {required bool home}) async {
    final lp = context.read<LocationProvider>();
    final planner = context.read<PlannerProvider>();
    final place = await showModalBottomSheet<Place>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => ChangeNotifierProvider.value(
        value: lp,
        child: _PlaceSearchSheet(title: home ? 'Chọn Nhà' : 'Chọn Nơi làm / học'),
      ),
    );
    if (place == null) return;
    final label = home ? PlaceLabel.home : PlaceLabel.work;
    final i = lp.saved.indexWhere((s) => s.locationId == place.id);
    if (i < 0) {
      lp.addSaved(place.id, label: label);
    } else if (lp.saved[i].label == PlaceLabel.none) {
      lp.setLabel(i, label);
    }
    planner.setCommute(
      home
          ? planner.commute.copyWith(homeId: place.id)
          : planner.commute.copyWith(workId: place.id),
    );
    planner.syncCommutePlaces(lp);
  }
}

class _PlaceTile extends StatelessWidget {
  const _PlaceTile({
    required this.icon,
    required this.label,
    required this.place,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Place? place;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ink = GlassInk.of(context);
    final p = place;
    return GlassSurface(
      child: Pressable(
        onTap: onTap,
        semanticsLabel:
            '$label: ${p == null ? 'chưa chọn' : p.name}. Chạm để chọn',
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 64),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Space.l,
              vertical: Space.m,
            ),
            child: Row(
              children: [
                Icon(icon, color: Palette.white, size: IconSizes.md),
                const SizedBox(width: Space.m),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: TypeScale.small.copyWith(color: ink.secondary),
                      ),
                      Text(
                        p == null ? 'Tìm phường hoặc dùng GPS' : p.name,
                        style: TypeScale.body.copyWith(
                          color: Palette.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  p == null ? Icons.add_rounded : Icons.edit_outlined,
                  color: Palette.white,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Tim phuong / xa (khong dau, tren may truoc, may chu sau) hoac dung GPS.
class _PlaceSearchSheet extends StatefulWidget {
  const _PlaceSearchSheet({required this.title});

  final String title;

  @override
  State<_PlaceSearchSheet> createState() => _PlaceSearchSheetState();
}

class _PlaceSearchSheetState extends State<_PlaceSearchSheet> {
  final _ctrl = TextEditingController();
  List<Place> _results = const [];
  String? _message;
  int _token = 0;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _search(String q) async {
    final lp = context.read<LocationProvider>();
    final t = ++_token;
    var r = lp.search(q);
    setState(() {
      _results = r;
      _message = null;
    });
    if (r.isEmpty && q.trim().length >= 2) {
      final remote = await lp.searchRemote(q);
      if (!mounted || t != _token) return;
      r = remote ?? const [];
      setState(() {
        _results = r;
        _message = remote == null
            ? 'Không tìm được trên máy chủ. Kiểm tra kết nối rồi thử lại.'
            : r.isEmpty
            ? 'Không thấy "$q". Thử tên phường khác, gõ không dấu cũng được.'
            : null;
      });
    }
  }

  Future<void> _gps() async {
    final lp = context.read<LocationProvider>();
    final o = await lp.useCurrentLocation();
    if (!mounted) return;
    if (o.ok && o.place != null) {
      Navigator.pop(context, o.place);
    } else {
      setState(() => _message = o.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final lp = context.watch<LocationProvider>();
    final insets = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(Space.l, 0, Space.l, Space.l + insets),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text(
              widget.title,
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          const SizedBox(height: Space.m),
          TextField(
            controller: _ctrl,
            autofocus: true,
            textInputAction: TextInputAction.search,
            decoration: const InputDecoration(
              labelText: 'Tên phường, xã',
              hintText: 'Ví dụ: Bến Thành, Thủ Đức',
              prefixIcon: Icon(Icons.search_rounded),
            ),
            onChanged: _search,
          ),
          const SizedBox(height: Space.s),
          OutlinedButton.icon(
            onPressed: lp.gpsBusy ? null : _gps,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(Touch.min),
            ),
            icon: lp.gpsBusy
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.my_location_rounded),
            label: Text(
              lp.gpsBusy ? 'Đang lấy vị trí…' : 'Dùng vị trí hiện tại (GPS)',
            ),
          ),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.only(top: Space.s),
              child: Semantics(liveRegion: true, child: Text(_message!)),
            ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final p in _results.take(20))
                  ListTile(
                    minTileHeight: Touch.min,
                    leading: const Icon(Icons.place_outlined),
                    title: Text(p.name),
                    subtitle: Text(p.detail),
                    onTap: () => Navigator.pop(context, p),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Buoc 2: gio di / ve

class _TimesStep extends StatelessWidget {
  const _TimesStep({super.key});

  Future<void> _pick(BuildContext context, bool leave) async {
    final planner = context.read<PlannerProvider>();
    final c = planner.commute;
    final t = await showTimePicker(
      context: context,
      initialTime: leave
          ? TimeOfDay(hour: c.leaveHour, minute: c.leaveMinute)
          : TimeOfDay(hour: c.returnHour, minute: c.returnMinute),
      helpText: leave ? 'Giờ đi làm / đi học' : 'Giờ về',
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
    final c = context.watch<PlannerProvider>().commute;
    return _StepFrame(
      scene: WeatherScene.rain,
      title: 'Mấy giờ bạn đi và về?',
      body:
          'Trang chủ sẽ nhắc kiểu "Về 17h30: mưa 70% – mang áo mưa" để bạn '
          'kịp bỏ áo mưa vào cốp xe.',
      children: [
        Row(
          children: [
            Expanded(
              child: _TimeTile(
                icon: Icons.two_wheeler_rounded,
                label: 'Giờ đi',
                value: shortHm(c.leaveHour, c.leaveMinute),
                onTap: () => _pick(context, true),
              ),
            ),
            const SizedBox(width: Space.cardGap),
            Expanded(
              child: _TimeTile(
                icon: Icons.home_outlined,
                label: 'Giờ về',
                value: shortHm(c.returnHour, c.returnMinute),
                onTap: () => _pick(context, false),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _TimeTile extends StatelessWidget {
  const _TimeTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ink = GlassInk.of(context);
    return GlassSurface(
      child: Pressable(
        onTap: onTap,
        semanticsLabel: '$label: $value. Chạm để đổi',
        child: Padding(
          padding: const EdgeInsets.all(Space.l),
          child: Column(
            children: [
              Icon(icon, color: Palette.white),
              const SizedBox(height: Space.s),
              Text(
                label,
                style: TypeScale.small.copyWith(color: ink.secondary),
              ),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  value,
                  style: TypeScale.bigValue.copyWith(
                    color: Palette.white,
                    fontFeatures: kTabular,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Buoc 3: thong bao buoi sang

class _NotifyStep extends StatefulWidget {
  const _NotifyStep({super.key});

  @override
  State<_NotifyStep> createState() => _NotifyStepState();
}

class _NotifyStepState extends State<_NotifyStep> {
  String? _message;
  bool _busy = false;

  Future<void> _enable() async {
    setState(() => _busy = true);
    final ok = await context.read<PlannerProvider>().setMorningBrief(true);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = ok
          ? null
          : 'Chưa được cấp quyền thông báo. Bạn vẫn xem cảnh báo trong ứng '
                'dụng; bật lại trong Cài đặt bất cứ lúc nào.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final ink = GlassInk.of(context);
    final planner = context.watch<PlannerProvider>();
    final c = planner.commute;
    final on = planner.notifySettings.system && c.briefEnabled;
    final supported = NotificationService.isSupportedPlatform;
    return _StepFrame(
      scene: WeatherScene.thunderstorm,
      title: 'Biết mưa trước khi ra đường',
      body:
          'Mỗi sáng lúc ${shortHm(c.briefHour, c.briefMinute)}, một thông báo '
          'ngắn tóm tắt mưa trong ngày ở Nhà và Nơi làm. Cảnh báo dông, mưa '
          'lớn cũng được gửi ngay. Không quảng cáo, tôn trọng giờ yên lặng.',
      children: [
        // Vi du minh hoa (khong phai du lieu that).
        Semantics(
          label:
              'Ví dụ thông báo: Hôm nay mưa 15 đến 18 giờ ở nơi làm, mang áo '
              'mưa khi về',
          excludeSemantics: true,
          child: GlassSurface(
            padding: const EdgeInsets.all(Space.l),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.notifications_active_outlined,
                  color: Palette.white,
                ),
                const SizedBox(width: Space.m),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Ví dụ · Thời tiết đi làm hôm nay',
                        style: TypeScale.small.copyWith(color: ink.secondary),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Hôm nay: mưa 15–18h ở Bến Thành, mang áo mưa khi về.',
                        style: TypeScale.body.copyWith(color: Palette.white),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: Space.l),
        if (!supported)
          Text(
            'Trình duyệt / thiết bị này chưa hỗ trợ thông báo của Sky '
            'Weather. Cảnh báo vẫn hiện trong ứng dụng; bật thông báo trên '
            'điện thoại Android hoặc iPhone.',
            textAlign: TextAlign.center,
            style: TypeScale.body.copyWith(color: ink.secondary),
          )
        else if (on)
          Semantics(
            liveRegion: true,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.check_circle_rounded, color: Palette.white),
                const SizedBox(width: Space.s),
                Flexible(
                  child: Text(
                    'Đã bật · ${shortHm(c.briefHour, c.briefMinute)} mỗi sáng',
                    style: TypeScale.body.copyWith(
                      color: Palette.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          )
        else
          OutlinedButton.icon(
            onPressed: _busy ? null : _enable,
            style: OutlinedButton.styleFrom(
              foregroundColor: Palette.white,
              side: const BorderSide(color: Palette.white),
              minimumSize: const Size.fromHeight(Touch.min),
            ),
            icon: const Icon(Icons.notifications_none_rounded),
            label: const Text('Bật thông báo buổi sáng'),
          ),
        if (_message != null)
          Padding(
            padding: const EdgeInsets.only(top: Space.s),
            child: Semantics(
              liveRegion: true,
              child: Text(
                _message!,
                textAlign: TextAlign.center,
                style: TypeScale.small.copyWith(color: ink.secondary),
              ),
            ),
          ),
        if (supported && !on)
          Padding(
            padding: const EdgeInsets.only(top: Space.s),
            child: Text(
              'Điện thoại sẽ hỏi quyền thông báo sau khi bạn bấm.',
              textAlign: TextAlign.center,
              style: TypeScale.small.copyWith(color: ink.secondary),
            ),
          ),
      ],
    );
  }
}
