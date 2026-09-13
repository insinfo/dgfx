# Roteiro Profissional de Robustez: Rasterizadores + SVG Parser
Foco em rasterização de vetores e SVGs de mais alta performace 
foco principal é performace
Este roteiro define como transformar o `marlin` em uma biblioteca de graficos 2D de alta performace dando flexibilidade para o utilizador escolher o algoritmo de rasterização desejado. 
otimizar o codigo ao maximo sem perder as identidades de cada algoritmo definidos nos papers C:\MyDartProjects\marlin\pesquisa

Base normativa e tecnica usada:
- C:\MyDartProjects\marlin\pesquisa
- `pesquisa/news/Scalable_Vector_Graphics_SVG_Tiny_1_2_Sp.md`
- `pesquisa/news/Conformance Criteria — SVG 2.html`
- referencias de implementacao em `referencias/agg-2.6-cpp`, `referencias/blend2d-master`, `referencias/skia-main`, `referencias/resvg-main`, `referencias/marlin-renderer-master`.
entre outros
---

## Status de implementacao (atualizado em 2026-02-08)

- [x] `SKIA_Scalar` / `SKIA_SIMD` agora respeitam `windingRule` por poligono no benchmark SVG.
- [x] `DAA` agora respeita `fillRule` (`evenodd` e `nonzero`).
- [x] Nucleo do `DAA.drawPolygon()` migrado para varredura por scanline com intersecoes (sem `point-in-polygon` no loop por pixel).
- [x] Benchmark SVG validado apos migracao (`Ghostscript_Tiger.svg` e `froggy-simple.svg`).
- [x] Correcao de geometria com multiplos subpaths no parser/rasterizadores (remove artefato diagonal preto no `froggy-simple`).
- [x] `SvgPolygon` agora preserva contornos via `contourVertexCounts`, mantendo semantica de `evenodd/nonzero` sem criar arestas fantasmas entre subpaths.
- [x] `Blend2D v1` e `Blend2D v2` atualizados para consumir contornos (`contourVertexCounts`) e fechar arestas por subpath.
- [x] Benchmark SVG atualizado para propagar contornos para `B2D_v1_*` e `B2D_v2_*` (immediate e batch).
- [x] `EDGE_FLAG_AA` atualizado para `windingRule` + multiplos contornos (`contourVertexCounts`) sem triangulo preto no `froggy-simple`.
- [x] Edge-flag agora limpa scanline completa por linha para eliminar residuos de flags.
- [x] `Blend2D v1` e `Blend2D v2`: conservacao de cobertura por segmento (`sum(distYLocal) == distY`) para reduzir drift numerico por linha.
- [x] `Blend2D v1`: gate SIMD alinhado ao `fillRule` (SIMD apenas `nonzero`; `evenodd` cai no scalar correto).
- [x] `Blend2D v2`: caminho SIMD atualizado para suportar `evenodd` com a mesma semantica do scalar (paridade entre modos).
- [x] `Skia scanline`: ajustes de arredondamento em ponto fixo (`round`) nas arestas para maior estabilidade numerica em SVG real.
- [x] `Blend2D v2`: resolve migrado para modelo de celula em 2 canais (`cell0 = cover - area`, `cell1 = area`) com acumulador por scanline (`cellAcc`), aproximando a semantica do `cell_merge` do Blend2D.
- [x] `Skia scanline`: fast-path de AET com insercao ordenada + verificacao de ordenacao, evitando sort completo quando a lista ja esta ordenada.
- [x] `Marlin`: `drawPolygon` agora aceita `contourVertexCounts` e renderiza subpaths separados (corrige geometria com furos/contornos em SVG real, removendo artefato diagonal no sapo).
- [x] Limpeza de warnings do analyzer nos arquivos de benchmark/svg/parser/edge_flag/marlin.
- [x] `Blend2D v2`: packing de celulas ativas por linha (bitmask) no caminho serial para pular linhas vazias e iniciar resolve no primeiro x ativo.
- [x] `Skia scanline`: bucketizacao por tile-Y (32px) para pular tiles sem arestas iniciando quando AET esta vazia.
- [x] `Marlin`: ajuste de ciclo de subpath (`moveTo`/`closePath`) para nao fechar caminho inexistente no primeiro `moveTo` (remove cortes espurios).
- [x] Benchmark SVG agora emite contornos (`stroke`) como geometria de preenchimento, tornando visivel o contorno do tigre em todos os backends.
- [x] `MarlinCache`: correcao de limpeza da faixa de tiles tocados em `resetTileLine` (remove limpeza incorreta que podia deixar residuos visuais).
- [x] Stroker central do benchmark migrado de "quad por segmento" para "anel por contorno" com join miter/bevel (reduz emendas visuais e custo de geometria de stroke).
- [x] `Blend2D v2` com isolates agora usa o mesmo resolve mascarado por bitset de celulas ativas (paridade com caminho serial).
- [x] `MarlinRenderer.endRendering` portado para fluxo de tile-line/subpixel mais fiel ao `Renderer.java` (AEL incremental + insertion sort local + acumulacao diferencial de cobertura).
- [x] `MarlinCache.copyAARow` ajustado para contrato diferencial (`prefix-sum` + clamp + `touchedTile` por cobertura), alinhando com a referencia Java.
- [x] `Marlin` deixou de remapear alpha duas vezes no blit (remove distorcao de cobertura e reduz artefatos de cortes).
- [x] Benchmark SVG: `Blend2D v1` desativado por padrao (`enableBlend2Dv1 = false`) devido custo extremo em cenas SVG reais (especialmente `B2D_v1_SIMD` no Tiger).
- [x] Contrato unificado introduzido: `drawPolygon(vertices, color, {windingRule, contourVertexCounts})` em backends do benchmark.
- [x] `ACDR` corrigido para processar `contourVertexCounts` + `windingRule` (even-odd/non-zero) em SVG real.
- [x] `AMCAD` corrigido para SDF com multiplos contornos sem arestas fantasmas entre subpaths.
- [x] `Marlin` recebeu desempate estavel de crossings iguais com chave secundaria (`edgePtr`) para robustez em contornos coincidentes.
- [x] `ACDR` no benchmark SVG otimizado por blend restrito ao bounding box do poligono (queda de ~7355ms para ~1841ms no Tiger).
- [x] `QCS` corrigido com implementacao real de `contourVertexCounts + windingRule` (even-odd/non-zero) no loop de assinatura por subamostra.
- [x] `SCP_AED` corrigido com implementacao real de contornos em scanline/SDF/curvature (sem conectar subpaths distintos).
- [x] Benchmark SVG validado apos correcoes: sem regressao funcional no `froggy-simple` para `QCS` e `SCP_AED`.
- [x] `DBSR` corrigido com implementacao real de `contourVertexCounts + windingRule` (even-odd/non-zero), removendo conexao artificial entre subpaths.
- [x] `HSGR` corrigido para preencher poligonos multi-contorno com `windingRule` real (fallback robusto por distancia/inside test para SVG complexo).
- [x] Benchmark SVG atualizado para propagar `windingRule` + `contourVertexCounts` tambem para `DBSR` e `HSGR`.
- [x] Otimizacao `HSGR` aplicada no caminho multi-contorno: processamento tile-aware em ordem Hilbert + bucketizacao de arestas por linha (reduz custo em SVG com muitos subpaths).
- [x] Hardening `DBSR` aplicado: bucketizacao de arestas por linha para reduzir custo por pixel mantendo `evenodd/non-zero`.
- [x] `RHBD` otimizado com bucketizacao de arestas por linha no caminho por tile (reduz custo por pixel em SVG real).
- [x] `AMCAD` otimizado com bucketizacao de arestas por linha na avaliacao SDF/inside test (queda forte de custo em cenas com muitos contornos).
- [x] Novo rasterizador `LNAF_SE` integrado ao projeto e benchmarks (scanline + span-ends + LUT de normal quantizada).

