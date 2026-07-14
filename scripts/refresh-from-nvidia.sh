#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Re-derive the kmeta patch queues from NVIDIA's linux-stable branches.
# Requires VPN/gerrit access to the nvidia remote. For the common case of
# keeping existing patches applying to a newer linux-yocto, use refresh.sh
# instead (no NVIDIA access needed). Both share lib/refresh-common.sh.
#
# Each queue is cherry-picked onto the cumulative base (yocto base + earlier
# queues, matching do_patch order). "New" commits are chosen by content
# (git cherry / patch-id), not commit-hash ancestry, since NVIDIA rebases their
# branches. An already-resolved on-disk patch with a matching Change-Id is
# reused (git am) rather than re-cherry-picked; only new/changed commits are
# re-derived and re-resolved. Conflicts pause for resolution in .refresh-worktree.
#
# Usage:
#   ./scripts/refresh-from-nvidia.sh --linux-yocto .linux-yocto-mirror --skip-fetch \
#     --nvidia-remote "$NVIDIA_LINUX_STABLE_URL" [queue ...]
#
# REFRESH_NO_REUSE=1 forces a full re-derive; REFRESH_FORCE=1 allows a queue
# over REFRESH_MAX_COMMITS (${REFRESH_MAX_COMMITS:-250}).

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEGRA_KERNEL_CACHE="${TEGRA_KERNEL_CACHE:-$(cd "${_SCRIPT_DIR}/.." && pwd)}"
export TEGRA_KERNEL_CACHE
export PYTHONPATH="${_SCRIPT_DIR}/lib${PYTHONPATH:+:$PYTHONPATH}"
# shellcheck source=lib/refresh-common.sh
source "${_SCRIPT_DIR}/lib/refresh-common.sh"
export_git_no_maintenance_env

NVIDIA_REMOTE_URL="${NVIDIA_LINUX_STABLE_URL:-}"
LINUX_YOCTO_OVERRIDE=""
SKIP_FETCH=0
DRY_RUN=0
INTERACTIVE=1
REQUEST_ARGS=()
REFRESH_MAX_COMMITS="${REFRESH_MAX_COMMITS:-250}"
EXPORT_WT="${TEGRA_KERNEL_CACHE}/.refresh-worktree"
LINUX_YOCTO_MIRROR="${TEGRA_KERNEL_CACHE}/.linux-yocto-mirror"
REFERENCE_CIDS_FILE=""

usage() {
    cat <<EOF
Usage: $(basename "$0") [options] [queue ...]

  --nvidia-remote URL   NVIDIA linux-stable remote (or set NVIDIA_LINUX_STABLE_URL)
  --linux-yocto PATH    checkout with nvidia refs (default: .linux-yocto-mirror)
  --skip-fetch          use refs already in the mirror
  --dry-run             print new-commit counts only
  --non-interactive     fail on conflicts instead of pausing
  -h, --help

No queue names refreshes all queues in do_patch order. Naming a subset applies
its predecessors from disk and re-derives only the named queues.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --nvidia-remote) NVIDIA_REMOTE_URL="$2"; shift 2 ;;
        --linux-yocto) LINUX_YOCTO_OVERRIDE="$2"; shift 2 ;;
        --skip-fetch) SKIP_FETCH=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --non-interactive) INTERACTIVE=0; shift ;;
        -h|--help) usage; exit 0 ;;
        *) REQUEST_ARGS+=("$1"); shift ;;
    esac
done

command -v git >/dev/null || die "missing: git"
command -v python3 >/dev/null || die "missing: python3"

[[ -n "$LINUX_YOCTO_OVERRIDE" ]] && export LINUX_YOCTO="$LINUX_YOCTO_OVERRIDE"
[[ -n "$NVIDIA_REMOTE_URL" ]] && export NVIDIA_LINUX_STABLE_URL_OVERRIDE="$NVIDIA_REMOTE_URL"

