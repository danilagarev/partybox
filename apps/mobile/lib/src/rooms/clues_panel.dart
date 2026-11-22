import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:partybox_game_core/partybox_game_core.dart';
import '../design/night_components.dart';
import '../design/night_theme.dart';
import 'room_controller.dart';

class CluesPanel extends StatefulWidget {
  const CluesPanel({
    super.key,
    required this.controller,
    required this.onChooseGame,
  });
  final RoomController controller;
  final VoidCallback onChooseGame;
  @override
  State<CluesPanel> createState() => _CluesPanelState();
}

class _CluesPanelState extends State<CluesPanel> with WidgetsBindingObserver {
  final _answer = TextEditingController();
  final _form = GlobalKey<FormState>();
  bool _foreground = true;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didUpdateWidget(CluesPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.controller.online) _answer.clear();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _answer.clear();
    setState(() => _foreground = state == AppLifecycleState.resumed);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _answer.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    final game = widget.controller.snapshot!.clues!;
    final answer = _answer.text.trim();
    _answer.clear();
    await widget.controller.play('clues.answer', {
      'answer': answer,
      'clueIndex': game.clueIndex,
    });
  }

  Future<void> _end(bool cancel) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(cancel ? 'Завершить партию?' : 'Открыть ответ?'),
        content: Text(
          cancel
              ? 'Все вернутся в лобби. Участники останутся в комнате.'
              : 'Те, кто ещё не ответил, не получат очки за это задание.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Продолжить игру'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(cancel ? 'Завершить' : 'Открыть ответ'),
          ),
        ],
      ),
    );
    if (accepted == true && mounted) {
      await widget.controller.play(cancel ? 'clues.cancel' : 'clues.hint');
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final snapshot = controller.snapshot!;
    final game = snapshot.clues!;
    final personal = snapshot.privateClues;
    final host = snapshot.hostId == snapshot.selfId;
    final enabled =
        _foreground &&
        controller.online &&
        !controller.busy &&
        !controller.hasPending;
    final canAnswer =
        enabled &&
        game.phase == 'playing' &&
        personal?.correct != true &&
        !game.attemptedIds.contains(snapshot.selfId);
    String name(String id) =>
        snapshot.players.firstWhere((p) => p.id == id).name;
    return NightPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const NightEyebrow('ЧТО ОБЪЕДИНЯЕТ?'),
          const SizedBox(height: 12),
          Text(
            game.phase == 'finished'
                ? 'Пять разгадок позади.'
                : 'Задание ${game.roundIndex + 1} из ${game.roundCount}',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          if (game.phase == 'playing')
            Text(
              'Подсказка ${game.clueIndex + 1} из 4 · верный ответ — ${4 - game.clueIndex} очк.',
              style: const TextStyle(color: NightColors.muted),
            ),
          const SizedBox(height: 16),
          for (final (index, clue) in game.clues.indexed)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text('${index + 1}. $clue'),
            ),
          if (game.phase == 'playing') ...[
            if (!_foreground || !controller.online)
              const Text('Вернёмся к ответам после восстановления связи.')
            else if (personal?.correct == true)
              Semantics(
                liveRegion: true,
                child: Text(
                  'Верно! +${personal!.points} очк. Ждём остальных.',
                  style: const TextStyle(color: NightColors.accent),
                ),
              )
            else ...[
              if (personal?.answer != null &&
                  personal?.clueIndex == game.clueIndex)
                const Padding(
                  padding: EdgeInsets.only(bottom: 12),
                  child: Text(
                    'Пока не совпало. Следующая попытка — с новой подсказкой.',
                  ),
                ),
              if (canAnswer)
                Form(
                  key: _form,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextFormField(
                        key: const ValueKey('clues-network-answer'),
                        controller: _answer,
                        decoration: const InputDecoration(
                          labelText: 'Ваш ответ',
                        ),
                        textInputAction: TextInputAction.done,
                        inputFormatters: [
                          LengthLimitingTextInputFormatter(120),
                        ],
                        validator: (value) => (value ?? '').runes.length > 120
                            ? 'Не больше 120 символов.'
                            : normalizeCluesAnswer(value ?? '').isEmpty
                            ? 'Введите слово или короткую фразу.'
                            : null,
                        onFieldSubmitted: (_) => _submit(),
                      ),
                      const SizedBox(height: 12),
                      NightButton(label: 'Ответить', onPressed: _submit),
                    ],
                  ),
                ),
            ],
            const SizedBox(height: 16),
            Text(
              'Угадали ${game.solvedIds.length} из ${snapshot.players.length}',
              style: const TextStyle(color: NightColors.muted),
            ),
            if (host) ...[
              const SizedBox(height: 16),
              NightButton(
                label: game.clueIndex < 3
                    ? 'Следующая подсказка'
                    : 'Открыть ответ',
                onPressed: enabled
                    ? () {
                        FocusScope.of(context).unfocus();
                        if (game.clueIndex == 3) {
                          _end(false);
                        } else {
                          controller.play('clues.hint');
                        }
                      }
                    : null,
              ),
            ] else
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text('Следующую подсказку откроет ведущий.'),
              ),
          ] else ...[
            const Divider(),
            const Text(
              'ПРАВИЛЬНЫЙ ОТВЕТ',
              style: TextStyle(color: NightColors.muted),
            ),
            Text(
              game.result!['answer'] as String,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 12),
            for (final answer
                in (game.result!['answers'] as List)
                    .cast<Map<String, dynamic>>())
              Text(
                '${name(answer['playerId'] as String)}: ${answer['answer'] ?? 'без ответа'} · +${answer['points']}',
              ),
            const SizedBox(height: 16),
            const Text(
              'ОБЩИЙ СЧЁТ',
              style: TextStyle(color: NightColors.muted),
            ),
            for (final score in [
              ...game.scores,
            ]..sort((a, b) => b.score.compareTo(a.score)))
              Text('${name(score.playerId)} — ${score.score}'),
            const SizedBox(height: 16),
            if (game.phase == 'finished') ...[
              Text(
                'Победители: ${game.winners.map(name).join(', ')}',
                style: const TextStyle(color: NightColors.accent),
              ),
              const SizedBox(height: 16),
              if (host)
                NightButton(
                  label: 'Сыграть ещё',
                  onPressed: enabled
                      ? () => controller.play('clues.start')
                      : null,
                ),
              TextButton(
                onPressed: host && enabled ? widget.onChooseGame : null,
                child: const Text('Выбрать другую игру'),
              ),
            ] else if (host)
              NightButton(
                label: game.roundIndex == 4
                    ? 'Показать итоги'
                    : 'Следующее задание',
                onPressed: enabled ? () => controller.play('clues.next') : null,
              )
            else
              const Text('Дальше перейдёт ведущий.'),
          ],
          if (host && game.phase != 'finished')
            TextButton(
              onPressed: enabled ? () => _end(true) : null,
              child: const Text('Завершить партию'),
            ),
        ],
      ),
    );
  }
}
