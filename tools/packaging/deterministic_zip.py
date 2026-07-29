#!/usr/bin/env python3
"""Create a byte-reproducible ZIP from one staged directory."""

from __future__ import annotations

import argparse
import os
import stat
import time
import zipfile
from pathlib import Path


def zip_time(epoch: int) -> tuple[int, int, int, int, int, int]:
    # ZIP cannot represent dates before 1980.
    value = time.gmtime(max(epoch, 315532800))
    return value[:6]


def add_entry(
    archive: zipfile.ZipFile, source: Path, relative: str, timestamp: tuple[int, ...]
) -> None:
    info = zipfile.ZipInfo(relative, timestamp)
    info.create_system = 3
    mode = source.lstat().st_mode
    if source.is_symlink():
        info.external_attr = (stat.S_IFLNK | 0o777) << 16
        archive.writestr(info, os.readlink(source), compress_type=zipfile.ZIP_STORED)
    elif source.is_dir():
        info.filename = relative.rstrip("/") + "/"
        info.external_attr = (stat.S_IFDIR | 0o755) << 16
        archive.writestr(info, b"", compress_type=zipfile.ZIP_STORED)
    else:
        permissions = 0o755 if mode & stat.S_IXUSR else 0o644
        info.external_attr = (stat.S_IFREG | permissions) << 16
        with source.open("rb") as handle:
            archive.writestr(
                info,
                handle.read(),
                compress_type=zipfile.ZIP_DEFLATED,
                compresslevel=9,
            )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--epoch", type=int, default=0)
    args = parser.parse_args()
    root = args.source.resolve()
    if not root.is_dir() or root == Path("/"):
        parser.error("source must be a non-root directory")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    timestamp = zip_time(args.epoch)
    paths = [root]
    paths.extend(sorted(root.rglob("*"), key=lambda item: item.relative_to(root).as_posix()))
    with zipfile.ZipFile(args.output, "w", allowZip64=True) as archive:
        for path in paths:
            relative = root.name if path == root else (
                root.name + "/" + path.relative_to(root).as_posix()
            )
            add_entry(archive, path, relative, timestamp)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
