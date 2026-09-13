import 'dart:math' as math;

import 'bl_image.dart';

typedef BLColor = int; // 0xAARRGGBB
typedef BLPixelFetcher = int Function(int x, int y);

enum BLFillRule {
  evenOdd,
  nonZero,
}

extension BLFillRuleX on BLFillRule {
  int get windingRule => this == BLFillRule.evenOdd ? 0 : 1;

  static BLFillRule fromWindingRule(int windingRule) {
    return windingRule == 0 ? BLFillRule.evenOdd : BLFillRule.nonZero;
  }
}

enum BLCompOp {
  // Porter-Duff (aligned with BL_COMP_OP_* from context.h)
  srcOver, // 0 — default
  srcCopy, // 1
  srcIn, // 2
  srcOut, // 3
  srcAtop, // 4
  dstOver, // 5
  dstCopy, // 6
  dstIn, // 7
  dstOut, // 8
  dstAtop, // 9
  xor_, // 10 — 'xor' is reserved in Dart
  clear, // 11

  // Advanced blend modes (separable)
  plus, // 12
  minus, // 13
  modulate, // 14
  multiply, // 15
  screen, // 16
  overlay, // 17
  darken, // 18
  lighten, // 19
  colorDodge, // 20
  colorBurn, // 21
  linearBurn, // 22
  linearLight, // 23
  pinLight, // 24
  hardLight, // 25
  softLight, // 26
  difference, // 27
  exclusion, // 28
}

class BLPoint {
  final double x;
  final double y;

  const BLPoint(this.x, this.y);
}

class BLRectI {
  final int x;
  final int y;
  final int width;
  final int height;

  const BLRectI(this.x, this.y, this.width, this.height);
}

class BLGradientStop {
  final double offset; // [0..1]
  final BLColor color;

  const BLGradientStop(this.offset, this.color);
}

enum BLGradientExtendMode {
  pad,
  repeat,
  reflect,
}

enum BLPatternFilter {
  nearest,
  bilinear,
}

/// Matriz afim 2D no mesmo layout do `BLMatrix2D` do Blend2D C++.
///
/// A convenção é de **vetor-linha**: um ponto `p = [x y 1]` é mapeado por
/// `p * M`, onde
///
/// ```
///     | m00  m01  0 |
/// M = | m10  m11  0 |
///     | m20  m21  1 |
/// ```
///
/// ou seja `x' = m00*x + m10*y + m20` e `y' = m01*x + m11*y + m21`
/// (exatamente o que [BLContext.transformPoint] já fazia antes desta classe
/// ganhar métodos, e o mesmo layout de `[a b c d e f]` do PDF).
class BLMatrix2D {
  final double m00;
  final double m01;
  final double m10;
  final double m11;
  final double m20;
  final double m21;

  const BLMatrix2D(
    this.m00,
    this.m01,
    this.m10,
    this.m11,
    this.m20,
    this.m21,
  );

  static const BLMatrix2D identity = BLMatrix2D(1.0, 0.0, 0.0, 1.0, 0.0, 0.0);

  /// Matriz de translação por ([tx], [ty]).
  static BLMatrix2D translation(double tx, double ty) =>
      BLMatrix2D(1.0, 0.0, 0.0, 1.0, tx, ty);

  /// Matriz de escala por ([sx], [sy]).
  static BLMatrix2D scaling(double sx, double sy) =>
      BLMatrix2D(sx, 0.0, 0.0, sy, 0.0, 0.0);

  /// Matriz de rotação de [radians] (sentido horário em coordenadas de tela,
  /// onde Y cresce para baixo; anti-horário em coordenadas matemáticas).
  static BLMatrix2D rotation(double radians) {
    final c = math.cos(radians);
    final s = math.sin(radians);
    return BLMatrix2D(c, s, -s, c, 0.0, 0.0);
  }

  /// Produto matricial `this * other` na convenção de vetor-linha.
  ///
  /// **Ordem**: `this` é aplicada PRIMEIRO e [other] DEPOIS, isto é, o
  /// resultado mapeia um ponto como `other(this(p))`. Equivalentemente,
  /// `a.multiply(b).mapPoint(p) == b.mapPoint(a.mapPoint(p))`.
  ///
  /// Isso é o que o operador `cm` do PDF precisa: `CTM' = cm.multiply(CTM)`,
  /// porque no PDF a nova matriz age sobre as coordenadas do usuário antes da
  /// CTM vigente.
  BLMatrix2D multiply(BLMatrix2D other) {
    return BLMatrix2D(
      m00 * other.m00 + m01 * other.m10,
      m00 * other.m01 + m01 * other.m11,
      m10 * other.m00 + m11 * other.m10,
      m10 * other.m01 + m11 * other.m11,
      m20 * other.m00 + m21 * other.m10 + other.m20,
      m20 * other.m01 + m21 * other.m11 + other.m21,
    );
  }

