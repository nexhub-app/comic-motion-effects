import numpy as np

from .geometry import decode_yolo, letterbox, mask_to_polygon, nms
from .types import Detection


class OnnxHandDetector:
    def __init__(self, session, conf=0.395, nms_iou=0.5, input_size=640):
        self.session = session
        self.conf = float(conf)
        self.nms_iou = float(nms_iou)
        self.input_size = int(input_size)

    @classmethod
    def load(cls, path, **kwargs):
        import onnxruntime as ort

        session = ort.InferenceSession(
            str(path), providers=["CPUExecutionProvider"]
        )
        return cls(session, **kwargs)

    def detect(self, image):
        canvas, params = letterbox(image, self.input_size)
        blob = canvas.astype(np.float32) / 255.0
        blob = np.transpose(blob, (2, 0, 1))[None]
        input_name = self.session.get_inputs()[0].name
        raw = self.session.run(None, {input_name: blob})[0]
        detections = decode_yolo(raw, self.conf, params)
        if not detections:
            return []
        boxes = np.stack([det.box for det in detections])
        scores = np.asarray([det.score for det in detections])
        keep = nms(boxes, scores, self.nms_iou)
        return [detections[index] for index in keep]


class HandSegNetSegmenter:
    def __init__(self, predictor, box_pad=0.03):
        self.predictor = predictor
        self.box_pad = float(box_pad)

    @classmethod
    def load(cls, path, device="cpu", **kwargs):
        import torch
        from safetensors.torch import load_file
        from segment_anything import SamPredictor, sam_model_registry

        sam = sam_model_registry["vit_b"](checkpoint=None)
        sam.load_state_dict(load_file(str(path)))
        sam.to(device)
        sam.eval()
        return cls(SamPredictor(sam), **kwargs)

    def segment(self, image, detections):
        if not detections:
            return []
        if image.dtype != np.uint8 or image.ndim != 3 or image.shape[2] != 3:
            raise ValueError("segmenter 需要 HxWx3 的 uint8 RGB 图像")
        height, width = image.shape[:2]
        self.predictor.set_image(image)

        results = []
        for det in detections:
            x1, y1, x2, y2 = (float(v) for v in det.box)
            pad = self.box_pad * max(x2 - x1, y2 - y1)
            box = np.asarray(
                [
                    max(0.0, x1 - pad),
                    max(0.0, y1 - pad),
                    min(width - 1.0, x2 + pad),
                    min(height - 1.0, y2 + pad),
                ],
                dtype=np.float64,
            )
            masks, _scores, _low = self.predictor.predict(
                box=box, multimask_output=False
            )
            mask = np.asarray(masks[0]).astype(bool)
            results.append(
                Detection(
                    score=det.score,
                    box=det.box,
                    polygon=mask_to_polygon(mask),
                    mask_area_ratio=float(mask.mean()),
                )
            )
        return results