mapfile -t PLAN_LINES < <(python3 "${_SCRIPT_DIR}/lib/refresh_plan.py" "${REQUEST_ARGS[@]}")
SESSION=()
for line in "${PLAN_LINES[@]}"; do
    [[ "$line" == "__QUEUES__" ]] && continue
    if [[ "$line" == *"="* && "$line" != *"|"* ]]; then
        key="${line%%=*}"; val="${line#*=}"; val="${val%\"}"; val="${val#\"}"
        case "$key" in
            LINUX_YOCTO|LINUX_YOCTO_UPSTREAM_URL|YOCTO_BASE|NVIDIA_REMOTE|FETCH_BRANCHES) printf -v "$key" '%s' "$val" ;;
            NVIDIA_LINUX_STABLE_URL) NVIDIA_REMOTE_URL="$val" ;;
            REFERENCE_REMOTE|REFERENCE_REMOTE_URL|REFERENCE_REF) printf -v "$key" '%s' "$val" ;;
        esac
    elif [[ "$line" == *"|"* ]]; then
        SESSION+=("$line")
    fi
done

[[ -n "$NVIDIA_REMOTE_URL" ]] || die "pass --nvidia-remote or set NVIDIA_LINUX_STABLE_URL"
[[ ${#SESSION[@]} -gt 0 ]] || die "no queues in session"

REFERENCE_BRANCH=""
[[ -n "${REFERENCE_REMOTE:-}" && -n "${REFERENCE_REF:-}" ]] && REFERENCE_BRANCH="${REFERENCE_REMOTE}/${REFERENCE_REF}"

ensure_remote_synced() {
    local repo="$1" remote="$2" url="$3" current
    current="$(git -C "$repo" remote get-url "$remote" 2>/dev/null || true)"
    if [[ -z "$current" ]]; then
        git -C "$repo" remote add "$remote" "$url" 2>/dev/null || true
    elif [[ "$current" != "$url" ]]; then
        echo "==> $remote remote ($repo): $current -> $url"
        git -C "$repo" remote set-url "$remote" "$url"
    fi
}

ensure_mirror() {
    if [[ ! -e "${LINUX_YOCTO_MIRROR}/.git" ]]; then
        echo "==> mirror: ${LINUX_YOCTO_MIRROR} (reference $1, dissociated)"
        git clone --reference "$1" --dissociate "$LINUX_YOCTO_UPSTREAM_URL" "${LINUX_YOCTO_MIRROR}"
    fi
    LINUX_YOCTO="${LINUX_YOCTO_MIRROR}"
    disable_git_maintenance_repo "$LINUX_YOCTO"
    ensure_remote_synced "$LINUX_YOCTO" origin "$LINUX_YOCTO_UPSTREAM_URL"
}

is_version_bump_subject() { [[ "$1" =~ ^Linux\ [0-9]+(\.[0-9]+){0,2}(-rc[0-9]+)?$ ]]; }

commit_change_id() {
    git -C "$LINUX_YOCTO" log -1 --format='%B' "$1" \
        | { grep -oiE 'Change-Id: I[0-9a-f]{40}' || true; } | head -1 | awk '{print tolower($2)}'
}

commit_is_config_only() {
    local files f
    files="$(git -C "$LINUX_YOCTO" show --name-only --format='' "$1" 2>/dev/null | grep -v '^$' || true)"
    [[ -n "$files" ]] || return 1
    while IFS= read -r f; do
        [[ "$f" == *"/configs/"* || "$f" == *defconfig ]] || return 1
    done <<< "$files"
    return 0
}

patch_change_id() {
    { grep -oiE 'Change-Id: I[0-9a-f]{40}' "$1" 2>/dev/null || true; } | head -1 | awk '{print tolower($2)}'
}

# Build the reference Change-Id allow-set from REFERENCE_BRANCH's NVIDIA delta.
# strict=1 dies on a missing/empty result; strict=0 warns and skips filtering.
build_reference_change_ids() {
    local strict="${1:-1}"
    [[ -n "${REFERENCE_BRANCH:-}" ]] || return 0
    [[ -n "$REFERENCE_CIDS_FILE" ]] && return 0

    if ! git -C "$LINUX_YOCTO" rev-parse -q --verify "${REFERENCE_BRANCH}^{commit}" >/dev/null 2>&1; then
        (( strict )) && die "reference: branch ${REFERENCE_BRANCH} not in mirror (add the ${REFERENCE_REMOTE} remote and fetch)"
        echo "==> reference: ${REFERENCE_BRANCH} not found (filter off for estimate)" >&2
        return 0
    fi
    local mb
    mb="$(git -C "$LINUX_YOCTO" merge-base "$REFERENCE_BRANCH" "$YOCTO_BASE" 2>/dev/null || true)"
    [[ -n "$mb" ]] || { (( strict )) && die "reference: no merge-base with ${REFERENCE_BRANCH}"; return 0; }

    local tmp; tmp="$(mktemp)"
    git -C "$LINUX_YOCTO" log "${mb}..${REFERENCE_BRANCH}" --format='%B' 2>/dev/null \
        | grep -oiE 'Change-Id: I[0-9a-f]{40}' | awk '{print tolower($2)}' | sort -u > "$tmp"
    local n; n="$(wc -l < "$tmp")"
    (( n > 0 )) || { rm -f "$tmp"; (( strict )) && die "reference: harvested 0 Change-Ids from ${REFERENCE_BRANCH}"; return 0; }
    REFERENCE_CIDS_FILE="$tmp"
    echo "==> reference: ${n} Change-Ids from ${REFERENCE_BRANCH} (delta over ${mb:0:12})"
}

new_commits_for_queue() {
    local base="$1" branch="$2" reffilter="${3:-0}"
    while IFS= read -r line; do
        [[ "$line" == "+ "* ]] || continue
        local commit="${line#+ }" subject
        subject="$(git -C "$LINUX_YOCTO" log -1 --format=%s "$commit")"
        is_version_bump_subject "$subject" && continue
        commit_is_config_only "$commit" && continue
        if [[ "$reffilter" == "1" && -n "$REFERENCE_CIDS_FILE" ]]; then
            local cid; cid="$(commit_change_id "$commit")"
            { [[ -n "$cid" ]] && grep -qxF "$cid" "$REFERENCE_CIDS_FILE"; } || continue
        fi
        printf '%s\n' "$commit"
    done < <(git -C "$LINUX_YOCTO" cherry "$base" "$branch")
}

apply_queue() {
    local patchdir="$1"; shift
    local commits=("$@")
    local -A ondisk_pf=()
    if [[ -z "${REFRESH_NO_REUSE:-}" && -d "$patchdir" ]]; then
        shopt -s nullglob
        local pf pcid
        for pf in "$patchdir"/*.patch; do
            pcid="$(patch_change_id "$pf")"
            [[ -n "$pcid" ]] && ondisk_pf["$pcid"]="$pf"
        done
        shopt -u nullglob
    fi
    local total="${#commits[@]}" reused=0 derived=0 commit cid pf
    echo "    apply $total commits (reuse on-disk patch when it still applies)..."
    for commit in "${commits[@]}"; do
        cid="$(commit_change_id "$commit")"
        pf=""; [[ -n "$cid" ]] && pf="${ondisk_pf[$cid]:-}"
        if [[ -z "${REFRESH_NO_REUSE:-}" && -n "$pf" ]] && am_reuse "$pf"; then
            reused=$((reused + 1))
        else
            cherry_pick_one "$commit"; derived=$((derived + 1))
        fi
    done
    echo "    reused $reused · derived $derived new/changed"
}

nvidia_cleanup() { [[ -n "$REFERENCE_CIDS_FILE" ]] && rm -f "$REFERENCE_CIDS_FILE"; common_cleanup; }
trap nvidia_cleanup EXIT

LINUX_YOCTO_SRC="${LINUX_YOCTO:-}"
ensure_mirror "${LINUX_YOCTO_SRC:-${LINUX_YOCTO_MIRROR}}"
ensure_remote_synced "$LINUX_YOCTO" "$NVIDIA_REMOTE" "$NVIDIA_REMOTE_URL"
disable_git_maintenance_repo "$LINUX_YOCTO"
echo "==> mirror: $LINUX_YOCTO"

if [[ $DRY_RUN -eq 1 ]]; then
    build_reference_change_ids 0
    for entry in "${SESSION[@]}"; do
        IFS='|' read -r name branch _scc _write reffilter <<<"$entry"
        count="$(new_commits_for_queue "$YOCTO_BASE" "$branch" "$reffilter" | wc -l)"
        echo "  $name: $count new commits (approx, vs yocto base only)"
    done
    exit 0
fi

if [[ $SKIP_FETCH -eq 1 ]]; then
    echo "==> skip fetch"
else
    echo "==> fetch $NVIDIA_REMOTE"
    # shellcheck disable=SC2086
    git -C "$LINUX_YOCTO" fetch "$NVIDIA_REMOTE" $FETCH_BRANCHES --prune
    if [[ -n "${REFERENCE_BRANCH:-}" ]]; then
        ensure_remote_synced "$LINUX_YOCTO" "$REFERENCE_REMOTE" "$REFERENCE_REMOTE_URL"
        echo "==> fetch $REFERENCE_REMOTE ${REFERENCE_REF}"
        git -C "$LINUX_YOCTO" fetch "$REFERENCE_REMOTE" \
            "+refs/heads/${REFERENCE_REF}:refs/remotes/${REFERENCE_REMOTE}/${REFERENCE_REF}" --prune
    fi
fi

git -C "$LINUX_YOCTO" rev-parse --verify "$YOCTO_BASE" >/dev/null

# shellcheck source=lib/srcrev-check.sh
source "${_SCRIPT_DIR}/lib/srcrev-check.sh"
check_srcrev_pin "$TEGRA_KERNEL_CACHE" "$LINUX_YOCTO" "$YOCTO_BASE"

build_reference_change_ids 1
setup_worktree

PATCH_BASE="$YOCTO_BASE"
for entry in "${SESSION[@]}"; do
    IFS='|' read -r name branch scc_rel do_write reffilter <<<"$entry"
    scc="${TEGRA_KERNEL_CACHE}/${scc_rel}"
    patchdir="${scc%.scc}/patches"
    CURRENT_BRANCH="$branch"   # for describe_conflict's "final version" hint
    git checkout -q --detach "$PATCH_BASE"

    if [[ "$do_write" == "1" ]]; then
        mapfile -t new_commits < <(new_commits_for_queue "$PATCH_BASE" "$branch" "$reffilter")
        count="${#new_commits[@]}"
        echo "==> $name ($count new commits, base $(git log -1 --oneline "$PATCH_BASE"))"
        (( count <= REFRESH_MAX_COMMITS )) || [[ -n "${REFRESH_FORCE:-}" ]] \
            || die "$name: $count commits exceeds ${REFRESH_MAX_COMMITS}; set REFRESH_FORCE=1"
        if (( count > 0 )); then
            apply_queue "$patchdir" "${new_commits[@]}"
            write_patches "$patchdir" "$PATCH_BASE"
        else
            rm -rf "$patchdir" && mkdir -p "$patchdir"
        fi
        gen_queue_scc "$scc" "$patchdir" "$name"
    else
        echo "==> $name (existing patches, base $(git log -1 --oneline "$PATCH_BASE"))"
        apply_patch_files "$patchdir"
    fi
    PATCH_BASE="$(git rev-parse HEAD)"
done

finalize
