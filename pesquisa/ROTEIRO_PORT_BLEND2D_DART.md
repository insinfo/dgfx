# Roteiro Detalhado: Blend2D like para Dart (extremamente otimizado) biblioteca grafica de alto desempenho inspirada no blend2d

Projeto alvo:
- Referência C++: `referencias/blend2d-master/blend2d`
- Port Dart: `lib/src/blend2d`

Objetivo:
- Portar a arquitetura do Blend2D de forma incremental, com foco em:
  - Qualidade visual correta (AA, furos, composições)
  - Throughput alto em CPU
  - Renderização de texto em puro Dart (OpenType + shaping + glyph raster + cache)
  - Design estável para evoluir depois para FFI/shared memory, sem retrabalho estrutural
  - API gráfica completa para futuro renderizador PDF otimizado em puro Dart

antes de qualquer reversão é bom executar pelo menos umas 10 vezes para garantir e consolidar média/faixa para decidirmos com mais confiança qualquer reversão

## Status de Execução (atualizado)

Concluído agora:
- Bootstrap inicial criado em `lib/src/blend2d/`:
  - `core/`: `bl_types.dart`, `bl_image.dart`
  - `geometry/`: `bl_path.dart`, `bl_stroker.dart`
  - `raster/`: `bl_edge_builder.dart`, `bl_edge_storage.dart`, `bl_analytic_rasterizer.dart`, `bl_raster_defs.dart`
  - `pipeline/`: `bl_compop_kernel.dart`, `bl_fetch_solid.dart`, `bl_fetch_linear_gradient.dart`, `bl_fetch_radial_gradient.dart`, `bl_fetch_pattern.dart`
  - `pixelops/`: `bl_pixelops.dart` (premultiply/unpremultiply/udiv255/swizzle/sRGB)
  - `context/`: `bl_context.dart` (save/restore, clip rect, transform afim, fillRect/strokeRect)
  - `threading/`: `bl_isolate_pool.dart` (API estável, execução local por enquanto)
  - `text/`: `bl_font.dart`, `bl_font_loader.dart`, `bl_glyph_run.dart`, `bl_text_layout.dart`
  - barrel export: `lib/src/blend2d/blend2d.dart`
- Harness de benchmark inicial:
  - `benchmark/blend2d_port_benchmark.dart`
  - cena sintética com furos, linha fina, arco e sobreposição.

Estado por fase:
- Fase 0: parcialmente concluída (harness dedicado já existe, falta diff automatizado/heatmap).
- Fase 1: parcialmente concluída (API mínima funcional para fill de polígonos/paths).
- Fase 2: iniciada (scanline nativo com AET, suporte a `evenOdd/nonZero` e contornos múltiplos).
- Fase 3: **concluída** — todos os 28 comp-ops do Blend2D C++ implementados (srcOver, srcCopy, srcIn, srcOut, srcAtop, dstOver, dstCopy, dstIn, dstOut, dstAtop, xor, clear, plus, minus, modulate, multiply, screen, overlay, darken, lighten, colorDodge, colorBurn, linearBurn, linearLight, pinLight, hardLight, softLight, difference, exclusion) + módulo `pixelops/bl_pixelops.dart` portado de `pixelops/scalar_p.h`.
- Fase 4: concluída (gradientes linear/radial + pattern nearest/bilinear/affine com fetchers dedicados).
- Fase 5: **concluída** — stroker robusto com paridade geométrica C++ em todos os caps (butt/square/round/roundRev/triangle/triangleRev) e joins (bevel/miterClip/miterBevel/miterRound/round), vetor `q = normal(p1-p0)*0.5` fiel à referência `pathstroke.cpp`.
- Fase 6-7: não iniciadas (paralelismo real e otimizações agressivas ainda pendentes).
- Fase 8-11 (texto): bootstrap avançando (loader + parser OpenType base de `head/maxp/hhea/hmtx/cmap/name/OS/2/kern` + layout simples + decoder inicial de outlines `glyf` simples/compostos + cache de outline por tamanho). Shaping avançado (GSUB/GPOS), `cff/cff2` e raster dedicado de glifos ainda pendentes.

Atualização incremental (port C++ -> Dart):
- `raster/bl_analytic_rasterizer.dart` não depende mais do backend legado.
- Regras de varredura estabilizadas com:
  - intervalo ativo em `y + 0.5` (semântica top/bottom mais robusta),
  - agrupamento por `x` coincidente para aplicar winding/toggle sem artefatos de vértice.
- Estrutura `raster/bl_edge_storage.dart` adicionada (SoA + buckets por scanline), inspirada em `edgestorage_p.h`, reduzindo alocações por draw-call.
- Raster migrado para base `A8` fixed-point (inspirado em `Pipeline::A8Info`):
  - constantes/ops em `raster/bl_raster_defs.dart`,
  - interseções e spans calculados em inteiro subpixel (8 bits),
  - avanço incremental por `xLift/xRem/xErr` (estilo `analyticrasterizer_p.h`).
- AA incremental adicionado no raster nativo:
  - subamostragem vertical por scanline (`aaSubsampleY`, default 2),
  - composição por cobertura acumulada da linha,
  - fast-path para runs com cobertura total e `src` opaco.
- Otimização do estágio AA:
  - acumulação de cobertura por `difference buffer + prefix sum` por scanline,
  - remoção do incremento pixel-a-pixel por span em cada subamostra,
  - redução de custo no hot-loop mantendo a mesma saída visual do AA incremental atual.
- Otimizações adicionais de hot-loop (inspiradas em `analyticrasterizer_p.h`):
  - lista de AET migrada para `Int32List + activeCount` (sem `List<int>.add/clear/length` no loop por scanline),
  - ordenação da AET trocada de `List.sort(comparator)` para insertion sort in-place incremental (menor overhead em listas quase ordenadas),
  - passo de erro do edge (`xErr/xRem/dy`) reescrito em forma branch-minimized (mesma matemática, menos jitter de branch).
- Geometria de path evoluída:
  - `BLPath` agora suporta `quadTo()` e `cubicTo()` com flatten adaptativo (De Casteljau),
  - base pronta para aproximação de curvas do pipeline `EdgeSourcePath` do Blend2D.
- OpenType/texto (bootstrap avançado, inspirado em `otcore/otcmap/otmetrics`):
  - parser SFNT de diretório de tabelas (`head`, `maxp`, `hhea`, `hmtx`, `cmap`) em `text/bl_font.dart`,
  - seleção de melhor sub-tabela `cmap` por score de plataforma/encoding (priorizando Windows Unicode, como no Blend2D),
  - mapeamento de caracteres para glifos suportando formatos `0`, `4`, `6`, `10`, `12` e `13`,
  - leitura de métricas horizontais (`numHMetrics`/`hmtx`) e cálculo de advance por glifo,
  - `BLTextLayout.shapeSimple()` passou a usar `glyphId` real (`cmap`) + `advance` real da fonte,
  - fallback para fontes símbolo (`codepoint + 0xF000`) quando o mapeamento direto retorna glifo indefinido.
- OpenType `name` (inspirado em `otname.cpp`):
  - parser da tabela `name` com escolha por score de plataforma/encoding/idioma (Unicode, Windows, Mac Roman),
  - suporte a `nameId` essenciais (`1/2/4/6/16/17/21/22`) com preferência tipográfica (`16/17` sobre `1/2/21/22`),
  - decodificação `UTF16-BE` e `Latin1` com saneamento de terminadores nulos,
  - normalização de `family/subfamily` para evitar subfamily redundante no fim do family.
- OpenType `kern` legacy (inspirado em `otkern`):
  - parser do `kern` (headers Windows/Mac) com seleção de sub-tabelas horizontais `format 0`,
  - extração e composição de pares `(left,right)->value` em unidades da fonte,
  - aplicação de kerning em `BLTextLayout.shapeSimple()` antes do avanço do glifo atual.
