#!/usr/bin/env python3
import json
from pathlib import Path
import re
import subprocess

root = Path(__file__).resolve().parent.parent
try:
    names = subprocess.check_output(['git', '-C', str(root), 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], text=True, stderr=subprocess.DEVNULL).split('\0')
except subprocess.CalledProcessError:
    names = [str(p.relative_to(root)) for p in root.rglob('*') if p.is_file()
             and '.local' not in p.relative_to(root).parts and '.git' not in p.relative_to(root).parts]
violations = []
patterns = [r'-----BEGIN [A-Z ]*PRIVATE KEY-----', r'\bgh[pousr]_[A-Za-z0-9]{30,}',
            r'\bgithub_pat_[A-Za-z0-9_]{30,}', r'client-key-data:\s*[A-Za-z0-9+/=]{20,}']
for name in filter(None, names):
    path = root / name
    if '.local' in Path(name).parts or path.suffix in ['.key', '.pem', '.kubeconfig']:
        violations.append(name + ': private path included')
        continue
    if path == Path(__file__).resolve():
        continue
    data = path.read_bytes()
    text = data.decode('utf-8', errors='replace')
    if any(re.search(p, text) for p in patterns):
        violations.append(name + ': credential pattern')
for path in (root / 'dashboards').glob('*.json'):
    dashboard = json.loads(path.read_text())
    assert dashboard.get('uid') and dashboard.get('panels'), 'Invalid dashboard'
if violations:
    raise SystemExit('\n'.join(violations))
print(f'Public source scan: {len(list(filter(None, names)))} files, no credential patterns')
