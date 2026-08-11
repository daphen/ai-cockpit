# Dev shell for the spike. wrapQtAppsHook + qtbase's setup hook put Qt6 on
# CMAKE_PREFIX_PATH correctly (the thing an ad-hoc `nix shell` was missing).
#   nix-shell --run 'cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j'
#   nix-shell --run ./build/heidr-term-spike
{ pkgs ? import <nixpkgs> { } }:
pkgs.mkShell {
  nativeBuildInputs = [
    pkgs.cmake
    pkgs.ninja
    pkgs.zig            # libghostty-vt is built via `zig build -Demit-lib-vt`
    pkgs.pkg-config
    pkgs.qt6.wrapQtAppsHook
  ];
  buildInputs = [
    pkgs.qt6.qtbase
    pkgs.qt6.qtdeclarative
    pkgs.qt6.qtwayland   # wayland QPA plugin, for running on niri
  ];
}
