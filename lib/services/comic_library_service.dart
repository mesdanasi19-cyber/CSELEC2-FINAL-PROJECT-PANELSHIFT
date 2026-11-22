import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'comic_identity.dart';

/// Persistent registry of every comic the user has imported.
///
/// [ReadingProgressService] only remembers the single most recent comic; this
/// service keeps the full list (newest import first) so the home screen can
/// render a library. Reading positions stay in [ReadingProgressService]; this
/// only stores identity (`id`, `title`, `sourcePath`) plus, for comics that came
/// from a folder import, the optional shelf group (`groupId`, `groupName`).
class ComicLibraryService {
  ComicLibraryService._();

  static const String _libraryKey = 'panelshift.library.v1';

  /// Bumped after every successful change to the registry so the UI can reload.
  static final ValueNotifier<int> libraryChanges = ValueNotifier<int>(0);

  /// Tail-serialised mutex: read-modify-write cycles must not interleave, or two
  /// quick imports could overwrite each other. The tail never completes with an
  /// error, so one failed write cannot block later ones.
  static Future<void> _writeTail = Future<void>.value();

  static Future<T> _serialized<T>(Future<T> Function() action) {
    final Future<void> previous = _writeTail;
    final Completer<void> done = Completer<void>();
    _writeTail = done.future;

    return () async {
      try {
        await previous;
        return await action();
      } finally {
        done.complete();
      }
    }();
  }

  /// Returns all imported comics, newest import first.
  static Future<List<ComicIdentity>> loadLibrary() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      return _decode(prefs.getString(_libraryKey));
    } catch (e) {
      debugPrint('ComicLibraryService.loadLibrary failed: $e');
      return <ComicIdentity>[];
    }
  }

  /// Registers [comic]. Duplicates are detected by [ComicIdentity.id].
  ///
  /// The id survives renames and moves, so when the same comic is imported
  /// again from a different path, the existing entry keeps its position and
  /// just has its path/title refreshed. Nothing is written (and nobody is
  /// notified) when the entry is already up to date.
  static Future<void> addComic(ComicIdentity comic) {
    return _serialized<void>(() async {
      try {
        final SharedPreferences prefs = await SharedPreferences.getInstance();
        final List<ComicIdentity> library = _decode(
          prefs.getString(_libraryKey),
        );

        final int index = library.indexWhere(
          (ComicIdentity c) => c.id == comic.id,
        );
        if (index >= 0) {
          final ComicIdentity existing = library[index];

          // A comic that carries a group (folder import) moves into that
          // group. One without a group (a single-file import, or simply
          // re-opening a comic from the library) never takes it out of the
          // folder shelf it already lives on.
          final String? nextGroupId = comic.isGrouped
              ? comic.groupId
              : existing.groupId;
          final String? nextGroupName = comic.isGrouped
              ? comic.groupName
              : existing.groupName;

          if (existing.sourcePath == comic.sourcePath &&
              existing.title == comic.title &&
              existing.groupId == nextGroupId &&
              existing.groupName == nextGroupName) {
            return;
          }
          library[index] = comic.copyWith(
            groupId: nextGroupId,
            groupName: nextGroupName,
          );
        } else {
          // New entries keep exactly the grouping they arrive with: a
          // single-file import (groupId == null) stays ungrouped.
          library.insert(0, comic);
        }

        if (await prefs.setString(_libraryKey, _encode(library))) {
          libraryChanges.value++;
        }
      } catch (e, st) {
        // A registry failure must never stop the user from reading.
        debugPrint('ComicLibraryService.addComic failed: $e\n$st');
      }
    });
  }

  /// Removes a comic from the registry. The file on disk and the saved reading
  /// position are left alone.
  static Future<void> removeComic(String comicId) {
    return _serialized<void>(() async {
      try {
        final SharedPreferences prefs = await SharedPreferences.getInstance();
        final List<ComicIdentity> library = _decode(
          prefs.getString(_libraryKey),
        );

        final int before = library.length;
        library.removeWhere((ComicIdentity c) => c.id == comicId);
        if (library.length == before) return;

        if (await prefs.setString(_libraryKey, _encode(library))) {
          libraryChanges.value++;
        }
      } catch (e, st) {
        debugPrint('ComicLibraryService.removeComic failed: $e\n$st');
      }
    });
  }

  // ---------------------------------------------------------------------------
  // (De)serialisation. Same field names as ReadingProgressService's "last
  // comic" record, so the two stay easy to reason about together.
  // ---------------------------------------------------------------------------

  static String _encode(List<ComicIdentity> library) => jsonEncode(
    <Map<String, String>>[
      for (final ComicIdentity c in library)
        <String, String>{
          'id': c.id,
          'title': c.title,
          'path': c.sourcePath,
          // Only written for folder imports, so ungrouped entries keep the
          // exact shape older versions of the app wrote and read.
          if (c.isGrouped) 'groupId': c.groupId!,
          if (c.isGrouped && (c.groupName?.isNotEmpty ?? false))
            'groupName': c.groupName!,
        },
    ],
  );

  /// Tolerant decoder: corrupt entries are skipped, duplicates collapsed.
  static List<ComicIdentity> _decode(String? raw) {
    final List<ComicIdentity> result = <ComicIdentity>[];
    if (raw == null) return result;

    try {
      final Object? parsed = jsonDecode(raw);
      if (parsed is! List) return result;

      final Set<String> seen = <String>{};
      for (final Object? item in parsed) {
        if (item is! Map) continue;
        final Object? id = item['id'];
        final Object? title = item['title'];
        final Object? path = item['path'];
        if (id is! String || title is! String || path is! String) continue;
        if (!seen.add(id)) continue;

        // Entries written before folder shelves existed have no group keys:
        // they load as ungrouped (null / null), no migration needed.
        final Object? rawGroupId = item['groupId'];
        final Object? rawGroupName = item['groupName'];
        final String? groupId = rawGroupId is String && rawGroupId.isNotEmpty
            ? rawGroupId
            : null;
        final String? groupName =
            groupId != null && rawGroupName is String && rawGroupName.isNotEmpty
            ? rawGroupName
            : null;

        result.add(
          ComicIdentity(
            id: id,
            title: title,
            sourcePath: path,
            groupId: groupId,
            groupName: groupName,
          ),
        );
      }
    } catch (e) {
      debugPrint('ComicLibraryService: corrupt library record ignored: $e');
    }
    return result;
  }
}
