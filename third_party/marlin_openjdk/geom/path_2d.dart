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

import 'dart:typed_data';
import 'dart:math' as math;

// Constants and Segment Types
const int WIND_EVEN_ODD = 0;
const int WIND_NON_ZERO = 1;
const int SEG_MOVETO = 0;
const int SEG_LINETO = 1;
const int SEG_QUADTO = 2;
const int SEG_CUBICTO = 3;
const int SEG_CLOSE = 4;

// Supporting Geometry Classes

class Point2D {
  final double x;
  final double y;
  Point2D(this.x, this.y);
  double getX() => x;
  double getY() => y;
}

class Rectangle2D {
  double x, y, width, height;
  Rectangle2D(this.x, this.y, this.width, this.height);
  Rectangle2D.empty() : this(0, 0, 0, 0);

  double getX() => x;
  double getY() => y;
  double getWidth() => width;
  double getHeight() => height;

  Rectangle getBounds() =>
      Rectangle(x.toInt(), y.toInt(), width.toInt(), height.toInt());
}

class Rectangle {
  int x, y, width, height;
  Rectangle(this.x, this.y, this.width, this.height);
}

class AffineTransform {
  final List<double> matrix;

  AffineTransform() : matrix = [1, 0, 0, 1, 0, 0]; // identity

  void transform(
      List<double> src, int srcOff, List<double> dst, int dstOff, int numPts) {
    for (int i = 0; i < numPts; i++) {
      double x = src[srcOff + i * 2];
      double y = src[srcOff + i * 2 + 1];
      dst[dstOff + i * 2] = matrix[0] * x + matrix[2] * y + matrix[4];
      dst[dstOff + i * 2 + 1] = matrix[1] * x + matrix[3] * y + matrix[5];
    }
  }

  void transformFloat(
      Float32List src, int srcOff, Float32List dst, int dstOff, int numPts) {
    for (int i = 0; i < numPts; i++) {
      double x = src[srcOff + i * 2];
      double y = src[srcOff + i * 2 + 1];
      dst[dstOff + i * 2] =
          (matrix[0] * x + matrix[2] * y + matrix[4]).toDouble();
      dst[dstOff + i * 2 + 1] =
          (matrix[1] * x + matrix[3] * y + matrix[5]).toDouble();
    }
  }
}

abstract class Shape {
  Rectangle getBounds();
  Rectangle2D getBounds2D();
  bool contains(double x, double y);
  bool containsPoint(Point2D p);
  bool containsRect(double x, double y, double w, double h);
  bool containsRectangle2D(Rectangle2D r);
  bool intersects(double x, double y, double w, double h);
  bool intersectsRectangle2D(Rectangle2D r);
  PathIterator getPathIterator(AffineTransform? at);
  PathIterator getPathIteratorWithFlatness(
      AffineTransform? at, double flatness);
}

abstract class PathIterator {
  static const int WIND_EVEN_ODD = 0;
  static const int WIND_NON_ZERO = 1;

  int getWindingRule();
  bool isDone();
  void next();
  int currentSegment(List<double> coords);
}

class IllegalPathStateException implements Exception {
  final String message;
  IllegalPathStateException(this.message);
  @override
  String toString() => "IllegalPathStateException: $message";
}

// ============================================================================
// Curve Utility Class (Crossing Calculations)
// ============================================================================

class Curve {
  static const int RECT_INTERSECTS = 0x80000000;

  static int pointCrossingsForLine(
      double px, double py, double x1, double y1, double x2, double y2) {
    if ((y1 < py && y2 <= py) ||
        (y1 > py && y2 >= py) ||
        (x1 <= px && x2 <= px)) {
      return 0;
    }
    if (y1 == y2) return 0;

    double x = x1 + (py - y1) * (x2 - x1) / (y2 - y1);
    if (x > px) {
      return (y1 < y2) ? 1 : -1;
    }
    return 0;
  }

  static int pointCrossingsForQuad(double px, double py, double x1, double y1,
      double cx, double cy, double x2, double y2, int level) {
    if ((y1 < py && cy < py && y2 < py) || (y1 > py && cy > py && y2 > py)) {
      return 0;
    }
    if (x1 <= px && cx <= px && x2 <= px) return 0;

    if (level > 0) {
      double cx1 = (x1 + cx) / 2;
      double cy1 = (y1 + cy) / 2;
      double cx2 = (cx + x2) / 2;
      double cy2 = (cy + y2) / 2;
      double cx3 = (cx1 + cx2) / 2;
      double cy3 = (cy1 + cy2) / 2;

      int c =
          pointCrossingsForQuad(px, py, x1, y1, cx1, cy1, cx3, cy3, level - 1);
      if (c != 0) return c;
      return pointCrossingsForQuad(
          px, py, cx3, cy3, cx2, cy2, x2, y2, level - 1);
    }

    double x = x1 + (py - y1) * (x2 - x1) / (y2 - y1);
    if (x > px) return (y1 < y2) ? 1 : -1;
    return 0;
  }

  static int pointCrossingsForCubic(
      double px,
      double py,
      double x1,
      double y1,
      double cx1,
      double cy1,
      double cx2,
      double cy2,
      double x2,
      double y2,
      int level) {
    if ((y1 < py && cy1 < py && cy2 < py && y2 < py) ||
        (y1 > py && cy1 > py && cy2 > py && y2 > py)) {
      return 0;
    }
    if (x1 <= px && cx1 <= px && cx2 <= px && x2 <= px) return 0;

    if (level > 0) {
      double cx1a = (x1 + cx1) / 2;
      double cy1a = (y1 + cy1) / 2;
      double cx2a = (cx1 + cx2) / 2;
      double cy2a = (cy1 + cy2) / 2;
      double cx3a = (cx2 + x2) / 2;
      double cy3a = (cy2 + y2) / 2;
      double cx1b = (cx1a + cx2a) / 2;
      double cy1b = (cy1a + cy2a) / 2;
      double cx2b = (cx2a + cx3a) / 2;
      double cy2b = (cy2a + cy3a) / 2;
      double cx1c = (cx1b + cx2b) / 2;
      double cy1c = (cy1b + cy2b) / 2;

      int c = pointCrossingsForCubic(
          px, py, x1, y1, cx1a, cy1a, cx1b, cy1b, cx1c, cy1c, level - 1);
      if (c != 0) return c;
      return pointCrossingsForCubic(
          px, py, cx1c, cy1c, cx2b, cy2b, cx3a, cy3a, x2, y2, level - 1);
    }

    double x = x1 + (py - y1) * (x2 - x1) / (y2 - y1);
    if (x > px) return (y1 < y2) ? 1 : -1;
    return 0;
  }

