# -*- coding: utf-8 -*-
"""把 真机截图/ 排成带功能讲解的 AppGallery 当期横版上传集合。

用法（仓库根目录）：
    python tools/generators/build_store_screenshots.py            重新生成横版上传集合
    python tools/generators/build_store_screenshots.py --check   只校验上传集合规格

产出（唯一上传集合，OUT 根目录）：
    商店截图_01..10_*.jpg    1920x1080 / 16:9 横向 JPG

规格（2026-11-15 用户提供的当期提交表单，横版口径）：
    全部横向、宽高比严格 16:9、最低 1920x1080、一次上传 3~10 张；
    PNG / JPG / JPEG 单张 5MB 以内，WEBP 单张 200KB 以内。
    竖版 9:16 是另一套口径，一次提交只能全用同一方向。

构图（沿用竖版设计稿海报的讲解式版式，不是「贴图 + 角标」）：
- 左侧文案区：品牌 + 场景眉标 + 大标题（含高亮）+ 功能说明 + 标签 + 页码。
- 右侧视觉区：真机原图完整缩放居中，不裁画面；两侧同图模糊延展背景。
- 三栏场景额外在截图上方加对位标注（文件树 / 编辑 / 预览等），
  让用户一眼看懂三折叠展开后的三栏分工；标注按栏宽比例对齐。
- 11 张原图全部用上：51+52 并排、47+48 上下叠放，其余单图，共 10 张。
- 第 10 张为六条功能要点收尾页，避免十张全是同一「截图 + 标签」版式。
- 系统状态栏、底部提示与笔记正文按真机原样保留（用户确认无隐私顾虑）。

边界：
- 旧竖版设计稿海报在 _中间素材/竖版设计稿/；纯截图版横图在 _中间素材/纯截图版/。
- 仅用标准库 + 本机 Chrome（headless CDP），不引入 Pillow 等第三方依赖。
- `--check` 只验规格不验画面；每次重跑后仍须目视确认文案无溢出、截图无遮挡。
"""

import base64
import pathlib
import shutil
import sys
import time

import build_store_posters as P

OUT = P.OUT
RAW = OUT / "真机截图"
VERT_BACKUP = P.VERT_OUT
PLAIN_BACKUP = OUT / "_中间素材" / "纯截图版"
TMP = P.TMP
W, H = P.LANDSCAPE_W, P.LANDSCAPE_H
MAX_BYTES = P.MAX_BYTES[".jpg"]


def raw(name):
    """按序号后缀定位用户放入的真机截图，避免把完整微信文件名写死在配置里。"""
    hits = sorted(RAW.glob("*_%s_130.jpg" % name))
    if len(hits) != 1:
        raise RuntimeError("真机截图 %s 匹配到 %d 个文件：%r" % (name, len(hits), hits))
    return hits[0]


