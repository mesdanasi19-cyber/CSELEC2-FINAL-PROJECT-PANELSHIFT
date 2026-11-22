import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'library_models.dart';

/// ==========================================
/// Bookshelf mode (painted backdrop + book tile)
/// ==========================================

/// Colors for the shelf. Two fixed palettes (identity-comparable so the
/// painter can cheaply decide when to repaint).
class ShelfPalette {
  const ShelfPalette({
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
  static const ShelfPalette dark = ShelfPalette(
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
  static const ShelfPalette light = ShelfPalette(
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

class ShelfBackdrop extends StatelessWidget {
  const ShelfBackdrop({
    super.key,
    required this.scroll,
    required this.palette,
    required this.plankTops,
    required this.bottomPlankTop,
    required this.folderPlanks,
    required this.rowStride,
    this.fillEmptyShelves = true,
  });

  final ScrollController scroll;
  final ShelfPalette palette;

  /// Content-space tops of the regular planks above the bottom plank (from
  /// [SectionedShelfLayout.regularPlankTops]).
  final List<double> plankTops;

  /// Content-space top of the lowermost plank; the base plinth docks to it.
  final double bottomPlankTop;

  /// Thicker folder divider planks (top edge + cleaned title) carrying the
  /// wooden nameplate bump.
  final List<ShelfFolderPlank> folderPlanks;

  /// Distance between empty shelves drawn below the last row of a short
  /// library.
  final double rowStride;

  /// `false` in stack mode: the books form one pile resting on its own plank,
  /// so no empty shelves are added and the base never docks to the screen
  /// bottom (back wall, uprights, crown and base still are drawn).
  final bool fillEmptyShelves;

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
        // Layer 2: uprights, crown, planks, folder planks and base plinth.
        RepaintBoundary(
          child: CustomPaint(
            willChange: true,
            painter: _BookshelfPainter(
              scroll: scroll,
              palette: palette,
              plankTops: plankTops,
              bottomPlankTop: bottomPlankTop,
              folderPlanks: folderPlanks,
              rowStride: rowStride,
              fillEmptyShelves: fillEmptyShelves,
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

  final ShelfPalette palette;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = palette.surround);

    final double wallLeft = ShelfDims.sideTotalWidth;
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
    double x = wallLeft + ShelfDims.wallBoardWidth;
    x < wallRight;
    x += ShelfDims.wallBoardWidth
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
    required this.plankTops,
    required this.bottomPlankTop,
    required this.folderPlanks,
    required this.rowStride,
    this.fillEmptyShelves = true,
  }) : super(repaint: scroll);

  final ScrollController scroll;
  final ShelfPalette palette;
  final List<double> plankTops;
  final double bottomPlankTop;
  final List<ShelfFolderPlank> folderPlanks;
  final double rowStride;

  /// When `false` (stack mode) there are no empty shelves and the base plinth
  /// stays right under the last pile.
  final bool fillEmptyShelves;

  /// Index of the first value >= [target] in an ascending sequence.
  static int _lowerBound(int length, double Function(int) valueAt, double target) {
    int lo = 0;
    int hi = length;
    while (lo < hi) {
      final int mid = (lo + hi) >> 1;
      if (valueAt(mid) < target) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;

    final double offset = scroll.positions.isEmpty
        ? 0.0
        : scroll.positions.last.pixels;
    final _PlankKit kit = _PlankKit.obtain(palette, size.width);

    final double reach = ShelfDims.plankHeight + ShelfDims.castShadow;

    // Where the lowermost plank & base plinth sit in content space:
    // - On a short library, docked cleanly at the bottom of the screen with
    //   empty shelves filling the space above it.
    // - On a tall library, anchored directly under the final row of comics.
    final double viewportBaseTop =
        size.height - ShelfDims.baseTotalHeight - ShelfDims.floorMargin;
    // A pile rests on its own bottom plank, so it never docks to the screen
    // bottom (that would leave the books floating above the plank).
    final bool dockBaseToBottom =
        fillEmptyShelves && rowStride > 0 && bottomPlankTop < viewportBaseTop;
    final double basePlankTop = dockBaseToBottom
        ? viewportBaseTop
        : bottomPlankTop;

    final double crownTop = -offset;
    final double baseScreenTop = basePlankTop - offset;
    final double bookcaseTop = math.max(
      0.0,
      crownTop + ShelfDims.crownCap + ShelfDims.crownCove,
    );
    final double bookcaseBottom = math.min(
      size.height,
      baseScreenTop + ShelfDims.baseTotalHeight,
    );

    // Mask overscroll above the crown or space below the bookcase feet.
    if (crownTop > 0) {
      kit.paintSurroundBand(canvas, 0.0, crownTop);
    }
    if (baseScreenTop + ShelfDims.baseTotalHeight < size.height) {
      kit.paintFloorArea(
        canvas,
        math.max(0.0, baseScreenTop + ShelfDims.baseTotalHeight),
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

    // Regular planks (one per row; one per section in stack mode). Stop before
    // the lowermost plank so it never collides with the base.
    final double limit = basePlankTop - 24;
    final double minTop = offset - reach;
    for (
      int i = _lowerBound(plankTops.length, (int k) => plankTops[k], minTop);
      i < plankTops.length;
      i++
    ) {
      final double top = plankTops[i];
      if (top - offset >= size.height || top >= limit) break;
      kit.paint(canvas, top - offset, i);
    }

    // Short library: the real bottom plank becomes an ordinary plank and empty
    // shelves fill the space down to the docked base.
    if (dockBaseToBottom) {
      int index = plankTops.length;
      if (bottomPlankTop < limit && bottomPlankTop >= minTop) {
        kit.paint(canvas, bottomPlankTop - offset, index);
      }
      final int firstEmpty = math.max(
        1,
        ((minTop - bottomPlankTop) / rowStride).floor(),
      );
      for (int k = firstEmpty; ; k++) {
        final double top = bottomPlankTop + k * rowStride;
        if (top - offset >= size.height || top >= limit) break;
        index = plankTops.length + k;
        kit.paint(canvas, top - offset, index);
      }
    }

    // Thicker folder divider planks with their wooden nameplate bumps.
    final double folderReach =
        ShelfDims.folderPlankHeight + ShelfDims.castShadow * 1.2;
    for (
      int j = _lowerBound(
        folderPlanks.length,
        (int k) => folderPlanks[k].top,
        offset - folderReach,
      );
      j < folderPlanks.length;
      j++
    ) {
      final ShelfFolderPlank folder = folderPlanks[j];
      if (folder.top - offset >= size.height) break;
      kit.paintFolderPlank(canvas, folder.top - offset, j, folder.title);
    }

    // Lowermost plank + apron plinth + side feet.
    if (baseScreenTop < size.height &&
        baseScreenTop + ShelfDims.baseTotalHeight > 0) {
      kit.paintBase(
        canvas,
        baseScreenTop,
        dockBaseToBottom ? 99 : plankTops.length,
      );
    }

    // Uppermost plank / stepped crown cornice.
    if (crownTop + ShelfDims.crownHeight + ShelfDims.crownCastShadow > 0) {
      kit.paintCrown(canvas, crownTop);
    }
  }

  static bool _sameDoubles(List<double> a, List<double> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _sameFolders(List<ShelfFolderPlank> a, List<ShelfFolderPlank> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i].top != b[i].top || a[i].title != b[i].title) return false;
    }
    return true;
  }

  @override
  bool shouldRepaint(covariant _BookshelfPainter old) {
    return old.scroll != scroll ||
        old.palette != palette ||
        old.bottomPlankTop != bottomPlankTop ||
        old.rowStride != rowStride ||
        old.fillEmptyShelves != fillEmptyShelves ||
        !_sameDoubles(old.plankTops, plankTops) ||
        !_sameFolders(old.folderPlanks, folderPlanks);
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
      : frontLeft = ShelfDims.sideInset + ShelfDims.sideFrontWidth,
        backLeft = ShelfDims.sideTotalWidth,
        frontWidth = math.max(
          8.0,
          width - 2 * (ShelfDims.sideInset + ShelfDims.sideFrontWidth),
        ),
        backWidth = math.max(8.0, width - 2 * ShelfDims.sideTotalWidth),
        hasRoom = width - 2 * ShelfDims.sideTotalWidth > 8 {
    const double surfaceH = ShelfDims.plankSurface;
    const double faceH = ShelfDims.plankFace;
    const double depth = ShelfDims.sideWallDepth;
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
      ShelfDims.castShadow,
    );

    // Side-wall cast shadows right below where each shelf joins the uprights.
    sideJointShadowLeft = Path()
      ..moveTo(0, surfaceH + faceH)
      ..lineTo(depth, surfaceH + faceH)
      ..lineTo(depth, surfaceH + faceH + ShelfDims.castShadow * 0.72)
      ..lineTo(0, surfaceH + faceH + ShelfDims.castShadow * 0.35)
      ..close();
    sideJointShadowRight = Path()
      ..moveTo(fw - depth, surfaceH + faceH)
      ..lineTo(fw, surfaceH + faceH)
      ..lineTo(fw, surfaceH + faceH + ShelfDims.castShadow * 0.35)
      ..lineTo(fw - depth, surfaceH + faceH + ShelfDims.castShadow * 0.72)
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
        Rect.fromLTWH(0, surfaceH + faceH, fw, ShelfDims.castShadow * 0.75),
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

  static _PlankKit obtain(ShelfPalette palette, double width) {
    final _PlankKit? kit = _current;
    if (kit != null && identical(kit.palette, palette) && kit.width == width) {
      return kit;
    }
    return _current = _PlankKit._(palette, width);
  }

  final ShelfPalette palette;
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

  /// Thicker divider plank + nameplate bump (built on first use).
  late final _FolderPlank folderPlank = _FolderPlank(this);

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
    const double inset = ShelfDims.sideInset;
    const double front = ShelfDims.sideFrontWidth;
    const double depth = ShelfDims.sideWallDepth;
    const double total = ShelfDims.sideTotalWidth;
    const double tile = ShelfDims.uprightTile;

    stileRect = Rect.fromLTWH(inset, 0, front, tile);
    stripRect = Rect.fromLTWH(inset + front, 0, depth, tile);
    stileShadowRect = Rect.fromLTWH(
      inset + front,
      0,
      ShelfDims.sideShadow,
      tile,
    );
    stripSeamRect = Rect.fromLTWH(total - 1, 0, 1, tile);
    stileBevelRect = Rect.fromLTWH(inset + front - 1.5, 0, 1.5, tile);
    stileEdgeRect = Rect.fromLTWH(inset, 0, 1.2, tile);
    stileSheenRect = Rect.fromLTWH(inset + 3, 0, 3.5, tile);
    wallSideShadowRect = Rect.fromLTWH(
      total,
      0,
      ShelfDims.wallSideShadow,
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
    const double capH = ShelfDims.crownCap;
    const double coveH = ShelfDims.crownCove;
    const double friezeH = ShelfDims.crownFrieze;
    const double h = ShelfDims.crownHeight;
    const double inset = ShelfDims.sideInset;
    const double front = ShelfDims.sideFrontWidth;
    const double depth = ShelfDims.sideWallDepth;
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
      ShelfDims.crownCastShadow,
    );
    crownSideShadowLeft = Path()
      ..moveTo(stileInnerL, h)
      ..lineTo(stileInnerL + depth, h)
      ..lineTo(stileInnerL + depth, h + ShelfDims.crownCastShadow * 0.72)
      ..lineTo(stileInnerL, h + ShelfDims.crownCastShadow * 0.35)
      ..close();
    crownSideShadowRight = Path()
      ..moveTo(stileInnerR - depth, h)
      ..lineTo(stileInnerR, h)
      ..lineTo(stileInnerR, h + ShelfDims.crownCastShadow * 0.35)
      ..lineTo(stileInnerR - depth, h + ShelfDims.crownCastShadow * 0.72)
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
        Rect.fromLTWH(0, h, w, ShelfDims.crownCastShadow * 0.75),
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
    const double plankH = ShelfDims.plankHeight;
    const double apronH = ShelfDims.baseApron;
    const double footH = ShelfDims.baseFootHeight;
    const double totalH = ShelfDims.baseTotalHeight;
    final double fw = frontWidth;

    // Local coordinates where x = 0 is the inner edge of the left front stile
    // and x = fw is the inner edge of the right front stile.
    baseApronRect = Rect.fromLTWH(0, plankH, fw, apronH);
    baseApronTopShadowRect = Rect.fromLTWH(0, plankH, fw, 6.0);
    baseApronBottomEdgeRect = Rect.fromLTWH(0, plankH + apronH - 1.5, fw, 1.5);
    baseKickVoidRect = Rect.fromLTWH(0, plankH + apronH, fw, footH);
    baseFloorShadowRect = Rect.fromLTWH(
      -ShelfDims.sideFrontWidth,
      totalH - 1.0,
      fw + 2 * ShelfDims.sideFrontWidth,
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
    canvas.clipRect(Rect.fromLTRB(0, top, ShelfDims.sideTotalWidth, bottom));
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
    const double tile = ShelfDims.uprightTile;
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

  /// Draws a folder divider plank (thicker than a regular one) whose top edge
  /// is at [top], with the wooden nameplate bump showing [title].
  void paintFolderPlank(Canvas canvas, double top, int index, String title) {
    if (!hasRoom) return;
    folderPlank.paint(canvas, top, index, title);
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

/// The thicker divider plank that sits above a folder's first row: same wood
/// anatomy as a regular plank (trapezoid top surface, front face, cast
/// shadows) with taller surface and face, plus a centered raised wooden
/// nameplate bump on the face that carries the cleaned folder title.
class _FolderPlank {
  _FolderPlank(this.kit) {
    const double surfaceH = ShelfDims.folderPlankSurface;
    const double faceH = ShelfDims.folderPlankFace;
    const double totalH = surfaceH + faceH;
    const double depth = ShelfDims.sideWallDepth;
    final double fw = kit.frontWidth;
    final ShelfPalette palette = kit.palette;

    surfaceRect = Rect.fromLTWH(0, 0, fw, surfaceH);
    faceRect = Rect.fromLTWH(0, surfaceH, fw, faceH);
    surfacePath = Path()
      ..moveTo(depth, 0)
      ..lineTo(fw - depth, 0)
      ..lineTo(fw, surfaceH)
      ..lineTo(0, surfaceH)
      ..close();

    const double shadowH = ShelfDims.castShadow * 1.2;
    shadowRect = Rect.fromLTWH(depth, totalH, kit.backWidth, shadowH);
    sideJointShadowLeft = Path()
      ..moveTo(0, totalH)
      ..lineTo(depth, totalH)
      ..lineTo(depth, totalH + shadowH * 0.72)
      ..lineTo(0, totalH + shadowH * 0.35)
      ..close();
    sideJointShadowRight = Path()
      ..moveTo(fw - depth, totalH)
      ..lineTo(fw, totalH)
      ..lineTo(fw, totalH + shadowH * 0.35)
      ..lineTo(fw - depth, totalH + shadowH * 0.72)
      ..close();
    highlightRect = Rect.fromLTWH(0, surfaceH, fw, 1.5);
    edgeRect = Rect.fromLTWH(0, totalH - 2, fw, 2);
    sheenRect = Rect.fromLTWH(0, surfaceH + 4, fw, 4);

    shadowPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: <Color>[
          Colors.black.withAlpha(225),
          Colors.black.withAlpha(125),
          Colors.black.withAlpha(40),
          Colors.black.withAlpha(0),
        ],
        stops: const <double>[0.0, 0.32, 0.68, 1.0],
      ).createShader(shadowRect);
    sideJointShadowPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: <Color>[
          Colors.black.withAlpha(190),
          Colors.black.withAlpha(60),
          Colors.black.withAlpha(0),
        ],
        stops: const <double>[0.0, 0.5, 1.0],
      ).createShader(Rect.fromLTWH(0, totalH, fw, shadowH * 0.75));

    surfacePaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: <Color>[palette.surfaceBack, palette.surfaceFront],
      ).createShader(surfaceRect);
    occlusionPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: <Color>[
          Colors.black.withAlpha(170),
          Colors.black.withAlpha(80),
          Colors.black.withAlpha(12),
        ],
        stops: const <double>[0.0, 0.55, 1.0],
      ).createShader(surfaceRect);
    surfaceSideShadowPaint = Paint()
      ..shader = LinearGradient(
        colors: <Color>[
          Colors.black.withAlpha(155),
          Colors.black.withAlpha(45),
          Colors.black.withAlpha(0),
          Colors.black.withAlpha(0),
          Colors.black.withAlpha(45),
          Colors.black.withAlpha(155),
        ],
        stops: const <double>[0.0, 0.05, 0.14, 0.86, 0.95, 1.0],
      ).createShader(surfaceRect);
    facePaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: <Color>[palette.faceTop, palette.faceBottom],
      ).createShader(faceRect);
    sheenPaint = Paint()
      ..shader = LinearGradient(
        colors: <Color>[
          Colors.white.withAlpha(0),
          Colors.white.withAlpha(42),
          Colors.white.withAlpha(0),
        ],
        stops: const <double>[0.0, 0.5, 1.0],
      ).createShader(sheenRect);
    endsPaint = Paint()
      ..shader = LinearGradient(
        colors: <Color>[
          Colors.black.withAlpha(85),
          Colors.black.withAlpha(0),
          Colors.black.withAlpha(0),
          Colors.black.withAlpha(85),
        ],
        stops: const <double>[0.0, 0.03, 0.97, 1.0],
      ).createShader(faceRect);

    grains = List<_PlankGrain>.generate(_variantCount, (int v) {
      final math.Random rnd = math.Random(v * 6151 + 977);
      return _PlankGrain(
        _PlankKit._buildGrain(surfaceRect, rnd, math.max(10, (fw / 20).round())),
        _PlankKit._buildGrain(faceRect, rnd, math.max(14, (fw / 12).round())),
      );
    }, growable: false);

    // --- nameplate bump ---------------------------------------------------
    const double bumpH = ShelfDims.folderBumpHeight;
    bumpTop = surfaceH + (faceH - bumpH) / 2;
    maxBumpWidth = math.max(
      40.0,
      math.min(ShelfDims.folderBumpMaxWidth, fw - 48),
    );

    // A lighter wood inlay than the plank face so the raised plate reads, in
    // both walnut and oak; the engraved ink is the darkest wood tone.
    final Color bumpHigh = Color.lerp(palette.faceTop, palette.highlight, 0.9)!;
    final Color bumpLow = Color.lerp(palette.faceTop, palette.highlight, 0.5)!;
    final Rect bumpShaderRect = Rect.fromLTWH(0, bumpTop, 1, bumpH);
    bumpBodyPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: <Color>[bumpHigh, bumpLow],
      ).createShader(bumpShaderRect);
    bumpContactShadowPaint = Paint()
      ..color = Colors.black.withAlpha(150)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.4);
    bumpOutlinePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.9
      ..color = Colors.black.withAlpha(120);
    bumpTopBevelPaint = Paint()..color = Colors.white.withAlpha(150);
    bumpSideBevelPaint = Paint()..color = Colors.white.withAlpha(80);
    bumpLowBevelPaint = Paint()..color = Colors.black.withAlpha(105);
    bumpSheenPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: <Color>[Colors.white.withAlpha(46), Colors.white.withAlpha(0)],
      ).createShader(Rect.fromLTWH(0, 0, 1, bumpH * 0.55));

    final Rect bumpGrainRect = Rect.fromLTWH(0, 0, maxBumpWidth, bumpH);
    bumpGrains = List<_GrainPaths>.generate(3, (int v) {
      final math.Random rnd = math.Random(v * 4409 + 31);
      return _PlankKit._buildGrain(bumpGrainRect, rnd, 14);
    }, growable: false);

    inkColor = Color.lerp(palette.faceBottom, Colors.black, 0.6)!;
    inkHighlightColor = Color.lerp(palette.highlight, Colors.white, 0.35)!
        .withAlpha(170);
  }

  final _PlankKit kit;

  static const int _variantCount = 6;
  static const int _maxCachedLabels = 32;

  late final Rect surfaceRect;
  late final Rect faceRect;
  late final Path surfacePath;
  late final Rect shadowRect;
  late final Path sideJointShadowLeft;
  late final Path sideJointShadowRight;
  late final Rect highlightRect;
  late final Rect edgeRect;
  late final Rect sheenRect;

  late final Paint shadowPaint;
  late final Paint sideJointShadowPaint;
  late final Paint surfacePaint;
  late final Paint occlusionPaint;
  late final Paint surfaceSideShadowPaint;
  late final Paint facePaint;
  late final Paint sheenPaint;
  late final Paint endsPaint;
  late final List<_PlankGrain> grains;

  late final double bumpTop;
  late final double maxBumpWidth;
  late final Paint bumpBodyPaint;
  late final Paint bumpContactShadowPaint;
  late final Paint bumpOutlinePaint;
  late final Paint bumpTopBevelPaint;
  late final Paint bumpSideBevelPaint;
  late final Paint bumpLowBevelPaint;
  late final Paint bumpSheenPaint;
  late final List<_GrainPaths> bumpGrains;
  late final Color inkColor;
  late final Color inkHighlightColor;

  // Laid-out labels, so scrolling never re-shapes text. Insertion-ordered:
  // the oldest label is evicted (and disposed) first.
  final Map<String, _BumpLabel> _labels = <String, _BumpLabel>{};

  _BumpLabel _labelFor(String title, double maxWidth) {
    final String key = '${maxWidth.round()}|$title';
    final _BumpLabel? cached = _labels[key];
    if (cached != null) return cached;

    TextPainter build(Color color) => TextPainter(
      text: TextSpan(
        text: title,
        style: TextStyle(
          color: color,
          fontSize: 12.5,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.5,
          height: 1.0,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '\u2026',
    )..layout(maxWidth: maxWidth);

    final _BumpLabel label = _BumpLabel(
      ink: build(inkColor),
      highlight: build(inkHighlightColor),
    );
    if (_labels.length >= _maxCachedLabels) {
      final String oldest = _labels.keys.first;
      _labels.remove(oldest)?.dispose();
    }
    return _labels[key] = label;
  }

  /// Draws the divider plank whose top edge is at [top] (kit-local x origin at
  /// the inner edge of the left front stile).
  void paint(Canvas canvas, double top, int index, String title) {
    final _PlankGrain grain = grains[(index * 5) % _variantCount];
    canvas.save();
    canvas.translate(kit.frontLeft, top);

    // 1. Cast shadows onto the back panel and recessed side walls.
    canvas.drawRect(shadowRect, shadowPaint);
    canvas.drawPath(sideJointShadowLeft, sideJointShadowPaint);
    canvas.drawPath(sideJointShadowRight, sideJointShadowPaint);

    // 2. Thick trapezoidal top surface with ambient occlusion.
    canvas.save();
    canvas.clipPath(surfacePath);
    canvas.drawRect(surfaceRect, surfacePaint);
    canvas.drawPath(grain.surface.dark, kit.grainDarkPaint);
    canvas.drawPath(grain.surface.light, kit.grainLightPaint);
    canvas.drawRect(surfaceRect, occlusionPaint);
    canvas.drawRect(surfaceRect, surfaceSideShadowPaint);
    canvas.restore();

    // 3. Tall front face.
    canvas.drawRect(faceRect, facePaint);
    canvas.drawPath(grain.face.dark, kit.grainDarkPaint);
    canvas.drawPath(grain.face.light, kit.grainLightPaint);
    canvas.drawRect(highlightRect, kit.highlightPaint);
    canvas.drawRect(edgeRect, kit.edgePaint);
    canvas.drawRect(sheenRect, sheenPaint);
    canvas.drawRect(faceRect, endsPaint);

    // 4. Raised nameplate bump with the folder title.
    _paintBump(canvas, index, title);

    canvas.restore();
  }

  void _paintBump(Canvas canvas, int index, String title) {
    const double bumpH = ShelfDims.folderBumpHeight;
    const double pad = ShelfDims.folderBumpPadding;
    final double fw = kit.frontWidth;

    final _BumpLabel label = _labelFor(title, maxBumpWidth - 2 * pad);
    final double minWidth = math.min(ShelfDims.folderBumpMinWidth, maxBumpWidth);
    final double bw = (label.width + 2 * pad)
        .clamp(minWidth, maxBumpWidth)
        .toDouble();
    final double left = (fw - bw) / 2;
    final RRect plate = RRect.fromRectAndRadius(
      Rect.fromLTWH(left, bumpTop, bw, bumpH),
      const Radius.circular(ShelfDims.folderBumpRadius),
    );

    // Contact shadow against the plank face (lower and wider than the plate).
    canvas.drawRRect(plate.shift(const Offset(0, 1.8)).inflate(0.8), bumpContactShadowPaint);

    // Wood body.
    canvas.drawRRect(plate, bumpBodyPaint);

    // Grain, bevels and sheen, clipped to the rounded plate.
    canvas.save();
    canvas.clipRRect(plate);
    canvas.translate(left, bumpTop);
    final _GrainPaths grain = bumpGrains[index % bumpGrains.length];
    canvas.drawPath(grain.dark, kit.grainDarkPaint);
    canvas.drawPath(grain.light, kit.grainLightPaint);
    canvas.drawRect(Rect.fromLTWH(0, 0, bw, bumpH * 0.55), bumpSheenPaint);
    canvas.drawRect(Rect.fromLTWH(0, 0, bw, 1.6), bumpTopBevelPaint);
    canvas.drawRect(Rect.fromLTWH(0, 0, 1.4, bumpH), bumpSideBevelPaint);
    canvas.drawRect(Rect.fromLTWH(bw - 1.4, 0, 1.4, bumpH), bumpLowBevelPaint);
    canvas.drawRect(Rect.fromLTWH(0, bumpH - 1.8, bw, 1.8), bumpLowBevelPaint);
    canvas.restore();

    canvas.drawRRect(plate, bumpOutlinePaint);

    // Engraved title: a light copy 1 dp below gives the carved edge.
    final double dx = left + (bw - label.width) / 2;
    final double dy = bumpTop + (bumpH - label.height) / 2;
    label.highlight.paint(canvas, Offset(dx, dy + 0.9));
    label.ink.paint(canvas, Offset(dx, dy));
  }
}

/// A laid-out title in ink plus its light "engraving edge" twin.
class _BumpLabel {
  const _BumpLabel({required this.ink, required this.highlight});

  final TextPainter ink;
  final TextPainter highlight;

  double get width => ink.width;
  double get height => ink.height;

  void dispose() {
    ink.dispose();
    highlight.dispose();
  }
}

/// A comic standing on a shelf: slightly rounded book edges, a spine crease,
/// a faint cover sheen and soft drop shadows that fall on the plank and wall.
class ShelfBook extends StatelessWidget {
  const ShelfBook({
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
