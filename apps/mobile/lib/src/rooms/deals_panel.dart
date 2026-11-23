import 'package:flutter/material.dart';

import '../design/night_components.dart';
import '../design/night_theme.dart';
import 'deals_models.dart';
import 'deals_trading.dart';
import 'room_controller.dart';
import 'room_models.dart';

class DealsPanel extends StatefulWidget {
  const DealsPanel({
    super.key,
    required this.controller,
    required this.snapshot,
    required this.onChooseGame,
  });

  final RoomController controller;
  final RoomSnapshot snapshot;
  final VoidCallback onChooseGame;

  @override
  State<DealsPanel> createState() => _DealsPanelState();
}

class _DealsPanelState extends State<DealsPanel> {
  int _goalIndex = 0;
  DealsItem? _item;
  DealsCategory? _claim;
  int? _declaredValue;
  int _price = 1;

  RoomSnapshot get _view => widget.snapshot;
  DealsGame get _game => _view.deals!;
  DealsPrivate get _me => _view.privateDeals!;
  bool get _ready => _game.readyIds.contains(_view.selfId);
  bool get _host => _view.hostId == _view.selfId;
  bool get _enabled =>
      widget.controller.online &&
      !widget.controller.busy &&
      !widget.controller.hasPending;

  Future<void> _play(
    String action, [
    Map<String, dynamic> payload = const {},
  ]) => widget.controller.play('deals.$action', payload, _view);

  String _name(String id) =>
      _view.players.firstWhere((player) => player.id == id).name;

  static const _pass = <String, dynamic>{
    'itemId': null,
    'category': null,
    'value': null,
    'price': null,
  };

