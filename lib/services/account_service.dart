import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config/api_config.dart';

/// Tai khoan TUY CHON (chi de dong bo giua cac thiet bi; app dung du khong
/// can dang nhap). Backend: backend/routers/auth.py + sync.py.

/// Loai loi khi goi /auth, /me.
enum AccountErrorKind {
  network,
  timeout,

  /// 401: token sai / het han -> dang xuat em.
  unauthorized,

  /// 401 khi dang nhap: sai email / mat khau.
  badLogin,

  /// 403: sai mat khau khi xoa tai khoan.
  wrongPassword,

  /// 409 khi dang ky: email da dung.
  emailTaken,

  /// 413: du lieu qua lon.
  tooLarge,

  /// 422: du lieu khong hop le (GPS, location_id sai, habits chua dong y...).
  invalid,

  /// 429: dang nhap sai qua nhieu lan.
  locked,
  server,
}

class AccountException implements Exception {
  AccountException(this.kind, {String? message, this.unknownLocationIds})
    : message = message ?? defaultMessage(kind);

  final AccountErrorKind kind;

  /// Cau tieng Viet de hien thi (uu tien `detail` cua may chu).
  final String message;

  /// 422 "Địa điểm không tồn tại." -> cac id may chu khong biet.
  final List<String>? unknownLocationIds;

  static String defaultMessage(AccountErrorKind k) => switch (k) {
    AccountErrorKind.network =>
      'Không có kết nối mạng hoặc không tới được máy chủ.',
    AccountErrorKind.timeout => 'Máy chủ không phản hồi.',
    AccountErrorKind.unauthorized =>
      'Phiên đăng nhập đã hết hạn. Vui lòng đăng nhập lại.',
    AccountErrorKind.badLogin => 'Email hoặc mật khẩu không đúng.',
    AccountErrorKind.wrongPassword => 'Mật khẩu không đúng.',
    AccountErrorKind.emailTaken => 'Không thể tạo tài khoản với email này.',
    AccountErrorKind.tooLarge => 'Dữ liệu quá lớn để đồng bộ.',
    AccountErrorKind.invalid => 'Dữ liệu không hợp lệ.',
    AccountErrorKind.locked =>
      'Đăng nhập sai quá nhiều lần. Vui lòng thử lại sau 15 phút.',
    AccountErrorKind.server => 'Máy chủ đang gặp lỗi.',
  };

  /// Loi tam thoi (mat mang / may chu loi) -> xep hang day sau.
  bool get isTransient =>
      kind == AccountErrorKind.network ||
      kind == AccountErrorKind.timeout ||
      kind == AccountErrorKind.server;

  @override
  String toString() => 'AccountException(${kind.name}): $message';
}

/// PUT /me/data tra 409: thiet bi khac da luu truoc. [current] la ban moi
/// nhat tren may chu (de gop roi gui lai).
class SyncConflict implements Exception {
  const SyncConflict(this.current);

  final RemoteDoc current;

  @override
  String toString() => 'SyncConflict(version ${current.version})';
}

/// Phien dang nhap.
@immutable
class AuthSession {
  const AuthSession({
    required this.token,
    required this.email,
    required this.expiresAt,
  });

  final String token;
  final String email;

  /// Unix giay (UTC).
  final int expiresAt;

  bool isExpired(DateTime now) =>
      now.millisecondsSinceEpoch ~/ 1000 >= expiresAt;

  Map<String, dynamic> toJson() => {
    'token': token,
    'email': email,
    'expires_at': expiresAt,
  };

  static AuthSession? tryFromJson(Object? j) {
    if (j is! Map) return null;
    final t = j['token'], e = j['email'], x = j['expires_at'];
    if (t is! String || t.isEmpty || e is! String || x is! int) return null;
    return AuthSession(token: t, email: e, expiresAt: x);
  }
}

/// GET /me/data: {version, data, updated_at}.
@immutable
class RemoteDoc {
  const RemoteDoc({required this.version, this.data, this.updatedAt});

  final int version;

  /// null = chua luu gi.
  final Map<String, dynamic>? data;

  /// Unix giay (may chu).
  final int? updatedAt;

  static RemoteDoc fromJson(Object? j) {
    if (j is! Map) throw AccountException(AccountErrorKind.server);
    final v = j['version'], d = j['data'], u = j['updated_at'];
    return RemoteDoc(
      version: v is int ? v : 0,
      data: d is Map ? Map<String, dynamic>.from(d) : null,
      updatedAt: u is int ? u : null,
    );
  }
}

