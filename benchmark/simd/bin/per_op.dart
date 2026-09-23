// Cost of each Int32x4 operation in isolation, to tell which ones are
// intrinsified and which ones still fall back to boxed runtime calls.
//
// Every benchmark runs the same loop: load one Int32x4 from a list, apply the
// operation, store the result. `load+store` is the baseline; an operation
// that costs several times the baseline is not being compiled to a single
// SIMD instruction.

import 'dart:typed_data';

import 'package:benchmark_harness/benchmark_harness.dart';

const int n = 16384;

final Int32x4List src = Int32x4List(n >> 2);
final Int32x4List other = Int32x4List(n >> 2);
final Int32x4List dst = Int32x4List(n >> 2);
final Float32x4List fdst = Float32x4List(n >> 2);

final zero = Int32x4.zero();
final k = Int32x4.splat(255);

class Op extends BenchmarkBase {
  Op(String name, this.body) : super('Int32x4Op.$name');

  final void Function() body;

  @override
  void run() => body();
}

// One closure per op keeps each loop monomorphic; the loop bodies are
// written out so the op is inlined into its own loop.
final ops = <Op>[
  Op('load+store', () {
    for (int j = 0; j < src.length; j++) {
      dst[j] = src[j];
    }
  }),
  Op('add', () {
    for (int j = 0; j < src.length; j++) {
      dst[j] = src[j] + other[j];
    }
  }),
  Op('and', () {
    for (int j = 0; j < src.length; j++) {
      dst[j] = src[j] & other[j];
    }
  }),
  Op('andNot', () {
    for (int j = 0; j < src.length; j++) {
      dst[j] = src[j].andNot(other[j]);
    }
  }),
  Op('shiftLeft', () {
    for (int j = 0; j < src.length; j++) {
      dst[j] = src[j] << 8;
    }
  }),
  Op('shiftRight', () {
    for (int j = 0; j < src.length; j++) {
      dst[j] = src[j] >> 8;
    }
  }),
  Op('abs', () {
    for (int j = 0; j < src.length; j++) {
      dst[j] = src[j].abs();
    }
  }),
  Op('min', () {
    for (int j = 0; j < src.length; j++) {
      dst[j] = src[j].min(k);
    }
  }),
  Op('lessThan', () {
    for (int j = 0; j < src.length; j++) {
      dst[j] = src[j].lessThan(other[j]);
    }
  }),
  Op('equal', () {
    for (int j = 0; j < src.length; j++) {
      dst[j] = src[j].equal(other[j]);
    }
  }),
  Op('equal.allTrue', () {
    int c = 0;
    for (int j = 0; j < src.length; j++) {
      if (src[j].equal(zero).allTrue) c++;
    }
    if (c == -1) throw 'unreachable';
  }),
  Op('equal.anyTrue', () {
    int c = 0;
    for (int j = 0; j < src.length; j++) {
      if (src[j].equal(zero).anyTrue) c++;
    }
    if (c == -1) throw 'unreachable';
  }),
  Op('shuffle', () {
    for (int j = 0; j < src.length; j++) {
      dst[j] = src[j].shuffle(Int32x4.xxyz);
    }
  }),
  Op('shuffleMix', () {
    for (int j = 0; j < src.length; j++) {
      dst[j] = src[j].shuffleMix(other[j], Int32x4.xxxy);
    }
  }),
  Op('withX', () {
    for (int j = 0; j < src.length; j++) {
      dst[j] = src[j].withX(0);
    }
  }),
  Op('select(Float32x4)', () {
    final t = Float32x4.splat(1), f = Float32x4.splat(2);
    for (int j = 0; j < src.length; j++) {
      fdst[j] = src[j].select(t, f);
    }
  }),
  Op('fromInt32x4Bits', () {
    for (int j = 0; j < src.length; j++) {
      fdst[j] = Float32x4.fromInt32x4Bits(src[j]);
    }
  }),
  Op('lanes->Float32x4', () {
    for (int j = 0; j < src.length; j++) {
      final v = src[j];
      fdst[j] = Float32x4(
        v.x.toDouble(),
        v.y.toDouble(),
        v.z.toDouble(),
        v.w.toDouble(),
      );
    }
  }),
];

void main() {
  final ints = src.buffer.asInt32List();
  final ints2 = other.buffer.asInt32List();
  for (int i = 0; i < ints.length; i++) {
    ints[i] = ((i * 2654435761) & 0xFFFF) - 0x8000;
    ints2[i] = ((i * 40503) & 0xFFFF) - 0x8000;
  }
  for (final op in ops) {
    op.report();
  }
}
