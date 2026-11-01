/// Nguon cua tung muc so lieu (truong `source` cua backend).
///
///   - ai: du bao cua AI do nhom tu huan luyen (moi gia tri tuong lai).
///   - observed: so lieu "thuc te" = du lieu dau vao Open-Meteo cho gio da
///     qua (phan tich mo hinh), KHONG phai tram do.
///   - forecast: chi con o may chu cu (du bao nguon ngoai); ung dung khong
///     ghi cong nguon ngoai cho du bao.
///   - climatology: trung binh nhieu nam cho cung ngay/gio.
enum DataSource { observed, forecast, climatology, ai }

/// "observed" | "forecast" | "climatology" -> DataSource; khac/thieu -> null.
DataSource? parseDataSource(dynamic value) {
  if (value is! String) return null;
  switch (value.trim().toLowerCase()) {
    case 'observed':
      return DataSource.observed;
    case 'forecast':
      return DataSource.forecast;
    case 'ai':
      return DataSource.ai;
    case 'climatology':
      return DataSource.climatology;
  }
  return null;
}

/// Cach goi DE HIEU, dung chung toan app, cho cac nguon so lieu. "Thuc te"
/// cua app la uoc tinh cua mo hinh thoi tiet (Open-Meteo) cho gio da qua,
/// KHONG phai so do tai tram -> luon kem "(mô hình)".
abstract final class DataCopy {
  /// Nhan day du (chip nguon, tieu de).
  static const String observed = 'Số liệu đã ghi nhận (mô hình)';

  /// Trong cau (chu thuong dau cau).
  static const String observedInline = 'số liệu đã ghi nhận (mô hình)';

  /// Trong cau da nam trong ngoac (tranh ngoac long ngoac).
  static const String observedInParens =
      'số liệu đã ghi nhận – ước tính mô hình';

  /// Trong ngoac ngan (chu thich nguon tron).
  static const String observedShort = 'đã ghi nhận, mô hình';

  /// Giai thich mot cau.
  static const String observedExplain =
      'số liệu Open-Meteo đã ghi nhận cho giờ đã qua — ước tính của mô hình '
      'thời tiết, không phải số đo tại trạm khí tượng';

  /// Du bao cua nhom.
  static const String aiForecast = 'AI của nhóm';
}

extension DataSourceText on DataSource {
  /// Nhan day du (tieu de phu, chip nguon).
  String get label {
    switch (this) {
      case DataSource.ai:
        return 'Dự báo AI Sky Weather';
      case DataSource.forecast:
        return 'Dự báo nguồn ngoài (máy chủ cũ)';
      case DataSource.observed:
        return DataCopy.observed;
      case DataSource.climatology:
        return 'Trung bình nhiều năm';
    }
  }

  /// Nhan ngan cho o/hang (danh dau tung muc khi nguon bi tron).
  String get shortLabel {
    switch (this) {
      case DataSource.ai:
        return 'AI của nhóm';
      case DataSource.forecast:
        return 'Nguồn ngoài';
      case DataSource.observed:
        return 'Đã ghi nhận';
      case DataSource.climatology:
        return 'Thống kê';
    }
  }

  /// Mot cau giai thich trung thuc.
  String get note {
    switch (this) {
      case DataSource.ai:
        return 'Mô hình AI thử nghiệm do nhóm Sky Weather tự huấn luyện trên '
            'dữ liệu đầu vào các giờ đã qua, không phải quan trắc trạm. Chưa '
            'vượt mốc thống kê khí hậu ở một số chỉ số/ngày thứ 7; không phải '
            'cảnh báo khí tượng chính thức.';
      case DataSource.forecast:
        return 'Máy chủ cũ gửi dự báo không do AI của nhóm tạo. Hãy cập nhật '
            'máy chủ; ứng dụng chỉ dùng dự báo AI của nhóm.';
      case DataSource.observed:
        return 'Số liệu Open-Meteo đã ghi nhận cho giờ đã qua — ước tính của '
            'mô hình thời tiết, không phải số đo từ trạm khí tượng.';
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
    return isMixed && s != DataSource.forecast && s != DataSource.ai;
  }
}
