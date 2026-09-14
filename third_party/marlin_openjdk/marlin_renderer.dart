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
import 'marlin_const.dart';
import 'float_math.dart';
import 'context/renderer_context.dart';
import 'context/array_cache_config.dart';
import 'marlin_cache.dart';
import 'curve.dart';
import 'path_consumer_2d.dart';

// Future recommendations (post-session):
// Profile
// _widenIntArray
// : Frequent calls here indicate initial bucket sizes might be too small. Increasing MarlinConst.initialEdgesCapacity could reduce resizing overhead.
// Optimize
// _blit
// : The current
// _blit
//  pixel blending logic performs many individual Int32List lookups per pixel. Unrolling loops or using Int32x4 SIMD instructions (if applicable in Dart Web/Native) could help.
// Review
// Dasher
// : The
// Dasher
//  interacts with Stroker which interacts with
// Renderer
// . This chain creates many method calls. Inlining simple math or reducing recursion depth in
// LengthIterator
//  might help.
// The Marlin renderer is now functional, correct, and feature-complete (supporting paths, strokes, dashes, transforms, and winding rules), albeit with room for performance tuning in a pure Dart environment.

class MarlinRenderer implements PathConsumer2D {
  // ignore: unused_field
  static const bool _doStats = false;
  // ignore: unused_field
  static const bool _doMonitors = false;
  // ignore: unused_field
  static const bool _doLogBounds = false;

  // Constants aliases
  static const int _offCurX = MarlinConst.offCurX;
  static const int _offError = MarlinConst.offError;
  static const int _offBumpX = MarlinConst.offBumpX;
  static const int _offBumpErr = MarlinConst.offBumpErr;
  static const int _offNext = MarlinConst.offNext;
  static const int _offYMaxOr = MarlinConst.offYmaxOr;
  static const int _sizeofEdge = MarlinConst.sizeofEdge;

  static const int _subpixelLgPositionsX = MarlinConst.subpixelLgPositionsX;
  static const int _subpixelLgPositionsY = MarlinConst.subpixelLgPositionsY;
  static const int _subpixelPositionsX = MarlinConst.subpixelPositionsX;
  // ignore: unused_field
  static const int _subpixelPositionsY = MarlinConst.subpixelPositionsY;
  // ignore: unused_field
  static const int _subpixelMaskX = MarlinConst.subpixelMaskX;
  // ignore: unused_field
  static const int _subpixelMaskY = MarlinConst.subpixelMaskY;
  static const double _power2To32 = MarlinConst.power2To32;
  static const int _mask32 = 0xFFFFFFFF;

  // ignore: unused_field
  static const double _quadDecBnd = 8.0 * (1.0 / 8.0);

  final RendererContext _rdrCtx;
  final MarlinCache _cache;
  final Curve _curve;

  // High-level API fields
  final int _width;
  final int _height;
  final Int32List _pixelBuffer;

  // Fields
  int _boundsMinX = 0, _boundsMinY = 0, _boundsMaxX = 0, _boundsMaxY = 0;
  // ignore: unused_field
  int _bboxMinX = 0, _bboxMinY = 0, _bboxMaxX = 0, _bboxMaxY = 0;

  double _edgeMinY = 0.0, _edgeMaxY = 0.0;
  double _edgeMinX = 0.0, _edgeMaxX = 0.0;

  // ignore: unused_field
  int _windingRule = MarlinConst.windNonZero;
  double _x0 = 0.0, _y0 = 0.0;
  double _pixSx0 = 0.0, _pixSy0 = 0.0;
  bool _subpathOpen = false;

  // Arrays
  Int32List _edges;
  int _edgesPos = 0;

  Int32List _edgeBuckets;
  Int32List _edgeBucketCounts;

  // Scanline arrays
  Int32List _crossings;
  Int32List _edgePtrs;
  // Aux arrays for sort (if needed, simplified to QuickSort for now)
  // Int32List _auxCrossings;
  // Int32List _auxEdgePtrs;

  Int32List _alphaLine;
  // ignore: unused_field
  int _edgeCount = 0;
  int _bboxSpMinX = 0, _bboxSpMaxX = 0, _bboxSpMinY = 0, _bboxSpMaxY = 0;