Medicoes observadas (benchmark `benchmark/svg_render_benchmark.dart`):
- DAA em `Ghostscript_Tiger`: ~8594ms -> ~95ms.
- DAA em `froggy-simple`: ~3239ms -> ~40ms.

Observacao:
- A migracao preserva a identidade DAA (LUT + distancia assinada na borda), mas troca o preenchimento interno para spans de scanline (AET simplificado), alinhando corretude e performance para SVGs complexos.
- O defeito do sapo nao era "AA ruim", era topologia quebrada ao concatenar subpaths diferentes em um unico anel. A correcao preserva os contornos e fecha cada subpath localmente no rasterizador.
- Estado atual Blend2D: diagonal preta removida, mas ainda existe `banding` horizontal no `froggy-simple` (artefato de acumulacao cobertura/area). Isso virou prioridade de corretude no core Blend2D.
- Estado atual Blend2D (apos ajustes numericos): banding horizontal caiu e ficou mais estavel entre scalar/SIMD, mas ainda ha resquicio fraco em fundos planos.
- Estado atual Blend2D: `B2D_v2` com `evenodd` agora roda em scalar e SIMD com mesma regra de fill; proxima etapa e aproximar layout/resolve de celulas ao `cell_merge` original para reduzir diferencas residuais.
- Estado atual Blend2D: `B2D_v2` ja usa resolve no estilo 2-canais (cell-merge-like) e ficou mais proximo da referencia; proximo passo e portar packing/bitmasks de celulas para reduzir custo de resolve e alinhar ainda mais com o Blend2D original.
- Estado atual Blend2D: packing/bitmask ja ativo no resolve serial; proximo passo e estender o mesmo esquema para o caminho com isolates (serializacao de bitmask + resolve paralelo com mascaras).
- Estado atual strokes: suporte atual e de benchmark (stroke-to-fill simplificado por segmento, join/cap basicos). Proximo passo e mover esse pipeline para IR de path/stroker central para qualidade de join/cap igual entre backends.
- Estado atual strokes: benchmark ja usa stroker de anel por contorno (miter/bevel). Proximo passo e suportar caps/joins completos por estilo SVG (`linecap`, `linejoin`, `miterlimit`) no IR central.
- Estado atual HSGR: corretude em SVG multi-subpath melhorou, mas o fallback robusto ficou caro no `froggy-simple`; proximo passo e reintroduzir percurso Hilbert/tile com AET por contorno para recuperar performance.
- Estado atual HSGR: caminho multi-contorno agora usa tiles/Hilbert + buckets por linha; custo do `froggy-simple` caiu significativamente, mantendo suporte a furos/subpaths.
- Estado atual RHBD/AMCAD: ambos migrados para selecao de arestas por scanline (row buckets), reduzindo o custo O(pixels*edges) para O(pixels*edges_locais) em SVG real.
- Estado atual LNAF_SE: backend novo focado em throughput (interior de spans solido + AA apenas nas pontas), com suporte a `evenodd/non-zero` e contornos multiplos.

