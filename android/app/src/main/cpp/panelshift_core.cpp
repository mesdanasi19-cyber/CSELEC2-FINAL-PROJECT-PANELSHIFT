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

// Updated to detect multiple comic panes using contour analysis and adaptive threshholding
__attribute__((visibility("default"))) __attribute__((used))
int process_comic_panels(
        uint8_t* pixel_data,
        int width,
        int height,
        float* out_rects,     // Output buffer for normalized panel coordinates [x, y, w, h, ...]
        int max_panels        // Maximum capacity of the output array
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

    // Step 3: Apply Adaptive Thresholding to isolate black gutters and panel borders cleanly from white backgrounds
    cv::Mat thresh_frame;
    cv::adaptiveThreshold(gray_frame, thresh_frame, 255, cv::ADAPTIVE_THRESH_GAUSSIAN_C,
                          cv::THRESH_BINARY_INV, 11, 2);

    // Step 4: Find contours of panels
    std::vector<std::vector<cv::Point>> contours;
    std::vector<cv::Vec4i> hierarchy;
    cv::findContours(thresh_frame, contours, hierarchy, cv::RETR_EXTERNAL, cv::CHAIN_APPROX_SIMPLE);

    if (contours.empty()) {
        LOGI("No panel contours detected in frame.");
        return 0;
    }

    int panel_count = 0;
    double total_area = static_cast<double>(width * height);

    for (const auto& contour : contours) {
        if (panel_count >= max_panels) break;

        // Approximate contour to a polygon to check if it's roughly rectangular
        std::vector<cv::Point> approx;
        double peri = cv::arcLength(contour, true);
        cv::approxPolyDP(contour, approx, 0.02 * peri, true);

        double area = cv::contourArea(contour);

        // Filter out tiny artifacts or oversized page borders (panels must be between 1% and 85% of page area)
        if (area > (total_area * 0.01) && area < (total_area * 0.85) && approx.size() >= 4 && approx.size() <= 6) {
            cv::Rect rect = cv::boundingRect(approx);

            // Write normalized coordinates (x, y, w, h scaled 0.0 to 1.0)
            out_rects[panel_count * 4 + 0] = static_cast<float>(rect.x) / static_cast<float>(width);
            out_rects[panel_count * 4 + 1] = static_cast<float>(rect.y) / static_cast<float>(height);
            out_rects[panel_count * 4 + 2] = static_cast<float>(rect.width) / static_cast<float>(width);
            out_rects[panel_count * 4 + 3] = static_cast<float>(rect.height) / static_cast<float>(height);

            panel_count++;
        }
    }
    //updated to display panel cound instead of max area of a single panel
    LOGI("Successfully extracted %d comic panels.", panel_count);
    return panel_count;
}

} // extern "C"