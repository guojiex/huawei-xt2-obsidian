#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""生成小艺智能体头像（曜石笔记 / 水晶 + 星芒）

沿用 gen_app_icon 的曜石水晶视觉，叠加 AI 星芒，输出单层 PNG。
产出：
  docs/assets/xiaoyi_agent_icon.png    1024x1024
  docs/assets/xiaoyi_agent_icon_512.png 512x512

用法：python tools/gen_agent_icon.py
依赖：Pillow（pip install Pillow）
"""

import math
import os

from PIL import Image, ImageDraw, ImageFilter

from gen_app_icon import make_background, make_foreground

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, "docs", "assets")


def sparkle(draw, cx, cy, r, color, ratio=0.22):
    """四角星芒：长轴 r，短轴 r*ratio"""
    pts = []
    for i in range(8):
        ang = math.pi / 4 * i - math.pi / 2
        rad = r if i % 2 == 0 else r * ratio
        pts.append((cx + rad * math.cos(ang), cy + rad * math.sin(ang)))
    draw.polygon(pts, fill=color)


def main():
    bg = make_background().convert("RGBA")
    fg = make_foreground()

    # 水晶缩小居中，给星芒留呼吸空间
    size = int(1024 * 0.74)
    fg_small = fg.resize((size, size), Image.LANCZOS)
    off = (1024 - size) // 2
    bg.alpha_composite(fg_small, (off, off))

    # 星芒层：先画大图再降采样，边缘柔和
    SS = 3
    layer = Image.new("RGBA", (1024 * SS, 1024 * SS), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    main_r = 0.085 * 1024 * SS
    sparkle(d, (0.735) * 1024 * SS, (0.235) * 1024 * SS, main_r, (238, 231, 255, 255))
    sparkle(d, (0.835) * 1024 * SS, (0.365) * 1024 * SS, main_r * 0.45, (216, 199, 252, 230))
    sparkle(d, (0.245) * 1024 * SS, (0.195) * 1024 * SS, main_r * 0.32, (205, 186, 250, 200))
    glow = layer.filter(ImageFilter.GaussianBlur(6 * SS))
    glow.putalpha(glow.getchannel("A").point(lambda a: int(a * 0.45)))
    layer = Image.alpha_composite(glow, layer)
    layer = layer.resize((1024, 1024), Image.LANCZOS)
    bg.alpha_composite(layer)

    os.makedirs(OUT_DIR, exist_ok=True)
    p1 = os.path.join(OUT_DIR, "xiaoyi_agent_icon.png")
    bg.convert("RGB").save(p1)
    print("write", p1)
    p2 = os.path.join(OUT_DIR, "xiaoyi_agent_icon_512.png")
    bg.convert("RGB").resize((512, 512), Image.LANCZOS).save(p2)
    print("write", p2)


if __name__ == "__main__":
    main()
