import 'dart:math' as math;

import '../core/bl_types.dart';

class BLPathData {
  final List<double> vertices;
  final List<int>? contourVertexCounts;

  /// `contourClosed[i]` é true se o contorno i foi fechado explicitamente
  /// via `close()`. Usado pelo stroker para decidir caps vs join de fechamento.
  final List<bool>? contourClosed;

  const BLPathData({
    required this.vertices,
    required this.contourVertexCounts,
    this.contourClosed,
  });
}

/// Caixa envolvente em coordenadas de ponto flutuante.
class BLBox {
  final double x0;
  final double y0;
  final double x1;
  final double y1;

  const BLBox(this.x0, this.y0, this.x1, this.y1);

  double get width => x1 - x0;
  double get height => y1 - y0;

  @override
  String toString() => 'BLBox($x0, $y0, $x1, $y1)';
}

/// Verbos de um [BLPath].
///
/// O caminho guarda a geometria COMO FOI DESCRITA — inclusive os pontos de
/// controle das curvas — e só a achata em polilinha quando alguém consulta
/// [BLPath.toPathData]. Isso permite escolher a tolerância de achatamento na
/// resolução em que o caminho vai ser realmente desenhado, e permite
/// [BLPath.transformed] mapear uma curva sem perder precisão.
class _BLVerb {
  static const int moveTo = 0;
  static const int lineTo = 1;
  static const int quadTo = 2;
  static const int cubicTo = 3;
  static const int close = 4;

  const _BLVerb._();
}

/// Acumulador de polilinha usado pelo achatamento.
///
/// Reproduz exatamente as regras que [BLPath] aplicava quando achatava na
/// construção: pontos consecutivos idênticos são descartados e um contorno com
/// menos de dois vértices é removido.
class _FlattenSink {
  final List<double> vertices = <double>[];
  final List<int> counts = <int>[];
  final List<bool> closed = <bool>[];

  bool _hasCurrent = false;
  int _currentCount = 0;
  double _lastX = 0.0;
  double _lastY = 0.0;

  double get lastX => _lastX;
  double get lastY => _lastY;
  bool get hasCurrent => _hasCurrent;

  void moveTo(double x, double y) {
    finishContour();
    _hasCurrent = true;
    _lastX = x;
    _lastY = y;
    vertices.add(x);
    vertices.add(y);
    _currentCount = 1;
  }

  void lineTo(double x, double y) {
    if (!_hasCurrent) {
      moveTo(x, y);
      return;
    }
    if (x == _lastX && y == _lastY) return;
    vertices.add(x);
    vertices.add(y);
    _lastX = x;
    _lastY = y;
    _currentCount++;
  }

  void finishContour({bool isClosed = false}) {
    if (!_hasCurrent) return;
    if (_currentCount >= 2) {
      // Aceita contornos de 2+ pontos para stroke (linhas abertas).
      // O raster ignora contornos com < 3 pontos via fillPolygon.
      counts.add(_currentCount);
      closed.add(isClosed);
    } else {
      final removeCount = _currentCount * 2;
      if (removeCount > 0 && removeCount <= vertices.length) {
        vertices.removeRange(vertices.length - removeCount, vertices.length);
      }
    }
    _hasCurrent = false;
    _currentCount = 0;
  }
}

/// Path do contexto Blend2D em Dart.
///
/// Guarda verbos e pontos de controle; o achatamento em polilinha acontece sob
/// demanda em [toPathData], com a tolerância que o chamador escolher. Um
/// caminho construído em espaço do usuário pode portanto ser levado ao espaço
/// do device por [transformed] e só então achatado, na resolução certa.
class BLPath {
  final List<int> _verbs = <int>[];
  final List<double> _points = <double>[];

  /// Tolerância de achatamento associada a cada verbo de curva, na ordem em
  /// que as curvas aparecem. Preserva a semântica histórica de
  /// `quadTo(..., tolerance: t)`, que achatava na hora com `t`.
  final List<double> _curveTolerance = <double>[];

  static const int _maxCurveDepth = 16;

