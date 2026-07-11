# Next steps

Snapshot as of 2026-07-11. What's in reasonable shape, and what's next, in
priority order.

## Where things stand

- **Android**: functional, this is the most-tested platform. See
  `docs/BUILD.md` for the `OpenCV_DIR` build flag the native counting engine
  needs.
- **Web**: pilot-ready — capture/import, manual counting, PDF/CSV/PNG
  export, and (as of this session) automatic counting all work in-browser,
  via a WebAssembly build of the same native engine Android/iOS use (see
  `native/opencfu_core/wasm/README.md`). The WASM analysis pipeline itself
  was thoroughly tested (real plate photos under Node), but the
  browser-loading and `dart:js_interop` glue around it were never run in an
  actual browser before shipping — **verify a real capture/count on the
  deployed site first**; see "Web: verify the WASM engine in a real
  browser" below. Build/host instructions are in `docs/BUILD.md`.
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

## 2. Web: verify the WASM engine in a real browser

The WASM port (`native/opencfu_core/wasm/`) is done and the analysis logic
was validated end-to-end against real plate photos — but not through an
actual browser, since none was available while building it. Before relying
on it for a pilot:

1. Open the deployed site, capture or import a real plate photo, confirm a
   plausible colony count comes back (not "unavailable", not a crash).
2. If it fails, open the browser dev console first — `native/opencfu_core/wasm/README.md`'s
   last section ("What still needs a real browser") lists the two specific
   things most likely to be wrong: the dynamic `<script>` loading in
   `web/opencfu/opencfu_web_bridge.js`, or the `dart:js_interop` calling
   convention in `lib/services/opencfu_engine_web.dart`.
3. Spot-check that a web count and an Android count on the *same* photo
   roughly agree — they run the identical processor code, so they should
   match exactly modulo any EXIF-orientation handling differences between
   how each platform decodes the image before handing it to the engine.

Once confirmed working, this item is done; only revisit
`native/opencfu_core/wasm/` if the processor/bridge C++ itself changes later
(see that README for the rebuild steps -- it needs a large one-time
Emscripten + custom-OpenCV toolchain setup, not part of normal
`flutter build web`/CI).

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
