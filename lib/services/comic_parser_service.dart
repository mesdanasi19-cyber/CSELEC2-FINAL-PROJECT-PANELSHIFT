import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:io' as io; // io.ZLibDecoder: unambiguous next to package:archive
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart'
    show BackgroundIsolateBinaryMessenger, MethodChannel, RootIsolateToken;
import 'package:rar/rar.dart';

import 'comic_cache_service.dart';
import 'comic_identity.dart';
import 'comic_page_source.dart';
import 'isolate_rpc.dart';

enum ComicArchiveFormat { zip, rar, unknown }

// =============================================================================
// Random-access byte readers (filesystem path or Android SAF content:// URI)
// =============================================================================

const String _safChannelName = 'panelshift/saf_picker';

/// Positional, read-only access to an archive's bytes, so the same parsing code
/// can read a regular file or a `content://` document without copying it.
abstract class RandomAccessByteReader {
  /// Total size of the source in bytes.
  Future<int> length();

  /// Up to [length] bytes starting at [offset]; shorter only at end of source.
  Future<Uint8List> readAt(int offset, int length);

  Future<void> close();

  /// [SafUriByteReader] for `content://` sources, [FileByteReader] otherwise.
  static RandomAccessByteReader forPath(String sourcePath) =>
      sourcePath.startsWith('content://')
      ? SafUriByteReader(sourcePath)
      : FileByteReader(sourcePath);
}

/// [RandomAccessByteReader] over a normal filesystem path.
class FileByteReader implements RandomAccessByteReader {
  FileByteReader(this.path);

  final String path;

  Future<RandomAccessFile>? _opening;
  Future<void> _queue = Future<void>.value();

  Future<RandomAccessFile> _file() => _opening ??= File(path).open();

  // setPosition + read must not interleave between concurrent callers.
  Future<T> _serial<T>(Future<T> Function() action) {
    final Future<T> result = _queue.then<T>((_) => action());
    _queue = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  @override
  Future<int> length() =>
      _serial<int>(() async => (await _file()).length());

  @override
  Future<Uint8List> readAt(int offset, int length) =>
      _serial<Uint8List>(() async {
        final RandomAccessFile raf = await _file();
        await raf.setPosition(offset);
        return raf.read(length);
      });

  @override
  Future<void> close() async {
    final Future<RandomAccessFile>? opening = _opening;
    _opening = null;
    if (opening == null) return;
    try {
      await _queue;
      await (await opening).close();
    } catch (_) {
      // Already closed or never opened.
    }
  }
}

/// Name, size and fingerprint of a SAF document, from `statAndHashUri`.
class SafUriStat {
  const SafUriStat({
    required this.fileName,
    required this.size,
    required this.md5Prefix,
  });

  final String fileName;
  final int size;

  /// Lowercase hex MD5 of the first 64 KB (same bytes `ComicIdentity.fromFile`
  /// hashes).
  final String md5Prefix;
}

/// [RandomAccessByteReader] over an Android `content://` URI, through the
/// `readUriRange` / `statAndHashUri` calls of `panelshift/saf_picker`. Safe to
/// use from a background isolate once
/// `BackgroundIsolateBinaryMessenger.ensureInitialized` has run there.
class SafUriByteReader implements RandomAccessByteReader {
  SafUriByteReader(this.uri);

  static const MethodChannel _channel = MethodChannel(_safChannelName);

  final String uri;
  int? _length;

  /// Null when the document is missing or no longer readable.
  static Future<SafUriStat?> stat(String uri) async {
    final Map<String, dynamic>? reply = await _channel
        .invokeMapMethod<String, dynamic>(
          'statAndHashUri',
          <String, Object?>{'uri': uri},
        );
    if (reply == null || reply['exists'] != true) return null;
    final Object? size = reply['size'];
    final Object? md5 = reply['md5Prefix'];
    if (size is! num || md5 is! String) return null;
    return SafUriStat(
      fileName: (reply['fileName'] as String?) ?? '',
      size: size.toInt(),
      md5Prefix: md5,
    );
  }

  /// Stages the document as a real file in the app cache (`copyDocumentToCache`)
  /// and returns its path. Only for archives that need a POSIX path (.cbr/.rar);
  /// the caller must delete the file when done.
  static Future<String> copyToCache(String uri, String name) async {
    final String? path = await _channel.invokeMethod<String>(
      'copyDocumentToCache',
      <String, Object?>{'uri': uri, 'name': name},
    );
    if (path == null || path.isEmpty) {
      throw FileSystemException('Could not stage the archive for extraction', uri);
    }
    return path;
  }

  @override
  Future<int> length() async {
    final int? cached = _length;
    if (cached != null) return cached;
    final SafUriStat? info = await stat(uri);
    if (info == null) {
      throw FileSystemException('Document is missing or unreadable', uri);
    }
    return _length = info.size;
  }

  @override
  Future<Uint8List> readAt(int offset, int length) async {
    if (length <= 0) return Uint8List(0);
    final Uint8List? data = await _channel.invokeMethod<Uint8List>(
      'readUriRange',
      <String, Object?>{'uri': uri, 'offset': offset, 'length': length},
    );
    if (data == null) {
      throw FileSystemException('Could not read from document', uri);
    }
    return data;
  }

  @override
  Future<void> close() async {}
}

/// Boot argument for the CBZ worker: the root isolate token it needs to use
/// platform channels, only when the archive is a `content://` document.
Object? _workerBootArg(String sourcePath) =>
    sourcePath.startsWith('content://') ? RootIsolateToken.instance : null;

/// Byte length of a path or `content://` source; throws [FileSystemException]
/// when it is missing.
Future<int> _sourceLength(String sourcePath) async {
  if (!sourcePath.startsWith('content://')) return File(sourcePath).length();
  final SafUriStat? info = await SafUriByteReader.stat(sourcePath);
  if (info == null) {
    throw FileSystemException('Document is missing or unreadable', sourcePath);
  }
  return info.size;
}

/// Optional capability of a [ComicPageSource]: measure a contiguous range of
/// pages from their image headers only, without decoding or fully reading them.
///
/// The reader uses it to probe the pages around the reading position first and
/// the rest in small, throttled batches, instead of one all-pages sweep.
abstract class PageDimensionProbe {
  /// Dimensions of pages `[start, start + count)`; null where a header could not
  /// be parsed. The list always has exactly [count] entries.
  Future<List<PageDimensions?>> probeDimensions(int start, int count);
}

/// Result of opening a comic file.
///
/// Opening builds the page index; page bytes are read lazily through [source].
/// Call [close] when the reader is dismissed.
class LoadedComic {
  LoadedComic({
    required this.source,
    required this.identity,
    this.cacheKey,
    this.retainCache = false,
  });

  final ComicPageSource source;
  final ComicIdentity identity;
  final String? cacheKey;

  /// When true, [close] keeps the extracted CBR folder (flagged as retained, so
  /// the next open skips the RAR extraction) instead of deleting it. The folder
  /// is still subject to [ComicCacheService.maxCacheBytes] eviction.
  final bool retainCache;

  Future<void>? _closeFuture;

  /// Idempotently disposes the page source and always releases its CBR cache.
  Future<void> close() => _closeFuture ??= _closeInternal();

  Future<void> _closeInternal() async {
    try {
      await source.dispose();
    } finally {
      final String? key = cacheKey;
      if (key != null) {
        await ComicCacheService.instance.release(key, keep: retainCache);
      }
    }
  }
}

class ComicParserService {
  ComicParserService._();

  /// The RAR plugin currently exposes no cancellation handle. This timeout
  /// bounds how long the UI waits; the cache lease is retained until the
  /// underlying native/plugin Future settles, preventing deletion while it may
  /// still be writing. Pass null to disable the timeout for unusually large
  /// archives or slow storage.
  static const Duration defaultRarExtractionTimeout = Duration(minutes: 10);
  static const Duration defaultArchiveIndexTimeout = Duration(minutes: 2);

  static int _cacheAttemptSequence = 0;

  /// Returns a new list of [items] in natural filename order ("Issue 2" before
  /// "Issue 10", case-insensitive), using the same comparison that orders an
  /// archive's pages. Keys are built once per item, so it is cheap for the long
  /// file lists produced by a folder import. [items] is not modified.
  static List<T> sortNaturally<T>(List<T> items, String Function(T item) nameOf) =>
      _sortNaturally<T>(items, nameOf);

  /// True for a loose page image (.jpg/.jpeg/.png/.webp) at any depth of an
  /// archive path. Hidden entries and OS metadata folders/files are rejected,
  /// exactly as when pages are indexed. Used by `.zip` pack import.
  static bool isPageImagePath(String path) => _isPageImage(path);

  /// True for a nested comic archive (.cbz/.cbr/.zip/.rar) at any depth of an
  /// archive path, with the same hidden/metadata filtering as [isPageImagePath].
  static bool isComicArchivePath(String path) {
    final String? extension = _visibleEntryExtension(path);
    return extension != null && _comicArchiveExtensions.contains(extension);
  }

  /// Archive entry path with '\\' turned into '/' and repeated slashes merged.
  static String normalizeEntryPath(String path) =>
      _normalizeArchiveEntryPath(path);

