/// Design tokens cua giao dien kinh (khoang cach, bo goc, chu, chuyen dong,
/// icon, do mo, mau co dinh). Widget trong lib/ui/weather/widgets dung cac
/// hang so nay thay vi so / mau viet tay.
library;

import 'package:flutter/animation.dart';
import 'package:flutter/painting.dart';

/// Khoang cach (nhip 4/8).
abstract final class Space {
  static const double xs = 4;
  static const double s = 8;
  static const double m = 12;
  static const double l = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const double xxxl = 48;

  /// Dem trong the.
  static const double cardPadding = 16;

  /// Khoang giua cac the.
  static const double cardGap = 12;

  /// Khoang giua cac phan.
  static const double sectionGap = 24;

  /// Chieu rong toi da cot noi dung.
  static const double contentMaxWidth = 640;

  /// Le trang theo chieu rong man hinh: 16 (dien thoai), 24 (>= 600),
  /// 32 (may tinh bang ngang).
  static double gutter(double width, {bool landscape = false}) {
    if (width >= 900 && landscape) return 32;
    if (width >= 600) return 24;
    return 16;
  }
}

/// Bo goc.
abstract final class Radii {
  static const double card = 22;
  static const double tile = 18;
  static const double pill = 999;
  static const double bar = 3;
}

/// Kich thuoc icon.
abstract final class IconSizes {
  static const double sm = 16;
  static const double md = 24;
  static const double lg = 32;
  static const double hero = 64;
}

/// Kich thuoc cham toi thieu (dp).
abstract final class Touch {
  static const double min = 48;
}

/// Do mo dung chung.
abstract final class Opacities {
  /// Chu phu tren kinh (da kiem >= 4.5:1 tren moi canh, xem
  /// test/glass_contrast_test.dart).
  static const double secondary = 0.85;

  /// Tieu de nho viet hoa cua the.
  static const double title = 0.80;
  static const double border = 0.18;
  static const double highlight = 0.25;
  static const double divider = 0.18;
  static const double track = 0.20;
  static const double pressed = 0.7;
}

/// Mau co dinh (khong phu thuoc canh).
abstract final class Palette {
  static const Color white = Color(0xFFFFFFFF);
  static const Color secondary = Color(0xD9FFFFFF); // 0.85
  static const Color title = Color(0xCCFFFFFF); // 0.80
  static const Color border = Color(0x2EFFFFFF); // 0.18
  static const Color highlight = Color(0x40FFFFFF); // 0.25
  static const Color divider = Color(0x2EFFFFFF);
  static const Color track = Color(0x33FFFFFF); // 0.20
  static const Color subtleFill = Color(0x1FFFFFFF); // o con trong the
  static const Color dotRing = Color(0xFF1E293B);

  /// Chu "mua" tren kinh (xanh nhat, >= 4.5:1).
  static const Color rain = Color(0xFF9EDBFF);

  /// Canh bao: nen amber + chu toi.
  static const Color alert = Color(0xFFF59E0B);
  static const Color onAlert = Color(0xFF0F172A);

  /// Nhan "Dữ liệu cũ".
  static const Color stale = Color(0xFFFFD27A);

  /// Thang nhiet do: mat -> diu -> am -> nong -> rat nong.
  static const Color tempCool = Color(0xFF5AC8FA);
  static const Color tempMild = Color(0xFFA3E635);
  static const Color tempWarm = Color(0xFFFACC15);
  static const Color tempHot = Color(0xFFFB923C);
  static const Color tempVeryHot = Color(0xFFEF4444);

  /// Nen bottom sheet (tron voi mau kinh cua canh).
  static const Color sheetBase = Color(0xB3141C2B);
  static const Color barrier = Color(0x66000000);
  static const Color textShadow = Color(0x40000000);
}

/// Thang chu (sp). Chu so luon dung [tabular].
abstract final class TypeScale {
  static const String family = 'Inter';
  static const List<FontFeature> tabular = [FontFeature.tabularFigures()];

  /// Nhiet do lon chi phong toi 1.3 lan.
  static const double heroMaxScale = 1.3;

  static const TextStyle hero = TextStyle(
    fontSize: 96,
    fontWeight: FontWeight.w200,
    letterSpacing: -2,
    height: 1.05,
    fontFeatures: tabular,
  );
  static const TextStyle city = TextStyle(
    fontSize: 32,
    fontWeight: FontWeight.w300,
    height: 1.2,
  );
  static const TextStyle condition = TextStyle(
    fontSize: 20,
    fontWeight: FontWeight.w400,
    height: 1.25,
  );
  static const TextStyle hiLo = TextStyle(
    fontSize: 17,
    fontWeight: FontWeight.w500,
    height: 1.3,
    fontFeatures: tabular,
  );
  static const TextStyle bigValue = TextStyle(
    fontSize: 34,
    fontWeight: FontWeight.w300,
    height: 1.1,
    fontFeatures: tabular,
  );
  static const TextStyle label = TextStyle(
    fontSize: 17,
    fontWeight: FontWeight.w500,
    height: 1.25,
  );
  static const TextStyle body = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w400,
    height: 1.35,
  );
  static const TextStyle cardTitle = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.6,
  );
  static const TextStyle hourLabel = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w500,
    fontFeatures: tabular,
  );
  static const TextStyle small = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w500,
    height: 1.3,
  );
}

/// Chuyen dong.
abstract final class Motion {
  static const Duration micro = Duration(milliseconds: 120);
  static const Duration short = Duration(milliseconds: 220);
  static const Duration medium = Duration(milliseconds: 350);
  static const Duration scene = Duration(milliseconds: 700);

  /// Thoat nhanh hon vao ~30 %.
  static const Duration shortExit = Duration(milliseconds: 150);
  static const Duration stagger = Duration(milliseconds: 50);
  static const int maxStaggered = 6;
  static const double riseOffset = 12;

  static const Curve enter = Curves.easeOutCubic;
  static const Curve exit = Curves.easeInCubic;
}