- OpenType `OS/2` (inspirado em `otcore.cpp`):
  - leitura de `weightClass`/`widthClass` com clamp e correção do intervalo `1..9 -> 100..900`,
  - suporte ao bit `USE_TYPO_METRICS` (`fsSelection`) para priorizar `sTypoAscender/Descender/LineGap`,
  - leitura de `xHeight/capHeight` quando `version >= 2`.
- TrueType `loca/glyf` (inspirado em `otglyf.cpp`):
  - leitura de `indexToLocFormat` do `head` e mapeamento de ranges de glifos via `loca` 16/32-bit,
  - extração de `glyph bounds` em unidades da fonte (bbox) com conversão de eixo Y para convenção raster top-down,
  - identificação estrutural de glifos compostos (`contourCount < 0`) para próxima etapa de outline decoder.
- TrueType `glyf` outlines (inspirado em `otglyf.cpp`):
  - decoder de glifo simples implementado (`flags`, expansão de `repeat`, deltas X/Y compactados e reconstrução de contornos),
  - conversão de pontos on/off-curve para `BLPath` com emissão de quadráticas implícitas em sequências off-curve,
  - suporte inicial a glifo composto (`compound`) com transformação afim (`scale`, `xy-scale`, `2x2`) e composição hierárquica com limite de profundidade,
  - suporte de tradução por componente para `ARGS_ARE_XY_VALUES` e proteção contra ciclos/recursão inválida em compostos.
- Cache de outlines:
  - cache por glifo em unidades da fonte dentro de `BLFontFace`,
  - cache de outline escalado por tamanho dentro de `BLFont` (reduz custo em texto repetido no mesmo size),
  - APIs adicionadas: `glyphOutlineUnits()`, `glyphOutline()`, `clearGlyphOutlineCache()`.
- Loader de fonte:
  - removido override indevido de `familyName` por nome de arquivo em `BLFontLoader`,
  - parser `name` passa a ser usado como fonte primária de nomenclatura quando `familyName` não é informado explicitamente.
- Raster AA:
  - corrigida a acumulação de cobertura para usar contribuição fracionária horizontal por pixel (A8),
  - ajuste de quantização para spans parciais com contribuição mínima de subpixel (reduzindo “gaps” em linha fina),
  - removido erro de análise em `bl_analytic_rasterizer.dart` (`return_without_value`) no caminho de AA.
- Composição (`pipeline/bl_compop_kernel.dart`):
  - `srcOver` ajustado para considerar corretamente alpha de destino (`dstA`) no caminho geral,
  - fast-path preservado para destino opaco (`dstA=255`) para manter custo baixo no bootstrap atual,
  - resultado final passa a preservar alpha de saída (em vez de fixar `0xFF` incondicionalmente) quando renderizando sobre destinos translúcidos.
- Fetchers/estilos (avanço de Fase 4 no port):
  - adicionada fundação de gradiente linear com tipos `BLGradientStop`/`BLLinearGradient` em `core/bl_types.dart`,
  - adicionada fundação de gradiente radial com tipo `BLRadialGradient` em `core/bl_types.dart`,
  - adicionada fundação de pattern com tipo `BLPattern` em `core/bl_types.dart`,
  - novo fetcher `pipeline/bl_fetch_linear_gradient.dart` com LUT de 256 amostras e interpolação de stops,
  - novo fetcher `pipeline/bl_fetch_radial_gradient.dart` com LUT de 256 amostras e resolução escalar por raiz quadrática (baseado na família de equações descrita em `pipeline/pipedefs.cpp`),
  - novo fetcher `pipeline/bl_fetch_pattern.dart` com amostragem nearest e suporte de extend por eixo (`pad/repeat/reflect`), alinhado ao modelo de contexto horizontal `Pad/Repeat/RoR` do Blend2D (`fetchgeneric_p.h`),
  - fetch radial atualizado com estabilização numérica de focal-point próximo à borda (estratégia inspirada em `init_radial_gradient` de `pipedefs.cpp`) e simplificação da equação no hot-loop,
  - correção de fidelidade visual no fetch radial: seleção da raiz da quadrática condicionada ao sinal de `a` (evita clamp indevido em `t=0` em cenários com `a<0`),
  - suporte inicial a `extendMode` em gradiente linear (`pad/repeat/reflect`) no fetcher, alinhando comportamento base de extensão com o modelo do Blend2D,
  - suporte inicial a `extendMode` (`pad/repeat/reflect`) também no fetch radial,
  - suporte inicial a pattern em `BLContext` via `setPattern(...)` e despacho para caminho fetched separado,
  - `BLContext` recebeu API `setLinearGradient(...)` e estado de estilo preparado para integração completa no resolve,
  - `BLContext` recebeu API `setRadialGradient(...)` e despacho para caminho fetched separado,
  - integração direta do gradiente no hot-path do raster foi testada nesta etapa, porém recuada no bootstrap por regressão de throughput,
  - caminho separado de resolve para fonte por pixel foi implementado em `bl_analytic_rasterizer.dart` (`drawPolygonFetched` + resolve fetched `nonZero/evenOdd`),
  - `BLContext.fillPolygon()` agora despacha gradiente linear para esse caminho separado, preservando o hot-path sólido principal sem branch extra no loop crítico.
  - fetch de pattern afim recebeu nova fatia de port inspirada em `FetchPatternAffineCtx` (`fetchgeneric_p.h`): avanço incremental por pixel em ponto fixo 24.8 (`fx/fy`), reduzindo recomputo de transformação no hot-loop em modos `nearest/bilinear` com transform afim.
- Raster analítico (upgrade de qualidade/robustez no bootstrap):
  - `bl_analytic_rasterizer.dart` migrou de AA simplificado por subamostragem vertical para acumulação analítica `cover/area` por célula com máscara ativa por scanline,
  - resolução de cobertura agora segue o modelo de prefix-sum de células (mesma família de abordagem do pipeline Batch Scalar), incluindo suporte correto a `evenOdd/nonZero`,
  - limpeza de buffers (`covers/areas/activeMask`) acoplada ao resolve para reduzir lixo residual entre draw-calls e eliminar artefatos visuais recorrentes em linhas finas/diagonais,
  - resolve otimizado por spans constantes entre eventos da `activeMask` (prefix-sum preservado), reduzindo trabalho em regiões sem células ativas,
  - fast-path opaco por run no resolve (`srcOver/srcCopy` com `srcA=255`) para escrita direta em spans de cobertura total,
  - rastreamento de min/max X por linha (`rowMinX/rowMaxX`), inspirado no uso de limites em `analyticrasterizer_p.h` (`kOptionRecordMinXMaxX`) para limitar a janela de resolve,
  - separação do resolve em dois hot-paths dedicados (`nonZero` e `evenOdd`) para remover branch de `fillRule` no loop interno, alinhado à estratégia de especialização do pipeline C++ (`fill_analytic` com `fillRule` definido por comando),
  - tentativa de especialização adicional por `compOp` (`srcOver/srcCopy`) foi avaliada e revertida no bootstrap atual por regressão de throughput; caminho estável mantido com branch local de comp-op,
  - tentativa de restringir limpeza da `activeMask` por faixa de words ativas (`minWord/maxWord` por linha), inspirada no padrão de limites do raster C++, foi avaliada e revertida no bootstrap atual por não mostrar ganho consistente no benchmark local.
