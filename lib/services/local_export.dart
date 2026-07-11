import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import 'web_download.dart';

/// Result of attempting to save a file into a persistent, user-visible
/// device folder (as opposed to the app's private sandbox).
class LocalSaveResult {
  const LocalSaveResult({required this.saved, this.path});

  /// True if the file landed in a real, user-browsable folder. False means
  /// the caller should fall back to sharing the file instead.
  final bool saved;
  final String? path;
}

const MethodChannel _channel = MethodChannel('opencfu_mobile/local_save');

/// Saves [bytes] as `OpenCFU/<subfolder>/<fileName>` (or `OpenCFU/<fileName>`
/// when [subfolder] is null) in a persistent, user-visible location, and
/// never throws -- callers fall back to the share sheet when
/// [LocalSaveResult.saved] is false. [subfolder] lets a batch of exports
/// (e.g. one PNG per plate, plus the results image) land together instead of
/// scattered flat in the OpenCFU root.
///
///  - Web: there's no filesystem to write into, so this triggers a normal
///    browser download instead -- the closest web equivalent of "a
///    persistent, user-visible location". Checked first, before any
///    `Platform.*` call, since `dart:io`'s `Platform` throws on web.
///  - Android 10+ (API 29+): written into MediaStore's public Downloads
///    collection. Scoped storage lets any app insert there without a
///    runtime permission, so this always just works.
///  - Android 9 and below: needs `WRITE_EXTERNAL_STORAGE`, requested here
///    (native side reports back that it's missing rather than throwing).
///  - iOS: saved into the app's own Documents/OpenCFU folder. Info.plist
///    opts in to file sharing, so that folder shows up in the Files app
///    under "On My iPhone/iPad" -- iOS has no equivalent runtime permission
///    to request for this.
Future<LocalSaveResult> saveToDeviceFolder({
  required String fileName,
  required String mimeType,
  required Uint8List bytes,
  String? subfolder,
}) async {
  if (kIsWeb) {
    final saved = await saveBytesAsWebDownload(fileName: fileName, mimeType: mimeType, bytes: bytes);
    return LocalSaveResult(saved: saved, path: saved ? fileName : null);
  }

  if (Platform.isIOS) {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final parts = ['OpenCFU', if (subfolder != null && subfolder.isNotEmpty) subfolder];
      final dir = Directory('${docs.path}${Platform.pathSeparator}${parts.join(Platform.pathSeparator)}');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final file = File('${dir.path}${Platform.pathSeparator}$fileName');
      await file.writeAsBytes(bytes);
      return LocalSaveResult(saved: true, path: file.path);
    } catch (_) {
      return const LocalSaveResult(saved: false);
    }
  }

  if (Platform.isAndroid) {
    Future<String?> attempt() => _channel.invokeMethod<String>('saveToDownloads', {
          'fileName': fileName,
          'mimeType': mimeType,
          'bytes': bytes,
          if (subfolder != null && subfolder.isNotEmpty) 'subfolder': subfolder,
        });

    try {
      final path = await attempt();
      if (path != null) {
        return LocalSaveResult(saved: true, path: path);
      }
    } on PlatformException catch (error) {
      if (error.code != 'permission_required') {
        return const LocalSaveResult(saved: false);
      }
      // Only reachable on Android 9 and below (see MainActivity.kt) -- ask,
      // then retry once.
      final status = await Permission.storage.request();
      if (!status.isGranted) {
        return const LocalSaveResult(saved: false);
      }
      try {
        final path = await attempt();
        if (path != null) {
          return LocalSaveResult(saved: true, path: path);
        }
      } catch (_) {
        return const LocalSaveResult(saved: false);
      }
    } catch (_) {
      return const LocalSaveResult(saved: false);
    }
  }

  return const LocalSaveResult(saved: false);
}
