#!/usr/bin/env python3
"""Real requests, Gateway conditions, Prometheus samples and Fluentd → Loki."""
import argparse
import base64
import contextlib
import datetime
import json
import os
from pathlib import Path
import socket
import subprocess
import time
import urllib.parse
import urllib.error
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parent.parent
RESULTS = []


def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.PIPE).strip()


def kjson(*args):
    return json.loads(run('kubectl', *args, '-o', 'json'))


def check(name, condition, detail):
    RESULTS.append({'check': name, 'passed': bool(condition), 'detail': detail})
    print(f"{'PASS' if condition else 'FAIL'} {name}: {detail}", flush=True)
    if not condition:
        raise RuntimeError(name)


def wait_for(fn, timeout=90):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        try:
            last = fn()
            if last:
                return last
        except urllib.error.HTTPError as exc:
            if exc.code in (401, 403):
                raise
        except (OSError, ValueError, RuntimeError):
            pass
        time.sleep(2)
    raise RuntimeError(f'Timed out after {timeout}s; last result={last!r}')


def api(base, path, params=None):
    url = base + path
    if params:
        url += '?' + urllib.parse.urlencode(params)
    with urllib.request.urlopen(url, timeout=8) as response:
        result = json.load(response)
    if result.get('status') != 'success':
        raise RuntimeError(str(result))
    return result['data']