  /// Folga aplicada ao criterio de parada da subdivisao.
  ///
  /// A folha do achatamento nao emite a corda crua: emite o vertice que
  /// preserva a area (veja [_emitLeaf]). Isso divide por 3 o desvio maximo
  /// entre a polilinha e a curva — a corda erra `s` (a flecha do arco), a
  /// polilinha compensada erra `s/3`. Logo da para parar de subdividir com 3x
  /// mais folga e ainda assim entregar o desvio que a tolerancia promete,
  /// gastando ~1.7x menos folhas. Como cada folha custa 2 vertices em vez de
  /// 1, o total fica proximo do que era antes da compensacao.
  static const double _leafToleranceGain = 3.0;
  static const double _leafToleranceGainSq =
      _leafToleranceGain * _leafToleranceGain;

  /// Tolerância padrão, a mesma que este path usava quando achatava na
  /// construção.
  static const double defaultFlattenTolerance = 0.25;

  bool _hasCurrent = false;
  double _lastX = 0.0;
  double _lastY = 0.0;

  // Cache do último achatamento: o caminho costuma ser consultado mais de uma
  // vez (fill + stroke + clip) e re-achatar a cada consulta seria uma
  // regressão em relação ao achatamento na construção.
  List<double>? _flatVertices;
  List<int>? _flatCounts;
  List<bool>? _flatClosed;
  double _flatTolerance = double.nan;

  void _invalidate() {
    _flatVertices = null;
    _flatCounts = null;
    _flatClosed = null;
    _flatTolerance = double.nan;
  }

  // =========================================================================
  // Construção
  // =========================================================================

  void moveTo(double x, double y) {
    _invalidate();
    _verbs.add(_BLVerb.moveTo);
    _points.add(x);
    _points.add(y);
    _hasCurrent = true;
    _lastX = x;
    _lastY = y;
  }

  void lineTo(double x, double y) {
    if (!_hasCurrent) {
      moveTo(x, y);
      return;
    }
    if (x == _lastX && y == _lastY) return;
    _invalidate();
    _verbs.add(_BLVerb.lineTo);
    _points.add(x);
    _points.add(y);
    _lastX = x;
    _lastY = y;
  }

  /// Curva quadrática até (x, y) com ponto de controle (cx, cy).
  ///
  /// [tolerance] é o desvio máximo aceito quando a curva for achatada por
  /// [toPathData] sem uma tolerância explícita.
  void quadTo(
    double cx,
    double cy,
    double x,
    double y, {
    double tolerance = defaultFlattenTolerance,
  }) {
    if (!_hasCurrent) {
      moveTo(x, y);
      return;
    }
    _invalidate();
    _verbs.add(_BLVerb.quadTo);
    _points.add(cx);
    _points.add(cy);
    _points.add(x);
    _points.add(y);
    _curveTolerance.add(tolerance);
    _lastX = x;
    _lastY = y;
  }

  /// Curva cúbica até (x, y) com pontos de controle (c1x, c1y) e (c2x, c2y).
  void cubicTo(
    double c1x,
    double c1y,
    double c2x,
    double c2y,
    double x,
    double y, {
    double tolerance = defaultFlattenTolerance,
  }) {
    if (!_hasCurrent) {
      moveTo(x, y);
      return;
    }
    _invalidate();
    _verbs.add(_BLVerb.cubicTo);
    _points.add(c1x);
    _points.add(c1y);
    _points.add(c2x);
    _points.add(c2y);
    _points.add(x);
    _points.add(y);
    _curveTolerance.add(tolerance);
    _lastX = x;
    _lastY = y;
  }

  /// Fecha o contorno atual explicitamente.
  /// Marca o contorno como closed para o stroker (sem cap nas extremidades).
  void close() {
    if (!_hasCurrent) return;
    _invalidate();
    _verbs.add(_BLVerb.close);
    _hasCurrent = false;
  }

  void clear() {
    _verbs.clear();
    _points.clear();
    _curveTolerance.clear();
    _hasCurrent = false;
    _lastX = 0.0;
    _lastY = 0.0;
    _invalidate();
  }

