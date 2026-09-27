; 出どころ: Zed（https://github.com/zed-industries/zed）crates/grammars/src/rust/outline.scm
;   commit bda9c0bd43a8d235d82adb01ea5bc875b861ecfc
; ライセンス: GPL-3.0-or-later（Zed Industries, Inc.）
; 手直し（2026-09）: VS Code の Rust（rust-analyzer の documentSymbol）に合わせて組み直した。宣言の語と可視性を名前から外し、種類を
;   足した。impl の名前は rust-analyzer と同じく `impl Trait for Type`（語を含む）。fn は self を取れば method、取らなければ
;   function。union を足し、let（rust-analyzer の既定で出さない）は出さない。

(struct_item
  name: (_) @name
  (#set! kind "struct")) @item

(union_item
  name: (_) @name
  (#set! kind "struct")) @item

(enum_item
  name: (_) @name
  (#set! kind "enum")) @item

(enum_variant
  name: (_) @name
  (#set! kind "enumMember")) @item

(field_declaration
  name: (_) @name
  (#set! kind "property")) @item

(trait_item
  name: (_) @name
  (#set! kind "interface")) @item

(impl_item
  "impl" @name
  "!"? @name
  trait: (_)? @name
  "for"? @name
  type: (_) @name
  (#set! kind "module")) @item

(mod_item
  name: (_) @name
  (#set! kind "module")) @item

(type_item
  name: (_) @name
  (#set! kind "type")) @item

(associated_type
  name: (_) @name
  (#set! kind "type")) @item

(const_item
  name: (_) @name
  (#set! kind "constant")) @item

(static_item
  name: (_) @name
  (#set! kind "constant")) @item

(macro_definition
  name: (_) @name
  (#set! kind "function")) @item

; fn は self を取れば method
(function_item
  name: (_) @name
  parameters: (parameters
    (self_parameter))
  (#set! kind "method")) @item

(function_signature_item
  name: (_) @name
  parameters: (parameters
    (self_parameter))
  (#set! kind "method")) @item

(function_item
  name: (_) @name
  (#set! kind "function")) @item

(function_signature_item
  name: (_) @name
  (#set! kind "function")) @item
