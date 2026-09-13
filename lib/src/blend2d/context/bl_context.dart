import 'dart:math' as math;
import 'dart:typed_data';

import '../core/bl_image.dart';
import '../core/bl_types.dart';
import '../pipeline/bl_fetch_linear_gradient.dart';
import '../pipeline/bl_fetch_pattern.dart';
import '../pipeline/bl_fetch_radial_gradient.dart';
import '../pipeline/bl_fetch_conic_gradient.dart';
import '../geometry/bl_dasher.dart';
import '../geometry/bl_path.dart';
import '../geometry/bl_stroker.dart';
import '../pipeline/bl_compop_kernel.dart';
import '../pipeline/bl_fetch_gouraud.dart';
import '../pipeline/bl_fetch_solid.dart';
import '../raster/bl_analytic_rasterizer.dart';
import '../text/bl_font.dart';
import '../text/bl_glyph_run.dart';
import '../text/bl_text_layout.dart';

enum _BLFillStyleType {
  solid,
  linearGradient,
  radialGradient,
  conicGradient,
  pattern,
}

/// Snapshot of context state for save/restore.
///
/// Port of BLContextCore saved state concept from C++ Blend2D.
class _BLContextState {
  final BLCompOp compOp;
  final BLFillRule fillRule;
  final BLSolidFetcher solidFetcher;
  final BLLinearGradientFetcher? linearGradientFetcher;
  final BLRadialGradientFetcher? radialGradientFetcher;
  final BLConicGradientFetcher? conicGradientFetcher;
  final BLPatternFetcher? patternFetcher;
  final _BLFillStyleType fillStyleType;
  final BLStrokeOptions strokeOptions;
  final double globalAlpha;
  final BLRectI? clipRect;

  /// Máscara de clip vigente no momento do save.
  ///
  /// Guardada por referência, sem cópia: [BLContext.clipToPath] nunca escreve
  /// numa máscara existente, sempre publica uma nova, então o snapshot não
  /// pode ser corrompido pelo estado que veio depois.
  final Uint8List? clipMask;
  final Uint8List? opacityMask;
  final BLMatrix2D transform;

  _BLContextState({
    required this.compOp,
    required this.fillRule,
    required this.solidFetcher,
    required this.linearGradientFetcher,
    required this.radialGradientFetcher,
    required this.conicGradientFetcher,
    required this.patternFetcher,
    required this.fillStyleType,
    required this.strokeOptions,
    required this.globalAlpha,
    required this.clipRect,
    required this.clipMask,
    required this.opacityMask,
    required this.transform,
  });
}

/// Contexto de desenho do port Blend2D em Dart.
///
/// Expansão da API de contexto com:
/// - save()/restore() para empilhar/desempilhar estado
/// - clipRect para recorte retangular
/// - globalAlpha para transparência global
/// - transform (BLMatrix2D) para transformações afins
/// - Todos os 28 comp-ops do Blend2D C++
///
/// Inspirado em: `blend2d/core/context.h`, `blend2d/core/context.cpp`
class BLContext {
  final BLImage image;
  final BLAnalyticRasterizer _rasterizer;

  BLCompOp compOp = BLCompOp.srcOver;
  BLFillRule fillRule = BLFillRule.nonZero;
  BLSolidFetcher _solidFetcher = BLSolidFetcher(0xFF000000);
  BLLinearGradientFetcher? _linearGradientFetcher;
  BLRadialGradientFetcher? _radialGradientFetcher;
  BLConicGradientFetcher? _conicGradientFetcher;
  BLPatternFetcher? _patternFetcher;
  _BLFillStyleType _fillStyleType = _BLFillStyleType.solid;

  /// Opções de stroke (largura, caps, joins) para [strokePath].
  BLStrokeOptions strokeOptions = const BLStrokeOptions();

  /// Transparência global `0.0..1.0`. Applied on top of fill/stroke alpha.
  double globalAlpha = 1.0;

  /// Clip retangular (null = sem clip, usa imagem inteira).
  BLRectI? _clipRect;

  /// Retorna o clip rect corrente (null = sem clip).
  BLRectI? get clipRect => _clipRect;

  /// Máscara de clip de 8 bits, um byte por pixel (255 = totalmente visível,
  /// 0 = totalmente recortado). `null` = sem máscara.
  ///
  /// O clip do PDF (`W n`) é uma interseção acumulativa de caminhos
  /// arbitrários, o que um retângulo não representa; por isso a máscara é
  /// multiplicativa. Só é alocada quando [clipToPath] é usado — desenho sem
  /// clip de caminho continua no caminho rápido sem custo por pixel.
  Uint8List? _clipMask;

  /// Máscara de clip corrente (null = sem clip de caminho).
  Uint8List? get clipMask => _clipMask;

  /// Independent per-pixel opacity mask. Unlike the geometric clip, this can
  /// be replaced or removed without losing the current clipping path.
  Uint8List? _opacityMask;
  Uint8List? _combinedMask;

  Uint8List? get opacityMask => _opacityMask;

  /// Transformação afim corrente (identity por padrão).
  BLMatrix2D _transform = BLMatrix2D.identity;

  /// Pilha de estados salvos via [save()].
  final List<_BLContextState> _stateStack = [];