- Harness do port (`blend2d_port_benchmark.dart`) alinhado ao benchmark principal:
  - cena sintética atualizada para 20 polígonos (paridade com benchmark principal),
  - inclusão da letra `A` (path fiel ao `assets/svg/a.svg`) para detectar regressões de winding/furos/contornos em cenários de texto vetorial,
  - benchmark dedicado de gradiente linear adicionado em `benchmark/blend2d_linear_gradient_benchmark.dart` (8 polígonos com gradientes lineares), com saída isolada em `output/rasterization_benchmark/BLEND2D_PORT_LINEAR_GRADIENT.png`.

Medição recente do benchmark do port (`benchmark/blend2d_port_benchmark.dart`, 512x512, 30 iterações):
- faixa observada no ambiente atual: ~`1.50ms` a `1.77ms` por frame (`~10k` a `12k poly/s`), com variação de execução a execução.
- última execução desta etapa: `1.665ms/frame` (`10809 poly/s`).
- após cobertura fracionária + kern: ~`1.823ms/frame` (`9875 poly/s`) no cenário sintético atual.
- após `name + OS/2` parser + ajuste de quantização AA em linha fina: faixa recente `2.05ms` a `2.14ms/frame` (`~8.4k` a `8.8k poly/s`) no cenário sintético atual.
- após base `loca/glyf` + limpeza do loader: execução recente na faixa `1.97ms` a `2.88ms/frame` (`~6.2k` a `9.1k poly/s`) com variabilidade de ambiente observada.
- após suporte `cmap` format 10 + fallback de símbolo: execução recente em `1.985ms/frame` (`9070 poly/s`).
- após migração do bootstrap para raster analítico `cover/area` com máscara ativa + cena sintética de 20 polígonos: `3.260ms/frame` (`6135 poly/s`) na execução local mais recente.
- após port do resolve por spans + fast-path opaco (inspirado no fluxo de limites/bit-scan do C++): execução recente em `1.938ms/frame` (`10321 poly/s`) e revalidação em `1.944ms/frame` (`10287 poly/s`).
- após separar o resolve por `fillRule` (`nonZero/evenOdd`) no hot-path: execução recente em `1.892ms/frame` (`10573 poly/s`).
- após tentativa de especialização por `compOp` e rollback para caminho estável: medições recentes em `2.021ms/frame` (`9897 poly/s`) e `1.929ms/frame` (`10370 poly/s`) no mesmo cenário sintético.
- após tentativa de limpeza parcial da `activeMask` por words ativas e rollback: medições recentes em `2.009ms/frame` (`9955 poly/s`), `2.015ms/frame` (`9927 poly/s`), `2.014ms/frame` (`9930 poly/s`) e `2.259ms/frame` (`8852 poly/s`), com variabilidade de ambiente elevada.
- após correção de `srcOver` (alpha de destino no caminho geral): medições recentes em `2.051ms/frame` (`9750 poly/s`) e `1.951ms/frame` (`10253 poly/s`) no cenário sintético atual.
- após fatia grande de fundação para gradiente linear + estabilização do hot-path sólido: medições recentes em `1.950ms/frame` (`10257 poly/s`) e `2.203ms/frame` (`9077 poly/s`), mantendo variabilidade de ambiente observada.
- após integração do gradiente linear via caminho separado de resolve (sem tocar o loop sólido principal): medições recentes em `2.314ms/frame` (`8644 poly/s`) e `2.140ms/frame` (`9348 poly/s`) no benchmark sintético atual.
- benchmark dedicado de gradiente linear (`blend2d_linear_gradient_benchmark.dart`, 512x512, 30 iterações, 8 polígonos): `2.473ms/frame` (`3235 poly/s`) na execução local recente.
- revalidação do baseline sólido após criação do benchmark dedicado: `1.976ms/frame` (`10119 poly/s`) em `blend2d_port_benchmark.dart`.
- após suporte de `extendMode` (`pad/repeat/reflect`) no gradiente linear e atualização da cena dedicada para cobrir `repeat/reflect`: `2.556ms/frame` (`3130 poly/s`) em `blend2d_linear_gradient_benchmark.dart`.
- revalidação do baseline sólido após essa etapa de extend-mode: `2.022ms/frame` (`9892 poly/s`) em `blend2d_port_benchmark.dart`.
- benchmark dedicado de gradiente radial (`blend2d_radial_gradient_benchmark.dart`, 512x512, 30 iterações, 8 polígonos): `3.499ms/frame` (`2286 poly/s`) na execução local recente.
- revalidação do baseline sólido após integração do gradiente radial em caminho separado: `2.125ms/frame` (`9411 poly/s`) em `blend2d_port_benchmark.dart`.
- após otimização/estabilização do fetch radial (focal-point + simplificação da solução quadrática): `2.503ms/frame` (`3196 poly/s`) em `blend2d_radial_gradient_benchmark.dart`.
- revalidação do baseline sólido após essa otimização radial: `2.102ms/frame` (`9514 poly/s`) em `blend2d_port_benchmark.dart`.
- após correção de render no radial (escolha de raiz por sinal de `a`) e regeneração das imagens de conferência: `3.224ms/frame` (`2481 poly/s`) em `blend2d_radial_gradient_benchmark.dart`.
- benchmark dedicado linear reexecutado na mesma rodada de conferência visual: `2.837ms/frame` (`2820 poly/s`) em `blend2d_linear_gradient_benchmark.dart`.
- revalidação do baseline sólido após essa correção de fidelidade radial: `2.062ms/frame` (`9702 poly/s`) em `blend2d_port_benchmark.dart`.
- benchmark dedicado de pattern nearest (`blend2d_pattern_benchmark.dart`, 512x512, 30 iterações, 8 polígonos): `1.598ms/frame` (`5006 poly/s`) na execução local recente.
- revalidação do baseline sólido após integração de pattern em caminho separado: `2.044ms/frame` (`9786 poly/s`) em `blend2d_port_benchmark.dart`.
- benchmark dedicado de pattern affine + bilinear (`blend2d_pattern_affine_bilinear_benchmark.dart`, 512x512, 30 iterações, 8 polígonos): `4.921ms/frame` (`1626 poly/s`) na primeira execução da fatia grande.
- após fast-path nearest inteiro (identity + offsets integrais) no fetch de pattern: `1.669ms/frame` (`4792 poly/s`) em `blend2d_pattern_benchmark.dart`.
- revalidação do baseline sólido após o fast-path nearest: `1.765ms/frame` (`11332 poly/s`) em `blend2d_port_benchmark.dart`.
- revalidação recente do benchmark affine + bilinear na mesma etapa: `5.001ms/frame` (`1600 poly/s`) em `blend2d_pattern_affine_bilinear_benchmark.dart`.
- após otimização incremental no fetch de pattern affine/bilinear (reuso de coordenadas afins entre pixels consecutivos + clamp inteiro mais leve de frações): `2.736ms/frame` (`2924 poly/s`) em `blend2d_pattern_affine_bilinear_benchmark.dart`.
- revalidação do pattern nearest na mesma rodada de otimização: `1.720ms/frame` (`4651 poly/s`) em `blend2d_pattern_benchmark.dart`.
- revalidação do baseline sólido na mesma rodada de otimização: `1.870ms/frame` (`10697 poly/s`) em `blend2d_port_benchmark.dart`.
- rodada de estabilidade (10 execuções) do pattern affine + bilinear antes de decisão de reversão: média `2.857ms/frame` (faixa `2.772..3.150ms`) e `2804 poly/s` (faixa `2539..2886`).
- rodada de estabilidade (10 execuções) do pattern nearest na mesma etapa: média `1.983ms/frame` (faixa `1.608..3.043ms`) e `4262 poly/s` (faixa `2629..4974`).
- rodada de estabilidade (10 execuções) do baseline sólido em shell isolado: média `2.453ms/frame` (faixa `2.238..2.671ms`) e `8178 poly/s` (faixa `7487..8937`).
- nova fatia grande (affine fixed-point 24.8 no fetch de pattern, inspirada em `FetchPatternAffineCtx`) validada com análise limpa e conferência visual da saída `BLEND2D_PORT_PATTERN_AFFINE_BILINEAR.png`.
- rodada de estabilidade (10 execuções) do affine+bilinear após essa fatia: média `2.680ms/frame` (faixa `2.552..2.928ms`) e `2992 poly/s` (faixa `2732..3134`) em `blend2d_pattern_affine_bilinear_benchmark.dart`.
- rodada de estabilidade sequencial (10 execuções) do pattern nearest após essa fatia: média `1.790ms/frame` (faixa `1.691..2.213ms`) e `4493 poly/s` (faixa `3614..4731`) em `blend2d_pattern_benchmark.dart`.
- rodada de estabilidade sequencial (10 execuções) do baseline sólido após essa fatia: média `2.036ms/frame` (faixa `1.844..2.596ms`) e `9924 poly/s` (faixa `7705..10848`) em `blend2d_port_benchmark.dart`.
- experimento C++-guided adicional: kernel bilinear em duas etapas (lerp `Fx/Fy`), visando reduzir multiplicações por pixel.
- validação 10x do lerp kernel no affine+bilinear indicou regressão, com média `2.928ms/frame` (faixa `2.724..3.511`) e `2745 poly/s` (faixa `2279..2937`); alteração revertida.
- experimento adicional de fast-path `reflect/reflect` (nearest+bicúbico/bilinear) também apresentou regressão nas rodadas 10x do affine+bilinear (run1 média `3.338ms/frame`, run2 média `3.233ms/frame`); alteração revertida para manter caminho estável.
- experimento adicional de especialização bilinear por combinações mistas de `extendMode` (`repeat/pad/reflect` em pares X/Y), guiado pela ideia de dispatch por contexto do `fetchgeneric_p.h`.
- validação 10x dessa especialização mista no affine+bilinear também indicou regressão, com média `2.926ms/frame` (faixa `2.676..3.454`) e `2747 poly/s` (faixa `2316..2990`); alteração revertida.
- nova tentativa C++-guided: port parcial do avanço incremental estilo `advance_x` para caso afim `repeat/repeat` (coordenada normalizada em fixed-point e correção por faixa, reduzindo `%` no caminho sequencial).
- validação inicial 10x dessa tentativa mostrou resultado inconsistente e sem ganho sustentado no conjunto atual (referência da rodada: affine+bilinear média `2.708ms/frame`, faixa `2.605..2.887`, `2958 poly/s`), com variabilidade elevada em reamostragens subsequentes.
- decisão: rollback da tentativa `advance_x repeat/repeat` e retorno ao caminho estável anterior.
- revalidação sequencial pós-rollback: `2.625ms/frame` (`3047 poly/s`) em `blend2d_pattern_affine_bilinear_benchmark.dart`, `1.834ms/frame` (`4361 poly/s`) em `blend2d_pattern_benchmark.dart` e `1.945ms/frame` (`10283 poly/s`) em `blend2d_port_benchmark.dart`.
- rodada formal 10x (pós-estabilização dos testes, protocolo consolidado):
  - baseline sólido `blend2d_port_benchmark.dart`: média `1.900ms/frame` (faixa `1.699..2.166ms`) e `10568 poly/s` (faixa `9234..11775`),
  - pattern nearest `blend2d_pattern_benchmark.dart`: média `1.850ms/frame` (faixa `1.681..2.309ms`) e `4354 poly/s` (faixa `3465..4760`),
  - pattern affine + bilinear `blend2d_pattern_affine_bilinear_benchmark.dart`: média `4.796ms/frame` (faixa `3.210..12.835ms`) e `1973 poly/s` (faixa `623..2492`), com outlier visível na cauda superior da faixa.
