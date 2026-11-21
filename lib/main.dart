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

Future<void> main() async {
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
  // The saved theme is read before the first frame so the app never flashes
  // the default colors first. SharedPreferences is a single small file.
  final AppThemeSettings theme = await AppThemeController.loadSaved();
  runApp(PanelShiftApp(initialTheme: theme));
}

/// ==========================================
/// 0. App theme (seed color + brightness)
/// ==========================================

/// One selectable seed color. [monochrome] renders the whole Material scheme in
/// neutral greys (used by "Monochrome Slate").
@immutable
class AppThemePreset {
  const AppThemePreset(this.name, this.argb, {this.monochrome = false});

  final String name;

  /// 0xAARRGGBB. This int is what gets persisted.
  final int argb;
  final bool monochrome;

  Color get color => Color(argb);
}

class AppThemePresets {
  const AppThemePresets._();

  static const AppThemePreset deepPurple = AppThemePreset(
    'Deep Purple',
    0xFF673AB7,
  );
  static const AppThemePreset crimson = AppThemePreset('Crimson', 0xFFC62828);
  static const AppThemePreset cobalt = AppThemePreset(
    'Cobalt Blue',
    0xFF0047AB,
  );
  static const AppThemePreset emerald = AppThemePreset('Emerald', 0xFF2E9E6B);
  static const AppThemePreset amber = AppThemePreset('Amber', 0xFFFFB300);
  static const AppThemePreset rose = AppThemePreset('Rose', 0xFFF06292);
  static const AppThemePreset slate = AppThemePreset(
    'Monochrome Slate',
    0xFF607D8B,
    monochrome: true,
  );

  static const List<AppThemePreset> all = <AppThemePreset>[
    deepPurple,
    crimson,
    cobalt,
    emerald,
    amber,
    rose,
    slate,
  ];

  /// The preset saved as [argb], or Deep Purple for anything unknown.
  static AppThemePreset byArgb(int? argb) {
    for (final AppThemePreset preset in all) {
      if (preset.argb == argb) return preset;
    }
    return deepPurple;
  }
}

/// Immutable theme choice: seed color + dark/light.
@immutable
class AppThemeSettings {
  const AppThemeSettings({required this.preset, required this.brightness});

  static const AppThemeSettings defaults = AppThemeSettings(
    preset: AppThemePresets.deepPurple,
    brightness: Brightness.dark,
  );

  final AppThemePreset preset;
  final Brightness brightness;

  ThemeData toThemeData() {
    final ColorScheme scheme = ColorScheme.fromSeed(
      seedColor: preset.color,
      brightness: brightness,
      dynamicSchemeVariant: preset.monochrome
          ? DynamicSchemeVariant.monochrome
          : DynamicSchemeVariant.tonalSpot,
    );
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      brightness: brightness,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AppThemeSettings &&
      other.preset.argb == preset.argb &&
      other.brightness == brightness;

  @override
  int get hashCode => Object.hash(preset.argb, brightness);
}

/// Holds the live theme at the app root. Library code only ever calls
/// [select]; [PanelShiftApp] listens and rebuilds the [MaterialApp] with the
/// new [ThemeData], so the screen below keeps its State (scroll position,
/// search, selection, pre-indexer queue).
class AppThemeController extends ValueNotifier<AppThemeSettings> {
  AppThemeController([AppThemeSettings initial = AppThemeSettings.defaults])
    : super(initial);

  static const String seedKey = 'panelshift.themeSeed.v1';
  static const String brightnessKey = 'panelshift.themeBrightness.v1';

  static Future<AppThemeSettings> loadSaved() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      return AppThemeSettings(
        preset: AppThemePresets.byArgb(prefs.getInt(seedKey)),
        brightness: prefs.getString(brightnessKey) == Brightness.light.name
            ? Brightness.light
            : Brightness.dark,
      );
    } catch (e) {
      debugPrint('PanelShift: could not load theme: $e');
      return AppThemeSettings.defaults;
    }
  }

  void select({AppThemePreset? preset, Brightness? brightness}) {
    final AppThemeSettings next = AppThemeSettings(
      preset: preset ?? value.preset,
      brightness: brightness ?? value.brightness,
    );
    if (next == value) return;
    value = next;
    unawaited(_save(next));
  }

  Future<void> _save(AppThemeSettings settings) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setInt(seedKey, settings.preset.argb);
      await prefs.setString(brightnessKey, settings.brightness.name);
    } catch (e) {
      debugPrint('PanelShift: could not save theme: $e');
    }
  }
}

class PanelShiftApp extends StatefulWidget {
  const PanelShiftApp({
    super.key,
    this.initialTheme = AppThemeSettings.defaults,
  });

  final AppThemeSettings initialTheme;

  @override
  State<PanelShiftApp> createState() => _PanelShiftAppState();
}

class _PanelShiftAppState extends State<PanelShiftApp> {
  late final AppThemeController _theme = AppThemeController(
    widget.initialTheme,
  );

  // Built once and handed to the builder as its `child`: a theme change
  // rebuilds MaterialApp only, and the screen's State is never replaced.
  late final Widget _home = ComicProcessorScreen(
    title: 'PanelShift Core Engine',
    themeController: _theme,
  );

  @override
  void dispose() {
    _theme.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppThemeSettings>(
      valueListenable: _theme,
      child: _home,
      builder: (BuildContext context, AppThemeSettings settings, Widget? home) {
        return MaterialApp(
          title: 'PanelShift Core',
          theme: settings.toThemeData(),
          home: home,
        );
      },
    );
  }
}

/// ==========================================
/// 1. Library Dashboard (import + grid/list/stack)
/// ==========================================
/// How the library is laid out. The enum [name] is what gets persisted.
///  * [grid]  - covers in columns,
///  * [list]  - one card per row,
///  * [stack] - a vertical pile of horizontal book spines (leftmost fifth of
///    each cover wrapped around the spine),
///  * [verticalStack] - rows of upright book spines standing side by side on
///    shelves (leftmost fifth of each cover running top to bottom).
enum LibraryViewMode { grid, list, stack, verticalStack }

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

enum _LibraryMenuAction { columns, theme, deleteRead }

enum _ImportChoice { file, folder }

/// One comic archive found by the Android folder scan. Only metadata: nothing
/// is copied until the comic's turn comes in the import loop.
class _FolderComicEntry {
  const _FolderComicEntry({
    required this.uri,
    required this.fileName,
    required this.path,
    required this.size,
  });

  /// Child document URI (content://...), kept as the "original source" so
  /// "Delete all read" can delete the external original later.
  final String uri;

  /// File-system-safe name used for the cache copy and imported_comics/.
  final String fileName;

  /// Path relative to the picked folder; natural-sorted to get import order.
  final String path;

  /// Byte size reported by the storage provider, or -1 when unknown.
  final int size;
}

enum _FileDeleteOutcome { deleted, skippedExternal, protectedOrLocked }

class ComicProcessorScreen extends StatefulWidget {
  const ComicProcessorScreen({
    super.key,
    required this.title,
    this.themeController,
  });

  final String title;

  /// Owned by [PanelShiftApp]. When null (for example in a widget test) the
  /// Theme button is simply not shown.
  final AppThemeController? themeController;

  @override
  State<ComicProcessorScreen> createState() => _ComicProcessorScreenState();
}

class _ComicProcessorScreenState extends State<ComicProcessorScreen> {
  static const String _viewModeKey = 'panelshift.libraryViewMode.v1';
  static const String _bookshelfModeKey = 'panelshift.bookshelfMode.v1';
  static const String _sortKey = 'panelshift.librarySort.v1';
  static const String _gridColumnsKey = 'panelshift.gridColumns.v1';
  static const String _originalSourcesKey = 'panelshift.originalSources.v1';
  static const MethodChannel _safChannel = MethodChannel('panelshift/saf_picker');

  /// Folder import also picks up comics inside sub-folders (breadth-first, up
  /// to 8 levels). Set to false to import only the picked folder's own files.
  static const bool _folderImportScansSubfolders = true;

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
  // the search query. The grid, list and stack always render [_visible].
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
          _ThemeDialog(controller: controller),
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

  _LibraryLayout _layoutFor(
    LibraryViewMode mode,
    bool bookshelf, {
    int? columns,
  }) {
    return switch (mode) {
      LibraryViewMode.grid => _LibraryLayout.grid(
        _libraryWidth,
        bookshelf: bookshelf,
        columns: columns ?? _gridColumns,
      ),
      LibraryViewMode.list => _LibraryLayout.list(bookshelf: bookshelf),
      LibraryViewMode.stack => _LibraryLayout.stack(bookshelf: bookshelf),
      LibraryViewMode.verticalStack => _LibraryLayout.verticalStack(
        _libraryWidth,
        bookshelf: bookshelf,
      ),
    };
  }

