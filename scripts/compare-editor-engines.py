#!/usr/bin/env python3
"""今の面（STTextView）と新しい面（Metal）で撮った同じ場面の絵を、本体（行番号の列｜本文｜俯瞰）の区画で画素ごとに比べる。

gallery の `editor_code*.png` と `editor_code_metal*.png`、flow の `editor_<名前>_NN_<手順>.png` と
`editor_<名前>_metal_NN_<手順>.png` を組にする。RGB と α は別々に比べる（RGBA のまま差を取ると α しか見ない）。
組ごとに、本体の区画（行番号の列・本文・横スクロールバー・ミニマップ・縦スクロールバー）ごとの差の最大と「1 段を超える画素」「8 段を超える
画素」の数を要約に書き、差を 16 倍にした絵（RGB と α を
横に並べる）を出力先に置く——丸点と角の丸い印の縁は描き方の違いで数段ずれるので、数でなく絵を見る。

使い方: scripts/compare-editor-engines.py [出力先（既定 .preview/e5-compare）]
先に gallery（ORBE_GALLERY=1）と flow（ORBE_FLOWS=1）を撮っておく。
"""

import pathlib
import re
import sys

from PIL import Image, ImageChops

ROOT = pathlib.Path(__file__).resolve().parent.parent
PREVIEW = ROOT / ".preview"
# 本体の左上（pt）。レール 36 + hairline 1 + サイドバー 240 + hairline 1、ファイルタブ行 28 + hairline 1 + パンくず 20。
BODY = (278, 49)
SCALE = 2
# 幅 1000pt・高さ 480pt の場面の本体の区画（pt。左・上・右・下）: 行番号の列 69、ミニマップは VS Code の式で 83、縦スクロール
# バー 14、本文の区画の下端の横スクロールバー 12（新しい面だけにある）。
REGIONS = [
    ("行番号の列", (278, 49, 347, 480)),
    ("本文", (347, 49, 903, 468)),
    ("横スクロールバー", (347, 468, 903, 480)),
    ("ミニマップ", (903, 49, 986, 480)),
    ("縦スクロールバー", (986, 49, 1000, 480)),
]


def pairs():
    gallery = PREVIEW / "gallery"
    for suffix in ["", "_light"]:
        old = gallery / f"editor_code{suffix}.png"
        new = gallery / f"editor_code_metal{suffix}.png"
        if old.exists() and new.exists():
            yield f"editor_code{suffix}", old, new
    flows = PREVIEW / "flows"
    for new in sorted(flows.glob("editor_*_metal_*.png")):
        match = re.match(r"(editor_.+)_metal_(\d\d_.+)\.png", new.name)
        if not match:
            continue
        old = flows / f"{match.group(1)}_{match.group(2)}.png"
        if old.exists():
            yield f"{match.group(1)}_{match.group(2)}", old, new


def channels(image):
    rgba = image.convert("RGBA")
    return rgba.convert("RGB"), rgba.getchannel("A")


def count_over(diff, level):
    """どれかの成分の差が `level` 段を超える画素の数。"""
    if diff.mode == "RGB":
        r, g, b = diff.split()
        diff = ImageChops.lighter(ImageChops.lighter(r, g), b)
    return sum(diff.histogram()[level + 1 :])


def compare(name, old_path, new_path, out):
    old = Image.open(old_path)
    new = Image.open(new_path)
    box = (BODY[0] * SCALE, BODY[1] * SCALE, old.width, old.height)
    old_rgb, old_alpha = channels(old.crop(box))
    new_rgb, new_alpha = channels(new.crop(box))
    rgb = ImageChops.difference(old_rgb, new_rgb)
    alpha = ImageChops.difference(old_alpha, new_alpha)
    amplify = lambda value: min(255, value * 16)
    strip = Image.new("RGB", (rgb.width * 2, rgb.height))
    strip.paste(rgb.point(amplify), (0, 0))
    strip.paste(alpha.point(amplify).convert("RGB"), (rgb.width, 0))
    strip.save(out / f"{name}.diff.png")
    cells = []
    for _, (left, top, right, bottom) in REGIONS:
        area = tuple(
            (value - origin) * SCALE
            for value, origin in zip((left, top, right, bottom), BODY + BODY)
        )
        part = rgb.crop(area)
        worst = max(high for _, high in part.getextrema())
        cells.append(f"{worst} / {count_over(part, 1)} / {count_over(part, 8)}")
    return f"| {name} | " + " | ".join(cells) + f" | {alpha.getextrema()[1]} / {count_over(alpha, 1)} |"


def main():
    out = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else PREVIEW / "e5-compare"
    out.mkdir(parents=True, exist_ok=True)
    rows = [compare(name, old, new, out) for name, old, new in pairs()]
    summary = "\n".join(
        [
            "区画ごとに「RGB の最大の差 / 1 段を超える画素 / 8 段を超える画素」、α は「最大の差 / 1 段を超える画素」。",
            "",
            "| 場面 | " + " | ".join(label for label, _ in REGIONS) + " | α |",
            "|---" * (len(REGIONS) + 2) + "|",
            *rows,
        ]
    )
    (out / "summary.md").write_text(summary + "\n")
    print(summary)


if __name__ == "__main__":
    main()
