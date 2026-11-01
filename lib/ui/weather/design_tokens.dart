/// Design tokens DUY NHAT cua app (khoang cach, bo goc, chu, chuyen dong,
/// icon, do mo, mau). Man hinh va widget dung cac hang so nay thay vi so /
/// mau viet tay; lib/utils/theme.dart dung [SystemColors]. Bang mau: xem
/// lib/ui/weather/README.md (muc "Bảng màu").
library;

import 'package:flutter/animation.dart';
import 'package:flutter/foundation.dart';
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

  /// Bo goc nho / vua / lon cho trang Material ngoai kinh (o, chip, banner).
  static const double small = 8;
  static const double medium = 16;
  static const double large = 24;

  /// Kieu iOS: nhom danh sach inset-grouped, nut, o nhap, sheet.
  static const double group = 12;
  static const double button = 12;
  static const double field = 10;
  static const double sheet = 13;
}

/// Kich thuoc icon.
abstract final class IconSizes {
  static const double sm = 16;
  static const double md = 24;
  static const double lg = 32;
  static const double hero = 64;

  /// Icon dong trong danh sach / chip (20), icon thoi tiet trong bang (28),
  /// icon trang thai trong / loi (48).
  static const double inline = 20;
  static const double row = 28;
  static const double state = 48;
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

  /// So nhiet do lon khi du lieu cu (van >= 3:1 cho chu lon tren nen toi).
  static const double staleHero = 0.6;
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

  /// Chu toi tren nen trang / amber (~17:1 tren trang).
  static const Color ink = Color(0xFF0F172A);

  /// Canh bao: nen amber + chu toi.
  static const Color alert = Color(0xFFF59E0B);
  static const Color onAlert = ink;

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

  /// Nen sheet iOS (dac: noi dung phia sau khong lam roi chu).
  static const Color sheetSolid = Color(0xFF141C2B);

  /// Nen thanh tieu de ghim cua Home: gan dac (96%) de noi dung cuon ben
  /// duoi khong ve de len ten dia diem/nut; [headerSolid] cho tuong phan cao.
  static const Color header = Color(0xF520232B);
  static const Color headerSolid = Color(0xFF20232B);
  static const Color barrier = Color(0x66000000);

  /// Thanh dieu huong iOS khi noi dung cuon ben duoi (mo 72 % + blur).
  static const Color navBar = Color(0xB81A1F29);

  /// Lop toi phu nen canh cua man hinh phu (tieu de nhom, chu thich, chan
  /// trang nam thang tren nen): chu trang nho >= 4.5:1 ca o canh sang.
  static const Color pageDim = Color(0x4D000000);

  /// Hang danh sach dang bi nhan (iOS highlight).
  static const Color rowPressed = Color(0x29FFFFFF);
  static const Color textShadow = Color(0x40000000);

  /// Vien o nhap chua chon tren kinh (trang 50 %).
  static const Color fieldBorder = Color(0x80FFFFFF);

  /// Chu tren nut trang dac (dang nhap).
  static const Color onWhite = Color(0xFF0B1F33);

  /// Nen tooltip bieu do tren kinh; vien cham chuoi so sanh.
  static const Color chartTooltip = Color(0xF0141C2B);
  static const Color chartInk = Color(0xFF141C2B);

  /// Luoi bieu do so sanh (trang 16 %).
  static const Color chartGrid = Color(0x29FFFFFF);

  /// Bo chon che do o Home (CupertinoSlidingSegmentedControl).
  static const Color segmentTrack = Color(0x66282B33);
  static const Color segmentThumb = Color(0xFF555A65);

  /// Banner trang thai tren Home (gan dac).
  static const Color banner = Color(0xF2262C30);

  /// Nut nguy hiem (nen do, chu trang ~6.5:1); nen vuot-de-xoa.
  static const Color danger = Color(0xFFB3261E);
  static const Color swipeDelete = Color(0xCCB91C1C);

  /// Chu hanh dong nguy hiem tren kinh toi (>= 4.5:1).
  static const Color dangerOnGlass = Color(0xFFFF9A8F);

  /// Nut dung o che do lai xe (chu trang).
  static const Color stop = Color(0xFFEF4444);

  /// Nen che do lai xe (toi 80 %).
  static const Color drivingScrim = Color(0xCC0B1220);

  /// Nen banner "Đang xem lại" (chu trang ~6.9:1).
  static const Color replay = Color(0xFF8A4B00);
}