  /// Keeps the same place in the library when the layout changes between
  /// normal and bookshelf rows, or when the grid's column count changes. The
  /// position is tracked as "which comic is at the top", so it survives a
  /// different number of comics per row.
  void _remapScrollOffset({required bool toBookshelf, int? toColumns}) {
    final ScrollController controller = switch (_viewMode) {
      LibraryViewMode.grid => _gridScroll,
      LibraryViewMode.list => _listScroll,
      LibraryViewMode.stack => _stackScroll,
      LibraryViewMode.verticalStack => _verticalStackScroll,
    };
    if (_libraryWidth <= 0 || controller.positions.isEmpty) return;

    final ScrollPosition position = controller.positions.last;
    if (!position.hasPixels || !position.hasViewportDimension) return;

    final _LibraryLayout before = _layoutFor(_viewMode, _isBookshelfMode);
    final _LibraryLayout after = _layoutFor(
      _viewMode,
      toBookshelf,
      columns: toColumns,
    );
    if (before.rowStride <= 0 || after.rowStride <= 0) return;

    final double rowPosition =
        (position.pixels - before.topInset) / before.rowStride;
    // Row -> comic position -> row of the new layout (identical when the
    // column count does not change).
    final double itemPosition = rowPosition * before.crossAxisCount;
    final double newRowPosition = itemPosition / after.crossAxisCount;
    final double target = after.topInset + newRowPosition * after.rowStride;
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
  ///  * Comics are then handled strictly one at a time: stream one document
  ///    into cache/file_picker/, persist it into imported_comics/ (which deletes
  ///    the cache copy), open it, build the cover, register it and close it
  ///    again before the next one starts.
  ///  * CBR archives are not kept extracted (retainCbrCache: false), so a
  ///    folder of RAR files cannot fill the cache; they extract on first open.
  Future<void> _pickAndImportFolder() {
    return _runProcessing('Opening folder picker...', () async {
      if (!Platform.isAndroid) {
        _notify('Folder import is available on Android only.');
        return;
      }

      final Map<String, dynamic>? picked =
          await _safChannel.invokeMapMethod<String, dynamic>(
        'pickComicFolder',
        <String, Object?>{'recursive': _folderImportScansSubfolders},
      );
      if (picked == null) {
        _notify('Folder selection cancelled.');
        return;
      }

      final List<_FolderComicEntry> found = <_FolderComicEntry>[];
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
          _FolderComicEntry(
            uri: uri,
            fileName: fileName,
            path: (raw['path'] as String?) ?? fileName,
            size: (raw['size'] as num?)?.toInt() ?? -1,
          ),
        );
      }

      if (found.isEmpty) {
        _notify('No .cbz, .zip, .cbr or .rar files found in that folder.');
        return;
      }

      // Natural order on the relative path: "Issue 2" before "Issue 10", and
      // files stay grouped by sub-folder.
      final List<_FolderComicEntry> entries = ComicParserService.sortNaturally(
        found,
        (_FolderComicEntry entry) => entry.path,
      );
      await _importFolderEntries(entries);
    });
  }

  Future<void> _importFolderEntries(List<_FolderComicEntry> entries) async {
    final int total = entries.length;
    int imported = 0;
    int failed = 0;

    for (int i = 0; i < total; i++) {
      if (!mounted) return;
      setState(() => _busyMessage = 'Importing ${i + 1} of $total...');
      // Let the banner repaint before the heavy work starts.
      await Future<void>.delayed(Duration.zero);

      if (await _importFolderEntry(entries[i])) {
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

  /// Imports one comic of a folder scan. Returns true when it is in the library.
  /// Never throws; a bad archive must not stop the rest of the folder.
  Future<bool> _importFolderEntry(_FolderComicEntry entry) async {
    final String sep = Platform.pathSeparator;
    final Directory libraryDir = await _managedLibraryDir();
    final File managedTarget = File(
      '${libraryDir.path}$sep${entry.fileName}',
    );
    // Remember whether this import creates the managed copy, so a broken
    // archive's copy can be removed again without touching an older comic.
    final bool targetExistedBefore = await managedTarget.exists();

    String? tempPath;
    String? persistentPath;
    bool registered = false;
    try {
      if (targetExistedBefore &&
          entry.size >= 0 &&
          await managedTarget.length() == entry.size) {
        // Already imported earlier (same name and byte size): skip the copy.
        persistentPath = managedTarget.path;
      } else {
        tempPath = await _safChannel.invokeMethod<String>(
          'copyDocumentToCache',
          <String, Object?>{'uri': entry.uri, 'name': entry.fileName},
        );
        if (tempPath == null || tempPath.isEmpty) {
          throw StateError('The document could not be copied.');
        }
        persistentPath = await _persistPickedFile(tempPath);
        tempPath = null; // _persistPickedFile removed the cache copy.
      }

      final LoadedComic loaded = await ComicParserService.loadComic(
        persistentPath,
        retainCbrCache: false,
      );
      final ComicIdentity identity = loaded.identity;
      try {
        if (loaded.source.pageCount > 0) {
          // Cover first, while the source is open (no-op if one already exists).
          await ComicCoverService.instance.adopt(loaded);
          await ComicLibraryService.addComic(identity);
          registered = true;
        }
      } finally {
        // Release this comic (and its CBR extraction) before the next one.
        try {
          await loaded.close();
        } catch (e) {
          debugPrint('PanelShift: closing "${entry.path}" failed: $e');
        }
      }

      if (!registered) {
        debugPrint('PanelShift: no image pages in "${entry.path}", skipped.');
        if (!targetExistedBefore) {
          await _deleteComicFile(persistentPath, deleteExternal: false);
        }
        return false;
      }

      await _saveOriginalSource(identity.id, entry.uri);
      return true;
    } catch (e) {
      debugPrint('PanelShift: folder import failed for "${entry.path}": $e');
      if (tempPath != null) {
        try {
          await File(tempPath).delete();
        } catch (_) {}
      }
      if (!targetExistedBefore && !registered) {
        // Fresh (possibly half-written) managed copy of a failed import.
        try {
          if (await managedTarget.exists()) await managedTarget.delete();
        } catch (_) {}
      }
      return false;
    }
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

  /// Batch "Remove from library": registry entry, cover, cached index and
  /// PanelShift's internal copy go; external originals and reading progress
  /// stay (same as the old single-comic remove).
  Future<void> _confirmRemoveSelected() async {
    if (_isProcessing) return;
    final List<ComicIdentity> comics = _selectedComics();
    if (comics.isEmpty) return;
    final int count = comics.length;

    final String subject = count == 1
        ? '"${comics.first.title}" and PanelShift\'s internal copy'
        : 'The $count selected comics and PanelShift\'s internal copies';

    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text(
          count == 1
              ? 'Remove 1 comic from library?'
              : 'Remove $count comics from library?',
        ),
        content: Text(
          '$subject will be removed. Any original files in your external '
          'folders are not deleted, and your reading positions are kept.',
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
          await _deleteComicFile(comic.sourcePath, deleteExternal: false);
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
                                'PanelShift (library entry, internal copy, '
                                'reading progress, covers, and cached data). '
                                'Original external files in folders like '
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
  }) async {
    final ComicCoverService covers = ComicCoverService.instance;
    final List<ComicIdentity> finished = <ComicIdentity>[];

    for (final ComicIdentity comic in List<ComicIdentity>.of(among ?? _library)) {
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
      child: switch (_viewMode) {
        LibraryViewMode.grid => _buildGrid(),
        LibraryViewMode.list => _buildList(),
        LibraryViewMode.stack => _buildStack(),
        LibraryViewMode.verticalStack => _buildVerticalStack(),
      },
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
    bool drawIntermediateShelves = true,
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
                  drawIntermediateShelves: drawIntermediateShelves,
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
          columns: _gridColumns,
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
                isSelected: _selectedIds.contains(comic.id),
                isSelectionMode: _isSelecting,
                onTap: () => _onEntryTap(comic),
                onLongPress: () => _onEntryLongPress(comic),
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
                isSelected: _selectedIds.contains(comic.id),
                isSelectionMode: _isSelecting,
                onTap: () => _onEntryTap(comic),
                onLongPress: () => _onEntryLongPress(comic),
              );
            },
          ),
        );
      },
    );
  }

  /// Stack mode: one horizontal book spine per row, lazily built with a fixed
  /// extent. In bookshelf mode the spines touch and form a pile resting on the
  /// bottom plank, so [_ShelfBackdrop] skips the planks between rows.
  Widget _buildStack() {
    final bool shelf = _isBookshelfMode;

    return LayoutBuilder(
      key: const ValueKey<String>('library-stack-layer'),
      builder: (BuildContext context, BoxConstraints constraints) {
        _libraryWidth = constraints.maxWidth;
        final _LibraryLayout layout = _LibraryLayout.stack(bookshelf: shelf);

        return _withShelves(
          bookshelf: shelf,
          controller: _stackScroll,
          layout: layout,
          rowCount: _visible.length,
          // No wooden plank between stacked books (this layer only exists
          // while the view mode is LibraryViewMode.stack).
          drawIntermediateShelves: false,
          scrollView: ListView.builder(
            key: const PageStorageKey<String>('library-stack'),
            controller: _stackScroll,
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
                layout: _EntryLayout.stack,
                bookshelf: shelf,
                isSelected: _selectedIds.contains(comic.id),
                isSelectionMode: _isSelecting,
                onTap: () => _onEntryTap(comic),
                onLongPress: () => _onEntryLongPress(comic),
              );
            },
          ),
        );
      },
    );
  }

  /// Vertical shelf stack: upright book spines standing side by side, as many
  /// per row as the shelf is wide, on shelves with the same compartment height
  /// as the 4-comics-per-row grid. Rows (and their planks) stack vertically as
  /// the library grows, exactly like the grid.
  Widget _buildVerticalStack() {
    final bool shelf = _isBookshelfMode;

    return LayoutBuilder(
      key: const ValueKey<String>('library-vertical-stack-layer'),
      builder: (BuildContext context, BoxConstraints constraints) {
        _libraryWidth = constraints.maxWidth;
        final _LibraryLayout layout = _LibraryLayout.verticalStack(
          constraints.maxWidth,
          bookshelf: shelf,
        );

        return _withShelves(
          bookshelf: shelf,
          controller: _verticalStackScroll,
          layout: layout,
          rowCount: layout.rowCount(_visible.length),
          scrollView: GridView.builder(
            key: const PageStorageKey<String>('library-vertical-stack'),
            controller: _verticalStackScroll,
            padding: layout.padding,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: layout.crossAxisCount,
              mainAxisSpacing: layout.mainAxisSpacing,
              crossAxisSpacing: layout.crossAxisSpacing,
              mainAxisExtent: layout.cellHeight,
            ),
            itemCount: _visible.length,
            addAutomaticKeepAlives: false,
            addRepaintBoundaries: true,
            itemBuilder: (BuildContext context, int index) {
              final ComicIdentity comic = _visible[index];
              return _ComicEntry(
                key: ValueKey<String>(comic.id),
                comic: comic,
                layout: _EntryLayout.verticalStack,
                bookshelf: shelf,
                isSelected: _selectedIds.contains(comic.id),
                isSelectionMode: _isSelecting,
                onTap: () => _onEntryTap(comic),
                onLongPress: () => _onEntryLongPress(comic),
              );
            },
          ),
        );
      },
    );
  }
}

/// Compact theme chooser. Choices apply immediately (live preview) and are
/// persisted by [AppThemeController]; the dialog just listens to it.
class _ThemeDialog extends StatelessWidget {
  const _ThemeDialog({required this.controller});

  final AppThemeController controller;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return AlertDialog(
      title: const Text('Theme'),
      contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      content: SizedBox(
        width: 320,
        child: ValueListenableBuilder<AppThemeSettings>(
          valueListenable: controller,
          builder: (BuildContext context, AppThemeSettings settings, _) {
            return SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Color', style: text.labelLarge),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 6,
                    runSpacing: 8,
                    children: [
                      for (final AppThemePreset preset in AppThemePresets.all)
                        _ThemeSwatch(
                          preset: preset,
                          selected: preset.argb == settings.preset.argb,
                          onTap: () => controller.select(preset: preset),
                        ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Text('Mode', style: text.labelLarge),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<Brightness>(
                      showSelectedIcon: false,
                      segments: const <ButtonSegment<Brightness>>[
                        ButtonSegment<Brightness>(
                          value: Brightness.dark,
                          icon: Icon(Icons.dark_mode_outlined),
                          label: Text('Dark'),
                        ),
                        ButtonSegment<Brightness>(
                          value: Brightness.light,
                          icon: Icon(Icons.light_mode_outlined),
                          label: Text('Light'),
                        ),
                      ],
                      selected: <Brightness>{settings.brightness},
                      onSelectionChanged: (Set<Brightness> selection) =>
                          controller.select(brightness: selection.first),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Bookshelf wood follows the mode: walnut in dark, oak in '
                    'light.',
                    style: text.bodySmall,
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }
}

class _ThemeSwatch extends StatelessWidget {
  const _ThemeSwatch({
    required this.preset,
    required this.selected,
    required this.onTap,
  });

  final AppThemePreset preset;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color color = preset.color;
    final Color onColor =
        ThemeData.estimateBrightnessForColor(color) == Brightness.dark
        ? Colors.white
        : Colors.black;

    return SizedBox(
      width: 72,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: selected ? scheme.primary : scheme.outlineVariant,
                    width: selected ? 3 : 1,
                  ),
                ),
                child: SizedBox(
                  width: 40,
                  height: 40,
                  child: selected
                      ? Icon(Icons.check, size: 20, color: onColor)
                      : null,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                preset.name,
                maxLines: 2,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.labelSmall?.copyWith(fontSize: 10.5, height: 1.15),
              ),
            ],
          ),
        ),
      ),
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
/// 2. Library card (shared by grid, list, stack and vertical stack)
/// ==========================================
enum _EntryLayout { grid, list, stack, verticalStack }

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
    this.isSelected = false,
    this.isSelectionMode = false,
  });

  final ComicIdentity comic;
  final _EntryLayout layout;
  final bool bookshelf;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  /// This comic is ticked in multi-select mode.
  final bool isSelected;

  /// The dashboard is in multi-select mode (some comic is ticked).
  final bool isSelectionMode;

  @override
  State<_ComicEntry> createState() => _ComicEntryState();
}

