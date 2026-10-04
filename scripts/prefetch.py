#!/usr/bin/env python3
"""Fetch only the pinned monitoring images on this project's dedicated host."""
from concurrent.futures import ThreadPoolExecutor
import os
from pathlib import Path
import platform
import subprocess
import time

root = Path(__file__).resolve().parent.parent
assert os.geteuid() == 0 and Path('/var/lib/mtc-devops/cluster.uid').exists(), 'Dedicated lab + sudo required'
arch = {'aarch64': 'arm64', 'x86_64': 'amd64'}[platform.machine()]
images = [x.strip() for x in (root / 'config/monitoring-images.txt').read_text().splitlines()
          if x.strip() and not x.startswith('#')]
present = set(subprocess.check_output(['ctr', '--namespace', 'k8s.io', 'images', 'list', '-q'], text=True).splitlines())

def fetch(image):
    if image in present:
        print('CACHED', image, flush=True)
        return
    log = Path('/var/lib/mtc-devops') / ('image-' + image.rsplit('/', 1)[-1].replace(':', '-') + '.log')
    for attempt in range(3):
        print(f'FETCH {attempt + 1}/3 {image}', flush=True)
        with log.open('ab') as output:
            try:
                result = subprocess.run(['ctr', '--namespace', 'k8s.io', 'images', 'pull', '--platform',
                    'linux/' + arch, image], stdout=output, stderr=subprocess.STDOUT, timeout=120)
                if result.returncode == 0:
                    subprocess.run(['ctr', '--namespace', 'k8s.io', 'images', 'label', image,
                                    'io.cri-containerd.image=managed'], check=True, stdout=subprocess.DEVNULL)
                    return
            except subprocess.TimeoutExpired:
                pass
        time.sleep(2 ** attempt)
    raise RuntimeError(f'Cannot fetch {image}; check network and private log {log}')

with ThreadPoolExecutor(max_workers=4) as pool:
    list(pool.map(fetch, images))
print('Pinned monitoring images ready', flush=True)
