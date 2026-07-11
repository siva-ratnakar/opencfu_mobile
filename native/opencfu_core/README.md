# OpenCFU Native Core

This directory vendors the OpenCFU processor layer into the Flutter app and
exposes it to Dart through a small C ABI bridge.

## Layout

- `src/defines.hpp`, `src/config.h` — core definitions. `config.h` is the
  hand-written mobile equivalent of the autotools-generated desktop header; it
  only defines the macros the processor actually uses (`PACKAGE_VERSION`,
  `INSTALLDIR`, `TRAINED_CLASSIF_XML_FILE`, `TRAINED_CLASSIF_PS_XML_FILE`).
- `src/processor/**` — the unmodified OpenCFU processing pipeline.
- `src/opencfu_mobile_bridge.{hpp,cpp}` — the C ABI called over `dart:ffi`.
- `CMakeLists.txt` — builds `libopencfu_mobile.so` and links OpenCV (Android).
- `opencfu_mobile_core.podspec` — builds the same sources into the iOS app and
  links OpenCV (via CocoaPods).

## The bridge

`opencfu_mobile_analyze_image()` takes an image path, the classifier directory,
a flat `OpenCfuOptions` struct (a mirror of the subset of `ProcessingOptions`
the mobile UI exposes) and returns:

- counts (valid colonies, total detected objects), and the source image size, in
  `OpenCfuBridgeResult`;
- per-object markers in a caller-allocated `OpenCfuColony[]` — each object's
  centre, its four rotated-bounding-box corners (in source-image pixels, same
  order as `OneObjectRow::getPoint`), radius, and valid flag.

The Dart layer (`lib/services/opencfu_engine_native.dart`) maps those corners
onto the displayed image so the overlay matches the desktop app.

Because the vendored `Processor` loads its classifiers from paths relative to
the working directory, the bridge `chdir()`s into `classifier_dir` for the
duration of the call (guarded and restored, under a mutex) so
`./data/trainedClassifier.xml` resolves.

## Building for Android

OpenCV is **not** vendored here. Provide the OpenCV Android SDK and point the
build at it:

1. Download the OpenCV Android SDK (`OpenCV-android-sdk`).
2. Build with the `OpenCV_DIR` project property set to its CMake package:

   ```
   flutter build apk \
     -POpenCV_DIR=/abs/path/to/OpenCV-android-sdk/sdk/native/jni
   ```

   or add `OpenCV_DIR=/abs/path/...` to `android/gradle.properties`.

When `OpenCV_DIR` is absent the native library is **not** built and the app
still runs — the Dart engine reports that the native engine is unavailable
instead of fabricating a count (see `android/app/build.gradle.kts`).

## Classifier assets

The app bundles a single trained classifier at
`assets/opencfu/data/trainedClassifier.xml`. At first run the Dart layer copies
it into the app's support directory as both `trainedClassifier.xml` and
`trainedClassifierPS.xml`.

> **Caveat:** the desktop build ships a separate post-split classifier
> (`trainedClassifierPS.xml`) trained on `data/training-set2`. That model is not
> committed to this repo, so the main classifier is reused for the post-split
> step. Both predictors consume the identical feature layout
> (`Step_4::makeFeaturesMatrix`), so this is dimensionally safe; it only makes
> the split/no-split decision less accurate. Add a real PS classifier asset to
> restore desktop-equivalent accuracy.

## Building for iOS

`ios/Podfile` depends on the local `opencfu_mobile_core` pod
(`opencfu_mobile_core.podspec`), which compiles these same sources and pulls in
OpenCV via the community `OpenCV` CocoaPods pod (it vendors the official
`opencv2.framework`, so no separate `OpenCV_DIR`-style step is needed the way
Android requires one). On a Mac:

```
cd ios && pod install
flutter build ios
```

There is no separate shared library on iOS the way there is on Android — the
bridge compiles straight into the app (or, under CocoaPods' `use_frameworks!`,
its own embedded framework), and the Dart layer finds
`opencfu_mobile_analyze_image()` via `DynamicLibrary.process()`. Because
nothing in Swift/Objective-C ever calls that function directly, only Dart via
FFI, `opencfu_mobile_bridge.hpp` marks it
`__attribute__((visibility("default"), used))` so Xcode's dead-code stripping
doesn't discard an apparently-unreferenced symbol.

**Caveat:** this wiring hasn't been built or run on an actual Mac/Xcode (this
repo was assembled without one). Treat `pod install` as the first real test of
it — plausible failure points are the `OpenCV` pod's exact module coverage
(needs `ml` for `Predictor.cpp`'s `cv::ml::RTrees`, and that pod hasn't been
updated in a few years) and whether the exported-symbol setup above is
actually sufficient in practice.

## Other platforms

The CMake target is portable to desktop (Linux/macOS/Windows) too, but no
build wiring exists for those yet.
