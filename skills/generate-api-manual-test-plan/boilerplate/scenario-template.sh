# --- §2 scenario block template -------------------------------------------
# Use this exact shape for every scenario block in §2 of the generated plan.
# Substitutions in <angle-brackets>:
#   <scenario>   — short slug, also the first arg to record_result
#   <name>       — human-readable name for the echo header
#   N            — scenario sequence number (1, 2, 3, …)
#   <url>        — target endpoint URL
#   <payload …>  — replace with the actual payload builder + args
#   <assertion-predicate> — jq -e expression on the read_state row
#   <human-readable expectation>, <one-sentence outcome>, <expectation>
#
# CRITICAL: record_result is called on BOTH branches with all five fields so
# the final results table shows the full picture even when fail-fast trips.
# Do NOT change the curl pattern — the `curl -i | head -1` style is fragile
# against CRLF and varying response shapes. Capture status + body separately.

new_fixture_id <scenario>
echo "=== Scenario N — <name> ==="

body_file=$(mktemp)
http_code=$(curl -s -o "$body_file" -w '%{http_code}' \
  -X POST <url> -H 'Content-Type: application/json' --data "$(payload Create '...')")
body=$(cat "$body_file"); rm -f "$body_file"

sleep 1
row=$(read_state)
if echo "$row" | jq -e '<assertion-predicate>' >/dev/null; then
  echo "✓ N PASS — <human-readable expectation>"
  record_result "<scenario>" PASS "$http_code" "<one-sentence outcome>" "$FIXTURE_ID"
else
  echo "✗ N FAIL"
  echo "  row: $row"
  echo "  body: $body"
  record_result "<scenario>" FAIL "$http_code" "expected <expectation>, got mismatch" "$FIXTURE_ID"
  exit 1
fi
