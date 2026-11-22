import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
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
///  * Covers are downscaled thumbnails stored on disk (application *support*
///    dir, not the temp dir, so the OS cache cleaner and [ComicCacheService]
///    never wipe them). On Android they are compact JPEGs (~15-25 KB, encoded
///    natively); elsewhere, or if the native encoder is unavailable, PNG.
///    Covers cached as PNG by older versions keep loading unchanged. Opening a .cbr just to show a cover would mean extracting the whole
///    archive, so each cover is generated once and reused forever.
///  * At import time the archive is already open, so [adopt] builds the cover
///    from the live page source at almost no extra cost.
///  * For anything else, [request] generates the cover lazily through
///    [ComicParserService], one comic at a time (the RAR plugin is heavy), and
///    skips queued work that no visible card is waiting for any more.
///  * Memory is bounded by WIDTH *and* AREA (see [_coverWidth] and
///    [_coverMaxPixels]): whatever the page's aspect ratio, a stored cover
///    decodes to at most ~0.7 MB of RGBA.
///  * Generation is scroll-aware: while the library is being scrolled the queue
///    parks ([setScrolling]), so archive extraction never competes with the
///    UI/raster threads for CPU during a fling on a low-end phone.
class ComicCoverService {
  ComicCoverService._();
  static final ComicCoverService instance = ComicCoverService._();

  static const String _folderName = 'panelshift_covers';

  /// Same channel as the SAF picker (see MainActivity.kt); used for the native
  /// JPEG encoder.
  static const MethodChannel _safChannel = MethodChannel('panelshift/saf_picker');

  /// Hard ceiling for a stored cover's width. 320 px stays crisp on 2-6 column
  /// grids; the library tile decodes with a `cacheWidth` no larger than this,
  /// so the file on disk and the bitmap in the ImageCache obey the same bound.
  static const int _coverWidth = 400;

  /// Second bound, on AREA: 320 x 540 px = ~0.7 MB of decoded RGBA. A width-only
  /// limit does not bound memory for tall pages: an 800 x 20000 strip scaled to
  /// 320 wide is still 320 x 8000 = 10 MB once the grid decodes it. With both
  /// limits every cover decodes to <= ~0.7 MB regardless of aspect ratio.
  static const int _coverMaxPixels = _coverWidth * 660;

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
  /// Queued generations (archive extraction + decode + thumbnail encode) wait for the
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
      await _deleteQuietly(File(_imagePath(dir, comicId, 'jpg')));
      await _deleteQuietly(File(_imagePath(dir, comicId, 'png')));
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
    if (!comic.isContentUri && !await File(comic.sourcePath).exists()) {
      return null;
    }

