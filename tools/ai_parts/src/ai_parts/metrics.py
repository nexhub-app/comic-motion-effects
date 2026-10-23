import math
import statistics

import numpy as np

from .geometry import polygon_area, polygon_iou
from .sidecar import validate_polygon, validate_sidecar

MIN_HAND_AREA = 0.002
MATCH_IOU = 0.5
SEG_MEDIAN_GATE = 0.70
SEG_FRACTION_GATE = 0.80
SEG_FRACTION_IOU = 0.5
RECALL_GATE = 0.75
PRECISION_GATE = 0.85
NEGATIVE_FP_PER_PAGE_GATE = 0.15
DUPLICATE_RATE_GATE = 0.05
ANCHOR_DIAG_RATIO = 0.15
ANCHOR_MIN_PX = 8.0


def _prediction_parts(data) -> tuple[list[dict], list[str]]:
    if not isinstance(data, dict):
        return [], ["prediction 顶层不是对象"]
    parts = data.get("parts")
    if not isinstance(parts, list):
        return [], ["prediction.parts 不是数组"]
    if not parts:
        return [], []

    is_sidecar = all(isinstance(p, dict) and "kind" in p for p in parts)
    if is_sidecar:
        errors = validate_sidecar(data)
        if errors:
            return [], errors
        return (
            [
                {
                    "polygon": np.asarray(p["polygon"], dtype=np.float64),
                    "anchor": (float(p["anchor"]["x"]), float(p["anchor"]["y"])),
                }
                for p in parts
            ],
            [],
        )

    errors = []
    if data.get("version") != 1:
        errors.append("draft.version 必须是 1")
    out = []
    for index, part in enumerate(parts):
        if not isinstance(part, dict):
            errors.append(f"draft.parts[{index}] 不是对象")
            continue
        polygon = part.get("polygon")
        errors.extend(
            f"draft.parts[{index}].polygon: {e}" for e in validate_polygon(polygon)
        )
        anchor = part.get("anchor")
        anchor_xy = None
        if anchor is not None:
            if not isinstance(anchor, dict):
                errors.append(f"draft.parts[{index}].anchor 不是对象")
            else:
                x, y = anchor.get("x"), anchor.get("y")
                if not isinstance(x, (int, float)) or not isinstance(y, (int, float)):
                    errors.append(f"draft.parts[{index}].anchor 缺少数值 x/y")
                elif not (0 <= x <= 1 and 0 <= y <= 1):
                    errors.append(f"draft.parts[{index}].anchor 坐标必须在 0..1")
                else:
                    anchor_xy = (float(x), float(y))
        if not errors:
            out.append(
                {
                    "polygon": np.asarray(polygon, dtype=np.float64),
                    "anchor": anchor_xy,
                }
            )
    return ([], errors) if errors else (out, [])


def _lookup_prediction(predictions: dict, page: str):
    if page in predictions:
        return predictions[page]
    stem = page.rsplit(".", 1)[0]
    for key in (stem, f"{stem}.json"):
        if key in predictions:
            return predictions[key]
    return None


def _match(
    pred_polys: list[np.ndarray], gt_polys: list[np.ndarray]
) -> list[tuple[int, int, float]]:
    candidates = []
    for pi, pred in enumerate(pred_polys):
        for gi, gt in enumerate(gt_polys):
            iou = polygon_iou(pred, gt)
            if iou >= MATCH_IOU:
                candidates.append((iou, pi, gi))
    candidates.sort(key=lambda item: (-item[0], item[1], item[2]))
    used_pred: set[int] = set()
    used_gt: set[int] = set()
    matches = []
    for iou, pi, gi in candidates:
        if pi in used_pred or gi in used_gt:
            continue
        used_pred.add(pi)
        used_gt.add(gi)
        matches.append((pi, gi, iou))
    return matches


def _bbox_diagonal(polygon: np.ndarray, width: int, height: int) -> float:
    xs = polygon[:, 0] * width
    ys = polygon[:, 1] * height
    return float(math.hypot(xs.max() - xs.min(), ys.max() - ys.min()))


def _gate(value, threshold, comparator: str, **extra) -> dict:
    passed = value >= threshold if comparator == ">=" else value <= threshold
    return {"value": value, "threshold": threshold, "pass": bool(passed), **extra}


