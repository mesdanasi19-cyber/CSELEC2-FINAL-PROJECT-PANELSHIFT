import 'package:flutter/material.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PanelShift',
      home: const ComicReaderScreen(),
    );
  }
}

class ComicReaderScreen extends StatefulWidget {
  const ComicReaderScreen({super.key});

  @override
  State<ComicReaderScreen> createState() => _ComicReaderScreenState();
}

class _ComicReaderScreenState extends State<ComicReaderScreen> {
  bool _isModelReady = false;

  @override
  void initState() {
    super.initState();

    // 1. Defer native execution until after the first UI frame finishes mounting
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializeYoloSafely();
    });
  }

  Future<void> _initializeYoloSafely() async {
    // 2. Add a 500ms safety buffer to let WebSockets and Impeller stabilize
    await Future.delayed(const Duration(milliseconds: 500));

    try {
      // 3. Resolve your local model storage path (copying from assets if needed)
      final Directory appDir = await getApplicationDocumentsDirectory();
      final String modelPath = '${appDir.path}/yolov8_panels.onnx';

      // Verify file exists on disk before passing to native code
      final File modelFile = File(modelPath);
      if (!await modelFile.exists()) {
        debugPrint('ERROR: YOLO model file not found at $modelPath');
        return;
      }

      debugPrint('Initializing native YOLO model from: $modelPath');

      // 4. Invoke your native bridge method safely
      // PanelShiftNativeBridge.initYoloModel(modelPath);

      if (mounted) {
        setState(() {
          _isModelReady = true;
        });
      }
      debugPrint('Native YOLO model initialization completed successfully.');
    } catch (e, stackTrace) {
      debugPrint('FATAL: Caught error during deferred native initialization: $e\n$stackTrace');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('PanelShift Reader')),
      body: Center(
        child: Text(_isModelReady ? 'YOLO Model Ready' : 'Initializing Engine...'),
      ),
    );
  }
}