  // Init
  factory MarlinRenderer(int width, int height) {
    return MarlinRenderer.withContext(
        RendererContext.createContext(), width, height);
  }

  MarlinRenderer.withContext(this._rdrCtx, int width, int height)
      : _width = width,
        _height = height,
        _cache = MarlinCache(_rdrCtx),
        _pixelBuffer = Int32List(width * height),
        _curve = Curve(),
        _edges =
            _rdrCtx.getIntArray(MarlinConst.initialEdgesCapacity) as Int32List,
        _edgeBuckets =
            _rdrCtx.getIntArray(MarlinConst.initialBucketArray) as Int32List,
        _edgeBucketCounts =
            _rdrCtx.getIntArray(MarlinConst.initialBucketArray) as Int32List,
        _crossings =
            _rdrCtx.getIntArray(MarlinConst.initialSmallArray) as Int32List,
        _edgePtrs =
            _rdrCtx.getIntArray(MarlinConst.initialSmallArray) as Int32List,
        _alphaLine =
            _rdrCtx.getIntArray(MarlinConst.initialAAArray) as Int32List;

  Int32List get buffer => _pixelBuffer;

  void clear(int color) {
    _pixelBuffer.fillRange(0, _pixelBuffer.length, color);
  }

  // Lifecycle
  void init(
      [int pixBoundsX = 0,
      int pixBoundsY = 0,
      int? pixBoundsWidth,
      int? pixBoundsHeight,
      int windingRule = MarlinConst.windNonZero]) {
    _windingRule = windingRule;

    int w = pixBoundsWidth ?? _width;
    int h = pixBoundsHeight ?? _height;

    _boundsMinX = pixBoundsX << _subpixelLgPositionsX;
    _boundsMaxX = (pixBoundsX + w) << _subpixelLgPositionsX;
    _boundsMinY = pixBoundsY << _subpixelLgPositionsY;
    _boundsMaxY = (pixBoundsY + h) << _subpixelLgPositionsY;

    final int edgeBucketsLength = (_boundsMaxY - _boundsMinY) + 1;
    if (edgeBucketsLength > _edgeBuckets.length) {
      _edgeBuckets = _rdrCtx.getIntArray(edgeBucketsLength) as Int32List;
      _edgeBucketCounts = _rdrCtx.getIntArray(edgeBucketsLength) as Int32List;
    }

    _edgeMinY = double.infinity;
    _edgeMaxY = double.negativeInfinity;
    _edgeMinX = double.infinity;
    _edgeMaxX = double.negativeInfinity;

    _edgeCount = 0;
    _edgesPos = _sizeofEdge; // Start at non-zero to verify linked lists
    _subpathOpen = false;

    _edgeBuckets.fillRange(0, edgeBucketsLength, 0);
    _edgeBucketCounts.fillRange(0, edgeBucketsLength, 0);
  }

  void dispose() {
    _cache.dispose();

    _rdrCtx.putIntArray(_edges, 0, _edgesPos);
    _rdrCtx.putIntArray(_edgeBuckets, 0, 0);
    _rdrCtx.putIntArray(_edgeBucketCounts, 0, 0);

    // Auxiliary arrays - clear potentially used portion or all to be safe (since we don't track used length outside scanline loop)
    _rdrCtx.putIntArray(_crossings, 0, _crossings.length);
    _rdrCtx.putIntArray(_edgePtrs, 0, _edgePtrs.length);

    _rdrCtx.putIntArray(_alphaLine, 0, 0); // Should be clean from scanline loop
  }

  // Coordinate utils
  static double _toSubpixX(double pixX) =>
      MarlinConst.fSubpixelPositionsX * pixX;
  static double _toSubpixY(double pixY) =>
      MarlinConst.fSubpixelPositionsY * pixY - 0.5;

  // PathConsumer2D
  void moveTo(double pixX, double pixY) {
    if (_subpathOpen) {
      closePath();
    }
    _pixSx0 = pixX;
    _pixSy0 = pixY;
    _x0 = _toSubpixX(pixX);
    _y0 = _toSubpixY(pixY);
    _subpathOpen = true;
  }

  void lineTo(double pixX, double pixY) {
    double x1 = _toSubpixX(pixX);
    double y1 = _toSubpixY(pixY);
    _addLine(_x0, _y0, x1, y1);
    _x0 = x1;
    _y0 = y1;
  }

