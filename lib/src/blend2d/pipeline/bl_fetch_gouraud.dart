import 'dart:typed_data';

import '../core/bl_types.dart';

/// Interpolação de cor por vértice (Gouraud) para um único triângulo.
///
/// A cor dentro de um triângulo é uma função **afim** de `(x, y)`: cada canal
/// varia linearmente, logo basta pré-computar o valor num vértice e os dois
/// gradientes `d/dx` e `d/dy` para obter a cor de qualquer pixel com duas
/// multiplicações e duas somas — sem recalcular coordenadas baricêntricas por
/// pixel.
///
/// Os canais são interpolados em espaço **pré-multiplicado** e devolvidos em
/// ARGB32 de alfa reto, que é o formato que [BLPixelFetcher] deve produzir.
/// Quando os três vértices têm o mesmo alfa — o caso dos sombreamentos PDF de
/// tipo 4 a 7, sempre opacos — isso coincide exatamente com a interpolação
/// direta dos componentes; quando não têm, pré-multiplicar é o único jeito de
/// não escurecer a transição em direção ao vértice transparente.
///
/// Uso típico: passar [fetch] a `BLAnalyticRasterizer.drawPolygonFetched` com
/// o triângulo como geometria.
class BLGouraudFetcher {
  /// Coeficientes do plano de cada canal, na ordem
  /// `[base, d/dx, d/dy]` para A, R, G e B pré-multiplicados.
  final Float64List _plane;

  /// Vértice de referência: os planos são avaliados em `(px - _ox, py - _oy)`.
  final double _ox;
  final double _oy;

  /// Triângulo degenerado (área nula): a cor vira constante.
  final bool _flat;
  final int _flatColor;

  BLGouraudFetcher._(
    this._plane,
    this._ox,
    this._oy,
    this._flat,
    this._flatColor,
  );

  /// Constrói o fetcher para o triângulo `(x0,y0)-(x1,y1)-(x2,y2)` com as
  /// cores ARGB32 [c0], [c1] e [c2] nos respectivos vértices.
  ///
  /// As coordenadas devem estar no **espaço de device** — o mesmo `(x, y)` que
  /// o rasterizador passa a [fetch].
  factory BLGouraudFetcher(
    double x0,
    double y0,
    BLColor c0,
    double x1,
    double y1,
    BLColor c1,
    double x2,
    double y2,
    BLColor c2,
  ) {
    final dx1 = x1 - x0;
    final dy1 = y1 - y0;
    final dx2 = x2 - x0;
    final dy2 = y2 - y0;
    final det = dx1 * dy2 - dx2 * dy1;

    final plane = Float64List(12);

    // Uma aresta colinear (ou um triângulo de área nula, que aparece nas bordas
    // degeneradas de um patch de Coons) não define um plano: qualquer
    // gradiente resolveria o sistema. Cair na média dos três vértices é a
    // única resposta estável — e é exatamente a cor certa quando os três
    // vértices coincidem.
    if (det == 0.0 || !det.isFinite) {
      return BLGouraudFetcher._(plane, x0, y0, true, _averageColor(c0, c1, c2));
    }

    final invDet = 1.0 / det;
    for (int ch = 0; ch < 4; ch++) {
      final v0 = _channelPremul(c0, ch);
      final v1 = _channelPremul(c1, ch);
      final v2 = _channelPremul(c2, ch);
      final d1 = v1 - v0;
      final d2 = v2 - v0;
      final o = ch * 3;
      plane[o] = v0;
      plane[o + 1] = (d1 * dy2 - d2 * dy1) * invDet; // d/dx
      plane[o + 2] = (dx1 * d2 - dx2 * d1) * invDet; // d/dy
    }

    return BLGouraudFetcher._(plane, x0, y0, false, 0);
  }

  /// Cor interpolada no centro do pixel `(x, y)`.
  @pragma('vm:prefer-inline')
  BLColor fetch(int x, int y) {
    if (_flat) return _flatColor;
    return evaluate(x + 0.5, y + 0.5);
  }