  static int rectCrossingsForLine(int crossings, double rxmin, double rymin,
      double rxmax, double rymax, double x1, double y1, double x2, double y2) {
    if (y1 >= rymax && y2 >= rymax) return crossings;
    if (y1 <= rymin && y2 <= rymin) return crossings;
    if (x1 <= rxmin && x2 <= rxmin) return crossings;

    if (x1 >= rxmax && x2 >= rxmax) {
      if (y1 < y2) {
        if (y1 <= rymin) crossings++;
        if (y2 >= rymax) crossings++;
      } else {
        if (y2 <= rymin) crossings--;
        if (y1 >= rymax) crossings--;
      }
    } else {
      return RECT_INTERSECTS;
    }
    return crossings;
  }

  static int rectCrossingsForQuad(
      int crossings,
      double rxmin,
      double rymin,
      double rxmax,
      double rymax,
      double x1,
      double y1,
      double cx,
      double cy,
      double x2,
      double y2,
      int level) {
    if (level > 0) {
      if ((y1 >= rymax && cy >= rymax && y2 >= rymax) ||
          (y1 <= rymin && cy <= rymin && y2 <= rymin) ||
          (x1 <= rxmin && cx <= rxmin && x2 <= rxmin) ||
          (x1 >= rxmax && cx >= rxmax && x2 >= rxmax)) {
        return crossings;
      }

      double cx1 = (x1 + cx) / 2;
      double cy1 = (y1 + cy) / 2;
      double cx2 = (cx + x2) / 2;
      double cy2 = (cy + y2) / 2;
      double cx3 = (cx1 + cx2) / 2;
      double cy3 = (cy1 + cy2) / 2;

      crossings = rectCrossingsForQuad(crossings, rxmin, rymin, rxmax, rymax,
          x1, y1, cx1, cy1, cx3, cy3, level - 1);
      if (crossings == RECT_INTERSECTS) return crossings;
      return rectCrossingsForQuad(crossings, rxmin, rymin, rxmax, rymax, cx3,
          cy3, cx2, cy2, x2, y2, level - 1);
    }

    return rectCrossingsForLine(
        crossings, rxmin, rymin, rxmax, rymax, x1, y1, x2, y2);
  }

  static int rectCrossingsForCubic(
      int crossings,
      double rxmin,
      double rymin,
      double rxmax,
      double rymax,
      double x1,
      double y1,
      double cx1,
      double cy1,
      double cx2,
      double cy2,
      double x2,
      double y2,
      int level) {
    if (level > 0) {
      if ((y1 >= rymax && cy1 >= rymax && cy2 >= rymax && y2 >= rymax) ||
          (y1 <= rymin && cy1 <= rymin && cy2 <= rymin && y2 <= rymin) ||
          (x1 <= rxmin && cx1 <= rxmin && cx2 <= rxmin && x2 <= rxmin) ||
          (x1 >= rxmax && cx1 >= rxmax && cx2 >= rxmax && x2 >= rxmax)) {
        return crossings;
      }

      double cx1a = (x1 + cx1) / 2;
      double cy1a = (y1 + cy1) / 2;
      double cx2a = (cx1 + cx2) / 2;
      double cy2a = (cy1 + cy2) / 2;
      double cx3a = (cx2 + x2) / 2;
      double cy3a = (cy2 + y2) / 2;
      double cx1b = (cx1a + cx2a) / 2;
      double cy1b = (cy1a + cy2a) / 2;
      double cx2b = (cx2a + cx3a) / 2;
      double cy2b = (cy2a + cy3a) / 2;
      double cx1c = (cx1b + cx2b) / 2;
      double cy1c = (cy1b + cy2b) / 2;

      crossings = rectCrossingsForCubic(crossings, rxmin, rymin, rxmax, rymax,
          x1, y1, cx1a, cy1a, cx1b, cy1b, cx1c, cy1c, level - 1);
      if (crossings == RECT_INTERSECTS) return crossings;
      return rectCrossingsForCubic(crossings, rxmin, rymin, rxmax, rymax, cx1c,
          cy1c, cx2b, cy2b, cx3a, cy3a, x2, y2, level - 1);
    }

    return rectCrossingsForLine(
        crossings, rxmin, rymin, rxmax, rymax, x1, y1, x2, y2);
  }

  static int rectCrossingsForPath(
      PathIterator pi, double x, double y, double w, double h) {
    if (w <= 0 || h <= 0) return 0;

    double rxmin = x;
    double rymin = y;
    double rxmax = x + w;
    double rymax = y + h;

    List<double> coords = List<double>.filled(6, 0);
    double movx = 0, movy = 0;
    double curx = 0, cury = 0;
    int crossings = 0;

    pi = FlatteningPathIterator(pi, 0.001);

    while (!pi.isDone()) {
      int type = pi.currentSegment(coords);
      switch (type) {
        case SEG_MOVETO:
          if (curx != movx || cury != movy) {
            crossings = rectCrossingsForLine(
                crossings, rxmin, rymin, rxmax, rymax, curx, cury, movx, movy);
          }
          curx = movx = coords[0];
          cury = movy = coords[1];
          break;
        case SEG_LINETO:
          crossings = rectCrossingsForLine(crossings, rxmin, rymin, rxmax,
              rymax, curx, cury, coords[0], coords[1]);
          curx = coords[0];
          cury = coords[1];
          break;
        case SEG_CLOSE:
          if (curx != movx || cury != movy) {
            crossings = rectCrossingsForLine(
                crossings, rxmin, rymin, rxmax, rymax, curx, cury, movx, movy);
          }
          curx = movx;
          cury = movy;
          break;
      }
      if (crossings == RECT_INTERSECTS) return crossings;
      pi.next();
    }

    if (curx != movx || cury != movy) {
      crossings = rectCrossingsForLine(
          crossings, rxmin, rymin, rxmax, rymax, curx, cury, movx, movy);
    }

    return crossings;
  }

