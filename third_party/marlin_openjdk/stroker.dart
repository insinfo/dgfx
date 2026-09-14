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

import 'dart:math' as math;
import 'dart:typed_data';
import 'helpers.dart';
import 'curve.dart';
import 'path_consumer_2d.dart';
import 'context/renderer_context.dart';

class Stroker implements PathConsumer2D {
  static const int MOVE_TO = 0;
  static const int DRAWING_OP_TO = 1;
  static const int CLOSE = 2;

  static const int JOIN_MITER = 0;
  static const int JOIN_ROUND = 1;
  static const int JOIN_BEVEL = 2;

  static const int CAP_BUTT = 0;
  static const int CAP_ROUND = 1;
  static const int CAP_SQUARE = 2;

  // 1000/65536f
  static const double ROUND_JOIN_THRESHOLD = 1000.0 / 65536.0;
  static const double C = 0.5522847498307933;
  static const int MAX_N_CURVES = 11;

  PathConsumer2D? _out;
  int _capStyle = CAP_BUTT;
  int _joinStyle = JOIN_MITER;
  double _lineWidth2 = 0.0;

  final Float64List _offset0 = Float64List(2);
  final Float64List _offset1 = Float64List(2);
  final Float64List _offset2 = Float64List(2);
  final Float64List _miter = Float64List(2);
  double _miterLimitSq = 0.0;

  int _prev = CLOSE;

  double _sx0 = 0, _sy0 = 0, _sdx = 0, _sdy = 0;
  double _cx0 = 0, _cy0 = 0, _cdx = 0, _cdy = 0;
  double _smx = 0, _smy = 0, _cmx = 0, _cmy = 0;

  late final PolyStack _reverse;
  late final Curve _curve;

  // Work buffers
  final Float64List _middle = Float64List(2 * 8);
  final Float64List _lp = Float64List(8);
  final Float64List _rp = Float64List(8);
  final Float64List _subdivTs = Float64List(MAX_N_CURVES - 1);

  Stroker(RendererContext rdrCtx) {
    _reverse = PolyStack(rdrCtx);
    _curve = Curve();
  }

  Stroker init(PathConsumer2D pc2d, double lineWidth, int capStyle,
      int joinStyle, double miterLimit) {
    _out = pc2d;
    _lineWidth2 = lineWidth / 2.0;
    _capStyle = capStyle;
    _joinStyle = joinStyle;

    double limit = miterLimit * _lineWidth2;
    _miterLimitSq = limit * limit;

    _prev = CLOSE;
    return this;
  }

  void dispose() {
    _reverse.dispose();
  }

  static void computeOffset(double lx, double ly, double w, Float64List m) {
    double len = lx * lx + ly * ly;
    if (len == 0.0) {
      m[0] = 0.0;
      m[1] = 0.0;
    } else {
      len = math.sqrt(len);
      m[0] = (ly * w) / len;
      m[1] = -(lx * w) / len;
    }
  }

  static bool isCW(double dx1, double dy1, double dx2, double dy2) {
    return dx1 * dy2 <= dy1 * dx2;
  }

  @override
  void moveTo(double x0, double y0) {
    if (_prev == DRAWING_OP_TO) {
      finish();
    }
    _sx0 = _cx0 = x0;
    _sy0 = _cy0 = y0;
    _cdx = _sdx = 1.0;
    _cdy = _sdy = 0.0;
    _prev = MOVE_TO;
  }

  @override
  void lineTo(double x1, double y1) {
    double dx = x1 - _cx0;
    double dy = y1 - _cy0;
    if (dx == 0.0 && dy == 0.0) {
      dx = 1.0;
    }
    computeOffset(dx, dy, _lineWidth2, _offset0);
    double mx = _offset0[0];
    double my = _offset0[1];

    _drawJoin(_cdx, _cdy, _cx0, _cy0, dx, dy, _cmx, _cmy, mx, my);

    _emitLineTo(_cx0 + mx, _cy0 + my);
    _emitLineTo(x1 + mx, y1 + my);

    _emitLineToRev(_cx0 - mx, _cy0 - my);
    _emitLineToRev(x1 - mx, y1 - my);

    _cmx = mx;
    _cmy = my;
    _cdx = dx;
    _cdy = dy;
    _cx0 = x1;
    _cy0 = y1;
    _prev = DRAWING_OP_TO;
  }

