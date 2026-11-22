import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// An invitation locates a room; authentication is always a separate enrollment.
final class RoomInvitation {
  const RoomInvitation._(this.uri, this.pin);
  final Uri uri;
  final String pin;
  String get origin => uri.origin;
  bool get isLoopback {
    final host = uri.host.toLowerCase();
    return host == 'localhost' ||
        host.endsWith('.localhost') ||
        host == '::1' ||
        host == '0.0.0.0' ||
        host == '::' ||
        RegExp(r'^127\.').hasMatch(host);
  }

  static RoomInvitation? parse(Uri uri) {
    if (!const {'http', 'https'}.contains(uri.scheme) ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        RegExp(r'\s').hasMatch(uri.host) ||
        uri.userInfo.isNotEmpty ||
        (uri.hasPort && (uri.port < 1 || uri.port > 65535)) ||
        (uri.path != '' && uri.path != '/') ||
        uri.hasFragment) {
      return null;
    }
    final values = uri.queryParametersAll['room'];
    if (values == null ||
        values.length != 1 ||
        !RegExp(r'^\d{6}$').hasMatch(values.single)) {
      return null;
    }
    return RoomInvitation._(
      Uri.parse(
        uri.origin,
      ).replace(path: '/', queryParameters: {'room': values.single}),
      values.single,
    );
  }

  static RoomInvitation create(String origin, String pin) {
    final base = Uri.tryParse(origin);
    if (base == null || base.hasQuery || base.hasFragment) {
      throw ArgumentError('Invalid invitation origin');
    }
    final invitation = parse(base.replace(queryParameters: {'room': pin}));
    if (invitation == null) throw ArgumentError('Invalid room invitation');
    return invitation;
  }
}

class RoomInvitationDialog extends StatefulWidget {
  const RoomInvitationDialog({super.key, required this.invitation});
  final RoomInvitation invitation;
  @override
  State<RoomInvitationDialog> createState() => _RoomInvitationDialogState();
}

class _RoomInvitationDialogState extends State<RoomInvitationDialog> {
  String? _copyStatus;
  Future<void> _copy() async {
    try {
      await Clipboard.setData(
        ClipboardData(text: widget.invitation.uri.toString()),
      );
      if (mounted) setState(() => _copyStatus = 'Ссылка скопирована');
    } catch (_) {
      if (mounted) {
        setState(
          () => _copyStatus =
              'Не удалось скопировать. Выделите ссылку выше и скопируйте вручную.',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final invitation = widget.invitation;
    final qrSize =
        (MediaQuery.sizeOf(context).width -
                MediaQuery.paddingOf(context).horizontal -
                128)
            .clamp(120.0, 248.0);
    return AlertDialog(
      scrollable: true,
      title: const Text('Пригласить друзей'),
      content: SizedBox(
        width: 320,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (invitation.isLoopback)
                const Text(
                  'Этот адрес открывается только на текущем компьютере. Для QR на телефоне откройте сайт по LAN-адресу компьютера.',
                )
              else ...[
                const Text(
                  'Наведите камеру телефона. Код комнаты уже будет заполнен — останется ввести имя.',
                ),
                const SizedBox(height: 16),
                Center(
                  child: SizedBox.square(
                    dimension: qrSize,
                    child: QrImageView(
                      data: invitation.uri.toString(),
                      version: QrVersions.auto,
                      size: qrSize,
                      padding: const EdgeInsets.all(28),
                      backgroundColor: Colors.white,
                      errorCorrectionLevel: QrErrorCorrectLevel.M,
                      semanticsLabel:
                          'QR приглашения в комнату ${invitation.pin.split('').join(' ')}',
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Text(
                'Код: ${invitation.pin.substring(0, 3)} ${invitation.pin.substring(3)}',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              SelectableText(invitation.uri.toString()),
              if (_copyStatus != null) ...[
                const SizedBox(height: 12),
                Semantics(liveRegion: true, child: Text(_copyStatus!)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Закрыть'),
        ),
        FilledButton.icon(
          onPressed: _copy,
          icon: const Icon(Icons.link),
          label: const Text('Скопировать ссылку'),
        ),
      ],
    );
  }
}
