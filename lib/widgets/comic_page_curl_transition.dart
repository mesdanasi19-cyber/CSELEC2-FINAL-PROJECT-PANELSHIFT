// comic_page_curl_transition.dart
//
// Touch-responsive page curl for the PanelShift reader.
//
// How it works
// ------------
// * The PageView keeps doing all scrolling, snapping and `onPageChanged`.
//   The curl is a pure visual layer driven by `PageController`'s scroll
//   position, so it plays for finger drags AND for programmatic
//   `animateToPage` calls (tap navigation), in both directions.
// * Pages are "stacked": every page is shifted back to x = 0. For a scroll
//   position between items k and k+1 one of them is the sheet being peeled
//   ("top") and the other is revealed underneath ("under").
// * The peeled sheet is a cylinder roll plus a flat flap showing the back of
//   the paper. The page widget itself is painted once (clipped with a path);
//   the roll, flap and shadows are canvas paths/gradients. InteractiveViewer /
//   panel overlays / TransformationController are untouched.
// * The fold angle comes from the pull vector between the finger and the
//   midpoint of the opposing (hinge-side) edge, so a corner grab folds along
//   the diagonal, a mid-height grab folds straight, and a diagonal drag bends
//   the fold continuously. There is no fixed tilt range.
// * Shadows and highlights are multiplied by an edge-proximity envelope, so
//   they dissolve over the last frames of a turn instead of snapping off when
//   the curl layer hands back to the settled page.
//
// Back of the sheet
// -----------------
// * Single page (or any whole-sheet fallback): the flap/roll show a ghost of
//   the SAME page - mirrored about the fold line (that is what you see through
//   thin paper), colour-inverted and low opacity - over a translucent paper
//   tint. See [ComicCurlPageView.ghostBackFace].
// * Two-page spread (needs `leavesBuilder`): the spread is NOT one sheet. Like
//   a book, ONE page is the leaf:
//     forward : right page, hinged at the spine, peels right -> left.
//               Its back shows the LEFT page of the next spread; the RIGHT
//               page of the next spread is revealed underneath.
//     reverse : left page of the current spread peels left -> right.
//               Its back shows the RIGHT page of the previous spread; the LEFT
//               page of the previous spread is revealed underneath.
//   The facing page on the back is drawn upright and lands exactly on its
//   natural position, so the hand-over to the next spread is seamless.
//
// Single page, BACKWARD turn: the paper's LEFT edge is the anchor. The sheet
// peels from that edge and the fold travels from the left edge outward to the
// right (see `leftEdgeReverse` in [_CurlGeometry.compute]).
//
// Usage: replace `PageView.builder(` with `ComicCurlPageView.builder(`.
// Assumes viewportFraction == 1.0 (one page per viewport).

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';

/// Returns the rect (in item/viewport coordinates) occupied by the paper of
/// the page at [index]. Return null to use the whole viewport.
typedef ComicCurlPaperRectBuilder = Rect? Function(int index, Size viewport);

/// Page rects (viewport coordinates) of a two-page spread. [left] and [right]
/// meet at the spine. A blank placeholder page still needs a rect.
@immutable
class ComicCurlLeaves {
  const ComicCurlLeaves({required this.left, required this.right});

  final Rect left;
  final Rect right;
}

/// Returns the leaves of the item at [index], or null when the item is not a
/// two-page spread (single page, wide page, zoomed in...). Null keeps the
/// whole-sheet curl for that item.
typedef ComicCurlLeavesBuilder = ComicCurlLeaves? Function(
  int index,
  Size viewport,
);

// Fold orientation. The angle is atan2(rise, run) of the pull vector; the run
// is smoothed with a floor (fraction of the sheet width) so a grab beside the
// pivot cannot flip the fold to horizontal. The angle is only SOFT limited.
const double _kSoftTiltLimit = 1.25; // radians (~72 deg), asymptote, not a clamp
const double _kTiltRunFloorFraction = 0.2;
// The fold's pivot (on the hinge-side edge) slides vertically toward the
// finger by this fraction of the finger's offset from the sheet centre, so the
// fold pivots around the finger's own height instead of the page centre.
// It must stay < 1: a pivot level with the finger would give a zero rise and
// freeze the tilt at 0.
const double _kPivotFollow = 0.3;
// Gain on the finger's rise relative to the pivot. Compensates the offset the
// moving pivot removes, so small finger shifts still swing the fold quickly.
const double _kTiltRiseGain = 1.5;
// Touch filter: movements larger than [_kTouchJitterPx] are followed with no
// latency at all; only sub-pixel-scale tremor is low-pass filtered (down to
// [_kTouchMinFollow] of the remaining distance per pointer-move event).
const double _kTouchMinFollow = 0.45;
const double _kTouchJitterPx = 8.0;
// Single-page curls finish when this fraction of the page travel is done
// (valid 0.8 .. 0.9). Past it the curl is complete and nothing is peeled.
const double _kCurlCompletionTravel = 0.9;
// Single-page folds ease to a straight (untilted) line over the last part of
// the curl, so the sheet leaves cleanly regardless of where the finger was.
const double _kStraightFoldStart = 0.75;
const double _kDefaultTouchX = 0.5; // neutral horizontal anchor for programmatic turns
const double _kDefaultTouchY = 0.85; // lower fold origin for taps / no finger (0..1)
const double _kDefaultRadiusFraction = 0.075; // roll radius vs. short side
const double _kDefaultGhostOpacity = 0.35; // inverted ghost on the back
const double _kDefaultGhostPaperOpacity = 1; // paper tint under the ghost
// Keep the curl alive almost to the settled PageView position. The direction
// anchor uses the same narrow threshold so it cannot flip while curling.
const double _kEdgeEps = 1e-4;
const double _kAnchorEps = 1e-4;
const double _kTextureHandoffWindow = 0.018;
// Shadows/highlights fade to zero over this much progress at both ends.
const double _kEffectFadeWindow = 0.03;
const double _kEffectEpsilon = 0.002;

// Snapshot (page texture) budget. Numbers are PIXELS, not bytes: 16 Mpx is
// 64 MB of RGBA, 24 Mpx is 96 MB.
const double _kSnapshotMaxDpr = 4.0;
const double _kSnapshotMaxPixels = 16.0 * 1024.0 * 1024.0;
const double _kSnapshotMaxDimension = 6144.0;
// Two-page spreads carry twice the artwork, so they get a larger budget that
// scales with how much of the viewport width the leaves actually cover.
const double _kSpreadSnapshotMaxDpr = 4.5;
const double _kSpreadSnapshotMaxPixels = 24.0 * 1024.0 * 1024.0;
const double _kSpreadSnapshotMaxDimension = 8192.0;
// Hard ceiling for all retained snapshots together (current page + stale
// neighbours), so the larger spread budget cannot stack up on low-memory
// devices. The anchor page's snapshot is never evicted.
const double _kSnapshotTotalPixelCap = 56.0 * 1024.0 * 1024.0;
const int _kSnapshotPaintRetries = 3;

double _clamp(double v, double lo, double hi) =>
    v < lo ? lo : (v > hi ? hi : v);

double _smoothStep(double edge0, double edge1, double value) {
  if (edge1 <= edge0) return value >= edge1 ? 1.0 : 0.0;
  final double t = _clamp((value - edge0) / (edge1 - edge0), 0.0, 1.0);
  return t * t * (3.0 - 2.0 * t);
}

/// Smooth saturation: ~x near zero, asymptotically +-[limit]. Unlike a clamp it
/// has no hard stop, so the fold keeps responding all the way out.
double _softLimit(double x, double limit) {
  if (limit <= 0.0) return 0.0;
  final double e = math.exp(2.0 * _clamp(x, -20.0 * limit, 20.0 * limit) / limit);
  return limit * (e - 1.0) / (e + 1.0);
}

/// 1 while a turn is well inside its range, easing to 0 as [progress] reaches
/// either end. Drives the shadow/highlight dissolve.
double _edgeEnvelope(double progress, {double window = _kEffectFadeWindow}) {
  return _smoothStep(0.0, window, math.min(progress, 1.0 - progress));
}

// ---------------------------------------------------------------------------
// Public widgets
// ---------------------------------------------------------------------------

/// Lets the host refresh the curl layer's page snapshot and wait for it.
///
/// A snapshot is a raster copy of the settled page. It has to show the page
/// exactly as the next turn starts (same zoom, same panel dimming), otherwise
/// the textured part of the curl visibly differs from the live page. Hosts
/// that change the page's appearance right before a programmatic turn call
/// [refresh] and start the turn when it completes.
class ComicCurlSnapshotController {
  _ComicCurlPageViewState? _state;

  /// Completes when a snapshot taken AFTER this call has been stored, when the
  /// layer cannot take one (disabled, not attached, not built yet), or after
  /// [timeout]. Never throws and never waits indefinitely.
  Future<void> refresh({
    Duration timeout = const Duration(milliseconds: 160),
  }) {
    final _ComicCurlPageViewState? state = _state;
    if (state == null) return Future<void>.value();
    return state._refreshSnapshotNow(timeout);
  }
}

/// Drop-in replacement for `PageView.builder` that turns pages with a curl.
class ComicCurlPageView extends StatefulWidget {
  const ComicCurlPageView.builder({
    super.key,
    required this.controller,
    required this.itemCount,
    required this.itemBuilder,
    this.backFaceBuilder,
    this.physics,
    this.onPageChanged,
    this.onPageTurnStarted,
    this.isInteractionBlocked,
    this.paperRectBuilder,
    this.leavesBuilder,
    this.snapshotController,
    this.snapshotInvalidator,
    this.paperColor = const Color(0xFFF3EDE0),
    this.ghostBackFace = true,
    this.ghostOpacity = _kDefaultGhostOpacity,
    this.ghostPaperOpacity = _kDefaultGhostPaperOpacity,
    this.radiusFraction = _kDefaultRadiusFraction,
    this.enabled = true,
  });

  final PageController controller;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

  /// Optional non-interactive copy of an item used only on a curled leaf's
  /// back. This avoids attaching a reader's shared TransformationController
  /// to two InteractiveViewers at the same time.
  final IndexedWidgetBuilder? backFaceBuilder;

  final ScrollPhysics? physics;
  final ValueChanged<int>? onPageChanged;

  /// Called once as an actual animated/gesture-driven turn leaves its settled
  /// page. Instant jumps and disabled layout remaps do not emit this callback.
  /// [fromIndex] and [toIndex] are virtual PageView indices.
  final void Function(int fromIndex, int toIndex)? onPageTurnStarted;

  /// Evaluated when a finger touches down. While it returns true, horizontal
  /// drags are swallowed so the user cannot fight a programmatic transition.
  final bool Function()? isInteractionBlocked;

