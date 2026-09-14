import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:dgfx/dgfx.dart';

/// Total length of every contour of [path], summed edge by edge.
double _totalLength(BLPath path, {bool includeClosingEdge = true}) {
  final data = path.toPathData();
  final verts = data.vertices;
  if (verts.isEmpty) return 0.0;
  final counts = data.contourVertexCounts ?? [verts.length ~/ 2];
  final closed = data.contourClosed;
  var total = 0.0;
  var offset = 0;
  for (var ci = 0; ci < counts.length; ci++) {
    final n = counts[ci];
    final isClosed = includeClosingEdge &&
        closed != null &&
        ci < closed.length &&
        closed[ci];
    final segCount = isClosed ? n : n - 1;
    for (var seg = 0; seg < segCount; seg++) {
      final i0 = offset + seg;
      final i1 = offset + ((seg + 1) % n);
      final dx = verts[i1 * 2] - verts[i0 * 2];
      final dy = verts[i1 * 2 + 1] - verts[i0 * 2 + 1];
      total += math.sqrt(dx * dx + dy * dy);
    }
    offset += n;
  }
  return total;
}

/// Axis-aligned bounds of every vertex of [path].
({double minX, double minY, double maxX, double maxY}) _bounds(BLPath path) {
  final verts = path.toPathData().vertices;
  var minX = double.infinity, minY = double.infinity;
  var maxX = double.negativeInfinity, maxY = double.negativeInfinity;
  for (var i = 0; i < verts.length; i += 2) {
    minX = math.min(minX, verts[i]);
    maxX = math.max(maxX, verts[i]);
    minY = math.min(minY, verts[i + 1]);
    maxY = math.max(maxY, verts[i + 1]);
  }
  return (minX: minX, minY: minY, maxX: maxX, maxY: maxY);
}

/// True when any dashed segment lies on the horizontal line y == [y] within
/// the x range [x0]..[x1].
bool _coversHorizontal(BLPath path, double y, double x0, double x1) {
  final data = path.toPathData();
  final verts = data.vertices;
  final counts = data.contourVertexCounts ?? [verts.length ~/ 2];
  var offset = 0;
  for (final n in counts) {
    for (var seg = 0; seg < n - 1; seg++) {
      final i0 = offset + seg, i1 = offset + seg + 1;
      final ay = verts[i0 * 2 + 1], by = verts[i1 * 2 + 1];
      if ((ay - y).abs() > 1e-9 || (by - y).abs() > 1e-9) continue;
      final ax = verts[i0 * 2], bx = verts[i1 * 2];
      final lo = math.min(ax, bx), hi = math.max(ax, bx);
      if (lo <= x0 + 1e-9 && hi >= x1 - 1e-9) return true;
    }
    offset += n;
  }
  return false;
}

