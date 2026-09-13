# Changelog

## 1.0.0

### Corrigido

- O achatamento de curvas subestimava a área que elas encerram. Uma polilinha
  inscrita sempre encerra menos que a curva, e com tolerância fixa o erro
  relativo cresce quando o raio cai: um círculo de raio 2 px rasterizava com
  área 11,3 contra 12,57 analíticos. A folha do achatamento passa a emitir o
  vértice que preserva a área da lasca entre a corda e a curva, o que iguala a
  área do polígono à da curva em qualquer subdivisão e ainda reduz a um terço o
  desvio máximo. De raio 1 a 64 a área rasterizada fica dentro de 0,2%.
- O traço de contornos fechados curvos perdia largura: 25% com `bevel`/`round`
  e 50% com as três variantes de miter, que é o join padrão do PDF. Eram três
  defeitos somados — o ponto de miter saía na metade da distância certa, o join
  era aplicado no lado errado do giro, e a chamada do lado direito negava duas
  vezes e devolvia os pontos do lado esquerdo.
- Traçar um contorno fechado degenerado (`m l h S`, o que o PyMuPDF emite para
  toda linha) emitia o mesmo retângulo duas vezes com a mesma orientação, e a
  cobertura parcial das bordas saturava: uma linha de 1 px saía com cobertura 2
  e sem antisserrilhamento.
- O rasterizador truncava a área acumulada por célula e o alfa de saída em vez
  de arredondar, o que encolhia formas pequenas em até 2%.
- Lookups OpenType do tipo Extension (GSUB 7, GPOS 9) calculavam o tipo real e
  o descartavam, de modo que nenhuma fonte que as usasse aplicava substituição
  ou posicionamento. Além disso GPOS 7, que é posicionamento contextual, era
  confundido com extensão.

### Adicionado

- Filtro de caixa para redução em padrões de imagem: quando a matriz encolhe a
  origem, o fetcher integra a área que cada pixel de device cobre em vez de
  amostrar um texel. `BLPatternFilter.box` declara a intenção; `nearest` e
  `bilinear` passam a se comportar assim na redução de qualquer forma, já que
  os dois só descrevem o que fazer ao ampliar.
- `BLLayoutEngine.applyGPOSAdjustments` devolve o ajuste completo de cada glifo
  — avanço e *placement* —, e o layout de texto aplica os dois. O placement era
  lido das subtabelas e jogado fora, o que apaga acentos deslocados.

## 1.0.0

Primeira versão publicada, sob o nome `dgfx`. O pacote foi reorganizado a
partir do repositório de pesquisa `marlin`, que era um workspace de
experimentos e não um pacote distribuível.

### Adicionado

- `package:dgfx/dgfx.dart` como ponto de entrada único e compatível com web e
  wasm. Um teste de arquitetura percorre o grafo de imports real a cada build
  para garantir que nada ali alcance `dart:io`, `dart:isolate`, `dart:ffi` ou
  `dart:html` — e um caso-guarda verifica que o próprio detector ainda funciona.
- `package:dgfx/dgfx_io.dart` para os recursos que exigem plataforma nativa
  (`BLFontLoader`, `BLIsolatePool`), separado justamente para que importá-los
  seja uma decisão explícita.
- `BLMatrix2D` com `multiply`, `invert`, `mapPoint`, determinante e os
  construtores `translation`, `scaling` e `rotation`.
- Clipping por caminho arbitrário (`clipToPath`, `clipToRectPath`,
  `resetClip`), recortando por máscara de cobertura em vez de rejeitar por
  bounding box.
- `BLStrokeOptions.minimumWidth`, para o caso em que a largura pedida é zero e
  ainda assim se espera a linha mais fina que o dispositivo desenha.
- Exemplo executável e documentação de API.

### Alterado

- **Licença agora é MIT**, com a atribuição ao Blend2D (zlib) registrada em
  `NOTICE`, incluindo a marcação de versão alterada que a cláusula 2 da zlib
  exige.
- O construtor `BLFontFace` passou a ser privado. Ele recebia trinta campos de
  estado interno já decodificado e nunca foi utilizável de fora;
  `BLFontFace.parse(bytes)` é a única porta de entrada.
- Os rasterizadores experimentais de pesquisa, o parser SVG e o escritor PNG
  continuam no repositório mas ficam fora do pacote publicado. Com isso o
  pacote passou a ter **zero dependências de runtime**.

### Movido

- O port em Dart do Marlin renderer do OpenJDK saiu de `lib/src/marlin/` para
  `third_party/marlin_openjdk/`, com licença própria (GPL versão 2 com
  Classpath Exception), os cabeçalhos de copyright da Oracle restaurados em
  cada arquivo e o aviso de modificação que a GPL exige. Ele não entra no
  pacote publicado e nenhuma linha dele é alcançável a partir de
  `package:dgfx/dgfx.dart` — há um teste de arquitetura que verifica isso.
  Continua servindo como oráculo independente nos testes de conformidade.

### Removido

- As dependências `unicode` e `logging`, que não eram usadas por nenhum
  arquivo. `archive` passou a ser dependência apenas de desenvolvimento.
