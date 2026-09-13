# Changelog

## 1.0.0

First published release, under the name `dgfx`. The package was reorganised out
of the `marlin` research repository, which was a workspace of experiments
rather than a distributable package.

### Added

- `package:dgfx/dgfx.dart` as the single entry point, compatible with web and
  wasm. An architecture test walks the real import graph on every build to make
  sure nothing reachable from there touches `dart:io`, `dart:isolate`,
  `dart:ffi` or `dart:html` — and a guard case checks that the detector itself
  still works.
- `package:dgfx/dgfx_io.dart` for the features that need a native platform
  (`BLFontLoader`, `BLIsolatePool`), kept separate precisely so that importing
  them is an explicit decision.
- `BLMatrix2D` with `multiply`, `invert`, `mapPoint`, determinant and the
  `translation`, `scaling` and `rotation` constructors.
- Clipping against an arbitrary path (`clipToPath`, `clipToRectPath`,
  `resetClip`), clipping by coverage mask instead of rejecting by bounding box.
- `BLStrokeOptions.minimumWidth`, for the case where the requested width is
  zero and the thinnest line the device can draw is still expected.
- A box filter for minification in image patterns: when the matrix shrinks the
  source, the fetcher integrates the area each device pixel covers instead of
  sampling one texel. `BLPatternFilter.box` declares the intent; `nearest` and
  `bilinear` now behave that way on any minification, since both only describe
  what to do when magnifying.
- `BLLayoutEngine.applyGPOSAdjustments` returns each glyph's full adjustment —
  advance *and* placement — and the text layout applies both. Placement was
  read from the subtables and thrown away, which erases displaced accents.
- A runnable example and API documentation.

### Fixed

- Curve flattening underestimated the area the curves enclose. An inscribed
  polyline always encloses less than the curve, and with a fixed tolerance the
  relative error grows as the radius falls: a circle of radius 2 px rasterized
  with area 11.3 against 12.57 analytic. The flattening leaf now emits the
  vertex that preserves the area of the sliver between the chord and the curve,
  which makes the polygon's area equal the curve's at any subdivision and also
  cuts the maximum deviation to a third. From radius 1 to 64 the rasterized
  area stays within 0.2 %.
- Stroking closed curved contours lost width: 25 % with `bevel`/`round` and
  50 % with all three miter variants, which is the PDF default join. It was
  three defects compounded — the miter point came out at half the right
  distance, the join was applied on the wrong side of the turn, and the
  right-side call negated twice and returned the left side's points.
- Stroking a degenerate closed contour (`m l h S`, which is what PyMuPDF emits
  for every line) emitted the same rectangle twice with the same orientation,
  and the partial coverage of the edges saturated: a 1 px line came out with
  coverage 2 and no antialiasing.
- The rasterizer truncated the accumulated per-cell area and the output alpha
  instead of rounding, which shrank small shapes by up to 2 %.
- OpenType Extension lookups (GSUB 7, GPOS 9) computed the real type and
  discarded it, so no font using them applied substitution or positioning. On
  top of that GPOS 7, which is contextual positioning, was mistaken for an
  extension.

### Changed

- **The licence is now MIT**, with the Blend2D attribution (zlib) recorded in
  `NOTICE`, including the altered-version marking that clause 2 of the zlib
  licence requires.
- The `BLFontFace` constructor became private. It took thirty fields of
  already-decoded internal state and was never usable from outside;
  `BLFontFace.parse(bytes)` is the only way in.
- The experimental research rasterizers, the SVG parser and the PNG writer stay
  in the repository but are kept out of the published package. With that, the
  package has **zero runtime dependencies**.
- The published package carries only README, LICENSE, NOTICE, CHANGELOG,
  pubspec, `lib/` and `example/`. The test suite, the benchmarks, the
  generation tools and the research material stay in the repository.

### Moved

- The Dart port of the OpenJDK Marlin renderer moved from `lib/src/marlin/` to
  `third_party/marlin_openjdk/`, with its own licence (GPL version 2 with
  Classpath Exception), Oracle's copyright headers restored in every file and
  the modification notice the GPL requires. It does not enter the published
  package and not one line of it is reachable from `package:dgfx/dgfx.dart` —
  there is an architecture test that checks this. It still serves as an
  independent oracle in the conformance tests.

### Removed

- The `unicode` and `logging` dependencies, which no file used. `archive`
  became a development-only dependency.
