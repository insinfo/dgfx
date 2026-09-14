import 'dart:async';

/// Contrato unificado para rasterizadores de poligonos no projeto.
///
/// `windingRule`:
/// - `0`: even-odd
/// - `1`: non-zero
///
/// `contourVertexCounts`:
/// - lista de contornos (subpaths) em numero de vertices.
/// - `null` ou vazio = um unico contorno com todos os vertices.
abstract class PolygonContract {
  FutureOr<void> drawPolygon(
    List<double> vertices,
    int color, {
    int windingRule = 1,
    List<int>? contourVertexCounts,
  });
}
