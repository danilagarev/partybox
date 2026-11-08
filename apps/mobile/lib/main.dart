import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'src/rooms/room_api.dart';
import 'src/rooms/room_controller.dart';
import 'src/rooms/room_vault.dart';

import 'src/app.dart';
import 'src/storage/preferences_spy_setup_store.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  const server = String.fromEnvironment('ROOM_SERVER_URL');
  final RoomVault vault = kIsWeb ? MemoryRoomVault() : SecureRoomVault();
  runApp(
    PartyBoxApp(
      setupStore: PreferencesSpySetupStore(),
      roomControllerFactory: server.isEmpty
          ? null
          : () => RoomController(
              api: HttpRoomApi(server, allowInsecure: !kReleaseMode),
              vault: vault,
            ),
    ),
  );
}
