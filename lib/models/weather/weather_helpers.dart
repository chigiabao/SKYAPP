import '../hcm_time.dart';

// --- JSON helpers (cac truong tu backend co the null) ---

double? toDouble(dynamic v) => v is num ? v.toDouble() : null;

int? toInt(dynamic v) => v is num ? v.round() : null;

double requireDouble(Map<String, dynamic> json, String key) {
  final v = toDouble(json[key]);
  if (v == null) {
    throw FormatException('Thiếu trường bắt buộc "$key"');
  }
  return v;
}

/// Xac suat 0-1: uu tien [probKey] (0-1), neu khong co thi [percentKey] / 100.
double? probability(
  Map<String, dynamic> json,
  String probKey,
  String percentKey,
) {
  final p = toDouble(json[probKey]);
  if (p != null) return p.clamp(0.0, 1.0).toDouble();
  final percent = toDouble(json[percentKey]);
  if (percent != null) return (percent / 100).clamp(0.0, 1.0).toDouble();
  return null;
}

int? toPercent(double? prob) =>
    prob == null ? null : (prob * 100).round().clamp(0, 100);

/// Timestamp -> gio dong ho TP.HCM (xem [HcmTime]).
DateTime requireDate(Map<String, dynamic> json, String key) {
  final v = json[key];
  final parsed = v is String ? HcmTime.tryParse(v) : null;
  if (parsed == null) {
    throw FormatException('Trường "$key" không hợp lệ: $v');
  }
  return parsed;
}
