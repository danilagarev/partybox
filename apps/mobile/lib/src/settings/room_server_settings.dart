import 'package:shared_preferences/shared_preferences.dart';

/// Only the public origin is stored here. Guest access remains in RoomVault.
final class RoomServerSettings {
  RoomServerSettings({
    SharedPreferencesAsync? preferences,
    this.defaultServer = '',
    this.allowInsecure = false,
  }) : _preferences = preferences ?? SharedPreferencesAsync();

  static const key = 'partybox.rooms.server.v1';
  final SharedPreferencesAsync _preferences;
  final String defaultServer;
  final bool allowInsecure;
  String? origin;
  String? error;

  String? normalize(String input) {
    final uri = Uri.tryParse(input.trim());
    if (uri == null ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        RegExp(r'\s').hasMatch(uri.host) ||
        (uri.hasPort && (uri.port < 1 || uri.port > 65535)) ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        (uri.scheme != 'https' && !(allowInsecure && uri.scheme == 'http'))) {
      return null;
    }
    return uri.origin;
  }

  Future<void> load() async {
    error = null;
    try {
      final saved = await _preferences.getString(key);
      final value = saved ?? defaultServer;
      if (value.isEmpty) {
        origin = null;
      } else {
        origin = normalize(value);
        if (origin == null) {
          error = 'Сохранённый адрес не подходит. Укажите HTTPS-адрес сервера.';
        }
      }
    } catch (_) {
      origin = null;
      error = 'Не удалось прочитать адрес сервера. Его можно сохранить заново.';
    }
  }

  Future<void> save(String input) async {
    final value = normalize(input);
    if (value == null) {
      throw const RoomServerSettingsFailure('Проверьте адрес сервера.');
    }
    try {
      await _preferences.setString(key, value);
    } catch (_) {
      throw const RoomServerSettingsFailure(
        'Не удалось сохранить адрес. Попробуйте ещё раз.',
      );
    }
    origin = value;
    error = null;
  }
}

final class RoomServerSettingsFailure implements Exception {
  const RoomServerSettingsFailure(this.message);
  final String message;
}