  /// Cor interpolada num ponto contínuo qualquer do plano do triângulo.
  ///
  /// Fora do triângulo o plano é extrapolado; os canais são saturados em
  /// `0..255`, então o resultado continua sendo uma cor válida. É o que
  /// mantém a franja antisserrilhada da silhueta com a cor da borda em vez de
  /// um buraco.
  BLColor evaluate(double px, double py) {
    if (_flat) return _flatColor;
    final dx = px - _ox;
    final dy = py - _oy;
    final p = _plane;

    int a = _round(p[0] + p[1] * dx + p[2] * dy);
    if (a < 0) a = 0;
    if (a > 255) a = 255;
    if (a == 0) return 0;

    int r = _round(p[3] + p[4] * dx + p[5] * dy);
    int g = _round(p[6] + p[7] * dx + p[8] * dy);
    int b = _round(p[9] + p[10] * dx + p[11] * dy);

    if (a != 255) {
      // Volta de pré-multiplicado para alfa reto.
      r = (r * 255) ~/ a;
      g = (g * 255) ~/ a;
      b = (b * 255) ~/ a;
    }
    if (r < 0) r = 0;
    if (r > 255) r = 255;
    if (g < 0) g = 0;
    if (g > 255) g = 255;
    if (b < 0) b = 0;
    if (b > 255) b = 255;

    return (a << 24) | (r << 16) | (g << 8) | b;
  }
}

/// Interpolação de cor por vértice sobre uma **malha inteira** de triângulos.
///
/// Existe para resolver um problema que rasterizar triângulo a triângulo não
/// resolve: dois triângulos antisserrilhados que compartilham uma aresta,
/// compostos um depois do outro com `srcOver`, deixam uma costura clara na
/// junção — cada um cobre a aresta pela metade, e meia cobertura mais meia
/// cobertura sobre o fundo não dá cobertura cheia. Numa malha de sombreamento
/// PDF (tipos 4, 5, 6 e 7) isso vira uma grade visível sobre a superfície.
///
/// A solução é rasterizar a malha **numa passada só**, passando cada triângulo
/// como um contorno da mesma geometria com regra `nonZero`: o rasterizador
/// analítico acumula área com sinal, e uma aresta interna percorrida em
/// sentidos opostos pelos dois triângulos vizinhos se cancela exatamente. O
/// antisserrilhamento sobra só na silhueta externa, que é onde ele deve estar.
/// Este fetcher é a outra metade: para cada pixel coberto, decide a que
/// triângulo ele pertence e devolve a cor interpolada.
///
/// Para o cancelamento funcionar, os triângulos precisam ter orientação
/// consistente; [BLGouraudMeshFetcher] normaliza a orientação na construção e
/// expõe o resultado em [orientedVertices], que é a lista de vértices que deve
/// ser entregue ao rasterizador.
class BLGouraudMeshFetcher {
  /// Vértices dos triângulos em espaço de device, 6 doubles por triângulo,
  /// todos com a **mesma orientação** (área com sinal positivo na convenção
  /// de device, isto é, com o eixo Y apontando para baixo).
  final Float64List orientedVertices;

  /// Coeficientes de plano: 12 doubles por triângulo, mesmo layout de
  /// [BLGouraudFetcher].
  final Float64List _planes;

  /// `[ox, oy]` por triângulo: o vértice de referência dos planos.
  final Float64List _origins;

  /// Funções de aresta pré-computadas para localizar o ponto: por triângulo,
  /// `[ax, ay, bx, by, cx, cy, invArea2]`.
  final Float64List _edges;

  /// Triângulos com área nula: cor constante em [_flatColors].
  final Uint8List _flat;
  final Uint32List _flatColors;

  final int triangleCount;

  /// Índice CSR por linha de scanline: [_rowStart] tem `_rowCount + 1`
  /// entradas e aponta para faixas de [_rowTris].
  final Int32List _rowStart;
  final Int32List _rowTris;
  final int _rowY0;
  final int _rowCount;

  /// Último triângulo que respondeu. O rasterizador varre em ordem de
  /// scanline, então o vizinho do pixel anterior acerta quase sempre.
  int _last = 0;

