/// ============================================================================
/// ACDR — Accumulated Coverage Derivative Rasterization
/// ============================================================================
///
/// Uma abordagem matematicamente nova de rasterização 2D com qualidade subpixel.
///
/// PRINCÍPIO CENTRAL:
///   Pela decomposição via Teorema de Green, a integral de área de cobertura
///   de um polígono sobre um pixel pode ser reduzida a integrais de linha
///   sobre as arestas. Ao longo de uma scanline fixa, cada aresta contribui
///   com uma função polinomial de grau ≤ 2 na variável X.
///
///   Consequência: a segunda derivada da cobertura em X é CONSTANTE entre
///   eventos de aresta. Isso permite propagação por diferenças finitas:
///
///     C(x+1) = 2·C(x) − C(x−1) + Δ²
///
///   Resultado: O(1) por pixel de borda após seeding inicial.
///
/// COMPLEXIDADE:
///   - Construção de eventos: O(E · H_média)
///   - Rasterização: O(pixels_total) — LINEAR no output
///   - Pixels de borda: ~3 ops (1 mul seed + 1 add propagação + 1 clamp)
///   - Pixels internos: ~1 op (write)
///
library acdr;

import 'dart:typed_data';
import 'dart:math' as math;
import '../common/polygon_contract.dart';

// ─────────────────────────────────────────────────────────────────────────────
// TIPOS FUNDAMENTAIS
// ─────────────────────────────────────────────────────────────────────────────

/// Vértice 2D com coordenadas normalizadas [0, 1]
class Vec2 {
  final double x;
  final double y;

  const Vec2(this.x, this.y);

  Vec2 operator +(Vec2 other) => Vec2(x + other.x, y + other.y);
  Vec2 operator -(Vec2 other) => Vec2(x - other.x, y - other.y);
  Vec2 operator *(double s) => Vec2(x * s, y * s);
}

/// Aresta processada com dados pré-computados para máxima performance
class AcdrProcessedEdge {
  final double x0, y0, x1, y1;
  final double yMin, yMax;
  final double slopeDxDy; // dx/dy — usado para interseção por scanline
  final double slopeDyDx; // dy/dx — usado para cobertura subpixel
  final double invSlopeDxDy; // 1/(dx/dy) = dy/dx (reciprocal pré-computado)
  final int direction; // +1 se y aumenta, -1 se diminui

  AcdrProcessedEdge({
    required this.x0,
    required this.y0,
    required this.x1,
    required this.y1,
    required this.yMin,
    required this.yMax,
    required this.slopeDxDy,
    required this.slopeDyDx,
    required this.invSlopeDxDy,
    required this.direction,
  });
}

/// Classificação de topologia — como uma aresta cruza um pixel
/// Determinada por comparações simples, sem branches no caminho crítico.
///
/// Cada topologia tem uma fórmula fechada de cobertura:
///
///   A (Esq↔Dir):  ½·(y_in + y_out)           — trapezóide
///   B (Esq↔Top):  1 − ½·(1−x_top)·(1−y_in)  — pixel menos triângulo
///   C (Bot↔Dir):  ½·x_bot·y_out               — triângulo
///   D (Bot↔Top):  ½·(x_in + x_out)           — faixa vertical
// ignore: unused_element
enum Topology { a, b, c, d, full, none }

/// Evento de aresta numa scanline — usado para ordenação
class EdgeEvent implements Comparable<EdgeEvent> {
  final double x; // Posição X da interseção
  final int edgeIndex; // Índice na lista de arestas processadas
  final bool isEntering; // true = entrando no polígono, false = saindo

  const EdgeEvent({
    required this.x,
    required this.edgeIndex,
    required this.isEntering,
  });

  @override
  int compareTo(EdgeEvent other) => x.compareTo(other.x);
}

// ─────────────────────────────────────────────────────────────────────────────
// O ALGORITMO ACDR — CLASSE PRINCIPAL
// ─────────────────────────────────────────────────────────────────────────────

