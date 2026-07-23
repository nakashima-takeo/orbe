# Orbe の ZDOTDIR shim。ZDOTDIR がこの dir を指すとき zsh が自動で読む——手動 source しない。
# alias 展開対策としてクォート可能なものはすべてクォートし builtin を前置する（ghostty/kitty shim と同流儀）。
# login shell のみ読まれる。ユーザーの .zprofile へブリッジする（.zshenv と同型）。

'builtin' 'typeset' _orbe_shim_dir="${${(%):-%x}:A:h}"

# ユーザーの ZDOTDIR を復元（無ければ unset。zsh は unset ZDOTDIR を HOME と同義に扱う）。
if [[ -n "${ORBE_USER_ZDOTDIR+X}" ]]; then
    'builtin' 'export' ZDOTDIR="$ORBE_USER_ZDOTDIR"
else
    'builtin' 'unset' 'ZDOTDIR'
fi

{
    # ユーザーの .zprofile を source（読めない rc・ディレクトリな rc は zsh 同様に無視）。
    'builtin' 'typeset' _orbe_file="${ZDOTDIR-$HOME}/.zprofile"
    [[ ! -r "$_orbe_file" ]] || 'builtin' 'source' '--' "$_orbe_file"
} always {
    # ユーザー .zprofile が ZDOTDIR を動かした場合も一律再捕捉する。
    if [[ -n "${ZDOTDIR+X}" ]]; then
        'builtin' 'export' ORBE_USER_ZDOTDIR="$ZDOTDIR"
    else
        'builtin' 'unset' 'ORBE_USER_ZDOTDIR'
    fi
    # 次の startup file（.zshrc）も shim に向ける。
    'builtin' 'export' ZDOTDIR="$_orbe_shim_dir"
    'builtin' 'unset' '_orbe_shim_dir' '_orbe_file'
}
