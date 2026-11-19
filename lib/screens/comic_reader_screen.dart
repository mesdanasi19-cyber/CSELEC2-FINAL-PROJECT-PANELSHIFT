import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'dart:typed_data';
import 'dart:ui' as ui;

import '../services/comic_cache_service.dart';
import '../services/comic_identity.dart';
import '../services/comic_page_source.dart';
import '../services/comic_parser_service.dart' show PageDimensionProbe;
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

// How pages change: the custom page curl, or a plain horizontal PageView slide
enum PageTransitionMode { curl, swipe }

/// Page-snapping physics for the reader's pager (curl and swipe).
///
/// Identical to the framework's [PageScrollPhysics] except for a stiffer settle
/// spring. The framework default (mass 0.5, stiffness 100, damping ratio 1.1)
/// takes roughly 0.3 s to finish a released page; stiffness 150 at ratio 1.05
/// settles in roughly 20% less time while staying (near-)critically damped, so
/// it never overshoots a page boundary. A released swipe feels a beat more
/// immediate, and the curl - the most expensive thing the app draws - is on
/// screen for that much fewer frames. Fling thresholds are left at the platform
/// defaults, where any deliberate flick already turns the page.
class _ReaderPagerPhysics extends PageScrollPhysics {
  const _ReaderPagerPhysics({super.parent});

  static final SpringDescription _spring = SpringDescription.withDampingRatio(
    mass: 0.5,
    stiffness: 150.0,
    ratio: 1.05,
  );

  @override
  _ReaderPagerPhysics applyTo(ScrollPhysics? ancestor) =>
      _ReaderPagerPhysics(parent: buildParent(ancestor));

  @override
  SpringDescription get spring => _spring;
}

/// The bitmap provider currently handed out for one page, remembered with the
/// inputs it was built from (see _ComicReaderScreenState._pageImageProvider).
class _PageProvider {
  const _PageProvider(this.bytes, this.size, this.provider);

  final Uint8List bytes;
  final Size? size;
  final ImageProvider provider;
}

// Header title: strips the folder and any trailing archive/document extension
// (Batman_01.cbz -> Batman_01). Only known comic/archive types are removed, so
// titles like "Batman v1.5" keep their dot.
final RegExp _comicExtension = RegExp(
  r'\.(cbz|cbr|cb7|cbt|cba|zip|rar|7z|tar|pdf|epub)$',
  caseSensitive: false,
);

String _comicDisplayTitle(String? raw) {
  if (raw == null) return '';
  String name = raw.trim();
  final int slash = math.max(name.lastIndexOf('/'), name.lastIndexOf('\\'));
  if (slash >= 0) name = name.substring(slash + 1);
  String previous;
  do {
    previous = name;
    name = name.replaceFirst(_comicExtension, '');
  } while (name != previous);
  return name.trim();
}

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
//
// [manga] mirrors the pairing so the earlier page is on the RIGHT
// (index 0 = left half, index 1 = right half):
//   LTR  cover/end page: [null, i]   pair: [i, i + 1]
//   RTL  cover/end page: [i, null]   pair: [i + 1, i]
// The grouping is identical in both modes, so the spread COUNT and the virtual
// index of every physical page never change when the direction flips.
List<List<int?>> _computeDoubleLayout(List<bool> wide, {bool manga = false}) {
  final int count = wide.length;
  final List<List<int?>> layout = <List<int?>>[];
  int i = 0;

  // A single (non-wide) page next to a blank half.
  List<int?> alone(int page) =>
      manga ? <int?>[page, null] : <int?>[null, page];

  while (i < count) {
    final bool isWide = wide[i];
    final bool isCover = (i == 0);

    if (isCover || isWide || i == count - 1) {
      if (isWide) {
        layout.add(<int?>[i]);
      } else {
        layout.add(alone(i));
      }
      i++;
    } else {
      if (i + 1 < count) {
        if (wide[i + 1]) {
          layout.add(alone(i));
          i++;
        } else {
          layout.add(manga ? <int?>[i + 1, i] : <int?>[i, i + 1]);
          i += 2;
        }
      } else {
        layout.add(alone(i));
        i++;
      }
    }
  }
  return layout;
}

// Short books are laid out inline (a few microseconds). Long ones are computed
// on a background isolate so the UI thread never stalls. The result crosses the
// isolate boundary as a flat int list ([first, second] per spread; -1 = blank
// half in EITHER slot, -2 in the second slot = single-page spread) so its
// element types are always exact.
Future<List<List<int?>>> _computeDoubleLayoutOffThread(
  List<bool> wide, {
  bool manga = false,
}) async {
  if (wide.length < 200) return _computeDoubleLayout(wide, manga: manga);
  try {
    final List<int> flat = await Isolate.run<List<int>>(() {
      final List<int> out = <int>[];
      for (final List<int?> spread in _computeDoubleLayout(wide, manga: manga)) {
        if (spread.length == 1) {
          out
            ..add(spread[0]!)
            ..add(-2);
        } else {
          out
            ..add(spread[0] ?? -1)
            ..add(spread[1] ?? -1);
        }
      }
      return out;
    });
    final List<List<int?>> layout = <List<int?>>[];
    for (int k = 0; k + 1 < flat.length; k += 2) {
      final int a = flat[k];
      final int b = flat[k + 1];
      layout.add(
        b == -2
            ? <int?>[a]
            : <int?>[a == -1 ? null : a, b == -1 ? null : b],
      );
    }
    return layout;
  } catch (e) {
    debugPrint('Background layout failed, computing inline: $e');
    return _computeDoubleLayout(wide, manga: manga);
  }
}
//v3.0.0
// Pure helper (no widget state, never mutates its input): orders panels the way
// manga is read. X is mirrored (1 - (x + width)) before sorting, so ascending
// mirrored-x == right-to-left. Rows run top-to-bottom; a panel joins the
// current row when it overlaps at least 50% of the smaller of the two heights.

