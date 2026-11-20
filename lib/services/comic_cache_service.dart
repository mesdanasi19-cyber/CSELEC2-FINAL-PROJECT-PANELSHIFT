import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Owns two on-disk stores:
///
///  * `panelshift_cbr_cache` (temporary directory): the folders that .cbr
///    archives are unpacked into. A folder is either *leased* (a reader is
///    using it), *retained* (extraction finished and indexed, kept for the next
///    open until [maxCacheBytes] evicts it) or an orphan (swept at startup).
///  * `panelshift_index_cache` (application support directory): one compact
///    JSON file per comic, keyed by the immutable comic id
///    (`<64KB MD5>_<byte length>`), holding the archive page index and the
///    page dimensions. A renamed or moved file keeps its entry; a modified file
///    gets a new id and therefore a fresh entry.
///
/// All cache-folder mutations are serialized through [_withLock]. Expensive
/// directory scans happen outside the lock; every deletion rechecks [_inUse]
/// while holding the lock, so a directory acquired during a scan cannot be
/// evicted. Index-file mutations use their own mutex, so a tiny JSON write is
/// never queued behind the deletion of a large extraction folder.
class ComicCacheService {
  ComicCacheService._();
  static final ComicCacheService instance = ComicCacheService._();

  static const String _rootFolderName = 'panelshift_cbr_cache';
  static const String _indexFolderName = 'panelshift_index_cache';
  static const int maxCacheBytes = 500 * 1024 * 1024;

  /// Bump when the JSON layout changes incompatibly: older files are ignored
  /// (and replaced) instead of being misread.
  static const int indexSchemaVersion = 1;

  /// Written into a CBR folder once its extraction is complete and indexed.
  /// Its modification time doubles as the folder's "last used" stamp for
  /// eviction. Folders without it are orphans of an interrupted extraction.
  static const String _retainedMarker = '.retained';

  /// A key may have only one active lease. Concurrently extracting the same
  /// key would otherwise delete or overwrite files being read by the first
  /// reader; reject that case instead of pretending a Set is a ref-count.
  final Set<String> _inUse = <String>{};

  final _LazyDir _cbrDir = _LazyDir(_rootFolderName, getTemporaryDirectory);
  final _LazyDir _indexDir = _LazyDir(
    _indexFolderName,
    getApplicationSupportDirectory,
  );

  final _AsyncMutex _cacheMutex = _AsyncMutex();
  final _AsyncMutex _indexMutex = _AsyncMutex();

  /// Tail-serialized async mutex for the extraction folders.
  Future<T> _withLock<T>(Future<T> Function() action) =>
      _cacheMutex.run<T>(action);

  Future<String> _rootPath() => _cbrDir.path();

  Future<String> _indexRootPath() => _indexDir.path();

  String _safeKey(String key) {
    final String safe = key.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    if (safe.isEmpty) {
      throw ArgumentError.value(key, 'key', 'Cache key must not be empty');
    }
    return safe;
  }

  // ---------------------------------------------------------------------------
  // CBR extraction folders
  // ---------------------------------------------------------------------------

  /// Creates a fresh, empty extraction folder for [key] and marks it in use.
  ///
  /// Fails fast if the same key is already leased. The lease is rolled back if
  /// directory deletion/creation fails for any reason.
  Future<Directory> acquire(String key) {
    final String safe = _safeKey(key);
    return _withLock<Directory>(() async {
      if (_inUse.contains(safe)) {
        throw StateError('Comic cache key is already acquired: $safe');
      }

      final String root = await _rootPath();
      final Directory dir = Directory('$root${Platform.pathSeparator}$safe');

      _inUse.add(safe);
      bool acquired = false;
      try {
        if (await dir.exists()) {
          await dir.delete(recursive: true);
        }
        await dir.create(recursive: true);
        acquired = true;
        return dir;
      } finally {
        if (!acquired) {
          _inUse.remove(safe);
        }
      }
    });
  }

  /// Leases an existing *retained* extraction folder WITHOUT wiping it.
  ///
  /// Returns null when the folder was evicted, never finished extracting
  /// (no retained marker) or is currently leased by someone else; the caller
  /// then falls back to a normal extraction.
  Future<Directory?> acquireRetained(String key) {
    final String safe;
    try {
      safe = _safeKey(key);
    } catch (_) {
      return Future<Directory?>.value(null);
    }

    return _withLock<Directory?>(() async {
      if (_inUse.contains(safe)) return null;

      final String root = await _rootPath();
      final Directory dir = Directory('$root${Platform.pathSeparator}$safe');
      if (!await dir.exists()) return null;
      if (!await _markerOf(dir).exists()) return null;

      _inUse.add(safe);
      unawaited(_touchMarker(dir));
      return dir;
    });
  }

