#!/usr/bin/env python3
"""Small repository/release secret guard with intentionally low false positives."""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
import zipfile
from pathlib import Path

PATTERNS = [
    ("private key", re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----")),
    (
        "literal bearer token",
        re.compile(rb"(?i)authorization\s*:\s*bearer\s+[A-Za-z0-9._~+/-]{20,}"),
    ),
    (
        "WeRead cookie",
        re.compile(
            rb"""(?ix)
            (?:
              (?:^|[;\s"']) (?:wr_skey|wr_gid|wr_vid|wr_rt|wr_ticket|wr_wrpa|thirdwx)
              = (?!(?:legacy|test|fake|example|selftest)[-_])
                [A-Za-z0-9%._~-]{12,}
              |
              (?:wr_skey|wr_gid|wr_vid|wr_rt|wr_ticket|wr_wrpa|thirdwx)\s*=\s*
              ["'](?!(?:legacy|test|fake|example|selftest)[-_])
              [A-Za-z0-9%._~-]{12,}["']
            )
            """
        ),
    ),
    (
        "literal API key",
        re.compile(rb"""(?ix)api[_-]?key\s*[:=]\s*["'][A-Za-z0-9._~-]{20,}["']"""),
    ),
    (
        "literal x-wrpa credential",
        re.compile(
            rb"""(?ix)x-wrpa-[0-9]+\s*[:=]\s*["']?[A-Za-z0-9%._~-]{12,}"""
        ),
    ),
]
FORBIDDEN_NAMES = {"secrets.lua", "wereader.db", "cookies.txt", ".env"}


def findings(name: str, data: bytes) -> list[str]:
    result = []
    if Path(name).name in FORBIDDEN_NAMES:
        result.append(f"{name}: forbidden credential/database filename")
    if b"\0" in data[:4096]:
        return result
    for label, pattern in PATTERNS:
        if pattern.search(data):
            result.append(f"{name}: {label}")
    return result


def tracked_files(root: Path) -> list[Path]:
    output = subprocess.check_output(
        ["git", "-C", str(root), "ls-files", "-z"]
    ).split(b"\0")
    return [root / item.decode() for item in output if item]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--archive", type=Path)
    args = parser.parse_args()
    violations: list[str] = []
    root = args.root.resolve()
    if args.archive:
        with zipfile.ZipFile(args.archive) as archive:
            for info in archive.infolist():
                if info.is_dir():
                    continue
                violations.extend(findings(info.filename, archive.read(info)))
    else:
        for path in tracked_files(root):
            if path.is_file():
                violations.extend(findings(str(path.relative_to(root)), path.read_bytes()))
    if violations:
        print("\n".join(violations), file=sys.stderr)
        return 1
    print("secret scan: clean")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
