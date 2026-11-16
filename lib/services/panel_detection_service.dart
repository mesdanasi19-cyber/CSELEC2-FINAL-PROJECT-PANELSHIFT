import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'isolate_rpc.dart';
import 'native_opencv_service.dart';

enum _JobState { pending, decoding, inFlight, cancelled }

class _Job {
  _Job(this.page, this.encoded);

  final int page;
  final Uint8List encoded;
  final Completer<List<ComicPanel>?> completer = Completer<List<ComicPanel>?>();
  _JobState state = _JobState.pending;

  bool get cancelled => state == _JobState.cancelled;
}

class _Frame {
  const _Frame(this.rgba, this.width, this.height);
  final Uint8List rgba;
  final int width;
  final int height;
}

/// Runs panel detection off the UI isolate and only spends it on pages the
/// reader still cares about.
///
/// How a fast fling is handled:
///  * The reader reports which pages matter ([updateFocus]): the current
///    spread and its two neighbours. Anything else that is still waiting is
///    cancelled on the spot (its future completes with `null`).
///  * Every time the reader moves to a different spread, nothing new is
///    started until it has stayed put for [settleDelay]. While the user is
///    still flinging, no decode and no inference is started at all.
///  * At most one job is dispatched to the worker at a time, so the amount of
///    work that cannot be cancelled is bounded by a single inference.
///  * Pending jobs are served nearest-to-focus first. In spread mode BOTH
///    pages of the active spread are "the focus" and share the top priority
///    (left page first, then right), so the right page is never starved
///    behind a neighbouring spread. Below that: the next spread, then the
///    previous one.
class PanelDetectionService {
  PanelDetectionService._();
  static final PanelDetectionService instance = PanelDetectionService._();

  /// How long the reader must stay on a spread before new work starts.
  static const Duration settleDelay = Duration(milliseconds: 40);

  /// After the active spread changes (or one of its pages finishes), work for
  /// OTHER pages is held back for at most this long while a page of the active
  /// spread has not been queued yet. The reader queues both halves of a spread
  /// a few milliseconds apart; without this hold, a prefetch job could slip in
  /// between them and, being uncancellable once running, delay the right page
  /// by a whole inference.
  static const Duration activeHold = Duration(milliseconds: 60);

  /// Pages are decoded to at most this many pixels on the long edge before
  /// detection. The model input is 640x640, so more pixels are wasted work.
  static const int detectionLongEdge = 640;

  static const int maxPanelsPerPage = 30;

  final Map<int, _Job> _jobs = <int, _Job>{};
  Set<int> _wanted =
      const <int>{}; // empty = no focus yet, everything is wanted
  int _focusPage = 0;

  /// Pages of the spread the reader is on (one page in single-page mode, two
  /// in spread mode). Every page in here has the same, highest priority.
  Set<int> _activePages = const <int>{};

  /// Pages that finished detection (successfully) since the last [cancelAll].
  final Set<int> _done = <int>{};
  DateTime _activeHoldUntil = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _settledAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _pumping = false;

  /// Resolves with the panels, or with `null` if the job was cancelled before
  /// it reached the worker. A cancelled page must NOT be cached as "no panels".
  Future<List<ComicPanel>?> detect(int page, Uint8List encodedImage) {
    final _Job? existing = _jobs[page];
    if (existing != null) return existing.completer.future;

    final _Job job = _Job(page, encodedImage);
    _jobs[page] = job;
    _kick();
    return job.completer.future;
  }

  /// Tell the service which page the reader is on and which pages are still
  /// worth detecting. Cheap; call it on every page change.
  ///
  /// [activePages] are the pages shown together right now (both halves of the
  /// current spread). They are detected before anything else and with equal
  /// priority, and are always treated as wanted. Leave it empty in
  /// single-page mode: [focusPage] alone is then the active page.
  void updateFocus(
    int focusPage,
    Set<int> wantedPages, {
    Set<int> activePages = const <int>{},
  }) {
    // Stepping from the left page of a spread to its right page is not a
    // fling, so it must not restart the settle timer. Only landing on a page
    // that is NOT part of the spread we were already on does.
    final bool movedAway = _activePages.isNotEmpty
        ? !_activePages.contains(focusPage)
        : focusPage != _focusPage;
    if (movedAway) {
      _settledAt = DateTime.now().add(settleDelay);
    }

    final Set<int> newActive = activePages.isEmpty
        ? <int>{focusPage}
        : Set<int>.of(activePages);
    final bool activeChanged =
        newActive.length != _activePages.length ||
        !newActive.containsAll(_activePages);

    _focusPage = focusPage;
    _activePages = newActive;
    if (activeChanged) {
      _activeHoldUntil = DateTime.now().add(activeHold);
    }

    // An empty wanted set keeps its meaning ("everything is wanted"); a real
    // one always includes the active spread so none of its pages can be
    // dropped as stale.
    _wanted = wantedPages.isEmpty
        ? const <int>{}
        : <int>{...wantedPages, ..._activePages};

    _dropStale();
    if (_jobs.isNotEmpty) _kick();
  }

  /// Cancels everything that has not reached the worker (reader closed).
  void cancelAll() {
    _wanted = const <int>{};
    _focusPage = 0;
    _activePages = const <int>{};
    _done.clear();
    _activeHoldUntil = DateTime.fromMillisecondsSinceEpoch(0);

    for (final _Job job in _jobs.values.toList()) {
      if (job.state == _JobState.pending || job.state == _JobState.decoding) {
        _cancel(job);
      } else if (job.state == _JobState.inFlight) {
        // The native inference cannot be cancelled safely.
        // Detach it from the page map so a new reader cannot
        // accidentally reuse the previous reader's future.
        if (identical(_jobs[job.page], job)) {
          _jobs.remove(job.page);
        }
      }
    }
  }