  /// Opens a .cbz/.zip/.cbr/.rar file or `content://` document (read in place,
  /// never copied; only .cbr/.rar is staged briefly for extraction). The format
  /// is detected from its magic
  /// bytes, with the extension used only when the header is unrecognised.
  ///
  /// The page index is cached by comic id ([ComicCacheService.readIndexCache]),
  /// so renamed or moved files keep it while modified files miss automatically:
  ///  * .cbz: a cached index is hydrated directly (one small JSON read, no
  ///    archive parsing). The page-reader isolate is started in the background
  ///    and is not on the open path.
  ///  * .cbr: a cached index is used only if its extracted folder is still in
  ///    `panelshift_cbr_cache` with every page; otherwise the archive is fully
  ///    extracted up front exactly as before and the index is refreshed.
  ///
  /// [retainCbrCache] keeps a freshly extracted CBR folder after
  /// [LoadedComic.close] so the next open is instant. Callers that only peek at
  /// a comic (thumbnails) should leave it false.
  static Future<LoadedComic> loadComic(
    String filePath, {
    Duration? rarExtractionTimeout = defaultRarExtractionTimeout,
    Duration? archiveIndexTimeout = defaultArchiveIndexTimeout,
    bool retainCbrCache = false,
  }) => _loadComic(
    filePath,
    rarExtractionTimeout: rarExtractionTimeout,
    archiveIndexTimeout: archiveIndexTimeout,
    retainCbrCache: retainCbrCache,
    waitForIndexJob: true,
  );

  static Future<LoadedComic> _loadComic(
    String filePath, {
    required Duration? rarExtractionTimeout,
    required Duration? archiveIndexTimeout,
    required bool retainCbrCache,
    required bool waitForIndexJob,
  }) async {
    final Future<ComicIdentity> identityFuture = identityFor(filePath);
    final Future<ComicArchiveFormat> formatFuture = detectFormat(filePath);

    final List<Object> both = await Future.wait<Object>(<Future<Object>>[
      identityFuture,
      formatFuture,
    ]);
    final ComicIdentity identity = both[0] as ComicIdentity;
    final ComicArchiveFormat format = both[1] as ComicArchiveFormat;
    // For a content:// source the size is already known from the identity stat
    // (it is part of the id), so later steps need no second platform call.
    final int? knownLength = _knownLengthOf(filePath, identity);

    // A background pre-index of this very comic is already doing the work the
    // open would do. Wait for it instead of duplicating it (never fails the open).
    if (waitForIndexJob) {
      final Future<void>? running = _indexJobs[identity.id];
      if (running != null) {
        try {
          await running;
        } catch (_) {}
      }
    }

    final ComicCacheService cache = ComicCacheService.instance;
    final Map<String, dynamic>? index = await cache.readIndexCache(identity.id);

    if (format == ComicArchiveFormat.rar) {
      final LoadedComic? cached = await _hydrateCbr(cache, identity, index);
      if (cached != null) return cached;

      // Each extraction gets a distinct folder. A timed-out native operation
      // may finish late; it must never collide with a subsequent open of the
      // same comic identity.
      final String extractionKey = _newExtractionKey(identity.id);
      final ComicPageSource source = await openCbr(
        filePath,
        cacheKey: extractionKey,
        extractionTimeout: rarExtractionTimeout,
        indexingTimeout: archiveIndexTimeout,
      );
      if (retainCbrCache && source is FilePageSource) {
        unawaited(_persistCbrIndex(cache, identity.id, extractionKey, source));
      }
      return LoadedComic(
        source: source,
        identity: identity,
        cacheKey: extractionKey,
        retainCache: retainCbrCache,
      );
    }

    final ZipPageSource? cachedZip = await _hydrateZip(
      cache,
      filePath,
      identity,
      index,
      knownLength: knownLength,
    );
    if (cachedZip != null) {
      return LoadedComic(source: cachedZip, identity: identity);
    }

    final ZipPageSource source = await ZipPageSource.open(
      filePath,
      knownLength: knownLength,
    );
    unawaited(_persistZipIndex(cache, identity.id, source));
    return LoadedComic(source: source, identity: identity);
  }

  // ---------------------------------------------------------------------------
  // Index cache: hydrate / persist
  // ---------------------------------------------------------------------------

  /// Rebuilds a [ZipPageSource] from the stored index. Requires the archive to
  /// still exist at [filePath] with the length it had when it was indexed.
  /// Costs one stat plus the JSON decode already done by the caller.
  static Future<ZipPageSource?> _hydrateZip(
    ComicCacheService cache,
    String filePath,
    ComicIdentity identity,
    Map<String, dynamic>? index, {
    int? knownLength,
  }) async {
    final Object? raw = index?['source'];
    if (raw is! Map<String, dynamic> || raw['type'] != 'zip') return null;

    final ZipPageSource? source = ZipPageSource.fromJson(raw, filePath);
    if (source == null || source.pageCount <= 0) return null;

    final int actualLength;
    try {
      actualLength = knownLength ?? await _sourceLength(filePath);
    } on FileSystemException {
      return null;
    }
    if (actualLength != source.indexedFileLength) return null;

    source.onIndexStale = () => unawaited(cache.deleteIndexCache(identity.id));
    source.onIndexRefreshed = () =>
        unawaited(_persistZipIndex(cache, identity.id, source));
    unawaited(source.warmUp());
    return source;
  }

  /// Re-opens a retained extraction folder when it is intact. Returns null (and
  /// removes a damaged folder) so the caller falls back to a normal extraction.
  static Future<LoadedComic?> _hydrateCbr(
    ComicCacheService cache,
    ComicIdentity identity,
    Map<String, dynamic>? index,
  ) async {
    final Object? raw = index?['source'];
    if (raw is! Map<String, dynamic> || raw['type'] != 'cbr') return null;
    final Object? storedRoot = raw['root'];
    if (storedRoot is! String || storedRoot.isEmpty) return null;

    final String key = storedRoot.split(RegExp(r'[\\/]')).last;
    final Directory? dir = await cache.acquireRetained(key);
    if (dir == null) return null; // Evicted, unfinished or in use elsewhere.

    bool usable = false;
    try {
      // Use the live path of the folder, not the stored one: the app's
      // temporary directory can move between installs/restores.
      final FilePageSource? source = FilePageSource.fromJson(raw, dir.path);
      if (source != null && source.pageCount > 0) {
        final int onDisk = await _countPageFiles(dir.path);
        if (onDisk == source.pageCount) {
          usable = true;
          return LoadedComic(
            source: source,
            identity: identity,
            cacheKey: key,
            retainCache: true,
          );
        }
      }
      return null;
    } catch (error) {
      debugPrint('ComicParserService: retained folder unusable: $error');
      return null;
    } finally {
      // A folder that no longer matches its index is deleted, not retained.
      if (!usable) await cache.release(key, keep: false);
    }
  }

  static Future<void> _persistZipIndex(
    ComicCacheService cache,
    String comicId,
    ZipPageSource source,
  ) async {
    final Map<String, dynamic>? json = source.toJson();
    if (json == null) return; // Fallback decoder: no reusable offsets.
    await cache.mergeIndexCache(comicId, <String, dynamic>{
      'pageCount': source.pageCount,
      'source': json,
    });
  }

  static Future<void> _persistCbrIndex(
    ComicCacheService cache,
    String comicId,
    String cacheKey,
    FilePageSource source,
  ) async {
    // Marker first: a folder that is indexed must also survive an app restart.
    await cache.markRetained(cacheKey);
    await cache.mergeIndexCache(comicId, <String, dynamic>{
      'pageCount': source.pageCount,
      'source': source.toJson(),
    });
  }

  // ---------------------------------------------------------------------------
  // Background pre-indexing
  // ---------------------------------------------------------------------------

  static final Map<String, Future<void>> _indexJobs = <String, Future<void>>{};

  /// Pages measured per micro-batch, and the pause between batches.
  static const int preIndexBatchPages = 8;
  static const Duration preIndexBatchPause = Duration(milliseconds: 40);

  /// Archives larger than this are not unpacked in the background; they are
  /// extracted when the user opens them.
  static const int preIndexMaxCbrBytes = 200 * 1024 * 1024;

  /// Builds and stores the page index and every page's dimensions of one comic
  /// so a later [loadComic] and the reader open without any header I/O.
  ///
  /// Low priority by design: sequential, 8 pages per micro-batch, a pause
  /// between batches, and [gate] is awaited before each batch (the caller can
  /// hold work back while a reader is on screen). Concurrent [loadComic] calls
  /// for the same comic wait for this job instead of repeating it. Never throws.
  ///
  /// [extractCbr] is off by default: indexing a .cbr/.rar means unpacking the
  /// whole archive into the CBR cache, so it is skipped here and happens on
  /// first open instead. .cbz/.zip archives are indexed from their headers
  /// only, which costs a tiny JSON file.
  static Future<void> preIndex(
    String filePath, {
    bool extractCbr = false,
    Future<void> Function()? gate,
  }) async {
    try {
      final ComicIdentity identity = await identityFor(filePath);
      final Future<void>? running = _indexJobs[identity.id];
      if (running != null) {
        await running;
        return;
      }

      final Future<void> job = _preIndex(
        filePath,
        identity,
        extractCbr: extractCbr,
        gate: gate,
      );
      _indexJobs[identity.id] = job;
      try {
        await job;
      } finally {
        _indexJobs.remove(identity.id);
      }
    } catch (error) {
      debugPrint('ComicParserService.preIndex failed for $filePath: $error');
    }
  }

