import 'package:flutter/material.dart';

import '../design/night_components.dart';
import '../design/night_theme.dart';
import '../truth/truth_sources.dart';
import '../truth/truth_topics.dart';
import 'room_controller.dart';

class TruthPanel extends StatefulWidget {
  const TruthPanel({
    super.key,
    required this.controller,
    required this.onChooseGame,
  });

  final RoomController controller;
  final VoidCallback onChooseGame;

  @override
  State<TruthPanel> createState() => _TruthPanelState();
}

class _TruthPanelState extends State<TruthPanel> {
  bool? _answer;
  int? _stake;
  int? _lastConcealEpoch;

  Future<void> _cancel() async {
    final controller = widget.controller;
    final session = controller.snapshot?.truth?.sessionId;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Отменить партию?'),
        content: const Text('Все вернутся в лобби. Комната сохранится.'),
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
    if (mounted &&
        confirmed == true &&
        controller.online &&
        controller.snapshot?.truth?.sessionId == session) {
      await controller.play('truth.cancel');
    }
  }

  static String _answerLabel(bool? answer) => switch (answer) {
    true => 'Правда',
    false => 'Выдумка',
    null => '—',
  };

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final snapshot = controller.snapshot!;
    final game = snapshot.truth!;
    final result = game.result;
    final enabled =
        controller.online && !controller.hasPending && !controller.busy;
    final host = snapshot.hostId == snapshot.selfId;
    final initial = game.phase == 'initial';
    final betting = game.phase == 'betting';
    final finished = game.phase == 'finished';
    final submittedIds = initial ? game.initialAnsweredIds : game.betIds;
    final submitted = submittedIds.contains(snapshot.selfId);
    final theme = Theme.of(context).textTheme;

    if (_lastConcealEpoch != controller.roleConcealEpoch || submitted) {
      _lastConcealEpoch = controller.roleConcealEpoch;
      _answer = null;
      _stake = null;
    }
    final answer = _answer;
    final stake = _stake;
    String name(String id) =>
        snapshot.players.firstWhere((player) => player.id == id).name;

    return NightPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          NightEyebrow(
            finished
                ? 'ИТОГИ ПАРТИИ'
                : 'РАУНД ${game.roundIndex + 1} ИЗ ${game.roundCount}',
          ),
          if (finished) ...[
            const SizedBox(height: 12),
            Text(
              game.winners.length == 1 ? 'Победитель' : 'Победители',
              style: theme.headlineMedium,
            ),
            for (final id in game.winners)
              Text(name(id), style: theme.titleLarge),
            const SizedBox(height: 20),
          ],
          Text(
            truthTopicTitles[game.topic]!,
            style: theme.labelLarge?.copyWith(color: NightColors.muted),
          ),
          const SizedBox(height: 8),
          Text(game.statement, style: theme.headlineSmall),
          const SizedBox(height: 20),
          if (initial || betting) ...[
            Text(
              initial ? 'Первый тайный ответ' : 'Окончательный ответ и ставка',
              style: theme.titleLarge,
            ),
            const SizedBox(height: 8),
            if (submitted)
              const Text('Ваш ответ принят. Ждём остальных.')
            else ...[
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final value in [true, false])
                    ChoiceChip(
                      label: Text(_answerLabel(value)),
                      selected: answer == value,
                      onSelected: enabled
                          ? (_) => setState(() => _answer = value)
                          : null,
                    ),
                ],
              ),
              if (betting) ...[
                const SizedBox(height: 12),
                const Text('Сколько очков поставить?'),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final value in [1, 2, 3])
                      ChoiceChip(
                        label: Text('$value'),
                        selected: stake == value,
                        onSelected: enabled
                            ? (_) => setState(() => _stake = value)
                            : null,
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 12),
              NightButton(
                label: initial ? 'Отправить ответ' : 'Подтвердить ставку',
                onPressed:
                    enabled && answer != null && (initial || stake != null)
                    ? () => controller.play(
                        initial ? 'truth.initial' : 'truth.bet',
                        {'answer': answer, if (betting) 'stake': stake!},
                        snapshot,
                      )
                    : null,
              ),
            ],
            const SizedBox(height: 12),
            Semantics(
              liveRegion: true,
              child: Text(
                'Ответили ${submittedIds.length} из ${snapshot.players.length}',
                style: const TextStyle(color: NightColors.muted),
              ),
            ),
          ],
          if (game.phase == 'discussion') ...[
            Text('Обсудите утверждение', style: theme.titleLarge),
            const SizedBox(height: 8),
            const Text(
              'Все дали первый ответ. Обсудите, что кажется правдой, а что вызывает сомнения.',
            ),
            const SizedBox(height: 12),
            if (host)
              NightButton(
                label: 'Перейти к ставкам',
                onPressed: enabled
                    ? () =>
                          controller.play('truth.discussed', const {}, snapshot)
                    : null,
              )
            else
              const Text('Ведущий откроет ставки после обсуждения.'),
          ],
          if (result != null) ...[
            Text(_answerLabel(result.truth), style: theme.headlineMedium),
            const SizedBox(height: 8),
            Text(result.explanation),
            const SizedBox(height: 12),
            TruthSources(sources: result.sources),
            const SizedBox(height: 20),
            Text('Как ответили', style: theme.titleLarge),
            const SizedBox(height: 8),
            for (final choice in result.answers)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  '${name(choice.playerId)} · ${_answerLabel(choice.initialAnswer)} → '
                  '${_answerLabel(choice.answer)} · ставка ${choice.stake} '
                  '· ${choice.points > 0 ? '+' : ''}${choice.points}',
                ),
              ),
            const SizedBox(height: 12),
            Text('Общий счёт', style: theme.titleLarge),
            const SizedBox(height: 8),
            for (final score in game.scores)
              Text('${name(score.playerId)} · ${score.score}'),
            const SizedBox(height: 20),
            if (host)
              NightButton(
                label: finished
                    ? 'Выбрать игру'
                    : game.roundIndex + 1 == game.roundCount
                    ? 'Посмотреть итоги'
                    : 'Следующее утверждение',
                onPressed: enabled
                    ? finished
                          ? widget.onChooseGame
                          : () => controller.play(
                              'truth.next',
                              const {},
                              snapshot,
                            )
                    : null,
              )
            else if (!finished)
              const Text('Ждём решения ведущего.'),
          ],
          if (host && !finished)
            TextButton(
              onPressed: enabled ? _cancel : null,
              child: const Text('Отменить партию'),
            ),
        ],
      ),
    );
  }
}
