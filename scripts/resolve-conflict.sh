#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Safe conflict-resolution helper for refresh-from-nvidia.sh.
#
# When the refresh pauses on a cherry-pick (or git am) conflict in the export
# worktree (.refresh-worktree), use these verbs instead of hand-driving git —
# they pick a side (or union both), VERIFY no conflict markers remain before
# staging, and continue the right operation with a non-interactive editor. This
# removes the easy footguns: continuing with markers still in a file, or using
# `--quit` (which silently drops the commit) instead of `--skip`/`--abort`.
#
# Usage (run from the tegra-kernel-cache root):
#   scripts/resolve-conflict.sh status                 # unmerged files + hunk counts + op
#   scripts/resolve-conflict.sh union  <file>...       # keep BOTH sides (drop markers)
#   scripts/resolve-conflict.sh ours   <file>...       # keep our (cumulative-base) side
#   scripts/resolve-conflict.sh theirs <file>...       # keep the incoming commit's side
#   scripts/resolve-conflict.sh continue               # verify clean, then <op> --continue
#   scripts/resolve-conflict.sh skip                   # drop this commit (<op> --skip)
#   scripts/resolve-conflict.sh abort                  # abort the whole <op>
#
# Resolve every conflicted file (mix verbs as needed), then `continue`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE="${TEGRA_KERNEL_CACHE:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
WT="${REFRESH_WORKTREE:-${CACHE}/.refresh-worktree}"

die() { echo "resolve-conflict: $*" >&2; exit 1; }
g() { git -C "$WT" "$@"; }

[[ -d "$WT/.git" || -f "$WT/.git" ]] || die "no export worktree at $WT (is a refresh paused?)"

# Which operation is mid-flight, so continue/skip/abort target the right one.
current_op() {
    local gd; gd="$(g rev-parse --git-dir)"
    if g rev-parse -q --verify CHERRY_PICK_HEAD >/dev/null 2>&1; then echo cherry-pick
    elif [[ -d "$WT/$gd/rebase-apply" ]]; then echo am
    else echo none; fi
}

unmerged() { g diff --name-only --diff-filter=U 2>/dev/null; }

markers_in() { grep -cE '^(<<<<<<< |=======$|>>>>>>> )' "$1" 2>/dev/null || true; }

require_no_markers() {
    local f bad=0
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        if [[ "$(grep -cE '^(<<<<<<< |>>>>>>> )' "$WT/$f" 2>/dev/null || echo 0)" != 0 ]]; then
            echo "  STILL HAS MARKERS: $f" >&2; bad=1
        fi
    done < <(g diff --name-only 2>/dev/null)
    return $bad
}

cmd="${1:-status}"; shift || true
op="$(current_op)"

case "$cmd" in
status)
    echo "operation in progress: $op"
    echo "unmerged files:"
    local_any=0
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        local_any=1
        stages="$(g ls-files -u -- "$f" | awk '{print $3}' | sort -u | tr '\n' ',')"
        hunks="$(grep -cE '^<<<<<<< ' "$WT/$f" 2>/dev/null || echo 0)"
        kind="content(category 3)"; [[ "$stages" != *1* ]] && kind="add/add(category 1 — union)"
        printf '    %-60s [%s hunk(s)] %s\n' "$f" "$hunks" "$kind"
    done < <(unmerged)
    [[ "$local_any" == 0 ]] && echo "    (none — ready to 'continue')"
    ;;
union)
    [[ $# -gt 0 ]] || die "union needs file(s)"
    for f in "$@"; do
        [[ -f "$WT/$f" ]] || die "no such file: $f"
        sed -i '/^<<<<<<< /d; /^=======$/d; /^>>>>>>> /d' "$WT/$f"
        [[ "$(markers_in "$WT/$f")" == 0 ]] || die "markers remain in $f after union (diff3 conflict? resolve by hand)"
        g add -- "$f"
        echo "  union: kept both sides, staged $f"
    done
    ;;
ours|theirs)
    [[ $# -gt 0 ]] || die "$cmd needs file(s)"
    for f in "$@"; do
        g checkout "--$cmd" -- "$f"
        g add -- "$f"
        echo "  $cmd: staged $f"
    done
    ;;
continue)
    [[ "$op" == none ]] && die "no cherry-pick/am in progress"
    if [[ -n "$(unmerged)" ]]; then
        echo "unmerged files remain — resolve them first:" >&2; unmerged | sed 's/^/    /' >&2; exit 1
    fi
    require_no_markers || die "conflict markers still present in staged files — fix before continuing"
    GIT_EDITOR=true g "$op" --continue
    echo "  continued ($op). New state:"; "$0" status
    ;;
skip)
    [[ "$op" == none ]] && die "no cherry-pick/am in progress"
    g "$op" --skip
    echo "  skipped this commit ($op)."
    ;;
abort)
    [[ "$op" == none ]] && die "no cherry-pick/am in progress"
    g "$op" --abort
    echo "  aborted ($op)."
    ;;
*)
    die "unknown command: $cmd (use: status|union|ours|theirs|continue|skip|abort)"
    ;;
esac
