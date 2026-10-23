from .sidecar import MAX_PARTS, build_draft


def run_page(image, page_name, detector, segmenter, models):
    detections = detector.detect(image)
    detections = segmenter.segment(image, detections) if detections else []
    usable = [det for det in detections if det.polygon is not None]
    usable.sort(key=lambda det: -det.score)
    usable = usable[:MAX_PARTS]
    height, width = image.shape[:2]
    return build_draft(page_name, int(width), int(height), models, usable)
