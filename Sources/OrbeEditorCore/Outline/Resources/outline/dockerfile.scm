; 出どころ: Orbe の自作
; ライセンス: GPL-3.0-or-later
; 要旨: VS Code の Dockerfile（dockerfile-language-service の DockerSymbols）に合わせ、ファイルの頭のパーサーディレクティブ
;   （`# syntax=…`）とトップレベルの命令を平らに並べる。命令の名前は命令の語（書かれたとおりの字。`run` は `run`）。
;   ONBUILD / HEALTHCHECK の中の命令は出さない。ディレクティブかどうか（頭から空行を挟まずに続くか）と名前は取り出しの
;   Dockerfile 側が決める。

(source_file
  (comment) @item
  (#match? @item "^#[ \t]*[A-Za-z][A-Za-z0-9]*[ \t]*=")
  (#set! kind "property"))

(source_file
  (_
    .
    [
      "ADD"
      "ARG"
      "CMD"
      "COPY"
      "CROSS_BUILD"
      "ENTRYPOINT"
      "ENV"
      "EXPOSE"
      "FROM"
      "HEALTHCHECK"
      "LABEL"
      "MAINTAINER"
      "ONBUILD"
      "RUN"
      "SHELL"
      "STOPSIGNAL"
      "USER"
      "VOLUME"
      "WORKDIR"
    ] @name) @item
  (#set! kind "instruction"))