  // =========================================================================
  // Consulta
  // =========================================================================

  /// True quando o caminho não tem nenhum verbo.
  bool get isEmpty => _verbs.isEmpty;

  /// True quando o caminho guarda pelo menos uma curva (quad ou cubic).
  bool get hasCurves => _curveTolerance.isNotEmpty;

  /// Achata o caminho em polilinhas e devolve a geometria resultante.
  ///
  /// Sem [tolerance] cada curva usa a tolerância com que foi adicionada (o
  /// default é [defaultFlattenTolerance]), o que reproduz exatamente o
  /// resultado de quando o achatamento acontecia na construção. Com
  /// [tolerance] explícita, ela vale para todas as curvas — é assim que quem
  /// conhece a escala do device pede o achatamento na resolução certa.
  BLPathData toPathData({double? tolerance}) {
    // Historicamente `toPathData()` encerrava o contorno em aberto, de modo
    // que um `lineTo` posterior iniciava um novo contorno. Preservado.
    _hasCurrent = false;

    final key = tolerance ?? double.negativeInfinity;
    if (_flatVertices == null || _flatTolerance != key) {
      _flatten(tolerance);
      _flatTolerance = key;
    }

    final counts = _flatCounts!;
    final closed = _flatClosed!;
    return BLPathData(
      vertices: List<double>.from(_flatVertices!),
      contourVertexCounts: counts.isEmpty ? null : List<int>.from(counts),
      contourClosed: closed.isEmpty ? null : List<bool>.from(closed),
    );
  }

  /// Caixa envolvente do caminho achatado, ou `null` se ele estiver vazio.
  ///
  /// É a caixa da geometria desenhada (não a dos pontos de controle), por isso
  /// depende da tolerância — passe [tolerance] para casar com o achatamento
  /// que vai ser usado no desenho.
  BLBox? bounds({double? tolerance}) {
    final data = toPathData(tolerance: tolerance);
    final v = data.vertices;
    if (v.isEmpty) return null;
    double minX = v[0], maxX = v[0], minY = v[1], maxY = v[1];
    for (int i = 2; i < v.length; i += 2) {
      final x = v[i], y = v[i + 1];
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    }
    return BLBox(minX, minY, maxX, maxY);
  }

  /// Caixa envolvente dos pontos de controle: conservadora (contém a caixa
  /// real) mas não exige achatamento. Útil para rejeição rápida por clip.
  BLBox? controlBounds() {
    if (_points.isEmpty) return null;
    double minX = _points[0], maxX = _points[0];
    double minY = _points[1], maxY = _points[1];
    for (int i = 2; i < _points.length; i += 2) {
      final x = _points[i], y = _points[i + 1];
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    }
    return BLBox(minX, minY, maxX, maxY);
  }

  /// Devolve uma cópia deste caminho com todos os pontos — inclusive os de
  /// controle das curvas — mapeados por [m].
  ///
  /// Como as curvas de Bézier são invariantes por transformação afim, mapear
  /// os pontos de controle é exato: o resultado é a mesma curva no espaço de
  /// destino, e só depois ela será achatada, na resolução de destino. As
  /// tolerâncias por curva são copiadas sem alteração, ou seja passam a valer
  /// nas unidades do espaço de destino.
  BLPath transformed(BLMatrix2D m) {
    final out = BLPath();
    if (_verbs.isEmpty) return out;

    int p = 0;
    int c = 0;
    for (final verb in _verbs) {
      switch (verb) {
        case _BLVerb.moveTo:
          final (x, y) = m.mapPoint(_points[p], _points[p + 1]);
          out.moveTo(x, y);
          p += 2;
          break;
        case _BLVerb.lineTo:
          final (x, y) = m.mapPoint(_points[p], _points[p + 1]);
          out.lineTo(x, y);
          p += 2;
          break;
        case _BLVerb.quadTo:
          final (cx, cy) = m.mapPoint(_points[p], _points[p + 1]);
          final (x, y) = m.mapPoint(_points[p + 2], _points[p + 3]);
          out.quadTo(cx, cy, x, y, tolerance: _curveTolerance[c]);
          p += 4;
          c++;
          break;
        case _BLVerb.cubicTo:
          final (c1x, c1y) = m.mapPoint(_points[p], _points[p + 1]);
          final (c2x, c2y) = m.mapPoint(_points[p + 2], _points[p + 3]);
          final (x, y) = m.mapPoint(_points[p + 4], _points[p + 5]);
          out.cubicTo(c1x, c1y, c2x, c2y, x, y, tolerance: _curveTolerance[c]);
          p += 6;
          c++;
          break;
        case _BLVerb.close:
          out.close();
          break;
      }
    }
    return out;
  }

