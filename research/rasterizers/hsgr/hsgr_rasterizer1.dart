/// ============================================================================
/// HSGR — Hilbert-Space Guided Rasterization
/// ============================================================================
/// esta verção não esta renderizando poligonos difernte de triangulos
/// Usa curvas de preenchimento de espaço (Hilbert) para traversar pixels
/// de forma a maximizar localidade de cache.
///
/// PRINCÍPIO CENTRAL:
///   Métodos clássicos varrem pixels em ordem row-major (linhas sequenciais),
///   o que causa cache misses frequentes em bounding boxes irregulares.
///
///   A curva de Hilbert mapeia um espaço 1D contínuo para 2D, preservando
///   vizinhança: pixels adjacentes na curva são adjacentes no espaço.
///
/// INOVAÇÃO:
///   - Traversal Não-Linear com Preservação de Localidade
///   - Atualizações incrementais nas funções de borda
///   - Cobertura Racional Otimizada (nova formulação)
///   - Combinação de teoria de curvas fractais com rasterização incremental
///
library hsgr;

import 'dart:typed_data';
import 'dart:math' as math;

// ─────────────────────────────────────────────────────────────────────────────
// GERAÇÃO DE CURVA DE HILBERT
// ─────────────────────────────────────────────────────────────────────────────

/// Gera coordenadas 2D a partir de índice 1D na curva de Hilbert
/// Algoritmo de decodificação via operações bit-a-bit (O(log N) por ponto)
class HilbertCurve {
  final int order; // Ordem da curva (tamanho = 2^order × 2^order)
  final int size; // 2^order

  HilbertCurve(this.order) : size = 1 << order;

  /// Converte índice D (distância ao longo da curva) para coordenadas (x, y)
  List<int> dToXY(int d) {
    int x = 0, y = 0;
    int rx, ry;
    int s = 1;
    int t = d;

    while (s < size) {
      rx = (t & 2) >> 1;
      ry = (t & 1) ^ rx;

      // Rotação
      if (ry == 0) {
        if (rx == 1) {
          x = s - 1 - x;
          y = s - 1 - y;
        }
        // Swap x e y
        final temp = x;
        x = y;
        y = temp;
      }

      x += (rx == 1 ? s : 0);
      y += (ry == 1 ? s : 0);

      s <<= 1;
      t >>= 2;
    }

    return [x, y];
  }

