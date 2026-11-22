import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:partybox_game_core/partybox_game_core.dart';
import 'package:partybox_mobile/src/clues/clues_game_screen.dart';
import 'package:partybox_mobile/src/clues/clues_pack.dart';
import 'package:partybox_mobile/src/design/night_theme.dart';

CluesPack fixture() => CluesPack(
  id: 'fixture',
  version: 1,
  questions: List.generate(
    10,
    (i) => CluesQuestion(
      id: 'q$i',
      answer: 'Тестовый ответ',
      aliases: ['Ответ'],
      clues: [
        'Первый намёк $i',
        'Второй намёк $i',
        'Третий намёк $i',
        'Четвёртый намёк $i',
      ],
    ),
  ),
);

Future<void> tapVisible(WidgetTester tester, String label) async {
  final finder = find.text(label);
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('bundled solo content loads and rotates without early repeats', (
    tester,
  ) async {
    final pack = await CluesPack.load();
    expect(pack.questions.length, greaterThanOrEqualTo(60));
    final deck = CluesDeck(pack, random: Random(42));
    final seen = <String>{};
    for (var batch = 0; batch < pack.questions.length ~/ 5; batch++) {
      var game = deck.start();
      for (var round = 0; round < 5; round++) {
        for (var hint = 0; hint < 4; hint++) {
          game = game.nextHint();
        }
        expect(seen.add(game.revealedAnswer!), true);
        game = game.nextRound();
      }
    }
    expect(seen.length, pack.questions.length ~/ 5 * 5);
  });

  test('deck draws all bundled questions before reusing them', () {
    final deck = CluesDeck(fixture(), random: Random(1));
    final clues = <String>{};
    for (var batch = 0; batch < 2; batch++) {
      var game = deck.start();
      for (var round = 0; round < 5; round++) {
        expect(clues.add(game.visibleClues.first), true);
        game = game.answer('Ответ').nextRound();
      }
    }
    expect(clues, hasLength(10));
  });

  testWidgets('complete solo cycle, incorrect attempt, reveal and replay', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        theme: nightTheme(),
        home: CluesGameScreen(
          packLoader: () async => fixture(),
          random: Random(1),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Тестовый ответ'), findsNothing);
    expect(find.textContaining('Второй намёк'), findsNothing);
    await tester.enterText(
      find.byKey(const ValueKey('clues-answer')),
      'Ошибка',
    );
    await tapVisible(tester, 'Ответить · 4 очк.');
    expect(find.text('Тестовый ответ'), findsNothing);
    await tapVisible(tester, 'Следующая подсказка · 3 очк.');
    expect(find.textContaining('Второй намёк'), findsOneWidget);
    for (var round = 0; round < 5; round++) {
      await tester.ensureVisible(find.byKey(const ValueKey('clues-answer')));
      await tester.enterText(
        find.byKey(const ValueKey('clues-answer')),
        'ОТВЕТ!',
      );
      await tapVisible(
        tester,
        round == 0 ? 'Ответить · 3 очк.' : 'Ответить · 4 очк.',
      );
      expect(
        find.byKey(const ValueKey('clues-revealed-answer')),
        findsOneWidget,
      );
      await tapVisible(
        tester,
        round == 4 ? 'Посмотреть результат' : 'Следующее задание',
      );
      if (round < 4) expect(find.text('Тестовый ответ'), findsNothing);
    }
    expect(find.text('19 из 20 очков'), findsOneWidget);
    await tapVisible(tester, 'Ещё пять заданий');
    expect(find.text('Счёт: 0'), findsOneWidget);
    expect(find.text('Тестовый ответ'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    semantics.dispose();
  });

  testWidgets('small screen, large text, keyboard and load retry', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    var loads = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: nightTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: CluesGameScreen(
          packLoader: () async {
            if (loads++ == 0) throw StateError('Synthetic load failure');
            return fixture();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tapVisible(tester, 'Повторить загрузку');
    final field = find.byKey(const ValueKey('clues-answer'));
    tester.view.viewInsets = const FakeViewPadding(bottom: 260);
    await tester.pumpAndSettle();
    await tester.ensureVisible(field);
    await tester.enterText(field, '');
    await tapVisible(tester, 'Ответить · 4 очк.');
    expect(find.text('Напишите свой ответ'), findsOneWidget);
    await tester.ensureVisible(field);
    await tester.enterText(field, 'Ответ');
    await tapVisible(tester, 'Ответить · 4 очк.');
    expect(find.byKey(const ValueKey('clues-revealed-answer')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('back confirms abandoning an active solo game', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: nightTheme(),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) =>
                    CluesGameScreen(packLoader: () async => fixture()),
              ),
            ),
            child: const Text('Открыть'),
          ),
        ),
      ),
    );
    await tapVisible(tester, 'Открыть');
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('Завершить партию?'), findsOneWidget);
    await tapVisible(tester, 'Продолжить игру');
    expect(find.byKey(const ValueKey('clues-answer')), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tapVisible(tester, 'Завершить');
    expect(find.text('Открыть'), findsOneWidget);
  });
}
