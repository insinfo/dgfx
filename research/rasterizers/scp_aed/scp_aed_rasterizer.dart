/// ============================================================================
/// SCP_AED — Stochastic Coverage Propagation with Adaptive Error Diffusion
/// ============================================================================
///
/// Versão prática/robusta:
///   1) Scanline para máscara (inside/outside) no bbox
///   2) Inicialização Narrow-Band SDF (distância assinada) perto das arestas
///   3) Difusão estocástica leve só na banda
///   4) Cobertura rápida (smoothstep) + Error Diffusion só na banda
///
library scp_aed;

import 'dart:math' as math;
import 'dart:typed_data';

class SCPAEDRasterizer {
  final int width;
  final int height;

  late final Uint32List _framebuffer;

  // Campo φ (vamos usar como SDF assinado na banda)
  late final Float64List _phi;
  late final Float64List _phiPrev;

  // Curvatura/“peso” (opcional) — aqui simples, útil para reduzir difusão em cantos.
  late final Float64List _curvature;

  // Erro de quantização em domínio de cobertura (0..1)
  late final Float64List _error;

  // Scratch
  final List<_Edge> _edges = <_Edge>[];
  final List<_Crossing> _crossings = <_Crossing>[];

  // ------------------------------------------------------------
  // Parâmetros (ajuste fino)
  // ------------------------------------------------------------

  // “Distância máxima” (clamp) do SDF. Quanto maior, mais banda estável.
  static const double _phiFar = 8.0;

  // Raio (em pixels) da banda SDF ao redor das arestas.
  // Custo ~ O(arestas * area_da_banda). 4–6 costuma ficar bom.
  static const double _sdfRadius = 5.0;

  // Quantos pixels (meia largura) para mapear distância -> cobertura.
  // 0.5 é “mais correto” para box filter; 0.7–0.9 dá um AA mais macio.
  static const double _aaHalfWidth = 0.75;

  // Difusão estocástica (refino). 0–2 iterações; 1 geralmente já ajuda.
  static const int _diffuseIters = 1;
  static const double _alpha = 0.22; // laplaciano
  static const double _beta = 0.10; // ruído

  // Margem do bbox: precisa cobrir SDF + vizinhança de difusão/erro.
  static const int _bboxMargin = 8;
  static const int _tileSize = 32;
  static const int _sdfTilePruneEdgeThreshold = 24;

  SCPAEDRasterizer({required this.width, required this.height}) {
    final n = width * height;
    _framebuffer = Uint32List(n);
    _phi = Float64List(n);
    _phiPrev = Float64List(n);
    _curvature = Float64List(n);
    _error = Float64List(n);
  }

  Uint32List get buffer => _framebuffer;

  void clear([int backgroundColor = 0xFF000000]) {
    _framebuffer.fillRange(0, _framebuffer.length, backgroundColor);
    _phi.fillRange(0, _phi.length, -_phiFar);
    _phiPrev.fillRange(0, _phiPrev.length, -_phiFar);
    _curvature.fillRange(0, _curvature.length, 0.0);
    _error.fillRange(0, _error.length, 0.0);
  }

  void drawPolygon(
    List<double> vertices,
    int color, {
    int windingRule = 1,
    List<int>? contourVertexCounts,
  }) {
    if (vertices.length < 6) return;
    final contours =
        _resolveContours(vertices.length ~/ 2, contourVertexCounts);

    final b = _computeBounds(vertices, margin: _bboxMargin);
    if (b.isEmpty) return;

    // Reseta só o bbox (fundamental quando desenha vários polígonos no mesmo frame)
    _resetBboxState(b);

    // 1) Pré-processa arestas e buckets espaciais
    _buildEdges(vertices, b, contours);
    if (_edges.isEmpty) return;
    final rowBuckets = _buildRowBuckets(b);

    // 2) Scanline => máscara inside/outside (φ = +/-_phiFar)
    _fillInteriorScanline(b, windingRule, rowBuckets);

    // 3) Curvatura simples (só pra modular erro/ruído em cantos)
    _computeCurvature(vertices, b, contours);

    // 4) Inicializa SDF assinado na banda (perto das arestas)
    if (_edges.length >= _sdfTilePruneEdgeThreshold) {
      final tileBuckets = _buildTileBuckets(b, _sdfRadius);
      _initSignedDistanceNarrowBandWithTilePruning(
        b,
        tileBuckets,
        radius: _sdfRadius,
      );
    } else {
      _initSignedDistanceNarrowBandDirect(b, radius: _sdfRadius);
    }

    // 5) Difusão estocástica leve só na banda
    for (int i = 0; i < _diffuseIters; i++) {
      _diffuse(b);
    }

    // 6) Render: cobertura rápida + error diffusion na banda
    _render(color, b);
  }