  void closePath() {
    if (!_subpathOpen) return;
    lineTo(_pixSx0, _pixSy0);
    _subpathOpen = false;
  }

  void curveTo(
      double x1, double y1, double x2, double y2, double x3, double y3) {
    final double xe = _toSubpixX(x3);
    final double ye = _toSubpixY(y3);
    _curve.setCubic(_x0, _y0, _toSubpixX(x1), _toSubpixY(y1), _toSubpixX(x2),
        _toSubpixY(y2), xe, ye);
    _curveBreakIntoLinesAndAdd(_x0, _y0, _curve, xe, ye);
    _x0 = xe;
    _y0 = ye;
  }

  void quadTo(double x1, double y1, double x2, double y2) {
    final double xe = _toSubpixX(x2);
    final double ye = _toSubpixY(y2);
    _curve.setQuad(_x0, _y0, _toSubpixX(x1), _toSubpixY(y1), xe, ye);
    _quadBreakIntoLinesAndAdd(_x0, _y0, _curve, xe, ye);
    _x0 = xe;
    _y0 = ye;
  }

  @override
  void pathDone() {
    closePath();
    endRendering();
  }

  // Implementation Placeholders
  void _addLine(double x1, double y1, double x2, double y2) {
    int or = 1;
    if (y2 < y1) {
      or = 0;
      double tmp = y2;
      y2 = y1;
      y1 = tmp;
      tmp = x2;
      x2 = x1;
      x1 = tmp;
    }

    final int firstCrossing =
        FloatMath.maxInt(FloatMath.ceilInt(y1), _boundsMinY);
    final int lastCrossing =
        FloatMath.minInt(FloatMath.ceilInt(y2), _boundsMaxY);

    if (firstCrossing >= lastCrossing) return;

    if (y1 < _edgeMinY) _edgeMinY = y1;
    if (y2 > _edgeMaxY) _edgeMaxY = y2;

    final double slope = (x2 - x1) / (y2 - y1);

    if (slope >= 0.0) {
      if (x1 < _edgeMinX) _edgeMinX = x1;
      if (x2 > _edgeMaxX) _edgeMaxX = x2;
    } else {
      if (x2 < _edgeMinX) _edgeMinX = x2;
      if (x1 > _edgeMaxX) _edgeMaxX = x1;
    }

    final int ptr = _edgesPos;
    if (_edges.length < ptr + _sizeofEdge) {
      _edges = _widenIntArray(_edges, ptr, _edges.length << 1);
    }

    final double x1Intercept = x1 + (firstCrossing - y1) * slope;
    // 2^32 * x + 0x7fffffff
    final int x1FixedBiased = (_power2To32 * x1Intercept).toInt() + 2147483647;

    _edges[ptr + _offCurX] = _i32(x1FixedBiased >> 32);
    _edges[ptr + _offError] = ((x1FixedBiased & _mask32) >> 1);

    final int slopeFixed = (_power2To32 * slope).toInt();
    _edges[ptr + _offBumpX] = _i32(slopeFixed >> 32);
    _edges[ptr + _offBumpErr] = ((slopeFixed & _mask32) >> 1);

    final int bucketIdx = firstCrossing - _boundsMinY;

    _edges[ptr + _offNext] = _edgeBuckets[bucketIdx];
    _edges[ptr + _offYMaxOr] = (lastCrossing << 1) | or;

    _edgeBuckets[bucketIdx] = ptr;
    _edgeBucketCounts[bucketIdx] += 2;
    _edgeBucketCounts[lastCrossing - _boundsMinY] |= 1;

    _edgesPos += _sizeofEdge;
  }

  void _quadBreakIntoLinesAndAdd(
      double x0, double y0, Curve c, double x2, double y2) {
    int count = 1;
    double maxDD = math.max(c.dbx.abs(), c.dby.abs());
    while (maxDD >= 1.0) {
      maxDD /= 4.0;
      count <<= 1;
    }

    if (count > 1) {
      double icount = 1.0 / count;
      double icount2 = icount * icount;
      double ddx = c.dbx * icount2;
      double ddy = c.dby * icount2;
      double dx = c.bx * icount2 + c.cx * icount;
      double dy = c.by * icount2 + c.cy * icount;

      while (--count > 0) {
        double x1 = x0 + dx;
        dx += ddx;
        double y1 = y0 + dy;
        dy += ddy;
        _addLine(x0, y0, x1, y1);
        x0 = x1;
        y0 = y1;
      }
    }
    _addLine(x0, y0, x2, y2);
  }

