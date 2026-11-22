import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../screens/comic_reader_screen.dart';
import '../../services/comic_cache_service.dart';
import '../../services/comic_cover_service.dart';
import '../../services/comic_identity.dart';
import '../../services/comic_library_service.dart';
import '../../services/comic_parser_service.dart';
import '../../services/reading_progress_service.dart';
import 'bookshelf_backdrop.dart';
import 'comic_entry_card.dart';
import 'home_theme.dart';
import 'library_file_ops.dart';
import 'library_models.dart';

/// ==========================================
/// Library Dashboard (import + grid/list/stack)
/// ==========================================

enum _LibraryMenuAction { columns, theme, deleteRead }

enum _ImportChoice { file, folder }

class ComicProcessorScreen extends StatefulWidget {
  const ComicProcessorScreen({
    super.key,
    required this.title,
    this.themeController,
  });

  final String title;

  /// Owned by `PanelShiftApp`. When null (for example in a widget test) the
  /// Theme button is simply not shown.
  final AppThemeController? themeController;

  @override
  State<ComicProcessorScreen> createState() => ComicProcessorScreenState();
}

class ComicProcessorScreenState extends State<ComicProcessorScreen> {
  static const String _viewModeKey = 'panelshift.libraryViewMode.v1';
  static const String _bookshelfModeKey = 'panelshift.bookshelfMode.v1';
  static const String _sortKey = 'panelshift.librarySort.v1';
  static const String _gridColumnsKey = 'panelshift.gridColumns.v1';
  /// Order in which [ComicLibraryService.loadLibrary] returns comics: `true`
  /// when the oldest import comes first (new imports are appended), `false`
  /// when the newest import comes first. If "Newest to oldest import" shows
  /// up reversed, flip this one flag.
  static const bool _registryIsOldestFirst = true;

  static final RegExp _numberChunks = RegExp(r'\d+|\D+');
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

  // Comics per row in the grid: 0 = Auto (responsive), otherwise 2..6.
  static const List<int> _columnChoices = <int>[0, 2, 3, 4, 5, 6];
  int _gridColumns = 0;
  bool _gridColumnsLoaded = false;

  // One controller per layout: each scroll view keeps its own position and the
  // painted shelves can follow it. [_libraryWidth] is cached from the latest
  // layout pass so toggling bookshelf mode can re-map the scroll offset.
  final ScrollController _gridScroll = ScrollController();
  final ScrollController _listScroll = ScrollController();
  final ScrollController _stackScroll = ScrollController();
  final ScrollController _verticalStackScroll = ScrollController();
  double _libraryWidth = 0;

  // Sorting + searching. [_library] is the raw registry, [_sorted] is the
  // whole library in the chosen order and [_visible] is [_sorted] narrowed by
  // the search query. The grid, list and stack always render [_sections],
  // which are built from [_visible].
  LibrarySort _sort = LibrarySort.newestFirst;
  bool _sortLoaded = false;
  bool _isSearching = false;
  String _searchQuery = '';
  List<ComicIdentity> _sorted = const <ComicIdentity>[];
  List<ComicIdentity> _visible = const <ComicIdentity>[];

  // [_visible] split into shelf sections: the ungrouped comics first, then one
  // section per imported folder in import order.
  List<LibrarySection> _sections = const <LibrarySection>[];
  final TextEditingController _searchController = TextEditingController();

  // Last-read timestamp per comic id (only comics that have progress).
  final Map<String, int> _lastReadAt = <String, int>{};
  int _readTimesSeq = 0;

  // Lower-cased titles, so each keystroke only does cheap `contains` checks.
  final Map<String, String> _lowerTitles = <String, String>{};

  // Comics being deleted in bulk: hidden immediately, even if a registry
  // reload lands before their removal has finished.
  final Set<String> _removing = <String>{};

  // Multi-select: ids of the comics ticked on the dashboard. Selection mode is
  // simply "at least one id selected"; unticking the last one leaves it.
  final Set<String> _selectedIds = <String>{};
  bool get _isSelecting => _selectedIds.isNotEmpty;

