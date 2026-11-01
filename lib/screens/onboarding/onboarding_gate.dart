part of '../onboarding_screen.dart';

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
