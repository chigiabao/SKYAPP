part of '../onboarding_screen.dart';

class _TimesStep extends StatelessWidget {
  const _TimesStep({super.key});

  Future<void> _pick(BuildContext context, bool leave) async {
    final planner = context.read<PlannerProvider>();
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
    final c = context.watch<PlannerProvider>().commute;
    return _StepFrame(
      scene: WeatherScene.rain,
      title: 'Mấy giờ bạn đi và về?',
      body:
          'Trang chủ sẽ nhắc kiểu "Về 17:30: mưa 70% – mang áo mưa" để bạn '
          'kịp bỏ áo mưa vào cốp xe.',
      children: [
        Row(
          children: [
            Expanded(
              child: _TimeTile(
                icon: Icons.two_wheeler_rounded,
                label: 'Giờ đi',
                value: clockHm(c.leaveHour, c.leaveMinute),
                onTap: () => _pick(context, true),
              ),
            ),
            const SizedBox(width: Space.cardGap),
            Expanded(
              child: _TimeTile(
                icon: Icons.home_outlined,
                label: 'Giờ về',
                value: clockHm(c.returnHour, c.returnMinute),
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
          // Icon, nhan va gio cung canh trai (kieu o so lieu iOS).
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: Palette.white),
              const SizedBox(height: Space.s),
              Text(
                label,
                style: TypeScale.small.copyWith(color: ink.secondary),
              ),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: AlignmentDirectional.centerStart,
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