# columns = [(栏宽占比, 标注), ...]，与截图实际栏宽对齐；空列表 = 不标注
ITEMS = [
    dict(file="商店截图_01_折叠随手记.jpg", ids=["51", "52"], dark=False,
         layout="pair-vertical", kicker="折叠态 · 单屏",
         headline="折叠时<br><em>随手记下想法</em>",
         sub="单屏专注当前笔记，浅色与深色按习惯切换；需要时再展开文件列表。",
         tags=["单屏专注", "浅色 / 深色", "自动保存"], columns=[]),
    dict(file="商店截图_02_三栏工作区.jpg", ids=["49"], dark=True,
         layout="single", kicker="展开态 · 三栏",
         headline="一屏三栏<br><em>各司其职</em>",
         sub="左栏管目录，中栏写 Markdown，右栏实时看排版。查找、写作与校对不用来回切换。",
         tags=["文件树", "Markdown 编辑", "实时预览"],
         columns=[(25, "① 文件树 / 目录"), (37.5, "② Markdown 编辑"),
                  (37.5, "③ 实时预览")]),
    dict(file="商店截图_03_边写边看.jpg", ids=["54"], dark=True,
         layout="single", kicker="展开态 · 编辑 / 预览",
         headline="编辑与预览<br><em>左右随你换</em>",
         sub="左栏目录常驻，中栏看反链与排版，右栏直接改正文；同一篇笔记也能一键切换编辑 / 预览。",
         tags=["编辑 / 预览互换", "反链查看", "自动保存"],
         columns=[(25, "① 文件树"), (37.5, "② 预览 / 反链"),
                  (37.5, "③ Markdown 编辑")]),
    dict(file="商店截图_04_双栏对照.jpg", ids=["50"], dark=False,
         layout="single", kicker="展开态 · 双栏对照",
         headline="两篇并排<br><em>边读边写</em>",
         sub="同时打开两篇笔记对照资料，左栏目录常驻，切换资料不用离开当前页。",
         tags=["双栏对照", "目录常驻", "拖拽调栏"],
         columns=[(25, "① 文件树"), (37.5, "② 笔记 A"),
                  (37.5, "③ 笔记 B")]),
    dict(file="商店截图_05_简单模式.jpg", ids=["53"], dark=False,
         layout="single", kicker="写作模式",
         headline="不熟悉语法<br><em>也能直接写</em>",
         sub="简单模式直接在排版后的正文书写，工具栏点按插入格式；想掌控细节可切回专业模式。",
         tags=["简单模式", "可视化编辑", "专业模式可切换"],
         columns=[(25, "① 文件树"), (75, "② 编辑 / 预览")]),
    dict(file="商店截图_06_快切与搜索.jpg", ids=["45"], dark=False,
         layout="single", kicker="查找",
         headline="找一篇笔记<br><em>不用记得在哪</em>",
         sub="按文件名、路径或正文查找，当前库与全部库逐一切换，也能快切最近打开。",
         tags=["当前库 / 全部库", "正文搜索", "快切"], columns=[]),
    dict(file="商店截图_07_分享与导出.jpg", ids=["44"], dark=False,
         layout="single", kicker="分享",
         headline="写完即分享<br><em>格式自己选</em>",
         sub="把笔记生成排版长图、A4 竖版 PDF，或导出 Markdown / ZIP 与纯文本。",
         tags=["长图", "PDF", "Markdown / ZIP"], columns=[]),
    dict(file="商店截图_08_写作统计.jpg", ids=["46"], dark=False,
         layout="single", kicker="回顾",
         headline="看见自己<br><em>写下的积累</em>",
         sub="按库汇总笔记数与总字数，用连续写作天数和近 12 周热力图回顾习惯，只在本机统计。",
         tags=["写作统计", "热力图", "本机统计"], columns=[]),
    dict(file="商店截图_09_笔记库管理.jpg", ids=["47", "48"], dark=False,
         layout="pair-stack", kicker="整理",
         headline="不同主题<br><em>各归各库</em>",
         sub="新建空白知识库或关联已有目录，也能导入已有库；每个库在应用内独立管理。",
         tags=["多知识库", "关联本地目录", "独立管理"], columns=[]),
    dict(file="商店截图_10_功能总览.jpg", ids=["49"], dark=True,
         layout="features", kicker="总览",
         headline="为三折叠<br><em>重新安排的笔记</em>",
         sub="从随手记录到整理成库，一台设备完成。", tags=[], columns=[],
         features=[
             ("三栏工作区", "单屏记录，展开后目录、编辑与预览各占一栏"),
             ("双栏对照", "两篇笔记并排，或同一篇边写边预览"),
             ("简单 / 专业双模式", "排版直写，或掌控 Markdown 细节"),
             ("知识库整理", "多库、多级文件夹、双向链接、跨库搜索"),
             ("多格式导出", "PDF、长图、Markdown 与 ZIP 打包"),
             ("本地存储", "笔记留在设备，浅色深色按习惯调整"),
         ]),
]

