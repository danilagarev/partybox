import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'night_art.dart';
import 'night_components.dart';
import 'night_theme.dart';

/// Only builds the secret while the controller permits it. Animated content is
/// exclusively the public cover; there is no retained outgoing role subtree.
class RolePeekCard extends StatefulWidget {
  const RolePeekCard({
    super.key,
    required this.revealed,
    required this.enabled,
    required this.viewed,
    required this.onReveal,
    required this.onConceal,
    required this.onContinue,
    required this.continueLabel,
    required this.closedContinueLabel,
    required this.secretBuilder,
    this.concealEpoch = 0,
  });

  final bool revealed, enabled, viewed;
  final VoidCallback onReveal, onConceal, onContinue;
  final String continueLabel, closedContinueLabel;
  final WidgetBuilder secretBuilder;
  final int concealEpoch;

  @override
  State<RolePeekCard> createState() => _RolePeekCardState();
}

class _RolePeekCardState extends State<RolePeekCard>
    with WidgetsBindingObserver {
  static const _threshold = 72.0;
  final _pointers = <int>{};
  bool _dragging = false, _blocked = false, _foreground = true;
  double _lift = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
  }

  @override
  void didUpdateWidget(RolePeekCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled ||
        oldWidget.concealEpoch != widget.concealEpoch ||
        (oldWidget.revealed && !widget.revealed)) {
      // Invalidate a held gesture after external concealment (e.g. disconnect).
      _dragging = false;
      _lift = 0;
      _blocked = _pointers.isNotEmpty;
    }
  }

  void _endPeek() {
    if (!mounted || (!_dragging && _lift == 0)) return;
    setState(() {
      _dragging = false;
      _lift = 0;
    });
    widget.onConceal();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    setState(() {
      _foreground = state == AppLifecycleState.resumed;
      _blocked = true;
      _dragging = false;
      _lift = 0;
      _pointers.clear();
    });
    // Also close a card opened by the keyboard/button, with no outgoing child.
    widget.onConceal();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _dragging = false;
    _lift = 0;
    _pointers.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final visible = widget.revealed && widget.enabled && _foreground;
    final canReveal = widget.enabled && _foreground;
    final gestureEnabled = canReveal && (!visible || _dragging);
    final reduced = NightMotion.reduced(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Listener(
          onPointerDown: (event) {
            if (!mounted) return;
            if (_pointers.isEmpty) _blocked = false;
            _pointers.add(event.pointer);
            if (_pointers.length > 1) {
              _blocked = true;
              _endPeek();
              widget.onConceal();
            }
          },
          onPointerUp: (event) {
            _pointers.remove(event.pointer);
            _endPeek();
          },
          onPointerCancel: (event) {
            _pointers.remove(event.pointer);
            _blocked = true;
            _endPeek();
          },
          child: GestureDetector(
            key: const ValueKey('role-peek-surface'),
            behavior: HitTestBehavior.opaque,
            excludeFromSemantics: true,
            onVerticalDragStart: gestureEnabled
                ? (_) {
                    if (!mounted ||
                        _blocked ||
                        _pointers.length != 1 ||
                        visible) {
                      return;
                    }
                    setState(() {
                      _dragging = true;
                      _lift = 0;
                    });
                  }
                : null,
            onVerticalDragUpdate: gestureEnabled
                ? (event) {
                    if (!mounted || !_dragging || _blocked) return;
                    setState(
                      () => _lift = (_lift - event.delta.dy).clamp(0, 140),
                    );
                    if (_lift >= _threshold && !widget.revealed) {
                      HapticFeedback.selectionClick();
                      widget.onReveal();
                    } else if (_lift < _threshold && widget.revealed) {
                      _endPeek();
                    }
                  }
                : null,
            onVerticalDragEnd: gestureEnabled ? (_) => _endPeek() : null,
            onVerticalDragCancel: gestureEnabled ? _endPeek : null,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(28),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Only public content is measured while concealed. This grows
                  // naturally with text scale and never lays out a hidden role.
                  Opacity(opacity: 0, child: ExcludeSemantics(child: _cover())),
                  if (visible)
                    Semantics(
                      liveRegion: true,
                      child: widget.secretBuilder(context),
                    ),
                  Positioned.fill(
                    child: IgnorePointer(
                      child: ExcludeSemantics(
                        child: AnimatedSlide(
                          offset: visible
                              ? const Offset(0, -1.02)
                              : Offset(0, -_lift / 320),
                          duration: reduced || (_dragging && !visible)
                              ? Duration.zero
                              : NightMotion.quick,
                          curve: NightMotion.curve,
                          child: _cover(),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Semantics(
          liveRegion: true,
          child: Text(
            visible && _dragging
                ? 'Отпустите, чтобы скрыть роль.'
                : 'Убедитесь, что только вы смотрите на экран.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: NightColors.muted),
          ),
        ),
        const SizedBox(height: 8),
        if (!visible)
          TextButton(
            key: const ValueKey('reveal-role'),
            onPressed: canReveal ? widget.onReveal : null,
            child: const Text('Показать мою роль'),
          )
        else if (!_dragging)
          TextButton(
            onPressed: widget.onConceal,
            child: const Text('Скрыть роль'),
          ),
        if (widget.viewed) ...[
          const SizedBox(height: 12),
          NightButton(
            key: const ValueKey('handoff-role'),
            onPressed: canReveal ? widget.onContinue : null,
            label: visible ? widget.continueLabel : widget.closedContinueLabel,
          ),
        ],
      ],
    );
  }

  Widget _cover() => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: 320),
    child: NightPanel(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          NightArt(kind: NightArtKind.seal, height: 72),
          SizedBox(height: 16),
          Text(
            'Ваша роль под защитой',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
          ),
          SizedBox(height: 16),
          Icon(
            Icons.keyboard_double_arrow_up_rounded,
            color: NightColors.accent,
            size: 32,
          ),
          Text(
            'Потяните вверх и удерживайте',
            textAlign: TextAlign.center,
            style: TextStyle(color: NightColors.muted),
          ),
        ],
      ),
    ),
  );
}
