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
      final bool closed =
          closedFlags != null && ci < closedFlags.length && closedFlags[ci];
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

    // Um contorno fechado de dois vértices retrocede sobre si mesmo: `m p0;
    // l p1; h` é ida e volta pelo mesmo segmento, e é o que o PyMuPDF emite
    // em toda linha. O padrão corre pelos dois sentidos — a ISO 32000-1
    // 8.4.3.6 manda percorrer o caminho inteiro, e o MuPDF faz isso também —
    // então traços da ida caem sobre traços da volta.
    //
    // Pintar a sobreposição duas vezes não muda a região coberta, mas muda o
    // que o rasterizador analítico calcula: ele integra o winding sobre o
    // pixel e corta em 1, em vez de integrar [winding != 0]. Num pixel de
    // borda coberto pela metade por dois traços, isso dá 0,5 + 0,5 = 1,0 onde
    // a verdade é 0,5, e a borda sai opaca. Os rasterizadores de varredura
    // não têm o problema porque emitem um único span de onde o winding sai de
    // zero até onde volta — `non_zero_winding_aa` em `draw-edge.c` do MuPDF e
    // o ramo não-zero de `Renderer.java` no Marlin são a mesma estrutura.
    //
    // Em vez de mudar de rasterizador, tira-se a causa: os traços deste caso
    // vivem todos sobre uma reta, então viram intervalos em um parâmetro e a
    // união é exata. Sem sobreposição, qualquer rasterizador acerta.
    if (closed && count == 2) {
      _emitMergedRetrace(out, runs, verts[start * 2], verts[start * 2 + 1],
          verts[(start + 1) * 2], verts[(start + 1) * 2 + 1]);
      return;
    }

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

  /// Une os traços de um contorno fechado que retrocede sobre si mesmo e os
  /// emite sem sobreposição.
  ///
  /// Todos os traços estão sobre a reta que vai de (`x0`,`y0`) a (`x1`,`y1`),
  /// então cada um é um intervalo do parâmetro `t` dessa reta e a união é uma
  /// fusão de intervalos ordenados. Unir antes de traçar preserva a região
  /// pintada: dois traços que se sobrepõem e cujas pontas levam cap `round` ou
  /// `square` cobrem exatamente o mesmo que o intervalo unido com o cap nas
  /// pontas de fora, porque o cap interno cai dentro da união.
  static void _emitMergedRetrace(BLPath out, List<_DashRun> runs, double x0,
      double y0, double x1, double y1) {
    final dx = x1 - x0, dy = y1 - y0;
    final lenSq = dx * dx + dy * dy;
    if (lenSq < 1e-24) return;
    double paramOf(double x, double y) =>
        ((x - x0) * dx + (y - y0) * dy) / lenSq;

    final spans = <List<double>>[];
    final dots = <_DashRun>[];
    for (final run in runs) {
      if (run.vertexCount < 2) {
        dots.add(run);
        continue;
      }
      // Varre TODOS os vértices, não só as pontas: o traço que atravessa p1
      // dá a volta ali e volta pelo mesmo lado, então é um "V" cujas pontas
      // ficam ambas aquém do vértice. Olhar só primeiro e último perderia
      // justamente o trecho até p1.
      var lo = double.infinity, hi = double.negativeInfinity;
      for (var k = 0; k < run.vertexCount; k++) {
        final t = paramOf(run.points[k * 2], run.points[k * 2 + 1]);
        if (t < lo) lo = t;
        if (t > hi) hi = t;
      }
      if (hi - lo <= 1e-12) {
        dots.add(run);
        continue;
      }
      spans.add(<double>[lo, hi]);
    }

    spans.sort((a, b) => a[0].compareTo(b[0]));
    final merged = <List<double>>[];
    for (final span in spans) {
      if (merged.isNotEmpty && span[0] <= merged.last[1] + 1e-12) {
        if (span[1] > merged.last[1]) merged.last[1] = span[1];
      } else {
        merged.add(span);
      }
    }

    for (final span in merged) {
      out.moveTo(x0 + dx * span[0], y0 + dy * span[0]);
      out.lineTo(x0 + dx * span[1], y0 + dy * span[1]);
    }

    // Um ponto do padrão que caia dentro de um traço já pintado não acrescenta
    // nada e só traria de volta a sobreposição que acabamos de desfazer.
    for (final dot in dots) {
      final t = paramOf(dot.firstX, dot.firstY);
      var covered = false;
      for (final span in merged) {
        if (t >= span[0] - 1e-12 && t <= span[1] + 1e-12) {
          covered = true;
          break;
        }
      }
      if (!covered) _emitDot(out, dot);
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
