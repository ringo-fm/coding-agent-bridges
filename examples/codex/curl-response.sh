#!/usr/bin/env bash
# Non-streaming /v1/responses smoke test against the local bridge.
#
# Usage:
#   AFM_BRIDGE_API_KEY=dev swift run codex-afm-bridge &
#   ./examples/curl-response.sh
set -euo pipefail

: "${AFM_BRIDGE_API_KEY:=dev}"
BASE_URL="${AFM_BRIDGE_BASE_URL:-http://127.0.0.1:8765}"

curl -sS -X POST "${BASE_URL}/v1/responses" \
  -H "Authorization: Bearer ${AFM_BRIDGE_API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "apple-foundation-local",
    "instructions": "You are a coding assistant.",
    "input": [
      {
        "role": "user",
        "content": [
          { "type": "input_text", "text": "Explain what this repository does in one sentence." }
        ]
      }
    ],
    "stream": false
  }' | python3 -m json.tool