  static Future<void> _preIndex(
    String filePath,
    ComicIdentity identity, {
    required bool extractCbr,
    required Future<void> Function()? gate,
  }) async {
    final ComicCacheService cache = ComicCacheService.instance;
    if (_hasCompleteDimensions(await cache.readIndexCache(identity.id))) return;

    if (await detectFormat(filePath) == ComicArchiveFormat.rar) {
      if (!extractCbr) return;
      if (await _sourceLength(filePath) > preIndexMaxCbrBytes) return;
    }

    final LoadedComic loaded = await _loadComic(
      filePath,
      rarExtractionTimeout: defaultRarExtractionTimeout,
      archiveIndexTimeout: defaultArchiveIndexTimeout,
      retainCbrCache: true,
      waitForIndexJob: false,
    );
    try {
      final Object source = loaded.source;
      final int count = loaded.source.pageCount;
      if (count <= 0 || source is! PageDimensionProbe) return;

      final List<List<int>> dimensions = <List<int>>[];
      for (int start = 0; start < count; start += preIndexBatchPages) {
        if (gate != null) await gate();
        final int batch = math.min(preIndexBatchPages, count - start);
        final List<PageDimensions?> part = await source.probeDimensions(
          start,
          batch,
        );
        for (final PageDimensions? d in part) {
          dimensions.add(d == null ? <int>[0, 0] : <int>[d.width, d.height]);
        }
        await Future<void>.delayed(preIndexBatchPause);
      }

      await cache.mergeIndexCache(identity.id, <String, dynamic>{
        'pageCount': count,
        'dimensions': dimensions,
      });
    } finally {
      await loaded.close();
    }
  }

  static bool _hasCompleteDimensions(Map<String, dynamic>? index) {
    final Object? dims = index?['dimensions'];
    final Object? count = index?['pageCount'];
    if (dims is! List || count is! int || count <= 0) return false;
    if (dims.length != count) return false;
    for (final Object? pair in dims) {
      if (pair is! List || pair.length < 2) return false;
      final Object? w = pair[0];
      final Object? h = pair[1];
      if (w is! int || h is! int || w <= 0 || h <= 0) return false;
    }
    return true;
  }

  /// Identity of the comic at [sourcePath], a filesystem path or a `content://`
  /// URI. Both give the same id format, so progress and caches are shared.
  static Future<ComicIdentity> identityFor(String sourcePath) async {
    if (!sourcePath.startsWith('content://')) {
      return ComicIdentity.fromFile(sourcePath);
    }
    final SafUriStat? info = await SafUriByteReader.stat(sourcePath);
    if (info == null) {
      throw FileSystemException('Document is missing or unreadable', sourcePath);
    }
    return ComicIdentity.fromUri(
      uri: sourcePath,
      fileName: info.fileName.isEmpty ? 'Untitled comic' : info.fileName,
      fileSize: info.size,
      md5Prefix: info.md5Prefix,
    );
  }

  /// File size of a content:// source, read back from the identity id
  /// (`<md5>_<size>`); null for filesystem paths (they are cheap to stat).
  static int? _knownLengthOf(String sourcePath, ComicIdentity identity) {
    if (!sourcePath.startsWith('content://')) return null;
    final String id = identity.id;
    return int.tryParse(id.substring(id.lastIndexOf('_') + 1));
  }

  static String _newExtractionKey(String identity) {
    _cacheAttemptSequence++;
    return '${identity}_${DateTime.now().microsecondsSinceEpoch}_$_cacheAttemptSequence';
  }

  static Future<ComicArchiveFormat> detectFormat(String sourcePath) async {
    // First 8 bytes only: from the file, or from the SAF URI via readUriRange.
    final RandomAccessByteReader reader = RandomAccessByteReader.forPath(
      sourcePath,
    );
    try {
      final Uint8List head = await reader.readAt(0, 8);

      // ZIP: "PK\x03\x04" (also "PK\x05\x06" empty / "PK\x07\x08" spanned).
      if (head.length >= 4 &&
          head[0] == 0x50 &&
          head[1] == 0x4B &&
          (head[2] == 0x03 || head[2] == 0x05 || head[2] == 0x07)) {
        return ComicArchiveFormat.zip;
      }

      // RAR4: "Rar!\x1A\x07\x00"; RAR5: "Rar!\x1A\x07\x01\x00".
      if (head.length >= 7 &&
          head[0] == 0x52 &&
          head[1] == 0x61 &&
          head[2] == 0x72 &&
          head[3] == 0x21 &&
          head[4] == 0x1A &&
          head[5] == 0x07) {
        return ComicArchiveFormat.rar;
      }
    } finally {
      await reader.close();
    }

    final String lower = sourcePath.toLowerCase();
    if (lower.endsWith('.cbr') || lower.endsWith('.rar')) {
      return ComicArchiveFormat.rar;
    }
    return ComicArchiveFormat.zip;
  }

  // ---------------------------------------------------------------------------
  // CBR (RAR)
  // ---------------------------------------------------------------------------

  /// Extracts [filePath] (a path or a `content://` URI, which is staged to a
  /// temporary file that is always deleted afterwards) into the cache and
  /// returns a lazy disk-backed source.
  ///
  /// When the plugin or page-index isolate exceeds its timeout, this method
  /// returns an error to the caller immediately. Because neither operation
  /// exposes cancellation, cleanup is attached to the original Future and is
  /// performed when that operation actually settles.
  static Future<ComicPageSource> openCbr(
    String filePath, {
    required String cacheKey,
    Duration? extractionTimeout = defaultRarExtractionTimeout,
    Duration? indexingTimeout = defaultArchiveIndexTimeout,
  }) async {
    _validateOptionalTimeout(extractionTimeout, 'extractionTimeout');
    _validateOptionalTimeout(indexingTimeout, 'indexingTimeout');

    final ComicCacheService cache = ComicCacheService.instance;
    final Directory workDir = await cache.acquire(cacheKey);
    bool cleanupDeferred = false;
    String? stagedPath;

    try {
      // The RAR plugin needs a real file. A content:// archive is staged into
      // the app cache just for the extraction and removed again in `finally`,
      // so no duplicate .cbr stays on disk.
      String archivePath = filePath;
      if (filePath.startsWith('content://')) {
        stagedPath = await SafUriByteReader.copyToCache(
          filePath,
          '$cacheKey.rar',
        );
        archivePath = stagedPath;
      }

      final Future<dynamic> extraction = Rar.extractRarFile(
        rarFilePath: archivePath,
        destinationPath: workDir.path,
      );

      dynamic result;
      try {
        result = extractionTimeout == null
            ? await extraction
            : await extraction.timeout(extractionTimeout);
      } on TimeoutException {
        cleanupDeferred = true;
        _releaseCacheWhenSettled(extraction, cache, cacheKey);
        rethrow;
      }

      if (result is! Map || result['success'] != true) {
        final Object? message = result is Map ? result['message'] : result;
        throw FileSystemException('RAR extraction failed: $message', filePath);
      }

      final String root = workDir.path;
      final Future<List<String>> indexing = _listPagesInIsolate(root);
      List<String> pages;
      try {
        pages = indexingTimeout == null
            ? await indexing
            : await indexing.timeout(indexingTimeout);
      } on TimeoutException {
        cleanupDeferred = true;
        _releaseCacheWhenSettled(indexing, cache, cacheKey);
        rethrow;
      }

      // Cache enforcement is best-effort and must not delay opening the reader.
      unawaited(cache.enforceLimit());
      return FilePageSource(root, pages);
    } catch (error, stackTrace) {
      if (!cleanupDeferred) {
        await cache.release(cacheKey);
      }
      Error.throwWithStackTrace(error, stackTrace);
    } finally {
      if (stagedPath != null) {
        try {
          await File(stagedPath).delete();
        } catch (_) {
          // Best effort; the picker cache is also swept by the OS.
        }
      }
    }
  }

  static void _validateOptionalTimeout(Duration? timeout, String name) {
    if (timeout != null && timeout <= Duration.zero) {
      throw ArgumentError.value(
        timeout,
        name,
        'Must be greater than zero or null',
      );
    }
  }

