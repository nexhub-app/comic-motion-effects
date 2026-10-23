import hashlib
import os
import sys
import urllib.request
from dataclasses import dataclass
from pathlib import Path

DEFAULT_ENDPOINT = "https://huggingface.co"
_CHUNK = 1 << 20


class ModelError(RuntimeError):
    pass


@dataclass(frozen=True)
class ModelSpec:
    key: str
    repo: str
    filename: str
    size_bytes: int
    sha256: str
    license: str
    license_url: str


DETECTOR = ModelSpec(
    key="detector",
    repo="deepghs/anime_hand_detection",
    filename="hand_detect_v1.0_s/model.onnx",
    size_bytes=44583229,
    sha256="408750ad39645fcdc0c5e774aa45a73941b2e785fc5611fb7d3d9790a41899c0",
    license="OpenRAIL",
    license_url="https://huggingface.co/deepghs/anime_hand_detection",
)

SEGMENTER = ModelSpec(
    key="segmenter",
    repo="Ov3rLoRd-MLEngineer/handsegnet-anime-sdxl",
    filename="handsegnet_vit_b_best.safetensors",
    size_bytes=374979240,
    sha256="64b35e5ee09aac8737e2554f15e73503f94ce9bf443dde4864255e14b7ca9c14",
    license="Apache-2.0",
    license_url="https://huggingface.co/Ov3rLoRd-MLEngineer/handsegnet-anime-sdxl",
)


def default_endpoint() -> str:
    return os.environ.get("COMIC_MOTION_AI_ENDPOINT", DEFAULT_ENDPOINT)


def model_url(spec: ModelSpec, endpoint: str | None = None) -> str:
    base = (endpoint or default_endpoint()).rstrip("/")
    return f"{base}/{spec.repo}/resolve/main/{spec.filename}"


def default_cache_dir() -> Path:
    env = os.environ.get("COMIC_MOTION_AI_CACHE")
    if env:
        return Path(env)
    if sys.platform == "win32":
        root = Path(os.environ.get("LOCALAPPDATA", Path.home() / "AppData" / "Local"))
    else:
        root = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache"))
    return root / "comic-motion-ai"


def model_path(cache: Path, spec: ModelSpec) -> Path:
    return Path(cache) / "models" / spec.key / Path(spec.filename).name


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(_CHUNK), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_file(path: Path, spec: ModelSpec) -> tuple[bool, str]:
    path = Path(path)
    if not path.is_file():
        return False, f"文件不存在：{path}"
    actual_size = path.stat().st_size
    if actual_size != spec.size_bytes:
        return False, f"size 不符：期望 {spec.size_bytes}，实际 {actual_size}"
    actual_sha = _sha256(path)
    if actual_sha != spec.sha256:
        return False, f"sha256 不符：期望 {spec.sha256}，实际 {actual_sha}"
    return True, ""


def download_model(
    spec: ModelSpec,
    cache: Path | None = None,
    endpoint: str | None = None,
    force: bool = False,
) -> Path:
    cache = Path(cache) if cache is not None else default_cache_dir()
    dest = model_path(cache, spec)
    if dest.is_file() and not force:
        ok, message = verify_file(dest, spec)
        if ok:
            return dest
        raise ModelError(f"{dest} 已存在但校验失败：{message}")
    dest.parent.mkdir(parents=True, exist_ok=True)
    part = dest.with_name(dest.name + ".part")
    url = model_url(spec, endpoint)
    try:
        with urllib.request.urlopen(url, timeout=60) as response, open(part, "wb") as fh:
            while True:
                chunk = response.read(_CHUNK)
                if not chunk:
                    break
                fh.write(chunk)
    except OSError as exc:
        part.unlink(missing_ok=True)
        raise ModelError(f"下载失败 {url}：{exc}") from exc
    ok, message = verify_file(part, spec)
    if not ok:
        part.unlink(missing_ok=True)
        raise ModelError(f"下载内容校验失败：{message}")
    part.replace(dest)
    return dest