  @override
  void initState() {
    super.initState();
    // Reload whenever a comic is added to / removed from the registry.
    ComicLibraryService.libraryChanges.addListener(_loadLibrary);
    // "Recently read" depends on the saved reading progress.
    ReadingProgressService.changes.addListener(_refreshReadTimes);
    unawaited(_loadViewMode());
    unawaited(_loadBookshelfMode());
    unawaited(_loadGridColumns());
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
    _stackScroll.dispose();
    _verticalStackScroll.dispose();
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
      if (await LibraryFileOps.sourceExists(comic.sourcePath)) {
        await ComicParserService.preIndex(
          comic.sourcePath,
          extractCbr: false,
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
      // Comics that left the registry can no longer be selected.
      _selectedIds.retainAll(<String>{for (final ComicIdentity c in library) c.id});
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
      final String? stored = prefs.getString(_viewModeKey);
      for (final LibraryViewMode candidate in LibraryViewMode.values) {
        if (candidate.name == stored) {
          mode = candidate;
          break;
        }
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

  /// The mode the view-mode button switches to:
  /// grid -> list -> stack -> verticalStack -> grid.
  LibraryViewMode get _nextViewMode => switch (_viewMode) {
    LibraryViewMode.grid => LibraryViewMode.list,
    LibraryViewMode.list => LibraryViewMode.stack,
    LibraryViewMode.stack => LibraryViewMode.verticalStack,
    LibraryViewMode.verticalStack => LibraryViewMode.grid,
  };

  /// The button shows the mode a tap leads to (same convention as before:
  /// grid shows the list icon, and so on).
  IconData get _viewModeIcon => switch (_nextViewMode) {
    LibraryViewMode.grid => Icons.grid_view,
    LibraryViewMode.list => Icons.view_list,
    LibraryViewMode.stack => Icons.view_agenda_outlined,
    LibraryViewMode.verticalStack => Icons.view_week_outlined,
  };

  String get _viewModeTooltip => switch (_nextViewMode) {
    LibraryViewMode.grid => 'Switch to grid view',
    LibraryViewMode.list => 'Switch to list view',
    LibraryViewMode.stack => 'Switch to stack view',
    LibraryViewMode.verticalStack => 'Switch to vertical shelf stack view',
  };

  void _toggleViewMode() {
    final LibraryViewMode next = _nextViewMode;
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
  // Comics per row
  // ---------------------------------------------------------------------------

  Future<void> _loadGridColumns() async {
    int columns = 0;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final int? stored = prefs.getInt(_gridColumnsKey);
      if (stored != null && _columnChoices.contains(stored)) columns = stored;
    } catch (e) {
      debugPrint('PanelShift: could not load grid columns: $e');
    }
    if (!mounted) return;
    setState(() {
      _gridColumns = columns;
      _gridColumnsLoaded = true;
    });
  }

  Future<void> _saveGridColumns(int columns) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_gridColumnsKey, columns);
    } catch (e) {
      debugPrint('PanelShift: could not save grid columns: $e');
    }
  }

  void _setGridColumns(int columns) {
    if (columns == _gridColumns || !_columnChoices.contains(columns)) return;
    // Re-map the scroll offset *before* the rebuild so the same comics stay
    // on screen even though the rows get taller/shorter and hold a different
    // number of comics.
    _remapScrollOffset(toBookshelf: _isBookshelfMode, toColumns: columns);
    setState(() => _gridColumns = columns);
    unawaited(_saveGridColumns(columns));
  }

  String get _columnsLabel => _gridColumns == 0 ? 'Auto' : '$_gridColumns';

  Future<void> _showColumnsDialog() async {
    // "Comics per row" only exists in the grid: list and stack have one comic
    // per row.
    if (_viewMode != LibraryViewMode.grid) return;
    if (!_gridColumnsLoaded) return;
    final int? choice = await showDialog<int>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Comics per row'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final int value in _columnChoices)
                  ChoiceChip(
                    label: Text(value == 0 ? 'Auto' : '$value'),
                    selected: value == _gridColumns,
                    onSelected: (_) => Navigator.pop(dialogContext, value),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'Auto fits as many comics as the screen width allows.',
              style: Theme.of(dialogContext).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (choice != null && mounted) _setGridColumns(choice);
  }

  // ---------------------------------------------------------------------------
  // Theme
  // ---------------------------------------------------------------------------

  Future<void> _showThemeDialog() async {
    final AppThemeController? controller = widget.themeController;
    if (controller == null) return;
    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) =>
          ThemeDialog(controller: controller),
    );
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
            final int c = compareNaturalChunks(keys[a.id]!, keys[b.id]!);
            return c != 0 ? c : byNewest(a, b);
          });
        }
    }

    _sorted = items;
    _refilter();
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
        if (progress != null) times[comic.id] = timestampOf(progress);
      } catch (e) {
        debugPrint('PanelShift: could not read progress of ${comic.id}: $e');
      }
      if (!mounted || seq != _readTimesSeq) return;
    }

    if (sameReadTimes(_lastReadAt, times)) return;
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
      _stackScroll,
      _verticalStackScroll,
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
    } else {
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
    // Sections are built from the comics that matched, so a folder without a
    // match disappears and matching comics stay under their folder header.
    _sections = _buildSections(_visible);
  }

  /// Splits [visible] (already sorted and filtered) into shelf sections.
  ///
  /// The ungrouped comics form the first section (omitted when empty); each
  /// folder follows in import order, so a newly imported folder lands under
  /// everything that was there before. [visible] keeps the active sort order,
  /// and a partition keeps relative order, so every section is sorted on its
  /// own and folders never merge.
  List<LibrarySection> _buildSections(List<ComicIdentity> visible) {
    final List<ComicIdentity> ungrouped = <ComicIdentity>[];
    final Map<String, List<ComicIdentity>> byGroup =
        <String, List<ComicIdentity>>{};
    final Map<String, String> names = <String, String>{};

    for (final ComicIdentity comic in visible) {
      final String? groupId = comic.groupId;
      if (!comic.isGrouped || groupId == null) {
        ungrouped.add(comic);
        continue;
      }
      (byGroup[groupId] ??= <ComicIdentity>[]).add(comic);
      final String? name = comic.groupName;
      if (name != null && name.trim().isNotEmpty) {
        names.putIfAbsent(groupId, () => name.trim());
      }
    }

    // Group ids are import timestamps, so numeric order is import order; ties
    // (and any non-numeric id) keep the order they first appear in.
    final List<String> groupIds = byGroup.keys.toList();
    final Map<String, int> appearance = <String, int>{
      for (int i = 0; i < groupIds.length; i++) groupIds[i]: i,
    };
    int stampOf(String id) => int.tryParse(id) ?? 0;
    groupIds.sort((String a, String b) {
      final int c = stampOf(a).compareTo(stampOf(b));
      return c != 0 ? c : appearance[a]!.compareTo(appearance[b]!);
    });

    return <LibrarySection>[
      if (ungrouped.isNotEmpty)
        LibrarySection(groupId: null, title: null, comics: ungrouped),
      for (final String id in groupIds)
        LibrarySection(
          groupId: id,
          title: names[id] ?? 'Imported Folder',
          comics: byGroup[id]!,
        ),
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

  LibraryLayout _layoutFor(
    LibraryViewMode mode,
    bool bookshelf, {
    int? columns,
  }) {
    return switch (mode) {
      LibraryViewMode.grid => LibraryLayout.grid(
        _libraryWidth,
        bookshelf: bookshelf,
        columns: columns ?? _gridColumns,
      ),
      LibraryViewMode.list => LibraryLayout.list(bookshelf: bookshelf),
      LibraryViewMode.stack => LibraryLayout.stack(bookshelf: bookshelf),
      LibraryViewMode.verticalStack => LibraryLayout.verticalStack(
        _libraryWidth,
        bookshelf: bookshelf,
      ),
    };
  }

  /// Exact sectioned geometry of the current sections in [mode].
  SectionedShelfLayout _sectionedLayoutFor(
    LibraryViewMode mode,
    bool bookshelf, {
    int? columns,
  }) {
    return SectionedShelfLayout.compute(
      layout: _layoutFor(mode, bookshelf, columns: columns),
      mode: mode,
      bookshelf: bookshelf,
      sections: _sections,
    );
  }

  /// Keeps the same place in the library when the layout changes between
  /// normal and bookshelf rows, or when the grid's column count changes. The
  /// position is tracked as "which comic (or which part of a folder header) is
  /// at the top", so it survives different row heights, a different number of
  /// comics per row and the folder headers between sections.
  void _remapScrollOffset({required bool toBookshelf, int? toColumns}) {
    final ScrollController controller = _scrollFor(_viewMode);
    if (_libraryWidth <= 0 || controller.positions.isEmpty) return;

    final ScrollPosition position = controller.positions.last;
    if (!position.hasPixels || !position.hasViewportDimension) return;
    if (_sections.isEmpty) return;

    final SectionedShelfLayout before = _sectionedLayoutFor(
      _viewMode,
      _isBookshelfMode,
    );
    final SectionedShelfLayout after = _sectionedLayoutFor(
      _viewMode,
      toBookshelf,
      columns: toColumns,
    );
    if (before.rowStride <= 0 || after.rowStride <= 0) return;

    final double target = after.offsetOf(before.anchorAt(position.pixels));
    final double maxExtent = math.max(
      0.0,
      after.contentExtent - position.viewportDimension,
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

  ScrollController _scrollFor(LibraryViewMode mode) => switch (mode) {
    LibraryViewMode.grid => _gridScroll,
    LibraryViewMode.list => _listScroll,
    LibraryViewMode.stack => _stackScroll,
    LibraryViewMode.verticalStack => _verticalStackScroll,
  };

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

  Future<void> _pickAndProcessComic() {
    return _runProcessing('Opening file manager...', () async {
      final ComicIdentity? picked = await LibraryFileOps.pickSingleComic(
        notify: _notify,
      );
      if (picked == null) return;

      if (mounted) {
        setState(() => _busyMessage = 'Importing comic into library...');
      }
      // Read in place (content:// URI or original path): no copy is made.
      await _extractAndOpen(picked.sourcePath);
    });
  }

  // ---------------------------------------------------------------------------
  // Import choice (single file / whole folder)
  // ---------------------------------------------------------------------------

  Future<void> _showImportChoiceSheet() async {
    if (_isProcessing) return;

    final _ImportChoice? choice = await showModalBottomSheet<_ImportChoice>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.insert_drive_file_outlined),
              title: const Text('Import a comic'),
              subtitle: const Text('Pick one .cbz, .zip, .cbr or .rar file'),
              onTap: () => Navigator.pop(sheetContext, _ImportChoice.file),
            ),
            ListTile(
              leading: const Icon(Icons.folder_copy_outlined),
              title: const Text('Import a folder'),
              subtitle: const Text(
                'Add every comic in a folder to the library',
              ),
              onTap: () => Navigator.pop(sheetContext, _ImportChoice.folder),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;

    switch (choice) {
      case _ImportChoice.file:
        unawaited(_pickAndProcessComic());
      case _ImportChoice.folder:
        unawaited(_pickAndImportFolder());
    }
  }

  // ---------------------------------------------------------------------------
  // Folder import
  // ---------------------------------------------------------------------------

  /// Lets the user pick a folder and imports every comic archive in it into the
  /// library, in natural filename order, WITHOUT opening any of them.
  ///
  /// Memory / storage safety (low-RAM 32-bit phones):
  ///  * Android lists the child documents first (metadata only, no copying).
  ///  * Comics are then handled strictly one at a time: fingerprint the
  ///    document in place (first 64 KB), build its cover from the content://
  ///    URI, register it and release it before the next one starts. No archive
  ///    is ever copied into app storage.
  ///  * CBR archives are not kept extracted (retainCbrCache: false), so a
  ///    folder of RAR files cannot fill the cache; they extract on first open.
  Future<void> _pickAndImportFolder() {
    return _runProcessing('Opening folder picker...', () async {
      final ({List<FolderComicEntry> entries, String folderName})? scan =
          await LibraryFileOps.scanComicFolder(notify: _notify);
      if (scan == null) return;
      await _importFolderEntries(scan.entries, scan.folderName);
    });
  }

  Future<void> _importFolderEntries(
    List<FolderComicEntry> entries,
    String folderName,
  ) async {
    final int total = entries.length;
    // One shared group per folder import. The id is a timestamp, so a later
    // import always sorts underneath every earlier one; the name is shown on
    // the shelf, cleaned of "(...)", version and volume noise.
    final String groupId = DateTime.now().microsecondsSinceEpoch.toString();
    final String groupName = cleanFolderTitle(folderName);
    int imported = 0;
    int failed = 0;

    for (int i = 0; i < total; i++) {
      if (!mounted) return;
      setState(() => _busyMessage = 'Importing ${i + 1} of $total...');
      // Let the banner repaint before the heavy work starts.
      await Future<void>.delayed(Duration.zero);

      if (await LibraryFileOps.importSingleFolderEntry(
        entries[i],
        groupId: groupId,
        groupName: groupName,
      )) {
        imported++;
      } else {
        failed++;
      }

      // Short breather between comics: lets the GC and the cover/grid
      // rendering catch up on slow 32-bit devices.
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }

    if (!mounted) return;
    final String comics = imported == 1 ? '1 comic' : '$imported comics';
    _notify(
      failed == 0
          ? 'Imported $comics.'
          : 'Imported $comics. $failed could not be imported.',
    );
  }

  Future<void> _openLibraryComic(ComicIdentity comic) {
    return _runProcessing('Opening ${comic.title}...', () async {
      if (!await LibraryFileOps.sourceExists(comic.sourcePath)) {
        _notify('"${comic.title}" is no longer at its original location.');
        return;
      }
      await _extractAndOpen(comic.sourcePath);
    });
  }

  /// Indexes [filePath], registers it in the library, opens the reader (which
  /// restores the saved position by itself) and releases the extraction once
  /// the reader is closed.
  Future<void> _extractAndOpen(String filePath) async {
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

  // ---------------------------------------------------------------------------
  // Multi-select
  // ---------------------------------------------------------------------------

  void _onEntryTap(ComicIdentity comic) {
    if (_isSelecting) {
      _toggleSelected(comic);
    } else {
      unawaited(_openLibraryComic(comic));
    }
  }

  /// Long-press starts selection mode (with this comic ticked); while already
  /// selecting it toggles the comic like a tap does.
  void _onEntryLongPress(ComicIdentity comic) {
    if (!_isSelecting && _isProcessing) return;
    unawaited(HapticFeedback.selectionClick());
    _toggleSelected(comic);
  }

  void _toggleSelected(ComicIdentity comic) {
    setState(() {
      if (!_selectedIds.remove(comic.id)) _selectedIds.add(comic.id);
    });
  }

  void _clearSelection() {
    if (_selectedIds.isEmpty) return;
    setState(_selectedIds.clear);
  }

  /// Ticks every comic that is currently listed (i.e. after the search filter).
  void _selectAllVisible() {
    setState(() {
      _selectedIds.addAll(_visible.map((ComicIdentity c) => c.id));
    });
  }

  /// The selected comics in display order (comics being deleted are skipped).
  List<ComicIdentity> _selectedComics() => <ComicIdentity>[
    for (final ComicIdentity comic in _sorted)
      if (_selectedIds.contains(comic.id)) comic,
  ];

  /// Batch "Remove from library": registry entry, cover and cached index go
  /// (plus the internal copy of a comic imported by an older version); the
  /// user's original files and reading progress stay.
  Future<void> _confirmRemoveSelected() async {
    if (_isProcessing) return;
    final List<ComicIdentity> comics = _selectedComics();
    if (comics.isEmpty) return;
    final int count = comics.length;

    final String subject = count == 1
        ? '"${comics.first.title}"'
        : 'The $count selected comics';

    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text(
          count == 1
              ? 'Remove 1 comic from library?'
              : 'Remove $count comics from library?',
        ),
        content: Text(
          '$subject will be removed from your library. PanelShift reads your '
          'comic files directly from where they are stored and makes no '
          'internal copies, so the original files are not deleted and your '
          'reading positions are kept.',
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
    if (confirmed != true || !mounted) return;

    final Set<String> ids = <String>{for (final ComicIdentity c in comics) c.id};
    setState(() {
      _isProcessing = true;
      _busyMessage = count == 1 ? 'Removing 1 comic...' : 'Removing $count comics...';
      _removing.addAll(ids);
      _selectedIds.removeAll(ids);
      _resort();
    });

    int failed = 0;
    try {
      // Sequential on purpose: registry removals are read-modify-write.
      for (final ComicIdentity comic in comics) {
        try {
          _preIndexQueue.removeWhere((ComicIdentity c) => c.id == comic.id);
          await ComicLibraryService.removeComic(comic.id);
          await ComicCoverService.instance.delete(comic.id);
          await ComicCacheService.instance.deleteIndexCache(comic.id);
          await LibraryFileOps.deleteComicFile(
            comic.sourcePath,
            deleteExternal: false,
          );
        } catch (e) {
          failed++;
          debugPrint('PanelShift: could not remove ${comic.title}: $e');
        }
      }
      try {
        await ComicCacheService.instance.purgeOrphans();
      } catch (e) {
        debugPrint('PanelShift: cache cleanup failed: $e');
      }
    } finally {
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

    final int removed = count - failed;
    if (failed > 0) {
      _notify('Removed $removed, but $failed could not be fully removed.');
    } else {
      _notify(
        removed == 1
            ? 'Removed 1 comic from the library.'
            : 'Removed $removed comics from the library.',
      );
    }
  }

  /// Batch "Delete": wipes the selection through [_deleteComics]. When the
  /// selection mixes finished and unfinished comics the dialog also offers to
  /// delete only the finished ones.
  Future<void> _confirmDeleteSelected() async {
    if (_isProcessing) return;
    final List<ComicIdentity> selected = _selectedComics();
    if (selected.isEmpty) return;

    setState(() {
      _isProcessing = true;
      _busyMessage = 'Checking selected comics...';
    });

    List<ComicIdentity> finished = const <ComicIdentity>[];
    try {
      finished = await _findFinishedComics(among: selected);
    } catch (e) {
      // Without the scan the "only finished" option is simply not offered.
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

    final bool canLimitToFinished =
        finished.isNotEmpty && finished.length < selected.length;
    bool deleteExternalFiles = false;
    bool onlyFinished = false;

    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) {
        final ColorScheme scheme = Theme.of(dialogContext).colorScheme;
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setDialogState) {
            final List<ComicIdentity> target = onlyFinished ? finished : selected;
            final int count = target.length;
            final List<String> preview = target
                .take(5)
                .map((ComicIdentity c) => c.title)
                .toList(growable: false);

            return AlertDialog(
              icon: Icon(Icons.delete_outline, color: scheme.error),
              title: Text(
                count == 1
                    ? (onlyFinished ? 'Delete 1 read comic?' : 'Delete 1 comic?')
                    : (onlyFinished
                          ? 'Delete $count read comics?'
                          : 'Delete $count comics?'),
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      deleteExternalFiles
                          ? 'The comics, PanelShift\'s internal data, AND '
                                'original external comic files (where permitted '
                                'by your OS) will be permanently deleted. This '
                                'cannot be undone.'
                          : 'The comics will be completely wiped from '
                                'PanelShift (library entry, reading progress, '
                                'covers, and cached data). PanelShift reads '
                                'your files directly and keeps no copies, so '
                                'the original files in folders like '
                                'Downloads will not be touched.',
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
                    if (canLimitToFinished)
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        dense: true,
                        value: onlyFinished,
                        title: Text(
                          finished.length == 1
                              ? 'Only delete the 1 finished comic in this selection'
                              : 'Only delete the ${finished.length} finished '
                                    'comics in this selection',
                        ),
                        onChanged: (bool? checked) {
                          setDialogState(() {
                            onlyFinished = checked ?? false;
                          });
                        },
                      ),
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

    final List<ComicIdentity> target = onlyFinished ? finished : selected;
    setState(() {
      _selectedIds.removeAll(target.map((ComicIdentity c) => c.id));
    });
    await _deleteComics(
      target,
      deleteExternalFiles: deleteExternalFiles,
      onlyRead: onlyFinished,
    );
  }

  // ---------------------------------------------------------------------------
  // Delete all read
  // ---------------------------------------------------------------------------

  /// Comics that show the "Finished" badge: their saved position is on the
  /// last page. Comics that were never opened (no saved progress) are skipped.
  ///
  /// Scans the whole library, or only [among] when given (the selection).
  Future<List<ComicIdentity>> _findFinishedComics({
    Iterable<ComicIdentity>? among,
  }) {
    return LibraryFileOps.findFinishedComics(among ?? _library);
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
                          'PanelShift (library entry, reading progress, '
                          'covers, and cached data). PanelShift reads your '
                          'files directly and keeps no copies, so the '
                          'original files in folders like Downloads will not '
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
  /// reading-progress store and the index cache (plus any legacy internal copy,
  /// and the original file when [deleteExternalFiles] is true), then sweeps the
  /// extraction cache.
  ///
  /// [onlyRead] only changes the wording of the messages ("read comics" vs.
  /// plain "comics" for an arbitrary selection).
  Future<void> _deleteComics(
      List<ComicIdentity> comics, {
        required bool deleteExternalFiles,
        bool onlyRead = true,
      }) async {
    final String noun = onlyRead ? 'read comic' : 'comic';
    final String nouns = onlyRead ? 'read comics' : 'comics';
    setState(() {
      _isProcessing = true;
      _busyMessage = comics.length == 1
          ? 'Deleting 1 $noun...'
          : 'Deleting ${comics.length} $nouns...';
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
        'Deleted $deleted $noun(s) ($protectedFiles external file(s) '
            'protected by OS).',
      );
    } else {
      _notify(
        deleted == 1 ? 'Deleted 1 $noun.' : 'Deleted $deleted $nouns.',
      );
    }
  }

  /// Wipes registry entry, cover, reading progress, cached archive index,
  /// retained CBR extraction, and the comic file for one entry.
  Future<({bool ok, bool externalProtected})> _purgeComic(
    ComicIdentity comic, {
    required bool deleteExternalFiles,
  }) async {
    _preIndexQueue.removeWhere((ComicIdentity c) => c.id == comic.id);
    return LibraryFileOps.purgeComic(
      comic,
      deleteExternalFiles: deleteExternalFiles,
    );
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    // Back clears the selection first, then closes the search bar, and only
    // then leaves the app.
    return PopScope(
      canPop: !_isSelecting && !_isSearching,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop) return;
        if (_isSelecting) {
          _clearSelection();
        } else if (_isSearching) {
          _closeSearch();
        }
      },
      child: _buildScaffold(context),
    );
  }

  Widget _buildScaffold(BuildContext context) {
    return Scaffold(
      appBar: _isSelecting
          ? _buildSelectionAppBar(context)
          : _buildLibraryAppBar(context),
      floatingActionButton: _isSelecting
          ? null
          : FloatingActionButton.extended(
              onPressed: _isProcessing ? null : _showImportChoiceSheet,
              icon: const Icon(Icons.library_add_outlined),
              label: const Text('Import'),
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

  /// Normal library bar. Fit rules for narrow phones (360 dp):
  ///  * every action is 40 dp wide instead of 48 (shrink-wrapped tap targets),
  ///  * the title scales down instead of being cut off with an ellipsis,
  ///  * Columns and Theme get their own buttons only from 600 dp up; on phones
  ///    they sit in the overflow menu next to "Delete all read", so the bar
  ///    carries no more icons than before.
  PreferredSizeWidget _buildLibraryAppBar(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool isGrid = _viewMode == LibraryViewMode.grid;
    final bool roomy = MediaQuery.sizeOf(context).width >= 600;
    final bool canTheme = widget.themeController != null;
    final bool menuHasColumns = !roomy && isGrid;
    final bool menuHasTheme = !roomy && canTheme;

    return PreferredSize(
      preferredSize: const Size.fromHeight(kToolbarHeight),
      child: Theme(
        data: theme.copyWith(
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: AppBar(
          backgroundColor: scheme.inversePrimary,
          titleSpacing: 12,
          title: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(widget.title),
          ),
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
              itemBuilder: (BuildContext context) =>
                  <PopupMenuEntry<LibrarySort>>[
                    for (final LibrarySort sort in LibrarySort.values)
                      CheckedPopupMenuItem<LibrarySort>(
                        value: sort,
                        checked: sort == _sort,
                        child: Text(sort.label),
                      ),
                  ],
            ),
            IconButton(
              tooltip: _viewModeTooltip,
              icon: Icon(_viewModeIcon),
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
            // Grid only: list and stack have no "comics per row".
            if (roomy && isGrid)
              IconButton(
                tooltip: 'Comics per row ($_columnsLabel)',
                icon: const Icon(Icons.view_column_outlined),
                onPressed: _gridColumnsLoaded && isGrid
                    ? () => unawaited(_showColumnsDialog())
                    : null,
              ),
            if (roomy && canTheme)
              IconButton(
                tooltip: 'Theme',
                icon: const Icon(Icons.palette_outlined),
                onPressed: () => unawaited(_showThemeDialog()),
              ),
            PopupMenuButton<_LibraryMenuAction>(
              tooltip: 'More options',
              onSelected: (_LibraryMenuAction action) {
                switch (action) {
                  case _LibraryMenuAction.columns:
                    unawaited(_showColumnsDialog());
                  case _LibraryMenuAction.theme:
                    unawaited(_showThemeDialog());
                  case _LibraryMenuAction.deleteRead:
                    unawaited(_confirmDeleteAllRead());
                }
              },
              itemBuilder: (BuildContext context) =>
                  <PopupMenuEntry<_LibraryMenuAction>>[
                    if (menuHasColumns)
                      PopupMenuItem<_LibraryMenuAction>(
                        value: _LibraryMenuAction.columns,
                        enabled: _gridColumnsLoaded && isGrid,
                        child: Row(
                          children: [
                            const Icon(Icons.view_column_outlined),
                            const SizedBox(width: 12),
                            Text('Columns ($_columnsLabel)'),
                          ],
                        ),
                      ),
                    if (menuHasTheme)
                      const PopupMenuItem<_LibraryMenuAction>(
                        value: _LibraryMenuAction.theme,
                        child: Row(
                          children: [
                            Icon(Icons.palette_outlined),
                            SizedBox(width: 12),
                            Text('Theme'),
                          ],
                        ),
                      ),
                    if (menuHasColumns || menuHasTheme)
                      const PopupMenuDivider(),
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
      ),
    );
  }

  /// Contextual bar shown while comics are selected.
  PreferredSizeWidget _buildSelectionAppBar(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool allVisibleSelected =
        _visible.isNotEmpty &&
        _visible.every((ComicIdentity c) => _selectedIds.contains(c.id));

    return AppBar(
      backgroundColor: scheme.secondaryContainer,
      foregroundColor: scheme.onSecondaryContainer,
      leading: IconButton(
        tooltip: 'Clear selection',
        icon: const Icon(Icons.close),
        onPressed: _clearSelection,
      ),
      title: Text('${_selectedIds.length} selected'),
      actions: [
        IconButton(
          tooltip: 'Select all',
          icon: const Icon(Icons.select_all),
          onPressed: allVisibleSelected ? null : _selectAllVisible,
        ),
        IconButton(
          tooltip: 'Remove from library',
          icon: const Icon(Icons.remove_circle_outline),
          onPressed: _isProcessing
              ? null
              : () => unawaited(_confirmRemoveSelected()),
        ),
        IconButton(
          tooltip: 'Delete',
          icon: const Icon(Icons.delete_outline),
          onPressed: _isProcessing
              ? null
              : () => unawaited(_confirmDeleteSelected()),
        ),
      ],
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
        !_gridColumnsLoaded ||
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
      child: _buildSectionedLibrary(_viewMode),
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
    required LibraryLayout layout,
    required SectionedShelfLayout sectioned,
    required bool isPile,
    required Widget scrollView,
  }) {
    final ThemeData theme = Theme.of(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: bookshelf
              ? ShelfBackdrop(
                  scroll: controller,
                  palette: theme.brightness == Brightness.dark
                      ? ShelfPalette.dark
                      : ShelfPalette.light,
                  plankTops: sectioned.regularPlankTops,
                  bottomPlankTop: sectioned.bottomPlankTop,
                  folderPlanks: sectioned.folderPlanks,
                  rowStride: layout.rowStride,
                  // A stack is one pile per section resting on its own plank:
                  // no empty shelves and no docking to the screen bottom.
                  fillEmptyShelves: !isPile,
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

  EntryLayout _entryLayoutFor(LibraryViewMode mode) => switch (mode) {
    LibraryViewMode.grid => EntryLayout.grid,
    LibraryViewMode.list => EntryLayout.list,
    LibraryViewMode.stack => EntryLayout.stack,
    LibraryViewMode.verticalStack => EntryLayout.verticalStack,
  };

  /// Header of a folder section; its height is exactly the section's
  /// `leading` extent. With bookshelf mode on the wooden divider plank and
  /// nameplate are painted by [ShelfBackdrop] underneath, so this only
  /// reserves the space (and labels it for screen readers); with it off the
  /// cleaned title is a plain, leftmost-aligned text header.
  Widget _buildFolderHeader({
    required LibrarySection section,
    required SectionGeometry geometry,
    required EdgeInsets padding,
    required bool bookshelf,
  }) {
    final String title = section.title ?? '';
    if (bookshelf) {
      return Semantics(
        header: true,
        label: title,
        child: SizedBox(height: geometry.leading),
      );
    }
    final ThemeData theme = Theme.of(context);
    return Semantics(
      header: true,
      child: SizedBox(
        height: geometry.leading,
        child: Align(
          alignment: Alignment.bottomLeft,
          child: Padding(
            padding: EdgeInsets.fromLTRB(padding.left, 0, padding.right, 8),
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.left,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.onSurface,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The library in any view mode: one [CustomScrollView] holding, per section,
  /// an optional folder header ([SliverToBoxAdapter]) followed by the section's
  /// comics ([SliverGrid] for grid / vertical stack, [SliverFixedExtentList]
  /// for list / stack). The slivers are sized from [SectionedShelfLayout], the
  /// same numbers the painted shelves use, so the books land on the planks.
  Widget _buildSectionedLibrary(LibraryViewMode mode) {
    final bool shelf = _isBookshelfMode;
    final ScrollController controller = _scrollFor(mode);

    return LayoutBuilder(
      key: ValueKey<String>('library-${mode.name}-layer'),
      builder: (BuildContext context, BoxConstraints constraints) {
        _libraryWidth = constraints.maxWidth;
        final LibraryLayout layout = _layoutFor(mode, shelf);
        final SectionedShelfLayout sectioned = SectionedShelfLayout.compute(
          layout: layout,
          mode: mode,
          bookshelf: shelf,
          sections: _sections,
        );
        final EdgeInsets pad = layout.padding;
        final EntryLayout entryLayout = _entryLayoutFor(mode);

        Widget entryFor(ComicIdentity comic) => ComicEntry(
          key: ValueKey<String>(comic.id),
          comic: comic,
          layout: entryLayout,
          bookshelf: shelf,
          isSelected: _selectedIds.contains(comic.id),
          isSelectionMode: _isSelecting,
          onTap: () => _onEntryTap(comic),
          onLongPress: () => _onEntryLongPress(comic),
        );

        Widget rowsSliver(LibrarySection section) {
          // Tiles never keep themselves alive, so skip the per-item
          // AutomaticKeepAlive wrapper; every tile is its own repaint layer.
          final SliverChildBuilderDelegate delegate = SliverChildBuilderDelegate(
            (BuildContext context, int index) =>
                entryFor(section.comics[index]),
            childCount: section.comics.length,
            addAutomaticKeepAlives: false,
            addRepaintBoundaries: true,
          );
          return switch (mode) {
            LibraryViewMode.grid || LibraryViewMode.verticalStack => SliverGrid(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: layout.crossAxisCount,
                mainAxisSpacing: layout.mainAxisSpacing,
                crossAxisSpacing: layout.crossAxisSpacing,
                mainAxisExtent: layout.cellHeight,
              ),
              delegate: delegate,
            ),
            LibraryViewMode.list || LibraryViewMode.stack =>
              SliverFixedExtentList(
                itemExtent: layout.cellHeight,
                delegate: delegate,
              ),
          };
        }

        final List<Widget> slivers = <Widget>[];
        for (int i = 0; i < _sections.length; i++) {
          final LibrarySection section = _sections[i];
          final SectionGeometry geometry = sectioned.sections[i];
          if (section.isFolder) {
            slivers.add(
              SliverToBoxAdapter(
                child: _buildFolderHeader(
                  section: section,
                  geometry: geometry,
                  padding: pad,
                  bookshelf: shelf,
                ),
              ),
            );
          }
          slivers.add(
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                pad.left,
                // The ungrouped section has no header: its leading extent is
                // the top padding (crown clearance in bookshelf mode).
                section.isFolder ? 0 : geometry.leading,
                pad.right,
                geometry.trailing,
              ),
              sliver: rowsSliver(section),
            ),
          );
        }

        return _withShelves(
          bookshelf: shelf,
          controller: controller,
          layout: layout,
          sectioned: sectioned,
          isPile: mode == LibraryViewMode.stack,
          scrollView: CustomScrollView(
            key: PageStorageKey<String>('library-${mode.name}'),
            controller: controller,
            slivers: slivers,
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
