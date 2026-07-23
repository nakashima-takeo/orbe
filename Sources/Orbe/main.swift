import AppKit

// 制御ソケットのクライアント（orbe-report 等）は応答を読まず即 close する fire-and-forget
// があり、その後 Orbe 側が応答を write すると EPIPE → SIGPIPE で本体プロセスが落ちうる。
// IPC サーバを内包するプロセスの定石として SIGPIPE を無視し、write は戻り値で扱う。
signal(SIGPIPE, SIG_IGN)

// 親が Claude Code セッションだと、その判定マーカーが Orbe に継承され各ペインの
// claude へ漏れる。CLAUDE_CODE_CHILD_SESSION が伝播すると子 claude は自身を「子セッション」
// と判定し、独立 transcript を書かず /resume 履歴に残らない。Orbe はターミナルのホストで
// あり親のセッション文脈を子へ伝播すべきでない——ペイン spawn 前にこれらマーカーを一掃し、
// 各ペインを独立したトップレベルセッションとして起こす（入れ子でも有効）。
// 一方 CLAUDE_CODE_USE_BEDROCK / _USE_VERTEX 等のユーザー設定・認証系は子が必要とするため残す。
let inheritedSessionMarkers = [
  "CLAUDECODE",
  "CLAUDE_CODE_CHILD_SESSION",
  "CLAUDE_CODE_SESSION_ID",
  "CLAUDE_CODE_ENTRYPOINT",
  "CLAUDE_EFFORT",
  "AI_AGENT",
]
for key in inheritedSessionMarkers {
  unsetenv(key)
}

// zsh 補完の ZDOTDIR shim を GUI プロセス env に据える。surface spawn の base env は
// プロセス env そのものなので、Ghostty 初期化（下の Ghostty.shared）より前に一度だけ行う。
CompletionShim.activate()

// エントリポイント。AppKit ライフサイクルで起動する。
let app = NSApplication.shared
app.setActivationPolicy(.regular)
TerminalFonts.registerBundled()  // 同梱等幅チェーン用 TTF を .process 登録（フォント解決より前）
_ = Ghostty.shared  // libghostty 初期化（app/config/runtime callbacks）
let delegate = AppDelegate()
app.delegate = delegate
app.run()
