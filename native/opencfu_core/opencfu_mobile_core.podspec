Pod::Spec.new do |s|
  s.name             = 'opencfu_mobile_core'
  s.version          = '1.0.0'
  s.summary          = 'Vendored OpenCFU processing core and dart:ffi C ABI bridge.'
  s.description      = <<-DESC
Compiles the vendored OpenCFU processor sources and the C ABI bridge
(opencfu_mobile_bridge.cpp) into the app so Dart's DynamicLibrary.process()
can find opencfu_mobile_analyze_image() at runtime. Android builds the same
sources via CMake instead (see native/opencfu_core/README.md).
                       DESC
  s.homepage         = 'https://github.com/qgeissmann/OpenCFU'
  s.license          = { :type => 'GPL-3.0-or-later' }
  s.author           = { 'OpenCFU Mobile' => 'noreply@example.invalid' }
  s.source           = { :path => '.' }
  s.platform         = :ios, '13.0'
  s.requires_arc     = false

  s.source_files        = 'src/*.{h,hpp,cpp}', 'src/processor/headers/*.hpp', 'src/processor/src/*.cpp'
  s.public_header_files = 'src/opencfu_mobile_bridge.hpp'

  # The official opencv2.framework, vendored via the community CocoaPods
  # wrapper. Ships core/imgproc/imgcodecs/ml etc. as one umbrella framework
  # (unlike the Android SDK's per-module aar), so no separate component list
  # is needed here the way native/opencfu_core/CMakeLists.txt has one.
  s.dependency 'OpenCV', '~> 4.3'

  s.pod_target_xcconfig = {
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++14',
    'CLANG_CXX_LIBRARY' => 'libc++',
    'HEADER_SEARCH_PATHS' => '$(PODS_TARGET_SRCROOT)/src',
    # Belt-and-braces alongside the __attribute__((visibility("default"))) on
    # opencfu_mobile_analyze_image() -- see opencfu_mobile_bridge.hpp.
    'GCC_SYMBOLS_PRIVATE_EXTERN' => 'NO',
  }
end
