#!/usr/bin/env bash
# Static lint for plans produced by generate-api-manual-test-plan.
#
# Usage:
#   evals/check-plan.sh <path-to-generated-plan.md> [case-name]
#
# If a case-name is given, the script loads that case from evals/cases.jsonl
# and runs its `required_lines` and `forbidden_patterns` assertions against
# the plan. If no case-name is given, the script applies only the universal
# checks (forbidden patterns that NO valid plan should ever contain).
#
# Exits 0 when every assertion passes; non-zero with a diagnostic on the first
# failure. Use in pre-commit hooks, CI, or right after invoking the skill.

set -euo pipefail

usage () {
  cat >&2 <<EOF
Usage: $0 <plan-file> [case-name]
  plan-file: path to a generated markdown plan
  case-name: optional name from evals/cases.jsonl. If omitted, runs only the
             universal forbidden-pattern checks.
EOF
  exit 2
}

[ $# -ge 1 ] || usage
PLAN="$1"
CASE_NAME="${2:-}"

[ -f "$PLAN" ] || { echo "✗ plan file not found: $PLAN" >&2; exit 2; }

HERE="$(cd "$(dirname "$0")" && pwd)"
CASES="$HERE/cases.jsonl"

fail_count=0
fail () {
  echo "✗ $1" >&2
  fail_count=$((fail_count + 1))
}

# --- Universal checks (always run) -----------------------------------------
# These catch the failure modes the skill has shipped at least once. Add to
# this list when a new class of defect lands in production.

UNIVERSAL_FORBIDDEN=(
  # Substitution markers that the generator forgot to fill in.
  '<your-org-slug>'
  '<your-dash0-app-host>'
  '<attribute-key>'
  '<service-dir>'
  '<feature>'
  '<feature-slug>'
  '<healthcheck-or-known-200-endpoint>'
  '<port>'
  '<start-command>'
  # Carry-over from .env.local.example.
  'REPLACE_WITH_'
  # Known broken curl patterns.
  'curl -fsS http'
  'curl -i | head -1'
  'curl -i | awk'
  # mktemp template with X's NOT at end of basename.
  'mktemp /tmp/[a-zA-Z0-9_-]*-XXXXXX\.tsv'
  # Placeholders that mean "I didn't finish".
  'TODO'
  'FIXME'
  'TBD'
)

for pat in "${UNIVERSAL_FORBIDDEN[@]}"; do
  if grep -E -q -- "$pat" "$PLAN"; then
    fail "forbidden pattern present: $pat"
    grep -nE -- "$pat" "$PLAN" | head -3 | sed 's/^/    /' >&2
  fi
done

# --- Case-specific checks (only when a case-name is given) -----------------

if [ -n "$CASE_NAME" ]; then
  [ -f "$CASES" ] || { echo "✗ cases file not found: $CASES" >&2; exit 2; }
  command -v jq >/dev/null || { echo "✗ jq required for case checks" >&2; exit 2; }

  CASE_JSON="$(jq -c --arg n "$CASE_NAME" 'select(.name == $n)' "$CASES")"
  [ -n "$CASE_JSON" ] || { echo "✗ case not found in $CASES: $CASE_NAME" >&2; exit 2; }

  while IFS= read -r needed; do
    [ -z "$needed" ] && continue
    if ! grep -F -q -- "$needed" "$PLAN"; then
      fail "missing required line: $needed"
    fi
  done < <(echo "$CASE_JSON" | jq -r '.expected.required_lines[]')

  while IFS= read -r forbidden; do
    [ -z "$forbidden" ] && continue
    if grep -E -q -- "$forbidden" "$PLAN"; then
      fail "case-forbidden pattern present: $forbidden"
      grep -nE -- "$forbidden" "$PLAN" | head -3 | sed 's/^/    /' >&2
    fi
  done < <(echo "$CASE_JSON" | jq -r '.expected.forbidden_patterns[]')
fi

# --- Summary ---------------------------------------------------------------

if [ "$fail_count" -gt 0 ]; then
  echo "" >&2
  echo "✗ check-plan failed with $fail_count issue(s) — fix and re-run" >&2
  exit 1
fi

echo "✓ $PLAN — all checks passed${CASE_NAME:+ (case: $CASE_NAME)}"
