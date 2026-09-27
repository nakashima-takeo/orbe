; 出どころ: Orbe の自作
; ライセンス: GPL-3.0-or-later
; 要旨: 関数の定義（`name() {}` と `function name {}`）を function として出す。関数の中の関数は入れ子になる。

(function_definition
  name: (word) @name
  (#set! kind "function")) @item
