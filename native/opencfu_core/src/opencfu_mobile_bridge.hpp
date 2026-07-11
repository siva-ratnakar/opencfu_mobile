#ifndef OPENCFU_MOBILE_BRIDGE_HPP
#define OPENCFU_MOBILE_BRIDGE_HPP

#include <stddef.h>

/*
 * On Android this links into libopencfu_mobile.so, whose whole dynamic symbol
 * table is exported by default -- dart:ffi's DynamicLibrary.open() just works.
 * On iOS there is no separate shared library: this compiles straight into the
 * app (or, under CocoaPods' use_frameworks!, its own embedded framework), and
 * dart:ffi finds it via DynamicLibrary.process(), which needs the symbol to
 * survive linking even though nothing in Swift/Objective-C ever calls it
 * directly. Force default visibility (in case a pod-level -fvisibility=hidden
 * is in effect) and mark it `used` so the linker doesn't dead-strip an
 * apparently-unreferenced function.
 */
#if defined(__GNUC__) || defined(__clang__)
#define OPENCFU_MOBILE_EXPORT __attribute__((visibility("default"), used))
#else
#define OPENCFU_MOBILE_EXPORT
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* Threshold modes mirror the OCFU_THR_* macros in defines.hpp. */
#define OPENCFU_THR_NORM 0
#define OPENCFU_THR_INV 1
#define OPENCFU_THR_BILAT 2

/*
 * Mask/ROI modes mirror the MASK_TYPE_* and MASK_TOOL_* macros in defines.hpp.
 * Mobile never uses MASK_TYPE_FILE (no "load mask from file" flow).
 */
#define OPENCFU_MASK_NONE 0
#define OPENCFU_MASK_DRAW 2
#define OPENCFU_MASK_AUTO 3

#define OPENCFU_MASK_TOOL_CIRCLE 0
#define OPENCFU_MASK_TOOL_POLYGON 1

/* Caller-supplied points (OPENCFU_MASK_DRAW) and returned mask boundary. */
#define OPENCFU_MASK_MAX_POINTS 32
#define OPENCFU_MASK_OUT_MAX_POINTS 64

/*
 * Options passed from Dart. This is a flat, ABI-stable mirror of the subset of
 * ProcessingOptions that the mobile UI exposes. Booleans are ints (0/1).
 */
typedef struct OpenCfuOptions {
    int threshold_mode;        /* OPENCFU_THR_* */
    int auto_threshold;        /* bool: auto-detect the threshold value */
    int threshold;             /* 0..255, used only when auto_threshold == 0 */
    int min_radius;            /* pixels */
    int max_radius;            /* pixels, used only when has_max_radius == 1 */
    int has_max_radius;        /* bool: 0 means "auto max" (no upper bound) */
    int hue_filter;            /* bool: colour (hue/sat) filter */
    int outlier_filter;        /* bool */
    double outlier_threshold;  /* likelihood threshold, OpenCFU default 30 */
    int similar_colours;       /* bool: colour clustering */
    double cluster_distance;   /* L*a*b* clustering distance, used when similar_colours == 1 */

    /* Plate mask/ROI -- colonies outside the mask are rejected. */
    int mask_type;              /* OPENCFU_MASK_* */
    int mask_tool;               /* OPENCFU_MASK_TOOL_*, used only when mask_type == OPENCFU_MASK_DRAW */
    int mask_point_count;        /* 0..OPENCFU_MASK_MAX_POINTS, used only when mask_type == OPENCFU_MASK_DRAW */
    float mask_points_x[OPENCFU_MASK_MAX_POINTS];  /* source-image pixel coords */
    float mask_points_y[OPENCFU_MASK_MAX_POINTS];
} OpenCfuOptions;

/*
 * One detected object. Coordinates are in source-image pixels. (cx, cy) is the
 * centre and (corner_x[i], corner_y[i]) are the four corners of the object's
 * rotated bounding box, in the same order OpenCFU's OneObjectRow::getPoint()
 * returns them, so the Flutter overlay can draw exactly what the desktop draws.
 */
typedef struct OpenCfuColony {
    float cx;
    float cy;
    float corner_x[4];
    float corner_y[4];
    int radius;
    int valid;                 /* bool: counted as a valid colony */
} OpenCfuColony;

typedef struct OpenCfuBridgeResult {
    int colony_count;          /* number of valid colonies (Result::getNValid) */
    int total_count;           /* number of detected objects (valid + invalid) */
    int returned_count;        /* number of colonies written to out_colonies */
    int image_width;
    int image_height;
    int valid;                 /* bool: analysis succeeded */
    char error_message[512];

    /*
     * The mask boundary actually applied during this analysis, if any -- for
     * OPENCFU_MASK_AUTO this reveals what the Hough-circle detector found; for
     * OPENCFU_MASK_DRAW it echoes back the rasterised shape. Lets the Flutter
     * overlay draw exactly what was applied without duplicating any geometry
     * logic. mask_applied == 0 means no mask was applied (mask_point_count is
     * then 0 and the points arrays are unused).
     */
    int mask_applied;          /* bool */
    int mask_point_count;      /* 0..OPENCFU_MASK_OUT_MAX_POINTS */
    float mask_points_x[OPENCFU_MASK_OUT_MAX_POINTS];
    float mask_points_y[OPENCFU_MASK_OUT_MAX_POINTS];
} OpenCfuBridgeResult;

/*
 * Analyse one image.
 *
 *   image_path      absolute path to the captured/imported image.
 *   classifier_dir  directory that contains `data/trainedClassifier.xml` and
 *                   `data/trainedClassifierPS.xml`. The bridge chdir()s here for
 *                   the duration of the call so the vendored Processor finds the
 *                   classifiers via their relative paths, then restores the cwd.
 *   options         processing options (may be NULL for OpenCFU defaults).
 *   out_result      required output header (counts, image size, error string).
 *   out_colonies    optional caller-allocated buffer for per-colony markers.
 *   max_colonies    capacity of out_colonies (0 if out_colonies is NULL).
 *
 * Returns 0 on success, negative on failure (out_result->error_message is set).
 */
OPENCFU_MOBILE_EXPORT
int opencfu_mobile_analyze_image(const char* image_path,
                                 const char* classifier_dir,
                                 const OpenCfuOptions* options,
                                 OpenCfuBridgeResult* out_result,
                                 OpenCfuColony* out_colonies,
                                 int max_colonies);

#ifdef __cplusplus
}
#endif

#endif
