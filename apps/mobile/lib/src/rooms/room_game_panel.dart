import 'package:flutter/material.dart';
import '../design/night_components.dart';
import '../design/night_theme.dart';
import 'room_controller.dart';

class RoomGamePanel extends StatefulWidget {
  const RoomGamePanel({super.key, required this.controller});
  final RoomController controller;
  @override
  State<RoomGamePanel> createState() => _RoomGamePanelState();
}

class _RoomGamePanelState extends State<RoomGamePanel> {
  int _minutes = 5;
  String? _suspect;
  Future<void> _cancel() async {
    widget.controller.hideRole();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Отменить раунд?'),
        content: const Text(
          'Все вернутся в лобби. Комната и её участники сохранятся.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Продолжить игру'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Отменить раунд'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await widget.controller.play('spy.cancel');
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final snapshot = controller.snapshot!;
    final game = snapshot.game;
    final host = snapshot.hostId == snapshot.selfId;
    final enabled =
        !controller.busy && !controller.hasPending && controller.online;
    return NightPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (game == null || game.phase == 'results') ...[
            if (game?.result != null) ...[
              Text(
                game!.result!['winner'] == 'civilians'
                    ? 'Шпион раскрыт.'
                    : 'Шпион ушёл.',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 12),
              Text('Локация: ${game.result!['location']}'),
              Text(
                'Шпион: ${snapshot.players.firstWhere((p) => p.id == game.result!['spyId']).name}',
              ),
              const SizedBox(height: 20),
            ],
            if (host) ...[
              DropdownButtonFormField<int>(
                initialValue: _minutes,
                decoration: const InputDecoration(
                  labelText: 'Обсуждение, минут',
                ),
                items: [
                  for (var i = 3; i <= 15; i++)
                    DropdownMenuItem(value: i, child: Text('$i')),
                ],
                onChanged: enabled
                    ? (value) => setState(() => _minutes = value!)
                    : null,
              ),
              const SizedBox(height: 16),
              NightButton(
                label: game == null ? 'Начать партию' : 'Сыграть ещё',
                onPressed: enabled && snapshot.players.length >= 4
                    ? () => controller.play('spy.start', {
                        'discussionMinutes': _minutes,
                        'packId': 'spy-ru-base',
                      })
                    : null,
              ),
              if (snapshot.players.length < 4)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text('Для партии нужны хотя бы четыре участника.'),
                ),
            ] else
              const Text('Ведущий начнёт партию, когда все соберутся.'),
          ] else if (game.phase == 'distribution') ...[
            const NightEyebrow('ВАША КАРТОЧКА'),
            const SizedBox(height: 12),
            if (game.readyIds.contains(snapshot.selfId))
              const Text('Роль подтверждена. Ждём остальных.')
            else if (controller.cardVisible) ...[
              Text(
                snapshot.card?.role == 'spy' ? 'Вы — шпион' : 'Вы знаете место',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 12),
              Text(
                snapshot.card?.role == 'spy'
                    ? 'Выясните локацию, не выдавая себя.'
                    : snapshot.card!.location!,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  color: NightColors.accent,
                ),
              ),
              const SizedBox(height: 20),
              NightButton(
                label: 'Скрыть и подтвердить',
                onPressed: enabled ? () => controller.play('spy.ready') : null,
              ),
            ] else
              NightButton(
                label: 'Показать мою роль',
                onPressed: enabled ? controller.revealRole : null,
              ),
            const SizedBox(height: 16),
            Text(
              'Готовы ${game.readyIds.length} из ${snapshot.players.length}',
            ),
          ] else if (game.phase == 'discussion') ...[
            const NightEyebrow('ОБСУЖДЕНИЕ'),
            const SizedBox(height: 12),
            Text(
              '${controller.remaining.inMinutes.toString().padLeft(2, '0')}:${(controller.remaining.inSeconds % 60).toString().padLeft(2, '0')}',
              style: Theme.of(context).textTheme.displaySmall,
            ),
            const SizedBox(height: 12),
            const Text(
              'Спрашивайте о месте. Найдите шпиона, не называя локацию.',
            ),
            if (controller.remaining == Duration.zero)
              const Text('Ждём завершения обсуждения на сервере.'),
            if (host) ...[
              const SizedBox(height: 20),
              NightButton(
                label: 'Завершить обсуждение',
                onPressed: enabled ? () => controller.play('spy.vote') : null,
              ),
            ],
          ] else if (game.phase == 'voting') ...[
            Text(
              'Кто здесь шпион?',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 12),
            const Text('Проголосуйте вслух. Ведущий подтвердит общий выбор.'),
            if (host) ...[
              RadioGroup<String>(
                groupValue: _suspect,
                onChanged: (value) {
                  if (enabled) setState(() => _suspect = value);
                },
                child: Column(
                  children: [
                    for (final (index, player) in snapshot.players.indexed)
                      RadioListTile<String>(
                        value: player.id,
                        title: Text('${index + 1}. ${player.name}'),
                        enabled: enabled,
                      ),
                  ],
                ),
              ),
              NightButton(
                label: 'Подтвердить выбор',
                onPressed: enabled && _suspect != null
                    ? () =>
                          controller.play('spy.accuse', {'suspectId': _suspect})
                    : null,
              ),
            ],
          ],
          if (host && game != null && game.phase != 'results') ...[
            const SizedBox(height: 12),
            TextButton(
              onPressed: enabled ? _cancel : null,
              child: const Text('Отменить раунд'),
            ),
          ],
        ],
      ),
    );
  }
}
