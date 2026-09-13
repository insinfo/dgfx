import '../core/bl_types.dart';
import 'dart:typed_data';

class BLPatternFetcher {
  static const int _fpShift = 8;
  static const int _fpOne = 1 << _fpShift;
  static const int _fpMask = _fpOne - 1;

  final BLPattern pattern;
  final int _w;
  final int _h;
  final Uint32List _pixels;
  final double _offsetX;
  final double _offsetY;
  final double _m00;
  final double _m01;
  final double _m10;
  final double _m11;
  final double _m20;
  final double _m21;
  final BLPatternFilter _filter;
  final bool _isIdentity;
  final bool _useFastNearestInt;
  final int _offsetXi;
  final int _offsetYi;

  // Per-pixel step in fixed-point 24.8
  final int _dxFxFp;
  final int _dxFyFp;

  // --- Filtro de redução (box) ---
  //
  // A matriz do padrão leva o pixel de DEVICE de volta à origem, então o
  // quadrado [x, x+1) x [y, y+1) do device vira um paralelogramo de lados
  // (m00, m10) e (m01, m11) no espaço da imagem. Guardamos a LARGURA da caixa
  // envolvente desse paralelogramo em cada eixo. Quando ela passa de um texel
  // há redução, e amostrar um ponto (ou quatro) descarta a maior parte da
  // origem — é daí que vem o moiré de uma digitalização encolhida. Nesse caso
  // integramos a área coberta.
  //
  // A janela é ancorada PARA FRENTE a partir do ponto amostrado, `[f, f+span)`,
  // e não no sentido em que a matriz anda. É a mesma convenção do caminho
  // nearest, que pega `floor(f)`: com span 1 os dois coincidem exatamente,
  // inclusive quando o eixo está invertido (m11 < 0, o caso de todo ladrilho
  // de PDF). Ancorar no sentido da matriz deslocava um texel nesse caso.
  final double _boxSpanX;
  final double _boxSpanY;

  /// True quando a matriz reduz em algum eixo, e portanto o filtro de caixa
  /// vale mais que o filtro escolhido.
  final bool _useBox;

  /// Teto de amostras por eixo. Acima disso o laço anda de [stepX] em
  /// [stepX] texels, cada amostra valendo pelo grupo que representa: numa
  /// redução extrema 64 amostras por eixo já não deixam moiré nenhum, e o
  /// custo por pixel fica limitado.
  static const int _maxBoxSamples = 64;

  // --- C++ affine context parameters (ox/oy/rx/ry/corx/cory port) ---
  final BLGradientExtendMode _extX;
  final BLGradientExtendMode _extY;

  /// Tile period X in fp: 0 for pad, w*fpOne for repeat, 2*w*fpOne for reflect.
  final int _periodXFp;

  /// Tile period Y in fp.
  final int _periodYFp;

  /// True when |dxFxFp| < periodXFp (branchless single-subtraction per pixel).
  final bool _canFastAdvX;

  /// True when |dxFyFp| < periodYFp.
  final bool _canFastAdvY;

  // Sequential tracking state
  int _seqY = 0;
  int _seqNextX = 0;
  int _seqFxFp = 0;
  int _seqFyFp = 0;
  bool _seqFpValid = false;