class _ComicEntryState extends State<_ComicEntry> {
  late final Future<ComicCover?> _coverFuture;
  late final ComicCover? _initialCover;

  /// Luminance-weighted grayscale applied to finished covers. A colour matrix
  /// runs on the GPU over the already-decoded bitmap, so it costs no extra
  /// decode and no extra image cache entry.
  static const ColorFilter _grayscaleFilter = ColorFilter.matrix(<double>[
    0.2126, 0.7152, 0.0722, 0, 0,
    0.2126, 0.7152, 0.0722, 0, 0,
    0.2126, 0.7152, 0.0722, 0, 0,
    0, 0, 0, 1, 0,
  ]);

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
        final bool isStack = widget.layout == _EntryLayout.stack;
        final bool isVerticalStack =
            widget.layout == _EntryLayout.verticalStack;
        final _ProgressSummary? summary = _summarize(
          cover?.pageCount,
          compact: isGrid || isStack || isVerticalStack,
        );

        // Upright spine: same leftmost-fifth art as the horizontal spine, but
        // running top to bottom (no rotation). It carries no text at all.
        if (isVerticalStack) {
          final Widget spineCover = _buildVerticalSpineCover(
            context,
            cover,
            finished: summary?.finished ?? false,
          );
          return Semantics(
            label: widget.comic.title,
            child: widget.bookshelf
                ? _buildShelfVerticalStackTile(context, spineCover, summary)
                : _buildVerticalStackTile(context, spineCover, summary),
          );
        }

        // A spine shows only the leftmost fifth of the cover, so it has its
        // own (smaller) decode path instead of the full-cover widget below.
        if (isStack) {
          final Widget spineCover = _buildSpineCover(
            context,
            cover,
            finished: summary?.finished ?? false,
          );
          return widget.bookshelf
              ? _buildShelfStackTile(context, spineCover, summary)
              : _buildStackTile(context, spineCover, summary);
        }

