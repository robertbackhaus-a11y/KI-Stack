#!/usr/bin/env python3
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import shutil
import sys


class RestoreError(RuntimeError):
    pass


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--target", type=Path, default=Path(r"C:\KI-Stack"))
    parser.add_argument(
        "--backup-root",
        type=Path,
        default=Path(r"C:\KI-Stack-Recovery-Backup"),
    )
    args = parser.parse_args()

    script_root = Path(__file__).resolve().parent
    package_root = script_root.parent
    overlay_root = package_root / "02-Operational-Overlay"
    manifest = json.loads(
        (overlay_root / "CONTENT-MANIFEST.json").read_text(encoding="utf-8-sig")
    )
    target = args.target.resolve()
    target.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    backup = args.backup_root / timestamp
    changed = 0
    unchanged = 0

    try:
        for record in manifest["files"]:
            relative = Path(str(record["path"]))
            source = overlay_root / "Content" / relative
            destination = target / relative
            expected_hash = str(record["sha256"]).lower()

            if not source.is_file() or sha256_file(source) != expected_hash:
                raise RestoreError(f"Overlay-Quelle ungültig: {relative.as_posix()}")

            if destination.is_file() and sha256_file(destination) == expected_hash:
                unchanged += 1
                continue

            if destination.exists():
                backup_path = backup / relative
                backup_path.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(destination, backup_path)

            destination.parent.mkdir(parents=True, exist_ok=True)
            partial = destination.with_name(destination.name + ".recovery-partial")
            shutil.copy2(source, partial)
            if sha256_file(partial) != expected_hash:
                partial.unlink(missing_ok=True)
                raise RestoreError(f"Kopierprüfung fehlgeschlagen: {relative.as_posix()}")
            partial.replace(destination)
            changed += 1

        report = {
            "passed": True,
            "target": str(target),
            "changed": changed,
            "unchanged": unchanged,
            "backup": str(backup) if backup.exists() else None,
        }
        report_path = target / "KI-Stack-Recovery-Apply-Report.json"
        report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(report, indent=2))
        return 0
    except Exception as exc:
        print(f"Recovery-Overlay konnte nicht angewendet werden: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