  /// Gera todos os pontos na ordem da curva de Hilbert dentro de uma região
  Iterable<List<int>> generatePoints(
      int minX, int minY, int maxX, int maxY) sync* {
    final totalPoints = size * size;

    for (int d = 0; d < totalPoints; d++) {
      final coords = dToXY(d);
      final x = coords[0];
      final y = coords[1];

      if (x >= minX && x <= maxX && y >= minY && y <= maxY) {
        yield coords;
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// FUNÇÃO DE BORDA INCREMENTAL
// ─────────────────────────────────────────────────────────────────────────────

/// Função de borda para teste de inclusão de triângulo
class EdgeFunction {
  final double a, b, c; // Coeficientes: ax + by + c = 0

  /// Deltas para incremento em cada direção
  final double deltaX; // a
  final double deltaY; // b

  EdgeFunction({
    required this.a,
    required this.b,
    required this.c,
  })  : deltaX = a,
        deltaY = b;

  factory EdgeFunction.fromPoints(double x0, double y0, double x1, double y1) {
    // Equação da linha: (y1-y0)*(x-x0) - (x1-x0)*(y-y0) = 0
    // Simplifica para: dx*y - dy*x + (dy*x0 - dx*y0) = 0
    final dx = x1 - x0;
    final dy = y1 - y0;
    final a = dy;
    final b = -dx;
    final c = dx * y0 - dy * x0;

    return EdgeFunction(a: a, b: b, c: c);
  }

  /// Avalia a função de borda em um ponto
  double evaluate(double x, double y) => a * x + b * y + c;

  /// Comprimento da normal (para normalização de distância)
  double get normalLength => math.sqrt(a * a + b * b);
}

// ─────────────────────────────────────────────────────────────────────────────
// COBERTURA RACIONAL COMPOSTA (NOVA FORMULAÇÃO)
// ─────────────────────────────────────────────────────────────────────────────

/// Calcula cobertura usando produto de funções racionais.
///
/// Para cada aresta i:
///   weight_i = 1 / (1 + (k * |d_i|)^m)
///
/// Cobertura final = Π weight_i
///
/// Isso é diferente de min(d) + smoothstep:
///   - Combina probabilidades "suavizadas" por aresta
///   - Mais rápida (usa mul/add, evita min/max)
///   - Melhor em bordas diagonais
double computeRationalCoverage(List<double> signedDistances,
    {double k = 2.0, double m = 2.0}) {
  double coverage = 1.0;

  for (final d in signedDistances) {
    // Clamp distância para evitar overflow
    final absD = d.abs().clamp(0.0, 10.0);

    // Função racional: 1 / (1 + (k*d)^m)
    final kd = k * absD;
    final kdm = math.pow(kd, m);
    final weight = 1.0 / (1.0 + kdm);

    coverage *= weight;
  }

  return coverage;
}

// ─────────────────────────────────────────────────────────────────────────────
// RASTERIZADOR HSGR
// ─────────────────────────────────────────────────────────────────────────────

class HSGRRasterizer {
  final int width;
  final int height;

  /// Buffer de pixels
  late final Uint32List _buffer;

  HSGRRasterizer({required this.width, required this.height}) {
    _buffer = Uint32List(width * height);
  }

  void clear([int backgroundColor = 0xFF000000]) {
    _buffer.fillRange(0, _buffer.length, backgroundColor);
  }

  /// Desenha um triângulo usando traversal Hilbert
  void drawTriangle(
    double x1,
    double y1,
    double x2,
    double y2,
    double x3,
    double y3,
    int color,
  ) {
    // Bounding box
    final minX = math.min(x1, math.min(x2, x3)).floor().clamp(0, width - 1);
    final maxX = math.max(x1, math.max(x2, x3)).ceil().clamp(0, width - 1);
    final minY = math.min(y1, math.min(y2, y3)).floor().clamp(0, height - 1);
    final maxY = math.max(y1, math.max(y2, y3)).ceil().clamp(0, height - 1);

    // Calcular ordem da curva de Hilbert
    final bboxWidth = maxX - minX + 1;
    final bboxHeight = maxY - minY + 1;
    final bboxSize = math.max(bboxWidth, bboxHeight);

    // Próxima potência de 2
    final order = (math.log(bboxSize) / math.log(2)).ceil().clamp(1, 10);

    // Criar curva de Hilbert
    final hilbert = HilbertCurve(order);

    // Criar funções de borda
    final edges = [
      EdgeFunction.fromPoints(x1, y1, x2, y2),
      EdgeFunction.fromPoints(x2, y2, x3, y3),
      EdgeFunction.fromPoints(x3, y3, x1, y1),
    ];

    // Pré-computar comprimentos normais para distância normalizada
    final normalLengths = edges.map((e) => e.normalLength).toList();

    // Estado incremental
    var prevX = -1, prevY = -1;
    final edgeValues = [0.0, 0.0, 0.0];

    // Traversar em ordem Hilbert
    for (final coords
        in hilbert.generatePoints(0, 0, hilbert.size - 1, hilbert.size - 1)) {
      final localX = coords[0];
      final localY = coords[1];

      // Mapear para coordenadas globais
      final globalX = minX + localX;
      final globalY = minY + localY;

      // Skip se fora do bounding box
      if (globalX > maxX || globalY > maxY) continue;

      // Centro do pixel
      final px = globalX + 0.5;
      final py = globalY + 0.5;

      // ─── ATUALIZAÇÃO INCREMENTAL ────────────────────────────────────
      if (prevX >= 0) {
        final dx = globalX - prevX;
        final dy = globalY - prevY;

        for (int e = 0; e < 3; e++) {
          edgeValues[e] += edges[e].deltaX * dx + edges[e].deltaY * dy;
        }
      } else {
        // Primeira avaliação
        for (int e = 0; e < 3; e++) {
          edgeValues[e] = edges[e].evaluate(px, py);
        }
      }

      prevX = globalX;
      prevY = globalY;

      // ─── TESTE DE INCLUSÃO ─────────────────────────────────────────
      // Verificar se está completamente dentro
      bool allPositive = true;
      for (final v in edgeValues) {
        if (v < 0) {
          allPositive = false;
          break;
        }
      }

      if (allPositive) {
        // Pixel completamente dentro
        _buffer[globalY * width + globalX] = color;
      } else {
        // Verificar se está na borda (possível AA)
        bool anyClose = false;
        final signedDistances = <double>[];

        for (int e = 0; e < 3; e++) {
          final dist = edgeValues[e] / normalLengths[e];
          signedDistances.add(dist);
          if (dist.abs() < 1.5) anyClose = true;
        }

        if (anyClose) {
          // Calcular cobertura racional
          final coverage = computeRationalCoverage(signedDistances);

          if (coverage > 0.01) {
            _blendPixel(globalX, globalY, color, (coverage * 255).toInt());
          }
        }
      }
    }
  }

  /// Blend de pixel
  void _blendPixel(int x, int y, int foreground, int alpha) {
    final idx = y * width + x;

    if (alpha >= 255) {
      _buffer[idx] = foreground;
      return;
    }

    final bg = _buffer[idx];
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
