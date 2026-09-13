import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:dgfx/dgfx.dart';

/// Helper to create a small test image with known pixels.
BLImage _createTestImage(int w, int h) {
  final img = BLImage(w, h);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      // Each pixel encodes its position: ARGB = (0xFF, x*17, y*17, (x+y)*13)
      final r = (x * 17) & 0xFF;
      final g = (y * 17) & 0xFF;
      final b = ((x + y) * 13) & 0xFF;
      img.pixels[y * w + x] = (0xFF << 24) | (r << 16) | (g << 8) | b;
    }
  }
  return img;
}

/// Helper to create a uniform solid-color image.
BLImage _createSolidImage(int w, int h, int argb) {
  final img = BLImage(w, h);
  img.pixels.fillRange(0, w * h, argb);
  return img;
}

void main() {
  group('BLPatternFetcher - Nearest', () {
    test('identity transform returns pixel at (x,y)', () {
      final img = _createTestImage(8, 8);
      final pat = BLPattern(image: img);
      final fetcher = BLPatternFetcher(pat);

      for (int y = 0; y < 8; y++) {
        for (int x = 0; x < 8; x++) {
          expect(fetcher.fetch(x, y), img.pixels[y * 8 + x],
              reason: 'Pixel at ($x,$y)');
        }
      }
    });

    test('pad extend clamps to border', () {
      final img = _createTestImage(4, 4);
      final pat = BLPattern(
        image: img,
        extendModeX: BLGradientExtendMode.pad,
        extendModeY: BLGradientExtendMode.pad,
      );
      final fetcher = BLPatternFetcher(pat);

      // Beyond right edge: should clamp to x=3
      expect(fetcher.fetch(10, 0), img.pixels[0 * 4 + 3]);
      // Beyond bottom: should clamp to y=3
      expect(fetcher.fetch(0, 10), img.pixels[3 * 4 + 0]);
      // Before left: should clamp to x=0
      expect(fetcher.fetch(-5, 2), img.pixels[2 * 4 + 0]);
    });

    test('repeat extend wraps around', () {
      final img = _createTestImage(4, 4);
      final pat = BLPattern(
        image: img,
        extendModeX: BLGradientExtendMode.repeat,
        extendModeY: BLGradientExtendMode.repeat,
      );
      final fetcher = BLPatternFetcher(pat);

      // x=4 wraps to x=0, x=5 wraps to x=1
      expect(fetcher.fetch(4, 0), img.pixels[0 * 4 + 0]);
      expect(fetcher.fetch(5, 0), img.pixels[0 * 4 + 1]);
      // Negative wraps: x=-1 wraps to x=3
      expect(fetcher.fetch(-1, 0), img.pixels[0 * 4 + 3]);
    });

    test('reflect extend mirrors at boundary', () {
      final img = _createTestImage(4, 4);
      final pat = BLPattern(
        image: img,
        extendModeX: BLGradientExtendMode.reflect,
        extendModeY: BLGradientExtendMode.pad,
      );
      final fetcher = BLPatternFetcher(pat);

      // Within tile: normal
      expect(fetcher.fetch(0, 0), img.pixels[0]);
      expect(fetcher.fetch(3, 0), img.pixels[3]);
      // Reflected: x=4 -> period=8, x=4 -> 8-1-4=3
      expect(fetcher.fetch(4, 0), img.pixels[3]);
      // x=5 -> 8-1-5=2
      expect(fetcher.fetch(5, 0), img.pixels[2]);
      // x=7 -> 8-1-7=0
      expect(fetcher.fetch(7, 0), img.pixels[0]);
      // x=8 -> wraps to 0 (new period)
      expect(fetcher.fetch(8, 0), img.pixels[0]);
    });

    test('offset shifts sampling origin', () {
      final img = _createTestImage(4, 4);
      final pat = BLPattern(
        image: img,
        offset: const BLPoint(2.0, 1.0),
      );
      final fetcher = BLPatternFetcher(pat);

      // fetch(2,1) should sample pixel (0,0) due to offset
      expect(fetcher.fetch(2, 1), img.pixels[0]);
    });

    test('sequential affine fetch with repeat is consistent', () {
      final img = _createTestImage(8, 8);
      final pat = BLPattern(
        image: img,
        extendModeX: BLGradientExtendMode.repeat,
        extendModeY: BLGradientExtendMode.repeat,
        transform: const BLMatrix2D(0.5, 0.0, 0.0, 0.5, 0.0, 0.0),
      );
      final fetcher = BLPatternFetcher(pat);

      // Fetch a row sequentially, then fetch same row non-sequentially
      // Results should match
      final sequential = <int>[];
      for (int x = 0; x < 32; x++) {
        sequential.add(fetcher.fetch(x, 5));
      }

      // Create fresh fetcher for random access
      final fetcher2 = BLPatternFetcher(pat);
      for (int x = 0; x < 32; x++) {
        expect(fetcher2.fetch(x, 5), sequential[x],
            reason: 'Sequential vs random at x=$x');
      }
    });

    test('affine transform with repeat wraps correctly', () {
      final img = _createSolidImage(4, 4, 0xFFFF0000); // Red
      // Set pixel (0,0) to green for detection
      img.pixels[0] = 0xFF00FF00;

      final pat = BLPattern(
        image: img,
        extendModeX: BLGradientExtendMode.repeat,
        extendModeY: BLGradientExtendMode.repeat,
        // Scale 2x: every 2 canvas pixels = 1 texture pixel
        transform: const BLMatrix2D(0.5, 0.0, 0.0, 0.5, 0.0, 0.0),
      );
      final fetcher = BLPatternFetcher(pat);

      // At canvas (0,0), tex = (0,0) -> green
      expect(fetcher.fetch(0, 0), 0xFF00FF00);
      // At canvas (2,0), tex = (1,0) -> red
      expect(fetcher.fetch(2, 0), 0xFFFF0000);
    });
  });

  group('BLPatternFetcher - Bilinear', () {
    test('bilinear at integer coords matches nearest', () {
      final img = _createTestImage(8, 8);
      final patNearest = BLPattern(
        image: img,
        filter: BLPatternFilter.nearest,
      );
      final patBilinear = BLPattern(
        image: img,
        filter: BLPatternFilter.bilinear,
      );
      final fetcherN = BLPatternFetcher(patNearest);
      final fetcherB = BLPatternFetcher(patBilinear);

      // At exact integer coordinates, bilinear should closely match nearest
      // (may differ slightly due to weight rounding)
      for (int y = 0; y < 7; y++) {
        for (int x = 0; x < 7; x++) {
          final n = fetcherN.fetch(x, y);
          final b = fetcherB.fetch(x, y);
          // Check that channels are close (within 2 due to rounding)
          final nA = (n >> 24) & 0xFF;
          final bA = (b >> 24) & 0xFF;
          final nR = (n >> 16) & 0xFF;
          final bR = (b >> 16) & 0xFF;
          expect((nA - bA).abs(), lessThan(3), reason: 'Alpha at ($x,$y)');
          expect((nR - bR).abs(), lessThan(3), reason: 'Red at ($x,$y)');
        }
      }
    });

    test('bilinear produces smooth interpolation', () {
      // Create a 2x1 image: black and white
      final img = BLImage(2, 1);
      img.pixels[0] = 0xFF000000; // black
      img.pixels[1] = 0xFFFFFFFF; // white

      final pat = BLPattern(
        image: img,
        filter: BLPatternFilter.bilinear,
        extendModeX: BLGradientExtendMode.pad,
        extendModeY: BLGradientExtendMode.pad,
        // Half-pixel offset to sample between the two pixels
        offset: const BLPoint(0.5, 0.0),
      );
      final fetcher = BLPatternFetcher(pat);

      // At x=1 (shifted by +0.5 -> samples at 0.5), should be ~middle gray
      final mid = fetcher.fetch(1, 0);
      final r = (mid >> 16) & 0xFF;
      // Should be approximately 128 (halfway between 0 and 255)
      expect(r, greaterThan(100));
      expect(r, lessThan(160));
    });

    test('bilinear repeat wraps at tile boundary', () {
      final img = _createTestImage(4, 4);
      final pat = BLPattern(
        image: img,
        filter: BLPatternFilter.bilinear,
        extendModeX: BLGradientExtendMode.repeat,
        extendModeY: BLGradientExtendMode.repeat,
      );
      final fetcher = BLPatternFetcher(pat);

      // Fetching beyond the image should produce valid results (wrap)
      for (int x = 0; x < 16; x++) {
        final pixel = fetcher.fetch(x, 0);
        expect(pixel & 0xFF000000, 0xFF000000,
            reason: 'Alpha should be opaque at x=$x');
      }
    });

    test('bilinear affine sequential consistency', () {
      final img = _createTestImage(8, 8);
      final pat = BLPattern(
        image: img,
        filter: BLPatternFilter.bilinear,
        extendModeX: BLGradientExtendMode.repeat,
        extendModeY: BLGradientExtendMode.repeat,
        transform: const BLMatrix2D(0.7, 0.3, -0.3, 0.7, 2.0, 1.0),
      );
      final fetcher = BLPatternFetcher(pat);

      // Fetch row sequentially
      final row = <int>[];
      for (int x = 0; x < 20; x++) {
        row.add(fetcher.fetch(x, 3));
      }

      // Verify random access against sequential results.
      for (int x = 0; x < 20; x += 3) {
        // Force non-sequential access by creating new fetcher each time
        final fetcherSingle = BLPatternFetcher(pat);
        final a = fetcherSingle.fetch(x, 3);
        final b = row[x];
        final aA = (a >>> 24) & 0xFF;
        final bA = (b >>> 24) & 0xFF;
        final aR = (a >>> 16) & 0xFF;
        final bR = (b >>> 16) & 0xFF;
        final aG = (a >>> 8) & 0xFF;
        final bG = (b >>> 8) & 0xFF;
        final aB = a & 0xFF;
        final bB = b & 0xFF;
        expect((aA - bA).abs(), lessThanOrEqualTo(2),
            reason: 'A random vs sequential at x=$x');
        expect((aR - bR).abs(), lessThanOrEqualTo(2),
            reason: 'R random vs sequential at x=$x');
        expect((aG - bG).abs(), lessThanOrEqualTo(2),
            reason: 'G random vs sequential at x=$x');
        expect((aB - bB).abs(), lessThanOrEqualTo(2),
            reason: 'B random vs sequential at x=$x');
      }
    });
  });

  group('BLPatternFetcher - Affine Context (C++ ox/oy/rx/ry port)', () {
    test('repeat mode avoids modulo in sequential path', () {
      // This tests the C++ affine context optimization:
      // sequential pixels use branchless subtraction instead of modulo
      final img = _createTestImage(8, 8);
      final pat = BLPattern(
        image: img,
        extendModeX: BLGradientExtendMode.repeat,
        extendModeY: BLGradientExtendMode.repeat,
        transform: const BLMatrix2D(1.5, 0.0, 0.0, 1.5, 0.0, 0.0),
      );
      final fetcher = BLPatternFetcher(pat);

      // Sequential fetch across multiple tile periods
      final results = <int>[];
      for (int x = 0; x < 40; x++) {
        results.add(fetcher.fetch(x, 0));
      }

      // Verify wrap-around: pixels should be periodic
      // With scale 1.5x and tile width 8, period in canvas space = 8/1.5 ≈ 5.33
      // Within one row, all fetched pixels should be valid (non-zero alpha)
      for (int i = 0; i < results.length; i++) {
        expect(results[i] & 0xFF000000, 0xFF000000,
            reason: 'Alpha should be opaque at x=$i');
      }
    });

    test('reflect mode handles mirror correctly in sequential path', () {
      // Create a gradient-like image for easy visual verification
      final img = BLImage(4, 1);
      img.pixels[0] = 0xFF000000; // 0
      img.pixels[1] = 0xFF555555; // 1
      img.pixels[2] = 0xFFAAAAAA; // 2
      img.pixels[3] = 0xFFFFFFFF; // 3

      final pat = BLPattern(
        image: img,
        extendModeX: BLGradientExtendMode.reflect,
        extendModeY: BLGradientExtendMode.pad,
      );
      final fetcher = BLPatternFetcher(pat);

      // Expected pattern: 0,1,2,3, 3,2,1,0, 0,1,2,3, ...
      expect(fetcher.fetch(0, 0), 0xFF000000); // 0
      expect(fetcher.fetch(1, 0), 0xFF555555); // 1
      expect(fetcher.fetch(2, 0), 0xFFAAAAAA); // 2
      expect(fetcher.fetch(3, 0), 0xFFFFFFFF); // 3
      expect(fetcher.fetch(4, 0), 0xFFFFFFFF); // 3 (reflected)
      expect(fetcher.fetch(5, 0), 0xFFAAAAAA); // 2 (reflected)
      expect(fetcher.fetch(6, 0), 0xFF555555); // 1 (reflected)
      expect(fetcher.fetch(7, 0), 0xFF000000); // 0 (reflected)
      expect(fetcher.fetch(8, 0), 0xFF000000); // 0 (new period)
    });

    test('large affine rotation with repeat produces valid pixels', () {
      final img = _createTestImage(16, 16);
      // 45-degree rotation
      final cos45 = 0.7071;
      final sin45 = 0.7071;
      final pat = BLPattern(
        image: img,
        extendModeX: BLGradientExtendMode.repeat,
        extendModeY: BLGradientExtendMode.repeat,
        filter: BLPatternFilter.nearest,
        transform: BLMatrix2D(cos45, sin45, -sin45, cos45, 0.0, 0.0),
      );
      final fetcher = BLPatternFetcher(pat);

      // Fetch a full scanline
      for (int x = 0; x < 64; x++) {
        final pixel = fetcher.fetch(x, 10);
        // Should always produce valid opaque pixels
        expect(pixel & 0xFF000000, 0xFF000000,
            reason: 'Alpha at x=$x should be opaque');
      }
    });

    test('pad mode leaves coordinates unnormalized', () {
      final img = _createTestImage(4, 4);
      final pat = BLPattern(
        image: img,
        extendModeX: BLGradientExtendMode.pad,
        extendModeY: BLGradientExtendMode.pad,
        transform: const BLMatrix2D(2.0, 0.0, 0.0, 2.0, 0.0, 0.0),
      );
      final fetcher = BLPatternFetcher(pat);

      // Far outside: should clamp to border.
      //
      // A matriz escala por 2, isto é, REDUZ: cada pixel de device cobre dois
      // texels em cada eixo e o fetcher integra a área. Na borda um dos eixos
      // já colapsou no clamp, então sobra a média dos dois texels do outro.
      int media2(int p, int q) {
        int canal(int shift) =>
            ((((p >>> shift) & 0xFF) + ((q >>> shift) & 0xFF)) / 2).round();
        return (canal(24) << 24) |
            (canal(16) << 16) |
            (canal(8) << 8) |
            canal(0);
      }

      expect(fetcher.fetch(100, 0),
          media2(img.pixels[0 * 4 + 3], img.pixels[1 * 4 + 3]));
      expect(fetcher.fetch(0, 100),
          media2(img.pixels[3 * 4 + 0], img.pixels[3 * 4 + 1]));
    });
  });

  // Nem nearest nem bilinear servem para REDUZIR: amostrar um texel (ou
  // quatro) descarta a maioria dos pixels de origem e o que sobra vira moiré.
  // Isso atinge o consumidor direto — uma digitalização de 300 dpi numa página
  // renderizada a 96 dpi passa exatamente por aqui.
  group('BLPatternFetcher - redução', () {
    BLImage checkerboard(int size) {
      final img = BLImage(size, size);
      for (int y = 0; y < size; y++) {
        for (int x = 0; x < size; x++) {
          img.pixels[y * size + x] =
              ((x + y) & 1) == 0 ? 0xFF000000 : 0xFFFFFFFF;
        }
      }
      return img;
    }

    int red(int argb) => (argb >> 16) & 0xFF;

    test('xadrez de 1 px reduzido à metade dá cinza uniforme', () {
      final img = checkerboard(16);
      for (final filter in BLPatternFilter.values) {
        final fetcher = BLPatternFetcher(BLPattern(
          image: img,
          filter: filter,
          transform: BLMatrix2D.scaling(2.0, 2.0),
        ));
        for (int y = 0; y < 8; y++) {
          for (int x = 0; x < 8; x++) {
            expect(red(fetcher.fetch(x, y)), closeTo(128, 1),
                reason: '\$filter em (\$x,\$y)');
          }
        }
      }
    });

    test('o ponto isolado daria preto sólido, não cinza', () {
      // Prova de que o teste acima mede alguma coisa. Amostrar um texel a cada
      // dois num xadrez de 1 px cai sempre na mesma fase: o resultado seria
      // preto chapado, com o xadrez inteiro desaparecido. Esse é o alias que o
      // filtro de caixa evita — e com uma redução só ligeiramente diferente de
      // 2x a fase caminha e vira moiré.
      final img = checkerboard(16);
      final pontual = <int>[
        for (int x = 0; x < 8; x++) red(img.pixels[2 * x]),
      ];
      expect(pontual.toSet(), <int>{0});
    });

    test('redução de 4x continua uniforme', () {
      final img = checkerboard(32);
      final fetcher = BLPatternFetcher(BLPattern(
        image: img,
        transform: BLMatrix2D.scaling(4.0, 4.0),
      ));
      for (int y = 0; y < 8; y++) {
        for (int x = 0; x < 8; x++) {
          expect(red(fetcher.fetch(x, y)), closeTo(128, 1));
        }
      }
    });

    test('redução só em x deixa as colunas cinzas e as linhas intactas', () {
      // Faixas verticais de 1 px: reduzir só em x tem que apagá-las.
      final img = BLImage(16, 4);
      for (int y = 0; y < 4; y++) {
        for (int x = 0; x < 16; x++) {
          img.pixels[y * 16 + x] = (x & 1) == 0 ? 0xFF000000 : 0xFFFFFFFF;
        }
      }
      final fetcher = BLPatternFetcher(BLPattern(
        image: img,
        transform: BLMatrix2D.scaling(2.0, 1.0),
      ));
      for (int y = 0; y < 4; y++) {
        for (int x = 0; x < 8; x++) {
          expect(red(fetcher.fetch(x, y)), closeTo(128, 1));
        }
      }
    });

    test('1:1 e ampliação não passam pelo filtro de caixa', () {
      final img = checkerboard(8);
      final identidade = BLPatternFetcher(BLPattern(image: img));
      for (int y = 0; y < 8; y++) {
        for (int x = 0; x < 8; x++) {
          expect(identidade.fetch(x, y), img.pixels[y * 8 + x]);
        }
      }

      // Ampliar em 2x com nearest continua devolvendo o texel exato.
      final ampliado = BLPatternFetcher(BLPattern(
        image: img,
        transform: BLMatrix2D.scaling(0.5, 0.5),
      ));
      expect(ampliado.fetch(0, 0), img.pixels[0]);
      expect(ampliado.fetch(1, 0), img.pixels[0]);
      expect(ampliado.fetch(2, 0), img.pixels[1]);
    });

    test('rotação pura não dispara o filtro', () {
      // Determinante 1 e nenhuma redução: girar não deve borrar.
      final img = checkerboard(8);
      final fetcher = BLPatternFetcher(BLPattern(
        image: img,
        transform: BLMatrix2D.rotation(math.pi / 2),
      ));
      final v = fetcher.fetch(3, 3);
      expect(red(v) == 0 || red(v) == 255, isTrue);
    });

    // Um ladrilho de PDF é rasterizado num bitmap de tamanho inteiro e depois
    // remapeado, o que dá fatores como 1,07 sem que ninguém tenha pedido
    // redução. Borrar as bordas do ladrilho aí é regressão: a célula tem que
    // sair idêntica ao bitmap de origem.
    test('ladrilho repetido em 1:1 sai idêntico ao bitmap de origem', () {
      final img = checkerboard(8);
      for (final filter in BLPatternFilter.values) {
        final fetcher = BLPatternFetcher(BLPattern(
          image: img,
          filter: filter,
          extendModeX: BLGradientExtendMode.repeat,
          extendModeY: BLGradientExtendMode.repeat,
        ));
        for (int y = 0; y < 24; y++) {
          for (int x = 0; x < 24; x++) {
            if (filter == BLPatternFilter.nearest) {
              expect(fetcher.fetch(x, y), img.pixels[(y % 8) * 8 + (x % 8)],
                  reason: '\$filter em (\$x,\$y)');
            } else {
              // Bilinear em 1:1 e offset inteiro cai sobre o texel exato.
              expect(fetcher.fetch(x, y), img.pixels[(y % 8) * 8 + (x % 8)],
                  reason: '\$filter em (\$x,\$y)');
            }
          }
        }
      }
    });

    test('eixo y invertido em 1:1 não desloca um texel', () {
      // O ladrilho de PDF chega com m11 negativo. O caminho de caixa é
      // ancorado para frente justamente para casar com o `floor` do nearest.
      final img = BLImage(4, 4);
      for (int i = 0; i < 16; i++) {
        img.pixels[i] = 0xFF000000 | (i * 0x010101);
      }
      final espelhado = BLPatternFetcher(BLPattern(
        image: img,
        extendModeX: BLGradientExtendMode.repeat,
        extendModeY: BLGradientExtendMode.repeat,
        transform: const BLMatrix2D(1.0, 0.0, 0.0, -1.0, 0.0, 4.0),
      ));
      for (int y = 0; y < 4; y++) {
        for (int x = 0; x < 4; x++) {
          final sy = (4 - y) % 4;
          expect(espelhado.fetch(x, y), img.pixels[sy * 4 + x],
              reason: '(\$x,\$y)');
        }
      }
    });

    test('redução marginal não liga o filtro', () {
      // 1,07x é o que sobra de rasterizar um ladrilho em tamanho inteiro; não
      // é redução de verdade e não pode borrar.
      final img = checkerboard(8);
      final fetcher = BLPatternFetcher(BLPattern(
        image: img,
        extendModeX: BLGradientExtendMode.repeat,
        extendModeY: BLGradientExtendMode.repeat,
        transform: const BLMatrix2D(8 / 7.5, 0.0, 0.0, 1.0, 0.0, 0.0),
      ));
      for (int x = 0; x < 16; x++) {
        final v = red(fetcher.fetch(x, 0));
        expect(v == 0 || v == 255, isTrue, reason: 'x=\$x deu \$v');
      }
    });

    test('a média respeita o alfa junto com a cor', () {
      final img = BLImage(2, 1);
      img.pixels[0] = 0x00000000;
      img.pixels[1] = 0xFFFFFFFF;
      final fetcher = BLPatternFetcher(BLPattern(
        image: img,
        transform: BLMatrix2D.scaling(2.0, 1.0),
      ));
      final v = fetcher.fetch(0, 0);
      expect((v >> 24) & 0xFF, closeTo(128, 1));
      expect(red(v), closeTo(128, 1));
    });
  });
}