  /// Cria um contexto que desenha sobre [image].
  ///
  /// Os parâmetros [useSimd], [useIsolates], [tileHeight],
  /// [minParallelDirtyHeight] e [aaSubsampleY] estão depreciados e **não
  /// fazem nada** — nunca fizeram. Não há caminho SIMD, não há paralelismo
  /// por isolates (Dart não compartilha memória entre isolates sem
  /// `dart:ffi`, que este pacote não usa) e o rasterizador é analítico, isto
  /// é, calcula a área exata coberta por pixel, de modo que não existe
  /// supersampling a configurar. Passá-los não altera nem um pixel nem um
  /// microssegundo; serão removidos numa versão futura.
  BLContext(
    this.image, {
    @Deprecated('No-op: não existe caminho SIMD. Será removido.')
    bool useSimd = false,
    @Deprecated('No-op: não existe paralelismo por isolates. Será removido.')
    bool useIsolates = false,
    @Deprecated('No-op: não existe resolve paralelo por faixas. Será removido.')
    int tileHeight = 64,
    @Deprecated('No-op: não existe resolve paralelo. Será removido.')
    int minParallelDirtyHeight = 256,
    @Deprecated(
      'No-op: o rasterizador é analítico (área exata), não amostra. '
      'Será removido.',
    )
    int aaSubsampleY = 2,
  }) : _rasterizer = BLAnalyticRasterizer(
          image.width,
          image.height,
          // O rasterizador compoe direto no buffer da imagem. Antes cada draw
          // terminava com uma copia da superficie inteira; numa pagina PDF com
          // milhares de operadores isso dominava o tempo de render.
          target: image.pixels,
        );

  // =========================================================================
  // Clear
  // =========================================================================

  void clear([BLColor argb = 0xFFFFFFFF]) {
    // image.pixels e o proprio buffer do rasterizador, um fill basta.
    _rasterizer.clear(argb);
  }

  // =========================================================================
  // State save/restore (inspired by BLContextCore saved state)
  // =========================================================================

  /// Salva o estado atual do contexto na pilha.
  /// Retorna a profundidade da pilha após o save.
  int save() {
    _stateStack.add(_BLContextState(
      compOp: compOp,
      fillRule: fillRule,
      solidFetcher: _solidFetcher,
      linearGradientFetcher: _linearGradientFetcher,
      radialGradientFetcher: _radialGradientFetcher,
      conicGradientFetcher: _conicGradientFetcher,
      patternFetcher: _patternFetcher,
      fillStyleType: _fillStyleType,
      strokeOptions: strokeOptions,
      globalAlpha: globalAlpha,
      clipRect: _clipRect,
      clipMask: _clipMask,
      opacityMask: _opacityMask,
      transform: _transform,
    ));
    return _stateStack.length;
  }

  /// Restaura o último estado salvo da pilha.
  /// Retorna true se o restore foi bem sucedido (pilha não vazia).
  bool restore() {
    if (_stateStack.isEmpty) return false;
    final state = _stateStack.removeLast();
    compOp = state.compOp;
    fillRule = state.fillRule;
    _solidFetcher = state.solidFetcher;
    _linearGradientFetcher = state.linearGradientFetcher;
    _radialGradientFetcher = state.radialGradientFetcher;
    _conicGradientFetcher = state.conicGradientFetcher;
    _patternFetcher = state.patternFetcher;
    _fillStyleType = state.fillStyleType;
    strokeOptions = state.strokeOptions;
    globalAlpha = state.globalAlpha;
    _clipRect = state.clipRect;
    _clipMask = state.clipMask;
    _opacityMask = state.opacityMask;
    _combinedMask = null;
    _transform = state.transform;
    return true;
  }

  /// Profundidade atual da pilha de save/restore.
  int get savedCount => _stateStack.length;

  // =========================================================================
  // Fill style
  // =========================================================================

  void setFillStyle(BLColor argb) {
    _solidFetcher = BLSolidFetcher(argb);
    _fillStyleType = _BLFillStyleType.solid;
    _linearGradientFetcher = null;
    _radialGradientFetcher = null;
    _conicGradientFetcher = null;
    _patternFetcher = null;
  }

  void setLinearGradient(BLLinearGradient gradient) {
    _linearGradientFetcher = BLLinearGradientFetcher(gradient);
    _radialGradientFetcher = null;
    _conicGradientFetcher = null;
    _patternFetcher = null;
    _fillStyleType = _BLFillStyleType.linearGradient;
  }

  void setRadialGradient(BLRadialGradient gradient) {
    _radialGradientFetcher = BLRadialGradientFetcher(gradient);
    _linearGradientFetcher = null;
    _conicGradientFetcher = null;
    _patternFetcher = null;
    _fillStyleType = _BLFillStyleType.radialGradient;
  }

  void setConicGradient(BLConicGradient gradient) {
    _conicGradientFetcher = BLConicGradientFetcher(gradient);
    _linearGradientFetcher = null;
    _radialGradientFetcher = null;
    _patternFetcher = null;
    _fillStyleType = _BLFillStyleType.conicGradient;
  }

  void setPattern(BLPattern pattern) {
    _patternFetcher = BLPatternFetcher(pattern);
    _linearGradientFetcher = null;
    _radialGradientFetcher = null;
    _conicGradientFetcher = null;
    _fillStyleType = _BLFillStyleType.pattern;
  }

  void setFillRule(BLFillRule rule) {
    fillRule = rule;
  }

  void setCompOp(BLCompOp op) {
    compOp = op;
  }

  // =========================================================================
  // Global alpha
  // =========================================================================

  /// Define a transparência global `0.0..1.0`.
  void setGlobalAlpha(double alpha) {
    globalAlpha = alpha.clamp(0.0, 1.0);
  }

  // =========================================================================
  // Clip rect
  // =========================================================================

  /// Define um clip retangular. Todos os draws são limitados a esta região.
  /// Passa `null` para remover o clip.
  void setClipRect(BLRectI? rect) {
    _clipRect = rect;
  }