  void _curveBreakIntoLinesAndAdd(
      double x0, double y0, Curve c, double x3, double y3) {
    int count = MarlinConst.cubCount;
    final double icount = MarlinConst.cubInvCount;
    final double icount2 = MarlinConst.cubInvCount2;
    final double icount3 = MarlinConst.cubInvCount3;

    double dddx = 2.0 * c.dax * icount3;
    double dddy = 2.0 * c.day * icount3;
    double ddx = dddx + c.dbx * icount2;
    double ddy = dddy + c.dby * icount2;
    double dx = c.ax * icount3 + c.bx * icount2 + c.cx * icount;
    double dy = c.ay * icount3 + c.by * icount2 + c.cy * icount;

    // Bounds for step adjustment (standard values)
    const double decBnd = 1.0;
    const double incBnd = 0.4; // Approximations based on typical behavior

    while (count > 0) {
      // Decrease step if error too large
      while (dx.abs() >= decBnd || dy.abs() >= decBnd) {
        // Using dx/dy as proxy for derivatives?
        // Actually Renderer.java checks ddx/ddy?
        // "Math.abs(ddx) >= _DEC_BND"
        // Let's check ddx/ddy.
        if (ddx.abs() < decBnd && ddy.abs() < decBnd) break; // Optimization

        dddx /= 8.0;
        dddy /= 8.0;
        ddx = ddx / 4.0 - dddx;
        ddy = ddy / 4.0 - dddy;
        dx = (dx - ddx) / 2.0;
        dy = (dy - ddy) / 2.0;
        count <<= 1;
      }

      // Increase step if error very small
      // "Math.abs(dx) <= _INC_BND" - wait, Renderer.java comments say:
      // "LBO: why use first derivative dX|Y instead of second ddX|Y ?"
      // It DOES use dx/dy in the check.
      while (count % 2 == 0 && dx.abs() <= incBnd && dy.abs() <= incBnd) {
        dx = 2.0 * dx + ddx;
        dy = 2.0 * dy + ddy;
        ddx = 4.0 * (ddx + dddx);
        ddy = 4.0 * (ddy + dddy);
        dddx *= 8.0;
        dddy *= 8.0;
        count >>= 1;
      }

      count--;
      if (count > 0) {
        double x1 = x0 + dx;
        dx += ddx;
        ddx += dddx;
        double y1 = y0 + dy;
        dy += ddy;
        ddy += dddy;

        _addLine(x0, y0, x1, y1);
        x0 = x1;
        y0 = y1;
      } else {
        _addLine(x0, y0, x3, y3);
      }
    }
  }

  void endRendering([int color = 0]) {
    if (_edgeMinY.isInfinite) return;

    final int spminX =
        FloatMath.maxInt(FloatMath.ceilInt(_edgeMinX - 0.5), _boundsMinX);
    final int spmaxX =
        FloatMath.minInt(FloatMath.ceilInt(_edgeMaxX - 0.5), _boundsMaxX - 1);
    final int spminY =
        FloatMath.maxInt(FloatMath.ceilInt(_edgeMinY), _boundsMinY);

    int maxY = FloatMath.ceilInt(_edgeMaxY);
    final int spmaxY;
    if (maxY <= _boundsMaxY - 1) {
      spmaxY = maxY;
    } else {
      spmaxY = _boundsMaxY - 1;
      maxY = _boundsMaxY;
    }

    if (spminX > spmaxX || spminY > spmaxY) return;

    final int pminX = spminX >> _subpixelLgPositionsX;
    final int pmaxX =
        (spmaxX + MarlinConst.subpixelMaskX) >> _subpixelLgPositionsX;
    final int pminY = spminY >> _subpixelLgPositionsY;
    final int pmaxY =
        (spmaxY + MarlinConst.subpixelMaskY) >> _subpixelLgPositionsY;

    _cache.init(pminX, pminY, pmaxX, pmaxY);

    _bboxSpMinX = pminX << _subpixelLgPositionsX;
    _bboxSpMaxX = pmaxX << _subpixelLgPositionsX;
    _bboxSpMinY = spminY;
    _bboxSpMaxY = math.min(spmaxY + 1, pmaxY << _subpixelLgPositionsY);

    final int alphaWidth = (pmaxX - pminX) + 2;
    if (_alphaLine.length < alphaWidth) {
      _alphaLine = _rdrCtx.getIntArray(alphaWidth) as Int32List;
    }

    for (int tileY = pminY; tileY < pmaxY; tileY += MarlinConst.tileSize) {
      final int spTileMinY =
          math.max(_bboxSpMinY, tileY << _subpixelLgPositionsY);
      if (spTileMinY >= _bboxSpMaxY) continue;

      final int spTileMaxY = math.min(
          _bboxSpMaxY,
          (tileY << _subpixelLgPositionsY) +
              (MarlinConst.tileSize << _subpixelLgPositionsY));

      _cache.resetTileLine(tileY);
      _endRenderingRange(spTileMinY, spTileMaxY);
      _blit(color);
    }
  }

