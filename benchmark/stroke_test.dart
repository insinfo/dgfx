/// Teste funcional rápido do BLStroker (Fase 5).
///
/// Uso:
///   dart run benchmark/stroke_test.dart
///
/// Produz: output/rasterization_benchmark/BLEND2D_PORT_STROKE_TEST.png
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../research/png/png_writer.dart';

import 'package:dgfx/src/blend2d/blend2d.dart';

Future<void> main() async {
  const w = 512, h = 512;
  final image = BLImage(w, h);
  final ctx = BLContext(image);
  ctx.clear(0xFFFFFFFF);

  // --- 1) Retângulo fechado com stroke bevel ---
  final rect = BLPath();
  rect.moveTo(50, 50);
  rect.lineTo(200, 50);
  rect.lineTo(200, 150);
  rect.lineTo(50, 150);
  rect.close();

  ctx.setStrokeOptions(const BLStrokeOptions(
    width: 6.0,
    join: BLStrokeJoin.bevel,
    startCap: BLStrokeCap.butt,
    endCap: BLStrokeCap.butt,
  ));
  await ctx.strokePath(rect, color: 0xFF0000FF);

  // --- 2) Triângulo fechado com miter join ---
  final tri = BLPath();
  tri.moveTo(300, 50);
  tri.lineTo(450, 150);
  tri.lineTo(300, 150);
  tri.close();

  ctx.setStrokeOptions(const BLStrokeOptions(
    width: 4.0,
    join: BLStrokeJoin.miterBevel,
    miterLimit: 4.0,
  ));
  await ctx.strokePath(tri, color: 0xFFFF0000);

  // --- 3) Linha aberta com round cap ---
  final line = BLPath();
  line.moveTo(50, 250);
  line.lineTo(200, 300);
  line.lineTo(50, 350);

  ctx.setStrokeOptions(const BLStrokeOptions(
    width: 8.0,
    join: BLStrokeJoin.round,
    startCap: BLStrokeCap.round,
    endCap: BLStrokeCap.round,
  ));
  await ctx.strokePath(line, color: 0xFF00AA00);

  // --- 4) Estrela com round join ---
  final star = BLPath();
  const scx = 370.0, scy = 300.0, outerR = 80.0, innerR = 35.0;
  const pts = 5;
  const step = math.pi / pts;
  for (int i = 0; i < pts * 2; i++) {
    final angle = -math.pi / 2 + i * step;
    final r = (i % 2 == 0) ? outerR : innerR;
    final px2 = scx + r * math.cos(angle);
    final py2 = scy + r * math.sin(angle);
    if (i == 0) {
      star.moveTo(px2, py2);
    } else {
      star.lineTo(px2, py2);
    }
  }
  star.close();

  ctx.setStrokeOptions(const BLStrokeOptions(
    width: 3.0,
    join: BLStrokeJoin.round,
  ));
  await ctx.strokePath(star, color: 0xFFFF6600);

  // --- 5) Curva cúbica (open, square+triangle caps) ---
  final curve = BLPath();
  curve.moveTo(50, 430);
  curve.cubicTo(150, 380, 300, 480, 450, 430);

  ctx.setStrokeOptions(const BLStrokeOptions(
    width: 5.0,
    join: BLStrokeJoin.bevel,
    startCap: BLStrokeCap.square,
    endCap: BLStrokeCap.triangle,
  ));
  await ctx.strokePath(curve, color: 0xFF9900CC);

  // --- 6) Círculo via cubicTo ---
  final circle = BLPath();
  const ccx = 130.0, ccy = 460.0, cr = 30.0;
  const kappa = 0.5522847498;
  circle.moveTo(ccx + cr, ccy);
  circle.cubicTo(
      ccx + cr, ccy + cr * kappa, ccx + cr * kappa, ccy + cr, ccx, ccy + cr);
  circle.cubicTo(
      ccx - cr * kappa, ccy + cr, ccx - cr, ccy + cr * kappa, ccx - cr, ccy);
  circle.cubicTo(
      ccx - cr, ccy - cr * kappa, ccx - cr * kappa, ccy - cr, ccx, ccy - cr);
  circle.cubicTo(
      ccx + cr * kappa, ccy - cr, ccx + cr, ccy - cr * kappa, ccx + cr, ccy);
  circle.close();

  ctx.setStrokeOptions(const BLStrokeOptions(
    width: 4.0,
    join: BLStrokeJoin.round,
  ));
  await ctx.strokePath(circle, color: 0xFF000000);

  // --- Salvar ---
  final outDir = Directory('output/rasterization_benchmark');
  if (!outDir.existsSync()) outDir.createSync(recursive: true);

  final rgba = Uint8List(w * h * 4);
  for (int i = 0; i < image.pixels.length; i++) {
    final px = image.pixels[i];
    rgba[i * 4] = (px >> 16) & 0xFF;
    rgba[i * 4 + 1] = (px >> 8) & 0xFF;
    rgba[i * 4 + 2] = px & 0xFF;
    rgba[i * 4 + 3] = (px >> 24) & 0xFF;
  }
  await PngWriter.saveRgba(
      'output/rasterization_benchmark/BLEND2D_PORT_STROKE_TEST.png',
      rgba,
      w,
      h);

  // Sanity check
  int nonWhite = 0;
  for (int i = 0; i < image.pixels.length; i++) {
    if (image.pixels[i] != 0xFFFFFFFF) nonWhite++;
  }

  print('Stroke test concluído.');
  print('Output: output/rasterization_benchmark/BLEND2D_PORT_STROKE_TEST.png');
  print('Non-white pixels: $nonWhite (deve ser > 0)');

  await ctx.dispose();
}
