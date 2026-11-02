import cv2
import numpy as np

class PanelShiftYoloDetector:
    def __init__(self):
        self.net = None
        self.is_model_loaded = False

    def init_yolo_model(self, model_path: str):
        """Initializes the YOLO network from an ONNX file path."""
        try:
            print(f"Attempting to load YOLO model from path: {model_path}")
            self.net = cv2.dnn.readNetFromONNX(model_path)

            if self.net.empty():
                print("ERROR: OpenCV readNetFromONNX returned an empty network structure.")
                self.is_model_loaded = False
            else:
                self.net.setPreferableBackend(cv2.dnn.DNN_BACKEND_OPENCV)
                self.net.setPreferableTarget(cv2.dnn.DNN_TARGET_CPU)
                self.is_model_loaded = True
                print("Successfully initialized and configured YOLO ONNX model in Python!")
        except Exception as e:
            print(f"Exception during model load: {e}")
            self.is_model_loaded = False

    def process_comic_panels(self, frame_bgr: np.ndarray, max_panels: int = 50) -> list:
        """
        Runs YOLO inference on a comic page image (BGR format) and
        returns normalized panel bounding boxes [x, y, w, h].
        """
        height, width = frame_bgr.shape[:2]

        if not self.is_model_loaded or self.net is None:
            print("YOLO model not loaded yet. Falling back to full-page panel.")
            if max_panels > 0:
                return [[0.0, 0.0, 1.0, 1.0]]
            return []

        input_width = 640
        input_height = 640

        # Create blob from image (equivalent to cv::dnn::blobFromImage)
        blob = cv2.dnn.blobFromImage(
            frame_bgr,
            scalefactor=1.0 / 255.0,
            size=(input_width, input_height),
            mean=(0, 0, 0),
            swapRB=True,
            crop=False
        )

        self.net.setInput(blob)
        detections = self.net.forward()

        # Validate tensor dimensions
        if len(detections.shape) < 3:
            print(f"Invalid detection tensor dimensions: {len(detections.shape)}")
            return []

        boxes = []
        confidences = []

        # YOLO output parsing
        data_width = detections.shape[2]
        pdata = detections[0]  # shape: (features, anchors)

        for i in range(data_width):
            confidence = pdata[4, i]
            if confidence > 0.40:
                cx = pdata[0, i]
                cy = pdata[1, i]
                w  = pdata[2, i]
                h  = pdata[3, i]

                x = int((cx - 0.5 * w) * (width / input_width))
                y = int((cy - 0.5 * h) * (height / input_height))
                rw = int(w * (width / input_width))
                rh = int(h * (height / input_height))

                x = max(0, min(x, width))
                y = max(0, min(y, height))
                rw = min(rw, width - x)
                rh = min(rh, height - y)

                if rw > 20 and rh > 20:
                    boxes.append([x, y, rw, rh])
                    confidences.append(float(confidence))

        # Apply Non-Maximum Suppression (NMS)
        indices = cv2.dnn.NMSBoxes(boxes, confidences, score_threshold=0.35, nms_threshold=0.45)

        candidate_boxes = []
        id_counter = 1

        if len(indices) > 0:
            # Handle different OpenCV NMS return formats across versions
            flat_indices = indices.flatten() if isinstance(indices, np.ndarray) else indices

            for idx in flat_indices:
                x, y, rw, rh = boxes[idx]
                aspect_ratio = float(rw) / float(rh) if rh > 0 else 0

                # Adaptive sizing filters
                min_height = 15 if aspect_ratio > 2.0 else 25
                min_width = 25

                if rw < min_width or rh < min_height:
                    continue

                area = rw * rh
                if area < 350:
                    continue

                if aspect_ratio < 0.15 or aspect_ratio > 8.0:
                    continue

                # Ensure box stays within frame boundaries
                x2, y2 = min(x + rw, width), min(y + rh, height)
                x, y = max(0, x), max(0, y)
                if x2 <= x or y2 <= y:
                    continue

                # Color variance check to filter out solid text blocks
                panel_crop = frame_bgr[y:y2, x:x2]
                gray_crop = cv2.cvtColor(panel_crop, cv2.COLOR_BGR2GRAY)
                stddev = np.std(gray_crop)

                if stddev < 15.0:
                    continue

                candidate_boxes.append({
                    "id": id_counter,
                    "rect": [x, y, x2 - x, y2 - y]
                })
                id_counter += 1

        # Merging loop for overlapping fragments
        merged_boxes = []
        for box_item in candidate_boxes:
            merged = False
            bx, by, bw, bh = box_item["rect"]
            box_rect = np.array([bx, by, bx + bw, by + bh])

            for existing in merged_boxes:
                ex, ey, ew, eh = existing["rect"]
                existing_rect = np.array([ex, ey, ex + ew, ey + eh])

                # Calculate intersection
                ix1 = max(box_rect[0], existing_rect[0])
                iy1 = max(box_rect[1], existing_rect[1])
                ix2 = min(box_rect[2], existing_rect[2])
                iy2 = min(box_rect[3], existing_rect[3])

                inter_w = max(0, ix2 - ix1)
                inter_h = max(0, iy2 - iy1)
                intersection_area = inter_w * inter_h

                box_area = bw * bh
                existing_area = ew * eh
                smaller_area = min(box_area, existing_area)

                overlap_ratio = (float(intersection_area) / smaller_area) if smaller_area > 0 else 0.0

                if intersection_area > 0 and overlap_ratio > 0.45:
                    # Union bounding box
                    ux1 = min(box_rect[0], existing_rect[0])
                    uy1 = min(box_rect[1], existing_rect[1])
                    ux2 = max(box_rect[2], existing_rect[2])
                    uy2 = max(box_rect[3], existing_rect[3])
                    existing["rect"] = [ux1, uy1, ux2 - ux1, uy2 - uy1]
                    merged = True
                    break

            if not merged:
                merged_boxes.append(box_item)

        # Dynamic fallback for covers / splash pages
        if not merged_boxes:
            merged_boxes.append({"id": 1, "rect": [0, 0, width, height]})

        # Sort top-to-bottom, left-to-right (Row tolerance = 45px)
        def sort_key(item):
            rx, ry, _, _ = item["rect"]
            # Group rows within 45 pixels tolerance
            row_bucket = ry // 45
            return (row_bucket, rx)

        merged_boxes.sort(key=sort_key)

        # Normalize and package final output coordinates
        panel_count = 0
        out_rects = []
        for item in merged_boxes:
            if panel_count >= max_panels:
                break
            rx, ry, rw, rh = item["rect"]
            out_rects.append([
                float(rx) / width,
                float(ry) / height,
                float(rw) / width,
                float(rh) / height
            ])
            panel_count += 1

        print(f"YOLO successfully extracted {panel_count} comic panels.")
        return out_rects

# ==============================================================================
# ARCHITECTURAL DECISION RECORD: WHY THIS ALGORITHM WAS PORTED TO C++
# ==============================================================================
#
# While this Python script accurately models the YOLOv8 panel detection and
# non-maximum suppression (NMS) logic, it is NOT used directly in the production
# Flutter mobile application for the following performance and graphics reasons:
#
# 1. Native FFI Interop: Flutter's Foreign Function Interface (FFI) relies on
#    compiled native C/C++ dynamic libraries (.so/.dll) to pass in-memory
#    pixel byte buffers directly across platform boundaries with zero latency.
#
# 2. Hardware-Accelerated Performance: Executing OpenCV DNN inferencing via
#    native C++ prevents memory copying overhead and eliminates Python runtime
#    garbage collection freezes during real-time 60 FPS UI rendering.
#
# 3. Mobile Execution Environment: Running an embedded Python interpreter on
#    Android/iOS introduces massive binary bloat and execution latency compared
#    to a lightweight, compiled C++ shared library (libpanelshift_core.so).
#
# CONCLUSION: This Python implementation serves as the reference algorithmic
# prototype for code inspection, while panelshift_core.cpp handles production
# rendering and real-time execution.
# ==============================================================================