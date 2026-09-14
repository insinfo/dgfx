import 'dart:typed_data';

abstract class ScanlineBuffer {
  int get width;
  void clear();
  void toggle(int x, int sampleIndex); // For Even-Odd
  void add(int x, int sampleIndex, int delta); // For Non-Zero

  // Converts the buffer content to alpha values (0-255) into the target buffer.
  void resolveToAlpha(Uint8List target);
}

// ----------------------------------------------------------------------
// EVEN-ODD IMPLEMENTATIONS
// ----------------------------------------------------------------------

// Optimized for 8 samples Even-Odd
class ScanlineBufferEvenOdd8 implements ScanlineBuffer {
  final int _width;
  final Uint8List _buffer;

  ScanlineBufferEvenOdd8(this._width) : _buffer = Uint8List(_width);

  @override
  int get width => _width;

  @override
  @pragma('vm:prefer-inline')
  void clear() {
    _buffer.fillRange(0, _width, 0);
  }

  @override
  @pragma('vm:prefer-inline')
  void toggle(int x, int sampleIndex) {
    if (x >= 0 && x < _width) {
      _buffer[x] ^= (1 << sampleIndex);
    }
  }

  @override
  void add(int x, int sampleIndex, int delta) {
    throw UnsupportedError("Use ScanlineBufferNonZero for winding rules");
  }

  static const List<int> _popcount8 = [
    0,
    1,
    1,
    2,
    1,
    2,
    2,
    3,
    1,
    2,
    2,
    3,
    2,
    3,
    3,
    4,
    1,
    2,
    2,
    3,
    2,
    3,
    3,
    4,
    2,
    3,
    3,
    4,
    3,
    4,
    4,
    5,
    1,
    2,
    2,
    3,
    2,
    3,
    3,
    4,
    2,
    3,
    3,
    4,
    3,
    4,
    4,
    5,
    2,
    3,
    3,
    4,
    3,
    4,
    4,
    5,
    3,
    4,
    4,
    5,
    4,
    5,
    5,
    6,
    1,
    2,
    2,
    3,
    2,
    3,
    3,
    4,
    2,
    3,
    3,
    4,
    3,
    4,
    4,
    5,
    2,
    3,
    3,
    4,
    3,
    4,
    4,
    5,
    3,
    4,
    4,
    5,
    4,
    5,
    5,
    6,
    2,
    3,
    3,
    4,
    3,
    4,
    4,
    5,
    3,
    4,
    4,
    5,
    4,
    5,
    5,
    6,
    3,
    4,
    4,
    5,
    4,
    5,
    5,
    6,
    4,
    5,
    5,
    6,
    5,
    6,
    6,
    7,
    1,
    2,
    2,
    3,
    2,
    3,
    3,
    4,
    2,
    3,
    3,
    4,
    3,
    4,
    4,
    5,
    2,
    3,
    3,
    4,
    3,
    4,
    4,
    5,
    3,
    4,
    4,
    5,
    4,
    5,
    5,
    6,
    2,
    3,
    3,
    4,
    3,
    4,
    4,
    5,
    3,
    4,
    4,
    5,
    4,
    5,
    5,
    6,
    3,
    4,
    4,
    5,
    4,
    5,
    5,
    6,
    4,
    5,
    5,
    6,
    5,
    6,
    6,
    7,
    2,
    3,
    3,
    4,
    3,
    4,
    4,
    5,
    3,
    4,
    4,
    5,
    4,
    5,
    5,
    6,
    3,
    4,
    4,
    5,
    4,
    5,
    5,
    6,
    4,
    5,
    5,
    6,
    5,
    6,
    6,
    7,
    3,
    4,
    4,
    5,
    4,
    5,
    5,
    6,
    4,
    5,
    5,
    6,
    5,
    6,
    6,
    7,
    4,
    5,
    5,
    6,
    5,
    6,
    6,
    7,
    5,
    6,
    6,
    7,
    6,
    7,
    7,
    8
  ];

