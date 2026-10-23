import numpy as np

from ai_parts.adapters import HandSegNetSegmenter, OnnxHandDetector
from ai_parts.types import Detection


class FakeInput:
    name = "images"


class FakeSession:
    def __init__(self, output):
        self.output = output
        self.feed = None

    def get_inputs(self):
        return [FakeInput()]

    def run(self, _outputs, feed):
        self.feed = feed
        return [self.output]


def _raw(rows):
    return np.asarray([rows], dtype=np.float32)


def test_detector_maps_letterbox_boxes_and_applies_nms():
    raw = _raw(
        [
            [320, 320, 128, 192, 0.9],
            [321, 321, 128, 192, 0.8],
            [100, 100, 64, 64, 0.1],
        ]
    )
    session = FakeSession(raw)
    detector = OnnxHandDetector(session, conf=0.395)

    image = np.empty((1000, 1000, 3), dtype=np.uint8)
    image[:, :] = (255, 0, 0)
    detections = detector.detect(image)

    assert len(detections) == 1
    np.testing.assert_allclose(detections[0].box, [400, 350, 600, 650], atol=1e-4)
    assert abs(detections[0].score - 0.9) < 1e-6
    blob = session.feed["images"]
    assert blob.shape == (1, 3, 640, 640)
    assert blob.dtype == np.float32
    assert blob[0, 0, 0, 0] > 0.9
    assert blob[0, 1, 0, 0] < 0.1
    assert blob[0, 2, 0, 0] < 0.1


def test_detector_returns_empty_without_rows_above_threshold():
    detector = OnnxHandDetector(FakeSession(_raw([[320, 320, 100, 100, 0.01]])))
    assert detector.detect(np.zeros((100, 100, 3), np.uint8)) == []


class FakePredictor:
    def __init__(self, masks):
        self.masks = masks
        self.images = []
        self.boxes = []

    def set_image(self, image):
        self.images.append(image)

    def predict(self, box, multimask_output=False):
        self.boxes.append(np.asarray(box, dtype=np.float64))
        assert multimask_output is False
        mask, score = self.masks[len(self.boxes) - 1]
        return np.asarray([mask]), np.asarray([score]), None


def _square_mask(size=100, lo=20, hi=60):
    mask = np.zeros((size, size), dtype=np.uint8)
    mask[lo:hi, lo:hi] = 1
    return mask


def test_segmenter_pads_box_and_returns_polygon_and_ratio():
    predictor = FakePredictor([(_square_mask(), 0.97)])
    segmenter = HandSegNetSegmenter(predictor)
    image = np.zeros((100, 100, 3), dtype=np.uint8)
    detections = [Detection(score=0.8, box=np.array([10, 10, 50, 50], float))]

    out = segmenter.segment(image, detections)

    assert len(out) == 1
    assert out[0].score == 0.8
    np.testing.assert_allclose(out[0].box, [10, 10, 50, 50])
    assert out[0].polygon is not None
    np.testing.assert_allclose(out[0].polygon.min(axis=0), [20 / 100, 20 / 100], atol=1e-6)
    np.testing.assert_allclose(out[0].polygon.max(axis=0), [59 / 100, 59 / 100], atol=1e-6)
    assert abs(out[0].mask_area_ratio - 0.16) < 1e-6
    np.testing.assert_allclose(predictor.boxes[0], [8.8, 8.8, 51.2, 51.2], atol=1e-4)


def test_segmenter_sets_image_once_and_keeps_empty_masks():
    predictor = FakePredictor([(_square_mask(), 0.9), (np.zeros((100, 100), np.uint8), 0.1)])
    segmenter = HandSegNetSegmenter(predictor)
    image = np.zeros((100, 100, 3), dtype=np.uint8)
    detections = [
        Detection(score=0.8, box=np.array([10, 10, 50, 50], float)),
        Detection(score=0.7, box=np.array([60, 60, 90, 90], float)),
    ]

    out = segmenter.segment(image, detections)

    assert len(predictor.images) == 1
    assert len(out) == 2
    assert out[1].polygon is None
    assert out[1].mask_area_ratio == 0.0


def test_segmenter_returns_empty_for_no_detections():
    predictor = FakePredictor([])
    segmenter = HandSegNetSegmenter(predictor)
    assert segmenter.segment(np.zeros((10, 10, 3), np.uint8), []) == []
    assert predictor.images == []
