# --- Results-table machinery (DO NOT REMOVE) -------------------------------
# Inline this block verbatim into §1 Helpers of every generated plan.
# Substitutions: none — the variables read from environment (DASH0_APP_HOST,
# DASH0_ORG, DISCRIMINATOR_KEY, DATASET, OTEL_SERVICE_NAME, TIME_FROM).
#
# mktemp requires the X's to be the LAST characters of the basename. The form
# `/tmp/foo-XXXXXX.tsv` is NOT a template on most mktemp implementations — it
# creates a file literally named `foo-XXXXXX.tsv` and collides with stale runs.
RESULTS_TSV=$(mktemp "${TMPDIR:-/tmp}/test-results.XXXXXX")
DASH0_APP_HOST="${DASH0_APP_HOST:-<your-dash0-app-host>}"   # inferred from .env.local
DASH0_ORG="${DASH0_ORG:-<your-org-slug>}"
DISCRIMINATOR_KEY="${DISCRIMINATOR_KEY:-<attribute-key>}"   # e.g. <service>.resource.id or request.id
TIME_FROM="${TIME_FROM:-now-1h}"

# Fail fast on any placeholder that the plan-generator forgot to substitute.
# These three MUST be real values — if any still look like `<...>` or contain
# the literal word "your", every generated link will 404 in the Dash0 UI
# ("Organization not found" / empty filter). Better to crash here than to
# silently produce broken links in the results table.
for var in DASH0_APP_HOST DASH0_ORG DISCRIMINATOR_KEY; do
  val="${!var}"
  case "$val" in
    "<"*">"|*your-*|"")
      echo "✗ $var is still a placeholder ('$val'). Set it in .env.local or override before sourcing." >&2
      exit 1
      ;;
  esac
done

record_result () {
  # $1 = scenario name (no tabs)
  # $2 = PASS | FAIL
  # $3 = last HTTP status code observed (digits, e.g. 200)
  # $4 = one-sentence outcome description (no tabs)
  # $5 = discriminator value (fixture id used in the per-row Dash0 link)
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >> "$RESULTS_TSV"
}

dash0_link () {
  # $1 = "traces" | "logs"
  # $2 = discriminator value (the specific fixture id for the row)
  local view=$1 disc=$2
  python3 - "$view" "$disc" "$DATASET" "$OTEL_SERVICE_NAME" "$DISCRIMINATOR_KEY" "$TIME_FROM" "$DASH0_APP_HOST" "$DASH0_ORG" <<'PY'
import base64, json, sys, urllib.parse, zlib
view, disc, dataset, service, disc_key, t_from, host, org = sys.argv[1:9]
common = {"dataset": dataset, "from": t_from, "to": "now", "sampling": "adaptive",
          "focusedTimeRange": None, "focusedDurationRange": None}
flt = {"filter": [
    {"key": "service.name", "operator": "is", "value": service},
    {"key": disc_key, "operator": "is", "value": disc},
]}
if view == "traces":
    common["pinnedFilters"] = {}
    state = {"/": common,
             "/traces": {"spanListConfig": {"activeViewId": "80c41711-b4f1-4b85-aa4c-cb5650d8355e"},
                         "open": False, "backUrl": None, "query": flt, "tab": "overview"},
             "/traces/explorer": {"elementKind": "span"}}
    path = "/traces/explorer"
else:
    state = {"/": common,
             "/logs": {"logsListConfig": {"activeViewId": "dash0-view-logs-default"},
                       "query": flt}}
    path = "/logs"
s = urllib.parse.quote(base64.urlsafe_b64encode(zlib.compress(
        json.dumps(state, separators=(",", ":")).encode())).decode())
print(f"https://{host}{path}?org={org}&s={s}")
PY
}

print_results_table () {
  [ -s "$RESULTS_TSV" ] || return 0
  {
    echo
    echo "## Test results"
    echo
    echo "| # | Scenario | Status | HTTP | Outcome | Traces | Logs |"
    echo "|---|---|---|---|---|---|---|"
    local i=0
    while IFS=$'\t' read -r name status http outcome disc; do
      i=$((i+1))
      local emoji=$([ "$status" = "PASS" ] && echo "✓" || echo "✗")
      local traces_url logs_url
      traces_url=$(dash0_link traces "$disc")
      logs_url=$(dash0_link logs "$disc")
      echo "| $i | $name | $emoji $status | $http | $outcome | [open]($traces_url) | [open]($logs_url) |"
    done < "$RESULTS_TSV"
    echo
  }
}

trap 'print_results_table' EXIT
