import 'dart:math' as math;

import '../core/bl_types.dart';
import 'bl_path.dart';

/// Port do PathStroker do Blend2D para Dart (Fase 5).
///
/// Transforma um [BLPath] de entrada em um [BLPath] de saída representando
/// o outline do stroke. O resultado pode ser preenchido (`fillPath`) com
/// [BLFillRule.nonZero] para produzir o stroke visual.
///
/// Suporta:
///  - Caps: butt, square, round, roundRev, triangle, triangleRev
///  - Joins: bevel, miterBevel, miterRound, miterClip, round
///  - Contornos abertos e fechados
///
/// Inspirado em: `blend2d/core/pathstroke.cpp`
class BLStroker {
  static const double _kEps = 1e-10;
  static const double _kEpsSq = 1e-20;

  // ---------------------------------------------------------------------------
  // API pública
  // ---------------------------------------------------------------------------

  /// Transforma [input] em um outline de stroke de acordo com [options].
  ///
  /// O resultado é um [BLPath] que deve ser preenchido com fill rule
  /// [BLFillRule.nonZero] para produzir o stroke visual correto.
  static BLPath strokePath(BLPath input, BLStrokeOptions options) {
    final data = input.toPathData();
    final out = BLPath();
    final verts = data.vertices;
    if (verts.isEmpty) return out;

    final counts = data.contourVertexCounts ?? [verts.length ~/ 2];
    final closedFlags = data.contourClosed;
    // width <= 0 não significa "não desenhar": no PDF `0 w` pede a linha mais
    // fina que o device consegue produzir. BLStrokeOptions.minimumWidth carrega
    // essa largura (o chamador que conhece a CTM converte 1 pixel de device
    // para unidades de usuário antes de chamar aqui).
    final hw = options.effectiveWidth * 0.5;
    if (hw <= 0) return out;

    // Limite de miter ao quadrado relativo a hw:
    // |k|^2 <= (miterLimit * hw)^2
    final miterLimitSq = options.miterLimit * options.miterLimit * hw * hw;

    int offset = 0;
    for (int ci = 0; ci < counts.length; ci++) {
      final int n = counts[ci];
      final bool isClosed = (closedFlags != null && ci < closedFlags.length)
          ? closedFlags[ci]
          : false;
      if (n >= 2) {
        _strokeContour(
            verts, offset, n, isClosed, hw, miterLimitSq, options, out);
      }
      offset += n;
    }

    return out;
  }

  // ---------------------------------------------------------------------------
  // Processamento de um único contorno
  // ---------------------------------------------------------------------------

