#include "opencfu_mobile_bridge.hpp"

#include <cmath>
#include <cstring>
#include <exception>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

#include <unistd.h>   // chdir, getcwd

#include "defines.hpp"
#include "processor/headers/ProcessingOptions.hpp"
#include "processor/headers/Processor.hpp"
#include "processor/headers/Result.hpp"

namespace {

// The vendored Processor resolves its classifier files relative to the current
// working directory, and OpenCV's global state is not thread-safe, so we make
// the whole analyse call mutually exclusive.
std::mutex g_analyze_mutex;

void set_error(OpenCfuBridgeResult* out_result, const std::string& message) {
    if (out_result == nullptr) {
        return;
    }
    out_result->colony_count = 0;
    out_result->total_count = 0;
    out_result->returned_count = 0;
    out_result->valid = 0;
    std::strncpy(out_result->error_message, message.c_str(), sizeof(out_result->error_message) - 1);
    out_result->error_message[sizeof(out_result->error_message) - 1] = '\0';
}

// Restores the process working directory when the analyse call returns.
class CwdGuard {
public:
    explicit CwdGuard(const char* target) : m_changed(false) {
        if (getcwd(m_saved, sizeof(m_saved)) == nullptr) {
            m_saved[0] = '\0';
        }
        if (target != nullptr && std::strlen(target) > 0) {
            m_changed = (chdir(target) == 0);
        }
    }
    ~CwdGuard() {
        if (m_changed && m_saved[0] != '\0') {
            if (chdir(m_saved) != 0) {
                // Nothing sensible to do on restore failure.
            }
        }
    }
    bool changed() const { return m_changed; }

private:
    char m_saved[4096];
    bool m_changed;
};

void apply_options(ProcessingOptions& po, const OpenCfuOptions* opts) {
    if (opts == nullptr) {
        // OpenCFU-compatible mobile "basic" defaults.
        po.setThrMode(OPENCFU_THR_INV);
        po.setHasAutoThr(true);
        po.setHasMaxRad(false);
        po.setMinMaxRad(std::make_pair(0, 50));
        po.setHasHueFilt(false);
        po.setHasOutlierFilt(true);
        po.setLikeThr(30.0);
        po.setHasClustDist(false);
        return;
    }

    po.setThrMode(opts->threshold_mode);
    po.setHasAutoThr(opts->auto_threshold != 0);
    if (opts->auto_threshold == 0) {
        po.setThr(opts->threshold);
    }

    const bool has_max = opts->has_max_radius != 0;
    po.setHasMaxRad(has_max);
    const int min_rad = opts->min_radius >= 0 ? opts->min_radius : 0;
    // When there is no explicit max, keep a generous upper bound; the filter is
    // disabled by has_max_radius == false so this value is not enforced.
    const int max_rad = has_max ? opts->max_radius : 9999;
    po.setMinMaxRad(std::make_pair(min_rad, max_rad < min_rad ? min_rad : max_rad));

    po.setHasHueFilt(opts->hue_filter != 0);
    po.setHasOutlierFilt(opts->outlier_filter != 0);
    po.setLikeThr(opts->outlier_threshold > 0 ? opts->outlier_threshold : 30.0);

    const bool cluster = opts->similar_colours != 0;
    po.setHasClustDist(cluster);
    if (cluster && opts->cluster_distance > 0) {
        po.setClustDist(opts->cluster_distance);
    }
}

// Desktop's MaskROI::circleFrom3 (MaskROI.cpp) does the same unchecked
// algebra; near-collinear points can make it produce a non-finite or
// negative radius, which desktop never guards against. We do, so a bad
// 3-point tap on mobile can't reach cv::circle() with garbage geometry.
bool three_point_circle_is_valid(const std::vector<cv::Point2f>& points) {
    const double x1 = points[0].x, y1 = points[0].y;
    const double x2 = points[1].x, y2 = points[1].y;
    const double x3 = points[2].x, y3 = points[2].y;

    const double f = x3 * x3 - x3 * x2 - x1 * x3 + x1 * x2 + y3 * y3 - y3 * y2 - y1 * y3 + y1 * y2;
    const double g = x3 * y1 - x3 * y2 + x1 * y2 - x1 * y3 + x2 * y3 - x2 * y1;
    const double m = (g == 0) ? 0.0 : (f / g);

    const double c = (m * y2) - x2 - x1 - (m * y1);
    const double d = (m * x1) - y1 - y2 - (x2 * m);
    const double e = (x1 * x2) + (y1 * y2) - (m * x1 * y2) + (m * x2 * y1);
    const double h = c / 2.0;
    const double k = d / 2.0;
    const double r = std::sqrt((h * h) + (k * k) - e);

    return std::isfinite(r) && r > 0.0;
}

// Builds the plate mask/ROI (if any) from opts->mask_* and applies it to po.
// Must run after po.setImage() -- MaskROI::setFromPoints() needs the image
// size, and MASK_TYPE_AUTO's Hough-circle detection needs the image itself.
void apply_mask(ProcessingOptions& po, const OpenCfuOptions* opts) {
    if (opts == nullptr || opts->mask_type == OPENCFU_MASK_NONE) {
        return;
    }

    if (opts->mask_type == OPENCFU_MASK_AUTO) {
        po.setMask(MaskROI(MASK_TYPE_AUTO));
        return;
    }

    if (opts->mask_type != OPENCFU_MASK_DRAW) {
        return;
    }

    const int tool = opts->mask_tool;
    const int count = opts->mask_point_count;
    const bool count_ok = (tool == OPENCFU_MASK_TOOL_CIRCLE && count == 3) ||
                           (tool == OPENCFU_MASK_TOOL_POLYGON && count >= 3);
    if (!count_ok || count > OPENCFU_MASK_MAX_POINTS) {
        // Bad input must never reach MaskROI::setFromPoints()/circleFrom3(),
        // which do unchecked indexing (assert-only, compiled out in release).
        return;
    }

    std::vector<cv::Point2f> points;
    points.reserve(static_cast<size_t>(count));
    for (int i = 0; i < count; ++i) {
        points.emplace_back(opts->mask_points_x[i], opts->mask_points_y[i]);
    }

    if (tool == OPENCFU_MASK_TOOL_CIRCLE && !three_point_circle_is_valid(points)) {
        return;
    }

    std::vector<std::pair<std::vector<cv::Point2f>, int>> shapes;
    shapes.emplace_back(points, tool);

    MaskROI mask;
    mask.setFromPoints(shapes, po.getImage().cols, po.getImage().rows);
    po.setMask(mask);
}

// Reports back the mask boundary actually applied (if any), so the Flutter
// overlay can draw exactly what OpenCFU used without duplicating any mask
// geometry logic on the Dart side.
void export_mask_contour(const ProcessingOptions& po, OpenCfuBridgeResult* out_result) {
    out_result->mask_applied = 0;
    out_result->mask_point_count = 0;

    const cv::Mat& mask_mat = po.getMask().getMat();
    if (mask_mat.empty()) {
        return;
    }

    std::vector<std::vector<cv::Point>> contours;
    cv::findContours(mask_mat.clone(), contours, cv::RETR_EXTERNAL, cv::CHAIN_APPROX_SIMPLE);
    if (contours.empty()) {
        return;
    }

    size_t largest = 0;
    double largest_area = 0.0;
    for (size_t i = 0; i < contours.size(); ++i) {
        const double area = cv::contourArea(contours[i]);
        if (area > largest_area) {
            largest_area = area;
            largest = i;
        }
    }

    const std::vector<cv::Point>& contour = contours[largest];
    if (contour.empty()) {
        return;
    }

    const int n = static_cast<int>(contour.size());
    const int written = n < OPENCFU_MASK_OUT_MAX_POINTS ? n : OPENCFU_MASK_OUT_MAX_POINTS;
    for (int i = 0; i < written; ++i) {
        // Evenly subsample rather than truncate, so a large contour (e.g. a
        // Hough-detected circle) still looks round instead of being cut off.
        const int src_index = static_cast<int>((static_cast<long long>(i) * n) / written);
        out_result->mask_points_x[i] = static_cast<float>(contour[src_index].x);
        out_result->mask_points_y[i] = static_cast<float>(contour[src_index].y);
    }
    out_result->mask_point_count = written;
    out_result->mask_applied = 1;
}

} // namespace