- estado mantido ao final da rodada: fatia `affine fixed-point 24.8` preservada; experimentos `lerp kernel`, `reflect/reflect` dedicado, especialização mista de `extendMode` e tentativa `advance_x repeat/repeat` descartados por throughput inferior ou instabilidade no protocolo de validação.
- atualização incremental desta sessão (pós-push):
  - consolidado o port afim de pattern com normalização por período em ponto fixo e correção robusta de índices em `repeat/reflect` no fetch bilinear (`_indexFromNorm` com `%` para coordenadas grandes), eliminando `RangeError` em testes de boundary/wrap,
  - suíte de testes Blend2D adicionada e estabilizada (`path/stroker/pattern/context/gradient`), com validação local recente em `dart test`: `71 passed, 0 failed`,
  - testes de gradiente radial alinhados ao contrato atual de `BLRadialGradient` (`r0/r1` explícitos), reduzindo falso-negativo por uso de default `r1=0`,
  - testes de composição/contexto ajustados para o comportamento atual do resolve analítico em `srcCopy` com cobertura fracionária (fallback efetivo para composição tipo `srcOver` quando `effA < 255`),
  - paridade de caps do stroker corrigida nesta sessão (ver abaixo).
- Stroker robusto (Fase 5, port de `pathstroke.cpp`):
  - novo arquivo `geometry/bl_stroker.dart` com `BLStroker.strokePath(BLPath, BLStrokeOptions) -> BLPath`,
  - enums `BLStrokeCap` (butt/square/round/roundRev/triangle/triangleRev) e `BLStrokeJoin` (bevel/miterClip/miterBevel/miterRound/round) adicionados em `core/bl_types.dart`,
  - classe `BLStrokeOptions` com `width`, `miterLimit`, `startCap`, `endCap`, `join`, `flattenTolerance` e `copyWith()`,
  - `BLPath` atualizado para rastrear `contourClosed` (flag por contorno via `close()`), exposto em `BLPathData.contourClosed`,
  - `BLPath._finishContour` agora aceita contornos de 2+ vértices (linhas abertas para stroke), sem impacto no fill (que continua exigindo >= 3),
  - stroker opera sobre vértices já aplainados (BLPath já flatten curvas via De Casteljau),
  - offset de segmentos por halfWidth com normal esquerda/direita,
  - cálculo de miter intersection por bissetriz normalizada (`k = (np + nn) * hw / |np + nn|^2`),
  - joins externos com bevel, miter (com limit), round (arco subdivido a ~45° por passo),
  - joins internos via intersecção simples,
  - caps de extremidade: butt (flat), square (extendido por hw), round (arco semicircular 180° subdivido via atan2), triangle, triangleRev, roundRev,
  - contornos fechados geram dois polígonos (A + B_reversed com winding oposto para nonZero),
  - contornos abertos geram um polígono fechado (A → end_cap → B_reversed → start_cap),
  - API `BLContext.strokePath(BLPath, {color, options})` e `strokePolygon(...)` adicionadas,
  - `BLContext.setStrokeOptions()` e `setStrokeWidth()` para configurar estado de stroke no contexto,
  - barrel export atualizado em `blend2d.dart`,
  - teste funcional em `benchmark/stroke_test.dart` com 6 cenários (ret+tri+poly+star+curva+círculo), validado com 9402 pixels de stroke em 512x512,
  - `dart analyze` limpo, baseline sólido sem regressão.
- Paridade geométrica de caps (port fiel de `add_cap()` de `pathstroke.cpp`):
  - `_addCapToPath` reescrito para calcular `q = normal(p1 - p0) * 0.5` (exatamente como no C++),
  - eliminados parâmetros `segNx/segNy` da função (q agora é auto-contido),
  - `square cap` agora estende FORWARD por hw além dos endpoints (bug de direção corrigido),
  - `triangle cap` agora estende a ponta para `pivot + q` (antes colapsava no pivot),
  - `round cap` simplificado para usar `pivot + q` como waypoint do arco,
  - `roundRev cap` reescrito com arcos de recuo via `_addArcPoints`,
  - `_addRoundCapToPath` simplificado para receber `qx/qy` em vez de `segNx/segNy`,
  - 3 novos testes dedicados de paridade geométrica:
    - `square cap extends FORWARD by hw beyond endpoints` (horizontal),
    - `triangle cap tip extends beyond pivot` (horizontal),
    - `square cap on diagonal line extends symmetrically` (45°),
  - rodada 10x do baseline sólido pós-paridade: média `1.921ms/frame` (faixa `1.785..2.359ms`) e `10478 poly/s`.
