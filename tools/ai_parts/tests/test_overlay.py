import cv2
import numpy as np

from ai_parts.overlay import render_overlay


def test_render_overlay_draws_parts_and_writes_png(tmp_path):
    image = np.full((100, 120, 3), 255, dtype=np.uint8)
    parts = [
        {
            "id": 1,
            "score": 0.9,
            "polygon": [[0.1, 0.1], [0.5, 0.1], [0.5, 0.5], [0.1, 0.5]],
        }
    ]
    out_path = tmp_path / "preview.png"

    out = render_overlay(image, parts, out_path=out_path)

    assert out.shape == image.shape
    assert out.dtype == np.uint8
    assert not np.array_equal(out, image)
    written = cv2.imread(str(out_path))
    assert written is not None
    assert written.shape == image.shape
