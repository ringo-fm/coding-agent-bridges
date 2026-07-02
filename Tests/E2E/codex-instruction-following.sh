#!/usr/bin/env bash

set -u

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
codex_bin="${CODEX_BIN:-$(command -v codex 2>/dev/null || true)}"
timeout_seconds="${E2E_TIMEOUT_SECONDS:-180}"
work_root="$(mktemp -d "${TMPDIR:-/tmp}/codex-afm-e2e.XXXXXX")"
fixture_repo="$work_root/repo"
expected="$work_root/expected-report.md"
log="$work_root/codex.log"
timed_out="$work_root/timed-out"
passed=0

diagnose() {
    printf '\nCodex instruction-following E2E failed.\n'
    printf 'Workspace: %s\n' "$work_root"
    if test -s "$log"; then
        printf '\n--- Codex / bridge output ---\n'
        sed -n '1,320p' "$log"
    fi
    if test -d "$fixture_repo/.git"; then
        printf '\n--- git status ---\n'
        git -C "$fixture_repo" status --short --untracked-files=all
        printf '\n--- tracked diff ---\n'
        git -C "$fixture_repo" diff --no-ext-diff
        if test -f "$fixture_repo/output/report.md"; then
            printf '\n--- generated report ---\n'
            sed -n '1,160p' "$fixture_repo/output/report.md"
        fi
    fi
}

cleanup() {
    if test "$passed" -eq 1; then
        rm -rf "$work_root"
    else
        diagnose
    fi
}
trap cleanup EXIT

if test -z "$codex_bin" || ! test -x "$codex_bin"; then
    printf 'CODEX_BIN does not name an executable Codex CLI: %s\n' "${codex_bin:-<empty>}" >&2
    exit 2
fi
if ! "$codex_bin" --version >"$log" 2>&1; then
    printf 'Codex CLI failed its version preflight: %s\n' "$codex_bin" >&2
    exit 2
fi
case "$timeout_seconds" in
    ''|*[!0-9]*) printf 'E2E_TIMEOUT_SECONDS must be a positive integer.\n' >&2; exit 2 ;;
    0) printf 'E2E_TIMEOUT_SECONDS must be greater than zero.\n' >&2; exit 2 ;;
esac

mkdir -p "$fixture_repo/input"
printf '%s\n' \
    '# Repository instructions' \
    '' \
    '- Complete the task described in TASK.md.' \
    '- You may inspect tracked inputs before making the change.' \
    '- Only create `output/report.md`; do not modify or delete tracked content.' \
    '- The report must match the requested format exactly, with no extra text.' \
    >"$fixture_repo/AGENTS.md"
printf '%s\n' \
    '# Task' \
    '' \
    'Read `input/records.tsv` and select rows whose status is exactly `active`.' \
    'Sort selected rows by numeric ID ascending.' \
    'Create `output/report.md` with the heading `# Active records`, followed by' \
    'one bullet per row in the form `- <id>: <name>`.' \
    >"$fixture_repo/TASK.md"
printf '%s\n' \
    $'id\tname\tstatus' \
    $'11\tcedar\tactive' \
    $'7\tmaple\tinactive' \
    $'3\tspruce\tactive' \
    $'20\twillow\tpending' \
    >"$fixture_repo/input/records.tsv"
printf '%s\n' \
    '# Active records' \
    '- 3: spruce' \
    '- 11: cedar' \
    >"$expected"

git -C "$fixture_repo" init -q
git -C "$fixture_repo" add AGENTS.md TASK.md input/records.tsv
git -C "$fixture_repo" \
    -c user.name='Codex E2E' \
    -c user.email='codex-e2e@example.invalid' \
    commit -qm 'Create instruction-following fixture'

cd "$repo_root"
ringo_bin="${RINGO_BIN:-}"
if test -z "$ringo_bin"; then
    if ! swift build --product ringo >>"$log" 2>&1; then
        printf 'Failed to build the ringo executable.\n' >&2
        exit 1
    fi
    bin_path="$(swift build --show-bin-path)"
    ringo_bin="$bin_path/ringo"
fi
if ! test -x "$ringo_bin"; then
    printf 'RINGO_BIN does not name an executable: %s\n' "$ringo_bin" >&2
    exit 2
fi
shim_dir="$work_root/bin"
mkdir -p "$shim_dir"
ln -s "$codex_bin" "$shim_dir/codex"

(
    PATH="$shim_dir:$PATH" \
    AFM_BRIDGE_PROFILE=codex-tools \
    "$ringo_bin" codex --isolated-config -- exec \
        --ephemeral \
        --sandbox workspace-write \
        --cd "$fixture_repo" \
        'Inspect the assigned inputs, then complete the task. Follow all repository instructions.'
) >>"$log" 2>&1 &
codex_pid=$!

(
    sleep "$timeout_seconds"
    if kill -0 "$codex_pid" 2>/dev/null; then
        printf 'timeout\n' >"$timed_out"
        child_pids="$(pgrep -P "$codex_pid" 2>/dev/null || true)"
        if test -n "$child_pids"; then
            kill -TERM $child_pids 2>/dev/null || true
        fi
        kill -TERM "$codex_pid" 2>/dev/null || true
        sleep 2
        if test -n "$child_pids"; then
            kill -KILL $child_pids 2>/dev/null || true
        fi
        kill -KILL "$codex_pid" 2>/dev/null || true
    fi
) &
watchdog_pid=$!

wait "$codex_pid"
codex_status=$?
kill "$watchdog_pid" 2>/dev/null || true
wait "$watchdog_pid" 2>/dev/null || true

if test -f "$timed_out"; then
    printf 'Codex E2E timed out after %s seconds.\n' "$timeout_seconds" >&2
    exit 1
fi
if test "$codex_status" -ne 0; then
    printf 'Codex or the AFM bridge exited with status %s.\n' "$codex_status" >&2
    exit 1
fi
if ! test -f "$fixture_repo/output/report.md"; then
    printf 'Codex did not create output/report.md.\n' >&2
    exit 1
fi
if ! cmp -s "$expected" "$fixture_repo/output/report.md"; then
    printf 'Generated report did not exactly match the expected content.\n' >&2
    diff -u "$expected" "$fixture_repo/output/report.md" >&2 || true
    exit 1
fi
if ! git -C "$fixture_repo" diff --quiet --no-ext-diff; then
    printf 'Codex modified tracked fixture content.\n' >&2
    exit 1
fi
actual_status="$(git -C "$fixture_repo" status --short --untracked-files=all)"
if test "$actual_status" != '?? output/report.md'; then
    printf 'Codex made changes outside output/report.md: %s\n' "$actual_status" >&2
    exit 1
fi

passed=1
printf 'PASS: Codex followed AGENTS.md and produced the exact report through AFM.\n'
