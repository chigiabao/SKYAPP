/// Tin hieu tab cho man goc trong moi tab cua [HomeScreen] (tab giu nguyen
/// trang thai trong IndexedStack nen man khong biet khi nao duoc mo lai):
/// - [HomeTabScope.selected]: tab dang mo (doi -> man tu lam moi neu cu).
/// - [HomeTabScope.reselected]: cham lai tab dang mo khi dang o goc tab
///   (man cuon ve dau trang, kieu iOS).
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../design_tokens.dart';
import 'home_navigation.dart' show HomeTab;

class HomeTabScope extends InheritedWidget {
  const HomeTabScope({
    super.key,
    required this.tab,
    required this.selected,
    required this.reselected,
    required super.child,
  });

  /// Tab chua cay con nay.
  final HomeTab tab;

  /// Tab dang mo.
  final ValueListenable<HomeTab> selected;

  /// Bao khi cham lai [tab] luc dang o goc tab.
  final Listenable reselected;

  bool get isActive => selected.value == tab;

  static HomeTabScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<HomeTabScope>();

  @override
  bool updateShouldNotify(HomeTabScope old) =>
      tab != old.tab ||
      selected != old.selected ||
      reselected != old.reselected;
}

/// Man goc cua tab: [tabScroll] gan vao danh sach cuon; cham lai tab ->
/// cuon ve dau ([onTabReselected]); mo lai tab -> [onTabSelected]. Ngoai
/// [HomeScreen] (khong co [HomeTabScope]) thi khong lam gi.
mixin HomeTabRoot<T extends StatefulWidget> on State<T> {
  final ScrollController tabScroll = ScrollController();
  HomeTabScope? _scope;

  /// Tab cua man nay vua duoc mo lai (khong goi o lan dung dau tien).
  void onTabSelected() {}

  /// Cham lai tab dang mo: mac dinh cuon ve dau trang.
  void onTabReselected() => scrollTabToTop();

  void scrollTabToTop() {
    if (!tabScroll.hasClients) return;
    final pos = tabScroll.position;
    if (pos.pixels <= pos.minScrollExtent) return;
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      tabScroll.jumpTo(pos.minScrollExtent);
    } else {
      tabScroll.animateTo(
        pos.minScrollExtent,
        duration: Motion.medium,
        curve: Motion.enter,
      );
    }
  }

  void _onSelected() {
    if (mounted && (_scope?.isActive ?? false)) onTabSelected();
  }

  void _onReselected() {
    if (mounted) onTabReselected();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = HomeTabScope.maybeOf(context);
    if (scope?.selected == _scope?.selected &&
        scope?.reselected == _scope?.reselected) {
      _scope = scope;
      return;
    }
    _unsubscribe();
    _scope = scope;
    scope?.selected.addListener(_onSelected);
    scope?.reselected.addListener(_onReselected);
  }

  void _unsubscribe() {
    _scope?.selected.removeListener(_onSelected);
    _scope?.reselected.removeListener(_onReselected);
  }

  @override
  void dispose() {
    _unsubscribe();
    tabScroll.dispose();
    super.dispose();
  }
}
