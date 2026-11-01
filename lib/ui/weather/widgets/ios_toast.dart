/// Thong bao ngan kieu iOS dung chung (thay cho SnackBar cua Material): vien
/// kinh toi hinh vien thuoc noi phia duoi, tu an sau vai giay, nut hanh dong
/// tuy chon (vd. "Hoàn tác"; khi bat trinh doc man hinh thong bao co nut
/// khong tu an), doc boi trinh doc man hinh (liveRegion), giam
/// chuyen dong -> hien/an tuc thi. Moi luc chi co MOT thong bao (cai moi
/// thay cai cu).
library;

import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../design_tokens.dart';

/// Sac thai cua thong bao (chi doi icon dau dong).
enum IosToastTone { info, success, error }

OverlayEntry? _current;

/// Hien thong bao ngan. [actionLabel] + [onAction] -> nut ben phai (bam thi
/// an thong bao roi goi [onAction]). Khong co Overlay -> bo qua.
void showIosToast(
  BuildContext context,
  String message, {
  IosToastTone tone = IosToastTone.info,
  String? actionLabel,
  VoidCallback? onAction,
  Duration? duration,
}) => showIosToastIn(
  iosToastOverlay(context),
  message,
  tone: tone,
  actionLabel: actionLabel,
  onAction: onAction,
  duration: duration,
);

/// Overlay goc de hien thong bao - lay TRUOC `await` (giong cach giu
/// ScaffoldMessenger) khi man hinh co the da dong luc co ket qua.
OverlayState? iosToastOverlay(BuildContext context) =>
    Overlay.maybeOf(context, rootOverlay: true);

/// Nhu [showIosToast] nhung voi [overlay] da lay san.
void showIosToastIn(
  OverlayState? overlay,
  String message, {
  IosToastTone tone = IosToastTone.info,
  String? actionLabel,
  VoidCallback? onAction,
  Duration? duration,
}) {
  if (overlay == null || !overlay.mounted) return;
  hideIosToast();
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _IosToast(
      message: message,
      tone: tone,
      actionLabel: actionLabel,
      onAction: onAction,
      // Co nut hanh dong -> de lau hon de kip bam.
      duration:
          duration ??
          (actionLabel != null
              ? const Duration(seconds: 6)
              : const Duration(seconds: 4)),
      onDone: () {
        if (identical(_current, entry)) {
          _current = null;
        }
        _drop(entry);
      },
    ),
  );
  _current = entry;
  _live.add(entry);
  overlay.insert(entry);
}

/// An ngay thong bao dang hien (neu co).
void hideIosToast() {
  final entry = _current;
  _current = null;
  if (entry != null) _drop(entry);
}

/// Cac muc dang nam trong Overlay (go dung mot lan).
final Set<OverlayEntry> _live = {};

void _drop(OverlayEntry entry) {
  if (!_live.remove(entry)) return;
  entry.remove();
  // Flutter tu doi toi khi widget roi cay roi moi giai phong.
  entry.dispose();
}

/// Phan cach phia duoi: chua thanh tab noi + vung an toan.
const double _bottomGap = 88;

class _IosToast extends StatefulWidget {
  const _IosToast({
    required this.message,
    required this.tone,
    required this.actionLabel,
    required this.onAction,
    required this.duration,
    required this.onDone,
  });

  final String message;
  final IosToastTone tone;
  final String? actionLabel;
  final VoidCallback? onAction;
  final Duration duration;
  final VoidCallback onDone;

  @override
  State<_IosToast> createState() => _IosToastState();
}

class _IosToastState extends State<_IosToast>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: Motion.short,
    reverseDuration: Motion.shortExit,
  );
  Timer? _timer;
  bool _closing = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_c.status == AnimationStatus.dismissed && !_closing) {
      if (MediaQuery.disableAnimationsOf(context)) {
        _c.value = 1;
      } else {
        _c.forward();
      }
      // Trinh doc man hinh / dieu khien bang phim (accessibleNavigation) +
      // co nut hanh dong: khong tu an, de kip toi nut (bam chu de dong).
      final hold =
          widget.actionLabel != null &&
          MediaQuery.accessibleNavigationOf(context);
      if (!hold) _timer ??= Timer(widget.duration, _close);
    }
  }

  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    _timer?.cancel();
    if (mounted && !MediaQuery.disableAnimationsOf(context)) {
      await _c.reverse();
    }
    widget.onDone();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _c.dispose();
    super.dispose();
  }

  IconData get _icon => switch (widget.tone) {
    IosToastTone.info => CupertinoIcons.info_circle_fill,
    IosToastTone.success => CupertinoIcons.checkmark_circle_fill,
    IosToastTone.error => CupertinoIcons.exclamationmark_triangle_fill,
  };

  Color get _iconColor => switch (widget.tone) {
    IosToastTone.info => Palette.secondary,
    IosToastTone.success => Tones.successOnDark,
    IosToastTone.error => Palette.dangerOnGlass,
  };

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final bottom =
        (mq.viewInsets.bottom > 0
            ? mq.viewInsets.bottom
            : mq.viewPadding.bottom) +
        (mq.viewInsets.bottom > 0 ? Space.m : _bottomGap);
    final curve = CurvedAnimation(parent: _c, curve: Curves.easeOutCubic);
    final action = widget.actionLabel;
    final capsule = Material(
      type: MaterialType.transparency,
      child: DefaultTextStyle(
        style: TypeScale.subhead.copyWith(color: Palette.white),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(Radii.card),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Palette.banner,
                borderRadius: BorderRadius.circular(Radii.card),
                border: Border.all(color: Palette.border),
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: Touch.min),
                child: Padding(
                  padding: EdgeInsets.only(
                    left: Space.l,
                    right: action == null ? Space.l : Space.xs,
                  ),
                  child: Row(
                    children: [
                      ExcludeSemantics(
                        child: Icon(
                          _icon,
                          size: IconSizes.inline,
                          color: _iconColor,
                        ),
                      ),
                      const SizedBox(width: Space.m),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            vertical: Space.m,
                          ),
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: _close,
                            child: Semantics(
                              liveRegion: true,
                              child: Text(widget.message),
                            ),
                          ),
                        ),
                      ),
                      if (action != null)
                        CupertinoButton(
                          padding: const EdgeInsets.symmetric(
                            horizontal: Space.m,
                          ),
                          minimumSize: const Size(Touch.min, Touch.min),
                          onPressed: () {
                            _close();
                            widget.onAction?.call();
                          },
                          child: Text(
                            action,
                            style: TypeScale.headline.copyWith(
                              color: SystemColors.accentDark,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return Positioned(
      left: Space.l + mq.viewPadding.left,
      right: Space.l + mq.viewPadding.right,
      bottom: bottom,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: Space.contentMaxWidth),
          child: FadeTransition(
            opacity: curve,
            child: SlideTransition(
              position: Tween(
                begin: const Offset(0, 0.4),
                end: Offset.zero,
              ).animate(curve),
              child: capsule,
            ),
          ),
        ),
      ),
    );
  }
}
