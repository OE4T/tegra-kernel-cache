#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Verify patch queues: SCC lists match disk; optionally apply all patches in order.
#
#   verify-queues.sh                          list vs disk only
#   verify-queues.sh --apply                  git am every queue on yocto base
#   verify-queues.sh --apply --linux-yocto PATH

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEGRA_KERNEL_CACHE="${TEGRA_KERNEL_CACHE:-$(cd "${_SCRIPT_DIR}/.." && pwd)}"
export PYTHONPATH="${_SCRIPT_DIR}/lib${PYTHONPATH:+:$PYTHONPATH}"

APPLY=0
LINUX_YOCTO_OVERRIDE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --apply) APPLY=1; shift ;;
        --linux-yocto) LINUX_YOCTO_OVERRIDE="$2"; shift 2 ;;
        -h|--help)
            cat <<EOF
Usage: $(basename "$0") [--apply] [--linux-yocto PATH]

  default     each queue .scc matches patches/ on disk
  --apply     reset worktree to yocto base and git am all queues in order
EOF
            exit 0
            ;;
        *) echo "verify-queues: unknown option: $1" >&2; exit 1 ;;
    esac
done

[[ -n "$LINUX_YOCTO_OVERRIDE" ]] && export LINUX_YOCTO="$LINUX_YOCTO_OVERRIDE"

python3 - "$TEGRA_KERNEL_CACHE" <<'PY'
import re
import sys
from pathlib import Path

from manifest import export_order, load_manifest

cache_root = Path(sys.argv[1])
doc = load_manifest(cache_root / "sources" / "branches.yaml")
features = cache_root / "features" / "tegra"
errors = 0

for q in export_order(doc):
    scc = cache_root / q["scc"]
    patchdir = scc.with_suffix("") / "patches"
    if not scc.is_file():
        print(f"ERROR: missing {scc}")
        errors += 1
        continue
    listed = []
    for line in scc.read_text(encoding="utf-8").splitlines():
        m = re.match(r"^patch\s+(\S+)", line)
        if m:
            listed.append(m.group(1))
    on_disk = sorted(p.name for p in patchdir.glob("*.patch")) if patchdir.is_dir() else []
    listed_names = [Path(p).name for p in listed]
    if not listed and not on_disk:
        print(f"WARN:  {q['name']}: no patches")
        errors += 1
        continue
    missing = set(listed_names) - set(on_disk)
    extra = set(on_disk) - set(listed_names)
    if missing or extra:
        print(f"ERROR: {q['name']}: scc/disk mismatch")
        for p in sorted(missing):
            print(f"  missing on disk: {p}")
        for p in sorted(extra):
            print(f"  not listed in scc: {p}")
        errors += 1
    else:
        print(f"OK:    {q['name']}: {len(on_disk)} patches")

if errors:
    sys.exit(1)
PY

echo "verify-queues: all queues consistent"

if [[ $APPLY -eq 0 ]]; then
    exit 0
fi

# shellcheck source=lib/git-env.sh
source "${_SCRIPT_DIR}/lib/git-env.sh"
export_git_no_maintenance_env

EXPORT_WT="${TEGRA_KERNEL_CACHE}/.refresh-worktree"
mapfile -t APPLY_PLAN < <(python3 - "$TEGRA_KERNEL_CACHE" <<'PY'
import re
import os
import sys
from pathlib import Path

from manifest import export_order, load_manifest, resolve_linux_yocto

cache_root = Path(sys.argv[1])
doc = load_manifest(cache_root / "sources" / "branches.yaml")
linux = resolve_linux_yocto(cache_root, doc, os.environ.get("LINUX_YOCTO"))
features = cache_root / "features" / "tegra"
print(f"LINUX_YOCTO={linux}")
print(f"YOCTO_BASE={doc['yocto_base_ref']}")
for q in export_order(doc):
    scc = cache_root / q["scc"]
    for line in scc.read_text(encoding="utf-8").splitlines():
        m = re.match(r"^patch\s+(\S+)", line)
        if m:
            print(f"{q['name']}|{features / m.group(1)}")
PY
)

LINUX_YOCTO=""
YOCTO_BASE=""
PATCH_ROWS=()
for line in "${APPLY_PLAN[@]}"; do
    case "$line" in
        LINUX_YOCTO=*) LINUX_YOCTO="${line#LINUX_YOCTO=}" ;;
        YOCTO_BASE=*) YOCTO_BASE="${line#YOCTO_BASE=}" ;;
        *) PATCH_ROWS+=("$line") ;;
    esac
done

[[ -n "$LINUX_YOCTO" && -n "$YOCTO_BASE" ]] || {
    echo "verify-queues: could not resolve linux-yocto (pass --linux-yocto)" >&2
    exit 1
}

# shellcheck source=lib/srcrev-check.sh
source "${_SCRIPT_DIR}/lib/srcrev-check.sh"
check_srcrev_pin "$TEGRA_KERNEL_CACHE" "$LINUX_YOCTO" "$YOCTO_BASE"

if ! git -C "$LINUX_YOCTO" worktree list --porcelain | grep -qF "worktree ${EXPORT_WT}"; then
    mkdir -p "$(dirname "$EXPORT_WT")"
    git -C "$LINUX_YOCTO" worktree add --detach "$EXPORT_WT" "$YOCTO_BASE"
fi

cd "$EXPORT_WT"
git am --abort 2>/dev/null || true
git rebase --abort 2>/dev/null || true
git checkout -q --detach "$YOCTO_BASE"

echo "verify-queues: applying ${#PATCH_ROWS[@]} patches on $YOCTO_BASE"

prev_queue=""
n=0
for row in "${PATCH_ROWS[@]}"; do
    IFS='|' read -r queue patchpath <<<"$row"
    [[ -f "$patchpath" ]] || {
        echo "verify-queues: missing patch file: $patchpath" >&2
        exit 1
    }
    n=$((n + 1))
    if [[ "$queue" != "$prev_queue" && -n "$prev_queue" ]]; then
        echo "    queue $prev_queue done"
    fi
    if [[ "$queue" != "$prev_queue" ]]; then
        echo "==> $queue"
        prev_queue="$queue"
    fi
    if ! git am --3way --no-gpg-sign "$patchpath" >/dev/null 2>&1; then
        echo "verify-queues: git am failed on patch $n ($queue):" >&2
        echo "  $patchpath" >&2
        git am --abort 2>/dev/null || true
        exit 1
    fi
done
[[ -n "$prev_queue" ]] && echo "    queue $prev_queue done"

echo "verify-queues: all ${#PATCH_ROWS[@]} patches applied successfully"
