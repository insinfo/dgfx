/// Benchmark bootstrap do port Blend2D em Dart.
///
/// Uso:
///   dart run benchmark/blend2d_port_benchmark.dart
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../research/png/png_writer.dart';

import 'package:dgfx/src/blend2d/blend2d.dart';

class _ScenePolygon {
  final List<double> vertices;
  final List<int>? contourVertexCounts;
  final BLFillRule fillRule;
  final int color;

  const _ScenePolygon({
    required this.vertices,
    required this.fillRule,
    required this.color,
    this.contourVertexCounts,
  });
}

double _signedArea2(List<double> vertices) {
  final n = vertices.length ~/ 2;
  if (n < 3) return 0.0;
  double a2 = 0.0;
  for (int i = 0; i < n; i++) {
    final j = (i + 1) % n;
    final xi = vertices[i * 2];
    final yi = vertices[i * 2 + 1];
    final xj = vertices[j * 2];
    final yj = vertices[j * 2 + 1];
    a2 += (xi * yj) - (xj * yi);
  }
  return a2;
}

List<double> _reverseContour(List<double> vertices) {
  final n = vertices.length ~/ 2;
  final out = List<double>.filled(vertices.length, 0.0, growable: false);
  for (int i = 0; i < n; i++) {
    final src = (n - 1 - i) * 2;
    out[i * 2] = vertices[src];
    out[i * 2 + 1] = vertices[src + 1];
  }
  return out;
}

List<double> _ensureClockwise(List<double> vertices) {
  if (vertices.length < 6) return vertices;
  return _signedArea2(vertices) >= 0.0 ? vertices : _reverseContour(vertices);
}

