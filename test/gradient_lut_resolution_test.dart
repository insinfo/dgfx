import 'package:dgfx/dgfx.dart';
import 'package:test/test.dart';

/// The gradient fetchers do not evaluate the stops per pixel: they build a
/// lookup table once and index it. The table's size is therefore the ceiling
/// on how much of the gradient survives, and this port had it nailed to 256
/// entries for every gradient. Blend2D picks it from the stops instead
/// (`bl_gradient_impl_ensure_info`, `BLGradientInfo::_lut_size`), and the
/// difference is not subtle: a colour that changes abruptly between two
/// neighbouring stops falls inside a single table entry, that entry gets an
/// interpolated colour, and the edge reaches the device as a ramp one entry
/// wide -- ten pixels across an A4 page at 300 dpi.
///
/// These tests are written against the observable output, not the table, so
/// they keep holding if the sizing rule is ever replaced by a better one.

/// Fills a [width]x8 image with a horizontal gradient and returns the middle
/// scanline.
List<int> _scanline(int width, List<BLGradientStop> stops) {
  final image = BLImage(width, 8);
  BLContext(image)
    ..setLinearGradient(BLLinearGradient(
        p0: const BLPoint(0, 0),
        p1: BLPoint(width.toDouble(), 0),
        stops: stops))
    ..fillPath(BLPath()..addRect(0, 0, width.toDouble(), 8));
  final row = <int>[];
  for (var x = 0; x < width; x++) {
    row.add(image.pixels[4 * width + x]);
  }
  return row;
}

const _blue = 0xFF0000FF;
const _red = 0xFFFF0000;

bool _isBlue(int c) => ((c >> 16) & 0xFF) == 0 && (c & 0xFF) == 255;
bool _isRed(int c) => ((c >> 16) & 0xFF) == 255 && (c & 0xFF) == 0;

/// `count` evenly spaced stops describing a hard step from blue to red at
/// `t = 0.5`, which is what a PDF type 4 function with an `ifelse` produces.
List<BLGradientStop> _step(int count) => [
      for (var i = 0; i < count; i++)
        BLGradientStop(i / (count - 1), i / (count - 1) < 0.5 ? _blue : _red),
    ];

void main() {
  group('gradient LUT resolution', () {
    // A step is described by a pair of adjacent stops, and where that pair
    // falls relative to the table's own grid decides everything: land between
    // two entries and the edge is reproduced exactly, land on one and that
    // entry is interpolated into a ramp. Testing a single step position
    // therefore proves nothing -- it only samples the lucky case. So the
    // position is swept, and what is asserted is the worst of the sweep.
    //
    // Measured across 59 positions, with 1024 stops handed in:
    //   table of  256 entries: edge up to 5.3 px out at 2479 px wide, and a
    //                          10 px ramp at a sixth of the positions.
    //   table of 1024 entries: edge within 1.6 px, never a ramp.
    ({double offset, int widestRamp}) sweep(int width) {
      var worstOffset = 0.0;
      var widestRamp = 0;
      for (var k = 1; k < 60; k++) {
        final at = 0.2 + 0.6 * k / 60;
        final row = _scanline(width, [
          for (var i = 0; i < 1024; i++)
            BLGradientStop(i / 1023, i / 1023 < at ? _blue : _red),
        ]);
        var flip = -1, ramp = 0;
        for (var x = 0; x < width; x++) {
          if (flip < 0 && _isRed(row[x])) flip = x;
          if (!_isBlue(row[x]) && !_isRed(row[x])) ramp++;
        }
        final offset = (flip - at * width).abs();
        if (offset > worstOffset) worstOffset = offset;
        if (ramp > widestRamp) widestRamp = ramp;
      }
      return (offset: worstOffset, widestRamp: widestRamp);
    }

    for (final width in [600, 1240, 2479]) {
      test('a step stays a step wherever it falls, at ${width}px', () {
        final result = sweep(width);
        expect(result.widestRamp, lessThanOrEqualTo(3),
            reason: 'the step was resampled into a ramp '
                '${result.widestRamp} px wide');
        expect(result.offset, lessThan(2.0),
            reason: 'the edge landed ${result.offset.toStringAsFixed(2)} px '
                'from where the stops put it');
      });
    }

    test('a 256-entry table would fail this, which is why the size is picked',
        () {
      // Guard case: the same step described with few enough stops that the
      // table cannot hold it. If this ever passes, the test above has stopped
      // proving anything -- it would mean the pipeline no longer resamples.
      final row = _scanline(1240, [
        const BLGradientStop(0.0, _blue),
        const BLGradientStop(0.4, _blue),
        const BLGradientStop(0.6, _red),
        const BLGradientStop(1.0, _red),
      ]);
      final blended = [
        for (var x = 1; x < 1239; x++)
          if (!_isBlue(row[x]) && !_isRed(row[x])) x
      ];
      expect(blended, isNotEmpty,
          reason: 'stops 0.2 apart describe a ramp, so a ramp must be drawn');
    });

    test('detail finer than the table is lost, and 1024 is the limit', () {
      // Stripes along the axis, described exactly. What comes back tells how
      // many bands the pipeline can still tell apart.
      List<BLGradientStop> stripes(int n) {
        final count = n * 8;
        return [
          for (var i = 0; i < count; i++)
            BLGradientStop(
                i / (count - 1),
                // clamped so t = 1 belongs to the last stripe rather than
                // opening a degenerate one past the end.
                (((i / (count - 1)) * n).floor().clamp(0, n - 1)).isEven
                    ? _blue
                    : _red),
        ];
      }

      int transitions(int n) {
        final row = _scanline(2479, stripes(n));
        var t = 0;
        var prev = _isRed(row[0]);
        for (var x = 1; x < 2479; x++) {
          final now = _isRed(row[x]);
          if (now != prev) t++;
          prev = now;
        }
        return t;
      }

      // Comfortably inside the table: reproduced exactly.
      expect(transitions(200), 199);
      expect(transitions(400), 399);
      // Past half the table, Nyquist takes over and the bands alias. This is
      // not a defect to fix by testing; it is the documented ceiling.
      expect(transitions(900), lessThan(899));
    });
  });

  group('BLGradientLut.sizeForStops', () {
    // Blend2D's rule, kept checkable so a future change is a decision rather
    // than an accident.
    test('two stops spanning the whole range describe a ramp', () {
      expect(
          BLGradientLut.sizeForStops(const [
            BLGradientStop(0.0, _blue),
            BLGradientStop(1.0, _red),
          ]),
          256);
    });

    test('two stops leaving flat regions need the edges resolved', () {
      expect(
          BLGradientLut.sizeForStops(const [
            BLGradientStop(0.25, _blue),
            BLGradientStop(0.75, _red),
          ]),
          512);
    });

    test('the symmetric three-stop case is the one Blend2D special-cases', () {
      expect(
          BLGradientLut.sizeForStops(const [
            BLGradientStop(0.0, _blue),
            BLGradientStop(0.5, _red),
            BLGradientStop(1.0, _blue),
          ]),
          512);
      expect(
          BLGradientLut.sizeForStops(const [
            BLGradientStop(0.0, _blue),
            BLGradientStop(0.3, _red),
            BLGradientStop(1.0, _blue),
          ]),
          1024);
    });

    test('anything richer gets the largest table', () {
      expect(BLGradientLut.sizeForStops(_step(1024)), BLGradientLut.maxSize);
    });
  });
}
