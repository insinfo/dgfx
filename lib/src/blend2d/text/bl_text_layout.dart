import 'bl_font.dart';
import 'bl_glyph_run.dart';
import 'bl_bidi.dart';
import 'bl_opentype_layout.dart';

/// Layout de texto avançado com suporte a shaping (GSUB/GPOS), Bidi (LTR/RTL),
/// e quebras de linha multi-line (`\n`).
class BLTextLayout {
  const BLTextLayout();

  /// Executa shaping e posicionamento com suporte a Bidirecionalidade
  /// (script árabe/hebraico em blocos isolados) e multi-line (`\n`).
  BLGlyphRun shapeText(
    String text,
    BLFont font, {
    double x = 0.0,
    double y = 0.0,
    Set<String>? gsubFeatures,
    Set<String>? gposFeatures,
  }) {
    if (text.isEmpty) return const BLGlyphRun(<BLGlyphPlacement>[]);

    final lines = text.split('\n');
    final allGlyphs = <BLGlyphPlacement>[];
    final face = font.face;

    final scale = font.size / (face.unitsPerEm > 0 ? face.unitsPerEm : 1000);
    final lineHeight = (face.ascender - face.descender) * scale;

    double penY = y;

    for (final line in lines) {
      if (line.isEmpty) {
        penY += lineHeight;
        continue;
      }

      // 1. Extrair direção básica (Fase 9 Bidi)
      final bidiRuns = BLBidiAnalyzer.analyze(line);
      double penX = x;

      for (final run in bidiRuns) {
        final part = line.substring(run.start, run.end);
        final runes = part.runes.toList(growable: false);

        // Cmap mapping
        var glyphIds = <int>[for (final cp in runes) face.mapCodePoint(cp)];

        final engine = face.layoutEngine;
        if (engine != null && engine.hasGSUB) {
          glyphIds = engine.applyGSUB(glyphIds, features: gsubFeatures);
        }

        List<BLGlyphAdjustment>? gposAdj;
        if (engine != null && engine.hasGPOS) {
          gposAdj = engine.applyGPOSAdjustments(
            glyphIds,
            features: gposFeatures,
          );
        }

        // Calcula a largura total do run primeiro (crucial para RTL)
        final advances = List<double>.filled(glyphIds.length, 0.0);
        double runWidth = 0.0;

        for (int i = 0; i < glyphIds.length; i++) {
          final gid = glyphIds[i];
          if (gposAdj == null && i > 0) {
            runWidth += font.kerning(glyphIds[i - 1], gid);
          }
          final adv = font.glyphAdvance(gid);
          double effAdv = adv;
          if (gposAdj != null && i < gposAdj.length) {
            effAdv += font.scaleValue(gposAdj[i].xAdvance);
          }
          advances[i] = effAdv;
          runWidth += effAdv;
        }

        // O placement move só o desenho do glifo, não o cursor: é o que
        // encaixa um acento sobre a letra. O outline sai do `glyf` sem
        // inversão de eixo, então y positivo é para cima nos dois.
        final offX = List<double>.filled(glyphIds.length, 0.0);
        final offY = List<double>.filled(glyphIds.length, 0.0);
        if (gposAdj != null) {
          for (int i = 0; i < glyphIds.length && i < gposAdj.length; i++) {
            final a = gposAdj[i];
            if (a.isZero) continue;
            offX[i] = font.scaleValue(a.xPlacement);
            offY[i] = font.scaleValue(a.yPlacement);
          }
        }

        // Posiciona os glifos (Lógica Base LTR vs RTL)
        if (run.direction == BLTextDirection.ltr) {
          for (int i = 0; i < glyphIds.length; i++) {
            final gid = glyphIds[i];
            allGlyphs.add(BLGlyphPlacement(
              glyphId: gid,
              x: penX + offX[i],
              y: penY + offY[i],
              advanceX: advances[i],
            ));
            penX += advances[i];
          }
        } else {
          // RTL: Posiciona de trás pra frente visualmente,
          // mas preenchemos da direita para a esquerda.
          double rtlX = penX + runWidth;
          for (int i = 0; i < glyphIds.length; i++) {
            final gid = glyphIds[i];
            rtlX -= advances[i]; // Move para a esquerda
            allGlyphs.add(BLGlyphPlacement(
              glyphId: gid,
              x: rtlX + offX[i],
              y: penY + offY[i],
              advanceX: advances[i],
            ));
          }
          penX += runWidth; // O pen lógico continua fluindo pra direita
        }
      }
      penY += lineHeight;
    }

    return BLGlyphRun(allGlyphs);
  }

  /// Alias de transição para compatibilidade da API (usará shapeText).
  BLGlyphRun shapeSimple(
    String text,
    BLFont font, {
    double x = 0.0,
    double y = 0.0,
    Set<String>? gsubFeatures,
    Set<String>? gposFeatures,
  }) {
    return shapeText(text, font,
        x: x, y: y, gsubFeatures: gsubFeatures, gposFeatures: gposFeatures);
  }

  /// Measures text dimensions including exact bounding box extraction.
  ///
  /// Multi-line aware. Returns bounding box metrics encapsulating all lines.
  BLTextMetrics measureText(
    String text,
    BLFont font, {
    Set<String>? gsubFeatures,
    Set<String>? gposFeatures,
  }) {
    if (text.isEmpty) return const BLTextMetrics(0, 0, 0, 0, 0);

    final run = shapeText(text, font,
        gsubFeatures: gsubFeatures, gposFeatures: gposFeatures);
    if (run.glyphs.isEmpty) return const BLTextMetrics(0, 0, 0, 0, 0);

    final face = font.face;
    final scale = font.size / (face.unitsPerEm > 0 ? face.unitsPerEm : 1000);

    double minX = double.infinity;
    double minY = double.infinity;
    double maxX = double.negativeInfinity;
    double maxY = double.negativeInfinity;

    for (final placement in run.glyphs) {
      if (placement.x < minX) minX = placement.x;
      // Para advance, o maxX precisa conter placement + advanceX
      if (placement.x + placement.advanceX > maxX) {
        maxX = placement.x + placement.advanceX;
      }

      // O Y do placement é o baseline.
      // bounding box engloba [baseline - ascender, baseline + descender (abs)]
      final asc = face.ascender * scale;
      final desc = face.descender * scale;

      final topY = placement.y - asc;
      final bottomY =
          placement.y + desc.abs(); // descender costuma ser negativo

      if (topY < minY) minY = topY;
      if (bottomY > maxY) maxY = bottomY;
    }

    final totalWidth = maxX > minX ? maxX - minX : 0.0;
    final totalHeight = maxY > minY ? maxY - minY : 0.0;

    return BLTextMetrics(
      totalWidth,
      totalHeight,
      run.glyphs.length,
      minX,
      minY,
    );
  }
}

/// Result of a multi-line or exact-bound text measurement.
class BLTextMetrics {
  /// Total precise advance width encompassing all lines.
  final double width;

  /// Total precise height encompassing all lines + ascenders/descenders.
  final double height;

  /// Min X of the bounding box (tight logical).
  final double boundingBoxX;

  /// Min Y of the bounding box (tight logical).
  final double boundingBoxY;

  /// Number of glyphs after shaping.
  final int glyphCount;

  const BLTextMetrics(
    this.width,
    this.height,
    this.glyphCount, [
    this.boundingBoxX = 0,
    this.boundingBoxY = 0,
  ]);

  @override
  String toString() =>
      'BLTextMetrics(w=$width, h=$height, glyphs=$glyphCount, bbox=[$boundingBoxX, $boundingBoxY])';
}
