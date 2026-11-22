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
    this.compact = false,
    this.surfaceHeight,
    this.showSafetyHint = true,
    this.showContinue = true,
  });

  final bool revealed, enabled, viewed;
  final VoidCallback onReveal, onConceal, onContinue;
  final String continueLabel, closedContinueLabel;
  final WidgetBuilder secretBuilder;
  final int concealEpoch;
  final bool compact, showSafetyHint, showContinue;
  final double? surfaceHeight;

  @override
  State<RolePeekCard> createState() => _RolePeekCardState();
}

class _RolePeekCardState extends State<RolePeekCard>
    with WidgetsBindingObserver {
  static const _threshold = 72.0;
  final _pointers = <int>{};
  final _frameKey = GlobalKey();
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
                    final frame = _frameKey.currentContext?.findRenderObject();
                    final height = frame is RenderBox
                        ? frame.size.height
                        : 320.0;
                    setState(
                      () => _lift = (_lift - event.delta.dy).clamp(
                        0,
                        height * .72,
                      ),
                    );
                    if (_lift >= _threshold && !widget.revealed) {
                      HapticFeedback.selectionClick();
                      widget.onReveal();
                    } else if (_lift == 0 && widget.revealed) {
                      _endPeek();
                    }
                  }
                : null,
            onVerticalDragEnd: gestureEnabled ? (_) => _endPeek() : null,
            onVerticalDragCancel: gestureEnabled ? _endPeek : null,
            child: ClipRRect(
              key: _frameKey,
              borderRadius: BorderRadius.circular(28),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Public cover alone sizes the surface. The secret is always
                  // positioned, so opening it never expands or moves the card.
                  Opacity(opacity: 0, child: ExcludeSemantics(child: _cover())),
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: NightColors.raised,
                        borderRadius: BorderRadius.circular(28),
                      ),
                    ),
                  ),
                  if (visible)
                    Positioned.fill(
                      child: ClipRect(
                        key: const ValueKey('role-peek-window'),
                        clipper: _PeekWindow(_dragging ? _lift : null),
                        child: ExcludeSemantics(
                          // A partial drag must not announce the whole secret.
                          // The explicit button remains the screen reader path.
                          excluding: _dragging,
                          child: Semantics(
                            liveRegion: !_dragging,
                            child: LayoutBuilder(
                              builder: (context, constraints) =>
                                  SingleChildScrollView(
                                    reverse: true,
                                    physics: _dragging
                                        ? const NeverScrollableScrollPhysics()
                                        : const ClampingScrollPhysics(),
                                    child: ConstrainedBox(
                                      constraints: BoxConstraints(
                                        minHeight: constraints.maxHeight,
                                      ),
                                      child: Align(
                                        alignment: Alignment.bottomCenter,
                                        child: widget.secretBuilder(context),
                                      ),
                                    ),
                                  ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  Positioned.fill(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final offset = visible && !_dragging
                            ? -constraints.maxHeight * 1.02
                            : -_lift;
                        return IgnorePointer(
                          child: ExcludeSemantics(
                            child: AnimatedContainer(
                              key: const ValueKey('role-peek-cover'),
                              transform: Matrix4.translationValues(
                                0,
                                offset,
                                0,
                              ),
                              duration: reduced || _dragging
                                  ? Duration.zero
                                  : NightMotion.quick,
                              curve: Curves.easeOutCubic,
                              child: KeyedSubtree(
                                key: const ValueKey('role-peek-cover-face'),
                                child: _cover(),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (widget.showSafetyHint) ...[
          const SizedBox(height: 12),
          Semantics(
            liveRegion: true,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Preserve the public hint's height during a drag. Otherwise a
                // bottom-scrolled page clamps its offset and moves the card.
                Visibility(
                  visible: !(visible && _dragging),
                  maintainState: true,
                  maintainAnimation: true,
                  maintainSize: true,
                  child: const Text(
                    'Убедитесь, что только вы смотрите на экран.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: NightColors.muted),
                  ),
                ),
                if (visible && _dragging)
                  const Text(
                    'Отпустите, чтобы скрыть роль.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: NightColors.muted),
                  ),
              ],
            ),
          ),
        ],
        SizedBox(height: widget.compact ? 4 : 8),
        Visibility(
          visible: !_dragging,
          maintainState: true,
          maintainAnimation: true,
          maintainSize: true,
          child: TextButton(
            key: visible ? null : const ValueKey('reveal-role'),
            onPressed: canReveal
                ? (visible ? widget.onConceal : widget.onReveal)
                : null,
            child: Text(
              visible && !_dragging ? 'Скрыть роль' : 'Показать мою роль',
            ),
          ),
        ),
        if (widget.showContinue && widget.viewed) ...[
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

  Widget _cover() {
    final content = NightPanel(
      padding: widget.compact ? 16 : 24,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (!widget.compact) ...[
            NightArt(kind: NightArtKind.seal, height: 56),
            const SizedBox(height: 16),
          ],
          Text(
            'Ваша роль под защитой',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: widget.compact ? 21 : 24,
              height: widget.compact ? 1.2 : null,
              fontWeight: FontWeight.w800,
            ),
          ),
          SizedBox(height: widget.compact ? 10 : 16),
          Icon(
            Icons.keyboard_double_arrow_up_rounded,
            color: NightColors.accent,
            size: widget.compact ? 28 : 32,
          ),
          Text(
            'Поднимите обложку и удерживайте',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: NightColors.muted,
              fontSize: widget.compact ? 14 : null,
              height: widget.compact ? 1.35 : null,
            ),
          ),
        ],
      ),
    );
    if (widget.surfaceHeight != null) {
      return SizedBox(
        height: widget.surfaceHeight!.clamp(176.0, 480.0),
        child: content,
      );
    }
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: widget.compact ? 208 : 320),
      child: content,
    );
  }
}

/// The uncovered band grows exactly by the finger distance. No reveal tween
/// can expose more than the user lifted, including at the threshold.
class _PeekWindow extends CustomClipper<Rect> {
  const _PeekWindow(this.lift);
  final double? lift;
  @override
  Rect getClip(Size size) => Rect.fromLTRB(
    0,
    lift == null ? 0 : size.height - lift!.clamp(0, size.height),
    size.width,
    size.height,
  );
  @override
  bool shouldReclip(_PeekWindow oldClipper) => oldClipper.lift != lift;
}

/// Compact private content: the important text sits near the lower edge,
/// underneath the physical cover, rather than becoming a full-screen poster.
class RoleSecretFace extends StatelessWidget {
  const RoleSecretFace({
    super.key,
    required this.title,
    required this.message,
    required this.isSpy,
  });
  final String title, message;
  final bool isSpy;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 20, 24, 28),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ExcludeSemantics(
          child: Icon(
            isSpy ? Icons.visibility_outlined : Icons.place_outlined,
            size: 24,
            color: NightColors.accent,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          title,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: NightColors.muted,
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          message,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: NightColors.text,
            fontSize: isSpy ? 16 : 23,
            height: 1.3,
            fontWeight: isSpy ? FontWeight.w500 : FontWeight.w800,
          ),
        ),
      ],
    ),
  );
}
