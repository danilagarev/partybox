import 'package:flutter/material.dart';

import '../design/night_components.dart';
import '../design/night_scene.dart';
import '../design/night_theme.dart';
import 'local_session_adapter.dart';

/// Public pack contents, only used before a round has been created.
class SpyThemePreview extends StatelessWidget {
  const SpyThemePreview({super.key, required this.pack, this.compact = false});
  final SpyPack pack;
  final bool compact;

  NightSceneKind get _scene => switch (pack.id) {
    'spy-ru-travel' => NightSceneKind.travel,
    'spy-ru-unusual' => NightSceneKind.unusual,
    _ => NightSceneKind.everyday,
  };

  @override
  Widget build(BuildContext context) => compact
      ? Row(
          children: [
            SizedBox(
              width: 72,
              child: NightScene(
                key: ValueKey(pack.id),
                kind: _scene,
                height: 40,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextButton(
                onPressed: () => _showContents(context),
                child: const Text('Посмотреть локации'),
              ),
            ),
          ],
        )
      : Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            NightScene(key: ValueKey(pack.id), kind: _scene, height: 104),
            const SizedBox(height: 10),
            if (pack.description.isNotEmpty) ...[
              Text(
                pack.description,
                style: const TextStyle(color: NightColors.muted),
              ),
              const SizedBox(height: 10),
            ],
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final place in pack.locations.take(3)) NightBadge(place),
              ],
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => _showContents(context),
                icon: const Icon(Icons.grid_view_rounded, size: 16),
                label: const Text('Посмотреть локации'),
              ),
            ),
          ],
        );

  void _showContents(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => SizedBox(
        height: MediaQuery.sizeOf(context).height * .8,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          pack.title,
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Состав темы. Место для раунда выберем случайно.',
                          style: TextStyle(color: NightColors.muted),
                        ),
                        const SizedBox(height: 12),
                      ],
                    ),
                  ),
                  NightScene(kind: _scene, height: 150),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final place in pack.locations) NightBadge(place),
                    ],
                  ),
                ],
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                child: NightButton(
                  label: 'Готово',
                  onPressed: () => Navigator.pop(context),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
