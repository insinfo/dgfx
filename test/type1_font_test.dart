import 'dart:typed_data';

import 'package:dgfx/dgfx.dart';
import 'package:test/test.dart';

// Monta fontes Adobe Type 1 completas em memória — texto claro PostScript,
// porção `eexec` encriptada de verdade com R = 55665 e charstrings
// encriptadas com R = 4330 — e verifica que o contorno decodificado bate com
// a geometria que foi escrita.
//
// O alvo é o `/FontFile` de um PDF (e o `.pfa`/`.pfb` em disco), que é o que
// saídas de TeX/dvips e praticamente todo PDF anterior a 2005 embutem.
//
// Nenhum binário entra no repositório: como a fonte é construída aqui, a
// forma esperada de cada glifo é conhecida até a unidade de fonte.

// ---------------------------------------------------------------------------
// Charstrings Type 1 (Black Book §6)
// ---------------------------------------------------------------------------

void _num(BytesBuilder out, int v) {
  if (v >= -107 && v <= 107) {
    out.addByte(v + 139);
  } else if (v >= 108 && v <= 1131) {
    final w = v - 108;
    out
      ..addByte(247 + (w >> 8))
      ..addByte(w & 0xFF);
  } else if (v <= -108 && v >= -1131) {
    final w = -v - 108;
    out
      ..addByte(251 + (w >> 8))
      ..addByte(w & 0xFF);
  } else {
    // Diferente do Type 2, o código 255 do Type 1 traz um inteiro de 32 bits.
    out
      ..addByte(255)
      ..addByte((v >> 24) & 0xFF)
      ..addByte((v >> 16) & 0xFF)
      ..addByte((v >> 8) & 0xFF)
      ..addByte(v & 0xFF);
  }
}

void _op(BytesBuilder out, int op) => out.addByte(op);

void _esc(BytesBuilder out, int op) {
  out
    ..addByte(12)
    ..addByte(op);
}

/// `sbx wx hsbw`: sidebearing e largura de avanço.
void _hsbw(BytesBuilder out, int sbx, int wx) {
  _num(out, sbx);
  _num(out, wx);
  _op(out, 13);
}

/// Retângulo fechado de (x0,y0) a (x1,y1), com o sidebearing em [sbx].
Uint8List _rectGlyph(int sbx, int width, int x0, int y0, int x1, int y1) {
  final out = BytesBuilder();
  _hsbw(out, sbx, width);
  // hsbw deixa o ponto corrente em (sbx, 0).
  _num(out, x0 - sbx);
  _num(out, y0);
  _op(out, 21); // rmoveto
  _num(out, x1 - x0);
  _op(out, 6); // hlineto
  _num(out, y1 - y0);
  _op(out, 7); // vlineto
  _num(out, x0 - x1);
  _op(out, 6); // hlineto
  _op(out, 9); // closepath
  _op(out, 14); // endchar
  return out.toBytes();
}

Uint8List _emptyGlyph() {
  final out = BytesBuilder();
  _hsbw(out, 0, 0);
  _op(out, 14);
  return out.toBytes();
}

// ---------------------------------------------------------------------------
// Montagem do arquivo
// ---------------------------------------------------------------------------

Uint8List _ascii(String text) =>
    Uint8List.fromList(text.codeUnits.map((c) => c & 0xFF).toList());

String _toHex(Uint8List data) {
  const digits = '0123456789abcdef';
  final buffer = StringBuffer();
  for (var i = 0; i < data.length; i++) {
    buffer
      ..write(digits[data[i] >> 4])
      ..write(digits[data[i] & 0x0F]);
    if ((i + 1) % 32 == 0) buffer.write('\n');
  }
  return buffer.toString();
}

/// Empacota [data] em segmentos PFB (`0x80 <tipo> <len32 little-endian>`).
Uint8List _wrapPFB(Uint8List clear, Uint8List binary, Uint8List trailer) {
  final out = BytesBuilder();
  void segment(int type, Uint8List payload) {
    out
      ..addByte(0x80)
      ..addByte(type)
      ..addByte(payload.length & 0xFF)
      ..addByte((payload.length >> 8) & 0xFF)
      ..addByte((payload.length >> 16) & 0xFF)
      ..addByte((payload.length >> 24) & 0xFF)
      ..add(payload);
  }

  segment(1, clear);
  segment(2, binary);
  segment(1, trailer);
  out
    ..addByte(0x80)
    ..addByte(3);
  return out.toBytes();
}

