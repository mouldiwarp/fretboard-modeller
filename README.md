# Fretboard Modeller

A native macOS app (SwiftUI + SceneKit) that builds a dimensionally accurate guitar fretboard solid and exports it as a binary STL (millimetres).

## Features
- Inputs: scale length, nut width, last-fret width, fret count, nut thickness, surface radius at the first and last fret (constant or compound radius), max thickness (7 mm default), wide-end corner diameter (9.5 mm default).
- Board always extends at least 9 mm past the last fret. Optional spoke-wheel truss rod mode adds a configurable extension and a cutout (default 20 mm wide, 5 mm deep, 3 mm inside corner radius).
- Orientation: widest end at the origin, narrowest toward +X.
- 3D viewer: orbit, ⌘ + scroll / pinch to zoom, preset views, fret lines, dimension lines, click two points to measure, and a full measurements panel.

## CNC toolpath (WorkBee Z1+)
The **TOOLPATH** button opens a second window that generates G-code (Duet / RepRapFirmware dialect) and plays the run back at 1x to 1000x with a moving cutter and live X/Y/Z/feed readout.
- Order: rough the top surface (passes across the board width, extending past the edges to the blank, 1.5 mm deep, 0.5 mm left, 20% overlap), rough a trench round the outline (1.5 x cutter width, outer loop first then the inner loop on each layer, so the cut beside the board is the lightest), finish the surface (50% overlap), then a full-depth outline cut.
- Blank size is set before generating (length, width, thickness, heel margin); the path is clipped to the blank and validated against it.
- Tabs (default 4, 5 mm wide, 1.5 mm tall) hold the board in the blank during the final outline cut and are left to be cut away by hand. The outline can run climb (CCW) or conventional (CW) to suit the spindle direction and avoid splitting.
- Feeds: X/Y 1000 mm/min, Z 800 mm/min, fast travel configurable (default 2500 mm/min, Ooznest's documented maximum feed rate - set it to your machine's configured maximum).
- Work origin: X0 = heel edge, Y0 = board centre line, Z0 = top of stock. Cutter is a 6 mm flat end mill.

## Build and run
```sh
swift run FretboardApp          # run from the command line
./make_app.sh                   # build "Fretboard Modeller.app" into ~/Applications (Spotlight-launchable)
```
Requires macOS 13+ and a Swift 5.9+ toolchain.

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
- `Sources/FretboardKit` – geometry, mesh generation, STL writer, measurements (no UI)
- `Sources/FretboardApp` – SwiftUI app and SceneKit viewer
- `tools/make_icon.swift` – renders the app icon (`Resources/AppIcon.icns`)
