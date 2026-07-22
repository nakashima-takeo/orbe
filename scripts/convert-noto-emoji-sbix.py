#!/usr/bin/env python3
"""vendor の NotoColorEmoji.ttf（CBDT/CBLC）を macOS CoreText が読める sbix 形式へ変換する。

CoreText は Google の CBDT ビットマップ絵文字を解釈できない（記述子の取得すら失敗する）。
CBDT も sbix も実体は同じ PNG 群なので、ストライクを sbix テーブルへ詰め替え、
sbix が前提とする glyf/loca を合成すれば CoreText で描ける。

glyf の各グリフには CBDT メトリクス（bearing/width/height を ppem→units 換算）由来の
バウンディングボックスを、面積ゼロの 2 点縮退輪郭で運ぶ（Apple Color Emoji と同じ手法。
輪郭自体は何も塗らない）。完全に空の glyf だと `CTFontGetBoundingRectsForGlyphs` が
零矩形を返し、寸法をこの API から取る描画側（ghostty renderGlyph は 1/4px 未満で
0 サイズ glyph を返す）で絵文字が空白になる。

sbix の originOffsetX/Y は 0 に固定する。CoreText はビットマップを「glyf bbox の左下＋
originOffset」に置く（実測で確定）ため、配置は bbox が一元的に運び、originOffset にも
CBDT bearing を書くと二重適用で縦に半セル級ズレる。

生成物 app/NotoColorEmoji-sbix.ttf はコミットする（ビルドに fonttools を要求しない）。
vendor/ghostty の NotoColorEmoji.ttf 更新時に再実行する:

  python3 -m venv .venv && .venv/bin/pip install fonttools
  .venv/bin/python scripts/convert-noto-emoji-sbix.py
"""

from pathlib import Path

from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib import TTFont, newTable
from fontTools.ttLib.tables._g_l_y_f import Glyph as GlyfGlyph
from fontTools.ttLib.tables.sbixGlyph import Glyph as SbixGlyph
from fontTools.ttLib.tables.sbixStrike import Strike

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "vendor/ghostty/src/font/res/NotoColorEmoji.ttf"
DST = ROOT / "app/NotoColorEmoji-sbix.ttf"


def bbox_glyph(metrics, scale: float) -> GlyfGlyph:
    """CBDT small glyph metrics（px・baseline 基準・BearingY=上端）を font units の
    バウンディングボックスへ換算し、それを対角 2 点の縮退輪郭（面積ゼロ＝何も塗らない）で
    持つ glyf グリフを作る。"""
    x_min = round(metrics.BearingX * scale)
    x_max = round((metrics.BearingX + metrics.width) * scale)
    y_max = round(metrics.BearingY * scale)
    y_min = round((metrics.BearingY - metrics.height) * scale)
    pen = TTGlyphPen(None)
    pen.moveTo((x_min, y_min))
    pen.lineTo((x_max, y_max))
    pen.closePath()
    return pen.glyph()


def main() -> None:
    # recalcTimestamp=False: head.modified に保存時刻を焼き込まず生成物を決定的にする
    # （再実行しても byte 一致し、コミット済み生成物を照合で監査できる）。
    font = TTFont(SRC, recalcTimestamp=False)
    ppem = font["CBLC"].strikes[0].bitmapSizeTable.ppemX
    strike_data = font["CBDT"].strikeData[0]
    scale = font["head"].unitsPerEm / ppem

    sbix = newTable("sbix")
    sbix.version = 1
    sbix.flags = 1
    strike = Strike(ppem=ppem, resolution=72)
    strike.glyphs = {}
    boxes: dict[str, GlyfGlyph] = {}
    for name, rec in strike_data.items():
        rec.ensureDecompiled()
        metrics = rec.metrics
        strike.glyphs[name] = SbixGlyph(
            glyphName=name,
            graphicType="png ",
            imageData=rec.imageData,
            originOffsetX=0,  # 配置は glyf bbox が一元的に運ぶ（docstring 参照）
            originOffsetY=0,
        )
        if metrics.width > 0 and metrics.height > 0:
            boxes[name] = bbox_glyph(metrics, scale)
    sbix.strikes = {ppem: strike}
    font["sbix"] = sbix

    glyf = newTable("glyf")
    glyf.glyphs = {name: boxes.get(name, GlyfGlyph()) for name in font.getGlyphOrder()}
    glyf.glyphOrder = font.getGlyphOrder()
    font["glyf"] = glyf
    font["loca"] = newTable("loca")

    del font["CBDT"]
    del font["CBLC"]
    font.save(DST)
    print(
        f"{DST.name}: {len(strike.glyphs)} glyphs "
        f"({len(boxes)} bboxes), {DST.stat().st_size} bytes"
    )


if __name__ == "__main__":
    main()