/// Khoa toa do may chu tu choi (sync.py `_GPS_KEYS`). App kiem tra truoc
/// khi gui: tuyet doi khong gui toa do GPS.
const Set<String> kGpsKeys = {
  'lat',
  'lon',
  'lng',
  'latitude',
  'longitude',
  'gps',
  'coords',
  'coordinates',
};

bool containsGpsKey(Object? o) {
  if (o is Map) {
    return o.entries.any(
      (e) =>
          kGpsKeys.contains('${e.key}'.toLowerCase()) ||
          containsGpsKey(e.value),
    );
  }
  if (o is List) return o.any(containsGpsKey);
  return false;
}

// ---------------------------------------------------------------------------
// Luu token

/// Noi luu phien dang nhap.
abstract class TokenStore {
  Future<AuthSession?> read();
  Future<void> write(AuthSession s);
  Future<void> clear();

  /// Mobile / desktop: Keychain (iOS/macOS), Keystore (Android), DPAPI
  /// (Windows), libsecret (Linux). Web: SharedPreferences (xem
  /// [PrefsTokenStore]).
  factory TokenStore.platform() =>
      kIsWeb ? PrefsTokenStore() : SecureTokenStore();
}

const String _tokenKey = 'account_session_v1';

/// flutter_secure_storage. iOS: Keychain, chi thiet bi nay
/// (`first_unlock_this_device`: khong theo ban sao luu iCloud).
class SecureTokenStore implements TokenStore {
  SecureTokenStore([FlutterSecureStorage? storage])
    : _s =
          storage ??
          const FlutterSecureStorage(
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock_this_device,
            ),
          );

  final FlutterSecureStorage _s;

  @override
  Future<AuthSession?> read() async {
    try {
      final raw = await _s.read(key: _tokenKey);
      return raw == null ? null : AuthSession.tryFromJson(jsonDecode(raw));
    } catch (e) {
      debugPrint('SecureTokenStore.read: $e');
      return null;
    }
  }

  @override
  Future<void> write(AuthSession s) =>
      _s.write(key: _tokenKey, value: jsonEncode(s.toJson()));

  @override
  Future<void> clear() async {
    try {
      await _s.delete(key: _tokenKey);
    } catch (e) {
      debugPrint('SecureTokenStore.clear: $e');
    }
  }
}

/// Web: SharedPreferences (= localStorage).
///
/// RUI RO: moi script chay tren cung origin (vd. qua lo hong XSS / extension)
/// doc duoc token. Trinh duyet khong co kho bi mat that (flutter_secure_storage
/// tren web cung de khoa trong localStorage). Giam thieu: token chi dung de
/// dong bo (khong co du lieu nhay cam ngoai email), het han sau 30 ngay,
/// khong dung cookie (khong co CSRF), "Đăng xuất" thu hoi token tren may chu.
class PrefsTokenStore implements TokenStore {
  @override
  Future<AuthSession?> read() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_tokenKey);
      return raw == null ? null : AuthSession.tryFromJson(jsonDecode(raw));
    } catch (e) {
      debugPrint('PrefsTokenStore.read: $e');
      return null;
    }
  }

  @override
  Future<void> write(AuthSession s) async {
    await (await SharedPreferences.getInstance()).setString(
      _tokenKey,
      jsonEncode(s.toJson()),
    );
  }

  @override
  Future<void> clear() async {
    try {
      await (await SharedPreferences.getInstance()).remove(_tokenKey);
    } catch (e) {
      debugPrint('PrefsTokenStore.clear: $e');
    }
  }
}

/// Trong bo nho (test).
class MemoryTokenStore implements TokenStore {
  MemoryTokenStore([this.session]);

  AuthSession? session;

  @override
  Future<AuthSession?> read() async => session;

  @override
  Future<void> write(AuthSession s) async => session = s;

  @override
  Future<void> clear() async => session = null;
}

// ---------------------------------------------------------------------------
// Goi API

