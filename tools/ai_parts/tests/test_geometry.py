import numpy as np
import pytest

from ai_parts.geometry import (
    decode_yolo,
    letterbox,
    map_model_box_to_page,
    mask_to_polygon,
    nms,
    polygon_area,
    polygon_contains,
    polygon_iou,
)


def test_letterbox_landscape_maps_page_box_roundtrip():
    image = np.zeros((720, 1280, 3), dtype=np.uint8)
    canvas, params = letterbox(image, size=640)

    assert canvas.shape == (640, 640, 3)
    assert params.scale == pytest.approx(0.5)
    assert params.pad_x == 0
    assert params.pad_y == 140

    page_box = np.array([100.0, 200.0, 300.0, 400.0])
    model_box = page_box * params.scale + np.array(
        [params.pad_x, params.pad_y, params.pad_x, params.pad_y]
    )
    mapped = map_model_box_to_page(model_box, params)

    np.testing.assert_allclose(mapped, page_box, atol=1e-6)


def test_letterbox_portrait_counts_padding_before_rounding():
    image = np.zeros((900, 638, 3), dtype=np.uint8)
    canvas, params = letterbox(image, size=640)

    assert canvas.shape == (640, 640, 3)
    assert params.scale == pytest.approx(640 / 900)
    assert params.pad_x == (640 - round(638 * params.scale)) // 2
    assert params.pad_y == 0


def _raw_two_layouts():
    row = np.array([320.0, 320.0, 64.0, 64.0, 0.9], dtype=np.float32)
    low = np.array([100.0, 100.0, 20.0, 20.0, 0.1], dtype=np.float32)
    rows = np.stack([row, low])
    return rows[None, :, :].transpose(0, 2, 1), rows[None, :, :]


def test_decode_yolo_accepts_both_layouts_and_maps_boxes():
    image = np.zeros((720, 1280, 3), dtype=np.uint8)
    _, params = letterbox(image, size=640)
    raw_channels_first, raw_rows = _raw_two_layouts()

    a = decode_yolo(raw_channels_first, conf=0.395, params=params)
    b = decode_yolo(raw_rows, conf=0.395, params=params)

    assert len(a) == 1
    assert len(b) == 1
    np.testing.assert_allclose(a[0].box, [576.0, 296.0, 704.0, 424.0], atol=1e-5)
    assert a[0].score == pytest.approx(0.9)
    np.testing.assert_allclose(a[0].box, b[0].box)


def test_nms_keeps_highest_scoring_overlapping_box():
    boxes = np.array(
        [
            [0.0, 0.0, 10.0, 10.0],
            [1.0, 1.0, 11.0, 11.0],
            [50.0, 50.0, 60.0, 60.0],
        ]
    )
    scores = np.array([0.6, 0.9, 0.5])
    keep = nms(boxes, scores, iou_thr=0.5)
    assert keep == [1, 2]


def test_mask_to_polygon_returns_normalized_polygon_and_contains_point():
    mask = np.zeros((100, 120), dtype=bool)
    mask[20:80, 10:70] = True

    poly = mask_to_polygon(mask)
    assert poly is not None
    assert len(poly) == 4
    assert np.all(poly >= 0.0) and np.all(poly <= 1.0)
    assert polygon_area(poly) == pytest.approx((60 / 120) * (60 / 100), abs=0.01)
    assert polygon_contains(poly, (30 / 120, 50 / 100))


def test_mask_to_polygon_returns_none_for_empty_mask():
    assert mask_to_polygon(np.zeros((10, 10), dtype=bool)) is None


def test_polygon_iou_known_values():
    unit = [[0.0, 0.0], [1.0, 0.0], [1.0, 1.0], [0.0, 1.0]]
    shifted = [[0.5, 0.0], [1.0, 0.0], [1.0, 1.0], [0.5, 1.0]]

    assert polygon_iou(unit, unit) == pytest.approx(1.0)
    assert polygon_iou(unit, [[2, 2], [3, 2], [3, 3], [2, 3]]) == 0.0
    assert polygon_iou(unit, shifted) == pytest.approx(0.5, abs=0.02)
