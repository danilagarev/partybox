import 'package:flutter/material.dart';

import '../design/night_components.dart';
import '../design/night_theme.dart';
import 'deals_models.dart';
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
  String? _itemId;
  DealsCategory? _category;
  int? _value;
  int _price = 5;

  RoomSnapshot get _snapshot => widget.snapshot;
  DealsGame get _game => _snapshot.deals!;
  DealsPrivate get _personal => _snapshot.privateDeals!;
  bool get _host => _snapshot.hostId == _snapshot.selfId;
  bool get _ready => _game.readyIds.contains(_snapshot.selfId);
  bool get _enabled =>
      widget.controller.online &&
      !widget.controller.busy &&
      !widget.controller.hasPending;
  bool get _canBuy => !_personal.purchased && !_ready;
  bool get _canAct =>
      _enabled &&
      (_game.deadline == null || widget.controller.remaining > Duration.zero);

  Future<void> _play(
    String action, [
    Map<String, dynamic> payload = const {},
    RoomSnapshot? intent,
  ]) => widget.controller.play('deals.$action', payload, intent ?? _snapshot);

  String _name(String id) =>
      _snapshot.players.firstWhere((player) => player.id == id).name;

  @override
  Widget build(BuildContext context) {
    final phase = _game.phase;
    final theme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(phase),
        const SizedBox(height: 20),
        if (!widget.controller.online)
          const Text('Восстанавливаем связь с комнатой…')
        else ...[
          if (_game.event case final event?
              when phase != DealsPhase.finished) ...[
            _DealsCard(
              icon: Icons.bolt_rounded,
              title: event.title,
              caption: 'Событие раунда',
              description: event.text,
            ),
            const SizedBox(height: 16),
          ],
          ...switch (phase) {
            DealsPhase.goals => _goals(),
            DealsPhase.listing => _listing(),
            DealsPhase.trading => _trading(),
            DealsPhase.market => _market(),
            DealsPhase.recap => _recap(),
            DealsPhase.finished => _finished(),
          },
          if (phase != DealsPhase.finished) ...[
            const SizedBox(height: 16),
            if (_personal.goal case final goal?)
              _details('Ваша тайная цель', [
                Text(goal.title, style: theme.titleMedium),
                Text(_goalLabel(goal)),
              ]),
            if (phase != DealsPhase.listing)
              _details('Ваши товары (${_personal.inventory.length})', [
                for (final item in _personal.inventory) Text(_itemLabel(item)),
              ]),
            if (_personal.purchases.isNotEmpty)
              _details('История покупок', [
                for (final purchase in _personal.purchases.reversed)
                  Text('Раунд ${purchase.round} · ${_purchaseLabel(purchase)}'),
              ]),
            if (_host)
              TextButton(
                onPressed: _enabled ? _cancel : null,
                child: const Text('Отменить партию'),
              ),
          ],
        ],
      ],
    );
  }

  Widget _header(DealsPhase phase) {
    final inRound = phase != DealsPhase.goals && phase != DealsPhase.finished;
    final finished = phase == DealsPhase.finished;
    final seconds = _remainingSeconds;
    final title = switch (phase) {
      DealsPhase.goals => 'Выберите тайную цель',
      DealsPhase.listing => 'Выставьте закрытый лот',
      DealsPhase.trading => 'Торги',
      DealsPhase.market => 'Открытый рынок',
      DealsPhase.recap => 'Итоги раунда',
      DealsPhase.finished => 'Итоги партии',
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [NightColors.raised, NightColors.surface],
        ),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: NightColors.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const NightEyebrow('МУТНЫЕ СДЕЛКИ', color: NightColors.accent),
            const SizedBox(height: 8),
            Semantics(
              header: true,
              child: Text(
                title,
                style: Theme.of(context).textTheme.headlineMedium,
              ),
            ),
            if (inRound) ...[
              const SizedBox(height: 12),
              Text(
                'Раунд ${_game.round} из 5',
                style: const TextStyle(color: NightColors.muted),
              ),
              const SizedBox(height: 8),
              Row(
                spacing: 4,
                children: [
                  for (var round = 1; round <= 5; round++)
                    Expanded(
                      child: Container(
                        height: 4,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(4),
                          color: round <= _game.round
                              ? NightColors.accent
                              : NightColors.divider,
                        ),
                      ),
                    ),
                ],
              ),
            ],
            if (!finished) ...[
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (_game.deadline != null)
                    _DealsTag(
                      icon: Icons.timer_outlined,
                      label: _timerLabel(seconds),
                      semanticsLabel:
                          'Осталось ${seconds ~/ 60} мин ${seconds % 60} сек',
                      tone: seconds <= 10
                          ? NightColors.error
                          : NightColors.accent,
                    ),
                  if (widget.controller.online)
                    _DealsTag(
                      icon: Icons.account_balance_wallet_outlined,
                      label: 'Ваш баланс · ${_coinAmount(_personal.balance)}',
                    ),
                ],
              ),
              if (phase != DealsPhase.trading) ...[
                const SizedBox(height: 8),
                Text(
                  'Готовы ${_game.readyIds.length} из ${_snapshot.players.length}',
                  style: const TextStyle(color: NightColors.muted),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  int get _remainingSeconds {
    final remaining = widget.controller.remaining.inMilliseconds;
    return (remaining + 999) ~/ 1000;
  }

  String _timerLabel(int seconds) {
    final minutes = seconds ~/ 60;
    final part = (seconds % 60).toString().padLeft(2, '0');
    return 'Осталось $minutes:$part';
  }

  Widget _details(String title, List<Widget> children) => ExpansionTile(
    tilePadding: EdgeInsets.zero,
    childrenPadding: const EdgeInsets.only(bottom: 8),
    expandedCrossAxisAlignment: CrossAxisAlignment.start,
    title: Text(title),
    children: [
      if (children.isEmpty) const Text('Пока пусто.'),
      for (final child in children)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Align(alignment: Alignment.centerLeft, child: child),
        ),
    ],
  );

  String _itemLabel(DealsItem item) =>
      '${item.name} · ${item.category.label}, стоимость ${item.value}';

  String _goalLabel(DealsGoal goal) => '${goal.text} · Бонус +${goal.bonus}';

  String _purchaseLabel(DealsPurchase purchase) {
    final seller = purchase.sellerId;
    final source = seller == null ? 'Рынок' : _name(seller);
    return '$source · ${_itemLabel(purchase.item)} · Цена ${purchase.price}';
  }

  List<Widget> _goals() => [
    if (_ready || _personal.goal != null)
      const Text('Цель выбрана. Ждём остальных игроков.')
    else ...[
      const Text('Выберите одну из двух. Остальные увидят вашу цель в финале.'),
      for (final goal in _personal.goalOptions) ...[
        const SizedBox(height: 12),
        _DealsCard(
          icon: Icons.lock_outline,
          title: goal.title,
          description: _goalLabel(goal),
          actions: [
            NightButton(
              label: 'Выбрать «${goal.title}»',
              onPressed: _canAct
                  ? () => _play('choose', {'goalId': goal.id})
                  : null,
            ),
          ],
        ),
      ],
    ],
  ];

  List<Widget> _listing() {
    final inventory = _personal.inventory;
    final enabled = _canAct && !_ready;
    final canList =
        enabled && _itemId != null && _category != null && _value != null;
    return [
      if (_ready)
        const Text('Решение принято. Ждём остальных игроков.')
      else ...[
        const Text(
          'Выберите товар. Покупатели увидят только заявленные категорию, стоимость и цену. Заявление может отличаться от содержимого.',
        ),
        if (inventory.isNotEmpty) ...[
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            isExpanded: true,
            itemHeight: null,
            initialValue: _itemId,
            decoration: const InputDecoration(labelText: 'Ваш товар'),
            items: [
              for (final item in inventory)
                DropdownMenuItem(value: item.id, child: Text(_itemLabel(item))),
            ],
            onChanged: enabled
                ? (id) {
                    final item = inventory.firstWhere((item) => item.id == id);
                    setState(() {
                      _itemId = item.id;
                      _category = item.category;
                      _value = item.value;
                    });
                  }
                : null,
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<DealsCategory>(
            key: ValueKey(('listing-category', _itemId)),
            isExpanded: true,
            itemHeight: null,
            initialValue: _category,
            decoration: const InputDecoration(
              labelText: 'Категория в объявлении',
            ),
            items: [
              for (final category in DealsCategory.values)
                DropdownMenuItem(value: category, child: Text(category.label)),
            ],
            onChanged: enabled
                ? (category) => setState(() => _category = category)
                : null,
          ),
          const SizedBox(height: 12),
          _numberField(
            key: ValueKey(('listing-value', _itemId)),
            label: 'Стоимость в объявлении',
            value: _value,
            values: const [2, 5, 8],
            onChanged: enabled
                ? (value) => setState(() => _value = value)
                : null,
          ),
          const SizedBox(height: 12),
          _numberField(
            label: 'Цена продажи',
            value: _price,
            values: List.generate(15, (index) => index + 1),
            onChanged: enabled
                ? (price) => setState(() => _price = price)
                : null,
          ),
          const SizedBox(height: 12),
          NightButton(
            label: 'Выставить лот',
            onPressed: canList
                ? () => _play('list', {
                    'itemId': _itemId,
                    'category': _category!.name,
                    'value': _value,
                    'price': _price,
                  })
                : null,
          ),
        ] else
          const Text('У вас нет товаров для продажи.'),
        TextButton(
          onPressed: enabled
              ? () => _play('list', {
                  'itemId': null,
                  'category': null,
                  'value': null,
                  'price': null,
                })
              : null,
          child: const Text('Пропустить продажу'),
        ),
      ],
      if (_game.market.isNotEmpty) _details('Товары на рынке', _marketItems()),
    ];
  }

  List<Widget> _trading() {
    final offers = _personal.incomingOffers;
    final outgoing = _personal.outgoingOffer;
    final inspection = _personal.inspection;
    final playerLots = _game.lots.where(
      (lot) => lot.sellerId != _snapshot.selfId,
    );
    final ownLots = _game.lots.where((lot) => lot.sellerId == _snapshot.selfId);
    return [
      if (_personal.purchased) ...[
        ..._roundPurchases(),
        const SizedBox(height: 12),
        const Text('Вы уже купили товар в этом раунде.'),
        const SizedBox(height: 16),
      ],
      const Text(
        'Обсуждайте цену вслух. Подтверждайте покупки и встречные предложения на телефоне.',
      ),
      for (final lot in ownLots) ...[
        const SizedBox(height: 12),
        _DealsCard(
          icon: lot.sold ? Icons.check_rounded : Icons.work_outline_rounded,
          title: 'Ваш лот',
          caption: lot.sold ? 'Продан' : 'Цена · ${_coinAmount(lot.price)}',
          description:
              'Заявлено · ${lot.category.label}, стоимость ${lot.value}',
          children: [
            if (_personal.ownLotItem case final item?)
              Text('В чемодане · ${_itemLabel(item)}'),
          ],
        ),
      ],
      if (offers.isNotEmpty) ...[
        const SizedBox(height: 16),
        _DealsCard(
          icon: Icons.swap_horiz_rounded,
          title: 'Встречные предложения вам',
          highlighted: true,
          actions: [
            for (final offer in offers)
              OutlinedButton(
                onPressed: _canAct
                    ? () => _confirmTrade(
                        'Принять предложение?',
                        '${_name(offer.buyerId)} купит ваш товар за ${offer.price}.',
                        'Принять',
                        'accept',
                        {'buyerId': offer.buyerId},
                      )
                    : null,
                child: Text(
                  'Принять · ${_name(offer.buyerId)} · ${offer.price}',
                ),
              ),
          ],
        ),
      ],
      if (outgoing != null) ...[
        const SizedBox(height: 12),
        _DealsCard(
          icon: Icons.swap_horiz_rounded,
          title: 'Ваше предложение',
          description:
              'Вы предложили ${outgoing.price} за лот игрока ${_name(outgoing.sellerId)}${outgoing.insured ? ' · со страховкой' : ''}.',
          actions: [
            OutlinedButton(
              onPressed: _canAct && _canBuy
                  ? () => _play('offer', {
                      'sellerId': null,
                      'price': null,
                      'insured': false,
                    })
                  : null,
              child: const Text('Отозвать предложение'),
            ),
          ],
        ),
      ],
      if (inspection != null) ...[
        const SizedBox(height: 12),
        _DealsCard(
          icon: Icons.search_rounded,
          title: 'Проверка лота',
          caption: _name(inspection.sellerId),
          description: [
            if (inspection.category case final category?)
              'Категория · ${category.label}',
            if (inspection.value case final value?) 'Стоимость · $value',
            if (inspection.matches case final matches?)
              matches ? 'Категория совпадает' : 'Категория отличается',
          ].join(' · '),
        ),
      ],
      const SizedBox(height: 20),
      _sectionHeading('Чемоданы на торгах'),
      if (playerLots.isEmpty) ...[
        const SizedBox(height: 12),
        const Text('У других игроков нет лотов.'),
      ],
      for (final lot in playerLots) ...[
        const SizedBox(height: 12),
        _playerLot(lot),
      ],
      if (_game.market.isNotEmpty) _details('Товары на рынке', _marketItems()),
      const SizedBox(height: 12),
      if (_ready)
        const Text('Вы завершили торги. Ждём остальных игроков.')
      else
        OutlinedButton(
          onPressed: _canAct
              ? () => _confirmTrade(
                  'Завершить торги?',
                  'Ваше встречное предложение будет отозвано. Если вы ещё ничего не купили, сможете выбрать товар на рынке.',
                  'Завершить торги',
                  'done',
                )
              : null,
          child: const Text('Завершить торги'),
        ),
    ];
  }

  Widget _playerLot(DealsLot lot) {
    final available = _canAct && _canBuy && !lot.sold;
    final balance = _personal.balance;
    return _DealsCard(
      icon: lot.sold ? Icons.check_rounded : Icons.work_outline_rounded,
      title: _name(lot.sellerId),
      caption: lot.sold ? 'Продан' : 'Закрытый лот',
      description: 'Заявлено · ${lot.category.label}, стоимость ${lot.value}',
      tag: lot.sold ? null : 'Цена · ${_coinAmount(lot.price)}',
      actions: [
        if (!lot.sold && _canBuy) ...[
          NightButton(
            label: 'Купить',
            onPressed: available && balance >= lot.price
                ? () => _purchase(lot, offer: false)
                : null,
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: available && balance > 0
                    ? () => _purchase(lot, offer: true)
                    : null,
                child: const Text(
                  'Предложить цену',
                  textAlign: TextAlign.center,
                ),
              ),
              if (_personal.inspection == null)
                TextButton(
                  onPressed: available && balance >= _lowestInspectionCost()
                      ? () => _inspect(lot)
                      : null,
                  child: const Text('Проверить', textAlign: TextAlign.center),
                ),
            ],
          ),
        ],
      ],
    );
  }

  int _lowestInspectionCost() =>
      _game.event?.id == 'e-05' ? 1 : _game.inspectionCost;

  Future<void> _purchase(DealsLot lot, {required bool offer}) async {
    final intent = _snapshot;
    final cost = _game.insuranceCost;
    final payout = _game.insurancePayout;
    final balance = _personal.balance;
    final maxPrice = balance > 15 ? 15 : balance;
    final insurance = _personal.insuranceAvailable;
    final outgoing = _personal.outgoingOffer;
    final replacing = outgoing?.sellerId == lot.sellerId && offer;
    var price = offer
        ? (replacing ? outgoing!.price : lot.price).clamp(1, maxPrice)
        : lot.price;
    var insured = replacing && outgoing!.insured;
    final title = offer
        ? 'Встречное предложение'
        : 'Покупка по заявленной цене';
    final label = offer ? 'Отправить предложение' : 'Подтвердить покупку';
    final decision = await showDialog<({int price, bool insured})>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, refresh) => AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_name(lot.sellerId)),
                Text(
                  'Заявлено · ${lot.category.label}, стоимость ${lot.value}',
                ),
                const SizedBox(height: 12),
                if (offer)
                  _numberField(
                    label: 'Ваша цена',
                    value: price,
                    values: List.generate(maxPrice, (index) => index + 1),
                    onChanged: (value) => refresh(() => price = value),
                  )
                else
                  Text('Цена · $price'),
                if (offer && outgoing != null)
                  const Text('Новое предложение заменит предыдущее.'),
                if (insurance)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: insured,
                    onChanged: (value) =>
                        refresh(() => insured = value == true),
                    title: Text('Застраховать · ${_coinAmount(cost)}'),
                    subtitle: Text(
                      'Один полис за партию. Если товар стоит 2, выплата составит ${_coinAmount(payout)}.',
                    ),
                  ),
                if (price + (insured ? cost : 0) > balance)
                  const Text('На покупку со страховкой не хватает монет.'),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Назад'),
            ),
            TextButton(
              onPressed: price + (insured ? cost : 0) <= balance
                  ? () => Navigator.pop(dialogContext, (
                      price: price,
                      insured: insured,
                    ))
                  : null,
              child: Text(label),
            ),
          ],
        ),
      ),
    );
    if (decision != null && mounted) {
      await _play(offer ? 'offer' : 'buy', {
        'sellerId': lot.sellerId,
        if (offer) 'price': decision.price,
        'insured': decision.insured,
      }, intent);
    }
  }

  Future<void> _inspect(DealsLot lot) async {
    final intent = _snapshot;
    final cost = _game.inspectionCost;
    final balance = _personal.balance;
    final modes = [
      (id: 'category', label: 'Узнать категорию', price: cost),
      (id: 'value', label: 'Узнать стоимость', price: cost),
      if (_game.event?.id == 'e-05')
        (id: 'match', label: 'Сверить заявленную категорию', price: 1),
      if (_game.event?.id == 'e-06')
        (id: 'both', label: 'Узнать категорию и стоимость', price: 3),
    ];
    final mode = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Одна проверка за раунд'),
        children: [
          for (final mode in modes)
            SimpleDialogOption(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              onPressed: balance >= mode.price
                  ? () => Navigator.pop(context, mode.id)
                  : null,
              child: Text('${mode.label} · ${_coinAmount(mode.price)}'),
            ),
          SimpleDialogOption(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
            onPressed: () => Navigator.pop(context),
            child: const Text('Назад'),
          ),
        ],
      ),
    );
    if (mode != null && mounted) {
      await _play('inspect', {'sellerId': lot.sellerId, 'mode': mode}, intent);
    }
  }

  List<Widget> _marketItems() => [
    for (final lot in _game.market)
      Text('${_itemLabel(lot.item)} · Цена ${lot.price}'),
  ];

  List<Widget> _market() => [
    if (_personal.purchased) ...[
      ..._roundPurchases(),
      const SizedBox(height: 12),
      const Text('Вы уже купили товар в этом раунде.'),
    ] else if (_ready)
      const Text('Решение принято. Ждём остальных игроков.')
    else ...[
      Text(
        'Если несколько игроков выберут один товар, первым право покупки получит ${_name(_game.marketPriorityId)}. Приоритет меняется каждый раунд.',
      ),
      for (final lot in _game.market) ...[
        const SizedBox(height: 12),
        _DealsCard(
          icon: Icons.storefront_outlined,
          title: lot.item.name,
          description:
              '${lot.item.category.label} · Стоимость ${lot.item.value}',
          tag: 'Цена · ${_coinAmount(lot.price)}',
          actions: [
            NightButton(
              label: 'Выбрать «${lot.item.name}»',
              onPressed: _canAct && _personal.balance >= lot.price
                  ? () => _play('market', {'itemId': lot.item.id})
                  : null,
            ),
          ],
        ),
      ],
      TextButton(
        onPressed: _canAct ? () => _play('market', {'itemId': null}) : null,
        child: const Text('Пропустить покупку'),
      ),
    ],
  ];

  List<Widget> _roundPurchases() => [
    for (final purchase in _personal.purchases)
      if (purchase.round == _game.round)
        NightEntrance(
          key: ValueKey(('purchase', purchase.item.id)),
          child: _DealsCard(
            icon: Icons.receipt_long_outlined,
            title: purchase.item.name,
            caption: 'Ваша покупка',
            description:
                '${purchase.item.category.label} · Стоимость ${purchase.item.value}\n'
                'Продавец · ${purchase.sellerId == null ? 'Рынок' : _name(purchase.sellerId!)}',
            tag: 'Уплачено · ${_coinAmount(purchase.price)}',
            highlighted: true,
          ),
        ),
  ];

  List<Widget> _recap() {
    final sales = _game.sales.where((sale) => sale.round == _game.round);
    return [
      ..._roundPurchases(),
      if (_personal.purchased) const SizedBox(height: 16),
      if (sales.isEmpty)
        const Text('В этом раунде покупок не было.')
      else ...[
        _sectionHeading('Сделки раунда'),
        for (final sale in sales) ...[
          const SizedBox(height: 8),
          _DealsCard(
            icon: Icons.swap_horiz_rounded,
            title:
                '${sale.sellerId == null ? 'Рынок' : _name(sale.sellerId!)} → ${_name(sale.buyerId)}',
            description: '${sale.category.label} · Заявлено ${sale.value}',
            tag: 'Цена · ${_coinAmount(sale.price)}',
          ),
        ],
      ],
      const SizedBox(height: 16),
      if (_ready)
        const Text('Ждём остальных игроков.')
      else
        NightButton(
          label: _game.round == 5 ? 'Показать итоги партии' : 'Следующий раунд',
          onPressed: _canAct ? () => _play('next') : null,
        ),
    ];
  }

  List<Widget> _finished() {
    final results = [..._game.results!]
      ..sort((a, b) => b.total.compareTo(a.total));
    final winners = results
        .where((result) => result.total == results.first.total)
        .toList();
    return [
      _DealsCard(
        icon: Icons.emoji_events_outlined,
        title: winners.map((result) => _name(result.playerId)).join(', '),
        caption: winners.length == 1 ? 'Победа' : 'Ничья',
        tag: '${winners.first.total} очков',
        highlighted: true,
      ),
      const SizedBox(height: 16),
      _sectionHeading('Очки игроков'),
      for (final result in results)
        _details('${_name(result.playerId)} · ${result.total} очков', [
          Text(
            'Монеты ${result.balance} + товары ${result.goodsValue} + бонус ${result.bonus}',
          ),
          Text(
            result.goal.title,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          Text(_goalLabel(result.goal)),
          for (final item in result.inventory) Text(_itemLabel(item)),
        ]),
      if (_game.revealedSales case final sales? when sales.isNotEmpty)
        _details('Что было в лотах', [
          for (final sale in sales)
            Text(
              'Раунд ${sale.purchase.round} · ${_name(sale.buyerId)} купил товар · ${_purchaseLabel(sale.purchase)}'
              '${sale.purchase.sellerId == null ? '' : ' · Заявлено ${sale.purchase.category.label}, ${sale.purchase.value}'}',
            ),
        ]),
      if (_host) ...[
        const SizedBox(height: 12),
        NightButton(
          label: 'Сыграть ещё',
          onPressed: _enabled ? () => _play('start') : null,
        ),
        TextButton(
          onPressed: _enabled ? widget.onChooseGame : null,
          child: const Text('Выбрать другую игру'),
        ),
      ],
    ];
  }

  Future<void> _cancel() => _confirmTrade(
    'Отменить партию?',
    'Все вернутся в лобби. Комната и её участники сохранятся.',
    'Отменить партию',
    'cancel',
  );

  Future<void> _confirmTrade(
    String title,
    String text,
    String submit,
    String action, [
    Map<String, dynamic> payload = const {},
  ]) async {
    final intent = _snapshot;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(text),
        scrollable: true,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Назад'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(submit),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) await _play(action, payload, intent);
  }

  Widget _sectionHeading(String label) => Semantics(
    header: true,
    child: Text(label, style: Theme.of(context).textTheme.titleLarge),
  );
}

