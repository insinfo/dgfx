import 'dart:math' as math;
import 'dart:typed_data';

import '../core/bl_types.dart';
import 'bl_gradient_lut.dart';

class _BLRadialParams {
  final double x0;
  final double y0;
  final double dcx;
  final double dcy;
  final double a;
  final double invA;
  final bool isLinear;
  final double r0Sq;
  final double r0Dr;

  const _BLRadialParams({
    required this.x0,
    required this.y0,
    required this.dcx,
    required this.dcy,
    required this.a,
    required this.invA,
    required this.isLinear,
    required this.r0Sq,
    required this.r0Dr,
  });
}

class BLRadialGradientFetcher {
  static const double _kEpsilon = 1e-20;
  static const double _kFocalDistLimit = 0.5;

  final BLRadialGradient gradient;
  final Uint32List _lut;

  final double _x0;
  final double _y0;
  final double _dcx;
  final double _dcy;

  final double _a;
  final double _invA;
  final bool _isLinear;
  final double _r0Sq;
  final double _r0Dr;

  /// Inversa de [BLRadialGradient.transform]: leva o pixel de device de volta
  /// ao espaço em que centros e raios foram definidos. É o que permite a um
  /// `/Pattern` com `/Matrix [2 0 0 1 0 0]` render uma elipse.
  final bool _hasTransform;
  final double _i00;
  final double _i01;
  final double _i10;
  final double _i11;
  final double _i20;
  final double _i21;

  factory BLRadialGradientFetcher(BLRadialGradient gradient) {
    final params = _prepare(gradient);
    final m = gradient.transform;
    // Matriz degenerada não tem volta: tratar como identidade evita NaN.
    final inv = m.isIdentity ? null : m.invert();
    return BLRadialGradientFetcher._(gradient, params, inv);
  }

  BLRadialGradientFetcher._(this.gradient, _BLRadialParams params,
      BLMatrix2D? inv)
      : _hasTransform = inv != null,
        _i00 = inv?.m00 ?? 1.0,
        _i01 = inv?.m01 ?? 0.0,
        _i10 = inv?.m10 ?? 0.0,
        _i11 = inv?.m11 ?? 1.0,
        _i20 = inv?.m20 ?? 0.0,
        _i21 = inv?.m21 ?? 0.0,
        _x0 = params.x0,
        _y0 = params.y0,
        _dcx = params.dcx,
        _dcy = params.dcy,
        _a = params.a,
        _invA = params.invA,
        _isLinear = params.isLinear,
        _r0Sq = params.r0Sq,
        _r0Dr = params.r0Dr,
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

    final vx = px - _x0;
    final vy = py - _y0;

    final b = vx * _dcx + vy * _dcy + _r0Dr;
    final c = vx * vx + vy * vy - _r0Sq;

    final t = _solveT(_isLinear, _a, _invA, b, c);
    if ((t < 0.0 && !gradient.extendStart) ||
        (t > 1.0 && !gradient.extendEnd)) {
      return 0x00000000;
    }
    final tc = _applyExtend(t, gradient.extendMode);
    final idx = (tc * (_lut.length - 1)).round();
    return _lut[idx];
  }

  @pragma('vm:prefer-inline')
  static double _solveT(
      bool isLinear, double a, double invA, double b, double c) {
    if (isLinear) {
      if (b.abs() < _kEpsilon) return 0.0;
      return c / (2.0 * b);
    }

    final disc = b * b - a * c;
    if (disc <= 0.0) return b * invA;

    final root = math.sqrt(disc);
    final numer = a >= 0.0 ? (b + root) : (b - root);
    return numer * invA;
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

  static _BLRadialParams _prepare(BLRadialGradient gradient) {
    final x0 = gradient.c0.x;
    final y0 = gradient.c0.y;
    final r0 = gradient.r0;
    final r1 = gradient.r1;

    double dcx = gradient.c1.x - x0;
    double dcy = gradient.c1.y - y0;
    final dr = r1 - r0;

    final sqDist = dcx * dcx + dcy * dcy;
    final dist = math.sqrt(sqDist);
    final distFromBorder = (dist - dr).abs();

    if (dist > _kEpsilon && distFromBorder < _kFocalDistLimit) {
      final scale0 = (dr - _kFocalDistLimit) / dist;
      final scale1 = (dr + _kFocalDistLimit) / dist;

      final dcx0 = dcx * scale0;
      final dcy0 = dcy * scale0;
      final dcx1 = dcx * scale1;
      final dcy1 = dcy * scale1;

      final d0 = ((dcx0 * dcx0 + dcy0 * dcy0) - sqDist).abs();
      final d1 = ((dcx1 * dcx1 + dcy1 * dcy1) - sqDist).abs();

      if (d0 < d1) {
        dcx = dcx0;
        dcy = dcy0;
      } else {
        dcx = dcx1;
        dcy = dcy1;
      }
    }

    final a = dcx * dcx + dcy * dcy - dr * dr;
    final isLinear = a.abs() < _kEpsilon;
    final invA = isLinear ? 0.0 : 1.0 / a;

    return _BLRadialParams(
      x0: x0,
      y0: y0,
      dcx: dcx,
      dcy: dcy,
      a: a,
      invA: invA,
      isLinear: isLinear,
      r0Sq: r0 * r0,
      r0Dr: r0 * dr,
    );
  }
}