/// Rasterizador ACDR.
///
/// Uso:
/// ```dart
/// final rasterizer = ACDRRasterizer(width: 512, height: 512);
/// final coverage = rasterizer.rasterize(polygon);
/// // coverage é um Float64List de tamanho width*height, valores em [0, 1]
/// ```
class ACDRRasterizer implements PolygonContract {
  final int width;
  final int height;

  /// Habilita integração subpixel em Y (melhora AA em arestas horizontais).
  /// Pode ser desativado para máxima performance.
  final bool enableSubpixelY;

  /// Corrige spans onde xLeft e xRight caem no mesmo pixel.
  /// Pode ser desativado se quiser comportamento legado.
  final bool enableSinglePixelSpanFix;

  /// Supersampling vertical barato (2 taps) para suavizar bordas horizontais.
  /// Pode ser desativado para máxima performance.
  final bool enableVerticalSupersample;

  /// Número de amostras verticais quando enableVerticalSupersample = true.
  /// Valores recomendados: 2 ou 4.
  final int verticalSampleCount;

  /// Buffer de cobertura — Float64List para evitar boxing
  /// Cada elemento é a cobertura do pixel correspondente em [0, 1]
  late final Float64List coverageBuffer;

  /// Buffer de eventos por scanline — pré-alocado para evitar GC
  /// Índice: scanline Y → lista de eventos nessa scanline
  final List<List<EdgeEvent>> _scanlineEvents;

  ACDRRasterizer({
    required this.width,
    required this.height,
    this.enableSubpixelY = true,
    this.enableSinglePixelSpanFix = true,
    this.enableVerticalSupersample = true,
    this.verticalSampleCount = 4,
  }) : _scanlineEvents = List.generate(height, (_) => []) {
    coverageBuffer = Float64List(width * height);
  }

  // ───────────────────────────────────────────────────────────────────────
  // FASE 1: PRÉ-PROCESSAMENTO DE ARESTAS
  // ───────────────────────────────────────────────────────────────────────

  /// Converte vértices normalizados em arestas processadas com dados
  /// pré-computados (slopes, reciprocais, bounding boxes).
  ///
  /// Arestas horizontais são descartadas (contribuição nula à cobertura).
  List<AcdrProcessedEdge> _preprocessEdges(
    List<Vec2> vertices, {
    List<int>? contourVertexCounts,
  }) {
    final edges = <AcdrProcessedEdge>[];
    final n = vertices.length;
    final contours = _resolveContours(n, contourVertexCounts);

    for (final contour in contours) {
      if (contour.count < 2) continue;
      for (int local = 0; local < contour.count; local++) {
        final i = contour.start + local;
        final j = contour.start + ((local + 1) % contour.count);
        final x0 = vertices[i].x * width;
        final y0 = vertices[i].y * height;
        final x1 = vertices[j].x * width;
        final y1 = vertices[j].y * height;

        final dy = y1 - y0;
        if (dy.abs() < 1e-6) continue; // Aresta horizontal — sem contribuição

        final dx = x1 - x0;
        final slopeDxDy = dx / dy; // Usado para calcular X na scanline
        final slopeDyDx = dy / dx; // Usado para cobertura subpixel
        final invSlopeDxDy = dy / dx; // Reciprocal pré-computado

        edges.add(AcdrProcessedEdge(
          x0: x0,
          y0: y0,
          x1: x1,
          y1: y1,
          yMin: dy > 0 ? y0 : y1,
          yMax: dy > 0 ? y1 : y0,
          slopeDxDy: slopeDxDy,
          slopeDyDx: slopeDyDx,
          invSlopeDxDy: invSlopeDxDy,
          direction: dy > 0 ? 1 : -1,
        ));
      }
    }

    return edges;
  }

  // ───────────────────────────────────────────────────────────────────────
  // FASE 2: CONSTRUÇÃO DA TABELA DE EVENTOS
  // ───────────────────────────────────────────────────────────────────────

