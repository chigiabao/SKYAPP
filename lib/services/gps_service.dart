/// Lay vi tri GPS (qua giao dien de thay duoc khi test).
///
/// Quyen rieng tu: toa do chi dung MOT lan de hoi may chu dia diem gan nhat;
/// app chi luu id dia diem, khong bao gio luu toa do.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

/// Ket qua lay vi tri.
enum GpsStatus { ok, serviceDisabled, denied, deniedForever, unavailable }

@immutable
class GpsFix {
  const GpsFix(this.status, {this.lat, this.lon, this.detail});

  const GpsFix.at(double this.lat, double this.lon)
    : status = GpsStatus.ok,
      detail = null;

  final GpsStatus status;
  final double? lat;
  final double? lon;

  /// Ly do cu the (de hien cho nguoi dung) khi [GpsStatus.unavailable].
  final String? detail;
}

abstract class GpsService {
  /// Xin quyen (chi khi nguoi dung chu dong cham) roi lay vi tri hien tai.
  Future<GpsFix> locate();

  /// Mo cai dat quyen cua app.
  Future<bool> openAppSettings();

  /// Mo cai dat dinh vi cua he dieu hanh.
  Future<bool> openLocationSettings();
}

/// Cai dat that bang package geolocator.
class GeolocatorGps implements GpsService {
  const GeolocatorGps();

  /// Trinh duyet chi cho Geolocation API o "secure context": https hoac
  /// localhost. Mo app qua `http://<IP LAN>` se bi chan.
  static bool isWebContextAllowed(Uri page) =>
      page.scheme == 'https' ||
      page.host == 'localhost' ||
      page.host == '127.0.0.1' ||
      page.host == '::1';

  @override
  Future<GpsFix> locate() async {
    if (kIsWeb && !isWebContextAllowed(Uri.base)) {
      return const GpsFix(
        GpsStatus.unavailable,
        detail:
            'Trình duyệt chỉ cho dùng vị trí khi mở ứng dụng qua https hoặc '
            'localhost. Hãy mở bằng địa chỉ https hoặc tìm địa điểm theo tên.',
      );
    }
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        return const GpsFix(GpsStatus.serviceDisabled);
      }
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.deniedForever) {
        return const GpsFix(GpsStatus.deniedForever);
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.unableToDetermine) {
        return const GpsFix(GpsStatus.denied);
      }
      final pos = await Geolocator.getCurrentPosition(
        // Do chinh xac cap phuong la du (o du lieu ~8 km).
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 20),
        ),
      );
      return GpsFix.at(pos.latitude, pos.longitude);
    } on PermissionDeniedException {
      return const GpsFix(GpsStatus.denied);
    } on LocationServiceDisabledException {
      return const GpsFix(GpsStatus.serviceDisabled);
    } on PermissionDefinitionsNotFoundException catch (e) {
      // Thieu quyen vi tri trong AndroidManifest (loi cau hinh ban build).
      debugPrint('GeolocatorGps: $e');
      return const GpsFix(
        GpsStatus.unavailable,
        detail:
            'Bản cài đặt này thiếu khai báo quyền vị trí nên không thể dùng '
            'GPS. Hãy tìm địa điểm theo tên.',
      );
    } on TimeoutException catch (e) {
      debugPrint('GeolocatorGps: $e');
      return const GpsFix(
        GpsStatus.unavailable,
        detail:
            'Không nhận được tín hiệu vị trí sau 20 giây. Hãy ra nơi thoáng '
            'hoặc bật Wi-Fi rồi thử lại.',
      );
    } catch (e) {
      debugPrint('GeolocatorGps: $e');
      return GpsFix(
        GpsStatus.unavailable,
        detail: 'Không lấy được vị trí hiện tại ($e). Vui lòng thử lại.',
      );
    }
  }

  @override
  Future<bool> openAppSettings() async {
    try {
      return await Geolocator.openAppSettings();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> openLocationSettings() async {
    try {
      return await Geolocator.openLocationSettings();
    } catch (_) {
      return false;
    }
  }
}
