/// Huong dan lan dau (3 buoc, bo qua duoc): Nha + Noi lam / hoc, gio di /
/// ve, thong bao buoi sang. Chi hien mot lan (co [OnboardingGate.doneKey]);
/// xem lai tu Cai dat.
library;

import 'package:flutter/cupertino.dart';
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
import '../ui/weather/widgets/ios_sheet.dart';
import '../ui/weather/widgets/ios_list.dart';

/// Boc man chinh: lan dau phu huong dan len tren (man chinh van tai du lieu
/// phia sau, nen xong huong dan la co so lieu ngay).

part 'onboarding/onboarding_gate.dart';
part 'onboarding/onboarding_components.dart';
part 'onboarding/places_step.dart';
part 'onboarding/times_step.dart';
part 'onboarding/notify_step.dart';

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
                      icon: const Icon(CupertinoIcons.back),
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