  /// Intersecta o clip atual com o retângulo dado.
  void clipToRect(BLRectI rect) {
    if (_clipRect == null) {
      _clipRect = rect;
    } else {
      final c = _clipRect!;
      final x0 = math.max(c.x, rect.x);
      final y0 = math.max(c.y, rect.y);
      final x1 = math.min(c.x + c.width, rect.x + rect.width);
      final y1 = math.min(c.y + c.height, rect.y + rect.height);
      if (x1 <= x0 || y1 <= y0) {
        _clipRect = const BLRectI(0, 0, 0, 0); // degenerate clip
      } else {
        _clipRect = BLRectI(x0, y0, x1 - x0, y1 - y0);
      }
    }
  }

  /// Remove o clip (desenhos usam a imagem inteira).
  void resetClip() {
    _clipRect = null;
    _clipMask = null;
    _combinedMask = null;
  }

  /// Replaces the current opacity mask, or removes it when [coverage] is null.
  /// The geometric clip remains untouched. Input samples are copied so saved
  /// states and caller-owned buffers cannot be mutated accidentally.
  void setOpacityMask(Uint8List? coverage) {
    final expected = image.width * image.height;
    if (coverage != null && coverage.length != expected) {
      throw ArgumentError.value(
          coverage.length, 'coverage', 'Expected $expected mask samples.');
    }
    _opacityMask = coverage == null ? null : Uint8List.fromList(coverage);
    _combinedMask = null;
  }

  Uint8List? _effectiveMask() {
    final clip = _clipMask;
    final opacity = _opacityMask;
    if (clip == null) return opacity;
    if (opacity == null) return clip;
    final cached = _combinedMask;
    if (cached != null) return cached;
    final combined = Uint8List(clip.length);
    for (var i = 0; i < combined.length; i++) {
      final a = clip[i], b = opacity[i];
      combined[i] = a == 255 ? b : (b == 255 ? a : (a * b + 127) ~/ 255);
    }
    return _combinedMask = combined;
  }

  /// Intersecta o clip corrente com [path] (regra [rule]).
  ///
  /// É o `W n` / `W* n` do PDF: o novo clip é a interseção do caminho com o
  /// que já estava vigente, nunca uma substituição. A interseção é feita
  /// multiplicando as coberturas de 8 bits, o que preserva o antialiasing das
  /// bordas em vez de decidir por dentro/fora por pixel.
  ///
  /// O caminho é transformado pela matriz corrente antes de ser rasterizado,
  /// igual a [fillPath].
  void clipToPath(BLPath path, {BLFillRule rule = BLFillRule.nonZero}) {
    final data = path.toPathData();
    if (data.vertices.length < 6) {
      // Caminho degenerado não delimita área nenhuma: clip vazio.
      _clipMask = Uint8List(image.width * image.height);
      _combinedMask = null;
      return;
    }

    final verts =
        isTransformIdentity ? data.vertices : _transformVertices(data.vertices);

    final coverage = Uint8List(image.width * image.height);
    _rasterizer.rasterizeCoverage(
      verts,
      coverage,
      fillRule: rule,
      contourVertexCounts: data.contourVertexCounts,
    );

    final previous = _clipMask;
    if (previous != null) {
      for (int i = 0; i < coverage.length; i++) {
        final a = previous[i];
        final b = coverage[i];
        // Interseção = produto normalizado das coberturas.
        coverage[i] = a == 255 ? b : (b == 255 ? a : (a * b + 127) ~/ 255);
      }
    }
    // Publica uma máscara nova em vez de escrever na antiga: os snapshots em
    // _stateStack guardam a referência anterior e precisam continuar válidos.
    _clipMask = coverage;
    _combinedMask = null;
  }

  /// Intersecta o clip vigente com uma cobertura externa em espaço de device.
  ///
  /// Cada byte corresponde a um pixel da imagem (`0` invisível, `255`
  /// totalmente visível). A entrada é copiada para preservar os snapshots de
  /// [save]/[restore] e pode ser reutilizada ou alterada pelo chamador.
  void intersectClipMask(Uint8List coverage) {
    final expected = image.width * image.height;
    if (coverage.length != expected) {
      throw ArgumentError.value(
          coverage.length, 'coverage', 'Expected $expected mask samples.');
    }
    final combined = Uint8List.fromList(coverage);
    final previous = _clipMask;
    if (previous != null) {
      for (var i = 0; i < combined.length; i++) {
        final a = previous[i];
        final b = combined[i];
        combined[i] = a == 255 ? b : (b == 255 ? a : (a * b + 127) ~/ 255);
      }
    }
    _clipMask = combined;
    _combinedMask = null;
  }

  /// Intersecta o clip corrente com um retângulo, materializado na máscara.
  ///
  /// Diferente de [clipToRect], que mantém o retângulo como caixa inteira
  /// (caminho rápido), esta versão é útil quando o retângulo já está em espaço
  /// do usuário e precisa passar pela transformação corrente.
  void clipToRectPath(double x, double y, double w, double h) {
    final path = BLPath();
    path.moveTo(x, y);
    path.lineTo(x + w, y);
    path.lineTo(x + w, y + h);
    path.lineTo(x, y + h);
    path.close();
    clipToPath(path);
  }

  // =========================================================================
  // Transform (affine matrix)
  // =========================================================================

  /// Define a transformação afim corrente.
  void setTransform(BLMatrix2D m) {
    _transform = m;
  }

  /// Retorna a transformação afim corrente.
  BLMatrix2D getTransform() => _transform;

  /// Reseta a transformação para identity.
  void resetTransform() {
    _transform = BLMatrix2D.identity;
  }

  /// Pré-concatena [m] à transformação corrente, como o operador `cm` do PDF.
  ///
  /// `CTM' = m × CTM`: [m] passa a agir sobre as coordenadas do usuário
  /// ANTES da transformação que já estava vigente, então chamadas sucessivas
  /// se acumulam do espaço mais interno para o mais externo.
  ///
  /// É o oposto de [translate] / [scale] / [rotate], que pós-concatenam (agem
  /// no espaço do device, depois da transformação corrente).
  void transform(BLMatrix2D m) {
    _transform = m.multiply(_transform);
  }