  /// Releases the cache only after an uncancellable operation has stopped
  /// accessing its directory. Both success and error paths perform cleanup.
  static void _releaseCacheWhenSettled<T>(
    Future<T> operation,
    ComicCacheService cache,
    String cacheKey,
  ) {
    unawaited(
      operation.then<void>(
        (_) async {
          await cache.release(cacheKey);
        },
        onError: (Object error, StackTrace stackTrace) async {
          await cache.release(cacheKey);
        },
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Legacy helpers (materialise every page; avoid in new code)
  // ---------------------------------------------------------------------------

  @Deprecated(
    'Loads every page into memory. Use ZipPageSource.open and read pages lazily.',
  )
  static Future<List<Uint8List>> extractCbzPages(String filePath) async {
    final ComicPageSource source = await ZipPageSource.open(filePath);
    try {
      return await _readAll(source);
    } finally {
      await source.dispose();
    }
  }

  @Deprecated(
    'Loads every page into memory. Use openCbr and read pages lazily.',
  )
  static Future<List<Uint8List>> extractCbrPages(
    String filePath, {
    required String cacheKey,
  }) async {
    final ComicPageSource source = await openCbr(filePath, cacheKey: cacheKey);
    try {
      return await _readAll(source);
    } finally {
      try {
        await source.dispose();
      } finally {
        await ComicCacheService.instance.release(cacheKey);
      }
    }
  }

  static Future<List<Uint8List>> _readAll(ComicPageSource source) async {
    final List<Uint8List> pages = <Uint8List>[];
    for (int i = 0; i < source.pageCount; i++) {
      pages.add(await source.readPage(i));
    }
    return pages;
  }
}

// =============================================================================
// CBZ: lazy reader backed by a worker isolate
// =============================================================================

const int _dimsChunk = 24;
const int _sniffBytes = 64 * 1024;

/// Compact page index of a ZIP archive: parallel arrays in reading order
/// (natural sort applied), one slot per page image. This is both the on-disk
/// JSON form and the wire form sent to the reader isolate.
class _ZipIndex {
  const _ZipIndex({
    required this.names,
    required this.offsets,
    required this.compressedSizes,
    required this.uncompressedSizes,
    required this.methods,
  });

  final List<String> names;
  final List<int> offsets; // localHeaderOffset
  final List<int> compressedSizes;
  final List<int> uncompressedSizes;
  final List<int> methods; // 0 = stored, 8 = deflate

  int get length => names.length;

  factory _ZipIndex.fromEntries(List<_ZipEntry> entries) => _ZipIndex(
    names: <String>[for (final _ZipEntry e in entries) e.name],
    offsets: <int>[for (final _ZipEntry e in entries) e.localHeaderOffset],
    compressedSizes: <int>[for (final _ZipEntry e in entries) e.compressedSize],
    uncompressedSizes: <int>[
      for (final _ZipEntry e in entries) e.uncompressedSize,
    ],
    methods: <int>[for (final _ZipEntry e in entries) e.method],
  );

  /// Validates untrusted JSON / wire data. Returns null for anything that is not
  /// a self-consistent index, so a damaged cache entry is simply a cache miss.
  static _ZipIndex? tryParse(
    Object? names,
    Object? offsets,
    Object? compressedSizes,
    Object? uncompressedSizes,
    Object? methods,
  ) {
    if (names is! List ||
        offsets is! List ||
        compressedSizes is! List ||
        uncompressedSizes is! List ||
        methods is! List) {
      return null;
    }
    final int count = names.length;
    if (count == 0 ||
        offsets.length != count ||
        compressedSizes.length != count ||
        uncompressedSizes.length != count ||
        methods.length != count) {
      return null;
    }

    try {
      final List<int> offsetList = <int>[for (final Object? v in offsets) v as int];
      final List<int> compressedList = <int>[
        for (final Object? v in compressedSizes) v as int,
      ];
      final List<int> uncompressedList = <int>[
        for (final Object? v in uncompressedSizes) v as int,
      ];
      final List<int> methodList = <int>[for (final Object? v in methods) v as int];
      for (int i = 0; i < count; i++) {
        if (offsetList[i] < 0 ||
            compressedList[i] < 0 ||
            uncompressedList[i] < 0 ||
            (methodList[i] != 0 && methodList[i] != 8)) {
          return null;
        }
      }
      return _ZipIndex(
        names: <String>[for (final Object? v in names) v as String],
        offsets: offsetList,
        compressedSizes: compressedList,
        uncompressedSizes: uncompressedList,
        methods: methodList,
      );
    } catch (_) {
      return null;
    }
  }

  List<_ZipEntry> toEntries() => <_ZipEntry>[
    for (int i = 0; i < length; i++)
      _ZipEntry(
        names[i],
        methods[i],
        compressedSizes[i],
        offsets[i],
        uncompressedSizes[i],
      ),
  ];

  List<Object?> toWire() => <Object?>[
    names,
    offsets,
    compressedSizes,
    uncompressedSizes,
    methods,
  ];
}

/// Reply of the worker's `open` operation: the page count and, when the fast
/// central-directory path was used, the page index.
class _OpenReply {
  const _OpenReply(this.count, this.index);

  final int count;
  final _ZipIndex? index;
}

_OpenReply? _parseOpenReply(Object? reply) {
  if (reply is int) return _OpenReply(reply, null);
  if (reply is! List || reply.isEmpty) return null;
  final Object? count = reply[0];
  if (count is! int) return null;
  if (reply.length < 6) return _OpenReply(count, null);
  final _ZipIndex? index = _ZipIndex.tryParse(
    reply[1],
    reply[2],
    reply[3],
    reply[4],
    reply[5],
  );
  return _OpenReply(count, index != null && index.length == count ? index : null);
}

class ZipPageSource implements ComicPageSource, PageDimensionProbe {
  ZipPageSource._({
    required this.pageCount,
    required String filePath,
    required int fileLength,
    IsolateRpc? rpc,
    _ZipIndex? index,
  }) : _filePath = filePath,
       _fileLength = fileLength,
       _rpc = rpc,
       _index = index;

  @override
  final int pageCount;

  final String _filePath;
  final int _fileLength;
  _ZipIndex? _index;

  // Null for a source hydrated from the index cache until its worker has been
  // started (see [_worker]); never replaced once set.
  IsolateRpc? _rpc;
  Future<IsolateRpc>? _workerFuture;

  bool _disposed = false;

  /// Called once if a cached index turns out not to match the archive, so the
  /// owner can drop the stale entry. The source itself heals by re-parsing.
  void Function()? onIndexStale;

  /// Called when a stale cached index was rebuilt from the archive so the
  /// owner can persist the updated offsets.
  void Function()? onIndexRefreshed;

  /// Length of the archive when this index was built (cache validation).
  int get indexedFileLength => _fileLength;

  static Future<ZipPageSource> open(String filePath, {int? knownLength}) async {
    final int length = knownLength ?? await _sourceLength(filePath);
    final IsolateRpc rpc = await IsolateRpc.spawn(
      _zipWorkerMain,
      _workerBootArg(filePath),
      debugName: 'cbz-reader',
    );

    try {
      final Object? reply = await rpc.callWithTimeout<Object>(
        'open',
        args: filePath,
      );
      final _OpenReply? parsed = _parseOpenReply(reply);
      if (parsed == null || parsed.count < 0) {
        throw const FormatException(
          'ZIP worker returned an invalid page count',
        );
      }
      return ZipPageSource._(
        pageCount: parsed.count,
        filePath: filePath,
        fileLength: length,
        rpc: rpc,
        index: parsed.index,
      );
    } catch (_) {
      await rpc.dispose();
      rethrow;
    }
  }

  /// Serialises the page index: sorted entry names plus, per page,
  /// `localHeaderOffset`, `compressedSize`, `uncompressedSize` and
  /// `compressionMethod` as parallel arrays. Null when the archive needed the
  /// full ZIP decoder (ZIP64, encrypted...), which has no reusable offsets.
  Map<String, dynamic>? toJson() {
    final _ZipIndex? index = _index;
    if (index == null) return null;
    return <String, dynamic>{
      'type': 'zip',
      'length': _fileLength,
      'names': index.names,
      'offsets': index.offsets,
      'csizes': index.compressedSizes,
      'usizes': index.uncompressedSizes,
      'methods': index.methods,
    };
  }

  /// Rebuilds a source from [toJson] output for the archive now at [filePath]
  /// (it may have been renamed or moved). Costs no archive I/O and no isolate:
  /// the reader worker is started lazily, in the background. Returns null for
  /// anything that is not a valid index.
  static ZipPageSource? fromJson(Object? json, String filePath) {
    if (json is! Map<String, dynamic> || json['type'] != 'zip') return null;
    final Object? length = json['length'];
    if (length is! int || length < 0) return null;
    final _ZipIndex? index = _ZipIndex.tryParse(
      json['names'],
      json['offsets'],
      json['csizes'],
      json['usizes'],
      json['methods'],
    );
    if (index == null) return null;
    return ZipPageSource._(
      pageCount: index.length,
      filePath: filePath,
      fileLength: length,
      index: index,
    );
  }

  /// Starts the reader isolate ahead of the first page read. Never throws; a
  /// real failure resurfaces from the read that needs the worker.
  Future<void> warmUp() async {
    try {
      await _worker();
    } catch (_) {}
  }

  Future<IsolateRpc> _worker() {
    final IsolateRpc? ready = _rpc;
    if (ready != null) return Future<IsolateRpc>.value(ready);

    final Future<IsolateRpc>? pending = _workerFuture;
    if (pending != null) return pending;

    final Future<IsolateRpc> future = _spawnAttached();
    _workerFuture = future;
    future.then<void>(
      (_) {},
      onError: (Object _) {
        // Allow a later call to retry instead of caching the failure.
        if (identical(_workerFuture, future)) _workerFuture = null;
      },
    );
    return future;
  }

  /// Spawns the worker and hands it the cached index, so it only opens the file
  /// (no central-directory parse, no sorting). If the archive no longer matches
  /// the index, the worker parses it from scratch and [onIndexStale] fires.
  Future<IsolateRpc> _spawnAttached() async {
    final _ZipIndex index = _index!;
    final IsolateRpc rpc = await IsolateRpc.spawn(
      _zipWorkerMain,
      _workerBootArg(_filePath),
      debugName: 'cbz-reader',
    );

    try {
      int? count;
      try {
        count = await rpc.callWithTimeout<int>(
          'attach',
          args: <Object?>[_filePath, ...index.toWire()],
        );
      } catch (_) {
        count = null;
      }
      if (count == null) {
        // Only drop the cached entry when the worker is still alive and
        // actively rejected the offsets (not on a timeout or worker crash).
        if (!rpc.isClosed) onIndexStale?.call();
        final Object? reply = await rpc.callWithTimeout<Object>(
          'open',
          args: _filePath,
        );
        final _OpenReply? parsed = _parseOpenReply(reply);
        count = parsed?.count;
        if (count == pageCount && parsed?.index != null) {
          _index = parsed!.index;
          onIndexRefreshed?.call();
        }
      }
      if (count != pageCount) {
        throw const FormatException('ZIP index no longer matches the archive');
      }
      _rpc = rpc;
      return rpc;
    } catch (_) {
      await rpc.dispose();
      rethrow;
    }
  }

  @override
  Future<Uint8List> readPage(int index) async {
    if (_disposed) throw StateError('ZIP page source is disposed');
    if (index < 0 || index >= pageCount) {
      throw RangeError.range(index, 0, pageCount - 1, 'index');
    }

    final IsolateRpc rpc = await _worker();
    final TransferableTypedData? data = await rpc
        .callWithTimeout<TransferableTypedData>('read', args: index);
    if (data == null) {
      throw StateError('Worker returned no data for page $index');
    }
    return data.materialize().asUint8List();
  }

  @override
  Future<List<PageDimensions?>> probeDimensions(int start, int count) async {
    if (_disposed) throw StateError('ZIP page source is disposed');
    if (start < 0 || count < 0 || start + count > pageCount) {
      throw RangeError('Invalid dimensions range: $start + $count of $pageCount');
    }
    if (count == 0) return const <PageDimensions?>[];

    final IsolateRpc rpc = await _worker();
    final Int32List? part = await rpc.callWithTimeout<Int32List>(
      'dims',
      args: <int>[start, count],
    );
    if (part == null || part.length != count * 2) {
      throw const FormatException('ZIP worker returned invalid dimensions');
    }
    return _decodeDims(part);
  }

  @override
  Future<List<PageDimensions?>> readAllDimensions() async {
    if (_disposed) throw StateError('ZIP page source is disposed');

    final List<PageDimensions?> out = <PageDimensions?>[];
    for (int start = 0; start < pageCount; start += _dimsChunk) {
      final int count = math.min(_dimsChunk, pageCount - start);
      out.addAll(await probeDimensions(start, count));
    }
    return out;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;

    IsolateRpc? rpc = _rpc;
    if (rpc == null) {
      // A hydrated source whose worker is still starting: wait for it so it can
      // be shut down instead of leaking. No worker at all means nothing to do.
      final Future<IsolateRpc>? pending = _workerFuture;
      if (pending != null) {
        try {
          rpc = await pending;
        } catch (_) {}
      }
    }
    if (rpc == null) return;

    // Ask the worker to close its RandomAccessFile before terminating it.
    // If the worker is already dead or unresponsive, dispose still kills it.
    try {
      await rpc.callWithTimeout<Object?>(
        'close',
        timeout: const Duration(seconds: 3),
      );
    } catch (_) {
      // Disposal is best-effort; the host-side controller still terminates it.
    } finally {
      await rpc.dispose();
    }
  }
}

class _ZipEntry {
  const _ZipEntry(
    this.name,
    this.method,
    this.compressedSize,
    this.localHeaderOffset,
    this.uncompressedSize,
  );

  final String name;
  final int method; // 0 = stored, 8 = deflate
  final int compressedSize;
  final int localHeaderOffset;
  final int uncompressedSize;
}

void _zipWorkerMain(List<Object?> boot) {
  // A content:// archive is read through the platform channel, which a
  // background isolate may only use after this call.
  final Object? init = boot.length > 1 ? boot[1] : null;
  if (init is RootIsolateToken) {
    BackgroundIsolateBinaryMessenger.ensureInitialized(init);
  }
  final _ZipWorker worker = _ZipWorker();
  serveRpc(boot[0] as SendPort, worker.handle);
}

class _ZipWorker {
  // content:// mode: the archive is read through [_reader] (async). File mode
  // keeps the original synchronous RandomAccessFile code path untouched.
  bool _asyncMode = false;
  RandomAccessByteReader? _reader;

  RandomAccessFile? _raf;
  List<_ZipEntry> _entries = const <_ZipEntry>[];
  bool _useFallback = false;
  List<ArchiveFile> _fallback = const <ArchiveFile>[];

  Object? handle(String op, Object? args) {
    switch (op) {
      case 'open':
        final String openPath = args as String;
        return openPath.startsWith('content://')
            ? _openSaf(openPath)
            : _open(openPath);
      case 'attach':
        final List<dynamic> wire = args as List<dynamic>;
        final String attachPath = wire[0] as String;
        return attachPath.startsWith('content://')
            ? _attachSaf(attachPath, wire.sublist(1))
            : _attach(attachPath, wire.sublist(1));
      case 'read':
        return _asyncMode ? _readAsync(args as int) : _read(args as int);
      case 'dims':
        final List<dynamic> range = args as List<dynamic>;
        if (range.length != 2) {
          throw const FormatException('Invalid dimensions request');
        }
        return _asyncMode
            ? _dimsAsync(range[0] as int, range[1] as int)
            : _dims(range[0] as int, range[1] as int);
      case 'close':
        _close();
        return null;
      default:
        throw ArgumentError.value(op, 'op', 'Unknown operation');
    }
  }

  void _close() {
    final RandomAccessFile? raf = _raf;
    _raf = null;
    _entries = const <_ZipEntry>[];
    _fallback = const <ArchiveFile>[];
    _useFallback = false;
    _asyncMode = false;
    final RandomAccessByteReader? reader = _reader;
    _reader = null;
    if (reader != null) unawaited(reader.close());
    if (raf != null) {
      try {
        raf.closeSync();
      } catch (_) {
        // The handle may already have been closed by the OS.
      }
    }
  }

  /// Opens the archive from an index cached by an earlier `open`: only the file
  /// handle is created. The local headers of the first and last page are checked
  /// so an index that no longer matches the bytes fails fast (the host then
  /// falls back to a full `open`).
  int _attach(String path, List<dynamic> wire) {
    _close();
    if (wire.length < 5) throw const FormatException('Invalid ZIP index');
    final _ZipIndex? index = _ZipIndex.tryParse(
      wire[0],
      wire[1],
      wire[2],
      wire[3],
      wire[4],
    );
    if (index == null) throw const FormatException('Invalid ZIP index');

    final List<_ZipEntry> entries = index.toEntries();
    final RandomAccessFile raf = File(path).openSync();
    try {
      _dataStart(raf, entries.first);
      _dataStart(raf, entries.last);
    } catch (_) {
      try {
        raf.closeSync();
      } catch (_) {}
      rethrow;
    }
    _raf = raf;
    _entries = entries;
    return entries.length;
  }

  List<Object?> _openReply() {
    final _ZipIndex index = _ZipIndex.fromEntries(_entries);
    return <Object?>[
      _entries.length,
      index.names,
      index.offsets,
      index.compressedSizes,
      index.uncompressedSizes,
      index.methods,
    ];
  }

  Object _open(String path) {
    _close();

    final RandomAccessFile raf = File(path).openSync();
    bool retainedHandle = false;
    List<_ZipEntry>? entries;
    try {
      entries = _readCentralDirectory(raf);
      if (entries != null) {
        _raf = raf;
        _entries = _sortNaturally<_ZipEntry>(
          entries,
          (_ZipEntry entry) => _normalizeArchiveEntryPath(entry.name),
        );
        retainedHandle = true;
        return _openReply();
      }
    } finally {
      if (!retainedHandle) {
        try {
          raf.closeSync();
        } catch (_) {
          // Preserve the original parsing exception, if any.
        }
      }
    }

    // ZIP64, encrypted, unsupported-compression and unusual layouts use the
    // complete decoder. This work remains inside the worker isolate.
    // `Archive.files` is a flat list of every ZIP entry, not just root files;
    // nested names such as "Chapter 01/page_2.webp" are therefore included.
    // Apply the same path-aware filter used by the central-directory reader so
    // both parsing paths discover exactly the same kinds of page images.
    return _openFallback(File(path).readAsBytesSync());
  }

  Object _openFallback(Uint8List bytes) {
    final Archive archive = ZipDecoder().decodeBytes(bytes);
    final List<ArchiveFile> files = <ArchiveFile>[];
    for (final ArchiveFile file in archive.files) {
      if (!file.isFile) continue; // Skip explicit directory entries.
      if (!_isPageImage(file.name)) continue;
      files.add(file);
    }
    _fallback = _sortNaturally<ArchiveFile>(
      files,
      (ArchiveFile file) => _normalizeArchiveEntryPath(file.name),
    );
    _useFallback = true;
    return <Object?>[_fallback.length];
  }

  TransferableTypedData _read(int index) {
    final int count = _useFallback ? _fallback.length : _entries.length;
    if (index < 0 || index >= count) {
      throw RangeError.range(index, 0, count - 1, 'index');
    }

    final Uint8List bytes = _useFallback
        ? Uint8List.fromList(_fallback[index].content as List<int>)
        : _readEntry(_raf!, _entries[index]);
    return TransferableTypedData.fromList(<TypedData>[bytes]);
  }

  Int32List _dims(int start, int count) {
    final int total = _useFallback ? _fallback.length : _entries.length;
    if (start < 0 || count < 0 || start + count > total) {
      throw RangeError(
        'Invalid dimensions range: start=$start count=$count total=$total',
      );
    }

    final Int32List out = Int32List(count * 2);
    for (int k = 0; k < count; k++) {
      PageDimensions? dimensions;
      try {
        dimensions = _useFallback
            ? ImageHeaderSniffer.sniff(
                Uint8List.fromList(_fallback[start + k].content as List<int>),
              )
            : _sniffEntry(_raf!, _entries[start + k]);
      } catch (_) {
        dimensions = null;
      }

      if (dimensions != null) {
        out[k * 2] = dimensions.width;
        out[k * 2 + 1] = dimensions.height;
      }
    }
    return out;
  }

  // --- content:// (SAF) variants: same logic, async reads -------------------

  Future<Object> _openSaf(String path) async {
    _close();
    final RandomAccessByteReader reader = SafUriByteReader(path);
    List<_ZipEntry>? entries;
    try {
      entries = await _readCentralDirectoryAsync(reader);
      if (entries != null) {
        _reader = reader;
        _asyncMode = true;
        _entries = _sortNaturally<_ZipEntry>(
          entries,
          (_ZipEntry entry) => _normalizeArchiveEntryPath(entry.name),
        );
        return _openReply();
      }

      // ZIP64 / encrypted / unusual layouts: full decoder, in this isolate.
      final Uint8List bytes = await _readWholeAsync(reader);
      final Object reply = _openFallback(bytes);
      _asyncMode = true;
      return reply;
    } finally {
      if (!identical(_reader, reader)) await reader.close();
    }
  }

  Future<int> _attachSaf(String path, List<dynamic> wire) async {
    _close();
    if (wire.length < 5) throw const FormatException('Invalid ZIP index');
    final _ZipIndex? index = _ZipIndex.tryParse(
      wire[0],
      wire[1],
      wire[2],
      wire[3],
      wire[4],
    );
    if (index == null) throw const FormatException('Invalid ZIP index');

    final List<_ZipEntry> entries = index.toEntries();
    final RandomAccessByteReader reader = SafUriByteReader(path);
    try {
      await _checkLocalHeaderAsync(reader, entries.first);
      await _checkLocalHeaderAsync(reader, entries.last);
    } catch (_) {
      await reader.close();
      rethrow;
    }
    _reader = reader;
    _asyncMode = true;
    _entries = entries;
    return entries.length;
  }

  Future<TransferableTypedData> _readAsync(int index) async {
    final int count = _useFallback ? _fallback.length : _entries.length;
    if (index < 0 || index >= count) {
      throw RangeError.range(index, 0, count - 1, 'index');
    }

    final Uint8List bytes;
    if (_useFallback) {
      bytes = Uint8List.fromList(_fallback[index].content as List<int>);
    } else {
      final RandomAccessByteReader? reader = _reader;
      if (reader == null) throw StateError('ZIP reader is closed');
      bytes = await _readEntryAsync(reader, _entries[index]);
    }
    return TransferableTypedData.fromList(<TypedData>[bytes]);
  }

  Future<Int32List> _dimsAsync(int start, int count) async {
    final int total = _useFallback ? _fallback.length : _entries.length;
    if (start < 0 || count < 0 || start + count > total) {
      throw RangeError(
        'Invalid dimensions range: start=$start count=$count total=$total',
      );
    }

    final RandomAccessByteReader? reader = _reader;
    final Int32List out = Int32List(count * 2);
    for (int k = 0; k < count; k++) {
      PageDimensions? dimensions;
      try {
        if (_useFallback) {
          dimensions = ImageHeaderSniffer.sniff(
            Uint8List.fromList(_fallback[start + k].content as List<int>),
          );
        } else if (reader != null) {
          dimensions = await _sniffEntryAsync(reader, _entries[start + k]);
        }
      } catch (_) {
        dimensions = null;
      }

      if (dimensions != null) {
        out[k * 2] = dimensions.width;
        out[k * 2 + 1] = dimensions.height;
      }
    }
    return out;
  }
}

// --- ZIP structure parsing --------------------------------------------------

int _u16(Uint8List bytes, int offset) =>
    bytes[offset] | (bytes[offset + 1] << 8);

int _u32(Uint8List bytes, int offset) =>
    bytes[offset] |
    (bytes[offset + 1] << 8) |
    (bytes[offset + 2] << 16) |
    (bytes[offset + 3] << 24);

/// Location of the central directory, from the end-of-central-directory record.
class _Eocd {
  const _Eocd(this.totalEntries, this.cdSize, this.cdOffset);

  final int totalEntries;
  final int cdSize;
  final int cdOffset;
}

/// Finds the EOCD record in [tail] (the last bytes of an archive of [length]
/// bytes). Returns null when the full decoder is needed (multi-disk, ZIP64,
/// inconsistent offsets) or no record exists.
_Eocd? _parseEocd(Uint8List tail, int length) {
  int eocd = -1;
  for (int i = tail.length - 22; i >= 0; i--) {
    if (tail[i] != 0x50 ||
        tail[i + 1] != 0x4B ||
        tail[i + 2] != 0x05 ||
        tail[i + 3] != 0x06) {
      continue;
    }
    final int commentLength = _u16(tail, i + 20);
    if (i + 22 + commentLength <= tail.length) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) return null;

  final int entriesOnDisk = _u16(tail, eocd + 8);
  final int totalEntries = _u16(tail, eocd + 10);
  final int cdSize = _u32(tail, eocd + 12);
  final int cdOffset = _u32(tail, eocd + 16);

  // Multi-disk archives and ZIP64 are delegated to package:archive.
  if (entriesOnDisk != totalEntries ||
      totalEntries == 0xFFFF ||
      cdSize == 0xFFFFFFFF ||
      cdOffset == 0xFFFFFFFF ||
      cdOffset < 0 ||
      cdSize < 0 ||
      cdOffset + cdSize > length) {
    return null;
  }
  return _Eocd(totalEntries, cdSize, cdOffset);
}

/// Parses the central directory. Returns null when the full decoder is needed.
List<_ZipEntry>? _readCentralDirectory(RandomAccessFile raf) {
  final int length = raf.lengthSync();
  if (length < 22) return null;

  final int tailLength = math.min(length, 22 + 0xFFFF);
  raf.setPositionSync(length - tailLength);
  final Uint8List tail = raf.readSync(tailLength);

  final _Eocd? eocd = _parseEocd(tail, length);
  if (eocd == null) return null;

  raf.setPositionSync(eocd.cdOffset);
  final Uint8List centralDirectory = raf.readSync(eocd.cdSize);
  if (centralDirectory.length != eocd.cdSize) return null;

  return _parseCentralDirectory(centralDirectory, eocd.totalEntries, length);
}

/// Same as [_readCentralDirectory], for any [RandomAccessByteReader] (used for
/// `content://` archives).
Future<List<_ZipEntry>?> _readCentralDirectoryAsync(
  RandomAccessByteReader reader,
) async {
  final int length = await reader.length();
  if (length < 22) return null;

  final int tailLength = math.min(length, 22 + 0xFFFF);
  final Uint8List tail = await reader.readAt(length - tailLength, tailLength);

  final _Eocd? eocd = _parseEocd(tail, length);
  if (eocd == null) return null;

  final Uint8List centralDirectory = await reader.readAt(
    eocd.cdOffset,
    eocd.cdSize,
  );
  if (centralDirectory.length != eocd.cdSize) return null;

  return _parseCentralDirectory(centralDirectory, eocd.totalEntries, length);
}

/// Walks the central-directory records and returns the page-image entries.
List<_ZipEntry>? _parseCentralDirectory(
  Uint8List centralDirectory,
  int totalEntries,
  int length,
) {
  final List<_ZipEntry> pages = <_ZipEntry>[];
  int offset = 0;
  int entriesRead = 0;

  while (offset < centralDirectory.length) {
    if (offset + 46 > centralDirectory.length ||
        _u32(centralDirectory, offset) != 0x02014B50) {
      return null;
    }

    final int flags = _u16(centralDirectory, offset + 8);
    final int method = _u16(centralDirectory, offset + 10);
    final int compressedSize = _u32(centralDirectory, offset + 20);
    final int uncompressedSize = _u32(centralDirectory, offset + 24);
    final int nameLength = _u16(centralDirectory, offset + 28);
    final int extraLength = _u16(centralDirectory, offset + 30);
    final int commentLength = _u16(centralDirectory, offset + 32);
    final int localOffset = _u32(centralDirectory, offset + 42);

    final int recordEnd =
        offset + 46 + nameLength + extraLength + commentLength;
    if (recordEnd > centralDirectory.length) return null;

    final String name = utf8.decode(
      Uint8List.sublistView(
        centralDirectory,
        offset + 46,
        offset + 46 + nameLength,
      ),
      allowMalformed: true,
    );
    offset = recordEnd;
    entriesRead++;

    // The ZIP central directory is a flat index: every nested file appears as
    // its own record with its full relative path (for example, "Vol 1/2.JPG").
    // Scan every record and filter that complete path rather than assuming
    // page images must be at the archive root. Directory/metadata entries are
    // rejected by _isPageImage.
    if (!_isPageImage(name)) continue;

    final bool encrypted = (flags & 0x1) != 0;
    final bool zip64 =
        compressedSize == 0xFFFFFFFF || localOffset == 0xFFFFFFFF;
    if (encrypted || zip64 || (method != 0 && method != 8)) {
      return null;
    }

    if (localOffset < 0 || localOffset + 30 > length) return null;
    pages.add(
      _ZipEntry(name, method, compressedSize, localOffset, uncompressedSize),
    );
  }

  if (entriesRead != totalEntries) return null;
  return pages;
}

/// Validates the local header and returns the entry's compressed-data offset.
int _dataStart(RandomAccessFile raf, _ZipEntry entry) {
  raf.setPositionSync(entry.localHeaderOffset);
  final Uint8List header = raf.readSync(30);
  if (header.length < 30 || _u32(header, 0) != 0x04034B50) {
    throw const FormatException('Corrupt ZIP local header');
  }
  return entry.localHeaderOffset + 30 + _u16(header, 26) + _u16(header, 28);
}

Uint8List _readEntry(RandomAccessFile raf, _ZipEntry entry) {
  raf.setPositionSync(_dataStart(raf, entry));
  final Uint8List raw = raf.readSync(entry.compressedSize);
  if (raw.length != entry.compressedSize) {
    throw const FormatException('Truncated ZIP entry');
  }
  if (entry.method == 0) return raw;

  final List<int> output = ZLibDecoder().decodeBytes(raw, raw: true);
  return output is Uint8List ? output : Uint8List.fromList(output);
}

PageDimensions? _sniffEntry(RandomAccessFile raf, _ZipEntry entry) {
  if (entry.method == 0) {
    raf.setPositionSync(_dataStart(raf, entry));
    final int headLength = math.min(entry.compressedSize, _sniffBytes);
    final PageDimensions? quick = ImageHeaderSniffer.sniff(
      raf.readSync(headLength),
    );
    if (quick != null || entry.compressedSize <= headLength) return quick;
  } else if (entry.method == 8) {
    // Image headers sit in the first bytes, so inflating the first 64 KB of the
    // compressed stream (native zlib) is enough. Inflating the whole page just
    // to read its size is what made cold probing of deflated archives slow.
    try {
      raf.setPositionSync(_dataStart(raf, entry));
      final int headLength = math.min(entry.compressedSize, _sniffBytes);
      final Uint8List? prefix = _inflatePrefix(raf.readSync(headLength));
      if (prefix != null && prefix.isNotEmpty) {
        final PageDimensions? quick = ImageHeaderSniffer.sniff(prefix);
        if (quick != null) return quick;
      }
    } catch (_) {
      // Fall through to the exact (full) path below.
    }
  }
  return ImageHeaderSniffer.sniff(_readEntry(raf, entry));
}

/// Local-header sanity check used when re-attaching a cached index.
Future<void> _checkLocalHeaderAsync(
  RandomAccessByteReader reader,
  _ZipEntry entry,
) async {
  final Uint8List header = await reader.readAt(entry.localHeaderOffset, 30);
  if (header.length < 30 || _u32(header, 0) != 0x04034B50) {
    throw const FormatException('Corrupt ZIP local header');
  }
}

/// Up to [maxData] bytes of an entry's compressed data. Header and data come
/// from ONE read (header + [slack] + data), so a page costs a single platform
/// call; a local header longer than the slack costs one more.
Future<Uint8List> _readEntryDataAsync(
  RandomAccessByteReader reader,
  _ZipEntry entry,
  int maxData,
) async {
  const int slack = 1024;
  final int want = math.min(entry.compressedSize, maxData);
  final Uint8List block = await reader.readAt(
    entry.localHeaderOffset,
    30 + slack + want,
  );
  if (block.length < 30 || _u32(block, 0) != 0x04034B50) {
    throw const FormatException('Corrupt ZIP local header');
  }
  final int start = 30 + _u16(block, 26) + _u16(block, 28);
  if (start + want <= block.length) {
    return Uint8List.sublistView(block, start, start + want);
  }
  final Uint8List data = await reader.readAt(
    entry.localHeaderOffset + start,
    want,
  );
  if (data.length != want) throw const FormatException('Truncated ZIP entry');
  return data;
}

Future<Uint8List> _readEntryAsync(
  RandomAccessByteReader reader,
  _ZipEntry entry,
) async {
  final Uint8List raw = await _readEntryDataAsync(
    reader,
    entry,
    entry.compressedSize,
  );
  if (raw.length != entry.compressedSize) {
    throw const FormatException('Truncated ZIP entry');
  }
  if (entry.method == 0) return raw;

  final List<int> output = ZLibDecoder().decodeBytes(raw, raw: true);
  return output is Uint8List ? output : Uint8List.fromList(output);
}

Future<PageDimensions?> _sniffEntryAsync(
  RandomAccessByteReader reader,
  _ZipEntry entry,
) async {
  if (entry.method == 0) {
    final Uint8List head = await _readEntryDataAsync(reader, entry, _sniffBytes);
    final PageDimensions? quick = ImageHeaderSniffer.sniff(head);
    if (quick != null || entry.compressedSize <= head.length) return quick;
  } else if (entry.method == 8) {
    // Same shortcut as _sniffEntry: inflate only the first 64 KB.
    try {
      final Uint8List head = await _readEntryDataAsync(
        reader,
        entry,
        _sniffBytes,
      );
      final Uint8List? prefix = _inflatePrefix(head);
      if (prefix != null && prefix.isNotEmpty) {
        final PageDimensions? quick = ImageHeaderSniffer.sniff(prefix);
        if (quick != null) return quick;
      }
    } catch (_) {
      // Fall through to the exact (full) path below.
    }
  }
  return ImageHeaderSniffer.sniff(await _readEntryAsync(reader, entry));
}

/// Whole source as one buffer, in 4 MB reads (full-decoder fallback only).
Future<Uint8List> _readWholeAsync(RandomAccessByteReader reader) async {
  const int chunk = 4 * 1024 * 1024;
  final int length = await reader.length();
  final BytesBuilder builder = BytesBuilder(copy: false);
  int offset = 0;
  while (offset < length) {
    final Uint8List part = await reader.readAt(
      offset,
      math.min(chunk, length - offset),
    );
    if (part.isEmpty) break;
    builder.add(part);
    offset += part.length;
  }
  return builder.takeBytes();
}

/// Collects the output of a chunked zlib conversion.
class _PrefixCollector implements Sink<List<int>> {
  final BytesBuilder _bytes = BytesBuilder(copy: true);

  @override
  void add(List<int> data) => _bytes.add(data);

  @override
  void close() {}

  Uint8List take() => _bytes.takeBytes();
}

/// Inflates as much of a truncated raw-deflate stream as its bytes allow.
/// The stream is cut on purpose, so the "unexpected end of data" error that a
/// complete decode would raise is ignored; whatever was produced is returned.
Uint8List? _inflatePrefix(Uint8List compressed) {
  final _PrefixCollector collector = _PrefixCollector();
  final ByteConversionSink sink = io.ZLibDecoder(
    raw: true,
  ).startChunkedConversion(collector);
  try {
    sink.add(compressed);
  } catch (_) {
    // Truncated or damaged: keep what was produced before the error.
  }
  try {
    sink.close(); // Releases the native zlib state; throws on truncated input.
  } catch (_) {}
  return collector.take();
}

// =============================================================================
// CBR: pages are files on disk
// =============================================================================

class FilePageSource implements ComicPageSource, PageDimensionProbe {
  FilePageSource(this.rootPath, this.relativePaths);

  final String rootPath;
  final List<String> relativePaths;

  /// Cached folder path and the sorted relative page names (see [fromJson]).
  Map<String, dynamic> toJson() => <String, dynamic>{
    'type': 'cbr',
    'root': rootPath,
    'files': relativePaths,
  };

  /// Rebuilds a source from [toJson] output. The caller supplies the folder's
  /// current path ([rootPath]); the stored one can go stale if the app's
  /// temporary directory moves. Returns null for an invalid document.
  static FilePageSource? fromJson(Object? json, String rootPath) {
    if (json is! Map<String, dynamic> || json['type'] != 'cbr') return null;
    final Object? files = json['files'];
    if (files is! List || files.isEmpty) return null;
    final List<String> names = <String>[];
    for (final Object? name in files) {
      if (name is! String || name.isEmpty) return null;
      names.add(name);
    }
    return FilePageSource(rootPath, names);
  }

  @override
  int get pageCount => relativePaths.length;

  @override
  Future<Uint8List> readPage(int index) {
    if (index < 0 || index >= pageCount) {
      throw RangeError.range(index, 0, pageCount - 1, 'index');
    }
    final String relative = relativePaths[index].replaceAll(
      '/',
      Platform.pathSeparator,
    );
    return File('$rootPath${Platform.pathSeparator}$relative').readAsBytes();
  }

  @override
  Future<List<PageDimensions?>> readAllDimensions() async {
    return _decodeDims(await _sniffFilesInIsolate(rootPath, relativePaths));
  }

  /// Header-only reads on the I/O thread pool, one page at a time: no isolate
  /// is spawned per micro-batch, and the event loop is free between reads.
  @override
  Future<List<PageDimensions?>> probeDimensions(int start, int count) async {
    if (start < 0 || count < 0 || start + count > pageCount) {
      throw RangeError('Invalid dimensions range: $start + $count of $pageCount');
    }
    final List<PageDimensions?> out = <PageDimensions?>[];
    for (int i = start; i < start + count; i++) {
      out.add(await _sniffFileAsync(relativePaths[i]));
    }
    return out;
  }

  Future<PageDimensions?> _sniffFileAsync(String relativePath) async {
    final String relative = relativePath.replaceAll(
      '/',
      Platform.pathSeparator,
    );
    RandomAccessFile? raf;
    try {
      raf = await File('$rootPath${Platform.pathSeparator}$relative').open();
      final int length = await raf.length();
      final Uint8List head = await raf.read(math.min(length, _sniffBytes));
      PageDimensions? dimensions = ImageHeaderSniffer.sniff(head);
      if (dimensions == null && length > head.length) {
        await raf.setPosition(0);
        dimensions = ImageHeaderSniffer.sniff(await raf.read(length));
      }
      return dimensions;
    } catch (_) {
      return null; // The reader measures this page after loading it.
    } finally {
      try {
        await raf?.close();
      } catch (_) {}
    }
  }

  @override
  Future<void> dispose() async {}
}

/// Counts the page images below [root] (same filter as the extraction index).
Future<int> _countPageFiles(String root) async {
  int count = 0;
  await for (final FileSystemEntity entity in Directory(
    root,
  ).list(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    String relative = entity.path.substring(root.length).replaceAll('\\', '/');
    if (relative.startsWith('/')) relative = relative.substring(1);
    if (_isPageImage(relative)) count++;
  }
  return count;
}

Future<List<String>> _listPagesInIsolate(String root) =>
    Isolate.run(() => _listPages(root));

Future<Int32List> _sniffFilesInIsolate(String root, List<String> paths) =>
    Isolate.run(() => _sniffFiles(root, paths));

List<String> _listPages(String root) {
  final List<String> found = <String>[];
  for (final FileSystemEntity entity in Directory(
    root,
  ).listSync(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    String relative = entity.path.substring(root.length).replaceAll('\\', '/');
    if (relative.startsWith('/')) relative = relative.substring(1);
    if (_isPageImage(relative)) found.add(relative);
  }
  return _sortNaturally<String>(found, (String value) => value);
}

Int32List _sniffFiles(String root, List<String> paths) {
  final Int32List out = Int32List(paths.length * 2);
  for (int i = 0; i < paths.length; i++) {
    try {
      final String relative = paths[i].replaceAll('/', Platform.pathSeparator);
      final RandomAccessFile raf = File(
        '$root${Platform.pathSeparator}$relative',
      ).openSync();
      try {
        final int length = raf.lengthSync();
        final Uint8List head = raf.readSync(math.min(length, _sniffBytes));
        PageDimensions? dimensions = ImageHeaderSniffer.sniff(head);
        if (dimensions == null && length > head.length) {
          raf.setPositionSync(0);
          dimensions = ImageHeaderSniffer.sniff(raf.readSync(length));
        }
        if (dimensions != null) {
          out[i * 2] = dimensions.width;
          out[i * 2 + 1] = dimensions.height;
        }
      } finally {
        raf.closeSync();
      }
    } catch (_) {
      // Leave 0,0: the reader can measure this page after loading it.
    }
  }
  return out;
}

// =============================================================================
// Shared helpers
// =============================================================================

List<PageDimensions?> _decodeDims(Int32List flat) => <PageDimensions?>[
  for (int i = 0; i + 1 < flat.length; i += 2)
    (flat[i] > 0 && flat[i + 1] > 0)
        ? PageDimensions(flat[i], flat[i + 1])
        : null,
];

/// Normalizes ZIP entry separators without changing the actual archive name.
/// ZIP paths conventionally use '/', but some tools write Windows '\\'.
String _normalizeArchiveEntryPath(String path) =>
    path.replaceAll('\\', '/').replaceAll(RegExp(r'/+'), '/');

const Set<String> _supportedPageExtensions = <String>{
  '.jpg',
  '.jpeg',
  '.png',
  '.webp',
};

const Set<String> _ignoredArchiveDirectories = <String>{
  '__macosx',
  '.spotlight-v100',
  '.trashes',
  r'$recycle.bin',
  'system volume information',
};

const Set<String> _ignoredArchiveMetadataFiles = <String>{
  'thumbs.db',
  'ehthumbs.db',
  'desktop.ini',
  '.ds_store',
};

/// Returns true only for a supported page image anywhere in the ZIP tree.
///
/// This is deliberately path-based: ZIP central-directory entries and
/// package:archive's `Archive.files` are flat lists whose names contain the
/// nested folder path. Walking a synthetic directory tree is unnecessary and
/// can accidentally miss entries when a ZIP omits explicit folder records.
bool _isPageImage(String path) {
  final String normalized = _normalizeArchiveEntryPath(path);
  if (normalized.isEmpty || normalized.endsWith('/')) return false;

  // Ignore harmless './' prefixes, but reject parent traversal segments.
  // Empty path components can occur when archives contain repeated slashes.
  final List<String> segments = normalized
      .split('/')
      .where((String segment) => segment.isNotEmpty && segment != '.')
      .toList(growable: false);
  if (segments.isEmpty || segments.any((String part) => part == '..')) {
    return false;
  }

  // Metadata directories may occur at the root or at any nested level. Match
  // complete path components (case-insensitively), not loose substrings, so a
  // real folder such as "__MACOSX_Extras" is not incorrectly discarded.
  for (final String segment in segments) {
    final String lowerSegment = segment.toLowerCase();
    if (lowerSegment.startsWith('.')) return false; // Hidden files/folders.
    if (_ignoredArchiveDirectories.contains(lowerSegment)) return false;
  }

  final String fileName = segments.last;
  final String lowerFileName = fileName.toLowerCase();
  if (_ignoredArchiveMetadataFiles.contains(lowerFileName)) return false;

  final int extensionStart = lowerFileName.lastIndexOf('.');
  if (extensionStart <= 0) return false;
  final String extension = lowerFileName.substring(extensionStart);
  return _supportedPageExtensions.contains(extension);
}

const Set<String> _comicArchiveExtensions = <String>{
  '.cbz',
  '.cbr',
  '.zip',
  '.rar',
};

/// Lower-case extension (with the dot) of a visible archive entry, or null for
/// directories, hidden entries, OS metadata and `..` paths. Same filtering as
/// [_isPageImage], without the page-image extension check.
String? _visibleEntryExtension(String path) {
  final String normalized = _normalizeArchiveEntryPath(path);
  if (normalized.isEmpty || normalized.endsWith('/')) return null;
  final List<String> segments = normalized
      .split('/')
      .where((String segment) => segment.isNotEmpty && segment != '.')
      .toList(growable: false);
  if (segments.isEmpty || segments.any((String part) => part == '..')) {
    return null;
  }
  for (final String segment in segments) {
    final String lower = segment.toLowerCase();
    if (lower.startsWith('.')) return null;
    if (_ignoredArchiveDirectories.contains(lower)) return null;
  }
  final String lowerFileName = segments.last.toLowerCase();
  if (_ignoredArchiveMetadataFiles.contains(lowerFileName)) return null;
  final int extensionStart = lowerFileName.lastIndexOf('.');
  if (extensionStart <= 0) return null;
  return lowerFileName.substring(extensionStart);
}

final RegExp _chunkPattern = RegExp(r'\d+|\D+');

class _NaturalKey {
  _NaturalKey(this.raw) {
    for (final Match match in _chunkPattern.allMatches(raw.toLowerCase())) {
      final String chunk = match.group(0)!;
      text.add(chunk);
      numbers.add(int.tryParse(chunk));
    }
  }

  final String raw;
  final List<String> text = <String>[];
  final List<int?> numbers = <int?>[];
}

int _compareNatural(_NaturalKey a, _NaturalKey b) {
  final int count = math.min(a.text.length, b.text.length);
  for (int i = 0; i < count; i++) {
    final int? leftNumber = a.numbers[i];
    final int? rightNumber = b.numbers[i];
    final int comparison = leftNumber != null && rightNumber != null
        ? leftNumber.compareTo(rightNumber)
        : a.text[i].compareTo(b.text[i]);
    if (comparison != 0) return comparison;
  }

  if (a.text.length != b.text.length) {
    return a.text.length.compareTo(b.text.length);
  }
  return a.raw.compareTo(b.raw);
}

List<T> _sortNaturally<T>(List<T> items, String Function(T item) nameOf) {
  final List<_NaturalKey> keys = <_NaturalKey>[
    for (final T item in items) _NaturalKey(nameOf(item)),
  ];
  final List<int> order = List<int>.generate(items.length, (int i) => i)
    ..sort((int left, int right) => _compareNatural(keys[left], keys[right]));
  return <T>[for (final int index in order) items[index]];
}