  @override
  void closePath() {
    if (_prev != DRAWING_OP_TO) {
      if (_prev == CLOSE) return;
      _emitMoveTo(_cx0, _cy0 - _lineWidth2);
      _cmx = _smx = 0.0;
      _cmy = _smy = -_lineWidth2;
      _cdx = _sdx = 1.0;
      _cdy = _sdy = 0.0;
      finish();
      return;
    }

    if (_cx0 != _sx0 || _cy0 != _sy0) {
      lineTo(_sx0, _sy0);
    }

    _drawJoin(_cdx, _cdy, _cx0, _cy0, _sdx, _sdy, _cmx, _cmy, _smx, _smy);

    _emitLineTo(_sx0 + _smx, _sy0 + _smy);
    _emitMoveTo(_sx0 - _smx, _sy0 - _smy);
    _emitReverse();

    _prev = CLOSE;
    _emitClose();
  }

  @override
  void pathDone() {
    if (_prev == DRAWING_OP_TO) {
      finish();
    }
    _out?.pathDone();
    _prev = CLOSE;
    dispose();
  }

  void finish() {
    if (_capStyle == CAP_ROUND) {
      _drawRoundCap(_cx0, _cy0, _cmx, _cmy);
    } else if (_capStyle == CAP_SQUARE) {
      _emitLineTo(_cx0 - _cmy + _cmx, _cy0 + _cmx + _cmy);
      _emitLineTo(_cx0 - _cmy - _cmx, _cy0 + _cmx - _cmy);
    }

    _emitReverse();

    if (_capStyle == CAP_ROUND) {
      _drawRoundCap(_sx0, _sy0, -_smx, -_smy);
    } else if (_capStyle == CAP_SQUARE) {
      _emitLineTo(_sx0 + _smy - _smx, _sy0 - _smx - _smy);
      _emitLineTo(_sx0 + _smy + _smx, _sy0 - _smx + _smy);
    }

    _emitClose();
  }

  void _drawJoin(double pdx, double pdy, double x0, double y0, double dx,
      double dy, double omx, double omy, double mx, double my) {
    if (_prev != DRAWING_OP_TO) {
      _emitMoveTo(x0 + mx, y0 + my);
      _sdx = dx;
      _sdy = dy;
      _smx = mx;
      _smy = my;
    } else {
      bool cw = isCW(pdx, pdy, dx, dy);
      if (_joinStyle == JOIN_MITER) {
        _drawMiter(pdx, pdy, x0, y0, dx, dy, omx, omy, mx, my, cw);
      } else if (_joinStyle == JOIN_ROUND) {
        _drawRoundJoin(x0, y0, omx, omy, mx, my, cw, ROUND_JOIN_THRESHOLD);
      }
      _emitLineToBool(x0, y0, !cw);
    }
    _prev = DRAWING_OP_TO;
  }

  void _drawRoundJoin(double cx, double cy, double omx, double omy, double mx,
      double my, bool rev, double threshold) {
    if ((omx == 0 && omy == 0) || (mx == 0 && my == 0)) return;

    double domx = omx - mx;
    double domy = omy - my;
    double len = domx * domx + domy * domy;
    if (len < threshold) return;

    if (rev) {
      omx = -omx;
      omy = -omy;
      mx = -mx;
      my = -my;
    }
    _drawRoundJoinInternal(cx, cy, omx, omy, mx, my, rev);
  }

