import 'dart:ffi';
import 'dart:io';
import 'dart:ui' show Offset;

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../app_mode.dart';
import '../capture_options.dart';
import 'opencfu_models.dart';

export 'opencfu_models.dart';

// Threshold modes mirror OPENCFU_THR_* in the native bridge header.
const int _thrNormal = 0;
const int _thrInverted = 1;
const int _thrBilateral = 2;

// Mask/ROI mode and tool mirror OPENCFU_MASK_*/OPENCFU_MASK_TOOL_* in the
// native bridge header.
const int _maskNone = 0;
const int _maskDraw = 2;
const int _maskAuto = 3;
const int _maskToolCircle = 0;
const int _maskToolPolygon = 1;

// Must match OPENCFU_MASK_MAX_POINTS / OPENCFU_MASK_OUT_MAX_POINTS.
const int _maskInMaxPoints = 32;
const int _maskOutMaxPoints = 64;

// Upper bound on markers copied back from native per analysis.
const int _maxColonies = 6000;

/// FFI-backed engine that calls the vendored OpenCFU processor. Falls back to an
/// "unavailable" result (rather than fabricating a count) when the native
/// library or its classifier assets are not present.
class FfiOpenCfuEngine extends OpenCfuEngine {
  factory FfiOpenCfuEngine() {
    try {
      return FfiOpenCfuEngine._open(_openLibrary());
    } catch (error) {
      return FfiOpenCfuEngine._unavailable(error.toString());
    }
  }

  FfiOpenCfuEngine._open(this._library) : _loadError = null;

  FfiOpenCfuEngine._unavailable(this._loadError) : _library = null;

  final DynamicLibrary? _library;
  final String? _loadError;
  String? _classifierDir;

  static DynamicLibrary _openLibrary() {
    if (Platform.isAndroid) return DynamicLibrary.open('libopencfu_mobile.so');
    if (Platform.isIOS) return DynamicLibrary.process();
    if (Platform.isMacOS) return DynamicLibrary.open('libopencfu_mobile.dylib');
    if (Platform.isWindows) return DynamicLibrary.open('opencfu_mobile.dll');
    if (Platform.isLinux) return DynamicLibrary.open('libopencfu_mobile.so');
    return DynamicLibrary.process();
  }

  _DartAnalyze? get _analyze {
    final library = _library;
    if (library == null) return null;
    return library.lookupFunction<_NativeAnalyze, _DartAnalyze>('opencfu_mobile_analyze_image');
  }

  /// Copies the bundled classifier into a writable directory the native core
  /// can read via its relative paths. The single trained classifier is used for
  /// both the main and post-split classifiers the processor expects.
  Future<String> _ensureClassifierDir() async {
    final cached = _classifierDir;
    if (cached != null) return cached;

    final support = await getApplicationSupportDirectory();
    final root = Directory('${support.path}${Platform.pathSeparator}opencfu');
    final dataDir = Directory('${root.path}${Platform.pathSeparator}data');
    if (!await dataDir.exists()) {
      await dataDir.create(recursive: true);
    }

    final bytes = await rootBundle.load('assets/opencfu/data/trainedClassifier.xml');
    final buffer = bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);

    for (final name in const ['trainedClassifier.xml', 'trainedClassifierPS.xml']) {
      final file = File('${dataDir.path}${Platform.pathSeparator}$name');
      if (!await file.exists() || await file.length() != buffer.length) {
        await file.writeAsBytes(buffer, flush: true);
      }
    }

