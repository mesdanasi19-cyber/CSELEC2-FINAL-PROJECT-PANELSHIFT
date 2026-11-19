import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';

import 'services/comic_cache_service.dart';
import 'services/comic_cover_service.dart';
import 'services/comic_identity.dart';
import 'services/comic_library_service.dart';
import 'services/comic_parser_service.dart';
import 'services/reading_progress_service.dart';
import 'screens/comic_reader_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Orphan cleanup is pure disk I/O. Started before the first frame it competes
  // with the library's cover reads on slow flash storage, so it waits until the
  // UI has settled.
  unawaited(
    Future<void>.delayed(const Duration(seconds: 4))
        .then<void>((_) => ComicCacheService.instance.purgeOrphans())
        .catchError((Object error, StackTrace st) {
          debugPrint('PanelShift cache cleanup failed: $error');
        }),
  );
  runApp(const PanelShiftApp());
}

class PanelShiftApp extends StatelessWidget {
  const PanelShiftApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PanelShift Core',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      home: const ComicProcessorScreen(title: 'PanelShift Core Engine'),
    );
  }
}

/// ==========================================
/// 1. Library Dashboard (import + grid/list)
/// ==========================================
enum LibraryViewMode { grid, list }

/// Sort criteria for the library dashboard. The enum [name] is what gets
/// persisted in SharedPreferences.
enum LibrarySort {
  newestFirst('Newest to oldest import'),
  oldestFirst('Oldest to newest import'),
  recentlyRead('Recently read'),
  titleAZ('Alphabetical (A-Z)');

  const LibrarySort(this.label);

  final String label;
}

enum _LibraryMenuAction { deleteRead }

enum _FileDeleteOutcome { deleted, skippedExternal, protectedOrLocked }

class ComicProcessorScreen extends StatefulWidget {
  const ComicProcessorScreen({super.key, required this.title});

  final String title;

  @override
  State<ComicProcessorScreen> createState() => _ComicProcessorScreenState();
}

class _ComicProcessorScreenState extends State<ComicProcessorScreen> {
  static const String _viewModeKey = 'panelshift.libraryViewMode.v1';
  static const String _bookshelfModeKey = 'panelshift.bookshelfMode.v1';
  static const String _sortKey = 'panelshift.librarySort.v1';
  static const String _originalSourcesKey = 'panelshift.originalSources.v1';
  static const MethodChannel _safChannel = MethodChannel('panelshift/saf_picker');

  /// Order in which [ComicLibraryService.loadLibrary] returns comics: `true`
  /// when the oldest import comes first (new imports are appended), `false`
  /// when the newest import comes first. If "Newest to oldest import" shows
  /// up reversed, flip this one flag.
  static const bool _registryIsOldestFirst = true;

  static final RegExp _numberChunks = RegExp(r'\d+|\D+');
  static final RegExp _leadingZeros = RegExp(r'^0+(?=\d)');
  static final RegExp _whitespace = RegExp(r'\s+');

  // Shown in the banner while a comic is being opened/indexed.
  String? _busyMessage;
  bool _isProcessing = false;

  List<ComicIdentity> _library = const <ComicIdentity>[];
  bool _libraryLoaded = false;
  int _libraryLoadSeq = 0;

  LibraryViewMode _viewMode = LibraryViewMode.grid;
  bool _viewModeLoaded = false;

  // Bookshelf mode: comics stand on wooden shelves instead of plain cards.
  bool _isBookshelfMode = false;
  bool _bookshelfModeLoaded = false;

  // One controller per layout: each scroll view keeps its own position and the
  // painted shelves can follow it. [_libraryWidth] is cached from the latest
  // layout pass so toggling bookshelf mode can re-map the scroll offset.
  final ScrollController _gridScroll = ScrollController();
  final ScrollController _listScroll = ScrollController();
  double _libraryWidth = 0;

  // Sorting + searching. [_library] is the raw registry, [_sorted] is the
  // whole library in the chosen order and [_visible] is [_sorted] narrowed by
  // the search query. The grid and the list always render [_visible].
  LibrarySort _sort = LibrarySort.newestFirst;
  bool _sortLoaded = false;
  bool _isSearching = false;
  String _searchQuery = '';
  List<ComicIdentity> _sorted = const <ComicIdentity>[];
  List<ComicIdentity> _visible = const <ComicIdentity>[];
  final TextEditingController _searchController = TextEditingController();

  // Last-read timestamp per comic id (only comics that have progress).
  final Map<String, int> _lastReadAt = <String, int>{};
  int _readTimesSeq = 0;

  // Lower-cased titles, so each keystroke only does cheap `contains` checks.
  final Map<String, String> _lowerTitles = <String, String>{};

  // Comics being deleted in bulk: hidden immediately, even if a registry
  // reload lands before their removal has finished.
  final Set<String> _removing = <String>{};

  @override
  void initState() {
    super.initState();
    // Reload whenever a comic is added to / removed from the registry.
    ComicLibraryService.libraryChanges.addListener(_loadLibrary);
    // "Recently read" depends on the saved reading progress.
    ReadingProgressService.changes.addListener(_refreshReadTimes);
    unawaited(_loadViewMode());
    unawaited(_loadBookshelfMode());
    unawaited(_loadSort());
    unawaited(_loadLibrary());
  }

