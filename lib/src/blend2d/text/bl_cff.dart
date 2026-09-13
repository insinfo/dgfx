/// CFF/CFF2 outline decoder (port of Blend2D's `otcff.cpp` charstring interpreter).
///
/// Parses CFF/CFF2 charstring programs and converts them to BLPath outlines.
/// Supports Type 2 charstring operators: move, line, curve, vstem, hstem,
/// endchar, and most hinting operators (ignored for outline extraction).
///
/// Inspired by: `blend2d/opentype/otcff.cpp`, `otcff_p.h`
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../geometry/bl_path.dart';
import 'bl_cff_strings.dart';

// ---------------------------------------------------------------------------
// CFF INDEX parser (v1)
// ---------------------------------------------------------------------------

/// A parsed CFF INDEX structure (v1).
class _CFFIndex {
  final int count;
  final int offsetSize;
  final int offsetsStart;
  final int dataStart;
  final ByteData view;

  /// Posição onde este INDEX começa (o campo `count`).
  final int start;
  final int countSize;

  const _CFFIndex(this.count, this.offsetSize, this.offsetsStart,
      this.dataStart, this.view, this.start, this.countSize);

  /// Total de bytes ocupados por este INDEX.
  ///
  /// Precisa ser o TAMANHO, e não a posição final absoluta: quem percorre o
  /// CFF caminha com `offset += index.totalSize` a partir do início do INDEX.
  /// A versão anterior devolvia a posição absoluta do fim, o que somava o
  /// deslocamento inicial duas vezes e fazia o parser errar o String INDEX e
  /// o Global Subr INDEX em qualquer CFF que não começasse no offset zero.
  int get totalSize {
    if (count == 0) return countSize;
    final end = dataStart + _readOffset(count) - 1;
    return end - start;
  }

  /// Posição logo após o ultimo byte deste INDEX.
  int get endOffset => start + totalSize;

  int _readOffset(int index) {
    final off = offsetsStart + index * offsetSize;
    switch (offsetSize) {
      case 1:
        return view.getUint8(off);
      case 2:
        return view.getUint16(off, Endian.big);
      case 3:
        return (view.getUint8(off) << 16) |
            (view.getUint8(off + 1) << 8) |
            view.getUint8(off + 2);
      case 4:
        return view.getUint32(off, Endian.big);
      default:
        return 0;
    }
  }

  /// Returns (start, end) byte range for entry [index] relative to data start.
  (int, int)? entryRange(int index) {
    if (index < 0 || index >= count) return null;
    final off0 = _readOffset(index) - 1; // CFF offsets are 1-based
    final off1 = _readOffset(index + 1) - 1;
    if (off0 < 0 || off1 < off0) return null;
    return (dataStart + off0, dataStart + off1);
  }

  /// Parse a CFF v1 INDEX starting at [offset].
  static _CFFIndex? parse(ByteData view, int offset, {int countSize = 2}) {
    if (countSize != 2 && countSize != 4) return null;
    if (offset < 0 || offset + countSize > view.lengthInBytes) return null;
    final count = countSize == 2
        ? view.getUint16(offset, Endian.big)
        : view.getUint32(offset, Endian.big);
    if (count == 0) {
      return _CFFIndex(0, 0, offset + countSize, offset + countSize, view,
          offset, countSize);
    }
    if (offset + countSize + 1 > view.lengthInBytes) return null;
    final offSize = view.getUint8(offset + countSize);
    if (offSize < 1 || offSize > 4) return null;
    final offsetsStart = offset + countSize + 1;
    final dataStart = offsetsStart + (count + 1) * offSize;
    if (dataStart > view.lengthInBytes) return null;
    final index = _CFFIndex(
        count, offSize, offsetsStart, dataStart, view, offset, countSize);
    // O ultimo offset marca o fim dos dados; se ele estoura o buffer, o INDEX
    // esta truncado e não pode ser usado.
    if (index.endOffset > view.lengthInBytes) return null;
    return index;
  }
}

// ---------------------------------------------------------------------------
// Type 2 Charstring interpreter (subset for outline extraction)
// ---------------------------------------------------------------------------

/// Type 2 charstring operators.
class _T2Op {
  static const int hstem = 1;
  static const int vstem = 3;
  static const int vmoveto = 4;
  static const int rlineto = 5;
  static const int hlineto = 6;
  static const int vlineto = 7;
  static const int rrcurveto = 8;
  static const int callsubr = 10;
  static const int returnOp = 11;
  static const int endchar = 14;
  static const int vsindex = 15;
  static const int blend = 16;
  static const int hstemhm = 18;
  static const int hintmask = 19;
  static const int cntrmask = 20;
  static const int rmoveto = 21;
  static const int hmoveto = 22;
  static const int vstemhm = 23;
  static const int rcurveline = 24;
  static const int rlinecurve = 25;
  static const int vvcurveto = 26;
  static const int hhcurveto = 27;
  static const int callgsubr = 29;
  static const int vhcurveto = 30;
  static const int hvcurveto = 31;
}

