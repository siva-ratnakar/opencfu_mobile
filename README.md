# OpenCFU Mobile

Flutter app for bacterial colony counting on Android/iOS, powered by the native
[OpenCFU](https://github.com/qgeissmann/OpenCFU) processing core over `dart:ffi`.

This repository was extracted from the `opencfu_mobile/` folder of an OpenCFU
fork into a standalone project.

## Features

- **Basic mode** — one-tap capture with OpenCFU's recommended defaults:
  inverted auto threshold, auto-max radius (0 minimum), auto ROI/mask, colour
  filter off, outlier filter at threshold 30, similar-colour clustering off.
- **Advanced mode** — choose the OpenCFU controls (threshold mode/auto/value,
  min/max radius, colour filter, outlier filter + threshold, colour clustering)
  *before* opening the camera.
- Camera-first capture with gallery import.
- After capture the plate is shown with every detected colony marked (the same
  rotated-box outlines the OpenCFU desktop app draws), mapped onto the image.
- Editable colony count per plate (edits keep the detected markers).
- Sample naming per plate — if you advance/finish without a name, the app
  prompts for one.
- Results table with PNG export, plus PDF and text sharing.
- "Basic Count" home-screen entry point — an Android app widget and an iOS
  Home Screen quick action both jump straight into basic-mode capture.

## Architecture

- `lib/main.dart` — UI flow and wiring.
- `lib/capture_options.dart` — the processing options model (mirrors the native
  `OpenCfuOptions`).
- `lib/services/` — the FFI engine (`opencfu_engine_native.dart`), the non-FFI
  stub, and the shared result model (`opencfu_models.dart`).
- `native/opencfu_core/` — the vendored OpenCFU processor sources, a C ABI
  bridge (`opencfu_mobile_bridge.*`), a hand-written `config.h`, a CMake build
  (Android) and a CocoaPods podspec (iOS). See `native/opencfu_core/README.md`.
- `assets/branding/` — the app icon and notification icon artwork: source SVGs
  under `source/`, rendered master PNGs, and `gen_icons.py`, which regenerates
  every platform icon file from the sources (`python3 assets/branding/gen_icons.py`,
  needs `pillow`, `cairosvg`, `numpy`).

The Dart layer talks to `opencfu_mobile_analyze_image()`, which runs the real
OpenCFU pipeline and returns colony counts plus per-object markers. When the
native library is not linked the app reports that the engine is unavailable
rather than inventing a count.

## Building with native counting (Android)

OpenCV is not vendored. Provide the OpenCV Android SDK and point the build at
its CMake package:

```bash
flutter pub get
flutter build apk -POpenCV_DIR=/abs/path/to/OpenCV-android-sdk/sdk/native/jni
# or add OpenCV_DIR=/abs/path/... to android/gradle.properties
```

Without `OpenCV_DIR` the app still builds and runs (the engine reports as
unavailable). See `native/opencfu_core/README.md` for details and the
classifier caveat.

## Building with native counting (iOS)

```bash
flutter pub get
cd ios && pod install && cd ..
flutter build ios
```

OpenCV comes in via CocoaPods (see `native/opencfu_core/opencfu_mobile_core.podspec`),
no separate SDK download needed. This wiring hasn't been built on an actual
Mac — see `native/opencfu_core/README.md` for the caveats to check on the
first real build.

## Run / validate

```bash
flutter pub get
flutter run
flutter analyze
flutter test
```

## Regenerating platform scaffolding

If any default platform files are missing, run `flutter create .` in the repo
root — it restores the standard Android/iOS/desktop/web scaffolding without
touching `lib/`, `native/`, or `assets/`.

## License

The OpenCFU core is GPL-licensed; this app is distributed under the same terms.
See `COPYING`.
