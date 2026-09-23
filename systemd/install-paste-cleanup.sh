#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
d="$HOME/.cache/heidr-pastes"
mkdir -p "$d"
(
  exec 9<>"$d/.sequence"
  flock 9
  if [[ ! -s "$d/.sequence" ]]; then
    n=$(find "$d" -maxdepth 1 -printf '%f\n' | grep -oE '^img[0-9]+' | cut -c4- | sort -n | tail -n1) || n=0
    printf '%s\n' "${n:-0}" > "$d/.sequence"
  fi
)
install -Dm644 heidr-pastes.conf "$HOME/.config/user-tmpfiles.d/heidr-pastes.conf"
for unit in cockpit-paste-clean.service cockpit-paste-clean.timer; do
  install -Dm644 "$unit" "$HOME/.config/systemd/user/$unit"
done
systemctl --user daemon-reload
systemctl --user enable --now cockpit-paste-clean.timer
systemctl --user start cockpit-paste-clean.service