  BLPatternFetcher(this.pattern)
      : _w = pattern.image.width,
        _h = pattern.image.height,
        _pixels = pattern.image.pixels,
        _offsetX = pattern.offset.x,
        _offsetY = pattern.offset.y,
        _m00 = pattern.transform.m00,
        _m01 = pattern.transform.m01,
        _m10 = pattern.transform.m10,
        _m11 = pattern.transform.m11,
        _m20 = pattern.transform.m20,
        _m21 = pattern.transform.m21,
        _filter = pattern.filter,
        _extX = pattern.extendModeX,
        _extY = pattern.extendModeY,
        _isIdentity = pattern.transform.m00 == 1.0 &&
            pattern.transform.m01 == 0.0 &&
            pattern.transform.m10 == 0.0 &&
            pattern.transform.m11 == 1.0 &&
            pattern.transform.m20 == 0.0 &&
            pattern.transform.m21 == 0.0,
        _useFastNearestInt = pattern.filter == BLPatternFilter.nearest &&
            pattern.transform.m00 == 1.0 &&
            pattern.transform.m01 == 0.0 &&
            pattern.transform.m10 == 0.0 &&
            pattern.transform.m11 == 1.0 &&
            pattern.transform.m20 == 0.0 &&
            pattern.transform.m21 == 0.0 &&
            pattern.offset.x == pattern.offset.x.roundToDouble() &&
            pattern.offset.y == pattern.offset.y.roundToDouble(),
        _dxFxFp = (pattern.transform.m00 * _fpOne).round(),
        _dxFyFp = (pattern.transform.m10 * _fpOne).round(),
        _offsetXi = pattern.offset.x.round(),
        _offsetYi = pattern.offset.y.round(),
        _periodXFp = _computePeriodFp(pattern.image.width, pattern.extendModeX),
        _periodYFp =
            _computePeriodFp(pattern.image.height, pattern.extendModeY),
        _canFastAdvX = _checkFastAdv((pattern.transform.m00 * _fpOne).round(),
            _computePeriodFp(pattern.image.width, pattern.extendModeX)),
        _canFastAdvY = _checkFastAdv((pattern.transform.m10 * _fpOne).round(),
            _computePeriodFp(pattern.image.height, pattern.extendModeY)),
        _boxSpanX = pattern.transform.m00.abs() + pattern.transform.m01.abs(),
        _boxSpanY = pattern.transform.m10.abs() + pattern.transform.m11.abs(),
        _useBox = pattern.filter == BLPatternFilter.box
            ? _isReducingAtAll(pattern.transform)
            : _isReducing(pattern.transform);

  /// Redução mínima para que o filtro de caixa valha a pena.
  ///
  /// Abaixo disso a amostragem por ponto ainda visita quase todos os texels e
  /// não há alias a combater — mas há nitidez a perder. E o limite tem um caso
  /// concreto a respeitar: um ladrilho de PDF é rasterizado num bitmap de
  /// tamanho inteiro (`ceil`) e depois remapeado, o que dá fatores como 1,07
  /// sem que ninguém tenha pedido redução alguma; borrar as bordas do ladrilho
  /// aí seria uma regressão. A partir de 1,5 a amostragem por ponto já joga
  /// fora um terço da origem, e é quando o moiré aparece — uma digitalização
  /// de 300 dpi numa página a 96 dpi cai em 3,1.
  static const double _minReductionForBox = 1.5;

  /// True quando um passo de um pixel no device anda bem mais de um texel na
  /// origem, em alguma direção.
  ///
  /// O critério é o comprimento das COLUNAS da matriz — o quanto a origem
  /// caminha quando o device anda um pixel em x, e quando anda um pixel em y —
  /// e não o determinante nem a caixa envolvente. O determinante não vê uma
  /// matriz que achata só num eixo (determinante pequeno, mas metade da imagem
  /// jogada fora num eixo só). A caixa envolvente acusaria redução numa
  /// rotação pura de 45 graus, que não reduz nada: ali as duas colunas têm
  /// comprimento 1 e a imagem só gira.
  static bool _isReducing(BLMatrix2D m) {
    final colX = m.m00 * m.m00 + m.m10 * m.m10;
    final colY = m.m01 * m.m01 + m.m11 * m.m11;
    const limit = _minReductionForBox * _minReductionForBox;
    return colX > limit || colY > limit;
  }

  /// True para qualquer redução, por menor que seja.
  ///
  /// É o que [BLPatternFilter.box] passa a significar: quem pede `box` declara
  /// que está desenhando uma imagem, e não um ladrilho, e aceita integrar a
  /// área sempre que a origem for maior que o destino. O limiar de
  /// [_minReductionForBox] continua valendo para a escolha automática, que é o
  /// que protege a borda do ladrilho remapeado em 1,07.
  ///
  /// Em 1:1 exato isto é falso, então uma imagem colocada sem escala continua
  /// sendo amostrada por ponto e um código de barras não borra.
  static bool _isReducingAtAll(BLMatrix2D m) {
    final colX = m.m00 * m.m00 + m.m10 * m.m10;
    final colY = m.m01 * m.m01 + m.m11 * m.m11;
    const limit = 1.0 + 1e-6;
    return colX > limit || colY > limit;
  }

  /// Tile period in fixed-point: 0 for pad, w*fpOne for repeat, 2*w*fpOne for reflect.
  static int _computePeriodFp(int size, BLGradientExtendMode mode) {
    if (mode == BLGradientExtendMode.pad) return 0;
    final base = size * _fpOne;
    return mode == BLGradientExtendMode.reflect ? base * 2 : base;
  }