  @override
  void dispose() {
    ComicLibraryService.libraryChanges.removeListener(_loadLibrary);
    ReadingProgressService.changes.removeListener(_refreshReadTimes);
    // A scroll that is cut short by navigation never reports its end.
    ComicCoverService.instance.setScrolling(false);
    _searchController.dispose();
    _gridScroll.dispose();
    _listScroll.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Background pre-indexer
  // ---------------------------------------------------------------------------

  // Comics that appear in the library after it was first loaded this session get
  // their archive index and page dimensions stored in ComicCacheService, so a
  // later tap opens without any parsing or header probing. Comics that were
  // already in the library at launch are indexed the first time they are opened.
  // Strictly sequential and low priority: it starts only once the library is
  // idle (no comic being opened or read), after the comic's cover is ready, and
  // it works in small throttled batches (see ComicParserService.preIndex).
  bool _preIndexBaselineTaken = false;
  final Set<String> _preIndexSeen = <String>{};
  final List<ComicIdentity> _preIndexQueue = <ComicIdentity>[];
  bool _preIndexRunning = false;

  void _enqueueNewComicsForPreIndex(List<ComicIdentity> library) {
    final Set<String> ids = <String>{
      for (final ComicIdentity comic in library) comic.id,
    };
    // A comic that left the library may be imported again later: forget it.
    _preIndexSeen.retainWhere(ids.contains);

    if (!_preIndexBaselineTaken) {
      _preIndexBaselineTaken = true;
      _preIndexSeen.addAll(ids);
      return;
    }
    for (final ComicIdentity comic in library) {
      if (_preIndexSeen.add(comic.id)) _preIndexQueue.add(comic);
    }
    if (_preIndexQueue.isNotEmpty) unawaited(_runPreIndexer());
  }

  bool _isStillInLibrary(String id) =>
      !_removing.contains(id) &&
      _library.any((ComicIdentity comic) => comic.id == id);

  /// Holds background work back while a comic is being opened or read
  /// ([_isProcessing] stays true for the whole reader session).
  Future<void> _waitUntilLibraryIdle() async {
    while (mounted && _isProcessing) {
      await Future<void>.delayed(const Duration(seconds: 1));
    }
  }

  Future<void> _runPreIndexer() async {
    if (_preIndexRunning) return;
    _preIndexRunning = true;
    try {
      // Let the new cards' cover requests get going first.
      await Future<void>.delayed(const Duration(seconds: 2));
      while (mounted && _preIndexQueue.isNotEmpty) {
        await _waitUntilLibraryIdle();
        if (!mounted || _preIndexQueue.isEmpty) break;

        final ComicIdentity comic = _preIndexQueue.removeAt(0);
        if (!_isStillInLibrary(comic.id)) continue;
        await _preIndexOne(comic);
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    } finally {
      _preIndexRunning = false;
    }
  }

  Future<void> _preIndexOne(ComicIdentity comic) async {
    // 1. Cover thumbnail first (a no-op when it already exists).
    final ComicCoverService covers = ComicCoverService.instance;
    try {
      await covers.request(comic);
    } catch (e) {
      debugPrint('PanelShift: pre-index cover failed for ${comic.title}: $e');
    } finally {
      covers.release(comic.id);
    }
    if (!mounted) return;

    // 2. Then the archive index and page dimensions.
    await _waitUntilLibraryIdle();
    if (!mounted || !_isStillInLibrary(comic.id)) return;
    try {
      if (await File(comic.sourcePath).exists()) {
        await ComicParserService.preIndex(
          comic.sourcePath,
          gate: _waitUntilLibraryIdle,
        );
      }
    } catch (e) {
      debugPrint('PanelShift: pre-index failed for ${comic.title}: $e');
    }

    // Deleted while it was being indexed: do not leave its index behind.
    if (mounted && !_isStillInLibrary(comic.id)) {
      await ComicCacheService.instance.deleteIndexCache(comic.id);
    }
  }

  // ---------------------------------------------------------------------------
  // State loading
  // ---------------------------------------------------------------------------

  Future<void> _loadLibrary() async {
    final int seq = ++_libraryLoadSeq;
    final List<ComicIdentity> library = await ComicLibraryService.loadLibrary();
    // Ignore stale results if a newer load was started meanwhile.
    if (!mounted || seq != _libraryLoadSeq) return;
    setState(() {
      _library = library;
      _libraryLoaded = true;
      _lowerTitles
        ..clear()
        ..addEntries(
          library.map(
            (ComicIdentity c) => MapEntry<String, String>(
              c.id,
              c.title.toLowerCase(),
            ),
          ),
        );
      _resort();
    });
    unawaited(_refreshReadTimes());
    _enqueueNewComicsForPreIndex(library);
  }

  Future<void> _loadViewMode() async {
    LibraryViewMode mode = LibraryViewMode.grid;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      if (prefs.getString(_viewModeKey) == LibraryViewMode.list.name) {
        mode = LibraryViewMode.list;
      }
    } catch (e) {
      debugPrint('PanelShift: could not load view mode: $e');
    }
    if (!mounted) return;
    setState(() {
      _viewMode = mode;
      _viewModeLoaded = true;
    });
  }

  Future<void> _saveViewMode(LibraryViewMode mode) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(_viewModeKey, mode.name);
    } catch (e) {
      debugPrint('PanelShift: could not save view mode: $e');
    }
  }

  void _toggleViewMode() {
    final LibraryViewMode next = _viewMode == LibraryViewMode.grid
        ? LibraryViewMode.list
        : LibraryViewMode.grid;
    setState(() => _viewMode = next);
    unawaited(_saveViewMode(next));
  }

  Future<void> _loadBookshelfMode() async {
    bool enabled = false;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      enabled = prefs.getBool(_bookshelfModeKey) ?? false;
    } catch (e) {
      debugPrint('PanelShift: could not load bookshelf mode: $e');
    }
    if (!mounted) return;
    setState(() {
      _isBookshelfMode = enabled;
      _bookshelfModeLoaded = true;
    });
  }

  Future<void> _saveBookshelfMode(bool enabled) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_bookshelfModeKey, enabled);
    } catch (e) {
      debugPrint('PanelShift: could not save bookshelf mode: $e');
    }
  }

  void _toggleBookshelfMode() {
    final bool next = !_isBookshelfMode;
    // Re-map the scroll offset *before* the rebuild so the same comics stay on
    // screen even though the rows change height (no jump, no reset).
    _remapScrollOffset(toBookshelf: next);
    setState(() => _isBookshelfMode = next);
    unawaited(_saveBookshelfMode(next));
  }

  // ---------------------------------------------------------------------------
  // Sorting
  // ---------------------------------------------------------------------------

  Future<void> _loadSort() async {
    LibrarySort sort = LibrarySort.newestFirst;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? stored = prefs.getString(_sortKey);
      for (final LibrarySort candidate in LibrarySort.values) {
        if (candidate.name == stored) {
          sort = candidate;
          break;
        }
      }
    } catch (e) {
      debugPrint('PanelShift: could not load sort order: $e');
    }
    if (!mounted) return;
    setState(() {
      _sort = sort;
      _sortLoaded = true;
      _resort();
    });
  }

  Future<void> _saveSort(LibrarySort sort) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(_sortKey, sort.name);
    } catch (e) {
      debugPrint('PanelShift: could not save sort order: $e');
    }
  }

  void _setSort(LibrarySort sort) {
    if (sort == _sort) return;
    setState(() {
      _sort = sort;
      _resort();
    });
    _jumpToTop();
    unawaited(_saveSort(sort));
  }

  /// Rebuilds [_sorted] (the whole library in the chosen order, minus comics
  /// that are being deleted) and re-applies the search filter. Call inside
  /// `setState`.
  void _resort() {
    final List<ComicIdentity> items = <ComicIdentity>[
      for (final ComicIdentity comic in _library)
        if (!_removing.contains(comic.id)) comic,
    ];

    // Import recency: a higher rank means imported more recently.
    final int last = _library.length - 1;
    final Map<String, int> rank = <String, int>{
      for (int i = 0; i < _library.length; i++)
        _library[i].id: _registryIsOldestFirst ? i : last - i,
    };
    int byNewest(ComicIdentity a, ComicIdentity b) =>
        (rank[b.id] ?? 0).compareTo(rank[a.id] ?? 0);

    switch (_sort) {
      case LibrarySort.newestFirst:
        items.sort(byNewest);
      case LibrarySort.oldestFirst:
        items.sort((ComicIdentity a, ComicIdentity b) => byNewest(b, a));
      case LibrarySort.recentlyRead:
        // Read comics first (latest first), then the never-opened ones by
        // import recency.
        items.sort((ComicIdentity a, ComicIdentity b) {
          final int? ta = _lastReadAt[a.id];
          final int? tb = _lastReadAt[b.id];
          if (ta != null && tb != null) {
            final int c = tb.compareTo(ta);
            return c != 0 ? c : byNewest(a, b);
          }
          if (ta != null) return -1;
          if (tb != null) return 1;
          return byNewest(a, b);
        });
      case LibrarySort.titleAZ:
        {
          // "Issue 2" sorts before "Issue 10"; keys are built once per sort.
          final Map<String, List<String>> keys = <String, List<String>>{
            for (final ComicIdentity c in items)
              c.id: _numberChunks
                  .allMatches(c.title.trim().toLowerCase())
                  .map((RegExpMatch m) => m[0]!)
                  .toList(growable: false),
          };
          items.sort((ComicIdentity a, ComicIdentity b) {
            final int c = _compareChunks(keys[a.id]!, keys[b.id]!);
            return c != 0 ? c : byNewest(a, b);
          });
        }
    }

    _sorted = items;
    _refilter();
  }

  static int _compareChunks(List<String> a, List<String> b) {
    final int shared = math.min(a.length, b.length);
    for (int i = 0; i < shared; i++) {
      final String x = a[i];
      final String y = b[i];
      final bool xIsNumber = _isDigit(x.codeUnitAt(0));
      final bool yIsNumber = _isDigit(y.codeUnitAt(0));

      final int c;
      if (xIsNumber && yIsNumber) {
        final String nx = x.replaceFirst(_leadingZeros, '');
        final String ny = y.replaceFirst(_leadingZeros, '');
        c = nx.length != ny.length
            ? nx.length.compareTo(ny.length)
            : nx.compareTo(ny);
      } else if (xIsNumber != yIsNumber) {
        c = xIsNumber ? -1 : 1; // numbers before letters
      } else {
        c = x.compareTo(y);
      }
      if (c != 0) return c;
    }
    return a.length.compareTo(b.length);
  }

  static bool _isDigit(int codeUnit) => codeUnit >= 48 && codeUnit <= 57;

  static int _timestampOf(ReadingProgress progress) {
    final Object? raw = progress.updatedAt;
    if (raw is DateTime) return raw.millisecondsSinceEpoch;
    if (raw is num) return raw.toInt();
    if (raw is String) return DateTime.tryParse(raw)?.millisecondsSinceEpoch ?? 0;
    return 0;
  }

  static bool _sameTimes(Map<String, int> a, Map<String, int> b) {
    if (a.length != b.length) return false;
    for (final MapEntry<String, int> entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }

  /// Reloads the last-read time of every comic. Only re-sorts when the sort
  /// order actually depends on it and something changed.
  Future<void> _refreshReadTimes() async {
    final int seq = ++_readTimesSeq;
    final List<ComicIdentity> snapshot = _library;
    final Map<String, int> times = <String, int>{};

    for (final ComicIdentity comic in snapshot) {
      try {
        final ReadingProgress? progress = await ReadingProgressService.load(
          comic.id,
        );
        if (progress != null) times[comic.id] = _timestampOf(progress);
      } catch (e) {
        debugPrint('PanelShift: could not read progress of ${comic.id}: $e');
      }
      if (!mounted || seq != _readTimesSeq) return;
    }

    if (_sameTimes(_lastReadAt, times)) return;
    setState(() {
      _lastReadAt
        ..clear()
        ..addAll(times);
      if (_sort == LibrarySort.recentlyRead) _resort();
    });
  }

  void _jumpToTop() {
    for (final ScrollController controller in <ScrollController>[
      _gridScroll,
      _listScroll,
    ]) {
      if (controller.hasClients) controller.jumpTo(0);
    }
  }

  // ---------------------------------------------------------------------------
  // Search
  // ---------------------------------------------------------------------------

  /// Narrows [_sorted] to the comics whose title contains every word of the
  /// query (any order, case-insensitive). Call inside `setState`.
  void _refilter() {
    final String query = _searchQuery.trim().toLowerCase();
    if (query.isEmpty) {
      _visible = _sorted;
      return;
    }
    final List<String> terms = query.split(_whitespace);
    _visible = <ComicIdentity>[
      for (final ComicIdentity comic in _sorted)
        if (_matchesAll(
          _lowerTitles[comic.id] ?? comic.title.toLowerCase(),
          terms,
        ))
          comic,
    ];
  }

  static bool _matchesAll(String title, List<String> terms) {
    for (final String term in terms) {
      if (!title.contains(term)) return false;
    }
    return true;
  }

  void _toggleSearch() {
    if (_isSearching) {
      _closeSearch();
    } else {
      setState(() => _isSearching = true);
    }
  }

  void _closeSearch() {
    _searchController.clear();
    setState(() {
      _isSearching = false;
      _searchQuery = '';
      _refilter();
    });
    _jumpToTop();
  }

  void _onSearchChanged(String query) {
    setState(() {
      _searchQuery = query;
      _refilter();
    });
    _jumpToTop();
  }

  void _clearSearchText() {
    _searchController.clear();
    _onSearchChanged('');
  }

  _LibraryLayout _layoutFor(LibraryViewMode mode, bool bookshelf) {
    return mode == LibraryViewMode.grid
        ? _LibraryLayout.grid(_libraryWidth, bookshelf: bookshelf)
        : _LibraryLayout.list(bookshelf: bookshelf);
  }

  /// Keeps the same "row position" when the row height changes between
  /// normal and bookshelf layouts.
  void _remapScrollOffset({required bool toBookshelf}) {
    final ScrollController controller = _viewMode == LibraryViewMode.grid
        ? _gridScroll
        : _listScroll;
    if (_libraryWidth <= 0 || controller.positions.isEmpty) return;

    final ScrollPosition position = controller.positions.last;
    if (!position.hasPixels || !position.hasViewportDimension) return;

    final _LibraryLayout before = _layoutFor(_viewMode, _isBookshelfMode);
    final _LibraryLayout after = _layoutFor(_viewMode, toBookshelf);
    if (before.rowStride <= 0 || after.rowStride <= 0) return;

    final double rowPosition =
        (position.pixels - before.topInset) / before.rowStride;
    final double target = after.topInset + rowPosition * after.rowStride;
    final double maxExtent = math.max(
      0.0,
      after.contentExtent(_visible.length) - position.viewportDimension,
    );
    position.jumpTo(target.clamp(0.0, maxExtent).toDouble());

    // Safety net: once the new layout is measured, never stay past its end.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!position.hasPixels || !position.hasContentDimensions) return;
      if (position.pixels > position.maxScrollExtent) {
        position.jumpTo(position.maxScrollExtent);
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Opening comics
  // ---------------------------------------------------------------------------

  void _notify(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
      );
  }

  /// Shared "busy" wrapper for every way of opening a comic.
  Future<void> _runProcessing(
    String startMessage,
    Future<void> Function() body,
  ) async {
    if (_isProcessing) return;

    setState(() {
      _isProcessing = true;
      _busyMessage = startMessage;
    });

    try {
      await body();
    } catch (e) {
      _notify('Error unpacking archive: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isProcessing = false;
          _busyMessage = null;
        });
      }
    }
  }

  Future<Directory> _managedLibraryDir() async {
    final Directory supportDir = await getApplicationSupportDirectory();
    return Directory(
      '${supportDir.path}${Platform.pathSeparator}imported_comics',
    );
  }

  /// Copies a picked archive into persistent app storage so Android's cache
  /// cleaner cannot delete it from `cache/file_picker/`.
  Future<String> _persistPickedFile(String pickedPath) async {
    final Directory libraryDir = await _managedLibraryDir();
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

  /// Deletes PanelShift's internal copy (and any leftover picker cache file).
  /// When [deleteExternal] is true, also attempts to delete external user
  /// files outside app storage if permitted by the OS.
  Future<_FileDeleteOutcome> _deleteComicFile(
      String sourcePath, {
        required bool deleteExternal,
      }) async {
    final Directory libraryDir = await _managedLibraryDir();
    final Directory tempDir = await getTemporaryDirectory();
    final String sep = Platform.pathSeparator;

    final String managedPrefix = '${libraryDir.path}$sep';
    final String pickerCachePrefix = '${tempDir.path}${sep}file_picker$sep';

    final bool isAppOwned =
        sourcePath.startsWith(managedPrefix) ||
            sourcePath.startsWith(pickerCachePrefix);

    if (!isAppOwned && !deleteExternal) {
      return _FileDeleteOutcome.skippedExternal;
    }

    final File file = File(sourcePath);
    if (!await file.exists()) {
      return _FileDeleteOutcome.deleted;
    }

    try {
      await file.delete();
    } on FileSystemException catch (e) {
      debugPrint('PanelShift: could not delete file "$sourcePath": $e');
      if (!isAppOwned) {
        return _FileDeleteOutcome.protectedOrLocked;
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

    return _FileDeleteOutcome.deleted;
  }

  Future _loadOriginalSources() async {
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

  Future<void> _saveOriginalSource(String comicId, String locator) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final Map<String, String> map = await _loadOriginalSources();
      map[comicId] = locator;
      await prefs.setString(_originalSourcesKey, jsonEncode(map));
    } catch (e) {
      debugPrint('PanelShift: could not save original source locator: $e');
    }
  }

  Future<String?> _takeOriginalSource(String comicId) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final Map<String, String> map = await _loadOriginalSources();
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

  Future<_FileDeleteOutcome> _deleteOriginalLocator(String locator) async {
    if (locator.startsWith('content://')) {
      try {
        final bool? deleted = await _safChannel.invokeMethod<bool>(
          'deleteUri',
          <String, Object?>{'uri': locator},
        );
        return deleted == true
            ? _FileDeleteOutcome.deleted
            : _FileDeleteOutcome.protectedOrLocked;
      } catch (e) {
        debugPrint('PanelShift: SAF URI delete failed for "$locator": $e');
        return _FileDeleteOutcome.protectedOrLocked;
      }
    }

    final File originalFile = File(locator);
    if (!await originalFile.exists()) {
      return _FileDeleteOutcome.deleted;
    }
    try {
      await originalFile.delete();
      return _FileDeleteOutcome.deleted;
    } on FileSystemException catch (e) {
      debugPrint('PanelShift: original file delete failed for "$locator": $e');
      return _FileDeleteOutcome.protectedOrLocked;
    }
  }

  static const Set<String> _supportedExtensions = <String>{
    'cbz',
    'zip',
    'cbr',
    'rar',
  };

  Future<void> _pickAndProcessComic() {
    return _runProcessing('Opening file manager...', () async {
      String? pickedTempPath;
      String? originalLocator;

      if (Platform.isAndroid) {
        final Map<String, dynamic>? picked =
        await _safChannel.invokeMapMethod<String, dynamic>('pickComic');
        if (picked == null || picked['tempPath'] == null) {
          _notify('File selection cancelled.');
          return;
        }
        pickedTempPath = picked['tempPath'] as String;
        originalLocator = picked['uri'] as String?;

        final String ext = pickedTempPath.split('.').last.toLowerCase();
        if (!_supportedExtensions.contains(ext)) {
          try {
            await File(pickedTempPath).delete();
          } catch (_) {}
          _notify('Please select a .cbz, .zip, .cbr, or .rar file.');
          return;
        }
      } else {
        final files = await FilePicker.pickFiles(
          type: FileType.custom,
          allowedExtensions: ['cbz', 'zip', 'cbr', 'rar'],
        );

        if (files.isEmpty || files.first.path == null) {
          _notify('File selection cancelled.');
          return;
        }
        pickedTempPath = files.first.path!;
        // On desktop, FilePicker returns the real original directory path.
        originalLocator = pickedTempPath;
      }

      if (!await File(pickedTempPath).exists()) {
        _notify('Selected file could not be found on disk.');
        return;
      }

      if (mounted) {
        setState(() => _busyMessage = 'Importing comic into library...');
      }
      final String persistentPath = await _persistPickedFile(pickedTempPath);
      await _extractAndOpen(persistentPath, originalLocator: originalLocator);
    });
  }

  Future<void> _openLibraryComic(ComicIdentity comic) {
    return _runProcessing('Opening ${comic.title}...', () async {
      if (!await File(comic.sourcePath).exists()) {
        _notify('"${comic.title}" is no longer at its original location.');
        return;
      }
      await _extractAndOpen(comic.sourcePath);
    });
  }

  /// Indexes [filePath], registers it in the library, opens the reader (which
  /// restores the saved position by itself) and releases the extraction once
  /// the reader is closed.
  Future<void> _extractAndOpen(
      String filePath, {
        String? originalLocator,
      }) async {
    if (mounted) {
      setState(() => _busyMessage = 'Indexing comic archive...');
    }

    final LoadedComic loaded = await ComicParserService.loadComic(
      filePath,
      retainCbrCache: true,
    );

    try {
      if (loaded.source.pageCount <= 0) {
        _notify('No valid image pages found in archive.');
        return;
      }

      // 1. Build the cover while the source is guaranteed to be open. It is a
      //    no-op (disk/memory hit) for comics that already have one.
      await ComicCoverService.instance.adopt(loaded);

      // 2. Register in the library (idempotent: dedupes by comic id, refreshes
      //    the stored path if the same comic was re-picked from elsewhere).
      await ComicLibraryService.addComic(loaded.identity);

      if (originalLocator != null && originalLocator.isNotEmpty) {
        await _saveOriginalSource(loaded.identity.id, originalLocator);
      }

      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => ComicReaderScreen(
            source: loaded.source,
            comic: loaded.identity,
            title: loaded.identity.title,
          ),
        ),
      );
    } finally {
      await loaded.close();
    }
  }

  Future<void> _confirmRemove(ComicIdentity comic) async {
    if (_isProcessing) return;

    final bool? confirmed = await showDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      title: const Text('Remove from library?'),
      content: Text(
        '"${comic.title}" and PanelShift\'s internal copy will be removed. '
            'Any original file in your external folders is not deleted, and '
            'your reading position is kept.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Remove'),
        ),
      ],
    ),
    );
    if (confirmed != true) return;

    _preIndexQueue.removeWhere((ComicIdentity c) => c.id == comic.id);
    await ComicLibraryService.removeComic(comic.id);
    await ComicCoverService.instance.delete(comic.id);
    await ComicCacheService.instance.deleteIndexCache(comic.id);
    await _deleteComicFile(comic.sourcePath, deleteExternal: false);
  }

  // ---------------------------------------------------------------------------
  // Delete all read
  // ---------------------------------------------------------------------------

  /// Comics that show the "Finished" badge: their saved position is on the
  /// last page. Comics that were never opened (no saved progress) are skipped.
  Future<List<ComicIdentity>> _findFinishedComics() async {
    final ComicCoverService covers = ComicCoverService.instance;
    final List<ComicIdentity> finished = <ComicIdentity>[];

    for (final ComicIdentity comic in List<ComicIdentity>.of(_library)) {
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

  Future<void> _confirmDeleteAllRead() async {
    if (_isProcessing || _library.isEmpty) return;

    setState(() {
      _isProcessing = true;
      _busyMessage = 'Checking for finished comics...';
    });

    List<ComicIdentity> finished = const <ComicIdentity>[];
    bool scanFailed = false;
    try {
      finished = await _findFinishedComics();
    } catch (e) {
      scanFailed = true;
      debugPrint('PanelShift: finished-comic scan failed: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isProcessing = false;
          _busyMessage = null;
        });
      }
    }

    if (!mounted) return;
    if (scanFailed) {
      _notify('Could not check your reading progress. Please try again.');
      return;
    }
    if (finished.isEmpty) {
      _notify('No finished comics to delete.');
      return;
    }

    final int count = finished.length;
    final List<String> preview = finished
        .take(5)
        .map((ComicIdentity c) => c.title)
        .toList(growable: false);

    bool deleteExternalFiles = false;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) {
        final ColorScheme scheme = Theme.of(dialogContext).colorScheme;
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setDialogState) {
            return AlertDialog(
              icon: Icon(Icons.delete_sweep_outlined, color: scheme.error),
              title: Text(
                count == 1 ? 'Delete 1 read comic?' : 'Delete $count read comics?',
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      deleteExternalFiles
                          ? 'Finished comics, PanelShift\'s internal data, AND '
                          'original external comic files (where permitted by '
                          'your OS) will be permanently deleted. This cannot '
                          'be undone.'
                          : 'Finished comics will be completely wiped from '
                          'PanelShift (library entry, internal copy, reading '
                          'progress, covers, and cached data). Original '
                          'external files in folders like Downloads will not '
                          'be touched.',
                    ),
                    const SizedBox(height: 12),
                    for (final String title in preview)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Text(
                          '• $title',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    if (count > preview.length)
                      Text('...and ${count - preview.length} more'),
                    const SizedBox(height: 8),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      dense: true,
                      value: deleteExternalFiles,
                      title: const Text(
                        'Also delete original external files (when permitted)',
                      ),
                      onChanged: (bool? checked) {
                        setDialogState(() {
                          deleteExternalFiles = checked ?? false;
                        });
                      },
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: scheme.error,
                    foregroundColor: scheme.onError,
                  ),
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: const Text('Delete'),
                ),
              ],
            );
          },
        );
      },
    );
    if (confirmed != true || !mounted) return;

    await _deleteComics(finished, deleteExternalFiles: deleteExternalFiles);
  }

  /// Removes every comic in [comics] from the registry, the cover store, the
  /// reading-progress store, and PanelShift's internal file storage, then
  /// sweeps the extraction cache.
  Future<void> _deleteComics(
      List<ComicIdentity> comics, {
        required bool deleteExternalFiles,
      }) async {
    setState(() {
      _isProcessing = true;
      _busyMessage = comics.length == 1
          ? 'Deleting 1 read comic...'
          : 'Deleting ${comics.length} read comics...';
      _removing.addAll(comics.map((ComicIdentity c) => c.id));
      _resort();
    });

    int failed = 0;
    int protectedFiles = 0;
    try {
      // Sequential on purpose: registry removals are read-modify-write.
      for (final ComicIdentity comic in comics) {
        final ({bool ok, bool externalProtected}) result = await _purgeComic(
          comic,
          deleteExternalFiles: deleteExternalFiles,
        );
        if (!result.ok) failed++;
        if (result.externalProtected) protectedFiles++;
      }

      // The registry no longer lists these comics, so any retained CBR
      // extraction folders in cache are now orphaned and get swept.
      try {
        await ComicCacheService.instance.purgeOrphans();
      } catch (e) {
        debugPrint('PanelShift: cache cleanup failed: $e');
      }
    } finally {
      // Reload while the deleted ids are still hidden, then release them:
      // anything that failed to delete comes back, everything else is gone.
      try {
        await _loadLibrary();
      } catch (e) {
        debugPrint('PanelShift: library reload failed: $e');
      }
      if (mounted) {
        setState(() {
          _removing.clear();
          _resort();
          _isProcessing = false;
          _busyMessage = null;
        });
      }
    }

    final int deleted = comics.length - failed;
    if (failed > 0) {
      _notify('Deleted $deleted, but $failed could not be fully removed.');
    } else if (protectedFiles > 0) {
      _notify(
        'Deleted $deleted read comic(s) ($protectedFiles external file(s) '
            'protected by OS).',
      );
    } else {
      _notify(
        deleted == 1 ? 'Deleted 1 read comic.' : 'Deleted $deleted read comics.',
      );
    }
  }

  /// Wipes registry entry, cover, reading progress, cached archive index,
  /// retained CBR extraction, and the comic file for one entry.
  Future<({bool ok, bool externalProtected})> _purgeComic(
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

    _preIndexQueue.removeWhere((ComicIdentity c) => c.id == id);
    if (!await step(() => ComicLibraryService.removeComic(id))) {
      return (ok: false, externalProtected: false);
    }
    await step(() => ComicCoverService.instance.delete(id));
    await step(() => ReadingProgressService.clear(id));
    await step(() => ComicCacheService.instance.deleteIndexCache(id));
    await step(() async {
      await _deleteComicFile(comic.sourcePath, deleteExternal: false);
      final String? originalLocator = await _takeOriginalSource(id);
      if (deleteExternalFiles && originalLocator != null) {
        final _FileDeleteOutcome outcome = await _deleteOriginalLocator(
          originalLocator,
        );
        if (outcome == _FileDeleteOutcome.protectedOrLocked) {
          externalProtected = true;
        }
      }
    });
    return (ok: ok, externalProtected: externalProtected);
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    // Back closes the search bar first instead of leaving the app.
    return PopScope(
      canPop: !_isSearching,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (!didPop && _isSearching) _closeSearch();
      },
      child: _buildScaffold(context),
    );
  }

  Widget _buildScaffold(BuildContext context) {
    final bool isGrid = _viewMode == LibraryViewMode.grid;
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.title),
        actions: [
          IconButton(
            tooltip: _isSearching ? 'Close search' : 'Search library',
            icon: Icon(_isSearching ? Icons.search_off : Icons.search),
            onPressed: _toggleSearch,
          ),
          PopupMenuButton<LibrarySort>(
            tooltip: 'Sort library',
            icon: const Icon(Icons.sort),
            enabled: _sortLoaded,
            onSelected: _setSort,
            itemBuilder: (BuildContext context) => <PopupMenuEntry<LibrarySort>>[
              for (final LibrarySort sort in LibrarySort.values)
                CheckedPopupMenuItem<LibrarySort>(
                  value: sort,
                  checked: sort == _sort,
                  child: Text(sort.label),
                ),
            ],
          ),
          IconButton(
            tooltip: isGrid ? 'Switch to list view' : 'Switch to grid view',
            icon: Icon(isGrid ? Icons.view_list : Icons.grid_view),
            onPressed: _viewModeLoaded ? _toggleViewMode : null,
          ),
          IconButton(
            tooltip: _isBookshelfMode
                ? 'Turn bookshelf mode off'
                : 'Turn bookshelf mode on',
            isSelected: _isBookshelfMode,
            icon: const Icon(Icons.shelves),
            style: IconButton.styleFrom(
              backgroundColor: _isBookshelfMode ? scheme.surface : null,
              foregroundColor: _isBookshelfMode ? scheme.primary : null,
            ),
            onPressed: _bookshelfModeLoaded ? _toggleBookshelfMode : null,
          ),
          PopupMenuButton<_LibraryMenuAction>(
            tooltip: 'More options',
            onSelected: (_LibraryMenuAction action) {
              switch (action) {
                case _LibraryMenuAction.deleteRead:
                  unawaited(_confirmDeleteAllRead());
              }
            },
            itemBuilder: (BuildContext context) =>
                <PopupMenuEntry<_LibraryMenuAction>>[
                  PopupMenuItem<_LibraryMenuAction>(
                    value: _LibraryMenuAction.deleteRead,
                    enabled: !_isProcessing && _library.isNotEmpty,
                    child: const Row(
                      children: [
                        Icon(Icons.delete_sweep_outlined),
                        SizedBox(width: 12),
                        Text('Delete all read'),
                      ],
                    ),
                  ),
                ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _isProcessing ? null : _pickAndProcessComic,
        icon: const Icon(Icons.folder_open),
        label: const Text('Import comic'),
      ),
      body: Column(
        children: [
          if (_isProcessing) _buildBusyBanner(),
          _buildSearchBar(),
          Expanded(child: _buildLibrary()),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: _isSearching
          ? Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: TextField(
                controller: _searchController,
                autofocus: true,
                textInputAction: TextInputAction.search,
                onChanged: _onSearchChanged,
                onSubmitted: (_) => FocusScope.of(context).unfocus(),
                decoration: InputDecoration(
                  hintText: 'Search comics by title',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _searchQuery.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear',
                          icon: const Icon(Icons.clear),
                          onPressed: _clearSearchText,
                        ),
                  filled: true,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(28),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            )
          : const SizedBox(width: double.infinity, height: 0),
    );
  }

  Widget _buildBusyBanner() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const LinearProgressIndicator(minHeight: 3),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text(
            _busyMessage ?? 'Working...',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }

  Widget _buildLibrary() {
    if (!_libraryLoaded ||
        !_viewModeLoaded ||
        !_bookshelfModeLoaded ||
        !_sortLoaded) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_sorted.isEmpty) {
      return const _EmptyLibrary();
    }
    if (_visible.isEmpty) {
      return _NoSearchResults(query: _searchQuery.trim());
    }

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      child: _viewMode == LibraryViewMode.grid ? _buildGrid() : _buildList(),
    );
  }

  /// Parks cover generation while the library scrolls (see
  /// [ComicCoverService.setScrolling]) so archive extraction never competes
  /// with the UI/raster threads during a fling.
  bool _onLibraryScroll(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification is ScrollStartNotification) {
      ComicCoverService.instance.setScrolling(true);
    } else if (notification is ScrollEndNotification) {
      ComicCoverService.instance.setScrolling(false);
    }
    return false;
  }

  /// Wraps a scroll view with the painted bookshelf (when enabled). The
  /// backdrop slot is always present in the tree so toggling the mode never
  /// rebuilds the scroll view's state or resets its position.
  ///
  /// Layer plan (each arrow is a separate compositor layer):
  ///   wall (static)  ->  planks (repaints per scroll tick)  ->  scroll view
  /// The scroll view gets its own RepaintBoundary: it repaints on every scroll
  /// tick, and without a boundary that repaint would dirty the route layer the
  /// app bar, search field and banners share.
  Widget _withShelves({
    required bool bookshelf,
    required ScrollController controller,
    required _LibraryLayout layout,
    required int rowCount,
    required Widget scrollView,
  }) {
    final ThemeData theme = Theme.of(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: bookshelf
              ? _ShelfBackdrop(
                  scroll: controller,
                  palette: theme.brightness == Brightness.dark
                      ? _ShelfPalette.dark
                      : _ShelfPalette.light,
                  rowCount: rowCount,
                  topInset: layout.topInset,
                  rowStride: layout.rowStride,
                  bookBottom: layout.bookBottom,
                )
              : const SizedBox.shrink(),
        ),
        RepaintBoundary(
          child: NotificationListener<ScrollNotification>(
            onNotification: _onLibraryScroll,
            child: scrollView,
          ),
        ),
      ],
    );
  }

  Widget _buildGrid() {
    final bool shelf = _isBookshelfMode;

    return LayoutBuilder(
      key: const ValueKey<String>('library-grid-layer'),
      builder: (BuildContext context, BoxConstraints constraints) {
        _libraryWidth = constraints.maxWidth;
        final _LibraryLayout layout = _LibraryLayout.grid(
          constraints.maxWidth,
          bookshelf: shelf,
        );

        return _withShelves(
          bookshelf: shelf,
          controller: _gridScroll,
          layout: layout,
          rowCount: layout.rowCount(_visible.length),
          scrollView: GridView.builder(
            key: const PageStorageKey<String>('library-grid'),
            controller: _gridScroll,
            padding: layout.padding,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: layout.crossAxisCount,
              mainAxisSpacing: layout.mainAxisSpacing,
              crossAxisSpacing: layout.crossAxisSpacing,
              mainAxisExtent: layout.cellHeight,
            ),
            itemCount: _visible.length,
            // Tiles never keep themselves alive, so skip the per-item
            // AutomaticKeepAlive wrapper; every tile is its own repaint layer.
            addAutomaticKeepAlives: false,
            addRepaintBoundaries: true,
            itemBuilder: (BuildContext context, int index) {
              final ComicIdentity comic = _visible[index];
              return _ComicEntry(
                key: ValueKey<String>(comic.id),
                comic: comic,
                layout: _EntryLayout.grid,
                bookshelf: shelf,
                onTap: () => _openLibraryComic(comic),
                onLongPress: () => _confirmRemove(comic),
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildList() {
    final bool shelf = _isBookshelfMode;

    return LayoutBuilder(
      key: const ValueKey<String>('library-list-layer'),
      builder: (BuildContext context, BoxConstraints constraints) {
        _libraryWidth = constraints.maxWidth;
        final _LibraryLayout layout = _LibraryLayout.list(bookshelf: shelf);

        return _withShelves(
          bookshelf: shelf,
          controller: _listScroll,
          layout: layout,
          rowCount: _visible.length,
          scrollView: ListView.builder(
            key: const PageStorageKey<String>('library-list'),
            controller: _listScroll,
            padding: layout.padding,
            itemExtent: layout.cellHeight,
            itemCount: _visible.length,
            addAutomaticKeepAlives: false,
            addRepaintBoundaries: true,
            itemBuilder: (BuildContext context, int index) {
              final ComicIdentity comic = _visible[index];
              return _ComicEntry(
                key: ValueKey<String>(comic.id),
                comic: comic,
                layout: _EntryLayout.list,
                bookshelf: shelf,
                onTap: () => _openLibraryComic(comic),
                onLongPress: () => _confirmRemove(comic),
              );
            },
          ),
        );
      },
    );
  }
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.collections_bookmark_outlined,
              size: 80,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 24),
            Text('Your library is empty', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Tap "Import comic" to add a .cbz or .cbr file.\n'
              'Imported comics show up here with your reading progress.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoSearchResults extends StatelessWidget {
  const _NoSearchResults({required this.query});

  final String query;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.search_off,
              size: 64,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text('No matching comics', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              query.isEmpty
                  ? 'Nothing to show.'
                  : 'No comic title contains "$query".',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// ==========================================
/// 2. Library card (shared by grid and list)
/// ==========================================
enum _EntryLayout { grid, list }

class _ProgressSummary {
  const _ProgressSummary({
    required this.label,
    this.fraction,
    this.finished = false,
  });

  final String label;
  final double? fraction;
  final bool finished;
}

/// One library entry. Owns its own async state so only visible cards (the
/// builders are lazy) ever trigger cover generation or progress lookups:
///  * cover + page count come from [ComicCoverService] (disk-cached),
///  * the saved position comes from [ReadingProgressService.load].
class _ComicEntry extends StatefulWidget {
  const _ComicEntry({
    super.key,
    required this.comic,
    required this.layout,
    required this.onTap,
    required this.onLongPress,
    this.bookshelf = false,
  });

  final ComicIdentity comic;
  final _EntryLayout layout;
  final bool bookshelf;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  State<_ComicEntry> createState() => _ComicEntryState();
}

class _ComicEntryState extends State<_ComicEntry> {
  late final Future<ComicCover?> _coverFuture;
  late final ComicCover? _initialCover;

  ReadingProgress? _progress;
  bool _progressLoaded = false;
  bool _sourceMissing = false;

  @override
  void initState() {
    super.initState();
    final ComicCoverService covers = ComicCoverService.instance;
    _initialCover = covers.cached(widget.comic.id);
    _coverFuture = covers.request(widget.comic);

    // Refresh whenever any reader saves progress (e.g. after closing a comic).
    ReadingProgressService.changes.addListener(_loadProgress);
    unawaited(_loadProgress());
    unawaited(_checkSource());
  }

  @override
  void didUpdateWidget(covariant _ComicEntry oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Same id, new location (the comic was re-imported from another path).
    if (oldWidget.comic.sourcePath != widget.comic.sourcePath) {
      unawaited(_checkSource());
    }
  }

  @override
  void dispose() {
    ReadingProgressService.changes.removeListener(_loadProgress);
    ComicCoverService.instance.release(widget.comic.id);
    super.dispose();
  }

  Future<void> _loadProgress() async {
    final ReadingProgress? progress = await ReadingProgressService.load(
      widget.comic.id,
    );
    if (!mounted) return;
    if (_progressLoaded && _sameProgress(_progress, progress)) return;
    setState(() {
      _progress = progress;
      _progressLoaded = true;
    });
  }

  static bool _sameProgress(ReadingProgress? a, ReadingProgress? b) {
    if (a == null || b == null) return a == b;
    return a.page == b.page &&
        a.panelIndex == b.panelIndex &&
        a.updatedAt == b.updatedAt;
  }

  Future<void> _checkSource() async {
    final bool exists = await File(widget.comic.sourcePath).exists();
    if (!mounted || _sourceMissing == !exists) return;
    setState(() => _sourceMissing = !exists);
  }

  _ProgressSummary? _summarize(int? pageCount, {required bool compact}) {
    if (!_progressLoaded) return null;

    final ReadingProgress? progress = _progress;
    if (progress == null) return const _ProgressSummary(label: 'Not started');

    final int page = math.max(progress.page, 0);
    if (pageCount == null || pageCount <= 0) {
      return _ProgressSummary(label: 'Page ${page + 1}');
    }

    final int current = math.min(page + 1, pageCount);
    final double fraction = current / pageCount;
    if (current >= pageCount) {
      return const _ProgressSummary(
        label: 'Finished',
        fraction: 1,
        finished: true,
      );
    }

    final int percent = (fraction * 100).round();
    return _ProgressSummary(
      label: compact
          ? '$current / $pageCount · $percent%'
          : 'Page $current of $pageCount · $percent%',
      fraction: fraction,
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ComicCover?>(
      future: _coverFuture,
      initialData: _initialCover,
      builder: (BuildContext context, AsyncSnapshot<ComicCover?> snapshot) {
        final ComicCover? cover = snapshot.data;
        final bool isGrid = widget.layout == _EntryLayout.grid;
        final _ProgressSummary? summary = _summarize(
          cover?.pageCount,
          compact: isGrid,
        );
        final Widget coverWidget = _buildCover(
          context,
          cover,
          loading: snapshot.connectionState != ConnectionState.done,
        );

        if (widget.bookshelf) {
          return isGrid
              ? _buildShelfGridTile(context, coverWidget, summary)
              : _buildShelfListTile(context, coverWidget, summary);
        }

        return isGrid
            ? _buildGridTile(context, coverWidget, summary)
            : _buildListTile(context, coverWidget, summary);
      },
    );
  }

  // --- cover ----------------------------------------------------------------

  /// Hard ceiling for a cover bitmap's decoded width (== the width
  /// [ComicCoverService] stores). Never exceeded, whatever the tile size.
  static const int _kCoverDecodeCeiling = 480;

  /// Decode width for one tile: its physical pixel width, clamped to
  /// [96, _kCoverDecodeCeiling]. A 3-column grid on a 1080 px phone decodes at
  /// ~360 px (0.7 MB per cover) and a list thumbnail at ~200 px, instead of
  /// 480 px (1.4 MB) everywhere - the ImageCache holds up to twice as many covers
  /// for the same RAM. With unbounded constraints the ceiling applies.
  int _coverDecodeWidth(BuildContext context, BoxConstraints constraints) {
    final double logical = constraints.maxWidth;
    if (!logical.isFinite || logical <= 0) return _kCoverDecodeCeiling;
    final double dpr = MediaQuery.devicePixelRatioOf(context);
    return (logical * dpr).ceil().clamp(96, _kCoverDecodeCeiling).toInt();
  }

  Widget _buildCover(
    BuildContext context,
    ComicCover? cover, {
    required bool loading,
  }) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    Widget placeholder(Widget child) => ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: Center(child: child),
    );

    if (cover != null) {
      return LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          return Image.file(
            File(cover.path),
            fit: BoxFit.cover,
            alignment: Alignment.topCenter,
            // Strictly bounded decode (<= 480 px wide, normally the tile's own
            // pixel width). The bitmap is already ~tile-sized, so bilinear is
            // enough: FilterQuality.medium would add a mipmap pass per cover.
            cacheWidth: _coverDecodeWidth(context, constraints),
            filterQuality: FilterQuality.low,
            gaplessPlayback: true,
            frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
              if (wasSynchronouslyLoaded) return child;
              return AnimatedOpacity(
                opacity: frame == null ? 0 : 1,
                duration: const Duration(milliseconds: 180),
                child: child,
              );
            },
            errorBuilder: (context, error, stackTrace) => placeholder(
              Icon(Icons.broken_image_outlined, color: scheme.onSurfaceVariant),
            ),
          );
        },
      );
    }

    if (loading) {
      return placeholder(
        const SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    return placeholder(
      Icon(
        _sourceMissing ? Icons.link_off : Icons.menu_book,
        size: 32,
        color: scheme.onSurfaceVariant,
      ),
    );
  }

  Widget _statusBadge(ColorScheme scheme, _ProgressSummary? summary) {
    final bool finished = summary?.finished ?? false;
    if (!finished && !_sourceMissing) return const SizedBox.shrink();

    return Positioned(
      top: 6,
      right: 6,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: _sourceMissing ? scheme.errorContainer : scheme.primary,
          shape: BoxShape.circle,
        ),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(
            _sourceMissing ? Icons.link_off : Icons.check,
            size: 14,
            color: _sourceMissing ? scheme.onErrorContainer : scheme.onPrimary,
          ),
        ),
      ),
    );
  }

  // --- bookshelf layouts ------------------------------------------------------

  Widget _shelfProgressBar(double fraction) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: LinearProgressIndicator(
        value: fraction,
        minHeight: 3,
        backgroundColor: Colors.black54,
      ),
    );
  }

  /// Grid cell in bookshelf mode: the cover stands on the shelf plank (drawn
  /// by [_BookshelfPainter] behind the grid) and a caption sits under it.
  /// The cover's bottom edge lands exactly on the plank: the cell height is
  /// `cover height + _ShelfDims.gridBelowCover`.
  Widget _buildShelfGridTile(
      BuildContext context,
      Widget cover,
      _ProgressSummary? summary,
      ) {
    final ThemeData theme = Theme.of(context);
    final double? fraction = summary?.fraction;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: _ShelfBook(
            onTap: widget.onTap,
            onLongPress: widget.onLongPress,
            child: Stack(
              fit: StackFit.expand,
              children: [
                cover,
                if (fraction != null) _shelfProgressBar(fraction),
                _statusBadge(theme.colorScheme, summary),
              ],
            ),
          ),
        ),
        // Space reserved for the visible shelf plank lip in front of the book
        const SizedBox(height: _ShelfDims.plankBelowBook),
      ],
    );
  }

  /// List row in bookshelf mode: one book per row, standing on its own plank
  /// that spans the full width of the screen.
  Widget _buildShelfListTile(
    BuildContext context,
    Widget cover,
    _ProgressSummary? summary,
  ) {
    final ThemeData theme = Theme.of(context);
    final double? fraction = summary?.fraction;

    return Padding(
      padding: const EdgeInsets.only(top: _ShelfDims.listTopGap),
      child: Align(
        alignment: Alignment.topCenter,
        child: SizedBox(
          height: _ShelfDims.listBookHeight,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: _ShelfDims.listBookWidth,
                child: _ShelfBook(
                  onTap: widget.onTap,
                  onLongPress: widget.onLongPress,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [cover, _statusBadge(theme.colorScheme, summary)],
                  ),
                ),
              ),
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: widget.onTap,
                  onLongPress: widget.onLongPress,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.comic.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _sourceMissing
                                ? 'File not found'
                                : (summary?.label ?? ' '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: _sourceMissing
                                  ? theme.colorScheme.error
                                  : theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          if (fraction != null) ...[
                            const SizedBox(height: 8),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(2),
                              child: LinearProgressIndicator(
                                value: fraction,
                                minHeight: 4,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // --- grid layout ----------------------------------------------------------

  Widget _buildGridTile(
    BuildContext context,
    Widget cover,
    _ProgressSummary? summary,
  ) {
    final ThemeData theme = Theme.of(context);
    final double? fraction = summary?.fraction;

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  cover,
                  if (fraction != null)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: LinearProgressIndicator(
                        value: fraction,
                        minHeight: 4,
                        backgroundColor: Colors.black54,
                      ),
                    ),
                  _statusBadge(theme.colorScheme, summary),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.comic.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _sourceMissing ? 'File not found' : (summary?.label ?? ' '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: _sourceMissing
                          ? theme.colorScheme.error
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --- list layout ----------------------------------------------------------

  Widget _buildListTile(
    BuildContext context,
    Widget cover,
    _ProgressSummary? summary,
  ) {
    final ThemeData theme = Theme.of(context);
    final double? fraction = summary?.fraction;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: widget.onTap,
          onLongPress: widget.onLongPress,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 68,
                child: Stack(
                  fit: StackFit.expand,
                  children: [cover, _statusBadge(theme.colorScheme, summary)],
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.comic.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _sourceMissing
                            ? 'File not found'
                            : (summary?.label ?? ' '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: _sourceMissing
                              ? theme.colorScheme.error
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      if (fraction != null) ...[
                        const SizedBox(height: 8),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: fraction,
                            minHeight: 4,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// ==========================================
/// 3. Bookshelf mode
/// ==========================================

/// Fixed measurements shared by the layout, the tiles and the painter so the
/// books always land exactly on the planks.
class _ShelfDims {
  const _ShelfDims._();

  // Plank anatomy (top surface in perspective + front face).
  static const double plankBehindBook = 7; // surface visible behind a book
  static const double plankInFrontOfBook = 5; // surface in front of a book
  static const double plankSurface = plankBehindBook + plankInFrontOfBook;
  static const double plankFace = 18;
  static const double plankHeight = plankSurface + plankFace;
  static const double plankBelowBook = plankInFrontOfBook + plankFace;
  static const double castShadow = 28; // shadow the plank throws on the wall
  static const double wallBoardWidth = 72;

  // Grid cells: cover (aspect) + plank + caption.
  static const double gridCoverAspect = 1.45; // cover height / width
  static const double gridBelowCover = plankBelowBook;

  // List rows: one book + plank per row.
  static const double listTopGap = 12;
  static const double listBookWidth = 72;
  static const double listBookHeight = 104;
  static const double listBottomGap = 9;
  static const double listBookBottom = listTopGap + listBookHeight;
  static const double listRowHeight =
      listBookBottom + plankBelowBook + listBottomGap;
}

/// Everything needed to lay out (and paint shelves for) one library layout.
/// For the list layout, [cellHeight] is the row height and there is one column.
class _LibraryLayout {
  const _LibraryLayout({
    required this.padding,
    required this.cellHeight,
    required this.bookBottom,
    this.crossAxisCount = 1,
    this.cellWidth = 0,
    this.crossAxisSpacing = 0,
    this.mainAxisSpacing = 0,
  });

  final EdgeInsets padding;
  final double cellHeight;

  /// Y position (relative to a row's top) where the books touch the shelf.
  final double bookBottom;
  final int crossAxisCount;
  final double cellWidth;
  final double crossAxisSpacing;
  final double mainAxisSpacing;

  double get topInset => padding.top;
  double get rowStride => cellHeight + mainAxisSpacing;

  int rowCount(int itemCount) =>
      itemCount <= 0 ? 0 : (itemCount + crossAxisCount - 1) ~/ crossAxisCount;

  /// Total scrollable extent, matching what the slivers compute.
  double contentExtent(int itemCount) {
    final int rows = rowCount(itemCount);
    if (rows == 0) return padding.vertical;
    return rows * cellHeight + (rows - 1) * mainAxisSpacing + padding.vertical;
  }

  /// Mirrors the previous `maxCrossAxisExtent: 190` / `childAspectRatio: 0.54`
  /// grid exactly when [bookshelf] is false.
  factory _LibraryLayout.grid(double width, {required bool bookshelf}) {
    const double maxCrossAxisExtent = 190;
    const double crossAxisSpacing = 16;
    final double mainAxisSpacing = bookshelf ? 14 : 16;
    final EdgeInsets padding = bookshelf
        ? const EdgeInsets.fromLTRB(22, 24, 22, 96)
        : const EdgeInsets.fromLTRB(16, 16, 16, 96);

    final double usable = math.max(0.0, width - padding.horizontal);
    final int count = math.max(
      1,
      (usable / (maxCrossAxisExtent + crossAxisSpacing)).ceil(),
    );
    final double cellWidth =
        math.max(0.0, usable - crossAxisSpacing * (count - 1)) / count;

    final double coverHeight = cellWidth * _ShelfDims.gridCoverAspect;
    final double cellHeight = bookshelf
        ? coverHeight + _ShelfDims.gridBelowCover
        : cellWidth / 0.54;

    return _LibraryLayout(
      padding: padding,
      cellHeight: cellHeight,
      bookBottom: bookshelf ? coverHeight : cellHeight,
      crossAxisCount: count,
      cellWidth: cellWidth,
      crossAxisSpacing: crossAxisSpacing,
      mainAxisSpacing: mainAxisSpacing,
    );
  }

  factory _LibraryLayout.list({required bool bookshelf}) {
    if (bookshelf) {
      return const _LibraryLayout(
        padding: EdgeInsets.fromLTRB(16, 8, 16, 96),
        cellHeight: _ShelfDims.listRowHeight,
        bookBottom: _ShelfDims.listBookBottom,
      );
    }
    return const _LibraryLayout(
      padding: EdgeInsets.fromLTRB(12, 8, 12, 96),
      cellHeight: 112,
      bookBottom: 112,
    );
  }
}

/// Colors for the shelf. Two fixed palettes (identity-comparable so the
/// painter can cheaply decide when to repaint).
class _ShelfPalette {
  const _ShelfPalette({
    required this.wall,
    required this.wallSeam,
    required this.wallSeamLight,
    required this.surfaceBack,
    required this.surfaceFront,
    required this.faceTop,
    required this.faceBottom,
    required this.highlight,
    required this.grainDark,
    required this.grainLight,
  });

  final Color wall;
  final Color wallSeam;
  final Color wallSeamLight;
  final Color surfaceBack;
  final Color surfaceFront;
  final Color faceTop;
  final Color faceBottom;
  final Color highlight;
  final Color grainDark;
  final Color grainLight;

  /// Dark walnut on a deep, warm back panel: sits quietly in the dark theme.
  static const _ShelfPalette dark = _ShelfPalette(
    wall: Color(0xFF17120F),
    wallSeam: Color(0x66000000),
    wallSeamLight: Color(0x0DFFFFFF),
    surfaceBack: Color(0xFF4A2F1B),
    surfaceFront: Color(0xFF6E4A2E),
    faceTop: Color(0xFF603F26),
    faceBottom: Color(0xFF36230F),
    highlight: Color(0xFF9A6E48),
    grainDark: Color(0x4D1E0F05),
    grainLight: Color(0x26FFD9A8),
  );

  /// Lighter oak for light themes.
  static const _ShelfPalette light = _ShelfPalette(
    wall: Color(0xFFD8CCBD),
    wallSeam: Color(0x33000000),
    wallSeamLight: Color(0x33FFFFFF),
    surfaceBack: Color(0xFFB58858),
    surfaceFront: Color(0xFFD2A877),
    faceTop: Color(0xFFC39563),
    faceBottom: Color(0xFF9B6D42),
    highlight: Color(0xFFEBD2AA),
    grainDark: Color(0x40502C10),
    grainLight: Color(0x40FFF0D0),
  );
}

/// The bookcase behind the scroll view, split into two retained layers so a
/// scroll tick only ever repaints the part that really moves:
///
///  1. [_ShelfWallPainter] - back panel, seams and side shading. It is fixed to
///     the viewport and independent of the scroll offset, so it is painted once
///     per size/theme and afterwards only composited.
///  2. [_BookshelfPainter] - the planks and the shadows they cast. It follows
///     the scroll controller and draws only the visible planks, reusing the
///     cached paints, shaders and grain paths of a [_PlankKit] instead of
///     rebuilding them every frame.
class _ShelfBackdrop extends StatelessWidget {
  const _ShelfBackdrop({
    required this.scroll,
    required this.palette,
    required this.rowCount,
    required this.topInset,
    required this.rowStride,
    required this.bookBottom,
  });

  final ScrollController scroll;
  final _ShelfPalette palette;
  final int rowCount;
  final double topInset;
  final double rowStride;
  final double bookBottom;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        // Layer 1: static wall. No repaint listenable, so after its first paint
        // it is never re-recorded while the library scrolls.
        RepaintBoundary(
          child: CustomPaint(
            isComplex: true,
            painter: _ShelfWallPainter(palette: palette),
          ),
        ),
        // Layer 2: only the planks move with the scroll offset.
        RepaintBoundary(
          child: CustomPaint(
            willChange: true,
            painter: _BookshelfPainter(
              scroll: scroll,
              palette: palette,
              rowCount: rowCount,
              topInset: topInset,
              rowStride: rowStride,
              bookBottom: bookBottom,
            ),
          ),
        ),
      ],
    );
  }
}

/// Back panel of the bookcase. Viewport-fixed, so it never listens to the
/// scroll controller; it repaints only when the size or the palette changes.
class _ShelfWallPainter extends CustomPainter {
  const _ShelfWallPainter({required this.palette});

  final _ShelfPalette palette;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = palette.wall);

    // Vertical back-board seams.
    final Paint seam = Paint()
      ..color = palette.wallSeam
      ..strokeWidth = 1;
    final Paint seamLight = Paint()
      ..color = palette.wallSeamLight
      ..strokeWidth = 1;
    for (
      double x = _ShelfDims.wallBoardWidth;
      x < size.width;
      x += _ShelfDims.wallBoardWidth
    ) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), seam);
      canvas.drawLine(Offset(x + 1, 0), Offset(x + 1, size.height), seamLight);
    }

    // Soft inner shading toward the left and right edges.
    const double side = 30;
    final Rect left = Rect.fromLTWH(0, 0, side, size.height);
    final Rect right = Rect.fromLTWH(size.width - side, 0, side, size.height);
    canvas.drawRect(
      left,
      Paint()
        ..shader = LinearGradient(
          colors: [Colors.black.withAlpha(110), Colors.black.withAlpha(0)],
        ).createShader(left),
    );
    canvas.drawRect(
      right,
      Paint()
        ..shader = LinearGradient(
          colors: [Colors.black.withAlpha(0), Colors.black.withAlpha(110)],
        ).createShader(right),
    );
  }

  @override
  bool shouldRepaint(covariant _ShelfWallPainter old) => old.palette != palette;
}

/// Paints a wooden plank under every visible row (plus empty shelves to fill
/// the screen when the library is short) and the shadows each plank casts. It
/// follows [scroll] directly, so it stays glued to the rows while scrolling and
/// only the visible planks are ever drawn, no matter how large the library is.
///
/// Per frame this does no allocation-heavy work: every gradient shader, stroke
/// paint and grain path lives in the shared [_PlankKit], and a plank is drawn
/// by translating the canvas to its row and replaying 12 cheap operations.
class _BookshelfPainter extends CustomPainter {
  _BookshelfPainter({
    required this.scroll,
    required this.palette,
    required this.rowCount,
    required this.topInset,
    required this.rowStride,
    required this.bookBottom,
    this.fillEmptyShelves = true,
  }) : super(repaint: scroll);

  final ScrollController scroll;
  final _ShelfPalette palette;
  final int rowCount;
  final double topInset;
  final double rowStride;
  final double bookBottom;
  final bool fillEmptyShelves;

  @override
  void paint(Canvas canvas, Size size) {
    if (rowStride <= 0 || size.isEmpty) return;

    final double offset = scroll.positions.isEmpty
        ? 0.0
        : scroll.positions.last.pixels;
    final _PlankKit kit = _PlankKit.obtain(palette, size.width);

    // Content-space Y of the first plank's top edge.
    final double firstTop = topInset + bookBottom - _ShelfDims.plankBehindBook;
    final double reach = _ShelfDims.plankHeight + _ShelfDims.castShadow;

    int first = ((offset - firstTop - reach) / rowStride).floor();
    int last = ((offset + size.height - firstTop) / rowStride).ceil();
    first = math.max(first, 0);
    if (!fillEmptyShelves) last = math.min(last, rowCount - 1);

    for (int i = first; i <= last; i++) {
      kit.paint(canvas, firstTop + i * rowStride - offset, i);
    }
  }

  @override
  bool shouldRepaint(covariant _BookshelfPainter old) {
    return old.scroll != scroll ||
        old.palette != palette ||
        old.rowCount != rowCount ||
        old.topInset != topInset ||
        old.rowStride != rowStride ||
        old.bookBottom != bookBottom ||
        old.fillEmptyShelves != fillEmptyShelves;
  }
}

/// Grain streaks of one plank surface or face (two paths = two draw calls).
class _GrainPaths {
  const _GrainPaths(this.dark, this.light);

  final Path dark;
  final Path light;
}

/// One pre-generated plank look: grain for the top surface and the front face.
class _PlankGrain {
  const _PlankGrain(this.surface, this.face);

  final _GrainPaths surface;
  final _GrainPaths face;
}

/// Everything a plank needs that does not change from frame to frame: the
/// gradient shaders (built once for a plank whose top edge sits at y = 0),
/// the stroke paints and a handful of grain variants.
///
/// A plank is drawn after `canvas.translate(0, top)`: shader coordinates follow
/// the canvas transform, so the same shaders serve every row and every frame.
/// The kit is rebuilt only when the width or the palette changes (rotation,
/// theme switch). A single shared entry is enough: the grid and the list share
/// one library width, and only one theme is active at a time.
class _PlankKit {
  _PlankKit._(this.palette, this.width) {
    const double surfaceH = _ShelfDims.plankSurface;
    const double faceH = _ShelfDims.plankFace;
    final double w = width;

    surfaceRect = Rect.fromLTWH(0, 0, w, surfaceH);
    faceRect = Rect.fromLTWH(0, surfaceH, w, faceH);
    wholeRect = Rect.fromLTWH(0, 0, w, surfaceH + faceH);
    shadowRect = Rect.fromLTWH(0, surfaceH + faceH, w, _ShelfDims.castShadow);
    occlusionRect = Rect.fromLTWH(0, 0, w, 5);
    highlightRect = Rect.fromLTWH(0, surfaceH, w, 1.5);
    edgeRect = Rect.fromLTWH(0, surfaceH + faceH - 2, w, 2);
    sheenRect = Rect.fromLTWH(0, surfaceH + 3, w, 3);

    // 1. Shadow thrown on the back panel below the plank.
    shadowPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.black.withAlpha(160),
          Colors.black.withAlpha(55),
          Colors.black.withAlpha(0),
        ],
        stops: const [0.0, 0.4, 1.0],
      ).createShader(shadowRect);

    // 2. Top surface (lighter toward the front edge).
    surfacePaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [palette.surfaceBack, palette.surfaceFront],
      ).createShader(surfaceRect);

    // Dark contact line where the surface meets the back panel.
    occlusionPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Colors.black.withAlpha(120), Colors.black.withAlpha(0)],
      ).createShader(occlusionRect);

    // 3. Front face, bevel highlight and lower edge shade.
    facePaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [palette.faceTop, palette.faceBottom],
      ).createShader(faceRect);
    highlightPaint = Paint()..color = palette.highlight;
    edgePaint = Paint()..color = Colors.black.withAlpha(130);

    // 4. Polished sheen: a soft specular streak along the front lip.
    sheenPaint = Paint()
      ..shader = LinearGradient(
        colors: [
          Colors.white.withAlpha(0),
          Colors.white.withAlpha(46),
          Colors.white.withAlpha(0),
        ],
        stops: const [0.0, 0.5, 1.0],
      ).createShader(sheenRect);

    // 5. Slight darkening toward both ends of the plank.
    endsPaint = Paint()
      ..shader = LinearGradient(
        colors: [
          Colors.black.withAlpha(90),
          Colors.black.withAlpha(0),
          Colors.black.withAlpha(0),
          Colors.black.withAlpha(90),
        ],
        stops: const [0.0, 0.05, 0.95, 1.0],
      ).createShader(wholeRect);

    grainDarkPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.9
      ..color = palette.grainDark;
    grainLightPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.7
      ..color = palette.grainLight;

    grains = List<_PlankGrain>.generate(_variantCount, (int v) {
      final math.Random rnd = math.Random(v * 7919 + 101);
      return _PlankGrain(
        _buildGrain(surfaceRect, rnd, math.max(8, (w / 26).round())),
        _buildGrain(faceRect, rnd, math.max(10, (w / 16).round())),
      );
    }, growable: false);
  }

  /// Distinct grain patterns. Rows pick one by index (stride 5 mod 8 scrambles
  /// the order), so neighbouring planks never look alike.
  static const int _variantCount = 8;

  static _PlankKit? _current;

  static _PlankKit obtain(_ShelfPalette palette, double width) {
    final _PlankKit? kit = _current;
    if (kit != null && identical(kit.palette, palette) && kit.width == width) {
      return kit;
    }
    return _current = _PlankKit._(palette, width);
  }

  final _ShelfPalette palette;
  final double width;

  late final Rect surfaceRect;
  late final Rect faceRect;
  late final Rect wholeRect;
  late final Rect shadowRect;
  late final Rect occlusionRect;
  late final Rect highlightRect;
  late final Rect edgeRect;
  late final Rect sheenRect;

  late final Paint shadowPaint;
  late final Paint surfacePaint;
  late final Paint occlusionPaint;
  late final Paint facePaint;
  late final Paint highlightPaint;
  late final Paint edgePaint;
  late final Paint sheenPaint;
  late final Paint endsPaint;
  late final Paint grainDarkPaint;
  late final Paint grainLightPaint;

  late final List<_PlankGrain> grains;

  /// Long, slightly drifting streaks in [r]'s local coordinates. Every streak
  /// is kept inside [r] (the inset covers the curve's drift plus half the
  /// stroke width), so no per-plank clipRect is needed at draw time.
  static _GrainPaths _buildGrain(Rect r, math.Random rnd, int count) {
    const double inset = 1.2;
    final double usableHeight = math.max(r.height - 2 * inset, 0.0);
    final Path dark = Path();
    final Path light = Path();
    for (int k = 0; k < count; k++) {
      final double y = r.top + inset + rnd.nextDouble() * usableHeight;
      final double length = math.min(50 + rnd.nextDouble() * r.width * 0.5, r.width);
      final double x0 = r.left + rnd.nextDouble() * math.max(r.width - length, 0.0);
      final double drift = (rnd.nextDouble() - 0.5) * 2.5;
      final Path target = k.isEven ? dark : light;
      target.moveTo(x0, y);
      target.quadraticBezierTo(x0 + length / 2, y + drift, x0 + length, y);
    }
    return _GrainPaths(dark, light);
  }

  /// Draws the plank whose top edge is at [top] (canvas coordinates). The order
  /// matches the original painter: shadow, surface + grain, contact line, face
  /// + grain, highlight, lower edge, sheen, end darkening.
  void paint(Canvas canvas, double top, int index) {
    final _PlankGrain grain = grains[(index * 5) % _variantCount];
    canvas.save();
    canvas.translate(0.0, top);
    canvas.drawRect(shadowRect, shadowPaint);
    canvas.drawRect(surfaceRect, surfacePaint);
    canvas.drawPath(grain.surface.dark, grainDarkPaint);
    canvas.drawPath(grain.surface.light, grainLightPaint);
    canvas.drawRect(occlusionRect, occlusionPaint);
    canvas.drawRect(faceRect, facePaint);
    canvas.drawPath(grain.face.dark, grainDarkPaint);
    canvas.drawPath(grain.face.light, grainLightPaint);
    canvas.drawRect(highlightRect, highlightPaint);
    canvas.drawRect(edgeRect, edgePaint);
    canvas.drawRect(sheenRect, sheenPaint);
    canvas.drawRect(wholeRect, endsPaint);
    canvas.restore();
  }
}

