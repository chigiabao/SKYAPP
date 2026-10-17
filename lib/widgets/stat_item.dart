import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../utils/constants.dart';

/// Mot o chi so: icon + nhan (caption) + gia tri. Khong co nen/vien rieng
/// de tranh "the trong the"; luoi cha lo khoang cach.
class StatItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final StatTone tone;

  /// Neu co: icon duoc xoay (radian) — dung cho mui ten huong gio.
  final double? iconRotation;

  /// Nhan doc cho trinh doc man hinh (mac dinh "label: value").
  final String? semanticsLabel;

  const StatItem({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    this.tone = StatTone.neutral,
    this.iconRotation,
    this.semanticsLabel,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget iconWidget = Icon(
      icon,
      size: AppSizes.iconSizeS,
      color: AppColors.statIcon(context, tone),
    );
    if (iconRotation != null) {
      iconWidget = Transform.rotate(angle: iconRotation!, child: iconWidget);
    }

    return MergeSemantics(
      child: Semantics(
        label: semanticsLabel ?? '$label: $value',
        excludeSemantics: true,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSizes.paddingS),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: iconWidget,
              ),
              const SizedBox(width: AppSizes.paddingS),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: AppTextStyles.caption.copyWith(
                        color: theme.textTheme.bodySmall?.color,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      value,
                      style: AppTextStyles.bodyLarge.copyWith(
                        color: theme.textTheme.bodyLarge?.color,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Luoi chi so hien tai trong mot the duy nhat. So cot tu dong: 3 cot o co
/// chu mac dinh, 2 cot khi chu lon (khong tran ngang).
class StatsGrid extends StatelessWidget {
  final String title;
  final List<StatItem> items;

  const StatsGrid({super.key, required this.title, required this.items});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scaler = MediaQuery.textScalerOf(context);

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSizes.paddingM,
          AppSizes.paddingM,
          AppSizes.paddingM,
          AppSizes.paddingS,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: AppTextStyles.heading3.copyWith(
                color: theme.textTheme.titleLarge?.color,
              ),
            ),
            const SizedBox(height: AppSizes.paddingXS),
            LayoutBuilder(
              builder: (context, constraints) {
                const gap = 12.0;
                // O can ~ icon + "1011 hPa" o co chu hien tai.
                final minCell =
                    AppSizes.iconSizeS +
                    AppSizes.paddingS +
                    scaler.scale(AppTextStyles.bodyLarge.fontSize!) * 3.6;
                final columns = math
                    .max(
                      1,
                      ((constraints.maxWidth + gap) / (minCell + gap)).floor(),
                    )
                    .clamp(1, 3);
                final cellWidth =
                    (constraints.maxWidth - gap * (columns - 1)) / columns;

                final rows = <Widget>[];
                for (var i = 0; i < items.length; i += columns) {
                  final rowItems = items.sublist(
                    i,
                    math.min(i + columns, items.length),
                  );
                  rows.add(
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Hang cuoi thieu o: cac o con lai chia deu chieu
                        // rong (vd o le cuoi o luoi 2 cot chiem tron hang).
                        for (var j = 0; j < rowItems.length; j++) ...[
                          if (j > 0) const SizedBox(width: gap),
                          SizedBox(
                            width: rowItems.length == columns
                                ? cellWidth
                                : (constraints.maxWidth -
                                          gap * (rowItems.length - 1)) /
                                      rowItems.length,
                            child: rowItems[j],
                          ),
                        ],
                      ],
                    ),
                  );
                }
                return Column(children: rows);
              },
            ),
          ],
        ),
      ),
    );
  }
}
