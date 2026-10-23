import json
import math
from pathlib import Path

import numpy as np

from .geometry import polygon_contains
from .sidecar import validate_polygon

PREDICTION_SUFFIXES = (".part_motion.json", ".draft.json")


def strip_suffix(name: str) -> str:
    for suffix in PREDICTION_SUFFIXES:
        if name.endswith(suffix):
            return name[: -len(suffix)]
    return Path(name).stem


def _validate_hand(hand, tag: str) -> None:
    if not isinstance(hand, dict):
        raise ValueError(f"{tag} 不是对象")
    errors = validate_polygon(hand.get("polygon"))
    if errors:
        raise ValueError(f"{tag}: {errors[0]}")
    wrist = hand.get("wrist")
    if not isinstance(wrist, (list, tuple)) or len(wrist) != 2:
        raise ValueError(f"{tag}.wrist 必须是 [x,y]")
    x, y = float(wrist[0]), float(wrist[1])
    if not (math.isfinite(x) and math.isfinite(y)):
        raise ValueError(f"{tag}.wrist 含非有限数值")
    if not (0 <= x <= 1 and 0 <= y <= 1):
        raise ValueError(f"{tag}.wrist 必须在 0..1")
    if not polygon_contains(np.asarray(hand["polygon"], dtype=np.float64), (x, y)):
        raise ValueError(f"{tag}.wrist 必须落在 polygon 内")


def load_annotations(directory) -> list[dict]:
    annotations = []
    seen_pages: set[str] = set()
    for path in sorted(Path(directory).glob("*.json")):
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
        if not isinstance(data, dict):
            raise ValueError(f"{path.name}: 顶层必须是对象")
        for field in ("page", "width", "height", "hands"):
            if field not in data:
                raise ValueError(f"{path.name}: 缺少字段 {field}")
        if int(data["width"]) <= 0 or int(data["height"]) <= 0:
            raise ValueError(f"{path.name}: width/height 必须为正")
        if not isinstance(data["hands"], list):
            raise ValueError(f"{path.name}: hands 必须是数组")
        page = str(data["page"])
        if page in seen_pages:
            raise ValueError(f"{path.name}: 重复 page {page}")
        seen_pages.add(page)
        for index, hand in enumerate(data["hands"]):
            _validate_hand(hand, f"{path.name}.hands[{index}]")
        annotations.append(data)
    if not annotations:
        raise ValueError(f"{directory} 中没有标注 JSON")
    return annotations


def load_predictions(directory) -> dict[str, dict]:
    chosen: dict[str, Path] = {}
    for suffix in PREDICTION_SUFFIXES:
        for path in sorted(Path(directory).glob(f"*{suffix}")):
            stem = strip_suffix(path.name)
            chosen.setdefault(stem, path)
    predictions = {}
    for stem, path in chosen.items():
        with open(path, encoding="utf-8") as fh:
            predictions[stem] = json.load(fh)
    return predictions
