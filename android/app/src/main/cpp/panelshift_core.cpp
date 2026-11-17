#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>
#include <opencv2/dnn.hpp>
#include <jni.h>
#include <android/log.h>

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <memory>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

// panel_postprocess.h (nms / filter_geometry / merge_fragments / sort_reading_order).
// Preferred layout: keep the header NEXT TO THIS FILE, it is then picked up
// automatically. The old Windows temp-folder path is kept only as a fallback so
// existing builds keep working; it breaks on any other machine / clean checkout,
// so once the header has been moved the #else branch can be deleted.
#if __has_include("panel_postprocess.h")
#include "panel_postprocess.h"
#else
#include "../../../../../../Users/USER/AppData/Local/Temp/panel_postprocess.h"
#endif

#define LOG_TAG "PanelShiftYolo"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

// Build with -DPANELSHIFT_PROFILE to log per-stage timings (ms) AND how many boxes
// survive each stage, for every page. That second line is the tool for tuning the
// thresholds below on real pages (see "stages raw=... final=..." in the log).
#ifdef PANELSHIFT_PROFILE
#define PS_TICK(name) const int64 name = cv::getTickCount()
#define PS_MS(a, b) (static_cast<double>((b) - (a)) * 1000.0 / cv::getTickFrequency())
#define PS_COUNT(name, expr) const size_t name = (expr)
#else
#define PS_TICK(name) ((void)0)
#define PS_COUNT(name, expr) ((void)0)
#endif

// Pipeline (everything runs on the page stretched to 640x640; boxes are 0..1):
//   resize -> pack CHW blob -> forward -> raw detections (> kConfThreshold)
//   -> nms (keeps the best Params::max_candidates = 300 by score) -> filter_geometry
//   -> drop_union_boxes -> merge_fragments -> flat-region check -> residue guard
//   -> sort_reading_order

