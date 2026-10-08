/// 画插件送来的二维图形。
///
/// 图形集合是**封闭的**（见 [UiShape]）—— 宿主为每一种写一段绘制代码。
/// 不给 SVG path 之类的通用能力，那等于让插件上传代码。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:plugin_core/plugin_core.dart';

class PluginShapePainter extends CustomPainter {
  const PluginShapePainter({required this.shape, required this.color});

  final UiShape shape;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    final rect = Offset.zero & size;
    final center = rect.center;
    final radius = math.min(size.width, size.height) / 2;

    switch (shape) {
      case UiShape.circle:
        canvas.drawCircle(center, radius, paint);

      case UiShape.square:
        // 圆角一点点：纯直角看起来像占位图，不像礼物
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(center: center, width: radius * 1.8, height: radius * 1.8),
            Radius.circular(radius * 0.18),
          ),
          paint,
        );

      case UiShape.triangle:
        canvas.drawPath(_polygon(center, radius, 3, -math.pi / 2), paint);

      case UiShape.diamond:
        canvas.drawPath(_polygon(center, radius, 4, -math.pi / 2), paint);

      case UiShape.hexagon:
        canvas.drawPath(_polygon(center, radius, 6, -math.pi / 2), paint);

      case UiShape.star:
        canvas.drawPath(_star(center, radius, 5), paint);

      case UiShape.heart:
        canvas.drawPath(_heart(center, radius), paint);
    }
  }

  /// 正 n 边形。
  Path _polygon(Offset c, double r, int sides, double startAngle) {
    final path = Path();
    for (var i = 0; i < sides; i++) {
      final a = startAngle + i * 2 * math.pi / sides;
      final p = Offset(c.dx + r * math.cos(a), c.dy + r * math.sin(a));
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    return path..close();
  }

  /// 五角星：外顶点与内顶点交替。
  Path _star(Offset c, double r, int points) {
    final path = Path();
    final inner = r * 0.42;
    for (var i = 0; i < points * 2; i++) {
      final rad = i.isEven ? r : inner;
      final a = -math.pi / 2 + i * math.pi / points;
      final p = Offset(c.dx + rad * math.cos(a), c.dy + rad * math.sin(a));
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    return path..close();
  }

  /// 心形：两段三次贝塞尔。
  ///
  /// 用贝塞尔而不是参数方程 —— 参数方程在小尺寸下会有毛刺，
  /// 而礼物图案常常只有 32–88 逻辑像素。
  Path _heart(Offset c, double r) {
    final w = r * 0.95;
    final h = r * 0.9;
    final top = c.dy - h * 0.55;
    final bottom = c.dy + h * 0.75;

    return Path()
      ..moveTo(c.dx, bottom)
      ..cubicTo(
        c.dx - w * 1.6, c.dy + h * 0.05,
        c.dx - w * 0.62, top - h * 0.62,
        c.dx, top,
      )
      ..cubicTo(
        c.dx + w * 0.62, top - h * 0.62,
        c.dx + w * 1.6, c.dy + h * 0.05,
        c.dx, bottom,
      )
      ..close();
  }

  @override
  bool shouldRepaint(PluginShapePainter old) =>
      old.shape != shape || old.color != color;
}
