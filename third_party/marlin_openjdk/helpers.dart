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

/// Helper class with static utility functions
class Helpers {
  Helpers._();

  /// Check if two values are within error margin
  static bool within(double x, double y, double err) {
    final double d = y - x;
    return d <= err && d >= -err;
  }

  /// Find roots of quadratic equation: a*t^2 + b*t + c = 0
  /// Returns number of roots found
  static int quadraticRoots(
    double a,
    double b,
    double c,
    List<double> zeroes,
    int off,
  ) {
    int ret = off;
    double t;

    if (a != 0.0) {
      final double dis = b * b - 4 * a * c;
      if (dis > 0.0) {
        final double sqrtDis = math.sqrt(dis);
        if (b >= 0.0) {
          zeroes[ret++] = (2.0 * c) / (-b - sqrtDis);
          zeroes[ret++] = (-b - sqrtDis) / (2.0 * a);
        } else {
          zeroes[ret++] = (-b + sqrtDis) / (2.0 * a);
          zeroes[ret++] = (2.0 * c) / (-b + sqrtDis);
        }
      } else if (dis == 0.0) {
        t = (-b) / (2.0 * a);
        zeroes[ret++] = t;
      }
    } else {
      if (b != 0.0) {
        t = (-c) / b;
        zeroes[ret++] = t;
      }
    }
    return ret - off;
  }

  /// Find roots of cubic equation in interval [A, B)
  /// d*t^3 + a*t^2 + b*t + c = 0
  static int cubicRootsInAB(
    double d,
    double a,
    double b,
    double c,
    List<double> pts,
    int off,
    double A,
    double B,
  ) {
    if (d == 0.0) {
      int num = quadraticRoots(a, b, c, pts, off);
      return filterOutNotInAB(pts, off, num, A, B) - off;
    }

    // Normal form: x^3 + ax^2 + bx + c = 0
    a /= d;
    b /= d;
    c /= d;

    // Substitute x = y - A/3 to eliminate quadratic term
    double sqA = a * a;
    double p = (1.0 / 3.0) * ((-1.0 / 3.0) * sqA + b);
    double q = (1.0 / 2.0) * ((2.0 / 27.0) * a * sqA - (1.0 / 3.0) * a * b + c);

    // Use Cardano's formula
    double cbP = p * p * p;
    double D = q * q + cbP;

    int num;
    if (D < 0.0) {
      final double phi = (1.0 / 3.0) * math.acos(-q / math.sqrt(-cbP));
      final double t = 2.0 * math.sqrt(-p);

      pts[off + 0] = t * math.cos(phi);
      pts[off + 1] = -t * math.cos(phi + (math.pi / 3.0));
      pts[off + 2] = -t * math.cos(phi - (math.pi / 3.0));
      num = 3;
    } else {
      final double sqrtD = math.sqrt(D);
      final double u = _cbrt(sqrtD - q);
      final double v = -_cbrt(sqrtD + q);

      pts[off] = u + v;
      num = 1;

      if (within(D, 0.0, 1e-8)) {
        pts[off + 1] = -(pts[off] / 2.0);
        num = 2;
      }
    }

    final double sub = (1.0 / 3.0) * a;
    for (int i = 0; i < num; ++i) {
      pts[off + i] -= sub;
    }

    return filterOutNotInAB(pts, off, num, A, B) - off;
  }

  /// Cube root
  static double _cbrt(double x) {
    if (x >= 0) {
      return math.pow(x, 1.0 / 3.0).toDouble();
    } else {
      return -math.pow(-x, 1.0 / 3.0).toDouble();
    }
  }

  /// Evaluate cubic at t: a*t^3 + b*t^2 + c*t + d
  static double evalCubic(double a, double b, double c, double d, double t) {
    return t * (t * (t * a + b) + c) + d;
  }

  /// Evaluate quadratic at t: a*t^2 + b*t + c
  static double evalQuad(double a, double b, double c, double t) {
    return t * (t * a + b) + c;
  }

  /// Filter out values not in [a, b)
  static int filterOutNotInAB(
    List<double> nums,
    int off,
    int len,
    double a,
    double b,
  ) {
    int ret = off;
    for (int i = off, end = off + len; i < end; i++) {
      if (nums[i] >= a && nums[i] < b) {
        nums[ret++] = nums[i];
      }
    }
    return ret;
  }

