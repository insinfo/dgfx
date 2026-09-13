/// OpenType GSUB/GPOS layout engine (port of Blend2D's `otlayout.cpp`).
///
/// Parses GSUB and GPOS tables and applies lookups for:
///   - GSUB Type 1 (SingleSubst): single glyph substitution
///   - GSUB Type 4 (LigatureSubst): ligature formation
///   - GPOS Type 2 (PairAdjustment): pair kerning/positioning
///
/// Inspired by: `blend2d/opentype/otlayout.cpp`, `otlayouttables_p.h`
library;

import 'dart:typed_data';

// ---------------------------------------------------------------------------
// Coverage table parser (shared by GSUB and GPOS)
// ---------------------------------------------------------------------------

/// Looks up [glyphId] in a CoverageTable at [offset] within [view].
/// Returns the coverage index, or -1 if not found.
int _coverageLookup(ByteData view, int tableStart, int offset, int glyphId) {
  final absOff = tableStart + offset;
  if (absOff + 4 > view.lengthInBytes) return -1;
  final format = view.getUint16(absOff, Endian.big);
  final count = view.getUint16(absOff + 2, Endian.big);

  if (format == 1) {
    // Format 1: array of glyph IDs (binary search)
    if (absOff + 4 + count * 2 > view.lengthInBytes) return -1;
    int lo = 0, hi = count - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >>> 1;
      final g = view.getUint16(absOff + 4 + mid * 2, Endian.big);
      if (g == glyphId) return mid;
      if (g < glyphId) {
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return -1;
  } else if (format == 2) {
    // Format 2: array of ranges (binary search)
    if (absOff + 4 + count * 6 > view.lengthInBytes) return -1;
    int lo = 0, hi = count - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >>> 1;
      final rangeOff = absOff + 4 + mid * 6;
      final first = view.getUint16(rangeOff, Endian.big);
      final last = view.getUint16(rangeOff + 2, Endian.big);
      if (glyphId < first) {
        hi = mid - 1;
      } else if (glyphId > last) {
        lo = mid + 1;
      } else {
        final startIdx = view.getUint16(rangeOff + 4, Endian.big);
        return startIdx + (glyphId - first);
      }
    }
    return -1;
  }
  return -1;
}

/// Counts the number of set bits corresponding to ValueFormat flags.
/// Each flag = one Int16 value record field.
int _valueRecordSize(int valueFormat) {
  int count = 0;
  int f = valueFormat & 0xFF;
  while (f != 0) {
    count += f & 1;
    f >>>= 1;
  }
  return count * 2; // each field is 2 bytes
}

// ---------------------------------------------------------------------------
// GSUB Lookup Type 1: Single Substitution
// ---------------------------------------------------------------------------

/// Applies GSUB SingleSubst at [subtableOffset] to [glyphId].
/// Returns the substituted glyph ID, or -1 if not applicable.
int _applySingleSubst(ByteData view, int subtableOffset, int glyphId) {
  if (subtableOffset + 6 > view.lengthInBytes) return -1;
  final format = view.getUint16(subtableOffset, Endian.big);
  final coverageOffset = view.getUint16(subtableOffset + 2, Endian.big);

  final covIdx = _coverageLookup(view, subtableOffset, coverageOffset, glyphId);
  if (covIdx < 0) return -1;

  if (format == 1) {
    // Format 1: delta
    final delta = view.getInt16(subtableOffset + 4, Endian.big);
    return (glyphId + delta) & 0xFFFF;
  } else if (format == 2) {
    // Format 2: array of substitute glyphs
    final count = view.getUint16(subtableOffset + 4, Endian.big);
    if (covIdx >= count) return -1;
    return view.getUint16(subtableOffset + 6 + covIdx * 2, Endian.big);
  }
  return -1;
}

// ---------------------------------------------------------------------------
// GSUB Lookup Type 4: Ligature Substitution
// ---------------------------------------------------------------------------

/// Result of a ligature match: the replacement glyph and the number of
/// input glyphs consumed (including the first).
class _LigatureResult {
  final int ligatureGlyph;
  final int componentCount;
  const _LigatureResult(this.ligatureGlyph, this.componentCount);
}

