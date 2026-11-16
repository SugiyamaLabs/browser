#!/usr/bin/env python3
"""Páginas de teste do bloqueador (docs/bloqueador.md). Só 127.0.0.1.
serve.py [PORTA]        http em /  (index.html) e /youtube
serve.py --tls PORTA    o mesmo em https, com um certificado próprio (cert.pem/key.pem gerados aqui)
"""
import http.server, json, ssl, subprocess, sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
PLAYER = {"videoDetails": {"videoId": "x"}, "adPlacements": [1], "playerAds": [2], "adSlots": [3]}


class H(http.server.BaseHTTPRequestHandler):
    def send(self, body, ctype):
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path in ("/", "/youtube", "/watch"):
            return self.send((HERE / ("index.html" if path == "/" else "youtube.html")).read_bytes(), "text/html; charset=utf-8")
        if path == "/headers":  # what the browser sent: DNT, Sec-GPC, Referer
            return self.send(json.dumps(dict(self.headers)).encode(), "application/json")
        self.send_error(404)

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        if self.path.startswith("/youtubei/v1/player"):
            return self.send(json.dumps(PLAYER).encode(), "application/json")
        self.send_error(404)

    def log_message(self, *a):
        pass


tls = "--tls" in sys.argv
args = [a for a in sys.argv[1:] if a != "--tls"]
srv = http.server.ThreadingHTTPServer(("127.0.0.1", int(args[0]) if args else 8766), H)
if tls:
    cert, key = HERE / "cert.pem", HERE / "key.pem"
    if not cert.exists():
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "30", "-subj", "/CN=www.youtube.com",
                        "-keyout", str(key), "-out", str(cert)], check=True, capture_output=True)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(cert, key)
    srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
srv.serve_forever()
