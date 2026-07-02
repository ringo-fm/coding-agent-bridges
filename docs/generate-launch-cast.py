#!/usr/bin/env python3
"""
ringo codex 起動シーンの合成 asciinema キャストを生成する。
PTY ネスト問題を回避するため、実際の録画をせずに JSON イベントを手動生成。
"""
import json, random
from pathlib import Path

OUT = Path(__file__).parent / "demo-launch.cast"

# ターミナル設定
COLS, ROWS = 80, 24

header = {
    "version": 3,
    "width": COLS,
    "height": ROWS,
    "term": {"cols": COLS, "rows": ROWS},
    "title": "ringo codex — launch",
}

events = []
t = 0.0

def ev(data, delta=0.0):
    global t
    t += delta
    events.append([round(t, 4), "o", data])

# 画面クリア
ev("\x1b[2J\x1b[H", delta=0.1)

# ❯ プロンプト表示
ev("❯ ", delta=0.3)

# "ringo codex" をタイピング（文字ごとに少し間をあける）
text = "ringo codex"
for ch in text:
    delay = random.uniform(0.06, 0.13)
    ev(ch, delta=delay)

# Enter 押下（カーソルが次行へ）
ev("\r\n", delta=0.25)

# bridge 起動とモデルロードを示す出力（ringo が実際に出力するイメージ）
ev("\x1b[2mStarting Apple Foundation Models bridge…\x1b[0m\r\n", delta=0.18)
ev("\x1b[2mLoading model: apple-foundation-local\x1b[0m\r\n", delta=0.55)
ev("\x1b[2mBridge ready  ✔\x1b[0m\r\n", delta=0.80)

# codex TUI が起動するまでの "loading" 感（空白行）
ev("\r\n", delta=0.30)
ev("\x1b[2mLaunching codex TUI…\x1b[0m\r\n", delta=0.20)

# 少し間を置いて終了（次の cast に接続される）
ev("", delta=1.0)

# 書き出し
with OUT.open("w") as f:
    f.write(json.dumps(header) + "\n")
    for row in events:
        f.write(json.dumps(row) + "\n")

total = round(t, 2)
print(f"✅ Generated: {OUT}  ({len(events)} events, {total}s)")