def score_corpus(
    annotations: list[dict],
    predictions: dict[str, dict],
    require_anchors: bool = False,
) -> dict:
    tp = fp = fn = negative_pages = negative_fp = duplicates = 0
    eligible_hands = 0
    seg_ious: list[float] = []
    anchor_errors: list[dict] = []
    errors: list[str] = []
    per_page: list[dict] = []

    for annotation in annotations:
        page = annotation["page"]
        width = int(annotation["width"])
        height = int(annotation["height"])
        gt_hands = annotation.get("hands", [])
        gt_polys = [np.asarray(h["polygon"], dtype=np.float64) for h in gt_hands]
        eligible = [polygon_area(poly) >= MIN_HAND_AREA for poly in gt_polys]
        eligible_hands += sum(eligible)
        is_negative = len(gt_hands) == 0
        if is_negative:
            negative_pages += 1

        pred_data = _lookup_prediction(predictions, page)
        pred_parts, pred_errors = (
            _prediction_parts(pred_data) if pred_data is not None else ([], [])
        )
        if pred_errors:
            errors.extend(f"{page}: {e}" for e in pred_errors)
            pred_parts = []
        pred_polys = [p["polygon"] for p in pred_parts]

        matches = _match(pred_polys, gt_polys)
        matched_pred = {pi for pi, _gi, _iou in matches}
        matched_gt = {gi for _pi, gi, _iou in matches}

        page_tp = page_fp = page_fn = 0
        tp_pred_indices = set()
        for pi, gi, iou in matches:
            if eligible[gi]:
                tp += 1
                page_tp += 1
                tp_pred_indices.add(pi)
                seg_ious.append(float(iou))
                gt = gt_hands[gi]
                wrist = gt.get("wrist")
                anchor = pred_parts[pi]["anchor"]
                if wrist is not None and anchor is not None:
                    diag = _bbox_diagonal(gt_polys[gi], width, height)
                    err_px = float(
                        math.hypot(
                            (anchor[0] - float(wrist[0])) * width,
                            (anchor[1] - float(wrist[1])) * height,
                        )
                    )
                    allowed = max(ANCHOR_DIAG_RATIO * diag, ANCHOR_MIN_PX)
                    anchor_errors.append(
                        {
                            "page": page,
                            "part": pi,
                            "error_px": err_px,
                            "diag_px": diag,
                            "error_diag": err_px / diag if diag > 0 else float("inf"),
                            "allowed_px": allowed,
                            "pass": bool(err_px <= allowed),
                        }
                    )

        unmatched_pred = [pi for pi in range(len(pred_parts)) if pi not in matched_pred]
        fp += len(unmatched_pred)
        page_fp = len(unmatched_pred)
        if is_negative:
            negative_fp += len(pred_parts)

        for pi in unmatched_pred:
            if any(
                polygon_iou(pred_polys[pi], pred_polys[tp_i]) >= MATCH_IOU
                for tp_i in tp_pred_indices
            ):
                duplicates += 1

        for gi, is_eligible in enumerate(eligible):
            if is_eligible and gi not in matched_gt:
                fn += 1
                page_fn += 1

        per_page.append(
            {
                "page": page,
                "eligible_hands": int(sum(eligible)),
                "predictions": len(pred_parts),
                "tp": page_tp,
                "fp": page_fp,
                "fn": page_fn,
                "negative": is_negative,
            }
        )

    recall = tp / eligible_hands if eligible_hands else 1.0
    precision = tp / (tp + fp) if tp + fp else 0.0
    negative_fp_per_page = negative_fp / negative_pages if negative_pages else 0.0
    duplicate_rate = duplicates / max(1, tp)
    seg_median = statistics.median(seg_ious) if seg_ious else 0.0
    seg_fraction = (
        sum(1 for iou in seg_ious if iou >= SEG_FRACTION_IOU) / len(seg_ious)
        if seg_ious
        else 0.0
    )
    anchor_scored = bool(anchor_errors)
    anchor_pass_rate = (
        sum(1 for item in anchor_errors if item["pass"]) / len(anchor_errors)
        if anchor_errors
        else 0.0
    )

    if require_anchors:
        anchor_gate = {
            "value": anchor_pass_rate,
            "threshold": 1.0,
            "pass": bool(
                anchor_pass_rate >= 1.0 and len(anchor_errors) == tp
            ),
            "scored": True,
        }
    else:
        anchor_gate = {
            "value": anchor_pass_rate if anchor_scored else None,
            "threshold": None,
            "pass": True,
            "scored": anchor_scored,
        }

    gates = {
        "schema_valid": {
            "value": len(errors),
            "threshold": 0,
            "pass": not errors,
        },
        "recall": _gate(recall, RECALL_GATE, ">="),
        "precision": _gate(precision, PRECISION_GATE, ">="),
        "negative_fp": _gate(
            negative_fp_per_page, NEGATIVE_FP_PER_PAGE_GATE, "<=", count=negative_fp
        ),
        "duplicate_rate": _gate(duplicate_rate, DUPLICATE_RATE_GATE, "<="),
        "seg_median_iou": _gate(seg_median, SEG_MEDIAN_GATE, ">="),
        "seg_frac_iou_ge_0_5": _gate(seg_fraction, SEG_FRACTION_GATE, ">="),
        "anchor_pass_rate": anchor_gate,
    }

    return {
        "summary": {
            "pages": len(annotations),
            "negative_pages": negative_pages,
            "eligible_hands": eligible_hands,
            "predictions": tp + fp,
            "tp": tp,
            "fp": fp,
            "fn": fn,
            "negative_fp": negative_fp,
            "negative_fp_per_page": negative_fp_per_page,
            "duplicates": duplicates,
            "duplicate_rate": duplicate_rate,
            "recall": recall,
            "precision": precision,
            "seg_median_iou": seg_median,
            "seg_frac_iou_ge_0_5": seg_fraction,
            "anchor_scored": anchor_scored,
            "anchor_pass_rate": anchor_pass_rate,
            "anchor_errors": anchor_errors,
        },
        "gates": gates,
        "passed": all(gate["pass"] for gate in gates.values()),
        "per_page": per_page,
        "errors": errors,
    }