/// Mau du lieu: thang ban do, muc nguy hiem tuyen duong, chuoi so sanh.
/// Thang mau luon di kem nhan chu / hinh dang (khong chi dua vao mau).
abstract final class DataColors {
  /// Thang kha nang mua (%): < 20, 20-40, 40-60, 60-80, >= 80.
  static const List<Color> rainScale = [
    Color(0xFFE0F2FE),
    Color(0xFFBAE6FD),
    Color(0xFF7DD3FC),
    Color(0xFF38BDF8),
    Color(0xFF0EA5E9),
  ];

  /// Thang gio (km/h): < 10, 10-20, 20-30, 30-40, >= 40.
  static const List<Color> windScale = [
    Color(0xFFE2E8F0),
    Color(0xFFA7F3D0),
    Color(0xFFFDE68A),
    Color(0xFFFDBA74),
    Color(0xFFFCA5A5),
  ];

  /// Nhan gio giat manh; o khong co du lieu.
  static const Color gust = Color(0xFFB91C1C);
  static const Color noData = Color(0xFFCBD5E1);

  /// Nen ban do khi khong co tile; chu toi tren o sang.
  static const Color mapBase = Color(0xFF1B2333);
  static const Color mapLabelDark = Color(0xFF000000);

  /// Ranh gioi TP.HCM, vien o luoi, bong ghim.
  static const Color boundaryFill = Color(0x14FFFFFF);
  static const Color boundaryStroke = Color(0xE60B3A66);
  static const Color cellBorder = Color(0x1FFFFFFF);
  static const Color pinShadow = Color(0xAA000000);

  /// Muc nguy hiem tren tuyen: chua ro / khong / mua / mua to / dong.
  static const Color hazardUnknown = Color(0xFF9CA3AF);
  static const Color hazardLowRain = Color(0xFF38BDF8);
  static const Color hazardNone = Color(0xFF34D399);
  static const Color hazardRain = Color(0xFFFACC15);
  static const Color hazardHeavy = Color(0xFFFB923C);
  static const Color hazardStorm = Color(0xFFEF4444);

  /// Vien toi duoi tuyen; nhan ban quyen ban do (nen trang + chu toi).
  static const Color routeCasing = Color(0x99000000);
  static const Color attributionBg = Color(0xB3FFFFFF);
  static const Color attributionText = Color(0xFF1F2937);

  /// Ba chuoi so sanh (kem net lien / dut / cham).
  static const Color seriesA = Color(0xFF7DD3FC);
  static const Color seriesB = Color(0xFFFCD34D);
  static const Color seriesC = Color(0xFFF0ABFC);
}

/// Mau nhan tren trang Material ngoai kinh, theo nen: `...OnLight` dung tren
/// nen sang (>= 4.5:1 cho chu, >= 3:1 cho icon), `...OnDark` tren nen toi.
/// Tren kinh dung [Palette] / GlassInk.
abstract final class Tones {
  /// Xanh thuong hieu: nhat / dam (chu trang tren [brandDeep] ~4.6:1) / diu.
  static const Color brand = Color(0xFF2196F3);
  static const Color brandDeep = Color(0xFF1976D2);
  static const Color brandSoft = Color(0xFF64B5F6);

  /// Nen noi / o chon toi (tooltip, chon ngay).
  static const Color navySurface = Color(0xFF16213E);
  static const Color navyCard = Color(0xFF1F3460);

  /// Chu tren nen toi; chu phu tren nen sang (~5:1 tren trang).
  static const Color textOnDark = Color(0xFFE0E0E0);
  static const Color secondaryOnLight = Color(0xFF6B6B6B);

  /// Chu phu tren nen xanh dam (trang 95 %).
  static const Color onBrandSecondary = Color(0xF2FFFFFF);

  static const Color rainOnDark = Color(0xFF4FC3F7);
  static const Color rainOnLight = Color(0xFF0277BD);
  static const Color airOnDark = Color(0xFF90CAF9);
  static const Color airOnLight = brandDeep;
  static const Color pressureOnDark = Color(0xFFB39DDB);
  static const Color pressureOnLight = Color(0xFF5E35B1);
  static const Color warmOnDark = Color(0xFFFFB74D);
  static const Color warmOnLight = Color(0xFFC2410C);
  static const Color neutralOnDark = Color(0xFFB0BEC5);
  static const Color neutralOnLight = Color(0xFF546E7A);

  /// Thuc te / da xac nhan.
  static const Color successOnDark = Color(0xFF81C784);
  static const Color successOnLight = Color(0xFF2E7D32);

  /// Nguon AI; duong gio tren bieu do.
  static const Color tealOnDark = Color(0xFF80CBC4);
  static const Color tealOnLight = Color(0xFF00695C);
  static const Color windOnLight = Color(0xFF00796B);