class _DealsTag extends StatelessWidget {
  const _DealsTag({
    required this.label,
    this.icon,
    this.semanticsLabel,
    this.tone = NightColors.text,
  });

  final String label;
  final IconData? icon;
  final String? semanticsLabel;
  final Color tone;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: NightColors.ink,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: NightColors.border),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 6,
        children: [
          if (icon case final symbol?)
            ExcludeSemantics(child: Icon(symbol, size: 16, color: tone)),
          Flexible(
            child: Text(
              label,
              semanticsLabel: semanticsLabel,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: tone,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _DealsCard extends StatelessWidget {
  const _DealsCard({
    required this.icon,
    required this.title,
    this.caption,
    this.description,
    this.tag,
    this.highlighted = false,
    this.children = const [],
    this.actions = const [],
  });

  final IconData icon;
  final String title;
  final String? caption;
  final String? description;
  final String? tag;
  final bool highlighted;
  final List<Widget> children;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    final tone = highlighted ? NightColors.accent : NightColors.muted;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: highlighted ? NightColors.raised : NightColors.surface,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: highlighted ? tone : NightColors.divider),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 12,
              children: [
                ExcludeSemantics(
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: NightColors.ink,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(icon, color: tone, size: 22),
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (caption case final label?)
                        Text(
                          label,
                          style: theme.labelLarge?.copyWith(color: tone),
                        ),
                      Text(title, style: theme.titleLarge),
                    ],
                  ),
                ),
              ],
            ),
            if (description case final body?) ...[
              const SizedBox(height: 8),
              Text(
                body,
                style: theme.bodyMedium?.copyWith(color: NightColors.muted),
              ),
            ],
            if (tag case final label?) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: _DealsTag(label: label, tone: NightColors.accent),
              ),
            ],
            for (final child in children) ...[const SizedBox(height: 8), child],
            for (final action in actions) ...[
              const SizedBox(height: 8),
              action,
            ],
          ],
        ),
      ),
    );
  }
}

String _coinAmount(int amount) {
  final lastTwo = amount % 100;
  final unit = lastTwo >= 11 && lastTwo <= 14
      ? 'монет'
      : switch (amount % 10) {
          1 => 'монета',
          2 || 3 || 4 => 'монеты',
          _ => 'монет',
        };
  return '$amount $unit';
}

Widget _numberField({
  Key? key,
  required String label,
  required int? value,
  required List<int> values,
  required ValueChanged<int>? onChanged,
}) => DropdownButtonFormField<int>(
  key: key,
  isExpanded: true,
  initialValue: value,
  decoration: InputDecoration(labelText: label),
  items: [
    for (final option in values)
      DropdownMenuItem(value: option, child: Text('$option')),
  ],
  onChanged: onChanged == null ? null : (value) => onChanged(value!),
);
