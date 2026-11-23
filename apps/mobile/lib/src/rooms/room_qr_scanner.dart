import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../design/night_theme.dart';
import 'room_invitation.dart';

class RoomQrScanner extends StatefulWidget {
  const RoomQrScanner({super.key});

  @override
  State<RoomQrScanner> createState() => _RoomQrScannerState();
}

class _RoomQrScannerState extends State<RoomQrScanner> {
  bool _accepted = false;
  bool _invalidCode = false;

  void _onDetect(BarcodeCapture capture) {
    if (!mounted || _accepted || ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    final codes = capture.barcodes.where(
      (barcode) => barcode.format == BarcodeFormat.qrCode,
    );
    for (final code in codes) {
      final invitation = RoomInvitation.fromQr(
        code.rawValue,
        allowInsecure: !kReleaseMode,
      );
      if (invitation != null) {
        _accepted = true;
        Navigator.of(context).pop(invitation);
        return;
      }
    }
    if (!_invalidCode && codes.isNotEmpty) {
      setState(() => _invalidCode = true);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Сканировать QR')),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(24),
            children: [
              Semantics(
                liveRegion: true,
                child: Text(
                  _invalidCode
                      ? 'Приглашение не распознано. Попросите ведущего показать QR-код комнаты PartyBox.'
                      : 'Наведите камеру на QR-код комнаты PartyBox.',
                  style: TextStyle(
                    color: _invalidCode ? NightColors.error : NightColors.text,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: AspectRatio(
                  aspectRatio: 4 / 3,
                  child: MobileScanner(
                    onDetect: _onDetect,
                    placeholderBuilder: (_) => const ColoredBox(
                      color: NightColors.surface,
                      child: Center(child: CircularProgressIndicator()),
                    ),
                    errorBuilder: (context, error) => _cameraError(error),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _cameraError(MobileScannerException error) {
    final message = switch (error.errorCode) {
      MobileScannerErrorCode.permissionDenied =>
        'Разрешите доступ к камере в настройках и откройте сканер снова.',
      MobileScannerErrorCode.unsupported =>
        'На этом устройстве камера недоступна.',
      _ => 'Не удалось открыть сканер. Попробуйте открыть его снова.',
    };
    return ColoredBox(
      color: NightColors.surface,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Semantics(
            liveRegion: true,
            child: Text(
              '$message ${kIsWeb ? 'В браузере камера работает через HTTPS. ' : ''}'
              'Можно вернуться и войти по коду.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}
