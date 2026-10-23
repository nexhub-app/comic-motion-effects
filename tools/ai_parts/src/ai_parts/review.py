import html
import json
import os
from pathlib import Path

IMAGE_SUFFIXES = {".png", ".jpg", ".jpeg", ".webp", ".bmp"}
DRAFT_SUFFIX = ".draft.json"


def _index_images(directory: Path) -> dict[str, Path]:
    index: dict[str, Path] = {}
    for path in sorted(directory.rglob("*")):
        if path.is_file() and path.suffix.lower() in IMAGE_SUFFIXES:
            index.setdefault(path.name, path)
            index.setdefault(path.stem, path)
    return index


def find_image(index: dict[str, Path], page: str) -> Path | None:
    return index.get(page) or index.get(Path(page).stem)


def build_review_html(drafts_dir, images_dir, output_path, title="AI 手部初审"):
    output_path = Path(output_path)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    index = _index_images(Path(images_dir))

    pages = []
    for draft_path in sorted(Path(drafts_dir).glob(f"*{DRAFT_SUFFIX}")):
        with open(draft_path, encoding="utf-8") as fh:
            draft = json.load(fh)
        image = find_image(index, draft.get("page", ""))
        relative = None
        if image is not None:
            try:
                relative = os.path.relpath(image, output_path.parent).replace("\\", "/")
            except ValueError:
                relative = image.resolve().as_uri()
        pages.append(
            {
                "page": draft.get("page", draft_path.name),
                "stem": draft_path.name[: -len(DRAFT_SUFFIX)],
                "image": relative,
                "draft": draft,
            }
        )
    if not pages:
        raise ValueError(f"{drafts_dir} 中没有 *.draft.json")

    payload = json.dumps(
        {"title": title, "pages": pages}, ensure_ascii=False, indent=2
    ).replace("<", "\\u003c")
    document = _TEMPLATE.replace("__TITLE__", html.escape(title)).replace(
        "__REVIEW_DATA__", payload
    )
    output_path.write_text(document, encoding="utf-8", newline="\n")
    return output_path


