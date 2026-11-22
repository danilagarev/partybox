import 'dart:math';

import 'package:flutter/material.dart';
import 'package:partybox_game_core/partybox_game_core.dart';

import '../design/night_components.dart';
import '../design/night_theme.dart';
import '../design/night_scene.dart';
import 'clues_pack.dart';

class CluesRulesScreen extends StatelessWidget {
  const CluesRulesScreen({super.key, this.onOpenRoom});
  final VoidCallback? onOpenRoom;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('ЧТО ОБЪЕДИНЯЕТ?')),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const NightScene(kind: NightSceneKind.clues, height: 150),
              const SizedBox(height: 20),
              const NightEyebrow('ОДНА ДОГАДКА. ВСЁ БЛИЖЕ.'),
              const SizedBox(height: 16),
              Text(
                'Разные намёки.\nОдин ответ.',
                style: Theme.of(context).textTheme.headlineLarge,
              ),
              const SizedBox(height: 24),
              const NightRule(
                number: '01',
                title: 'Найдите ответ',
                text:
                    'Открывайте подсказки и угадывайте предмет, место или понятие. В партии пять заданий.',
              ),
              const NightRule(
                number: '02',
                title: 'Раньше — больше очков',
                text:
                    'За ответ после первой подсказки — 4 очка, затем 3, 2 и 1. Максимум за партию — 20.',
              ),
              const NightRule(
                number: '03',
                title: 'Ошибаться можно',
                text:
                    'Одна попытка на подсказку. Не угадали? Откройте следующую и попробуйте снова. Лучше короткий ответ: принимаются предусмотренные варианты, без проверки свободных объяснений.',
              ),
              const SizedBox(height: 24),
              const NightEyebrow('КАК БУДЕТЕ ИГРАТЬ?'),
              const SizedBox(height: 12),
              const Text(
                'Одному · без интернета и таймера. Открывайте подсказки в своём темпе.',
              ),
              const SizedBox(height: 12),
              NightButton(
                label: 'Играть одному',
                onPressed: () => Navigator.of(context).push<void>(
                  NightRoute(builder: (_) => const CluesGameScreen()),
                ),
              ),
              if (onOpenRoom != null) ...[
                const SizedBox(height: 20),
                const Text(
                  'С друзьями · у каждого свой телефон. Подсказки общие, ответы тайные. Следующую подсказку открывает ведущий. Нужен интернет.',
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: onOpenRoom,
                  child: const Text('Создать комнату «Что объединяет?»'),
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}

class CluesGameScreen extends StatefulWidget {
  const CluesGameScreen({super.key, this.packLoader, this.random});
  final Future<CluesPack> Function()? packLoader;
  final Random? random;

  @override
  State<CluesGameScreen> createState() => _CluesGameScreenState();
}

class _CluesGameScreenState extends State<CluesGameScreen> {
  static const _maxAnswerLength = 120;

  final _answer = TextEditingController();
  final _scroll = ScrollController();
  CluesDeck? _deck;
  CluesSession? _session;
  String? _validation;
  bool _loadFailed = false, _allowExit = false, _confirmingExit = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loadFailed = false);
    try {
      final pack = await (widget.packLoader ?? CluesPack.load)();
      if (!mounted) return;
      setState(() {
        _deck = CluesDeck(pack, random: widget.random);
        _session = _deck!.start();
      });
    } catch (_) {
      if (mounted) setState(() => _loadFailed = true);
    }
  }

  @override
  void dispose() {
    _answer.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _change(CluesSession next) {
    FocusScope.of(context).unfocus();
    _answer.clear();
    setState(() {
      _session = next;
      _validation = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
    });
  }

  void _submit() {
    if (_session?.canAnswer != true) return;
    final answer = _answer.text;
    if (answer.runes.length > _maxAnswerLength) {
      setState(() => _validation = 'Не больше $_maxAnswerLength символов');
      return;
    }
    if (normalizeCluesAnswer(answer).isEmpty) {
      setState(() => _validation = 'Напишите свой ответ');
      return;
    }
    _change(_session!.answer(answer));
  }

  Future<void> _confirmExit() async {
    if (_confirmingExit) return;
    _confirmingExit = true;
    final leave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Завершить партию?'),
        content: const SingleChildScrollView(
          child: Text('Текущий результат будет потерян.'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Продолжить игру'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Завершить'),
          ),
        ],
      ),
    );
    _confirmingExit = false;
    if (leave == true && mounted) {
      setState(() => _allowExit = true);
      await WidgetsBinding.instance.endOfFrame;
      if (mounted) Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final game = _session;
    return PopScope(
      canPop: _allowExit || game == null || game.phase == CluesPhase.finished,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmExit();
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('ЧТО ОБЪЕДИНЯЕТ?')),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: SingleChildScrollView(
                controller: _scroll,
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_loadFailed) ...[
                      const Text(
                        'Не удалось загрузить задания. Попробуйте ещё раз.',
                      ),
                      const SizedBox(height: 16),
                      NightButton(
                        label: 'Повторить загрузку',
                        onPressed: _load,
                      ),
                    ] else if (game == null) ...[
                      const Center(child: CircularProgressIndicator()),
                      const SizedBox(height: 16),
                      const Text(
                        'Готовим задания…',
                        textAlign: TextAlign.center,
                      ),
                    ] else if (game.phase == CluesPhase.finished)
                      ..._result(game)
                    else
                      ..._round(game),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _round(CluesSession game) => [
    NightStageProgress(
      labels: const ['Первое', 'Второе', 'Третье', 'Четвёртое', 'Пятое'],
      current: game.roundIndex,
    ),
    const SizedBox(height: 24),
    Wrap(
      spacing: 12,
      runSpacing: 8,
      children: [
        NightBadge('Задание ${game.roundIndex + 1} из 5'),
        NightBadge('Счёт: ${game.score}'),
      ],
    ),
    const SizedBox(height: 20),
    Text('Что объединяет?', style: Theme.of(context).textTheme.headlineMedium),
    const SizedBox(height: 8),
    Text(
      'Подсказка ${game.clueIndex + 1} из 4',
      style: const TextStyle(color: NightColors.muted),
    ),
    const SizedBox(height: 16),
    for (final (index, clue) in game.visibleClues.indexed) ...[
      NightPanel(
        padding: 20,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            NightEyebrow('ПОДСКАЗКА ${index + 1}'),
            const SizedBox(height: 8),
            Text(clue, style: const TextStyle(fontSize: 17, height: 1.4)),
          ],
        ),
      ),
      const SizedBox(height: 12),
    ],
    if (game.phase == CluesPhase.reveal) ...[
      Semantics(
        liveRegion: true,
        child: NightPanel(
          accent: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                game.roundPoints > 0
                    ? 'Верно! +${game.roundPoints}'
                    : 'Ответ на задание',
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 12),
              Text(
                game.revealedAnswer!,
                key: const ValueKey('clues-revealed-answer'),
                style: const TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                ),
              ),
              if (game.roundPoints == 0) ...[
                const SizedBox(height: 8),
                const Text('В этом задании — 0 очков. Попробуем следующее?'),
              ],
            ],
          ),
        ),
      ),
      const SizedBox(height: 20),
      NightButton(
        label: game.roundIndex == 4
            ? 'Посмотреть результат'
            : 'Следующее задание',
        onPressed: () => _change(game.nextRound()),
      ),
    ] else ...[
      if (game.attempt != null) ...[
        Semantics(
          liveRegion: true,
          child: const Text(
            'Пока не угадали. Откройте следующую подсказку и попробуйте снова.',
            style: TextStyle(color: NightColors.muted),
          ),
        ),
        const SizedBox(height: 12),
      ],
      TextField(
        key: const ValueKey('clues-answer'),
        controller: _answer,
        enabled: game.canAnswer,
        maxLength: _maxAnswerLength,
        textInputAction: TextInputAction.done,
        textCapitalization: TextCapitalization.sentences,
        decoration: InputDecoration(
          labelText: 'Ваш ответ',
          errorText: _validation,
        ),
        onSubmitted: (_) => _submit(),
      ),
      const SizedBox(height: 12),
      NightButton(
        label: 'Ответить · ${game.availablePoints} очк.',
        onPressed: game.canAnswer ? _submit : null,
      ),
      const SizedBox(height: 8),
      TextButton(
        onPressed: () => _change(game.nextHint()),
        child: Text(
          game.clueIndex == 3
              ? 'Показать ответ · 0 очков'
              : 'Следующая подсказка · ${game.availablePoints - 1} очк.',
        ),
      ),
    ],
  ];

  List<Widget> _result(CluesSession game) => [
    const NightEyebrow('ПЯТЬ ЗАДАНИЙ ПОЗАДИ'),
    const SizedBox(height: 24),
    const ExcludeSemantics(
      child: Icon(
        Icons.auto_awesome_rounded,
        color: NightColors.accent,
        size: 64,
      ),
    ),
    const SizedBox(height: 24),
    Text('Есть общее!', style: Theme.of(context).textTheme.headlineLarge),
    const SizedBox(height: 12),
    Text(
      '${game.score} из 20 очков',
      key: const ValueKey('clues-total-score'),
      style: const TextStyle(
        fontSize: 32,
        fontWeight: FontWeight.w800,
        color: NightColors.accent,
      ),
    ),
    const SizedBox(height: 12),
    const Text(
      'Иногда одной подсказки достаточно. Иногда интересно дойти до четвёртой.',
      style: TextStyle(color: NightColors.muted),
    ),
    const SizedBox(height: 28),
    NightButton(
      label: 'Ещё пять заданий',
      onPressed: () => _change(_deck!.start()),
    ),
    const SizedBox(height: 12),
    TextButton(
      onPressed: () => Navigator.of(context).popUntil((route) => route.isFirst),
      child: const Text('К выбору игр'),
    ),
  ];
}