List<double> _ensureCounterClockwise(List<double> vertices) {
  if (vertices.length < 6) return vertices;
  return _signedArea2(vertices) < 0.0 ? vertices : _reverseContour(vertices);
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

List<double> _createStar(
  double cx,
  double cy,
  double outerRadius,
  double innerRadius,
) {
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

List<double> _createComplexPolygon(double cx, double cy, double size) {
  return <double>[
    cx + size * 0.8,
    cy,
    cx + size * 0.4,
    cy + size * 0.7,
    cx - size * 0.3,
    cy + size * 0.6,
    cx - size * 0.9,
    cy,
    cx - size * 0.5,
    cy - size * 0.5,
    cx + size * 0.2,
    cy - size * 0.8,
  ];
}

/// Letra "A" fiel ao path de `assets/svg/a.svg` (com flatten das quadraticas).
List<List<double>> _createLetterA(double cx, double cy, double size) {
  const minX = 167.0;
  const minY = 234.3;
  const boxW = 239.3;
  const boxH = 253.7;

  final s = size / boxH;
  final tx = cx - (minX + boxW * 0.5) * s;
  final ty = cy - (minY + boxH * 0.5) * s;

  double mapX(double x) => x * s + tx;
  double mapY(double y) => y * s + ty;

  final outer = <double>[];
  double px = 206.5;
  double py = 488.0;

  void addPoint(double x, double y) {
    outer.add(mapX(x));
    outer.add(mapY(y));
  }

  void lineRel(double dx, double dy) {
    px += dx;
    py += dy;
    addPoint(px, py);
  }

  void quadRel(double cdx, double cdy, double dx, double dy,
      {int segments = 16}) {
    final x0 = px;
    final y0 = py;
    final cx0 = x0 + cdx;
    final cy0 = y0 + cdy;
    final x1 = x0 + dx;
    final y1 = y0 + dy;

    for (int i = 1; i <= segments; i++) {
      final t = i / segments;
      final mt = 1.0 - t;
      final x = mt * mt * x0 + 2.0 * mt * t * cx0 + t * t * x1;
      final y = mt * mt * y0 + 2.0 * mt * t * cy0 + t * t * y1;
      addPoint(x, y);
    }

    px = x1;
    py = y1;
  }

  addPoint(px, py); // m206.5 488
  lineRel(-39.5, 0.0); // h-39.5
  lineRel(90.7, -228.7); // l90.7-228.7
  quadRel(4.8, -12.6, 11.8, -18.8); // q4.8-12.6 11.8-18.8
  quadRel(7.4, -6.2, 17.4, -6.2); // q7.4-6.2 17.4-6.2
  quadRel(10.1, 0.0, 17.1, 6.2); // q10.1 0 17.1 6.2
  quadRel(7.2, 6.1, 12.0, 18.8); // q7.2 6.1 12 18.8
  lineRel(90.3, 228.7); // l90.3 228.7
  lineRel(-39.5, 0.0); // h-39.5
  lineRel(-86.4, -226.4); // l-86.4 -226.4
  lineRel(12.6, 0.0); // h12.6

  final bar = <double>[
    mapX(352.4),
    mapY(424.3),
    mapX(221.9),
    mapY(424.3),
    mapX(221.9),
    mapY(392.2),
    mapX(352.4),
    mapY(392.2),
  ];

  return <List<double>>[outer, bar];
}

List<double> _createThinLine(
  double x0,
  double y0,
  double x1,
  double y1,
  double thickness,
) {
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

_ScenePolygon _createHollowRect(
  double cx,
  double cy,
  double outerW,
  double outerH,
  double border,
) {
  final halfOw = outerW * 0.5;
  final halfOh = outerH * 0.5;
  final innerW = math.max(outerW - border * 2.0, 1.0);
  final innerH = math.max(outerH - border * 2.0, 1.0);
  final halfIw = innerW * 0.5;
  final halfIh = innerH * 0.5;

  final outer = _ensureClockwise(<double>[
    cx - halfOw,
    cy - halfOh,
    cx + halfOw,
    cy - halfOh,
    cx + halfOw,
    cy + halfOh,
    cx - halfOw,
    cy + halfOh,
  ]);

  final inner = _ensureCounterClockwise(<double>[
    cx - halfIw,
    cy - halfIh,
    cx + halfIw,
    cy - halfIh,
    cx + halfIw,
    cy + halfIh,
    cx - halfIw,
    cy + halfIh,
  ]);

  return _ScenePolygon(
    vertices: <double>[...outer, ...inner],
    contourVertexCounts: const <int>[4, 4],
    fillRule: BLFillRule.nonZero,
    color: 0xFFFF0000,
  );
}

_ScenePolygon _createHollowCircle(
  double cx,
  double cy,
  double outerRadius,
  double innerRadius,
  int segments,
) {
  final outer = <double>[];
  final inner = <double>[];
  for (int i = 0; i < segments; i++) {
    final a = i * (2.0 * math.pi / segments);
    outer.add(cx + outerRadius * math.cos(a));
    outer.add(cy + outerRadius * math.sin(a));
  }
  for (int i = 0; i < segments; i++) {
    final a = i * (2.0 * math.pi / segments);
    inner.add(cx + innerRadius * math.cos(a));
    inner.add(cy + innerRadius * math.sin(a));
  }
  final outerCw = _ensureClockwise(outer);
  final innerCcw = _ensureCounterClockwise(inner);

  return _ScenePolygon(
    vertices: <double>[...outerCw, ...innerCcw],
    contourVertexCounts: <int>[segments, segments],
    fillRule: BLFillRule.nonZero,
    color: 0xFFFF0000,
  );
}

List<_ScenePolygon> _createSyntheticScene() {
  final polygons = <_ScenePolygon>[
    _ScenePolygon(
      vertices: _ensureClockwise(_createTriangle(256, 256, 100)),
      fillRule: BLFillRule.nonZero,
      color: 0xFFFF0000,
    ),
    _ScenePolygon(
      vertices: _ensureClockwise(_createSquare(128, 128, 80)),
      fillRule: BLFillRule.nonZero,
      color: 0xFFFF0000,
    ),
    _ScenePolygon(
      vertices: _ensureClockwise(_createStar(384, 384, 100, 40)),
      fillRule: BLFillRule.nonZero,
      color: 0xFFFF0000,
    ),
    _ScenePolygon(
      vertices: _ensureClockwise(_createComplexPolygon(256, 400, 80)),
      fillRule: BLFillRule.nonZero,
      color: 0xFFFF0000,
    ),
    ..._createLetterA(102, 378, 130).map(
      (poly) => _ScenePolygon(
        vertices: poly,
        fillRule: BLFillRule.nonZero,
        color: 0xFFFF0000,
      ),
    ),
    _ScenePolygon(
      vertices:
          _ensureClockwise(_createArcBand(140, 258, 34, 38, -2.6, -0.15, 36)),
      fillRule: BLFillRule.nonZero,
      color: 0xFFFF0000,
    ),
    _ScenePolygon(
      vertices: _ensureClockwise(_createThinLine(24, 492, 488, 486, 1.8)),
      fillRule: BLFillRule.nonZero,
      color: 0xFFFF0000,
    ),
    _createHollowRect(410, 228, 96, 52, 10),
    _createHollowCircle(330, 228, 24, 14, 48),
  ];

  for (int i = 0; i < 10; i++) {
    final x = 50.0 + (i % 5) * 100;
    final y = 50.0 + (i ~/ 5) * 100;
    polygons.add(_ScenePolygon(
      vertices: _ensureClockwise(_createTriangle(x, y, 30)),
      fillRule: BLFillRule.nonZero,
      color: 0xFFFF0000,
    ));
  }
  return polygons;
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
  List<_ScenePolygon> polygons,
) async {
  ctx.clear(0xFFF0F0F0);
  for (final p in polygons) {
    await ctx.fillPolygon(
      p.vertices,
      contourVertexCounts: p.contourVertexCounts,
      color: p.color,
      rule: p.fillRule,
    );
  }
}

Future<void> main() async {
  const width = 512;
  const height = 512;
  const warmup = 5;
  const iterations = 30;

  final polygons = _createSyntheticScene();
  final image = BLImage(width, height);
  // Sem flags de configuracao: useSimd/useIsolates/tileHeight/
  // minParallelDirtyHeight sempre foram no-ops e estao depreciados.
  final ctx = BLContext(image);

  try {
    print('Blend2D Dart Port Bootstrap Benchmark');
    print('Resolution: ${width}x$height');
    print('Iterations: $iterations');
    print('Polygons per iteration: ${polygons.length}');

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

    await _saveImage('BLEND2D_PORT_BOOTSTRAP', image.pixels, width, height);

    print('');
    print('Average: ${avgMs.toStringAsFixed(3)} ms/frame');
    print('Throughput: $polyPerSec poly/s');
    print('Output: output/rasterization_benchmark/BLEND2D_PORT_BOOTSTRAP.png');
  } finally {
    await ctx.dispose();
  }
}
