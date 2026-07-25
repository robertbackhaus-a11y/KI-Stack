#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import sys
import tempfile
import zipfile
from dataclasses import dataclass, asdict
from pathlib import Path, PurePosixPath
from typing import Any

try:
    import yaml  # type: ignore
except Exception:
    yaml = None

DEVICE_NAMES = {"CON", "PRN", "AUX", "NUL"}
DEVICE_NAMES.update({f"COM{i}" for i in range(1, 10)})
DEVICE_NAMES.update({f"LPT{i}" for i in range(1, 10)})

BAD_PATTERNS = {
    "REG-004-HASHTABLE-KEYS": re.compile(r"\$expected\.Key\b", re.IGNORECASE),
    "REG-005-DOUBLE-BACKSLASH-PREFIX": re.compile(r"\.TrimEnd\(\s*['\"]\\\\['\"]\s*\)\s*\+\s*['\"]\\\\['\"]", re.IGNORECASE),
    "REG-006-BROAD-GIT-TEXT-SCAN": re.compile(r"-notmatch\s+['\"][^'\"]*\\bgit\\b[^'\"]*['\"]", re.IGNORECASE),
    "REG-001-OLD-CUTOVER-ASSET-NAME": re.compile(r"KI-Stack-Cutover-Execute-v1\.6\.3\.zip", re.IGNORECASE),
}

TEXT_EXTENSIONS = {
    ".ps1", ".psm1", ".psd1", ".cmd", ".bat", ".py", ".json", ".yml", ".yaml",
    ".md", ".txt", ".ini", ".cfg", ".toml", ".xml", ".sh"
}

@dataclass
class Check:
    name: str
    passed: bool
    detail: str = ""
    severity: str = "error"


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def safe_zip_path(name: str) -> tuple[bool, str]:
    if not name:
        return False, "empty name"
    if "\\" in name:
        return False, "backslash separator"
    if name.startswith("/") or name.startswith("//"):
        return False, "absolute/UNC path"
    if re.match(r"^[A-Za-z]:", name):
        return False, "drive-qualified path"
    if ":" in name:
        return False, "alternate data stream or colon"
    p = PurePosixPath(name)
    if any(part in ("", ".", "..") for part in p.parts):
        return False, "empty, dot or traversal component"
    for part in p.parts:
        stem = part.rstrip(" .").split(".", 1)[0].upper()
        if stem in DEVICE_NAMES:
            return False, f"reserved Windows device name: {part}"
        if part.endswith(" ") or part.endswith("."):
            return False, f"trailing space/dot: {part}"
    if len(name) > 240:
        return False, "path longer than 240 characters"
    return True, ""


def zip_entry_is_symlink(info: zipfile.ZipInfo) -> bool:
    mode = (info.external_attr >> 16) & 0xFFFF
    return (mode & 0o170000) == 0o120000


def parse_sha_manifest(path: Path) -> tuple[dict[str, str], list[str]]:
    entries: dict[str, str] = {}
    errors: list[str] = []
    for idx, raw in enumerate(path.read_text(encoding="utf-8-sig").splitlines(), start=1):
        line = raw.strip()
        if not line:
            continue
        m = re.match(r"^([0-9a-fA-F]{64})\s+[* ]?(.+)$", line)
        if not m:
            errors.append(f"line {idx}: invalid format")
            continue
        digest = m.group(1).lower()
        rel = m.group(2).replace("\\", "/").lstrip("./")
        ok, reason = safe_zip_path(rel)
        if not ok:
            errors.append(f"line {idx}: unsafe path {rel}: {reason}")
            continue
        key = rel.casefold()
        if key in (k.casefold() for k in entries):
            errors.append(f"line {idx}: duplicate manifest path {rel}")
            continue
        entries[rel] = digest
    return entries, errors


def load_sidecar(zip_path: Path) -> tuple[str | None, str]:
    candidates = [Path(str(zip_path) + ".sha256"), zip_path.with_suffix(zip_path.suffix + ".sha256")]
    seen: set[Path] = set()
    for c in candidates:
        if c in seen:
            continue
        seen.add(c)
        if c.exists():
            text = c.read_text(encoding="utf-8-sig").strip()
            m = re.match(r"^([0-9a-fA-F]{64})\s+[* ]?(.+)$", text)
            if not m:
                return None, f"invalid sidecar format: {c.name}"
            if Path(m.group(2)).name != zip_path.name:
                return None, f"sidecar filename mismatch: {m.group(2)}"
            return m.group(1).lower(), c.name
    return None, "sidecar not found"


