#!/usr/bin/env python3
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
from verify import kjson, run

root = Path(__file__).resolve().parent.parent
state = root / '.local'
state.mkdir(mode=0o700, exist_ok=True)
os.chmod(state, 0o700)

def snapshot():
    cluster = kjson('get', 'namespace', 'kube-system')['metadata']['uid']
    assert cluster == run('sudo', 'cat', '/var/lib/mtc-devops/cluster.uid'), 'Dedicated cluster identity mismatch'
    pvcs = kjson('-n', 'mtc-observability', 'get', 'pvc')['items']
    pods = kjson('get', 'pods', '-A')['items']
    selected = [p for p in pods if p['metadata']['namespace'] in
                ['mtc-lab', 'mtc-observability', 'envoy-gateway-system'] and
                any(c['type'] == 'Ready' and c['status'] == 'True' for c in p.get('status', {}).get('conditions', []))]
    secrets = {}
    for ns, name in [('mtc-lab', 'mtc-demo-tls'), ('mtc-observability', 'mtc-grafana-admin')]:
        secret = kjson('-n', ns, 'get', 'secret', name)
        secrets[name] = {'uid': secret['metadata']['uid'], 'data_hash':
                         hashlib.sha256(json.dumps(secret['data'], sort_keys=True).encode()).hexdigest()}
    return {'cluster': cluster, 'pvcs': {p['metadata']['name']: p['metadata']['uid'] for p in pvcs},
            'secrets': secrets, 'ready_pods': {p['metadata']['namespace'] + '/' + p['metadata']['name']:
                                             p['metadata']['uid'] for p in selected}}

parser = argparse.ArgumentParser()
parser.add_argument('--capture', action='store_true')
args = parser.parse_args()
current = snapshot()
if args.capture:
    (state / 'idempotence-before.json').write_text(json.dumps(current, indent=2) + '\n')
    print('Captured private baseline: cluster, PVC, Secret, ready Pod identities')
else:
    before = json.loads((state / 'idempotence-before.json').read_text())
    checks = {key + '_unchanged': current[key] == before[key] for key in before}
    for key, passed in checks.items():
        print(('PASS ' if passed else 'FAIL ') + key, flush=True)
    report = {'time_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'passed': all(checks.values()), 'checks': checks, 'ready_pod_count': len(current['ready_pods'])}
    (state / 'idempotence.json').write_text(json.dumps(report, indent=2) + '\n')
    raise SystemExit(0 if report['passed'] else 1)
