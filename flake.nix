{
  description = "Cockpit: nvim terminal and agentd rail in one Quickshell window";

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
      # libghostty-vt so the nix build stays offline/reproducible. The legacy Heidr QML ABI
      # module, its impl lib, and the native lib all land in one dir with an
      # $ORIGIN rpath so they resolve each other at runtime.
      plugin = pkgs.stdenv.mkDerivation {
        pname = "cockpit-termplugin";
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

      cockpit = pkgs.writeShellApplication {
        name = "cockpit-qs";
        runtimeInputs = [ pkgs.quickshell pkgs.procps pkgs.coreutils pkgs.util-linux ];
        text = ''
          # QsLib (the live dotfiles design system) wins; the legacy Heidr plugin module
          # is appended so `import Heidr` resolves.
          # Native Wayland — otherwise Qt falls back to XWayland (xcb), which
          # renders differently AND lets the window hold an X11 keyboard grab that
          # swallows the compositor's keybinds.
          export QT_QPA_PLATFORM=wayland
          export QML2_IMPORT_PATH="$HOME/.local/share/qml:${plugin}/qml''${QML2_IMPORT_PATH:+:$QML2_IMPORT_PATH}"
          export COCKPIT_ASSET_DIR="${plugin}/share/cockpit/assets"

          for v in SCOPE NEW_CWD AGENTD_SOCKS AGENTD_SOCK TITLE FORCE_NEW DEV; do
            cv="COCKPIT_$v"; hv="HEIDR_$v"
            if [ -n "''${!cv:-}" ]; then export "$hv=''${!cv}"
            elif [ -n "''${!hv:-}" ]; then export "$cv=''${!hv}"
            fi
          done

          shell="${plugin}/share/cockpit/qs-shell"
          if [ -n "''${COCKPIT_DEV:-}" ] && [ -d "$COCKPIT_DEV/qs-shell" ]; then shell="$COCKPIT_DEV/qs-shell"; fi

          _u=$(id -un)
          export PATH="/etc/profiles/per-user/$_u/bin:$HOME/.nix-profile/bin:$PATH:/run/current-system/sw/bin"

          if [ -z "''${COCKPIT_AGENTD_SOCKS:-}" ] && [ -z "''${COCKPIT_AGENTD_SOCK:-}" ]; then
            ws=$(niri msg --json workspaces 2>/dev/null | ${pkgs.jq}/bin/jq -r '.[] | select(.is_focused) | .name // empty' 2>/dev/null || true)
            case "''${ws:-}" in
              lovable*)
                scopes="lovable work"
                export COCKPIT_SCOPE="''${COCKPIT_SCOPE:-lovable}"
                export COCKPIT_NEW_CWD="''${COCKPIT_NEW_CWD:-$HOME/work/lovable}"
                ;;
              *)
                scopes="personal"
                export COCKPIT_SCOPE="''${COCKPIT_SCOPE:-personal}"
                export COCKPIT_NEW_CWD="''${COCKPIT_NEW_CWD:-$HOME/personal}"
                ;;
            esac
            socks=""
            for sc in $scopes; do socks="''${socks:+$socks,}''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/agentd-$sc.sock"; done
            export COCKPIT_AGENTD_SOCKS="$socks"
          fi

          if [ "''${COCKPIT_SCOPE:-lovable}" = "personal" ]; then
            export COCKPIT_TITLE="''${COCKPIT_TITLE:-cockpit-qs · private}"
            mirror="$HOME/.local/state/cockpit/private-shell-pkg"
            mkdir -p "$mirror"; rm -f "$mirror"/*.qml
            for f in "$shell"/*.qml; do ln -sf "$f" "$mirror/$(basename "$f")"; done
            shell="$mirror"
          else
            export COCKPIT_TITLE="''${COCKPIT_TITLE:-cockpit-qs · lovable}"
          fi

          for v in SCOPE NEW_CWD AGENTD_SOCKS AGENTD_SOCK TITLE FORCE_NEW DEV; do
            cv="COCKPIT_$v"; hv="HEIDR_$v"
            [ -n "''${!cv:-}" ] && export "$hv=''${!cv}"
          done
          if [ -z "''${COCKPIT_FORCE_NEW:-}" ] && command -v niri >/dev/null 2>&1 \
             && niri msg --json windows 2>/dev/null | ${pkgs.jq}/bin/jq -e --arg t "$COCKPIT_TITLE" '.[]|select(.title==$t)' >/dev/null 2>&1; then
            niri msg action focus-window --id "$(niri msg --json windows | ${pkgs.jq}/bin/jq -r --arg t "$COCKPIT_TITLE" '.[]|select(.title==$t)|.id' | head -1)" 2>/dev/null || true
            exit 0
          fi
          exec qs -p "$shell"
        '';
      };
    in {
      packages.${system} = { inherit plugin; cockpit-qs = cockpit; heidr-qs = cockpit; default = cockpit; };
      apps.${system}.default = { type = "app"; program = "${cockpit}/bin/cockpit-qs"; };
      devShells.${system}.default = import ./shell.nix { inherit pkgs; };
    };
}