  /// Nguon khi hau (amber); gio giat.
  static const Color amberOnDark = Color(0xFFFFB74D);
  static const Color amberOnLight = Color(0xFFB45309);
  static const Color gustOnDark = Color(0xFFFFCC80);

  /// Vach "bay gio" tren bieu do.
  static const Color markerOnDark = Color(0xFFFFD54F);
  static const Color markerOnLight = Color(0xFFC62828);
}

/// Mau he thong kieu iOS cho theme Material/Cupertino (lib/utils/theme.dart)
/// va trang Cai dat.
abstract final class SystemColors {
  /// Chu chinh tren nen sang; cung la nen the toi.
  static const Color label = Color(0xFF1C1C1E);
  static const Color surfaceDark = label;
  static const Color secondaryLabelLight = Color(0xFF636366);
  static const Color secondaryLabelDark = Color(0xFFAEAEB2);

  /// Mau nhan (nut, lien ket); [accentDarkSettings] rieng cho trang Cai dat.
  static const Color accentLight = Color(0xFF0066CC);
  static const Color accentDark = Color(0xFF64D2FF);
  static const Color accentDarkSettings = Color(0xFF64B5FF);
  static const Color onAccentDark = Color(0xFF101113);

  /// Nen trang nhom (sang); nen trang toi.
  static const Color groupedBackground = Color(0xFFF2F2F7);
  static const Color backgroundDark = Color(0xFF111113);

  static const Color separatorLight = Color(0xFFD1D1D6);
  static const Color separatorDark = Color(0xFF38383A);

  /// Chu phu dong cai dat.
  static const Color subtitleLight = Color(0xFF606067);
  static const Color subtitleDark = Color(0xFFB6B6BD);

  /// O mau sau icon cai dat (icon trang).
  static const Color iconRed = Color(0xFFD64545);
  static const Color iconGreen = Color(0xFF287C59);
  static const Color iconOrange = Color(0xFFB05B13);
  static const Color iconPurple = Color(0xFF7860A4);
  static const Color iconBlue = Color(0xFF286EB0);
}

/// Thang chu (sp). Chu so luon dung [tabular].
///
/// MOT ho chu cho toan app: SF Pro (font he thong) tren iOS/macOS goc; Inter
/// (dong goi, du dau tieng Viet) tren web/Android/desktop. Moi kieu Cupertino
/// (nut, thanh dieu huong, tab) cung dung ho nay - truoc day chung mac dinh
/// 'CupertinoSystemText' + letterSpacing -0.41, tren web khong co font do nen
/// roi ve font du phong hep (ten dia diem, "Cài đặt"... trong khac han).
abstract final class TypeScale {
  /// True khi chay native tren thiet bi Apple (co SF Pro he thong).
  static bool get appleSystemFont =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  /// Ho chu dung chung (xem tren).
  static String get family => appleSystemFont ? 'CupertinoSystemText' : 'Inter';

  /// Ho chu cho co chu >= 20 (SF Pro Display tren Apple).
  static String get displayFamily =>
      appleSystemFont ? 'CupertinoSystemDisplay' : 'Inter';

  static const List<FontFeature> tabular = [FontFeature.tabularFigures()];

  // Moi kieu deu mang san fontFamily (getter vi [family] phu thuoc nen tang):
  // ButtonStyle.textStyle / CupertinoButton khong ke thua ho chu cua theme,
  // thieu fontFamily la nhan nut roi ve font du phong hep tren web/Android.
  // --- Thang chu iOS (Apple HIG, co "Large" mac dinh). Phong theo co chu he
  // thong qua TextScaler; khong dat chieu cao co dinh cho khung chua chu. ---
  static TextStyle get largeTitle => TextStyle(
    fontFamily: displayFamily,
    fontSize: 34,
    fontWeight: FontWeight.w700,
    height: 1.2,
    letterSpacing: 0.37,
  );
  static TextStyle get title1 => TextStyle(
    fontFamily: displayFamily,
    fontSize: 28,
    fontWeight: FontWeight.w600,
    height: 1.2,
    letterSpacing: 0.36,
  );
  static TextStyle get title2 => TextStyle(
    fontFamily: displayFamily,
    fontSize: 22,
    fontWeight: FontWeight.w600,
    height: 1.25,
    letterSpacing: 0.35,
  );
  static TextStyle get title3 => TextStyle(
    fontFamily: displayFamily,
    fontSize: 20,
    fontWeight: FontWeight.w600,
    height: 1.25,
    letterSpacing: 0.38,
  );
  static TextStyle get headline => TextStyle(
    fontFamily: family,
    fontSize: 17,
    fontWeight: FontWeight.w600,
    height: 1.3,
    letterSpacing: 0,
  );
  static TextStyle get iosBody => TextStyle(
    fontFamily: family,
    fontSize: 17,
    fontWeight: FontWeight.w400,
    height: 1.3,
    letterSpacing: 0,
  );
  static TextStyle get callout => TextStyle(
    fontFamily: family,
    fontSize: 16,
    fontWeight: FontWeight.w400,
    height: 1.3,
    letterSpacing: 0,
  );
  static TextStyle get subhead => TextStyle(
    fontFamily: family,
    fontSize: 15,
    fontWeight: FontWeight.w400,
    height: 1.33,
    letterSpacing: 0,
  );
  static TextStyle get footnote => TextStyle(
    fontFamily: family,
    fontSize: 13,
    fontWeight: FontWeight.w400,
    height: 1.35,
    letterSpacing: 0,
  );
  static TextStyle get caption1 => TextStyle(
    fontFamily: family,
    fontSize: 12,
    fontWeight: FontWeight.w400,
    height: 1.35,
    letterSpacing: 0,
  );

