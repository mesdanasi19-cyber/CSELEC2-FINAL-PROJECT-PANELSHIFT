import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'comic_identity.dart';
import 'comic_parser_service.dart';

/// A cached cover thumbnail plus the comic's page count (which is only known
/// once the archive has been indexed, so it is stored next to the image).
class ComicCover {
  const ComicCover({required this.path, required this.pageCount});

  final String path;
  final int pageCount;
}

/// Produces and caches small cover thumbnails (page 0) for the library.
///
/// Design:
///  * Covers are downscaled PNGs stored on disk (application *support* dir, not
///    the temp dir, so the OS cache cleaner and [ComicCacheService] never wipe
///    them). Opening a .cbr just to show a cover would mean extracting the whole
///    archive, so each cover is generated once and reused forever.
///  * At import time the archive is already open, so [adopt] builds the cover
///    from the live page source at almost no extra cost.
///  * For anything else, [request] generates the cover lazily through
///    [ComicParserService], one comic at a time (the RAR plugin is heavy), and
///    skips queued work that no visible card is waiting for any more.
///  * Memory is bounded by WIDTH *and* AREA (see [_coverWidth] and
///    [_coverMaxPixels]): whatever the page's aspect ratio, a stored cover
///    decodes to at most ~1.5 MB of RGBA.
///  * Generation is scroll-aware: while the library is being scrolled the queue
///    parks ([setScrolling]), so archive extraction never competes with the
///    UI/raster threads for CPU during a fling on a low-end phone.
class ComicCoverService {
  ComicCoverService._();
  static final ComicCoverService instance = ComicCoverService._();

  static const String _folderName = 'panelshift_covers';

  /// Hard ceiling for a stored cover's width. The library tile decodes with
  /// `cacheWidth <= 480` as well (main.dart), so the file on disk and the
  /// bitmap in the ImageCache obey the same bound.
  static const int _coverWidth = 480;

  /// Second bound, on AREA: 480 x 800 px = 1.5 MB of decoded RGBA. A width-only
  /// limit does not bound memory for tall pages: an 800 x 20000 strip scaled to
  /// 480 wide is still 480 x 12000 = 23 MB once the grid decodes it. With both
  /// limits every cover decodes to <= ~1.5 MB regardless of aspect ratio.
  static const int _coverMaxPixels = _coverWidth * 800;

  /// Minimum gap between two archive generations, so a burst of covers cannot
  /// hold the CPU for several consecutive frames.
  static const Duration _jobGap = Duration(milliseconds: 16);

  /// Longest a queued generation waits for the library to stop scrolling. A
  /// lost "scroll ended" signal therefore cannot stall the queue.
  static const Duration _scrollWaitCeiling = Duration(seconds: 3);

  static const int _metaVersion = 1;

  static final RegExp _unsafeChars = RegExp(r'[^A-Za-z0-9_-]');

  final Map<String, ComicCover> _memo = <String, ComicCover>{};
  final Map<String, Future<ComicCover?>> _inFlight =
      <String, Future<ComicCover?>>{};

  /// How many live widgets currently want each cover.
  final Map<String, int> _interest = <String, int>{};

  /// Comics whose cover failed to build this session; not retried on every
  /// scroll (a failing .cbr would otherwise be re-extracted repeatedly).
  final Set<String> _failed = <String>{};

  Future<Directory>? _dirFuture;
  Future<void> _queueTail = Future<void>.value();

  /// Non-null while the library is scrolling; queued jobs wait on it.
  Completer<void>? _scrollGate;

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Synchronous lookup of an already-known cover (no disk access).
  ComicCover? cached(String comicId) => _memo[comicId];

  /// Asks for [comic]'s cover. Pair every call with [release] (e.g. from a
  /// widget's dispose) so abandoned requests can be skipped. Never throws;
  /// completes with null when no cover can be produced.
  Future<ComicCover?> request(ComicIdentity comic) {
    final String id = comic.id;
    _interest[id] = (_interest[id] ?? 0) + 1;

    final ComicCover? known = _memo[id];
    if (known != null) return Future<ComicCover?>.value(known);

    final Future<ComicCover?>? running = _inFlight[id];
    if (running != null) return running;

    late final Future<ComicCover?> future;
    future = _resolve(comic).whenComplete(() {
      if (identical(_inFlight[id], future)) _inFlight.remove(id);
    });
    _inFlight[id] = future;
    return future;
  }

  /// Withdraws one [request].
  void release(String comicId) {
    final int left = (_interest[comicId] ?? 0) - 1;
    if (left <= 0) {
      _interest.remove(comicId);
    } else {
      _interest[comicId] = left;
    }
  }

