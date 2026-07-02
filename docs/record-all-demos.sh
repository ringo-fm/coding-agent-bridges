#!/usr/bin/env bash
# Codex と Claude 両方のデモ GIF を生成する統合スクリプト
# 使用方法: bash docs/record-all-demos.sh [codex|claude|all]

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCS="$REPO/docs"
BRIDGE_PORT=18765
TARGET="${1:-all}"

die() { echo "❌ $*" >&2; exit 1; }
need() { command -v "$1" > /dev/null 2>&1 || die "Required tool not found: $1"; }

need asciinema
need agg
need expect
need python3

# bridge が起動済みでなければ起動
ensure_bridge() {
    if curl -sf "http://127.0.0.1:${BRIDGE_PORT}/health" > /dev/null 2>&1; then
        echo "✔  Bridge already running on port ${BRIDGE_PORT}"
        return
    fi
    echo "→  Starting ringo gateway on port ${BRIDGE_PORT}…"
    ringo serve --port "${BRIDGE_PORT}" &
    BRIDGE_PID=$!
    for i in $(seq 1 30); do
        sleep 1
        curl -sf "http://127.0.0.1:${BRIDGE_PORT}/health" > /dev/null 2>&1 && break
        [ "$i" -eq 30 ] && die "Bridge did not become ready after 30s"
    done
    echo "✔  Bridge ready"
}

merge_casts() {
    local launch="$1" main="$2" out="$3" title="$4"
    python3 - <<PYEOF
import json
from pathlib import Path

def read_cast(p):
    lines = Path(p).read_text().splitlines()
    return json.loads(lines[0]), [json.loads(l) for l in lines[1:] if l.strip()]

h1, ev1 = read_cast("$launch")
h2, ev2 = read_cast("$main")

end1 = ev1[-1][0] if ev1 else 0.0
offset = end1 + 1.0

header = dict(h1)
header["title"] = "$title"
header.pop("command", None)

merged = [[t, typ, data] for t, typ, data in ev1]
for t, typ, data in ev2:
    merged.append([round(t + offset, 6), typ, data])

with Path("$out").open("w") as f:
    f.write(json.dumps(header) + "\n")
    for ev in merged:
        f.write(json.dumps(ev) + "\n")

print(f"✅ Merged: $out  ({len(ev1)} + {len(ev2)} = {len(merged)} events)")
PYEOF
}

record_codex() {
    echo ""
    echo "=== Codex デモ録画 ==="

    echo "→  起動シーン生成…"
    python3 "$DOCS/generate-launch-cast.py"

    ensure_bridge

    echo "→  Codex 対話録画…"
    asciinema rec \
        --overwrite \
        --title "ringo codex conversation" \
        --cols 110 \
        --rows 34 \
        "$DOCS/demo-main.cast" \
        -c "expect '$DOCS/demo-codex.exp'"

    echo "→  キャスト結合…"
    merge_casts \
        "$DOCS/demo-launch.cast" \
        "$DOCS/demo-main.cast" \
        "$DOCS/demo-codex-merged.cast" \
        "ringo codex — Apple Foundation Models"

    echo "→  GIF 生成…"
    agg \
        --theme monokai \
        --font-size 15 \
        --speed 1.5 \
        "$DOCS/demo-codex-merged.cast" "$DOCS/demo-codex.gif"

    echo "✅ Codex GIF: $DOCS/demo-codex.gif"
}

record_claude() {
    echo ""
    echo "=== Claude デモ録画 ==="

    echo "→  起動シーン生成…"
    python3 "$DOCS/generate-claude-launch-cast.py"

    ensure_bridge

    echo "→  Claude 対話録画…"
    asciinema rec \
        --overwrite \
        --title "ringo claude conversation" \
        --cols 110 \
        --rows 34 \
        "$DOCS/demo-claude-main.cast" \
        -c "expect '$DOCS/demo-claude.exp'"

    echo "→  キャスト結合…"
    merge_casts \
        "$DOCS/demo-claude-launch.cast" \
        "$DOCS/demo-claude-main.cast" \
        "$DOCS/demo-claude-merged.cast" \
        "ringo claude — Apple Foundation Models"

    echo "→  GIF 生成…"
    agg \
        --theme monokai \
        --font-size 15 \
        --speed 1.5 \
        "$DOCS/demo-claude-merged.cast" "$DOCS/demo-claude.gif"

    echo "✅ Claude GIF: $DOCS/demo-claude.gif"
}

case "$TARGET" in
    codex) record_codex ;;
    claude) record_claude ;;
    all)
        record_codex
        record_claude
        ;;
    *)
        echo "Usage: $0 [codex|claude|all]"
        exit 1
        ;;
esac

# bridge を自分で起動した場合は終了
if [ -n "${BRIDGE_PID:-}" ]; then
    kill "$BRIDGE_PID" 2>/dev/null || true
fi

echo ""
echo "🎬 完了"
