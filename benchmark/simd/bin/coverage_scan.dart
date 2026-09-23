// Coverage accumulation ("resolve") of an analytic-coverage rasterizer.
//
// Extracted from `resolveSimd` in research/rasterizers/blend2d/
// blend2d_rasterizer2.dart (B2D v2) and `_resolveSimd` in blend2d_rasterizer.dart
// (B2D v1), the kernels behind the "B2D" rows of the SIMD gap report in
// https://github.com/dart-lang/sdk/issues/62618.
//
// Per cell: `acc += cover - area; coverage = acc; acc += area;` then
// `alpha = min((|coverage| * 255) >> 8, 255)`. The running sum makes each lane
// depend on the previous one, so the rasterizer loads an Int32x4 and then
// extracts x/y/z/w and does the rest in scalar code (LaneExtract below).
//
// ScanSimd keeps everything in Int32x4 using the new 3.14 API:
//   * inclusive prefix sum: lane shift by 1 = `shuffle(xxyz).withX(0)`,
//     lane shift by 2 = `zero.shuffleMix(v, xxxy)`;
//   * carry broadcast with `shuffle(wwww)` (no lane extraction at all);
//   * `abs`, `<<`, `>>`, `min` instead of scalar branches;
//   * `x * 255` written as `(x << 8) - x` because Int32x4 has no `*` yet.
// Shifting lanes in with zeros takes two ops here; Wasm's i8x16.shuffle does
// it in one because it takes arbitrary lanes from both inputs.

import 'dart:typed_data';

import 'package:benchmark_harness/benchmark_harness.dart';

const int width = 512;
const int height = 64;
const int cells = width * height;

final Int32List covers = Int32List(cells);
final Int32List areas = Int32List(cells);

void fillCells() {
  // Two spans per row, each edge crossing one cell with a fractional area,
  // like a polygon edge that is steeper than 45 degrees.
  void edge(int y, int x256, int dir) {
    final idx = y * width + (x256 >> 8);
    covers[idx] += 256 * dir;
    areas[idx] += (x256 & 0xFF) * dir;
  }

  for (int y = 0; y < height; y++) {
    final l0 = (20 << 8) + y * 301;
    final r0 = (200 << 8) + y * 173;
    final l1 = (260 << 8) + y * 97;
    final r1 = (480 << 8) - y * 211;
    edge(y, l0, 1);
    edge(y, r0, -1);
    edge(y, l1, 1);
    edge(y, r1, -1);
  }
}

abstract class ScanBench extends BenchmarkBase {
  ScanBench(String name) : super('CoverageScan.$name');

  final Int32List alpha = Int32List(cells);
}

class ScanScalar extends ScanBench {
  ScanScalar() : super('scalar');

  @override
  void run() {
    for (int y = 0; y < height; y++) {
      int acc = 0;
      final row = y * width;
      for (int x = 0; x < width; x++) {
        final i = row + x;
        final cv = covers[i];
        final ar = areas[i];
        acc += cv - ar;
        final coverage = acc;
        acc += ar;
        final m = coverage >> 31;
        int a = (((coverage ^ m) - m) * 255) >> 8;
        if (a > 255) a = 255;
        alpha[i] = a;
      }
    }
  }
}

class ScanLaneExtract extends ScanBench {
  ScanLaneExtract() : super('laneExtract');

  late final Int32x4List cov4 = covers.buffer.asInt32x4List();
  late final Int32x4List area4 = areas.buffer.asInt32x4List();

  @override
  void run() {
    for (int y = 0; y < height; y++) {
      int acc = 0;
      int j = (y * width) >> 2;
      final end = j + (width >> 2);
      for (; j < end; j++) {
        final vc = cov4[j];
        final va = area4[j];
        final c0 = vc.x, c1 = vc.y, c2 = vc.z, c3 = vc.w;
        final a0 = va.x, a1 = va.y, a2 = va.z, a3 = va.w;
        acc += c0 - a0;
        int k0 = acc;
        acc += a0;
        acc += c1 - a1;
        int k1 = acc;
        acc += a1;
        acc += c2 - a2;
        int k2 = acc;
        acc += a2;
        acc += c3 - a3;
        int k3 = acc;
        acc += a3;
        final m0 = k0 >> 31, m1 = k1 >> 31, m2 = k2 >> 31, m3 = k3 >> 31;
        k0 = (((k0 ^ m0) - m0) * 255) >> 8;
        k1 = (((k1 ^ m1) - m1) * 255) >> 8;
        k2 = (((k2 ^ m2) - m2) * 255) >> 8;
        k3 = (((k3 ^ m3) - m3) * 255) >> 8;
        final o = j << 2;
        alpha[o] = k0 > 255 ? 255 : k0;
        alpha[o + 1] = k1 > 255 ? 255 : k1;
        alpha[o + 2] = k2 > 255 ? 255 : k2;
        alpha[o + 3] = k3 > 255 ? 255 : k3;
      }
    }
  }
}

class ScanSimd extends ScanBench {
  ScanSimd() : super('scanSimd');

  late final Int32x4List cov4 = covers.buffer.asInt32x4List();
  late final Int32x4List area4 = areas.buffer.asInt32x4List();
  late final Int32x4List alpha4 = alpha.buffer.asInt32x4List();

  @override
  void run() {
    final zero = Int32x4.zero();
    final max255 = Int32x4.splat(255);
    for (int y = 0; y < height; y++) {
      var carry = zero;
      int j = (y * width) >> 2;
      final end = j + (width >> 2);
      for (; j < end; j++) {
        final v = cov4[j];
        final s1 = v + v.shuffle(Int32x4.xxyz).withX(0);
        final p = s1 + zero.shuffleMix(s1, Int32x4.xxxy);
        final a = (p + carry - area4[j]).abs();
        alpha4[j] = (((a << 8) - a) >> 8).min(max255);
        carry = carry + p.shuffle(Int32x4.wwww);
      }
    }
  }
}

void main() {
  fillCells();
  final benchmarks = <ScanBench Function()>[
    ScanScalar.new,
    ScanLaneExtract.new,
    ScanSimd.new,
  ];

  final expected = (ScanScalar()..run()).alpha;
  for (final bm in benchmarks.skip(1)) {
    final b = bm()..run();
    for (int i = 0; i < cells; i++) {
      if (b.alpha[i] != expected[i]) {
        throw StateError(
          '${b.name}: alpha[$i] = ${b.alpha[i]}, '
          'expected ${expected[i]}',
        );
      }
    }
  }

  for (final bm in benchmarks) {
    bm().report();
  }
}