  /// Determinante da parte linear (2x2) da matriz.
  double get determinant => m00 * m11 - m01 * m10;

  /// Inversa da matriz, ou `null` se o determinante for ~0 (não inversível).
  ///
  /// Padrões de imagem e shadings do PDF precisam levar um pixel de device de
  /// volta ao espaço do padrão, o que exige esta inversa.
  BLMatrix2D? invert() {
    final det = determinant;
    // Limite absoluto: matrizes de PDF já chegam em unidades de device, então
    // um determinante desta ordem significa que a transformação colapsou a
    // área em uma linha/ponto e não há inversa útil.
    if (det.abs() < 1e-20 || !det.isFinite) return null;
    final inv = 1.0 / det;
    return BLMatrix2D(
      m11 * inv,
      -m01 * inv,
      -m10 * inv,
      m00 * inv,
      (m10 * m21 - m11 * m20) * inv,
      (m01 * m20 - m00 * m21) * inv,
    );
  }

  /// Mapeia o ponto ([x], [y]) por esta matriz.
  (double, double) mapPoint(double x, double y) =>
      (m00 * x + m10 * y + m20, m01 * x + m11 * y + m21);

  /// True se a matriz é a identidade (comparação exata, como no fast path
  /// de [BLContext]).
  bool get isIdentity =>
      m00 == 1.0 &&
      m01 == 0.0 &&
      m10 == 0.0 &&
      m11 == 1.0 &&
      m20 == 0.0 &&
      m21 == 0.0;

  @override
  String toString() => 'BLMatrix2D($m00, $m01, $m10, $m11, $m20, $m21)';
}

class BLLinearGradient {
  final BLPoint p0;
  final BLPoint p1;
  final List<BLGradientStop> stops;
  final BLGradientExtendMode extendMode;
  final bool extendStart;
  final bool extendEnd;

  /// Matriz que leva o espaço do gradiente ao espaço do device.
  ///
  /// Os pontos/raios do gradiente são interpretados NESTE espaço; o fetcher
  /// inverte a matriz e leva cada pixel de device de volta a ele. É a mesma
  /// semântica de `BLGradient::setTransform` do Blend2D C++ e do `/Matrix` de
  /// um `/Pattern` do PDF (ISO 32000-1 8.7.3.1), e é o que permite a um
  /// shading radial produzir uma ELIPSE sob uma CTM anisotrópica, em vez de
  /// um círculo de raio médio.
  ///
  /// Atenção: é o inverso da convenção de [BLPattern.transform], que já leva
  /// o device ao espaço do padrão.
  final BLMatrix2D transform;

  const BLLinearGradient({
    required this.p0,
    required this.p1,
    required this.stops,
    this.extendMode = BLGradientExtendMode.pad,
    this.extendStart = true,
    this.extendEnd = true,
    this.transform = BLMatrix2D.identity,
  });
}

class BLRadialGradient {
  final BLPoint c0;
  final BLPoint c1;
  final double r0;
  final double r1;
  final List<BLGradientStop> stops;
  final BLGradientExtendMode extendMode;
  final bool extendStart;
  final bool extendEnd;

  /// Matriz que leva o espaço do gradiente ao espaço do device.
  ///
  /// Os pontos/raios do gradiente são interpretados NESTE espaço; o fetcher
  /// inverte a matriz e leva cada pixel de device de volta a ele. É a mesma
  /// semântica de `BLGradient::setTransform` do Blend2D C++ e do `/Matrix` de
  /// um `/Pattern` do PDF (ISO 32000-1 8.7.3.1), e é o que permite a um
  /// shading radial produzir uma ELIPSE sob uma CTM anisotrópica, em vez de
  /// um círculo de raio médio.
  ///
  /// Atenção: é o inverso da convenção de [BLPattern.transform], que já leva
  /// o device ao espaço do padrão.
  final BLMatrix2D transform;

  const BLRadialGradient({
    required this.c0,
    required this.c1,
    required this.r0,
    this.r1 = 0.0,
    required this.stops,
    this.extendMode = BLGradientExtendMode.pad,
    this.extendStart = true,
    this.extendEnd = true,
    this.transform = BLMatrix2D.identity,
  });
}

class BLConicGradient {
  final BLPoint center;
  final double angle; // Offset inicial em radianos
  final List<BLGradientStop> stops;
  final BLGradientExtendMode extendMode;

  /// Matriz que leva o espaço do gradiente ao espaço do device.
  ///
  /// Os pontos/raios do gradiente são interpretados NESTE espaço; o fetcher
  /// inverte a matriz e leva cada pixel de device de volta a ele. É a mesma
  /// semântica de `BLGradient::setTransform` do Blend2D C++ e do `/Matrix` de
  /// um `/Pattern` do PDF (ISO 32000-1 8.7.3.1), e é o que permite a um
  /// shading radial produzir uma ELIPSE sob uma CTM anisotrópica, em vez de
  /// um círculo de raio médio.
  ///
  /// Atenção: é o inverso da convenção de [BLPattern.transform], que já leva
  /// o device ao espaço do padrão.
  final BLMatrix2D transform;

