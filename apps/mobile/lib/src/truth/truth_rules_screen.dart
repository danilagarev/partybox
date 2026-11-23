import 'dart:math';

import 'package:flutter/material.dart';
import 'package:partybox_game_core/partybox_game_core.dart';

import '../design/night_components.dart';
import 'truth_pack.dart';
import 'truth_sources.dart';
import 'truth_topics.dart';

class TruthRulesScreen extends StatelessWidget {
  const TruthRulesScreen({super.key, required this.onOpenRoom});

  final VoidCallback onOpenRoom;

  @override
  Widget build(BuildContext context) => _TruthLayout(
    title: 'Не может быть!',
    child: _TruthRulesBody(onOpenRoom: onOpenRoom),
  );
}

class _TruthRulesBody extends StatelessWidget {
  const _TruthRulesBody({required this.onOpenRoom});

  final VoidCallback onOpenRoom;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const NightRule(
        number: '01',
        title: 'Решите, правда ли это',
        text: 'В каждом из десяти раундов все сначала отвечают тайно.',
      ),
      const NightRule(
        number: '02',
        title: 'Обсудите утверждение',
        text: 'Убеждайте друг друга. После обсуждения можно изменить ответ.',
      ),
      const NightRule(
        number: '03',
        title: 'Сделайте ставку',
        text:
            'Поставьте от 1 до 3 очков. Угадали — прибавьте ставку, ошиблись — вычтите.',
      ),
      const SizedBox(height: 20),
      NightButton(
        label: 'На одном телефоне',
        onPressed: () => Navigator.of(
          context,
        ).push<void>(NightRoute(builder: (_) => const TruthLocalSetup())),
      ),
      const SizedBox(height: 12),
      OutlinedButton(
        onPressed: onOpenRoom,
        child: const Text('На отдельных телефонах'),
      ),
    ],
  );
}

class TruthLocalSetup extends StatefulWidget {
  const TruthLocalSetup({super.key, this.loadCards = loadTruthCards});

  final Future<List<TruthCard>> Function() loadCards;

  @override
  State<TruthLocalSetup> createState() => _TruthLocalSetupState();
}

class _TruthLocalSetupState extends State<TruthLocalSetup> {
  final _form = GlobalKey<FormState>();
  final _names = <TextEditingController>[];
  final _topics = <String>{};
  final _random = Random();
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _addPlayer();
    _addPlayer();
  }

  void _addPlayer() {
    _names.add(TextEditingController(text: 'Игрок ${_names.length + 1}'));
  }

  @override
  void dispose() {
    for (final name in _names) {
      name.dispose();
    }
    super.dispose();
  }

  Future<void> _start() async {
    if (_loading || !_form.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    final names = _names.map((name) => name.text.trim()).toList();
    final topics = Set<String>.of(_topics);
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final cards = drawTruthCards(await widget.loadCards(), topics, _random);
      final session = TruthSession(names, cards);
      if (!mounted) return;
      setState(() => _loading = false);
      await Navigator.of(context).push<void>(
        NightRoute(builder: (_) => _TruthLocalGame(session: session)),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Не удалось загрузить карточки. Попробуйте ещё раз.';
      });
    }
  }

  @override
  Widget build(BuildContext context) => _TruthLayout(
    title: 'Подготовка',
    child: Form(
      key: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const NightEyebrow('ТЕМЫ'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              FilterChip(
                label: const Text('Всё вперемешку'),
                selected: _topics.isEmpty,
                onSelected: _loading ? null : (_) => setState(_topics.clear),
              ),
              for (final entry in truthTopicTitles.entries)
                FilterChip(
                  label: Text(entry.value),
                  selected: _topics.contains(entry.key),
                  onSelected: _loading
                      ? null
                      : (selected) => setState(() {
                          if (selected) {
                            _topics.add(entry.key);
                          } else {
                            _topics.remove(entry.key);
                          }
                        }),
                ),
            ],
          ),
          const SizedBox(height: 20),
          const NightEyebrow('ИГРОКИ'),
          for (final (index, name) in _names.indexed)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: TextFormField(
                key: ObjectKey(name),
                controller: name,
                enabled: !_loading,
                maxLength: 40,
                decoration: InputDecoration(
                  labelText: 'Имя игрока ${index + 1}',
                  counterText: '',
                ),
                validator: (value) => value == null || value.trim().isEmpty
                    ? 'Введите имя'
                    : null,
              ),
            ),
          Wrap(
            children: [
              TextButton(
                onPressed: _loading || _names.length == 12
                    ? null
                    : () => setState(_addPlayer),
                child: const Text('Добавить игрока'),
              ),
              if (_names.length > 2)
                TextButton(
                  onPressed: _loading
                      ? null
                      : () {
                          final controller = _names.last;
                          setState(_names.removeLast);
                          WidgetsBinding.instance.addPostFrameCallback(
                            (_) => controller.dispose(),
                          );
                        },
                  child: const Text('Убрать последнего'),
                ),
            ],
          ),
          if (_error case final error?) Text(error),
          const SizedBox(height: 12),
          NightButton(
            label: _loading ? 'Загружаем карточки…' : 'Начать партию',
            onPressed: _loading ? null : _start,
          ),
        ],
      ),
    ),
  );
}

class _TruthLocalGame extends StatefulWidget {
  const _TruthLocalGame({required this.session});

  final TruthSession session;

  @override
  State<_TruthLocalGame> createState() => _TruthLocalGameState();
}

