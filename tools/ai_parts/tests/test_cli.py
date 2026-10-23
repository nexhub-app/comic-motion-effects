import json

import cv2
import numpy as np

from ai_parts import cli
from ai_parts.review import build_review_html
from ai_parts.sidecar import load_json, validate_sidecar
from ai_parts.types import Detection

SQUARE = np.array([[0.1, 0.1], [0.5, 0.1], [0.5, 0.5], [0.1, 0.5]])


class FakeDetector:
    def detect(self, image):
        return [Detection(score=0.9, box=np.array([10, 10, 50, 50], float))]


class FakeSegmenter:
    def segment(self, image, detections):
        return [
            Detection(score=det.score, box=det.box, polygon=SQUARE, mask_area_ratio=0.16)
            for det in detections
        ]


def _draft(path):
    data = {
        "version": 1,
        "page": "p.png",
        "width": 100,
        "height": 100,
        "models": {"detector": "fake", "segmenter": "fake"},
        "parts": [
            {
                "id": 1,
                "score": 0.9,
                "bbox": [0.1, 0.1, 0.5, 0.5],
                "polygon": SQUARE.tolist(),
                "anchor": None,
            }
        ],
    }
    path.write_text(json.dumps(data), encoding="utf-8")
    return data


def test_detect_writes_draft_and_overlay(tmp_path, monkeypatch):
    image_path = tmp_path / "p.png"
    cv2.imwrite(str(image_path), np.full((100, 100, 3), 255, np.uint8))
    out_dir = tmp_path / "out"
    monkeypatch.setattr(
        cli, "_load_models", lambda cache, conf: (FakeDetector(), FakeSegmenter())
    )

    code = cli.main(["detect", str(image_path), "--out", str(out_dir)])

    assert code == 0
    draft = load_json(out_dir / "p.draft.json")
    assert draft["page"] == "p.png"
    assert len(draft["parts"]) == 1
    assert draft["parts"][0]["polygon"] is not None
    assert (out_dir / "p.overlay.png").is_file()


def test_compose_writes_valid_sidecar(tmp_path):
    draft_path = tmp_path / "p.draft.json"
    _draft(draft_path)
    anchors_path = tmp_path / "anchors.json"
    anchors_path.write_text(json.dumps({"1": [0.2, 0.2]}), encoding="utf-8")
    out_path = tmp_path / "p.part_motion.json"

    code = cli.main(
        ["compose", str(draft_path), "--anchors", str(anchors_path), "-o", str(out_path)]
    )

    assert code == 0
    sidecar = load_json(out_path)
    assert validate_sidecar(sidecar) == []
    assert sidecar["parts"][0]["anchor"] == {"x": 0.2, "y": 0.2, "joint": "wrist"}


def test_compose_without_anchor_fails(tmp_path, capsys):
    draft_path = tmp_path / "p.draft.json"
    _draft(draft_path)
    anchors_path = tmp_path / "anchors.json"
    anchors_path.write_text("{}", encoding="utf-8")
    out_path = tmp_path / "p.part_motion.json"

    code = cli.main(
        ["compose", str(draft_path), "--anchors", str(anchors_path), "-o", str(out_path)]
    )

    assert code != 0
    assert "anchor" in capsys.readouterr().err.lower()
    assert not out_path.exists()


def _annotation(path, page, hands):
    path.write_text(
        json.dumps({"page": page, "width": 100, "height": 100, "hands": hands}),
        encoding="utf-8",
    )


def test_score_passes_and_writes_report(tmp_path, capsys):
    annotations = tmp_path / "gt"
    predictions = tmp_path / "pred"
    annotations.mkdir()
    predictions.mkdir()
    _annotation(
        annotations / "p.json",
        "p.png",
        [{"polygon": SQUARE.tolist(), "wrist": [0.2, 0.2]}],
    )
    (predictions / "p.part_motion.json").write_text(
        json.dumps(
            {
                "version": 1,
                "parts": [
                    {
                        "kind": "hand",
                        "polygon": SQUARE.tolist(),
                        "anchor": {"x": 0.2, "y": 0.2, "joint": "wrist"},
                    }
                ],
            }
        ),
        encoding="utf-8",
    )
    report_path = tmp_path / "report.json"

    code = cli.main(
        [
            "score",
            str(annotations),
            str(predictions),
            "--require-anchors",
            "-o",
            str(report_path),
        ]
    )

    assert code == 0
    report = load_json(report_path)
    assert report["passed"] is True
    assert report["summary"]["tp"] == 1
    assert "passed" in capsys.readouterr().out


def test_score_returns_nonzero_when_gates_fail(tmp_path):
    annotations = tmp_path / "gt"
    predictions = tmp_path / "pred"
    annotations.mkdir()
    predictions.mkdir()
    _annotation(annotations / "p.json", "p.png", [{"polygon": SQUARE.tolist(), "wrist": [0.2, 0.2]}])

    code = cli.main(["score", str(annotations), str(predictions)])

    assert code == 1


def test_review_writes_html_gallery(tmp_path):
    drafts = tmp_path / "drafts"
    images = tmp_path / "images"
    drafts.mkdir()
    images.mkdir()
    draft = _draft(drafts / "p.draft.json")
    cv2.imwrite(str(images / "p.png"), np.full((100, 100, 3), 255, np.uint8))
    out_path = tmp_path / "review.html"

    code = cli.main(
        [
            "review",
            str(drafts),
            str(images),
            "-o",
            str(out_path),
            "--title",
            "验收初审",
        ]
    )

    assert code == 0
    html = out_path.read_text(encoding="utf-8")
    assert "验收初审" in html
    assert "p.png" in html
    assert '"score": 0.9' in html
    assert draft["parts"][0]["polygon"][0][0] == 0.1


def test_review_falls_back_to_file_uri_across_drives(tmp_path, monkeypatch):
    drafts = tmp_path / "drafts"
    images = tmp_path / "images"
    drafts.mkdir()
    images.mkdir()
    _draft(drafts / "p.draft.json")
    cv2.imwrite(str(images / "p.png"), np.full((100, 100, 3), 255, np.uint8))

    def cross_drive(*_args, **_kwargs):
        raise ValueError("path is on mount 'E:', start on mount 'C:'")

    monkeypatch.setattr("ai_parts.review.os.path.relpath", cross_drive)
    out_path = tmp_path / "review.html"

    build_review_html(drafts, images, out_path)

    assert "file:///" in out_path.read_text(encoding="utf-8")
