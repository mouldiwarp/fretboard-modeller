# Fretboard Modeller

A native macOS app (SwiftUI + SceneKit) for making guitar fretboards. It has three tools:

1. **Designer** – builds a dimensionally accurate fretboard solid, lets you inspect and measure it, and exports a binary STL (millimetres).
2. **Toolpath** – generates WorkBee Z1+ (Duet / RepRapFirmware) G-code to machine the board from a blank, with an animated playback window.
3. **Fret Template** – generates marker-hole G-code for the jig used to cut fret slots on a chop saw.

A full illustrated walk-through is in [`docs/Fretboard-Modeller-User-Guide.pdf`](docs/Fretboard-Modeller-User-Guide.pdf).

![Designer](docs/img/designer.png)

## Designer
- Inputs: scale length (mm, with inch presets), fret count, nut width, last-fret width, nut thickness (default 0), surface radius at the first and last fret in inches (equal = constant radius, different = compound), max thickness (7 mm), wide-end corner diameter (9.5 mm).
- The widest end is at the origin (X = 0, the heel); the narrowest end is toward +X. The wide corners are rounded; the narrow end has hard corners.
- The board always extends at least 9 mm past the last fret (configurable, default 9 mm).
- **Spoke-wheel truss rod** (on by default): adds a cutout centred on the heel edge, default 20 mm wide × 5 mm deep with 3 mm inside corner radius, all editable.
- Compound radius is modelled as a cone-like surface: the centre-line stays at the max thickness, so the edges get thinner toward the wider end. Edge thicknesses are shown in the measurements panel.
- Viewer: orbit, ⌘ + scroll or pinch to zoom, preset views, fret lines, dimension lines, click two points to measure.
- Export: binary STL; the mesh is checked to be watertight.

## Toolpath (CNC)
The **TOOLPATH** button opens a second window that generates G-code and plays the run back at 1× to 1000× with a moving cutter and live X/Y/Z/feed readout.

- **Machine:** Ooznest WorkBee Z1+, Duet / RepRapFirmware dialect. Work origin: X0 = heel edge of the board, Y0 = board centre line, Z0 = top of the blank. Cutter: 6 mm flat end mill.
- **Feeds:** X/Y cutting 1000 mm/min, Z cutting 800 mm/min, fast travel configurable (default 2500 mm/min is a placeholder – set it to your machine's maximum).
- **Blank:** set the blank length, width, thickness and where the board sits in it before generating. The blank thickness is a *minimum*: it must be at least board thickness + material left + 0.5 mm so there is always a roughing pass. The path is clipped to the blank and checked against it.
- **Sequence** (all aimed at reducing splitting):
  1. Rough the top surface – passes across the board width, extending past the edges, 1.5 mm deep, leaving 0.5 mm, 20 % overlap.
  2. Rough a trench round the outline – 1.5× the cutter width, two loops on every depth layer, outer loop first and the loop beside the board last, leaving 0.5 mm.
  3. Finish the surface – 50 % overlap.
  4. Cut the outline at full depth, leaving tabs.
- **Tabs:** default 4 tabs, 5 mm wide, 1.5 mm tall, hold the board in the blank on the final cut; cut them away by hand.
- **Outline direction:** climb (counter-clockwise) or conventional (clockwise) – flip it if you see splitting on one side.
- The cutter never cuts below the surface (checked by the tests). The playback shows the path, not material removal.

![Toolpath](docs/img/toolpath.png)

## Fret Template
Ported from the standalone Fret Template Builder. Computes fret positions from the nut (`d = L·(1 − 1/2^(n/12))`) and writes GRBL-style G-code that drills marker holes on the centre line (Y0) at each fret (fret 0 = X0). Defaults: 4 mm hole (documentation only), 6 mm plunge, 5 mm safe Z, 200 mm/min. No spindle commands – run the drill by hand. Scale length and fret count start from the designer's values.

![Fret Template](docs/img/template.png)

## Build and run
```sh
swift run FretboardApp          # run from the command line
./make_app.sh                   # build "Fretboard Modeller.app" into ~/Applications (Spotlight-launchable)
```
Requires macOS 13+ and a Swift 5.9+ toolchain (Command Line Tools are enough).

## Tests
```sh
swift test
```
With only the Command Line Tools installed (no Xcode), the swift-testing framework needs extra paths:
```sh
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
U=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
DYLD_LIBRARY_PATH=$U swift test -Xswiftc -F$F -Xlinker -F$F -Xlinker -rpath -Xlinker $F -Xlinker -rpath -Xlinker $U
```

## Layout
- `Sources/FretboardKit` – geometry, mesh, STL, measurements, toolpath and G-code generation, fret template (no UI)
- `Sources/FretboardApp` – SwiftUI app, SceneKit viewers, the three tool windows
- `Tests/FretboardKitTests` – geometry, mesh, toolpath and template tests
- `docs/` – user guide (PDF + HTML source) and screenshots
- `tools/make_icon.swift` – renders the app icon (`Resources/AppIcon.icns`)
