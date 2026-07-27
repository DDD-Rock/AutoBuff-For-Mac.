#!/usr/bin/env python3
"""Build fixed-font EXP templates from the collector dataset without OCR."""

from __future__ import annotations

import argparse
import json
import re
from collections import defaultdict
from pathlib import Path

import numpy as np
from PIL import Image


CANONICAL_SIZE = (185, 44)
TEXT_TOP = 3
TEXT_HEIGHT = 15
ANCHOR_X = 8
ANCHOR_WIDTH = 30
DIGIT_X = 41
DIGIT_WIDTH = 6
DIGIT_ADVANCE = 7


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("dataset", type=Path)
    parser.add_argument("output", type=Path)
    return parser.parse_args()


def foreground_mask(image: np.ndarray) -> np.ndarray:
    rgb = image.astype(np.int16)
    return (rgb.min(axis=2) >= 150) & ((rgb.max(axis=2) - rgb.min(axis=2)) <= 65)


def parse_percentage(raw_text: str) -> str:
    matches = re.findall(r"(\d+(?:[\.,]\d+)?)\s*%", raw_text)
    if not matches:
        raise ValueError(f"percentage is missing from label: {raw_text!r}")
    return matches[-1].replace(",", ".")


def parse_current_exp(entry: dict) -> str:
    if "current_exp" in entry:
        return str(entry["current_exp"])
    raw_text = entry.get("suspected_text", "")
    match = re.search(r"(?:E|D|Đ|F)XP[\s\.:_-]*(\d+)", raw_text, re.IGNORECASE)
    if not match:
        raise ValueError(f"current EXP is missing from label: {raw_text!r}")
    return match.group(1)


def context_path(dataset: Path, entry: dict) -> Path:
    relative = entry.get("context")
    if not relative:
        raise ValueError(f"context path is missing: {entry}")
    return dataset / relative


def crop(mask: np.ndarray, x: int, width: int) -> np.ndarray:
    return mask[TEXT_TOP : TEXT_TOP + TEXT_HEIGHT, x : x + width]


def add_sample(
    templates: dict[str, list[np.ndarray]],
    mask: np.ndarray,
    current_exp: str,
    percentage: str,
) -> None:
    templates["anchor"].append(crop(mask, ANCHOR_X, ANCHOR_WIDTH))

    for index, character in enumerate(current_exp):
        templates[character].append(
            crop(mask, DIGIT_X + index * DIGIT_ADVANCE, DIGIT_WIDTH)
        )

    left_paren_x = DIGIT_X + len(current_exp) * DIGIT_ADVANCE
    templates["left_paren"].append(crop(mask, left_paren_x, 3))

    integer_part, fractional_part = percentage.split(".", maxsplit=1)
    percentage_x = left_paren_x + 4
    for index, character in enumerate(integer_part):
        templates[character].append(
            crop(mask, percentage_x + index * DIGIT_ADVANCE, DIGIT_WIDTH)
        )

    dot_x = percentage_x + len(integer_part) * DIGIT_ADVANCE
    templates["dot"].append(crop(mask, dot_x, 2))
    fraction_x = dot_x + 3
    for index, character in enumerate(fractional_part):
        templates[character].append(
            crop(mask, fraction_x + index * DIGIT_ADVANCE, DIGIT_WIDTH)
        )

    percent_x = fraction_x + len(fractional_part) * DIGIT_ADVANCE
    templates["percent"].append(crop(mask, percent_x, 11))
    templates["right_paren"].append(crop(mask, percent_x + 16, 3))


def consensus(samples: list[np.ndarray]) -> np.ndarray:
    shapes = {sample.shape for sample in samples}
    if len(shapes) != 1:
        raise ValueError(f"template samples have inconsistent shapes: {shapes}")
    votes = np.stack(samples).mean(axis=0)
    return (votes >= 0.5).astype(np.uint8) * 255


def main() -> None:
    args = parse_args()
    manifest = args.dataset / "manifest.jsonl"
    entries = [json.loads(line) for line in manifest.read_text().splitlines() if line]
    templates: dict[str, list[np.ndarray]] = defaultdict(list)
    used_samples = 0

    for entry in entries:
        raw_text = entry.get("raw_text") or entry.get("suspected_text") or ""
        try:
            current_exp = parse_current_exp(entry)
            percentage = parse_percentage(raw_text)
            if "." not in percentage:
                continue
            path = context_path(args.dataset, entry)
            image = Image.open(path).convert("RGB")
            if image.size != CANONICAL_SIZE:
                raise ValueError(
                    f"unexpected panel size {image.size}, expected {CANONICAL_SIZE}: {path}"
                )
            add_sample(
                templates,
                foreground_mask(np.asarray(image)),
                current_exp,
                percentage,
            )
            used_samples += 1
        except (FileNotFoundError, ValueError) as error:
            print(f"skip {entry.get('id', '?')}: {error}")

    missing = [character for character in "0123456789" if not templates[character]]
    if missing:
        raise SystemExit(f"missing digit samples: {', '.join(missing)}")

    args.output.mkdir(parents=True, exist_ok=True)
    names = {
        "anchor": "exp_anchor.png",
        "left_paren": "exp_left_paren.png",
        "dot": "exp_dot.png",
        "percent": "exp_percent.png",
        "right_paren": "exp_right_paren.png",
    }
    names.update({character: f"exp_char_{character}.png" for character in "0123456789"})

    counts = {}
    for label, filename in names.items():
        if not templates[label]:
            raise SystemExit(f"missing template samples for {label}")
        Image.fromarray(consensus(templates[label]), mode="L").save(args.output / filename)
        counts[label] = len(templates[label])

    metadata = {
        "schema_version": 1,
        "canonical_width": CANONICAL_SIZE[0],
        "canonical_height": CANONICAL_SIZE[1],
        "used_samples": used_samples,
        "template_sample_counts": counts,
    }
    (args.output / "exp_templates.json").write_text(
        json.dumps(metadata, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    )
    print(json.dumps(metadata, ensure_ascii=False, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