  static void _strokeContour(
    List<double> verts,
    int start,
    int n,
    bool isClosed,
    double hw,
    double miterLimitSq,
    BLStrokeOptions options,
    BLPath out,
  ) {
    // Extrair vértices do contorno em arrays locais
    final px = List<double>.filled(n, 0.0);
    final py = List<double>.filled(n, 0.0);
    for (int i = 0; i < n; i++) {
      px[i] = verts[(start + i) * 2];
      py[i] = verts[(start + i) * 2 + 1];
    }

    // Computar normais por segmento.
    // nx[i], ny[i] = normal esquerda unitária do segmento de p[i] a p[(i+1)%n].
    final int segCount = isClosed ? n : n - 1;
    final nx = List<double>.filled(n, 0.0);
    final ny = List<double>.filled(n, 0.0);
    int lastValidSeg = -1;
    for (int i = 0; i < segCount; i++) {
      final j = (i + 1) % n;
      final dx = px[j] - px[i];
      final dy = py[j] - py[i];
      final lenSq = dx * dx + dy * dy;
      if (lenSq < _kEpsSq) {
        // Segmento degenerado: herdar normal anterior
        if (lastValidSeg >= 0) {
          nx[i] = nx[lastValidSeg];
          ny[i] = ny[lastValidSeg];
        }
        continue;
      }
      final len = math.sqrt(lenSq);
      nx[i] = -dy / len;
      ny[i] = dx / len;
      lastValidSeg = i;
    }
    // Para contornos abertos, estender a normal final para o ponto último
    if (!isClosed && n >= 2) {
      nx[n - 1] = nx[n - 2];
      ny[n - 1] = ny[n - 2];
    }

    // Lados A (esquerdo / +hw) e B (direito / -hw)
    final aVerts = <double>[];
    final bVerts = <double>[];

    for (int i = 0; i < n; i++) {
      final bool isFirst = !isClosed && i == 0;
      final bool isLast = !isClosed && i == n - 1;

      if (isFirst) {
        aVerts.add(px[0] + hw * nx[0]);
        aVerts.add(py[0] + hw * ny[0]);
        bVerts.add(px[0] - hw * nx[0]);
        bVerts.add(py[0] - hw * ny[0]);
        continue;
      }

      if (isLast) {
        final int lastSeg = n - 2;
        aVerts.add(px[n - 1] + hw * nx[lastSeg]);
        aVerts.add(py[n - 1] + hw * ny[lastSeg]);
        bVerts.add(px[n - 1] - hw * nx[lastSeg]);
        bVerts.add(py[n - 1] - hw * ny[lastSeg]);
        continue;
      }

      // Vértice com join
      final int prevSeg = isClosed ? (i - 1 + n) % n : i - 1;
      final int currSeg = i; // segmento de saída a partir de p[i]

      final double npx = nx[prevSeg], npy = ny[prevSeg];
      final double nnx = nx[currSeg], nny = ny[currSeg];

      // Cross: > 0 → vira esquerda (A é externo); < 0 → vira direita (B é externo)
      final double cross = npx * nny - npy * nnx;

      // Vetor bissetriz: m = np + nn
      final double mx = npx + nnx, my = npy + nny;
      final double mLenSq = mx * mx + my * my;

      if (mLenSq < _kEps) {
        // Normais anti-paralelas: U-turn de 180°
        // Adicionar ponto intermediário por segmento
        aVerts.add(px[i] + hw * npx);
        aVerts.add(py[i] + hw * npy);
        aVerts.add(px[i] + hw * nnx);
        aVerts.add(py[i] + hw * nny);
        bVerts.add(px[i] - hw * npx);
        bVerts.add(py[i] - hw * npy);
        bVerts.add(px[i] - hw * nnx);
        bVerts.add(py[i] - hw * nny);
        continue;
      }

      // Ponto de miter: interseção das duas retas offset, medida a partir do
      // vértice. Com np e nn unitárias, ela vale `hw * m / (1 + np.nn)`, e
      // como |m|^2 = 2 * (1 + np.nn) isso é `2 * hw * m / |m|^2`. O fator 2
      // estava faltando: o miter saía na METADE da distância correta, o que
      // encolhia todo contorno fechado (e fazia o limite de miter só disparar
      // com o dobro do ângulo).
      final double kx = 2.0 * mx * hw / mLenSq;
      final double ky = 2.0 * my * hw / mLenSq;
      final double kLenSq = kx * kx + ky * ky;

      // `cross` é o seno do ângulo de giro medido de np para nn. Girar para um
      // lado abre um vão do lado OPOSTO: quem anda e vira à esquerda deixa a
      // quina para a direita. Portanto cross > 0 (giro à esquerda) põe o join
      // no lado B, não no lado A. Estava trocado, e o efeito era o contrário
      // do pretendido — a quina externa recebia o ponto de miter (que a
      // encolhia) e o lado de dentro recebia o bevel/round.
      if (cross >= 0.0) {
        // Vira para o lado de A: B é o externo → join; A é o interno.
        // Atenção ao sinal: `_addOuterJoin` já multiplica a normal pela
        // meia-largura recebida, então o lado B quer `-hw` com as normais
        // ORIGINAIS. Negar os dois se cancelava e devolvia os pontos do lado
        // A — por isso bevel e round saíam deformados neste ramo.
        _addOuterJoin(bVerts, px[i], py[i], -hw, npx, npy, nnx, nny, -kx, -ky,
            kLenSq, miterLimitSq, options.join);
        _addInnerJoin(aVerts, px[i], py[i], kx, ky);
      } else {
        // Vira para o lado de B: A é o externo → join; B é o interno.
        _addOuterJoin(aVerts, px[i], py[i], hw, npx, npy, nnx, nny, kx, ky,
            kLenSq, miterLimitSq, options.join);
        _addInnerJoin(bVerts, px[i], py[i], -kx, -ky);
      }
    }

    if (isClosed) {
      // Dois polígonos fechados: A (winding +1) e B invertido (winding -1).
      // Preenchimento nonZero produz o stroke anelar.
      //
      // Isso só vale enquanto A e B correm no MESMO sentido do contorno, que é
      // o que acontece quando o contorno encerra área e a meia-largura cabe
      // dentro dele. Dois casos quebram essa premissa:
      //
      //  * contorno fechado degenerado — `m l h S`, que é o que o PyMuPDF
      //    emite para toda linha: a ida e a volta se cancelam, A e B saem com
      //    a MESMA geometria percorrida ao contrário, e inverter B alinha os
      //    dois. O nonZero ainda acusa "dentro", mas o rasterizador analítico
      //    soma área com sinal e a cobertura PARCIAL das bordas é contada duas
      //    vezes: uma linha de 1 px saía com cobertura 2 e sem antisserrilhado.
      //  * meia-largura maior que o contorno — o lado de dentro se inverte e o
      //    stroke deveria virar um borrão cheio, não um anel.
      //
      // Os dois se detectam pelo mesmo sinal: se as áreas de A e B têm sinais
      // opostos (ou uma delas é nula), não há anel a formar — basta o laço
      // externo, o de maior área em módulo.
      final areaA = _signedArea2(aVerts);
      final areaB = _signedArea2(bVerts);
      if (areaA * areaB > 0.0) {
        _emitClosedPolygon(aVerts, out);
        _emitClosedPolygonReversed(bVerts, out);
      } else if (areaA.abs() >= areaB.abs()) {
        _emitClosedPolygon(aVerts, out);
      } else {
        _emitClosedPolygonReversed(bVerts, out);
      }
    } else {
      // Um polígono fechado: A → end_cap → B_reversed → start_cap
      final int na = aVerts.length ~/ 2;
      final int nb = bVerts.length ~/ 2;
      if (na < 1 || nb < 1) return;

      out.moveTo(aVerts[0], aVerts[1]);
      for (int i = 1; i < na; i++) {
        out.lineTo(aVerts[i * 2], aVerts[i * 2 + 1]);
      }

      // End cap: do último A ao último B
      // C++ Blend2D: add_cap(a_out(), _p0, b_out().vtx[-1], end_cap)
      _addCapToPath(
        out,
        aVerts[(na - 1) * 2],
        aVerts[(na - 1) * 2 + 1],
        px[n - 1],
        py[n - 1],
        bVerts[(nb - 1) * 2],
        bVerts[(nb - 1) * 2 + 1],
        options.endCap,
        hw,
      );

      // B invertido
      for (int i = nb - 2; i >= 0; i--) {
        out.lineTo(bVerts[i * 2], bVerts[i * 2 + 1]);
      }

      // Start cap: do primeiro B ao primeiro A
      // C++ Blend2D: add_cap(c_out, _pInitial, a_path[figure_offset], start_cap)
      _addCapToPath(
        out,
        bVerts[0],
        bVerts[1],
        px[0],
        py[0],
        aVerts[0],
        aVerts[1],
        options.startCap,
        hw,
      );

      out.close();
    }
  }

