import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'isolate_rpc.dart';
import 'native_opencv_service.dart';

enum _JobState { pending, decoding, inFlight, cancelled }

class _Job {
  _Job(this.page, Uint8List encoded) : _encoded = encoded;

  final int page;
  final Completer<List<ComicPanel>?> completer = Completer<List<ComicPanel>?>();
  _JobState state = _JobState.pending;

  /// The compressed page. It is handed to the decoder (or dropped on cancel) as
  /// early as possible, so a job that waits for, or runs, an inference does not
  /// pin a multi-MB buffer that nothing in this service needs any more.
  Uint8List? _encoded;

  bool get cancelled => state == _JobState.cancelled;

  /// True until the job reaches the worker; only such a job can be cancelled.
  bool get cancellable =>
      state == _JobState.pending || state == _JobState.decoding;

  Uint8List takeEncoded() {
    final Uint8List? bytes = _encoded;
    if (bytes == null) {
      throw StateError('Encoded bytes of page $page were already released');
    }
    _encoded = null;
    return bytes;
  }

  void releaseEncoded() {
    _encoded = null;
  }
}

class _Frame {
  const _Frame(this.pixels, this.width, this.height);

  /// RGBA pixels, already copied into transferable memory by
  /// [PanelDetectionService._decodeForDetection].
  final TransferableTypedData pixels;
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
///    work that cannot be cancelled is bounded by a single inference. The
///    decode of the next page is deliberately NOT overlapped with a running
///    inference: both would fight for the same cores (the native side already
///    uses all of them) and the inference is the part that cannot be cancelled.
///  * Pending jobs are served in whole spreads, nearest first: the active
///    spread (left page first, then right), then the NEXT spread (both pages),
///    then the PREVIOUS one, then the spread after next, and so on (see
///    [_priorityKey]). In single-page mode a "spread" is one page.
///
/// Memory: one page is decoded at a time and only at [detectionLongEdge] px, a
/// job drops its compressed bytes as soon as the decoder has them, and the
/// decoded bitmap is copied into transferable memory and released before the
/// inference starts.
///
/// Time is read from a monotonic [Stopwatch], not DateTime.now(): a wall-clock
/// change (manual or network time update) can no longer freeze the queue.
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

  /// [_done] only has to remember pages around the reader; anything farther
  /// away than this many pages is forgotten so the set cannot grow all session.
  static const int _doneWindow = 8;

  final Map<int, _Job> _jobs = <int, _Job>{};
  Set<int> _wanted =
      const <int>{}; // empty = no focus yet, everything is wanted
  int _focusPage = 0;

  /// Pages of the spread the reader is on (one page in single-page mode, two
  /// in spread mode). Every page in here has the same, highest priority.
  Set<int> _activePages = const <int>{};

  /// Lowest / highest page of the active spread (the focus page while no
  /// spread is known). Cached so ranking a job allocates nothing.
  int _anchorMin = 0;
  int _anchorMax = 0;

  /// Pages that finished detection (successfully) since the last [cancelAll],
  /// pruned to [_doneWindow] pages around the reader.
  final Set<int> _done = <int>{};

  final Stopwatch _clock = Stopwatch()..start();
  int _activeHoldUntilUs = 0;
  int _settledAtUs = 0;
  bool _pumping = false;

  /// Reused by [_dropStale] so the common "nothing is stale" case allocates
  /// nothing (it runs on every focus change and every pump iteration).
  final List<_Job> _scratch = <_Job>[];

  int get _nowUs => _clock.elapsedMicroseconds;

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
    final int now = _nowUs;

    // Stepping from the left page of a spread to its right page is not a
    // fling, so it must not restart the settle timer. Only landing on a page
    // that is NOT part of the spread we were already on does.
    final bool movedAway = _activePages.isNotEmpty
        ? !_activePages.contains(focusPage)
        : focusPage != _focusPage;
    if (movedAway) {
      _settledAtUs = now + settleDelay.inMicroseconds;
    }

    final Set<int> newActive = activePages.isEmpty
        ? <int>{focusPage}
        : Set<int>.of(activePages);
    final bool activeChanged =
        newActive.length != _activePages.length ||
        !newActive.containsAll(_activePages);