TEMPLATE = """<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<style>
*{box-sizing:border-box}
html,body{margin:0;padding:0}
body{width:1920px;height:1080px;overflow:hidden}
.stage{position:relative;width:1920px;height:1080px;overflow:hidden;background:__BG2__;
  font-family:"HarmonyOS Sans SC","Microsoft YaHei",sans-serif}
.panel{position:absolute;left:0;top:0;width:680px;height:1080px;
  padding:78px 58px 64px;color:__INK__;z-index:3;
  background:linear-gradient(165deg,__BG1__ 0%,__BG2__ 100%)}
.panel:after{content:"";position:absolute;right:0;top:0;width:1px;height:100%;
  background:__CHIP_LINE__}
.brand{display:flex;align-items:center;gap:20px}
.brand img{width:78px;height:78px;border-radius:20px;background:#fff;
  box-shadow:0 12px 30px rgba(20,60,120,.18)}
.brand-name{font-size:34px;font-weight:700;letter-spacing:2px;line-height:1.1}
.brand-en{font-size:15px;letter-spacing:2px;color:__MUTED__;margin-top:9px}
.kicker{margin-top:72px;display:inline-block;padding:11px 24px;border-radius:999px;
  font-size:19px;letter-spacing:2px;color:__ACCENT__;background:__CHIP__;
  border:1px solid __CHIP_LINE__}
.headline{margin-top:34px;font-size:60px;line-height:1.28;font-weight:700;
  letter-spacing:1px;position:relative;z-index:2}
.headline em{font-style:normal;color:__ACCENT__}
.sub{margin-top:30px;font-size:25px;line-height:1.75;color:__MUTED__;
  position:relative;z-index:2}
.tags{margin-top:46px;display:flex;gap:14px;flex-wrap:wrap;position:relative;z-index:2}
.tag{padding:14px 24px;border-radius:999px;font-size:21px;letter-spacing:.5px;
  background:__CHIP__;border:1px solid __CHIP_LINE__;color:__INK__}
.footer{position:absolute;left:58px;right:58px;bottom:56px;display:flex;
  justify-content:space-between;align-items:center;font-size:18px;
  color:__MUTED__;letter-spacing:1px}
.footer .rule{width:44px;height:3px;border-radius:3px;background:__ACCENT__}
.right{position:absolute;left:680px;right:0;top:0;bottom:0;overflow:hidden}
.bg{position:absolute;inset:-120px;background-image:url(__BG__);
  background-size:cover;background-position:center;transform:scale(1.12);
  filter:blur(80px) brightness(__BRIGHT__) saturate(1.1);opacity:.92}
.veil{position:absolute;inset:0;background:__VEIL__}
.frames{position:absolute;inset:0;display:flex;flex-direction:__FLEXDIR__;
  gap:__GAP__;align-items:center;justify-content:center;z-index:2}
.shotwrap{position:relative;flex:none;width:max-content}
.shot{height:__SHOT_H__;border-radius:18px;overflow:hidden;
  box-shadow:__SHADOW__;border:1px solid __FRAME_LINE__;background:#fff}
.shot img{display:block;height:__SHOT_H__;width:auto}
.cols{position:absolute;left:0;right:0;top:-66px;display:flex;gap:8px}
.col{min-width:0;padding:12px 6px;text-align:center;border-radius:12px;
  font-size:18px;font-weight:600;color:#f4f9ff;white-space:nowrap;
  background:rgba(9,24,44,.82);border:1px solid rgba(255,255,255,.24)}
.features{position:absolute;inset:0;z-index:2;display:grid;
  grid-template-columns:1fr 1fr;gap:22px;align-content:center;padding:74px 66px}
.feature{display:flex;align-items:flex-start;gap:20px;padding:28px 28px;
  border-radius:22px;background:__CHIP__;border:1px solid __CHIP_LINE__}
.feature .num{width:52px;height:52px;flex:none;border-radius:16px;
  display:flex;align-items:center;justify-content:center;
  background:__ACCENT__;color:#fff;font-size:22px;font-weight:700}
.feature b{display:block;font-size:26px;font-weight:700;color:__INK__;line-height:1.3}
.feature span{display:block;margin-top:11px;font-size:19px;line-height:1.55;color:__MUTED__}
</style></head><body><div class="stage">
<div class="panel">
  <div class="brand"><img src="__ICON__" alt=""><div>
    <div class="brand-name">曜石笔记</div>
    <div class="brand-en">本地 MARKDOWN 笔记</div></div></div>
  <div class="kicker">__KICKER__</div>
  <div class="headline">__HEADLINE__</div>
  <div class="sub">__SUB__</div>
  <div class="tags">__TAGS__</div>
  <div class="footer"><span>本地 Markdown 笔记 · 为三折叠而设计</span>
    <span class="rule"></span><span>__PAGE__ / __TOTAL__</span></div>
</div>
<div class="right"><div class="bg"></div><div class="veil"></div>__RIGHT__</div>
</div></body></html>"""