  @override
  @pragma('vm:prefer-inline')
  void resolveToAlpha(Uint8List target) {
    int mask = 0;
    for (int i = 0; i < _width; i++) {
      mask ^= _buffer[i];

      if (mask == 0) {
        target[i] = 0;
      } else if (mask == 0xFF) {
        target[i] = 255;
      } else {
        // Approximation:
        // 255/8 = 31.875 ~ 32
        // Better: (count * 255) >> 3
        int count = _popcount8[mask];
        target[i] = (count * 255) >> 3;
      }
    }
  }
}

// Optimized for 16 samples Even-Odd
class ScanlineBufferEvenOdd16 implements ScanlineBuffer {
  final int _width;
  final Uint16List _buffer;

  ScanlineBufferEvenOdd16(this._width) : _buffer = Uint16List(_width);

  @override
  int get width => _width;

  @override
  @pragma('vm:prefer-inline')
  void clear() {
    _buffer.fillRange(0, _width, 0);
  }

  @override
  @pragma('vm:prefer-inline')
  void toggle(int x, int sampleIndex) {
    if (x >= 0 && x < _width) {
      _buffer[x] ^= (1 << sampleIndex);
    }
  }

  @override
  void add(int x, int sampleIndex, int delta) {
    throw UnsupportedError("Use ScanlineBufferNonZero for winding rules");
  }

  @override
  @pragma('vm:prefer-inline')
  void resolveToAlpha(Uint8List target) {
    int mask = 0;
    for (int i = 0; i < _width; i++) {
      mask ^= _buffer[i];

      if (mask == 0) {
        target[i] = 0;
      } else if (mask == 0xFFFF) {
        target[i] = 255;
      } else {
        // Count bits
        int count = 0;
        int m = mask;
        while (m != 0) {
          m &= (m - 1);
          count++;
        }
        // 255 / 16 = 15.9375
        // (count * 255) >> 4
        target[i] = (count * 255) >> 4;
      }
    }
  }
}

// Optimized for 32 samples Even-Odd
class ScanlineBufferEvenOdd32 implements ScanlineBuffer {
  final int _width;
  final Uint32List _buffer;

  ScanlineBufferEvenOdd32(this._width) : _buffer = Uint32List(_width);

  @override
  int get width => _width;

  @override
  @pragma('vm:prefer-inline')
  void clear() {
    _buffer.fillRange(0, _width, 0);
  }

  @override
  @pragma('vm:prefer-inline')
  void toggle(int x, int sampleIndex) {
    if (x >= 0 && x < _width) {
      _buffer[x] ^= (1 << sampleIndex);
    }
  }

  @override
  void add(int x, int sampleIndex, int delta) {
    throw UnsupportedError("Use ScanlineBufferNonZero for winding rules");
  }

  @override
  @pragma('vm:prefer-inline')
  void resolveToAlpha(Uint8List target) {
    int mask = 0;
    for (int i = 0; i < _width; i++) {
      mask ^= _buffer[i];

      if (mask == 0) {
        target[i] = 0;
      } else if (mask == 0xFFFFFFFF) {
        target[i] = 255;
      } else {
        int count = 0;
        int m = mask;
        // Kernighen's method is good for sparse bits, but for general mask maybe not optimal.
        // Dart doesn't have native popcount.
        // Use parallel bit count?
        m = m - ((m >> 1) & 0x55555555);
        m = (m & 0x33333333) + ((m >> 2) & 0x33333333);
        m = (m + (m >> 4)) & 0x0F0F0F0F;
        m = m + (m >> 8);
        m = m + (m >> 16);
        count = m & 0x3F;

        // 255 / 32 = 7.96875
        // (count * 255) >> 5
        target[i] = (count * 255) >> 5;
      }
    }
  }
}

// ----------------------------------------------------------------------
// NON-ZERO IMPLEMENTATIONS
// ----------------------------------------------------------------------

// Optimized for 8 samples Non-Zero Winding
class ScanlineBufferNonZero8 implements ScanlineBuffer {
  final int _width;
  final Uint64List _buffer;

  ScanlineBufferNonZero8(this._width) : _buffer = Uint64List(_width);

  @override
  int get width => _width;

