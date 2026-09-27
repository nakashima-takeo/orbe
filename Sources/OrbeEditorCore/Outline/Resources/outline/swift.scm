; 出どころ: tree-sitter-swift（https://github.com/alex-pinkus/tree-sitter-swift）queries/outline.scm
;   commit 31d17fe7e818a2048c808b5c6fdc2dc792f4f5b5（tag 0.7.3-with-generated-files）
; ライセンス: MIT（Copyright (c) 2021 alex-pinkus）
; 手直し: VS Code の Swift（sourcekit-lsp の documentSymbol）に合わせて組み直した。宣言の語（class / func / var）を名前から外し、
;   種類を足し、関数とメソッド・プロパティと変数をパターンで分け、関数の中の変数を外した。enum の case・typealias・
;   associatedtype・型引数・deinit・macro を足し、subscript を外した（sourcekit-lsp が出さない）。
;   関数・init の名前は語（`init`）か関数名だけを取り、引数ラベルは取り出しの Swift 側が item の直下の parameter から組む。

; 型
(class_declaration
  declaration_kind: "class"
  name: (_) @name
  (#set! kind "class")) @item

(class_declaration
  declaration_kind: "actor"
  name: (_) @name
  (#set! kind "class")) @item

(class_declaration
  declaration_kind: "struct"
  name: (_) @name
  (#set! kind "struct")) @item

(class_declaration
  declaration_kind: "enum"
  name: (_) @name
  (#set! kind "enum")) @item

(class_declaration
  declaration_kind: "extension"
  name: (_) @name
  (#set! kind "module")) @item

(protocol_declaration
  name: (_) @name
  (#set! kind "interface")) @item

(typealias_declaration
  name: (type_identifier) @name
  (#set! kind "type")) @item

(associatedtype_declaration
  name: (type_identifier) @name
  (#set! kind "type")) @item

(type_parameters
  (type_parameter
    (type_identifier) @name) @item
  (#set! kind "type"))

; 型の本体の中の関数はメソッド。それ以外（トップレベル・関数の中）は関数。
(class_body
  (function_declaration
    "func"
    .
    _ @name) @item
  (#set! kind "method"))

(enum_class_body
  (function_declaration
    "func"
    .
    _ @name) @item
  (#set! kind "method"))

(protocol_body
  (protocol_function_declaration
    "func"
    .
    _ @name) @item
  (#set! kind "method"))

(function_declaration
  "func"
  .
  _ @name
  (#set! kind "function")) @item

(macro_declaration
  (simple_identifier) @name
  (#set! kind "function")) @item

(init_declaration
  "init" @name
  (#set! kind "constructor")) @item

(deinit_declaration
  "deinit" @name
  (#set! kind "constructor")) @item

; 型の本体のプロパティと、トップレベルの変数。関数の中の変数は出さない。
(class_body
  (property_declaration
    name: (pattern) @name) @item
  (#set! kind "property"))

(enum_class_body
  (property_declaration
    name: (pattern) @name) @item
  (#set! kind "property"))

(protocol_body
  (protocol_property_declaration
    name: (pattern
      bound_identifier: (_) @name)) @item
  (#set! kind "property"))

(source_file
  (property_declaration
    name: (pattern) @name) @item
  (#set! kind "variable"))

; enum の case は 1 つずつ（`case stop, reset` は 2 つ）。
(enum_entry
  name: (simple_identifier) @name @item
  (#set! kind "enumMember"))