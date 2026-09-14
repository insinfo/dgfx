import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

const int _defaultBinsPerOctant = 16;
const int _defaultMaxDist16 = 32;
const String _defaultOutPath =
    'lib/src/rasterization_algorithms/lnaf_se/lnaf_se_tables.dart';

void main(List<String> args) {
  if (args.contains('--help') || args.contains('-h')) {
    _printUsage();
    return;
  }

  var binsPerOctant = _defaultBinsPerOctant;
  var maxDist16 = _defaultMaxDist16;
  var outPath = _defaultOutPath;

  for (final arg in args) {
    if (arg.startsWith('--bins=')) {
      binsPerOctant = _parseIntArg(arg, '--bins=');
      continue;
    }
    if (arg.startsWith('--max-dist16=')) {
      maxDist16 = _parseIntArg(arg, '--max-dist16=');
      continue;
    }
    if (arg.startsWith('--out=')) {
      outPath = arg.substring('--out='.length).trim();
      continue;
    }
  }

  if (binsPerOctant <= 0) {
    stderr.writeln('Invalid --bins value: $binsPerOctant');
    exitCode = 2;
    return;
  }
  if (maxDist16 <= 0) {
    stderr.writeln('Invalid --max-dist16 value: $maxDist16');
    exitCode = 2;
    return;
  }

  final dirCount = 8 * binsPerOctant;
  final stride = 2 * maxDist16 + 1;
  final table = Uint8List(dirCount * stride);

  final nx = Float64List(dirCount);
  final ny = Float64List(dirCount);
  for (int oct = 0; oct < 8; oct++) {
    final base = oct * (math.pi / 4.0);
    for (int b = 0; b < binsPerOctant; b++) {
      final t = (b + 0.5) / binsPerOctant;
      final ang = base + t * (math.pi / 4.0);
      final id = oct * binsPerOctant + b;
      nx[id] = math.cos(ang);
      ny[id] = math.sin(ang);
    }
  }

  for (int id = 0; id < dirCount; id++) {
    final nxx = nx[id];
    final nyy = ny[id];
    final base = id * stride;
    for (int di = -maxDist16; di <= maxDist16; di++) {
      // dist16 positivo => mais "dentro"; a LUT precisa crescer com dist16.
      final d = -di / 16.0;
      final cov = _coverageHalfPlane(nxx, nyy, d);
      final a = (cov * 255.0 + 0.5).floor().clamp(0, 255);
      table[base + (di + maxDist16)] = a;
    }
    for (int i = 1; i < stride; i++) {
      final prev = table[base + i - 1];
      final cur = table[base + i];
      if (cur < prev) {
        table[base + i] = prev;
      }
    }
  }

  final sb = StringBuffer()
    ..writeln('// GENERATED CODE - DO NOT EDIT BY HAND.')
    ..writeln('// Run: dart run tool/generate_lnaf_se_tables.dart')
    ..writeln()
    ..writeln("import 'dart:typed_data';")
    ..writeln()
    ..writeln('const int kLnafBinsPerOctant = $binsPerOctant;')
    ..writeln('const int kLnafMaxDist16 = $maxDist16;')
    ..writeln('const int kLnafDirCount = ${8 * binsPerOctant};')
    ..writeln('const int kLnafDistStride = ${2 * maxDist16 + 1};')
    ..writeln()
    ..writeln('final Uint8List kLnafCoverageTable = Uint8List.fromList(<int>[');

  const perLine = 32;
  for (int i = 0; i < table.length; i += perLine) {
    final end = (i + perLine < table.length) ? i + perLine : table.length;
    sb.writeln('  ${table.sublist(i, end).join(', ')},');
  }
  sb.writeln(']);');

  final outFile = File(outPath);
  outFile.parent.createSync(recursive: true);
  outFile.writeAsStringSync(sb.toString());

  final kib = (table.length / 1024.0).toStringAsFixed(2);
  stdout.writeln(
      'Generated $outPath (${table.length} entries, $kib KiB, bins=$binsPerOctant, maxDist16=$maxDist16)');
}

int _parseIntArg(String arg, String prefix) {
  final value = arg.substring(prefix.length).trim();
  return int.parse(value);
}

double _coverageHalfPlane(double nx, double ny, double d) {
  const x0 = -0.5, x1 = 0.5;
  const y0 = -0.5, y1 = 0.5;

  final px = Float64List(8);
  final py = Float64List(8);
  px[0] = x0;
  py[0] = y0;
  px[1] = x1;
  py[1] = y0;
  px[2] = x1;
  py[2] = y1;
  px[3] = x0;
  py[3] = y1;

  final outx = Float64List(8);
  final outy = Float64List(8);
  int outN = 0;

  double sx = px[3];
  double sy = py[3];
  double sVal = nx * sx + ny * sy - d;
  bool sIn = sVal >= 0.0;

  for (int i = 0; i < 4; i++) {
    final ex = px[i];
    final ey = py[i];
    final eVal = nx * ex + ny * ey - d;
    final eIn = eVal >= 0.0;

    if (sIn && eIn) {
      outx[outN] = ex;
      outy[outN] = ey;
      outN++;
    } else if (sIn && !eIn) {
      final t = sVal / (sVal - eVal);
      outx[outN] = sx + (ex - sx) * t;
      outy[outN] = sy + (ey - sy) * t;
      outN++;
    } else if (!sIn && eIn) {
      final t = sVal / (sVal - eVal);
      outx[outN] = sx + (ex - sx) * t;
      outy[outN] = sy + (ey - sy) * t;
      outN++;
      outx[outN] = ex;
      outy[outN] = ey;
      outN++;
    }

    sx = ex;
    sy = ey;
    sVal = eVal;
    sIn = eIn;
  }

  if (outN < 3) {
    return 0.0;
  }

  double area2 = 0.0;
  double ax = outx[outN - 1];
  double ay = outy[outN - 1];
  for (int i = 0; i < outN; i++) {
    final bx = outx[i];
    final by = outy[i];
    area2 += ax * by - bx * ay;
    ax = bx;
    ay = by;
  }

  final area = (area2.abs()) * 0.5;
  if (area <= 0.0) return 0.0;
  if (area >= 1.0) return 1.0;
  return area;
}

void _printUsage() {
  stdout.writeln('Usage: dart run tool/generate_lnaf_se_tables.dart [options]');
  stdout.writeln();
  stdout.writeln('Options:');
  stdout.writeln(
      '  --bins=<int>         bins per octant (default: $_defaultBinsPerOctant)');
  stdout.writeln(
      '  --max-dist16=<int>   distance clamp in 1/16 px (default: $_defaultMaxDist16)');
  stdout.writeln(
      '  --out=<path>         output file (default: $_defaultOutPath)');
  stdout.writeln('  -h, --help           show this help');
}
