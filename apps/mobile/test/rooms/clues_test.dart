import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:partybox_mobile/src/design/night_theme.dart';
import 'package:partybox_mobile/src/rooms/clues_panel.dart';
import 'package:partybox_mobile/src/rooms/room_controller.dart';
import 'package:partybox_mobile/src/rooms/room_models.dart';
import 'package:partybox_mobile/src/rooms/room_vault.dart';

import 'clues_support.dart';
import 'support.dart';

Future<void> showCluesControl(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

Future<void> tapCluesControl(WidgetTester tester, Finder finder) async {
  await showCluesControl(tester, finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<RoomController> connectClues(CluesApi api, TestVault vault) async {
  final controller = RoomController(api: api, vault: vault);
  await controller.initialize();
  api.receive!(api.current);
  return controller;
}

Widget cluesApp(RoomController controller, {double scale = 1}) => MaterialApp(
  theme: nightTheme(),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: Scaffold(
    body: SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: AnimatedBuilder(
            animation: controller,
            builder: (_, _) =>
                CluesPanel(controller: controller, onChooseGame: () {}),
          ),
        ),
      ),
    ),
  ),
);

void main() {
  test(
    'v4 semantic validation rejects foreign, duplicate and early secret data',
    () {
      for (final phase in ['playing', 'reveal', 'finished']) {
        expect(
          RoomSnapshot.parse(cluesFixture(phase: phase)).clues!.phase,
          phase,
        );
      }
      final mutations = <void Function(Map<String, dynamic>)>[
        (data) => data['publicState']['clues']['solvedIds'] = [selfId, selfId],
        (data) => data['publicState']['clues']['attemptedIds'] = [otherId],
        (data) =>
            data['publicState']['clues']['scores'][1]['playerId'] = selfId,
        (data) => data['publicState']['clues']['result'] = cluesFixture(
          phase: 'reveal',
        )['publicState']['clues']['result'],
        (data) => data['publicState']['clues']['clues'] = [
          'Первая',
          'Неоткрытая вторая',
        ],
        (data) =>
            data['privateClues']['answer'] = 'Утечка без номера подсказки',
        (data) => data['privateClues']['correct'] = true,
      ];
      for (final mutate in mutations) {
        final data = cluesFixture();
        mutate(data);
        expect(() => RoomSnapshot.parse(data), throwsA(isA<RoomFailure>()));
      }
      final duplicateResult = cluesFixture(phase: 'reveal');
      duplicateResult['publicState']['clues']['result']['answers'][1]['playerId'] =
          selfId;
      expect(
        () => RoomSnapshot.parse(duplicateResult),
        throwsA(isA<RoomFailure>()),
      );
      final foreignWinner = cluesFixture(phase: 'finished');
      foreignWinner['publicState']['clues']['winners'] = [otherId];
      expect(
        () => RoomSnapshot.parse(foreignWinner),
        throwsA(isA<RoomFailure>()),
      );
    },
  );

  test('plaintext vault rejects private clue answers on encode and decode', () {
    final secret = {
      'protocolVersion': 4,
      'commandId': '00000000-0000-4000-8000-000000000030',
      'expectedVersion': 1,
      'sessionId': cluesFixture()['publicState']['clues']['sessionId'],
      'type': 'clues.answer',
      'payload': {'answer': 'Приватная догадка', 'clueIndex': 0},
    };
    expect(() => saved(leave: secret).toJson(), throwsA(isA<RoomFailure>()));
    expect(
      () =>
          RoomAccess.decode(jsonEncode({...saved().toJson(), 'leave': secret})),
      throwsA(isA<RoomFailure>()),
    );
  });

  test(
    'definite answer race retries only the same clue with a new command ID',
    () async {
      final api = CluesApi()..current = RoomSnapshot.parse(cluesFixture());
      api.responses.addAll([
        cluesFixture(version: 2),
        cluesFixture(version: 3, ownAnswer: 'Учебный ответ', correct: true),
      ]);
      api.errors.addAll([const RoomFailure('VERSION_CONFLICT'), null]);
      final vault = TestVault()..value = saved();
      final controller = await connectClues(api, vault);
      addTearDown(controller.dispose);
      final writes = vault.writes;
      await controller.play('clues.answer', {
        'answer': 'Учебный ответ',
        'clueIndex': 0,
      });
      expect(api.leaves, hasLength(2));
      expect(
        api.leaves[0].leave!['commandId'],
        isNot(api.leaves[1].leave!['commandId']),
      );
      expect(api.leaves[1].leave!['expectedVersion'], 2);
      expect(api.leaves[1].leave!['payload'], {
        'answer': 'Учебный ответ',
        'clueIndex': 0,
      });
      expect(controller.snapshot!.privateClues!.correct, true);
      expect(vault.writes, writes);
      expect(vault.value!.leave, null);
      expect(
        jsonEncode(vault.value!.toJson()),
        isNot(contains('Учебный ответ')),
      );
      await controller.retry();
      expect(api.leaves, hasLength(2));
    },
  );

  test(
    'advanced clue and uncertain response never silently replay an answer',
    () async {
      for (final uncertain in [false, true]) {
        final api = CluesApi()..current = RoomSnapshot.parse(cluesFixture());
        api.responses.add(
          uncertain
              ? cluesFixture(
                  version: 2,
                  ownAnswer: 'Учебный ответ',
                  correct: true,
                )
              : cluesFixture(version: 2, clueIndex: 1),
        );
        api.errors.add(
          RoomFailure(uncertain ? 'CONNECTION' : 'VERSION_CONFLICT'),
        );
        final vault = TestVault()..value = saved();
        final controller = await connectClues(api, vault);
        await controller.play('clues.answer', {
          'answer': 'Учебный ответ',
          'clueIndex': 0,
        });
        expect(api.leaves, hasLength(1));
        expect(controller.hasPending, false);
        expect(vault.value!.leave, null);
        await controller.retry();
        expect(api.leaves, hasLength(1));
        expect(controller.snapshot!.privateClues!.correct, uncertain);
        controller.dispose();
      }
    },
  );

  test(
    'background during a rejected answer stops automatic race retries',
    () async {
      final api = CluesApi()
        ..current = RoomSnapshot.parse(cluesFixture())
        ..commandGate = Completer<void>();
      api.responses.add(cluesFixture(version: 2));
      api.errors.add(const RoomFailure('VERSION_CONFLICT'));
      final controller = await connectClues(api, TestVault()..value = saved());
      addTearDown(controller.dispose);
      final sending = controller.play('clues.answer', {
        'answer': 'В памяти',
        'clueIndex': 0,
      });
      controller.setActive(false);
      api.commandGate!.complete();
      await sending;
      expect(api.leaves, hasLength(1));
      expect(controller.online, false);
      expect(controller.hasPending, false);
    },
  );

  testWidgets(
    'network answer, feedback, hint, reveal and final scores use v4 commands',
    (tester) async {
      final api = CluesApi()
        ..current = RoomSnapshot.parse(cluesFixture(clueIndex: 1));
      api.responses.addAll([
        cluesFixture(version: 2, clueIndex: 1, ownAnswer: 'Догадка'),
        cluesFixture(
          version: 3,
          clueIndex: 2,
          ownAnswer: 'Догадка',
          ownClue: 1,
        ),
        cluesFixture(version: 6, clueIndex: 2, phase: 'finished'),
        cluesFixture(version: 7),
      ]);
      final vault = TestVault()..value = saved();
      final controller = await connectClues(api, vault);
      await tester.pumpWidget(cluesApp(controller));
      await tester.pumpAndSettle();
      expect(find.text('Учебный ответ'), findsNothing);
      final field = find.byKey(const ValueKey('clues-network-answer'));
      await showCluesControl(tester, field);
      await tester.enterText(field, 'Догадка');
      await tapCluesControl(tester, find.text('Ответить'));
      expect(api.leaves.single.leave!['type'], 'clues.answer');
      expect(api.leaves.single.leave!['payload'], {
        'answer': 'Догадка',
        'clueIndex': 1,
      });
      api.receive!(api.current);
      await tester.pumpAndSettle();
      expect(find.textContaining('Пока не совпало.'), findsOneWidget);
      await tapCluesControl(tester, find.text('Следующая подсказка'));
      expect(api.leaves.last.leave!['type'], 'clues.hint');
      api.receive!(api.current);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('clues-network-answer')),
        findsOneWidget,
      );
      api.current = RoomSnapshot.parse(
        cluesFixture(
          version: 4,
          clueIndex: 2,
          ownAnswer: 'Учебный ответ',
          correct: true,
        ),
      );
      api.receive!(api.current);
      await tester.pumpAndSettle();
      expect(find.text('Верно! +2 очк. Ждём остальных.'), findsOneWidget);
      api.current = RoomSnapshot.parse(
        cluesFixture(version: 5, clueIndex: 2, phase: 'reveal', round: 4),
      );
      api.receive!(api.current);
      await tester.pumpAndSettle();
      expect(find.text('Учебный ответ'), findsOneWidget);
      expect(find.text('ОБЩИЙ СЧЁТ'), findsOneWidget);
      await tapCluesControl(tester, find.text('Показать итоги'));
      expect(api.leaves.last.leave!['type'], 'clues.next');
      api.receive!(api.current);
      await tester.pumpAndSettle();
      expect(find.textContaining('Победители:'), findsOneWidget);
      await tapCluesControl(tester, find.text('Сыграть ещё'));
      expect(api.leaves.last.leave!['type'], 'clues.start');
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets(
    'large text and keyboard preserve controls and discard private drafts',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      addTearDown(
        () => tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
      final semantics = tester.ensureSemantics();
      final api = CluesApi()..current = RoomSnapshot.parse(cluesFixture());
      final controller = await connectClues(api, TestVault()..value = saved());
      await tester.pumpWidget(cluesApp(controller, scale: 2));
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('clues-network-answer'));
      await showCluesControl(tester, field);
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      await tester.enterText(field, 'Личный черновик');
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('clues-network-answer')), findsNothing);
      expect(
        tester.getSemantics(find.byType(CluesPanel)).toStringDeep(),
        isNot(contains('Личный черновик')),
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(tester.widget<TextFormField>(field).controller!.text, isEmpty);
      await showCluesControl(tester, field);
      await tester.enterText(field, 'Другой черновик');
      api.disconnected!();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('clues-network-answer')), findsNothing);
      api.receive!(api.current);
      await tester.pumpAndSettle();
      expect(tester.widget<TextFormField>(field).controller!.text, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      semantics.dispose();
      controller.dispose();
    },
  );
}
