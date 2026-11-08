import 'package:flutter/material.dart';
import '../design/night_components.dart';
import '../design/night_theme.dart';
import '../design/role_peek_card.dart';
import 'room_controller.dart';
import '../spy/local_session_adapter.dart';
import '../spy/spy_question_help.dart';

class RoomGamePanel extends StatefulWidget {
  const RoomGamePanel({super.key, required this.controller});
  final RoomController controller;
  @override
  State<RoomGamePanel> createState() => _RoomGamePanelState();
}

class _RoomGamePanelState extends State<RoomGamePanel> {
  int _minutes = 5;
  String _packId = 'spy-ru-base';
  List<SpyPack>? _packs;
  bool _packLoadFailed = false;
  String? _suspect;

  @override
  void initState() {
    super.initState();
    final game = widget.controller.snapshot?.game;
    if (game != null) _packId = game.packId;
    _loadPacks();
  }

  Future<void> _loadPacks() async {
    setState(() => _packLoadFailed = false);
    try {
      final packs = await SpyPack.loadAll();
      if (!mounted) return;
      setState(() {
        _packs = packs;
        if (!packs.any((p) => p.id == _packId)) _packId = packs.first.id;
      });
    } catch (_) {
      if (mounted) setState(() => _packLoadFailed = true);
    }
  }

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
              if (_packs != null) ...[
                DropdownButtonFormField<String>(
                  key: ValueKey('room-pack-$_packId'),
                  isExpanded: true,
                  initialValue: _packId,
                  decoration: const InputDecoration(labelText: 'Набор локаций'),
                  items: [
                    for (final pack in _packs!)
                      DropdownMenuItem(
                        value: pack.id,
                        child: Text(
                          pack.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: enabled
                      ? (id) => setState(() => _packId = id!)
                      : null,
                ),
                const SizedBox(height: 12),
                Text(_packs!.firstWhere((p) => p.id == _packId).description),
                Text(
                  _packs!.firstWhere((p) => p.id == _packId).rotationLabel,
                  style: const TextStyle(color: NightColors.muted),
                ),
                const SizedBox(height: 16),
              ] else if (_packLoadFailed)
                TextButton(
                  onPressed: _loadPacks,
                  child: const Text('Не удалось загрузить темы. Повторить'),
                )
              else
                const Text('Загружаем темы…'),
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
                onPressed:
                    enabled && _packs != null && snapshot.players.length >= 4
                    ? () => controller.play('spy.start', {
                        'discussionMinutes': _minutes,
                        'packId': _packId,
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
            else
              RolePeekCard(
                key: ValueKey(('room-peek', game.sessionId, snapshot.selfId)),
                revealed: controller.cardVisible,
                concealEpoch: controller.roleConcealEpoch,
                enabled: enabled,
                viewed: controller.roleViewed,
                onReveal: controller.revealRole,
                onConceal: controller.hideRole,
                onContinue: () => controller.play('spy.ready'),
                continueLabel: 'Скрыть и подтвердить',
                closedContinueLabel: 'Подтвердить роль',
                secretBuilder: (context) => Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        snapshot.card?.role == 'spy'
                            ? 'Вы — шпион'
                            : 'Вы знаете место',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineMedium,
                      ),
                      const SizedBox(height: 20),
                      Text(
                        snapshot.card?.role == 'spy'
                            ? 'Выясните локацию, не выдавая себя.'
                            : snapshot.card!.location!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                          color: NightColors.accent,
                        ),
                      ),
                    ],
                  ),
                ),
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
            const SpyQuestionHelp(),
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