  /// Paper rect of a page inside the viewport (letterboxing, spreads, ...).
  /// Used for whole-sheet curls.
  final ComicCurlPaperRectBuilder? paperRectBuilder;

  /// Per-page rects of two-page spreads. When it returns non-null for BOTH
  /// items involved in a turn, the turn is book-style (one page peels).
  final ComicCurlLeavesBuilder? leavesBuilder;

  /// Optional handle to refresh the settled page's snapshot on demand.
  final ComicCurlSnapshotController? snapshotController;

  /// Optional signal that the settled page's appearance changed (panel
  /// dimming, outlines, ...). The curl layer re-captures the settled page,
  /// postponing the swap until no turn is in flight.
  final Listenable? snapshotInvalidator;

  /// Colour of the paper (back of a whole sheet, tint under the ghost).
  final Color paperColor;

  /// Whole-sheet back face: show an inverted, low-opacity mirror image of the
  /// page itself instead of plain paper.
  final bool ghostBackFace;

  /// Opacity of that ghost (0..1).
  final double ghostOpacity;

  /// Opacity of the paper tint under the ghost. 0 = fully see-through (the
  /// page underneath shows through as well), 1 = opaque paper.
  final double ghostPaperOpacity;

  /// Roll radius as a fraction of the viewport's short side.
  final double radiusFraction;

  /// When false pages simply scroll (the curl layer becomes a pass-through).
  final bool enabled;

  @override
  State<ComicCurlPageView> createState() => _ComicCurlPageViewState();
}

class _ComicCurlPageViewState extends State<ComicCurlPageView> {
  // Pointer position in normalized viewport coordinates. X is captured when
  // the gesture starts and held stable; Y follows the finger (low-pass
  // filtered) while a turn is in progress, so diagonal drags bend the fold
  // fluidly without the mesh jittering under the finger.
  final ValueNotifier<Offset> _touchPosition = ValueNotifier<Offset>(
    const Offset(_kDefaultTouchX, _kDefaultTouchY),
  );
  final ValueNotifier<int> _snapshotRevision = ValueNotifier<int>(0);
  final Map<int, GlobalKey> _snapshotKeys = <int, GlobalKey>{};
  final Map<int, ui.Image> _snapshots = <int, ui.Image>{};
  // Logical size each snapshot was captured at. A snapshot is only used while
  // the viewport still has that size (rotation, split-screen resize).
  final Map<int, Size> _snapshotSizes = <int, Size>{};
  final Set<int> _snapshotScheduled = <int>{};
  final Set<int> _snapshotCapturing = <int>{};
  // Items that were requested again while a capture was already running; the
  // running capture may be stale, so they are captured once more afterwards.
  final Set<int> _snapshotRecapture = <int>{};
  final Map<int, int> _snapshotPaintRetries = <int, int>{};
  final Map<int, List<Completer<void>>> _snapshotWaiters =
      <int, List<Completer<void>>>{};
  int _snapshotGeneration = 0;
  bool _snapshotRefreshPending = false;
  Size? _viewportSize;
  bool _viewportRefreshScheduled = false;
  late Listenable _repaint;
  late double _anchor;

  // Pointer that currently steers the fold: the most recent finger down.
  int? _activePointer;
  // Latest raw (unfiltered) finger position, normalized. Kept even while no
  // turn is in flight so the first curl frame starts exactly under the finger.
  Offset _touchTarget = const Offset(_kDefaultTouchX, _kDefaultTouchY);
  bool _touchNeedsSnap = false;

  // The PageController also moves for programmatic animateToPage turns. A
  // single latch keeps one sound from firing on every animation frame.
  bool _turnStartNotified = false;

  @override
  void initState() {
    super.initState();
    _anchor = widget.controller.initialPage.toDouble();
    _repaint = Listenable.merge(<Listenable>[
      widget.controller,
      _touchPosition,
      _snapshotRevision,
    ]);
    widget.controller.addListener(_settleAnchor);
    widget.snapshotInvalidator?.addListener(_onSnapshotInvalidated);
    widget.snapshotController?._state = this;
    _scheduleSnapshot(_anchor.round());
  }

