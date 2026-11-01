import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../ui/weather/design_tokens.dart';
import 'settings_common.dart';

// ---------------------------------------------------------------------------
// Nhom 8 - Ca nhan hoa: giao dien, don vi, chi so trang chu, dia diem, tro nang
// ---------------------------------------------------------------------------

/// Segments at normal sizes; checkmarked rows when labels need more room.
class SettingsChoiceGroup<T extends Object> extends StatelessWidget {
  const SettingsChoiceGroup({
    super.key,
    required this.icon,
    required this.title,
    required this.options,
    required this.selected,
    required this.onSelected,
    this.subtitle,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final List<(T, String)> options;
  final T selected;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.l, Space.l, Space.l, Space.s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SettingsIcon(icon),
              // Cung khoang cach icon-chu nhu hang ListTile/IosListRow (12).
              const SizedBox(width: Space.m),
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    title,
                    style: TypeScale.bodyLarge.copyWith(
                      color: theme.textTheme.bodyLarge?.color,
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (subtitle != null)
            Padding(
              // Thut thang cot tieu de (khong nam duoi icon).
              padding: const EdgeInsets.only(
                top: Space.xs,
                left: SettingsIcon.size + Space.m,
              ),
              child: Text(
                subtitle!,
                style: TypeScale.bodySmall.copyWith(
                  color: theme.textTheme.bodySmall?.color,
                ),
              ),
            ),
          const SizedBox(height: Space.s),
          LayoutBuilder(
            builder: (context, constraints) {
              final style = theme.textTheme.bodyMedium!.copyWith(
                fontSize: TypeScale.bodyMedium.fontSize,
              );
              var requiredWidth = 8.0;
              for (final (_, label) in options) {
                final painter = TextPainter(
                  text: TextSpan(text: label, style: style),
                  textDirection: Directionality.of(context),
                  textScaler: MediaQuery.textScalerOf(context),
                )..layout();
                requiredWidth += (painter.width < 48 ? 48 : painter.width) + 20;
                painter.dispose();
              }
              final fits = requiredWidth <= constraints.maxWidth;
              Widget option(T value, String label, {Widget? child}) =>
                  Semantics(
                    label: '$title: $label',
                    excludeSemantics: true,
                    selected: value == selected,
                    button: true,
                    inMutuallyExclusiveGroup: true,
                    onTap: () => onSelected(value),
                    child: child ?? Text(label, style: style),
                  );
              if (fits) {
                return SizedBox(
                  width: double.infinity,
                  child: CupertinoSlidingSegmentedControl<T>(
                    proportionalWidth: true,
                    groupValue: selected,
                    onValueChanged: (value) {
                      if (value != null) onSelected(value);
                    },
                    children: {
                      for (final (value, label) in options)
                        value: Semantics(
                          label: '$title: $label',
                          excludeSemantics: true,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(
                              minWidth: 48,
                              minHeight: 48,
                            ),
                            child: Center(child: Text(label, style: style)),
                          ),
                        ),
                    },
                  ),
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (value, label) in options)
                    option(
                      value,
                      label,
                      child: CupertinoButton(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        minimumSize: const Size(48, 48),
                        onPressed: () => onSelected(value),
                        child: Row(
                          children: [
                            Expanded(child: Text(label, style: style)),
                            const SizedBox(width: 12),
                            SizedBox.square(
                              dimension: 24,
                              child: value == selected
                                  ? const ExcludeSemantics(
                                      child: Icon(
                                        CupertinoIcons.check_mark,
                                        size: 20,
                                      ),
                                    )
                                  : null,
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
