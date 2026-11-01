import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/units.dart';

/// Chi so co the hien tren trang chu (thu tu mac dinh = thu tu enum).
enum HomeMetric {
  aqi('Chất lượng không khí (AQI)', Icons.masks_outlined, fullWidth: true),
  feelsLike('Cảm giác như', Icons.thermostat_outlined),
  uv('Chỉ số UV', Icons.wb_sunny_outlined),
  wind('Gió', Icons.air_rounded),
  humidity('Độ ẩm', Icons.water_drop_outlined),
  visibility('Tầm nhìn', Icons.visibility_outlined),
  pressure('Áp suất', Icons.speed_rounded),
  rain('Lượng mưa', Icons.umbrella_outlined),
  cloud('Mây', Icons.cloud_outlined),
  sun('Mặt trời mọc / lặn', Icons.wb_twilight_rounded, fullWidth: true);

  const HomeMetric(this.label, this.icon, {this.fullWidth = false});
  final String label;
  final IconData icon;

  /// Chiem ca hang (khong ghep cap).
  final bool fullWidth;
}

/// Cai dat ca nhan hoa: moi don vi (ke ca °C/°F), chi so trang chu, tro nang.
/// Giao dien Sang/Toi khong con luu (da bo); 'themeMode' cu bi bo qua.
class PreferencesProvider extends ChangeNotifier {
  /// [units]: gia tri ban dau (test). App that goi [load] truoc runApp
  /// (main.dart) de khong nhay giao dien o frame dau.
  PreferencesProvider({UnitPrefs? units}) : _units = units ?? const UnitPrefs();

  static const String prefsKey = 'preferences_v1';

  /// Khoa cu (truoc khi gom vao [prefsKey]): chi doc de chuyen doi.
  static const String legacyCelsiusKey = 'isCelsius';

  /// Cac muc co chu trong app (nhan voi textScaler cua he thong).
  static const List<double> textScaleOptions = [0.9, 1.0, 1.15, 1.3];

  /// Tran tren cua he so chu sau khi nhan (tranh vo bo cuc).
  static const double maxTextScale = 3.0;

  UnitPrefs _units;
  List<HomeMetric> _order = HomeMetric.values;
  Set<HomeMetric> _hidden = const {};
  double _textScale = 1.0;
  bool _highContrast = false;
  bool _reduceMotion = false;
  Future<void>? _loading;

  UnitPrefs get units => _units;

  /// Tat ca chi so theo thu tu nguoi dung (ke ca dang an).
  List<HomeMetric> get metricOrder => List.unmodifiable(_order);

  /// Chi so dang bat, theo thu tu hien thi.
  List<HomeMetric> get visibleMetrics => [
    for (final m in _order)
      if (!_hidden.contains(m)) m,
  ];
  bool isVisible(HomeMetric m) => !_hidden.contains(m);
  double get textScale => _textScale;
  bool get highContrast => _highContrast;
  bool get reduceMotion => _reduceMotion;

  /// Lay provider neu co (test / man hinh don le co the khong co).
  static PreferencesProvider? maybeOf(
    BuildContext context, {
    bool listen = true,
  }) {
    try {
      return Provider.of<PreferencesProvider>(context, listen: listen);
    } on ProviderNotFoundException {
      return null;
    }
  }

  /// Don vi hien thi hien hanh (mac dinh neu khong co provider).
  static UnitPrefs unitsOf(BuildContext context) =>
      maybeOf(context)?.units ?? const UnitPrefs();

  /// Don vi da luu (dung ca trong tac vu nen, khong can provider).
  static UnitPrefs unitsFromPrefs(SharedPreferences? p) {
    if (p == null) return const UnitPrefs();
    try {
      final u = readStored(p).json['units'];
      return UnitPrefs.fromJson(u is Map ? Map<String, dynamic>.from(u) : null);
    } catch (_) {
      return const UnitPrefs();
    }
  }

  /// JSON da luu, bo sung tu khoa cu neu thieu (°C/°F truoc day luu rieng
  /// qua AppSettings); xoa truong 'themeMode' cu (da bo). [migrated]: co
  /// lay tu khoa cu -> nen ghi lai.
  static ({Map<String, dynamic> json, bool migrated}) readStored(
    SharedPreferences p,
  ) {
    var j = <String, dynamic>{};
    final raw = p.getString(prefsKey);
    if (raw != null) {
      try {
        final d = jsonDecode(raw);
        if (d is Map) j = Map<String, dynamic>.from(d);
      } catch (_) {}
    }
    var migrated = false;
    final u = j['units'];
    final units = u is Map ? Map<String, dynamic>.from(u) : <String, dynamic>{};
    if (!units.containsKey('temp')) {
      final c = p.get(legacyCelsiusKey);
      if (c is bool) {
        units['temp'] = (c ? TempUnit.celsius : TempUnit.fahrenheit).name;
        j['units'] = units;
        migrated = true;
      }
    }
    // Ban cu luu che do Sang/Toi (da bo): ghi lai de xoa truong thua.
    if (j.remove('themeMode') != null) migrated = true;
    return (json: j, migrated: migrated);
  }