  // --- scheduling -------------------------------------------------------------

  void _kick() {
    if (!_pumping) unawaited(_pump());
  }

  void _cancel(_Job job) {
    job.state = _JobState.cancelled;
    if (identical(_jobs[job.page], job)) _jobs.remove(job.page);
    if (!job.completer.isCompleted) job.completer.complete(null);
  }

  void _dropStale() {
    if (_wanted.isEmpty) return;
    for (final _Job job in _jobs.values.toList()) {
      final bool running =
          job.state == _JobState.pending || job.state == _JobState.decoding;
      if (running && !_wanted.contains(job.page)) _cancel(job);
    }
  }

  /// Distance of [page] from the active spread; 0 for every active page.
  int _distanceFromActive(int page) {
    final Set<int> anchors = _activePages.isNotEmpty
        ? _activePages
        : <int>{_focusPage};
    int best = 1 << 30;
    for (final int anchor in anchors) {
      final int d = (page - anchor).abs();
      if (d < best) best = d;
    }
    return best;
  }

  /// True while a page of the active spread has neither a queued job nor a
  /// finished result.
  bool _activeIncomplete() {
    for (final int p in _activePages) {
      if (!_jobs.containsKey(p) && !_done.contains(p)) return true;
    }
    return false;
  }

  _Job? _pickNext() {
    final Set<int> anchors = _activePages.isNotEmpty
        ? _activePages
        : <int>{_focusPage};
    final int anchorMax = anchors.reduce(math.max);

    _Job? best;
    int bestDistance = 1 << 30;
    int bestTie = 1 << 30;

    for (final _Job job in _jobs.values) {
      if (job.state != _JobState.pending) continue;

      final int distance = _distanceFromActive(job.page);
      // Tie-break:
      //  * inside the active spread (distance 0): reading order, left page
      //    first - both pages still have equal priority over everything else;
      //  * outside it: the page ahead of the reader before the one behind.
      final int tie = distance == 0
          ? job.page
          : (job.page > anchorMax ? 0 : 1);

      if (distance < bestDistance ||
          (distance == bestDistance && tie < bestTie)) {
        best = job;
        bestDistance = distance;
        bestTie = tie;
      }
    }
    return best;
  }

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (true) {
        _dropStale();
        final _Job? job = _pickNext();
        if (job == null) break;

        final Duration wait = _settledAt.difference(DateTime.now());
        if (wait > Duration.zero) {
          await Future<void>.delayed(wait);
          continue; // focus may have moved again: re-evaluate everything
        }

        // Keep the active spread's pages consecutive: do not start low-priority
        // work while an active page has not even been queued yet (bounded by
        // [activeHold]).
        if (_distanceFromActive(job.page) > 0 && _activeIncomplete()) {
          final Duration hold = _activeHoldUntil.difference(DateTime.now());
          if (hold > Duration.zero) {
            await Future<void>.delayed(hold);
            continue;
          }
        }

        // Last chance to purge: nothing stale may reach the decoder.
        _dropStale();
        if (job.cancelled) continue;

        await _run(job);
      }
    } finally {
      _pumping = false;
    }
  }

  Future<void> _run(_Job job) async {
    job.state = _JobState.decoding;
    try {
      // Stage 1 (engine threads): decode straight to a reduced size.
      final _Frame frame = await _decodeForDetection(job.encoded);
      if (job.cancelled) return;

      // Stage 2 (worker isolate): native inference.
      final IsolateRpc worker = await NativeOpenCvService.ensureWorker();
      if (job.cancelled) return;
      job.state =
          _JobState.inFlight; // from here on it can no longer be cancelled

      final Float32List? flat = await worker.call<Float32List>(
        'detect',
        <Object?>[
          TransferableTypedData.fromList(<TypedData>[frame.rgba]),
          frame.width,
          frame.height,
          maxPanelsPerPage,
        ],
      );
      if (!job.completer.isCompleted) {
        job.completer.complete(NativeOpenCvService.panelsFromFlat(flat));
      }
      _done.add(job.page);
      if (_activePages.contains(job.page)) {
        // The other half of the spread may be queued a moment from now.
        _activeHoldUntil = DateTime.now().add(activeHold);
      }
    } catch (e, st) {
      if (!job.completer.isCompleted) job.completer.completeError(e, st);
    } finally {
      if (identical(_jobs[job.page], job)) _jobs.remove(job.page);
    }
  }

  /// Decodes at (at most) [detectionLongEdge] px instead of full resolution:
  /// JPEG/PNG decoders can downscale while decoding, and the RGBA copy that
  /// crosses into the worker is several times smaller.
  static Future<_Frame> _decodeForDetection(Uint8List encoded) async {
    final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(
      encoded,
    );
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final int w = descriptor.width;
      final int h = descriptor.height;
      final double scale = math.min(1.0, detectionLongEdge / math.max(w, h));
      final int targetW = math.max(1, (w * scale).round());
      final int targetH = math.max(1, (h * scale).round());

      codec = await descriptor.instantiateCodec(
        targetWidth: targetW,
        targetHeight: targetH,
      );
      final ui.FrameInfo frame = await codec.getNextFrame();
      image = frame.image;

      final ByteData? data = await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      if (data == null) {
        throw StateError('Could not read pixels for panel detection');
      }
      return _Frame(
        Uint8List.view(data.buffer, data.offsetInBytes, data.lengthInBytes),
        image.width,
        image.height,
      );
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
  }
}