  /// Linha corrente e posição dentro do bucket dela.
  ///
  /// Os buckets são ordenados por `minX`, e o rasterizador varre x crescente,
  /// então retomar a busca de onde ela parou transforma a localização do ponto
  /// em amortizado O(1): sem isso, cada troca de triângulo relia o bucket
  /// inteiro (dezenas de triângulos por linha numa malha fina), e a busca
  /// dominava o custo por pixel.
  int _cursorRow = -1;
  int _cursor = 0;

  /// Estado do run incremental: baricêntricas e canais pré-multiplicados no
  /// pixel `(_seqX, _seqY)`, mais os respectivos incrementos por pixel em x.
  bool _seqValid = false;
  int _seqX = 0;
  int _seqY = 0;
  double _w0 = 0, _w1 = 0, _w2 = 0;
  double _dw0 = 0, _dw1 = 0, _dw2 = 0;
  double _ca = 0, _cr = 0, _cg = 0, _cb = 0;
  double _dca = 0, _dcr = 0, _dcg = 0, _dcb = 0;

  BLGouraudMeshFetcher._(
    this.orientedVertices,
    this._planes,
    this._origins,
    this._edges,
    this._flat,
    this._flatColors,
    this.triangleCount,
    this._rowStart,
    this._rowTris,
    this._rowY0,
    this._rowCount,
  );

