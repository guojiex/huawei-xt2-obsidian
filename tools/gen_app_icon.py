#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""生成 HarmonyOS 分层图标（曜石笔记 / 几何水晶）

产出：
  AppScope/resources/base/media/{background,foreground}.png    1024x1024
  entry/src/main/resources/base/media/{background,foreground}.png 1024x1024
  entry/src/main/resources/base/media/startIcon.png            152x152

用法：python tools/gen_app_icon.py
依赖：Pillow（pip install Pillow）
"""

import math
import os

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SS = 3                      # 超采样倍数，降采样后得到抗锯齿边缘
N = 1024 * SS               # 超采样画布边长
HALF = N / 2.0

# ---- 配色：紫黑曜石 ----
BG_INNER = (59, 30, 110)     # 背景径向渐变中心 #3B1E6E
BG_OUTER = (21, 10, 40)      # 背景径向渐变边缘 #150A28
FACE_TOP_L_TOP = (205, 186, 255)   # 左上受光面（最亮）
FACE_TOP_L_BOT = (139, 92, 246)
FACE_TOP_R_TOP = (139, 92, 246)    # 右上受光面
FACE_TOP_R_BOT = (88, 28, 205)
FACE_BOT_L_TOP = (82, 34, 158)     # 左下背光面
FACE_BOT_L_BOT = (48, 15, 100)
FACE_BOT_R_TOP = (54, 18, 124)     # 右下背光面（最暗）
FACE_BOT_R_BOT = (34, 10, 74)
EDGE_HIGHLIGHT = (232, 224, 255, 210)
EDGE_RIM = (222, 210, 255, 110)

ROT_DEG = -10                # 整体倾斜，让晶体不那么呆板


def rot(p, deg, cx, cy):
    a = math.radians(deg)
    x, y = p[0] - cx, p[1] - cy
    return (cx + x * math.cos(a) - y * math.sin(a),
            cy + x * math.sin(a) + y * math.cos(a))


def lerp(c1, c2, t):
    return tuple(int(round(a + (b - a) * t)) for a, b in zip(c1, c2))


def fill_tri_gradient(draw, pts, c_top, c_bot):
    """按 y 方向线性渐变填充三角形（扫描线，逐行填色）"""
    ys = [p[1] for p in pts]
    y0, y1 = min(ys), max(ys)
    span = y1 - y0
    for y in range(int(math.floor(y0)), int(math.ceil(y1)) + 1):
        t = 0.0 if span == 0 else (y - y0) / span
        col = lerp(c_top, c_bot, t)
        xs = []
        for i in range(3):
            x1, y1_ = pts[i]
            x2, y2_ = pts[(i + 1) % 3]
            if (y1_ <= y < y2_) or (y2_ <= y < y1_):
                xs.append(x1 + (x2 - x1) * (y - y1_) / (y2_ - y1_))
        if len(xs) >= 2:
            draw.line([(min(xs), y), (max(xs), y)], fill=col, width=1)


def crystal_points(scale=1.0):
    """双锥晶体投影：上、右、下、左四个顶点 + 中心；整体旋转并缩放"""
    h, w = 0.325 * N, 0.185 * N      # 半高 / 半宽，控制在中心 66% 安全区内
    base = [(HALF, HALF - h), (HALF + w, HALF),
            (HALF, HALF + h), (HALF - w, HALF)]
    base = [rot(p, ROT_DEG, HALF, HALF) for p in base]
    if scale != 1.0:
        base = [(HALF + (x - HALF) * scale, HALF + (y - HALF) * scale)
                for x, y in base]
    return base


def make_background():
    """径向渐变背景：先画小图再放大，避免逐像素循环"""
    s = 256
    img = Image.new("RGB", (s, s))
    px = img.load()
    c = (s * 0.5, s * 0.42)
    r_max = s * 0.78
    for y in range(s):
        for x in range(s):
            d = math.hypot(x - c[0], y - c[1]) / r_max
            t = min(1.0, d) ** 1.35
            px[x, y] = lerp(BG_INNER, BG_OUTER, t)
    return img.resize((1024, 1024), Image.LANCZOS)


def make_foreground():
    fg = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    d = ImageDraw.Draw(fg)
    top, right, bottom, left = crystal_points()

    # 底部投影
    shadow = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    scx, scy = HALF, HALF + 0.345 * N
    sd.ellipse([scx - 0.16 * N, scy - 0.026 * N, scx + 0.16 * N, scy + 0.026 * N],
               fill=(12, 4, 26, 130))
    shadow = shadow.filter(ImageFilter.GaussianBlur(0.014 * N))
    fg.alpha_composite(shadow)

    # 四个切面，光来自左上
    fill_tri_gradient(d, [top, left, (HALF, HALF)], FACE_TOP_L_TOP, FACE_TOP_L_BOT)
    fill_tri_gradient(d, [top, (HALF, HALF), right], FACE_TOP_R_TOP, FACE_TOP_R_BOT)
    fill_tri_gradient(d, [left, bottom, (HALF, HALF)], FACE_BOT_L_TOP, FACE_BOT_L_BOT)
    fill_tri_gradient(d, [(HALF, HALF), bottom, right], FACE_BOT_R_TOP, FACE_BOT_R_BOT)

    # 腰线（左右顶点连线）：下锥的折面分割
    d.line([left, right], fill=(30, 8, 66, 120), width=max(1, int(1.4 * SS)))
    # 中轴棱线高光：上段受光亮，下段减弱避免像裂纹
    d.line([top, (HALF, HALF)], fill=EDGE_HIGHLIGHT, width=max(1, int(3.0 * SS)))
    d.line([(HALF, HALF), bottom], fill=(178, 158, 246, 95), width=max(1, int(1.8 * SS)))
    # 受光侧边缘反光：左上棱 + 左侧腰线
    d.line([top, left], fill=EDGE_RIM, width=max(1, int(2.0 * SS)))
    d.line([left, bottom], fill=(196, 181, 253, 70), width=max(1, int(1.8 * SS)))

    return fg.resize((1024, 1024), Image.LANCZOS)


def main():
    bg = make_background()
    fg = make_foreground()

    targets = [
        os.path.join(ROOT, "AppScope", "resources", "base", "media"),
        os.path.join(ROOT, "entry", "src", "main", "resources", "base", "media"),
    ]
    for t in targets:
        os.makedirs(t, exist_ok=True)
        bg.save(os.path.join(t, "background.png"))
        fg.save(os.path.join(t, "foreground.png"))
        print("write", os.path.join(t, "background.png"))
        print("write", os.path.join(t, "foreground.png"))

    # 启动窗口图标 = 背景 + 前景合成
    start = bg.copy().convert("RGBA")
    start.alpha_composite(fg)
    start = start.resize((152, 152), Image.LANCZOS)
    p = os.path.join(targets[1], "startIcon.png")
    start.save(p)
    print("write", p)


if __name__ == "__main__":
    main()