  const BLConicGradient({
    required this.center,
    this.angle = 0.0,
    required this.stops,
    this.extendMode = BLGradientExtendMode.pad,
    this.transform = BLMatrix2D.identity,
  });
}

class BLPattern {
  final BLImage image;
  final BLPoint offset;
  final BLGradientExtendMode extendModeX;
  final BLGradientExtendMode extendModeY;
  final BLPatternFilter filter;
  final BLMatrix2D transform;

  const BLPattern({
    required this.image,
    this.offset = const BLPoint(0.0, 0.0),
    this.extendModeX = BLGradientExtendMode.pad,
    this.extendModeY = BLGradientExtendMode.pad,
    this.filter = BLPatternFilter.nearest,
    this.transform = BLMatrix2D.identity,
  });
}

// ---------------------------------------------------------------------------
// Stroke types (Fase 5 - port do PathStroker do Blend2D)
// ---------------------------------------------------------------------------

/// Estilo de cap para extremidades de contornos abertos.
/// Alinhado com BLStrokeCap do C++.
enum BLStrokeCap {
  /// Termina exatamente no ponto final (padrão).
  butt,

  /// Estende o cap em halfWidth além do ponto final (forma quadrada).
  square,

  /// Cap circular com raio = halfWidth.
  round,

  /// Cap circular recuado (inverso do round).
  roundRev,

  /// Cap triangular apontando para fora.
  triangle,

  /// Cap triangular apontando para dentro.
  triangleRev,
}

/// Estilo de join para vértices internos de contornos.
/// Alinhado com BLStrokeJoin do C++.
enum BLStrokeJoin {
  /// Chanfrado simples (bevel).
  bevel,

  /// Miter cortado quando excede o limite.
  miterClip,

  /// Miter com fallback para bevel.
  miterBevel,

  /// Miter com fallback para round.
  miterRound,

  /// Join circular.
  round,
}

/// Opções de stroke usadas por BLContext.strokePath() e BLStroker.
/// Equivalente a BLStrokeOptions do C++.
class BLStrokeOptions {
  /// Largura total do stroke.
  final double width;

  /// Limite do miter (em múltiplos de halfWidth).
  /// Default 4.0 corresponde a BL_STROKE_MITER_LIMIT_DEFAULT.
  final double miterLimit;

  /// Cap do início do contorno.
  final BLStrokeCap startCap;

  /// Cap do fim do contorno.
  final BLStrokeCap endCap;

  /// Estilo de join nos vértices internos.
  final BLStrokeJoin join;

  /// Tolerância de flatten para curvas (De Casteljau).
  final double flattenTolerance;

  /// Largura mínima efetiva, nas mesmas unidades (espaço do usuário) de
  /// [width].
  ///
  /// Quando [width] é `<= 0` o stroker usa este valor no lugar dela. É o que
  /// o operador `0 w` do PDF pede: "a linha mais fina que o dispositivo
  /// consegue desenhar", nunca linha nenhuma.
  ///
  /// O default `1.0` equivale a um pixel quando não há transformação. Como o
  /// stroker trabalha em espaço do usuário e não conhece a escala do device,
  /// quem tem a CTM deve passar `minimumWidth: 1.0 / escalaDoDevice` —
  /// [BLContext.strokePath] faz isso automaticamente a partir da transformação
  /// corrente.
  final double minimumWidth;

  const BLStrokeOptions({
    this.width = 1.0,
    this.miterLimit = 4.0,
    this.startCap = BLStrokeCap.butt,
    this.endCap = BLStrokeCap.butt,
    this.join = BLStrokeJoin.bevel,
    this.flattenTolerance = 0.25,
    this.minimumWidth = 1.0,
  });

  /// Largura realmente usada pelo stroker: [width], ou [minimumWidth] quando
  /// [width] é zero/negativa.
  double get effectiveWidth => width > 0.0 ? width : minimumWidth;

  BLStrokeOptions copyWith({
    double? width,
    double? miterLimit,
    BLStrokeCap? startCap,
    BLStrokeCap? endCap,
    BLStrokeJoin? join,
    double? flattenTolerance,
    double? minimumWidth,
  }) {
    return BLStrokeOptions(
      width: width ?? this.width,
      miterLimit: miterLimit ?? this.miterLimit,
      startCap: startCap ?? this.startCap,
      endCap: endCap ?? this.endCap,
      join: join ?? this.join,
      flattenTolerance: flattenTolerance ?? this.flattenTolerance,
      minimumWidth: minimumWidth ?? this.minimumWidth,
    );
  }
}