        final Widget coverWidget = _buildCover(
          context,
          cover,
          loading: snapshot.connectionState != ConnectionState.done,
          finished: summary?.finished ?? false,
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
    bool finished = false,
  }) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    Widget placeholder(Widget child) => ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: Center(child: child),
    );

    if (cover != null) {
      return LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final Widget image = Image.file(
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
          // Finished comics are shown in black and white.
          return finished
              ? ColorFiltered(colorFilter: _grayscaleFilter, child: image)
              : image;
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

  /// Only flags a missing source file. The top-right check mark belongs to
  /// the selection indicator (see [_selectionMarks]); finished comics are
  /// shown with a black-and-white cover instead. In selection mode the badge
  /// moves to the top-left so it never sits under the indicator.
  Widget _statusBadge(
    ColorScheme scheme,
    _ProgressSummary? summary, {
    bool compact = false,
  }) {
    if (!_sourceMissing) return const SizedBox.shrink();

    // Narrow upright spine (~40 dp): a small centered badge just above the
    // progress bar, so it never meets the selection circle at the top.
    if (compact) {
      return Positioned(
        left: 0,
        right: 0,
        bottom: 8,
        child: Center(
          heightFactor: 1,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: scheme.errorContainer,
              shape: BoxShape.circle,
            ),
            child: Padding(
              padding: const EdgeInsets.all(3),
              child: Icon(
                Icons.link_off,
                size: 12,
                color: scheme.onErrorContainer,
              ),
            ),
          ),
        ),
      );
    }

    return Positioned(
      top: 6,
      left: widget.isSelectionMode ? 6 : null,
      right: widget.isSelectionMode ? null : 6,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.errorContainer,
          shape: BoxShape.circle,
        ),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(
            Icons.link_off,
            size: 14,
            color: scheme.onErrorContainer,
          ),
        ),
      ),
    );
  }

  /// Selection overlay for the cover stack: an empty circle on every comic
  /// while in selection mode, and on the selected ones a filled check badge
  /// (top right), a light tint and, with [outline], a border. Pass
  /// `outline: false` where the surrounding [Card] draws the border itself.
  Widget _selectionMarks(
    ColorScheme scheme, {
    bool outline = true,
    bool compact = false,
  }) {
    if (!widget.isSelectionMode) return const SizedBox.shrink();
    final bool selected = widget.isSelected;
    // Compact (narrow upright spine): a 20 dp circle centered at the top
    // instead of a 24 dp one in the corner, so it fits without clipping.
    final double markSize = compact ? 20 : 24;
    final double checkSize = compact ? 12 : 14;
    final Widget markCircle = SizedBox(
      width: markSize,
      height: markSize,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: selected ? scheme.primary : Colors.black38,
          border: Border.all(
            color: selected ? scheme.onPrimary : Colors.white,
            width: 2,
          ),
        ),
        child: selected
            ? Center(
                child: Icon(
                  Icons.check,
                  size: checkSize,
                  color: scheme.onPrimary,
                ),
              )
            : null,
      ),
    );

    return Positioned.fill(
      child: IgnorePointer(
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (selected)
              DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.primary.withAlpha(46),
                  border: outline
                      ? Border.all(color: scheme.primary, width: 3)
                      : null,
                ),
              ),
            Positioned(
              top: 6,
              left: compact ? 0 : null,
              right: compact ? 0 : 6,
              child: compact
                  ? Center(heightFactor: 1, child: markCircle)
                  : markCircle,
            ),
          ],
        ),
      ),
    );
  }

  /// Card outline for the normal (non-bookshelf) layouts.
  ShapeBorder _cardShape(ColorScheme scheme) => RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(12),
    side: widget.isSelected
        ? BorderSide(color: scheme.primary, width: 2)
        : BorderSide.none,
  );

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
                _selectionMarks(theme.colorScheme),
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
                    children: [
                      cover,
                      _statusBadge(theme.colorScheme, summary),
                      _selectionMarks(theme.colorScheme),
                    ],
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

  // --- stack layout (book spines) -------------------------------------------

  /// Fraction of the cover's width that wraps the spine (its leftmost edge).
  static const double _kSpineCoverFraction = 0.2;

  /// Hard ceiling for a spine cover's decoded width. The whole cover is
  /// decoded (only its left fifth is visible), so this is kept well under
  /// [_kCoverDecodeCeiling]: ~0.4 MB per cover instead of ~1.4 MB.
  static const int _kSpineDecodeCeiling = 256;

  static const BorderRadius _spineRadius = BorderRadius.horizontal(
    left: Radius.circular(6),
    right: Radius.circular(6),
  );

  /// Everything that sits on top of the spine art, as one const (never
  /// rebuilt) layer set: a dark scrim so text stays readable over bright
  /// covers, rounded book-end cap shading, a top highlight and a bottom
  /// contact shadow. The shadow is painted *inside* each spine because the
  /// next spine in the pile paints over anything spilling out of this one.
  static const Widget _spineShade = Stack(
    fit: StackFit.expand,
    children: [
      // Readability scrim (heavier under the title side).
      DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [Color(0xB3000000), Color(0x8C000000)],
          ),
        ),
      ),
      // Rounded left / right book-end caps.
      DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            stops: [0.0, 0.035, 0.08, 0.92, 0.965, 1.0],
            colors: [
              Color(0x99000000),
              Color(0x40000000),
              Color(0x00000000),
              Color(0x00000000),
              Color(0x33000000),
              Color(0x80000000),
            ],
          ),
        ),
      ),
      // Top highlight line + bottom contact shadow.
      DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            stops: [0.0, 0.03, 0.045, 0.66, 0.94, 1.0],
            colors: [
              Color(0x66FFFFFF),
              Color(0x59FFFFFF),
              Color(0x00FFFFFF),
              Color(0x00000000),
              Color(0x66000000),
              Color(0xB3000000),
            ],
          ),
        ),
      ),
    ],
  );

  static const List<Shadow> _spineTextShadows = <Shadow>[
    Shadow(color: Color(0xCC000000), blurRadius: 3, offset: Offset(0, 1)),
  ];

  /// The leftmost 20 % of [cover], filling [constraints] (tight, finite). The
  /// cover is laid out 5x the strip's width and clipped to its left fifth;
  /// both spine layouts use this, the horizontal one inside a [RotatedBox].
  Widget _buildCoverStrip(
    BuildContext context,
    ComicCover cover,
    BoxConstraints constraints, {
    required bool finished,
    required Widget placeholder,
  }) {
    final double stripWidth = constraints.maxWidth;
    final double stripHeight = constraints.maxHeight;
    if (!stripWidth.isFinite ||
        !stripHeight.isFinite ||
        stripWidth <= 0 ||
        stripHeight <= 0) {
      return placeholder;
    }
    final double fullWidth = stripWidth / _kSpineCoverFraction;
    final double dpr = MediaQuery.devicePixelRatioOf(context);

    final Widget image = Image.file(
      File(cover.path),
      width: fullWidth,
      height: stripHeight,
      fit: BoxFit.cover,
      // Keep the cover's left edge (and its top) when cropping.
      alignment: Alignment.topLeft,
      // Strictly bounded decode (<= 256 px wide).
      cacheWidth: (fullWidth * dpr)
          .ceil()
          .clamp(96, _kSpineDecodeCeiling)
          .toInt(),
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
      errorBuilder: (context, error, stackTrace) => placeholder,
    );
    // Finished comics are shown in black and white.
    final Widget art = finished
        ? ColorFiltered(colorFilter: _grayscaleFilter, child: image)
        : image;

    return ClipRect(
      child: OverflowBox(
        alignment: Alignment.centerLeft,
        minWidth: 0,
        maxWidth: fullWidth,
        minHeight: stripHeight,
        maxHeight: stripHeight,
        child: Align(
          alignment: Alignment.centerLeft,
          widthFactor: _kSpineCoverFraction,
          child: art,
        ),
      ),
    );
  }

  /// Spine art: the leftmost 20 % of the cover, rotated a quarter turn so the
  /// cover's left edge wraps horizontally across the spine. The cover is
  /// laid out 5x the strip's width and clipped to its left fifth.
  Widget _buildSpineCover(
    BuildContext context,
    ComicCover? cover, {
    bool finished = false,
  }) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Widget placeholder = ColoredBox(color: scheme.surfaceContainerHighest);
    if (cover == null) return placeholder;

    return RotatedBox(
      quarterTurns: 1,
      // Inside the RotatedBox the constraints are transposed: maxWidth is the
      // spine's thickness and maxHeight is its length.
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          return _buildCoverStrip(
            context,
            cover,
            constraints,
            finished: finished,
            placeholder: placeholder,
          );
        },
      ),
    );
  }

  /// Short status for a spine: percentage while reading, else the status.
  String _spineLabel(_ProgressSummary? summary) {
    if (_sourceMissing) return 'File not found';
    if (summary == null) return '';
    if (summary.finished) return summary.label;
    final double? fraction = summary.fraction;
    if (fraction != null) return '${(fraction * 100).round()}%';
    return summary.label;
  }

  /// One horizontal book spine. [bookshelf] only changes how the pile looks:
  /// on a shelf the spines touch (the next one covers this one's shadow) and
  /// cast a soft shadow sideways onto the wall; off a shelf each spine is an
  /// inset rounded bar with a small gap above and below.
  Widget _buildSpine(
    BuildContext context,
    Widget spineCover,
    _ProgressSummary? summary, {
    required bool bookshelf,
  }) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final double? fraction = summary?.fraction;
    final String label = _spineLabel(summary);

    // Keep the title/label clear of the status badge and the selection
    // circle (both 24 dp round marks that sit 6 dp in from a corner).
    final bool badgeLeft = _sourceMissing && widget.isSelectionMode;
    final double leftPad = badgeLeft ? 36 : 18;
    final double rightPad = (widget.isSelectionMode || _sourceMissing) ? 36 : 14;

    final Widget body = ClipRRect(
      borderRadius: _spineRadius,
      child: Stack(
        fit: StackFit.expand,
        children: [
          spineCover,
          _spineShade,
          Positioned.fill(
            child: Padding(
              padding: EdgeInsets.fromLTRB(leftPad, 0, rightPad, 3),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.comic.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        shadows: _spineTextShadows,
                      ),
                    ),
                  ),
                  if (label.isNotEmpty) ...[
                    const SizedBox(width: 10),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 96),
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: _sourceMissing
                              ? scheme.errorContainer
                              : const Color(0xE6FFFFFF),
                          shadows: _spineTextShadows,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (fraction != null) _shelfProgressBar(fraction),
          _statusBadge(scheme, summary),
          _selectionMarks(scheme),
          // Ripple sits above everything so it is actually visible.
          Positioned.fill(
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                onTap: widget.onTap,
                onLongPress: widget.onLongPress,
              ),
            ),
          ),
        ],
      ),
    );

    if (!bookshelf) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: _ShelfDims.stackGap / 2),
        child: body,
      );
    }
    return DecoratedBox(
      decoration: const BoxDecoration(
        borderRadius: _spineRadius,
        boxShadow: <BoxShadow>[
          // Soft shadow onto the back wall / plank beside the pile.
          BoxShadow(
            color: Color(0x73000000),
            blurRadius: 5,
            offset: Offset(2.5, 0.5),
          ),
        ],
      ),
      child: body,
    );
  }

  /// Stack row outside bookshelf mode (gap between spines).
  Widget _buildStackTile(
    BuildContext context,
    Widget spineCover,
    _ProgressSummary? summary,
  ) => _buildSpine(context, spineCover, summary, bookshelf: false);

  /// Stack row in bookshelf mode: spines are stacked directly on top of each
  /// other. The pile rests on the bottom plank drawn by [_BookshelfPainter];
  /// there is no plank between books.
  Widget _buildShelfStackTile(
    BuildContext context,
    Widget spineCover,
    _ProgressSummary? summary,
  ) => _buildSpine(context, spineCover, summary, bookshelf: true);

  // --- vertical stack layout (upright book spines) ---------------------------

  static const BorderRadius _verticalSpineRadius = BorderRadius.all(
    Radius.circular(3),
  );

  /// Overlay for an upright spine, as one const layer set: a dark readability
  /// scrim plus cylindrical left-to-right shading (left highlight, a curved
  /// spine crease, right edge shadow) so books standing side by side read as
  /// separate 3D objects.
  static const Widget _verticalSpineShade = Stack(
    fit: StackFit.expand,
    children: [
      // Dark scrim (a touch heavier at the foot, where the plank shadow is).
      DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0x4D000000), Color(0x33000000), Color(0x80000000)],
            stops: [0.0, 0.55, 1.0],
          ),
        ),
      ),
      // Cylinder: left highlight, crease, right edge shadow.
      DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            stops: [0.0, 0.07, 0.13, 0.18, 0.28, 0.72, 0.9, 1.0],
            colors: [
              Color(0x4DFFFFFF),
              Color(0x1AFFFFFF),
              Color(0x66000000),
              Color(0x1FFFFFFF),
              Color(0x00000000),
              Color(0x00000000),
              Color(0x40000000),
              Color(0x99000000),
            ],
          ),
        ),
      ),
    ],
  );

  /// Upright spine art: the leftmost 20 % of the cover running top to bottom
  /// (no rotation). Same strip as [_buildSpineCover], 256 px decode ceiling.
  Widget _buildVerticalSpineCover(
    BuildContext context,
    ComicCover? cover, {
    bool finished = false,
  }) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Widget placeholder = ColoredBox(color: scheme.surfaceContainerHighest);
    if (cover == null) return placeholder;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        return _buildCoverStrip(
          context,
          cover,
          constraints,
          finished: finished,
          placeholder: placeholder,
        );
      },
    );
  }

  /// Layers of an upright spine (no text). Everything fits the narrow spine:
  /// the badge and the selection circle are centered and compact.
  List<Widget> _verticalSpineLayers(
    ColorScheme scheme,
    Widget spineCover,
    _ProgressSummary? summary,
  ) {
    final double? fraction = summary?.fraction;
    return <Widget>[
      spineCover,
      _verticalSpineShade,
      if (fraction != null) _shelfProgressBar(fraction),
      _statusBadge(scheme, summary, compact: true),
      _selectionMarks(scheme, compact: true),
    ];
  }

  /// Upright spine outside bookshelf mode: a small rounded bar with a soft
  /// drop shadow.
  Widget _buildVerticalStackTile(
    BuildContext context,
    Widget spineCover,
    _ProgressSummary? summary,
  ) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return DecoratedBox(
      decoration: const BoxDecoration(
        borderRadius: _verticalSpineRadius,
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Color(0x59000000),
            blurRadius: 3,
            offset: Offset(0, 1.5),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: _verticalSpineRadius,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ..._verticalSpineLayers(scheme, spineCover, summary),
            // Ripple sits above everything so it is actually visible.
            Positioned.fill(
              child: Material(
                type: MaterialType.transparency,
                child: InkWell(
                  onTap: widget.onTap,
                  onLongPress: widget.onLongPress,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Upright spine in bookshelf mode: the book stands on the plank drawn by
  /// [_BookshelfPainter] (cell height == book height + plankBelowBook, the
  /// same compartment as the 4-per-row grid).
  Widget _buildShelfVerticalStackTile(
    BuildContext context,
    Widget spineCover,
    _ProgressSummary? summary,
  ) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: _ShelfBook(
            onTap: widget.onTap,
            onLongPress: widget.onLongPress,
            child: Stack(
              fit: StackFit.expand,
              children: _verticalSpineLayers(scheme, spineCover, summary),
            ),
          ),
        ),
        // Space reserved for the visible shelf plank lip in front of the book
        const SizedBox(height: _ShelfDims.plankBelowBook),
      ],
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
      shape: _cardShape(theme.colorScheme),
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
                  _selectionMarks(theme.colorScheme, outline: false),
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
        shape: _cardShape(theme.colorScheme),
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
                  children: [
                    cover,
                    _statusBadge(theme.colorScheme, summary),
                    _selectionMarks(theme.colorScheme, outline: false),
                  ],
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
  static const double plankBehindBook = 9; // surface visible behind a book
  static const double plankInFrontOfBook = 5; // surface in front of a book
  static const double plankSurface = plankBehindBook + plankInFrontOfBook;
  static const double plankFace = 17;
  static const double plankHeight = plankSurface + plankFace;
  static const double plankBelowBook = plankInFrontOfBook + plankFace;
  static const double castShadow = 40; // shadow the plank throws on the wall
  static const double wallBoardWidth = 72;
  static const double wallSideShadow = 46; // shadow side walls cast on back

  // Grid cells: cover (aspect) + plank.
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

  // Stack mode: one horizontal spine per row. In bookshelf mode the spines
  // touch (no gap) and form a pile that rests on the bottom plank.
  static const double stackShelfRowHeight = 52;
  static const double stackGap = 4; // gap between spines off the shelf
  static const double stackRowHeight = 50 + stackGap;

  // Bookcase frame: 3 dp outer setback so the top crown cap overhangs like a
  // real cornice, 12 dp front stile flush with plank front faces, plus 14 dp
  // recessed inner side wall matching plankSurface for a 45-degree 3D miter.
  static const double sideInset = 3;
  static const double sideFrontWidth = 12;
  static const double sideWallDepth = plankSurface; // 14 dp
  static const double sideTotalWidth =
      sideInset + sideFrontWidth + sideWallDepth; // 29 dp
  static const double sideShadow = 14; // shadow front stile throws on side wall
  static const double uprightTile = 360; // height of one cached grain tile

  // Uppermost plank / stepped crown cornice above row 0 (content space).
  static const double crownCap = 7; // overhanging top cap lip
  static const double crownCove = 7; // tapered cove molding under the cap
  static const double crownFrieze = 20; // main upper header board
  static const double crownHeight = crownCap + crownCove + crownFrieze; // 34 dp
  static const double crownCastShadow = 38; // shadow onto the top compartment
  static const double crownClearance = 16; // crown bottom -> first book top

  // Lowermost plank / solid apron plinth & feet below the bottom shelf.
  static const double baseApron = 22; // solid baseboard rail below bottom shelf
  static const double baseFootHeight = 10; // side stiles extending down as feet
  static const double baseExtraHeight = baseApron + baseFootHeight; // 32 dp
  static const double baseTotalHeight = plankHeight + baseExtraHeight; // 63 dp
  static const double floorMargin = 8; // floor strip below feet on short shelves

  // Clearances the layouts use so covers never touch the frame.
  static const double shelfTopInset = crownHeight + crownClearance;
  static const double shelfSideGutter = 7; // plank lip beside the outer books
  static const double shelfSidePadding = sideTotalWidth + shelfSideGutter;
  static const double shelfBottomPadding =
      plankBelowBook + baseExtraHeight + 36; // 90 dp (clears base + FAB)
  static const double listTopInset = shelfTopInset - listTopGap;
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

  factory _LibraryLayout.grid(
      double width, {
        required bool bookshelf,
        int columns = 0,
      }) {
    const double maxCrossAxisExtent = 190;
    final bool auto = columns < 2;
    final int fixedCount = columns.clamp(2, 6).toInt();
    final double crossAxisSpacing = auto
        ? 16
        : (fixedCount >= 5 ? 8 : (fixedCount == 4 ? 12 : 16));
    final double mainAxisSpacing = bookshelf ? 14 : 16;
    final EdgeInsets padding = bookshelf
        ? const EdgeInsets.fromLTRB(
      _ShelfDims.shelfSidePadding,
      _ShelfDims.shelfTopInset,
      _ShelfDims.shelfSidePadding,
      _ShelfDims.shelfBottomPadding,
    )
        : const EdgeInsets.fromLTRB(16, 16, 16, 96);

    final double usable = math.max(0.0, width - padding.horizontal);
    final int count = auto
        ? math.max(1, (usable / (maxCrossAxisExtent + crossAxisSpacing)).ceil())
        : fixedCount;
    final double cellWidth =
        math.max(0.0, usable - crossAxisSpacing * (count - 1)) / count;

    final double coverHeight = cellWidth * _ShelfDims.gridCoverAspect;
    final double cellHeight = bookshelf
        ? coverHeight + _ShelfDims.gridBelowCover
        : cellWidth / 0.54;

    return _LibraryLayout(
      padding: padding,
      cellHeight: cellHeight,
      bookBottom: bookshelf
          ? cellHeight - _ShelfDims.plankBelowBook
          : cellHeight,
      crossAxisCount: count,
      cellWidth: cellWidth,
      crossAxisSpacing: crossAxisSpacing,
      mainAxisSpacing: mainAxisSpacing,
    );
  }

  factory _LibraryLayout.list({required bool bookshelf}) {
    if (bookshelf) {
      return const _LibraryLayout(
        padding: EdgeInsets.fromLTRB(
          _ShelfDims.shelfSidePadding,
          _ShelfDims.listTopInset,
          _ShelfDims.shelfSidePadding,
          _ShelfDims.shelfBottomPadding,
        ),
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

  /// Upright spines on shelves. The shelf (padding, row height, plank spacing,
  /// where the books touch the plank) is exactly the 4-comics-per-row grid's;
  /// only the number of books per row changes: as many ~38 dp spines as fit.
  factory _LibraryLayout.verticalStack(
    double width, {
    required bool bookshelf,
  }) {
    final _LibraryLayout ref4 = _LibraryLayout.grid(
      width,
      bookshelf: bookshelf,
      columns: 4,
    );

    const double targetSpineWidth = 38.0;
    const double spineSpacing = 2.0;
    final double usable = math.max(0.0, width - ref4.padding.horizontal);
    final int crossAxisCount = math.max(
      1,
      ((usable + spineSpacing) / (targetSpineWidth + spineSpacing)).floor(),
    );
    final double cellWidth =
        math.max(0.0, usable - spineSpacing * (crossAxisCount - 1)) /
        crossAxisCount;

    return _LibraryLayout(
      padding: ref4.padding,
      cellHeight: ref4.cellHeight,
      bookBottom: ref4.bookBottom,
      crossAxisCount: crossAxisCount,
      cellWidth: cellWidth,
      crossAxisSpacing: spineSpacing,
      mainAxisSpacing: ref4.mainAxisSpacing,
    );
  }

  /// One spine per row. On a shelf the rows touch, so the last row's bottom
  /// (== [bookBottom] of that row) is where the pile meets the bottom plank.
  factory _LibraryLayout.stack({required bool bookshelf}) {
    if (bookshelf) {
      return const _LibraryLayout(
        padding: EdgeInsets.fromLTRB(
          _ShelfDims.shelfSidePadding,
          _ShelfDims.shelfTopInset,
          _ShelfDims.shelfSidePadding,
          _ShelfDims.shelfBottomPadding,
        ),
        cellHeight: _ShelfDims.stackShelfRowHeight,
        bookBottom: _ShelfDims.stackShelfRowHeight,
      );
    }
    return const _LibraryLayout(
      padding: EdgeInsets.fromLTRB(12, 8, 12, 96),
      cellHeight: _ShelfDims.stackRowHeight,
      bookBottom: _ShelfDims.stackRowHeight,
    );
  }
}

/// Colors for the shelf. Two fixed palettes (identity-comparable so the
/// painter can cheaply decide when to repaint).
class _ShelfPalette {
  const _ShelfPalette({
    required this.surround,
    required this.floor,
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

  final Color surround;
  final Color floor;
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

  /// Dark walnut with a lifted backing panel so downward plank shadows and
  /// inward side-wall shadows read with strong 3D depth.
  static const _ShelfPalette dark = _ShelfPalette(
    surround: Color(0xFF140E0A),
    floor: Color(0xFF1A120D),
    wall: Color(0xFF2B1D14),
    wallSeam: Color(0x4D000000),
    wallSeamLight: Color(0x0AFFFFFF),
    surfaceBack: Color(0xFF2E1C10),
    surfaceFront: Color(0xFF563822),
    faceTop: Color(0xFF6B472C),
    faceBottom: Color(0xFF3A2413),
    highlight: Color(0xFFA67952),
    grainDark: Color(0x521A0C04),
    grainLight: Color(0x24FFD9A8),
  );

  /// Lighter oak for light themes.
  static const _ShelfPalette light = _ShelfPalette(
    surround: Color(0xFFE8E2DA),
    floor: Color(0xFFDFD7CD),
    wall: Color(0xFFD5C7B6),
    wallSeam: Color(0x2E000000),
    wallSeamLight: Color(0x2EFFFFFF),
    surfaceBack: Color(0xFF946B43),
    surfaceFront: Color(0xFFC49868),
    faceTop: Color(0xFFCCA070),
    faceBottom: Color(0xFF96693E),
    highlight: Color(0xFFF2DCBA),
    grainDark: Color(0x40502C10),
    grainLight: Color(0x38FFF0D0),
  );
}

class _ShelfBackdrop extends StatelessWidget {
  const _ShelfBackdrop({
    required this.scroll,
    required this.palette,
    required this.rowCount,
    required this.topInset,
    required this.rowStride,
    required this.bookBottom,
    this.drawIntermediateShelves = true,
  });

  final ScrollController scroll;
  final _ShelfPalette palette;
  final int rowCount;
  final double topInset;
  final double rowStride;
  final double bookBottom;

  /// `false` in stack mode: the books form one pile on the bottom plank, so
  /// no plank is drawn between rows (back wall, uprights, crown and base
  /// still are).
  final bool drawIntermediateShelves;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        // Layer 1: static back panel & board seams.
        RepaintBoundary(
          child: CustomPaint(
            isComplex: true,
            painter: _ShelfWallPainter(palette: palette),
          ),
        ),
        // Layer 2: uprights, crown, planks, and lowermost base plinth.
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
              drawIntermediateShelves: drawIntermediateShelves,
            ),
          ),
        ),
      ],
    );
  }
}

/// Static back panel of the bookcase. Viewport-fixed, so it never listens to
/// the scroll controller; it repaints only when the size or palette changes.
class _ShelfWallPainter extends CustomPainter {
  const _ShelfWallPainter({required this.palette});

  final _ShelfPalette palette;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = palette.surround);

    final double wallLeft = _ShelfDims.sideTotalWidth;
    final double wallRight = math.max(wallLeft, size.width - wallLeft);
    canvas.drawRect(
      Rect.fromLTRB(wallLeft, 0, wallRight, size.height),
      Paint()..color = palette.wall,
    );

    // Subtle vertical back-board seams inside the compartment area.
    final Paint seam = Paint()
      ..color = palette.wallSeam
      ..strokeWidth = 1;
    final Paint seamLight = Paint()
      ..color = palette.wallSeamLight
      ..strokeWidth = 1;
    for (
    double x = wallLeft + _ShelfDims.wallBoardWidth;
    x < wallRight;
    x += _ShelfDims.wallBoardWidth
    ) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), seam);
      canvas.drawLine(Offset(x + 1, 0), Offset(x + 1, size.height), seamLight);
    }

    // Inward side-wall shadows onto the back panel.
    _PlankKit.obtain(palette, size.width).paintWallSideShadows(canvas, size);
  }

  @override
  bool shouldRepaint(covariant _ShelfWallPainter old) => old.palette != palette;
}

