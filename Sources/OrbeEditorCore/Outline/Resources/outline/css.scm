; 出どころ: Zed（https://github.com/zed-industries/zed）crates/grammars/src/css/outline.scm
;   commit bda9c0bd43a8d235d82adb01ea5bc875b861ecfc
; ライセンス: GPL-3.0-or-later（Zed Industries, Inc.）
; 手直し（2026-09）: VS Code の CSS（vscode-css-languageservice の findDocumentSymbols2）に合わせた。種類を足し、`@import` を外し、
;   `@keyframes` と `@font-face` を足した（`@keyframes` は接頭辞の付いたものも、取り出しの CSS 側が `@keyframes 名前` にする）。rule_set の @name は selectors の節を丸ごと取る（取り出しの CSS 側が、カンマで
;   並んだセレクタを 1 つずつ別のシンボルにする）。`@media` の名前は `@media` と問い合わせの字（カンマを含む）。

(rule_set
  (selectors) @name
  (#set! kind "selector")) @item

(media_statement
  "@media" @name
  [
    (binary_query)
    (feature_query)
    (keyword_query)
    (parenthesized_query)
    (selector_query)
    (unary_query)
    ","
  ]* @name
  (#set! kind "module")) @item

(keyframes_statement
  (keyframes_name) @name
  (#set! kind "selector")) @item

(at_rule
  (at_keyword) @name
  (#eq? @name "@font-face")
  (#set! kind "selector")) @item
