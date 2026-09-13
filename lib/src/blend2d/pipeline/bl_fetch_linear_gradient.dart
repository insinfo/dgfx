import 'dart:math' as math;
import 'dart:typed_data';

import '../core/bl_types.dart';

class BLLinearGradientFetcher {
  static const int _kLutSize = 256;

  final BLLinearGradient gradient;
  final Uint32List _lut;
  final double _x0;
  final double _y0;
  final double _dx;
  final double _dy;
  final double _invLen2;

  /// Inversa de [BLLinearGradient.transform]: leva o pixel de device de volta
  /// ao espaço em que `p0`/`p1` foram definidos.
  final bool _hasTransform;
  final double _i00;
  final double _i01;
  final double _i10;
  final double _i11;
  final double _i20;
  final double _i21;

  factory BLLinearGradientFetcher(BLLinearGradient gradient) {
    final m = gradient.transform;
    // Matriz degenerada não tem volta: o gradiente colapsa, e tratar como
    // identidade é melhor que devolver NaN em todo pixel.
    final inv = m.isIdentity ? null : m.invert();
    return BLLinearGradientFetcher._(gradient, inv);
  }

  BLLinearGradientFetcher._(this.gradient, BLMatrix2D? inv)
      : _x0 = gradient.p0.x,
        _y0 = gradient.p0.y,
        _dx = gradient.p1.x - gradient.p0.x,
        _dy = gradient.p1.y - gradient.p0.y,
        _invLen2 = _computeInvLen2(gradient),
        _hasTransform = inv != null,
        _i00 = inv?.m00 ?? 1.0,
        _i01 = inv?.m01 ?? 0.0,
        _i10 = inv?.m10 ?? 0.0,
        _i11 = inv?.m11 ?? 1.0,
        _i20 = inv?.m20 ?? 0.0,
        _i21 = inv?.m21 ?? 0.0,
        _lut = _buildLut(gradient.stops);

  @pragma('vm:prefer-inline')
  int fetch(int x, int y) {
    if (_invLen2 == 0.0) return _lut[0];

    double px = x + 0.5;
    double py = y + 0.5;
    if (_hasTransform) {
      final tx = _i00 * px + _i10 * py + _i20;
      final ty = _i01 * px + _i11 * py + _i21;
      px = tx;
      py = ty;
    }
    final t = ((px - _x0) * _dx + (py - _y0) * _dy) * _invLen2;
    if ((t < 0.0 && !gradient.extendStart) ||
        (t > 1.0 && !gradient.extendEnd)) {
      return 0x00000000;
    }
    final tc = _applyExtend(t, gradient.extendMode);
    final idx = (tc * (_kLutSize - 1)).round();
    return _lut[idx];
  }

  @pragma('vm:prefer-inline')
  static double _applyExtend(double t, BLGradientExtendMode mode) {
    switch (mode) {
      case BLGradientExtendMode.pad:
        return t < 0.0 ? 0.0 : (t > 1.0 ? 1.0 : t);

      case BLGradientExtendMode.repeat:
        final r = t - t.floorToDouble();
        return r < 0.0 ? r + 1.0 : r;

      case BLGradientExtendMode.reflect:
        final period = t - (t * 0.5).floorToDouble() * 2.0;
        final wrapped = period < 0.0 ? period + 2.0 : period;
        return wrapped <= 1.0 ? wrapped : 2.0 - wrapped;
    }
  }

  static double _computeInvLen2(BLLinearGradient gradient) {
    final dx = gradient.p1.x - gradient.p0.x;
    final dy = gradient.p1.y - gradient.p0.y;
    final len2 = dx * dx + dy * dy;
    return len2 <= 1e-20 ? 0.0 : 1.0 / len2;
  }

  static Uint32List _buildLut(List<BLGradientStop> inputStops) {
    final lut = Uint32List(_kLutSize);
    if (inputStops.isEmpty) {
      lut.fillRange(0, _kLutSize, 0xFF000000);
      return lut;
    }

    final stops = List<BLGradientStop>.from(inputStops)
      ..sort((a, b) => a.offset.compareTo(b.offset));

    final first = stops.first;
    final last = stops.last;

    for (int i = 0; i < _kLutSize; i++) {
      final t = i / (_kLutSize - 1);
      if (t <= first.offset) {
        lut[i] = first.color;
        continue;
      }
      if (t >= last.offset) {
        lut[i] = last.color;
        continue;
      }

      int seg = 0;
      while (seg + 1 < stops.length && t > stops[seg + 1].offset) {
        seg++;
      }

      final a = stops[seg];
      final b = stops[seg + 1];
      final denom = math.max(1e-12, b.offset - a.offset);
      final u = (t - a.offset) / denom;
      lut[i] = _lerpColor(a.color, b.color, u);
    }

    return lut;
  }

  static int _lerpColor(int c0, int c1, double t) {
    final a0 = (c0 >>> 24) & 0xFF;
    final r0 = (c0 >>> 16) & 0xFF;
    final g0 = (c0 >>> 8) & 0xFF;
    final b0 = c0 & 0xFF;

    final a1 = (c1 >>> 24) & 0xFF;
    final r1 = (c1 >>> 16) & 0xFF;
    final g1 = (c1 >>> 8) & 0xFF;
    final b1 = c1 & 0xFF;

    final a = (a0 + (a1 - a0) * t).round().clamp(0, 255);
    final r = (r0 + (r1 - r0) * t).round().clamp(0, 255);
    final g = (g0 + (g1 - g0) * t).round().clamp(0, 255);
    final b = (b0 + (b1 - b0) * t).round().clamp(0, 255);

    return (a << 24) | (r << 16) | (g << 8) | b;
  }
}
