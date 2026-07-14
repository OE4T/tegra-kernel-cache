# SPDX-License-Identifier: MIT
# shellcheck shell=bash
# Shared git settings for tegra-kernel-cache scripts.
# Sourced by refresh-from-nvidia.sh — do not execute directly.

# Environment for all child git processes (worktree ops use the git() wrapper below).
export_git_no_maintenance_env() {
    export GIT_OPTIONAL_LOCKS=0
    export GIT_CONFIG_COUNT=5
    export GIT_CONFIG_KEY_0=maintenance.auto
    export GIT_CONFIG_VALUE_0=false
    export GIT_CONFIG_KEY_1=gc.auto
    export GIT_CONFIG_VALUE_1=0
    export GIT_CONFIG_KEY_2=gc.autoDetach
    export GIT_CONFIG_VALUE_2=false
    export GIT_CONFIG_KEY_3=maintenance.commit-graph.auto
    export GIT_CONFIG_VALUE_3=false
    export GIT_CONFIG_KEY_4=maintenance.gc.auto
    export GIT_CONFIG_VALUE_4=false
}

# Persist settings in a repo and stop any running maintenance scheduler.
# Best-effort: config writes may fail on root-owned mirrors or under lock contention.
disable_git_maintenance_repo() {
    local repo="$1"
    git -C "$repo" config maintenance.auto false 2>/dev/null || true
    git -C "$repo" config gc.auto 0 2>/dev/null || true
    git -C "$repo" config gc.autoDetach false 2>/dev/null || true
    git -C "$repo" config maintenance.commit-graph.auto false 2>/dev/null || true
    git -C "$repo" config maintenance.gc.auto false 2>/dev/null || true
    git -C "$repo" maintenance stop 2>/dev/null || true
}

# Override bare `git` in scripts that source this file.
git() {
    command git \
        -c maintenance.auto=false \
        -c gc.auto=0 \
        -c gc.autoDetach=false \
        -c maintenance.commit-graph.auto=false \
        -c maintenance.gc.auto=false \
        "$@"
}