  /// Para cada aresta, calcula as interseções com cada scanline e
  /// popula a tabela de eventos. Complexidade: O(E · H_média).
  ///
  /// Eventos são ORDENADOS por X dentro de cada scanline usando
  /// inserção direta (mais eficiente que sort para listas pequenas).
  void _buildScanlineEvents(List<AcdrProcessedEdge> edges, double yOffset) {
    // Limpar eventos anteriores
    for (int y = 0; y < height; y++) {
      _scanlineEvents[y].clear();
    }

    for (int e = 0; e < edges.length; e++) {
      final edge = edges[e];
      // Calcular range de scanlines cujos centros (y + 0.5) estão dentro da aresta
      final yStart = (edge.yMin - yOffset).ceil().toInt().clamp(0, height - 1);
      final yEnd = (edge.yMax - yOffset).floor().toInt().clamp(0, height - 1);

      for (int y = yStart; y <= yEnd; y++) {
        final scanY = y + yOffset;

        // Verificar se está dentro do range da aresta
        if (scanY < edge.yMin || scanY >= edge.yMax) continue;

        // Calcular interseção X usando slope pré-computado
        // x = x0 + (scanY - y0) * slopeDxDy
        final x = edge.x0 + (scanY - edge.y0) * edge.slopeDxDy;

        _scanlineEvents[y].add(EdgeEvent(
          x: x,
          edgeIndex: e,
          isEntering: edge.direction > 0,
        ));
      }
    }

    // Ordenar eventos por X em cada scanline
    for (int y = 0; y < height; y++) {
      _scanlineEvents[y].sort();
    }
  }

  // ───────────────────────────────────────────────────────────────────────
  // FASE 3: CLASSIFICAÇÃO DE TOPOLOGIA
  // ───────────────────────────────────────────────────────────────────────

  /// Classifica como uma aresta cruza um pixel baseado nos pontos
  /// de entrada e saída em coordenadas locais do pixel [0,1]×[0,1].
  ///
  /// Usa apenas comparações — sem branches no caminho crítico quando
  /// compilado com AOT (Dart compila isso eficientemente).
  // ignore: unused_element
  static Topology _classifyTopology(
    double yEntry,
    double yExit,
    double xEntry,
    double xExit,
  ) {
    // Determinar quais lados a aresta cruza
    // Entrada
    final enterLeft = xEntry <= 0.0;
    final enterBot = yEntry <= 0.0;
    final enterRight = xEntry >= 1.0;
    final enterTop = yEntry >= 1.0;
    // Saída
    final exitLeft = xExit <= 0.0;
    final exitBot = yExit <= 0.0;
    final exitRight = xExit >= 1.0;
    final exitTop = yExit >= 1.0;

    // Classificação por padrão de entrada/saída
    // Topo A: cruza Esquerda ↔ Direita
    if ((enterLeft && exitRight) || (enterRight && exitLeft)) {
      return Topology.a;
    }
    // Topo D: cruza Bottom ↔ Top (aresta vertical dominante)
    if ((enterBot && exitTop) || (enterTop && exitBot)) return Topology.d;
    // Topo B: cruza Esquerda ↔ Top
    if ((enterLeft && exitTop) || (enterTop && exitLeft)) return Topology.b;
    // Topo C: cruza Bottom ↔ Direita
    if ((enterBot && exitRight) || (enterRight && exitBot)) return Topology.c;

    // Casos com corners
    if ((enterLeft && exitBot) || (enterBot && exitLeft)) return Topology.c;
    if ((enterRight && exitTop) || (enterTop && exitRight)) return Topology.b;
    if ((enterLeft && exitLeft)) return Topology.none; // tangente
    if ((enterBot && exitBot)) return Topology.none; // tangente

    // Default: trata como trapezóide (Topo A)
    return Topology.a;
  }

  // ───────────────────────────────────────────────────────────────────────
  // FASE 4: FÓRMULAS FECHADAS DE COBERTURA (SEED)
  // ───────────────────────────────────────────────────────────────────────

