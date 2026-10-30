# ==============================================================================
# CMakeLists.txt for PanelShift Core Engine (Android ARM64 / Adreno 710 target)
# ==============================================================================

# Minimum required version of CMake to process this file
cmake_minimum_required(VERSION 3.22.1)

# Project name definition
project(panelshift_core)

# Set C++ standard to C++17 required for modern OpenCV C++ API usage
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Point directly to your absolute machine path for the OpenCV Android SDK
set(OpenCV_DIR "C:/deps/opencv_android/sdk/native/jni")

# Find the OpenCV package using its configuration script provided in the SDK
# Find the OpenCV package using only essential modules
find_package(OpenCV REQUIRED COMPONENTS core imgproc)

# Print a status message to verify OpenCV integration during CMake configuration phase
message(STATUS "OpenCV library status:")
message(STATUS "    version: ${OpenCV_VERSION}")
message(STATUS "    libraries: ${OpenCV_LIBS}")
message(STATUS "    include path: ${OpenCV_INCLUDE_DIRS}")

# Create our shared library (.so) for the Dart FFI bridge
add_library(
        panelshift_core
        SHARED
        panelshift_core.cpp
)

# Find Android-specific system libraries required for logging and bitmap manipulation
find_library(log-lib log)
find_library(jnigraphics-lib jnigraphics)

# Link OpenCV libraries, Android system logging, and bitmap graphics handlers to our target
target_link_libraries(
        panelshift_core
        PRIVATE
        ${OpenCV_LIBS}
        ${log-lib}
        ${jnigraphics-lib}
)

# Include directories for header resolution
target_include_directories(
        panelshift_core
        PRIVATE
        ${OpenCV_INCLUDE_DIRS}
)