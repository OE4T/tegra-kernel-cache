# SPDX-License-Identifier: MIT
# shellcheck shell=bash
# Warn when yocto_base_ref (branches.yaml) has drifted from the SRCREV_machine
# pinned by the linux-yocto recipe. Patches built against the wrong base can
# be silently wrong. Sourced by refresh-from-nvidia.sh and verify-queues.sh.

check_srcrev_pin() {
    local cache_root="$1" linux_yocto="$2" yocto_base="$3"
    local version bb candidates cand srcrev base_sha

    version="$(python3 -c "
import sys
sys.path.insert(0, '${cache_root}/scripts/lib')
from manifest import load_manifest
print(load_manifest('${cache_root}/sources/branches.yaml')['version_suffix'])
" 2>/dev/null)" || return 0
    [[ -n "$version" ]] || return 0

    candidates=(
        "${cache_root}/../repos/openembedded-core/meta/recipes-kernel/linux/linux-yocto_${version}.bb"
        "${cache_root}/../openembedded-core/meta/recipes-kernel/linux/linux-yocto_${version}.bb"
    )

    for cand in "${candidates[@]}"; do
        [[ -f "$cand" ]] || continue
        srcrev="$(grep -E '^SRCREV_machine[[:space:]]*\?=' "$cand" | head -1 \
            | sed -E 's/.*"([0-9a-f]{40})".*/\1/')"
        [[ -n "$srcrev" ]] || continue

        base_sha="$(git -C "$linux_yocto" rev-parse "$yocto_base" 2>/dev/null)" || return 0
        if [[ "$base_sha" != "$srcrev" ]]; then
            echo "" >&2
            echo "==> WARNING: yocto_base_ref drifted from the pinned kernel SRCREV" >&2
            echo "    yocto_base_ref ($yocto_base) resolves to: $base_sha" >&2
            echo "    SRCREV_machine in $cand: $srcrev" >&2
            echo "    Point yocto_base_ref in sources/branches.yaml at the pinned" >&2
            echo "    SRCREV, or pass a matching --linux-yocto checkout." >&2
            echo "" >&2
        fi
        return 0
    done
}
