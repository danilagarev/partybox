import 'package:flutter/material.dart';

import '../design/deals_cover.dart';
import '../design/night_scene.dart';
import '../design/night_components.dart';
import '../design/night_theme.dart';

/// Games share a hierarchy; their marks distinguish the premise.
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
    this.clues = false,
    this.truth = false,
    this.deals = false,
  });
  final String title, genre, description, metadata, mode, action;
  final bool tolerance;
  final bool clues;
  final bool truth;
  final bool deals;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: deals
            ? const [Color(0xFF40382E), Color(0xFF272823)]
            : truth
            ? const [Color(0xFF373346), Color(0xFF24252F)]
            : clues
            ? const [Color(0xFF394337), Color(0xFF202C2A)]
            : tolerance
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
                      color: tolerance || truth
                          ? NightColors.lilac
                          : NightColors.accent,
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
              SizedBox(
                width: 104,
                child: deals
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: const SizedBox(height: 76, child: DealsCover()),
                      )
                    : truth
                    ? const NightScene(kind: NightSceneKind.truth, height: 76)
                    : NightScene(
                        kind: clues
                            ? NightSceneKind.clues
                            : tolerance
                            ? NightSceneKind.tolerance
                            : NightSceneKind.spy,
                        height: 76,
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
