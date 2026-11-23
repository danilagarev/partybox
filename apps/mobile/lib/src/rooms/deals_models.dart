enum DealsPhase { goals, listing, trading, market, recap, finished }

enum DealsCategory {
  tech('Техника'),
  art('Искусство'),
  jewelry('Украшения'),
  antiques('Антиквариат'),
  toys('Игрушки'),
  music('Музыка');

  const DealsCategory(this.label);
  final String label;
}

typedef _Json = Map<String, dynamic>;

List<T> _readList<T>(Object? value, T Function(_Json) parse) =>
    List<T>.unmodifiable((value as List).cast<_Json>().map(parse));

final class DealsGame {
  DealsGame(Map<String, dynamic> value)
    : sessionId = value['sessionId'] as String,
      phase = DealsPhase.values.byName(value['phase'] as String),
      round = value['round'] as int,
      deadline = value['deadline'] == null
          ? null
          : DateTime.tryParse(value['deadline'] as String),
      readyIds = List<String>.unmodifiable(value['readyIds'] as List),
      lots = _readList(value['lots'], DealsLot.new),
      market = _readList(value['market'], DealsMarketLot.new),
      marketPriorityId = value['marketPriorityId'] as String,
      event = value['event'] == null
          ? null
          : DealsEvent(value['event'] as _Json),
      sales = _readList(value['sales'], DealsSale.new),
      results = value['results'] == null
          ? null
          : _readList(value['results'], DealsResult.new),
      revealedSales = value['revealedSales'] == null
          ? null
          : _readList(value['revealedSales'], DealsRevealedSale.new);
  final String sessionId, marketPriorityId;
  final DealsPhase phase;
  final int round;
  final DateTime? deadline;
  final List<String> readyIds;
  final List<DealsLot> lots;
  final List<DealsMarketLot> market;
  final DealsEvent? event;
  final List<DealsSale> sales;
  final List<DealsResult>? results;
  final List<DealsRevealedSale>? revealedSales;

  int get insuranceCost => event?.id == 'e-07' ? 0 : 1;
  int get insurancePayout => event?.id == 'e-08' ? 4 : 3;
  int get inspectionCost => switch (event?.id) {
    'e-03' => 1,
    'e-04' => 3,
    _ => 2,
  };
}

final class DealsPrivate {
  DealsPrivate(Map<String, dynamic> value)
    : balance = value['balance'] as int,
      inventory = _readList(value['inventory'], DealsItem.new),
      goalOptions = _readList(value['goalOptions'], DealsGoal.new),
      goal = value['goal'] == null ? null : DealsGoal(value['goal'] as _Json),
      ownLotItem = value['ownLotItem'] == null
          ? null
          : DealsItem(value['ownLotItem'] as _Json),
      outgoingOffer = value['outgoingOffer'] == null
          ? null
          : DealsOffer(value['outgoingOffer'] as _Json),
      incomingOffers = _readList(value['incomingOffers'], DealsOffer.new),
      inspection = value['inspection'] == null
          ? null
          : DealsInspection(value['inspection'] as _Json),
      insuranceAvailable = value['insuranceAvailable'] as bool,
      purchased = value['purchased'] as bool,
      purchases = _readList(value['purchases'], DealsPurchase.new);

  final int balance;
  final List<DealsItem> inventory;
  final List<DealsGoal> goalOptions;
  final DealsGoal? goal;
  final DealsItem? ownLotItem;
  final DealsOffer? outgoingOffer;
  final List<DealsOffer> incomingOffers;
  final DealsInspection? inspection;
  final bool insuranceAvailable, purchased;
  final List<DealsPurchase> purchases;

  @override
  String toString() => 'DealsPrivate(<redacted>)';
}

final class DealsItem {
  DealsItem(Map<String, dynamic> value)
    : id = value['id'] as String,
      name = value['name'] as String,
      category = DealsCategory.values.byName(value['category'] as String),
      value = value['value'] as int;

  final String id, name;
  final DealsCategory category;
  final int value;
}

final class DealsGoal {
  DealsGoal(Map<String, dynamic> value)
    : id = value['id'] as String,
      title = value['title'] as String,
      text = value['text'] as String,
      bonus = value['bonus'] as int;

  final String id, title, text;
  final int bonus;
}

final class DealsEvent {
  DealsEvent(Map<String, dynamic> value)
    : id = value['id'] as String,
      title = value['title'] as String,
      text = value['text'] as String;

  final String id, title, text;
}

final class DealsLot {
  DealsLot(Map<String, dynamic> value)
    : sellerId = value['sellerId'] as String,
      category = DealsCategory.values.byName(value['category'] as String),
      value = value['value'] as int,
      price = value['price'] as int,
      sold = value['sold'] as bool;

  final String sellerId;
  final DealsCategory category;
  final int value, price;
  final bool sold;
}

final class DealsMarketLot {
  DealsMarketLot(Map<String, dynamic> value)
    : item = DealsItem(value['item'] as _Json),
      price = value['price'] as int;

  final DealsItem item;
  final int price;
}

final class DealsOffer {
  DealsOffer(Map<String, dynamic> value)
    : sellerId = value['sellerId'] as String,
      buyerId = value['buyerId'] as String,
      price = value['price'] as int,
      insured = value['insured'] as bool;

  final String sellerId, buyerId;
  final int price;
  final bool insured;
}

final class DealsInspection {
  DealsInspection(Map<String, dynamic> value)
    : sellerId = value['sellerId'] as String,
      category = value['category'] == null
          ? null
          : DealsCategory.values.byName(value['category'] as String),
      value = value['value'] as int?,
      matches = value['matches'] as bool?;

  final String sellerId;
  final DealsCategory? category;
  final int? value;
  final bool? matches;
}

final class DealsPurchase {
  DealsPurchase(Map<String, dynamic> value)
    : item = DealsItem(value['item'] as _Json),
      sellerId = value['sellerId'] as String?,
      round = value['round'] as int,
      price = value['price'] as int,
      category = DealsCategory.values.byName(value['category'] as String),
      value = value['value'] as int;

  final DealsItem item;
  final String? sellerId;
  final int round, price, value;
  final DealsCategory category;
}

final class DealsSale {
  DealsSale(Map<String, dynamic> value)
    : sellerId = value['sellerId'] as String?,
      buyerId = value['buyerId'] as String,
      round = value['round'] as int,
      price = value['price'] as int,
      category = DealsCategory.values.byName(value['category'] as String),
      value = value['value'] as int;

  final String? sellerId;
  final String buyerId;
  final DealsCategory category;
  final int round, price, value;
}

final class DealsResult {
  DealsResult(Map<String, dynamic> value)
    : playerId = value['playerId'] as String,
      balance = value['balance'] as int,
      goodsValue = value['goodsValue'] as int,
      bonus = value['bonus'] as int,
      total = value['total'] as int,
      goal = DealsGoal(value['goal'] as _Json),
      inventory = _readList(value['inventory'], DealsItem.new);

  final String playerId;
  final int balance, goodsValue, bonus, total;
  final DealsGoal goal;
  final List<DealsItem> inventory;
}

final class DealsRevealedSale {
  DealsRevealedSale(Map<String, dynamic> value)
    : buyerId = value['buyerId'] as String,
      purchase = DealsPurchase(value['purchase'] as _Json);

  final String buyerId;
  final DealsPurchase purchase;
}