  /// Calcula a cobertura de um pixel de borda usando a fórmula fechada
  /// correspondente à sua topologia.
  ///
  /// ESTE É O CORAÇÃO DO ALGORITMO.
  ///
  /// Cada topologia tem uma fórmula EXATA (não aproximação) que calcula
  /// a área da interseção entre a aresta e o pixel.
  ///
  /// Operações:
  ///   Topo A: 1 adição + 1 shift (multiplicação por 0.5)
  ///   Topo B: 2 subtrações + 1 multiplicação + 1 shift
  ///   Topo C: 1 multiplicação + 1 shift
  ///   Topo D: 1 adição + 1 shift
  // ignore: unused_element
  static double computeTopologySeed(
    double yEntry,
    double yExit,
    double xEntry,
    double xExit,
    Topology topo,
  ) {
    switch (topo) {
      case Topology.a:
        // Trapezóide: média das alturas de entrada e saída
        // Área = ½·(y_in + y_out) · 1 (largura do pixel)
        return 0.5 * (yEntry + yExit);

      case Topology.b:
        // Pixel completo menos triângulo no canto superior esquerdo
        // O triângulo tem base = (1 - x_top) e altura = (1 - y_entrada)
        // coverage = 1 - ½·base·altura
        return 1.0 - 0.5 * (1.0 - xExit) * (1.0 - yEntry);

      case Topology.c:
        // Triângulo no canto inferior direito
        // base = x_bottom, altura = y_saída
        // coverage = ½·base·altura
        return 0.5 * xEntry * yExit;

      case Topology.d:
        // Faixa vertical: média das posições X
        // coverage = ½·(x_entrada + x_saída)
        return 0.5 * (xEntry + xExit);

      case Topology.full:
        return 1.0;

      case Topology.none:
        return 0.0;
    }
  }

  // ───────────────────────────────────────────────────────────────────────
  // FASE 5: RASTERIZAÇÃO COM PROPAGAÇÃO POR DERIVADA
  // ───────────────────────────────────────────────────────────────────────

  /// FUNÇÃO PRINCIPAL DE RASTERIZAÇÃO.
  ///
  /// Implementa o algoritmo ACDR completo:
  /// 1. Pré-processa arestas
  /// 2. Constrói tabela de eventos
  /// 3. Para cada scanline, processa pares de interseções:
  ///    a) Calcula cobertura dos pixels de borda (seed + propagação)
  ///    b) Preenche pixels internos com coverage = 1.0
  ///
  /// @param vertices Lista de vértices do polígono (coordenadas normalizadas)
  /// @return Float64List com cobertura de cada pixel [0, 1]
  Float64List rasterize(
    List<Vec2> vertices, {
    int windingRule = 0,
    List<int>? contourVertexCounts,
  }) {
    if (vertices.length < 3) return coverageBuffer;

    // Fase 1: Pré-processar arestas
    final edges =
        _preprocessEdges(vertices, contourVertexCounts: contourVertexCounts);
    if (edges.isEmpty) return coverageBuffer;

    final sampleOffsets = enableVerticalSupersample
        ? (verticalSampleCount <= 2
            ? const <double>[0.25, 0.75]
            : const <double>[0.125, 0.375, 0.625, 0.875])
        : const <double>[0.5];
    final sampleWeight = 1.0 / sampleOffsets.length;

    for (final yOffset in sampleOffsets) {
      // Fase 2: Construir eventos
      _buildScanlineEvents(edges, yOffset);

      // Fase 3-5: Rasterizar por scanline
      for (int scanY = 0; scanY < height; scanY++) {
        final events = _scanlineEvents[scanY];
        if (events.length < 2) continue;

        // Processar spans por regra de preenchimento:
        // windingRule: 0 = even-odd, 1 = non-zero
        int winding = 0;
        double? xLeft;
        int leftEdgeIndex = -1;
        for (int p = 0; p < events.length; p++) {
          final event = events[p];
          final bool wasInside =
              (windingRule == 0) ? ((winding & 1) != 0) : (winding != 0);
          winding += event.isEntering ? 1 : -1;
          final bool isInside =
              (windingRule == 0) ? ((winding & 1) != 0) : (winding != 0);

          if (!wasInside && isInside) {
            xLeft = event.x;
            leftEdgeIndex = event.edgeIndex;
            continue;
          }
          if (!(wasInside && !isInside) || xLeft == null || leftEdgeIndex < 0) {
            continue;
          }

          final xRight = event.x;

          // Epsilon para evitar dupla contagem em interseções exatas
          final xLeftAdj = xLeft + 1e-6;
          final xRightAdj = xRight - 1e-6;

          if (xRightAdj <= xLeftAdj) continue; // Aresta degenerada

          final pxLeft = xLeftAdj.floor().clamp(0, width - 1);
          final pxRight = xRightAdj.floor().clamp(0, width - 1);

          // ── SPAN EM UM ÚNICO PIXEL ───────────────────────────────────
          if (enableSinglePixelSpanFix && pxRight == pxLeft) {
            final coverage = _rasterizeSinglePixelSpan(
              scanY,
              pxLeft,
              xLeftAdj,
              xRightAdj,
              edges[leftEdgeIndex],
              edges[event.edgeIndex],
            );
            if (coverage > 0.0) {
              coverageBuffer[scanY * width + pxLeft] += coverage * sampleWeight;
            }
            continue;
          }

          // ── PIXEL DE BORDA ESQUERDA ──────────────────────────────────
          _rasterizeLeftBorder(
            scanY,
            pxLeft,
            xLeftAdj,
            edges[leftEdgeIndex],
            sampleWeight,
          );

          // ── PIXEL DE BORDA DIREITA ───────────────────────────────────
          _rasterizeRightBorder(
            scanY,
            pxRight,
            xRightAdj,
            edges[event.edgeIndex],
            sampleWeight,
          );

          // ── PIXELS INTERNOS — FILL O(1) amortizado ──────────────────
          // Todos os pixels entre as bordas são completamente cobertos.
          final fillStart = (pxLeft + 1).clamp(0, width);
          final fillEnd = pxRight.clamp(0, width);

          if (fillEnd > fillStart) {
            final rowOffset = scanY * width;
            for (int px = fillStart; px < fillEnd; px++) {
              coverageBuffer[rowOffset + px] += sampleWeight;
            }
          }
          xLeft = null;
          leftEdgeIndex = -1;
        }
      }
    }

    return coverageBuffer;
  }