def read_text_safely(path: Path) -> str | None:
    try:
        return path.read_text(encoding="utf-8-sig")
    except UnicodeDecodeError:
        try:
            return path.read_text(encoding="cp1252")
        except Exception:
            return None


def validate_zip_archive(path: Path, depth: int, max_depth: int, checks: list[Check], prefix: str) -> dict[str, Any]:
    result: dict[str, Any] = {"path": str(path), "sha256": sha256_file(path), "entries": 0}
    names: list[str] = []
    lower_names: set[str] = set()
    unsafe: list[str] = []
    duplicates: list[str] = []
    case_dupes: list[str] = []
    symlinks: list[str] = []
    crc_errors: list[str] = []
    try:
        with zipfile.ZipFile(path, "r") as zf:
            infos = zf.infolist()
            result["entries"] = len(infos)
            for info in infos:
                name = info.filename
                ok, reason = safe_zip_path(name.rstrip("/")) if name.endswith("/") else safe_zip_path(name)
                if not ok:
                    unsafe.append(f"{name}: {reason}")
                if name in names:
                    duplicates.append(name)
                folded = name.casefold()
                if folded in lower_names and name not in names:
                    case_dupes.append(name)
                names.append(name)
                lower_names.add(folded)
                if zip_entry_is_symlink(info):
                    symlinks.append(name)
                if not info.is_dir():
                    try:
                        with zf.open(info, "r") as src:
                            while src.read(1024 * 1024):
                                pass
                    except Exception as exc:
                        crc_errors.append(f"{name}: {exc}")
            bad = zf.testzip()
            if bad and not any(x.startswith(bad + ":") for x in crc_errors):
                crc_errors.append(bad)
    except Exception as exc:
        checks.append(Check(f"{prefix} ZIP open/read", False, str(exc)))
        return result

    checks.append(Check(f"{prefix} safe ZIP paths", not unsafe, " | ".join(unsafe[:10])))
    checks.append(Check(f"{prefix} no duplicate ZIP paths", not duplicates and not case_dupes,
                        "exact=" + ",".join(duplicates[:5]) + "; case=" + ",".join(case_dupes[:5])))
    checks.append(Check(f"{prefix} no ZIP symlinks", not symlinks, ", ".join(symlinks[:10])))
    checks.append(Check(f"{prefix} complete byte-read and CRC", not crc_errors, " | ".join(crc_errors[:10])))
    result.update({"unsafe": unsafe, "duplicates": duplicates, "caseDuplicates": case_dupes,
                   "symlinks": symlinks, "crcErrors": crc_errors})
    return result


def find_single_root(names: list[str]) -> str | None:
    roots = {n.split("/", 1)[0] for n in names if n and not n.startswith("__MACOSX/")}
    return next(iter(roots)) if len(roots) == 1 else None


