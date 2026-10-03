; 出どころ: tree-sitter-markdown（https://github.com/tree-sitter-grammars/tree-sitter-markdown）
;   tree-sitter-markdown-inline/queries/injections.scm、v0.5.3（commit f969cd3ae3f9fbd4e43205431d0ae286014c05b5）
; ライセンス: MIT（Copyright (c) 2021 Matthias Deiml）
; 手直し: html_tag を束ねる（injection.combined）。段落（inline の層）の中のタグを 1 本の木で解き、閉じタグを開きタグと
;   対にする——タグごとの木では、閉じタグだけの断片を HTML として解けない。nvim-treesitter・Helix の queries と同じ指定。

((html_tag) @injection.content
  (#set! injection.language "html")
  (#set! injection.combined))

((latex_block) @injection.content
  (#set! injection.language "latex"))
