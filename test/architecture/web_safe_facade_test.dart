import 'dart:io';

import 'package:test/test.dart';

/// Bibliotecas `dart:` que quebram compilação/execução em web e wasm.
const _forbiddenDartLibraries = <String>{
  'dart:io',
  'dart:isolate',
  'dart:ffi',
  'dart:html',
};

/// Uma aresta do grafo: quem importou o quê.
class _Edge {
  final String from;
  final String uri;

  const _Edge(this.from, this.uri);
}

/// Extrai os URIs de `import`/`export`/`part` de um arquivo Dart.
///
/// Parsing por regex em vez do analyzer de propósito: o teste não deve
/// depender de nenhum pacote além de `test`, e diretivas em Dart são
/// sintaticamente simples o bastante (sempre no topo, sempre com o URI numa
/// string literal).
List<String> _directiveUris(String source) {
  // Remove comentários de bloco e de linha para não capturar imports que
  // estejam comentados.
  final withoutComments = source
      .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
      .replaceAll(RegExp(r'^\s*//.*$', multiLine: true), '');

  final pattern = RegExp(
    r'''^\s*(?:import|export|part)\s+(?:'([^']+)'|"([^"]+)")''',
    multiLine: true,
  );

  final uris = <String>[];
  for (final match in pattern.allMatches(withoutComments)) {
    final uri = match.group(1) ?? match.group(2);
    // `part of` não tem URI de arquivo neste formato; o grupo vem nulo.
    if (uri != null) uris.add(uri);
  }
  return uris;
}

/// Resolve um URI de diretiva para um caminho de arquivo do projeto, ou null
/// se o URI aponta para fora dele (outro pacote, `dart:`).
String? _resolve(String uri, String fromFile, String libDir) {
  if (uri.startsWith('dart:')) return null;
  if (uri.startsWith('package:dgfx/')) {
    return _normalize('$libDir/${uri.substring('package:dgfx/'.length)}');
  }
  if (uri.startsWith('package:')) return null;
  final dir = fromFile.substring(0, fromFile.lastIndexOf('/'));
  return _normalize('$dir/$uri');
}

/// Colapsa `.` e `..` e normaliza separadores para `/`.
String _normalize(String path) {
  final parts = <String>[];
  for (final segment in path.replaceAll(r'\', '/').split('/')) {
    if (segment == '.' || segment.isEmpty) continue;
    if (segment == '..') {
      if (parts.isNotEmpty) parts.removeLast();
      continue;
    }
    parts.add(segment);
  }
  return parts.join('/');
}

/// Percorre o grafo de imports a partir de [entryPoint] e devolve, para cada
/// biblioteca `dart:` proibida encontrada, a cadeia de arquivos que levou até
/// ela.
Map<String, List<String>> _findForbidden(String entryPoint, String libDir) {
  final violations = <String, List<String>>{};
  final visited = <String>{};
  final parents = <String, String>{};
  final queue = <_Edge>[_Edge('<entry>', entryPoint)];

  while (queue.isNotEmpty) {
    final edge = queue.removeAt(0);
    final path = edge.uri;
    if (!visited.add(path)) continue;

    final file = File(path);
    if (!file.existsSync()) {
      fail('Arquivo referenciado não existe: $path (via ${edge.from})');
    }

    for (final uri in _directiveUris(file.readAsStringSync())) {
      if (_forbiddenDartLibraries.contains(uri)) {
        violations.putIfAbsent(uri, () => _chain(path, parents, entryPoint));
        continue;
      }
      final resolved = _resolve(uri, path, libDir);
      if (resolved == null || visited.contains(resolved)) continue;
      parents[resolved] = path;
      queue.add(_Edge(path, resolved));
    }
  }

  return violations;
}

/// Reconstrói o caminho entry point → ... → [file].
List<String> _chain(String file, Map<String, String> parents, String entry) {
  final chain = <String>[file];
  var current = file;
  while (current != entry) {
    final parent = parents[current];
    if (parent == null) break;
    chain.insert(0, parent);
    current = parent;
  }
  return chain;
}

void main() {
  // Os testes rodam com o diretório raiz do pacote como CWD.
  const libDir = 'lib';
  const facade = 'lib/dgfx.dart';
  const ioEntry = 'lib/dgfx_io.dart';

  group('lib/dgfx.dart web-safe facade', () {
    test('não alcança dart:io, dart:isolate, dart:ffi nem dart:html', () {
      final violations = _findForbidden(facade, libDir);

      if (violations.isNotEmpty) {
        final report = violations.entries
            .map((e) =>
                '  ${e.key} alcançado via:\n    ${e.value.join('\n    ')}')
            .join('\n');
        fail('A facade web-safe alcança bibliotecas proibidas:\n$report');
      }

      expect(violations, isEmpty);
    });

    test('exclui explicitamente bl_font_loader e bl_isolate_pool', () {
      final uris = _directiveUris(File(facade).readAsStringSync());
      expect(uris.any((u) => u.contains('bl_font_loader')), isFalse,
          reason: 'bl_font_loader.dart importa dart:io');
      expect(uris.any((u) => u.contains('bl_isolate_pool')), isFalse,
          reason: 'o pool de isolates não faz sentido em wasm');
    });

    test('exporta o núcleo Blend2D que o renderizador PDF precisa', () {
      final uris = _directiveUris(File(facade).readAsStringSync());
      const required = [
        'context/bl_context.dart',
        'core/bl_image.dart',
        'core/bl_types.dart',
        'geometry/bl_path.dart',
        'geometry/bl_stroker.dart',
        'geometry/bl_dasher.dart',
        'raster/bl_analytic_rasterizer.dart',
        'text/bl_font.dart',
        'text/bl_text_layout.dart',
      ];
      for (final path in required) {
        expect(uris.any((u) => u.endsWith(path)), isTrue,
            reason: 'falta exportar $path');
      }
    });

    test('o detector realmente pega uma violação (guarda do próprio teste)',
        () {
      // Sem este caso, um bug no walker faria o teste principal passar sempre.
      // `dgfx_io.dart` é o ponto de entrada que assume a plataforma nativa, e
      // alcança dart:io via text/bl_font_loader.dart de propósito.
      final violations = _findForbidden(ioEntry, libDir);
      expect(violations.keys, contains('dart:io'),
          reason: 'se isto falhar, o walker parou de enxergar as arestas '
              'e o teste principal virou um falso positivo');
      expect(violations['dart:io']!.last, contains('bl_font_loader.dart'));
    });

    test(
        'dgfx_io.dart reexporta a facade web-safe, para quem usa nativo '
        'precisar de um import só', () {
      final uris = _directiveUris(File(ioEntry).readAsStringSync());
      expect(uris, contains('dgfx.dart'));
      expect(uris.any((u) => u.contains('bl_font_loader')), isTrue);
      expect(uris.any((u) => u.contains('bl_isolate_pool')), isTrue);
    });
  });
}