  // --------------------------------------------------------------------------
  // BBox
  // --------------------------------------------------------------------------

  _Bounds _computeBounds(List<double> vertices, {required int margin}) {
    double minX = double.infinity, minY = double.infinity;
    double maxX = -double.infinity, maxY = -double.infinity;

    for (int i = 0; i < vertices.length; i += 2) {
      final x = vertices[i];
      final y = vertices[i + 1];
      if (x < minX) minX = x;
      if (y < minY) minY = y;
      if (x > maxX) maxX = x;
      if (y > maxY) maxY = y;
    }

    final x0 = (minX.floor() - margin).clamp(0, width - 1);
    final y0 = (minY.floor() - margin).clamp(0, height - 1);
    final x1 = (maxX.ceil() + margin).clamp(0, width - 1);
    final y1 = (maxY.ceil() + margin).clamp(0, height - 1);

    return _Bounds(x0, y0, x1, y1);
  }

  void _resetBboxState(_Bounds b) {
    for (int y = b.y0; y <= b.y1; y++) {
      final row = y * width;
      final start = row + b.x0;
      final end = row + b.x1 + 1;

      _phi.fillRange(start, end, -_phiFar);
      _phiPrev.fillRange(start, end, -_phiFar);
      _curvature.fillRange(start, end, 0.0);
      _error.fillRange(start, end, 0.0);
    }
  }

  // --------------------------------------------------------------------------
  // Scanline (máscara inside/outside)
  // --------------------------------------------------------------------------

  void _buildEdges(
      List<double> vertices, _Bounds b, List<_ContourSpan> contours) {
    _edges.clear();

    for (final contour in contours) {
      if (contour.count < 2) continue;
      for (int local = 0; local < contour.count; local++) {
        final i = contour.start + local;
        final j = contour.start + ((local + 1) % contour.count);
        double x0 = vertices[i * 2];
        double y0 = vertices[i * 2 + 1];
        double x1 = vertices[j * 2];
        double y1 = vertices[j * 2 + 1];

        if (y0 == y1) continue;
        int winding = 1;
        if (y0 > y1) {
          final tx = x0;
          x0 = x1;
          x1 = tx;
          final ty = y0;
          y0 = y1;
          y1 = ty;
          winding = -1;
        }

        // culling vertical no bbox
        if (y1 < b.y0 || y0 > b.y1 + 1) continue;

        _edges.add(_Edge(x0, y0, x1, y1, winding));
      }
    }
  }

  List<List<int>> _buildRowBuckets(_Bounds b) {
    final rows = b.y1 - b.y0 + 1;
    final buckets = List<List<int>>.generate(rows, (_) => <int>[]);
    for (int i = 0; i < _edges.length; i++) {
      final e = _edges[i];
      final yStart = (e.y0.floor() - 1).clamp(b.y0, b.y1);
      final yEnd = (e.y1.ceil() + 1).clamp(b.y0, b.y1);
      for (int y = yStart; y <= yEnd; y++) {
        buckets[y - b.y0].add(i);
      }
    }
    return buckets;
  }

