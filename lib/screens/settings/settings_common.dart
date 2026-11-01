/// Thanh phan dung chung cua man Cai dat.
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../ui/weather/design_tokens.dart';

/// Tieu de nhom: chu ro, icon, cao toi thieu 48 dp, la "header" cho trinh
/// doc man hinh (vuot nhanh giua cac nhom).
class SettingsSectionHeader extends StatelessWidget {
  final String title;
  final IconData? icon;

  const SettingsSectionHeader({super.key, required this.title, this.icon});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.textTheme.bodySmall?.color;
    return Semantics(
      header: true,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: Touch.min),
        child: Padding(
          padding: const EdgeInsets.only(left: Space.s, bottom: Space.xs),
          child: Row(
            children: [
              if (icon != null) ...[
                ExcludeSemantics(
                  child: Icon(icon, size: IconSizes.sm, color: color),
                ),
                const SizedBox(width: Space.s),
              ],
              Expanded(
                child: Text(
                  title.toUpperCase(),
                  style: TypeScale.footnote.copyWith(
                    color: color,
                    fontWeight: FontWeight.w500,
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

class SettingsTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const SettingsTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // ListTile tu doc title + subtitle; khong boc them Semantics(label) de
    // tranh doc trung (truoc day nhan bi doc hai lan cung control).
    return ListTile(
      leading: SettingsIcon(icon),
      title: Text(
        title,
        style: TypeScale.bodyLarge.copyWith(
          color: theme.textTheme.bodyLarge?.color,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: TypeScale.bodySmall.copyWith(
          color: theme.textTheme.bodySmall?.color,
        ),
      ),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: Space.l,
        vertical: Space.xs,
      ),
    );
  }
}

class SettingsIcon extends StatelessWidget {
  const SettingsIcon(this.icon, {super.key});

  /// Canh o vuong icon (dung de thut mo ta thang cot tieu de).
  static const double size = 30;

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final color = switch (icon) {
      CupertinoIcons.bell ||
      CupertinoIcons.exclamationmark_triangle => SystemColors.iconRed,
      CupertinoIcons.location ||
      CupertinoIcons.arrow_2_circlepath => SystemColors.iconGreen,
      CupertinoIcons.sun_max ||
      CupertinoIcons.thermometer => SystemColors.iconOrange,
      CupertinoIcons.moon ||
      CupertinoIcons.paintbrush => SystemColors.iconPurple,
      _ => SystemColors.iconBlue,
    };
    return ExcludeSemantics(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(7),
        ),
        child: SizedBox.square(
          dimension: size,
          child: Icon(icon, size: 19, color: Colors.white),
        ),
      ),
    );
  }
}

class SettingsAction extends StatelessWidget {
  const SettingsAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
    enabled: onPressed != null,
    child: CupertinoButton(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
      minimumSize: const Size(48, 48),
      onPressed: onPressed,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ExcludeSemantics(child: Icon(icon, size: 20)),
          const SizedBox(width: 8),
          Flexible(child: Text(label, style: TypeScale.subhead)),
        ],
      ),
    ),
  );
}

class SettingsSwitchTile extends StatelessWidget {
  const SettingsSwitchTile({
    super.key,
    this.secondary,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
    this.contentPadding,
  });

  final Widget? secondary;
  final Widget title;
  final Widget? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final EdgeInsetsGeometry? contentPadding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tileTheme = ListTileTheme.of(context);
    // The control is disabled, not its explanation (including system locks).
    final titleColor =
        tileTheme.titleTextStyle?.color ??
        tileTheme.textColor ??
        theme.colorScheme.onSurface;
    final subtitleColor =
        tileTheme.subtitleTextStyle?.color ??
        tileTheme.textColor ??
        theme.textTheme.bodySmall?.color ??
        theme.colorScheme.onSurfaceVariant;
    return MergeSemantics(
      child: ListTile(
        leading: secondary,
        title: DefaultTextStyle.merge(
          style: TextStyle(color: titleColor),
          child: title,
        ),
        subtitle: subtitle == null
            ? null
            : DefaultTextStyle.merge(
                style: TextStyle(color: subtitleColor),
                child: subtitle!,
              ),
        contentPadding: contentPadding,
        enabled: onChanged != null,
        onTap: onChanged == null ? null : () => onChanged!(!value),
        trailing: SizedBox(
          width: 60,
          height: Touch.min,
          child: CupertinoSwitch(value: value, onChanged: onChanged),
        ),
      ),
    );
  }
}

class SettingsNote extends StatelessWidget {
  const SettingsNote(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: Text(
      text,
      style: TypeScale.bodySmall.copyWith(
        color: Theme.of(context).textTheme.bodySmall?.color,
      ),
    ),
  );
}
