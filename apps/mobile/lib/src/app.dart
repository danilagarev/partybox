import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'catalog/game_card.dart';
import 'clues/clues_game_screen.dart';
import 'design/night_components.dart';
import 'design/night_gallery.dart';
import 'design/night_theme.dart';
import 'design/night_scene.dart';
import 'spy/spy_game_screen.dart';
import 'storage/spy_setup.dart';
import 'rooms/room_controller.dart';
import 'rooms/room_screen.dart';

class PartyBoxApp extends StatelessWidget {
  const PartyBoxApp({
    super.key,
    this.setupStore,
    this.roomControllerFactory,
    this.resolveRoomController,
    this.onConfigureServer,
    this.initialRoomPin,
  });
  final String? initialRoomPin;
  final SpySetupStore? setupStore;
  final RoomController Function()? roomControllerFactory;
  final Future<RoomController?> Function(BuildContext)? resolveRoomController;
  final Future<void> Function(BuildContext)? onConfigureServer;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'PartyBox',
    initialRoute: '/',
    locale: const Locale('ru'),
    supportedLocales: const [Locale('ru')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    debugShowCheckedModeBanner: false,
    theme: nightTheme(),
    home: const bool.fromEnvironment('DESIGN_GALLERY') && !kReleaseMode
        ? const NightGallery()
        : CatalogScreen(
            setupStore: setupStore,
            roomControllerFactory: roomControllerFactory,
            resolveRoomController: resolveRoomController,
            onConfigureServer: onConfigureServer,
            initialRoomPin: initialRoomPin,
          ),
  );
}

class CatalogScreen extends StatefulWidget {
  const CatalogScreen({
    super.key,
    this.setupStore,
    this.roomControllerFactory,
    this.resolveRoomController,
    this.onConfigureServer,
    this.initialRoomPin,
  });
  final String? initialRoomPin;
  final SpySetupStore? setupStore;
  final RoomController Function()? roomControllerFactory;
  final Future<RoomController?> Function(BuildContext)? resolveRoomController;
  final Future<void> Function(BuildContext)? onConfigureServer;

  @override
  State<CatalogScreen> createState() => _CatalogScreenState();
}

class _CatalogScreenState extends State<CatalogScreen> {
  // A connection resolver may await storage or configuration before pushing a
  // route. Keep one navigation intent across all entry points during that gap.
  bool _openingConnection = false;

