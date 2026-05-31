# --- §0.1 Preflight: verify service reachability ---------------------------
# Inline this block into §0.1 of the generated plan. Substitute:
#   <healthcheck-or-known-200-endpoint> — any URL on localhost that returns
#       SOMETHING when the service is up (200, 401, 404 — all fine).
#   <port> — the local port (cosmetic, only used in the error message).
#   <start-command> — what the user runs to start the service (e.g. `make run`).

cd <service-dir>

# .env.local present (gitignored)
test -f .env.local || { echo "✗ .env.local missing — start service yourself first"; exit 1; }
echo "✓ .env.local present"

# Service reachable. If this probe fails (connection refused), the user must
# (re)start the service themselves in a shell that has sourced .env.local.
# IMPORTANT: do NOT use `curl -fsS` here — it exits non-zero on 4xx/5xx AND
# prints `curl: (22) ...` to stderr. A 401/404 from a live service is fine
# for liveness; only "connection refused" means the service is down. Capture
# the status code and only treat the connect-failure code (000) as a miss.
http_code=$(curl -s -o /dev/null -w '%{http_code}' <healthcheck-or-known-200-endpoint> 2>/dev/null || echo 000)
if [ "$http_code" = "000" ]; then
  echo "✗ service not reachable at http://localhost:<port> — start it yourself: source .env.local && <start-command>"
  exit 1
fi
echo "✓ service up on :<port> (HTTP $http_code)"
