#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>
#include <opencv2/dnn.hpp>
#include <jni.h>
#include <android/log.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <exception>
#include <memory>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

// NOTE: this path points into a Windows temp folder and will break on any other
// machine / clean checkout. Move panel_postprocess.h next to this file and use
// #include "panel_postprocess.h" instead.
#include "../../../../../../Users/USER/AppData/Local/Temp/panel_postprocess.h"

#define LOG_TAG "PanelShiftYolo"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

// Build with -DPANELSHIFT_PROFILE to log per-stage timings (ms) for every page.
#ifdef PANELSHIFT_PROFILE
#define PS_TICK(name) const int64 name = cv::getTickCount()
#define PS_MS(a, b) (static_cast<double>((b) - (a)) * 1000.0 / cv::getTickFrequency())
#else
#define PS_TICK(name) ((void)0)
#endif

namespace {

// Model input edge. The model is fed the whole page stretched to 640x640 (as
// before), so normalised output coordinates map 1:1 back onto the page.
constexpr int kInputSize = 640;
constexpr float kConfThreshold = 0.40f;

// Sanity limits for the caller's buffer and the model output. Anything outside
// them is treated as a failure and answered with the full-page fallback.
constexpr int kMaxImageEdge = 16384;
constexpr int kMaxAnchors = 100000;

// Minimum grey-level standard deviation (0..255) of a panel. Measured on the
// 640px thumbnail, where fine texture is averaged out; if you see real panels
// rejected, lower this a little (e.g. 12).
constexpr double kMinStdDev = 15.0;

// The pixels handed in are RGB. The old code asked blobFromImage to swap R and
// B on an image that was already RGB, i.e. it fed the network BGR. Ultralytics
// models expect RGB. Set to true only if your model was trained on BGR input.
constexpr bool kSwapRB = false;

// Worker threads OpenCV may use for resize / cvtColor / the DNN CPU backend.
// 4 = one thread per big core on a 4+4 SoC such as the Snapdragon 685 in the
// Honor Pad 9. NOTE: this caps the thread COUNT; it does not pin threads to
// cores, so the kernel scheduler still decides where they run. With fewer than
// kDnnThreads big cores the extra threads simply share them. Measure with
// PANELSHIFT_PROFILE before changing (try 2 and 4). 0 = leave OpenCV's default.
constexpr int kDnnThreads = 4;

std::mutex g_mutex;                    // serialises init + inference (Net is not thread-safe)
std::unique_ptr<cv::dnn::Net> g_net;   // guarded by g_mutex

// Buffers reused by every call (all guarded by g_mutex). OpenCV only
// reallocates a Mat when its size/type changes, and every buffer below is
// always 640x640 with the same type, so after the first page there is no
// per-page heap allocation for the intermediates and nothing to fragment.
cv::Mat g_blob;        // 1x3x640x640 float input tensor
cv::Mat g_small_rgba;  // 640x640 RGBA, resized page
cv::Mat g_rgb;         // 640x640 RGB
cv::Mat g_gray;        // 640x640 grey thumbnail for the flat-region check
std::vector<panelshift::Box> g_candidates;  // capacity kept between calls
std::vector<panelshift::Box> g_textured;    // capacity kept between calls

inline float clamp01(float v) { return std::max(0.0f, std::min(1.0f, v)); }
inline int clampi(int v, int lo, int hi) { return std::max(lo, std::min(hi, v)); }

// Whole page as a single panel: used for covers / splash pages and whenever
// inference cannot run. Returns 0 (no panels) only if there is no output buffer.
int write_full_page(float* out_rects, int max_panels) {
    if (out_rects == nullptr || max_panels <= 0) return 0;
    out_rects[0] = 0.0f;
    out_rects[1] = 0.0f;
    out_rects[2] = 1.0f;
    out_rects[3] = 1.0f;
    return 1;
}

}  // namespace

extern "C" {

// 1. Loads the ONNX model and runs one warm-up inference, so the first real
//    page does not pay for graph setup. Called once, from the Dart worker
//    isolate. Returns 1 when the model is ready, 0 otherwise.
__attribute__((visibility("default"))) __attribute__((used))
int initYoloModel(const char* model_path_cstr) {
    if (model_path_cstr == nullptr) {
        LOGE("Model path C-string is null.");
        return 0;
    }

    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_net && !g_net->empty()) return 1;

    const std::string model_path(model_path_cstr);
    LOGI("Loading YOLO model from: %s", model_path.c_str());

    try {
        if (kDnnThreads > 0) cv::setNumThreads(kDnnThreads);

        cv::dnn::Net net = cv::dnn::readNetFromONNX(model_path);
        if (net.empty()) {
            LOGE("OpenCV readNetFromONNX returned an empty network.");
            return 0;
        }
        net.setPreferableBackend(cv::dnn::DNN_BACKEND_OPENCV);
        net.setPreferableTarget(cv::dnn::DNN_TARGET_CPU);

        // Allocate the pooled buffers now (and warm the net with the same
        // shapes), so the first real page pays no allocation cost either.
        g_small_rgba.create(kInputSize, kInputSize, CV_8UC4);
        g_rgb.create(kInputSize, kInputSize, CV_8UC3);
        g_gray.create(kInputSize, kInputSize, CV_8UC1);
        g_candidates.reserve(256);
        g_textured.reserve(64);

        g_rgb.setTo(cv::Scalar(255, 255, 255));
        cv::dnn::blobFromImage(g_rgb, g_blob, 1.0 / 255.0, cv::Size(kInputSize, kInputSize),
                               cv::Scalar(), kSwapRB, false, CV_32F);
        net.setInput(g_blob);
        net.forward();  // warm-up

        g_net.reset(new cv::dnn::Net(net));
        LOGI("YOLO ONNX model loaded and warmed up (threads=%d).", cv::getNumThreads());
        return 1;
    } catch (const cv::Exception& e) {
        LOGE("OpenCV exception during model load: %s", e.what());
    } catch (const std::exception& e) {
        LOGE("Standard exception during model load: %s", e.what());
    } catch (...) {
        LOGE("Unknown exception during model load.");
    }
    g_net.reset();
    return 0;
}