  /// Flags the (leased) folder of [key] as complete so it survives
  /// [release] with `keep: true`, [purgeOrphans] and an app restart.
  Future<void> markRetained(String key) async {
    final String safe;
    try {
      safe = _safeKey(key);
    } catch (_) {
      return;
    }

    await _withLock<void>(() async {
      try {
        final String root = await _rootPath();
        final Directory dir = Directory('$root${Platform.pathSeparator}$safe');
        if (await dir.exists()) await _touchMarker(dir);
      } catch (error, stackTrace) {
        debugPrint(
          'ComicCacheService.markRetained failed for $safe: $error\n$stackTrace',
        );
      }
    });
  }

  /// Releases a cache lease.
  ///
  /// With [keep] false (default) the folder is deleted. With [keep] true the
  /// folder stays on disk, flagged as retained, until [enforceLimit] evicts it
  /// or the comic is removed through [deleteIndexCache].
  ///
  /// Filesystem cleanup is best-effort; a cleanup failure must never prevent
  /// the lease from being removed or strand callers waiting on the mutex.
  Future<void> release(String key, {bool keep = false}) async {
    final String safe;
    try {
      safe = _safeKey(key);
    } catch (error) {
      debugPrint('ComicCacheService.release ignored invalid key: $error');
      return;
    }

    await _withLock<void>(() async {
      try {
        final String root = await _rootPath();
        final Directory dir = Directory('$root${Platform.pathSeparator}$safe');
        if (await dir.exists()) {
          if (keep) {
            await _touchMarker(dir);
          } else {
            await dir.delete(recursive: true);
          }
        }
      } catch (error, stackTrace) {
        debugPrint(
          'ComicCacheService.release failed for $safe: $error\n$stackTrace',
        );
      } finally {
        _inUse.remove(safe);
      }
    });

    // enforceLimit catches its own scan/deletion errors. It runs after the
    // release lock has been relinquished, so it cannot recursively deadlock.
    await enforceLimit();
  }

  /// Deletes every folder that is neither leased nor retained, and any
  /// interrupted index write. Call at startup.
  Future<void> purgeOrphans() async {
    try {
      final String root = await _rootPath();
      final List<String> folders = await _listFoldersInIsolate(root);

      for (final String path in folders) {
        await _withLock<void>(() async {
          final String name = _nameOf(path);
          if (_inUse.contains(name)) return;
          await _deleteQuietly(Directory(path));
        });
      }
    } catch (error, stackTrace) {
      debugPrint('ComicCacheService.purgeOrphans failed: $error\n$stackTrace');
    }

    await _purgeStaleIndexTempFiles();
  }

  /// Evicts oldest folders until the cache fits under [maxCacheBytes].
  Future<void> enforceLimit() async {
    try {
      // Take a consistent snapshot, then do the expensive recursive scan in a
      // worker isolate without holding the cache mutex.
      final _CacheSnapshot snapshot = await _withLock<_CacheSnapshot>(
        () async => _CacheSnapshot(await _rootPath(), Set<String>.of(_inUse)),
      );

      final List<String> victims = await _planEvictionInIsolate(
        snapshot.root,
        snapshot.pinned,
        maxCacheBytes,
      );

      for (final String path in victims) {
        await _withLock<void>(() async {
          // An acquire may have happened while the isolate was scanning.
          if (_inUse.contains(_nameOf(path))) return;
          await _deleteQuietly(Directory(path));
        });
      }
    } catch (error, stackTrace) {
      debugPrint('ComicCacheService.enforceLimit failed: $error\n$stackTrace');
    }
  }

  static String _nameOf(String path) => path.split(Platform.pathSeparator).last;

  File _markerOf(Directory dir) =>
      File('${dir.path}${Platform.pathSeparator}$_retainedMarker');

  /// Creates the marker or refreshes its modification time (LRU stamp).
  Future<void> _touchMarker(Directory dir) async {
    try {
      await _markerOf(dir).writeAsString('');
    } catch (error) {
      debugPrint('ComicCacheService: could not mark ${dir.path}: $error');
    }
  }

