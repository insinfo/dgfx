// Draws a scene with a fill, a gradient, a stroke and a clip, and prints an
// ASCII preview. It deliberately avoids `dart:io`: the same file runs on
// native, web and wasm.
import 'package:dgfx/dgfx.dart';

Future<void> main() async {
  const size = 240;
  final image = BLImage(size, size);
  final ctx = BLContext(image)..clear(0xFFFFFFFF);

  // 1. Uma forma curva preenchida com gradiente linear.
  final blob = BLPath()
    ..moveTo(30, 40)
    ..cubicTo(210, 10, 30, 190, 200, 170)
    ..lineTo(120, 120)
    ..close();

  ctx
    ..setFillRule(BLFillRule.nonZero)
    ..setLinearGradient(BLLinearGradient(
      p0: BLPoint(30, 40),
      p1: BLPoint(200, 170),
      stops: const [
        BLGradientStop(0.0, 0xFF3366CC),
        BLGradientStop(1.0, 0xFF66CC99),
      ],
    ));
  await ctx.fillPath(blob);

  // 2. O contorno da mesma forma, com juntas e pontas arredondadas.
  ctx
    ..setFillStyle(0xFF223344)
    ..setStrokeOptions(const BLStrokeOptions(
      width: 4,
      startCap: BLStrokeCap.round,
      endCap: BLStrokeCap.round,
      join: BLStrokeJoin.round,
    ));
  await ctx.strokePath(blob);

  // 3. A red rectangle clipped in half — the clip cuts by coverage mask, so
  //    the edge lands exactly on the boundary, not on the bounding box.
  ctx.save();
  ctx.clipToRectPath(0, 0, size / 2, size.toDouble());
  ctx.setFillStyle(0x99CC3333);
  await ctx.fillRect(60, 150, 140, 60);
  ctx.restore();

  ctx.flush();

  _printPreview(image);
}

/// Reduz a imagem a uma grade de caracteres, para conferir o resultado sem
/// depender de um codificador de imagem.
void _printPreview(BLImage image, {int cols = 60}) {
  const ramp = ' .:-=+*#%@';
  final step = image.width ~/ cols;
  final rows = image.height ~/ (step * 2);

  for (var row = 0; row < rows; row++) {
    final buffer = StringBuffer();
    for (var col = 0; col < cols; col++) {
      final argb = image.pixels[(row * step * 2) * image.width + col * step];
      final r = (argb >> 16) & 0xFF;
      final g = (argb >> 8) & 0xFF;
      final b = argb & 0xFF;
      // Perceptual luminance, inverted: the darker it is, the denser.
      final luma = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255.0;
      buffer.write(ramp[((1.0 - luma) * (ramp.length - 1)).round()]);
    }
    print(buffer);
  }
}
