#!/usr/bin/env python3
import os
from pathlib import Path
import subprocess
import tempfile
import time

source = Path(__file__).resolve().parents[1] / 'systemd'
with tempfile.TemporaryDirectory(prefix='cockpit-paste-expiry-') as directory:
    home = Path(directory)
    cache = home / '.cache/heidr-pastes'
    cache.mkdir(parents=True)
    now = time.time()
    for name, hours in [('img2.png', 25), ('img17.jpg', 23)]:
        path = cache / name
        path.write_text(name)
        os.utime(path, (now, now - hours * 3600))
    outside = home / 'unrelated.png'
    outside.write_text('keep')
    os.utime(outside, (now - 90000, now - 90000))
    (cache / 'external.png').symlink_to(outside)
    os.utime(cache / 'external.png', (now - 90000, now - 90000), follow_symlinks=False)
    tools = home / 'bin'
    tools.mkdir()
    systemctl = tools / 'systemctl'
    systemctl.write_text('#!/bin/sh\nexit 0\n')
    systemctl.chmod(0o755)
    env = dict(os.environ, HOME=str(home), PATH=str(tools) + ':' + os.environ['PATH'])
    subprocess.run(['bash', str(source / 'install-paste-cleanup.sh')], env=env, check=True)
    assert (cache / '.sequence').read_text().strip() == '17'
    os.utime(cache / '.sequence', (now - 90000, now - 90000))
    config = home / '.config/user-tmpfiles.d/heidr-pastes.conf'
    config.write_text(config.read_text().replace('%h', str(home)))
    subprocess.run(['systemd-tmpfiles', '--user', '--clean', str(config)], check=True)
    assert not (cache / 'img2.png').exists(), 'recent access prevented 24-hour expiry'
    assert (cache / 'img17.jpg').read_text() == 'img17.jpg', 'unexpired screenshot deleted'
    assert (cache / '.sequence').read_text().strip() == '17', 'counter expired'
    assert outside.read_text() == 'keep', 'cleanup escaped its cache'
    assert not (cache / 'external.png').is_symlink()
    (cache / 'img17.jpg').unlink()
    subprocess.run(['bash', str(source / 'install-paste-cleanup.sh')], env=env, check=True)
    assert (cache / '.sequence').read_text().strip() == '17', 'reinstall reset counter'
print('PASS: 24-hour mtime cutoff, recent reads, counter retention, safe symlinks, and installer reseeding')