  /// Calculate length of line segment
  static double linelen(double x1, double y1, double x2, double y2) {
    final double dx = x2 - x1;
    final double dy = y2 - y1;
    return math.sqrt(dx * dx + dy * dy);
  }

  /// Subdivide curve (6 for quad, 8 for cubic)
  static void subdivide(
    List<double> src,
    int srcoff,
    List<double>? left,
    int leftoff,
    List<double>? right,
    int rightoff,
    int type,
  ) {
    switch (type) {
      case 6:
        subdivideQuad(src, srcoff, left, leftoff, right, rightoff);
        break;
      case 8:
        subdivideCubic(src, srcoff, left, leftoff, right, rightoff);
        break;
      default:
        throw ArgumentError('Unsupported curve type: $type');
    }
  }

  /// Subdivide cubic curve at midpoint
  static void subdivideCubic(
    List<double> src,
    int srcoff,
    List<double>? left,
    int leftoff,
    List<double>? right,
    int rightoff,
  ) {
    double x1 = src[srcoff + 0];
    double y1 = src[srcoff + 1];
    double ctrlx1 = src[srcoff + 2];
    double ctrly1 = src[srcoff + 3];
    double ctrlx2 = src[srcoff + 4];
    double ctrly2 = src[srcoff + 5];
    double x2 = src[srcoff + 6];
    double y2 = src[srcoff + 7];

    if (left != null) {
      left[leftoff + 0] = x1;
      left[leftoff + 1] = y1;
    }
    if (right != null) {
      right[rightoff + 6] = x2;
      right[rightoff + 7] = y2;
    }

    x1 = (x1 + ctrlx1) / 2.0;
    y1 = (y1 + ctrly1) / 2.0;
    x2 = (x2 + ctrlx2) / 2.0;
    y2 = (y2 + ctrly2) / 2.0;
    double centerx = (ctrlx1 + ctrlx2) / 2.0;
    double centery = (ctrly1 + ctrly2) / 2.0;
    ctrlx1 = (x1 + centerx) / 2.0;
    ctrly1 = (y1 + centery) / 2.0;
    ctrlx2 = (x2 + centerx) / 2.0;
    ctrly2 = (y2 + centery) / 2.0;
    centerx = (ctrlx1 + ctrlx2) / 2.0;
    centery = (ctrly1 + ctrly2) / 2.0;

    if (left != null) {
      left[leftoff + 2] = x1;
      left[leftoff + 3] = y1;
      left[leftoff + 4] = ctrlx1;
      left[leftoff + 5] = ctrly1;
      left[leftoff + 6] = centerx;
      left[leftoff + 7] = centery;
    }
    if (right != null) {
      right[rightoff + 0] = centerx;
      right[rightoff + 1] = centery;
      right[rightoff + 2] = ctrlx2;
      right[rightoff + 3] = ctrly2;
      right[rightoff + 4] = x2;
      right[rightoff + 5] = y2;
    }
  }

  /// Subdivide cubic curve at parameter t
  static void subdivideCubicAt(
    double t,
    List<double> src,
    int srcoff,
    List<double>? left,
    int leftoff,
    List<double>? right,
    int rightoff,
  ) {
    double x1 = src[srcoff + 0];
    double y1 = src[srcoff + 1];
    double ctrlx1 = src[srcoff + 2];
    double ctrly1 = src[srcoff + 3];
    double ctrlx2 = src[srcoff + 4];
    double ctrly2 = src[srcoff + 5];
    double x2 = src[srcoff + 6];
    double y2 = src[srcoff + 7];

    if (left != null) {
      left[leftoff + 0] = x1;
      left[leftoff + 1] = y1;
    }
    if (right != null) {
      right[rightoff + 6] = x2;
      right[rightoff + 7] = y2;
    }

    x1 = x1 + t * (ctrlx1 - x1);
    y1 = y1 + t * (ctrly1 - y1);
    x2 = ctrlx2 + t * (x2 - ctrlx2);
    y2 = ctrly2 + t * (y2 - ctrly2);
    double centerx = ctrlx1 + t * (ctrlx2 - ctrlx1);
    double centery = ctrly1 + t * (ctrly2 - ctrly1);
    ctrlx1 = x1 + t * (centerx - x1);
    ctrly1 = y1 + t * (centery - y1);
    ctrlx2 = centerx + t * (x2 - centerx);
    ctrly2 = centery + t * (y2 - centery);
    centerx = ctrlx1 + t * (ctrlx2 - ctrlx1);
    centery = ctrly1 + t * (ctrly2 - ctrly1);

    if (left != null) {
      left[leftoff + 2] = x1;
      left[leftoff + 3] = y1;
      left[leftoff + 4] = ctrlx1;
      left[leftoff + 5] = ctrly1;
      left[leftoff + 6] = centerx;
      left[leftoff + 7] = centery;
    }
    if (right != null) {
      right[rightoff + 0] = centerx;
      right[rightoff + 1] = centery;
      right[rightoff + 2] = ctrlx2;
      right[rightoff + 3] = ctrly2;
      right[rightoff + 4] = x2;
      right[rightoff + 5] = y2;
    }
  }

