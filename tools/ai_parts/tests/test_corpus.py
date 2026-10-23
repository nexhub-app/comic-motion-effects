import json

import pytest

from ai_parts.corpus import load_annotations, load_predictions, strip_suffix


def _write(path, data):
    path.write_text(json.dumps(data), encoding="utf-8")


def test_load_annotations_reads_and_sorts(tmp_path):
    _write(
        tmp_path / "b.json",
        {
            "page": "b.png",
            "width": 100,
            "height": 200,
            "hands": [{"polygon": [[0, 0], [1, 0], [1, 1]], "wrist": [0.5, 0.5]}],
        },
    )
    _write(tmp_path / "a.json", {"page": "a.png", "width": 100, "height": 200, "hands": []})

    annotations = load_annotations(tmp_path)

    assert [item["page"] for item in annotations] == ["a.png", "b.png"]
    assert annotations[1]["hands"][0]["wrist"] == [0.5, 0.5]


def test_load_annotations_rejects_missing_fields(tmp_path):
    _write(tmp_path / "a.json", {"page": "a.png", "hands": []})
    with pytest.raises(ValueError, match="width"):
        load_annotations(tmp_path)


def test_load_predictions_prefers_composed_sidecar(tmp_path):
    _write(tmp_path / "a.draft.json", {"version": 1, "parts": [{"id": 99}]})
    _write(tmp_path / "a.part_motion.json", {"version": 1, "parts": []})
    _write(tmp_path / "b.draft.json", {"version": 1, "parts": [{"id": 2}]})

    predictions = load_predictions(tmp_path)

    assert predictions["a"]["parts"] == []
    assert predictions["b"]["parts"] == [{"id": 2}]


def test_strip_suffix_handles_both_prediction_kinds():
    assert strip_suffix("ch01-01.part_motion.json") == "ch01-01"
    assert strip_suffix("ch01-01.draft.json") == "ch01-01"
    assert strip_suffix("other.json") == "other"


def test_load_annotations_rejects_bad_polygon(tmp_path):
    _write(
        tmp_path / "a.json",
        {
            "page": "a.png",
            "width": 100,
            "height": 100,
            "hands": [{"polygon": [[0, 0], [1, 0]], "wrist": [0.5, 0.5]}],
        },
    )
    with pytest.raises(ValueError, match="polygon"):
        load_annotations(tmp_path)


def test_load_annotations_rejects_wrist_outside_polygon(tmp_path):
    _write(
        tmp_path / "a.json",
        {
            "page": "a.png",
            "width": 100,
            "height": 100,
            "hands": [
                {
                    "polygon": [[0.1, 0.1], [0.3, 0.1], [0.3, 0.3], [0.1, 0.3]],
                    "wrist": [0.9, 0.9],
                }
            ],
        },
    )
    with pytest.raises(ValueError, match="wrist"):
        load_annotations(tmp_path)


def test_load_annotations_rejects_duplicate_pages(tmp_path):
    for name in ("a.json", "b.json"):
        _write(
            tmp_path / name,
            {"page": "same.png", "width": 100, "height": 100, "hands": []},
        )
    with pytest.raises(ValueError, match="重复"):
        load_annotations(tmp_path)