LAYOUT = {
    "single": dict(shot_h="830px", gap="0px", flexdir="row"),
    "pair-vertical": dict(shot_h="760px", gap="44px", flexdir="row"),
    "pair-stack": dict(shot_h="470px", gap="20px", flexdir="column"),
    "features": dict(shot_h="0px", gap="0px", flexdir="row"),
}


def build_html(cfg, paths, icon_uri, page, total):
    c = P.DARK if cfg["dark"] else P.LIGHT
    uris = ["data:image/jpeg;base64," + base64.b64encode(p.read_bytes()).decode()
            for p in paths]
    lay = LAYOUT[cfg["layout"]]

    if cfg["layout"] == "features":
        rows = "".join(
            '<div class="feature"><div class="num">%02d</div>'
            '<div><b>%s</b><span>%s</span></div></div>' % (i, title, desc)
            for i, (title, desc) in enumerate(cfg["features"], 1))
        right = '<div class="features">%s</div>' % rows
    else:
        frames = []
        for u in uris:
            cols = ""
            if cfg["columns"]:
                cells = "".join(
                    '<div class="col" style="flex:%s 1 0">%s</div>' % (ratio, label)
                    for ratio, label in cfg["columns"])
                cols = '<div class="cols">%s</div>' % cells
            frames.append('<div class="shotwrap">%s<div class="shot">'
                          '<img src="%s" alt=""></div></div>' % (cols, u))
        right = '<div class="frames">%s</div>' % "".join(frames)

    tags = "".join('<div class="tag">%s</div>' % t for t in cfg["tags"])
    pairs = {
        "__BG1__": c["bg1"], "__BG2__": c["bg2"], "__INK__": c["ink"],
        "__MUTED__": c["muted"], "__ACCENT__": c["accent"],
        "__CHIP__": c["chip"], "__CHIP_LINE__": c["chip_line"],
        "__SHADOW__": c["shadow"],
        "__BRIGHT__": ("0.86" if cfg["layout"] == "features" else
                       ("0.62" if cfg["dark"] else "1.12")),
        "__VEIL__": ("linear-gradient(90deg,rgba(8,18,32,.44),rgba(8,18,32,.12))"
                     if cfg["layout"] == "features" else
                     ("linear-gradient(90deg,rgba(8,18,32,.62),rgba(8,18,32,.30))"
                      if cfg["dark"] else
                      "linear-gradient(90deg,rgba(244,249,255,.58),rgba(226,238,255,.28))")),
        "__FRAME_LINE__": ("rgba(255,255,255,.18)" if cfg["dark"]
                           else "rgba(20,60,120,.28)"),
        "__BG__": uris[0], "__ICON__": icon_uri,
        "__KICKER__": cfg["kicker"], "__HEADLINE__": cfg["headline"],
        "__SUB__": cfg["sub"], "__TAGS__": tags,
        "__PAGE__": "%02d" % page, "__TOTAL__": "%02d" % total,
        "__RIGHT__": right,
        "__SHOT_H__": lay["shot_h"], "__GAP__": lay["gap"],
        "__FLEXDIR__": lay["flexdir"],
    }
    html = TEMPLATE
    for key, value in pairs.items():
        html = html.replace(key, value)
    return html


