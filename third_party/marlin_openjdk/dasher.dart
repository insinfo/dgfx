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
import 'marlin_const.dart';
import 'helpers.dart';
import 'path_consumer_2d.dart';
import 'context/renderer_context.dart';

class Dasher implements PathConsumer2D {
  static const int REC_LIMIT = 4;
  static const double ERR = 0.01;
  static const double MIN_TINCREMENT = 1.0 / (1 << REC_LIMIT);

  PathConsumer2D? _out;
  Float64List? _dash;
  int _dashLen = 0;
  double _startPhase = 0.0;
  bool _startDashOn = false;
  int _startIdx = 0;

  bool _starting = false;
  bool _needsMoveTo = false;

  int _idx = 0;
  bool _dashOn = false;
  double _phase = 0.0;

  double _sx = 0, _sy = 0;
  double _x0 = 0, _y0 = 0;

  final Float64List _curCurvepts = Float64List(8 * 2);

  Float64List _firstSegmentsBuffer;
  final Float64List _firstSegmentsBufferInitial;
  int _firstSegidx = 0;

  bool _recycleDashes = false;

  final LengthIterator _li = LengthIterator();

  Dasher(RendererContext rdrCtx)
      : _firstSegmentsBufferInitial = Float64List(MarlinConst.initialArray + 1),
        _firstSegmentsBuffer = Float64List(MarlinConst.initialArray + 1) {
    _firstSegmentsBuffer = _firstSegmentsBufferInitial;
  }

  Dasher init(PathConsumer2D out, Float64List dash, int dashLen, double phase,
      bool recycleDashes) {
    if (phase < 0.0) {
      throw ArgumentError("phase < 0 !");
    }
    _out = out;

    int idx = 0;
    _dashOn = true;
    double d;
    while (phase >= (d = dash[idx])) {
      phase -= d;
      idx = (idx + 1) % dashLen;
      _dashOn = !_dashOn;
    }

    _dash = dash;
    _dashLen = dashLen;
    _startPhase = _phase = phase;
    _startDashOn = _dashOn;
    _startIdx = idx;
    _starting = true;
    _needsMoveTo = false;
    _firstSegidx = 0;

    _recycleDashes = recycleDashes;

    return this;
  }

  void dispose() {
    _firstSegmentsBuffer.fillRange(0, _firstSegmentsBuffer.length, 0);
    _curCurvepts.fillRange(0, _curCurvepts.length, 0);

    if (_recycleDashes) {
      _dash = null;
    }

    if (_firstSegmentsBuffer != _firstSegmentsBufferInitial) {
      _firstSegmentsBuffer = _firstSegmentsBufferInitial;
    }
  }

  @override
  void moveTo(double x0, double y0) {
    if (_firstSegidx > 0) {
      _out!.moveTo(_sx, _sy);
      _emitFirstSegments();
    }
    _needsMoveTo = true;
    _idx = _startIdx;
    _dashOn = _startDashOn;
    _phase = _startPhase;
    _sx = _x0 = x0;
    _sy = _y0 = y0;
    _starting = true;
  }

  void _emitSeg(Float64List buf, int off, int type) {
    switch (type) {
      case 8:
        _out!.curveTo(buf[off], buf[off + 1], buf[off + 2], buf[off + 3],
            buf[off + 4], buf[off + 5]);
        break;
      case 6:
        _out!.quadTo(buf[off], buf[off + 1], buf[off + 2], buf[off + 3]);
        break;
      case 4:
        _out!.lineTo(buf[off], buf[off + 1]);
        break;
    }
  }

  void _emitFirstSegments() {
    final buf = _firstSegmentsBuffer;
    for (int i = 0; i < _firstSegidx;) {
      int type = buf[i].toInt();
      _emitSeg(buf, i + 1, type);
      i += (type - 1);
    }
    _firstSegidx = 0;
  }

