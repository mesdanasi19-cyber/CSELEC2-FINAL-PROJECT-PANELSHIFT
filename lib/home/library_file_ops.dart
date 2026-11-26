import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
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
      _lastPickedUri = uri;
      _lastPickedName = pickedName;
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

  // The Android picker reports the display name separately from the URI
  // (a content:// URI does not always end in ".zip"), so the last pick is
  // remembered for [isZipArchive].
  static String _lastPickedUri = '';
  static String _lastPickedName = '';

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
      final ComicIdentity comic;
      if (entry.uri.startsWith('content://')) {
        final SafUriStat? info = await SafUriByteReader.stat(entry.uri);
        if (info == null) {
          debugPrint('PanelShift: "${entry.path}" is not readable, skipped.');
          return false;
        }
        comic = ComicIdentity.fromUri(
          uri: entry.uri,
          fileName: info.fileName.isEmpty ? entry.fileName : info.fileName,
          fileSize: info.size,
          md5Prefix: info.md5Prefix,
        ).copyWith(groupId: groupId, groupName: groupName);
      } else {
        // Desktop .zip import: entries are plain file paths, read in place.
        final ComicIdentity fromDisk = await Future<ComicIdentity>.value(
          ComicIdentity.fromFile(entry.uri),
        );
        comic = fromDisk.copyWith(groupId: groupId, groupName: groupName);
      }

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

  // ===========================================================================
  // .zip comic packs ("Import a comic" with a .zip)
  // ===========================================================================

  /// Whether [nameOrUri] is a `.zip` file. Pass the picked comic's
  /// `sourcePath` (or its file name). A `content://` URI does not always end
  /// in the file name, so the display name reported by the last
  /// [pickSingleComic] is used for that URI.
  static bool isZipArchive(String nameOrUri) {
    String text = nameOrUri;
    if (nameOrUri.startsWith('content://') &&
        nameOrUri == _lastPickedUri &&
        _lastPickedName.isNotEmpty) {
      text = _lastPickedName;
    }
    try {
      text = Uri.decodeComponent(text);
    } catch (_) {}
    return text.trim().toLowerCase().endsWith('.zip');
  }

  /// Extracts a picked `.zip` next to itself, deletes it once at least one
  /// comic came out, and lists the comics for a one-shelf folder-style import.
  ///
  /// The `.zip` is extracted into `<its folder>/<zip name>/` (a "(1)" suffix
  /// if that exists). Nested `.cbz/.cbr/.zip/.rar` files are copied with their
  /// relative paths; a `.zip` with only page images gets one stored `.cbz` per
  /// image folder. On failure or when nothing is found, the partial folder is
  /// removed and the `.zip` stays. Returns the entries in natural order of
  /// their relative path plus the zip's base name, or null ([notify] gets the
  /// reason). Hand the result to the folder import as it is: one group, one
  /// shelf.
  static Future<({List<FolderComicEntry> entries, String folderName})?>
  extractAndScanZipComic(
    String sourcePath, {
    required void Function(String message) notify,
  }) async {
    try {
      return Platform.isAndroid
          ? await _extractZipAndroid(sourcePath, notify)
          : await _extractZipDesktop(sourcePath, notify);
    } on PlatformException catch (e) {
      debugPrint('PanelShift: zip extraction failed: ${e.code} ${e.message}');
      notify(e.message ?? 'Could not extract the .zip file.');
      return null;
    } on FileSystemException catch (e) {
      debugPrint('PanelShift: zip extraction failed: $e');
      notify(
        e.message.isEmpty ? 'Could not extract the .zip file.' : e.message,
      );
      return null;
    } catch (e) {
      debugPrint('PanelShift: zip extraction failed: $e');
      notify('Could not extract the .zip file.');
      return null;
    }
  }

  static List<FolderComicEntry> _entriesFromReply(Map<String, dynamic> reply) {
    final List<FolderComicEntry> found = <FolderComicEntry>[];
    final List<Object?> rawFiles =
        (reply['files'] as List<Object?>?) ?? const <Object?>[];
    for (final Object? raw in rawFiles) {
      if (raw is! Map<Object?, Object?>) continue;
      final String? uri = raw['uri'] as String?;
      final String? fileName = raw['fileName'] as String?;
      if (uri == null || uri.isEmpty || fileName == null || fileName.isEmpty) {
        continue;
      }
      if (!_supportedExtensions.contains(fileName.split('.').last.toLowerCase())) {
        continue;
      }
      found.add(
        FolderComicEntry(
          uri: uri,
          fileName: fileName,
          path: (raw['path'] as String?) ?? fileName,
          size: (raw['size'] as num?)?.toInt() ?? -1,
        ),
      );
    }
    return found;
  }

  static Future<({List<FolderComicEntry> entries, String folderName})?>
  _extractZipAndroid(
    String sourcePath,
    void Function(String message) notify,
  ) async {
    // Can wait on the user: the folder-access picker may open first.
    final Map<String, dynamic>? reply = await _safChannel
        .invokeMapMethod<String, dynamic>(
          'extractZipToOriginalFolder',
          <String, Object?>{'uri': sourcePath},
        );
    if (reply == null) {
      notify('Extraction cancelled.');
      return null;
    }

    final List<FolderComicEntry> found = _entriesFromReply(reply);
    if (found.isEmpty) {
      notify('No comics or page images found in that .zip. It was left as it is.');
      return null;
    }
    if (reply['zipDeleted'] == false) {
      notify('Extracted, but the original .zip could not be deleted.');
    }

    String folderName = ((reply['folderName'] as String?) ?? '').trim();
    if (folderName.isEmpty) folderName = 'Imported Zip';
    return (
      entries: ComicParserService.sortNaturally(
        found,
        (FolderComicEntry entry) => entry.path,
      ),
      folderName: folderName,
    );
  }

  static Future<({List<FolderComicEntry> entries, String folderName})?>
  _extractZipDesktop(
    String sourcePath,
    void Function(String message) notify,
  ) async {
    final File zipFile = File(sourcePath);
    if (!await zipFile.exists()) {
      notify('Selected file could not be found on disk.');
      return null;
    }

    final _DesktopZipResult result = await Isolate.run(
      () => _extractZipOnDesktop(sourcePath),
    );
    if (result.files.isEmpty) {
      notify('No comics or page images found in that .zip. It was left as it is.');
      return null;
    }
    if (!result.zipDeleted) {
      notify('Extracted, but the original .zip could not be deleted.');
    }

    final List<FolderComicEntry> found = <FolderComicEntry>[
      for (final _DesktopZipFile file in result.files)
        FolderComicEntry(
          uri: file.path,
          fileName: file.path.split(RegExp(r'[\\/]')).last,
          path: file.relative,
          size: file.size,
        ),
    ];
    return (
      entries: ComicParserService.sortNaturally(
        found,
        (FolderComicEntry entry) => entry.path,
      ),
      folderName: result.zipBaseName,
    );
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


// =============================================================================
// Desktop .zip extraction (runs in a background isolate; dart:io only)
// =============================================================================

class _DesktopZipFile {
  const _DesktopZipFile(this.path, this.relative, this.size);

  final String path;
  final String relative;
  final int size;
}

class _DesktopZipResult {
  const _DesktopZipResult({
    required this.zipBaseName,
    required this.files,
    required this.zipDeleted,
  });

  final String zipBaseName;
  final List<_DesktopZipFile> files;
  final bool zipDeleted;
}

final RegExp _unsafeFileNameChars = RegExp(r'[\\/:*?"<>|]');

String _cleanZipSegment(String segment) {
  final String cleaned = segment.replaceAll(_unsafeFileNameChars, '_').trim();
  return cleaned.isEmpty ? '_' : cleaned;
}

/// Extracts [zipPath] into `<its folder>/<zip name>/`. Never leaves a partial
/// folder behind and deletes the `.zip` only after at least one comic exists.
_DesktopZipResult _extractZipOnDesktop(String zipPath) {
  final File zipFile = File(zipPath);
  final String zipName = zipPath.split(RegExp(r'[\\/]')).last;
  final String rawBase = zipName.toLowerCase().endsWith('.zip')
      ? zipName.substring(0, zipName.length - 4).trim()
      : zipName.trim();
  final String zipBaseName = rawBase.isEmpty ? 'Comic' : rawBase;
  final String folderBase = _cleanZipSegment(zipBaseName);

  // The whole archive is read once; entries are decompressed one at a time.
  final Archive archive = ZipDecoder().decodeBytes(zipFile.readAsBytesSync());

  // Zip Slip: refuse the whole archive if any entry climbs out with "..".
  final List<ArchiveFile> nestedArchives = <ArchiveFile>[];
  final Map<String, List<ArchiveFile>> imageFolders =
      <String, List<ArchiveFile>>{};
  for (final ArchiveFile file in archive.files) {
    if (!file.isFile) continue;
    final List<String> parts = ComicParserService.normalizeEntryPath(file.name)
        .split('/')
        .where((String part) => part.isNotEmpty && part != '.')
        .toList(growable: false);
    if (parts.any((String part) => part == '..')) {
      throw const FileSystemException(
        'The .zip contains an unsafe path ("..") and was not imported.',
      );
    }
    if (parts.isEmpty) continue;
    if (ComicParserService.isComicArchivePath(file.name)) {
      nestedArchives.add(file);
    } else if (ComicParserService.isPageImagePath(file.name)) {
      imageFolders
          .putIfAbsent(parts.take(parts.length - 1).join('/'), () => <ArchiveFile>[])
          .add(file);
    }
  }
  if (nestedArchives.isEmpty && imageFolders.isEmpty) {
    return _DesktopZipResult(
      zipBaseName: zipBaseName,
      files: const <_DesktopZipFile>[],
      zipDeleted: false,
    );
  }

  final Directory parent = zipFile.parent;
  final String sep = Platform.pathSeparator;
  String destName = folderBase;
  for (int n = 1;
      Directory('${parent.path}$sep$destName').existsSync() ||
          File('${parent.path}$sep$destName').existsSync();
      n++) {
    destName = '$folderBase ($n)';
  }
  final Directory dest = Directory('${parent.path}$sep$destName')..createSync();

  final List<_DesktopZipFile> produced = <_DesktopZipFile>[];
  bool succeeded = false;
  try {
    if (nestedArchives.isNotEmpty) {
      // Case A: nested comic archives keep their relative paths.
      for (final ArchiveFile file in nestedArchives) {
        final List<String> parts =
            ComicParserService.normalizeEntryPath(file.name)
                .split('/')
                .where((String part) => part.isNotEmpty && part != '.')
                .map(_cleanZipSegment)
                .toList(growable: false);
        final String relative = parts.join('/');
        final File out = File(
          '${dest.path}$sep${parts.join(sep)}',
        );
        out.parent.createSync(recursive: true);
        final Uint8List bytes = Uint8List.fromList(file.content as List<int>);
        out.writeAsBytesSync(bytes, flush: true);
        produced.add(_DesktopZipFile(out.path, relative, bytes.length));
      }
    } else {
      // Case B: one stored .cbz per image folder.
      final Map<String, String> names = _chooseCbzNames(
        imageFolders.keys,
        folderBase,
      );
      for (final MapEntry<String, List<ArchiveFile>> folder
          in imageFolders.entries) {
        final String cbzName = '${names[folder.key]}.cbz';
        final File out = File('${dest.path}$sep$cbzName');
        final int size = _writeStoredZip(out, folder.value);
        produced.add(_DesktopZipFile(out.path, cbzName, size));
      }
    }

    for (final _DesktopZipFile file in produced) {
      if (!File(file.path).existsSync() || File(file.path).lengthSync() <= 0) {
        throw FileSystemException('Extraction produced an empty file', file.path);
      }
    }
    if (produced.isEmpty) {
      return _DesktopZipResult(
        zipBaseName: zipBaseName,
        files: const <_DesktopZipFile>[],
        zipDeleted: false,
      );
    }
    succeeded = true;
  } finally {
    if (!succeeded) {
      try {
        dest.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  bool deleted = false;
  try {
    zipFile.deleteSync();
    deleted = true;
  } catch (_) {}
  return _DesktopZipResult(
    zipBaseName: zipBaseName,
    files: produced,
    zipDeleted: deleted,
  );
}

/// Leaf folder name per image folder; clashes fall back to the full path.
Map<String, String> _chooseCbzNames(Iterable<String> keys, String baseName) {
  String leaf(String key) => _cleanZipSegment(
    key.isEmpty ? baseName : key.substring(key.lastIndexOf('/') + 1),
  );

  final Map<String, int> leafUse = <String, int>{};
  for (final String key in keys) {
    leafUse.update(leaf(key).toLowerCase(), (int n) => n + 1, ifAbsent: () => 1);
  }
  final Set<String> used = <String>{};
  final Map<String, String> names = <String, String>{};
  for (final String key in keys) {
    String candidate = leaf(key);
    if (key.isNotEmpty && (leafUse[candidate.toLowerCase()] ?? 0) > 1) {
      candidate = _cleanZipSegment(key.replaceAll('/', ' - '));
    }
    String unique = candidate;
    for (int n = 1; !used.add(unique.toLowerCase()); n++) {
      unique = '$candidate ($n)';
    }
    names[key] = unique;
  }
  return names;
}

final List<int> _crcTable = List<int>.generate(256, (int n) {
  int c = n;
  for (int k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1);
  }
  return c;
}, growable: false);

int _crc32(List<int> data) {
  int c = 0xFFFFFFFF;
  for (final int byte in data) {
    c = _crcTable[(c ^ byte) & 0xFF] ^ (c >> 8);
  }
  return c ^ 0xFFFFFFFF;
}

/// Writes [pages] as an uncompressed (STORED) zip, one page in memory at a
/// time. Returns the file size.
int _writeStoredZip(File target, List<ArchiveFile> pages) {
  final RandomAccessFile raf = target.openSync(mode: FileMode.write);
  final BytesBuilder central = BytesBuilder(copy: false);
  final Set<String> usedNames = <String>{};
  int offset = 0;
  int count = 0;
  try {
    for (final ArchiveFile page in pages) {
      final String clean = _cleanZipSegment(
        ComicParserService.normalizeEntryPath(page.name).split('/').last,
      );
      String name = clean;
      for (int n = 1; !usedNames.add(name.toLowerCase()); n++) {
        final int dot = clean.lastIndexOf('.');
        name = dot > 0
            ? '${clean.substring(0, dot)} ($n)${clean.substring(dot)}'
            : '$clean ($n)';
      }
      final Uint8List nameBytes = Uint8List.fromList(utf8.encode(name));
      final List<int> data = page.content as List<int>;
      final int crc = _crc32(data);

      final ByteData local = ByteData(30)
        ..setUint32(0, 0x04034b50, Endian.little)
        ..setUint16(4, 20, Endian.little)
        ..setUint16(6, 0x0800, Endian.little) // UTF-8 names
        ..setUint16(8, 0, Endian.little) // stored
        ..setUint16(10, 0, Endian.little)
        ..setUint16(12, 33, Endian.little) // 1980-01-01
        ..setUint32(14, crc, Endian.little)
        ..setUint32(18, data.length, Endian.little)
        ..setUint32(22, data.length, Endian.little)
        ..setUint16(26, nameBytes.length, Endian.little)
        ..setUint16(28, 0, Endian.little);
      raf.writeFromSync(local.buffer.asUint8List());
      raf.writeFromSync(nameBytes);
      raf.writeFromSync(data);

      final ByteData entry = ByteData(46)
        ..setUint32(0, 0x02014b50, Endian.little)
        ..setUint16(4, 20, Endian.little)
        ..setUint16(6, 20, Endian.little)
        ..setUint16(8, 0x0800, Endian.little)
        ..setUint16(10, 0, Endian.little)
        ..setUint16(12, 0, Endian.little)
        ..setUint16(14, 33, Endian.little)
        ..setUint32(16, crc, Endian.little)
        ..setUint32(20, data.length, Endian.little)
        ..setUint32(24, data.length, Endian.little)
        ..setUint16(28, nameBytes.length, Endian.little)
        ..setUint32(42, offset, Endian.little);
      central
        ..add(entry.buffer.asUint8List())
        ..add(nameBytes);

      offset += 30 + nameBytes.length + data.length;
      count++;
      if (offset > 0xFFFFFFF0 || count > 0xFFFF) {
        throw FileSystemException('Image folder is too large for one .cbz', target.path);
      }
    }

    final Uint8List directory = central.takeBytes();
    raf.writeFromSync(directory);
    final ByteData end = ByteData(22)
      ..setUint32(0, 0x06054b50, Endian.little)
      ..setUint16(8, count, Endian.little)
      ..setUint16(10, count, Endian.little)
      ..setUint32(12, directory.length, Endian.little)
      ..setUint32(16, offset, Endian.little);
    raf.writeFromSync(end.buffer.asUint8List());
    return offset + directory.length + 22;
  } finally {
    raf.closeSync();
  }
}