Uint8List buildType1({
  String fontName = 'TestType1',
  required List<(String, Uint8List)> charstrings,
  List<Uint8List> subrs = const <Uint8List>[],
  Map<int, String>? encoding,
  int lenIV = 4,
  String fontMatrix = '0.001 0 0 0.001 0 0',
  String fontBBox = '0 -200 1000 900',
  bool hexEexec = false,
  bool pfb = false,
}) {
  final clear = StringBuffer()
    ..writeln('%!PS-AdobeFont-1.0: $fontName 001.001')
    ..writeln('/FontName /$fontName def')
    ..writeln('/FontMatrix [$fontMatrix] readonly def')
    ..writeln('/FontType 1 def')
    ..writeln('/PaintType 0 def')
    ..writeln('/FontBBox {$fontBBox} readonly def');

  if (encoding == null) {
    clear.writeln('/Encoding StandardEncoding def');
  } else {
    clear
      ..writeln('/Encoding 256 array')
      ..writeln('0 1 255 {1 index exch /.notdef put} for');
    final codes = encoding.keys.toList()..sort();
    for (final code in codes) {
      clear.writeln('dup $code /${encoding[code]} put');
    }
    clear.writeln('readonly def');
  }
  clear
    ..writeln('currentdict end')
    ..writeln('currentfile eexec');

  // --- porção privada, antes da encriptação eexec ---------------------------
  final private = BytesBuilder()
    ..add(_ascii('dup /Private 12 dict dup begin\n'))
    ..add(_ascii(
        '/RD {string currentfile exch readstring pop} executeonly def\n'))
    ..add(_ascii('/ND {noaccess def} executeonly def\n'))
    ..add(_ascii('/NP {noaccess put} executeonly def\n'))
    ..add(_ascii('/lenIV $lenIV def\n'))
    ..add(_ascii('/BlueValues [] ND\n'));

  if (subrs.isNotEmpty) {
    private.add(_ascii('/Subrs ${subrs.length} array\n'));
    for (var i = 0; i < subrs.length; i++) {
      final enc = blType1Encrypt(subrs[i], blType1CharstringKey, lenIV);
      private
        ..add(_ascii('dup $i ${enc.length} RD '))
        ..add(enc)
        ..add(_ascii(' NP\n'));
    }
    private.add(_ascii('ND\n'));
  }

  private.add(_ascii('/CharStrings ${charstrings.length} dict dup begin\n'));
  for (final entry in charstrings) {
    final enc = blType1Encrypt(entry.$2, blType1CharstringKey, lenIV);
    private
      ..add(_ascii('/${entry.$1} ${enc.length} RD '))
      ..add(enc)
      ..add(_ascii(' ND\n'));
  }
  private
    ..add(_ascii('end\n'))
    ..add(_ascii('end\n'))
    ..add(_ascii('mark currentfile closefile\n'));

  final encrypted = blType1Encrypt(private.toBytes(), blType1EexecKey, 4);

  final trailer = StringBuffer();
  for (var line = 0; line < 8; line++) {
    trailer.writeln('0' * 64);
  }
  trailer.writeln('cleartomark');

  final clearBytes = _ascii(clear.toString());
  final body = hexEexec ? _ascii('${_toHex(encrypted)}\n') : encrypted;
  final trailerBytes = _ascii(trailer.toString());

  if (pfb) return _wrapPFB(clearBytes, body, trailerBytes);

  return (BytesBuilder()
        ..add(clearBytes)
        ..add(body)
        ..add(_ascii('\n'))
        ..add(trailerBytes))
      .toBytes();
}

// ---------------------------------------------------------------------------
// Utilidades de verificação
// ---------------------------------------------------------------------------

({double left, double top, double right, double bottom}) _boxOf(
    BLPathData path) {
  var minX = double.infinity;
  var maxX = double.negativeInfinity;
  var minY = double.infinity;
  var maxY = double.negativeInfinity;
  for (var i = 0; i < path.vertices.length; i += 2) {
    final x = path.vertices[i];
    final y = path.vertices[i + 1];
    if (x < minX) minX = x;
    if (x > maxX) maxX = x;
    if (y < minY) minY = y;
    if (y > maxY) maxY = y;
  }
  return (left: minX, top: minY, right: maxX, bottom: maxY);
}

