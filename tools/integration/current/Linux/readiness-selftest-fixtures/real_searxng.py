import http.server, json, sys
port = int(sys.argv[1])
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path == '/healthz':
            body = b'OK'
            self.send_response(200); self.send_header('Content-Type','text/plain')
            self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
        elif self.path == '/config':
            data = {"instance_name":"KI-Stack SearXNG","version":"2026.6.28+357662d86","engines":[{"name":"google"}]}
            body = json.dumps(data).encode()
            self.send_response(200); self.send_header('Content-Type','application/json')
            self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
        else:
            self.send_response(404); self.end_headers()
http.server.HTTPServer(('127.0.0.1', port), Handler).serve_forever()