  Future<void> _deleteQuietly(Directory dir) async {
    try {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (error) {
      debugPrint('ComicCacheService: could not delete ${dir.path}: $error');
    }
  }

  // ---------------------------------------------------------------------------
  // Persistent index cache (panelshift_index_cache/<comicId>.json)
  // ---------------------------------------------------------------------------

  Future<File> _indexFile(String comicId) async {
    final String safe = _safeKey(comicId);
    final String root = await _indexRootPath();
    return File('$root${Platform.pathSeparator}$safe.json');
  }

  /// Returns the stored index of [comicId], or null when there is none, it is
  /// unreadable, or it was written by an incompatible schema version.
  ///
  /// Writes are atomic (temp file + rename), so a reader always sees a complete
  /// document and needs no lock.
  Future<Map<String, dynamic>?> readIndexCache(String comicId) async {
    try {
      return await _readIndexFile(await _indexFile(comicId));
    } catch (error) {
      debugPrint('ComicCacheService.readIndexCache failed: $error');
      return null;
    }
  }

  /// Replaces the stored index of [comicId] with [data].
  ///
  /// The document is written to a temporary file, flushed, then renamed over
  /// the target, so an interrupted write can never leave corrupt JSON behind.
  /// Never throws: the index is an optimisation, not state anyone depends on.
  Future<void> writeIndexCache(String comicId, Map<String, dynamic> data) async {
    try {
      await _indexMutex.run<void>(() async {
        final File file = await _indexFile(comicId);
        await _writeIndexAtomically(file, <String, dynamic>{
          ...data,
          'v': indexSchemaVersion,
        });
      });
    } catch (error, stackTrace) {
      debugPrint('ComicCacheService.writeIndexCache failed: $error\n$stackTrace');
    }
  }

  /// Read-modify-write of the stored index: every key of [patch] replaces the
  /// stored one, all other keys (for example `dimensions` while the archive
  /// index is refreshed) are preserved. Serialized, so the page-index writer and
  /// the dimension writer can never overwrite each other.
  Future<void> mergeIndexCache(
    String comicId,
    Map<String, dynamic> patch,
  ) async {
    try {
      await _indexMutex.run<void>(() async {
        final File file = await _indexFile(comicId);
        final Map<String, dynamic>? current = await _readIndexFile(file);
        await _writeIndexAtomically(file, <String, dynamic>{
          ...?current,
          ...patch,
          'v': indexSchemaVersion,
        });
      });
    } catch (error, stackTrace) {
      debugPrint('ComicCacheService.mergeIndexCache failed: $error\n$stackTrace');
    }
  }

  /// Forgets everything stored for [comicId]: the index file and, for a CBR,
  /// the retained extraction folder it points to (unless a reader has it open).
  Future<void> deleteIndexCache(String comicId) async {
    try {
      String? retainedKey;
      await _indexMutex.run<void>(() async {
        final File file = await _indexFile(comicId);
        retainedKey = _retainedKeyOf(await _readIndexFile(file));
        await _deleteFileQuietly(file);
        await _deleteFileQuietly(File('${file.path}.tmp'));
      });

      final String? key = retainedKey;
      if (key == null) return;
      await _withLock<void>(() async {
        if (_inUse.contains(key)) return;
        final String root = await _rootPath();
        await _deleteQuietly(Directory('$root${Platform.pathSeparator}$key'));
      });
    } catch (error, stackTrace) {
      debugPrint('ComicCacheService.deleteIndexCache failed: $error\n$stackTrace');
    }
  }

  String? _retainedKeyOf(Map<String, dynamic>? index) {
    final Object? source = index?['source'];
    if (source is! Map<String, dynamic> || source['type'] != 'cbr') return null;
    final Object? root = source['root'];
    if (root is! String || root.isEmpty) return null;
    try {
      return _safeKey(root.split(RegExp(r'[\\/]')).last);
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> _readIndexFile(File file) async {
    final String text;
    try {
      text = await file.readAsString();
    } catch (_) {
      return null; // Missing or unreadable.
    }

    try {
      final Object? decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic> &&
          decoded['v'] == indexSchemaVersion) {
        return decoded;
      }
    } on FormatException {
      // Corrupt document: fall through and discard it.
    }
    await _deleteFileQuietly(file);
    return null;
  }

  Future<void> _writeIndexAtomically(
    File target,
    Map<String, dynamic> data,
  ) async {
    final File temp = File('${target.path}.tmp');
    try {
      await temp.writeAsString(jsonEncode(data), flush: true);
      try {
        await temp.rename(target.path);
      } on FileSystemException {
        // Some platforms refuse to rename over an existing file.
        if (await target.exists()) await target.delete();
        await temp.rename(target.path);
      }
    } catch (_) {
      await _deleteFileQuietly(temp);
      rethrow;
    }
  }

  Future<void> _deleteFileQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Best effort.
    }
  }

  Future<void> _purgeStaleIndexTempFiles() async {
    try {
      final Directory dir = Directory(await _indexRootPath());
      if (!await dir.exists()) return;
      await _indexMutex.run<void>(() async {
        await for (final FileSystemEntity entity in dir.list(
          followLinks: false,
        )) {
          if (entity is File && entity.path.endsWith('.json.tmp')) {
            await _deleteFileQuietly(entity);
          }
        }
      });
    } catch (error) {
      debugPrint('ComicCacheService: index temp cleanup failed: $error');
    }
  }
}

