# Spike: prove libghostty-vt can drive a terminal render inside a Qt6 QQuickItem,
# AND that the item can be imported as a QML plugin by an external app (Quickshell).
# Build:
#   nix-shell --run 'cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j'
# Run standalone:   ./run.sh
# Run inside qs:     ./run-qs.sh
cmake_minimum_required(VERSION 3.21)
project(heidr_term_spike LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 REQUIRED COMPONENTS Core Gui Quick Qml)
qt_standard_project_setup(REQUIRES 6.5)

# libghostty-vt: FetchContent delegates to `zig build -Demit-lib-vt` (root CMakeLists).
include(FetchContent)
FetchContent_Declare(ghostty
  GIT_REPOSITORY https://github.com/ghostty-org/ghostty.git
  GIT_TAG main
)
FetchContent_MakeAvailable(ghostty)

# Reusable QML module `Heidr` exposing the TermView item. Emitted as an importable
# module under build/qml/Heidr (qmldir + plugin), so any QML runtime — our own exe
# OR Quickshell (`qs`) — can `import Heidr` given QML_IMPORT_PATH=build/qml.
qt_add_library(heidr_term SHARED)
qt_add_qml_module(heidr_term
  URI Heidr
  VERSION 1.0
  OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/qml/Heidr
  SOURCES TermView.cpp TermView.h
)
target_link_libraries(heidr_term PRIVATE Qt6::Quick Qt6::Gui ghostty-vt util)

# Standalone spike exe: hosts its own window (Main.qml) and imports Heidr in-process.
qt_add_executable(heidr-term-spike main.cpp)
qt_add_qml_module(heidr-term-spike URI HeidrApp VERSION 1.0 QML_FILES Main.qml)
target_link_libraries(heidr-term-spike PRIVATE heidr_term Qt6::Quick Qt6::Gui)