  /// Monta a malha.
  ///
  /// [xy] são coordenadas de device intercaladas `x, y` (um par por vértice),
  /// [colors] tem uma cor ARGB32 por vértice, e [indices] três índices por
  /// triângulo. [indices] pode ser omitido, e nesse caso [xy] é lido como uma
  /// sequência direta de triângulos.
  factory BLGouraudMeshFetcher(
    Float64List xy,
    Uint32List colors, [
    Int32List? indices,
  ]) {
    final vertexCount = xy.length ~/ 2;
    if (colors.length < vertexCount) {
      throw ArgumentError(
        'colors tem ${colors.length} entradas para $vertexCount vértices',
      );
    }

    final Int32List idx;
    if (indices != null) {
      if (indices.length % 3 != 0) {
        throw ArgumentError(
          'indices tem ${indices.length} entradas, que não é múltiplo de 3',
        );
      }
      idx = indices;
    } else {
      if (vertexCount % 3 != 0) {
        throw ArgumentError(
          'sem indices, xy precisa de um múltiplo de 3 vértices; '
          'veio $vertexCount',
        );
      }
      idx = Int32List(vertexCount);
      for (int i = 0; i < vertexCount; i++) {
        idx[i] = i;
      }
    }

    final triCount = idx.length ~/ 3;
    final verts = Float64List(triCount * 6);
    final planes = Float64List(triCount * 12);
    final origins = Float64List(triCount * 2);
    final edges = Float64List(triCount * 7);
    final flat = Uint8List(triCount);
    final flatColors = Uint32List(triCount);

    double minY = double.infinity;
    double maxY = double.negativeInfinity;

    for (int t = 0; t < triCount; t++) {
      int i0 = idx[t * 3];
      int i1 = idx[t * 3 + 1];
      int i2 = idx[t * 3 + 2];
      if (i0 < 0 ||
          i1 < 0 ||
          i2 < 0 ||
          i0 >= vertexCount ||
          i1 >= vertexCount ||
          i2 >= vertexCount) {
        throw ArgumentError(
          'índice fora da faixa no triângulo $t: ($i0, $i1, $i2) para '
          '$vertexCount vértices',
        );
      }

      double x0 = xy[i0 * 2], y0 = xy[i0 * 2 + 1];
      double x1 = xy[i1 * 2], y1 = xy[i1 * 2 + 1];
      double x2 = xy[i2 * 2], y2 = xy[i2 * 2 + 1];

      double area2 = (x1 - x0) * (y2 - y0) - (x2 - x0) * (y1 - y0);
      if (area2 < 0) {
        // Inverte para a orientação canônica. O rasterizador acumula área com
        // sinal; só com orientação uniforme a aresta compartilhada é
        // percorrida em sentidos opostos pelos dois vizinhos e se cancela. Sem
        // isso a costura volta.
        final tx = x1, ty = y1, ti = i1;
        x1 = x2;
        y1 = y2;
        i1 = i2;
        x2 = tx;
        y2 = ty;
        i2 = ti;
        area2 = -area2;
      }

      final v = t * 6;
      verts[v] = x0;
      verts[v + 1] = y0;
      verts[v + 2] = x1;
      verts[v + 3] = y1;
      verts[v + 4] = x2;
      verts[v + 5] = y2;

      if (y0 < minY) minY = y0;
      if (y1 < minY) minY = y1;
      if (y2 < minY) minY = y2;
      if (y0 > maxY) maxY = y0;
      if (y1 > maxY) maxY = y1;
      if (y2 > maxY) maxY = y2;

      final e = t * 7;
      edges[e] = x0;
      edges[e + 1] = y0;
      edges[e + 2] = x1;
      edges[e + 3] = y1;
      edges[e + 4] = x2;
      edges[e + 5] = y2;
      edges[e + 6] = area2 > 0 ? 1.0 / area2 : 0.0;

      final c0 = colors[i0], c1 = colors[i1], c2 = colors[i2];
      origins[t * 2] = x0;
      origins[t * 2 + 1] = y0;

      if (area2 == 0.0 || !area2.isFinite) {
        flat[t] = 1;
        flatColors[t] = _averageColor(c0, c1, c2);
        continue;
      }

      final dx1 = x1 - x0, dy1 = y1 - y0;
      final dx2 = x2 - x0, dy2 = y2 - y0;
      final invDet = 1.0 / area2;
      for (int ch = 0; ch < 4; ch++) {
        final v0 = _channelPremul(c0, ch);
        final d1 = _channelPremul(c1, ch) - v0;
        final d2 = _channelPremul(c2, ch) - v0;
        final o = t * 12 + ch * 3;
        planes[o] = v0;
        planes[o + 1] = (d1 * dy2 - d2 * dy1) * invDet;
        planes[o + 2] = (dx1 * d2 - dx2 * d1) * invDet;
      }
    }

    // Índice por scanline. O bucket de uma linha lista os triângulos cuja
    // caixa em Y cruza aquela linha, ordenados por minX; com o cache de último
    // acerto e o cursor de busca, a varredura dentro do bucket é amortizada.
    int rowY0 = 0;
    int rowCount = 0;
    Int32List rowStart = Int32List(1);
    Int32List rowTris = Int32List(0);

    if (triCount > 0 && minY.isFinite && maxY.isFinite) {
      rowY0 = minY.floor();
      final rowY1 = maxY.ceil();
      rowCount = rowY1 - rowY0 + 1;
      if (rowCount < 1) rowCount = 1;
      // Malha absurdamente alta: o índice não vale a memória, cai na busca
      // linear com cache.
      if (rowCount > 1 << 16) {
        rowCount = 0;
      }
    }

    if (rowCount > 0) {
      final counts = Int32List(rowCount + 1);
      for (int t = 0; t < triCount; t++) {
        final v = t * 6;
        final a = verts[v + 1], b = verts[v + 3], c = verts[v + 5];
        int lo = _minOf3(a, b, c).floor() - rowY0;
        int hi = _maxOf3(a, b, c).ceil() - rowY0;
        if (lo < 0) lo = 0;
        if (hi >= rowCount) hi = rowCount - 1;
        for (int r = lo; r <= hi; r++) {
          counts[r]++;
        }
      }
      rowStart = Int32List(rowCount + 1);
      int acc = 0;
      for (int r = 0; r < rowCount; r++) {
        rowStart[r] = acc;
        acc += counts[r];
      }
      rowStart[rowCount] = acc;
      rowTris = Int32List(acc);
      final cursor = Int32List(rowCount);
      for (int t = 0; t < triCount; t++) {
        final v = t * 6;
        final a = verts[v + 1], b = verts[v + 3], c = verts[v + 5];
        int lo = _minOf3(a, b, c).floor() - rowY0;
        int hi = _maxOf3(a, b, c).ceil() - rowY0;
        if (lo < 0) lo = 0;
        if (hi >= rowCount) hi = rowCount - 1;
        for (int r = lo; r <= hi; r++) {
          rowTris[rowStart[r] + cursor[r]++] = t;
        }
      }

      // Ordena cada bucket por minX. Combinado com o cursor de busca do
      // fetch, isso faz a localização do ponto avançar junto com a varredura
      // em x em vez de reler o bucket a cada troca de triângulo.
      final minX = Float64List(triCount);
      for (int t = 0; t < triCount; t++) {
        final v = t * 6;
        minX[t] = _minOf3(verts[v], verts[v + 2], verts[v + 4]);
      }
      final scratch = <int>[];
      for (int r = 0; r < rowCount; r++) {
        final s = rowStart[r];
        final e = rowStart[r + 1];
        if (e - s < 2) continue;
        scratch
          ..clear()
          ..addAll(rowTris.getRange(s, e));
        scratch.sort((a, b) => minX[a].compareTo(minX[b]));
        for (int i = 0; i < scratch.length; i++) {
          rowTris[s + i] = scratch[i];
        }
      }
    } else {
      rowStart = Int32List(1);
      rowTris = Int32List(0);
      rowCount = 0;
    }

    return BLGouraudMeshFetcher._(
      verts,
      planes,
      origins,
      edges,
      flat,
      flatColors,
      triCount,
      rowStart,
      rowTris,
      rowY0,
      rowCount,
    );
  }