- Expansão de composição (Fase 3 → concluída, port de `compop_p.h`/`compopgeneric_p.h`):
  - `BLCompOp` expandido de 2 para 28 operadores (alinhado com `context.h`):
    - Porter-Duff: srcOver, srcCopy, srcIn, srcOut, srcAtop, dstOver, dstCopy, dstIn, dstOut, dstAtop, xor, clear,
    - Aditivos/subtrativos: plus, minus, modulate,
    - Separáveis avançados: multiply, screen, overlay, darken, lighten, colorDodge, colorBurn, linearBurn, linearLight, pinLight, hardLight, softLight, difference, exclusion,
  - cada modo implementado com a fórmula separável `B(Dc,Sc) + Sca.(1-Da) + Dca.(1-Sa)` (SVG/PDF spec),
  - `BLCompOpKernel.compose()` dispatch centralizado para todos os 28 modos,
  - fast-path `srcOver` preservado com caminho otimizado para destino opaco,
  - testes verificam que todos os 28 ops produzem pixels válidos (sem crash/out-of-range).
- Módulo `pixelops/` (port de `pixelops/scalar_p.h`):
  - `udiv255()` — divisão por 255 com arredondamento correto (`((x + 128) * 257) >> 16`),
  - `premultiply()` — ARGB straight → PRGB (port fiel do escalar C++, incluindo `val32 |= 0xFF000000`),
  - `unpremultiply()` — PRGB → ARGB straight (com tabela de recíprocos, port de `unpremultiply_rgb_8bit`),
  - `alphaOf/redOf/greenOf/blueOf/packArgb` — extração e empacotamento de canais,
  - `swizzleArgbToAbgr/swizzleArgbToRgba/swizzleRgbaToArgb` — conversão de byte-order,
  - `srgbToLinear/linearToSrgb` — conversão aproximada de espaço de cor para ops futuros,
  - `neg255/clamp255/addus8` — utilitários escalares.
- Expansão do Context API (inspirado em `context.h`/`context.cpp`):
  - `save()/restore()` — pilha de estado completa (compOp, fillRule, estilo, stroke, alpha, clip, transform),
  - `setGlobalAlpha()` — transparência global [0.0..1.0],
  - `setClipRect()/clipToRect()/resetClip()` — recorte retangular com interseção,
  - `setTransform()/getTransform()/resetTransform()` — transformação afim completa (`BLMatrix2D`),
  - `translate()/scale()/rotate()` — atalhos de transformação incremental,
  - `transformPoint()` / `isTransformIdentity` — consulta de transformação,
  - `fillRect()/strokeRect()` — APIs de conveniência para retângulos,
  - pipeline de transformação de vértices integrado no `fillPolygon()`,
  - getter público `clipRect` para introspecção/testes.

Medição recente do benchmark do port (`benchmark/blend2d_port_benchmark.dart`, 512x512, 30 iterações):
- rodada formal 10x pós-expansão comp-ops/pixelops/context: média `1.847ms/frame` (faixa `1.714..1.983ms`) e `10841 poly/s` (faixa `10083..11669`).
- rodada formal 10x pós-integração comp-ops no resolve + text API + CFF: média `1.900ms/frame` (excl. outlier, faixa `1.800..2.102ms`) e `10482 poly/s` (excl. outlier), sem regressão.
- `dart test`: 102 testes passando (0 falhas), `dart analyze`: 0 issues.
- visual stroke test: 9402 non-white pixels (consistente).
- Integração comp-ops no rasterizador:
  - Os 28 comp-ops do `BLCompOpKernel` agora estão conectados end-to-end no resolve de cobertura (`_resolveMaskedCoverage*`).
  - Anteriormente, o resolve usava `BLCompOpKernel.srcOver()` fixo mesmo quando outro comp-op era selecionado.
  - Agora, `BLCompOpKernel.compose(compOp, dst, src)` é chamado para todos os modos não-fast-path.
  - Fast-path opaco preservado para `srcOver/srcCopy` com cobertura total e alpha=255.
  - Teste `srcCopy` corrigido para refletir o comportamento correto (source replace, não fallback para srcOver).
- Text API (port de Fase 11, inspirado em `context.h` `fillText`/`strokeText`):
  - `BLContext.fillText(String, BLFont, {x, y, color})` — shape + render all glyphs filled.
  - `BLContext.strokeText(String, BLFont, {x, y, color, options})` — shape + render all glyphs stroked.
  - `BLContext.fillGlyphRun(BLGlyphRun, BLFont, {color})` — render pre-shaped glyph run filled.
  - `BLContext.strokeGlyphRun(BLGlyphRun, BLFont, {color, options})` — render pre-shaped glyph run stroked.
  - Cada glifo é traduzido para sua posição de placement e renderizado via `fillPolygon`/`strokePath` existentes.
- CFF/Type2 charstring decoder (port de `otcff.cpp`):
  - Novo arquivo `text/bl_cff.dart` com `BLCFFDecoder.decodeGlyph()`.
  - Parser de CFF INDEX v1 (`_CFFIndex.parse()`) com suporte a offset sizes 1-4.
  - Interpretador de charstrings Type 2 com todos os operadores de outline:
    - `rmoveto/hmoveto/vmoveto`, `rlineto/hlineto/vlineto`,
    - `rrcurveto/hhcurveto/vvcurveto/hvcurveto/vhcurveto`,
    - `rcurveline/rlinecurve`,
    - `hflex/flex/hflex1/flex1` (escape operators),
    - `hstem/vstem/hstemhm/vstemhm/hintmask/cntrmask` (hints — consumidos, não afetam outline),
    - `endchar`.
  - Parser de TopDict para localizar offset do CharStrings INDEX.
  - `BLFontFace` atualizado:
    - Novos campos: `hasCFFOutlines`, `cffOffset`, `cffLength`.
    - `glyphOutlineUnits()` agora faz fallback para CFF quando TrueType outlines não existem.
    - `parse()` detecta a tabela `'CFF '` e preenche os campos CFF.
  - Barril export atualizado com `text/bl_cff.dart`.
