import 'dart:typed_data';
import 'common.dart';
import 'edge.dart';
import 'edge_table.dart';
import 'patterns.dart';
import 'scanline_buffer.dart';

enum FillRule {
  evenOdd,
  nonZero,
}

class ScanlineEdgeFlagRasterizer {
  final int width;
  final int height;
  final int subpixelCount;
  final int subpixelShift;

  // Buffers
  late final ScanlineBuffer bufferEvenOdd;
  late final ScanlineBuffer bufferNonZero;

  // Cache for Active Edge Table
  Edge? activeEdges;

  List<int>? _offsets;

  ScanlineEdgeFlagRasterizer(this.width, this.height, {int samples = 8})
      : subpixelCount = samples,
        subpixelShift = (samples == 32) ? 5 : (samples == 16 ? 4 : 3) {
    if (samples == 8) {
      bufferEvenOdd = ScanlineBufferEvenOdd8(width);
      bufferNonZero = ScanlineBufferNonZero8(width);
      _initOffsets(SamplingPatterns.offsets8);
    } else if (samples == 16) {
      bufferEvenOdd = ScanlineBufferEvenOdd16(width);
      bufferNonZero = ScanlineBufferNonZeroGeneric(width, 16);
      _initOffsets(SamplingPatterns.offsets16);
    } else if (samples == 32) {
      bufferEvenOdd = ScanlineBufferEvenOdd32(width);
      bufferNonZero = ScanlineBufferNonZeroGeneric(width, 32);
      _initOffsets(SamplingPatterns.offsets32);
    } else {
      throw ArgumentError("Samples must be 8, 16, or 32");
    }
  }

  void _initOffsets(List<double> doubleOffsets) {
    _offsets = doubleOffsets.map((d) => floatToFixed(d)).toList();
  }

  // Output buffer (alpha)
  Uint8List? _outputBuffer;
  Uint8List get outputBuffer {
    _outputBuffer ??= Uint8List(width * height);
    return _outputBuffer!;
  }

  void rasterize(List<double> vertices, FillRule rule,
      {Uint8List? outputBuffer}) {
    if (outputBuffer != null) {
      if (outputBuffer.length != width * height) {
        throw ArgumentError('outputBuffer must be size width*height');
      }
      _outputBuffer = outputBuffer;
    }

    if (_outputBuffer == null)
      _outputBuffer = Uint8List(width * height);
    else if (outputBuffer == null)
      _outputBuffer!.fillRange(0, _outputBuffer!.length,
          0); // Clear if internal or reused without explicit clear

    if (outputBuffer != null) {
      // If external buffer provided, we assume caller handles clearing if they want,
      // but typically rasterizers clear.
      // The benchmark passes 'out' which is cleared inside the other raster functions (`_clear(out)`).
      // So I should adhere to that or clear it myself.
      // The other functions call `_clear(out)`.
      // So I should probably not clear it if the benchmark clears it?
      // Wait, `rasterCellsPrefix` calls `_clear(out)`.
      // `rasterScanlineAnalytic` calls `_clear(out)`.
      // So I should clear it.
      _outputBuffer!.fillRange(0, _outputBuffer!.length, 0);
    }

    EdgeTable et = EdgeTable(0, height);

    _buildEdgeTable(et, vertices, subpixelShift, subpixelCount);

    // 2. Process Scanlines
    ScanlineBuffer scanlineBuffer =
        (rule == FillRule.evenOdd) ? bufferEvenOdd : bufferNonZero;

    activeEdges = null;

    for (int y = 0; y < height; y++) {
      scanlineBuffer.clear();

      Edge? newEdges = et.getEdgesForScanline(y);
      if (newEdges != null) {
        _insertActiveEdges(newEdges);
      }

      if (activeEdges != null) {
        _plotActiveEdges(y, subpixelCount, scanlineBuffer);
        _updateActiveEdges(y, subpixelCount);
      }

      var bufferView = Uint8List.view(_outputBuffer!.buffer, y * width, width);
      scanlineBuffer.resolveToAlpha(bufferView);
    }
  }