  /// Aplica translação à transformação corrente.
  ///
  /// PÓS-concatena: o deslocamento é aplicado em espaço de device, depois da
  /// transformação corrente (`CTM' = CTM × T`). Para a semântica do `cm` do
  /// PDF use [transform] com [BLMatrix2D.translation].
  void translate(double tx, double ty) {
    // T * M = [1 0; 0 1; tx ty] * M
    _transform = BLMatrix2D(
      _transform.m00,
      _transform.m01,
      _transform.m10,
      _transform.m11,
      _transform.m20 + tx,
      _transform.m21 + ty,
    );
  }

  /// Aplica escala à transformação corrente.
  ///
  /// PÓS-concatena: escala o resultado em espaço de device
  /// (`CTM' = CTM × S`). Para a semântica do `cm` do PDF use [transform] com
  /// [BLMatrix2D.scaling].
  void scale(double sx, double sy) {
    _transform = BLMatrix2D(
      _transform.m00 * sx,
      _transform.m01 * sy,
      _transform.m10 * sx,
      _transform.m11 * sy,
      _transform.m20 * sx,
      _transform.m21 * sy,
    );
  }

  /// Aplica rotação (em radianos) à transformação corrente.
  ///
  /// PÓS-concatena em espaço de device (`CTM' = CTM × R`). Atenção ao sinal:
  /// a matriz pós-concatenada aqui é `BLMatrix2D.rotation(-angle)`, ou seja o
  /// sentido é o inverso de [BLMatrix2D.rotation] (que segue o Blend2D C++ e o
  /// `cm` do PDF). O comportamento é o histórico deste port e foi preservado;
  /// para a convenção do PDF use `transform(BLMatrix2D.rotation(angle))`.
  void rotate(double angle) {
    final c = math.cos(angle);
    final s = math.sin(angle);
    final m = _transform;
    _transform = BLMatrix2D(
      m.m00 * c + m.m01 * s,
      m.m01 * c - m.m00 * s,
      m.m10 * c + m.m11 * s,
      m.m11 * c - m.m10 * s,
      m.m20 * c + m.m21 * s,
      m.m21 * c - m.m20 * s,
    );
  }

  /// Transforma um ponto (x, y) pela transformação corrente.
  /// Retorna (x', y') = (m00*x + m10*y + m20, m01*x + m11*y + m21).
  (double, double) transformPoint(double x, double y) {
    final m = _transform;
    return (
      m.m00 * x + m.m10 * y + m.m20,
      m.m01 * x + m.m11 * y + m.m21,
    );
  }

  /// Verifica se a transformação corrente é identity (sem transformação).
  bool get isTransformIdentity => _transform.isIdentity;

  // =========================================================================
  // Fill polygon
  // =========================================================================

  Future<void> fillPolygon(
    List<double> vertices, {
    List<int>? contourVertexCounts,
    BLColor? color,
    BLFillRule? rule,
  }) async {
    final bool useExplicitColor = color != null;
    final drawRule = rule ?? fillRule;
    final gradientFetcher = _linearGradientFetcher;
    final radialFetcher = _radialGradientFetcher;
    final patternFetcher = _patternFetcher;

    // Apply transform to vertices if not identity
    List<double> drawVerts =
        isTransformIdentity ? vertices : _transformVertices(vertices);

    // Clip retangular: além do reject por bounding box (barato quando a
    // geometria está toda fora), a caixa vai para o rasterizador, que recorta
    // pixel a pixel. Antes o clip era SÓ o reject por bbox e qualquer forma
    // que cruzasse a borda saía desenhada inteira.
    final BLRectI? clipBox = _clipRect;
    if (clipBox != null) {
      if (clipBox.width <= 0 || clipBox.height <= 0) return;
      double minX = double.infinity, maxX = double.negativeInfinity;
      double minY = double.infinity, maxY = double.negativeInfinity;
      for (int i = 0; i < drawVerts.length; i += 2) {
        final vx = drawVerts[i], vy = drawVerts[i + 1];
        if (vx < minX) minX = vx;
        if (vx > maxX) maxX = vx;
        if (vy < minY) minY = vy;
        if (vy > maxY) maxY = vy;
      }
      if (maxX < clipBox.x ||
          minX > clipBox.x + clipBox.width ||
          maxY < clipBox.y ||
          minY > clipBox.y + clipBox.height) {
        return; // completely outside clip
      }
    }

    final mask = _effectiveMask();

    if (!useExplicitColor &&
        _fillStyleType == _BLFillStyleType.linearGradient &&
        gradientFetcher != null) {
      await _rasterizer.drawPolygonFetched(
        drawVerts,
        _withGlobalAlpha(gradientFetcher.fetch),
        fillRule: drawRule,
        compOp: compOp,
        contourVertexCounts: contourVertexCounts,
        clipMask: mask,
        clipBox: clipBox,
      );
      return;
    }

    if (!useExplicitColor &&
        _fillStyleType == _BLFillStyleType.radialGradient &&
        radialFetcher != null) {
      await _rasterizer.drawPolygonFetched(
        drawVerts,
        _withGlobalAlpha(radialFetcher.fetch),
        fillRule: drawRule,
        compOp: compOp,
        contourVertexCounts: contourVertexCounts,
        clipMask: mask,
        clipBox: clipBox,
      );
      return;
    }

    final conicFetcher = _conicGradientFetcher;
    if (!useExplicitColor &&
        _fillStyleType == _BLFillStyleType.conicGradient &&
        conicFetcher != null) {
      await _rasterizer.drawPolygonFetched(
        drawVerts,
        _withGlobalAlpha(conicFetcher.fetch),
        fillRule: drawRule,
        compOp: compOp,
        contourVertexCounts: contourVertexCounts,
        clipMask: mask,
        clipBox: clipBox,
      );
      return;
    }

    if (!useExplicitColor &&
        _fillStyleType == _BLFillStyleType.pattern &&
        patternFetcher != null) {
      await _rasterizer.drawPolygonFetched(
        drawVerts,
        _withGlobalAlpha(patternFetcher.fetch),
        fillRule: drawRule,
        compOp: compOp,
        contourVertexCounts: contourVertexCounts,
        clipMask: mask,
        clipBox: clipBox,
      );
      return;
    }

    int drawColor = color ?? _solidFetcher.fetch();

    // Apply globalAlpha to the color's alpha channel
    if (globalAlpha < 1.0) {
      final srcA = (drawColor >>> 24) & 0xFF;
      final effA = (srcA * globalAlpha + 0.5).toInt().clamp(0, 255);
      drawColor = (effA << 24) | (drawColor & 0x00FFFFFF);
    }

    await _rasterizer.drawPolygon(
      drawVerts,
      drawColor,
      fillRule: drawRule,
      compOp: compOp,
      contourVertexCounts: contourVertexCounts,
      clipMask: mask,
      clipBox: clipBox,
    );
  }

