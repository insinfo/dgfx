/// Fontes Adobe Type 1 (`/FontFile` de um PDF, `.pfa` e `.pfb`).
///
/// Implementa o que a referência normativa — Adobe, *Adobe Type 1 Font Format*
/// ("Black Book"), 1990 — descreve como necessário para extrair contornos:
///
///   - o contêiner PFB (segmentos `0x80 0x01`/`0x80 0x02`) e o PFA (texto com
///     a porção `eexec` em hexadecimal), §2.2 e apêndice B;
///   - a decriptação `eexec` com R = 55665 e a de charstrings com R = 4330,
///     respeitando `/lenIV`, §7.1 e §7.2;
///   - o dicionário PostScript de texto claro (`/FontMatrix`, `/FontBBox`,
///     `/Encoding`) e o privado (`/Subrs`, `/CharStrings`), §5 e §10;
///   - o interpretador de charstrings Type 1 inteiro, §6: `hsbw`, `sbw`,
///     `closepath`, os move/line/curve, `callsubr`/`return`, os operadores de
///     hint, `div`, `seac`, `setcurrentpoint` e `callothersubr` com os
///     OtherSubrs 0-3 — ou seja, FLEX e substituição de hints.
///
/// A convenção de eixo do contorno devolvido é a mesma de
/// `BLCFFDecoder.decodeGlyph`: `y` cresce para BAIXO, para que o resultado vá
/// direto ao rasterizador.
library;

import 'dart:typed_data';

import '../geometry/bl_path.dart';
import 'bl_cff_strings.dart';

// ---------------------------------------------------------------------------
// Criptografia (Black Book §7)
// ---------------------------------------------------------------------------

const int _eexecKey = 55665;
const int _charstringKey = 4330;
const int _c1 = 52845;
const int _c2 = 22719;

/// Decripta [data] com o algoritmo `eexec`, descartando os [skip] primeiros
/// bytes do texto claro (bytes aleatórios de semente).
Uint8List _decrypt(Uint8List data, int key, int skip) {
  var r = key;
  final out = Uint8List(data.length);
  for (var i = 0; i < data.length; i++) {
    final c = data[i];
    out[i] = c ^ (r >> 8);
    r = ((c + r) * _c1 + _c2) & 0xFFFF;
  }
  if (skip <= 0) return out;
  if (skip >= out.length) return Uint8List(0);
  return Uint8List.sublistView(out, skip);
}

/// Encripta [data] com o algoritmo do Type 1, prefixando [skip] bytes de
/// semente. Existe para que testes possam montar uma fonte Type 1 de verdade.
Uint8List blType1Encrypt(Uint8List data, int key, int skip) {
  var r = key;
  final out = BytesBuilder();
  void step(int plain) {
    final c = plain ^ (r >> 8);
    r = ((c + r) * _c1 + _c2) & 0xFFFF;
    out.addByte(c & 0xFF);
  }

  for (var i = 0; i < skip; i++) {
    step(0x41); // 'A': qualquer byte serve, desde que não seja hexadecimal
  }
  for (final b in data) {
    step(b);
  }
  return out.toBytes();
}

/// Chave da porção `eexec` (55665), exposta para montagem de fontes em teste.
const int blType1EexecKey = _eexecKey;

/// Chave das charstrings (4330), exposta para montagem de fontes em teste.
const int blType1CharstringKey = _charstringKey;

// ---------------------------------------------------------------------------
// Leitura léxica do dicionário PostScript
// ---------------------------------------------------------------------------

bool _isSpace(int c) =>
    c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 || c == 0x0C || c == 0x00;

bool _isDelimiter(int c) =>
    _isSpace(c) ||
    c == 0x2F || // /
    c == 0x7B || // {
    c == 0x7D || // }
    c == 0x5B || // [
    c == 0x5D || // ]
    c == 0x28 || // (
    c == 0x29; // )

bool _isHexDigit(int c) =>
    (c >= 0x30 && c <= 0x39) ||
    (c >= 0x41 && c <= 0x46) ||
    (c >= 0x61 && c <= 0x66);

int _hexValue(int c) {
  if (c >= 0x30 && c <= 0x39) return c - 0x30;
  if (c >= 0x41 && c <= 0x46) return c - 0x41 + 10;
  return c - 0x61 + 10;
}

/// Encontra a primeira ocorrência da sequência ASCII [needle] em [data].
int _indexOfAscii(Uint8List data, String needle, int from) {
  if (needle.isEmpty) return from;
  final first = needle.codeUnitAt(0);
  final limit = data.length - needle.length;
  for (var i = from < 0 ? 0 : from; i <= limit; i++) {
    if (data[i] != first) continue;
    var ok = true;
    for (var j = 1; j < needle.length; j++) {
      if (data[i + j] != needle.codeUnitAt(j)) {
        ok = false;
        break;
      }
    }
    if (ok) return i;
  }
  return -1;
}

