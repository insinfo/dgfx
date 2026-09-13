import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:dgfx/dgfx.dart';

void main() {
  group('BLStroker', () {
    test('stroke horizontal line produces filled outline', () {
      final path = BLPath();
      path.moveTo(10, 50);
      path.lineTo(90, 50);

      final outline = BLStroker.strokePath(
        path,
        const BLStrokeOptions(
            width: 10.0, startCap: BLStrokeCap.butt, endCap: BLStrokeCap.butt),
      );
      final data = outline.toPathData();

      // Should produce a non-empty outline
      expect(data.vertices.length, greaterThan(0));
      // Open contour with butt caps: single polygon (A + end_cap + B + start_cap)
      expect(data.contourVertexCounts!.length, 1);
      // At least 4 points for a rectangle
      expect(data.contourVertexCounts![0], greaterThanOrEqualTo(4));
    });

    test('stroke closed triangle produces two contours (nonZero)', () {
      final path = BLPath();
      path.moveTo(50, 10);
      path.lineTo(90, 90);
      path.lineTo(10, 90);
      path.close();

      final outline = BLStroker.strokePath(
        path,
        const BLStrokeOptions(width: 4.0, join: BLStrokeJoin.bevel),
      );
      final data = outline.toPathData();

      // Closed contour: two polygons (outer A + inner B reversed)
      expect(data.contourVertexCounts!.length, 2);
    });

    test('zero-width stroke falls back to minimumWidth (PDF "0 w")', () {
      final path = BLPath();
      path.moveTo(0, 0);
      path.lineTo(100, 100);

      // width == 0 nao significa "nao desenhar": vale minimumWidth (default
      // 1.0), como o operador `0 w` do PDF exige.
      final outline = BLStroker.strokePath(
        path,
        const BLStrokeOptions(width: 0.0),
      );
      final data = outline.toPathData();
      expect(data.vertices.isEmpty, false);

      final reference = BLStroker.strokePath(
        path,
        const BLStrokeOptions(width: 1.0),
      );
      expect(data.vertices, reference.toPathData().vertices);
    });

    test('zero minimumWidth still degenerates to an empty outline', () {
      final path = BLPath();
      path.moveTo(0, 0);
      path.lineTo(100, 100);

      final outline = BLStroker.strokePath(
        path,
        const BLStrokeOptions(width: 0.0, minimumWidth: 0.0),
      );
      expect(outline.toPathData().vertices.isEmpty, true);
    });

    test('empty path returns empty outline', () {
      final path = BLPath();
      final outline = BLStroker.strokePath(
        path,
        const BLStrokeOptions(width: 5.0),
      );
      final data = outline.toPathData();
      expect(data.vertices.isEmpty, true);
    });

    test('square cap preserves endpoint bounds', () {
      final path = BLPath();
      path.moveTo(50, 50);
      path.lineTo(150, 50);

      final outline = BLStroker.strokePath(
        path,
        const BLStrokeOptions(
          width: 20.0,
          startCap: BLStrokeCap.square,
          endCap: BLStrokeCap.square,
        ),
      );
      final data = outline.toPathData();

      // Check that the outline keeps at least the original segment span.
      double minX = double.infinity;
      double maxX = double.negativeInfinity;
      for (int i = 0; i < data.vertices.length; i += 2) {
        final x = data.vertices[i];
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
      }
      // Original line span is 50..150.
      expect(minX, lessThanOrEqualTo(50.0));
      expect(maxX, greaterThanOrEqualTo(150.0));
    });

    test('round cap produces arc points', () {
      final path = BLPath();
      path.moveTo(50, 50);
      path.lineTo(150, 50);

      final outline = BLStroker.strokePath(
        path,
        const BLStrokeOptions(
          width: 20.0,
          startCap: BLStrokeCap.round,
          endCap: BLStrokeCap.round,
        ),
      );
      final data = outline.toPathData();

      // Round caps add arc subdivision points (~45deg per step = ~4 pts per cap)
      // Total should be significantly more than the 4 points of a butt-cap rectangle
      expect(data.contourVertexCounts![0], greaterThan(6));
    });

    test('miter join within limit stays sharp', () {
      final path = BLPath();
      path.moveTo(0, 0);
      path.lineTo(50, 0);
      path.lineTo(50, 50); // 90-degree turn
      path.close();

      final outline = BLStroker.strokePath(
        path,
        const BLStrokeOptions(
          width: 10.0,
          join: BLStrokeJoin.miterClip,
          miterLimit: 10.0, // generous limit
        ),
      );
      final data = outline.toPathData();
      expect(data.vertices.length, greaterThan(0));
    });

    test('stroke with curves (cubicTo) produces reasonable outline', () {
      final path = BLPath();
      path.moveTo(10, 50);
      path.cubicTo(50, 10, 80, 90, 120, 50);

      final outline = BLStroker.strokePath(
        path,
        const BLStrokeOptions(
            width: 6.0, startCap: BLStrokeCap.round, endCap: BLStrokeCap.round),
      );
      final data = outline.toPathData();

      // Should have a reasonable number of vertices from the flattened curve
      expect(data.vertices.length, greaterThan(20));
    });

    test('all cap types produce non-empty outlines', () {
      for (final cap in BLStrokeCap.values) {
        final path = BLPath();
        path.moveTo(10, 50);
        path.lineTo(90, 50);

        final outline = BLStroker.strokePath(
          path,
          BLStrokeOptions(width: 10.0, startCap: cap, endCap: cap),
        );
        final data = outline.toPathData();
        expect(data.vertices.length, greaterThan(0),
            reason: 'Cap $cap should produce non-empty outline');
      }
    });

    test('all join types produce non-empty outlines', () {
      for (final join in BLStrokeJoin.values) {
        final path = BLPath();
        path.moveTo(10, 10);
        path.lineTo(50, 10);
        path.lineTo(50, 50);
        path.close();

        final outline = BLStroker.strokePath(
          path,
          BLStrokeOptions(width: 6.0, join: join),
        );
        final data = outline.toPathData();
        expect(data.vertices.length, greaterThan(0),
            reason: 'Join $join should produce non-empty outline');
      }
    });

    test(
        'square cap extends FORWARD by hw beyond endpoints (C++ Blend2D parity)',
        () {
      // Horizontal line (50,50) -> (150,50), width=20 (hw=10).
      // Square cap should extend the stroke by hw=10 BEYOND each endpoint:
      //   start: x should reach 50 - 10 = 40
      //   end:   x should reach 150 + 10 = 160
      final path = BLPath();
      path.moveTo(50, 50);
      path.lineTo(150, 50);

      final outline = BLStroker.strokePath(
        path,
        const BLStrokeOptions(
          width: 20.0,
          startCap: BLStrokeCap.square,
          endCap: BLStrokeCap.square,
        ),
      );
      final data = outline.toPathData();

      double minX = double.infinity;
      double maxX = double.negativeInfinity;
      double minY = double.infinity;
      double maxY = double.negativeInfinity;
      for (int i = 0; i < data.vertices.length; i += 2) {
        final x = data.vertices[i];
        final y = data.vertices[i + 1];
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }

      // Forward extension: minX should be exactly 50 - hw = 40
      expect(minX, closeTo(40.0, 0.01),
          reason: 'Square cap start should extend hw=10 before x=50');
      // Forward extension: maxX should be exactly 150 + hw = 160
      expect(maxX, closeTo(160.0, 0.01),
          reason: 'Square cap end should extend hw=10 beyond x=150');
      // Y span should be exactly width=20: 50 ± 10
      expect(minY, closeTo(40.0, 0.01));
      expect(maxY, closeTo(60.0, 0.01));
    });

    test('triangle cap tip extends beyond pivot (C++ Blend2D parity)', () {
      // Horizontal line (50,50) -> (150,50), width=20 (hw=10).
      // Triangle cap tip should be at (pivot + q) where q extends forward by hw.
      final path = BLPath();
      path.moveTo(50, 50);
      path.lineTo(150, 50);

      final outline = BLStroker.strokePath(
        path,
        const BLStrokeOptions(
          width: 20.0,
          startCap: BLStrokeCap.triangle,
          endCap: BLStrokeCap.triangle,
        ),
      );
      final data = outline.toPathData();

      double minX = double.infinity;
      double maxX = double.negativeInfinity;
      for (int i = 0; i < data.vertices.length; i += 2) {
        final x = data.vertices[i];
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
      }

      // Triangle cap should extend to pivot + q, i.e. 50 - 10 = 40 and 150 + 10 = 160
      expect(minX, closeTo(40.0, 0.01),
          reason: 'Triangle cap should extend hw beyond start pivot');
      expect(maxX, closeTo(160.0, 0.01),
          reason: 'Triangle cap should extend hw beyond end pivot');
    });

    test('square cap on diagonal line extends symmetrically (C++ parity)', () {
      // Diagonal line (50,50) -> (150,150), width=20 (hw=10).
      // Square cap extends in the direction perpendicular to (p1-p0), i.e. along
      // the tangent of the original segment, by hw from each endpoint.
      final path = BLPath();
      path.moveTo(50, 50);
      path.lineTo(150, 150);

      final outline = BLStroker.strokePath(
        path,
        const BLStrokeOptions(
          width: 20.0,
          startCap: BLStrokeCap.square,
          endCap: BLStrokeCap.square,
        ),
      );
      final data = outline.toPathData();

      double minX = double.infinity;
      double maxX = double.negativeInfinity;
      double minY = double.infinity;
      double maxY = double.negativeInfinity;
      for (int i = 0; i < data.vertices.length; i += 2) {
        final x = data.vertices[i];
        final y = data.vertices[i + 1];
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }

      // For a 45-degree line, the hw=10 stroke crosses ±10/sqrt(2) ≈ ±7.071
      // in each axis from the line, plus the square cap extends hw=10 along
      // the tangent direction, adding another 10/sqrt(2) ≈ 7.071 beyond end.
      // Total X span: (50 - 7.071 - 7.071) to (150 + 7.071 + 7.071)
      // ≈ 35.86 to 164.14
      final double hw = 10.0;
      final double d = hw / 1.4142135623730951; // hw / sqrt(2)
      expect(minX, closeTo(50 - d - d, 0.5));
      expect(maxX, closeTo(150 + d + d, 0.5));
      expect(minY, closeTo(50 - d - d, 0.5));
      expect(maxY, closeTo(150 + d + d, 0.5));
    });

    test('BLStrokeOptions copyWith preserves defaults', () {
      const opts = BLStrokeOptions();
      final copy = opts.copyWith(width: 5.0);
      expect(copy.width, 5.0);
      expect(copy.miterLimit, 4.0); // default
      expect(copy.startCap, BLStrokeCap.butt);
      expect(copy.endCap, BLStrokeCap.butt);
      expect(copy.join, BLStrokeJoin.bevel);
    });

    test('stroke width affects outline size', () {
      double outlineArea(double width) {
        final path = BLPath();
        path.moveTo(0, 50);
        path.lineTo(100, 50);
        final outline = BLStroker.strokePath(
          path,
          BLStrokeOptions(
              width: width,
              startCap: BLStrokeCap.butt,
              endCap: BLStrokeCap.butt),
        );
        final data = outline.toPathData();
        // Measure bounding box height as proxy for stroke width
        double minY = double.infinity;
        double maxY = double.negativeInfinity;
        for (int i = 1; i < data.vertices.length; i += 2) {
          final y = data.vertices[i];
          if (y < minY) minY = y;
          if (y > maxY) maxY = y;
        }
        return maxY - minY;
      }

      final thin = outlineArea(4.0);
      final thick = outlineArea(20.0);
      expect(thick, greaterThan(thin));
      expect(thin, closeTo(4.0, 0.5));
      expect(thick, closeTo(20.0, 0.5));
    });
  });

  // Regressões de largura do traço, todas medidas como COBERTURA: a soma de
  // (255 - valor)/255 num corte perpendicular ao traço tem que dar exatamente
  // a largura pedida, independente de caps, joins e de o contorno ser fechado.
  group('BLStroker - largura efetiva', () {
    double coverageAt(BLImage img, int x0, int x1, int y) {
      double sum = 0.0;
      for (int x = x0; x <= x1; x++) {
        sum += (255 - (img.pixels[y * img.width + x] & 0xFF)) / 255.0;
      }
      return sum;
    }

    double coverageDown(BLImage img, int x, int y0, int y1) {
      double sum = 0.0;
      for (int y = y0; y <= y1; y++) {
        sum += (255 - (img.pixels[y * img.width + x] & 0xFF)) / 255.0;
      }
      return sum;
    }

    Future<BLImage> render(BLPath p, BLStrokeOptions o) async {
      final img = BLImage(200, 200);
      final ctx = BLContext(img)..clear(0xFFFFFFFF);
      await ctx.strokePath(p, color: 0xFF000000, options: o);
      ctx.flush();
      await ctx.dispose();
      return img;
    }

    // `m l h S` é o que o PyMuPDF emite para TODA linha, então esse caminho
    // responde por praticamente todo traço de PDF gerado por terceiros. O
    // contorno fechado degenerado fazia o stroker emitir o mesmo retângulo
    // duas vezes com a MESMA orientação; o rasterizador soma área com sinal,
    // então a cobertura parcial das bordas dobrava e saturava — uma linha de
    // 1 px saía com cobertura 2 e sem antisserrilhamento.
    test('linha fechada com `close` tem a mesma largura da aberta', () async {
      for (final w in <double>[1, 2, 3, 4]) {
        for (final y in <double>[20.0, 40.5]) {
          final options = BLStrokeOptions(
            width: w,
            startCap: BLStrokeCap.butt,
            endCap: BLStrokeCap.butt,
          );
          BLPath line(bool closed) {
            final p = BLPath()
              ..moveTo(20, y)
              ..lineTo(180, y);
            if (closed) p.close();
            return p;
          }

          final yi = y.floor();
          final aberto = coverageDown(
              await render(line(false), options), 100, yi - 4, yi + 4);
          final fechado = coverageDown(
              await render(line(true), options), 100, yi - 4, yi + 4);

          expect(aberto, closeTo(w, 0.02), reason: 'aberto w=\$w y=\$y');
          expect(fechado, closeTo(w, 0.02), reason: 'fechado w=\$w y=\$y');
          expect(fechado, closeTo(aberto, 0.02), reason: 'w=\$w y=\$y');
        }
      }
    });

    // O segmento de fechamento de `m p0; l p1; h` retrocede sobre o mesmo
    // segmento e não acrescenta área nenhuma, então a cobertura total tem que
    // ser idêntica à do mesmo caminho sem `h`, em qualquer largura, qualquer
    // posição e qualquer orientação.
    test('`h` num caminho de dois pontos não muda a área coberta', () async {
      Future<double> total(
          double w, bool closed, double x0, double y0, double x1, double y1,
          int cx0, int cy0, int cx1, int cy1) async {
        final p = BLPath()
          ..moveTo(x0, y0)
          ..lineTo(x1, y1);
        if (closed) p.close();
        final img = await render(
            p,
            BLStrokeOptions(
              width: w,
              startCap: BLStrokeCap.butt,
              endCap: BLStrokeCap.butt,
            ));
        double acc = 0.0;
        for (int y = cy0; y <= cy1; y++) {
          acc += coverageAt(img, cx0, cx1, y);
        }
        return acc;
      }

      for (final w in <double>[1, 2, 3, 4]) {
        for (final off in <double>[0.0, 0.5]) {
          // Horizontal.
          final ha = await total(w, false, 50, 100 + off, 150, 100 + off,
              40, 90, 160, 110);
          final hf = await total(w, true, 50, 100 + off, 150, 100 + off,
              40, 90, 160, 110);
          expect(hf, closeTo(ha, 0.02), reason: 'horizontal w=$w off=$off');
          expect(hf, closeTo(100 * w, 1.0), reason: 'horizontal w=$w off=$off');

          // Vertical.
          final va = await total(w, false, 100 + off, 50, 100 + off, 150,
              90, 40, 110, 160);
          final vf = await total(w, true, 100 + off, 50, 100 + off, 150,
              90, 40, 110, 160);
          expect(vf, closeTo(va, 0.02), reason: 'vertical w=$w off=$off');
          expect(vf, closeTo(100 * w, 1.0), reason: 'vertical w=$w off=$off');

          // 45 graus.
          const d = 70.710678;
          final da = await total(w, false, 40 + off, 40 + off, 40 + off + d,
              40 + off + d, 20, 20, 140, 140);
          final df = await total(w, true, 40 + off, 40 + off, 40 + off + d,
              40 + off + d, 20, 20, 140, 140);
          expect(df, closeTo(da, 0.05), reason: '45 graus w=$w off=$off');
          expect(df, closeTo(100 * w, 1.0), reason: '45 graus w=$w off=$off');
        }
      }
    });

    test('retângulo fechado tem a largura pedida nos quatro lados', () async {
      for (final w in <double>[1, 2, 3]) {
        final p = BLPath()..addRect(40, 40, 120, 120);
        final img = await render(p, BLStrokeOptions(width: w));
        // Corte horizontal pelo meio: cruza a lateral esquerda.
        expect(coverageAt(img, 30, 50, 100), closeTo(w, 0.02),
            reason: 'lateral, w=\$w');
        // Corte vertical pelo meio: cruza o topo.
        expect(coverageDown(img, 100, 30, 50), closeTo(w, 0.02),
            reason: 'topo, w=\$w');
      }
    });

    // O join estava no lado errado (girar para um lado abre o vão do lado
    // OPOSTO) e o ponto de miter saía na metade da distância certa. Num
    // contorno com muitos segmentos — todo círculo e toda curva traçada — o
    // efeito era perder 25% da largura com bevel/round e 50% com miter, que é
    // o join padrão do PDF.
    test('traço de círculo tem a largura pedida em todos os joins', () async {
      const joins = <BLStrokeJoin>[
        BLStrokeJoin.bevel,
        BLStrokeJoin.round,
        BLStrokeJoin.miterClip,
        BLStrokeJoin.miterBevel,
        BLStrokeJoin.miterRound,
      ];
      for (final join in joins) {
        for (final w in <double>[1, 2, 3, 4]) {
          final p = BLPath()..addArc(100, 100, 50, 0, 2 * math.pi);
          p.close();
          final img = await render(p, BLStrokeOptions(width: w, join: join));
          expect(coverageAt(img, 40, 60, 100), closeTo(w, 0.03),
              reason: '\$join w=\$w');
        }
      }
    });

    test('polígono regular traçado tem a largura pedida', () async {
      for (final sides in <int>[16, 64, 256]) {
        for (final join in <BLStrokeJoin>[
          BLStrokeJoin.bevel,
          BLStrokeJoin.miterBevel,
        ]) {
          final p = BLPath();
          for (int i = 0; i < sides; i++) {
            final a = 2 * math.pi * i / sides;
            final x = 100 + 50 * math.cos(a);
            final y = 100 + 50 * math.sin(a);
            if (i == 0) {
              p.moveTo(x, y);
            } else {
              p.lineTo(x, y);
            }
          }
          p.close();
          final img = await render(p, BLStrokeOptions(width: 3, join: join));
          expect(coverageAt(img, 40, 60, 100), closeTo(3.0, 0.1),
              reason: 'N=\$sides \$join');
        }
      }
    });

    test('o outline de um quadrado fechado é um anel com a área certa',
        () async {
      final p = BLPath()..addRect(10, 10, 20, 20);
      final outline = BLStroker.strokePath(
          p, const BLStrokeOptions(width: 4, join: BLStrokeJoin.miterBevel));
      final d = outline.toPathData();
      final counts = d.contourVertexCounts!;
      expect(counts.length, 2, reason: 'anel = laço externo + laço interno');

      double area(int start, int n) {
        double acc = 0.0;
        for (int i = 0; i < n; i++) {
          final a = (start + i) * 2;
          final b = (start + (i + 1) % n) * 2;
          acc += d.vertices[a] * d.vertices[b + 1] -
              d.vertices[b] * d.vertices[a + 1];
        }
        return acc / 2;
      }

      final a0 = area(0, counts[0]);
      final a1 = area(counts[0], counts[1]);
      // Externo 24x24, interno 16x16, orientações opostas.
      expect(a0.abs() + a1.abs(), closeTo(576 + 256, 1e-9));
      expect(a0.sign * a1.sign, -1.0);
      // Perímetro do eixo (80) vezes a largura (4).
      expect((a0.abs() - a1.abs()).abs(), closeTo(320, 1e-9));
    });
  });
}
