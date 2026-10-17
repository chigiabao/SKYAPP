/// Thanh "pill" kinh o day Home: nut ban do, cham trang (moi dia diem mot
/// trang), nut danh sach dia diem. Kem bottom sheet kinh dung chung.
library;

import 'package:flutter/material.dart';

import '../../../providers/location_provider.dart';
import '../../../screens/map_screen.dart';
import '../app_scene.dart';
import '../design_tokens.dart';
import 'glass_card.dart';

/// Thanh pill noi o day man hinh: ban do (trai), cham trang (giua), danh
/// sach dia diem (phai). Nut >= 48 dp.
class BottomPillBar extends StatelessWidget {
  const BottomPillBar({
    super.key,
    required this.pageCount,
    required this.currentPage,
    required this.onMap,
    required this.onLocations,
    this.onTrip,
    this.firstIsCurrentLocation = true,
  });

  /// Mo man "Chuyến đi" (null = an nut).
  final VoidCallback? onTrip;

  /// Trang dau la "Vị trí hiện tại" (cham hinh mui ten).
  final bool firstIsCurrentLocation;
  final int pageCount;
  final int currentPage;
  final VoidCallback onMap;
  final VoidCallback onLocations;

  /// Chieu cao thanh (khong tinh vung an toan).
  static const double height = Touch.min + Space.xs;

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      radius: Radii.pill,
      padding: const EdgeInsets.symmetric(horizontal: Space.xs, vertical: 2),
      child: Row(
        children: [
          GlassIconButton(
            icon: Icons.map_outlined,
            tooltip: 'Bản đồ',
            onPressed: onMap,
          ),
          if (onTrip != null)
            GlassIconButton(
              icon: Icons.directions_car_outlined,
              tooltip: 'Chuyến đi',
              onPressed: onTrip!,
            ),
          Expanded(
            child: Semantics(
              label: 'Địa điểm ${currentPage + 1} trên $pageCount',
              excludeSemantics: true,
              // Nhieu trang: thu nho thay vi tran.
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (int i = 0; i < pageCount; i++)
                      Padding(
                        padding: const EdgeInsets.all(Space.xs),
                        child: Icon(
                          i == 0 && firstIsCurrentLocation
                              ? Icons.near_me_outlined
                              : i == currentPage
                              ? Icons.circle
                              : Icons.circle_outlined,
                          size: i == 0 && firstIsCurrentLocation ? 14 : 8,
                          color: i == currentPage
                              ? Palette.white
                              : Palette.white.withValues(alpha: 0.45),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          GlassIconButton(
            icon: Icons.format_list_bulleted_rounded,
            tooltip: 'Danh sách địa điểm',
            onPressed: onLocations,
          ),
        ],
      ),
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
