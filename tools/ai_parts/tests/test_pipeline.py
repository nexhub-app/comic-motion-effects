import numpy as np

from ai_parts.pipeline import run_page
from ai_parts.types import Detection

SQUARE = np.array([[0.1, 0.1], [0.3, 0.1], [0.3, 0.3], [0.1, 0.3]])


class FakeDetector:
    def __init__(self, detections):
        self.detections = detections

    def detect(self, image):
        return self.detections


class FakeSegmenter:
    def __init__(self, empty_indices=()):
        self.empty_indices = set(empty_indices)

    def segment(self, image, detections):
        out = []
        for index, det in enumerate(detections):
            poly = None if index in self.empty_indices else SQUARE
            out.append(
                Detection(
                    score=det.score,
                    box=det.box,
                    polygon=poly,
                    mask_area_ratio=0.0 if poly is None else 0.05,
                )
            )
        return out


def _detections(n):
    return [
        Detection(score=0.5 + i / 100, box=np.array([100, 100, 300, 300], float))
        for i in range(n)
    ]


def test_run_page_filters_empty_masks_sorts_and_assigns_ids():
    detections = _detections(3)
    draft = run_page(
        image=np.zeros((1000, 1000, 3), np.uint8),
        page_name="p.png",
        detector=FakeDetector(detections),
        segmenter=FakeSegmenter(empty_indices={1}),
        models={"detector": "fake", "segmenter": "fake"},
    )

    assert [part["id"] for part in draft["parts"]] == [1, 2]
    assert draft["parts"][0]["score"] > draft["parts"][1]["score"]
    assert draft["page"] == "p.png"


def test_run_page_caps_parts_at_eight():
    draft = run_page(
        image=np.zeros((1000, 1000, 3), np.uint8),
        page_name="p.png",
        detector=FakeDetector(_detections(10)),
        segmenter=FakeSegmenter(),
        models={"detector": "fake", "segmenter": "fake"},
    )
    assert len(draft["parts"]) == 8


def test_run_page_returns_empty_draft_without_detections():
    draft = run_page(
        image=np.zeros((10, 10, 3), np.uint8),
        page_name="p.png",
        detector=FakeDetector([]),
        segmenter=FakeSegmenter(),
        models={"detector": "fake", "segmenter": "fake"},
    )
    assert draft["parts"] == []
