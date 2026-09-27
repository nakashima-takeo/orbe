; 出どころ: Orbe の自作
; ライセンス: GPL-3.0-or-later
; 要旨: VS Code の Dockerfile（dockerfile-language-service の DockerSymbols）に合わせ、トップレベルの命令を平らに並べる。
;   名前は命令の語（書かれたとおりの字。`run` は `run`）。ONBUILD / HEALTHCHECK の中の命令は出さない。

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
