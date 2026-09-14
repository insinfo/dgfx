/// Benchmark dedicado de gradiente linear no port Blend2D em Dart.
///
/// Uso:
///   dart run benchmark/blend2d_linear_gradient_benchmark.dart
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../research/png/png_writer.dart';

import 'package:dgfx/src/blend2d/blend2d.dart';

class _GradientScenePolygon {
  final List<double> vertices;
  final BLFillRule fillRule;
  final BLLinearGradient gradient;

  const _GradientScenePolygon({
    required this.vertices,
    required this.fillRule,
    required this.gradient,
  });
}

List<double> _createTriangle(double cx, double cy, double size) {
  return <double>[
    cx,
    cy - size,
    cx - size * 0.866,
    cy + size * 0.5,
    cx + size * 0.866,
    cy + size * 0.5,
  ];
}

List<double> _createSquare(double cx, double cy, double size) {
  final h = size * 0.5;
  return <double>[
    cx - h,
    cy - h,
    cx + h,
    cy - h,
    cx + h,
    cy + h,
    cx - h,
    cy + h,
  ];
}

List<double> _createHexagon(double cx, double cy, double radius) {
  final out = <double>[];
  for (int i = 0; i < 6; i++) {
    final a = -math.pi / 2 + i * (2 * math.pi / 6);
    out.add(cx + radius * math.cos(a));
    out.add(cy + radius * math.sin(a));
  }
  return out;
}

List<double> _createStar(
    double cx, double cy, double outerRadius, double innerRadius) {
  final out = <double>[];
  const points = 5;
  const step = math.pi / points;
  for (int i = 0; i < points * 2; i++) {
    final angle = -math.pi / 2 + i * step;
    final r = i.isEven ? outerRadius : innerRadius;
    out.add(cx + r * math.cos(angle));
    out.add(cy + r * math.sin(angle));
  }
  return out;
}

List<double> _createArcBand(
  double cx,
  double cy,
  double innerRadius,
  double outerRadius,
  double startAngle,
  double endAngle,
  int segments,
) {
  final out = <double>[];
  for (int i = 0; i <= segments; i++) {
    final t = i / segments;
    final a = startAngle + (endAngle - startAngle) * t;
    out.add(cx + outerRadius * math.cos(a));
    out.add(cy + outerRadius * math.sin(a));
  }
  for (int i = segments; i >= 0; i--) {
    final t = i / segments;
    final a = startAngle + (endAngle - startAngle) * t;
    out.add(cx + innerRadius * math.cos(a));
    out.add(cy + innerRadius * math.sin(a));
  }
  return out;
}

List<double> _createThinLine(
    double x0, double y0, double x1, double y1, double thickness) {
  final dx = x1 - x0;
  final dy = y1 - y0;
  final len = math.sqrt(dx * dx + dy * dy);
  if (len <= 1e-9) {
    final h = thickness * 0.5;
    return <double>[
      x0 - h,
      y0 - h,
      x0 + h,
      y0 - h,
      x0 + h,
      y0 + h,
      x0 - h,
      y0 + h
    ];
  }
  final nx = -dy / len;
  final ny = dx / len;
  final h = thickness * 0.5;
  return <double>[
    x0 + nx * h,
    y0 + ny * h,
    x0 - nx * h,
    y0 - ny * h,
    x1 - nx * h,
    y1 - ny * h,
    x1 + nx * h,
    y1 + ny * h,
  ];
}

BLLinearGradient _makeGradient(
  double x0,
  double y0,
  double x1,
  double y1,
  int c0,
  int c1, {
  BLGradientExtendMode extendMode = BLGradientExtendMode.pad,
}) {
  return BLLinearGradient(
    p0: BLPoint(x0, y0),
    p1: BLPoint(x1, y1),
    stops: <BLGradientStop>[
      BLGradientStop(0.0, c0),
      BLGradientStop(1.0, c1),
    ],
    extendMode: extendMode,
  );
}