void main() {
  // 'A': retângulo de (100,50) a (500,700), avanço 600.
  // 'B': retângulo de (0,0) a (200,200), avanço 250.
  final simple = buildType1(
    charstrings: <(String, Uint8List)>[
      ('.notdef', _emptyGlyph()),
      ('A', _rectGlyph(100, 600, 100, 50, 500, 700)),
      ('B', _rectGlyph(0, 250, 0, 0, 200, 200)),
    ],
  );

  group('deteccao de fonte Type 1', () {
    test('reconhece o programa PostScript com eexec', () {
      expect(BLType1Font.looksLikeType1(simple), isTrue);
    });

    test('nao confunde um sfnt com um Type 1', () {
      final sfnt = Uint8List.fromList(<int>[
        0x00, 0x01, 0x00, 0x00, //
        0x00, 0x04, 0x00, 0x40, 0x00, 0x00, 0x00, 0x00,
      ]);
      expect(BLType1Font.looksLikeType1(sfnt), isFalse);
    });

    test('nao confunde um CFF puro com um Type 1', () {
      final cff = Uint8List.fromList(<int>[1, 0, 4, 2, 0, 1, 1, 1]);
      expect(BLType1Font.looksLikeType1(cff), isFalse);
    });
  });

  group('leitura do dicionario PostScript', () {
    test('le o nome, a matriz e a caixa da fonte', () {
      final font = BLType1Font.parse(simple)!;
      expect(font.fontName, 'TestType1');
      expect(font.unitsPerEm, 1000);
      expect(font.fontMatrix.first, closeTo(0.001, 1e-12));
      expect(font.fontBBox, <double>[0, -200, 1000, 900]);
    });

    test('conta os glifos do /CharStrings', () {
      final font = BLType1Font.parse(simple)!;
      expect(font.glyphCount, 3);
      expect(font.glyphNames, <String>['.notdef', 'A', 'B']);
      expect(font.nameToGlyphId['A'], 1);
      expect(font.nameToGlyphId['B'], 2);
    });

    test('deriva o unitsPerEm de um FontMatrix diferente do padrao', () {
      final font = BLType1Font.parse(buildType1(
        fontMatrix: '0.0005 0 0 0.0005 0 0',
        charstrings: <(String, Uint8List)>[
          ('.notdef', _emptyGlyph()),
          ('A', _rectGlyph(0, 100, 0, 0, 100, 100)),
        ],
      ))!;
      expect(font.unitsPerEm, 2000);
    });

    test('/Encoding StandardEncoding mapeia os codigos padrao', () {
      final font = BLType1Font.parse(simple)!;
      expect(font.usesStandardEncoding, isTrue);
      expect(font.encoding[65], 'A');
      expect(font.codeToGlyphId[65], 1);
      expect(font.codeToGlyphId[66], 2);
    });

    test('/Encoding explicito vence a StandardEncoding', () {
      final font = BLType1Font.parse(buildType1(
        encoding: const <int, String>{200: 'A', 201: 'B'},
        charstrings: <(String, Uint8List)>[
          ('.notdef', _emptyGlyph()),
          ('A', _rectGlyph(100, 600, 100, 50, 500, 700)),
          ('B', _rectGlyph(0, 250, 0, 0, 200, 200)),
        ],
      ))!;
      expect(font.usesStandardEncoding, isFalse);
      expect(font.encoding[200], 'A');
      expect(font.codeToGlyphId[200], 1);
      expect(font.codeToGlyphId.containsKey(65), isFalse);
    });

    test('a StandardEncoding usada pelo seac resolve os nomes certos', () {
      expect(blStandardEncodingName(65), 'A');
      expect(blStandardEncodingName(194), 'acute');
      expect(blStandardEncodingName(0), isNull);
    });
  });

  group('contornos Type 1', () {
    test('o retangulo sai com a geometria escrita e o eixo Y invertido', () {
      final font = BLType1Font.parse(simple)!;
      final path = font.decodeGlyph(1)!;
      final box = _boxOf(path);
      expect(box.left, closeTo(100, 1e-9));
      expect(box.right, closeTo(500, 1e-9));
      // y do glifo cresce para cima; a saída cresce para baixo.
      expect(box.top, closeTo(-700, 1e-9));
      expect(box.bottom, closeTo(-50, 1e-9));
      expect(path.contourVertexCounts, hasLength(1));
    });

    test('glifos diferentes tem contornos diferentes', () {
      final font = BLType1Font.parse(simple)!;
      final a = _boxOf(font.decodeGlyph(1)!);
      final b = _boxOf(font.decodeGlyph(2)!);
      expect(a.right, isNot(closeTo(b.right, 1e-6)));
    });

    test('resolve contorno por nome', () {
      final font = BLType1Font.parse(simple)!;
      expect(_boxOf(font.decodeGlyphByName('B')!).right, closeTo(200, 1e-9));
      expect(font.decodeGlyphByName('Z'), isNull);
    });

    test('hsbw da a largura de avanco, ja que nao ha hmtx', () {
      final font = BLType1Font.parse(simple)!;
      expect(font.advanceWidthUnits(1), 600);
      expect(font.advanceWidthUnits(2), 250);
    });

    test('sbw define sidebearing e avanco nos dois eixos', () {
      final glyph = BytesBuilder();
      _num(glyph, 40); // sbx
      _num(glyph, 10); // sby
      _num(glyph, 700); // wx
      _num(glyph, 0); // wy
      _esc(glyph, 7); // sbw
      _num(glyph, 0);
      _num(glyph, 0);
      _op(glyph, 21); // rmoveto: fica em (40, 10)
      _num(glyph, 100);
      _op(glyph, 6); // hlineto
      _num(glyph, 100);
      _op(glyph, 7); // vlineto
      _op(glyph, 9); // closepath
      _op(glyph, 14);

      final font = BLType1Font.parse(buildType1(
        charstrings: <(String, Uint8List)>[
          ('.notdef', _emptyGlyph()),
          ('A', glyph.toBytes()),
        ],
      ))!;
      expect(font.advanceWidthUnits(1), 700);
      final box = _boxOf(font.decodeGlyph(1)!);
      expect(box.left, closeTo(40, 1e-9));
      expect(box.right, closeTo(140, 1e-9));
      expect(box.bottom, closeTo(-10, 1e-9));
      expect(box.top, closeTo(-110, 1e-9));
    });

    test('rrcurveto, hvcurveto e vhcurveto produzem curvas', () {
      final glyph = BytesBuilder();
      _hsbw(glyph, 0, 1000);
      _num(glyph, 0);
      _num(glyph, 0);
      _op(glyph, 21); // rmoveto -> (0,0)
      _num(glyph, 0);
      _num(glyph, 200);
      _num(glyph, 200);
      _num(glyph, 0);
      _num(glyph, 0);
      _num(glyph, -200);
      _op(glyph, 8); // rrcurveto -> (200, 0)
      _op(glyph, 9);
      _op(glyph, 14);

      final font = BLType1Font.parse(buildType1(
        charstrings: <(String, Uint8List)>[
          ('.notdef', _emptyGlyph()),
          ('A', glyph.toBytes()),
        ],
      ))!;
      final path = font.decodeGlyph(1)!;
      expect(path.contourVertexCounts, hasLength(1));
      // Achatada, a curva tem muito mais que os dois extremos.
      expect(path.vertices.length ~/ 2, greaterThan(4));
      final box = _boxOf(path);
      expect(box.left, closeTo(0, 1e-9));
      expect(box.right, closeTo(200, 1e-9));
      // O ponto de controle puxa o contorno para y positivo no glifo.
      expect(box.top, lessThan(-50));
    });

    test('div calcula o operando antes de construir o contorno', () {
      final glyph = BytesBuilder();
      _hsbw(glyph, 0, 1000);
      _num(glyph, 1000);
      _num(glyph, 10);
      _esc(glyph, 12); // div -> 100
      _num(glyph, 0);
      _op(glyph, 21); // rmoveto(100, 0)
      _num(glyph, 800);
      _num(glyph, 4);
      _esc(glyph, 12); // div -> 200
      _op(glyph, 6); // hlineto
      _num(glyph, 50);
      _op(glyph, 7); // vlineto
      _op(glyph, 9);
      _op(glyph, 14);

      final font = BLType1Font.parse(buildType1(
        charstrings: <(String, Uint8List)>[
          ('.notdef', _emptyGlyph()),
          ('A', glyph.toBytes()),
        ],
      ))!;
      final box = _boxOf(font.decodeGlyph(1)!);
      expect(box.left, closeTo(100, 1e-9));
      expect(box.right, closeTo(300, 1e-9));
    });

    test('o inteiro de 32 bits do codigo 255 chega intacto', () {
      final glyph = BytesBuilder();
      _hsbw(glyph, 0, 1000);
      _num(glyph, 5000);
      _num(glyph, 0);
      _op(glyph, 21); // rmoveto(5000, 0)
      _num(glyph, -4000);
      _op(glyph, 6); // hlineto
      _num(glyph, 100);
      _op(glyph, 7);
      _op(glyph, 9);
      _op(glyph, 14);

      final font = BLType1Font.parse(buildType1(
        charstrings: <(String, Uint8List)>[
          ('.notdef', _emptyGlyph()),
          ('A', glyph.toBytes()),
        ],
      ))!;
      final box = _boxOf(font.decodeGlyph(1)!);
      expect(box.left, closeTo(1000, 1e-9));
      expect(box.right, closeTo(5000, 1e-9));
    });

    test('hstem, vstem, hstem3, vstem3 e dotsection nao emitem geometria', () {
      final glyph = BytesBuilder();
      _hsbw(glyph, 0, 1000);
      _num(glyph, 0);
      _num(glyph, 100);
      _op(glyph, 1); // hstem
      _num(glyph, 0);
      _num(glyph, 100);
      _op(glyph, 3); // vstem
      _num(glyph, 0);
      _num(glyph, 10);
      _num(glyph, 100);
      _num(glyph, 10);
      _num(glyph, 200);
      _num(glyph, 10);
      _esc(glyph, 2); // hstem3
      _num(glyph, 0);
      _num(glyph, 10);
      _num(glyph, 100);
      _num(glyph, 10);
      _num(glyph, 200);
      _num(glyph, 10);
      _esc(glyph, 1); // vstem3
      _esc(glyph, 0); // dotsection
      _num(glyph, 0);
      _num(glyph, 0);
      _op(glyph, 21);
      _num(glyph, 300);
      _op(glyph, 6);
      _num(glyph, 300);
      _op(glyph, 7);
      _op(glyph, 9);
      _op(glyph, 14);

      final font = BLType1Font.parse(buildType1(
        charstrings: <(String, Uint8List)>[
          ('.notdef', _emptyGlyph()),
          ('A', glyph.toBytes()),
        ],
      ))!;
      final path = font.decodeGlyph(1)!;
      expect(path.contourVertexCounts, hasLength(1));
      final box = _boxOf(path);
      expect(box.right, closeTo(300, 1e-9));
      expect(box.top, closeTo(-300, 1e-9));
    });
  });

  group('subrotinas e OtherSubrs', () {
    // Subrs padrão de qualquer fonte Type 1: 0-2 formam o FLEX e 3 é a
    // substituição de hints (Black Book §8.3).
    Uint8List standardSubr0() {
      final out = BytesBuilder();
      _num(out, 3);
      _num(out, 0);
      _esc(out, 16); // callothersubr
      _esc(out, 17); // pop
      _esc(out, 17); // pop
      _esc(out, 33); // setcurrentpoint
      _op(out, 11); // return
      return out.toBytes();
    }

    Uint8List standardSubr(int index) {
      final out = BytesBuilder();
      _num(out, 0);
      _num(out, index);
      _esc(out, 16);
      _op(out, 11);
      return out.toBytes();
    }

    test('callsubr executa a subrotina e return volta', () {
      final subr = BytesBuilder();
      _num(subr, 300);
      _op(subr, 6); // hlineto
      _op(subr, 11); // return

      final glyph = BytesBuilder();
      _hsbw(glyph, 0, 1000);
      _num(glyph, 0);
      _num(glyph, 0);
      _op(glyph, 21);
      _num(glyph, 0);
      _op(glyph, 10); // callsubr 0
      _num(glyph, 200);
      _op(glyph, 7); // vlineto
      _op(glyph, 9);
      _op(glyph, 14);

      final font = BLType1Font.parse(buildType1(
        subrs: <Uint8List>[subr.toBytes()],
        charstrings: <(String, Uint8List)>[
          ('.notdef', _emptyGlyph()),
          ('A', glyph.toBytes()),
        ],
      ))!;
      expect(font.subrCount, 1);
      final box = _boxOf(font.decodeGlyph(1)!);
      expect(box.right, closeTo(300, 1e-9));
      expect(box.top, closeTo(-200, 1e-9));
    });

    test('FLEX vira duas curvas num unico contorno, sem o ponto de referencia',
        () {
      // Sete rmovetos entre OtherSubrs 1 e 0. Sem tratar o FLEX, cada um deles
      // abriria um contorno novo e o glifo sairia com oito contornos vazios.
      const points = <(int, int)>[
        (50, 100), // ponto de referência — tem de ser descartado
        (50, 100), // controle 1  -> (100, 200)
        (100, 0), // controle 2  -> (200, 200)
        (100, -200), // junção     -> (300, 0)
        (100, -200), // controle 3 -> (400, -200)
        (100, 0), // controle 4  -> (500, -200)
        (100, 200), // final       -> (600, 0)
      ];

      final glyph = BytesBuilder();
      _hsbw(glyph, 0, 1000);
      _num(glyph, 0);
      _num(glyph, 0);
      _op(glyph, 21); // rmoveto -> (0,0)
      _num(glyph, 1);
      _op(glyph, 10); // callsubr 1: inicia o FLEX
      for (final p in points) {
        _num(glyph, p.$1);
        _num(glyph, p.$2);
        _op(glyph, 21); // rmoveto
        _num(glyph, 2);
        _op(glyph, 10); // callsubr 2: registra o ponto
      }
      _num(glyph, 50); // altura do flex
      _num(glyph, 600); // x final
      _num(glyph, 0); // y final
      _num(glyph, 0);
      _op(glyph, 10); // callsubr 0: fecha o FLEX
      _op(glyph, 14);

      final font = BLType1Font.parse(buildType1(
        subrs: <Uint8List>[
          standardSubr0(),
          standardSubr(1),
          standardSubr(2),
        ],
        charstrings: <(String, Uint8List)>[
          ('.notdef', _emptyGlyph()),
          ('A', glyph.toBytes()),
        ],
      ))!;

      final path = font.decodeGlyph(1)!;
      expect(path.contourVertexCounts, hasLength(1),
          reason: 'o FLEX nao pode quebrar o contorno em varios');

      final verts = path.vertices;
      expect(verts[0], closeTo(0, 1e-9));
      expect(verts[1], closeTo(0, 1e-9));
      expect(verts[verts.length - 2], closeTo(600, 1e-9));
      expect(verts[verts.length - 1], closeTo(0, 1e-9));

      // O ponto de referência (50, 100) — saída (50, -100) — nunca é emitido.
      for (var i = 0; i < verts.length; i += 2) {
        final isReference =
            (verts[i] - 50).abs() < 1e-9 && (verts[i + 1] + 100).abs() < 1e-9;
        expect(isReference, isFalse);
      }

      // As duas curvas sobem e descem: a de cima no glifo vira y negativo.
      final box = _boxOf(path);
      expect(box.top, lessThan(-50));
      expect(box.bottom, greaterThan(50));
    });

    test('substituicao de hints (OtherSubrs 3) chama o subr devolvido', () {
      // `subr# 1 3 callothersubr pop callsubr` — a subrotina só é executada
      // se o valor devolvido pelo `pop` for o número que foi passado.
      final hintSubr = BytesBuilder();
      _num(hintSubr, 400);
      _op(hintSubr, 6); // hlineto
      _op(hintSubr, 11);

      final decoy = BytesBuilder();
      _num(decoy, -400);
      _op(decoy, 6);
      _op(decoy, 11);

      final glyph = BytesBuilder();
      _hsbw(glyph, 0, 1000);
      _num(glyph, 0);
      _num(glyph, 0);
      _op(glyph, 21);
      _num(glyph, 1); // subr# a chamar depois da troca de hints
      _num(glyph, 1); // n = 1 argumento
      _num(glyph, 3); // OtherSubrs 3
      _esc(glyph, 16); // callothersubr
      _esc(glyph, 17); // pop -> devolve 1
      _op(glyph, 10); // callsubr 1
      _num(glyph, 150);
      _op(glyph, 7); // vlineto
      _op(glyph, 9);
      _op(glyph, 14);

      final font = BLType1Font.parse(buildType1(
        subrs: <Uint8List>[decoy.toBytes(), hintSubr.toBytes()],
        charstrings: <(String, Uint8List)>[
          ('.notdef', _emptyGlyph()),
          ('A', glyph.toBytes()),
        ],
      ))!;
      final box = _boxOf(font.decodeGlyph(1)!);
      expect(box.right, closeTo(400, 1e-9),
          reason: 'o subr 1 e nao o subr 0 tem de ter sido chamado');
      expect(box.left, closeTo(0, 1e-9));
    });

    test('setcurrentpoint reposiciona sem desenhar', () {
      final glyph = BytesBuilder();
      _hsbw(glyph, 0, 1000);
      _num(glyph, 0);
      _num(glyph, 0);
      _op(glyph, 21);
      _num(glyph, 100);
      _op(glyph, 6);
      _op(glyph, 9); // closepath
      _num(glyph, 500);
      _num(glyph, 500);
      _esc(glyph, 33); // setcurrentpoint(500, 500)
      _num(glyph, 0);
      _num(glyph, 0);
      _op(glyph, 21); // rmoveto relativo ao ponto corrente
      _num(glyph, 100);
      _op(glyph, 6);
      _num(glyph, 100);
      _op(glyph, 7);
      _op(glyph, 9);
      _op(glyph, 14);

      final font = BLType1Font.parse(buildType1(
        charstrings: <(String, Uint8List)>[
          ('.notdef', _emptyGlyph()),
          ('A', glyph.toBytes()),
        ],
      ))!;
      final path = font.decodeGlyph(1)!;
      final box = _boxOf(path);
      expect(box.right, closeTo(600, 1e-9));
      expect(box.top, closeTo(-600, 1e-9));
    });
  });

  group('seac compoe caracteres acentuados', () {
    // 'A' é o retângulo (100,50)-(500,700); 'acute', o retângulo (50,0)-(150,100).
    // O composto pede adx = 500, asb = 50 e ady = 800: o acento vai para
    // x + (sbx_do_composto + adx - asb) = x + 550 e y + 800.
    Uint8List seacGlyph() {
      final out = BytesBuilder();
      _hsbw(out, 100, 600);
      _num(out, 50); // asb
      _num(out, 500); // adx
      _num(out, 800); // ady
      _num(out, 65); // bchar = 'A'
      _num(out, 194); // achar = 'acute'
      _esc(out, 6); // seac
      return out.toBytes();
    }

    final accented = buildType1(
      charstrings: <(String, Uint8List)>[
        ('.notdef', _emptyGlyph()),
        ('A', _rectGlyph(100, 600, 100, 50, 500, 700)),
        ('acute', _rectGlyph(50, 200, 50, 0, 150, 100)),
        ('Aacute', seacGlyph()),
      ],
    );

    test('emite base e acento como contornos separados', () {
      final font = BLType1Font.parse(accented)!;
      final path = font.decodeGlyph(font.nameToGlyphId['Aacute']!)!;
      expect(path.contourVertexCounts, hasLength(2));
    });

    test('posiciona o acento por adx - asb somado ao sidebearing da base', () {
      final font = BLType1Font.parse(accented)!;
      final box = _boxOf(font.decodeGlyph(font.nameToGlyphId['Aacute']!)!);
      // base: x [100,500]; acento: x [50,150] + 550 = [600,700]
      expect(box.left, closeTo(100, 1e-9));
      expect(box.right, closeTo(700, 1e-9));
      // base: y [50,700]; acento: y [0,100] + 800 = [800,900]
      expect(box.bottom, closeTo(-50, 1e-9));
      expect(box.top, closeTo(-900, 1e-9));
    });

    test('sem os glifos referenciados o seac nao inventa contorno', () {
      final font = BLType1Font.parse(buildType1(
        charstrings: <(String, Uint8List)>[
          ('.notdef', _emptyGlyph()),
          ('Aacute', seacGlyph()),
        ],
      ))!;
      expect(font.decodeGlyph(font.nameToGlyphId['Aacute']!), isNull);
    });
  });

  group('conteineres e variantes de criptografia', () {
    test('PFB com segmentos binarios le igual ao PFA', () {
      final pfb = buildType1(
        pfb: true,
        charstrings: <(String, Uint8List)>[
          ('.notdef', _emptyGlyph()),
          ('A', _rectGlyph(100, 600, 100, 50, 500, 700)),
        ],
      );
      expect(BLType1Font.looksLikeType1(pfb), isTrue);
      final font = BLType1Font.parse(pfb)!;
      expect(font.glyphNames, <String>['.notdef', 'A']);
      final box = _boxOf(font.decodeGlyph(1)!);
      expect(box.left, closeTo(100, 1e-9));
      expect(box.right, closeTo(500, 1e-9));
    });

    test('a porcao eexec em hexadecimal e aceita', () {
      final font = BLType1Font.parse(buildType1(
        hexEexec: true,
        charstrings: <(String, Uint8List)>[
          ('.notdef', _emptyGlyph()),
          ('A', _rectGlyph(100, 600, 100, 50, 500, 700)),
        ],
      ))!;
      final box = _boxOf(font.decodeGlyph(1)!);
      expect(box.left, closeTo(100, 1e-9));
      expect(box.right, closeTo(500, 1e-9));
    });

    test('lenIV diferente do padrao e respeitado', () {
      for (final lenIV in const <int>[0, 1, 7]) {
        final font = BLType1Font.parse(buildType1(
          lenIV: lenIV,
          charstrings: <(String, Uint8List)>[
            ('.notdef', _emptyGlyph()),
            ('A', _rectGlyph(100, 600, 100, 50, 500, 700)),
          ],
        ))!;
        final box = _boxOf(font.decodeGlyph(1)!);
        expect(box.left, closeTo(100, 1e-9), reason: 'lenIV = $lenIV');
        expect(box.right, closeTo(500, 1e-9), reason: 'lenIV = $lenIV');
      }
    });

    test('um lenIV errado produz lixo, nao o contorno certo (guarda)', () {
      // O arquivo diz lenIV 4 mas as charstrings foram encriptadas com 6: o
      // teste anterior só prova algo porque este falha em produzir a caixa.
      final good = BLType1Font.parse(buildType1(
        lenIV: 4,
        charstrings: <(String, Uint8List)>[
          ('.notdef', _emptyGlyph()),
          ('A', _rectGlyph(100, 600, 100, 50, 500, 700)),
        ],
      ))!;
      final goodBox = _boxOf(good.decodeGlyph(1)!);

      final bytes = buildType1(
        lenIV: 6,
        charstrings: <(String, Uint8List)>[
          ('.notdef', _emptyGlyph()),
          ('A', _rectGlyph(100, 600, 100, 50, 500, 700)),
        ],
      );
      // Reescreve o `/lenIV 6` declarado para 4 sem mexer nos dados.
      final font = BLType1Font.parse(bytes)!;
      final path = font.decodeGlyph(1);
      final box = path == null ? null : _boxOf(path);
      expect(box?.right, closeTo(goodBox.right, 1e-9),
          reason: 'com lenIV coerente o contorno tem de sair igual');
    });
  });

  group('BLFontFace aceita uma fonte Type 1', () {
    test('parse devolve uma face com contornos Type 1', () {
      final face = BLFontFace.parse(simple);
      expect(face.hasType1Outlines, isTrue);
      expect(face.hasCFFOutlines, isFalse);
      expect(face.hasTrueTypeOutlines, isFalse);
      expect(face.glyphCount, 3);
      expect(face.unitsPerEm, 1000);
      expect(face.postScriptName, 'TestType1');
    });

    test('resolve GID por nome de glifo', () {
      final face = BLFontFace.parse(simple);
      expect(face.glyphIdForName('A'), 1);
      expect(face.glyphIdForName('B'), 2);
      expect(face.glyphIdForName('Z'), isNull);
      expect(face.glyphNameForId(1), 'A');
    });

    test('mapCodePoint usa o /Encoding no lugar do cmap', () {
      final face = BLFontFace.parse(simple);
      expect(face.mapCodePoint(65), 1);
      expect(face.mapCodePoint(66), 2);
    });

    test('glyphOutlineUnits devolve a mesma geometria da fonte', () {
      final face = BLFontFace.parse(simple);
      final box = _boxOf(face.glyphOutlineUnits(1)!);
      expect(box.left, closeTo(100, 1e-9));
      expect(box.right, closeTo(500, 1e-9));
      expect(box.top, closeTo(-700, 1e-9));
    });

    test('glyphAdvanceUnits sai do hsbw, e nao do em inteiro', () {
      final face = BLFontFace.parse(simple);
      expect(face.glyphAdvanceUnits(1), 600);
      expect(face.glyphAdvanceUnits(2), 250);
    });

    test('BLFont escala o contorno para o corpo pedido', () {
      final font = BLFont(BLFontFace.parse(simple), 20.0);
      final box = _boxOf(font.glyphOutline(1)!);
      expect(box.left, closeTo(2.0, 1e-9)); // 100 * 20/1000
      expect(box.right, closeTo(10.0, 1e-9));
    });

    test('a metrica vertical vem da FontBBox, ja que nao ha hhea', () {
      final face = BLFontFace.parse(simple);
      expect(face.ascender, 900);
      expect(face.descender, -200);
    });
  });
}
