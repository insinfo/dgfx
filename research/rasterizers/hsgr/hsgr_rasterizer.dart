/// ============================================================================
/// HSGR — Hilbert-Space Guided Rasterization (versão otimizada)
/// ============================================================================
///
/// Otimizações principais:
/// - Hilbert em *tiles* (ex.: 32x32) para evitar varrer bbox padded gigante.
/// - Path Hilbert pré-computado/cacheado (sem `sync*`/List por pixel).
/// - Atualização incremental das arestas por 4 direções (R/L/D/U).
/// - Culling por tile (fora / totalmente dentro).
/// - AA barato por distância assinada mínima às arestas:
///   alpha = clamp(minDist + 0.5, 0..1)
/// ============================================================================

import 'dart:math' as math;
import 'dart:typed_data';
import '../common/polygon_contract.dart';

@pragma('vm:prefer-inline')
double _cross2(double ax, double ay, double bx, double by) => ax * by - ay * bx;

@pragma('vm:prefer-inline')
double _triArea2(
    double x1, double y1, double x2, double y2, double x3, double y3) {
  return _cross2(x2 - x1, y2 - y1, x3 - x1, y3 - y1);
}

// ─────────────────────────────────────────────────────────────────────────────
// TRIANGULAÇÃO (EAR CLIPPING) PARA POLÍGONOS SIMPLES
// ─────────────────────────────────────────────────────────────────────────────

class _P {
  final double x;
  final double y;
  const _P(this.x, this.y);
}

@pragma('vm:prefer-inline')
double _cross(_P a, _P b, _P c) {
  final abx = b.x - a.x;
  final aby = b.y - a.y;
  final acx = c.x - a.x;
  final acy = c.y - a.y;
  return abx * acy - aby * acx;
}

double _signedArea(List<_P> pts) {
  double s = 0.0;
  for (int i = 0, j = pts.length - 1; i < pts.length; j = i++) {
    s += (pts[j].x * pts[i].y) - (pts[i].x * pts[j].y);
  }
  return s * 0.5;
}

@pragma('vm:prefer-inline')
bool _pointInTriangle(_P p, _P a, _P b, _P c) {
  final s1 = _cross(a, b, p);
  final s2 = _cross(b, c, p);
  final s3 = _cross(c, a, p);

  final hasNeg = (s1 < 0) || (s2 < 0) || (s3 < 0);
  final hasPos = (s1 > 0) || (s2 > 0) || (s3 > 0);
  return !(hasNeg && hasPos);
}

List<List<double>> _triangulateEarClipping(List<double> vertices) {
  if (vertices.length < 6 || (vertices.length & 1) == 1) return const [];

  var pts = <_P>[];
  for (int i = 0; i < vertices.length; i += 2) {
    pts.add(_P(vertices[i], vertices[i + 1]));
  }

  // remove último se repetir o primeiro
  if (pts.length >= 2) {
    final first = pts.first;
    final last = pts.last;
    if ((first.x == last.x) && (first.y == last.y)) {
      pts.removeLast();
    }
  }
  if (pts.length < 3) return const [];

  // garantir CCW
  if (_signedArea(pts) < 0) {
    pts = pts.reversed.toList();
  }

  final idx = List<int>.generate(pts.length, (i) => i);
  final triangles = <List<double>>[];

  const eps = 1e-12;

  int guard = 0;
  while (idx.length > 3 && guard++ < 10000) {
    bool earFound = false;

    for (int i = 0; i < idx.length; i++) {
      final iPrev = idx[(i - 1 + idx.length) % idx.length];
      final iCurr = idx[i];
      final iNext = idx[(i + 1) % idx.length];

      final pPrev = pts[iPrev];
      final pCurr = pts[iCurr];
      final pNext = pts[iNext];

      // convexidade (para CCW deve ser > 0)
      final crossVal = (pNext.x - pCurr.x) * (pPrev.y - pCurr.y) -
          (pNext.y - pCurr.y) * (pPrev.x - pCurr.x);
      if (crossVal <= eps) continue;

      bool hasPointInside = false;
      for (int j = 0; j < idx.length; j++) {
        final iTest = idx[j];
        if (iTest == iPrev || iTest == iCurr || iTest == iNext) continue;

        if (_pointInTriangle(pts[iTest], pPrev, pCurr, pNext)) {
          hasPointInside = true;
          break;
        }
      }
      if (hasPointInside) continue;

      // é uma orelha
      triangles.add([
        pPrev.x,
        pPrev.y,
        pCurr.x,
        pCurr.y,
        pNext.x,
        pNext.y,
      ]);
      idx.removeAt(i);
      earFound = true;
      break;
    }

    // fallback: fan triangulation
    if (!earFound) {
      for (int i = 1; i + 1 < idx.length; i++) {
        final p0 = pts[idx[0]];
        final p1 = pts[idx[i]];
        final p2 = pts[idx[i + 1]];
        triangles.add([p0.x, p0.y, p1.x, p1.y, p2.x, p2.y]);
      }
      return triangles;
    }
  }

  if (idx.length == 3) {
    final p0 = pts[idx[0]];
    final p1 = pts[idx[1]];
    final p2 = pts[idx[2]];
    triangles.add([p0.x, p0.y, p1.x, p1.y, p2.x, p2.y]);
  }

  return triangles;
}

