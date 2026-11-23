import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../design/night_components.dart';
import '../design/night_theme.dart';
import 'room_controller.dart';
import 'room_models.dart';
import 'room_game_panel.dart';
import 'room_invitation.dart';

class RoomScreen extends StatefulWidget {
  const RoomScreen({
    super.key,
    required this.controller,
    this.initialGame,
    this.initialJoining = false,
    this.initialPin,
  });
  final String? initialGame;
  final bool initialJoining;
  final String? initialPin;
  final RoomController controller;
  @override
  State<RoomScreen> createState() => _RoomScreenState();
}

class _RoomScreenState extends State<RoomScreen> with WidgetsBindingObserver {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController(), _pin = TextEditingController();
  bool _joining = false, _ignoreInvitation = false;
  Timer? _ticker;
  bool _foreground = true;
  RoomController get controller => widget.controller;
  @override
  void initState() {
    super.initState();
    _joining = widget.initialJoining || widget.initialPin != null;
    if (widget.initialPin != null &&
        RegExp(r'^\d{6}$').hasMatch(widget.initialPin!)) {
      _pin.text = widget.initialPin!;
    }
    WidgetsBinding.instance.addObserver(this);
    controller.addListener(_changed);
    unawaited(controller.initialize());
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted &&
          _foreground &&
          controller.snapshot?.game?.phase == 'discussion') {
        setState(() {});
      }
    });
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    controller.setActive(_foreground);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    controller.removeListener(_changed);
    controller.dispose();
    _name.dispose();
    _pin.dispose();
    super.dispose();
  }

  Future<void> _confirm(bool forget) async {
    controller.hideRole();
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(forget ? 'Удалить доступ?' : 'Выйти из комнаты?'),
        content: SingleChildScrollView(
          child: Text(
            forget
                ? 'Телефон забудет комнату. Если вы уже вошли, ваше место останется до закрытия комнаты.'
                : 'Ваше место освободится. Активный раунд будет отменён. Если вы ведущий, управление перейдёт следующему участнику.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(forget ? 'Удалить доступ' : 'Выйти'),
          ),
        ],
      ),
    );
    if (accepted == true && mounted) {
      if (forget) {
        await controller.forget();
      } else {
        await controller.leave();
      }
    }
  }

  void _submit() {
    if (_form.currentState!.validate()) {
      FocusScope.of(context).unfocus();
      unawaited(
        controller.enroll(_name.text, pin: _joining ? _pin.text : null),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = controller.snapshot;
    final invitationConflict =
        snapshot != null &&
        !_ignoreInvitation &&
        widget.initialPin != null &&
        widget.initialPin != snapshot.pin;
    final active =
        snapshot != null &&
        (snapshot.game != null && snapshot.game!.phase != 'results' ||
            snapshot.tolerance != null &&
                snapshot.tolerance!.phase != 'finished' ||
            snapshot.clues != null && snapshot.clues!.phase != 'finished' ||
            snapshot.truth != null);
    return PopScope(
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) controller.hideRole();
      },
      child: Scaffold(
        appBar: AppBar(
          actions: [
            if (active)
              IconButton(
                tooltip: 'Комната и участники',
                onPressed: () => _showRoomInfo(snapshot),
                icon: const Icon(Icons.groups_outlined),
              ),
          ],
          title: Text(
            snapshot == null || snapshot.protocolVersion >= 3
                ? 'ИГРЫ В КОМНАТЕ'
                : 'КОМНАТА «ШПИОНА»',
          ),
        ),
        body: invitationConflict
            ? _invitationConflict(snapshot)
            : active
            ? _activeGame(snapshot)
            : SafeArea(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: ListView(
                      padding: const EdgeInsets.all(24),
                      children: [
                        const NightEyebrow('У КАЖДОГО СВОЙ ТЕЛЕФОН'),
                        const SizedBox(height: 16),
                        Text(
                          snapshot == null
                              ? (_joining
                                    ? 'Присоединяйтесь к своим.'
                                    : 'Создадим вашу комнату.')
                              : 'Все свои — здесь.',
                          style: Theme.of(context).textTheme.headlineLarge,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          snapshot == null
                              ? (_joining
                                    ? (widget.initialPin != null
                                          ? 'Код из приглашения уже заполнен. Введите своё имя, чтобы присоединиться.'
                                          : 'Введите имя и код от ведущего. Сохранённое место восстановится автоматически.')
                                    : widget.initialGame == 'truth'
                                    ? 'Играем в «Не может быть!». Создайте комнату и пригласите друзей по коду.'
                                    : widget.initialGame == 'clues'
                                    ? 'Играем в «Что объединяет?». Можно начать одному или пригласить друзей по коду.'
                                    : widget.initialGame == 'tolerance'
                                    ? 'Играем в «Шкалу терпения». Создайте комнату, затем пригласите друзей по коду.'
                                    : 'Играем в «Шпиона». Создайте комнату, затем пригласите друзей по коду.')
                              : snapshot.protocolVersion >= 3
                              ? 'Выберите игру в комнате. Обсуждайте за столом, а тайные ответы отправляйте с телефона.'
                              : 'У каждого своя роль. Обсуждение и голосование — вслух.',
                          style: TextStyle(color: NightColors.muted),
                        ),
                        const SizedBox(height: 24),
                        if (snapshot != null)
                          NightEntrance(
                            key: ValueKey(snapshot.roomId),
                            child: _lobby(snapshot),
                          )
                        else if (controller.canEnroll)
                          _enrollment(),
                        if (controller.busy)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            child: Semantics(
                              liveRegion: true,
                              label: 'Подключаемся',
                              child: LinearProgressIndicator(),
                            ),
                          ),
                        if (controller.error != null)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            child: Semantics(
                              liveRegion: true,
                              child: Text(
                                controller.error!.message,
                                style: const TextStyle(
                                  color: NightColors.error,
                                ),
                              ),
                            ),
                          ),
                        if (controller.notice != null)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            child: Semantics(
                              liveRegion: true,
                              child: Text(controller.notice!),
                            ),
                          ),
                        if (!controller.busy &&
                            (controller.error != null || controller.hasPending))
                          NightButton(
                            label: 'Повторить',
                            onPressed: controller.retry,
                          ),
                        if (!controller.busy &&
                            controller.canForget &&
                            (controller.hasPending || snapshot == null))
                          TextButton(
                            onPressed: () => _confirm(true),
                            child: const Text('Удалить доступ с телефона'),
                          ),
                        const SizedBox(height: 20),
                        const Text(
                          'Возврат в каталог сохраняет место в комнате.',
                          style: TextStyle(
                            color: NightColors.muted,
                            fontSize: 12,
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

  Future<void> _showInvitation(RoomSnapshot snapshot) async {
    controller.hideRole();
    await showDialog<void>(
      context: context,
      builder: (_) => RoomInvitationDialog(
        invitation: RoomInvitation.create(controller.api.origin, snapshot.pin),
      ),
    );
  }

  Widget _invitationConflict(RoomSnapshot snapshot) => SafeArea(
    child: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'У вас уже есть другая комната',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 16),
              Text(
                'Сохранено место в комнате ${snapshot.pin}. Приглашение ведёт в ${widget.initialPin}. Чтобы присоединиться, сначала выйдите из текущей комнаты. Активная партия будет отменена.',
              ),
              const SizedBox(height: 24),
              NightButton(
                label: 'Остаться в текущей',
                onPressed: () => setState(() => _ignoreInvitation = true),
              ),
              TextButton(
                onPressed: controller.busy ? null : () => _confirm(false),
                child: const Text('Выйти и открыть приглашение'),
              ),
              if (controller.error != null)
                Text(
                  controller.error!.message,
                  style: const TextStyle(color: NightColors.error),
                ),
            ],
          ),
        ),
      ),
    ),
  );

  Future<void> _showRoomInfo(RoomSnapshot snapshot) async {
    controller.hideRole();
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Комната ${snapshot.pin}'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final player in snapshot.players)
                Text(
                  '${player.name}${player.id == snapshot.hostId ? ' · ведущий' : ''}',
                ),
              const SizedBox(height: 16),
              Text(controller.online ? 'В сети' : 'Восстанавливаем связь…'),
              const SizedBox(height: 12),
              const Text(
                'Приглашать новых участников можно в лобби и между партиями.',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('К игре'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _confirm(false);
            },
            child: const Text('Выйти из комнаты'),
          ),
        ],
      ),
    );
  }

  Widget _activeGame(RoomSnapshot snapshot) => SafeArea(
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact =
                snapshot.game != null &&
                MediaQuery.textScalerOf(context).scale(16) <= 22 &&
                constraints.maxHeight >= 420;
            final panel = RoomGamePanel(
              key: ValueKey(snapshot.sessionId ?? 'lobby'),
              controller: controller,
              compactSpy: compact,
            );
            if (compact) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                child: panel,
              );
            }
            return ListView(
              key: snapshot.truth == null
                  ? null
                  : ValueKey((
                      snapshot.truth!.roundIndex,
                      snapshot.truth!.phase,
                    )),
              padding: const EdgeInsets.all(20),
              children: [
                panel,
                if (controller.notice != null && controller.error == null)
                  Text(
                    controller.notice!,
                    style: const TextStyle(color: NightColors.muted),
                  ),
                if (controller.error != null)
                  Text(
                    controller.error!.message,
                    style: const TextStyle(color: NightColors.error),
                  ),
                if (!controller.online || controller.hasPending)
                  TextButton(
                    onPressed: controller.busy ? null : controller.retry,
                    child: const Text('Восстановить связь'),
                  ),
              ],
            );
          },
        ),
      ),
    ),
  );

  Widget _enrollment() => Form(
    key: _form,
    child: NightPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            children: [
              ChoiceChip(
                label: const Text('Создать'),
                selected: !_joining,
                onSelected: (_) => setState(() => _joining = false),
              ),
              ChoiceChip(
                label: const Text('Войти по коду'),
                selected: _joining,
                onSelected: (_) => setState(() => _joining = true),
              ),
            ],
          ),
          const SizedBox(height: 20),
          TextFormField(
            controller: _name,
            enabled: !controller.busy,
            decoration: const InputDecoration(labelText: 'Ваше имя'),
            textCapitalization: TextCapitalization.words,
            textInputAction: _joining
                ? TextInputAction.next
                : TextInputAction.done,
            validator: (value) => RoomContract.validName(value?.trim() ?? '')
                ? null
                : 'Введите имя: от 1 до 40 символов.',
            onFieldSubmitted: (_) {
              if (!_joining) _submit();
            },
          ),
          if (_joining) ...[
            const SizedBox(height: 16),
            TextFormField(
              controller: _pin,
              enabled: !controller.busy,
              decoration: const InputDecoration(labelText: 'Код комнаты'),
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(6),
              ],
              validator: (value) => RegExp(r'^\d{6}$').hasMatch(value ?? '')
                  ? null
                  : 'В коде шесть цифр.',
              onFieldSubmitted: (_) => _submit(),
            ),
          ],
          const SizedBox(height: 24),
          NightButton(
            label: _joining ? 'Войти в комнату' : 'Создать комнату',
            onPressed: controller.busy ? null : _submit,
          ),
        ],
      ),
    ),
  );
  Widget _lobby(RoomSnapshot snapshot) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (snapshot.game == null &&
          snapshot.tolerance == null &&
          snapshot.clues == null &&
          snapshot.truth == null) ...[
        _roomCode(snapshot),
        const SizedBox(height: 20),
      ],
      RoomGamePanel(
        key: ValueKey(snapshot.sessionId ?? 'lobby'),
        controller: controller,
        initialGame: !_joining && snapshot.hostId == snapshot.selfId
            ? widget.initialGame
            : null,
      ),
      const SizedBox(height: 20),
      if (snapshot.game != null ||
          snapshot.tolerance != null ||
          snapshot.clues != null ||
          snapshot.truth != null) ...[
        _roomCode(snapshot),
        const SizedBox(height: 20),
      ],
      Semantics(
        liveRegion: true,
        child: Text(
          controller.online
              ? 'В сети · изменения видны всем'
              : 'Восстанавливаем связь…',
          style: const TextStyle(color: NightColors.muted),
        ),
      ),
      const SizedBox(height: 20),
      Text(
        'В КОМНАТЕ · ${snapshot.players.length}/12',
        style: Theme.of(context).textTheme.labelLarge,
      ),
      const SizedBox(height: 12),
      for (final (index, player) in snapshot.players.indexed)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: NightPanel(
            padding: 16,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: player.id == snapshot.selfId
                        ? NightColors.accent
                        : NightColors.raised,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${index + 1}'.padLeft(2, '0'),
                    style: TextStyle(
                      color: player.id == snapshot.selfId
                          ? NightColors.ink
                          : NightColors.muted,
                      fontWeight: FontWeight.w800,
                      fontSize: 12,
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        player.name,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      if (player.id == snapshot.selfId ||
                          player.id == snapshot.hostId)
                        Text(
                          [
                            if (player.id == snapshot.selfId) 'Это вы',
                            if (player.id == snapshot.hostId) 'Ведущий',
                          ].join(' · '),
                          style: const TextStyle(
                            fontSize: 12,
                            color: NightColors.muted,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      const SizedBox(height: 16),
      OutlinedButton(
        onPressed: controller.busy || controller.hasPending
            ? null
            : () => _confirm(false),
        child: const Text('Выйти из комнаты'),
      ),
    ],
  );
  Widget _roomCode(RoomSnapshot snapshot) => NightPanel(
    accent: true,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const NightEyebrow('КОД КОМНАТЫ', color: NightColors.ink),
        const SizedBox(height: 8),
        Semantics(
          label: 'Код комнаты ${snapshot.pin.split('').join(' ')}',
          excludeSemantics: true,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              '${snapshot.pin.substring(0, 3)} ${snapshot.pin.substring(3)}',
              style: const TextStyle(fontSize: 48, fontWeight: FontWeight.w800),
            ),
          ),
        ),
        const SizedBox(height: 12),
        const Text('Назовите код друзьям. Комната открыта 24 часа с создания.'),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            foregroundColor: NightColors.ink,
            side: const BorderSide(color: NightColors.ink),
          ),
          onPressed: () => _showInvitation(snapshot),
          icon: const Icon(Icons.qr_code_2),
          label: const Text('Показать QR-код'),
        ),
      ],
    ),
  );
}
