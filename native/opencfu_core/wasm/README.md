# OpenCFU WebAssembly core

Compiles the same vendored OpenCFU processor (`../src/processor/**`) and the
same C ABI bridge (`../src/opencfu_mobile_bridge.{hpp,cpp}`) used by
Android/iOS into `opencfu_mobile.js` + `opencfu_mobile.wasm`, so colony
counting also works on the web build instead of falling back to "native
engine unavailable" there.

The compiled output is **checked into `web/opencfu/`** (not gitignored) and
treated as a build artifact, like a vendored binary dependency -- rebuilding
it needs a large, one-time toolchain setup (Emscripten + a custom
Emscripten-cross-compiled OpenCV, both described below) that isn't worth
adding to the GitHub Actions web-deploy workflow. `flutter build web` just
picks up the committed `web/opencfu/*.js`/`*.wasm` via Flutter's normal
`web/` passthrough (everything under `web/` is copied verbatim into
`build/web/`) -- no CI changes needed. Only rebuild these files by hand when
`../src/processor/**`, `../src/opencfu_mobile_bridge.*`, or `wasm_bridge.cpp`
actually change.

## Why this needed real work (not just a CMake flag)

- **No official WASM build of OpenCV includes what this needs.** The
  official `opencv.js` build (`platforms/js/build_js.py`) explicitly
  disables `imgcodecs` (JPEG/PNG decode) and `ml` (the RTrees classifier)
  because its typical use case reads pixels from an HTML canvas instead of
  file bytes and doesn't need machine learning. OpenCFU needs both --
  `cv::imread`/`imdecode` for the actual photo, `cv::ml::RTrees` for the
  post-split colony classifier -- so OpenCV had to be built from source
  again with a different module list.
- **The bridge's request/response are C structs**, and hand-marshaling
  those across the JS/WASM boundary via Emscripten's raw `ccall`/heap-offset
  API would mean keeping a second, unverifiable copy of every struct's exact
  field layout in JS. `wasm_bridge.cpp` instead wraps the existing bridge
  behind an Embind (`emscripten/bind.h`) binding, which generates that
  marshaling automatically and safely.

## 1. Install Emscripten

```
git clone https://github.com/emscripten-core/emsdk.git
cd emsdk
./emsdk install latest
./emsdk activate latest
source ./emsdk_env.sh   # needed in every new shell before the steps below
```

## 2. Build OpenCV for WASM

No prebuilt SDK exists for this the way there is for Android -- build it
from source, matching the version used elsewhere in this repo (check
`docs/BUILD.md`/the Android build for the current pinned version; 4.13.0 at
the time this was written):