OPENCFU_MOBILE_EXPORT
int opencfu_mobile_analyze_image(const char* image_path,
                                 const char* classifier_dir,
                                 const OpenCfuOptions* options,
                                 OpenCfuBridgeResult* out_result,
                                 OpenCfuColony* out_colonies,
                                 int max_colonies) {
    if (out_result == nullptr) {
        return -1;
    }

    out_result->colony_count = 0;
    out_result->total_count = 0;
    out_result->returned_count = 0;
    out_result->image_width = 0;
    out_result->image_height = 0;
    out_result->valid = 0;
    out_result->error_message[0] = '\0';
    out_result->mask_applied = 0;
    out_result->mask_point_count = 0;

    if (image_path == nullptr || std::strlen(image_path) == 0) {
        set_error(out_result, "Missing image path");
        return -2;
    }

    std::lock_guard<std::mutex> lock(g_analyze_mutex);

    // chdir into the classifier directory so Processor's relative classifier
    // paths resolve; the guard restores the previous cwd on return.
    CwdGuard cwd(classifier_dir);

    try {
        ProcessingOptions po;
        if (!po.setImage(std::string(image_path))) {
            set_error(out_result, std::string("Could not read image: ") + image_path);
            return -2;
        }

        out_result->image_width = po.getImage().cols;
        out_result->image_height = po.getImage().rows;

        apply_options(po, options);
        apply_mask(po, options);

        Processor processor(po);
        processor.runAll();

        export_mask_contour(po, out_result);

        const Result& result = processor.getNumResult();
        out_result->colony_count = result.getNValid();
        out_result->total_count = static_cast<int>(result.size());

        int written = 0;
        if (out_colonies != nullptr && max_colonies > 0) {
            for (size_t i = 0; i < result.size() && written < max_colonies; ++i) {
                const OneObjectRow& row = result.getRow(i);
                OpenCfuColony& dst = out_colonies[written];
                cv::Point2f p0 = row.getPoint(0);
                cv::Point2f p2 = row.getPoint(2);
                dst.cx = (p0.x + p2.x) * 0.5f;
                dst.cy = (p0.y + p2.y) * 0.5f;
                for (int c = 0; c < 4; ++c) {
                    cv::Point2f pc = row.getPoint(c);
                    dst.corner_x[c] = pc.x;
                    dst.corner_y[c] = pc.y;
                }
                dst.radius = row.getRadius();
                dst.valid = row.isValid() ? 1 : 0;
                ++written;
            }
        }
        out_result->returned_count = written;
        out_result->valid = 1;
        return 0;
    } catch (const std::exception& exception) {
        set_error(out_result, exception.what());
        return -3;
    } catch (...) {
        set_error(out_result, "Unknown native OpenCFU error");
        return -4;
    }
}
