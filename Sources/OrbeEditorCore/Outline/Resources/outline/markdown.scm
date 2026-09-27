; 出どころ: Zed（https://github.com/zed-industries/zed）crates/grammars/src/markdown/outline.scm
;   commit bda9c0bd43a8d235d82adb01ea5bc875b861ecfc
; ライセンス: GPL-3.0-or-later（Zed Industries, Inc.）
; 手直し（2026-09）: VS Code の Markdown に合わせた。種類を足し、section ではなく見出しの節そのものを item にした（入れ子は
;   取り出しの Markdown 側が見出しの段で決める。引用や箇条の中の見出しも段で並ぶ）。印を @context に取る。setext 見出し
;   （下線の見出し）と、字の無い ATX 見出しを足した。

(atx_heading
  .
  (_) @context
  heading_content: (_)? @name
  (#set! kind "heading")) @item

(setext_heading
  heading_content: (paragraph
    (inline) @name)
  (#set! kind "heading")) @item