/// Cursor de tokens sobre bytes PostScript em latin-1.
class _PSReader {
  final Uint8List data;
  int pos;

  _PSReader(this.data, [this.pos = 0]);

  void skipSpace() {
    while (pos < data.length) {
      final c = data[pos];
      if (_isSpace(c)) {
        pos++;
        continue;
      }
      if (c == 0x25) {
        // Comentário até o fim da linha.
        while (pos < data.length && data[pos] != 0x0A && data[pos] != 0x0D) {
          pos++;
        }
        continue;
      }
      break;
    }
  }

  /// Lê o próximo token simples (sem `/`), ou `''` no fim dos dados.
  String nextToken() {
    skipSpace();
    if (pos >= data.length) return '';
    final start = pos;
    final c = data[pos];
    if (c == 0x2F) {
      // Nome literal: devolve incluindo a barra.
      pos++;
      while (pos < data.length && !_isDelimiter(data[pos])) {
        pos++;
      }
      return _latin1(data, start, pos);
    }
    if (c == 0x7B || c == 0x7D || c == 0x5B || c == 0x5D) {
      pos++;
      return _latin1(data, start, pos);
    }
    while (pos < data.length && !_isDelimiter(data[pos])) {
      pos++;
    }
    if (pos == start) pos++; // token de um caractere delimitador solto
    return _latin1(data, start, pos);
  }

  /// Lê um inteiro, ou `null` se o próximo token não for numérico.
  int? nextInt() {
    final token = nextToken();
    if (token.isEmpty) return null;
    return int.tryParse(token);
  }
}

String _latin1(Uint8List data, int start, int end) {
  final buffer = StringBuffer();
  for (var i = start; i < end && i < data.length; i++) {
    buffer.writeCharCode(data[i]);
  }
  return buffer.toString();
}

// ---------------------------------------------------------------------------
// Contêineres PFA / PFB
// ---------------------------------------------------------------------------

/// Desmonta um PFB em bytes contínuos, ou devolve [data] se não for PFB.
///
/// Black Book, apêndice B: cada segmento começa com `0x80`, um tipo (1 =
/// texto ASCII, 2 = binário, 3 = fim) e, nos dois primeiros casos, um
/// comprimento de 32 bits em little-endian.
Uint8List _unwrapPFB(Uint8List data) {
  if (data.length < 6 || data[0] != 0x80) return data;
  final out = BytesBuilder();
  var p = 0;
  while (p + 2 <= data.length) {
    if (data[p] != 0x80) break;
    final type = data[p + 1];
    if (type == 3) break; // EOF
    if (type != 1 && type != 2) break;
    if (p + 6 > data.length) break;
    final length = data[p + 2] |
        (data[p + 3] << 8) |
        (data[p + 4] << 16) |
        (data[p + 5] << 24);
    final start = p + 6;
    if (length < 0 || start + length > data.length) {
      out.add(Uint8List.sublistView(data, start));
      break;
    }
    out.add(Uint8List.sublistView(data, start, start + length));
    p = start + length;
  }
  final bytes = out.toBytes();
  return bytes.isEmpty ? data : bytes;
}

// ---------------------------------------------------------------------------
// Interpretador de charstrings Type 1 (Black Book §6)
// ---------------------------------------------------------------------------

class _T1Op {
  static const int hstem = 1;
  static const int vstem = 3;
  static const int vmoveto = 4;
  static const int rlineto = 5;
  static const int hlineto = 6;
  static const int vlineto = 7;
  static const int rrcurveto = 8;
  static const int closepath = 9;
  static const int callsubr = 10;
  static const int returnOp = 11;
  static const int escape = 12;
  static const int hsbw = 13;
  static const int endchar = 14;
  static const int rmoveto = 21;
  static const int hmoveto = 22;
  static const int vhcurveto = 30;
  static const int hvcurveto = 31;

  // Operadores de dois bytes (12 x).
  static const int dotsection = 0;
  static const int vstem3 = 1;
  static const int hstem3 = 2;
  static const int seac = 6;
  static const int sbw = 7;
  static const int div = 12;
  static const int callothersubr = 16;
  static const int pop = 17;
  static const int setcurrentpoint = 33;
}

/// Estado de execução de uma charstring Type 1.
class _T1Interpreter {
  final BLPath path;
  final List<Uint8List> subrs;
  final double scaleX;
  final double scaleY;
  final double tolerance;

  /// Deslocamento aplicado na emissão — usado pelo `seac` para posicionar o
  /// acento sem reescrever as coordenadas da charstring do acento.
  final double originX;
  final double originY;

