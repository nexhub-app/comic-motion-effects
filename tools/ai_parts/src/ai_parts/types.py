from dataclasses import dataclass

import numpy as np


@dataclass
class Detection:
    """A hand detection in page pixel coordinates."""

    score: float
    box: np.ndarray
    polygon: np.ndarray | None = None
    mask_area_ratio: float | None = None
