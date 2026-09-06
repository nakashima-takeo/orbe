#!/usr/bin/env python3
"""worktree 識別色を oklch から sRGB hex へ写し、Swift の定数表として書き出す。

生成式（色相数・トーンは HUES / TONES が正）:
  index i → tone = TONES[theme][i // HUES]、hue = (i % HUES) * (360 / HUES) + 7

番号（`WorktreeColor.index(forKey:)`）はテーマ共通で、色だけがテーマごとに違う。dark は暗い chrome の
上で光るトーン、light は白い紙面の上で沈むトーンを採る。

oklch → oklab → linear sRGB（Björn Ottosson の行列）→ gamma 符号化 → 8bit 丸め。
一部のチャンネルが sRGB 域外に出るので、CSS Color 4 が規定するガマット写像 binary-search local MINDE
（https://drafts.csswg.org/css-color-4/#GMA-Binary-local-MINDE ・chroma を [0, C] で二分探索し、
クリップ結果との ΔEOK が JND 0.02 未満になる最大 chroma を採る）で落とす。見本 theme.ts が書いている
のは oklch の値そのもので、写像はこの規定に従う。

生成物 Sources/Orbe/DesignSystem/WorktreePalette.swift はコミットする（アプリに色計算を持ち込まない）。
式を変えたら再実行する:

  python3 scripts/gen-worktree-palette.py
"""

import math
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DST = ROOT / "Sources/Orbe/DesignSystem/WorktreePalette.swift"

HUES = 24
HUE_STEP = 360 / HUES
# テーマごとの淡 / 濃 2 トーンの (L, C)。
TONES = {
    "dark": [(0.80, 0.09), (0.64, 0.15)],
    "light": [(0.62, 0.13), (0.48, 0.15)],
}
JND = 0.02
EPSILON = 0.0001


def oklch_to_oklab(l: float, c: float, h_deg: float) -> tuple[float, float, float]:
    h = math.radians(h_deg)
    return l, c * math.cos(h), c * math.sin(h)


def oklab_to_linear_srgb(l: float, a: float, b: float) -> tuple[float, float, float]:
    l_ = l + 0.3963377774 * a + 0.2158037573 * b
    m_ = l - 0.1055613458 * a - 0.0638541728 * b
    s_ = l - 0.0894841775 * a - 1.2914855480 * b
    l3, m3, s3 = l_**3, m_**3, s_**3
    return (
        4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3,
        -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3,
        -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3,
    )


def linear_srgb_to_oklab(r: float, g: float, b: float) -> tuple[float, float, float]:
    l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
    m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
    s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b
    l_, m_, s_ = l ** (1 / 3), m ** (1 / 3), s ** (1 / 3)
    return (
        0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
        1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
        0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_,
    )


def in_gamut(rgb: tuple[float, float, float]) -> bool:
    return all(0 <= c <= 1 for c in rgb)


def clip(rgb: tuple[float, float, float]) -> tuple[float, float, float]:
    return tuple(min(1.0, max(0.0, c)) for c in rgb)


def delta_eok(a: tuple[float, float, float], b: tuple[float, float, float]) -> float:
    return math.dist(a, b)


def to_srgb_linear(l: float, c: float, h: float) -> tuple[float, float, float]:
    """CSS Color 4 の binary-search local MINDE ガマット写像。域内ならそのまま、域外なら chroma を落として写す。"""
    origin = oklab_to_linear_srgb(*oklch_to_oklab(l, c, h))
    if in_gamut(origin):
        return origin
    lo, hi, lo_in_gamut = 0.0, c, True
    current = origin
    clipped = clip(origin)
    if delta_eok(linear_srgb_to_oklab(*clipped), oklch_to_oklab(l, c, h)) < JND:
        return clipped
    while hi - lo > EPSILON:
        chroma = (lo + hi) / 2
        current_lab = oklch_to_oklab(l, chroma, h)
        current = oklab_to_linear_srgb(*current_lab)
        if lo_in_gamut and in_gamut(current):
            lo = chroma
            continue
        clipped = clip(current)
        e = delta_eok(linear_srgb_to_oklab(*clipped), current_lab)
        if e < JND:
            if JND - e < EPSILON:
                return clipped
            lo_in_gamut = False
            lo = chroma
        else:
            hi = chroma
    return clip(current)


def gamma(c: float) -> float:
    return 12.92 * c if c <= 0.0031308 else 1.055 * c ** (1 / 2.4) - 0.055


def hex_of(rgb: tuple[float, float, float]) -> int:
    r, g, b = (round(gamma(c) * 255) for c in rgb)
    return (r << 16) | (g << 8) | b


def palette(theme: str) -> list[int]:
    return [
        hex_of(to_srgb_linear(l, c, i * HUE_STEP + 7))
        for (l, c) in TONES[theme]
        for i in range(HUES)
    ]


def table(name: str, colors: list[int]) -> str:
    rows = [colors[i : i + 8] for i in range(0, len(colors), 8)]
    body = "\n".join("    " + " ".join(f"0x{c:06x}," for c in row) for row in rows)
    return f"  static let {name}: [Int] = [\n{body}\n  ]"


def render(palettes: dict[str, list[int]]) -> str:
    tables = "\n".join(table(theme, colors) for theme, colors in palettes.items())
    return f"""// scripts/gen-worktree-palette.py が生成する。手で編集せず、式を変えたらスクリプトを直して再生成する。

/// worktree 識別色。番号（`WorktreeColor.index(forKey:)`）はテーマ共通で、色だけがテーマごとに違う。
/// 色相 × トーンの oklch を CSS Color 4 の彩度落としで sRGB へ写した hex。
/// 式と色数は scripts/gen-worktree-palette.py の HUES / TONES が正。
enum WorktreePalette {{
  static let count = {len(next(iter(palettes.values())))}
{tables}
}}
"""


def generate() -> str:
    return render({theme: palette(theme) for theme in TONES})


if __name__ == "__main__":
    DST.write_text(generate())
    print(f"wrote {DST}")
