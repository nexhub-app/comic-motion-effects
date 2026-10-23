import json

import numpy as np
import pytest

from ai_parts.sidecar import (
    AnchorError,
    DraftError,
    build_draft,
    compose_sidecar,
    dumps_json,
    validate_sidecar,
)
from ai_parts.types import Detection

SQUARE = np.array([[0.1, 0.1], [0.3, 0.1], [0.3, 0.3], [0.1, 0.3]])
SQUARE_2 = np.array([[0.5, 0.5], [0.7, 0.5], [0.7, 0.7], [0.5, 0.7]])


def _det(score=0.9, box=(100, 100, 300, 300), polygon=SQUARE):
    return Detection(score=score, box=np.array(box, dtype=float), polygon=polygon)


def _draft():
    return build_draft(
        page_name="page.png",
        width=1000,
        height=1000,
        models={"detector": "hand_s", "segmenter": "handsegnet"},
        detections=[
            _det(0.9, (100, 100, 300, 300), SQUARE),
            _det(0.8, (500, 500, 700, 700), SQUARE_2),
        ],
    )


def test_build_draft_normalizes_boxes_and_sorts_by_score():
    draft = _draft()

    assert draft["version"] == 1
    assert draft["page"] == "page.png"
    assert draft["width"] == 1000
    assert [p["id"] for p in draft["parts"]] == [1, 2]
    np.testing.assert_allclose(draft["parts"][0]["bbox"], [0.1, 0.1, 0.3, 0.3])
    assert draft["parts"][0]["anchor"] is None
    assert draft["models"]["detector"] == "hand_s"


def test_compose_writes_version1_hand_sidecar_and_is_deterministic():
    out = compose_sidecar(_draft(), {1: (0.2, 0.25), 2: (0.6, 0.65)})

    assert out["version"] == 1
    assert len(out["parts"]) == 2
    part = out["parts"][0]
    assert part["kind"] == "hand"
    assert part["anchor"] == {"x": 0.2, "y": 0.25, "joint": "wrist"}
    assert isinstance(part["polygon"], list)

    again = compose_sidecar(_draft(), {1: (0.2, 0.25), 2: (0.6, 0.65)})
    assert dumps_json(out) == dumps_json(again)
    assert json.loads(dumps_json(out))["parts"][0]["polygon"][0] == [0.1, 0.1]


def test_compose_rejects_missing_anchor_by_default():
    with pytest.raises(AnchorError, match="1, 2"):
        compose_sidecar(_draft(), {})


def test_compose_can_skip_unconfirmed_parts_explicitly():
    out = compose_sidecar(_draft(), {1: (0.2, 0.25)}, allow_skip=True)
    assert len(out["parts"]) == 1


def test_compose_rejects_anchor_outside_polygon():
    with pytest.raises(AnchorError, match="part 1"):
        compose_sidecar(_draft(), {1: (0.5, 0.5), 2: (0.6, 0.65)})


def test_compose_rejects_more_than_eight_parts():
    draft = _draft()
    draft["parts"] = draft["parts"] * 5
    for i, part in enumerate(draft["parts"], start=1):
        part["id"] = i
    anchors = {i: (0.2, 0.2) for i in range(1, 11)}
    with pytest.raises(DraftError, match="8"):
        compose_sidecar(draft, anchors)


def test_compose_rejects_invalid_polygon():
    draft = _draft()
    draft["parts"][0]["polygon"] = [[0.1, 0.1], [0.2, 0.2]]
    with pytest.raises(DraftError, match="polygon"):
        compose_sidecar(draft, {1: (0.15, 0.15), 2: (0.6, 0.65)})


def test_validate_sidecar_reports_anchor_and_polygon_errors():
    bad = {
        "version": 1,
        "parts": [
            {
                "kind": "hand",
                "polygon": [[0.1, 0.1], [0.3, 0.1], [0.3, 0.3]],
                "anchor": {"x": 0.9, "y": 0.9, "joint": "wrist"},
            }
        ],
    }
    errors = validate_sidecar(bad)
    assert any("inside" in e for e in errors)

    bad["parts"][0]["anchor"] = {"x": 0.2, "y": 0.2, "joint": "wrist"}
    bad["parts"][0]["polygon"] = [[0.1, 0.1], [1.2, 0.1], [0.3, 0.3]]
    errors = validate_sidecar(bad)
    assert any("0..1" in e for e in errors)


def test_validate_sidecar_accepts_composed_output():
    out = compose_sidecar(_draft(), {1: (0.2, 0.25), 2: (0.6, 0.65)})
    assert validate_sidecar(out) == []