  /// Cópia independente deste caminho, com as curvas preservadas.
  BLPath clone() => transformed(BLMatrix2D.identity);

  // =========================================================================
  // Convenience geometry methods
  // =========================================================================

  /// Adds a circular arc from angle [startAngle] sweeping [sweepAngle] radians.
  /// The arc is centered at (cx, cy) with radius [r].
  void addArc(
    double cx,
    double cy,
    double r,
    double startAngle,
    double sweepAngle, {
    bool moveToStart = true,
  }) {
    addEllipticArc(cx, cy, r, r, startAngle, sweepAngle,
        moveToStart: moveToStart);
  }

  /// Adds an elliptic arc with radii rx, ry.
  void addEllipticArc(
    double cx,
    double cy,
    double rx,
    double ry,
    double startAngle,
    double sweepAngle, {
    bool moveToStart = true,
  }) {
    if (sweepAngle.abs() < 1e-10) return;

    // Subdivide into 90° (pi/2) segments max
    const double halfPi = 1.5707963267948966;
    final int segments = (sweepAngle.abs() / halfPi).ceil().clamp(1, 16);
    final double segSweep = sweepAngle / segments;

    // Cubic Bézier approximation factor for arc segment
    final double alpha = (4.0 / 3.0) * _tan(segSweep * 0.25);

    double angle = startAngle;
    for (int i = 0; i < segments; i++) {
      final double cos0 = _cos(angle);
      final double sin0 = _sin(angle);
      final double cos1 = _cos(angle + segSweep);
      final double sin1 = _sin(angle + segSweep);

      final double x0 = cx + rx * cos0;
      final double y0 = cy + ry * sin0;
      final double x1 = cx + rx * cos1;
      final double y1 = cy + ry * sin1;

      // Control points
      final double c1x = x0 - alpha * rx * sin0;
      final double c1y = y0 + alpha * ry * cos0;
      final double c2x = x1 + alpha * rx * sin1;
      final double c2y = y1 - alpha * ry * cos1;

      if (i == 0 && moveToStart) {
        moveTo(x0, y0);
      }
      cubicTo(c1x, c1y, c2x, c2y, x1, y1);
      angle += segSweep;
    }
  }

  /// Adds a rectangle as a closed contour.
  void addRect(double x, double y, double w, double h) {
    moveTo(x, y);
    lineTo(x + w, y);
    lineTo(x + w, y + h);
    lineTo(x, y + h);
    close();
  }

  /// Adds a rounded rectangle with corner radius [r].
  void addRoundRect(double x, double y, double w, double h, double r) {
    if (r <= 0) {
      addRect(x, y, w, h);
      return;
    }
    // Clamp radius to half the smaller dimension
    final maxR = (w < h ? w : h) * 0.5;
    final cr = r > maxR ? maxR : r;
    const double k = 0.5522847498; // cubic Bézier approximation factor
    final kc = cr * k;

    // Start at top-left after corner
    moveTo(x + cr, y);
    // Top edge
    lineTo(x + w - cr, y);
    // Top-right corner
    cubicTo(x + w - cr + kc, y, x + w, y + cr - kc, x + w, y + cr);
    // Right edge
    lineTo(x + w, y + h - cr);
    // Bottom-right corner
    cubicTo(x + w, y + h - cr + kc, x + w - cr + kc, y + h, x + w - cr, y + h);
    // Bottom edge
    lineTo(x + cr, y + h);
    // Bottom-left corner
    cubicTo(x + cr - kc, y + h, x, y + h - cr + kc, x, y + h - cr);
    // Left edge
    lineTo(x, y + cr);
    // Top-left corner
    cubicTo(x, y + cr - kc, x + cr - kc, y, x + cr, y);
    close();
  }