  void _drawRoundJoinInternal(double cx, double cy, double omx, double omy,
      double mx, double my, bool rev) {
    double cosext = omx * mx + omy * my;
    final int numCurves = cosext >= 0 ? 1 : 2;

    if (numCurves == 1) {
      _drawBezApproxForArc(cx, cy, omx, omy, mx, my, rev);
    } else if (numCurves == 2) {
      double nx = my - omy;
      double ny = omx - mx;
      double nlen = math.sqrt(nx * nx + ny * ny);
      double scale = _lineWidth2 / nlen;
      double mmx = nx * scale;
      double mmy = ny * scale;

      if (rev) {
        mmx = -mmx;
        mmy = -mmy;
      }
      _drawBezApproxForArc(cx, cy, omx, omy, mmx, mmy, rev);
      _drawBezApproxForArc(cx, cy, mmx, mmy, mx, my, rev);
    }
  }

  void _drawBezApproxForArc(double cx, double cy, double omx, double omy,
      double mx, double my, bool rev) {
    double cosext2 = (omx * mx + omy * my) / (2.0 * _lineWidth2 * _lineWidth2);
    double numer = 0.5 - cosext2;
    if (numer < 0.0) numer = 0.0;
    double cv =
        (4.0 / 3.0) * math.sqrt(numer) / (1.0 + math.sqrt(cosext2 + 0.5));
    if (rev) cv = -cv;

    final double x1 = cx + omx;
    final double y1 = cy + omy;
    final double x2 = x1 - cv * omy;
    final double y2 = y1 + cv * omx;

    final double x4 = cx + mx;
    final double y4 = cy + my;
    final double x3 = x4 + cv * my;
    final double y3 = y4 - cv * mx;

    _emitCurveToRevFlag(x1, y1, x2, y2, x3, y3, x4, y4, rev);
  }

  void _drawRoundCap(double cx, double cy, double mx, double my) {
    _emitCurveTo(cx + mx - C * my, cy + my + C * mx, cx - my + C * mx,
        cy + mx + C * my, cx - my, cy + mx);
    _emitCurveTo(cx - my - C * mx, cy + mx - C * my, cx - mx - C * my,
        cy - my + C * mx, cx - mx, cy - my);
  }

  void _drawMiter(double pdx, double pdy, double x0, double y0, double dx,
      double dy, double omx, double omy, double mx, double my, bool rev) {
    if ((mx == omx && my == omy) ||
        (pdx == 0 && pdy == 0) ||
        (dx == 0 && dy == 0)) return;

    if (rev) {
      omx = -omx;
      omy = -omy;
      mx = -mx;
      my = -my;
    }

    computeIntersection((x0 - pdx) + omx, (y0 - pdy) + omy, x0 + omx, y0 + omy,
        (dx + x0) + mx, (dy + y0) + my, x0 + mx, y0 + my, _miter, 0);

    final double miterX = _miter[0];
    final double miterY = _miter[1];
    double lenSq =
        (miterX - x0) * (miterX - x0) + (miterY - y0) * (miterY - y0);

    if (lenSq < _miterLimitSq) {
      _emitLineToBool(miterX, miterY, rev);
    }
  }

  static void computeIntersection(double x0, double y0, double x1, double y1,
      double x0p, double y0p, double x1p, double y1p, Float64List m, int off) {
    double x10 = x1 - x0;
    double y10 = y1 - y0;
    double x10p = x1p - x0p;
    double y10p = y1p - y0p;

    double den = x10 * y10p - x10p * y10;
    if (den == 0.0) {
      m[off] = x0;
      m[off + 1] = y0;
      return;
    } // prevent NaN
    double t = x10p * (y0 - y0p) - y10p * (x0 - x0p);
    t /= den;
    m[off] = x0 + t * x10;
    m[off + 1] = y0 + t * y10;
  }

  // Emitting methods
  void _emitMoveTo(double x0, double y0) => _out!.moveTo(x0, y0);
  void _emitLineTo(double x1, double y1) => _out!.lineTo(x1, y1);
  void _emitLineToRev(double x1, double y1) => _reverse.pushLine(x1, y1);