  @override
  Widget build(BuildContext context) {
    final phase = _game.phase;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _status(),
        if (_game.event case final event?
            when widget.controller.online && phase != DealsPhase.finished)
          Align(
            alignment: Alignment.centerLeft,
            child: ActionChip(
              avatar: const Icon(Icons.bolt_outlined, size: 18),
              label: Text(event.title),
              onPressed: () => _sheet<void>(event.title, [Text(event.text)]),
            ),
          ),
        const SizedBox(height: 16),
        if (!widget.controller.online && phase != DealsPhase.trading)
          const _Waiting('Подключаемся к комнате…')
        else ...[
          ...switch (phase) {
            DealsPhase.goals => _goals(),
            DealsPhase.listing => _listing(),
            DealsPhase.trading => [
              DealsTrading(
                key: const ValueKey('deals-trading'),
                controller: widget.controller,
                snapshot: _view,
              ),
            ],
            DealsPhase.market => _market(),
            DealsPhase.recap => _recap(),
            DealsPhase.finished => _finished(),
          },
          if (widget.controller.online) ...[
            const SizedBox(height: 14),
            _tools(),
          ],
        ],
      ],
    );
  }

  Widget _status() {
    final phase = _game.phase;
    final seconds = (widget.controller.remaining.inMilliseconds + 999) ~/ 1000;
    final timer =
        '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
    return Row(
      children: [
        Expanded(
          child: Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (phase != DealsPhase.goals && phase != DealsPhase.finished)
                _Chip('Раунд ${_game.round}/5'),
              if (_game.deadline != null)
                _Chip('Осталось $timer', icon: Icons.timer_outlined),
            ],
          ),
        ),
        if (phase != DealsPhase.finished &&
            widget.controller.online &&
            _me.goal != null)
          IconButton(
            tooltip: 'Тайная цель',
            icon: const Icon(Icons.lock_outline_rounded),
            onPressed: _showGoal,
          ),
        if (phase != DealsPhase.finished && widget.controller.online)
          _Chip(
            '${_me.balance}',
            icon: Icons.toll_rounded,
            semantics: '${_me.balance} монет',
          ),
      ],
    );
  }

  List<Widget> _goals() {
    if (_ready || _me.goalOptions.isEmpty) {
      return [const _Heading('Цель выбрана'), _waitForTable()];
    }
    final goal = _me.goalOptions[_goalIndex];
    return [
      const _Heading('Твоя тайная цель'),
      NightPanel(
        padding: 20,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.lock_outline_rounded,
                  color: NightColors.accent,
                ),
                const Spacer(),
                _Chip('+${goal.bonus} очков'),
              ],
            ),
            const SizedBox(height: 16),
            Text(goal.title, style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 6),
            Text(goal.text),
          ],
        ),
      ),
      const SizedBox(height: 16),
      NightButton(
        label: 'В игру',
        onPressed: _enabled ? () => _play('choose', {'goalId': goal.id}) : null,
      ),
      if (_me.goalOptions.length > 1)
        TextButton(
          onPressed: _enabled
              ? () => setState(() => _goalIndex = 1 - _goalIndex)
              : null,
          child: Text(_goalIndex == 0 ? 'Другая цель' : 'Первая цель'),
        ),
    ];
  }

  void _pick(DealsItem item) {
    setState(() {
      _item = item;
      _claim = item.category;
      _declaredValue = item.value;
      _price = item.value + 1;
    });
  }

  List<Widget> _listing() {
    if (_ready) {
      return [
        _Heading(_me.ownLotItem == null ? 'Ты пасуешь' : 'Чемодан выставлен'),
        _waitForTable(),
      ];
    }
    if (_item case final item?) return _confirmListing(item);
    return [
      const _Heading('Что продаёшь?'),
      if (_me.inventory.isEmpty) const _Waiting('Пока нечего продавать'),
      for (final item in _me.inventory) ...[
        _ItemTile(item: item, onTap: _enabled ? () => _pick(item) : null),
        const SizedBox(height: 8),
      ],
      TextButton(
        onPressed: _enabled ? () => _play('list', _pass) : null,
        child: const Text('Не выставлять'),
      ),
    ];
  }

  List<Widget> _confirmListing(DealsItem item) {
    final bluff = item.category != _claim || item.value != _declaredValue;
    return [
      const _Heading('Твой чемодан'),
      _ItemTile(item: item),
      const SizedBox(height: 12),
      NightPanel(
        padding: 16,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(child: Text('Просишь')),
                _step('Снизить цену', Icons.remove, _price > 1 ? -1 : null),
                SizedBox(
                  width: 38,
                  child: Text(
                    '$_price',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                _step('Повысить цену', Icons.add, _price < 15 ? 1 : null),
              ],
            ),
            const Divider(),
            Row(
              children: [
                Expanded(
                  child: Text(
                    bluff
                        ? 'Блеф · ${_claim!.label}, $_declaredValue'
                        : 'Честное объявление',
                    style: TextStyle(
                      color: bluff ? NightColors.lilac : NightColors.muted,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: _enabled ? () => _bluff(item) : null,
                  child: Text(bluff ? 'Изменить' : 'Блефовать'),
                ),
              ],
            ),
          ],
        ),
      ),
      const SizedBox(height: 16),
      NightButton(
        label: 'Выставить за $_price',
        onPressed: _enabled
            ? () => _play('list', {
                'itemId': item.id,
                'category': _claim!.name,
                'value': _declaredValue,
                'price': _price,
              })
            : null,
      ),
      TextButton(
        onPressed: _enabled ? () => setState(() => _item = null) : null,
        child: const Text('Другой товар'),
      ),
    ];
  }

  Widget _step(String label, IconData icon, int? change) => IconButton.outlined(
    tooltip: label,
    icon: Icon(icon),
    onPressed: !_enabled || change == null
        ? null
        : () => setState(() => _price += change),
  );

  Future<void> _bluff(DealsItem item) async {
    var category = _claim!;
    var value = _declaredValue!;
    final choice =
        await showModalBottomSheet<({DealsCategory category, int value})>(
          context: context,
          isScrollControlled: true,
          showDragHandle: true,
          useSafeArea: true,
          builder: (sheet) => StatefulBuilder(
            builder: (context, setSheetState) => SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _Heading('Что сказать покупателям?'),
                  const Text('Товар останется в чемодане.'),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      for (final option in DealsCategory.values)
                        ChoiceChip(
                          label: Text(option.label),
                          avatar: Icon(_categoryIcon(option), size: 16),
                          selected: category == option,
                          onSelected: (_) =>
                              setSheetState(() => category = option),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Text('Скажи, сколько он стоит'),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final amount in [2, 5, 8])
                        ChoiceChip(
                          label: Text('$amount мон.'),
                          selected: amount == value,
                          onSelected: (_) =>
                              setSheetState(() => value = amount),
                        ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  NightButton(
                    label: 'Сохранить объявление',
                    onPressed: () => Navigator.pop(sheet, (
                      category: category,
                      value: value,
                    )),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(sheet, (
                      category: item.category,
                      value: item.value,
                    )),
                    child: const Text('Сказать правду'),
                  ),
                ],
              ),
            ),
          ),
        );
    if (choice != null && mounted) {
      setState(() {
        _claim = choice.category;
        _declaredValue = choice.value;
      });
    }
  }

  List<Widget> _market() {
    if (_ready) {
      final purchase = _me.purchases
          .where((entry) => entry.round == _game.round)
          .firstOrNull;
      return [
        if (purchase == null)
          const _Heading('Рынок')
        else ...[
          const _Heading('Твоя покупка'),
          _ItemTile(item: purchase.item),
          Text('Заплатил: ${purchase.price} мон.'),
        ],
        _waitForTable(),
      ];
    }
    return [
      const _Heading('Открытый рынок'),
      for (final lot in _game.market) ...[
        _ItemTile(item: lot.item),
        const SizedBox(height: 10),
        NightButton(
          label: 'Взять за ${lot.price}',
          onPressed: _enabled && _me.balance >= lot.price
              ? () => _play('market', {'itemId': lot.item.id})
              : null,
        ),
        const SizedBox(height: 10),
      ],
      TextButton(
        onPressed: _enabled ? () => _play('market', {'itemId': null}) : null,
        child: const Text('Пропустить рынок'),
      ),
      Text(
        'При совпадении первым покупает ${_name(_game.marketPriorityId)}.',
        style: const TextStyle(color: NightColors.muted),
        textAlign: TextAlign.center,
      ),
    ];
  }

  Widget _waitForTable() {
    final waiting = _view.players
        .where(
          (player) =>
              player.id != _view.selfId && !_game.readyIds.contains(player.id),
        )
        .toList();
    return _Waiting(
      waiting.length == 1
          ? 'Ждём · ${waiting.single.name}'
          : 'Ждём остальных · ${_game.readyIds.length}/${_view.players.length}',
    );
  }

  List<Widget> _recap() {
    final sales = _game.sales
        .where((sale) => sale.round == _game.round)
        .toList();
    final purchases = _me.purchases.where((sale) => sale.round == _game.round);
    return [
      const _Heading('Раунд закрыт'),
      if (sales.isEmpty) const Text('Сделок не было.'),
      for (final purchase in purchases) ...[
        _ItemTile(item: purchase.item),
        const SizedBox(height: 8),
      ],
      if (sales.isNotEmpty)
        Text(
          'Сделок за раунд · ${sales.length}',
          style: const TextStyle(color: NightColors.muted),
        ),
      const SizedBox(height: 16),
      if (_ready)
        _waitForTable()
      else
        NightButton(
          label: _game.round == 5 ? 'К итогам' : 'Следующий раунд',
          onPressed: _enabled ? () => _play('next') : null,
        ),
    ];
  }

  List<Widget> _finished() {
    final results = [..._game.results!]
      ..sort((a, b) => b.total.compareTo(a.total));
    final winners = results.where(
      (result) => result.total == results.first.total,
    );
    return [
      _Heading(winners.length == 1 ? 'Победа' : 'Ничья'),
      NightPanel(
        accent: true,
        padding: 20,
        child: Column(
          children: [
            const Icon(
              Icons.emoji_events_outlined,
              size: 40,
              color: NightColors.ink,
            ),
            const SizedBox(height: 8),
            Text(
              winners.map((result) => _name(result.playerId)).join(', '),
              style: Theme.of(
                context,
              ).textTheme.headlineMedium?.copyWith(color: NightColors.ink),
              textAlign: TextAlign.center,
            ),
            Text('${results.first.total} очков'),
          ],
        ),
      ),
      const SizedBox(height: 12),
      for (final result in results)
        ExpansionTile(
          title: Text(_name(result.playerId)),
          subtitle: Text(
            'Монеты ${result.balance} · Товары ${result.goodsValue} · Цель +${result.bonus}',
          ),
          leading: const Icon(Icons.person_outline_rounded),
          children: [
            ListTile(
              title: Text(result.goal.title),
              subtitle: Text(result.goal.text),
            ),
            for (final item in result.inventory)
              ListTile(title: Text(item.name)),
          ],
        ),
      if (_game.revealedSales case final sales? when sales.isNotEmpty)
        ExpansionTile(
          title: const Text('Что было в чемоданах'),
          children: [
            for (final sale in sales)
              ListTile(
                title: Text(sale.purchase.item.name),
                subtitle: Text(
                  '${_name(sale.buyerId)} · Куплено за ${sale.purchase.price}',
                ),
              ),
          ],
        ),
      if (_host) ...[
        const SizedBox(height: 12),
        NightButton(
          label: 'Сыграть ещё',
          onPressed: _enabled ? () => _play('start') : null,
        ),
        TextButton(
          onPressed: _enabled ? widget.onChooseGame : null,
          child: const Text('Другая игра'),
        ),
      ],
    ];
  }

  Widget _tools() => Wrap(
    spacing: 8,
    runSpacing: 4,
    alignment: WrapAlignment.center,
    children: [
      if (_game.phase != DealsPhase.finished) ...[
        if (_game.phase != DealsPhase.listing)
          TextButton.icon(
            icon: const Icon(Icons.style_outlined, size: 18),
            label: Text('Рука · ${_me.inventory.length}'),
            onPressed: _showHand,
          ),
      ],
      TextButton.icon(
        icon: const Icon(Icons.help_outline, size: 18),
        label: const Text('Правила'),
        onPressed: _showRules,
      ),
    ],
  );

  Future<void> _showRules() async {
    final canCancel = _host && _enabled && _game.phase != DealsPhase.finished;
    final cancel = await _sheet<bool>(
      'Как играть',
      [
        const Text(
          'Выставь товар. Покупатели увидят только цену и то, что ты объявил.',
        ),
        const SizedBox(height: 10),
        const Text(
          'Торгуйтесь вслух. Купить, проверить и предложить свою цену можно на телефоне.',
        ),
        const SizedBox(height: 10),
        const Text('Для тайной цели купи хотя бы один товар у соперника.'),
        const SizedBox(height: 10),
        const Text('Очки — монеты, стоимость товаров и бонус за цель.'),
      ],
      footer: canCancel
          ? (sheet) => TextButton(
              onPressed: () => Navigator.pop(sheet, true),
              child: const Text('Отменить партию'),
            )
          : null,
    );
    if (cancel == true && mounted && _enabled) await _cancel();
  }

  Future<void> _showGoal() => _privateSheet(
    'Тайная цель',
    (personal) => [
      if (personal.goal case final goal?) ...[
        Text(goal.title),
        const SizedBox(height: 8),
        Text(goal.text),
        const SizedBox(height: 8),
        Text('Бонус +${goal.bonus}'),
      ],
    ],
  );

  Future<void> _showHand() => _privateSheet(
    'Твои товары',
    (personal) => [
      if (personal.inventory.isEmpty) const Text('Рука пуста'),
      for (final item in personal.inventory) ...[
        _ItemTile(item: item),
        const SizedBox(height: 8),
      ],
    ],
  );

  Future<void> _privateSheet(
    String title,
    List<Widget> Function(DealsPrivate) content,
  ) {
    final controller = widget.controller;
    final intent = _view;
    return _sheet<void>(title, [
      AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final current = controller.snapshot;
          if (current?.roomId != intent.roomId ||
              current?.selfId != intent.selfId ||
              current?.sessionId != intent.sessionId) {
            return const Text('Эта партия больше недоступна.');
          }
          final personal = current?.privateDeals;
          if (!controller.online || personal == null) {
            return const Text('Ждём восстановления связи.');
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: content(personal),
          );
        },
      ),
    ]);
  }

  Future<T?> _sheet<T>(
    String title,
    List<Widget> content, {
    Widget Function(BuildContext)? footer,
  }) => showModalBottomSheet<T>(
    context: context,
    useSafeArea: true,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Heading(title),
          ...content,
          if (footer != null) footer(context),
        ],
      ),
    ),
  );

  Future<void> _cancel() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Отменить партию?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Назад'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Отменить партию'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted && _enabled) await _play('cancel');
  }
}

