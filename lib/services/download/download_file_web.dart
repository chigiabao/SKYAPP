import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Tao Blob + the <a download> roi bam (khong dung Web Share).
void downloadBytes(Uint8List bytes, String fileName, String mimeType) {
  final blob = web.Blob(
    <JSAny>[bytes.toJS].toJS,
    web.BlobPropertyBag(type: mimeType),
  );
  final url = web.URL.createObjectURL(blob);
  final a = web.document.createElement('a') as web.HTMLAnchorElement
    ..href = url
    ..download = fileName
    ..style.display = 'none';
  web.document.body?.append(a);
  a.click();
  a.remove();
  web.URL.revokeObjectURL(url);
}