  void _emitLineToBool(double x1, double y1, bool rev) {
    if (rev) {
      _emitLineToRev(x1, y1);
    } else {
      _emitLineTo(x1, y1);
    }
  }

  void _emitQuadTo(double x1, double y1, double x2, double y2) =>
      _out!.quadTo(x1, y1, x2, y2);
  void _emitQuadToRev(double x0, double y0, double x1, double y1) =>
      _reverse.pushQuad(x0, y0, x1, y1);
  void _emitCurveTo(
          double x1, double y1, double x2, double y2, double x3, double y3) =>
      _out!.curveTo(x1, y1, x2, y2, x3, y3);
  void _emitCurveToRev(
          double x0, double y0, double x1, double y1, double x2, double y2) =>
      _reverse.pushCubic(x0, y0, x1, y1, x2, y2);

  void _emitCurveToRevFlag(double x0, double y0, double x1, double y1,
      double x2, double y2, double x3, double y3, bool rev) {
    if (rev) {
      _reverse.pushCubic(x0, y0, x1, y1, x2, y2);
    } else {
      _out!.curveTo(x1, y1, x2, y2, x3, y3);
    }
  }

  void _emitClose() => _out!.closePath();
  void _emitReverse() => _reverse.popAll(_out!);

  @override
  void quadTo(double x1, double y1, double x2, double y2) {
    final mid = _middle;
    mid[0] = _cx0;
    mid[1] = _cy0;
    mid[2] = x1;
    mid[3] = y1;
    mid[4] = x2;
    mid[5] = y2;

    // Check degenerate
    double dxs = mid[2] - mid[0];
    double dys = mid[3] - mid[1];
    double dxf = mid[4] - mid[2];
    double dyf = mid[5] - mid[3];
    if ((dxs == 0.0 && dys == 0.0) || (dxf == 0.0 && dyf == 0.0)) {
      dxs = dxf = mid[4] - mid[0];
      dys = dyf = mid[5] - mid[1];
    }
    if (dxs == 0.0 && dys == 0.0) {
      lineTo(mid[4], mid[5]);
      return;
    }
    if (dxs.abs() < 0.1 && dys.abs() < 0.1) {
      double len = math.sqrt(dxs * dxs + dys * dys);
      dxs /= len;
      dys /= len;
    }
    if (dxf.abs() < 0.1 && dyf.abs() < 0.1) {
      double len = math.sqrt(dxf * dxf + dyf * dyf);
      dxf /= len;
      dyf /= len;
    }

    computeOffset(dxs, dys, _lineWidth2, _offset0);
    _drawJoin(
        _cdx, _cdy, _cx0, _cy0, dxs, dys, _cmx, _cmy, _offset0[0], _offset0[1]);

    int nSplits = findSubdivPoints(_curve, mid, _subdivTs, 6, _lineWidth2);
    final l = _lp;
    final r = _rp;

    int kind = 0;
    BreakPtrIterator it = _curve.breakPtsAtTs(mid, 6, _subdivTs, nSplits);
    while (it.hasNext()) {
      int curCurveOff = it.next();

      kind = _computeOffsetQuad(mid, curCurveOff, l, r);
      _emitLineTo(l[0], l[1]);

      if (kind == 6) {
        _emitQuadTo(l[2], l[3], l[4], l[5]);
        _emitQuadToRev(r[0], r[1], r[2], r[3]);
      } else {
        // 4
        _emitLineTo(l[2], l[3]);
        _emitLineToRev(r[0], r[1]);
      }
      _emitLineToRev(r[kind - 2], r[kind - 1]);
    }

    _cmx = (l[kind - 2] - r[kind - 2]) / 2.0;
    _cmy = (l[kind - 1] - r[kind - 1]) / 2.0;
    _cdx = dxf;
    _cdy = dyf;
    _cx0 = x2; // xf
    _cy0 = y2;
    _prev = DRAWING_OP_TO;
  }