def validate_extracted_tree(root: Path, release_mode: bool, checks: list[Check], require_manifest: bool = True, strict_policy: bool = True) -> dict[str, Any]:
    files = sorted([p for p in root.rglob("*") if p.is_file()])
    rels = [p.relative_to(root).as_posix() for p in files]
    details: dict[str, Any] = {"fileCount": len(files), "files": rels}

    contract_candidates = [root / "Validation" / "VALIDATION-CONTRACT.json", root / "Contract" / "VALIDATION-CONTRACT.json"]
    contract_path = next((p for p in contract_candidates if p.exists()), None)
    contract: dict[str, Any] | None = None
    if contract_path:
        try:
            contract = json.loads(contract_path.read_text(encoding="utf-8-sig"))
            required_fields = ["schemaVersion", "packageName", "packageVersion", "packageType", "selfTestEntryPoint", "regressionCoverageFile"]
            missing = [f for f in required_fields if f not in contract]
            checks.append(Check("Validation contract parses and has required fields", not missing, ", ".join(missing)))
        except Exception as exc:
            checks.append(Check("Validation contract parses and has required fields", False, str(exc)))
    else:
        checks.append(Check("Validation contract present", not release_mode, "missing Validation/VALIDATION-CONTRACT.json"))
    details["contract"] = contract
    effective_strict = strict_policy or contract is not None
    details["policyMode"] = "strict" if effective_strict else "legacy-nested"

    manifests = [p for p in files if p.name.upper() == "SHA256SUMS.TXT"]
    if len(manifests) > 1 or (require_manifest and len(manifests) != 1):
        checks.append(Check("Exactly one SHA256SUMS.txt", False, f"found {len(manifests)}"))
    elif len(manifests) == 0:
        checks.append(Check("Nested SHA256SUMS.txt", True, "not present and not required", severity="warning"))
    else:
        manifest = manifests[0]
        expected, errors = parse_sha_manifest(manifest)
        checks.append(Check("SHA256SUMS format", not errors, " | ".join(errors[:10])))
        manifest_rel = manifest.relative_to(root).as_posix()
        actual_set = {r for r in rels if r != manifest_rel}
        expected_set = set(expected)
        missing = sorted(expected_set - actual_set)
        extra = sorted(actual_set - expected_set)
        if effective_strict:
            checks.append(Check("Exact manifest file set", not missing and not extra,
                                f"missing={missing[:10]}; extra={extra[:10]}"))
        else:
            checks.append(Check("Nested legacy manifest listed files present", not missing,
                                f"missing={missing[:10]}"))
            checks.append(Check("Nested legacy untracked files", True,
                                f"extra={extra[:10]}", severity="warning"))
        drift: list[str] = []
        for rel, digest in expected.items():
            p = root / Path(rel)
            if p.exists() and sha256_file(p) != digest:
                drift.append(rel)
        checks.append(Check("Manifest SHA256 values", not drift, ", ".join(drift[:10])))
        details["manifest"] = {"path": manifest_rel, "trackedFiles": len(expected), "missing": missing, "extra": extra, "drift": drift}

    json_errors: list[str] = []
    yaml_errors: list[str] = []
    python_errors: list[str] = []
    cmd_errors: list[str] = []
    pattern_hits: list[str] = []

    for p in files:
        rel = p.relative_to(root).as_posix()
        suffix = p.suffix.lower()
        if suffix == ".json":
            try:
                json.loads(p.read_text(encoding="utf-8-sig"))
            except Exception as exc:
                json_errors.append(f"{rel}: {exc}")
        elif suffix in (".yml", ".yaml"):
            if yaml is None:
                yaml_errors.append(f"{rel}: PyYAML unavailable")
            else:
                try:
                    yaml.safe_load(p.read_text(encoding="utf-8-sig"))
                except Exception as exc:
                    yaml_errors.append(f"{rel}: {exc}")
        elif suffix == ".py":
            try:
                source = p.read_text(encoding='utf-8-sig')
                compile(source, str(p), 'exec')
            except Exception as exc:
                python_errors.append(f"{rel}: {exc}")
        elif suffix in (".cmd", ".bat"):
            raw = p.read_bytes()
            if raw.startswith(b"\xef\xbb\xbf") or raw.startswith(b"\xff\xfe") or raw.startswith(b"\xfe\xff"):
                cmd_errors.append(f"{rel}: BOM present")
            if b"\n" in raw and b"\r\n" not in raw:
                cmd_errors.append(f"{rel}: LF-only line endings")
            if b"\n" in raw and raw.replace(b"\r\n", b"").find(b"\n") >= 0:
                cmd_errors.append(f"{rel}: mixed/LF line endings")

        if suffix in {'.ps1', '.psm1', '.psd1', '.cmd', '.bat'} and p.stat().st_size <= 2 * 1024 * 1024:
            text = read_text_safely(p)
            if text is not None:
                for reg_id, rx in BAD_PATTERNS.items():
                    if rx.search(text):
                        pattern_hits.append(f"{reg_id}: {rel}")
                if "KI-Stack-Cutover-Execute-v1.6.3-core.zip" in text and "dac28224c7456d19b3046582059abed37ad1ae3a155f198007c6734fc8a6e00a" in text:
                    pattern_hits.append(f"REG-002-HASH-CONTRACT-MIX: {rel}")

    if effective_strict:
        checks.append(Check("JSON syntax", not json_errors, " | ".join(json_errors[:10])))
        checks.append(Check("YAML syntax", not yaml_errors, " | ".join(yaml_errors[:10])))
        checks.append(Check("Python syntax compile", not python_errors, " | ".join(python_errors[:10])))
        checks.append(Check("CMD/BAT encoding and CRLF", not cmd_errors, " | ".join(cmd_errors[:10])))
        checks.append(Check("Known static regression patterns absent", not pattern_hits, " | ".join(pattern_hits[:10])))
    else:
        checks.append(Check("Nested legacy JSON syntax observations", True, " | ".join(json_errors[:10]), severity="warning"))
        checks.append(Check("Nested legacy YAML syntax observations", True, " | ".join(yaml_errors[:10]), severity="warning"))
        checks.append(Check("Nested legacy Python syntax observations", True, " | ".join(python_errors[:10]), severity="warning"))
        checks.append(Check("Nested legacy CMD/BAT deviations", True, " | ".join(cmd_errors[:10]), severity="warning"))
        checks.append(Check("Nested legacy static regression observations", True, " | ".join(pattern_hits[:10]), severity="warning"))

    if contract:
        required_files = contract.get("requiredFiles", [])
        missing_required = [x for x in required_files if not (root / Path(x)).is_file()]
        checks.append(Check("Contract required files present", not missing_required, ", ".join(missing_required[:10])))
        selftest = contract.get("selfTestEntryPoint", "")
        checks.append(Check("Contract self-test entry point exists", bool(selftest) and (root / Path(selftest)).is_file(), selftest))
        if contract.get("allowRepositoryOperations") is not False:
            checks.append(Check("Repository operations explicitly forbidden", False, "allowRepositoryOperations must be false"))
        else:
            checks.append(Check("Repository operations explicitly forbidden", True))
        required_regs = contract.get("requiredRegressionIds", [])
        checks.append(Check("Regression contract is non-empty", bool(required_regs), "requiredRegressionIds is empty"))
        coverage_rel = contract.get("regressionCoverageFile", "")
        coverage_path = root / Path(coverage_rel) if coverage_rel else None
        coverage_errors: list[str] = []
        if not coverage_path or not coverage_path.is_file():
            coverage_errors.append(f"coverage file missing: {coverage_rel}")
        else:
            try:
                coverage_data = json.loads(coverage_path.read_text(encoding="utf-8-sig"))
                entries = coverage_data.get("coverage", [])
                by_id = {str(e.get("id", "")): e for e in entries}
                for reg_id in required_regs:
                    entry = by_id.get(str(reg_id))
                    if not entry:
                        coverage_errors.append(f"missing coverage: {reg_id}")
                        continue
                    status = entry.get("status")
                    if status == "covered":
                        if not str(entry.get("method", "")).strip():
                            coverage_errors.append(f"covered without method: {reg_id}")
                    elif status == "notApplicable":
                        if not str(entry.get("justification", "")).strip():
                            coverage_errors.append(f"notApplicable without justification: {reg_id}")
                    else:
                        coverage_errors.append(f"invalid coverage status {status}: {reg_id}")
            except Exception as exc:
                coverage_errors.append(f"coverage parse error: {exc}")
        checks.append(Check("Regression coverage resolved", not coverage_errors, " | ".join(coverage_errors[:20])))

    details.update({"jsonErrors": json_errors, "yamlErrors": yaml_errors, "pythonErrors": python_errors,
                    "cmdErrors": cmd_errors, "patternHits": pattern_hits})
    return details