namespace {

// Model input edge. The model is fed the whole page stretched to 640x640 (as
// before), so normalised output coordinates map 1:1 back onto the page.
constexpr int kInputSize = 640;

// ---- Thresholds ---------------------------------------------------------------
// kConfThreshold and kMinStdDev were reviewed and DELIBERATELY left as they were:
// where to put them depends on your model and your pages, and the right way to
// move them is to build with PANELSHIFT_PROFILE and watch the per-stage counts.

// Confidence a raw detection needs to enter post-processing at all. Raising it
// removes weak artifacts but also weak REAL panels (borderless, bleeding off the
// page), and a missed panel is story content the reader never zooms into, while
// an extra box costs one spare stop. Lowering it hands merge_fragments more weak
// pieces to reunite, at the price of more bubble / whitespace boxes.
constexpr float kConfThreshold = 0.40f;

// Minimum grey-level standard deviation (0..255) of a panel. Measured on the
// 640px thumbnail, where fine texture is averaged out; if you see real panels
// rejected, lower this a little (e.g. 12).
// What this check can and cannot do: 15 is roughly "at least ~0.35% black ink on
// white paper" (std = 255 * sqrt(p * (1 - p))), far above scan / JPEG noise and far
// below any real content, so it removes genuinely BLANK boxes (whitespace). It can
// not reject speech bubbles or captions: text plus outline is high-contrast. Those
// are a job for NMS / geometry (panel_postprocess.h), not for this number.
constexpr double kMinStdDev = 15.0;

// If everything that survives covers less than this share of the page, it is
// almost certainly residue (a lone bubble, caption or logo on a title / recap
// page) and the whole page is returned as one panel instead of zooming into it.
// Overlaps are counted twice, which can only make this trigger less often. Set to
// 0.0f to disable.
constexpr float kMinPageCoverage = 0.15f;

// ---- Post-processing switches -------------------------------------------------
// Two changes to panel_postprocess.h, each undone by one line so they can be compared
// with the previous behaviour on your own pages (PANELSHIFT_PROFILE shows what each
// one does). Both are tested on synthetic pages only, not on your detector's output.
//
// A weak box that spans two neighbouring panels would absorb both in merge_fragments
// and swallow the gutter between them (nothing else can: merge_fragments never
// bridges a gap). true drops such a box; false leaves it in.
constexpr bool kDropUnionBoxes = true;

// Reading order. false = row grouping only, exactly the previous behaviour. true =
// also split at a clear gap when a box spans several rows (a tall panel beside a
// stack), which row grouping gets right or wrong depending on a fraction of a percent
// of vertical offset. The price: on a plain grid that a stray box has distorted into a
// box spanning rows, the cut can read a block column by column (about 1% of such pages
// under harsh synthetic noise, 0.2% or less under typical noise).
constexpr bool kCutReadingOrder = true;

// ---- Limits & platform --------------------------------------------------------

// Sanity limits for the caller's buffer and the model output. Anything outside
// them is treated as a failure and answered with the full-page fallback.
constexpr int kMaxImageEdge = 16384;
constexpr int kMaxAnchors = 100000;

// The pixels handed in are RGB(A). The old code asked blobFromImage to swap R and
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

// ---- Shared state & thread-safety audit ---------------------------------------
// Every object below is read and written ONLY while g_mutex is held:
//  * initYoloModel() and process_comic_panels() both take the lock first;
//  * Net::forward() runs under the lock and its result (a view into the net's own
//    output buffer, valid until the next forward()) is fully consumed before the
//    lock is released. No pointer into g_blob / g_small_rgba / g_gray or into the
//    net's output ever leaves a locked section; the caller-owned out_rects is the
//    only thing handed back.
// Nothing is thread_local and nothing is freed by hand: the Mats own their memory
// (reference counted by OpenCV) and live until process exit, so there is no raw
// owning pointer to leak.
std::mutex g_mutex;                    // serialises init + inference (Net is not thread-safe)
std::unique_ptr<cv::dnn::Net> g_net;   // guarded by g_mutex

// Buffers reused by every call. They are always 640x640 with the same type, and
// OpenCV only reallocates a Mat when its size / type changes, so after warm-up
// these three (6.96 MB in total) are never allocated again:
//   g_blob        1x3x640x640 float input tensor            4.92 MB
//   g_small_rgba  640x640 RGBA, the resized page            1.64 MB
//   g_gray        640x640 grey thumbnail, flat-region check 0.41 MB
// Compared with the previous version this drops the 1.23 MB g_rgb buffer AND the
// temporary float image blobFromImage builds on every call: it converts the whole
// image to a fresh CV_32F Mat before filling the blob (one call peaks at about
// twice the blob's size; measured with OpenCV 5.0 on desktop), i.e. ~4.9 MB
// allocated and freed on every page. Peak during pre-processing falls from
// ~13.1 MB to ~7.0 MB, with no per-page allocation left for the big buffers.
// What still allocates per page are a few small std::vectors (a few KB each) here
// and inside panel_postprocess. They are deliberately not pooled: nms() takes its
// input by value and every stage returns a new vector, so a "pooled" candidate
// vector lost its buffer on every call anyway.
cv::Mat g_blob;
cv::Mat g_small_rgba;
cv::Mat g_gray;

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

// One image row: RGBA bytes in, three float planes out, scaled to 0..1. This is the
// same arithmetic as blobFromImage (u8 * float(1/255)) and, for the default
// kSwapRB=false, gives the network exactly the values it received before.
// __restrict tells the compiler the source and the three planes never overlap,
// which is what lets it vectorise the loop (NEON on arm64) instead of assuming
// that every float store might write into the source bytes.
inline void pack_row(const uint8_t* __restrict src, float* __restrict c0,
                     float* __restrict c1, float* __restrict c2, int n) {
    constexpr float kScale = static_cast<float>(1.0 / 255.0);
    constexpr int kSrc0 = kSwapRB ? 2 : 0;  // source channel for plane 0
    constexpr int kSrc2 = kSwapRB ? 0 : 2;  // source channel for plane 2
    for (int x = 0; x < n; ++x) {
        const uint8_t* p = src + 4 * x;
        c0[x] = static_cast<float>(p[kSrc0]) * kScale;
        c1[x] = static_cast<float>(p[1]) * kScale;
        c2[x] = static_cast<float>(p[kSrc2]) * kScale;
    }
}

// Packs the 640x640 RGBA thumbnail into the 1x3x640x640 CHW float blob in ONE pass
// and without temporaries (alpha is ignored, as the old RGBA2RGB did).
void pack_input_blob(const cv::Mat& rgba, cv::Mat& blob) {
    constexpr int kPlane = kInputSize * kInputSize;
    const int sizes[4] = {1, 3, kInputSize, kInputSize};
    blob.create(4, sizes, CV_32F);  // no-op once the blob has this shape
    float* const plane0 = reinterpret_cast<float*>(blob.data);
    for (int y = 0; y < kInputSize; ++y) {
        const size_t row = static_cast<size_t>(y) * kInputSize;
        pack_row(rgba.ptr<uint8_t>(y), plane0 + row, plane0 + kPlane + row,
                 plane0 + 2 * kPlane + row, kInputSize);
    }
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
        // shapes and the same packing code), so the first real page pays no
        // allocation cost either.
        g_small_rgba.create(kInputSize, kInputSize, CV_8UC4);
        g_gray.create(kInputSize, kInputSize, CV_8UC1);

        g_small_rgba.setTo(cv::Scalar(255, 255, 255, 255));
        pack_input_blob(g_small_rgba, g_blob);
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
        // pooled 640x640 RGBA buffer, then ONE pass that packs it into the pooled
        // CHW float blob. INTER_AREA is the right filter for shrinking; INTER_LINEAR
        // if we have to enlarge. (The Dart side decodes to at most 640px on the
        // long edge, so in practice the short edge is enlarged.)
        const cv::Mat frame(height, width, CV_8UC4, pixel_data);  // header only, no copy
        const int interpolation =
            (width >= kInputSize && height >= kInputSize) ? cv::INTER_AREA : cv::INTER_LINEAR;
        cv::resize(frame, g_small_rgba, cv::Size(kInputSize, kInputSize), 0, 0, interpolation);
        pack_input_blob(g_small_rgba, g_blob);
        PS_TICK(t1);

        g_net->setInput(g_blob);
        cv::Mat output = g_net->forward();
        PS_TICK(t2);

        // --- Output tensor: [1, 4+nc, anchors] (YOLOv8 default) or the transposed
        // [1, anchors, 4+nc]. Rows 0..3 are cx, cy, w, h in 640px model space;
        // rows 4.. are class scores (one row for a single-class panel model).
        // Every mismatch bails out right here, before any pointer is formed.
        // (If the model ever gets a second class, e.g. speech bubbles, the max over
        // all class rows below would report bubbles as panels: read only the panel
        // class's row instead.)
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

        std::vector<panelshift::Box> candidates;
        candidates.reserve(128);  // a normal page has a few dozen; it grows if a noisy one has more
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
            // Clamping can collapse a box that lies outside the page to zero area.
            // Such a box can never be a panel and would only take one of the 300
            // candidate slots nms() keeps.
            if (!(x1 > x0) || !(y1 > y0)) continue;
            candidates.push_back(panelshift::Box{x0, y0, x1 - x0, y1 - y0, confidence});
        }
        PS_COUNT(n_raw, candidates.size());

