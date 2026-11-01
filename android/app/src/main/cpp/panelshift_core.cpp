#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>
#include <opencv2/dnn.hpp>
#include <jni.h>
#include <android/log.h>
#include <vector>
#include <string>
#include <fstream> // Required for std::ifstream file checks

#define LOG_TAG "PanelShiftYolo"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

static cv::dnn::Net* g_yolo_net = nullptr;
static bool is_model_loaded = false;

extern "C" {

// 1. Initializes the YOLO network from local storage path
// Initializes the YOLO network from local storage path via Dart FFI
__attribute__((visibility("default"))) __attribute__((used))
void initYoloModel(const char* model_path_cstr) {
    if (model_path_cstr == nullptr) {
        LOGE("Model path C-string is null.");
        return;
    }

    std::string model_path(model_path_cstr);
    LOGI("Attempting to load YOLO model from stable path: %s", model_path.c_str());

    // Verify file accessibility using std::ifstream
    std::ifstream file(model_path, std::ios::binary | std::ios::ate);
    if (!file.is_open()) {
        LOGE("ERROR: Model file cannot be opened at path: %s", model_path.c_str());
        return;
    }
    std::streamsize fileSize = file.tellg();
    file.close();
    LOGI("Model file verified successfully. Size: %ld bytes", static_cast<long>(fileSize));

    if (!is_model_loaded) {
        try {
            cv::dnn::Net loaded_net = cv::dnn::readNetFromONNX(model_path);
            if (loaded_net.empty()) {
                LOGE("OpenCV readNetFromONNX returned an empty network structure.");
            } else {
                loaded_net.setPreferableBackend(cv::dnn::DNN_BACKEND_OPENCV);
                loaded_net.setPreferableTarget(cv::dnn::DNN_TARGET_CPU);

                // Assign to the heap pointer safely
                g_yolo_net = new cv::dnn::Net(loaded_net);
                is_model_loaded = true;
                LOGI("Successfully initialized and configured YOLO ONNX model!");
            }
        } catch (const cv::Exception& e) {
            LOGE("OpenCV Exception during model load: %s", e.what());
        } catch (const std::exception& e) {
            LOGE("Standard Exception during model load: %s", e.what());
        }
    }
}

// 2. Dummy stub for document corners
JNIEXPORT jint JNICALL
Java_com_panelshift_engine_PanelShiftNativeBridge_detectDocumentCorners(
        JNIEnv* env, jobject thiz, jlong native_handle) {
    return 1;
}

// 3. Main processing function: Runs YOLO inference on the comic page pixel buffer
__attribute__((visibility("default"))) __attribute__((used))
int process_comic_panels(
        uint8_t* pixel_data,
        int width,
        int height,
        float* out_rects,
        int max_panels
) {
    if (pixel_data == nullptr || width <= 0 || height <= 0) {
        LOGE("Invalid image buffer passed to native core.");
        return 0;
    }

    if (!is_model_loaded || g_yolo_net == nullptr || g_yolo_net->empty()) {
        LOGE("YOLO model not loaded yet. Falling back to full-page panel.");
        if (max_panels > 0) {
            out_rects[0] = 0.0f;
            out_rects[1] = 0.0f;
            out_rects[2] = 1.0f;
            out_rects[3] = 1.0f;
            return 1;
        }
        return 0;
    }
    cv::Mat frame(height, width, CV_8UC4, pixel_data);
    cv::Mat rgb_frame;
    cv::cvtColor(frame, rgb_frame, cv::COLOR_RGBA2RGB);

    int input_width = 640;
    int input_height = 640;

    cv::Mat blob = cv::dnn::blobFromImage(rgb_frame, 1.0 / 255.0, cv::Size(input_width, input_height), cv::Scalar(0, 0, 0), true, false);

    g_yolo_net->setInput(blob);
    cv::Mat detections = g_yolo_net->forward();

    // Validate tensor dimensions to prevent out-of-bounds segfaults
    if (detections.dims < 3) {
        LOGE("Invalid detection tensor dimensions: %d", detections.dims);
        return 0;
    }

    std::vector<cv::Rect> boxes;
    std::vector<float> confidences;

    int data_width = detections.size[2];
    float* pdata = (float*)detections.data;

    for (int i = 0; i < data_width; ++i) {
        float confidence = pdata[4 * data_width + i];
        if (confidence > 0.40f) {
            float cx = pdata[0 * data_width + i];
            float cy = pdata[1 * data_width + i];
            float w  = pdata[2 * data_width + i];
            float h  = pdata[3 * data_width + i];

            int x = static_cast<int>((cx - 0.5f * w) * (static_cast<float>(width) / input_width));
            int y = static_cast<int>((cy - 0.5f * h) * (static_cast<float>(height) / input_height));
            int rw = static_cast<int>(w * (static_cast<float>(width) / input_width));
            int rh = static_cast<int>(h * (static_cast<float>(height) / input_height));

            x = std::max(0, std::min(x, width));
            y = std::max(0, std::min(y, height));
            rw = std::min(rw, width - x);
            rh = std::min(rh, height - y);

            if (rw > 20 && rh > 20) {
                boxes.emplace_back(x, y, rw, rh);
                confidences.push_back(confidence);
            }
        }
    }

    std::vector<int> indices;
    cv::dnn::NMSBoxes(boxes, confidences, 0.35f, 0.45f, indices);

    struct PanelBox {
        int id;
        cv::Rect rect;
    };

    std::vector<PanelBox> candidate_boxes;
    int id_counter = 1;

    for (int idx : indices) {
        const auto& rect = boxes[idx];

        float aspect_ratio = static_cast<float>(rect.width) / static_cast<float>(rect.height);

        // ADAPTIVE SIZING: Allow shorter heights specifically for wide cinematic/landscape panels
        int min_height = (aspect_ratio > 2.0f) ? 15 : 25;
        int min_width = 25;

        if (rect.width < min_width || rect.height < min_height) continue;

        int area = rect.width * rect.height;
        if (area < 350) continue; // Lowered area floor to catch smaller panels

        // Aspect ratio bounds (supports wide strips up to 8.0 ratio)
        if (aspect_ratio < 0.15f || aspect_ratio > 8.0f) continue;

        cv::Rect safe_rect = rect & cv::Rect(0, 0, rgb_frame.cols, rgb_frame.rows);
        if (safe_rect.width <= 0 || safe_rect.height <= 0) continue;

        // Color variance check to filter out solid text blocks
        cv::Mat panel_crop = rgb_frame(safe_rect);
        cv::Mat gray_crop;
        cv::cvtColor(panel_crop, gray_crop, cv::COLOR_RGB2GRAY);

        cv::Scalar mean, stddev;
        cv::meanStdDev(gray_crop, mean, stddev);

        if (stddev[0] < 15.0) continue;

        candidate_boxes.push_back({id_counter++, safe_rect});
    }

    // Merging loop for overlapping fragments
    std::vector<PanelBox> merged_boxes;
    for (const auto& box_item : candidate_boxes) {
        bool merged = false;
        for (auto& existing : merged_boxes) {
            cv::Rect intersection = box_item.rect & existing.rect;
            int intersection_area = intersection.area();
            int smaller_area = std::min(box_item.rect.area(), existing.rect.area());

            float overlap_ratio = (smaller_area > 0) ? (static_cast<float>(intersection_area) / smaller_area) : 0.0f;

            if (intersection_area > 0 && overlap_ratio > 0.45f) {
                existing.rect = existing.rect | box_item.rect;
                merged = true;
                break;
            }
        }
        if (!merged) {
            merged_boxes.push_back(box_item);
        }
    }

    // DYNAMIC FALLBACK FOR COVERS & RECAP PAGES:
    // If a page has zero valid panels detected (e.g. cover art, splash pages, or text-heavy recap pages),
    // treat the entire image as a single full-page panel instead of leaving it empty.
    if (merged_boxes.empty()) {
        merged_boxes.push_back({1, cv::Rect(0, 0, width, height)});
    }

    // Re-sort final merged boxes strictly Top-to-Bottom, Left-to-Right
    std::sort(merged_boxes.begin(), merged_boxes.end(), [](const PanelBox& a, const PanelBox& b) {
        const int row_tolerance = 45;
        if (std::abs(a.rect.y - b.rect.y) > row_tolerance) {
            return a.rect.y < b.rect.y;
        }
        return a.rect.x < b.rect.x;
    });

    // Populate final output array
    int panel_count = 0;
    for (const auto& item : merged_boxes) {
        if (panel_count >= max_panels) break;

        out_rects[panel_count * 4 + 0] = static_cast<float>(item.rect.x) / width;
        out_rects[panel_count * 4 + 1] = static_cast<float>(item.rect.y) / height;
        out_rects[panel_count * 4 + 2] = static_cast<float>(item.rect.width) / width;
        out_rects[panel_count * 4 + 3] = static_cast<float>(item.rect.height) / height;

        panel_count++;
    }

    LOGI("YOLO successfully extracted %d comic panels.", panel_count);
    return panel_count;
}

} // extern "C" - Single closing brace for the entire block