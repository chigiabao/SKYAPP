import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config/api_config.dart';
import '../models/weather.dart';
import 'app_version.dart';

/// Phan hoi nguoi dung (nhom 10). Backend: backend/routers/feedback.py.
///
/// Phan hoi la bao cao CHUA XAC MINH (verified = false), luu rieng, KHONG
/// thay du lieu quan trac. Khong bao gio gui toa do GPS: payload chi gom cac
/// truong liet ke trong [FeedbackDraft.toPayload].

/// Phien ban app hien hanh (package_info_plus, xem [AppVersion]).
String get kAppVersion => AppVersion.current;

/// Ten nen tang ngan gui kem phan hoi.
String currentPlatformName() => kIsWeb ? 'web' : defaultTargetPlatform.name;

const String kFeedbackDisclaimer =
    'Phản hồi của bạn chưa được xác minh và không thay thế dữ liệu quan trắc.';

const int kFeedbackMaxLength = 1000;

enum FeedbackKind {
  bug('bug', 'Báo lỗi'),
  suggestion('suggestion', 'Góp ý'),
  wrongForecast('wrong_forecast', 'Dự báo sai');

  const FeedbackKind(this.json, this.label);
  final String json;
  final String label;

  static FeedbackKind? tryParse(Object? v) {
    for (final k in values) {
      if (k.json == v) return k;
    }
    return null;
  }
}

enum TemperatureFeel {
  hot('hot', 'Nóng'),
  ok('ok', 'Bình thường'),
  cool('cool', 'Mát');

  const TemperatureFeel(this.json, this.label);
  final String json;
  final String label;

  static TemperatureFeel? tryParse(Object? v) {
    for (final f in values) {
      if (f.json == v) return f;
    }
    return null;
  }
}

/// Noi dung mot phan hoi (cung la ban nhap luu khi mat mang).
class FeedbackDraft {
  const FeedbackDraft({
    required this.kind,
    this.message = '',
    this.locationId,
    this.raining,
    this.feel,
    this.snapshot,
  });

  final FeedbackKind kind;
  final String message;
  final String? locationId;

  /// Chi dung voi [FeedbackKind.wrongForecast].
  final bool? raining;
  final TemperatureFeel? feel;

  /// forecast_snapshot nho, xem [forecastSnapshot].
  final Map<String, Object?>? snapshot;

  /// Body cho POST /feedback. Danh sach truong co dinh: khong co lat/lon.
  Map<String, Object?> toPayload({String? appVersion, String? platform}) {
    final wrong = kind == FeedbackKind.wrongForecast;
    final msg = message.trim();
    return {
      'kind': kind.json,
      'message': msg.length > kFeedbackMaxLength
          ? msg.substring(0, kFeedbackMaxLength)
          : msg,
      if (locationId != null) 'location_id': locationId,
      if (wrong && (raining != null || feel != null))
        'observed': {
          if (raining != null) 'raining': raining,
          if (feel != null) 'temperature_feel': feel!.json,
        },
      if (snapshot != null) 'forecast_snapshot': snapshot,
      'app_version': appVersion ?? kAppVersion,
      'platform': platform ?? currentPlatformName(),
    };
  }

  Map<String, Object?> toJson() => {
    'kind': kind.json,
    'message': message,
    'location_id': locationId,
    'raining': raining,
    'feel': feel?.json,
    'snapshot': snapshot,
  };

  static FeedbackDraft? tryFromJson(Object? j) {
    if (j is! Map) return null;
    final kind = FeedbackKind.tryParse(j['kind']);
    if (kind == null) return null;
    final snap = j['snapshot'];
    return FeedbackDraft(
      kind: kind,
      message: j['message'] is String ? j['message'] as String : '',
      locationId: j['location_id'] is String
          ? j['location_id'] as String
          : null,
      raining: j['raining'] is bool ? j['raining'] as bool : null,
      feel: TemperatureFeel.tryParse(j['feel']),
      snapshot: snap is Map ? Map<String, Object?>.from(snap) : null,
    );
  }
}

/// forecast_snapshot: dia diem, gio, nhiet do du bao, kha nang mua (0-1),
/// nguon. Uu tien gio hien tai trong [hours]; khong co -> [current].
Map<String, Object?>? forecastSnapshot({
  required String? locationId,
  required DateTime nowHcm,
  List<HourlyForecast> hours = const [],
  CurrentWeather? current,
}) {
  final hour = HcmTime.startOfHour(nowHcm);
  HourlyForecast? h;
  for (final x in hours) {
    if (HcmTime.startOfHour(x.time) == hour) {
      h = x;
      break;
    }
  }
  if (h == null && current == null) return null;
  final rain =
      h?.rainProbability ??
      (current?.precipitationProbability == null
          ? null
          : current!.precipitationProbability! / 100);
  return {
    'location_id': locationId,
    'time': HcmTime.toIso(h?.time ?? hour),
    'temperature': h?.temperature ?? current?.temperature,
    'rain_probability': rain,
    'source': (h?.source ?? current?.source)?.name ?? 'forecast',
  };
}