  List<List<int>> _buildTileBuckets(_Bounds b, double radius) {
    final minTileX = b.x0 ~/ _tileSize;
    final maxTileX = b.x1 ~/ _tileSize;
    final minTileY = b.y0 ~/ _tileSize;
    final maxTileY = b.y1 ~/ _tileSize;
    final tilesX = maxTileX - minTileX + 1;
    final tilesY = maxTileY - minTileY + 1;
    final buckets = List<List<int>>.generate(tilesX * tilesY, (_) => <int>[]);

    for (int i = 0; i < _edges.length; i++) {
      final e = _edges[i];
      final ex0 = (math.min(e.x0, e.x1) - radius).floor().clamp(b.x0, b.x1);
      final ex1 = (math.max(e.x0, e.x1) + radius).ceil().clamp(b.x0, b.x1);
      final ey0 = (e.y0 - radius).floor().clamp(b.y0, b.y1);
      final ey1 = (e.y1 + radius).ceil().clamp(b.y0, b.y1);
      if (ex0 > ex1 || ey0 > ey1) continue;

      final tx0 = (ex0 ~/ _tileSize).clamp(minTileX, maxTileX).toInt();
      final tx1 = (ex1 ~/ _tileSize).clamp(minTileX, maxTileX).toInt();
      final ty0 = (ey0 ~/ _tileSize).clamp(minTileY, maxTileY).toInt();
      final ty1 = (ey1 ~/ _tileSize).clamp(minTileY, maxTileY).toInt();

      for (int ty = ty0; ty <= ty1; ty++) {
        final rowBase = (ty - minTileY) * tilesX;
        for (int tx = tx0; tx <= tx1; tx++) {
          buckets[rowBase + (tx - minTileX)].add(i);
        }
      }
    }
    return buckets;
  }

  void _fillInteriorScanline(
    _Bounds b,
    int windingRule,
    List<List<int>> rowBuckets,
  ) {
    _crossings.clear();

    for (int y = b.y0; y <= b.y1; y++) {
      final rowEdgeIndices = rowBuckets[y - b.y0];
      if (rowEdgeIndices.isEmpty) continue;

      final scanY = y + 0.5;
      _crossings.clear();

      for (int i = 0; i < rowEdgeIndices.length; i++) {
        final e = _edges[rowEdgeIndices[i]];
        if (scanY >= e.y0 && scanY < e.y1) {
          final t = (scanY - e.y0) / (e.y1 - e.y0);
          _crossings.add(_Crossing(e.x0 + t * (e.x1 - e.x0), e.winding));
        }
      }

      if (_crossings.isEmpty) continue;
      _crossings.sort((a, b2) => a.x.compareTo(b2.x));

      final row = y * width;
      int winding = 0;
      double? startX;
      for (int i = 0; i < _crossings.length; i++) {
        final c = _crossings[i];
        final bool wasInside =
            (windingRule == 0) ? ((winding & 1) != 0) : (winding != 0);
        winding += c.winding;
        final bool isInside =
            (windingRule == 0) ? ((winding & 1) != 0) : (winding != 0);

        if (!wasInside && isInside) {
          startX = c.x;
          continue;
        }
        if (wasInside && !isInside && startX != null) {
          int xStart = startX.ceil();
          int xEnd = c.x.floor();
          if (xStart < b.x0) xStart = b.x0;
          if (xEnd > b.x1) xEnd = b.x1;
          if (xStart <= xEnd) {
            for (int x = xStart; x <= xEnd; x++) {
              _phi[row + x] = _phiFar; // inside
            }
          }
          startX = null;
        }
      }
    }
  }

  // --------------------------------------------------------------------------
  // Curvatura simples (só em cantos) + espalhamento local
  // --------------------------------------------------------------------------

