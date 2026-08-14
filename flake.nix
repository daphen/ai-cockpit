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
          # Native Wayland — otherwise Qt falls back to XWayland (xcb), which
          # renders differently AND lets the window hold an X11 keyboard grab that
          # swallows the compositor's keybinds.
          export QT_QPA_PLATFORM=wayland
          export QML2_IMPORT_PATH="$HOME/.local/share/qml:${plugin}/qml''${QML2_IMPORT_PATH:+:$QML2_IMPORT_PATH}"

          # Dev: HEIDR_DEV=/path/to/repo runs the working-tree rail (hot-reload)
          # against the installed plugin. Otherwise use the packaged snapshot.
          shell="${plugin}/share/heidr/qs-shell"
          if [ -n "''${HEIDR_DEV:-}" ] && [ -d "$HEIDR_DEV/qs-shell" ]; then
            shell="$HEIDR_DEV/qs-shell"
          fi

          # Per-mode identity: distinct title + qs config path, so a private and a work
          # cockpit run SIMULTANEOUSLY (Super+y cycles them via niri-jump-or-exec;
          # heidr-ipc routes to the focused one by title).
          if [ "''${HEIDR_SCOPE:-lovable}" = "personal" ]; then
            export HEIDR_TITLE="''${HEIDR_TITLE:-heidr-qs · private}"
            mirror="$HOME/.local/state/heidr/private-shell-pkg"
            mkdir -p "$mirror"; rm -f "$mirror"/*.qml
            for f in "$shell"/*.qml; do ln -sf "$f" "$mirror/$(basename "$f")"; done
            shell="$mirror"
          else
            export HEIDR_TITLE="''${HEIDR_TITLE:-heidr-qs · lovable}"
          fi

          # Single-instance PER MODE: focus this mode's existing window if one is mapped
          # (skipped by HEIDR_FORCE_NEW=1 — the Super+Shift+Y always-spawn path). Heidr
          # connects to the already-running agentd; no daemon of its own to spawn.
          # Put the USER profile first so the wrapped `nvim` (with the full config)
          # wins over the system's unwrapped nvim; keep system bin as a fallback so
          # qs/tools still resolve when launched from a minimal niri env.
          _u=$(id -un)
          export PATH="/etc/profiles/per-user/$_u/bin:$HOME/.nix-profile/bin:$PATH:/run/current-system/sw/bin"

          # MODE by launch context (mirrors run-qs.sh): DEFAULT = PRIVATE, personal
          # scope only, everything on this machine. The lovable workspace is the
          # special case that wires the full work cockpit (lovable + VM work +
          # personal; ticket names win collisions). Previously this launcher set no
          # sockets at all, so the rail silently fell back to lovable-only.
          if [ -z "''${HEIDR_AGENTD_SOCKS:-}" ] && [ -z "''${HEIDR_AGENTD_SOCK:-}" ]; then
            ws=$(niri msg --json workspaces 2>/dev/null | ${pkgs.jq}/bin/jq -r '.[] | select(.is_focused) | .name // empty' 2>/dev/null || true)
            case "''${ws:-}" in
              lovable*)
                scopes="lovable work"
                export HEIDR_SCOPE="''${HEIDR_SCOPE:-lovable}"
                export HEIDR_NEW_CWD="''${HEIDR_NEW_CWD:-$HOME/work/lovable}"
                ;;
              *)
                scopes="personal"
                export HEIDR_SCOPE="''${HEIDR_SCOPE:-personal}"
                export HEIDR_NEW_CWD="''${HEIDR_NEW_CWD:-$HOME/personal}"
                ;;
            esac
            socks=""
            for sc in $scopes; do socks="''${socks:+$socks,}''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/agentd-$sc.sock"; done
            export HEIDR_AGENTD_SOCKS="$socks"
          fi
          if [ -z "''${HEIDR_FORCE_NEW:-}" ] && command -v niri >/dev/null 2>&1 \
             && niri msg --json windows 2>/dev/null | ${pkgs.jq}/bin/jq -e --arg t "$HEIDR_TITLE" '.[]|select(.title==$t)' >/dev/null 2>&1; then
            niri msg action focus-window --id "$(niri msg --json windows | ${pkgs.jq}/bin/jq -r --arg t "$HEIDR_TITLE" '.[]|select(.title==$t)|.id' | head -1)" 2>/dev/null || true
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