  @override
  void curveTo(
      double x1, double y1, double x2, double y2, double x3, double y3) {
    final mid = _middle;
    mid[0] = _cx0;
    mid[1] = _cy0;
    mid[2] = x1;
    mid[3] = y1;
    mid[4] = x2;
    mid[5] = y2;
    mid[6] = x3;
    mid[7] = y3;

    double dxs = mid[2] - mid[0];
    double dys = mid[3] - mid[1];
    double dxf = mid[6] - mid[4];
    double dyf = mid[7] - mid[5];

    bool p1eqp2 = (dxs == 0.0 && dys == 0.0);
    bool p3eqp4 = (dxf == 0.0 && dyf == 0.0);
    if (p1eqp2) {
      dxs = mid[4] - mid[0];
      dys = mid[5] - mid[1];
      if (dxs == 0.0 && dys == 0.0) {
        dxs = mid[6] - mid[0];
        dys = mid[7] - mid[1];
      }
    }
    if (p3eqp4) {
      dxf = mid[6] - mid[2];
      dyf = mid[7] - mid[3];
      if (dxf == 0.0 && dyf == 0.0) {
        dxf = mid[6] - mid[0];
        dyf = mid[7] - mid[1];
      }
    }
    if (dxs == 0.0 && dys == 0.0) {
      lineTo(mid[6], mid[7]);
      return;
    }

    // normalize small
    if (dxs.abs() < 0.1 && dys.abs() < 0.1) {
      double len = math.sqrt(dxs * dxs + dys * dys);
      dxs /= len;
      dys /= len;
    }
    if (dxf.abs() < 0.1 && dyf.abs() < 0.1) {
      double len = math.sqrt(dxf * dxf + dyf * dyf);
      dxf /= len;
      dyf /= len;
    }

    computeOffset(dxs, dys, _lineWidth2, _offset0);
    _drawJoin(
        _cdx, _cdy, _cx0, _cy0, dxs, dys, _cmx, _cmy, _offset0[0], _offset0[1]);

    int nSplits = findSubdivPoints(_curve, mid, _subdivTs, 8, _lineWidth2);
    final l = _lp;
    final r = _rp;

    int kind = 0;
    BreakPtrIterator it = _curve.breakPtsAtTs(mid, 8, _subdivTs, nSplits);
    while (it.hasNext()) {
      int curCurveOff = it.next();

      kind = _computeOffsetCubic(mid, curCurveOff, l, r);
      _emitLineTo(l[0], l[1]);

      if (kind == 8) {
        _emitCurveTo(l[2], l[3], l[4], l[5], l[6], l[7]);
        _emitCurveToRev(r[0], r[1], r[2], r[3], r[4], r[5]);
      } else {
        _emitLineTo(l[2], l[3]);
        _emitLineToRev(r[0], r[1]);
      }
      _emitLineToRev(r[kind - 2], r[kind - 1]);
    }

    _cmx = (l[kind - 2] - r[kind - 2]) / 2.0;
    _cmy = (l[kind - 1] - r[kind - 1]) / 2.0;
    _cdx = dxf;
    _cdy = dyf;
    _cx0 = x3;
    _cy0 = y3;
    _prev = DRAWING_OP_TO;
  }

