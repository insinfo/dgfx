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

import 'path_consumer_2d.dart';
import 'geom/path_2d.dart';

class TransformingPathConsumer2D {
  TransformingPathConsumer2D();

  final Path2DWrapper _wpPath2DWrapper = Path2DWrapper();

  PathConsumer2D wrapPath2d(Path2DFloat p2d) {
    return _wpPath2DWrapper.init(p2d);
  }

  final TranslateFilter _txTranslateFilter = TranslateFilter();
  final DeltaScaleFilter _txDeltaScaleFilter = DeltaScaleFilter();
  final ScaleFilter _txScaleFilter = ScaleFilter();
  final DeltaTransformFilter _txDeltaTransformFilter = DeltaTransformFilter();
  final TransformFilter _txTransformFilter = TransformFilter();

  PathConsumer2D transformConsumer(PathConsumer2D out, AffineTransform? at) {
    if (at == null) return out;

    double mxx = at.matrix[0];
    double myx = at.matrix[1];
    double mxy = at.matrix[2];
    double myy = at.matrix[3];
    double mxt = at.matrix[4];
    double myt = at.matrix[5];

    if (mxy == 0.0 && myx == 0.0) {
      if (mxx == 1.0 && myy == 1.0) {
        if (mxt == 0.0 && myt == 0.0) {
          return out;
        } else {
          return _txTranslateFilter.init(out, mxt, myt);
        }
      } else {
        if (mxt == 0.0 && myt == 0.0) {
          return _txDeltaScaleFilter.init(out, mxx, myy);
        } else {
          return _txScaleFilter.init(out, mxx, myy, mxt, myt);
        }
      }
    } else if (mxt == 0.0 && myt == 0.0) {
      return _txDeltaTransformFilter.init(out, mxx, mxy, myx, myy);
    } else {
      return _txTransformFilter.init(out, mxx, mxy, mxt, myx, myy, myt);
    }
  }
}

class TranslateFilter implements PathConsumer2D {
  PathConsumer2D? _out;
  double _tx = 0, _ty = 0;

  TranslateFilter init(PathConsumer2D out, double tx, double ty) {
    _out = out;
    _tx = tx;
    _ty = ty;
    return this;
  }

  @override
  void moveTo(double x0, double y0) => _out!.moveTo(x0 + _tx, y0 + _ty);

  @override
  void lineTo(double x1, double y1) => _out!.lineTo(x1 + _tx, y1 + _ty);

  @override
  void quadTo(double x1, double y1, double x2, double y2) {
    _out!.quadTo(x1 + _tx, y1 + _ty, x2 + _tx, y2 + _ty);
  }

  @override
  void curveTo(
      double x1, double y1, double x2, double y2, double x3, double y3) {
    _out!.curveTo(x1 + _tx, y1 + _ty, x2 + _tx, y2 + _ty, x3 + _tx, y3 + _ty);
  }

  @override
  void closePath() => _out!.closePath();

  @override
  void pathDone() => _out!.pathDone();
}

class ScaleFilter implements PathConsumer2D {
  PathConsumer2D? _out;
  double _sx = 0, _sy = 0, _tx = 0, _ty = 0;

  ScaleFilter init(
      PathConsumer2D out, double sx, double sy, double tx, double ty) {
    _out = out;
    _sx = sx;
    _sy = sy;
    _tx = tx;
    _ty = ty;
    return this;
  }

  @override
  void moveTo(double x0, double y0) =>
      _out!.moveTo(x0 * _sx + _tx, y0 * _sy + _ty);

  @override
  void lineTo(double x1, double y1) =>
      _out!.lineTo(x1 * _sx + _tx, y1 * _sy + _ty);

  @override
  void quadTo(double x1, double y1, double x2, double y2) {
    _out!
        .quadTo(x1 * _sx + _tx, y1 * _sy + _ty, x2 * _sx + _tx, y2 * _sy + _ty);
  }

  @override
  void curveTo(
      double x1, double y1, double x2, double y2, double x3, double y3) {
    _out!.curveTo(x1 * _sx + _tx, y1 * _sy + _ty, x2 * _sx + _tx,
        y2 * _sy + _ty, x3 * _sx + _tx, y3 * _sy + _ty);
  }

  @override
  void closePath() => _out!.closePath();

  @override
  void pathDone() => _out!.pathDone();
}

class TransformFilter implements PathConsumer2D {
  PathConsumer2D? _out;
  double _mxx = 0, _mxy = 0, _mxt = 0, _myx = 0, _myy = 0, _myt = 0;

  TransformFilter init(PathConsumer2D out, double mxx, double mxy, double mxt,
      double myx, double myy, double myt) {
    _out = out;
    _mxx = mxx;
    _mxy = mxy;
    _mxt = mxt;
    _myx = myx;
    _myy = myy;
    _myt = myt;
    return this;
  }

