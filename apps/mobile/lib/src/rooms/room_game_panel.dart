import 'package:flutter/material.dart';
import '../design/night_components.dart';
import '../design/night_theme.dart';
import '../design/role_peek_card.dart';
import 'room_controller.dart';
import 'tolerance_panel.dart';
import 'clues_panel.dart';
import '../spy/local_session_adapter.dart';
import '../spy/spy_question_help.dart';

class RoomGamePanel extends StatefulWidget {
  const RoomGamePanel({
    super.key,
    required this.controller,
    this.initialGame,
    this.compactSpy = false,
  });
  final String? initialGame;
  final bool compactSpy;
  final RoomController controller;
  @override
  State<RoomGamePanel> createState() => _RoomGamePanelState();
}

class _RoomGamePanelState extends State<RoomGamePanel> {
  int _minutes = 5;
  String _selectedGame = 'spy';
  bool _chooseNextGame = false;
  String _packId = 'spy-ru-base';
  List<SpyPack>? _packs;
  bool _packLoadFailed = false;
  String? _suspect;
  Object? _ballotSelectionKey;

  @override
  void initState() {
    super.initState();
    _selectedGame = (widget.controller.snapshot?.protocolVersion ?? 0) >= 3
        ? widget.initialGame ?? 'spy'
        : 'spy';
    final game = widget.controller.snapshot?.game;
    if (game != null && game.phase != 'results') _selectedGame = 'spy';
    if (game != null) _packId = game.packId;
    // A deliberate catalogue choice can replace a completed game. A generic
    // return keeps its result, and an active game always remains authoritative.
    _chooseNextGame =
        (widget.controller.snapshot?.tolerance?.phase == 'finished' &&
            widget.initialGame != null &&
            widget.initialGame != 'tolerance') ||
        (widget.controller.snapshot?.clues?.phase == 'finished' &&
            widget.initialGame != null &&
            widget.initialGame != 'clues');
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
    final selectionKey = (game?.sessionId, game?.votingRound);
    if (selectionKey != _ballotSelectionKey) {
      _ballotSelectionKey = selectionKey;
      _suspect = null;
    }
    final host = snapshot.hostId == snapshot.selfId;
    final enabled =
        !controller.busy && !controller.hasPending && controller.online;
    final clues = snapshot.clues;
    if (clues != null && !_chooseNextGame) {
      return CluesPanel(
        key: ValueKey((clues.sessionId, clues.roundIndex)),
        controller: controller,
        onChooseGame: () => setState(() => _chooseNextGame = true),
      );
    }
    if (widget.compactSpy && game != null && game.phase != 'results') {
      return _compactSpy(context);
    }
    final tolerance = snapshot.tolerance;
    if (tolerance != null && !_chooseNextGame) {
      return TolerancePanel(
        key: ValueKey((
          tolerance.sessionId,
          tolerance.roundIndex,
          tolerance.phase,
        )),
        controller: controller,
        onChooseGame: () => setState(() => _chooseNextGame = true),
      );
    }
    final choosing = game == null || game.phase == 'results';
    if (choosing && game == null && !host && snapshot.protocolVersion >= 3) {
      return NightPanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Ждём начала игры',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 12),
            const Text(
              'Ведущий выбирает игру. Он начнёт партию, когда все соберутся.',
            ),
            const SizedBox(height: 12),
            const Text(
              'Ваше место в комнате сохранено. Пока можно пригласить остальных по коду.',
              style: TextStyle(color: NightColors.muted),
            ),
          ],
        ),
      );
    }
    final chooser = snapshot.protocolVersion >= 3 && choosing
        ? Padding(
            padding: const EdgeInsets.only(bottom: 20),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('Шпион'),
                  selected: _selectedGame == 'spy',
                  onSelected: host && enabled
                      ? (_) => setState(() => _selectedGame = 'spy')
                      : null,
                ),
                if (snapshot.protocolVersion >= 4)
                  ChoiceChip(
                    label: const Text('Что объединяет?'),
                    selected: _selectedGame == 'clues',
                    onSelected: host && enabled
                        ? (_) => setState(() => _selectedGame = 'clues')
                        : null,
                  ),
                ChoiceChip(
                  label: const Text('Шкала терпения'),
                  selected: _selectedGame == 'tolerance',
                  onSelected: host && enabled
                      ? (_) => setState(() => _selectedGame = 'tolerance')
                      : null,
                ),
              ],
            ),
          )
        : const SizedBox.shrink();
    if (choosing && _selectedGame == 'clues') {
      return NightPanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            chooser,
            Text(
              'Разные намёки. Один ответ.',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 16),
            const Text(
              'Пять заданий, по четыре подсказки. Ответьте раньше остальных: за верный ответ — 4, 3, 2 или 1 очко. После ошибки можно попробовать с новой подсказкой.',
            ),
            const SizedBox(height: 12),
            const Text(
              '1–12 игроков · подсказки открывает ведущий · ответы тайные',
            ),
            const SizedBox(height: 20),
            if (host)
              NightButton(
                label: 'Начать «Что объединяет?»',
                onPressed: enabled && snapshot.protocolVersion >= 4
                    ? () {
                        setState(() => _chooseNextGame = false);
                        controller.play('clues.start');
                      }
                    : null,
              )
            else
              const Text('Ведущий начнёт партию, когда все соберутся.'),
          ],
        ),
      );
    }
    if (choosing && _selectedGame == 'tolerance') {
      return NightPanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            chooser,
            Text(
              'Как хорошо вы знаете друг друга?',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 16),
            const Text(toleranceRules),
            const SizedBox(height: 16),
            const Text('4–12 игроков · каждый побывает героем · ответы тайные'),
            const SizedBox(height: 20),
            if (host)
              NightButton(
                label: 'Начать «Шкалу терпения»',
                onPressed: enabled && snapshot.players.length >= 4
                    ? () {
                        setState(() => _chooseNextGame = false);
                        controller.play('tolerance.start');
                      }
                    : null,
              )
            else
              const Text('Ведущий начнёт партию, когда все соберутся.'),
            if (snapshot.players.length < 4)
              const Text('Для партии нужны хотя бы четыре участника.'),
          ],
        ),
      );
    }
    return NightPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          chooser,
          if (game == null || game.phase == 'results') ...[
            if (snapshot.protocolVersion >= 3)
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text('Как играть в «Шпиона»'),
                children: [
                  Padding(
                    padding: EdgeInsets.only(bottom: 16),
                    child: Text(
                      'Один из вас — шпион, остальные знают одно место. '
                      'Посмотрите свою карточку и подтвердите готовность. '
                      'Задавайте друг другу вопросы о месте, не называя его. '
                      'Шпион старается не выдать себя. Когда время закончится, '
                      '${snapshot.protocolVersion >= 5 ? 'каждый тайно голосует со своего телефона. При ничьей — новый тур среди лидеров. ' : 'проголосуйте вслух: ведущий подтвердит общий выбор. '}'
                      'Нашли шпиона — победили остальные. Ошиблись — победил шпион.',
                    ),
                  ),
                ],
              ),
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
                const Text(
                  'Без повторов до конца набора',
                  style: TextStyle(color: NightColors.muted),
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
                secretBuilder: (context) => RoleSecretFace(
                  title: snapshot.card?.role == 'spy'
                      ? 'Вы — шпион'
                      : 'Вы знаете место',
                  message: snapshot.card?.role == 'spy'
                      ? 'Выясните локацию, не выдавая себя.'
                      : snapshot.card!.location!,
                  isSpy: snapshot.card?.role == 'spy',
                ),
              ),
            const SizedBox(height: 16),
            Text(
              'Готовы ${game.readyIds.length} из ${snapshot.players.length}',
            ),
            if (snapshot.protocolVersion >= 3)
              Text(
                'Ждём: ${snapshot.players.where((p) => !game.readyIds.contains(p.id)).map((p) => p.id == snapshot.selfId ? '${p.name} (вы)' : p.name).join(', ')}',
                style: const TextStyle(color: NightColors.muted),
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
            Text(_votingHint()),
            _votingChoices(enabled),
            if (game.votingRound != null || host)
              NightButton(
                label: _hasVoted
                    ? 'Голос принят'
                    : game.votingRound != null
                    ? 'Проголосовать'
                    : 'Подтвердить выбор',
                onPressed:
                    enabled &&
                        !_hasVoted &&
                        _suspect != null &&
                        (game.votingRound != null || host)
                    ? _submitVote
                    : null,
              ),
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

  bool get _hasVoted {
    final snapshot = widget.controller.snapshot!;
    return snapshot.game!.votedIds.contains(snapshot.selfId);
  }

  String _votingHint() {
    final snapshot = widget.controller.snapshot!;
    final game = snapshot.game!;
    if (game.votingRound == null) {
      return 'Проголосуйте вслух. Выбор подтвердит ведущий.';
    }
    return '${game.votingRound! > 1 ? 'Ничья. Тур ${game.votingRound} среди лидеров. ' : ''}'
        'Проголосовали ${game.votedIds.length} из ${snapshot.players.length}. '
        'Каждый голосует на своём телефоне.';
  }

  void _submitVote() {
    final game = widget.controller.snapshot!.game!;
    if (_suspect == null) return;
    widget.controller.play(
      game.votingRound != null ? 'spy.ballot' : 'spy.accuse',
      {
        'suspectId': _suspect,
        if (game.votingRound != null) 'round': game.votingRound,
      },
    );
  }

  Widget _votingChoices(bool enabled) {
    final snapshot = widget.controller.snapshot!;
    final game = snapshot.game!;
    final individual = game.votingRound != null;
    if (_hasVoted) {
      final chosen = snapshot.players.firstWhere(
        (p) => p.id == snapshot.card!.ballotSuspectId,
      );
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Semantics(
          liveRegion: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.check_circle_outline,
                color: NightColors.accent,
                size: 40,
              ),
              const SizedBox(height: 12),
              Text(
                'Ваш голос: ${chosen.name}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              const Text(
                'Выбор сохранён. Ждём остальных. До конца тура голоса закрыты.',
              ),
            ],
          ),
        ),
      );
    }
    if (!individual && snapshot.hostId != snapshot.selfId) {
      return const Text('Обсудите подозрения. Ведущий подтвердит общий выбор.');
    }
    return RadioGroup<String>(
      groupValue: _suspect,
      onChanged: (value) {
        if (enabled) setState(() => _suspect = value);
      },
      child: Column(
        children: [
          if (individual)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'Выберите подозреваемого. После отправки изменить голос нельзя.',
                style: TextStyle(color: NightColors.muted),
              ),
            ),
          for (final (index, player) in snapshot.players.indexed)
            if (!individual || game.candidateIds.contains(player.id))
              RadioListTile<String>(
                value: player.id,
                title: Text(
                  '${index + 1}. ${player.name}${player.id == snapshot.selfId ? ' (вы)' : ''}',
                ),
                enabled: enabled,
                dense: true,
              ),
        ],
      ),
    );
  }

  Widget _compactSpy(BuildContext context) {
    final controller = widget.controller;
    final snapshot = controller.snapshot!;
    final game = snapshot.game!;
    final host = snapshot.hostId == snapshot.selfId;
    final enabled =
        controller.online && !controller.busy && !controller.hasPending;
    final ready = game.readyIds.contains(snapshot.selfId);
    final label = switch (game.phase) {
      'distribution' =>
        ready
            ? 'Роль подтверждена'
            : controller.cardVisible
            ? 'Скрыть и подтвердить'
            : 'Подтвердить роль',
      'discussion' => 'Завершить обсуждение',
      _ =>
        _hasVoted
            ? 'Голос принят'
            : game.votingRound != null
            ? 'Проголосовать'
            : 'Подтвердить выбор',
    };
    VoidCallback? action;
    if (enabled &&
        game.phase == 'distribution' &&
        controller.roleViewed &&
        !ready) {
      action = () => controller.play('spy.ready');
    } else if (enabled && host && game.phase == 'discussion') {
      action = () => controller.play('spy.vote');
    } else if (enabled &&
        (game.votingRound != null || host) &&
        game.phase == 'voting' &&
        !_hasVoted &&
        _suspect != null) {
      action = _submitVote;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(switch (game.phase) {
          'distribution' => 'Посмотрите свою карточку',
          'discussion' => 'Обсуждение',
          _ =>
            game.votingRound != null
                ? 'Кто здесь шпион?'
                : 'Кого подозревает компания?',
        }, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(
          game.phase == 'distribution'
              ? 'Готовы ${game.readyIds.length} из ${snapshot.players.length}'
              : game.phase == 'voting'
              ? _votingHint()
              : 'Задавайте вопросы о месте, не называя его.',
          style: const TextStyle(color: NightColors.muted),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: LayoutBuilder(
            builder: (context, space) {
              if (game.phase == 'distribution') {
                if (ready) {
                  return const Center(
                    child: Text('Роль скрыта. Ждём остальных.'),
                  );
                }
                return SingleChildScrollView(
                  child: RolePeekCard(
                    key: ValueKey((
                      'room-peek',
                      game.sessionId,
                      snapshot.selfId,
                    )),
                    compact: true,
                    surfaceHeight: (space.maxHeight - 60).clamp(176, 480),
                    showSafetyHint: false,
                    showContinue: false,
                    revealed: controller.cardVisible,
                    enabled: enabled,
                    viewed: controller.roleViewed,
                    concealEpoch: controller.roleConcealEpoch,
                    onReveal: controller.revealRole,
                    onConceal: controller.hideRole,
                    onContinue: () => controller.play('spy.ready'),
                    continueLabel: 'Скрыть и подтвердить',
                    closedContinueLabel: 'Подтвердить роль',
                    secretBuilder: (_) => RoleSecretFace(
                      title: snapshot.card?.role == 'spy'
                          ? 'Вы — шпион'
                          : 'Вы знаете место',
                      message: snapshot.card?.role == 'spy'
                          ? 'Выясните локацию, не выдавая себя.'
                          : snapshot.card!.location!,
                      isSpy: snapshot.card?.role == 'spy',
                    ),
                  ),
                );
              }
              if (game.phase == 'discussion') {
                return SingleChildScrollView(
                  child: Column(
                    children: [
                      const SizedBox(height: 12),
                      Semantics(
                        label:
                            'Осталось ${controller.remaining.inMinutes} минут ${controller.remaining.inSeconds % 60} секунд',
                        excludeSemantics: true,
                        child: Text(
                          '${controller.remaining.inMinutes}:${(controller.remaining.inSeconds % 60).toString().padLeft(2, '0')}',
                          style: Theme.of(context).textTheme.displayLarge
                              ?.copyWith(color: NightColors.accent),
                        ),
                      ),
                      const SizedBox(height: 20),
                      const SpyQuestionHelp(),
                      if (controller.remaining == Duration.zero)
                        const Text('Ждём завершения обсуждения на сервере.'),
                    ],
                  ),
                );
              }
              return SingleChildScrollView(child: _votingChoices(enabled));
            },
          ),
        ),
        if (controller.error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Semantics(
              liveRegion: true,
              child: Text(
                controller.error!.message,
                style: const TextStyle(color: NightColors.error),
              ),
            ),
          ),
        const SizedBox(height: 8),
        if (!controller.online || controller.hasPending)
          TextButton.icon(
            onPressed: controller.busy ? null : controller.retry,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Восстановить связь'),
          ),
        Row(
          children: [
            Expanded(
              child:
                  game.phase == 'distribution' ||
                      host ||
                      game.votingRound != null
                  ? NightButton(label: label, onPressed: action)
                  : const Text(
                      'Дальше перейдёт ведущий.',
                      style: TextStyle(color: NightColors.muted),
                    ),
            ),
            if (host)
              IconButton(
                tooltip: 'Отменить раунд',
                onPressed: enabled ? _cancel : null,
                icon: const Icon(Icons.close_rounded),
              ),
          ],
        ),
      ],
    );
  }
}
