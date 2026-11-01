import 'package:flutter/cupertino.dart';

import '../design_tokens.dart';
import 'collapsing_header.dart';

/// Unframed conditions; missing readings are never filled with placeholders.
class HomeWeatherOverview extends StatelessWidget {
  const HomeWeatherOverview({
    super.key,
    required this.info,
    required this.onTrip,
  });

  final WeatherHeaderInfo info;
  final VoidCallback onTrip;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).height <= 700;
    final centered = MediaQuery.sizeOf(context).width < 900;
    final alignment = centered
        ? CrossAxisAlignment.center
        : CrossAxisAlignment.start;
    final textAlign = centered ? TextAlign.center : TextAlign.start;
    return Semantics(
      container: true,
      child: SizedBox(
        width: double.infinity,
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: compact ? 0 : Space.xl),
          child: LayoutBuilder(
            builder: (context, box) {
              final scaler = TextScaler.linear(
                (MediaQuery.textScalerOf(context).scale(96) / 96).clamp(
                  1.0,
                  TypeScale.heroMaxScale,
                ),
              );
              final temperatureStyle = TypeScale.hero.copyWith(
                fontFeatures: TypeScale.tabular,
                color: Palette.white,
              );
              // Du lieu cu: lam mo so lon + ghi ro thoi diem ngay ben duoi,
              // de khong trong nhu nhiet do hien tai.
              final stale = info.isStale && info.staleAt != null;
              final temperature = Semantics(
                label: info.semanticsTemp,
                excludeSemantics: info.semanticsTemp != null,
                child: Text(
                  info.temperature ?? '',
                  key: const ValueKey('hero-temperature'),
                  textScaler: scaler,
                  style: stale
                      ? temperatureStyle.copyWith(
                          color: Palette.white.withValues(
                            alpha: Opacities.staleHero,
                          ),
                        )
                      : temperatureStyle,
                ),
              );
              final staleAt = stale
                  ? Padding(
                      padding: const EdgeInsets.only(top: Space.xs),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            CupertinoIcons.clock,
                            size: 15,
                            color: Palette.stale,
                          ),
                          const SizedBox(width: Space.xs),
                          Flexible(
                            child: ExcludeSemantics(
                              child: Text(
                                info.staleAt!,
                                key: const ValueKey('hero-stale-at'),
                                style: TypeScale.subhead.copyWith(
                                  color: Palette.stale,
                                  fontWeight: FontWeight.w600,
                                  fontFeatures: TypeScale.tabular,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                  : null;
              final condition = Text(
                info.condition ?? '',
                textAlign: textAlign,
                style: TypeScale.condition.copyWith(
                  height: 1.4,
                  fontWeight: FontWeight.w500,
                  color: Palette.white,
                ),
              );
              final temperatureMeasure = TextPainter(
                text: TextSpan(
                  text: info.temperature,
                  style: temperatureStyle.copyWith(
                    fontFamily: DefaultTextStyle.of(context).style.fontFamily,
                  ),
                ),
                textScaler: scaler,
                textDirection: Directionality.of(context),
              )..layout();
              // Only share a line when both readings retain their full size.
              final inline =
                  compact &&
                  info.temperature != null &&
                  info.condition != null &&
                  MediaQuery.textScalerOf(context).scale(20) <= 26 &&
                  temperatureMeasure.width +
                          Space.m +
                          MediaQuery.textScalerOf(context).scale(96) <=
                      box.maxWidth;
              temperatureMeasure.dispose();
              return Column(
                crossAxisAlignment: alignment,
                children: [
                  Text(
                    info.detail,
                    textAlign: textAlign,
                    style: TypeScale.footnote.copyWith(
                      height: 1.4,
                      color: Palette.secondary,
                    ),
                  ),
                  if (info.temperature != null) ...[
                    SizedBox(height: compact ? Space.xs : Space.s),
                    if (inline)
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          temperature,
                          const SizedBox(width: Space.m),
                          Flexible(child: condition),
                        ],
                      )
                    else
                      temperature,
                    ?staleAt,
                  ],
                  if (info.condition != null && !inline) condition,
                  if (info.highLow != null) ...[
                    const SizedBox(height: Space.xs),
                    Text(
                      info.highLow!,
                      textAlign: textAlign,
                      style: TypeScale.subhead.copyWith(
                        height: 1.5,
                        fontFeatures: TypeScale.tabular,
                        color: Palette.white,
                      ),
                    ),
                  ],
                  if (info.temperature != null) ...[
                    SizedBox(height: compact ? Space.s : Space.l),
                    Text(
                      info.today ?? 'Chưa có dự báo theo giờ',
                      textAlign: textAlign,
                      style: TypeScale.callout.copyWith(
                        height: 1.45,
                        fontWeight: FontWeight.w500,
                        color: Palette.white,
                      ),
                    ),
                    CupertinoButton(
                      onPressed: onTrip,
                      padding: const EdgeInsets.symmetric(
                        horizontal: Space.m,
                        vertical: Space.s,
                      ),
                      minimumSize: const Size(48, 48),
                      pressedOpacity: MediaQuery.disableAnimationsOf(context)
                          ? 1
                          : Opacities.pressed,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              'Lên kế hoạch ra ngoài',
                              textAlign: textAlign,
                              style: TypeScale.subhead.copyWith(
                                color: Palette.rain,
                                fontWeight: FontWeight.w600,
                                height: 1.4,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          const Icon(
                            CupertinoIcons.chevron_right,
                            size: 14,
                            color: Palette.rain,
                          ),
                        ],
                      ),
                    ),
                  ],
                  if (info.updated != null ||
                      info.sourceLabel != null ||
                      info.isStale ||
                      info.cachedNote != null ||
                      info.refreshing) ...[
                    SizedBox(height: compact ? Space.xs : Space.s),
                    Semantics(
                      liveRegion: info.isStale,
                      child: Column(
                        crossAxisAlignment: alignment,
                        children: [
                          if (info.isStale)
                            Text(
                              'Dữ liệu cũ',
                              style: TypeScale.footnote.copyWith(
                                color: Palette.stale,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          if (info.updated != null || info.sourceLabel != null)
                            Text(
                              [?info.updated, ?info.sourceLabel].join(' · '),
                              textAlign: textAlign,
                              style: TypeScale.caption1.copyWith(
                                color: Palette.secondary,
                                height: 1.5,
                                fontFeatures: TypeScale.tabular,
                              ),
                            ),
                          if (info.cachedNote != null)
                            Text(
                              info.cachedNote!,
                              textAlign: textAlign,
                              style: TypeScale.footnote.copyWith(
                                color: Palette.secondary,
                              ),
                            ),
                          if (info.refreshing)
                            Text(
                              'Đang cập nhật...',
                              style: TypeScale.footnote.copyWith(
                                color: Palette.secondary,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
