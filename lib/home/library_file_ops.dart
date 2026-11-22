import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/comic_cache_service.dart';
import '../../services/comic_cover_service.dart';
import '../../services/comic_identity.dart';
import '../../services/comic_library_service.dart';
import '../../services/comic_parser_service.dart';
import '../../services/reading_progress_service.dart';

/// One comic archive found by the Android folder scan. Only metadata: nothing
/// is copied until the comic's turn comes in the import loop.
class FolderComicEntry {
  const FolderComicEntry({
    required this.uri,
    required this.fileName,
    required this.path,
    required this.size,
  });

  /// Child document URI (content://...). It is the comic's `sourcePath`: the
  /// archive is read in place and never copied.
  final String uri;

  /// File-system-safe version of the display name (fallback title).
  final String fileName;

  /// Path relative to the picked folder; natural-sorted to get import order.
  final String path;

  /// Byte size reported by the storage provider, or -1 when unknown.
  final int size;
}

enum FileDeleteOutcome { deleted, skippedExternal, protectedOrLocked }

/// File, SAF and storage logic of the library dashboard. No widgets and no
/// `BuildContext`: user-facing messages go out through a `notify` callback and
/// the screen keeps every dialog, snackbar and progress banner.
class LibraryFileOps {
  const LibraryFileOps._();

  static const String _originalSourcesKey = 'panelshift.originalSources.v1';
  static const MethodChannel _safChannel = MethodChannel('panelshift/saf_picker');

  // sourceExists() answers are reused for a short while so a scrolling grid
  // (one card per comic) does not make a platform call per rebuild.
  static const Duration _existsTtl = Duration(seconds: 20);
  static final Map<String, ({bool exists, DateTime at})> _existsCache =
      <String, ({bool exists, DateTime at})>{};
  static final Map<String, Future<bool>> _existsInFlight =
      <String, Future<bool>>{};

  /// Folder import also picks up comics inside sub-folders (breadth-first, up
  /// to 8 levels). Set to false to import only the picked folder's own files.
  static const bool _folderImportScansSubfolders = true;

  static const Set<String> _supportedExtensions = <String>{
    'cbz',
    'zip',
    'cbr',
    'rar',
  };

  /// Legacy `imported_comics/` folder. New imports no longer write here; it is
  /// only used to recognise and clean up copies made by older versions.
  static Future<Directory> managedLibraryDir() async {
    final Directory supportDir = await getApplicationSupportDirectory();
    return Directory(
      '${supportDir.path}${Platform.pathSeparator}imported_comics',
    );
  }

  /// LEGACY: copies an archive into `imported_comics/`. No import flow calls
  /// this any more (comics are read from their original location); it remains
  /// only for callers outside the library dashboard.
  static Future<String> persistPickedFile(String pickedPath) async {
    final Directory libraryDir = await managedLibraryDir();
    if (!await libraryDir.exists()) {
      await libraryDir.create(recursive: true);
    }

    final String sep = Platform.pathSeparator;
    final String prefix = '${libraryDir.path}$sep';
    if (pickedPath.startsWith(prefix)) return pickedPath;

    final String fileName = pickedPath.split(RegExp(r'[\\/]')).last;
    final File sourceFile = File(pickedPath);
    final int sourceLength = await sourceFile.length();

    // Reuse an existing managed copy if it has the same name and byte size.
    File target = File('$prefix$fileName');
    if (await target.exists()) {
      if (await target.length() == sourceLength) {
        return target.path;
      }
      // Different file with the same filename: keep the clean filename inside
      // a unique subfolder so ComicIdentity still reads the original title.
      final Directory bucket = Directory(
        '$prefix${DateTime.now().microsecondsSinceEpoch}',
      );
      await bucket.create(recursive: true);
      target = File('${bucket.path}$sep$fileName');
    }

    await sourceFile.copy(target.path);

    // Remove only file_picker's transient cache copy, never a user folder.
    if (pickedPath.contains('${sep}file_picker$sep')) {
      try {
        await sourceFile.delete();
      } catch (_) {}
    }

    return target.path;
  }

