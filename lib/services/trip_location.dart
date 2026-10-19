/// Vi tri lien tuc khi dang di (nhom 6), boc sau interface de test bang
/// stream gia.
///
/// Tiet kiem pin: do chinh xac trung binh, chi bao khi di them ~500 m.
/// Chay nen:
///   - iOS: UIBackgroundModes `location` + allowBackgroundLocationUpdates,
///     hien chi bao vi tri (thanh xanh). Quyen "Khi dùng ứng dụng" la du.
///   - Android: foreground service cua geolocator (thong bao co dinh), quyen
///     FOREGROUND_SERVICE_LOCATION; khong can ACCESS_BACKGROUND_LOCATION.
///   - Web: chi khi tab dang mo.
/// Toa do chi dung trong bo nho de tim o luoi / phan tuyen con lai, KHONG luu.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import 'gps_service.dart';

/// Khoang cach toi thieu giua hai lan cap nhat vi tri (m).
const int kTripDistanceFilterM = 500;

abstract class TripLocationSource {
  /// Xin quyen vi tri (khi dung app) neu chua co; tra ve trang thai.
  Future<GpsStatus> ensurePermission();

  /// Stream vi tri; [background] = tiep tuc khi app o nen.
  Stream<LatLng> watch({required bool background});
}

/// Chay nen duoc tren nen tang hien tai (iOS, Android); web thi khong.
bool get tripBackgroundSupported =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.android);

class GeolocatorTripLocation implements TripLocationSource {
  const GeolocatorTripLocation();

  @override
  Future<GpsStatus> ensurePermission() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        return GpsStatus.serviceDisabled;
      }
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      return switch (perm) {
        LocationPermission.always ||
        LocationPermission.whileInUse => GpsStatus.ok,
        LocationPermission.deniedForever => GpsStatus.deniedForever,
        _ => GpsStatus.denied,
      };
    } catch (e) {
      debugPrint('GeolocatorTripLocation: $e');
      return GpsStatus.unavailable;
    }
  }

  @override
  Stream<LatLng> watch({required bool background}) =>
      Geolocator.getPositionStream(
        locationSettings: settingsFor(background: background),
      ).map((p) => LatLng(p.latitude, p.longitude));

  /// Cai dat theo nen tang (tach ra de test).
  static LocationSettings settingsFor({
    required bool background,
    TargetPlatform? platform,
    bool web = kIsWeb,
  }) {
    const accuracy = LocationAccuracy.medium;
    if (web) {
      return const LocationSettings(
        accuracy: accuracy,
        distanceFilter: kTripDistanceFilterM,
      );
    }
    switch (platform ?? defaultTargetPlatform) {
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        return AppleSettings(
          accuracy: accuracy,
          distanceFilter: kTripDistanceFilterM,
          activityType: ActivityType.otherNavigation,
          pauseLocationUpdatesAutomatically: false,
          allowBackgroundLocationUpdates: background,
          showBackgroundLocationIndicator: background,
        );
      case TargetPlatform.android:
        return AndroidSettings(
          accuracy: accuracy,
          distanceFilter: kTripDistanceFilterM,
          intervalDuration: const Duration(seconds: 30),
          foregroundNotificationConfig: background
              ? const ForegroundNotificationConfig(
                  notificationTitle: 'Sky Weather đang theo dõi chuyến đi',
                  notificationText:
                      'Cảnh báo mưa, dông trên đường. Mở ứng dụng để tạm dừng '
                      'hoặc kết thúc.',
                  notificationChannelName: 'Chuyến đi',
                  notificationIcon: AndroidResource(name: 'ic_stat_weather'),
                  setOngoing: true,
                )
              : null,
        );
      default:
        return const LocationSettings(
          accuracy: accuracy,
          distanceFilter: kTripDistanceFilterM,
        );
    }
  }
}
