import copy

import numpy as np
import pytest

from ai_parts.metrics import score_corpus
from ai_parts.sidecar import build_draft, compose_sidecar
from ai_parts.types import Detection

SQUARE = [[0.1, 0.1], [0.3, 0.1], [0.3, 0.3], [0.1, 0.3]]
SQUARE_2 = [[0.5, 0.5], [0.7, 0.5], [0.7, 0.7], [0.5, 0.7]]


def _ann(page, hands, width=1000, height=1000):
    return {"page": page, "width": width, "height": height, "hands": hands}


def _hand(polygon, wrist):
    return {"polygon": polygon, "wrist": wrist, "occluded": False}


def _pred(page, items, width=1000, height=1000, anchors=True):
    detections = [
        Detection(
            score=0.9 - i * 0.1,
            box=np.array([100, 100, 300, 300], dtype=float),
            polygon=np.asarray(poly, dtype=float),
        )
        for i, (poly, _wrist) in enumerate(items)
    ]
    draft = build_draft(page, width, height, {"detector": "test"}, detections)
    if not anchors:
        return draft
    anchor_map = {i + 1: wrist for i, (_poly, wrist) in enumerate(items)}
    return compose_sidecar(draft, anchor_map)


def test_perfect_predictions_pass_all_gates():
    anns = [
        _ann("p1.png", [_hand(SQUARE, (0.2, 0.25)), _hand(SQUARE_2, (0.6, 0.65))]),
        _ann("neg.png", []),
    ]
    preds = {
        "p1.png": _pred(
            "p1.png", [(SQUARE, (0.2, 0.25)), (SQUARE_2, (0.6, 0.65))]
        )
    }

    report = score_corpus(anns, preds, require_anchors=True)

    assert report["summary"]["tp"] == 2
    assert report["summary"]["fn"] == 0
    assert report["gates"]["recall"]["pass"]
    assert report["gates"]["anchor_pass_rate"]["pass"]
    assert report["passed"] is True


def test_missed_hand_fails_recall():
    anns = [_ann("p1.png", [_hand(SQUARE, (0.2, 0.25)), _hand(SQUARE_2, (0.6, 0.65))])]
    preds = {"p1.png": _pred("p1.png", [(SQUARE, (0.2, 0.25))])}

    report = score_corpus(anns, preds, require_anchors=True)

    assert report["summary"]["recall"] == pytest.approx(0.5)
    assert report["gates"]["recall"]["pass"] is False
    assert report["passed"] is False


def test_negative_page_false_positives_fail_gate():
    anns = [_ann(f"neg{i}.png", []) for i in range(3)]
    preds = {
        f"neg{i}.png": _pred(f"neg{i}.png", [(SQUARE, (0.2, 0.25))])
        for i in range(3)
    }

    report = score_corpus(anns, preds)

    assert report["summary"]["negative_fp"] == 3
    assert report["gates"]["negative_fp"]["pass"] is False
    assert report["passed"] is False


def test_duplicate_overlap_is_counted_separately():
    anns = [_ann("p1.png", [_hand(SQUARE, (0.2, 0.25))])]
    preds = {
        "p1.png": _pred(
            "p1.png", [(SQUARE, (0.2, 0.25)), (SQUARE, (0.2, 0.25))]
        )
    }

    report = score_corpus(anns, preds, require_anchors=True)

    assert report["summary"]["tp"] == 1
    assert report["summary"]["fp"] == 1
    assert report["summary"]["duplicate_rate"] == pytest.approx(1.0)
    assert report["gates"]["duplicate_rate"]["pass"] is False


def test_small_hand_is_excluded_from_recall_and_not_penalized_as_fp():
    tiny = [[0.1, 0.1], [0.13, 0.1], [0.13, 0.13], [0.1, 0.13]]  # 0.09% area
    anns = [
        _ann("p1.png", [_hand(SQUARE, (0.2, 0.25)), _hand(tiny, (0.115, 0.125))]),
        _ann("p2.png", [_hand(SQUARE_2, (0.6, 0.65))]),
    ]
    preds = {
        "p1.png": _pred("p1.png", [(tiny, (0.115, 0.125))]),
        "p2.png": _pred("p2.png", [(SQUARE_2, (0.6, 0.65))]),
    }

    report = score_corpus(anns, preds, require_anchors=True)

    assert report["summary"]["eligible_hands"] == 2
    assert report["summary"]["tp"] == 1
    assert report["summary"]["fp"] == 0
    assert report["summary"]["fn"] == 1


def test_anchor_error_uses_bbox_diagonal_with_pixel_floor():
    gt = _ann("p1.png", [_hand(SQUARE, (0.2, 0.25))], width=100, height=100)
    pred = _pred("p1.png", [(SQUARE, (0.25, 0.30))], width=100, height=100)

    report = score_corpus([gt], {"p1.png": pred}, require_anchors=True)

    # 7.07 px error, bbox diagonal 28.28 px: ratio 0.25 but the 8 px floor passes it.
    assert report["summary"]["anchor_errors"][0]["error_px"] == pytest.approx(7.071, abs=0.01)
    assert report["gates"]["anchor_pass_rate"]["pass"] is True

    gt_big = _ann("p1.png", [_hand(SQUARE, (0.2, 0.25))], width=1000, height=1000)
    pred_big = _pred("p1.png", [(SQUARE, (0.29, 0.29))], width=1000, height=1000)
    report_big = score_corpus([gt_big], {"p1.png": pred_big}, require_anchors=True)
    assert report_big["gates"]["anchor_pass_rate"]["pass"] is False


def test_require_anchors_fails_for_unconfirmed_draft():
    anns = [_ann("p1.png", [_hand(SQUARE, (0.2, 0.25))])]
    draft = _pred("p1.png", [(SQUARE, (0.2, 0.25))], anchors=False)

    scored = score_corpus(anns, {"p1.png": draft}, require_anchors=False)
    assert scored["gates"]["anchor_pass_rate"]["scored"] is False
    assert scored["passed"] is True

    required = score_corpus(anns, {"p1.png": draft}, require_anchors=True)
    assert required["gates"]["anchor_pass_rate"]["pass"] is False
    assert required["passed"] is False


def test_invalid_prediction_fails_schema_gate_without_crashing():
    anns = [_ann("p1.png", [_hand(SQUARE, (0.2, 0.25))])]
    bad = _pred("p1.png", [(SQUARE, (0.2, 0.25))])
    bad["parts"][0]["polygon"] = [[0.1, 0.1], [0.3, 0.3]]

    report = score_corpus(anns, {"p1.png": bad}, require_anchors=True)

    assert report["gates"]["schema_valid"]["pass"] is False
    assert report["errors"]


def test_report_is_json_serializable():
    import json

    anns = [_ann("p1.png", [_hand(SQUARE, (0.2, 0.25))])]
    report = score_corpus(anns, {"p1.png": _pred("p1.png", [(SQUARE, (0.2, 0.25))])})
    json.dumps(report, allow_nan=False)
