import 'dart:ui' show Offset;

import 'package:image_picker/image_picker.dart';

import '../app_mode.dart';
import '../capture_options.dart';

/// One detected object, in source-image pixel coordinates. [corners] are the
/// four corners of the rotated bounding box, in the same order OpenCFU's
/// desktop app draws them, when this came from the native core. Markers the
/// operator adds by hand (to fix a colony the algorithm missed) have no
/// corners and are drawn as a plain circle instead; [manual] flags those so
/// the overlay can tell them apart from what the algorithm found.
class ColonyMarker {
  const ColonyMarker({
    required this.center,
    required this.corners,
    required this.radius,
    required this.valid,
    this.manual = false,
  });

  final Offset center;
  final List<Offset> corners;
  final double radius;
  final bool valid;
  final bool manual;

  ColonyMarker copyWith({bool? valid}) => ColonyMarker(
        center: center,
        corners: corners,
        radius: radius,
        valid: valid ?? this.valid,
        manual: manual,
      );
}

/// Result of analysing one plate image.
class OpenCfuAnalysis {
  const OpenCfuAnalysis({
    required this.colonyCount,
    required this.overlayLabel,
    this.totalCount = 0,
    this.imageWidth = 0,
    this.imageHeight = 0,
    this.markers = const <ColonyMarker>[],
    this.maskContour = const <Offset>[],
    this.available = true,
    this.errorMessage,
  });

  /// Number of valid colonies.
  final int colonyCount;

  /// A short human-readable status line shown under the count.
  final String overlayLabel;

  /// Total detected objects (valid + rejected).
  final int totalCount;

  final int imageWidth;
  final int imageHeight;

  /// Per-object markers for drawing the overlay. Empty when unavailable.
  final List<ColonyMarker> markers;

  /// The plate mask boundary actually applied (auto-detected or drawn), in
  /// source-image pixel coordinates. Empty when no mask was applied.
  final List<Offset> maskContour;

  /// False when the native engine could not run (e.g. library not linked).
  final bool available;

  final String? errorMessage;

  bool get hasImageSize => imageWidth > 0 && imageHeight > 0;
}

/// Contract implemented by both the native (FFI) engine and the stub.
abstract class OpenCfuEngine {
  const OpenCfuEngine();

  Future<OpenCfuAnalysis> analyze({
    required XFile image,
    required AppMode mode,
    required CaptureOptions options,
  });
}