  void _goTo(Float64List pts, int off, int type) {
    double x = pts[off + type - 4];
    double y = pts[off + type - 3];
    if (_dashOn) {
      if (_starting) {
        int len = type - 2 + 1;
        int segIdx = _firstSegidx;
        var buf = _firstSegmentsBuffer;
        if (segIdx + len > buf.length) {
          int newSize = buf.length * 2;
          if (newSize < segIdx + len) newSize = segIdx + len + 100;
          var newBuf = Float64List(newSize);
          newBuf.setRange(0, segIdx, buf);
          _firstSegmentsBuffer = buf = newBuf;
        }
        buf[segIdx++] = type.toDouble();
        len--;
        for (int k = 0; k < len; k++) buf[segIdx + k] = pts[off + k];
        segIdx += len;
        _firstSegidx = segIdx;
      } else {
        if (_needsMoveTo) {
          _out!.moveTo(_x0, _y0);
          _needsMoveTo = false;
        }
        _emitSeg(pts, off, type);
      }
    } else {
      _starting = false;
      _needsMoveTo = true;
    }
    _x0 = x;
    _y0 = y;
  }

  @override
  void lineTo(double x1, double y1) {
    double dx = x1 - _x0;
    double dy = y1 - _y0;
    double len = dx * dx + dy * dy;
    if (len == 0.0) return;
    len = math.sqrt(len);

    double cx = dx / len;
    double cy = dy / len;

    final dashArr = _dash!;
    final pts = _curCurvepts;

    while (true) {
      double leftInThisDashSegment = dashArr[_idx] - _phase;
      if (len <= leftInThisDashSegment) {
        pts[0] = x1;
        pts[1] = y1;
        _goTo(pts, 0, 4);
        _phase += len;
        if (len == leftInThisDashSegment) {
          _phase = 0.0;
          _idx = (_idx + 1) % _dashLen;
          _dashOn = !_dashOn;
        }
        return;
      }

      double dashdx = dashArr[_idx] * cx;
      double dashdy = dashArr[_idx] * cy;

      if (_phase == 0.0) {
        pts[0] = _x0 + dashdx;
        pts[1] = _y0 + dashdy;
      } else {
        double p = leftInThisDashSegment / dashArr[_idx];
        pts[0] = _x0 + p * dashdx;
        pts[1] = _y0 + p * dashdy;
      }

      _goTo(pts, 0, 4);
      len -= leftInThisDashSegment;
      _idx = (_idx + 1) % _dashLen;
      _dashOn = !_dashOn;
      _phase = 0.0;
    }
  }

  void _somethingTo(int type) {
    if (_pointCurve(_curCurvepts, type)) return;

    _li.initializeIterationOnCurve(_curCurvepts, type);
    int curCurveOff = 0;
    double lastSplitT = 0.0;
    double t;
    double leftInThisDashSegment = _dash![_idx] - _phase;

    while ((t = _li.next(leftInThisDashSegment)) < 1.0) {
      if (t != 0.0) {
        Helpers.subdivideAt((t - lastSplitT) / (1.0 - lastSplitT), _curCurvepts,
            curCurveOff, _curCurvepts, 0, _curCurvepts, type, type);
        lastSplitT = t;
        _goTo(_curCurvepts, 2, type);
        curCurveOff = type;
      }
      _idx = (_idx + 1) % _dashLen;
      _dashOn = !_dashOn;
      _phase = 0.0;
      leftInThisDashSegment = _dash![_idx];
    }
    _goTo(_curCurvepts, curCurveOff + 2, type);
    _phase += _li.lastSegLen;
    if (_phase >= _dash![_idx]) {
      _phase = 0.0;
      _idx = (_idx + 1) % _dashLen;
      _dashOn = !_dashOn;
    }
    _li.reset();
  }

  static bool _pointCurve(Float64List curve, int type) {
    for (int i = 2; i < type; i++) {
      if (curve[i] != curve[i - 2]) return false;
    }
    return true;
  }

  @override
  void curveTo(
      double x1, double y1, double x2, double y2, double x3, double y3) {
    final pts = _curCurvepts;
    pts[0] = _x0;
    pts[1] = _y0;
    pts[2] = x1;
    pts[3] = y1;
    pts[4] = x2;
    pts[5] = y2;
    pts[6] = x3;
    pts[7] = y3;
    _somethingTo(8);
  }

  @override
  void quadTo(double x1, double y1, double x2, double y2) {
    final pts = _curCurvepts;
    pts[0] = _x0;
    pts[1] = _y0;
    pts[2] = x1;
    pts[3] = y1;
    pts[4] = x2;
    pts[5] = y2;
    _somethingTo(6);
  }

