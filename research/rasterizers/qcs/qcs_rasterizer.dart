/// ============================================================================
/// QCS — Quantized Coverage Signature Rasterization
/// ============================================================================
///
/// A filosofia central é converter o problema geométrico complexo de cálculo
/// de área (que usa muito ponto flutuante e é lento) em um problema de BUSCA
/// EM TABELAS e OPERAÇÕES DE BITS.
///
/// PRINCÍPIO CENTRAL:
///   Em vez de calcular a área exata, QUANTIZAMOS a cobertura. Imagine que
///   cada pixel é dividido em uma micro-grade de pontos de amostragem.
///   Para rasterização de subpixel em layout RGB horizontal, usamos uma
///   grade de 3×2 (6 pontos) dentro de cada pixel.
///
///   Para cada ponto de amostragem, perguntamos: "está dentro ou fora?"
///   A resposta é uma sequência de 6 bits (a "Assinatura de Cobertura")
///   que indexa diretamente uma LUT pré-computada.
///
/// INOVAÇÃO:
///   - Elimina ponto flutuante no loop interno: tudo é int + bitwise
///   - Conversão de Geometria em Busca O(1)
///   - Minimal footprint por pixel: algumas somas e uma indexação
///   - Adaptável: grade 3×1 (mais rápida), 3×3 (mais qualidade)
///
library qcs;

import 'dart:typed_data';

// ─────────────────────────────────────────────────────────────────────────────
// CONSTANTES DE AMOSTRAGEM
// ─────────────────────────────────────────────────────────────────────────────

/// Layout de amostragem 3×2:
/// | R | G | B | <- subpixels
/// | • | • | • | <- pontos superiores (s0, s1, s2)
/// | • | • | • | <- pontos inferiores (s3, s4, s5)
///
/// Total: 6 pontos = 6 bits = 64 assinaturas possíveis

/// Offsets horizontais dos pontos de amostragem (em fração do pixel)
const List<double> _sampleOffsetsX = [
  1.0 / 6.0,
  3.0 / 6.0,
  5.0 / 6.0, // Linha superior (R, G, B)
  1.0 / 6.0,
  3.0 / 6.0,
  5.0 / 6.0, // Linha inferior
];

// ─────────────────────────────────────────────────────────────────────────────
// LOOK-UP TABLE DE SUBPIXEL
// ─────────────────────────────────────────────────────────────────────────────

/// LUT que mapeia assinatura de 6 bits para intensidades RGB
class SubpixelLUT {
  /// 64 entradas, cada uma com 3 valores (R, G, B)
  final Uint8List _table;

  SubpixelLUT() : _table = Uint8List(64 * 3) {
    _precompute();
  }

  void _precompute() {
    for (int signature = 0; signature < 64; signature++) {
      // Bits: s0 s1 s2 s3 s4 s5
      // s0, s3 → Red   (2 amostras)
      // s1, s4 → Green (2 amostras)
      // s2, s5 → Blue  (2 amostras)

      final s0 = (signature >> 0) & 1; // Red superior
      final s1 = (signature >> 1) & 1; // Green superior
      final s2 = (signature >> 2) & 1; // Blue superior
      final s3 = (signature >> 3) & 1; // Red inferior
      final s4 = (signature >> 4) & 1; // Green inferior
      final s5 = (signature >> 5) & 1; // Blue inferior

      // Cobertura de cada canal (0, 0.5, ou 1.0 → 0, 127, 255)
      final coverageR = ((s0 + s3) * 255) ~/ 2;
      final coverageG = ((s1 + s4) * 255) ~/ 2;
      final coverageB = ((s2 + s5) * 255) ~/ 2;

      _table[signature * 3 + 0] = coverageR;
      _table[signature * 3 + 1] = coverageG;
      _table[signature * 3 + 2] = coverageB;
    }
  }

  /// Obtém as intensidades RGB para uma assinatura
  void getIntensities(int signature, List<int> outRGB) {
    outRGB[0] = _table[signature * 3 + 0];
    outRGB[1] = _table[signature * 3 + 1];
    outRGB[2] = _table[signature * 3 + 2];
  }

  int getR(int signature) => _table[signature * 3 + 0];
  int getG(int signature) => _table[signature * 3 + 1];
  int getB(int signature) => _table[signature * 3 + 2];
}

// Scanline-based approach for non-convex support