  final List<double> stack = <double>[];
  final List<double> psResults = <double>[];
  final List<double> flexPoints = <double>[];

  double x = 0.0;
  double y = 0.0;
  double sbx = 0.0;
  double sby = 0.0;
  double width = 0.0;
  bool hasWidth = false;
  bool contourOpen = false;
  bool flexing = false;
  bool finished = false;

  /// Sinaliza que a charstring terminou por `seac`, com os argumentos.
  List<double>? seacArgs;

  _T1Interpreter({
    required this.path,
    required this.subrs,
    required this.scaleX,
    required this.scaleY,
    required this.tolerance,
    this.originX = 0.0,
    this.originY = 0.0,
  });

  double _px(double v) => (v + originX) * scaleX;
  double _py(double v) => -(v + originY) * scaleY;

  void _closeIfOpen() {
    if (contourOpen) {
      path.close();
      contourOpen = false;
    }
  }

  void _moveTo(double dx, double dy) {
    x += dx;
    y += dy;
    if (flexing) {
      // Durante o FLEX o rmoveto não desenha: ele acumula um dos sete pontos
      // de referência que os OtherSubrs 0-2 transformam em duas curvas.
      flexPoints
        ..add(x)
        ..add(y);
      return;
    }
    _closeIfOpen();
    path.moveTo(_px(x), _py(y));
    contourOpen = true;
  }

  void _lineTo(double dx, double dy) {
    x += dx;
    y += dy;
    if (!contourOpen) {
      path.moveTo(_px(x), _py(y));
      contourOpen = true;
    } else {
      path.lineTo(_px(x), _py(y));
    }
  }

  void _curveTo(
      double dx1, double dy1, double dx2, double dy2, double dx3, double dy3) {
    final x1 = x + dx1, y1 = y + dy1;
    final x2 = x1 + dx2, y2 = y1 + dy2;
    final x3 = x2 + dx3, y3 = y2 + dy3;
    x = x3;
    y = y3;
    if (!contourOpen) {
      path.moveTo(_px(x3), _py(y3));
      contourOpen = true;
      return;
    }
    path.cubicTo(
      _px(x1),
      _py(y1),
      _px(x2),
      _py(y2),
      _px(x3),
      _py(y3),
      tolerance: tolerance,
    );
  }

  void _curveToAbsolute(
      double x1, double y1, double x2, double y2, double x3, double y3) {
    if (!contourOpen) {
      path.moveTo(_px(x3), _py(y3));
      contourOpen = true;
    } else {
      path.cubicTo(
        _px(x1),
        _py(y1),
        _px(x2),
        _py(y2),
        _px(x3),
        _py(y3),
        tolerance: tolerance,
      );
    }
    x = x3;
    y = y3;
  }

