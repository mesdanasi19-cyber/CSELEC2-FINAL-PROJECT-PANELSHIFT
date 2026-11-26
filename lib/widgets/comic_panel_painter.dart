import 'package:flutter/material.dart';

import '../services/native_opencv_service.dart';

class ComicPanelPainter extends CustomPainter {
  final List<ComicPanel> panels;
  final int activeIndex;
  final bool showDimming;
  final bool showOutlines;
  final double dimmingOpacity;

  ComicPanelPainter({
    required this.panels,
    required this.activeIndex,
    this.showDimming = true,
    this.showOutlines = true,
    this.dimmingOpacity = 0.65, // <-- Added with default value
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (panels.isEmpty) return;

    // 1. Draw dimming overlay only if enabled
    if (showDimming && activeIndex >= 0 && activeIndex < panels.length) {
      final activePanel = panels[activeIndex];
      final activeRect = Rect.fromLTWH(
        activePanel.x * size.width,
        activePanel.y * size.height,
        activePanel.width * size.width,
        activePanel.height * size.height,
      );

      final dimPaint = Paint()
        ..color = Colors.black.withOpacity(dimmingOpacity)
        ..style = PaintingStyle.fill;

      canvas.saveLayer(Offset.zero & size, Paint());
      canvas.drawRect(Offset.zero & size, dimPaint);
      canvas.drawRect(activeRect, Paint()..blendMode = BlendMode.clear);
      canvas.restore();
    }

    // 2. Draw panel outlines and badges only if enabled
    if (showOutlines) {
      final strokePaint = Paint()
        ..color = Colors.yellowAccent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.0;

      final activeStrokePaint = Paint()
        ..color = Colors.cyanAccent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4.5;

      // Constituent (pre-merge) rectangles of a merged panel: a different
      // colour and a thinner stroke so they never hide the outer outline.
      final subStrokePaint = Paint()
        ..color = Colors.orangeAccent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0;

      for (int i = 0; i < panels.length; i++) {
        final panel = panels[i];
        final rect = Rect.fromLTWH(
          panel.x * size.width,
          panel.y * size.height,
          panel.width * size.width,
          panel.height * size.height,
        );

        final isCurrent = (i == activeIndex && showDimming);
        canvas.drawRect(rect, isCurrent ? activeStrokePaint : strokePaint);

        final textSpan = TextSpan(
          text: ' #${i + 1} ',
          style: TextStyle(
            color: Colors.black,
            fontSize: 14,
            fontWeight: FontWeight.bold,
            backgroundColor: isCurrent
                ? Colors.cyanAccent
                : Colors.yellowAccent,
          ),
        );

        final textPainter = TextPainter(
          text: textSpan,
          textDirection: TextDirection.ltr,
        )..layout();

        textPainter.paint(canvas, Offset(rect.left + 4, rect.top + 4));

        // 3. Merged sub-panels, labelled #<outer>.<n>. Outline only: the outer
        // panel stays the single camera stop.
        for (int k = 0; k < panel.mergedSubPanels.length; k++) {
          final sub = panel.mergedSubPanels[k];
          final subRect = Rect.fromLTWH(
            sub.left * size.width,
            sub.top * size.height,
            sub.width * size.width,
            sub.height * size.height,
          );
          canvas.drawRect(subRect, subStrokePaint);

          final subPainter = TextPainter(
            text: TextSpan(
              text: ' #${i + 1}.${k + 1} ',
              style: const TextStyle(
                color: Colors.black,
                fontSize: 11,
                fontWeight: FontWeight.bold,
                backgroundColor: Colors.orangeAccent,
              ),
            ),
            textDirection: TextDirection.ltr,
          )..layout();

          // Bottom-left corner, so it never sits on the outer "#n" badge at
          // the top-left of the outer box.
          subPainter.paint(
            canvas,
            Offset(subRect.left + 3, subRect.bottom - subPainter.height - 3),
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant ComicPanelPainter oldDelegate) {
    return oldDelegate.panels != panels ||
        oldDelegate.activeIndex != activeIndex ||
        oldDelegate.showDimming != showDimming ||
        oldDelegate.showOutlines != showOutlines ||
        oldDelegate.dimmingOpacity != dimmingOpacity;
  }
}
