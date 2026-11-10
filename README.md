# PanelShift 📖⚡

> A high-performance, AI-assisted digital comic reader built with Flutter, C++, and OpenCV. 

PanelShift was built to fix a common issue with reading digital comics on mobile screens: **manual pinch-to-zoom fatigue**. Instead of forcing you to constantly drag and zoom across irregular page layouts, PanelShift uses an embedded **YOLOv8** object detection model to find panels on the fly, dynamically focusing and dimming the rest of the page for an intuitive, guided reading experience.

---

## Key Features

- 🧠 **On-Device Panel Detection**: Runs a native C++ pipeline with OpenCV DNN to execute a custom YOLOv8 model (`.onnx`) directly on the device—zero cloud latency or internet required.
- 📐 **Smart Spread Layout ("Google Books" Engine)**: Automatically inspects image aspect ratios to isolate double-page spreads and single covers while neatly pairing portrait pages.
- 🎨 **Spotlight Dimming Overlay**: Uses custom canvas layers (`saveLayer` and `BlendMode.clear`) to cut out an active spotlight over the highlighted panel while dimming non-active areas by 65%.
- ⚡ **Zero-Disk In-Memory Extraction**: Reads `.cbz` archives directly into volatile RAM byte buffers (`Uint8List`), eliminating temporary disk writes and keeping tablet storage clean.
- 🎯 **Gesture & Zoom Management**: Combines dynamic transformation matrices (`InteractiveViewer`) with tap navigation, preventing gesture arena conflicts between page curling and panel panning.

---

## Technical Architecture

PanelShift uses a hybrid mobile architecture designed for maximum rendering performance:

```
+-------------------------------------------------------------+
|                      FLUTTER UI LAYER                       |
|   - PageFlipController / ComicPanelPainter (Custom Canvas)  |
|   - InteractiveViewer (Matrix Zoom Transformations)        |
+-------------------------------------------------------------+
                              │
               Dart FFI (Foreign Function Interface)
                              ▼
+-------------------------------------------------------------+
|                     NATIVE C++ ENGINE                       |
|   - panelshift_core.cpp (Memory Bridge & Pointer Ops)       |
|   - OpenCV DNN Module (ONNX Inference Execution)            |
|   - YOLOv8 Panel Bounding Box & NMS Algorithm               |
+-------------------------------------------------------------+
```

### Tech Stack

* **Frontend UI / UX**: Flutter (Dart)
* **Native Interop**: Dart `ffi` (Foreign Function Interface)
* **Native Graphics Engine**: C++17 with OpenCV 4.x (DNN & ImgProc)
* **AI Model**: YOLOv8 ONNX format (`yolov8_panels.onnx`)
* **Page Flip Engine**: `turnable_page`

---

## Directory Structure

```text
panelshift/
├── android/                   # Native Android build & NDK configs
├── assets/                    # Holds model weights (yolov8_panels.onnx)
├── docs/                      # Technical specs & algorithmic flowcharts
├── prototypes/
│   └── panelshift_yolo.py     # Python algorithmic reference prototype
├── lib/
│   ├── engine/                # Coordinates native FFI data channels
│   ├── models/                # ComicPanel, PageLayout data models
│   ├── screens/               # ComicReaderScreen UI & state logic
│   ├── services/              # CBZ memory extraction & Native OpenCV bridge
│   └── widgets/               # ComicPanelPainter spotlight canvas
├── native_src/
│   ├── CMakeLists.txt         # Native C++ build directives
│   └── panelshift_core.cpp    # Production OpenCV DNN inference pipeline
└── README.md
```

---

## Getting Started

### Prerequisites

Before setting up the project, ensure you have the following installed:

1. **Flutter SDK** (3.x or higher)
2. **Android Studio** with the following components installed via the SDK Manager:
   * **Android NDK** (Side-by-side)
   * **CMake** (3.18.1 or higher)
   * **Android SDK Command-line Tools**
3. A connected physical Android tablet/device (recommended for best GPU/NDK performance) or an x86_64 Emulator with OpenGL ES 3.0 enabled.

---

## Installation & Running the App

### 1. Clone the Repository
```bash
git clone https://github.com/your-username/panelshift.git
cd panelshift
```

### 2. Fetch Dependencies
```bash
flutter pub get
```

### 3. Verify Native Weights & Build Setup
Ensure `yolov8_panels.onnx` is present inside your `assets/` directory and referenced in `pubspec.yaml`:
```yaml
flutter:
  assets:
    - assets/yolov8_panels.onnx
```

### 4. Run the Application
Connect your Android device or start an emulator, then execute:
```bash
flutter run --release
```
*(Note: Running in `--release` or `--profile` mode is recommended to evaluate true native C++ FFI performance without Dart Debug Overhead).*

---

## How It Works (Step-by-Step Flow)

1. **Archive Ingestion**: The user picks a `.cbz` archive. `ComicParserService` unpacks `.jpg`/`.png` images into memory byte arrays (`Uint8List`).
2. **Model Bootstrap**: On app startup, `NativeOpenCvService` transfers `yolov8_panels.onnx` from the application bundle to local application storage so the C++ layer can access it.
3. **Inference Request**: When a page is rendered, Dart calls `process_comic_panels()` across the FFI bridge, passing the raw RGBA pixel memory pointer.
4. **C++ Execution**: C++ converts the buffer to an OpenCV `Mat`, formats a $640 \times 640$ normalized blob, and passes it through `g_yolo_net->forward()`.
5. **NMS & Sorting**: The C++ engine filters bounding boxes using Non-Maximum Suppression (`cv::dnn::NMSBoxes`), sorts them in top-to-bottom reading order, and returns normalized coordinates (`0.0`–`1.0`) back to Dart.
6. **Viewport Transformation**: Flutter's `ComicPanelPainter` draws the active spotlight box onto the `CustomPaint` layer, while `TransformationController` animates the viewport to focus on the target coordinates.

---

## Developer Note: Python Prototype

Inside `prototypes/panelshift_yolo.py`, you'll find a standalone Python reference script. This file was used to benchmark algorithm accuracy and Non-Maximum Suppression (NMS) parameters during prototyping before porting the pipeline into high-performance C++ (`panelshift_coreV0_Prototype.txt`) for production native deployment.

---

## License

Distributed under the MIT License. See `LICENSE` for more information.