class AccountService {
  AccountService({
    http.Client? client,
    this.baseUrl = ApiConfig.baseUrl,
    this.timeout = ApiConfig.timeout,
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final String baseUrl;
  final Duration timeout;

  Future<AuthSession> register(String email, String password) =>
      _auth('/auth/register', email, password);

  Future<AuthSession> login(String email, String password) =>
      _auth('/auth/login', email, password);

  Future<AuthSession> _auth(String path, String email, String password) async {
    final j = await _send(
      'POST',
      path,
      body: {'email': email.trim(), 'password': password},
      login: true,
    );
    final s = j is Map
        ? AuthSession.tryFromJson({
            'token': j['token'],
            'email': j['email'] ?? email.trim().toLowerCase(),
            'expires_at': j['expires_at'],
          })
        : null;
    if (s == null) throw AccountException(AccountErrorKind.server);
    return s;
  }

  /// Thu hoi token tren may chu.
  Future<void> logout(String token) =>
      _send('POST', '/auth/logout', token: token);

  /// {email, created_at, last_active_at}.
  Future<Map<String, dynamic>> me(String token) async {
    final j = await _send('GET', '/me', token: token);
    return j is Map ? Map<String, dynamic>.from(j) : const {};
  }

  Future<RemoteDoc> getData(String token) async =>
      RemoteDoc.fromJson(await _send('GET', '/me/data', token: token));

  /// PUT /me/data. 409 -> [SyncConflict]; 422 / 413 -> [AccountException].
  /// Tu choi gui neu [data] co khoa toa do.
  Future<RemoteDoc> putData(
    String token,
    int baseVersion,
    Map<String, dynamic> data,
  ) async {
    if (containsGpsKey(data)) {
      throw AccountException(
        AccountErrorKind.invalid,
        message: 'Không đồng bộ toạ độ GPS.',
      );
    }
    return RemoteDoc.fromJson(
      await _send(
        'PUT',
        '/me/data',
        token: token,
        body: {'base_version': baseVersion, 'data': data},
      ),
    );
  }

  Future<void> deleteData(String token) =>
      _send('DELETE', '/me/data', token: token);

  /// Xoa tai khoan; sai mat khau -> [AccountErrorKind.wrongPassword].
  Future<void> deleteAccount(String token, String password) =>
      _send('DELETE', '/me', token: token, body: {'password': password});

  /// GET /me/export: toan bo du lieu (JSON dep, de luu file).
  Future<String> export(String token) async {
    final j = await _send('GET', '/me/export', token: token);
    return const JsonEncoder.withIndent('  ').convert(j);
  }

  /// GET /privacy: chinh sach quyen rieng tu (tieng Viet).
  Future<Map<String, String>> privacy() async {
    final j = await _send('GET', '/privacy');
    if (j is! Map) throw AccountException(AccountErrorKind.server);
    return {for (final e in j.entries) '${e.key}': '${e.value}'};
  }

  Future<dynamic> _send(
    String method,
    String path, {
    String? token,
    Object? body,
    bool login = false,
  }) async {
    final req = http.Request(method, Uri.parse('$baseUrl$path'));
    req.headers['Accept'] = 'application/json';
    if (token != null) req.headers['Authorization'] = 'Bearer $token';
    if (body != null) {
      req.headers['Content-Type'] = 'application/json; charset=utf-8';
      req.body = jsonEncode(body);
    }
    final http.Response res;
    try {
      res = await http.Response.fromStream(
        await _client.send(req).timeout(timeout),
      ).timeout(timeout);
    } on TimeoutException {
      throw AccountException(AccountErrorKind.timeout);
    } catch (e) {
      debugPrint('AccountService $method $path: $e');
      throw AccountException(AccountErrorKind.network);
    }
    dynamic json;
    if (res.bodyBytes.isNotEmpty) {
      try {
        json = jsonDecode(utf8.decode(res.bodyBytes));
      } catch (_) {
        json = null;
      }
    }
    final code = res.statusCode;
    if (code >= 200 && code < 300) return json;
    final detail = json is Map ? json['detail'] : null;
    final msg = detail is String ? detail : null;
    switch (code) {
      case 401:
        throw AccountException(
          login ? AccountErrorKind.badLogin : AccountErrorKind.unauthorized,
          message: login ? msg : null,
        );
      case 403:
        throw AccountException(AccountErrorKind.wrongPassword, message: msg);
      case 409:
        if (json is Map && json['current'] != null) {
          throw SyncConflict(RemoteDoc.fromJson(json['current']));
        }
        throw AccountException(AccountErrorKind.emailTaken, message: msg);
      case 413:
        throw AccountException(AccountErrorKind.tooLarge, message: msg);
      case 422:
        if (detail is Map) {
          final ids = detail['unknown_location_ids'];
          throw AccountException(
            AccountErrorKind.invalid,
            message: detail['message'] is String
                ? detail['message'] as String
                : null,
            unknownLocationIds: ids is List
                ? [for (final i in ids) '$i']
                : null,
          );
        }
        // Loi Pydantic: danh sach {loc, msg}.
        String? first;
        if (detail is List && detail.isNotEmpty && detail.first is Map) {
          final m = (detail.first as Map)['msg'];
          if (m is String) first = m.replaceFirst('Value error, ', '');
        }
        throw AccountException(AccountErrorKind.invalid, message: msg ?? first);
      case 429:
        throw AccountException(AccountErrorKind.locked, message: msg);
      default:
        throw AccountException(AccountErrorKind.server);
    }
  }
}
