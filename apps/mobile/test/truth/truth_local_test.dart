import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:partybox_game_core/partybox_game_core.dart';
import 'package:partybox_mobile/src/truth/truth_rules_screen.dart';

void main() {
  testWidgets('shared-phone round hides choices until the final bet', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: TruthLocalSetup(
          loadCards: () async => [
            for (var index = 0; index < 10; index++)
              TruthCard(
                id: 'card-$index',
                topic: 'science',
                statement: 'Проверочное утверждение',
                truth: true,
                explanation: 'Секретное объяснение',
                sources: [
                  (title: 'Проверочный источник', url: 'https://example.com'),
                ],
              ),
          ],
        ),
      ),
    );

    Future<void> tap(String label) async {
      final finder = find.text(label);
      await tester.ensureVisible(finder);
      await tester.pumpAndSettle();
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }

    await tap('Наука, ты серьёзно?');
    await tap('Начать партию');
    expect(find.text('Передайте телефон: Игрок 1'), findsOneWidget);
    expect(find.text('Правда'), findsNothing);
    await tap('Ответить тайно');
    await tap('Выдумка');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('Выдумка'), findsNothing);
    await tap('Ответить тайно');
    await tap('Выдумка');
    await tap('Подтвердить ответ');
    expect(find.text('Передайте телефон: Игрок 2'), findsOneWidget);
    expect(find.text('Выдумка'), findsNothing);

    await tap('Ответить тайно');
    await tap('Правда');
    await tap('Подтвердить ответ');
    await tap('Перейти к ставкам');
    await tap('Сделать ставку');
    await tap('Правда');
    await tap('Ставка 3');
    await tap('Подтвердить ставку');
    expect(find.text('Секретное объяснение'), findsNothing);
    expect(find.text('Ставка 3'), findsNothing);

    await tap('Сделать ставку');
    await tap('Выдумка');
    await tap('Ставка 2');
    await tap('Подтвердить ставку');
    expect(find.text('Секретное объяснение'), findsOneWidget);
    expect(find.text('Выдумка → Правда'), findsOneWidget);
    expect(find.text('Игрок 1 · 3'), findsOneWidget);
    expect(find.text('Игрок 2 · -2'), findsOneWidget);
    await tap('Следующий раунд');
    expect(find.text('РАУНД 2 ИЗ 10'), findsOneWidget);
    expect(find.text('Правда'), findsNothing);
  });
}
