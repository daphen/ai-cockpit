#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d /tmp/cockpit-image-paste.XXXXXX)
pid=""
cleanup() {
  if [[ -n "$pid" ]]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
  rm -rf "$tmp"
}
trap cleanup EXIT
mkdir -m 700 "$tmp/runtime"
mkdir -p "$tmp/home/bin" "$tmp/home/.cache/heidr-pastes"
printf 'existing screenshot\n' > "$tmp/home/.cache/heidr-pastes/img2.png"
sed "s|%h|$tmp/home|g" systemd/heidr-pastes.conf > "$tmp/home/expiry.conf"
cp qs-shell/*.qml "$tmp/"
cp "${1:-qs-shell/Rail.qml}" "$tmp/Rail.qml"
cp test/image-paste.qml "$tmp/shell.qml"
printf '' > "$tmp/home/transfers"
cat > "$tmp/home/bin/transport" <<'PY'
#!/usr/bin/env python3
import base64, os, pathlib, shutil, sys
home = pathlib.Path(os.environ['HOME'])
name = pathlib.Path(sys.argv[0]).name
png = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a1S0AAAAASUVORK5CYII=')
if name == 'wl-paste':
    if '--list-types' in sys.argv:
        print('text/plain' if (home/'text-mode').exists() else 'image/png')
    else:
        sys.stdout.buffer.write(png)
elif name == 'ssh':
    assert sys.argv[-1] == 'mkdir -p "/home/david_karlsson_lovable_dev/.cache/heidr-pastes"', sys.argv
elif name == 'scp':
    source, target = sys.argv[-2:]
    assert target == 'david_karlsson_lovable_dev@paste-test.invalid:/home/david_karlsson_lovable_dev/.cache/heidr-pastes/', target
    source = pathlib.Path(source)
    assert source.parent == home/'.cache/heidr-pastes', source
    assert source.read_bytes() == png, 'image content changed'
    if source.name == 'img3.png':
        assert (source.parent/'img2.png').read_text() == 'existing screenshot\n', 'existing screenshot overwritten'
    remote = home/'received'
    remote.mkdir(exist_ok=True)
    shutil.copyfile(source, remote/source.name)
    with (home/'transfers').open('a') as f:
        f.write(str(source)+'\n')
PY
chmod +x "$tmp/home/bin/transport"
for command in wl-paste ssh scp; do ln -s transport "$tmp/home/bin/$command"; done
env -u WAYLAND_DISPLAY HOME="$tmp/home" XDG_RUNTIME_DIR="$tmp/runtime" PATH="$tmp/home/bin:$PATH" \
  COCKPIT_VM_USER=david_karlsson_lovable_dev COCKPIT_VM_HOST=paste-test.invalid \
  QT_QPA_PLATFORM=offscreen QML_IMPORT_PATH="$HOME/.local/share/qml" \
  qs -p "$tmp" >"$tmp/output" 2>&1 &
pid=$!
for _ in $(seq 1 100); do
  grep -qE 'PASS:|ERROR|Error:' "$tmp/output" && break
  sleep 0.1
done
if grep -E 'ERROR|Error:' "$tmp/output"; then exit 1; fi
grep 'PASS:' "$tmp/output"
cmp "$tmp/home/received/img3.png" "$tmp/home/received/img4.png"
cmp "$tmp/home/received/img4.png" "$tmp/home/.cache/heidr-pastes/img4.png"
cmp "$tmp/home/received/img3.png" "$tmp/home/.cache/heidr-pastes/img5.png"
cmp "$tmp/home/received/img3.png" "$tmp/home/lovbox/cockpit/project/.heidr-pastes/img1.png"
[[ ! -e "$tmp/home/.cache/heidr-pastes/img2.png" && ! -e "$tmp/home/.cache/heidr-pastes/img3.png" ]]
[[ ! -e "$tmp/home/work" ]]