  /// Executa a charstring [code]; devolve `false` se ela estiver corrompida.
  bool run(Uint8List code, int depth) {
    if (depth > 30) return false;
    var p = 0;
    while (p < code.length) {
      if (finished) return true;
      final b0 = code[p++];

      if (b0 >= 32) {
        // Operando numérico (Black Book §6.2). Diferente do Type 2, o código
        // 255 traz um inteiro de 32 bits com sinal, não um 16.16.
        if (b0 == 255) {
          if (p + 4 > code.length) return false;
          final v = (code[p] << 24) |
              (code[p + 1] << 16) |
              (code[p + 2] << 8) |
              code[p + 3];
          p += 4;
          stack.add((v & 0x80000000) != 0 ? (v - 0x100000000) : v.toDouble());
        } else if (b0 <= 246) {
          stack.add((b0 - 139).toDouble());
        } else if (b0 <= 250) {
          if (p >= code.length) return false;
          stack.add(((b0 - 247) * 256 + code[p++] + 108).toDouble());
        } else {
          if (p >= code.length) return false;
          stack.add((-(b0 - 251) * 256 - code[p++] - 108).toDouble());
        }
        if (stack.length > 64) return false;
        continue;
      }

      if (b0 == _T1Op.escape) {
        if (p >= code.length) return false;
        final b1 = code[p++];
        if (!_escaped(b1, depth)) return false;
        if (finished) return true;
        continue;
      }

      switch (b0) {
        case _T1Op.hstem:
        case _T1Op.vstem:
          stack.clear();
          break;

        case _T1Op.vmoveto:
          if (stack.isEmpty) return false;
          _moveTo(0.0, stack.last);
          stack.clear();
          break;

        case _T1Op.hmoveto:
          if (stack.isEmpty) return false;
          _moveTo(stack.last, 0.0);
          stack.clear();
          break;

        case _T1Op.rmoveto:
          if (stack.length < 2) return false;
          _moveTo(stack[stack.length - 2], stack[stack.length - 1]);
          stack.clear();
          break;

        case _T1Op.rlineto:
          if (stack.length < 2) return false;
          _lineTo(stack[0], stack[1]);
          stack.clear();
          break;

        case _T1Op.hlineto:
          if (stack.isEmpty) return false;
          _lineTo(stack[0], 0.0);
          stack.clear();
          break;

        case _T1Op.vlineto:
          if (stack.isEmpty) return false;
          _lineTo(0.0, stack[0]);
          stack.clear();
          break;

        case _T1Op.rrcurveto:
          if (stack.length < 6) return false;
          _curveTo(stack[0], stack[1], stack[2], stack[3], stack[4], stack[5]);
          stack.clear();
          break;

        case _T1Op.hvcurveto:
          if (stack.length < 4) return false;
          _curveTo(stack[0], 0.0, stack[1], stack[2], 0.0, stack[3]);
          stack.clear();
          break;

        case _T1Op.vhcurveto:
          if (stack.length < 4) return false;
          _curveTo(0.0, stack[0], stack[1], stack[2], stack[3], 0.0);
          stack.clear();
          break;

        case _T1Op.closepath:
          _closeIfOpen();
          stack.clear();
          break;

        case _T1Op.hsbw:
          if (stack.length < 2) return false;
          sbx = stack[0];
          width = stack[1];
          hasWidth = true;
          x = sbx;
          y = 0.0;
          stack.clear();
          break;

        case _T1Op.callsubr:
          if (stack.isEmpty) return false;
          final index = stack.removeLast().toInt();
          if (index < 0 || index >= subrs.length) {
            // Um índice fora da faixa é dado corrompido; ignorar é melhor do
            // que perder o glifo inteiro.
            break;
          }
          if (!run(subrs[index], depth + 1)) return false;
          if (finished) return true;
          break;

        case _T1Op.returnOp:
          return true;

        case _T1Op.endchar:
          _closeIfOpen();
          finished = true;
          return true;

        default:
          // Operador desconhecido: limpa a pilha e segue, como faz o
          // interpretador de referência.
          stack.clear();
          break;
      }
    }
    return true;
  }

  bool _escaped(int op, int depth) {
    switch (op) {
      case _T1Op.dotsection:
      case _T1Op.vstem3:
      case _T1Op.hstem3:
        stack.clear();
        return true;

      case _T1Op.sbw:
        if (stack.length < 4) return false;
        sbx = stack[0];
        sby = stack[1];
        width = stack[2];
        hasWidth = true;
        x = sbx;
        y = sby;
        stack.clear();
        return true;

      case _T1Op.div:
        if (stack.length < 2) return false;
        final b = stack.removeLast();
        final a = stack.removeLast();
        stack.add(b == 0 ? 0.0 : a / b);
        return true;

      case _T1Op.seac:
        if (stack.length < 5) return false;
        seacArgs = <double>[
          stack[0],
          stack[1],
          stack[2],
          stack[3],
          stack[4],
        ];
        stack.clear();
        _closeIfOpen();
        finished = true;
        return true;

      case _T1Op.setcurrentpoint:
        if (stack.length < 2) return false;
        x = stack[0];
        y = stack[1];
        stack.clear();
        return true;

      case _T1Op.callothersubr:
        return _callOtherSubr();

      case _T1Op.pop:
        stack.add(psResults.isEmpty ? 0.0 : psResults.removeAt(0));
        return true;

      default:
        stack.clear();
        return true;
    }
  }

