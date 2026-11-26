import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show Rect;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'isolate_rpc.dart';

class ComicPanel {
  final double x;
  final double y;
  final double width;
  final double height;

  /// The pre-merge rectangles (normalised 0..1, like [x]/[y]/[width]/[height])
  /// this panel was merged from. Empty for a panel that was never merged.
  /// Display metadata only: navigation and zoom use the outer panel alone.
  final List<Rect> mergedSubPanels;

  const ComicPanel({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    this.mergedSubPanels = const <Rect>[],
  });

  @override
  String toString() =>
      'ComicPanel(x: $x, y: $y, w: $width, h: $height, '
      'sub: ${mergedSubPanels.length})';
}

/// Layout of the buffer filled by native `process_comic_panels_ex`: one record
/// of [kPanelRecordStride] floats per panel,
///   [x, y, w, h, subCount, sx0, sy0, sw0, sh0, sx1, ...]
/// with room for [kMaxSubPanelsPerPanel] sub-rectangles. This side passes
/// [kMaxSubPanelsPerPanel] to native, which derives the same stride from it, so
/// the two can never disagree. Unused sub slots are zero.
const int kMaxSubPanelsPerPanel = 12;
const int kPanelRecordStride = 5 + 4 * kMaxSubPanelsPerPanel;

// Native ABI. `initYoloModel` now returns 1 (loaded) / 0 (failed) instead of void.
typedef InitYoloC = Int32 Function(Pointer<Utf8> modelPath);
typedef InitYoloDart = int Function(Pointer<Utf8> modelPath);

// `process_comic_panels_ex` writes panel records (see kPanelRecordStride) and
// never writes past `bufferFloats` floats of `outBuffer`.
typedef ProcessComicPanelsC = Int32 Function(
  Pointer<Uint8> pixelData,
  Int32 width,
  Int32 height,
  Pointer<Float> outBuffer,
  Int32 maxPanels,
  Int32 maxSubPanels,
  Int32 bufferFloats,
);

typedef ProcessComicPanelsDart = int Function(
  Pointer<Uint8> pixelData,
  int width,
  int height,
  Pointer<Float> outBuffer,
  int maxPanels,
  int maxSubPanels,
  int bufferFloats,
);

/// Symbol lookups for one isolate. Dart statics are per-isolate, so the UI
/// isolate and the detection worker each create their own instance; the
/// shared library and the model it holds are process-wide.
class _NativeBindings {
  _NativeBindings() {
    if (!Platform.isAndroid) {
      throw UnsupportedError(
        'Native OpenCV is currently configured for Android only.',
      );
    }
    final DynamicLibrary lib = DynamicLibrary.open('libpanelshift_core.so');
    _init = lib.lookupFunction<InitYoloC, InitYoloDart>('initYoloModel');
    _process = lib.lookupFunction<ProcessComicPanelsC, ProcessComicPanelsDart>(
      'process_comic_panels_ex',
    );
  }

  late final InitYoloDart _init;
  late final ProcessComicPanelsDart _process;

  int init(String modelPath) {
    final Pointer<Utf8> pathPtr = modelPath.toNativeUtf8();
    try {
      return _init(pathPtr);
    } finally {
      malloc.free(pathPtr);
    }
  }

  /// Returns `count * kPanelRecordStride` floats: one panel record per panel
  /// (normalised 0..1 rectangle plus its merged sub-rectangles).
  Float32List detect(Uint8List rgba, int width, int height, int maxPanels) {
    if (rgba.isEmpty || width <= 0 || height <= 0 || maxPanels <= 0) {
      return Float32List(0);
    }

    // Require exactly width * height * 4 RGBA bytes.
    final int expectedBytes = width * height * 4;
    if (rgba.length != expectedBytes) {
      throw ArgumentError(
        'Invalid RGBA buffer: expected $expectedBytes bytes, '
        'received ${rgba.length}.',
      );
    }

    Pointer<Uint8>? pixelPtr;
    Pointer<Float>? outPtr;

    try {
      // Allocate inside try so a failure in the second allocation
      // cannot leak the first allocation.
      final int outFloats = maxPanels * kPanelRecordStride;
      pixelPtr = malloc<Uint8>(rgba.length);
      outPtr = malloc<Float>(outFloats);

      pixelPtr.asTypedList(rgba.length).setAll(0, rgba);

      int count = _process(
        pixelPtr,
        width,
        height,
        outPtr,
        maxPanels,
        kMaxSubPanelsPerPanel,
        outFloats,
      );

      if (count < 0) count = 0;
      if (count > maxPanels) count = maxPanels;

      // Copy the result before freeing native memory.
      return Float32List.fromList(
        outPtr.asTypedList(count * kPanelRecordStride),
      );
    } finally {
      if (pixelPtr != null) {
        malloc.free(pixelPtr);
      }
      if (outPtr != null) {
        malloc.free(outPtr);
      }
    }
  }
}

// -----------------------------------------------------------------------------
// Detection worker isolate
// -----------------------------------------------------------------------------