  /// Subdivide quadratic curve at midpoint
  static void subdivideQuad(
    List<double> src,
    int srcoff,
    List<double>? left,
    int leftoff,
    List<double>? right,
    int rightoff,
  ) {
    double x1 = src[srcoff + 0];
    double y1 = src[srcoff + 1];
    double ctrlx = src[srcoff + 2];
    double ctrly = src[srcoff + 3];
    double x2 = src[srcoff + 4];
    double y2 = src[srcoff + 5];

    if (left != null) {
      left[leftoff + 0] = x1;
      left[leftoff + 1] = y1;
    }
    if (right != null) {
      right[rightoff + 4] = x2;
      right[rightoff + 5] = y2;
    }

    x1 = (x1 + ctrlx) / 2.0;
    y1 = (y1 + ctrly) / 2.0;
    x2 = (x2 + ctrlx) / 2.0;
    y2 = (y2 + ctrly) / 2.0;
    ctrlx = (x1 + x2) / 2.0;
    ctrly = (y1 + y2) / 2.0;

    if (left != null) {
      left[leftoff + 2] = x1;
      left[leftoff + 3] = y1;
      left[leftoff + 4] = ctrlx;
      left[leftoff + 5] = ctrly;
    }
    if (right != null) {
      right[rightoff + 0] = ctrlx;
      right[rightoff + 1] = ctrly;
      right[rightoff + 2] = x2;
      right[rightoff + 3] = y2;
    }
  }

  /// Subdivide quadratic curve at parameter t
  static void subdivideQuadAt(
    double t,
    List<double> src,
    int srcoff,
    List<double>? left,
    int leftoff,
    List<double>? right,
    int rightoff,
  ) {
    double x1 = src[srcoff + 0];
    double y1 = src[srcoff + 1];
    double ctrlx = src[srcoff + 2];
    double ctrly = src[srcoff + 3];
    double x2 = src[srcoff + 4];
    double y2 = src[srcoff + 5];

    if (left != null) {
      left[leftoff + 0] = x1;
      left[leftoff + 1] = y1;
    }
    if (right != null) {
      right[rightoff + 4] = x2;
      right[rightoff + 5] = y2;
    }

    x1 = x1 + t * (ctrlx - x1);
    y1 = y1 + t * (ctrly - y1);
    x2 = ctrlx + t * (x2 - ctrlx);
    y2 = ctrly + t * (y2 - ctrly);
    ctrlx = x1 + t * (x2 - x1);
    ctrly = y1 + t * (y2 - y1);

    if (left != null) {
      left[leftoff + 2] = x1;
      left[leftoff + 3] = y1;
      left[leftoff + 4] = ctrlx;
      left[leftoff + 5] = ctrly;
    }
    if (right != null) {
      right[rightoff + 0] = ctrlx;
      right[rightoff + 1] = ctrly;
      right[rightoff + 2] = x2;
      right[rightoff + 3] = y2;
    }
  }

  /// Subdivide at parameter t
  static void subdivideAt(
    double t,
    List<double> src,
    int srcoff,
    List<double>? left,
    int leftoff,
    List<double>? right,
    int rightoff,
    int size,
  ) {
    switch (size) {
      case 8:
        subdivideCubicAt(t, src, srcoff, left, leftoff, right, rightoff);
        break;
      case 6:
        subdivideQuadAt(t, src, srcoff, left, leftoff, right, rightoff);
        break;
    }
  }

  /// Insertion sort for small arrays
  static void isort(List<double> a, int off, int len) {
    for (int i = off + 1, end = off + len; i < end; i++) {
      double ai = a[i];
      int j = i - 1;
      for (; j >= off && a[j] > ai; j--) {
        a[j + 1] = a[j];
      }
      a[j + 1] = ai;
    }
  }
}
