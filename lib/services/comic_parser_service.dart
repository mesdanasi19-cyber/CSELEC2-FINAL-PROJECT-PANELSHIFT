import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:rar/rar.dart';

import 'comic_cache_service.dart';
import 'comic_identity.dart';
import 'comic_page_source.dart';
import 'isolate_rpc.dart';

enum ComicArchiveFormat { zip, rar, unknown }

/// Result of opening a comic file.
///
/// Opening builds the page index; page bytes are read lazily through [source].
/// Call [close] when the reader is dismissed.
class LoadedComic {
  LoadedComic({required this.source, required this.identity, this.cacheKey});

  final ComicPageSource source;
  final ComicIdentity identity;
  final String? cacheKey;

  Future<void>? _closeFuture;

  /// Idempotently disposes the page source and always releases its CBR cache.
  Future<void> close() => _closeFuture ??= _closeInternal();

  Future<void> _closeInternal() async {
    try {
      await source.dispose();
    } finally {
      final String? key = cacheKey;
      if (key != null) {
        await ComicCacheService.instance.release(key);
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

  /// Opens a .cbz/.zip/.cbr/.rar file. The format is detected from its magic
  /// bytes, with the extension used only when the header is unrecognised.
  static Future<LoadedComic> loadComic(
    String filePath, {
    Duration? rarExtractionTimeout = defaultRarExtractionTimeout,
    Duration? archiveIndexTimeout = defaultArchiveIndexTimeout,
  }) async {
    final Future<ComicIdentity> identityFuture = ComicIdentity.fromFile(
      filePath,
    );
    final Future<ComicArchiveFormat> formatFuture = detectFormat(filePath);

    final List<Object> both = await Future.wait<Object>(<Future<Object>>[
      identityFuture,
      formatFuture,
    ]);
    final ComicIdentity identity = both[0] as ComicIdentity;
    final ComicArchiveFormat format = both[1] as ComicArchiveFormat;

    if (format == ComicArchiveFormat.rar) {
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
      return LoadedComic(
        source: source,
        identity: identity,
        cacheKey: extractionKey,
      );
    }

    final ComicPageSource source = await ZipPageSource.open(filePath);
    return LoadedComic(source: source, identity: identity);
  }

  static String _newExtractionKey(String identity) {
    _cacheAttemptSequence++;
    return '${identity}_${DateTime.now().microsecondsSinceEpoch}_$_cacheAttemptSequence';
  }

  static Future<ComicArchiveFormat> detectFormat(String filePath) async {
    final RandomAccessFile raf = await File(filePath).open();
    try {
      final Uint8List head = await raf.read(8);

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
      await raf.close();
    }

    final String lower = filePath.toLowerCase();
    if (lower.endsWith('.cbr') || lower.endsWith('.rar')) {
      return ComicArchiveFormat.rar;
    }
    return ComicArchiveFormat.zip;
  }

  // ---------------------------------------------------------------------------
  // CBR (RAR)
  // ---------------------------------------------------------------------------

  /// Extracts [filePath] into the cache and returns a lazy disk-backed source.
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

    try {
      final Future<dynamic> extraction = Rar.extractRarFile(
        rarFilePath: filePath,
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

class ZipPageSource implements ComicPageSource {
  ZipPageSource._(this._rpc, this.pageCount);

  final IsolateRpc _rpc;

  @override
  final int pageCount;

  bool _disposed = false;

  static Future<ZipPageSource> open(String filePath) async {
    final IsolateRpc rpc = await IsolateRpc.spawn(
      _zipWorkerMain,
      null,
      debugName: 'cbz-reader',
    );

    try {
      final int? count = await rpc.callWithTimeout<int>('open', args: filePath);
      if (count == null || count < 0) {
        throw const FormatException(
          'ZIP worker returned an invalid page count',
        );
      }
      return ZipPageSource._(rpc, count);
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

    final TransferableTypedData? data = await _rpc
        .callWithTimeout<TransferableTypedData>('read', args: index);
    if (data == null) {
      throw StateError('Worker returned no data for page $index');
    }
    return data.materialize().asUint8List();
  }

  @override
  Future<List<PageDimensions?>> readAllDimensions() async {
    if (_disposed) throw StateError('ZIP page source is disposed');

    final List<PageDimensions?> out = <PageDimensions?>[];
    for (int start = 0; start < pageCount; start += _dimsChunk) {
      final int count = math.min(_dimsChunk, pageCount - start);
      final Int32List? part = await _rpc.callWithTimeout<Int32List>(
        'dims',
        args: <int>[start, count],
      );
      if (part == null || part.length != count * 2) {
        throw const FormatException('ZIP worker returned invalid dimensions');
      }
      out.addAll(_decodeDims(part));
    }
    return out;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;

    // Ask the worker to close its RandomAccessFile before terminating it.
    // If the worker is already dead or unresponsive, dispose still kills it.
    try {
      await _rpc.callWithTimeout<Object?>(
        'close',
        timeout: const Duration(seconds: 3),
      );
    } catch (_) {
      // Disposal is best-effort; the host-side controller still terminates it.
    } finally {
      await _rpc.dispose();
    }
  }
}

class _ZipEntry {
  const _ZipEntry(
    this.name,
    this.method,
    this.compressedSize,
    this.localHeaderOffset,
  );

  final String name;
  final int method; // 0 = stored, 8 = deflate
  final int compressedSize;
  final int localHeaderOffset;
}

void _zipWorkerMain(List<Object?> boot) {
  final _ZipWorker worker = _ZipWorker();
  serveRpc(boot[0] as SendPort, worker.handle);
}

class _ZipWorker {
  RandomAccessFile? _raf;
  List<_ZipEntry> _entries = const <_ZipEntry>[];
  bool _useFallback = false;
  List<ArchiveFile> _fallback = const <ArchiveFile>[];

  Object? handle(String op, Object? args) {
    switch (op) {
      case 'open':
        return _open(args as String);
      case 'read':
        return _read(args as int);
      case 'dims':
        final List<dynamic> range = args as List<dynamic>;
        if (range.length != 2) {
          throw const FormatException('Invalid dimensions request');
        }
        return _dims(range[0] as int, range[1] as int);
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
    if (raf != null) {
      try {
        raf.closeSync();
      } catch (_) {
        // The handle may already have been closed by the OS.
      }
    }
  }

  int _open(String path) {
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
          (_ZipEntry entry) => entry.name,
        );
        retainedHandle = true;
        return _entries.length;
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
    final Archive archive = ZipDecoder().decodeBytes(
      File(path).readAsBytesSync(),
    );
    final List<ArchiveFile> files = archive.files
        .where((ArchiveFile file) => file.isFile && _isPageImage(file.name))
        .toList();
    _fallback = _sortNaturally<ArchiveFile>(
      files,
      (ArchiveFile file) => file.name,
    );
    _useFallback = true;
    return _fallback.length;
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
}

// --- ZIP structure parsing --------------------------------------------------

int _u16(Uint8List bytes, int offset) =>
    bytes[offset] | (bytes[offset + 1] << 8);

int _u32(Uint8List bytes, int offset) =>
    bytes[offset] |
    (bytes[offset + 1] << 8) |
    (bytes[offset + 2] << 16) |
    (bytes[offset + 3] << 24);

/// Parses the central directory. Returns null when the full decoder is needed.
List<_ZipEntry>? _readCentralDirectory(RandomAccessFile raf) {
  final int length = raf.lengthSync();
  if (length < 22) return null;

  final int tailLength = math.min(length, 22 + 0xFFFF);
  raf.setPositionSync(length - tailLength);
  final Uint8List tail = raf.readSync(tailLength);

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

  raf.setPositionSync(cdOffset);
  final Uint8List centralDirectory = raf.readSync(cdSize);
  if (centralDirectory.length != cdSize) return null;

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

    if (!_isPageImage(name)) continue;

    final bool encrypted = (flags & 0x1) != 0;
    final bool zip64 =
        compressedSize == 0xFFFFFFFF || localOffset == 0xFFFFFFFF;
    if (encrypted || zip64 || (method != 0 && method != 8)) {
      return null;
    }

    if (localOffset < 0 || localOffset + 30 > length) return null;
    pages.add(_ZipEntry(name, method, compressedSize, localOffset));
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
  }
  return ImageHeaderSniffer.sniff(_readEntry(raf, entry));
}

// =============================================================================
// CBR: pages are files on disk
// =============================================================================

class FilePageSource implements ComicPageSource {
  FilePageSource(this.rootPath, this.relativePaths);

  final String rootPath;
  final List<String> relativePaths;

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

  @override
  Future<void> dispose() async {}
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

bool _isPageImage(String path) {
  final String name = path.toLowerCase().replaceAll('\\', '/');
  return (name.endsWith('.jpg') ||
          name.endsWith('.jpeg') ||
          name.endsWith('.png')) &&
      !name.startsWith('__macosx') &&
      !name.contains('/__macosx') &&
      !name.startsWith('.') &&
      !name.contains('/.');
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