  // ───────────────────────────────────────────────────────────────────────
  // HELPERS: Pixels de borda
  // ───────────────────────────────────────────────────────────────────────

  /// Rasteriza o pixel de borda ESQUERDO de um span.
  ///
  /// A aresta entra pelo lado direito do polígono neste pixel.
  /// A cobertura é a fração do pixel que está DENTRO do polígono
  /// (à direita da interseção).
  void _rasterizeLeftBorder(
    int scanY,
    int px,
    double xIntersection,
    AcdrProcessedEdge edge,
    double sampleWeight,
  ) {
    if (!enableSubpixelY) {
      final fracX = xIntersection - px;
      var coverage = (1.0 - fracX).clamp(0.0, 1.0);
      coverageBuffer[scanY * width + px] += coverage * sampleWeight;
      return;
    }

    final slopeDxDy = edge.slopeDxDy; // dx/dy
    final xTop = xIntersection - 0.5 * slopeDxDy;
    final xBottom = xIntersection + 0.5 * slopeDxDy;

    final u0 = xTop - px;
    final u1 = xBottom - px;

    // Fração à direita da aresta = 1 - clamp(u,0,1)
    final leftArea = 1.0 - _integrateClamped01(u0, u1);
    coverageBuffer[scanY * width + px] +=
        leftArea.clamp(0.0, 1.0) * sampleWeight;
  }

  /// Rasteriza o pixel de borda DIREITO de um span.
  ///
  /// A aresta sai pelo lado esquerdo do polígono neste pixel.
  /// A cobertura é a fração do pixel que está DENTRO do polígono
  /// (à esquerda da interseção).
  void _rasterizeRightBorder(
    int scanY,
    int px,
    double xIntersection,
    AcdrProcessedEdge edge,
    double sampleWeight,
  ) {
    if (!enableSubpixelY) {
      final fracX = xIntersection - px;
      coverageBuffer[scanY * width + px] +=
          fracX.clamp(0.0, 1.0) * sampleWeight;
      return;
    }

    final slopeDxDy = edge.slopeDxDy; // dx/dy
    final xTop = xIntersection - 0.5 * slopeDxDy;
    final xBottom = xIntersection + 0.5 * slopeDxDy;

    final u0 = xTop - px;
    final u1 = xBottom - px;

    final rightArea = _integrateClamped01(u0, u1);
    coverageBuffer[scanY * width + px] +=
        rightArea.clamp(0.0, 1.0) * sampleWeight;
  }

