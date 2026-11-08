import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:partybox_mobile/src/design/night_theme.dart';
import 'package:partybox_mobile/src/design/role_peek_card.dart';
import 'support/role_peek_flow.dart';

class PeekHarness extends StatefulWidget {
  const PeekHarness({super.key, this.reduced = false});
  final bool reduced;
  @override
  State<PeekHarness> createState() => PeekHarnessState();
}

class PeekHarnessState extends State<PeekHarness> {
  bool revealed = false, enabled = true, viewed = false;
  int confirmations = 0;
  int concealEpoch = 0;
  void hide() => setState(() {
    revealed = false;
    concealEpoch++;
  });
  void enable(bool value) => setState(() => enabled = value);
  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: nightTheme(),
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: widget.reduced),
      child: Scaffold(
        body: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: RolePeekCard(
              revealed: revealed,
              enabled: enabled,
              viewed: viewed,
              concealEpoch: concealEpoch,
              onReveal: () => setState(() {
                revealed = true;
                viewed = true;
              }),
              onConceal: hide,
              onContinue: () => setState(() => confirmations++),
              continueLabel: 'Скрыть и передать',
              closedContinueLabel: 'Передать телефон',
              secretBuilder: (_) => const Padding(
                padding: EdgeInsets.all(24),
                child: Text('Тестовый секрет'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  void hidden(WidgetTester tester) {
    expect(find.text('Тестовый секрет'), findsNothing);
    expect(
      tester.getSemantics(find.byType(RolePeekCard)).toStringDeep(),
      isNot(contains('Тестовый секрет')),
    );
  }

  testWidgets(
    'concealment before the first revealed frame still invalidates a held gesture',
    (tester) async {
      final key = GlobalKey<PeekHarnessState>();
      await tester.pumpWidget(PeekHarness(key: key));
      await tester.pumpAndSettle();
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('role-peek-surface'))),
      );
      await gesture.moveBy(const Offset(0, -24));
      await tester.pump();
      await gesture.moveBy(const Offset(0, -90));
      expect(key.currentState!.revealed, true);
      key.currentState!.hide();
      await tester.pump();
      await gesture.moveBy(const Offset(0, -120));
      await tester.pump();
      expect(find.text('Тестовый секрет'), findsNothing);
      await gesture.up();
    },
  );

  for (final reduced in [false, true]) {
    testWidgets(
      'hold reveals, release removes secret and needs explicit confirmation, reduced=$reduced',
      (tester) async {
        final semantics = tester.ensureSemantics();
        try {
          final key = GlobalKey<PeekHarnessState>();
          await tester.pumpWidget(PeekHarness(key: key, reduced: reduced));
          await tester.pumpAndSettle();
          hidden(tester);
          expect(find.text('Передать телефон'), findsNothing);
          final gesture = await holdCard(tester);
          expect(find.text('Тестовый секрет'), findsOneWidget);
          expect(key.currentState!.confirmations, 0);
          await gesture.up();
          await tester.pump();
          hidden(tester);
          expect(key.currentState!.confirmations, 0);
          await tester.ensureVisible(find.text('Передать телефон'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Передать телефон'));
          expect(key.currentState!.confirmations, 1);
        } finally {
          semantics.dispose();
        }
      },
    );
  }

  testWidgets(
    'short or downward movement does not reveal; cancel hides immediately',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(const PeekHarness());
        await tester.pumpAndSettle();
        final surface = find.byKey(const ValueKey('role-peek-surface'));
        for (final delta in [-25.0, 90.0]) {
          final gesture = await tester.startGesture(tester.getCenter(surface));
          await gesture.moveBy(Offset(0, delta.sign * 24));
          await tester.pump();
          await gesture.moveBy(Offset(0, delta));
          await tester.pump();
          hidden(tester);
          await gesture.up();
          await tester.pumpAndSettle();
        }
        final gesture = await holdCard(tester);
        expect(find.text('Тестовый секрет'), findsOneWidget);
        await gesture.cancel();
        await tester.pump();
        hidden(tester);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'second finger closes the role and cannot take over the held gesture',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(const PeekHarness());
        await tester.pumpAndSettle();
        final first = await holdCard(tester);
        final second = await tester.startGesture(
          tester.getCenter(find.byKey(const ValueKey('role-peek-surface'))),
          pointer: 2,
        );
        await tester.pump();
        hidden(tester);
        await first.up();
        await second.moveBy(const Offset(0, -120));
        await tester.pump();
        hidden(tester);
        await second.up();
        await tester.pumpAndSettle();
        final fresh = await holdCard(tester, pointer: 3);
        expect(find.text('Тестовый секрет'), findsOneWidget);
        await fresh.up();
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets('background and resume invalidate the held gesture', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(const PeekHarness());
      await tester.pumpAndSettle();
      final gesture = await holdCard(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      hidden(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await gesture.moveBy(const Offset(0, -120));
      await tester.pump();
      hidden(tester);
      await gesture.up();
      final fresh = await holdCard(tester, pointer: 2);
      expect(find.text('Тестовый секрет'), findsOneWidget);
      await fresh.up();
    } finally {
      semantics.dispose();
    }
  });

  for (final disable in [false, true]) {
    testWidgets('external concealment invalidates gesture, disable=$disable', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      try {
        final key = GlobalKey<PeekHarnessState>();
        await tester.pumpWidget(PeekHarness(key: key));
        await tester.pumpAndSettle();
        final gesture = await holdCard(tester);
        if (disable) {
          key.currentState!.enable(false);
        } else {
          key.currentState!.hide();
        }
        await tester.pump();
        hidden(tester);
        key.currentState!.hide();
        key.currentState!.enable(true);
        await tester.pump();
        await gesture.moveBy(const Offset(0, -120));
        await tester.pump();
        hidden(tester);
        await gesture.up();
      } finally {
        semantics.dispose();
      }
    });
  }

  testWidgets(
    'button alternative opens without holding and can conceal again',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(const PeekHarness());
        await tester.pumpAndSettle();
        await tester.tap(find.text('Показать мою роль'));
        await tester.pumpAndSettle();
        expect(find.text('Тестовый секрет'), findsOneWidget);
        await tester.tap(find.text('Скрыть роль'));
        await tester.pump();
        hidden(tester);
      } finally {
        semantics.dispose();
      }
    },
  );
}
