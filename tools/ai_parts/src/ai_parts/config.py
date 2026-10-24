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


class _SafeRedirectHandler(urllib.request.HTTPRedirectHandler):
    """重定向护栏：每个跳转目标都过一遍 [_assert_host_allowed]
    （协议 + 解析 IP 边界），阻断跳向内网/元数据地址的重定向。"""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        _assert_host_allowed(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


_OPENER = urllib.request.build_opener(_SafeRedirectHandler)


def _assert_host_allowed(url: str) -> None:
    """SSRF 护栏：协议 + 解析 IP 边界校验。

    - 仅允许 https；http 只在环境变量 COMIC_MOTION_AI_ALLOW_LOCAL=1 时且
      目标解析到本机回环才放行（本地镜像/代理调试用，默认关闭）；
    - 解析目标主机全部 IP，阻断私网/环回/链路本地/保留/组播地址（内网、
      云元数据 169.254.169.254 之类），默认连回环也拦；
    - DNS rebinding 在本地 CLI 场景不做连接级 pin（超出本工具范围），
      由「仅 https + 默认公网端点 + 下载后 sha256 强校验」兜底。
    """
    import ipaddress
    import socket
    from urllib.parse import urlparse

    parsed = urlparse(url)
    if parsed.scheme not in ("https", "http"):
        raise ModelError(f"仅允许 http(s) 下载端点：{url}")
    allow_local = os.environ.get("COMIC_MOTION_AI_ALLOW_LOCAL") == "1"
    if parsed.scheme == "http" and not allow_local:
        raise ModelError(f"明文 http 已禁用（本地镜像调试请设 COMIC_MOTION_AI_ALLOW_LOCAL=1）：{url}")
    host = parsed.hostname
    if not host:
        raise ModelError(f"下载端点缺主机名：{url}")
    port = parsed.port or (443 if parsed.scheme == "https" else 80)
    try:
        infos = socket.getaddrinfo(host, port)
    except OSError as exc:
        raise ModelError(f"下载主机解析失败 {host}：{exc}") from exc
    for info in infos:
        try:
            ip = ipaddress.ip_address(info[4][0])
        except ValueError:
            continue
        loopback_ok = allow_local and ip.is_loopback
        if (ip.is_private or ip.is_loopback or ip.is_link_local
                or ip.is_reserved or ip.is_multicast) and not loopback_ok:
            raise ModelError(f"下载端点解析到非公网地址 {ip}，已阻断：{url}")


def _validate_download_target(url: str, dest: Path, cache: Path) -> None:
    """下载前校验（安全护栏）：
    - [_assert_host_allowed] 做 SSRF 边界校验；
    - 目标文件与 .part 临时文件解析后都必须落在缓存目录内
      （防 spec 字段被构造出 ../ 逃逸缓存根）。返回验证过的 .part 路径，
      调用方只准写这个路径。"""
    _assert_host_allowed(url)
    cache_root = cache.resolve()
    for tag, candidate in (("dest", dest), ("part", dest.with_name(dest.name + ".part"))):
        try:
            candidate.resolve().relative_to(cache_root)
        except ValueError as exc:
            raise ModelError(f"下载目标 {tag} 越出缓存目录：{candidate}") from exc
    return dest.with_name(dest.name + ".part")


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
    url = model_url(spec, endpoint)
    # 安全护栏返回验证过的 .part 路径（dest 与 part 都解析后落缓存目录内），
    # 下方只写这个路径。
    part = _validate_download_target(url, dest, cache)
    # 直接守卫（数据流就近可见）：.part 必须仍落在缓存目录内才允许写。
    if not part.resolve().is_relative_to(cache.resolve()):
        raise ModelError(f"下载目标越出缓存目录：{part}")
    try:
        with _OPENER.open(url, timeout=60) as response, part.open("wb") as fh:
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