// ─────────────────────────────────────────────────────────────────────────────
// RASTERIZADOR QCS
// ─────────────────────────────────────────────────────────────────────────────

class QCSRasterizer {
  final int width;
  final int height;

  /// Buffer de subpixels RGB
  late final Uint8List _subpixelBuffer;

  /// Buffer de pixels para exportação
  late final Uint32List _pixelBuffer;

  /// LUT de subpixel
  final SubpixelLUT _lut;

  /// Buffer de assinaturas por scanline (auxiliar de integração)
  late final Uint8List _signatureScanline;
  late final Int32List _wTopR, _wTopG, _wTopB, _wBotR, _wBotG, _wBotB;

  QCSRasterizer({required this.width, required this.height})
      : _lut = SubpixelLUT() {
    _subpixelBuffer = Uint8List(width * height * 3);
    _pixelBuffer = Uint32List(width * height);
    _signatureScanline = Uint8List(width + 1);
    _wTopR = Int32List(width + 1);
    _wTopG = Int32List(width + 1);
    _wTopB = Int32List(width + 1);
    _wBotR = Int32List(width + 1);
    _wBotG = Int32List(width + 1);
    _wBotB = Int32List(width + 1);
  }

  void clear([int backgroundColor = 0xFFFFFFFF]) {
    final r = (backgroundColor >> 16) & 0xFF;
    final g = (backgroundColor >> 8) & 0xFF;
    final b = backgroundColor & 0xFF;

    for (int i = 0; i < width * height; i++) {
      _subpixelBuffer[i * 3 + 0] = r;
      _subpixelBuffer[i * 3 + 1] = g;
      _subpixelBuffer[i * 3 + 2] = b;
    }
  }