_TEMPLATE = """<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>__TITLE__</title>
<style>
:root { color-scheme: dark; --bg:#14161a; --panel:#1d2127; --line:#30363f; --text:#e7e9ee;
        --muted:#9aa4b2; --accent:#ff6b5a; --ok:#3ecf8e; }
* { box-sizing: border-box; }
body { margin:0; background:var(--bg); color:var(--text); font:14px/1.5 "Segoe UI", system-ui, sans-serif; }
header { padding:12px 18px; border-bottom:1px solid var(--line); display:flex; gap:16px; align-items:baseline; }
header h1 { font-size:16px; margin:0; font-weight:600; }
header .meta { color:var(--muted); font-size:12px; }
main { display:flex; height:calc(100vh - 52px); }
aside { width:320px; flex:none; padding:16px; border-right:1px solid var(--line); overflow:auto; background:var(--panel); }
#page-title { font-weight:600; margin-bottom:4px; word-break:break-all; }
#page-index { color:var(--muted); font-size:12px; margin-bottom:14px; }
.part { display:flex; justify-content:space-between; gap:8px; width:100%; text-align:left;
        background:#242a31; color:var(--text); border:1px solid var(--line); border-radius:6px;
        padding:8px 10px; margin-bottom:6px; cursor:pointer; font:inherit; }
.part.active { border-color:var(--accent); box-shadow:0 0 0 1px var(--accent) inset; }
.part .tag { color:var(--muted); font-size:12px; }
.part .dot { width:8px; height:8px; border-radius:50%; background:#555d68; flex:none; margin-top:6px; }
.part.done .dot { background:var(--ok); }
.hint { color:var(--muted); font-size:12px; margin:12px 0; }
button.action { width:100%; padding:9px 10px; margin-top:8px; border-radius:6px; border:1px solid var(--line);
                background:#2a313a; color:var(--text); cursor:pointer; font:inherit; }
button.action.primary { background:var(--accent); border-color:var(--accent); color:#1a0d0b; font-weight:600; }
button.action:disabled { opacity:.45; cursor:default; }
.nav { display:flex; gap:8px; margin-top:12px; }
.nav button { flex:1; }
#stage { flex:1; overflow:auto; padding:18px; display:flex; flex-direction:column; align-items:center; }
#viewport { position:relative; max-width:100%; width:min(100%, 900px); }
#page-image { display:block; width:100%; height:auto; border-radius:4px; background:#0b0c0e; }
#overlay, #markers { position:absolute; inset:0; width:100%; height:100%; }
#overlay { pointer-events:none; }
#markers { pointer-events:none; }
.marker { position:absolute; width:14px; height:14px; margin:-7px 0 0 -7px; border-radius:50%;
          border:2px solid #101215; background:var(--ok); box-shadow:0 0 0 1px var(--ok); }
.marker.selected { background:var(--accent); box-shadow:0 0 0 2px var(--accent); }
#toast { position:fixed; left:50%; bottom:28px; transform:translateX(-50%); padding:9px 16px;
         border-radius:6px; background:#2c333d; border:1px solid var(--line); opacity:0;
         transition:opacity .15s; pointer-events:none; }
#toast.show { opacity:1; }
.empty { color:var(--muted); padding:40px; text-align:center; }
</style>
</head>
<body>
<header>
  <h1>__TITLE__</h1>
  <span class="meta">选中部件 → 在手部 polygon 内点击腕点 → 导出 anchors。每次只导出当前页。</span>
</header>
<main>
  <aside>
    <div id="page-title"></div>
    <div id="page-index"></div>
    <div id="part-list"></div>
    <div class="hint">腕点必须落在该部件的 polygon 内；导出文件与 draft 同名，compose 时逐一传入。</div>
    <button class="action primary" id="download">导出本页 anchors</button>
    <div class="nav">
      <button class="action" id="prev">上一页</button>
      <button class="action" id="next">下一页</button>
    </div>
  </aside>
  <section id="stage">
    <div id="viewport">
      <img id="page-image" alt="">
      <svg id="overlay" viewBox="0 0 1 1" preserveAspectRatio="none"></svg>
      <div id="markers"></div>
    </div>
    <div class="empty" id="empty" hidden>找不到页面图片，请检查 --images 目录。</div>
  </section>
</main>
<div id="toast"></div>
<script id="review-data" type="application/json">__REVIEW_DATA__</script>
<script>
(() => {
  const DATA = JSON.parse(document.getElementById('review-data').textContent);
  const COLORS = ['#ff6b5a', '#3ecf8e', '#5aa7ff', '#ffb84d', '#c07bff', '#4dd6d6', '#ffd94d', '#9aa4b2'];
  const state = { index: 0, selected: null, anchors: {} };
  const img = document.getElementById('page-image');
  const svg = document.getElementById('overlay');
  const markers = document.getElementById('markers');
  const partList = document.getElementById('part-list');
  const toast = document.getElementById('toast');
  let toastTimer = null;

  DATA.pages.forEach((page) => {
    const store = {};
    (page.draft.parts || []).forEach((part) => {
      store[part.id] = part.anchor ? [part.anchor.x, part.anchor.y] : null;
    });
    state.anchors[page.stem] = store;
  });

  function say(message) {
    toast.textContent = message;
    toast.classList.add('show');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => toast.classList.remove('show'), 2200);
  }

  function current() { return DATA.pages[state.index]; }
  function parts() { return current().draft.parts || []; }
  function store() { return state.anchors[current().stem]; }

  function inside(polygon, x, y) {
    let hit = false;
    for (let i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
      const [xi, yi] = polygon[i], [xj, yj] = polygon[j];
      if ((yi > y) !== (yj > y) && x < ((xj - xi) * (y - yi)) / (yj - yi) + xi) hit = !hit;
    }
    return hit;
  }

  function round(value) { return Math.round(value * 1e6) / 1e6; }

  function render() {
    const page = current();
    document.getElementById('page-title').textContent = page.page;
    document.getElementById('page-index').textContent =
      `第 ${state.index + 1} / ${DATA.pages.length} 页 · ${parts().length} 个候选`;
    document.getElementById('prev').disabled = state.index === 0;
    document.getElementById('next').disabled = state.index >= DATA.pages.length - 1;
    img.src = page.image || '';
    const missing = !page.image;
    img.style.display = missing ? 'none' : 'block';
    document.getElementById('empty').hidden = !missing;

    svg.replaceChildren();
    markers.replaceChildren();
    parts().forEach((part, index) => {
      const color = COLORS[index % COLORS.length];
      const polygon = document.createElementNS('http://www.w3.org/2000/svg', 'polygon');
      polygon.setAttribute('points', part.polygon.map((p) => `${p[0]},${p[1]}`).join(' '));
      polygon.setAttribute('fill', color);
      polygon.setAttribute('fill-opacity', part.id === state.selected ? '0.22' : '0.10');
      polygon.setAttribute('stroke', color);
      polygon.setAttribute('stroke-width', part.id === state.selected ? '2.5' : '1.5');
      polygon.setAttribute('vector-effect', 'non-scaling-stroke');
      svg.appendChild(polygon);
    });

    partList.replaceChildren();
    document.getElementById('download').disabled = parts().length === 0;
    if (parts().length === 0) {
      const empty = document.createElement('div');
      empty.className = 'hint';
      empty.textContent = '本页没有候选手部，无需导出。';
      partList.appendChild(empty);
    }
    parts().forEach((part, index) => {
      const button = document.createElement('button');
      button.className = 'part' + (part.id === state.selected ? ' active' : '') +
        (store()[part.id] ? ' done' : '');
      const left = document.createElement('span');
      left.textContent = `#${part.id}  score ${Number(part.score).toFixed(2)}`;
      const tag = document.createElement('span');
      tag.className = 'tag';
      tag.textContent = store()[part.id] ? '已确认' : '待确认';
      const dot = document.createElement('span');
      dot.className = 'dot';
      button.append(left, tag, dot);
      button.addEventListener('click', () => {
        state.selected = part.id;
        render();
      });
      partList.appendChild(button);
    });

    Object.entries(store()).forEach(([id, point]) => {
      if (!point) return;
      const marker = document.createElement('div');
      marker.className = 'marker' + (Number(id) === state.selected ? ' selected' : '');
      marker.style.left = `${point[0] * 100}%`;
      marker.style.top = `${point[1] * 100}%`;
      markers.appendChild(marker);
    });
  }

  function selectNextUnconfirmed() {
    const pending = parts().find((part) => !store()[part.id]);
    state.selected = pending ? pending.id : (parts()[0] ? parts()[0].id : null);
  }

  img.addEventListener('click', (event) => {
    if (!current().image || state.selected === null) return;
    const part = parts().find((item) => item.id === state.selected);
    if (!part) return;
    const rect = img.getBoundingClientRect();
    const x = (event.clientX - rect.left) / rect.width;
    const y = (event.clientY - rect.top) / rect.height;
    if (x < 0 || x > 1 || y < 0 || y > 1) return;
    if (!inside(part.polygon, x, y)) {
      say('腕点必须落在该手部 polygon 内');
      return;
    }
    store()[part.id] = [round(x), round(y)];
    const pending = parts().find((item) => !store()[item.id]);
    state.selected = pending ? pending.id : part.id;
    render();
  });

  document.getElementById('download').addEventListener('click', () => {
    const missing = parts().filter((part) => !store()[part.id]);
    if (missing.length) {
      say(`还有 ${missing.length} 个部件未确认，先补齐再导出`);
      return;
    }
    const name = `${current().stem}.anchors.json`;
    const blob = new Blob([JSON.stringify(store(), null, 2) + '\\n'], { type: 'application/json' });
    const link = document.createElement('a');
    link.href = URL.createObjectURL(blob);
    link.download = name;
    link.click();
    setTimeout(() => URL.revokeObjectURL(link.href), 1000);
    say(`已导出 ${name}`);
  });

  function go(delta) {
    const next = state.index + delta;
    if (next < 0 || next >= DATA.pages.length) return;
    state.index = next;
    selectNextUnconfirmed();
    render();
  }
  document.getElementById('prev').addEventListener('click', () => go(-1));
  document.getElementById('next').addEventListener('click', () => go(1));
  document.addEventListener('keydown', (event) => {
    if (event.key === 'ArrowLeft') go(-1);
    if (event.key === 'ArrowRight') go(1);
  });

  selectNextUnconfirmed();
  render();
})();
</script>
</body>
</html>
"""
