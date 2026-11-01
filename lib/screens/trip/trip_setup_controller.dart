/// Trang thai + luong bat dong bo cua man "Chuyến đi" truoc khi chay: chon
/// diem di / den, phuong tien, gio di, tim kiem, GPS, lap tuyen, bat dau.
/// Man hinh chi ve UI va hop thoai; [TripProvider] giu tuyen / chuyen di.
library;

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

import '../../models/place.dart';
import '../../providers/location_provider.dart';
import '../../providers/trip_provider.dart';
import '../../services/gps_service.dart';
import '../../services/route_service.dart';

class TripSetupController extends ChangeNotifier {
  TripSetupController({
    required this.gps,
    this._withRoute = true,
    this.replayAt,
  });

  final GpsService gps;

  /// Thoi diem xem lai cua app (null / tra ve null = truc tiep).
  final DateTime? Function()? replayAt;

  bool _withRoute;
  Place? _from; // null = GPS
  Place? _to;
  TripProfile _profile = TripProfile.driving; // xe may
  DateTime? _departAt; // null = bay gio
  bool _background = false;
  List<Place> _results = const [];
  bool _searching = false;
  String? _message;
  GpsStatus? _gpsIssue;
  bool _disposed = false;
  int _inputsRevision = 0;

  bool get withRoute => _withRoute;

  /// null = vi tri hien tai (GPS).
  Place? get from => _from;
  Place? get to => _to;
  TripProfile get profile => _profile;

  /// null = khoi hanh bay gio.
  DateTime? get departAt => _departAt;

  /// "Tiếp tục khi tắt màn hình".
  bool get background => _background;
  List<Place> get results => _results;
  bool get searching => _searching;
  String? get message => _message;

  /// Loi quyen / dinh vi tat -> hien nut "Mở cài đặt" (Android + iOS).
  GpsStatus? get gpsIssue => _gpsIssue;

  /// Bat dau duoc: khong tuyen, hoac da co tuyen.
  bool canStart(TripProvider trip) => !_withRoute || trip.plan != null;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// Mua 2 gio toi tai vi tri GPS hien tai ([at] = thoi diem xem lai).
  Future<void> loadNowcast(TripProvider trip, {DateTime? at}) async {
    if (_disposed || trip.nowcastLoading) return;
    final fix = await gps.locate();
    if (_disposed) return;
    if (fix.status != GpsStatus.ok) {
      _gpsIssue = fix.status;
      _changed();
      trip.setNowcastError(
        fix.detail ?? 'Không lấy được vị trí hiện tại để xem mưa.',
      );
      return;
    }
    await trip.loadNowcast(fix.lat!, fix.lon!, at: at ?? replayAt?.call());
  }

  void setWithRoute(bool v, TripProvider trip) {
    if (v != _withRoute) _invalidatePlan(trip);
    _withRoute = v;
    _changed();
    if (!v && trip.nowcastPlace == null && !trip.nowcastLoading) {
      loadNowcast(trip);
    }
  }

  Future<void> runSearch(LocationProvider lp, String q) async {
    _searching = true;
    _changed();
    final r = await lp.searchRemote(q) ?? lp.search(q);
    if (_disposed) return;
    _results = r.take(8).toList();
    _searching = false;
    _changed();
  }

  void _invalidatePlan(TripProvider trip) {
    _inputsRevision++;
    trip.clearPlan();
  }

  void setFrom(Place? p, TripProvider trip) {
    _invalidatePlan(trip);
    _from = p;
    _changed();
  }

  /// Chon diem den (tu ket qua tim hoac dia diem da luu).
  void pickDestination(Place p, TripProvider trip) {
    _invalidatePlan(trip);
    _to = p;
    _results = const [];
    _changed();
  }

  /// "Đổi điểm đến": bo tuyen cu.
  void clearDestination(TripProvider trip) {
    _invalidatePlan(trip);
    _to = null;
    _changed();
  }

  void setProfile(TripProfile p, TripProvider trip) {
    _invalidatePlan(trip);
    _profile = p;
    _changed();
  }

  void setBackground(bool v) {
    _background = v;
    _changed();
  }

  void setDepartAt(DateTime? at, TripProvider trip) {
    _invalidatePlan(trip);
    _departAt = at;
    _changed();
  }

  /// Gio [hour]:[minute] gan nhat khong truoc [now] (qua ngay neu da qua).
  static DateTime nextDeparture(DateTime now, int hour, int minute) {
    final at = DateTime.utc(now.year, now.month, now.day, hour, minute);
    return at.isBefore(now) ? at.add(const Duration(days: 1)) : at;
  }

  /// Lap tuyen tu diem di (hoac GPS) toi diem den roi so sanh gio di.
  Future<void> plan(TripProvider trip) async {
    final to = _to;
    if (to == null) return;
    final revision = _inputsRevision;
    _message = null;
    _gpsIssue = null;
    _changed();
    LatLng from;
    if (_from != null) {
      from = LatLng(_from!.lat, _from!.lon);
    } else {
      final fix = await gps.locate();
      if (_disposed || revision != _inputsRevision) return;
      if (fix.status != GpsStatus.ok) {
        _gpsIssue = fix.status;
        _message =
            fix.detail ??
            'Không lấy được vị trí hiện tại. Hãy chọn điểm đi là một địa '
                'điểm.';
        _changed();
        return;
      }
      from = LatLng(fix.lat!, fix.lon!);
    }
    final r = await trip.planRoute(
      from: from,
      to: LatLng(to.lat, to.lon),
      departAt: _departAt ?? trip.nowHcm,
      profile: _profile,
      fromLabel: _from == null
          ? 'Vị trí hiện tại (GPS)'
          : 'Điểm đi · ${_from!.name}',
      toLabel: to.name,
    );
    if (!_disposed && revision == _inputsRevision && r != null) {
      await trip.compareDepartures();
    }
  }

  /// Bat dau chuyen di. [confirmBackground] giai thich truoc khi he thong hoi
  /// quyen vi tri nen; chi goi khi bat nen va nen duoc ho tro.
  Future<void> start(
    TripProvider trip, {
    required bool backgroundSupported,
    required Future<bool?> Function() confirmBackground,
  }) async {
    if (_background && backgroundSupported) {
      final ok = await confirmBackground();
      if (ok != true || _disposed) return;
    }
    final st = await trip.start(
      route: _withRoute ? trip.plan : null,
      fromId: _withRoute ? _from?.id : null,
      toId: _withRoute ? _to?.id : null,
      background: _background,
    );
    if (st != GpsStatus.ok && !_disposed) {
      _gpsIssue = st;
      _message = trip.error;
      _changed();
    }
  }
}