  /// Quantidade de contornos (um por triângulo) para
  /// `drawPolygonFetched(contourVertexCounts: ...)`.
  List<int> get contourVertexCounts => List<int>.filled(triangleCount, 3);

  /// Cor interpolada no centro do pixel `(x, y)`.
  BLColor fetch(int x, int y) {
    if (triangleCount == 0) return 0;

    // 0. Caminho incremental. O rasterizador percorre runs de x consecutivos
    // dentro de uma scanline, e tanto as coordenadas baricêntricas quanto os
    // canais de cor são afins em x: avançar um pixel é somar uma constante.
    // Enquanto as três baricêntricas continuarem não negativas, o pixel ainda
    // está no mesmo triângulo e nada precisa ser localizado nem reavaliado.
    if (_seqValid && y == _seqY && x == _seqX + 1) {
      final w0 = _w0 + _dw0;
      final w1 = _w1 + _dw1;
      final w2 = _w2 + _dw2;
      if (w0 >= 0.0 && w1 >= 0.0 && w2 >= 0.0) {
        _w0 = w0;
        _w1 = w1;
        _w2 = w2;
        _seqX = x;
        _ca += _dca;
        _cr += _dcr;
        _cg += _dcg;
        _cb += _dcb;
        return _pack(_ca, _cr, _cg, _cb);
      }
    }

    final px = x + 0.5;
    final py = y + 0.5;

    // 1. O triângulo do pixel anterior.
    if (_contains(_last, px, py)) return _startRun(_last, x, y, px, py);

    // 2. Os triângulos desta scanline, a partir de onde a busca parou.
    int best = -1;
    double bestScore = double.negativeInfinity;
    if (_rowCount > 0) {
      int row = y - _rowY0;
      if (row < 0) row = 0;
      if (row >= _rowCount) row = _rowCount - 1;
      final start = _rowStart[row];
      final end = _rowStart[row + 1];
      if (row != _cursorRow || _cursor < start || _cursor >= end) {
        _cursorRow = row;
        _cursor = start;
      }
      for (int n = 0, i = _cursor; n < end - start; n++) {
        final t = _rowTris[i];
        final score = _score(t, px, py);
        if (score >= 0.0) {
          _last = t;
          _cursor = i;
          return _startRun(t, x, y, px, py);
        }
        if (score > bestScore) {
          bestScore = score;
          best = t;
        }
        i++;
        if (i >= end) i = start;
      }
    } else {
      for (int t = 0; t < triangleCount; t++) {
        final score = _score(t, px, py);
        if (score >= 0.0) {
          _last = t;
          return _startRun(t, x, y, px, py);
        }
        if (score > bestScore) {
          bestScore = score;
          best = t;
        }
      }
    }

    // 3. Nenhum triângulo contém o centro do pixel. Isso acontece na franja
    // antisserrilhada da silhueta, onde o pixel é coberto em parte mas o
    // centro cai para fora. Extrapolar o plano do triângulo mais próximo é o
    // que faz a borda continuar com a cor da borda em vez de um buraco.
    if (best < 0) {
      best = _nearestGlobal(px, py);
    }
    _last = best;
    return _startRun(best, x, y, px, py);
  }