  /// Deletes a legacy internal copy in `imported_comics/` (and any leftover
  /// picker cache file). A `content://` URI or any other external path is the
  /// user's own file: it is left alone and [FileDeleteOutcome.skippedExternal]
  /// is returned, unless [deleteExternal] is true, which deletes it if the OS
  /// permits.
  static Future<FileDeleteOutcome> deleteComicFile(
      String sourcePath, {
        required bool deleteExternal,
      }) async {
    _forgetSourceExists(sourcePath);

    if (sourcePath.startsWith('content://')) {
      return deleteExternal
          ? deleteOriginalLocator(sourcePath)
          : FileDeleteOutcome.skippedExternal;
    }

    final Directory libraryDir = await managedLibraryDir();
    final Directory tempDir = await getTemporaryDirectory();
    final String sep = Platform.pathSeparator;

    final String managedPrefix = '${libraryDir.path}$sep';
    final String pickerCachePrefix = '${tempDir.path}${sep}file_picker$sep';

    final bool isAppOwned =
        sourcePath.startsWith(managedPrefix) ||
            sourcePath.startsWith(pickerCachePrefix);

    if (!isAppOwned && !deleteExternal) {
      return FileDeleteOutcome.skippedExternal;
    }

    final File file = File(sourcePath);
    if (!await file.exists()) {
      return FileDeleteOutcome.deleted;
    }

    try {
      await file.delete();
    } on FileSystemException catch (e) {
      debugPrint('PanelShift: could not delete file "$sourcePath": $e');
      if (!isAppOwned) {
        return FileDeleteOutcome.protectedOrLocked;
      }
      rethrow;
    }

    // If the file lived in a collision subfolder inside imported_comics/,
    // remove the folder once it is empty.
    if (sourcePath.startsWith(managedPrefix)) {
      final Directory parent = file.parent;
      if (parent.path != libraryDir.path && await parent.exists()) {
        if (await parent.list().isEmpty) {
          await parent.delete();
        }
      }
    }

    return FileDeleteOutcome.deleted;
  }

  static void _forgetSourceExists(String sourcePath) {
    _existsCache.remove(sourcePath);
    _existsInFlight.remove(sourcePath);
  }

  /// Whether the comic's archive can still be read: `existsUri` for a
  /// `content://` document, a plain file check otherwise. Answers are cached
  /// for a few seconds and concurrent asks for the same path share one check.
  static Future<bool> sourceExists(String sourcePath) {
    final ({bool exists, DateTime at})? cached = _existsCache[sourcePath];
    if (cached != null && DateTime.now().difference(cached.at) < _existsTtl) {
      return Future<bool>.value(cached.exists);
    }
    final Future<bool>? running = _existsInFlight[sourcePath];
    if (running != null) return running;

    final Future<bool> check = _checkSourceExists(sourcePath);
    _existsInFlight[sourcePath] = check;
    return check.whenComplete(() {
      if (identical(_existsInFlight[sourcePath], check)) {
        _existsInFlight.remove(sourcePath);
      }
    });
  }

  static Future<bool> _checkSourceExists(String sourcePath) async {
    try {
      final bool exists = sourcePath.startsWith('content://')
          ? (await _safChannel.invokeMethod<bool>(
                  'existsUri',
                  <String, Object?>{'uri': sourcePath},
                )) ==
                true
          : await File(sourcePath).exists();
      _existsCache[sourcePath] = (exists: exists, at: DateTime.now());
      return exists;
    } catch (e) {
      // Not cached: a transient platform error must not stick for the TTL.
      debugPrint('PanelShift: could not check "$sourcePath": $e');
      return false;
    }
  }

