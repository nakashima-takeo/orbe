# Orbe の ZDOTDIR shim。ZDOTDIR がこの dir を指すとき zsh が自動で読む——手動 source しない。
# alias 展開対策としてクォート可能なものはすべてクォートし builtin を前置する（ghostty/kitty shim と同流儀）。
# interactive のみ読まれる。ユーザーの .zshrc へブリッジした後に補完 widget を source する。

'builtin' 'typeset' _orbe_shim_dir="${${(%):-%x}:A:h}"

# 以降はユーザーの ZDOTDIR で動く（.zshrc は shim が仲介する最後の startup file。
# この復元により、続く .zlogin は zsh が自力で正しい場所から読み、子プロセスにも shim が残らない）。
if [[ -n "${ORBE_USER_ZDOTDIR+X}" ]]; then
    'builtin' 'export' ZDOTDIR="$ORBE_USER_ZDOTDIR"
else
    'builtin' 'unset' 'ZDOTDIR'
fi

{
    # ユーザーの .zshrc を source（読めない rc・ディレクトリな rc は zsh 同様に無視）。
    'builtin' 'typeset' _orbe_file="${ZDOTDIR-$HOME}/.zshrc"
    [[ ! -r "$_orbe_file" ]] || 'builtin' 'source' '--' "$_orbe_file"
} always {
    # ユーザー .zshrc の後に widget を source ＝ bind が定義上最後（順序競争の構造的解決）。
    # ORBE_SOCK/ORBE_PANE 不在なら orbe-completion.zsh 側の guard で no-op。
    'builtin' 'typeset' _orbe_file="$_orbe_shim_dir/orbe-completion.zsh"
    [[ ! -r "$_orbe_file" ]] || 'builtin' 'source' '--' "$_orbe_file"
    'builtin' 'unset' '_orbe_shim_dir' '_orbe_file' 'ORBE_USER_ZDOTDIR'
}
