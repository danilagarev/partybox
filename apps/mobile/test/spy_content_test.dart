import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:partybox_game_core/partybox_game_core.dart';
import 'package:partybox_mobile/src/spy/local_session_adapter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const players = [
    Player(id: 'a', name: 'А'),
    Player(id: 'b', name: 'Б'),
    Player(id: 'c', name: 'В'),
    Player(id: 'd', name: 'Г'),
  ];
  String location(SpySession session) => players
      .map((p) => session.cardFor(p.id).location)
      .whereType<String>()
      .first;

  test(
    'all catalog packs are bundled and rotate independently without repeats',
    () async {
      final packs = await SpyPack.loadAll();
      expect(packs, hasLength(3));
      final adapter = LocalSessionAdapter.catalog(
        packs: packs,
        random: Random(42),
      );
      final seen = <String, Set<String>>{for (final p in packs) p.id: {}};
      final last = <String, String>{};
      for (var cycle = 0; cycle < 3; cycle++) {
        final rounds = packs.map((pack) => pack.locations.length).reduce(max);
        for (var i = 0; i < rounds; i++) {
          for (final pack in packs) {
            if (i >= pack.locations.length) continue;
            adapter.selectPack(pack.id);
            final selected = location(
              adapter.create(players, const Duration(minutes: 5)),
            );
            expect(selected, isNot(last[pack.id]));
            expect(seen[pack.id]!.add(selected), true);
            last[pack.id] = selected;
          }
        }
        for (final pack in packs) {
          expect(seen[pack.id], hasLength(pack.locations.length));
          seen[pack.id]!.clear();
        }
      }
    },
  );

  test(
    'one-location pack stays playable and invalid starts do not consume it',
    () {
      final adapter = LocalSessionAdapter(
        pack: SpyPack(
          id: 'test',
          version: 1,
          title: 'Тест',
          locations: ['Музей'],
        ),
      );
      expect(
        () => adapter.create([], const Duration(minutes: 5)),
        throwsArgumentError,
      );
      for (var i = 0; i < 3; i++) {
        expect(
          location(adapter.create(players, const Duration(minutes: 5))),
          'Музей',
        );
      }
    },
  );
}