  static int pointCrossingsForPath(PathIterator pi, double x, double y) {
    List<double> coords = List<double>.filled(6, 0);
    double movx = 0, movy = 0;
    double curx = 0, cury = 0;
    int crossings = 0;

    while (!pi.isDone()) {
      int type = pi.currentSegment(coords);
      switch (type) {
        case SEG_MOVETO:
          if (cury != movy) {
            crossings += pointCrossingsForLine(x, y, curx, cury, movx, movy);
          }
          curx = movx = coords[0];
          cury = movy = coords[1];
          break;
        case SEG_LINETO:
          crossings +=
              pointCrossingsForLine(x, y, curx, cury, coords[0], coords[1]);
          curx = coords[0];
          cury = coords[1];
          break;
        case SEG_QUADTO:
          crossings += pointCrossingsForQuad(
              x, y, curx, cury, coords[0], coords[1], coords[2], coords[3], 0);
          curx = coords[2];
          cury = coords[3];
          break;
        case SEG_CUBICTO:
          crossings += pointCrossingsForCubic(x, y, curx, cury, coords[0],
              coords[1], coords[2], coords[3], coords[4], coords[5], 0);
          curx = coords[4];
          cury = coords[5];
          break;
        case SEG_CLOSE:
          if (cury != movy) {
            crossings += pointCrossingsForLine(x, y, curx, cury, movx, movy);
          }
          curx = movx;
          cury = movy;
          break;
      }
      pi.next();
    }

    if (cury != movy) {
      crossings += pointCrossingsForLine(x, y, curx, cury, movx, movy);
    }

    return crossings;
  }
}

// ============================================================================
// FlatteningPathIterator (Simplified)
// ============================================================================

class FlatteningPathIterator implements PathIterator {
  final PathIterator src;
  final double flatness;

  FlatteningPathIterator(this.src, this.flatness);

  @override
  int getWindingRule() => src.getWindingRule();

  @override
  bool isDone() => src.isDone();

  @override
  void next() => src.next();

  @override
  int currentSegment(List<double> coords) => src.currentSegment(coords);
}

// ============================================================================
// Path2D Abstract Base Class
// ============================================================================

abstract class Path2D implements Shape {
  static const int INIT_SIZE = 20;
  static const int EXPAND_MAX = 500;
  static const int EXPAND_MAX_COORDS = EXPAND_MAX * 2;
  static const int EXPAND_MIN = 10;

  late Uint8List pointTypes;
  int numTypes = 0;
  int numCoords = 0;
  int windingRule = WIND_NON_ZERO;

  Path2D();

  Path2D.withRule(int rule, int initialTypes) {
    setWindingRule(rule);
    pointTypes = Uint8List(initialTypes);
  }

  // Abstract methods
  Float32List cloneCoordsFloat(AffineTransform? at);
  Float64List cloneCoordsDouble(AffineTransform? at);
  void appendFloat(double x, double y);
  void appendDouble(double x, double y);
  Point2D getPoint(int coordIndex);
  void needRoom(bool needMove, int newCoords);
  int pointCrossings(double px, double py);
  int rectCrossings(double rxmin, double rymin, double rxmax, double rymax);

  // Abstract path construction methods
  void moveTo(double x, double y);
  void lineTo(double x, double y);
  void quadTo(double x1, double y1, double x2, double y2);
  void curveTo(
      double x1, double y1, double x2, double y2, double x3, double y3);

  static Uint8List expandPointTypes(Uint8List oldPointTypes, int needed) {
    final int oldSize = oldPointTypes.length;
    final int newSizeMin = oldSize + needed;
    if (newSizeMin < oldSize) {
      throw RangeError("pointTypes exceeds maximum capacity!");
    }

    int grow = oldSize;
    if (grow > EXPAND_MAX) {
      grow = math.max(EXPAND_MAX, oldSize >> 3);
    } else if (grow < EXPAND_MIN) {
      grow = EXPAND_MIN;
    }

    int newSize = oldSize + grow;
    if (newSize < newSizeMin) {
      newSize = 0x7FFFFFFF; // Max int
    }

    final newArr = Uint8List(newSize);
    newArr.setRange(0, oldSize, oldPointTypes);
    return newArr;
  }

  void closePath() {
    if (numTypes == 0 || pointTypes[numTypes - 1] != SEG_CLOSE) {
      needRoom(true, 0);
      pointTypes[numTypes++] = SEG_CLOSE;
    }
  }

  void appendShape(Shape s, bool connect) {
    appendPathIterator(s.getPathIterator(null), connect);
  }

  void appendPathIterator(PathIterator pi, bool connect);

  int getWindingRule() => windingRule;

  void setWindingRule(int rule) {
    if (rule != WIND_EVEN_ODD && rule != WIND_NON_ZERO) {
      throw ArgumentError(
          "winding rule must be WIND_EVEN_ODD or WIND_NON_ZERO");
    }
    windingRule = rule;
  }

  Point2D? getCurrentPoint() {
    int index = numCoords;
    if (numTypes < 1 || index < 1) return null;

    if (pointTypes[numTypes - 1] == SEG_CLOSE) {
      for (int i = numTypes - 2; i > 0; i--) {
        switch (pointTypes[i]) {
          case SEG_MOVETO:
            return getPoint(index - 2);
          case SEG_LINETO:
            index -= 2;
            break;
          case SEG_QUADTO:
            index -= 4;
            break;
          case SEG_CUBICTO:
            index -= 6;
            break;
          case SEG_CLOSE:
            break;
        }
      }
    }
    return getPoint(index - 2);
  }

  void reset() {
    numTypes = numCoords = 0;
  }

  Shape createTransformedShape(AffineTransform? at) {
    final p2d = clone();
    if (at != null) {
      p2d.transform(at);
    }
    return p2d;
  }

  void transform(AffineTransform at);

  @override
  Rectangle getBounds() => getBounds2D().getBounds();

  @override
  bool contains(double x, double y) {
    if (x * 0.0 + y * 0.0 == 0.0) {
      if (numTypes < 2) return false;
      int mask = (windingRule == WIND_NON_ZERO ? -1 : 1);
      return ((pointCrossings(x, y) & mask) != 0);
    }
    return false;
  }