  void _computeCurvature(
      List<double> vertices, _Bounds b, List<_ContourSpan> contours) {
    // “pinta” um pequeno disco ao redor do vértice com o ângulo de virada (0..pi)
    const int r = 2;
    for (final contour in contours) {
      if (contour.count < 3) continue;
      for (int local = 0; local < contour.count; local++) {
        final p0 = contour.start + local;
        final p1 = contour.start + ((local + 1) % contour.count);
        final p2 = contour.start + ((local + 2) % contour.count);

        final dx1 = vertices[p1 * 2] - vertices[p0 * 2];
        final dy1 = vertices[p1 * 2 + 1] - vertices[p0 * 2 + 1];
        final dx2 = vertices[p2 * 2] - vertices[p1 * 2];
        final dy2 = vertices[p2 * 2 + 1] - vertices[p1 * 2 + 1];

        final a1 = math.atan2(dy1, dx1);
        final a2 = math.atan2(dy2, dx2);
        double diff = (a2 - a1).abs();
        if (diff > math.pi) diff = 2 * math.pi - diff;

        final vx = vertices[p1 * 2].round();
        final vy = vertices[p1 * 2 + 1].round();

        for (int oy = -r; oy <= r; oy++) {
          final yy = vy + oy;
          if (yy < b.y0 || yy > b.y1) continue;
          final row = yy * width;

          for (int ox = -r; ox <= r; ox++) {
            final xx = vx + ox;
            if (xx < b.x0 || xx > b.x1) continue;

            final d2 = (ox * ox + oy * oy);
            if (d2 > r * r) continue;

            // falloff simples
            final w = 1.0 - (math.sqrt(d2) / r);
            final idx = row + xx;
            final v = diff * w;
            if (v > _curvature[idx]) _curvature[idx] = v;
          }
        }
      }
    }
  }

  // --------------------------------------------------------------------------
  // Narrow-band SDF: distância ponto->segmento (somente perto da borda)
  // --------------------------------------------------------------------------

  void _initSignedDistanceNarrowBandWithTilePruning(
    _Bounds b,
    List<List<int>> tileBuckets, {
    required double radius,
  }) {
    final minTileX = b.x0 ~/ _tileSize;
    final maxTileX = b.x1 ~/ _tileSize;
    final minTileY = b.y0 ~/ _tileSize;
    final maxTileY = b.y1 ~/ _tileSize;
    final tilesX = maxTileX - minTileX + 1;
    final r = radius;

    for (int ty = minTileY; ty <= maxTileY; ty++) {
      final tileY0 = math.max(ty * _tileSize, b.y0);
      final tileY1 = math.min((ty + 1) * _tileSize - 1, b.y1);

      for (int tx = minTileX; tx <= maxTileX; tx++) {
        final tileX0 = math.max(tx * _tileSize, b.x0);
        final tileX1 = math.min((tx + 1) * _tileSize - 1, b.x1);
        final candidates =
            tileBuckets[(ty - minTileY) * tilesX + (tx - minTileX)];
        if (candidates.isEmpty) continue;

        for (int ci = 0; ci < candidates.length; ci++) {
          final e = _edges[candidates[ci]];
          final ax = e.x0;
          final ay = e.y0;
          final bx = e.x1;
          final by = e.y1;

          int x0 = (math.min(ax, bx) - r).floor().clamp(tileX0, tileX1).toInt();
          int x1 = (math.max(ax, bx) + r).ceil().clamp(tileX0, tileX1).toInt();
          int y0 = (math.min(ay, by) - r).floor().clamp(tileY0, tileY1).toInt();
          int y1 = (math.max(ay, by) + r).ceil().clamp(tileY0, tileY1).toInt();
          if (x0 > x1 || y0 > y1) continue;

          for (int y = y0; y <= y1; y++) {
            final py = y + 0.5;
            final row = y * width;

            for (int x = x0; x <= x1; x++) {
              final idx = row + x;
              final sign = (_phi[idx] >= 0.0) ? 1.0 : -1.0;

              final px = x + 0.5;
              final d2 = _dist2PointToSegment(px, py, ax, ay, bx, by);
              final curAbs = _phi[idx].abs();
              if (d2 >= curAbs * curAbs) continue;

              var d = math.sqrt(d2);
              if (d > _phiFar) d = _phiFar;

              _phi[idx] = sign * d;
            }
          }
        }
      }
    }
  }