  /// Adds another path's geometry to this path, curvas incluídas.
  void addPath(BLPath other) {
    if (identical(other, this)) {
      // Copiar de si mesmo enquanto se percorre invalidaria o iterador.
      addPath(other.clone());
      return;
    }
    int p = 0;
    int c = 0;
    for (final verb in other._verbs) {
      switch (verb) {
        case _BLVerb.moveTo:
          moveTo(other._points[p], other._points[p + 1]);
          p += 2;
          break;
        case _BLVerb.lineTo:
          lineTo(other._points[p], other._points[p + 1]);
          p += 2;
          break;
        case _BLVerb.quadTo:
          quadTo(other._points[p], other._points[p + 1], other._points[p + 2],
              other._points[p + 3],
              tolerance: other._curveTolerance[c]);
          p += 4;
          c++;
          break;
        case _BLVerb.cubicTo:
          cubicTo(other._points[p], other._points[p + 1], other._points[p + 2],
              other._points[p + 3], other._points[p + 4], other._points[p + 5],
              tolerance: other._curveTolerance[c]);
          p += 6;
          c++;
          break;
        case _BLVerb.close:
          close();
          break;
      }
    }
  }

  // Math helpers
  static double _cos(double x) => math.cos(x);
  static double _sin(double x) => math.sin(x);
  static double _tan(double x) => math.tan(x);

  // =========================================================================
  // Achatamento
  // =========================================================================

  void _flatten(double? tolerance) {
    final sink = _FlattenSink();
    int p = 0;
    int c = 0;
    for (final verb in _verbs) {
      switch (verb) {
        case _BLVerb.moveTo:
          sink.moveTo(_points[p], _points[p + 1]);
          p += 2;
          break;
        case _BLVerb.lineTo:
          sink.lineTo(_points[p], _points[p + 1]);
          p += 2;
          break;
        case _BLVerb.quadTo:
          final tol = tolerance ?? _curveTolerance[c];
          final tolSq = tol * tol;
          _flattenQuad(sink, sink.lastX, sink.lastY, _points[p], _points[p + 1],
              _points[p + 2], _points[p + 3], tolSq, 0);
          p += 4;
          c++;
          break;
        case _BLVerb.cubicTo:
          final tol = tolerance ?? _curveTolerance[c];
          final tolSq = tol * tol;
          _flattenCubic(
              sink,
              sink.lastX,
              sink.lastY,
              _points[p],
              _points[p + 1],
              _points[p + 2],
              _points[p + 3],
              _points[p + 4],
              _points[p + 5],
              tolSq,
              0);
          p += 6;
          c++;
          break;
        case _BLVerb.close:
          sink.finishContour(isClosed: true);
          break;
      }
    }
    sink.finishContour();

    _flatVertices = sink.vertices;
    _flatCounts = sink.counts;
    _flatClosed = sink.closed;
  }

  @pragma('vm:prefer-inline')
  static double _pointLineDistanceSq(
    double px,
    double py,
    double ax,
    double ay,
    double bx,
    double by,
  ) {
    final dx = bx - ax;
    final dy = by - ay;
    final den = dx * dx + dy * dy;
    if (den <= 1e-12) {
      final ex = px - ax;
      final ey = py - ay;
      return ex * ex + ey * ey;
    }
    final t = (((px - ax) * dx) + ((py - ay) * dy)) / den;
    final qx = ax + t * dx;
    final qy = ay + t * dy;
    final ex = px - qx;
    final ey = py - qy;
    return ex * ex + ey * ey;
  }

  @pragma('vm:prefer-inline')
  static double _quadFlatnessSq(
    double x0,
    double y0,
    double cx,
    double cy,
    double x1,
    double y1,
  ) {
    return _pointLineDistanceSq(cx, cy, x0, y0, x1, y1);
  }

