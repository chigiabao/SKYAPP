/// O "Chất lượng không khí" (US AQI, thang EPA 0-500).
library;

import 'package:flutter/material.dart';

import '../../../utils/formatters.dart';
import 'metric_tile.dart';

/// Muc AQI theo US EPA (ten tieng Viet).
enum AqiCategory {
  good('Tốt'),
  moderate('Trung bình'),
  sensitive('Kém cho nhóm nhạy cảm'),
  unhealthy('Kém'),
  veryUnhealthy('Rất kém'),
  hazardous('Nguy hại');

  const AqiCategory(this.label);

  final String label;

  /// 0-50 Tốt, 51-100 Trung bình, 101-150 Kém cho nhóm nhạy cảm,
  /// 151-200 Kém, 201-300 Rất kém, > 300 Nguy hại.
  static AqiCategory of(int aqi) {
    if (aqi <= 50) return good;
    if (aqi <= 100) return moderate;
    if (aqi <= 150) return sensitive;
    if (aqi <= 200) return unhealthy;
    if (aqi <= 300) return veryUnhealthy;
    return hazardous;
  }
}

/// Thang AQI hien thi 0..500.
const double kAqiScaleMax = 500;

/// Vi tri vach (0..1) tren thang 0-500.
double aqiMarker(int aqi) => (aqi / kAqiScaleMax).clamp(0.0, 1.0);

/// Mau EPA tai cac moc 0, 50, 100, 150, 200, 300, 500.
const List<Color> kAqiColors = [
  Color(0xFF00E400),
  Color(0xFF00E400),
  Color(0xFFFFFF00),
  Color(0xFFFF7E00),
  Color(0xFFFF0000),
  Color(0xFF8F3F97),
  Color(0xFF7E0023),
];
const List<double> kAqiStops = [0, 0.1, 0.2, 0.3, 0.4, 0.6, 1.0];

class AqiCard extends StatelessWidget {
  const AqiCard({super.key, required this.usAqi, this.pm25, this.sentence});

  final int? usAqi;
  final double? pm25;

  /// Cau giai thich (xem aqiSentence trong weather_insights.dart).
  final String? sentence;

  @override
  Widget build(BuildContext context) {
    final int? aqi = usAqi;
    final AqiCategory? cat = aqi == null ? null : AqiCategory.of(aqi);
    final String? pm = pm25 == null
        ? null
        : 'PM2.5 ${WeatherFormat.decimal1(pm25!)} µg/m³';
    return MetricTile(
      title: 'Chất lượng không khí',
      icon: Icons.air_rounded,
      value: aqi?.toString(),
      label: cat?.label,
      sentence: _sentence(pm),
      semanticsLabel: aqi == null
          ? 'Chất lượng không khí: $kNoData'
          : 'Chất lượng không khí $aqi, mức ${cat!.label}'
                '${_sentence(pm) == null ? '' : '. ${_sentence(pm)}'}',
      footer: 'Thang AQI của Mỹ (US EPA), 0–500.',
      visual: aqi == null
          ? null
          : IndexScaleBar(
              colors: kAqiColors,
              stops: kAqiStops,
              marker: aqiMarker(aqi),
              startLabel: '0',
              endLabel: '500',
            ),
    );
  }

  /// Cau giai thich; luon kem gia tri PM2.5 neu co.
  String? _sentence(String? pm) {
    final s = sentence;
    if (pm == null || (s != null && s.contains('PM2.5'))) return s;
    return s == null ? '$pm.' : '$s $pm.';
  }
}
