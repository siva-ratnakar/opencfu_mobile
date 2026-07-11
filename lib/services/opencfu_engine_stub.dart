import 'package:image_picker/image_picker.dart';

import '../app_mode.dart';
import '../capture_options.dart';
import 'opencfu_models.dart';

export 'opencfu_models.dart';

/// Stub engine for platforms without dart:ffi (e.g. web). The native OpenCFU
/// core cannot run there, so every analysis reports that the engine is
/// unavailable instead of fabricating a colony count.
class FfiOpenCfuEngine extends OpenCfuEngine {
  FfiOpenCfuEngine();

  @override
  Future<OpenCfuAnalysis> analyze({
    required XFile image,
    required AppMode mode,
    required CaptureOptions options,
  }) async {
    return const OpenCfuAnalysis(
      colonyCount: 0,
      overlayLabel: 'Native engine unavailable',
      available: false,
      errorMessage: 'The OpenCFU native core is not available on this platform.',
    );
  }
}