  // =========================================================================
  // Gouraud — interpolação de cor por vértice
  // =========================================================================

  /// Preenche um triângulo com a cor interpolada linearmente entre os três
  /// vértices (sombreamento de Gouraud).
  ///
  /// As coordenadas passam pela transformação corrente; as cores são ARGB32.
  /// O estilo de fill do contexto é ignorado — a cor vem dos vértices —, mas
  /// [compOp], [globalAlpha], o clip retangular e a máscara de clip valem
  /// normalmente.
  ///
  /// Este é o caminho de um triângulo só, com antisserrilhamento nas três
  /// arestas. Para uma malha de triângulos adjacentes use
  /// [fillTriangleMesh]: desenhar triângulo a triângulo e compor com
  /// `srcOver` deixa uma costura clara em cada aresta compartilhada, porque
  /// meia cobertura de cada lado não soma cobertura cheia.
  Future<void> fillTriangleGouraud(
    double x0,
    double y0,
    BLColor c0,
    double x1,
    double y1,
    BLColor c1,
    double x2,
    double y2,
    BLColor c2,
  ) async {
    final verts = <double>[x0, y0, x1, y1, x2, y2];
    final drawVerts = isTransformIdentity ? verts : _transformVertices(verts);

    final BLRectI? clipBox = _clipRect;
    if (clipBox != null &&
        (clipBox.width <= 0 ||
            clipBox.height <= 0 ||
            _outsideClipBox(drawVerts, clipBox))) {
      return;
    }

    final fetcher = BLGouraudFetcher(
      drawVerts[0], drawVerts[1], c0, //
      drawVerts[2], drawVerts[3], c1, //
      drawVerts[4], drawVerts[5], c2,
    );

    await _rasterizer.drawPolygonFetched(
      drawVerts,
      _withGlobalAlpha(fetcher.fetch),
      fillRule: BLFillRule.nonZero,
      compOp: compOp,
      clipMask: _effectiveMask(),
      clipBox: clipBox,
    );
  }

  /// Preenche uma malha de triângulos com sombreamento de Gouraud **numa
  /// única passada do rasterizador**.
  ///
  /// [xy] são coordenadas intercaladas `x, y` (um par por vértice), [colors]
  /// traz uma cor ARGB32 por vértice e [indices] três índices por triângulo.
  /// Omitir [indices] faz [xy] ser lido como uma sequência direta de
  /// triângulos.
  ///
  /// A passada única é o ponto: cada triângulo entra como um contorno da mesma
  /// geometria, com regra `nonZero`. O rasterizador analítico acumula área com
  /// sinal, então uma aresta interna percorrida em sentidos opostos pelos dois
  /// triângulos vizinhos se cancela exatamente — as arestas internas saem
  /// **sem antisserrilhamento e sem costura**, e o antisserrilhamento fica só
  /// na silhueta externa da malha, que é onde ele deve estar. A orientação dos
  /// triângulos é normalizada internamente, então a malha pode vir com
  /// orientação mista.
  ///
  /// É o caminho para os sombreamentos PDF de tipo 4 (free-form Gouraud), 5
  /// (lattice-form Gouraud), 6 (Coons patch) e 7 (tensor patch), em que a
  /// alternativa — um fill por triângulo, com a média das três cores — custa
  /// até mais de mil chamadas por patch e ainda deixa uma grade visível.
  Future<void> fillTriangleMesh(
    Float64List xy,
    Uint32List colors, [
    Int32List? indices,
  ]) async {
    if (xy.length < 6) return;

    Float64List deviceXy;
    if (isTransformIdentity) {
      deviceXy = xy;
    } else {
      final m = _transform;
      deviceXy = Float64List(xy.length);
      for (int i = 0; i < xy.length; i += 2) {
        final x = xy[i], y = xy[i + 1];
        deviceXy[i] = m.m00 * x + m.m10 * y + m.m20;
        deviceXy[i + 1] = m.m01 * x + m.m11 * y + m.m21;
      }
    }

    final mesh = BLGouraudMeshFetcher(deviceXy, colors, indices);
    if (mesh.triangleCount == 0) return;

    final BLRectI? clipBox = _clipRect;
    if (clipBox != null &&
        (clipBox.width <= 0 ||
            clipBox.height <= 0 ||
            _outsideClipBox(mesh.orientedVertices, clipBox))) {
      return;
    }

    await _rasterizer.drawPolygonFetched(
      mesh.orientedVertices,
      _withGlobalAlpha(mesh.fetch),
      fillRule: BLFillRule.nonZero,
      compOp: compOp,
      contourVertexCounts: mesh.contourVertexCounts,
      clipMask: _effectiveMask(),
      clipBox: clipBox,
    );
  }

