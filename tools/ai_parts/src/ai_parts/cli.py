import argparse
import sys
import time
from pathlib import Path

import cv2

from .config import (
    DETECTOR,
    SEGMENTER,
    ModelError,
    default_cache_dir,
    download_model,
    model_path,
)
from .corpus import load_annotations, load_predictions
from .metrics import score_corpus
from .overlay import render_overlay
from .pipeline import run_page
from .review import build_review_html
from .sidecar import (
    AnchorError,
    DraftError,
    compose_sidecar,
    dumps_json,
    load_json,
    write_json,
)


def _models_meta() -> dict[str, str]:
    return {
        "detector": f"{DETECTOR.repo}/{DETECTOR.filename}@{DETECTOR.sha256[:8]}",
        "segmenter": f"{SEGMENTER.repo}/{SEGMENTER.filename}@{SEGMENTER.sha256[:8]}",
    }


def _load_models(cache, conf=None):
    from .adapters import HandSegNetSegmenter, OnnxHandDetector

    cache = Path(cache) if cache is not None else default_cache_dir()
    detector_path = model_path(cache, DETECTOR)
    segmenter_path = model_path(cache, SEGMENTER)
    for path, spec in ((detector_path, DETECTOR), (segmenter_path, SEGMENTER)):
        if not path.is_file():
            raise ModelError(
                f"模型未下载：{path}。先运行 ai-parts download（或设置 COMIC_MOTION_AI_CACHE）"
            )
    kwargs = {} if conf is None else {"conf": conf}
    return OnnxHandDetector.load(detector_path, **kwargs), HandSegNetSegmenter.load(
        segmenter_path
    )


def _read_rgb(path: Path):
    image = cv2.imread(str(path), cv2.IMREAD_COLOR)
    if image is None:
        raise ValueError(f"无法读取图片：{path}")
    return cv2.cvtColor(image, cv2.COLOR_BGR2RGB)


def _cmd_download(args) -> int:
    specs = [DETECTOR, SEGMENTER]
    if args.model == "detector":
        specs = [DETECTOR]
    elif args.model == "segmenter":
        specs = [SEGMENTER]
    for spec in specs:
        path = download_model(
            spec, cache=args.cache, endpoint=args.endpoint, force=args.force
        )
        print(f"{spec.key}: {path}")
    return 0


def _cmd_detect(args) -> int:
    detector, segmenter = _load_models(args.cache, args.conf)
    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    models = _models_meta()
    for image_path in args.images:
        started = time.perf_counter()
        image = _read_rgb(image_path)
        draft = run_page(image, image_path.name, detector, segmenter, models)
        draft_path = out_dir / f"{image_path.stem}.draft.json"
        write_json(draft_path, draft, base_dir=out_dir)
        if not args.no_overlay:
            render_overlay(
                image, draft["parts"], out_path=out_dir / f"{image_path.stem}.overlay.png"
            )
        elapsed = time.perf_counter() - started
        print(
            f"{image_path.name}: {len(draft['parts'])} 个候选 "
            f"{elapsed:.2f}s -> {draft_path}"
        )
    return 0


def _cmd_review(args) -> int:
    path = build_review_html(
        args.drafts, args.images, args.out, title=args.title
    )
    print(f"初审页面：{path}")
    return 0


def _cmd_compose(args) -> int:
    draft = load_json(args.draft)
    anchors = load_json(args.anchors)
    if not isinstance(anchors, dict):
        raise AnchorError("anchors 顶层必须是对象：{part_id: [x, y]}")
    sidecar = compose_sidecar(draft, anchors, allow_skip=args.allow_skip)
    # 允许根 = 用户声明的输出目录：文件必须落在该目录解析后的真实位置
    # （防 .. 分量与符号链接把写盘重定向到别处），目录本身可以是任意绝对路径。
    write_json(args.out, sidecar, base_dir=Path(args.out).resolve().parent)
    print(f"{args.out}: {len(sidecar['parts'])} 个手部部件")
    return 0


def _cmd_score(args) -> int:
    report = score_corpus(
        load_annotations(args.annotations),
        load_predictions(args.predictions),
        require_anchors=args.require_anchors,
    )
    summary = report["summary"]
    line = (
        f"pages={summary['pages']} recall={summary['recall']:.3f} "
        f"precision={summary['precision']:.3f} "
        f"negative_fp/page={summary['negative_fp_per_page']:.3f} "
        f"passed={report['passed']}"
    )
    if args.out:
        write_json(args.out, report, base_dir=Path(args.out).resolve().parent)
        print(line)
        print(f"报告：{args.out}")
    else:
        sys.stdout.write(dumps_json(report))
    return 0 if report["passed"] else 1


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="ai-parts",
        description="漫画手部部件生产器：检测 → 分割 → 人工腕点 → 侧车 → 验收评分",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    download = sub.add_parser("download", help="下载并校验模型权重")
    download.add_argument("--cache", type=Path)
    download.add_argument("--endpoint", help="HF 兼容端点，默认取 COMIC_MOTION_AI_ENDPOINT")
    download.add_argument(
        "--model", choices=("all", "detector", "segmenter"), default="all"
    )
    download.add_argument("--force", action="store_true")
    download.set_defaults(func=_cmd_download)

    detect = sub.add_parser("detect", help="生成候选部件 draft 与叠加图")
    detect.add_argument("images", nargs="+", type=Path)
    detect.add_argument("--out", type=Path, required=True)
    detect.add_argument("--cache", type=Path)
    detect.add_argument("--conf", type=float, help="检测阈值，默认 0.395")
    detect.add_argument("--no-overlay", action="store_true")
    detect.set_defaults(func=_cmd_detect)

    review = sub.add_parser("review", help="生成人工腕点确认页面")
    review.add_argument("drafts", type=Path)
    review.add_argument("images", type=Path)
    review.add_argument("-o", "--out", type=Path, required=True)
    review.add_argument("--title", default="AI 手部初审")
    review.set_defaults(func=_cmd_review)

    compose = sub.add_parser("compose", help="合并人工锚点，产出 part_motion 侧车")
    compose.add_argument("draft", type=Path)
    compose.add_argument("--anchors", type=Path, required=True)
    compose.add_argument("-o", "--out", type=Path, required=True)
    compose.add_argument("--allow-skip", action="store_true")
    compose.set_defaults(func=_cmd_compose)

    score = sub.add_parser("score", help="按验收门槛评分")
    score.add_argument("annotations", type=Path)
    score.add_argument("predictions", type=Path)
    score.add_argument("-o", "--out", type=Path)
    score.add_argument("--require-anchors", action="store_true")
    score.set_defaults(func=_cmd_score)
    return parser


def main(argv=None) -> int:
    args = _build_parser().parse_args(argv)
    try:
        return args.func(args)
    except AnchorError as exc:
        print(f"anchor 错误: {exc}", file=sys.stderr)
        return 2
    except (DraftError, ModelError, ValueError, OSError) as exc:
        print(f"错误: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