  static int findSubdivPoints(
      Curve c, Float64List pts, Float64List ts, int type, double w) {
    double x12 = pts[2] - pts[0];
    double y12 = pts[3] - pts[1];
    if (y12 != 0.0 && x12 != 0.0) {
      double hypot = math.sqrt(x12 * x12 + y12 * y12);
      double cos = x12 / hypot;
      double sin = y12 / hypot;
      double x1 = cos * pts[0] + sin * pts[1];
      double y1 = cos * pts[1] - sin * pts[0];
      double x2 = cos * pts[2] + sin * pts[3];
      double y2 = cos * pts[3] - sin * pts[2];
      double x3 = cos * pts[4] + sin * pts[5];
      double y3 = cos * pts[5] - sin * pts[4];

      if (type == 8) {
        double x4 = cos * pts[6] + sin * pts[7];
        double y4 = cos * pts[7] - sin * pts[6];
        c.setCubic(x1, y1, x2, y2, x3, y3, x4, y4);
      } else {
        c.setQuad(x1, y1, x2, y2, x3, y3);
      }
    } else {
      c.setFromPoints(pts, type);
    }

    int ret = 0;
    ret += c.dxRoots(ts, ret);
    ret += c.dyRoots(ts, ret);
    if (type == 8) {
      ret += c.infPoints(ts, ret);
    }
    ret += c.rootsOfROCMinusW(ts, ret, w, 0.0001);

    ret = Helpers.filterOutNotInAB(ts, 0, ret, 0.0001, 0.9999);
    Helpers.isort(ts, 0, ret);
    return ret;
  }

  static bool within(double x1, double y1, double x2, double y2, double err) {
    return Helpers.within(x1, x2, err) && Helpers.within(y1, y2, err);
  }

  void getLineOffsets(double x1, double y1, double x2, double y2,
      Float64List left, Float64List right) {
    computeOffset(x2 - x1, y2 - y1, _lineWidth2, _offset0);
    double mx = _offset0[0];
    double my = _offset0[1];
    left[0] = x1 + mx;
    left[1] = y1 + my;
    left[2] = x2 + mx;
    left[3] = y2 + my;
    right[0] = x1 - mx;
    right[1] = y1 - my;
    right[2] = x2 - mx;
    right[3] = y2 - my;
  }