class _TruthLocalGameState extends State<_TruthLocalGame>
    with WidgetsBindingObserver {
  bool _handedOff = false;
  bool? _answer;
  int _stake = 1;
  bool _allowPop = false;
  bool _confirmingExit = false;

  TruthSession get _session => widget.session;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && _handedOff) setState(_hideTurn);
  }

  void _hideTurn() {
    _handedOff = false;
    _answer = null;
    _stake = 1;
  }

  Future<void> _requestExit() async {
    if (_confirmingExit) return;
    _confirmingExit = true;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Завершить партию?'),
        content: const Text('Текущий счёт и ответы сбросятся.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Продолжить игру'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Завершить'),
          ),
        ],
      ),
    );
    _confirmingExit = false;
    if (confirmed != true || !mounted) return;
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  @override
  Widget build(BuildContext context) {
    final phase = _session.phase;
    return PopScope(
      canPop: _allowPop || phase == TruthPhase.finished,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _requestExit();
      },
      child: _TruthLayout(
        scrollKey: ValueKey((_session.roundIndex, phase, _session.turnIndex)),
        title: 'Не может быть!',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            NightEyebrow(
              phase == TruthPhase.finished
                  ? 'ИТОГИ'
                  : 'РАУНД ${_session.roundIndex + 1} ИЗ $truthRoundCount',
            ),
            const SizedBox(height: 12),
            if (phase != TruthPhase.finished)
              NightPanel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(truthTopicTitles[_session.topic]!),
                    const SizedBox(height: 12),
                    Text(
                      _session.statement,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 20),
            switch (phase) {
              TruthPhase.initial || TruthPhase.betting => _turn(phase),
              TruthPhase.discussion => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Обсудите утверждение. После обсуждения каждый сможет изменить ответ и сделать ставку.',
                  ),
                  const SizedBox(height: 16),
                  NightButton(
                    label: 'Перейти к ставкам',
                    onPressed: () => setState(_session.finishDiscussion),
                  ),
                ],
              ),
              TruthPhase.reveal => _reveal(),
              TruthPhase.finished => _finish(),
            },
          ],
        ),
      ),
    );
  }

  Widget _turn(TruthPhase phase) {
    final player = _session.players[_session.turnIndex!];
    final betting = phase == TruthPhase.betting;
    if (!_handedOff) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Передайте телефон: $player'),
          const SizedBox(height: 12),
          NightButton(
            label: betting ? 'Сделать ставку' : 'Ответить тайно',
            onPressed: () => setState(() {
              _answer = _session.currentInitial;
              _handedOff = true;
            }),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          betting
              ? '$player, подтвердите ответ и ставку'
              : '$player, ваш ответ',
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          children: [
            for (final (value, title) in [(true, 'Правда'), (false, 'Выдумка')])
              ChoiceChip(
                label: Text(title),
                selected: _answer == value,
                onSelected: (_) => setState(() => _answer = value),
              ),
          ],
        ),
        if (betting)
          Wrap(
            spacing: 8,
            children: [
              for (var stake = 1; stake <= 3; stake++)
                ChoiceChip(
                  label: Text('Ставка $stake'),
                  selected: _stake == stake,
                  onSelected: (_) => setState(() => _stake = stake),
                ),
            ],
          ),
        const SizedBox(height: 12),
        NightButton(
          label: betting ? 'Подтвердить ставку' : 'Подтвердить ответ',
          onPressed: _answer == null
              ? null
              : () => setState(() {
                  if (betting) {
                    _session.bet(_answer!, _stake);
                  } else {
                    _session.answerInitial(_answer!);
                  }
                  _hideTurn();
                }),
        ),
      ],
    );
  }

  String _verdict(bool value) => value ? 'Правда' : 'Выдумка';

  Widget _reveal() {
    final card = _session.revealed!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          _verdict(card.truth),
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        Text(card.explanation),
        TruthSources(sources: card.sources),
        const Divider(),
        for (final (i, answer) in _session.answers.indexed)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(_session.players[i]),
            subtitle: Text(
              answer.initial == answer.answer
                  ? _verdict(answer.answer)
                  : '${_verdict(answer.initial)} → ${_verdict(answer.answer)}',
            ),
            trailing: Text('${answer.points > 0 ? '+' : ''}${answer.points}'),
          ),
        _scores(),
        const SizedBox(height: 16),
        NightButton(
          label: _session.roundIndex + 1 == truthRoundCount
              ? 'Показать итоги'
              : 'Следующий раунд',
          onPressed: () => setState(_session.next),
        ),
      ],
    );
  }

  Widget _scores() {
    final ranked = _session.scores.indexed.toList()
      ..sort((a, b) {
        final score = b.$2.compareTo(a.$2);
        return score == 0 ? a.$1.compareTo(b.$1) : score;
      });
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const NightEyebrow('ОБЩИЙ СЧЁТ'),
        for (final (i, score) in ranked)
          Text('${_session.players[i]} · $score'),
      ],
    );
  }

  Widget _finish() {
    final winners = _session.winners.map((i) => _session.players[i]).join(', ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '${_session.winners.length == 1 ? 'Победитель' : 'Ничья'}: $winners',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 16),
        _scores(),
        const SizedBox(height: 16),
        NightButton(
          label: 'Сыграть ещё',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}

class _TruthLayout extends StatelessWidget {
  const _TruthLayout({
    required this.title,
    required this.child,
    this.scrollKey,
  });

  final String title;
  final Widget child;
  final Key? scrollKey;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title)),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            key: scrollKey,
            padding: const EdgeInsets.all(24),
            children: [child],
          ),
        ),
      ),
    ),
  );
}