  @override
  void closePath() {
    lineTo(_sx, _sy);
    if (_firstSegidx > 0) {
      if (!_dashOn || _needsMoveTo) {
        _out!.moveTo(_sx, _sy);
      }
      _emitFirstSegments();
    }
    moveTo(_sx, _sy);
  }

  @override
  void pathDone() {
    if (_firstSegidx > 0) {
      _out!.moveTo(_sx, _sy);
      _emitFirstSegments();
    }
    _out!.pathDone();
    dispose();
  }
}

enum Side { LEFT, RIGHT }

class LengthIterator {
  final List<Float64List> _recCurveStack;
  final List<Side> _sides;
  int _curveType = 0;
  double _nextT = 0.0;
  double _lenAtNextT = 0.0;
  double _lastT = 0.0;
  double _lenAtLastT = 0.0;
  double _lenAtLastSplit = 0.0;
  double lastSegLen = 0.0;
  int _recLevel = 0;
  bool _done = true;
  final Float64List _curLeafCtrlPolyLengths = Float64List(3);
  final Float64List _nextRoots = Float64List(4);
  final Float64List _flatLeafCoefCache =
      Float64List.fromList([0.0, 0.0, -1.0, 0.0]);
  int _cachedHaveLowAcceleration = -1;

  LengthIterator()
      : _recCurveStack = List.generate(4 + 1, (_) => Float64List(8)),
        _sides = List.filled(4, Side.LEFT);

  void reset() {
    // Keep dirty
  }

  void initializeIterationOnCurve(Float64List pts, int type) {
    for (int i = 0; i < 8; i++) _recCurveStack[0][i] = pts[i];
    _curveType = type;
    _recLevel = 0;
    _lastT = 0.0;
    _lenAtLastT = 0.0;
    _nextT = 0.0;
    _lenAtNextT = 0.0;
    _goLeft();
    _lenAtLastSplit = 0.0;
    if (_recLevel > 0) {
      _sides[0] = Side.LEFT;
      _done = false;
    } else {
      _sides[0] = Side.RIGHT;
      _done = true;
    }
    lastSegLen = 0.0;
  }

  bool _haveLowAcceleration(double err) {
    if (_cachedHaveLowAcceleration == -1) {
      double len1 = _curLeafCtrlPolyLengths[0];
      double len2 = _curLeafCtrlPolyLengths[1];
      if (!Helpers.within(len1, len2, err * len2)) {
        _cachedHaveLowAcceleration = 0;
        return false;
      }
      if (_curveType == 8) {
        double len3 = _curLeafCtrlPolyLengths[2];
        double errLen3 = err * len3;
        if (!(Helpers.within(len2, len3, errLen3) &&
            Helpers.within(len1, len3, errLen3))) {
          _cachedHaveLowAcceleration = 0;
          return false;
        }
      }
      _cachedHaveLowAcceleration = 1;
      return true;
    }
    return _cachedHaveLowAcceleration == 1;
  }

  void _goLeft() {
    double len = _onLeaf();
    if (len >= 0.0) {
      _lastT = _nextT;
      _lenAtLastT = _lenAtNextT;
      _nextT += (1 << (4 - _recLevel)) * Dasher.MIN_TINCREMENT;
      _lenAtNextT += len;
      _flatLeafCoefCache[2] = -1.0;
      _cachedHaveLowAcceleration = -1;
    } else {
      Helpers.subdivide(
          _recCurveStack[_recLevel],
          0,
          _recCurveStack[_recLevel + 1],
          0,
          _recCurveStack[_recLevel],
          0,
          _curveType);
      _sides[_recLevel] = Side.LEFT;
      _recLevel++;
      _goLeft();
    }
  }

  void _goToNextLeaf() {
    int lvl = _recLevel;
    lvl--;
    while (_sides[lvl] == Side.RIGHT) {
      if (lvl == 0) {
        _recLevel = 0;
        _done = true;
        return;
      }
      lvl--;
    }
    _sides[lvl] = Side.RIGHT;
    // copy 8
    for (int i = 0; i < 8; i++)
      _recCurveStack[lvl + 1][i] = _recCurveStack[lvl][i];
    lvl++;
    _recLevel = lvl;
    _goLeft();
  }