  // ---------------------------------------------------------------------------
  // Join externo (lado convexo)
  // Inspirado em outer_join() de pathstroke.cpp
  // ---------------------------------------------------------------------------

  static void _addOuterJoin(
    List<double> verts,
    double cx,
    double cy,
    double hw, // halfWidth com sinal (+hw = A, -hw = B)
    double npx,
    double npy, // normal inbound
    double nnx,
    double nny, // normal outbound
    double kx,
    double ky, // offset do miter para este lado
    double kLenSq,
    double miterLimitSq,
    BLStrokeJoin joinType,
  ) {
    // Ponto final do segmento anterior offset e ponto inicial do próximo
    final double peX = cx + hw * npx;
    final double peY = cy + hw * npy;
    final double nsX = cx + hw * nnx;
    final double nsY = cy + hw * nny;

    // Collinear: não precisa de join
    final double ddx = nsX - peX, ddy = nsY - peY;
    if (ddx * ddx + ddy * ddy < _kEpsSq) {
      verts.add(peX);
      verts.add(peY);
      return;
    }

    switch (joinType) {
      case BLStrokeJoin.miterBevel:
      case BLStrokeJoin.miterRound:
      case BLStrokeJoin.miterClip:
        if (kLenSq <= miterLimitSq) {
          // Miter dentro do limite
          verts.add(cx + kx);
          verts.add(cy + ky);
          return;
        }
        // Fallback por tipo
        if (joinType == BLStrokeJoin.miterRound) {
          _addArcPoints(verts, cx, cy, peX, peY, nsX, nsY);
          return;
        }
        if (joinType == BLStrokeJoin.miterClip) {
          // Clipar o miter ao limite
          final double miterLen = math.sqrt(miterLimitSq);
          final double kLen = math.sqrt(kLenSq);
          if (kLen > _kEps) {
            final double clip = miterLen / kLen;
            verts.add(cx + kx * clip);
            verts.add(cy + ky * clip);
          }
          verts.add(nsX);
          verts.add(nsY);
          return;
        }
        // miterBevel → bevel
        verts.add(peX);
        verts.add(peY);
        verts.add(nsX);
        verts.add(nsY);
        return;

      case BLStrokeJoin.round:
        _addArcPoints(verts, cx, cy, peX, peY, nsX, nsY);
        return;

      case BLStrokeJoin.bevel:
        verts.add(peX);
        verts.add(peY);
        verts.add(nsX);
        verts.add(nsY);
        return;
    }
  }

