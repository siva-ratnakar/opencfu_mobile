// Web (WebAssembly) entry point for the OpenCFU core.
//
// Wraps the existing, unmodified opencfu_mobile_analyze_image() C ABI (see
// ../src/opencfu_mobile_bridge.{hpp,cpp}, shared verbatim with Android/iOS)
// behind an Embind binding instead of exposing the raw C function directly.
// Embind auto-generates the JS<->C++ marshaling for the request/response
// structs (numbers, strings, vectors, nested objects) -- hand-rolling that
// over emcc's ccall/heap-offset API would mean keeping a second, error-prone
// copy of every struct's exact field layout in JS, with no way to verify it
// short of running it in a real browser. Embind removes that whole class of
// bug.
//
// The image itself is still handed to the underlying bridge as a path, same
// as Android/iOS -- the caller (lib/services/opencfu_engine_web.dart) writes
// the picked photo's bytes into Emscripten's virtual filesystem (via
// Module.FS, exported through -sFORCE_FILESYSTEM=1) before calling analyze(),
// and does the same for the classifier XML files under classifierDir. See
// wasm/README.md.

#include <algorithm>
#include <string>
#include <vector>

#include <emscripten/bind.h>

#include "opencfu_mobile_bridge.hpp"

namespace {

struct WasmColony {
    float cx = 0;
    float cy = 0;
    float cornerX0 = 0;
    float cornerY0 = 0;
    float cornerX1 = 0;
    float cornerY1 = 0;
    float cornerX2 = 0;
    float cornerY2 = 0;
    float cornerX3 = 0;
    float cornerY3 = 0;
    int radius = 0;
    bool valid = false;
};

struct WasmResult {
    bool ok = false;
    std::string errorMessage;
    int colonyCount = 0;
    int totalCount = 0;
    int imageWidth = 0;
    int imageHeight = 0;
    bool maskApplied = false;
    std::vector<float> maskPointsX;
    std::vector<float> maskPointsY;
    std::vector<WasmColony> colonies;
};

// Caller-supplied cap on returned markers -- mirrors the max_colonies
// argument every other platform's bridge caller passes. Generous enough that
// no real plate photo should ever hit it.
constexpr int kMaxColonies = 4096;

WasmResult analyze(
    const std::string& imagePath,
    const std::string& classifierDir,
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
    const std::vector<float>& maskPointsX,
    const std::vector<float>& maskPointsY
) {
    OpenCfuOptions opts{};
    opts.threshold_mode = thresholdMode;
    opts.auto_threshold = autoThreshold ? 1 : 0;
    opts.threshold = threshold;
    opts.min_radius = minRadius;
    opts.max_radius = maxRadius;
    opts.has_max_radius = hasMaxRadius ? 1 : 0;
    opts.hue_filter = hueFilter ? 1 : 0;
    opts.outlier_filter = outlierFilter ? 1 : 0;
    opts.outlier_threshold = outlierThreshold;
    opts.similar_colours = similarColours ? 1 : 0;
    opts.cluster_distance = clusterDistance;
    opts.mask_type = maskType;
    opts.mask_tool = maskTool;

    const int pointCount = std::min({
        static_cast<int>(maskPointsX.size()),
        static_cast<int>(maskPointsY.size()),
        OPENCFU_MASK_MAX_POINTS,
    });
    opts.mask_point_count = pointCount;
    for (int i = 0; i < pointCount; ++i) {
        opts.mask_points_x[i] = maskPointsX[static_cast<size_t>(i)];
        opts.mask_points_y[i] = maskPointsY[static_cast<size_t>(i)];
    }

    OpenCfuBridgeResult result{};
    std::vector<OpenCfuColony> colonies(kMaxColonies);

    const int rc = opencfu_mobile_analyze_image(
        imagePath.c_str(), classifierDir.c_str(), &opts, &result, colonies.data(), kMaxColonies);

    WasmResult out;
    out.ok = (rc == 0) && result.valid != 0;
    out.errorMessage = std::string(result.error_message);
    out.colonyCount = result.colony_count;
    out.totalCount = result.total_count;
    out.imageWidth = result.image_width;
    out.imageHeight = result.image_height;
    out.maskApplied = result.mask_applied != 0;

    out.maskPointsX.reserve(static_cast<size_t>(result.mask_point_count));
    out.maskPointsY.reserve(static_cast<size_t>(result.mask_point_count));
    for (int i = 0; i < result.mask_point_count; ++i) {
        out.maskPointsX.push_back(result.mask_points_x[i]);
        out.maskPointsY.push_back(result.mask_points_y[i]);
    }

    out.colonies.reserve(static_cast<size_t>(result.returned_count));
    for (int i = 0; i < result.returned_count; ++i) {
        const OpenCfuColony& c = colonies[static_cast<size_t>(i)];
        WasmColony wc;
        wc.cx = c.cx;
        wc.cy = c.cy;
        wc.cornerX0 = c.corner_x[0];
        wc.cornerY0 = c.corner_y[0];
        wc.cornerX1 = c.corner_x[1];
        wc.cornerY1 = c.corner_y[1];
        wc.cornerX2 = c.corner_x[2];
        wc.cornerY2 = c.corner_y[2];
        wc.cornerX3 = c.corner_x[3];
        wc.cornerY3 = c.corner_y[3];
        wc.radius = c.radius;
        wc.valid = c.valid != 0;
        out.colonies.push_back(wc);
    }
    return out;
}

} // namespace

// Emscripten's "executable" target type (see CMakeLists.txt's
// add_executable()) needs a main symbol to link, even though this module is
// only ever used as a library from JS -- it does nothing.
int main() {
    return 0;
}

EMSCRIPTEN_BINDINGS(opencfu_module) {
    emscripten::register_vector<float>("VectorFloat");

    emscripten::value_object<WasmColony>("WasmColony")
        .field("cx", &WasmColony::cx)
        .field("cy", &WasmColony::cy)
        .field("cornerX0", &WasmColony::cornerX0)
        .field("cornerY0", &WasmColony::cornerY0)
        .field("cornerX1", &WasmColony::cornerX1)
        .field("cornerY1", &WasmColony::cornerY1)
        .field("cornerX2", &WasmColony::cornerX2)
        .field("cornerY2", &WasmColony::cornerY2)
        .field("cornerX3", &WasmColony::cornerX3)
        .field("cornerY3", &WasmColony::cornerY3)
        .field("radius", &WasmColony::radius)
        .field("valid", &WasmColony::valid);
    emscripten::register_vector<WasmColony>("VectorWasmColony");

    emscripten::value_object<WasmResult>("WasmResult")
        .field("ok", &WasmResult::ok)
        .field("errorMessage", &WasmResult::errorMessage)
        .field("colonyCount", &WasmResult::colonyCount)
        .field("totalCount", &WasmResult::totalCount)
        .field("imageWidth", &WasmResult::imageWidth)
        .field("imageHeight", &WasmResult::imageHeight)
        .field("maskApplied", &WasmResult::maskApplied)
        .field("maskPointsX", &WasmResult::maskPointsX)
        .field("maskPointsY", &WasmResult::maskPointsY)
        .field("colonies", &WasmResult::colonies);

    emscripten::function("analyze", &analyze);
}
