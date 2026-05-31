#!/usr/bin/env python3
"""Encode a Dash0 UI query-state object into the URL `s` parameter.

The Dash0 web app stores its current view's query state in the URL via:

    https://<dash0-app-host>/<view>?org=<slug>&s=<urlsafe-b64(zlib(json))>

This script accepts JSON on stdin (or as the first arg) and emits the encoded
string. Use it from a SKILL or a generated test plan to produce deep links to
traces / logs / metrics pre-filtered to your test run.

USAGE:
    # From a heredoc:
    python3 encode-dash0-link.py <<'JSON'
    { "/": {...}, "/traces": {...}, "/traces/explorer": {...} }
    JSON

    # From a file:
    python3 encode-dash0-link.py state.json

    # Bake into a URL:
    s=$(python3 encode-dash0-link.py state.json)
    echo "https://<dash0-app-host>/traces/explorer?org=$ORG&s=$s"

QUERY-STATE SHAPE (cheat-sheet from observed working links):

    Traces page:
    {
      "/": {
        "dataset": "default",
        "focusedTimeRange": null,
        "focusedDurationRange": null,
        "from": "now-1h",
        "to": "now",
        "sampling": "adaptive",
        "pinnedFilters": {}
      },
      "/traces": {
        "spanListConfig": {"activeViewId": "80c41711-b4f1-4b85-aa4c-cb5650d8355e"},
        "open": false,
        "backUrl": null,
        "query": {
          "filter": [
            {"key": "service.name", "operator": "is", "value": "<my-local-service>"},
            {"key": "<discriminator>", "operator": "is", "value": "<value>"}
          ]
        },
        "tab": "overview"
      },
      "/traces/explorer": {"elementKind": "span"}
    }

    Logs page:
    {
      "/": { ... same as above (sans pinnedFilters) ... },
      "/logs": {
        "logsListConfig": {"activeViewId": "dash0-view-logs-default"},
        "query": {
          "filter": [
            {"key": "service.name", "operator": "is", "value": "<my-local-service>"}
          ]
        }
      }
    }

OPERATOR NAMES — known working: `is`. The app's parser does NOT accept every
filter operator name in the URL state — `contains`, `like`, `regex` have all
been observed to throw 500 React-Server-Components errors on render. Default
to `is` with an exact value. Use multiple filters in the array to AND them.
"""

import base64
import json
import sys
import urllib.parse
import zlib


def encode(state: dict) -> str:
    raw = json.dumps(state, separators=(",", ":")).encode()
    compressed = zlib.compress(raw)
    return urllib.parse.quote(base64.urlsafe_b64encode(compressed).decode())


def main() -> None:
    if len(sys.argv) > 1 and sys.argv[1] != "-":
        with open(sys.argv[1]) as f:
            state = json.load(f)
    else:
        state = json.load(sys.stdin)
    print(encode(state))


if __name__ == "__main__":
    main()
