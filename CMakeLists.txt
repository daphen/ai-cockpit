# Spike: prove librio (rio's embeddable terminal core) can drive a terminal render
# inside a Qt6 QQuickItem, AND that the item can be imported as a QML plugin by an
# external app (Quickshell).
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
find_package(Threads REQUIRED)
qt_standard_project_setup(REQUIRES 6.5)

# librio: PTY + VT state + a pulled render snapshot, as a static Rust lib with a C ABI
# (linked INTO the plugin, so nothing extra ships next to it).
#   -DRIO_LIBRARY=.../liblibrio.a -DRIO_INCLUDE_DIR=.../include
#       link a prebuilt (the nix flake builds it from the pinned rio source);
#   otherwise `cargo build -p librio` from RIO_SOURCE_DIR — a sibling ../rio checkout
#       when there is one, else a FetchContent clone of github.com/raphamorim/rio
#       (needs network + cargo; see shell.nix).
set(RIO_LIBRARY "" CACHE FILEPATH "Prebuilt liblibrio.a (skips the cargo build)")
set(RIO_INCLUDE_DIR "" CACHE PATH "Directory holding librio.h (with RIO_LIBRARY)")
set(RIO_SOURCE_DIR "" CACHE PATH "rio checkout to cargo-build librio from")
add_library(librio STATIC IMPORTED)
if(RIO_LIBRARY)
  if(NOT RIO_INCLUDE_DIR)
    message(FATAL_ERROR "RIO_LIBRARY needs RIO_INCLUDE_DIR")
  endif()
  set_target_properties(librio PROPERTIES
    IMPORTED_LOCATION "${RIO_LIBRARY}"
    INTERFACE_INCLUDE_DIRECTORIES "${RIO_INCLUDE_DIR}")
else()
  if(NOT RIO_SOURCE_DIR)
    if(EXISTS "${CMAKE_SOURCE_DIR}/../rio/librio/Cargo.toml")
      get_filename_component(RIO_SOURCE_DIR "${CMAKE_SOURCE_DIR}/../rio" ABSOLUTE)
    else()
      include(FetchContent)
      # rio has no CMakeLists at its root, so MakeAvailable only populates the source.
      FetchContent_Declare(rio
        GIT_REPOSITORY https://github.com/raphamorim/rio.git
        GIT_TAG main
      )
      FetchContent_MakeAvailable(rio)
      set(RIO_SOURCE_DIR "${rio_SOURCE_DIR}")
    endif()
  endif()
  message(STATUS "librio: cargo-building from ${RIO_SOURCE_DIR}")
  find_program(CARGO_EXECUTABLE cargo REQUIRED)
  set(_rio_target_dir "${CMAKE_BINARY_DIR}/librio-target")
  # rio's `librio` cargo profile: release, no LTO, unstripped → target/librio/.
  set(_rio_a "${_rio_target_dir}/librio/liblibrio.a")
  # Always re-run cargo (an up-to-date build is a fast no-op); BYPRODUCTS lets the
  # generator relink the plugin when the archive actually changed.
  add_custom_target(librio_cargo
    COMMAND "${CARGO_EXECUTABLE}" build -p librio --profile librio --target-dir "${_rio_target_dir}"
    BYPRODUCTS "${_rio_a}"
    WORKING_DIRECTORY "${RIO_SOURCE_DIR}"
    COMMENT "cargo build -p librio"
    VERBATIM)
  set_target_properties(librio PROPERTIES
    IMPORTED_LOCATION "${_rio_a}"
    INTERFACE_INCLUDE_DIRECTORIES "${RIO_SOURCE_DIR}/librio/include")
  add_dependencies(librio librio_cargo)
endif()
# What a Rust staticlib expects from the host toolchain on Linux.
set_property(TARGET librio APPEND PROPERTY INTERFACE_LINK_LIBRARIES Threads::Threads ${CMAKE_DL_LIBS} m)

# Installed libs resolve their siblings (the impl lib) from their own dir; Qt is
# reused from the already-loaded quickshell process.
set(CMAKE_INSTALL_RPATH "$ORIGIN")

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
target_link_libraries(heidr_term PRIVATE Qt6::Quick Qt6::Gui librio)

# Standalone spike exe: hosts its own window (Main.qml) and imports Heidr in-process.
qt_add_executable(heidr-term-spike main.cpp)
qt_add_qml_module(heidr-term-spike URI HeidrApp VERSION 1.0 QML_FILES Main.qml)
target_link_libraries(heidr-term-spike PRIVATE heidr_term Qt6::Quick Qt6::Gui)

# Install rules (used by the nix flake). cmake rewrites the install rpath to $ORIGIN,
# so the module dir is self-contained + build-path-free; librio is inside the impl lib.
install(TARGETS heidr_term heidr_termplugin LIBRARY DESTINATION qml/Heidr)
install(DIRECTORY ${CMAKE_BINARY_DIR}/qml/Heidr/ DESTINATION qml/Heidr
        FILES_MATCHING PATTERN "qmldir" PATTERN "*.qmltypes")
install(DIRECTORY ${CMAKE_SOURCE_DIR}/qs-shell DESTINATION share/cockpit)
install(DIRECTORY ${CMAKE_SOURCE_DIR}/assets DESTINATION share/cockpit)