List<_GradientScenePolygon> _createGradientScene() {
  return <_GradientScenePolygon>[
    _GradientScenePolygon(
      vertices: _createTriangle(88, 92, 56),
      fillRule: BLFillRule.nonZero,
      gradient: _makeGradient(32, 32, 144, 160, 0xFFE53935, 0xFFFFB300),
    ),
    _GradientScenePolygon(
      vertices: _createSquare(212, 88, 98),
      fillRule: BLFillRule.nonZero,
      gradient: _makeGradient(162, 36, 262, 140, 0xFF3949AB, 0xFF26C6DA),
    ),
    _GradientScenePolygon(
      vertices: _createHexagon(350, 96, 52),
      fillRule: BLFillRule.nonZero,
      gradient: _makeGradient(
        330,
        70,
        370,
        130,
        0xFF00897B,
        0xFF9CCC65,
        extendMode: BLGradientExtendMode.repeat,
      ),
    ),
    _GradientScenePolygon(
      vertices: _createStar(438, 98, 56, 24),
      fillRule: BLFillRule.nonZero,
      gradient: _makeGradient(
        420,
        72,
        456,
        116,
        0xFF8E24AA,
        0xFFEC407A,
        extendMode: BLGradientExtendMode.reflect,
      ),
    ),
    _GradientScenePolygon(
      vertices: _createArcBand(120, 276, 28, 64, -2.6, -0.1, 36),
      fillRule: BLFillRule.nonZero,
      gradient: _makeGradient(48, 236, 188, 316, 0xFFFF7043, 0xFFFFEE58),
    ),
    _GradientScenePolygon(
      vertices: _createSquare(278, 268, 132),
      fillRule: BLFillRule.nonZero,
      gradient: _makeGradient(212, 202, 344, 334, 0xFF5E35B1, 0xFF42A5F5),
    ),
    _GradientScenePolygon(
      vertices: _createStar(430, 274, 72, 30),
      fillRule: BLFillRule.nonZero,
      gradient: _makeGradient(
        404,
        242,
        452,
        304,
        0xFF43A047,
        0xFFAED581,
        extendMode: BLGradientExtendMode.reflect,
      ),
    ),
    _GradientScenePolygon(
      vertices: _createThinLine(20, 486, 492, 470, 5.0),
      fillRule: BLFillRule.nonZero,
      gradient: _makeGradient(20, 486, 492, 470, 0xFF1E88E5, 0xFF00ACC1),
    ),
  ];
}

Future<void> _saveImage(
  String name,
  Uint32List buffer,
  int width,
  int height,
) async {
  final dir = Directory('output/rasterization_benchmark');
  await dir.create(recursive: true);

  final rgba = Uint8List(width * height * 4);
  for (int i = 0; i < buffer.length; i++) {
    final px = buffer[i];
    rgba[i * 4] = (px >> 16) & 0xFF;
    rgba[i * 4 + 1] = (px >> 8) & 0xFF;
    rgba[i * 4 + 2] = px & 0xFF;
    rgba[i * 4 + 3] = (px >> 24) & 0xFF;
  }

  await PngWriter.saveRgba('${dir.path}/$name.png', rgba, width, height);
}

Future<void> _renderScene(
  BLContext ctx,
  List<_GradientScenePolygon> polygons,
) async {
  ctx.clear(0xFFF2F2F2);
  for (final p in polygons) {
    ctx.setLinearGradient(p.gradient);
    await ctx.fillPolygon(
      p.vertices,
      rule: p.fillRule,
    );
  }
}

Future<void> main() async {
  const width = 512;
  const height = 512;
  const warmup = 5;
  const iterations = 30;

  final polygons = _createGradientScene();
  final image = BLImage(width, height);
  final ctx = BLContext(image);

  try {
    print('Blend2D Dart Port Linear Gradient Benchmark');
    print('Resolution: ${width}x$height');
    print('Iterations: $iterations');
    print('Gradient polygons per iteration: ${polygons.length}');

    for (int i = 0; i < warmup; i++) {
      await _renderScene(ctx, polygons);
    }

    final sw = Stopwatch()..start();
    for (int i = 0; i < iterations; i++) {
      await _renderScene(ctx, polygons);
    }
    sw.stop();

    final avgMs = sw.elapsedMicroseconds / 1000.0 / iterations;
    final polyPerSec =
        ((iterations * polygons.length) / (sw.elapsedMicroseconds / 1000000.0))
            .round();

    await _saveImage(
        'BLEND2D_PORT_LINEAR_GRADIENT', image.pixels, width, height);

    print('');
    print('Average: ${avgMs.toStringAsFixed(3)} ms/frame');
    print('Throughput: $polyPerSec poly/s');
    print(
        'Output: output/rasterization_benchmark/BLEND2D_PORT_LINEAR_GRADIENT.png');
  } finally {
    await ctx.dispose();
  }
}