void _detectionWorkerMain(List<Object?> boot) {
  final _NativeBindings native = _NativeBindings();
  serveRpc(boot[0] as SendPort, (String op, Object? args) {
    switch (op) {
      case 'init':
        // Model load + warm-up inference happen here, never on the UI isolate.
        return native.init(args as String);
      case 'detect':
        final List<Object?> a = args as List<Object?>;
        final Uint8List rgba = (a[0] as TransferableTypedData)
            .materialize()
            .asUint8List();
        return native.detect(rgba, a[1] as int, a[2] as int, a[3] as int);
    }
    throw ArgumentError.value(op, 'op', 'unknown operation');
  });
}

class NativeOpenCvService {
  NativeOpenCvService._();

  static IsolateRpc? _liveWorker;
  static Future<IsolateRpc>? _starting;
  static _NativeBindings? _mainBindings;

  static Future<String> prepareYoloModelAsset() async {
    final Directory appDocDir = await getApplicationDocumentsDirectory();
    final String localPath = '${appDocDir.path}/yolov8_panels.onnx';

    final File localFile = File(localPath);

    // Reuse an existing, non-empty model.
    if (await localFile.exists()) {
      final int existingLength = await localFile.length();

      if (existingLength > 0) {
        return localPath;
      }

      // Remove an incomplete or empty model file.
      await localFile.delete();
    }

    final ByteData data = await rootBundle.load('assets/yolov8_panels.onnx');

    final Uint8List bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );

    if (bytes.isEmpty) {
      throw StateError('YOLO model asset is empty.');
    }

    // Write to a temporary file first, so a failed write cannot leave
    // a partially copied model at the final destination.
    final File temporaryFile = File('$localPath.tmp');

    try {
      await temporaryFile.writeAsBytes(bytes, flush: true);

      if (await temporaryFile.length() != bytes.length) {
        throw StateError('YOLO model copy is incomplete.');
      }

      await temporaryFile.rename(localPath);
    } catch (_) {
      if (await temporaryFile.exists()) {
        await temporaryFile.delete();
      }
      rethrow;
    }

    return localPath;
  }

  /// Spawns the detection isolate and loads the model inside it. Safe to call
  /// repeatedly and fire-and-forget: the UI isolate is never blocked, and the
  /// first detection simply waits for this to finish.
  static Future<void> initializeEngine() async {
    await ensureWorker();
  }

  /// The running detection worker (started on first use, restarted if it died).
  static Future<IsolateRpc> ensureWorker() async {
    final IsolateRpc? live = _liveWorker;
    if (live != null && !live.isClosed) return live;
    return _starting ??= _startWorker().whenComplete(() => _starting = null);
  }

  static Future<IsolateRpc> _startWorker() async {
    final String modelPath = await prepareYoloModelAsset();
    final IsolateRpc rpc = await IsolateRpc.spawn(
      _detectionWorkerMain,
      null,
      debugName: 'panel-detection',
    );
    try {
      final int? loaded = await rpc.call<int>('init', modelPath);
      // 0 = model failed to load; native code then answers with one full-page
      // panel per page, so reading still works.
      debugPrint(
        'Native YOLO model initialisation finished (loaded=${loaded == 1}).',
      );
    } catch (_) {
      await rpc.dispose();
      rethrow;
    }
    _liveWorker = rpc;
    return rpc;
  }

  static Future<void> shutdown() async {
    final IsolateRpc? live = _liveWorker;
    _liveWorker = null;
    await live?.dispose();
  }

  /// Synchronous detection on the CALLING isolate.
  ///
  /// This blocks for the whole inference. Only meant for tests and tooling;
  /// the reader uses `PanelDetectionService`, which runs it in the worker.
  @Deprecated('Blocks the calling isolate. Use PanelDetectionService.')
  static List<ComicPanel> detectPanels(
    Uint8List rawRgbaBytes,
    int width,
    int height, {
    int maxPanels = 20,
  }) {
    final _NativeBindings native = _mainBindings ??= _NativeBindings();
    return panelsFromFlat(
      native.detect(rawRgbaBytes, width, height, maxPanels),
    );
  }

  /// Decodes the worker's result: [kPanelRecordStride] floats per panel.
  static List<ComicPanel> panelsFromFlat(Float32List? flat) {
    if (flat == null || flat.length < kPanelRecordStride) {
      return const <ComicPanel>[];
    }
    final int count = flat.length ~/ kPanelRecordStride;
    return List<ComicPanel>.generate(count, (int i) {
      final int base = i * kPanelRecordStride;
      return ComicPanel(
        x: flat[base],
        y: flat[base + 1],
        width: flat[base + 2],
        height: flat[base + 3],
        mergedSubPanels: _subPanelsOf(flat, base),
      );
    }, growable: false);
  }

  static List<Rect> _subPanelsOf(Float32List flat, int base) {
    final double declared = flat[base + 4];
    if (!declared.isFinite || declared < 1) return const <Rect>[];
    final int n = declared > kMaxSubPanelsPerPanel
        ? kMaxSubPanelsPerPanel
        : declared.round();

    final List<Rect> subs = <Rect>[];
    for (int k = 0; k < n; k++) {
      final int o = base + 5 + 4 * k;
      final double x = flat[o];
      final double y = flat[o + 1];
      final double w = flat[o + 2];
      final double h = flat[o + 3];
      if (!x.isFinite || !y.isFinite || !(w > 0.0) || !(h > 0.0)) continue;
      subs.add(Rect.fromLTWH(x, y, w, h));
    }
    return subs.isEmpty ? const <Rect>[] : List<Rect>.unmodifiable(subs);
  }
}
