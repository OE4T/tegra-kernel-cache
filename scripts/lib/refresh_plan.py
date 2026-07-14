#!/usr/bin/env python3
"""Emit shell assignments and queue rows for refresh-from-nvidia.sh."""

from __future__ import annotations

import os
import sys
from pathlib import Path

from manifest import (
    die,
    export_order,
    load_manifest,
    resolve_linux_yocto,
    resolve_linux_yocto_upstream_url,
)


def remote_branch_path(branch: str, remote: str) -> str:
    prefix = f"{remote}/"
    return branch[len(prefix):] if branch.startswith(prefix) else branch


def local_branch_ref(branch: str, remote: str) -> str:
    return f"{remote}/{remote_branch_path(branch, remote)}"


def resolve_nvidia_url(cache_root: Path, doc: dict, override: str | None) -> str:
    if override:
        return override
    env = os.environ.get("NVIDIA_LINUX_STABLE_URL")
    if env:
        return env
    for raw in doc.get("nvidia_linux_stable_candidates") or []:
        path = Path(os.path.expandvars(raw))
        if path.is_dir() and (path / ".git").exists():
            return f"file://{path.resolve()}"
    die(
        "missing NVIDIA remote URL: pass --nvidia-remote, set NVIDIA_LINUX_STABLE_URL, "
        "or add a path under nvidia_linux_stable_candidates in branches.yaml"
    )


def session_queues(doc: dict, names: list[str]) -> tuple[list[dict], set[str]]:
    """Queues to build in git (cumulative) and which get patch files written."""
    ordered = export_order(doc)
    if not names:
        return ordered, {q["name"] for q in ordered}
    missing = set(names) - {q["name"] for q in ordered}
    if missing:
        die(f"unknown queue(s): {', '.join(sorted(missing))}")
    last = max(i for i, q in enumerate(ordered) if q["name"] in names)
    return ordered[: last + 1], set(names)


def main() -> None:
    cache_root = Path(os.environ.get("TEGRA_KERNEL_CACHE", Path(__file__).resolve().parents[2]))
    doc = load_manifest(cache_root / "sources" / "branches.yaml")

    linux = resolve_linux_yocto(cache_root, doc, os.environ.get("LINUX_YOCTO"))
    linux_upstream_url = resolve_linux_yocto_upstream_url(
        doc, os.environ.get("LINUX_YOCTO_UPSTREAM_URL_OVERRIDE")
    )
    nvidia_url = resolve_nvidia_url(cache_root, doc, os.environ.get("NVIDIA_LINUX_STABLE_URL_OVERRIDE"))
    session, write_targets = session_queues(doc, sys.argv[1:])

    remote = doc.get("nvidia_remote_name", "nvidia")
    fetch_paths = sorted({remote_branch_path(q["nvidia_branch"], remote) for q in session})

    print(f'LINUX_YOCTO="{linux}"')
    print(f'LINUX_YOCTO_UPSTREAM_URL="{linux_upstream_url}"')
    print(f'NVIDIA_LINUX_STABLE_URL="{nvidia_url}"')
    print(f'YOCTO_BASE="{os.environ.get("YOCTO_BASE") or doc["yocto_base_ref"]}"')
    print(f'NVIDIA_REMOTE="{remote}"')
    print(f'FETCH_BRANCHES="{" ".join(fetch_paths)}"')

    ref = doc.get("reference")
    if ref:
        print(f'REFERENCE_REMOTE="{ref["remote"]}"')
        print(f'REFERENCE_REMOTE_URL="{ref.get("remote_url") or nvidia_url}"')
        print(f'REFERENCE_REF="{ref.get("ref", "master")}"')

    print("__QUEUES__")
    for q in session:
        write = "1" if q["name"] in write_targets else "0"
        reffilter = "1" if (ref and q.get("reference_filter")) else "0"
        print("|".join([q["name"], local_branch_ref(q["nvidia_branch"], remote), q["scc"], write, reffilter]))


if __name__ == "__main__":
    main()
