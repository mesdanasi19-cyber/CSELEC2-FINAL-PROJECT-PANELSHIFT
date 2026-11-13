import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'dart:typed_data';
import 'dart:ui' as ui;

import '../services/comic_identity.dart';
import '../services/comic_page_source.dart';
import '../services/native_opencv_service.dart';
import '../services/panel_detection_service.dart';
import '../services/reading_progress_service.dart';
import '../services/page_turn_sound_controller.dart';
import '../widgets/comic_panel_painter.dart';
import '../widgets/comic_page_curl_transition.dart';

// Defines the available modes for showing full-page views before/after panel steps
enum FullPageStepMode { none, afterLast, beforeFirst, both }

// Explicit state tracking for full-page positions
enum FullPagePosition { none, beforeFirst, afterLast }

// A single panel inside a spread: which physical page, and which panel on it
class _PanelRef {
  final int page;
  final int index;
  const _PanelRef(this.page, this.index);
}

// A zoom request that arrived while the pager was mid-turn (or the layout was
// being switched). The shared TransformationController must not change while a
// curl is peeling a snapshot of the page, so the request is parked and replayed
// once the pager settles - but only if the reader is still where it was.
class _DeferredZoom {
  const _DeferredZoom.focus(this.page, ComicPanel this.panel, this.epoch);
  const _DeferredZoom.fullPage(this.page, this.epoch) : panel = null;

  final int page; // physical page the request was made for
  final ComicPanel? panel; // null = zoom out to the full page
  final int epoch; // layout epoch the request was made in
}

// ---------------------------------------------------------------------------
// Double-page layout rules (pure functions, no widget state)
// ---------------------------------------------------------------------------

// Google Books style pairing. Depends only on which pages are "wide", so it can
// run anywhere, including a background isolate.
List<List<int?>> _computeDoubleLayout(List<bool> wide) {
  final int count = wide.length;
  final List<List<int?>> layout = <List<int?>>[];
  int i = 0;

  while (i < count) {
    final bool isWide = wide[i];
    final bool isCover = (i == 0);

    if (isCover || isWide || i == count - 1) {
      if (isWide) {
        layout.add(<int?>[i]);
      } else {
        layout.add(<int?>[null, i]);
      }
      i++;
    } else {
      if (i + 1 < count) {
        if (wide[i + 1]) {
          layout.add(<int?>[null, i]);
          i++;
        } else {
          layout.add(<int?>[i, i + 1]);
          i += 2;
        }
      } else {
        layout.add(<int?>[null, i]);
        i++;
      }
    }
  }
  return layout;
}

// Short books are laid out inline (a few microseconds). Long ones are computed
// on a background isolate so the UI thread never stalls. The result crosses the
// isolate boundary as a flat int list ([first, second] per spread; -1 = blank
// left half, -2 = single-page spread) so its element types are always exact.
Future<List<List<int?>>> _computeDoubleLayoutOffThread(List<bool> wide) async {
  if (wide.length < 200) return _computeDoubleLayout(wide);
  try {
    final List<int> flat = await Isolate.run<List<int>>(() {
      final List<int> out = <int>[];
      for (final List<int?> spread in _computeDoubleLayout(wide)) {
        if (spread.length == 1) {
          out
            ..add(spread[0]!)
            ..add(-2);
        } else {
          out
            ..add(spread[0] ?? -1)
            ..add(spread[1]!);
        }
      }
      return out;
    });
    final List<List<int?>> layout = <List<int?>>[];
    for (int k = 0; k + 1 < flat.length; k += 2) {
      final int a = flat[k];
      final int b = flat[k + 1];
      layout.add(b == -2 ? <int?>[a] : <int?>[a == -1 ? null : a, b]);
    }
    return layout;
  } catch (e) {
    debugPrint('Background layout failed, computing inline: $e');
    return _computeDoubleLayout(wide);
  }
}

class ComicReaderScreen extends StatefulWidget {
  /// Pages are read from here one at a time, only when they are needed.
  final ComicPageSource source;

  /// Identifies the comic for saving/restoring the reading position.
  /// When null, nothing is saved or restored.
  final ComicIdentity? comic;

  const ComicReaderScreen({super.key, required this.source, this.comic});

  /// For callers that still hold every page in memory.
  factory ComicReaderScreen.fromBytes({
    Key? key,
    required List<Uint8List> pageBytes,
    ComicIdentity? comic,
  }) => ComicReaderScreen(
    key: key,
    source: InMemoryPageSource(pageBytes),
    comic: comic,
  );

  @override
  State<ComicReaderScreen> createState() => _ComicReaderScreenState();
}