  @override
  bool containsPoint(Point2D p) => contains(p.getX(), p.getY());

  @override
  bool containsRect(double x, double y, double w, double h) {
    if (x.isNaN || (x + w).isNaN || y.isNaN || (y + h).isNaN) return false;
    if (w <= 0 || h <= 0) return false;

    int mask = (windingRule == WIND_NON_ZERO ? -1 : 2);
    int crossings = rectCrossings(x, y, x + w, y + h);
    return (crossings != Curve.RECT_INTERSECTS && (crossings & mask) != 0);
  }

  @override
  bool containsRectangle2D(Rectangle2D r) =>
      containsRect(r.getX(), r.getY(), r.getWidth(), r.getHeight());

  @override
  bool intersects(double x, double y, double w, double h) {
    if (x.isNaN || (x + w).isNaN || y.isNaN || (y + h).isNaN) return false;
    if (w <= 0 || h <= 0) return false;

    int mask = (windingRule == WIND_NON_ZERO ? -1 : 2);
    int crossings = rectCrossings(x, y, x + w, y + h);
    return (crossings == Curve.RECT_INTERSECTS || (crossings & mask) != 0);
  }

  @override
  bool intersectsRectangle2D(Rectangle2D r) =>
      intersects(r.getX(), r.getY(), r.getWidth(), r.getHeight());

  @override
  PathIterator getPathIteratorWithFlatness(
      AffineTransform? at, double flatness) {
    return FlatteningPathIterator(getPathIterator(at), flatness);
  }

  @override
  PathIterator getPathIterator(AffineTransform? at);

  Path2D clone();
}

// ============================================================================
// Path2DFloat Implementation
// ============================================================================

class Path2DFloat extends Path2D {
  late Float32List floatCoords;

  Path2DFloat() : super.withRule(WIND_NON_ZERO, Path2D.INIT_SIZE) {
    floatCoords = Float32List(Path2D.INIT_SIZE * 2);
  }

  Path2DFloat.withRule(int rule) : super.withRule(rule, Path2D.INIT_SIZE) {
    floatCoords = Float32List(Path2D.INIT_SIZE * 2);
  }

  Path2DFloat.withCapacity(int rule, int initialCapacity)
      : super.withRule(rule, initialCapacity) {
    floatCoords = Float32List(initialCapacity * 2);
  }

  Path2DFloat.fromShape(Shape s) : this.fromShapeWithTransform(s, null);

  Path2DFloat.fromShapeWithTransform(Shape s, AffineTransform? at) {
    if (s is Path2D) {
      Path2D p2d = s;
      setWindingRule(p2d.windingRule);
      numTypes = p2d.numTypes;
      pointTypes = Uint8List.fromList(p2d.pointTypes.sublist(0, p2d.numTypes));
      numCoords = p2d.numCoords;
      floatCoords = Float32List.fromList(p2d.cloneCoordsFloat(at));
    } else {
      PathIterator pi = s.getPathIterator(at);
      setWindingRule(pi.getWindingRule());
      pointTypes = Uint8List(Path2D.INIT_SIZE);
      floatCoords = Float32List(Path2D.INIT_SIZE * 2);
      appendPathIterator(pi, false);
    }
  }

  @override
  Float32List cloneCoordsFloat(AffineTransform? at) {
    Float32List ret;
    if (at == null) {
      ret = Float32List(numCoords);
      ret.setRange(0, numCoords, floatCoords);
    } else {
      ret = Float32List(numCoords);
      at.transformFloat(floatCoords, 0, ret, 0, numCoords ~/ 2);
    }
    return ret;
  }

  @override
  Float64List cloneCoordsDouble(AffineTransform? at) {
    Float64List ret = Float64List(numCoords);
    if (at == null) {
      for (int i = 0; i < numCoords; i++) {
        ret[i] = floatCoords[i];
      }
    } else {
      at.transform(floatCoords as List<double>, 0, ret, 0, numCoords ~/ 2);
    }
    return ret;
  }

  @override
  void appendFloat(double x, double y) {
    floatCoords[numCoords++] = x;
    floatCoords[numCoords++] = y;
  }

  @override
  void appendDouble(double x, double y) {
    floatCoords[numCoords++] = x.toDouble();
    floatCoords[numCoords++] = y.toDouble();
  }

  @override
  Point2D getPoint(int coordIndex) {
    return Point2D(floatCoords[coordIndex], floatCoords[coordIndex + 1]);
  }

  @override
  void needRoom(bool needMove, int newCoords) {
    if ((numTypes == 0) && needMove) {
      throw IllegalPathStateException(
          "missing initial moveto in path definition");
    }
    if (numTypes >= pointTypes.length) {
      pointTypes = Path2D.expandPointTypes(pointTypes, 1);
    }
    if (numCoords > (floatCoords.length - newCoords)) {
      floatCoords = expandCoords(floatCoords, newCoords);
    }
  }

  static Float32List expandCoords(Float32List oldCoords, int needed) {
    final int oldSize = oldCoords.length;
    final int newSizeMin = oldSize + needed;
    if (newSizeMin < oldSize) {
      throw RangeError("coords exceeds maximum capacity!");
    }

    int grow = oldSize;
    if (grow > Path2D.EXPAND_MAX_COORDS) {
      grow = math.max(Path2D.EXPAND_MAX_COORDS, oldSize >> 3);
    } else if (grow < Path2D.EXPAND_MIN) {
      grow = Path2D.EXPAND_MIN;
    }

    int newSize = oldSize + grow;
    if (newSize < newSizeMin) {
      newSize = 0x7FFFFFFF;
    }

    final newArr = Float32List(newSize);
    newArr.setRange(0, oldSize, oldCoords);
    return newArr;
  }

  @override
  void moveTo(double x, double y) {
    if (numTypes > 0 && pointTypes[numTypes - 1] == SEG_MOVETO) {
      floatCoords[numCoords - 2] = x.toDouble();
      floatCoords[numCoords - 1] = y.toDouble();
    } else {
      needRoom(false, 2);
      pointTypes[numTypes++] = SEG_MOVETO;
      floatCoords[numCoords++] = x.toDouble();
      floatCoords[numCoords++] = y.toDouble();
    }
  }