/// Interprets a Type 2 charstring and appends the outline to [path].
///
/// Returns true on success.
bool _interpretCharstring(
  BLPath path,
  ByteData view,
  int start,
  int end,
  double scaleX,
  double scaleY,
  double offsetX,
  double offsetY, {
  _CFFIndex? localSubrs,
  _CFFIndex? globalSubrs,
  List<List<double>> variationScalars = const <List<double>>[],
  double tolerance = 0.25,
}) {
  final stack = Float64List(48); // CFF operand stack (max 48 per spec)
  final transient = Float64List(32);
  int sp = 0; // stack pointer
  double x = offsetX, y = offsetY;
  bool hasWidth = false;
  bool hasMoveTo = false;
  int stemCount = 0;
  var variationIndex = 0;
  var randomState = 0x1234567;

  void moveTo(double dx, double dy) {
    x += dx;
    y += dy;
    path.moveTo(x * scaleX, -y * scaleY);
    hasMoveTo = true;
  }

  void lineTo(double dx, double dy) {
    x += dx;
    y += dy;
    if (!hasMoveTo) {
      path.moveTo(x * scaleX, -y * scaleY);
      hasMoveTo = true;
    } else {
      path.lineTo(x * scaleX, -y * scaleY);
    }
  }

  void curveTo(
    double dx1,
    double dy1,
    double dx2,
    double dy2,
    double dx3,
    double dy3,
  ) {
    final x1 = x + dx1, y1 = y + dy1;
    final x2 = x1 + dx2, y2 = y1 + dy2;
    final x3 = x2 + dx3, y3 = y2 + dy3;
    x = x3;
    y = y3;
    if (!hasMoveTo) {
      path.moveTo(x * scaleX, -y * scaleY);
      hasMoveTo = true;
    } else {
      path.cubicTo(
        x1 * scaleX,
        -y1 * scaleY,
        x2 * scaleX,
        -y2 * scaleY,
        x3 * scaleX,
        -y3 * scaleY,
        tolerance: tolerance,
      );
    }
  }

  void handleStems() {
    // Consume pairs from the stack as stems; ignore for outline.
    if (!hasWidth && (sp & 1) != 0) {
      hasWidth = true;
      // First number is width hint — skip
      stemCount += (sp - 1) >> 1;
    } else {
      stemCount += sp >> 1;
    }
    sp = 0;
  }

  int hintBytes() => (stemCount + 7) >> 3;

  // Subroutine bias (CFF spec)
  int subrBias(int count) {
    if (count < 1240) return 107;
    if (count < 33900) return 1131;
    return 32768;
  }

  // Call stack for subroutine calls
  final callStack = <(int, int)>[]; // (savedP, savedEnd)
  int maxCallDepth = 10;

  int p = start;
  while (p < end) {
    final b0 = view.getUint8(p++);

    // Operand encoding
    if (b0 >= 32) {
      // Number
      if (b0 <= 246) {
        if (sp < 48) stack[sp++] = (b0 - 139).toDouble();
      } else if (b0 <= 250) {
        if (p >= end) return false;
        final b1 = view.getUint8(p++);
        if (sp < 48) stack[sp++] = ((b0 - 247) * 256 + b1 + 108).toDouble();
      } else if (b0 <= 254) {
        if (p >= end) return false;
        final b1 = view.getUint8(p++);
        if (sp < 48) stack[sp++] = (-(b0 - 251) * 256 - b1 - 108).toDouble();
      } else {
        // b0 == 255: 32-bit fixed-point (16.16)
        if (p + 4 > end) return false;
        final val = view.getInt32(p, Endian.big);
        p += 4;
        if (sp < 48) stack[sp++] = val / 65536.0;
      }
      continue;
    }

    // Operator
    switch (b0) {
      // 28 não é operador: é o prefixo de um inteiro de 16 bits com sinal,
      // a única forma de escrever valores fora de -1131..1131 numa charstring.
      // Sem este caso o número caía no `default`, que limpa a pilha e faz o
      // glifo perder o segmento inteiro.
      case 28:
        if (p + 2 > end) return false;
        if (sp < 48) stack[sp++] = view.getInt16(p, Endian.big).toDouble();
        p += 2;
        break;

      case _T2Op.rmoveto:
        if (!hasWidth && sp > 2) hasWidth = true;
        if (hasMoveTo) path.close();
        if (sp >= 2) {
          moveTo(stack[sp - 2], stack[sp - 1]);
        }
        sp = 0;
        break;

      case _T2Op.hmoveto:
        if (!hasWidth && sp > 1) hasWidth = true;
        if (hasMoveTo) path.close();
        if (sp >= 1) {
          moveTo(stack[sp - 1], 0);
        }
        sp = 0;
        break;

      case _T2Op.vmoveto:
        if (!hasWidth && sp > 1) hasWidth = true;
        if (hasMoveTo) path.close();
        if (sp >= 1) {
          moveTo(0, stack[sp - 1]);
        }
        sp = 0;
        break;

      case _T2Op.rlineto:
        for (int i = 0; i < sp - 1; i += 2) {
          lineTo(stack[i], stack[i + 1]);
        }
        sp = 0;
        break;

      case _T2Op.hlineto:
        for (int i = 0; i < sp; i++) {
          if ((i & 1) == 0) {
            lineTo(stack[i], 0);
          } else {
            lineTo(0, stack[i]);
          }
        }
        sp = 0;
        break;

      case _T2Op.vlineto:
        for (int i = 0; i < sp; i++) {
          if ((i & 1) == 0) {
            lineTo(0, stack[i]);
          } else {
            lineTo(stack[i], 0);
          }
        }
        sp = 0;
        break;

      case _T2Op.rrcurveto:
        for (int i = 0; i + 5 < sp; i += 6) {
          curveTo(stack[i], stack[i + 1], stack[i + 2], stack[i + 3],
              stack[i + 4], stack[i + 5]);
        }
        sp = 0;
        break;

      case _T2Op.hhcurveto:
        {
          int i = 0;
          double dy1 = 0;
          if ((sp & 1) != 0) {
            dy1 = stack[i++];
          }
          while (i + 3 < sp) {
            curveTo(stack[i], dy1, stack[i + 1], stack[i + 2], stack[i + 3], 0);
            i += 4;
            dy1 = 0;
          }
        }
        sp = 0;
        break;

      case _T2Op.vvcurveto:
        {
          int i = 0;
          double dx1 = 0;
          if ((sp & 1) != 0) {
            dx1 = stack[i++];
          }
          while (i + 3 < sp) {
            curveTo(dx1, stack[i], stack[i + 1], stack[i + 2], 0, stack[i + 3]);
            i += 4;
            dx1 = 0;
          }
        }
        sp = 0;
        break;

      case _T2Op.hvcurveto:
        {
          int i = 0;
          bool startH = true;
          while (i + 3 < sp) {
            if (startH) {
              final extra = (i + 4 < sp && i + 5 >= sp) ? stack[i + 4] : 0.0;
              curveTo(
                  stack[i], 0, stack[i + 1], stack[i + 2], extra, stack[i + 3]);
              i += (extra != 0 ? 5 : 4);
            } else {
              final extra = (i + 4 < sp && i + 5 >= sp) ? stack[i + 4] : 0.0;
              curveTo(
                  0, stack[i], stack[i + 1], stack[i + 2], stack[i + 3], extra);
              i += (extra != 0 ? 5 : 4);
            }
            startH = !startH;
          }
        }
        sp = 0;
        break;

      case _T2Op.vhcurveto:
        {
          int i = 0;
          bool startV = true;
          while (i + 3 < sp) {
            if (startV) {
              final extra = (i + 4 < sp && i + 5 >= sp) ? stack[i + 4] : 0.0;
              curveTo(
                  0, stack[i], stack[i + 1], stack[i + 2], stack[i + 3], extra);
              i += (extra != 0 ? 5 : 4);
            } else {
              final extra = (i + 4 < sp && i + 5 >= sp) ? stack[i + 4] : 0.0;
              curveTo(
                  stack[i], 0, stack[i + 1], stack[i + 2], extra, stack[i + 3]);
              i += (extra != 0 ? 5 : 4);
            }
            startV = !startV;
          }
        }
        sp = 0;
        break;

      case _T2Op.rcurveline:
        {
          int i = 0;
          while (i + 7 < sp) {
            curveTo(stack[i], stack[i + 1], stack[i + 2], stack[i + 3],
                stack[i + 4], stack[i + 5]);
            i += 6;
          }
          if (i + 1 < sp) {
            lineTo(stack[i], stack[i + 1]);
          }
        }
        sp = 0;
        break;

      case _T2Op.rlinecurve:
        {
          int i = 0;
          final lineEnd = sp - 6;
          while (i + 1 < lineEnd) {
            lineTo(stack[i], stack[i + 1]);
            i += 2;
          }
          if (i + 5 < sp) {
            curveTo(stack[i], stack[i + 1], stack[i + 2], stack[i + 3],
                stack[i + 4], stack[i + 5]);
          }
        }
        sp = 0;
        break;

      case _T2Op.endchar:
        if (hasMoveTo) path.close();
        sp = 0;
        return true;

      case _T2Op.vsindex:
        if (sp < 1) return false;
        variationIndex = stack[--sp].toInt();
        if (variationIndex < 0 || variationIndex >= variationScalars.length) {
          return false;
        }
        break;

      case _T2Op.blend:
        if (sp < 1 || variationIndex >= variationScalars.length) {
          return false;
        }
        final valueCount = stack[sp - 1].toInt();
        final scalars = variationScalars[variationIndex];
        final regionCount = scalars.length;
        final required = valueCount * (regionCount + 1) + 1;
        if (valueCount < 0 || required > sp) return false;
        final first = sp - required;
        for (var value = 0; value < valueCount; value++) {
          var blended = stack[first + value];
          for (var region = 0; region < regionCount; region++) {
            blended += stack[first + valueCount * (region + 1) + value] *
                scalars[region];
          }
          stack[first + value] = blended;
        }
        sp = first + valueCount;
        break;

      case _T2Op.callsubr:
        if (localSubrs == null || sp < 1 || callStack.length >= maxCallDepth) {
          return false;
        }
        final localIndex = stack[--sp].toInt() + subrBias(localSubrs.count);
        final localRange = localSubrs.entryRange(localIndex);
        if (localRange == null) return false;
        callStack.add((p, end));
        p = localRange.$1;
        end = localRange.$2;
        break;

      case _T2Op.callgsubr:
        if (globalSubrs == null || sp < 1 || callStack.length >= maxCallDepth) {
          return false;
        }
        final globalIndex = stack[--sp].toInt() + subrBias(globalSubrs.count);
        final globalRange = globalSubrs.entryRange(globalIndex);
        if (globalRange == null) return false;
        callStack.add((p, end));
        p = globalRange.$1;
        end = globalRange.$2;
        break;

      case _T2Op.returnOp:
        if (callStack.isNotEmpty) {
          final saved = callStack.removeLast();
          p = saved.$1;
          end = saved.$2;
        }
        break;

      case _T2Op.hstem:
      case _T2Op.vstem:
      case _T2Op.hstemhm:
      case _T2Op.vstemhm:
        handleStems();
        break;

      case _T2Op.hintmask:
      case _T2Op.cntrmask:
        // If any stems remain on the stack, consume them first
        if (sp > 0) handleStems();
        // Skip hint mask bytes
        p += hintBytes();
        break;

      case 12: // escape — two-byte operators
        if (p >= end) return false;
        final b1 = view.getUint8(p++);
        // Most escape operators are hints/math that don't affect outlines.
        // Operadores de pilha e aritmética precisam ser executados: seus
        // resultados frequentemente alimentam os operadores de contorno.
        switch (b1) {
          case 3: // and
            if (sp < 2) return false;
            stack[sp - 2] = stack[sp - 2] != 0 && stack[sp - 1] != 0 ? 1 : 0;
            sp--;
            break;
          case 4: // or
            if (sp < 2) return false;
            stack[sp - 2] = stack[sp - 2] != 0 || stack[sp - 1] != 0 ? 1 : 0;
            sp--;
            break;
          case 5: // not
            if (sp < 1) return false;
            stack[sp - 1] = stack[sp - 1] == 0 ? 1 : 0;
            break;
          case 9: // abs
            if (sp < 1) return false;
            stack[sp - 1] = stack[sp - 1].abs();
            break;
          case 10: // add
            if (sp < 2) return false;
            stack[sp - 2] += stack[sp - 1];
            sp--;
            break;
          case 11: // sub
            if (sp < 2) return false;
            stack[sp - 2] -= stack[sp - 1];
            sp--;
            break;
          case 12: // div
            if (sp < 2 || stack[sp - 1] == 0) return false;
            stack[sp - 2] /= stack[sp - 1];
            sp--;
            break;
          case 14: // neg
            if (sp < 1) return false;
            stack[sp - 1] = -stack[sp - 1];
            break;
          case 15: // eq
            if (sp < 2) return false;
            stack[sp - 2] = stack[sp - 2] == stack[sp - 1] ? 1 : 0;
            sp--;
            break;
          case 18: // drop
            if (sp < 1) return false;
            sp--;
            break;
          case 20: // put
            if (sp < 2) return false;
            final index = stack[sp - 1].toInt();
            if (index < 0 || index >= transient.length) return false;
            transient[index] = stack[sp - 2];
            sp -= 2;
            break;
          case 21: // get
            if (sp < 1) return false;
            final index = stack[sp - 1].toInt();
            if (index < 0 || index >= transient.length) return false;
            stack[sp - 1] = transient[index];
            break;
          case 22: // ifelse: s1 s2 v1 v2 -> s1 ou s2
            if (sp < 4) return false;
            stack[sp - 4] =
                stack[sp - 2] <= stack[sp - 1] ? stack[sp - 4] : stack[sp - 3];
            sp -= 3;
            break;
          case 23: // random
            if (sp >= stack.length) return false;
            // LCG determinístico: renderizações repetidas devem ser idênticas.
            randomState = (1103515245 * randomState + 12345) & 0x7fffffff;
            stack[sp++] = (randomState + 1) / 0x80000000;
            break;
          case 24: // mul
            if (sp < 2) return false;
            stack[sp - 2] *= stack[sp - 1];
            sp--;
            break;
          case 26: // sqrt
            if (sp < 1 || stack[sp - 1] < 0) return false;
            stack[sp - 1] = math.sqrt(stack[sp - 1]);
            break;
          case 27: // dup
            if (sp < 1 || sp >= stack.length) return false;
            stack[sp] = stack[sp - 1];
            sp++;
            break;
          case 28: // exch
            if (sp < 2) return false;
            final value = stack[sp - 1];
            stack[sp - 1] = stack[sp - 2];
            stack[sp - 2] = value;
            break;
          case 29: // index
            if (sp < 1) return false;
            final requestedIndex = stack[sp - 1].toInt();
            // A especificação manda tratar índice negativo como zero.
            final index = requestedIndex < 0 ? 0 : requestedIndex;
            if (index >= sp - 1) return false;
            stack[sp - 1] = stack[sp - 2 - index];
            break;
          case 30: // roll
            if (sp < 2) return false;
            final shift = stack[sp - 1].toInt();
            final count = stack[sp - 2].toInt();
            sp -= 2;
            if (count < 0 || count > sp) return false;
            if (count > 1) {
              final normalized = ((shift % count) + count) % count;
              if (normalized != 0) {
                final values =
                    List<double>.generate(count, (i) => stack[sp - count + i]);
                for (var i = 0; i < count; i++) {
                  stack[sp - count + ((i + normalized) % count)] = values[i];
                }
              }
            }
            break;
          case 34: // hflex
            if (sp >= 7) {
              curveTo(stack[0], 0, stack[1], stack[2], stack[3], 0);
              curveTo(stack[4], 0, stack[5], -stack[2], stack[6], 0);
            }
            sp = 0;
            break;
          case 35: // flex
            if (sp >= 12) {
              curveTo(
                  stack[0], stack[1], stack[2], stack[3], stack[4], stack[5]);
              curveTo(
                  stack[6], stack[7], stack[8], stack[9], stack[10], stack[11]);
            }
            sp = 0;
            break;
          case 36: // hflex1
            if (sp >= 9) {
              curveTo(stack[0], stack[1], stack[2], stack[3], stack[4], 0);
              curveTo(stack[5], 0, stack[6], stack[7], stack[8],
                  -(stack[1] + stack[3] + stack[7]));
            }
            sp = 0;
            break;
          case 37: // flex1
            if (sp >= 11) {
              final dx = stack[0] + stack[2] + stack[4] + stack[6] + stack[8];
              final dy = stack[1] + stack[3] + stack[5] + stack[7] + stack[9];
              if (dx.abs() > dy.abs()) {
                curveTo(
                    stack[0], stack[1], stack[2], stack[3], stack[4], stack[5]);
                curveTo(stack[6], stack[7], stack[8], stack[9], stack[10], -dy);
              } else {
                curveTo(
                    stack[0], stack[1], stack[2], stack[3], stack[4], stack[5]);
                curveTo(stack[6], stack[7], stack[8], stack[9], -dx, stack[10]);
              }
            }
            sp = 0;
            break;
          default:
            // Unknown escape operator — clear stack
            sp = 0;
            break;
        }
        break;

      default:
        // Unknown operator — ignore
        sp = 0;
        break;
    }
  }

  if (hasMoveTo) path.close();
  return true;
}