def render(ws, html_path, out_path):
    ws.call("Page.navigate", {"url": html_path.as_uri()})
    time.sleep(1.2)
    ws.call("Emulation.setDeviceMetricsOverride",
            {"width": W, "height": H, "deviceScaleFactor": 1, "mobile": False})
    time.sleep(0.4)
    res = ws.call("Page.captureScreenshot", {
        "format": "jpeg", "quality": 92, "captureBeyondViewport": True,
        "clip": {"x": 0, "y": 0, "width": W, "height": H, "scale": 1}})
    data = base64.b64decode(res["data"])
    dim = P.image_size(data, ".jpg")
    if dim != (W, H):
        raise RuntimeError("输出不是 %dx%d：%r (%s)" % (W, H, dim, out_path.name))
    if len(data) > MAX_BYTES:
        raise RuntimeError("输出超过 5MB：%s (%d KB)" % (out_path.name, len(data) // 1024))
    out_path.write_bytes(data)
    return len(data)


def archive_old():
    """根目录旧成品挪进 _中间素材/，保证上传集合只含本次生成的 10 张。"""
    VERT_BACKUP.mkdir(parents=True, exist_ok=True)
    PLAIN_BACKUP.mkdir(parents=True, exist_ok=True)
    for pattern, target in (("商店海报_*.png", VERT_BACKUP),
                            ("商店截图_*.jpg", PLAIN_BACKUP)):
        moved = 0
        for p in sorted(OUT.glob(pattern)):
            dst = target / p.name
            if dst.exists():
                dst.unlink()
            shutil.move(str(p), str(dst))
            moved += 1
        if moved:
            print("已归档 %d 张旧图到 %s" % (moved, target))


def main():
    if not RAW.is_dir():
        raise RuntimeError("真机截图目录不存在：%s" % RAW)
    if not pathlib.Path(P.CHROME).exists():
        raise RuntimeError("Chrome not found: %s" % P.CHROME)
    if len(ITEMS) > P.MAX_COUNT:
        raise RuntimeError("输出 %d 张超过当期上限 %d 张" % (len(ITEMS), P.MAX_COUNT))
    OUT.mkdir(parents=True, exist_ok=True)
    TMP.mkdir(exist_ok=True)
    archive_old()

    icon_uri = "data:image/png;base64," + base64.b64encode(P.ICON.read_bytes()).decode()
    tmp_html = TMP / "store_screenshot_render.html"
    proc, ws = P.launch()
    try:
        for page, cfg in enumerate(ITEMS, 1):
            paths = [raw(i) for i in cfg["ids"]]
            html = build_html(cfg, paths, icon_uri, page, len(ITEMS))
            tmp_html.write_text(html, encoding="utf-8")
            size = render(ws, tmp_html, OUT / cfg["file"])
            print("横版 %-36s %4d x %4d  %4d KB  %s" %
                  (cfg["file"], W, H, size // 1024, cfg["layout"]))
    finally:
        proc.terminate()

    print("\n上传目录:", OUT)
    errors = P.check_upload_set()
    if errors:
        for e in errors:
            print("  FAIL", e)
        raise RuntimeError("上传集合规格校验失败")
    print("上传集合规格校验通过（全部横向 16:9 / 1920x1080 / 体积达标）。")


if __name__ == "__main__":
    if "--check" in sys.argv[1:]:
        problems = P.check_upload_set()
        if problems:
            for item in problems:
                print("  FAIL", item)
            raise SystemExit(1)
        print("校验通过：上传集合同方向、比例与最低尺寸合规、体积达标。")
    else:
        main()