  /// True when |step| < period (branchless single-subtraction is sufficient).
  static bool _checkFastAdv(int stepFp, int periodFp) {
    if (periodFp <= 0) return false;
    final abs = stepFp < 0 ? -stepFp : stepFp;
    return abs < periodFp;
  }

  @pragma('vm:prefer-inline')
  int fetch(int x, int y) {
    if (_useBox) {
      return _fetchBox(x, y);
    }
    if (_filter == BLPatternFilter.nearest) {
      return _fetchNearest(x, y);
    }
    return _fetchBilinear(x, y);
  }

  /// Média da imagem sobre a área que este pixel de device cobre.
  ///
  /// Cada texel entra com o seu quinhão de sobreposição com a caixa, então o
  /// resultado é a média de área de verdade: um xadrez de 1 px reduzido à
  /// metade dá cinza uniforme, e não o padrão que o ponto isolado inventaria.
  int _fetchBox(int x, int y) {
    final fx = _m00 * x + _m01 * y + _m20 - _offsetX;
    final fy = _m10 * x + _m11 * y + _m21 - _offsetY;

    final ax0 = fx;
    final ax1 = fx + _boxSpanX;
    final ay0 = fy;
    final ay1 = fy + _boxSpanY;

    final ix0 = ax0.floor();
    final ix1 = ax1.ceil();
    final iy0 = ay0.floor();
    final iy1 = ay1.ceil();

    final nx = ix1 - ix0;
    final ny = iy1 - iy0;
    final stepX = nx <= _maxBoxSamples ? 1 : (nx + _maxBoxSamples - 1) ~/ _maxBoxSamples;
    final stepY = ny <= _maxBoxSamples ? 1 : (ny + _maxBoxSamples - 1) ~/ _maxBoxSamples;

    double sumA = 0.0, sumR = 0.0, sumG = 0.0, sumB = 0.0, sumW = 0.0;

    for (int iy = iy0; iy < iy1; iy += stepY) {
      final double top = iy > ay0 ? iy.toDouble() : ay0;
      final double bottomEdge = (iy + stepY).toDouble();
      final double bottom = bottomEdge < ay1 ? bottomEdge : ay1;
      final double wy = bottom - top;
      if (wy <= 0.0) continue;

      final sy = _periodYFp > 0
          ? _indexFromNorm(iy, _h, _extY)
          : _applyExtend(iy, _h, _extY);
      if (sy < 0) continue;
      final row = sy * _w;

      for (int ix = ix0; ix < ix1; ix += stepX) {
        final double left = ix > ax0 ? ix.toDouble() : ax0;
        final double rightEdge = (ix + stepX).toDouble();
        final double right = rightEdge < ax1 ? rightEdge : ax1;
        final double wx = right - left;
        if (wx <= 0.0) continue;

        final sx = _periodXFp > 0
            ? _indexFromNorm(ix, _w, _extX)
            : _applyExtend(ix, _w, _extX);
        if (sx < 0) continue;

        final w = wx * wy;
        final px = _pixels[row + sx];
        sumA += ((px >>> 24) & 0xFF) * w;
        sumR += ((px >>> 16) & 0xFF) * w;
        sumG += ((px >>> 8) & 0xFF) * w;
        sumB += (px & 0xFF) * w;
        sumW += w;
      }
    }

    if (sumW <= 0.0) return 0;
    final inv = 1.0 / sumW;
    int clamp255(double v) {
      final i = (v * inv).round();
      return i < 0 ? 0 : (i > 255 ? 255 : i);
    }

    return (clamp255(sumA) << 24) |
        (clamp255(sumR) << 16) |
        (clamp255(sumG) << 8) |
        clamp255(sumB);
  }