/// Attempts to apply GSUB LigatureSubst at [subtableOffset].
/// [glyphIds] is the full glyph array; [index] is the current position.
/// Returns a [_LigatureResult] or null if no match.
_LigatureResult? _applyLigatureSubst(
  ByteData view,
  int subtableOffset,
  List<int> glyphIds,
  int index,
) {
  if (subtableOffset + 6 > view.lengthInBytes) return null;
  final format = view.getUint16(subtableOffset, Endian.big);
  if (format != 1) return null;

  final coverageOffset = view.getUint16(subtableOffset + 2, Endian.big);
  final covIdx =
      _coverageLookup(view, subtableOffset, coverageOffset, glyphIds[index]);
  if (covIdx < 0) return null;

  final ligSetCount = view.getUint16(subtableOffset + 4, Endian.big);
  if (covIdx >= ligSetCount) return null;

  final ligSetOffset = subtableOffset +
      view.getUint16(subtableOffset + 6 + covIdx * 2, Endian.big);
  if (ligSetOffset + 2 > view.lengthInBytes) return null;

  final ligCount = view.getUint16(ligSetOffset, Endian.big);

  for (int li = 0; li < ligCount; li++) {
    final ligOff =
        ligSetOffset + view.getUint16(ligSetOffset + 2 + li * 2, Endian.big);
    if (ligOff + 4 > view.lengthInBytes) continue;

    final ligGlyph = view.getUint16(ligOff, Endian.big);
    final compCount = view.getUint16(ligOff + 2, Endian.big);
    if (compCount < 2) continue;
    if (index + compCount - 1 >= glyphIds.length) continue;
    if (ligOff + 4 + (compCount - 1) * 2 > view.lengthInBytes) continue;

    bool match = true;
    for (int ci = 0; ci < compCount - 1; ci++) {
      final expected = view.getUint16(ligOff + 4 + ci * 2, Endian.big);
      if (glyphIds[index + 1 + ci] != expected) {
        match = false;
        break;
      }
    }
    if (match) {
      return _LigatureResult(ligGlyph, compCount);
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// GSUB Lookup Type 2: Multiple Substitution
// ---------------------------------------------------------------------------

/// Applies GSUB MultipleSubst at [subtableOffset] to [glyphId].
/// Returns a list of replacement glyphs, or null if no match.
List<int>? _applyMultipleSubst(ByteData view, int subtableOffset, int glyphId) {
  if (subtableOffset + 6 > view.lengthInBytes) return null;
  final format = view.getUint16(subtableOffset, Endian.big);
  if (format != 1) return null;

  final coverageOffset = view.getUint16(subtableOffset + 2, Endian.big);
  final covIdx = _coverageLookup(view, subtableOffset, coverageOffset, glyphId);
  if (covIdx < 0) return null;

  final sequenceCount = view.getUint16(subtableOffset + 4, Endian.big);
  if (covIdx >= sequenceCount) return null;

  final sequenceOffset = subtableOffset +
      view.getUint16(subtableOffset + 6 + covIdx * 2, Endian.big);
  if (sequenceOffset + 2 > view.lengthInBytes) return null;

  final glyphCount = view.getUint16(sequenceOffset, Endian.big);
  if (sequenceOffset + 2 + glyphCount * 2 > view.lengthInBytes) return null;

  final replacements = <int>[];
  for (int i = 0; i < glyphCount; i++) {
    replacements.add(view.getUint16(sequenceOffset + 2 + i * 2, Endian.big));
  }
  return replacements;
}

// ---------------------------------------------------------------------------
// GSUB Lookup Type 3: Alternate Substitution
// ---------------------------------------------------------------------------

/// Applies GSUB AlternateSubst at [subtableOffset] to [glyphId].
/// For bootstrap, we always pick the first alternate (index 0).
/// Returns the alternate glyph ID, or -1 if no match.
int _applyAlternateSubst(ByteData view, int subtableOffset, int glyphId) {
  if (subtableOffset + 6 > view.lengthInBytes) return -1;
  final format = view.getUint16(subtableOffset, Endian.big);
  if (format != 1) return -1;

  final coverageOffset = view.getUint16(subtableOffset + 2, Endian.big);
  final covIdx = _coverageLookup(view, subtableOffset, coverageOffset, glyphId);
  if (covIdx < 0) return -1;

  final alternateSetCount = view.getUint16(subtableOffset + 4, Endian.big);
  if (covIdx >= alternateSetCount) return -1;

  final alternateSetOffset = subtableOffset +
      view.getUint16(subtableOffset + 6 + covIdx * 2, Endian.big);
  if (alternateSetOffset + 2 > view.lengthInBytes) return -1;

  final glyphCount = view.getUint16(alternateSetOffset, Endian.big);
  if (glyphCount == 0) return -1;
  if (alternateSetOffset + 2 + 2 > view.lengthInBytes) return -1;

  // Pick the first alternate automatically in this bootstrap
  return view.getUint16(alternateSetOffset + 2, Endian.big);
}

// ---------------------------------------------------------------------------
// ClassDef table parser (for GPOS Format 2)
// ---------------------------------------------------------------------------

/// Looks up the class of [glyphId] in a ClassDef table at [absOffset].
/// Returns the class value (0 if not found or not covered).
int _classDefLookup(ByteData view, int absOffset, int glyphId) {
  if (absOffset + 4 > view.lengthInBytes) return 0;
  final format = view.getUint16(absOffset, Endian.big);

  if (format == 1) {
    // Format 1: first glyph + array of class values
    if (absOffset + 6 > view.lengthInBytes) return 0;
    final firstGlyph = view.getUint16(absOffset + 2, Endian.big);
    final count = view.getUint16(absOffset + 4, Endian.big);
    final index = glyphId - firstGlyph;
    if (index < 0 || index >= count) return 0;
    if (absOffset + 6 + (index + 1) * 2 > view.lengthInBytes) return 0;
    return view.getUint16(absOffset + 6 + index * 2, Endian.big);
  } else if (format == 2) {
    // Format 2: array of ranges (binary search)
    if (absOffset + 4 > view.lengthInBytes) return 0;
    final count = view.getUint16(absOffset + 2, Endian.big);
    if (absOffset + 4 + count * 6 > view.lengthInBytes) return 0;

    int lo = 0, hi = count - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >>> 1;
      final rangeOff = absOffset + 4 + mid * 6;
      final first = view.getUint16(rangeOff, Endian.big);
      final last = view.getUint16(rangeOff + 2, Endian.big);
      if (glyphId < first) {
        hi = mid - 1;
      } else if (glyphId > last) {
        lo = mid + 1;
      } else {
        return view.getUint16(rangeOff + 4, Endian.big);
      }
    }
    return 0;
  }
  return 0;
}

// ---------------------------------------------------------------------------
// GPOS Lookup Type 2: Pair Adjustment (formats 1 + 2)
// ---------------------------------------------------------------------------

/// Result of a pair adjustment: x/y placement and advance adjustments.
class GPosAdjustment {
  final int xPlacement1;
  final int yPlacement1;
  final int xAdvance1;
  final int yAdvance1;
  final int xPlacement2;
  final int yPlacement2;
  final int xAdvance2;
  final int yAdvance2;

  const GPosAdjustment({
    this.xPlacement1 = 0,
    this.yPlacement1 = 0,
    this.xAdvance1 = 0,
    this.yAdvance1 = 0,
    this.xPlacement2 = 0,
    this.yPlacement2 = 0,
    this.xAdvance2 = 0,
    this.yAdvance2 = 0,
  });
}

/// Reads value record fields from [offset] given [valueFormat].
/// Returns (xPlacement, yPlacement, xAdvance, yAdvance).
(int, int, int, int) _readValueRecord(
    ByteData view, int offset, int valueFormat) {
  int p = offset;
  int xPlace = 0, yPlace = 0, xAdv = 0, yAdv = 0;

  if (valueFormat & 0x01 != 0) {
    xPlace = view.getInt16(p, Endian.big);
    p += 2;
  }
  if (valueFormat & 0x02 != 0) {
    yPlace = view.getInt16(p, Endian.big);
    p += 2;
  }
  if (valueFormat & 0x04 != 0) {
    xAdv = view.getInt16(p, Endian.big);
    p += 2;
  }
  if (valueFormat & 0x08 != 0) {
    yAdv = view.getInt16(p, Endian.big);
    p += 2;
  }
  // Skip device table offsets (0x10..0x80)
  return (xPlace, yPlace, xAdv, yAdv);
}

// ---------------------------------------------------------------------------
// GPOS Lookup Type 1: Single Adjustment
// ---------------------------------------------------------------------------

/// Applies GPOS SingleAdjustment at [subtableOffset] to [glyphId].
/// Returns adjustment or null if no match.
GPosAdjustment? _applySingleAdjustment(
  ByteData view,
  int subtableOffset,
  int glyphId,
) {
  if (subtableOffset + 6 > view.lengthInBytes) return null;
  final format = view.getUint16(subtableOffset, Endian.big);
  final coverageOffset = view.getUint16(subtableOffset + 2, Endian.big);
  final valueFormat = view.getUint16(subtableOffset + 4, Endian.big);

  final covIdx = _coverageLookup(view, subtableOffset, coverageOffset, glyphId);
  if (covIdx < 0) return null;

  final vrSize = _valueRecordSize(valueFormat);

  if (format == 1) {
    if (subtableOffset + 6 + vrSize > view.lengthInBytes) return null;
    final (xp, yp, xa, ya) =
        _readValueRecord(view, subtableOffset + 6, valueFormat);
    return GPosAdjustment(
        xPlacement1: xp, yPlacement1: yp, xAdvance1: xa, yAdvance1: ya);
  } else if (format == 2) {
    final valueCount = view.getUint16(subtableOffset + 6, Endian.big);
    if (covIdx >= valueCount) return null;
    final recOff = subtableOffset + 8 + covIdx * vrSize;
    if (recOff + vrSize > view.lengthInBytes) return null;
    final (xp, yp, xa, ya) = _readValueRecord(view, recOff, valueFormat);
    return GPosAdjustment(
        xPlacement1: xp, yPlacement1: yp, xAdvance1: xa, yAdvance1: ya);
  }

  return null;
}

/// Applies GPOS PairAdjustment (Format 1 or 2) at [subtableOffset].
/// Returns adjustment or null if no match.
GPosAdjustment? _applyPairAdjustment(
  ByteData view,
  int subtableOffset,
  int glyphId1,
  int glyphId2,
) {
  if (subtableOffset + 10 > view.lengthInBytes) return null;
  final format = view.getUint16(subtableOffset, Endian.big);
  final coverageOffset = view.getUint16(subtableOffset + 2, Endian.big);
  final valueFormat1 = view.getUint16(subtableOffset + 4, Endian.big);
  final valueFormat2 = view.getUint16(subtableOffset + 6, Endian.big);

  final covIdx =
      _coverageLookup(view, subtableOffset, coverageOffset, glyphId1);
  if (covIdx < 0) return null;

  final vr1Size = _valueRecordSize(valueFormat1);
  final vr2Size = _valueRecordSize(valueFormat2);

  if (format == 1) {
    // Format 1: list of PairSets
    final pairSetCount = view.getUint16(subtableOffset + 8, Endian.big);
    if (covIdx >= pairSetCount) return null;

    final pairSetOff = subtableOffset +
        view.getUint16(subtableOffset + 10 + covIdx * 2, Endian.big);
    if (pairSetOff + 2 > view.lengthInBytes) return null;

    final pairCount = view.getUint16(pairSetOff, Endian.big);
    final pairRecSize = 2 + vr1Size + vr2Size;

    for (int pi = 0; pi < pairCount; pi++) {
      final recOff = pairSetOff + 2 + pi * pairRecSize;
      if (recOff + 2 > view.lengthInBytes) break;
      final secondGlyph = view.getUint16(recOff, Endian.big);
      if (secondGlyph == glyphId2) {
        final (xp1, yp1, xa1, ya1) =
            _readValueRecord(view, recOff + 2, valueFormat1);
        final (xp2, yp2, xa2, ya2) =
            _readValueRecord(view, recOff + 2 + vr1Size, valueFormat2);
        return GPosAdjustment(
          xPlacement1: xp1,
          yPlacement1: yp1,
          xAdvance1: xa1,
          yAdvance1: ya1,
          xPlacement2: xp2,
          yPlacement2: yp2,
          xAdvance2: xa2,
          yAdvance2: ya2,
        );
      }
      if (secondGlyph > glyphId2) break; // sorted
    }
  } else if (format == 2) {
    // Format 2: ClassDef-based pair adjustment
    if (subtableOffset + 16 > view.lengthInBytes) return null;

    final classDef1Off =
        subtableOffset + view.getUint16(subtableOffset + 8, Endian.big);
    final classDef2Off =
        subtableOffset + view.getUint16(subtableOffset + 10, Endian.big);
    final class1Count = view.getUint16(subtableOffset + 12, Endian.big);
    final class2Count = view.getUint16(subtableOffset + 14, Endian.big);

    final class1 = _classDefLookup(view, classDef1Off, glyphId1);
    final class2 = _classDefLookup(view, classDef2Off, glyphId2);

    if (class1 >= class1Count || class2 >= class2Count) return null;

    // Each class record = vr1Size + vr2Size bytes
    // Records laid out as: class_records[class1 * class2Count + class2]
    final classRecSize = vr1Size + vr2Size;
    final recIndex = class1 * class2Count + class2;
    final recOff = subtableOffset + 16 + recIndex * classRecSize;

    if (recOff + classRecSize > view.lengthInBytes) return null;

    final (xp1, yp1, xa1, ya1) = _readValueRecord(view, recOff, valueFormat1);
    final (xp2, yp2, xa2, ya2) =
        _readValueRecord(view, recOff + vr1Size, valueFormat2);

    // Skip zero adjustments
    if (xa1 == 0 &&
        xa2 == 0 &&
        xp1 == 0 &&
        xp2 == 0 &&
        ya1 == 0 &&
        ya2 == 0 &&
        yp1 == 0 &&
        yp2 == 0) {
      return null;
    }

    return GPosAdjustment(
      xPlacement1: xp1,
      yPlacement1: yp1,
      xAdvance1: xa1,
      yAdvance1: ya1,
      xPlacement2: xp2,
      yPlacement2: yp2,
      xAdvance2: xa2,
      yAdvance2: ya2,
    );
  }
  return null;
}

// ---------------------------------------------------------------------------
// High-level GSUB/GPOS table parser
// ---------------------------------------------------------------------------

/// Parsed GSUB or GPOS lookup entry.
class _LookupEntry {
  final int lookupType;
  final int lookupFlags;
  final List<int> subtableOffsets;

  const _LookupEntry(this.lookupType, this.lookupFlags, this.subtableOffsets);
}

/// Parses the lookup list from a GSUB or GPOS table.
///
/// [isGsub] decide qual tipo significa "Extension": 7 no GSUB, 9 no GPOS. A
/// distinção importa porque GPOS 7 é posicionamento contextual, e tratá-lo
/// como extensão leria o corpo da subtabela como um cabeçalho de extensão.
List<_LookupEntry> _parseLookupList(
  ByteData view,
  int tableOffset, {
  required bool isGsub,
}) {
  if (tableOffset + 10 > view.lengthInBytes) return const [];

  final lookupListOffset =
      tableOffset + view.getUint16(tableOffset + 8, Endian.big);
  if (lookupListOffset + 2 > view.lengthInBytes) return const [];

  final lookupCount = view.getUint16(lookupListOffset, Endian.big);
  final result = <_LookupEntry>[];

  for (int i = 0; i < lookupCount; i++) {
    if (lookupListOffset + 2 + (i + 1) * 2 > view.lengthInBytes) break;
    final lookupOff = lookupListOffset +
        view.getUint16(lookupListOffset + 2 + i * 2, Endian.big);
    if (lookupOff + 6 > view.lengthInBytes) continue;

    final lookupType = view.getUint16(lookupOff, Endian.big);
    final lookupFlags = view.getUint16(lookupOff + 2, Endian.big);
    final subtableCount = view.getUint16(lookupOff + 4, Endian.big);
    final subtables = <int>[];

    // Uma Extension lookup não tem lógica própria: ela só embrulha subtabelas
    // que moram longe demais para caber num offset de 16 bits. O tipo REAL
    // está no cabeçalho da extensão, e é ele que a aplicação tem que ver —
    // antes o offset era resolvido mas o tipo continuava 7/9, e aí nenhum
    // ramo do switch casava: uma fonte que usasse Extension (qualquer fonte
    // grande o bastante, o que inclui as CJK e boa parte das profissionais)
    // não aplicava substituição nem posicionamento nenhum.
    final int extensionType = isGsub ? 7 : 9;
    int effectiveType = lookupType;

    for (int s = 0; s < subtableCount; s++) {
      if (lookupOff + 6 + (s + 1) * 2 > view.lengthInBytes) break;
      final stOff =
          lookupOff + view.getUint16(lookupOff + 6 + s * 2, Endian.big);

      if (lookupType == extensionType && stOff + 8 <= view.lengthInBytes) {
        final extFormat = view.getUint16(stOff, Endian.big);
        if (extFormat == 1) {
          // A especificação exige que todas as subtabelas de uma mesma
          // Extension lookup embrulhem o mesmo tipo.
          effectiveType = view.getUint16(stOff + 2, Endian.big);
          subtables.add(stOff + view.getUint32(stOff + 4, Endian.big));
          continue;
        }
      }

      subtables.add(stOff);
    }

    result.add(_LookupEntry(effectiveType, lookupFlags, subtables));
  }

  return result;
}

/// Parses the feature list and collects lookup indices for requested features.
List<int> _collectFeatureLookups(
  ByteData view,
  int tableOffset,
  Set<String> requestedFeatures,
) {
  if (tableOffset + 10 > view.lengthInBytes) return const [];

  final featureListOffset =
      tableOffset + view.getUint16(tableOffset + 6, Endian.big);
  if (featureListOffset + 2 > view.lengthInBytes) return const [];

  final featureCount = view.getUint16(featureListOffset, Endian.big);
  final lookupIndices = <int>[];

  for (int i = 0; i < featureCount; i++) {
    final recOff = featureListOffset + 2 + i * 6;
    if (recOff + 6 > view.lengthInBytes) break;

    // Read feature tag as 4 ASCII chars
    final tag = String.fromCharCodes([
      view.getUint8(recOff),
      view.getUint8(recOff + 1),
      view.getUint8(recOff + 2),
      view.getUint8(recOff + 3),
    ]);

    if (!requestedFeatures.contains(tag)) continue;

    final featOff = featureListOffset + view.getUint16(recOff + 4, Endian.big);
    if (featOff + 4 > view.lengthInBytes) continue;

    // Skip featureParamsOffset (2 bytes)
    final lookupCount = view.getUint16(featOff + 2, Endian.big);
    for (int li = 0; li < lookupCount; li++) {
      if (featOff + 4 + (li + 1) * 2 > view.lengthInBytes) break;
      lookupIndices.add(view.getUint16(featOff + 4 + li * 2, Endian.big));
    }
  }

  return lookupIndices;
}

// ---------------------------------------------------------------------------
// Public API: BLLayoutEngine
// ---------------------------------------------------------------------------

/// OpenType layout engine for GSUB and GPOS processing.
///
/// Parses GSUB/GPOS tables from font data and applies feature-based
/// substitutions and positioning to glyph runs.
class BLLayoutEngine {
  final ByteData _view;
  final int _gsubOffset;
  final int _gsubLength;
  final int _gposOffset;
  final int _gposLength;

  late final List<_LookupEntry> _gsubLookups;
  late final List<_LookupEntry> _gposLookups;

  BLLayoutEngine(
    this._view, {
    required int gsubOffset,
    required int gsubLength,
    required int gposOffset,
    required int gposLength,
  })  : _gsubOffset = gsubOffset,
        _gsubLength = gsubLength,
        _gposOffset = gposOffset,
        _gposLength = gposLength {
    _gsubLookups = _gsubLength > 0
        ? _parseLookupList(_view, _gsubOffset, isGsub: true)
        : const [];
    _gposLookups = _gposLength > 0
        ? _parseLookupList(_view, _gposOffset, isGsub: false)
        : const [];
  }

  /// Whether GSUB data is available.
  bool get hasGSUB => _gsubLength > 0;

  /// Whether GPOS data is available.
  bool get hasGPOS => _gposLength > 0;

  /// Number of parsed GSUB lookups.
  int get gsubLookupCount => _gsubLookups.length;

  /// Number of parsed GPOS lookups.
  int get gposLookupCount => _gposLookups.length;

  // =========================================================================
  // GSUB: Apply features to glyph IDs
  // =========================================================================

  /// Applies GSUB features to [glyphIds] in-place (may change length for
  /// ligatures). Returns the new glyph list.
  ///
  /// [features] is a set of 4-char feature tags (e.g. `{'liga', 'clig'}`).
  List<int> applyGSUB(List<int> glyphIds, {Set<String>? features}) {
    if (_gsubLength == 0 || _gsubLookups.isEmpty) return glyphIds;

    final requestedFeatures = features ?? const {'liga', 'clig', 'rlig'};
    final lookupIndices =
        _collectFeatureLookups(_view, _gsubOffset, requestedFeatures);

    var result = List<int>.from(glyphIds);

    for (final li in lookupIndices) {
      if (li >= _gsubLookups.length) continue;
      final lookup = _gsubLookups[li];

      // `lookupType` já vem resolvido: uma Extension lookup foi trocada pelo
      // tipo que ela embrulha ao parsear a lista.
      for (final stOff in lookup.subtableOffsets) {
        switch (lookup.lookupType) {
          case 1: // SingleSubst
            for (int i = 0; i < result.length; i++) {
              final newGlyph = _applySingleSubst(_view, stOff, result[i]);
              if (newGlyph >= 0) result[i] = newGlyph;
            }
            break;

          case 2: // MultipleSubst
            int i = 0;
            while (i < result.length) {
              final replacements = _applyMultipleSubst(_view, stOff, result[i]);
              if (replacements != null && replacements.isNotEmpty) {
                result.replaceRange(i, i + 1, replacements);
                i += replacements.length;
              } else {
                i++;
              }
            }
            break;

          case 3: // AlternateSubst
            for (int i = 0; i < result.length; i++) {
              final newGlyph = _applyAlternateSubst(_view, stOff, result[i]);
              if (newGlyph >= 0) result[i] = newGlyph;
            }
            break;

          case 4: // LigatureSubst
            int i = 0;
            while (i < result.length) {
              final lig = _applyLigatureSubst(_view, stOff, result, i);
              if (lig != null) {
                result[i] = lig.ligatureGlyph;
                result.removeRange(i + 1, i + lig.componentCount);
                // Don't advance i; try again from same position
              } else {
                i++;
              }
            }
            break;

          default:
            // Other types not yet implemented in this bootstrap
            break;
        }
      }
    }

    return result;
  }

  // =========================================================================
  // GPOS: Apply pair positioning
  // =========================================================================

  /// Applies GPOS pair positioning to compute x-advance adjustments.
  /// Returns a list of x-advance adjustments (same length as [glyphIds]).
  ///
  /// Atalho para quem só quer o avanço; [applyGPOSAdjustments] devolve também
  /// o deslocamento do desenho do glifo.
  List<int> applyGPOS(List<int> glyphIds, {Set<String>? features}) {
    return [
      for (final a in applyGPOSAdjustments(glyphIds, features: features))
        a.xAdvance
    ];
  }

  /// Aplica GPOS e devolve o ajuste completo de cada glifo, em unidades de
  /// fonte.
  ///
  /// O avanço move o cursor; o *placement* move só o desenho daquele glifo,
  /// sem mexer no cursor. Os dois já eram lidos das subtabelas, mas o
  /// placement era descartado — o que apaga acentos deslocados e qualquer
  /// ajuste vertical que a fonte peça.
  List<BLGlyphAdjustment> applyGPOSAdjustments(
    List<int> glyphIds, {
    Set<String>? features,
  }) {
    final adjustments = List<BLGlyphAdjustment>.filled(
        glyphIds.length, const BLGlyphAdjustment());
    if (_gposLength == 0 || _gposLookups.isEmpty) return adjustments;

    final requestedFeatures = features ?? const {'kern'};
    final lookupIndices =
        _collectFeatureLookups(_view, _gposOffset, requestedFeatures);

    for (final li in lookupIndices) {
      if (li >= _gposLookups.length) continue;
      final lookup = _gposLookups[li];

      if (lookup.lookupType != 1 && lookup.lookupType != 2) continue;

      for (final stOff in lookup.subtableOffsets) {
        if (lookup.lookupType == 1) {
          // SingleAdjustment
          for (int i = 0; i < glyphIds.length; i++) {
            final adj = _applySingleAdjustment(_view, stOff, glyphIds[i]);
            if (adj != null) {
              adjustments[i] = adjustments[i].plus(
                xPlacement: adj.xPlacement1,
                yPlacement: adj.yPlacement1,
                xAdvance: adj.xAdvance1,
                yAdvance: adj.yAdvance1,
              );
            }
          }
        } else if (lookup.lookupType == 2) {
          // PairAdjustment
          for (int i = 0; i < glyphIds.length - 1; i++) {
            final adj = _applyPairAdjustment(
                _view, stOff, glyphIds[i], glyphIds[i + 1]);
            if (adj != null) {
              adjustments[i] = adjustments[i].plus(
                xPlacement: adj.xPlacement1,
                yPlacement: adj.yPlacement1,
                xAdvance: adj.xAdvance1,
                yAdvance: adj.yAdvance1,
              );
              adjustments[i + 1] = adjustments[i + 1].plus(
                xPlacement: adj.xPlacement2,
                yPlacement: adj.yPlacement2,
                xAdvance: adj.xAdvance2,
                yAdvance: adj.yAdvance2,
              );
            }
          }
        }
      }
    }

    return adjustments;
  }
}

/// Ajuste de posicionamento aplicado a um glifo, em unidades de fonte.
///
/// `xAdvance`/`yAdvance` movem o cursor para o próximo glifo;
/// `xPlacement`/`yPlacement` movem o desenho deste glifo sem mexer no cursor —
/// é assim que a fonte encaixa um acento sobre a letra certa.
class BLGlyphAdjustment {
  final int xPlacement;
  final int yPlacement;
  final int xAdvance;
  final int yAdvance;

  const BLGlyphAdjustment({
    this.xPlacement = 0,
    this.yPlacement = 0,
    this.xAdvance = 0,
    this.yAdvance = 0,
  });

  /// True quando não há nada a aplicar.
  bool get isZero =>
      xPlacement == 0 && yPlacement == 0 && xAdvance == 0 && yAdvance == 0;

  /// Soma outro ajuste a este. Lookups distintos acumulam.
  BLGlyphAdjustment plus({
    int xPlacement = 0,
    int yPlacement = 0,
    int xAdvance = 0,
    int yAdvance = 0,
  }) =>
      BLGlyphAdjustment(
        xPlacement: this.xPlacement + xPlacement,
        yPlacement: this.yPlacement + yPlacement,
        xAdvance: this.xAdvance + xAdvance,
        yAdvance: this.yAdvance + yAdvance,
      );

  @override
  String toString() => 'BLGlyphAdjustment(placement: (\$xPlacement, '
      '\$yPlacement), advance: (\$xAdvance, \$yAdvance))';
}