  void drawPolygon(
    List<double> vertices,
    int color, {
    int windingRule = 1,
    List<int>? contourVertexCounts,
  }) {
    if (vertices.length < 6) return;
    final n = vertices.length ~/ 2;
    final contours = _resolveContours(n, contourVertexCounts);

    // 1. Pré-processamento de Arestas
    final edges = <_QcsEdge>[];
    double minY = double.infinity, maxY = double.negativeInfinity;

    for (final contour in contours) {
      if (contour.count < 2) continue;
      for (int local = 0; local < contour.count; local++) {
        final i = contour.start + local;
        final j = contour.start + ((local + 1) % contour.count);
        final x0 = vertices[i * 2], y0 = vertices[i * 2 + 1];
        final x1 = vertices[j * 2], y1 = vertices[j * 2 + 1];

        if (y0 < minY) minY = y0;
        if (y0 > maxY) maxY = y0;
        if (y1 < minY) minY = y1;
        if (y1 > maxY) maxY = y1;
        if (y0 == y1) continue;

        final windingDelta = (y1 > y0) ? 1 : -1;
        edges.add(_QcsEdge(x0, y0, x1, y1, windingDelta));
      }
    }

    final pxMinY = minY.floor().clamp(0, height - 1);
    final pxMaxY = maxY.ceil().clamp(0, height - 1);

    final colorR = (color >> 16) & 0xFF;
    final colorG = (color >> 8) & 0xFF;
    final colorB = color & 0xFF;

    // 2. Loop de Scanlines
    for (int py = pxMinY; py <= pxMaxY; py++) {
      _signatureScanline.fillRange(0, _signatureScanline.length, 0);
      if (windingRule != 0) {
        _wTopR.fillRange(0, _wTopR.length, 0);
        _wTopG.fillRange(0, _wTopG.length, 0);
        _wTopB.fillRange(0, _wTopB.length, 0);
        _wBotR.fillRange(0, _wBotR.length, 0);
        _wBotG.fillRange(0, _wBotG.length, 0);
        _wBotB.fillRange(0, _wBotB.length, 0);
      }

      // Y dos centros das duas sub-scanlines QCS
      final yTop = py + 0.25;
      final yBot = py + 0.75;

      // 3. Fase de Toggle / Winding por subamostra
      for (final edge in edges) {
        // Interseção na sub-scanline Superior
        if ((edge.y0 <= yTop && edge.y1 > yTop) ||
            (edge.y1 <= yTop && edge.y0 > yTop)) {
          final x = edge.x0 +
              (yTop - edge.y0) * (edge.x1 - edge.x0) / (edge.y1 - edge.y0);
          for (int s = 0; s < 3; s++) {
            final ix = (x - _sampleOffsetsX[s]).floor();
            if (ix >= -1 && ix < width) {
              if (windingRule == 0) {
                _signatureScanline[ix + 1] ^= (1 << s);
              } else {
                if (s == 0) _wTopR[ix + 1] += edge.windingDelta;
                if (s == 1) _wTopG[ix + 1] += edge.windingDelta;
                if (s == 2) _wTopB[ix + 1] += edge.windingDelta;
              }
            }
          }
        }
        // Interseção na sub-scanline Inferior
        if ((edge.y0 <= yBot && edge.y1 > yBot) ||
            (edge.y1 <= yBot && edge.y0 > yBot)) {
          final x = edge.x0 +
              (yBot - edge.y0) * (edge.x1 - edge.x0) / (edge.y1 - edge.y0);
          for (int s = 3; s < 6; s++) {
            final ix = (x - _sampleOffsetsX[s]).floor();
            if (ix >= -1 && ix < width) {
              if (windingRule == 0) {
                _signatureScanline[ix + 1] ^= (1 << s);
              } else {
                if (s == 3) _wBotR[ix + 1] += edge.windingDelta;
                if (s == 4) _wBotG[ix + 1] += edge.windingDelta;
                if (s == 5) _wBotB[ix + 1] += edge.windingDelta;
              }
            }
          }
        }
      }

      // 4. Integração de Bits (Prefix XOR horizontal) + Blit
      int runningSignature = 0;
      int runTopR = 0,
          runTopG = 0,
          runTopB = 0,
          runBotR = 0,
          runBotG = 0,
          runBotB = 0;
      final rowOffset = py * width * 3;

      for (int px = 0; px < width; px++) {
        if (windingRule == 0) {
          runningSignature ^= _signatureScanline[px];
        } else {
          runTopR += _wTopR[px];
          runTopG += _wTopG[px];
          runTopB += _wTopB[px];
          runBotR += _wBotR[px];
          runBotG += _wBotG[px];
          runBotB += _wBotB[px];

          runningSignature = 0;
          if (runTopR != 0) runningSignature |= (1 << 0);
          if (runTopG != 0) runningSignature |= (1 << 1);
          if (runTopB != 0) runningSignature |= (1 << 2);
          if (runBotR != 0) runningSignature |= (1 << 3);
          if (runBotG != 0) runningSignature |= (1 << 4);
          if (runBotB != 0) runningSignature |= (1 << 5);
        }

        if (runningSignature == 0) continue;

        // Recupera intensidade da LUT O(1)
        final intensityR = _lut.getR(runningSignature);
        final intensityG = _lut.getG(runningSignature);
        final intensityB = _lut.getB(runningSignature);

        final idx = rowOffset + px * 3;

        if (runningSignature == 63) {
          // 100% Cobertura
          _subpixelBuffer[idx + 0] = colorR;
          _subpixelBuffer[idx + 1] = colorG;
          _subpixelBuffer[idx + 2] = colorB;
        } else {
          // Blend Subpixel Oritentado
          final bgR = _subpixelBuffer[idx + 0];
          final bgG = _subpixelBuffer[idx + 1];
          final bgB = _subpixelBuffer[idx + 2];

          _subpixelBuffer[idx + 0] =
              ((colorR * intensityR + bgR * (255 - intensityR)) >> 8)
                  .clamp(0, 255);
          _subpixelBuffer[idx + 1] =
              ((colorG * intensityG + bgG * (255 - intensityG)) >> 8)
                  .clamp(0, 255);
          _subpixelBuffer[idx + 2] =
              ((colorB * intensityB + bgB * (255 - intensityB)) >> 8)
                  .clamp(0, 255);
        }
      }
    }
  }

  /// Resolve buffer de subpixels para buffer ARGB
  void resolve() {
    for (int i = 0; i < width * height; i++) {
      final r = _subpixelBuffer[i * 3 + 0];
      final g = _subpixelBuffer[i * 3 + 1];
      final b = _subpixelBuffer[i * 3 + 2];
      _pixelBuffer[i] = 0xFF000000 | (r << 16) | (g << 8) | b;
    }
  }

  Uint32List get pixels {
    resolve();
    return _pixelBuffer;
  }

  Uint8List get subpixels => _subpixelBuffer;
}

class _QcsEdge {
  final double x0, y0, x1, y1;
  final int windingDelta;
  _QcsEdge(this.x0, this.y0, this.x1, this.y1, this.windingDelta);
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
