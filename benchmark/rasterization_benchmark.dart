/// Benchmark comparativo de todos os métodos de rasterização implementados.
///
/// Uso:
///   dart run benchmark/rasterization_benchmark.dart
///
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:async';

import '../research/png/png_writer.dart';
import '../research/rasterizers/rasterizers.dart';

// Import explícito das duas versões Blend2D (pra garantir acesso mesmo sem export)
import '../research/rasterizers/blend2d/blend2d_rasterizer.dart' as b2d1;
import '../research/rasterizers/blend2d/blend2d_rasterizer2.dart' as b2d2;

// ─────────────────────────────────────────────────────────────────────────────
// POLÍGONOS DE TESTE
// ─────────────────────────────────────────────────────────────────────────────

/// Triângulo simples
List<double> createTriangle(double cx, double cy, double size) {
  return [
    cx, cy - size, // Topo
    cx - size * 0.866, cy + size * 0.5, // Esquerda inferior
    cx + size * 0.866, cy + size * 0.5, // Direita inferior
  ];
}

/// Quadrado
List<double> createSquare(double cx, double cy, double size) {
  final half = size / 2;
  return [
    cx - half,
    cy - half,
    cx + half,
    cy - half,
    cx + half,
    cy + half,
    cx - half,
    cy + half,
  ];
}

/// Estrela de 5 pontas
List<double> createStar(
    double cx, double cy, double outerRadius, double innerRadius) {
  final vertices = <double>[];
  const numPoints = 5;
  const angleStep = 3.14159265 / numPoints;

  for (int i = 0; i < numPoints * 2; i++) {
    final angle = -3.14159265 / 2 + i * angleStep;
    final radius = i.isEven ? outerRadius : innerRadius;
    vertices.add(cx + radius * cos(angle));
    vertices.add(cy + radius * sin(angle));
  }

  return vertices;
}

/// Polígono complexo (hexágono irregular)
List<double> createComplexPolygon(double cx, double cy, double size) {
  return [
    cx + size * 0.8,
    cy,
    cx + size * 0.4,
    cy + size * 0.7,
    cx - size * 0.3,
    cy + size * 0.6,
    cx - size * 0.9,
    cy,
    cx - size * 0.5,
    cy - size * 0.5,
    cx + size * 0.2,
    cy - size * 0.8,
  ];
}

/// Funções trigonométricas simples (só usadas na criação dos polígonos, fora do loop do benchmark)
double cos(double x) {
  var result = 1.0;
  var term = 1.0;
  for (int i = 1; i <= 10; i++) {
    term *= -x * x / ((2 * i - 1) * (2 * i));
    result += term;
  }
  return result;
}

double sin(double x) => cos(x - 3.14159265 / 2);

// ─────────────────────────────────────────────────────────────────────────────
// BENCHMARK RUNNER
// ─────────────────────────────────────────────────────────────────────────────

class BenchmarkResult {
  final String name;
  final double timeMs;
  final int polygonsPerSecond;

  BenchmarkResult(this.name, this.timeMs, this.polygonsPerSecond);

  @override
  String toString() {
    return '$name: ${timeMs.toStringAsFixed(2)}ms ($polygonsPerSecond poly/s)';
  }
}

class _SimdPairRule {
  final String scalarSuffix;
  final String simdSuffix;
  final String? variantLabel;

  const _SimdPairRule(
    this.scalarSuffix,
    this.simdSuffix, {
    this.variantLabel,
  });
}

class _SimdGapEntry {
  final String label;
  final BenchmarkResult scalar;
  final BenchmarkResult simd;

  const _SimdGapEntry({
    required this.label,
    required this.scalar,
    required this.simd,
  });

  double get deltaMs => simd.timeMs - scalar.timeMs;
  double get deltaPercent => ((simd.timeMs / scalar.timeMs) - 1.0) * 100.0;
  double get speedup => scalar.timeMs / simd.timeMs;
}

const List<_SimdPairRule> _simdPairRules = <_SimdPairRule>[
  _SimdPairRule(' (Scalar)', ' (SIMD)'),
  _SimdPairRule(' (Imm Scalar)', ' (Imm SIMD)', variantLabel: 'Imm'),
  _SimdPairRule(' (Batch Scalar)', ' (Batch SIMD)', variantLabel: 'Batch'),
  _SimdPairRule(' (Scalar+Iso)', ' (SIMD+Iso)', variantLabel: 'Iso'),
  _SimdPairRule(' (Batch Scalar+Iso)', ' (Batch SIMD+Iso)',
      variantLabel: 'Batch+Iso'),
];