- Sessão acelerada 3 (CFF subrs + dasher + drawImage + circle + GSUB/GPOS + glyph cache):
  - rodada formal 10x pós-sessão: média `1.884ms/frame` (faixa `1.752..2.059ms`) e `10641 poly/s` — zero regressão.
  - `dart test`: 115 testes passando (0 falhas), `dart analyze`: 0 issues.
  - CFF Subroutines (`callsubr`/`callgsubr`/`return`):
    - Operadores Type 2 `callsubr` (op 10), `callgsubr` (op 29), `return` (op 11) implementados.
    - Bias calculado por spec CFF (107/1131/32768).
    - Call stack com profundidade máxima 10.
    - Parser de Private DICT (op 18) e local subr offset (op 19).
    - GSubR INDEX parsing no fluxo principal de `decodeGlyph`.
  - Dash Pattern (`BLDasher`):
    - Novo `geometry/bl_dasher.dart` — converte path sólido em path tracejado.
    - Suporte a padrões arbitrários e dash offset.
    - `BLContext.strokeDashedPath()` integrado.
  - globalAlpha integrado no pipeline:
    - `globalAlpha` agora modula o canal alpha da cor sólida em `fillPolygon()`.
  - clipRect integrado no pipeline:
    - Clip rect faz rejeição por bounding-box em `fillPolygon()`.
    - Também aplicado em `drawImage()`.
  - drawImage:
    - `BLContext.drawImage(BLImage, {dx, dy})` — composição pixel-a-pixel.
    - Usa `BLCompOpKernel.compose()` para todos os 28 modos.
    - Respeita globalAlpha e clipRect.
  - Geometry convenience APIs:
    - `fillCircle/strokeCircle/fillEllipse/strokeEllipse` via Bézier 4-quadrante (k ≈ 0.5522847498).
  - **GSUB/GPOS Layout Engine** (port de `otlayout.cpp`/`otlayouttables_p.h`):
    - Novo `text/bl_opentype_layout.dart` com `BLLayoutEngine`.
    - **GSUB Type 1** (SingleSubst): formatos 1 (delta) e 2 (array), com CoverageTable (formats 1+2, binary search).
    - **GSUB Type 4** (LigatureSubst): formato 1 com matching de componentes.
    - **GPOS Type 2** (PairAdjustment): formato 1 com PairSets e ValueRecords.
    - CoverageTable parser completo (format 1 = sorted glyphs, format 2 = ranges).
    - ValueRecord reader para flags `xPlacement/yPlacement/xAdvance/yAdvance`.
    - Extension lookup resolution (GSUB type 7, GPOS type 9).
    - Feature list parser com coleta de lookup indices por feature tags.
    - `applyGSUB(glyphIds, {features})` — substitui glifos via features (liga/clig/rlig).
    - `applyGPOS(glyphIds, {features})` — retorna x-advance adjustments via features (kern).
    - `BLFontFace` atualizado:
      - Novos campos: `gsubOffset/gsubLength/gposOffset/gposLength`.
      - Lazy-initialized `layoutEngine` getter para acesso ao `BLLayoutEngine`.
      - `parse()` detecta tabelas `'GSUB'` e `'GPOS'`.
  - **Glyph Cache** (`text/bl_glyph_cache.dart`):
    - `BLGlyphCache` com LRU eviction.
    - Keyed por `(fontFaceId, glyphId, fontSize*64)`.
    - Limites configuráveis de entries (default 4096) e memória (default 16MB).
    - `BLGlyphCacheEntry` com bitmap A8, bearings, dimensões.
    - Hit-rate tracking e cache statistics.
    - `evictFont()` para eviction per-font.
  - Barril export atualizado com `bl_opentype_layout.dart` e `bl_glyph_cache.dart`.
- Sessão acelerada 4 (GPOS F2 + Path geometry + glyph rasterizer + measureText + roundRect):
  - rodada formal 10x pós-sessão: média `1.905ms/frame` (faixa `1.806..2.139ms`) e `10532 poly/s` — zero regressão.
  - `dart test`: 127 testes passando (0 falhas), `dart analyze`: 0 issues.
  - **GPOS PairAdjustment Format 2** (ClassDef-based):
    - `_classDefLookup()` parser para ClassDefTable format 1 (array) e format 2 (ranges, binary search).
    - Integrado em `_applyPairAdjustment()` para resolver class pairs e ler value records da class matrix.
    - Suporta a maioria das fontes modernas que usam ClassDef para kerning.
  - **BLPath convenience geometry**:
    - `addArc()` — arco circular via subdivisão em segmentos Bézier cúbicos.
    - `addEllipticArc()` — arco elíptico com rx/ry independentes.
    - `addRect()` — retângulo como contorno fechado.
    - `addRoundRect()` — retângulo arredondado com cantos cúbicos (Bézier k=0.5522847498).
    - `addPath()` — append de outro BLPath (multi-contorno).
  - **BLContext convenience APIs**:
    - `fillRoundRect()` / `strokeRoundRect()` usando `BLPath.addRoundRect()`.
  - **measureText()** (`BLTextLayout`):
    - `BLTextMetrics` com width, height, glyphCount.
    - Calcula largura total via last glyph position + advance.
    - Altura baseada em `(ascender - descender) * scale`.
  - **Glyph Rasterizer** (`text/bl_glyph_rasterizer.dart`):
    - `BLGlyphRasterizer` usando pipeline analítico existente.
    - Renderiza glyph outline em bitmap A8: clear→drawPolygon→extract alpha.
    - `rasterizeAndCache()` — rasteriza e armazena no `BLGlyphCache`.
    - `BLAnalyticRasterizer.pixelBuffer` getter exposto para acesso ao buffer.
  - **BLTextLayout integrado com GSUB/GPOS**:
    - `shapeSimple()` agora aplica GSUB→GPOS automaticamente.
    - GSUB features configuráveis, fallback para legacy kern quando sem GPOS.
    - `BLFont.scaleValue()` para converter font units → pixels.
  - Barril export atualizado com `bl_glyph_rasterizer.dart`.
  - Licença MIT adicionada em `LICENSE`.
- Sessão acelerada 5 (OpenType Extra Lookups + Conic Gradients):
  - `dart test`: 127 testes passando (0 falhas).
  - **OpenType GSUB/GPOS Extensions** (`bl_opentype_layout.dart`):
    - `GSUB Type 2 (Multiple Substitution)`: Resolvido mapeamento de 1 glifo para N glifos (útil para expandir ligaduras invertidas).
    - `GSUB Type 3 (Alternate Substitution)`: Escolha da primeira alternativa para substituição (bootstrap).
    - `GPOS Type 1 (Single Adjustment)`: Posicionamentos precisos individuais e ajustes de advance via formats 1 & 2.
    - Loop central refatorado em `applyGSUB` e `applyGPOS` para processamento inline escalável.
  - **Gradientes** (`bl_types.dart`, `bl_fetch_conic_gradient.dart`, `bl_context.dart`):
    - Implementação de `BLConicGradient` e `BLConicGradientFetcher`.
    - Lógica de lookup em LUT (Look-Up Table) de 256 cores baseada no ângulo polar (`atan2`).
    - Integração no `BLContext` com `setConicGradient` e branch em `fillPolygon`.
  - Com isso, temos toda a especificação base de fill styles preenchida (Solid, Linear, Radial, Conic, Pattern).
- Sessão acelerada 6 (Bidi Segmentation + Multi-line Layout & Metrics):
  - `dart test`: 127 testes passando.
  - **Script/Bidi Segmentation (Fase 9 bootstrap)** (`text/bl_bidi.dart`):
    - `BLBidiAnalyzer` implementado para segmentar a string em run levels baseados no Unicode block approach (resolvendo Hebraico/Árabe como RTL).
    - `BLTextDirection` enum (LTR vs RTL) e `BLTextRun`.
  - **Multi-line & RTL Text Layout** (`text/bl_text_layout.dart`):
    - `shapeText` reescrito para fragmentar texto por quebras de linha (`\n`) e rodar Bidi em cada linha.
    - Lógica de posicionamento RTL preenche run da direita pra esquerda visualmente (subtraindo advances do cursor).
  - **Text Metrics Expansion** (`BLTextMetrics`):
    - Bounding Box preciso (`boundingBoxX`, `boundingBoxY`) incluso em adição ao `width`/`height` semânticos.
    - Captura o escopo de múltiplos *lines* e ascenders/descenders dinâmicos por run.

## 1) Princípios de engenharia (não negociáveis)

1. Correção antes de micro-otimização.
2. No hot-path: zero alocação por frame.
3. Dados em SoA (`Int32List`, `Uint32List`, `Float64List`) e loops planos.
4. Pipeline previsível: `build edges -> raster cells -> resolve coverage -> comp op`.
5. Sempre benchmarkar contra baseline interno (Marlin + Blend2D_v2 atual).
6. Toda feature nova entra com teste visual + teste numérico.

## 2) Escopo do “port completo”