    _focusPage = focusPage;
    if (activeChanged) {
      _activePages = newActive;
      _recomputeAnchors();
      _activeHoldUntilUs = now + activeHold.inMicroseconds;
      _done.removeWhere((int p) => _distanceFromActive(p) > _doneWindow);
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
    _recomputeAnchors();
    _done.clear();
    _activeHoldUntilUs = 0;
    _settledAtUs = 0;

    for (final _Job job in _jobs.values.toList()) {
      if (job.cancellable) {
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
    job.releaseEncoded();
    if (identical(_jobs[job.page], job)) _jobs.remove(job.page);
    if (!job.completer.isCompleted) job.completer.complete(null);
  }

  void _dropStale() {
    if (_wanted.isEmpty) return;
    _scratch.clear();
    for (final _Job job in _jobs.values) {
      if (job.cancellable && !_wanted.contains(job.page)) _scratch.add(job);
    }
    for (final _Job job in _scratch) {
      _cancel(job);
    }
    _scratch.clear();
  }

  void _recomputeAnchors() {
    if (_activePages.isEmpty) {
      _anchorMin = _anchorMax = _focusPage;
      return;
    }
    int lo = _activePages.first;
    int hi = lo;
    for (final int p in _activePages) {
      if (p < lo) lo = p;
      if (p > hi) hi = p;
    }
    _anchorMin = lo;
    _anchorMax = hi;
  }

  /// True for the pages of the spread the reader is on.
  bool _isActive(int page) => _activePages.isNotEmpty
      ? _activePages.contains(page)
      : page == _focusPage;

  /// Distance of [page] from the active spread; 0 for every active page.
  int _distanceFromActive(int page) {
    if (page < _anchorMin) return _anchorMin - page;
    if (page > _anchorMax) return page - _anchorMax;
    return 0;
  }

  /// Sort key of [page]; the pending job with the smallest key runs next.
  ///
  /// Pages are ranked in whole spreads, nearest spread first, because the
  /// spread is the unit the reader turns to:
  ///   key = (spreads away from the active one, ahead-before-behind, offset)
  ///  * the active spread is block 0, in reading order (left page first);
  ///  * block k >= 1 is the k-th spread after / before it. "After" wins over
  ///    "before" at the same k, and inside a block the page nearest to the
  ///    active spread goes first.
  /// With the reader on {4,5} that gives 4,5 | 6,7 | 3,2 | 8,9 | 1,0 ...
  /// The previous rule ranked single pages by distance (4,5 | 6,3,7,2), which
  /// put the previous spread's right page ahead of the NEXT spread's right
  /// page, the opposite of what the class comment promises, so the page the
  /// reader is most likely to turn to was left half-ready. In single-page mode
  /// the spread is one page wide and both rules give the same order.
  int _priorityKey(int page) {
    final int span = _anchorMax - _anchorMin + 1; // 1 = single page, 2 = spread
    final int block;
    final int side; // 0 = ahead of the reader, 1 = behind
    final int offset;
    if (page < _anchorMin) {
      final int d = _anchorMin - page - 1;
      block = d ~/ span + 1;
      side = 1;
      offset = d % span;
    } else if (page > _anchorMax) {
      final int d = page - _anchorMax - 1;
      block = d ~/ span + 1;
      side = 0;
      offset = d % span;
    } else {
      block = 0;
      side = 0;
      offset = page - _anchorMin;
    }
    return (block << 12) | (side << 10) | offset;
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
    _Job? best;
    int bestKey = 1 << 40;
    for (final _Job job in _jobs.values) {
      if (job.state != _JobState.pending) continue;
      final int key = _priorityKey(job.page);
      if (key < bestKey) {
        best = job;
        bestKey = key;
      }
    }
    return best;
  }

  /// Sleeps at least [us] microseconds. Timers tick in whole milliseconds, so
  /// round up instead of spinning through sub-millisecond waits.
  static Future<void> _sleepUs(int us) =>
      Future<void>.delayed(Duration(milliseconds: (us + 999) ~/ 1000));

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (true) {
        _dropStale();
        final _Job? job = _pickNext();
        if (job == null) break;

        final int settleLeftUs = _settledAtUs - _nowUs;
        if (settleLeftUs > 0) {
          await _sleepUs(settleLeftUs);
          continue; // focus may have moved again: re-evaluate everything
        }

        // Keep the active spread's pages consecutive: do not start low-priority
        // work while an active page has not even been queued yet (bounded by
        // [activeHold]).
        if (!_isActive(job.page) && _activeIncomplete()) {
          final int holdLeftUs = _activeHoldUntilUs - _nowUs;
          if (holdLeftUs > 0) {
            await _sleepUs(holdLeftUs);
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
      // Stage 1 (engine threads): decode straight to a reduced size. The job's
      // compressed bytes are handed over here and not kept.
      final _Frame frame = await _decodeForDetection(job.takeEncoded());
      if (job.cancelled) return;

      // Stage 2 (worker isolate): native inference.
      final IsolateRpc worker = await NativeOpenCvService.ensureWorker();
      if (job.cancelled) return;
      job.state =
          _JobState.inFlight; // from here on it can no longer be cancelled

      final Float32List? flat = await worker.call<Float32List>(
        'detect',
        <Object?>[frame.pixels, frame.width, frame.height, maxPanelsPerPage],
      );
      if (!job.completer.isCompleted) {
        job.completer.complete(NativeOpenCvService.panelsFromFlat(flat));
      }

      // Bookkeeping only while this job is still the one registered for its
      // page. After cancelAll() it belongs to a reader that no longer exists,
      // and must not mark the page "done" for the next one.
      if (identical(_jobs[job.page], job)) {
        _done.add(job.page);
        if (_isActive(job.page)) {
          // The other half of the spread may be queued a moment from now.
          _activeHoldUntilUs = _nowUs + activeHold.inMicroseconds;
        }
      }
    } catch (e, st) {
      if (!job.completer.isCompleted) job.completer.completeError(e, st);
    } finally {
      job.releaseEncoded();
      if (identical(_jobs[job.page], job)) _jobs.remove(job.page);
    }
  }

  /// Decodes at (at most) [detectionLongEdge] px instead of full resolution:
  /// JPEG/PNG decoders can downscale while decoding, and the RGBA copy that
  /// crosses into the worker is several times smaller.
  ///
  /// Two things are deliberately left as they were: the long edge stays 640
  /// because that is the model's input size (going lower would feed it a softer
  /// page and change what it detects), and the aspect ratio is kept (no square
  /// decode) because the native side derives `page_aspect` for its geometry
  /// filters from this frame's width and height.
  ///
  /// The pixels are copied into transferable memory right here, so once this
  /// returns the decoded bitmap and its ByteData are garbage instead of being
  /// referenced by the job for the whole (uncancellable) inference.
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
      final TransferableTypedData pixels = TransferableTypedData.fromList(
        <TypedData>[
          Uint8List.view(data.buffer, data.offsetInBytes, data.lengthInBytes),
        ],
      );
      return _Frame(pixels, image.width, image.height);
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
  }
}
