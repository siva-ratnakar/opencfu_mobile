import 'dart:typed_data';

/// No-op on every platform except web -- callers gate on `kIsWeb` before
/// reaching for this, so this body should never actually run.
Future<bool> saveBytesAsWebDownload({
  required String fileName,
  required String mimeType,
  required Uint8List bytes,
}) async {
  return false;
}
