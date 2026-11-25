import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/app_theme.dart';

enum PulseOrbState { monitoring, alarm, disconnected }

class PulseOrbIndicator extends StatefulWidget {
  const PulseOrbIndicator({super.key, required this.state, this.size = 156});

  final PulseOrbState state;
  final double size;

  @override
  State<PulseOrbIndicator> createState() => _PulseOrbIndicatorState();
}

class _PulseOrbIndicatorState extends State<PulseOrbIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  Duration get _duration => switch (widget.state) {
    PulseOrbState.monitoring => const Duration(milliseconds: 2800),
    PulseOrbState.alarm => const Duration(milliseconds: 850),
    PulseOrbState.disconnected => const Duration(milliseconds: 4400),
  };

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: _duration)
      ..repeat();
  }

  @override
  void didUpdateWidget(covariant PulseOrbIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      _controller
        ..duration = _duration
        ..repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: SizedBox.square(
        dimension: widget.size,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) => CustomPaint(
            painter: _PulseOrbPainter(
              progress: _controller.value,
              state: widget.state,
            ),
          ),
        ),
      ),
    );
  }
}

class _PulseOrbPainter extends CustomPainter {
  const _PulseOrbPainter({required this.progress, required this.state});

  final double progress;
  final PulseOrbState state;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final shortest = size.shortestSide;
    final colors = switch (state) {
      PulseOrbState.monitoring => const [
        AppColors.accent,
        AppColors.accentStrong,
        AppColors.primaryLight,
      ],
      PulseOrbState.alarm => const [
        Color(0xFFFFB24A),
        Color(0xFFEF5B45),
        AppColors.dangerDark,
      ],
      PulseOrbState.disconnected => const [
        Color(0xFFD5DEE5),
        Color(0xFF9AAAB7),
        Color(0xFF687A89),
      ],
    };

    for (var index = 0; index < 3; index++) {
      final phase = (progress + index / 3) % 1.0;
      final radius = shortest * (0.29 + phase * 0.2);
      final opacity =
          (1 - phase) * (state == PulseOrbState.alarm ? 0.25 : 0.16);
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = state == PulseOrbState.alarm ? 3 : 2
          ..color = colors[index].withValues(alpha: opacity),
      );
    }

    final breath = math.sin(progress * math.pi * 2);
    final baseRadius = shortest * (state == PulseOrbState.alarm ? 0.31 : 0.3);
    final amplitude = state == PulseOrbState.alarm ? 0.075 : 0.035;
    final path = Path();
    const points = 64;
    for (var index = 0; index <= points; index++) {
      final angle = index / points * math.pi * 2;
      final organic =
          math.sin(angle * 3 + progress * math.pi * 2) * amplitude +
          math.cos(angle * 5 - progress * math.pi * 2) * amplitude * 0.45;
      final radius = baseRadius * (1 + organic + breath * amplitude * 0.35);
      final point = Offset(
        center.dx + math.cos(angle) * radius,
        center.dy + math.sin(angle) * radius,
      );
      if (index == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }
    path.close();

    canvas.drawShadow(path, colors.last.withValues(alpha: 0.35), 18, true);
    canvas.drawPath(
      path,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.3, -0.35),
          radius: 1.1,
          colors: colors,
          stops: const [0, 0.58, 1],
        ).createShader(Offset.zero & size),
    );
    canvas.drawCircle(
      center.translate(-shortest * 0.07, -shortest * 0.08),
      shortest * 0.09,
      Paint()
        ..shader = RadialGradient(
          colors: [Colors.white.withValues(alpha: 0.72), Colors.transparent],
        ).createShader(Offset.zero & size),
    );
  }

  @override
  bool shouldRepaint(covariant _PulseOrbPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.state != state;
}
