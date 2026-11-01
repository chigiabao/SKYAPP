import 'package:http/http.dart' as http;

import '../utils/formatters.dart';
import 'api_service.dart';

/// Ket qua kiem tra `/health`.
typedef ServerHealth = ({bool ok, String message});

/// Goi `GET {baseUrl}/health` (qua [ApiService]) va mo ta ket qua bang
/// tieng Viet.
Future<ServerHealth> checkServerHealth(
  String baseUrl, {
  http.Client? client,
  Duration timeout = const Duration(seconds: 6),
}) async {
  final api = ApiService(client: client, baseUrl: baseUrl, timeout: timeout);
  try {
    final j = await api.fetchHealthJson();
    if (j['status'] == null) {
      return (ok: false, message: 'Không phải máy chủ Sky Weather.');
    }
    final age = j['data_age_hours'];
    final db = j['database'];
    final parts = [
      'Kết nối được (${j['status']})',
      if (db != null) 'CSDL: $db',
      if (age is num)
        'dữ liệu mới nhất cách đây ${WeatherFormat.compact(age)} giờ',
    ];
    final healthy =
        j['status'] == 'healthy' &&
        (db == null || db == 'ok') &&
        j['ready'] != false;
    return (ok: healthy, message: '${parts.join(' · ')}.');
  } on ApiException catch (e) {
    final code = e.statusCode;
    return switch (e.kind) {
      ApiErrorKind.timeout => (
        ok: false,
        message: 'Hết thời gian chờ. Kiểm tra địa chỉ và mạng.',
      ),
      ApiErrorKind.invalidData => (
        ok: false,
        message: 'Không phải máy chủ Sky Weather.',
      ),
      _ when code != null => (
        ok: false,
        message: 'Máy chủ trả lỗi HTTP $code.',
      ),
      _ => (
        ok: false,
        message: 'Không kết nối được. Kiểm tra địa chỉ, mạng và máy chủ.',
      ),
    };
  } finally {
    if (client == null) api.close();
  }
}
