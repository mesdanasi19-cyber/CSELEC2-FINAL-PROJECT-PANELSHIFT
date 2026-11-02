import 'package:flutter/material.dart';
import 'dart:typed_data';
import 'dart:ui' as ui;
import '../services/native_opencv_service.dart';
import '../widgets/comic_panel_painter.dart';

enum FullPageStepMode { none, afterLast, beforeFirst, both }

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
  List<List<int?>> _doubleLayout = [];

  int _currentPage = 0;
  int _currentPanelIndex = 0;
  bool _isAnalyzing = false;
  bool _isEngineReady = false;

  bool _showPanelOutlines = true;
  bool _showPanelOverlays = true;
  bool _showUI = true;
  bool _isDoublePageView = false;

  FullPageStepMode _fullPageStepMode = FullPageStepMode.none;
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
      duration: const Duration(milliseconds: 400), // Smoother, comfortable transition speed
    )..addListener(() {
      if (_zoomAnimation != null) {
        _transformationController.value = _zoomAnimation!.value;
      }
    });

    for (int i = 0; i < widget.pageBytes.length; i++) {
      _singleLayout.add([i]);
    }

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await Future.delayed(const Duration(milliseconds: 200));

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
            if (_fullPageStepMode == FullPageStepMode.beforeFirst || _fullPageStepMode == FullPageStepMode.both) {
              _isFullPageActive = true;
            }
          });
        }

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
    List<List<int?>> layout = [];
    int i = 0;

    while (i < widget.pageBytes.length) {
      final size = _imageSizesCache[i];
      bool isWide = size != null && (size.width > size.height * 1.15);
      bool isCover = (i == 0);

      if (isCover || isWide || i == widget.pageBytes.length - 1) {
        if (isWide) {
          layout.add([i]);
        } else {
          layout.add([null, i]);
        }
        i++;
      } else {
        if (i + 1 < widget.pageBytes.length) {
          final nextSize = _imageSizesCache[i + 1];
          bool nextIsWide = nextSize != null && (nextSize.width > nextSize.height * 1.15);

          if (nextIsWide) {
            layout.add([null, i]);
            i++;
          } else {
            layout.add([i, i + 1]);
            i += 2;
          }
        } else {
          layout.add([null, i]);
          i++;
        }
      }
    }
    _doubleLayout = layout;
  }

  List<List<int>> _getEffectiveLayout() {
    if (_isDoublePageView) {
      return _doubleLayout.map((spread) => spread.whereType<int>().toList()).toList();
    }
    return _singleLayout;
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
        _focusOnPanel(panels[_currentPanelIndex], _lastViewportSize!);
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
      // Check if we were at the "before first" full screen (index 0)
      if (_currentPanelIndex == 0) {
        setState(() {
          _isFullPageActive = false;
        });
        final panels = _detectedPanelsCache[_currentPage] ?? [];
        if (panels.isNotEmpty) {
          _focusOnPanel(panels[0], viewportSize);
        }
        return;
      }

      // Otherwise, we were at the "after last" full screen -> advance to next virtual page
      final layout = _getEffectiveLayout();
      final virtualIndex = _findVirtualPageIndex(_currentPage);
      if (virtualIndex < layout.length - 1) {
        _resetZoomInstant();
        final nextPhysicalPages = layout[virtualIndex + 1];
        bool startWithFull = (_fullPageStepMode == FullPageStepMode.beforeFirst || _fullPageStepMode == FullPageStepMode.both);
        setState(() {
          _currentPage = nextPhysicalPages[0];
          _currentPanelIndex = 0;
          _isFullPageActive = startWithFull;
        });
        _pageController.animateToPage(
          virtualIndex + 1,
          duration: const Duration(milliseconds: 400),
          curve: Curves.easeInOutCubic,
        ).then((_) {
          if (!_isFullPageActive) {
            final newPanels = _detectedPanelsCache[_currentPage] ?? [];
            if (newPanels.isNotEmpty) {
              _focusOnPanel(newPanels[0], viewportSize);
            }
          } else {
            _animateToFullPage();
          }
        });
      }
      return;
    }

    // Normal panel progression
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

    // Trigger After-Last Full Screen if enabled
    if ((_fullPageStepMode == FullPageStepMode.afterLast || _fullPageStepMode == FullPageStepMode.both) && isAtLastPanel && !_isFullPageActive) {
      setState(() {
        _isFullPageActive = true;
      });
      _animateToFullPage();
      return;
    }

    // Advance to next page directly
    if (virtualIndex < layout.length - 1) {
      _resetZoomInstant();
      final nextPhysicalPages = layout[virtualIndex + 1];
      bool startWithFull = (_fullPageStepMode == FullPageStepMode.beforeFirst || _fullPageStepMode == FullPageStepMode.both);
      setState(() {
        _currentPage = nextPhysicalPages[0];
        _currentPanelIndex = 0;
        _isFullPageActive = startWithFull;
      });
      _pageController.animateToPage(
        virtualIndex + 1,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOutCubic,
      ).then((_) {
        if (!_isFullPageActive) {
          final newPanels = _detectedPanelsCache[_currentPage] ?? [];
          if (newPanels.isNotEmpty) {
            _focusOnPanel(newPanels[0], viewportSize);
          }
        } else {
          _animateToFullPage();
        }
      });
    }
  }

  void _prevPanel(Size viewportSize) {
    if (_isFullPageActive) {
      // If we are on "after-last" full screen, tapping left goes back to the last panel of this page
      if (_currentPanelIndex > 0 || (_detectedPanelsCache[_currentPage]?.length ?? 0) <= 1 || _currentPanelIndex == (_detectedPanelsCache[_currentPage]?.length ?? 1) - 1) {
        // Check if we came from last panel or first panel
        final panels = _detectedPanelsCache[_currentPage] ?? [];
        if (_currentPanelIndex == panels.length - 1) {
          setState(() {
            _isFullPageActive = false;
          });
          if (panels.isNotEmpty) {
            _focusOnPanel(panels.last, viewportSize);
          }
          return;
        }
      }

      // If we were on "before-first" full screen, tapping left goes to the previous page
      final layout = _getEffectiveLayout();
      final virtualIndex = _findVirtualPageIndex(_currentPage);
      if (virtualIndex > 0) {
        _resetZoomInstant();
        final prevPhysicalPages = layout[virtualIndex - 1];
        bool endWithFull = (_fullPageStepMode == FullPageStepMode.afterLast || _fullPageStepMode == FullPageStepMode.both);
        setState(() {
          _currentPage = prevPhysicalPages.last;
          _isFullPageActive = endWithFull;
        });
        _pageController.animateToPage(
          virtualIndex - 1,
          duration: const Duration(milliseconds: 400),
          curve: Curves.easeInOutCubic,
        ).then((_) {
          final panels = _detectedPanelsCache[_currentPage] ?? [];
          if (panels.isNotEmpty) {
            setState(() {
              _currentPanelIndex = panels.length - 1;
            });
            if (!_isFullPageActive) {
              _focusOnPanel(panels.last, viewportSize);
            } else {
              _animateToFullPage();
            }
          }
        });
      }
      return;
    }

    // Normal panel backward progression
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

    // If at panel 0, trigger Before-First Full Screen if enabled
    if ((_fullPageStepMode == FullPageStepMode.beforeFirst || _fullPageStepMode == FullPageStepMode.both) && !_isFullPageActive) {
      setState(() {
        _isFullPageActive = true;
      });
      _animateToFullPage();
      return;
    }

    // Otherwise go to previous page
    if (virtualIndex > 0) {
      _resetZoomInstant();
      final prevPhysicalPages = layout[virtualIndex - 1];
      bool endWithFull = (_fullPageStepMode == FullPageStepMode.afterLast || _fullPageStepMode == FullPageStepMode.both);
      setState(() {
        _currentPage = prevPhysicalPages.last;
        _isFullPageActive = endWithFull;
      });
      _pageController.animateToPage(
        virtualIndex - 1,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOutCubic,
      ).then((_) {
        final panels = _detectedPanelsCache[_currentPage] ?? [];
        if (panels.isNotEmpty) {
          setState(() {
            _currentPanelIndex = panels.length - 1;
          });
          if (!_isFullPageActive) {
            _focusOnPanel(panels.last, viewportSize);
          } else {
            _animateToFullPage();
          }
        }
      });
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
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOutCubic,
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
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOutCubic,
      );
    }
  }

  void _handleScreenTap(TapUpDetails details, Size viewportSize) {
    final double screenWidth = viewportSize.width;
    final double tapX = details.localPosition.dx;

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

  void _handleDoubleTap(Offset localPos, Size viewportSize) {
    if (!_isFullPageActive && _transformationController.value != Matrix4.identity()) {
      setState(() => _isFullPageActive = true);
      _animateToFullPage();
      return;
    }

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

    if (localPos.dx < offsetX || localPos.dx > offsetX + renderedW ||
        localPos.dy < offsetY || localPos.dy > offsetY + renderedH) {
      return;
    }

    final double nx = (localPos.dx - offsetX) / renderedW;
    final double ny = (localPos.dy - offsetY) / renderedH;

    final panels = _detectedPanelsCache[_currentPage] ?? [];
    for (int i = 0; i < panels.length; i++) {
      final p = panels[i];
      if (nx >= p.x && nx <= p.x + p.width && ny >= p.y && ny <= p.y + p.height) {
        setState(() {
          _currentPanelIndex = i;
          _isFullPageActive = false;
        });
        _focusOnPanel(p, viewportSize);
        break;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final effectiveLayout = _getEffectiveLayout();

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
                onDoubleTapDown: (details) => _handleDoubleTap(details.localPosition, constraints.biggest),
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
                  physics: _isScreenLocked ? const NeverScrollableScrollPhysics() : const BouncingScrollPhysics(),
                  itemCount: effectiveLayout.length,
                  onPageChanged: (virtualIndex) {
                    final physicalPages = effectiveLayout[virtualIndex];
                    setState(() {
                      _currentPage = physicalPages[0];
                      _currentPanelIndex = 0;
                      _isFullPageActive = (_fullPageStepMode == FullPageStepMode.beforeFirst || _fullPageStepMode == FullPageStepMode.both);
                    });
                    _resetZoomInstant();
                    if (_isFullPageActive) {
                      _animateToFullPage();
                    }
                    for (var pageIdx in physicalPages) {
                      _processPagePanels(pageIdx, widget.pageBytes[pageIdx]);
                    }
                  },
                  itemBuilder: (context, virtualIndex) {
                    if (_isDoublePageView) {
                      final spread = _doubleLayout[virtualIndex];
                      return Center(
                        child: InteractiveViewer(
                          transformationController: _transformationController,
                          minScale: 1.0,
                          maxScale: 5.0,
                          child: Center(
                            child: spread.length == 1
                                ? _buildSinglePageWidget(spread[0]!)
                                : _buildDoublePageWidget(spread[0], spread[1]),
                          ),
                        ),
                      );
                    } else {
                      final pageIndex = _singleLayout[virtualIndex][0];
                      return Center(
                        child: InteractiveViewer(
                          transformationController: _transformationController,
                          minScale: 1.0,
                          maxScale: 5.0,
                          child: Center(
                            child: _buildSinglePageWidget(pageIndex),
                          ),
                        ),
                      );
                    }
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
                          tooltip: _isScreenLocked ? 'Screen Locked' : 'Screen Unlocked',
                          onPressed: () {
                            setState(() {
                              _isScreenLocked = !_isScreenLocked;
                            });
                          },
                        ),
                        IconButton(
                          icon: Icon(
                            _fullPageStepMode == FullPageStepMode.none
                                ? Icons.fullscreen_exit
                                : _fullPageStepMode == FullPageStepMode.afterLast
                                ? Icons.vertical_align_bottom
                                : _fullPageStepMode == FullPageStepMode.beforeFirst
                                ? Icons.vertical_align_top
                                : Icons.unfold_more,
                          ),
                          tooltip: 'Full-Page Step: ${_fullPageStepMode.name}',
                          onPressed: () {
                            setState(() {
                              switch (_fullPageStepMode) {
                                case FullPageStepMode.none:
                                  _fullPageStepMode = FullPageStepMode.afterLast;
                                  break;
                                case FullPageStepMode.afterLast:
                                  _fullPageStepMode = FullPageStepMode.beforeFirst;
                                  break;
                                case FullPageStepMode.beforeFirst:
                                  _fullPageStepMode = FullPageStepMode.both;
                                  break;
                                case FullPageStepMode.both:
                                  _fullPageStepMode = FullPageStepMode.none;
                                  break;
                              }
                            });
                          },
                        ),
                        IconButton(
                          icon: Icon(_isDoublePageView ? Icons.menu_book : Icons.chrome_reader_mode),
                          tooltip: 'Toggle Spread View',
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
                          icon: Icon(_showPanelOutlines ? Icons.border_outer : Icons.border_clear),
                          tooltip: 'Toggle Panel Outlines & Numbers',
                          onPressed: () {
                            setState(() {
                              _showPanelOutlines = !_showPanelOutlines;
                            });
                          },
                        ),
                        IconButton(
                          icon: Icon(_showPanelOverlays ? Icons.layers : Icons.layers_outlined),
                          tooltip: 'Toggle Panel Dimming',
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
          if (_showPanelOutlines)
            CustomPaint(
              painter: ComicPanelPainter(
                panels: panels,
                activeIndex: (_currentPage == pageIndex && !_isFullPageActive) ? _currentPanelIndex : -1,
                showOutlines: true,
                showDimming: false,
              ),
            ),
          if (_showPanelOverlays && !_isFullPageActive)
            CustomPaint(
              painter: ComicPanelPainter(
                panels: (_currentPage == pageIndex) ? panels : [],
                activeIndex: (_currentPage == pageIndex) ? _currentPanelIndex : -99,
                showOutlines: false,
                showDimming: true,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildDoublePageWidget(int? pageA, int? pageB) {
    final sizeA = pageA != null ? _imageSizesCache[pageA] : null;
    final sizeB = pageB != null ? _imageSizesCache[pageB] : null;

    return LayoutBuilder(
      builder: (context, constraints) {
        final double maxHeight = constraints.maxHeight;
        final double maxWidth = constraints.maxWidth;

        final double wB = sizeB != null ? maxHeight * (sizeB.width / sizeB.height) : maxWidth / 2;
        final double wA = sizeA != null ? maxHeight * (sizeA.width / sizeA.height) : wB;

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
                child: pageA != null
                    ? Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.memory(widget.pageBytes[pageA], fit: BoxFit.fill),
                    if (_showPanelOutlines)
                      CustomPaint(
                        painter: ComicPanelPainter(
                          panels: _detectedPanelsCache[pageA] ?? [],
                          activeIndex: (_currentPage == pageA && !_isFullPageActive) ? _currentPanelIndex : -1,
                          showOutlines: true,
                          showDimming: false,
                        ),
                      ),
                    if (_showPanelOverlays && !_isFullPageActive)
                      CustomPaint(
                        painter: ComicPanelPainter(
                          panels: (_currentPage == pageA) ? (_detectedPanelsCache[pageA] ?? []) : [],
                          activeIndex: (_currentPage == pageA) ? _currentPanelIndex : -99,
                          showOutlines: false,
                          showDimming: true,
                        ),
                      ),
                    if (_showPanelOverlays && !_isFullPageActive && _currentPage != pageA)
                      Container(color: Colors.black.withOpacity(0.65)),
                  ],
                )
                    : Container(color: Colors.black),
              ),
              SizedBox(
                width: wB * scale,
                height: maxHeight * scale,
                child: pageB != null
                    ? Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.memory(widget.pageBytes[pageB], fit: BoxFit.fill),
                    if (_showPanelOutlines)
                      CustomPaint(
                        painter: ComicPanelPainter(
                          panels: _detectedPanelsCache[pageB] ?? [],
                          activeIndex: (_currentPage == pageB && !_isFullPageActive) ? _currentPanelIndex : -1,
                          showOutlines: true,
                          showDimming: false,
                        ),
                      ),
                    if (_showPanelOverlays && !_isFullPageActive)
                      CustomPaint(
                        painter: ComicPanelPainter(
                          panels: (_currentPage == pageB) ? (_detectedPanelsCache[pageB] ?? []) : [],
                          activeIndex: (_currentPage == pageB) ? _currentPanelIndex : -99,
                          showOutlines: false,
                          showDimming: true,
                        ),
                      ),
                    if (_showPanelOverlays && !_isFullPageActive && _currentPage != pageB)
                      Container(color: Colors.black.withOpacity(0.65)),
                  ],
                )
                    : Container(color: Colors.black),
              ),
            ],
          ),
        );
      },
    );
  }
}