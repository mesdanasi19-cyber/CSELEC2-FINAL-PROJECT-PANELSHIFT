import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Owns the temporary folders that .cbr archives are unpacked into.
///
/// All cache mutations are serialized through [_withLock]. Expensive directory
/// scans happen outside the lock; every deletion rechecks [_inUse] while holding
/// the lock, so a directory acquired during a scan cannot be evicted.
class ComicCacheService {
  ComicCacheService._();
  static final ComicCacheService instance = ComicCacheService._();

  static const String _rootFolderName = 'panelshift_cbr_cache';
  static const int maxCacheBytes = 500 * 1024 * 1024;

  /// A key may have only one active lease. Concurrently extracting the same
  /// key would otherwise delete or overwrite files being read by the first
  /// reader; reject that case instead of pretending a Set is a ref-count.
  final Set<String> _inUse = <String>{};

  Future<String>? _rootPathFuture;

  /// Tail-serialized async mutex.
  ///
  /// The tail is always a successful Future: an action's error is returned to
  /// its own caller, while [release] is completed from finally regardless of
  /// success, filesystem failure, or an exception thrown by the action.
  Future<void> _lockTail = Future<void>.value();

  Future<T> _withLock<T>(Future<T> Function() action) async {
    final Future<void> previous = _lockTail;
    final Completer<void> release = Completer<void>();
    _lockTail = release.future;

    try {
      await previous;
      return await action();
    } finally {
      if (!release.isCompleted) {
        release.complete();
      }
    }
  }

  Future<String> _rootPath() {
    final Future<String>? cached = _rootPathFuture;
    if (cached != null) return cached;

    final Completer<String> completer = Completer<String>();
    final Future<String> future = completer.future;
    _rootPathFuture = future;

    () async {
      try {
        final Directory tmp = await getTemporaryDirectory();
        final String path =
            '${tmp.path}${Platform.pathSeparator}$_rootFolderName';
        await Directory(path).create(recursive: true);
        completer.complete(path);
      } catch (error, stackTrace) {
        if (identical(_rootPathFuture, future)) {
          _rootPathFuture = null;
        }
        completer.completeError(error, stackTrace);
      }
    }();

    return future;
  }

  String _safeKey(String key) {
    final String safe = key.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    if (safe.isEmpty) {
      throw ArgumentError.value(key, 'key', 'Cache key must not be empty');
    }
    return safe;
  }

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

  /// Releases a cache lease and deletes its folder.
  ///
  /// Filesystem cleanup is best-effort; a cleanup failure must never prevent
  /// the lease from being removed or strand callers waiting on the mutex.
  Future<void> release(String key) async {
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
          await dir.delete(recursive: true);
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

  /// Deletes every folder that is not currently leased. Call at startup.
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

  Future<void> _deleteQuietly(Directory dir) async {
    try {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (error) {
      debugPrint('ComicCacheService: could not delete ${dir.path}: $error');
    }
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

List<String> _listFolders(String root) {
  final Directory rootDir = Directory(root);
  if (!rootDir.existsSync()) return const <String>[];
  return <String>[
    for (final FileSystemEntity entity in rootDir.listSync(followLinks: false))
      if (entity is Directory) entity.path,
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

/// Returns folders to delete (oldest first) to get back under [cap].
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
