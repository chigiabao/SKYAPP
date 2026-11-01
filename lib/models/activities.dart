/// Hoat dong ngoai troi va cham diem tung gio (thuan Dart).
///
/// Moi hoat dong co "ho so" (nhiet do de chiu, muc so mua / UV / gio / AQI,
/// khung gio hop ly trong ngay). [scoreHour] cho 0-100 kem ly do;
/// [bestWindows] tim khung gio lien tiep tot nhat trong 24-48 gio toi.
library;

import 'dart:math' as math;

import '../utils/forecast_format.dart';
import 'units.dart';
import 'weather.dart';
import 'weather_alerts.dart' show feelsLikeOf, isThunderstormCode;

part 'activities/activity_score.dart';
part 'activities/activity_routine.dart';
part 'activities/commute_settings.dart';

/// Muc nhay cam voi thoi tiet (nhan he so phat).
enum Sensitivity {
  low('Ít', 0.7),
  normal('Vừa', 1.0),
  high('Nhiều', 1.4);

  const Sensitivity(this.label, this.factor);
  final String label;
  final double factor;
}

/// Ho so mot hoat dong.
class ActivityProfile {
  const ActivityProfile({
    required this.tempLo,
    required this.tempHi,
    required this.rainWeight,
    required this.uvMax,
    required this.gustMax,
    required this.aqiWeight,
    required this.hours,
    this.durationHours = 1,
    this.preferSun = false,
    this.goldenHours = const [],
  });

  /// Khoang nhiet do cam giac de chiu, °C.
  final double tempLo;
  final double tempHi;

  /// Diem tru toi da khi chac chan mua (xac suat 100 %).
  final double rainWeight;

  /// UV toi da khong bi tru diem.
  final double uvMax;

  /// Gio giat toi da khong bi tru diem, km/h.
  final double gustMax;

  /// He so tru diem theo AQI (0 = khong quan tam).
  final double aqiWeight;

  /// Gio trong ngay cho phep (gio bat dau, 0-23).
  final Set<int> hours;

  /// Do dai khung goi y, gio.
  final int durationHours;

  /// Can nang (phoi do): duoc cong diem khi UV vua phai.
  final bool preferSun;

  /// Gio "vang" duoc cong diem (chup anh).
  final List<int> goldenHours;
}

/// Danh sach hoat dong (de bai muc 4: di lam / di hoc, tap the duc, hoat
/// dong ngoai troi).
enum Activity {
  running(
    'Chạy bộ',
    ActivityProfile(
      tempLo: 20,
      tempHi: 30,
      rainWeight: 60,
      uvMax: 5,
      gustMax: 35,
      aqiWeight: 1,
      hours: {5, 6, 7, 8, 9, 16, 17, 18, 19, 20},
    ),
  ),
  cycling(
    'Đạp xe',
    ActivityProfile(
      tempLo: 20,
      tempHi: 31,
      rainWeight: 70,
      uvMax: 5,
      gustMax: 30,
      aqiWeight: 0.8,
      hours: {5, 6, 7, 8, 9, 16, 17, 18, 19},
      durationHours: 2,
    ),
  ),
  commute(
    'Đi làm / đi học',
    ActivityProfile(
      tempLo: 20,
      tempHi: 34,
      rainWeight: 70,
      uvMax: 8,
      gustMax: 45,
      aqiWeight: 0.4,
      hours: {6, 7, 8, 9, 16, 17, 18, 19},
    ),
  ),
  laundry(
    'Giặt phơi đồ',
    ActivityProfile(
      tempLo: 24,
      tempHi: 40,
      rainWeight: 100,
      uvMax: 12,
      gustMax: 50,
      aqiWeight: 0,
      hours: {7, 8, 9, 10, 11, 12, 13, 14},
      durationHours: 3,
      preferSun: true,
    ),
  ),
  outing(
    'Đi chơi',
    ActivityProfile(
      tempLo: 22,
      tempHi: 32,
      rainWeight: 60,
      uvMax: 6,
      gustMax: 40,
      aqiWeight: 0.6,
      hours: {7, 8, 9, 10, 15, 16, 17, 18, 19, 20, 21},
      durationHours: 3,
    ),
  ),
  photography(
    'Chụp ảnh',
    ActivityProfile(
      tempLo: 20,
      tempHi: 34,
      rainWeight: 80,
      uvMax: 9,
      gustMax: 40,
      aqiWeight: 0.5,
      hours: {5, 6, 7, 8, 15, 16, 17},
      goldenHours: [5, 6, 16, 17],
    ),
  ),
  watering(
    'Tưới cây',
    ActivityProfile(
      tempLo: 18,
      tempHi: 34,
      rainWeight: 50,
      uvMax: 4,
      gustMax: 40,
      aqiWeight: 0,
      hours: {5, 6, 7, 8, 16, 17, 18},
    ),
  );

  const Activity(this.label, this.profile);
  final String label;
  final ActivityProfile profile;
}

/// Mac dinh khi nguoi dung chua chon.
/// Di lam / di hoc dung dau: nguoi dung TP.HCM di xe may can biet mua luc
/// di / ve nhat.
const List<Activity> kDefaultFavorites = [
  Activity.commute,
  Activity.running,
  Activity.laundry,
  Activity.outing,
];

/// Diem mot gio.