@contextlib.contextmanager
def forward(resource, remote):
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    process = subprocess.Popen(['kubectl', '-n', 'mtc-observability',
        'port-forward', resource, f'{port}:{remote}', '--address=127.0.0.1'],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        def opened():
            if process.poll() is not None:
                raise RuntimeError('port-forward exited')
            with socket.create_connection(('127.0.0.1', port), timeout=1):
                return True
        wait_for(opened, 30)
        yield f'http://127.0.0.1:{port}'
    finally:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def conditions(resource, required):
    cs = resource.get('status', {}).get('conditions', [])
    return all(any(c['type'] == typ and c['status'] == 'True'
                   and c.get('observedGeneration') == resource['metadata']['generation']
                   for c in cs) for typ in required)


def main(extended):
    namespace = kjson('get', 'namespace', 'mtc-lab')
    check('dedicated cluster', namespace['metadata']['labels'].get('mtc-managed') == 'true', 'namespace marker')
    nodes = kjson('get', 'nodes')['items']
    node = nodes[0]
    check('node Ready', all(any(c['type'] == 'Ready' and c['status'] == 'True'
          for c in n['status']['conditions']) for n in nodes), f'{len(nodes)} node(s)')
    gateway = kjson('-n', 'mtc-lab', 'get', 'gateway', 'mtc-gateway')
    check('Gateway Accepted + Programmed', conditions(gateway, ['Accepted', 'Programmed']), 'current generation')
    for route in kjson('-n', 'mtc-lab', 'get', 'httproute')['items']:
        parent_statuses = route.get('status', {}).get('parents', [])
        valid = bool(parent_statuses) and all(conditions({'metadata': route['metadata'], 'status': p},
            ['Accepted', 'ResolvedRefs']) for p in parent_statuses)
        check(f"HTTPRoute {route['metadata']['name']}", valid, 'Accepted + ResolvedRefs')
    workloads = kjson('get', 'deployments', '-A')['items']
    selected = [w for w in workloads if w['metadata']['namespace'] in
                ['mtc-lab', 'mtc-observability', 'envoy-gateway-system']]
    check('deployments Ready', bool(selected) and all(w.get('status', {}).get('availableReplicas', 0)
          >= w['spec'].get('replicas', 1) for w in selected), f'{len(selected)} deployments')
    claims = kjson('-n', 'mtc-observability', 'get', 'pvc')['items']
    check('persistent volumes', len(claims) >= 3 and all(c['status']['phase'] == 'Bound' for c in claims),
          ', '.join(sorted(c['metadata']['name'] for c in claims)))
    address = next(a['address'] for a in node['status']['addresses'] if a['type'] == 'InternalIP')
    token = 'mtc-check-' + uuid.uuid4().hex

    def http(host='demo.mtc.test', path='/', tls=False):
        args = ['curl', '--silent', '--show-error', '--max-time', '8', '--write-out', '\n%{http_code}',
                '--header', f'X-Request-ID: {token}']
        if tls:
            args += ['--cacert', str(ROOT / '.local/tls/server.crt'), '--resolve',
                     f'{host}:30443:{address}', f'https://{host}:30443{path}']
        else:
            args += ['--header', f'Host: {host}', f'http://{address}:30080{path}']
        body, code = subprocess.check_output(args, text=True, stderr=subprocess.PIPE).rsplit('\n', 1)
        return body.rstrip('\n'), int(code)

    check('HTTP Hello World', http(path='/?check=' + token) == ('Hello World! version=stable', 200), 'stable through Gateway')
    check('path routing', http(path='/canary?check=' + token) == ('Hello World! version=canary', 200), '/canary → canary')
    check('TLS with certificate verification', http(tls=True)[1] == 200, 'SAN demo.mtc.test + trusted demo certificate')
    check('hostname isolation', http(host='unmatched.invalid')[1] == 404, 'unknown hostname rejected')
    check('error log trigger', http(path='/error-test/' + token)[1] == 404, 'Nginx access + file error')

    prom_pods = kjson('-n', 'mtc-observability', 'get', 'pods', '-l', 'app.kubernetes.io/name=prometheus')['items']
    check('Prometheus present', len(prom_pods) == 1, 'one persistent Prometheus replica')
    with forward('pod/' + prom_pods[0]['metadata']['name'], 9090) as prom:
        active = wait_for(lambda: api(prom, '/api/v1/targets')['activeTargets'])
        required_jobs = ['envoy', 'node-exporter', 'kube-state-metrics', 'loki', 'kubelet']
        for job in required_jobs:
            def healthy_job():
                current = api(prom, '/api/v1/targets')['activeTargets']
                return [t for t in current if t['health'] == 'up' and
                        job in (t['labels'].get('job', '') + t['scrapePool'])]
            matched = wait_for(healthy_job)
            check('Prometheus target ' + job, bool(matched), f'{len(matched)} healthy target(s)')
        def query(expr):
            return api(prom, '/api/v1/query', {'query': expr})['result']
        cpu = wait_for(lambda: query('sum(rate(container_cpu_usage_seconds_total{namespace="mtc-lab",container="nginx"}[2m]))'))
        check('PromQL CPU', bool(cpu), 'cAdvisor application CPU sample')
        ram = query('sum(container_memory_working_set_bytes{namespace="mtc-lab",container="nginx"})')
        check('PromQL RAM', bool(ram) and float(ram[0]['value'][1]) > 0, 'application working set > 0')
        http_expr = 'sum(envoy_http_downstream_rq_total{envoy_http_conn_manager_prefix=~"https?-.*"})'
        traffic = wait_for(lambda: query(http_expr))
        check('PromQL HTTP requests', bool(traffic) and float(traffic[0]['value'][1]) > 0,
              f"request counter={traffic[0]['value'][1]}")
        baseline = float(traffic[0]['value'][1])
        for _ in range(20):
            http(path='/?metrics=' + token)
        def increased():
            samples = query(http_expr)
            return samples and float(samples[0]['value'][1]) >= baseline + 20
        check('HTTP counter increases after 20 requests', wait_for(increased), 'application listeners only; next scrape')
        dashboard_source = json.loads((ROOT / 'dashboards/mtc-demo.json').read_text())
        for panel in dashboard_source['panels']:
            if panel['datasource']['type'] == 'prometheus':
                samples = wait_for(lambda: query(panel['targets'][0]['expr']))
                check('dashboard PromQL ' + panel['title'], bool(samples), f'{len(samples)} series')
        active = api(prom, '/api/v1/targets')['activeTargets']
        bad = [t['labels'].get('job', t['scrapePool']) for t in active if t['health'] != 'up']
        check('all selected Prometheus targets healthy', not bad, bad or f'{len(active)} healthy targets')

    with forward('service/mtc-loki', 3100) as loki:
        def find_log(stream):
            data = api(loki, '/loki/api/v1/query_range', {'query':
                '{app="mtc-demo",stream="' + stream + '"} |= "' + token + '"',
                'since': '15m', 'limit': '100'})
            return data.get('result', [])
        for stream in ['stdout', 'stderr']:
            matches = wait_for(lambda: find_log(stream))
            check('Fluentd → Loki ' + stream, bool(matches), token)

    with forward('service/monitoring-grafana', 80) as grafana:
        credentials = 'admin:' + (ROOT / '.local/grafana-password').read_text().strip()
        auth = 'Basic ' + base64.b64encode(credentials.encode()).decode()
        def grafana_get(path):
            request = urllib.request.Request(grafana + path, headers={'Authorization': auth})
            with urllib.request.urlopen(request, timeout=8) as response:
                return json.load(response)
        sources = wait_for(lambda: grafana_get('/api/datasources'))
        check('Grafana data sources', {'prometheus', 'mtc-loki'}.issubset({s['uid'] for s in sources}),
              'Prometheus + Loki provisioned')
        dashboard = wait_for(lambda: grafana_get('/api/dashboards/uid/mtc-devops'))
        referenced = {p['datasource']['uid'] for p in dashboard['dashboard']['panels']}
        check('Grafana dashboard references', referenced.issubset({s['uid'] for s in sources}), 'all panel data sources resolve')
        check('Grafana dashboard imported', len(dashboard['dashboard']['panels']) == 9,
              'HTTP RPS/codes/p95/5xx, CPU/RAM, replicas, targets, logs')

    if extended:
        counts = {'stable': 0, 'canary': 0}
        for _ in range(200):
            body, code = http(host='split.mtc.test')
            check_version = body.rsplit('=', 1)[-1]
            if code != 200 or check_version not in counts:
                raise RuntimeError(f'Unexpected weighted response: {code} {body}')
            counts[check_version] += 1
        check('weighted backends 90/10', 3 <= counts['canary'] <= 45, counts)
        app = kjson('-n', 'mtc-lab', 'get', 'pods', '-l',
                    'app.kubernetes.io/name=demo-nginx,app.kubernetes.io/version=stable')['items'][0]
        ruby = 'begin; Timeout.timeout(3) { TCPSocket.new(ARGV[0],8080) }; exit 1; rescue Timeout::Error; puts "blocked"; end'
        blocked = run('kubectl', '-n', 'mtc-observability', 'exec', 'daemonset/mtc-fluentd',
                      '--', 'ruby', '-rsocket', '-rtimeout', '-e', ruby, app['status']['podIP'])
        check('NetworkPolicy enforced', blocked == 'blocked', 'direct connection from observability namespace dropped')
    print('All verification checks passed.', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--extended', action='store_true')
    args = parser.parse_args()
    failed = None
    try:
        main(args.extended)
    except Exception as exc:
        failed = str(exc)
        print('ERROR:', failed, flush=True)
    state = ROOT / '.local'
    state.mkdir(mode=0o700, exist_ok=True)
    os.chmod(state, 0o700)
    (state / 'verification.json').write_text(json.dumps({'time_utc':
        datetime.datetime.now(datetime.timezone.utc).isoformat(), 'passed': failed is None,
        'checks': RESULTS, 'error': failed}, ensure_ascii=False, indent=2) + '\n')
    raise SystemExit(1 if failed else 0)
