import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:partybox_mobile/main.dart' as application;
import 'package:partybox_mobile/src/rooms/room_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:partybox_mobile/src/design/night_theme.dart';
import 'package:partybox_mobile/src/settings/room_server_settings.dart';
import 'package:partybox_mobile/src/settings/room_server_screen.dart';

base class FailingServerPreferences extends InMemorySharedPreferencesAsync {
  FailingServerPreferences() : super.empty();
  bool fail = false;
  @override
  Future<bool> setString(
    String key,
    String value,
    SharedPreferencesOptions options,
  ) {
    if (fail) throw StateError('Synthetic storage failure');
    return super.setString(key, value, options);
  }
}

Future<void> showControl(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 30 && finder.hitTestable().evaluate().isEmpty; i++) {
    await tester.drag(find.byType(ListView).last, const Offset(0, -160));
    await tester.pumpAndSettle();
  }
  expect(finder.hitTestable(), findsOneWidget);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    final previous = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    addTearDown(() => SharedPreferencesAsyncPlatform.instance = previous);
  });

  test(
    'persist only normalized origin; saved configuration overrides build default',
    () async {
      final prefs = SharedPreferencesAsync();
      await prefs.setString('unrelated', 'keep');
      final settings = RoomServerSettings(
        defaultServer: 'https://build.example',
      );
      await settings.load();
      expect(settings.origin, 'https://build.example');
      await settings.save(' https://rooms.example:443/ ');
      final restored = RoomServerSettings(
        defaultServer: 'https://build.example',
      );
      await restored.load();
      expect(restored.origin, 'https://rooms.example');
      expect(
        await prefs.getString(RoomServerSettings.key),
        'https://rooms.example',
      );
      expect(await prefs.getString('unrelated'), 'keep');
    },
  );

  test(
    'release rejects insecure URLs, credentials, paths, fragments and invalid ports',
    () {
      final settings = RoomServerSettings();
      for (final address in [
        '',
        'rooms.example',
        'http://rooms.example',
        'https://name:secret@rooms.example',
        'https://rooms.example/api',
        'https://rooms.example?token=secret',
        'https://rooms.example#part',
        'https://rooms.example:0',
        'https://rooms.example:70000',
        'https://rooms.example:abc',
      ]) {
        expect(settings.normalize(address), null, reason: address);
      }
      expect(
        settings.normalize('https://rooms.example/'),
        'https://rooms.example',
      );
      expect(
        RoomServerSettings(
          allowInsecure: true,
        ).normalize('http://192.168.1.241:8720/'),
        'http://192.168.1.241:8720',
      );
    },
  );

  test(
    'invalid saved address never silently changes to another build server',
    () async {
      await SharedPreferencesAsync().setString(
        RoomServerSettings.key,
        'http://old.example',
      );
      final settings = RoomServerSettings(defaultServer: 'https://new.example');
      await settings.load();
      expect(settings.origin, null);
      expect(settings.error, isNotNull);
      expect(
        await SharedPreferencesAsync().getString(RoomServerSettings.key),
        'http://old.example',
      );
    },
  );

  test('failed save keeps previous active origin and can be retried', () async {
    final backend = FailingServerPreferences();
    SharedPreferencesAsyncPlatform.instance = backend;
    final settings = RoomServerSettings(
      defaultServer: 'https://original.example',
    );
    await settings.load();
    backend.fail = true;
    await expectLater(
      settings.save('https://new.example'),
      throwsA(isA<RoomServerSettingsFailure>()),
    );
    expect(settings.origin, 'https://original.example');
    backend.fail = false;
    await settings.save('https://new.example');
    expect(settings.origin, 'https://new.example');
  });

  testWidgets('configure HTTPS server and return to the selected game', (
    tester,
  ) async {
    final settings = RoomServerSettings();
    await settings.load();
    await tester.pumpWidget(
      MaterialApp(
        theme: nightTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push<bool>(
                MaterialPageRoute(
                  builder: (_) => RoomServerScreen(settings: settings),
                ),
              ),
              child: const Text('Настроить'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Настроить'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextFormField),
      'https://rooms.example/',
    );
    await showControl(tester, find.text('Сохранить адрес'));
    await tester.tap(find.text('Сохранить адрес'));
    await tester.pumpAndSettle();
    expect(settings.origin, 'https://rooms.example');
    expect(find.byType(RoomServerScreen), findsNothing);
    expect(find.text('Настроить'), findsOneWidget);
  });

  testWidgets(
    'unconfigured app opens server setup and preserves tolerance selection',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(application.createPartyBoxApp());
      await tester.pumpAndSettle();
      await showControl(tester, find.text('Играть в «Шкалу»'));
      await tester.tap(find.text('Играть в «Шкалу»'));
      await tester.pumpAndSettle();
      await showControl(tester, find.text('Создать комнату «Шкалы»'));
      await tester.tap(find.text('Создать комнату «Шкалы»'));
      await tester.pumpAndSettle();
      expect(find.byType(RoomServerScreen), findsOneWidget);
      await showControl(tester, find.byType(TextFormField));
      await tester.enterText(
        find.byType(TextFormField),
        'https://rooms.example',
      );
      await showControl(tester, find.text('Сохранить адрес'));
      await tester.tap(find.text('Сохранить адрес'));
      await tester.pumpAndSettle();
      expect(find.byType(RoomServerScreen), findsNothing);
      expect(
        tester.widget<RoomScreen>(find.byType(RoomScreen)).initialGame,
        'tolerance',
      );
      expect(find.textContaining('Играем в «Шкалу терпения».'), findsOneWidget);
      expect(
        await SharedPreferencesAsync().getString(RoomServerSettings.key),
        'https://rooms.example',
      );
      expect(tester.takeException(), null);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