  /// Nhan tab bar (HIG 10 pt; dung 11 cho de doc tieng Viet co dau).
  static TextStyle get tabLabel => TextStyle(
    fontFamily: family,
    fontSize: 11,
    fontWeight: FontWeight.w500,
    height: 1.2,
    letterSpacing: 0.07,
  );

  /// Nhiet do lon chi phong toi 1.3 lan.
  static const double heroMaxScale = 1.3;

  static TextStyle get hero => TextStyle(
    fontFamily: displayFamily,
    fontSize: 96,
    fontWeight: FontWeight.w200,
    letterSpacing: 0,
    height: 1.05,
    fontFeatures: tabular,
  );
  static TextStyle get city => TextStyle(
    fontFamily: displayFamily,
    fontSize: 32,
    fontWeight: FontWeight.w300,
    height: 1.2,
  );
  static TextStyle get condition => TextStyle(
    fontFamily: displayFamily,
    fontSize: 20,
    fontWeight: FontWeight.w400,
    height: 1.25,
  );
  static TextStyle get hiLo => TextStyle(
    fontFamily: family,
    fontSize: 17,
    fontWeight: FontWeight.w500,
    height: 1.3,
    fontFeatures: tabular,
  );
  static TextStyle get bigValue => TextStyle(
    fontFamily: displayFamily,
    fontSize: 34,
    fontWeight: FontWeight.w300,
    height: 1.1,
    fontFeatures: tabular,
  );
  static TextStyle get label => TextStyle(
    fontFamily: family,
    fontSize: 17,
    fontWeight: FontWeight.w500,
    height: 1.25,
  );
  static TextStyle get body => TextStyle(
    fontFamily: family,
    fontSize: 15,
    fontWeight: FontWeight.w400,
    height: 1.35,
  );
  static TextStyle get cardTitle => TextStyle(
    fontFamily: family,
    fontSize: 12,
    fontWeight: FontWeight.w600,
    letterSpacing: 0,
  );
  static TextStyle get hourLabel => TextStyle(
    fontFamily: family,
    fontSize: 13,
    fontWeight: FontWeight.w500,
    fontFeatures: tabular,
  );
  static TextStyle get small => TextStyle(
    fontFamily: family,
    fontSize: 12,
    fontWeight: FontWeight.w500,
    height: 1.3,
  );

  // Kieu chu cho trang Material ngoai kinh (khong dat height; truoc day la
  // AppTextStyles trong lib/utils/constants.dart).
  static TextStyle get temperatureSmall =>
      TextStyle(fontFamily: family, fontSize: 18, fontWeight: FontWeight.w500);
  static TextStyle get heading2 =>
      TextStyle(fontFamily: family, fontSize: 20, fontWeight: FontWeight.w600);
  static TextStyle get heading3 =>
      TextStyle(fontFamily: family, fontSize: 16, fontWeight: FontWeight.w600);
  static TextStyle get bodyLarge =>
      TextStyle(fontFamily: family, fontSize: 16, fontWeight: FontWeight.w400);
  static TextStyle get bodyMedium =>
      TextStyle(fontFamily: family, fontSize: 14, fontWeight: FontWeight.w400);
  static TextStyle get bodySmall =>
      TextStyle(fontFamily: family, fontSize: 12, fontWeight: FontWeight.w400);
  static TextStyle get caption => TextStyle(
    fontFamily: family,
    fontSize: 12,
    fontWeight: FontWeight.w400,
    letterSpacing: 0.3,
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
