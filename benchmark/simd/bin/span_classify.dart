// Classify groups of 4 coverage counters as empty / full / partial and blit.
//
// Extracted from `_blitAccumulatedSIMD` in research/rasterizers/
// skia_scanline/skia_scanline_rasterizer.dart (the "SKIA" row of the SIMD gap
// report in https://github.com/dart-lang/sdk/issues/62618).
//
// A scanline accumulator holds per-pixel sample counts in 0..8. Each group of
// 4 pixels is skipped when all counters are 0, filled with one Int32x4 store
// when all are >= 8, and blended per pixel otherwise. The partial path is
// scalar in every variant; the variants only differ in how they classify:
//
//   * scalar:      four Int32List reads and scalar compares;
//   * laneExtract: what the rasterizer does today, read an Int32x4 and pull
//                  its lanes out through a one-element Int32x4List scratch;
//   * compareSimd: `equal(zero).allTrue` and `greaterThanOrEqual(8).allTrue`
//                  (new in 3.14), no lane extraction on the fast paths.

import 'dart:typed_data';

import 'package:benchmark_harness/benchmark_harness.dart';

const int width = 512;
const int height = 64;
const int pixels = width * height;
const int full = 8;
const int color = 0xFF3366CC;

final Int32List counters = Int32List(pixels);

void fillCounters() {
  // Per row: empty, a partial edge, a long full run, a partial edge, empty.
  for (int y = 0; y < height; y++) {
    final row = y * width;
    final l = 40 + (y * 5) % 90;
    final r = 300 + (y * 7) % 180;
    for (int x = l; x < r; x++) {
      counters[row + x] = full;
    }
    for (int k = 0; k < 3; k++) {
      counters[row + l - 1 - k] = (3 - k) * 2;
      counters[row + r + k] = (3 - k) * 2 + 1;
    }
  }
}

final List<int> alphaLut = List<int>.generate(
  full + 1,
  (c) => (c * 0xFF) >> 3,
  growable: false,
);

abstract class ClassifyBench extends BenchmarkBase {
  ClassifyBench(String name) : super('SpanClassify.$name');

  final Uint32List fb = Uint32List(pixels);
  late final Int32x4List fb4 = fb.buffer.asInt32x4List();

  @override
  void setup() => fb.fillRange(0, pixels, 0xFFFFFFFF);

  @pragma('vm:prefer-inline')
  void blendPixel(int idx, int c) {
    if (c >= full) {
      fb[idx] = color;
    } else if (c > 0) {
      final a = alphaLut[c];
      final bg = fb[idx];
      final inv = 255 - a;
      final r = (((color >> 16) & 0xFF) * a + ((bg >> 16) & 0xFF) * inv) >> 8;
      final g = (((color >> 8) & 0xFF) * a + ((bg >> 8) & 0xFF) * inv) >> 8;
      final b = ((color & 0xFF) * a + (bg & 0xFF) * inv) >> 8;
      fb[idx] = 0xFF000000 | (r << 16) | (g << 8) | b;
    }
  }
}

class ClassifyScalar extends ClassifyBench {
  ClassifyScalar() : super('scalar');

  @override
  void run() {
    final color4 = Int32x4.splat(color);
    for (int i = 0; i < pixels; i += 4) {
      final c0 = counters[i], c1 = counters[i + 1];
      final c2 = counters[i + 2], c3 = counters[i + 3];
      if ((c0 | c1 | c2 | c3) == 0) continue;
      if (c0 >= full && c1 >= full && c2 >= full && c3 >= full) {
        fb4[i >> 2] = color4;
        continue;
      }
      blendPixel(i, c0);
      blendPixel(i + 1, c1);
      blendPixel(i + 2, c2);
      blendPixel(i + 3, c3);
    }
  }
}

class ClassifyLaneExtract extends ClassifyBench {
  ClassifyLaneExtract() : super('laneExtract');

  late final Int32x4List counters4 = counters.buffer.asInt32x4List();
  final Int32x4List scratch = Int32x4List(1);
  late final Int32List scratchInts = scratch.buffer.asInt32List();

  @override
  void run() {
    final color4 = Int32x4.splat(color);
    for (int j = 0; j < pixels >> 2; j++) {
      scratch[0] = counters4[j];
      final c0 = scratchInts[0], c1 = scratchInts[1];
      final c2 = scratchInts[2], c3 = scratchInts[3];
      if ((c0 | c1 | c2 | c3) == 0) continue;
      if (c0 >= full && c1 >= full && c2 >= full && c3 >= full) {
        fb4[j] = color4;
        continue;
      }
      final i = j << 2;
      blendPixel(i, c0);
      blendPixel(i + 1, c1);
      blendPixel(i + 2, c2);
      blendPixel(i + 3, c3);
    }
  }
}

class ClassifyCompareSimd extends ClassifyBench {
  ClassifyCompareSimd() : super('compareSimd');

  late final Int32x4List counters4 = counters.buffer.asInt32x4List();

  @override
  void run() {
    final color4 = Int32x4.splat(color);
    final zero = Int32x4.zero();
    final full4 = Int32x4.splat(full);
    for (int j = 0; j < pixels >> 2; j++) {
      final v = counters4[j];
      if (v.equal(zero).allTrue) continue;
      if (v.greaterThanOrEqual(full4).allTrue) {
        fb4[j] = color4;
        continue;
      }
      final i = j << 2;
      blendPixel(i, counters[i]);
      blendPixel(i + 1, counters[i + 1]);
      blendPixel(i + 2, counters[i + 2]);
      blendPixel(i + 3, counters[i + 3]);
    }
  }
}

void main() {
  fillCounters();
  final benchmarks = <ClassifyBench Function()>[
    ClassifyScalar.new,
    ClassifyLaneExtract.new,
    ClassifyCompareSimd.new,
  ];

  final expected =
      (ClassifyScalar()
            ..setup()
            ..run())
          .fb;
  for (final bm in benchmarks.skip(1)) {
    final b = bm()
      ..setup()
      ..run();
    for (int i = 0; i < pixels; i++) {
      if (b.fb[i] != expected[i]) {
        throw StateError(
          '${b.name}: fb[$i] = ${b.fb[i].toRadixString(16)}, '
          'expected ${expected[i].toRadixString(16)}',
        );
      }
    }
  }

  for (final bm in benchmarks) {
    bm().report();
  }
}
