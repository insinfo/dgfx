import 'dart:math' as math;

import 'bl_path.dart';

/// Um trecho contínuo de traço produzido pelo dasher.
///
/// Guardado antes de ir para o [BLPath] de saída porque um contorno fechado
/// pode precisar fundir o último traço com o primeiro (ambos encostam no ponto
/// inicial do contorno) — sem a fusão o ponto de partida ganharia dois caps em
/// vez de um join.
class _DashRun {
  /// Pontos do traço, já sem repetições consecutivas.
  final List<double> points = <double>[];

  /// Direção unitária do segmento onde o traço começou. Só é usada quando o
  /// traço tem comprimento zero (um "ponto" do padrão, ISO 32000-1 8.4.3.6).
  double dirX = 1.0;
  double dirY = 0.0;

  void add(double x, double y) {
    final n = points.length;
    if (n >= 2 && points[n - 2] == x && points[n - 1] == y) return;
    points
      ..add(x)
      ..add(y);
  }

  int get vertexCount => points.length ~/ 2;

  double get firstX => points[0];
  double get firstY => points[1];
  double get lastX => points[points.length - 2];
  double get lastY => points[points.length - 1];
}

/// Dash pattern generator (port of Blend2D's dasher).
///
/// Converts a solid [BLPath] into a dashed [BLPath] by applying a repeating
/// dash/gap pattern. The result can then be stroked via `BLStroker`.
///
/// Segue ISO 32000-1 8.4.3.6 (`d` — line dash pattern):
///  - o padrão alterna traço/lacuna começando por um traço;
///  - um array de tamanho ímpar é usado ciclicamente, de modo que `[3]`
///    significa 3 ligado / 3 desligado;
///  - um array vazio (ou com comprimento total zero) significa linha sólida;
///  - traços de comprimento zero viram pontos, visíveis quando o cap é
///    redondo ou quadrado projetado.
///
/// Inspired by: `blend2d/core/pathstroke.cpp` dash logic.
class BLDasher {
  const BLDasher._();

  /// Comprimento dado a um traço de comprimento zero para que ele sobreviva
  /// até o stroker e vire um ponto (ISO 32000-1 8.4.3.6). Com cap `butt` o
  /// resultado continua invisível, que é o comportamento correto.
  static const double _kDotLength = 1e-6;

  /// Applies a dash pattern to [input] and returns a new dashed path.
  ///
  /// [dashArray] is a list of alternating dash/gap lengths (e.g. `[10, 5]`).
  /// [dashOffset] shifts the start of the dash pattern.
  ///
  /// Each contour in [input] is independently dashed. Contornos fechados
  /// (`close()`) incluem a aresta de fechamento, de `p[n-1]` de volta a `p[0]`.
  static BLPath dashPath(
    BLPath input,
    List<double> dashArray, {
    double dashOffset = 0.0,
  }) {
    if (dashArray.isEmpty) return input;

    // ISO 32000-1 8.4.3.6: o array é usado ciclicamente. Com tamanho ímpar a
    // paridade traço/lacuna se inverte a cada volta, o que equivale a repetir
    // o array duas vezes. Sem isso `[3] 0 d` (3 ligado / 3 desligado) saía
    // como linha sólida, porque o índice 0 — sempre par — nunca virava lacuna.
    final pattern = <double>[];
    for (final d in dashArray) {
      pattern.add(d.abs());
    }
    if (pattern.length.isOdd) {
      pattern.addAll(pattern.toList(growable: false));
    }

    double patternLen = 0.0;
    for (final d in pattern) {
      patternLen += d;
    }
    // Padrão degenerado (tudo zero): a spec chama de inválido; os leitores
    // desenham linha sólida, que é o que devolver o caminho de entrada faz.
    if (patternLen <= 0.0 || !patternLen.isFinite) return input;

    final result = BLPath();
    final data = input.toPathData();
    final verts = data.vertices;
    if (verts.isEmpty) return result;

    final counts = data.contourVertexCounts ?? [verts.length ~/ 2];
    final closedFlags = data.contourClosed;

    int vertOffset = 0;
    for (int ci = 0; ci < counts.length; ci++) {
      final cnt = counts[ci];
      if (cnt < 2) {
        vertOffset += cnt;
        continue;
      }
      final bool closed = closedFlags != null &&
          ci < closedFlags.length &&
          closedFlags[ci];
      _dashContour(
        result,
        verts,
        vertOffset,
        cnt,
        closed,
        pattern,
        patternLen,
        dashOffset,
      );
      vertOffset += cnt;
    }

    return result;
  }

