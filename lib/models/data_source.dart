/// Nguon cua tung muc so lieu (truong `source` cua backend).
///
///   - observed: so lieu "thuc te" = du lieu phan tich cua mo hinh
///     (Open-Meteo reanalysis/analysis), KHONG phai tram do.
///   - forecast: du bao cua mo hinh Open-Meteo.
///   - climatology: trung binh nhieu nam cho cung ngay/gio.
enum DataSource { observed, forecast, climatology }

/// "observed" | "forecast" | "climatology" -> DataSource; khac/thieu -> null.
DataSource? parseDataSource(dynamic value) {
  if (value is! String) return null;
  switch (value.trim().toLowerCase()) {
    case 'observed':
      return DataSource.observed;
    case 'forecast':
      return DataSource.forecast;
    case 'climatology':
      return DataSource.climatology;
  }
  return null;
}

extension DataSourceText on DataSource {
  /// Nhan day du (tieu de phu, chip nguon).
  String get label {
    switch (this) {
      case DataSource.forecast:
        return 'Dự báo mô hình (Open-Meteo)';
      case DataSource.observed:
        return 'Thực tế (dữ liệu mô hình phân tích)';
      case DataSource.climatology:
        return 'Trung bình nhiều năm';
    }
  }

  /// Nhan ngan cho o/hang (danh dau tung muc khi nguon bi tron).
  String get shortLabel {
    switch (this) {
      case DataSource.forecast:
        return 'Dự báo';
      case DataSource.observed:
        return 'Thực tế';
      case DataSource.climatology:
        return 'Thống kê';
    }
  }

  /// Mot cau giai thich trung thuc.
  String get note {
    switch (this) {
      case DataSource.forecast:
        return 'Dự báo của mô hình thời tiết Open-Meteo, có thể sai lệch.';
      case DataSource.observed:
        return 'Dữ liệu phân tích của mô hình (Open-Meteo), không phải số đo '
            'từ trạm khí tượng.';
      case DataSource.climatology:
        return 'Số liệu thống kê nhiều năm cho cùng ngày, cùng giờ — '
            'không phải dự báo thời tiết thực.';
    }
  }
}

/// Tom tat nguon cua mot danh sach muc.
///
/// Backend cu khong gui `source` -> coi la trung binh nhieu nam (dung voi
/// du lieu backend cu tra ve), de khong bao gio ghi nham la "du bao".
class SourceSummary {
  const SourceSummary._(this.sources);

  /// Cac nguon co mat, theo thu tu enum (observed, forecast, climatology).
  final List<DataSource> sources;

  /// Nguon mac dinh khi muc khong co truong `source` (backend cu).
  static const DataSource fallback = DataSource.climatology;

  factory SourceSummary.of(Iterable<DataSource?> items) {
    final present = <DataSource>{for (final s in items) s ?? fallback};
    if (present.isEmpty) present.add(fallback);
    return SourceSummary._([
      for (final s in DataSource.values)
        if (present.contains(s)) s,
    ]);
  }

  bool get isMixed => sources.length > 1;

  /// Nguon duy nhat; null neu tron.
  DataSource? get single => isMixed ? null : sources.first;

  bool contains(DataSource s) => sources.contains(s);

  /// Nhan tieu de phu: mot nguon -> nhan day du; tron -> liet ke ngan.
  String get label => isMixed
      ? 'Nhiều nguồn: ${sources.map((s) => s.shortLabel).join(' + ')}'
      : sources.first.label;

  /// Muc co can danh dau rieng khong: khi tron, danh dau muc khong phai du
  /// bao; muc "thuc te" luon duoc danh dau.
  bool marks(DataSource? item) {
    final s = item ?? fallback;
    if (s == DataSource.observed) return true;
    return isMixed && s != DataSource.forecast;
  }
}
