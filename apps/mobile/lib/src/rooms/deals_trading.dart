import 'package:flutter/material.dart';

import '../design/deals_cover.dart';
import '../design/night_components.dart';
import '../design/night_theme.dart';
import 'deals_models.dart';
import 'room_controller.dart';
import 'room_models.dart';

class DealsTrading extends StatefulWidget {
  const DealsTrading({
    super.key,
    required this.controller,
    required this.snapshot,
  });

  final RoomController controller;
  final RoomSnapshot snapshot;

  @override
  State<DealsTrading> createState() => _DealsTradingState();
}

class _DealsTradingState extends State<DealsTrading> {
  final _revealKey = GlobalKey();
  String? _selectedSeller;

  RoomSnapshot get _snapshot => widget.snapshot;
  RoomController get _controller => widget.controller;
  DealsGame get _game => _snapshot.deals!;
  DealsPrivate get _personal => _snapshot.privateDeals!;
  bool get _ready => _game.readyIds.contains(_snapshot.selfId);
  bool get _canAct =>
      _controller.online &&
      !_controller.busy &&
      !_controller.hasPending &&
      (_game.deadline == null || _controller.remaining > Duration.zero);
  bool get _canBuy => _canAct && !_ready && !_personal.purchased;
  int get _lowestInspectionCost =>
      _game.event?.id == 'e-05' ? 1 : _game.inspectionCost;

  String _name(String id) =>
      _snapshot.players.firstWhere((player) => player.id == id).name;

