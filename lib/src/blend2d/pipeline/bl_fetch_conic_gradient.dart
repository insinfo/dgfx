import 'dart:math' as math;
import 'dart:typed_data';

import '../core/bl_types.dart';
import 'bl_gradient_lut.dart';

class BLConicGradientFetcher {
  static const double _inv2Pi = 1.0 / (2.0 * math.pi);

  final BLConicGradient gradient;
  final Uint32List _lut;

  final double _cx;
  final double _cy;
  final double _angle;

  /// Inversa de [BLConicGradient.transform]: leva o pixel de device de volta
  /// ao espaço em que o centro e o ângulo foram definidos.
  final bool _hasTransform;
  final double _i00;
  final double _i01;
  final double _i10;
  final double _i11;
  final double _i20;
  final double _i21;

  factory BLConicGradientFetcher(BLConicGradient gradient) {
    final m = gradient.transform;
    // Matriz degenerada não tem volta: tratar como identidade evita NaN.
    final inv = m.isIdentity ? null : m.invert();
    return BLConicGradientFetcher._(gradient, inv);
  }

  BLConicGradientFetcher._(this.gradient, BLMatrix2D? inv)
      : _cx = gradient.center.x,
        _cy = gradient.center.y,
        _angle = gradient.angle,
        _hasTransform = inv != null,
        _i00 = inv?.m00 ?? 1.0,
        _i01 = inv?.m01 ?? 0.0,
        _i10 = inv?.m10 ?? 0.0,
        _i11 = inv?.m11 ?? 1.0,
        _i20 = inv?.m20 ?? 0.0,
        _i21 = inv?.m21 ?? 0.0,
        _lut = BLGradientLut.build(gradient.stops);

  @pragma('vm:prefer-inline')
  int fetch(int x, int y) {
    double px = x + 0.5;
    double py = y + 0.5;
    if (_hasTransform) {
      final tx = _i00 * px + _i10 * py + _i20;
      final ty = _i01 * px + _i11 * py + _i21;
      px = tx;
      py = ty;
    }

    final dx = px - _cx;
    final dy = py - _cy;

    double angle = math.atan2(dy, dx) - _angle;
    // Normalize to [0, 2pi)
    if (angle < 0.0) angle += 2.0 * math.pi;
    if (angle >= 2.0 * math.pi) angle -= 2.0 * math.pi;

    double t = angle * _inv2Pi;
    final tc = _applyExtend(t, gradient.extendMode);

    // Fallback clamps just in case of float issues
    int idx = (tc * (_lut.length - 1)).round();
    if (idx < 0) idx = 0;
    if (idx >= _lut.length) idx = _lut.length - 1;

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
}
