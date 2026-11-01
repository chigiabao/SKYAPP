/// Dau trang Home kieu iOS: thanh pho, nhiet do rat lon, mo ta, cao/thap,
/// cam giac, mot cau "Hôm nay"; cuon len -> thu gon thanh hai dong
/// "TP. Hồ Chí Minh" / "26° | Nhiều mây". Dieu khien hoan toan bang vi tri
/// cuon (khong hen gio).
library;

import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../design_tokens.dart';
import '../glass_ink.dart';
import 'glass_card.dart';
import 'home_motion.dart';
import 'shimmer.dart';

part 'header/header_metrics.dart';
part 'header/header_chips.dart';

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
                style: TypeScale.footnote
                    .copyWith(fontWeight: FontWeight.w500, height: 1.3)
                    .merge(sec),
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