  /// Arma o run incremental no triângulo [t], no pixel `(x, y)` cujo centro é
  /// `(px, py)`, e devolve a cor daquele pixel.
  ///
  /// Um triângulo degenerado não tem baricêntricas: o run é desarmado e a cor
  /// constante é devolvida direto.
  BLColor _startRun(int t, int x, int y, double px, double py) {
    if (_flat[t] != 0) {
      _seqValid = false;
      return _flatColors[t];
    }

    final e = t * 7;
    final inv = _edges[e + 6];
    final x0 = _edges[e], y0 = _edges[e + 1];
    final x1 = _edges[e + 2], y1 = _edges[e + 3];
    final x2 = _edges[e + 4], y2 = _edges[e + 5];

    _w0 = ((x2 - x1) * (py - y1) - (y2 - y1) * (px - x1)) * inv;
    _w1 = ((x0 - x2) * (py - y2) - (y0 - y2) * (px - x2)) * inv;
    _w2 = ((x1 - x0) * (py - y0) - (y1 - y0) * (px - x0)) * inv;
    _dw0 = -(y2 - y1) * inv;
    _dw1 = -(y0 - y2) * inv;
    _dw2 = -(y1 - y0) * inv;

    final p = _planes;
    final o = t * 12;
    final dx = px - _origins[t * 2];
    final dy = py - _origins[t * 2 + 1];
    _ca = p[o] + p[o + 1] * dx + p[o + 2] * dy;
    _cr = p[o + 3] + p[o + 4] * dx + p[o + 5] * dy;
    _cg = p[o + 6] + p[o + 7] * dx + p[o + 8] * dy;
    _cb = p[o + 9] + p[o + 10] * dx + p[o + 11] * dy;
    _dca = p[o + 1];
    _dcr = p[o + 4];
    _dcg = p[o + 7];
    _dcb = p[o + 10];

    _seqValid = true;
    _seqX = x;
    _seqY = y;
    return _pack(_ca, _cr, _cg, _cb);
  }

  /// Converte os canais pré-multiplicados contínuos em ARGB32 de alfa reto.
  ///
  /// Satura em double antes de converter para int: assim `toInt()` sempre
  /// recebe um valor não negativo e finito, onde truncar é o mesmo que
  /// arredondar para baixo — e some o `isFinite` e o `floor()` do caminho
  /// genérico, que aqui rodam quatro vezes por pixel.
  static BLColor _pack(double ap, double rp, double gp, double bp) {
    // `!(x > y)` em vez de `x <= y` para tratar NaN como saturação inferior.
    final int a = !(ap > 0.0) ? 0 : (ap >= 254.5 ? 255 : (ap + 0.5).toInt());
    if (a == 0) return 0;

    int r = !(rp > 0.0) ? 0 : (rp >= 254.5 ? 255 : (rp + 0.5).toInt());
    int g = !(gp > 0.0) ? 0 : (gp >= 254.5 ? 255 : (gp + 0.5).toInt());
    int b = !(bp > 0.0) ? 0 : (bp >= 254.5 ? 255 : (bp + 0.5).toInt());

    if (a != 255) {
      // Volta de pré-multiplicado para alfa reto.
      r = (r * 255) ~/ a;
      g = (g * 255) ~/ a;
      b = (b * 255) ~/ a;
      if (r > 255) r = 255;
      if (g > 255) g = 255;
      if (b > 255) b = 255;
    }

    return (a << 24) | (r << 16) | (g << 8) | b;
  }