  void moveToFloat(double x, double y) {
    if (numTypes > 0 && pointTypes[numTypes - 1] == SEG_MOVETO) {
      floatCoords[numCoords - 2] = x;
      floatCoords[numCoords - 1] = y;
    } else {
      needRoom(false, 2);
      pointTypes[numTypes++] = SEG_MOVETO;
      floatCoords[numCoords++] = x;
      floatCoords[numCoords++] = y;
    }
  }

  @override
  void lineTo(double x, double y) {
    needRoom(true, 2);
    pointTypes[numTypes++] = SEG_LINETO;
    floatCoords[numCoords++] = x.toDouble();
    floatCoords[numCoords++] = y.toDouble();
  }

  void lineToFloat(double x, double y) {
    needRoom(true, 2);
    pointTypes[numTypes++] = SEG_LINETO;
    floatCoords[numCoords++] = x;
    floatCoords[numCoords++] = y;
  }

  @override
  void quadTo(double x1, double y1, double x2, double y2) {
    needRoom(true, 4);
    pointTypes[numTypes++] = SEG_QUADTO;
    floatCoords[numCoords++] = x1.toDouble();
    floatCoords[numCoords++] = y1.toDouble();
    floatCoords[numCoords++] = x2.toDouble();
    floatCoords[numCoords++] = y2.toDouble();
  }

  void quadToFloat(double x1, double y1, double x2, double y2) {
    needRoom(true, 4);
    pointTypes[numTypes++] = SEG_QUADTO;
    floatCoords[numCoords++] = x1;
    floatCoords[numCoords++] = y1;
    floatCoords[numCoords++] = x2;
    floatCoords[numCoords++] = y2;
  }

  @override
  void curveTo(
      double x1, double y1, double x2, double y2, double x3, double y3) {
    needRoom(true, 6);
    pointTypes[numTypes++] = SEG_CUBICTO;
    floatCoords[numCoords++] = x1.toDouble();
    floatCoords[numCoords++] = y1.toDouble();
    floatCoords[numCoords++] = x2.toDouble();
    floatCoords[numCoords++] = y2.toDouble();
    floatCoords[numCoords++] = x3.toDouble();
    floatCoords[numCoords++] = y3.toDouble();
  }

  void curveToFloat(
      double x1, double y1, double x2, double y2, double x3, double y3) {
    needRoom(true, 6);
    pointTypes[numTypes++] = SEG_CUBICTO;
    floatCoords[numCoords++] = x1;
    floatCoords[numCoords++] = y1;
    floatCoords[numCoords++] = x2;
    floatCoords[numCoords++] = y2;
    floatCoords[numCoords++] = x3;
    floatCoords[numCoords++] = y3;
  }

  @override
  int pointCrossings(double px, double py) {
    if (numTypes == 0) return 0;

    double movx, movy, curx, cury, endx, endy;
    curx = movx = floatCoords[0];
    cury = movy = floatCoords[1];
    int crossings = 0;
    int ci = 2;

    for (int i = 1; i < numTypes; i++) {
      switch (pointTypes[i]) {
        case SEG_MOVETO:
          if (cury != movy) {
            crossings +=
                Curve.pointCrossingsForLine(px, py, curx, cury, movx, movy);
          }
          movx = curx = floatCoords[ci++];
          movy = cury = floatCoords[ci++];
          break;
        case SEG_LINETO:
          crossings += Curve.pointCrossingsForLine(px, py, curx, cury,
              endx = floatCoords[ci++], endy = floatCoords[ci++]);
          curx = endx;
          cury = endy;
          break;
        case SEG_QUADTO:
          crossings += Curve.pointCrossingsForQuad(
              px,
              py,
              curx,
              cury,
              floatCoords[ci++],
              floatCoords[ci++],
              endx = floatCoords[ci++],
              endy = floatCoords[ci++],
              0);
          curx = endx;
          cury = endy;
          break;
        case SEG_CUBICTO:
          crossings += Curve.pointCrossingsForCubic(
              px,
              py,
              curx,
              cury,
              floatCoords[ci++],
              floatCoords[ci++],
              floatCoords[ci++],
              floatCoords[ci++],
              endx = floatCoords[ci++],
              endy = floatCoords[ci++],
              0);
          curx = endx;
          cury = endy;
          break;
        case SEG_CLOSE:
          if (cury != movy) {
            crossings +=
                Curve.pointCrossingsForLine(px, py, curx, cury, movx, movy);
          }
          curx = movx;
          cury = movy;
          break;
      }
    }

    if (cury != movy) {
      crossings += Curve.pointCrossingsForLine(px, py, curx, cury, movx, movy);
    }
    return crossings;
  }

  @override
  int rectCrossings(double rxmin, double rymin, double rxmax, double rymax) {
    if (numTypes == 0) return 0;

    double curx, cury, movx, movy, endx, endy;
    curx = movx = floatCoords[0];
    cury = movy = floatCoords[1];
    int crossings = 0;
    int ci = 2;

    for (int i = 1; crossings != Curve.RECT_INTERSECTS && i < numTypes; i++) {
      switch (pointTypes[i]) {
        case SEG_MOVETO:
          if (curx != movx || cury != movy) {
            crossings = Curve.rectCrossingsForLine(
                crossings, rxmin, rymin, rxmax, rymax, curx, cury, movx, movy);
          }
          movx = curx = floatCoords[ci++];
          movy = cury = floatCoords[ci++];
          break;
        case SEG_LINETO:
          crossings = Curve.rectCrossingsForLine(
              crossings,
              rxmin,
              rymin,
              rxmax,
              rymax,
              curx,
              cury,
              endx = floatCoords[ci++],
              endy = floatCoords[ci++]);
          curx = endx;
          cury = endy;
          break;
        case SEG_QUADTO:
          crossings = Curve.rectCrossingsForQuad(
              crossings,
              rxmin,
              rymin,
              rxmax,
              rymax,
              curx,
              cury,
              floatCoords[ci++],
              floatCoords[ci++],
              endx = floatCoords[ci++],
              endy = floatCoords[ci++],
              0);
          curx = endx;
          cury = endy;
          break;
        case SEG_CUBICTO:
          crossings = Curve.rectCrossingsForCubic(
              crossings,
              rxmin,
              rymin,
              rxmax,
              rymax,
              curx,
              cury,
              floatCoords[ci++],
              floatCoords[ci++],
              floatCoords[ci++],
              floatCoords[ci++],
              endx = floatCoords[ci++],
              endy = floatCoords[ci++],
              0);
          curx = endx;
          cury = endy;
          break;
        case SEG_CLOSE:
          if (curx != movx || cury != movy) {
            crossings = Curve.rectCrossingsForLine(
                crossings, rxmin, rymin, rxmax, rymax, curx, cury, movx, movy);
          }
          curx = movx;
          cury = movy;
          break;
      }
    }

    if (crossings != Curve.RECT_INTERSECTS && (curx != movx || cury != movy)) {
      crossings = Curve.rectCrossingsForLine(
          crossings, rxmin, rymin, rxmax, rymax, curx, cury, movx, movy);
    }
    return crossings;
  }

