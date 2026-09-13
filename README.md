# dgfx

Motor gráfico 2D em Dart puro: rasterização analítica com anti-aliasing,
gradientes, padrões, stroking, clipping e texto OpenType.

Sem dependências de runtime — só `dart:core`, `dart:math`, `dart:typed_data` e
`dart:async` — e portanto compilável para **native, web e wasm** a partir do
mesmo código. Um teste de arquitetura percorre o grafo de imports a cada build
para garantir que isso continue verdade.

## Instalação

```yaml
dependencies:
  dgfx: ^1.0.0
```

## Uso

```dart
import 'package:dgfx/dgfx.dart';

Future<void> main() async {
  final image = BLImage(240, 240);
  final ctx = BLContext(image)..clear(0xFFFFFFFF);

  final blob = BLPath()
    ..moveTo(30, 40)
    ..cubicTo(210, 10, 30, 190, 200, 170)
    ..lineTo(120, 120)
    ..close();

  ctx
    ..setFillRule(BLFillRule.nonZero)
    ..setLinearGradient(BLLinearGradient(
      p0: BLPoint(30, 40),
      p1: BLPoint(200, 170),
      stops: const [
        BLGradientStop(0.0, 0xFF3366CC),
        BLGradientStop(1.0, 0xFF66CC99),
      ],
    ));
  await ctx.fillPath(blob);

  ctx
    ..setFillStyle(0xFF223344)
    ..setStrokeOptions(const BLStrokeOptions(
      width: 4,
      startCap: BLStrokeCap.round,
      endCap: BLStrokeCap.round,
      join: BLStrokeJoin.round,
    ));
  await ctx.strokePath(blob);

  ctx.flush();
  // `image.pixels` é um Uint32List ARGB pronto para ser codificado.
}
```

O programa completo, com clipping e uma prévia em ASCII, está em
[`example/dgfx_example.dart`](example/dgfx_example.dart).

Toda operação de desenho é `Future` porque o rasterizador pode distribuir
trabalho; chame `flush()` antes de ler os pixels.

## O que está implementado

**Rasterização.** Rasterizador analítico que acumula cobertura por célula
(`cover`/`area`), com máscara de bits por scanline para visitar apenas as
regiões ativas. Regras `nonZero` e `evenOdd`, múltiplos contornos para furos, e
anti-aliasing sem supersampling.

**Composição.** Os 28 operadores: os doze Porter-Duff (`srcOver`, `srcCopy`,
`srcIn`, `srcOut`, `srcAtop`, `dstOver`, `dstCopy`, `dstIn`, `dstOut`,
`dstAtop`, `xor_`, `clear`) e os dezesseis modos de mesclagem separáveis
(`multiply`, `screen`, `overlay`, `darken`, `lighten`, `colorDodge`,
`colorBurn`, `linearBurn`, `linearLight`, `pinLight`, `hardLight`, `softLight`,
`difference`, `exclusion`, `plus`, `minus`, `modulate`). Alfa global por
contexto.

**Estilos.** Cor sólida, gradiente linear, radial e cônico, e padrão de imagem
com transformação afim própria. A filtragem escolhida — `nearest` ou
`bilinear` — vale para a ampliação; na redução o fetcher integra a área que
cada pixel de device cobre, porque amostrar um texel (ou quatro) descartaria a
maior parte da origem e o que sobrasse viraria moiré. É o caminho de uma
digitalização de 300 dpi numa página renderizada a 96 dpi.

**Geometria.** `BLPath` com `moveTo`/`lineTo`/`quadTo`/`cubicTo`/`close`, arcos,
arcos elípticos, retângulos e retângulos arredondados. Stroking com todos os
caps (`butt`, `square`, `round`, `roundRev`, `triangle`, `triangleRev`) e joins
(`bevel`, `miterClip`, `miterBevel`, `miterRound`, `round`), além de tracejado
com offset de fase.

O achatamento de curvas preserva a área. Uma polilinha inscrita na curva sempre
encerra menos área que ela, e com tolerância fixa o erro relativo cresce quando
o raio cai: um círculo de raio 2 px rasterizava com área 11,3 contra 12,57
analíticos, 10% a menos. A folha do achatamento emite, antes do ponto final, o
vértice que faz o triângulo ter exatamente a área da lasca entre a corda e a
curva — com isso a área do polígono é a da curva em qualquer nível de
subdivisão, e o desvio máximo em relação à curva ainda cai para um terço. De
raio 1 a 64 a área rasterizada fica dentro de 0,2% da analítica, e o retângulo
alinhado continua exato.

**Clipping.** Retangular e por caminho arbitrário (`clipToPath`), com pilha
`save`/`restore`. O clip recorta de verdade por máscara de cobertura — não é
rejeição por bounding box.

**Transformação.** `BLMatrix2D` afim completa, com `multiply`, `invert`,
`mapPoint` e determinante, mais `translate`/`scale`/`rotate` no contexto.

**Texto.** Parsing de OpenType em memória: `head`, `maxp`, `hhea`, `hmtx`,
`cmap`, `name`, `OS/2`, `kern`, contornos `glyf` (simples e compostos) e CFF.
Layout com kerning, cache de outline por tamanho e rasterização de glifos.

O shaping cobre GSUB tipos 1 a 4 (substituição simples, múltipla, alternativa e
ligadura) e GPOS tipos 1 e 2 (ajuste simples e por par), incluindo os que vêm
embrulhados numa Extension lookup — GSUB 7 e GPOS 9 —, cujo tipo real é
resolvido ao ler a lista. Do GPOS sai o ajuste completo: o avanço move o cursor
e o *placement* move só o desenho do glifo, que é como a fonte encaixa um
acento sobre a letra. Posicionamento contextual (GSUB 5/6, GPOS 7/8) e marcas
(GPOS 3 a 6) ainda não são aplicados; uma lookup desse tipo é ignorada, nunca
lida como outra coisa.

```dart
final face = BLFontFace.parse(fontBytes);
```

## Plataformas

`package:dgfx/dgfx.dart` é o ponto de entrada principal e funciona em qualquer
alvo, inclusive web e wasm.

`package:dgfx/dgfx_io.dart` reexporta tudo isso e adiciona os recursos que só
existem fora do navegador: `BLFontLoader`, que descobre fontes do sistema e lê
fontes OpenType/TrueType/CFF e todas as faces de coleções TTC, e
`BLIsolatePool`. Importá-lo tira o seu programa da compatibilidade com web —
use-o apenas em aplicações nativas.

No navegador, registre um `BLCallbackFontProvider` na `BLFontCollection` para
resolver URLs, Google Fonts ou `FontFace`. A coleção mantém a face em cache
pelos nomes solicitados, mesmo quando o nome interno OpenType é diferente, e
compartilha uma única consulta entre resoluções simultâneas da mesma face.

## Origem

Este pacote é uma reimplementação independente em Dart, derivada do
[Blend2D](https://blend2d.com) (C++, licença zlib). **Não é o Blend2D**, não é
distribuído nem endossado pelos seus autores; a arquitetura, a API e o
comportamento são próprios, e qualquer diferença de renderização ou desempenho
é responsabilidade deste pacote. Veja [NOTICE](NOTICE) para a atribuição
completa.

## Licença

MIT — veja [LICENSE](LICENSE).

A única exceção é o diretório `third_party/`, que guarda software de terceiros
sob licença própria e fica fora do pacote publicado. Hoje ele contém um port em
Dart do Marlin renderer do OpenJDK, sob GPLv2 com Classpath Exception, usado
apenas como oráculo independente nos testes.