  void _buildEdgeTable(
      EdgeTable et, List<double> vertices, int subShift, int subCount) {
    int count = vertices.length ~/ 2;
    if (count < 3) return;

    double prevX = vertices[(count - 1) * 2];
    double prevY = vertices[(count - 1) * 2 + 1];

    for (int i = 0; i < count; i++) {
      double currX = vertices[i * 2];
      double currY = vertices[i * 2 + 1];

      _addEdge(et, prevX, prevY, currX, currY, subShift, subCount);

      prevX = currX;
      prevY = currY;
    }
  }

  void _addEdge(EdgeTable et, double x0, double y0, double x1, double y1,
      int subShift, int subCount) {
    // Scale Y by subpixel count
    double sy0 = y0 * subCount;
    double sy1 = y1 * subCount;

    int iy0 = sy0.floor();
    int iy1 = sy1.floor();

    if (iy0 == iy1) return;

    double sx0 = x0;
    double sx1 = x1;

    int dir = 1;
    if (iy0 > iy1) {
      int t = iy0;
      iy0 = iy1;
      iy1 = t;
      double td = sx0;
      sx0 = sx1;
      sx1 = td;
      double tyd = sy0;
      sy0 = sy1;
      sy1 = tyd;
      dir = -1;
    }

    double dx = (sx1 - sx0) / (sy1 - sy0);

    int scanlineStart = iy0 >> subShift;

    int fixedX = floatToFixed(sx0);
    int fixedSlope = floatToFixed(dx);

    Edge edge = Edge(
      yStart: iy0,
      yEnd: iy1,
      x: fixedX,
      slope: fixedSlope,
      dir: dir,
    );

    if (scanlineStart < et.buckets.length) {
      // Handle linking
      Edge? existing = et.buckets[scanlineStart];
      edge.next = existing;
      et.buckets[scanlineStart] = edge;
    }
  }

  void _insertActiveEdges(Edge edgeList) {
    Edge? curr = edgeList;
    while (curr != null) {
      Edge? next = curr.next;
      curr.next = activeEdges;
      activeEdges = curr;
      curr = next;
    }
  }

  void _plotActiveEdges(int y, int subCount, ScanlineBuffer buffer) {
    Edge? curr = activeEdges;

    int scanlineBase = y << subpixelShift;
    List<int> fixedOffsets = _offsets!;

    while (curr != null) {
      int startSub = curr.yStart - scanlineBase;
      if (startSub < 0) startSub = 0;

      int endSub = curr.yEnd - scanlineBase;
      if (endSub > subCount) endSub = subCount;

      if (startSub < endSub) {
        for (int s = startSub; s < endSub; s++) {
          int px = (curr.x + fixedOffsets[s]) >> fixedPointShift;

          // Polymorphic dispatch? Or if check.
          // Buffer is interface.
          // toggle/add are virtual.
          // For EvenOdd/NonZero specific buffers, maybe we can inline?
          // But loop is hot.
          // Interface call in Dart is reasonably fast (inline cache).

          if (ruleIsEvenOdd(buffer)) {
            buffer.toggle(px, s);
          } else {
            buffer.add(px, s, curr.dir);
          }

          curr.x += curr.slope;
        }
      }

      curr = curr.next;
    }
  }

  bool ruleIsEvenOdd(ScanlineBuffer b) {
    return b == bufferEvenOdd;
  }

  void _updateActiveEdges(int y, int subCount) {
    int nextScanlineStart = (y + 1) << subpixelShift;

    Edge? prev = null;
    Edge? curr = activeEdges;

    while (curr != null) {
      if (curr.yEnd <= nextScanlineStart) {
        if (prev == null) {
          activeEdges = curr.next;
        } else {
          prev.next = curr.next;
        }
      } else {
        prev = curr;
      }
      curr = curr.next;
    }
  }
}
