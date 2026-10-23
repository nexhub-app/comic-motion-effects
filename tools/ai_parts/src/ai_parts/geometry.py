from dataclasses import dataclass

import cv2
import numpy as np

from .types import Detection

PAD_VALUE = 114
POLYGON_RASTER_SIZE = 512


@dataclass(frozen=True)
class LetterboxParams:
    scale: float
    pad_x: int
    pad_y: int
    model_size: int
    page_w: int
    page_h: int


def letterbox(image: np.ndarray, size: int = 640) -> tuple[np.ndarray, LetterboxParams]:
    h, w = image.shape[:2]
    scale = min(size / w, size / h)
    new_w, new_h = int(round(w * scale)), int(round(h * scale))
    canvas = np.full((size, size, 3), PAD_VALUE, dtype=np.uint8)
    pad_x = (size - new_w) // 2
    pad_y = (size - new_h) // 2
    resized = cv2.resize(image, (new_w, new_h), interpolation=cv2.INTER_LINEAR)
    canvas[pad_y : pad_y + new_h, pad_x : pad_x + new_w] = resized
    return canvas, LetterboxParams(scale, pad_x, pad_y, size, w, h)


def map_model_box_to_page(box: np.ndarray, params: LetterboxParams) -> np.ndarray:
    box = np.asarray(box, dtype=np.float64).copy()
    box[[0, 2]] = (box[[0, 2]] - params.pad_x) / params.scale
    box[[1, 3]] = (box[[1, 3]] - params.pad_y) / params.scale
    return box


def _rows_to_xyxy(rows: np.ndarray) -> np.ndarray:
    cx, cy, bw, bh = rows[:, 0], rows[:, 1], rows[:, 2], rows[:, 3]
    return np.stack([cx - bw / 2, cy - bh / 2, cx + bw / 2, cy + bh / 2], axis=1)


def decode_yolo(
    raw: np.ndarray, conf: float, params: LetterboxParams
) -> list[Detection]:
    out = np.asarray(raw)
    if out.ndim == 3:
        out = out[0]
    if out.ndim != 2:
        raise ValueError(f"unexpected detector output shape: {raw.shape}")
    if out.shape[0] == 5 and out.shape[1] != 5:
        out = out.T
    if out.shape[1] != 5:
        raise ValueError(f"unexpected detector output shape: {raw.shape}")

    rows = out[out[:, 4] >= conf]
    if len(rows) == 0:
        return []
    boxes = _rows_to_xyxy(rows)
    detections = []
    for box, score in zip(boxes, rows[:, 4]):
        page_box = map_model_box_to_page(box, params)
        page_box[[0, 2]] = np.clip(page_box[[0, 2]], 0, params.page_w)
        page_box[[1, 3]] = np.clip(page_box[[1, 3]], 0, params.page_h)
        detections.append(Detection(score=float(score), box=page_box))
    return detections


def iou_xyxy(a: np.ndarray, b: np.ndarray) -> float:
    x1 = max(float(a[0]), float(b[0]))
    y1 = max(float(a[1]), float(b[1]))
    x2 = min(float(a[2]), float(b[2]))
    y2 = min(float(a[3]), float(b[3]))
    inter = max(0.0, x2 - x1) * max(0.0, y2 - y1)
    area_a = max(0.0, float(a[2] - a[0])) * max(0.0, float(a[3] - a[1]))
    area_b = max(0.0, float(b[2] - b[0])) * max(0.0, float(b[3] - b[1]))
    union = area_a + area_b - inter
    return inter / union if union > 0 else 0.0


def nms(
    boxes: np.ndarray, scores: np.ndarray, iou_thr: float = 0.5
) -> list[int]:
    order = np.argsort(-np.asarray(scores), kind="stable")
    keep: list[int] = []
    for idx in order:
        if all(iou_xyxy(boxes[idx], boxes[k]) <= iou_thr for k in keep):
            keep.append(int(idx))
    return keep


def mask_to_polygon(mask: np.ndarray) -> np.ndarray | None:
    mask_u8 = mask.astype(np.uint8)
    contours, _ = cv2.findContours(mask_u8, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    if not contours:
        return None
    contour = max(contours, key=cv2.contourArea)
    if cv2.contourArea(contour) <= 0:
        return None
    epsilon = 0.004 * cv2.arcLength(contour, True)
    approx = cv2.approxPolyDP(contour, epsilon, True).reshape(-1, 2)
    if len(approx) < 3:
        return None
    h, w = mask.shape[:2]
    poly = approx.astype(np.float64) / np.array([w, h], dtype=np.float64)
    poly = np.clip(poly, 0.0, 1.0)
    if polygon_area(poly) < 1e-6:
        return None
    return poly


def polygon_area(poly: np.ndarray) -> float:
    pts = np.asarray(poly, dtype=np.float64)
    x, y = pts[:, 0], pts[:, 1]
    return float(abs(np.dot(x, np.roll(y, -1)) - np.dot(y, np.roll(x, -1))) / 2.0)


def _point_on_segment(
    point: tuple[float, float],
    a: np.ndarray,
    b: np.ndarray,
    eps: float = 1e-9,
) -> bool:
    px, py = point
    ax, ay = a
    bx, by = b
    cross = (bx - ax) * (py - ay) - (by - ay) * (px - ax)
    if abs(cross) > eps:
        return False
    dot = (px - ax) * (bx - ax) + (py - ay) * (by - ay)
    length_sq = (bx - ax) ** 2 + (by - ay) ** 2
    return -eps <= dot <= length_sq + eps


def polygon_contains(poly: np.ndarray, point: tuple[float, float]) -> bool:
    pts = np.asarray(poly, dtype=np.float64)
    x, y = point
    for i in range(len(pts)):
        if _point_on_segment(point, pts[i], pts[(i + 1) % len(pts)]):
            return True
    inside = False
    j = len(pts) - 1
    for i in range(len(pts)):
        xi, yi = pts[i]
        xj, yj = pts[j]
        crosses = (yi > y) != (yj > y)
        if crosses:
            x_cross = (xj - xi) * (y - yi) / (yj - yi) + xi
            if x < x_cross:
                inside = not inside
        j = i
    return inside


def _rasterize(poly: np.ndarray, size: int) -> np.ndarray:
    canvas = np.zeros((size, size), dtype=np.uint8)
    pts = np.round(np.asarray(poly, dtype=np.float64) * (size - 1)).astype(np.int32)
    cv2.fillPoly(canvas, [pts], 1)
    return canvas.astype(bool)


def polygon_iou(
    a: np.ndarray, b: np.ndarray, raster_size: int = POLYGON_RASTER_SIZE
) -> float:
    ra = _rasterize(a, raster_size)
    rb = _rasterize(b, raster_size)
    union = np.logical_or(ra, rb).sum()
    if union == 0:
        return 0.0
    return float(np.logical_and(ra, rb).sum() / union)