  void _initSignedDistanceNarrowBandDirect(
    _Bounds b, {
    required double radius,
  }) {
    final r = radius;
    for (int ei = 0; ei < _edges.length; ei++) {
      final e = _edges[ei];
      final ax = e.x0;
      final ay = e.y0;
      final bx = e.x1;
      final by = e.y1;

      int x0 = (math.min(ax, bx) - r).floor().clamp(b.x0, b.x1).toInt();
      int x1 = (math.max(ax, bx) + r).ceil().clamp(b.x0, b.x1).toInt();
      int y0 = (math.min(ay, by) - r).floor().clamp(b.y0, b.y1).toInt();
      int y1 = (math.max(ay, by) + r).ceil().clamp(b.y0, b.y1).toInt();
      if (x0 > x1 || y0 > y1) continue;

      for (int y = y0; y <= y1; y++) {
        final py = y + 0.5;
        final row = y * width;

        for (int x = x0; x <= x1; x++) {
          final idx = row + x;
          final sign = (_phi[idx] >= 0.0) ? 1.0 : -1.0;

          final px = x + 0.5;
          final d2 = _dist2PointToSegment(px, py, ax, ay, bx, by);
          final curAbs = _phi[idx].abs();
          if (d2 >= curAbs * curAbs) continue;

          var d = math.sqrt(d2);
          if (d > _phiFar) d = _phiFar;

          _phi[idx] = sign * d;
        }
      }
    }
  }

  static double _dist2PointToSegment(
    double px,
    double py,
    double ax,
    double ay,
    double bx,
    double by,
  ) {
    final abx = bx - ax;
    final aby = by - ay;
    final apx = px - ax;
    final apy = py - ay;

    final denom = abx * abx + aby * aby;
    double t = (denom <= 1e-12) ? 0.0 : (apx * abx + apy * aby) / denom;
    if (t < 0.0) t = 0.0;
    if (t > 1.0) t = 1.0;

    final cx = ax + abx * t;
    final cy = ay + aby * t;

    final dx = px - cx;
    final dy = py - cy;
    return dx * dx + dy * dy;
  }

  // --------------------------------------------------------------------------
  // Difusão estocástica leve (só na banda)
  // --------------------------------------------------------------------------

  void _diffuse(_Bounds b) {
    // copia bbox
    for (int y = b.y0; y <= b.y1; y++) {
      final row = y * width;
      final start = row + b.x0;
      final end = row + b.x1 + 1;
      _phiPrev.setRange(start, end, _phi, start);
    }

    // 1px de vizinhança
    final x0 = math.max(b.x0 + 1, 1);
    final y0 = math.max(b.y0 + 1, 1);
    final x1 = math.min(b.x1 - 1, width - 2);
    final y1 = math.min(b.y1 - 1, height - 2);
    if (x0 > x1 || y0 > y1) return;

    // banda efetiva (não faz sentido difundir longe das arestas)
    final band = _sdfRadius + 0.5;

    for (int y = y0; y <= y1; y++) {
      final row = y * width;
      for (int x = x0; x <= x1; x++) {
        final idx = row + x;
        final v = _phiPrev[idx];

        if (v.abs() > band) {
          _phi[idx] = v;
          continue;
        }

        final lap = _phiPrev[idx - width] +
            _phiPrev[idx + width] +
            _phiPrev[idx - 1] +
            _phiPrev[idx + 1] -
            4.0 * v;

        final kappa = _curvature[idx];

        // ruído controlado (mais fraco em cantos)
        final noise = (_pseudoRandom(x, y) - 0.5) * 2.0;
        final noiseScale = _beta / (1.0 + 6.0 * kappa);

        _phi[idx] = v + _alpha * lap + noiseScale * noise;
      }
    }
  }

  // --------------------------------------------------------------------------
  // Render (smoothstep) + Error Diffusion na banda
  // --------------------------------------------------------------------------

