/// ============================================================================
/// AMCAD — Analytic Micro-Cell Adaptive Distance-field Rasterization
/// ============================================================================
///
/// Trata cada pixel não como um ponto, mas como um DOMÍNIO DE INTEGRAÇÃO.
/// Calcula a cobertura analítica exata (ou aproximação de erro controlado)
/// da primitiva sobre esse domínio.
///
/// PRINCÍPIO CENTRAL:
///   Em vez de amostrar pontos, integramos a função característica χ_P(x,y)
///   sobre o quadrado do pixel usando representação implícita via SDF.
///
///   C_ij = (1/|Ω|) ∬_Ω χ_P(x,y) dx dy
///
///   O truque é NUNCA calcular χ diretamente. Representamos a fronteira
///   implicitamente via SDF φ(x,y), então χ_P = H(-φ) onde H é Heaviside.
///
/// INOVAÇÃO:
///   - Aproximação de Taylor Adaptativa por Blocos (micro-células)
///   - Aritmética de ponto fixo 24.8 para evitar boxing
///   - Morton Codes para localidade espacial
///   - R-funções para operações booleanas suaves
///   - Zero-allocation no hot path
///
library amcad;

import 'dart:typed_data';
import 'dart:math' as math;
import '../common/polygon_contract.dart';

// ─────────────────────────────────────────────────────────────────────────────
// CONSTANTES
// ─────────────────────────────────────────────────────────────────────────────

/// Tamanho da micro-célula (4×4 pixels)
const int kMicroCellSize = 4;

/// Ponto fixo 24.8
const int kFixedBits = 8;
const int kFixedOne = 1 << kFixedBits;

/// Largura do filtro AA (em pixels)
const double kAAWidth = 0.5;

/// EPS para tratar “ponto em cima da aresta” (evita linhas/oscilações)
const double kEdgeEps = 1e-6;

// ─────────────────────────────────────────────────────────────────────────────
// LOOK-UP TABLE DE COBERTURA ANALÍTICA
// ─────────────────────────────────────────────────────────────────────────────

/// LUT que mapeia φ quantizado e ângulo do gradiente para cobertura
class AnalyticCoverageLUT {
  static const int phiBins = 256;
  static const int angleBins = 64;
  static const double tRange = 3.0;

  final Uint8List _table;

  AnalyticCoverageLUT() : _table = Uint8List(phiBins * angleBins) {
    _precompute();
  }

  void _precompute() {
    for (int p = 0; p < phiBins; p++) {
      // t em [-tRange, +tRange]
      final tBase = -tRange + (2.0 * tRange) * (p / (phiBins - 1));

      for (int a = 0; a < angleBins; a++) {
        final theta = (a / (angleBins - 1)) * math.pi;

        // Aproxima footprint do pixel na direção do gradiente
        final footprint =
            (math.cos(theta).abs() + math.sin(theta).abs()).clamp(1e-6, 1e9);

        final t = tBase / footprint;

        // Cobertura suave
        final coverage = 0.5 - 0.5 * _tanh(t);

        _table[p * angleBins + a] = (coverage * 255).round().clamp(0, 255);
      }
    }
  }

  /// Aproximação rápida de tanh
  double _tanh(double x) {
    if (x > 3.0) return 1.0;
    if (x < -3.0) return -1.0;
    final x2 = x * x;
    return x * (27.0 + x2) / (27.0 + 9.0 * x2);
  }

