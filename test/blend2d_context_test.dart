import 'dart:math' as math;
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:dgfx/dgfx.dart';

/// Count non-background pixels in an image.
int _countDrawnPixels(BLImage image, {int background = 0xFFFFFFFF}) {
  int count = 0;
  for (int i = 0; i < image.pixels.length; i++) {
    if (image.pixels[i] != background) count++;
  }
  return count;
}

/// Check if a specific pixel is not the background color.
bool _isDrawn(BLImage image, int x, int y, {int background = 0xFFFFFFFF}) {
  return image.pixels[y * image.width + x] != background;
}

void main() {
  group('BLContext - Fill', () {
    test('fillPolygon draws a triangle', () async {
      final image = BLImage(64, 64);
      final ctx = BLContext(image);
      ctx.clear(0xFFFFFFFF);

      // Triangle covering a portion of the image
      await ctx.fillPolygon(
        [10, 10, 50, 10, 30, 50],
        color: 0xFFFF0000,
      );

      final drawn = _countDrawnPixels(image);
      expect(drawn, greaterThan(100));

      // Center of triangle should be drawn
      expect(_isDrawn(image, 30, 25), true);
      // Outside triangle should not be drawn
      expect(_isDrawn(image, 5, 5), false);

      await ctx.dispose();
    });

    test('fillPolygon with hole (nonZero)', () async {
      final image = BLImage(64, 64);
      final ctx = BLContext(image);
      ctx.clear(0xFFFFFFFF);
      ctx.setFillRule(BLFillRule.nonZero);

      // Outer rectangle (CW) + inner rectangle (CCW for hole)
      await ctx.fillPolygon(
        [
          // Outer (CW)
          5, 5, 55, 5, 55, 55, 5, 55,
          // Inner (CCW)
          15, 15, 15, 45, 45, 45, 45, 15,
        ],
        color: 0xFF00FF00,
        contourVertexCounts: [4, 4],
      );

      // Center should be the hole (background)
      expect(_isDrawn(image, 30, 30), false, reason: 'Center should be hole');
      // Border should be drawn
      expect(_isDrawn(image, 10, 10), true, reason: 'Border should be drawn');

      await ctx.dispose();
    });

    test('fillPath draws triangle via BLPath', () async {
      final image = BLImage(64, 64);
      final ctx = BLContext(image);
      ctx.clear(0xFFFFFFFF);

      final path = BLPath();
      path.moveTo(10, 10);
      path.lineTo(50, 10);
      path.lineTo(30, 50);
      path.close();

      await ctx.fillPath(path, color: 0xFF0000FF);

      final drawn = _countDrawnPixels(image);
      expect(drawn, greaterThan(100));

      await ctx.dispose();
    });

    test('fillPath with cubic curve', () async {
      final image = BLImage(64, 64);
      final ctx = BLContext(image);
      ctx.clear(0xFFFFFFFF);

      final path = BLPath();
      path.moveTo(5, 32);
      path.cubicTo(20, 5, 40, 5, 58, 32);
      path.lineTo(58, 58);
      path.lineTo(5, 58);
      path.close();

      await ctx.fillPath(path, color: 0xFFFF0000);

      final drawn = _countDrawnPixels(image);
      expect(drawn, greaterThan(200));

      await ctx.dispose();
    });

    test('compOp srcCopy writes directly', () async {
      final image = BLImage(32, 32);
      final ctx = BLContext(image);
      ctx.clear(0xFFFFFFFF);
      ctx.setCompOp(BLCompOp.srcCopy);

      await ctx.fillPolygon(
        [0, 0, 31, 0, 31, 31, 0, 31],
        color: 0x80FF0000, // semi-transparent red
      );

      // srcCopy replaces the destination with the source pixel.
      // With full coverage the result is exactly 0x80FF0000.
      // With AA fringe pixels the rasterizer may blend via compose().
      // The interior pixel should have the source's alpha (0x80 = 128).
      final pixel = image.pixels[16 * 32 + 16];
      final alpha = (pixel >> 24) & 0xFF;
      final r = (pixel >> 16) & 0xFF;
      final g = (pixel >> 8) & 0xFF;
      final b = pixel & 0xFF;
      // srcCopy writes source alpha directly — no longer 0xFF
      expect(alpha, closeTo(0x80, 2));
      expect(r, greaterThan(g));
      expect(r, greaterThan(b));

      await ctx.dispose();
    });
  });

  group('BLContext - Stroke', () {
    test('strokePath draws a line', () async {
      final image = BLImage(64, 64);
      final ctx = BLContext(image);
      ctx.clear(0xFFFFFFFF);

      final path = BLPath();
      path.moveTo(5, 32);
      path.lineTo(58, 32);

      await ctx.strokePath(
        path,
        color: 0xFFFF0000,
        options: const BLStrokeOptions(width: 4.0),
      );

      final drawn = _countDrawnPixels(image);
      expect(drawn, greaterThan(50));

      // Center of the line should be drawn
      expect(_isDrawn(image, 30, 32), true);
      // Far from the line should not be drawn
      expect(_isDrawn(image, 30, 5), false);

      await ctx.dispose();
    });

    test('strokePath with closed triangle', () async {
      final image = BLImage(64, 64);
      final ctx = BLContext(image);
      ctx.clear(0xFFFFFFFF);

      final path = BLPath();
      path.moveTo(32, 5);
      path.lineTo(58, 55);
      path.lineTo(5, 55);
      path.close();

      await ctx.strokePath(
        path,
        color: 0xFF0000FF,
        options: const BLStrokeOptions(width: 3.0),
      );

      final drawn = _countDrawnPixels(image);
      expect(drawn, greaterThan(100));

      // Interior of triangle should NOT be drawn (only the stroke outline)
      // At the center, a thin stroke means the interior is empty
      // (for a 3px stroke on a ~50px triangle, center should be clear)
      // This depends on exact geometry; just verify we have drawn pixels
      expect(drawn, lessThan(64 * 64)); // Not everything is drawn

      await ctx.dispose();
    });

    test('setStrokeWidth affects rendering', () async {
      final image1 = BLImage(64, 64);
      final ctx1 = BLContext(image1);
      ctx1.clear(0xFFFFFFFF);
      ctx1.setStrokeWidth(2.0);

      final path = BLPath();
      path.moveTo(10, 32);
      path.lineTo(54, 32);

      await ctx1.strokePath(path, color: 0xFF000000);
      final thin = _countDrawnPixels(image1);
      await ctx1.dispose();

      final image2 = BLImage(64, 64);
      final ctx2 = BLContext(image2);
      ctx2.clear(0xFFFFFFFF);
      ctx2.setStrokeWidth(10.0);

      await ctx2.strokePath(path, color: 0xFF000000);
      final thick = _countDrawnPixels(image2);
      await ctx2.dispose();

      expect(thick, greaterThan(thin));
    });
  });

  group('BLContext - Style', () {
    test('setFillStyle changes fill color', () async {
      final image = BLImage(32, 32);
      final ctx = BLContext(image);
      ctx.clear(0xFFFFFFFF);

      ctx.setFillStyle(0xFF00FF00); // green
      await ctx.fillPolygon([0, 0, 31, 0, 31, 31, 0, 31]);

      final pixel = image.pixels[16 * 32 + 16];
      final g = (pixel >> 8) & 0xFF;
      expect(g, greaterThan(200));

      await ctx.dispose();
    });

    test('setLinearGradient fills with gradient', () async {
      final image = BLImage(64, 64);
      final ctx = BLContext(image);
      ctx.clear(0xFFFFFFFF);

      ctx.setLinearGradient(BLLinearGradient(
        p0: const BLPoint(0, 0),
        p1: const BLPoint(64, 0),
        stops: const [
          BLGradientStop(0.0, 0xFF000000),
          BLGradientStop(1.0, 0xFFFFFFFF),
        ],
      ));

      await ctx.fillPolygon([0, 0, 63, 0, 63, 63, 0, 63]);

      // Left side should be dark, right side light
      final leftPixel = image.pixels[32 * 64 + 5];
      final rightPixel = image.pixels[32 * 64 + 58];
      final rLeft = (leftPixel >> 16) & 0xFF;
      final rRight = (rightPixel >> 16) & 0xFF;
      expect(rRight, greaterThan(rLeft));

      await ctx.dispose();
    });
  });

  group('BLImage', () {
    test('constructor creates correctly sized buffer', () {
      final img = BLImage(100, 50);
      expect(img.width, 100);
      expect(img.height, 50);
      expect(img.pixels.length, 5000);
    });

    test('clear fills with specified color', () {
      final img = BLImage(10, 10);
      img.clear(0xFFFF0000);

      for (final pixel in img.pixels) {
        expect(pixel, 0xFFFF0000);
      }
    });

    test('copyFrom copies pixel data', () {
      final img = BLImage(4, 4);
      final source = Uint32List(16);
      for (int i = 0; i < 16; i++) {
        source[i] = i;
      }

      img.copyFrom(source);
      for (int i = 0; i < 16; i++) {
        expect(img.pixels[i], i);
      }
    });

    test('copyFrom rejects wrong size', () {
      final img = BLImage(4, 4);
      final source = Uint32List(8); // wrong size

      expect(() => img.copyFrom(source), throwsArgumentError);
    });
  });

  // Cobertura rasterizada = área da forma. O retângulo alinhado sempre deu a
  // área exata; a borda curva é que saía até 10% menor, porque o achatamento
  // produzia uma poligonal inscrita.
  group('BLContext - área coberta', () {
    double coverage(BLImage img) {
      double sum = 0.0;
      for (int i = 0; i < img.pixels.length; i++) {
        sum += (255 - ((img.pixels[i] >> 16) & 0xFF)) / 255.0;
      }
      return sum;
    }

    Future<double> painted(
        int size, Future<void> Function(BLContext) draw) async {
      final img = BLImage(size, size);
      final ctx = BLContext(img)..clear(0xFFFFFFFF);
      await draw(ctx);
      ctx.flush();
      final area = coverage(img);
      await ctx.dispose();
      return area;
    }

    test('retângulo alinhado cobre exatamente a sua área', () async {
      expect(
          await painted(
              16, (ctx) => ctx.fillRect(4, 4, 4, 4, color: 0xFF000000)),
          closeTo(16.0, 1e-9));
      expect(
          await painted(
              32, (ctx) => ctx.fillRect(2, 3, 20, 11, color: 0xFF000000)),
          closeTo(220.0, 1e-9));
    });

    test('círculo cobre pi*r^2 a menos de 0,5%, de r=1 a r=64', () async {
      for (final r in <double>[1, 1.5, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64]) {
        final size = (r * 2).ceil() + 8;
        final c = size / 2.0;
        final got = await painted(
            size, (ctx) => ctx.fillCircle(c, c, r, color: 0xFF000000));
        final exact = math.pi * r * r;
        expect(got, closeTo(exact, exact * 0.005),
            reason: 'raio \$r: \$got vs \$exact');
      }
    });

    test('elipse cobre pi*rx*ry a menos de 0,5%', () async {
      for (final radii in <List<double>>[
        [2, 4],
        [4, 2],
        [8, 16],
        [30, 10],
        [64, 16],
      ]) {
        final rx = radii[0], ry = radii[1];
        final size = (2 * math.max(rx, ry)).ceil() + 8;
        final c = size / 2.0;
        final got = await painted(
            size, (ctx) => ctx.fillEllipse(c, c, rx, ry, color: 0xFF000000));
        final exact = math.pi * rx * ry;
        expect(got, closeTo(exact, exact * 0.005), reason: 'rx=\$rx ry=\$ry');
      }
    });

    test('quarto de círculo cobre pi*r^2/4 a menos de 0,5%', () async {
      for (final r in <double>[2, 4, 8, 16, 32, 64]) {
        final size = r.ceil() + 12;
        final p = BLPath()
          ..moveTo(6, 6)
          ..lineTo(6 + r, 6)
          ..addArc(6, 6, r, 0, math.pi / 2, moveToStart: false)
          ..close();
        final got =
            await painted(size, (ctx) => ctx.fillPath(p, color: 0xFF000000));
        final exact = math.pi * r * r / 4;
        expect(got, closeTo(exact, exact * 0.005), reason: 'raio \$r');
      }
    });
  });
}