// ─────────────────────────────────────────────────────────────────────────────
// HILBERT PATH (cacheado) — TILE ORDER
// ─────────────────────────────────────────────────────────────────────────────

class _HilbertPathCache {
  static final Map<int, Uint32List> _cache = <int, Uint32List>{};

  /// Retorna uma lista com (x | (y<<16) | (dir<<30)).
  /// dir: 0=right, 1=left, 2=down, 3=up (dir do ponto anterior -> atual).
  static Uint32List getPath(int order) {
    return _cache.putIfAbsent(order, () => _build(order));
  }

  static Uint32List _build(int order) {
    final n = 1 << order;
    final total = n * n;
    final out = Uint32List(total);

    int prevX = 0;
    int prevY = 0;

    for (int d = 0; d < total; d++) {
      final packedXY = _d2xyPacked(n, d);
      final x = packedXY & 0xFFFF;
      final y = (packedXY >> 16) & 0xFFFF;

      int dir = 0;
      if (d != 0) {
        if (x == prevX + 1) {
          dir = 0; // right
        } else if (x == prevX - 1) {
          dir = 1; // left
        } else if (y == prevY + 1) {
          dir = 2; // down
        } else {
          dir = 3; // up
        }
      }

      out[d] = packedXY | (dir << 30);
      prevX = x;
      prevY = y;
    }

    return out;
  }