    LoadedComic? loaded;
    try {
      // Only page 0 is needed: a .cbr unpacked for it must not stay in the
      // CBR cache once [loaded] is closed below.
      loaded = await ComicParserService.loadComic(
        comic.sourcePath,
        retainCbrCache: false,
      );
      final int pageCount = loaded.source.pageCount;
      if (pageCount <= 0) {
        throw const FormatException('Archive contains no image pages');
      }
      final Uint8List page0 = await loaded.source.readPage(0);
      return await _buildAndStore(comic.id, page0, pageCount);
    } on FileSystemException catch (e) {
      // Missing or unreadable source (including revoked/moved content:// URIs):
      // leave out of _failed so it can recover if the file is restored.
      debugPrint('ComicCoverService: source unreadable for ${comic.id}: $e');
      return null;
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

  static String _imagePath(Directory dir, String id, String ext) =>
      '${dir.path}${Platform.pathSeparator}${_safe(id)}.$ext';

  static String _metaPath(Directory dir, String id) =>
      '${dir.path}${Platform.pathSeparator}${_safe(id)}.json';

  Future<ComicCover?> _readCached(String id) async {
    final ComicCover? memo = _memo[id];
    if (memo != null) return memo;

    try {
      final Directory dir = await _dir();

      // One read instead of exists() + read: a missing record (the common case
      // while a big library is first scrolled) costs a single failed open.
      final String raw = await File(_metaPath(dir, id)).readAsString().then<String>(
        (String value) => value,
        onError: (Object _) => '',
      );
      if (raw.isEmpty) return null;

      final Object? parsed = jsonDecode(raw);
      if (parsed is! Map) return null;
      final Object? version = parsed['v'];
      final Object? pages = parsed['pages'];
      if (version != _metaVersion || pages is! num || pages.toInt() <= 0) {
        return null;
      }

      // Records written before JPEG covers existed have no 'ext': those
      // covers are PNGs and keep loading without regeneration.
      final Object? storedExt = parsed['ext'];
      final String ext =
          storedExt is String && storedExt.isNotEmpty ? storedExt : 'png';

      final File img = File(_imagePath(dir, id, ext));
      if (!await img.exists()) return null;

      final ComicCover cover = ComicCover(
        path: img.path,
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
    final ({Uint8List bytes, String ext}) encoded = await _encodeThumbnail(page0);
    final Directory dir = await _dir();

    final String imgPath = _imagePath(dir, id, encoded.ext);
    final String metaPath = _metaPath(dir, id);
    final String stamp = DateTime.now().microsecondsSinceEpoch.toString();
    final File tmpImg = File('$imgPath.$stamp.tmp');
    final File tmpMeta = File('$metaPath.$stamp.tmp');

    try {
      await tmpImg.writeAsBytes(encoded.bytes, flush: true);
      await tmpMeta.writeAsString(
        jsonEncode(<String, Object>{
          'v': _metaVersion,
          'pages': pageCount,
          'ext': encoded.ext,
        }),
        flush: true,
      );
      // Rename into place, metadata last: it is the "record is complete" marker.
      await tmpImg.rename(imgPath);
      await tmpMeta.rename(metaPath);
    } catch (_) {
      await _deleteQuietly(tmpImg);
      await _deleteQuietly(tmpMeta);
      rethrow;
    }

    // The record now points at the new image; a legacy PNG left by an older
    // version is dead weight.
    if (encoded.ext != 'png') {
      await _deleteQuietly(File(_imagePath(dir, id, 'png')));
    }

    final ComicCover cover = ComicCover(path: imgPath, pageCount: pageCount);
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

  /// Decodes page 0 into a bounded thumbnail image. When page 0 is a wide
  /// two-page spread (`width > height`), only the right half (the front cover
  /// on wrap-around / manga covers) is kept and scaled to the cover budget so
  /// the library tile never stretches a low-resolution center crop.
  static Future<ui.Image> _decodeThumbnailImage(Uint8List bytes) async {
    final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(
      bytes,
    );
    try {
      final ui.ImageDescriptor descriptor = await ui.ImageDescriptor.encoded(
        buffer,
      );
      final bool isWideSpread =
          descriptor.width > 0 &&
              descriptor.height > 0 &&
              descriptor.width > descriptor.height;
      final int sourceWidth = isWideSpread
          ? math.max(1, descriptor.width ~/ 2)
          : descriptor.width;
      final _CoverSize target = _fitCover(sourceWidth, descriptor.height);

      final ui.Codec codec;
      try {
        // The codec keeps its own reference to the descriptor.
        codec = await descriptor.instantiateCodec(
          targetWidth: isWideSpread ? target.width * 2 : target.width,
          targetHeight: target.height,
        );
      } catch (_) {
        descriptor.dispose();
        rethrow;
      }

      try {
        final ui.FrameInfo frame = await codec.getNextFrame();
        final ui.Image decoded = frame.image;
        if (!isWideSpread) return decoded;

        try {
          final ui.PictureRecorder recorder = ui.PictureRecorder();
          final ui.Canvas canvas = ui.Canvas(recorder);
          final double srcLeft = decoded.width / 2.0;
          canvas.drawImageRect(
            decoded,
            ui.Rect.fromLTWH(
              srcLeft,
              0,
              decoded.width - srcLeft,
              decoded.height.toDouble(),
            ),
            ui.Rect.fromLTWH(
              0,
              0,
              target.width.toDouble(),
              target.height.toDouble(),
            ),
            ui.Paint()..filterQuality = ui.FilterQuality.high,
          );
          final ui.Picture picture = recorder.endRecording();
          try {
            return await picture.toImage(target.width, target.height);
          } finally {
            picture.dispose();
          }
        } finally {
          decoded.dispose();
        }
      } finally {
        codec.dispose();
      }
    } finally {
      buffer.dispose();
    }
  }

  /// Decodes at the bounded thumbnail size and re-encodes it compactly.
  ///
  /// On Android the raw RGBA pixels go to the native JPEG encoder
  /// (`compressThumbnail` in MainActivity.kt, quality 82, typically 15-25 KB).
  /// Anywhere else, or if that call fails (e.g. no platform channel in
  /// widget/unit tests), the thumbnail is encoded as lossless PNG instead.
  /// Decoding and encoding run on engine/native worker threads, not the UI
  /// isolate.
  static Future<({Uint8List bytes, String ext})> _encodeThumbnail(
      Uint8List bytes,
      ) async {
    final ui.Image image = await _decodeThumbnailImage(bytes);
    try {
      if (Platform.isAndroid) {
        try {
          final ByteData? rgba = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          if (rgba != null) {
            final Uint8List? compressed =
            await _safChannel.invokeMethod<Uint8List>(
              'compressThumbnail',
              <String, Object>{
                'rgba': rgba.buffer.asUint8List(
                  rgba.offsetInBytes,
                  rgba.lengthInBytes,
                ),
                'width': image.width,
                'height': image.height,
                'quality': 88,
              },
            );
            if (compressed != null && compressed.isNotEmpty) {
              return (bytes: compressed, ext: 'jpg');
            }
          }
        } catch (e) {
          debugPrint('ComicCoverService: JPEG encode unavailable, using PNG: $e');
        }
      }

      final ByteData? png = await image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      if (png == null) throw StateError('PNG encoding returned no data');
      return (
      bytes: png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
      ext: 'png',
      );
    } finally {
      image.dispose();
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
