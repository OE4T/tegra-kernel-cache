"""Read sources/branches.yaml for tegra-kernel-cache scripts."""

from __future__ import annotations

import glob
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("PyYAML required: pip install pyyaml")


def die(msg: str) -> None:
    print(f"manifest: {msg}", file=sys.stderr)
    sys.exit(1)


def load_manifest(manifest_path: str | Path) -> dict:
    with open(manifest_path, encoding="utf-8") as f:
        doc = yaml.safe_load(f)
    _resolve_version_placeholders(doc)
    return doc


def _resolve_version_placeholders(doc: dict) -> None:
    version = doc.get("version_suffix")
    if not version:
        return
    if "yocto_base_ref" in doc:
        doc["yocto_base_ref"] = doc["yocto_base_ref"].replace("{version}", version)
    for q in doc.get("queues") or []:
        if "nvidia_branch" in q:
            q["nvidia_branch"] = q["nvidia_branch"].replace("{version}", version)


def resolve_linux_yocto(cache_root: Path, doc: dict, override: str | None) -> Path:
    if override:
        p = Path(override)
        if p.is_dir() and (p / ".git").exists():
            return p
        die(f"--linux-yocto is not a git checkout: {p}")

    mirror = cache_root / ".linux-yocto-mirror"
    if mirror.is_dir() and (mirror / ".git").exists():
        return mirror

    for rel in doc.get("linux_yocto_candidates") or []:
        for candidate in sorted(glob.glob(str(cache_root / rel))):
            p = Path(candidate)
            if p.is_dir() and (p / ".git").exists():
                return p
    die("linux-yocto git not found. Pass --linux-yocto PATH.")


def resolve_linux_yocto_upstream_url(doc: dict, override: str | None) -> str:
    """Authoritative linux-yocto URL: candidates are bootstrap-only, never this."""
    if override:
        return override
    url = doc.get("linux_yocto_upstream_url")
    if not url:
        die("missing linux_yocto_upstream_url in branches.yaml")
    return url


def export_order(doc: dict) -> list[dict]:
    """Queues in do_patch order: platform first, then the rest alphabetically."""
    enabled = [q for q in doc["queues"] if q.get("enable_in_bsp")]
    by_name = {q["name"]: q for q in enabled}
    ordered: list[dict] = []
    if "platform" in by_name:
        ordered.append(by_name.pop("platform"))
    ordered.extend(by_name[name] for name in sorted(by_name))
    return ordered
