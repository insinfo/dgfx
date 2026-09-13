import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:dgfx/dgfx.dart';

void main() {
  group('BLPath', () {
    test('moveTo + lineTo creates single contour', () {
      final path = BLPath();
      path.moveTo(0, 0);
      path.lineTo(100, 0);
      path.lineTo(100, 100);

      final data = path.toPathData();
      expect(data.vertices.length, 6); // 3 points * 2
      expect(data.contourVertexCounts, [3]);
      expect(data.contourClosed, [false]);
    });

    test('close() marks contour as closed', () {
      final path = BLPath();
      path.moveTo(0, 0);
      path.lineTo(100, 0);
      path.lineTo(100, 100);
      path.close();

      final data = path.toPathData();
      expect(data.contourVertexCounts, [3]);
      expect(data.contourClosed, [true]);
    });

    test('multiple contours tracked separately', () {
      final path = BLPath();
      // Contour 1 (closed)
      path.moveTo(0, 0);
      path.lineTo(10, 0);
      path.lineTo(10, 10);
      path.close();

      // Contour 2 (open)
      path.moveTo(50, 50);
      path.lineTo(60, 50);
      path.lineTo(60, 60);

      final data = path.toPathData();
      expect(data.contourVertexCounts!.length, 2);
      expect(data.contourVertexCounts, [3, 3]);
      expect(data.contourClosed, [true, false]);
    });

    test('single-point contour discarded', () {
      final path = BLPath();
      path.moveTo(50, 50); // Single point, should be discarded
      path.moveTo(0, 0);
      path.lineTo(100, 0);
      path.lineTo(100, 100);

      final data = path.toPathData();
      expect(data.contourVertexCounts, [3]);
      expect(data.vertices.length, 6);
    });

    test('2-point contour preserved for stroke', () {
      final path = BLPath();
      path.moveTo(0, 0);
      path.lineTo(100, 100);

      final data = path.toPathData();
      expect(data.contourVertexCounts, [2]);
      expect(data.vertices.length, 4);
    });

    test('duplicate lineTo ignored', () {
      final path = BLPath();
      path.moveTo(10, 20);
      path.lineTo(30, 40);
      path.lineTo(30, 40); // duplicate, should be ignored
      path.lineTo(50, 60);

      final data = path.toPathData();
      expect(data.contourVertexCounts, [3]); // 3 unique points
    });

    test('lineTo without moveTo creates implicit moveTo', () {
      final path = BLPath();
      path.lineTo(100, 100);
      path.lineTo(200, 200);

      final data = path.toPathData();
      expect(data.vertices.length, 4);
      expect(data.vertices[0], 100.0); // implicit moveTo at first lineTo
      expect(data.vertices[1], 100.0);
    });

    test('quadTo flattens to line segments', () {
      final path = BLPath();
      path.moveTo(0, 0);
      path.quadTo(50, 100, 100, 0);

      final data = path.toPathData();
      // Should produce more than 2 points due to flattening
      expect(data.contourVertexCounts![0], greaterThan(2));
      // First point is the moveTo
      expect(data.vertices[0], 0.0);
      expect(data.vertices[1], 0.0);
      // Last point is the endpoint
      expect(data.vertices[data.vertices.length - 2], 100.0);
      expect(data.vertices[data.vertices.length - 1], 0.0);
    });

    test('cubicTo flattens to line segments', () {
      final path = BLPath();
      path.moveTo(0, 0);
      path.cubicTo(33, 100, 66, -100, 100, 0);

      final data = path.toPathData();
      expect(data.contourVertexCounts![0], greaterThan(3));
      expect(data.vertices[0], 0.0);
      expect(data.vertices[1], 0.0);
      expect(data.vertices[data.vertices.length - 2], 100.0);
      expect(data.vertices[data.vertices.length - 1], closeTo(0.0, 0.01));
    });

    test('clear resets all state', () {
      final path = BLPath();
      path.moveTo(0, 0);
      path.lineTo(100, 100);
      path.lineTo(200, 200);
      path.close();

      path.clear();

      final data = path.toPathData();
      expect(data.vertices.isEmpty, true);
      expect(data.contourVertexCounts, isNull);
    });

    test('toPathData can be called multiple times', () {
      final path = BLPath();
      path.moveTo(0, 0);
      path.lineTo(10, 0);
      path.lineTo(10, 10);

      final data1 = path.toPathData();
      final data2 = path.toPathData();
      expect(data1.vertices.length, data2.vertices.length);
      expect(data1.contourVertexCounts, data2.contourVertexCounts);
    });
  });

  // Regressão: a polilinha do achatamento subestimava a área da curva.
  //
  // Um polígono INSCRITO num círculo de raio r com n lados encerra
  // `(n/2) r^2 sen(2pi/n)`, bem menos que `pi r^2` quando n é pequeno. Como a
  // tolerância de achatamento é fixa, raios pequenos ganhavam poucos segmentos
  // e o erro chegava a 10%: um círculo de raio 2 px achatava para um octógono
  // de área 11,31 contra 12,57 analíticos. A folha do achatamento agora emite
  // o vértice que preserva a área da lasca entre a corda e a curva, então a
  // área do polígono bate com a da curva em qualquer subdivisão.
  group('BLPath - área do achatamento', () {
    double polygonArea(List<double> v) {
      final n = v.length ~/ 2;
      if (n < 3) return 0.0;
      double acc = 0.0;
      for (int i = 0; i < n; i++) {
        final j = (i + 1) % n;
        acc += v[i * 2] * v[j * 2 + 1] - v[j * 2] * v[i * 2 + 1];
      }
      return acc.abs() / 2;
    }

    BLPath ellipse(double cx, double cy, double rx, double ry) {
      const k = 0.5522847498;
      final kx = rx * k, ky = ry * k;
      return BLPath()
        ..moveTo(cx + rx, cy)
        ..cubicTo(cx + rx, cy - ky, cx + kx, cy - ry, cx, cy - ry)
        ..cubicTo(cx - kx, cy - ry, cx - rx, cy - ky, cx - rx, cy)
        ..cubicTo(cx - rx, cy + ky, cx - kx, cy + ry, cx, cy + ry)
        ..cubicTo(cx + kx, cy + ry, cx + rx, cy + ky, cx + rx, cy)
        ..close();
    }

    test('círculo achatado tem a área analítica, de r=1 a r=64', () {
      for (final r in <double>[1, 1.5, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64]) {
        final area = polygonArea(ellipse(100, 100, r, r).toPathData().vertices);
        final exact = math.pi * r * r;
        expect(area, closeTo(exact, exact * 0.005),
            reason: 'raio \$r: \$area vs \$exact');
      }
    });

    test('elipse achatada tem a área analítica', () {
      for (final radii in <List<double>>[
        [2, 4],
        [4, 2],
        [8, 16],
        [30, 10],
        [64, 16],
      ]) {
        final rx = radii[0], ry = radii[1];
        final area = polygonArea(ellipse(100, 100, rx, ry).toPathData().vertices);
        final exact = math.pi * rx * ry;
        expect(area, closeTo(exact, exact * 0.005),
            reason: 'rx=\$rx ry=\$ry: \$area vs \$exact');
      }
    });

    test('quarto de círculo achatado tem a área analítica', () {
      for (final r in <double>[2, 4, 8, 16, 32, 64]) {
        final p = BLPath()
          ..moveTo(100, 100)
          ..lineTo(100 + r, 100)
          ..addArc(100, 100, r, 0, math.pi / 2, moveToStart: false)
          ..close();
        final area = polygonArea(p.toPathData().vertices);
        final exact = math.pi * r * r / 4;
        expect(area, closeTo(exact, exact * 0.005), reason: 'raio \$r');
      }
    });

    test('o achatamento não desperdiça vértices em curva já reta', () {
      // Uma "curva" colinear não ganha vértice de compensação: a lasca é nula.
      final p = BLPath()
        ..moveTo(0, 0)
        ..cubicTo(10, 0, 20, 0, 30, 0);
      expect(p.toPathData().vertices, [0.0, 0.0, 30.0, 0.0]);
    });
  });
}