List<_SimdGapEntry> _collectSimdGapEntries(List<BenchmarkResult> results) {
  final byName = <String, BenchmarkResult>{
    for (final r in results) r.name: r,
  };
  final out = <_SimdGapEntry>[];
  final seen = <String>{};

  for (final scalar in results) {
    for (final rule in _simdPairRules) {
      if (!scalar.name.endsWith(rule.scalarSuffix)) continue;
      final baseName = scalar.name
          .substring(0, scalar.name.length - rule.scalarSuffix.length);
      final simdName = '$baseName${rule.simdSuffix}';
      final simd = byName[simdName];
      if (simd == null) continue;

      final dedupKey = '${scalar.name}|${simd.name}';
      if (!seen.add(dedupKey)) continue;

      final label = (rule.variantLabel == null || rule.variantLabel!.isEmpty)
          ? baseName
          : '$baseName (${rule.variantLabel})';
      out.add(_SimdGapEntry(label: label, scalar: scalar, simd: simd));
    }
  }

  out.sort((a, b) => b.deltaPercent.compareTo(a.deltaPercent));
  return out;
}

String _formatSimdGapReport(List<_SimdGapEntry> gaps) {
  final sb = StringBuffer();
  sb.writeln('SIMD GAP REPORT (Scalar vs SIMD, lower is better)');
  sb.writeln(
      'Algorithm                      Scalar      SIMD        Delta       Status');
  sb.writeln(
      '--------------------------------------------------------------------------');

  if (gaps.isEmpty) {
    sb.writeln('No Scalar/SIMD pairs found.');
    return sb.toString();
  }

  for (final gap in gaps) {
    final scalarMs = '${gap.scalar.timeMs.toStringAsFixed(2)}ms';
    final simdMs = '${gap.simd.timeMs.toStringAsFixed(2)}ms';
    final deltaMs =
        '${gap.deltaMs >= 0 ? '+' : ''}${gap.deltaMs.toStringAsFixed(2)}ms';
    final deltaPct =
        '${gap.deltaPercent >= 0 ? '+' : ''}${gap.deltaPercent.toStringAsFixed(1)}%';
    final status = gap.deltaMs <= 0
        ? 'SIMD faster (${gap.speedup.toStringAsFixed(2)}x)'
        : 'SIMD slower (${(1.0 / gap.speedup).toStringAsFixed(2)}x)';

    sb.writeln(
      '${gap.label.padRight(30)} '
      '${scalarMs.padLeft(9)} '
      '${simdMs.padLeft(9)} '
      '${('$deltaMs $deltaPct').padLeft(15)} '
      '$status',
    );
  }

  return sb.toString();
}

Future<void> _writeSimdGapReportFile(String reportText) async {
  final dir = Directory('output/rasterization_benchmark');
  await dir.create(recursive: true);
  final file = File('${dir.path}/simd_gap_report.txt');
  await file.writeAsString('$reportText\n');
}

typedef RasterizeFunc = FutureOr<void> Function(
    List<double> vertices, int color);

/// Benchmark padrão (chama rasterize() por polígono)
Future<BenchmarkResult> runBenchmark(
  String name,
  RasterizeFunc rasterize,
  List<List<double>> polygons,
  int warmupIterations,
  int measureIterations, {
  void Function()? clear,
}) async {
  // Warmup
  for (int i = 0; i < warmupIterations; i++) {
    if (clear != null) clear();
    for (final poly in polygons) {
      await rasterize(poly, 0xFFFF0000);
    }
  }

  // Measure
  final stopwatch = Stopwatch()..start();

  for (int i = 0; i < measureIterations; i++) {
    if (clear != null) clear();
    for (final poly in polygons) {
      await rasterize(poly, 0xFFFF0000);
    }
  }

  stopwatch.stop();
  final totalMs = stopwatch.elapsedMicroseconds / 1000.0;
  final totalPolygons = measureIterations * polygons.length;
  final polyPerSec = (totalPolygons / (totalMs / 1000)).round();

  return BenchmarkResult(name, totalMs / measureIterations, polyPerSec);
}

typedef RasterizeBatchFunc = FutureOr<void> Function(
    List<List<double>> polygons, int color);

/// Benchmark em batch (acumula todos os polígonos e executa um flush/resolução 1x por iteração)
Future<BenchmarkResult> runBenchmarkBatch(
  String name,
  RasterizeBatchFunc rasterizeBatch,
  List<List<double>> polygons,
  int warmupIterations,
  int measureIterations, {
  void Function()? clear,
}) async {
  // Warmup
  for (int i = 0; i < warmupIterations; i++) {
    if (clear != null) clear();
    await rasterizeBatch(polygons, 0xFFFF0000);
  }

  // Measure
  final stopwatch = Stopwatch()..start();

  for (int i = 0; i < measureIterations; i++) {
    if (clear != null) clear();
    await rasterizeBatch(polygons, 0xFFFF0000);
  }

  stopwatch.stop();
  final totalMs = stopwatch.elapsedMicroseconds / 1000.0;
  final totalPolygons = measureIterations * polygons.length;
  final polyPerSec = (totalPolygons / (totalMs / 1000)).round();

  return BenchmarkResult(name, totalMs / measureIterations, polyPerSec);
}

