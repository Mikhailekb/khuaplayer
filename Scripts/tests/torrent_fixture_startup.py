#!/usr/bin/env python3
"""The loopback fixture must start and authenticate with reverse DNS unavailable."""
import base64
import json
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

fixture = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix='kinolet-fixture-startup-') as scratch:
    state = Path(scratch) / 'worker'
    state.mkdir()
    (state / 'accs.db').write_text(json.dumps({'fixture': 'test-password'}))
    (state / 'settings.json').write_text(json.dumps({'BitTorr': {'CacheSize': 134217728}}))
    # A failed lookup represents the same dependency as an indefinitely blocked
    # host resolver, while keeping the red regression deterministic and quick.
    bootstrap = '''
import runpy, socket, sys
def unavailable_reverse_dns(*args, **kwargs):
    raise RuntimeError('fixture must not invoke reverse DNS')
socket.getfqdn = unavailable_reverse_dns
sys.argv = sys.argv[1:]
runpy.run_path(sys.argv[0], run_name='__main__')
'''
    child = subprocess.Popen([sys.executable, '-c', bootstrap, str(fixture),
                              '--port', '0', '--path', str(state), '--httpauth'],
                             stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    try:
        deadline = time.monotonic() + 10
        port = None
        while time.monotonic() < deadline:
            if child.poll() is not None:
                raise AssertionError('fixture exited before listening: ' + child.stderr.read())
            events = Path(scratch) / 'fixture-events.jsonl'
            if events.exists():
                for line in events.read_text().splitlines():
                    try:
                        event = json.loads(line)
                    except ValueError:
                        continue  # The child may still be appending this line.
                    if event['kind'] == 'listening':
                        port = event['port']
                if port:
                    break
            time.sleep(0.01)
        assert port, 'fixture did not listen without reverse DNS'
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        endpoint = f'http://127.0.0.1:{port}'
        with opener.open(endpoint + '/echo', timeout=3) as response:
            assert response.status == 200 and response.read().startswith(b'MatriX.')
        authorization = 'Basic ' + base64.b64encode(b'fixture:test-password').decode()
        request = urllib.request.Request(endpoint + '/torrents', data=b'{"action":"list"}',
                                         headers={'Authorization': authorization})
        with opener.open(request, timeout=3) as response:
            assert response.status == 200 and json.load(response) == []
        try:
            opener.open(urllib.request.Request(endpoint + '/torrents', data=b'{"action":"list"}'), timeout=3)
        except urllib.error.HTTPError as error:
            assert error.code == 401
            error.close()
        else:
            raise AssertionError('fixture accepted an unauthenticated request')
        print('Torrent fixture startup checks passed (reverse DNS unavailable; echo and authenticated/unauthenticated HTTP).')
    finally:
        if child.poll() is None:
            child.terminate()
        try:
            child.wait(timeout=3)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()
        child.stderr.close()
