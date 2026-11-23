import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:partybox_mobile/src/app.dart';
import 'package:partybox_mobile/src/design/night_theme.dart';
import 'package:partybox_mobile/src/rooms/room_controller.dart';
import 'package:partybox_mobile/src/rooms/room_invitation.dart';
import 'package:partybox_mobile/src/rooms/room_screen.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'support.dart';

void main() {
  testWidgets('QR button is labelled and readable on the accent room panel', (
    tester,
  ) async {
    final api = FakeRoomApi();
    final controller = RoomController(
      api: api,
      vault: TestVault()..value = saved(),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: nightTheme(),
        home: RoomScreen(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    await settleRoomContent(tester);
    final label = find.text('Показать QR-код');
    expect(label, findsOneWidget);
    final button = tester.widget<OutlinedButton>(
      find.ancestor(of: label, matching: find.byType(OutlinedButton)),
    );
    expect(button.style!.foregroundColor!.resolve({}), NightColors.ink);
    await tester.ensureVisible(label);
    await tester.tap(label);
    await tester.pumpAndSettle();
    expect(find.byType(QrImageView), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  test('invitation contains only the room locator and rejects unsafe URLs', () {
    final invite = RoomInvitation.create(
      'https://partybox.sorima.tech',
      '001234',
    );
    expect(invite.uri.toString(), 'https://partybox.sorima.tech/?room=001234');
    expect(
      RoomInvitation.parse(
        Uri.parse(
          '${invite.uri}&server=https://evil.example&guestToken=secret',
        ),
      )!.uri,
      invite.uri,
    );
    for (final input in [
      'https://x/?room=12345',
      'https://x/?room=123456&room=654321',
      'https://user:secret@x/?room=123456',
      'https://x/path?room=123456',
      'https://x/?room=123456#secret',
      'file:///x?room=123456',
      'https://x:0/?room=123456',
    ]) {
      expect(RoomInvitation.parse(Uri.parse(input)), null, reason: input);
    }
    expect(
      () => RoomInvitation.create('https://x/?token=secret', '001234'),
      throwsArgumentError,
    );
    expect(
      RoomInvitation.create('http://127.0.0.1:8729', '001234').isLoopback,
      true,
    );
    expect(
      RoomInvitation.create('http://[::1]:8729', '001234').isLoopback,
      true,
    );
    expect(
      RoomInvitation.create('http://192.168.1.241:8729', '001234').isLoopback,
      false,
    );
  });

  test('scanned invitations preserve origin and enforce release transport', () {
    final invitation = RoomInvitation.fromQr(
      'https://partybox.example:8443/?room=001234',
      allowInsecure: false,
    );
    expect(invitation?.origin, 'https://partybox.example:8443');
    expect(invitation?.pin, '001234');
    for (final code in [
      null,
      '001234',
      'https://partybox.example/?room=123456&room=654321',
      'https://partybox.example/?room=%FF',
      'https://localhost/?room=001234',
      'http://192.168.1.10:8729/?room=001234',
    ]) {
      expect(RoomInvitation.fromQr(code, allowInsecure: false), isNull);
    }
    expect(
      RoomInvitation.fromQr(
        'http://192.168.1.10:8729/?room=001234',
        allowInsecure: true,
      )?.pin,
      '001234',
    );
  });

  testWidgets('QR and clipboard carry the same public invitation', (
    tester,
  ) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final invite = RoomInvitation.create(
      'https://partybox.sorima.tech',
      '001234',
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: nightTheme(),
        home: Scaffold(body: RoomInvitationDialog(invitation: invite)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(QrImageView), findsOneWidget);
    expect(
      tester.widget<SelectableText>(find.byType(SelectableText)).data,
      invite.uri.toString(),
    );
    await tester.tap(find.text('Скопировать ссылку'));
    await tester.pumpAndSettle();
    expect(copied, invite.uri.toString());
    expect(find.text('Ссылка скопирована'), findsOneWidget);
  });

  testWidgets(
    'clipboard failure, large text and loopback have usable fallbacks',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            throw PlatformException(code: 'denied');
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: nightTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: RoomInvitationDialog(
              invitation: RoomInvitation.create(
                'http://localhost:8729',
                '001234',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(QrImageView), findsNothing);
      expect(find.byType(SelectableText), findsOneWidget);
      await tester.ensureVisible(find.text('Скопировать ссылку'));
      await tester.tap(find.text('Скопировать ссылку'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), null);
      final status = find.text(
        'Не удалось скопировать. Выделите ссылку выше и скопируйте вручную.',
      );
      await tester.ensureVisible(status);
      expect(status, findsOneWidget);
    },
  );

  testWidgets(
    'invitation opens one join screen, prefills PIN and waits for a name',
    (tester) async {
      final api = FakeRoomApi();
      var calls = 0;
      await tester.pumpWidget(
        PartyBoxApp(
          initialRoomPin: '001234',
          roomControllerFactory: () {
            calls++;
            return RoomController(api: api, vault: TestVault());
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(find.byType(RoomScreen), findsOneWidget);
      expect(api.enrollments, isEmpty);
      final pin = find.byType(TextFormField).last;
      expect(tester.widget<TextFormField>(pin).controller!.text, '001234');
      await tester.enterText(find.byType(TextFormField).first, 'Друг');
      await tester.ensureVisible(find.text('Войти в комнату'));
      await tester.tap(find.text('Войти в комнату'));
      await tester.pumpAndSettle();
      expect(api.enrollments.single.pin, '001234');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('another saved room is never silently left or replaced', (
    tester,
  ) async {
    final api = FakeRoomApi();
    final vault = TestVault()..value = saved();
    await tester.pumpWidget(
      MaterialApp(
        theme: nightTheme(),
        home: RoomScreen(
          controller: RoomController(api: api, vault: vault),
          initialPin: '999999',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('У вас уже есть другая комната'), findsOneWidget);
    expect(api.enrollments, isEmpty);
    expect(api.leaves, isEmpty);
    expect(vault.value!.token, testToken);
    await tester.tap(find.text('Выйти и открыть приглашение'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    expect(api.leaves, isEmpty);
    expect(vault.value!.token, testToken);
    await tester.tap(find.text('Остаться в текущей'));
    await tester.pumpAndSettle();
    expect(find.text('У вас уже есть другая комната'), findsNothing);
    expect(api.enrollments, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