  static Future<Map<String, String>> loadOriginalSources() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString(_originalSourcesKey);
      if (raw == null || raw.isEmpty) return <String, String>{};
      final Map<String, dynamic> decoded =
      jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map(
            (String k, dynamic v) => MapEntry<String, String>(k, v.toString()),
      );
    } catch (e) {
      debugPrint('PanelShift: could not load original source map: $e');
      return <String, String>{};
    }
  }

  static Future<void> saveOriginalSource(String comicId, String locator) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final Map<String, String> map = await loadOriginalSources();
      map[comicId] = locator;
      await prefs.setString(_originalSourcesKey, jsonEncode(map));
    } catch (e) {
      debugPrint('PanelShift: could not save original source locator: $e');
    }
  }

  static Future<String?> takeOriginalSource(String comicId) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final Map<String, String> map = await loadOriginalSources();
      final String? removed = map.remove(comicId);
      if (removed != null) {
        await prefs.setString(_originalSourcesKey, jsonEncode(map));
      }
      return removed;
    } catch (e) {
      debugPrint('PanelShift: could not remove original source locator: $e');
      return null;
    }
  }

  static Future<FileDeleteOutcome> deleteOriginalLocator(String locator) async {
    if (locator.startsWith('content://')) {
      try {
        final bool? deleted = await _safChannel.invokeMethod<bool>(
          'deleteUri',
          <String, Object?>{'uri': locator},
        );
        return deleted == true
            ? FileDeleteOutcome.deleted
            : FileDeleteOutcome.protectedOrLocked;
      } catch (e) {
        debugPrint('PanelShift: SAF URI delete failed for "$locator": $e');
        return FileDeleteOutcome.protectedOrLocked;
      }
    }

    final File originalFile = File(locator);
    if (!await originalFile.exists()) {
      return FileDeleteOutcome.deleted;
    }
    try {
      await originalFile.delete();
      return FileDeleteOutcome.deleted;
    } on FileSystemException catch (e) {
      debugPrint('PanelShift: original file delete failed for "$locator": $e');
      return FileDeleteOutcome.protectedOrLocked;
    }
  }

  /// Lets the user pick one comic archive (Android `pickComic` channel, or
  /// [FilePicker] elsewhere) and returns its [ComicIdentity], or null when
  /// nothing usable was picked ([notify] gets the reason).
  ///
  /// Nothing is copied: on Android the identity's `sourcePath` is the persisted
  /// `content://` URI, on desktop the original file path.
  static Future<ComicIdentity?> pickSingleComic({
    required void Function(String message) notify,
  }) async {
    if (Platform.isAndroid) {
      final Map<String, dynamic>? picked =
          await _safChannel.invokeMapMethod<String, dynamic>('pickComic');
      final String? uri = picked?['uri'] as String?;
      if (picked == null || uri == null || uri.isEmpty) {
        notify('File selection cancelled.');
        return null;
      }

      final String pickedName = (picked['fileName'] as String?) ?? '';
      if (!_hasSupportedExtension(pickedName)) {
        notify('Please select a .cbz, .zip, .cbr, or .rar file.');
        return null;
      }

      final SafUriStat? info = await SafUriByteReader.stat(uri);
      if (info == null) {
        notify('Selected file could not be read.');
        return null;
      }
      return ComicIdentity.fromUri(
        uri: uri,
        fileName: info.fileName.isEmpty ? pickedName : info.fileName,
        fileSize: info.size,
        md5Prefix: info.md5Prefix,
      );
    }

    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['cbz', 'zip', 'cbr', 'rar'],
    );

    if (files.isEmpty || files.first.path == null) {
      notify('File selection cancelled.');
      return null;
    }
    // On desktop, FilePicker returns the real original path: read it in place.
    final String path = files.first.path!;
    if (!_hasSupportedExtension(path)) {
      notify('Please select a .cbz, .zip, .cbr, or .rar file.');
      return null;
    }
    if (!await File(path).exists()) {
      notify('Selected file could not be found on disk.');
      return null;
    }
    return ComicIdentity.fromFile(path);
  }

  static bool _hasSupportedExtension(String name) =>
      _supportedExtensions.contains(name.split('.').last.toLowerCase());

  /// Last path component of a directory path (desktop: the picked directory's
  /// basename). Trailing separators are ignored; returns '' for an empty path.
  static String _folderBaseName(String path) {
    final List<String> parts = path
        .split(RegExp(r'[\\/]'))
        .where((String part) => part.isNotEmpty)
        .toList(growable: false);
    return parts.isEmpty ? '' : parts.last;
  }

  /// Name of the picked folder: Android's `folderName` map key, or (when the
  /// platform did not report one) the basename of the picked location.
  static String _resolveFolderName(Map<String, dynamic> picked) {
    final String reported = ((picked['folderName'] as String?) ?? '').trim();
    if (reported.isNotEmpty) return reported;

    String location = (picked['treeUri'] as String?) ?? '';
    try {
      location = Uri.decodeComponent(location);
    } catch (_) {}
    // `...tree/primary:Comics/Marvel` -> `Marvel`; `primary:Comics` -> `Comics`.
    final String base = _folderBaseName(location).split(':').last.trim();
    return base.isEmpty ? 'Imported Folder' : base;
  }

  /// Lets the user pick a folder and lists every comic archive in it (Android
  /// `pickComicFolder` channel; metadata only, nothing is copied), in natural
  /// order of the relative path: "Issue 2" before "Issue 10", and files stay
  /// grouped by sub-folder. Returns the entries together with the picked
  /// folder's name, or null when there is nothing to import; [notify] gets the
  /// reason.
  static Future<({List<FolderComicEntry> entries, String folderName})?>
  scanComicFolder({
    required void Function(String message) notify,
  }) async {
    if (!Platform.isAndroid) {
      notify('Folder import is available on Android only.');
      return null;
    }

    final Map<String, dynamic>? picked =
        await _safChannel.invokeMapMethod<String, dynamic>(
      'pickComicFolder',
      <String, Object?>{'recursive': _folderImportScansSubfolders},
    );
    if (picked == null) {
      notify('Folder selection cancelled.');
      return null;
    }

    final List<FolderComicEntry> found = <FolderComicEntry>[];
    final List<Object?> rawFiles =
        (picked['files'] as List<Object?>?) ?? const <Object?>[];
    for (final Object? raw in rawFiles) {
      if (raw is! Map<Object?, Object?>) continue;
      final String? uri = raw['uri'] as String?;
      final String? fileName = raw['fileName'] as String?;
      if (uri == null || uri.isEmpty || fileName == null || fileName.isEmpty) {
        continue;
      }
      final String ext = fileName.split('.').last.toLowerCase();
      if (!_supportedExtensions.contains(ext)) continue;
      found.add(
        FolderComicEntry(
          uri: uri,
          fileName: fileName,
          path: (raw['path'] as String?) ?? fileName,
          size: (raw['size'] as num?)?.toInt() ?? -1,
        ),
      );
    }

    if (found.isEmpty) {
      notify('No .cbz, .zip, .cbr or .rar files found in that folder.');
      return null;
    }

    // Natural order on the relative path: "Issue 2" before "Issue 10", and
    // files stay grouped by sub-folder.
    final List<FolderComicEntry> sorted = ComicParserService.sortNaturally(
      found,
      (FolderComicEntry entry) => entry.path,
    );
    return (entries: sorted, folderName: _resolveFolderName(picked));
  }

  /// Imports one comic of a folder scan. Returns true when it is in the library.
  /// Never throws; a bad archive must not stop the rest of the folder.
  ///
  /// [groupId] is shared by every comic of one folder import (it keeps them on
  /// one shelf group) and [groupName] is the cleaned folder title shown on it.
  ///
  /// Nothing is copied: the comic is registered with its `content://` URI as
  /// `sourcePath`. Only the cover thumbnail and the JSON index caches are
  /// written to app storage.
  static Future<bool> importSingleFolderEntry(
    FolderComicEntry entry, {
    required String groupId,
    required String groupName,
  }) async {
    try {
      final SafUriStat? info = await SafUriByteReader.stat(entry.uri);
      if (info == null) {
        debugPrint('PanelShift: "${entry.path}" is not readable, skipped.');
        return false;
      }
      final ComicIdentity comic = ComicIdentity.fromUri(
        uri: entry.uri,
        fileName: info.fileName.isEmpty ? entry.fileName : info.fileName,
        fileSize: info.size,
        md5Prefix: info.md5Prefix,
      ).copyWith(groupId: groupId, groupName: groupName);

      // Cover first (a no-op when one exists). This opens the archive in place
      // and also records its page count; the reference is released right away.
      final ComicCoverService covers = ComicCoverService.instance;
      final ComicCover? cover;
      try {
        cover = await covers.request(comic);
      } finally {
        covers.release(comic.id);
      }

      final int? pageCount = cover?.pageCount;
      if (pageCount == null || pageCount <= 0) {
        debugPrint('PanelShift: no image pages in "${entry.path}", skipped.');
        return false;
      }

      await ComicLibraryService.addComic(comic);
      return true;
    } catch (e) {
      debugPrint('PanelShift: folder import failed for "${entry.path}": $e');
      return false;
    }
  }

  /// Comics that show the "Finished" badge: their saved position is on the
  /// last page. Comics that were never opened (no saved progress) are skipped.
  ///
  /// Scans [among]: the whole library, or just the selection.
  static Future<List<ComicIdentity>> findFinishedComics(
    Iterable<ComicIdentity> among,
  ) async {
    final ComicCoverService covers = ComicCoverService.instance;
    final List<ComicIdentity> finished = <ComicIdentity>[];

    for (final ComicIdentity comic in List<ComicIdentity>.of(among)) {
      final ReadingProgress? progress = await ReadingProgressService.load(
        comic.id,
      );
      if (progress == null) continue;

      // The page count comes from the (disk-cached) cover entry.
      ComicCover? cover = covers.cached(comic.id);
      if (cover == null) {
        try {
          cover = await covers.request(comic);
        } catch (e) {
          debugPrint('PanelShift: no page count for ${comic.title}: $e');
        } finally {
          covers.release(comic.id);
        }
      }

      final int? pageCount = cover?.pageCount;
      if (pageCount == null || pageCount <= 0) continue;
      if (math.max(progress.page, 0) + 1 >= pageCount) finished.add(comic);
    }
    return finished;
  }

  /// Wipes registry entry, cover, reading progress, cached archive index and
  /// retained CBR extraction for one entry, plus any legacy internal copy.
  /// The user's own file (content:// URI or external path) is deleted only when
  /// [deleteExternalFiles] is true. The caller drops the comic from its own
  /// pre-index queue first.
  static Future<({bool ok, bool externalProtected})> purgeComic(
      ComicIdentity comic, {
        required bool deleteExternalFiles,
      }) async {
    final String id = comic.id;
    bool ok = true;
    bool externalProtected = false;

    Future<bool> step(Future<void> Function() action) async {
      try {
        await action();
        return true;
      } catch (e) {
        ok = false;
        debugPrint('PanelShift: cleanup step failed for $id: $e');
        return false;
      }
    }

    if (!await step(() => ComicLibraryService.removeComic(id))) {
      return (ok: false, externalProtected: false);
    }
    await step(() => ComicCoverService.instance.delete(id));
    await step(() => ReadingProgressService.clear(id));
    await step(() => ComicCacheService.instance.deleteIndexCache(id));
    await step(() async {
      // A legacy internal copy (imported_comics/) is always removed. For a
      // content:// URI or an external desktop path this is a no-op that reports
      // skippedExternal: that file belongs to the user.
      final FileDeleteOutcome ownCopy = await deleteComicFile(
        comic.sourcePath,
        deleteExternal: false,
      );
      final bool sourceIsExternal = ownCopy == FileDeleteOutcome.skippedExternal;

      // Old imports also recorded where the original came from.
      final String? legacyOriginal = await takeOriginalSource(id);

      if (deleteExternalFiles) {
        final Set<String> targets = <String>{
          if (sourceIsExternal) comic.sourcePath,
          if (legacyOriginal != null && legacyOriginal.isNotEmpty)
            legacyOriginal,
        };
        for (final String target in targets) {
          final FileDeleteOutcome outcome = await deleteOriginalLocator(target);
          if (outcome == FileDeleteOutcome.protectedOrLocked) {
            externalProtected = true;
          }
        }
      }
    });
    return (ok: ok, externalProtected: externalProtected);
  }
}