  @override
  void initState() {
    super.initState();
    final pin = widget.initialRoomPin;
    if (pin != null && RegExp(r'^\d{6}$').hasMatch(pin)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_openRoom(context, joining: true, pin: pin));
      });
    }
  }

  Future<void> _configureServer(BuildContext context) async {
    if (_openingConnection || ModalRoute.of(context)?.isCurrent != true) return;
    _openingConnection = true;
    try {
      await widget.onConfigureServer?.call(context);
    } finally {
      _openingConnection = false;
    }
  }

  void _showDetails(BuildContext context, WidgetBuilder builder) {
    if (_openingConnection || ModalRoute.of(context)?.isCurrent != true) return;
    Navigator.of(context).push<void>(NightRoute(builder: builder));
  }

  Future<void> _openRoom(
    BuildContext context, {
    String? game,
    bool joining = false,
    String? pin,
  }) async {
    if (_openingConnection || ModalRoute.of(context)?.isCurrent != true) return;
    _openingConnection = true;
    try {
      final controller =
          widget.roomControllerFactory?.call() ??
          await widget.resolveRoomController?.call(context);
      if (!mounted ||
          !context.mounted ||
          ModalRoute.of(context)?.isCurrent != true) {
        controller?.dispose();
        return;
      }
      if (controller == null) return;
      await Navigator.of(context).push<void>(
        NightRoute(
          builder: (_) => RoomScreen(
            controller: controller,
            initialGame: game,
            initialJoining: joining,
            initialPin: pin,
          ),
        ),
      );
    } finally {
      _openingConnection = false;
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
            children: [
              const NightEyebrow('PARTYBOX · ИГРЫ ДЛЯ КОМПАНИИ'),
              const SizedBox(height: 12),
              NightEntrance(
                child: Text(
                  'Вечер, который\nсближает.',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                'Три игры. Для себя и своей компании.',
                style: TextStyle(color: NightColors.muted),
              ),
              const SizedBox(height: 24),
              const Wrap(
                spacing: 20,
                runSpacing: 6,
                alignment: WrapAlignment.spaceBetween,
                children: [
                  NightEyebrow('ВЫБЕРИТЕ ИГРУ'),
                  Text(
                    '1–12 человек',
                    style: TextStyle(fontSize: 12, color: NightColors.muted),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              CatalogGameCard(
                title: 'Шпион',
                genre: 'ДЕДУКЦИЯ',
                tolerance: false,
                description: 'Все знают место. Один делает вид.',
                metadata: '4–12 игроков · от 5 минут',
                mode: 'Один телефон или у каждого свой',
                action: 'Играть в «Шпиона»',
                onPressed: () => _showDetails(
                  context,
                  (detailsContext) => SpyRulesScreen(
                    setupStore: widget.setupStore,
                    onOpenRoom: () => _openRoom(detailsContext, game: 'spy'),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              CatalogGameCard(
                title: 'Шкала терпения',
                genre: 'УЗНАЙТЕ ДРУГ ДРУГА',
                tolerance: true,
                description: 'У всех свой предел. Угадайте, где чужой.',
                metadata: '4–12 игроков · по раунду на каждого',
                mode: 'У каждого свой телефон',
                action: 'Играть в «Шкалу»',
                onPressed: () => _showDetails(
                  context,
                  (detailsContext) => ToleranceRulesScreen(
                    onOpenRoom: () =>
                        _openRoom(detailsContext, game: 'tolerance'),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              CatalogGameCard(
                title: 'Что объединяет?',
                genre: 'ПОДСКАЗКИ И ДОГАДКИ',
                tolerance: false,
                clues: true,
                description: 'Четыре подсказки. Один общий ответ.',
                metadata: '1–12 игроков · пять заданий',
                mode: 'Одному без сети или с друзьями в комнате',
                action: 'Играть в «Что объединяет?»',
                onPressed: () => _showDetails(
                  context,
                  (detailsContext) => CluesRulesScreen(
                    onOpenRoom: () => _openRoom(detailsContext, game: 'clues'),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              OutlinedButton.icon(
                onPressed: () => _openRoom(context, joining: true),
                icon: const Icon(Icons.meeting_room_outlined),
                label: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('Войти / вернуться в комнату'),
                ),
              ),
              if (widget.onConfigureServer != null)
                TextButton.icon(
                  onPressed: () => _configureServer(context),
                  icon: const Icon(Icons.tune, size: 18),
                  label: const Text('Подключение комнат'),
                ),
              const SizedBox(height: 8),
              const Text(
                'Уже играете с друзьями? Введите код или продолжите с сохранённого места.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: NightColors.muted),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class SpyRulesScreen extends StatelessWidget {
  const SpyRulesScreen({super.key, this.setupStore, this.onOpenRoom});
  final SpySetupStore? setupStore;
  final VoidCallback? onOpenRoom;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('ШПИОН')),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const NightScene(kind: NightSceneKind.spy, height: 150),
              const SizedBox(height: 20),
              const NightEyebrow('ПРАВИЛА / ОДИН РАУНД'),
              const SizedBox(height: 16),
              Text(
                'Один из вас не в курсе.',
                style: Theme.of(context).textTheme.headlineLarge,
              ),
              const SizedBox(height: 24),
              const NightRule(
                number: '01',
                title: 'Телефон по кругу',
                text:
                    'Все знают место, кроме шпиона. Посмотрите роль, скройте и передайте телефон.',
              ),
              const SizedBox(height: 12),
              const NightRule(
                number: '02',
                title: 'У кого плохое алиби?',
                text:
                    'Спрашивайте о месте. Найдите шпиона, не называя локацию.',
              ),
              const SizedBox(height: 12),
              const NightRule(
                number: '03',
                title: 'Решайте вместе',
                text:
                    'Проголосуйте вслух. Нашли шпиона — выиграли. Ошиблись — победил он.',
              ),
              const SizedBox(height: 24),
              const Divider(),
              const NightEyebrow('КАК БУДЕТЕ ИГРАТЬ?'),
              const SizedBox(height: 12),
              const Text(
                'За одним столом · без интернета. Нужен только один телефон.',
              ),
              const SizedBox(height: 12),
              NightButton(
                label: 'Собрать компанию',
                onPressed: () => Navigator.of(context).push<void>(
                  NightRoute(
                    builder: (_) => SpyGameScreen(setupStore: setupStore),
                  ),
                ),
              ),
              if (onOpenRoom != null) ...[
                const SizedBox(height: 16),
                const Text(
                  'У каждого свой телефон — роли на личных экранах, вход по коду.',
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: onOpenRoom,
                  child: const Text('Создать комнату «Шпиона»'),
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}

class ToleranceRulesScreen extends StatelessWidget {
  const ToleranceRulesScreen({super.key, required this.onOpenRoom});
  final VoidCallback onOpenRoom;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('ШКАЛА ТЕРПЕНИЯ')),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const NightScene(kind: NightSceneKind.tolerance, height: 150),
              const SizedBox(height: 20),
              const NightEyebrow('НАСКОЛЬКО ХОРОШО ВЫ ЗНАКОМЫ?'),
              const SizedBox(height: 16),
              Text(
                'У каждого\nсвой предел.',
                style: Theme.of(context).textTheme.headlineLarge,
              ),
              const SizedBox(height: 24),
              const NightRule(
                number: '01',
                title: 'Один — герой раунда',
                text:
                    'Герой тайно расставляет четыре неприятности от «переживу» до «вечер испорчен».',
              ),
              const SizedBox(height: 12),
              const NightRule(
                number: '02',
                title: 'Остальные угадывают',
                text:
                    'Видите три карточки в порядке героя и четвёртую отдельно. Угадайте её место и тайно отправьте ответ.',
              ),
              const SizedBox(height: 12),
              const NightRule(
                number: '03',
                title: 'Сравните и обсудите',
                text:
                    'За точную догадку — очко. Обсудите результат и передайте очередь: каждый побывает героем.',
              ),
              const SizedBox(height: 24),
              const NightPanel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    NightEyebrow('У КАЖДОГО СВОЙ ТЕЛЕФОН'),
                    SizedBox(height: 12),
                    Text(
                      'Создайте комнату и назовите друзьям код. Нужно от 4 до 12 игроков; каждый побывает героем.',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              NightButton(
                label: 'Создать комнату «Шкалы»',
                onPressed: onOpenRoom,
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
