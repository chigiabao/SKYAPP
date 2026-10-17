/// Bo dinh dang so lieu dung chung (dau thap phan kieu Viet Nam: dau phay).
class WeatherFormat {
  WeatherFormat._();

  /// Luong mua: 0 -> "0 mm", <1 -> mot chu so thap phan ("0,4 mm"),
  /// >= 1 -> so nguyen ("13 mm"). Vet mua (< 0,05) -> "< 0,1 mm".
  static String rainMm(double? mm) {
    if (mm == null) return '--';
    if (mm <= 0) return '0 mm';
    if (mm < 0.05) return '< 0,1 mm';
    final oneDecimal = (mm * 10).round() / 10;
    if (oneDecimal < 1) return '${_decimal(oneDecimal, 1)} mm';
    return '${mm.round()} mm';
  }

  /// Tam nhin: < 10 km -> mot chu so thap phan, con lai so nguyen.
  static String visibilityKm(double? km) {
    if (km == null) return '--';
    if (km < 10) return '${_decimal(km, 1)} km';
    return '${km.round()} km';
  }

  static String percent(num? value) =>
      value == null ? '--' : '${value.round()}%';

  static String speedKmh(double? kmh) =>
      kmh == null ? '--' : '${kmh.round()} km/h';

  /// Huong gio (do, kieu khi tuong: huong gio THOI TU) -> 8 huong tieng Viet.
  static String compass(double? degrees) {
    if (degrees == null) return '--';
    const names = [
      'Bắc',
      'Đông Bắc',
      'Đông',
      'Đông Nam',
      'Nam',
      'Tây Nam',
      'Tây',
      'Tây Bắc',
    ];
    final normalized = degrees % 360;
    final index = ((normalized + 22.5) ~/ 45) % 8;
    return names[index];
  }

  /// So mot chu so thap phan, dau phay ("36,6").
  static String decimal1(double value) => _decimal(value, 1);

  static String _decimal(double value, int digits) =>
      value.toStringAsFixed(digits).replaceAll('.', ',');
}