Future<void> saveImage(
    String name, Uint32List buffer, int width, int height) async {
  final dir = Directory('output/rasterization_benchmark');
  await dir.create(recursive: true);

  // Convert 0xAARRGGBB (Uint32) to RGBA bytes
  final rgba = Uint8List(width * height * 4);
  for (int i = 0; i < buffer.length; i++) {
    final pixel = buffer[i];
    rgba[i * 4] = (pixel >> 16) & 0xFF; // R
    rgba[i * 4 + 1] = (pixel >> 8) & 0xFF; // G
    rgba[i * 4 + 2] = pixel & 0xFF; // B
    rgba[i * 4 + 3] = (pixel >> 24) & 0xFF; // A
  }

  try {
    await PngWriter.saveRgba('${dir.path}/$name.png', rgba, width, height);
  } catch (e) {
    print("Error saving $name.png: $e");
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// MAIN
// ─────────────────────────────────────────────────────────────────────────────

Future<void> main() async {
  const width = 512;
  const height = 512;
  const warmup = 5;
  const iterations = 20;

  print('╔══════════════════════════════════════════════════════════════════╗');
  print('║         MARLIN RASTERIZATION METHODS BENCHMARK                   ║');
  print(
      '║         Resolution: ${width}x$height, Iterations: $iterations              ║');
  print('╚══════════════════════════════════════════════════════════════════╝');
  print('');

  // Criar polígonos de teste
  final polygons = <List<double>>[
    createTriangle(256, 256, 100),
    createSquare(128, 128, 80),
    createStar(384, 384, 100, 40),
    createComplexPolygon(256, 400, 80),
  ];

  // Adicionar mais polígonos para stress test
  for (int i = 0; i < 10; i++) {
    final x = 50.0 + (i % 5) * 100;
    final y = 50.0 + (i ~/ 5) * 100;
    polygons.add(createTriangle(x, y, 30));
  }

  print('Polygons per iteration: ${polygons.length}');
  print('');

  final results = <BenchmarkResult>[];

  // ─── ACDR ───────────────────────────────────────────────────────────────
  print('Testing ACDR (Accumulated Coverage Derivative)...');
  try {
    final acdr = ACDRRasterizer(
        width: width,
        height: height,
        enableSubpixelY: false,
        enableSinglePixelSpanFix: false,
        enableVerticalSupersample: false);

    results.add(await runBenchmark(
      'ACDR',
      (vertices, color) {
        final verts = <Vec2>[];
        for (int i = 0; i < vertices.length; i += 2) {
          verts.add(Vec2(vertices[i] / width, vertices[i + 1] / height));
        }
        acdr.rasterize(verts);
      },
      polygons,
      warmup,
      iterations,
      clear: () => acdr.clear(),
    ));

    final aBuffer = Uint32List(width * height);
    for (int i = 0; i < width * height; i++) {
      final cov = acdr.coverageBuffer[i].clamp(0, 1);
      final aa = (cov * 255).toInt();
      aBuffer[i] = 0xFF000000 | (255 << 16) | ((255 - aa) << 8) | (255 - aa);
    }
    await saveImage('ACDR', aBuffer, width, height);
  } catch (e) {
    print('  ACDR failed: $e');
  }

  // O arm de comparacao com o Marlin renderer do OpenJDK foi removido
  // junto com o port, que era GPL e incompativel com a licenca MIT
  // deste pacote. Veja NOTICE.

  // ─── SCANLINE_EO ────────────────────────────────────────────────────────
  print('Testing SCANLINE_EO (Scanline no AA)...');
  try {
    final scanline = ScanlineRasterizer(width: width, height: height);
    results.add(await runBenchmark(
      'SCANLINE_EO',
      (vertices, color) => scanline.drawPolygon(vertices, color),
      polygons,
      warmup,
      iterations,
      clear: () => scanline.clear(0xFFFFFFFF),
    ));
    await saveImage('SCANLINE_EO', scanline.buffer, width, height);
  } catch (e) {
    print('  SCANLINE_EO failed: $e');
  }

  // ─── SSAA ──────────────────────────────────────────────────────────────
  print('Testing SSAA (RGSS 8x8)...');
  try {
    final ssaa = SSAARasterizer(width: width, height: height);
    results.add(await runBenchmark(
      'SSAA 8x8',
      (vertices, color) => ssaa.drawPolygon(vertices, color),
      polygons,
      warmup,
      iterations,
      clear: () => ssaa.clear(0xFFFFFFFF),
    ));
    await saveImage('SSAA', ssaa.buffer, width, height);
  } catch (e) {
    print('  SSAA failed: $e');
  }

  // ─── MSAA ──────────────────────────────────────────────────────────────
  print('Testing MSAA (4x4)...');
  try {
    final msaa = MSAARasterizer(
        width: width,
        height: height,
        samplesPerAxis: 4,
        enableTileCulling: false);
    results.add(await runBenchmark(
      'MSAA 4x4',
      (vertices, color) => msaa.drawPolygon(vertices, color),
      polygons,
      warmup,
      iterations,
      clear: () => msaa.clear(0xFFFFFFFF),
    ));
    await saveImage('MSAA_4x4', msaa.buffer, width, height);
  } catch (e) {
    print('  MSAA failed: $e');
  }

  // ─── TESSELLATION ──────────────────────────────────────────────────────
  print('Testing TESSELLATION...');
  try {
    final tess = TessellationRasterizer(width: width, height: height);
    results.add(await runBenchmark(
      'TESSELLATION',
      (vertices, color) => tess.drawPolygon(vertices, color),
      polygons,
      warmup,
      iterations,
      clear: () => tess.clear(0xFFFFFFFF),
    ));
    await saveImage('TESSELLATION', tess.buffer, width, height);
  } catch (e) {
    print('  TESSELLATION failed: $e');
  }

  // ─── WAVELET_HAAR ──────────────────────────────────────────────────────
  print('Testing WAVELET_HAAR...');
  try {
    final wavelet = WaveletHaarRasterizer(width: width, height: height);
    results.add(await runBenchmark(
      'WAVELET_HAAR',
      (vertices, color) => wavelet.drawPolygon(vertices, color),
      polygons,
      warmup,
      iterations,
      clear: () => wavelet.clear(0xFFFFFFFF),
    ));
    await saveImage('WAVELET_HAAR', wavelet.buffer, width, height);
  } catch (e) {
    print('  WAVELET_HAAR failed: $e');
  }

  // ─── DAA ────────────────────────────────────────────────────────────────
  print('Testing DAA (Delta-Analytic Approximation)...');
  try {
    final daa = DAARasterizer(width: width, height: height);
    results.add(await runBenchmark(
      'DAA',
      (vertices, color) {
        if (vertices.length >= 6) {
          daa.drawPolygon(vertices, color);
        }
      },
      polygons,
      warmup,
      iterations,
      clear: () => daa.clear(0xFFFFFFFF),
    ));
    await saveImage('DAA', daa.framebuffer, width, height);
  } catch (e) {
    print('  DAA failed: $e');
  }

  // ─── DDFI ───────────────────────────────────────────────────────────────
  print('Testing DDFI (Discrete Differential Flux Integration)...');
  try {
    final ddfi = FluxRenderer(width, height);
    results.add(await runBenchmark(
      'DDFI',
      (vertices, color) => ddfi.drawPolygon(vertices, color),
      polygons,
      warmup,
      iterations,
      clear: () => ddfi.clear(0xFFFFFFFF),
    ));
    await saveImage('DDFI', ddfi.buffer, width, height);
  } catch (e) {
    print('  DDFI failed: $e');
  }

  // ─── DBSR ────────────────────────────────────────────────────────────────
  print('Testing DBSR (Distance-Based Subpixel)...');
  try {
    final dbsr = DBSRRasterizer(width: width, height: height);
    results.add(await runBenchmark(
      'DBSR',
      (vertices, color) {
        if (vertices.length >= 6) {
          dbsr.drawPolygon(vertices, color);
        }
      },
      polygons,
      warmup,
      iterations,
      clear: () => dbsr.clear(0xFFFFFFFF),
    ));
    await saveImage('DBSR', dbsr.pixels, width, height);
  } catch (e) {
    print('  DBSR failed: $e');
  }

  // ─── EPL_AA ─────────────────────────────────────────────────────────────
  print('Testing EPL_AA (EdgePlane Lookup)...');
  try {
    final epl = EPLRasterizer(width: width, height: height);
    results.add(await runBenchmark(
      'EPL_AA',
      (vertices, color) => epl.drawPolygon(vertices, color),
      polygons,
      warmup,
      iterations,
      clear: () => epl.clear(0xFFFFFFFF),
    ));
    await saveImage('EPL_AA', epl.buffer, width, height);
  } catch (e) {
    print('  EPL_AA failed: $e');
  }

  // ─── QCS ────────────────────────────────────────────────────────────────
  print('Testing QCS (Quantized Coverage Signature)...');
  try {
    final qcs = QCSRasterizer(width: width, height: height);
    results.add(await runBenchmark(
      'QCS',
      (vertices, color) => qcs.drawPolygon(vertices, color),
      polygons,
      warmup,
      iterations,
      clear: () => qcs.clear(0xFFFFFFFF),
    ));
    await saveImage('QCS', qcs.pixels, width, height);
  } catch (e) {
    print('  QCS failed: $e');
  }

  // ─── RHBD ───────────────────────────────────────────────────────────────
  print('Testing RHBD (Hybrid Tiled Rasterization)...');
  try {
    final rhbd = RHBDRasterizer(width: width, height: height);
    results.add(await runBenchmark(
      'RHBD',
      (vertices, color) => rhbd.drawPolygon(vertices, color),
      polygons,
      warmup,
      iterations,
      clear: () => rhbd.clear(0xFFFFFFFF),
    ));
    await saveImage('RHBD', rhbd.buffer, width, height);
  } catch (e) {
    print('  RHBD failed: $e');
  }

  // ─── AMCAD ──────────────────────────────────────────────────────────────
  print('Testing AMCAD (Analytic Micro-Cell Adaptive)...');
  try {
    final amcad = AMCADRasterizer(width: width, height: height);
    results.add(await runBenchmark(
      'AMCAD',
      (vertices, color) => amcad.drawPolygon(vertices, color),
      polygons,
      warmup,
      iterations,
      clear: () => amcad.clear(0xFFFFFFFF),
    ));
    await saveImage('AMCAD', amcad.buffer, width, height);
  } catch (e) {
    print('  AMCAD failed: $e');
  }

  // ─── HSGR ───────────────────────────────────────────────────────────────
  print('Testing HSGR (Hilbert-Space Guided)...');
  try {
    final hsgr = HSGRRasterizer(width: width, height: height);
    results.add(await runBenchmark(
      'HSGR',
      (vertices, color) => hsgr.drawPolygon(vertices, color),
      polygons,
      warmup,
      iterations,
      clear: () => hsgr.clear(0xFFFFFFFF),
    ));
    await saveImage('HSGR', hsgr.buffer, width, height);
  } catch (e) {
    print('  HSGR failed: $e');
  }

  // ─── LNAF_SE ────────────────────────────────────────────────────────────
  print('Testing LNAF_SE (Lattice-Normal Alpha Field)...');
  try {
    Future<void> warmupLnafMode(LnafSeQualityMode quality) async {
      final warm = LNAFSERasterizer(
        width: width,
        height: height,
        qualityMode: quality,
      );
      warm.clear(0xFFFFFFFF);
      for (final poly in polygons) {
        warm.drawPolygon(poly, 0xFFFF0000);
      }
    }

    Future<void> runLnafVariant({
      required String label,
      required String imageName,
      required LnafSeQualityMode quality,
      String? extraImageName,
    }) async {
      final lnaf = LNAFSERasterizer(
        width: width,
        height: height,
        qualityMode: quality,
      );
      results.add(await runBenchmark(
        label,
        (vertices, color) => lnaf.drawPolygon(vertices, color),
        polygons,
        warmup,
        iterations,
        clear: () => lnaf.clear(0xFFFFFFFF),
      ));
      await saveImage(imageName, lnaf.buffer, width, height);
      if (extraImageName != null && extraImageName.isNotEmpty) {
        await saveImage(extraImageName, lnaf.buffer, width, height);
      }
    }

    await warmupLnafMode(LnafSeQualityMode.fast);
    await warmupLnafMode(LnafSeQualityMode.high);
    await warmupLnafMode(LnafSeQualityMode.ultra);
    await warmupLnafMode(LnafSeQualityMode.extreme);
    await warmupLnafMode(LnafSeQualityMode.cinematic);

    await runLnafVariant(
      label: 'LNAF_SE (Fast)',
      imageName: 'LNAF_SE_FAST',
      quality: LnafSeQualityMode.fast,
    );
    await runLnafVariant(
      label: 'LNAF_SE (High)',
      imageName: 'LNAF_SE_HIGH',
      quality: LnafSeQualityMode.high,
    );
    await runLnafVariant(
      label: 'LNAF_SE (Ultra)',
      imageName: 'LNAF_SE_ULTRA',
      quality: LnafSeQualityMode.ultra,
    );
    await runLnafVariant(
      label: 'LNAF_SE (Extreme)',
      imageName: 'LNAF_SE_EXTREME',
      quality: LnafSeQualityMode.extreme,
    );
    await runLnafVariant(
      label: 'LNAF_SE',
      imageName: 'LNAF_SE',
      quality: LnafSeQualityMode.fast,
      extraImageName: 'LNAF_SE_FAST_DEFAULT',
    );
  } catch (e) {
    print('  LNAF_SE failed: $e');
  }

  // ─── SWEEP_SDF ──────────────────────────────────────────────────────────
  print('Testing SWEEP_SDF (Scanline with Analytical SDF)...');
  try {
    final sweepSdf = SweepSDFRasterizer(width: width, height: height);
    results.add(await runBenchmark(
      'SWEEP_SDF',
      (vertices, color) => sweepSdf.drawPolygon(vertices, color),
      polygons,
      warmup,
      iterations,
      clear: () => sweepSdf.clear(0xFFFFFFFF),
    ));
    await saveImage('SWEEP_SDF', sweepSdf.pixels, width, height);
  } catch (e) {
    print('  SWEEP_SDF failed: $e');
  }

  // ─── SCDT ───────────────────────────────────────────────────────────────
  print('Testing SCDT (Spectral Coverage Ternary)...');
  try {
    final scdt = SCDTRasterizer(width: width, height: height);
    results.add(await runBenchmark(
      'SCDT',
      (vertices, color) => scdt.drawPolygon(vertices, color),
      polygons,
      warmup,
      iterations,
      clear: () => scdt.clear(0xFFFFFFFF),
    ));
    await saveImage('SCDT', scdt.pixels, width, height);
  } catch (e) {
    print('  SCDT failed: $e');
  }

  // ─── SCP_AED ────────────────────────────────────────────────────────────
  print('Testing SCP_AED (Stochastic Coverage Propagation)...');
  try {
    final scp = SCPAEDRasterizer(width: width, height: height);
    results.add(await runBenchmark(
      'SCP_AED',
      (vertices, color) => scp.drawPolygon(vertices, color),
      polygons,
      warmup,
      iterations,
      clear: () => scp.clear(0xFFFFFFFF),
    ));
    await saveImage('SCP_AED', scp.buffer, width, height);
  } catch (e) {
    print('  SCP_AED failed: $e');
  }

  // ─── BLEND2D v1 ─────────────────────────────────────────────────────────
  print('Testing BLEND2D v1 (Various configs)...');
  try {
    // 1. Scalar, No Isolates
    final b2dScalar = b2d1.Blend2DRasterizer(
      width,
      height,
      config: b2d1.RasterizerConfig(useSimd: false, useIsolates: false),
    );
    results.add(await runBenchmark(
      'B2D v1 (Scalar)',
      (vertices, color) => b2dScalar.drawPolygon(vertices, color),
      polygons,
      warmup,
      iterations,
      clear: () => b2dScalar.clear(0xFFFFFFFF),
    ));
    await saveImage('BLEND2D_v1_Scalar', b2dScalar.buffer, width, height);

    // 2. SIMD, No Isolates
    final b2dSimd = b2d1.Blend2DRasterizer(
      width,
      height,
      config: b2d1.RasterizerConfig(useSimd: true, useIsolates: false),
    );
    results.add(await runBenchmark(
      'B2D v1 (SIMD)',
      (vertices, color) => b2dSimd.drawPolygon(vertices, color),
      polygons,
      warmup,
      iterations,
      clear: () => b2dSimd.clear(0xFFFFFFFF),
    ));
    await saveImage('BLEND2D_v1_SIMD', b2dSimd.buffer, width, height);

    // 3. Scalar + Isolates
    final b2dScalarParallel = b2d1.Blend2DRasterizer(
      width,
      height,
      config: b2d1.RasterizerConfig(
        useSimd: false,
        useIsolates: true,
        tileHeight: height ~/ 4,
      ),
    );
    results.add(await runBenchmark(
      'B2D v1 (Scalar+Iso)',
      (vertices, color) => b2dScalarParallel.drawPolygon(vertices, color),
      polygons,
      warmup,
      iterations,
      clear: () => b2dScalarParallel.clear(0xFFFFFFFF),
    ));
    await saveImage(
        'BLEND2D_v1_Scalar_Isolates', b2dScalarParallel.buffer, width, height);

    // 4. SIMD + Isolates
    final b2dParallel = b2d1.Blend2DRasterizer(
      width,
      height,
      config: b2d1.RasterizerConfig(
        useSimd: true,
        useIsolates: true,
        tileHeight: height ~/ 4,
      ),
    );
    results.add(await runBenchmark(
      'B2D v1 (SIMD+Iso)',
      (vertices, color) => b2dParallel.drawPolygon(vertices, color),
      polygons,
      warmup,
      iterations,
      clear: () => b2dParallel.clear(0xFFFFFFFF),
    ));
    await saveImage(
        'BLEND2D_v1_SIMD_Isolates', b2dParallel.buffer, width, height);
  } catch (e) {
    print('  BLEND2D v1 failed: $e');
  }

  // ─── BLEND2D v2.0 ───────────────────────────────────────────────────────
  print('Testing BLEND2D v2.0 (Immediate + Batched, Various configs)...');

  b2d2.Blend2DRasterizer2? v2ScalarImmediate;
  b2d2.Blend2DRasterizer2? v2SimdImmediate;
  b2d2.Blend2DRasterizer2? v2ScalarBatched;
  b2d2.Blend2DRasterizer2? v2SimdBatched;

  b2d2.Blend2DRasterizer2? v2ScalarBatchedIso;
  b2d2.Blend2DRasterizer2? v2SimdBatchedIso;

  try {
    // -------------------------
    // IMMEDIATE (flush por polígono)
    // -------------------------
    v2ScalarImmediate = b2d2.Blend2DRasterizer2(
      width,
      height,
      config: b2d2.RasterizerConfig2(useSimd: false, useIsolates: false),
    );
    results.add(await runBenchmark(
      'B2D v2 (Imm Scalar)',
      (vertices, color) =>
          v2ScalarImmediate!.drawPolygon(vertices, color, flushNow: true),
      polygons,
      warmup,
      iterations,
      clear: () => v2ScalarImmediate!.clear(0xFFFFFFFF),
    ));
    await saveImage(
        'BLEND2D_v2_Imm_Scalar', v2ScalarImmediate.buffer, width, height);

    v2SimdImmediate = b2d2.Blend2DRasterizer2(
      width,
      height,
      config: b2d2.RasterizerConfig2(useSimd: true, useIsolates: false),
    );
    results.add(await runBenchmark(
      'B2D v2 (Imm SIMD)',
      (vertices, color) =>
          v2SimdImmediate!.drawPolygon(vertices, color, flushNow: true),
      polygons,
      warmup,
      iterations,
      clear: () => v2SimdImmediate!.clear(0xFFFFFFFF),
    ));
    await saveImage(
        'BLEND2D_v2_Imm_SIMD', v2SimdImmediate.buffer, width, height);

    // -------------------------
    // BATCHED (addPolygon em todos + flush 1x)
    // -------------------------
    v2ScalarBatched = b2d2.Blend2DRasterizer2(
      width,
      height,
      config: b2d2.RasterizerConfig2(useSimd: false, useIsolates: false),
    );
    results.add(await runBenchmarkBatch(
      'B2D v2 (Batch Scalar)',
      (polys, color) async {
        for (final p in polys) {
          v2ScalarBatched!.addPolygon(p);
        }
        await v2ScalarBatched!.flush(color);
      },
      polygons,
      warmup,
      iterations,
      clear: () => v2ScalarBatched!.clear(0xFFFFFFFF),
    ));
    await saveImage(
        'BLEND2D_v2_Batch_Scalar', v2ScalarBatched.buffer, width, height);

    v2SimdBatched = b2d2.Blend2DRasterizer2(
      width,
      height,
      config: b2d2.RasterizerConfig2(useSimd: true, useIsolates: false),
    );
    results.add(await runBenchmarkBatch(
      'B2D v2 (Batch SIMD)',
      (polys, color) async {
        for (final p in polys) {
          v2SimdBatched!.addPolygon(p);
        }
        await v2SimdBatched!.flush(color);
      },
      polygons,
      warmup,
      iterations,
      clear: () => v2SimdBatched!.clear(0xFFFFFFFF),
    ));
    await saveImage(
        'BLEND2D_v2_Batch_SIMD', v2SimdBatched.buffer, width, height);

    // -------------------------
    // BATCHED + ISOLATES (pool persistente)
    // -------------------------
    v2ScalarBatchedIso = b2d2.Blend2DRasterizer2(
      width,
      height,
      config: b2d2.RasterizerConfig2(
        useSimd: false,
        useIsolates: true,
        tileHeight: height ~/ 4,
        minParallelDirtyHeight: 1, // força paralelismo no benchmark
      ),
    );
    results.add(await runBenchmarkBatch(
      'B2D v2 (Batch Scalar+Iso)',
      (polys, color) async {
        for (final p in polys) {
          v2ScalarBatchedIso!.addPolygon(p);
        }
        await v2ScalarBatchedIso!.flush(color);
      },
      polygons,
      warmup,
      iterations,
      clear: () => v2ScalarBatchedIso!.clear(0xFFFFFFFF),
    ));
    await saveImage('BLEND2D_v2_Batch_Scalar_Isolates',
        v2ScalarBatchedIso.buffer, width, height);

    v2SimdBatchedIso = b2d2.Blend2DRasterizer2(
      width,
      height,
      config: b2d2.RasterizerConfig2(
        useSimd: true,
        useIsolates: true,
        tileHeight: height ~/ 4,
        minParallelDirtyHeight: 1, // força paralelismo no benchmark
      ),
    );
    results.add(await runBenchmarkBatch(
      'B2D v2 (Batch SIMD+Iso)',
      (polys, color) async {
        for (final p in polys) {
          v2SimdBatchedIso!.addPolygon(p);
        }
        await v2SimdBatchedIso!.flush(color);
      },
      polygons,
      warmup,
      iterations,
      clear: () => v2SimdBatchedIso!.clear(0xFFFFFFFF),
    ));
    await saveImage('BLEND2D_v2_Batch_SIMD_Isolates', v2SimdBatchedIso.buffer,
        width, height);
  } catch (e) {
    print('  BLEND2D v2.0 failed: $e');
  } finally {
    // encerra isolates do pool (se tiver)
    try {
      await v2ScalarImmediate?.dispose();
    } catch (_) {}
    try {
      await v2SimdImmediate?.dispose();
    } catch (_) {}
    try {
      await v2ScalarBatched?.dispose();
    } catch (_) {}
    try {
      await v2SimdBatched?.dispose();
    } catch (_) {}
    try {
      await v2ScalarBatchedIso?.dispose();
    } catch (_) {}
    try {
      await v2SimdBatchedIso?.dispose();
    } catch (_) {}
  }

  // ─── SKIA_SCANLINE ──────────────────────────────────────────────────────
  print('Testing SKIA_SCANLINE (Various configs)...');
  try {
    final skiaScalar =
        SkiaRasterizer(width: width, height: height, useSimd: false);
    results.add(await runBenchmark(
      'SKIA (Scalar)',
      (vertices, color) => skiaScalar.drawPolygon(vertices, color),
      polygons,
      warmup,
      iterations,
      clear: () => skiaScalar.clear(0xFFFFFFFF),
    ));
    await saveImage('SKIA_Scalar', skiaScalar.buffer, width, height);

    final skiaSimd =
        SkiaRasterizer(width: width, height: height, useSimd: true);
    results.add(await runBenchmark(
      'SKIA (SIMD)',
      (vertices, color) => skiaSimd.drawPolygon(vertices, color),
      polygons,
      warmup,
      iterations,
      clear: () => skiaSimd.clear(0xFFFFFFFF),
    ));
    await saveImage('SKIA_SIMD', skiaSimd.buffer, width, height);
  } catch (e) {
    print('  SKIA_SCANLINE failed: $e');
  }

  // ─── EDGE_FLAG_AA ───────────────────────────────────────────────────────
  print('Testing EDGE_FLAG_AA...');
  try {
    final edgeFlag = EdgeFlagAARasterizer(width: width, height: height);
    results.add(await runBenchmark(
      'EDGE_FLAG_AA',
      (vertices, color) => edgeFlag.drawPolygon(vertices, color),
      polygons,
      warmup,
      iterations,
      clear: () => edgeFlag.clear(0xFFFFFFFF),
    ));
    await saveImage('EDGE_FLAG_AA', edgeFlag.buffer, width, height);
  } catch (e) {
    print('  EDGE_FLAG_AA failed: $e');
  }

  // ─── RESULTADOS ─────────────────────────────────────────────────────────
  print('');
  print('╔══════════════════════════════════════════════════════════════════╗');
  print('║                          RESULTS                                 ║');
  print('╠══════════════════════════════════════════════════════════════════╣');

  results.sort((a, b) => a.timeMs.compareTo(b.timeMs));

  for (final result in results) {
    final name = result.name.padRight(28);
    final time = '${result.timeMs.toStringAsFixed(2)}ms'.padLeft(10);
    final pps = '${result.polygonsPerSecond} poly/s'.padLeft(15);
    print('║ $name │ $time │ $pps ║');
  }

  print('╚══════════════════════════════════════════════════════════════════╝');

  final simdGaps = _collectSimdGapEntries(results);
  final simdGapText = _formatSimdGapReport(simdGaps);

  print('');
  for (final line in simdGapText.split('\n')) {
    if (line.isEmpty) continue;
    print(line);
  }

  try {
    await _writeSimdGapReportFile(simdGapText);
    print('');
    print(
        'SIMD gap report saved to: output/rasterization_benchmark/simd_gap_report.txt');
  } catch (e) {
    print('');
    print('Failed to save SIMD gap report file: $e');
  }
}
