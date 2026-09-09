#!/usr/bin/env sh
printf '%s\n' "$*" >> "$HOME/mirror-calls"
sleep 0.35
printf '%s\n' "$*" >> "$HOME/mirror-done"
case "$*" in *every-2) printf 'simulated preparation failure\n' >&2; exit 1 ;; esac