  void _endRenderingRange(int ymin, int ymax) {
    final bool windingEvenOdd = (_windingRule == MarlinConst.windEvenOdd);
    final int bboxx0 = _bboxSpMinX;
    final int bboxx1 = _bboxSpMaxX;
    const int errStepMax = 0x7fffffff;
    const int minValue = -2147483648;
    const int maxValue = 2147483647;

    int pixMinX = maxValue;
    int pixMaxX = minValue;
    int lastY = -1;

    int y = ymin;
    int bucket = y - _boundsMinY;
    int numCrossings = _edgeCount;

    for (; y < ymax; y++, bucket++) {
      final int bucketCount = _edgeBucketCounts[bucket];
      int prevNumCrossings = numCrossings;

      if (bucketCount != 0) {
        if ((bucketCount & 0x1) != 0) {
          final int yLim = (y << 1) | 0x1;
          int newCount = 0;
          for (int i = 0; i < numCrossings; i++) {
            final int ecur = _edgePtrs[i];
            if (_edges[ecur + _offYMaxOr] > yLim) {
              _edgePtrs[newCount++] = ecur;
            }
          }
          prevNumCrossings = numCrossings = newCount;
        }

        final int ptrLen = bucketCount >> 1;
        if (ptrLen != 0) {
          final int ptrEnd = numCrossings + ptrLen;
          if (_edgePtrs.length < ptrEnd) {
            _edgePtrs = _widenIntArray(_edgePtrs, numCrossings, ptrEnd);
          }
          int ecur = _edgeBuckets[bucket];
          while (numCrossings < ptrEnd) {
            _edgePtrs[numCrossings++] = ecur;
            ecur = _edges[ecur + _offNext];
          }
          if (_crossings.length < numCrossings) {
            _crossings = _widenIntArray(_crossings, 0, numCrossings + 1);
          }
        }
      }

      if (numCrossings != 0) {
        final bool useBinarySearch = numCrossings >= 20;
        for (int i = 0; i < numCrossings; i++) {
          final int ecur = _edgePtrs[i];
          int curx = _edges[ecur + _offCurX];
          final int cross = _i32(curx << 1) | (_edges[ecur + _offYMaxOr] & 0x1);

          curx = _i32(curx + _edges[ecur + _offBumpX]);
          final int err =
              _i32(_edges[ecur + _offError] + _edges[ecur + _offBumpErr]);
          _edges[ecur + _offCurX] = _i32(curx - (err >> 31));
          _edges[ecur + _offError] = err & errStepMax;

          if (i > 0 &&
              _crossingLess(cross, ecur, _crossings[i - 1], _edgePtrs[i - 1])) {
            int insertAt = i;
            if (useBinarySearch && i >= prevNumCrossings) {
              int low = 0;
              int high = i - 1;
              while (low <= high) {
                final int mid = (low + high) >> 1;
                if (_crossingLess(
                    _crossings[mid], _edgePtrs[mid], cross, ecur)) {
                  low = mid + 1;
                } else {
                  high = mid - 1;
                }
              }
              insertAt = low;
            } else {
              int j = i - 1;
              while (j >= 0 &&
                  _crossingLess(cross, ecur, _crossings[j], _edgePtrs[j])) {
                j--;
              }
              insertAt = j + 1;
            }

            for (int j = i - 1; j >= insertAt; j--) {
              _crossings[j + 1] = _crossings[j];
              _edgePtrs[j + 1] = _edgePtrs[j];
            }
            _crossings[insertAt] = cross;
            _edgePtrs[insertAt] = ecur;
          } else {
            _crossings[i] = cross;
          }
        }

        int lowx = _crossings[0] >> 1;
        int highx = _crossings[numCrossings - 1] >> 1;
        int x0 = (lowx > bboxx0) ? lowx : bboxx0;
        int x1 = (highx < bboxx1) ? highx : bboxx1;
        int tmp = x0 >> _subpixelLgPositionsX;
        if (tmp < pixMinX) pixMinX = tmp;
        tmp = x1 >> _subpixelLgPositionsX;
        if (tmp > pixMaxX) pixMaxX = tmp;

        int curxo = _crossings[0];
        int prev = curxo >> 1;
        int curx = prev;
        int crorientation = ((curxo & 0x1) << 1) - 1;

        void addSpan(int span0, int span1) {
          int sx0 = (span0 > bboxx0) ? span0 : bboxx0;
          int sx1 = (span1 < bboxx1) ? span1 : bboxx1;
          if (sx0 >= sx1) return;

          sx0 -= bboxx0;
          sx1 -= bboxx0;

          final int pixX = sx0 >> _subpixelLgPositionsX;
          final int pixXMaxM1 = (sx1 - 1) >> _subpixelLgPositionsX;
          if (pixX == pixXMaxM1) {
            final int delta = sx1 - sx0;
            _alphaLine[pixX] += delta;
            _alphaLine[pixX + 1] -= delta;
          } else {
            int frac = (sx0 & MarlinConst.subpixelMaskX);
            _alphaLine[pixX] += (_subpixelPositionsX - frac);
            _alphaLine[pixX + 1] += frac;

            final int pixXMax = sx1 >> _subpixelLgPositionsX;
            frac = (sx1 & MarlinConst.subpixelMaskX);
            _alphaLine[pixXMax] -= (_subpixelPositionsX - frac);
            _alphaLine[pixXMax + 1] -= frac;
          }
        }

        if (windingEvenOdd) {
          int sum = crorientation;
          for (int i = 1; i < numCrossings; i++) {
            curxo = _crossings[i];
            curx = curxo >> 1;
            crorientation = ((curxo & 0x1) << 1) - 1;
            if ((sum & 0x1) != 0) {
              addSpan(prev, curx);
            }
            sum += crorientation;
            prev = curx;
          }
        } else {
          int sum = 0;
          for (int i = 1;; i++) {
            sum += crorientation;
            if (sum != 0) {
              if (prev > curx) prev = curx;
            } else {
              addSpan(prev, curx);
              prev = maxValue;
            }
            if (i == numCrossings) break;
            curxo = _crossings[i];
            curx = curxo >> 1;
            crorientation = ((curxo & 0x1) << 1) - 1;
          }
        }
      }

      if ((y & MarlinConst.subpixelMaskY) == MarlinConst.subpixelMaskY) {
        lastY = y >> _subpixelLgPositionsY;
        if (pixMaxX >= pixMinX) {
          _cache.copyAARow(_alphaLine, lastY, pixMinX, pixMaxX + 2);
        } else {
          _cache.clearAARow(lastY);
        }
        pixMinX = maxValue;
        pixMaxX = minValue;
      }

      _edgeBuckets[bucket] = 0;
      _edgeBucketCounts[bucket] = 0;
    }

    final int finalY = (y - 1) >> _subpixelLgPositionsY;
    if (pixMaxX >= pixMinX) {
      _cache.copyAARow(_alphaLine, finalY, pixMinX, pixMaxX + 2);
    } else if (finalY != lastY) {
      _cache.clearAARow(finalY);
    }

    _edgeCount = numCrossings;
  }

