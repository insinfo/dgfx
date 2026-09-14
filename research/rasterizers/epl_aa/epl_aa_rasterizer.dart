/// ============================================================================
/// EPL_AA — EdgePlane Lookup Anti-Aliasing
/// ============================================================================
///
/// Uma ideia bem diferente do "4×4 subpixel" e do "cell accumulation":
/// em vez de amostrar subpixels, calcula-se diretamente a FRAÇÃO DE ÁREA
/// que um semi-plano (definido pela aresta mais relevante) ocupa dentro
/// do quadrado do pixel.
///
/// PRINCÍPIO CENTRAL:
///   A cobertura do quadrado do pixel por um semi-plano depende APENAS de:
///   1. Orientação da reta (ângulo θ da normal/tangente)
///   2. Distância assinada (s) da reta ao centro do pixel
///
///   Ou seja: α ≈ C(θ, s)
///
///   Onde s é a distância em "unidades de pixel" e θ é a orientação.
///
/// TÉCNICA:
///   1. Pré-computa uma LUT 2D com coberturas para todas as combinações (θ, s)
///   2. Em runtime, apenas indexa a LUT e retorna o alpha
///   3. Fallback para 4×4 apenas em casos patológicos (vértices, interseções)
///
/// PERFORMANCE:
///   - Evita loops internos de 16 amostras
///   - Reduz branch misprediction
///   - Usa Uint8List e soma incremental
///   - A parte "pesada" fica confinada a poucos pixels
///
library epl_aa;

import 'dart:typed_data';
import 'dart:math' as math;
import 'epl_aa_tables.dart';
import '../common/polygon_contract.dart';

// ─────────────────────────────────────────────────────────────────────────────
// LOOK-UP TABLE DE COBERTURA
// ─────────────────────────────────────────────────────────────────────────────

/// LUT 2D para cobertura de semi-plano.
///
/// Armazena, para cada combinação de (ângulo, distância), a porcentagem
/// de área do pixel coberta pelo semi-plano.
class CoverageLUT2D {
  /// Número de bins para o ângulo θ (0..π/2, explorando simetria)
  static const int thetaBins = kEplThetaBins;

  /// Número de bins para a distância s (tipicamente -1.0..+1.0 como folga)
  static const int distBins = kEplDistBins;

  /// Tabela de coberturas (0..255)
  final Uint8List _table;
  static const double _halfPi = math.pi / 2.0;
  static const double _distMin = kEplDistMin;
  static const double _distSpan = kEplDistMax - kEplDistMin;
  static const double _thetaScale = (thetaBins - 1) / _halfPi;
  static const double _distScale = (distBins - 1) / _distSpan;

  CoverageLUT2D() : _table = kEplCoverageTable;

  /// Obtém cobertura para um ângulo e distância
  @pragma('vm:prefer-inline')
  int getCoverage(double theta, double signedDist) {
    // Normalizar ângulo para [0, π/2]
    var normalizedTheta = theta.abs();
    while (normalizedTheta > math.pi / 2) {
      normalizedTheta = math.pi - normalizedTheta;
    }

    // Índices na tabela
    final thetaIdx = ((normalizedTheta / (math.pi / 2)) * (thetaBins - 1))
        .round()
        .clamp(0, thetaBins - 1);
    final distIdx = (((signedDist - _distMin) / _distSpan) * (distBins - 1))
        .round()
        .clamp(0, distBins - 1);

    return _table[thetaIdx * distBins + distIdx];
  }

  @pragma('vm:prefer-inline')
  int thetaToIndex(double theta) {
    var normalizedTheta = theta.abs();
    if (normalizedTheta > _halfPi) {
      normalizedTheta = math.pi - normalizedTheta;
      if (normalizedTheta < 0) normalizedTheta = -normalizedTheta;
    }
    return (normalizedTheta * _thetaScale).round().clamp(0, thetaBins - 1);
  }

