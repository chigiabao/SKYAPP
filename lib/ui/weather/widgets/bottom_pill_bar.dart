/// Responsive Home navigation and shared location sheets.
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'home_navigation.dart';

export 'home_navigation.dart' show HomeTab;
export 'ios_sheet.dart' show showGlassSheet, showIosSheet;

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
    this.selected = HomeTab.today,
  });

  /// Tab dang mo.
  final HomeTab selected;

  /// Chi so trang vi tri hien tai trong nhan truy cap; null -> theo
  /// [firstIsCurrentLocation].
  final int? currentLocationIndex;

  /// Nut nhanh "Tôi sắp ra ngoài" -> Chuyen di (null = an nut).
  final VoidCallback? onTrip;

  /// Rain probability for semantics; a small dot signals available data.
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
  static const double height = HomeNavigation.minHeight;

  static double heightFor(double width, TextScaler scaler) =>
      HomeNavigation.heightFor(width, scaler);

  /// Dem cuoi cho moi danh sach cuon nam sau thanh tab.
  static double reservedHeight(BuildContext context) =>
      HomeNavigation.reservedHeight(context);

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
      selected: selected,
      locationPosition:
          '${isCurrent ? 'Vị trí hiện tại. ' : ''}'
          'Địa điểm ${currentPage + 1} trên $pageCount',
    );
  }
}