  /// True quando a caixa de [verts] não toca [clipBox] — reject barato antes
  /// de acumular aresta nenhuma.
  static bool _outsideClipBox(List<double> verts, BLRectI clipBox) {
    double minX = double.infinity, maxX = double.negativeInfinity;
    double minY = double.infinity, maxY = double.negativeInfinity;
    for (int i = 0; i < verts.length; i += 2) {
      final vx = verts[i], vy = verts[i + 1];
      if (vx < minX) minX = vx;
      if (vx > maxX) maxX = vx;
      if (vy < minY) minY = vy;
      if (vy > maxY) maxY = vy;
    }
    return maxX < clipBox.x ||
        minX > clipBox.x + clipBox.width ||
        maxY < clipBox.y ||
        minY > clipBox.y + clipBox.height;
  }

  /// Envolve [fetcher] aplicando [globalAlpha] ao alpha da fonte.
  ///
  /// `ca` / `CA` do PDF valem para todo tipo de fill; gradientes e padrões
  /// passavam direto pelo bloco de globalAlpha do caminho sólido e saíam
  /// sempre opacos.
  BLPixelFetcher _withGlobalAlpha(BLPixelFetcher fetcher) {
    final alpha = globalAlpha;
    if (alpha >= 1.0) return fetcher;
    return (int x, int y) {
      final px = fetcher(x, y);
      final srcA = (px >>> 24) & 0xFF;
      final effA = (srcA * alpha + 0.5).toInt().clamp(0, 255);
      return (effA << 24) | (px & 0x00FFFFFF);
    };
  }

  Future<void> fillPath(
    BLPath path, {
    BLColor? color,
    BLFillRule? rule,
  }) async {
    final data = path.toPathData();
    if (data.vertices.length < 6) return;
    await fillPolygon(
      data.vertices,
      contourVertexCounts: data.contourVertexCounts,
      color: color,
      rule: rule,
    );
  }

  // =========================================================================
  // Fill rect (convenience)
  // =========================================================================

  /// Preenche um retângulo com a cor / estilo atual.
  Future<void> fillRect(double x, double y, double w, double h,
      {BLColor? color}) async {
    final path = BLPath();
    path.moveTo(x, y);
    path.lineTo(x + w, y);
    path.lineTo(x + w, y + h);
    path.lineTo(x, y + h);
    path.close();
    await fillPath(path, color: color);
  }

  // =========================================================================
  // Geometry convenience APIs
  // =========================================================================

  /// Preenche um círculo centrado em (cx, cy) com raio r.
  Future<void> fillCircle(double cx, double cy, double r,
      {BLColor? color}) async {
    final path = _buildCirclePath(cx, cy, r);
    await fillPath(path, color: color);
  }

  /// Renderiza o stroke de um círculo.
  Future<void> strokeCircle(double cx, double cy, double r,
      {BLColor? color, BLStrokeOptions? options}) async {
    final path = _buildCirclePath(cx, cy, r);
    await strokePath(path, color: color, options: options);
  }

  /// Preenche uma elipse centrada em (cx, cy) com raios rx, ry.
  Future<void> fillEllipse(double cx, double cy, double rx, double ry,
      {BLColor? color}) async {
    final path = _buildEllipsePath(cx, cy, rx, ry);
    await fillPath(path, color: color);
  }

  /// Renderiza o stroke de uma elipse.
  Future<void> strokeEllipse(double cx, double cy, double rx, double ry,
      {BLColor? color, BLStrokeOptions? options}) async {
    final path = _buildEllipsePath(cx, cy, rx, ry);
    await strokePath(path, color: color, options: options);
  }

  /// Builds a circle path using 8-segment cubic approximation.
  static BLPath _buildCirclePath(double cx, double cy, double r) {
    return _buildEllipsePath(cx, cy, r, r);
  }

  /// Builds an ellipse path using 4-quadrant cubic Bézier approximation.
  /// Uses the standard k ≈ 0.5522847498 control-point factor.
  static BLPath _buildEllipsePath(double cx, double cy, double rx, double ry) {
    const double k = 0.5522847498;
    final kx = rx * k, ky = ry * k;
    final path = BLPath();
    // Start at right
    path.moveTo(cx + rx, cy);
    // Top-right quadrant
    path.cubicTo(cx + rx, cy - ky, cx + kx, cy - ry, cx, cy - ry);
    // Top-left quadrant
    path.cubicTo(cx - kx, cy - ry, cx - rx, cy - ky, cx - rx, cy);
    // Bottom-left quadrant
    path.cubicTo(cx - rx, cy + ky, cx - kx, cy + ry, cx, cy + ry);
    // Bottom-right quadrant
    path.cubicTo(cx + kx, cy + ry, cx + rx, cy + ky, cx + rx, cy);
    path.close();
    return path;
  }

  /// Preenche um retângulo arredondado.
  Future<void> fillRoundRect(
    double x,
    double y,
    double w,
    double h,
    double r, {
    BLColor? color,
  }) async {
    final path = BLPath()..addRoundRect(x, y, w, h, r);
    await fillPath(path, color: color);
  }

  /// Strokes um retângulo arredondado.
  Future<void> strokeRoundRect(
    double x,
    double y,
    double w,
    double h,
    double r, {
    BLColor? color,
  }) async {
    final path = BLPath()..addRoundRect(x, y, w, h, r);
    await strokePath(path, color: color);
  }

  // =========================================================================
  // Stroke API (Fase 5)
  // =========================================================================

