import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'comic_identity.dart';

/// Where the reader was last: physical page + panel on that page.
class ReadingProgress {
  final int page;
  final int panelIndex;
  final DateTime updatedAt;

  const ReadingProgress({
    required this.page,
    required this.panelIndex,
    required this.updatedAt,
  });

  Map<String, dynamic> toJson() => {
    'page': page,
    'panel': panelIndex,
    'ts': updatedAt.millisecondsSinceEpoch,
  };

  static ReadingProgress? tryParse(String? raw) {
    if (raw == null) return null;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return ReadingProgress(
        page: (map['page'] as num).toInt(),
        panelIndex: (map['panel'] as num).toInt(),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(
          (map['ts'] as num).toInt(),
        ),
      );
    } catch (_) {
      return null; // corrupt / older format -> behave as "nothing saved"
    }
  }

}

/// The comic that was open most recently, for a "Continue reading" shortcut.
class LastReadComic {
  final ComicIdentity comic;
  final ReadingProgress? progress;
  const LastReadComic(this.comic, this.progress);
}

/// Persistent storage for reading progress (one small JSON record per comic).
class ReadingProgressService {
  ReadingProgressService._();

  static const String _progressPrefix = 'panelshift.progress.v1.';
  static const String _lastComicKey = 'panelshift.lastComic.v1';

  /// Bumped after every successful write so UI (e.g. the launch screen) can
  /// refresh its "Continue reading" button.
  static final ValueNotifier<int> changes = ValueNotifier<int>(0);
  static final Map<String, Future<void>> _saveTails = <String, Future<void>>{};

  static Future<ReadingProgress?> load(String comicId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return ReadingProgress.tryParse(
        prefs.getString('$_progressPrefix$comicId'),
      );
    } catch (e) {
      debugPrint('ReadingProgressService.load failed: $e');
      return null;
    }
  }

  static Future<bool> save(
    ComicIdentity comic, {
    required int page,
    required int panelIndex,
  }) {
    final String key = comic.id;

    final Completer<bool> result = Completer<bool>();

    // Wait for the previous write for this comic.
    final Future<void> previous = _saveTails[key] ?? Future<void>.value();

    late final Future<void> next;

    next = previous.then((_) async {
      try {
        final prefs = await SharedPreferences.getInstance();

        final record = ReadingProgress(
          page: page,
          panelIndex: panelIndex,
          updatedAt: DateTime.now(),
        );

        final bool ok = await prefs.setString(
          '$_progressPrefix$key',
          jsonEncode(record.toJson()),
        );

        if (ok) {
          changes.value++;
        }

        if (!result.isCompleted) {
          result.complete(ok);
        }
      } catch (e, st) {
        debugPrint('ReadingProgressService.save failed: $e\n$st');

        if (!result.isCompleted) {
          result.complete(false);
        }
      }
    });

    _saveTails[key] = next;

    return result.future.whenComplete(() {
      // Do not remove a newer queued write.
      if (identical(_saveTails[key], next)) {
        _saveTails.remove(key);
      }
    });
  }

  /// Remembers which comic was opened last (identity only; the position
  /// itself lives in the per-comic record).
  static Future<void> markOpened(ComicIdentity comic) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _lastComicKey,
        jsonEncode({
          'id': comic.id,
          'title': comic.title,
          'path': comic.sourcePath,
        }),
      );
      changes.value++;
    } catch (e) {
      debugPrint('ReadingProgressService.markOpened failed: $e');
    }
  }

  static Future<LastReadComic?> lastRead() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_lastComicKey);
      if (raw == null) return null;
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final comic = ComicIdentity(
        id: map['id'] as String,
        title: map['title'] as String,
        sourcePath: map['path'] as String,
      );
      return LastReadComic(
        comic,
        ReadingProgress.tryParse(
          prefs.getString('$_progressPrefix${comic.id}'),
        ),
      );
    } catch (e) {
      debugPrint('ReadingProgressService.lastRead failed: $e');
      return null;
    }
  }

  /// Clears the stored reading progress for a specific comic ID.
  static Future<bool> clear(String comicId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final bool ok = await prefs.remove('$_progressPrefix$comicId');
      if (ok) {
        changes.value++;
      }
      return ok;
    } catch (e) {
      debugPrint('ReadingProgressService.clear failed: $e');
      return false;
    }
  }
}

/// Debounced writer owned by one open reader.
///
/// The reader calls [update] on every navigation change; the position is only
/// written once it has been stable for [debounce] (default 1.5 s). [flush]
/// forces an immediate write (app backgrounded, reader closed).

class ReadingProgressTracker {
  ReadingProgressTracker({
    required this.comic,
    this.debounce = const Duration(milliseconds: 1500),
  });

  final ComicIdentity comic;
  final Duration debounce;

  Timer? _timer;
  bool _closed = false;

  int? _savedPage;
  int? _savedPanel;

  int? _pendingPage;
  int? _pendingPanel;

  Future<void>? _flushInFlight;

  bool get _isDirty =>
      _pendingPage != null &&
      (_pendingPage != _savedPage || _pendingPanel != _savedPanel);

  void seed(int page, int panelIndex) {
    if (_closed) return;

    _savedPage = page;
    _savedPanel = panelIndex;
  }

  void update(int page, int panelIndex) {
    if (_closed) return;

    _pendingPage = page;
    _pendingPanel = panelIndex;

    _timer?.cancel();
    _timer = null;

    if (_isDirty) {
      _timer = Timer(debounce, () {
        unawaited(flush());
      });
    }
  }

  Future<void> flush() {
    _timer?.cancel();
    _timer = null;

    // If another flush is running, wait for it and then
    // write again only if the newest position is still dirty.
    final Future<void>? active = _flushInFlight;

    if (active != null) {
      return active.then((_) {
        return _isDirty ? flush() : Future<void>.value();
      });
    }

    if (!_isDirty) {
      return Future<void>.value();
    }

    final int page = _pendingPage!;
    final int panel = _pendingPanel!;

    final int? previousPage = _savedPage;
    final int? previousPanel = _savedPanel;

    // Optimistic baseline prevents duplicate writes.
    _savedPage = page;
    _savedPanel = panel;

    late final Future<void> operation;

    operation =
        () async {
          final bool ok = await ReadingProgressService.save(
            comic,
            page: page,
            panelIndex: panel,
          );

          if (!ok && _savedPage == page && _savedPanel == panel) {
            // Restore the previous baseline so a later flush retries.
            _savedPage = previousPage;
            _savedPanel = previousPanel;
          }
        }().whenComplete(() {
          if (identical(_flushInFlight, operation)) {
            _flushInFlight = null;
          }
        });

    _flushInFlight = operation;

    return operation;
  }

  Future<void> dispose() {
    _closed = true;
    _timer?.cancel();
    _timer = null;

    // Flush is still allowed after closing; update() is not.
    return flush();
  }
}
