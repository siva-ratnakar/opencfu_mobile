# CMake build for the OpenCFU web (WebAssembly) core.
#
# Produces opencfu_mobile.js + opencfu_mobile.wasm, loaded by
# lib/services/opencfu_engine_web.dart via dart:js_interop. Deliberately a
# separate CMakeLists.txt from ../CMakeLists.txt (Android/iOS), sharing only
# the vendored sources under ../src -- this experimental web target can't
# accidentally regress the already-working native builds by being edited.
#
# See wasm/README.md for how the Emscripten-cross-compiled OpenCV dependency
# (core, imgproc, imgcodecs, ml) was itself built; there is no prebuilt SDK
# for it the way there is for Android.
#
# Build with (from this directory, with an activated Emscripten SDK):
#   emcmake cmake -B build -DCMAKE_BUILD_TYPE=Release \
#     -DOpenCV_DIR=<opencv-wasm-install>/lib/cmake/opencv4
#   cmake --build build

cmake_minimum_required(VERSION 3.18)
project(opencfu_mobile_wasm LANGUAGES CXX)

if(NOT EMSCRIPTEN)
    message(FATAL_ERROR "wasm/CMakeLists.txt is Emscripten-only -- configure with emcmake.")
endif()

# 17, not the 14 the Android/iOS build uses -- Emscripten's own bind.h
# (Embind, used by wasm_bridge.cpp) needs std::optional.
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(OpenCV REQUIRED COMPONENTS core imgproc imgcodecs ml)

set(CORE_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/../src)
file(GLOB PROCESSOR_SOURCES ${CORE_ROOT}/processor/src/*.cpp)

add_executable(opencfu_mobile
    ${CMAKE_CURRENT_SOURCE_DIR}/wasm_bridge.cpp
    ${CORE_ROOT}/opencfu_mobile_bridge.cpp
    ${PROCESSOR_SOURCES}
)

target_include_directories(opencfu_mobile PRIVATE
    ${CORE_ROOT}
    ${CORE_ROOT}/processor/headers
    ${OpenCV_INCLUDE_DIRS}
)

target_link_libraries(opencfu_mobile PRIVATE ${OpenCV_LIBS})
target_compile_definitions(opencfu_mobile PRIVATE OPENCFU_MOBILE_EXPORTS)

# -fexceptions: the bridge's try/catch around the whole analysis (see
# opencfu_mobile_bridge.cpp) needs C++ exceptions enabled -- Emscripten
# disables them by default for code size/speed.
# --bind: enables Embind (see wasm_bridge.cpp's EMSCRIPTEN_BINDINGS block).
# MODULARIZE + EXPORT_NAME: produces a factory function (OpenCfuModule())
# instead of writing to the global scope, so Dart can control exactly when
# and how the module loads.
# FORCE_FILESYSTEM: guarantees Module.FS is present -- the Dart caller writes
# the picked photo and the classifier XML files into the virtual filesystem
# through it before calling Module.analyze().
# ALLOW_MEMORY_GROWTH: a plate photo's decoded size isn't known upfront, and
# a fixed initial heap would risk an OOM abort on a large gallery import.
# ENVIRONMENT=web, USE_PTHREADS=0: single-threaded, browser-only. Threads
# would need SharedArrayBuffer, which needs cross-origin-isolation response
# headers GitHub Pages (a plain static host) cannot set.
target_compile_options(opencfu_mobile PRIVATE -fexceptions -O3)
target_link_options(opencfu_mobile PRIVATE
    -fexceptions
    -O3
    --bind
    -sMODULARIZE=1
    -sEXPORT_NAME=OpenCfuModule
    -sFORCE_FILESYSTEM=1
    "-sEXPORTED_RUNTIME_METHODS=[\"FS\"]"
    -sALLOW_MEMORY_GROWTH=1
    -sENVIRONMENT=web
    -sUSE_PTHREADS=0
    # Growable WASM memory (ALLOW_MEMORY_GROWTH above) defaults
    # (GROWABLE_ARRAYBUFFERS=1) to backing itself with a JS "resizable"
    # ArrayBuffer whenever the browser supports one (current Chrome does) --
    # but the browser's native TextDecoder.decode() currently refuses views
    # onto resizable ArrayBuffers ("The provided ArrayBuffer value must not
    # be resizable"), and Emscripten uses TextDecoder internally to pull
    # std::string fields (e.g. WasmResult::errorMessage) back out to JS.
    # Tried disabling TextDecoder entirely instead (-sTEXTDECODER=0), but
    # this Emscripten version no longer accepts that value -- forcing the
    # classic non-resizable, detach-and-replace growth strategy here avoids
    # the incompatibility at its source regardless.
    -sGROWABLE_ARRAYBUFFERS=0
)
