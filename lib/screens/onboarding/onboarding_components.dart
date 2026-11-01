part of '../onboarding_screen.dart';

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
          Center(
            child: _Float(child: WeatherIcon(scene: scene, size: 96)),
          ),
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