Blend2D completo é grande. Para viabilizar em Dart com performance:

Escopo faseado:
1. Núcleo Raster + Composição (equivalente ao coração do Blend2D para shapes 2D).
2. Fetchers essenciais: cor sólida, gradiente linear/radial, pattern simples.
3. Context API equivalente (subset amplo e estável).
4. Stroke/path robustos.
5. Texto completo em puro Dart (fontes, shaping, glyph cache, render).
6. Paralelismo e batch avançado.
7. Recursos secundários (codecs/imagens avançadas) em trilha separada.

## 3) Mapeamento de módulos (C++ -> Dart)

Referência C++:
- `blend2d/core/*`
- `blend2d/geometry/*`
- `blend2d/raster/*`
- `blend2d/pipeline/*`
- `blend2d/opentype/*`
- `blend2d/unicode/*`
- `blend2d/tables/*`
- `blend2d/threading/*`
- `blend2d/pixelops/*`

Estrutura recomendada em Dart:
- `lib/src/blend2d/core/`
  - tipos base (`B2DColor`, `B2DRect`, `B2DMatrix`, enums)
  - runtime/config/capabilities
- `lib/src/blend2d/geometry/`
  - path, flatten, bbox, stroker
- `lib/src/blend2d/raster/`
  - edge builder, cell accumulation, analytic rasterizer, tile scheduler
- `lib/src/blend2d/pipeline/`
  - comp-op kernels, fetchers, span runners
- `lib/src/blend2d/text/`
  - parsing OpenType/TrueType, cmap, glyf/cff (escopo incremental)
  - shaping (GSUB/GPOS subset prioritário), bidi e segmentação
  - glyph cache, atlas/tiles, raster de glyph (gray/lcd opcional)
- `lib/src/blend2d/unicode/`
  - normalização mínima, bidi runs, quebra de linha e script runs
- `lib/src/blend2d/tables/`
  - tabelas compactas para classificar scripts, bidi e lookup rápido
- `lib/src/blend2d/threading/`
  - isolate pool persistente, filas de job, sync
- `lib/src/blend2d/pixelops/`
  - convert, premultiply, swizzle
- `lib/src/blend2d/context/`
  - API de alto nível (`fillPath`, `strokePath`, `setCompOp`, etc.)

## 4) Ordem de implementação (fases executáveis)

## Fase 0 - Baseline e harness (1-2 dias)

Entregáveis:
- Benchmark dedicado: `benchmark/blend2d_port_benchmark.dart`
- Corpus visual fixo:
  - `assets/svg/froggy-simple.svg`
  - `assets/svg/Ghostscript_Tiger.svg`
  - cena sintética com:
    - furos (anel/retângulo vazado/A com buraco)
    - linha fina
    - arcos
    - sobreposição com mesma cor (detectar cancelamentos indevidos)
- Métricas:
  - `ms/frame`
  - `polygons/s`
  - diferença de imagem (pixel mismatch + heatmap)

Critério de saída:
- baseline reproduzível e automatizado.

## Fase 1 - Núcleo de dados e API mínima (3-5 dias)

Entregáveis:
- `B2DImage` (ARGB32), `B2DContext` mínimo
- `drawPolygon(vertices, color, windingRule, contourVertexCounts)`
- fill rules corretas (`EvenOdd`, `NonZero`)
- compatibilidade com `PolygonContract` existente

Critério de saída:
- Sem regressão nos testes de furos/contornos.

## Fase 2 - Raster analítico de células (1-2 semanas)

Entregáveis:
- `EdgeBuilder` com clipping robusto
- buffers `covers` e `areas` por tile
- resolve escalar determinístico (sem branch excessivo)
- correção de casos degenerados:
  - horizontal/vertical extrema
  - micro-segmentos
  - self-overlap simples

Critério de saída:
- Qualidade equivalente ao pipeline Blend2D atual do projeto, sem artefatos de “linha fantasma”.

## Fase 3 - Pipeline de composição (1 semana) ✅ CONCLUÍDA

Entregáveis:
- ✅ kernels de comp-op em Dart:
  - ✅ `SrcCopy`, `SrcOver` (prioridade)
  - ✅ Todos os 28 operadores de composição do Blend2D C++ implementados
  - ✅ Módulo `pixelops/bl_pixelops.dart` com premultiply/unpremultiply/udiv255
- ✅ caminho premultiplied consistente
- ✅ clamp/saturate sem custo desnecessário

Critério de saída:
- ✅ Render final idêntico (ou erro mínimo) nos casos sólidos e alpha.

## Fase 4 - Fetchers e estilos (1-2 semanas)

Entregáveis:
- fetcher sólido (já no caminho principal)
- gradiente linear + radial
- pattern básico (nearest/bilinear inicial)
- cache de estado por draw-call (evitar recomputo)

Critério de saída:
- SVGs com gradientes principais renderizando sem fallback para outros rasterizadores.

## Fase 5 - Stroke/path robusto (1-2 semanas) ✅ CONCLUÍDA

Entregáveis:
- ✅ stroker (miter/round/bevel, cap butt/round/square/roundRev/triangle/triangleRev)
- ✅ flatten adaptativo de curvas (De Casteljau)
- ✅ tratamento robusto de joins e caps em subpixel
- ✅ paridade geométrica fina com C++ Blend2D (`q = normal(p1-p0)*0.5`)

Critério de saída:
- ✅ linhas finas e contornos equivalentes ao Marlin/AMCAD visualmente.

## Fase 6 - Paralelismo real (1 semana)

Entregáveis:
- isolate pool persistente por tiles sujos
- scheduler por custo estimado de tile (não só altura fixa)
- merge/composite final sem cópias extras

Critério de saída:
- ganho consistente em cenas grandes (`Tiger`) sem degradar cenas pequenas (`Froggy`).

## Fase 7 - Otimização agressiva (contínua)

Checklist:
- remover bounds checks redundantes via organização de loop
- reduzir branches no resolve
- compactar estado quente em arrays contíguos
- pré-cálculo de spans e run-length de cobertura
- “dirty rectangles” por comando
- fast-path opaco para `SrcCopy/SrcOver`

Critério de saída:
- alvo inicial: superar `Marlin` em throughput no benchmark sintético sem perder qualidade visual.

## Fase 8 - Fontes e OpenType em puro Dart (1-2 semanas)

Entregáveis:
- Loader de fonte (`.ttf`, `.otf`, `.ttc`) em memória.
- Parser de tabelas essenciais:
  - `head`, `hhea`, `maxp`, `hmtx`, `cmap`, `name`, `OS/2`
- Parser de outlines:
  - prioridade `glyf` (TrueType)
  - `cff/cff2` em trilha subsequente
- Métricas tipográficas: ascent/descent/lineGap/xHeight/capHeight quando disponível.

Critério de saída:
- carregar fontes reais e mapear código Unicode -> glyph ID corretamente.

## Fase 9 - Shaping e layout de texto (1-2 semanas) — PARCIALMENTE CONCLUÍDA

Entregáveis:
- Pipeline de shaping em Dart:
  - segmentação por script/língua
  - bidi por runs
  - ✅ aplicação incremental de `GSUB/GPOS` (subset inicial — SingleSubst + LigatureSubst + PairAdjustment)
- ✅ Kerning e advance positioning corretos (via GPOS PairAdjustment format 1 + legacy kern).
- API mínima:
  - `shapeText(String text, TextStyle style) -> GlyphRun`
  - `measureText(...)`

Critério de saída:
- palavras latinas e casos com ligaduras/kerning renderizando com posicionamento estável.

## Fase 10 - Rasterização de glyphs e cache (1-2 semanas) — PARCIALMENTE CONCLUÍDA

