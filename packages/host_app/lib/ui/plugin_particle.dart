/// 粒子场：飘落的花瓣 / 雪 / 星光。
///
/// ## 为什么帧循环必须在宿主里
///
/// 插件每帧回传一次状态是**不可能**的：一帧 16ms，光把一棵 UI 树
/// 序列化过 Bridge 就超了（见 `docs/23` 的分工）。
///
/// 所以粒子做成一个**节点**：插件描述"要 14 片花瓣"，宿主每帧自己算。
/// 插件发一条消息，宿主跑一万帧 —— 这才是正确的比例。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:plugin_core/plugin_core.dart';

class PluginParticleField extends StatefulWidget {
  const PluginParticleField({
    super.key,
    required this.shape,
    required this.count,
    required this.color,
    this.speed = 1,
    this.opacity = 1,
  });

  final ParticleShape shape;
  final int count;
  final Color color;
  final double speed;
  final double opacity;

  @override
  State<PluginParticleField> createState() => _PluginParticleFieldState();
}

class _PluginParticleFieldState extends State<PluginParticleField>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late List<_Particle> _particles;

  @override
  void initState() {
    super.initState();
    _particles = _spawn(widget.count);
    // 一个周期 = 最慢那片花瓣落到底的时间。用 repeat 而不是 forward：
    // 粒子的相位是取模算的，所以循环点看不出接缝。
    _c = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: (14000 / widget.speed).round()),
    )..repeat();
  }

  @override
  void didUpdateWidget(PluginParticleField old) {
    super.didUpdateWidget(old);
    if (old.count != widget.count) _particles = _spawn(widget.count);
    if (old.speed != widget.speed) {
      _c.duration = Duration(milliseconds: (14000 / widget.speed).round());
      _c..stop()..repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  /// 每片花瓣的随机参数。
  ///
  /// **用固定种子的伪随机**而不是 `Random()`：同一份声明每次重建
  /// 应该长得一样。真随机的话滚动列表时花瓣会整片跳一次位置。
  List<_Particle> _spawn(int n) {
    final rng = math.Random(20240214);
    return List<_Particle>.generate(n, (i) {
      return _Particle(
        x: rng.nextDouble(),
        phase: rng.nextDouble(),
        fallSpeed: 0.6 + rng.nextDouble() * 0.8,
        swayAmp: 0.02 + rng.nextDouble() * 0.05,
        swayFreq: 0.5 + rng.nextDouble() * 1.5,
        spinSpeed: (rng.nextDouble() - 0.5) * 3.2,
        size: 0.6 + rng.nextDouble() * 0.8,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    // 系统开了"减弱动效"就画静态的 —— 前庭功能敏感的用户会被
    // 全屏飘落的东西弄难受。宁可少一个效果，不要让人不舒服。
    if (reduceMotion) {
      return CustomPaint(
        painter: _ParticlePainter(
          particles: _particles,
          shape: widget.shape,
          color: widget.color,
          opacity: widget.opacity,
          t: 0,
        ),
      );
    }
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) => CustomPaint(
        painter: _ParticlePainter(
          particles: _particles,
          shape: widget.shape,
          color: widget.color,
          opacity: widget.opacity,
          t: _c.value,
        ),
      ),
    );
  }
}

class _Particle {
  const _Particle({
    required this.x,
    required this.phase,
    required this.fallSpeed,
    required this.swayAmp,
    required this.swayFreq,
    required this.spinSpeed,
    required this.size,
  });

  final double x;
  final double phase;
  final double fallSpeed;
  final double swayAmp;
  final double swayFreq;
  final double spinSpeed;
  final double size;
}

class _ParticlePainter extends CustomPainter {
  const _ParticlePainter({
    required this.particles,
    required this.shape,
    required this.color,
    required this.opacity,
    required this.t,
  });

  final List<_Particle> particles;
  final ParticleShape shape;
  final Color color;
  final double opacity;
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final base = size.shortestSide * 0.045;

    for (final p in particles) {
      // 竖直位置：相位 + 时间，取模让它循环
      var progress = (p.phase + t * p.fallSpeed) % 1.0;
      // 从屏幕上方一点点开始，落到下方一点点结束 ——
      // 不然会在上下边缘"凭空出现/消失"
      final y = -0.06 * size.height + progress * 1.12 * size.height;
      final sway = math.sin((t * p.swayFreq + p.phase) * math.pi * 2) * p.swayAmp;
      final x = (p.x + sway) * size.width;

      // 快落到底时淡出，落顶时淡入 —— 硬切会很显眼
      final fade = progress < 0.08
          ? progress / 0.08
          : (progress > 0.9 ? (1 - progress) / 0.1 : 1.0);

      final paint = Paint()
        ..color = color.withValues(alpha: (opacity * fade).clamp(0.0, 1.0))
        ..style = PaintingStyle.fill
        ..isAntiAlias = true;

      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(t * p.spinSpeed * math.pi * 2 + p.phase * math.pi);
      _drawOne(canvas, base * p.size, paint);
      canvas.restore();
    }
  }

  void _drawOne(Canvas canvas, double r, Paint paint) {
    switch (shape) {
      case ParticleShape.petal:
        // 花瓣：一个"水滴 + 缺口"的形状。
        // 用两段贝塞尔而不是椭圆 —— 椭圆看起来像纸屑，不像花瓣。
        final path = Path()
          ..moveTo(0, -r)
          ..cubicTo(r * 0.95, -r * 0.5, r * 0.75, r * 0.75, 0, r)
          ..cubicTo(-r * 0.75, r * 0.75, -r * 0.95, -r * 0.5, 0, -r)
          ..close();
        canvas.drawPath(path, paint);

      case ParticleShape.snow:
        // 六角雪花
        final stroke = Paint()
          ..color = paint.color
          ..strokeWidth = math.max(1.0, r * 0.18)
          ..strokeCap = StrokeCap.round
          ..isAntiAlias = true;
        for (var i = 0; i < 6; i++) {
          final a = i * math.pi / 3;
          canvas.drawLine(Offset.zero, Offset(math.cos(a) * r, math.sin(a) * r), stroke);
        }

      case ParticleShape.star:
        canvas.drawPath(_star(r), paint);

      case ParticleShape.dot:
        canvas.drawCircle(Offset.zero, r * 0.5, paint);

      case ParticleShape.leaf:
        final path = Path()
          ..moveTo(0, -r)
          ..quadraticBezierTo(r, 0, 0, r)
          ..quadraticBezierTo(-r, 0, 0, -r)
          ..close();
        canvas.drawPath(path, paint);
    }
  }

  Path _star(double r) {
    final path = Path();
    for (var i = 0; i < 10; i++) {
      final rad = i.isEven ? r : r * 0.42;
      final a = -math.pi / 2 + i * math.pi / 5;
      final p = Offset(math.cos(a) * rad, math.sin(a) * rad);
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    return path..close();
  }

  @override
  bool shouldRepaint(_ParticlePainter old) =>
      old.t != t ||
      old.color != color ||
      old.shape != shape ||
      old.opacity != opacity ||
      old.particles != particles;
}
