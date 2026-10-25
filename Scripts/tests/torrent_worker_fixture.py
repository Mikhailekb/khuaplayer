#!/usr/bin/env python3
"""Loopback protocol fault fixture for TorrentServer.swift; never joins a swarm."""
import argparse
import base64
import hashlib
import json
import os
import signal
import socketserver
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from email.parser import BytesParser
from email.policy import default as email_policy
from pathlib import Path

WORKER_VERSION = 'MatriX.147-khua.7'

parser = argparse.ArgumentParser()
parser.add_argument('--ip', default='127.0.0.1')
parser.add_argument('--port', type=int, required=True)
parser.add_argument('--path', type=Path, required=True)
parser.add_argument('--httpauth', action='store_true')
args = parser.parse_args()
accounts = json.loads((args.path / 'accs.db').read_text())
user, password = next(iter(accounts.items()))
authorization = 'Basic ' + base64.b64encode((user + ':' + password).encode()).decode()
records = {}
playback_revisions = {}
playback_windows = {}
records_lock = threading.Lock()
audit_lock = threading.Lock()
payload = bytes(range(256)) * 4096
settings = json.loads((args.path / 'settings.json').read_text())['BitTorr']
diagnostics = os.environ.get('KINOLET_TORRENT_FIXTURE_DIAGNOSTICS')

def audit(kind, **values):
    event = json.dumps(dict(kind=kind, pid=os.getpid(), monotonic=time.monotonic(), **values)) + '\n'
    with audit_lock:
        with (args.path.parent / 'fixture-events.jsonl').open('a') as output:
            output.write(event)
        if diagnostics:
            with Path(diagnostics).open('a') as output:
                output.write(event)

audit('start', cacheSize=settings['CacheSize'], directory=args.path.name,
      port=args.port, python=sys.version.split()[0])
if (args.path.parent / 'refuse-start').exists():
    raise SystemExit(12)

