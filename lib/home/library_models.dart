import 'dart:math' as math;

import 'package:flutter/painting.dart';

import '../../services/comic_identity.dart';
import '../../services/reading_progress_service.dart';

/// ==========================================
/// Library layout models (view mode, sort, shelf measurements)
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

/// Fixed measurements shared by the layout, the tiles and the painter so the
/// books always land exactly on the planks.
class ShelfDims {
  const ShelfDims._();

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

  // Folder divider plank: a thicker plank (taller top surface and front face
  // than a regular one) that sits directly above a folder's first row and
  // carries the folder's wooden nameplate bump on its front face.
  static const double folderPlankSurface = 22;
  static const double folderPlankFace = 30;
  static const double folderPlankHeight = folderPlankSurface + folderPlankFace;

  // Centered raised nameplate bump on the divider plank's front face.
  static const double folderBumpMaxWidth = 240;
  static const double folderBumpMinWidth = 72;
  static const double folderBumpHeight = 22;
  static const double folderBumpPadding = 14; // horizontal padding around text
  static const double folderBumpRadius = 7;

  // Folder spacing (content space).
  static const double folderFirstTop = crownHeight + 10; // plank under crown
  static const double folderPlankGapAfter = 14; // divider plank -> book tops
  static const double folderSectionGap = 22; // previous plank -> divider plank

  // Bookshelf mode OFF: plain left-aligned text header above a folder.
  static const double folderTextHeaderHeight = 44;
  static const double folderTextSectionGap = 8;
}

