; 出どころ: Zed（https://github.com/zed-industries/zed）extensions/html/languages/html/outline.scm
;   commit bda9c0bd43a8d235d82adb01ea5bc875b861ecfc
; ライセンス: Apache-2.0（Copyright 2022 - 2025 Zed Industries, Inc.）
; 手直し: VS Code の HTML（vscode-html-languageservice の findDocumentSymbols2）に合わせた。種類を足し、自己終了タグの要素と
;   script / style の要素を足した。@name はタグ名だけ（取り出しの HTML 側が、item の最初の子のタグの属性から
;   `tag#id.class1.class2` にする）。

(element
  (start_tag
    (tag_name) @name)
  (#set! kind "element")) @item

(element
  (self_closing_tag
    (tag_name) @name)
  (#set! kind "element")) @item

(script_element
  (start_tag
    (tag_name) @name)
  (#set! kind "element")) @item

(style_element
  (start_tag
    (tag_name) @name)
  (#set! kind "element")) @item