  @override
  @pragma('vm:prefer-inline')
  void clear() {
    _buffer.fillRange(0, _width, 0);
  }

  @override
  void toggle(int x, int sampleIndex) {
    throw UnsupportedError("Use ScanlineBufferEvenOdd for toggle/xor");
  }

  @override
  @pragma('vm:prefer-inline')
  void add(int x, int sampleIndex, int delta) {
    if (x >= 0 && x < _width) {
      // 8 bits per sample.
      int shift = sampleIndex << 3; // * 8
      // Dart ints are 64-bit.
      if (delta > 0) {
        _buffer[x] += (1 << shift);
      } else {
        _buffer[x] -= (1 << shift);
      }
    }
  }

  @override
  @pragma('vm:prefer-inline')
  void resolveToAlpha(Uint8List target) {
    int accum = 0;

    for (int i = 0; i < _width; i++) {
      accum += _buffer[i];

      if (accum == 0) {
        target[i] = 0;
      } else {
        int count = 0;
        if ((accum & 0xFF) != 0) count++;
        if ((accum & 0xFF00) != 0) count++;
        if ((accum & 0xFF0000) != 0) count++;
        if ((accum & 0xFF000000) != 0) count++;
        if ((accum & 0xFF00000000) != 0) count++;
        if ((accum & 0xFF0000000000) != 0) count++;
        if ((accum & 0xFF000000000000) != 0) count++;
        if ((accum & 0xFF00000000000000) != 0) count++;

        target[i] = (count * 255) >> 3;
      }
    }
  }
}

// Generic Non-Zero for N samples
// Uses linear array of byte counters.
// Optimized for layout: [pixel0_s0, pixel0_s1, ... pixel1_s0, ...]
// Or [pixel0_s0...sN, pixel1_s0...sN]
class ScanlineBufferNonZeroGeneric implements ScanlineBuffer {
  final int _width;
  final int _samples;
  final Int8List _buffer;

  ScanlineBufferNonZeroGeneric(this._width, this._samples)
      : _buffer = Int8List(_width * _samples);

  @override
  int get width => _width;

  @override
  @pragma('vm:prefer-inline')
  void clear() {
    _buffer.fillRange(0, _buffer.length, 0);
  }

  @override
  void toggle(int x, int sampleIndex) {
    throw UnsupportedError("Use ScanlineBufferEvenOdd for toggle/xor");
  }

  @override
  @pragma('vm:prefer-inline')
  void add(int x, int sampleIndex, int delta) {
    if (x >= 0 && x < _width) {
      // Index = x * samples + sampleIndex
      // With fixed samples, we can optimize shift logic, but this is generic.
      int index = x * _samples + sampleIndex;
      _buffer[index] += delta;
    }
  }

  @override
  @pragma('vm:prefer-inline')
  void resolveToAlpha(Uint8List target) {
    // We need to maintain running sum for EACH sample index.
    // Unlike EdgeFlag bitwise where we XOR bits, Non-Zero maintains winding count.
    // Wait. The algorithm says: "The fill routine then accumulates the values from the canvas to a temporary variable"
    // Yes, we accumulate horizontally.
    // But we have N accumulators, one for each sample line.

    // Create N accumulators
    // Since N is small (16/32), we can keep them in a list or registers.
    // For 16/32, registers is too much for Dart vm optimization maybe?
    // Using Int32List for accumulators.

    Int32List accums = Int32List(_samples);
    // clear is implicit 0

    int ptr = 0;
    for (int i = 0; i < _width; i++) {
      int activeSamples = 0;

      for (int s = 0; s < _samples; s++) {
        accums[s] += _buffer[ptr++];
        if (accums[s] != 0) {
          activeSamples++;
        }
      }

      if (activeSamples == 0) {
        target[i] = 0;
      } else if (activeSamples == _samples) {
        target[i] = 255;
      } else {
        // (count * 255) ~/ samples
        if (_samples == 16)
          target[i] = (activeSamples * 255) >> 4;
        else if (_samples == 32)
          target[i] = (activeSamples * 255) >> 5;
        else
          target[i] = (activeSamples * 255) ~/ _samples;
      }
    }
  }
}
