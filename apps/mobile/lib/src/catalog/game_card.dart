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
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: tolerance
            ? const [Color(0xFF303A39), Color(0xFF202C2A)]
            : const [Color(0xFF344733), Color(0xFF202C2A)],
      ),
      borderRadius: BorderRadius.circular(28),
      border: Border.all(color: NightColors.divider),
    ),
    child: Padding(
      padding: const EdgeInsets.all(20),
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
                    NightEyebrow(
                      genre,
                      color: tolerance ? NightColors.lilac : NightColors.accent,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      title,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              ExcludeSemantics(
                child: Container(
                  width: 68,
                  height: 68,
                  decoration: BoxDecoration(
                    color: tolerance ? NightColors.raised : NightColors.accent,
                    borderRadius: BorderRadius.circular(23),
                    border: tolerance
                        ? Border.all(
                            color: NightColors.lilac.withValues(alpha: .45),
                          )
                        : null,
                  ),
                  child: tolerance
                      ? CustomPaint(painter: _ToleranceMark())
                      : const NightArt(height: 68),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(description, style: const TextStyle(color: NightColors.text)),
          const SizedBox(height: 16),
          _detail(Icons.people_outline_rounded, metadata),
          const SizedBox(height: 6),
          _detail(
            tolerance ? Icons.devices_rounded : Icons.phonelink_ring_rounded,
            mode,
          ),
          const SizedBox(height: 18),
          NightButton(label: action, onPressed: onPressed),
        ],
      ),
    ),
  );

  Widget _detail(IconData icon, String text) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      ExcludeSemantics(child: Icon(icon, size: 16, color: NightColors.muted)),
      const SizedBox(width: 8),
      Expanded(
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 12,
            height: 1.5,
            color: NightColors.muted,
          ),
        ),
      ),
    ],
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
      stroke..color = NightColors.lilac,
    );
    canvas.drawLine(
      Offset.zero,
      const Offset(12, -17),
      stroke..color = NightColors.text,
    );
    canvas.drawCircle(Offset.zero, 4, Paint()..color = NightColors.lilac);
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
