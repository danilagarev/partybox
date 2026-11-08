import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:partybox_game_content/partybox_game_content.dart';
import 'package:partybox_game_core/partybox_game_core.dart';

/// Immutable bundled content. A running controller keeps this exact pack version.
final class SpyPack {
  SpyPack({
    required this.id,
    required this.version,
    required this.title,
    this.description = '',
    required List<String> locations,
  }) : locations = List.unmodifiable(locations) {
    if (locations.isEmpty ||
        locations.any((label) => label.trim().isEmpty) ||
        locations.toSet().length != locations.length) {
      throw const FormatException('Empty locations');
    }
  }

  final String id;
  final int version;
  final String title;
  final String description;
  final List<String> locations;

  String get rotationLabel {
    final count = locations.length;
    final remainder = count % 100;
    final noun = remainder >= 11 && remainder <= 14
        ? 'локаций'
        : switch (count % 10) {
            1 => 'локация',
            2 || 3 || 4 => 'локации',
            _ => 'локаций',
          };
    return '$count $noun${count > 1 ? ' · без повторов до конца набора' : ''}';
  }

  static Future<SpyPack> load() async => (await loadAll()).first;

  static Future<List<SpyPack>> loadAll() async {
    final catalog =
        jsonDecode(await rootBundle.loadString(spyCatalogAsset, cache: false))
            as Map<String, dynamic>;
    if (catalog['schemaVersion'] != 1 ||
        catalog['gameId'] != 'spy' ||
        catalog['locale'] != 'ru') {
      throw const FormatException('Unsupported catalog');
    }
    final packs = <SpyPack>[];
    for (final entry in catalog['packs'] as List<dynamic>) {
      final id = entry['id'] as String;
      if (!RegExp(r'^[a-z][a-z0-9-]{1,79}$').hasMatch(id) ||
          packs.any((pack) => pack.id == id)) {
        throw const FormatException('Invalid catalog entry');
      }
      packs.add(
        await _load(
          id,
          entry['version'] as int,
          entry['description'] as String,
        ),
      );
    }
    if (packs.isEmpty) throw const FormatException('Empty catalog');
    return List.unmodifiable(packs);
  }

  static Future<SpyPack> _load(
    String id,
    int version,
    String description,
  ) async {
    final json =
        jsonDecode(
              await rootBundle.loadString(
                'packages/partybox_game_content/packs/$id.json',
                cache: false,
              ),
            )
            as Map<String, dynamic>;
    if (json['schemaVersion'] != 1 ||
        json['gameId'] != 'spy' ||
        json['locale'] != 'ru' ||
        json['id'] != id ||
        json['version'] != version) {
      throw const FormatException('Unsupported pack');
    }
    return SpyPack(
      id: json['id'] as String,
      version: json['version'] as int,
      title: json['title'] as String,
      description: description,
      locations: [
        for (final item in json['items'] as List<dynamic>)
          (item as Map<String, dynamic>)['label'] as String,
      ],
    );
  }
}

final class LocalSessionAdapter {
  LocalSessionAdapter({required SpyPack pack, Random? random})
    : _pack = pack,
      packs = List.unmodifiable([pack]),
      _random = random ?? Random();

  LocalSessionAdapter.catalog({required List<SpyPack> packs, Random? random})
    : packs = List.unmodifiable(packs),
      _pack = packs.first,
      _random = random ?? Random() {
    if (packs.map((p) => p.id).toSet().length != packs.length) {
      throw const FormatException('Duplicate pack');
    }
  }

  SpyPack _pack;
  SpyPack get pack => _pack;
  final List<SpyPack> packs;
  final Random _random;
  final Map<String, List<String>> _history = {};

  void selectPack(String id) {
    _pack = packs.firstWhere((p) => p.id == id);
  }

  SpySession create(List<Player> players, Duration duration) {
    final key = '${pack.id}:${pack.version}';
    var history = _history[key] ?? <String>[];
    var candidates = pack.locations.where((s) => !history.contains(s)).toList();
    if (candidates.isEmpty) {
      candidates = pack.locations.where((s) => s != history.last).toList();
      if (candidates.isEmpty) candidates = pack.locations.toList();
      history = [];
    }
    final location = candidates[_random.nextInt(candidates.length)];
    final session = SpySession.create(
      players: players,
      location: location,
      random: _random,
      duration: duration,
    );
    _history[key] = [...history, location];
    return session;
  }
}
