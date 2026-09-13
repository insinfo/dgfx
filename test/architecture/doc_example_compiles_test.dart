import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// Extrai os blocos ```dart de um texto Markdown (ou de um dartdoc já sem os
/// `///`).
List<String> _dartFences(String source) {
  final blocks = <String>[];
  final lines = const LineSplitter().convert(source);
  StringBuffer? current;
  for (final line in lines) {
    final trimmed = line.trimLeft();
    if (current == null) {
      if (trimmed == '```dart') current = StringBuffer();
      continue;
    }
    if (trimmed == '```') {
      blocks.add(current.toString());
      current = null;
      continue;
    }
    current.writeln(line);
  }
  return blocks;
}

/// Tira os `///` do dartdoc de biblioteca no topo de [source].
String _stripDoc(String source) {
  final out = StringBuffer();
  for (final line in const LineSplitter().convert(source)) {
    final trimmed = line.trimLeft();
    if (!trimmed.startsWith('///')) continue;
    var body = trimmed.substring(3);
    if (body.startsWith(' ')) body = body.substring(1);
    out.writeln(body);
  }
  return out.toString();
}

/// Escreve [program] num diretório temporário com um `package_config.json` que
/// aponta para este pacote, e roda `dart analyze` nele.
///
/// É a única forma de provar que um trecho de documentação compila: conferir o
/// texto à mão é exatamente o que deixou `ctx.clearAll(...)` — um método que
/// nunca existiu — no exemplo canônico do pacote.
ProcessResult _analyzeSnippet(String program, String packageRoot) {
  final dir = Directory.systemTemp.createTempSync('dgfx_doc_example');
  try {
    final toolDir = Directory('${dir.path}/.dart_tool')..createSync();
    final rootUri = Uri.directory(packageRoot).toString();
    File('${toolDir.path}/package_config.json').writeAsStringSync(
      jsonEncode({
        'configVersion': 2,
        'packages': [
          {
            'name': 'dgfx',
            'rootUri': rootUri,
            'packageUri': 'lib/',
            'languageVersion': '3.0',
          },
        ],
      }),
    );
    final main = File('${dir.path}/main.dart')..writeAsStringSync(program);
    return Process.runSync(
      Platform.resolvedExecutable,
      ['analyze', '--fatal-warnings', main.path],
      workingDirectory: dir.path,
    );
  } finally {
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Um antivírus segurando o handle não deve derrubar o teste.
    }
  }
}

void main() {
  final packageRoot = Directory.current.path;

  group('os exemplos da documentação compilam', () {
    test('o exemplo do dartdoc de lib/dgfx.dart', () {
      final source = File('lib/dgfx.dart').readAsStringSync();
      final blocks = _dartFences(_stripDoc(source));
      expect(blocks, hasLength(1),
          reason: 'esperava exatamente um bloco ```dart no dartdoc da '
              'biblioteca; se o exemplo mudou, ajuste este teste junto');

      final result = _analyzeSnippet(blocks.single, packageRoot);
      expect(
        result.exitCode,
        0,
        reason: 'o exemplo canônico de lib/dgfx.dart não compila:\n'
            '${result.stdout}\n${result.stderr}',
      );
    });

    test('o exemplo de uso do README', () {
      final blocks = _dartFences(File('README.md').readAsStringSync())
          .where((b) => b.contains("import 'package:dgfx/dgfx.dart';"))
          .toList();
      expect(blocks, isNotEmpty, reason: 'o README perdeu o exemplo de uso');

      for (final block in blocks) {
        final result = _analyzeSnippet(block, packageRoot);
        expect(
          result.exitCode,
          0,
          reason: 'um exemplo do README não compila:\n'
              '${result.stdout}\n${result.stderr}',
        );
      }
    });
  },
      // `dart analyze` num processo separado é lento na primeira execução.
      timeout: const Timeout(Duration(minutes: 3)));
}