  static void _dashContour(
    BLPath out,
    List<double> verts,
    int start,
    int count,
    bool closed,
    List<double> pattern,
    double patternLen,
    double offset,
  ) {
    // Normalize offset into [0, patternLen)
    double dashState = offset % patternLen;
    if (dashState < 0) dashState += patternLen;

    // Find initial dash index and remaining length in that dash
    int dashIdx = 0;
    double rem = dashState;
    // `rem > 0` impede que uma entrada de comprimento ZERO seja consumida
    // aqui: `[0 5] 0 d` pede um ponto exatamente no início do contorno, e
    // pular a entrada 0 levava o contorno a começar já dentro da lacuna.
    while (dashIdx < pattern.length && rem > 0 && rem >= pattern[dashIdx]) {
      rem -= pattern[dashIdx];
      dashIdx++;
    }
    if (dashIdx >= pattern.length) {
      dashIdx = 0;
      rem = 0;
    }
    double dashRemaining = pattern[dashIdx] - rem;
    bool isDash = (dashIdx & 1) == 0; // even indices = dash, odd = gap
    final bool startsInDash = isDash;

    final runs = <_DashRun>[];
    _DashRun? current;

    // Contorno fechado inclui a aresta de p[count-1] de volta a p[0]: sem ela
    // um `re S` tracejado sai com três lados.
    final int segCount = closed ? count : count - 1;

    for (int seg = 0; seg < segCount; seg++) {
      final i0 = start + seg;
      final i1 = start + ((seg + 1) % count);
      final double x0 = verts[i0 * 2], y0 = verts[i0 * 2 + 1];
      final double x1 = verts[i1 * 2], y1 = verts[i1 * 2 + 1];

      final dx = x1 - x0, dy = y1 - y0;
      final double segLen = math.sqrt(dx * dx + dy * dy);
      if (segLen < 1e-12) continue;

      final ux = dx / segLen, uy = dy / segLen;
      double consumed = 0;

      while (consumed < segLen - 1e-10) {
        final available = segLen - consumed;
        final take = math.min(dashRemaining, available);

        final px = x0 + ux * (consumed + take);
        final py = y0 + uy * (consumed + take);

        if (isDash) {
          if (current == null) {
            current = _DashRun()
              ..dirX = ux
              ..dirY = uy
              ..add(x0 + ux * consumed, y0 + uy * consumed);
            runs.add(current);
          }
          current.add(px, py);
        } else {
          current = null;
        }

        consumed += take;
        dashRemaining -= take;

        if (dashRemaining <= 1e-10) {
          dashIdx = (dashIdx + 1) % pattern.length;
          dashRemaining = pattern[dashIdx];
          isDash = (dashIdx & 1) == 0;
          if (!isDash) current = null;
        }
      }
    }

    final bool endsInDash = current != null;

    if (runs.isEmpty) return;

    // Fechado e com traço encostando nas duas pontas: o último traço e o
    // primeiro são o mesmo traço, visto que ambos tocam p[0]. Fundir evita
    // dois caps onde deveria haver um join.
    if (closed && startsInDash && endsInDash && runs.length > 1) {
      final first = runs.first;
      final last = runs.removeLast();
      for (int i = 0; i < first.vertexCount; i++) {
        last.add(first.points[i * 2], first.points[i * 2 + 1]);
      }
      runs[0] = last;
    }

    for (final run in runs) {
      if (run.vertexCount < 2) {
        // Traço de comprimento zero: vira um ponto.
        _emitDot(out, run);
        continue;
      }
      out.moveTo(run.firstX, run.firstY);
      for (int i = 1; i < run.vertexCount; i++) {
        out.lineTo(run.points[i * 2], run.points[i * 2 + 1]);
      }
      // Contorno inteiramente coberto por um único traço: fecha para que o
      // stroker aplique um join, e não dois caps, no ponto de partida.
      if (closed &&
          runs.length == 1 &&
          startsInDash &&
          endsInDash &&
          run.lastX == run.firstX &&
          run.lastY == run.firstY) {
        out.close();
      }
    }
  }

  /// Emite um traço degenerado como um segmento minúsculo na direção do
  /// contorno. Com cap `round` ou `square` o stroker o transforma no ponto que
  /// a spec pede; com `butt` ele permanece invisível, também como a spec pede.
  static void _emitDot(BLPath out, _DashRun run) {
    final x = run.firstX;
    final y = run.firstY;
    out.moveTo(x, y);
    out.lineTo(x + run.dirX * _kDotLength, y + run.dirY * _kDotLength);
  }
}

/// Options for dashed stroke.
class BLDashOptions {
  /// Alternating dash/gap lengths.
  final List<double> dashArray;

  /// Offset within the dash pattern to start from.
  final double dashOffset;

  const BLDashOptions({
    required this.dashArray,
    this.dashOffset = 0.0,
  });
}