class _BookshelfPainter extends CustomPainter {
  _BookshelfPainter({
    required this.scroll,
    required this.palette,
    required this.rowCount,
    required this.topInset,
    required this.rowStride,
    required this.bookBottom,
    this.fillEmptyShelves = true,
    this.drawIntermediateShelves = true,
  }) : super(repaint: scroll);

  final ScrollController scroll;
  final _ShelfPalette palette;
  final int rowCount;
  final double topInset;
  final double rowStride;
  final double bookBottom;
  final bool fillEmptyShelves;

  /// When `false` (stack mode) only the bottom plank is drawn under the books.
  final bool drawIntermediateShelves;

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

    // Where the lowermost plank & base plinth sit in content space:
    // - On a short library, docked cleanly at the bottom of the screen with
    //   empty shelves filling the space above it.
    // - On a tall library, anchored directly under the final row of comics.
    final int lastContentRow = math.max(0, rowCount - 1);
    final double lastContentShelfTop = firstTop + lastContentRow * rowStride;
    final double viewportBaseTop =
        size.height - _ShelfDims.baseTotalHeight - _ShelfDims.floorMargin;
    // A pile rests on its own bottom plank, so it never docks to the screen
    // bottom (that would leave the books floating above the plank).
    final bool dockBaseToBottom =
        fillEmptyShelves &&
        drawIntermediateShelves &&
        lastContentShelfTop < viewportBaseTop;
    final double basePlankTop =
    dockBaseToBottom ? viewportBaseTop : lastContentShelfTop;

    final double crownTop = -offset;
    final double baseScreenTop = basePlankTop - offset;
    final double bookcaseTop = math.max(
      0.0,
      crownTop + _ShelfDims.crownCap + _ShelfDims.crownCove,
    );
    final double bookcaseBottom = math.min(
      size.height,
      baseScreenTop + _ShelfDims.baseTotalHeight,
    );

    // Mask overscroll above the crown or space below the bookcase feet.
    if (crownTop > 0) {
      kit.paintSurroundBand(canvas, 0.0, crownTop);
    }
    if (baseScreenTop + _ShelfDims.baseTotalHeight < size.height) {
      kit.paintFloorArea(
        canvas,
        math.max(0.0, baseScreenTop + _ShelfDims.baseTotalHeight),
        size.height,
      );
    }

    // Side uprights spanning cleanly between the crown and the base feet.
    kit.paintUprights(
      canvas,
      size.width,
      top: bookcaseTop,
      bottom: bookcaseBottom,
    );

