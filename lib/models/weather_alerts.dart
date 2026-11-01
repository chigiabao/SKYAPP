/// Bo luat canh bao chay tren thiet bi (thuan Dart, khong goi mang).
///
/// Dau vao: du lieu theo gio cua mot dia diem + [AlertSettings]. Dau ra:
/// danh sach [AlertEvent] (gom cac gio lien tiep cung loai). Canh bao dua tren
/// du lieu MO HINH, KHONG phai canh bao chinh thuc.
library;

import 'dart:math' as math;

import '../utils/forecast_format.dart';
import '../utils/formatters.dart';
import 'units.dart';
import 'weather.dart';

part 'weather_alerts/alert_settings.dart';
part 'weather_alerts/alert_event.dart';
part 'weather_alerts/alert_notice.dart';

/// Dong mien tru hien o man Canh bao / banner / thong bao.
const String kAlertDisclaimer =
    'Cảnh báo dựa trên dữ liệu mô hình, không phải cảnh báo chính thức – '
    'xem Đài KTTV khu vực Nam Bộ';

/// Whether the alert window contains an hour the alert evaluator can use.
bool hasAlertHours(
  List<HourlyForecast> hours,
  DateTime nowHcm,
  int lookaheadHours,
) {
  final start = HcmTime.startOfHour(nowHcm);
  final end = start.add(Duration(hours: lookaheadHours));
  return hours.any(
    (h) =>
        !h.time.isBefore(start) &&
        h.time.isBefore(end) &&
        h.source != DataSource.climatology,
  );
}

/// Muc do (tang dan).
enum AlertLevel {
  advisory('Lưu ý'),
  warning('Cảnh báo'),
  danger('Nguy hiểm');

  const AlertLevel(this.label);
  final String label;

  bool operator >=(AlertLevel o) => index >= o.index;
  bool operator >(AlertLevel o) => index > o.index;
}

AlertLevel _max(AlertLevel a, AlertLevel b) => a.index >= b.index ? a : b;

/// Cac loai canh bao.
enum AlertType {
  rain('Mưa', '%'),
  heavyRain('Mưa lớn', 'mm/h'),
  thunderstorm('Dông, sét', ''),
  heat('Nắng nóng', '°C'),
  uv('UV cao', ''),
  wind('Gió giật mạnh', 'km/h'),
  aqi('Không khí kém', 'AQI');

  const AlertType(this.label, this.unit);
  final String label;
  final String unit;
}

/// Ngưỡng / bat-tat / gio yen lang. Gia tri mac dinh hop voi TP.HCM.