  int _computeOffsetCubic(
      Float64List pts, int off, Float64List leftOff, Float64List rightOff) {
    double x1 = pts[off + 0], y1 = pts[off + 1];
    double x2 = pts[off + 2], y2 = pts[off + 3];
    double x3 = pts[off + 4], y3 = pts[off + 5];
    double x4 = pts[off + 6], y4 = pts[off + 7];

    double dx4 = x4 - x3;
    double dy4 = y4 - y3;
    double dx1 = x2 - x1;
    double dy1 = y2 - y1;

    // ulp approximations?
    // Java: 6f * ulp(y2). Dart doesn't expose ulp directly easily (can do, but lets use epsilon small)
    // double ulp(double d) { return d.abs() * 2.22e-16; } // approx

    bool p1eqp2 = within(x1, y1, x2, y2, 1e-6); // using small eps
    bool p3eqp4 = within(x3, y3, x4, y4, 1e-6);

    if (p1eqp2 && p3eqp4) {
      getLineOffsets(x1, y1, x4, y4, leftOff, rightOff);
      return 4;
    } else if (p1eqp2) {
      dx1 = x3 - x1;
      dy1 = y3 - y1;
    } else if (p3eqp4) {
      dx4 = x4 - x2;
      dy4 = y4 - y2;
    }

    double dotsq = (dx1 * dx4 + dy1 * dy4);
    dotsq *= dotsq;
    double l1sq = dx1 * dx1 + dy1 * dy1;
    double l4sq = dx4 * dx4 + dy4 * dy4;

    if (Helpers.within(dotsq, l1sq * l4sq, 1e-6)) {
      getLineOffsets(x1, y1, x4, y4, leftOff, rightOff);
      return 4;
    }

    double x = (x1 + 3.0 * (x2 + x3) + x4) / 8.0;
    double y = (y1 + 3.0 * (y2 + y3) + y4) / 8.0;
    double dxm = x3 + x4 - x1 - x2;
    double dym = y3 + y4 - y1 - y2;

    computeOffset(dx1, dy1, _lineWidth2, _offset0);
    computeOffset(dxm, dym, _lineWidth2, _offset1);
    computeOffset(dx4, dy4, _lineWidth2, _offset2);

    double x1p = x1 + _offset0[0];
    double y1p = y1 + _offset0[1];
    double xi = x + _offset1[0];
    double yi = y + _offset1[1];
    double x4p = x4 + _offset2[0];
    double y4p = y4 + _offset2[1];

    double det = (dx1 * dy4 - dy1 * dx4);
    if (det == 0.0) {
      // Fallback to line
      getLineOffsets(x1, y1, x4, y4, leftOff, rightOff);
      return 4;
    }

    double invdet43 = 4.0 / (3.0 * det);

    double two_pi_m_p1_m_p4x = 2.0 * xi - x1p - x4p;
    double two_pi_m_p1_m_p4y = 2.0 * yi - y1p - y4p;
    double c1 = invdet43 * (dy4 * two_pi_m_p1_m_p4x - dx4 * two_pi_m_p1_m_p4y);
    double c2 = invdet43 * (dx1 * two_pi_m_p1_m_p4y - dy1 * two_pi_m_p1_m_p4x);

    leftOff[0] = x1p;
    leftOff[1] = y1p;
    leftOff[2] = x1p + c1 * dx1;
    leftOff[3] = y1p + c1 * dy1;
    leftOff[4] = x4p + c2 * dx4;
    leftOff[5] = y4p + c2 * dy4;
    leftOff[6] = x4p;
    leftOff[7] = y4p;

    x1p = x1 - _offset0[0];
    y1p = y1 - _offset0[1];
    xi = x - 2.0 * _offset1[0];
    yi = y - 2.0 * _offset1[1];
    x4p = x4 - _offset2[0];
    y4p = y4 - _offset2[1]; // x4p logic in Java slightly diff?
    // Java: xi = xi - 2f * offset1[0]. Wait. Offset1 was added.
    // Right side: subtract offset.
    // In Java: "xi = xi - 2f * offset1[0]". Since xi was x + offset1, new xi is x - offset1. Correct.

    two_pi_m_p1_m_p4x = 2.0 * xi - x1p - x4p;
    two_pi_m_p1_m_p4y = 2.0 * yi - y1p - y4p;
    c1 = invdet43 * (dy4 * two_pi_m_p1_m_p4x - dx4 * two_pi_m_p1_m_p4y);
    c2 = invdet43 * (dx1 * two_pi_m_p1_m_p4y - dy1 * two_pi_m_p1_m_p4x);

    rightOff[0] = x1p;
    rightOff[1] = y1p;
    rightOff[2] = x1p + c1 * dx1;
    rightOff[3] = y1p + c1 * dy1;
    rightOff[4] = x4p + c2 * dx4;
    rightOff[5] = y4p + c2 * dy4;
    rightOff[6] = x4p;
    rightOff[7] = y4p;
    return 8;
  }

  int _computeOffsetQuad(
      Float64List pts, int off, Float64List leftOff, Float64List rightOff) {
    double x1 = pts[off + 0], y1 = pts[off + 1];
    double x2 = pts[off + 2], y2 = pts[off + 3];
    double x3 = pts[off + 4], y3 = pts[off + 5];

    double dx3 = x3 - x2;
    double dy3 = y3 - y2;
    double dx1 = x2 - x1;
    double dy1 = y2 - y1;

    computeOffset(dx1, dy1, _lineWidth2, _offset0);
    computeOffset(dx3, dy3, _lineWidth2, _offset1);

    leftOff[0] = x1 + _offset0[0];
    leftOff[1] = y1 + _offset0[1];
    leftOff[4] = x3 + _offset1[0];
    leftOff[5] = y3 + _offset1[1];
    rightOff[0] = x1 - _offset0[0];
    rightOff[1] = y1 - _offset0[1];
    rightOff[4] = x3 - _offset1[0];
    rightOff[5] = y3 - _offset1[1];

    double x1p = leftOff[0];
    double y1p = leftOff[1];
    double x3p = leftOff[4];
    double y3p = leftOff[5];

    computeIntersection(x1p, y1p, x1p + dx1, y1p + dy1, x3p, y3p, x3p - dx3,
        y3p - dy3, leftOff, 2);
    double cx = leftOff[2];
    double cy = leftOff[3];

    if (!(cx.isFinite && cy.isFinite)) {
      x1p = rightOff[0];
      y1p = rightOff[1];
      x3p = rightOff[4];
      y3p = rightOff[5];
      computeIntersection(x1p, y1p, x1p + dx1, y1p + dy1, x3p, y3p, x3p - dx3,
          y3p - dy3, rightOff, 2);
      cx = rightOff[2];
      cy = rightOff[3];
      if (!(cx.isFinite && cy.isFinite)) {
        getLineOffsets(x1, y1, x3, y3, leftOff, rightOff);
        return 4;
      }
      leftOff[2] = 2.0 * x2 - cx;
      leftOff[3] = 2.0 * y2 - cy;
      return 6;
    }

    rightOff[2] = 2.0 * x2 - cx;
    rightOff[3] = 2.0 * y2 - cy;
    return 6;
  }
}

