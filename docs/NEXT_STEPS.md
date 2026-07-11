# Next steps

Snapshot as of 2026-07-11. What's in reasonable shape, and what's next, in
priority order.

## Where things stand

- **Android**: functional, this is the most-tested platform. See
  `docs/BUILD.md` for the `OpenCV_DIR` build flag the native counting engine
  needs.
- **Web**: newly pilot-ready (this session) — capture/import, manual
  counting, and PDF/CSV/PNG export all work in-browser. The native
  auto-counting engine does **not** run on web (no WASM build of it exists);
  see "Web: automatic counting" below if that's worth revisiting. Build/host
  instructions are in `docs/BUILD.md`.
- **iOS**: wired up (Podfile, `opencfu_mobile_core.podspec`, the FFI bridge
  compiles the same C++ sources as Android) but **never actually built or run**
  — this repo was assembled without a Mac. Treat it as the top priority once
  there's an Apple developer account and a Mac available to test on.

## 1. iOS — first real build

This is genuinely untested, not just unpolished. `native/opencfu_core/README.md`
already flags the specific risk areas; start there. In rough order of what's
likely to break first:

1. `cd ios && pod install` — first real test of the `opencfu_mobile_core` pod
   pulling in the community `OpenCV` CocoaPods pod. That pod hasn't been
   updated in a few years; confirm it still resolves and that it includes the
   `ml` module (`Predictor.cpp` needs `cv::ml::RTrees`).
2. `flutter build ios` — confirm the C ABI bridge
   (`opencfu_mobile_bridge.hpp`'s `__attribute__((visibility("default"), used))`)
   actually survives Xcode's dead-code stripping, since nothing but Dart FFI
   calls that symbol.
3. Once it builds: run the same manual pass the Android app has had — capture,
   auto-count, manual edit/exclude, mask draw, export (PDF/CSV/PNG), the
   home-screen widget equivalent (iOS home screen quick action via
   `SceneDelegate.swift`/`AppDelegate.swift` — check it still launches into
   basic-capture like the Android widget does).
4. Only after that: TestFlight for the pilot group mentioned for the web app.

## 2. Web: automatic counting (optional, large)

Manual counting already works on web as a stopgap. If the pilot feedback
says "I need the real algorithm in the browser," porting
`native/opencfu_core` (OpenCV + the vendored processor) to WebAssembly via
Emscripten is the way there — but it's a substantial, separate undertaking
(a WASM OpenCV build, rewriting the FFI bridge as JS interop, re-verifying
every processing option produces the same results as native). Don't start
this speculatively; wait until pilot feedback actually asks for it.

## 3. Premium features

Full design notes already exist in `docs/PREMIUM_FEATURES.md`, including a
suggested build order by implementation cost. Short version, cheapest first:

1. **Segmented Counting** — restrict auto-counting to one grid cell; reuses
   the existing mask pipeline almost entirely.
2. **Colony Type Classification** — classify detected colonies by
   color/size into named types; new UI + one new Dart-side color-sampling
   step, no native changes.
3. **Manual Counting Mode** — a whole new top-level mode (grid → zoom →
   tap-count → extrapolate) for plates too dense to auto-count; the most new
   UI surface, but composed entirely from pieces (mask draw, manual tap-to-add
   markers, `InteractiveViewer` zoom) that already exist elsewhere in the app.

Don't start on these before iOS is at least building — premium features
compound the cross-platform testing surface, and right now only Android is
verified to work at all.