/// Everything needed to lay out (and paint shelves for) one library layout.
/// For the list layout, [cellHeight] is the row height and there is one column.
class LibraryLayout {
  const LibraryLayout({
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

  factory LibraryLayout.grid(
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
      ShelfDims.shelfSidePadding,
      ShelfDims.shelfTopInset,
      ShelfDims.shelfSidePadding,
      ShelfDims.shelfBottomPadding,
    )
        : const EdgeInsets.fromLTRB(16, 16, 16, 96);

    final double usable = math.max(0.0, width - padding.horizontal);
    final int count = auto
        ? math.max(1, (usable / (maxCrossAxisExtent + crossAxisSpacing)).ceil())
        : fixedCount;
    final double cellWidth =
        math.max(0.0, usable - crossAxisSpacing * (count - 1)) / count;

    final double coverHeight = cellWidth * ShelfDims.gridCoverAspect;
    final double cellHeight = bookshelf
        ? coverHeight + ShelfDims.gridBelowCover
        : cellWidth / 0.54;

    return LibraryLayout(
      padding: padding,
      cellHeight: cellHeight,
      bookBottom: bookshelf
          ? cellHeight - ShelfDims.plankBelowBook
          : cellHeight,
      crossAxisCount: count,
      cellWidth: cellWidth,
      crossAxisSpacing: crossAxisSpacing,
      mainAxisSpacing: mainAxisSpacing,
    );
  }

  factory LibraryLayout.list({required bool bookshelf}) {
    if (bookshelf) {
      return const LibraryLayout(
        padding: EdgeInsets.fromLTRB(
          ShelfDims.shelfSidePadding,
          ShelfDims.listTopInset,
          ShelfDims.shelfSidePadding,
          ShelfDims.shelfBottomPadding,
        ),
        cellHeight: ShelfDims.listRowHeight,
        bookBottom: ShelfDims.listBookBottom,
      );
    }
    return const LibraryLayout(
      padding: EdgeInsets.fromLTRB(12, 8, 12, 96),
      cellHeight: 112,
      bookBottom: 112,
    );
  }

  /// Upright spines on shelves. The shelf (padding, row height, plank spacing,
  /// where the books touch the plank) is exactly the 4-comics-per-row grid's;
  /// only the number of books per row changes: as many ~38 dp spines as fit.
  factory LibraryLayout.verticalStack(
    double width, {
    required bool bookshelf,
  }) {
    final LibraryLayout ref4 = LibraryLayout.grid(
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

    return LibraryLayout(
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
  factory LibraryLayout.stack({required bool bookshelf}) {
    if (bookshelf) {
      return const LibraryLayout(
        padding: EdgeInsets.fromLTRB(
          ShelfDims.shelfSidePadding,
          ShelfDims.shelfTopInset,
          ShelfDims.shelfSidePadding,
          ShelfDims.shelfBottomPadding,
        ),
        cellHeight: ShelfDims.stackShelfRowHeight,
        bookBottom: ShelfDims.stackShelfRowHeight,
      );
    }
    return const LibraryLayout(
      padding: EdgeInsets.fromLTRB(12, 8, 12, 96),
      cellHeight: ShelfDims.stackRowHeight,
      bookBottom: ShelfDims.stackRowHeight,
    );
  }
}

/// ==========================================
/// Folder shelf sections
/// ==========================================

// Version / volume / chapter markers: "v1", "v02", "ver. 3", "vol 12",
// "ch. 5", "part 2" (optionally a range such as "vol 1-3").
final RegExp _versionMarkers = RegExp(
  r'(?<![A-Za-z0-9])'
  r'(?:version|volume|chapter|chap|vol|ver|ch|part|pt|v)(?![A-Za-z])'
  r'\.?\s*\d+(?:[.,]\d+)*(?:\s*[-–—]\s*\d+(?:[.,]\d+)*)?',
  caseSensitive: false,
);

// Standalone numbers and numeric ranges: "2024", "01-12".
final RegExp _standaloneNumbers = RegExp(
  r'(?<![A-Za-z0-9])\d+(?:[.,]\d+)*(?:\s*[-–—]\s*\d+(?:[.,]\d+)*)?'
  r'(?![A-Za-z0-9])',
);

final RegExp _emptySquareBrackets = RegExp(r'\[\s*\]');
final RegExp _runsOfWhitespace = RegExp(r'\s+');
final RegExp _edgeSeparators = RegExp(r'^[\s\-_–—]+|[\s\-_–—]+$');

/// Removes every parenthesis, every word inside parentheses and every
/// character after the last closing parenthesis. An unclosed "(" swallows the
/// rest of the text.
String _stripParentheses(String raw) {
  final int lastClose = raw.lastIndexOf(')');
  final String head = lastClose >= 0 ? raw.substring(0, lastClose + 1) : raw;
  final StringBuffer out = StringBuffer();
  int depth = 0;
  for (int i = 0; i < head.length; i++) {
    final String ch = head[i];
    if (ch == '(') {
      depth++;
    } else if (ch == ')') {
      if (depth > 0) depth--;
    } else if (depth == 0) {
      out.write(ch);
    }
  }
  return out.toString();
}

/// Text inside the first pair of parentheses (to its matching ")", or to the
/// end when it is never closed), without any parenthesis characters.
String _firstParenthesisContent(String raw, int open) {
  int depth = 0;
  int end = raw.length;
  for (int i = open; i < raw.length; i++) {
    final String ch = raw[i];
    if (ch == '(') {
      depth++;
    } else if (ch == ')') {
      depth--;
      if (depth == 0) {
        end = i;
        break;
      }
    }
  }
  return raw.substring(open + 1, end).replaceAll(RegExp(r'[()]'), '');
}

/// Cleans a raw folder name for display on the shelf plank / header.
///
///  (a) removes all parentheses, the words inside them and everything after
///      the last ")". When nothing precedes the first "(" (the whole name was
///      wrapped in parentheses) the text inside the first parentheses is used
///      instead, before the remaining rules run;
///  (b) strips version / volume / chapter markers (v1, v02, ver. 3, vol 12,
///      ch. 5, part 2), standalone numbers and numeric ranges (2024, 01-12);
///  (c) removes empty square brackets, leading / trailing dashes and
///      underscores and collapses extra spaces. An empty result falls back to
///      the trimmed original name.
String cleanFolderTitle(String raw) {
  final int firstOpen = raw.indexOf('(');
  String text;
  if (firstOpen >= 0 && raw.substring(0, firstOpen).trim().isEmpty) {
    text = _firstParenthesisContent(raw, firstOpen);
  } else {
    text = _stripParentheses(raw);
  }

  text = text.replaceAll(_versionMarkers, ' ');
  text = text.replaceAll(_standaloneNumbers, ' ');

  text = text.replaceAll(_emptySquareBrackets, ' ');
  text = text.replaceAll(_runsOfWhitespace, ' ').trim();
  text = text.replaceAll(_edgeSeparators, '').trim();
  text = text.replaceAll(_runsOfWhitespace, ' ');

  return text.isEmpty ? raw.trim() : text;
}

/// One block of the library: the topmost ungrouped section ([groupId] and
/// [title] null) or one folder import ([title] is the cleaned folder name).
class LibrarySection {
  const LibrarySection({
    required this.groupId,
    required this.title,
    required this.comics,
  });

  final String? groupId;
  final String? title;
  final List<ComicIdentity> comics;

  bool get isFolder => groupId != null;
}

/// A folder divider plank to paint: content-space top edge + cleaned title.
class ShelfFolderPlank {
  const ShelfFolderPlank({required this.top, required this.title});

  final double top;
  final String title;
}

/// Vertical geometry of one [LibrarySection] (content space, in dp).
class SectionGeometry {
  const SectionGeometry({
    required this.itemCount,
    required this.rowCount,
    required this.top,
    required this.leading,
    required this.headerTop,
    required this.headerHeight,
    required this.rowsTop,
    required this.rowsExtent,
    required this.trailing,
    required this.bottom,
  });

  final int itemCount;
  final int rowCount;

  /// Where the section starts.
  final double top;

  /// Space before the first row: top padding, and for a folder also its header
  /// (divider plank or text header). This is the height of the header sliver.
  final double leading;

  /// Top and height of the folder header (0 height for the ungrouped section).
  final double headerTop;
  final double headerHeight;

  /// Top of the first row and total height of all rows (planks excluded).
  final double rowsTop;
  final double rowsExtent;

  /// Space after the last row (gap to the next section / bottom padding).
  final double trailing;

  /// End of the section (== [top] + leading + rowsExtent + trailing).
  final double bottom;
}

/// A scroll position expressed in comics, so it survives a layout change.
/// [item] < 0 is inside the section's header zone (fraction of it), 0..count
/// is the fractional comic index and > count is inside the trailing gap.
class ShelfScrollAnchor {
  const ShelfScrollAnchor(this.section, this.item);

  final int section;
  final double item;
}

/// Exact vertical layout of a list of [LibrarySection]s for one view mode:
/// where every folder header, row, regular plank and the bottom plank sit and
/// how tall the whole content is.
///
/// In stack mode all comics of a section pile onto ONE shelf: one regular
/// plank below the pile and none inside it.
class SectionedShelfLayout {
  const SectionedShelfLayout._({
    required this.sections,
    required this.contentExtent,
    required this.regularPlankTops,
    required this.bottomPlankTop,
    required this.folderPlanks,
    required this.crossAxisCount,
    required this.rowStride,
    required this.isPile,
  });

  final List<SectionGeometry> sections;

  /// Total scrollable extent (all slivers, paddings included).
  final double contentExtent;

  /// Content-space tops of the regular planks above the bottom plank, in
  /// order (one per row, or one per section in stack mode).
  final List<double> regularPlankTops;

  /// Top of the lowermost plank (the one the base plinth docks to).
  final double bottomPlankTop;

  /// Folder divider planks (bookshelf mode only).
  final List<ShelfFolderPlank> folderPlanks;

  final int crossAxisCount;
  final double rowStride;
  final bool isPile;

  factory SectionedShelfLayout.compute({
    required LibraryLayout layout,
    required LibraryViewMode mode,
    required bool bookshelf,
    required List<LibrarySection> sections,
  }) {
    final bool pile = mode == LibraryViewMode.stack;
    final int cross = pile ? 1 : math.max(1, layout.crossAxisCount);
    final double stride = layout.rowStride;

    final List<SectionGeometry> geometry = <SectionGeometry>[];
    final List<double> planks = <double>[];
    final List<ShelfFolderPlank> folderPlanks = <ShelfFolderPlank>[];

    double y = 0;
    for (int i = 0; i < sections.length; i++) {
      final LibrarySection section = sections[i];
      final bool first = i == 0;
      final bool last = i == sections.length - 1;
      final int count = section.comics.length;
      final int rows = count == 0 ? 0 : (count + cross - 1) ~/ cross;

      double headerTop = y;
      double headerHeight = 0;
      final double leading;
      if (!section.isFolder) {
        leading = first ? layout.padding.top : 0;
      } else if (bookshelf) {
        final double topGap = first ? ShelfDims.folderFirstTop : 0;
        headerTop = y + topGap;
        headerHeight = ShelfDims.folderPlankHeight;
        leading = topGap + headerHeight + ShelfDims.folderPlankGapAfter;
      } else {
        final double topGap = first ? layout.padding.top : 0;
        headerTop = y + topGap;
        headerHeight = ShelfDims.folderTextHeaderHeight;
        leading = topGap + headerHeight;
      }

      final double rowsTop = y + leading;
      final double rowsExtent = rows == 0
          ? 0
          : rows * layout.cellHeight + (rows - 1) * layout.mainAxisSpacing;

      if (bookshelf && rows > 0) {
        double plankTopOfRow(int row) =>
            rowsTop + row * stride + layout.bookBottom - ShelfDims.plankBehindBook;
        if (pile) {
          planks.add(plankTopOfRow(rows - 1));
        } else {
          for (int r = 0; r < rows; r++) {
            planks.add(plankTopOfRow(r));
          }
        }
      }
      if (bookshelf && section.isFolder) {
        folderPlanks.add(
          ShelfFolderPlank(top: headerTop, title: section.title ?? ''),
        );
      }

      final double trailing;
      if (last) {
        trailing = layout.padding.bottom;
      } else if (bookshelf) {
        // A pile's plank hangs below its last spine (the cell ends at the
        // spine); the other layouts' cells already include their plank.
        trailing =
            (pile ? ShelfDims.plankBelowBook : 0) + ShelfDims.folderSectionGap;
      } else {
        trailing = ShelfDims.folderTextSectionGap;
      }

      final double bottom = rowsTop + rowsExtent + trailing;
      geometry.add(
        SectionGeometry(
          itemCount: count,
          rowCount: rows,
          top: y,
          leading: leading,
          headerTop: headerTop,
          headerHeight: headerHeight,
          rowsTop: rowsTop,
          rowsExtent: rowsExtent,
          trailing: trailing,
          bottom: bottom,
        ),
      );
      y = bottom;
    }

    final double fallbackPlank =
        layout.padding.top + layout.bookBottom - ShelfDims.plankBehindBook;
    return SectionedShelfLayout._(
      sections: geometry,
      contentExtent: sections.isEmpty ? layout.padding.vertical : y,
      regularPlankTops: planks.length > 1
          ? List<double>.unmodifiable(planks.sublist(0, planks.length - 1))
          : const <double>[],
      bottomPlankTop: planks.isEmpty ? fallbackPlank : planks.last,
      folderPlanks: List<ShelfFolderPlank>.unmodifiable(folderPlanks),
      crossAxisCount: cross,
      rowStride: stride,
      isPile: pile,
    );
  }

  /// The scroll position [pixels] as "which comic is at the top".
  ShelfScrollAnchor anchorAt(double pixels) {
    if (sections.isEmpty) return const ShelfScrollAnchor(0, 0);
    for (int i = 0; i < sections.length; i++) {
      final SectionGeometry g = sections[i];
      if (pixels >= g.bottom && i < sections.length - 1) continue;

      if (pixels < g.rowsTop) {
        final double fraction = g.leading > 0
            ? ((pixels - g.rowsTop) / g.leading).clamp(-1.0, 0.0).toDouble()
            : 0.0;
        return ShelfScrollAnchor(i, fraction);
      }
      final double rowsEnd = g.rowsTop + g.rowsExtent;
      if (pixels >= rowsEnd) {
        final double fraction = g.trailing > 0
            ? ((pixels - rowsEnd) / g.trailing).clamp(0.0, 1.0).toDouble()
            : 0.0;
        return ShelfScrollAnchor(i, g.itemCount + fraction);
      }
      final double rowPosition = _rowsIn(pixels - g.rowsTop);
      return ShelfScrollAnchor(
        i,
        math.min(rowPosition * crossAxisCount, g.itemCount.toDouble()),
      );
    }
    return const ShelfScrollAnchor(0, 0);
  }

  double _rowsIn(double distance) =>
      rowStride > 0 ? distance / rowStride : 0.0;

  /// Scroll offset (in this layout) of a position taken from [anchorAt].
  double offsetOf(ShelfScrollAnchor anchor) {
    if (sections.isEmpty) return 0;
    final SectionGeometry g =
        sections[anchor.section.clamp(0, sections.length - 1).toInt()];
    if (anchor.item < 0) return g.rowsTop + anchor.item * g.leading;
    if (anchor.item > g.itemCount) {
      return g.rowsTop + g.rowsExtent + (anchor.item - g.itemCount) * g.trailing;
    }
    final double y = g.rowsTop + (anchor.item / crossAxisCount) * rowStride;
    return math.min(y, g.rowsTop + g.rowsExtent);
  }
}

/// Natural-order comparison of two titles split into digit / non-digit chunks
/// (see `_numberChunks` in the dashboard): "issue 2" sorts before "issue 10".
int compareNaturalChunks(List<String> a, List<String> b) {
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

final RegExp _leadingZeros = RegExp(r'^0+(?=\d)');

bool _isDigit(int codeUnit) => codeUnit >= 48 && codeUnit <= 57;

/// Last-read time of [progress] in milliseconds since the epoch (0 if unknown).
int timestampOf(ReadingProgress progress) {
  final Object? raw = progress.updatedAt;
  if (raw is DateTime) return raw.millisecondsSinceEpoch;
  if (raw is num) return raw.toInt();
  if (raw is String) return DateTime.tryParse(raw)?.millisecondsSinceEpoch ?? 0;
  return 0;
}

/// True when both maps hold exactly the same last-read times.
bool sameReadTimes(Map<String, int> a, Map<String, int> b) {
  if (a.length != b.length) return false;
  for (final MapEntry<String, int> entry in a.entries) {
    if (b[entry.key] != entry.value) return false;
  }
  return true;
}