  @override
  void moveTo(double x0, double y0) {
    _out!.moveTo(x0 * _mxx + y0 * _mxy + _mxt, x0 * _myx + y0 * _myy + _myt);
  }

  @override
  void lineTo(double x1, double y1) {
    _out!.lineTo(x1 * _mxx + y1 * _mxy + _mxt, x1 * _myx + y1 * _myy + _myt);
  }

  @override
  void quadTo(double x1, double y1, double x2, double y2) {
    _out!.quadTo(x1 * _mxx + y1 * _mxy + _mxt, x1 * _myx + y1 * _myy + _myt,
        x2 * _mxx + y2 * _mxy + _mxt, x2 * _myx + y2 * _myy + _myt);
  }

  @override
  void curveTo(
      double x1, double y1, double x2, double y2, double x3, double y3) {
    _out!.curveTo(
        x1 * _mxx + y1 * _mxy + _mxt,
        x1 * _myx + y1 * _myy + _myt,
        x2 * _mxx + y2 * _mxy + _mxt,
        x2 * _myx + y2 * _myy + _myt,
        x3 * _mxx + y3 * _mxy + _mxt,
        x3 * _myx + y3 * _myy + _myt);
  }

  @override
  void closePath() => _out!.closePath();

  @override
  void pathDone() => _out!.pathDone();
}

class DeltaScaleFilter implements PathConsumer2D {
  PathConsumer2D? _out;
  double _sx = 0, _sy = 0;

  DeltaScaleFilter init(PathConsumer2D out, double mxx, double myy) {
    _out = out;
    _sx = mxx;
    _sy = myy;
    return this;
  }

  @override
  void moveTo(double x0, double y0) => _out!.moveTo(x0 * _sx, y0 * _sy);

  @override
  void lineTo(double x1, double y1) => _out!.lineTo(x1 * _sx, y1 * _sy);

  @override
  void quadTo(double x1, double y1, double x2, double y2) {
    _out!.quadTo(x1 * _sx, y1 * _sy, x2 * _sx, y2 * _sy);
  }

  @override
  void curveTo(
      double x1, double y1, double x2, double y2, double x3, double y3) {
    _out!.curveTo(x1 * _sx, y1 * _sy, x2 * _sx, y2 * _sy, x3 * _sx, y3 * _sy);
  }

  @override
  void closePath() => _out!.closePath();

  @override
  void pathDone() => _out!.pathDone();
}

class DeltaTransformFilter implements PathConsumer2D {
  PathConsumer2D? _out;
  double _mxx = 0, _mxy = 0, _myx = 0, _myy = 0;

  DeltaTransformFilter init(
      PathConsumer2D out, double mxx, double mxy, double myx, double myy) {
    _out = out;
    _mxx = mxx;
    _mxy = mxy;
    _myx = myx;
    _myy = myy;
    return this;
  }

  @override
  void moveTo(double x0, double y0) {
    _out!.moveTo(x0 * _mxx + y0 * _mxy, x0 * _myx + y0 * _myy);
  }

  @override
  void lineTo(double x1, double y1) {
    _out!.lineTo(x1 * _mxx + y1 * _mxy, x1 * _myx + y1 * _myy);
  }

  @override
  void quadTo(double x1, double y1, double x2, double y2) {
    _out!.quadTo(x1 * _mxx + y1 * _mxy, x1 * _myx + y1 * _myy,
        x2 * _mxx + y2 * _mxy, x2 * _myx + y2 * _myy);
  }

  @override
  void curveTo(
      double x1, double y1, double x2, double y2, double x3, double y3) {
    _out!.curveTo(
        x1 * _mxx + y1 * _mxy,
        x1 * _myx + y1 * _myy,
        x2 * _mxx + y2 * _mxy,
        x2 * _myx + y2 * _myy,
        x3 * _mxx + y3 * _mxy,
        x3 * _myx + y3 * _myy);
  }

  @override
  void closePath() => _out!.closePath();

  @override
  void pathDone() => _out!.pathDone();
}

class Path2DWrapper implements PathConsumer2D {
  Path2DFloat? _p2d;

  Path2DWrapper init(Path2DFloat p2d) {
    _p2d = p2d;
    return this;
  }

  @override
  void moveTo(double x0, double y0) => _p2d!.moveTo(x0, y0);

  @override
  void lineTo(double x1, double y1) => _p2d!.lineTo(x1, y1);

  @override
  void closePath() => _p2d!.closePath();

  @override
  void pathDone() {}

  @override
  void curveTo(
      double x1, double y1, double x2, double y2, double x3, double y3) {
    _p2d!.curveTo(x1, y1, x2, y2, x3, y3);
  }

  @override
  void quadTo(double x1, double y1, double x2, double y2) {
    _p2d!.quadTo(x1, y1, x2, y2);
  }
}
