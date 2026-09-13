/// Motor gráfico 2D em Dart puro — ponto de entrada principal.
///
/// Rasterizador analítico com anti-aliasing, composição Porter-Duff e modos de
/// mesclagem, gradientes (linear, radial, cônico), padrões com filtragem e
/// transformação afim, stroking com todos os caps e joins, tracejado, clipping
/// por caminho arbitrário e texto OpenType (`glyf` e CFF) com layout e cache.
///
/// Tudo aqui é compilável para native, web e wasm: o grafo de imports
/// alcançável a partir deste arquivo não toca `dart:io`, `dart:isolate`,
/// `dart:ffi` nem `dart:html`, e o pacote não tem dependências de runtime.
/// `test/architecture/web_safe_facade_test.dart` percorre o grafo de imports
/// de verdade para garantir essa promessa a cada build.
///
/// Para carregar fontes de arquivo ou usar o pool de isolates — recursos que
/// só existem fora do navegador — importe `package:dgfx/dgfx_io.dart`.
///
/// ```dart
/// import 'package:dgfx/dgfx.dart';
///
/// Future<void> main() async {
///   final image = BLImage(200, 200);
///   final ctx = BLContext(image)..clear(0xFFFFFFFF);
///   final path = BLPath()
///     ..moveTo(20, 20)
///     ..lineTo(180, 60)
///     ..lineTo(100, 180)
///     ..close();
///   ctx.setFillStyle(0xFF3366CC);
///   await ctx.fillPath(path);
///   ctx.flush();
///   // `image.pixels` é um Uint32List ARGB pronto para ser codificado.
/// }
/// ```
library;

// Contexto de desenho e superfície.
export 'src/blend2d/context/bl_context.dart';
export 'src/blend2d/core/bl_image.dart';
export 'src/blend2d/core/bl_types.dart';

// Geometria.
export 'src/blend2d/geometry/bl_dasher.dart';
export 'src/blend2d/geometry/bl_path.dart';
export 'src/blend2d/geometry/bl_stroker.dart';

// Pipeline de composição e fetchers de estilo.
export 'src/blend2d/pipeline/bl_compop_kernel.dart';
export 'src/blend2d/pipeline/bl_fetch_conic_gradient.dart';
export 'src/blend2d/pipeline/bl_fetch_gouraud.dart';
export 'src/blend2d/pipeline/bl_fetch_linear_gradient.dart';
export 'src/blend2d/pipeline/bl_fetch_pattern.dart';
export 'src/blend2d/pipeline/bl_fetch_radial_gradient.dart';
export 'src/blend2d/pipeline/bl_fetch_solid.dart';
export 'src/blend2d/pixelops/bl_pixelops.dart';

// Rasterizador analítico.
export 'src/blend2d/raster/bl_analytic_rasterizer.dart';
export 'src/blend2d/raster/bl_edge_builder.dart';
export 'src/blend2d/raster/bl_raster_defs.dart';

// Texto (parsing de fonte em memória, layout e rasterização de glifos).
export 'src/blend2d/text/bl_bidi.dart';
export 'src/blend2d/text/bl_cff.dart';
export 'src/blend2d/text/bl_font.dart';
export 'src/blend2d/text/bl_font_collection.dart';
export 'src/blend2d/text/bl_glyph_cache.dart';
export 'src/blend2d/text/bl_glyph_rasterizer.dart';
export 'src/blend2d/text/bl_glyph_run.dart';
export 'src/blend2d/text/bl_mac_glyph_names.dart';
export 'src/blend2d/text/bl_opentype_layout.dart';
export 'src/blend2d/text/bl_text_layout.dart';
export 'src/blend2d/text/bl_type1.dart';