Proximo foco imediato:
- Corrigir `banding` horizontal do Blend2D (`_addSegment`/conservacao de cobertura em clipping horizontal) e validar contra referencia.
- Corrigir custo anormal de `B2D_v1_SIMD` (hoje muito pior que scalar).
- Introduzir comparacao automatica de divergencia visual por backend (golden + threshold).
- Iniciar baseline scanline central compartilhado para reduzir divergencia entre algoritmos em geometrias de multiplos subpaths.

Plano tecnico curto para fechar banding Blend2D:
1. Migrar acumulacao de `cover/area` para escala fixa unica por pixel com arredondamento consistente (evitar mistura de truncamentos por segmento).
2. Adicionar compensacao de erro por scanline (sum(distYLocal) == distY) para eliminar drift horizontal.
3. Criar teste visual focado em fundo uniforme (SVG sintetico) com threshold por linha para detectar banding no CI.

---

## 1) Principios de arquitetura (decisao-chave)

1. O parser **nao corrige geometria por heuristica**.
- Parser deve preservar semanticamente o SVG (subpaths, fill-rule, winding, transform stack, paint order).
- Normalizacoes destrutivas (ex.: reordenar contornos por area) devem ser opcionais e fora do parser canonico.

2. O rasterizador é o responsavel por interior/fill robusto.
- Mesmo path complexo deve funcionar em `nonzero` e `evenodd`.
- Caminho SIMD e scalar devem produzir resultado equivalente (delta visual controlado).

3. A API vetorial interna deve ser de alto nivel (Path/Canvas), nao apenas `drawPolygon`.
- `moveTo`, `lineTo`, `quadTo`, `cubicTo`, `arcTo`, `close`, `drawRect`, `drawRoundRect`, `drawCircle`, `drawEllipse`, `drawPath`, `drawText`.

---

## 2) Meta de conformidade (MVP profissional)

Classe alvo inicial: **Conforming SVG  (static/secure-static)** com base em SVG.

Escopo fase 1 (obrigatorio):
- Parsing robusto de path data (`M/L/H/V/C/S/Q/T/A/Z`, abs/rel).
- `fill-rule: nonzero|evenodd` correto.
- Transform stack correto (CTM com dupla precisao para composicao de matriz).
- Shapes basicas: `path`, `rect`, `circle`, `ellipse`, `polygon`, `polyline`, `line`.
- Paint basico: `fill`, `stroke`, `fill-opacity`, `stroke-opacity`, `opacity`.
- `viewBox` + `preserveAspectRatio`.
- Tratamento de erro conforme parser tolerante (nao crashar com dados invalidos).