void main() {
  group('BLDasher basics', () {
    test('empty dash array returns the input path unchanged', () {
      final path = BLPath()
        ..moveTo(0, 0)
        ..lineTo(100, 0);
      final dashed = BLDasher.dashPath(path, const []);
      expect(identical(dashed, path), isTrue);
    });

    test('all-zero dash array falls back to a solid line', () {
      final path = BLPath()
        ..moveTo(0, 0)
        ..lineTo(100, 0);
      final dashed = BLDasher.dashPath(path, const [0.0, 0.0]);
      expect(identical(dashed, path), isTrue);
    });

    test('[10 10] over a 100 unit line yields five 10 unit dashes', () {
      final path = BLPath()
        ..moveTo(0, 0)
        ..lineTo(100, 0);
      final dashed = BLDasher.dashPath(path, const [10.0, 10.0]);
      final data = dashed.toPathData();

      expect(data.contourVertexCounts, hasLength(5));
      for (final n in data.contourVertexCounts!) {
        expect(n, 2);
      }
      expect(_totalLength(dashed), closeTo(50.0, 1e-9));

      // Dashes start at 0, 20, 40, 60, 80.
      final verts = data.vertices;
      for (var i = 0; i < 5; i++) {
        expect(verts[i * 4], closeTo(i * 20.0, 1e-9));
        expect(verts[i * 4 + 2], closeTo(i * 20.0 + 10.0, 1e-9));
      }
    });

    test('dashOffset shifts the pattern', () {
      final path = BLPath()
        ..moveTo(0, 0)
        ..lineTo(100, 0);
      // Offset 10 lands exactly on the first gap, so the line starts blank.
      final dashed =
          BLDasher.dashPath(path, const [10.0, 10.0], dashOffset: 10.0);
      final verts = dashed.toPathData().vertices;
      expect(verts[0], closeTo(10.0, 1e-9));
      expect(_totalLength(dashed), closeTo(50.0, 1e-9));
    });

    test('dash carries across a corner of an open contour', () {
      // Two 10 unit legs, pattern [15 5]: the first dash spans the corner.
      final path = BLPath()
        ..moveTo(0, 0)
        ..lineTo(10, 0)
        ..lineTo(10, 10);
      final dashed = BLDasher.dashPath(path, const [15.0, 5.0]);
      final data = dashed.toPathData();
      expect(data.contourVertexCounts, hasLength(1));
      // 0..10 horizontal plus 0..5 vertical = 3 vertices, 15 units.
      expect(data.contourVertexCounts![0], 3);
      expect(_totalLength(dashed), closeTo(15.0, 1e-9));
    });
  });

  group('BLDasher closed contours (P0-1a)', () {
    test('a dashed rectangle keeps its closing edge', () {
      // 100x50 rectangle: perimeter 300, pattern [5 5] => 150 units of dash.
      final path = BLPath()..addRect(0, 0, 100, 50);
      final dashed = BLDasher.dashPath(path, const [5.0, 5.0]);

      expect(_totalLength(dashed), closeTo(150.0, 1e-9));

      // The closing edge runs from (0, 50) back to (0, 0) along x == 0. Before
      // the fix nothing at all was emitted there: the rectangle had 3 sides.
      final b = _bounds(dashed);
      expect(b.minX, closeTo(0.0, 1e-9));
      expect(b.minY, closeTo(0.0, 1e-9));
      expect(b.maxX, closeTo(100.0, 1e-9));
      expect(b.maxY, closeTo(50.0, 1e-9));

      // Every side must carry dash material.
      final data = dashed.toPathData();
      final verts = data.vertices;
      var onLeftEdge = 0;
      for (var i = 0; i < verts.length; i += 2) {
        if (verts[i].abs() < 1e-9 && verts[i + 1] > 1e-9) onLeftEdge++;
      }
      expect(onLeftEdge, greaterThan(0),
          reason: 'the closing edge x == 0 must be dashed too');
    });

    test('open rectangle-shaped polyline is shorter than the closed one', () {
      final closed = BLPath()..addRect(0, 0, 100, 50);
      final open = BLPath()
        ..moveTo(0, 0)
        ..lineTo(100, 0)
        ..lineTo(100, 50)
        ..lineTo(0, 50);

      final dashedClosed = BLDasher.dashPath(closed, const [5.0, 5.0]);
      final dashedOpen = BLDasher.dashPath(open, const [5.0, 5.0]);

      expect(_totalLength(dashedClosed), closeTo(150.0, 1e-9));
      // Open path is 250 units long => 125 of dash.
      expect(_totalLength(dashedOpen), closeTo(125.0, 1e-9));
    });

    test('a dash spanning the seam of a closed contour is a single run', () {
      // Perimeter 40 (10x10 square). Pattern [30 10] with offset 0: the dash
      // runs 0..30 and the gap 30..40, so the contour starts and ends inside a
      // gap — no merge. With offset 35 the contour starts inside the dash and
      // also ends inside it, so the last run must merge into the first.
      final path = BLPath()..addRect(0, 0, 10, 10);
      final dashed =
          BLDasher.dashPath(path, const [30.0, 10.0], dashOffset: 35.0);
      final data = dashed.toPathData();
      // One single merged run instead of two runs touching (0, 0).
      expect(data.contourVertexCounts, hasLength(1));
      expect(
          _totalLength(dashed, includeClosingEdge: false), closeTo(30.0, 1e-9));
      // It must not be a closed contour: it is an arc of the perimeter.
      expect(data.contourClosed, [false]);
    });

    test('a pattern longer than the perimeter closes the contour', () {
      final path = BLPath()..addRect(0, 0, 10, 10);
      final dashed = BLDasher.dashPath(path, const [1000.0, 10.0]);
      final data = dashed.toPathData();
      expect(data.contourVertexCounts, hasLength(1));
      expect(data.contourClosed, [true]);
      expect(_totalLength(dashed), closeTo(40.0, 1e-9));
    });
  });

  group('BLDasher odd-length arrays (P0-1b)', () {
    test('[3] means 3 on / 3 off, not a solid line', () {
      // 30 unit line, pattern [3] => dashes at 0..3, 6..9, ... 24..27 => 5
      // full dashes plus one starting at 30 (none) = 15 units of ink.
      final path = BLPath()
        ..moveTo(0, 0)
        ..lineTo(30, 0);
      final dashed = BLDasher.dashPath(path, const [3.0]);
      final data = dashed.toPathData();

      expect(data.contourVertexCounts, hasLength(5));
      expect(_totalLength(dashed), closeTo(15.0, 1e-9));

      final verts = data.vertices;
      for (var i = 0; i < 5; i++) {
        expect(verts[i * 4], closeTo(i * 6.0, 1e-9));
        expect(verts[i * 4 + 2], closeTo(i * 6.0 + 3.0, 1e-9));
      }
    });

    test('[2 4 6] cycles with inverted parity on the second pass', () {
      // Expanded to [2 4 6 2 4 6], total 24.
      // on 0..2, off 2..6, on 6..12, off 12..14, on 14..18, off 18..24.
      final path = BLPath()
        ..moveTo(0, 0)
        ..lineTo(24, 0);
      final dashed = BLDasher.dashPath(path, const [2.0, 4.0, 6.0]);
      final data = dashed.toPathData();
      expect(data.contourVertexCounts, hasLength(3));
      expect(_totalLength(dashed), closeTo(2.0 + 6.0 + 4.0, 1e-9));

      final verts = data.vertices;
      expect(verts[0], closeTo(0.0, 1e-9));
      expect(verts[2], closeTo(2.0, 1e-9));
      expect(verts[4], closeTo(6.0, 1e-9));
      expect(verts[6], closeTo(12.0, 1e-9));
      expect(verts[8], closeTo(14.0, 1e-9));
      expect(verts[10], closeTo(18.0, 1e-9));
    });

    test('[5] on a closed square covers exactly half the perimeter', () {
      final path = BLPath()..addRect(0, 0, 10, 10);
      final dashed = BLDasher.dashPath(path, const [5.0]);
      expect(_totalLength(dashed), closeTo(20.0, 1e-9));
    });
  });

  group('BLDasher zero-length dashes (P0-1c)', () {
    test('[0 5] emits one degenerate run per period', () {
      final path = BLPath()
        ..moveTo(0, 0)
        ..lineTo(20, 0);
      final dashed = BLDasher.dashPath(path, const [0.0, 5.0]);
      final data = dashed.toPathData();

      // Dots at 0, 5, 10, 15 (and the one at 20 falls on the end).
      expect(data.contourVertexCounts!.length, greaterThanOrEqualTo(4));
      final verts = data.vertices;
      for (var i = 0; i < 4; i++) {
        expect(verts[i * 4], closeTo(i * 5.0, 1e-9));
      }
      // Each run is a minuscule segment, so the total ink is ~0 but non-empty:
      // with a round or square cap the stroker turns each into a dot.
      expect(_totalLength(dashed), lessThan(1e-3));
      expect(_totalLength(dashed), greaterThan(0.0));
    });

    test('a dotted line strokes into round blobs', () async {
      final image = BLImage(40, 20);
      final ctx = BLContext(image)..clear(0xFF000000);
      final path = BLPath()
        ..moveTo(5, 10)
        ..lineTo(35, 10);
      await ctx.strokeDashedPath(
        path,
        dashArray: const [0.0, 10.0],
        color: 0xFFFFFFFF,
        options: const BLStrokeOptions(
          width: 6.0,
          startCap: BLStrokeCap.round,
          endCap: BLStrokeCap.round,
        ),
      );
      ctx.flush();

      // A dot is centred on x == 5, 15, 25 (and 35). The midpoints between
      // them must stay black.
      int red(int px) => (px >>> 16) & 0xFF;
      expect(red(image.pixels[10 * 40 + 5]), greaterThan(200));
      expect(red(image.pixels[10 * 40 + 15]), greaterThan(200));
      expect(red(image.pixels[10 * 40 + 25]), greaterThan(200));
      expect(red(image.pixels[10 * 40 + 10]), lessThan(40));
      expect(red(image.pixels[10 * 40 + 20]), lessThan(40));
      await ctx.dispose();
    });
  });

  group('contorno fechado que retrocede sobre si mesmo', () {
    // `m p0; l p1; h` e ida e volta pelo mesmo segmento, e e o que o PyMuPDF
    // emite em toda linha. O padrao corre pelos dois sentidos, entao tracos da
    // ida caem sobre tracos da volta; o resultado tem de ser a uniao deles.

    /// Fracao do segmento coberta pela uniao das duas passagens.
    ///
    /// Oraculo independente do dasher: um ponto do segmento esta pintado se a
    /// passagem de ida OU a de volta cai num traco naquele ponto. A ida chega
    /// nele com parametro `t * len` e a volta com `2 * len - t * len`. Nao
    /// reaproveita nada da implementacao.
    double coveredFraction(double len, List<double> pattern, double offset) {
      final period = pattern.fold<double>(0, (a, b) => a + b);
      bool inDash(double s) {
        var phase = (s + offset) % period;
        var index = 0;
        while (phase >= pattern[index]) {
          phase -= pattern[index];
          index = (index + 1) % pattern.length;
        }
        return index.isEven;
      }

      const steps = 400000;
      var covered = 0;
      for (var i = 0; i < steps; i++) {
        final t = (i + 0.5) / steps * len;
        if (inDash(t) || inDash(2 * len - t)) covered++;
      }
      return covered / steps;
    }

    /// Intervalos do parametro ocupados por cada contorno da saida.
    List<List<double>> spansOf(BLPath path, double x0, double x1) {
      final data = path.toPathData();
      final verts = data.vertices;
      final counts = data.contourVertexCounts ?? [verts.length ~/ 2];
      final out = <List<double>>[];
      var offset = 0;
      for (final n in counts) {
        var lo = double.infinity, hi = double.negativeInfinity;
        for (var k = 0; k < n; k++) {
          final t = (verts[(offset + k) * 2] - x0) / (x1 - x0);
          if (t < lo) lo = t;
          if (t > hi) hi = t;
        }
        out.add(<double>[lo, hi]);
        offset += n;
      }
      out.sort((a, b) => a[0].compareTo(b[0]));
      return out;
    }

    test('os tracos da saida nao se sobrepoem', () {
      for (final pattern in [
        const [6.0, 3.0],
        const [1.0, 2.0],
        const [7.0, 4.0, 2.0, 4.0],
      ]) {
        for (final offset in [0.0, 2.5]) {
          final path = BLPath()
            ..moveTo(10, 10)
            ..lineTo(110, 10)
            ..close();
          final dashed = BLDasher.dashPath(path, pattern, dashOffset: offset);
          final spans = spansOf(dashed, 10, 110);
          for (var i = 1; i < spans.length; i++) {
            expect(spans[i][0], greaterThanOrEqualTo(spans[i - 1][1] - 1e-9),
                reason: 'padrao $pattern deslocamento $offset: o traco '
                    '${spans[i]} invade ${spans[i - 1]}');
          }
        }
      }
    });

    test('o comprimento tracado e o da uniao, nao a soma das duas passagens',
        () {
      const pattern = [6.0, 3.0];
      final path = BLPath()
        ..moveTo(10, 10)
        ..lineTo(110, 10)
        ..close();
      final dashed = BLDasher.dashPath(path, pattern);

      // A soma das duas passagens seria 2 * 100 * 6/9 = 133,3, maior que o
      // proprio segmento: e a medida da sobreposicao. A uniao cabe nos 100 e
      // e o oraculo por forca bruta que diz quanto.
      final esperado = coveredFraction(100, pattern, 0) * 100;
      expect(_totalLength(dashed), closeTo(esperado, 0.05));
      expect(_totalLength(dashed), lessThan(100.0001));
    });

    test('a tinta no raster e a do comprimento tracado, sem borda saturada',
        () async {
      const pattern = [6.0, 3.0];
      const width = 3.0;
      final path = BLPath()
        ..moveTo(10, 20)
        ..lineTo(110, 20)
        ..close();
      final dashed = BLDasher.dashPath(path, pattern);

      final image = BLImage(130, 40);
      final ctx = BLContext(image)..clear(0xFF000000);
      await ctx.strokeDashedPath(
        path,
        dashArray: pattern,
        color: 0xFFFFFFFF,
        options: const BLStrokeOptions(width: width),
      );
      ctx.flush();

      var ink = 0.0;
      for (var i = 0; i < image.pixels.length; i++) {
        ink += ((image.pixels[i] >>> 16) & 0xFF) / 255.0;
      }
      await ctx.dispose();

      // Se a ida e a volta fossem tracadas sobrepostas, o rasterizador
      // analitico somaria as coberturas parciais das bordas e cortaria em 1,
      // e a tinta passaria do comprimento vezes a largura. Este numero e o
      // que o MuPDF e o Marlin dao, porque os dois emitem um unico span de
      // onde o winding sai de zero ate onde volta.
      expect(ink, closeTo(_totalLength(dashed) * width, 2.0));
    });
  });

  group('BLDasher through BLContext', () {
    test('a dashed rectangle paints all four sides', () async {
      final image = BLImage(120, 70);
      final ctx = BLContext(image)..clear(0xFF000000);
      final path = BLPath()..addRect(10, 10, 100, 50);
      await ctx.strokeDashedPath(
        path,
        dashArray: const [5.0, 5.0],
        color: 0xFFFFFFFF,
        options: const BLStrokeOptions(width: 2.0),
      );
      ctx.flush();

      int red(int x, int y) => (image.pixels[y * 120 + x] >>> 16) & 0xFF;
      // Scan each side for at least one lit pixel.
      var top = 0, bottom = 0, left = 0, right = 0;
      for (var x = 10; x <= 110; x++) {
        if (red(x, 10) > 128) top++;
        if (red(x, 60) > 128) bottom++;
      }
      for (var y = 10; y <= 60; y++) {
        if (red(10, y) > 128) left++;
        if (red(110, y) > 128) right++;
      }
      expect(top, greaterThan(10));
      expect(bottom, greaterThan(10));
      expect(right, greaterThan(5));
      // The left side is the closing edge: zero before the P0-1a fix.
      expect(left, greaterThan(5),
          reason: 'the closing edge of the rectangle must be dashed');
      await ctx.dispose();
    });

    test('a dashed line covers only the on portions', () {
      final path = BLPath()
        ..moveTo(0, 3)
        ..lineTo(40, 3);
      final dashed = BLDasher.dashPath(path, const [8.0, 2.0]);
      expect(_coversHorizontal(dashed, 3, 0, 8), isTrue);
      expect(_coversHorizontal(dashed, 3, 8, 10), isFalse);
      expect(_coversHorizontal(dashed, 3, 10, 18), isTrue);
    });
  });
}
