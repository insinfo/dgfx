/// Port of Blend2D pixelops/scalar_p.h — scalar pixel utilities.
///
/// Provides premultiply/unpremultiply, integer division by 255 with correct
/// rounding, and pixel format conversion helpers.
///
/// All operations work on ARGB32 (0xAARRGGBB) in premultiplied alpha space
/// unless noted otherwise.
library;

import 'dart:math' as math;

// ---------------------------------------------------------------------------
// Scalar pixel utilities (port of bl::PixelOps::Scalar)
// ---------------------------------------------------------------------------

/// Integer division by 255 with correct rounding semantics.
/// Equivalent to C++ `((x + 128) * 257) >> 16`.
int udiv255(int x) => ((x + 0x80) * 0x101) >>> 16;

/// Negate in 255 space: `255 - x`.
int neg255(int x) => x ^ 0xFF;

/// Clamp to `0..255`.
int clamp255(int x) => x < 0 ? 0 : (x > 255 ? 255 : x);

/// Saturating add of two bytes (clamp to 255).
int addus8(int a, int b) {
  final s = a + b;
  return s > 255 ? 255 : s;
}

// ---------------------------------------------------------------------------
// Premultiply / Unpremultiply (port of scalar_p.h cvt_prgb32/cvt_argb32)
// ---------------------------------------------------------------------------

/// Convert ARGB32 (straight alpha) to premultiplied ARGB32 (PRGB32).
///
/// Port of `cvt_prgb32_8888_from_argb32_8888(uint32_t val32)`.
int premultiply(int argb) {
  final a = (argb >>> 24) & 0xFF;
  if (a == 255) return argb;
  if (a == 0) return 0;

  // C++ sets alpha to 0xFF before the packed multiply so that
  // the output alpha byte equals the original alpha, not a*a/255.
  // val32 |= 0xFF000000u;
  final int val32 = argb | 0xFF000000;

  final int rb = val32 & 0x00FF00FF;
  final int ag = (val32 >>> 8) & 0x00FF00FF;

  int rbm = (rb * a) + 0x00800080;
  int agm = (ag * a) + 0x00800080;

  rbm = (rbm + ((rbm >>> 8) & 0x00FF00FF)) & 0xFF00FF00;
  agm = (agm + ((agm >>> 8) & 0x00FF00FF)) & 0xFF00FF00;

  return agm | (rbm >>> 8);
}

/// Reciprocal table for unpremultiply: (255 * 65536 + a/2) / a, for a in `0..255`.
/// Index 0 is 0 (special case: fully transparent).
final List<int> _unpremultiplyRcp = List<int>.generate(256, (a) {
  if (a == 0) return 0;
  return ((255 * 65536) + (a ~/ 2)) ~/ a;
}, growable: false);

/// Convert premultiplied ARGB32 (PRGB32) to straight alpha ARGB32.
///
/// Port of `cvt_argb32_8888_from_prgb32_8888(uint32_t val32)`.
int unpremultiply(int prgb) {
  final a = (prgb >>> 24) & 0xFF;
  if (a == 255 || a == 0) return prgb;

  final recip = _unpremultiplyRcp[a];
  final r = clamp255((((prgb >>> 16) & 0xFF) * recip + 0x8000) >>> 16);
  final g = clamp255((((prgb >>> 8) & 0xFF) * recip + 0x8000) >>> 16);
  final b = clamp255(((prgb & 0xFF) * recip + 0x8000) >>> 16);

  return (a << 24) | (r << 16) | (g << 8) | b;
}

// ---------------------------------------------------------------------------
// Channel extraction helpers
// ---------------------------------------------------------------------------

/// Extract alpha channel `0..255`.
int alphaOf(int argb) => (argb >>> 24) & 0xFF;

/// Extract red channel `0..255`.
int redOf(int argb) => (argb >>> 16) & 0xFF;

/// Extract green channel `0..255`.
int greenOf(int argb) => (argb >>> 8) & 0xFF;

/// Extract blue channel `0..255`.
int blueOf(int argb) => argb & 0xFF;

/// Pack ARGB channels into a single int.
int packArgb(int a, int r, int g, int b) =>
    ((a & 0xFF) << 24) | ((r & 0xFF) << 16) | ((g & 0xFF) << 8) | (b & 0xFF);

// ---------------------------------------------------------------------------
// Swizzle (byte‐order conversion)
// ---------------------------------------------------------------------------

/// ARGB to ABGR (swap R and B channels).
int swizzleArgbToAbgr(int argb) {
  final a = (argb >>> 24) & 0xFF;
  final r = (argb >>> 16) & 0xFF;
  final g = (argb >>> 8) & 0xFF;
  final b = argb & 0xFF;
  return (a << 24) | (b << 16) | (g << 8) | r;
}

/// ARGB to RGBA.
int swizzleArgbToRgba(int argb) {
  final a = (argb >>> 24) & 0xFF;
  final r = (argb >>> 16) & 0xFF;
  final g = (argb >>> 8) & 0xFF;
  final b = argb & 0xFF;
  return (r << 24) | (g << 16) | (b << 8) | a;
}

/// RGBA to ARGB.
int swizzleRgbaToArgb(int rgba) {
  final r = (rgba >>> 24) & 0xFF;
  final g = (rgba >>> 16) & 0xFF;
  final b = (rgba >>> 8) & 0xFF;
  final a = rgba & 0xFF;
  return (a << 24) | (r << 16) | (g << 8) | b;
}

// ---------------------------------------------------------------------------
// Linear <-> sRGB (for soft-light and future color-space-aware ops)
// ---------------------------------------------------------------------------

/// Approximate sRGB to linear conversion for a single channel `0..255` → `0.0..1.0`.
double srgbToLinear(int c) {
  final s = c / 255.0;
  return s <= 0.04045
      ? s / 12.92
      : math.pow((s + 0.055) / 1.055, 2.4).toDouble();
}

/// Approximate linear to sRGB conversion `0.0..1.0` → `0..255`.
int linearToSrgb(double l) {
  final s = l <= 0.0031308 ? l * 12.92 : 1.055 * math.pow(l, 1.0 / 2.4) - 0.055;
  return clamp255((s * 255.0 + 0.5).toInt());
}
