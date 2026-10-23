import cv2
import numpy as np

_COLORS = [
    (255, 64, 64),
    (64, 192, 64),
    (64, 128, 255),
    (255, 160, 32),
    (192, 64, 255),
    (32, 200, 200),
    (255, 208, 64),
    (160, 160, 160),
]


def render_overlay(image_rgb, parts, out_path=None):
    image = np.asarray(image_rgb)
    if image.dtype != np.uint8 or image.ndim != 3 or image.shape[2] != 3:
        raise ValueError("image_rgb 必须是 HxWx3 的 uint8 数组")
    out = image.copy()
    height, width = out.shape[:2]
    tint = out.copy()

    polygons = []
    for index, part in enumerate(parts):
        color = _COLORS[(int(part.get("id", index + 1)) - 1) % len(_COLORS)]
        points = np.asarray(part["polygon"], dtype=np.float64)
        pixels = np.column_stack(
            [points[:, 0] * width, points[:, 1] * height]
        ).astype(np.int32)
        polygons.append((part, color, pixels))
        cv2.fillPoly(tint, [pixels], color)

    cv2.addWeighted(tint, 0.35, out, 0.65, 0, dst=out)

    for part, color, pixels in polygons:
        cv2.polylines(out, [pixels], True, color, 2, lineType=cv2.LINE_AA)
        label = f"#{part.get('id', '?')} {float(part.get('score', 0.0)):.2f}"
        x = int(pixels[:, 0].min())
        y = max(14, int(pixels[:, 1].min()) - 6)
        cv2.putText(
            out, label, (x, y), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 0, 0), 3, cv2.LINE_AA
        )
        cv2.putText(
            out, label, (x, y), cv2.FONT_HERSHEY_SIMPLEX, 0.5, color, 1, cv2.LINE_AA
        )
        anchor = part.get("anchor")
        if isinstance(anchor, dict) and "x" in anchor and "y" in anchor:
            center = (
                int(round(float(anchor["x"]) * width)),
                int(round(float(anchor["y"]) * height)),
            )
            cv2.circle(out, center, 5, color, -1, lineType=cv2.LINE_AA)
            cv2.circle(out, center, 6, (0, 0, 0), 1, lineType=cv2.LINE_AA)

    if out_path is not None:
        if not cv2.imwrite(str(out_path), cv2.cvtColor(out, cv2.COLOR_RGB2BGR)):
            raise OSError(f"无法写入叠加图：{out_path}")
    return out