class _ComicReaderScreenState extends State<ComicReaderScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  double _dimmingLevel = 0.90;

  // Page-turn audio is preloaded independently from navigation so play() never
  // blocks a gesture, the curl animation or a panel transition.
  final PageTurnSoundController _pageTurnSound = PageTurnSoundController();
  bool _pageSoundEnabled = true;
  double _pageSoundVolume = 0.46;
  String? _customPageSoundName;

  // ... rest of your code ...
  // Virtual page the PageView opens on. Set by the progress restore before the
  // first build; the controller is created lazily so it can use it.
  int _initialVirtualPage = 0;
  late final PageController _pageController = PageController(
    initialPage: _initialVirtualPage,
  );
  late final TransformationController _transformationController;
  late final AnimationController _animationController;
  Animation<Matrix4>? _zoomAnimation;

  // Caches for detected panels and original image dimensions per physical page
  final Map<int, List<ComicPanel>> _detectedPanelsCache = {};
  final Map<int, Size> _imageSizesCache = {};
  // In-flight detection jobs (prevents running detection twice for one page)
  final Map<int, Future<List<ComicPanel>>> _panelJobs = {};

  // Lazy page window: encoded bytes of the pages near the reader. Sizes stay
  // in _imageSizesCache for every page once the background sweep has run.
  final Map<int, Uint8List> _pageBytes = {};
  final Map<int, Future<void>> _pageLoads = {};
  // Pages whose bytes were requested from build (see _requestPageBytes).
  final Set<int> _pageLoadRequested = <int>{};
  // Shown for a page whose panels are not detected yet: the whole page counts
  // as ONE panel. Taps and swipes read only the cache plus this fallback, so
  // they never wait for the worker; real panels replace it as soon as they land.
  static const List<ComicPanel> _fullPageFallback = <ComicPanel>[
    ComicPanel(x: 0.0, y: 0.0, width: 1.0, height: 1.0),
  ];

  // Spread whose arrival fix-up (_finishArrival) is still waiting for detection.
  int _pendingArrivalSpread = -1;

  // Ceiling for waits that run purely in the background, so they can never
  // dangle forever on a stalled worker. Nothing on the gesture path uses it.
  static const Duration _panelBackgroundCeiling = Duration(seconds: 15);

  // Spread slide and the guards around it. The guard is deliberately only a
  // little longer than the animation, so a stuck animation cannot hold the
  // navigation lock.
  static const Duration _slideDuration = Duration(milliseconds: 500);
  static const Duration _slideGuard = Duration(milliseconds: 300);
  static const Duration _frameGuard = Duration(milliseconds: 120);

  // Hard upper bound for _navBusy. Whatever happens inside a transition, the
  // lock is released by a timer after this long. It covers the slide plus the
  // short wait for a fresh curl snapshot (_refreshCurlSnapshotForTurn), so it
  // cannot expire while a transition is still legitimately running.
  static const Duration _navLockMax = Duration(milliseconds: 600);
  int _navToken = 0;
  Timer? _navWatchdog;

  // True once every page is measured and the spread layout is built.
  bool _layoutReady = false;
  int _lastSyncedPage = -1;
  bool _lastSyncedDouble = false;

  // Layouts for single and double spread modes
  final List<List<int>> _singleLayout = [];
  List<List<int?>> _doubleLayout = [];

  // Reader state
  int _currentPage = 0; // physical page index
  int _currentPanelIndex = 0;
  bool _isEngineReady = false;

  // Reading-progress persistence (see "Reading progress" section below)
  ReadingProgressTracker? _progress;
  Future<ReadingProgress?>? _savedProgressFuture;
  bool _progressTrackingEnabled = false;

  // True while a programmatic page transition (or layout switch) is running.
  // Taps are ignored and onPageChanged is suppressed during this time.
  bool _navBusy = false;
  Timer? _prefetchTimer;

  // Display configuration toggles
  bool _showPanelOutlines = false;
  bool _showPanelOverlays = true;
  bool _showUI = true;
  bool _isDoublePageView = false;

  // Curl indices are layout-relative. Disable the curl layer while switching
  // between single-page and spread layouts, then re-enable it after the
  // PageController has been moved to the matching index in the new layout.
  bool _suspendCurlForLayoutSwitch = false;

  // --- curl <-> zoom coordination -------------------------------------------
  //
  // The curl peels a raster snapshot of the settled page. While a turn is in
  // flight nothing may change what that page looks like or where it sits:
  //  * the shared TransformationController is only reset, animated or handed
  //    to another page while the pager is settled (requests are deferred),
  //  * the curl geometry reads a frozen copy of "which spread is zoomed" that
  //    is only refreshed while settled, so the paper rect cannot flip mid-turn,
  //  * every async continuation of a layout switch carries an epoch and is
  //    dropped when a newer switch has started.
  final ComicCurlSnapshotController _curlSnapshot =
      ComicCurlSnapshotController();
  final ValueNotifier<int> _curlSnapshotTick = ValueNotifier<int>(0);
  int _curlSignature = 0;
  bool _curlSnapshotDirty = false;
  int _layoutEpoch = 0;
  bool _pagerListenerAttached = false;
  // Virtual index whose live content is zoomed, as the curl layer sees it.
  int? _curlZoomedVirtual;
  // Virtual index that owns the shared TransformationController.
  int? _zoomOwnerVirtual;
  bool _zoomResetPending = false;
  _DeferredZoom? _deferredZoom;
  Offset? _pointerDownAt;
  static const double _zoomFastForwardSlop = 9.0;

  // The slider has its own notifier so pointer-move updates rebuild only the
  // footer, not the comic pages or their image/panel widgets.
  final ValueNotifier<double> _footerPageValue = ValueNotifier<double>(1.0);
  bool _isFooterScrubbing = false;

  FullPageStepMode _fullPageStepMode = FullPageStepMode.none;
  FullPagePosition _fullPagePosition = FullPagePosition.none;

  bool _isScreenLocked = true;
  Size? _lastViewportSize;

  bool get _wantsBefore =>
      _fullPageStepMode == FullPageStepMode.beforeFirst ||
      _fullPageStepMode == FullPageStepMode.both;
  bool get _wantsAfter =>
      _fullPageStepMode == FullPageStepMode.afterLast ||
      _fullPageStepMode == FullPageStepMode.both;

  // --- ADD THIS DIALOG METHOD ---
  void _showDimmingDialog() {
    showDialog(
      context: context,
      builder: (context) {
        double tempDimming = _dimmingLevel;
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return AlertDialog(
              title: const Text('Adjust Dimming Level'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('${(tempDimming * 100).toStringAsFixed(0)}%'),
                  Slider(
                    value: tempDimming,
                    min: 0.0,
                    max: 1.0,
                    divisions: 20,
                    label: '${(tempDimming * 100).toStringAsFixed(0)}%',
                    onChanged: (val) {
                      setStateDialog(() {
                        tempDimming = val;
                      });
                    },
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () {
                    setState(() {
                      _dimmingLevel = tempDimming;
                    });
                    Navigator.pop(context);
                  },
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  void initState() {
    super.initState();
    // (_pageController is created lazily, see its declaration)
    WidgetsBinding.instance.addObserver(this);
    unawaited(_loadPageSoundSettings());
    final comic = widget.comic;
    if (comic != null) {
      // Short debounce: the position reaches storage shortly after every
      // navigation change instead of only after 1.5 s of stillness.
      _progress = ReadingProgressTracker(
        comic: comic,
        debounce: const Duration(milliseconds: 500),
      );
      _savedProgressFuture = ReadingProgressService.load(comic.id);
      unawaited(ReadingProgressService.markOpened(comic));
    }
    _transformationController = TransformationController()
      ..addListener(_onZoomChanged);
    _animationController =
        AnimationController(
            vsync: this,
            duration: const Duration(milliseconds: 500),
          )
          ..addListener(() {
            if (_zoomAnimation != null) {
              _transformationController.value = _zoomAnimation!.value;
            }
          });

    for (int i = 0; i < _pageCount; i++) {
      _singleLayout.add([i]);
    }

    // Nothing heavy runs before the first frame: the spinner is drawn first,
    // then only the opening page is read, and everything else follows lazily
    // (see _bootstrap).
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  // Runs while the route is being removed, before the State is detached: the
  // write is started here (non-blocking) so it is already under way - usually
  // finished - by the time the previous screen shows "Continue reading".
  @override
  void deactivate() {
    unawaited(_flushProgress());
    super.deactivate();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    final ReadingProgressTracker? tracker = _progress;
    _progress = null;
    _progressTrackingEnabled = false;
    if (tracker != null) {
      // Flush is allowed after close; it needs nothing from this State.
      unawaited(
        tracker.dispose().catchError((Object e, StackTrace st) {
          debugPrint('Final progress write failed: $e\n$st');
        }),
      );
    }
    _prefetchTimer?.cancel();
    _navWatchdog?.cancel();
    PanelDetectionService.instance.cancelAll();
    _pageBytes.clear();
    _deferredZoom = null;
    _detachPagerListener();
    _animationController.dispose();
    _transformationController.removeListener(_onZoomChanged);
    _transformationController.dispose();
    _pageController.dispose();
    _footerPageValue.dispose();
    _curlSnapshotTick.dispose();
    unawaited(_pageTurnSound.dispose());
    super.dispose();
  }

  Future<void> _loadPageSoundSettings() async {
    try {
      await _pageTurnSound.initialize();
      if (!mounted) return;
      setState(() {
        _pageSoundEnabled = _pageTurnSound.enabled;
        _pageSoundVolume = _pageTurnSound.volume;
        _customPageSoundName = _pageTurnSound.customSoundName;
      });
    } catch (error, stackTrace) {
      // Audio is optional; never let a sound backend failure interrupt reading.
      debugPrint('Page-sound initialization failed: $error\n$stackTrace');
    }
  }

  void _showPageSoundDialog() {
    showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter updateDialog) {
            return AlertDialog(
              title: const Text('Page Sound'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Play sound on page turns'),
                      value: _pageSoundEnabled,
                      onChanged: (bool value) {
                        updateDialog(() => _pageSoundEnabled = value);
                        setState(() => _pageSoundEnabled = value);
                        unawaited(_pageTurnSound.setEnabled(value));
                      },
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        const Text('Volume'),
                        const Spacer(),
                        Text('${(_pageSoundVolume * 100).round()}%'),
                      ],
                    ),
                    Slider(
                      value: _pageSoundVolume.clamp(0.0, 1.0).toDouble(),
                      min: 0.0,
                      max: 1.0,
                      divisions: 20,
                      onChanged: (double value) {
                        updateDialog(() => _pageSoundVolume = value);
                      },
                      onChangeEnd: (double value) {
                        if (!mounted) return;
                        setState(() => _pageSoundVolume = value);
                        unawaited(_pageTurnSound.setVolume(value));
                      },
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _customPageSoundName == null
                          ? 'Sound: Built-in paper rustle'
                          : 'Sound: $_customPageSoundName',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Supported custom formats: WAV, MP3 and M4A (up to 8 MB).',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () async {
                    try {
                      final String? name =
                          await _pageTurnSound.importCustomSound();
                      if (name == null || !mounted) return;
                      setState(() => _customPageSoundName = name);
                      if (dialogContext.mounted) {
                        updateDialog(() => _customPageSoundName = name);
                      }
                    } catch (error, stackTrace) {
                      debugPrint('Custom page-sound import failed: $error\n$stackTrace');
                      if (!mounted) return;
                      ScaffoldMessenger.of(this.context).showSnackBar(
                        SnackBar(content: Text('Could not import page sound: $error')),
                      );
                    }
                  },
                  child: const Text('Import custom'),
                ),
                if (_customPageSoundName != null)
                  TextButton(
                    onPressed: () async {
                      try {
                        await _pageTurnSound.useBundledSound();
                        if (!mounted) return;
                        setState(() => _customPageSoundName = null);
                        if (dialogContext.mounted) {
                          updateDialog(() => _customPageSoundName = null);
                        }
                      } catch (error, stackTrace) {
                        debugPrint('Could not restore bundled page sound: $error\n$stackTrace');
                        if (!mounted) return;
                        ScaffoldMessenger.of(this.context).showSnackBar(
                          SnackBar(content: Text('Could not restore default sound: $error')),
                        );
                      }
                    },
                    child: const Text('Use default'),
                  ),
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Done'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // Called by ComicCurlPageView at the first non-zero pager movement. This is
  // intentionally independent of _navBusy: tap-driven _goToSpread animations
  // hold that lock but are still real animated page turns. Layout remaps disable
  // the curl widget and instant jumpToPage calls do not emit the callback.
  void _onCurlPageTurnStarted(int fromVirtualIndex, int toVirtualIndex) {
    if (!mounted ||
        !_isEngineReady ||
        !_pageSoundEnabled ||
        _suspendCurlForLayoutSwitch ||
        fromVirtualIndex == toVirtualIndex) {
      return;
    }
    final List<List<int>> layout = _getEffectiveLayout();
    if (fromVirtualIndex < 0 ||
        fromVirtualIndex >= layout.length ||
        toVirtualIndex < 0 ||
        toVirtualIndex >= layout.length) {
      return;
    }
    _pageTurnSound.play();
  }

  // ---------------------------------------------------------------------------
  // Lazy page window (bytes, sizes, codecs, detection focus)
  // ---------------------------------------------------------------------------
  //
  // Before the first frame only the page the reader opens on is read and
  // measured. Pages within one spread of it are then loaded and their image
  // codecs warmed; every other page's size comes from a cheap header sweep in a
  // background isolate; panel detection is limited to the same window.

  int get _pageCount => widget.source.pageCount;

  // Extra pages kept in memory beyond the wanted window (current spread and one
  // spread each side), so a page the PageView is still building never loses its bytes.
  static const int _extraResidentPages = 2;

  Future<void> _bootstrap() async {
    try {
      unawaited(NativeOpenCvService.initializeEngine().catchError((Object e, StackTrace st) {
        debugPrint('YOLO engine init failed: $e\n$st');
      }));

      if (_pageCount > 0) {
        _detectedPanelsCache[0] = const [ComicPanel(x: 0.0, y: 0.0, width: 1.0, height: 1.0)];
      }

      final ReadingProgress? saved = await _savedProgressFuture;
      if (saved != null && _pageCount > 0) {
        _currentPage = saved.page.clamp(0, _pageCount - 1);
        _currentPanelIndex = saved.panelIndex < 0 ? 0 : saved.panelIndex;
        _initialVirtualPage = _findVirtualPageIndex(_currentPage);
      }

      // Load the first page with safety fallback
      try {
        await _ensurePageLoaded(_currentPage).timeout(const Duration(seconds: 8));
      } catch (e) {
        debugPrint('Warning: First page load timed out or failed, showing blank fallback: $e');
      }

      if (!mounted) return;

      // _initialVirtualPage is final by now, so the lazily created controller
      // gets the restored page; hook the settle detection to it.
      _attachPagerListener();
      setState(() {
        _isEngineReady = true; // Guarantees the loading screen dismisses
        if (_wantsBefore) {
          _fullPagePosition = FullPagePosition.beforeFirst;
        }
      });

      // Start tracking as soon as the saved page is applied. It used to wait for
      // the saved page's panel detection, so leaving (or turning pages) before
      // that finished silently lost the new position.
      _progress?.seed(saved?.page ?? 0, saved?.panelIndex ?? 0);
      _progressTrackingEnabled = true;
      _reportProgress();

      unawaited(_loadRemainingLayoutData());
      _schedulePrefetch(_initialVirtualPage);
      await _finishProgressRestore(saved);

    } catch (e, stackTrace) {
      debugPrint('FATAL: Error in reader bootstrap: $e\n$stackTrace');
      if (mounted && !_isEngineReady) {
        _attachPagerListener();
        setState(() => _isEngineReady = true); // Forces spinner to stop on fatal error
      }
    }
  }

  // Makes sure the bytes and the size of [page] are available. Concurrent
  // callers share one load.
  Future<void> _ensurePageLoaded(int page) {
    if (page < 0 || page >= _pageCount) return Future<void>.value();
    if (_pageBytes.containsKey(page) && _imageSizesCache.containsKey(page)) {
      return Future<void>.value();
    }
    final Future<void>? running = _pageLoads[page];
    if (running != null) return running;

    final Future<void> load = _loadPage(page)
        .whenComplete(() => _pageLoads.remove(page));
    _pageLoads[page] = load;
    return load;
  }

  // Called from build when a page's bytes are not resident yet (e.g. the right
  // half of a spread whose read is slower than the left half). Starts the load
  // after the frame; _loadPage calls setState the moment the bytes land, so the
  // picture appears by itself without any further user action.
  void _requestPageBytes(int page) {
    if (page < 0 || page >= _pageCount) return;
    if (_pageBytes.containsKey(page) || _pageLoads.containsKey(page)) return;
    if (!_pageLoadRequested.add(page)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pageLoadRequested.remove(page);
      if (!mounted) return;
      unawaited(_ensurePageLoaded(page));
    });
  }

  Future<void> _loadPage(int page) async {
    Uint8List? bytes = _pageBytes[page];
    if (bytes == null) {
      // One quick retry: a single slow or failed read must not leave the
      // page black for the rest of the session.
      for (int attempt = 0; attempt < 2 && bytes == null; attempt++) {
        try {
          // 5-second timeout safeguard so page reading never hangs indefinitely
          bytes = await widget.source
              .readPage(page)
              .timeout(
                const Duration(seconds: 5),
                onTimeout: () =>
                    throw TimeoutException('Page read timed out for page $page'),
              );
        } catch (e, st) {
          debugPrint('Error reading page $page (attempt ${attempt + 1}): $e\n$st');
          if (!mounted) return;
          if (attempt == 0) {
            await Future<void>.delayed(const Duration(milliseconds: 250));
          }
        }
      }
      if (bytes == null) return; // exit cleanly without locking the UI
    }
    if (!mounted) return;
    _pageBytes[page] = bytes;

    // Show the picture as soon as its bytes exist; measuring can take longer.
    if (_isEngineReady) setState(() {});

    if (!_imageSizesCache.containsKey(page)) {
      final Size? size = await _measurePage(bytes);
      if (!mounted) return;
      if (size != null) {
        _imageSizesCache[page] = size;
        if (_isEngineReady) setState(() {});
      }
    }
    // A page may have been loaded by the UI after its earlier detection
    // attempt found no bytes. Make sure it gets another detection request.
    if (mounted &&
        _isPageInCurrentSpread(page) &&
        !_detectedPanelsCache.containsKey(page)) {
      unawaited(_ensurePanels(page));
    }

  }

  // Width/height without decoding pixels: header parse first, then Flutter's
  // ImageDescriptor (which also only reads the header). Null if neither works.
  Future<Size?> _measurePage(Uint8List bytes) async {
    final PageDimensions? quick = ImageHeaderSniffer.sniff(bytes);
    if (quick != null)
      return Size(quick.width.toDouble(), quick.height.toDouble());

    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      return Size(descriptor.width.toDouble(), descriptor.height.toDouble());
    } catch (e) {
      debugPrint('Could not measure page: $e');
      return null;
    } finally {
      descriptor?.dispose();
      buffer?.dispose();
    }
  }

  // Loads [pages] (current page first) and instantiates their image codecs
  // now, in the engine's background threads, so a page turn finds the decoded
  // image already in the ImageCache.
  Future<void> _warmWindow(List<int> pages) async {
    for (final int page in pages) {
      try {
        await _ensurePageLoaded(page);
        final Uint8List? bytes = _pageBytes[page];
        if (!mounted || bytes == null) continue;
        await precacheImage(MemoryImage(bytes), context);
      } catch (e) {
        debugPrint('Could not warm up page $page: $e');
      }
    }
  }

  // Drops the bytes (and the decoded image) of pages far from the reader.
  void _trimWindow(Set<int> wanted) {
    if (wanted.isEmpty) return;
    final int lo = wanted.reduce(math.min) - _extraResidentPages;
    final int hi = wanted.reduce(math.max) + _extraResidentPages;
    final List<int> far = _pageBytes.keys
        .where((int p) => p < lo || p > hi)
        .toList();
    for (final int page in far) {
      final Uint8List? bytes = _pageBytes.remove(page);
      if (bytes != null) unawaited(MemoryImage(bytes).evict());
    }
  }

  // Called from setState: when the current page (or the spread mode) changed,
  // moves the lazy window and the detection focus to the new spread +-1.
  void _syncFocus() {
    if (!_isEngineReady || !mounted) return;
    if (_currentPage == _lastSyncedPage &&
        _isDoublePageView == _lastSyncedDouble)
      return;

    final List<List<int>> layout = _getEffectiveLayout();
    if (layout.isEmpty) return;
    _lastSyncedPage = _currentPage;
    _lastSyncedDouble = _isDoublePageView;

    final int v = _findVirtualPageIndex(_currentPage);
    final List<int> ordered = <int>[]; // current spread, next, previous
    for (final int spread in <int>[v, v + 1, v - 1]) {
      if (spread < 0 || spread >= layout.length) continue;
      ordered.addAll(layout[spread]);
    }
    final Set<int> wanted = ordered.toSet();

    // Pages outside this set that are still waiting for detection are
    // cancelled immediately; nothing new starts until the page stops changing.
    // Both pages of the current spread share the top priority.
    PanelDetectionService.instance.updateFocus(
      _currentPage,
      wanted,
      activePages: layout[v].toSet(),
    );
    _trimWindow(wanted);
    unawaited(_warmWindow(ordered));
  }

  // Measures every page from its header, in a background isolate, then builds
  // the double-page layout (it needs every page's aspect ratio). Spread mode
  // stays disabled until this has finished.
  Future<void> _loadRemainingLayoutData() async {
    try {
      final List<PageDimensions?> dims = await widget.source
          .readAllDimensions();
      if (!mounted) return;
      for (int i = 0; i < dims.length && i < _pageCount; i++) {
        final PageDimensions? d = dims[i];
        if (d != null && !_imageSizesCache.containsKey(i)) {
          _imageSizesCache[i] = Size(d.width.toDouble(), d.height.toDouble());
        }
      }

      // Rare: a header the sniffer could not parse. Measure those the slow way.
      for (int i = 0; i < _pageCount; i++) {
        if (_imageSizesCache.containsKey(i)) continue;
        try {
          final Uint8List bytes =
              _pageBytes[i] ?? await widget.source.readPage(i);
          final Size? size = await _measurePage(bytes);
          if (size != null) _imageSizesCache[i] = size;
        } catch (e) {
          debugPrint('Could not measure page $i: $e');
        }
        if (!mounted) return;
      }

      await _buildDoubleLayout();
      if (!mounted) return;
      setState(() => _layoutReady = true);
    } catch (e, st) {
      debugPrint('Error measuring pages: $e\n$st');
    }
  }

  // ---------------------------------------------------------------------------
  // Layout helpers
  // ---------------------------------------------------------------------------

  // Builds the double-page layout. The pairing rules only depend on which pages
  // are wide, so long books are computed on a background isolate and the UI
  // thread just receives the finished list. Toggling spread view never calls
  // this: it only switches between two layouts that already exist.
  Future<void> _buildDoubleLayout() async {
    final List<bool> wide = List<bool>.generate(_pageCount, (int i) {
      final Size? size = _imageSizesCache[i];
      return size != null && size.width > size.height * 1.15;
    }, growable: false);

    final List<List<int?>> layout = await _computeDoubleLayoutOffThread(wide);
    if (!mounted) return;
    _doubleLayout = layout;
  }

  // Active layout (null placeholders removed)
  List<List<int>> _getEffectiveLayout() {
    if (_isDoublePageView) {
      return _doubleLayout
          .map((spread) => spread.whereType<int>().toList())
          .toList();
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

  bool _allDetected(List<int> pages) =>
      pages.every(_detectedPanelsCache.containsKey);

  // Panels of one page for navigation: the detected ones, or the full-page
  // fallback while detection is still running. Never waits.
  List<ComicPanel> _panelsOf(int page) =>
      _detectedPanelsCache[page] ?? _fullPageFallback;

  // Every panel of a spread, left page first, then right. Cache only: a page
  // still being detected counts as one full-page panel, so stepping through a
  // spread never skips a page and never waits.
  List<_PanelRef> _cachedSequence(List<int> pages) {
    final out = <_PanelRef>[];
    for (final p in pages) {
      final panels = _panelsOf(p);
      for (int i = 0; i < panels.length; i++) {
        out.add(_PanelRef(p, i));
      }
    }
    return out;
  }

  // BACKGROUND ONLY (never from a gesture handler): starts detection of every
  // page in [pages] together and waits for them, up to [budget]. A timeout does
  // not cancel the detection; its result still arrives through setState.
  Future<bool> _waitForPanels(List<int> pages, Duration budget) async {
    if (_allDetected(pages)) return true;
    try {
      await Future.wait(
        pages
            .where((int p) => !_detectedPanelsCache.containsKey(p))
            .map(_ensurePanels),
      ).timeout(budget, onTimeout: () => const <List<ComicPanel>>[]);
    } catch (e, st) {
      debugPrint('Waiting for panel detection failed: $e\n$st');
    }
    return _allDetected(pages);
  }

  Future<void> _ensureSpreadPanels(List<int> pages) async {
    if (!mounted || pages.isEmpty) return;

    final List<int> validPages = pages
        .where((int page) => page >= 0 && page < _pageCount)
        .toList();

    // Get both pages' bytes first, concurrently.
    await Future.wait(
      validPages.map(_ensurePageLoaded),
    );

    if (!mounted) return;

    final List<int> readyPages = validPages
        .where((int page) => _pageBytes.containsKey(page))
        .toList();

    final List<int> missingPages = validPages
        .where((int page) => !_pageBytes.containsKey(page))
        .toList();

    if (missingPages.isNotEmpty) {
      debugPrint(
        '[SpreadDetection] Pages still missing bytes: $missingPages',
      );
    }

    // Queue detection for every page whose bytes are available.
    if (readyPages.isNotEmpty) {
      await _waitForPanels(
        readyPages,
        _panelBackgroundCeiling,
      );
    }
  }
  

  int _currentSeqPos(List<_PanelRef> seq) {
    for (int i = 0; i < seq.length; i++) {
      if (seq[i].page == _currentPage && seq[i].index == _currentPanelIndex)
        return i;
    }
    return -1;
  }

  // Where a physical page is drawn inside the viewport (mirrors the widgets in build)
  Rect? _pageRect(int virtualIndex, int page, Size vp) {
    final imgSize = _imageSizesCache[page];
    if (imgSize == null) return null;

    final double cw = vp.width;
    final double ch = vp.height;

    // Called from the curl layer and from async continuations; a virtual
    // index from another layout must yield "unknown", never a RangeError.
    final List<int?> spread;
    if (_isDoublePageView) {
      if (virtualIndex < 0 || virtualIndex >= _doubleLayout.length) {
        return null;
      }
      spread = _doubleLayout[virtualIndex];
      if (spread.isEmpty) return null;
    } else {
      spread = <int?>[page];
    }

    if (spread.length == 1) {
      final double fit = math.min(cw / imgSize.width, ch / imgSize.height);
      final double w = imgSize.width * fit;
      final double h = imgSize.height * fit;
      return Rect.fromLTWH((cw - w) / 2.0, (ch - h) / 2.0, w, h);
    }

    final int? a = spread[0];
    final int? b = spread[1];
    final Size? sizeA = a != null ? _imageSizesCache[a] : null;
    final Size? sizeB = b != null ? _imageSizesCache[b] : null;

    final double wB = sizeB != null
        ? ch * (sizeB.width / sizeB.height)
        : cw / 2;
    final double wA = sizeA != null ? ch * (sizeA.width / sizeA.height) : wB;

    double scale = 1.0;
    if ((wA + wB) > cw) {
      scale = cw / (wA + wB);
    }

    final double totalW = (wA + wB) * scale;
    final double totalH = ch * scale;
    final double baseX = (cw - totalW) / 2.0;
    final double baseY = (ch - totalH) / 2.0;

    if (page == a) {
      return Rect.fromLTWH(baseX, baseY, wA * scale, totalH);
    }
    return Rect.fromLTWH(baseX + wA * scale, baseY, wB * scale, totalH);
  }

  // ---------------------------------------------------------------------------
  // Panel detection (cached, de-duplicated, prefetched)
  // ---------------------------------------------------------------------------

  Future<List<ComicPanel>> _ensurePanels(int index) {
    final cached = _detectedPanelsCache[index];
    if (cached != null) return Future.value(cached);

    final running = _panelJobs[index];
    if (running != null) return running;

    final job = _detectPanels(index)
        .whenComplete(() => _panelJobs.remove(index));
    _panelJobs[index] = job;
    return job;
  }

  bool _isPageInCurrentSpread(int page) {
    final layout = _getEffectiveLayout();
    if (layout.isEmpty) return false;

    final int virtualIndex = _findVirtualPageIndex(_currentPage);

    return virtualIndex >= 0 &&
        virtualIndex < layout.length &&
        layout[virtualIndex].contains(page);
  }

  Future<List<ComicPanel>> _detectPanels(int index) async {
    if (index == 0) {
      const cover = <ComicPanel>[
        ComicPanel(x: 0.0, y: 0.0, width: 1.0, height: 1.0),
      ];
      _detectedPanelsCache[0] = cover;
      return cover;
    }

    List<ComicPanel>? detected;
    try {
      // The page may have been trimmed out of the resident window meanwhile.
      await _ensurePageLoaded(index);
      final Uint8List? bytes = _pageBytes[index];
      if (bytes == null) return const <ComicPanel>[];

      // Decoding (engine threads) and inference (worker isolate) both happen
      // off the UI isolate. Completes with null when the user flung past this
      // page before its turn came.
      detected = await PanelDetectionService.instance.detect(index, bytes);
    } catch (e, st) {
      debugPrint(
        'Error running OpenCV panel detection on page $index: $e\n$st',
      );
      detected =
          const <
            ComicPanel
          >[]; // as before: a failed page is cached as "no panels"
    }

    // Cancelled: do NOT cache anything, so the page is detected normally the
    // next time it becomes relevant.
    if (detected == null) return const <ComicPanel>[];
    final List<ComicPanel> panels = detected;

    if (!mounted) return panels;
    setState(() {
      _detectedPanelsCache[index] = panels;
    });
    _onPanelsArrived(index, panels);
    return panels;
  }

  // Detection of [page] just finished. If the reader is sitting on that page
  // (on the full-page fallback), swap the fallback for the real panel: clamp the
  // index and zoom onto it. Runs entirely on the back of the worker's result;
  // no gesture ever waited for it.
  void _onPanelsArrived(int page, List<ComicPanel> panels) {
    if (!mounted || panels.isEmpty) return;
    if (page != _currentPage || _fullPagePosition != FullPagePosition.none) {
      return;
    }
    // An arrival fix-up for this spread is pending; it positions the reader.
    if (_pendingArrivalSpread != -1 &&
        _findVirtualPageIndex(page) == _pendingArrivalSpread) {
      return;
    }
    final Size? vp = _lastViewportSize;
    if (vp == null || _navBusy || _suspendCurlForLayoutSwitch) return;

    final int idx = _currentPanelIndex < panels.length
        ? _currentPanelIndex
        : panels.length - 1;
    if (idx != _currentPanelIndex) {
      setState(() => _currentPanelIndex = idx);
    }
    _focusOnPanel(panels[idx], vp);
  }

  // Detects neighbouring spreads in the background so page turns never have to
  // wait for (or freeze on) detection while animating.
  void _schedulePrefetch(int virtualIndex) {
    // A late call for a spread the user has already flung past must not
    // replace the timer of the spread they are really on.
    if (_getEffectiveLayout().isNotEmpty &&
        virtualIndex != _findVirtualPageIndex(_currentPage))
      return;
    _prefetchTimer?.cancel();
    _prefetchTimer = Timer(const Duration(milliseconds: 350), () async {
      if (!mounted || _navBusy || _suspendCurlForLayoutSwitch) return;
      final layout = _getEffectiveLayout();
      for (final v in [virtualIndex + 1, virtualIndex - 1]) {
        if (v < 0 || v >= layout.length) continue;
        if (!mounted || _navBusy || _suspendCurlForLayoutSwitch) return;
        await _ensureSpreadPanels(layout[v]);
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Zoom helpers
  // ---------------------------------------------------------------------------
  //
  // Rule: the shared TransformationController is only reset, animated or
  // handed to another page while the pager is settled and no layout switch is
  // running. Anything else is parked ([_deferredZoom], [_zoomResetPending]) and
  // applied by [_onPagerSettled]. A curl that is peeling a snapshot of the page
  // therefore never sees the page change under it.

  // Pager threshold for "at rest". Same value the curl layer uses to hand the
  // sheet back to the settled page.
  static const double _pagerSettleEps = 1e-4;

  // Page position without the asserts of PageController.page, which fire while
  // content dimensions are not established (e.g. in the frame an itemCount
  // change is applied). Null when there is no usable position.
  double? _safePagerPage() {
    // Before the pager listener is attached the controller may not exist yet
    // (it is created lazily with the restored page); never create it here.
    if (!_pagerListenerAttached ||
        !_pageController.hasClients ||
        _pageController.positions.length != 1) {
      return null;
    }
    final ScrollPosition position = _pageController.position;
    if (!position.hasPixels ||
        !position.hasViewportDimension ||
        position.viewportDimension <= 0.0) {
      return null;
    }
    double pixels = position.pixels;
    if (position.hasContentDimensions) {
      pixels = pixels
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble();
    }
    return pixels /
        (position.viewportDimension * _pageController.viewportFraction);
  }

  bool get _isPagerSettled {
    final double? page = _safePagerPage();
    if (page == null) return true; // nothing can be scrolling
    return (page - page.roundToDouble()).abs() < _pagerSettleEps;
  }

  bool get _canChangeZoom => !_suspendCurlForLayoutSwitch && _isPagerSettled;

  void _attachPagerListener() {
    if (_pagerListenerAttached) return;
    _pagerListenerAttached = true;
    _pageController.addListener(_onPagerTick);
  }

  void _detachPagerListener() {
    if (!_pagerListenerAttached) return;
    _pagerListenerAttached = false;
    _pageController.removeListener(_onPagerTick);
  }

  bool _settleCallbackScheduled = false;

  void _onPagerTick() {
    if (!mounted || !_isPagerSettled) return;
    // The controller also notifies from inside layout (viewport resize).
    // State may only be touched outside build/layout/paint.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      if (_settleCallbackScheduled) return;
      _settleCallbackScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _settleCallbackScheduled = false;
        if (mounted && _isPagerSettled) _onPagerSettled();
      });
      return;
    }
    _onPagerSettled();
  }

  // The pager is at rest on a page: apply everything that had to wait for it.
  void _onPagerSettled() {
    if (!mounted || _suspendCurlForLayoutSwitch) return;

    // 1. A zoom reset that was requested mid-turn (swipe arrival).
    if (_zoomResetPending) _resetZoomInstant();

    // 2. The curl's frozen view of the zoom state, and who owns the shared
    //    controller, now follow the settled page.
    _refreshCurlZoomState();
    final List<List<int>> layout = _getEffectiveLayout();
    if (layout.isNotEmpty &&
        _zoomOwnerVirtual != _findVirtualPageIndex(_currentPage)) {
      // build() re-derives the owner now that the pager is settled.
      setState(() {});
    }

    // 3. A panel zoom (or zoom-out) that arrived mid-turn.
    _flushDeferredZoom();
  }

  void _flushDeferredZoom() {
    final _DeferredZoom? pending = _deferredZoom;
    if (pending == null || !_canChangeZoom) return;
    _deferredZoom = null;
    // Replay only if the reader is exactly where the request was made.
    if (pending.epoch != _layoutEpoch || pending.page != _currentPage) return;

    final ComicPanel? panel = pending.panel;
    if (panel == null) {
      if (_fullPagePosition != FullPagePosition.none) _animateToFullPage();
      return;
    }
    final Size? viewport = _lastViewportSize;
    if (viewport == null || _fullPagePosition != FullPagePosition.none) return;
    _focusOnPanel(panel, viewport);
  }

  int? _currentVirtualOrNull() {
    final List<List<int>> layout = _getEffectiveLayout();
    return layout.isEmpty ? null : _findVirtualPageIndex(_currentPage);
  }

  void _onZoomChanged() => _refreshCurlZoomState();

  // What the curl geometry reads (see _curlPaperRect / _curlLeaves). Frozen
  // while a turn is in flight so the sheet's paper rect cannot flip from
  // "whole viewport" to "fitted page" halfway through a turn.
  void _refreshCurlZoomState() {
    if (_suspendCurlForLayoutSwitch || !_isPagerSettled) return;
    _curlZoomedVirtual = _transformationController.value.isIdentity()
        ? null
        : _currentVirtualOrNull();
  }

  // Cheap signature of everything that changes how the SETTLED page looks at
  // identity zoom. A change marks the curl snapshot dirty and, when the page
  // is not zoomed, asks the curl layer to re-capture it right away.
  void _syncCurlSignature() {
    final int signature = Object.hash(
      _currentPage,
      _currentPanelIndex,
      _fullPagePosition,
      _showPanelOutlines,
      _showPanelOverlays,
      _dimmingLevel,
      _isDoublePageView,
      _layoutEpoch,
    );
    if (signature == _curlSignature) return;
    _curlSignature = signature;
    _curlSnapshotDirty = true;
    if (!_suspendCurlForLayoutSwitch &&
        _transformationController.value.isIdentity()) {
      _curlSnapshotTick.value++;
    }
  }

  // Before a PROGRAMMATIC turn that starts from a zoomed (or changed) page the
  // stored snapshot no longer matches the page the turn will draw: the zoom is
  // reset to identity first, the panel dimming moved on, and a tap's
  // touch-down capture may even have caught the zoomed look. Give the reset one
  // frame to reach the screen, then wait (bounded) for a fresh capture.
  Future<void> _refreshCurlSnapshotForTurn(int epoch) async {
    try {
      await WidgetsBinding.instance.endOfFrame.timeout(
        _frameGuard,
        onTimeout: () {},
      );
      if (!mounted || epoch != _layoutEpoch || _suspendCurlForLayoutSwitch) {
        return;
      }
      await _curlSnapshot.refresh();
      _curlSnapshotDirty = false;
    } catch (e, st) {
      debugPrint('Curl snapshot refresh failed: $e\n$st');
    }
  }

  // A drag that starts while an automatic panel zoom is still running: land
  // the zoom now, so the touch-down snapshot, the curl paper rect and the live
  // page all agree on the final zoom. Taps are not affected (a tap never moves
  // far enough), so rapid panel tapping keeps its smooth retargeting.
  void _onReaderPointerMove(PointerMoveEvent event) {
    final Offset? origin = _pointerDownAt;
    if (origin == null || !_animationController.isAnimating) return;
    if ((event.position - origin).distance < _zoomFastForwardSlop) return;
    if (!_canChangeZoom) return;
    _pointerDownAt = null;
    _animationController.value = 1.0;
    _curlSnapshotTick.value++;
  }

  void _resetZoomInstant({bool force = false}) {
    if (!force && !_canChangeZoom) {
      // Mid-turn: the curl is peeling a snapshot of the zoomed page. The reset
      // is applied by _onPagerSettled; it also supersedes a parked panel zoom.
      _zoomResetPending = true;
      _deferredZoom = null;
      return;
    }
    _zoomResetPending = false;
    _animationController.stop();
    _zoomAnimation = null;
    _transformationController.value = Matrix4.identity();
  }

  void _animateToFullPage() {
    if (!_canChangeZoom) {
      _deferredZoom = _DeferredZoom.fullPage(_currentPage, _layoutEpoch);
      return;
    }
    if (_zoomResetPending) _resetZoomInstant();
    _deferredZoom = null;
    final Matrix4 beginMatrix = _transformationController.value;
    final Matrix4 endMatrix = Matrix4.identity();

    _zoomAnimation = Matrix4Tween(begin: beginMatrix, end: endMatrix).animate(
      CurvedAnimation(
        parent: _animationController,
        curve: Curves.easeInOutCubic,
      ),
    );

    _animationController.forward(from: 0.0);
  }

  // Zooms onto a panel of [_currentPage]
  void _focusOnPanel(ComicPanel panel, Size viewportSize) {
    if (viewportSize.width == 0 ||
        viewportSize.height == 0 ||
        _fullPagePosition != FullPagePosition.none)
      return;

    if (!_canChangeZoom) {
      // A turn is in flight (or the layout is being switched): zooming now
      // would change the page under a curl that is peeling its snapshot. Park
      // the request; _onPagerSettled replays it if the reader is still here.
      _deferredZoom = _DeferredZoom.focus(_currentPage, panel, _layoutEpoch);
      return;
    }
    // A reset that was parked mid-turn must land BEFORE this zoom starts, or
    // _onPagerSettled would reset it again right after it began.
    if (_zoomResetPending) _resetZoomInstant();
    _deferredZoom = null;

    final layout = _getEffectiveLayout();
    if (layout.isEmpty) return;
    final virtualIndex = _findVirtualPageIndex(_currentPage);
    final Rect? rect = _pageRect(virtualIndex, _currentPage, viewportSize);
    if (rect == null) return;

    final double containerW = viewportSize.width;
    final double containerH = viewportSize.height;

    final double panelScreenX = rect.left + (panel.x * rect.width);
    final double panelScreenY = rect.top + (panel.y * rect.height);
    final double panelScreenW = panel.width * rect.width;
    final double panelScreenH = panel.height * rect.height;

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
      ..translateByDouble(targetX, targetY, 0.0, 1.0)
      ..scaleByDouble(targetScale, targetScale, 1.0, 1.0);

    _zoomAnimation = Matrix4Tween(begin: beginMatrix, end: endMatrix).animate(
      CurvedAnimation(
        parent: _animationController,
        curve: Curves.easeInOutCubic,
      ),
    );

    _animationController.forward(from: 0.0);
  }

  // ---------------------------------------------------------------------------
  // Navigation
  // ---------------------------------------------------------------------------

  // Shows a specific panel (possibly on the other page of the same spread)
  void _showPanel(_PanelRef ref, Size vp) {
    if (_navBusy || _suspendCurlForLayoutSwitch) return;
    setState(() {
      _currentPage = ref.page;
      _currentPanelIndex = ref.index;
      _fullPagePosition = FullPagePosition.none;
    });
    final panels = _panelsOf(ref.page);
    if (ref.index < panels.length) {
      _focusOnPanel(panels[ref.index], vp);
    }
  }

  // --- navigation lock --------------------------------------------------------
  //
  // _navBusy is released by whoever took the lock OR by a watchdog after
  // _navLockMax, whichever comes first. The token makes sure a late release from
  // an old transition can never clear the lock of a newer one.
  int _lockNav() {
    _navBusy = true;
    final int token = ++_navToken;
    _navWatchdog?.cancel();
    _navWatchdog = Timer(_navLockMax, () {
      if (_navToken == token) _navBusy = false;
    });
    return token;
  }

  void _unlockNav(int token) {
    if (_navToken != token) return;
    _navWatchdog?.cancel();
    _navWatchdog = null;
    _navBusy = false;
  }

  /// Jumps to a physical comic page selected by the footer scrubber. The
  /// physical page is translated to the active virtual page/spread first.
  Future<void> _jumpToPhysicalPage(int requestedPage) async {
    if (_navBusy || _suspendCurlForLayoutSwitch || _pageCount <= 0) return;
    final int page = requestedPage.clamp(0, _pageCount - 1).toInt();
    final List<List<int>> layout = _getEffectiveLayout();
    if (layout.isEmpty) return;
    final int target = _findVirtualPageIndex(page)
        .clamp(0, layout.length - 1)
        .toInt();
    if (page == _currentPage && _safePagerPage()?.round() == target) {
      _footerPageValue.value = (page + 1).toDouble();
      return;
    }

    _pendingArrivalSpread = -1;
    final int epoch = _layoutEpoch;
    final bool wasZoomed =
        !_transformationController.value.isIdentity() ||
        _animationController.isAnimating;
    final int lock = _lockNav();
    try {
      _resetZoomInstant();
      if (mounted) {
        setState(() {
          _currentPage = page;
          _currentPanelIndex = 0;
          _fullPagePosition = FullPagePosition.none;
        });
      }
      await WidgetsBinding.instance.endOfFrame.timeout(
        _frameGuard,
        onTimeout: () {},
      );
      if (!mounted || epoch != _layoutEpoch) return;
      if (_pageController.hasClients) {
        final int currentIndex = _safePagerPage()?.round() ?? target;
        final int distance = (currentIndex - target).abs();

        // If jumping far, use an instant jump to avoid cascading page curls.
        // If close by (1-2 spreads away), keep the smooth animation.
        if (distance > 2) {
          _pageController.jumpToPage(target);
        } else {
          // The curl peels a snapshot of the page the turn starts from; make
          // sure it is the un-zoomed page, not the zoomed panel it replaced.
          if (wasZoomed || _curlSnapshotDirty) {
            await _refreshCurlSnapshotForTurn(epoch);
            if (!mounted || epoch != _layoutEpoch) return;
          }
          await _pageController.animateToPage(
            target,
            duration: _slideDuration,
            curve: Curves.easeInOutCubic,
          ).timeout(_slideGuard, onTimeout: () {});
        }
      }
    } catch (e, st) {
      debugPrint('Footer page navigation failed: $e\n$st');
    } finally {
      _unlockNav(lock);
    }

    if (!mounted) return;
    _footerPageValue.value = (page + 1).toDouble();
    _schedulePrefetch(target);
    unawaited(_ensureSpreadPanels(layout[target]));
    final Size? viewport = _lastViewportSize;
    final List<ComicPanel> panels = _panelsOf(page);
    if (viewport != null && panels.isNotEmpty) {
      _focusOnPanel(panels[0], viewport);
    }
  }

  // Moves to another spread.
  //  atEnd == false -> arrive at the start (beforeFirst view or first panel)
  //  atEnd == true  -> arrive at the end (afterLast view or LAST panel; in a
  //                    double spread that is the last panel of the RIGHT page)
  //
  // The slide starts IMMEDIATELY from whatever is cached (plus the full-page
  // fallback). Detection of the new spread runs in the background; its result
  // arrives through setState and _finishArrival / _onPanelsArrived.
  Future<void> _goToSpread(
    int target, {
    required bool atEnd,
    required Size vp,
  }) async {
    if (_navBusy || _suspendCurlForLayoutSwitch) return;
    final layout = _getEffectiveLayout();
    if (target < 0 || target >= layout.length) return;

    final List<int> pages = layout[target];
    _pendingArrivalSpread = -1;

    // Everything that continues after an await belongs to this layout; a
    // layout switch in between must not be answered with indices of the old one.
    final int epoch = _layoutEpoch;
    final bool wasZoomed =
        !_transformationController.value.isIdentity() ||
        _animationController.isAnimating;

    int page = pages.first;
    int panelIdx = 0;
    FullPagePosition position = FullPagePosition.none;
    final bool panelsKnown = _allDetected(pages);

    final int lock = _lockNav();
    try {
      if (atEnd) {
        if (_wantsAfter) {
          position = FullPagePosition.afterLast;
          page = pages.last;
          final panels = _panelsOf(page);
          panelIdx = panels.isEmpty ? 0 : panels.length - 1;
        } else {
          position = FullPagePosition.none;
          final seq = _cachedSequence(pages);
          if (seq.isEmpty) {
            page = pages.last;
            panelIdx = 0;
          } else {
            page = seq.last.page;
            panelIdx = seq.last.index;
          }
        }
      } else {
        position = _wantsBefore
            ? FullPagePosition.beforeFirst
            : FullPagePosition.none;
        page = pages.first;
        panelIdx = 0;
      }

      _resetZoomInstant();
      setState(() {
        _currentPage = page;
        _currentPanelIndex = panelIdx;
        _fullPagePosition = position;
      });

      if (_pageController.hasClients) {
        // The curl peels a snapshot of the page the turn starts from. The zoom
        // was just reset to identity (and the panel dimming may have moved on),
        // so refresh the snapshot first instead of curling a stale picture.
        if (wasZoomed || _curlSnapshotDirty) {
          await _refreshCurlSnapshotForTurn(epoch);
          if (!mounted || epoch != _layoutEpoch) return;
        }
        await _pageController
            .animateToPage(
              target,
              duration: _slideDuration,
              curve: Curves.easeInOutCubic,
            )
            .timeout(_slideGuard, onTimeout: () {});
      }
      if (!mounted || epoch != _layoutEpoch) return;

      if (position == FullPagePosition.none) {
        final panels = _panelsOf(page);
        if (panelIdx < panels.length) {
          // Gated: parked until the pager is settled if the slide guard fired
          // while the curl was still finishing.
          _focusOnPanel(panels[panelIdx], _lastViewportSize ?? vp);
        }
      }
      // beforeFirst / afterLast: the view is already at identity (full page)
    } finally {
      _unlockNav(lock);
    }

    if (!mounted || epoch != _layoutEpoch) return;
    _schedulePrefetch(target);

    if (!panelsKnown) {
      _pendingArrivalSpread = target;
      // Both halves are queued together (equal priority in the service) ...
      unawaited(_ensureSpreadPanels(pages));
      // ... and the arrival is corrected as soon as the page that decides it
      // (first page going forward, last page going back) is detected.
      unawaited(
        _finishArrival(
          target: target,
          atEnd: atEnd,
          page: page,
          panelIdx: panelIdx,
          position: position,
          vp: vp,
          epoch: epoch,
        ),
      );
    }
  }

  // Corrects an arrival that used the full-page fallback: waits in the
  // background for the page that decides where the reader should be, then - only
  // if the reader is still exactly where the arrival left them - fixes the
  // panel index and zooms onto the real panel.
  Future<void> _finishArrival({
    required int target,
    required bool atEnd,
    required int page,
    required int panelIdx,
    required FullPagePosition position,
    required Size vp,
    required int epoch,
  }) async {
    try {
      if (epoch != _layoutEpoch) return;
      final layout = _getEffectiveLayout();
      if (target < 0 || target >= layout.length) return;
      final List<int> pages = layout[target];

      await _waitForPanels(<int>[
        atEnd ? pages.last : pages.first,
      ], _panelBackgroundCeiling);
      // This wait can be long. If the layout was switched meanwhile, `target`
      // is an index of the other layout: leave the new state alone.
      if (!mounted || epoch != _layoutEpoch) return;

      // The user moved on (tap, swipe, view toggle): leave their state alone.
      if (_findVirtualPageIndex(_currentPage) != target ||
          _currentPage != page ||
          _currentPanelIndex != panelIdx ||
          _fullPagePosition != position) {
        return;
      }

      int newPage = page;
      int newIdx = panelIdx;
      if (atEnd) {
        if (position == FullPagePosition.afterLast) {
          final panels = _panelsOf(page);
          newIdx = panels.isEmpty ? 0 : panels.length - 1;
        } else {
          final seq = _cachedSequence(pages);
          if (seq.isNotEmpty) {
            newPage = seq.last.page;
            newIdx = seq.last.index;
          }
        }
      }

      if (newPage != page || newIdx != panelIdx) {
        setState(() {
          _currentPage = newPage;
          _currentPanelIndex = newIdx;
        });
      }

      if (position == FullPagePosition.none) {
        final panels = _detectedPanelsCache[newPage];
        if (panels != null && newIdx < panels.length) {
          _focusOnPanel(panels[newIdx], _lastViewportSize ?? vp);
        }
      }
    } finally {
      if (_pendingArrivalSpread == target) _pendingArrivalSpread = -1;
    }
  }

  // Gesture handlers below are synchronous and read ONLY the cache (plus the
  // full-page fallback). They never await detection.
  void _nextPanel(Size vp) {
    if (_navBusy || _suspendCurlForLayoutSwitch) return;
    final layout = _getEffectiveLayout();
    if (layout.isEmpty) return;

    final v = _findVirtualPageIndex(_currentPage);
    final seq = _cachedSequence(layout[v]);

    if (_fullPagePosition == FullPagePosition.beforeFirst) {
      // Leave the full-page view and enter the first panel
      if (seq.isNotEmpty) {
        _showPanel(seq.first, vp);
        return;
      }
    } else if (_fullPagePosition == FullPagePosition.afterLast) {
      // Leave the full-page view and go on to the next spread
      unawaited(_goToSpread(v + 1, atEnd: false, vp: vp));
      return;
    } else {
      final pos = _currentSeqPos(seq);
      if (seq.isNotEmpty && pos < seq.length - 1) {
        _showPanel(seq[pos + 1], vp);
        return;
      }
      // At the last panel of the spread
      if (_wantsAfter) {
        setState(() {
          _fullPagePosition = FullPagePosition.afterLast;
        });
        _animateToFullPage();
        return;
      }
    }

    unawaited(_goToSpread(v + 1, atEnd: false, vp: vp));
  }

  void _prevPanel(Size vp) {
    if (_navBusy || _suspendCurlForLayoutSwitch) return;
    final layout = _getEffectiveLayout();
    if (layout.isEmpty) return;

    final v = _findVirtualPageIndex(_currentPage);
    final pages = layout[v];
    final seq = _cachedSequence(pages);

    if (_fullPagePosition == FullPagePosition.afterLast) {
      // Leave the full-page view and return to the last panel
      if (seq.isNotEmpty) {
        _showPanel(seq.last, vp);
        return;
      }
    } else if (_fullPagePosition == FullPagePosition.beforeFirst) {
      // fall through: go to the previous spread
    } else {
      final pos = _currentSeqPos(seq);
      if (pos > 0) {
        _showPanel(seq[pos - 1], vp);
        return;
      }
      // At the first panel of the spread
      if (_wantsBefore) {
        setState(() {
          _currentPage = pages.first;
          _currentPanelIndex = 0;
          _fullPagePosition = FullPagePosition.beforeFirst;
        });
        _animateToFullPage();
        return;
      }
    }

    unawaited(_goToSpread(v - 1, atEnd: true, vp: vp));
  }

  // Called only for real user swipes on the PageView. Synchronous: the page is
  // on screen at once; panels that are not detected yet pop in later through
  // _onPanelsArrived.
  //
  // PageView reports the new page when the turn is HALF done, so the pager is
  // still moving here. The zoom reset and the panel zoom below are therefore
  // parked by _resetZoomInstant / _focusOnPanel and applied by
  // _onPagerSettled; the curl keeps peeling an unchanged page until then.
  void _arriveBySwipe(int virtualIndex) {
    final layout = _getEffectiveLayout();
    if (virtualIndex < 0 || virtualIndex >= layout.length) return;
    final pages = layout[virtualIndex];

    _pendingArrivalSpread = -1;
    _resetZoomInstant();
    setState(() {
      _currentPage = pages.first;
      _currentPanelIndex = 0;
      _fullPagePosition = _wantsBefore
          ? FullPagePosition.beforeFirst
          : FullPagePosition.none;
    });

    _schedulePrefetch(virtualIndex);

    // Already detected (e.g. prefetched): zoom immediately.
    final Size? vp = _lastViewportSize;
    final cached = _detectedPanelsCache[pages.first];
    if (_fullPagePosition == FullPagePosition.none &&
        vp != null &&
        cached != null &&
        cached.isNotEmpty) {
      _focusOnPanel(cached.first, vp);
    }

    // Queue both halves together; results arrive via setState.
    unawaited(_ensureSpreadPanels(pages));
  }

  Future<void> _toggleSpreadView() async {
    if (_navBusy || _suspendCurlForLayoutSwitch || !_layoutReady) return;
    // Nothing to switch to until the spread layout exists.
    if (!_isDoublePageView && _doubleLayout.isEmpty) return;

    _pendingArrivalSpread = -1;
    final int physicalPageToKeep = _currentPage;
    final int lock = _lockNav();
    try {
      // The layout switch outranks every pending zoom request: stop the zoom
      // animation, reset the controller even if a drag is still settling (the
      // jump below cancels it), and forget everything keyed to the old layout.
      _resetZoomInstant(force: true);
      _deferredZoom = null;
      _zoomResetPending = false;
      setState(() {
        // PageView indices are layout-relative. Freeze both curl painting and
        // user scrolling until the same physical page has a valid new index.
        _suspendCurlForLayoutSwitch = true;
        // Invalidates every async continuation that captured the old layout.
        _layoutEpoch++;
        _curlZoomedVirtual = null;
        // Null = "follow the current page" until the pager is settled again.
        _zoomOwnerVirtual = null;
        _isDoublePageView = !_isDoublePageView;
        _currentPanelIndex = 0;
        _fullPagePosition = FullPagePosition.beforeFirst;
      });

      // Do not continue after an arbitrary short timeout: doing so can expose
      // the new layout while PageController still points at the old index.
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;

      final List<List<int>> newLayout = _getEffectiveLayout();
      if (newLayout.isNotEmpty) {
        final int targetVirtual = _findVirtualPageIndex(physicalPageToKeep)
            .clamp(0, newLayout.length - 1)
            .toInt();
        bool positioned = false;

        // A PageView can need an extra frame to apply new itemCount/metrics.
        // Retry only frame/position synchronization; never animate through an
        // obsolete virtual index.
        for (int attempt = 0; attempt < 3 && mounted; attempt++) {
          if (!_pageController.hasClients) {
            await WidgetsBinding.instance.endOfFrame;
            continue;
          }

          final ScrollPosition position = _pageController.position;
          if (!position.hasViewportDimension || !position.hasContentDimensions) {
            await WidgetsBinding.instance.endOfFrame;
            continue;
          }

          _pageController.jumpToPage(targetVirtual);
          await WidgetsBinding.instance.endOfFrame;
          if (!mounted || !_pageController.hasClients) break;

          final double? actualPage = _safePagerPage();
          if (actualPage != null &&
              (actualPage - targetVirtual).abs() < 0.001) {
            positioned = true;
            break;
          }
        }

        if (!positioned && _pageController.hasClients) {
          // Last-resort PageController path: jumpToPage also records the
          // requested page when viewport dimensions are not ready yet.
          _pageController.jumpToPage(targetVirtual);
          await WidgetsBinding.instance.endOfFrame;
          final double? actualPage = _safePagerPage();
          positioned = actualPage != null &&
              (actualPage - targetVirtual).abs() < 0.001;
        }

        if (!positioned) {
          debugPrint(
            'Spread toggle: PageController could not confirm index '
            '$targetVirtual after frame synchronization.',
          );
        }
      }

      if (mounted && _currentPage != physicalPageToKeep) {
        setState(() {
          _currentPage = physicalPageToKeep;
          _currentPanelIndex = 0;
        });
      }
    } catch (e, st) {
      debugPrint('Spread toggle failed: $e\n$st');
    } finally {
      if (mounted && _suspendCurlForLayoutSwitch) {
        // The curl widget resets its anchor and invalidates the old layout's
        // snapshots on this false -> true transition.
        setState(() => _suspendCurlForLayoutSwitch = false);
      }
      _unlockNav(lock);
    }
    if (!mounted) return;

    // The layout is live again: let the curl see the (identity) zoom state of
    // the new layout, hand the controller to the right page, and replay
    // nothing from the old layout (the epoch bump already dropped it).
    _onPagerSettled();

    final List<List<int>> layout = _getEffectiveLayout();
    if (layout.isEmpty) return;
    final int v = _findVirtualPageIndex(_currentPage)
        .clamp(0, layout.length - 1)
        .toInt();
    _schedulePrefetch(v);
    unawaited(_ensureSpreadPanels(layout[v]));
  }

  // 3-zone tap handler (left 30%: prev, right 30%: next, center: toggle UI)
  void _handleScreenTap(TapUpDetails details, Size viewportSize) {
    if (_suspendCurlForLayoutSwitch) return;
    final double screenWidth = viewportSize.width;
    final double tapX = details.localPosition.dx;

    if (tapX < screenWidth * 0.3) {
      _prevPanel(viewportSize);
    } else if (tapX > screenWidth * 0.7) {
      _nextPanel(viewportSize);
    } else {
      setState(() {
        _showUI = !_showUI;

        // Instant system UI toggle for tablet bars
        if (_showUI) {
          // Show system status and navigation bars normally
          SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
        } else {
          // Hide system status and navigation bars completely for true full-screen
          SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
        }
      });
    }
  }

  // Double-tap: zoom into the tapped panel, or return to the full page view
  void _handleDoubleTap(Offset localPos, Size viewportSize) {
    if (_navBusy || _suspendCurlForLayoutSwitch) return;

    if (_fullPagePosition == FullPagePosition.none &&
        _transformationController.value != Matrix4.identity()) {
      setState(() => _fullPagePosition = FullPagePosition.beforeFirst);
      _animateToFullPage();
      return;
    }

    final layout = _getEffectiveLayout();
    if (layout.isEmpty) return;
    final virtualIndex = _findVirtualPageIndex(_currentPage);

    for (final page in layout[virtualIndex]) {
      final Rect? rect = _pageRect(virtualIndex, page, viewportSize);
      if (rect == null || !rect.contains(localPos)) continue;

      final double nx = (localPos.dx - rect.left) / rect.width;
      final double ny = (localPos.dy - rect.top) / rect.height;

      final panels = _detectedPanelsCache[page] ?? const <ComicPanel>[];
      for (int i = 0; i < panels.length; i++) {
        final p = panels[i];
        if (nx >= p.x &&
            nx <= p.x + p.width &&
            ny >= p.y &&
            ny <= p.y + p.height) {
          _showPanel(_PanelRef(page, i), viewportSize);
          return;
        }
      }
      return;
    }
  }

  // ---------------------------------------------------------------------------
  // Page curl
  // ---------------------------------------------------------------------------

  // Paper rect of a spread/page inside the viewport, for the page-curl effect.
  // Read-only: only calls _pageRect / _getEffectiveLayout, never changes state.
  // While a panel is zoomed in, the zoomed content fills the viewport, so the
  // whole viewport is the sheet.
  Rect? _curlPaperRect(int virtualIndex, Size vp) {
    final layout = _getEffectiveLayout();
    if (virtualIndex < 0 || virtualIndex >= layout.length) return null;

    // _curlZoomedVirtual is frozen while a turn is in flight (see
    // _refreshCurlZoomState), so this answer cannot change halfway through a
    // turn when the swipe arrival resets the zoom or moves _currentPage.
    if (virtualIndex == _curlZoomedVirtual) {
      return Offset.zero & vp;
    }

    Rect? paper;
    for (final page in layout[virtualIndex]) {
      final Rect? r = _pageRect(virtualIndex, page, vp);
      if (r == null) continue;
      paper = paper == null ? r : paper.expandToInclude(r);
    }
    return paper;
  }

  // Per-page rects of a two-page spread, so the curl can peel ONE page like a
  // book leaf instead of the whole spread. Read-only: only calls _pageRect and
  // the layout helpers, never changes state.
  // Returns null (-> whole-sheet curl via _curlPaperRect) for single-page mode,
  // wide single-page spreads, and while a panel is zoomed in.
  ComicCurlLeaves? _curlLeaves(int virtualIndex, Size vp) {
    if (!_isDoublePageView) return null;
    if (virtualIndex < 0 || virtualIndex >= _doubleLayout.length) {
      return null;
    }

    // Preserve whole-viewport curling while the active spread is zoomed (frozen
    // while a turn is in flight, see _curlPaperRect).
    if (virtualIndex == _curlZoomedVirtual) {
      return null;
    }

    final List<int?> spread = _doubleLayout[virtualIndex];

    // Wide single-page spread: virtually split the fitted page into
    // two balanced leaves, with the hinge at the page's center.
    if (spread.length == 1) {
      final int? page = spread.single;
      if (page == null) return null;

      final Rect? pageRect = _pageRect(virtualIndex, page, vp);
      if (pageRect == null || pageRect.isEmpty) return null;

      // Align the shared virtual spine to the device-pixel grid. A fractional
      // centre can quantize differently in the two half-leaf meshes and show
      // up as a seam that shakes during wide-page curls.
      final double dpr =
          (MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1.0)
              .clamp(1.0, 4.0)
              .toDouble();
      final double spineInset =
          math.min(1.0 / dpr, pageRect.width / 4.0);
      final double minSpine = pageRect.left + spineInset;
      final double maxSpine = pageRect.right - spineInset;
      final double alignedSpine =
          (pageRect.center.dx * dpr).roundToDouble() / dpr;
      final double spineX = alignedSpine.clamp(minSpine, maxSpine).toDouble();

      final Rect left = Rect.fromLTRB(
        pageRect.left,
        pageRect.top,
        spineX,
        pageRect.bottom,
      );

      final Rect right = Rect.fromLTRB(
        spineX,
        pageRect.top,
        pageRect.right,
        pageRect.bottom,
      );

      if (left.isEmpty || right.isEmpty) return null;

      return ComicCurlLeaves(left: left, right: right);
    }

    // Standard two-page spread: retain the existing per-page geometry.
    if (spread.length != 2) return null;

    final int? a = spread[0];
    final int? b = spread[1];
    if (b == null) return null;

    final Rect? right = _pageRect(virtualIndex, b, vp);
    if (right == null || right.isEmpty) return null;

    // Preserve the blank left-page placeholder behavior.
    final Rect left =
        (a != null ? _pageRect(virtualIndex, a, vp) : null) ??
            Rect.fromLTRB(
              right.left - right.width,
              right.top,
              right.left,
              right.bottom,
            );

    if (left.isEmpty) return null;

    return ComicCurlLeaves(left: left, right: right);
  }

  // ---------------------------------------------------------------------------
  // Reading progress (save / restore)
  // ---------------------------------------------------------------------------

  // Every navigation path (_showPanel, _goToSpread, _arriveBySwipe, ...) changes
  // _currentPage / _currentPanelIndex inside setState, so hooking setState
  // catches all of them without touching any navigation code. The tracker
  // ignores calls where nothing changed and debounces the actual write.
  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    _reportProgress();
    // Same trick for the lazy window: whenever the page changes, move the
    // detection focus and the resident-page window with it.
    _syncFocus();
    // And for the curl: anything that changes how the settled page looks
    // invalidates the raster snapshot the curl peels.
    _syncCurlSignature();
  }

  void _reportProgress() {
    if (!_progressTrackingEnabled) return;
    _progress?.update(_currentPage, _currentPanelIndex);
  }

  // Non-blocking: starts the write and returns. Safe to call repeatedly (the
  // tracker coalesces overlapping flushes and skips them when nothing changed).
  Future<void> _flushProgress() async {
    final ReadingProgressTracker? tracker = _progress;
    if (tracker == null) return;
    try {
      await tracker.flush();
    } catch (e, st) {
      debugPrint('Progress flush failed: $e\n$st');
    }
  }

  // Android may kill a backgrounded app without calling dispose(), so write now.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      unawaited(_progress?.flush());
    }
  }

  // Second half of the restore (the page itself was applied before the first
  // build): validates the panel index and zooms onto the saved panel.
  // Progress tracking is already on (see _bootstrap); a clamped panel index
  // below is reported through setState like any other change.
  Future<void> _finishProgressRestore(ReadingProgress? saved) async {
    try {
      if (saved != null && _pageCount > 0) {
        final int page = _currentPage;
        final List<ComicPanel> panels = await _ensurePanels(page);
        if (!mounted) return;

        // Panel count may differ from when the position was saved
        if (panels.isNotEmpty && _currentPanelIndex >= panels.length) {
          setState(() => _currentPanelIndex = panels.length - 1);
        }

        await WidgetsBinding
            .instance
            .endOfFrame; // viewport is measured by then
        if (!mounted) return;

        final Size? vp = _lastViewportSize;
        if (vp != null &&
            !_navBusy &&
            _currentPage == page &&
            _fullPagePosition == FullPagePosition.none &&
            _currentPanelIndex < panels.length) {
          _focusOnPanel(panels[_currentPanelIndex], vp);
        }
      }
    } catch (e, st) {
      debugPrint('Error restoring reading position: $e\n$st');
    }
    // (Tracking was already switched on in _bootstrap; a clamped panel index
    // above went through setState and is reported like any other change.)
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final effectiveLayout = _getEffectiveLayout();
    final int currentVirtual = effectiveLayout.isEmpty
        ? 0
        : _findVirtualPageIndex(_currentPage);

    // The shared TransformationController belongs to the page the pager is
    // settled on. While a turn is in flight it stays with the page being
    // peeled (the field keeps the last settled owner), so the curl never sees
    // that page's live content lose its zoom halfway through the turn.
    if (!_suspendCurlForLayoutSwitch && _isPagerSettled) {
      _zoomOwnerVirtual = currentVirtual;
    }
    final int zoomOwner = _zoomOwnerVirtual ?? currentVirtual;

    return PopScope(
      canPop: true,
      // Back button, back gesture or AppBar arrow: start saving before the
      // route animates away.
      onPopInvokedWithResult: (bool didPop, Object? result) {
        unawaited(_flushProgress());
      },
      child: Scaffold(
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
                      onTapUp: (details) =>
                          _handleScreenTap(details, constraints.biggest),
                      onDoubleTapDown: (details) => _handleDoubleTap(
                        details.localPosition,
                        constraints.biggest,
                      ),
                      child: Listener(
                        behavior: HitTestBehavior.translucent,
                        onPointerDown: (PointerDownEvent event) =>
                            _pointerDownAt = event.position,
                        onPointerMove: _onReaderPointerMove,
                        onPointerUp: (PointerUpEvent event) =>
                            _pointerDownAt = null,
                        onPointerCancel: (PointerCancelEvent event) =>
                            _pointerDownAt = null,
                        child: ComicCurlPageView.builder(
                        controller: _pageController,
                        snapshotController: _curlSnapshot,
                        snapshotInvalidator: _curlSnapshotTick,
                        enabled: !_suspendCurlForLayoutSwitch,
                        // Drags that start while a programmatic transition is running are swallowed
                        isInteractionBlocked: () =>
                            _navBusy || _suspendCurlForLayoutSwitch,
                        paperRectBuilder: _curlPaperRect,
                        leavesBuilder: _curlLeaves,
                        // A layout-relative index must not change while the
                        // controller is being remapped to the new layout.
                        physics: (_isScreenLocked || _suspendCurlForLayoutSwitch)
                            ? const NeverScrollableScrollPhysics()
                            : const BouncingScrollPhysics(),
                        // In spread mode, never show the single-page mirrored
                        // ghost if a transient geometry lookup misses a leaf.
                        // A plain paper fallback is preferable to the wrong art.
                        ghostBackFace: !_isDoublePageView,
                        backFaceBuilder: (context, virtualIndex) {
                          if (virtualIndex < 0 ||
                              virtualIndex >= effectiveLayout.length) {
                            return const SizedBox.shrink();
                          }
                          // This is a static duplicate of the adjacent spread:
                          // it must not attach the reader's shared zoom
                          // TransformationController to a second viewer.
                          return Center(
                            child: Center(
                              child: _buildVirtualPageContent(
                                virtualIndex,
                                forCurlBackFace: true,
                              ),
                            ),
                          );
                        },
                        itemCount: effectiveLayout.length,
                        onPageTurnStarted: _onCurlPageTurnStarted,
                        onPageChanged: (virtualIndex) {
                          // Programmatic navigation and layout remapping already
                          // own the reader state; ignore transient indices.
                          if (_navBusy || _suspendCurlForLayoutSwitch) return;
                          if (_findVirtualPageIndex(_currentPage) ==
                              virtualIndex)
                            return;
                          _arriveBySwipe(virtualIndex);
                        },
                        itemBuilder: (context, virtualIndex) {
                          // Only the interactive foreground page owns the shared
                          // controller. The backFaceBuilder above renders a
                          // separate static copy without an InteractiveViewer.
                          final TransformationController? controller =
                              virtualIndex == zoomOwner
                                  ? _transformationController
                                  : null;
                          final Key key = ValueKey(
                            '${_isDoublePageView ? 'd' : 's'}$virtualIndex',
                          );
                          return Center(
                            child: InteractiveViewer(
                              key: key,
                              transformationController: controller,
                              minScale: 1.0,
                              maxScale: 5.0,
                              child: Center(
                                child: _buildVirtualPageContent(virtualIndex),
                              ),
                            ),
                          );
                        },
                      ),
                      ),
                    ),
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: IgnorePointer(
                        ignoring: !_showUI,
                        child: AnimatedSlide(
                          offset: _showUI ? Offset.zero : const Offset(0, -1),
                          duration: const Duration(milliseconds: 220),
                          curve: Curves.easeInOut,
                          child: AnimatedOpacity(
                            opacity: _showUI ? 1.0 : 0.0,
                            duration: const Duration(milliseconds: 200),
                            child: AppBar(
                            backgroundColor: Colors.black.withValues(
                              alpha: 0.8,
                            ),
                            title: Text(
                              'PanelShift Reader (${_currentPage + 1}/$_pageCount)',
                              style: const TextStyle(color: Colors.white),
                            ),
                            iconTheme: const IconThemeData(color: Colors.white),

                            actions: [
                              IconButton(
                                icon: Icon(
                                  _isScreenLocked
                                      ? Icons.lock
                                      : Icons.lock_open,
                                ),
                                tooltip: _isScreenLocked
                                    ? 'Screen Locked'
                                    : 'Screen Unlocked',
                                onPressed: () {
                                  setState(() {
                                    _isScreenLocked = !_isScreenLocked;
                                  });
                                },
                              ),
                              IconButton(
                                icon: Icon(
                                  _pageSoundEnabled
                                      ? Icons.volume_up
                                      : Icons.volume_off,
                                ),
                                tooltip: 'Page Sound',
                                onPressed: _showPageSoundDialog,
                              ),
                              IconButton(
                                icon: const Icon(Icons.brightness_6),
                                tooltip: 'Adjust Dimming Level',
                                onPressed: _showDimmingDialog,
                              ),
                              IconButton(
                                icon: Icon(
                                  _fullPageStepMode == FullPageStepMode.none
                                      ? Icons.fullscreen_exit
                                      : _fullPageStepMode ==
                                            FullPageStepMode.afterLast
                                      ? Icons.vertical_align_bottom
                                      : _fullPageStepMode ==
                                            FullPageStepMode.beforeFirst
                                      ? Icons.vertical_align_top
                                      : Icons.unfold_more,
                                ),
                                tooltip:
                                    'Full-Page Step: ${_fullPageStepMode.name}',
                                onPressed: () {
                                  setState(() {
                                    switch (_fullPageStepMode) {
                                      case FullPageStepMode.none:
                                        _fullPageStepMode =
                                            FullPageStepMode.afterLast;
                                        break;
                                      case FullPageStepMode.afterLast:
                                        _fullPageStepMode =
                                            FullPageStepMode.beforeFirst;
                                        break;
                                      case FullPageStepMode.beforeFirst:
                                        _fullPageStepMode =
                                            FullPageStepMode.both;
                                        break;
                                      case FullPageStepMode.both:
                                        _fullPageStepMode =
                                            FullPageStepMode.none;
                                        break;
                                    }
                                  });
                                },
                              ),
                              IconButton(
                                icon: Icon(
                                  _isDoublePageView
                                      ? Icons.menu_book
                                      : Icons.chrome_reader_mode,
                                ),
                                tooltip: _layoutReady
                                    ? 'Toggle Spread View'
                                    : 'Preparing spread layout',
                                // Spreads need every page's size, which is measured in
                                // the background right after the first frame.
                                onPressed: _layoutReady
                                    ? _toggleSpreadView
                                    : null,
                              ),
                              IconButton(
                                icon: Icon(
                                  _showPanelOutlines
                                      ? Icons.border_outer
                                      : Icons.border_clear,
                                ),
                                tooltip: 'Toggle Panel Outlines & Numbers',
                                onPressed: () {
                                  setState(() {
                                    _showPanelOutlines = !_showPanelOutlines;
                                  });
                                },
                              ),
                              IconButton(
                                icon: Icon(
                                  _showPanelOverlays
                                      ? Icons.layers
                                      : Icons.layers_outlined,
                                ),
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
                      ),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: IgnorePointer(
                        ignoring: !_showUI,
                        child: AnimatedSlide(
                          offset: _showUI ? Offset.zero : const Offset(0, 1),
                          duration: const Duration(milliseconds: 220),
                          curve: Curves.easeInOut,
                          child: AnimatedOpacity(
                            opacity: _showUI ? 1.0 : 0.0,
                            duration: const Duration(milliseconds: 200),
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              // Absorb taps/drags at the overlay boundary; the
                              // slider below owns its horizontal drag gesture.
                              onTap: () {},
                              child: SafeArea(
                                top: false,
                                child: Container(
                                  padding: const EdgeInsets.fromLTRB(18, 10, 18, 8),
                                  decoration: BoxDecoration(
                                    color: Colors.black.withValues(alpha: 0.82),
                                    border: Border(
                                      top: BorderSide(
                                        color: Colors.white.withValues(alpha: 0.12),
                                      ),
                                    ),
                                  ),
                                  child: ValueListenableBuilder<double>(
                                    valueListenable: _footerPageValue,
                                    builder: (context, scrubValue, _) {
                                      final double displayedPage = _isFooterScrubbing
                                          ? scrubValue
                                          : (_currentPage + 1).toDouble();
                                      final int pageCount = math.max(1, _pageCount).toInt();
                                      final double sliderValue = displayedPage
                                          .clamp(1.0, pageCount.toDouble());
                                      return Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Row(
                                            children: [
                                              const Icon(Icons.menu_book, color: Colors.white70, size: 17),
                                              const SizedBox(width: 8),
                                              Text(
                                                'Page ${sliderValue.round()} of $_pageCount',
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 13,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                              const Spacer(),
                                              Text(
                                                _isDoublePageView ? 'Double page' : 'Single page',
                                                style: TextStyle(
                                                  color: Colors.white.withValues(alpha: 0.55),
                                                  fontSize: 11,
                                                ),
                                              ),
                                            ],
                                          ),
                                          SliderTheme(
                                            data: SliderTheme.of(context).copyWith(
                                              trackHeight: 3,
                                              activeTrackColor: Colors.white,
                                              inactiveTrackColor: Colors.white24,
                                              thumbColor: Colors.white,
                                              overlayColor: Colors.white.withValues(alpha: 0.12),
                                              valueIndicatorColor: Colors.black87,
                                              valueIndicatorTextStyle: const TextStyle(color: Colors.white),
                                            ),
                                            child: Slider(
                                              min: 1,
                                              max: math.max(1, _pageCount).toDouble(),
                                              divisions: _pageCount > 1 ? _pageCount - 1 : null,
                                              value: sliderValue,
                                              label: 'Page ${sliderValue.round()}',
                                              onChangeStart: _pageCount <= 1 ? null : (value) {
                                                _isFooterScrubbing = true;
                                                _footerPageValue.value = value;
                                              },
                                              onChanged: _pageCount <= 1 ? null : (value) {
                                                _footerPageValue.value = value;
                                              },
                                              onChangeEnd: _pageCount <= 1 ? null : (value) {
                                                _isFooterScrubbing = false;
                                                _footerPageValue.value = value;
                                                unawaited(_jumpToPhysicalPage(value.round() - 1));
                                              },
                                            ),
                                          ),
                                        ],
                                      );
                                    },
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
      ),
    );
  }

  // Content for a layout-relative PageView item. The regular item is wrapped
  // in an InteractiveViewer by the caller; a curl back face uses this same
  // content without a second viewer or the active-page panel dimming overlay.
  Widget _buildVirtualPageContent(
    int virtualIndex, {
    bool forCurlBackFace = false,
  }) {
    if (_isDoublePageView) {
      if (virtualIndex < 0 || virtualIndex >= _doubleLayout.length) {
        return const SizedBox.shrink();
      }
      final List<int?> spread = _doubleLayout[virtualIndex];
      return spread.length == 1
          ? _buildSinglePageWidget(
              spread[0]!,
              forCurlBackFace: forCurlBackFace,
            )
          : _buildDoublePageWidget(
              spread[0],
              spread[1],
              forCurlBackFace: forCurlBackFace,
            );
    }

    if (virtualIndex < 0 || virtualIndex >= _singleLayout.length) {
      return const SizedBox.shrink();
    }
    return _buildSinglePageWidget(
      _singleLayout[virtualIndex][0],
      forCurlBackFace: forCurlBackFace,
    );
  }

  // Renders a single comic page with optional panel outlines and dimming overlays
  Widget _buildSinglePageWidget(
    int pageIndex, {
    bool forCurlBackFace = false,
  }) {
    final panels = _detectedPanelsCache[pageIndex] ?? [];
    final imgSize = _imageSizesCache[pageIndex];
    final Uint8List? bytes = _pageBytes[pageIndex];
    // Outside the resident window (or still being read): nothing to draw yet.
    // The load is (re)started and setState redraws this page when it lands.
    if (bytes == null) {
      _requestPageBytes(pageIndex);
      return const SizedBox.shrink();
    }

    return imgSize == null
        ? Image.memory(bytes, fit: BoxFit.contain)
        : AspectRatio(
            aspectRatio: imgSize.width / imgSize.height,
            child: Stack(
              fit: StackFit.passthrough,
              children: [
                Image.memory(bytes, fit: BoxFit.contain, gaplessPlayback: true),
                if (!forCurlBackFace && _showPanelOutlines)
                  CustomPaint(
                    painter: ComicPanelPainter(
                      panels: panels,
                      activeIndex:
                          (_currentPage == pageIndex &&
                              _fullPagePosition == FullPagePosition.none)
                          ? _currentPanelIndex
                          : -1,
                      showOutlines: true,
                      showDimming: false,
                      dimmingOpacity: _dimmingLevel,
                    ),
                  ),
                if (!forCurlBackFace &&
                    _showPanelOverlays &&
                    _fullPagePosition == FullPagePosition.none)
                  CustomPaint(
                    painter: ComicPanelPainter(
                      panels: (_currentPage == pageIndex) ? panels : [],
                      activeIndex: (_currentPage == pageIndex)
                          ? _currentPanelIndex
                          : -99,
                      showOutlines: false,
                      showDimming: true,
                      dimmingOpacity: _dimmingLevel,
                    ),
                  ),
              ],
            ),
          );
  }

  // Renders a double-page spread with right-aligned placeholder sizing and spread dimming
  Widget _buildDoublePageWidget(
    int? pageA,
    int? pageB, {
    bool forCurlBackFace = false,
  }) {
    final sizeA = pageA != null ? _imageSizesCache[pageA] : null;
    final sizeB = pageB != null ? _imageSizesCache[pageB] : null;

    return LayoutBuilder(
      builder: (context, constraints) {
        final double maxHeight = constraints.maxHeight;
        final double maxWidth = constraints.maxWidth;

        final double wB = sizeB != null
            ? maxHeight * (sizeB.width / sizeB.height)
            : maxWidth / 2;
        final double wA = sizeA != null
            ? maxHeight * (sizeA.width / sizeA.height)
            : wB;

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
                    ? _buildSpreadHalf(pageA, forCurlBackFace: forCurlBackFace)
                    : Container(color: Colors.black),
              ),
              SizedBox(
                width: wB * scale,
                height: maxHeight * scale,
                child: pageB != null
                    ? _buildSpreadHalf(pageB, forCurlBackFace: forCurlBackFace)
                    : Container(color: Colors.black),
              ),
            ],
          ),
        );
      },
    );
  }

  // One half (page) of a double spread
  Widget _buildSpreadHalf(int page, {bool forCurlBackFace = false}) {
    final panels = _detectedPanelsCache[page] ?? [];
    final Uint8List? bytes = _pageBytes[page];
    // Bytes not here yet (this half is slower than its neighbour): start/join
    // the load. _loadPage calls setState as soon as they arrive, which rebuilds
    // this widget with the Image.memory below.
    if (bytes == null) _requestPageBytes(page);
    return Stack(
      fit: StackFit.expand,
      children: [
        if (bytes != null)
          Image.memory(bytes, fit: BoxFit.fill, gaplessPlayback: true)
        else
          const Center(
            child: SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        if (!forCurlBackFace && _showPanelOutlines)
          CustomPaint(
            painter: ComicPanelPainter(
              panels: panels,
              activeIndex:
                  (_currentPage == page &&
                      _fullPagePosition == FullPagePosition.none)
                  ? _currentPanelIndex
                  : -1,
              showOutlines: true,
              showDimming: false,
              dimmingOpacity: _dimmingLevel,
            ),
          ),
        if (!forCurlBackFace &&
            _showPanelOverlays &&
            _fullPagePosition == FullPagePosition.none)
          CustomPaint(
            painter: ComicPanelPainter(
              panels: (_currentPage == page) ? panels : [],
              activeIndex: (_currentPage == page) ? _currentPanelIndex : -99,
              showOutlines: false,
              showDimming: true,
              dimmingOpacity: _dimmingLevel,
            ),
          ),
        if (!forCurlBackFace &&
            _showPanelOverlays &&
            _fullPagePosition == FullPagePosition.none &&
            _currentPage != page)
          Container(color: Colors.black.withValues(alpha: 0.65)),
      ],
    );
  }
}
