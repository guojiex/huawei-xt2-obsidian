# -*- coding: utf-8 -*-
"""从 v2 设计稿截取干净的应用界面，合成竖版商店海报（当前为备选素材，不进上传目录）。

用法（仓库根目录）：
    python tools/generators/build_store_posters.py            重新截取界面并生成竖版海报
    python tools/generators/build_store_posters.py --check   只校验上传集合规格，不启动浏览器

产出：
    docs/marketing/素材/_中间素材/竖版设计稿/商店海报_01..10.png   1080x1920 / 9:16【备选】
    docs/marketing/素材/_中间素材/界面截图_01..10.png              纯界面底图【不可上传】

当前上传集合由 build_store_screenshots.py 生成，位于 docs/marketing/素材/ 根目录，
为 1920x1080 / 16:9 的真机界面横版图。本脚本产物一律写进 _中间素材/，重跑不会污染上传目录。

上传规格（2026-11-15 用户提供的 AppGallery Connect 当期提交表单，两套方向任选其一，
一次提交只能全用同一方向）：
    竖版：全部竖向、9:16、最低 1080x1920；横版：全部横向、16:9、最低 1920x1080。
    均要求一次上传 3~10 张；PNG / JPG / JPEG 单张 5MB 以内，WEBP 单张 200KB 以内。
    **不接受横竖混用**；界面底图与备选海报单独放 _中间素材/ 隔离。

说明：
- 界面来自 docs/prototype/v2/index.html 的 URL 复现状态，用 CDP 精确裁剪 #window，
  隐藏原型演示标注（.tree-help / .sidebar-bottom / #noteFooter）。
- 这些是**设计稿界面**，不是真机截图；真机素材见 build_store_screenshots.py。
  素材规格以 AppGallery Connect 当期提交表单校验为准。
- 仅使用标准库 + 本机 Chrome（headless CDP），不引入第三方依赖。
- `--check` 只验规格不验画面；原型由并行开发维护，重跑后须目视确认无演示弹窗 / 调试浮层。
"""

import base64
import json
import os
import pathlib
import socket
import struct
import subprocess
import time
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[2]
PROTOTYPE = ROOT / "docs/prototype/v2/index.html"
ICON = ROOT / "docs/assets/app_icon_1024.png"
OUT = ROOT / "docs/marketing/素材"
SRC = OUT / "_中间素材"          # 界面底图：横向 / 低分辨率，仅用于排版，不进上传集合
VERT_OUT = SRC / "竖版设计稿"     # 竖版备选海报，不进上传目录
TMP = ROOT / "tmp"
CHROME = r"C:\Program Files\Google\Chrome\Application\chrome.exe"
PORT = 9347
PROFILE = TMP / "poster_chrome_profile"

POSTER_W, POSTER_H = 1080, 1920
LANDSCAPE_W, LANDSCAPE_H = 1920, 1080
MIN_COUNT, MAX_COUNT = 3, 10
# (最低宽, 最低高, 比例宽, 比例高, 是否竖向)
SPECS = {
    "竖版": (POSTER_W, POSTER_H, 9, 16, True),
    "横版": (LANDSCAPE_W, LANDSCAPE_H, 16, 9, False),
}
MAX_BYTES = {
    ".png": 5 * 1024 * 1024,
    ".jpg": 5 * 1024 * 1024,
    ".jpeg": 5 * 1024 * 1024,
    ".webp": 200 * 1024,
}

# 原型由并行会话持续维护，可能带有演示态弹窗（如 editorMismatchDialog）或启动遮罩。
# .search-note / .import-demo 是设计稿自带的「本页演示 / 不写入设备」提示，
# 属于原型说明而非产品界面，不能出现在上架素材里。
# 截图前关闭「本场景不需要展示」的 dialog，其余（搜索 / 分享 / 统计等）按场景保留。
DIALOG_CLEAN_CSS = (
    ".tree-help,.sidebar-bottom,#noteFooter,#editorMismatchDialog,.startup-mask,"
    ".search-note,.import-demo{display:none!important}"
    "*:focus{outline:none!important}"
)


