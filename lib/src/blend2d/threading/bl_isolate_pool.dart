import 'dart:async';

/// Pool que **não usa isolates**. Depreciado.
///
/// O nome e a posição em `package:dgfx/dgfx_io.dart` prometem paralelismo que
/// nunca existiu: [run] executa o job no isolate corrente, via
/// `Future.sync`. Não há `Isolate.spawn` aqui — o arquivo nem importa
/// `dart:isolate`. [workerCount] é guardado e ignorado.
///
/// A promessa não foi cumprida porque não compensa: Dart não compartilha
/// memória entre isolates sem `dart:ffi` (que este pacote não usa), então
/// paralelizar o rasterizador exigiria copiar `covers`/`areas`/framebuffer
/// ida e volta. Medição nesta máquina, página A4 a 300 dpi (2480x3508):
/// enviar um framebuffer a um isolate custa ~31 ms, recebê-lo de volta ~9 ms
/// e o fill inteiro da página custa ~11 ms. O caminho "paralelo" seria
/// várias vezes mais lento que o sequencial.
///
/// Se você precisa de paralelismo de verdade, paralelize acima do dgfx: uma
/// [BLImage] por isolate (por exemplo, uma página por isolate) e junte os
/// resultados. Essa granularidade amortiza a cópia; a granularidade de faixa
/// de scanline não.
///
/// Será removido numa versão futura.
@Deprecated(
  'BLIsolatePool não usa isolates: run() executa o job no isolate corrente. '
  'Paralelize acima do dgfx (uma BLImage por isolate). Será removido.',
)
class BLIsolatePool {
  final int workerCount;
  bool _started = false;
  bool _disposed = false;

  BLIsolatePool({required this.workerCount})
      : assert(workerCount > 0, 'workerCount must be > 0');

  Future<void> start() async {
    if (_disposed) {
      throw StateError('BLIsolatePool is disposed');
    }
    _started = true;
  }

  bool get isStarted => _started;
  bool get isDisposed => _disposed;

  /// Executa [job] **no isolate corrente** e devolve o resultado.
  ///
  /// Apesar do nome da classe, não há troca de isolate nem serialização: isto
  /// é `Future.sync(job)` com verificação de ciclo de vida.
  Future<T> run<T>(FutureOr<T> Function() job) async {
    if (_disposed) {
      throw StateError('BLIsolatePool is disposed');
    }
    if (!_started) {
      await start();
    }
    return await Future<T>.sync(job);
  }

  Future<void> dispose() async {
    _disposed = true;
    _started = false;
  }
}
