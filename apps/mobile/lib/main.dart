import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'src/rooms/room_api.dart';
import 'src/rooms/room_invitation.dart';
import 'src/rooms/room_controller.dart';
import 'src/rooms/room_vault.dart';
import 'src/rooms/session_room_vault.dart';
import 'src/design/night_components.dart';
import 'src/settings/room_server_settings.dart';
import 'src/settings/room_server_screen.dart';

import 'src/app.dart';
import 'src/storage/preferences_spy_setup_store.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(createPartyBoxApp());
}

Widget createPartyBoxApp({
  String configuredServer = const String.fromEnvironment(
    'ROOM_SERVER_URL',
    defaultValue: 'https://partybox.sorima.tech',
  ),
  Uri? launchUri,
}) {
  final entry = launchUri ?? (kIsWeb ? Uri.base : null);
  final invitation = entry == null ? null : RoomInvitation.parse(entry);
  const browserRooms = bool.fromEnvironment('BROWSER_ROOMS');
  final defaultServer = kIsWeb && configuredServer == 'same-origin'
      ? Uri.base.origin
      : configuredServer;
  final RoomVault vault = kIsWeb
      ? (browserRooms && (!kReleaseMode || Uri.base.scheme == 'https')
            ? SessionRoomVault()
            : MemoryRoomVault())
      : SecureRoomVault();
  final settings = RoomServerSettings(
    defaultServer: defaultServer,
    allowInsecure: !kReleaseMode,
  );
  final loaded = settings.load();

  Future<void> configureServer(BuildContext context) async {
    await loaded;
    if (!context.mounted || ModalRoute.of(context)?.isCurrent != true) return;
    await Navigator.of(context).push<bool>(
      NightRoute(builder: (_) => RoomServerScreen(settings: settings)),
    );
  }

  Future<RoomController?> resolveController(BuildContext context) async {
    await loaded;
    if (!context.mounted || ModalRoute.of(context)?.isCurrent != true) {
      return null;
    }
    if (settings.origin == null && invitation == null) {
      await configureServer(context);
    }
    // An invitation belongs to its web origin. Never redirect it to a saved
    // custom server; the vault still requires explicit handling of old access.
    final server = invitation?.origin ?? settings.origin;
    if (!context.mounted || server == null) return null;
    return RoomController(
      api: HttpRoomApi(server, allowInsecure: !kReleaseMode),
      vault: vault,
    );
  }

  return PartyBoxApp(
    initialRoomPin: invitation?.pin,
    setupStore: PreferencesSpySetupStore(),
    resolveRoomController: resolveController,
    onConfigureServer: configureServer,
  );
}
