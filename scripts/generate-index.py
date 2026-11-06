#!/usr/bin/env python3
"""Generate the machine-readable mirror catalog (index.json) from images/*.yaml.

Downstream consumers read this file to resolve an image name + version to its
Harbor target and digest. The file is committed so a catalog change is reviewed
together with the image manifest.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover - exercised by humans without deps
    sys.exit("PyYAML is required: python3 -m pip install pyyaml")

ROOT = Path(__file__).resolve().parent.parent


def _consumers(path: Path, name: str, img: dict) -> list[str]:
    raw = img.get("consumers")
    if not isinstance(raw, list) or not raw:
        raise SystemExit(f"{path}: {name}: consumers must be a non-empty list")
    consumers: list[str] = []
    for item in raw:
        if not isinstance(item, str):
            raise SystemExit(f"{path}: {name}: consumer must be a string")
        value = item.strip()
        if not value:
            raise SystemExit(f"{path}: {name}: consumer must not be empty")
        if value not in consumers:
            consumers.append(value)
    return consumers


def load_images(images_dir: Path) -> list[dict]:
    images: list[dict] = []
    seen: set[tuple[str, str]] = set()
    for path in sorted(images_dir.glob("*.yaml")):
        doc = yaml.safe_load(path.read_text(encoding="utf-8"))
        if not isinstance(doc, dict):
            raise SystemExit(f"{path}: not a YAML mapping")
        category = ((doc.get("metadata") or {}).get("name") or path.stem).strip()
        defaults = ((doc.get("spec") or {}).get("defaults") or {}).get("platforms") or []
        for img in (doc.get("spec") or {}).get("images") or []:
            name = str(img.get("name", "")).strip()
            if not name:
                raise SystemExit(f"{path}: image without a name")
            key = (category, name)
            if key in seen:
                raise SystemExit(f"{path}: duplicate image name '{name}' in category '{category}'")
            seen.add(key)
            consumers = _consumers(path, name, img)
            platforms = img.get("platforms") or defaults
            versions = []
            for ver in img.get("versions") or []:
                entry = {"tag": str(ver.get("tag", ""))}
                if ver.get("digest"):
                    entry["digest"] = str(ver["digest"])
                entry["platforms"] = list(platforms)
                versions.append(entry)
            versions.sort(key=lambda v: v["tag"])
            images.append(
                {
                    "id": f"{category}/{name}",
                    "name": name,
                    "consumers": consumers,
                    "category": category,
                    "source": str(img.get("source", "")),
                    "target": str(img.get("target", "")),
                    "versions": versions,
                }
            )
    images.sort(key=lambda i: i["name"])
    return images


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--images-dir", type=Path, default=ROOT / "images")
    ap.add_argument("--output", type=Path, default=ROOT / "index.json")
    args = ap.parse_args()

    data = {"schema": 2, "images": load_images(args.images_dir)}
    text = json.dumps(data, ensure_ascii=False, indent=2) + "\n"
    if str(args.output) == "-":
        sys.stdout.write(text)
    else:
        args.output.write_text(text, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