  /// Black Book §8.3 e apêndice de OtherSubrs: FLEX (0-2), substituição de
  /// hints (3), controle de contador (12-13) e Multiple Master (14-18).
  bool _callOtherSubr() {
    if (stack.length < 2) return false;
    final otherSubr = stack.removeLast().toInt();
    final argCount = stack.removeLast().toInt();
    if (argCount < 0 || argCount > stack.length) return false;

    final args = <double>[];
    for (var i = stack.length - argCount; i < stack.length; i++) {
      args.add(stack[i]);
    }
    stack.removeRange(stack.length - argCount, stack.length);
    psResults.clear();

    switch (otherSubr) {
      case 1: // início do FLEX
        flexing = true;
        flexPoints.clear();
        return true;

      case 2: // ponto intermediário do FLEX: o rmoveto já o registrou
        return true;

      case 0: // fim do FLEX
        flexing = false;
        if (flexPoints.length < 14) {
          // Sequência incompleta: cai para uma linha até o ponto corrente,
          // que é o que o interpretador de referência faz para não perder o
          // contorno inteiro.
          if (contourOpen) path.lineTo(_px(x), _py(y));
          psResults
            ..add(x)
            ..add(y);
          return true;
        }
        // flexPoints[0..1] é o ponto de referência do FLEX, descartado; os
        // seis seguintes são os pontos de controle das duas curvas.
        _curveToAbsolute(
          flexPoints[2],
          flexPoints[3],
          flexPoints[4],
          flexPoints[5],
          flexPoints[6],
          flexPoints[7],
        );
        _curveToAbsolute(
          flexPoints[8],
          flexPoints[9],
          flexPoints[10],
          flexPoints[11],
          flexPoints[12],
          flexPoints[13],
        );
        flexPoints.clear();
        // Os dois `pop` seguintes alimentam o `setcurrentpoint` do Subrs 0.
        psResults
          ..add(x)
          ..add(y);
        return true;

      case 3: // substituição de hints: devolve o número do subr a chamar
        psResults.add(args.isEmpty ? 3.0 : args[0]);
        return true;

      case 12:
      case 13: // controle de contador: só consome argumentos
        return true;

      case 14:
      case 15:
      case 16:
      case 17:
      case 18:
        // Multiple Master: os primeiros `k` argumentos são os valores da
        // instância base e os demais são deltas por eixo. Sem vetor de pesos
        // a instância correta é a base, então devolvemos os `k` primeiros.
        final k =
            const <int, int>{14: 1, 15: 2, 16: 3, 17: 4, 18: 6}[otherSubr]!;
        for (var i = 0; i < k && i < args.length; i++) {
          psResults.add(args[i]);
        }
        return true;

      default:
        // OtherSubr desconhecido: a convenção PostScript é deixar os
        // argumentos na pilha para os `pop` seguintes.
        psResults.addAll(args);
        return true;
    }
  }
}

// ---------------------------------------------------------------------------
// API pública
// ---------------------------------------------------------------------------

/// Fonte Adobe Type 1 decodificada em memória.
class BLType1Font {
  /// Nome PostScript declarado em `/FontName`.
  final String fontName;

  /// `/FontMatrix`, ou o padrão `[0.001, 0, 0, 0.001, 0, 0]`.
  final List<double> fontMatrix;

  /// `/FontBBox` (`[xMin, yMin, xMax, yMax]`), ou `null` se ausente.
  final List<double>? fontBBox;

  /// Unidades por em derivadas de `1 / fontMatrix[0]`.
  final int unitsPerEm;

  /// Nome de cada glifo, na ordem de aparição em `/CharStrings`.
  final List<String> glyphNames;

  /// Nome do glifo -> GID.
  final Map<String, int> nameToGlyphId;

  /// Código do `/Encoding` da fonte (0..255) -> nome do glifo.
  final Map<int, String> encoding;

  /// Código -> GID, derivado de [encoding]. E' o substituto do `cmap`.
  final Map<int, int> codeToGlyphId;

  /// `true` se a fonte declarou `/Encoding StandardEncoding`.
  final bool usesStandardEncoding;

  final List<Uint8List> _charstrings;
  final List<Uint8List> _subrs;
  final Map<String, Uint8List> _charstringsByName;
  final Map<int, int> _advanceCache = <int, int>{};

  BLType1Font._({
    required this.fontName,
    required this.fontMatrix,
    required this.fontBBox,
    required this.unitsPerEm,
    required this.glyphNames,
    required this.nameToGlyphId,
    required this.encoding,
    required this.codeToGlyphId,
    required this.usesStandardEncoding,
    required List<Uint8List> charstrings,
    required List<Uint8List> subrs,
    required Map<String, Uint8List> charstringsByName,
  })  : _charstrings = charstrings,
        _subrs = subrs,
        _charstringsByName = charstringsByName;

  /// Número de glifos, isto é, de entradas em `/CharStrings`.
  int get glyphCount => _charstrings.length;

  /// Número de subrotinas locais declaradas em `/Subrs`.
  int get subrCount => _subrs.length;

  /// Diz se [data] parece ser uma fonte Type 1 (PFA, PFB ou o conteúdo cru
  /// de um `/FontFile` de PDF).
  ///
  /// Deliberadamente conservador: um sfnt nunca começa com `0x80` nem com
  /// `%!`, e nunca contém o token `eexec`.
  static bool looksLikeType1(Uint8List data) {
    if (data.length < 8) return false;
    if (data[0] == 0x80 && (data[1] == 1 || data[1] == 2)) return true;

    // Cabeçalho PostScript: `%!PS-AdobeFont`, `%!FontType1`, ...
    var p = 0;
    while (p < data.length && _isSpace(data[p])) {
      p++;
    }
    final hasHeader =
        p + 2 <= data.length && data[p] == 0x25 && data[p + 1] == 0x21;

    final window =
        data.length < 8192 ? data : Uint8List.sublistView(data, 0, 8192);
    final hasEexec = _indexOfAscii(window, 'eexec', 0) >= 0;
    if (hasHeader && hasEexec) return true;
    if (!hasEexec) return false;
    return _indexOfAscii(window, '/FontType', 0) >= 0 ||
        _indexOfAscii(window, '/FontMatrix', 0) >= 0 ||
        _indexOfAscii(window, '/CharStrings', 0) >= 0;
  }

