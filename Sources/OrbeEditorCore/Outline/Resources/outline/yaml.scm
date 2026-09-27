; 出どころ: Zed（https://github.com/zed-industries/zed）crates/grammars/src/yaml/outline.scm
;   commit bda9c0bd43a8d235d82adb01ea5bc875b861ecfc
; ライセンス: GPL-3.0-or-later（Zed Industries, Inc.）
; 手直し: 種類を足し、値を名前の後ろに付ける @context を外した。キーはプレーンな字に加えて引用符つき・数などの字も取り、
;   フローの mapping（`{ a: 1 }`）の組も足した。

(block_mapping_pair
  key: (flow_node
    [
      (plain_scalar)
      (double_quote_scalar)
      (single_quote_scalar)
    ] @name)
  (#set! kind "key")) @item

(flow_pair
  key: (flow_node
    [
      (plain_scalar)
      (double_quote_scalar)
      (single_quote_scalar)
    ] @name)
  (#set! kind "key")) @item
