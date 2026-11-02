import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/services.dart';
import 'services/comic_parser_service.dart';
import 'services/native_opencv_service.dart';

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
/// 2. Comic Panel Painter with Dimming Support
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

      canvas.saveLayer(Offset.zero & size, Paint());
      canvas.drawRect(Offset.zero & size, dimPaint);
      canvas.drawRect(activeRect, Paint()..blendMode = BlendMode.clear);
      canvas.restore();
    }

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

      final isCurrent = (i == activeIndex && showDimming);
      canvas.drawRect(rect, isCurrent ? activeStrokePaint : strokePaint);

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
/// 3. Comic Reader Screen
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

  List<List<int>> _singleLayout = [];
  List<List<int>> _doubleLayout = [];

  int _currentPage = 0;
  int _currentPanelIndex = 0;
  bool _isAnalyzing = false;
  bool _isEngineReady = false;
  bool _showPanelOverlays = true;
  bool _showUI = true;
  bool _isDoublePageView = false;
  bool _enableFullPageStep = false;
  bool _isFullPageActive = false;
  bool _isScreenLocked = true;
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

    for (int i = 0; i < widget.pageBytes.length; i++) {
      _singleLayout.add([i]);
    }

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await Future.delayed(const Duration(milliseconds: 300));

      try {
        await NativeOpenCvService.initializeEngine();

        for (int i = 0; i < widget.pageBytes.length; i++) {
          final ui.Codec codec = await ui.instantiateImageCodec(widget.pageBytes[i]);
          final ui.FrameInfo frame = await codec.getNextFrame();
          _imageSizesCache[i] = Size(frame.image.width.toDouble(), frame.image.height.toDouble());
        }

        _buildDoubleLayout();

        if (mounted) {
          setState(() {
            _isEngineReady = true;
          });
        }
        debugPrint('YOLO engine & layout pre-calculated successfully.');

        if (widget.pageBytes.isNotEmpty) {
          _processPagePanels(0, widget.pageBytes[0]);
        }
      } catch (e, stackTrace) {
        debugPrint('FATAL: Error initializing engine/sizes: $e\n$stackTrace');
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

  void _buildDoubleLayout() {
    List<List<int>> layout = [];
    int i = 0;
    while (i < widget.pageBytes.length) {
      final size = _imageSizesCache[i];
      bool isWide = size != null && (size.width > size.height * 1.15);
      bool isCover = (i == 0);

      if (isCover || isWide || i == widget.pageBytes.length - 1) {
        layout.add([i]);
        i++;
      } else {
        final nextSize = _imageSizesCache[i + 1];
        bool nextIsWide = nextSize != null && (nextSize.width > nextSize.height * 1.15);
        if (nextIsWide) {
          layout.add([i]);
          i++;
        } else {
          layout.add([i, i + 1]);
          i += 2;
        }
      }
    }
    _doubleLayout = layout;
  }

  List<List<int>> _getEffectiveLayout() {
    return _isDoublePageView ? _doubleLayout : _singleLayout;
  }

  int _findVirtualPageIndex(int targetPhysicalPage) {
    final layout = _getEffectiveLayout();
    for (int i = 0; i < layout.length; i++) {
      if (layout[i].contains(targetPhysicalPage)) {
        return i;
      }
    }
    return 0;
  }

  Future<void> _processPagePanels(int index, Uint8List compressedBytes) async {
    if (_detectedPanelsCache.containsKey(index) || (_isAnalyzing && _currentPage == index) || !_isEngineReady) return;

    try {
      if (index == 0) {
        _detectedPanelsCache[0] = [const ComicPanel(x: 0.0, y: 0.0, width: 1.0, height: 1.0)];
        return;
      }

      setState(() => _isAnalyzing = true);

      final ui.Codec codec = await ui.instantiateImageCodec(compressedBytes);
      final ui.FrameInfo frame = await codec.getNextFrame();
      final ui.Image image = frame.image;
      final int width = image.width;
      final int height = image.height;

      final ByteData? byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (byteData == null) return;

      final Uint8List rawRgbaBytes = byteData.buffer.asUint8List();
      final panels = NativeOpenCvService.detectPanels(rawRgbaBytes, width, height);

      if (!mounted) return;
      setState(() {
        _detectedPanelsCache[index] = panels;
      });

      if (index == _currentPage && panels.isNotEmpty && _lastViewportSize != null && !_isFullPageActive) {
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

  void _animateToFullPage() {
    final Matrix4 beginMatrix = _transformationController.value;
    final Matrix4 endMatrix = Matrix4.identity();

    _zoomAnimation = Matrix4Tween(begin: beginMatrix, end: endMatrix).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOutCubic),
    );

    _animationController.forward(from: 0.0);
  }

  void _focusOnPanel(ComicPanel panel, Size viewportSize) {
    if (viewportSize.width == 0 || viewportSize.height == 0 || _isFullPageActive) return;

    final layout = _getEffectiveLayout();
    final virtualIndex = _findVirtualPageIndex(_currentPage);
    final physicalPages = layout[virtualIndex];

    final Size? imgSize = _imageSizesCache[_currentPage];
    if (imgSize == null) return;

    final double containerW = viewportSize.width;
    final double containerH = viewportSize.height;

    double renderedW, renderedH, offsetX, offsetY;

    if (_isDoublePageView && physicalPages.length == 2) {
      final sizeA = _imageSizesCache[physicalPages[0]]!;
      final sizeB = _imageSizesCache[physicalPages[1]]!;

      final double maxHeight = containerH;
      final double wA = maxHeight * (sizeA.width / sizeA.height);
      final double wB = maxHeight * (sizeB.width / sizeB.height);

      double scale = 1.0;
      if ((wA + wB) > containerW) {
        scale = containerW / (wA + wB);
      }

      final double totalW = (wA + wB) * scale;
      final double totalH = maxHeight * scale;
      final double baseOffsetX = (containerW - totalW) / 2.0;
      final double baseOffsetY = (containerH - totalH) / 2.0;

      if (_currentPage == physicalPages[0]) {
        renderedW = wA * scale;
        renderedH = totalH;
        offsetX = baseOffsetX;
        offsetY = baseOffsetY;
      } else {
        renderedW = wB * scale;
        renderedH = totalH;
        offsetX = baseOffsetX + (wA * scale);
        offsetY = baseOffsetY;
      }
    } else {
      final double imgW = imgSize.width;
      final double imgH = imgSize.height;
      final double fitScale = (containerW / imgW < containerH / imgH)
          ? containerW / imgW
          : containerH / imgH;

      renderedW = imgW * fitScale;
      renderedH = imgH * fitScale;
      offsetX = (containerW - renderedW) / 2.0;
      offsetY = (containerH - renderedH) / 2.0;
    }

    final double panelScreenX = offsetX + (panel.x * renderedW);
    final double panelScreenY = offsetY + (panel.y * renderedH);
    final double panelScreenW = panel.width * renderedW;
    final double panelScreenH = panel.height * renderedH;

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
    if (_isFullPageActive) {
      setState(() {
        _isFullPageActive = false;
      });
      final layout = _getEffectiveLayout();
      final virtualIndex = _findVirtualPageIndex(_currentPage);

      if (virtualIndex < layout.length - 1) {
        _resetZoomInstant();
        final nextPhysicalPages = layout[virtualIndex + 1];
        setState(() {
          _currentPage = nextPhysicalPages[0];
          _currentPanelIndex = 0;
        });
        _pageController.animateToPage(
          virtualIndex + 1,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeInOut,
        ).then((_) {
          final newPanels = _detectedPanelsCache[_currentPage] ?? [];
          if (newPanels.isNotEmpty) {
            _focusOnPanel(newPanels[0], viewportSize);
          }
        });
      }
      return;
    }

    final layout = _getEffectiveLayout();
    final virtualIndex = _findVirtualPageIndex(_currentPage);
    final physicalPages = layout[virtualIndex];

    bool isAtLastPanel = false;

    if (_isDoublePageView && physicalPages.length == 2) {
      final pageA = physicalPages[0];
      final pageB = physicalPages[1];
      final panelsA = _detectedPanelsCache[pageA] ?? [];
      final panelsB = _detectedPanelsCache[pageB] ?? [];

      if (_currentPage == pageA) {
        if (_currentPanelIndex < panelsA.length - 1) {
          setState(() => _currentPanelIndex++);
          _focusOnPanel(panelsA[_currentPanelIndex], viewportSize);
          return;
        } else {
          setState(() {
            _currentPage = pageB;
            _currentPanelIndex = 0;
          });
          if (panelsB.isNotEmpty) {
            _focusOnPanel(panelsB[0], viewportSize);
          }
          return;
        }
      } else {
        if (_currentPanelIndex < panelsB.length - 1) {
          setState(() => _currentPanelIndex++);
          _focusOnPanel(panelsB[_currentPanelIndex], viewportSize);
          return;
        } else {
          isAtLastPanel = true;
        }
      }
    } else {
      final panels = _detectedPanelsCache[_currentPage] ?? [];
      if (_currentPanelIndex < panels.length - 1) {
        setState(() => _currentPanelIndex++);
        _focusOnPanel(panels[_currentPanelIndex], viewportSize);
        return;
      } else {
        isAtLastPanel = true;
      }
    }

    if (_enableFullPageStep && isAtLastPanel && !_isFullPageActive) {
      setState(() {
        _isFullPageActive = true;
      });
      _animateToFullPage();
      return;
    }

    if (virtualIndex < layout.length - 1) {
      _resetZoomInstant();
      final nextPhysicalPages = layout[virtualIndex + 1];
      setState(() {
        _currentPage = nextPhysicalPages[0];
        _currentPanelIndex = 0;
        _isFullPageActive = false;
      });
      _pageController.animateToPage(
        virtualIndex + 1,
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

  void _prevPanel(Size viewportSize) {
    if (_isFullPageActive) {
      setState(() {
        _isFullPageActive = false;
      });
      final layout = _getEffectiveLayout();
      final virtualIndex = _findVirtualPageIndex(_currentPage);
      final physicalPages = layout[virtualIndex];

      if (_isDoublePageView && physicalPages.length == 2) {
        setState(() {
          _currentPage = physicalPages[1];
        });
        final panelsB = _detectedPanelsCache[physicalPages[1]] ?? [];
        setState(() {
          _currentPanelIndex = panelsB.isNotEmpty ? panelsB.length - 1 : 0;
        });
        if (panelsB.isNotEmpty) {
          _focusOnPanel(panelsB[_currentPanelIndex], viewportSize);
        }
      } else {
        final panels = _detectedPanelsCache[_currentPage] ?? [];
        setState(() {
          _currentPanelIndex = panels.isNotEmpty ? panels.length - 1 : 0;
        });
        if (panels.isNotEmpty) {
          _focusOnPanel(panels[_currentPanelIndex], viewportSize);
        }
      }
      return;
    }

    final layout = _getEffectiveLayout();
    final virtualIndex = _findVirtualPageIndex(_currentPage);
    final physicalPages = layout[virtualIndex];

    if (_isDoublePageView && physicalPages.length == 2) {
      final pageA = physicalPages[0];
      final pageB = physicalPages[1];
      final panelsA = _detectedPanelsCache[pageA] ?? [];
      final panelsB = _detectedPanelsCache[pageB] ?? [];

      if (_currentPage == pageB) {
        if (_currentPanelIndex > 0) {
          setState(() => _currentPanelIndex--);
          _focusOnPanel(panelsB[_currentPanelIndex], viewportSize);
          return;
        } else {
          setState(() {
            _currentPage = pageA;
            _currentPanelIndex = panelsA.isNotEmpty ? panelsA.length - 1 : 0;
          });
          if (panelsA.isNotEmpty) {
            _focusOnPanel(panelsA[_currentPanelIndex], viewportSize);
          }
          return;
        }
      } else {
        if (_currentPanelIndex > 0) {
          setState(() => _currentPanelIndex--);
          _focusOnPanel(panelsA[_currentPanelIndex], viewportSize);
          return;
        }
      }
    } else {
      final panels = _detectedPanelsCache[_currentPage] ?? [];
      if (_currentPanelIndex > 0) {
        setState(() => _currentPanelIndex--);
        _focusOnPanel(panels[_currentPanelIndex], viewportSize);
        return;
      }
    }

    if (virtualIndex > 0) {
      _resetZoomInstant();
      final prevPhysicalPages = layout[virtualIndex - 1];
      setState(() {
        _currentPage = prevPhysicalPages.last;
        _currentPanelIndex = 0;
        _isFullPageActive = true;
      });
      _pageController.animateToPage(
        virtualIndex - 1,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeInOut,
      );
    }
  }

  void _nextPageFree() {
    final layout = _getEffectiveLayout();
    final virtualIndex = _findVirtualPageIndex(_currentPage);
    if (virtualIndex < layout.length - 1) {
      _resetZoomInstant();
      setState(() {
        _currentPage = layout[virtualIndex + 1][0];
        _currentPanelIndex = 0;
        _isFullPageActive = true;
      });
      _pageController.animateToPage(
        virtualIndex + 1,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  void _prevPageFree() {
    final layout = _getEffectiveLayout();
    final virtualIndex = _findVirtualPageIndex(_currentPage);
    if (virtualIndex > 0) {
      _resetZoomInstant();
      setState(() {
        _currentPage = layout[virtualIndex - 1][0];
        _currentPanelIndex = 0;
        _isFullPageActive = true;
      });
      _pageController.animateToPage(
        virtualIndex - 1,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  void _handleScreenTap(TapUpDetails details, Size viewportSize) {
    final double screenWidth = viewportSize.width;
    final double tapX = details.localPosition.dx;

    // Tap actions are ALWAYS fully functional regardless of lock mode
    if (tapX < screenWidth * 0.3) {
      _prevPanel(viewportSize);
    } else if (tapX > screenWidth * 0.7) {
      _nextPanel(viewportSize);
    } else {
      setState(() {
        _showUI = !_showUI;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final layout = _getEffectiveLayout();

    return Scaffold(
      backgroundColor: Colors.black,
      body: !_isEngineReady
          ? const Center(child: CircularProgressIndicator())
          : LayoutBuilder(
        builder: (context, constraints) {
          _lastViewportSize = constraints.biggest;
          return Stack(
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: (details) => _handleScreenTap(details, constraints.biggest),
                // Swipe is ONLY enabled when unlocked AND in unzoomed/full-page mode
                onHorizontalDragEnd: (!_isScreenLocked && (_isFullPageActive || _transformationController.value == Matrix4.identity()))
                    ? (details) {
                  if (details.primaryVelocity != null) {
                    if (details.primaryVelocity! < -300) {
                      _nextPageFree();
                    } else if (details.primaryVelocity! > 300) {
                      _prevPageFree();
                    }
                  }
                }
                    : null,
                child: PageView.builder(
                  controller: _pageController,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: layout.length,
                  onPageChanged: (virtualIndex) {
                    final physicalPages = layout[virtualIndex];
                    setState(() {
                      _currentPage = physicalPages[0];
                      _currentPanelIndex = 0;
                    });
                    for (var pageIdx in physicalPages) {
                      _processPagePanels(pageIdx, widget.pageBytes[pageIdx]);
                    }
                  },
                  itemBuilder: (context, virtualIndex) {
                    final physicalPages = layout[virtualIndex];

                    return Center(
                      child: InteractiveViewer(
                        transformationController: _transformationController,
                        minScale: 1.0,
                        maxScale: 5.0,
                        child: Center(
                          child: physicalPages.length == 1
                              ? _buildSinglePageWidget(physicalPages[0])
                              : _buildDoublePageWidget(physicalPages[0], physicalPages[1]),
                        ),
                      ),
                    );
                  },
                ),
              ),
              if (_showUI)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: AnimatedOpacity(
                    opacity: _showUI ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 200),
                    child: AppBar(
                      backgroundColor: Colors.black.withOpacity(0.8),
                      title: Text(
                        'PanelShift Reader (${_currentPage + 1}/${widget.pageBytes.length})',
                        style: const TextStyle(color: Colors.white),
                      ),
                      iconTheme: const IconThemeData(color: Colors.white),
                      actions: [
                        IconButton(
                          icon: Icon(_isScreenLocked ? Icons.lock : Icons.lock_open),
                          tooltip: _isScreenLocked ? 'Unlock Swipe (Full-Page Only)' : 'Lock Screen (Strict Tap)',
                          onPressed: () {
                            setState(() {
                              _isScreenLocked = !_isScreenLocked;
                            });
                          },
                        ),
                        IconButton(
                          icon: Icon(_enableFullPageStep ? Icons.fullscreen : Icons.fullscreen_exit),
                          tooltip: _enableFullPageStep ? 'Disable Full Page Step' : 'Enable Full Page Step',
                          onPressed: () {
                            setState(() {
                              _enableFullPageStep = !_enableFullPageStep;
                            });
                          },
                        ),
                        IconButton(
                          icon: Icon(_isDoublePageView ? Icons.menu_book : Icons.chrome_reader_mode),
                          tooltip: _isDoublePageView ? 'Switch to Single View' : 'Switch to Double View',
                          onPressed: () {
                            setState(() {
                              _isDoublePageView = !_isDoublePageView;
                              _resetZoomInstant();
                              _currentPanelIndex = 0;
                              _isFullPageActive = true;
                            });

                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (!mounted) return;
                              final newLayout = _getEffectiveLayout();
                              int newVirtualIdx = 0;
                              for (int vi = 0; vi < newLayout.length; vi++) {
                                if (newLayout[vi].contains(_currentPage)) {
                                  newVirtualIdx = vi;
                                  break;
                                }
                              }
                              if (_pageController.hasClients) {
                                _pageController.jumpToPage(newVirtualIdx);
                              }
                            });
                          },
                        ),
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
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildSinglePageWidget(int pageIndex) {
    final panels = _detectedPanelsCache[pageIndex] ?? [];
    final imgSize = _imageSizesCache[pageIndex];

    return imgSize == null
        ? Image.memory(widget.pageBytes[pageIndex], fit: BoxFit.contain)
        : AspectRatio(
      aspectRatio: imgSize.width / imgSize.height,
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          Image.memory(
            widget.pageBytes[pageIndex],
            fit: BoxFit.contain,
          ),
          if (_showPanelOverlays)
            CustomPaint(
              painter: ComicPanelPainter(
                panels: panels,
                activeIndex: (_currentPage == pageIndex && !_isFullPageActive) ? _currentPanelIndex : -1,
                showDimming: !_isFullPageActive,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildDoublePageWidget(int pageA, int pageB) {
    final sizeA = _imageSizesCache[pageA];
    final sizeB = _imageSizesCache[pageB];

    if (sizeA == null || sizeB == null) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Image.memory(widget.pageBytes[pageA], fit: BoxFit.fitHeight),
          Image.memory(widget.pageBytes[pageB], fit: BoxFit.fitHeight),
        ],
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final double maxHeight = constraints.maxHeight;
        final double maxWidth = constraints.maxWidth;

        final double wA = maxHeight * (sizeA.width / sizeA.height);
        final double wB = maxHeight * (sizeB.width / sizeB.height);

        double scale = 1.0;
        if ((wA + wB) > maxWidth) {
          scale = maxWidth / (wA + wB);
        }

        return Center(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: wA * scale,
                height: maxHeight * scale,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.memory(widget.pageBytes[pageA], fit: BoxFit.fill),
                    if (_showPanelOverlays)
                      CustomPaint(
                        painter: ComicPanelPainter(
                          panels: _detectedPanelsCache[pageA] ?? [],
                          activeIndex: (_currentPage == pageA && !_isFullPageActive) ? _currentPanelIndex : -1,
                          showDimming: !_isFullPageActive,
                        ),
                      ),
                  ],
                ),
              ),
              SizedBox(
                width: wB * scale,
                height: maxHeight * scale,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.memory(widget.pageBytes[pageB], fit: BoxFit.fill),
                    if (_showPanelOverlays)
                      CustomPaint(
                        painter: ComicPanelPainter(
                          panels: _detectedPanelsCache[pageB] ?? [],
                          activeIndex: (_currentPage == pageB && !_isFullPageActive) ? _currentPanelIndex : -1,
                          showDimming: !_isFullPageActive,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}