#!/usr/bin/env python3
"""Controlled rolling update and persistence checks, only on this managed lab."""
import datetime
import json
from pathlib import Path
import threading
import time
import urllib.request
import uuid
from verify import api, forward, kjson, run, wait_for

ROOT = Path(__file__).resolve().parent.parent


def main():
    selected_uid = kjson('get', 'namespace', 'kube-system')['metadata']['uid']
    recorded_uid = run('sudo', 'cat', '/var/lib/mtc-devops/cluster.uid')
    assert selected_uid == recorded_uid, 'Selected cluster is not this dedicated lab'
    deployment = kjson('-n', 'mtc-lab', 'get', 'deployment', 'demo-stable')
    assert deployment['spec']['replicas'] >= 2, 'Two stable replicas required'
    node = kjson('get', 'nodes')['items'][0]
    address = next(a['address'] for a in node['status']['addresses'] if a['type'] == 'InternalIP')
    token = 'mtc-persist-' + uuid.uuid4().hex
    stop = threading.Event()
    attempts = []

    def request():
        req = urllib.request.Request(f'http://{address}:30080/?check={token}', headers={'Host': 'demo.mtc.test'})
        with urllib.request.urlopen(req, timeout=3) as response:
            return response.status == 200 and response.read() == b'Hello World! version=stable\n'

    def traffic():
        while not stop.is_set():
            try:
                attempts.append(request())
            except OSError:
                attempts.append(False)
            stop.wait(0.1)

    assert request()
    worker = threading.Thread(target=traffic)
    worker.start()
    try:
        run('kubectl', '-n', 'mtc-lab', 'rollout', 'restart', 'deployment/demo-stable')
        run('kubectl', '-n', 'mtc-lab', 'rollout', 'status', 'deployment/demo-stable', '--timeout=180s')
    finally:
        stop.set()
        worker.join(timeout=10)
    assert len(attempts) > 10 and all(attempts), f'Rolling update errors: {attempts.count(False)} / {len(attempts)}'
    print(f'PASS rolling update: {len(attempts)} HTTP requests, 0 errors', flush=True)

    query = '{app="mtc-demo",stream="stdout"} |= "' + token + '"'
    def logs(loki):
        return api(loki, '/loki/api/v1/query_range', {'query': query, 'since': '15m', 'limit': '10'})['result']
    with forward('service/mtc-loki', 3100) as loki:
        before = wait_for(lambda: logs(loki))
    claim_uid = kjson('-n', 'mtc-observability', 'get', 'pvc', 'mtc-loki')['metadata']['uid']
    run('kubectl', '-n', 'mtc-observability', 'rollout', 'restart', 'statefulset/mtc-loki')
    run('kubectl', '-n', 'mtc-observability', 'rollout', 'status', 'statefulset/mtc-loki', '--timeout=180s')
    with forward('service/mtc-loki', 3100) as loki:
        after = wait_for(lambda: logs(loki))
    assert any(value in [v for stream in after for v in stream['values']]
               for stream in before for value in stream['values']), 'Original log record missing after Loki restart'
    assert claim_uid == kjson('-n', 'mtc-observability', 'get', 'pvc', 'mtc-loki')['metadata']['uid']
    print('PASS Loki restart: original log timestamp/value and PVC preserved', flush=True)

    prom = kjson('-n', 'mtc-observability', 'get', 'pods', '-l', 'app.kubernetes.io/name=prometheus')['items'][0]
    sts_name = next(r['name'] for r in prom['metadata']['ownerReferences'] if r['kind'] == 'StatefulSet')
    with forward('pod/' + prom['metadata']['name'], 9090) as url:
        sample = api(url, '/api/v1/query', {'query': 'sum(envoy_http_downstream_rq_total)'})['result'][0]['value']
    run('kubectl', '-n', 'mtc-observability', 'rollout', 'restart', 'statefulset/' + sts_name)
    run('kubectl', '-n', 'mtc-observability', 'rollout', 'status', 'statefulset/' + sts_name, '--timeout=180s')
    with forward('pod/' + prom['metadata']['name'], 9090) as url:
        restored = wait_for(lambda: api(url, '/api/v1/query', {'query': 'sum(envoy_http_downstream_rq_total)',
                   'time': str(sample[0])})['result'])
    assert restored[0]['value'] == sample, f'Historical Prometheus sample changed: {sample} / {restored}'
    print('PASS Prometheus restart: historical sample preserved', flush=True)
    report = {'time_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'passed': True,
              'rolling_http_requests': len(attempts), 'rolling_http_failures': attempts.count(False),
              'loki_original_record_preserved': True, 'prometheus_historical_sample_preserved': True}
    (ROOT / '.local/resilience.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
