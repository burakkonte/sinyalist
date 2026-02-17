// =============================================================================
// SINYALIST — JNI Bridge Compilation Unit
// =============================================================================
// This file exists solely to compile the header-only SeismicDetector
// into a shared library (.so) for the Android NDK build.
// All logic lives in seismic_detector.hpp.
// =============================================================================

#define __ANDROID__ 1
#include "seismic_detector.hpp"