  @pragma('vm:prefer-inline')
  int _fetchNearest(int x, int y) {
    // Fast path: identity transform + integer offsets
    if (_useFastNearestInt) {
      final sx = _applyExtend(x - _offsetXi, _w, _extX);
      final sy = _applyExtend(y - _offsetYi, _h, _extY);
      if (sx < 0 || sy < 0) return 0;
      return _pixels[sy * _w + sx];
    }

    // Identity transform (non-integer offsets)
    if (_isIdentity) {
      _seqFpValid = false;
      final ix = (x - _offsetX).floor();
      final iy = (y - _offsetY).floor();
      final sx = _applyExtend(ix, _w, _extX);
      final sy = _applyExtend(iy, _h, _extY);
      if (sx < 0 || sy < 0) return 0;
      return _pixels[sy * _w + sx];
    }

    // Affine transform with C++ affine context optimization:
    // Normalize at span start (full modulo), then per-pixel branchless
    // overflow check replaces modulo (port of ox/oy/rx/ry from C++).
    int fxFp;
    int fyFp;
    if (_seqFpValid && y == _seqY && x == _seqNextX) {
      fxFp = _seqFxFp;
      fyFp = _seqFyFp;
    } else {
      // Span start: compute from transform + normalize
      fxFp = ((_m00 * x + _m01 * y + _m20 - _offsetX) * _fpOne).floor();
      fyFp = ((_m10 * x + _m11 * y + _m21 - _offsetY) * _fpOne).floor();
      if (_periodXFp > 0) fxFp = _normFp(fxFp, _periodXFp);
      if (_periodYFp > 0) fyFp = _normFp(fyFp, _periodYFp);
    }

    // Advance sequential state with branchless overflow check
    _advanceSeq(x, y, fxFp, fyFp);

    // Get pixel index from (possibly normalized) coordinate
    final ix = fxFp >> _fpShift;
    final iy = fyFp >> _fpShift;
    final sx = _periodXFp > 0
        ? _indexFromNorm(ix, _w, _extX)
        : _applyExtend(ix, _w, _extX);
    final sy = _periodYFp > 0
        ? _indexFromNorm(iy, _h, _extY)
        : _applyExtend(iy, _h, _extY);
    if (sx < 0 || sy < 0) return 0;
    return _pixels[sy * _w + sx];
  }

  @pragma('vm:prefer-inline')
  int _fetchBilinear(int x, int y) {
    // Identity transform: compute directly
    if (_isIdentity) {
      _seqFpValid = false;
      final fx = x - _offsetX;
      final fy = y - _offsetY;
      final x0 = fx.floor();
      final y0 = fy.floor();
      int ux = ((fx - x0) * 256.0 + 0.5).toInt();
      int uy = ((fy - y0) * 256.0 + 0.5).toInt();
      if (ux < 0) ux = 0;
      if (ux > 256) ux = 256;
      if (uy < 0) uy = 0;
      if (uy > 256) uy = 256;
      return _sampleBilinear4(x0, y0, ux, uy);
    }

    // Affine transform with C++ affine context optimization
    int fxFp;
    int fyFp;
    if (_seqFpValid && y == _seqY && x == _seqNextX) {
      fxFp = _seqFxFp;
      fyFp = _seqFyFp;
    } else {
      fxFp = ((_m00 * x + _m01 * y + _m20 - _offsetX) * _fpOne).floor();
      fyFp = ((_m10 * x + _m11 * y + _m21 - _offsetY) * _fpOne).floor();
      if (_periodXFp > 0) fxFp = _normFp(fxFp, _periodXFp);
      if (_periodYFp > 0) fyFp = _normFp(fyFp, _periodYFp);
    }

    _advanceSeq(x, y, fxFp, fyFp);

    final x0 = fxFp >> _fpShift;
    final y0 = fyFp >> _fpShift;
    final ux = fxFp & _fpMask;
    final uy = fyFp & _fpMask;

    return _sampleBilinear4(x0, y0, ux, uy);
  }

  // ---------- Sequential advance (C++ advance_x port) ----------

  @pragma('vm:prefer-inline')
  void _advanceSeq(int x, int y, int fxFp, int fyFp) {
    int nextFx = fxFp + _dxFxFp;
    int nextFy = fyFp + _dxFyFp;
    if (_periodXFp > 0) {
      if (_canFastAdvX) {
        // Branchless: single subtraction replaces modulo (C++ ox/rx trick)
        if (nextFx >= _periodXFp) nextFx -= _periodXFp;
        if (nextFx < 0) nextFx += _periodXFp;
      } else {
        nextFx = _normFp(nextFx, _periodXFp);
      }
    }
    if (_periodYFp > 0) {
      if (_canFastAdvY) {
        if (nextFy >= _periodYFp) nextFy -= _periodYFp;
        if (nextFy < 0) nextFy += _periodYFp;
      } else {
        nextFy = _normFp(nextFy, _periodYFp);
      }
    }
    _seqFpValid = true;
    _seqY = y;
    _seqNextX = x + 1;
    _seqFxFp = nextFx;
    _seqFyFp = nextFy;
  }

  // ---------- Bilinear 4-sample (unified) ----------