def inspect_nested_archive(path: Path, depth: int, max_depth: int, checks: list[Check], label: str) -> dict[str, Any]:
    report = validate_zip_archive(path, depth, max_depth, checks, label)
    report["depth"] = depth
    if depth >= max_depth:
        report["nestedArchives"] = []
        return report
    nested_reports: list[dict[str, Any]] = []
    with tempfile.TemporaryDirectory(prefix="kistack-nested-") as td:
        td_path = Path(td)
        try:
            with zipfile.ZipFile(path, "r") as zf:
                names = [i.filename for i in zf.infolist()]
                root_name = find_single_root(names)
                roots = sorted({n.split('/', 1)[0] for n in names if n})
                checks.append(Check(
                    f"{label} package root layout",
                    True,
                    f"single-root={root_name}" if root_name else f"legacy-rootless={roots}",
                    severity="warning" if root_name is None else "error",
                ))
                for info in zf.infolist():
                    if info.is_dir():
                        continue
                    ok, reason = safe_zip_path(info.filename)
                    if not ok:
                        raise ValueError(f"unsafe path {info.filename}: {reason}")
                    target = td_path / Path(*PurePosixPath(info.filename).parts)
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with zf.open(info) as src, target.open("wb") as dst:
                        shutil.copyfileobj(src, dst)
                package_root = td_path / root_name if root_name else td_path
                report["extractedTree"] = validate_extracted_tree(
                    package_root, release_mode=False, checks=checks, require_manifest=False, strict_policy=False
                )
                for nested in sorted(package_root.rglob("*.zip")):
                    rel = nested.relative_to(package_root).as_posix()
                    nested_reports.append(inspect_nested_archive(
                        nested, depth + 1, max_depth, checks, f"Nested {label}/{rel}"
                    ))
        except Exception as exc:
            checks.append(Check(f"{label} safe nested extraction", False, str(exc)))
    report["nestedArchives"] = nested_reports
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description="Independent KI-Stack package validator")
    parser.add_argument("--package", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--release-mode", action="store_true")
    parser.add_argument("--max-nested-depth", type=int, default=3)
    args = parser.parse_args()

    package = Path(args.package).resolve()
    output = Path(args.output).resolve()
    checks: list[Check] = []
    report: dict[str, Any] = {
        "schemaVersion": "1.0",
        "validator": "validate_package.py",
        "package": str(package),
        "releaseMode": args.release_mode,
        "checks": [],
    }

    if not package.is_file() or package.suffix.lower() != ".zip":
        checks.append(Check("Input is an existing ZIP", False, str(package)))
    else:
        digest = sha256_file(package)
        report["sha256"] = digest
        sidecar_digest, sidecar_detail = load_sidecar(package)
        checks.append(Check("Outer SHA256 sidecar present and valid", sidecar_digest is not None, sidecar_detail))
        if sidecar_digest:
            checks.append(Check("Outer SHA256 matches sidecar", digest == sidecar_digest,
                                f"actual={digest}; expected={sidecar_digest}"))
        outer = validate_zip_archive(package, 0, args.max_nested_depth, checks, "Outer")
        report["outerArchive"] = outer

        with tempfile.TemporaryDirectory(prefix="kistack-gate-") as td:
            td_path = Path(td)
            try:
                with zipfile.ZipFile(package, "r") as zf:
                    names = [i.filename for i in zf.infolist()]
                    root_name = find_single_root(names)
                    checks.append(Check("Single package root directory", root_name is not None, str(sorted({n.split('/',1)[0] for n in names}))))
                    if root_name:
                        for info in zf.infolist():
                            if info.is_dir():
                                continue
                            ok, reason = safe_zip_path(info.filename)
                            if not ok:
                                raise ValueError(f"unsafe path {info.filename}: {reason}")
                            target = td_path / Path(*PurePosixPath(info.filename).parts)
                            target.parent.mkdir(parents=True, exist_ok=True)
                            with zf.open(info) as src, target.open("wb") as dst:
                                shutil.copyfileobj(src, dst)
                        package_root = td_path / root_name
                        report["extractedTree"] = validate_extracted_tree(package_root, args.release_mode, checks, require_manifest=True, strict_policy=True)
                        nested_reports: list[dict[str, Any]] = []
                        if args.max_nested_depth > 0:
                            for nested in sorted(package_root.rglob("*.zip")):
                                rel = nested.relative_to(package_root).as_posix()
                                nested_reports.append(inspect_nested_archive(
                                    nested, 1, args.max_nested_depth, checks, f"Nested {rel}"
                                ))
                        report["nestedArchives"] = nested_reports
            except Exception as exc:
                checks.append(Check("Safe extraction", False, str(exc)))

    report["checks"] = [asdict(c) for c in checks]
    report["failed"] = [asdict(c) for c in checks if not c.passed and c.severity == "error"]
    report["passed"] = len(report["failed"]) == 0
    report["status"] = "STATIC_VALIDATION_PASSED" if report["passed"] else "REJECTED"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps({"passed": report["passed"], "status": report["status"], "output": str(output)}, ensure_ascii=False))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