// -----------------------------------------------------------------------------
// Small concurrency / path helpers
// -----------------------------------------------------------------------------

/// Tail-serialized async mutex.
///
/// The tail is always a successful Future: an action's error is returned to
/// its own caller, while the release is completed from finally regardless of
/// success, filesystem failure, or an exception thrown by the action.
class _AsyncMutex {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() action) async {
    final Future<void> previous = _tail;
    final Completer<void> release = Completer<void>();
    _tail = release.future;

    try {
      await previous;
      return await action();
    } finally {
      if (!release.isCompleted) {
        release.complete();
      }
    }
  }
}

/// A directory created on first use, under a parent such as the temporary or
/// application-support directory. A failed creation is not cached.
class _LazyDir {
  _LazyDir(this._name, this._resolveParent);

  final String _name;
  final Future<Directory> Function() _resolveParent;
  Future<String>? _future;

  Future<String> path() {
    final Future<String>? cached = _future;
    if (cached != null) return cached;

    final Completer<String> completer = Completer<String>();
    final Future<String> future = completer.future;
    _future = future;

    () async {
      try {
        final Directory parent = await _resolveParent();
        final String path = '${parent.path}${Platform.pathSeparator}$_name';
        await Directory(path).create(recursive: true);
        completer.complete(path);
      } catch (error, stackTrace) {
        if (identical(_future, future)) {
          _future = null;
        }
        completer.completeError(error, stackTrace);
      }
    }();

    return future;
  }
}

// -----------------------------------------------------------------------------
// Isolate-side work (top-level so no instance state is captured by the closures)
// -----------------------------------------------------------------------------

Future<List<String>> _listFoldersInIsolate(String root) =>
    Isolate.run(() => _listFolders(root));

Future<List<String>> _planEvictionInIsolate(
  String root,
  Set<String> pinned,
  int cap,
) => Isolate.run(() => _planEviction(root, pinned, cap));

/// Folders that may be swept as orphans: everything without a retained marker.
List<String> _listFolders(String root) {
  final Directory rootDir = Directory(root);
  if (!rootDir.existsSync()) return const <String>[];
  return <String>[
    for (final FileSystemEntity entity in rootDir.listSync(followLinks: false))
      if (entity is Directory &&
          !File(
            '${entity.path}${Platform.pathSeparator}'
            '${ComicCacheService._retainedMarker}',
          ).existsSync())
        entity.path,
  ];
}

class _CacheSnapshot {
  const _CacheSnapshot(this.root, this.pinned);

  final String root;
  final Set<String> pinned;
}

class _CacheEntry {
  const _CacheEntry(this.path, this.name, this.size, this.modified);

  final String path;
  final String name;
  final int size;
  final DateTime modified;
}

/// Returns folders to delete (least recently used first) to get back under
/// [cap]. A folder's age is the newer of its own modification time and its
/// retained marker's, which is refreshed every time the folder is reopened.
List<String> _planEviction(String root, Set<String> pinned, int cap) {
  final Directory rootDir = Directory(root);
  if (!rootDir.existsSync()) return const <String>[];

  final List<_CacheEntry> entries = <_CacheEntry>[];
  int total = 0;

  for (final FileSystemEntity entity in rootDir.listSync(followLinks: false)) {
    if (entity is! Directory) continue;

    final int size = _dirSize(entity);
    DateTime modified;
    try {
      modified = entity.statSync().modified;
    } on FileSystemException {
      continue;
    }

    try {
      final FileStat marker = File(
        '${entity.path}${Platform.pathSeparator}'
        '${ComicCacheService._retainedMarker}',
      ).statSync();
      if (marker.type != FileSystemEntityType.notFound &&
          marker.modified.isAfter(modified)) {
        modified = marker.modified;
      }
    } on FileSystemException {
      // No marker: the folder's own timestamp stands.
    }

    entries.add(
      _CacheEntry(
        entity.path,
        ComicCacheService._nameOf(entity.path),
        size,
        modified,
      ),
    );
    total += size;
  }

  if (total <= cap) return const <String>[];

  entries.sort(
    (_CacheEntry a, _CacheEntry b) => a.modified.compareTo(b.modified),
  );

  final List<String> victims = <String>[];
  for (final _CacheEntry entry in entries) {
    if (total <= cap) break;
    if (pinned.contains(entry.name)) continue;
    victims.add(entry.path);
    total -= entry.size;
  }
  return victims;
}

int _dirSize(Directory dir) {
  int total = 0;
  try {
    for (final FileSystemEntity entity in dir.listSync(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      try {
        total += entity.lengthSync();
      } on FileSystemException {
        // The file may have vanished while the scan was running.
      }
    }
  } on FileSystemException {
    // The folder may have vanished while the scan was running.
  }
  return total;
}