  @pragma('vm:prefer-inline')
  int _sampleBilinear4(int x0, int y0, int ux, int uy) {
    int sx0, sx1, sy0, sy1;
    if (_periodXFp > 0) {
      sx0 = _indexFromNorm(x0, _w, _extX);
      sx1 = _indexFromNorm(x0 + 1, _w, _extX);
    } else {
      sx0 = _applyExtend(x0, _w, _extX);
      sx1 = _applyExtend(x0 + 1, _w, _extX);
    }
    if (_periodYFp > 0) {
      sy0 = _indexFromNorm(y0, _h, _extY);
      sy1 = _indexFromNorm(y0 + 1, _h, _extY);
    } else {
      sy0 = _applyExtend(y0, _h, _extY);
      sy1 = _applyExtend(y0 + 1, _h, _extY);
    }
    if (sx0 < 0 || sy0 < 0 || sx1 < 0 || sy1 < 0) return 0;

    final p00 = _pixels[sy0 * _w + sx0];
    final p10 = _pixels[sy0 * _w + sx1];
    final p01 = _pixels[sy1 * _w + sx0];
    final p11 = _pixels[sy1 * _w + sx1];

    final w00 = (256 - ux) * (256 - uy);
    final w10 = ux * (256 - uy);
    final w01 = (256 - ux) * uy;
    final w11 = ux * uy;
    return _blend4(p00, p10, p01, p11, w00, w10, w01, w11);
  }

  // ---------- Normalization helpers (C++ normalize_px_py port) ----------

  /// Normalize fixed-point coordinate to [0, period) using full modulo.
  /// Called at span start; per-pixel advance uses branchless subtraction.
  @pragma('vm:prefer-inline')
  static int _normFp(int v, int period) {
    v = v % period;
    if (v < 0) v += period;
    return v;
  }

  /// Get pixel index from normalized coordinate (no modulo needed).
  /// For repeat: v is in [0, size), bilinear neighbor v+1 may equal size.
  /// For reflect: v is in [0, 2*size), XOR-style fold for mirroring.
  /// For pad: v may be any value, clamp to [0, size-1].
  @pragma('vm:prefer-inline')
  static int _indexFromNorm(int v, int size, BLGradientExtendMode mode) {
    switch (mode) {
      case BLGradientExtendMode.pad:
        if (v < 0) return 0;
        if (v >= size) return size - 1;
        return v;
      case BLGradientExtendMode.repeat:
        v %= size;
        if (v < 0) v += size;
        return v;
      case BLGradientExtendMode.reflect:
        final period = size * 2;
        v %= period;
        if (v < 0) v += period;
        if (v >= size) return period - 1 - v;
        return v;
    }
  }

  @pragma('vm:prefer-inline')
  static int _blend4(
    int p00,
    int p10,
    int p01,
    int p11,
    int w00,
    int w10,
    int w01,
    int w11,
  ) {
    final a = (((p00 >>> 24) & 0xFF) * w00 +
            ((p10 >>> 24) & 0xFF) * w10 +
            ((p01 >>> 24) & 0xFF) * w01 +
            ((p11 >>> 24) & 0xFF) * w11) >>
        16;

    final r = (((p00 >>> 16) & 0xFF) * w00 +
            ((p10 >>> 16) & 0xFF) * w10 +
            ((p01 >>> 16) & 0xFF) * w01 +
            ((p11 >>> 16) & 0xFF) * w11) >>
        16;

    final g = (((p00 >>> 8) & 0xFF) * w00 +
            ((p10 >>> 8) & 0xFF) * w10 +
            ((p01 >>> 8) & 0xFF) * w01 +
            ((p11 >>> 8) & 0xFF) * w11) >>
        16;

    final b = (((p00) & 0xFF) * w00 +
            ((p10) & 0xFF) * w10 +
            ((p01) & 0xFF) * w01 +
            ((p11) & 0xFF) * w11) >>
        16;

    return (a << 24) | (r << 16) | (g << 8) | b;
  }

  @pragma('vm:prefer-inline')
  static int _applyExtend(int v, int size, BLGradientExtendMode mode) {
    if (size <= 0) return -1;

    switch (mode) {
      case BLGradientExtendMode.pad:
        if (v < 0) return 0;
        if (v >= size) return size - 1;
        return v;

      case BLGradientExtendMode.repeat:
        int r = v % size;
        if (r < 0) r += size;
        return r;

      case BLGradientExtendMode.reflect:
        if (size == 1) return 0;
        final period = size * 2;
        int r = v % period;
        if (r < 0) r += period;
        return r < size ? r : (period - 1 - r);
    }
  }
}