class PolyStack {
  static const int TYPE_LINETO = 0;
  static const int TYPE_QUADTO = 1;
  static const int TYPE_CUBICTO = 2;

  Float32List _curves;
  int _end = 0;
  Int8List _curveTypes;
  int _numCurves = 0;

  final Float32List _curvesInitial;
  final Int8List _curveTypesInitial;

  PolyStack(RendererContext rdrCtx)
      : _curvesInitial = Float32List(4096),
        _curveTypesInitial = Int8List(4096),
        _curves = Float32List(4096),
        _curveTypes = Int8List(4096) {
    _curves = _curvesInitial;
    _curveTypes = _curveTypesInitial;
  }

  void dispose() {
    _end = 0;
    _numCurves = 0;
    if (_curves != _curvesInitial) {
      _curves = _curvesInitial;
    }
  }

  void ensureSpace(int n) {
    if (_end + n > _curves.length) {
      int newSize = _curves.length * 2;
      var newCurves = Float32List(newSize);
      newCurves.setRange(0, _end, _curves);
      _curves = newCurves;
    }
    if (_numCurves + 1 > _curveTypes.length) {
      int newSize = _curveTypes.length * 2;
      var newTypes = Int8List(newSize);
      newTypes.setRange(0, _numCurves, _curveTypes);
      _curveTypes = newTypes;
    }
  }

  void pushLine(double x, double y) {
    ensureSpace(2);
    _curveTypes[_numCurves++] = TYPE_LINETO;
    _curves[_end++] = x;
    _curves[_end++] = y;
  }

  void pushQuad(double x0, double y0, double x1, double y1) {
    ensureSpace(4);
    _curveTypes[_numCurves++] = TYPE_QUADTO;
    _curves[_end++] = x1;
    _curves[_end++] = y1;
    _curves[_end++] = x0;
    _curves[_end++] = y0;
  }

  void pushCubic(
      double x0, double y0, double x1, double y1, double x2, double y2) {
    ensureSpace(6);
    _curveTypes[_numCurves++] = TYPE_CUBICTO;
    _curves[_end++] = x2;
    _curves[_end++] = y2;
    _curves[_end++] = x1;
    _curves[_end++] = y1;
    _curves[_end++] = x0;
    _curves[_end++] = y0;
  }

  void popAll(PathConsumer2D io) {
    int nc = _numCurves;
    int e = _end;

    while (nc != 0) {
      int type = _curveTypes[--nc];
      switch (type) {
        case TYPE_LINETO:
          e -= 2;
          io.lineTo(_curves[e], _curves[e + 1]);
          break;
        case TYPE_QUADTO:
          e -= 4;
          io.quadTo(_curves[e], _curves[e + 1], _curves[e + 2], _curves[e + 3]);
          break;
        case TYPE_CUBICTO:
          e -= 6;
          io.curveTo(_curves[e], _curves[e + 1], _curves[e + 2], _curves[e + 3],
              _curves[e + 4], _curves[e + 5]);
          break;
      }
    }
    _numCurves = 0;
    _end = 0;
  }
}