  /// Lê uma fonte Type 1 completa. Devolve `null` se a estrutura não fechar.
  static BLType1Font? parse(Uint8List data) {
    final bytes = _unwrapPFB(data);

    final eexecPos = _indexOfAscii(bytes, 'eexec', 0);
    final clear =
        eexecPos < 0 ? bytes : Uint8List.sublistView(bytes, 0, eexecPos);

    Uint8List private = Uint8List(0);
    if (eexecPos >= 0) {
      var p = eexecPos + 5;
      while (p < bytes.length && _isSpace(bytes[p])) {
        p++;
      }
      final encrypted = _readEexecBlock(bytes, p);
      if (encrypted.isNotEmpty) {
        private = _decrypt(encrypted, _eexecKey, 4);
      }
    }

    final fontName = _parseName(clear, '/FontName');
    final fontMatrix = _parseNumberArray(clear, '/FontMatrix', 6) ??
        const <double>[0.001, 0.0, 0.0, 0.001, 0.0, 0.0];
    final fontBBox = _parseNumberArray(clear, '/FontBBox', 4);

    var unitsPerEm = 1000;
    final sx = fontMatrix[0];
    if (sx.isFinite && sx > 0) {
      final derived = (1.0 / sx).round();
      if (derived >= 16 && derived <= 16384) unitsPerEm = derived;
    }

    var lenIV = 4;
    final lenIVPos = _indexOfAscii(private, '/lenIV', 0);
    if (lenIVPos >= 0) {
      final parsed = (_PSReader(private, lenIVPos + 6)).nextInt();
      if (parsed != null && parsed >= 0 && parsed <= 16) lenIV = parsed;
    }

    final subrs = _parseSubrs(private, lenIV);
    final entries = _parseCharStrings(private, lenIV);
    if (entries.isEmpty) return null;

    final glyphNames = <String>[];
    final nameToGlyphId = <String, int>{};
    final charstrings = <Uint8List>[];
    final charstringsByName = <String, Uint8List>{};
    for (final entry in entries) {
      final gid = charstrings.length;
      glyphNames.add(entry.$1);
      charstrings.add(entry.$2);
      nameToGlyphId.putIfAbsent(entry.$1, () => gid);
      charstringsByName.putIfAbsent(entry.$1, () => entry.$2);
    }

    final (encoding, usesStandard) = _parseEncoding(clear);
    final codeToGlyphId = <int, int>{};
    encoding.forEach((code, name) {
      final gid = nameToGlyphId[name];
      if (gid != null) codeToGlyphId[code] = gid;
    });

    return BLType1Font._(
      fontName: fontName,
      fontMatrix: List<double>.unmodifiable(fontMatrix),
      fontBBox: fontBBox == null ? null : List<double>.unmodifiable(fontBBox),
      unitsPerEm: unitsPerEm,
      glyphNames: List<String>.unmodifiable(glyphNames),
      nameToGlyphId: Map<String, int>.unmodifiable(nameToGlyphId),
      encoding: Map<int, String>.unmodifiable(encoding),
      codeToGlyphId: Map<int, int>.unmodifiable(codeToGlyphId),
      usesStandardEncoding: usesStandard,
      charstrings: charstrings,
      subrs: subrs,
      charstringsByName: charstringsByName,
    );
  }

  /// Contorno do glifo [glyphId], em unidades de fonte e com `y` para baixo.
  BLPathData? decodeGlyph(
    int glyphId, {
    double scaleX = 1.0,
    double scaleY = 1.0,
    double tolerance = 0.25,
  }) {
    if (glyphId < 0 || glyphId >= _charstrings.length) return null;
    return _decodeCharstring(
      _charstrings[glyphId],
      scaleX: scaleX,
      scaleY: scaleY,
      tolerance: tolerance,
    );
  }

  /// Contorno do glifo de nome [name], ou `null` se ele não existir.
  BLPathData? decodeGlyphByName(
    String name, {
    double scaleX = 1.0,
    double scaleY = 1.0,
    double tolerance = 0.25,
  }) {
    final code = _charstringsByName[name];
    if (code == null) return null;
    return _decodeCharstring(
      code,
      scaleX: scaleX,
      scaleY: scaleY,
      tolerance: tolerance,
    );
  }