  // ---------------------------------------------------------------------------
  // Join interno (lado côncavo) — simplesmente usa a intersecção do miter
  // ---------------------------------------------------------------------------

  static void _addInnerJoin(
    List<double> verts,
    double cx,
    double cy,
    double ikx,
    double iky,
  ) {
    verts.add(cx + ikx);
    verts.add(cy + iky);
  }

  // ---------------------------------------------------------------------------
  // Arco genérico (round join / round cap)
  // Calcula pontos sobre o arco de a até b ao redor de c (short arc).
  // ---------------------------------------------------------------------------

  static void _addArcPoints(
    List<double> verts,
    double cx,
    double cy,
    double ax,
    double ay,
    double bx,
    double by,
  ) {
    final double ux = ax - cx, uy = ay - cy;
    final double vx = bx - cx, vy = by - cy;
    final double r = math.sqrt(ux * ux + uy * uy);
    if (r < _kEps) {
      verts.add(bx);
      verts.add(by);
      return;
    }

    final double startAngle = math.atan2(uy, ux);
    final double endAngle = math.atan2(vy, vx);

    // Cruzamento determina a direção do arco (short arc, convex side)
    final double crossUV = ux * vy - uy * vx;
    double deltaAngle;
    if (crossUV >= 0.0) {
      // CCW
      deltaAngle = endAngle - startAngle;
      if (deltaAngle < 0) deltaAngle += 2 * math.pi;
    } else {
      // CW
      deltaAngle = endAngle - startAngle;
      if (deltaAngle > 0) deltaAngle -= 2 * math.pi;
    }

    if (deltaAngle.abs() < _kEps) {
      verts.add(bx);
      verts.add(by);
      return;
    }

    // Subdividir a ~45° por passo para qualidade suficiente
    final int steps = math.max(1, (deltaAngle.abs() / (math.pi / 4)).ceil());
    final double step = deltaAngle / steps;

    for (int i = 1; i <= steps; i++) {
      final double angle = startAngle + i * step;
      verts.add(cx + r * math.cos(angle));
      verts.add(cy + r * math.sin(angle));
    }
  }

  // ---------------------------------------------------------------------------
  // Cap de extremidade → emite direto no BLPath de saída
  // Port fiel de add_cap() de pathstroke.cpp
  // Parâmetros:
  //   p0x/p0y   = último ponto emitido no path de saída (out.vtx[-1] do C++)
  //   pivX/pivY = ponto original do contorno (pivot)
  //   p1x/p1y   = ponto correspondente do outro lado
  //
  // q = normal(p1 - p0) * 0.5
  //   onde normal(v) = (-v.y, v.x)
  //   |p1 - p0| == width → |q| == hw — perpendicular a (p1-p0), na direção
  //   que se afasta do pivot (extensão do cap para fora).
  // ---------------------------------------------------------------------------

