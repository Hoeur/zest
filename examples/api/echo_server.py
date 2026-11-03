"""A tiny httpbin-style echo server for running the example suites offline.

    python3 echo_server.py 8080

Every path answers with JSON describing the request: args, json, data, headers,
url and method. /status/<code> answers with that status and an empty body.
"""
import json, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs
class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    # One write per response and no Nagle delay, so latency numbers from
    # `ztest load` measure ZTest rather than a 40ms delayed-ACK stall.
    wbufsize = 64 * 1024
    disable_nagle_algorithm = True
    def log_message(self, *a): pass
    def reply(self):
        u = urlparse(self.path)
        n = int(self.headers.get('Content-Length') or 0)
        raw = self.rfile.read(n) if n else b''
        try: js = json.loads(raw) if raw else None
        except Exception: js = None
        if u.path.startswith('/status/'):
            code = int(u.path.split('/')[2]); body=b''
        else:
            code = 200
            body = json.dumps({"args": {k:v[0] for k,v in parse_qs(u.query).items()}, "json": js, "data": raw.decode(errors='replace'),
                "headers": {"-".join(p.capitalize() for p in k.split("-")): v for k, v in self.headers.items()}, "url": "http://%s%s" % (self.headers.get('Host'), self.path), "method": self.command}).encode()
        self.send_response(code)
        self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(body)))
        self.send_header('Set-Cookie','sid=abc; Path=/')
        self.end_headers(); self.wfile.write(body)
    do_GET=do_POST=do_PUT=do_PATCH=do_DELETE=reply
ThreadingHTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