IconData _categoryIcon(DealsCategory category) => switch (category) {
  DealsCategory.tech => Icons.memory_rounded,
  DealsCategory.art => Icons.palette_outlined,
  DealsCategory.jewelry => Icons.diamond_outlined,
  DealsCategory.antiques => Icons.hourglass_bottom_rounded,
  DealsCategory.toys => Icons.toys_outlined,
  DealsCategory.music => Icons.music_note_rounded,
};

class _ItemTile extends StatelessWidget {
  const _ItemTile({required this.item, this.onTap});
  final DealsItem item;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Material(
    borderRadius: BorderRadius.circular(18),
    color: NightColors.surface,
    child: ListTile(
      key: ValueKey('deals-item-${item.id}'),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: NightColors.divider),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
      onTap: onTap,
      leading: Icon(_categoryIcon(item.category), color: NightColors.accent),
      title: Text(item.name, style: Theme.of(context).textTheme.titleMedium),
      subtitle: Text(item.category.label),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Chip(
            'Стоит ${item.value}',
            semantics: 'Стоимость ${item.value} монет',
          ),
          if (onTap != null)
            const Icon(Icons.chevron_right_rounded, color: NightColors.muted),
        ],
      ),
    ),
  );
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Semantics(
      header: true,
      child: Text(text, style: Theme.of(context).textTheme.headlineMedium),
    ),
  );
}

class _Waiting extends StatelessWidget {
  const _Waiting(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Text(text, style: const TextStyle(color: NightColors.muted)),
    ),
  );
}

class _Chip extends StatelessWidget {
  const _Chip(this.label, {this.icon, this.semantics});
  final String label;
  final IconData? icon;
  final String? semantics;

  @override
  Widget build(BuildContext context) => Semantics(
    label: semantics,
    excludeSemantics: semantics != null,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: NightColors.raised,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 15, color: NightColors.accent),
              const SizedBox(width: 5),
            ],
            Text(label, style: Theme.of(context).textTheme.labelMedium),
          ],
        ),
      ),
    ),
  );
}