        // --- Post-processing (see panel_postprocess.h) --------------------------
        panelshift::Params params;
        params.page_aspect = static_cast<float>(width) / static_cast<float>(height);
        params.use_cuts = kCutReadingOrder;

        std::vector<panelshift::Box> boxes = panelshift::nms(std::move(candidates), params);
        PS_COUNT(n_nms, boxes.size());
        boxes = panelshift::filter_geometry(boxes, params);
        PS_COUNT(n_geometry, boxes.size());
        // merge_fragments never bridges a gap, but it does absorb everything inside a
        // box, so a weak box spanning two neighbouring panels would fuse them and
        // swallow the gutter between them (see drop_union_boxes and kDropUnionBoxes).
        // Run unconditionally: only the logging below depends on the profile flag.
        const size_t union_dropped = kDropUnionBoxes ? panelshift::drop_union_boxes(boxes, params) : 0;
        (void)union_dropped;
        boxes = panelshift::merge_fragments(std::move(boxes), params);
        PS_COUNT(n_merged, boxes.size());

        // Flat-region check, AFTER merging: a flat fragment of a real panel is
        // absorbed into it first, instead of being dropped and leaving a hole.
        // It runs on views into ONE pooled 640px grey thumbnail (made from the RGBA
        // thumbnail directly: same grey values as the old RGB route) and compacts
        // the box list in place, so there is no second vector and no copy back.
        if (!boxes.empty()) {
            cv::cvtColor(g_small_rgba, g_gray, cv::COLOR_RGBA2GRAY);

            size_t kept = 0;
            for (size_t i = 0; i < boxes.size(); ++i) {
                const panelshift::Box b = boxes[i];  // copy: boxes[kept] may overwrite boxes[i]
                const int x0 = clampi(static_cast<int>(std::floor(b.x * kInputSize)), 0, kInputSize - 1);
                const int y0 = clampi(static_cast<int>(std::floor(b.y * kInputSize)), 0, kInputSize - 1);
                const int x1 = clampi(static_cast<int>(std::ceil(b.right() * kInputSize)), x0 + 1, kInputSize);
                const int y1 = clampi(static_cast<int>(std::ceil(b.bottom() * kInputSize)), y0 + 1, kInputSize);

                cv::Scalar mean, stddev;
                cv::meanStdDev(g_gray(cv::Rect(x0, y0, x1 - x0, y1 - y0)), mean, stddev);
                if (stddev[0] >= kMinStdDev) {
                    boxes[kept++] = b;
                } else {
#ifdef PANELSHIFT_PROFILE
                    LOGI("flat box dropped: std=%.1f area=%.3f", stddev[0],
                         static_cast<double>(b.w * b.h));
#endif
                }
            }
            boxes.erase(boxes.begin() + static_cast<std::ptrdiff_t>(kept), boxes.end());
        }
        PS_COUNT(n_textured, boxes.size());

