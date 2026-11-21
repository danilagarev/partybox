import 'package:flutter/material.dart';
import '../design/night_components.dart';
import '../design/night_theme.dart';
import 'room_controller.dart';

const toleranceRules =
    'Каждый по очереди становится героем. Герой тайно расставляет четыре '
    'неприятности от «переживу» до «вечер испорчен». Остальные увидят три '
    'карточки в его порядке и одну отдельно. Обсудите, куда герой поставил '
    'четвёртую, и каждый тайно выберите место. За точную догадку — одно очко. '
    'После ответов всех игроков порядок и догадки откроются. '
    'Партия закончится, когда каждый побывает героем. При равных очках победа общая.';

class TolerancePanel extends StatefulWidget {
  const TolerancePanel({
    super.key,
    required this.controller,
    required this.onChooseGame,
  });
  final RoomController controller;
  final VoidCallback onChooseGame;
  @override
  State<TolerancePanel> createState() => _TolerancePanelState();
}

class _TolerancePanelState extends State<TolerancePanel> {
  List<String>? _order;
  int? _position;
  int? _epoch;

  Future<void> _cancel() async {
    widget.controller.hideRole();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Отменить партию?'),
        content: const SingleChildScrollView(
          child: Text('Очки этой партии сбросятся. Все вернутся в лобби.'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Продолжить игру'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Отменить партию'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await widget.controller.play('tolerance.cancel');
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final snapshot = controller.snapshot!;
    final game = snapshot.tolerance!;
    final host = snapshot.selfId == snapshot.hostId;
    final hero = snapshot.selfId == game.heroId;
    final heroName = snapshot.players
        .firstWhere((p) => p.id == game.heroId)
        .name;
    final enabled =
        controller.online && !controller.busy && !controller.hasPending;
    // A conceal event invalidates drafts even if the server round has not changed.
    if (_epoch != controller.roleConcealEpoch) {
      _epoch = controller.roleConcealEpoch;
      _order = null;
      _position = null;
    }
    final order = _order ?? game.cards.map((c) => c.id).toList();
    return NightPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const NightEyebrow('ШКАЛА ТЕРПЕНИЯ', color: NightColors.lilac),
          const SizedBox(height: 16),
          NightStageProgress(
            labels: const ['Тайная шкала', 'Догадки', 'Открытие', 'Итоги'],
            current: switch (game.phase) {
              'ranking' => 0,
              'guessing' => 1,
              'reveal' => 2,
              _ => 3,
            },
          ),
          const SizedBox(height: 12),
          Text(
            game.phase == 'finished'
                ? 'Вечер выдержали.'
                : 'Раунд ${game.roundIndex + 1} из ${snapshot.players.length}',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 12),
          if (game.phase != 'finished') Text('Герой раунда — $heroName'),
          const SizedBox(height: 12),
          if (game.phase == 'ranking') ...[
            if (hero) ...[
              const Text(
                'Ваш порядок останется тайным. От «переживу» сверху до «вечер испорчен» снизу.',
              ),
              const SizedBox(height: 12),
              if (!controller.toleranceVisible)
                NightButton(
                  label: 'Составить тайную шкалу',
                  onPressed: enabled ? controller.revealTolerance : null,
                )
              else ...[
                const Text(
                  'Переживу',
                  style: TextStyle(color: NightColors.muted),
                ),
                for (final (index, id) in order.indexed)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _scaleCard(
                          index,
                          game.text(id),
                          key: ValueKey('rank-card-$id'),
                        ),
                        Wrap(
                          spacing: 8,
                          children: [
                            TextButton.icon(
                              key: ValueKey('rank-up-$id'),
                              onPressed: enabled && index > 0
                                  ? () => _move(order, index, -1)
                                  : null,
                              icon: const Icon(Icons.arrow_upward),
                              label: const Text('Выше'),
                            ),
                            TextButton.icon(
                              key: ValueKey('rank-down-$id'),
                              onPressed: enabled && index < 3
                                  ? () => _move(order, index, 1)
                                  : null,
                              icon: const Icon(Icons.arrow_downward),
                              label: const Text('Ниже'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                const Text(
                  'Вечер испорчен',
                  style: TextStyle(color: NightColors.muted),
                ),
                const SizedBox(height: 16),
                NightButton(
                  label: 'Скрыть и зафиксировать порядок',
                  onPressed: enabled
                      ? () => controller.play('tolerance.rank', {
                          'order': List<String>.of(order),
                        })
                      : null,
                ),
                TextButton(
                  onPressed: controller.hideRole,
                  child: const Text('Скрыть мою шкалу'),
                ),
              ],
            ] else
              const Text(
                'Герой составляет свою тайную шкалу. Скоро появятся три ориентира и карточка для догадки.',
              ),
          ] else if (game.phase == 'guessing') ...[
            const Text('От «переживу» до «вечер испорчен»:'),
            const SizedBox(height: 12),
            for (final (index, id) in game.visibleOrder.indexed)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _scaleCard(index, game.text(id)),
              ),
            const Divider(),
            Text(
              'Куда поставить: «${game.text(game.targetId)}»?',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            if (hero)
              const Text(
                'Не подсказывайте свой ответ. Остальные обсуждают и выбирают тайно.',
              )
            else if (game.submittedIds.contains(snapshot.selfId))
              const Text(
                'Ваша догадка принята. Она откроется после ответов всех игроков.',
              )
            else ...[
              const Text(
                'Сначала обсудите вслух. Затем каждый выбирает одно из четырёх мест.',
              ),
              const SizedBox(height: 12),
              if (!controller.toleranceVisible)
                NightButton(
                  label: 'Выбрать место тайно',
                  onPressed: enabled ? controller.revealTolerance : null,
                )
              else ...[
                RadioGroup<int>(
                  groupValue: _position,
                  onChanged: (value) {
                    if (enabled) setState(() => _position = value);
                  },
                  child: Column(
                    children: [
                      for (var i = 0; i < 4; i++)
                        RadioListTile<int>(
                          value: i,
                          title: Text(switch (i) {
                            0 => '1 · Перед всеми',
                            3 => '4 · После всех',
                            _ => '${i + 1} · Между $i и ${i + 1}',
                          }),
                          enabled: enabled,
                        ),
                    ],
                  ),
                ),
                NightButton(
                  label: 'Скрыть и отправить догадку',
                  onPressed: enabled && _position != null
                      ? () => controller.play('tolerance.guess', {
                          'position': _position,
                        })
                      : null,
                ),
                TextButton(
                  onPressed: controller.hideRole,
                  child: const Text('Скрыть выбор'),
                ),
              ],
            ],
            const SizedBox(height: 12),
            Text(
              'Ответили ${game.submittedIds.length} из ${snapshot.players.length - 1}',
            ),
          ] else ...[
            if (game.phase == 'reveal') ...[
              const Text('Вот как решил герой:'),
              const SizedBox(height: 12),
              for (final (index, id)
                  in (game.result!['order'] as List).cast<String>().indexed)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _scaleCard(
                    index,
                    game.text(id),
                    highlighted: id == game.targetId,
                  ),
                ),
              const Text('Догадки игроков'),
              for (final guess
                  in (game.result!['guesses'] as List)
                      .cast<Map<String, dynamic>>())
                Text(
                  '${snapshot.players.firstWhere((p) => p.id == guess['playerId']).name}: место ${(guess['position'] as int) + 1} · ${guess['correct'] == true ? '+1 очко' : '0 очков'}',
                ),
              const SizedBox(height: 12),
              const Text(
                'Обсудите самый спорный выбор и передайте роль следующему.',
              ),
              if (host) ...[
                const SizedBox(height: 16),
                NightButton(
                  label: game.roundIndex + 1 == snapshot.players.length
                      ? 'Подвести итоги'
                      : 'Следующий герой',
                  onPressed: enabled
                      ? () => controller.play('tolerance.next')
                      : null,
                ),
              ] else
                const Text('Ведущий продолжит партию.'),
            ] else ...[
              Text(
                'Победители: ${game.winners.map((id) => snapshot.players.firstWhere((p) => p.id == id).name).join(', ')}',
              ),
              if (host) ...[
                const SizedBox(height: 16),
                NightButton(
                  label: 'Ещё одна шкала',
                  onPressed: enabled
                      ? () => controller.play('tolerance.start')
                      : null,
                ),
                TextButton(
                  onPressed: enabled ? widget.onChooseGame : null,
                  child: const Text('Выбрать другую игру'),
                ),
              ],
            ],
            const SizedBox(height: 24),
            const NightEyebrow('ОБЩИЙ СЧЁТ'),
            const SizedBox(height: 12),
            for (final score in game.scores)
              Text(
                '${snapshot.players.firstWhere((p) => p.id == score.playerId).name} · ${score.score}',
              ),
          ],
          const SizedBox(height: 12),
          const ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text('Правила «Шкалы терпения»'),
            children: [
              Padding(
                padding: EdgeInsets.only(bottom: 16),
                child: Text(toleranceRules),
              ),
            ],
          ),
          if (host && game.phase != 'finished')
            TextButton(
              onPressed: enabled ? _cancel : null,
              child: const Text('Отменить партию'),
            ),
        ],
      ),
    );
  }

  Widget _scaleCard(
    int index,
    String text, {
    Key? key,
    bool highlighted = false,
  }) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: NightColors.background,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(
        color: highlighted ? NightColors.lilac : NightColors.divider,
      ),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (highlighted)
          const Padding(
            padding: EdgeInsets.only(bottom: 6),
            child: Text(
              'КАРТОЧКА ДЛЯ ДОГАДКИ',
              style: TextStyle(
                color: NightColors.lilac,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 1,
              ),
            ),
          ),
        Text('${index + 1}. $text', key: key),
      ],
    ),
  );

  void _move(List<String> current, int from, int delta) {
    final next = List<String>.of(current);
    final value = next.removeAt(from);
    next.insert(from + delta, value);
    setState(() => _order = next);
  }
}