class FeedbackReceipt {
  const FeedbackReceipt({required this.id, this.createdAt, this.verified});

  final int id;
  final String? createdAt;
  final bool? verified;
}

enum FeedbackErrorKind { network, rateLimited, invalid, server }

class FeedbackException implements Exception {
  FeedbackException(this.kind, {this.draftSaved = false, String? message})
    : message = message ?? defaultMessage(kind, draftSaved);

  final FeedbackErrorKind kind;

  /// Da luu nhap de thu lai.
  final bool draftSaved;
  final String message;

  static String defaultMessage(FeedbackErrorKind k, bool saved) => switch (k) {
    FeedbackErrorKind.network =>
      'Không gửi được do lỗi mạng.${saved ? ' Đã lưu nháp, bạn có thể thử lại.' : ''}',
    FeedbackErrorKind.rateLimited =>
      'Bạn đã gửi quá nhiều phản hồi, vui lòng thử lại sau.',
    FeedbackErrorKind.invalid => 'Nội dung phản hồi không hợp lệ.',
    FeedbackErrorKind.server =>
      'Máy chủ đang gặp lỗi.${saved ? ' Đã lưu nháp, bạn có thể thử lại.' : ''}',
  };

  @override
  String toString() => 'FeedbackException(${kind.name}): $message';
}

class FeedbackService {
  FeedbackService({
    http.Client? client,
    this._baseUrl,
    this.timeout = ApiConfig.timeout,
    this._appVersion,
    String? platform,
  }) : _client = client ?? http.Client(),
       platform = platform ?? currentPlatformName();

  static const String draftKey = 'feedback_draft_v1';

  final http.Client _client;
  final String? _baseUrl;

  /// Doc moi lan goi: ApiConfig.baseUrl co the doi luc chay.
  String get baseUrl => _baseUrl ?? ApiConfig.baseUrl;
  final Duration timeout;
  final String? _appVersion;

  /// Mac dinh: phien ban that cua app ([AppVersion.current]).
  String get appVersion => _appVersion ?? kAppVersion;
  final String platform;

  /// Gui phan hoi. Thanh cong -> xoa nhap. Mat mang / may chu loi -> luu
  /// nhap roi nem [FeedbackException] (draftSaved = true).
  Future<FeedbackReceipt> submit(FeedbackDraft draft) async {
    final body = jsonEncode(
      draft.toPayload(appVersion: appVersion, platform: platform),
    );
    http.Response res;
    try {
      res = await _client
          .post(
            Uri.parse('$baseUrl/feedback'),
            headers: const {'Content-Type': 'application/json'},
            body: body,
          )
          .timeout(timeout);
    } catch (_) {
      final saved = await saveDraft(draft);
      throw FeedbackException(FeedbackErrorKind.network, draftSaved: saved);
    }
    if (res.statusCode == 201 || res.statusCode == 200) {
      await clearDraft();
      final j = _decode(res);
      final id = j is Map ? j['id'] : null;
      return FeedbackReceipt(
        id: id is num ? id.toInt() : 0,
        createdAt: j is Map ? j['created_at'] as String? : null,
        verified: j is Map ? j['verified'] as bool? : null,
      );
    }
    if (res.statusCode == 429) {
      throw FeedbackException(FeedbackErrorKind.rateLimited);
    }
    if (res.statusCode >= 500) {
      final saved = await saveDraft(draft);
      throw FeedbackException(FeedbackErrorKind.server, draftSaved: saved);
    }
    // 404 (dia diem la) / 422: noi dung sai, khong luu nhap.
    throw FeedbackException(FeedbackErrorKind.invalid);
  }

  static Object? _decode(http.Response res) {
    try {
      return jsonDecode(utf8.decode(res.bodyBytes));
    } catch (_) {
      return null;
    }
  }

  Future<bool> saveDraft(FeedbackDraft d) async {
    try {
      final p = await SharedPreferences.getInstance();
      return await p.setString(draftKey, jsonEncode(d.toJson()));
    } catch (e) {
      debugPrint('feedback draft: $e');
      return false;
    }
  }

  Future<FeedbackDraft?> loadDraft() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(draftKey);
      return raw == null ? null : FeedbackDraft.tryFromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  Future<void> clearDraft() async {
    try {
      await (await SharedPreferences.getInstance()).remove(draftKey);
    } catch (_) {}
  }
}
