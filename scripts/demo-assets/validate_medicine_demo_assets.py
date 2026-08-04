#!/usr/bin/env python3
"""Validate the SlowWalk A5 synthetic medicine asset bundle offline."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import struct
import subprocess
import sys


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
ASSET_ROOT = REPOSITORY_ROOT / "shared/demo-assets/medicine"
MANIFEST_PATH = ASSET_ROOT / "manifest.json"
GENERATOR_PATH = REPOSITORY_ROOT / "scripts/demo-assets/generate_medicine_demo_assets.py"
DISCLAIMER = "DEMO DATA — NOT FOR CLINICAL USE"
CHINESE_DISCLAIMER = "演示数据，不用于临床用途"
MAX_FILE_BYTES = 1_000_000
EXPECTED_IDS = {
    "acetaminophen-angle-v1",
    "acetaminophen-clean-v1",
    "acetaminophen-lowlight-v1",
    "cold-relief-ambiguous-v1",
}
REQUIRED_FIELDS = {
    "id",
    "file",
    "sha256",
    "synthetic",
    "approvedForRecording",
    "expectedVisibleTexts",
    "expectedCanonicalMedicineID",
    "purpose",
    "expectedReadable",
    "expectedAmbiguous",
    "generatedBy",
    "generatorVersion",
    "width",
    "height",
    "mimeType",
}


def read_png_header(data: bytes) -> tuple[int, int, int, int] | None:
    if len(data) < 33 or data[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    if data[8:12] != b"\x00\x00\x00\r" or data[12:16] != b"IHDR":
        return None
    width, height, bit_depth, color_type, compression, filtering, interlace = struct.unpack(">IIBBBBB", data[16:29])
    if compression != 0 or filtering != 0 or interlace != 0:
        return None
    return width, height, bit_depth, color_type


def safe_asset_path(relative: object) -> Path | None:
    if not isinstance(relative, str) or not relative or "\\" in relative:
        return None
    posix_path = PurePosixPath(relative)
    if posix_path.is_absolute() or relative != posix_path.as_posix() or ".." in posix_path.parts:
        return None
    resolved = (ASSET_ROOT / Path(*posix_path.parts)).resolve()
    try:
        resolved.relative_to(ASSET_ROOT.resolve())
    except ValueError:
        return None
    return resolved


def validate_asset(asset: object, errors: list[str]) -> tuple[str | None, bool]:
    if not isinstance(asset, dict):
        errors.append("every assets entry must be an object")
        return None, False
    asset_id = asset.get("id")
    label = asset_id if isinstance(asset_id, str) and asset_id else "<invalid-id>"
    missing = sorted(REQUIRED_FIELDS - asset.keys())
    if missing:
        errors.append(f"{label}: missing fields: {', '.join(missing)}")
    if not isinstance(asset_id, str) or not asset_id:
        errors.append(f"{label}: id must be a non-empty string")
        asset_id = None
    relative = asset.get("file")
    path = safe_asset_path(relative)
    if path is None:
        errors.append(f"{label}: file must be a normalized relative path inside the asset root")
    elif not path.is_file():
        errors.append(f"{label}: file does not exist: {relative}")
    else:
        data = path.read_bytes()
        digest = asset.get("sha256")
        if not isinstance(digest, str) or re.fullmatch(r"[0-9a-f]{64}", digest) is None:
            errors.append(f"{label}: sha256 must be 64 lowercase hexadecimal characters")
        elif hashlib.sha256(data).hexdigest() != digest:
            errors.append(f"{label}: SHA-256 mismatch")
        header = read_png_header(data)
        if header is None:
            errors.append(f"{label}: invalid PNG signature or IHDR")
        else:
            width, height, bit_depth, color_type = header
            if asset.get("width") != width or asset.get("height") != height:
                errors.append(f"{label}: PNG dimensions do not match manifest")
            if width <= 0 or height <= 0 or width > 1600 or height > 1200:
                errors.append(f"{label}: dimensions exceed 1600x1200")
            if bit_depth != 8 or color_type not in (2, 6):
                errors.append(f"{label}: PNG must use 8-bit RGB or RGBA pixels")
        if len(data) > MAX_FILE_BYTES:
            errors.append(f"{label}: file exceeds {MAX_FILE_BYTES} bytes")
    if asset.get("synthetic") is not True:
        errors.append(f"{label}: synthetic must be true")
    approved = asset.get("approvedForRecording")
    if type(approved) is not bool:
        errors.append(f"{label}: approvedForRecording must be a boolean")
        approved = False
    texts = asset.get("expectedVisibleTexts")
    if not isinstance(texts, list) or not texts or not all(isinstance(text, str) and text for text in texts):
        errors.append(f"{label}: expectedVisibleTexts must be a non-empty string array")
        texts = []
    if DISCLAIMER not in texts:
        errors.append(f"{label}: expectedVisibleTexts must contain the English demo disclaimer")
    if asset_id == "acetaminophen-clean-v1" and CHINESE_DISCLAIMER not in texts:
        errors.append(f"{label}: approved clean image must contain the Chinese demo disclaimer")
    for field in ("expectedReadable", "expectedAmbiguous"):
        if type(asset.get(field)) is not bool:
            errors.append(f"{label}: {field} must be a boolean")
    for field in ("purpose", "generatedBy", "generatorVersion"):
        if not isinstance(asset.get(field), str) or not asset[field]:
            errors.append(f"{label}: {field} must be a non-empty string")
    if asset.get("generatedBy") != "scripts/demo-assets/generate_medicine_demo_assets.py":
        errors.append(f"{label}: generatedBy must identify the repository generator")
    if asset.get("mimeType") != "image/png":
        errors.append(f"{label}: mimeType must be image/png")
    if isinstance(asset_id, str) and relative != f"images/{asset_id}.png":
        errors.append(f"{label}: file must match the asset id")
    canonical_id = asset.get("expectedCanonicalMedicineID")
    if canonical_id is not None and (not isinstance(canonical_id, str) or not canonical_id):
        errors.append(f"{label}: expectedCanonicalMedicineID must be a non-empty string or null")
    if isinstance(asset_id, str) and asset_id.startswith("acetaminophen-") and canonical_id != "demo-acetaminophen":
        errors.append(f"{label}: Acetaminophen assets must use bundled catalog id demo-acetaminophen")
    if asset_id == "cold-relief-ambiguous-v1" and canonical_id is not None:
        errors.append(f"{label}: ambiguous multi-ingredient asset canonical id must be null")
    return asset_id, bool(approved)


def main() -> int:
    errors: list[str] = []
    try:
        manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        print(f"ERROR: could not read manifest: {error}", file=sys.stderr)
        return 1
    if not isinstance(manifest, dict):
        errors.append("manifest root must be an object")
        assets = []
    else:
        if manifest.get("schemaVersion") != 1:
            errors.append("schemaVersion must equal 1")
        assets = manifest.get("assets")
        if not isinstance(assets, list):
            errors.append("assets must be an array")
            assets = []
    ids: list[str] = []
    approved_ids: list[str] = []
    for asset in assets:
        asset_id, approved = validate_asset(asset, errors)
        if asset_id is not None:
            ids.append(asset_id)
            if approved:
                approved_ids.append(asset_id)
    if len(ids) != len(set(ids)):
        errors.append("asset ids must be unique")
    if set(ids) != EXPECTED_IDS:
        errors.append("manifest must contain exactly the four frozen A5 asset ids")
    if ids != sorted(ids):
        errors.append("assets must be sorted by id")
    if approved_ids != ["acetaminophen-clean-v1"]:
        errors.append("exactly acetaminophen-clean-v1 must be approved for recording")
    listed_pngs = {asset.get("file") for asset in assets if isinstance(asset, dict) and isinstance(asset.get("file"), str)}
    actual_pngs = {path.relative_to(ASSET_ROOT).as_posix() for path in (ASSET_ROOT / "images").glob("*.png")}
    if listed_pngs != actual_pngs:
        errors.append("manifest image list must exactly match images/*.png")
    reproducibility = subprocess.run(
        [sys.executable, str(GENERATOR_PATH), "--check"],
        cwd=REPOSITORY_ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    if reproducibility.returncode != 0:
        errors.append(f"generator reproducibility check failed: {reproducibility.stdout.strip()}")
    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print(f"Validated {len(assets)} synthetic medicine PNG assets; hashes, metadata, recording approval, and regenerated bytes are stable.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