  static void _addCapToPath(
    BLPath out,
    double p0x,
    double p0y,
    double pivX,
    double pivY,
    double p1x,
    double p1y,
    BLStrokeCap cap,
    double hw,
  ) {
    // q = normal(p1 - p0) * 0.5  (Blend2D C++ pathstroke.cpp line 923)
    final double dx = p1x - p0x;
    final double dy = p1y - p0y;
    final double qx = -dy * 0.5;
    final double qy = dx * 0.5;

    switch (cap) {
      case BLStrokeCap.butt:
        // C++: out.line_to(p1)
        out.lineTo(p1x, p1y);
        return;

      case BLStrokeCap.square:
        // C++: out.line_to(p0 + q), out.line_to(p1 + q), out.line_to(p1)
        out.lineTo(p0x + qx, p0y + qy);
        out.lineTo(p1x + qx, p1y + qy);
        out.lineTo(p1x, p1y);
        return;

      case BLStrokeCap.round:
        // C++: arc_quadrant_to(p0 + q, pivot + q), arc_quadrant_to(p1 + q, p1)
        // Implementado como arco subdividido com midpoint em (pivot + q)
        _addRoundCapToPath(out, p0x, p0y, pivX, pivY, p1x, p1y, qx, qy, hw);
        return;

      case BLStrokeCap.roundRev:
        // C++: line_to(p0+q), arc_quadrant(p0, pivot), arc_quadrant(p1, p1+q), line_to(p1)
        out.lineTo(p0x + qx, p0y + qy);
        // Arco de (p0+q) passando por (p0) até (pivot), e de (pivot) passando por (p1) até (p1+q)
        {
          // Arco de recuo: (p0+q) ao redor do midpoint entre p0 e pivot
          final tmpVerts = <double>[];
          _addArcPoints(
              tmpVerts, pivX, pivY, p0x + qx, p0y + qy, pivX + qx, pivY + qy);
          for (int i = 0; i < tmpVerts.length; i += 2) {
            out.lineTo(tmpVerts[i], tmpVerts[i + 1]);
          }
          tmpVerts.clear();
          // Continuação: de (pivot) passando por (p1) até (p1+q)
          _addArcPoints(
              tmpVerts, pivX, pivY, pivX + qx, pivY + qy, p1x + qx, p1y + qy);
          for (int i = 0; i < tmpVerts.length; i += 2) {
            out.lineTo(tmpVerts[i], tmpVerts[i + 1]);
          }
        }
        out.lineTo(p1x, p1y);
        return;

      case BLStrokeCap.triangle:
        // C++: out.line_to(pivot + q), out.line_to(p1)
        out.lineTo(pivX + qx, pivY + qy);
        out.lineTo(p1x, p1y);
        return;

      case BLStrokeCap.triangleRev:
        // C++: line_to(p0+q), line_to(pivot), line_to(p1+q), line_to(p1)
        out.lineTo(p0x + qx, p0y + qy);
        out.lineTo(pivX, pivY);
        out.lineTo(p1x + qx, p1y + qy);
        out.lineTo(p1x, p1y);
        return;
    }
  }

  /// Arco de cap semicircular: de p0 ao redor de piv até p1 (180°).
  /// Usa o midpoint `pivot + q` (onde q = normal(p1-p0)*0.5) como waypoint,
  /// equivalente ao arc_quadrant_to do C++ Blend2D.
  static void _addRoundCapToPath(
    BLPath out,
    double p0x,
    double p0y,
    double pivX,
    double pivY,
    double p1x,
    double p1y,
    double qx,
    double qy,
    double hw,
  ) {
    // Midpoint do arco semicircular: pivot + q
    // C++: arc_quadrant_to(p0 + q, pivot + q), arc_quadrant_to(p1 + q, p1)
    final double midX = pivX + qx;
    final double midY = pivY + qy;

    // Arco de p0 passando por mid até p1 (dois quadrantes de ~90° cada)
    final tmpVerts = <double>[];
    _addArcPoints(tmpVerts, pivX, pivY, p0x, p0y, midX, midY);
    _addArcPoints(tmpVerts, pivX, pivY, midX, midY, p1x, p1y);

    final int nPts = tmpVerts.length ~/ 2;
    for (int i = 0; i < nPts; i++) {
      out.lineTo(tmpVerts[i * 2], tmpVerts[i * 2 + 1]);
    }
    // Garantir que chegamos exatamente em p1
    out.lineTo(p1x, p1y);
  }

  // ---------------------------------------------------------------------------
  // Utilitários de emissão de polígono no BLPath de saída
  // ---------------------------------------------------------------------------

  /// Dobro da área com sinal do polígono dado por [verts] (x, y intercalados).
  static double _signedArea2(List<double> verts) {
    final int n = verts.length ~/ 2;
    if (n < 3) return 0.0;
    double acc = 0.0;
    double xj = verts[(n - 1) * 2];
    double yj = verts[(n - 1) * 2 + 1];
    for (int i = 0; i < n; i++) {
      final xi = verts[i * 2];
      final yi = verts[i * 2 + 1];
      acc += (xj * yi) - (xi * yj);
      xj = xi;
      yj = yi;
    }
    return acc;
  }

  static void _emitClosedPolygon(List<double> verts, BLPath out) {
    final int n = verts.length ~/ 2;
    if (n < 2) return;
    out.moveTo(verts[0], verts[1]);
    for (int i = 1; i < n; i++) {
      out.lineTo(verts[i * 2], verts[i * 2 + 1]);
    }
    out.close();
  }

  static void _emitClosedPolygonReversed(List<double> verts, BLPath out) {
    final int n = verts.length ~/ 2;
    if (n < 2) return;
    out.moveTo(verts[(n - 1) * 2], verts[(n - 1) * 2 + 1]);
    for (int i = n - 2; i >= 0; i--) {
      out.lineTo(verts[i * 2], verts[i * 2 + 1]);
    }
    out.close();
  }
}
