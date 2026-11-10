import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef NativeEdgeDetectionFunction = ffi.Int32 Function(
  ffi.Pointer<ffi.Uint8> pixelData,
  ffi.Int32 width,
  ffi.Int32 height,
  ffi.Pointer<ffi.Float> outCorners,
);

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

  void _initNativeLibrary() {
    if (Platform.isAndroid) {
      _nativeLib = ffi.DynamicLibrary.open("libpanelshift_core.so");
    } else if (Platform.isWindows) {
      _nativeLib = ffi.DynamicLibrary.open("panelshift_core.dll");
    } else {
      throw UnsupportedError(
        "Platform not supported for PanelShift Native Core.",
      );
    }

    _processEdgeDetection = _nativeLib
        .lookup<ffi.NativeFunction<NativeEdgeDetectionFunction>>(
          'process_document_edge_detection',
        )
        .asFunction<DartEdgeDetectionFunction>();
  }

  int detectEdges(
    ffi.Pointer<ffi.Uint8> pixelData,
    int width,
    int height,
    ffi.Pointer<ffi.Float> outCorners,
  ) {
    return _processEdgeDetection(pixelData, width, height, outCorners);
  }
}
