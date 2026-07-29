#!/usr/bin/env python3
"""Fail closed when a Kindle release misses required safety metadata."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import zipfile
from pathlib import Path

REQUIRED = {
    "wereader/launch.sh",
    "wereader/update.sh",
    "wereader/update-public.key",
    "wereader/collect_diagnostics.sh",
    "wereader/redact_stream.sh",
    "wereader/menu.json",
    "wereader/version.json",
    "wereader/bin/luajit",
    "wereader/bin/minisign",
    "wereader/lib/liblvgl.so",
    "wereader/lib/libwereader_kindledisplay.so",
    "wereader/lib/libfbink.so.1",
    "wereader/lib/libcrbridge.so",
    "wereader/LICENSE",
    "wereader/NOTICE",
    "wereader/share/sbom.spdx.json",
    "wereader/share/THIRD_PARTY_LICENSES.md",
    "wereader/share/SOURCE_OFFER.md",
    "wereader/share/dependencies.lock",
    "wereader/share/runtime-dependencies.lock",
}
REQUIRED_COMPONENTS = {
    "FBInk",
    "LVGL",
    "crengine",
    "coolreader",
    "LuaJIT",
    "libcurl",
    "SQLite",
    "minisign",
    "NotoSansCJK",
}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("archive", type=Path)
    parser.add_argument("--checksum", type=Path)
    args = parser.parse_args()
    errors = []
    with zipfile.ZipFile(args.archive) as archive:
        names = [item.filename.rstrip("/") for item in archive.infolist()]
        missing = sorted(REQUIRED - set(names))
        if missing:
            errors.append("missing: " + ", ".join(missing))
        forbidden = [
            name for name in names
            if name.endswith(("wereader.db", "secrets.lua"))
            or "/cache/" in name or "/crash/" in name or "/logs/" in name
        ]
        if forbidden:
            errors.append("mutable/private files included: " + ", ".join(forbidden))
        if len(names) != len(set(names)):
            errors.append("duplicate archive paths")
        try:
            version = json.loads(archive.read("wereader/version.json"))
            for field in ("version", "abi", "minimum_firmware", "source_revision"):
                if not version.get(field):
                    errors.append(f"version.json missing {field}")
            sbom = json.loads(archive.read("wereader/share/sbom.spdx.json"))
            if sbom.get("spdxVersion") != "SPDX-2.3":
                errors.append("invalid SPDX version")
            component_names = {
                package.get("name") for package in sbom.get("packages", [])
            }
            missing_components = sorted(REQUIRED_COMPONENTS - component_names)
            if missing_components:
                errors.append(
                    "SBOM missing runtime components: "
                    + ", ".join(missing_components)
                )
            license_files = [
                name for name in names
                if name.startswith("wereader/share/licenses/")
                and name != "wereader/share/licenses"
            ]
            if len(license_files) < 5:
                errors.append("runtime license bundle is incomplete")
        except (KeyError, json.JSONDecodeError) as error:
            errors.append(f"metadata parse failed: {error}")
    if args.checksum:
        expected = args.checksum.read_text(encoding="utf-8").split()[0]
        actual = hashlib.sha256(args.archive.read_bytes()).hexdigest()
        if expected != actual:
            errors.append("checksum mismatch")
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print("release audit: passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
