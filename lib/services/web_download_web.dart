import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Triggers a browser "Save As" download for [bytes] -- the web equivalent
/// of writing into a device folder, since there's no filesystem to write
/// into and no OS share sheet to hand a real file to.
Future<bool> saveBytesAsWebDownload({
  required String fileName,
  required String mimeType,
  required Uint8List bytes,
}) async {
  final blob = web.Blob([bytes.toJS].toJS, web.BlobPropertyBag(type: mimeType));
  final url = web.URL.createObjectURL(blob);
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = fileName;
  web.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
  web.URL.revokeObjectURL(url);
  return true;
}
