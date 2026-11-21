import 'package:flutter/material.dart';
import '../design/night_components.dart';
import '../design/night_theme.dart';
import 'room_server_settings.dart';

class RoomServerScreen extends StatefulWidget {
  const RoomServerScreen({super.key, required this.settings});
  final RoomServerSettings settings;

  @override
  State<RoomServerScreen> createState() => _RoomServerScreenState();
}

class _RoomServerScreenState extends State<RoomServerScreen> {
  final _form = GlobalKey<FormState>();
  late final _address = TextEditingController(
    text: widget.settings.origin ?? '',
  );
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _error = widget.settings.error;
  }

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || !_form.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.settings.save(_address.text);
      if (mounted) Navigator.of(context).pop(true);
    } on RoomServerSettingsFailure catch (failure) {
      if (mounted) setState(() => _error = failure.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: Scaffold(
      appBar: AppBar(title: const Text('ПОДКЛЮЧЕНИЕ КОМНАТ')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                const NightEyebrow('У КАЖДОГО СВОЙ ТЕЛЕФОН'),
                const SizedBox(height: 16),
                Text(
                  'Один адрес для всей компании.',
                  style: Theme.of(context).textTheme.headlineLarge,
                ),
                const SizedBox(height: 16),
                const Text(
                  'Укажите адрес, который дал организатор. Затем создайте '
                  'комнату или войдите по коду. У всех участников должен '
                  'быть один и тот же сервер.',
                ),
                const SizedBox(height: 24),
                NightPanel(
                  child: Form(
                    key: _form,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextFormField(
                          controller: _address,
                          enabled: !_saving,
                          keyboardType: TextInputType.url,
                          autocorrect: false,
                          enableSuggestions: false,
                          textInputAction: TextInputAction.done,
                          decoration: const InputDecoration(
                            labelText: 'Адрес сервера',
                            hintText: 'https://play.example.com',
                          ),
                          validator: (value) =>
                              widget.settings.normalize(value ?? '') == null
                              ? 'Укажите HTTPS-адрес без пути, логина и пароля.'
                              : null,
                          onFieldSubmitted: (_) => _save(),
                        ),
                        const SizedBox(height: 16),
                        const Text(
                          'При смене сервера прежняя комната остаётся на '
                          'старом адресе. Приложение предложит удалить '
                          'старый доступ с телефона перед новым входом.',
                          style: TextStyle(color: NightColors.muted),
                        ),
                        if (_error != null) ...[
                          const SizedBox(height: 16),
                          Semantics(
                            liveRegion: true,
                            child: Text(
                              _error!,
                              style: const TextStyle(color: NightColors.error),
                            ),
                          ),
                        ],
                        const SizedBox(height: 24),
                        NightButton(
                          label: _saving ? 'Сохраняем…' : 'Сохранить адрес',
                          onPressed: _saving ? null : _save,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