  @override
  void appendPathIterator(PathIterator pi, bool connect) {
    List<double> coords = List<double>.filled(6, 0);

    while (!pi.isDone()) {
      switch (pi.currentSegment(coords)) {
        case SEG_MOVETO:
          if (!connect || numTypes < 1 || numCoords < 1) {
            moveTo(coords[0], coords[1]);
            break;
          }
          if (pointTypes[numTypes - 1] != SEG_CLOSE &&
              floatCoords[numCoords - 2] == coords[0] &&
              floatCoords[numCoords - 1] == coords[1]) {
            break;
          }
          lineTo(coords[0], coords[1]);
          break;
        case SEG_LINETO:
          lineTo(coords[0], coords[1]);
          break;
        case SEG_QUADTO:
          quadTo(coords[0], coords[1], coords[2], coords[3]);
          break;
        case SEG_CUBICTO:
          curveTo(
              coords[0], coords[1], coords[2], coords[3], coords[4], coords[5]);
          break;
        case SEG_CLOSE:
          closePath();
          break;
      }
      pi.next();
      connect = false;
    }
  }

  @override
  void transform(AffineTransform at) {
    at.transformFloat(floatCoords, 0, floatCoords, 0, numCoords ~/ 2);
  }

  @override
  Rectangle2D getBounds2D() {
    double x1, y1, x2, y2;
    int i = numCoords;

    if (i > 0) {
      y1 = y2 = floatCoords[--i];
      x1 = x2 = floatCoords[--i];
      while (i > 0) {
        double y = floatCoords[--i];
        double x = floatCoords[--i];
        if (x < x1) x1 = x;
        if (y < y1) y1 = y;
        if (x > x2) x2 = x;
        if (y > y2) y2 = y;
      }
    } else {
      x1 = y1 = x2 = y2 = 0.0;
    }
    return Rectangle2D(x1, y1, x2 - x1, y2 - y1);
  }

  @override
  PathIterator getPathIterator(AffineTransform? at) {
    if (at == null) {
      return CopyIteratorFloat(this);
    } else {
      return TxIteratorFloat(this, at);
    }
  }

  @override
  Path2DFloat clone() => Path2DFloat.fromShapeWithTransform(this, null);
}

// ============================================================================
// Path2DDouble Implementation
// ============================================================================

class Path2DDouble extends Path2D {
  late Float64List doubleCoords;

  Path2DDouble() : super.withRule(WIND_NON_ZERO, Path2D.INIT_SIZE) {
    doubleCoords = Float64List(Path2D.INIT_SIZE * 2);
  }

  Path2DDouble.withRule(int rule) : super.withRule(rule, Path2D.INIT_SIZE) {
    doubleCoords = Float64List(Path2D.INIT_SIZE * 2);
  }

  Path2DDouble.withCapacity(int rule, int initialCapacity)
      : super.withRule(rule, initialCapacity) {
    doubleCoords = Float64List(initialCapacity * 2);
  }

  Path2DDouble.fromShape(Shape s) : this.fromShapeWithTransform(s, null);

  Path2DDouble.fromShapeWithTransform(Shape s, AffineTransform? at) {
    if (s is Path2D) {
      Path2D p2d = s;
      setWindingRule(p2d.windingRule);
      numTypes = p2d.numTypes;
      pointTypes = Uint8List.fromList(p2d.pointTypes.sublist(0, p2d.numTypes));
      numCoords = p2d.numCoords;
      doubleCoords = Float64List.fromList(p2d.cloneCoordsDouble(at));
    } else {
      PathIterator pi = s.getPathIterator(at);
      setWindingRule(pi.getWindingRule());
      pointTypes = Uint8List(Path2D.INIT_SIZE);
      doubleCoords = Float64List(Path2D.INIT_SIZE * 2);
      appendPathIterator(pi, false);
    }
  }

  @override
  Float32List cloneCoordsFloat(AffineTransform? at) {
    Float32List ret = Float32List(numCoords);
    if (at == null) {
      for (int i = 0; i < numCoords; i++) {
        ret[i] = doubleCoords[i];
      }
    } else {
      at.transform(doubleCoords, 0, ret, 0, numCoords ~/ 2);
    }
    return ret;
  }

  @override
  Float64List cloneCoordsDouble(AffineTransform? at) {
    Float64List ret;
    if (at == null) {
      ret = Float64List(numCoords);
      ret.setRange(0, numCoords, doubleCoords);
    } else {
      ret = Float64List(numCoords);
      at.transform(doubleCoords, 0, ret, 0, numCoords ~/ 2);
    }
    return ret;
  }

  @override
  void appendFloat(double x, double y) {
    doubleCoords[numCoords++] = x;
    doubleCoords[numCoords++] = y;
  }

  @override
  void appendDouble(double x, double y) {
    doubleCoords[numCoords++] = x;
    doubleCoords[numCoords++] = y;
  }

  @override
  Point2D getPoint(int coordIndex) {
    return Point2D(doubleCoords[coordIndex], doubleCoords[coordIndex + 1]);
  }

