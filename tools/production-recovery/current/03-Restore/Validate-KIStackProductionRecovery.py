#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import sys
import zipfile


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    errors = []

    sums = root / "SHA256SUMS.txt"
    if not sums.is_file():
        errors.append("SHA256SUMS.txt fehlt")
    else:
        expected = {}
        for line in sums.read_text(encoding="utf-8").splitlines():
            if not line.strip():
                continue
            try:
                digest, relative = line.split(" *", 1)
                expected[relative] = digest.lower()
            except ValueError:
                errors.append(f"Ungültige SHA256SUMS-Zeile: {line}")

        actual_paths = {
            p.relative_to(root).as_posix()
            for p in root.rglob("*")
            if p.is_file() and p.name != "SHA256SUMS.txt"
        }
        if actual_paths != set(expected):
            errors.append("Paketdateisatz weicht von SHA256SUMS ab")
        for relative, expected_hash in expected.items():
            path = root / Path(relative)
            if not path.is_file():
                errors.append(f"Datei fehlt: {relative}")
            elif sha256_file(path) != expected_hash:
                errors.append(f"SHA256 falsch: {relative}")

    release_manifest_path = root / "RELEASE-MANIFEST.json"
    if not release_manifest_path.is_file():
        errors.append("RELEASE-MANIFEST.json fehlt")
    else:
        manifest = json.loads(release_manifest_path.read_text(encoding="utf-8-sig"))
        runtime = root / "01-Runtime" / manifest["runtime"]["name"]
        if not runtime.is_file():
            errors.append("Runtime-ZIP fehlt")
        elif sha256_file(runtime) != manifest["runtime"]["actualSha256"]:
            errors.append("Runtime-SHA256 falsch")
        else:
            try:
                with zipfile.ZipFile(runtime, "r") as archive:
                    corrupt = archive.testzip()
                    if corrupt is not None:
                        errors.append(f"Runtime-ZIP beschädigt: {corrupt}")
            except zipfile.BadZipFile:
                errors.append("Runtime ist kein gültiges ZIP")

    result = {"passed": not errors, "errors": errors}
    print(json.dumps(result, indent=2))
    return 0 if not errors else 1


if __name__ == "__main__":
    raise SystemExit(main())