  double _onLeaf() {
    Float64List curve = _recCurveStack[_recLevel];
    double polyLen = 0.0;
    double x0 = curve[0], y0 = curve[1];

    for (int i = 2; i < _curveType; i += 2) {
      double x1 = curve[i], y1 = curve[i + 1];
      double len = Helpers.linelen(x0, y0, x1, y1);
      polyLen += len;
      _curLeafCtrlPolyLengths[i ~/ 2 - 1] = len;
      x0 = x1;
      y0 = y1;
    }

    double lineLen = Helpers.linelen(
        curve[0], curve[1], curve[_curveType - 2], curve[_curveType - 1]);
    if ((polyLen - lineLen) < Dasher.ERR || _recLevel == 4) {
      return (polyLen + lineLen) / 2.0;
    }
    return -1.0;
  }

  double next(double len) {
    double targetLength = _lenAtLastSplit + len;
    while (_lenAtNextT < targetLength) {
      if (_done) {
        lastSegLen = _lenAtNextT - _lenAtLastSplit;
        return 1.0;
      }
      _goToNextLeaf();
    }
    _lenAtLastSplit = targetLength;
    double leaflen = _lenAtNextT - _lenAtLastT;
    double t = (targetLength - _lenAtLastT) / leaflen;

    if (!_haveLowAcceleration(0.05)) {
      if (_flatLeafCoefCache[2] < 0.0) {
        double x = 0.0 + _curLeafCtrlPolyLengths[0];
        double y = x + _curLeafCtrlPolyLengths[1];
        if (_curveType == 8) {
          double z = y + _curLeafCtrlPolyLengths[2];
          _flatLeafCoefCache[0] = 3.0 * (x - y) + z;
          _flatLeafCoefCache[1] = 3.0 * (y - 2.0 * x);
          _flatLeafCoefCache[2] = 3.0 * x;
          _flatLeafCoefCache[3] = -z;
        } else if (_curveType == 6) {
          _flatLeafCoefCache[0] = 0.0;
          _flatLeafCoefCache[1] = y - 2.0 * x;
          _flatLeafCoefCache[2] = 2.0 * x;
          _flatLeafCoefCache[3] = -y;
        }
      }
      double a = _flatLeafCoefCache[0];
      double b = _flatLeafCoefCache[1];
      double c = _flatLeafCoefCache[2];
      double d = t * _flatLeafCoefCache[3];

      // Note: cubicRootsInAB signature updated in Helpers?
      // "Helpers.cubicRootsInAB(d, a, b, c, ...)" in Curve.dart calling Helpers.
      // Helpers signature: cubicRootsInAB(d, a, b, c, pts, off, A, B).
      // Here d corresponds to cubic term?
      // Java: cubicRootsInAB(a, b, c, d, ...).
      // In Java: "d*t^3 + a*t^2 + b*t + c = 0"? Or "a*t^3..."?
      // Helpers.dart: "d*t^3 + a*t^2 + b*t + c = 0".
      // Java Dasher: "a = _flatLeafCoefCache[0]". This is cubic term (from flattening logic).
      // Java passes (a, b, c, d).
      // So in Dart I should pass (a, b, c, d).
      // Wait. In Java Dasher: `Helpers.cubicRootsInAB(a, b, c, d, ...)`
      // In Dart Helpers: `cubicRootsInAB(d, a, b, c, ...)`?
      // Let's check Helpers.dart again.
      // "static int cubicRootsInAB(double d, double a, double b, double c, ...)"
      // "d*t^3 + a*t^2 + b*t + c = 0".
      // So 'd' is cubic coeff.
      // In Dasher Java: 'a' is cubic coeff.
      // So I should pass 'a' as first arg.
      int n = Helpers.cubicRootsInAB(a, b, c, d, _nextRoots, 0, 0.0, 1.0);
      if (n == 1 && !_nextRoots[0].isNaN) {
        t = _nextRoots[0];
      }
    }
    t = t * (_nextT - _lastT) + _lastT;
    if (t >= 1.0) {
      t = 1.0;
      _done = true;
    }
    lastSegLen = len;
    return t;
  }
}
