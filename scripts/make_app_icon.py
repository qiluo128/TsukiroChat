#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
生成 Android 应用图标。

之前一直是 Flutter 的默认图标（蓝色 Flutter logo），这是最显眼的"没打磨"。

## 设计

  - 背景：靛蓝→紫的竖向渐变（和 App 主色 #6366F1 同族）
  - 前景：白色对话气泡 + 三个点（"正在输入"）

## 为什么要生成两套

Android 8+ 用**自适应图标**：系统会把前景和背景分层，
然后按厂商的喜好裁成圆形/方形/水滴形。所以：

  - `ic_launcher.png` —— 老系统的完整图标（已经是成品，不裁）
  - `ic_launcher_foreground.png` + `ic_launcher_background.png` + XML
    —— 新系统的分层版

**关键点**：自适应图标的前景层画布是 108x108dp，但系统只会保留中间
**72x72dp 的安全区**，外面一圈会被裁掉。所以气泡必须画在中间 2/3 里，
否则在某些启动器上会被切掉一半。这是最常见的自适应图标踩坑点。

用法: python scripts/make_app_icon.py
"""

import os
from PIL import Image, ImageDraw

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES = os.path.join(REPO, "packages", "host_app", "android", "app", "src", "main", "res")

# 与 design_tokens 的主色同族
GRAD_TOP = (99, 102, 241)     # #6366F1
GRAD_BOTTOM = (139, 92, 246)  # #8B5CF6

# 每个密度下的基准尺寸（dp）
DENSITIES = {
    "mipmap-mdpi": 1.0,
    "mipmap-hdpi": 1.5,
    "mipmap-xhdpi": 2.0,
    "mipmap-xxhdpi": 3.0,
    "mipmap-xxxhdpi": 4.0,
}

LAUNCHER_DP = 48      # 传统图标
ADAPTIVE_DP = 108     # 自适应图标画布
SAFE_ZONE = 72 / 108  # 安全区占比


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def gradient(size):
    """竖向渐变背景。"""
    img = Image.new("RGB", (size, size))
    px = img.load()
    for y in range(size):
        color = lerp(GRAD_TOP, GRAD_BOTTOM, y / max(size - 1, 1))
        for x in range(size):
            px[x, y] = color
    return img


def rounded_mask(size, radius_ratio=0.22):
    """圆角方形遮罩（传统图标用）。"""
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, size - 1, size - 1), radius=int(size * radius_ratio), fill=255
    )
    return mask


def draw_bubble(canvas_size, bubble_ratio):
    """
    画对话气泡。

    bubble_ratio 是气泡宽度占画布的比例 —— 自适应图标要传 SAFE_ZONE，
    因为外面一圈会被系统裁掉。
    """
    img = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    w = canvas_size * bubble_ratio
    # 气泡本体的高宽比：稍微扁一点更像对话框
    h = w * 0.72
    left = (canvas_size - w) / 2
    top = (canvas_size - h) / 2 - canvas_size * 0.02

    radius = h * 0.34
    d.rounded_rectangle(
        (left, top, left + w, top + h),
        radius=radius,
        fill=(255, 255, 255, 255),
    )

    # 左下角的小尾巴
    tail_w = w * 0.16
    tail_h = h * 0.28
    tail_x = left + w * 0.22
    tail_y = top + h - 1
    d.polygon(
        [
            (tail_x, tail_y),
            (tail_x + tail_w, tail_y),
            (tail_x + tail_w * 0.15, tail_y + tail_h),
        ],
        fill=(255, 255, 255, 255),
    )

    # 三个点（"正在输入"）——
    # 这是产品语义：这是个聊天应用，而且对方"正在说话"
    dot_r = h * 0.075
    gap = w * 0.19
    cx = left + w / 2
    cy = top + h * 0.48
    for i in (-1, 0, 1):
        x = cx + i * gap
        d.ellipse((x - dot_r, cy - dot_r, x + dot_r, cy + dot_r),
                  fill=GRAD_TOP + (255,))

    return img


def save(img, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path, "PNG", optimize=True)
    return path


def main():
    written = []

    for folder, scale in DENSITIES.items():
        target = os.path.join(RES, folder)

        # ── 传统图标：完整成品，自己带圆角 ──
        legacy_px = int(LAUNCHER_DP * scale)
        bg = gradient(legacy_px)
        bubble = draw_bubble(legacy_px, bubble_ratio=0.62)
        legacy = Image.alpha_composite(bg.convert("RGBA"), bubble)
        legacy.putalpha(rounded_mask(legacy_px))
        written.append(save(legacy, os.path.join(target, "ic_launcher.png")))

        # ── 自适应图标：背景层 + 前景层分开 ──
        adaptive_px = int(ADAPTIVE_DP * scale)
        written.append(
            save(gradient(adaptive_px), os.path.join(target, "ic_launcher_background.png"))
        )
        # 前景层只画在安全区里，否则会被启动器裁掉
        fg = draw_bubble(adaptive_px, bubble_ratio=SAFE_ZONE * 0.86)
        written.append(save(fg, os.path.join(target, "ic_launcher_foreground.png")))

    # ── 自适应图标的 XML ──
    xml = """<?xml version="1.0" encoding="utf-8"?>
<!--
  自适应图标（Android 8+）。

  系统会按厂商喜好把前景裁成圆形/方形/水滴形，所以前景层的内容
  必须落在中间 72/108 的安全区里 —— 见 scripts/make_app_icon.py。

  由脚本生成，改设计请改脚本再重跑，不要手改这里的图。
-->
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@mipmap/ic_launcher_background" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
    <!-- 主题图标（Android 13+）：跟随壁纸配色时用的单色版本 -->
    <monochrome android:drawable="@mipmap/ic_launcher_foreground" />
</adaptive-icon>
"""
    anydpi = os.path.join(RES, "mipmap-anydpi-v26")
    os.makedirs(anydpi, exist_ok=True)
    for name in ("ic_launcher.xml", "ic_launcher_round.xml"):
        with open(os.path.join(anydpi, name), "w", encoding="utf-8") as fh:
            fh.write(xml)
        written.append(os.path.join(anydpi, name))

    print(f"生成了 {len(written)} 个文件：")
    for p in written:
        rel = os.path.relpath(p, RES)
        print(f"  {rel}  ({os.path.getsize(p)} bytes)")


if __name__ == "__main__":
    main()
