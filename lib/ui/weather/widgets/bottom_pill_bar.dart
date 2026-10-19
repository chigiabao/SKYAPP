/// Responsive Home navigation and shared location sheets.
library;

import 'package:flutter/material.dart';

import '../../../providers/location_provider.dart';
import '../../../screens/map_screen.dart';
import '../app_scene.dart';
import '../design_tokens.dart';
import 'glass_card.dart';
import 'home_navigation.dart';

/// Labeled destinations with an explicit selected state and 48 dp targets.
class BottomPillBar extends StatelessWidget {
  const BottomPillBar({
    super.key,
    required this.pageCount,
    required this.currentPage,
    required this.onMap,
    required this.onLocations,
    this.onTrip,
    this.tripRainPercent,
    this.firstIsCurrentLocation = true,
    this.currentLocationIndex,
    this.onHome,
    this.vertical = false,
  });

  /// Chi so trang vi tri hien tai trong nhan truy cap; null -> theo
  /// [firstIsCurrentLocation].
  final int? currentLocationIndex;

  /// Nut nhanh "Tôi sắp ra ngoài" -> Chuyen di (null = an nut).
  final VoidCallback? onTrip;

  /// Xac suat mua lon nhat 2 gio toi (%), hien nho tren nut; null = an.
  final int? tripRainPercent;

  /// Trang dau la vi tri hien tai khi khong co currentLocationIndex.
  final bool firstIsCurrentLocation;
  final int pageCount;
  final int currentPage;
  final VoidCallback onMap;
  final VoidCallback onLocations;
  final VoidCallback? onHome;
  final bool vertical;

  /// Chieu cao thanh (khong tinh vung an toan).
  static const double height = 104;

  static double heightFor(double width, TextScaler scaler) =>
      HomeNavigation.heightFor(width, scaler);

  @override
  Widget build(BuildContext context) {
    final isCurrent = currentLocationIndex != null
        ? currentPage == currentLocationIndex
        : firstIsCurrentLocation && currentPage == 0;
    return HomeNavigation(
      onHome: onHome,
      onMap: onMap,
      onLocations: onLocations,
      onTrip: onTrip,
      rainPercent: tripRainPercent,
      vertical: vertical,
      locationPosition:
          '${isCurrent ? 'Vị trí hiện tại. ' : ''}'
          'Địa điểm ${currentPage + 1} trên $pageCount',
    );
  }
}

/// Bottom sheet kinh dung chung.
Future<T?> showGlassSheet<T>(
  BuildContext context, {
  required String title,
  required Widget Function(BuildContext) builder,
}) {
  final Color glass = AppScene.of(context).theme.glassColor;
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Palette.barrier,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: GlassSurface(
            // Kinh dam hon de doc tot tren bat ky canh nao.
            tint: Color.alphaBlend(glass, Palette.sheetBase),
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
            child: DefaultTextStyle.merge(
              style: const TextStyle(color: Colors.white),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: const Color(0x66FFFFFF),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Semantics(
                    header: true,
                    child: Text(
                      title,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Flexible(child: SingleChildScrollView(child: builder(ctx))),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Mo man hinh ban do. Tra ve id dia diem nguoi dung chon "Xem chi tiết"
/// (null neu chi xem).
Future<String?> openLocationMap(
  BuildContext context, {
  required LocationProvider locations,
  String? focusLocationId,
}) {
  return Navigator.of(context).push<String>(
    MaterialPageRoute(
      builder: (_) =>
          MapScreen(locations: locations, focusLocationId: focusLocationId),
    ),
  );
}
