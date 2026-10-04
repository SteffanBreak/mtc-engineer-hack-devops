#!/usr/bin/env python3
"""Render explicitly named tokens without touching Nginx or shell variables."""
import os
import hashlib
import re
import sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
values = {}
for line in (root / "config/versions.env").read_text().splitlines():
    if not line or line.startswith("#"):
        continue
    key, value = line.split("=", 1)
    values[key] = value.strip().strip('"').strip("'")
values.update({k: v for k, v in os.environ.items() if k.startswith("MTC_")})
source = Path(sys.argv[1])
text = source.read_text()
values['MTC_SOURCE_HASH'] = hashlib.sha256(text.encode()).hexdigest()
values['MTC_FLUENTD_HASH'] = hashlib.sha256((root / 'images/fluentd/Dockerfile').read_bytes()).hexdigest()
tokens = set(re.findall(r"__([A-Z][A-Z0-9_]*)__", text))
for token in tokens:
    if token not in values:
        raise SystemExit(f"Missing template value: {token}")
    text = text.replace(f"__{token}__", values[token])
sys.stdout.write(text)
