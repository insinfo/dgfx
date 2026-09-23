// Per-lane select of integers by a runtime mask (bitselect / blendv).
//
// The request in https://github.com/dart-lang/sdk/issues/62618 asked for
// `select(a, b, mask)` on integer vectors. The reply suggested `shuffleMix`,
// but `shuffleMix` picks lanes by a compile-time constant (XY from `this`,
// ZW from `other`), so it cannot pick per lane from a mask computed at run
// time. The existing `Int32x4.select` only takes and returns Float32x4.
//
// Kernel: `out[i] = a[i] < b[i] ? a[i] : b[i] + b[i]`, the shape of
// "keep the smaller value or fall back" code in pixel pipelines.
//
//   * scalar:        branchy scalar loop;
//   * andNot:        `m = a.lessThan(b); (a & m) | (b + b).andNot(m)`;
//   * floatBits:     `m.select(...)` round-tripping through Float32x4 bits,
//                    the only built-in select today.
// A native Wasm-style `v128.bitselect` would make this a single operation.

import 'dart:typed_data';

import 'package:benchmark_harness/benchmark_harness.dart';

const int n = 16384;

final Int32List a = Int32List(n);
final Int32List b = Int32List(n);

void fillInputs() {
  for (int i = 0; i < n; i++) {
    a[i] = ((i * 2654435761) & 0x3FF) - 300;
    b[i] = ((i * 40503) & 0x1FF) - 100;
  }
}

abstract class SelectBench extends BenchmarkBase {
  SelectBench(String name) : super('MaskSelect.$name');

  final Int32List out = Int32List(n);
  late final Int32x4List a4 = a.buffer.asInt32x4List();
  late final Int32x4List b4 = b.buffer.asInt32x4List();
  late final Int32x4List out4 = out.buffer.asInt32x4List();
}

class SelectScalar extends SelectBench {
  SelectScalar() : super('scalar');

  @override
  void run() {
    for (int i = 0; i < n; i++) {
      final x = a[i], y = b[i];
      out[i] = x < y ? x : y + y;
    }
  }
}

class SelectAndNot extends SelectBench {
  SelectAndNot() : super('andNot');

  @override
  void run() {
    for (int j = 0; j < n >> 2; j++) {
      final x = a4[j], y = b4[j];
      final m = x.lessThan(y);
      out4[j] = (x & m) | (y + y).andNot(m);
    }
  }
}

class SelectFloatBits extends SelectBench {
  SelectFloatBits() : super('floatBits');

  @override
  void run() {
    for (int j = 0; j < n >> 2; j++) {
      final x = a4[j], y = b4[j];
      final m = x.lessThan(y);
      out4[j] = Int32x4.fromFloat32x4Bits(
        m.select(
          Float32x4.fromInt32x4Bits(x),
          Float32x4.fromInt32x4Bits(y + y),
        ),
      );
    }
  }
}

void main() {
  fillInputs();
  final benchmarks = <SelectBench Function()>[
    SelectScalar.new,
    SelectAndNot.new,
    SelectFloatBits.new,
  ];

  final expected = (SelectScalar()..run()).out;
  for (final bm in benchmarks.skip(1)) {
    final s = bm()..run();
    for (int i = 0; i < n; i++) {
      if (s.out[i] != expected[i]) {
        throw StateError(
          '${s.name}: out[$i] = ${s.out[i]}, '
          'expected ${expected[i]}',
        );
      }
    }
  }

  for (final bm in benchmarks) {
    bm().report();
  }
}
