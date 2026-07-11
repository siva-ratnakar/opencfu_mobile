import 'dart:js_interop';
import 'dart:typed_data';
import 'dart:ui' show Offset;

import 'package:flutter/services.dart' show rootBundle;
import 'package:image_picker/image_picker.dart';

import '../app_mode.dart';
import '../capture_options.dart';
import 'opencfu_models.dart';

export 'opencfu_models.dart';

// Threshold modes mirror OPENCFU_THR_* in the native bridge header (same
// constants opencfu_engine_native.dart uses for the FFI struct).
const int _thrNormal = 0;
const int _thrInverted = 1;
const int _thrBilateral = 2;

// Mask/ROI mode and tool mirror OPENCFU_MASK_*/OPENCFU_MASK_TOOL_*.
const int _maskNone = 0;
const int _maskDraw = 2;
const int _maskAuto = 3;
const int _maskToolCircle = 0;
const int _maskToolPolygon = 1;

const int _maskInMaxPoints = 32;

/// WebAssembly-backed engine for browsers: calls the same vendored OpenCFU
/// processor as Android/iOS/desktop (native/opencfu_core/wasm/), compiled to
/// WASM via Emscripten instead of linked as a native library. See
/// docs/BUILD.md's web WASM section and native/opencfu_core/wasm/README.md
/// for how it was built and how this bridges to it.
///
/// The actual module load/call/marshal work happens in
/// web/opencfu/opencfu_web_bridge.js (loaded from web/index.html), reached
/// here through one `window.opencfuAnalyze()` call -- deliberately a single,
/// simply-typed entry point rather than having Dart construct Embind's
/// vector/value_object types directly over js_interop.
class WasmOpenCfuEngine extends OpenCfuEngine {
  Uint8List? _classifierBytes;

  Future<Uint8List> _ensureClassifierBytes() async {
    final cached = _classifierBytes;
    if (cached != null) return cached;
    final data = await rootBundle.load('assets/opencfu/data/trainedClassifier.xml');
    final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    _classifierBytes = bytes;
    return bytes;
  }

  @override
  Future<OpenCfuAnalysis> analyze({
    required XFile image,
    required AppMode mode,
    required CaptureOptions options,
  }) async {
    Uint8List classifierBytes;
    Uint8List imageBytes;
    try {
      classifierBytes = await _ensureClassifierBytes();
      imageBytes = await image.readAsBytes();
    } catch (error) {
      return _unavailableAnalysis('Could not prepare analysis input: $error');
    }

    final jsOptions = _toJsOptions(options);

    final _JsAnalyzeResult result;
    try {
      final promise = _opencfuAnalyze(imageBytes.toJS, classifierBytes.toJS, jsOptions);
      result = (await promise.toDart) as _JsAnalyzeResult;
    } catch (error) {
      return _unavailableAnalysis('OpenCFU WebAssembly module failed: $error');
    }

    if (!result.ok) {
      return _unavailableAnalysis(result.errorMessage.isEmpty ? 'WebAssembly OpenCFU analysis failed' : result.errorMessage);
    }

    final markers = <ColonyMarker>[];
    final colonies = result.colonies.toDart;
    for (final colony in colonies) {
      final cornerX = colony.cornerX.toDart;
      final cornerY = colony.cornerY.toDart;
      markers.add(
        ColonyMarker(
          center: Offset(colony.cx, colony.cy),
          corners: <Offset>[
            for (var i = 0; i < 4; i++) Offset(cornerX[i].toDartDouble, cornerY[i].toDartDouble),
          ],
          radius: colony.radius.toDouble(),
          valid: colony.valid,
        ),
      );
    }

    final maskContour = <Offset>[];
    if (result.maskApplied) {
      final maskX = result.maskPointsX.toDart;
      final maskY = result.maskPointsY.toDart;
      for (var i = 0; i < maskX.length; i++) {
        maskContour.add(Offset(maskX[i].toDartDouble, maskY[i].toDartDouble));
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
  }

  _JsAnalyzeOptions _toJsOptions(CaptureOptions options) {
    final thresholdMode = switch (options.thresholdMode) {
      ThresholdMode.normal => _thrNormal,
      ThresholdMode.inverted => _thrInverted,
      ThresholdMode.bilateral => _thrBilateral,
    };
    final maskType = switch (options.maskMode) {
      MaskMode.none => _maskNone,
      MaskMode.auto => _maskAuto,
      MaskMode.draw => _maskDraw,
    };
    final maskTool = switch (options.maskTool) {
      MaskTool.circle => _maskToolCircle,
      MaskTool.polygon => _maskToolPolygon,
    };

    final points = options.maskPoints;
    final pointCount = options.maskMode == MaskMode.draw ? points.length.clamp(0, _maskInMaxPoints) : 0;
    final maskPointsX = <double>[for (var i = 0; i < pointCount; i++) points[i].dx];
    final maskPointsY = <double>[for (var i = 0; i < pointCount; i++) points[i].dy];

    return _JsAnalyzeOptions(
      thresholdMode: thresholdMode,
      autoThreshold: options.autoThreshold,
      threshold: (options.threshold.clamp(0.0, 1.0) * 255).round(),
      minRadius: options.minRadius.round(),
      maxRadius: options.maxRadius.round(),
      hasMaxRadius: options.hasMaxRadius,
      hueFilter: options.colourFilter,
      outlierFilter: options.outlierFilter,
      outlierThreshold: options.outlierThreshold,
      similarColours: options.similarColours,
      clusterDistance: options.clusterDistance,
      maskType: maskType,
      maskTool: maskTool,
      maskPointsX: maskPointsX.map((d) => d.toJS).toList().toJS,
      maskPointsY: maskPointsY.map((d) => d.toJS).toList().toJS,
    );
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

/// [WasmOpenCfuEngine] is the concrete implementation on web; the exported
/// name matches what `opencfu_engine.dart`'s conditional export expects
/// (mirroring FfiOpenCfuEngine on native).
typedef FfiOpenCfuEngine = WasmOpenCfuEngine;

// --- JS interop --------------------------------------------------------

@JS('opencfuAnalyze')
external JSPromise<JSAny?> _opencfuAnalyze(JSUint8Array imageBytes, JSUint8Array classifierBytes, _JsAnalyzeOptions options);

extension type _JsAnalyzeOptions._(JSObject _) implements JSObject {
  external factory _JsAnalyzeOptions({
    int thresholdMode,
    bool autoThreshold,
    int threshold,
    int minRadius,
    int maxRadius,
    bool hasMaxRadius,
    bool hueFilter,
    bool outlierFilter,
    double outlierThreshold,
    bool similarColours,
    double clusterDistance,
    int maskType,
    int maskTool,
    JSArray<JSNumber> maskPointsX,
    JSArray<JSNumber> maskPointsY,
  });
}

extension type _JsAnalyzeResult._(JSObject _) implements JSObject {
  external bool get ok;
  external String get errorMessage;
  external int get colonyCount;
  external int get totalCount;
  external int get imageWidth;
  external int get imageHeight;
  external bool get maskApplied;
  external JSArray<JSNumber> get maskPointsX;
  external JSArray<JSNumber> get maskPointsY;
  external JSArray<_JsColony> get colonies;
}

extension type _JsColony._(JSObject _) implements JSObject {
  external double get cx;
  external double get cy;
  external JSArray<JSNumber> get cornerX;
  external JSArray<JSNumber> get cornerY;
  external int get radius;
  external bool get valid;
}