  @pragma('vm:prefer-inline')
  static int _d2xyPacked(int n, int d) {
    int t = d;
    int x = 0;
    int y = 0;

    for (int s = 1; s < n; s <<= 1) {
      final rx = 1 & (t >> 1);
      final ry = 1 & (t ^ rx);

      // rot
      if (ry == 0) {
        if (rx == 1) {
          x = s - 1 - x;
          y = s - 1 - y;
        }
        final tmp = x;
        x = y;
        y = tmp;
      }

      x += s * rx;
      y += s * ry;
      t >>= 2;
    }

    return (x & 0xFFFF) | ((y & 0xFFFF) << 16);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// RASTERIZADOR HSGR
// ─────────────────────────────────────────────────────────────────────────────

class HSGRRasterizer implements PolygonContract {
  final int width;
  final int height;

  late final Uint32List _buffer;

  /// tileOrder padrão: 5 => 32x32.
  final int tileOrder;

  HSGRRasterizer({
    required this.width,
    required this.height,
    this.tileOrder = 5,
  }) {
    _buffer = Uint32List(width * height);
  }

  void clear([int backgroundColor = 0xFF000000]) {
    _buffer.fillRange(0, _buffer.length, backgroundColor);
  }

  Uint32List get buffer => _buffer;

  @override
  void drawPolygon(
    List<double> vertices,
    int color, {
    int windingRule = 1,
    List<int>? contourVertexCounts,
  }) {
    if (vertices.length < 6) return;
    final pointCount = vertices.length ~/ 2;
    final contours = _resolveContours(pointCount, contourVertexCounts);
    if (contours.isEmpty) return;

    // Fast-path: triângulo único continua no kernel original.
    if (contours.length == 1 && contours.first.count == 3) {
      drawTriangle(
        vertices[0],
        vertices[1],
        vertices[2],
        vertices[3],
        vertices[4],
        vertices[5],
        color,
      );
      return;
    }
    if (contours.length == 1 && windingRule != 0) {
      final only = contours.first;
      final local = <double>[];
      for (int i = 0; i < only.count; i++) {
        final p = only.start + i;
        local.add(vertices[p * 2]);
        local.add(vertices[p * 2 + 1]);
      }
      final tris = _triangulateEarClipping(local);
      if (tris.isNotEmpty) {
        for (final t in tris) {
          drawTriangle(
            t[0],
            t[1],
            t[2],
            t[3],
            t[4],
            t[5],
            color,
          );
        }
        return;
      }
    }

    double minX = double.infinity;
    double minY = double.infinity;
    double maxX = double.negativeInfinity;
    double maxY = double.negativeInfinity;
    for (int i = 0; i < vertices.length; i += 2) {
      final x = vertices[i];
      final y = vertices[i + 1];
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    }

    final int x0 = minX.floor().clamp(0, width - 1);
    final int y0 = minY.floor().clamp(0, height - 1);
    final int x1 = maxX.ceil().clamp(0, width - 1);
    final int y1 = maxY.ceil().clamp(0, height - 1);
    if (x0 > x1 || y0 > y1) return;

    final edges = <_PolyEdge>[];
    for (final contour in contours) {
      if (contour.count < 2) continue;
      for (int i = 0; i < contour.count; i++) {
        final int p0 = contour.start + i;
        final int p1 = contour.start + ((i + 1) % contour.count);
        final double ex1 = vertices[p0 * 2];
        final double ey1 = vertices[p0 * 2 + 1];
        final double ex2 = vertices[p1 * 2];
        final double ey2 = vertices[p1 * 2 + 1];
        edges.add(_PolyEdge(
          ex1,
          ey1,
          ex2,
          ey2,
          ey1 < ey2 ? 1 : -1,
        ));
      }
    }
    if (edges.isEmpty) return;
    final rowBuckets = _buildRowBuckets(edges, y0, y1);

    final tSize = 1 << tileOrder.clamp(1, 10);
    final tilesX = ((x1 - x0 + 1) + tSize - 1) ~/ tSize;
    final tilesY = ((y1 - y0 + 1) + tSize - 1) ~/ tSize;
    final order = _ceilLog2(math.max(tilesX, tilesY));
    final path = _HilbertPathCache.getPath(order);

    for (int i = 0; i < path.length; i++) {
      final packed = path[i];
      final tx = packed & 0xFFFF;
      final ty = (packed >> 16) & 0x3FFF;
      if (tx >= tilesX || ty >= tilesY) continue;

      final tileX0 = x0 + tx * tSize;
      final tileY0 = y0 + ty * tSize;
      final tileX1 = math.min(tileX0 + tSize - 1, x1);
      final tileY1 = math.min(tileY0 + tSize - 1, y1);

      for (int y = tileY0; y <= tileY1; y++) {
        final rowEdges = rowBuckets[y - y0];
        if (rowEdges.isEmpty) continue;
        final row = y * width;
        final py = y + 0.5;
        for (int x = tileX0; x <= tileX1; x++) {
          final idx = row + x;
          final px = x + 0.5;

          final inside = _isInsideIndexed(px, py, edges, rowEdges, windingRule);
          double minDistSq = double.infinity;
          for (int k = 0; k < rowEdges.length; k++) {
            final e = edges[rowEdges[k]];
            final distSq =
                _pointSegmentDistanceSq(px, py, e.x1, e.y1, e.x2, e.y2);
            if (distSq < minDistSq) minDistSq = distSq;
          }

          final dist = minDistSq.isFinite ? math.sqrt(minDistSq) : 0.0;
          final signed = inside ? -dist : dist;
          final alpha = (0.5 - signed).clamp(0.0, 1.0);
          if (alpha <= 0.0) continue;
          if (alpha >= 1.0) {
            _buffer[idx] = color;
          } else {
            _blendPixelByIndex(idx, color, (alpha * 255).round());
          }
        }
      }
    }
  }

  void drawTriangle(
    double x1,
    double y1,
    double x2,
    double y2,
    double x3,
    double y3,
    int color,
  ) {
    final area2 = _triArea2(x1, y1, x2, y2, x3, y3);
    if (area2.abs() < 1e-9) return;

    // CCW
    if (area2 < 0) {
      final tx = x2;
      final ty = y2;
      x2 = x3;
      y2 = y3;
      x3 = tx;
      y3 = ty;
    }

    final minX = math.min(x1, math.min(x2, x3)).floor();
    final maxX = math.max(x1, math.max(x2, x3)).ceil();
    final minY = math.min(y1, math.min(y2, y3)).floor();
    final maxY = math.max(y1, math.max(y2, y3)).ceil();

    final cMinX = minX < 0 ? 0 : (minX >= width ? width - 1 : minX);
    final cMaxX = maxX < 0 ? 0 : (maxX >= width ? width - 1 : maxX);
    final cMinY = minY < 0 ? 0 : (minY >= height ? height - 1 : minY);
    final cMaxY = maxY < 0 ? 0 : (maxY >= height ? height - 1 : maxY);

    if (cMinX > cMaxX || cMinY > cMaxY) return;

    // Edge f = a*x + b*y + c (no centro do pixel)
    final a0 = (y1 - y2), b0 = (x2 - x1), c0 = (x1 * y2 - x2 * y1);
    final a1 = (y2 - y3), b1 = (x3 - x2), c1 = (x2 * y3 - x3 * y2);
    final a2 = (y3 - y1), b2 = (x1 - x3), c2 = (x3 * y1 - x1 * y3);

    final invLen0 = 1.0 / math.sqrt(a0 * a0 + b0 * b0);
    final invLen1 = 1.0 / math.sqrt(a1 * a1 + b1 * b1);
    final invLen2 = 1.0 / math.sqrt(a2 * a2 + b2 * b2);

    final tOrder = tileOrder.clamp(1, 10);
    final tSize = 1 << tOrder;
    final path = _HilbertPathCache.getPath(tOrder);

    for (int ty = cMinY; ty <= cMaxY; ty += tSize) {
      final tileH = math.min(tSize, cMaxY - ty + 1);

      for (int tx = cMinX; tx <= cMaxX; tx += tSize) {
        final tileW = math.min(tSize, cMaxX - tx + 1);

        // corners (centro do pixel do canto)
        final xL = tx + 0.5;
        final xR = (tx + tileW - 1) + 0.5;
        final yT = ty + 0.5;
        final yB = (ty + tileH - 1) + 0.5;

        // AB
        final f0_00 = a0 * xL + b0 * yT + c0;
        final f0_10 = a0 * xR + b0 * yT + c0;
        final f0_01 = a0 * xL + b0 * yB + c0;
        final f0_11 = a0 * xR + b0 * yB + c0;
        final f0min = math.min(math.min(f0_00, f0_10), math.min(f0_01, f0_11));
        final f0max = math.max(math.max(f0_00, f0_10), math.max(f0_01, f0_11));
        if (f0max < 0) continue;

        // BC
        final f1_00 = a1 * xL + b1 * yT + c1;
        final f1_10 = a1 * xR + b1 * yT + c1;
        final f1_01 = a1 * xL + b1 * yB + c1;
        final f1_11 = a1 * xR + b1 * yB + c1;
        final f1min = math.min(math.min(f1_00, f1_10), math.min(f1_01, f1_11));
        final f1max = math.max(math.max(f1_00, f1_10), math.max(f1_01, f1_11));
        if (f1max < 0) continue;

        // CA
        final f2_00 = a2 * xL + b2 * yT + c2;
        final f2_10 = a2 * xR + b2 * yT + c2;
        final f2_01 = a2 * xL + b2 * yB + c2;
        final f2_11 = a2 * xR + b2 * yB + c2;
        final f2min = math.min(math.min(f2_00, f2_10), math.min(f2_01, f2_11));
        final f2max = math.max(math.max(f2_00, f2_10), math.max(f2_01, f2_11));
        if (f2max < 0) continue;

        // totalmente dentro
        if (f0min >= 0 && f1min >= 0 && f2min >= 0) {
          for (int y = 0; y < tileH; y++) {
            final rowStart = (ty + y) * width + tx;
            _buffer.fillRange(rowStart, rowStart + tileW, color);
          }
          continue;
        }

        // parcial: inicial no (0,0)
        double fAB = a0 * (tx + 0.5) + b0 * (ty + 0.5) + c0;
        double fBC = a1 * (tx + 0.5) + b1 * (ty + 0.5) + c1;
        double fCA = a2 * (tx + 0.5) + b2 * (ty + 0.5) + c2;

        for (int i = 0; i < path.length; i++) {
          final packed = path[i];

          if (i != 0) {
            final dir = packed >> 30;
            if (dir == 0) {
              fAB += a0;
              fBC += a1;
              fCA += a2;
            } else if (dir == 1) {
              fAB -= a0;
              fBC -= a1;
              fCA -= a2;
            } else if (dir == 2) {
              fAB += b0;
              fBC += b1;
              fCA += b2;
            } else {
              fAB -= b0;
              fBC -= b1;
              fCA -= b2;
            }
          }

          final ox = packed & 0xFFFF;
          final oy = (packed >> 16) & 0x3FFF;
          if (ox >= tileW || oy >= tileH) continue;

          final x = tx + ox;
          final y = ty + oy;
          final idx = y * width + x;

          if (fAB >= 0 && fBC >= 0 && fCA >= 0) {
            _buffer[idx] = color;
            continue;
          }

          final d0 = fAB * invLen0;
          final d1 = fBC * invLen1;
          final d2 = fCA * invLen2;
          final minD = math.min(d0, math.min(d1, d2));

          double alpha = minD + 0.5;

          if (alpha <= 0) continue;
          if (alpha >= 1) {
            _buffer[idx] = color;
            continue;
          }

          _blendPixelByIndex(idx, color, (alpha * 255).toInt());
        }
      }
    }
  }

  @pragma('vm:prefer-inline')
  void _blendPixelByIndex(int idx, int fg, int alpha255) {
    if (alpha255 <= 0) return;
    if (alpha255 >= 255) {
      _buffer[idx] = fg;
      return;
    }

    final a = alpha255 + 1; // 1..256
    final inv = 256 - a;

    final bg = _buffer[idx];

    final rb = bg & 0x00FF00FF;
    final gb = bg & 0x0000FF00;
    final rf = fg & 0x00FF00FF;
    final gf = fg & 0x0000FF00;

    final r = ((rf * a + rb * inv) >> 8) & 0x00FF00FF;
    final g = ((gf * a + gb * inv) >> 8) & 0x0000FF00;

    _buffer[idx] = 0xFF000000 | r | g;
  }
}

class _PolyEdge {
  final double x1;
  final double y1;
  final double x2;
  final double y2;
  final int winding;

  const _PolyEdge(this.x1, this.y1, this.x2, this.y2, this.winding);
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
  for (final rawCount in counts) {
    if (rawCount <= 0) continue;
    if (consumed + rawCount > totalPoints) {
      return <_ContourSpan>[_ContourSpan(0, totalPoints)];
    }
    out.add(_ContourSpan(consumed, rawCount));
    consumed += rawCount;
  }
  if (out.isEmpty || consumed != totalPoints) {
    return <_ContourSpan>[_ContourSpan(0, totalPoints)];
  }
  return out;
}

@pragma('vm:prefer-inline')
double _pointSegmentDistanceSq(
  double px,
  double py,
  double x1,
  double y1,
  double x2,
  double y2,
) {
  final vx = x2 - x1;
  final vy = y2 - y1;
  final vv = vx * vx + vy * vy;
  double t;
  if (vv <= 1e-12) {
    t = 0.0;
  } else {
    t = ((px - x1) * vx + (py - y1) * vy) / vv;
    if (t < 0.0) {
      t = 0.0;
    } else if (t > 1.0) {
      t = 1.0;
    }
  }
  final cx = x1 + vx * t;
  final cy = y1 + vy * t;
  final dx = px - cx;
  final dy = py - cy;
  return dx * dx + dy * dy;
}

bool _isInsideIndexed(
  double px,
  double py,
  List<_PolyEdge> edges,
  List<int> edgeIndices,
  int windingRule,
) {
  int winding = 0;
  int crossings = 0;
  for (int i = 0; i < edgeIndices.length; i++) {
    final e = edges[edgeIndices[i]];
    final bool upward = e.y1 <= py && e.y2 > py;
    final bool downward = e.y1 > py && e.y2 <= py;
    if (!(upward || downward)) continue;
    final cross = (e.x2 - e.x1) * (py - e.y1) - (px - e.x1) * (e.y2 - e.y1);
    if (cross > 0 && upward) {
      winding += e.winding;
      crossings++;
    } else if (cross < 0 && downward) {
      winding += e.winding;
      crossings++;
    }
  }
  if (windingRule == 0) return (crossings & 1) != 0;
  return winding != 0;
}

List<List<int>> _buildRowBuckets(List<_PolyEdge> edges, int y0, int y1) {
  final rows = y1 - y0 + 1;
  final buckets = List<List<int>>.generate(rows, (_) => <int>[]);
  for (int i = 0; i < edges.length; i++) {
    final e = edges[i];
    final minY = math.min(e.y1, e.y2);
    final maxY = math.max(e.y1, e.y2);
    final r0 = (minY.floor() - 1).clamp(y0, y1);
    final r1 = (maxY.ceil() + 1).clamp(y0, y1);
    for (int y = r0; y <= r1; y++) {
      buckets[y - y0].add(i);
    }
  }
  return buckets;
}

int _ceilLog2(int v) {
  if (v <= 1) return 0;
  int p = 0;
  int x = 1;
  while (x < v) {
    x <<= 1;
    p++;
  }
  return p;
}