//v.3.0.2
// Mirrors x (1 - (x + width)) and applies the same hybrid row-grouping +
// recursive XY-cut logic as panel_postprocess.h so vertical panel stacks beside
// tall panels are always read top-to-bottom before crossing a vertical gutter.
List<ComicPanel> _orderPanelsRightToLeft(List<ComicPanel> panels) {
  if (panels.length < 2) return panels;

  double mirroredX(ComicPanel p) => 1.0 - (p.x + p.width);
  double mirroredRight(ComicPanel p) => 1.0 - p.x;

  bool sharesRow(ComicPanel a, ComicPanel b) {
    final double minH = math.min(a.height, b.height);
    final double overlap =
        math.min(a.y + a.height, b.y + b.height) - math.max(a.y, b.y);
    return minH > 0.0 && overlap > 0.50 * minH;
  }

  List<List<ComicPanel>> groupRows(List<ComicPanel> items) {
    final List<ComicPanel> sorted = List<ComicPanel>.of(items)
      ..sort((ComicPanel a, ComicPanel b) => a.y.compareTo(b.y));
    final List<bool> used = List<bool>.filled(sorted.length, false);
    final List<List<ComicPanel>> rows = <List<ComicPanel>>[];

    for (int i = 0; i < sorted.length; i++) {
      if (used[i]) continue;
      final ComicPanel seed = sorted[i];
      final List<ComicPanel> row = <ComicPanel>[seed];
      used[i] = true;

      for (int j = i + 1; j < sorted.length; j++) {
        if (!used[j] && sharesRow(seed, sorted[j])) {
          row.add(sorted[j]);
          used[j] = true;
        }
      }

      // Insertion sort within row: right-to-left (mirroredX), then top-to-bottom
      for (int k = 1; k < row.length; k++) {
        final ComicPanel key = row[k];
        int m = k;
        while (m > 0) {
          final ComicPanel prev = row[m - 1];
          final double dx = (mirroredX(key) - mirroredX(prev)).abs();
          final bool before = dx > 0.03
              ? mirroredX(key) < mirroredX(prev)
              : key.y < prev.y;
          if (!before) break;
          row[m] = prev;
          m--;
        }
        row[m] = key;
      }
      rows.add(row);
    }
    return rows;
  }

  bool rowsConsistent(List<List<ComicPanel>> rows) {
    for (int r = 0; r < rows.length; r++) {
      for (int i = 0; i < rows[r].length; i++) {
        for (int j = i + 1; j < rows[r].length; j++) {
          if (!sharesRow(rows[r][i], rows[r][j])) return false;
        }
        for (int s = r + 1; s < rows.length; s++) {
          for (final ComicPanel other in rows[s]) {
            if (sharesRow(rows[r][i], other)) return false;
          }
        }
      }
    }
    return true;
  }

  bool splitAtGap(
    List<ComicPanel> items,
    bool byY,
    List<ComicPanel> first,
    List<ComicPanel> second,
  ) {
    final List<ComicPanel> sorted = List<ComicPanel>.of(items)
      ..sort(
        (ComicPanel a, ComicPanel b) =>
            byY ? a.y.compareTo(b.y) : mirroredX(a).compareTo(mirroredX(b)),
      );
    double reach = byY
        ? (sorted[0].y + sorted[0].height)
        : mirroredRight(sorted[0]);
    for (int k = 1; k < sorted.length; k++) {
      final double start = byY ? sorted[k].y : mirroredX(sorted[k]);
      if (start >= reach - 0.02) {
        first.addAll(sorted.sublist(0, k));
        second.addAll(sorted.sublist(k));
        return true;
      }
      reach = math.max(
        reach,
        byY ? (sorted[k].y + sorted[k].height) : mirroredRight(sorted[k]),
      );
    }
    return false;
  }

  void orderRegion(List<ComicPanel> items, List<ComicPanel> out) {
    if (items.length < 2) {
      out.addAll(items);
      return;
    }
    final List<List<ComicPanel>> rows = groupRows(items);
    if (rowsConsistent(rows)) {
      for (final List<ComicPanel> row in rows) {
        out.addAll(row);
      }
      return;
    }
    final List<ComicPanel> first = <ComicPanel>[];
    final List<ComicPanel> second = <ComicPanel>[];
    if (splitAtGap(items, true, first, second) ||
        splitAtGap(items, false, first, second)) {
      orderRegion(first, out);
      orderRegion(second, out);
      return;
    }
    for (final List<ComicPanel> row in rows) {
      out.addAll(row);
    }
  }

  final List<ComicPanel> ordered = <ComicPanel>[];
  orderRegion(panels, ordered);
  return ordered;
}

// Memo of the right-to-left order of one page, validated by the identity of the
// cached source list (so a re-detection invalidates it automatically).
// _detectedPanelsCache itself is never touched.
class _RtlPanelOrder {
  const _RtlPanelOrder(this.source, this.ordered);

  final List<ComicPanel> source;
  final List<ComicPanel> ordered;
}

class ComicReaderScreen extends StatefulWidget {
  /// Pages are read from here one at a time, only when they are needed.
  final ComicPageSource source;

  /// Identifies the comic for saving/restoring the reading position.
  /// When null, nothing is saved or restored.
  final ComicIdentity? comic;

  /// Name shown in the header. Pass the comic's title or file name; a file
  /// extension such as ".cbz" is removed for display.
  final String? title;

  const ComicReaderScreen({
    super.key,
    required this.source,
    this.comic,
    this.title,
  });

