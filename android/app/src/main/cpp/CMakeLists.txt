cmake_minimum_required(VERSION 3.10.2)

project(panelshift_core)

# 1. Point OpenCV_DIR to the jni folder where OpenCVConfig.cmake resides
set(OpenCV_DIR "C:/deps/opencv_android/sdk/native/jni")

# 2. Find OpenCV package required for compilation
find_package(OpenCV REQUIRED)

# 3. Explicitly include OpenCV header search directories
include_directories(${OpenCV_INCLUDE_DIRS})

# Add your native C++ source file (residing in the same folder as CMakeLists.txt)
add_library(
        panelshift_core
        SHARED
        panelshift_core.cpp
)

# Find Android system libraries needed for logging and bitmap manipulation
find_library(
        log-lib
        log
)

find_library(
        bitmap-lib
        jnigraphics
)

# Link OpenCV modules and Android system libraries
target_link_libraries(
        panelshift_core
        ${OpenCV_LIBS}
        ${log-lib}
        ${bitmap-lib}
)