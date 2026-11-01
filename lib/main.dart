import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/services.dart';
import 'services/comic_parser_service.dart';
import 'services/native_opencv_service.dart'; // Contains NativeOpenCvService & ComicPanel

void main() {
  runApp(const PanelShiftApp());
}

class PanelShiftApp extends StatelessWidget {
  const PanelShiftApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PanelShift Core',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      home: const ComicProcessorScreen(title: 'PanelShift Core Engine'),
    );
  }
}

/// ==========================================
/// 1. File Picker & Archive Loader Screen
/// ==========================================
class ComicProcessorScreen extends StatefulWidget {
  const ComicProcessorScreen({super.key, required this.title});

  final String title;

  @override
  State<ComicProcessorScreen> createState() => _ComicProcessorScreenState();
}

class _ComicProcessorScreenState extends State<ComicProcessorScreen> {
  String _statusMessage = 'Ready to process digital comic archives.';
  bool _isProcessing = false;
  int _extractedPageCount = 0;

  Future<void> _pickAndProcessComic() async {
    setState(() {
      _isProcessing = true;
      _statusMessage = 'Opening file manager...';
      _extractedPageCount = 0;
    });

    try {
      List<PlatformFile> files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['cbz', 'zip'],
      );

      if (files.isEmpty || files.single.path == null) {
        setState(() {
          _statusMessage = 'File selection cancelled.';
        });
        return;
      }

      final filePath = files.single.path!;
      setState(() {
        _statusMessage = 'Extracting comic archive pages...';
      });

      final List<Uint8List> pages = await ComicParserService.extractCbzPages(filePath);

      if (pages.isEmpty) {
        setState(() {
          _statusMessage = 'No valid image pages found in archive.';
        });
        return;
      }

      setState(() {
        _extractedPageCount = pages.length;
        _statusMessage = 'Successfully extracted $_extractedPageCount pages!';
      });

      if (mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => ComicReaderScreen(pageBytes: pages),
          ),
        );
      }
    } catch (e) {
      setState(() {
        _statusMessage = 'Error unpacking archive: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isProcessing = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.title),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(Icons.menu_book, size: 80, color: Colors.deepPurple),
            const SizedBox(height: 24),
            Text(
              _statusMessage,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16),
            ),
            if (_extractedPageCount > 0) ...[
              const SizedBox(height: 12),
              Text(
                'Total Pages Loaded: $_extractedPageCount',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.green),
              ),
            ],
            const SizedBox(height: 32),
            ElevatedButton.icon(
              onPressed: _isProcessing ? null : _pickAndProcessComic,
              icon: const Icon(Icons.folder_open),
              label: const Text('Select & Process Comic Archive (.cbz)'),
            ),
          ],
        ),
      ),
    );
  }
}

/// ==========================================
/// 2. Temporary High-Visibility Debug Painter for Testing
/// ==========================================
class ComicPanelPainter extends CustomPainter {
  final List<ComicPanel> panels;
  final int activeIndex;
  final bool showDimming;

  ComicPanelPainter({
    required this.panels,
    required this.activeIndex,
    this.showDimming = true,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (panels.isEmpty) return;

    // 1. Draw Spotlight Dimming (dim everything EXCEPT the active panel)
    if (showDimming && activeIndex >= 0 && activeIndex < panels.length) {
      final activePanel = panels[activeIndex];
      final activeRect = Rect.fromLTWH(
        activePanel.x * size.width,
        activePanel.y * size.height,
        activePanel.width * size.width,
        activePanel.height * size.height,
      );

      final dimPaint = Paint()
        ..color = Colors.black.withOpacity(0.65)
        ..style = PaintingStyle.fill;

      // Save canvas state and punch out active panel rectangle
      canvas.saveLayer(Offset.zero & size, Paint());
      canvas.drawRect(Offset.zero & size, dimPaint);
      canvas.drawRect(activeRect, Paint()..blendMode = BlendMode.clear);
      canvas.restore();
    }

    // 2. Draw Bounding Boxes and Indicators
    final strokePaint = Paint()
      ..color = Colors.yellowAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0;

    final activeStrokePaint = Paint()
      ..color = Colors.cyanAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.5;

    for (int i = 0; i < panels.length; i++) {
      final panel = panels[i];
      final rect = Rect.fromLTWH(
        panel.x * size.width,
        panel.y * size.height,
        panel.width * size.width,
        panel.height * size.height,
      );

      final isCurrent = (i == activeIndex);
      canvas.drawRect(rect, isCurrent ? activeStrokePaint : strokePaint);

      // Label badge
      final textSpan = TextSpan(
        text: ' #${i + 1} ',
        style: TextStyle(
          color: Colors.black,
          fontSize: 14,
          fontWeight: FontWeight.bold,
          backgroundColor: isCurrent ? Colors.cyanAccent : Colors.yellowAccent,
        ),
      );

      final textPainter = TextPainter(
        text: textSpan,
        textDirection: TextDirection.ltr,
      )..layout();

      textPainter.paint(canvas, Offset(rect.left + 4, rect.top + 4));
    }
  }

  @override
  bool shouldRepaint(covariant ComicPanelPainter oldDelegate) {
    return oldDelegate.panels != panels ||
        oldDelegate.activeIndex != activeIndex ||
        oldDelegate.showDimming != showDimming;
  }
}

/// ==========================================
/// 3. Comic Reader Screen with YOLO Integration
/// ==========================================
class ComicReaderScreen extends StatefulWidget {
  final List<Uint8List> pageBytes;

