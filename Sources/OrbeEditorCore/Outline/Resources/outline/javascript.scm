; 出どころ: Zed（https://github.com/zed-industries/zed）crates/grammars/src/javascript/outline.scm
;   commit bda9c0bd43a8d235d82adb01ea5bc875b861ecfc
; ライセンス: GPL-3.0-or-later（Zed Industries, Inc.）
; 手直し: VS Code の JavaScript（tsserver の navtree）に合わせて組み直した。typescript.scm と同じ組み方から TypeScript
;   専用の節（interface・enum・type・namespace・abstract・引数のプロパティ）を外し、クラスのフィールドを
;   `field_definition` で取った。宣言の語と修飾子を名前から外し、種類を足した。変数は深さを問わず出し、getter / setter・
;   `export default`・呼び出しに渡した関数（tsserver の「… callback」）を足した。

; 型
(class_declaration
  name: (_) @name
  (#set! kind "class")) @item

; 関数
(function_declaration
  name: (_) @name
  (#set! kind "function")) @item

(generator_function_declaration
  name: (_) @name
  (#set! kind "function")) @item

; `export default` の名の無い値は `default`
(export_statement
  "default" @name
  value: (class)
  (#set! kind "class")) @item

(export_statement
  "default" @name
  value: [
    (function_expression)
    (arrow_function)
  ]
  (#set! kind "function")) @item

(export_statement
  "default" @name
  value: (_)
  (#set! kind "variable")) @item

; 呼び出しに渡した関数（`describe("x", () => {})` など）。名は呼ぶ式と、最初の引数が文字列ならその文字列。
(arguments
  (function_expression
    name: (_) @name) @item
  (#set! kind "function"))

(call_expression
  function: [
    (identifier)
    (member_expression)
  ] @name
  arguments: (arguments
    .
    (string) @name
    [
      (arrow_function)
      (function_expression)
    ] @item)
  (#set! kind "function"))

(call_expression
  function: [
    (identifier)
    (member_expression)
  ] @name
  arguments: (arguments
    [
      (arrow_function)
      (function_expression)
    ] @item)
  (#set! kind "function"))

; クラスの中身
(class_body
  (method_definition
    name: (property_identifier) @name
    (#eq? @name "constructor")) @item
  (#set! kind "constructor"))

(class_body
  (method_definition
    [
      "get"
      "set"
    ]
    name: (_) @name) @item
  (#set! kind "property"))

(class_body
  (method_definition
    name: (_) @name) @item
  (#set! kind "method"))

(field_definition
  property: (_) @name
  (#set! kind "property")) @item

; オブジェクトの中身（どこにあっても）
(object
  (method_definition
    [
      "get"
      "set"
    ]
    name: (_) @name) @item
  (#set! kind "property"))

(object
  (method_definition
    name: (_) @name) @item
  (#set! kind "method"))

(pair
  key: (_) @name
  value: [
    (arrow_function)
    (function_expression)
  ]
  (#set! kind "method")) @item

(pair
  key: (_) @name
  (#set! kind "property")) @item

(object
  (shorthand_property_identifier) @name @item
  (#set! kind "property"))

(object
  (spread_element
    (identifier) @name) @item
  (#set! kind "property"))

; 変数（深さを問わない）
(variable_declarator
  name: (identifier) @name
  (#set! kind "variable")) @item

(variable_declarator
  name: (object_pattern
    [
      (shorthand_property_identifier_pattern) @name @item
      (pair_pattern
        value: (identifier) @name @item)
      (pair_pattern
        value: (assignment_pattern
          left: (identifier) @name @item))
      (object_assignment_pattern
        left: (shorthand_property_identifier_pattern) @name @item)
      (rest_pattern
        (identifier) @name @item)
    ])
  (#set! kind "variable"))

(variable_declarator
  name: (array_pattern
    [
      (identifier) @name @item
      (assignment_pattern
        left: (identifier) @name @item)
      (rest_pattern
        (identifier) @name @item)
    ])
  (#set! kind "variable"))

(for_in_statement
  kind: _
  left: (identifier) @name @item
  (#set! kind "variable"))

(catch_clause
  parameter: (identifier) @name @item
  (#set! kind "variable"))