    // Intermediate shelves (skipped in stack mode: the books are one pile).
    if (drawIntermediateShelves) {
      int first = ((offset - firstTop - reach) / rowStride).floor();
      int last = ((offset + size.height - firstTop) / rowStride).ceil();
      first = math.max(first, 0);
      if (!fillEmptyShelves) last = math.min(last, rowCount - 1);

      for (int i = first; i <= last; i++) {
        final double shelfContentTop = firstTop + i * rowStride;
        // Stop before the lowermost plank so it never collides with an empty shelf.
        if (shelfContentTop >= basePlankTop - 24) break;
        kit.paint(canvas, shelfContentTop - offset, i);
      }
    }

    // Lowermost plank + apron plinth + side feet.
    if (baseScreenTop < size.height &&
        baseScreenTop + _ShelfDims.baseTotalHeight > 0) {
      kit.paintBase(
        canvas,
        baseScreenTop,
        dockBaseToBottom ? 99 : lastContentRow,
      );
    }

    // Uppermost plank / stepped crown cornice.
    if (crownTop + _ShelfDims.crownHeight + _ShelfDims.crownCastShadow > 0) {
      kit.paintCrown(canvas, crownTop);
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
        old.fillEmptyShelves != fillEmptyShelves ||
        old.drawIntermediateShelves != drawIntermediateShelves;
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

/// Precomputed shaders, geometry paths, and wood-grain strokes for the bookcase.
/// Built once per (palette, width) pair so scrolling allocates zero objects.
class _PlankKit {
  _PlankKit._(this.palette, this.width)
      : frontLeft = _ShelfDims.sideInset + _ShelfDims.sideFrontWidth,
        backLeft = _ShelfDims.sideTotalWidth,
        frontWidth = math.max(
          8.0,
          width - 2 * (_ShelfDims.sideInset + _ShelfDims.sideFrontWidth),
        ),
        backWidth = math.max(8.0, width - 2 * _ShelfDims.sideTotalWidth),
        hasRoom = width - 2 * _ShelfDims.sideTotalWidth > 8 {
    const double surfaceH = _ShelfDims.plankSurface;
    const double faceH = _ShelfDims.plankFace;
    const double depth = _ShelfDims.sideWallDepth;
    final double fw = frontWidth;

    // Local coordinates where x = 0 is the inner edge of the left front stile
    // and x = fw is the inner edge of the right front stile.
    surfaceRect = Rect.fromLTWH(0, 0, fw, surfaceH);
    faceRect = Rect.fromLTWH(0, surfaceH, fw, faceH);
    wholeRect = Rect.fromLTWH(0, 0, fw, surfaceH + faceH);

    // Trapezoidal flat shelf surface: recedes inward by [depth] at y = 0 so
    // it meets the angled inner side walls at a true 45-degree 3D miter.
    surfacePath = Path()
      ..moveTo(depth, 0)
      ..lineTo(fw - depth, 0)
      ..lineTo(fw, surfaceH)
      ..lineTo(0, surfaceH)
      ..close();

    // Downward cast shadow on the back panel (between the rear corners).
    shadowRect = Rect.fromLTWH(
      depth,
      surfaceH + faceH,
      backWidth,
      _ShelfDims.castShadow,
    );

    // Side-wall cast shadows right below where each shelf joins the uprights.
    sideJointShadowLeft = Path()
      ..moveTo(0, surfaceH + faceH)
      ..lineTo(depth, surfaceH + faceH)
      ..lineTo(depth, surfaceH + faceH + _ShelfDims.castShadow * 0.72)
      ..lineTo(0, surfaceH + faceH + _ShelfDims.castShadow * 0.35)
      ..close();
    sideJointShadowRight = Path()
      ..moveTo(fw - depth, surfaceH + faceH)
      ..lineTo(fw, surfaceH + faceH)
      ..lineTo(fw, surfaceH + faceH + _ShelfDims.castShadow * 0.35)
      ..lineTo(fw - depth, surfaceH + faceH + _ShelfDims.castShadow * 0.72)
      ..close();

    occlusionRect = Rect.fromLTWH(0, 0, fw, surfaceH);
    surfaceSideShadowRect = Rect.fromLTWH(0, 0, fw, surfaceH);
    highlightRect = Rect.fromLTWH(0, surfaceH, fw, 1.5);
    edgeRect = Rect.fromLTWH(0, surfaceH + faceH - 2, fw, 2);
    sheenRect = Rect.fromLTWH(0, surfaceH + 3, fw, 3);

    // 1. Deep cast shadow thrown onto the back panel beneath the plank.
    shadowPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.black.withAlpha(215),
          Colors.black.withAlpha(115),
          Colors.black.withAlpha(35),
          Colors.black.withAlpha(0),
        ],
        stops: const [0.0, 0.32, 0.68, 1.0],
      ).createShader(shadowRect);

    sideJointShadowPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.black.withAlpha(185),
          Colors.black.withAlpha(55),
          Colors.black.withAlpha(0),
        ],
        stops: const [0.0, 0.5, 1.0],
      ).createShader(
        Rect.fromLTWH(0, surfaceH + faceH, fw, _ShelfDims.castShadow * 0.75),
      );

    // 2. Flat top surface base wood (darkened in the back where books sit).
    surfacePaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [palette.surfaceBack, palette.surfaceFront],
      ).createShader(surfaceRect);

    // Full-depth ambient occlusion across the flat shelf surface.
    occlusionPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.black.withAlpha(180),
          Colors.black.withAlpha(85),
          Colors.black.withAlpha(15),
        ],
        stops: const [0.0, 0.55, 1.0],
      ).createShader(occlusionRect);

    // Side-wall shadow falling onto the left/right ends of the shelf surface.
    surfaceSideShadowPaint = Paint()
      ..shader = LinearGradient(
        colors: [
          Colors.black.withAlpha(155),
          Colors.black.withAlpha(45),
          Colors.black.withAlpha(0),
          Colors.black.withAlpha(0),
          Colors.black.withAlpha(45),
          Colors.black.withAlpha(155),
        ],
        stops: const [0.0, 0.05, 0.14, 0.86, 0.95, 1.0],
      ).createShader(surfaceSideShadowRect);

    // 3. Front vertical face, crisp top bevel highlight, and bottom edge.
    facePaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [palette.faceTop, palette.faceBottom],
      ).createShader(faceRect);
    highlightPaint = Paint()..color = palette.highlight;
    edgePaint = Paint()..color = Colors.black.withAlpha(165);

    // 4. Soft specular sheen along the front lip.
    sheenPaint = Paint()
      ..shader = LinearGradient(
        colors: [
          Colors.white.withAlpha(0),
          Colors.white.withAlpha(42),
          Colors.white.withAlpha(0),
        ],
        stops: const [0.0, 0.5, 1.0],
      ).createShader(sheenRect);

    // 5. Subtle corner darkening where the front face meets the front stiles.
    endsPaint = Paint()
      ..shader = LinearGradient(
        colors: [
          Colors.black.withAlpha(85),
          Colors.black.withAlpha(0),
          Colors.black.withAlpha(0),
          Colors.black.withAlpha(85),
        ],
        stops: const [0.0, 0.03, 0.97, 1.0],
      ).createShader(faceRect);

    surroundPaint = Paint()..color = palette.surround;
    floorPaint = Paint()..color = palette.floor;

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
        _buildGrain(surfaceRect, rnd, math.max(8, (fw / 26).round())),
        _buildGrain(faceRect, rnd, math.max(10, (fw / 16).round())),
      );
    }, growable: false);

    _buildUprights();
    _buildCrown();
    _buildBase();
  }

  /// Front faces start at [frontLeft] (inner edge of the front stile); rear
  /// edges start at [backLeft] (where the recessed side wall meets the back).
  final double frontLeft;
  final double backLeft;
  final double frontWidth;
  final double backWidth;
  final bool hasRoom;

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
  late final Rect surfaceSideShadowRect;
  late final Rect highlightRect;
  late final Rect edgeRect;
  late final Rect sheenRect;
  late final Path surfacePath;
  late final Path sideJointShadowLeft;
  late final Path sideJointShadowRight;

  late final Paint shadowPaint;
  late final Paint sideJointShadowPaint;
  late final Paint surfacePaint;
  late final Paint occlusionPaint;
  late final Paint surfaceSideShadowPaint;
  late final Paint facePaint;
  late final Paint highlightPaint;
  late final Paint edgePaint;
  late final Paint sheenPaint;
  late final Paint endsPaint;
  late final Paint surroundPaint;
  late final Paint floorPaint;
  late final Paint grainDarkPaint;
  late final Paint grainLightPaint;

  late final List<_PlankGrain> grains;

  // --- side uprights & back-wall side shadows ------------------------------
  late final Rect stileRect;
  late final Rect stripRect;
  late final Rect stileShadowRect;
  late final Rect stripSeamRect;
  late final Rect stileBevelRect;
  late final Rect stileEdgeRect;
  late final Rect stileSheenRect;
  late final Rect wallSideShadowRect;
  late final Paint stilePaint;
  late final Paint stripPaint;
  late final Paint stileShadowPaint;
  late final Paint stripSeamPaint;
  late final Paint stileSheenPaint;
  late final Paint wallSideShadowPaint;
  late final _GrainPaths stileGrain;
  late final _GrainPaths stripGrain;

  // --- uppermost plank / stepped crown cornice -----------------------------
  late final Rect crownCapRect;
  late final Rect crownCapHighlightRect;
  late final Rect crownCapUnderShadowRect;
  late final Rect crownCoveBounds;
  late final Path crownCovePath;
  late final Rect crownFriezeRect;
  late final Rect crownFriezeTopShadowRect;
  late final Rect crownBeadRect;
  late final Rect crownEdgeRect;
  late final Rect crownShadowRect;
  late final Path crownSideShadowLeft;
  late final Path crownSideShadowRight;
  late final Paint crownCapPaint;
  late final Paint crownCapUnderShadowPaint;
  late final Paint crownCovePaint;
  late final Paint crownFriezePaint;
  late final Paint crownFriezeTopShadowPaint;
  late final Paint crownEndsPaint;
  late final Paint crownShadowPaint;
  late final Paint crownSideShadowPaint;
  late final Paint crownJointPaint;
  late final Paint crownJointLightPaint;
  late final Path crownJoints;
  late final Path crownJointsLight;
  late final _GrainPaths crownCapGrain;
  late final _GrainPaths crownFriezeGrain;

  // --- lowermost plank / base plinth & feet --------------------------------
  late final Rect baseApronRect;
  late final Rect baseApronTopShadowRect;
  late final Rect baseApronBottomEdgeRect;
  late final Rect baseKickVoidRect;
  late final Rect baseFloorShadowRect;
  late final Paint baseApronPaint;
  late final Paint baseApronTopShadowPaint;
  late final Paint baseApronEndsPaint;
  late final Paint baseKickVoidPaint;
  late final Paint baseFloorShadowPaint;
  late final _GrainPaths baseApronGrain;

  static _GrainPaths _buildGrain(Rect r, math.Random rnd, int count) {
    const double inset = 1.2;
    final double usableHeight = math.max(r.height - 2 * inset, 0.0);
    final Path dark = Path();
    final Path light = Path();
    for (int k = 0; k < count; k++) {
      final double y = r.top + inset + rnd.nextDouble() * usableHeight;
      final double length = math.min(
        50 + rnd.nextDouble() * r.width * 0.5,
        r.width,
      );
      final double x0 =
          r.left + rnd.nextDouble() * math.max(r.width - length, 0.0);
      final double drift = (rnd.nextDouble() - 0.5) * 2.5;
      final Path target = k.isEven ? dark : light;
      target.moveTo(x0, y);
      target.quadraticBezierTo(x0 + length / 2, y + drift, x0 + length, y);
    }
    return _GrainPaths(dark, light);
  }

  static _GrainPaths _buildVerticalGrain(Rect r, math.Random rnd, int count) {
    const double inset = 1.0;
    final double usableWidth = math.max(r.width - 2 * inset, 0.0);
    final Path dark = Path();
    final Path light = Path();
    for (int k = 0; k < count; k++) {
      final double x = r.left + inset + rnd.nextDouble() * usableWidth;
      final double length = math.min(
        60 + rnd.nextDouble() * r.height * 0.5,
        r.height,
      );
      final double y0 =
          r.top + rnd.nextDouble() * math.max(r.height - length, 0.0);
      final double drift = (rnd.nextDouble() - 0.5) * 1.6;
      final Path target = k.isEven ? dark : light;
      target.moveTo(x, y0);
      target.quadraticBezierTo(x + drift, y0 + length / 2, x, y0 + length);
    }
    return _GrainPaths(dark, light);
  }

  void _buildUprights() {
    const double inset = _ShelfDims.sideInset;
    const double front = _ShelfDims.sideFrontWidth;
    const double depth = _ShelfDims.sideWallDepth;
    const double total = _ShelfDims.sideTotalWidth;
    const double tile = _ShelfDims.uprightTile;

    stileRect = Rect.fromLTWH(inset, 0, front, tile);
    stripRect = Rect.fromLTWH(inset + front, 0, depth, tile);
    stileShadowRect = Rect.fromLTWH(
      inset + front,
      0,
      _ShelfDims.sideShadow,
      tile,
    );
    stripSeamRect = Rect.fromLTWH(total - 1, 0, 1, tile);
    stileBevelRect = Rect.fromLTWH(inset + front - 1.5, 0, 1.5, tile);
    stileEdgeRect = Rect.fromLTWH(inset, 0, 1.2, tile);
    stileSheenRect = Rect.fromLTWH(inset + 3, 0, 3.5, tile);
    wallSideShadowRect = Rect.fromLTWH(
      total,
      0,
      _ShelfDims.wallSideShadow,
      tile,
    );

    // Recessed inner side wall: lit near the front stile, deep shadow at back.
    stripPaint = Paint()
      ..shader = LinearGradient(
        colors: [
          Color.lerp(palette.surfaceFront, Colors.black, 0.15)!,
          Color.lerp(palette.surfaceBack, Colors.black, 0.55)!,
        ],
      ).createShader(stripRect);
    stripSeamPaint = Paint()..color = Colors.black.withAlpha(160);

    // Shadow cast onto the back panel by the left and right bookcase walls.
    wallSideShadowPaint = Paint()
      ..shader = LinearGradient(
        colors: [
          Colors.black.withAlpha(175),
          Colors.black.withAlpha(80),
          Colors.black.withAlpha(20),
          Colors.black.withAlpha(0),
        ],
        stops: const [0.0, 0.35, 0.72, 1.0],
      ).createShader(wallSideShadowRect);

    stileShadowPaint = Paint()
      ..shader = LinearGradient(
        colors: [
          Colors.black.withAlpha(160),
          Colors.black.withAlpha(55),
          Colors.black.withAlpha(0),
        ],
        stops: const [0.0, 0.45, 1.0],
      ).createShader(stileShadowRect);

    stilePaint = Paint()
      ..shader = LinearGradient(
        colors: [palette.faceBottom, palette.faceTop, palette.surfaceFront],
        stops: const [0.0, 0.45, 1.0],
      ).createShader(stileRect);
    stileSheenPaint = Paint()
      ..shader = LinearGradient(
        colors: [
          Colors.white.withAlpha(0),
          Colors.white.withAlpha(46),
          Colors.white.withAlpha(0),
        ],
        stops: const [0.0, 0.5, 1.0],
      ).createShader(stileSheenRect);

    final math.Random rnd = math.Random(60013);
    stileGrain = _buildVerticalGrain(stileRect, rnd, 16);
    stripGrain = _buildVerticalGrain(stripRect, rnd, 10);
  }

  void _buildCrown() {
    const double capH = _ShelfDims.crownCap;
    const double coveH = _ShelfDims.crownCove;
    const double friezeH = _ShelfDims.crownFrieze;
    const double h = _ShelfDims.crownHeight;
    const double inset = _ShelfDims.sideInset;
    const double front = _ShelfDims.sideFrontWidth;
    const double depth = _ShelfDims.sideWallDepth;
    final double w = width;
    final double stileInnerL = inset + front;
    final double stileInnerR = w - inset - front;

    // 1. Overhanging top cap lip (full width).
    crownCapRect = Rect.fromLTWH(0, 0, w, capH);
    crownCapHighlightRect = Rect.fromLTWH(0, 0, w, 1.5);
    crownCapUnderShadowRect = Rect.fromLTWH(0, capH - 1.5, w, 1.5);

    // 2. Tapered cove molding stepping inward from cap to header board.
    crownCoveBounds = Rect.fromLTWH(0, capH, w, coveH);
    crownCovePath = Path()
      ..moveTo(0, capH)
      ..lineTo(w, capH)
      ..lineTo(w - inset, capH + coveH)
      ..lineTo(inset, capH + coveH)
      ..close();

    // 3. Upper header board / frieze spanning between the outer stile edges.
    crownFriezeRect = Rect.fromLTWH(
      inset,
      capH + coveH,
      math.max(w - 2 * inset, 1.0),
      friezeH,
    );
    crownFriezeTopShadowRect = Rect.fromLTWH(
      inset,
      capH + coveH,
      math.max(w - 2 * inset, 1.0),
      4.0,
    );
    crownBeadRect = Rect.fromLTWH(
      inset,
      h - 3.0,
      math.max(w - 2 * inset, 1.0),
      1.2,
    );
    crownEdgeRect = Rect.fromLTWH(
      inset,
      h - 1.8,
      math.max(w - 2 * inset, 1.0),
      1.8,
    );

    // 4. Cast shadows into the top compartment (back wall + recessed side walls).
    crownShadowRect = Rect.fromLTWH(
      backLeft,
      h,
      backWidth,
      _ShelfDims.crownCastShadow,
    );
    crownSideShadowLeft = Path()
      ..moveTo(stileInnerL, h)
      ..lineTo(stileInnerL + depth, h)
      ..lineTo(stileInnerL + depth, h + _ShelfDims.crownCastShadow * 0.72)
      ..lineTo(stileInnerL, h + _ShelfDims.crownCastShadow * 0.35)
      ..close();
    crownSideShadowRight = Path()
      ..moveTo(stileInnerR - depth, h)
      ..lineTo(stileInnerR, h)
      ..lineTo(stileInnerR, h + _ShelfDims.crownCastShadow * 0.35)
      ..lineTo(stileInnerR - depth, h + _ShelfDims.crownCastShadow * 0.72)
      ..close();

    crownCapPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Color.lerp(palette.faceTop, palette.highlight, 0.25)!,
          palette.faceTop,
        ],
      ).createShader(crownCapRect);
    crownCapUnderShadowPaint = Paint()..color = Colors.black.withAlpha(185);

    crownCovePaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Color.lerp(palette.faceBottom, Colors.black, 0.38)!,
          Color.lerp(palette.faceBottom, palette.faceTop, 0.35)!,
        ],
      ).createShader(crownCoveBounds);

    crownFriezePaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [palette.faceTop, palette.faceBottom],
      ).createShader(crownFriezeRect);
    crownFriezeTopShadowPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Colors.black.withAlpha(115), Colors.black.withAlpha(0)],
      ).createShader(crownFriezeTopShadowRect);

    crownEndsPaint = Paint()
      ..shader = LinearGradient(
        colors: [
          Colors.black.withAlpha(80),
          Colors.black.withAlpha(0),
          Colors.black.withAlpha(0),
          Colors.black.withAlpha(80),
        ],
        stops: const [0.0, 0.03, 0.97, 1.0],
      ).createShader(crownFriezeRect);

    crownShadowPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.black.withAlpha(215),
          Colors.black.withAlpha(105),
          Colors.black.withAlpha(0),
        ],
        stops: const [0.0, 0.42, 1.0],
      ).createShader(crownShadowRect);
    crownSideShadowPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.black.withAlpha(185),
          Colors.black.withAlpha(55),
          Colors.black.withAlpha(0),
        ],
        stops: const [0.0, 0.5, 1.0],
      ).createShader(
        Rect.fromLTWH(0, h, w, _ShelfDims.crownCastShadow * 0.75),
      );

    // Subtle vertical cabinetry joinery seams where the stiles meet the header.
    crownJointPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = Colors.black.withAlpha(110);
    crownJointLightPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = Colors.white.withAlpha(26);
    crownJoints = Path()
      ..moveTo(stileInnerL, capH + coveH)
      ..lineTo(stileInnerL, h)
      ..moveTo(stileInnerR, capH + coveH)
      ..lineTo(stileInnerR, h);
    crownJointsLight = crownJoints.shift(const Offset(1.0, 0.0));

    final math.Random rnd = math.Random(4242);
    crownCapGrain = _buildGrain(
      crownCapRect,
      rnd,
      math.max(6, (w / 44).round()),
    );
    crownFriezeGrain = _buildGrain(
      crownFriezeRect,
      rnd,
      math.max(10, (w / 14).round()),
    );
  }

  void _buildBase() {
    const double plankH = _ShelfDims.plankHeight;
    const double apronH = _ShelfDims.baseApron;
    const double footH = _ShelfDims.baseFootHeight;
    const double totalH = _ShelfDims.baseTotalHeight;
    final double fw = frontWidth;

    // Local coordinates where x = 0 is the inner edge of the left front stile
    // and x = fw is the inner edge of the right front stile.
    baseApronRect = Rect.fromLTWH(0, plankH, fw, apronH);
    baseApronTopShadowRect = Rect.fromLTWH(0, plankH, fw, 6.0);
    baseApronBottomEdgeRect = Rect.fromLTWH(0, plankH + apronH - 1.5, fw, 1.5);
    baseKickVoidRect = Rect.fromLTWH(0, plankH + apronH, fw, footH);
    baseFloorShadowRect = Rect.fromLTWH(
      -_ShelfDims.sideFrontWidth,
      totalH - 1.0,
      fw + 2 * _ShelfDims.sideFrontWidth,
      6.0,
    );

    baseApronPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [palette.faceTop, palette.faceBottom],
      ).createShader(baseApronRect);
    baseApronTopShadowPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Colors.black.withAlpha(155), Colors.black.withAlpha(0)],
      ).createShader(baseApronTopShadowRect);
    baseApronEndsPaint = Paint()
      ..shader = LinearGradient(
        colors: [
          Colors.black.withAlpha(90),
          Colors.black.withAlpha(0),
          Colors.black.withAlpha(0),
          Colors.black.withAlpha(90),
        ],
        stops: const [0.0, 0.03, 0.97, 1.0],
      ).createShader(baseApronRect);

    baseKickVoidPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.black.withAlpha(210),
          Colors.black.withAlpha(135),
          Colors.black.withAlpha(70),
        ],
        stops: const [0.0, 0.55, 1.0],
      ).createShader(baseKickVoidRect);
    baseFloorShadowPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Colors.black.withAlpha(150), Colors.black.withAlpha(0)],
      ).createShader(baseFloorShadowRect);

    final math.Random rnd = math.Random(9001);
    baseApronGrain = _buildGrain(
      baseApronRect,
      rnd,
      math.max(10, (fw / 15).round()),
    );
  }

  void paintWallSideShadows(Canvas canvas, Size size) {
    canvas.drawRect(
      Rect.fromLTRB(
        wallSideShadowRect.left,
        0,
        wallSideShadowRect.right,
        size.height,
      ),
      wallSideShadowPaint,
    );
    canvas.save();
    canvas.translate(size.width, 0.0);
    canvas.scale(-1.0, 1.0);
    canvas.drawRect(
      Rect.fromLTRB(
        wallSideShadowRect.left,
        0,
        wallSideShadowRect.right,
        size.height,
      ),
      wallSideShadowPaint,
    );
    canvas.restore();
  }

  void paintSurroundBand(Canvas canvas, double top, double bottom) {
    if (bottom <= top) return;
    canvas.drawRect(Rect.fromLTRB(0, top, width, bottom), surroundPaint);
  }

  void paintFloorArea(Canvas canvas, double top, double bottom) {
    if (bottom <= top) return;
    canvas.drawRect(Rect.fromLTRB(0, top, width, bottom), floorPaint);
  }

  void paintUprights(
      Canvas canvas,
      double viewportWidth, {
        required double top,
        required double bottom,
      }) {
    if (bottom <= top) return;
    _paintUprightSpan(canvas, top, bottom, 0.0);
    canvas.save();
    canvas.translate(viewportWidth, 0.0);
    canvas.scale(-1.0, 1.0);
    _paintUprightSpan(canvas, top, bottom, 0.43);
    canvas.restore();
  }

  void _paintUprightSpan(
      Canvas canvas,
      double top,
      double bottom,
      double phase,
      ) {
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(0, top, _ShelfDims.sideTotalWidth, bottom));
    canvas.drawRect(
      Rect.fromLTRB(stripRect.left, top, stripRect.right, bottom),
      stripPaint,
    );
    _paintGrainTiles(canvas, top, bottom, phase, stripGrain, withLight: false);
    canvas.drawRect(
      Rect.fromLTRB(stripSeamRect.left, top, stripSeamRect.right, bottom),
      stripSeamPaint,
    );
    canvas.drawRect(
      Rect.fromLTRB(stileShadowRect.left, top, stileShadowRect.right, bottom),
      stileShadowPaint,
    );
    canvas.drawRect(
      Rect.fromLTRB(stileRect.left, top, stileRect.right, bottom),
      stilePaint,
    );
    _paintGrainTiles(canvas, top, bottom, phase, stileGrain, withLight: true);
    canvas.drawRect(
      Rect.fromLTRB(stileSheenRect.left, top, stileSheenRect.right, bottom),
      stileSheenPaint,
    );
    canvas.drawRect(
      Rect.fromLTRB(stileBevelRect.left, top, stileBevelRect.right, bottom),
      highlightPaint,
    );
    canvas.drawRect(
      Rect.fromLTRB(stileEdgeRect.left, top, stileEdgeRect.right, bottom),
      edgePaint,
    );
    canvas.restore();
  }

  void _paintGrainTiles(
      Canvas canvas,
      double top,
      double bottom,
      double phase,
      _GrainPaths grain, {
        required bool withLight,
      }) {
    const double tile = _ShelfDims.uprightTile;
    final double startY =
        ((top + phase * tile) / tile).floor() * tile - phase * tile;
    for (double y = startY; y < bottom; y += tile) {
      canvas.save();
      canvas.translate(0.0, y);
      canvas.drawPath(grain.dark, grainDarkPaint);
      if (withLight) canvas.drawPath(grain.light, grainLightPaint);
      canvas.restore();
    }
  }

  /// Paints the uppermost plank / stepped crown cornice at [top].
  void paintCrown(Canvas canvas, double top) {
    canvas.save();
    canvas.translate(0.0, top);

    // 1. Cast shadows into the top compartment (back wall + recessed sides).
    canvas.drawRect(crownShadowRect, crownShadowPaint);
    canvas.drawPath(crownSideShadowLeft, crownSideShadowPaint);
    canvas.drawPath(crownSideShadowRight, crownSideShadowPaint);

    // 2. Main upper header board / frieze.
    canvas.drawRect(crownFriezeRect, crownFriezePaint);
    canvas.drawPath(crownFriezeGrain.dark, grainDarkPaint);
    canvas.drawPath(crownFriezeGrain.light, grainLightPaint);
    canvas.drawRect(crownFriezeTopShadowRect, crownFriezeTopShadowPaint);
    canvas.drawPath(crownJoints, crownJointPaint);
    canvas.drawPath(crownJointsLight, crownJointLightPaint);
    canvas.drawRect(crownBeadRect, highlightPaint);
    canvas.drawRect(crownEdgeRect, edgePaint);
    canvas.drawRect(crownFriezeRect, crownEndsPaint);

    // 3. Tapered cove molding tucked under the overhanging top cap.
    canvas.drawPath(crownCovePath, crownCovePaint);

    // 4. Full-width overhanging top cap lip.
    canvas.drawRect(crownCapRect, crownCapPaint);
    canvas.drawPath(crownCapGrain.dark, grainDarkPaint);
    canvas.drawPath(crownCapGrain.light, grainLightPaint);
    canvas.drawRect(crownCapHighlightRect, highlightPaint);
    canvas.drawRect(crownCapUnderShadowRect, crownCapUnderShadowPaint);

    canvas.restore();
  }

  /// Paints the lowermost plank, solid baseboard apron, and side bookcase feet
  /// whose shelf top surface sits at [top].
  void paintBase(Canvas canvas, double top, int index) {
    if (!hasRoom) return;
    final _PlankGrain grain = grains[(index * 5) % _variantCount];
    canvas.save();
    canvas.translate(frontLeft, top);

    // 1. Recessed under-cabinet toe-kick void & floor shadow between the legs.
    canvas.drawRect(baseKickVoidRect, floorPaint);
    canvas.drawRect(baseKickVoidRect, baseKickVoidPaint);
    canvas.drawRect(baseFloorShadowRect, baseFloorShadowPaint);

    // 2. Solid horizontal baseboard / apron plinth between the front stiles.
    canvas.drawRect(baseApronRect, baseApronPaint);
    canvas.drawPath(baseApronGrain.dark, grainDarkPaint);
    canvas.drawPath(baseApronGrain.light, grainLightPaint);
    canvas.drawRect(baseApronTopShadowRect, baseApronTopShadowPaint);
    canvas.drawRect(baseApronBottomEdgeRect, edgePaint);
    canvas.drawRect(baseApronRect, baseApronEndsPaint);

    // 3. Bottom shelf trapezoidal top surface (where the lowest comics sit).
    canvas.save();
    canvas.clipPath(surfacePath);
    canvas.drawRect(surfaceRect, surfacePaint);
    canvas.drawPath(grain.surface.dark, grainDarkPaint);
    canvas.drawPath(grain.surface.light, grainLightPaint);
    canvas.drawRect(occlusionRect, occlusionPaint);
    canvas.drawRect(surfaceSideShadowRect, surfaceSideShadowPaint);
    canvas.restore();

    // 4. Bottom shelf front vertical face.
    canvas.drawRect(faceRect, facePaint);
    canvas.drawPath(grain.face.dark, grainDarkPaint);
    canvas.drawPath(grain.face.light, grainLightPaint);
    canvas.drawRect(highlightRect, highlightPaint);
    canvas.drawRect(edgeRect, edgePaint);
    canvas.drawRect(sheenRect, sheenPaint);
    canvas.drawRect(faceRect, endsPaint);

    canvas.restore();
  }

  /// Draws an intermediate plank whose top edge is at [top].
  void paint(Canvas canvas, double top, int index) {
    if (!hasRoom) return;
    final _PlankGrain grain = grains[(index * 5) % _variantCount];
    canvas.save();
    canvas.translate(frontLeft, top);

    // 1. Cast shadows onto the back panel and recessed side walls.
    canvas.drawRect(shadowRect, shadowPaint);
    canvas.drawPath(sideJointShadowLeft, sideJointShadowPaint);
    canvas.drawPath(sideJointShadowRight, sideJointShadowPaint);

    // 2. Trapezoidal flat top surface with full-depth ambient occlusion.
    canvas.save();
    canvas.clipPath(surfacePath);
    canvas.drawRect(surfaceRect, surfacePaint);
    canvas.drawPath(grain.surface.dark, grainDarkPaint);
    canvas.drawPath(grain.surface.light, grainLightPaint);
    canvas.drawRect(occlusionRect, occlusionPaint);
    canvas.drawRect(surfaceSideShadowRect, surfaceSideShadowPaint);
    canvas.restore();

    // 3. Front vertical face spanning flush between the two front stiles.
    canvas.drawRect(faceRect, facePaint);
    canvas.drawPath(grain.face.dark, grainDarkPaint);
    canvas.drawPath(grain.face.light, grainLightPaint);
    canvas.drawRect(highlightRect, highlightPaint);
    canvas.drawRect(edgeRect, edgePaint);
    canvas.drawRect(sheenRect, sheenPaint);
    canvas.drawRect(faceRect, endsPaint);

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
          // Tight contact shadow where the book rests on the shelf surface
          // (stays within the 5 dp front lip so the front plank face stays crisp).
          BoxShadow(
            color: Color(0xCC000000),
            blurRadius: 3.5,
            spreadRadius: -0.5,
            offset: Offset(0, 1.5),
          ),
          // Recessed depth shadow cast behind and slightly right onto the back wall.
          BoxShadow(
            color: Color(0x66000000),
            blurRadius: 9,
            spreadRadius: -1.5,
            offset: Offset(2.5, -3.5),
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


