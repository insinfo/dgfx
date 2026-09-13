# dgfx

[![CI](https://github.com/insinfo/dgfx/actions/workflows/ci.yml/badge.svg)](https://github.com/insinfo/dgfx/actions/workflows/ci.yml)
[![AI Assisted](https://img.shields.io/badge/AI-Assisted-purple.svg)](https://github.com/insinfo/dgfx)

A 2D graphics engine written in pure Dart: analytic anti-aliased rasterization,
gradients, patterns, stroking, clipping and OpenType text.

No runtime dependencies — only `dart:core`, `dart:math`, `dart:typed_data` and
`dart:async` — so the same code compiles to **native, web and wasm**. An
architecture test walks the real import graph on every build to keep that true.

## AI assistance

Parts of the code, the tests and the documentation in this repository were
written with the help of LLM tooling. Everything in the package goes through the
test suite (`dart test`), the analyzer (`dart analyze`) and `dart pub publish
--dry-run` before it lands, and the person who commits it is responsible for it.
Treat the disclosure as information about how the work was produced, not as a
disclaimer about its quality: the checks are the same either way, and so is the
accountability.

## Install

```yaml
dependencies:
  dgfx: ^1.0.0
```

## Usage

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
  // `image.pixels` is a Uint32List of 0xAARRGGBB pixels, ready to encode.
}
```

The full program, with clipping and an ASCII preview, is in
[`example/dgfx_example.dart`](example/dgfx_example.dart). A test analyzes the
snippet above on every run, so it compiles or CI goes red.

Every drawing call returns a `Future`; call `flush()` before reading pixels.

## What is implemented

**Rasterization.** An analytic rasterizer that accumulates per-cell coverage
(`cover`/`area`), with a per-scanline bit mask so only active regions are
visited. `nonZero` and `evenOdd` fill rules, multiple contours for holes, and
anti-aliasing without supersampling.

**Compositing.** All 28 operators: the twelve Porter-Duff ones (`srcOver`,
`srcCopy`, `srcIn`, `srcOut`, `srcAtop`, `dstOver`, `dstCopy`, `dstIn`,
`dstOut`, `dstAtop`, `xor_`, `clear`) and the sixteen separable blend modes
(`multiply`, `screen`, `overlay`, `darken`, `lighten`, `colorDodge`,
`colorBurn`, `linearBurn`, `linearLight`, `pinLight`, `hardLight`, `softLight`,
`difference`, `exclusion`, `plus`, `minus`, `modulate`). Plus a per-context
global alpha.

**Styles.** Solid color, linear, radial and conic gradients, and image patterns
with their own affine transform. The chosen filter — `nearest` or `bilinear` —
applies to magnification; on minification the fetcher integrates the area each
device pixel covers, because sampling one texel (or four) would throw away most
of the source and what survived would turn into moiré. That is the path a 300
dpi scan takes on a page rendered at 96 dpi.

**Geometry.** `BLPath` with `moveTo`/`lineTo`/`quadTo`/`cubicTo`/`close`, arcs,
elliptical arcs, rectangles and rounded rectangles. Stroking with every cap
(`butt`, `square`, `round`, `roundRev`, `triangle`, `triangleRev`) and join
(`bevel`, `miterClip`, `miterBevel`, `miterRound`, `round`), plus dashing with a
phase offset.

Curve flattening preserves area. A polyline inscribed in a curve always encloses
less than the curve does, and with a fixed tolerance the relative error grows as
the radius shrinks: a circle of radius 2 px used to rasterize with area 11.3
against an analytic 12.57, 10% short. The leaf of the flattener now emits, right
before the end point, the vertex that makes the triangle carry exactly the area
of the sliver between chord and curve — so the polygon's area equals the curve's
at any subdivision level, and the maximum deviation from the curve still drops to
a third. From radius 1 to 64 the rasterized area stays within 0.2% of the
analytic one, and an axis-aligned rectangle remains exact.

**Clipping.** Rectangular and arbitrary-path (`clipToPath`), with a
`save`/`restore` stack. The clip cuts by coverage mask — it is not bounding-box
rejection.

**Transforms.** A full affine `BLMatrix2D`, with `multiply`, `invert`,
`mapPoint` and determinant, plus `translate`/`scale`/`rotate` on the context.

**Text.** In-memory OpenType parsing: `head`, `maxp`, `hhea`, `hmtx`, `cmap`,
`name`, `OS/2`, `kern`, `glyf` outlines (simple and composite), CFF/CFF2 and
Type 1. Layout with kerning, an outline cache per size, and glyph
rasterization.

Shaping covers GSUB types 1 to 4 (single, multiple, alternate and ligature
substitution) and GPOS types 1 and 2 (single and pair adjustment), including the
ones wrapped in an Extension lookup — GSUB 7 and GPOS 9 — whose real type is
resolved when the list is read. GPOS yields the full adjustment: the advance
moves the pen and the *placement* moves only the glyph's drawing, which is how a
font parks an accent over a letter.

Note that `ctx.fillText` deliberately uses the simple path (cmap plus `kern`).
For GSUB/GPOS shaping and bidi run splitting, go through `BLTextLayout.shapeText`
and hand the resulting run to `ctx.fillGlyphRun`:

```dart
const layout = BLTextLayout();
final run = layout.shapeText('Ambigüidade', font, x: 20, y: 60);
await ctx.fillGlyphRun(run, font);
```

## What is *not* implemented

This is a rasterizer, not a full graphics stack. The following are absent on
purpose or simply not done yet; none of them fail silently in a way that looks
like success.

- **No image codecs.** There is no PNG, JPEG or any other decoder or encoder.
  `BLImage.pixels` is a `Uint32List` of `0xAARRGGBB`; bring your own encoder, or
  write the raw buffer out. Loading an image to use as a pattern means decoding
  it yourself first.
- **No SVG.** No parser, no renderer, no CSS. There is an SVG parser in the
  repository under `research/`, but it is not part of the published package and
  is not supported.
- **No parallelism and no SIMD.** `BLIsolatePool` is deprecated and runs the job
  on the current isolate; it never spawned one. Dart cannot share memory between
  isolates without `dart:ffi`, so band-level parallelism would cost more in
  copying than the fill itself. Parallelize *above* dgfx — one `BLImage` per
  isolate. There is also no JIT pipeline: Blend2D's speed comes largely from
  compiling pixel pipelines at runtime, and this port does not do that.
- **Partial OpenType shaping.** Contextual and chained-contextual substitution
  and positioning (GSUB 5/6, GPOS 7/8) and every mark lookup (GPOS 3 to 6:
  cursive attachment, mark-to-base, mark-to-ligature, mark-to-mark) are parsed
  but not applied. A lookup of those types is skipped, never misread as another
  type. In practice this means Arabic, Indic and other complex scripts will not
  shape correctly.
- **Bidi is a heuristic.** `BLBidiAnalyzer` splits runs by Unicode block
  (Hebrew, Arabic and neighbours), not by the Unicode Bidirectional Algorithm.
  No embedding levels, no explicit direction controls, no mirroring.
- **No color or bitmap fonts.** `COLR`/`CPAL`, `sbix`, `CBDT`/`CBLC` and SVG
  glyph tables are ignored. Emoji render as outlines when the font has them and
  as `.notdef` when it does not.
- **No TrueType variable fonts.** `fvar`/`gvar`/`avar` are not read. CFF2
  variation stores are applied (`BLFont.withVariationCoordinates`), so a CFF2
  variable font works and a `glyf`-based one renders at its default instance.
- **No hinting.** `fpgm`/`prep`/`cvt` programs and CFF hint operators are
  skipped. Small text is anti-aliased, not grid-fitted, and there is no
  subpixel/LCD filtering.
- **One pixel format.** 32-bit ARGB only. No A8 surfaces, no 16-bit or float
  targets, no premultiplied variants to choose from.
- **No color management.** sRGB values are blended as-is; there is no ICC, no
  wide gamut, no linear-light compositing mode.
- **No text layout above the run.** No line breaking, no justification, no
  `\t` handling, no text-on-path, no rich text.
- **No gradient dithering**, no mesh gradients beyond `fillTriangleGouraud` /
  `fillTriangleMesh`, no filters or effects (blur, shadow, feather).

## Platforms

`package:dgfx/dgfx.dart` is the main entry point and works on every target,
including web and wasm.

`package:dgfx/dgfx_io.dart` re-exports all of that and adds what only exists off
the browser: `BLFontLoader`, which discovers system fonts and reads
OpenType/TrueType/CFF files and every face of a TTC collection, plus the
deprecated `BLIsolatePool`. Importing it takes your program out of web
compatibility — use it only in native applications.

In the browser, register a `BLCallbackFontProvider` on `BLFontCollection` to
resolve URLs, Google Fonts or a `FontFace`. The collection caches the face under
the names it was asked for, even when the internal OpenType name differs, and
shares a single lookup between concurrent resolutions of the same face.

## Origin

This package is an independent Dart reimplementation derived from
[Blend2D](https://blend2d.com) (C++, zlib license). **It is not Blend2D**, is not
distributed or endorsed by its authors; the architecture, the API and the
behavior are its own, and any difference in rendering or performance is this
package's responsibility. See [NOTICE](NOTICE) for the full attribution.

## License

MIT — see [LICENSE](LICENSE).

The one exception is the `third_party/` directory, which holds third-party
software under its own license and stays out of the published package. Today it
contains a Dart port of the OpenJDK Marlin renderer, under GPLv2 with the
Classpath Exception, used only as an independent oracle in the tests. Nothing in
`lib/` reaches it, and a test enforces that. [NOTICE](NOTICE) records the
provenance of everything in the repository, published or not.