  /// For callers that still hold every page in memory.
  factory ComicReaderScreen.fromBytes({
    Key? key,
    required List<Uint8List> pageBytes,
    ComicIdentity? comic,
    String? title,
  }) => ComicReaderScreen(
    key: key,
    source: InMemoryPageSource(pageBytes),
    comic: comic,
    title: title,
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
  // Not final: switching between the page curl and the plain PageView creates
  // a fresh controller (see _setTransitionMode).
  late PageController _pageController = PageController(
    initialPage: _initialVirtualPage,
  );
  late final TransformationController _transformationController;
  late final AnimationController _animationController;
  // One curve for every zoom animation. A CurvedAnimation registers a status
  // listener on its parent for as long as it lives, so creating a new one per
  // panel tap (as before) grew the controller's listener list for the whole
  // reading session. Only the tween changes between animations.
  late final CurvedAnimation _zoomCurve;
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

  // Page-turn timing. Everything is defined at a base speed of 1.0x and divided
  // by [_pageTurnSpeed], so 1.5x is 1.5 times faster and 0.5x twice as slow.
  // The 1.0x base is deliberately slow and relaxed, like turning a real page.
  static const Duration _baseSlideDuration = Duration(milliseconds: 900);
  // How long the slide is awaited before the code after it may continue. It
  // keeps the 60% proportion of the original 300 ms guard on a 500 ms slide;
  // the animation keeps running past it, and anything that needs a settled
  // pager is parked until then (_focusOnPanel / _resetZoomInstant).
  static const Duration _baseSlideGuard = Duration(milliseconds: 540);
  // Frame / snapshot waits, in milliseconds so the watchdog slack below can be
  // derived from them at compile time. These are SAFETY NETS, not delays: on a
  // healthy device each wait ends after one frame (~16 ms). They only matter
  // when a frame is late - a 60 Hz low-end GPU re-rasterising a big page, a
  // cold shader - and then they decide whether the next step (capturing the
  // curl snapshot, starting the slide) sees the zoom reset that was just
  // applied, or runs against a stale frame. 120 ms is only ~7 frames at 60 Hz,
  // which one slow raster of a full-resolution page can eat on its own.
  static const int _frameGuardMs = 200;
  static const int _snapshotRefreshTimeoutMs = 260;
  static const Duration _frameGuard = Duration(milliseconds: _frameGuardMs);
  static const Duration _snapshotRefreshTimeout = Duration(
    milliseconds: _snapshotRefreshTimeoutMs,
  );
  // Extra time the navigation watchdog allows beyond the slide guard. The worst
  // case before a slide can start is two frame guards (the footer jump waits
  // one frame itself, then _refreshCurlSnapshotForTurn waits another) plus the
  // snapshot wait, plus a margin. Derived, so retuning a guard cannot silently
  // break the invariant "the watchdog outlasts the waits it protects".
  static const Duration _navLockSlack = Duration(
    milliseconds: 2 * _frameGuardMs + _snapshotRefreshTimeoutMs + 140,
  );
  // Gentler than the old easeInOutCubic: slower start and stop.
  static const Curve _pageTurnCurve = Curves.easeInOutSine;

  static const List<double> _pageTurnSpeedOptions = <double>[
    0.5,
    0.75,
    1.0,
    1.5,
    2.0,
  ];
  double _pageTurnSpeed = 1.0;

  Duration _scaledByTurnSpeed(Duration base) => Duration(
    microseconds: (base.inMicroseconds / _pageTurnSpeed).round(),
  );
  Duration get _slideDuration => _scaledByTurnSpeed(_baseSlideDuration);
  Duration get _slideGuard => _scaledByTurnSpeed(_baseSlideGuard);

  // Hard upper bound for _navBusy. Whatever happens inside a transition, the
  // lock is released by a timer after this long. It covers the slide guard
  // plus the short wait for a fresh curl snapshot (_refreshCurlSnapshotForTurn).
  Duration get _navLockMax => _slideGuard + _navLockSlack;
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

  // Manga / right-to-left reading order. Loaded from SharedPreferences in
  // _bootstrap (before the first layout build) so it stays the default across
  // comics and app restarts, and persisted on every toggle.
  static const String _kMangaModePrefKey = 'reader_manga_mode';
  bool _isMangaMode = false;
  // Direction the CURRENT _doubleLayout was built for. _getEffectiveLayout reads
  // this (not _isMangaMode) so a layout and its compaction can never disagree.
  bool _doubleLayoutIsManga = false;
  final Map<int, _RtlPanelOrder> _rtlPanelOrder = <int, _RtlPanelOrder>{};

  // Reading transition: the custom page curl or a plain horizontal slide.
  PageTransitionMode _transitionMode = PageTransitionMode.curl;
  bool get _useCurl => _transitionMode == PageTransitionMode.curl;

  // Bottom control hub: is the secondary row (sound, dimming, ...) open?
  bool _showMoreControls = false;

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
  // Swipe mode only: the curl layer reports turn starts itself, the plain
  // PageView does not, so the page-turn sound follows the pager position.
  int? _lastSettledVirtual;
  bool _swipeTurnSoundFired = false;
  // Virtual index whose live content is zoomed, as the curl layer sees it.
  int? _curlZoomedVirtual;
  // Virtual index that owns the shared TransformationController.
  int? _zoomOwnerVirtual;
  bool _zoomResetPending = false;
  _DeferredZoom? _deferredZoom;
  Offset? _pointerDownAt;
  static const double _zoomFastForwardSlop = 9.0;

  // --- Instant edge taps --------------------------------------------------------
  // GestureDetector reports onTapUp only after its double-tap recogniser has
  // given up (kDoubleTapTimeout, 300 ms). With onDoubleTapDown registered,
  // EVERY tap - including the rapid left/right taps that step through panels -
  // therefore arrives 300 ms late. Edge-zone taps are recognised here instead,
  // on finger-up, straight from the pointer stream: zero added latency. The
  // centre zone keeps GestureDetector's tap / double-tap arbitration, so
  // double-tap-to-zoom (and the single tap that toggles the UI) work as before.
  // Trade-off: a quick double tap inside an edge zone now steps twice instead
  // of zooming. Set to false to restore the original behaviour everywhere.
  static const bool _kInstantEdgeTaps = true;
  static const double _kEdgeZoneLeft = 0.3;
  static const double _kEdgeZoneRight = 0.7;

  // Instant 0 ms edge taps apply only while actively zoomed into a panel.
// In full-page view, edge zones yield to GestureDetector so double-tapping
// any panel near the left/right edges jumps directly into it.
  bool get _useInstantEdgeTaps =>
      _kInstantEdgeTaps &&
          _fullPagePosition == FullPagePosition.none &&
          !_transformationController.value.isIdentity();
  // The platform touch slop (8 dp on Android): beyond it the PageView's drag
  // recogniser has taken the gesture, so it must not also count as a tap.
  static const double _kTapMoveSlop = 8.0;
  // GestureDetector has no upper bound either; this only filters out a finger
  // that was parked on the screen and forgotten.
  static const Duration _kTapMaxDuration = Duration(seconds: 2);
  final Set<int> _downPointers = <int>{};
  int? _tapPointer;
  Offset? _tapDownLocal;
  Duration? _tapDownTime;
  bool _edgeTapHandled = false;

  // Refreshes the curl snapshot once a zoom has settled (see _noteZoomSettled).
  Timer? _zoomSnapshotTimer;

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

  String _formatSpeed(double speed) => '${speed}x';

  void _showTurnSpeedDialog() {
    showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('Page-Turn Speed'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final double option in _pageTurnSpeedOptions)
                    ChoiceChip(
                      label: Text(_formatSpeed(option)),
                      selected: option == _pageTurnSpeed,
                      onSelected: (_) {
                        setState(() => _pageTurnSpeed = option);
                        Navigator.of(dialogContext).pop();
                      },
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                '1.0x is a relaxed, book-like turn. Higher is faster, lower '
                'is slower. Applies to tap-zone and slider page turns.',
                style: Theme.of(dialogContext).textTheme.bodySmall,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Close'),
            ),
          ],
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
          })
          ..addStatusListener((AnimationStatus status) {
            if (status == AnimationStatus.completed) _noteZoomSettled();
          });
    _zoomCurve = CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeInOutCubic,
    );

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
    _zoomSnapshotTimer?.cancel();
    PanelDetectionService.instance.cancelAll();
    _pageBytes.clear();
    _pageProviders.clear();
    _deferredZoom = null;
    _detachPagerListener();
    _zoomCurve.dispose();
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

  // Reads the persisted reading direction. Falls back to left-to-right.
  Future<void> _loadMangaMode() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      _isMangaMode = prefs.getBool(_kMangaModePrefKey) ?? false;
      _doubleLayoutIsManga = _isMangaMode;
    } catch (e, st) {
      debugPrint('Manga mode load failed: $e\n$st');
    }
  }

  Future<void> _persistMangaMode(bool value) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kMangaModePrefKey, value);
    } catch (e, st) {
      debugPrint('Manga mode save failed: $e\n$st');
    }
  }

  Future<void> _bootstrap() async {
    try {
      // The direction must be known before any layout is built or the pager is
      // shown (_isEngineReady is still false here).
      await _loadMangaMode();

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

      // Warm path: every page's size (and so the double-page layout) comes from
      // the index cache - zero image-header I/O. A cold cache falls through to
      // _loadRemainingLayoutData below.
      final bool dimsFromCache = await _applyCachedDimensions();

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
        if (dimsFromCache) _layoutReady = true; // Spread mode usable at once
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

      if (!dimsFromCache) unawaited(_loadRemainingLayoutData());
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

  // --- Page bitmap budget ------------------------------------------------------
  // A comic scan is often far larger than the screen (a 3000 x 4500 JPEG is
  // 54 MB once decoded to RGBA) and the resident window keeps up to three
  // spreads decoded in the ImageCache at once. Decoding every page at full
  // resolution is the app's largest memory consumer and the usual cause of
  // out-of-memory kills on 3-4 GB phones. Pages are therefore decoded at no
  // more than [_kMaxDecodedPagePixels] pixels (~24 MB) and
  // [_kMaxDecodedPageSide] on the long side. Panel detection (it reads the
  // original bytes) and the panel rectangles (normalised coordinates) are
  // unaffected, zoom stays sharp up to roughly twice the full-screen scale for
  // typical scans, and a page at or under the budget is not resized at all.
  // Every site that touches a page's bitmap (build, precache, evict) must go
  // through [_pageImageProvider]: the ImageCache key depends on the target size.
  static const int _kMaxDecodedPagePixels = 6 * 1024 * 1024;
  static const int _kMaxDecodedPageSide = 4096;

  // The provider handed to an Image widget must be the SAME instance while the
  // bytes and the measured size are unchanged: ResizeImage has no value
  // equality (MemoryImage has), so a fresh instance on every build would make
  // every Image re-resolve its stream on every rebuild of the reader.
  final Map<int, _PageProvider> _pageProviders = <int, _PageProvider>{};

  ImageProvider _pageImageProvider(int page, Uint8List bytes) {
    final Size? size = _imageSizesCache[page];
    final _PageProvider? cached = _pageProviders[page];
    if (cached != null &&
        identical(cached.bytes, bytes) &&
        cached.size == size) {
      return cached.provider;
    }
    final ImageProvider provider = _boundedPageProvider(bytes, size);
    _pageProviders[page] = _PageProvider(bytes, size, provider);
    return provider;
  }

  ImageProvider _boundedPageProvider(Uint8List bytes, Size? size) {
    final ImageProvider source = MemoryImage(bytes);
    if (size == null || size.width <= 0 || size.height <= 0) return source;

    final double scale = math.min(
      1.0,
      math.min(
        math.sqrt(_kMaxDecodedPagePixels / (size.width * size.height)),
        _kMaxDecodedPageSide / math.max(size.width, size.height),
      ),
    );
    if (scale >= 1.0) return source;

    return ResizeImage(
      source,
      width: math.max(1, (size.width * scale).floor()),
      height: math.max(1, (size.height * scale).floor()),
      policy: ResizeImagePolicy.fit,
    );
  }

  // Loads [pages] (current page first) and instantiates their image codecs
  // now, in the engine's background threads, so a page turn finds the decoded
  // image already in the ImageCache. A newer call supersedes an older one: when
  // the user flips through pages quickly, the stale windows stop at their next
  // page instead of piling decode work (and decoded bitmaps) on top of the
  // current one.
  int _warmGeneration = 0;

  Future<void> _warmWindow(List<int> pages) async {
    final int generation = ++_warmGeneration;
    for (final int page in pages) {
      if (generation != _warmGeneration) return;
      try {
        await _ensurePageLoaded(page);
        if (generation != _warmGeneration) return;
        final Uint8List? bytes = _pageBytes[page];
        if (!mounted || bytes == null) continue;
        await precacheImage(_pageImageProvider(page, bytes), context);
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
      if (bytes != null) unawaited(_pageImageProvider(page, bytes).evict());
      _pageProviders.remove(page); // must not keep the bytes alive
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

  // ---------------------------------------------------------------------------
  // Page dimensions: index cache + throttled cold probing
  // ---------------------------------------------------------------------------

  // Cold-cache probing. The pages around the reading position are measured
  // first (current spread, curl snapshots and the neighbours YOLOv8 works on
  // never wait for a sweep); the rest follows in small batches with a pause in
  // between, and a batch is held back (briefly) while a page turn, a pager
  // scroll or a panel-detection job is running.
  static const int _kDimsPriorityBefore = 2;
  static const int _kDimsPriorityAfter = 6;
  static const int _kDimsBatchPages = 8;
  static const Duration _kDimsBatchYield = Duration(milliseconds: 32);
  static const Duration _kDimsBusyPoll = Duration(milliseconds: 60);
  static const int _kDimsMaxBusyPolls = 8; // At most ~480 ms of waiting per batch.

  // Fills _imageSizesCache for EVERY page from the stored index and builds the
  // double-page layout, all before the first frame. Returns false (leaving the
  // caches untouched or partially filled) on a miss; the cold path then only
  // probes what is still unknown.
  Future<bool> _applyCachedDimensions() async {
    final ComicIdentity? comic = widget.comic;
    final int count = _pageCount;
    if (comic == null || count <= 0) return false;
    try {
      final Map<String, dynamic>? index = await ComicCacheService.instance
          .readIndexCache(comic.id);
      final Object? raw = index?['dimensions'];
      if (raw is! List || raw.length != count) return false;

      int known = 0;
      for (int i = 0; i < count; i++) {
        final Object? pair = raw[i];
        if (pair is! List || pair.length < 2) continue;
        final Object? w = pair[0];
        final Object? h = pair[1];
        if (w is int && h is int && w > 0 && h > 0) {
          _imageSizesCache[i] = Size(w.toDouble(), h.toDouble());
          known++;
        }
      }
      if (known != count) return false;

      await _buildDoubleLayout();
      return mounted;
    } catch (e, st) {
      debugPrint('Cached page dimensions unusable: $e\n$st');
      return false;
    }
  }

  // Stores every known page size next to the archive index, keyed by comic id.
  // Unknown pages are stored as [0, 0] and measured again next time.
  Future<void> _persistDimensionsToIndex() async {
    final ComicIdentity? comic = widget.comic;
    final int count = _pageCount;
    if (comic == null || count <= 0) return;

    final List<List<int>> dimensions = <List<int>>[];
    for (int i = 0; i < count; i++) {
      final Size? size = _imageSizesCache[i];
      dimensions.add(
        size == null
            ? <int>[0, 0]
            : <int>[size.width.round(), size.height.round()],
      );
    }
    await ComicCacheService.instance.mergeIndexCache(
      comic.id,
      <String, dynamic>{'pageCount': count, 'dimensions': dimensions},
    );
  }

  bool get _isPagerMoving {
    try {
      return _pageController.hasClients &&
          _pageController.position.isScrollingNotifier.value;
    } catch (_) {
      return false;
    }
  }

  // Lets an active page turn / scroll / detection job finish before the next
  // probe batch touches the disk. Bounded, so probing always makes progress.
  Future<void> _waitForQuietMoment() async {
    for (int i = 0; i < _kDimsMaxBusyPolls; i++) {
      if (!mounted) return;
      final bool busy =
          _navBusy ||
          _panelJobs.isNotEmpty ||
          _animationController.isAnimating ||
          _isPagerMoving;
      if (!busy) return;
      await Future<void>.delayed(_kDimsBusyPoll);
    }
  }

  // Probes [start, start + count) unless every page in it is already known.
  // Returns false once the screen is gone. A failed probe leaves its pages
  // unknown; the slow per-page fallback in _loadRemainingLayoutData covers them.
  Future<bool> _probeDimensionRange(
    PageDimensionProbe probe,
    int start,
    int count, {
    required bool throttle,
  }) async {
    if (!mounted) return false;
    bool needed = false;
    for (int i = start; i < start + count && !needed; i++) {
      needed = !_imageSizesCache.containsKey(i);
    }

    if (needed) {
      if (throttle) {
        await _waitForQuietMoment();
        if (!mounted) return false;
      }
      try {
        final List<PageDimensions?> part = await probe.probeDimensions(
          start,
          count,
        );
        if (!mounted) return false;
        for (int k = 0; k < part.length; k++) {
          final int page = start + k;
          final PageDimensions? d = part[k];
          if (d != null && !_imageSizesCache.containsKey(page)) {
            _imageSizesCache[page] = Size(
              d.width.toDouble(),
              d.height.toDouble(),
            );
          }
        }
      } catch (e, st) {
        debugPrint('Dimension probe [$start, ${start + count}) failed: $e\n$st');
      }
    }

    if (throttle) await Future<void>.delayed(_kDimsBatchYield);
    return mounted;
  }

  // 1) the priority window around the reading position in one call, 2) the
  // rest in micro-batches (forward to the last page, then backward to the
  // first), each preceded by a quiet-moment check and followed by a yield.
  Future<void> _probeAllDimensionsThrottled(PageDimensionProbe probe) async {
    final int count = _pageCount;
    final int lo = math.max(0, _currentPage - _kDimsPriorityBefore);
    final int hi = math.min(count - 1, _currentPage + _kDimsPriorityAfter);

    if (!await _probeDimensionRange(probe, lo, hi - lo + 1, throttle: false)) {
      return;
    }
    for (int s = hi + 1; s < count; s += _kDimsBatchPages) {
      final int n = math.min(_kDimsBatchPages, count - s);
      if (!await _probeDimensionRange(probe, s, n, throttle: true)) return;
    }
    for (int e = lo; e > 0; e -= _kDimsBatchPages) {
      final int s = math.max(0, e - _kDimsBatchPages);
      if (!await _probeDimensionRange(probe, s, e - s, throttle: true)) return;
    }
  }

  // Cold path: measures the pages that are still unknown (priority window
  // first, then throttled batches), then builds the double-page layout (it
  // needs every page's aspect ratio) and stores the sizes in the index cache.
  // Spread mode stays disabled until this has finished.
  Future<void> _loadRemainingLayoutData() async {
    try {
      final Object source = widget.source;
      if (source is PageDimensionProbe) {
        await _probeAllDimensionsThrottled(source);
      } else {
        // Sources without range probing (in-memory pages) keep the old sweep.
        final List<PageDimensions?> dims = await widget.source
            .readAllDimensions();
        if (!mounted) return;
        for (int i = 0; i < dims.length && i < _pageCount; i++) {
          final PageDimensions? d = dims[i];
          if (d != null && !_imageSizesCache.containsKey(i)) {
            _imageSizesCache[i] = Size(d.width.toDouble(), d.height.toDouble());
          }
        }
      }
      if (!mounted) return;

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

      // Fire and forget: the next open of this comic skips all of the above.
      unawaited(_persistDimensionsToIndex());
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
  List<bool> _wideFlags() => List<bool>.generate(_pageCount, (int i) {
    final Size? size = _imageSizesCache[i];
    return size != null && size.width > size.height * 1.15;
  }, growable: false);

  // Builds for the current reading direction. If the user flipped it while the
  // (possibly isolate-based) computation was running, it is computed again.
  Future<void> _buildDoubleLayout() async {
    final List<bool> wide = _wideFlags();
    bool manga;
    do {
      manga = _isMangaMode;
      final List<List<int?>> layout = await _computeDoubleLayoutOffThread(
        wide,
        manga: manga,
      );
      if (!mounted) return;
      _doubleLayout = layout;
      _doubleLayoutIsManga = manga;
    } while (manga != _isMangaMode);
  }

  // Used by _toggleMangaMode: computes a layout without assigning anything.
  Future<List<List<int?>>> _computeDoubleLayoutFor(bool manga) =>
      _computeDoubleLayoutOffThread(_wideFlags(), manga: manga);

  // Active layout (null placeholders removed). The compacted double layout is
  // built once per assignment of _doubleLayout instead of on every call: this
  // getter sits on the build path, the tap handlers and the per-frame curl
  // callbacks, and allocating a list per spread (~150 for a 300-page comic) each
  // time is pure garbage. Callers only read the result.
  List<List<int>>? _compactDoubleLayout;
  List<List<int?>>? _compactDoubleLayoutSource;

  List<List<int>> _getEffectiveLayout() {
    if (_isDoublePageView) {
      final List<List<int?>> source = _doubleLayout;
      final List<List<int>>? cached = _compactDoubleLayout;
      if (cached != null && identical(_compactDoubleLayoutSource, source)) {
        return cached;
      }
      // The effective layout is always in READING order. Manga spreads are
      // stored [left, right] = [later, earlier], so they are reversed here:
      // [i + 1, i] -> [i, i + 1] and [i, null] -> [i]. pages.first is always
      // the first page read (right side), pages.last the second (left side).
      final bool manga = _doubleLayoutIsManga;
      final List<List<int>> compact = source.map((spread) {
        final List<int> pages = spread.whereType<int>().toList();
        return manga ? pages.reversed.toList() : pages;
      }).toList();
      _compactDoubleLayoutSource = source;
      _compactDoubleLayout = compact;
      return compact;
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
  //
  // In manga mode the detected panels come back right-to-left (see
  // _orderPanelsRightToLeft). _detectedPanelsCache is not mutated or
  // invalidated: the ordered copy is memoised per page against the identity of
  // the cached list. Every consumer of a panel INDEX must go through this.
  List<ComicPanel> _panelsOf(int page) {
    final List<ComicPanel>? detected = _detectedPanelsCache[page];
    if (detected == null) return _fullPageFallback;
    if (!_isMangaMode || detected.length < 2) return detected;
    final _RtlPanelOrder? memo = _rtlPanelOrder[page];
    if (memo != null && identical(memo.source, detected)) return memo.ordered;
    final List<ComicPanel> ordered = _orderPanelsRightToLeft(detected);
    _rtlPanelOrder[page] = _RtlPanelOrder(detected, ordered);
    return ordered;
  }

  // For painters: "nothing detected yet" stays an empty list (no fallback box),
  // otherwise the same order as navigation so outlines/active panel agree.
  List<ComicPanel> _panelsForPainting(int page) =>
      _detectedPanelsCache.containsKey(page)
      ? _panelsOf(page)
      : const <ComicPanel>[];

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

    double wB = sizeB != null ? ch * (sizeB.width / sizeB.height) : cw / 2;
    final double wA = sizeA != null ? ch * (sizeA.width / sizeA.height) : wB;
    // Manga cover/end page [i, null]: the blank RIGHT half takes the page's
    // width (the LTR [null, i] case already does this via wA = wB).
    if (b == null && sizeA != null) wB = wA;

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
  void _onPanelsArrived(int page, List<ComicPanel> rawPanels) {
    if (!mounted || rawPanels.isEmpty) return;
    if (page != _currentPage || _fullPagePosition != FullPagePosition.none) {
      return;
    }
    // Panel indices follow the reading order (right-to-left in manga mode).
    final List<ComicPanel> panels = _panelsOf(page);
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

  // Swipe mode: announces the first movement away from a settled page, the
  // same moment ComicCurlPageView calls onPageTurnStarted in curl mode.
  void _trackSwipeTurnForSound() {
    final double? page = _safePagerPage();
    if (page == null) return;
    final double nearest = page.roundToDouble();
    if ((page - nearest).abs() < _pagerSettleEps) {
      _lastSettledVirtual = nearest.toInt();
      _swipeTurnSoundFired = false;
      return;
    }
    if (_swipeTurnSoundFired) return;
    final int from = _lastSettledVirtual ?? _currentVirtualOrNull() ?? 0;
    _swipeTurnSoundFired = true;
    _onCurlPageTurnStarted(from, page > from ? from + 1 : from - 1);
  }

  void _onPagerTick() {
    if (!mounted) return;
    if (!_useCurl) _trackSwipeTurnForSound();
    if (!_isPagerSettled) return;
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
      _transitionMode,
      _isMangaMode,
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
    // Swipe mode has no curl layer and therefore no snapshot to refresh.
    if (!_useCurl) return;
    try {
      await WidgetsBinding.instance.endOfFrame.timeout(
        _frameGuard,
        onTimeout: () {},
      );
      if (!mounted || epoch != _layoutEpoch || _suspendCurlForLayoutSwitch) {
        return;
      }
      await _curlSnapshot.refresh(timeout: _snapshotRefreshTimeout);
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
    final Offset? tapOrigin = _tapDownLocal;
    if (_tapPointer == event.pointer &&
        tapOrigin != null &&
        (event.localPosition - tapOrigin).distance > _kTapMoveSlop) {
      _tapPointer = null; // it is a drag, not a tap
    }
    final Offset? origin = _pointerDownAt;
    if (origin == null || !_animationController.isAnimating) return;
    if ((event.position - origin).distance < _zoomFastForwardSlop) return;
    if (!_canChangeZoom) return;
    _pointerDownAt = null;
    _animationController.value = 1.0;
    _curlSnapshotTick.value++;
  }

  void _onReaderPointerDown(PointerDownEvent event) {
    _pointerDownAt = event.position;
    _downPointers.add(event.pointer);
    if (_downPointers.length == 1) {
      _tapPointer = event.pointer;
      _tapDownLocal = event.localPosition;
      _tapDownTime = event.timeStamp;
      _edgeTapHandled = false;
    } else {
      _tapPointer = null; // a second finger: pinch or catch, not a tap
    }
  }

  // Edge-zone taps fire here, on finger-up (see _kInstantEdgeTaps).
  void _onReaderPointerUp(PointerUpEvent event, Size viewportSize) {
    _pointerDownAt = null;
    _downPointers.remove(event.pointer);
    final Duration? downTime = _tapDownTime;
    final bool isTap =
        _useInstantEdgeTaps &&
        _tapPointer == event.pointer &&
        downTime != null &&
        event.timeStamp - downTime <= _kTapMaxDuration;
    _tapPointer = null;
    if (!isTap || _suspendCurlForLayoutSwitch) return;

    final double x = event.localPosition.dx;
    final double width = viewportSize.width;
    if (x < width * _kEdgeZoneLeft) {
      _edgeTapHandled = true;
      _stepFromEdgeTap(leftEdge: true, viewportSize: viewportSize);
    } else if (x > width * _kEdgeZoneRight) {
      _edgeTapHandled = true;
      _stepFromEdgeTap(leftEdge: false, viewportSize: viewportSize);
    }
  }

  // One place decides what an edge tap means.
  //   LTR:   left edge = back,    right edge = forward
  //   Manga: left edge = forward, right edge = back
  void _stepFromEdgeTap({required bool leftEdge, required Size viewportSize}) {
    final bool forward = _isMangaMode ? leftEdge : !leftEdge;
    if (forward) {
      _nextPanel(viewportSize);
    } else {
      _prevPanel(viewportSize);
    }
  }

  void _onReaderPointerCancel(PointerCancelEvent event) {
    _pointerDownAt = null;
    _downPointers.remove(event.pointer);
    if (_tapPointer == event.pointer) {
      _tapPointer = null;
      _edgeTapHandled = false;
    }
  }

  // A zoom (animated panel focus, pinch or pan) has ended. The curl layer no
  // longer captures its snapshot at touch-down (see _kCaptureSnapshotOnTouchDown
  // in comic_page_curl_transition.dart), so it is refreshed here once the
  // picture has stopped moving: the reader is looking at the panel right now,
  // the cheapest moment for a full-page raster, and the next swipe then starts
  // from a texture that matches the screen.
  void _noteZoomSettled() {
    if (!_useCurl) return;
    _zoomSnapshotTimer?.cancel();
    _zoomSnapshotTimer = Timer(const Duration(milliseconds: 280), () {
      if (!mounted ||
          !_useCurl ||
          _suspendCurlForLayoutSwitch ||
          !_isPagerSettled) {
        return;
      }
      // Another zoom animation started meanwhile; its completion re-arms this.
      if (_animationController.isAnimating) return;
      _curlSnapshotTick.value++;
    });
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

    _zoomAnimation = Matrix4Tween(
      begin: beginMatrix,
      end: endMatrix,
    ).animate(_zoomCurve);

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

    _zoomAnimation = Matrix4Tween(
      begin: beginMatrix,
      end: endMatrix,
    ).animate(_zoomCurve);

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
            curve: _pageTurnCurve,
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
              curve: _pageTurnCurve,
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
        final List<ComicPanel>? panels = _detectedPanelsCache.containsKey(newPage)
            ? _panelsOf(newPage)
            : null;
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
    final List<ComicPanel>? cached =
        _detectedPanelsCache.containsKey(pages.first)
        ? _panelsOf(pages.first)
        : null;
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

  // Flips the reading direction without moving the reader: _currentPage and
  // _currentPanelIndex are never written here, so ReadingProgressTracker sees no
  // change and never records a reset or corrupted position.
  Future<void> _toggleMangaMode() async {
    if (_navBusy || _suspendCurlForLayoutSwitch) return;

    final bool next = !_isMangaMode;
    unawaited(_persistMangaMode(next)); // persisted immediately

    // Layout still being measured: just flip the flag. _buildDoubleLayout
    // notices and builds for the new direction.
    if (!_layoutReady) {
      setState(() => _isMangaMode = next);
      return;
    }

    _pendingArrivalSpread = -1;
    final int keepPage = _currentPage;
    final int keepPanel = _currentPanelIndex;
    final int lock = _lockNav();
    try {
      // Same protocol as _toggleSpreadView: zoom to identity, drop parked work,
      // freeze curl + scrolling, invalidate async continuations of the old
      // layout.
      _resetZoomInstant(force: true);
      _deferredZoom = null;
      _zoomResetPending = false;
      setState(() {
        _suspendCurlForLayoutSwitch = true;
        _layoutEpoch++;
        _curlZoomedVirtual = null;
        _zoomOwnerVirtual = null;
      });

      // Compute first (isolate for long books), then swap flag + layout in ONE
      // setState so no frame ever sees a half-switched state.
      final List<List<int?>> newDouble = await _computeDoubleLayoutFor(next);
      if (!mounted) return;
      setState(() {
        _isMangaMode = next;
        _doubleLayout = newDouble;
        _doubleLayoutIsManga = next;
      });

      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;

      // Keep the pager on the same physical page. The curl is suspended, so
      // onPageChanged is ignored while jumping.
      final List<List<int>> newLayout = _getEffectiveLayout();
      if (newLayout.isNotEmpty) {
        final int targetVirtual = _findVirtualPageIndex(keepPage)
            .clamp(0, newLayout.length - 1)
            .toInt();
        bool positioned = false;

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
          _pageController.jumpToPage(targetVirtual);
          await WidgetsBinding.instance.endOfFrame;
        }
      }

      // Belt and braces: restore progress only if something moved it.
      if (mounted &&
          (_currentPage != keepPage || _currentPanelIndex != keepPanel)) {
        setState(() {
          _currentPage = keepPage;
          _currentPanelIndex = keepPanel;
        });
      }
    } catch (e, st) {
      debugPrint('Manga mode toggle failed: $e\n$st');
    } finally {
      if (mounted && _suspendCurlForLayoutSwitch) {
        // The curl widget re-anchors and drops old-direction textures on this
        // false -> true transition.
        setState(() => _suspendCurlForLayoutSwitch = false);
      }
      _unlockNav(lock);
    }
    if (!mounted) return;

    _onPagerSettled();

    // Snapshots were taken in the old direction: refresh the curl texture.
    _curlSnapshotDirty = true;
    if (_transformationController.value.isIdentity()) {
      _curlSnapshotTick.value++;
    }

    final List<List<int>> layout = _getEffectiveLayout();
    if (layout.isEmpty) return;
    final int v = _findVirtualPageIndex(_currentPage)
        .clamp(0, layout.length - 1)
        .toInt();
    _schedulePrefetch(v);
    unawaited(_ensureSpreadPanels(layout[v]));

    // The zoom was reset for the switch: put the camera back on the current
    // panel (looked up in the new order). Full-page views stay at identity.
    final Size? viewport = _lastViewportSize;
    if (viewport != null && _fullPagePosition == FullPagePosition.none) {
      final List<ComicPanel> panels = _panelsOf(_currentPage);
      if (_currentPanelIndex < panels.length) {
        _focusOnPanel(panels[_currentPanelIndex], viewport);
      }
    }
  }

  // Switches between the page curl and the plain horizontal swipe. The two
  // pagers are different widgets and a ScrollController must never be attached
  // to two scroll views at once, so each switch gives the new pager a fresh
  // PageController that opens on the current spread; the old controller is
  // disposed once its widget has left the tree. Reading position, panel and
  // zoom are untouched. Ignored while a turn, a drag or a layout switch runs.
  Future<void> _setTransitionMode(PageTransitionMode mode) async {
    if (mode == _transitionMode) return;
    if (_navBusy || _suspendCurlForLayoutSwitch || !_isPagerSettled) return;

    final int lock = _lockNav();
    PageController? retired;
    try {
      final int? virtual = _currentVirtualOrNull();
      final PageController old = _pageController;
      _detachPagerListener();
      _pageController = PageController(initialPage: virtual ?? 0);
      retired = old;
      _attachPagerListener();
      _lastSettledVirtual = virtual;
      _swipeTurnSoundFired = false;

      setState(() {
        _transitionMode = mode;
        
        // ---> ADD THIS LINE: If curl mode is turned off (switched to swipe), 
        // automatically turn off the page sound effect.
        if (mode == PageTransitionMode.swipe) {
          _pageSoundEnabled = false;
          unawaited(_pageTurnSound.setEnabled(false));
        }
      });
      await WidgetsBinding.instance.endOfFrame;
    } catch (e, st) {
      debugPrint('Transition switch failed: $e\n$st');
    } finally {
      retired?.dispose();
      _unlockNav(lock);
    }
    if (!mounted) return;

    // A freshly built curl layer has no snapshot of the page yet.
    if (_useCurl) {
      _curlSnapshotDirty = true;
      if (_transformationController.value.isIdentity()) {
        _curlSnapshotTick.value++;
      }
    }
    _onPagerSettled();
  }

  // 3-zone tap handler (left 30%: prev, right 30%: next, center: toggle UI)
  void _handleScreenTap(TapUpDetails details, Size viewportSize) {
    if (_suspendCurlForLayoutSwitch) return;
    if (_edgeTapHandled) {
      _edgeTapHandled = false;
      return;
    }
    final double screenWidth = viewportSize.width;
    final double tapX = details.localPosition.dx;

    // Edge zones are handled on finger-up (see _onReaderPointerUp).
    if (_useInstantEdgeTaps &&
        (tapX < screenWidth * _kEdgeZoneLeft ||
            tapX > screenWidth * _kEdgeZoneRight)) {
      return;
    }

    if (tapX < screenWidth * _kEdgeZoneLeft) {
      _stepFromEdgeTap(leftEdge: true, viewportSize: viewportSize);
    } else if (tapX > screenWidth * _kEdgeZoneRight) {
      _stepFromEdgeTap(leftEdge: false, viewportSize: viewportSize);
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

    // Taps in the edge zones are navigation taps (see _onReaderPointerUp); a
    // quick second tap there steps on again instead of zooming.
    if (_useInstantEdgeTaps &&
        (localPos.dx < viewportSize.width * _kEdgeZoneLeft ||
            localPos.dx > viewportSize.width * _kEdgeZoneRight)) {
      return;
    }

    // Consume Tap 2's pointer so its upcoming PointerUpEvent does not fire
    // _onReaderPointerUp after _showPanel switches out of full-page mode.
    _tapPointer = null;

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

      final List<ComicPanel> panels = _panelsForPainting(page);
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
    // Manga cover/end page [i, null]: real page on the left, blank placeholder
    // leaf of equal size on the right.
    if (b == null) {
      if (a == null) return null;
      final Rect? pageLeft = _pageRect(virtualIndex, a, vp);
      if (pageLeft == null || pageLeft.isEmpty) return null;
      return ComicCurlLeaves(
        left: pageLeft,
        right: Rect.fromLTRB(
          pageLeft.right,
          pageLeft.top,
          pageLeft.right + pageLeft.width,
          pageLeft.bottom,
        ),
      );
    }

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
      // A pointer-up that never arrives must not leave a stale finger behind.
      _downPointers.clear();
      _tapPointer = null;
    }
  }

  // The OS is short of memory: release everything that can be rebuilt. The
  // framework already clears the ImageCache; this also drops the encoded bytes
  // of every page outside the current spread (they are re-read on demand when
  // their page is built again).
  @override
  void didHaveMemoryPressure() {
    if (!mounted || !_isEngineReady) return;
    final List<List<int>> layout = _getEffectiveLayout();
    if (layout.isEmpty) return;
    final int virtual = _findVirtualPageIndex(_currentPage);
    if (virtual < 0 || virtual >= layout.length) return;
    final Set<int> keep = layout[virtual].toSet();
    final List<int> drop = _pageBytes.keys
        .where((int page) => !keep.contains(page))
        .toList();
    for (final int page in drop) {
      final Uint8List? bytes = _pageBytes.remove(page);
      if (bytes != null) unawaited(_pageImageProvider(page, bytes).evict());
      _pageProviders.remove(page);
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
        await _ensurePanels(page);
        if (!mounted) return;
        // Saved panel indices refer to the current reading order.
        final List<ComicPanel> panels = _panelsOf(page);

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
                        onPointerDown: _onReaderPointerDown,
                        onPointerMove: _onReaderPointerMove,
                        onPointerUp: (PointerUpEvent event) =>
                            _onReaderPointerUp(event, constraints.biggest),
                        onPointerCancel: _onReaderPointerCancel,
                        child: _useCurl
                            ? ComicCurlPageView.builder(
                                controller: _pageController,
                                reverse: _isMangaMode,
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
                                physics: _pagerPhysics,
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
                                onPageChanged: _onPagerPageChanged,
                                itemBuilder: (context, virtualIndex) =>
                                    _buildPagerItem(virtualIndex, zoomOwner),
                              )
                            // Plain horizontal slide: same controller type, same
                            // physics, same page content and zoom ownership.
                            : PageView.builder(
                                controller: _pageController,
                                reverse: _isMangaMode,
                                physics: _pagerPhysics,
                                itemCount: effectiveLayout.length,
                                onPageChanged: _onPagerPageChanged,
                                itemBuilder: (context, virtualIndex) =>
                                    _buildPagerItem(virtualIndex, zoomOwner),
                              ),
                      ),
                    ),
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: _buildHeader(),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: _buildBottomBar(),
                    ),
                  ],
                );
              },
            ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Pager helpers shared by the page curl and the horizontal swipe
  // ---------------------------------------------------------------------------

  ScrollPhysics get _pagerPhysics =>
      (_isScreenLocked || _suspendCurlForLayoutSwitch)
      ? const NeverScrollableScrollPhysics()
      : const _ReaderPagerPhysics(parent: BouncingScrollPhysics());

  void _onPagerPageChanged(int virtualIndex) {
    // Programmatic navigation and layout remapping already own the reader
    // state; ignore transient indices.
    if (_navBusy || _suspendCurlForLayoutSwitch) return;
    if (_findVirtualPageIndex(_currentPage) == virtualIndex) return;
    _arriveBySwipe(virtualIndex);
  }

  Widget _buildPagerItem(int virtualIndex, int zoomOwner) {
    // Only the interactive foreground page owns the shared controller. The
    // curl's backFaceBuilder renders a separate static copy without an
    // InteractiveViewer.
    final TransformationController? controller = virtualIndex == zoomOwner
        ? _transformationController
        : null;
    final Key key = ValueKey('${_isDoublePageView ? 'd' : 's'}$virtualIndex');
    return Center(
      child: InteractiveViewer(
        key: key,
        transformationController: controller,
        minScale: 1.0,
        maxScale: 5.0,
        // Pinch / pan finished: refresh the curl snapshot once it settles.
        onInteractionEnd: controller == null
            ? null
            : (ScaleEndDetails details) => _noteZoomSettled(),
        child: Center(child: _buildVirtualPageContent(virtualIndex)),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Header (title only) and bottom control hub
  // ---------------------------------------------------------------------------

  // The comic's name without its file extension (Batman_01.cbz -> Batman_01).
  // If ComicIdentity carries a name or file name, use it as the fallback here:
  //   _comicDisplayTitle(widget.title ?? widget.comic?.<field>)
  String get _headerTitle {
    final String name = _comicDisplayTitle(widget.title);
    return name.isEmpty ? 'PanelShift Reader' : name;
  }

  Widget _buildHeader() {
    return IgnorePointer(
      ignoring: !_showUI,
      child: AnimatedSlide(
        offset: _showUI ? Offset.zero : const Offset(0, -1),
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeInOut,
        child: AnimatedOpacity(
          opacity: _showUI ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 200),
          // Text only: every action lives in the bottom control hub. The
          // standard back arrow is kept; set automaticallyImplyLeading to
          // false for a purely text header (system back still works).
          child: AppBar(
            backgroundColor: Colors.black.withValues(alpha: 0.8),
            iconTheme: const IconThemeData(color: Colors.white),
            title: Text(
              _headerTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBottomBar() {
    return IgnorePointer(
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
            // Absorb taps/drags at the overlay boundary; the slider below owns
            // its horizontal drag gesture.
            onTap: () {},
            child: SafeArea(
              top: false,
              child: Container(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.82),
                  border: Border(
                    top: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildPageSlider(),
                    const SizedBox(height: 2),
                    Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 560),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _buildPrimaryControls(),
                            // Secondary row: expands above the page edge of the
                            // bar so the slider never moves.
                            AnimatedSize(
                              duration: const Duration(milliseconds: 200),
                              curve: Curves.easeInOut,
                              alignment: Alignment.topCenter,
                              child: _showMoreControls
                                  ? Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Divider(
                                          height: 8,
                                          thickness: 1,
                                          color: Colors.white.withValues(
                                            alpha: 0.12,
                                          ),
                                        ),
                                        _buildSecondaryControls(),
                                      ],
                                    )
                                  : const SizedBox(width: double.infinity),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // Page counter + slider. Has its own notifier so scrubbing rebuilds only
  // this part of the bar, not the comic pages or the control buttons.
  Widget _buildPageSlider() {
    return ValueListenableBuilder<double>(
      valueListenable: _footerPageValue,
      builder: (context, scrubValue, _) {
        final double displayedPage = _isFooterScrubbing
            ? scrubValue
            : (_currentPage + 1).toDouble();
        final int pageCount = math.max(1, _pageCount).toInt();
        final double sliderValue = displayedPage.clamp(
          1.0,
          pageCount.toDouble(),
        );
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Row(
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
                onChangeStart: _pageCount <= 1
                    ? null
                    : (value) {
                        _isFooterScrubbing = true;
                        _footerPageValue.value = value;
                      },
                onChanged: _pageCount <= 1
                    ? null
                    : (value) {
                        _footerPageValue.value = value;
                      },
                onChangeEnd: _pageCount <= 1
                    ? null
                    : (value) {
                        _isFooterScrubbing = false;
                        _footerPageValue.value = value;
                        unawaited(_jumpToPhysicalPage(value.round() - 1));
                      },
              ),
            ),
          ],
        );
      },
    );
  }

  // Everyday toggles: one tap flips them.
  Widget _buildPrimaryControls() {
    return Row(
      children: [
        Expanded(
          child: _HubButton(
            icon: _isScreenLocked ? Icons.lock : Icons.lock_open,
            label: _isScreenLocked ? 'Locked' : 'Unlocked',
            tooltip: _isScreenLocked
                ? 'Screen locked (swiping disabled)'
                : 'Screen unlocked (swiping enabled)',
            active: _isScreenLocked,
            onPressed: () => setState(() => _isScreenLocked = !_isScreenLocked),
          ),
        ),
        Expanded(
          child: _HubButton(
            icon: _isDoublePageView
                ? Icons.menu_book
                : Icons.chrome_reader_mode,
            label: _isDoublePageView ? 'Double' : 'Single',
            tooltip: _layoutReady
                ? 'Toggle single / double page view'
                : 'Preparing spread layout',
            active: _isDoublePageView,
            // Spreads need every page's size, which is measured in the
            // background right after the first frame.
            onPressed: _layoutReady ? _toggleSpreadView : null,
          ),
        ),
        Expanded(
          child: _HubButton(
            icon: _showPanelOutlines ? Icons.border_outer : Icons.border_clear,
            label: 'Outlines',
            tooltip: 'Toggle panel outlines & numbers',
            active: _showPanelOutlines,
            onPressed: () =>
                setState(() => _showPanelOutlines = !_showPanelOutlines),
          ),
        ),
        Expanded(
          child: _HubButton(
            icon: _showPanelOverlays ? Icons.layers : Icons.layers_outlined,
            label: 'Panel dim',
            tooltip: 'Toggle panel dimming',
            active: _showPanelOverlays,
            onPressed: () =>
                setState(() => _showPanelOverlays = !_showPanelOverlays),
          ),
        ),
        Expanded(
          child: _HubButton(
            icon: _useCurl ? Icons.auto_stories : Icons.swipe,
            label: _useCurl ? 'Curl' : 'Swipe',
            tooltip: _useCurl
                ? 'Page curl (tap for horizontal swipe)'
                : 'Horizontal swipe (tap for page curl)',
            onPressed: () => unawaited(
              _setTransitionMode(
                _useCurl ? PageTransitionMode.swipe : PageTransitionMode.curl,
              ),
            ),
          ),
        ),
        Expanded(
          child: _HubButton(
            icon: _showMoreControls ? Icons.expand_more : Icons.expand_less,
            label: _showMoreControls ? 'Less' : 'More',
            tooltip: _showMoreControls
                ? 'Hide extra controls'
                : 'Sound, dimming, full-page step, speed',
            active: _showMoreControls,
            onPressed: () =>
                setState(() => _showMoreControls = !_showMoreControls),
          ),
        ),
      ],
    );
  }

  // Settings that open a dialog or cycle through several states.
  Widget _buildSecondaryControls() {
    return Row(
      children: [
        Expanded(
          child: _HubButton(
            icon: _pageSoundEnabled ? Icons.volume_up : Icons.volume_off,
            label: 'Sound',
            tooltip: 'Page sound',
            active: _pageSoundEnabled,
            onPressed: _showPageSoundDialog,
          ),
        ),
        Expanded(
          child: _HubButton(
            icon: Icons.brightness_6,
            label: 'Dim ${(_dimmingLevel * 100).round()}%',
            tooltip: 'Adjust dimming level',
            onPressed: _showDimmingDialog,
          ),
        ),
        Expanded(
          child: _HubButton(
            icon: switch (_fullPageStepMode) {
              FullPageStepMode.none => Icons.fullscreen_exit,
              FullPageStepMode.afterLast => Icons.vertical_align_bottom,
              FullPageStepMode.beforeFirst => Icons.vertical_align_top,
              FullPageStepMode.both => Icons.unfold_more,
            },
            label: switch (_fullPageStepMode) {
              FullPageStepMode.none => 'Full: Off',
              FullPageStepMode.afterLast => 'Full: After',
              FullPageStepMode.beforeFirst => 'Full: Before',
              FullPageStepMode.both => 'Full: Both',
            },
            tooltip: 'Full-page step: ${_fullPageStepMode.name}',
            active: _fullPageStepMode != FullPageStepMode.none,
            onPressed: _cycleFullPageStepMode,
          ),
        ),
        Expanded(
          child: _HubButton(
            icon: Icons.speed,
            label: 'Speed ${_formatSpeed(_pageTurnSpeed)}',
            tooltip: 'Page-turn speed',
            active: _pageTurnSpeed != 1.0,
            onPressed: _showTurnSpeedDialog,
          ),
        ),
        Expanded(
          child: _HubButton(
            icon: _isMangaMode
                ? Icons.format_textdirection_r_to_l
                : Icons.format_textdirection_l_to_r,
            label: 'Manga',
            tooltip: _isMangaMode
                ? 'Manga order: right-to-left (tap for left-to-right)'
                : 'Left-to-right (tap for manga right-to-left)',
            active: _isMangaMode,
            onPressed: () => unawaited(_toggleMangaMode()),
          ),
        ),
      ],
    );
  }

  void _cycleFullPageStepMode() {
    setState(() {
      _fullPageStepMode = switch (_fullPageStepMode) {
        FullPageStepMode.none => FullPageStepMode.afterLast,
        FullPageStepMode.afterLast => FullPageStepMode.beforeFirst,
        FullPageStepMode.beforeFirst => FullPageStepMode.both,
        FullPageStepMode.both => FullPageStepMode.none,
      };
    });
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
    final List<ComicPanel> panels = _panelsForPainting(pageIndex);
    final imgSize = _imageSizesCache[pageIndex];
    final Uint8List? bytes = _pageBytes[pageIndex];
    // Outside the resident window (or still being read): nothing to draw yet.
    // The load is (re)started and setState redraws this page when it lands.
    if (bytes == null) {
      _requestPageBytes(pageIndex);
      return const SizedBox.shrink();
    }

    return imgSize == null
        ? Image(
            image: _pageImageProvider(pageIndex, bytes),
            fit: BoxFit.contain,
          )
        : AspectRatio(
            aspectRatio: imgSize.width / imgSize.height,
            child: Stack(
              fit: StackFit.passthrough,
              children: [
                Image(
                  image: _pageImageProvider(pageIndex, bytes),
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                ),
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

        double wB = sizeB != null
            ? maxHeight * (sizeB.width / sizeB.height)
            : maxWidth / 2;
        final double wA = sizeA != null
            ? maxHeight * (sizeA.width / sizeA.height)
            : wB;
        // Manga cover/end page [i, null]: the blank RIGHT half takes the
        // page's width.
        if (pageB == null && sizeA != null) wB = wA;

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
    final List<ComicPanel> panels = _panelsForPainting(page);
    final Uint8List? bytes = _pageBytes[page];
    // Bytes not here yet (this half is slower than its neighbour): start/join
    // the load. _loadPage calls setState as soon as they arrive, which rebuilds
    // this widget with the Image.memory below.
    if (bytes == null) _requestPageBytes(page);
    return Stack(
      fit: StackFit.expand,
      children: [
        if (bytes != null)
          Image(
            image: _pageImageProvider(page, bytes),
            fit: BoxFit.fill,
            gaplessPlayback: true,
          )
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
          Container(color: Colors.black.withValues(alpha: _dimmingLevel)),
      ],
    );
  }
}

// One control of the bottom hub: icon over a short caption. Highlighted while
// the feature it controls is on; greyed out when it has no action.
class _HubButton extends StatelessWidget {
  const _HubButton({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.onPressed,
    this.active = false,
  });

  final IconData icon;
  final String label;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final bool enabled = onPressed != null;
    final Color color = !enabled
        ? Colors.white30
        : (active ? Colors.white : Colors.white70);
    return Tooltip(
      message: tooltip,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Material(
          color: active ? Colors.white.withValues(alpha: 0.14) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 22, color: color),
                  const SizedBox(height: 2),
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: color,
                      fontSize: 10.5,
                      fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
