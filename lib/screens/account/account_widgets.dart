part of '../account_screen.dart';

class _NoticeCard extends StatelessWidget {
  const _NoticeCard({required this.text, required this.onClose});

  final String text;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: IosListSection.padded(
        child: Row(
          children: [
            Icon(Icons.info_rounded, color: GlassInk.of(context).warning),
            const SizedBox(width: Space.s),
            Expanded(
              child: Text(
                text,
                style: TypeScale.body.copyWith(color: Palette.white),
              ),
            ),
            GlassIconButton(
              icon: CupertinoIcons.xmark,
              tooltip: 'Đóng thông báo',
              onPressed: onClose,
            ),
          ],
        ),
      ),
    );
  }
}

/// Nut vien >= 48 dp, rong het the.
class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => IosButton.tinted(
    expand: true,
    onPressed: onPressed,
    icon: icon,
    label: label,
  );
}

// ---------------------------------------------------------------------------
// Dang nhap / dang ky
