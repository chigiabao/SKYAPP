/// Tai mot file xuong may qua trinh duyet (chi web). Ngoai web: nem
/// [UnsupportedError] - noi goi phai kiem tra kIsWeb truoc.
library;

export 'download_file_stub.dart'
    if (dart.library.js_interop) 'download_file_web.dart';