  /// Configura as opções de stroke (largura, caps, joins, miter limit).
  void setStrokeOptions(BLStrokeOptions options) {
    strokeOptions = options;
  }

  /// Configura apenas a largura do stroke.
  void setStrokeWidth(double width) {
    strokeOptions = strokeOptions.copyWith(width: width);
  }

  /// Renderiza o stroke de [path] usando [strokeOptions] atuais.
  ///
  /// O stroke é convertido em um outline preenchido com [BLFillRule.nonZero].
  /// A cor / estilo de fill atuais são usados (ou [color] se fornecido).
  ///
  /// Com `width == 0` (o `0 w` do PDF) o traço vira uma hairline de um pixel
  /// de device: o contexto sobrescreve [BLStrokeOptions.minimumWidth] com
  /// `1 / escalaDoDevice` derivado da transformação corrente. Sob transformação
  /// identidade isso coincide com o default de `minimumWidth`.
  Future<void> strokePath(
    BLPath path, {
    BLColor? color,
    BLStrokeOptions? options,
  }) async {
    final opts = _resolveStrokeOptions(options ?? strokeOptions);
    if (opts.effectiveWidth <= 0) return;

    final outline = BLStroker.strokePath(path, opts);
    await fillPath(
      outline,
      color: color,
      rule: BLFillRule.nonZero,
    );
  }

  /// Renderiza o stroke de um polígono (lista de vértices).
  Future<void> strokePolygon(
    List<double> vertices, {
    List<int>? contourVertexCounts,
    bool closedContours = true,
    BLColor? color,
    BLStrokeOptions? options,
  }) async {
    final opts = options ?? strokeOptions;
    if (opts.effectiveWidth <= 0) return;

    // Montar BLPath a partir dos vértices
    final path = BLPath();
    final counts = contourVertexCounts ?? [vertices.length ~/ 2];
    int offset = 0;
    for (final cnt in counts) {
      if (cnt < 2) {
        offset += cnt;
        continue;
      }
      path.moveTo(vertices[offset * 2], vertices[offset * 2 + 1]);
      for (int i = 1; i < cnt; i++) {
        path.lineTo(vertices[(offset + i) * 2], vertices[(offset + i) * 2 + 1]);
      }
      if (closedContours) path.close();
      offset += cnt;
    }

    await strokePath(path, color: color, options: opts);
  }

  // =========================================================================
  // Stroke rect (convenience)
  // =========================================================================

  /// Stroked rectangle.
  Future<void> strokeRect(
    double x,
    double y,
    double w,
    double h, {
    BLColor? color,
    BLStrokeOptions? options,
  }) async {
    final path = BLPath();
    path.moveTo(x, y);
    path.lineTo(x + w, y);
    path.lineTo(x + w, y + h);
    path.lineTo(x, y + h);
    path.close();
    await strokePath(path, color: color, options: options);
  }

  // =========================================================================
  // Dashed stroke (Fase 5+)
  // =========================================================================

  /// Stroke com dash pattern.
  ///
  /// [dashArray] define o padrão alternado dash/gap (ex: `[10, 5]`).
  /// [dashOffset] desloca o início do padrão.
  Future<void> strokeDashedPath(
    BLPath path, {
    required List<double> dashArray,
    double dashOffset = 0.0,
    BLColor? color,
    BLStrokeOptions? options,
  }) async {
    final dashed = BLDasher.dashPath(path, dashArray, dashOffset: dashOffset);
    await strokePath(dashed, color: color, options: options);
  }

  // =========================================================================
  // Image blitting (drawImage)
  // =========================================================================

  /// Compõe [src] sobre o contexto na posição (dx, dy).
  ///
  /// Itera pixel a pixel e aplica o comp-op corrente.
  /// Respeita globalAlpha e clipRect.
  void drawImage(BLImage src, {int dx = 0, int dy = 0}) {
    final dstBuf = _rasterizer.buffer;
    final srcPx = src.pixels;
    final dstW = image.width, dstH = image.height;
    final srcW = src.width, srcH = src.height;

    // Determine visible region
    int x0 = dx, y0 = dy;
    int x1 = dx + srcW, y1 = dy + srcH;
    if (_clipRect != null) {
      final cr = _clipRect!;
      x0 = math.max(x0, cr.x);
      y0 = math.max(y0, cr.y);
      x1 = math.min(x1, cr.x + cr.width);
      y1 = math.min(y1, cr.y + cr.height);
    }
    x0 = math.max(0, x0);
    y0 = math.max(0, y0);
    x1 = math.min(dstW, x1);
    y1 = math.min(dstH, y1);

    if (x0 >= x1 || y0 >= y1) return;

    final alphaScale = globalAlpha < 1.0;
    final mask = _effectiveMask();

    for (int py = y0; py < y1; py++) {
      final srcRow = (py - dy) * srcW;
      final dstRow = py * dstW;
      for (int px = x0; px < x1; px++) {
        int sp = srcPx[srcRow + (px - dx)];
        int a = (sp >>> 24) & 0xFF;
        if (alphaScale) {
          a = (a * globalAlpha + 0.5).toInt().clamp(0, 255);
        }
        if (mask != null) {
          final m = mask[dstRow + px];
          if (m == 0) continue;
          if (m != 255) a = (a * m + 127) ~/ 255;
        }
        sp = (a << 24) | (sp & 0x00FFFFFF);
        dstBuf[dstRow + px] =
            BLCompOpKernel.compose(compOp, dstBuf[dstRow + px], sp);
      }
    }
  }

  // =========================================================================
  // Text API (Fase 11 — port de fillText/strokeText/drawGlyphRun)
  // =========================================================================

