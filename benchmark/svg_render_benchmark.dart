/// =============================================================================
/// SVG RENDERING BENCHMARK
/// =============================================================================
///
/// Renderiza arquivos SVG reais com todos os rasterizadores disponíveis,
/// gerando PNGs para inspeção visual.
///
/// Uso:
///   dart run benchmark/svg_render_benchmark.dart
///

library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../research/png/png_writer.dart';
import '../research/rasterizers/rasterizers.dart';
import '../research/svg/svg_parser.dart';

import '../research/rasterizers/blend2d/blend2d_rasterizer2.dart' as b2d2;

const outputDir = 'output/svg_renders';

const svgFiles = <String>[
  'assets/svg/Ghostscript_Tiger.svg',
  'assets/svg/froggy-simple.svg',
];

const renderWidth = 512;
const renderHeight = 512;
const enableBlend2Dv1 = false;

class PreparedPolygon {
  final List<double> vertices;
  final int color;
  final int windingRule; // 0: EvenOdd, 1: NonZero (matching MarlinConst)
  final List<int>? contourVertexCounts; // Path subpaths; null = single contour

  const PreparedPolygon(
    this.vertices,
    this.color,
    this.windingRule, {
    this.contourVertexCounts,
  });
}

class _ContourSpan {
  final int start;
  final int count;

  const _ContourSpan(this.start, this.count);
}

abstract class RasterizerAdapter {
  String get name;

  Future<Uint8List> render(List<PreparedPolygon> polygons);
}

class FunctionAdapter implements RasterizerAdapter {
  @override
  final String name;

  final Future<Uint8List> Function(List<PreparedPolygon> polygons) _render;

  FunctionAdapter(this.name, this._render);

  @override
  Future<Uint8List> render(List<PreparedPolygon> polygons) => _render(polygons);
}

