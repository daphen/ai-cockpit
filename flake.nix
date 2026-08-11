{
  description = "Heidr — cockpit: nvim (libghostty terminal) + agentd rail in one Quickshell window";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  # Same quickshell the system runs (v0.3.0). When consumed from ~/nixos both
  # inputs `follows` the system's, so the plugin's Qt == the running qs's Qt.
  inputs.quickshell = {
    url = "github:quickshell-mirror/quickshell/v0.3.0";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, quickshell }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; overlays = [ quickshell.overlays.default ]; };
      qt = pkgs.qt6;

      # The C++ QML plugin (the libghostty terminal). Built against the vendored
      # libghostty-vt so the nix build stays offline/reproducible. The Heidr qml
      # module, its impl lib, and the native lib all land in one dir with an
      # $ORIGIN rpath so they resolve each other at runtime.
      plugin = pkgs.stdenv.mkDerivation {
        pname = "heidr-termplugin";
        version = "0.1.0";
        # Exclude local build dirs — a stale build/CMakeCache.txt (absolute paths
        # from the dev tree) makes nix's cmake abort with a source-mismatch.
        src = pkgs.lib.cleanSourceWith {
          src = ./.;
          filter = path: type:
            let b = baseNameOf (toString path); in
            !(type == "directory" && (b == "build" || b == "build-vendored" || b == "result"));
        };
        nativeBuildInputs = [ pkgs.cmake pkgs.ninja qt.wrapQtAppsHook qt.qtdeclarative pkgs.patchelf ];
        buildInputs = [ qt.qtbase qt.qtdeclarative qt.qtwayland ];
        dontWrapQtApps = true;   # we ship a .so module, not an executable
        cmakeFlags = [ "-DHEIDR_VENDORED_GHOSTTY=ON" "-DCMAKE_BUILD_TYPE=Release" ];
        # CMake install() rules (guarded by the vendored flag) place the module +
        # libs in $out/qml/Heidr with an $ORIGIN rpath and copy qs-shell.
      };

      heidr = pkgs.writeShellApplication {
        name = "heidr-qs";   # distinct from the old nvim-rail `heidr` script (coexist)
        runtimeInputs = [ pkgs.quickshell pkgs.procps pkgs.coreutils pkgs.util-linux ];
        text = ''
          # QsLib (the live dotfiles design system) wins; the Heidr plugin module
          # is appended so `import Heidr` resolves.
          export QML2_IMPORT_PATH="$HOME/.local/share/qml:${plugin}/qml''${QML2_IMPORT_PATH:+:$QML2_IMPORT_PATH}"

          # Dev: HEIDR_DEV=/path/to/repo runs the working-tree rail (hot-reload)
          # against the installed plugin. Otherwise use the packaged snapshot.
          shell="${plugin}/share/heidr/qs-shell"
          if [ -n "''${HEIDR_DEV:-}" ] && [ -d "$HEIDR_DEV/qs-shell" ]; then
            shell="$HEIDR_DEV/qs-shell"
          fi

          # Single-instance: focus the existing window if one is mapped (niri),
          # else launch. Heidr connects to the already-running agentd; no daemon
          # of its own to spawn.
          export PATH="/run/current-system/sw/bin:$PATH"
          if command -v niri >/dev/null 2>&1 && niri msg --json windows 2>/dev/null | grep -q '"title": *"heidr-qs"'; then
            niri msg action focus-window --id "$(niri msg --json windows | ${pkgs.jq}/bin/jq -r '.[]|select(.title=="heidr-qs")|.id' | head -1)" 2>/dev/null || true
            exit 0
          fi
          exec qs -p "$shell"
        '';
      };
    in {
      packages.${system} = { inherit plugin; heidr-qs = heidr; default = heidr; };
      apps.${system}.default = { type = "app"; program = "${heidr}/bin/heidr-qs"; };
      devShells.${system}.default = import ./shell.nix { inherit pkgs; };
    };
}
