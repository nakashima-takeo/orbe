# Orbe ドロップダウン補完（zsh）。
# Orbe が起こした zsh でのみ env が立つ。ORBE_SOCK / ORBE_PANE 未設定なら全 widget を定義せず no-op。
# $BUFFER/$CURSOR を control.sock 経由で host へ通知し、Tab で host が返す補完後 buffer を zle 変数へ直書きする。
# tmux/ssh 先・bash/fish は env 不達で何も起きない（劣化なしの無効）。

[[ -n $ORBE_SOCK && -n $ORBE_PANE ]] || return 0
[[ -n $_ORBE_COMPLETION_LOADED ]] && return 0
zmodload zsh/net/socket 2>/dev/null || return 0
typeset -g _ORBE_COMPLETION_LOADED=1

typeset -g _ORBE_FD=
typeset -g _ORBE_LAST=
# 既存の Tab バインドをフォールバックとして退避（自分自身は除外して再 source での自己ループを防ぐ）。
typeset -g _ORBE_TAB_FALLBACK=expand-or-complete
if [[ ${${(z)$(bindkey '^I')}[2]} != _orbe_complete ]]; then
  _ORBE_TAB_FALLBACK=${${(z)$(bindkey '^I')}[2]:-expand-or-complete}
fi

# control.sock へ AF_UNIX クライアント接続し fd を確保する（未接続時のみ）。失敗は静かに無効化。
_orbe_connect() {
  [[ -n $_ORBE_FD ]] && return 0
  if zsocket $ORBE_SOCK 2>/dev/null; then
    _ORBE_FD=$REPLY
    return 0
  fi
  _ORBE_FD=
  return 1
}

