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

# libghostty-vt: dev builds fetch + `zig build` it (needs network); nix/reproducible
# builds link the prebuilt vendored lib in vendor/ (-DHEIDR_VENDORED_GHOSTTY=ON).
option(HEIDR_VENDORED_GHOSTTY "Link the prebuilt vendored libghostty-vt instead of FetchContent" OFF)
if(HEIDR_VENDORED_GHOSTTY)
  # Installed libs resolve their siblings (libghostty-vt, the impl lib) from their
  # own dir; Qt is reused from the already-loaded quickshell process.
  set(CMAKE_INSTALL_RPATH "$ORIGIN")
  add_library(ghostty-vt SHARED IMPORTED)
  # The real object (not the .so / .so.0 symlinks) — installing a symlink renamed
  # to its own target yields a reflexive symlink that nix rejects.
  set(_ghostty_so "${CMAKE_SOURCE_DIR}/vendor/libghostty-vt/lib/libghostty-vt.so.0.1.0")
  set_target_properties(ghostty-vt PROPERTIES
    IMPORTED_LOCATION "${_ghostty_so}"
    INTERFACE_INCLUDE_DIRECTORIES "${CMAKE_SOURCE_DIR}/vendor/libghostty-vt/include")
else()
  include(FetchContent)
  FetchContent_Declare(ghostty
    GIT_REPOSITORY https://github.com/ghostty-org/ghostty.git
    GIT_TAG main
  )
  FetchContent_MakeAvailable(ghostty)
endif()

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

# Install rules (used by the nix flake; -DHEIDR_VENDORED_GHOSTTY=ON). cmake rewrites
# the install rpath to $ORIGIN, so the module dir is self-contained + build-path-free.
if(HEIDR_VENDORED_GHOSTTY)
  install(TARGETS heidr_term heidr_termplugin LIBRARY DESTINATION qml/Heidr)
  install(DIRECTORY ${CMAKE_BINARY_DIR}/qml/Heidr/ DESTINATION qml/Heidr
          FILES_MATCHING PATTERN "qmldir" PATTERN "*.qmltypes")
  install(FILES ${_ghostty_so} DESTINATION qml/Heidr RENAME libghostty-vt.so.0)
  install(DIRECTORY ${CMAKE_SOURCE_DIR}/qs-shell DESTINATION share/heidr)
endif()
