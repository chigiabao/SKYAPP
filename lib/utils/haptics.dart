import 'package:flutter/services.dart';

/// Phan hoi xuc giac kieu iOS dung chung (khong lam gi tren web/desktop).
/// App chua co cong tac bat/tat rung rieng: theo cai dat he thong.
///
/// - [selection]: doi tab, phan doan (segmented), cong tac, chon ngay.
/// - [light]: hanh dong chinh (nut chinh, lam moi, bat dau theo doi).
/// - [success]: luu / gui / lam moi xong (UINotificationFeedback.success).
/// - [warning]: thao tac pha huy (xoa dia diem) - nhac nhe.
/// - [error]: gui that bai, dang nhap loi, lam moi that bai (va manh ngan,
///   khong dung `vibrate` - tren iOS la mot hoi rung dai).
abstract final class AppHaptics {
  static void selection() => HapticFeedback.selectionClick();

  static void light() => HapticFeedback.lightImpact();

  static void success() => HapticFeedback.mediumImpact();

  static void warning() => HapticFeedback.heavyImpact();

  static void error() => HapticFeedback.heavyImpact();
}

/// Boc ham keo-de-lam-moi: [refresh] tra ve true khi tai thanh cong. Thanh
/// cong -> rung [AppHaptics.success]; that bai (false hoac nem loi) ->
/// [AppHaptics.error] (loi van hien tren man hinh; loi nem ra duoc nem lai).
Future<void> Function() withRefreshHaptic(Future<bool> Function() refresh) =>
    () async {
      final bool ok;
      try {
        ok = await refresh();
      } catch (_) {
        AppHaptics.error();
        rethrow;
      }
      ok ? AppHaptics.success() : AppHaptics.error();
    };