  // ---- Doc / ghi ----

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final stored = readStored(p);
      if (stored.json.isEmpty) return;
      _apply(stored.json);
      notifyListeners();
      if (stored.migrated) await _save();
    } catch (e) {
      debugPrint('PreferencesProvider.load: $e');
    }
  }

  Future<void> _save() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(prefsKey, jsonEncode(exportSettings()));
    } catch (e) {
      debugPrint('PreferencesProvider.save: $e');
    }
  }

  void _changed() {
    notifyListeners();
    _save();
  }

  /// Ban sao JSON (dong bo tai khoan).
  Map<String, dynamic> exportSettings() => {
    'version': 1,
    'units': _units.toJson(),
    'metricOrder': [for (final m in _order) m.name],
    'hiddenMetrics': [for (final m in _hidden) m.name],
    'textScale': _textScale,
    'highContrast': _highContrast,
    'reduceMotion': _reduceMotion,
  };

  /// Nhap tu JSON (truong sai / thieu -> mac dinh), luu va bao thay doi.
  Future<void> importSettings(Map<String, dynamic> json) async {
    _apply(json);
    notifyListeners();
    await _save();
  }

  void _apply(Map<String, dynamic> j) {
    // Ban cu (truoc khi gom °C/°F vao day) thieu 'temp': giu gia tri hien tai
    // thay vi dat ve mac dinh. 'themeMode' cu (da bo) bi bo qua.
    final u = j['units'];
    final temp = _units.temp;
    _units = UnitPrefs.fromJson(u is Map ? Map<String, dynamic>.from(u) : null);
    if (u is! Map || !u.containsKey('temp')) {
      _units = _units.copyWith(temp: temp);
    }
    _order = normalizeOrder(j['metricOrder']);
    final hidden = j['hiddenMetrics'];
    _hidden = {
      if (hidden is List)
        for (final n in hidden) ...HomeMetric.values.where((m) => m.name == n),
    };
    final ts = j['textScale'];
    _textScale = ts is num && textScaleOptions.contains(ts.toDouble())
        ? ts.toDouble()
        : 1.0;
    _highContrast = j['highContrast'] == true;
    _reduceMotion = j['reduceMotion'] == true;
  }

  /// Thu tu hop le: giu cac ten dung (khong trung), them chi so moi o cuoi.
  static List<HomeMetric> normalizeOrder(Object? raw) {
    final out = <HomeMetric>[];
    if (raw is List) {
      for (final n in raw) {
        for (final m in HomeMetric.values) {
          if (m.name == n && !out.contains(m)) out.add(m);
        }
      }
    }
    for (final m in HomeMetric.values) {
      if (!out.contains(m)) out.add(m);
    }
    return out;
  }

  // ---- Don vi ----

  void setUnits(UnitPrefs u) {
    if (u == _units) return;
    _units = u;
    _changed();
  }

  void setTemperatureUnit(bool celsius) => setUnits(
    _units.copyWith(temp: celsius ? TempUnit.celsius : TempUnit.fahrenheit),
  );

  // ---- Chi so trang chu ----

  void setMetricVisible(HomeMetric m, bool visible) {
    final next = {..._hidden};
    visible ? next.remove(m) : next.add(m);
    _hidden = next;
    _changed();
  }

  /// Di chuyen kieu `onReorderItem` ([newIndex] tinh sau khi xoa muc cu).
  void reorderMetric(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= _order.length) return;
    final list = [..._order];
    final m = list.removeAt(oldIndex);
    list.insert(newIndex.clamp(0, list.length), m);
    _order = list;
    _changed();
  }

  /// Nut len (-1) / xuong (+1), thay the cho keo tha.
  void moveMetric(HomeMetric m, int delta) {
    final i = _order.indexOf(m);
    final j = i + delta;
    if (i < 0 || j < 0 || j >= _order.length) return;
    final list = [..._order];
    list[i] = list[j];
    list[j] = m;
    _order = list;
    _changed();
  }

  void resetMetrics() {
    _order = HomeMetric.values;
    _hidden = const {};
    _changed();
  }

  // ---- Tro nang ----

  void setTextScale(double v) {
    if (!textScaleOptions.contains(v) || v == _textScale) return;
    _textScale = v;
    _changed();
  }

  void setHighContrast(bool on) {
    if (on == _highContrast) return;
    _highContrast = on;
    _changed();
  }

  void setReduceMotion(bool on) {
    if (on == _reduceMotion) return;
    _reduceMotion = on;
    _changed();
  }

  /// MediaQuery da ket hop he thong + lua chon trong app: co chu nhan them
  /// (toi da [maxTextScale]), tuong phan cao / giam chuyen dong = he thong
  /// HOAC cong tac trong app.
  MediaQueryData applyTo(MediaQueryData mq) {
    final base = mq.textScaler;
    final scaler = _textScale == 1.0
        ? base
        : _ScaledTextScaler(base, _textScale, maxTextScale);
    return mq.copyWith(
      textScaler: scaler,
      highContrast: mq.highContrast || _highContrast,
      disableAnimations: mq.disableAnimations || _reduceMotion,
    );
  }
}

/// textScaler he thong x he so trong app, gioi han tren.
class _ScaledTextScaler extends TextScaler {
  const _ScaledTextScaler(this.base, this.factor, this.max);

  final TextScaler base;
  final double factor;
  final double max;

  @override
  double scale(double fontSize) {
    if (fontSize <= 0) return base.scale(fontSize);
    final scaled = base.scale(fontSize) * factor;
    return scaled.clamp(0, fontSize * max).toDouble();
  }

  @override
  // ignore: deprecated_member_use
  double get textScaleFactor => scale(14) / 14;

  @override
  bool operator ==(Object other) =>
      other is _ScaledTextScaler &&
      other.base == base &&
      other.factor == factor &&
      other.max == max;

  @override
  int get hashCode => Object.hash(base, factor, max);
}