  @pragma('vm:prefer-inline')
  static double _cubicFlatnessSq(
    double x0,
    double y0,
    double c1x,
    double c1y,
    double c2x,
    double c2y,
    double x1,
    double y1,
  ) {
    final d1 = _pointLineDistanceSq(c1x, c1y, x0, y0, x1, y1);
    final d2 = _pointLineDistanceSq(c2x, c2y, x0, y0, x1, y1);
    return d1 > d2 ? d1 : d2;
  }

  /// Emite a folha do achatamento preservando a area que a curva encerra.
  ///
  /// Uma polilinha *inscrita* na curva sempre encerra menos area do que ela: o
  /// deficit de cada corda e a area da lasca entre a corda e o arco. Somado ao
  /// longo de um circulo isso da um erro relativo de `(4/3) * tol / r`, que
  /// para raios pequenos passa de 10% — um circulo de raio 2 px rasterizava com
  /// area 11,31 em vez de 12,57. Nao e erro do rasterizador (um retangulo
  /// alinhado da a area exata), e do achatamento.
  ///
  /// A correcao emite, antes do ponto final, um vertice [mx], [my] escolhido
  /// para que o triangulo `(P0, M, P1)` tenha exatamente a area [area] da
  /// lasca. Com isso a area do poligono resultante e *identica* a area
  /// encerrada pela curva, em qualquer nivel de subdivisao. M fica sobre a
  /// mediatriz da corda, a altura `2*area/|corda|` — cerca de 4/3 da flecha do
  /// arco, ou seja um pouco alem do meio do arco. De quebra o desvio maximo da
  /// polilinha em relacao a curva cai de `s` para `s/3`.
  @pragma('vm:prefer-inline')
  static void _emitLeaf(
    _FlattenSink sink,
    double x0,
    double y0,
    double x1,
    double y1,
    double area,
  ) {
    final dx = x1 - x0;
    final dy = y1 - y0;
    final lenSq = dx * dx + dy * dy;
    // Corda degenerada (laco fechado sobre si) ou lasca desprezivel em relacao
    // ao tamanho da corda: nao vale um vertice a mais.
    if (lenSq > 0.0 && 4.0 * area * area > 1e-12 * lenSq * lenSq) {
      final f = 2.0 * area / lenSq;
      sink.lineTo((x0 + x1) * 0.5 + f * dy, (y0 + y1) * 0.5 - f * dx);
    }
    sink.lineTo(x1, y1);
  }

  /// Area (com sinal) entre a quadratica e a corda `P0 -> P1`.
  ///
  /// Vale exatamente 2/3 da area do triangulo `(P0, C, P1)`.
  @pragma('vm:prefer-inline')
  static double _quadChordArea(
    double x0,
    double y0,
    double cx,
    double cy,
    double x1,
    double y1,
  ) {
    final ax = cx - x0, ay = cy - y0;
    final bx = x1 - x0, by = y1 - y0;
    return (ax * by - ay * bx) / 3.0;
  }

  /// Area (com sinal) entre a cubica e a corda `P0 -> P1`.
  ///
  /// `A = 3/20 * [cross(a,b) + cross(a,c) + 2*cross(b,c)]`, com `a = C1 - P0`,
  /// `b = C2 - P0` e `c = P1 - P0`. Sai de integrar `1/2 * cross(B, B')` sobre
  /// a base de Bernstein.
  @pragma('vm:prefer-inline')
  static double _cubicChordArea(
    double x0,
    double y0,
    double c1x,
    double c1y,
    double c2x,
    double c2y,
    double x1,
    double y1,
  ) {
    final ax = c1x - x0, ay = c1y - y0;
    final bx = c2x - x0, by = c2y - y0;
    final cx = x1 - x0, cy = y1 - y0;
    final ab = ax * by - ay * bx;
    final ac = ax * cy - ay * cx;
    final bc = bx * cy - by * cx;
    return 0.15 * (ab + ac + 2.0 * bc);
  }