```
git clone --branch 4.13.0 --depth 1 https://github.com/opencv/opencv.git opencv-src
mkdir opencv-wasm-build opencv-wasm-install
cd opencv-wasm-build
emcmake cmake ../opencv-src -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=../opencv-wasm-install \
  -DCPU_BASELINE='' -DCPU_DISPATCH='' \
  -DCV_ENABLE_INTRINSICS=OFF \
  -DWITH_PTHREADS_PF=OFF \
  -DWITH_PROTOBUF=OFF -DBUILD_PROTOBUF=OFF \
  -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTS=OFF -DBUILD_PERF_TESTS=OFF \
  -DBUILD_EXAMPLES=OFF -DBUILD_DOCS=OFF -DBUILD_ANDROID_EXAMPLES=OFF \
  -DBUILD_opencv_apps=OFF -DBUILD_opencv_calib3d=OFF -DBUILD_opencv_dnn=OFF \
  -DBUILD_opencv_features2d=OFF -DBUILD_opencv_flann=ON -DBUILD_opencv_gapi=OFF \
  -DBUILD_opencv_ml=ON -DBUILD_opencv_photo=OFF -DBUILD_opencv_imgcodecs=ON \
  -DBUILD_opencv_highgui=ON -DBUILD_opencv_shape=OFF -DBUILD_opencv_videoio=OFF \
  -DBUILD_opencv_videostab=OFF -DBUILD_opencv_superres=OFF -DBUILD_opencv_stitching=OFF \
  -DBUILD_opencv_java=OFF -DBUILD_opencv_js=OFF -DBUILD_opencv_python2=OFF -DBUILD_opencv_python3=OFF \
  -DWITH_1394=OFF -DWITH_ADE=OFF -DWITH_VTK=OFF -DWITH_EIGEN=OFF \
  -DWITH_FFMPEG=OFF -DWITH_GSTREAMER=OFF -DWITH_GTK=OFF -DWITH_GTK_2_X=OFF \
  -DWITH_IPP=OFF -DWITH_AVIF=OFF -DWITH_JASPER=OFF -DWITH_WEBP=OFF \
  -DWITH_OPENEXR=OFF -DWITH_OPENJPEG=OFF -DWITH_OPENGL=OFF -DWITH_OPENVX=OFF \
  -DWITH_OPENNI=OFF -DWITH_OPENNI2=OFF -DWITH_TBB=OFF -DWITH_TIFF=OFF \
  -DWITH_V4L=OFF -DWITH_OPENCL=OFF -DWITH_OPENCL_SVM=OFF \
  -DWITH_OPENCLAMDFFT=OFF -DWITH_OPENCLAMDBLAS=OFF -DWITH_GPHOTO2=OFF \
  -DWITH_LAPACK=OFF -DWITH_ITT=OFF -DWITH_QUIRC=OFF \
  -DWITH_JPEG=ON -DWITH_PNG=ON -DWITH_ZLIB=ON
ninja install -j$(nproc)
```

Notes on the less obvious flags, from what actually failed while getting
this working the first time:

- **`-DCV_ENABLE_INTRINSICS=OFF` is required**, or the build fails with
  `always_inline function 'wasm_v128_load' requires target feature
  'simd128'`. OpenCV's WASM SIMD intrinsics path needs a matching
  `-msimd128` compiler flag that isn't set by default; easier to disable the
  intrinsics path entirely (matches `build_js.py`'s own default -- SIMD
  there is opt-in via its `--simd` flag, which this skips).
- **`-DWITH_PTHREADS_PF=OFF`**: real OS threads under WASM need
  `SharedArrayBuffer`, which needs `Cross-Origin-Opener-Policy`/
  `Cross-Origin-Embedder-Policy` response headers -- GitHub Pages is a plain
  static host and can't set those. Single-threaded avoids the whole problem.
- **`-DWITH_PROTOBUF=OFF -DBUILD_PROTOBUF=OFF` is required**, or the
  *install* step (not the build) succeeds but writes a broken
  `OpenCVModules.cmake` that references `liblibprotobuf.a` -- a file that
  was never actually built because `dnn` (protobuf's only real consumer
  here) is disabled. Without this flag, anything that later does
  `find_package(OpenCV)` against this install fails immediately.

## 3. Build the OpenCFU WASM module

```
cd native/opencfu_core/wasm
emcmake cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DOpenCV_DIR=<path-to-opencv-wasm-install>/lib/cmake/opencv4
cmake --build build
cp build/opencfu_mobile.js build/opencfu_mobile.wasm ../../../web/opencfu/
```

## 4. Sanity-check the module before trusting it in the app

