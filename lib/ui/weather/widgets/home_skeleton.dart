/// Khung xuong (skeleton) cua Home khi chua co so lieu: hinh dang the
/// "Theo giờ" va "7 ngày" bang khoi mo + lap lanh. Khong phai so gia.
library;

import 'package:flutter/material.dart';

import '../design_tokens.dart';
import 'glass_card.dart';
import 'shimmer.dart';

class HomeSkeleton extends StatelessWidget {
  const HomeSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    Widget line(double w, [double h = 12]) =>
        SkeletonBlock(width: w, height: h);
    return Semantics(
      label: 'Đang tải dữ liệu thời tiết',
      liveRegion: true,
      excludeSemantics: true,
      child: Shimmer(
        enabled: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            GlassCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  line(88),
                  const SizedBox(height: Space.m),
                  line(220, 14),
                  const SizedBox(height: Space.l),
                  LayoutBuilder(
                    builder: (context, c) {
                      final n = (c.maxWidth / 64).floor().clamp(1, 6);
                      return Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          for (var i = 0; i < n; i++)
                            Column(
                              children: [
                                line(32, 10),
                                const SizedBox(height: Space.s),
                                const SkeletonBlock(width: 28, height: 28),
                                const SizedBox(height: Space.s),
                                line(28, 14),
                              ],
                            ),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: Space.cardGap),
            GlassCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  line(120),
                  for (var i = 0; i < 5; i++) ...[
                    const SizedBox(height: Space.l),
                    Row(
                      children: [
                        line(56, 14),
                        const Spacer(),
                        const SkeletonBlock(width: 24, height: 24),
                        const SizedBox(width: Space.l),
                        line(120, 6),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
