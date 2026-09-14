/*
 * Copyright (c) 2007, 2015, Oracle and/or its affiliates. All rights reserved.
 * DO NOT ALTER OR REMOVE COPYRIGHT NOTICES OR THIS FILE HEADER.
 *
 * This code is free software; you can redistribute it and/or modify it
 * under the terms of the GNU General Public License version 2 only, as
 * published by the Free Software Foundation.  Oracle designates this
 * particular file as subject to the "Classpath" exception as provided
 * by Oracle in the LICENSE file that accompanied this code.
 *
 * This code is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 * FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
 * version 2 for more details (a copy is included in the LICENSE file that
 * accompanied this code).
 *
 * You should have received a copy of the GNU General Public License version
 * 2 along with this work; if not, write to the Free Software Foundation,
 * Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301 USA.
 *
 * Please contact Oracle, 500 Oracle Parkway, Redwood Shores, CA 94065 USA
 * or visit www.oracle.com if you need additional information or have any
 * questions.
 */

/*
 * MODIFICADO: este arquivo e uma traducao para Dart do Marlin renderer do
 * OpenJDK (org.marlin.pisces / sun.java2d.marlin), feita por Isaque Neves em
 * 2026. A traducao e uma obra derivada e permanece sob a GNU General Public
 * License versao 2 com a Classpath Exception, exatamente como o original.
 *
 * Este diretorio NAO faz parte do pacote `dgfx` publicado no pub.dev, que e
 * licenciado sob MIT. Veja `third_party/marlin_openjdk/README.md`.
 */

import 'helpers.dart';

/// Curve representation for handling cubic and quadratic Bezier curves.
/// Stores polynomial coefficients for efficient evaluation.
class Curve {
  // Polynomial coefficients for x: ax*t^3 + bx*t^2 + cx*t + dx
  double ax = 0, ay = 0;
  double bx = 0, by = 0;
  double cx = 0, cy = 0;
  double dx = 0, dy = 0;

  // Derivative coefficients
  double dax = 0, day = 0;
  double dbx = 0, dby = 0;

  // shared iterator instance
  final BreakPtrIterator _iterator = BreakPtrIterator();

  Curve();

  /// Set from point array based on type (6 for quad, 8 for cubic)
  void setFromPoints(List<double> points, int type) {
    switch (type) {
      case 8:
        setCubic(
          points[0],
          points[1],
          points[2],
          points[3],
          points[4],
          points[5],
          points[6],
          points[7],
        );
        break;
      case 6:
        setQuad(
          points[0],
          points[1],
          points[2],
          points[3],
          points[4],
          points[5],
        );
        break;
      default:
        throw ArgumentError('Curves can only be cubic or quadratic');
    }
  }

  /// Set cubic Bezier curve from 4 control points
  void setCubic(
    double x1,
    double y1,
    double x2,
    double y2,
    double x3,
    double y3,
    double x4,
    double y4,
  ) {
    // Compute polynomial coefficients
    ax = 3.0 * (x2 - x3) + x4 - x1;
    ay = 3.0 * (y2 - y3) + y4 - y1;
    bx = 3.0 * (x1 - 2.0 * x2 + x3);
    by = 3.0 * (y1 - 2.0 * y2 + y3);
    cx = 3.0 * (x2 - x1);
    cy = 3.0 * (y2 - y1);
    dx = x1;
    dy = y1;

    // Derivative coefficients
    dax = 3.0 * ax;
    day = 3.0 * ay;
    dbx = 2.0 * bx;
    dby = 2.0 * by;
  }

  /// Set quadratic Bezier curve from 3 control points
  void setQuad(
    double x1,
    double y1,
    double x2,
    double y2,
    double x3,
    double y3,
  ) {
    ax = 0;
    ay = 0;
    bx = x1 - 2.0 * x2 + x3;
    by = y1 - 2.0 * y2 + y3;
    cx = 2.0 * (x2 - x1);
    cy = 2.0 * (y2 - y1);
    dx = x1;
    dy = y1;

    dax = 0;
    day = 0;
    dbx = 2.0 * bx;
    dby = 2.0 * by;
  }

  /// Evaluate x at parameter t
  double xAt(double t) {
    return t * (t * (t * ax + bx) + cx) + dx;
  }

  /// Evaluate y at parameter t
  double yAt(double t) {
    return t * (t * (t * ay + by) + cy) + dy;
  }

  /// Evaluate dx/dt at parameter t
  double dxAt(double t) {
    return t * (t * dax + dbx) + cx;
  }

  /// Evaluate dy/dt at parameter t
  double dyAt(double t) {
    return t * (t * day + dby) + cy;
  }

  /// Find roots of dx/dt = 0
  int dxRoots(List<double> roots, int off) {
    return Helpers.quadraticRoots(dax, dbx, cx, roots, off);
  }

  /// Find roots of dy/dt = 0
  int dyRoots(List<double> roots, int off) {
    return Helpers.quadraticRoots(day, dby, cy, roots, off);
  }

