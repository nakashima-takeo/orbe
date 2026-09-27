; 出どころ: Zed（https://github.com/zed-industries/zed）crates/grammars/src/markdown/outline.scm
;   commit bda9c0bd43a8d235d82adb01ea5bc875b861ecfc
; ライセンス: GPL-3.0-or-later（Zed Industries, Inc.）
; 手直し: 種類を足した。名前は VS Code と同じく見出しの印を含める（印を @context に取る）。入れ子は見出しの section の包含で
;   決まる。setext 見出し（下線の見出し）を足した（印の字が無いので名前は見出しの字だけ。この文法では section を作らない）。

(section
  (atx_heading
    .
    (_) @context
    .
    heading_content: (_) @name)
  (#set! kind "heading")) @item

(setext_heading
  heading_content: (_) @name
  (#set! kind "heading")) @item
