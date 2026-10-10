#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export COCKPIT_LINK_CAPTURE=$(mktemp /tmp/cockpit-link-style.XXXXXX.png)
log=$(mktemp /tmp/cockpit-link-style.XXXXXX.log)
trap 'rm -f "$COCKPIT_LINK_CAPTURE" "$log"' EXIT
bash test/session-landing.sh test/local-link-style.qml | tee "$log"
python3 - "$COCKPIT_LINK_CAPTURE" "$log" <<'PY'
import collections
import json
import sys
import subprocess

line = next(line for line in open(sys.argv[2]) if 'LINK_STYLE ' in line)
metadata = json.loads(line.split('LINK_STYLE ', 1)[1])
width, height = map(int, subprocess.check_output(['identify', '-format', '%w %h', sys.argv[1]]).split())
pixels = subprocess.check_output(['magick', sys.argv[1], '-depth', '8', 'rgba:-'])
expected = tuple(bytes.fromhex(metadata['color'].lstrip('#')))
for index, row in enumerate(metadata['rows']):
    crop = pixels[int(row['y']) * width * 4:min(height, int(row['y'] + row['height'])) * width * 4]
    colors = collections.Counter(tuple(crop[i:i+3]) for i in range(0, len(crop), 4) if crop[i+3] == 255 and any(crop[i:i+3]))
    actual, count = colors.most_common(1)[0]
    assert actual == expected, f'Link {index} rendered {actual}, expected theme color {expected}'
    assert count > 10, f'Link {index} has insufficient painted text'
print('PASS: all four rendered link types use the same theme color')
PY
