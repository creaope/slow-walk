#!/usr/bin/env python3
"""Generate the fixed SlowWalk A5 synthetic medicine image bundle."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import struct
import sys
import zlib


GENERATOR_VERSION = "1.0.0"
GENERATED_BY = "scripts/demo-assets/generate_medicine_demo_assets.py"
REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
ASSET_ROOT = REPOSITORY_ROOT / "shared/demo-assets/medicine"
WIDTH = 640
HEIGHT = 480
DISCLAIMER = "DEMO DATA — NOT FOR CLINICAL USE"
CHINESE_DISCLAIMER = "演示数据，不用于临床用途"

FONT = {
    " ": ("00000",) * 7,
    "-": ("00000", "00000", "00000", "11111", "00000", "00000", "00000"),
    "—": ("000000000", "000000000", "000000000", "111111111", "111111111", "000000000", "000000000"),
    ".": ("00000", "00000", "00000", "00000", "00000", "01100", "01100"),
    "0": ("01110", "10001", "10011", "10101", "11001", "10001", "01110"),
    "1": ("00100", "01100", "00100", "00100", "00100", "00100", "01110"),
    "2": ("01110", "10001", "00001", "00010", "00100", "01000", "11111"),
    "3": ("11110", "00001", "00001", "01110", "00001", "00001", "11110"),
    "4": ("00010", "00110", "01010", "10010", "11111", "00010", "00010"),
    "5": ("11111", "10000", "10000", "11110", "00001", "00001", "11110"),
    "6": ("01110", "10000", "10000", "11110", "10001", "10001", "01110"),
    "7": ("11111", "00001", "00010", "00100", "01000", "01000", "01000"),
    "8": ("01110", "10001", "10001", "01110", "10001", "10001", "01110"),
    "9": ("01110", "10001", "10001", "01111", "00001", "00001", "01110"),
    "A": ("01110", "10001", "10001", "11111", "10001", "10001", "10001"),
    "B": ("11110", "10001", "10001", "11110", "10001", "10001", "11110"),
    "C": ("01111", "10000", "10000", "10000", "10000", "10000", "01111"),
    "D": ("11110", "10001", "10001", "10001", "10001", "10001", "11110"),
    "E": ("11111", "10000", "10000", "11110", "10000", "10000", "11111"),
    "F": ("11111", "10000", "10000", "11110", "10000", "10000", "10000"),
    "G": ("01111", "10000", "10000", "10111", "10001", "10001", "01111"),
    "H": ("10001", "10001", "10001", "11111", "10001", "10001", "10001"),
    "I": ("01110", "00100", "00100", "00100", "00100", "00100", "01110"),
    "J": ("00111", "00010", "00010", "00010", "10010", "10010", "01100"),
    "K": ("10001", "10010", "10100", "11000", "10100", "10010", "10001"),
    "L": ("10000", "10000", "10000", "10000", "10000", "10000", "11111"),
    "M": ("10001", "11011", "10101", "10101", "10001", "10001", "10001"),
    "N": ("10001", "11001", "10101", "10011", "10001", "10001", "10001"),
    "O": ("01110", "10001", "10001", "10001", "10001", "10001", "01110"),
    "P": ("11110", "10001", "10001", "11110", "10000", "10000", "10000"),
    "Q": ("01110", "10001", "10001", "10001", "10101", "10010", "01101"),
    "R": ("11110", "10001", "10001", "11110", "10100", "10010", "10001"),
    "S": ("01111", "10000", "10000", "01110", "00001", "00001", "11110"),
    "T": ("11111", "00100", "00100", "00100", "00100", "00100", "00100"),
    "U": ("10001", "10001", "10001", "10001", "10001", "10001", "01110"),
    "V": ("10001", "10001", "10001", "10001", "10001", "01010", "00100"),
    "W": ("10001", "10001", "10001", "10101", "10101", "10101", "01010"),
    "X": ("10001", "10001", "01010", "00100", "01010", "10001", "10001"),
    "Y": ("10001", "10001", "01010", "00100", "00100", "00100", "00100"),
    "Z": ("11111", "00001", "00010", "00100", "01000", "10000", "11111"),
    "g": ("00000", "01111", "10001", "10001", "01111", "00001", "01110"),
    "m": ("00000", "11010", "10101", "10101", "10101", "10101", "10101"),
}

# Original fixed-stroke glyphs used only for the required synthetic disclaimer.
CJK_STROKES = {
    "演": "1,3,3,5|1,7,3,8|1,14,4,10|9,1,10,2|5,3,14,3|6,5,13,5|7,5,7,11|12,5,12,11|7,7,12,7|7,10,12,10|5,12,14,12|8,13,5,15|11,13,14,15",
    "示": "4,3,12,3|2,6,14,6|8,6,8,15|5,9,2,13|11,9,14,13",
    "数": "4,1,4,9|1,4,7,4|1,1,3,3|7,1,5,3|4,5,1,9|4,5,7,9|10,2,15,2|13,1,10,7|9,7,15,7|12,7,10,13|10,10,15,15|15,9,12,14",
    "据": "1,5,6,5|4,1,4,14|1,11,6,8|4,14,2,13|8,2,15,2|8,2,8,14|8,6,14,6|11,6,11,9|9,9,15,9|9,9,9,14|9,14,15,14|15,9,15,14",
    "，": "9,11,11,11|10,12,8,15",
    "不": "2,3,14,3|9,3,7,7|7,7,7,15|7,8,2,12|8,8,14,13",
    "用": "4,2,14,2|4,2,4,15|14,2,14,14|14,14,12,15|4,7,14,7|4,11,14,11|9,2,9,14",
    "于": "4,3,12,3|2,7,14,7|9,7,9,14|9,14,6,15",
    "临": "2,2,2,13|5,2,5,11|8,2,14,2|9,4,8,7|12,3,12,7|8,8,15,8|8,8,8,15|15,8,15,15|8,15,15,15|11,9,11,14",
    "床": "8,1,10,3|3,3,15,3|3,3,3,14|8,5,8,15|4,8,14,8|8,8,4,13|8,8,14,14",
    "途": "8,1,12,4|6,5,14,5|10,4,10,13|7,8,14,8|8,10,6,13|12,10,14,13|2,3,4,5|2,8,5,8|5,8,4,13|4,13,7,15|7,15,15,15",
}


class Canvas:
    def __init__(self, width: int, height: int, color: tuple[int, int, int]):
        self.width = width
        self.height = height
        self.pixels = bytearray(bytes(color) * (width * height))

    def set_pixel(self, x: int, y: int, color: tuple[int, int, int]) -> None:
        if 0 <= x < self.width and 0 <= y < self.height:
            offset = (y * self.width + x) * 3
            self.pixels[offset : offset + 3] = bytes(color)

    def pixel(self, x: int, y: int) -> tuple[int, int, int]:
        offset = (y * self.width + x) * 3
        return tuple(self.pixels[offset : offset + 3])  # type: ignore[return-value]

    def rectangle(self, x0: int, y0: int, x1: int, y1: int, color: tuple[int, int, int]) -> None:
        x0, x1 = max(0, x0), min(self.width, x1)
        y0, y1 = max(0, y0), min(self.height, y1)
        row = bytes(color) * max(0, x1 - x0)
        for y in range(y0, y1):
            offset = (y * self.width + x0) * 3
            self.pixels[offset : offset + len(row)] = row

    def line(self, x0: int, y0: int, x1: int, y1: int, color: tuple[int, int, int], width: int = 1) -> None:
        dx, sx = abs(x1 - x0), 1 if x0 < x1 else -1
        dy, sy = -abs(y1 - y0), 1 if y0 < y1 else -1
        error = dx + dy
        while True:
            radius = width // 2
            self.rectangle(x0 - radius, y0 - radius, x0 + radius + 1, y0 + radius + 1, color)
            if x0 == x1 and y0 == y1:
                break
            twice = 2 * error
            if twice >= dy:
                error += dy
                x0 += sx
            if twice <= dx:
                error += dx
                y0 += sy


def text_width(text: str, scale: int) -> int:
    return sum((len(FONT[character][0]) + 1) * scale for character in text) - scale


def draw_text(canvas: Canvas, text: str, x: int, y: int, scale: int, color: tuple[int, int, int]) -> None:
    for character in text:
        rows = FONT.get(character)
        if rows is None:
            raise ValueError(f"unsupported fixed-font character: {character!r}")
        for row_index, row in enumerate(rows):
            for column_index, value in enumerate(row):
                if value == "1":
                    canvas.rectangle(
                        x + column_index * scale,
                        y + row_index * scale,
                        x + (column_index + 1) * scale,
                        y + (row_index + 1) * scale,
                        color,
                    )
        x += (len(rows[0]) + 1) * scale


def draw_text_center(canvas: Canvas, text: str, y: int, scale: int, color: tuple[int, int, int]) -> None:
    draw_text(canvas, text, (canvas.width - text_width(text, scale)) // 2, y, scale, color)


def draw_chinese_disclaimer(canvas: Canvas, x: int, y: int, scale: int, color: tuple[int, int, int]) -> None:
    cell_width = 18 * scale
    for index, character in enumerate(CHINESE_DISCLAIMER):
        for segment in CJK_STROKES[character].split("|"):
            x0, y0, x1, y1 = (int(value) for value in segment.split(","))
            canvas.line(
                x + index * cell_width + x0 * scale,
                y + y0 * scale,
                x + index * cell_width + x1 * scale,
                y + y1 * scale,
                color,
                max(2, scale),
            )


def label_frame() -> Canvas:
    canvas = Canvas(WIDTH, HEIGHT, (220, 225, 222))
    canvas.rectangle(28, 30, 620, 456, (111, 119, 116))
    canvas.rectangle(20, 22, 612, 448, (249, 248, 243))
    canvas.rectangle(20, 22, 44, 448, (30, 122, 126))
    return canvas


def acetaminophen_clean() -> Canvas:
    canvas = label_frame()
    ink = (31, 44, 48)
    coral = (210, 82, 66)
    canvas.rectangle(44, 22, 612, 103, coral)
    draw_text_center(canvas, "SLOWWALK DEMO MEDICINE", 48, 3, (255, 255, 250))
    canvas.rectangle(82, 123, 558, 129, (30, 122, 126))
    draw_text_center(canvas, "ACETAMINOPHEN", 158, 5, ink)
    canvas.rectangle(226, 244, 414, 302, (30, 122, 126))
    draw_text_center(canvas, "500 mg", 259, 4, (255, 255, 250))
    canvas.rectangle(82, 326, 558, 330, coral)
    draw_text_center(canvas, DISCLAIMER, 347, 2, ink)
    chinese_width = len(CHINESE_DISCLAIMER) * 36
    draw_chinese_disclaimer(canvas, (WIDTH - chinese_width) // 2, 388, 2, ink)
    return canvas


def rotated_angle(source: Canvas) -> Canvas:
    canvas = Canvas(WIDTH, HEIGHT, (194, 201, 198))
    denominator = 65 * 86
    for y in range(HEIGHT):
        dy = y - HEIGHT // 2
        for x in range(WIDTH):
            dx = x - WIDTH // 2
            source_x = WIDTH // 2 + round_div((64 * dx + 8 * dy) * 100, denominator)
            source_y = HEIGHT // 2 + round_div((-8 * dx + 64 * dy) * 100, denominator)
            if 0 <= source_x < WIDTH and 0 <= source_y < HEIGHT:
                canvas.set_pixel(x, y, source.pixel(source_x, source_y))
    return canvas


def round_div(numerator: int, denominator: int) -> int:
    if numerator < 0:
        return -((-numerator + denominator // 2) // denominator)
    return (numerator + denominator // 2) // denominator


def lowlight(source: Canvas) -> Canvas:
    canvas = Canvas(WIDTH, HEIGHT, (0, 0, 0))
    for y in range(HEIGHT):
        for x in range(WIDTH):
            edge = max(abs(x - WIDTH // 2) * 100 // (WIDTH // 2), abs(y - HEIGHT // 2) * 100 // (HEIGHT // 2))
            factor = 56 - min(edge, 100) * 16 // 100
            canvas.set_pixel(x, y, tuple(5 + value * factor // 100 for value in source.pixel(x, y)))
    return canvas


def ambiguous_label() -> Canvas:
    canvas = label_frame()
    ink = (31, 44, 48)
    coral = (210, 82, 66)
    canvas.rectangle(44, 22, 612, 86, (30, 122, 126))
    draw_text_center(canvas, "SLOWWALK SYNTHETIC LABEL", 44, 2, (255, 255, 250))
    draw_text_center(canvas, "COLD RELIEF STUDY", 118, 3, ink)
    draw_text_center(canvas, "MULTI-INGREDIENT", 171, 2, coral)
    draw_text(canvas, "ACETAMINOPHEN", 86, 226, 2, ink)
    draw_text(canvas, "DEXTROMETHORPHAN", 86, 267, 2, ink)
    draw_text(canvas, "CHLORPHENIRAMINE", 86, 308, 2, ink)
    canvas.rectangle(194, 303, 526, 340, (83, 89, 90))
    draw_text_center(canvas, "LABEL OBSCURED", 314, 2, (255, 255, 250))
    canvas.rectangle(82, 377, 558, 381, coral)
    draw_text_center(canvas, DISCLAIMER, 402, 2, ink)
    return canvas


def png_bytes(canvas: Canvas) -> bytes:
    raw = bytearray()
    row_length = canvas.width * 3
    for y in range(canvas.height):
        raw.append(0)
        offset = y * row_length
        raw.extend(canvas.pixels[offset : offset + row_length])
    header = struct.pack(">IIBBBBB", canvas.width, canvas.height, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR", header) + png_chunk(b"IDAT", stored_zlib(bytes(raw))) + png_chunk(b"IEND", b"")


def stored_zlib(data: bytes) -> bytes:
    output = bytearray(b"\x78\x01")
    for offset in range(0, len(data), 65_535):
        block = data[offset : offset + 65_535]
        final = offset + len(block) == len(data)
        output.append(1 if final else 0)
        output.extend(struct.pack("<HH", len(block), len(block) ^ 0xFFFF))
        output.extend(block)
    output.extend(struct.pack(">I", zlib.adler32(data) & 0xFFFFFFFF))
    return bytes(output)


def png_chunk(kind: bytes, payload: bytes) -> bytes:
    checksum = zlib.crc32(kind + payload) & 0xFFFFFFFF
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", checksum)


def build_bundle() -> dict[str, bytes]:
    clean = acetaminophen_clean()
    images = {
        "images/acetaminophen-angle-v1.png": png_bytes(rotated_angle(clean)),
        "images/acetaminophen-clean-v1.png": png_bytes(clean),
        "images/acetaminophen-lowlight-v1.png": png_bytes(lowlight(clean)),
        "images/cold-relief-ambiguous-v1.png": png_bytes(ambiguous_label()),
    }
    acetaminophen_texts = [
        "SLOWWALK DEMO MEDICINE",
        "ACETAMINOPHEN",
        "500 mg",
        DISCLAIMER,
        CHINESE_DISCLAIMER,
    ]
    definitions = {
        "acetaminophen-angle-v1": ("Deterministic rotated capture test", True, False, False, "demo-acetaminophen", acetaminophen_texts),
        "acetaminophen-clean-v1": ("Approved A5 recording image", True, False, True, "demo-acetaminophen", acetaminophen_texts),
        "acetaminophen-lowlight-v1": ("Deterministic low-light capture test", True, False, False, "demo-acetaminophen", acetaminophen_texts),
        "cold-relief-ambiguous-v1": (
            "Multi-ingredient and partially obscured ambiguity test",
            True,
            True,
            False,
            None,
            [
                "SLOWWALK SYNTHETIC LABEL",
                "COLD RELIEF STUDY",
                "MULTI-INGREDIENT",
                "ACETAMINOPHEN",
                "DEXTROMETHORPHAN",
                DISCLAIMER,
            ],
        ),
    }
    assets = []
    for asset_id in sorted(definitions):
        purpose, readable, ambiguous, approved, canonical_id, texts = definitions[asset_id]
        filename = f"images/{asset_id}.png"
        assets.append(
            {
                "id": asset_id,
                "file": filename,
                "sha256": hashlib.sha256(images[filename]).hexdigest(),
                "synthetic": True,
                "approvedForRecording": approved,
                "expectedVisibleTexts": texts,
                "expectedCanonicalMedicineID": canonical_id,
                "purpose": purpose,
                "expectedReadable": readable,
                "expectedAmbiguous": ambiguous,
                "generatedBy": GENERATED_BY,
                "generatorVersion": GENERATOR_VERSION,
                "width": WIDTH,
                "height": HEIGHT,
                "mimeType": "image/png",
            }
        )
    manifest = {
        "schemaVersion": 1,
        "assetSet": "slowwalk-a5-medicine-v1",
        "disclaimer": DISCLAIMER,
        "assets": assets,
    }
    images["manifest.json"] = (json.dumps(manifest, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    return images


def check_bundle(bundle: dict[str, bytes]) -> int:
    differences = []
    for relative_path, expected in bundle.items():
        path = ASSET_ROOT / relative_path
        if not path.is_file():
            differences.append(f"missing: {relative_path}")
        elif path.read_bytes() != expected:
            differences.append(f"content differs: {relative_path}")
    expected_pngs = {path for path in bundle if path.endswith(".png")}
    if (ASSET_ROOT / "images").is_dir():
        actual_pngs = {path.relative_to(ASSET_ROOT).as_posix() for path in (ASSET_ROOT / "images").glob("*.png")}
        differences.extend(f"unexpected: {path}" for path in sorted(actual_pngs - expected_pngs))
    if differences:
        print("Medicine demo assets are not byte-for-byte current:", file=sys.stderr)
        for difference in differences:
            print(f"  {difference}", file=sys.stderr)
        return 1
    print("Medicine demo assets are byte-for-byte current (4 PNG files and manifest.json).")
    return 0


def write_bundle(bundle: dict[str, bytes]) -> None:
    for relative_path, content in bundle.items():
        path = ASSET_ROOT / relative_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
    print(f"Generated {len(bundle) - 1} synthetic PNG files and manifest.json in {ASSET_ROOT.relative_to(REPOSITORY_ROOT)}.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="compare regenerated bytes without writing files")
    arguments = parser.parse_args()
    bundle = build_bundle()
    if arguments.check:
        return check_bundle(bundle)
    write_bundle(bundle)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
