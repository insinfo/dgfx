/// ============================================================================
/// SCP_AED — Stochastic Coverage Propagation with Adaptive Error Diffusion
/// ============================================================================
///
/// Redesenhado para alinhar com o artigo de pesquisa:
///   1. Rasterização por Varredura para preenchimento (Interior/Exterior)
///   2. Difusão Estocástica para Anti-Aliasing Suave
///   3. Difusão de Erro Adaptativa para Quantização
///
library scp_aed;

import 'dart:typed_data';
import 'dart:math' as math;

class SCPAEDRasterizer {
  final int width;
  final int height;

  late final Uint32List _framebuffer;

  // Campo φ e buffers auxiliares
  late final Float64List _phi;
  late final Float64List _phiPrev;
  late final Float64List _curvature;
  late final Float64List _errorBuffer;

  // Scratch (para reduzir alocações)
  final List<_Edge> _edges = <_Edge>[];
  final List<double> _intersections = <double>[];

  // Parâmetros
  static const double alpha = 0.25;
  static const double beta = 0.15;

  static const double _phiOutside = -10.0;
  static const double _phiInside = 10.0;

  /// Banda onde a “física” roda (fora disso é estável)
  static const double _bandPhi = 4.0;

  /// Margem do bbox para difusão/erro
  static const int _bboxMargin = 6;

  SCPAEDRasterizer({required this.width, required this.height}) {
    final n = width * height;
    _framebuffer = Uint32List(n);
    _phi = Float64List(n);
    _phiPrev = Float64List(n);
    _curvature = Float64List(n);
    _errorBuffer = Float64List(n);
  }

  void clear([int backgroundColor = 0xFF000000]) {
    _framebuffer.fillRange(0, _framebuffer.length, backgroundColor);
    _phi.fillRange(0, _phi.length, _phiOutside);
    _phiPrev.fillRange(0, _phiPrev.length, _phiOutside);
    _curvature.fillRange(0, _curvature.length, 0.0);
    _errorBuffer.fillRange(0, _errorBuffer.length, 0.0);
  }

  Uint32List get buffer => _framebuffer;

  void drawPolygon(List<double> vertices, int color) {
    if (vertices.length < 6) return;

    final bbox = _computeBounds(vertices, margin: _bboxMargin);
    if (bbox.isEmpty) return;

    // IMPORTANTÍSSIMO PARA BENCHMARK:
    // Reseta somente o bbox (evita contaminar polígonos seguintes)
    _resetBboxState(bbox);

    // 1) Scanline inicializa φ (inside/outside) no bbox
    _fillInteriorScanline(vertices, bbox);

    // 2) Curvatura (κ) — simples nos vértices (você pode melhorar depois)
    _computeCurvature(vertices, bbox);

    // 3) Difusão estocástica controlada (poucas iterações)
    for (int iter = 0; iter < 2; iter++) {
      _diffuse(bbox);
    }

    // 4) Render + difusão de erro
    _render(color, bbox);
  }

  // --------------------------------------------------------------------------
  // BBox + Reset
  // --------------------------------------------------------------------------

  _Bounds _computeBounds(List<double> vertices, {int margin = 0}) {
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

    int x0 = (minX.floor() - margin).clamp(0, width - 1);
    int y0 = (minY.floor() - margin).clamp(0, height - 1);
    int x1 = (maxX.ceil() + margin).clamp(0, width - 1);
    int y1 = (maxY.ceil() + margin).clamp(0, height - 1);

    return _Bounds(x0, y0, x1, y1);
  }

  void _resetBboxState(_Bounds b) {
    for (int y = b.y0; y <= b.y1; y++) {
      final row = y * width;
      final start = row + b.x0;
      final end = row + b.x1 + 1;

      _phi.fillRange(start, end, _phiOutside);
      _phiPrev.fillRange(start, end, _phiOutside);
      _curvature.fillRange(start, end, 0.0);
      _errorBuffer.fillRange(start, end, 0.0);
    }
  }

  // --------------------------------------------------------------------------
  // Scanline
  // --------------------------------------------------------------------------

  void _fillInteriorScanline(List<double> vertices, _Bounds bbox) {
    final n = vertices.length ~/ 2;
    _edges.clear();

    for (int i = 0; i < n; i++) {
      final j = (i + 1) % n;
      double x0 = vertices[i * 2];
      double y0 = vertices[i * 2 + 1];
      double x1 = vertices[j * 2];
      double y1 = vertices[j * 2 + 1];

      if (y0 == y1) continue;
      if (y0 > y1) {
        final tx = x0;
        x0 = x1;
        x1 = tx;
        final ty = y0;
        y0 = y1;
        y1 = ty;
      }

      // Culling vertical (bbox)
      if (y1 < bbox.y0 || y0 > bbox.y1 + 1) continue;

      _edges.add(_Edge(x0, y0, x1, y1));
    }

    for (int y = bbox.y0; y <= bbox.y1; y++) {
      final scanY = y + 0.5;
      _intersections.clear();

      for (final e in _edges) {
        if (scanY >= e.y0 && scanY < e.y1) {
          final t = (scanY - e.y0) / (e.y1 - e.y0);
          _intersections.add(e.x0 + t * (e.x1 - e.x0));
        }
      }

      if (_intersections.isEmpty) continue;
      _intersections.sort();

      for (int i = 0; i + 1 < _intersections.length; i += 2) {
        int xStart = _intersections[i].ceil();
        int xEnd = _intersections[i + 1].floor();

        if (xStart < bbox.x0) xStart = bbox.x0;
        if (xEnd > bbox.x1) xEnd = bbox.x1;

        final row = y * width;

        for (int x = xStart; x <= xEnd; x++) {
          _phi[row + x] = _phiInside;
        }

        // Zona de transição inicial
        if (xStart - 1 >= bbox.x0) _phi[row + (xStart - 1)] = 0.0;
        if (xEnd + 1 <= bbox.x1) _phi[row + (xEnd + 1)] = 0.0;
      }
    }
  }