Escopo fase 2:
- `clipPath`, `mask` (subset), gradientes lineares/radiais, imagem raster.
- Texto basico via shaping pipeline (portar o HarfBuzz e portar o FreeType .

Escopo fase 3:
- perfil high-quality (AA melhor, regressao visual baixa, qualidade de reamostragem e composicao refinadas).

---

## 3) Novo modelo interno: Path e Scene

## 3.1 `Path2D` interno (IR canonica)

Criar IR vetorial independente do parser:
- `PathVerb`: Move, Line, Quad, Cubic, Arc, Close.
- `Path2D { verbs, points, fillRule }`.
- Subpaths preservados por `Move` e `Close`.
- Sem triangulacao prematura no parser.

API publica minima:
- `beginPath()`
- `moveTo(x,y)`
- `lineTo(x,y)`
- `quadTo(cx,cy,x,y)`
- `cubicTo(c1x,c1y,c2x,c2y,x,y)`
- `arcTo(...)` + helper para arco eliptico SVG
- `close()`
- `drawRect`, `drawRoundRect`, `drawCircle`, `drawEllipse`
- `drawPath(path, paint)`
- `drawText(text, x, y, textStyle)`

## 3.2 `Paint` e estado grafico

- `PaintStyle`: fill / stroke / fill+stroke.
- `Color`, `Shader` (gradiente futuro), `alpha`, `blendMode`.
- `StrokeStyle`: width, cap, join, miterLimit, dash.
- `RenderState`: CTM, clip, globalOpacity.

## 3.3 Scene list

Parser SVG gera comandos de alto nivel:
- `DrawPathCommand(path, paint, state)`
- `PushState` / `PopState`
- `ClipPathCommand`

---

## 4) Rasterizador robusto (core)

## 4.1 Motor padrao (scanline orientado a edge list)

Implementar um rasterizador de referencia robusto:
- Construir edges por subpath (com orientacao).
- Active Edge Table por scanline.
- Acumulo de winding por span.
- Regra `evenodd` e `nonzero` no mesmo kernel.
- Cobertura AA por area/fracao subpixel (8-bit ou superior).

Esse motor vira baseline de corretude para validar os demais.

## 4.2 Contrato de fill-rule unico para todos os rasterizadores

Cada rasterizador deve implementar o mesmo contrato:
- `fillRule = evenOdd|nonZero`
- resultado igual ao baseline (tolerancia definida).



## 4.3 Pipeline de flattening geometrico

- Curvas (quad/cubic/arc) flatten por erro maximo controlado (flatness em px).
- Flatness adaptativa por zoom/CTM.
- Garantir monotonicidade quando necessario para estabilidade numerica.
- importante os rasterizadores não devem ter saidas absurdas diferentes em processadores diferentes

## 4.4 Robustez numerica

- CTM em `double`.
- Intersecoes/ordem de edges com epsilon consistente.
- Ordenacao estavel de edges por x e slope.
- Sanitizacao de NaN/Inf antes de rasterizar.

---

## 5) Parser SVG profissional

## 5.1 Estrategia

- Parser em duas etapas:
1. Parse XML + estilo/atributos (DOM leve ou stream parser).
2. Conversao para Scene/Path IR (sem perder semantica).

## 5.2 Conformidade minima de atributos

Implementar e testar:
- `d`, `fill`, `stroke`, `fill-rule`, `fill-opacity`, `stroke-opacity`, `opacity`.
- `transform` completo (translate/scale/rotate/skew/matrix).
- `viewBox`, `preserveAspectRatio`.
- heranca de estilo (inline + `style="..."` + apresentação basica).

## 5.3 Erro e recuperacao

- Path data invalido: ignorar segmento invalido e continuar quando possivel.
- Elemento desconhecido: ignorar com warning estruturado.
- Modo estrito (testes) vs modo tolerante (runtime).

## 5.4 Performance de parse

- Tokenizador de path sem regex pesada em loop critico.
- Reuso de buffers/listas para reduzir alloc.
- Cache de estilos resolvidos em subarvores repetidas.

---

## 6) Texto e fontes (`drawText`) de forma profissional

Fase inicial:
- `drawText` basico com shaping simples (latin) e fallback previsivel.

Fase profissional:
- Integrar shaping completo (HarfBuzz) + raster de glyph (FreeType/SDF/scanline).
- Suporte bidi, ligaduras e fallback de fontes.
- Mapeamento de `text-anchor`, baseline, `font-family`, `font-size`.

Parser SVG de texto:
- `text`, `tspan` (primeiro), `textPath` (fase posterior).
- `textArea` pode entrar como extensao Tiny 1.2 (não core SVG 2 geral).

---

## 7) Plano de execucao por fases

## Fase A (2-4 semanas): Fundacao correta

Entregas:
- `Path2D` IR + API de desenho vetorial minima.
- Rasterizador baseline scanline robusto (`evenodd`/`nonzero`).
- Parser SVG convertido para gerar IR (sem normalizacao destrutiva).
- Testes unitarios de path parser + fill-rule.

Critério de aceite:
- Casos com multiplos subpaths e buracos renderizando igual ao esperado.
- Sem regressao nos benchmarks atuais de sapo/tigre.

## Fase B (3-6 semanas): Confiabilidade e performance

Entregas:
- Ajuste de DAA para scanline/AET.
- Correcao do caminho SIMD Blend2D com regra de fill completa.
- Benchmarks de CPU/memoria + profiling.
- Golden tests de imagem por rasterizador.

Critério de aceite:
- Divergencia visual abaixo de threshold vs baseline.
- Ganho de performance documentado sem regressao de corretude.

## Fase C (4-8 semanas): SVG viewer robusto

Entregas:
- `clipPath`, gradientes basicos, imagem raster.
- Texto com pipeline inicial.
- Matriz de conformidade (feature x status x teste).

Critério de aceite:
- Cobertura de testes W3C/resvg subset definida e reproduzivel.

## Fase D (continuo): High-quality

Entregas:
- Melhorias de AA/composicao.
- Ajuste fino de precisao e estabilidade numerica.
- Ferramenta de diff visual e dashboard de regressao.

---

## 8) Testes e qualidade (obrigatorio)

## 8.1 Tipos de teste

- Unitario: parser de comandos path, transform, fill-rule.
- Propriedade/fuzz: strings `d` aleatorias e degeneradas.
- Golden image: fixtures SVG reais.
- Diferencial: comparar com `resvg`/`skia` em subset definido.

## 8.2 Fixtures obrigatorias

- Casos `evenodd` com multiplos subpaths.
- Casos `nonzero` com contornos opostos.
- Auto-interseccao, quase-colinear, coordenadas extremas.
- `viewBox`/`preserveAspectRatio` variado.

## 8.3 Metricas de gate CI

- `render_correctness_score`
- tempo medio por frame
- pico de memoria
- taxa de falha por corpus fuzz

Build falha se corretude cair abaixo do limite acordado.

---

## 9) Refatoracao de codigo no projeto

Diretorios sugeridos:
- `lib/src/graphics/path/` (IR + builders)
- `lib/src/graphics/paint/`
- `lib/src/raster/core/` (baseline)
- `lib/src/raster/backends/` (DAA, Blend2D, etc)
- `lib/src/svg/parser/` (lexer, parser, style resolver)
- `test/svg_conformance/`
- `benchmark/svg/`

Regras de engenharia:
- Um contrato unico de `FillRule` para todo backend.
- Sem logica duplicada de parse/flatten por rasterizador.
- Cada otimizacao SIMD deve ter teste de equivalencia com scalar.

---

## 10) Backlog priorizado (ordem recomendada)

P0:
- Congelar parser canonico sem normalizacao destrutiva.
- Criar `Path2D` IR e migrar draw de poligono para draw de path.
- Implementar raster baseline scanline robusto.
- Corrigir fill-rule no Blend2D SIMD interno.

P1:
- Migrar DAA para pipeline scanline/AET.
- Flatten adaptativo de curvas/arcos.
- Goldens + diff visual automatizado no CI.

P2:
- Stroke completo (caps/joins/dash).
- Texto basico + font fallback inicial.
- `clipPath` e gradiente linear.

P3:
- High-quality profile.
- Performance tuning por arquitetura (SIMD/threads/tiles).

---

## 11) Definicao de pronto (DoD)

Um recurso so e considerado "profissional" quando:
- tem comportamento alinhado a spec (ou desvio documentado),
- tem teste unitario + teste visual,
- tem benchmark antes/depois,
- funciona igual no caminho scalar e otimizado,
- possui documentacao de limites conhecidos.

---

## 12) Primeira sprint recomendada (execucao imediata)

1. Introduzir `Path2D` + `FillRule` unificados.
2. Atualizar parser SVG para emitir `Path2D` com subpaths preservados.
3. Criar raster baseline scanline para virar oraculo de corretude.
4. Rodar benchmark do sapo em todos os backends comparando contra baseline.
5. Corrigir divergencias criticas (DAA e Blend2D SIMD primeiro).

Esse passo ja remove a causa raiz atual e prepara o terreno para `drawRect`, `drawArc`, `lineTo`, `close`, `drawBezier`, `drawText` com consistencia de engine.
