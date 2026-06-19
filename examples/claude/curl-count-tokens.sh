#!/bin/sh
# /v1/messages/count_tokens smoke test against claude-afm-bridge.
set -eu

HOST="${AFM_BRIDGE_HOST:-127.0.0.1}"
PORT="${AFM_BRIDGE_PORT:-8766}"
TOKEN="${AFM_BRIDGE_API_KEY:-local-afm-token}"
URL="http://${HOST}:${PORT}/v1/messages/count_tokens"

curl -sS -X POST "$URL" \
  -H "content-type: application/json" \
  -H "x-api-key: ${TOKEN}" \
  -H "anthropic-version: 2023-06-01" \
  -d '{
    "model": "claude-afm-local",
    "system": "You are a concise assistant.",
    "messages": [
      { "role": "user", "content": "Review this repository and summarize its structure." }
    ]
  }'
echo

