/// Extensões do motor gráfico que dependem da plataforma nativa.
///
/// Este ponto de entrada é separado de `package:dgfx/dgfx.dart` de propósito:
/// o que está aqui usa `dart:io`, então importá-lo tira o seu programa da
/// compatibilidade com web e wasm. Se você compila para o navegador, importe
/// apenas `dgfx.dart` e carregue fontes com `BLFontFace.parse(bytes)`,
/// obtendo os bytes por conta própria.
///
/// - [BLFontLoader] lê arquivos de fonte do disco (`dart:io`).
/// - `BLIsolatePool` está **depreciado** e não usa isolates: `run()` executa
///   o job no isolate corrente. Veja a documentação da classe para a medição
///   que motivou a decisão de não implementá-lo.
library;

export 'dgfx.dart';

export 'src/blend2d/text/bl_font_loader.dart';
export 'src/blend2d/threading/bl_isolate_pool.dart';