# 文字列を JSON 文字列リテラルへエスケープ（" \ 改行＋C0）。結果は $REPLY。
# 改行を \n に畳むことで複数行 buffer でも 1 行 JSON に収め、行 framing を壊さない。
_orbe_json_escape() {
  local s=$1 out= i c
  for (( i = 1; i <= ${#s}; i++ )); do
    c=$s[i]
    case $c in
      ('"') out+='\"' ;;
      ('\') out+='\\' ;;
      ($'\n') out+='\n' ;;
      ($'\t') out+='\t' ;;
      ($'\r') out+='\r' ;;
      # 残る C0 制御文字（稀）だけ \uXXXX へ。印字可能文字は fork せずそのまま積む
      # （毎キーストロークで全文字を回すので、ここでの subshell fork を避ける）。
      ([$'\x01'-$'\x1f']) out+=$(printf '\\u%04x' "'$c") ;;
      (*) out+=$c ;;
    esac
  done
  REPLY=$out
}

# JSON 文字列リテラルを元の文字列へ戻す（accept 応答の buffer を zle へ入れる前に）。結果は $REPLY。
_orbe_json_unescape() {
  local s=$1 out= i c n
  local -i len=${#s}
  i=1
  while (( i <= len )); do
    c=$s[i]
    if [[ $c == '\' ]]; then
      (( i++ ))
      n=$s[i]
      case $n in
        (n) out+=$'\n' ;;
        (t) out+=$'\t' ;;
        (r) out+=$'\r' ;;
        (b) out+=$'\b' ;;
        (f) out+=$'\f' ;;
        ('"') out+='"' ;;
        ('\') out+='\' ;;
        ('/') out+='/' ;;
        (u) out+=$(printf "\\u$s[i+1,i+4]"); (( i += 4 )) ;;
        (*) out+=$n ;;
      esac
    else
      out+=$c
    fi
    (( i++ ))
  done
  REPLY=$out
}

# 1 行 JSON を fd へ送る（fire-and-forget）。書込み失敗で fd を捨て次回 init で再接続。
_orbe_send() {
  if ! print -ru$_ORBE_FD -- "$1" 2>/dev/null; then
    _ORBE_FD=
    return 1
  fi
  return 0
}

# 現在の $BUFFER/$CURSOR を completion_update（無応答）で host へ送る。
_orbe_send_update() {
  _orbe_connect || return
  local REPLY
  _orbe_json_escape "$BUFFER"
  _orbe_send \
    "{\"jsonrpc\":\"2.0\",\"method\":\"completion_update\",\"params\":{\"paneId\":$ORBE_PANE,\"buffer\":\"$REPLY\",\"cursor\":$CURSOR}}"
}

# zle-line-init: fd を確保し差分検出をリセットする。
_orbe_line_init() {
  _orbe_connect
  _ORBE_LAST=
}

# zle-line-pre-redraw: $BUFFER/$CURSOR が前回送信値から変化したときだけ update を送る。
_orbe_line_pre_redraw() {
  local cur="$CURSOR:$BUFFER"
  [[ $cur == "$_ORBE_LAST" ]] && return  # RHS をクォート（buffer の glob 文字でパターン誤判定しない）
  _ORBE_LAST=$cur
  _orbe_send_update
}

# zle-line-finish: コマンド確定/中断で popup を消す（completion_end・無応答）。
_orbe_line_finish() {
  [[ -n $_ORBE_FD ]] || return
  _orbe_send "{\"jsonrpc\":\"2.0\",\"method\":\"completion_end\",\"params\":{\"paneId\":$ORBE_PANE}}"
}

# completion_accept を id 付きで送り 1 行応答を読む。advance=true は次トークンへ進む確定（Tab）、
# false は挿入のみの確定（Enter）。result.buffer が非 null なら zle の $BUFFER/$CURSOR を直書換し 0、
# popup 非表示/候補なし/失敗/タイムアウトは何もせず 1（呼び元が各々のフォールバックへ）。
# completion_update が無応答契約なので、この fd から読める行は accept 応答だけ。
_orbe_try_accept() {
  local advance=$1
  _orbe_connect \
    && _orbe_send "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"completion_accept\",\"params\":{\"paneId\":$ORBE_PANE,\"advance\":$advance}}" \
    || return 1
  local line
  IFS= read -r -t 1 -u$_ORBE_FD line || return 1
  [[ -n $line && $line != *'"buffer":null'* ]] || return 1
  [[ $line =~ '"buffer":"((\\.|[^"\\])*)"' ]] || return 1
  local raw=$match[1]
  local REPLY
  _orbe_json_unescape "$raw"
  BUFFER=$REPLY
  if [[ $line =~ '"cursor":([0-9]+)' ]]; then
    CURSOR=$match[1]
  fi
  return 0
}

# Tab: 次トークンへ進む確定（末尾空白付与は insertValue に従う）。不可なら従来 Tab へフォールバック。
_orbe_complete() {
  _orbe_try_accept true || zle "$_ORBE_TAB_FALLBACK"
}

# Return: popup 表示中なら選択候補を末尾空白なしで確定し popup を閉じる（次トークンへ進まない）。
# popup 非表示/accept 不可なら現在の accept-line widget（改行＝実行）へ。
_orbe_accept_line() {
  _orbe_try_accept false || zle accept-line
}

# 既存 widget を壊さないようチェーンして束ねる（zsh-syntax-highlighting 等が
# zle-line-pre-redraw を使うため、退避して両方呼ぶ）。
_orbe_bind_hook() {
  local hook=$1 fn=$2
  if [[ -n ${widgets[$hook]} ]]; then
    local orig="_orbe_orig_$hook"
    zle -A "$hook" "$orig"
    functions[_orbe_chain_$hook]="$fn; zle $orig"
    zle -N "$hook" "_orbe_chain_$hook"
  else
    zle -N "$hook" "$fn"
  fi
}

_orbe_bind_hook zle-line-init _orbe_line_init
_orbe_bind_hook zle-line-pre-redraw _orbe_line_pre_redraw
_orbe_bind_hook zle-line-finish _orbe_line_finish
zle -N _orbe_complete
bindkey '^I' _orbe_complete
zle -N _orbe_accept_line
bindkey '^M' _orbe_accept_line
