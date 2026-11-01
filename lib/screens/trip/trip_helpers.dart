import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import '../../services/route_service.dart';
import '../../ui/weather/design_tokens.dart';

/// Mau tung muc nguy hiem tren tuyen.
Color hazardColor(RouteHazard h) => switch (h) {
  RouteHazard.lowRain => DataColors.hazardLowRain,
  RouteHazard.unknown => DataColors.hazardUnknown,
  RouteHazard.none => DataColors.hazardNone,
  RouteHazard.rain => DataColors.hazardRain,
  RouteHazard.heavy => DataColors.hazardHeavy,
  RouteHazard.storm => DataColors.hazardStorm,
};

/// Cac doan tuyen to mau theo diem mau gan nhat (dung chung cho ban do).
List<Polyline> routeWeatherPolylines(TripRoute r, {double width = 6}) {
  final g = r.geometry;
  if (g.length < 2) return const [];
  if (r.samples.isEmpty) {
    return [
      Polyline(
        points: g,
        color: hazardColor(RouteHazard.unknown),
        strokeWidth: width,
      ),
    ];
  }
  final idx = [for (final s in r.samples) nearestIndex(g, s.point)];
  final out = <Polyline>[];
  for (var i = 0; i < r.samples.length; i++) {
    final a = i == 0 ? 0 : idx[i];
    final b = i == r.samples.length - 1 ? g.length - 1 : idx[i + 1];
    if (b <= a) continue;
    out.add(
      Polyline(
        points: g.sublist(a, b + 1),
        color: hazardColor(r.samples[i].hazard),
        strokeWidth: width,
        borderColor: DataColors.routeCasing,
        borderStrokeWidth: 1.5,
      ),
    );
  }
  return out;
}

String formatHhmm(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

String durationText(double min) {
  final m = min.round();
  return m < 60 ? '$m phút' : '${m ~/ 60} giờ ${m % 60} phút';
}

String routeWeatherSummary(TripRoute route) {
  final worst = route.worstAlert;
  if (worst != null) {
    return 'Đoạn xấu nhất: ${worst.alertReason ?? worst.hazard.label}'
        ', lúc ${formatHhmm(worst.eta)}.';
  }
  if (route.availableSampleCount == 0) {
    return 'Chưa có dự báo thời tiết dọc tuyến; chưa thể đánh giá nguy cơ.';
  }
  if (route.hasOwnModelForecasts) {
    final available = route.samples.where((s) => s.forecastAvailable);
    final probabilities = available
        .where((s) => s.hasValidRainProbability)
        .map((s) => s.rainProbability!)
        .toList();
    final amounts = available
        .where((s) => s.hasValidRainAmount)
        .map((s) => s.precipitation!)
        .toList();
    if (probabilities.isEmpty && amounts.isEmpty) {
      return 'Chưa đủ chỉ số mưa dọc tuyến.';
    }
    final probability = probabilities.isEmpty
        ? null
        : probabilities.reduce((a, b) => a > b ? a : b);
    final amount = amounts.isEmpty
        ? null
        : amounts.reduce((a, b) => a > b ? a : b);
    final complete = available.where((s) => s.rainAssessmentComplete).length;
    final partial = route.hasCompleteRainCoverage
        ? ''
        : 'Đủ chỉ số mưa $complete/${route.samples.length} điểm. ';
    final chance = probability == null
        ? 'chưa rõ xác suất'
        : 'cao nhất ${(probability * 100).round()}%';
    final intensity = amount == null
        ? 'chưa rõ lượng mưa'
        : 'cao nhất ${amount.toStringAsFixed(1)} mm/giờ';
    return '${partial}Mưa dọc tuyến: $chance · $intensity.';
  }
  if (!route.hasCompleteForecastCoverage) {
    return 'Dự báo dọc tuyến chưa đầy đủ; chưa thể đánh giá toàn tuyến.';
  }
  if (!route.hasCompleteHazardCoverage) {
    return 'Chưa đủ dữ liệu để đánh giá mọi nguy cơ trên tuyến.';
  }
  return 'Chưa ghi nhận ngưỡng cảnh báo trong dữ liệu hiện có.';
}

String? routeCoverageNote(TripRoute route) {
  if (route.hasOwnModelForecasts) {
    return 'AI chưa đủ cơ sở loại trừ dông và gió giật nguy hiểm. '
        'Không thể kết luận tuyến an toàn.';
  }
  if (!route.hasCompleteHazardCoverage) {
    return 'Thiếu dữ liệu tại một số điểm hoặc thiếu chỉ số nguy cơ. '
        'Không có cảnh báo không đồng nghĩa tuyến an toàn.';
  }
  return null;
}
