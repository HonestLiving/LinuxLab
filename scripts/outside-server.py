#!/usr/bin/env python3
"""Return the peer IP so a client can observe source NAT. No file serving."""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        body = (json.dumps({"server": "outside", "client_ip": self.client_address[0]}) + "\n").encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    ThreadingHTTPServer(("198.18.0.2", 8080), Handler).serve_forever()
