#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>
#include <jni.h>
#include <android/log.h>
#include <android/bitmap.h>
#include <vector>
#include <cmath>
#include <cstdint>

// Define logging macros for Android logcat debugging
#define LOG_TAG "PanelShiftNative"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

extern "C" {

JNIEXPORT jint JNICALL
Java_com_panelshift_engine_PanelShiftNativeBridge_detectDocumentCorners(
        JNIEnv* env, jobject thiz, jlong native_handle) {
    return 1;
}

__attribute__((visibility("default"))) __attribute__((used))
int process_document_edge_detection(
        uint8_t* pixel_data,
        int width,
        int height,
        float* out_corners
) {
    if (pixel_data == nullptr || width <= 0 || height <= 0) {
        LOGE("Invalid image buffer passed to native core.");
        return 0;
    }

    // Step 1: Wrap raw memory buffer into a cv::Mat (Zero-Copy optimization)
    cv::Mat input_frame(height, width, CV_8UC4, pixel_data);

    // Step 2: Convert to Grayscale
    cv::Mat gray_frame;
    cv::cvtColor(input_frame, gray_frame, cv::COLOR_RGBA2GRAY);

    // Step 3: Apply Gaussian Blur
    cv::Mat blurred_frame;
    cv::GaussianBlur(gray_frame, blurred_frame, cv::Size(5, 5), 0);

    // Step 4: Apply Canny Edge Detection
    cv::Mat edges_frame;
    cv::Canny(blurred_frame, edges_frame, 75, 200);

    // Step 5: Find contours using core OpenCV function
    std::vector<std::vector<cv::Point>> contours;
    std::vector<cv::Vec4i> hierarchy;
    cv::findContours(edges_frame, contours, hierarchy, cv::RETR_LIST, cv::CHAIN_APPROX_SIMPLE);

    if (contours.empty()) {
        LOGI("No contours detected in frame.");
        return 0;
    }

    // Step 6: Evaluate contours using pure C++ math (Shoelace formula & manual bounds)
    double max_area = 0.0;
    std::vector<cv::Point> best_contour;

    for (const auto& contour : contours) {
        double area = 0.0;
        int n = contour.size();
        if (n < 4) continue;

        for (int i = 0; i < n; ++i) {
            int j = (i + 1) % n;
            area += static_cast<double>(contour[i].x) * contour[j].y;
            area -= static_cast<double>(contour[j].x) * contour[i].y;
        }
        area = std::abs(area) / 2.0;

        // Filter out tiny noise contours (10% of total frame area)
        if (area > (width * height * 0.10) && area > max_area) {
            int min_x = contour[0].x, max_x = contour[0].x;
            int min_y = contour[0].y, max_y = contour[0].y;

            for (const auto& pt : contour) {
                if (pt.x < min_x) min_x = pt.x;
                if (pt.x > max_x) max_x = pt.x;
                if (pt.y < min_y) min_y = pt.y;
                if (pt.y > max_y) max_y = pt.y;
            }

            std::vector<cv::Point> quad = {
                    cv::Point(min_x, min_y),
                    cv::Point(max_x, min_y),
                    cv::Point(max_x, max_y),
                    cv::Point(min_x, max_y)
            };

            max_area = area;
            best_contour = quad;
        }
    }

    if (best_contour.size() != 4) {
        LOGI("Valid document quadrilateral not found.");
        return 0;
    }

    // Step 7: Write normalized coordinates (0.0 to 1.0) for Flutter consumption
    for (int i = 0; i < 4; ++i) {
        out_corners[i * 2]     = static_cast<float>(best_contour[i].x) / static_cast<float>(width);
        out_corners[i * 2 + 1] = static_cast<float>(best_contour[i].y) / static_cast<float>(height);
    }

    LOGI("Successfully extracted document corners with area: %f", max_area);
    return 1;
}

} // extern "C"