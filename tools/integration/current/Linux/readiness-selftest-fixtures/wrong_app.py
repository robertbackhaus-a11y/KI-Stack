import http.server, sys
port = int(sys.argv[1])
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path == '/healthz':
            # coincidentally also answers "OK" -- this is what makes the
            # identity check (/config) necessary, not just /healthz alone.
            body = b'OK'
            self.send_response(200); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
        elif self.path == '/config':
            body = b'{"status":"ok"}'
            self.send_response(200); self.send_header('Content-Type','application/json')
            self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
        else:
            self.send_response(200); body=b'hello'; self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
http.server.HTTPServer(('127.0.0.1', port), Handler).serve_forever()