def hide_demo(keep=()):
    """生成截图前注入的 JS：保留 keep 中的 dialog，其余关闭并隐藏演示标注。"""
    return (
        "(()=>{const keep=new Set(%s);"
        "document.querySelectorAll('dialog[open]').forEach(d=>{"
        "if(!keep.has(d.id)){try{d.close()}catch(_){}}});"
        "const s=document.createElement('style');"
        "s.textContent=%s;"
        "document.head.appendChild(s);return true})()"
        % (json.dumps(list(keep)), json.dumps(DIALOG_CLEAN_CSS))
    )

# 与设计稿 :root / [data-theme=dark] 对齐的品牌色
LIGHT = {
    "bg1": "#f4f9ff", "bg2": "#e2eeff", "ink": "#182431", "muted": "#5d6b7d",
    "accent": "#007dff", "chip": "#ffffff", "chip_line": "#d8e6fb",
    "shadow": "0 40px 90px rgba(28,74,140,.20)", "deco": "#007dff",
}
DARK = {
    "bg1": "#0d1622", "bg2": "#16283f", "ink": "#f0f5fb", "muted": "#9fb2c8",
    "accent": "#71b3ff", "chip": "#1c2c40", "chip_line": "#2c4560",
    "shadow": "0 40px 90px rgba(0,0,0,.55)", "deco": "#3d8bff",
}


class WS:
    """极简 Chrome DevTools Protocol WebSocket 客户端（stdlib only）。"""

    def __init__(self, url):
        host, path = url.split("/devtools/", 1)
        path = "/devtools/" + path
        host = host.replace("ws://", "")
        h, p = host.split(":")
        self.s = socket.create_connection((h, int(p)))
        self.s.settimeout(30)
        key = base64.b64encode(os.urandom(16)).decode()
        req = ("GET %s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\n"
               "Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\n"
               "Sec-WebSocket-Version: 13\r\n\r\n" % (path, host, key))
        self.s.sendall(req.encode())
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = self.s.recv(4096)
            if not chunk:
                raise ConnectionError("websocket handshake failed")
            buf += chunk
        head, self.buf = buf.split(b"\r\n\r\n", 1)
        if b"101" not in head.split(b"\r\n")[0]:
            raise ConnectionError("no upgrade: %r" % head[:200])

    def send(self, obj):
        data = json.dumps(obj).encode()
        mask = os.urandom(4)
        n = len(data)
        header = bytearray([0x81])
        if n < 126:
            header.append(0x80 | n)
        elif n < 65536:
            header.append(0x80 | 126)
            header += struct.pack(">H", n)
        else:
            header.append(0x80 | 127)
            header += struct.pack(">Q", n)
        header += mask
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
        self.s.sendall(bytes(header) + masked)

    def _read(self, n):
        while len(self.buf) < n:
            chunk = self.s.recv(65536)
            if not chunk:
                raise ConnectionError("connection closed")
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def recv(self):
        while True:
            b1, b2 = self._read(2)
            op = b1 & 0x0F
            length = b2 & 0x7F
            if length == 126:
                length = struct.unpack(">H", self._read(2))[0]
            elif length == 127:
                length = struct.unpack(">Q", self._read(8))[0]
            payload = self._read(length)
            if op == 1:
                return json.loads(payload)
            if op == 8:
                raise ConnectionError("websocket closed by peer")

    def call(self, method, params=None, _id=[0]):
        _id[0] += 1
        mid = _id[0]
        self.send({"id": mid, "method": method, "params": params or {}})
        while True:
            msg = self.recv()
            if msg.get("id") == mid:
                if "error" in msg:
                    raise RuntimeError("%s -> %s" % (method, msg["error"]))
                return msg.get("result", {})


def evaluate(ws, expr):
    r = ws.call("Runtime.evaluate",
                {"expression": expr, "returnByValue": True, "awaitPromise": True})
    if r.get("exceptionDetails"):
        raise RuntimeError(json.dumps(r["exceptionDetails"])[:600])
    return r.get("result", {}).get("value")


