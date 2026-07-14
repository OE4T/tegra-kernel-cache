# SPDX-License-Identifier: MIT
# shellcheck shell=bash
# Shared machinery for refresh.sh and refresh-from-nvidia.sh.
# Sourced, not executed. Callers must set TEGRA_KERNEL_CACHE, LINUX_YOCTO,
# EXPORT_WT, YOCTO_BASE, and INTERACTIVE before sourcing.

_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=git-env.sh
source "${_COMMON_DIR}/git-env.sh"

die() { echo "$(basename "${0}"): $*" >&2; exit 1; }

setup_worktree() {
    git -C "$LINUX_YOCTO" worktree list --porcelain | grep -qF "worktree ${EXPORT_WT}" || {
        mkdir -p "$(dirname "$EXPORT_WT")"
        git -C "$LINUX_YOCTO" worktree add --detach "$EXPORT_WT" "$YOCTO_BASE"
    }
    cd "$EXPORT_WT"
    git checkout -q --detach "$YOCTO_BASE" 2>/dev/null || git checkout -q -B kmeta-export-idle "$YOCTO_BASE"
}

common_cleanup() {
    [[ -d "${EXPORT_WT}" ]] || return 0
    git -C "$EXPORT_WT" am --abort 2>/dev/null || true
    git -C "$EXPORT_WT" cherry-pick --abort 2>/dev/null || true
    git -C "$EXPORT_WT" checkout -q --detach "$YOCTO_BASE" 2>/dev/null || true
}

describe_conflict() {
    local commit="${1:-}"
    echo "  conflict:"
    [[ -n "$commit" ]] && git -C "$LINUX_YOCTO" log -1 \
        --format='  incoming: %h  %an  %ad%n    %s' --date=short "$commit" 2>/dev/null
    local f
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        local stages hunks kind
        stages="$(git ls-files -u -- "$f" 2>/dev/null | awk '{print $3}' | sort -u | tr '\n' ',')"
        hunks="$(grep -cE '^<<<<<<< ' "$f" 2>/dev/null || echo 0)"
        [[ "$stages" != *1* ]] && kind="add/add -- usually union both sides" || kind="content -- reconcile onto our shape"
        echo "    $f  [${hunks} hunk(s)]  $kind"
    done < <(git diff --name-only --diff-filter=U 2>/dev/null)
    [[ -n "${CURRENT_BRANCH:-}" ]] && {
        echo "  intended final version of a file:"
        echo "    git -C $LINUX_YOCTO show ${CURRENT_BRANCH}:<path>"
    }
}

prompt_resolve_conflict() {
    local op="$1" hint="${2:-}" commit="${3:-}"
    echo ""
    echo "==> ${op} conflict in ${EXPORT_WT}"
    [[ -n "$hint" ]] && echo "    ${hint}"
    describe_conflict "$commit"
    echo ""
    echo "  Resolve with the helper (from ${TEGRA_KERNEL_CACHE}):"
    echo "    scripts/resolve-conflict.sh status"
    echo "    scripts/resolve-conflict.sh union|ours|theirs <file>..."
    echo "    scripts/resolve-conflict.sh continue | skip | abort"
    echo ""
    if (( INTERACTIVE )); then
        if [[ -t 0 ]]; then
            read -r -p "Press Enter when ${op} is complete... "
        else
            echo "  (stdin is not a terminal -- polling until resolved)"
            sleep 5
        fi
    else
        die "${op} conflict -- resolve in ${EXPORT_WT} or drop --non-interactive"
    fi
}

# A clean 3-way merge with no net change: content already present, safe to skip.
cherry_pick_is_empty_noop() {
    [[ -z "$(git diff --name-only --diff-filter=U)" ]] && git diff --quiet && git diff --cached --quiet
}

wait_for_cherry_pick() {
    local commit="$1" subject
    subject="$(git -C "$LINUX_YOCTO" log -1 --format=%s "$commit")"
    while git rev-parse -q CHERRY_PICK_HEAD >/dev/null 2>&1; do
        if cherry_pick_is_empty_noop; then
            echo "    skip (empty after merge -- already present): $subject"
            git cherry-pick --skip
            continue
        fi
        prompt_resolve_conflict "cherry-pick" "$subject" "$commit"
    done
}

am_in_progress() {
    local gitdir; gitdir="$(git rev-parse --git-dir)"
    [[ -d "${gitdir}/rebase-apply" && -f "${gitdir}/rebase-apply/applying" ]]
}

wait_for_am() { while am_in_progress; do prompt_resolve_conflict "am"; done; }

cherry_pick_one() {
    local commit="$1"
    git cherry-pick "$commit" && return 0
    if git rev-parse -q CHERRY_PICK_HEAD >/dev/null 2>&1; then
        wait_for_cherry_pick "$commit"
    else
        git cherry-pick --abort 2>/dev/null || true
        die "cherry-pick failed: $(git -C "$LINUX_YOCTO" log -1 --format=%s "$commit")"
    fi
}

# git am one on-disk patch; returns 1 on any conflict so caller can cherry-pick instead.
am_reuse() {
    git am --3way --no-gpg-sign "$1" >/dev/null 2>&1 && return 0
    git am --abort >/dev/null 2>&1 || true
    return 1
}

apply_patch_files() {
    local patchdir="$1"
    shopt -s nullglob
    local patches=("${patchdir}"/*.patch)
    shopt -u nullglob
    [[ "${#patches[@]}" -gt 0 ]] || return 0
    echo "    git am ${#patches[@]} patches..."
    git am --3way --no-gpg-sign "${patches[@]}" && return 0
    if am_in_progress; then
        wait_for_am
    else
        git am --abort 2>/dev/null || true
        die "git am failed applying patches from ${patchdir}"
    fi
}

write_patches() {
    local patchdir="$1" base="$2" tmpdir n=1
    tmpdir="$(mktemp -d)"
    rm -rf "$patchdir"
    git format-patch --no-stat --zero-commit -o "$tmpdir" "${base}..HEAD" >/dev/null
    mkdir -p "$patchdir"
    shopt -s nullglob
    for f in "$tmpdir"/*.patch; do
        local name="${f##*/}"; name="${name#*-}"
        mv "$f" "${patchdir}/$(printf '%04d' "$n")-${name}"
        n=$((n + 1))
    done
    shopt -u nullglob
    rm -rf "$tmpdir"
    echo "    wrote $((n - 1)) patches -> $patchdir"
}

gen_queue_scc() { "${TEGRA_KERNEL_CACHE}/scripts/generate-scc.sh" "$1" "$2" "$3"; }

finalize() {
    "${TEGRA_KERNEL_CACHE}/scripts/generate-scc.sh" --aggregator
    "${TEGRA_KERNEL_CACHE}/scripts/verify-queues.sh"
    echo "Done."
}
