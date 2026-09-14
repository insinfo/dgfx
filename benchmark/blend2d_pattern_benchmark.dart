/// Benchmark dedicado de pattern nearest no port Blend2D em Dart.
///
/// Uso:
///   dart run benchmark/blend2d_pattern_benchmark.dart
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../research/png/png_writer.dart';

import 'package:dgfx/src/blend2d/blend2d.dart';

class _PatternScenePolygon {
  final List<double> vertices;
  final BLFillRule fillRule;
  final BLPattern pattern;

  const _PatternScenePolygon({
    required this.vertices,
    required this.fillRule,
    required this.pattern,
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

BLImage _buildPatternImage() {
  const w = 32;
  const h = 32;
  final img = BLImage(w, h);
  final px = img.pixels;

  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      final checker = ((x ~/ 8) + (y ~/ 8)).isEven;
      final ring = (((x - 16) * (x - 16) + (y - 16) * (y - 16)) ~/ 24) % 2 == 0;
      final c0 = checker ? 0xFF1E88E5 : 0xFFE53935;
      final c1 = ring ? 0xFFFFEE58 : 0xFF43A047;
      final blend = ((x * 255) ~/ (w - 1));

      final r0 = (c0 >>> 16) & 0xFF;
      final g0 = (c0 >>> 8) & 0xFF;
      final b0 = c0 & 0xFF;
      final r1 = (c1 >>> 16) & 0xFF;
      final g1 = (c1 >>> 8) & 0xFF;
      final b1 = c1 & 0xFF;

      final r = ((r0 * (255 - blend) + r1 * blend) ~/ 255).clamp(0, 255);
      final g = ((g0 * (255 - blend) + g1 * blend) ~/ 255).clamp(0, 255);
      final b = ((b0 * (255 - blend) + b1 * blend) ~/ 255).clamp(0, 255);

      px[y * w + x] = 0xFF000000 | (r << 16) | (g << 8) | b;
    }
  }

  return img;
}

BLPattern _makePattern(
  BLImage src,
  double ox,
  double oy,
  BLGradientExtendMode ex,
  BLGradientExtendMode ey,
) {
  return BLPattern(
    image: src,
    offset: BLPoint(ox, oy),
    extendModeX: ex,
    extendModeY: ey,
  );
}

List<_PatternScenePolygon> _createPatternScene(BLImage tile) {
  return <_PatternScenePolygon>[
    _PatternScenePolygon(
      vertices: _createTriangle(88, 92, 56),
      fillRule: BLFillRule.nonZero,
      pattern: _makePattern(tile, 10, 12, BLGradientExtendMode.repeat,
          BLGradientExtendMode.repeat),
    ),
    _PatternScenePolygon(
      vertices: _createSquare(212, 88, 98),
      fillRule: BLFillRule.nonZero,
      pattern: _makePattern(tile, 28, 22, BLGradientExtendMode.reflect,
          BLGradientExtendMode.reflect),
    ),
    _PatternScenePolygon(
      vertices: _createHexagon(350, 96, 52),
      fillRule: BLFillRule.nonZero,
      pattern: _makePattern(tile, 40, 10, BLGradientExtendMode.repeat,
          BLGradientExtendMode.reflect),
    ),
    _PatternScenePolygon(
      vertices: _createStar(438, 98, 56, 24),
      fillRule: BLFillRule.nonZero,
      pattern: _makePattern(
          tile, 380, 62, BLGradientExtendMode.pad, BLGradientExtendMode.pad),
    ),
    _PatternScenePolygon(
      vertices: _createArcBand(120, 276, 28, 64, -2.6, -0.1, 36),
      fillRule: BLFillRule.nonZero,
      pattern: _makePattern(tile, 88, 250, BLGradientExtendMode.repeat,
          BLGradientExtendMode.repeat),
    ),
    _PatternScenePolygon(
      vertices: _createSquare(278, 268, 132),
      fillRule: BLFillRule.nonZero,
      pattern: _makePattern(tile, 248, 232, BLGradientExtendMode.reflect,
          BLGradientExtendMode.repeat),
    ),
    _PatternScenePolygon(
      vertices: _createStar(430, 274, 72, 30),
      fillRule: BLFillRule.nonZero,
      pattern: _makePattern(tile, 408, 250, BLGradientExtendMode.pad,
          BLGradientExtendMode.reflect),
    ),
    _PatternScenePolygon(
      vertices: _createThinLine(20, 486, 492, 470, 5.0),
      fillRule: BLFillRule.nonZero,
      pattern: _makePattern(
          tile, 0, 464, BLGradientExtendMode.repeat, BLGradientExtendMode.pad),
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
  List<_PatternScenePolygon> polygons,
) async {
  ctx.clear(0xFFF2F2F2);
  for (final p in polygons) {
    ctx.setPattern(p.pattern);
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

  final tile = _buildPatternImage();
  final polygons = _createPatternScene(tile);
  final image = BLImage(width, height);
  final ctx = BLContext(image);

  try {
    print('Blend2D Dart Port Pattern Benchmark');
    print('Resolution: ${width}x$height');
    print('Iterations: $iterations');
    print('Pattern polygons per iteration: ${polygons.length}');

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

    await _saveImage('BLEND2D_PORT_PATTERN', image.pixels, width, height);

    print('');
    print('Average: ${avgMs.toStringAsFixed(3)} ms/frame');
    print('Throughput: $polyPerSec poly/s');
    print('Output: output/rasterization_benchmark/BLEND2D_PORT_PATTERN.png');
  } finally {
    await ctx.dispose();
  }
}
