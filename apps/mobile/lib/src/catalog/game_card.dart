import 'dart:math' as math;
import 'package:flutter/material.dart';

import '../design/night_art.dart';
import '../design/night_components.dart';
import '../design/night_theme.dart';

/// Two games share a hierarchy; the original marks distinguish their premise.
class CatalogGameCard extends StatelessWidget {
  const CatalogGameCard({
    super.key,
    required this.title,
    required this.genre,
    required this.description,
    required this.metadata,
    required this.mode,
    required this.action,
    required this.tolerance,
    required this.onPressed,
  });
  final String title, genre, description, metadata, mode, action;
  final bool tolerance;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => NightPanel(
    padding: 20,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  NightEyebrow(genre),
                  const SizedBox(height: 6),
                  Text(
                    title,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            ExcludeSemantics(
              child: Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: tolerance ? NightColors.raised : NightColors.accent,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: tolerance
                    ? CustomPaint(painter: _ToleranceMark())
                    : const NightArt(height: 64),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(description),
        const SizedBox(height: 10),
        Text(
          metadata,
          style: const TextStyle(fontSize: 12, color: NightColors.muted),
        ),
        const SizedBox(height: 4),
        Text(
          mode,
          style: const TextStyle(fontSize: 12, color: NightColors.muted),
        ),
        const SizedBox(height: 16),
        NightButton(label: action, onPressed: onPressed),
      ],
    ),
  );
}

class _ToleranceMark extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2 + 6);
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      Rect.fromCircle(center: Offset.zero, radius: 22),
      math.pi,
      math.pi,
      false,
      stroke..color = NightColors.border,
    );
    canvas.drawArc(
      Rect.fromCircle(center: Offset.zero, radius: 22),
      math.pi,
      math.pi * .7,
      false,
      stroke..color = NightColors.accent,
    );
    canvas.drawLine(
      Offset.zero,
      const Offset(12, -17),
      stroke..color = NightColors.text,
    );
    canvas.drawCircle(Offset.zero, 4, Paint()..color = NightColors.accent);
    canvas.drawLine(
      const Offset(-16, 10),
      const Offset(16, 10),
      stroke..color = NightColors.border,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
