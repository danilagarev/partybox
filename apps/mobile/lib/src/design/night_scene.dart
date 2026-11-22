import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'night_theme.dart';

enum NightSceneKind {
  spy,
  tolerance,
  clues,
  starter,
  everyday,
  travel,
  unusual,
}

/// Decorative editorial artwork. Game and pack names are supplied by their cards.
class NightScene extends StatefulWidget {
  const NightScene({super.key, required this.kind, this.height = 140});

  final NightSceneKind kind;
  final double height;

  @override
  State<NightScene> createState() => _NightSceneState();
}

class _NightSceneState extends State<NightScene>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entrance = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1050),
  );
  late final Animation<double> _arrival = _entrance.drive(
    CurveTween(curve: const Interval(0, .44, curve: NightMotion.curve)),
  );
  late final Animation<double> _detail = _entrance.drive(
    CurveTween(curve: const Interval(.22, 1, curve: Curves.easeInOutCubic)),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (NightMotion.reduced(context)) {
      _entrance.value = 1;
    } else if (_entrance.isDismissed) {
      _entrance.forward();
    }
  }

  @override
  void didUpdateWidget(covariant NightScene oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.kind != widget.kind) {
      if (NightMotion.reduced(context)) {
        _entrance.value = 1;
      } else {
        _entrance.forward(from: 0);
      }
    }
  }

  @override
  void dispose() {
    _entrance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox(
      width: double.infinity,
      height: widget.height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topRight,
              end: Alignment.bottomLeft,
              colors: [_backdrop(widget.kind), NightColors.background],
            ),
          ),
          child: FadeTransition(
            opacity: _arrival,
            child: SlideTransition(
              position: _arrival.drive(
                Tween(begin: const Offset(0, .045), end: Offset.zero),
              ),
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: _NightScenePainter(widget.kind, _detail),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  static Color _backdrop(NightSceneKind kind) => switch (kind) {
    NightSceneKind.spy => const Color(0xFF314438),
    NightSceneKind.tolerance => const Color(0xFF3F364E),
    NightSceneKind.clues => const Color(0xFF3B3D31),
    NightSceneKind.starter => const Color(0xFF403B36),
    NightSceneKind.everyday => const Color(0xFF30443C),
    NightSceneKind.travel => const Color(0xFF35444A),
    NightSceneKind.unusual => const Color(0xFF433951),
  };
}

class _NightScenePainter extends CustomPainter {
  _NightScenePainter(this.kind, this.detail) : super(repaint: detail);

  final NightSceneKind kind;
  final Animation<double> detail;

  @override
  void paint(Canvas canvas, Size size) {
    final artWidth = size.width < size.height * 1.55 ? 200 : 276;
    final scale = math.min(size.width / artWidth, size.height / 152);
    if (scale <= 0) return;
    canvas.save();
    canvas.translate(
      (size.width - 276 * scale) / 2,
      (size.height - 152 * scale) / 2,
    );
    canvas.scale(scale);
    final scene = _Scene(canvas, detail.value);
    scene.halo(kind);
    switch (kind) {
      case NightSceneKind.spy:
        scene.spy();
      case NightSceneKind.tolerance:
        scene.tolerance();
      case NightSceneKind.clues:
        scene.clues();
      case NightSceneKind.starter:
        scene.starter();
      case NightSceneKind.everyday:
        scene.everyday();
      case NightSceneKind.travel:
        scene.travel();
      case NightSceneKind.unusual:
        scene.unusual();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_NightScenePainter oldDelegate) =>
      oldDelegate.kind != kind || oldDelegate.detail != detail;
}

class _Scene {
  _Scene(this.canvas, this.progress);

  final Canvas canvas;
  final double progress;
  double get remaining => 1 - progress;
  static const _ink = NightColors.ink;
  static const _lime = NightColors.accent;
  static const _lilac = NightColors.lilac;
  static const _cream = NightColors.text;
  static const _sage = Color(0xFF8DA48A);
  static const _moss = Color(0xFF4B6351);
  static const _gold = Color(0xFFE8BA83);
  static const _plum = Color(0xFF72657F);
  static const _paper = Color(0xFFDBD6BA);

  static Paint _fill(Color color) => Paint()..color = color;

  static Paint _stroke(Color color, double width) => Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeWidth = width
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  void _box(
    double x,
    double y,
    double width,
    double height,
    double radius,
    Color color,
  ) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(x, y, width, height),
        Radius.circular(radius),
      ),
      _fill(color),
    );
  }

  void _frame(
    double x,
    double y,
    double width,
    double height,
    double radius,
    Color color,
  ) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(x, y, width, height),
        Radius.circular(radius),
      ),
      _stroke(color, 1),
    );
  }

  void _circle(double x, double y, double radius, Color color) =>
      canvas.drawCircle(Offset(x, y), radius, _fill(color));

  void _ring(
    double x,
    double y,
    double radius,
    Color color, [
    double width = 1,
  ]) => canvas.drawCircle(Offset(x, y), radius, _stroke(color, width));

  void _oval(double x, double y, double width, double height, Color color) =>
      canvas.drawOval(Rect.fromLTWH(x, y, width, height), _fill(color));

  void _line(
    double x,
    double y,
    double endX,
    double endY,
    Color color, [
    double width = 1,
  ]) =>
      canvas.drawLine(Offset(x, y), Offset(endX, endY), _stroke(color, width));

  void _polygon(List<Offset> vertices, Color color) =>
      canvas.drawPath(Path()..addPolygon(vertices, true), _fill(color));

  void _star(double x, double y, double radius, Color color) {
    _line(x - radius, y, x + radius, y, color);
    _line(x, y - radius, x, y + radius, color);
  }

  void _rotate(double x, double y, double angle, VoidCallback paint) {
    canvas.save();
    canvas.translate(x, y);
    canvas.rotate(angle);
    paint();
    canvas.restore();
  }

  void halo(NightSceneKind kind) {
    final color = switch (kind) {
      NightSceneKind.tolerance => _lilac,
      NightSceneKind.clues || NightSceneKind.starter => _gold,
      NightSceneKind.everyday || NightSceneKind.spy => _lime,
      NightSceneKind.travel => _cream,
      NightSceneKind.unusual => _lilac,
    };
    const center = Offset(165, 65);
    final glow = RadialGradient(
      colors: [color.withAlpha(29), color.withAlpha(0)],
    ).createShader(Rect.fromCircle(center: center, radius: 96));
    canvas.drawCircle(center, 96, Paint()..shader = glow);
    _ring(166, 62, 47, color.withAlpha(40));
    _ring(166, 62, 56, color.withAlpha(30));
    _star(33, 46, 5, color.withAlpha(144));
    _star(241, 35, 4, color.withAlpha(138));
    _circle(225, 53, 1.6, color.withAlpha(128));
    _circle(54, 30, 1.1, color.withAlpha(104));
    _circle(252, 79, 1.1, color.withAlpha(104));
    _line(24, 130, 252, 130, color.withAlpha(40));
    _oval(57, 123, 173, 19, _ink.withAlpha(160));
  }

  void spy() {
    _box(28, 79, 21, 43, 2, _moss.withAlpha(104));
    _box(52, 66, 30, 56, 2, _moss.withAlpha(122));
    _box(185, 78, 28, 44, 2, _moss.withAlpha(122));
    _box(216, 91, 28, 31, 2, _moss.withAlpha(104));
    for (var row = 0; row < 4; row++) {
      for (var column = 0; column < 2; column++) {
        _box(58 + column * 10, 74 + row * 11, 3, 4, 1, _lime.withAlpha(76));
        _box(192 + column * 9, 85 + row * 8, 3, 3, 1, _lime.withAlpha(60));
      }
    }
    _rotate(126, 81, .18, () {
      _box(-53, -43, 99, 84, 6, _ink);
      _box(-57, -47, 99, 84, 6, _moss);
      _frame(-57, -47, 99, 84, 6, _sage);
      for (var row = 0; row < 5; row++) {
        _line(-48, -27 + row * 11, 35, -27 + row * 11, _sage.withAlpha(101));
      }
    });
    _rotate(124, 81, -.13, () {
      _box(-46, -51, 91, 100, 5, _ink);
      _box(-49, -55, 91, 100, 5, _paper);
      _box(-41, -47, 34, 40, 3, _moss);
      _oval(-38, -26, 28, 17, _ink);
      _circle(-24, -32, 7, _ink);
      _line(1, -42, 33, -42, _moss, 2);
      _line(1, -34, 25, -34, _moss, 2);
      _line(1, -26, 29, -26, _moss, 2);
      for (var row = 0; row < 4; row++) {
        _line(
          -41,
          1 + row * 9,
          31 - row * 5,
          1 + row * 9,
          _moss.withAlpha(150),
        );
      }
      _ring(22, 27, 10, _moss, 1.6);
      _ring(22, 27, 6, _moss.withAlpha(150));
    });
    canvas.save();
    canvas.translate(-37 * remaining, -13 * remaining);
    _line(177, 98, 207, 125, _ink, 16);
    _line(177, 96, 205, 122, _sage, 10);
    _line(186, 104, 205, 122, _lime, 2);
    _circle(161, 80, 25, _ink);
    _circle(161, 80, 19, _moss);
    _ring(161, 80, 21, _lime, 2.6);
    final eye = Path()
      ..moveTo(149, 80)
      ..quadraticBezierTo(161, 67, 173, 80)
      ..quadraticBezierTo(161, 93, 149, 80);
    canvas.drawPath(eye, _stroke(_cream, 1.6));
    _circle(161, 80, 3.6, _lime);
    canvas.restore();
  }

  void tolerance() {
    _rotate(104, 78, -.17, () {
      _box(-48, -39, 96, 66, 10, _ink);
      _box(-51, -43, 96, 66, 10, _plum);
      _polygon(const [
        Offset(-37, 17),
        Offset(-37, 34),
        Offset(-19, 19),
      ], _plum);
      _line(-35, -26, 14, -26, _lilac.withAlpha(184), 2);
      _line(-35, -16, 0, -16, _lilac.withAlpha(150), 2);
    });
    _rotate(153, 55, .13, () {
      _box(-25, -23, 78, 40, 8, _ink);
      _box(-28, -26, 78, 40, 8, _paper);
      _polygon(const [Offset(25, 7), Offset(25, 22), Offset(40, 8)], _paper);
      for (var dot = 0; dot < 3; dot++) {
        _circle(-11 + dot * 11, -6, 2.5, _moss);
      }
    });
    _box(86, 65, 125, 64, 12, _ink);
    _box(82, 61, 125, 64, 12, _lilac);
    _frame(87, 66, 115, 54, 9, _plum.withAlpha(131));
    const dial = Rect.fromLTWH(117, 76, 55, 55);
    canvas.drawArc(dial, math.pi, math.pi, false, _stroke(_plum, 7));
    canvas.drawArc(
      dial,
      math.pi * 1.64,
      math.pi * .36,
      false,
      _stroke(_moss, 7),
    );
    for (var tick = 0; tick < 7; tick++) {
      final angle = math.pi + tick * math.pi / 6;
      _line(
        144.5 + math.cos(angle) * 16,
        103.5 + math.sin(angle) * 16,
        144.5 + math.cos(angle) * 20,
        103.5 + math.sin(angle) * 20,
        _ink,
      );
    }
    final turn = -1.9 * remaining;
    _line(
      144.5,
      103.5,
      144.5 + 14.5 * math.cos(turn) + 15.5 * math.sin(turn),
      103.5 + 14.5 * math.sin(turn) - 15.5 * math.cos(turn),
      _ink,
      2,
    );
    _circle(144.5, 103.5, 3, _ink);
    _line(113, 112, 176, 112, _plum.withAlpha(145));
  }

  void clues() {
    final string = Path()
      ..moveTo(34, 87)
      ..cubicTo(98, 135, 180, 25, 241, 70);
    canvas.drawPath(string, _stroke(_gold.withAlpha(160), 1.2));
    _rotate(80 + 38 * remaining, 78, -.16 * progress, () {
      _box(-30, -34, 65, 78, 6, _ink);
      _box(-34, -39, 65, 78, 6, _sage);
      _frame(-29, -34, 55, 67, 4, _cream.withAlpha(140));
      _circle(-7, -3, 10, _cream);
      _circle(-7, -3, 5, _moss);
      _line(1, 3, 16, 18, _cream, 5);
      _line(10, 12, 14, 8, _cream, 3);
      _line(14, 16, 18, 12, _cream, 3);
      _line(-15, 24, 10, 24, _moss);
    });
    _rotate(197 - 36 * remaining, 78, .17 * progress, () {
      _box(-29, -34, 65, 78, 6, _ink);
      _box(-34, -39, 65, 78, 6, _plum);
      _frame(-29, -34, 55, 67, 4, _lilac.withAlpha(150));
      _circle(-2, -2, 17, _lilac);
      _ring(-2, -2, 13, _plum);
      _polygon(const [
        Offset(5, -10),
        Offset(0, 0),
        Offset(-9, 7),
        Offset(-4, -4),
      ], _plum);
      _circle(-2, -2, 2, _ink);
      _line(-15, 24, 11, 24, _lilac.withAlpha(160));
    });
    _rotate(138, 79, .02, () {
      _box(-33, -43, 73, 92, 6, _ink);
      _box(-37, -48, 73, 92, 6, _paper);
      _frame(-31, -42, 61, 80, 4, _moss.withAlpha(135));
      _polygon(const [
        Offset(-14, 14),
        Offset(-15, -1),
        Offset(-6, -12),
        Offset(7, -12),
        Offset(15, -1),
        Offset(14, 14),
      ], _moss);
      _box(-5, 1, 9, 13, 1, _cream);
      _box(-4, -6, 7, 4, 1, _lime);
      _line(-13, 25, 13, 25, _moss);
      _star(0, -22, 4, _moss);
    });
    _circle(48, 98, 3, _gold);
    _circle(231, 68, 3, _gold);
  }

  void starter() {
    _circle(194, 45, 13, _gold.withAlpha(160));
    for (var building = 0; building < 6; building++) {
      final x = 31 + building * 37.0;
      final top = 75 - (building % 3) * 11.0;
      _box(x, top, 32, 121 - top, 2, _moss.withAlpha(112));
      _box(x + 7, top + 8, 3, 5, 1, _gold.withAlpha(95));
      _box(x + 17, top + 8, 3, 5, 1, _gold.withAlpha(105));
    }
    _box(79, 51, 105, 76, 4, _ink);
    _box(83, 48, 97, 76, 4, _moss);
    _box(90, 51, 83, 11, 3, _paper);
    _line(101, 56, 159, 56, _moss);
    _box(95, 79, 43, 33, 3, _ink);
    _box(99, 83, 35, 25, 2, Color.lerp(_moss, _gold, progress)!);
    _line(117, 83, 117, 108, _moss, 2);
    _line(100, 95, 133, 95, _moss, 2);
    _box(143, 79, 23, 45, 4, _ink);
    _box(147, 84, 15, 24, 2, _gold.withAlpha(210));
    _circle(158, 114, 1.4, _cream);
    for (var stripe = 0; stripe < 8; stripe++) {
      final x = 87 + 11.0 * stripe;
      _polygon([
        Offset(x, 63),
        Offset(x + 10, 63),
        Offset(x + 9, 74),
        Offset(x - 3, 74),
      ], stripe.isEven ? _cream : _sage);
      _box(x - 3, 72, 12, 7, 3, stripe.isEven ? _paper : _moss);
    }
    _line(199, 83, 199, 124, _sage, 2);
    _box(194, 80, 10, 6, 2, _gold);
    _box(60, 115, 13, 10, 2, _gold);
    _oval(60, 100, 6, 15, _sage);
    _oval(65, 97, 9, 19, _lime.withAlpha(188));
    _line(57, 126, 213, 126, _sage.withAlpha(140));
  }

  void everyday() {
    _box(91, 25, 84, 65, 8, _ink);
    _box(96, 30, 74, 56, 5, _moss);
    _circle(150, 47 + 14 * remaining, 9, _lilac.withAlpha(190));
    _polygon(const [
      Offset(96, 74),
      Offset(114, 58),
      Offset(132, 68),
      Offset(151, 57),
      Offset(170, 69),
      Offset(170, 86),
      Offset(96, 86),
    ], _sage.withAlpha(145));
    _line(133, 31, 133, 84, _ink, 2);
    _line(97, 57, 169, 57, _ink, 2);
    _box(71, 119, 8, 10, 2, _paper);
    _box(181, 119, 8, 10, 2, _paper);
    _box(72, 73, 116, 43, 13, _sage);
    _box(62, 93, 134, 28, 8, _moss);
    _box(74, 96, 109, 15, 5, _sage);
    _box(62, 89, 16, 27, 6, _sage);
    _box(180, 89, 16, 27, 6, _sage);
    _rotate(96, 91, -.14, () => _box(-11, -11, 23, 20, 5, _lilac));
    _rotate(161, 91, .17, () => _box(-12, -12, 24, 22, 5, _gold));
    _line(219, 111, 218, 79, _sage, 2);
    _rotate(217, 90, -.67, () => _oval(-4, -19, 9, 21, _sage));
    _rotate(220, 94, .65, () => _oval(-3, -21, 9, 20, _lime.withAlpha(195)));
    _rotate(219, 102, -.86, () => _oval(-3, -16, 8, 17, _lime.withAlpha(165)));
    _polygon(const [
      Offset(209, 108),
      Offset(229, 108),
      Offset(225, 128),
      Offset(213, 128),
    ], _paper);
    _oval(207, 106, 24, 5, _gold);
    _line(45, 118, 45, 129, _gold, 2);
    _oval(33, 115, 24, 5, _gold);
    _ring(51, 111, 4, _cream);
    _box(41, 106, 10, 9, 2, _cream);
    _line(43, 101, 46, 97, _cream.withAlpha(146));
  }

  void travel() {
    _circle(185, 48, 19, _gold.withAlpha(202));
    _polygon(const [
      Offset(27, 114),
      Offset(90, 50),
      Offset(110, 72),
      Offset(153, 34),
      Offset(226, 114),
    ], _sage);
    _polygon(const [
      Offset(64, 76),
      Offset(90, 50),
      Offset(112, 74),
      Offset(101, 70),
      Offset(94, 76),
      Offset(86, 66),
      Offset(77, 75),
    ], _cream);
    _polygon(const [
      Offset(126, 58),
      Offset(153, 34),
      Offset(185, 69),
      Offset(166, 60),
      Offset(159, 66),
      Offset(149, 53),
      Offset(141, 61),
    ], _cream);
    _polygon(const [
      Offset(24, 117),
      Offset(73, 94),
      Offset(95, 98),
      Offset(130, 80),
      Offset(161, 93),
      Offset(183, 83),
      Offset(249, 118),
    ], _moss);
    for (var tree = 0; tree < 5; tree++) {
      final x = 31 + tree * 13.0;
      final y = 94 + (tree % 2) * 7.0;
      _polygon([
        Offset(x, y),
        Offset(x - 7, y + 24),
        Offset(x + 7, y + 24),
      ], _ink);
      _line(x, y + 20, x, y + 29, _ink, 2);
    }
    _rotate(178 + 22 * remaining, 107 - 11 * remaining, -.12 * progress, () {
      _frame(-13, -34, 26, 18, 5, _gold);
      _box(-37, -22, 78, 48, 8, _ink);
      _box(-41, -26, 78, 48, 8, _gold);
      _frame(-36, -21, 68, 38, 5, _ink.withAlpha(126));
      _box(-28, -26, 6, 48, 1, _moss);
      _box(19, -26, 6, 48, 1, _moss);
      _box(-28, -10, 6, 8, 1, _cream);
      _box(19, -10, 6, 8, 1, _cream);
      _circle(-8, -1, 8, _lilac);
      _line(-12, 0, -8, -5, _plum);
      _line(-8, -5, -4, 0, _plum);
      _box(3, 3, 10, 6, 2, _cream);
    });
  }

  void unusual() {
    _circle(195, 47, 16, _lilac.withAlpha(148));
    _circle(202, 41, 14, const Color(0xFF453D53));
    _star(186, 68, 3, _gold);
    _star(86, 35, 2, _cream);
    _polygon(const [
      Offset(46, 87),
      Offset(72, 78),
      Offset(89, 85),
      Offset(74, 105),
      Offset(58, 99),
    ], _plum);
    _line(47, 87, 86, 85, _sage, 2);
    _polygon(const [
      Offset(198, 99),
      Offset(220, 90),
      Offset(238, 97),
      Offset(216, 118),
    ], _plum);
    _line(199, 99, 235, 97, _sage, 2);
    _polygon(const [
      Offset(83, 99),
      Offset(117, 88),
      Offset(172, 89),
      Offset(198, 100),
      Offset(166, 117),
      Offset(147, 137),
      Offset(119, 123),
    ], _plum);
    _polygon(const [
      Offset(83, 99),
      Offset(118, 94),
      Offset(147, 102),
      Offset(147, 137),
      Offset(119, 123),
    ], const Color(0xFF4E465C));
    _polygon(const [
      Offset(83, 98),
      Offset(119, 90),
      Offset(176, 91),
      Offset(198, 99),
      Offset(170, 108),
      Offset(124, 109),
    ], _sage);
    _box(111, 67, 56, 31, 4, _ink);
    _box(116, 66, 47, 33, 3, _paper);
    _box(132, 78, 15, 21, 5, _plum);
    _box(119, 77, 7, 10, 3, _moss);
    _box(153, 77, 7, 10, 3, _moss);
    const dome = Rect.fromLTWH(114, 43, 51, 48);
    canvas.drawArc(dome, math.pi, math.pi, true, _fill(_lilac));
    const meridian = Rect.fromLTWH(128, 43, 23, 48);
    canvas.drawArc(meridian, math.pi, math.pi, false, _stroke(_plum, 1.3));
    _line(114, 67, 165, 67, _cream, 2);
    _rotate(143, 45, -.85 * remaining, () {
      _line(0, 1, 12, -13, _ink, 8);
      _line(0, 0, 12, -14, _sage, 4);
      _line(9, -16, 15, -11, _gold, 3);
    });
    _line(129, 103, 151, 103, _cream, 2);
    _circle(166, 126, 2, _lilac.withAlpha(138));
    _circle(120, 136, 1.4, _lilac.withAlpha(138));
  }
}