  @override
  void didUpdateWidget(ComicCurlPageView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_settleAnchor);
      widget.controller.addListener(_settleAnchor);
      _repaint = Listenable.merge(<Listenable>[
        widget.controller,
        _touchPosition,
        _snapshotRevision,
      ]);
      _anchor = _readPage(widget.controller);
      _turnStartNotified = false;
    }

    if (oldWidget.snapshotInvalidator != widget.snapshotInvalidator) {
      oldWidget.snapshotInvalidator?.removeListener(_onSnapshotInvalidated);
      widget.snapshotInvalidator?.addListener(_onSnapshotInvalidated);
    }
    if (oldWidget.snapshotController != widget.snapshotController) {
      if (oldWidget.snapshotController?._state == this) {
        oldWidget.snapshotController!._state = null;
      }
      widget.snapshotController?._state = this;
    }

    if (oldWidget.itemCount != widget.itemCount ||
        (oldWidget.enabled && !widget.enabled)) {
      _turnStartNotified = false;
      _clearSnapshots();
      if (widget.enabled && widget.itemCount > 0) {
        _scheduleSnapshot(_readPage(widget.controller).round());
      }
    }

    // A layout switch changes what a virtual PageView index represents. Do
    // not carry the old layout's settled index into the new layout's direction
    // test; the reader re-enables curl only after it has jumped to the matching
    // page in the new layout.
    if (!oldWidget.enabled && widget.enabled) {
      _anchor = _readPage(widget.controller);
      _turnStartNotified = false;
      _scheduleSnapshot(_anchor.round());
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_settleAnchor);
    widget.snapshotInvalidator?.removeListener(_onSnapshotInvalidated);
    if (widget.snapshotController?._state == this) {
      widget.snapshotController!._state = null;
    }
    _completeSnapshotWaiters(null);
    for (final ui.Image image in _snapshots.values) {
      image.dispose();
    }
    _snapshots.clear();
    _snapshotSizes.clear();
    _snapshotRevision.dispose();
    _touchPosition.dispose();
    super.dispose();
  }

  GlobalKey _snapshotKeyFor(int index) => _snapshotKeys.putIfAbsent(
    index,
    () => GlobalKey(debugLabel: 'comic-curl-page-$index'),
  );

  /// The stored snapshot of [index], but only if it was captured at [size].
  /// A texture from another viewport size would be mapped with the wrong
  /// scale, so it is treated as missing (the curl falls back to the live
  /// page) until a fresh capture lands.
  ui.Image? _snapshotFor(int index, Size size) {
    final ui.Image? image = _snapshots[index];
    if (image == null) return null;
    final Size? captured = _snapshotSizes[index];
    if (captured == null ||
        (captured.width - size.width).abs() > 0.5 ||
        (captured.height - size.height).abs() > 0.5) {
      return null;
    }
    return image;
  }

  void _disposeImageAfterFrame(ui.Image image) {
    WidgetsBinding.instance.addPostFrameCallback((_) => image.dispose());
  }

  void _completeSnapshotWaiters(int? index) {
    final List<int> keys = index == null
        ? _snapshotWaiters.keys.toList()
        : <int>[index];
    for (final int key in keys) {
      final List<Completer<void>>? waiters = _snapshotWaiters.remove(key);
      if (waiters == null) continue;
      for (final Completer<void> waiter in waiters) {
        if (!waiter.isCompleted) waiter.complete();
      }
    }
  }

  void _clearSnapshots() {
    // Invalidates captures that began against the previous layout.
    _snapshotGeneration++;
    _snapshotRefreshPending = false;
    _snapshotRecapture.clear();
    // Nobody should wait for a texture of a layout that no longer exists.
    _completeSnapshotWaiters(null);
    if (_snapshots.isEmpty) return;
    for (final ui.Image image in _snapshots.values) {
      _disposeImageAfterFrame(image);
    }
    _snapshots.clear();
    _snapshotSizes.clear();
    _snapshotRevision.value++;
  }

  void _pruneSnapshots(int center) {
    final List<int> staleImages = _snapshots.keys
        .where((int index) => (index - center).abs() > 1)
        .toList();
    for (final int index in staleImages) {
      final ui.Image? image = _snapshots.remove(index);
      _snapshotSizes.remove(index);
      if (image != null) _disposeImageAfterFrame(image);
    }
    final List<int> staleKeys = _snapshotKeys.keys
        .where((int index) => (index - center).abs() > 3)
        .toList();
    for (final int index in staleKeys) {
      _snapshotKeys.remove(index);
    }
    if (staleImages.isNotEmpty) _snapshotRevision.value++;
  }

  // The spread budget is larger than the single-page one, and up to three
  // snapshots can be retained at once. Keep the total bounded, evicting the
  // farthest neighbours first. The anchor page is never evicted: it is the
  // only snapshot a turn that starts now would use.
  void _enforceSnapshotBudget(int center) {
    double total = 0.0;
    for (final ui.Image image in _snapshots.values) {
      total += image.width * image.height.toDouble();
    }
    if (total <= _kSnapshotTotalPixelCap) return;

    final List<int> candidates = _snapshots.keys
        .where((int index) => index != center)
        .toList()
      ..sort(
        (int a, int b) => (b - center).abs().compareTo((a - center).abs()),
      );
    bool evicted = false;
    for (final int index in candidates) {
      if (total <= _kSnapshotTotalPixelCap) break;
      final ui.Image? image = _snapshots.remove(index);
      _snapshotSizes.remove(index);
      if (image == null) continue;
      total -= image.width * image.height.toDouble();
      _disposeImageAfterFrame(image);
      evicted = true;
    }
    if (evicted) _snapshotRevision.value++;
  }

  void _scheduleSnapshot(int index) {
    if (!widget.enabled || index < 0 || index >= widget.itemCount) return;
    if (!_snapshotScheduled.add(index)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _snapshotScheduled.remove(index);
      if (mounted) _captureSnapshot(index);
    });
  }

  // Capture close to the device's native pixel density, but cap total pixels
  // and the longest edge so high-density devices do not allocate enormous
  // temporary textures. The snapshot is temporary; the original page widget
  // and its source image remain untouched.
  //
  // Two-page spreads carry two pages of artwork, so their budget grows with
  // [aggregateLeafWidth] (the summed width of both leaves): the more of the
  // viewport width the artwork covers, the closer the budget gets to
  // [_kSpreadSnapshotMaxPixels] / DPR [_kSpreadSnapshotMaxDpr]. Single pages
  // (aggregateLeafWidth == 0) keep the original budget.
  double _snapshotPixelRatio(
    Size logicalSize, {
    double aggregateLeafWidth = 0.0,
  }) {
    if (logicalSize.isEmpty ||
        !logicalSize.width.isFinite ||
        !logicalSize.height.isFinite) {
      return 1.0;
    }
    final bool spread = aggregateLeafWidth > 0.0;
    final double deviceRatio =
        MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1.0;
    final double dpr = deviceRatio
        .clamp(1.0, spread ? _kSpreadSnapshotMaxDpr : _kSnapshotMaxDpr)
        .toDouble();

    final double coverage = spread
        ? _clamp(aggregateLeafWidth / logicalSize.width, 0.0, 1.0)
        : 0.0;
    final double maxPixels = spread
        ? _kSnapshotMaxPixels +
              (_kSpreadSnapshotMaxPixels - _kSnapshotMaxPixels) * coverage
        : _kSnapshotMaxPixels;
    final double maxDimension = spread
        ? _kSpreadSnapshotMaxDimension
        : _kSnapshotMaxDimension;

    final double longestSide = math
        .max(logicalSize.width, logicalSize.height)
        .toDouble();
    final double pixelCount = logicalSize.width * logicalSize.height;
    final double dimensionLimit = maxDimension / longestSide;
    final double pixelLimit = math.sqrt(maxPixels / pixelCount);
    return math
        .max(0.1, math.min(dpr, math.min(dimensionLimit, pixelLimit)))
        .toDouble();
  }

  double _aggregateLeafWidth(int index, Size logicalSize) {
    try {
      final ComicCurlLeaves? leaves = _leaves(index, logicalSize);
      if (leaves == null) return 0.0;
      final double total = leaves.left.width + leaves.right.width;
      return total.isFinite && total > 0.0 ? total : 0.0;
    } catch (error) {
      debugPrint('Comic page curl leaf lookup failed for item $index: $error');
      return 0.0;
    }
  }

  Future<void> _captureSnapshot(int index) async {
    if (!mounted || !widget.enabled || index < 0 || index >= widget.itemCount) {
      _completeSnapshotWaiters(index);
      return;
    }
    if (_snapshotCapturing.contains(index)) {
      // The capture that is running started before this request and may
      // already be stale. Run once more when it finishes.
      _snapshotRecapture.add(index);
      return;
    }
    final RenderObject? renderObject = _snapshotKeys[index]?.currentContext
        ?.findRenderObject();
    if (renderObject is! RenderRepaintBoundary ||
        !renderObject.attached ||
        !renderObject.hasSize ||
        renderObject.size.isEmpty) {
      _completeSnapshotWaiters(index);
      return;
    }

    // RenderRepaintBoundary.toImage asserts (debug builds) while the boundary
    // still has a paint pending, which happens when something marks it dirty
    // after the frame's paint phase. Retry on the next frame instead of
    // failing the capture.
    bool needsPaint = false;
    assert(() {
      needsPaint = renderObject.debugNeedsPaint;
      return true;
    }());
    if (needsPaint) {
      final int retries = (_snapshotPaintRetries[index] ?? 0) + 1;
      if (retries <= _kSnapshotPaintRetries) {
        _snapshotPaintRetries[index] = retries;
        _scheduleSnapshot(index);
      } else {
        _snapshotPaintRetries.remove(index);
        _completeSnapshotWaiters(index);
      }
      return;
    }
    _snapshotPaintRetries.remove(index);

    _snapshotCapturing.add(index);
    final int generation = _snapshotGeneration;
    try {
      final Size logicalSize = renderObject.size;
      final double pixelRatio = _snapshotPixelRatio(
        logicalSize,
        aggregateLeafWidth: _aggregateLeafWidth(index, logicalSize),
      );
      final ui.Image image = await renderObject.toImage(
        pixelRatio: pixelRatio,
      );
      if (!mounted ||
          !widget.enabled ||
          generation != _snapshotGeneration ||
          index < 0 ||
          index >= widget.itemCount) {
        image.dispose();
        return;
      }
      final ui.Image? previous = _snapshots[index];
      _snapshots[index] = image;
      _snapshotSizes[index] = logicalSize;
      if (previous != null) _disposeImageAfterFrame(previous);
      final int center = _anchor.round();
      _pruneSnapshots(center);
      _enforceSnapshotBudget(center);
      _snapshotRevision.value++;
    } catch (error, stackTrace) {
      debugPrint(
        'Comic page curl snapshot failed for item $index: $error\n$stackTrace',
      );
    } finally {
      _snapshotCapturing.remove(index);
      final bool again = _snapshotRecapture.remove(index);
      // If a layout switch invalidated this in-flight capture, or the page
      // changed while it ran, capture again against the current, fully-built
      // layout instead of leaving a stale gap. Waiters are released only by
      // the capture that is final for them.
      if (mounted &&
          widget.enabled &&
          index >= 0 &&
          index < widget.itemCount &&
          (again || generation != _snapshotGeneration)) {
        _scheduleSnapshot(index);
      } else {
        _completeSnapshotWaiters(index);
      }
    }
  }

  /// See [ComicCurlSnapshotController.refresh].
  Future<void> _refreshSnapshotNow(Duration timeout) {
    if (!mounted || !widget.enabled || widget.itemCount <= 0) {
      return Future<void>.value();
    }
    final int index = _anchor.round();
    if (index < 0 || index >= widget.itemCount) return Future<void>.value();
    final Completer<void> done = Completer<void>();
    _snapshotWaiters.putIfAbsent(index, () => <Completer<void>>[]).add(done);
    _scheduleSnapshot(index);
    return done.future.timeout(timeout, onTimeout: () {});
  }

  // The host says the settled page looks different now. Swapping the texture
  // while a turn is in flight would change the sheet under the finger, so
  // that is postponed until the page settles (see [_settleAnchor]).
  void _onSnapshotInvalidated() {
    if (!mounted || !widget.enabled) return;
    if (_isTurning()) {
      _snapshotRefreshPending = true;
      return;
    }
    _scheduleSnapshot(_anchor.round());
  }

  bool _isTurning() {
    final double page = _readPage(widget.controller);
    return (page - page.roundToDouble()).abs() > _kAnchorEps;
  }

  // Layout builders run during layout, where notifiers must not fire, so a
  // viewport change is handled after the frame.
  void _noteViewportSize(Size size) {
    if (!size.width.isFinite || !size.height.isFinite || size.isEmpty) return;
    final Size? previous = _viewportSize;
    _viewportSize = size;
    if (previous == null || previous == size || _viewportRefreshScheduled) {
      return;
    }
    _viewportRefreshScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _viewportRefreshScheduled = false;
      if (!mounted || !widget.enabled) return;
      _clearSnapshots();
      _scheduleSnapshot(_anchor.round());
    });
  }

  void _handlePointer(PointerEvent event, Size viewportSize) {
    if (!viewportSize.width.isFinite ||
        !viewportSize.height.isFinite ||
        viewportSize.width <= 0.0 ||
        viewportSize.height <= 0.0) {
      return;
    }

    Offset normalized() => Offset(
      _clamp(event.localPosition.dx / viewportSize.width, 0.0, 1.0),
      _clamp(event.localPosition.dy / viewportSize.height, 0.0, 1.0),
    );

    if (event is PointerDownEvent) {
      // The newest finger steers the fold; it always takes over, so a missed
      // pointer-up can never leave the layer deaf to later touches.
      _activePointer = event.pointer;
      // PointerEvent.localPosition is local to the Listener.
      final Offset target = normalized();
      _touchTarget = target;
      _touchNeedsSnap = false;
      _touchPosition.value = target;
      _scheduleSnapshot(_anchor.round());
      return;
    }

    if (event.pointer != _activePointer) return;

    if (event is PointerMoveEvent) {
      // Free-form tracking: both axes follow the finger. The raw position is
      // always remembered; the notifier (which repaints every curl frame) only
      // fires while a turn is in flight, so pans of a zoomed page do not churn
      // the curl layer.
      final Offset target = normalized();
      _touchTarget = target;
      if (!_isTurning()) {
        _touchNeedsSnap = true;
        return;
      }
      final Offset current = _touchPosition.value;
      if (_touchNeedsSnap) {
        // The turn just began: start under the finger, no catch-up lag.
        _touchNeedsSnap = false;
        _touchPosition.value = target;
        return;
      }
      final double dxPx = (target.dx - current.dx) * viewportSize.width;
      final double dyPx = (target.dy - current.dy) * viewportSize.height;
      final double distPx = math.sqrt(dxPx * dxPx + dyPx * dyPx);
      // Big or fast movement -> follow = 1 (instant). Tiny movement -> mild
      // smoothing so a resting finger does not make the fold shimmer.
      final double follow =
          _kTouchMinFollow +
              (1.0 - _kTouchMinFollow) * _smoothStep(0.0, _kTouchJitterPx, distPx);
      final Offset next = Offset(
        current.dx + (target.dx - current.dx) * follow,
        current.dy + (target.dy - current.dy) * follow,
      );
      if ((next - current).distanceSquared < 1e-12) return;
      _touchPosition.value = next;
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      // Land exactly where the finger lifted, so the release animation starts
      // from the true fold orientation instead of a filtered one.
      if (_isTurning() && _touchPosition.value != _touchTarget) {
        _touchPosition.value = _touchTarget;
      }
      _activePointer = null;
    }
  }

  bool _isBlocked() => widget.isInteractionBlocked?.call() ?? false;

  Rect? _paperRect(int index, Size viewport) =>
      widget.paperRectBuilder?.call(index, viewport);

  ComicCurlLeaves? _leaves(int index, Size viewport) =>
      widget.leavesBuilder?.call(index, viewport);

  Widget _buildItem(BuildContext context, int index) =>
      widget.itemBuilder(context, index);

  Widget _buildBackFaceItem(BuildContext context, int index) =>
      widget.backFaceBuilder?.call(context, index) ?? _buildItem(context, index);

  // Only a user drag or an animateToPage-driven turn counts as an actual
  // page-turn gesture. This excludes jumpToPage/layout corrections, which can
  // briefly update pixels without presenting a curl to the user.
  bool _isPagerActivelyScrolling() {
    if (!widget.controller.hasClients ||
        widget.controller.positions.length != 1) {
      return false;
    }
    return widget.controller.position.isScrollingNotifier.value;
  }

  // The anchor is the last SETTLED page. Update it from the scroll listener
  // only at the same tight threshold used to hand the curl back to PageView.
  void _settleAnchor() {
    final double page = _readPage(widget.controller);
    final double nearest = page.roundToDouble();

    // This listener sees both finger drags and animateToPage transitions.
    // Notify on the first non-zero movement away from the settled anchor,
    // before PageView's onPageChanged midpoint callback. Panel navigation does
    // not move PageController and therefore cannot reach this branch.
    if ((page - nearest).abs() >= _kAnchorEps) {
      if (widget.enabled &&
          _isPagerActivelyScrolling() &&
          !_turnStartNotified &&
          widget.itemCount > 1) {
        final int fromIndex = _anchor.round();
        final int toIndex = page > _anchor ? fromIndex + 1 : fromIndex - 1;
        if (toIndex >= 0 && toIndex < widget.itemCount) {
          _turnStartNotified = true;
          widget.onPageTurnStarted?.call(fromIndex, toIndex);
        }
      }
      return;
    }

    // A completed turn or a cancelled drag has returned to rest. Re-arm for
    // the next turn, including a drag that snapped back to the same page.
    _turnStartNotified = false;
    if (nearest != _anchor) {
      _anchor = nearest;
      _snapshotRefreshPending = false;
      _pruneSnapshots(nearest.toInt());
      _scheduleSnapshot(nearest.toInt());
    } else if (_snapshotRefreshPending) {
      // The host changed the page's look mid-turn; apply it now that the
      // sheet is at rest.
      _snapshotRefreshPending = false;
      _scheduleSnapshot(nearest.toInt());
    }
  }

  // True while the gesture/animation started from a lower page (page grows).
  // Stays stable even if a released drag springs back.
  bool _isForward(double page) => page >= _anchor;

  @override
  Widget build(BuildContext context) {
    return _CurlScope(
      controller: widget.controller,
      repaint: _repaint,
      touchPosition: _touchPosition,
      enabled: widget.enabled,
      paperColor: widget.paperColor,
      ghostBackFace: widget.ghostBackFace,
      ghostOpacity: widget.ghostOpacity,
      ghostPaperOpacity: widget.ghostPaperOpacity,
      radiusFraction: widget.radiusFraction,
      isBlocked: _isBlocked,
      isForward: _isForward,
      paperRect: _paperRect,
      leaves: _leaves,
      buildItem: _buildItem,
      buildBackFaceItem: _buildBackFaceItem,
      snapshot: _snapshotFor,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final Size touchSize = constraints.biggest;
          _noteViewportSize(touchSize);
          return Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (PointerEvent event) =>
                _handlePointer(event, touchSize),
            onPointerMove: (PointerEvent event) =>
                _handlePointer(event, touchSize),
            onPointerUp: (PointerEvent event) =>
                _handlePointer(event, touchSize),
            onPointerCancel: (PointerEvent event) =>
                _handlePointer(event, touchSize),
            child: PageView.builder(
              controller: widget.controller,
              physics: widget.physics,
              itemCount: widget.itemCount,
              onPageChanged: widget.onPageChanged,
              itemBuilder: (BuildContext context, int index) {
                // PageView builds its adjacent items ahead of a drag. Capture
                // those pages as they enter the cache so a reverse single-page
                // turn already has the previous page's texture before the
                // curl becomes visible (rather than briefly showing the
                // outgoing page while that texture is being captured).
                final GlobalKey snapshotKey = _snapshotKeyFor(index);
                _scheduleSnapshot(index);
                return ComicPageCurlTransition(
                  index: index,
                  child: RepaintBoundary(
                    key: snapshotKey,
                    child: widget.itemBuilder(context, index),
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

/// Wraps one page of a [ComicCurlPageView]. Used automatically by it.
class ComicPageCurlTransition extends StatelessWidget {
  const ComicPageCurlTransition({
    super.key,
    required this.index,
    required this.child,
  });

  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final _CurlScope? scope = context
        .dependOnInheritedWidgetOfExactType<_CurlScope>();
    if (scope == null || !scope.enabled) return child;

    return RawGestureDetector(
      behavior: HitTestBehavior.translucent,
      gestures: <Type, GestureRecognizerFactory>{
        _BusyDragBlocker:
            GestureRecognizerFactoryWithHandlers<_BusyDragBlocker>(
              () => _BusyDragBlocker(scope.isBlocked),
              (_BusyDragBlocker instance) {
                instance
                  ..isBlocked = scope.isBlocked
                  ..onUpdate = _ignoreDrag;
              },
            ),
      },
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final Size size = constraints.biggest;
          return AnimatedBuilder(
            animation: scope.repaint,
            child: child,
            builder: (BuildContext context, Widget? built) {
              return _buildFrame(context, scope, size, built!);
            },
          );
        },
      ),
    );
  }

  Widget _buildFrame(
    BuildContext context,
    _CurlScope scope,
    Size size,
    Widget page,
  ) {
    // The page subtree always sits at Transform > Stack > CustomPaint > ClipPath
    // > page, whatever the role, so it is never rebuilt from scratch when a
    // curl starts or ends. Extra layers live in sibling slots of the Stack.
    Widget frame({
      required double dx,
      CustomPainter? shadowPainter,
      CustomPainter? texturePainter,
      CustomPainter? shadePainter,
      CustomClipper<Path>? clipper,
      Widget? backLayer,
    }) {
      return Transform.translate(
        offset: Offset(dx, 0.0),
        child: Stack(
          fit: StackFit.passthrough,
          clipBehavior: Clip.none,
          children: <Widget>[
            CustomPaint(
              foregroundPainter: shadowPainter,
              child: ClipPath(
                clipper: clipper,
                clipBehavior: clipper == null ? Clip.none : Clip.antiAlias,
                child: page,
              ),
            ),
            // Textured front face. It replaces the flat widget rendering only
            // while a page snapshot is available and the sheet is curled.
            if (texturePainter != null)
              Positioned.fill(
                child: IgnorePointer(child: CustomPaint(painter: texturePainter)),
              ),
            // Back of the sheet (ghost / facing page).
            Positioned.fill(
              child: IgnorePointer(child: backLayer ?? const SizedBox.shrink()),
            ),
            // Roll shading + edge line, above the back layer.
            Positioned.fill(
              child: IgnorePointer(child: CustomPaint(painter: shadePainter)),
            ),
          ],
        ),
      );
    }

    if (!size.width.isFinite || !size.height.isFinite || size.isEmpty) {
      return frame(dx: 0.0);
    }

    // The turn in progress is between items `lo` and `lo + 1`.
    final double pos = _readPage(scope.controller);
    final int lo = pos.floor();
    final double f = pos - lo;
    if (f <= _kEdgeEps ||
        f >= 1.0 - _kEdgeEps ||
        (index != lo && index != lo + 1)) {
      return frame(dx: 0.0);
    }

    final bool forward = scope.isForward(pos);
    final Rect view = Offset.zero & size;

    // Book mode: both spreads are real two-page spreads.
    final ComicCurlLeaves? loLeaves = scope.leaves(lo, size);
    final ComicCurlLeaves? hiLeaves = scope.leaves(lo + 1, size);
    final bool book = loLeaves != null && hiLeaves != null;

    // Which item is the sheet (`top`) and which is revealed (`under`):
    //  * forward (any layout): `lo` peels away, `lo + 1` is revealed;
    //  * book, reverse: the left leaf of `lo + 1` peels toward `lo`;
    //  * single page, reverse: the forward curl played backwards. The sheet is
    //    the PREVIOUS page `lo` (rolled up past the left edge at f ~ 1 and
    //    unrolled as f falls); the settled page `lo + 1` is only ever the
    //    revealed layer. The old code made `lo + 1` the sheet at progress ~ 1,
    //    i.e. fully peeled, which exposed the previous page in one frame.
    final int topIndex = (forward || !book) ? lo : lo + 1;
    final bool isTop = index == topIndex;

    // `travel`: 0 = settled on the page the gesture started from, 1 = settled
    // on the destination page.
    final double travel = forward ? f : 1.0 - f;
    double progress;
    // 0..1, how complete a single-page curl is (drives fold straightening).
    double completion = 0.0;
    if (book) {
      // Spreads keep their original mapping: the leaf must land exactly on
      // the spine at the hand-over.
      progress = travel;
    } else {
      // Curl scope: the curl finishes after `_kCurlCompletionTravel` of the
      // travel and holds its completed state for the remainder.
      completion = _clamp(travel / _kCurlCompletionTravel, 0.0, 1.0);
      progress = forward ? completion : 1.0 - completion;
    }
    if (!progress.isFinite) return frame(dx: 0.0);

    Rect paper; // the sheet that peels
    Rect? underWindow; // only this part of the revealed item may show
    Rect? hingeWindow; // exact bounds of the stationary leaf at the spine
    Rect? versoRect; // natural rect of the facing page shown on the back
    int versoIndex = lo;
    if (book && forward) {
      paper = loLeaves.right;
      hingeWindow = loLeaves.left;
      underWindow = hiLeaves.right;
      versoRect = hiLeaves.left;
      versoIndex = lo + 1;
    } else if (book) {
      paper = hiLeaves.left;
      hingeWindow = hiLeaves.right;
      underWindow = loLeaves.left;
      versoRect = loLeaves.right;
      versoIndex = lo;
    } else {
      paper = scope.paperRect(topIndex, size) ?? view;
      // The incoming page may have a different aspect ratio from the outgoing
      // page. Keep its reveal clipped to its own fitted paper rectangle.
      // The revealed item is always the later page (`lo + 1`): it is what the
      // forward curl uncovers and what the backward curl is laid over.
      underWindow = scope.paperRect(lo + 1, size);
    }

    final double clampedProgress = _clamp(progress, 0.0, 1.0);
    final _CurlGeometry geometry = _CurlGeometry.compute(
      size: size,
      paper: paper,
      progress: clampedProgress,
      touchPosition: scope.touchPosition.value,
      radiusFraction: scope.radiusFraction,
      book: book,
      mirrored: book && !forward,
      // Keep the original reverse flag for book spreads. Whole-sheet turns
      // use the shared forward geometry in both directions.
      reverse: book && !forward,
      underWindow: underWindow,
      hingeWindow: hingeWindow,
      tiltScale: book
          ? 1.0
          : 1.0 - _smoothStep(_kStraightFoldStart, 1.0, completion),
    );


    // Blend the raster mesh into the live page at the start/end of a turn.
    // During this narrow hand-off, frontClip keeps the live image underneath
    // the fading texture, avoiding a one-frame texture/flat-page pop.
    final double edgeDistance = math.min(
      clampedProgress,
      1.0 - clampedProgress,
    );
    final double textureOpacity = _smoothStep(
      0.0,
      _kTextureHandoffWindow,
      edgeDistance,
    );

    // Shadows and highlights dissolve as the sheet lands on either side. The
    // curl layer is handed back to the settled page at f ~ 0 / f ~ 1; with the
    // envelope already at zero by then nothing visible changes at that frame.
    // The glint is a thinner effect than the shadow, so it fades out sooner.
    final double shadowOpacity = _edgeEnvelope(clampedProgress);
    final double highlightOpacity = shadowOpacity * shadowOpacity;

    // Cancel the PageView's own slide so both items sit on top of each other.
    final double dx = (pos - index) * size.width;
    final _CurlRole role = isTop ? _CurlRole.top : _CurlRole.under;
    // A whole-sheet reverse turn is visually the previous page peeling
    // across the viewport. Its front texture must therefore come from the
    // destination page (`lo`), not the outgoing page (`lo + 1`). The backface
    // below independently uses the same previous-page index with the existing
    // low-opacity ghost treatment. Spread turns keep their original leaf
    // snapshot mapping.
    final int textureIndex = !book && !forward ? lo : topIndex;
    final ui.Image? pageSnapshot =
        isTop ? scope.snapshot(textureIndex, size) : null;
    final bool useTexturedCurl = pageSnapshot != null && geometry.hasBack;

    return frame(
      dx: dx,
      shadowPainter: _CurlPainter(
        layer: _CurlLayer.shadow,
        role: role,
        geometry: geometry,
        shadowOpacity: shadowOpacity,
        highlightOpacity: highlightOpacity,
      ),
      texturePainter: useTexturedCurl
          ? _CurlTexturePainter(
              image: pageSnapshot,
              logicalSize: size,
              geometry: geometry,
              opacity: textureOpacity,
              // A spread is two independent leaves; map each one onto its
              // own texel window (see [_TextureWindow]).
              perLeafMapping: book,
            )
          : null,
      shadePainter: isTop
          ? _CurlPainter(
              layer: _CurlLayer.shade,
              role: role,
              geometry: geometry,
              shadowOpacity: shadowOpacity,
              highlightOpacity: highlightOpacity,
            )
          : null,
      clipper: _PathClipper(
        isTop
            ? (useTexturedCurl && textureOpacity >= 0.999
                  ? geometry.flatClip
                  : geometry.frontClip)
            : geometry.revealClip,
      ),
      backLayer: isTop
          ? _buildBackLayer(
              context: context,
              scope: scope,
              geometry: geometry,

              versoRect: versoRect,
              versoIndex: versoIndex,
            )
          : null,
    );
  }

  /// The visible back of the peeled sheet (roll + flap), clipped to the
  /// geometry's back-face polygon.
  Widget? _buildBackLayer({
    required BuildContext context,
    required _CurlScope scope,
    required _CurlGeometry geometry,
    required Rect? versoRect,
    required int versoIndex,
  }) {
    if (!geometry.hasBack) return null;

    final List<Widget> layers = <Widget>[];
    if (versoRect != null) {
      // Book: the facing page of the adjacent spread, upright. Content at its
      // natural position N is drawn at F(M(N)): M mirrors about the spine, F
      // about the fold line. At progress 1 the fold IS the spine, F*M = I, so
      // the page lands exactly where the next spread draws it.
      layers
        ..add(ColoredBox(color: scope.paperColor))
        ..add(
          Transform(
            transform: geometry.flapMirror.multiplied(geometry.hingeMirror),
            child: ClipRect(
              clipper: _RectClipper(versoRect),
              child: scope.buildBackFaceItem(context, versoIndex),
            ),
          ),
        );
    } else if (scope.ghostBackFace) {
      // Whole sheet: the same page seen through the paper = the page mirrored
      // about the fold line, inverted, low opacity.
      layers
        ..add(
          ColoredBox(
            color: scope.paperColor.withOpacity(scope.ghostPaperOpacity),
          ),
        )
        ..add(
          ColorFiltered(
            colorFilter: ColorFilter.matrix(_ghostMatrix(scope.ghostOpacity)),
            child: Transform(
              transform: geometry.flapMirror,
              child: scope.buildBackFaceItem(context, versoIndex),
            ),
          ),
        );
    } else {
      layers.add(ColoredBox(color: scope.paperColor));
    }

    return ClipPath(
      clipper: _PathClipper(geometry.backFace),
      clipBehavior: Clip.antiAlias,
      child: ExcludeSemantics(
        child: Stack(
          fit: StackFit.expand,
          clipBehavior: Clip.none,
          children: layers,
        ),
      ),
    );
  }
}

/// RGB inverted, alpha scaled (values are 0..255 translations).
List<double> _ghostMatrix(double opacity) => <double>[
  1,
  0,
  0,
  0,
  0,
  0,
  1,
  0,
  0,
  0,
  0,
  0,
  1,
  0,
  0,
  0,
  0,
  0,
  _clamp(opacity, 0.0, 1.0),
  0,
];

/// Reflection about the line through [point] with unit normal [unitNormal].
Matrix4 _reflection(Offset point, Offset unitNormal) {
  final double nx = unitNormal.dx;
  final double ny = unitNormal.dy;
  final double k = 2.0 * (point.dx * nx + point.dy * ny);
  final Matrix4 m = Matrix4.identity();
  m.setEntry(0, 0, 1.0 - 2.0 * nx * nx);
  m.setEntry(0, 1, -2.0 * nx * ny);
  m.setEntry(1, 0, -2.0 * nx * ny);
  m.setEntry(1, 1, 1.0 - 2.0 * ny * ny);
  m.setEntry(0, 3, k * nx);
  m.setEntry(1, 3, k * ny);
  return m;
}

// ---------------------------------------------------------------------------
// Scope (shared state for the pages of one ComicCurlPageView)
// ---------------------------------------------------------------------------

enum _CurlRole { top, under }

enum _CurlLayer { shadow, shade }

class _CurlScope extends InheritedWidget {
  const _CurlScope({
    required this.controller,
    required this.repaint,
    required this.touchPosition,
    required this.enabled,
    required this.paperColor,
    required this.ghostBackFace,
    required this.ghostOpacity,
    required this.ghostPaperOpacity,
    required this.radiusFraction,
    required this.isBlocked,
    required this.isForward,
    required this.paperRect,
    required this.leaves,
    required this.buildItem,
    required this.buildBackFaceItem,
    required this.snapshot,
    required super.child,
  });

  final PageController controller;
  final Listenable repaint;
  final ValueListenable<Offset> touchPosition;
  final bool enabled;
  final Color paperColor;
  final bool ghostBackFace;
  final double ghostOpacity;
  final double ghostPaperOpacity;
  final double radiusFraction;
  final bool Function() isBlocked;
  final bool Function(double page) isForward;
  final Rect? Function(int index, Size viewport) paperRect;
  final ComicCurlLeaves? Function(int index, Size viewport) leaves;
  final Widget Function(BuildContext context, int index) buildItem;
  final Widget Function(BuildContext context, int index) buildBackFaceItem;
  final ui.Image? Function(int index, Size size) snapshot;

  @override
  bool updateShouldNotify(_CurlScope old) {
    return controller != old.controller ||
        repaint != old.repaint ||
        enabled != old.enabled ||
        paperColor != old.paperColor ||
        ghostBackFace != old.ghostBackFace ||
        ghostOpacity != old.ghostOpacity ||
        ghostPaperOpacity != old.ghostPaperOpacity ||
        buildItem != old.buildItem ||
        buildBackFaceItem != old.buildBackFaceItem ||
        snapshot != old.snapshot ||
        radiusFraction != old.radiusFraction;
  }
}

/// Current (clamped) page value, safe to call while the PageView is laying out
/// (PageController.page asserts before content dimensions are known).
double _readPage(PageController c) {
  final double fallback = c.initialPage.toDouble();
  if (c.positions.length != 1) return fallback;
  final ScrollPosition pos = c.position;
  if (!pos.hasPixels ||
      !pos.hasViewportDimension ||
      pos.viewportDimension <= 0.0) {
    return fallback;
  }
  double pixels = pos.pixels;
  if (pos.hasContentDimensions) {
    pixels = _clamp(pixels, pos.minScrollExtent, pos.maxScrollExtent);
  }
  return pixels / (pos.viewportDimension * c.viewportFraction);
}

// ---------------------------------------------------------------------------
// Drag gate: swallows horizontal drags that begin while the screen is busy
// ---------------------------------------------------------------------------

void _ignoreDrag(DragUpdateDetails details) {}

/// Only takes part in the gesture arena when [isBlocked] is true at pointer
/// down. It sits below the PageView's Scrollable, so on a tie it wins the
/// arena and the PageView never starts dragging. Taps are not affected.
class _BusyDragBlocker extends HorizontalDragGestureRecognizer {
  _BusyDragBlocker(this.isBlocked);

  bool Function() isBlocked;

  @override
  bool isPointerAllowed(PointerEvent event) {
    return isBlocked() && super.isPointerAllowed(event as PointerDownEvent);
  }
}

// ---------------------------------------------------------------------------
// Geometry
// ---------------------------------------------------------------------------
//
// Coordinates: (s, t) where s runs along `normal` (from the fixed side of the
// sheet towards the side that gets peeled) and t along `axis` (the fold line).
// A flat fold sits at s = fold. The part of the sheet beyond it wraps around a
// cylinder of radius r, goes over the top and comes back flat as the flap:
//   s in [fold, fold + pi r/2]  lower arc  (hidden under the upper arc)
//   s in [fold + pi r/2, fold + pi r]  upper arc, screen s' = fold + r sin(u/r)
//   s >= fold + pi r  flat flap, screen s' = 2 fold + pi r - s
// i.e. the flap is the sheet reflected about the line s = fold + pi r / 2.
//
// All of this is computed for a sheet that peels from the RIGHT towards the
// left ("canonical space"). A left-hinged page that peels left -> right
// (reverse book turn) is computed mirrored (x -> width - x) and every output
// is mapped back to screen space.
//
// Book mode differs from the whole-sheet curl in three ways:
//   * the fold stops at the sheet's hinge edge instead of leaving the screen,
//   * roll radius and fold tilt taper to 0 so the leaf lands flat on the spine,
//   * the hinge-side page is never clipped and the revealed item is limited to
//     the facing page's own rect.

class _CurlGeometry {
  _CurlGeometry._({
    required this.frontClip,
    required this.flatClip,
    required this.revealClip,
    required this.backFace,
    required this.hasBack,
    required this.sheet,
    required this.shadowArea,
    required this.fold,
    required this.radius,
    required this.normal,
    required this.axis,
    required this.origin,
    required this.mirrored,
    required this.width,
    required this.hingeX,
  });

  final Path
  frontClip; // where the peeled page itself is still visible (screen)
  final Path flatClip; // uncurled portion left live under the texture mesh
  final Path revealClip; // where the page underneath shows through (screen)
  final Path backFace; // roll + flap (back of the paper) (screen)
  final bool hasBack;
  final Rect sheet; // screen
  final Rect shadowArea; // where the flap may cast its shadow (screen)
  final double fold; // canonical
  final double radius; // canonical
  final Offset normal; // canonical
  final Offset axis; // canonical
  final Offset origin; // canonical
  final bool mirrored;
  final double width;
  final double hingeX; // screen x of the spine (book mode only)

  /// Canonical (s, t) -> canonical point.
  Offset at(double s, double t) => Offset(
    origin.dx + normal.dx * s + axis.dx * t,
    origin.dy + normal.dy * s + axis.dy * t,
  );

  /// Canonical point -> screen point.
  Offset toScreen(Offset p) => mirrored ? Offset(width - p.dx, p.dy) : p;

  /// Signed distance of an original (screen-space) point along the curl normal.
  double sourceS(Offset screenPoint) {
    final Offset canonical = mirrored
        ? Offset(width - screenPoint.dx, screenPoint.dy)
        : screenPoint;
    return (canonical.dx - origin.dx) * normal.dx +
        (canonical.dy - origin.dy) * normal.dy;
  }

  /// Maps a point on the front of the sheet onto the projected cylinder.
  /// Points before the fold remain flat; points after it are progressively
  /// compressed toward the cylinder's silhouette.
  Offset projectFrontPoint(Offset screenPoint) {
    final Offset canonical = mirrored
        ? Offset(width - screenPoint.dx, screenPoint.dy)
        : screenPoint;
    final double dx = canonical.dx - origin.dx;
    final double dy = canonical.dy - origin.dy;
    final double s = dx * normal.dx + dy * normal.dy;
    final double t = dx * axis.dx + dy * axis.dy;
    final double u = s - fold;
    final double projectedS = u <= 0.0
        ? s
        : fold + radius * math.sin(u / radius);
    return toScreen(at(projectedS, t));
  }

  /// Source-side boundary where the front of the sheet meets the back face.
  double get frontTextureLimit => fold + math.pi * radius / 2.0;

  /// Reflection about the fold line of the flat flap (screen space). A page
  /// drawn through it is what the flap shows "through the paper".
  Matrix4 get flapMirror {
    final double sCenter = fold + math.pi * radius / 2.0;
    final Offset point = toScreen(at(sCenter, 0.0));
    final Offset n = mirrored ? Offset(-normal.dx, normal.dy) : normal;
    return _reflection(point, n);
  }

  /// Reflection about the spine (screen space, book mode).
  Matrix4 get hingeMirror =>
      _reflection(Offset(hingeX, 0.0), const Offset(1.0, 0.0));

  factory _CurlGeometry.compute({
    required Size size,
    required Rect paper,
    required double progress,
    required Offset touchPosition,
    required double radiusFraction,
    bool reverse = false,
    bool book = false,
    bool mirrored = false,
    Rect? underWindow,
    Rect? hingeWindow,
    double tiltScale = 1.0,
  }) {
    final double width = size.width;
    Rect canon(Rect r) => mirrored
        ? Rect.fromLTRB(width - r.right, r.top, width - r.left, r.bottom)
        : r;
    Offset canonPoint(Offset p) =>
        mirrored ? Offset(width - p.dx, p.dy) : p;

    final Rect view = Offset.zero & size;
    Rect sheet = canon(paper).intersect(view);
    if (sheet.isEmpty) sheet = view;

    // --- Peel anchor and fold orientation ------------------------------------
    //
    // Everything below is canonical: the sheet peels from its RIGHT edge
    // towards the left. A single-page BACKWARD turn is the same geometry
    // mirrored, so the paper's LEFT edge (screen) is the canonical right edge.
    // That edge is the anchor the fold peels from, and the fold travels from
    // the paper's left edge outward to its right edge.
    final bool leftEdgeReverse = !book && mirrored;
    final bool rightEdgeReverse = !book && reverse;

    final Offset screenTouch = Offset(
      _clamp(touchPosition.dx, 0.0, 1.0) * width,
      _clamp(touchPosition.dy, 0.0, 1.0) * size.height,
    );

    // Vertical focus: the finger's height, kept inside the sheet. Used for the
    // origin and for the pivot's follow target. (The raw, unclamped touch still
    // steers the tilt below, so a finger leaving the paper keeps steering.)
    final double focusY = _clamp(screenTouch.dy, sheet.top, sheet.bottom);


    final Offset canonicalTouch;
    final Offset origin;
    if (leftEdgeReverse) {
      final Rect paperOnScreen = canon(sheet);
      final double grab = _clamp(
        screenTouch.dx - paperOnScreen.left,
        0.0,
        paperOnScreen.width,
      );

      canonicalTouch = Offset(sheet.right - grab, screenTouch.dy);
      origin = Offset(sheet.right, focusY);
    } else if (rightEdgeReverse) {
      // Single-page reverse: keep the curl anchored to the RIGHT edge.
      // The finger steers the fold, but cannot move its anchor to the left edge.
      canonicalTouch = screenTouch;
      origin = Offset(sheet.right, focusY);
    } else {
      canonicalTouch = canonPoint(screenTouch);
      origin = Offset(
        _clamp(canonicalTouch.dx, sheet.left, sheet.right),
        focusY,
      );
    }

    // Fold orientation = angle of the pull vector from the midpoint of the
    // opposing (hinge-side) edge to the finger. A finger level with the pivot
    // folds straight; a finger in a corner folds along the diagonal that
    // corner pulls; an upper-to-lower diagonal drag sweeps through every angle
    // in between. The touch is NOT clamped to the sheet, so a finger leaving
    // the paper keeps steering. The run gets a hypot floor so a grab right
    // beside the pivot cannot flip the fold to horizontal, and the angle is
    // soft limited (asymptotic, no hard stop) to keep extreme grabs sane.

    final bool reverseSinglePage = reverse && !book;

    final double pivotY =
        sheet.center.dy + (focusY - sheet.center.dy) * _kPivotFollow;
    final Offset pivot = Offset(
      reverseSinglePage ? sheet.right : sheet.left,
      pivotY,
    );

    final Offset rawPull = reverseSinglePage
        ? pivot - canonicalTouch
        : canonicalTouch - pivot;
    final Offset pull = Offset(rawPull.dx, rawPull.dy * _kTiltRiseGain);

    final double runFloor = math.max(
      1.0,
      sheet.width * _kTiltRunFloorFraction,
    );

    final double run = math.sqrt(
      pull.dx * pull.dx + runFloor * runFloor,
    );

    double tilt = _softLimit(
      math.atan2(pull.dy, run),
      _kSoftTiltLimit,
    );

// Book leaves taper to a flat landing on the spine.
    if (book) {
      tilt *= 1.0 - progress * progress;
    } else {
      tilt *= _clamp(tiltScale, 0.0, 1.0);
    }

    final double sinT = math.sin(tilt);
    final double cosT = math.cos(tilt);

    final Offset normal = reverseSinglePage
        ? Offset(-cosT, sinT)
        : Offset(cosT, sinT);

    final Offset axis = reverseSinglePage
        ? Offset(sinT, cosT)
        : Offset(sinT, -cosT);


    double sOf(Offset p) =>
        (p.dx - origin.dx) * normal.dx + (p.dy - origin.dy) * normal.dy;
    Offset at(double s, double t) => Offset(
      origin.dx + normal.dx * s + axis.dx * t,
      origin.dy + normal.dy * s + axis.dy * t,
    );

    final List<Offset> viewPoly = <Offset>[
      view.topLeft,
      view.topRight,
      view.bottomRight,
      view.bottomLeft,
    ];
    final List<Offset> sheetPoly = <Offset>[
      sheet.topLeft,
      sheet.topRight,
      sheet.bottomRight,
      sheet.bottomLeft,
    ];

    double viewMinS = double.infinity;
    for (final Offset p in viewPoly) {
      viewMinS = math.min(viewMinS, sOf(p));
    }
    double sheetMinS = double.infinity;
    double sheetMaxS = -double.infinity;
    for (final Offset p in sheetPoly) {
      sheetMinS = math.min(sheetMinS, sOf(p));
      sheetMaxS = math.max(sheetMaxS, sOf(p));
    }

    // Fold travels from the sheet's far corner/edge to just past the near edge
    // of the viewport (whole sheet) or to the hinge edge of the sheet (book),
    // so progress == 1 leaves nothing peeled / a flat leaf on the other page.
    final double maxRadius = _clamp(
      view.shortestSide * radiusFraction,
      10.0,
      96.0,
    );
    final double foldStart = sheetMaxS;
    final double foldEnd = book ? sheetMinS : viewMinS - maxRadius;
    final double fold = foldStart + (foldEnd - foldStart) * progress;
    final double rawRadius = math.min(maxRadius, (sheetMaxS - fold) / math.pi);
    final bool hasBack = rawRadius > 0.5;
    final double radius = (book && hasBack)
        ? math.max(0.25, math.min(rawRadius, fold - sheetMinS))
        : rawRadius;

    // The page itself stays visible up to the roll's silhouette; the roll and
    // flap are painted over it. Where the sheet is only partly lifted (near its
    // top/bottom edge on a slanted fold) the page shows through instead of a gap.
    Path frontClip = _polygonPath(
      _clipBySide(viewPoly, sOf, fold + radius, keepBelow: true),
    );
    Path revealClip = _polygonPath(
      _clipBySide(viewPoly, sOf, fold + radius, keepBelow: false),
    );
    Path flatClip = _polygonPath(
      _clipBySide(viewPoly, sOf, fold, keepBelow: true),
    );

    if (!book) {
      // Whole-sheet/single-page turns must stay anchored to the actual paper
      // rectangle. Clipping only to the viewport lets the revealed layer leak
      // into letterboxed margins and makes the trailing edge look ragged.
      final Path paperBounds = Path()..addRect(sheet.inflate(0.5));
      frontClip = Path.combine(
        ui.PathOperation.intersect,
        frontClip,
        paperBounds,
      );
      flatClip = Path.combine(
        ui.PathOperation.intersect,
        flatClip,
        paperBounds,
      );

      // If supplied, use the incoming page's own fitted rect for the reveal;
      // otherwise retain viewport behavior for callers without rect metadata.
      if (underWindow != null) {
        revealClip = Path.combine(
          ui.PathOperation.intersect,
          revealClip,
          Path()..addRect(canon(underWindow)),
        );
      }
    }

    if (book) {
      // Restrict the moving front sheet to its exact paper bounds. The old
      // viewport-wide clip could leave antialiased pixels beyond the fitted
      // leaf at the moment the destination spread became visible.
      final Path leafBounds = Path()..addRect(sheet);
      frontClip = Path.combine(
        ui.PathOperation.intersect,
        frontClip,
        leafBounds,
      );
      flatClip = Path.combine(
        ui.PathOperation.intersect,
        flatClip,
        leafBounds,
      );

      // Preserve the stationary hinge-side leaf using its measured rect. This
      // also handles virtual halves of a wide page without extending the clip
      // into letterboxed margins.
      final Rect? hinge = hingeWindow == null
          ? null
          : canon(hingeWindow).intersect(view);
      final Path hingeBounds = hinge != null && !hinge.isEmpty
          ? (Path()..addRect(hinge))
          : (Path()
            ..addRect(Rect.fromLTRB(0.0, 0.0, sheet.left, size.height)));
      frontClip = Path.combine(
        ui.PathOperation.union,
        frontClip,
        hingeBounds,
      );
      flatClip = Path.combine(
        ui.PathOperation.union,
        flatClip,
        hingeBounds,
      );

      if (underWindow != null) {
        revealClip = Path.combine(
          ui.PathOperation.intersect,
          revealClip,
          Path()..addRect(canon(underWindow)),
        );
      }
    }

    final Path backFace = Path();
    if (hasBack) {
      final double piR = math.pi * radius;
      final double sTop = fold + piR / 2.0;
      final double sFlat = fold + piR;
      final double sEnd = sheetMaxS - 1e-4;

      // Lateral extent of the sheet along the fold line at a given s.
      List<double>? interval(double s) {
        final double bx = origin.dx + normal.dx * s;
        final double by = origin.dy + normal.dy * s;
        double lo = -double.infinity;
        double hi = double.infinity;
        if (axis.dx.abs() < 1e-9) {
          if (bx < sheet.left || bx > sheet.right) return null;
        } else {
          final double t1 = (sheet.left - bx) / axis.dx;
          final double t2 = (sheet.right - bx) / axis.dx;
          lo = math.max(lo, math.min(t1, t2));
          hi = math.min(hi, math.max(t1, t2));
        }
        if (axis.dy.abs() < 1e-9) {
          if (by < sheet.top || by > sheet.bottom) return null;
        } else {
          final double t1 = (sheet.top - by) / axis.dy;
          final double t2 = (sheet.bottom - by) / axis.dy;
          lo = math.max(lo, math.min(t1, t2));
          hi = math.min(hi, math.max(t1, t2));
        }
        return lo > hi ? null : <double>[lo, hi];
      }

      double mapS(double s) {
        final double u = s - fold;
        if (u <= piR) return fold + radius * math.sin(u / radius);
        return 2.0 * fold + piR - s;
      }

      final List<double> samples = <double>[];
      // Sample the visible half-cylinder densely enough that the silhouette
      // remains smooth on high-density displays and during fast page drags.
      // These are angular samples (uniform in s/r), not screen-space samples.
      const int rollSteps = 40;
      final double rollEnd = math.min(sFlat, sEnd);
      for (int i = 0; i <= rollSteps; i++) {
        final double t = i / rollSteps;
        samples.add(sTop + (rollEnd - sTop) * t);
      }
      // Sheet corners are where the lateral limits change slope.
      for (final Offset c in sheetPoly) {
        final double s = sOf(c);
        if (s > sTop && s < sEnd) samples.add(s);
      }
      if (sEnd > sFlat) {
        samples
          ..add(sFlat)
          ..add(sEnd);
      }
      samples.sort();

      final List<Offset> left = <Offset>[];
      final List<Offset> right = <Offset>[];
      double previousS = double.negativeInfinity;
      for (final double s in samples) {
        // Corner and arc-end samples can coincide. Skip duplicates to avoid
        // zero-length polygon edges and tiny shading seams.
        if ((s - previousS).abs() < 1e-5) continue;
        previousS = s;
        final List<double>? iv = interval(s);
        if (iv == null) continue;
        final double sp = mapS(s);
        left.add(at(sp, iv[0]));
        right.add(at(sp, iv[1]));
      }
      if (left.length >= 2) {
        backFace.addPolygon(<Offset>[...left, ...right.reversed], true);
      }
    }

    // Canonical -> screen.
    final Matrix4 flip = Matrix4.identity()
      ..setEntry(0, 0, -1.0)
      ..setEntry(0, 3, width);
    Path toScreenPath(Path p) => mirrored ? p.transform(flip.storage) : p;

    final Rect screenSheet = canon(sheet);

    return _CurlGeometry._(
      frontClip: toScreenPath(frontClip),
      flatClip: toScreenPath(flatClip),
      revealClip: toScreenPath(revealClip),
      backFace: toScreenPath(backFace),
      hasBack: hasBack && !backFace.getBounds().isEmpty,
      sheet: screenSheet,
      shadowArea: book ? view : screenSheet,
      fold: fold,
      radius: radius,
      normal: normal,
      axis: axis,
      origin: origin,
      mirrored: mirrored,
      width: width,
      hingeX: mirrored ? screenSheet.right : screenSheet.left,
    );
  }

  /// Cylindrical diffuse shading across the visible roll. `u` runs from the
  /// flap side (0) to the silhouette (1). The changing surface normal creates
  /// a rounded light-to-shadow transition rather than a flat dark stripe.
  ui.Shader backShadeShader({double opacity = 1.0}) {
    const int steps = 32;
    final List<Color> colors = <Color>[];
    final List<double> stops = <double>[];

    for (int i = 0; i <= steps; i++) {
      final double u = i / steps;
      final double nz = math.sqrt(math.max(0.0, 1.0 - u * u));

      // Directional diffuse + ambient fill. The slight negative u term puts
      // the far side of the cylinder into shadow.
      final double diffuse = _clamp(0.18 + 0.92 * nz - 0.24 * u, 0.0, 1.0);
      final double ambient = 0.38;
      final double lit = ambient + (1.0 - ambient) * diffuse;

      // A restrained broad bounce highlight keeps the paper from looking
      // metallic while preserving a readable cylindrical gradient.
      final double bounce = (u - 0.30) / 0.19;
      final double brightness = _clamp(
        lit + 0.045 * math.exp(-bounce * bounce),
        0.0,
        1.0,
      );

      colors.add(
        Color.fromRGBO(0, 0, 0, _clamp((1.0 - brightness) * opacity, 0.0, 1.0)),
      );
      stops.add(u);
    }

    return ui.Gradient.linear(
      toScreen(at(fold, 0.0)),
      toScreen(at(fold + radius, 0.0)),
      colors,
      stops,
    );
  }

  /// Narrow, soft specular glint running along the cylindrical spine. Kept
  /// separate from the black diffuse shader so it can use screen blending.
  ui.Shader rollHighlightShader({double opacity = 1.0}) {
    const List<double> stops = <double>[0.0, 0.24, 0.38, 0.48, 0.60, 0.78, 1.0];
    const List<double> alphas = <double>[
      0.00,
      0.015,
      0.075,
      0.13,
      0.055,
      0.012,
      0.00,
    ];
    final double k = _clamp(opacity, 0.0, 1.0);
    final List<Color> colors = <Color>[
      for (final double a in alphas) Color.fromRGBO(255, 255, 255, a * k),
    ];

    return ui.Gradient.linear(
      toScreen(at(fold, 0.0)),
      toScreen(at(fold + radius, 0.0)),
      colors,
      stops,
    );
  }

  /// Soft shadow the lifted sheet throws on the page underneath.
  ui.Shader underShadowShader({double opacity = 1.0}) {
    final double span = 40.0 + radius * 1.6;
    final double k = _clamp(opacity, 0.0, 1.0);
    return ui.Gradient.linear(
      toScreen(at(fold + radius, 0.0)),
      toScreen(at(fold + radius + span, 0.0)),
      <Color>[
        Color.fromARGB((0x70 * k).round(), 0, 0, 0),
        Color.fromARGB((0x22 * k).round(), 0, 0, 0),
        const Color(0x00000000),
      ],
      const <double>[0.0, 0.4, 1.0],
    );
  }

  Offset get shadowShift => mirrored
      ? Offset(normal.dx * 5.0, -normal.dy * 5.0)
      : Offset(-normal.dx * 5.0, -normal.dy * 5.0);
}

Path _polygonPath(List<Offset> poly) {
  final Path path = Path();
  if (poly.length >= 3) path.addPolygon(poly, true);
  return path;
}

/// Sutherland-Hodgman clip of a convex polygon against {s <= limit} (keepBelow)
/// or {s >= limit}.
List<Offset> _clipBySide(
  List<Offset> poly,
  double Function(Offset) sOf,
  double limit, {
  required bool keepBelow,
}) {
  final List<Offset> out = <Offset>[];
  for (int i = 0; i < poly.length; i++) {
    final Offset cur = poly[i];
    final Offset next = poly[(i + 1) % poly.length];
    final double dc = keepBelow ? sOf(cur) - limit : limit - sOf(cur);
    final double dn = keepBelow ? sOf(next) - limit : limit - sOf(next);
    if (dc <= 0.0) out.add(cur);
    if ((dc < 0.0 && dn > 0.0) || (dc > 0.0 && dn < 0.0)) {
      final double k = dc / (dc - dn);
      out.add(
        Offset(
          cur.dx + (next.dx - cur.dx) * k,
          cur.dy + (next.dy - cur.dy) * k,
        ),
      );
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// Textured front-sheet mesh
// ---------------------------------------------------------------------------

class _CurlMeshPoint {
  const _CurlMeshPoint(this.source, this.s);

  final Offset source;
  final double s;
}

/// Maps logical source coordinates onto texels of a page snapshot.
///
/// [_TextureWindow.global] uses one scale for the whole image (single page).
/// [_TextureWindow.leaf] gives ONE leaf of a two-page spread its own window:
/// the leaf's edges are rounded to whole texels and the scale is derived from
/// that window alone. Both leaves round the shared spine to the same texel
/// line, so they neither overlap nor leave a gap, while each leaf's first and
/// last texel column is covered fully (no half-texel bleed that reads as a
/// blurry edge). Interior mesh vertices are then snapped to whole texels
/// relative to the leaf, so a flat leaf is sampled 1:1 and stays crisp.
class _TextureWindow {
  const _TextureWindow._({
    required this.originX,
    required this.originY,
    required this.texelLeft,
    required this.texelTop,
    required this.scaleX,
    required this.scaleY,
  });

  factory _TextureWindow.global(ui.Image image, Size logicalSize) {
    return _TextureWindow._(
      originX: 0.0,
      originY: 0.0,
      texelLeft: 0.0,
      texelTop: 0.0,
      scaleX: image.width / logicalSize.width,
      scaleY: image.height / logicalSize.height,
    );
  }

  factory _TextureWindow.leaf(ui.Image image, Size logicalSize, Rect leaf) {
    final double sx = image.width / logicalSize.width;
    final double sy = image.height / logicalSize.height;
    final double left = (leaf.left * sx).roundToDouble();
    final double top = (leaf.top * sy).roundToDouble();
    final double right = math.min(
      (leaf.right * sx).roundToDouble(),
      image.width.toDouble(),
    );
    final double bottom = math.min(
      (leaf.bottom * sy).roundToDouble(),
      image.height.toDouble(),
    );
    if (leaf.width <= 0.0 ||
        leaf.height <= 0.0 ||
        right - left < 1.0 ||
        bottom - top < 1.0) {
      return _TextureWindow.global(image, logicalSize);
    }
    return _TextureWindow._(
      originX: leaf.left,
      originY: leaf.top,
      texelLeft: left,
      texelTop: top,
      scaleX: (right - left) / leaf.width,
      scaleY: (bottom - top) / leaf.height,
    );
  }

  final double originX; // logical x of the window's left edge
  final double originY;
  final double texelLeft; // texel x that edge maps to (a whole texel)
  final double texelTop;
  final double scaleX; // texels per logical pixel, for THIS window
  final double scaleY;

  double u(double x) => texelLeft + (x - originX) * scaleX;
  double v(double y) => texelTop + (y - originY) * scaleY;

  double snapX(double x) =>
      originX + ((x - originX) * scaleX).roundToDouble() / scaleX;
  double snapY(double y) =>
      originY + ((y - originY) * scaleY).roundToDouble() / scaleY;
}

/// Draws a raster snapshot of the live page through a cylindrical mesh. The
/// live widget remains mounted underneath it (so its state and controllers are
/// preserved), but is clipped to the stationary portion while this painter
/// supplies the visibly compressed/curved front surface.
class _CurlTexturePainter extends CustomPainter {
  const _CurlTexturePainter({
    required this.image,
    required this.logicalSize,
    required this.geometry,
    required this.opacity,
    this.perLeafMapping = false,
  });

  final ui.Image image;
  final Size logicalSize;
  final _CurlGeometry geometry;
  final double opacity;

  /// Double spreads: give the leaf being drawn its own texel window instead of
  /// one scale for the whole snapshot (see [_TextureWindow]).
  final bool perLeafMapping;

  static const int _columns = 42;
  static const int _rows = 42;

  List<_CurlMeshPoint> _clipTriangle(List<_CurlMeshPoint> triangle) {
    final List<_CurlMeshPoint> output = <_CurlMeshPoint>[];
    for (int i = 0; i < triangle.length; i++) {
      final _CurlMeshPoint current = triangle[i];
      final _CurlMeshPoint next = triangle[(i + 1) % triangle.length];
      final bool currentInside = current.s <= geometry.frontTextureLimit;
      final bool nextInside = next.s <= geometry.frontTextureLimit;

      if (currentInside) output.add(current);
      if (currentInside != nextInside) {
        final double denominator = next.s - current.s;
        if (denominator.abs() > 1e-9) {
          final double t =
              (geometry.frontTextureLimit - current.s) / denominator;
          final Offset source = Offset.lerp(current.source, next.source, t)!;
          output.add(_CurlMeshPoint(source, geometry.frontTextureLimit));
        }
      }
    }
    return output;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final Rect sourceRect = geometry.sheet.intersect(Offset.zero & size);
    if (sourceRect.isEmpty ||
        logicalSize.isEmpty ||
        geometry.radius <= 0.0 ||
        opacity <= 0.001) {
      return;
    }

    final List<double> positions = <double>[];
    final List<double> textureCoordinates = <double>[];

    // The captured bitmap may be smaller than DPR x logical size (memory
    // cap), so device DPR alone is not the UV step. Each axis, and in a spread
    // each leaf, derives its own scale from the bitmap's real texel grid.
    final _TextureWindow window = perLeafMapping
        ? _TextureWindow.leaf(image, logicalSize, sourceRect)
        : _TextureWindow.global(image, logicalSize);

    void addVertex(_CurlMeshPoint point) {
      final Offset target = geometry.projectFrontPoint(point.source);
      positions
        ..add(target.dx)
        ..add(target.dy);
      textureCoordinates
        ..add(window.u(point.source.dx))
        ..add(window.v(point.source.dy));
    }

    void addTriangle(
      _CurlMeshPoint a,
      _CurlMeshPoint b,
      _CurlMeshPoint c,
    ) {
      final List<_CurlMeshPoint> clipped = _clipTriangle(<_CurlMeshPoint>[
        a,
        b,
        c,
      ]);
      if (clipped.length < 3) return;
      for (int i = 1; i < clipped.length - 1; i++) {
        addVertex(clipped[0]);
        addVertex(clipped[i]);
        addVertex(clipped[i + 1]);
      }
    }

    final double cellWidth = sourceRect.width / _columns;
    final double cellHeight = sourceRect.height / _rows;
    final List<_CurlMeshPoint> grid = <_CurlMeshPoint>[];
    // Snap interior samples to whole texels of the window (per leaf in a
    // spread) so the mesh samples the bitmap 1:1 where it is flat.
    double snapX(double value) => window.snapX(value);
    double snapY(double value) => window.snapY(value);

    for (int row = 0; row <= _rows; row++) {
      // Keep exact outer boundaries but align interior samples to the
      // captured texture's texel grid. This removes fractional UV drift from
      // each half of a virtual wide page while retaining the shared spine.
      final double rawY = sourceRect.top + cellHeight * row;
      final double y = row == 0 || row == _rows
          ? rawY
          : snapY(rawY);
      for (int column = 0; column <= _columns; column++) {
        final double rawX = sourceRect.left + cellWidth * column;
        final double x = column == 0 || column == _columns
            ? rawX
            : snapX(rawX);
        final Offset source = Offset(x, y);
        grid.add(_CurlMeshPoint(source, geometry.sourceS(source)));
      }
    }

    _CurlMeshPoint at(int row, int column) =>
        grid[row * (_columns + 1) + column];

    for (int row = 0; row < _rows; row++) {
      for (int column = 0; column < _columns; column++) {
        final _CurlMeshPoint topLeft = at(row, column);
        final _CurlMeshPoint topRight = at(row, column + 1);
        final _CurlMeshPoint bottomRight = at(row + 1, column + 1);
        final _CurlMeshPoint bottomLeft = at(row + 1, column);
        addTriangle(topLeft, topRight, bottomRight);
        addTriangle(topLeft, bottomRight, bottomLeft);
      }
    }

    if (positions.isEmpty) return;

    final ui.Vertices vertices = ui.Vertices.raw(
      ui.VertexMode.triangles,
      Float32List.fromList(positions),
      textureCoordinates: Float32List.fromList(textureCoordinates),
    );
    final ui.ImageShader shader = ui.ImageShader(
      image,
      ui.TileMode.clamp,
      ui.TileMode.clamp,
      Matrix4.identity().storage,
    );
    final Paint paint = Paint()
      ..isAntiAlias = true
      ..colorFilter = ColorFilter.mode(
        Color.fromRGBO(255, 255, 255, _clamp(opacity, 0.0, 1.0)),
        BlendMode.modulate,
      )
      ..filterQuality = FilterQuality.high
      ..shader = shader;

    canvas.save();
    try {
      canvas.clipRect(Offset.zero & size);
      canvas.drawVertices(vertices, ui.BlendMode.srcOver, paint);
    } finally {
      canvas.restore();
      // Both are native-backed dart:ui objects and are created for this paint
      // pass only. Dispose them immediately after recording the draw operation.
      vertices.dispose();
      shader.dispose();
    }
  }

  @override
  bool shouldRepaint(covariant _CurlTexturePainter oldDelegate) =>
      !identical(oldDelegate.image, image) ||
      oldDelegate.logicalSize != logicalSize ||
      oldDelegate.opacity != opacity ||
      oldDelegate.perLeafMapping != perLeafMapping ||
      oldDelegate.geometry != geometry;
}

// ---------------------------------------------------------------------------
// Painting
// ---------------------------------------------------------------------------

class _PathClipper extends CustomClipper<Path> {
  _PathClipper(this.path);

  final Path path;

  @override
  Path getClip(Size size) => path;

  @override
  bool shouldReclip(covariant _PathClipper oldClipper) =>
      !identical(oldClipper.path, path);
}

class _RectClipper extends CustomClipper<Rect> {
  _RectClipper(this.rect);

  final Rect rect;

  @override
  Rect getClip(Size size) => rect;

  @override
  bool shouldReclip(covariant _RectClipper oldClipper) =>
      oldClipper.rect != rect;
}

/// Two stages, drawn in different slots of the frame's Stack:
///  * [_CurlLayer.shadow]: above the page, below the back layer - the flap's
///    shadow on the page (top) or the sheet's shadow on the revealed page (under);
///  * [_CurlLayer.shade]: above the back layer - roll shading and edge line.
///
/// [shadowOpacity] scales every darkening effect (flap shadow, shadow on the
/// revealed page, roll shading, edge line) and [highlightOpacity] the roll's
/// specular glint. Both come from the edge-proximity envelope, so they reach
/// zero before the curl layer is handed back to the settled page.
class _CurlPainter extends CustomPainter {
  _CurlPainter({
    required this.layer,
    required this.role,
    required this.geometry,
    this.shadowOpacity = 1.0,
    this.highlightOpacity = 1.0,
  });

  final _CurlLayer layer;
  final _CurlRole role;
  final _CurlGeometry geometry;
  final double shadowOpacity;
  final double highlightOpacity;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    if (role == _CurlRole.top) {
      if (layer == _CurlLayer.shadow) {
        _paintFlapShadow(canvas);
      } else {
        _paintBackShading(canvas);
      }
    } else if (layer == _CurlLayer.shadow && shadowOpacity > _kEffectEpsilon) {
      canvas.clipPath(geometry.revealClip);
      canvas.drawPaint(
        Paint()..shader = geometry.underShadowShader(opacity: shadowOpacity),
      );
    }
    canvas.restore();
  }

  void _paintFlapShadow(Canvas canvas) {
    final Path back = geometry.backFace;
    if (!geometry.hasBack || shadowOpacity <= _kEffectEpsilon) return;

    canvas.save();
    canvas.clipPath(geometry.frontClip);
    canvas.clipRect(geometry.shadowArea);
    canvas.drawPath(
      back.shift(geometry.shadowShift),
      Paint()
        // 0x66 / 255 = 0.4 at full strength.
        ..color = Color.fromRGBO(0, 0, 0, 0.4 * _clamp(shadowOpacity, 0.0, 1.0))
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7.0),
    );
    canvas.restore();
  }

  void _paintBackShading(Canvas canvas) {
    final Path back = geometry.backFace;
    if (!geometry.hasBack) return;

    final bool shade = shadowOpacity > _kEffectEpsilon;
    final bool glint = highlightOpacity > _kEffectEpsilon;

    if (shade) {
      canvas.drawPath(
        back,
        Paint()..shader = geometry.backShadeShader(opacity: shadowOpacity),
      );
    }
    if (glint) {
      canvas.drawPath(
        back,
        Paint()
          ..shader = geometry.rollHighlightShader(opacity: highlightOpacity)
          ..blendMode = BlendMode.screen,
      );
    }
    if (shade) {
      canvas.drawPath(
        back,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.8
          // 0x2E / 255 = 0.18 at full strength.
          ..color = Color.fromRGBO(
            0,
            0,
            0,
            0.18 * _clamp(shadowOpacity, 0.0, 1.0),
          ),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _CurlPainter oldDelegate) => true;
}
