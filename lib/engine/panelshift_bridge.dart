import 'dart:ffi' as ffi;
import 'dart:io';
import 'package:ffi/ffi.dart';

// --- FFI Function Signature Definitions ---
// Define the C-style function signature for document edge detection
typedef NativeEdgeDetectionFunction = ffi.Int32 Function(
    ffi.Pointer<ffi.Uint8> pixelData,
    ffi.Int32 width,
    ffi.Int32 height,
    ffi.Pointer<ffi.Float> outCorners,
    );

// Define the Dart-callable function signature type
typedef DartEdgeDetectionFunction = int Function(
    ffi.Pointer<ffi.Uint8> pixelData,
    int width,
    int height,
    ffi.Pointer<ffi.Float> outCorners,
    );

class PanelShiftBridge {
  late final ffi.DynamicLibrary _nativeLib;
  late final DartEdgeDetectionFunction _processEdgeDetection;

  PanelShiftBridge() {
    _initNativeLibrary();
  }

  /// Loads the compiled C++ shared library depending on the platform
  void _initNativeLibrary() {
    if (Platform.isAndroid) {
      // On Android, symbols are loaded globally from the shared object
      _nativeLib = ffi.DynamicLibrary.open("libpanelshift_core.so");
    } else if (Platform.isWindows) {
      _nativeLib = ffi.DynamicLibrary.open("panelshift_core.dll");
    } else {
      throw UnsupportedError("Platform not supported for PanelShift Native Core.");
    }

    // Look up the exported C function from panelshift_engine.cpp
    _processEdgeDetection = _nativeLib
        .lookup<ffi.NativeFunction<NativeEdgeDetectionFunction>>(
        'process_document_edge_detection')
        .asFunction<DartEdgeDetectionFunction>();
  }

  /// Passes raw pixel buffers and receives detected document corners (normalized 0.0 - 1.0)
  /// Returns 1 if successful, 0 if no valid document quadrilateral is found.
  int detectEdges(ffi.Pointer<ffi.Uint8> pixelData, int width, int height, ffi.Pointer<ffi.Float> outCorners) {
    return _processEdgeDetection(pixelData, width, height, outCorners);
  }
}