// ---------------------------------------------------------------------------
// Parser de DICT (Top DICT / Private DICT)
// ---------------------------------------------------------------------------

/// Chave de um operador de dois bytes (`12 x`) dentro do mapa devolvido por
/// [_parseDict]. Operadores de um byte usam o próprio valor como chave.
int _escOp(int b1) => 1200 + b1;

/// Le um DICT do CFF inteiro e devolve `operador -> operandos`.
///
/// O parser precisa decodificar números reais de verdade (e não trata-los como
/// zero) porque o FontMatrix — de onde sai o unitsPerEm — é justamente uma
/// lista de reais.
Map<int, List<double>> _parseDict(ByteData view, int start, int end) {
  final out = <int, List<double>>{};
  var operands = <double>[];
  var p = start;

  while (p < end) {
    final b0 = view.getUint8(p++);

    if (b0 >= 32 && b0 <= 246) {
      operands.add((b0 - 139).toDouble());
    } else if (b0 >= 247 && b0 <= 250) {
      if (p >= end) break;
      final b1 = view.getUint8(p++);
      operands.add(((b0 - 247) * 256 + b1 + 108).toDouble());
    } else if (b0 >= 251 && b0 <= 254) {
      if (p >= end) break;
      final b1 = view.getUint8(p++);
      operands.add((-(b0 - 251) * 256 - b1 - 108).toDouble());
    } else if (b0 == 28) {
      if (p + 2 > end) break;
      operands.add(view.getInt16(p, Endian.big).toDouble());
      p += 2;
    } else if (b0 == 29) {
      if (p + 4 > end) break;
      operands.add(view.getInt32(p, Endian.big).toDouble());
      p += 4;
    } else if (b0 == 30) {
      // Real codificado em nibbles (BCD).
      final text = StringBuffer();
      var done = false;
      while (p < end && !done) {
        final byte = view.getUint8(p++);
        for (final nibble in <int>[byte >> 4, byte & 0x0F]) {
          if (nibble <= 9) {
            text.write(nibble);
          } else if (nibble == 0x0A) {
            text.write('.');
          } else if (nibble == 0x0B) {
            text.write('E');
          } else if (nibble == 0x0C) {
            text.write('E-');
          } else if (nibble == 0x0E) {
            text.write('-');
          } else if (nibble == 0x0F) {
            done = true;
            break;
          }
          // 0x0D é reservado: ignorado.
        }
      }
      operands.add(double.tryParse(text.toString()) ?? 0.0);
    } else if (b0 == 12) {
      if (p >= end) break;
      final b1 = view.getUint8(p++);
      out[_escOp(b1)] = operands;
      operands = <double>[];
    } else {
      out[b0] = operands;
      operands = <double>[];
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// Estrutura de um CFF: header + INDEXes de topo + Top DICT
// ---------------------------------------------------------------------------

/// Operadores de DICT usados aqui.
class _CFFOp {
  static const int fontBBox = 5;
  static const int charset = 15;
  static const int encoding = 16;
  static const int charStrings = 17;
  static const int private = 18;
  static const int localSubrs = 19; // dentro do Private DICT
  static const int vstore = 24;
  static const int fontMatrix = 1207;
  static const int ros = 1230; // presente apenas em CIDFonts
  static const int fdArray = 1236;
  static const int fdSelect = 1237;
}

/// Resultado da leitura da "espinha dorsal" de um CFF.
///
/// Os deslocamentos guardados aqui já são absolutos dentro do [view]: um CFF
/// puro tem `cffOffset == 0`, um OpenType/CFF tem o offset da tabela `CFF `.
class _CFFStructure {
  final ByteData view;
  final int cffOffset;
  final int cffEnd;
  final _CFFIndex? nameIndex;
  final _CFFIndex? topDictIndex;
  final _CFFIndex? stringIndex;
  final _CFFIndex? globalSubrs;
  final Map<int, List<double>> topDict;
  final _CFFIndex charStrings;
  final bool isCff2;
  final _CFFVariationStore? variationStore;

  const _CFFStructure({
    required this.view,
    required this.cffOffset,
    required this.cffEnd,
    required this.nameIndex,
    required this.topDictIndex,
    required this.stringIndex,
    required this.globalSubrs,
    required this.topDict,
    required this.charStrings,
    required this.isCff2,
    this.variationStore,
  });

  /// INDEX de subrotinas locais, extraido do Private DICT (se houver).
  _CFFIndex? get localSubrs {
    return _localSubrsFromDict(topDict);
  }

  _CFFIndex? _localSubrsFromDict(Map<int, List<double>> dict) {
    final priv = dict[_CFFOp.private];
    if (priv == null || priv.length < 2) return null;
    final privSize = priv[0].toInt();
    final privOffset = cffOffset + priv[1].toInt();
    if (privSize <= 0 ||
        privOffset < cffOffset ||
        privOffset + privSize > cffEnd) {
      return null;
    }
    final privDict = _parseDict(view, privOffset, privOffset + privSize);
    final subrs = privDict[_CFFOp.localSubrs];
    if (subrs == null || subrs.isEmpty) return null;
    // O offset de Subrs é relativo ao início do Private DICT, não ao CFF.
    final index = _CFFIndex.parse(view, privOffset + subrs.last.toInt(),
        countSize: isCff2 ? 4 : 2);
    return index != null && index.endOffset <= cffEnd ? index : null;
  }

  /// Subrotinas do Font DICT selecionado por FDSelect num CID-keyed CFF.
  _CFFIndex? localSubrsForGlyph(int glyphId) {
    final fdArrayOperands = topDict[_CFFOp.fdArray];
    final fdSelectOperands = topDict[_CFFOp.fdSelect];
    if (fdArrayOperands == null ||
        fdArrayOperands.isEmpty ||
        fdSelectOperands == null ||
        fdSelectOperands.isEmpty) {
      return localSubrs;
    }
    final array = _CFFIndex.parse(
        view, cffOffset + fdArrayOperands.last.toInt(),
        countSize: isCff2 ? 4 : 2);
    if (array == null || array.endOffset > cffEnd) return null;
    final fd =
        _fontDictForGlyph(cffOffset + fdSelectOperands.last.toInt(), glyphId);
    if (fd == null || fd < 0 || fd >= array.count) return null;
    final range = array.entryRange(fd);
    if (range == null) return null;
    return _localSubrsFromDict(_parseDict(view, range.$1, range.$2));
  }

  int? _fontDictForGlyph(int offset, int glyphId) {
    if (glyphId < 0 ||
        glyphId >= charStrings.count ||
        offset < cffOffset ||
        offset >= cffEnd) {
      return null;
    }
    final format = view.getUint8(offset);
    if (format == 0) {
      final at = offset + 1 + glyphId;
      return at < cffEnd ? view.getUint8(at) : null;
    }
    if (format != 3 || offset + 3 > cffEnd) return null;
    final ranges = view.getUint16(offset + 1, Endian.big);
    var p = offset + 3;
    if (ranges == 0 || p + ranges * 3 + 2 > cffEnd) return null;
    final sentinel = view.getUint16(offset + 3 + ranges * 3, Endian.big);
    if (view.getUint16(p, Endian.big) != 0 || sentinel != charStrings.count) {
      return null;
    }
    for (var i = 0; i < ranges; i++) {
      final first = view.getUint16(p, Endian.big);
      final fd = view.getUint8(p + 2);
      final next =
          i + 1 < ranges ? view.getUint16(p + 3, Endian.big) : sentinel;
      if (next <= first) return null;
      if (glyphId >= first && glyphId < next) return fd;
      p += 3;
    }
    return null;
  }

  /// Le o header e os quatro INDEXes de topo. Devolve `null` se algo não
  /// bater — o que também serve de validação para detectar um CFF puro.
  static _CFFStructure? parse(ByteData view, int cffOffset, int cffLength) {
    if (cffOffset < 0 || cffLength < 4) return null;
    if (cffOffset + cffLength > view.lengthInBytes) return null;
    final cffEnd = cffOffset + cffLength;

    final major = view.getUint8(cffOffset);
    if (major != 1 && major != 2) return null;
    final headerSize = view.getUint8(cffOffset + 2);
    if (headerSize < 4 || headerSize >= cffLength) return null;

    if (major == 2) {
      if (headerSize < 5 || cffOffset + 5 > cffEnd) return null;
      final topDictLength = view.getUint16(cffOffset + 3, Endian.big);
      final topStart = cffOffset + headerSize;
      final topEnd = topStart + topDictLength;
      if (topDictLength <= 0 || topEnd > cffEnd) return null;
      final topDict = _parseDict(view, topStart, topEnd);
      final globalSubrs = _CFFIndex.parse(view, topEnd, countSize: 4);
      if (globalSubrs == null || globalSubrs.endOffset > cffEnd) return null;
      final csOperands = topDict[_CFFOp.charStrings];
      if (csOperands == null || csOperands.isEmpty) return null;
      final charStrings = _CFFIndex.parse(
          view, cffOffset + csOperands.last.toInt(),
          countSize: 4);
      if (charStrings == null ||
          charStrings.count == 0 ||
          charStrings.endOffset > cffEnd) {
        return null;
      }
      return _CFFStructure(
        view: view,
        cffOffset: cffOffset,
        cffEnd: cffEnd,
        nameIndex: null,
        topDictIndex: null,
        stringIndex: null,
        globalSubrs: globalSubrs,
        topDict: topDict,
        charStrings: charStrings,
        isCff2: true,
        variationStore: _parseVariationStore(view, cffOffset, cffEnd, topDict),
      );
    }

    final nameIndex = _CFFIndex.parse(view, cffOffset + headerSize);
    if (nameIndex == null || nameIndex.endOffset > cffEnd) return null;

    final topDictIndex = _CFFIndex.parse(view, nameIndex.endOffset);
    if (topDictIndex == null ||
        topDictIndex.count == 0 ||
        topDictIndex.endOffset > cffEnd) {
      return null;
    }

    final stringIndex = _CFFIndex.parse(view, topDictIndex.endOffset);
    final globalSubrs = stringIndex == null
        ? null
        : _CFFIndex.parse(view, stringIndex.endOffset);
    if (stringIndex == null ||
        stringIndex.endOffset > cffEnd ||
        globalSubrs == null ||
        globalSubrs.endOffset > cffEnd) {
      return null;
    }

    final topRange = topDictIndex.entryRange(0);
    if (topRange == null) return null;
    final topDict = _parseDict(view, topRange.$1, topRange.$2);

    final csOperands = topDict[_CFFOp.charStrings];
    if (csOperands == null || csOperands.isEmpty) return null;
    final charStrings =
        _CFFIndex.parse(view, cffOffset + csOperands.last.toInt());
    if (charStrings == null ||
        charStrings.count == 0 ||
        charStrings.endOffset > cffEnd) {
      return null;
    }

    return _CFFStructure(
      view: view,
      cffOffset: cffOffset,
      cffEnd: cffEnd,
      nameIndex: nameIndex,
      topDictIndex: topDictIndex,
      stringIndex: stringIndex,
      globalSubrs: globalSubrs,
      topDict: topDict,
      charStrings: charStrings,
      isCff2: false,
    );
  }
}

class _CFFVariationStore {
  final List<List<(double, double, double)>> regions;
  final List<List<int>> regionIndices;

  const _CFFVariationStore(this.regions, this.regionIndices);

  List<List<double>> scalars(List<double> coordinates) => <List<double>>[
        for (final indices in regionIndices)
          <double>[
            for (final index in indices) _scalar(regions[index], coordinates)
          ]
      ];

  static double _scalar(
      List<(double, double, double)> axes, List<double> coordinates) {
    var result = 1.0;
    for (var axis = 0; axis < axes.length; axis++) {
      final (start, peak, end) = axes[axis];
      final coordinate =
          axis < coordinates.length ? coordinates[axis].clamp(-1.0, 1.0) : 0.0;
      if (peak == 0 || start > peak || peak > end) continue;
      if (coordinate < start || coordinate > end) return 0;
      if (coordinate == peak) continue;
      if (coordinate < peak) {
        if (peak == start) continue;
        result *= (coordinate - start) / (peak - start);
      } else {
        if (peak == end) continue;
        result *= (end - coordinate) / (end - peak);
      }
    }
    return result;
  }
}

_CFFVariationStore? _parseVariationStore(
    ByteData view, int cffOffset, int cffEnd, Map<int, List<double>> topDict) {
  final operands = topDict[_CFFOp.vstore];
  if (operands == null || operands.isEmpty) return null;
  final start = cffOffset + operands.last.toInt();
  if (start < cffOffset || start + 8 > cffEnd) return null;
  if (view.getUint16(start, Endian.big) != 1) return null;
  final regionListOffset = view.getUint32(start + 2, Endian.big);
  final count = view.getUint16(start + 6, Endian.big);
  if (count == 0 || start + 8 + count * 4 > cffEnd) return null;
  final regionIndices = <List<int>>[];
  for (var i = 0; i < count; i++) {
    final relative = view.getUint32(start + 8 + i * 4, Endian.big);
    final data = start + relative;
    if (data < start || data + 6 > cffEnd) return null;
    final regionCount = view.getUint16(data + 4, Endian.big);
    if (data + 6 + regionCount * 2 > cffEnd) return null;
    regionIndices.add(<int>[
      for (var j = 0; j < regionCount; j++)
        view.getUint16(data + 6 + j * 2, Endian.big)
    ]);
  }
  final regionList = start + regionListOffset;
  if (regionList < start || regionList + 4 > cffEnd) return null;
  final axisCount = view.getUint16(regionList, Endian.big);
  final regionCount = view.getUint16(regionList + 2, Endian.big);
  final bytes = axisCount * regionCount * 6;
  if (regionList + 4 + bytes > cffEnd) return null;
  final regions = <List<(double, double, double)>>[];
  var at = regionList + 4;
  for (var region = 0; region < regionCount; region++) {
    final axes = <(double, double, double)>[];
    for (var axis = 0; axis < axisCount; axis++) {
      double fixed(int offset) => view.getInt16(offset, Endian.big) / 16384.0;
      axes.add((fixed(at), fixed(at + 2), fixed(at + 4)));
      at += 6;
    }
    regions.add(axes);
  }
  if (regionIndices.any((set) => set.any((index) => index >= regions.length))) {
    return null;
  }
  return _CFFVariationStore(regions, regionIndices);
}

// ---------------------------------------------------------------------------
// Charset -> nomes de glifo
// ---------------------------------------------------------------------------

/// Le o charset e devolve o SID de cada GID (índice = GID).
///
/// Devolve `null` para os charsets predefinidos Expert (1) e ExpertSubset (2),
/// que não são tabelados aqui.
List<int>? _parseCharsetSids(
  ByteData view,
  int cffOffset,
  int charsetOffset,
  int glyphCount,
) {
  if (glyphCount <= 0) return null;

  // Charset 0 = ISOAdobe: a ordem dos glifos é a das strings padrão, ou seja
  // SID == GID. E' o caso quando o Top DICT nem traz o operador `charset`.
  if (charsetOffset == 0) {
    return List<int>.generate(glyphCount, (gid) => gid);
  }
  if (charsetOffset == 1 || charsetOffset == 2) return null;

  final base = cffOffset + charsetOffset;
  if (base < 0 || base >= view.lengthInBytes) return null;

  final sids = List<int>.filled(glyphCount, 0);
  final format = view.getUint8(base);
  var p = base + 1;

  if (format == 0) {
    for (var gid = 1; gid < glyphCount; gid++) {
      if (p + 2 > view.lengthInBytes) return null;
      sids[gid] = view.getUint16(p, Endian.big);
      p += 2;
    }
    return sids;
  }

  if (format == 1 || format == 2) {
    final nLeftBytes = format == 1 ? 1 : 2;
    var gid = 1;
    while (gid < glyphCount) {
      if (p + 2 + nLeftBytes > view.lengthInBytes) return null;
      final first = view.getUint16(p, Endian.big);
      p += 2;
      final nLeft =
          nLeftBytes == 1 ? view.getUint8(p) : view.getUint16(p, Endian.big);
      p += nLeftBytes;
      for (var i = 0; i <= nLeft && gid < glyphCount; i++) {
        sids[gid++] = first + i;
      }
    }
    return sids;
  }

  return null;
}

// ---------------------------------------------------------------------------
// Encoding -> código de caractere
// ---------------------------------------------------------------------------

/// Monta o mapa `código (0..255) -> GID` a partir do Encoding do CFF.
///
/// Um CFF puro não tem `cmap`; o equivalente é este Encoding, e quando o Top
/// DICT não o declara vale o Standard Encoding. E' o que faz um consumidor
/// genérico conseguir resolver 'A' sem saber nada do PDF em volta.
Map<int, int> _buildCodeToGlyphId(
  ByteData view,
  int cffOffset,
  int encodingOffset,
  int glyphCount,
  List<int> sids,
  Map<String, int> nameToGlyphId,
) {
  final out = <int, int>{};

  if (encodingOffset == 0 || encodingOffset == 1) {
    // Encodings predefinidos: código -> SID -> nome -> GID.
    final entries = encodingOffset == 0
        ? cffStandardEncodingSids.asMap().entries
        : cffExpertEncodingSids.entries;
    for (final entry in entries) {
      final code = entry.key;
      final sid = entry.value;
      if (sid == 0) continue;
      final gid = nameToGlyphId[cffStandardStrings[sid]];
      if (gid != null && gid != 0) out[code] = gid;
    }
    return out;
  }

  final base = cffOffset + encodingOffset;
  if (base < 0 || base >= view.lengthInBytes) return out;

  final b0 = view.getUint8(base);
  final format = b0 & 0x7F;
  var p = base + 1;

  if (format == 0) {
    if (p >= view.lengthInBytes) return out;
    final nCodes = view.getUint8(p++);
    for (var gid = 1; gid <= nCodes && p < view.lengthInBytes; gid++) {
      final code = view.getUint8(p++);
      if (gid < glyphCount) out.putIfAbsent(code, () => gid);
    }
  } else if (format == 1) {
    if (p >= view.lengthInBytes) return out;
    final nRanges = view.getUint8(p++);
    var gid = 1;
    for (var r = 0; r < nRanges && p + 2 <= view.lengthInBytes; r++) {
      final first = view.getUint8(p++);
      final nLeft = view.getUint8(p++);
      for (var i = 0; i <= nLeft; i++) {
        if (gid < glyphCount) out.putIfAbsent(first + i, () => gid);
        gid++;
      }
    }
  } else {
    return out;
  }

  // O bit alto do formato indica que seguem "supplements": pares
  // código -> SID que dao um segundo código a um glifo já mapeado.
  if ((b0 & 0x80) != 0 && p < view.lengthInBytes) {
    final nSups = view.getUint8(p++);
    for (var i = 0; i < nSups && p + 3 <= view.lengthInBytes; i++) {
      final code = view.getUint8(p++);
      final sid = view.getUint16(p, Endian.big);
      p += 2;
      final gid = sids.indexOf(sid);
      if (gid > 0) out[code] = gid;
    }
  }

  return out;
}

// ---------------------------------------------------------------------------
// Metadados de um CFF (API publica)
// ---------------------------------------------------------------------------

/// Informações estruturais de uma fonte CFF, o suficiente para montar uma
/// face quando não existe um contêiner sfnt em volta.
///
/// Um PDF embute fontes assim em `/FontFile3` com `/Subtype /Type1C`: não há
/// `maxp` de onde tirar a contagem de glifos, nem `head` de onde tirar o
/// unitsPerEm, nem `cmap` para mapear códigos. Tudo isso sai daqui.
class BLCFFInfo {
  /// Número de glifos = número de entradas do CharStrings INDEX.
  final int glyphCount;

  /// Unidades por em, derivadas do FontMatrix (`1 / matrix[0]`).
  final int unitsPerEm;

  /// FontMatrix declarado (ou o padrão `[0.001, 0, 0, 0.001, 0, 0]`).
  final List<double> fontMatrix;

  /// FontBBox declarado (`[xMin, yMin, xMax, yMax]`), ou `null` se ausente.
  final List<double>? fontBBox;

  /// Nome PostScript (primeira entrada do Name INDEX).
  final String name;

  /// `true` quando a fonte é um CIDFont: o charset mapeia GID -> CID, e não
  /// GID -> SID, então não há nomes de glifo a extrair.
  final bool isCID;

  /// Nome de cada glifo por GID; vazio em CIDFonts ou charsets não suportados.
  final List<String> glyphNames;

  /// Nome do glifo -> GID. Em caso de nomes repetidos, vence o menor GID.
  final Map<String, int> nameToGlyphId;

  /// Código de caractere (0..255) -> GID, vindo do Encoding do CFF.
  ///
  /// E' o substituto do `cmap` num CFF puro. Vazio em CIDFonts.
  final Map<int, int> codeToGlyphId;

  /// CID -> GID vindo do charset de uma fonte CID-keyed.
  ///
  /// Diferentemente de uma fonte CFF por nomes, os valores do charset são
  /// CIDs. Um consumidor PDF usa este mapa quando o CIDFontType0 não possui
  /// `/CIDToGIDMap` (esse mapa é próprio de CIDFontType2/TrueType).
  final Map<int, int> cidToGlyphId;

  const BLCFFInfo({
    required this.glyphCount,
    required this.unitsPerEm,
    required this.fontMatrix,
    required this.fontBBox,
    required this.name,
    required this.isCID,
    required this.glyphNames,
    required this.nameToGlyphId,
    required this.codeToGlyphId,
    required this.cidToGlyphId,
  });

  /// Le os metadados de um bloco CFF em [view], começando em [cffOffset].
  ///
  /// Serve tanto para um CFF puro (`cffOffset = 0`, `cffLength = data.length`)
  /// quanto para a tabela `CFF ` de um OpenType.
  static BLCFFInfo? parse(ByteData view, int cffOffset, int cffLength) {
    final cff = _CFFStructure.parse(view, cffOffset, cffLength);
    if (cff == null) return null;

    final glyphCount = cff.charStrings.count;

    // FontMatrix: 0.001 é o padrão do CFF e corresponde a um em de 1000.
    var matrix = const <double>[0.001, 0.0, 0.0, 0.001, 0.0, 0.0];
    final declared = cff.topDict[_CFFOp.fontMatrix];
    if (declared != null && declared.length >= 6) {
      matrix = List<double>.unmodifiable(declared.sublist(0, 6));
    }
    var unitsPerEm = 1000;
    final sx = matrix[0];
    if (sx.isFinite && sx > 0) {
      final derived = (1.0 / sx).round();
      // Um em fora desta faixa só pode vir de dado corrompido; cair no padrão
      // é melhor do que propagar uma escala absurda para o rasterizador.
      if (derived >= 16 && derived <= 16384) unitsPerEm = derived;
    }

    List<double>? bbox;
    final bboxOperands = cff.topDict[_CFFOp.fontBBox];
    if (bboxOperands != null && bboxOperands.length >= 4) {
      bbox = List<double>.unmodifiable(bboxOperands.sublist(0, 4));
    }

    var name = '';
    final nameRange = cff.nameIndex?.entryRange(0);
    if (nameRange != null) {
      name = _latin1(view, nameRange.$1, nameRange.$2);
    }

    final isCID = cff.topDict.containsKey(_CFFOp.ros);

    final glyphNames = <String>[];
    final nameToGlyphId = <String, int>{};
    var codeToGlyphId = const <int, int>{};
    var cidToGlyphId = const <int, int>{};
    if (!cff.isCff2 && !isCID) {
      final charsetOffset = cff.topDict[_CFFOp.charset]?.last.toInt() ?? 0;
      final sids =
          _parseCharsetSids(view, cffOffset, charsetOffset, glyphCount);
      if (sids != null) {
        for (var gid = 0; gid < glyphCount; gid++) {
          final glyphName = _sidToName(view, cff.stringIndex, sids[gid]);
          glyphNames.add(glyphName);
          if (glyphName.isNotEmpty) {
            nameToGlyphId.putIfAbsent(glyphName, () => gid);
          }
        }
        final encodingOffset = cff.topDict[_CFFOp.encoding]?.last.toInt() ?? 0;
        codeToGlyphId = _buildCodeToGlyphId(
          view,
          cffOffset,
          encodingOffset,
          glyphCount,
          sids,
          nameToGlyphId,
        );
      }
    } else if (!cff.isCff2) {
      final charsetOffset = cff.topDict[_CFFOp.charset]?.last.toInt() ?? 0;
      final cids =
          _parseCharsetSids(view, cffOffset, charsetOffset, glyphCount);
      if (cids != null) {
        final mapped = <int, int>{};
        for (var gid = 0; gid < cids.length; gid++) {
          mapped.putIfAbsent(cids[gid], () => gid);
        }
        cidToGlyphId = mapped;
      }
    }

    return BLCFFInfo(
      glyphCount: glyphCount,
      unitsPerEm: unitsPerEm,
      fontMatrix: matrix,
      fontBBox: bbox,
      name: name,
      isCID: isCID,
      glyphNames: List<String>.unmodifiable(glyphNames),
      nameToGlyphId: Map<String, int>.unmodifiable(nameToGlyphId),
      codeToGlyphId: Map<int, int>.unmodifiable(codeToGlyphId),
      cidToGlyphId: Map<int, int>.unmodifiable(cidToGlyphId),
    );
  }

  /// Resolve um SID para o nome correspondente.
  ///
  /// SIDs abaixo de 391 vêm da tabela de strings padrão do CFF; acima disso o
  /// índice `sid - 391` aponta para o String INDEX da própria fonte.
  static String _sidToName(ByteData view, _CFFIndex? stringIndex, int sid) {
    if (sid < 0) return '';
    if (sid < cffStandardStrings.length) return cffStandardStrings[sid];
    if (stringIndex == null) return '';
    final range = stringIndex.entryRange(sid - cffStandardStrings.length);
    if (range == null) return '';
    return _latin1(view, range.$1, range.$2);
  }

  static String _latin1(ByteData view, int start, int end) {
    if (start < 0 || end > view.lengthInBytes || end <= start) return '';
    final buffer = StringBuffer();
    for (var i = start; i < end; i++) {
      buffer.writeCharCode(view.getUint8(i));
    }
    return buffer.toString();
  }
}

// ---------------------------------------------------------------------------
// CFF font outline decoder (public API)
// ---------------------------------------------------------------------------

/// Decodifica contornos de glifo a partir de um bloco CFF.
///
/// [cffOffset] e [cffLength] delimitam o CFF dentro do buffer: a tabela
/// `CFF ` de um OpenType, ou o arquivo inteiro no caso de um CFF puro.
class BLCFFDecoder {
  const BLCFFDecoder._();

  /// Diz se [data] é um CFF "puro" (bare CFF / Type1C), sem contêiner sfnt.
  ///
  /// A detecção é deliberadamente conservadora: além de exigir o header CFF
  /// (`major = 1`, `minor = 0`, `hdrSize` e `offSize` plausíveis), recusa
  /// qualquer `sfntVersion` conhecido e só aceita se a estrutura inteira até
  /// o CharStrings INDEX puder ser lida. Classificar um sfnt errado aqui
  /// custaria uma fonte inteira sem glifos, então vale errar para o lado de
  /// não detectar.
  static bool looksLikeBareCFF(Uint8List data) {
    if (data.length < 8) return false;

    // Versões de sfnt conhecidas: 1.0 (TrueType), 'OTTO', 'true', 'ttcf' e
    // 'typ1'. Nenhuma começa com 0x01 0x00, mas a checagem fica explicita.
    final tag = (data[0] << 24) | (data[1] << 16) | (data[2] << 8) | data[3];
    const sfntVersions = <int>[
      0x00010000, // TrueType
      0x4F54544F, // 'OTTO'
      0x74727565, // 'true'
      0x74746366, // 'ttcf'
      0x74797031, // 'typ1'
    ];
    if (sfntVersions.contains(tag)) return false;

    if (data[0] != 1 || data[1] != 0) return false; // major.minor = 1.0
    final headerSize = data[2];
    final offSize = data[3];
    if (headerSize < 4 || headerSize >= data.length) return false;
    if (offSize < 1 || offSize > 4) return false;

    // Validação estrutural: sem um CharStrings INDEX legível não seria um CFF
    // utilizável de qualquer forma.
    final view = ByteData.sublistView(data);
    return _CFFStructure.parse(view, 0, data.length) != null;
  }

  /// Decodifica o contorno do glifo [glyphId].
  ///
  /// Percorre header, Name INDEX, Top DICT INDEX, String INDEX, Global Subr
  /// INDEX e CharStrings INDEX para localizar e interpretar a charstring.
  static BLPathData? decodeGlyph(
    ByteData view,
    int cffOffset,
    int cffLength,
    int glyphId, {
    double scaleX = 1.0,
    double scaleY = 1.0,
    List<double> variationCoordinates = const <double>[],
    double tolerance = 0.25,
  }) {
    final cff = _CFFStructure.parse(view, cffOffset, cffLength);
    if (cff == null) return null;

    final csRange = cff.charStrings.entryRange(glyphId);
    if (csRange == null) return null;

    final path = BLPath();
    final ok = _interpretCharstring(
      path,
      view,
      csRange.$1,
      csRange.$2,
      scaleX,
      scaleY,
      0,
      0,
      localSubrs: cff.localSubrsForGlyph(glyphId),
      globalSubrs: cff.globalSubrs,
      variationScalars: cff.variationStore?.scalars(variationCoordinates) ??
          const <List<double>>[<double>[]],
      tolerance: tolerance,
    );
    if (!ok) return null;

    return path.toPathData();
  }
}
