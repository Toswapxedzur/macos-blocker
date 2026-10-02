"""One-request, loopback-only HTTP fixture for actual URLSession download tests."""

import http.server
import pathlib
import sys

root = pathlib.Path(sys.argv[1])


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/model.gguf":
            self.send_error(404)
            return
        data = (root / "model.gguf").read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_):
        pass


with http.server.HTTPServer(("127.0.0.1", 0), Handler) as server:
    server.timeout = 30
    print(server.server_port, flush=True)
    server.handle_request()
