import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../services/comic_cover_service.dart';
import '../../services/comic_identity.dart';
import '../../services/reading_progress_service.dart';
import 'bookshelf_backdrop.dart';
import 'library_file_ops.dart';
import 'library_models.dart';

/// ==========================================
/// 2. Library card (shared by grid, list, stack and vertical stack)
/// ==========================================
enum EntryLayout { grid, list, stack, verticalStack }

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
class ComicEntry extends StatefulWidget {
  const ComicEntry({
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
  final EntryLayout layout;
  final bool bookshelf;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  /// This comic is ticked in multi-select mode.
  final bool isSelected;

  /// The dashboard is in multi-select mode (some comic is ticked).
  final bool isSelectionMode;

  @override
  State<ComicEntry> createState() => _ComicEntryState();
}

class _ComicEntryState extends State<ComicEntry> {
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
  void didUpdateWidget(covariant ComicEntry oldWidget) {
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
    final bool exists = await LibraryFileOps.sourceExists(
      widget.comic.sourcePath,
    );
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
        final bool isGrid = widget.layout == EntryLayout.grid;
        final bool isStack = widget.layout == EntryLayout.stack;
        final bool isVerticalStack =
            widget.layout == EntryLayout.verticalStack;
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
  /// by `_BookshelfPainter` behind the grid) and a caption sits under it.
  /// The cover's bottom edge lands exactly on the plank: the cell height is
  /// `cover height + ShelfDims.gridBelowCover`.
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
          child: ShelfBook(
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
        const SizedBox(height: ShelfDims.plankBelowBook),
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
      padding: const EdgeInsets.only(top: ShelfDims.listTopGap),
      child: Align(
        alignment: Alignment.topCenter,
        child: SizedBox(
          height: ShelfDims.listBookHeight,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: ShelfDims.listBookWidth,
                child: ShelfBook(
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
        padding: const EdgeInsets.symmetric(vertical: ShelfDims.stackGap / 2),
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
  /// other. The pile rests on the bottom plank drawn by `_BookshelfPainter`;
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
  /// `_BookshelfPainter` (cell height == book height + plankBelowBook, the
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
          child: ShelfBook(
            onTap: widget.onTap,
            onLongPress: widget.onLongPress,
            child: Stack(
              fit: StackFit.expand,
              children: _verticalSpineLayers(scheme, spineCover, summary),
            ),
          ),
        ),
        // Space reserved for the visible shelf plank lip in front of the book
        const SizedBox(height: ShelfDims.plankBelowBook),
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
