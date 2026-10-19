/// The "dòng thời gian mưa" o Home: thanh ngang 24 gio to theo xac suat mua
/// (gio dong mau canh bao), moc gio, tieu de canh bao (neu co). Cham the ->
/// man Canh bao (cau mien tru nam o do).
library;

import 'package:flutter/material.dart';

import '../design_tokens.dart';
import '../glass_ink.dart';
import '../weather_insights.dart';
import 'glass_card.dart';

class RainTimelineCard extends StatelessWidget {
  const RainTimelineCard({
    super.key,
    required this.slots,
    required this.title,
    this.thunder = false,
    this.icon,
    this.accent,
    this.onOpen,
    this.onDismiss,
  });

  final List<RainSlot> slots;

  /// "Cảnh báo · Dông · 16:00–18:00" hoac "Mưa 24 giờ tới".
  final String title;
  final bool thunder;

  /// Icon tieu de (vd. loai canh bao); null = dong / o theo [thunder].
  final IconData? icon;

  /// Mau vach trai + icon (muc canh bao); null = mau mua.
  final Color? accent;
  final VoidCallback? onOpen;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final ink = GlassInk.of(context);
    final Color color = accent ?? ink.rain;
    var peak = 0.0;
    double total = 0;
    for (final s in slots) {
      if (s.p > peak) peak = s.p;
      total += s.mm ?? 0;
    }
    final String detail = [
      'Tới ${(peak * 100).round()}%',
      if (total >= 0.1)
        'tổng ${total.toStringAsFixed(1).replaceAll('.', ',')} mm',
      '${slots.length} giờ tới',
    ].join(' · ');

    final body = Padding(
      padding: const EdgeInsets.fromLTRB(Space.l, Space.m, 0, Space.m),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              ExcludeSemantics(
                child: Icon(
                  icon ??
                      (thunder
                          ? Icons.thunderstorm_outlined
                          : Icons.umbrella_outlined),
                  color: color,
                  size: IconSizes.md,
                ),
              ),
              const SizedBox(width: Space.s),
              Expanded(
                child: Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TypeScale.label.copyWith(
                    fontWeight: FontWeight.w600,
                    color: Palette.white,
                    fontFeatures: kTabular,
                  ),
                ),
              ),
              if (onOpen != null)
                const ExcludeSemantics(
                  child: Icon(
                    Icons.chevron_right_rounded,
                    color: Palette.white,
                  ),
                ),
              if (onDismiss == null) const SizedBox(width: Space.m),
            ],
          ),
          const SizedBox(height: Space.s),
          Padding(
            padding: EdgeInsets.only(right: onDismiss == null ? Space.l : 0),
            child: _Bar(slots: slots, rain: ink.rain, storm: Palette.alert),
          ),
          const SizedBox(height: Space.xs),
          Padding(
            padding: EdgeInsets.only(right: onDismiss == null ? Space.l : 0),
            child: Text(
              detail,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TypeScale.small.copyWith(
                color: ink.secondary,
                fontFeatures: kTabular,
              ),
            ),
          ),
        ],
      ),
    );

    return Semantics(
      container: true,
      liveRegion: true,
      child: GlassSurface(
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: 3, child: ColoredBox(color: color)),
              Expanded(
                child: onOpen == null
                    ? body
                    : Pressable(
                        onTap: onOpen,
                        semanticsLabel:
                            '$title. $detail. ${_spoken(slots)}Mở màn Cảnh báo',
                        child: body,
                      ),
              ),
              if (onDismiss != null)
                Align(
                  alignment: Alignment.topCenter,
                  child: Tooltip(
                    message: 'Đóng cảnh báo',
                    excludeFromSemantics: true,
                    child: Pressable(
                      onTap: onDismiss,
                      semanticsLabel: 'Đóng cảnh báo',
                      child: const SizedBox.square(
                        dimension: Touch.min,
                        child: Icon(
                          Icons.close_rounded,
                          color: Palette.white,
                          size: IconSizes.md,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// "Mưa từ 16h đến 19h. " cho trinh doc man hinh.
  static String _spoken(List<RainSlot> s) {
    final i = s.indexWhere((x) => x.p >= 0.5);
    if (i < 0) return '';
    var j = i;
    while (j + 1 < s.length && s[j + 1].p >= 0.5) {
      j++;
    }
    return 'Mưa từ ${s[i].time.hour} giờ đến ${(s[j].time.hour + 1) % 24} giờ. ';
  }
}

/// Thanh 24 o + moc gio (moi 6 gio).
class _Bar extends StatelessWidget {
  const _Bar({required this.slots, required this.rain, required this.storm});

  final List<RainSlot> slots;
  final Color rain;
  final Color storm;

  @override
  Widget build(BuildContext context) {
    final ink = GlassInk.of(context);
    final labelStyle = TypeScale.small.copyWith(
      fontSize: 12,
      color: ink.secondary,
      fontFeatures: kTabular,
    );
    final n = slots.length;
    return ExcludeSemantics(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 20,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < n; i++)
                    Expanded(
                      child: Padding(
                        padding: EdgeInsets.only(right: i == n - 1 ? 0 : 1.5),
                        child: ColoredBox(
                          color: Color.alphaBlend(
                            (slots[i].thunder ? storm : rain).withValues(
                              alpha: slots[i].thunder
                                  ? 0.95
                                  : 0.12 + 0.88 * slots[i].p,
                            ),
                            Palette.track,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: Space.xs),
          // Moc gio moi 6 o (Bay gio, +6, +12, +18), canh trai theo o.
          Row(
            children: [
              for (var i = 0; i < n; i += 6)
                Expanded(
                  flex: n - i < 6 ? n - i : 6,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        i == 0 ? 'Bây giờ' : '${slots[i].time.hour}h',
                        maxLines: 1,
                        style: labelStyle,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
