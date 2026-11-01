import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../services/native_opencv_service.dart';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

Future<String> prepareYoloModelAsset() async {
  final Directory appDir = await getApplicationDocumentsDirectory();
  final String targetPath = '${appDir.path}/yolov8_panels.onnx';
  final File file = File(targetPath);

  if (!await file.exists()) {
    debugPrint('YOLO model not found locally. Copying from asset bundle...');
    final ByteData data = await rootBundle.load('assets/flv8_panels.onnx');
    final List<int> bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    await file.writeAsBytes(bytes, flush: true);
    debugPrint('YOLO model successfully written to: $targetPath');
  }
  return targetPath;
}

class ComicReaderScreen extends StatefulWidget {
  final List<Uint8List> pageBytes;

  const ComicReaderScreen({super.key, required this.pageBytes});

  @override
  State<ComicReaderScreen> createState() => _ComicReaderScreenState();
}

class _ComicReaderScreenState extends State<ComicReaderScreen> {
  late final PageController _pageController;
  final Map<int, List<ComicPanel>> _detectedPanelsCache = {};
  int _currentPage = 0;
  bool _isAnalyzing = false;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();

    // Defer initialization to let the UI mount smoothly, then initialize native engine
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await Future.delayed(const Duration(milliseconds: 500)); // Stabilization buffer

      try {
        // 1. Calls the complete pipeline inside NativeOpenCvService (copies asset & calls FFI init)[cite: 5]
        await NativeOpenCvService.initializeEngine();
        debugPrint('YOLO model and native engine initialized successfully.');

        // 2. Now safely start processing your comic pages
        if (widget.pageBytes.isNotEmpty) {
          _processPagePanels(0, widget.pageBytes[0]);
        }
      } catch (e, stackTrace) {
        debugPrint('FATAL: Error initializing native OpenCV engine: $e\n$stackTrace');
      }
    });
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _processPagePanels(int index, Uint8List compressedBytes) async {
    if (_detectedPanelsCache.containsKey(index) || _isAnalyzing) return;

    setState(() {
      _isAnalyzing = true;
    });

    try {
      // 1. Decode compressed archive bytes (JPEG/PNG) into an uncompressed image
      final ui.Codec codec = await ui.instantiateImageCodec(compressedBytes);
      final ui.FrameInfo frame = await codec.getNextFrame();
      final ui.Image image = frame.image;

      final int width = image.width;
      final int height = image.height;

      // 2. Extract raw uncompressed RGBA pixel bytes required by OpenCV (CV_8UC4)
      final ByteData? byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (byteData == null) {
        debugPrint('Failed to extract raw RGBA byte data for page $index');
        return;
      }

      final Uint8List rawRgbaBytes = byteData.buffer.asUint8List();

      // 3. Call native OpenCV bridge safely with raw pixel buffer and precise dimensions
      final panels = NativeOpenCvService.detectPanels(rawRgbaBytes, width, height);

      debugPrint('Page $index: Successfully extracted ${panels.length} panels (Resolution: ${width}x$height)');

      if (!mounted) return;
      setState(() {
        _detectedPanelsCache[index] = panels;
      });
    } catch (e) {
      debugPrint('Error decoding image or running OpenCV on page $index: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isAnalyzing = false;
        });
      }
    }
  }

  void _onPageChanged(int index) {
    setState(() {
      _currentPage = index;
    });
    _processPagePanels(index, widget.pageBytes[index]);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black.withOpacity(0.7),
        title: Text(
          'PanelShift Reader (${_currentPage + 1}/${widget.pageBytes.length})',
          style: const TextStyle(color: Colors.white),
        ),
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          IconButton(
            icon: const Icon(Icons.file_open),
            onPressed: () {
              // TODO: Add your file picker / import logic here
            },
          ),
        ],
      ),
      body: PageView.builder(
        controller: _pageController,
        itemCount: widget.pageBytes.length,
        onPageChanged: _onPageChanged,
        itemBuilder: (context, index) {
          return Center(
            child: InteractiveViewer(
              minScale: 1.0,
              maxScale: 4.0,
              child: Image.memory(
                widget.pageBytes[index],
                fit: BoxFit.contain,
                errorBuilder: (context, error, stackTrace) {
                  return const Center(
                    child: Text(
                      'Error loading page',
                      style: TextStyle(color: Colors.red),
                    ),
                  );
                },
              ),
            ),
          );
        },
      ),
    );
  }
}