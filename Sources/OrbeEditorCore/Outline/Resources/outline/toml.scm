; 出どころ: zed-extensions/toml（https://github.com/zed-extensions/toml）languages/toml/outline.scm
;   commit 302e1bfc0abbbc3216c495557c162e18405636e4
; ライセンス: Apache-2.0（Copyright 2022-2025 Zed Industries, Inc.）
; 手直し: 種類を足した（テーブルは module、キーは key）。キーの節を種類で名指した。

(table
  "["
  [
    (bare_key)
    (quoted_key)
    (dotted_key)
  ] @name
  "]"
  (#set! kind "module")) @item

(table_array_element
  "[["
  [
    (bare_key)
    (quoted_key)
    (dotted_key)
  ] @name
  "]]"
  (#set! kind "module")) @item

(pair
  [
    (bare_key)
    (quoted_key)
    (dotted_key)
  ] @name
  "="
  (#set! kind "key")) @item