  /// Quão "dentro" de [t] o ponto está: >= 0 significa dentro, e valores
  /// negativos crescem em direção ao triângulo mais próximo.
  double _score(int t, double px, double py) {
    final e = t * 7;
    final inv = _edges[e + 6];
    if (inv == 0.0) {
      // Triângulo degenerado: nunca "contém" nada, mas ainda pode ser o mais
      // próximo. Usa a distância ao primeiro vértice, negada.
      final dx = px - _edges[e];
      final dy = py - _edges[e + 1];
      return -(dx * dx + dy * dy) - 1e9;
    }
    final x0 = _edges[e], y0 = _edges[e + 1];
    final x1 = _edges[e + 2], y1 = _edges[e + 3];
    final x2 = _edges[e + 4], y2 = _edges[e + 5];

    final w0 = ((x2 - x1) * (py - y1) - (y2 - y1) * (px - x1)) * inv;
    final w1 = ((x0 - x2) * (py - y2) - (y0 - y2) * (px - x2)) * inv;
    final w2 = ((x1 - x0) * (py - y0) - (y1 - y0) * (px - x0)) * inv;

    double m = w0;
    if (w1 < m) m = w1;
    if (w2 < m) m = w2;
    return m;
  }

  bool _contains(int t, double px, double py) => _score(t, px, py) >= 0.0;

  int _nearestGlobal(double px, double py) {
    int best = 0;
    double bestScore = double.negativeInfinity;
    for (int t = 0; t < triangleCount; t++) {
      final score = _score(t, px, py);
      if (score > bestScore) {
        bestScore = score;
        best = t;
      }
    }
    return best;
  }

  /// Cor da malha num ponto contínuo qualquer, sem usar nem alterar o estado
  /// incremental de [fetch].
  ///
  /// É a referência do caminho rápido: `fetch(x, y)` tem de concordar com
  /// `colorAt(x + 0.5, y + 0.5)`. Fora da malha, devolve a extrapolação do
  /// triângulo mais próximo, que é o que mantém a franja antisserrilhada com a
  /// cor da borda.
  BLColor colorAt(double px, double py) {
    if (triangleCount == 0) return 0;
    int best = -1;
    double bestScore = double.negativeInfinity;
    for (int t = 0; t < triangleCount; t++) {
      final score = _score(t, px, py);
      if (score >= 0.0) {
        best = t;
        break;
      }
      if (score > bestScore) {
        bestScore = score;
        best = t;
      }
    }
    return _evaluate(best, px, py);
  }

  BLColor _evaluate(int t, double px, double py) {
    if (_flat[t] != 0) return _flatColors[t];
    final dx = px - _origins[t * 2];
    final dy = py - _origins[t * 2 + 1];
    final p = _planes;
    final o = t * 12;
    return _pack(
      p[o] + p[o + 1] * dx + p[o + 2] * dy,
      p[o + 3] + p[o + 4] * dx + p[o + 5] * dy,
      p[o + 6] + p[o + 7] * dx + p[o + 8] * dy,
      p[o + 9] + p[o + 10] * dx + p[o + 11] * dy,
    );
  }
}

/// Canal [ch] (0=A, 1=R, 2=G, 3=B) de [argb] em espaço pré-multiplicado.
double _channelPremul(int argb, int ch) {
  final a = (argb >>> 24) & 0xFF;
  if (ch == 0) return a.toDouble();
  final shift = ch == 1 ? 16 : (ch == 2 ? 8 : 0);
  final v = (argb >>> shift) & 0xFF;
  if (a == 255) return v.toDouble();
  return v * a / 255.0;
}

int _averageColor(int c0, int c1, int c2) {
  int avg(int shift) {
    final s = ((c0 >>> shift) & 0xFF) +
        ((c1 >>> shift) & 0xFF) +
        ((c2 >>> shift) & 0xFF);
    return (s + 1) ~/ 3;
  }

  return (avg(24) << 24) | (avg(16) << 16) | (avg(8) << 8) | avg(0);
}

@pragma('vm:prefer-inline')
int _round(double v) => v.isFinite ? (v + 0.5).floor() : 0;

@pragma('vm:prefer-inline')
double _minOf3(double a, double b, double c) {
  var m = a;
  if (b < m) m = b;
  if (c < m) m = c;
  return m;
}

@pragma('vm:prefer-inline')
double _maxOf3(double a, double b, double c) {
  var m = a;
  if (b > m) m = b;
  if (c > m) m = c;
  return m;
}