def launch():
    TMP.mkdir(exist_ok=True)
    PROFILE.mkdir(parents=True, exist_ok=True)
    url = PROTOTYPE.as_uri() + "?ui=2&preset=wide&theme=light"
    proc = subprocess.Popen(
        [CHROME, "--headless=new", "--disable-gpu", "--no-sandbox",
         "--hide-scrollbars", "--window-size=1600,1120",
         "--force-device-scale-factor=1",
         "--remote-debugging-port=%d" % PORT,
         "--user-data-dir=" + str(PROFILE),
         "--no-first-run", "--no-default-browser-check",
         "--allow-file-access-from-files", url],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    target = None
    for _ in range(80):
        time.sleep(0.25)
        try:
            pages = json.loads(urllib.request.urlopen(
                "http://127.0.0.1:%d/json" % PORT, timeout=2).read())
            cand = [t for t in pages
                    if t.get("type") == "page" and "index.html" in t.get("url", "")]
            if cand:
                target = cand[0]
                break
        except Exception:
            continue
    if not target:
        proc.terminate()
        raise RuntimeError("no devtools target for prototype")
    ws = WS(target["webSocketDebuggerUrl"])
    ws.call("Runtime.enable")
    ws.call("Page.enable")
    return proc, ws


def capture_ui(ws, query, keep=()):
    """按 URL 复现状态加载原型，精确裁剪 #window，返回 (png_bytes, w, h)。

    keep 指定要留在画面里的 dialog id（用于展示搜索 / 分享 / 统计等功能态）。
    """
    ws.call("Page.navigate", {"url": PROTOTYPE.as_uri() + "?" + query})
    time.sleep(2.2)
    ws.call("Emulation.setDeviceMetricsOverride",
            {"width": 1600, "height": 1120, "deviceScaleFactor": 2, "mobile": False})
    ws.call("Runtime.evaluate", {"expression": hide_demo(keep)})
    time.sleep(0.6)
    rect = evaluate(ws, "(()=>{const r=document.querySelector('#window')"
                        ".getBoundingClientRect();return {x:r.x,y:r.y,w:r.width,h:r.height}})()")
    if not rect or rect["w"] < 100:
        raise RuntimeError("bad #window rect: %r" % rect)
    res = ws.call("Page.captureScreenshot", {
        "format": "png", "captureBeyondViewport": True,
        "clip": {"x": rect["x"], "y": rect["y"],
                 "width": rect["w"], "height": rect["h"], "scale": 1}})
    data = base64.b64decode(res["data"])
    w = int.from_bytes(data[16:20], "big")
    h = int.from_bytes(data[20:24], "big")
    return data, w, h


TEMPLATE = """<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<style>
*{box-sizing:border-box}
html,body{margin:0;padding:0}
body{width:1080px;height:1920px;overflow:hidden}
.poster{position:relative;width:1080px;height:1920px;overflow:hidden;
  padding:100px 72px 72px;
  background:linear-gradient(160deg,__BG1__ 0%,__BG2__ 62%,__BG2__ 100%);
  font-family:"HarmonyOS Sans SC","PingFang SC","Microsoft YaHei",sans-serif;
  color:__INK__}
.deco{position:absolute;pointer-events:none;opacity:.10;background:__DECO__;
  clip-path:polygon(50% 0,100% 42%,50% 100%,0 42%)}
.deco.a{width:640px;height:820px;right:-230px;top:-210px;transform:rotate(18deg)}
.deco.b{width:380px;height:480px;left:-170px;bottom:-150px;transform:rotate(-16deg);opacity:.07}
.brand{display:flex;align-items:center;gap:24px;position:relative;z-index:2}
.brand img{width:92px;height:92px;border-radius:22px;background:#fff;
  box-shadow:0 14px 34px rgba(20,60,120,.18)}
.brand-name{font-size:40px;font-weight:700;letter-spacing:2px;line-height:1.1}
.brand-en{font-size:18px;letter-spacing:2px;color:__MUTED__;margin-top:9px}
.headline{margin-top:__HEAD_GAP__;font-size:__HEAD_SIZE__;line-height:1.30;
  font-weight:700;letter-spacing:1px;position:relative;z-index:2}
.headline em{font-style:normal;color:__ACCENT__}
.sub{margin-top:30px;font-size:29px;line-height:1.72;color:__MUTED__;
  max-width:936px;position:relative;z-index:2}
.shots{margin-top:__SHOT_GAP__;display:flex;gap:__SHOT_GAPX__;
  justify-content:center;align-items:flex-start;position:relative;z-index:2}
.shot{border-radius:26px;overflow:hidden;background:#fff;box-shadow:__SHADOW__;
  width:__SHOT_W__;flex:none}
.shot img{display:block;width:100%;height:auto}
.tags{margin-top:__TAG_GAP__;display:flex;gap:18px;flex-wrap:wrap;position:relative;z-index:2}
.tag{padding:17px 28px;border-radius:999px;font-size:25px;letter-spacing:.5px;
  background:__CHIP__;border:1px solid __CHIP_LINE__;color:__INK__}
.features{margin-top:60px;display:grid;gap:20px;position:relative;z-index:2}
.feature{display:flex;align-items:center;gap:26px;padding:24px 32px;border-radius:26px;
  background:__CHIP__;border:1px solid __CHIP_LINE__}
.feature .num{width:60px;height:60px;flex:none;border-radius:18px;display:flex;
  align-items:center;justify-content:center;background:__ACCENT__;color:#fff;
  font-size:26px;font-weight:700}
.feature b{font-size:30px;font-weight:700;display:block;line-height:1.3}
.feature span{font-size:23px;color:__MUTED__;display:block;margin-top:7px;line-height:1.45}
.footer{position:absolute;left:72px;right:72px;bottom:70px;display:flex;
  justify-content:space-between;align-items:center;font-size:21px;color:__MUTED__;
  letter-spacing:1px;z-index:2}
.footer .rule{width:52px;height:3px;border-radius:3px;background:__ACCENT__}
</style></head><body><div class="poster">
<div class="deco a"></div><div class="deco b"></div>
<div class="brand"><img src="__ICON__" alt=""><div>
<div class="brand-name">曜石笔记</div><div class="brand-en">本地 MARKDOWN 笔记</div></div></div>
<div class="headline">__HEADLINE__</div>
<div class="sub">__SUB__</div>
__BODY__
<div class="footer"><span>本地 Markdown 笔记 · 为三折叠而设计</span>
<span class="rule"></span><span>__PAGE__ / __TOTAL__</span></div>
</div></body></html>"""


def render_poster(cfg, images, icon_uri, total=10):
    c = DARK if cfg["dark"] else LIGHT
    if cfg.get("features"):
        # 收尾页用要点清单换口气，避免十张全是「截图 + 标签」的同一版式。
        rows = "".join(
            '<div class="feature"><div class="num">%02d</div>'
            '<div><b>%s</b><span>%s</span></div></div>' % (i, title, desc)
            for i, (title, desc) in enumerate(cfg["features"], 1))
        body = '<div class="features">%s</div>' % rows
    else:
        imgs = []
        for key in cfg["shots"]:
            data = images[key]
            imgs.append('<div class="shot"><img src="data:image/png;base64,%s" alt=""></div>'
                        % base64.b64encode(data).decode())
        tags = "".join('<div class="tag">%s</div>' % t for t in cfg["tags"])
        body = ('<div class="shots">%s</div><div class="tags">%s</div>'
                % ("".join(imgs), tags))
    html = TEMPLATE
    pairs = {
        "__BG1__": c["bg1"], "__BG2__": c["bg2"], "__INK__": c["ink"],
        "__MUTED__": c["muted"], "__ACCENT__": c["accent"], "__DECO__": c["deco"],
        "__CHIP__": c["chip"], "__CHIP_LINE__": c["chip_line"], "__SHADOW__": c["shadow"],
        "__ICON__": icon_uri, "__HEADLINE__": cfg["headline"], "__SUB__": cfg["sub"],
        "__BODY__": body, "__PAGE__": cfg["page"], "__TOTAL__": "%02d" % total,
        "__HEAD_GAP__": cfg.get("head_gap", "96px"),
        "__HEAD_SIZE__": cfg.get("head_size", "74px"),
        "__SHOT_GAP__": cfg.get("shot_gap", "86px"),
        "__SHOT_GAPX__": cfg.get("shot_gapx", "28px"),
        "__SHOT_W__": cfg.get("shot_w", "936px"),
        "__TAG_GAP__": cfg.get("tag_gap", "80px"),
    }
    for k, v in pairs.items():
        html = html.replace(k, v)
    return html


def capture_poster(ws, html_path):
    ws.call("Page.navigate", {"url": html_path.as_uri()})
    time.sleep(1.4)
    ws.call("Emulation.setDeviceMetricsOverride",
            {"width": POSTER_W, "height": POSTER_H,
             "deviceScaleFactor": 1, "mobile": False})
    time.sleep(0.5)
    res = ws.call("Page.captureScreenshot", {
        "format": "png", "captureBeyondViewport": True,
        "clip": {"x": 0, "y": 0, "width": POSTER_W,
                 "height": POSTER_H, "scale": 1}})
    return base64.b64decode(res["data"])


def image_size(data, ext):
    """读取 PNG / JPEG 像素尺寸；其余格式返回 None（需要人工确认）。"""
    if ext == ".png" and data[:8] == b"\x89PNG\r\n\x1a\n":
        return struct.unpack(">II", data[16:24])
    if ext in (".jpg", ".jpeg") and data[:2] == b"\xff\xd8":
        i = 2
        sof = {0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7,
               0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF}
        while i + 9 < len(data):
            if data[i] != 0xFF:
                i += 1
                continue
            marker = data[i + 1]
            if marker in (0xD8, 0xD9) or 0xD0 <= marker <= 0xD7:
                i += 2
                continue
            seg = int.from_bytes(data[i + 2:i + 4], "big")
            if seg < 2:
                return None
            if marker in sof:
                h = int.from_bytes(data[i + 5:i + 7], "big")
                w = int.from_bytes(data[i + 7:i + 9], "big")
                return (w, h)
            i += 2 + seg
    return None


def matches_spec(dim, spec):
    """校验单张图是否满足某方向规格（最低尺寸 + 严格比例 + 方向）。"""
    w, h, rw, rh, vertical = spec
    if dim is None:
        return False
    return (dim[0] >= w and dim[1] >= h
            and dim[0] * rh == dim[1] * rw
            and (dim[1] > dim[0] if vertical else dim[0] > dim[1]))


def check_upload_set():
    """上传集合 = OUT 根目录所有图片。

    当期表单允许竖版 9:16 / ≥1080x1920 或横版 16:9 / ≥1920x1080，
    但一次提交必须全用同一方向；先判定方向，再逐张校验尺寸、比例与体积。
    底图与备选海报一律放 _中间素材/，不得回到根目录。
    """
    files = sorted(p for p in OUT.iterdir()
                   if p.is_file() and p.suffix.lower() in MAX_BYTES)
    errors = []
    print("上传集合校验：%s（共 %d 张）" % (OUT, len(files)))
    if not (MIN_COUNT <= len(files) <= MAX_COUNT):
        errors.append("张数 %d 不在 %d~%d 范围" % (len(files), MIN_COUNT, MAX_COUNT))
    entries = []
    for f in files:
        data = f.read_bytes()
        entries.append((f, image_size(data, f.suffix.lower()), data))
    mode = next((name for name, spec in SPECS.items()
                 if all(matches_spec(dim, spec) for _, dim, _ in entries)), None)
    print("  方向判定：%s" % (mode or "未统一（横竖混用或不合规）"))
    if mode is None:
        errors.append("上传集合必须全部为竖向 9:16 / ≥1080x1920，或全部为横向 16:9 / ≥1920x1080")
    for f, dim, data in entries:
        ext = f.suffix.lower()
        limit = MAX_BYTES[ext]
        dims_ok = mode is not None and matches_spec(dim, SPECS[mode])
        bytes_ok = len(data) <= limit
        status = "OK" if (dims_ok and bytes_ok) else "FAIL"
        detail = "%dx%d" % dim if dim else "尺寸未识别"
        print("  %-4s %-38s %-12s %6d KB / 上限 %d KB" %
              (status, f.name, detail, len(data) // 1024, limit // 1024))
        if not dims_ok:
            errors.append("%s 不满足 %s 规格（%s）" % (f.name, mode or "当期", detail))
        if not bytes_ok:
            errors.append("%s 超过 %s 体积上限" % (f.name, ext))
    return errors


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    SRC.mkdir(parents=True, exist_ok=True)
    VERT_OUT.mkdir(parents=True, exist_ok=True)
    if not CHROME or not pathlib.Path(CHROME).exists():
        raise RuntimeError("Chrome not found: %s" % CHROME)

    base_query = "ui=2&preset=wide&theme=light&experience=professional&dual=1&lm=edit&rm=preview"
    preview_query = "ui=2&preset=wide&theme=light&experience=professional&dual=1&lm=preview&rm=preview"
    # 第三项 = 本场景要保留展示的 dialog；其余弹窗一律关闭。
    scenes = [
        ("界面截图_01_三屏工作区.png", base_query, ()),
        ("界面截图_02_单屏浅色.png", "ui=2&preset=phone&theme=light&experience=simple", ()),
        ("界面截图_03_单屏深色.png", "ui=2&preset=phone&theme=dark&experience=simple", ()),
        ("界面截图_04_深色三屏.png",
         "ui=2&preset=wide&theme=dark&experience=professional&dual=1&lm=edit&rm=preview", ()),
        ("界面截图_05_简单模式.png",
         "ui=2&preset=wide&theme=light&experience=simple&dual=0", ()),
        ("界面截图_06_章节导航.png", preview_query + "&side=chapters", ()),
        ("界面截图_07_笔记库管理.png", preview_query + "&view=vaults", ()),
        ("界面截图_08_写作统计.png", preview_query + "&view=stats", ("statsDialog",)),
        ("界面截图_09_快切搜索.png", preview_query + "&panel=search", ("quickSearchDialog",)),
        ("界面截图_10_分享导出.png", preview_query + "&panel=share&stage=formats", ("shareDialog",)),
    ]

    proc, ws = launch()
    try:
        for name, query, keep in scenes:
            data, w, h = capture_ui(ws, query, keep)
            (SRC / name).write_bytes(data)
            print("底图 %-34s %4d x %4d  %4d KB（中间素材，不上传）" %
                  (name, w, h, len(data) // 1024))
    finally:
        proc.terminate()

    # 用 key = 文件名去构造海报配置，避免映射出错
    ui = {name: (SRC / name).read_bytes() for name, _, _ in scenes}

    posters = [
        dict(file="商店海报_01_三屏工作区.png", page="01", dark=False,
             headline="一台三折叠<br><em>一整张工作台</em>",
             sub="折叠时随手记下想法；展开后，让资料、写作与预览各有空间。",
             tags=["三屏展开", "编辑 / 预览", "本地 Markdown"],
             shots=["界面截图_01_三屏工作区.png"], shot_w="936px"),
        dict(file="商店海报_02_折叠随手记.png", page="02", dark=False,
             headline="折叠时<br><em>随手记下想法</em>",
             sub="单屏专注当前笔记，需要时展开文件列表；浅色与深色按习惯切换。",
             tags=["单屏专注", "浅色 / 深色", "自动保存"],
             shots=["界面截图_02_单屏浅色.png", "界面截图_03_单屏深色.png"],
             shot_w="452px", shot_gapx="28px", head_gap="72px",
             shot_gap="56px", tag_gap="48px", head_size="70px"),
        dict(file="商店海报_03_简单模式.png", page="03", dark=False,
             headline="不熟悉语法<br><em>也能直接写</em>",
             sub="简单模式下直接在排版后的正文书写，表格、公式与待办点按插入。",
             tags=["简单模式", "可视化编辑", "专业模式可切换"],
             shots=["界面截图_05_简单模式.png"], shot_w="936px"),
        dict(file="商店海报_04_深色知识库.png", page="04", dark=True,
             headline="把笔记<br><em>整理成知识库</em>",
             sub="多个知识库与多级文件夹，跨库搜索、双向链接，让记录连成脉络。",
             tags=["多知识库", "跨库搜索", "双向链接"],
             shots=["界面截图_04_深色三屏.png"], shot_w="936px"),
        dict(file="商店海报_05_双栏对照.png", page="05", dark=False,
             headline="两篇并排<br><em>边读边写</em>",
             sub="同时打开两篇笔记对照资料，用章节导航在长文里快速定位。",
             tags=["双栏对照", "章节导航", "编辑 / 预览"],
             shots=["界面截图_06_章节导航.png"], shot_w="936px"),
        dict(file="商店海报_06_笔记库管理.png", page="06", dark=False,
             headline="不同主题<br><em>各归各库</em>",
             sub="新建空白知识库或关联已有目录，也可从 ZIP 备份导入；各库独立管理。",
             tags=["多知识库", "ZIP 导入", "独立管理"],
             shots=["界面截图_07_笔记库管理.png"], shot_w="936px"),
        dict(file="商店海报_07_写作统计.png", page="07", dark=False,
             headline="看见自己<br><em>写下的积累</em>",
             sub="按库汇总笔记数与总字数，用连续写作天数和热力图回顾习惯。",
             tags=["写作统计", "热力图", "成就徽章"],
             shots=["界面截图_08_写作统计.png"], shot_w="936px",
             head_size="70px", shot_gap="64px", tag_gap="56px"),
        dict(file="商店海报_08_快切搜索.png", page="08", dark=False,
             headline="找一篇笔记<br><em>不用记得在哪</em>",
             sub="按文件名或正文查找，切换全部库逐库呈现结果，也能快切最近打开。",
             tags=["当前库 / 全部库", "正文搜索", "快切"],
             shots=["界面截图_09_快切搜索.png"], shot_w="936px"),
        dict(file="商店海报_09_分享导出.png", page="09", dark=False,
             headline="写完即分享<br><em>格式自己选</em>",
             sub="把笔记生成排版长图、PDF 文档，或导出 Markdown 文件与纯文本。",
             tags=["长图", "PDF", "Markdown"],
             shots=["界面截图_10_分享导出.png"], shot_w="936px"),
        dict(file="商店海报_10_功能总览.png", page="10", dark=True,
             headline="为三折叠<br><em>重新安排的笔记</em>",
             sub="从随手记录到整理成库，一台设备完成。",
             head_size="70px", features=[
                 ("三屏工作区", "单屏记录，展开后目录、编辑与预览各占一栏"),
                 ("双栏对照", "两篇笔记并排，或同一篇边写边预览"),
                 ("简单 / 专业双模式", "排版直写，或掌控 Markdown 细节"),
                 ("知识库整理", "多库、多级文件夹、双向链接、跨库搜索"),
                 ("多格式导出", "PDF、长图、Markdown 与 ZIP 打包"),
                 ("本地存储", "笔记留在设备，浅色深色与字号按习惯调整"),
             ]),
    ]

    if len(posters) > MAX_COUNT:
        raise RuntimeError("海报 %d 张超过当期上传上限 %d 张" % (len(posters), MAX_COUNT))

    icon_uri = "data:image/png;base64," + base64.b64encode(ICON.read_bytes()).decode()
    tmp_html = TMP / "poster_render.html"
    proc, ws = launch()
    try:
        for cfg in posters:
            html = render_poster(cfg, ui, icon_uri, total=len(posters))
            tmp_html.write_text(html, encoding="utf-8")
            data = capture_poster(ws, tmp_html)
            w = int.from_bytes(data[16:20], "big")
            h = int.from_bytes(data[20:24], "big")
            size_kb = len(data) // 1024
            if (w, h) != (POSTER_W, POSTER_H):
                raise RuntimeError("bad poster size %sx%s for %s" % (w, h, cfg["file"]))
            if len(data) > MAX_BYTES[".png"]:
                raise RuntimeError("poster exceeds 5MB: %s (%d KB)" % (cfg["file"], size_kb))
            (VERT_OUT / cfg["file"]).write_bytes(data)
            print("备选海报 %-28s %4d x %4d  %4d KB" % (cfg["file"], w, h, size_kb))
    finally:
        proc.terminate()

    print("\n竖版备选目录:", VERT_OUT, "（不进上传集合）")
    print("当前上传集合:", OUT, "根目录（由 build_store_screenshots.py 生成）")
    errors = check_upload_set()
    if errors:
        for e in errors:
            print("  FAIL", e)
        raise RuntimeError("上传集合规格校验失败")
    print("上传集合规格校验通过（同方向、比例与最低尺寸、体积均达标）。")


if __name__ == "__main__":
    import sys

    if "--check" in sys.argv[1:]:
        problems = check_upload_set()
        if problems:
            for item in problems:
                print("  FAIL", item)
            raise SystemExit(1)
        print("校验通过：上传集合同方向、比例与最低尺寸合规、体积达标。")
    else:
        main()
