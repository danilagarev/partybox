import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:test/test.dart';
import 'package:partybox_game_core/partybox_game_core.dart';

class FixedIndex implements Random {
  FixedIndex(this.index);
  final int index;
  @override
  int nextInt(int max) => index;
  @override
  bool nextBool() => throw UnimplementedError();
  @override
  double nextDouble() => throw UnimplementedError();
}

void main() {
  test('shared server Spy vectors match Dart rules', () {
    final vectors =
        jsonDecode(
              File('../game-contracts/vectors/spy-v1.json').readAsStringSync(),
            )
            as Map;
    for (final item in vectors['cases'] as List) {
      final initial = item['initial'] as Map;
      var state = SpySession.create(
        players: [
          for (final p in initial['players'] as List)
            Player(id: p['id'] as String, name: p['name'] as String),
        ],
        location: initial['location'] as String,
        random: FixedIndex(initial['spyIndex'] as int),
        duration: Duration(milliseconds: initial['durationMs'] as int),
      );
      for (final step in item['steps'] as List) {
        SpySession action() => switch (step['type']) {
          'ack' => state.acknowledgeRole(
            step['playerId'] as String,
            now: DateTime.fromMillisecondsSinceEpoch(
              step['at'] as int,
              isUtc: true,
            ),
          ),
          'time' => state.advanceTime(
            DateTime.fromMillisecondsSinceEpoch(step['at'] as int, isUtc: true),
          ),
          'vote' => state.startVoting(),
          _ => state.accuse(step['playerId'] as String),
        };
        if (step['error'] == true) {
          expect(
            action,
            throwsA(anyOf(isA<StateError>(), isA<ArgumentError>())),
          );
          continue;
        }
        state = action();
        expect(state.phase.name, step['phase']);
        if (step['winner'] != null) expect(state.winner!.name, step['winner']);
        if (state.phase != SpyPhase.results) {
          expect(
            jsonEncode(state.publicView()),
            isNot(contains(initial['location'])),
          );
        }
      }
    }
  });
}