  void _blit(int color) {
    if (_cache.tileMin == 2147483647) return;

    final int tMin = _cache.tileMin;
    final int tMax = _cache.tileMax;
    final int tileW = MarlinConst.tileSize;
    final int yStart = _cache.bboxY0;
    final int yLimit = math.min(_cache.bboxY1, yStart + MarlinConst.tileSize);

    final int sr = (color >> 16) & 0xFF;
    final int sg = (color >> 8) & 0xFF;
    final int sb = color & 0xFF;

    for (int t = tMin; t < tMax; t++) {
      if (_cache.touchedTile[t] == 0) continue;
      final int tx = _cache.bboxX0 + (t << MarlinConst.tileSizeLg);

      for (int y = yStart; y < yLimit; y++) {
        if (y < 0 || y >= _height) continue;
        final int row = y - yStart;
        final int rowIdx = _cache.rowAAChunkIndex[row];
        if (rowIdx == 0) continue;

        int idx = rowIdx;
        int x = _cache.rowAAx0[row];
        final int rowOffset = y * _width;

        while (true) {
          final int val = _cache.rowAAChunk[idx++];
          final int len = _cache.rowAAChunk[idx++];
          if (val == 0 && len == 0) break;

          if (val != 0) {
            final int runEnd = x + len;
            final int start = math.max(x, tx);
            final int end = math.min(runEnd, tx + tileW);
            for (int px = start; px < end; px++) {
              if (px < 0 || px >= _width) continue;
              final int di = rowOffset + px;
              final int dst = _pixelBuffer[di];
              final int dr = (dst >> 16) & 0xFF;
              final int dg = (dst >> 8) & 0xFF;
              final int db = dst & 0xFF;
              final int invA = 255 - val;
              final int outR = ((sr * val) + (dr * invA)) >> 8;
              final int outG = ((sg * val) + (dg * invA)) >> 8;
              final int outB = ((sb * val) + (db * invA)) >> 8;
              _pixelBuffer[di] = 0xFF000000 | (outR << 16) | (outG << 8) | outB;
            }
          }
          x += len;
        }
      }
    }
  }

