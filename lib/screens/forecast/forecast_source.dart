import '../../models/data_source.dart';

/// Nguon du lieu cua man hinh du bao chi tiet (chip "Nguồn: ...").
///
/// Suy ra tu truong `source` cua tung muc ([ForecastSource.fromItems]); nhan
/// va cau giai thich lay tu [DataSourceText] trong models/data_source.dart.
class ForecastSource {
  const ForecastSource({
    required this.label,
    required this.note,
    this.isRealForecast = false,
    this.summary,
  });

  /// Nhan ngan, hien trong chip nguon (vd "Trung bình nhiều năm").
  final String label;

  /// Mot cau giai thich ngan dat duoi chip nguon.
  final String note;

  /// true = toan bo la du bao tu mo hinh.
  final bool isRealForecast;

  /// Tom tat nguon (null voi hang so co dinh); dung de ve chu thich khi tron.
  final SourceSummary? summary;

  bool get isMixed => summary?.isMixed ?? false;

  /// Backend cu (khong gui `source`): trung binh nhieu nam.
  static const climatology = ForecastSource(
    label: 'Trung bình nhiều năm',
    note:
        'Số liệu thống kê nhiều năm cho cùng ngày, cùng giờ — '
        'không phải dự báo thời tiết thực.',
  );

  /// Tu nguon cua cac muc dang hien thi; muc thieu `source` -> trung binh
  /// nhieu nam (xem [SourceSummary.fallback]).
  factory ForecastSource.fromItems(Iterable<DataSource?> sources) {
    final s = SourceSummary.of(sources);
    final single = s.single;
    return ForecastSource(
      label: s.label,
      note: single != null
          ? single.note
          : 'Mỗi giờ/ngày được đánh dấu nguồn riêng (xem chú thích).',
      isRealForecast: single == DataSource.forecast || single == DataSource.ai,
      summary: s,
    );
  }
}