  /// Renderiza [text] preenchido na posição (x, y) usando [font].
  ///
  /// Usa [BLTextLayout.shapeSimple] para mapear codepoints → glyph IDs e
  /// posicionar os glifos com advance/kerning.
  /// Cada glifo é renderizado como path via [fillPath].
  Future<void> fillText(
    String text,
    BLFont font, {
    double x = 0.0,
    double y = 0.0,
    BLColor? color,
  }) async {
    if (text.isEmpty) return;
    const layout = BLTextLayout();
    final run = layout.shapeSimple(text, font, x: x, y: y);
    await fillGlyphRun(run, font, color: color);
  }

  /// Renderiza [text] com stroke na posição (x, y) usando [font].
  Future<void> strokeText(
    String text,
    BLFont font, {
    double x = 0.0,
    double y = 0.0,
    BLColor? color,
    BLStrokeOptions? options,
  }) async {
    if (text.isEmpty) return;
    const layout = BLTextLayout();
    final run = layout.shapeSimple(text, font, x: x, y: y);
    await strokeGlyphRun(run, font, color: color, options: options);
  }

  /// Renderiza um [BLGlyphRun] preenchido.
  ///
  /// Para cada glifo no run, obtém o outline escalado e o preenche na
  /// posição (placement.x, placement.y).
  Future<void> fillGlyphRun(
    BLGlyphRun run,
    BLFont font, {
    BLColor? color,
  }) async {
    for (final glyph in run.glyphs) {
      final outline = font.glyphOutline(glyph.glyphId);
      if (outline == null || outline.vertices.length < 6) continue;

      // Translate vertices to glyph position
      final verts = outline.vertices;
      final translated = List<double>.filled(verts.length, 0.0);
      for (int i = 0; i < verts.length; i += 2) {
        translated[i] = verts[i] + glyph.x;
        translated[i + 1] = verts[i + 1] + glyph.y;
      }

      await fillPolygon(
        translated,
        contourVertexCounts: outline.contourVertexCounts,
        color: color,
        rule: BLFillRule.nonZero,
      );
    }
  }

  /// Renderiza um [BLGlyphRun] com stroke.
  Future<void> strokeGlyphRun(
    BLGlyphRun run,
    BLFont font, {
    BLColor? color,
    BLStrokeOptions? options,
  }) async {
    for (final glyph in run.glyphs) {
      final outline = font.glyphOutline(glyph.glyphId);
      if (outline == null || outline.vertices.length < 6) continue;

      // build a BLPath translated to glyph position
      final path = BLPath();
      final verts = outline.vertices;
      final counts = outline.contourVertexCounts ?? [verts.length ~/ 2];
      int offset = 0;
      for (final cnt in counts) {
        if (cnt < 2) {
          offset += cnt;
          continue;
        }
        path.moveTo(
            verts[offset * 2] + glyph.x, verts[offset * 2 + 1] + glyph.y);
        for (int i = 1; i < cnt; i++) {
          path.lineTo(
            verts[(offset + i) * 2] + glyph.x,
            verts[(offset + i) * 2 + 1] + glyph.y,
          );
        }
        path.close();
        offset += cnt;
      }

      await strokePath(path, color: color, options: options);
    }
  }

  // =========================================================================
  // Flush / dispose
  // =========================================================================

  int _surfaceCopies = 0;

  /// Quantas cópias de superfície inteira este contexto já fez.
  ///
  /// Diagnóstico: com o rasterizador compondo direto em `image.pixels` o
  /// número é O(1) (zero) para qualquer quantidade de draws, e não O(N) como
  /// quando cada draw terminava com uma cópia.
  int get surfaceCopyCount => _surfaceCopies;

  /// Garante que [image] reflete tudo o que foi desenhado.
  ///
  /// Chame antes de ler `image.pixels` (encode PNG, comparação de pixels).
  /// No caminho normal o rasterizador já compõe no buffer da imagem e isto é
  /// um no-op; a cópia só acontece se o backend estiver com buffer próprio.
  void flush() {
    if (identical(_rasterizer.buffer, image.pixels)) return;
    image.copyFrom(_rasterizer.buffer);
    _surfaceCopies++;
  }

  Future<void> dispose() => _rasterizer.dispose();

  // =========================================================================
  // Internal
  // =========================================================================

  /// Escala linear média do device implícita na transformação corrente.
  ///
  /// `sqrt(|det|)` é a média geométrica dos fatores de escala dos dois eixos;
  /// para transformações anisotrópicas é uma aproximação, mas é o que uma
  /// linha de largura única pode representar.
  double get _deviceScale {
    final det = _transform.determinant.abs();
    if (det <= 0.0 || !det.isFinite) return 1.0;
    return math.sqrt(det);
  }

  /// Preenche [BLStrokeOptions.minimumWidth] com o equivalente a um pixel de
  /// device em espaço do usuário.
  ///
  /// O stroker trabalha em espaço do usuário e não conhece a CTM; só o
  /// contexto sabe converter "um pixel" para as unidades em que o caminho
  /// está. É o que faz `0 w` do PDF render uma hairline de um pixel qualquer
  /// que seja a escala corrente.
  BLStrokeOptions _resolveStrokeOptions(BLStrokeOptions opts) {
    if (opts.width > 0.0) return opts;
    final scale = _deviceScale;
    if (scale <= 0.0) return opts;
    return opts.copyWith(minimumWidth: 1.0 / scale);
  }

  /// Aplica a transformação corrente a todos os vértices.
  List<double> _transformVertices(List<double> verts) {
    final m = _transform;
    final result = List<double>.filled(verts.length, 0.0);
    for (int i = 0; i < verts.length; i += 2) {
      final x = verts[i], y = verts[i + 1];
      result[i] = m.m00 * x + m.m10 * y + m.m20;
      result[i + 1] = m.m01 * x + m.m11 * y + m.m21;
    }
    return result;
  }
}