  void _render(int color, _Bounds b) {
    final r = (color >> 16) & 0xFF;
    final g = (color >> 8) & 0xFF;
    final bl = color & 0xFF;

    for (int y = b.y0; y <= b.y1; y++) {
      final row = y * width;

      for (int x = b.x0; x <= b.x1; x++) {
        final idx = row + x;

        final phi = _phi[idx];

        // fora “bem longe” => transparente
        if (phi <= -_aaHalfWidth - 1.5) continue;

        // erro entra em domínio de cobertura
        final errIn = _error[idx];
        _error[idx] = 0.0;

        double coverage;

        if (phi >= _aaHalfWidth + 1.5) {
          coverage = 1.0;
        } else if (phi <= -_aaHalfWidth - 1.5) {
          coverage = 0.0;
        } else {
          // mapeia distância -> [0..1] e aplica smoothstep
          final t =
              ((phi + _aaHalfWidth) / (2.0 * _aaHalfWidth)).clamp(0.0, 1.0);
          coverage = t * t * (3.0 - 2.0 * t); // smoothstep
        }

        // aplica erro e clamp
        coverage = (coverage + errIn).clamp(0.0, 1.0);

        final a = (coverage * 255.0).round();
        if (a > 0) _blendPixel(idx, r, g, bl, a);

        // difunde erro só na banda subpixel (onde 0<coverage<1)
        if (coverage > 0.0 &&
            coverage < 1.0 &&
            phi.abs() <= (_aaHalfWidth + 0.75)) {
          final q = a / 255.0;
          final e = coverage - q;
          if (e.abs() >= 0.0008) {
            final kappa = _curvature[idx];
            _propagateError(x, y, b, e, kappa);
          }
        }
      }
    }
  }

  void _propagateError(int x, int y, _Bounds b, double err, double kappa) {
    // Floyd–Steinberg
    const wR = 7 / 16;
    const wDL = 3 / 16;
    const wD = 5 / 16;
    const wDR = 1 / 16;

    // reduz difusão em cantos
    final scale = math.exp(-2.0 * kappa);
    final e = err * scale;

    final yNext = y + 1;

    if (x + 1 <= b.x1) _error[y * width + (x + 1)] += e * wR;

    if (yNext <= b.y1) {
      final rowN = yNext * width;

      if (x - 1 >= b.x0) _error[rowN + (x - 1)] += e * wDL;
      _error[rowN + x] += e * wD;
      if (x + 1 <= b.x1) _error[rowN + (x + 1)] += e * wDR;
    }
  }

  // --------------------------------------------------------------------------
  // Utils
  // --------------------------------------------------------------------------

  static double _pseudoRandom(int x, int y) {
    int n = x * 374761393 + y * 668265263;
    n = (n ^ (n >> 13)) * 1274126177;
    return (n & 0x7FFFFFFF) / 2147483647.0;
  }

  void _blendPixel(int idx, int r, int g, int b, int a) {
    if (a >= 255) {
      _framebuffer[idx] = 0xFF000000 | (r << 16) | (g << 8) | b;
      return;
    }

    final bg = _framebuffer[idx];
    final invA = 255 - a;

    final bgR = (bg >> 16) & 0xFF;
    final bgG = (bg >> 8) & 0xFF;
    final bgB = bg & 0xFF;

    // /256 (rápido) — aceitável visualmente
    final outR = (r * a + bgR * invA) >> 8;
    final outG = (g * a + bgG * invA) >> 8;
    final outB = (b * a + bgB * invA) >> 8;

    _framebuffer[idx] = 0xFF000000 | (outR << 16) | (outG << 8) | outB;
  }
}

class _Bounds {
  final int x0, y0, x1, y1;
  const _Bounds(this.x0, this.y0, this.x1, this.y1);
  bool get isEmpty => x0 > x1 || y0 > y1;
}

class _Edge {
  final double x0, y0, x1, y1;
  final int winding;
  _Edge(this.x0, this.y0, this.x1, this.y1, this.winding);
}

class _Crossing {
  final double x;
  final int winding;
  const _Crossing(this.x, this.winding);
}

class _ContourSpan {
  final int start;
  final int count;
  const _ContourSpan(this.start, this.count);
}

List<_ContourSpan> _resolveContours(int totalPoints, List<int>? counts) {
  if (counts == null || counts.isEmpty) {
    return <_ContourSpan>[_ContourSpan(0, totalPoints)];
  }
  int consumed = 0;
  final out = <_ContourSpan>[];
  for (final raw in counts) {
    if (raw <= 0) continue;
    if (consumed + raw > totalPoints) {
      return <_ContourSpan>[_ContourSpan(0, totalPoints)];
    }
    out.add(_ContourSpan(consumed, raw));
    consumed += raw;
  }
  if (out.isEmpty || consumed != totalPoints) {
    return <_ContourSpan>[_ContourSpan(0, totalPoints)];
  }
  return out;
}