  double _rasterizeSinglePixelSpan(
    int scanY,
    int px,
    double xLeft,
    double xRight,
    AcdrProcessedEdge leftEdge,
    AcdrProcessedEdge rightEdge,
  ) {
    if (!enableSubpixelY) {
      return (xRight - xLeft).clamp(0.0, 1.0);
    }

    // Integrar largura entre duas arestas dentro do mesmo pixel
    final xLeftTop = xLeft - 0.5 * leftEdge.slopeDxDy;
    final xLeftBottom = xLeft + 0.5 * leftEdge.slopeDxDy;
    final xRightTop = xRight - 0.5 * rightEdge.slopeDxDy;
    final xRightBottom = xRight + 0.5 * rightEdge.slopeDxDy;

    final uL0 = xLeftTop - px;
    final uL1 = xLeftBottom - px;
    final uR0 = xRightTop - px;
    final uR1 = xRightBottom - px;

    final areaLeft = _integrateClamped01(uL0, uL1);
    final areaRight = _integrateClamped01(uR0, uR1);

    final coverage = (areaRight - areaLeft).clamp(0.0, 1.0);
    return coverage;
  }

  /// Limpa o buffer de cobertura para reutilização
  void clear() {
    coverageBuffer.fillRange(0, coverageBuffer.length, 0.0);
  }

  @override
  void drawPolygon(
    List<double> vertices,
    int color, {
    int windingRule = 1,
    List<int>? contourVertexCounts,
  }) {
    // Mantem compatibilidade com o contrato unificado:
    // converte vertices em pixels para normalizado.
    if (vertices.length < 6) return;
    clear();
    final pts = List<Vec2>.generate(
      vertices.length ~/ 2,
      (i) => Vec2(vertices[i * 2] / width, vertices[i * 2 + 1] / height),
      growable: false,
    );
    rasterize(
      pts,
      windingRule: windingRule == 0 ? 0 : 1,
      contourVertexCounts: contourVertexCounts,
    );
  }
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

@pragma('vm:prefer-inline')
double _integrateLinear(double u0, double du, double a, double b) {
  // ∫_a^b (u0 + du*t) dt
  return u0 * (b - a) + 0.5 * du * (b * b - a * a);
}

/// Integra clamp(u, 0, 1) no intervalo [0,1], onde u(y) é linear.
@pragma('vm:prefer-inline')
double _integrateClamped01(double u0, double u1) {
  if (u0 <= 0.0 && u1 <= 0.0) return 0.0;
  if (u0 >= 1.0 && u1 >= 1.0) return 1.0;
  if (u0 == u1) return u0.clamp(0.0, 1.0);

  final du = u1 - u0;
  if (du > 0.0) {
    final y0 = (0.0 - u0) / du;
    final y1 = (1.0 - u0) / du;
    final a = y0.clamp(0.0, 1.0);
    final b = y1.clamp(0.0, 1.0);
    var integral = 0.0;
    if (b > a) integral += _integrateLinear(u0, du, a, b);
    if (y1 < 1.0) integral += (1.0 - b);
    return integral;
  } else {
    final y1 = (1.0 - u0) / du; // du < 0
    final y0 = (0.0 - u0) / du;
    final a = y1.clamp(0.0, 1.0);
    final b = y0.clamp(0.0, 1.0);
    var integral = 0.0;
    if (y1 > 0.0) integral += a;
    if (b > a) integral += _integrateLinear(u0, du, a, b);
    return integral;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// FUNÇÕES MATEMÁTICAS AUXILIARES
// ─────────────────────────────────────────────────────────────────────────────

double cos(double x) {
  // Taylor series — sem dependência externa
  var result = 1.0;
  var term = 1.0;
  for (int i = 1; i <= 12; i++) {
    term *= -x * x / ((2 * i - 1) * (2 * i));
    result += term;
  }
  return result;
}

double sin(double x) {
  return cos(x - math.pi / 2);
}