  /// Largura de avanço do glifo, em unidades de fonte, vinda de `hsbw`/`sbw`.
  ///
  /// Um Type 1 não tem `hmtx`: a largura faz parte da charstring.
  int advanceWidthUnits(int glyphId) {
    if (glyphId < 0 || glyphId >= _charstrings.length) return 0;
    final cached = _advanceCache[glyphId];
    if (cached != null) return cached;
    final interp = _T1Interpreter(
      path: BLPath(),
      subrs: _subrs,
      scaleX: 1.0,
      scaleY: 1.0,
      tolerance: 0.25,
    );
    interp.run(_charstrings[glyphId], 0);
    final value = interp.hasWidth ? interp.width.round() : 0;
    _advanceCache[glyphId] = value;
    return value;
  }

  BLPathData? _decodeCharstring(
    Uint8List code, {
    required double scaleX,
    required double scaleY,
    required double tolerance,
  }) {
    final path = BLPath();
    final interp = _T1Interpreter(
      path: path,
      subrs: _subrs,
      scaleX: scaleX,
      scaleY: scaleY,
      tolerance: tolerance,
    );
    if (!interp.run(code, 0)) return null;
    interp._closeIfOpen();

    final seac = interp.seacArgs;
    if (seac != null) {
      if (!_appendSeac(
        path,
        interp.sbx,
        seac,
        scaleX: scaleX,
        scaleY: scaleY,
        tolerance: tolerance,
      )) {
        return null;
      }
    }
    return path.toPathData();
  }

  /// `seac` (Black Book §6.4): compõe um caractere acentuado a partir de dois
  /// glifos da StandardEncoding.
  bool _appendSeac(
    BLPath path,
    double baseSideBearing,
    List<double> args, {
    required double scaleX,
    required double scaleY,
    required double tolerance,
  }) {
    final asb = args[0];
    final adx = args[1];
    final ady = args[2];
    final bchar = args[3].toInt();
    final achar = args[4].toInt();

    final baseName = blStandardEncodingName(bchar);
    final accentName = blStandardEncodingName(achar);
    if (baseName == null || accentName == null) return false;

    final baseCode = _charstringsByName[baseName];
    final accentCode = _charstringsByName[accentName];
    if (baseCode == null || accentCode == null) return false;

    final base = _T1Interpreter(
      path: path,
      subrs: _subrs,
      scaleX: scaleX,
      scaleY: scaleY,
      tolerance: tolerance,
    );
    if (!base.run(baseCode, 0)) return false;
    base._closeIfOpen();

    // O deslocamento do acento é relativo ao sidebearing do caractere base
    // composto, e não à origem: `adx - asb + sb`.
    final accent = _T1Interpreter(
      path: path,
      subrs: _subrs,
      scaleX: scaleX,
      scaleY: scaleY,
      tolerance: tolerance,
      originX: baseSideBearing + adx - asb,
      originY: ady,
    );
    if (!accent.run(accentCode, 0)) return false;
    accent._closeIfOpen();
    return true;
  }

  // -------------------------------------------------------------------------
  // Leitura do dicionário
  // -------------------------------------------------------------------------

  /// Isola os bytes encriptados que seguem `eexec`, convertendo de hexadecimal
  /// quando o arquivo é PFA.
  static Uint8List _readEexecBlock(Uint8List bytes, int start) {
    if (start >= bytes.length) return Uint8List(0);

    // Heurística do próprio formato: se os quatro primeiros bytes úteis são
    // dígitos hexadecimais, a porção está em ASCII hexadecimal.
    var hexCandidates = 0;
    var probe = start;
    while (probe < bytes.length && hexCandidates < 4) {
      final c = bytes[probe];
      if (_isSpace(c)) {
        probe++;
        continue;
      }
      if (!_isHexDigit(c)) break;
      hexCandidates++;
      probe++;
    }

    if (hexCandidates < 4) {
      return Uint8List.sublistView(bytes, start);
    }

    final out = BytesBuilder();
    var high = -1;
    for (var i = start; i < bytes.length; i++) {
      final c = bytes[i];
      if (_isSpace(c)) continue;
      if (!_isHexDigit(c)) break;
      if (high < 0) {
        high = _hexValue(c);
      } else {
        out.addByte((high << 4) | _hexValue(c));
        high = -1;
      }
    }
    return out.toBytes();
  }

  static String _parseName(Uint8List data, String key) {
    final pos = _indexOfAscii(data, key, 0);
    if (pos < 0) return '';
    final token = _PSReader(data, pos + key.length).nextToken();
    if (token.startsWith('/')) return token.substring(1);
    return token;
  }

  static List<double>? _parseNumberArray(Uint8List data, String key, int n) {
    final pos = _indexOfAscii(data, key, 0);
    if (pos < 0) return null;
    final reader = _PSReader(data, pos + key.length);
    final values = <double>[];
    for (var guard = 0; guard < n + 4 && values.length < n; guard++) {
      final token = reader.nextToken();
      if (token.isEmpty) break;
      if (token == '[' || token == '{') continue;
      if (token == ']' || token == '}') break;
      final v = double.tryParse(token);
      if (v == null) break;
      values.add(v);
    }
    if (values.length < n) return null;
    return values;
  }