  /// Quadrado do ganho de tolerancia aplicavel a esta cubica.
  ///
  /// O ganho so se justifica quando a compensacao de area realmente encolhe o
  /// desvio, e isso exige que a curva nao troque de lado da corda. Se os dois
  /// pontos de controle estao do mesmo lado (curva convexa no trecho), a
  /// lasca tem um sinal so e o vertice compensado cai no meio dela. Num
  /// trecho em S as duas metades se cancelam na area e o vertice compensado
  /// volta para cima da corda, sem reduzir desvio nenhum — ai vale a
  /// tolerancia crua.
  @pragma('vm:prefer-inline')
  static double _cubicToleranceGainSq(
    double x0,
    double y0,
    double c1x,
    double c1y,
    double c2x,
    double c2y,
    double x1,
    double y1,
  ) {
    final dx = x1 - x0;
    final dy = y1 - y0;
    final s1 = dx * (c1y - y0) - dy * (c1x - x0);
    final s2 = dx * (c2y - y0) - dy * (c2x - x0);
    return s1 * s2 >= 0.0 ? _leafToleranceGainSq : 1.0;
  }

  static void _flattenQuad(
    _FlattenSink sink,
    double x0,
    double y0,
    double cx,
    double cy,
    double x1,
    double y1,
    double tolSq,
    int depth,
  ) {
    // Uma quadratica nunca tem inflexao: o ponto de controle esta sempre do
    // mesmo lado da corda, entao a compensacao de area sempre reduz o desvio e
    // o ganho de tolerancia vale integralmente.
    if (depth >= _maxCurveDepth ||
        _quadFlatnessSq(x0, y0, cx, cy, x1, y1) <=
            tolSq * _leafToleranceGainSq) {
      _emitLeaf(sink, x0, y0, x1, y1, _quadChordArea(x0, y0, cx, cy, x1, y1));
      return;
    }

    final x01 = (x0 + cx) * 0.5;
    final y01 = (y0 + cy) * 0.5;
    final x12 = (cx + x1) * 0.5;
    final y12 = (cy + y1) * 0.5;
    final x012 = (x01 + x12) * 0.5;
    final y012 = (y01 + y12) * 0.5;

    _flattenQuad(sink, x0, y0, x01, y01, x012, y012, tolSq, depth + 1);
    _flattenQuad(sink, x012, y012, x12, y12, x1, y1, tolSq, depth + 1);
  }

  static void _flattenCubic(
    _FlattenSink sink,
    double x0,
    double y0,
    double c1x,
    double c1y,
    double c2x,
    double c2y,
    double x1,
    double y1,
    double tolSq,
    int depth,
  ) {
    if (depth >= _maxCurveDepth ||
        _cubicFlatnessSq(x0, y0, c1x, c1y, c2x, c2y, x1, y1) <=
            tolSq * _cubicToleranceGainSq(x0, y0, c1x, c1y, c2x, c2y, x1, y1)) {
      _emitLeaf(sink, x0, y0, x1, y1,
          _cubicChordArea(x0, y0, c1x, c1y, c2x, c2y, x1, y1));
      return;
    }

    final x01 = (x0 + c1x) * 0.5;
    final y01 = (y0 + c1y) * 0.5;
    final x12 = (c1x + c2x) * 0.5;
    final y12 = (c1y + c2y) * 0.5;
    final x23 = (c2x + x1) * 0.5;
    final y23 = (c2y + y1) * 0.5;

    final x012 = (x01 + x12) * 0.5;
    final y012 = (y01 + y12) * 0.5;
    final x123 = (x12 + x23) * 0.5;
    final y123 = (y12 + y23) * 0.5;

    final x0123 = (x012 + x123) * 0.5;
    final y0123 = (y012 + y123) * 0.5;

    _flattenCubic(
        sink, x0, y0, x01, y01, x012, y012, x0123, y0123, tolSq, depth + 1);
    _flattenCubic(
        sink, x0123, y0123, x123, y123, x23, y23, x1, y1, tolSq, depth + 1);
  }
}
