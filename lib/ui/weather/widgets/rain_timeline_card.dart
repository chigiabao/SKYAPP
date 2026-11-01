/// The "dòng thời gian mưa" o Home: thanh ngang 24 gio to theo xac suat mua
/// (gio dong mau canh bao), moc gio, tieu de canh bao (neu co). Cham the ->
/// man Canh bao (cau mien tru nam o do).
library;

import 'package:flutter/cupertino.dart';
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
    this.alertDetail,
    this.thunder = false,
    this.icon,
    this.accent,
    this.onOpen,
    this.onDismiss,
  });

  final List<RainSlot> slots;

  /// "Cảnh báo · Dông · 16:00–18:00" hoac "Mưa 24 giờ tới".
  final String title;

  /// The alert's own metric and timing, separate from the rain timeline.
  final String? alertDetail;
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
    final compact = MediaQuery.sizeOf(context).height <= 700;
    final Color color = accent ?? ink.rain;
    final ordered = [...slots]..sort((a, b) => a.time.compareTo(b.time));
    final timeline = <RainSlot>[];
    for (final slot in ordered) {
      if (timeline.isNotEmpty) {
        var missing = timeline.last.time.add(const Duration(hours: 1));
        while (missing.isBefore(slot.time)) {
          timeline.add((time: missing, p: null, mm: null, thunder: false));
          missing = missing.add(const Duration(hours: 1));
        }
      }
      timeline.add(slot);
    }
    final probabilities = timeline.map((s) => s.p).nonNulls.toList();
    final amounts = timeline.map((s) => s.mm).nonNulls.toList();
    final peak = probabilities.fold<double>(0, (a, b) => a > b ? a : b);
    final total = amounts.fold<double>(0, (a, b) => a + b);
    final String detail = timeline.isEmpty
        ? 'Chưa có dữ liệu mưa theo giờ.'
        : [
            if (probabilities.isEmpty)
              'Chưa có xác suất mưa'
            else
              'Xác suất mưa tới ${(peak * 100).round()}%'
                  '${probabilities.length == timeline.length ? '' : ' (dữ liệu chưa đủ)'}',
            if (amounts.isEmpty)
              'Chưa có lượng mưa'
            else if (amounts.length < timeline.length)
              'đã có ${total.toStringAsFixed(1).replaceAll('.', ',')} mm'
                  ' (${amounts.length}/${timeline.length} giờ)',
            if (amounts.length == timeline.length)
              'tổng ${total.toStringAsFixed(1).replaceAll('.', ',')} mm',
            '${_time(timeline.first.time)}–'
                '${_time(timeline.last.time.add(const Duration(hours: 1)))}',
          ].join(' · ');

    final body = Padding(
      padding: EdgeInsets.fromLTRB(
        Space.l,
        compact ? Space.s : Space.m,
        0,
        compact ? Space.s : Space.m,
      ),
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
                    CupertinoIcons.chevron_forward,
                    color: Palette.white,
                  ),
                ),
              if (onDismiss == null) const SizedBox(width: Space.m),
            ],
          ),
          const SizedBox(height: Space.s),
          if (alertDetail != null) ...[
            Padding(
              padding: EdgeInsets.only(right: onDismiss == null ? Space.l : 0),
              child: Text(
                alertDetail!,
                style: TypeScale.body.copyWith(color: ink.secondary),
              ),
            ),
            const SizedBox(height: Space.m),
            Text(
              'Dữ liệu mưa theo giờ',
              style: TypeScale.label.copyWith(color: Palette.white),
            ),
            const SizedBox(height: Space.s),
          ],
          if (slots.isNotEmpty) ...[
            Padding(
              padding: EdgeInsets.only(right: onDismiss == null ? Space.l : 0),
              child: _Bar(
                slots: timeline,
                rain: ink.rain,
                storm: Palette.alert,
              ),
            ),
            const SizedBox(height: Space.xs),
          ],
          Padding(
            padding: EdgeInsets.only(right: onDismiss == null ? Space.l : 0),
            child: Text(
              detail,
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
                            '$title. ${alertDetail == null ? '' : '$alertDetail. '}'
                            '$detail. ${_spoken(timeline)}Mở màn Cảnh báo',
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
                          CupertinoIcons.xmark,
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

  static String _time(DateTime time) =>
      '${time.hour.toString().padLeft(2, '0')}:00 ${time.day}/${time.month}';

  /// Missing hours must break spoken rain intervals.
  static String _spoken(List<RainSlot> s) {
    final text = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if ((s[i].p ?? 0) < 0.5) continue;
      final start = s[i].time;
      while (i + 1 < s.length &&
          (s[i + 1].p ?? 0) >= 0.5 &&
          s[i + 1].time.difference(s[i].time) == const Duration(hours: 1)) {
        i++;
      }
      text.write(
        'Khả năng mưa cao từ ${_time(start)} đến '
        '${_time(s[i].time.add(const Duration(hours: 1)))}. ',
      );
    }
    return text.toString();
  }
}

/// Thanh 24 cot + moc gio (moi 6 gio, 12 gio khi chu lon).
///
/// Mau = xac suat mua theo bac ro rang (<20% gan nhu trong suot -> >=80%
/// xanh dam nhat); chieu cao cot = luong mua (mm), toi thieu 40%.
class _Bar extends StatelessWidget {
  const _Bar({required this.slots, required this.rain, required this.storm});

  final List<RainSlot> slots;
  final Color rain;
  final Color storm;

  static const double _height = 28;
  static const double _gap = 2;

  /// Bac mau xanh mua theo xac suat (tren kinh toi: bac >=40% dat >= 3:1).
  static Color colorFor(double? p) {
    if (p == null) return Colors.transparent;
    if (p >= 0.8) return const Color(0xFF7CC8FF);
    if (p >= 0.6) return const Color(0xFF3D9BF0);
    if (p >= 0.4) return const Color(0xFF2E78C7);
    if (p >= 0.2) return const Color(0x995B8FC4);
    return const Color(0x29FFFFFF);
  }

  static double _fraction(RainSlot s) {
    final mm = s.mm;
    if (mm == null) return (s.p ?? 0) >= 0.2 ? 1 : 0.4;
    return 0.4 + 0.6 * (mm / 5).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final ink = GlassInk.of(context);
    final labelStyle = TypeScale.small.copyWith(
      color: ink.secondary,
      fontFeatures: kTabular,
    );
    final n = slots.length;
    final stride = MediaQuery.textScalerOf(context).scale(12) > 18 ? 12 : 6;
    return ExcludeSemantics(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: MediaQuery.sizeOf(context).height <= 700 ? 20 : _height,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < n; i++) ...[
                  if (i > 0) const SizedBox(width: _gap),
                  Expanded(
                    child: FractionallySizedBox(
                      alignment: Alignment.bottomCenter,
                      heightFactor: slots[i].thunder ? 1 : _fraction(slots[i]),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: slots[i].thunder
                              ? storm
                              : colorFor(slots[i].p),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: Space.xs),
          // Fewer ticks at large text; labels wrap instead of shrinking.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < n; i += stride)
                Expanded(
                  flex: n - i < stride ? n - i : stride,
                  child: Text('${slots[i].time.hour}h', style: labelStyle),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
