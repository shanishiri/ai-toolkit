# --- Catch-all HTTP listener (200s every verb on :9999) --------------------
# Inline this block verbatim into §0.2 of the generated plan, but only when
# at least one endpoint in the API surface POSTs/PUTs back to a customer-
# supplied callback URL (e.g. CloudFormation ResponseURL).
#
# Why not python3 -m http.server? It returns 501 on PUT, which breaks any
# CFN-style ResponseURL contract. The tiny server below accepts every verb.

cat > /tmp/catchall.py <<'PY'
import http.server, socketserver
class H(http.server.BaseHTTPRequestHandler):
    def _ok(self):
        try: self.rfile.read(int(self.headers.get('Content-Length') or 0))
        except: pass
        self.send_response(200); self.end_headers()
    do_GET = do_PUT = do_POST = do_DELETE = lambda s: s._ok()
    def log_message(*a, **kw): pass
socketserver.TCPServer(('', 9999), H).serve_forever()
PY
nohup python3 /tmp/catchall.py >/tmp/catchall.log 2>&1 &
CATCHALL_PID=$!; disown
until curl -fsS -X PUT http://localhost:9999/ >/dev/null 2>&1; do sleep 1; done
echo "✓ catch-all listener on :9999"
