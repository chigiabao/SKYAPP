/// Danh sach kieu iOS "inset grouped" tren nen kinh toi: tieu de nhom chu
/// nho viet hoa, khoi bo goc 12 voi duong ke manh giua cac hang, chu thich
/// duoi nhom. Hang co nen sang nhe khi nhan (thay cho gon song Material).
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../../utils/haptics.dart';
import '../design_tokens.dart';
import '../glass_ink.dart';
import 'glass_card.dart';

class IosListSection extends StatelessWidget {
  const IosListSection({
    super.key,
    this.header,
    this.headerTrailing,
    this.footer,
    required this.children,
    this.dividerIndent = Space.l,
    this.margin = const EdgeInsets.only(bottom: Space.xl),
  });

  /// Nhom chua mot khoi noi dung tu do (form, cong tac, thanh truot) co le
  /// 16 ngang.
  IosListSection.padded({
    super.key,
    this.header,
    this.headerTrailing,
    this.footer,
    required Widget child,
    this.margin = const EdgeInsets.only(bottom: Space.xl),
  }) : dividerIndent = Space.l,
       children = [
         Padding(
           padding: const EdgeInsets.symmetric(
             horizontal: Space.l,
             vertical: Space.s,
           ),
           child: child,
         ),
       ];

  final String? header;

  /// Nut nho ben phai tieu de nhom (vd. "Xóa").
  final Widget? headerTrailing;
  final String? footer;
  final List<Widget> children;

  /// Le trai cua duong ke (60 khi hang co icon dau).
  final double dividerIndent;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    // Tieu de / chu thich nhom nam tren nen canh (khong co kinh): dung mau
    // chu phu cua dau trang (da tinh lop toi), khong dung mau tren kinh.
    final ink = GlassInk.of(context);
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        rows.add(
          Padding(
            padding: EdgeInsetsDirectional.only(start: dividerIndent),
            child: const ExcludeSemantics(
              child: Divider(
                height: 0.5,
                thickness: 0.5,
                color: Palette.divider,
              ),
            ),
          ),
        );
      }
      rows.add(children[i]);
    }
    return Padding(
      padding: margin,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (header != null)
            Padding(
              padding: EdgeInsets.fromLTRB(
                Space.l,
                headerTrailing == null ? Space.s : 0,
                headerTrailing == null ? Space.l : 0,
                headerTrailing == null ? Space.s - 2 : 0,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Semantics(
                      header: true,
                      container: true,
                      child: Text(
                        header!.toUpperCase(),
                        style: TypeScale.footnote.copyWith(
                          color: ink.headerSecondary,
                        ),
                      ),
                    ),
                  ),
                  ?headerTrailing,
                ],
              ),
            ),
          GlassSurface(
            key: const ValueKey('ios-inset-group'),
            radius: Radii.group,
            padding: EdgeInsets.zero,
            child: Material(
              type: MaterialType.transparency,
              child: Theme(
                data: Theme.of(context).copyWith(
                  highlightColor: Palette.rowPressed,
                  splashFactory: NoSplash.splashFactory,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: rows,
                ),
              ),
            ),
          ),
          if (footer != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Space.l,
                Space.s - 2,
                Space.l,
                0,
              ),
              child: Text(
                footer!,
                style: TypeScale.footnote.copyWith(color: ink.headerSecondary),
              ),
            ),
        ],
      ),
    );
  }
}

/// Mot hang iOS: icon (o vuong mau tuy chon), tieu de, phu de, phan ben
/// phai (gia tri / cong tac / chevron). Cao toi thieu 48, chu tu xuong dong.
class IosListRow extends StatelessWidget {
  const IosListRow({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.value,
    this.onTap,
    this.chevron,
    this.destructive = false,
    this.semanticsLabel,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;

  /// Gia tri hien ben phai (chu phu), vd. "°C".
  final String? value;
  final VoidCallback? onTap;

  /// Mac dinh: co chevron khi co [onTap] va khong co [trailing].
  final bool? chevron;
  final bool destructive;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final ink = GlassInk.of(context);
    final showChevron = chevron ?? (onTap != null && trailing == null);
    final row = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: Touch.min),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Space.l,
          vertical: Space.s + 2,
        ),
        child: Row(
          children: [
            if (leading != null) ...[
              ExcludeSemantics(child: leading!),
              const SizedBox(width: Space.m),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: TypeScale.iosBody.copyWith(
                      color: destructive
                          ? Palette.dangerOnGlass
                          : Palette.white,
                    ),
                  ),
                  if (subtitle != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        subtitle!,
                        style: TypeScale.subhead.copyWith(color: ink.secondary),
                      ),
                    ),
                ],
              ),
            ),
            if (value != null) ...[
              const SizedBox(width: Space.s),
              Text(
                value!,
                style: TypeScale.iosBody.copyWith(color: ink.secondary),
              ),
            ],
            if (trailing != null) ...[
              const SizedBox(width: Space.s),
              trailing!,
            ],
            if (showChevron) ...[
              const SizedBox(width: Space.s),
              ExcludeSemantics(
                child: Icon(
                  CupertinoIcons.chevron_forward,
                  size: 17,
                  color: ink.secondary,
                ),
              ),
            ],
          ],
        ),
      ),
    );
    if (onTap == null) {
      return semanticsLabel == null
          ? MergeSemantics(child: row)
          : Semantics(
              container: true,
              label: semanticsLabel,
              excludeSemantics: true,
              child: row,
            );
    }
    return Semantics(
      button: true,
      label: semanticsLabel,
      excludeSemantics: semanticsLabel != null,
      child: InkWell(
        onTap: () {
          AppHaptics.selection();
          onTap!();
        },
        child: semanticsLabel == null ? MergeSemantics(child: row) : row,
      ),
    );
  }
}

/// O vuong mau sau icon (kieu Cai dat iOS), 30 pt, icon trang.
class IosIconTile extends StatelessWidget {
  const IosIconTile(this.icon, {super.key, required this.color});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(7),
    ),
    child: SizedBox.square(
      dimension: 30,
      child: Icon(icon, size: 19, color: Palette.white),
    ),
  );
}