  /// Tells the service whether the library list/grid is currently scrolling.
  ///
  /// Queued generations (archive extraction + decode + PNG encode) wait for the
  /// scroll to stop instead of competing with the UI and raster threads for the
  /// CPU. Work that is already running is never interrupted, and the wait is
  /// bounded ([_scrollWaitCeiling]).
  void setScrolling(bool scrolling) {
    if (scrolling) {
      _scrollGate ??= Completer<void>();
      return;
    }
    final Completer<void>? gate = _scrollGate;
    _scrollGate = null;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  Future<void> _waitForScrollIdle() async {
    final Completer<void>? gate = _scrollGate;
    if (gate != null) {
      await gate.future.timeout(
        _scrollWaitCeiling,
        onTimeout: () {
          // Treat a gate that outlived the ceiling as stale (a missed "scroll
          // ended"): drop it so the queue keeps moving.
          if (identical(_scrollGate, gate)) _scrollGate = null;
        },
      );
    }
    // Always leave at least one frame between two generations.
    await Future<void>.delayed(_jobGap);
  }

  /// Builds the cover from an archive that is already open (import path).
  /// Must be awaited while [loaded] is still open. Never throws.
  Future<ComicCover?> adopt(LoadedComic loaded) async {
    final String id = loaded.identity.id;
    try {
      final ComicCover? existing = await _readCached(id);
      if (existing != null) return existing;

      final Uint8List page0 = await loaded.source.readPage(0);
      return await _buildAndStore(id, page0, loaded.source.pageCount);
    } catch (e, st) {
      _failed.add(id);
      debugPrint('ComicCoverService.adopt failed for $id: $e\n$st');
      return null;
    }
  }

  /// Deletes the cached cover of a comic that left the library.
  Future<void> delete(String comicId) async {
    _memo.remove(comicId);
    _failed.remove(comicId);
    try {
      final Directory dir = await _dir();
      await _deleteQuietly(File(_pngPath(dir, comicId)));
      await _deleteQuietly(File(_metaPath(dir, comicId)));
    } catch (e) {
      debugPrint('ComicCoverService.delete failed for $comicId: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Resolution
  // ---------------------------------------------------------------------------

  Future<ComicCover?> _resolve(ComicIdentity comic) async {
    final ComicCover? cached = await _readCached(comic.id);
    if (cached != null) return cached;
    if (_failed.contains(comic.id)) return null;

    return _enqueue<ComicCover?>(() async {
      // Every card that wanted this cover has scrolled away: skip the work.
      if ((_interest[comic.id] ?? 0) <= 0) return null;

      // Heavy work starts only while the library is idle, and only if somebody
      // still wants the cover once the wait is over.
      await _waitForScrollIdle();
      if ((_interest[comic.id] ?? 0) <= 0) return null;

      // An import (adopt) may have produced it while we were queued.
      final ComicCover? again = await _readCached(comic.id);
      if (again != null) return again;

      return _generateFromArchive(comic);
    });
  }

  /// One generation at a time; the tail never completes with an error.
  Future<T> _enqueue<T>(Future<T> Function() job) {
    final Future<void> previous = _queueTail;
    final Completer<void> done = Completer<void>();
    _queueTail = done.future;

    return () async {
      try {
        await previous;
        return await job();
      } finally {
        done.complete();
      }
    }();
  }

  Future<ComicCover?> _generateFromArchive(ComicIdentity comic) async {
    // Not marked as failed: the file may reappear (or be re-imported).
    if (!await File(comic.sourcePath).exists()) return null;

    LoadedComic? loaded;
    try {
      loaded = await ComicParserService.loadComic(comic.sourcePath);
      final int pageCount = loaded.source.pageCount;
      if (pageCount <= 0) {
        throw const FormatException('Archive contains no image pages');
      }
      final Uint8List page0 = await loaded.source.readPage(0);
      return await _buildAndStore(comic.id, page0, pageCount);
    } catch (e, st) {
      _failed.add(comic.id);
      debugPrint('ComicCoverService: cover failed for ${comic.id}: $e\n$st');
      return null;
    } finally {
      try {
        await loaded?.close();
      } catch (e) {
        debugPrint('ComicCoverService: closing archive failed: $e');
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Disk cache
  // ---------------------------------------------------------------------------

  Future<Directory> _dir() {
    final Future<Directory>? existing = _dirFuture;
    if (existing != null) return existing;

    final Future<Directory> future = () async {
      final Directory base = await getApplicationSupportDirectory();
      final Directory dir = Directory(
        '${base.path}${Platform.pathSeparator}$_folderName',
      );
      await dir.create(recursive: true);
      return dir;
    }();
    _dirFuture = future;

    // Do not cache a failure forever.
    future.then<void>((Directory _) {}, onError: (Object _) {
      if (identical(_dirFuture, future)) _dirFuture = null;
    });
    return future;
  }

  static String _safe(String id) => id.replaceAll(_unsafeChars, '_');

  static String _pngPath(Directory dir, String id) =>
      '${dir.path}${Platform.pathSeparator}${_safe(id)}.png';

  static String _metaPath(Directory dir, String id) =>
      '${dir.path}${Platform.pathSeparator}${_safe(id)}.json';

  Future<ComicCover?> _readCached(String id) async {
    final ComicCover? memo = _memo[id];
    if (memo != null) return memo;

    try {
      final Directory dir = await _dir();
      final File png = File(_pngPath(dir, id));

      // One read instead of exists() + read: a missing record (the common case
      // while a big library is first scrolled) costs a single failed open.
      final String raw = await File(_metaPath(dir, id)).readAsString().then<String>(
        (String value) => value,
        onError: (Object _) => '',
      );
      if (raw.isEmpty || !await png.exists()) return null;

      final Object? parsed = jsonDecode(raw);
      if (parsed is! Map) return null;
      final Object? version = parsed['v'];
      final Object? pages = parsed['pages'];
      if (version != _metaVersion || pages is! num || pages.toInt() <= 0) {
        return null;
      }

      final ComicCover cover = ComicCover(
        path: png.path,
        pageCount: pages.toInt(),
      );
      _memo[id] = cover;
      return cover;
    } catch (e) {
      debugPrint('ComicCoverService: unreadable cover record for $id: $e');
      return null;
    }
  }

  Future<ComicCover> _buildAndStore(
    String id,
    Uint8List page0,
    int pageCount,
  ) async {
    final Uint8List png = await _downscaleToPng(page0);
    final Directory dir = await _dir();

    final String pngPath = _pngPath(dir, id);
    final String metaPath = _metaPath(dir, id);
    final String stamp = DateTime.now().microsecondsSinceEpoch.toString();
    final File tmpPng = File('$pngPath.$stamp.tmp');
    final File tmpMeta = File('$metaPath.$stamp.tmp');

    try {
      await tmpPng.writeAsBytes(png, flush: true);
      await tmpMeta.writeAsString(
        jsonEncode(<String, Object>{'v': _metaVersion, 'pages': pageCount}),
        flush: true,
      );
      // Rename into place, metadata last: it is the "record is complete" marker.
      await tmpPng.rename(pngPath);
      await tmpMeta.rename(metaPath);
    } catch (_) {
      await _deleteQuietly(tmpPng);
      await _deleteQuietly(tmpMeta);
      rethrow;
    }

    final ComicCover cover = ComicCover(path: pngPath, pageCount: pageCount);
    _memo[id] = cover;
    _failed.remove(id);
    return cover;
  }

  /// Fits [width] x [height] inside the cover budget: at most [_coverWidth]
  /// wide AND at most [_coverMaxPixels] in area, never upscaled.
  static _CoverSize _fitCover(int width, int height) {
    if (width <= 0 || height <= 0) return const _CoverSize(_coverWidth, _coverWidth);
    final double byWidth = _coverWidth / width;
    final double byArea = math.sqrt(_coverMaxPixels / (width * height.toDouble()));
    final double scale = math.min(1.0, math.min(byWidth, byArea));
    return _CoverSize(
      math.max(1, (width * scale).round()),
      math.max(1, (height * scale).round()),
    );
  }

  /// Reads only the header to learn the page size, then opens a codec that
  /// decodes straight to the bounded thumbnail size. For JPEG/WebP the engine
  /// can scale inside the decoder, so the full-resolution bitmap is never
  /// materialised; for PNG pages the decoder still needs the full bitmap
  /// transiently, which is why the stored result is also area-bounded.
  static Future<ui.Codec> _openThumbnailCodec(Uint8List bytes) async {
    final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(
      bytes,
    );
    try {
      final ui.ImageDescriptor descriptor = await ui.ImageDescriptor.encoded(
        buffer,
      );
      try {
        final _CoverSize target = _fitCover(descriptor.width, descriptor.height);
        // The codec keeps its own reference to the descriptor.
        return await descriptor.instantiateCodec(
          targetWidth: target.width,
          targetHeight: target.height,
        );
      } catch (_) {
        descriptor.dispose();
        rethrow;
      }
    } finally {
      buffer.dispose();
    }
  }

  /// Decodes at the bounded thumbnail size and re-encodes as PNG. Both steps
  /// run on engine worker threads, not the UI isolate.
  static Future<Uint8List> _downscaleToPng(Uint8List bytes) async {
    final ui.Codec codec = await _openThumbnailCodec(bytes);
    try {
      final ui.FrameInfo frame = await codec.getNextFrame();
      final ui.Image image = frame.image;
      try {
        final ByteData? data = await image.toByteData(
          format: ui.ImageByteFormat.png,
        );
        if (data == null) throw StateError('PNG encoding returned no data');
        return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      } finally {
        image.dispose();
      }
    } finally {
      codec.dispose();
    }
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (e) {
      debugPrint('ComicCoverService: could not delete ${file.path}: $e');
    }
  }
}

/// Pixel size of a bounded cover thumbnail.
class _CoverSize {
  const _CoverSize(this.width, this.height);

  final int width;
  final int height;
}