class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *unused):
        pass
    def answer(self, status, data=b'', content_type='application/json', extra=None):
        audit('response', path=urllib.parse.urlsplit(self.path).path,
              method=self.command, status=status,
              hasAuthorization=self.headers.get('Authorization') is not None)
        self.send_response(status)
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Content-Type', content_type)
        for key, value in (extra or {}).items():
            self.send_header(key, value)
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(data)
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        if self.headers.get('Authorization') != authorization:
            self.answer(401)
            return
        if self.path == '/playback/cache':
            try:
                command = json.loads(body)
                hash_value, file_id = command['hash'], command['file_index']
                if hash_value not in records:
                    self.answer(404)
                    return
                if file_id != 7:
                    self.answer(404)
                    return
                result = dict(hash=hash_value, file_index=7, file_offset=13,
                    file_length=len(payload), piece_length=65536,
                    resident_bytes=65523, ranges=[[0, 65523]])
                audit('cache-snapshot', **command)
                gate = args.path.parent / ('hold-cache-reply-' + hash_value)
                if gate.exists():
                    gate.with_name('cache-reply-started-' + hash_value).touch()
                    while gate.exists():
                        time.sleep(0.01)
                override = args.path.parent / ('cache-reply-override-' + hash_value + '.json')
                if override.exists():
                    result = dict(result, **json.loads(override.read_text()))
                self.answer(200, json.dumps(result).encode())
            except (ValueError, KeyError, TypeError):
                self.answer(400)
            return
        if self.path == '/playback/window':
            try:
                command = json.loads(body)
                hash_value, consumer, revision = command['hash'], command['consumer'], command['revision']
                key = (hash_value, consumer)
                transient = args.path.parent / ('fail-next-seek-' + consumer)
                if command.get('seeking') and transient.exists():
                    transient.unlink()
                    audit('seek-transient-failure', **command)
                    self.answer(503)
                    return
                with records_lock:
                    if revision <= playback_revisions.get(key, 0):
                        self.answer(409)
                        return
                    if hash_value not in records:
                        self.answer(404)
                        return
                    playback_revisions[key] = revision
                    if command.get('remove'):
                        playback_windows.pop(key, None)
                        result = {'revision': revision, 'removed': True}
                    elif command.get('seeking'):
                        if command['file_index'] != 7:
                            self.answer(400)
                            return
                        result = dict(playback_windows.get(key, {}), revision=revision, seeking=True)
                        playback_windows[key] = result
                    else:
                        lower, current, upper = command['lower'], command['current'], command['upper']
                        if command['file_index'] != 7 or not 0 <= lower <= current <= upper <= len(payload):
                            self.answer(400)
                            return
                        # Protocol fixture deliberately clamps the caller's
                        # requested end; actual piece/budget policy has Go tests.
                        result = dict(lower=lower, current=current, upper=min(upper, current + 65536),
                                      piece_length=65536, revision=revision)
                        if lower == current and current % 65536:
                            result['lower'] = current - current % 65536
                        playback_windows[key] = result
                audit('window', **command)
                barrier = args.path.parent / ('hold-window-reply-' + consumer + '-' + str(revision))
                if barrier.exists():
                    barrier.with_name('window-reply-started-' + consumer + '-' + str(revision)).touch()
                    while barrier.exists():
                        time.sleep(0.01)
                override = args.path.parent / ('window-reply-override-' + consumer + '.json')
                if override.exists() and not command.get('remove'):
                    result = dict(result, **json.loads(override.read_text()))
                self.answer(200, json.dumps(result).encode())
            except (ValueError, KeyError, TypeError):
                self.answer(400)
            return
        if self.path == '/torrent/upload':
            envelope = (b'Content-Type: ' + self.headers.get('Content-Type', '').encode()
                        + b'\r\nMIME-Version: 1.0\r\n\r\n' + body)
            message = BytesParser(policy=email_policy).parsebytes(envelope)
            parts = list(message.iter_parts())
            torrent_data = parts[0].get_payload(decode=True) if len(parts) == 1 else b''
            # The fixture's valid metainfo is d4:info<original encoded dictionary>e.
            # The production bounded bencode parser validates before upload.
            if not torrent_data.startswith(b'd4:info') or not torrent_data.endswith(b'ee'):
                self.answer(400)
                return
            hash_value = hashlib.sha1(torrent_data[7:-1]).hexdigest()
            result = {'hash': hash_value, 'name': 'Uploaded',
                      'file_stats': [{'id': 7, 'path': 'Show/Movie.mp4', 'length': len(payload)}],
                      'stat': 3, 'preloaded_bytes': 65536}
            with records_lock:
                records[hash_value] = result
            audit('request', path=self.path, action='upload', hash=hash_value)
            self.answer(200, json.dumps(result).encode())
            return
        try:
            command = json.loads(body)
        except (ValueError, UnicodeError):
            self.answer(400)
            return
        action = command.get('action')
        audit('request', path=urllib.parse.urlsplit(self.path).path,
              action=action, hash=command.get('hash'))
        if self.path != '/torrents':
            self.answer(500)
            return
        if action == 'rem':
            barrier = args.path.parent / ('hold-rem-' + command.get('hash', ''))
            if barrier.exists():
                barrier.with_name('rem-started-' + command.get('hash', '')).touch()
                while barrier.exists():
                    time.sleep(0.01)
        with records_lock:
            if action == 'list':
                result = list(records.values())
            elif action == 'add':
                link = urllib.parse.parse_qs(urllib.parse.urlsplit(command.get('link', '')).query)
                hash_value = link.get('xt', [''])[0].split(':')[-1].lower()
                mode = link.get('dn', ['Movie'])[0]
                file = {'id': 7, 'path': 'Show/Movie.mp4', 'length': len(payload)}
                if mode == 'badid':
                    file.pop('id')
                files = [] if mode == 'timeout' else [file]
                if mode == 'duplicate':
                    files.append({'id': 7, 'path': 'Other.mp4', 'length': 5})
                result = {'hash': hash_value, 'name': mode, 'file_stats': files, 'stat': 3,
                          'preloaded_bytes': 65536, 'download_speed': 128000,
                          'torrent_size': len(payload), 'active_peers': 2, 'total_peers': 3}
                records[hash_value] = result
            elif action == 'get':
                result = records.get(command.get('hash'))
                if result is None:
                    self.answer(404)
                    return
            elif action == 'rem':
                records.pop(command.get('hash'), None)
                self.answer(200)
                return
            else:
                self.answer(400)
                return
        self.answer(200, json.dumps(result).encode())
    def do_HEAD(self):
        self.do_GET()
    def do_GET(self):
        url = urllib.parse.urlsplit(self.path)
        if url.path == '/echo':
            barrier = args.path.parent / 'hold-echo'
            if barrier.exists():
                (args.path.parent / 'echo-started').touch()
                while barrier.exists():
                    time.sleep(0.01)
            self.answer(200, WORKER_VERSION.encode(), 'text/plain')
            return
        if not url.path.startswith('/stream/'):
            self.answer(404)
            return
        if self.headers.get('Authorization') != authorization:
            self.answer(401)
            return
        query = urllib.parse.parse_qs(url.query)
        audit('stream', consumer=query.get('playback_consumer', [None])[0])
        with records_lock:
            record = records.get(query.get('link', [''])[0])
        if not record or query.get('index') != ['7']:
            self.answer(404)
            return
        data = payload
        status = 200
        extra = {}
        if self.headers.get('Range'):
            start, end = self.headers['Range'].removeprefix('bytes=').split('-')
            start, end = int(start), int(end)
            data = payload[start:end + 1]
            status = 206
            extra['Content-Range'] = f'bytes {start}-{end}/{len(payload)}'
        if record['name'] != 'slow' or self.command == 'HEAD':
            self.answer(status, data, 'video/mp4', extra)
            return
        self.send_response(status)
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Content-Type', 'video/mp4')
        self.end_headers()
        try:
            for offset in range(0, len(data), 16384):
                self.wfile.write(data[offset:offset + 16384])
                self.wfile.flush()
                time.sleep(0.02)
        except (BrokenPipeError, ConnectionResetError):
            pass

class LoopbackHTTPServer(ThreadingHTTPServer):
    def server_bind(self):
        # HTTPServer resolves getfqdn(host) after binding. This protocol fixture
        # has a numeric loopback address and must not depend on the host's DNS.
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]

server = LoopbackHTTPServer((args.ip, args.port), Handler)
audit('listening', port=server.server_port)
server.daemon_threads = True
def stop():
    delay = args.path.parent / 'termination-delay-ms'
    if delay.exists():
        time.sleep(int(delay.read_text()) / 1000)
    server.shutdown()

signal.signal(signal.SIGTERM, lambda *_: threading.Thread(target=stop, daemon=True).start())
try:
    server.serve_forever(poll_interval=0.05)
finally:
    server.server_close()
    audit('stop')