    _classifierDir = root.path;
    return root.path;
  }

  @override
  Future<OpenCfuAnalysis> analyze({
    required XFile image,
    required AppMode mode,
    required CaptureOptions options,
  }) async {
    final loadError = _loadError;
    if (loadError != null) {
      return _unavailableAnalysis('Native OpenCFU library not linked: $loadError');
    }

    final analyze = _analyze;
    if (analyze == null) {
      return _unavailableAnalysis('Native OpenCFU entry point missing');
    }

    String classifierDir;
    try {
      classifierDir = await _ensureClassifierDir();
    } catch (error) {
      return _unavailableAnalysis('Could not prepare classifier: $error');
    }

    final imagePathPtr = image.path.toNativeUtf8();
    final classifierDirPtr = classifierDir.toNativeUtf8();
    final optionsPtr = calloc<_NativeOptions>();
    final resultPtr = calloc<_NativeBridgeResult>();
    final coloniesPtr = calloc<_NativeColony>(_maxColonies);

    try {
      _fillOptions(optionsPtr.ref, options);

      final code = analyze(imagePathPtr, classifierDirPtr, optionsPtr, resultPtr, coloniesPtr, _maxColonies);
      final result = resultPtr.ref;

      if (code != 0 || result.valid == 0) {
        return _unavailableAnalysis(_readError(result));
      }

      final markers = <ColonyMarker>[];
      for (var i = 0; i < result.returnedCount; i++) {
        final colony = coloniesPtr[i];
        markers.add(
          ColonyMarker(
            center: Offset(colony.cx, colony.cy),
            corners: <Offset>[
              Offset(colony.cornerX[0], colony.cornerY[0]),
              Offset(colony.cornerX[1], colony.cornerY[1]),
              Offset(colony.cornerX[2], colony.cornerY[2]),
              Offset(colony.cornerX[3], colony.cornerY[3]),
            ],
            radius: colony.radius.toDouble(),
            valid: colony.valid != 0,
          ),
        );
      }

      final maskContour = <Offset>[];
      if (result.maskApplied != 0) {
        final count = result.maskPointCount.clamp(0, _maskOutMaxPoints);
        for (var i = 0; i < count; i++) {
          maskContour.add(Offset(result.maskPointsX[i], result.maskPointsY[i]));
        }
      }

      return OpenCfuAnalysis(
        colonyCount: result.colonyCount,
        totalCount: result.totalCount,
        imageWidth: result.imageWidth,
        imageHeight: result.imageHeight,
        markers: markers,
        maskContour: maskContour,
        overlayLabel: mode == AppMode.basic ? 'Basic mode' : 'Advanced mode',
      );
    } finally {
      calloc.free(coloniesPtr);
      calloc.free(resultPtr);
      calloc.free(optionsPtr);
      calloc.free(classifierDirPtr);
      calloc.free(imagePathPtr);
    }
  }

  void _fillOptions(_NativeOptions o, CaptureOptions options) {
    o.thresholdMode = switch (options.thresholdMode) {
      ThresholdMode.normal => _thrNormal,
      ThresholdMode.inverted => _thrInverted,
      ThresholdMode.bilateral => _thrBilateral,
    };
    o.autoThreshold = options.autoThreshold ? 1 : 0;
    o.threshold = (options.threshold.clamp(0.0, 1.0) * 255).round();
    o.minRadius = options.minRadius.round();
    o.maxRadius = options.maxRadius.round();
    o.hasMaxRadius = options.hasMaxRadius ? 1 : 0;
    o.hueFilter = options.colourFilter ? 1 : 0;
    o.outlierFilter = options.outlierFilter ? 1 : 0;
    o.outlierThreshold = options.outlierThreshold;
    o.similarColours = options.similarColours ? 1 : 0;
    o.clusterDistance = options.clusterDistance;

    o.maskType = switch (options.maskMode) {
      MaskMode.none => _maskNone,
      MaskMode.auto => _maskAuto,
      MaskMode.draw => _maskDraw,
    };
    o.maskTool = switch (options.maskTool) {
      MaskTool.circle => _maskToolCircle,
      MaskTool.polygon => _maskToolPolygon,
    };
    final points = options.maskPoints;
    final pointCount = points.length.clamp(0, _maskInMaxPoints);
    o.maskPointCount = options.maskMode == MaskMode.draw ? pointCount : 0;
    for (var i = 0; i < pointCount; i++) {
      o.maskPointsX[i] = points[i].dx;
      o.maskPointsY[i] = points[i].dy;
    }
  }

  String _readError(_NativeBridgeResult result) {
    final codes = <int>[];
    for (var i = 0; i < 512; i++) {
      final c = result.errorMessage[i];
      if (c == 0) break;
      codes.add(c);
    }
    if (codes.isEmpty) return 'Native OpenCFU analysis failed';
    return String.fromCharCodes(codes);
  }

  OpenCfuAnalysis _unavailableAnalysis(String message) {
    return OpenCfuAnalysis(
      colonyCount: 0,
      overlayLabel: 'Native engine unavailable',
      available: false,
      errorMessage: message,
    );
  }
}

// --- Native struct/function definitions -------------------------------------

final class _NativeOptions extends Struct {
  @Int32()
  external int thresholdMode;
  @Int32()
  external int autoThreshold;
  @Int32()
  external int threshold;
  @Int32()
  external int minRadius;
  @Int32()
  external int maxRadius;
  @Int32()
  external int hasMaxRadius;
  @Int32()
  external int hueFilter;
  @Int32()
  external int outlierFilter;
  @Double()
  external double outlierThreshold;
  @Int32()
  external int similarColours;
  @Double()
  external double clusterDistance;

  @Int32()
  external int maskType;
  @Int32()
  external int maskTool;
  @Int32()
  external int maskPointCount;
  @Array<Float>(32)
  external Array<Float> maskPointsX;
  @Array<Float>(32)
  external Array<Float> maskPointsY;
}

final class _NativeColony extends Struct {
  @Float()
  external double cx;
  @Float()
  external double cy;
  @Array<Float>(4)
  external Array<Float> cornerX;
  @Array<Float>(4)
  external Array<Float> cornerY;
  @Int32()
  external int radius;
  @Int32()
  external int valid;
}

final class _NativeBridgeResult extends Struct {
  @Int32()
  external int colonyCount;
  @Int32()
  external int totalCount;
  @Int32()
  external int returnedCount;
  @Int32()
  external int imageWidth;
  @Int32()
  external int imageHeight;
  @Int32()
  external int valid;
  @Array<Uint8>(512)
  external Array<Uint8> errorMessage;

  @Int32()
  external int maskApplied;
  @Int32()
  external int maskPointCount;
  @Array<Float>(64)
  external Array<Float> maskPointsX;
  @Array<Float>(64)
  external Array<Float> maskPointsY;
}

typedef _NativeAnalyze = Int32 Function(
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<_NativeOptions>,
  Pointer<_NativeBridgeResult>,
  Pointer<_NativeColony>,
  Int32,
);

typedef _DartAnalyze = int Function(
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<_NativeOptions>,
  Pointer<_NativeBridgeResult>,
  Pointer<_NativeColony>,
  int,
);
