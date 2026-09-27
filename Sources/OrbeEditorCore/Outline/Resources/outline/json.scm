; 出どころ: Zed（https://github.com/zed-industries/zed）crates/grammars/src/json/outline.scm
;   commit bda9c0bd43a8d235d82adb01ea5bc875b861ecfc
; ライセンス: GPL-3.0-or-later（Zed Industries, Inc.）
; 手直し（2026-09）: VS Code の JSON（vscode-json-languageservice の findDocumentSymbols2）に合わせた。種類を足し、エスケープを含むキーと
;   空のキー（名前は `""`）を足した。配列の要素はどの値も item にし、@name を付けない（取り出しの JSON 側が、配列の中での
;   番号を名前にする）。

(pair
  key: (string
    [
      (string_content)
      (escape_sequence)
    ]+ @name)
  (#set! kind "key")) @item

(pair
  key: (string) @name
  (#set! kind "key")) @item

(array
  [
    (object)
    (array)
    (string)
    (number)
    (true)
    (false)
    (null)
  ] @item
  (#set! kind "key"))
