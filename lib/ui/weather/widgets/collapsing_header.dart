/// Dau trang Home kieu iOS: thanh pho, nhiet do rat lon, mo ta, cao/thap,
/// cam giac, mot cau "Hôm nay"; cuon len -> thu gon thanh hai dong
/// "TP. Hồ Chí Minh" / "26° | Nhiều mây". Dieu khien hoan toan bang vi tri
/// cuon (khong hen gio).
library;

import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../design_tokens.dart';
import '../glass_ink.dart';
import 'glass_card.dart';
import 'shimmer.dart';

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
    this.updated,
    this.isStale = false,
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

  /// Cau tom tat hom nay (toi da 2 dong).
  final String? today;

  /// "Cập nhật 12:00".
  final String? updated;
  final bool isStale;

  /// "Đã lưu 21:05" khi dang hien cache offline.
  final String? cachedNote;

  /// Nhan nguon cua so lieu hien tai ("Thực tế"...).
  final String? sourceLabel;

  /// Nhan doc cho nhiet do ("Nhiệt độ hiện tại: 26°C").
  final String? semanticsTemp;

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
      other.updated == updated &&
      other.isStale == isStale &&
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
    updated,
    isStale,
    cachedNote,
    sourceLabel,
  );
}

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

  double _line(String text, TextStyle style, {TextScaler? scaler}) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: style.copyWith(fontFamily: TypeScale.family),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
      textScaler: scaler ?? _s,
    )..layout(maxWidth: width <= 0 ? double.infinity : width);
    final double h = tp.height;
    tp.dispose();
    return h;
  }

  double _measure() {
    final i = info;
    if (i == null) return 0;
    double h =
        _line(i.city, TypeScale.city) +
        _line(i.detail, TypeScale.small.copyWith(fontSize: 13));
    if (i.temperature == null) return h;
    h += _line(
      i.temperature!,
      TypeScale.hero,
      scaler: TextScaler.linear(heroScale),
    );
    if (i.condition != null) h += _line(i.condition!, TypeScale.condition);
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
class CollapsingHeaderDelegate extends SliverPersistentHeaderDelegate {
  CollapsingHeaderDelegate({
    required this.info,
    required this.metrics,
    required this.actions,
    required this.glassColor,
    required this.ink,
    this.loading = false,
    this.onCityLongPress,
  });

  final WeatherHeaderInfo info;
  final HeaderMetrics metrics;
  final Widget actions;
  final Color glassColor;
  final GlassInk ink;
  final bool loading;
  final VoidCallback? onCityLongPress;

  /// Key cua vung cat noi dung lon (dung trong test).
  static const Key heroClipKey = ValueKey<String>('hero-clip');

  @override
  double get maxExtent => metrics.maxExtent;

  @override
  double get minExtent => metrics.minExtent;

  /// Ty le thu gon 0 (mo) .. 1 (gon).
  double progress(double shrinkOffset) {
    final double range = maxExtent - minExtent;
    if (range <= 0) return 1;
    return (shrinkOffset / range).clamp(0.0, 1.0);
  }

  static double expandedOpacityAt(double t) => (1 - t / 0.5).clamp(0.0, 1.0);

  static double compactOpacityAt(double t) => ((t - 0.3) / 0.3).clamp(0.0, 1.0);

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final double t = progress(shrinkOffset);
    final double top = metrics.topPadding;
    final double barHeight = metrics.barHeight;
    final double expandedOpacity = expandedOpacityAt(t);
    final double compactOpacity = compactOpacityAt(t);
    final double glassT = (t / 0.6).clamp(0.0, 1.0);
    final String? compact = info.compactText;

    return Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.hardEdge,
      children: [
        // Lop toi nhe sau chu de chu trang dat 4.5:1 tren canh sang.
        if (ink.headerScrim > 0 && glassT < 1)
          IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(
                      alpha: ink.headerScrim * (1 - glassT),
                    ),
                    Colors.black.withValues(
                      alpha: ink.headerScrim * (1 - glassT),
                    ),
                    Colors.black.withValues(alpha: 0),
                  ],
                  stops: const [0, 0.8, 1],
                ),
              ),
            ),
          ),
        // Thanh kinh (blur canh + mau kinh + vien manh duoi).
        if (glassT > 0)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: top + barHeight,
            child: ClipRect(
              child: BackdropFilter(
                filter: ImageFilter.blur(
                  sigmaX: GlassSpec.blurSigma * glassT,
                  sigmaY: GlassSpec.blurSigma * glassT,
                ),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: glassColor.withValues(alpha: glassColor.a * glassT),
                    border: Border(
                      bottom: BorderSide(
                        color: Palette.border.withValues(
                          alpha: Palette.border.a * glassT,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        if (expandedOpacity > 0)
          Positioned(
            top: top + barHeight,
            left: 0,
            right: 0,
            bottom: 0,
            child: ClipRect(
              key: heroClipKey,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    top: metrics.extraTop - shrinkOffset,
                    left: Space.l,
                    right: Space.l,
                    height: metrics.heroHeight,
                    child: IgnorePointer(
                      ignoring: t > 0.3,
                      child: Opacity(
                        opacity: expandedOpacity,
                        child: WeatherHeaderBlock(
                          info: info,
                          metrics: metrics,
                          loading: loading,
                          onCityLongPress: onCityLongPress,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (compactOpacity > 0)
          Positioned(
            top: top,
            left: 104,
            right: 104,
            height: barHeight,
            child: Opacity(
              opacity: compactOpacity,
              child: Semantics(
                header: true,
                label: compact == null ? info.city : '${info.city}, $compact',
                excludeSemantics: true,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      info.city,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TypeScale.label.copyWith(
                        fontWeight: FontWeight.w600,
                        color: Palette.white,
                      ),
                    ),
                    if (compact != null)
                      Text(
                        compact,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TypeScale.body.copyWith(
                          height: 1.2,
                          color: Palette.white,
                          fontFeatures: kTabular,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        Positioned(
          top: top + (barHeight - HeaderMetrics.actionsHeight) / 2,
          left: Space.xs,
          height: HeaderMetrics.actionsHeight,
          child: actions,
        ),
      ],
    );
  }

  @override
  bool shouldRebuild(CollapsingHeaderDelegate old) =>
      old.info != info ||
      old.maxExtent != maxExtent ||
      old.minExtent != minExtent ||
      old.loading != loading ||
      old.glassColor != glassColor ||
      old.ink != ink ||
      old.actions != actions;
}

/// Khoi dau trang day du (dung trong delegate va o cot trai man hinh rong).
class WeatherHeaderBlock extends StatelessWidget {
  const WeatherHeaderBlock({
    super.key,
    required this.info,
    required this.metrics,
    required this.loading,
    this.onCityLongPress,
  });

  final WeatherHeaderInfo info;
  final HeaderMetrics metrics;
  final bool loading;
  final VoidCallback? onCityLongPress;

  static const List<Shadow> _shadow = [
    Shadow(color: Palette.textShadow, blurRadius: 8, offset: Offset(0, 1)),
  ];

  @override
  Widget build(BuildContext context) {
    final GlassInk ink = GlassInk.of(context);
    final TextStyle sec = TextStyle(
      color: ink.headerSecondary,
      shadows: _shadow,
    );
    return LayoutBuilder(
      builder: (context, c) => FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.topCenter,
        child: SizedBox(
          width: c.maxWidth,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Semantics(
                header: true,
                hint: onCityLongPress == null
                    ? null
                    : 'Nhấn giữ để mở giả lập thời tiết',
                child: GestureDetector(
                  onLongPress: onCityLongPress,
                  child: Text(
                    info.city,
                    textAlign: TextAlign.center,
                    style: TypeScale.city.copyWith(
                      color: Palette.white,
                      shadows: _shadow,
                    ),
                  ),
                ),
              ),
              Text(
                info.detail,
                textAlign: TextAlign.center,
                style: TypeScale.small.merge(sec).copyWith(fontSize: 13),
              ),
              if (info.temperature != null) ...[
                Semantics(
                  label: info.semanticsTemp,
                  excludeSemantics: info.semanticsTemp != null,
                  child: Shimmer(
                    enabled: loading,
                    child: MediaQuery.withClampedTextScaling(
                      maxScaleFactor: metrics.heroScale,
                      minScaleFactor: metrics.heroScale,
                      child: Padding(
                        // Can giua phan so (dau ° lech phai).
                        padding: const EdgeInsets.only(left: Space.xl),
                        child: Text(
                          info.temperature!,
                          style: TypeScale.hero.copyWith(
                            color: Palette.white,
                            shadows: _shadow,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                if (info.condition != null)
                  Text(
                    info.condition!,
                    textAlign: TextAlign.center,
                    style: TypeScale.condition.copyWith(
                      color: Palette.white,
                      shadows: _shadow,
                    ),
                  ),
                Shimmer(
                  enabled: loading,
                  child: Column(
                    children: [
                      if (info.highLow != null)
                        Text(
                          info.highLow!,
                          textAlign: TextAlign.center,
                          style: TypeScale.hiLo.copyWith(
                            color: Palette.white,
                            shadows: _shadow,
                          ),
                        ),
                      if (info.feelsLike != null)
                        Text(
                          info.feelsLike!,
                          textAlign: TextAlign.center,
                          style: TypeScale.hiLo.merge(sec),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: Space.s),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    if (info.updated != null)
                      GlassPill(
                        label: info.updated!,
                        icon: Icons.update_rounded,
                        semanticsLabel: 'Thời điểm số liệu: ${info.updated}',
                      ),
                    if (info.isStale)
                      const GlassPill(
                        label: 'Dữ liệu cũ',
                        icon: Icons.history_rounded,
                        iconColor: Palette.alert,
                      ),
                    if (info.cachedNote != null)
                      GlassPill(
                        label: info.cachedNote!,
                        icon: Icons.cloud_off_outlined,
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
