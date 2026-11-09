# Fretboard Modeller

A native macOS app (SwiftUI + SceneKit) that builds a dimensionally accurate guitar fretboard solid and exports it as a binary STL (millimetres).

## Features
- Inputs: scale length, nut width, last-fret width, fret count, nut thickness, surface radius at the first and last fret (constant or compound radius), max thickness (7 mm default), wide-end corner diameter (9.5 mm default).
- Board always extends at least 9 mm past the last fret. Optional spoke-wheel truss rod mode adds a configurable extension and a cutout (default 20 mm wide, 5 mm deep, 3 mm inside corner radius).
- Orientation: widest end at the origin, narrowest toward +X.
- 3D viewer: orbit, ⌘ + scroll / pinch to zoom, preset views, fret lines, dimension lines, click two points to measure, and a full measurements panel.

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
