#!/bin/sh
# Streaming /v1/messages smoke test against claude-afm-bridge (Anthropic SSE).
set -eu

HOST="${AFM_BRIDGE_HOST:-127.0.0.1}"
PORT="${AFM_BRIDGE_PORT:-8766}"
TOKEN="${AFM_BRIDGE_API_KEY:-local-afm-token}"
URL="http://${HOST}:${PORT}/v1/messages"

curl -sS -N -X POST "$URL" \
  -H "content-type: application/json" \
  -H "x-api-key: ${TOKEN}" \
  -H "anthropic-version: 2023-06-01" \
  -d '{
    "model": "claude-afm-local",
    "max_tokens": 256,
    "stream": true,
    "messages": [
      { "role": "user", "content": "Count from 1 to 5, one number per line." }
    ]
  }'