Entregáveis:
- Raster de glyph por cobertura (grayscale AA) em puro Dart.
- ✅ Cache de glyph por chave:
  - `(fontFaceId, glyphId, fontSize*64)`
- ✅ Atlas de glyphs com LRU eviction e limites configuráveis (entries + memória).
- Composição de glyph no mesmo pipeline de spans/composition.

Critério de saída:
- texto com AA consistente sem custo explosivo por frame.

## Fase 11 - API gráfica de texto + ponte para PDF (1 semana)

Entregáveis:
- API de contexto:
  - `setFont(...)`, `fillText(...)`, `strokeText(...)`, `drawGlyphRun(...)`
- Estruturas para PDF futuro:
  - `GlyphRun` serializável
  - mapeamento de fonte/subset ID
  - coleta de glyphs usados por página
- Modo dual:
  - render direto em bitmap
  - exportar comandos de texto para backend PDF futuro

Critério de saída:
- mesma cena pode ser renderizada em bitmap e também gerar dados prontos para writer PDF.

## 5) Estratégia de performance para Dart (específica)

1. Tipos:
- usar `int` em ponto fixo no raster/resolve.
- evitar `double` no hot loop (permitido só em pré-processamento).

2. Memória:
- buffers fixos reciclados.
- nada de `List<dynamic>` no núcleo.
- evitar `sublist` que aloca; usar views ou índices.

3. Branching:
- separar loops por `fillRule` (dois caminhos específicos).
- separar comp-op opaco vs alpha.

4. SIMD:
- tratar SIMD em Dart como opcional e medido, nunca presumido.
- manter fallback escalar como caminho canônico.

5. Isolates:
- pool persistente.
- chunking por tile sujo e custo real.
- minimizar serialização (mensagens pequenas + dados já particionados).

6. Texto:
- cache agressivo de glyph + métricas.
- evitar re-shaping quando texto/style/font não mudam.
- separar pipeline `shape` (CPU pesado, reusável) de `paint` (hot-path por frame).

## 6) Qualidade e validação

Testes obrigatórios por fase:
1. Furos:
- anel, retângulo vazado, letra A com buraco.
2. Sobreposição:
- triângulo sobre quadrado de mesma cor (não pode “abrir furo”).
3. Linha fina:
- diagonal subpixel longa.
4. Curvas:
- arco fino e bezier.
5. SVG real:
- `froggy-simple.svg`
- `Ghostscript_Tiger.svg`
6. Texto:
- Latin básico, acentos, kerning, ligaduras.
- bidi básico (LTR/RTL em mesma linha).
- tamanhos pequenos (8-12px) para detectar perda de hint/legibilidade.

Métrica visual:
- diff vs referência (Marlin/AMCAD) com tolerância definida por caso.

## 7) Roadmap de entregas (marcos)

Marco M1:
- Fase 0 + Fase 1 concluídas.
- API mínima funcional em `lib/src/blend2d`.

Marco M2:
- Fase 2 + Fase 3 concluídas.
- Raster sólido com composições básicas e sem artefatos graves.

Marco M3:
- Fase 4 + Fase 5 concluídas.
- estilos (gradiente/pattern) + stroke robusto.

Marco M4:
- Fase 6 + Fase 8 concluídas.
- paralelismo + fundação OpenType em puro Dart.

Marco M5:
- Fase 9 + Fase 10 concluídas.
- shaping + raster/cache de texto prontos para produção.

Marco M6:
- Fase 11 + otimizações finais.
- ganho real de throughput em cenas grandes.
- API gráfica completa (shape + text) e base pronta para backend PDF.

## 8) Plano de arquivos (bootstrap imediato)

Criar (ou preencher) em `lib/src/blend2d`:
- ✅ `context/bl_context.dart` — save/restore, clip rect, transform, fillRect/strokeRect
- ✅ `core/bl_types.dart` — 28 comp-ops, BLMatrix2D, BLRectI, stroke types
- ✅ `geometry/bl_path.dart` — path com flatten de curvas
- ✅ `geometry/bl_stroker.dart` — stroker com paridade geométrica C++
- ✅ `raster/bl_edge_builder.dart`
- ✅ `raster/bl_analytic_rasterizer.dart` — cover/area analítico
- ✅ `raster/bl_edge_storage.dart` — SoA + buckets
- ✅ `raster/bl_raster_defs.dart` — constantes A8
- ✅ `pipeline/bl_compop_kernel.dart` — 28 comp-ops completos
- ✅ `pipeline/bl_fetch_solid.dart`
- ✅ `pipeline/bl_fetch_linear_gradient.dart`
- ✅ `pipeline/bl_fetch_radial_gradient.dart`
- ✅ `pipeline/bl_fetch_pattern.dart` — nearest/bilinear/affine
- ✅ `pixelops/bl_pixelops.dart` — premultiply/unpremultiply/udiv255/swizzle
- ✅ `text/bl_font.dart` — OpenType parser completo
- ✅ `text/bl_font_loader.dart`
- 🔲 `text/bl_opentype_parser.dart` — GSUB/GPOS ainda não portado
- 🔲 `text/bl_shaper.dart` — shaping avançado pendente
- ✅ `text/bl_glyph_run.dart`
- 🔲 `text/bl_glyph_cache.dart` — atlas com eviction pendente
- ✅ `text/bl_text_layout.dart`
- 🔲 `unicode/bl_bidi.dart` — bidi pendente
- 🔲 `unicode/bl_script_runs.dart` — script runs pendente
- 🔲 `tables/bl_unicode_tables.dart` — tabelas Unicode pendentes
- ✅ `threading/bl_isolate_pool.dart`
- ✅ `blend2d.dart` (barrel export interno)

## 9) Riscos e mitigação

Risco: regressão de qualidade em casos degenerados.
- Mitigação: suíte visual focada em degenerados + asserts em debug.

Risco: SIMD em Dart piorar performance.
- Mitigação: feature flag + benchmark A/B obrigatório.

Risco: overhead de isolates anular ganho.
- Mitigação: paralelismo só acima de limiar de custo de tile.

Risco: shaping OpenType incompleto degradar tipografia.
- Mitigação: priorizar subset de features críticas e corpus de regressão tipográfica.

Risco: cache de glyph crescer demais.
- Mitigação: LRU por memória alvo + métricas de hit-rate no benchmark.

Risco: escopo “completo” explodir prazo.
- Mitigação: congelar “core port” primeiro (raster/pipeline/context) e executar texto em fases curtas com metas objetivas.

## 10) Definição de pronto (DoD) por etapa

Uma fase só fecha quando:
1. `dart analyze` sem issues novos.
2. benchmark roda estável (mínimo 3 execuções consistentes).
3. testes visuais sem regressões críticas.
4. documentação de decisões e trade-offs atualizada.

---

Resumo objetivo:
- Primeiro portamos o coração do Blend2D (raster + pipeline + contexto) com qualidade correta.
- Em paralelo, fechamos a trilha de texto em puro Dart (fontes, shaping, raster e cache).
- Depois expandimos recursos avançados e integração com backend PDF.
- Tudo guiado por benchmark e validação visual contínua.

Próxima fatia grande recomendada:
- **Fase 9 (shaping)**: iniciar port de GSUB/GPOS do OpenType para suporte a ligaduras e kerning avançado.
- **Fase 10 (glyph raster)**: rasterização dedicada de glifos com AA e cache/atlas.
- **Fase 6 (paralelismo)**: isolate pool real por tiles sujos para throughput em cenas grandes.
- Alternativamente: integração dos 28 comp-ops no resolve do rasterizador (atualmente o resolve só usa srcOver/srcCopy inline; o dispatch generalizado via `BLCompOpKernel.compose()` pode ser conectado para os modos avançados), mantendo o protocolo de decisão por benchmark em rodada mínima de 10 execuções antes de qualquer reversão.