// 2. Dummy stub for document corners
JNIEXPORT jint JNICALL
Java_com_panelshift_engine_PanelShiftNativeBridge_detectDocumentCorners(
        JNIEnv* env, jobject thiz, jlong native_handle) {
    return 1;
}

// 3. Runs YOLO on an RGBA page buffer (any size) and writes up to max_panels
//    normalised rects (x, y, w, h) in reading order. Returns the panel count.
//    Never throws and never returns 0 for a valid call: every failure path
//    answers with the full page as one panel.
__attribute__((visibility("default"))) __attribute__((used))
int process_comic_panels(
        uint8_t* pixel_data,
        int width,
        int height,
        float* out_rects,
        int max_panels
) {
    if (pixel_data == nullptr || out_rects == nullptr || width <= 0 || height <= 0 ||
        max_panels <= 0 || width > kMaxImageEdge || height > kMaxImageEdge) {
        LOGE("Invalid arguments passed to native core (w=%d h=%d max=%d).", width, height, max_panels);
        return 0;
    }

    std::lock_guard<std::mutex> lock(g_mutex);

    if (!g_net || g_net->empty()) {
        LOGE("YOLO model not loaded. Falling back to full-page panel.");
        return write_full_page(out_rects, max_panels);
    }

    // A C++ exception must never cross the FFI boundary: it would abort the app.
    try {
        PS_TICK(t0);

        // --- Pre-processing: ONE resize straight from the caller's buffer into a
        // pooled 640x640 RGBA buffer, then ONE colour conversion into a pooled RGB
        // buffer. INTER_AREA is the right filter for shrinking; INTER_LINEAR if we
        // have to enlarge.
        const cv::Mat frame(height, width, CV_8UC4, pixel_data);  // header only, no copy
        const int interpolation =
            (width >= kInputSize && height >= kInputSize) ? cv::INTER_AREA : cv::INTER_LINEAR;
        cv::resize(frame, g_small_rgba, cv::Size(kInputSize, kInputSize), 0, 0, interpolation);
        cv::cvtColor(g_small_rgba, g_rgb, cv::COLOR_RGBA2RGB);

        // Already 640x640, so blobFromImage only scales to 0..1 (into g_blob's memory).
        cv::dnn::blobFromImage(g_rgb, g_blob, 1.0 / 255.0, cv::Size(kInputSize, kInputSize),
                               cv::Scalar(), kSwapRB, false, CV_32F);
        PS_TICK(t1);

        g_net->setInput(g_blob);
        cv::Mat output = g_net->forward();
        PS_TICK(t2);

        // --- Output tensor: [1, 4+nc, anchors] (YOLOv8 default) or the transposed
        // [1, anchors, 4+nc]. Rows 0..3 are cx, cy, w, h in 640px model space;
        // rows 4.. are class scores (one row for a single-class panel model).
        // Every mismatch bails out right here, before any pointer is formed.
        if (output.empty() || output.dims != 3 || output.depth() != CV_32F || output.size[0] != 1) {
            LOGE("Unexpected detection tensor (dims=%d). Falling back to full page.", output.dims);
            return write_full_page(out_rects, max_panels);
        }
        const int d1 = output.size[1];
        const int d2 = output.size[2];
        const bool transposed = d1 > d2;
        const int rows = transposed ? d2 : d1;
        const int cols = transposed ? d1 : d2;
        if (rows < 5 || cols <= 0 || cols > kMaxAnchors) {
            LOGE("Unexpected detection tensor shape [1,%d,%d]. Falling back to full page.", d1, d2);
            return write_full_page(out_rects, max_panels);
        }

        const cv::Mat contiguous = output.isContinuous() ? output : output.clone();
        if (!contiguous.isContinuous() ||
            contiguous.total() < static_cast<size_t>(rows) * static_cast<size_t>(cols)) {
            LOGE("Detection tensor is smaller than its shape says. Falling back to full page.");
            return write_full_page(out_rects, max_panels);
        }
        const float* data = reinterpret_cast<const float*>(contiguous.data);

        // Element (r, c) lives at data[r * stride_r + c * stride_c]; picking the
        // strides once removes the layout branch from the inner loop.
        const size_t stride_r = transposed ? 1 : static_cast<size_t>(cols);
        const size_t stride_c = transposed ? static_cast<size_t>(rows) : 1;
        auto at = [&](int r, int c) -> float {
            return data[static_cast<size_t>(r) * stride_r + static_cast<size_t>(c) * stride_c];
        };

        g_candidates.clear();  // keeps capacity: no reallocation after warm-up
        const float inv_input = 1.0f / static_cast<float>(kInputSize);
        for (int i = 0; i < cols; ++i) {
            float confidence = at(4, i);
            for (int k = 5; k < rows; ++k) confidence = std::max(confidence, at(k, i));
            if (!(confidence > kConfThreshold)) continue;  // also rejects NaN

            const float cx = at(0, i);
            const float cy = at(1, i);
            const float w = at(2, i);
            const float h = at(3, i);
            if (!std::isfinite(cx) || !std::isfinite(cy) || !std::isfinite(w) || !std::isfinite(h)) continue;

            const float x0 = clamp01((cx - 0.5f * w) * inv_input);
            const float y0 = clamp01((cy - 0.5f * h) * inv_input);
            const float x1 = clamp01((cx + 0.5f * w) * inv_input);
            const float y1 = clamp01((cy + 0.5f * h) * inv_input);
            g_candidates.push_back(panelshift::Box{x0, y0, x1 - x0, y1 - y0, confidence});
        }

        // --- Post-processing (see panel_postprocess.h) --------------------------
        panelshift::Params params;
        params.page_aspect = static_cast<float>(width) / static_cast<float>(height);

        // nms takes its input by value: move the pooled vector in (its buffer goes
        // with it, and is re-reserved below only when it was actually consumed).
        std::vector<panelshift::Box> boxes = panelshift::nms(std::move(g_candidates), params);
        g_candidates.clear();
        if (g_candidates.capacity() < 256) g_candidates.reserve(256);
        boxes = panelshift::filter_geometry(boxes, params);
        boxes = panelshift::merge_fragments(std::move(boxes), params);

        // Flat-region check, AFTER merging: a flat fragment of a real panel is
        // absorbed into it first, instead of being dropped and leaving a hole.
        // It runs on views into ONE pooled 640px grey thumbnail.
        if (!boxes.empty()) {
            cv::cvtColor(g_rgb, g_gray, cv::COLOR_RGB2GRAY);

            g_textured.clear();
            for (const panelshift::Box& b : boxes) {
                const int x0 = clampi(static_cast<int>(std::floor(b.x * kInputSize)), 0, kInputSize - 1);
                const int y0 = clampi(static_cast<int>(std::floor(b.y * kInputSize)), 0, kInputSize - 1);
                const int x1 = clampi(static_cast<int>(std::ceil(b.right() * kInputSize)), x0 + 1, kInputSize);
                const int y1 = clampi(static_cast<int>(std::ceil(b.bottom() * kInputSize)), y0 + 1, kInputSize);

                cv::Scalar mean, stddev;
                cv::meanStdDev(g_gray(cv::Rect(x0, y0, x1 - x0, y1 - y0)), mean, stddev);
                if (stddev[0] >= kMinStdDev) g_textured.push_back(b);
            }
            boxes.assign(g_textured.begin(), g_textured.end());
        }

        // DYNAMIC FALLBACK FOR COVERS & RECAP PAGES: nothing valid left, so the
        // whole page is one panel instead of leaving it empty.
        if (boxes.empty()) {
            boxes.push_back(panelshift::Box{0.0f, 0.0f, 1.0f, 1.0f, 1.0f});
        }

        panelshift::sort_reading_order(boxes, params);

        const int panel_count = std::min(max_panels, static_cast<int>(boxes.size()));
        for (int i = 0; i < panel_count; ++i) {
            out_rects[i * 4 + 0] = boxes[i].x;
            out_rects[i * 4 + 1] = boxes[i].y;
            out_rects[i * 4 + 2] = boxes[i].w;
            out_rects[i * 4 + 3] = boxes[i].h;
        }

#ifdef PANELSHIFT_PROFILE
        PS_TICK(t3);
        LOGI("panels=%d  input=%dx%d  pre=%.1fms  forward=%.1fms  post=%.1fms",
             panel_count, width, height, PS_MS(t0, t1), PS_MS(t1, t2), PS_MS(t2, t3));
#else
        LOGI("YOLO extracted %d comic panels.", panel_count);
#endif
        return panel_count;
    } catch (const cv::Exception& e) {
        LOGE("OpenCV exception during inference: %s", e.what());
    } catch (const std::exception& e) {  // includes std::bad_alloc
        LOGE("Standard exception during inference: %s", e.what());
    } catch (...) {
        LOGE("Unknown exception during inference.");
    }
    return write_full_page(out_rects, max_panels);
}

}  // extern "C"