The module doesn't need a browser to run -- Emscripten bundles Node, and
`opencfu_mobile.js` loads under it directly if relinked with
`-sENVIRONMENT=web,node` (the checked-in build is `-sENVIRONMENT=web`-only,
smaller and stricter for production; add `,node` only for this kind of local
check, on a throwaway relink, not the committed artifact). A real end-to-end
check -- write a real plate photo and the bundled classifier
(`assets/opencfu/data/trainedClassifier.xml`) into the module's virtual
filesystem via `Module.FS.writeFile()`, call `Module.analyze(...)` (see
`wasm_bridge.cpp`'s `EMSCRIPTEN_BINDINGS` block for the exact signature) --
is a far stronger signal than "it compiled", and is how this was actually
validated before ever being wired into the app (no browser was available
while writing this).

One thing that isn't safe to skip: Embind's `register_vector`-typed fields
(`colonies`, `maskPointsX`, `maskPointsY` on the returned `WasmResult`) are
WASM-heap-backed and need an explicit `.delete()` after reading their data
out, or repeated analyses over a session leak memory -- individual
`value_object` entries (a single colony, the result itself) don't need this.
See `web/opencfu/opencfu_web_bridge.js`, which already does this.

## 5. What still needs a real browser

Loading `opencfu_mobile.js` via a dynamically-injected `<script>` tag (see
`opencfu_web_bridge.js`'s `loadModule()`) and the `dart:js_interop` calling
convention in `lib/services/opencfu_engine_web.dart` are both standard,
well-established patterns, but neither was ever exercised in an actual
browser before this shipped -- there wasn't one available. If counting
doesn't work on a real deploy, open the browser console first; the most
likely failure points are exactly those two, not the analysis logic itself
(which was thoroughly exercised per step 4).

**Confirmed bug, already fixed, from the first real deploy**:
`opencfu_mobile.js` 404'd on GitHub Pages (a non-root base href) because
`loadModule()` read `document.currentScript` *inside* its async callback to
find its own folder. That property is only valid synchronously, during a
script's own top-level execution -- by the time `loadModule()` actually ran
(async, triggered by the operator's first capture, long after
`opencfu_web_bridge.js` itself had finished its initial synchronous run),
`document.currentScript` was `null`, silently collapsing the resolved path
to just `opencfu_mobile.js` relative to the page root instead of the
`opencfu/` folder it's actually in. Fixed by capturing the script's URL once
at top-level synchronous execution time and reusing that stored value later
-- see the top of `opencfu_web_bridge.js`. Exactly the class of bug flagged
above as the highest-risk unverified piece; if something like this happens
again, suspect the same pattern (a browser-only API read from the wrong
execution context) before suspecting the analysis logic.

**Second confirmed bug, from the second real deploy** (after the 404 above
was fixed): analysis failed with `TypeError: Failed to execute 'decode' on
'TextDecoder': The provided ArrayBuffer value must not be resizable`. Root
cause: `ALLOW_MEMORY_GROWTH=1` (needed since a plate photo's decoded size
isn't known upfront) defaults, in this Emscripten version, to backing
growable memory with a JS *resizable* `ArrayBuffer` whenever the browser
supports one (current Chrome does) -- but the browser's native
`TextDecoder.decode()` currently refuses views onto resizable
`ArrayBuffer`s, and Emscripten uses `TextDecoder` internally to marshal
`std::string` fields (`WasmResult::errorMessage`) back to JS. This
specifically bit the *error* path -- a short/empty `errorMessage` (the
success case) stays under Emscripten's own no-`TextDecoder` fast path for
tiny strings, but any real error message is long enough to hit it, meaning
this bug was actively hiding whatever the real underlying error was.
Node's `TextDecoder` doesn't enforce this browser-specific restriction, so
this one could not be reproduced or confirmed fixed the same way as the
first bug (step 4's Node-based check exercises the analysis logic
correctly regardless, but not this specific browser/TextDecoder
interaction) -- fixed based on tracing Emscripten's own source
(`runtime_common.js`'s `getMemoryBuffer()`) to find `GROWABLE_ARRAYBUFFERS`,
the setting controlling whether the resizable-buffer path is ever taken at
all, and confirmed only by the user's real deploy. `-sTEXTDECODER=0`
(disable `TextDecoder` entirely) would have been the more direct fix but
isn't accepted by this Emscripten version (`TEXTDECODER must be either 1 or
2`); `-sGROWABLE_ARRAYBUFFERS=0` forces the older detach-and-replace growth
strategy instead, which was never resizable to begin with, sidestepping the
incompatibility at its source rather than working around its symptom.