  @override
  void needRoom(bool needMove, int newCoords) {
    if ((numTypes == 0) && needMove) {
      throw IllegalPathStateException(
          "missing initial moveto in path definition");
    }
    if (numTypes >= pointTypes.length) {
      pointTypes = Path2D.expandPointTypes(pointTypes, 1);
    }
    if (numCoords > (doubleCoords.length - newCoords)) {
      doubleCoords = expandCoords(doubleCoords, newCoords);
    }
  }

  static Float64List expandCoords(Float64List oldCoords, int needed) {
    final int oldSize = oldCoords.length;
    final int newSizeMin = oldSize + needed;
    if (newSizeMin < oldSize) {
      throw RangeError("coords exceeds maximum capacity!");
    }

    int grow = oldSize;
    if (grow > Path2D.EXPAND_MAX_COORDS) {
      grow = math.max(Path2D.EXPAND_MAX_COORDS, oldSize >> 3);
    } else if (grow < Path2D.EXPAND_MIN) {
      grow = Path2D.EXPAND_MIN;
    }

    int newSize = oldSize + grow;
    if (newSize < newSizeMin) {
      newSize = 0x7FFFFFFF;
    }

    final newArr = Float64List(newSize);
    newArr.setRange(0, oldSize, oldCoords);
    return newArr;
  }

  @override
  void moveTo(double x, double y) {
    if (numTypes > 0 && pointTypes[numTypes - 1] == SEG_MOVETO) {
      doubleCoords[numCoords - 2] = x;
      doubleCoords[numCoords - 1] = y;
    } else {
      needRoom(false, 2);
      pointTypes[numTypes++] = SEG_MOVETO;
      doubleCoords[numCoords++] = x;
      doubleCoords[numCoords++] = y;
    }
  }

  @override
  void lineTo(double x, double y) {
    needRoom(true, 2);
    pointTypes[numTypes++] = SEG_LINETO;
    doubleCoords[numCoords++] = x;
    doubleCoords[numCoords++] = y;
  }

  @override
  void quadTo(double x1, double y1, double x2, double y2) {
    needRoom(true, 4);
    pointTypes[numTypes++] = SEG_QUADTO;
    doubleCoords[numCoords++] = x1;
    doubleCoords[numCoords++] = y1;
    doubleCoords[numCoords++] = x2;
    doubleCoords[numCoords++] = y2;
  }

  @override
  void curveTo(
      double x1, double y1, double x2, double y2, double x3, double y3) {
    needRoom(true, 6);
    pointTypes[numTypes++] = SEG_CUBICTO;
    doubleCoords[numCoords++] = x1;
    doubleCoords[numCoords++] = y1;
    doubleCoords[numCoords++] = x2;
    doubleCoords[numCoords++] = y2;
    doubleCoords[numCoords++] = x3;
    doubleCoords[numCoords++] = y3;
  }

  @override
  int pointCrossings(double px, double py) {
    if (numTypes == 0) return 0;

    double movx, movy, curx, cury, endx, endy;
    curx = movx = doubleCoords[0];
    cury = movy = doubleCoords[1];
    int crossings = 0;
    int ci = 2;

    for (int i = 1; i < numTypes; i++) {
      switch (pointTypes[i]) {
        case SEG_MOVETO:
          if (cury != movy) {
            crossings +=
                Curve.pointCrossingsForLine(px, py, curx, cury, movx, movy);
          }
          movx = curx = doubleCoords[ci++];
          movy = cury = doubleCoords[ci++];
          break;
        case SEG_LINETO:
          crossings += Curve.pointCrossingsForLine(px, py, curx, cury,
              endx = doubleCoords[ci++], endy = doubleCoords[ci++]);
          curx = endx;
          cury = endy;
          break;
        case SEG_QUADTO:
          crossings += Curve.pointCrossingsForQuad(
              px,
              py,
              curx,
              cury,
              doubleCoords[ci++],
              doubleCoords[ci++],
              endx = doubleCoords[ci++],
              endy = doubleCoords[ci++],
              0);
          curx = endx;
          cury = endy;
          break;
        case SEG_CUBICTO:
          crossings += Curve.pointCrossingsForCubic(
              px,
              py,
              curx,
              cury,
              doubleCoords[ci++],
              doubleCoords[ci++],
              doubleCoords[ci++],
              doubleCoords[ci++],
              endx = doubleCoords[ci++],
              endy = doubleCoords[ci++],
              0);
          curx = endx;
          cury = endy;
          break;
        case SEG_CLOSE:
          if (cury != movy) {
            crossings +=
                Curve.pointCrossingsForLine(px, py, curx, cury, movx, movy);
          }
          curx = movx;
          cury = movy;
          break;
      }
    }

    if (cury != movy) {
      crossings += Curve.pointCrossingsForLine(px, py, curx, cury, movx, movy);
    }
    return crossings;
  }

  @override
  int rectCrossings(double rxmin, double rymin, double rxmax, double rymax) {
    if (numTypes == 0) return 0;

    double curx, cury, movx, movy, endx, endy;
    curx = movx = doubleCoords[0];
    cury = movy = doubleCoords[1];
    int crossings = 0;
    int ci = 2;

    for (int i = 1; crossings != Curve.RECT_INTERSECTS && i < numTypes; i++) {
      switch (pointTypes[i]) {
        case SEG_MOVETO:
          if (curx != movx || cury != movy) {
            crossings = Curve.rectCrossingsForLine(
                crossings, rxmin, rymin, rxmax, rymax, curx, cury, movx, movy);
          }
          movx = curx = doubleCoords[ci++];
          movy = cury = doubleCoords[ci++];
          break;
        case SEG_LINETO:
          endx = doubleCoords[ci++];
          endy = doubleCoords[ci++];
          crossings = Curve.rectCrossingsForLine(
              crossings, rxmin, rymin, rxmax, rymax, curx, cury, endx, endy);
          curx = endx;
          cury = endy;
          break;
        case SEG_QUADTO:
          crossings = Curve.rectCrossingsForQuad(
              crossings,
              rxmin,
              rymin,
              rxmax,
              rymax,
              curx,
              cury,
              doubleCoords[ci++],
              doubleCoords[ci++],
              endx = doubleCoords[ci++],
              endy = doubleCoords[ci++],
              0);
          curx = endx;
          cury = endy;
          break;
        case SEG_CUBICTO:
          crossings = Curve.rectCrossingsForCubic(
              crossings,
              rxmin,
              rymin,
              rxmax,
              rymax,
              curx,
              cury,
              doubleCoords[ci++],
              doubleCoords[ci++],
              doubleCoords[ci++],
              doubleCoords[ci++],
              endx = doubleCoords[ci++],
              endy = doubleCoords[ci++],
              0);
          curx = endx;
          cury = endy;
          break;
        case SEG_CLOSE:
          if (curx != movx || cury != movy) {
            crossings = Curve.rectCrossingsForLine(
                crossings, rxmin, rymin, rxmax, rymax, curx, cury, movx, movy);
          }
          curx = movx;
          cury = movy;
          break;
      }
    }

    if (crossings != Curve.RECT_INTERSECTS && (curx != movx || cury != movy)) {
      crossings = Curve.rectCrossingsForLine(
          crossings, rxmin, rymin, rxmax, rymax, curx, cury, movx, movy);
    }
    return crossings;
  }

