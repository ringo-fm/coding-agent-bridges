#!/usr/bin/env bash

set -u

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
claude_bin="${CLAUDE_BIN:-$(command -v claude 2>/dev/null || true)}"
timeout_seconds="${E2E_TIMEOUT_SECONDS:-180}"
work_root="$(mktemp -d "${TMPDIR:-/tmp}/claude-afm-e2e.XXXXXX")"
fixture_repo="$work_root/repo"
expected="$work_root/expected-report.md"
log="$work_root/claude.log"
timed_out="$work_root/timed-out"
passed=0

diagnose() {
    printf '\nClaude instruction-following E2E failed.\nWorkspace: %s\n' "$work_root"
    test ! -s "$log" || { printf '\n--- Claude / bridge output ---\n'; sed -n '1,320p' "$log"; }
    test ! -d "$fixture_repo/.git" || {
        printf '\n--- git status ---\n'; git -C "$fixture_repo" status --short --untracked-files=all
        printf '\n--- tracked diff ---\n'; git -C "$fixture_repo" diff --no-ext-diff
    }
}

cleanup() {
    if test "$passed" -eq 1; then rm -rf "$work_root"; else diagnose; fi
}
trap cleanup EXIT

if test -z "$claude_bin" || ! test -x "$claude_bin" || ! "$claude_bin" --version >"$log" 2>&1; then
    printf 'CLAUDE_BIN does not name a runnable Claude Code CLI: %s\n' "${claude_bin:-<empty>}" >&2
    exit 2
fi
case "$timeout_seconds" in
    ''|*[!0-9]*|0) printf 'E2E_TIMEOUT_SECONDS must be a positive integer.\n' >&2; exit 2 ;;
esac

mkdir -p "$fixture_repo/input"
printf '%s\n' \
    '# Repository instructions' '' \
    '- Complete the task described in TASK.md.' \
    '- Only create `output/report.md`; do not modify tracked content.' \
    '- The report must match the requested format exactly.' \
    >"$fixture_repo/CLAUDE.md"
printf '%s\n' \
    '# Task' '' \
    'Read `input/records.tsv` and select rows whose status is exactly `active`.' \
    'Sort selected rows by numeric ID ascending.' \
    'Create `output/report.md` with heading `# Active records`, followed by' \
    'one bullet per row in the form `- <id>: <name>`.' \
    >"$fixture_repo/TASK.md"
printf '%s\n' \
    $'id\tname\tstatus' $'11\tcedar\tactive' $'7\tmaple\tinactive' \
    $'3\tspruce\tactive' $'20\twillow\tpending' \
    >"$fixture_repo/input/records.tsv"
printf '%s\n' '# Active records' '- 3: spruce' '- 11: cedar' >"$expected"

git -C "$fixture_repo" init -q
git -C "$fixture_repo" add CLAUDE.md TASK.md input/records.tsv
git -C "$fixture_repo" -c user.name='Claude E2E' -c user.email='claude-e2e@example.invalid' commit -qm 'Create fixture'

cd "$repo_root"
ringo_bin="${RINGO_BIN:-}"
if test -z "$ringo_bin"; then
    swift build --product ringo >>"$log" 2>&1 || { printf 'Failed to build ringo.\n' >&2; exit 1; }
    ringo_bin="$(swift build --show-bin-path)/ringo"
fi
test -x "$ringo_bin" || { printf 'RINGO_BIN does not name an executable: %s\n' "$ringo_bin" >&2; exit 2; }
shim_dir="$work_root/bin"
mkdir -p "$shim_dir"
ln -s "$claude_bin" "$shim_dir/claude"

(
    cd "$fixture_repo"
    PATH="$shim_dir:$PATH" "$ringo_bin" claude --context-mode persistent -- \
        --print --dangerously-skip-permissions \
        'Inspect the assigned inputs, then complete the task. Follow all repository instructions.'
) >>"$log" 2>&1 &
agent_pid=$!

(
    sleep "$timeout_seconds"
    if kill -0 "$agent_pid" 2>/dev/null; then
        printf 'timeout\n' >"$timed_out"
        pkill -TERM -P "$agent_pid" 2>/dev/null || true
        kill -TERM "$agent_pid" 2>/dev/null || true
        sleep 2
        pkill -KILL -P "$agent_pid" 2>/dev/null || true
        kill -KILL "$agent_pid" 2>/dev/null || true
    fi
) &
watchdog_pid=$!

wait "$agent_pid"; agent_status=$?
kill "$watchdog_pid" 2>/dev/null || true
wait "$watchdog_pid" 2>/dev/null || true

test ! -f "$timed_out" || { printf 'Claude E2E timed out.\n' >&2; exit 1; }
test "$agent_status" -eq 0 || { printf 'Claude or bridge exited with status %s.\n' "$agent_status" >&2; exit 1; }
test -f "$fixture_repo/output/report.md" || { printf 'Missing output/report.md.\n' >&2; exit 1; }
cmp -s "$expected" "$fixture_repo/output/report.md" || { diff -u "$expected" "$fixture_repo/output/report.md" >&2 || true; exit 1; }
git -C "$fixture_repo" diff --quiet --no-ext-diff || { printf 'Tracked fixture content changed.\n' >&2; exit 1; }
test "$(git -C "$fixture_repo" status --short --untracked-files=all)" = '?? output/report.md' || {
    printf 'Claude made changes outside output/report.md.\n' >&2; exit 1;
}

passed=1
printf 'PASS: Claude followed CLAUDE.md and produced the exact report through AFM.\n'
