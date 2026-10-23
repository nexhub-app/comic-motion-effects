import json
import math

import numpy as np

from .geometry import polygon_area, polygon_contains
from .types import Detection

DRAFT_VERSION = 1
SIDECAR_VERSION = 1
MAX_PARTS = 8
_COORD_DECIMALS = 6


class DraftError(ValueError):
    pass


class AnchorError(ValueError):
    pass


def _round_coord(value: float) -> float:
    rounded = round(float(value), _COORD_DECIMALS)
    return 0.0 if rounded == 0 else rounded


def validate_polygon(polygon) -> list[str]:
    try:
        pts = np.asarray(polygon, dtype=np.float64)
    except (TypeError, ValueError):
        return ["polygon 不是数值点数组"]
    if pts.ndim != 2 or pts.shape[1] != 2 or len(pts) < 3:
        return ["polygon 必须是至少 3 个 [x,y] 点"]
    if not np.isfinite(pts).all():
        return ["polygon 含非有限数值"]
    if (pts < 0).any() or (pts > 1).any():
        return ["polygon 坐标越界，契约要求 0..1"]
    if polygon_area(pts) < 1e-6:
        return ["polygon 面积≈0"]
    return []


def _clean_polygon(polygon) -> list[list[float]]:
    errors = validate_polygon(polygon)
    if errors:
        raise DraftError(errors[0])
    pts = np.asarray(polygon, dtype=np.float64)
    return [[_round_coord(x), _round_coord(y)] for x, y in pts]


def build_draft(
    page_name: str,
    width: int,
    height: int,
    models: dict,
    detections: list[Detection],
) -> dict:
    if width <= 0 or height <= 0:
        raise DraftError("页面尺寸必须为正")
    ordered = sorted(detections, key=lambda d: -d.score)
    parts = []
    for idx, det in enumerate(ordered, start=1):
        if det.polygon is None:
            raise DraftError(f"detection {idx} 缺少 polygon")
        x1, y1, x2, y2 = (float(v) for v in det.box)
        bbox = [
            _round_coord(np.clip(x1 / width, 0, 1)),
            _round_coord(np.clip(y1 / height, 0, 1)),
            _round_coord(np.clip(x2 / width, 0, 1)),
            _round_coord(np.clip(y2 / height, 0, 1)),
        ]
        parts.append(
            {
                "id": idx,
                "score": round(float(det.score), 6),
                "bbox": bbox,
                "polygon": _clean_polygon(det.polygon),
                "anchor": None,
            }
        )
    if len(parts) > MAX_PARTS:
        raise DraftError(f"部件数超过上限 {MAX_PARTS}")
    return {
        "version": DRAFT_VERSION,
        "page": page_name,
        "width": int(width),
        "height": int(height),
        "models": dict(models),
        "parts": parts,
    }


def _normalize_anchors(anchors: dict) -> dict[int, tuple[float, float] | None]:
    out: dict[int, tuple[float, float] | None] = {}
    for key, value in anchors.items():
        part_id = int(key)
        if value is None:
            out[part_id] = None
            continue
        if not isinstance(value, (list, tuple)) or len(value) != 2:
            raise AnchorError(f"anchor[{part_id}] 必须是 [x,y] 或 null")
        x, y = float(value[0]), float(value[1])
        if not (math.isfinite(x) and math.isfinite(y)):
            raise AnchorError(f"anchor[{part_id}] 含非有限数值")
        out[part_id] = (x, y)
    return out


def compose_sidecar(
    draft: dict, anchors: dict, allow_skip: bool = False
) -> dict:
    parts = draft.get("parts")
    if not isinstance(parts, list) or not parts:
        raise DraftError("draft.parts 为空")
    if len(parts) > MAX_PARTS:
        raise DraftError(f"部件数超过上限 {MAX_PARTS}")

    ids = [int(p.get("id", -1)) for p in parts]
    if len(set(ids)) != len(ids):
        raise DraftError("draft.parts 存在重复 id")
    normalized = _normalize_anchors(anchors)

    missing = [part_id for part_id in ids if normalized.get(part_id) is None]
    if missing and not allow_skip:
        raise AnchorError(f"缺少人工确认锚点：part {', '.join(map(str, missing))}")

    composed = []
    for part in sorted(parts, key=lambda p: int(p["id"])):
        part_id = int(part["id"])
        polygon = _clean_polygon(part.get("polygon"))
        anchor = normalized.get(part_id)
        if anchor is None:
            continue
        x, y = anchor
        if not (0 <= x <= 1 and 0 <= y <= 1):
            raise AnchorError(f"part {part_id} 锚点越界")
        if not polygon_contains(np.asarray(polygon), (x, y)):
            raise AnchorError(f"part {part_id} 锚点落在 polygon 外")
        composed.append(
            {
                "kind": "hand",
                "polygon": polygon,
                "anchor": {
                    "x": _round_coord(x),
                    "y": _round_coord(y),
                    "joint": "wrist",
                },
            }
        )

    if not composed:
        raise AnchorError("没有任何已确认锚点的部件")
    return {"version": SIDECAR_VERSION, "parts": composed}


def dumps_json(data: dict) -> str:
    return json.dumps(data, ensure_ascii=False, indent=2, allow_nan=False) + "\n"


def write_json(path, data: dict) -> None:
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(dumps_json(data))


def load_json(path) -> dict:
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def validate_sidecar(data: dict) -> list[str]:
    errors: list[str] = []
    if not isinstance(data, dict):
        return ["sidecar 顶层不是对象"]
    if data.get("version") != SIDECAR_VERSION:
        errors.append(f"version 必须是 {SIDECAR_VERSION}")
    parts = data.get("parts")
    if not isinstance(parts, list) or not parts:
        return errors + ["parts 必须是非空数组"]
    if len(parts) > MAX_PARTS:
        errors.append(f"parts 超过上限 {MAX_PARTS}")
    for index, part in enumerate(parts):
        tag = f"parts[{index}]"
        if not isinstance(part, dict):
            errors.append(f"{tag} 不是对象")
            continue
        if part.get("kind") != "hand":
            errors.append(f"{tag}.kind 必须是 hand")
        try:
            polygon = _clean_polygon(part.get("polygon"))
        except DraftError as exc:
            errors.append(f"{tag}.polygon: {exc}")
            continue
        anchor = part.get("anchor")
        if not isinstance(anchor, dict):
            errors.append(f"{tag}.anchor 缺失或不是对象")
            continue
        x, y = anchor.get("x"), anchor.get("y")
        if not isinstance(x, (int, float)) or not isinstance(y, (int, float)):
            errors.append(f"{tag}.anchor 缺少数值 x/y")
            continue
        if not (0 <= x <= 1 and 0 <= y <= 1):
            errors.append(f"{tag}.anchor 坐标必须在 0..1")
            continue
        if anchor.get("joint") != "wrist":
            errors.append(f"{tag}.anchor.joint 必须是 wrist")
        if not polygon_contains(np.asarray(polygon), (float(x), float(y))):
            errors.append(f"{tag}.anchor 必须落在 polygon inside")
    return errors
