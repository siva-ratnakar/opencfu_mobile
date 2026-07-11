import 'dart:ui' show Offset;

/// Threshold mode, mirrors the OCFU_THR_* constants in the native core.
enum ThresholdMode { normal, inverted, bilateral }

/// Plate mask/ROI mode, mirrors the MASK_TYPE_* constants in the native core
/// (minus MASK_TYPE_FILE, which mobile never uses -- there is no "load mask
/// from file" flow here).
enum MaskMode { none, auto, draw }

/// Manual mask drawing tool, mirrors the MASK_TOOL_* constants in the native
/// core. Only meaningful when [CaptureOptions.maskMode] is [MaskMode.draw].
enum MaskTool { circle, polygon }

/// User-facing capture/processing options. These map onto the native
/// `OpenCfuOptions` struct consumed by the bridge (see
/// `services/opencfu_engine_native.dart`).
class CaptureOptions {
  const CaptureOptions({
    required this.thresholdMode,
    required this.autoThreshold,
    required this.threshold,
    required this.minRadius,
    required this.maxRadius,
    required this.hasMaxRadius,
    required this.maskMode,
    required this.maskTool,
    required this.maskPoints,
    required this.colourFilter,
    required this.outlierFilter,
    required this.outlierThreshold,
    required this.similarColours,
    required this.clusterDistance,
  });

  /// Basic mode, per the OpenCFU mobile spec:
  ///  - Threshold: inverted, auto
  ///  - Radius: auto-max with 0 minimum
  ///  - ROI and mask: auto-detected plate boundary
  ///  - Colour filter: disabled
  ///  - Outlier filter: auto, threshold 30
  ///  - Similar colours: disabled
  factory CaptureOptions.basic() => const CaptureOptions(
        thresholdMode: ThresholdMode.inverted,
        autoThreshold: true,
        threshold: 0.5,
        minRadius: 0,
        maxRadius: 50,
        hasMaxRadius: false,
        maskMode: MaskMode.auto,
        maskTool: MaskTool.circle,
        maskPoints: <Offset>[],
        colourFilter: false,
        outlierFilter: true,
        outlierThreshold: 30,
        similarColours: false,
        clusterDistance: 2.3,
      );

  /// Advanced mode starts from mostly-basic values, but leaves the mask off
  /// by default -- the operator picks None/Auto/Draw explicitly.
  factory CaptureOptions.advancedDefaults() => const CaptureOptions(
        thresholdMode: ThresholdMode.inverted,
        autoThreshold: true,
        threshold: 0.5,
        minRadius: 0,
        maxRadius: 50,
        hasMaxRadius: false,
        maskMode: MaskMode.none,
        maskTool: MaskTool.circle,
        maskPoints: <Offset>[],
        colourFilter: false,
        outlierFilter: true,
        outlierThreshold: 30,
        similarColours: false,
        clusterDistance: 2.3,
      );

  final ThresholdMode thresholdMode;
  final bool autoThreshold;

  /// Manual threshold, normalised 0..1 (mapped to 0..255 for the native core).
  /// Only used when [autoThreshold] is false.
  final double threshold;

  final double minRadius;
  final double maxRadius;

  /// When false the maximum radius is not enforced ("auto-max").
  final bool hasMaxRadius;

  final MaskMode maskMode;

  /// Which manual tool was used/is active. Only meaningful when [maskMode]
  /// is [MaskMode.draw].
  final MaskTool maskTool;

  /// Points tapped by the operator, in source-image pixel coordinates. Only
  /// meaningful when [maskMode] is [MaskMode.draw]: exactly 3 points for
  /// [MaskTool.circle], 3 or more for [MaskTool.polygon].
  final List<Offset> maskPoints;

  /// Colour (hue/saturation) filter.
  final bool colourFilter;

  final bool outlierFilter;

  /// Outlier likelihood threshold (OpenCFU default 30).
  final double outlierThreshold;

  /// Colour clustering ("similar colours").
  final bool similarColours;
  final double clusterDistance;

  bool get invertThreshold => thresholdMode == ThresholdMode.inverted;

  CaptureOptions copyWith({
    ThresholdMode? thresholdMode,
    bool? autoThreshold,
    double? threshold,
    double? minRadius,
    double? maxRadius,
    bool? hasMaxRadius,
    MaskMode? maskMode,
    MaskTool? maskTool,
    List<Offset>? maskPoints,
    bool? colourFilter,
    bool? outlierFilter,
    double? outlierThreshold,
    bool? similarColours,
    double? clusterDistance,
  }) {
    return CaptureOptions(
      thresholdMode: thresholdMode ?? this.thresholdMode,
      autoThreshold: autoThreshold ?? this.autoThreshold,
      threshold: threshold ?? this.threshold,
      minRadius: minRadius ?? this.minRadius,
      maxRadius: maxRadius ?? this.maxRadius,
      hasMaxRadius: hasMaxRadius ?? this.hasMaxRadius,
      maskMode: maskMode ?? this.maskMode,
      maskTool: maskTool ?? this.maskTool,
      maskPoints: maskPoints ?? this.maskPoints,
      colourFilter: colourFilter ?? this.colourFilter,
      outlierFilter: outlierFilter ?? this.outlierFilter,
      outlierThreshold: outlierThreshold ?? this.outlierThreshold,
      similarColours: similarColours ?? this.similarColours,
      clusterDistance: clusterDistance ?? this.clusterDistance,
    );
  }

  String get summary {
    final thr = autoThreshold ? 'thr auto' : 'thr ${(threshold * 100).round()}%';
    final mode = switch (thresholdMode) {
      ThresholdMode.inverted => 'inv',
      ThresholdMode.bilateral => 'bilat',
      ThresholdMode.normal => 'norm',
    };
    final rad = hasMaxRadius
        ? 'rad ${minRadius.round()}-${maxRadius.round()}'
        : 'rad ${minRadius.round()}+ (auto max)';
    final outlier = outlierFilter ? 'outlier ${outlierThreshold.round()}' : 'no outlier';
    final mask = switch (maskMode) {
      MaskMode.none => 'no mask',
      MaskMode.auto => 'auto mask',
      MaskMode.draw => 'drawn mask (${maskTool == MaskTool.circle ? 'circle' : 'polygon'})',
    };
    return '$thr ($mode) • $rad • $outlier • $mask';
  }
}
