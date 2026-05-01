#!/usr/bin/env python3
import http.server

class NoCacheHandler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header('Cache-Control', 'no-store, no-cache, must-revalidate')
        super().end_headers()
    def log_message(self, fmt, *args):
        pass

print('Serving on http://localhost:8000')
try:
    http.server.HTTPServer(('', 8000), NoCacheHandler).serve_forever()
except KeyboardInterrupt:
    pass