  @override
  void didUpdateWidget(covariant DealsTrading oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_personal.purchased && !oldWidget.snapshot.privateDeals!.purchased) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_revealKey.currentContext case final context?) {
          Scrollable.ensureVisible(
            context,
            alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart,
            duration: NightMotion.reduced(context)
                ? Duration.zero
                : NightMotion.enter,
          );
        }
      });
    }
  }

  Future<void> _play(
    String action,
    RoomSnapshot intent, [
    Map<String, dynamic> payload = const {},
  ]) async {
    if (!mounted || !_canAct) return;
    await _controller.play('deals.$action', payload, intent);
  }

  Future<void> _playIfUnchanged(
    String action,
    RoomSnapshot intent,
    bool Function(RoomSnapshot) matches, [
    Map<String, dynamic> payload = const {},
  ]) async {
    if (!mounted) return;
    final current = _matchingTrade(_controller.snapshot, intent, matches);
    if (current != null) await _play(action, current, payload);
  }

  @override
  Widget build(BuildContext context) {
    if (!_controller.online) {
      return const Text('Подключаемся к комнате…');
    }
    final purchase = _personal.purchases
        .where((purchase) => purchase.round == _game.round)
        .firstOrNull;
    final otherLots = _game.lots.where(
      (lot) => lot.sellerId != _snapshot.selfId,
    );
    final available = otherLots.where((lot) => !lot.sold).toList();
    final lot =
        available.where((lot) => lot.sellerId == _selectedSeller).firstOrNull ??
        available.firstOrNull;
    final skipLabel = lot == null ? 'К рынку' : 'Пропустить торги';
    final own = _game.lots
        .where((lot) => lot.sellerId == _snapshot.selfId)
        .firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 12,
      children: [
        if (purchase != null)
          _reveal(purchase)
        else if (_ready)
          const Text('Ждём, пока все закончат торги.'),
        if (_personal.incomingOffers.isNotEmpty)
          _incoming(_personal.incomingOffers),
        if (purchase == null && !_ready) ...[
          if (available.length > 1)
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final option in available)
                  ChoiceChip(
                    label: Text(_name(option.sellerId)),
                    selected: option.sellerId == lot?.sellerId,
                    onSelected: (_) =>
                        setState(() => _selectedSeller = option.sellerId),
                  ),
              ],
            ),
          if (lot != null)
            _lotCard(lot)
          else
            NightPanel(
              padding: 16,
              child: Text(
                otherLots.isEmpty
                    ? 'У соперников нет чемоданов'
                    : 'Все чемоданы соперников проданы',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
          if (_personal.inspection case final inspection?
              when inspection.sellerId != lot?.sellerId)
            _inspectionResult(inspection),
          if (_personal.outgoingOffer case final offer?) _outgoing(offer),
          if (_game.market.isNotEmpty)
            ExpansionTile(
              title: const Text('Что на рынке'),
              leading: const Icon(Icons.storefront_outlined),
              children: [
                for (final lot in _game.market)
                  ListTile(
                    title: Text(lot.item.name),
                    subtitle: Text(
                      '${lot.item.category.label} · стоит ${lot.item.value}',
                    ),
                    trailing: Text(_coins(lot.price)),
                  ),
              ],
            ),
          OutlinedButton(
            onPressed: _canAct ? () => _endTrading(skipLabel) : null,
            child: Text(skipLabel),
          ),
        ],
        if (own != null && _personal.ownLotItem != null) _ownLot(own),
      ],
    );
  }

  Widget _lotCard(DealsLot lot) {
    final theme = Theme.of(context).textTheme;
    return Semantics(
      container: true,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: ColoredBox(
          color: NightColors.surface,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 136, child: DealsCover()),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 10,
                  children: [
                    Text(
                      'Лот игрока ${_name(lot.sellerId)}',
                      style: theme.labelLarge?.copyWith(
                        color: NightColors.muted,
                      ),
                    ),
                    Wrap(
                      spacing: 12,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      alignment: WrapAlignment.spaceBetween,
                      children: [
                        Text(lot.category.label, style: theme.headlineSmall),
                        Text(
                          _coins(lot.price),
                          style: theme.titleLarge?.copyWith(
                            color: NightColors.accent,
                          ),
                        ),
                      ],
                    ),
                    Text('Обещанная стоимость · ${lot.value}'),
                    if (_personal.inspection case final inspection?
                        when inspection.sellerId == lot.sellerId)
                      _inspectionResult(inspection),
                    if (_personal.balance < lot.price)
                      const Text('Не хватает монет на покупку'),
                    NightButton(
                      label: 'Купить',
                      onPressed: _canBuy && _personal.balance >= lot.price
                          ? () => _purchase(lot, offer: false)
                          : null,
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            style: _compactOutline,
                            onPressed: _canBuy && _personal.balance > 0
                                ? () => _purchase(lot, offer: true)
                                : null,
                            child: const Text('Торг'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton(
                            style: _compactOutline,
                            onPressed:
                                _canBuy &&
                                    _personal.inspection == null &&
                                    _personal.balance >= _lowestInspectionCost
                                ? () => _inspect(lot)
                                : null,
                            child: const Text('Проверить'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _reveal(DealsPurchase purchase) {
    final theme = Theme.of(context).textTheme;
    final item = purchase.item;
    final honest =
        item.category == purchase.category && item.value == purchase.value;
    final tone = honest ? NightColors.accent : NightColors.lilac;
    final intent = _snapshot;
    return NightEntrance(
      key: ValueKey(item.id),
      child: Semantics(
        key: _revealKey,
        liveRegion: true,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: tone),
            color: NightColors.raised,
          ),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 8,
              children: [
                ExcludeSemantics(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Icon(Icons.lock_open_rounded, size: 32, color: tone),
                  ),
                ),
                Text('В чемодане', style: theme.labelLarge),
                Text(item.name, style: theme.headlineMedium),
                Text('${item.category.label} · стоимость ${item.value}'),
                const SizedBox(height: 2),
                Text(
                  honest ? 'Честное объявление' : 'Блеф!',
                  style: theme.titleLarge?.copyWith(color: tone),
                ),
                if (!honest)
                  Text(
                    'В объявлении · ${purchase.category.label}, стоимость ${purchase.value}',
                  ),
                Text('Заплачено · ${_coins(purchase.price)}'),
                if (_ready)
                  const Text('Ждём, пока все закончат торги.')
                else
                  NightButton(
                    label: 'Дальше',
                    onPressed: _canAct ? () => _play('done', intent) : null,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _ownLot(DealsLot lot) {
    final item = _personal.ownLotItem!;
    final theme = Theme.of(context).textTheme;
    final sale = _game.sales
        .where((sale) => sale.sellerId == _snapshot.selfId)
        .firstOrNull;
    return NightPanel(
      padding: 12,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 4,
        children: [
          Text(
            sale != null
                ? 'Ваш чемодан продан за ${_coins(sale.price)}'
                : 'Ваш чемодан · ${_coins(lot.price)}',
            style: theme.labelLarge,
          ),
          if (!lot.sold) ...[
            Text('Объявлено · ${lot.category.label}, стоимость ${lot.value}'),
            Text('Внутри · ${item.name}, стоимость ${item.value}'),
          ],
        ],
      ),
    );
  }

  Widget _incoming(List<DealsOffer> offers) => Semantics(
    liveRegion: true,
    child: NightPanel(
      padding: 12,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 8,
        children: [
          Text('За ваш чемодан', style: Theme.of(context).textTheme.titleLarge),
          for (final offer in offers)
            OutlinedButton(
              onPressed: _canAct ? () => _accept(offer) : null,
              child: Text(
                '${_name(offer.buyerId)} · ${_coins(offer.price)}',
                textAlign: TextAlign.center,
              ),
            ),
        ],
      ),
    ),
  );

  Widget _outgoing(DealsOffer offer) {
    final intent = _snapshot;
    return NightPanel(
      padding: 12,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Ждём ответа · ${_name(offer.sellerId)}',
            style: Theme.of(context).textTheme.labelLarge,
          ),
          Text(
            '${_coins(offer.price)}${offer.insured ? ' со страховкой' : ''}',
          ),
          TextButton(
            onPressed: _canBuy
                ? () => _playIfUnchanged(
                    'offer',
                    intent,
                    (current) => _sameOutgoingOffer(current, offer),
                    {'sellerId': null, 'price': null, 'insured': false},
                  )
                : null,
            child: const Text('Отозвать'),
          ),
        ],
      ),
    );
  }

  Widget _inspectionResult(DealsInspection inspection) {
    final evidence = [
      if (inspection.category case final category?) category.label,
      if (inspection.value case final value?) 'стоимость $value',
      if (inspection.matches case final matches?)
        matches ? 'категория совпала' : 'категория отличается',
    ];
    return NightPanel(
      padding: 12,
      child: Semantics(
        liveRegion: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 4,
          children: [
            Text(
              'Проверка · ${_name(inspection.sellerId)}',
              style: Theme.of(context).textTheme.labelLarge,
            ),
            Text(evidence.join(' · ')),
          ],
        ),
      ),
    );
  }

  Future<void> _accept(DealsOffer offer) async {
    final intent = _snapshot;
    final name = _name(offer.buyerId);
    final terms = _offerTerms(offer);
    bool matches(RoomSnapshot current) => current.privateDeals!.incomingOffers
        .any((candidate) => _offerTerms(candidate) == terms);
    final confirmed = await _sheet<bool>(
      intent,
      matches,
      'Продать чемодан?',
      (context) => [
        Text('$name предлагает ${_coins(offer.price)}.'),
        NightButton(
          label: 'Продать за ${offer.price}',
          onPressed: () => Navigator.pop(context, true),
        ),
      ],
    );
    if (confirmed == true) {
      await _playIfUnchanged('accept', intent, matches, {
        'buyerId': offer.buyerId,
      });
    }
  }

  Future<void> _endTrading(String label) async {
    final intent = _snapshot;
    final outgoing = _personal.outgoingOffer;
    bool matches(RoomSnapshot current) => _sameOutgoingOffer(current, outgoing);
    if (outgoing != null) {
      final confirmed = await _sheet<bool>(
        intent,
        matches,
        '$label?',
        (context) => [
          const Text('Ваше предложение будет отозвано.'),
          NightButton(
            label: label,
            onPressed: () => Navigator.pop(context, true),
          ),
        ],
      );
      if (confirmed != true) return;
    }
    await _playIfUnchanged('done', intent, matches);
  }

  Future<void> _purchase(DealsLot lot, {required bool offer}) async {
    final intent = _snapshot;
    final balance = _personal.balance;
    final insuranceAvailable = _personal.insuranceAvailable;
    final cost = _game.insuranceCost;
    final payout = _game.insurancePayout;
    final outgoing = _personal.outgoingOffer;
    bool matches(RoomSnapshot current) {
      final personal = current.privateDeals!;
      final game = current.deals!;
      return _sameOutgoingOffer(current, outgoing) &&
          _sameOpenLot(game, lot) &&
          personal.balance == balance &&
          personal.insuranceAvailable == insuranceAvailable &&
          game.insuranceCost == cost &&
          game.insurancePayout == payout;
    }

    final existing = offer && outgoing?.sellerId == lot.sellerId
        ? outgoing
        : null;
    var insured = existing?.insured ?? false;
    final maxPrice = balance.clamp(1, 15);
    var price = offer
        ? (existing?.price ?? lot.price - 1).clamp(1, maxPrice)
        : lot.price;
    final name = _name(lot.sellerId);
    final decision = await _sheet<({int price, bool insured})>(
      intent,
      matches,
      offer ? 'Предложить цену' : 'Купить чемодан?',
      (context) => [
        Text('$name · ${lot.category.label}'),
        StatefulBuilder(
          builder: (context, refresh) {
            final total = price + (insured ? cost : 0);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 12,
              children: [
                if (offer)
                  Row(
                    children: [
                      IconButton.outlined(
                        tooltip: 'Уменьшить цену',
                        onPressed: price > 1
                            ? () => refresh(() => price--)
                            : null,
                        icon: const Icon(Icons.remove),
                      ),
                      Expanded(
                        child: Text(
                          _coins(price),
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                      ),
                      IconButton.outlined(
                        tooltip: 'Увеличить цену',
                        onPressed: price < maxPrice
                            ? () => refresh(() => price++)
                            : null,
                        icon: const Icon(Icons.add),
                      ),
                    ],
                  ),
                if (offer && outgoing != null)
                  const Text('Новое предложение заменит прежнее.'),
                if (insuranceAvailable)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: insured,
                    onChanged: (value) =>
                        refresh(() => insured = value == true),
                    title: Text(
                      'Страховка · ${cost == 0 ? 'бесплатно' : _coins(cost)}',
                    ),
                    subtitle: Text(
                      'Раз за игру. Если товар стоит 2, получите ${_coins(payout)}.',
                    ),
                  ),
                if (total > balance) const Text('Не хватает монет'),
                NightButton(
                  label: offer ? 'Предложить за $price' : 'Купить за $total',
                  onPressed: total <= balance
                      ? () => Navigator.pop(context, (
                          price: price,
                          insured: insured,
                        ))
                      : null,
                ),
              ],
            );
          },
        ),
      ],
    );
    if (decision != null) {
      await _playIfUnchanged(offer ? 'offer' : 'buy', intent, matches, {
        'sellerId': lot.sellerId,
        if (offer) 'price': decision.price,
        'insured': decision.insured,
      });
    }
  }

  Future<void> _inspect(DealsLot lot) async {
    final intent = _snapshot;
    final cost = _game.inspectionCost;
    final balance = _personal.balance;
    final event = _game.event?.id;
    bool matches(RoomSnapshot current) =>
        _canStillBuy(current) &&
        _sameOpenLot(current.deals!, lot) &&
        current.privateDeals!.balance == balance &&
        current.privateDeals!.inspection == null &&
        current.deals!.event?.id == event;
    final modes = [
      (id: 'category', label: 'Узнать категорию', price: cost),
      (id: 'value', label: 'Узнать стоимость', price: cost),
      if (event == 'e-05') (id: 'match', label: 'Сверить категорию', price: 1),
      if (event == 'e-06')
        (id: 'both', label: 'Узнать категорию и стоимость', price: 3),
    ];
    final mode = await _sheet<String>(
      intent,
      matches,
      'Проверить чемодан',
      (context) => [
        const Text('Одна проверка за раунд'),
        for (final mode in modes)
          OutlinedButton(
            onPressed: balance >= mode.price
                ? () => Navigator.pop(context, mode.id)
                : null,
            child: Text(
              '${mode.label} · ${_coins(mode.price)}',
              textAlign: TextAlign.center,
            ),
          ),
      ],
    );
    if (mode != null) {
      await _playIfUnchanged('inspect', intent, matches, {
        'sellerId': lot.sellerId,
        'mode': mode,
      });
    }
  }

  Future<T?> _sheet<T>(
    RoomSnapshot intent,
    bool Function(RoomSnapshot) matches,
    String title,
    List<Widget> Function(BuildContext) actions,
  ) {
    final controller = _controller;
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: NightColors.surface,
      builder: (context) => SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
          child: AnimatedBuilder(
            animation: controller,
            builder: (context, _) {
              final current = _matchingTrade(
                controller.snapshot,
                intent,
                matches,
              );
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                spacing: 12,
                children: [
                  Text(title, style: Theme.of(context).textTheme.headlineSmall),
                  if (current == null)
                    const Text('Условия изменились. Откройте действие заново.')
                  else if (!controller.online)
                    const Text('Ждём восстановления связи.')
                  else
                    ...actions(context),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(current == null ? 'Закрыть' : 'Назад'),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

RoomSnapshot? _matchingTrade(
  RoomSnapshot? current,
  RoomSnapshot intent,
  bool Function(RoomSnapshot) matches,
) {
  if (current == null ||
      current.roomId != intent.roomId ||
      current.selfId != intent.selfId ||
      current.sessionId != intent.sessionId ||
      current.deals?.phase != DealsPhase.trading ||
      current.deals?.round != intent.deals?.round ||
      current.privateDeals == null ||
      !matches(current)) {
    return null;
  }
  return current;
}

bool _canStillBuy(RoomSnapshot current) =>
    !current.privateDeals!.purchased &&
    !current.deals!.readyIds.contains(current.selfId);

bool _sameOutgoingOffer(RoomSnapshot current, DealsOffer? offer) =>
    _canStillBuy(current) &&
    _offerTerms(current.privateDeals!.outgoingOffer) == _offerTerms(offer);

(String, String, int, bool)? _offerTerms(DealsOffer? offer) => offer == null
    ? null
    : (offer.buyerId, offer.sellerId, offer.price, offer.insured);

bool _sameOpenLot(DealsGame game, DealsLot lot) => game.lots.any(
  (candidate) =>
      candidate.sellerId == lot.sellerId &&
      candidate.category == lot.category &&
      candidate.value == lot.value &&
      candidate.price == lot.price &&
      !candidate.sold,
);

final _compactOutline = OutlinedButton.styleFrom(
  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 12),
);

String _coins(int amount) {
  final unit = amount % 100 >= 11 && amount % 100 <= 14
      ? 'монет'
      : switch (amount % 10) {
          1 => 'монета',
          2 || 3 || 4 => 'монеты',
          _ => 'монет',
        };
  return '$amount $unit';
}
