/// Dau trang Home kieu iOS: thanh pho, nhiet do rat lon, mo ta, cao/thap,
/// cam giac, mot cau "Hôm nay"; cuon len -> thu gon thanh hai dong
/// "TP. Hồ Chí Minh" / "26° | Nhiều mây". Dieu khien hoan toan bang vi tri
/// cuon (khong hen gio).
library;

import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../design_tokens.dart';
import '../glass_ink.dart';
import 'glass_card.dart';
import 'home_motion.dart';
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
    this.todayRain = false,
    this.updated,
    this.refreshing = false,
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

  /// Cau tom tat hanh dong (mot dong, vd. "Dông 12–13h · mang áo mưa").
  final String? today;

  /// [today] noi ve mua (icon o / mau mua).
  final bool todayRain;

  /// Dang lam moi tren nen du lieu cu: cham xoay nho canh gio cap nhat.
  final bool refreshing;

  /// "Cập nhật 12:00".
  final String? updated;
  final bool isStale;

  /// "Đã lưu 21:05" khi dang hien cache offline.
  final String? cachedNote;

  /// Nhan nguon cua so lieu hien tai ("Thực tế"...).
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
    cachedNote,
    sourceLabel,
  );
}

/// Kieu chu cau hanh dong duoi nhiet do (dung chung do + ve).
const TextStyle _todayStyle = TextStyle(
  fontSize: 15,
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
        _line(i.detail, TypeScale.small.copyWith(fontSize: 13));
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
class CollapsingHeaderDelegate extends SliverPersistentHeaderDelegate {
  CollapsingHeaderDelegate({
    required this.info,
    required this.metrics,
    required this.actions,
    required this.glassColor,
    required this.ink,
    this.trailing,
    this.loading = false,
    this.onCityLongPress,
  });

  final WeatherHeaderInfo info;
  final HeaderMetrics metrics;

  /// Nut ben trai thanh tren.
  final Widget actions;

  /// Nut ben phai (tieu de gon can giua giua hai nhom).
  final Widget? trailing;
  final Color glassColor;
  final GlassInk ink;
  final bool loading;
  final VoidCallback? onCityLongPress;

  /// Key cua vung cat noi dung lon (dung trong test).
  static const Key heroClipKey = ValueKey<String>('hero-clip');

  /// Key cua khoi chu o thanh gon (dung trong test).
  static const Key compactTitleKey = ValueKey<String>('compact-title');

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

  /// Noi dung lon troi theo cuon va bi cat o mep thanh nut, nen chi mo dan
  /// o doan cuoi (tranh khoang trong lon khi cuon do).
  static double expandedOpacityAt(double t) =>
      (1 - (t - 0.4) / 0.5).clamp(0.0, 1.0);

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
        // Hang nut + dong thu gon: ten can giua man hinh neu du cho, neu
        // khong thi day sang phai cua nhom nut va cat "..." (khong de len nut).
        Positioned(
          top: top,
          left: 0,
          right: 0,
          height: barHeight,
          child: CustomMultiChildLayout(
            delegate: _BarLayout(),
            children: [
              LayoutId(id: _BarSlot.actions, child: actions),
              if (trailing != null)
                LayoutId(id: _BarSlot.trailing, child: trailing!),
              if (compactOpacity > 0)
                LayoutId(
                  id: _BarSlot.title,
                  child: Opacity(
                    opacity: compactOpacity,
                    child: Semantics(
                      header: true,
                      label: compact == null
                          ? info.city
                          : '${info.city}, $compact',
                      excludeSemantics: true,
                      child: Column(
                        key: compactTitleKey,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            info.city,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            softWrap: false,
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
                              softWrap: false,
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
            ],
          ),
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
      old.actions != actions ||
      old.trailing != trailing;
}

enum _BarSlot { actions, trailing, title }

/// Bo cuc hang tren: nhom nut ben trai (cao [HeaderMetrics.actionsHeight],
/// can giua doc); ten can giua theo chieu ngang neu khong cham nut, neu
/// khong thi bat dau sau nut + [Space.s] va bi gioi han rong (ellipsis).
class _BarLayout extends MultiChildLayoutDelegate {
  @override
  void performLayout(Size size) {
    final loose = BoxConstraints.loose(
      Size(size.width, HeaderMetrics.actionsHeight),
    );
    double left = 0;
    double right = 0;
    if (hasChild(_BarSlot.actions)) {
      final Size a = layoutChild(_BarSlot.actions, loose);
      positionChild(
        _BarSlot.actions,
        Offset(Space.xs, (size.height - a.height) / 2),
      );
      left = Space.xs + a.width;
    }
    if (hasChild(_BarSlot.trailing)) {
      final Size a = layoutChild(_BarSlot.trailing, loose);
      positionChild(
        _BarSlot.trailing,
        Offset(size.width - Space.xs - a.width, (size.height - a.height) / 2),
      );
      right = Space.xs + a.width;
    }
    if (hasChild(_BarSlot.title)) {
      // Can giua that su: chua lai hai ben bang nhom nut rong hon.
      final double inset = (left > right ? left : right) + Space.s;
      double start = inset;
      double end = size.width - inset;
      if (end - start < 96) {
        start = left + Space.s;
        end = size.width - (right > 0 ? right + Space.s : Space.l);
      }
      final double maxW = (end - start).clamp(0.0, size.width);
      final Size t = layoutChild(
        _BarSlot.title,
        BoxConstraints(maxWidth: maxW, maxHeight: size.height),
      );
      final double centered = (size.width - t.width) / 2;
      final double x = centered < start
          ? start
          : (centered + t.width > end ? end - t.width : centered);
      positionChild(_BarSlot.title, Offset(x, (size.height - t.height) / 2));
    }
  }

  @override
  bool shouldRelayout(_BarLayout oldDelegate) => false;
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
                  // Vung nhan >= 48 dp (ten mot dong).
                  child: Container(
                    constraints: const BoxConstraints(minHeight: Touch.min),
                    alignment: Alignment.center,
                    child: Text(
                      info.city,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TypeScale.city.copyWith(
                        color: Palette.white,
                        shadows: _shadow,
                      ),
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
                        child: CountUpTemperature(
                          text: info.temperature!,
                          memoryKey: info.city,
                          style: TypeScale.hero.copyWith(
                            color: Palette.white,
                            shadows: _shadow,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                if (info.heroCondition != null)
                  Text(
                    info.heroCondition!,
                    textAlign: TextAlign.center,
                    style: TypeScale.condition.copyWith(
                      color: Palette.white,
                      shadows: _shadow,
                    ),
                  ),
                if (info.today != null) ...[
                  const SizedBox(height: Space.xs),
                  _TodayChip(text: info.today!, rain: info.todayRain),
                  const SizedBox(height: Space.xs),
                ],
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
                      info.refreshing
                          ? _RefreshingPill(label: info.updated!)
                          : GlassPill(
                              label: info.updated!,
                              icon: Icons.update_rounded,
                              semanticsLabel:
                                  'Thời điểm số liệu: ${info.updated}',
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

/// Cau hanh dong duoi nhiet do: nen kinh nhe, icon o (mua) / mat troi.
class _TodayChip extends StatelessWidget {
  const _TodayChip({required this.text, required this.rain});

  final String text;
  final bool rain;

  @override
  Widget build(BuildContext context) {
    final GlassInk ink = GlassInk.of(context);
    // Mua: nen pha mau mua + vien mua de noi bat hon trang thai hien tai.
    return DecoratedBox(
      decoration: BoxDecoration(
        color: rain
            ? Color.alphaBlend(
                ink.rain.withValues(alpha: 0.16),
                Colors.black.withValues(alpha: 0.30),
              )
            : Colors.black.withValues(alpha: 0.22),
        borderRadius: BorderRadius.circular(Radii.pill),
        border: Border.all(
          color: rain ? ink.rain.withValues(alpha: 0.55) : Palette.border,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Space.m,
          vertical: Space.xs,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ExcludeSemantics(
              child: Icon(
                rain ? Icons.umbrella_rounded : Icons.wb_sunny_outlined,
                size: IconSizes.sm,
                color: rain ? ink.rain : Palette.white,
              ),
            ),
            const SizedBox(width: Space.xs),
            Flexible(
              child: Text(
                text,
                textAlign: TextAlign.center,
                style: _todayStyle.copyWith(color: Palette.white),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Cập nhật lúc HH:mm" + cham xoay nho khi dang lam moi tren cache.
class _RefreshingPill extends StatelessWidget {
  const _RefreshingPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final bool reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return Semantics(
      label: '$label, đang làm mới',
      liveRegion: true,
      excludeSemantics: true,
      child: GlassSurface(
        radius: Radii.pill,
        padding: const EdgeInsets.symmetric(
          horizontal: Space.m,
          vertical: Space.xs + 1,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox.square(
              dimension: 12,
              child: reduce
                  ? const Icon(
                      Icons.sync_rounded,
                      size: 12,
                      color: Palette.white,
                    )
                  : const CircularProgressIndicator(
                      strokeWidth: 1.6,
                      color: Palette.white,
                    ),
            ),
            const SizedBox(width: Space.xs),
            Flexible(
              child: Text(
                label,
                style: TypeScale.small.copyWith(
                  fontWeight: FontWeight.w600,
                  color: Palette.white,
                  fontFeatures: kTabular,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