        // DYNAMIC FALLBACK FOR COVERS & RECAP PAGES: nothing valid left, or only
        // residue that covers a sliver of the page (see kMinPageCoverage), so the
        // whole page is one panel instead of leaving it empty or zooming into an
        // artifact.
        float covered = 0.0f;
        for (const panelshift::Box& b : boxes) covered += b.w * b.h;
        if (boxes.empty() || covered < kMinPageCoverage) {
#ifdef PANELSHIFT_PROFILE
            if (!boxes.empty()) LOGI("residue guard: %zu box(es) cover only %.3f of the page", boxes.size(),
                                     static_cast<double>(covered));
#endif
            boxes.clear();
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
        LOGI("stages raw=%zu nms=%zu geometry=%zu union_dropped=%zu merged=%zu textured=%zu final=%d",
             n_raw, n_nms, n_geometry, union_dropped, n_merged, n_textured, panel_count);
        // Area and score of every box that is returned: the signature of whatever
        // artifacts survive (small and weak = a bubble or caption) shows up here.
        for (int i = 0; i < panel_count; ++i) {
            const panelshift::Box& b = boxes[i];
            LOGI("  panel %d: x=%.3f y=%.3f w=%.3f h=%.3f area=%.3f score=%.2f", i,
                 static_cast<double>(b.x), static_cast<double>(b.y), static_cast<double>(b.w),
                 static_cast<double>(b.h), static_cast<double>(b.w * b.h), static_cast<double>(b.score));
        }
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
