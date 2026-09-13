# Roteiro — Scanline Edge‑Flag AA otimizado em Dart

## Objetivo
Implementar o algoritmo Scanline Edge‑Flag para antialiasing de polígonos em Dart, com foco em desempenho (SIMD, pragmas da VM, acesso sequencial e buffers compactos), suportando regras de preenchimento even‑odd e non‑zero, e preparando caminho para variações de filtros e clipping.

foco em construir um renderizador 2D de alta performace
para renderizar formas e testos (SVG) para imagens 2D PNG

## Referências obrigatórias (base conceitual)
- pesquisa\Scanline edge-flag algorithm for antialiasing.md (artigo “Scanline edge‑flag algorithm for antialiasing”).
- SLEFA_1_0_1 (código C++ original e docs do autor).
- SLEFA_QT_comparisons (dados de desempenho comparativo).

## 1) Leitura e extração dos requisitos
1. Ler o artigo (pesquisa\Scanline edge-flag algorithm for antialiasing.md):
   - Entender o fluxo geral: marcação de bordas → varredura por scanline → máscara de cobertura.
   - Identificar variantes: even‑odd vs non‑zero, buffer full‑height vs scanline‑oriented, padrões de amostragem (n‑rooks), otimizações listadas.
2. Inspecionar SLEFA_1_0_1:
   - Localizar “PolygonVersionF.cpp” (versão final) e “NonZeroMaskC.h”.
   - Mapear as estruturas: Edge Table (ET), Active Edge Table (AET), DDA, mask tracking.
   - Confirmar parâmetros: SUBPIXEL_SHIFT (8/16/32 amostras), offsets n‑rooks.
3. Consultar SLEFA_QT_comparisons/results.txt para estabelecer metas de performance.

## 2) Definições de escopo para o port em Dart
1. Entrada:
   - Polígonos simples/complexos (concavos, auto‑interseção).
   - Coordenadas em float/double (converter para fixed‑point internamente).
2. Saída:
   - Máscara de cobertura por pixel (0–255 ou 0–N), com conversão para alpha.
   - Buffer RGBA (Uint32) ou buffer de alpha separado (Uint8).
3. Regras de preenchimento:
   - Implementar even‑odd primeiro; depois non‑zero.
4. Amostragem:
   - Definir padrões de 8, 16 e 32 amostras (n‑rooks conforme artigo).

## 3) Arquitetura de módulos (Dart)
1. `edge.dart`
   - Estrutura de Edge: `yStart`, `yEnd`, `x`, `dx`, `dir`.
2. `edge_table.dart`
   - ET por scanline (lista/array de listas).
3. `scanline_buffer.dart`
   - Buffer de marcação por scanline (bits ou contadores compactos).
4. `rasterizer.dart`
   - Pipeline: build ET → varrer scanlines → preencher → produzir máscara/alpha.
5. `patterns.dart`
   - Offsets n‑rooks para 8/16/32.

## 4) Núcleo do algoritmo (primeiro pass)
1. Converter coordenadas para fixed‑point (ex.: 24.8 ou 16.8), com escala por subpixel.
2. Construir ET:
   - Ignorar arestas horizontais.
   - Normalizar direção (y0 < y1), registrar `dir` (+1/-1).
   - Calcular `x` inicial no primeiro sub‑scanline.
3. Loop de scanlines:
   - Mover edges da ET para AET.
   - Plotar arestas em sub‑scanlines (DDA) usando offsets n‑rooks.
   - Gerar máscara por XOR (even‑odd) ou acumular contador (non‑zero).
   - Fazer fill left→right acumulando e produzindo máscara por pixel.

## 5) Otimizações específicas para Dart
1. Tipos e buffers:
   - Usar `Uint32List`/`Uint16List`/`Uint8List` para buffers.
   - Evitar listas dinâmicas no hot‑loop; pré‑alocar.
2. Fixed‑point:
   - Evitar `double` dentro do loop (usar `int` e shifts).
3. SIMD e vetorização:
   - Explorar `Uint32List` para processar 32/64 bits de máscara por vez.
   - Organizar o buffer por palavra (32‑bit) para reduzir branches.
4. Pragmas da VM:
   - Usar `@pragma('vm:prefer-inline')` em funções de hot‑loop.
   - Usar `@pragma('vm:never-inline')` em helpers não críticos.
   - Evitar closures e alocações dentro do raster loop.
5. Branch minimization:
   - Separar caminhos “full”, “empty” e “partial” no loop de fill.
6. Cache locality:
   - Adotar abordagem scanline‑oriented para reduzir footprint.
7. Loop unrolling:
   - Unroll manual para sub‑scanlines fixas (8/16/32) com offsets precomputados.

## 6) Implementação de non‑zero winding
1. Alterar o buffer de marcação:
   - Trocar XOR por acumulador de direção (+1/‑1) por amostra.
2. Compactação:
   - Empacotar múltiplos contadores em `Uint32/Uint64` (com padding bit a cada 7 bits).
3. Fill:
   - Converter contador acumulado para “mask on/off”.
   - Atualizar máscara somente quando transição 0↔non‑zero ocorre.

## 7) Clipping e limites
1. Clipping vertical:
   - Ajustar `yStart/yEnd` no ET para o retângulo de clip.
2. Clipping horizontal:
   - Clamp por scanline; dividir arestas que cruzam limites se necessário.
3. Extents:
   - Calcular `minX/maxX` por scanline para reduzir trabalho de fill.

## 8) Conversão de máscara para alpha
1. Tabela LUT `popcount -> alpha` para N amostras.
2. Opcional: filtros maiores (2×2) com lookup adicional.

## 9) Validação e benchmarks
1. Testes funcionais:
   - Quadrado, estrela, polígonos auto‑intersectantes.
   - Comparar even‑odd vs non‑zero.
2. Benchmarks:
   - Reproduzir cenários similares ao SLEFA_QT_comparisons.
   - Medir com 8/16/32 amostras.

## 10) Entregáveis mínimos
- Implementação base even‑odd (scanline‑oriented).
- Implementação non‑zero com compactação.
- Padrões n‑rooks 8/16/32.
- Testes de regressão + benchmark simples.

## Observações finais
- Priorize uma versão correta e previsível antes das otimizações agressivas.
- Isolar o hot‑loop para permitir futuras versões com intrínsecos ou FFI.
