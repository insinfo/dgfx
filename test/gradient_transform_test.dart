import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:dgfx/dgfx.dart';

/// Stops that turn the LUT into an identity ramp: `lut[i]` has red == i, so
/// `fetch` returns exactly `round(t * 255)` in the red channel and the test can
/// predict every pixel analytically.
const _ramp = <BLGradientStop>[
  BLGradientStop(0.0, 0xFF000000),
  BLGradientStop(1.0, 0xFFFFFFFF),
];

int _red(int argb) => (argb >>> 16) & 0xFF;

int _expectedRamp(double t) {
  final c = t < 0.0 ? 0.0 : (t > 1.0 ? 1.0 : t);
  return (c * 255).round();
}

void main() {
  group('BLLinearGradient.transform (P0-2)', () {
    test('identity transform is the historical behaviour', () {
      const g = BLLinearGradient(
        p0: BLPoint(0, 0),
        p1: BLPoint(100, 0),
        stops: _ramp,
      );
      final f = BLLinearGradientFetcher(g);
      for (var x = 0; x < 100; x += 7) {
        expect(_red(f.fetch(x, 3)), _expectedRamp((x + 0.5) / 100.0));
      }
    });

    test('translation shifts the ramp by exactly the offset', () {
      final g = BLLinearGradient(
        p0: const BLPoint(0, 0),
        p1: const BLPoint(100, 0),
        stops: _ramp,
        transform: BLMatrix2D.translation(20, 0),
      );
      final f = BLLinearGradientFetcher(g);
      for (var x = 20; x < 120; x += 9) {
        expect(_red(f.fetch(x, 3)), _expectedRamp((x + 0.5 - 20.0) / 100.0),
            reason: 'x=$x');
      }
    });

    test('a quarter turn makes the ramp run along device Y', () {
      // m maps gradient (u, v) to device (-v, u), so the inverse is
      // u = y, v = -x. With p0..p1 along +u the ramp runs along device Y.
      final g = BLLinearGradient(
        p0: const BLPoint(0, 0),
        p1: const BLPoint(100, 0),
        stops: _ramp,
        transform: const BLMatrix2D(0, 1, -1, 0, 0, 0),
      );
      final f = BLLinearGradientFetcher(g);
      for (var y = 0; y < 100; y += 11) {
        for (final x in const [0, 17, 63]) {
          expect(_red(f.fetch(x, y)), _expectedRamp((y + 0.5) / 100.0),
              reason: 'x=$x y=$y');
        }
      }
    });

    test('a non-uniform scale stretches the ramp per axis', () {
      // m = [3 0 0 1 10 0]: device x = 3u + 10, so u = (x - 10) / 3.
      final g = BLLinearGradient(
        p0: const BLPoint(0, 0),
        p1: const BLPoint(20, 0),
        stops: _ramp,
        transform: const BLMatrix2D(3, 0, 0, 1, 10, 0),
      );
      final f = BLLinearGradientFetcher(g);
      for (var x = 10; x < 70; x += 6) {
        final u = (x + 0.5 - 10.0) / 3.0;
        expect(_red(f.fetch(x, 0)), _expectedRamp(u / 20.0), reason: 'x=$x');
      }
    });
  });

  group('BLRadialGradient.transform (P0-2)', () {
    test('an anisotropic scale produces an ellipse, not a circle', () {
      // Gradient space: circle of radius 10 at the origin.
      // m = [2 0 0 1 50 50] => device x = 2u + 50, y = v + 50.
      // Inverse: u = (x - 50) / 2, v = y - 50.
      final g = BLRadialGradient(
        c0: const BLPoint(0, 0),
        c1: const BLPoint(0, 0),
        r0: 0.0,
        r1: 10.0,
        stops: _ramp,
        transform: const BLMatrix2D(2, 0, 0, 1, 50, 50),
      );
      final f = BLRadialGradientFetcher(g);

      for (var y = 30; y < 70; y += 3) {
        for (var x = 20; x < 80; x += 3) {
          final u = (x + 0.5 - 50.0) / 2.0;
          final v = (y + 0.5 - 50.0);
          final t = math.sqrt(u * u + v * v) / 10.0;
          expect(_red(f.fetch(x, y)), _expectedRamp(t), reason: 'x=$x y=$y');
        }
      }

      // The defining property: the t == 1 contour is an ellipse 20 wide and
      // 10 tall (semi-axes), not a circle of the averaged radius sqrt(2)*10.
      expect(_red(f.fetch(69, 49)), lessThan(255)); // u = 9.75 -> inside
      expect(_red(f.fetch(71, 49)), 255); // u = 10.75 -> outside
      expect(_red(f.fetch(49, 59)), lessThan(255)); // v = 9.5 -> inside
      expect(_red(f.fetch(49, 61)), 255); // v = 10.5 -> outside
    });

    test('transform is equivalent to pre-transforming the geometry', () {
      // A pure translation can be expressed either way; both must agree.
      final viaTransform = BLRadialGradientFetcher(BLRadialGradient(
        c0: const BLPoint(0, 0),
        c1: const BLPoint(0, 0),
        r0: 0.0,
        r1: 12.0,
        stops: _ramp,
        transform: BLMatrix2D.translation(40, 25),
      ));
      final viaGeometry = BLRadialGradientFetcher(const BLRadialGradient(
        c0: BLPoint(40, 25),
        c1: BLPoint(40, 25),
        r0: 0.0,
        r1: 12.0,
        stops: _ramp,
      ));
      for (var y = 10; y < 45; y += 2) {
        for (var x = 25; x < 60; x += 2) {
          expect(viaTransform.fetch(x, y), viaGeometry.fetch(x, y),
              reason: 'x=$x y=$y');
        }
      }
    });

    test('extendEnd false clips to the transformed ellipse', () async {
      final image = BLImage(100, 100);
      final ctx = BLContext(image)..clear(0xFF000000);
      ctx.setRadialGradient(BLRadialGradient(
        c0: const BLPoint(0, 0),
        c1: const BLPoint(0, 0),
        r0: 0.0,
        r1: 10.0,
        stops: const [
          BLGradientStop(0.0, 0xFFFFFFFF),
          BLGradientStop(1.0, 0xFFFFFFFF),
        ],
        extendEnd: false,
        transform: const BLMatrix2D(2, 0, 0, 1, 50, 50),
      ));
      await ctx.fillRect(0, 0, 100, 100);
      ctx.flush();

      int px(int x, int y) => _red(image.pixels[y * 100 + x]);

      // Semi-axes 20 (x) and 10 (y) around (50, 50).
      expect(px(67, 50), 255, reason: 'inside along the long axis');
      expect(px(73, 50), 0, reason: 'outside along the long axis');
      expect(px(50, 57), 255, reason: 'inside along the short axis');
      expect(px(50, 63), 0, reason: 'outside along the short axis');
      // A circle of the averaged radius would have lit this one; the ellipse
      // must not.
      expect(px(50, 62), 0);
      await ctx.dispose();
    });
  });

  group('BLConicGradient.transform (P0-2)', () {
    test('translation moves the cone centre', () {
      final viaTransform = BLConicGradientFetcher(BLConicGradient(
        center: const BLPoint(0, 0),
        stops: _ramp,
        transform: BLMatrix2D.translation(30, 30),
      ));
      final viaGeometry = BLConicGradientFetcher(const BLConicGradient(
        center: BLPoint(30, 30),
        stops: _ramp,
      ));
      for (var y = 5; y < 60; y += 3) {
        for (var x = 5; x < 60; x += 3) {
          expect(viaTransform.fetch(x, y), viaGeometry.fetch(x, y),
              reason: 'x=$x y=$y');
        }
      }
    });

    test('an anisotropic scale skews the angular ramp', () {
      // m = [2 0 0 1 40 40]: u = (x - 40) / 2, v = y - 40.
      final g = BLConicGradient(
        center: const BLPoint(0, 0),
        stops: _ramp,
        transform: const BLMatrix2D(2, 0, 0, 1, 40, 40),
      );
      final f = BLConicGradientFetcher(g);
      for (var y = 10; y < 70; y += 5) {
        for (var x = 10; x < 70; x += 5) {
          final u = (x + 0.5 - 40.0) / 2.0;
          final v = (y + 0.5 - 40.0);
          var angle = math.atan2(v, u);
          if (angle < 0) angle += 2 * math.pi;
          expect(_red(f.fetch(x, y)), _expectedRamp(angle / (2 * math.pi)),
              reason: 'x=$x y=$y');
        }
      }
    });
  });

  group('degenerate transforms', () {
    test('a singular matrix falls back to identity instead of NaN', () {
      final g = BLLinearGradient(
        p0: const BLPoint(0, 0),
        p1: const BLPoint(100, 0),
        stops: _ramp,
        // Collapses the plane onto a line: no inverse.
        transform: const BLMatrix2D(1, 1, 1, 1, 0, 0),
      );
      final f = BLLinearGradientFetcher(g);
      for (var x = 0; x < 100; x += 13) {
        final v = f.fetch(x, 5);
        expect(v & 0xFF000000, 0xFF000000);
        expect(_red(v), _expectedRamp((x + 0.5) / 100.0));
      }
    });
  });
}
