# CMake build for the OpenCFU mobile native core.
#
# Produces the shared library `libopencfu_mobile.so` (Android) that the Dart FFI
# layer loads. It compiles the vendored OpenCFU processor layer plus the C ABI
# bridge, and links against OpenCV.
#
# OpenCV is NOT vendored here (it is large and platform-specific). Provide it via
# the OpenCV Android SDK and point CMake at it with -DOpenCV_DIR=<sdk>/sdk/native/jni
# (the Android Gradle wiring passes this through from the `OpenCV_DIR` project
# property / gradle.properties). See native/opencfu_core/README.md.

cmake_minimum_required(VERSION 3.18)
project(opencfu_mobile LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 14)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# --- OpenCV -----------------------------------------------------------------
# Allow the caller to pass OpenCV_DIR; otherwise rely on find_package search.
find_package(OpenCV REQUIRED COMPONENTS core imgproc imgcodecs ml)

# --- Sources ----------------------------------------------------------------
set(CORE_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/src)

file(GLOB PROCESSOR_SOURCES ${CORE_ROOT}/processor/src/*.cpp)

add_library(opencfu_mobile SHARED
    ${CORE_ROOT}/opencfu_mobile_bridge.cpp
    ${PROCESSOR_SOURCES}
)

target_include_directories(opencfu_mobile PRIVATE
    ${CORE_ROOT}
    ${CORE_ROOT}/processor/headers
    ${OpenCV_INCLUDE_DIRS}
)

target_link_libraries(opencfu_mobile PRIVATE ${OpenCV_LIBS})

if(ANDROID)
    # OpenCV's Android SDK links a static libc++; keep our library consistent.
    target_link_libraries(opencfu_mobile PRIVATE log)
endif()

# Export the C ABI symbols even under -fvisibility=hidden builds.
target_compile_definitions(opencfu_mobile PRIVATE OPENCFU_MOBILE_EXPORTS)
