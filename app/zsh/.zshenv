# Orbe の ZDOTDIR shim。ZDOTDIR がこの dir を指すとき zsh が自動で読む——手動 source しない。
# alias 展開対策としてクォート可能なものはすべてクォートし builtin を前置する（ghostty/kitty shim と同流儀）。
# 全 zsh 起動で読まれる。ユーザーの .zshenv へブリッジし、実効 ZDOTDIR を ORBE_USER_ZDOTDIR に捕捉する。

'builtin' 'typeset' _orbe_shim_dir="${${(%):-%x}:A:h}"

# ユーザーの ZDOTDIR を復元（無ければ unset。zsh は unset ZDOTDIR を HOME と同義に扱う）。
if [[ -n "${ORBE_USER_ZDOTDIR+X}" ]]; then
    'builtin' 'export' ZDOTDIR="$ORBE_USER_ZDOTDIR"
else
    'builtin' 'unset' 'ZDOTDIR'
fi

{
    # ユーザーの .zshenv を source（ZDOTDIR 派はここで ZDOTDIR を設定するのが慣習）。
    # zsh 同様、読めない rc・ディレクトリな rc は無視する。
    'builtin' 'typeset' _orbe_file="${ZDOTDIR-$HOME}/.zshenv"
    [[ ! -r "$_orbe_file" ]] || 'builtin' 'source' '--' "$_orbe_file"
} always {
    # ユーザー .zshenv 実行後の実効 ZDOTDIR を捕捉（後続の shim ブリッジ・復元が使う）。
    if [[ -n "${ZDOTDIR+X}" ]]; then
        'builtin' 'export' ORBE_USER_ZDOTDIR="$ZDOTDIR"
    else
        'builtin' 'unset' 'ORBE_USER_ZDOTDIR'
    fi
    # 次の startup file（.zprofile/.zshrc）も shim に向ける。
    'builtin' 'export' ZDOTDIR="$_orbe_shim_dir"
    'builtin' 'unset' '_orbe_shim_dir' '_orbe_file'
}