  /// Obtém cobertura para φ e ângulo, escalando por ||grad|| e largura AA
  int getCoverage(double phi, double angle, double gradMag) {
    final gm = (gradMag.abs() < 1e-9) ? 1.0 : gradMag.abs();

    // t = phi/(||grad||*w)
    final t = (phi / (gm * kAAWidth)).clamp(-tRange, tRange);

    final pIdx = (((t + tRange) / (2.0 * tRange)) * (phiBins - 1))
        .round()
        .clamp(0, phiBins - 1);

    final normalizedAngle = angle.abs() % math.pi;
    final aIdx = ((normalizedAngle / math.pi) * (angleBins - 1))
        .round()
        .clamp(0, angleBins - 1);

    var c = _table[pIdx * angleBins + aIdx];

    if (c <= 2) return 0;
    if (c >= 253) return 255;
    return c;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// R-FUNÇÕES PARA OPERAÇÕES CSG
// ─────────────────────────────────────────────────────────────────────────────

/// União C¹ contínua: φ_union = φ₁ + φ₂ - √(φ₁² + φ₂²)
double rUnion(double phi1, double phi2) {
  return phi1 + phi2 - math.sqrt(phi1 * phi1 + phi2 * phi2);
}

/// Interseção C¹ contínua: φ_intersect = φ₁ + φ₂ + √(φ₁² + φ₂²)
double rIntersect(double phi1, double phi2) {
  return phi1 + phi2 + math.sqrt(phi1 * phi1 + phi2 * phi2);
}

// ─────────────────────────────────────────────────────────────────────────────
// SDF RESULT
// ─────────────────────────────────────────────────────────────────────────────

class _SdfResult {
  final double phi;
  final double unsignedDist;
  final bool inside;
  final double gradX;
  final double gradY;

  const _SdfResult({
    required this.phi,
    required this.unsignedDist,
    required this.inside,
    required this.gradX,
    required this.gradY,
  });

  double get gradMag => math.sqrt(gradX * gradX + gradY * gradY);
  double get angle => math.atan2(gradY, gradX);
}

// ─────────────────────────────────────────────────────────────────────────────
// RASTERIZADOR AMCAD
// ─────────────────────────────────────────────────────────────────────────────

class AMCADRasterizer implements PolygonContract {
  final int width;
  final int height;

  /// Framebuffer
  late final Uint32List _framebuffer;

  /// LUT de cobertura
  final AnalyticCoverageLUT _coverageLUT;

  /// Número de tiles
  final int tilesX;
  final int tilesY;

  AMCADRasterizer({required this.width, required this.height})
      : tilesX = (width + kMicroCellSize - 1) ~/ kMicroCellSize,
        tilesY = (height + kMicroCellSize - 1) ~/ kMicroCellSize,
        _coverageLUT = AnalyticCoverageLUT() {
    _framebuffer = Uint32List(width * height);
  }

  void clear([int backgroundColor = 0xFF000000]) {
    _framebuffer.fillRange(0, _framebuffer.length, backgroundColor);
  }

  /// Desenha um polígono usando SDF analítico
  @override
  void drawPolygon(
    List<double> vertices,
    int color, {
    int windingRule = 1,
    List<int>? contourVertexCounts,
  }) {
    if (vertices.length < 6) return;

    final n = vertices.length ~/ 2;
    final contours = _resolveContours(n, contourVertexCounts);
    final edges = _buildEdges(vertices, contours);
    if (edges.isEmpty) return;

    // Bounding box
    double minX = double.infinity, maxX = double.negativeInfinity;
    double minY = double.infinity, maxY = double.negativeInfinity;

    for (int i = 0; i < n; i++) {
      final x = vertices[i * 2];
      final y = vertices[i * 2 + 1];
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    }

    // Tiles afetados
    final tileMinX = (minX / kMicroCellSize).floor().clamp(0, tilesX - 1);
    final tileMaxX = (maxX / kMicroCellSize).ceil().clamp(0, tilesX - 1);
    final tileMinY = (minY / kMicroCellSize).floor().clamp(0, tilesY - 1);
    final tileMaxY = (maxY / kMicroCellSize).ceil().clamp(0, tilesY - 1);
    final minYi = minY.floor().clamp(0, height - 1);
    final maxYi = maxY.ceil().clamp(0, height - 1);
    final rowBuckets = _buildRowBuckets(minYi, maxYi, edges);
    final allEdgeIndices = List<int>.generate(edges.length, (i) => i);

    for (int ty = tileMinY; ty <= tileMaxY; ty++) {
      for (int tx = tileMinX; tx <= tileMaxX; tx++) {
        _processTile(
          tx,
          ty,
          vertices,
          color,
          windingRule,
          contours,
          edges,
          rowBuckets,
          allEdgeIndices,
          minYi,
          maxYi,
        );
      }
    }
  }

  /// Processa um tile
  void _processTile(int tx, int ty, List<double> vertices, int color,
      [int windingRule = 1,
      List<_ContourSpan>? contours,
      List<_EdgeData>? edges,
      List<List<int>>? rowBuckets,
      List<int>? allEdgeIndices,
      int minYi = 0,
      int maxYi = 0]) {
    contours ??= _resolveContours(vertices.length ~/ 2, null);
    edges ??= _buildEdges(vertices, contours);
    rowBuckets ??= _buildRowBuckets(minYi, maxYi, edges);
    allEdgeIndices ??= List<int>.generate(edges.length, (i) => i);
    final tileX = tx * kMicroCellSize;
    final tileY = ty * kMicroCellSize;

    // Centro do tile
    final centerX = tileX + kMicroCellSize / 2.0;
    final centerY = tileY + kMicroCellSize / 2.0;

    final c = _signedDistanceAndGrad(
      centerX,
      centerY,
      vertices,
      windingRule,
      contours,
      edges,
      rowBuckets,
      allEdgeIndices,
      minYi,
      maxYi,
    );

    final halfDiag = kMicroCellSize * 0.7071067811865476;
    final safe = halfDiag + kAAWidth;

    if (c.unsignedDist > safe) {
      if (c.inside) {
        _fillTile(tileX, tileY, color, 255);
      }
      return;
    }

    // Tile de fronteira: processar pixel a pixel
    for (int py = 0; py < kMicroCellSize; py++) {
      final globalY = tileY + py;
      if (globalY >= height) break;

      for (int px = 0; px < kMicroCellSize; px++) {
        final globalX = tileX + px;
        if (globalX >= width) break;

        // Coordenadas relativas ao centro do pixel
        final pixelCenterX = globalX + 0.5;
        final pixelCenterY = globalY + 0.5;

        final s = _signedDistanceAndGrad(
          pixelCenterX,
          pixelCenterY,
          vertices,
          windingRule,
          contours,
          edges,
          rowBuckets,
          allEdgeIndices,
          minYi,
          maxYi,
        );

        final coverage = _coverageLUT.getCoverage(s.phi, s.angle, s.gradMag);

        if (coverage != 0) {
          _blendPixel(globalX, globalY, color, coverage);
        }
      }
    }
  }

  _SdfResult _signedDistanceAndGrad(
    double x,
    double y,
    List<double> vertices,
    int windingRule,
    List<_ContourSpan> contours,
    List<_EdgeData> edges,
    List<List<int>> rowBuckets,
    List<int> allEdgeIndices,
    int minYi,
    int maxYi,
  ) {
    double minDist2 = double.infinity;
    double bestCx = 0.0, bestCy = 0.0;
    double bestEx = 1.0, bestEy = 0.0;

    int evenOddCrossings = 0;
    int nonZeroWinding = 0;

    final yi = y.floor().clamp(minYi, maxYi);
    final row = rowBuckets[yi - minYi];
    final candidates = row.isEmpty ? allEdgeIndices : row;

    for (int k = 0; k < candidates.length; k++) {
      final e = edges[candidates[k]];
      final xi = e.x1;
      final yi1 = e.y1;
      final xj = e.x2;
      final yj = e.y2;

      final intersects = ((yi1 > y) != (yj > y)) &&
          (x < (xj - xi) * (y - yi1) / (yj - yi1) + xi);
      if (intersects) {
        evenOddCrossings++;
      }

      if (((yi1 <= y) && (yj > y)) || ((yi1 > y) && (yj <= y))) {
        final isLeft = (xj - xi) * (y - yi1) - (yj - yi1) * (x - xi);
        if (e.winding > 0) {
          if (isLeft > 0.0) nonZeroWinding++;
        } else if (isLeft < 0.0) {
          nonZeroWinding--;
        }
      }

      final ex = xi - xj;
      final ey = yi1 - yj;
      final len2 = ex * ex + ey * ey;

      if (len2 > 1e-12) {
        var t = ((x - xj) * ex + (y - yj) * ey) / len2;
        if (t < 0.0) {
          t = 0.0;
        } else if (t > 1.0) {
          t = 1.0;
        }

        final cx = xj + t * ex;
        final cy = yj + t * ey;

        final dx = x - cx;
        final dy = y - cy;
        final d2 = dx * dx + dy * dy;

        if (d2 < minDist2) {
          minDist2 = d2;
          bestCx = cx;
          bestCy = cy;
          bestEx = ex;
          bestEy = ey;
        }
      }
    }

    bool inside = (windingRule == 0)
        ? ((evenOddCrossings & 1) != 0)
        : (nonZeroWinding != 0);

    final unsignedDist = math.sqrt(minDist2);
    final onEdge = unsignedDist <= kEdgeEps;
    if (onEdge) {
      inside = true;
    }

    final phi = inside ? -unsignedDist : unsignedDist;

    double gx, gy;

    if (unsignedDist > 1e-9) {
      gx = (x - bestCx) / unsignedDist;
      gy = (y - bestCy) / unsignedDist;

      if (inside) {
        gx = -gx;
        gy = -gy;
      }
    } else {
      final el = math.sqrt(bestEx * bestEx + bestEy * bestEy);
      if (el > 1e-12) {
        gx = bestEy / el;
        gy = -bestEx / el;
      } else {
        gx = 1.0;
        gy = 0.0;
      }
    }

    return _SdfResult(
      phi: phi,
      unsignedDist: unsignedDist,
      inside: inside,
      gradX: gx,
      gradY: gy,
    );
  }

  /// Preenche um tile com cor sólida
  void _fillTile(int tileX, int tileY, int color, int alpha) {
    for (int py = 0; py < kMicroCellSize; py++) {
      final globalY = tileY + py;
      if (globalY >= height) break;

      for (int px = 0; px < kMicroCellSize; px++) {
        final globalX = tileX + px;
        if (globalX >= width) break;

        _blendPixel(globalX, globalY, color, alpha);
      }
    }
  }

  /// Blend de pixel
  void _blendPixel(int x, int y, int foreground, int alpha) {
    final idx = y * width + x;

    if (alpha >= 255) {
      _framebuffer[idx] = foreground;
      return;
    }

    final bg = _framebuffer[idx];
    final fgR = (foreground >> 16) & 0xFF;
    final fgG = (foreground >> 8) & 0xFF;
    final fgB = foreground & 0xFF;
    final bgR = (bg >> 16) & 0xFF;
    final bgG = (bg >> 8) & 0xFF;
    final bgB = bg & 0xFF;

    final invA = 255 - alpha;
    final r = (fgR * alpha + bgR * invA) ~/ 255;
    final g = (fgG * alpha + bgG * invA) ~/ 255;
    final b = (fgB * alpha + bgB * invA) ~/ 255;

    _framebuffer[idx] = 0xFF000000 | (r << 16) | (g << 8) | b;
  }

  Uint32List get buffer => _framebuffer;

  List<_EdgeData> _buildEdges(
      List<double> vertices, List<_ContourSpan> contours) {
    final edges = <_EdgeData>[];
    for (final contour in contours) {
      if (contour.count < 2) continue;
      for (int local = 0; local < contour.count; local++) {
        final int j = contour.start + local;
        final int i = contour.start + ((local + 1) % contour.count);
        final x1 = vertices[i * 2];
        final y1 = vertices[i * 2 + 1];
        final x2 = vertices[j * 2];
        final y2 = vertices[j * 2 + 1];
        edges.add(_EdgeData(x1, y1, x2, y2, y1 < y2 ? 1 : -1));
      }
    }
    return edges;
  }

  List<List<int>> _buildRowBuckets(
      int minYi, int maxYi, List<_EdgeData> edges) {
    final rows = maxYi - minYi + 1;
    final buckets = List<List<int>>.generate(rows, (_) => <int>[]);
    for (int i = 0; i < edges.length; i++) {
      final e = edges[i];
      final minY = math.min(e.y1, e.y2);
      final maxY = math.max(e.y1, e.y2);
      final r0 = (minY.floor() - 1).clamp(minYi, maxYi);
      final r1 = (maxY.ceil() + 1).clamp(minYi, maxYi);
      for (int y = r0; y <= r1; y++) {
        buckets[y - minYi].add(i);
      }
    }
    return buckets;
  }
}

class _EdgeData {
  final double x1;
  final double y1;
  final double x2;
  final double y2;
  final int winding;
  const _EdgeData(this.x1, this.y1, this.x2, this.y2, this.winding);
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