List<PreparedPolygon> _preparePolygons(
  List<SvgPolygon> polygons,
  double svgWidth,
  double svgHeight,
) {
  final safeW = svgWidth <= 0 ? 1.0 : svgWidth;
  final safeH = svgHeight <= 0 ? 1.0 : svgHeight;
  final scaleX = renderWidth / safeW;
  final scaleY = renderHeight / safeH;

  final prepared = <PreparedPolygon>[];
  for (final poly in polygons) {
    if (poly.vertices.length < 6) continue;
    final scaled = _scaleVertices(poly.vertices, scaleX, scaleY);
    final windingRule = poly.evenOdd ? 0 : 1;

    final fillColor = poly.fillColor;
    if (((fillColor >> 24) & 0xFF) != 0) {
      prepared.add(PreparedPolygon(
        scaled,
        fillColor,
        windingRule,
        contourVertexCounts: poly.contourVertexCounts,
      ));
    }

    final strokeAlpha = (poly.strokeColor >> 24) & 0xFF;
    if (strokeAlpha != 0 && poly.strokeWidth > 0.0) {
      final strokePx = poly.strokeWidth * ((scaleX.abs() + scaleY.abs()) * 0.5);
      if (strokePx > 0.0) {
        _appendStrokePolygons(
          prepared: prepared,
          vertices: scaled,
          contourVertexCounts: poly.contourVertexCounts,
          strokeColor: poly.strokeColor,
          strokeWidthPx: strokePx,
        );
      }
    }
  }
  return prepared;
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

void _appendStrokePolygons({
  required List<PreparedPolygon> prepared,
  required List<double> vertices,
  required List<int>? contourVertexCounts,
  required int strokeColor,
  required double strokeWidthPx,
}) {
  if (strokeWidthPx <= 0.0) return;
  const double eps = 1e-6;
  final double halfWidth = strokeWidthPx * 0.5;
  final double joinOverlap = halfWidth * 0.8;

  final int pointCount = vertices.length ~/ 2;
  final contours = _resolveContours(pointCount, contourVertexCounts);

  for (final contour in contours) {
    if (contour.count < 2) continue;

    final int first = contour.start;
    final int last = contour.start + contour.count - 1;
    final double fx = vertices[first * 2];
    final double fy = vertices[first * 2 + 1];
    final double lx = vertices[last * 2];
    final double ly = vertices[last * 2 + 1];
    final bool closed = ((fx - lx) * (fx - lx) + (fy - ly) * (fy - ly)) <= eps;

    final int segCount = closed ? contour.count : (contour.count - 1);
    for (int i = 0; i < segCount; i++) {
      final int p0 = contour.start + i;
      final int p1 = contour.start + ((i + 1) % contour.count);

      final double x0 = vertices[p0 * 2];
      final double y0 = vertices[p0 * 2 + 1];
      final double x1 = vertices[p1 * 2];
      final double y1 = vertices[p1 * 2 + 1];

      double dx = x1 - x0;
      double dy = y1 - y0;
      final double len2 = dx * dx + dy * dy;
      if (len2 <= eps) continue;
      final double invLen = 1.0 / math.sqrt(len2);
      dx *= invLen;
      dy *= invLen;

      double sx = x0;
      double sy = y0;
      double ex = x1;
      double ey = y1;

      if (closed || i > 0) {
        sx -= dx * joinOverlap;
        sy -= dy * joinOverlap;
      }
      if (closed || i < segCount - 1) {
        ex += dx * joinOverlap;
        ey += dy * joinOverlap;
      }

      final double nx = -dy * halfWidth;
      final double ny = dx * halfWidth;

      prepared.add(PreparedPolygon(
        <double>[
          sx + nx,
          sy + ny,
          ex + nx,
          ey + ny,
          ex - nx,
          ey - ny,
          sx - nx,
          sy - ny,
        ],
        strokeColor,
        1,
        contourVertexCounts: const <int>[4],
      ));
    }
  }
}

List<double> _scaleVertices(
  List<double> vertices,
  double scaleX,
  double scaleY,
) {
  final out = List<double>.filled(vertices.length, 0.0, growable: false);
  for (int i = 0; i < vertices.length; i += 2) {
    out[i] = vertices[i] * scaleX;
    out[i + 1] = vertices[i + 1] * scaleY;
  }
  return out;
}

Uint8List _uint32ToRGBA(Uint32List argbData) {
  final rgba = Uint8List(argbData.length * 4);
  for (int i = 0; i < argbData.length; i++) {
    final pixel = argbData[i];
    rgba[i * 4] = (pixel >> 16) & 0xFF;
    rgba[i * 4 + 1] = (pixel >> 8) & 0xFF;
    rgba[i * 4 + 2] = pixel & 0xFF;
    rgba[i * 4 + 3] = (pixel >> 24) & 0xFF;
  }
  return rgba;
}

String _slugify(String name) {
  final sb = StringBuffer();
  for (int i = 0; i < name.length; i++) {
    final code = name.codeUnitAt(i);
    final isAlphaNum = (code >= 48 && code <= 57) ||
        (code >= 65 && code <= 90) ||
        (code >= 97 && code <= 122);
    sb.write(isAlphaNum ? String.fromCharCode(code) : '_');
  }
  return sb.toString().replaceAll(RegExp('_+'), '_').toLowerCase();
}

List<Vec2> _toNormalizedVec2(List<double> verticesPx) {
  final out = <Vec2>[];
  final invW = 1.0 / renderWidth;
  final invH = 1.0 / renderHeight;

  for (int i = 0; i < verticesPx.length; i += 2) {
    out.add(Vec2(verticesPx[i] * invW, verticesPx[i + 1] * invH));
  }
  return out;
}

// ignore: unused_element
void _blendCoverageInto(Uint32List dst, Float64List coverage, int color) {
  final srcA = (color >> 24) & 0xFF;
  final srcR = (color >> 16) & 0xFF;
  final srcG = (color >> 8) & 0xFF;
  final srcB = color & 0xFF;

  for (int i = 0; i < coverage.length; i++) {
    final c = coverage[i];
    if (c <= 0.0) continue;

    final cov = c.clamp(0.0, 1.0);
    int alpha = (cov * srcA).round();
    if (alpha <= 0) continue;

    if (alpha >= 255) {
      dst[i] = 0xFF000000 | (srcR << 16) | (srcG << 8) | srcB;
      continue;
    }

    final bg = dst[i];
    final bgR = (bg >> 16) & 0xFF;
    final bgG = (bg >> 8) & 0xFF;
    final bgB = bg & 0xFF;
    final invA = 255 - alpha;

    final outR = (srcR * alpha + bgR * invA) >> 8;
    final outG = (srcG * alpha + bgG * invA) >> 8;
    final outB = (srcB * alpha + bgB * invA) >> 8;

    dst[i] = 0xFF000000 | (outR << 16) | (outG << 8) | outB;
  }
}

void _blendCoverageIntoBounds(
  Uint32List dst,
  Float64List coverage,
  int color,
  List<double> vertices,
) {
  if (vertices.length < 6) return;
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

  final int x0 = minX.floor().clamp(0, renderWidth - 1);
  final int y0 = minY.floor().clamp(0, renderHeight - 1);
  final int x1 = maxX.ceil().clamp(0, renderWidth - 1);
  final int y1 = maxY.ceil().clamp(0, renderHeight - 1);

  final srcA = (color >> 24) & 0xFF;
  final srcR = (color >> 16) & 0xFF;
  final srcG = (color >> 8) & 0xFF;
  final srcB = color & 0xFF;

  for (int y = y0; y <= y1; y++) {
    final row = y * renderWidth;
    for (int x = x0; x <= x1; x++) {
      final i = row + x;
      final c = coverage[i];
      if (c <= 0.0) continue;

      final cov = c.clamp(0.0, 1.0);
      int alpha = (cov * srcA).round();
      if (alpha <= 0) continue;
      if (alpha >= 255) {
        dst[i] = 0xFF000000 | (srcR << 16) | (srcG << 8) | srcB;
        continue;
      }

      final bg = dst[i];
      final bgR = (bg >> 16) & 0xFF;
      final bgG = (bg >> 8) & 0xFF;
      final bgB = bg & 0xFF;
      final invA = 255 - alpha;

      final outR = (srcR * alpha + bgR * invA) >> 8;
      final outG = (srcG * alpha + bgG * invA) >> 8;
      final outB = (srcB * alpha + bgB * invA) >> 8;
      dst[i] = 0xFF000000 | (outR << 16) | (outG << 8) | outB;
    }
  }
}

Future<void> _renderBlend2DV2BatchByColorRuns(
  b2d2.Blend2DRasterizer2 rasterizer,
  List<PreparedPolygon> polygons,
) async {
  int runColor = 0;
  int runWinding = 0;
  bool hasRun = false;

  for (final poly in polygons) {
    if (!hasRun) {
      runColor = poly.color;
      runWinding = poly.windingRule;
      hasRun = true;
      rasterizer.fillRule = runWinding;
      rasterizer.addPolygon(
        poly.vertices,
        contourVertexCounts: poly.contourVertexCounts,
      );
      continue;
    }

    if (poly.color == runColor && poly.windingRule == runWinding) {
      // Same batch state, accumulate
      rasterizer.addPolygon(
        poly.vertices,
        contourVertexCounts: poly.contourVertexCounts,
      );
      continue;
    }

    // Flush previous batch
    await rasterizer.flush(runColor);

    // Start new batch
    runColor = poly.color;
    runWinding = poly.windingRule;
    rasterizer.fillRule = runWinding;
    rasterizer.addPolygon(
      poly.vertices,
      contourVertexCounts: poly.contourVertexCounts,
    );
  }

  if (hasRun) {
    await rasterizer.flush(runColor);
  }
}

List<RasterizerAdapter> _buildAdapters() {
  return <RasterizerAdapter>[
    FunctionAdapter('ACDR', (polygons) async {
      final rasterizer = ACDRRasterizer(
          width: renderWidth,
          height: renderHeight,
          enableSubpixelY: false,
          enableSinglePixelSpanFix: false,
          enableVerticalSupersample: false);
      final out = Uint32List(renderWidth * renderHeight)
        ..fillRange(0, renderWidth * renderHeight, 0xFFFFFFFF);

      for (final poly in polygons) {
        rasterizer.clear();
        rasterizer.rasterize(
          _toNormalizedVec2(poly.vertices),
          windingRule: poly.windingRule,
          contourVertexCounts: poly.contourVertexCounts,
        );
        _blendCoverageIntoBounds(
            out, rasterizer.coverageBuffer, poly.color, poly.vertices);
      }

      return _uint32ToRGBA(out);
    }),
    // Arm do Marlin (OpenJDK, GPL) removido junto com o port. Veja NOTICE.
    FunctionAdapter('SCANLINE_EO', (polygons) async {
      final r = ScanlineRasterizer(width: renderWidth, height: renderHeight);
      r.clear(0xFFFFFFFF);

      for (final poly in polygons) {
        r.drawPolygon(
          poly.vertices,
          poly.color,
          windingRule: poly.windingRule,
          contourVertexCounts: poly.contourVertexCounts,
        );
      }

      return _uint32ToRGBA(r.buffer);
    }),
    FunctionAdapter('MSAA_4x4', (polygons) async {
      final r = MSAARasterizer(
        width: renderWidth,
        height: renderHeight,
        samplesPerAxis: 4,
        enableTileCulling: false,
      );
      r.clear(0xFFFFFFFF);

      for (final poly in polygons) {
        r.drawPolygon(
          poly.vertices,
          poly.color,
          windingRule: poly.windingRule,
          contourVertexCounts: poly.contourVertexCounts,
        );
      }

      return _uint32ToRGBA(r.buffer);
    }),
    FunctionAdapter('TESSELLATION', (polygons) async {
      final r = TessellationRasterizer(
        width: renderWidth,
        height: renderHeight,
      );
      r.clear(0xFFFFFFFF);

      for (final poly in polygons) {
        r.drawPolygon(
          poly.vertices,
          poly.color,
          windingRule: poly.windingRule,
          contourVertexCounts: poly.contourVertexCounts,
        );
      }

      return _uint32ToRGBA(r.buffer);
    }),
    /*
    FunctionAdapter('SSAA', (polygons) async {
      final r = SSAARasterizer(
        width: renderWidth,
        height: renderHeight,
        enableTileCulling: false,
      );
      r.clear(0xFFFFFFFF);

      for (final poly in polygons) {
        r.drawPolygon(
          poly.vertices,
          poly.color,
          windingRule: poly.windingRule,
          contourVertexCounts: poly.contourVertexCounts,
        );
      }

      return _uint32ToRGBA(r.buffer);
    }),
    */
    FunctionAdapter('WAVELET_HAAR', (polygons) async {
      final r = WaveletHaarRasterizer(width: renderWidth, height: renderHeight);
      r.clear(0xFFFFFFFF);

      for (final poly in polygons) {
        r.drawPolygon(poly.vertices, poly.color);
      }

      return _uint32ToRGBA(r.buffer);
    }),
    FunctionAdapter('DAA', (polygons) async {
      final r = DAARasterizer(width: renderWidth, height: renderHeight);
      r.clear(0xFFFFFFFF);

      for (final poly in polygons) {
        r.drawPolygon(
          poly.vertices,
          poly.color,
          windingRule: poly.windingRule,
          contourVertexCounts: poly.contourVertexCounts,
        );
      }

      return _uint32ToRGBA(r.framebuffer);
    }),
    FunctionAdapter('DDFI', (polygons) async {
      final r = FluxRenderer(renderWidth, renderHeight);
      r.clear(0xFFFFFFFF);

      for (final poly in polygons) {
        r.drawPolygon(poly.vertices, poly.color);
      }

      return _uint32ToRGBA(r.buffer);
    }),
    FunctionAdapter('DBSR', (polygons) async {
      final r = DBSRRasterizer(width: renderWidth, height: renderHeight);
      r.clear(0xFFFFFFFF);

      for (final poly in polygons) {
        r.drawPolygon(
          poly.vertices,
          poly.color,
          windingRule: poly.windingRule,
          contourVertexCounts: poly.contourVertexCounts,
        );
      }

      return _uint32ToRGBA(r.pixels);
    }),
    FunctionAdapter('EPL_AA', (polygons) async {
      final r = EPLRasterizer(width: renderWidth, height: renderHeight);
      r.clear(0xFFFFFFFF);

      for (final poly in polygons) {
        r.drawPolygon(
          poly.vertices,
          poly.color,
          windingRule: poly.windingRule,
          contourVertexCounts: poly.contourVertexCounts,
        );
      }

      return _uint32ToRGBA(r.buffer);
    }),
    FunctionAdapter('QCS', (polygons) async {
      final r = QCSRasterizer(width: renderWidth, height: renderHeight);
      r.clear(0xFFFFFFFF);

      for (final poly in polygons) {
        r.drawPolygon(poly.vertices, poly.color);
      }

      return _uint32ToRGBA(r.pixels);
    }),
    FunctionAdapter('RHBD', (polygons) async {
      final r = RHBDRasterizer(width: renderWidth, height: renderHeight);
      r.clear(0xFFFFFFFF);

      for (final poly in polygons) {
        r.drawPolygon(
          poly.vertices,
          poly.color,
          windingRule: poly.windingRule,
          contourVertexCounts: poly.contourVertexCounts,
        );
      }

      return _uint32ToRGBA(r.buffer);
    }),
    FunctionAdapter('AMCAD', (polygons) async {
      final r = AMCADRasterizer(width: renderWidth, height: renderHeight);
      r.clear(0xFFFFFFFF);

      for (final poly in polygons) {
        r.drawPolygon(
          poly.vertices,
          poly.color,
          windingRule: poly.windingRule,
          contourVertexCounts: poly.contourVertexCounts,
        );
      }

      return _uint32ToRGBA(r.buffer);
    }),
    FunctionAdapter('HSGR', (polygons) async {
      final r = HSGRRasterizer(width: renderWidth, height: renderHeight);
      r.clear(0xFFFFFFFF);

      for (final poly in polygons) {
        r.drawPolygon(
          poly.vertices,
          poly.color,
          windingRule: poly.windingRule,
          contourVertexCounts: poly.contourVertexCounts,
        );
      }

      return _uint32ToRGBA(r.buffer);
    }),
    FunctionAdapter('LNAF_SE (Fast)', (polygons) async {
      final r = LNAFSERasterizer(
        width: renderWidth,
        height: renderHeight,
        qualityMode: LnafSeQualityMode.fast,
      );
      r.clear(0xFFFFFFFF);

      for (final poly in polygons) {
        r.drawPolygon(
          poly.vertices,
          poly.color,
          windingRule: poly.windingRule,
          contourVertexCounts: poly.contourVertexCounts,
        );
      }

      return _uint32ToRGBA(r.buffer);
    }),
    FunctionAdapter('LNAF_SE (High)', (polygons) async {
      final r = LNAFSERasterizer(
        width: renderWidth,
        height: renderHeight,
        qualityMode: LnafSeQualityMode.high,
      );
      r.clear(0xFFFFFFFF);

      for (final poly in polygons) {
        r.drawPolygon(
          poly.vertices,
          poly.color,
          windingRule: poly.windingRule,
          contourVertexCounts: poly.contourVertexCounts,
        );
      }

      return _uint32ToRGBA(r.buffer);
    }),
    FunctionAdapter('LNAF_SE (Ultra)', (polygons) async {
      final r = LNAFSERasterizer(
        width: renderWidth,
        height: renderHeight,
        qualityMode: LnafSeQualityMode.ultra,
      );
      r.clear(0xFFFFFFFF);

      for (final poly in polygons) {
        r.drawPolygon(
          poly.vertices,
          poly.color,
          windingRule: poly.windingRule,
          contourVertexCounts: poly.contourVertexCounts,
        );
      }

      return _uint32ToRGBA(r.buffer);
    }),
    FunctionAdapter('LNAF_SE (Extreme)', (polygons) async {
      final r = LNAFSERasterizer(
        width: renderWidth,
        height: renderHeight,
        qualityMode: LnafSeQualityMode.extreme,
      );
      r.clear(0xFFFFFFFF);

      for (final poly in polygons) {
        r.drawPolygon(
          poly.vertices,
          poly.color,
          windingRule: poly.windingRule,
          contourVertexCounts: poly.contourVertexCounts,
        );
      }

      return _uint32ToRGBA(r.buffer);
    }),
    FunctionAdapter('LNAF_SE (Cinematic)', (polygons) async {
      final r = LNAFSERasterizer(
        width: renderWidth,
        height: renderHeight,
        qualityMode: LnafSeQualityMode.cinematic,
      );
      r.clear(0xFFFFFFFF);

      for (final poly in polygons) {
        r.drawPolygon(
          poly.vertices,
          poly.color,
          windingRule: poly.windingRule,
          contourVertexCounts: poly.contourVertexCounts,
        );
      }

      return _uint32ToRGBA(r.buffer);
    }),
    FunctionAdapter('LNAF_SE', (polygons) async {
      final r = LNAFSERasterizer(
        width: renderWidth,
        height: renderHeight,
        qualityMode: LnafSeQualityMode.fast,
      );
      r.clear(0xFFFFFFFF);

      for (final poly in polygons) {
        r.drawPolygon(
          poly.vertices,
          poly.color,
          windingRule: poly.windingRule,
          contourVertexCounts: poly.contourVertexCounts,
        );
      }

      return _uint32ToRGBA(r.buffer);
    }),
    FunctionAdapter('SWEEP_SDF', (polygons) async {
      final r = SweepSDFRasterizer(width: renderWidth, height: renderHeight);
      r.clear(0xFFFFFFFF);

      for (final poly in polygons) {
        r.drawPolygon(poly.vertices, poly.color);
      }

      return _uint32ToRGBA(r.pixels);
    }),
    FunctionAdapter('SCDT', (polygons) async {
      final r = SCDTRasterizer(width: renderWidth, height: renderHeight);
      r.clear(0xFFFFFFFF);

      for (final poly in polygons) {
        r.drawPolygon(poly.vertices, poly.color);
      }

      return _uint32ToRGBA(r.pixels);
    }),
    FunctionAdapter('SCP_AED', (polygons) async {
      final r = SCPAEDRasterizer(width: renderWidth, height: renderHeight);
      r.clear(0xFFFFFFFF);

      for (final poly in polygons) {
        r.drawPolygon(
          poly.vertices,
          poly.color,
          windingRule: poly.windingRule,
          contourVertexCounts: poly.contourVertexCounts,
        );
      }

      return _uint32ToRGBA(r.buffer);
    }),
    if (enableBlend2Dv1)
      FunctionAdapter('B2D_v1_Scalar', (polygons) async {
        final r = Blend2DRasterizer(
          renderWidth,
          renderHeight,
          config: const RasterizerConfig(useSimd: false, useIsolates: false),
        );
        r.clear(0xFFFFFFFF);

        for (final poly in polygons) {
          await r.drawPolygon(poly.vertices, poly.color,
              windingRule: poly.windingRule,
              contourVertexCounts: poly.contourVertexCounts);
        }

        return _uint32ToRGBA(r.buffer);
      }),
    if (enableBlend2Dv1)
      FunctionAdapter('B2D_v1_SIMD', (polygons) async {
        final r = Blend2DRasterizer(
          renderWidth,
          renderHeight,
          config: const RasterizerConfig(useSimd: true, useIsolates: false),
        );
        r.clear(0xFFFFFFFF);

        for (final poly in polygons) {
          await r.drawPolygon(poly.vertices, poly.color,
              windingRule: poly.windingRule,
              contourVertexCounts: poly.contourVertexCounts);
        }

        return _uint32ToRGBA(r.buffer);
      }),
    /*
    FunctionAdapter('B2D_v1_Scalar_Iso', (polygons) async {
      final r = Blend2DRasterizer(
        renderWidth,
        renderHeight,
        config: RasterizerConfig(
          useSimd: false,
          useIsolates: true,
          tileHeight: renderHeight ~/ 4,
        ),
      );
      r.clear(0xFFFFFFFF);

      for (final poly in polygons) {
        await r.drawPolygon(poly.vertices, poly.color);
      }

      return _uint32ToRGBA(r.buffer);
    }),
    FunctionAdapter('B2D_v1_SIMD_Iso', (polygons) async {
      final r = Blend2DRasterizer(
        renderWidth,
        renderHeight,
        config: RasterizerConfig(
          useSimd: true,
          useIsolates: true,
          tileHeight: renderHeight ~/ 4,
        ),
      );
      r.clear(0xFFFFFFFF);

      for (final poly in polygons) {
        await r.drawPolygon(poly.vertices, poly.color);
      }

      return _uint32ToRGBA(r.buffer);
    }),
    */
    FunctionAdapter('B2D_v2_Imm_Scalar', (polygons) async {
      final r = b2d2.Blend2DRasterizer2(
        renderWidth,
        renderHeight,
        config:
            const b2d2.RasterizerConfig2(useSimd: false, useIsolates: false),
      );
      try {
        r.clear(0xFFFFFFFF);
        for (final poly in polygons) {
          await r.drawPolygon(poly.vertices, poly.color,
              flushNow: true,
              windingRule: poly.windingRule,
              contourVertexCounts: poly.contourVertexCounts);
        }
        return _uint32ToRGBA(r.buffer);
      } finally {
        await r.dispose();
      }
    }),
    /*
    FunctionAdapter('B2D_v2_Imm_SIMD', (polygons) async {
      final r = b2d2.Blend2DRasterizer2(
        renderWidth,
        renderHeight,
        config: const b2d2.RasterizerConfig2(useSimd: true, useIsolates: false),
      );
      try {
        r.clear(0xFFFFFFFF);
        for (final poly in polygons) {
          await r.drawPolygon(poly.vertices, poly.color, flushNow: true);
        }
        return _uint32ToRGBA(r.buffer);
      } finally {
        await r.dispose();
      }
    }),
    */
    FunctionAdapter('B2D_v2_Batch_Scalar', (polygons) async {
      final r = b2d2.Blend2DRasterizer2(
        renderWidth,
        renderHeight,
        config:
            const b2d2.RasterizerConfig2(useSimd: false, useIsolates: false),
      );
      try {
        r.clear(0xFFFFFFFF);
        await _renderBlend2DV2BatchByColorRuns(r, polygons);
        return _uint32ToRGBA(r.buffer);
      } finally {
        await r.dispose();
      }
    }),
    FunctionAdapter('B2D_v2_Batch_SIMD', (polygons) async {
      final r = b2d2.Blend2DRasterizer2(
        renderWidth,
        renderHeight,
        config: const b2d2.RasterizerConfig2(useSimd: true, useIsolates: false),
      );
      try {
        r.clear(0xFFFFFFFF);
        await _renderBlend2DV2BatchByColorRuns(r, polygons);
        return _uint32ToRGBA(r.buffer);
      } finally {
        await r.dispose();
      }
    }),
    FunctionAdapter('B2D_v2_Batch_Scalar_Iso', (polygons) async {
      final r = b2d2.Blend2DRasterizer2(
        renderWidth,
        renderHeight,
        config: b2d2.RasterizerConfig2(
          useSimd: false,
          useIsolates: true,
          tileHeight: renderHeight ~/ 4,
          minParallelDirtyHeight: 1,
        ),
      );
      try {
        r.clear(0xFFFFFFFF);
        await _renderBlend2DV2BatchByColorRuns(r, polygons);
        return _uint32ToRGBA(r.buffer);
      } finally {
        await r.dispose();
      }
    }),
    FunctionAdapter('B2D_v2_Batch_SIMD_Iso', (polygons) async {
      final r = b2d2.Blend2DRasterizer2(
        renderWidth,
        renderHeight,
        config: b2d2.RasterizerConfig2(
          useSimd: true,
          useIsolates: true,
          tileHeight: renderHeight ~/ 4,
          minParallelDirtyHeight: 1,
        ),
      );
      try {
        r.clear(0xFFFFFFFF);
        await _renderBlend2DV2BatchByColorRuns(r, polygons);
        return _uint32ToRGBA(r.buffer);
      } finally {
        await r.dispose();
      }
    }),
    FunctionAdapter('SKIA_Scalar', (polygons) async {
      final r = SkiaRasterizer(
          width: renderWidth, height: renderHeight, useSimd: false);
      r.clear(0xFFFFFFFF);

      for (final poly in polygons) {
        r.drawPolygon(
          poly.vertices,
          poly.color,
          windingRule: poly.windingRule,
          contourVertexCounts: poly.contourVertexCounts,
        );
      }

      return _uint32ToRGBA(r.buffer);
    }),
    FunctionAdapter('SKIA_SIMD', (polygons) async {
      final r = SkiaRasterizer(
          width: renderWidth, height: renderHeight, useSimd: true);
      r.clear(0xFFFFFFFF);

      for (final poly in polygons) {
        r.drawPolygon(
          poly.vertices,
          poly.color,
          windingRule: poly.windingRule,
          contourVertexCounts: poly.contourVertexCounts,
        );
      }

      return _uint32ToRGBA(r.buffer);
    }),
    FunctionAdapter('EDGE_FLAG_AA', (polygons) async {
      final r = EdgeFlagAARasterizer(width: renderWidth, height: renderHeight);
      r.clear(0xFFFFFFFF);

      for (final poly in polygons) {
        r.drawPolygon(
          poly.vertices,
          poly.color,
          windingRule: poly.windingRule,
          contourVertexCounts: poly.contourVertexCounts,
        );
      }

      return _uint32ToRGBA(r.buffer);
    }),
  ];
}

Future<void> main() async {
  print('╔══════════════════════════════════════════════════════════════════╗');
  print('║         SVG RENDERING BENCHMARK                                  ║');
  print('║         Renderiza SVGs reais com todos os rasterizadores         ║');
  print('╚══════════════════════════════════════════════════════════════════╝');
  print('');

  await Directory(outputDir).create(recursive: true);

  final parser = SvgParser();
  final adapters = _buildAdapters();

  print('Adapters: ${adapters.length}');

  for (final svgPath in svgFiles) {
    print('');
    print('═' * 70);
    print('Processing: $svgPath');
    print('═' * 70);

    final file = File(svgPath);
    if (!await file.exists()) {
      print('  File not found: $svgPath');
      continue;
    }

    final svgContent = await file.readAsString();
    late SvgDocument doc;

    try {
      doc = parser.parse(svgContent);
      print(
          '  SVG size: ${doc.width.toStringAsFixed(2)}x${doc.height.toStringAsFixed(2)}');
      print('  Polygons parsed: ${doc.polygons.length}');
    } catch (e) {
      print('  Failed to parse SVG: $e');
      continue;
    }

    final prepared = _preparePolygons(doc.polygons, doc.width, doc.height);
    if (prepared.isEmpty) {
      print('  No drawable polygons found in SVG');
      continue;
    }

    print('  Prepared polygons: ${prepared.length}');

    final baseName = svgPath.split('/').last.replaceAll('.svg', '');

    for (final adapter in adapters) {
      print('');
      print('  Rendering with ${adapter.name}...');

      try {
        final stopwatch = Stopwatch()..start();
        final pixels = await adapter.render(prepared);
        stopwatch.stop();

        final outputPath =
            '$outputDir/${baseName}_${_slugify(adapter.name)}.png';
        await PngWriter.saveRgba(outputPath, pixels, renderWidth, renderHeight);

        print('    ✓ Saved: $outputPath (${stopwatch.elapsedMilliseconds}ms)');
      } catch (e, st) {
        print('    ✗ Failed: $e');
        print('      $st');
      }
    }
  }

  print('');
  print('═' * 70);
  print('Done! Check $outputDir for output files.');
  print('═' * 70);
}
