// Blend a solid color over ARGB32 pixels with a per-pixel 8-bit coverage.
//
// This is the blit at the end of every resolve loop in research/rasterizers/
// (B2D v1/v2, SKIA): `out = (src * a + dst * (255 - a)) >> 8` per channel.
// It is the part of the pipeline that stays scalar in all of the rasterizers
// benchmarked in https://github.com/dart-lang/sdk/issues/62618, because:
//
//   * Int32x4 has no `*` (cl/551260 is still open), so channel * alpha
//     cannot be done in Int32x4;
//   * there is no numeric Int32x4 <-> Float32x4 conversion (Wasm has
//     f32x4.convert_i32x4_s and i32x4.trunc_sat_f32x4_s; Dart only has the
//     bit casts fromInt32x4Bits/fromFloat32x4Bits), so moving to Float32x4
//     means extracting and rebuilding every lane;
//   * there are no 8/16-bit lane types (#46182) to do it the usual way
//     (widen u8 -> u16, multiply, narrow with saturation).
//
//   * scalar:     per-pixel, per-channel integer math;
//   * shiftSimd:  channel unpack/pack in Int32x4 (`>>`, `&`, `<<`, `|`), the
//                 multiplies emulated by the only integer-only route left:
//                 extracting lanes, multiplying in scalar and rebuilding;
//   * floatSimd:  channel unpack/pack in Int32x4, multiplies in Float32x4 with
//                 the int <-> float lane conversions done by hand.

import 'dart:typed_data';

import 'package:benchmark_harness/benchmark_harness.dart';

const int n = 16384;
const int src = 0xFF3366CC;

final Uint32List dst0 = Uint32List(n);
final Int32List coverage = Int32List(n);

void fillInputs() {
  for (int i = 0; i < n; i++) {
    dst0[i] = 0xFF000000 | ((i * 2654435761) & 0xFFFFFF);
    coverage[i] = (i * 40503) & 0xFF;
  }
}

abstract class BlendBench extends BenchmarkBase {
  BlendBench(String name) : super('SolidBlend.$name');

  final Uint32List dst = Uint32List(n);
  late final Int32x4List dst4 = dst.buffer.asInt32x4List();
  late final Int32x4List cov4 = coverage.buffer.asInt32x4List();

  // Every run starts from the same pixels, so all variants do the same work
  // and their results can be compared.
  @override
  void run() {
    dst.setAll(0, dst0);
    blend();
  }

  void blend();
}

class BlendScalar extends BlendBench {
  BlendScalar() : super('scalar');

  @override
  void blend() {
    const sr = (src >> 16) & 0xFF, sg = (src >> 8) & 0xFF, sb = src & 0xFF;
    for (int i = 0; i < n; i++) {
      final a = coverage[i];
      final inv = 255 - a;
      final d = dst[i];
      final r = (sr * a + ((d >> 16) & 0xFF) * inv) >> 8;
      final g = (sg * a + ((d >> 8) & 0xFF) * inv) >> 8;
      final b = (sb * a + (d & 0xFF) * inv) >> 8;
      dst[i] = 0xFF000000 | (r << 16) | (g << 8) | b;
    }
  }
}

class BlendShiftSimd extends BlendBench {
  BlendShiftSimd() : super('shiftSimd');

  @pragma('vm:prefer-inline')
  static Int32x4 mul(Int32x4 x, Int32x4 y) =>
      Int32x4(x.x * y.x, x.y * y.y, x.z * y.z, x.w * y.w);

  @override
  void blend() {
    final ff = Int32x4.splat(0xFF);
    final opaque = Int32x4.splat(0xFF000000);
    final sr = Int32x4.splat((src >> 16) & 0xFF);
    final sg = Int32x4.splat((src >> 8) & 0xFF);
    final sb = Int32x4.splat(src & 0xFF);
    for (int j = 0; j < n >> 2; j++) {
      final a = cov4[j];
      final inv = ff - a;
      final d = dst4[j];
      final r = (mul(sr, a) + mul((d >> 16) & ff, inv)) >> 8;
      final g = (mul(sg, a) + mul((d >> 8) & ff, inv)) >> 8;
      final b = (mul(sb, a) + mul(d & ff, inv)) >> 8;
      dst4[j] = opaque | (r << 16) | (g << 8) | b;
    }
  }
}

class BlendFloatSimd extends BlendBench {
  BlendFloatSimd() : super('floatSimd');

  @pragma('vm:prefer-inline')
  static Float32x4 toF(Int32x4 v) =>
      Float32x4(v.x.toDouble(), v.y.toDouble(), v.z.toDouble(), v.w.toDouble());

  @pragma('vm:prefer-inline')
  static Int32x4 toI(Float32x4 v) =>
      Int32x4(v.x.toInt(), v.y.toInt(), v.z.toInt(), v.w.toInt());

  @override
  void blend() {
    final ff = Int32x4.splat(0xFF);
    final ffF = Float32x4.splat(255.0);
    final inv256 = Float32x4.splat(1.0 / 256.0);
    final opaque = Int32x4.splat(0xFF000000);
    final sr = Float32x4.splat(((src >> 16) & 0xFF).toDouble());
    final sg = Float32x4.splat(((src >> 8) & 0xFF).toDouble());
    final sb = Float32x4.splat((src & 0xFF).toDouble());
    for (int j = 0; j < n >> 2; j++) {
      final a = toF(cov4[j]);
      final inv = ffF - a;
      final d = dst4[j];
      // All terms are non-negative and below 2^24, so float math is exact
      // and truncation matches the scalar `>> 8`.
      final r = toI((sr * a + toF((d >> 16) & ff) * inv) * inv256);
      final g = toI((sg * a + toF((d >> 8) & ff) * inv) * inv256);
      final b = toI((sb * a + toF(d & ff) * inv) * inv256);
      dst4[j] = opaque | (r << 16) | (g << 8) | b;
    }
  }
}

void main() {
  fillInputs();
  final benchmarks = <BlendBench Function()>[
    BlendScalar.new,
    BlendShiftSimd.new,
    BlendFloatSimd.new,
  ];

  final expected = (BlendScalar()..run()).dst;
  for (final bm in benchmarks.skip(1)) {
    final b = bm()..run();
    for (int i = 0; i < n; i++) {
      if (b.dst[i] != expected[i]) {
        throw StateError(
          '${b.name}: dst[$i] = ${b.dst[i].toRadixString(16)}, '
          'expected ${expected[i].toRadixString(16)}',
        );
      }
    }
  }

  for (final bm in benchmarks) {
    bm().report();
  }
}
