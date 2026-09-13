import 'dart:typed_data';

import 'package:dgfx/dgfx.dart';
import 'package:test/test.dart';

int _a(int c) => (c >>> 24) & 0xFF;
int _r(int c) => (c >>> 16) & 0xFF;
int _g(int c) => (c >>> 8) & 0xFF;
int _b(int c) => c & 0xFF;

String _hex(int c) => '0x${c.toRadixString(16).padLeft(8, '0')}';

/// Verifica um pixel canal a canal, com tolerância.
void expectColor(int actual, int expected, {int tolerance = 2}) {
  final ok = (_a(actual) - _a(expected)).abs() <= tolerance &&
      (_r(actual) - _r(expected)).abs() <= tolerance &&
      (_g(actual) - _g(expected)).abs() <= tolerance &&
      (_b(actual) - _b(expected)).abs() <= tolerance;
  expect(ok, isTrue,
      reason: 'esperava ${_hex(expected)} (±$tolerance), veio ${_hex(actual)}');
}

void main() {
  group('BLGouraudFetcher', () {
    test('devolve a cor do vértice no próprio vértice', () {
      // O fetcher amostra o centro do pixel, então avaliamos o plano contínuo
      // exatamente nas coordenadas dos vértices.
      final f = BLGouraudFetcher(
        0, 0, 0xFFFF0000, //
        100, 0, 0xFF00FF00, //
        0, 100, 0xFF0000FF,
      );
      expectColor(f.evaluate(0, 0), 0xFFFF0000);
      expectColor(f.evaluate(100, 0), 0xFF00FF00);
      expectColor(f.evaluate(0, 100), 0xFF0000FF);
    });

    test('interpola linearmente no meio de uma aresta', () {
      final f = BLGouraudFetcher(
        0, 0, 0xFF000000, //
        100, 0, 0xFFFFFFFF, //
        0, 100, 0xFF000000,
      );
      // Meio da aresta 0-1: metade do caminho entre 0 e 255.
      final mid = f.evaluate(50, 0);
      expect(_r(mid), inInclusiveRange(126, 129));
      expect(_g(mid), inInclusiveRange(126, 129));
      expect(_b(mid), inInclusiveRange(126, 129));
      // Um quarto do caminho.
      expect(_r(f.evaluate(25, 0)), inInclusiveRange(62, 65));
    });

    test('o gradiente é constante: a cor é uma função afim de (x, y)', () {
      final f = BLGouraudFetcher(
        10, 10, 0xFF102030, //
        210, 10, 0xFFF02030, //
        10, 210, 0xFF10F030,
      );
      // d/dx do canal vermelho: (0xF0 - 0x10) / 200 por pixel.
      for (final y in const [10.0, 60.0, 150.0]) {
        final at0 = _r(f.evaluate(10, y));
        final at100 = _r(f.evaluate(110, y));
        final at200 = _r(f.evaluate(210, y));
        expect(at100 - at0, inInclusiveRange(111, 113));
        expect(at200 - at100, inInclusiveRange(111, 113));
      }
    });

    test('triângulo degenerado vira a média das três cores', () {
      final f = BLGouraudFetcher(
        5, 5, 0xFF000000, //
        5, 5, 0xFF303030, //
        5, 5, 0xFF606060,
      );
      expectColor(f.evaluate(5, 5), 0xFF303030, tolerance: 1);
      expectColor(f.evaluate(900, -12), 0xFF303030, tolerance: 1);
    });

    test('alfas diferentes interpolam em espaço pré-multiplicado', () {
      // Do branco opaco ao branco totalmente transparente: o alfa cai
      // linearmente e a cor reta continua branca em todo o caminho, em vez de
      // escurecer na direção do vértice transparente.
      final f = BLGouraudFetcher(
        0, 0, 0xFFFFFFFF, //
        100, 0, 0x00FFFFFF, //
        0, 100, 0xFFFFFFFF,
      );
      final mid = f.evaluate(50, 0);
      expect(_a(mid), inInclusiveRange(126, 129));
      expect(_r(mid), inInclusiveRange(250, 255));
      expect(_g(mid), inInclusiveRange(250, 255));
      expect(_b(mid), inInclusiveRange(250, 255));
    });

    test('fetch amostra o centro do pixel', () {
      final f = BLGouraudFetcher(
        0, 0, 0xFF000000, //
        256, 0, 0xFFFF0000, //
        0, 256, 0xFF000000,
      );
      // O centro do pixel 0 está em x = 0.5.
      expect(_r(f.fetch(0, 0)), _r(f.evaluate(0.5, 0.5)));
      expect(_r(f.fetch(100, 0)), _r(f.evaluate(100.5, 0.5)));
    });
  });

  group('BLContext.fillTriangleGouraud', () {
    test('pinta cada canto com a cor do vértice correspondente', () async {
      final image = BLImage(64, 64);
      final ctx = BLContext(image)..clear(0xFF000000);
      await ctx.fillTriangleGouraud(
        2, 2, 0xFFFF0000, //
        60, 2, 0xFF00FF00, //
        2, 60, 0xFF0000FF,
      );
      ctx.flush();

      int px(int x, int y) => image.pixels[y * 64 + x];

      // Perto do vértice vermelho.
      final nearRed = px(6, 6);
      expect(_r(nearRed), greaterThan(200));
      expect(_g(nearRed), lessThan(60));
      expect(_b(nearRed), lessThan(60));

      // Perto do vértice verde.
      final nearGreen = px(54, 5);
      expect(_g(nearGreen), greaterThan(190));
      expect(_r(nearGreen), lessThan(70));

      // Perto do vértice azul.
      final nearBlue = px(5, 54);
      expect(_b(nearBlue), greaterThan(190));
      expect(_r(nearBlue), lessThan(70));

      // Fora do triângulo continua preto.
      expect(px(60, 60), 0xFF000000);
    });

    test('a média das três cores aparece no centroide', () async {
      final image = BLImage(64, 64);
      final ctx = BLContext(image)..clear(0xFF000000);
      await ctx.fillTriangleGouraud(
        1, 1, 0xFFFF0000, //
        62, 1, 0xFF00FF00, //
        1, 62, 0xFF0000FF,
      );
      ctx.flush();
      // Centroide de (1,1), (62,1), (1,62) ≈ (21.3, 21.3); no centroide as
      // três baricêntricas valem 1/3.
      final c = image.pixels[21 * 64 + 21];
      expect(_r(c), inInclusiveRange(70, 105));
      expect(_g(c), inInclusiveRange(70, 105));
      expect(_b(c), inInclusiveRange(70, 105));
    });

    test('respeita a transformação corrente', () async {
      final a = BLImage(64, 64);
      final actx = BLContext(a)..clear(0xFF000000);
      await actx.fillTriangleGouraud(
        4, 4, 0xFFFF0000, //
        40, 4, 0xFF00FF00, //
        4, 40, 0xFF0000FF,
      );
      actx.flush();

      final b = BLImage(64, 64);
      final bctx = BLContext(b)..clear(0xFF000000);
      bctx.translate(10, 6);
      await bctx.fillTriangleGouraud(
        -6, -2, 0xFFFF0000, //
        30, -2, 0xFF00FF00, //
        -6, 34, 0xFF0000FF,
      );
      bctx.flush();

      expect(b.pixels, orderedEquals(a.pixels));
    });

    test('respeita globalAlpha', () async {
      final image = BLImage(32, 32);
      final ctx = BLContext(image)..clear(0xFF000000);
      ctx.globalAlpha = 0.5;
      await ctx.fillTriangleGouraud(
        0, 0, 0xFFFFFFFF, //
        31, 0, 0xFFFFFFFF, //
        0, 31, 0xFFFFFFFF,
      );
      ctx.flush();
      final c = image.pixels[4 * 32 + 4];
      // Branco a 50% sobre preto.
      expect(_r(c), inInclusiveRange(120, 135));
    });

    test('respeita o clip retangular', () async {
      final image = BLImage(64, 64);
      final ctx = BLContext(image)..clear(0xFF000000);
      ctx.clipToRect(const BLRectI(0, 0, 20, 64));
      await ctx.fillTriangleGouraud(
        2, 2, 0xFFFFFFFF, //
        60, 2, 0xFFFFFFFF, //
        2, 60, 0xFFFFFFFF,
      );
      ctx.flush();
      expect(_r(image.pixels[10 * 64 + 10]), greaterThan(200));
      expect(image.pixels[4 * 64 + 40], 0xFF000000);
    });
  });

  group('BLContext.fillTriangleMesh', () {
    /// Dois triângulos formando o quadrado [0,size) x [0,size), com cores
    /// constantes: o teste do seam.
    (Float64List, Uint32List, Int32List) quad(double size, int color) {
      final xy = Float64List.fromList([0, 0, size, 0, size, size, 0, size]);
      final colors = Uint32List.fromList([color, color, color, color]);
      final indices = Int32List.fromList([0, 1, 2, 0, 2, 3]);
      return (xy, colors, indices);
    }

    test('a diagonal compartilhada não deixa costura', () async {
      final image = BLImage(32, 32);
      final ctx = BLContext(image)..clear(0xFF000000);
      final (xy, colors, indices) = quad(32, 0xFFFFFFFF);
      await ctx.fillTriangleMesh(xy, colors, indices);
      ctx.flush();

      // Toda a diagonal (a aresta interna) tem de sair branca cheia. Com um
      // fill por triângulo, cada lado contribuiria ~50% de cobertura e a
      // diagonal sairia cinza.
      for (int i = 1; i < 31; i++) {
        final c = image.pixels[i * 32 + i];
        expect(c, 0xFFFFFFFF,
            reason: 'costura na diagonal em ($i, $i): ${_hex(c)}');
      }
    });

    test('desenhar triângulo a triângulo DEIXA a costura (contraprova)',
        () async {
      final image = BLImage(32, 32);
      final ctx = BLContext(image)..clear(0xFF000000);
      await ctx.fillTriangleGouraud(
        0, 0, 0xFFFFFFFF, //
        32, 0, 0xFFFFFFFF, //
        32, 32, 0xFFFFFFFF,
      );
      await ctx.fillTriangleGouraud(
        0, 0, 0xFFFFFFFF, //
        32, 32, 0xFFFFFFFF, //
        0, 32, 0xFFFFFFFF,
      );
      ctx.flush();

      // Se isto passar a dar branco cheio, o problema que fillTriangleMesh
      // resolve deixou de existir e este teste pode ir embora.
      var seamPixels = 0;
      for (int i = 1; i < 31; i++) {
        if (image.pixels[i * 32 + i] != 0xFFFFFFFF) seamPixels++;
      }
      expect(seamPixels, greaterThan(20),
          reason: 'a costura triângulo-a-triângulo sumiu sozinha');
    });

    test('orientação mista continua sem costura', () async {
      final image = BLImage(32, 32);
      final ctx = BLContext(image)..clear(0xFF000000);
      final xy = Float64List.fromList([0, 0, 32, 0, 32, 32, 0, 32]);
      final colors =
          Uint32List.fromList([0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF]);
      // Segundo triângulo com a orientação invertida de propósito.
      final indices = Int32List.fromList([0, 1, 2, 3, 2, 0]);
      await ctx.fillTriangleMesh(xy, colors, indices);
      ctx.flush();
      for (int i = 1; i < 31; i++) {
        expect(image.pixels[i * 32 + i], 0xFFFFFFFF);
      }
    });

    test('interpola a cor por vértice através da malha inteira', () async {
      final image = BLImage(64, 64);
      final ctx = BLContext(image)..clear(0xFF000000);
      // Preto à esquerda, branco à direita, nos dois triângulos.
      final xy = Float64List.fromList([0, 0, 64, 0, 64, 64, 0, 64]);
      final colors =
          Uint32List.fromList([0xFF000000, 0xFFFFFFFF, 0xFFFFFFFF, 0xFF000000]);
      final indices = Int32List.fromList([0, 1, 2, 0, 2, 3]);
      await ctx.fillTriangleMesh(xy, colors, indices);
      ctx.flush();

      int lum(int x, int y) => _r(image.pixels[y * 64 + x]);

      // Rampa monótona em x, igual nas duas metades (acima e abaixo da
      // diagonal), o que só acontece se os dois triângulos concordarem.
      for (final y in const [8, 32, 56]) {
        int prev = -1;
        for (int x = 1; x < 63; x++) {
          final v = lum(x, y);
          expect(v, greaterThanOrEqualTo(prev - 1),
              reason: 'rampa não monótona em ($x, $y)');
          prev = v;
        }
      }
      expect(lum(2, 32), lessThan(20));
      expect(lum(61, 32), greaterThan(235));
      // A mesma coluna tem a mesma cor nas duas metades do quadrado.
      expect((lum(32, 8) - lum(32, 56)).abs(), lessThanOrEqualTo(4));
    });

    test('sem indices, xy é lido como triângulos soltos', () async {
      final image = BLImage(32, 32);
      final ctx = BLContext(image)..clear(0xFF000000);
      final xy = Float64List.fromList([2, 2, 30, 2, 2, 30]);
      final colors = Uint32List.fromList([0xFFFF0000, 0xFFFF0000, 0xFFFF0000]);
      await ctx.fillTriangleMesh(xy, colors);
      ctx.flush();
      expect(image.pixels[8 * 32 + 8], 0xFFFF0000);
      expect(image.pixels[28 * 32 + 28], 0xFF000000);
    });

    test('respeita a transformação corrente', () async {
      final a = BLImage(48, 48);
      final actx = BLContext(a)..clear(0xFF000000);
      final xy = Float64List.fromList([4, 4, 40, 4, 40, 40, 4, 40]);
      final colors =
          Uint32List.fromList([0xFFFF0000, 0xFF00FF00, 0xFF0000FF, 0xFFFFFF00]);
      final indices = Int32List.fromList([0, 1, 2, 0, 2, 3]);
      await actx.fillTriangleMesh(xy, colors, indices);
      actx.flush();

      final b = BLImage(48, 48);
      final bctx = BLContext(b)..clear(0xFF000000);
      bctx.translate(4, 4);
      final xy2 = Float64List.fromList([0, 0, 36, 0, 36, 36, 0, 36]);
      await bctx.fillTriangleMesh(xy2, colors, indices);
      bctx.flush();

      expect(b.pixels, orderedEquals(a.pixels));
    });

    test('respeita a máscara de clip por caminho', () async {
      final image = BLImage(48, 48);
      final ctx = BLContext(image)..clear(0xFF000000);
      ctx.clipToPath(BLPath()
        ..moveTo(0, 0)
        ..lineTo(16, 0)
        ..lineTo(16, 48)
        ..lineTo(0, 48)
        ..close());
      final xy = Float64List.fromList([0, 0, 48, 0, 48, 48, 0, 48]);
      final colors =
          Uint32List.fromList([0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF]);
      final indices = Int32List.fromList([0, 1, 2, 0, 2, 3]);
      await ctx.fillTriangleMesh(xy, colors, indices);
      ctx.flush();

      expect(image.pixels[24 * 48 + 8], 0xFFFFFFFF);
      expect(image.pixels[24 * 48 + 40], 0xFF000000);
    });

    test('malha vazia e argumentos inconsistentes', () async {
      final image = BLImage(16, 16);
      final ctx = BLContext(image)..clear(0xFF000000);

      await ctx.fillTriangleMesh(Float64List(0), Uint32List(0));
      ctx.flush();
      expect(image.pixels.every((p) => p == 0xFF000000), isTrue);

      expect(
        () => BLGouraudMeshFetcher(
          Float64List.fromList([0, 0, 1, 0, 1, 1]),
          Uint32List.fromList([0xFFFFFFFF]),
        ),
        throwsArgumentError,
      );
      expect(
        () => BLGouraudMeshFetcher(
          Float64List.fromList([0, 0, 1, 0, 1, 1]),
          Uint32List.fromList([1, 2, 3]),
          Int32List.fromList([0, 1]),
        ),
        throwsArgumentError,
      );
      expect(
        () => BLGouraudMeshFetcher(
          Float64List.fromList([0, 0, 1, 0, 1, 1]),
          Uint32List.fromList([1, 2, 3]),
          Int32List.fromList([0, 1, 7]),
        ),
        throwsArgumentError,
      );
    });

    test('o caminho incremental concorda com a avaliação direta', () {
      // fetch() avança as baricêntricas e os canais por soma enquanto x é
      // consecutivo; colorAt() reavalia do zero. Os dois têm de dar a mesma
      // cor, senão o caminho rápido está mentindo.
      const n = 5;
      final verts = <double>[];
      final cols = <int>[];
      for (int j = 0; j <= n; j++) {
        for (int i = 0; i <= n; i++) {
          verts.add(3 + i * 40 / n);
          verts.add(3 + j * 40 / n);
          cols.add(0xFF000000 |
              ((i * 255 ~/ n) << 16) |
              ((j * 255 ~/ n) << 8) |
              ((i * j * 255 ~/ (n * n))));
        }
      }
      final idx = <int>[];
      for (int j = 0; j < n; j++) {
        for (int i = 0; i < n; i++) {
          final a = j * (n + 1) + i;
          idx.addAll([a, a + 1, a + n + 2, a, a + n + 2, a + n + 1]);
        }
      }
      final mesh = BLGouraudMeshFetcher(
        Float64List.fromList(verts),
        Uint32List.fromList(cols),
        Int32List.fromList(idx),
      );

      // Varredura sequencial, que é como o rasterizador chama. A malha cobre
      // [3, 43); fora dela os dois caminhos extrapolam a partir do triângulo
      // "mais próximo", e qual deles é o mais próximo é uma escolha de
      // desempate sem resposta canônica — a comparação só faz sentido dentro.
      var checked = 0;
      for (int y = 0; y < 48; y++) {
        for (int x = 0; x < 48; x++) {
          final fast = mesh.fetch(x, y);
          if (x < 4 || x > 41 || y < 4 || y > 41) continue;
          expectColor(fast, mesh.colorAt(x + 0.5, y + 0.5), tolerance: 0);
          checked++;
        }
      }
      expect(checked, greaterThan(1000));
    });

    test('uma malha grande sai numa passada só do rasterizador', () async {
      // 16x16 células => 512 triângulos, a ordem de grandeza de um patch de
      // Coons subdividido. O ponto é que isto é UMA chamada.
      const n = 16;
      const size = 128.0;
      final verts = <double>[];
      final cols = <int>[];
      for (int j = 0; j <= n; j++) {
        for (int i = 0; i <= n; i++) {
          verts.add(i * size / n);
          verts.add(j * size / n);
          final t = (i * 255 ~/ n);
          cols.add(0xFF000000 | (t << 16) | (t << 8) | t);
        }
      }
      final idx = <int>[];
      for (int j = 0; j < n; j++) {
        for (int i = 0; i < n; i++) {
          final a = j * (n + 1) + i;
          final b = a + 1;
          final c = a + (n + 1);
          final d = c + 1;
          idx.addAll([a, b, d, a, d, c]);
        }
      }

      final image = BLImage(128, 128);
      final ctx = BLContext(image)..clear(0xFF000000);
      await ctx.fillTriangleMesh(
        Float64List.fromList(verts),
        Uint32List.fromList(cols),
        Int32List.fromList(idx),
      );
      ctx.flush();

      // Nenhuma linha de grade: a coluna x é a mesma cor em toda a altura, e
      // a rampa horizontal é monótona.
      for (int x = 2; x < 126; x++) {
        final top = _r(image.pixels[8 * 128 + x]);
        final bottom = _r(image.pixels[120 * 128 + x]);
        expect((top - bottom).abs(), lessThanOrEqualTo(2),
            reason: 'coluna $x variou com y: $top vs $bottom');
      }
      int prev = -1;
      for (int x = 2; x < 126; x++) {
        final v = _r(image.pixels[64 * 128 + x]);
        expect(v, greaterThanOrEqualTo(prev - 1));
        prev = v;
      }
      expect(_r(image.pixels[64 * 128 + 4]), lessThan(30));
      expect(_r(image.pixels[64 * 128 + 124]), greaterThan(225));
    });
  });
}