  // --------------------------------------------------------------------------
  // Curvatura (κ)
  // --------------------------------------------------------------------------

  void _computeCurvature(List<double> vertices, _Bounds bbox) {
    final n = vertices.length ~/ 2;

    for (int i = 0; i < n; i++) {
      final p0 = i;
      final p1 = (i + 1) % n;
      final p2 = (i + 2) % n;

      final dx1 = vertices[p1 * 2] - vertices[p0 * 2];
      final dy1 = vertices[p1 * 2 + 1] - vertices[p0 * 2 + 1];
      final dx2 = vertices[p2 * 2] - vertices[p1 * 2];
      final dy2 = vertices[p2 * 2 + 1] - vertices[p1 * 2 + 1];

      final ang1 = math.atan2(dy1, dx1);
      final ang2 = math.atan2(dy2, dx2);
      double diff = (ang2 - ang1).abs();
      if (diff > math.pi) diff = 2 * math.pi - diff;

      final vx = vertices[p1 * 2].round();
      final vy = vertices[p1 * 2 + 1].round();

      if (vx < bbox.x0 || vx > bbox.x1 || vy < bbox.y0 || vy > bbox.y1)
        continue;
      _curvature[vy * width + vx] = diff; // 0..pi
    }
  }

  // --------------------------------------------------------------------------
  // Difusão estocástica (só na banda)
  // --------------------------------------------------------------------------

  void _diffuse(_Bounds b) {
    // Copia φ -> φPrev no bbox
    for (int y = b.y0; y <= b.y1; y++) {
      final row = y * width;
      final start = row + b.x0;
      final end = row + b.x1 + 1;
      _phiPrev.setRange(start, end, _phi, start);
    }

    // Precisamos de 1px de borda pra vizinhança 4-conexa
    final x0 = math.max(b.x0 + 1, 1);
    final y0 = math.max(b.y0 + 1, 1);
    final x1 = math.min(b.x1 - 1, width - 2);
    final y1 = math.min(b.y1 - 1, height - 2);

    if (x0 > x1 || y0 > y1) return;

    for (int y = y0; y <= y1; y++) {
      final row = y * width;
      for (int x = x0; x <= x1; x++) {
        final idx = row + x;
        final v = _phiPrev[idx];

        // Só processa banda de transição
        if (v.abs() > _bandPhi) {
          _phi[idx] = v;
          continue;
        }

        final lap = _phiPrev[idx - width] +
            _phiPrev[idx + width] +
            _phiPrev[idx - 1] +
            _phiPrev[idx + 1] -
            4.0 * v;

        final kappa = _curvature[idx] + 0.1;
        final noise = (_pseudoRandom(x, y) - 0.5) * 2.0;

        // Evita explosão quando κ ~ 0
        final noiseScale = beta / (1.0 + 8.0 * kappa);

        _phi[idx] = v + alpha * lap + noiseScale * noise;
      }
    }
  }

  // --------------------------------------------------------------------------
  // Render + Error diffusion
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

        // Totalmente fora: não desenha
        if (phi <= -_bandPhi) continue;

        // Lê erro e zera (evita “vazamento” intra-polígono)
        final errIn = _errorBuffer[idx];
        _errorBuffer[idx] = 0.0;

        double coverage;

        // Totalmente dentro
        if (phi >= _bandPhi) {
          coverage = 1.0;
        } else {
          final p = phi + errIn;

          // Early outs
          if (p <= -5.0) {
            continue;
          } else if (p >= 5.0) {
            coverage = 1.0;
          } else {
            coverage = 1.0 / (1.0 + math.exp(-p));
          }

          if (coverage < 0.02) coverage = 0.0;
          if (coverage > 0.98) coverage = 1.0;
        }

        final a = (coverage * 255.0).round().clamp(0, 255);

        if (a > 0) {
          _blendPixel(idx, r, g, bl, a);
        }

        // Só propaga erro quando faz sentido (borda)
        if (coverage > 0.0 && coverage < 1.0 && phi.abs() < _bandPhi) {
          final q = a / 255.0;
          final e = coverage - q;
          if (e.abs() >= 0.001) {
            final kappa = _curvature[idx] + 0.1;
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

    final scale = math.exp(-2.0 * kappa);
    final e = err * scale;

    // Respeita bbox
    final yNext = y + 1;

    if (x + 1 <= b.x1) _errorBuffer[y * width + (x + 1)] += e * wR;

    if (yNext <= b.y1) {
      final rowN = yNext * width;

      if (x - 1 >= b.x0) _errorBuffer[rowN + (x - 1)] += e * wDL;
      _errorBuffer[rowN + x] += e * wD;
      if (x + 1 <= b.x1) _errorBuffer[rowN + (x + 1)] += e * wDR;
    }
  }

  // --------------------------------------------------------------------------
  // Utils
  // --------------------------------------------------------------------------

  double _pseudoRandom(int x, int y) {
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

    // (>>8) é uma aproximação ok aqui (equivale a /256)
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
  _Edge(this.x0, this.y0, this.x1, this.y1);
}
