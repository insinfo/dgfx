// Fixed-point math constants
// SLEFA uses FloatToFixed logic. Assuming 24.8 fixed point for coordinates inside scanline?
// Or maybe higher precision for the DDA.
// SubPolygon.h mentiones FIXED_POINT_SHIFT which is likely 8 or 16.

const int fixedPointShift =
    12; // 12 bits for fraction is usually good for rasterization
const int fixedPointScale = 1 << fixedPointShift;
const int fixedPointMask = fixedPointScale - 1;

@pragma('vm:prefer-inline')
int floatToFixed(double val) {
  return (val * fixedPointScale).floor();
}

@pragma('vm:prefer-inline')
int intToFixed(int val) {
  return val << fixedPointShift;
}

@pragma('vm:prefer-inline')
double fixedToFloat(int val) {
  return val / fixedPointScale;
}

@pragma('vm:prefer-inline')
int fixedFloor(int val) {
  return val >> fixedPointShift;
}

@pragma('vm:prefer-inline')
int fixedCeil(int val) {
  return (val + fixedPointMask) >> fixedPointShift;
}

@pragma('vm:prefer-inline')
int fixedFraction(int val) {
  return val & fixedPointMask;
}
