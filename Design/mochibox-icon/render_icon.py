#!/usr/bin/env python3
"""麻薯盒 Mochibox · 应用图标生成器（V3 定稿）

几何约束（可复核）：
  内容区 824×824，对角线 1165.3，黄金分割点 P = 824×0.618 = 509.3
  团子圆心沿对角线外推 R，使轮廓恰好经过 P
  → 团子边缘把对角线切成 720.2 : 445.1 = 0.618 : 0.382
  团子占右下，曲率由 R 控制（R 越小越圆、越显年轻）
  咬口 = 单个圆弧：圆心推到轮廓之外，只咬掉一浅弧（苹果 logo 的做法）
"""
import math
import random
from PIL import Image, ImageDraw

SS = 4                      # 超采样
N = 824                     # macOS 图标内容区
CANVAS = 1024               # 最终画布
MARGIN = (CANVAS - N) // 2
R_CORNER = 185.4            # 1024 画布对应的圆角

CREAM = (255, 249, 239)     # 米白底
BROWN = (206, 150, 88)      # 麻薯棕（提亮，避免沉闷）
POWDER = (232, 200, 155)    # 黄豆粉

GOLD = 0.6180339887
MODS = [(2, 0.020, 1.1), (3, 0.014, 2.4), (4, 0.008, 0.3)]

DIAG = math.hypot(N, N)
P = (N * GOLD, N * GOLD)
R = 270.0                                    # 曲率半径：越小越圆
DIAG_UNIT = (P[0] / math.hypot(*P), P[1] / math.hypot(*P))
CENTER = (P[0] + DIAG_UNIT[0] * R, P[1] + DIAG_UNIT[1] * R)   # ≈ (700.2, 700.2)
TH_P = math.atan2(P[1] - CENTER[1], P[0] - CENTER[0])


def modf(t):
    return 1.0 + sum(a * math.cos(m * t + p) for m, a, p in MODS)


def build(bite_r=92, bite_out=0.40, bite_off=0.30, dust=96, seed=31):
    W = N * SS
    img = Image.new("RGBA", (W, W), CREAM + (255,))
    d = ImageDraw.Draw(img)
    cx, cy = CENTER

    steps = 2400
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        r = R * modf(t)
        pts.append(((cx + r * math.cos(t)) * SS, (cy + r * math.sin(t)) * SS))
    d.polygon(pts, fill=BROWN)

    # 单个小圆弧咬口
    tb = TH_P + bite_off
    r_c = R * modf(tb)
    c0x, c0y = cx + r_c * math.cos(tb), cy + r_c * math.sin(tb)
    bx = c0x + math.cos(tb) * bite_r * bite_out
    by = c0y + math.sin(tb) * bite_r * bite_out
    d.ellipse([(bx - bite_r) * SS, (by - bite_r) * SS,
               (bx + bite_r) * SS, (by + bite_r) * SS], fill=CREAM)

    # 撒粉：沿轮廓内侧均匀分布
    rnd = random.Random(seed)
    for k in range(dust):
        t = 2 * math.pi * (k + rnd.uniform(0.05, 0.95)) / dust
        rr = R * modf(t) - rnd.uniform(10, 54)
        x, y = cx + rr * math.cos(t), cy + rr * math.sin(t)
        s = rnd.uniform(1.8, 3.2)
        inside = math.hypot(x - cx, y - cy) <= R * modf(math.atan2(y - cy, x - cx)) - s - 5
        if not inside or math.hypot(x - bx, y - by) < bite_r + s + 6:
            continue
        d.ellipse([(x - s) * SS, (y - s * 0.70) * SS, (x + s) * SS, (y + s * 0.70) * SS], fill=POWDER)

    img = img.resize((N, N), Image.LANCZOS)
    mask = Image.new("L", (N * SS, N * SS), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, N * SS - 1, N * SS - 1], radius=R_CORNER * SS, fill=255)
    mask = mask.resize((N, N), Image.LANCZOS)
    img.putalpha(mask)

    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    canvas.paste(img, (MARGIN, MARGIN), img)
    return canvas, bx, by


if __name__ == "__main__":
    import json
    import os
    import sys

    out = sys.argv[1] if len(sys.argv) > 1 else "."
    os.makedirs(out, exist_ok=True)
    icon, bx, by = build()
    icon.save(f"{out}/mochibox-1024.png")

    iset = f"{out}/Mochibox.iconset"
    os.makedirs(iset, exist_ok=True)
    for sz in (16, 32, 128, 256, 512):
        icon.resize((sz, sz), Image.LANCZOS).save(f"{iset}/icon_{sz}x{sz}.png")
        icon.resize((sz * 2, sz * 2), Image.LANCZOS).save(f"{iset}/icon_{sz}x{sz}@2x.png")

    print(json.dumps({
        "团心": [round(CENTER[0], 1), round(CENTER[1], 1)],
        "半径": R,
        "黄金点": [round(P[0], 1), round(P[1], 1)],
        "上段": round(math.hypot(*P), 1),
        "下段": round(math.hypot(N - P[0], N - P[1]), 1),
        "比值": round(math.hypot(*P) / DIAG, 4),
        "咬口圆心": [round(bx, 1), round(by, 1)],
    }, ensure_ascii=False, indent=2))
