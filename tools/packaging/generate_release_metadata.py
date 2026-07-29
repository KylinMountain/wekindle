#!/usr/bin/env python3
"""Generate deterministic SPDX SBOM and source/license notices."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path


def load_dependencies(path: Path) -> list[dict[str, str]]:
    dependencies = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line or line.startswith("#"):
            continue
        fields = line.split("|")
        if len(fields) != 5:
            raise ValueError(f"invalid dependency lock line: {line}")
        name, repository, commit, license_id, checksum = fields
        if not re.fullmatch(r"[0-9a-f]{64}", checksum):
            raise ValueError(f"invalid dependency checksum: {name}")
        dependencies.append(
            {
                "name": name,
                "repository": repository,
                "commit": commit,
                "license": license_id,
                "sha256": checksum,
            }
        )
    return dependencies


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--lock", type=Path, required=True, action="append")
    parser.add_argument("--require-component", action="append", default=[])
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--abi", required=True)
    args = parser.parse_args()
    dependencies = []
    seen_names = set()
    for lock in args.lock:
        for dependency in load_dependencies(lock):
            if dependency["name"] in seen_names:
                raise ValueError(
                    f"duplicate dependency in release locks: {dependency['name']}"
                )
            seen_names.add(dependency["name"])
            dependencies.append(dependency)
    missing_components = sorted(set(args.require_component) - seen_names)
    if missing_components:
        raise ValueError(
            "runtime dependency lock missing: " + ", ".join(missing_components)
        )
    args.output_dir.mkdir(parents=True, exist_ok=True)
    seed = json.dumps(
        [args.version, args.abi, dependencies],
        ensure_ascii=True,
        sort_keys=True,
    ).encode()
    namespace_hash = hashlib.sha256(seed).hexdigest()
    document = {
        "spdxVersion": "SPDX-2.3",
        "dataLicense": "CC0-1.0",
        "SPDXID": "SPDXRef-DOCUMENT",
        "name": f"wereader-{args.version}-{args.abi}",
        "documentNamespace": f"https://wereader.invalid/spdx/{namespace_hash}",
        "creationInfo": {
            "created": "1980-01-01T00:00:00Z",
            "creators": ["Tool: wereader-generate-release-metadata"],
        },
        "packages": [
            {
                "name": "wereader",
                "SPDXID": "SPDXRef-Package-wereader",
                "versionInfo": args.version,
                "downloadLocation": "NOASSERTION",
                "filesAnalyzed": False,
                "licenseConcluded": "AGPL-3.0-only",
                "licenseDeclared": "AGPL-3.0-only",
                "copyrightText": "NOASSERTION",
            }
        ],
        "relationships": [],
    }
    for index, dependency in enumerate(dependencies, 1):
        spdx_id = f"SPDXRef-Package-dependency-{index}"
        package = {
            "name": dependency["name"],
            "SPDXID": spdx_id,
            "versionInfo": dependency["commit"],
            "downloadLocation": dependency["repository"],
            "filesAnalyzed": False,
            "licenseConcluded": dependency["license"],
            "licenseDeclared": dependency["license"],
            "copyrightText": "NOASSERTION",
            "externalRefs": [
                {
                    "referenceCategory": "PACKAGE-MANAGER",
                    "referenceType": "purl",
                    "referenceLocator": (
                        f"pkg:github/{dependency['repository'].split('github.com/')[-1].removesuffix('.git')}"
                        f"@{dependency['commit']}"
                    ),
                }
            ],
        }
        if dependency["sha256"]:
            package["checksums"] = [
                {"algorithm": "SHA256", "checksumValue": dependency["sha256"]}
            ]
        document["packages"].append(package)
        document["relationships"].append(
            {
                "spdxElementId": "SPDXRef-Package-wereader",
                "relationshipType": "DEPENDS_ON",
                "relatedSpdxElement": spdx_id,
            }
        )
    (args.output_dir / "sbom.spdx.json").write_text(
        json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    rows = [
        "# Third-party licenses",
        "",
        "| Component | Commit | License | Source |",
        "|---|---|---|---|",
    ]
    for dependency in dependencies:
        rows.append(
            f"| {dependency['name']} | `{dependency['commit']}` | "
            f"{dependency['license']} | {dependency['repository']} |"
        )
    (args.output_dir / "THIRD_PARTY_LICENSES.md").write_text(
        "\n".join(rows) + "\n", encoding="utf-8"
    )
    source_lines = [
        "# Corresponding source",
        "",
        "This build is accompanied by exact source coordinates:",
        "",
    ]
    source_lines.extend(
        f"- {item['name']}: {item['repository']} at `{item['commit']}`"
        for item in dependencies
    )
    source_lines.extend(
        [
            "",
            "The complete Wereader source for this version must be distributed "
            "with the release or offered from the release page, as required by "
            "the applicable GPL/AGPL licenses.",
            "",
        ]
    )
    (args.output_dir / "SOURCE_OFFER.md").write_text(
        "\n".join(source_lines), encoding="utf-8"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
