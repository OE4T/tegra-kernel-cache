#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Refresh the kmeta patch queues against an updated linux-yocto.
#
# Replays the patches under features/tegra/*/patches onto a fresh linux-yocto
# base (git am --3way), pausing to resolve any conflict a moved base introduces,
# then rewrites the patches and regenerates the SCCs. This keeps the queues
# applying as the linux-yocto SRCREV advances.
#
# To pull new content from NVIDIA branches, use refresh-from-nvidia.sh. Both
# share scripts/lib/refresh-common.sh.
#
# Usage:
#   ./scripts/refresh.sh --linux-yocto PATH [queue ...]
#
# With no queue names, refreshes every queue in do_patch order. Naming a subset
# applies its predecessors (to build the cumulative base) but rewrites only the
# named queues. Override the base with YOCTO_BASE=<ref>.

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEGRA_KERNEL_CACHE="${TEGRA_KERNEL_CACHE:-$(cd "${_SCRIPT_DIR}/.." && pwd)}"
export TEGRA_KERNEL_CACHE
export PYTHONPATH="${_SCRIPT_DIR}/lib${PYTHONPATH:+:$PYTHONPATH}"
# shellcheck source=lib/refresh-common.sh
source "${_SCRIPT_DIR}/lib/refresh-common.sh"
export_git_no_maintenance_env

EXPORT_WT="${TEGRA_KERNEL_CACHE}/.refresh-worktree"
INTERACTIVE=1
REQUEST_ARGS=()

usage() {
    cat <<EOF
Usage: $(basename "$0") [--linux-yocto PATH] [--non-interactive] [queue ...]

  --linux-yocto PATH   linux-yocto checkout to rebuild against (default: .linux-yocto-mirror)
  --non-interactive    fail on conflicts instead of pausing to resolve
  -h, --help

Replays the committed patches onto the linux-yocto base. Override the base with
YOCTO_BASE=<ref>.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --linux-yocto) export LINUX_YOCTO="$2"; shift 2 ;;
        --non-interactive) INTERACTIVE=0; shift ;;
        -h|--help) usage; exit 0 ;;
        *) REQUEST_ARGS+=("$1"); shift ;;
    esac
done

command -v git >/dev/null || die "missing: git"
command -v python3 >/dev/null || die "missing: python3"

mapfile -t PLAN < <(python3 - "$TEGRA_KERNEL_CACHE" "${REQUEST_ARGS[@]}" <<'PY'
import os, sys
from pathlib import Path
from manifest import export_order, load_manifest, resolve_linux_yocto

cache = Path(sys.argv[1])
names = sys.argv[2:]
doc = load_manifest(cache / "sources" / "branches.yaml")
linux = resolve_linux_yocto(cache, doc, os.environ.get("LINUX_YOCTO"))
ordered = export_order(doc)
if names:
    missing = set(names) - {q["name"] for q in ordered}
    if missing:
        sys.exit("refresh: unknown queue(s): " + ", ".join(sorted(missing)))
    last = max(i for i, q in enumerate(ordered) if q["name"] in names)
    session, targets = ordered[: last + 1], set(names)
else:
    session, targets = ordered, {q["name"] for q in ordered}
print(f"LINUX_YOCTO={linux}")
print(f'YOCTO_BASE={os.environ.get("YOCTO_BASE") or doc["yocto_base_ref"]}')
for q in session:
    print(f'QUEUE|{q["name"]}|{q["scc"]}|{"1" if q["name"] in targets else "0"}')
PY
)

LINUX_YOCTO=""; YOCTO_BASE=""; SESSION=()
for line in "${PLAN[@]}"; do
    case "$line" in
        LINUX_YOCTO=*) export LINUX_YOCTO="${line#LINUX_YOCTO=}" ;;
        YOCTO_BASE=*)  YOCTO_BASE="${line#YOCTO_BASE=}" ;;
        QUEUE\|*)      SESSION+=("${line#QUEUE|}") ;;
    esac
done
[[ -n "$LINUX_YOCTO" && -n "$YOCTO_BASE" ]] || die "could not resolve linux-yocto (pass --linux-yocto)"
[[ ${#SESSION[@]} -gt 0 ]] || die "no queues"

disable_git_maintenance_repo "$LINUX_YOCTO"
git -C "$LINUX_YOCTO" rev-parse --verify "$YOCTO_BASE" >/dev/null

# shellcheck source=lib/srcrev-check.sh
source "${_SCRIPT_DIR}/lib/srcrev-check.sh"
check_srcrev_pin "$TEGRA_KERNEL_CACHE" "$LINUX_YOCTO" "$YOCTO_BASE"

trap common_cleanup EXIT
echo "==> linux-yocto: $LINUX_YOCTO"
echo "==> base: $(git -C "$LINUX_YOCTO" log -1 --oneline "$YOCTO_BASE")"
setup_worktree

PATCH_BASE="$YOCTO_BASE"
for entry in "${SESSION[@]}"; do
    IFS='|' read -r name scc_rel do_write <<<"$entry"
    scc="${TEGRA_KERNEL_CACHE}/${scc_rel}"
    patchdir="${scc%.scc}/patches"
    git checkout -q --detach "$PATCH_BASE"
    echo "==> $name"
    apply_patch_files "$patchdir"
    if [[ "$do_write" == "1" ]]; then
        write_patches "$patchdir" "$PATCH_BASE"
        gen_queue_scc "$scc" "$patchdir" "$name"
    fi
    PATCH_BASE="$(git rev-parse HEAD)"
done

finalize
