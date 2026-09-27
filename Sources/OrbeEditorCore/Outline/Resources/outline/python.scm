; 出どころ: Zed（https://github.com/zed-industries/zed）crates/grammars/src/python/outline.scm
;   commit bda9c0bd43a8d235d82adb01ea5bc875b861ecfc
; ライセンス: GPL-3.0-or-later（Zed Industries, Inc.）
; 手直し（2026-09）: VS Code の Python（Pylance / pyright の documentSymbol）に合わせて組み直した。宣言の語（class / def / async）を
;   名前から外し、種類を足し、クラスの本体の def を method（@property 等は property）に分けた。デコレータの付いた定義は
;   デコレータから範囲にした。変数（モジュール・クラス・関数の中の代入と for の変数、全部大文字は constant）・
;   引数（self / cls / _ を除く）・type 文を足した。

; クラス
(decorated_definition
  definition: (class_definition
    name: (identifier) @name)
  (#set! kind "class")) @item

(module
  (class_definition
    name: (identifier) @name) @item
  (#set! kind "class"))

(block
  (class_definition
    name: (identifier) @name) @item
  (#set! kind "class"))

; クラスの本体の def は method。@property などは property。
(class_definition
  body: (block
    (decorated_definition
      (decorator
        [
          (identifier)
          (attribute)
        ] @_decorator)
      definition: (function_definition
        name: (identifier) @name)) @item)
  (#match? @_decorator "^(property|cached_property|functools[.]cached_property|.*[.](setter|getter|deleter))$")
  (#set! kind "property"))

(class_definition
  body: (block
    (decorated_definition
      definition: (function_definition
        name: (identifier) @name)) @item)
  (#set! kind "method"))

(class_definition
  body: (block
    (function_definition
      name: (identifier) @name) @item)
  (#set! kind "method"))

; それ以外の def は function
(decorated_definition
  definition: (function_definition
    name: (identifier) @name)
  (#set! kind "function")) @item

(module
  (function_definition
    name: (identifier) @name) @item
  (#set! kind "function"))

(block
  (function_definition
    name: (identifier) @name) @item
  (#set! kind "function"))

(type_alias_statement
  left: (type
    (identifier) @name)
  (#set! kind "type")) @item

; 変数（全部大文字の名は constant）
(assignment
  left: (identifier) @name @item
  (#match? @name "^[0-9_]*[A-Z][A-Z0-9_]*$")
  (#set! kind "constant"))

(assignment
  left: (identifier) @name @item
  (#not-eq? @name "_")
  (#set! kind "variable"))

(assignment
  left: [
    (pattern_list
      (identifier) @name @item)
    (tuple_pattern
      (identifier) @name @item)
  ]
  (#not-eq? @name "_")
  (#set! kind "variable"))

(for_statement
  left: (identifier) @name @item
  (#not-eq? @name "_")
  (#set! kind "variable"))

(for_statement
  left: [
    (pattern_list
      (identifier) @name @item)
    (tuple_pattern
      (identifier) @name @item)
  ]
  (#not-eq? @name "_")
  (#set! kind "variable"))

; 引数（self / cls / _ を除く）
(function_definition
  parameters: (parameters
    [
      (identifier) @name @item
      (typed_parameter
        .
        (identifier) @name @item)
      (default_parameter
        name: (identifier) @name @item)
      (typed_default_parameter
        name: (identifier) @name @item)
      (list_splat_pattern
        (identifier) @name @item)
      (dictionary_splat_pattern
        (identifier) @name @item)
      (typed_parameter
        [
          (list_splat_pattern
            (identifier) @name @item)
          (dictionary_splat_pattern
            (identifier) @name @item)
        ])
    ])
  (#not-any-of? @name "self" "cls" "_")
  (#set! kind "variable"))