  /// `/Encoding`: ou `StandardEncoding`, ou uma sequência de
  /// `dup <código> /<nome> put`.
  static (Map<int, String>, bool) _parseEncoding(Uint8List data) {
    final out = <int, String>{};
    final pos = _indexOfAscii(data, '/Encoding', 0);
    if (pos < 0) return (out, false);

    final reader = _PSReader(data, pos + 9);
    final first = reader.nextToken();
    if (first == 'StandardEncoding') {
      for (var code = 0; code < 256; code++) {
        final name = blStandardEncodingName(code);
        if (name != null) out[code] = name;
      }
      return (out, true);
    }

    // Array explícito. Percorre até `readonly def` ou `def` no nível de topo.
    var guard = 0;
    while (reader.pos < data.length && guard++ < 4096) {
      final token = reader.nextToken();
      if (token.isEmpty) break;
      if (token == 'def') break;
      if (token != 'dup') continue;
      final code = reader.nextInt();
      if (code == null) continue;
      final name = reader.nextToken();
      if (!name.startsWith('/')) continue;
      final put = reader.nextToken();
      if (put != 'put') continue;
      if (code >= 0 && code < 256) out[code] = name.substring(1);
    }
    return (out, false);
  }

  /// `/Subrs n array` seguido de `dup <i> <len> RD <bin> NP`.
  static List<Uint8List> _parseSubrs(Uint8List data, int lenIV) {
    final pos = _indexOfAscii(data, '/Subrs', 0);
    if (pos < 0) return const <Uint8List>[];

    final reader = _PSReader(data, pos + 6);
    final count = reader.nextInt();
    if (count == null || count <= 0 || count > 65535) {
      return const <Uint8List>[];
    }

    final subrs = List<Uint8List>.filled(count, Uint8List(0), growable: false);
    var read = 0;
    var guard = 0;
    while (
        read < count && reader.pos < data.length && guard++ < count * 8 + 64) {
      final token = reader.nextToken();
      if (token.isEmpty) break;
      if (token == 'ND' || token == '|-' || token == 'noaccess') continue;
      if (token != 'dup') {
        // `/CharStrings` marca o fim do array de subrotinas.
        if (token == '/CharStrings') break;
        continue;
      }
      final index = reader.nextInt();
      final length = reader.nextInt();
      if (index == null || length == null || length < 0) break;
      reader.nextToken(); // RD / -|
      final start = reader.pos + 1; // exatamente um espaço antes do binário
      if (start + length > data.length) break;
      final blob = Uint8List.sublistView(data, start, start + length);
      if (index >= 0 && index < count) {
        subrs[index] = _decrypt(blob, _charstringKey, lenIV);
      }
      reader.pos = start + length;
      read++;
    }
    return subrs;
  }

  /// `/CharStrings n dict dup begin` seguido de `/<nome> <len> RD <bin> ND`.
  static List<(String, Uint8List)> _parseCharStrings(
      Uint8List data, int lenIV) {
    final pos = _indexOfAscii(data, '/CharStrings', 0);
    if (pos < 0) return const <(String, Uint8List)>[];

    final reader = _PSReader(data, pos + 12);
    final declared = reader.nextInt() ?? 0;
    final out = <(String, Uint8List)>[];

    var guard = 0;
    final limit = (declared > 0 ? declared : 4096) * 8 + 256;
    while (reader.pos < data.length && guard++ < limit) {
      final token = reader.nextToken();
      if (token.isEmpty) break;
      if (token == 'end') break;
      if (!token.startsWith('/') || token.length < 2) continue;

      final length = reader.nextInt();
      if (length == null || length < 0) continue;
      reader.nextToken(); // RD / -|
      final start = reader.pos + 1;
      if (start + length > data.length) break;
      final blob = Uint8List.sublistView(data, start, start + length);
      out.add((token.substring(1), _decrypt(blob, _charstringKey, lenIV)));
      reader.pos = start + length;
    }
    return out;
  }
}

/// Nome do glifo da StandardEncoding da Adobe para o código [code].
///
/// Devolve `null` para códigos sem glifo. A tabela vem do CFF (que reproduz
/// exatamente a StandardEncoding do Type 1) por meio de código -> SID -> nome.
String? blStandardEncodingName(int code) {
  if (code < 0 || code >= cffStandardEncodingSids.length) return null;
  final sid = cffStandardEncodingSids[code];
  if (sid <= 0 || sid >= cffStandardStrings.length) return null;
  return cffStandardStrings[sid];
}