  @override
  void appendPathIterator(PathIterator pi, bool connect) {
    List<double> coords = List<double>.filled(6, 0);

    while (!pi.isDone()) {
      switch (pi.currentSegment(coords)) {
        case SEG_MOVETO:
          if (!connect || numTypes < 1 || numCoords < 1) {
            moveTo(coords[0], coords[1]);
            break;
          }
          if (pointTypes[numTypes - 1] != SEG_CLOSE &&
              doubleCoords[numCoords - 2] == coords[0] &&
              doubleCoords[numCoords - 1] == coords[1]) {
            break;
          }
          lineTo(coords[0], coords[1]);
          break;
        case SEG_LINETO:
          lineTo(coords[0], coords[1]);
          break;
        case SEG_QUADTO:
          quadTo(coords[0], coords[1], coords[2], coords[3]);
          break;
        case SEG_CUBICTO:
          curveTo(
              coords[0], coords[1], coords[2], coords[3], coords[4], coords[5]);
          break;
        case SEG_CLOSE:
          closePath();
          break;
      }
      pi.next();
      connect = false;
    }
  }

  @override
  void transform(AffineTransform at) {
    at.transform(doubleCoords, 0, doubleCoords, 0, numCoords ~/ 2);
  }

  @override
  Rectangle2D getBounds2D() {
    double x1, y1, x2, y2;
    int i = numCoords;

    if (i > 0) {
      y1 = y2 = doubleCoords[--i];
      x1 = x2 = doubleCoords[--i];
      while (i > 0) {
        double y = doubleCoords[--i];
        double x = doubleCoords[--i];
        if (x < x1) x1 = x;
        if (y < y1) y1 = y;
        if (x > x2) x2 = x;
        if (y > y2) y2 = y;
      }
    } else {
      x1 = y1 = x2 = y2 = 0.0;
    }
    return Rectangle2D(x1, y1, x2 - x1, y2 - y1);
  }

  @override
  PathIterator getPathIterator(AffineTransform? at) {
    if (at == null) {
      return CopyIteratorDouble(this);
    } else {
      return TxIteratorDouble(this, at);
    }
  }

  @override
  Path2DDouble clone() => Path2DDouble.fromShapeWithTransform(this, null);
}

// ============================================================================
// Path Iterators
// ============================================================================

abstract class Path2DIterator implements PathIterator {
  final Path2D path;
  int typeIdx = 0;
  int pointIdx = 0;

  static final List<int> curvecoords = [2, 2, 4, 6, 0];

  Path2DIterator(this.path);

  @override
  int getWindingRule() => path.getWindingRule();

  @override
  bool isDone() => typeIdx >= path.numTypes;

  @override
  void next() {
    int type = path.pointTypes[typeIdx++];
    pointIdx += curvecoords[type];
  }
}

class CopyIteratorFloat extends Path2DIterator {
  final Float32List floatCoords;

  CopyIteratorFloat(Path2DFloat p2df)
      : floatCoords = p2df.floatCoords,
        super(p2df);

  @override
  int currentSegment(List<double> coords) {
    int type = path.pointTypes[typeIdx];
    int numCoords = Path2DIterator.curvecoords[type];
    if (numCoords > 0) {
      for (int i = 0; i < numCoords; i++) {
        coords[i] = floatCoords[pointIdx + i];
      }
    }
    return type;
  }
}

class TxIteratorFloat extends Path2DIterator {
  final Float32List floatCoords;
  final AffineTransform affine;

  TxIteratorFloat(Path2DFloat p2df, AffineTransform at)
      : floatCoords = p2df.floatCoords,
        affine = at,
        super(p2df);

  @override
  int currentSegment(List<double> coords) {
    int type = path.pointTypes[typeIdx];
    int numCoords = Path2DIterator.curvecoords[type];
    if (numCoords > 0) {
      affine.transformFloat(floatCoords, pointIdx, Float32List.fromList(coords),
          0, numCoords ~/ 2);
      for (int i = 0; i < numCoords; i++) {
        coords[i] = Float32List.fromList(coords)[i];
      }
    }
    return type;
  }
}

class CopyIteratorDouble extends Path2DIterator {
  final Float64List doubleCoords;

  CopyIteratorDouble(Path2DDouble p2dd)
      : doubleCoords = p2dd.doubleCoords,
        super(p2dd);

  @override
  int currentSegment(List<double> coords) {
    int type = path.pointTypes[typeIdx];
    int numCoords = Path2DIterator.curvecoords[type];
    if (numCoords > 0) {
      for (int i = 0; i < numCoords; i++) {
        coords[i] = doubleCoords[pointIdx + i];
      }
    }
    return type;
  }
}

class TxIteratorDouble extends Path2DIterator {
  final Float64List doubleCoords;
  final AffineTransform affine;

  TxIteratorDouble(Path2DDouble p2dd, AffineTransform at)
      : doubleCoords = p2dd.doubleCoords,
        affine = at,
        super(p2dd);

  @override
  int currentSegment(List<double> coords) {
    int type = path.pointTypes[typeIdx];
    int numCoords = Path2DIterator.curvecoords[type];
    if (numCoords > 0) {
      affine.transform(doubleCoords, pointIdx, coords, 0, numCoords ~/ 2);
    }
    return type;
  }
}
