/// O "Chỉ số UV" (thang WHO 0-11+).
library;

import 'package:flutter/material.dart';

import 'metric_tile.dart';

/// Muc UV theo WHO (lam tron so nguyen truoc khi xep muc).
enum UvCategory {
  low('Thấp'),
  moderate('Trung bình'),
  high('Cao'),
  veryHigh('Rất cao'),
  extreme('Cực cao');

  const UvCategory(this.label);

  final String label;

  /// 0-2 Thấp, 3-5 Trung bình, 6-7 Cao, 8-10 Rất cao, >= 11 Cực cao.
  static UvCategory of(double uv) {
    final int v = uv.round();
    if (v <= 2) return low;
    if (v <= 5) return moderate;
    if (v <= 7) return high;
    if (v <= 10) return veryHigh;
    return extreme;
  }
}

/// Thang UV hien thi 0..11 (11+ dung o cuoi thanh).
const double kUvScaleMax = 11;

/// Vi tri vach (0..1).
double uvMarker(double uv) => (uv / kUvScaleMax).clamp(0.0, 1.0);

const List<Color> kUvColors = [
  Color(0xFF3EA72D),
  Color(0xFF3EA72D),
  Color(0xFFFFF300),
  Color(0xFFF18B00),
  Color(0xFFE53210),
  Color(0xFFB567A4),
];
const List<double> kUvStops = [0, 2.5 / 11, 5.5 / 11, 7.5 / 11, 10.5 / 11, 1];

class UvCard extends StatelessWidget {
  const UvCard({super.key, required this.uvIndex, this.sentence});

  final double? uvIndex;

  /// Cau giai thich (xem uvSentence trong weather_insights.dart).
  final String? sentence;

  @override
  Widget build(BuildContext context) {
    final double? uv = uvIndex;
    final UvCategory? cat = uv == null ? null : UvCategory.of(uv);
    final String? value = uv == null ? null : '${uv.round()}';
    return MetricTile(
      title: 'Chỉ số UV',
      icon: Icons.wb_sunny_outlined,
      value: value,
      label: cat?.label,
      sentence: sentence,
      semanticsLabel: uv == null
          ? 'Chỉ số UV: $kNoData'
          : 'Chỉ số UV $value, mức ${cat!.label}'
                '${sentence == null ? '' : '. $sentence'}',
      visual: uv == null
          ? null
          : IndexScaleBar(
              colors: kUvColors,
              stops: kUvStops,
              marker: uvMarker(uv),
              startLabel: '0',
              endLabel: '11+',
            ),
    );
  }
}