  const ComicReaderScreen({super.key, required this.pageBytes});

  @override
  State<ComicReaderScreen> createState() => _ComicReaderScreenState();
}

class _ComicReaderScreenState extends State<ComicReaderScreen> with SingleTickerProviderStateMixin {
  late final PageController _pageController;
  late final TransformationController _transformationController;
  late final AnimationController _animationController;
  Animation<Matrix4>? _zoomAnimation;

  final Map<int, List<ComicPanel>> _detectedPanelsCache = {};
  final Map<int, Size> _imageSizesCache = {};
  int _currentPage = 0;
  int _currentPanelIndex = 0;
  bool _isAnalyzing = false;
  bool _isEngineReady = false;
  bool _showPanelOverlays = true;
  bool _showUI = true; // Toggle for center tap header visibility
  Size? _lastViewportSize;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    _transformationController = TransformationController();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    )..addListener(() {
      if (_zoomAnimation != null) {
        _transformationController.value = _zoomAnimation!.value;
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await Future.delayed(const Duration(milliseconds: 500));

      try {
        await NativeOpenCvService.initializeEngine();

        if (mounted) {
          setState(() {
            _isEngineReady = true;
          });
        }
        debugPrint('YOLO engine initialized successfully in reader screen.');

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
    _transformationController.dispose();
    _animationController.dispose();
    super.dispose();
  }

  Future<void> _processPagePanels(int index, Uint8List compressedBytes) async {
    if (_detectedPanelsCache.containsKey(index) || (_isAnalyzing && _currentPage == index) || !_isEngineReady) return;

    try {
      final ui.Codec codec = await ui.instantiateImageCodec(compressedBytes);
      final ui.FrameInfo frame = await codec.getNextFrame();
      final ui.Image image = frame.image;

      final int width = image.width;
      final int height = image.height;
      _imageSizesCache[index] = Size(width.toDouble(), height.toDouble());

      if (index == 0) {
        setState(() {
          _detectedPanelsCache[0] = [
            const ComicPanel(x: 0.0, y: 0.0, width: 1.0, height: 1.0)
          ];
        });
        return;
      }

      setState(() => _isAnalyzing = true);

      final ByteData? byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (byteData == null) return;

      final Uint8List rawRgbaBytes = byteData.buffer.asUint8List();
      final panels = NativeOpenCvService.detectPanels(rawRgbaBytes, width, height);
      debugPrint('Page $index: Extracted ${panels.length} panels (Resolution: ${width}x$height)');

      if (!mounted) return;
      setState(() {
        _detectedPanelsCache[index] = panels;
      });

      if (index == _currentPage && panels.isNotEmpty && _lastViewportSize != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _currentPage == index) {
            _focusOnPanel(panels[_currentPanelIndex], _lastViewportSize!);
          }
        });
      }
    } catch (e) {
      debugPrint('Error running OpenCV panel detection on page $index: $e');
    } finally {
      if (mounted) setState(() => _isAnalyzing = false);
    }
  }

  void _resetZoomInstant() {
    _animationController.stop();
    _zoomAnimation = null;
    _transformationController.value = Matrix4.identity();
  }