/// A comic standing on a shelf: slightly rounded book edges, a spine crease,
/// a faint cover sheen and soft drop shadows that fall on the plank and wall.
class _ShelfBook extends StatelessWidget {
  const _ShelfBook({
    required this.child,
    required this.onTap,
    required this.onLongPress,
  });

  final Widget child;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  static const BorderRadius _radius = BorderRadius.only(
    topLeft: Radius.circular(2),
    bottomLeft: Radius.circular(2),
    topRight: Radius.circular(4),
    bottomRight: Radius.circular(4),
  );

  static const Widget _sheen = Stack(
    fit: StackFit.expand,
    children: [
      // Top-to-bottom cover gloss.
      Positioned(
        left: 0,
        right: 0,
        top: 0,
        height: 48,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0x26FFFFFF), Color(0x00FFFFFF)],
            ),
          ),
        ),
      ),
      // Spine shading + crease.
      Positioned(
        left: 0,
        top: 0,
        bottom: 0,
        width: 9,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0x73000000), Color(0x00000000)],
            ),
          ),
        ),
      ),
      Positioned(
        left: 8,
        top: 0,
        bottom: 0,
        width: 1.5,
        child: DecoratedBox(
          decoration: BoxDecoration(color: Color(0x1FFFFFFF)),
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        borderRadius: _radius,
        boxShadow: <BoxShadow>[
          // Tight shadow cast onto the plank surface and the wall.
          BoxShadow(
            color: Color(0xA6000000),
            blurRadius: 9,
            offset: Offset(5, 3),
          ),
          // Wide, soft ambient shadow.
          BoxShadow(
            color: Color(0x59000000),
            blurRadius: 22,
            spreadRadius: 1,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: _radius,
        child: Stack(
          fit: StackFit.expand,
          children: [
            child,
            const IgnorePointer(child: _sheen),
            // Ripple sits above the cover art so it is actually visible.
            Positioned.fill(
              child: Material(
                type: MaterialType.transparency,
                child: InkWell(onTap: onTap, onLongPress: onLongPress),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Two-line caption under a shelf. Clips instead of overflowing when the
/// system font scale is large.
class _ShelfCaption extends StatelessWidget {
  const _ShelfCaption({
    required this.title,
    required this.subtitle,
    required this.subtitleColor,
  });

  final String title;
  final String subtitle;
  final Color subtitleColor;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return ClipRect(
      child: OverflowBox(
        alignment: Alignment.topLeft,
        minHeight: 0,
        maxHeight: double.infinity,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall?.copyWith(
                fontSize: 13,
                height: 1.25,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 11.5,
                height: 1.25,
                color: subtitleColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
