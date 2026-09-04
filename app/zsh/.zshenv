# Orbe の ZDOTDIR shim。ZDOTDIR がこの dir を指すとき zsh が自動で読む——手動 source しない。
# alias 展開対策としてクォート可能なものはすべてクォートし builtin を前置する（ghostty/kitty shim と同流儀）。
# 全 zsh 起動で読まれる唯一の shim。ZDOTDIR をユーザー値へ復元してユーザーの .zshenv へブリッジし、
# 以降 ZDOTDIR には触らない（続く .zprofile/.zshrc/.zlogin は zsh がユーザーの dir から読み、
# 子プロセスにも shim は残らない）。

# ユーザーの ZDOTDIR を復元し、ORBE_USER_ZDOTDIR は読んだ時点で消す（GUI → shim の一回きりの受け渡し）。
if [[ -n "${ORBE_USER_ZDOTDIR+X}" ]]; then
    'builtin' 'export' ZDOTDIR="$ORBE_USER_ZDOTDIR"
    'builtin' 'unset' 'ORBE_USER_ZDOTDIR'
else
    'builtin' 'unset' 'ZDOTDIR'
fi
# 空文字・Orbe の shim dir（自分自身・別 .app・旧版。orbe-completion.zsh の有無で同定）はユーザー値ではない。
# unset（zsh は HOME と同義に扱う）へ倒し、shim を「ユーザーの .zshenv」として source する再帰経路を閉じる。
[[ -n "${ZDOTDIR-}" && ! -r "${ZDOTDIR-}/orbe-completion.zsh" ]] || 'builtin' 'unset' 'ZDOTDIR'

{
    # ユーザーの .zshenv を source（読めない rc・ディレクトリな rc は zsh 同様に無視）。
    'builtin' 'typeset' _orbe_file="${ZDOTDIR-$HOME}/.zshenv"
    [[ ! -r "$_orbe_file" ]] || 'builtin' 'source' '--' "$_orbe_file"
} always {
    # interactive のみ: 全 startup file の後＝最初のプロンプト直前の precmd で一度だけ widget を source する。
    # フックは自分を precmd_functions から外して消え、widget ファイルはユーザーの alias・オプションから
    # 隔離した関数スコープでパースする。ORBE_SOCK/ORBE_PANE 不在なら orbe-completion.zsh 側の guard で no-op。
    if [[ -o 'interactive' ]]; then
        'builtin' 'typeset' '-g' _orbe_widget_file="${${(%):-%x}:A:h}/orbe-completion.zsh"
        _orbe_bootstrap() {
            'builtin' 'emulate' '-L' 'zsh' '-o' 'no_aliases' '-o' 'no_warn_create_global'
            'builtin' 'local' _orbe_file="$_orbe_widget_file"
            'builtin' 'unset' '_orbe_widget_file'
            precmd_functions=("${(@)precmd_functions:#_orbe_bootstrap}")
            'builtin' 'unfunction' '--' '_orbe_bootstrap'
            [[ ! -r "$_orbe_file" ]] || 'builtin' 'source' '--' "$_orbe_file"
        }
        precmd_functions+=('_orbe_bootstrap')
    fi
    'builtin' 'unset' '_orbe_file'
}
