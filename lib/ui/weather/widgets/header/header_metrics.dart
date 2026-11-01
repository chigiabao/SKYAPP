part of '../collapsing_header.dart';

/// Noi dung dau trang (da dinh dang san; null = khong co so lieu).
@immutable
class WeatherHeaderInfo {
  const WeatherHeaderInfo({
    required this.city,
    required this.detail,
    this.temperature,
    this.condition,
    this.highLow,
    this.feelsLike,
    this.today,
    this.todayRain = false,
    this.updated,
    this.refreshing = false,
    this.isStale = false,
    this.staleAt,
    this.cachedNote,
    this.sourceLabel,
    this.semanticsTemp,
  });

  final String city;
  final String detail;

  /// "26°"; null khi chua co du lieu.
  final String? temperature;
  final String? condition;

  /// "Cao 30° · Thấp 24°".
  final String? highLow;

  /// "Cảm giác như 33°".
  final String? feelsLike;

  /// Cau tom tat hanh dong (mot dong, vd. "Dông 12–13h · mang áo mưa").
  final String? today;

  /// [today] noi ve mua (icon o / mau mua).
  final bool todayRain;

  /// Dang lam moi tren nen du lieu cu: cham xoay nho canh gio cap nhat.
  final bool refreshing;

  /// "Cập nhật 12:00".
  final String? updated;
  final bool isStale;

  /// "Lúc 15:00 27/10": thoi diem cua so lieu cu, hien ngay canh so nhiet do
  /// (chi khi [isStale]) de khong bi hieu nham la gia tri hien tai.
  final String? staleAt;

  /// "Đã lưu 21:05" khi dang hien cache offline.
  final String? cachedNote;

  /// Nhan nguon cua so lieu hien tai ("Đã ghi nhận"...).
  final String? sourceLabel;

  /// Nhan doc cho nhiet do ("Nhiệt độ hiện tại: 26°C").
  final String? semanticsTemp;

  /// Dong mo ta o dau trang mo: "Hiện có mây" (trang thai HIEN TAI, phan
  /// biet voi cau du bao ben duoi).
  String? get heroCondition {
    final c = condition;
    if (c == null || c.isEmpty) return c;
    return 'Hiện ${c[0].toLowerCase()}${c.substring(1)}';
  }

  /// Dong duoi ten thanh pho o thanh gon.
  String? get compactText => temperature == null
      ? null
      : condition == null
      ? temperature!
      : '$temperature | $condition';

  @override
  bool operator ==(Object other) =>
      other is WeatherHeaderInfo &&
      other.city == city &&
      other.detail == detail &&
      other.temperature == temperature &&
      other.condition == condition &&
      other.highLow == highLow &&
      other.feelsLike == feelsLike &&
      other.today == today &&
      other.todayRain == todayRain &&
      other.updated == updated &&
      other.refreshing == refreshing &&
      other.isStale == isStale &&
      other.staleAt == staleAt &&
      other.cachedNote == cachedNote &&
      other.sourceLabel == sourceLabel;

  @override
  int get hashCode => Object.hash(
    city,
    temperature,
    condition,
    highLow,
    feelsLike,
    today,
    todayRain,
    updated,
    refreshing,
    isStale,
    staleAt,
    cachedNote,
    sourceLabel,
  );
}

/// Kieu chu cau hanh dong duoi nhiet do (dung chung do + ve).
final TextStyle _todayStyle = TypeScale.subhead.copyWith(
  height: 1.3,
  fontWeight: FontWeight.w600,
  fontFeatures: TypeScale.tabular,
);

/// Kich thuoc dau trang: do theo NOI DUNG (TextPainter cung kieu chu voi
/// [WeatherHeaderBlock]), khong phai chieu cao co dinh.
class HeaderMetrics {
  HeaderMetrics(
    TextScaler scaler, {
    required this.topPadding,
    this.info,
    this.width = 0,
    this.viewportHeight = 0,
  }) : _s = scaler;

  final TextScaler _s;
  final double topPadding;
  final WeatherHeaderInfo? info;

  /// Chieu rong cot chu cua dau trang.
  final double width;
  final double viewportHeight;

  static const double actionsHeight = Touch.min;

  /// He so phong cua nhiet do lon (<= 1.3).
  double get heroScale =>
      (_s.scale(96) / 96).clamp(0.0, TypeScale.heroMaxScale);

  /// Chieu cao thanh gon (nut + hai dong chu), khong tinh vung an toan.
  double get barHeight {
    final double bar = 1.2 * _s.scale(17) + 1.3 * _s.scale(15) + 16;
    return bar < 64 ? 64 : bar;
  }

  /// Khoang trong them phia tren ten thanh pho tren man hinh cao.
  double get extraTop =>
      ((viewportHeight - 760) * 0.25).clamp(0.0, 72.0).toDouble();

  late final double heroHeight = _measure();

  double _line(
    String text,
    TextStyle style, {
    TextScaler? scaler,
    int? maxLines,
    double indent = 0,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: style.copyWith(fontFamily: TypeScale.family),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
      textScaler: scaler ?? _s,
      maxLines: maxLines,
      ellipsis: maxLines == null ? null : '…',
    )..layout(maxWidth: width <= 0 ? double.infinity : width - indent);
    final double h = tp.height;
    tp.dispose();
    return h;
  }

  double _measure() {
    final i = info;
    if (i == null) return 0;
    double h =
        math.max(Touch.min, _line(i.city, TypeScale.city, maxLines: 1)) +
        _line(
          i.detail,
          TypeScale.footnote.copyWith(fontWeight: FontWeight.w500, height: 1.3),
        );
    if (i.temperature == null) return h;
    h += _line(
      i.temperature!,
      TypeScale.hero,
      scaler: TextScaler.linear(heroScale),
    );
    if (i.heroCondition != null) {
      h += _line(i.heroCondition!, TypeScale.condition);
    }
    if (i.today != null) {
      final double t = _line(
        i.today!,
        _todayStyle,
        indent: _s.scale(IconSizes.sm) + Space.xs + 2 * Space.m,
      );
      final double icon = IconSizes.sm.toDouble();
      h += Space.xs + (t > icon ? t : icon) + 2 * Space.xs + 2 + Space.xs;
    }
    if (i.highLow != null) h += _line(i.highLow!, TypeScale.hiLo);
    if (i.feelsLike != null) h += _line(i.feelsLike!, TypeScale.hiLo);
    // Khoang cach + hang pill (chu nho + dem 2 x 5 + vien).
    h +=
        Space.s +
        _line(
          'Cập nhật',
          TypeScale.small.copyWith(fontWeight: FontWeight.w600),
        ) +
        2 * (Space.xs + 1) +
        2;
    return h;
  }

  /// Dau trang mo: thanh nut + khoang tren + noi dung + khoang phan (24).
  double get maxExtent =>
      topPadding + barHeight + extraTop + heroHeight + Space.sectionGap;

  double get minExtent => topPadding + barHeight;
}

/// Delegate cho SliverPersistentHeader (pinned).
///
/// Bo cuc: hang tren cung (cao [HeaderMetrics.barHeight]) chua nut va dong
/// thu gon; noi dung lon nam DUOI hang nay, troi len theo cuon va bi cat o
/// mep duoi hang nut (khong bao gio chay duoi nut). Noi dung mo het khi
/// t = 0.5; thanh gon (kinh) hien du khi t = 0.6.
