import hashlib

from ai_parts.config import (
    DETECTOR,
    SEGMENTER,
    default_cache_dir,
    model_path,
    model_url,
    verify_file,
)


def test_model_specs_are_pinned_to_known_hashes():
    assert DETECTOR.sha256 == "408750ad39645fcdc0c5e774aa45a73941b2e785fc5611fb7d3d9790a41899c0"
    assert DETECTOR.size_bytes == 44583229
    assert SEGMENTER.sha256 == "64b35e5ee09aac8737e2554f15e73503f94ce9bf443dde4864255e14b7ca9c14"
    assert SEGMENTER.size_bytes == 374979240


def test_model_url_handles_trailing_slash():
    assert model_url(DETECTOR, "https://hf-mirror.com/") == (
        "https://hf-mirror.com/deepghs/anime_hand_detection/resolve/main/"
        "hand_detect_v1.0_s/model.onnx"
    )


def test_default_cache_dir_respects_environment(monkeypatch, tmp_path):
    monkeypatch.setenv("COMIC_MOTION_AI_CACHE", str(tmp_path))
    assert default_cache_dir() == tmp_path


def test_model_path_keeps_models_separate(tmp_path):
    det = model_path(tmp_path, DETECTOR)
    seg = model_path(tmp_path, SEGMENTER)
    assert det.parent == tmp_path / "models" / "detector"
    assert seg.parent == tmp_path / "models" / "segmenter"
    assert det.name == "model.onnx"


def test_verify_file_checks_size_and_sha(tmp_path):
    data = b"hello"
    path = tmp_path / "x.bin"
    path.write_bytes(data)
    spec = type(DETECTOR)(
        key="test",
        repo="r",
        filename="x.bin",
        size_bytes=len(data),
        sha256=hashlib.sha256(data).hexdigest(),
        license="Apache-2.0",
        license_url="https://example.invalid",
    )
    ok, message = verify_file(path, spec)
    assert ok and message == ""

    path.write_bytes(b"hell0")
    ok, message = verify_file(path, spec)
    assert not ok and "sha256" in message