  @pragma('vm:prefer-inline')
  int getCoverageByThetaIndex(int thetaIdx, double signedDist) {
    final distIdx =
        ((signedDist - _distMin) * _distScale).round().clamp(0, distBins - 1);
    return _table[thetaIdx * distBins + distIdx];
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ARESTA PROCESSADA
// ─────────────────────────────────────────────────────────────────────────────

class EplProcessedEdge {
  final double x1, y1, x2, y2;
  final double vx, vy;
  final double vv;
  final double minX, maxX, minY, maxY;

  /// Normal unitária
  final double nx, ny;

  /// Termo constante do plano: nx * px + ny * py + c = 0
  final double planeC;

  /// Ângulo da normal
  final double theta;
  final int thetaIdx;

  /// Comprimento da aresta
  final double length;

  /// Inverse length para normalização
  final double invLength;

  EplProcessedEdge({
    required this.x1,
    required this.y1,
    required this.x2,
    required this.y2,
    required this.vx,
    required this.vy,
    required this.vv,
    required this.minX,
    required this.maxX,
    required this.minY,
    required this.maxY,
    required this.nx,
    required this.ny,
    required this.planeC,
    required this.theta,
    required this.thetaIdx,
    required this.length,
    required this.invLength,
  });

  factory EplProcessedEdge.fromPoints(
      double x1, double y1, double x2, double y2, CoverageLUT2D lut) {
    final dx = x2 - x1;
    final dy = y2 - y1;
    final len = math.sqrt(dx * dx + dy * dy);
    final invLen = len > 0 ? 1.0 / len : 0.0;
    final vv = dx * dx + dy * dy;
    final minX = math.min(x1, x2);
    final maxX = math.max(x1, x2);
    final minY = math.min(y1, y2);
    final maxY = math.max(y1, y2);

    // Normal apontando para a direita do vetor (sentido horário)
    final nx = dy * invLen;
    final ny = -dx * invLen;
    final planeC = -(nx * x1 + ny * y1);

    // Ângulo da normal
    final theta = math.atan2(ny, nx);
    final thetaIdx = lut.thetaToIndex(theta);

    return EplProcessedEdge(
      x1: x1,
      y1: y1,
      x2: x2,
      y2: y2,
      vx: dx,
      vy: dy,
      vv: vv,
      minX: minX,
      maxX: maxX,
      minY: minY,
      maxY: maxY,
      nx: nx,
      ny: ny,
      planeC: planeC,
      theta: theta,
      thetaIdx: thetaIdx,
      length: len,
      invLength: invLen,
    );
  }

  /// Calcula distância assinada de um ponto ao plano da aresta
  @pragma('vm:prefer-inline')
  double signedDistance(double px, double py) {
    return nx * px + ny * py + planeC;
  }

  /// Verifica se o ponto está próximo de um endpoint (caso patológico)
  @pragma('vm:prefer-inline')
  bool isNearEndpoint(double px, double py, double threshold) {
    final d1 = (px - x1).abs() + (py - y1).abs(); // Manhattan
    final d2 = (px - x2).abs() + (py - y2).abs();
    return d1 < threshold || d2 < threshold;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// RASTERIZADOR EPL_AA
// ─────────────────────────────────────────────────────────────────────────────

class EPLRasterizer implements PolygonContract {
  final int width;
  final int height;

  /// Buffer de pixels
  late final Uint32List _buffer;

  /// LUT de cobertura
  final CoverageLUT2D _coverageLUT;

  /// Tamanho do tile para processamento
  static const int tileSize = 32;
  static const double _candidateExpand = 1.5;
  static const double _farDistSq = 0.55 * 0.55;
  static const double _pathologicalSecondDistSq = 0.6 * 0.6;

  EPLRasterizer({required this.width, required this.height})
      : _coverageLUT = CoverageLUT2D() {
    _buffer = Uint32List(width * height);
  }

  void clear([int backgroundColor = 0xFF000000]) {
    _buffer.fillRange(0, _buffer.length, backgroundColor);
  }

  /// Desenha um polígono usando o método de semi-plano com LUT
  void drawPolygon(
    List<double> vertices,
    int color, {
    int windingRule = 1,
    List<int>? contourVertexCounts,
  }) {
    if (vertices.length < 6) return;

    // Converter para arestas processadas
    final n = vertices.length ~/ 2;
    final contours = _resolveContours(n, contourVertexCounts);
    final edges = <EplProcessedEdge>[];
    edges.length = 0;

    for (final contour in contours) {
      if (contour.count < 2) continue;
      for (int local = 0; local < contour.count; local++) {
        final i = contour.start + local;
        final j = contour.start + ((local + 1) % contour.count);
        edges.add(EplProcessedEdge.fromPoints(
          vertices[i * 2],
          vertices[i * 2 + 1],
          vertices[j * 2],
          vertices[j * 2 + 1],
          _coverageLUT,
        ));
      }
    }
    if (edges.isEmpty) {
      return;
    }

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

    final pxMinX = minX.floor().clamp(0, width - 1);
    final pxMaxX = maxX.ceil().clamp(0, width - 1);
    final pxMinY = minY.floor().clamp(0, height - 1);
    final pxMaxY = maxY.ceil().clamp(0, height - 1);

    final rowBuckets = _buildRowBuckets(edges, pxMinY, pxMaxY);
    final minTileX = pxMinX ~/ tileSize;
    final maxTileX = pxMaxX ~/ tileSize;
    final minTileY = pxMinY ~/ tileSize;
    final maxTileY = pxMaxY ~/ tileSize;
    final tilesX = maxTileX - minTileX + 1;
    final tileBuckets = _buildTileBuckets(
      edges,
      pxMinX,
      pxMaxX,
      pxMinY,
      pxMaxY,
      minTileX,
      maxTileX,
      minTileY,
      maxTileY,
    );

    final edgeStamp = Int32List(edges.length);
    final rowTileCandidates = <int>[];
    int stamp = 1;

    for (int ty = minTileY; ty <= maxTileY; ty++) {
      final tileY0 = math.max(ty * tileSize, pxMinY);
      final tileY1 = math.min((ty + 1) * tileSize - 1, pxMaxY);
      final tileRowBase = (ty - minTileY) * tilesX;

      for (int tx = minTileX; tx <= maxTileX; tx++) {
        final tileX0 = math.max(tx * tileSize, pxMinX);
        final tileX1 = math.min((tx + 1) * tileSize - 1, pxMaxX);
        final tileCandidates = tileBuckets[tileRowBase + (tx - minTileX)];
        final hasTileCandidates = tileCandidates.isNotEmpty;

        if (hasTileCandidates) {
          stamp++;
          if (stamp >= 0x7FFFFFFF) {
            edgeStamp.fillRange(0, edgeStamp.length, 0);
            stamp = 1;
          }
          for (int i = 0; i < tileCandidates.length; i++) {
            edgeStamp[tileCandidates[i]] = stamp;
          }
        }

        for (int py = tileY0; py <= tileY1; py++) {
          final rowEdges = rowBuckets[py - pxMinY];
          if (rowEdges.isEmpty) continue;

          final centerY = py + 0.5;
          final row = py * width;

          rowTileCandidates.clear();
          if (hasTileCandidates) {
            for (int i = 0; i < rowEdges.length; i++) {
              final edgeIdx = rowEdges[i];
              if (edgeStamp[edgeIdx] == stamp) {
                rowTileCandidates.add(edgeIdx);
              }
            }
          }

          if (rowTileCandidates.isEmpty) {
            final inside = _isPointInsideIndexed(
              edges,
              rowEdges,
              tileX0 + 0.5,
              centerY,
              windingRule,
            );
            if (inside) {
              _buffer.fillRange(row + tileX0, row + tileX1 + 1, color);
            }
            continue;
          }

          for (int px = tileX0; px <= tileX1; px++) {
            final centerX = px + 0.5;
            final coverage = _computePixelCoverage(
              edges,
              rowTileCandidates,
              rowEdges,
              centerX,
              centerY,
              windingRule,
            );

            if (coverage > 0) {
              _blendPixelByIndex(row + px, color, coverage);
            }
          }
        }
      }
    }
  }

  /// Computa a cobertura de um pixel usando a aresta dominante
  int _computePixelCoverage(
    List<EplProcessedEdge> edges,
    List<int> distanceCandidates,
    List<int> rowEdgeIndices,
    double centerX,
    double centerY,
    int windingRule,
  ) {
    EplProcessedEdge? dominantEdge;
    double minDistSq = double.infinity;
    double secondMinDistSq = double.infinity;

    for (int i = 0; i < distanceCandidates.length; i++) {
      final edge = edges[distanceCandidates[i]];
      final distSq = _distanceToSegmentSq(edge, centerX, centerY);

      if (distSq < minDistSq) {
        secondMinDistSq = minDistSq;
        minDistSq = distSq;
        dominantEdge = edge;
      } else if (distSq < secondMinDistSq) {
        secondMinDistSq = distSq;
      }
    }

    if (dominantEdge == null) return 0;
    final centerInside = _isPointInsideIndexed(
      edges,
      rowEdgeIndices,
      centerX,
      centerY,
      windingRule,
    );

    // Pixel longe da borda: classificação binária robusta.
    if (minDistSq > _farDistSq) {
      return centerInside ? 255 : 0;
    }

    // Verificar casos patológicos
    final isPathological = secondMinDistSq < _pathologicalSecondDistSq ||
        dominantEdge.isNearEndpoint(centerX, centerY, 1.0);

    if (isPathological) {
      // Fallback para supersampling 4×4
      return _supersample4x4(
        edges,
        rowEdgeIndices,
        centerX - 0.5,
        centerY - 0.5,
        windingRule,
      );
    }

    // Caso normal: usar LUT
    final signedDist = dominantEdge.signedDistance(centerX, centerY);
    var coverage =
        _coverageLUT.getCoverageByThetaIndex(dominantEdge.thetaIdx, signedDist);

    // Alinhar o lado "inside" da LUT com a classificação global do polígono.
    final lineInside = signedDist <= 0.0;
    if (lineInside != centerInside) {
      coverage = 255 - coverage;
    }

    return coverage.clamp(0, 255);
  }

  /// Fallback: supersampling 4×4 para pixels problemáticos
  int _supersample4x4(
    List<EplProcessedEdge> edges,
    List<int> rowEdgeIndices,
    double pixelX,
    double pixelY,
    int windingRule,
  ) {
    int count = 0;

    for (int sy = 0; sy < 4; sy++) {
      final y = pixelY + (sy + 0.5) / 4;

      for (int sx = 0; sx < 4; sx++) {
        final x = pixelX + (sx + 0.5) / 4;

        if (_isPointInsideIndexed(edges, rowEdgeIndices, x, y, windingRule)) {
          count++;
        }
      }
    }

    return (count * 255) ~/ 16;
  }

  @pragma('vm:prefer-inline')
  bool _isPointInsideIndexed(
    List<EplProcessedEdge> edges,
    List<int> edgeIndices,
    double px,
    double py,
    int windingRule,
  ) {
    if (windingRule == 0) {
      bool inside = false;
      for (int i = 0; i < edgeIndices.length; i++) {
        final edge = edges[edgeIndices[i]];
        final x1 = edge.x1;
        final y1 = edge.y1;
        final x2 = edge.x2;
        final y2 = edge.y2;
        if ((y1 > py) != (y2 > py) &&
            (px < (x2 - x1) * (py - y1) / (y2 - y1) + x1)) {
          inside = !inside;
        }
      }
      return inside;
    }

    int winding = 0;

    for (int i = 0; i < edgeIndices.length; i++) {
      final edge = edges[edgeIndices[i]];
      final x1 = edge.x1;
      final y1 = edge.y1;
      final x2 = edge.x2;
      final y2 = edge.y2;

      if (y1 <= py) {
        if (y2 > py && _isLeft(x1, y1, x2, y2, px, py) > 0) {
          winding++;
        }
      } else {
        if (y2 <= py && _isLeft(x1, y1, x2, y2, px, py) < 0) {
          winding--;
        }
      }
    }

    return winding != 0;
  }

  @pragma('vm:prefer-inline')
  double _isLeft(
    double x1,
    double y1,
    double x2,
    double y2,
    double px,
    double py,
  ) {
    return (x2 - x1) * (py - y1) - (px - x1) * (y2 - y1);
  }

  @pragma('vm:prefer-inline')
  double _distanceToSegmentSq(EplProcessedEdge edge, double px, double py) {
    final vx = edge.vx;
    final vy = edge.vy;
    final wx = px - edge.x1;
    final wy = py - edge.y1;

    final vv = edge.vv;
    if (vv <= 1e-12) {
      return wx * wx + wy * wy;
    }

    var t = (wx * vx + wy * vy) / vv;
    if (t < 0.0) {
      t = 0.0;
    } else if (t > 1.0) {
      t = 1.0;
    }

    final cx = edge.x1 + vx * t;
    final cy = edge.y1 + vy * t;
    final dx = px - cx;
    final dy = py - cy;
    return dx * dx + dy * dy;
  }

  List<List<int>> _buildRowBuckets(
    List<EplProcessedEdge> edges,
    int minY,
    int maxY,
  ) {
    final rows = maxY - minY + 1;
    final buckets = List<List<int>>.generate(rows, (_) => <int>[]);
    for (int i = 0; i < edges.length; i++) {
      final e = edges[i];
      final y0 = (e.minY.floor() - 1).clamp(minY, maxY);
      final y1 = (e.maxY.ceil() + 1).clamp(minY, maxY);
      for (int y = y0; y <= y1; y++) {
        buckets[y - minY].add(i);
      }
    }
    return buckets;
  }

  List<List<int>> _buildTileBuckets(
    List<EplProcessedEdge> edges,
    int minX,
    int maxX,
    int minY,
    int maxY,
    int minTileX,
    int maxTileX,
    int minTileY,
    int maxTileY,
  ) {
    final tilesX = maxTileX - minTileX + 1;
    final tilesY = maxTileY - minTileY + 1;
    final buckets = List<List<int>>.generate(tilesX * tilesY, (_) => <int>[]);

    for (int i = 0; i < edges.length; i++) {
      final e = edges[i];
      final ex0 = (e.minX - _candidateExpand).floor().clamp(minX, maxX).toInt();
      final ex1 = (e.maxX + _candidateExpand).ceil().clamp(minX, maxX).toInt();
      final ey0 = (e.minY - _candidateExpand).floor().clamp(minY, maxY).toInt();
      final ey1 = (e.maxY + _candidateExpand).ceil().clamp(minY, maxY).toInt();
      if (ex0 > ex1 || ey0 > ey1) continue;

      final tx0 = (ex0 ~/ tileSize).clamp(minTileX, maxTileX).toInt();
      final tx1 = (ex1 ~/ tileSize).clamp(minTileX, maxTileX).toInt();
      final ty0 = (ey0 ~/ tileSize).clamp(minTileY, maxTileY).toInt();
      final ty1 = (ey1 ~/ tileSize).clamp(minTileY, maxTileY).toInt();

      for (int ty = ty0; ty <= ty1; ty++) {
        final rowBase = (ty - minTileY) * tilesX;
        for (int tx = tx0; tx <= tx1; tx++) {
          buckets[rowBase + (tx - minTileX)].add(i);
        }
      }
    }
    return buckets;
  }

  /// Aplica blending de um pixel
  void _blendPixelByIndex(int idx, int foreground, int alpha) {
    final bg = _buffer[idx];

    if (alpha >= 255) {
      _buffer[idx] = foreground;
      return;
    }

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

    _buffer[idx] = 0xFF000000 | (r << 16) | (g << 8) | b;
  }

  Uint32List get buffer => _buffer;
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