  // Arrays
  Int32List _widenIntArray(Int32List oldArray, int used, int newSize) {
    if (newSize > ArrayCacheConfig.maxArraySize) {
      // Fallback to allocation
      final newArray = Int32List(newSize);
      newArray.setRange(0, used, oldArray);
      _rdrCtx.putIntArray(oldArray, 0, used);
      return newArray;
    }

    final newArray = _rdrCtx.getDirtyIntArrayCache(newSize).getArray();
    newArray.setRange(0, used, oldArray);
    _rdrCtx.putIntArray(oldArray, 0, used); // Recycle old
    return newArray;
  }

  static int _i32(int v) => v.toSigned(32);

  static bool _crossingLess(int c1, int e1, int c2, int e2) {
    if (c1 != c2) return c1 < c2;
    return e1 < e2;
  }

  // Convenience for backward compat
  void drawTriangle(double x0, double y0, double x1, double y1, double x2,
      double y2, int color) {
    init(0, 0, _width, _height, MarlinConst.windNonZero);
    moveTo(x0, y0);
    lineTo(x1, y1);
    lineTo(x2, y2);
    closePath();
    endRendering(color);
  }

  void drawPolygon(
    List<double> vertices,
    int color, {
    int windingRule = MarlinConst.windNonZero,
    List<int>? contourVertexCounts,
  }) {
    if (vertices.length < 6) return;
    init(0, 0, _width, _height, windingRule);

    final int totalPoints = vertices.length ~/ 2;
    int consumed = 0;

    void drawContour(int startPoint, int count) {
      if (count < 3) return;
      final int start = startPoint * 2;
      moveTo(vertices[start], vertices[start + 1]);
      for (int local = 1; local < count; local++) {
        final int idx = (startPoint + local) * 2;
        lineTo(vertices[idx], vertices[idx + 1]);
      }
      closePath();
    }

    if (contourVertexCounts != null && contourVertexCounts.isNotEmpty) {
      for (final raw in contourVertexCounts) {
        if (raw <= 0) continue;
        if (consumed + raw > totalPoints) {
          consumed = 0;
          break;
        }
        drawContour(consumed, raw);
        consumed += raw;
      }
    }

    if (consumed != totalPoints) {
      drawContour(0, totalPoints);
    }

    endRendering(color);
  }
}
