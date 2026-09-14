import 'dart:math' as math;
import 'dart:typed_data';

import '../core/bl_types.dart';

/// Tabela de cores pré-calculada a partir dos stops de um gradiente.
///
/// Os três fetchers (linear, radial, cônico) só diferem em como chegam ao
/// parâmetro `t`; a partir daí todos consultam a mesma tabela, e antes desta
/// classe cada um carregava a sua própria cópia do mesmo código.
///
/// O tamanho **não** é fixo. Uma tabela pequena reamostra o gradiente, e o
/// que se perde nessa reamostragem é justamente a descontinuidade: um degrau
/// entre dois stops vizinhos cai dentro de uma entrada, que é interpolada, e
/// sai como uma rampa de `largura/n` pixels no device — 10 px numa página A4 a
/// 300 dpi com uma tabela de 256. O Blend2D escolhe o tamanho a partir dos
/// stops por esse motivo (`BLGradientInfo::_lut_size`), e este porte fazia
/// 256 em todos os casos.
abstract final class BLGradientLut {
  /// Menor tabela usada. Um gradiente de dois stops nas pontas é uma rampa
  /// linear, e 256 entradas já a descrevem sem erro visível.
  static const int minSize = 256;

  /// Maior tabela usada, que é também o teto do Blend2D.
  static const int maxSize = 1024;

  /// Escolhe o tamanho da tabela pelos stops, como `bl_gradient_impl_ensure_info`.
  ///
  /// A regra é do original: dois stops nas pontas descrevem uma rampa e cabem
  /// em 256; qualquer coisa mais rica precisa de mais resolução, porque cada
  /// entrada a menos é um trecho do gradiente que deixa de existir.
  static int sizeForStops(List<BLGradientStop> stops) {
    switch (stops.length) {
      case 0:
      case 1:
        return 256;
      case 2:
        // Dois stops separados por menos que o intervalo inteiro deixam
        // patamares constantes fora deles, e o degrau na borda de cada
        // patamar precisa de resolução para não virar rampa.
        final delta = stops[1].offset - stops[0].offset;
        return delta >= 0.998 ? 256 : 512;
      case 3:
        return (stops[0].offset <= 0.002 &&
                stops[1].offset == 0.5 &&
                stops[2].offset >= 0.998)
            ? 512
            : 1024;
      default:
        return 1024;
    }
  }

  /// Constrói a tabela, interpolando linearmente entre os stops.
  static Uint32List build(List<BLGradientStop> inputStops) {
    final size = sizeForStops(inputStops);
    final lut = Uint32List(size);
    if (inputStops.isEmpty) {
      lut.fillRange(0, size, 0xFF000000);
      return lut;
    }

    final stops = List<BLGradientStop>.from(inputStops)
      ..sort((a, b) => a.offset.compareTo(b.offset));

    final first = stops.first;
    final last = stops.last;

    // `seg` só anda para frente: `t` cresce com `i`, então retomar a busca de
    // zero a cada entrada custaria size * stops.length comparações — meio
    // milhão num gradiente com 1024 stops, que é o que um shading de PDF com
    // função amostrada produz.
    var seg = 0;
    for (var i = 0; i < size; i++) {
      final t = i / (size - 1);
      if (t <= first.offset) {
        lut[i] = first.color;
        continue;
      }
      if (t >= last.offset) {
        lut[i] = last.color;
        continue;
      }

      while (seg + 1 < stops.length && t > stops[seg + 1].offset) {
        seg++;
      }

      final a = stops[seg];
      final b = stops[seg + 1];
      final denom = math.max(1e-12, b.offset - a.offset);
      final u = (t - a.offset) / denom;
      lut[i] = lerpColor(a.color, b.color, u);
    }

    return lut;
  }

  static int lerpColor(int c0, int c1, double t) {
    final a0 = (c0 >>> 24) & 0xFF;
    final r0 = (c0 >>> 16) & 0xFF;
    final g0 = (c0 >>> 8) & 0xFF;
    final b0 = c0 & 0xFF;

    final a1 = (c1 >>> 24) & 0xFF;
    final r1 = (c1 >>> 16) & 0xFF;
    final g1 = (c1 >>> 8) & 0xFF;
    final b1 = c1 & 0xFF;

    final a = (a0 + (a1 - a0) * t).round().clamp(0, 255);
    final r = (r0 + (r1 - r0) * t).round().clamp(0, 255);
    final g = (g0 + (g1 - g0) * t).round().clamp(0, 255);
    final b = (b0 + (b1 - b0) * t).round().clamp(0, 255);

    return (a << 24) | (r << 16) | (g << 8) | b;
  }
}
