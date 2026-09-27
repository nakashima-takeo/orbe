; 出どころ: Zed（https://github.com/zed-industries/zed）crates/grammars/src/go/outline.scm
;   commit bda9c0bd43a8d235d82adb01ea5bc875b861ecfc
; ライセンス: GPL-3.0-or-later（Zed Industries, Inc.）
; 手直し: VS Code の Go（gopls の documentSymbol）に合わせて組み直した。宣言の語（type / func / const / var）を名前から外し、
;   種類を足した（struct / interface / それ以外の型は class）。メソッドの名前はレシーバの型とメソッド名。関数の中は出さない。
;   const / var と struct のフィールドは、名前が 1 つなら宣言全体、複数なら名前ごとを範囲にした。埋め込みのフィールドと
;   interface に埋め込んだ型を足した。

; 型
(type_spec
  name: (_) @name
  type: (struct_type)
  (#set! kind "struct")) @item

(type_spec
  name: (_) @name
  type: (interface_type)
  (#set! kind "interface")) @item

(type_spec
  name: (_) @name
  (#set! kind "class")) @item

(type_alias
  name: (_) @name
  (#set! kind "class")) @item

; 関数とメソッド。メソッドの名前はレシーバの型とメソッド名（`(*Server).Start` の `*Server` と `Start`）。
(function_declaration
  name: (_) @name
  (#set! kind "function")) @item

(method_declaration
  receiver: (parameter_list
    (parameter_declaration
      type: (_) @name))
  name: (_) @name
  (#set! kind "method")) @item

; トップレベルの const / var。名前が 1 つの宣言は宣言全体、複数なら名前ごと。
(source_file
  (const_declaration
    (const_spec
      name: (identifier) @name @item
      name: (identifier)))
  (#set! kind "constant"))

(source_file
  (const_declaration
    (const_spec
      name: (identifier)
      name: (identifier) @name @item))
  (#set! kind "constant"))

(source_file
  (const_declaration
    [
      (const_spec
        .
        name: (identifier) @name
        .
        type: (_))
      (const_spec
        .
        name: (identifier) @name
        .
        value: (_))
      (const_spec
        .
        name: (identifier) @name .)
    ] @item)
  (#set! kind "constant"))

(source_file
  (var_declaration
    [
      (var_spec
        name: (identifier) @name @item
        name: (identifier))
      (var_spec_list
        (var_spec
          name: (identifier) @name @item
          name: (identifier)))
    ])
  (#set! kind "variable"))

(source_file
  (var_declaration
    [
      (var_spec
        name: (identifier)
        name: (identifier) @name @item)
      (var_spec_list
        (var_spec
          name: (identifier)
          name: (identifier) @name @item))
    ])
  (#set! kind "variable"))

(source_file
  (var_declaration
    [
      (var_spec
        .
        name: (identifier) @name
        .
        type: (_)) @item
      (var_spec
        .
        name: (identifier) @name
        .
        value: (_)) @item
      (var_spec_list
        [
          (var_spec
            .
            name: (identifier) @name
            .
            type: (_))
          (var_spec
            .
            name: (identifier) @name
            .
            value: (_))
        ] @item)
    ])
  (#set! kind "variable"))

; struct のフィールド。名前が 1 つなら宣言全体、複数なら名前ごと。埋め込みは型の名。
(field_declaration
  name: (field_identifier) @name @item
  name: (field_identifier)
  (#set! kind "property"))

(field_declaration
  name: (field_identifier)
  name: (field_identifier) @name @item
  (#set! kind "property"))

(field_declaration
  .
  name: (field_identifier) @name
  .
  type: (_)
  (#set! kind "property")) @item

(field_declaration
  .
  type: [
    (type_identifier) @name
    (qualified_type
      name: (type_identifier) @name)
    (generic_type
      type: [
        (type_identifier) @name
        (qualified_type
          name: (type_identifier) @name)
      ])
  ]
  (#set! kind "property")) @item

; interface の中身
(method_elem
  name: (_) @name
  (#set! kind "method")) @item

(interface_type
  (type_elem
    .
    [
      (type_identifier) @name
      (qualified_type
        name: (type_identifier) @name)
    ] .) @item
  (#set! kind "property"))