  /// Find inflection points
  int infPoints(List<double> pts, int off) {
    // inflection point at t if -f'(t)x*f''(t)y + f'(t)y*f''(t)x == 0
    final double a = dax * dby - dbx * day;
    final double b = 2.0 * (cy * dax - day * cx);
    final double c = cy * dbx - cx * dby;
    return Helpers.quadraticRoots(a, b, c, pts, off);
  }

  // finds points where the first and second derivative are
  // perpendicular. This happens when g(t) = f'(t)*f''(t) == 0 (where
  // * is a dot product).
  int perpendiculardfddf(List<double> pts, int off) {
    final double a = 2.0 * (dax * dax + day * day);
    final double b = 3.0 * (dax * dbx + day * dby);
    final double c = 2.0 * (dax * cx + day * cy) + dbx * dbx + dby * dby;
    final double d = dbx * cx + dby * cy;
    return Helpers.cubicRootsInAB(d, a, b, c, pts, off, 0.0, 1.0);
  }

  int rootsOfROCMinusW(List<double> roots, int off, double w, double err) {
    int ret = off;
    int numPerpdfddf = perpendiculardfddf(roots, off);
    double t0 = 0.0;
    double ft0 = _ROCsq(t0) - w * w;

    roots[off + numPerpdfddf] = 1.0;
    numPerpdfddf++;

    for (int i = off; i < off + numPerpdfddf; i++) {
      double t1 = roots[i];
      double ft1 = _ROCsq(t1) - w * w;
      if (ft0 == 0.0) {
        roots[ret++] = t0;
      } else if (ft1 * ft0 < 0.0) {
        roots[ret++] = _falsePositionROCsqMinusX(t0, t1, w * w, err);
      }
      t0 = t1;
      ft0 = ft1;
    }
    return ret - off;
  }

  double _ROCsq(double t) {
    final double dx = t * (t * dax + dbx) + cx;
    final double dy = t * (t * day + dby) + cy;
    final double ddx = 2.0 * dax * t + dbx;
    final double ddy = 2.0 * day * t + dby;
    final double dx2dy2 = dx * dx + dy * dy;
    final double ddx2ddy2 = ddx * ddx + ddy * ddy;
    final double ddxdxddydy = ddx * dx + ddy * dy;
    double denom = dx2dy2 * ddx2ddy2 - ddxdxddydy * ddxdxddydy;
    if (denom == 0)
      return double.infinity; // Prevent NaN if possible, or handle
    return dx2dy2 * ((dx2dy2 * dx2dy2) / denom);
  }

  double _eliminateInf(double x) {
    if (x == double.infinity) return double.maxFinite;
    if (x == double.negativeInfinity)
      return double.minPositive; // or -maxFinite?
    return x;
  }

  double _falsePositionROCsqMinusX(double x0, double x1, double x, double err) {
    const int iterLimit = 100;
    int side = 0;
    double t = x1;
    double ft = _eliminateInf(_ROCsq(t) - x);
    double s = x0;
    double fs = _eliminateInf(_ROCsq(s) - x);
    double r = s;

    for (int i = 0; i < iterLimit && (t - s).abs() > err * (t + s).abs(); i++) {
      r = (fs * t - ft * s) / (fs - ft);
      double fr = _ROCsq(r) - x;
      if (_sameSign(fr, ft)) {
        ft = fr;
        t = r;
        if (side < 0) {
          fs /= (1 << (-side));
          side--;
        } else {
          side = -1;
        }
      } else if (fr * fs > 0.0) {
        fs = fr;
        s = r;
        if (side > 0) {
          ft /= (1 << side);
          side++;
        } else {
          side = 1;
        }
      } else {
        break;
      }
    }
    return r;
  }

  bool _sameSign(double x, double y) {
    return (x < 0.0 && y < 0.0) || (x > 0.0 && y > 0.0);
  }

  BreakPtrIterator breakPtsAtTs(
      List<double> pts, int type, List<double> Ts, int numTs) {
    _iterator.init(pts, type, Ts, numTs);
    return _iterator;
  }
}

class BreakPtrIterator {
  int _nextCurveIdx = 0;
  int _curCurveOff = 0;
  double _prevT = 0.0;
  List<double>? _pts;
  int _type = 0;
  List<double>? _ts;
  int _numTs = 0;

  void init(List<double> pts, int type, List<double> ts, int numTs) {
    _pts = pts;
    _type = type;
    _ts = ts;
    _numTs = numTs;
    _nextCurveIdx = 0;
    _curCurveOff = 0;
    _prevT = 0.0;
  }

  bool hasNext() {
    return _nextCurveIdx <= _numTs;
  }

  int next() {
    int ret;
    if (_nextCurveIdx < _numTs) {
      double curT = _ts![_nextCurveIdx];
      double splitT = (curT - _prevT) / (1.0 - _prevT);
      Helpers.subdivideAt(
          splitT, _pts!, _curCurveOff, _pts, 0, _pts, _type, _type);
      _prevT = curT;
      ret = 0;
      _curCurveOff = _type;
    } else {
      ret = _curCurveOff;
    }
    _nextCurveIdx++;
    return ret;
  }
}
