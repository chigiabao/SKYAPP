import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../ui/weather/design_tokens.dart';
import '../../ui/weather/widgets/app_segmented_control.dart';
import '../../utils/haptics.dart';

/// Chon "Dự báo" / "Điều kiện"; web / may tinh co them nut lam moi.
class HomeModeBar extends StatelessWidget {
  const HomeModeBar({
    super.key,
    required this.showDetails,
    required this.onChanged,
    required this.refreshing,
    required this.onRefresh,
  });

  final bool showDetails;
  final ValueChanged<bool> onChanged;
  final bool refreshing;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: AppSegmentedControl<bool>(
            key: const ValueKey('home-mode-selector'),
            selected: showDetails,
            onChanged: onChanged,
            segments: const [
              AppSegment(value: false, label: 'Dự báo'),
              AppSegment(value: true, label: 'Điều kiện'),
            ],
          ),
        ),
        // Dien thoai co keo de lam moi; web khong co nen giu nut.
        if (kIsWeb ||
            !{
              TargetPlatform.android,
              TargetPlatform.iOS,
            }.contains(Theme.of(context).platform)) ...[
          const SizedBox(width: Space.s),
          IconButton(
            constraints: const BoxConstraints(
              minWidth: Touch.min,
              minHeight: Touch.min,
            ),
            tooltip: refreshing ? 'Đang cập nhật' : 'Làm mới thời tiết',
            onPressed: onRefresh == null
                ? null
                : () {
                    AppHaptics.light();
                    onRefresh!();
                  },
            icon: const Icon(CupertinoIcons.arrow_clockwise),
          ),
        ],
      ],
    );
  }
}
