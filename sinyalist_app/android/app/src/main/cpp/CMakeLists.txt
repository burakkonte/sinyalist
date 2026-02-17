cmake_minimum_required(VERSION 3.22)
project(sinyalist_seismic LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Optimization flags for release: LTO, no exceptions (binary size), NEON SIMD
set(CMAKE_CXX_FLAGS_RELEASE "-O3 -flto -fno-exceptions -fno-rtti -DNDEBUG")
set(CMAKE_CXX_FLAGS_DEBUG "-O0 -g -DDEBUG")

# ARM NEON for float math acceleration (all modern Android devices)
if(CMAKE_ANDROID_ARCH_ABI STREQUAL "arm64-v8a")
    add_compile_options(-march=armv8-a+simd)
elseif(CMAKE_ANDROID_ARCH_ABI STREQUAL "armeabi-v7a")
    add_compile_options(-mfpu=neon -mfloat-abi=softfp)
endif()

add_library(sinyalist_seismic SHARED
    seismic_detector.hpp  # Header-only, but listed for IDE indexing
    seismic_jni_bridge.cpp
)

# Link against Android NDK libraries
find_library(log-lib log)
find_library(android-lib android)

target_link_libraries(sinyalist_seismic
    ${log-lib}
    ${android-lib}
)

target_include_directories(sinyalist_seismic PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
)