  void _focusOnPanel(ComicPanel panel, Size viewportSize) {
    if (viewportSize.width == 0 || viewportSize.height == 0) return;

    final Size? imgSize = _imageSizesCache[_currentPage];
    if (imgSize == null) return;

    final double containerW = viewportSize.width;
    final double containerH = viewportSize.height;
    final double imgW = imgSize.width;
    final double imgH = imgSize.height;

    final double fitScale = (containerW / imgW < containerH / imgH)
        ? containerW / imgW
        : containerH / imgH;

    final double renderedW = imgW * fitScale;
    final double renderedH = imgH * fitScale;
    final double offsetX = (containerW - renderedW) / 2.0;
    final double offsetY = (containerH - renderedH) / 2.0;

    final double panelScreenX = offsetX + (panel.x * renderedW);
    final double panelScreenY = offsetY + (panel.y * renderedH);
    final double panelScreenW = panel.width * renderedW;
    final double panelScreenH = panel.height * renderedH;

    // Zero-margin edge-to-edge scaling calculation (no 0.94 padding shrink)
    final double scaleX = containerW / panelScreenW;
    final double scaleY = containerH / panelScreenH;

    double targetScale = (scaleX < scaleY ? scaleX : scaleY);
    targetScale = targetScale.clamp(1.0, 5.0);

    final double panelCenterX = panelScreenX + (panelScreenW / 2.0);
    final double panelCenterY = panelScreenY + (panelScreenH / 2.0);

    final double targetX = (containerW / 2.0) - (panelCenterX * targetScale);
    final double targetY = (containerH / 2.0) - (panelCenterY * targetScale);

    final Matrix4 beginMatrix = _transformationController.value;
    final Matrix4 endMatrix = Matrix4.identity()
      ..translate(targetX, targetY)
      ..scale(targetScale);

    _zoomAnimation = Matrix4Tween(begin: beginMatrix, end: endMatrix).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOutCubic),
    );

    _animationController.forward(from: 0.0);
  }

  void _nextPanel(Size viewportSize) {
    final panels = _detectedPanelsCache[_currentPage] ?? [];

    if (panels.isEmpty) {
      if (_currentPage < widget.pageBytes.length - 1) {
        _resetZoomInstant();
        setState(() {
          _currentPage++;
          _currentPanelIndex = 0;
        });
        _pageController.animateToPage(
          _currentPage,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        );
      }
      return;
    }

    if (_currentPanelIndex < panels.length - 1) {
      setState(() => _currentPanelIndex++);
      _focusOnPanel(panels[_currentPanelIndex], viewportSize);
    } else {
      if (_currentPage < widget.pageBytes.length - 1) {
        _resetZoomInstant();
        setState(() {
          _currentPage++;
          _currentPanelIndex = 0;
        });
        _pageController.animateToPage(
          _currentPage,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeInOut,
        ).then((_) {
          final newPanels = _detectedPanelsCache[_currentPage] ?? [];
          if (newPanels.isNotEmpty) {
            _focusOnPanel(newPanels[0], viewportSize);
          }
        });
      }
    }
  }

  void _prevPanel(Size viewportSize) {
    final panels = _detectedPanelsCache[_currentPage] ?? [];

    if (_currentPanelIndex > 0) {
      setState(() => _currentPanelIndex--);
      _focusOnPanel(panels[_currentPanelIndex], viewportSize);
    } else {
      if (_currentPage > 0) {
        _resetZoomInstant();
        setState(() {
          _currentPage--;
        });
        final prevPanels = _detectedPanelsCache[_currentPage] ?? [];
        setState(() {
          _currentPanelIndex = prevPanels.isNotEmpty ? prevPanels.length - 1 : 0;
        });
        _pageController.animateToPage(
          _currentPage,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeInOut,
        ).then((_) {
          final loadedPrevPanels = _detectedPanelsCache[_currentPage] ?? [];
          if (loadedPrevPanels.isNotEmpty) {
            _focusOnPanel(loadedPrevPanels[_currentPanelIndex], viewportSize);
          }
        });
      }
    }
  }

  void _handleScreenTap(TapUpDetails details, Size viewportSize) {
    final double screenWidth = viewportSize.width;
    final double tapX = details.localPosition.dx;

    // Divide screen into 3 touch zones: Left (30%), Center (40%), Right (30%)
    if (tapX < screenWidth * 0.3) {
      _prevPanel(viewportSize);
    } else if (tapX > screenWidth * 0.7) {
      _nextPanel(viewportSize);
    } else {
      // Center tap: Toggle header UI visibility
      setState(() {
        _showUI = !_showUI;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: _showUI
          ? AppBar(
        backgroundColor: Colors.black.withOpacity(0.8),
        title: Text(
          'PanelShift Reader (${_currentPage + 1}/${widget.pageBytes.length})',
          style: const TextStyle(color: Colors.white),
        ),
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          IconButton(
            icon: Icon(_showPanelOverlays ? Icons.layers : Icons.layers_outlined),
            tooltip: 'Toggle Panel Overlays',
            onPressed: () {
              setState(() {
                _showPanelOverlays = !_showPanelOverlays;
              });
            },
          ),
        ],
      )
          : null,
      body: !_isEngineReady
          ? const Center(child: CircularProgressIndicator())
          : LayoutBuilder(
        builder: (context, constraints) {
          _lastViewportSize = constraints.biggest;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (details) => _handleScreenTap(details, constraints.biggest),
            child: PageView.builder(
              controller: _pageController,
              physics: const NeverScrollableScrollPhysics(), // Managed via 3-zone taps
              itemCount: widget.pageBytes.length,
              onPageChanged: (index) {
                setState(() {
                  _currentPage = index;
                });
                _processPagePanels(index, widget.pageBytes[index]);
              },
              itemBuilder: (context, index) {
                final panels = _detectedPanelsCache[index] ?? [];
                final imgSize = _imageSizesCache[index];

                return Center(
                  child: InteractiveViewer(
                    transformationController: _transformationController,
                    minScale: 1.0,
                    maxScale: 5.0,
                    child: Center(
                      child: imgSize == null
                          ? Image.memory(widget.pageBytes[index], fit: BoxFit.contain)
                          : AspectRatio(
                        aspectRatio: imgSize.width / imgSize.height,
                        child: Stack(
                          fit: StackFit.passthrough,
                          children: [
                            Image.memory(
                              widget.pageBytes[index],
                              fit: BoxFit.contain,
                            ),
                            if (_showPanelOverlays)
                              CustomPaint(
                                painter: ComicPanelPainter(
                                  panels: panels,
                                  activeIndex: _currentPanelIndex,
                                  showDimming: true,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}